import CREGEngine
import ComposableArchitecture
import Foundation

extension AppFeature {
  /// The one gate Recovery Suggestion / Prepared Follow-Up preparation
  /// starts from. `startOrRetainFollowUpPreparation` reads the same
  /// predicate to decide whether to retain instead, so a start that cannot
  /// happen and a context that must be parked can never disagree.
  func canStartFollowUpPreparation(
    state: State,
    conversationID: UUID
  ) -> Bool {
    state.canStartLowPriorityInference
      && state.modelReadiness == .ready
      && state.fmAvailability == .available
      && state.conversations[id: conversationID] != nil
  }

  /// Every path that hands a follow-up context to preparation shares this
  /// seam. An open gate starts the work; a closed one parks the context as
  /// the pending memo that activation, `.modelPrepared`, and the
  /// FM-availability watch already resume. The only context dropped here is
  /// one whose conversation is gone — parking that would hold
  /// `isInferenceIdle` false for the rest of the session with nothing left
  /// to prepare. Callers refresh availability immediately before calling.
  func startOrRetainFollowUpPreparation(
    state: inout State,
    conversationID: UUID,
    context: FollowUpSuggestionContext,
    generation: Int,
    scopeDiagnosisCompleted: Bool = false
  ) -> Effect<Action> {
    guard state.conversations[id: conversationID] != nil,
      ownsSuggestions(
        state: state, conversationID: conversationID, generation: generation)
    else { return .none }
    guard
      canStartFollowUpPreparation(
        state: state, conversationID: conversationID)
    else {
      state.pendingSuggestionContexts[conversationID] = PendingScopeDiagnosis(
        conversationID: conversationID,
        messageID: context.sourceAssistantMessageID,
        context: context,
        generation: generation,
        scopeDiagnosisCompleted: scopeDiagnosisCompleted)
      let batch = PreparedFollowUpBatch(
        sourceAssistantMessageID: context.sourceAssistantMessageID,
        context: context, status: .preparing, updatedAt: now,
        generation: generation,
        scopeDiagnosisCompleted: scopeDiagnosisCompleted)
      if state.chat?.conversationID == conversationID {
        state.chat?.followUpBatch = batch
      }
      return .merge(
        watchFMAvailabilityIfStranded(state: &state),
        saveFollowUpBatchEffect(conversationID: conversationID, batch: batch))
    }
    return startFollowUpPreparation(
      state: &state,
      conversationID: conversationID,
      context: context,
      generation: generation,
      scopeDiagnosisCompleted: scopeDiagnosisCompleted)
  }

  /// A stale save is a retired batch losing a race with the acceptance that
  /// retired it; the store refuses it and nothing is presented. Any other
  /// failure reaches the failure surface.
  func saveFollowUpBatchEffect(
    conversationID: UUID,
    batch: PreparedFollowUpBatch
  ) -> Effect<Action> {
    .run { send in
      do {
        try await history.saveFollowUpBatch(conversationID, batch)
      } catch HistoryStoreError.staleFollowUpBatch {
        return
      } catch {
        await send(.operationFailed(
          .history(operation: .messageSave, error: error)))
      }
    }
  }

  func startFollowUpPreparation(
    state: inout State,
    conversationID: UUID,
    context: FollowUpSuggestionContext,
    generation: Int,
    scopeDiagnosisCompleted: Bool = false
  ) -> Effect<Action> {
    guard
      canStartFollowUpPreparation(
        state: state, conversationID: conversationID),
      ownsSuggestions(
        state: state, conversationID: conversationID, generation: generation)
    else { return .none }
    let batch = PreparedFollowUpBatch(
      sourceAssistantMessageID: context.sourceAssistantMessageID,
      context: context,
      status: .preparing,
      updatedAt: now,
      generation: generation,
      scopeDiagnosisCompleted: scopeDiagnosisCompleted)
    state.followUpPreparation = FollowUpPreparationState(
      conversationID: conversationID,
      context: context,
      batch: batch,
      generation: generation)
    state.pendingSuggestionContexts.removeValue(forKey: conversationID)
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
      guard !Task.isCancelled else { return }
      await send(.followUpPreparationStreamEnded(
        conversationID: conversationID,
        sourceMessageID: context.sourceAssistantMessageID))
    }
    .cancellable(
      id: CancelID.followUpPreparation,
      cancelInFlight: true)
  }

  func resumeFollowUpPreparationIfIdle(
    state: inout State
  ) -> Effect<Action> {
    guard
      state.canStartLowPriorityInference,
      state.modelReadiness == .ready,
      state.fmAvailability == .available,
      let chat = state.chat,
      let batch = state.resumableFollowUpBatch,
      let context = batch.context
    else { return .none }
    guard
      ownsSuggestions(
        state: state, conversationID: chat.conversationID,
        generation: batch.effectiveGeneration)
    else {
      // The loaded batch was retired by a later accepted question.
      state.chat?.followUpBatch = nil
      return .none
    }
    if case .turnFailure(_, let verdict) = context.seed,
      verdict == nil, !batch.scopeDiagnosisCompleted
    {
      return startScopeDiagnosis(
        state: &state,
        conversationID: chat.conversationID,
        messageID: context.sourceAssistantMessageID,
        context: context,
        generation: batch.effectiveGeneration)
    }
    state.followUpPreparation = FollowUpPreparationState(
      conversationID: chat.conversationID,
      context: context,
      batch: batch,
      generation: batch.effectiveGeneration)
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
      guard !Task.isCancelled else { return }
      await send(.followUpPreparationStreamEnded(
        conversationID: conversationID,
        sourceMessageID: context.sourceAssistantMessageID))
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
        resumeRequestedModelPreparation(state: &state),
        resumePendingSuggestionContextIfIdle(state: &state),
        resumeFollowUpPreparationIfIdle(state: &state))
    }
  }

  func handleFollowUpPreparationStreamEnded(
    state: inout State,
    conversationID: UUID,
    sourceMessageID: UUID
  ) -> Effect<Action> {
    guard var preparation = state.followUpPreparation,
      preparation.conversationID == conversationID,
      preparation.context.sourceAssistantMessageID == sourceMessageID
    else { return .none }
    // No `.finished` event means this batch may be partial. Keep its
    // durable `.preparing` state for the next idle or navigation resume.
    preparation.batch.status = .preparing
    preparation.batch.updatedAt = now
    state.followUpPreparation = nil
    if state.chat?.conversationID == conversationID {
      state.chat?.followUpBatch = preparation.batch
    }
    let batch = preparation.batch
    let lines = preparation.eventLines
    return .merge(
      .run { _ in
        try? await history.saveFollowUpBatch(conversationID, batch)
        try? await history.appendEvents(conversationID, sourceMessageID, lines)
      },
      resumePendingSuggestionContextIfIdle(state: &state),
      resumeRequestedModelPreparation(state: &state))
  }

  // MARK: - Scope diagnosis (C before D)

  /// A backgrounded diagnosis retains its Recovery Suggestion context but not
  /// the optional verdict. Resume D only after the app is active and the same
  /// idle/model-availability gates used by ordinary preparation are satisfied.
  func resumeInterruptedScopeDiagnosisIfIdle(
    state: inout State
  ) -> Effect<Action> {
    guard
      let pending = state.pendingScopeDiagnosis,
      !state.isScopeDiagnosisInFlight
    else { return .none }
    guard state.conversations[id: pending.conversationID] != nil,
      ownsSuggestions(
        state: state, conversationID: pending.conversationID,
        generation: pending.generation)
    else {
      // The retained diagnosis can never resume once its conversation is
      // gone or its generation was retired; keeping it would gate
      // preparation, resume, and model maintenance for the rest of the
      // session.
      state.pendingScopeDiagnosis = nil
      return .none
    }
    guard
      state.canStartLowPriorityInferenceIgnoringScopeDiagnosis,
      state.modelReadiness == .ready,
      state.fmAvailability == .available
    else { return .none }
    state.pendingScopeDiagnosis = nil
    return startScopeDiagnosis(
      state: &state,
      conversationID: pending.conversationID,
      messageID: pending.messageID,
      context: pending.context,
      generation: pending.generation,
      scopeDiagnosisCompleted: pending.scopeDiagnosisCompleted)
  }

  func resumePendingSuggestionContextIfIdle(
    state: inout State
  ) -> Effect<Action> {
    guard state.canStartLowPriorityInference,
      state.modelReadiness == .ready,
      state.fmAvailability == .available
    else { return .none }
    // Parked contexts whose conversation is gone or whose generation was
    // retired are dropped here rather than resumed.
    state.pendingSuggestionContexts = state.pendingSuggestionContexts.filter {
      state.conversations[id: $0.key] != nil
        && ownsSuggestions(
          state: state, conversationID: $0.key,
          generation: $0.value.generation)
    }
    let selectedID = state.chat?.conversationID
    guard let pending = selectedID.flatMap({ state.pendingSuggestionContexts[$0] })
      ?? state.pendingSuggestionContexts.values.min(by: {
        $0.conversationID.uuidString < $1.conversationID.uuidString
      })
    else { return .none }
    state.pendingSuggestionContexts.removeValue(forKey: pending.conversationID)
    // The judge runs once per context: a parked verdict, or a completed nil
    // verdict, resumes straight into preparation.
    if pending.needsScopeDiagnosis {
      return startScopeDiagnosis(
        state: &state, conversationID: pending.conversationID,
        messageID: pending.messageID, context: pending.context,
        generation: pending.generation)
    }
    return startFollowUpPreparation(
      state: &state, conversationID: pending.conversationID,
      context: pending.context,
      generation: pending.generation,
      scopeDiagnosisCompleted: pending.scopeDiagnosisCompleted)
  }

  /// A retained scope diagnosis holds `isInferenceIdle` false, and while
  /// Apple Intelligence is off nothing else can clear it — which would gate
  /// the user's explicit model-preparation retry for the rest of the
  /// session. The explicit retry outranks the passive recovery memo. Park
  /// the memo so it can resume after model maintenance.
  func abandonScopeDiagnosisForModelMaintenance(
    state: inout State
  ) -> Effect<Action> {
    guard let pending = state.pendingScopeDiagnosis else { return .none }
    state.pendingSuggestionContexts[pending.conversationID] = pending
    state.pendingScopeDiagnosis = nil
    state.isScopeDiagnosisInFlight = false
    diagnostics.info(
      category: .submission,
      code: "scope_diagnosis_parked_for_model_preparation",
      summary:
        "A pending scope diagnosis was parked so a user-requested model preparation could start.")
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
    context: FollowUpSuggestionContext,
    generation: Int,
    scopeDiagnosisCompleted: Bool = false
  ) -> Effect<Action> {
    // The persistence barrier can settle after the user has already deleted
    // the conversation (the durable delete defers on that same barrier). A
    // verdict for a deleted conversation has nothing to enrich or persist,
    // and parking it would hold `isInferenceIdle` false for nothing. The
    // same goes for a context whose generation a later question retired.
    guard state.conversations[id: conversationID] != nil,
      ownsSuggestions(
        state: state, conversationID: conversationID, generation: generation)
    else { return .none }
    // A context that already carries a verdict, or whose judge already
    // completed, is never judged again.
    let needsScopeDiagnosis: Bool = {
      guard case .turnFailure(_, let verdict) = context.seed else { return false }
      return verdict == nil && !scopeDiagnosisCompleted
    }()
    // The judge needs Apple Intelligence and the serializer, not the SQL
    // model, so readiness is deliberately absent here. Every gate that is
    // closed would fail the identical gate inside preparation, so hand the
    // context to the retain seam instead of falling through it: the only
    // copy of a Recovery Suggestion context survives to the next foreground
    // idle window rather than being discarded.
    guard
      needsScopeDiagnosis,
      state.isSceneActive,
      state.isTurnSchedulerIdle,
      state.fmAvailability == .available
    else {
      return startOrRetainFollowUpPreparation(
        state: &state,
        conversationID: conversationID,
        context: context,
        generation: generation,
        scopeDiagnosisCompleted: scopeDiagnosisCompleted)
    }
    state.pendingScopeDiagnosis = PendingScopeDiagnosis(
      conversationID: conversationID,
      messageID: messageID,
      context: context,
      generation: generation)
    state.isScopeDiagnosisInFlight = true
    let question = context.standaloneQuestion
    let batch = PreparedFollowUpBatch(
      sourceAssistantMessageID: messageID,
      context: context, status: .preparing, updatedAt: now,
      generation: generation)
    return .run(priority: .low) { send in
      // Register the cancellation ID before the durable write, and let the
      // write finish even if inactivity cancels the judge in this window.
      let save = Task {
        try await history.saveFollowUpBatch(conversationID, batch)
      }
      do {
        try await save.value
      } catch HistoryStoreError.staleFollowUpBatch {
        return
      } catch {
        await send(.operationFailed(
          .history(operation: .messageSave, error: error)))
      }
      guard !Task.isCancelled else { return }
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
    // Clear only the judge identified by this completion. A stale completion
    // from a cancelled effect must not make a newer diagnosis look resumable.
    state.isScopeDiagnosisInFlight = false
    var context = pending.context
    var verdictPersistence: Effect<Action>?
    var verdictAttached = false

    if let verdict, case .turnFailure(let reason, _) = context.seed {
      verdictAttached = true
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

    guard verdictAttached else {
      // The judge ran to completion without a verdict. The context moves on
      // to preparation, parked if a gate is closed, and is marked judged so
      // no resume path calls the judge a second time. A nil verdict also
      // often means Apple Intelligence went unavailable mid-session — re-read
      // availability so the resume gates see fresh state, and watch for
      // recovery so the retained context does not strand while the app
      // stays foregrounded.
      refreshFMAvailability(state: &state)
      state.pendingScopeDiagnosis = nil
      return .merge(
        startOrRetainFollowUpPreparation(
          state: &state, conversationID: conversationID,
          context: context, generation: pending.generation,
          scopeDiagnosisCompleted: true),
        watchFMAvailabilityIfStranded(state: &state))
    }
    state.pendingScopeDiagnosis = nil
    // Persist C's message/event enrichment before D can append preparation
    // events, preserving the intended C-before-D order in events.jsonl. D
    // starts through its own action so delivery re-checks the idle gates: a
    // turn dispatched or a deletion committed during this write must veto
    // the preparation. Chaining the raw preparation effect here would defer
    // its cancel-ID registration behind the write, turning any
    // `.cancel(id: .followUpPreparation)` issued in that window into a no-op
    // and letting the preparation run as an uncancellable zombie. A failed
    // event encoding skips only the durable write: the verdict-enriched
    // context still reaches preparation.
    return .concatenate(
      verdictPersistence ?? .none,
      .send(
        .scopeDiagnosisPersisted(
          conversationID: conversationID, context: context,
          generation: pending.generation)))
  }

  // MARK: - Conversation lifecycle helpers

}
