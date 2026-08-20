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
      state.activeTurn == nil,
      state.queue.isEmpty,
      state.pendingTurnPersistence == nil,
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
      state.activeTurn == nil,
      state.queue.isEmpty,
      state.pendingTurnPersistence == nil,
      state.pendingScopeDiagnosis == nil,
      state.followUpPreparation == nil,
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
      return .run { _ in
        try? await history.saveFollowUpBatch(conversationID, batch)
        try? await history.appendEvents(
          conversationID, sourceMessageID, lines)
      }
    }
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
      state.activeTurn == nil,
      state.queue.isEmpty,
      state.pendingTurnPersistence == nil,
      state.followUpPreparation == nil,
      state.modelReadiness == .ready,
      state.fmAvailability == .available,
      state.conversations[id: pending.conversationID] != nil
    else { return .none }
    state.pendingScopeDiagnosis = nil
    return startFollowUpPreparation(
      state: &state,
      conversationID: pending.conversationID,
      context: pending.context)
  }

  /// Judges portfolio coverage of the failed question after the failure has
  /// rendered, then hands the verdict-enriched context to Recovery Suggestion
  /// preparation. When the diagnosis cannot run — a turn started, FM went
  /// unavailable, or the conversation is no longer on screen (its message is
  /// not loaded to enrich) — preparation proceeds without a verdict.
  func startScopeDiagnosis(
    state: inout State,
    conversationID: UUID,
    messageID: UUID,
    context: FollowUpSuggestionContext
  ) -> Effect<Action> {
    guard
      context.isRecoverySeed,
      state.activeTurn == nil,
      state.queue.isEmpty,
      state.fmAvailability == .available,
      state.chat?.conversationID == conversationID
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
    state.pendingScopeDiagnosis = nil
    var context = pending.context
    var effects: [Effect<Action>] = []

    if let verdict, case .turnFailure(let reason, _) = context.seed {
      context.seed = .turnFailure(reason: reason, scopeVerdict: verdict)
      // Enrich the rendered failure in place — the same revisioned-save
      // pattern as preparedAnswer → .answer.
      if state.chat?.conversationID == conversationID,
        let index = state.chat?.messages.index(id: messageID),
        var message = state.chat?.messages[index],
        case .failedTurn(let bodyReason, _) = message.body
      {
        message.body = .failedTurn(reason: bodyReason, scopeVerdict: verdict)
        message.devInfo?.scopeVerdict = verdict
        state.chat?.messages[index] = message
        let updated = message
        effects.append(
          .run { _ in
            _ = try? await messageUpdateQueue.save(
              conversationID: conversationID,
              messageID: updated.id
            ) {
              try await history.updateMessage(conversationID, updated)
            }
          })
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

    effects.append(
      startFollowUpPreparation(
        state: &state,
        conversationID: conversationID,
        context: context))
    return .merge(effects)
  }

  // MARK: - Conversation lifecycle helpers

}
