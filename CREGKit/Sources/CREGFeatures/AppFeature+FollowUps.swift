import CREGEngine
import ComposableArchitecture
import Foundation

extension AppFeature {
  func startFollowUpPreparation(
    state: inout State,
    conversationID: UUID,
    context: FollowUpSuggestionContext
  ) -> Effect<Action> {
    guard
      state.isSceneActive,
      state.isInferenceIdle,
      state.modelReadiness == .ready,
      state.fmAvailability == .available,
      state.conversations[id: conversationID] != nil
    else { return .none }
    let batch = PreparedFollowUpBatch(
      sourceAssistantMessageID: context.sourceAssistantMessageID,
      context: context,
      status: .preparing,
      updatedAt: now)
    state.followUpPreparation = FollowUpPreparationState(
      conversationID: conversationID,
      context: context,
      batch: batch)
    if state.chat?.conversationID == conversationID {
      state.chat?.followUpBatch = batch
    }
    return .run(priority: .low) { send in
      try? await history.saveFollowUpBatch(conversationID, batch)
      for await event in pipeline.prepareFollowUps(context) {
        guard !Task.isCancelled else { return }
        await send(
          .followUpPreparationEvent(
            conversationID: conversationID,
            sourceMessageID: context.sourceAssistantMessageID,
            event: event))
      }
    }
    .cancellable(
      id: CancelID.followUpPreparation,
      cancelInFlight: true)
  }

  func resumeFollowUpPreparationIfIdle(
    state: inout State
  ) -> Effect<Action> {
    guard
      state.isSceneActive,
      state.isInferenceIdle,
      state.modelReadiness == .ready,
      state.fmAvailability == .available,
      let chat = state.chat,
      let batch = chat.followUpBatch,
      batch.status == .preparing,
      let context = batch.context
    else { return .none }
    state.followUpPreparation = FollowUpPreparationState(
      conversationID: chat.conversationID,
      context: context,
      batch: batch)
    let conversationID = chat.conversationID
    return .run(priority: .low) { send in
      for await event in pipeline.prepareFollowUps(context) {
        guard !Task.isCancelled else { return }
        await send(
          .followUpPreparationEvent(
            conversationID: conversationID,
            sourceMessageID: context.sourceAssistantMessageID,
            event: event))
      }
    }
    .cancellable(
      id: CancelID.followUpPreparation,
      cancelInFlight: true)
  }

  func handleFollowUpPreparationEvent(
    state: inout State,
    conversationID: UUID,
    sourceMessageID: UUID,
    event: FollowUpPreparationEvent
  ) -> Effect<Action> {
    guard
      var preparation = state.followUpPreparation,
      preparation.conversationID == conversationID,
      preparation.context.sourceAssistantMessageID == sourceMessageID,
      state.activeTurn == nil,
      state.queue.isEmpty,
      state.pendingTurnPersistence == nil
    else { return .none }

    if let line = try? event.jsonLine() {
      preparation.eventLines.append(line)
    }
    switch event {
    case .started, .proposalFailed, .rejected:
      state.followUpPreparation = preparation
      return .none

    case .prepared(let prepared):
      _ = preparation.batch.appendIfEligible(prepared)
      preparation.batch.updatedAt = now
      state.followUpPreparation = preparation
      if state.chat?.conversationID == conversationID {
        state.chat?.followUpBatch = preparation.batch
      }
      let batch = preparation.batch
      return .run { _ in
        try? await history.saveFollowUpBatch(conversationID, batch)
      }

    case .finished:
      preparation.batch.status = .completed
      preparation.batch.updatedAt = now
      state.followUpPreparation = nil
      if state.chat?.conversationID == conversationID {
        state.chat?.followUpBatch = preparation.batch
      }
      let batch = preparation.batch
      let lines = preparation.eventLines
      let persistence = Effect<Action>.run { _ in
        try? await history.saveFollowUpBatch(conversationID, batch)
        try? await history.appendEvents(
          conversationID, sourceMessageID, lines)
      }
      // An interrupted-diagnosis resume can occupy the slot ahead of the
      // selected conversation's own persisted `.preparing` batch, whose only
      // other resume hooks are activation and navigation. Re-check now that
      // the slot is free again.
      return .merge(
        persistence,
        resumeFollowUpPreparationIfIdle(state: &state))
    }
  }

  // MARK: - Scope diagnosis (C before D)

  /// A backgrounded diagnosis retains its Recovery Suggestion context but not
  /// the optional verdict. Resume D only after the app is active and the same
  /// idle/model-availability gates used by ordinary preparation are satisfied.
  func resumeInterruptedScopeDiagnosisIfIdle(
    state: inout State
  ) -> Effect<Action> {
    guard let pending = state.pendingScopeDiagnosis else { return .none }
    guard state.conversations[id: pending.conversationID] != nil else {
      // The retained diagnosis can never resume once its conversation is
      // gone; keeping it would gate preparation, resume, and model
      // maintenance for the rest of the session.
      state.pendingScopeDiagnosis = nil
      return .none
    }
    guard
      state.isSceneActive,
      state.isTurnSchedulerIdle,
      state.followUpPreparation == nil,
      !state.isCapturingAnswerability,
      state.modelReadiness == .ready,
      state.fmAvailability == .available
    else { return .none }
    state.pendingScopeDiagnosis = nil
    return startFollowUpPreparation(
      state: &state,
      conversationID: pending.conversationID,
      context: pending.context)
  }

  /// A retained scope diagnosis holds `isInferenceIdle` false, and while
  /// Apple Intelligence is off nothing else can clear it — which would gate
  /// the user's explicit model-preparation retry for the rest of the
  /// session. The explicit retry outranks the passive recovery memo, exactly
  /// as `dispatch` abandons an in-flight diagnosis rather than queueing
  /// behind it.
  func abandonScopeDiagnosisForModelMaintenance(
    state: inout State
  ) -> Effect<Action> {
    guard state.pendingScopeDiagnosis != nil else { return .none }
    state.pendingScopeDiagnosis = nil
    diagnostics.info(
      category: .submission,
      code: "scope_diagnosis_abandoned_for_model_preparation",
      summary:
        "A pending scope diagnosis was abandoned so a user-requested model preparation could start.")
    return .cancel(id: CancelID.scopeDiagnosis)
  }

  /// Judges portfolio coverage of the failed question after the failure has
  /// rendered, then hands the verdict-enriched context to Recovery Suggestion
  /// preparation. Selection is irrelevant: background conversations still
  /// complete C before D and persist the same verdict/event pair.
  func startScopeDiagnosis(
    state: inout State,
    conversationID: UUID,
    messageID: UUID,
    context: FollowUpSuggestionContext
  ) -> Effect<Action> {
    // The persistence barrier can settle after the user has already deleted
    // the conversation (the durable delete defers on that same barrier). A
    // verdict for a deleted conversation has nothing to enrich or persist,
    // and parking it would hold `isInferenceIdle` false for nothing.
    guard state.conversations[id: conversationID] != nil else { return .none }
    guard state.isSceneActive else {
      // The barrier can also settle while the app is inactive. Never start
      // FM work in the background; retain the context exactly like a
      // backgrounded diagnosis so reactivation resumes Recovery Suggestion
      // preparation without a verdict.
      if context.isRecoverySeed {
        state.pendingScopeDiagnosis = PendingScopeDiagnosis(
          conversationID: conversationID,
          messageID: messageID,
          context: context)
      }
      return .none
    }
    guard
      context.isRecoverySeed,
      state.isTurnSchedulerIdle,
      state.fmAvailability == .available
    else {
      return startFollowUpPreparation(
        state: &state,
        conversationID: conversationID,
        context: context)
    }
    state.pendingScopeDiagnosis = PendingScopeDiagnosis(
      conversationID: conversationID,
      messageID: messageID,
      context: context)
    let question = context.standaloneQuestion
    return .run(priority: .low) { send in
      let verdict = await scopeDiagnosis.judge(question)
      guard !Task.isCancelled else { return }
      await send(
        .scopeDiagnosisFinished(
          conversationID: conversationID,
          messageID: messageID,
          verdict: verdict))
    }
    .cancellable(id: CancelID.scopeDiagnosis, cancelInFlight: true)
  }

  func handleScopeDiagnosisFinished(
    state: inout State,
    conversationID: UUID,
    messageID: UUID,
    verdict: ScopeVerdictRecord?
  ) -> Effect<Action> {
    guard
      let pending = state.pendingScopeDiagnosis,
      pending.conversationID == conversationID,
      pending.messageID == messageID
    else { return .none }
    var context = pending.context
    var verdictPersistence: Effect<Action>?

    if let verdict, case .turnFailure(let reason, _) = context.seed {
      context.seed = .turnFailure(reason: reason, scopeVerdict: verdict)
      // Enrich the selected transcript immediately when it is loaded. The
      // durable transaction below performs the same update regardless of the
      // user's current selection.
      if state.chat?.conversationID == conversationID,
        let index = state.chat?.messages.index(id: messageID),
        var message = state.chat?.messages[index],
        case .failedTurn(let bodyReason, _) = message.body
      {
        message.body = .failedTurn(reason: bodyReason, scopeVerdict: verdict)
        message.devInfo?.scopeVerdict = verdict
        state.chat?.messages[index] = message
      }
      let event = PipelineEvent.scopeDiagnosisFinished(
        sourceAssistantMessageID: messageID,
        verdict: verdict)
      if let line = try? event.jsonLine() {
        verdictPersistence = .run { _ in
          try? await history.persistScopeDiagnosis(
            conversationID, messageID, verdict, line)
        }
      }
      diagnostics.info(
        category: .submission,
        code: "scope_verdict_attached",
        summary: "A Scope Verdict annotated a rendered Turn Failure.",
        context: [
          "verdict": verdict.verdict.rawValue,
          "has_missing_subject": String(verdict.missingSubject != nil),
        ])
    }

    guard let verdictPersistence else {
      // Keep the recovery memo until every follow-on gate is open. In
      // particular, deactivation can be reduced before this already-queued
      // nil completion; consuming the memo here would leave nothing for the
      // next activation to resume.
      return resumeInterruptedScopeDiagnosisIfIdle(state: &state)
    }
    state.pendingScopeDiagnosis = nil
    // Persist C's message/event enrichment before D can append preparation
    // events, preserving the intended C-before-D order in events.jsonl. D
    // starts through its own action so delivery re-checks the idle gates: a
    // turn dispatched or a deletion committed during this write must veto
    // the preparation. Chaining the raw preparation effect here would defer
    // its cancel-ID registration behind the write, turning any
    // `.cancel(id: .followUpPreparation)` issued in that window into a no-op
    // and letting the preparation run as an uncancellable zombie.
    return .concatenate(
      verdictPersistence,
      .send(
        .scopeDiagnosisPersisted(
          conversationID: conversationID, context: context)))
  }

  // MARK: - Conversation lifecycle helpers

}
