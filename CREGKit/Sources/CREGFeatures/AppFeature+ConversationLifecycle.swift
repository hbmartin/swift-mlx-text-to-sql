import CREGEngine
import ComposableArchitecture
import Foundation

extension AppFeature {
  func deleteConversation(
    state: inout State,
    summary: ConversationSummary
  ) -> Effect<Action> {
    var effects: [Effect<Action>] = []

    // A second delete inside the Undo window commits the first immediately.
    if let previous = state.pendingDeletion {
      let id = previous.summary.id
      effects.append(
        commitOrDeferDeletion(state: &state, conversationID: id))
    }

    let index = state.conversations.index(id: summary.id) ?? 0
    state.conversations.remove(id: summary.id)
    state.pendingDeletion = PendingDeletion(summary: summary, index: index)
    state.queue.removeAll { $0.conversationID == summary.id }
    if state.activeTurn?.conversationID == summary.id {
      state.activeTurn = nil
      effects.append(.cancel(id: CancelID.pipeline))
      effects.append(.send(.dispatchNextIfIdle))
    }
    if state.followUpPreparation?.conversationID == summary.id {
      state.followUpPreparation = nil
      effects.append(.cancel(id: CancelID.followUpPreparation))
    }
    if state.pendingScopeDiagnosis?.conversationID == summary.id {
      // A diagnosis for a deleted conversation can never resume, and a
      // retained one gates preparation and model maintenance session-long.
      state.pendingScopeDiagnosis = nil
      state.isScopeDiagnosisInFlight = false
      effects.append(.cancel(id: CancelID.scopeDiagnosis))
    }

    if state.chat?.conversationID == summary.id {
      if let nextSummary = state.conversations.first {
        effects.append(loadConversationEffect(id: nextSummary.id))
      } else {
        effects.append(createConversationEffect())
      }
    }
    syncSchedulerProjection(into: &state)

    diagnostics.info(
      category: .history,
      code: "conversation_delete_pending",
      summary: "A conversation entered the undo window before deletion.")
    effects.append(
      .run { send in
        try await clock.sleep(for: .seconds(5))
        await send(.deleteCountdownFinished)
      }
      .cancellable(id: CancelID.deleteCountdown, cancelInFlight: true))
    return .merge(effects)
  }

  /// Commits a confirmed delete only after its terminal transcript write has
  /// settled. Removing the row sooner would allow the still-live write to fail
  /// visibly or recreate orphaned journal/event data after deletion.
  func commitOrDeferDeletion(
    state: inout State,
    conversationID: UUID
  ) -> Effect<Action> {
    if state.pendingTurnPersistence?.conversationID == conversationID {
      state.deletionAwaitingTurnPersistence = conversationID
      diagnostics.info(
        category: .history,
        code: "conversation_delete_waiting_for_persistence",
        summary: "Conversation deletion is waiting for its final history write.")
      return .none
    }
    return commitDeletionEffect(conversationID: conversationID)
  }

  func handleConversationWriteFailure(
    state: inout State,
    conversationID: UUID,
    failure: FailurePresentation
  ) -> Effect<Action> {
    if state.pendingDeletion?.summary.id == conversationID {
      state.pendingDeletion?.deferredFailure = failure
      diagnostics.info(
        category: .history,
        code: "conversation_write_failure_deferred_for_undo",
        summary:
          "A conversation write failure is deferred until the pending deletion is resolved.")
      return .none
    }
    guard state.conversations[id: conversationID] != nil else { return .none }
    return .send(.operationFailed(failure))
  }

  func rollBackOptimisticUserTurn(
    state: inout State,
    questionID: UUID,
    conversationID: UUID,
    optimisticTurn: OptimisticUserTurn
  ) {
    let terminalMessageID =
      state.pendingTurnPersistence?.questionID == questionID
      ? state.pendingTurnPersistence?.terminalMessageID
      : nil
    if state.activeTurn?.questionID == questionID {
      state.activeTurn = nil
    }
    if state.pendingTurnPersistence?.questionID == questionID {
      state.pendingTurnPersistence = nil
    }
    if state.chat?.conversationID == conversationID {
      let messageIDs = Set(
        [optimisticTurn.message.id, terminalMessageID].compactMap { $0 })
      state.chat?.messages.removeAll { messageIDs.contains($0.id) }
      if state.chat?.isManuallyTitled == false,
        let previousChatTitle = optimisticTurn.previousChatTitle
      {
        state.chat?.title = previousChatTitle
      }
    }

    if var previousSummary = optimisticTurn.previousSummary,
      let currentSummary = state.conversations[id: conversationID]
    {
      if currentSummary.isManuallyTitled {
        previousSummary.title = currentSummary.title
        previousSummary.isManuallyTitled = true
      }
      state.conversations[id: conversationID] = previousSummary
      state.conversations.sort { $0.lastActivityAt > $1.lastActivityAt }
    }
    syncSchedulerProjection(into: &state)
  }

  func commitDeletionEffect(conversationID: UUID) -> Effect<Action> {
    .run { send in
      await messageUpdateQueue.beginDeletingConversation(conversationID)
      do {
        try await history.deleteConversation(conversationID)
        await messageUpdateQueue.confirmConversationDeletion(conversationID)
      } catch {
        await messageUpdateQueue.cancelConversationDeletion(conversationID)
        await send(
          .operationFailed(.history(operation: .delete, error: error)))
      }
    }
  }

  func createConversationEffect() -> Effect<Action> {
    let id = uuid()
    let startedAt = now
    return .run { send in
      let summary = try await history.createConversation(id, startedAt)
      await send(.conversationCreated(summary))
    } catch: { error, send in
      await send(
        .operationFailed(.history(operation: .conversationCreate, error: error)))
    }
  }

  func loadConversationEffect(id: UUID) -> Effect<Action> {
    .run { send in
      let snapshot = try await history.loadConversation(id)
      await send(.conversationLoaded(snapshot))
    } catch: { error, send in
      await send(
        .operationFailed(.history(operation: .load, error: error)))
    }
  }

  /// Mirrors the global queue and active turn into the selected chat's
  /// parent-maintained projection fields.
  func setModelReadiness(
    _ readiness: ModelReadiness,
    state: inout State
  ) {
    state.modelReadiness = readiness
    syncSchedulerProjection(into: &state)
  }

  /// Re-reads Apple Intelligence availability and re-projects the submission
  /// gate. Availability is a synchronous system read, so this runs inline on
  /// appearance and scene activation rather than through an effect.
  func refreshFMAvailability(state: inout State) {
    let availability = fmStatus.availability()
    guard availability != state.fmAvailability else { return }
    state.fmAvailability = availability
    if case .unavailable(let reason) = availability {
      diagnostics.info(
        category: .submission,
        code: "fm_unavailable",
        summary: "Apple Intelligence is unavailable; submission is gated.",
        context: ["reason": reason.label])
    }
    syncSchedulerProjection(into: &state)
  }

  func syncSchedulerProjection(into state: inout State) {
    guard var chat = state.chat else { return }
    chat.isSubmissionEnabled =
      state.modelReadiness == .ready && state.fmAvailability == .available
    chat.queued = state.queue.filter { $0.conversationID == chat.conversationID }
    if let active = state.activeTurn,
      active.conversationID == chat.conversationID
    {
      let expanded = chat.processing?.isTimelineExpanded ?? false
      chat.processing = ChatFeature.ProcessingState(
        questionID: active.questionID,
        question: active.question,
        startedAt: active.startedAt,
        trace: active.trace,
        isTimelineExpanded: expanded)
    } else {
      chat.processing = nil
    }
    state.chat = chat
  }

  func updateSummaryAfterMessage(
    state: inout State,
    conversationID: UUID,
    message: ChatMessage,
    replacing: Bool = false
  ) {
    guard var summary = state.conversations[id: conversationID] else { return }
    summary.lastActivityAt = message.createdAt
    summary.latestMessagePreview = message.previewText
    if !replacing { summary.messageCount += 1 }
    state.conversations[id: conversationID] = summary
    state.conversations.sort { $0.lastActivityAt > $1.lastActivityAt }
  }

  func startLaunchBenchmarkIfReady(
    state: inout State
  ) -> Effect<Action> {
    refreshFMAvailability(state: &state)
    guard
      let question = state.launchBenchmarkQuestion?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !question.isEmpty,
      !state.launchBenchmarkStarted,
      state.modelReadiness == .ready,
      state.fmAvailability == .available,
      state.chat != nil,
      state.activeTurn == nil,
      state.pendingTurnPersistence == nil
    else { return .none }

    // A launch benchmark is a standalone turn. Do not let a prior installed
    // build's conversation trigger Foundation Models rewrite work or alter the
    // SQL prompt being timed.
    state.chat?.messages.removeAll()
    state.launchBenchmarkStarted = true
    diagnostics.info(
      category: .submission,
      code: "launch_benchmark_started",
      summary: "The Debug launch benchmark started.")
    guard let conversationID = state.chat?.conversationID else { return .none }
    return dispatch(
      state: &state,
      conversationID: conversationID,
      submission: QuestionSubmission(question: question))
  }

  func preparationEffect(
    mode: ModelRuntimeMode
  ) -> Effect<Action> {
    .run { send in
      var environment = preparationEnvironment.snapshot()
      environment["runtime_mode"] = mode.rawValue
      diagnostics.info(
        category: .model,
        code: "model_preparation_attempt_started",
        summary: "A SQL model preparation attempt started.",
        context: environment)
      await preparationJournal.begin(
        mode,
        environment)
      do {
        let report = try await pipeline.prepare(mode)
        await preparationJournal.complete(report)
        await send(.modelPrepared(report))
      } catch {
        let failure: ModelPreparationFailure
        if let preparationFailure = error as? ModelPreparationFailure {
          failure = preparationFailure
        } else {
          let nsError = error as NSError
          failure = ModelPreparationFailure(
            code: "model_preparation_unexpected",
            stage: .containerLoad,
            mode: mode,
            userMessage:
              "The SQL model could not be prepared. Restart CREG and try again.",
            diagnostic: DiagnosticDetails.sanitizedDescription(error),
            errorDomain: nsError.domain,
            errorCode: nsError.code)
        }
        await preparationJournal.fail(failure)
        await send(.modelPreparationFailed(failure))
      }
    }
    .cancellable(id: CancelID.modelPreparation, cancelInFlight: true)
  }

  /// A retained Scope Verdict memo deliberately does not gate preparation:
  /// both retry paths abandon it via
  /// `abandonScopeDiagnosisForModelMaintenance`, because the explicit user
  /// request outranks the passive recovery memo.
  func canStartModelPreparation(state: State) -> Bool {
    !state.modelPreparationInFlight
      && state.isInferenceIdleIgnoringScopeDiagnosis
  }

  func outcomeName(_ outcome: TurnOutcome) -> String {
    switch outcome {
    case .answered: "answered"
    case .needsClarification: "needs_clarification"
    case .failed: "failed"
    }
  }

  func timeoutStage(_ stage: String?) -> String {
    TurnTelemetry.normalizedTimeoutStage(stage)
  }
}
