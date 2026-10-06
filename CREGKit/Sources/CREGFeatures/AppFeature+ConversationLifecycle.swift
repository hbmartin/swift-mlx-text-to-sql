import CREGEngine
import ComposableArchitecture
import Foundation

extension AppFeature {
  func retryJournalEligibleForQueue(
    state: State, conversationID: UUID, journalID: UUID
  ) -> Bool {
    state.conversations[id: conversationID] != nil
      && state.isConversationLive(conversationID)
      && !state.dismissedRetryJournalIDs.contains(journalID)
  }

  /// A dismissal failure owns the user-facing error. Keep its journal hidden
  /// until every earlier retry write has settled, then restore manual retry.
  func finishDeferredDismissalIfReady(
    state: inout State, journalID: UUID
  ) -> Effect<Action> {
    guard var deferred = state.pendingInterruptedDismissals[journalID],
      let failure = deferred.failure,
      state.retryJournals[journalID]?.operations.values.contains(where: \.holdsScheduler) != true
    else { return .none }
    state.retryJournals[journalID]?.dismissalRecovery = nil
    guard
      state.conversations[id: deferred.conversationID] != nil
        || state.isConversationPendingDeletion(deferred.conversationID)
    else { return .none }
    deferred.interruption.status = .manualRetryRequired
    state.retryJournals[journalID]?.dismissalRecovery = deferred
    state.retryJournals[journalID]?.dismissalIsSettled = true
    syncDismissalProjection(into: &state)
    syncSchedulerProjection(into: &state)
    return handleConversationWriteFailure(
      state: &state, conversationID: deferred.conversationID, failure: failure)
  }

  /// A history load cannot resurrect pending or successfully dismissed rows.
  /// Recovery changes only interruption banners, preserving the live chat.
  func syncDismissalProjection(into state: inout State) {
    guard var chat = state.chat,
      state.isConversationLive(chat.conversationID)
    else { return }
    chat.interruptedTurns.removeAll {
      guard let journalID = $0.journalID ?? $0.executionID else { return false }
      return state.dismissedRetryJournalIDs.contains(journalID)
        && state.failedDismissalRecoveries[journalID] == nil
    }
    for recovery in state.failedDismissalRecoveries.values
    where recovery.conversationID == chat.conversationID {
      if let index = chat.interruptedTurns.firstIndex(where: {
        ($0.journalID ?? $0.executionID) == recovery.journalID
      }) {
        let retryCount = chat.interruptedTurns[index].autoRetryCount
        chat.interruptedTurns[index] = recovery.interruption
        chat.interruptedTurns[index].autoRetryCount = retryCount
      } else {
        chat.interruptedTurns.append(recovery.interruption)
      }
    }
    chat.interruptedTurns.sort {
      if $0.interruptedAt != $1.interruptedAt { return $0.interruptedAt < $1.interruptedAt }
      return (($0.journalID ?? $0.executionID)?.uuidString ?? "")
        < (($1.journalID ?? $1.executionID)?.uuidString ?? "")
    }
    state.chat = chat
  }

  func recordSuppressedRetryFailure(_ failure: FailurePresentation, journalID: UUID) {
    diagnostics.record(
      DiagnosticEvent(
        level: .error, category: .history,
        code: "retry_write_failed_after_dismissal",
        summary: "An obsolete retry write failed after its interruption was dismissed.",
        details: failure.diagnostic,
        context: ["journal_id": journalID.uuidString, "failure_code": failure.code]))
  }

  func updateRetryCount(
    state: inout State, conversationID: UUID, journalID: UUID, count: Int
  ) {
    state.seedRetry(journalID, conversationID: conversationID)
    state.retryJournals[journalID]?.knownDurableCount = count
    state.retryJournals[journalID]?.interruption?.autoRetryCount = count
    state.retryJournals[journalID]?.dismissalRecovery?.interruption.autoRetryCount = count
    if state.chat?.conversationID == conversationID,
      let index = state.chat?.interruptedTurns.firstIndex(where: {
        ($0.journalID ?? $0.executionID) == journalID
      })
    {
      state.chat?.interruptedTurns[index].autoRetryCount = count
    }
  }

  func deleteConversation(
    state: inout State,
    summary: ConversationSummary
  ) -> Effect<Action> {
    guard state.isConversationLive(summary.id) else { return .none }
    var effects: [Effect<Action>] = []
    if let previous = state.pendingDeletion {
      state.undoDeletionID = nil
      effects.append(.cancel(id: DeletionCountdownID(token: previous.token)))
      effects.append(commitOrDeferDeletion(state: &state, conversationID: previous.summary.id))
    }
    let token = uuid()
    state.conversationDeletions[summary.id] = .init(token: token, summary: summary)
    state.undoDeletionID = summary.id
    for (journalID, journal) in state.retryJournals where journal.conversationID == summary.id {
      for operation in journal.operations.values {
        if case .inspection(let queued, _) = operation {
          insertQueuedQuestion(queued, into: &state)
        }
      }
      state.invalidateRetryInspection(journalID)
      effects.append(.cancel(id: RetryInspectionID(journalID: journalID)))
    }
    if state.answerReadyBanner?.conversationID == summary.id {
      state.answerReadyBanner = nil
      effects.append(.cancel(id: CancelID.bannerTimeout))
    }
    if let active = state.activeTurn, active.conversationID == summary.id {
      // Deletion cancels the running turn, retaining its durable interruption
      // for manual Ask Again after Undo. It cannot consume automatic retry.
      state.seedRetry(active.questionID, conversationID: summary.id)
      state.retryJournals[active.questionID]?.intent = .cancelled(manualRequested: false)
      effects.append(interruptActiveTurn(state: &state, ambiguous: false))
    }
    if let preparation = state.followUpPreparation, preparation.conversationID == summary.id {
      state.pendingSuggestionContexts[summary.id] = PendingScopeDiagnosis(
        conversationID: summary.id, messageID: preparation.context.sourceAssistantMessageID,
        context: preparation.context, generation: preparation.generation,
        scopeDiagnosisCompleted: true)
      state.followUpPreparation = nil
      effects.append(.cancel(id: CancelID.followUpPreparation))
    }
    if let diagnosis = state.pendingScopeDiagnosis, diagnosis.conversationID == summary.id {
      state.pendingSuggestionContexts[summary.id] = diagnosis
      state.pendingScopeDiagnosis = nil
      state.isScopeDiagnosisInFlight = false
      effects.append(.cancel(id: CancelID.scopeDiagnosis))
    }
    if state.chat?.conversationID == summary.id {
      state.chat = nil
      if let next = state.visibleConversations.first {
        effects.append(loadConversationEffect(id: next.id))
      } else {
        effects.append(createConversationEffect())
      }
    }
    syncSchedulerProjection(into: &state)
    effects.append(
      .run { send in
        try await clock.sleep(for: .seconds(5))
        await send(.deleteCountdownFinished(token))
      }.cancellable(id: DeletionCountdownID(token: token)))
    return .merge(effects)
  }

  func commitOrDeferDeletion(state: inout State, conversationID: UUID) -> Effect<Action> {
    guard let deletion = state.conversationDeletions[conversationID],
      deletion.phase == .undoWindow || deletion.phase == .awaitingSettlement
    else { return .none }
    if state.hasOutstandingWrites(in: conversationID) {
      state.conversationDeletions[conversationID]?.phase = .awaitingSettlement
      return .none
    }
    state.conversationDeletions[conversationID]?.phase = .committing
    return commitDeletionEffect(conversationID: conversationID, token: deletion.token)
  }

  func finishDeferredDeletion(state: inout State, conversationID: UUID) -> Effect<Action> {
    guard state.conversationDeletions[conversationID]?.phase == .awaitingSettlement else {
      return .none
    }
    return commitOrDeferDeletion(state: &state, conversationID: conversationID)
  }

  func handleConversationWriteFailure(
    state: inout State,
    conversationID: UUID,
    failure: FailurePresentation
  ) -> Effect<Action> {
    if state.isConversationPendingDeletion(conversationID) {
      state.conversationDeletions[conversationID]?.deferredFailure = failure
      diagnostics.info(
        category: .history,
        code: "conversation_write_failure_deferred_for_undo",
        summary:
          "A conversation write failure is deferred until the pending deletion is resolved.")
      return .none
    }
    guard state.isConversationLive(conversationID) else {
      diagnostics.record(DiagnosticEvent(
        level: .error, category: .history,
        code: "conversation_write_failed_after_deletion",
        summary: "An obsolete conversation write failed after deletion.",
        details: failure.diagnostic,
        context: ["conversation_id": conversationID.uuidString, "failure_code": failure.code]))
      return .none
    }
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
        [
          optimisticTurn.isExisting ? nil : optimisticTurn.message.id,
          terminalMessageID,
        ].compactMap { $0 })
      state.chat?.messages.removeAll { messageIDs.contains($0.id) }
      if state.chat?.isManuallyTitled == false,
        let previousChatTitle = optimisticTurn.previousChatTitle
      {
        state.chat?.title = previousChatTitle
      }
    }

    if !optimisticTurn.isExisting,
      var previousSummary = optimisticTurn.previousSummary,
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

  func commitDeletionEffect(conversationID: UUID, token: UUID) -> Effect<Action> {
    .run { send in
      await messageUpdateQueue.beginDeletingConversation(conversationID)
      do {
        try await history.deleteConversation(conversationID)
        await messageUpdateQueue.confirmConversationDeletion(conversationID)
        await send(.conversationDeletionFinished(conversationID, token: token, failure: nil))
      } catch {
        await messageUpdateQueue.cancelConversationDeletion(conversationID)
        await send(
          .conversationDeletionFinished(
            conversationID, token: token, failure: .history(operation: .delete, error: error)))
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
    chat.queued = state.queue.filter {
      $0.conversationID == chat.conversationID && $0.retryJournalID == nil
    }
    // The interruption banner owns retry presentation: a journal that is
    // queued, being claimed, or being released shows "Retry queued" while
    // it remains wanted. A new Ask Again restores that presentation.
    var queuedRetries = Set(
      state.queue.compactMap {
        $0.conversationID == chat.conversationID ? $0.retryJournalID : nil
      })
    // During a claim, Ask Again clears cancellation before promoting it.
    // During a release, cancellation and promotion can coexist until decline
    // settles, so the release condition below retains both checks.
    if state.retryClaimConversationID == chat.conversationID,
      let claiming = state.retryClaimJournalID,
      !state.dismissedRetryJournalIDs.contains(claiming),
      !state.cancelledRetryJournalIDs.contains(claiming)
    {
      queuedRetries.insert(claiming)
    }
    if state.retryReleaseConversationID == chat.conversationID,
      let releasing = state.retryReleaseJournalID,
      !state.dismissedRetryJournalIDs.contains(releasing),
      !state.cancelledRetryJournalIDs.contains(releasing)
        || state.userPromotedRetryJournalIDs.contains(releasing)
    {
      queuedRetries.insert(releasing)
    }
    chat.queuedRetryJournalIDs = queuedRetries
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

  /// Callers refresh availability immediately before calling.
  func startLaunchBenchmarkIfReady(
    state: inout State
  ) -> Effect<Action> {
    guard
      let question = state.launchBenchmarkQuestion?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !question.isEmpty,
      !state.launchBenchmarkStarted,
      // A benchmark turn wipes the transcript and dispatches like any other
      // turn, so it takes the same gates. `canStartLowPriorityInference`
      // additionally keeps it off an in-flight preparation or capture: this
      // path does not clear `followUpPreparation` the way `.submitQuestion`
      // does, and dispatching over one would strand it non-nil forever once
      // its `.finished` event is dropped.
      state.canDispatchTurn,
      state.canStartLowPriorityInference,
      state.fmAvailability == .available,
      state.chat != nil
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
    mode: ModelRuntimeMode,
    attemptID: UUID
  ) -> Effect<Action> {
    .run { send in
      await ModelPreparationAttemptContext.$attemptID.withValue(attemptID) {
        var environment = preparationEnvironment.snapshot()
        environment["runtime_mode"] = mode.rawValue
        diagnostics.info(
          category: .model,
          code: "model_preparation_attempt_started",
          summary: "A SQL model preparation attempt started.",
          context: environment)
        await preparationJournal.begin(
          attemptID,
          mode,
          environment)
        guard !Task.isCancelled else { return }
        do {
          let report = try await pipeline.prepare(mode)
          guard !Task.isCancelled else { return }
          await preparationJournal.complete(report)
          await send(.modelPrepared(report, attemptID: attemptID))
        } catch {
          guard !Task.isCancelled else { return }
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
          await send(.modelPreparationFailed(failure, attemptID: attemptID))
        }
      }
    }
    .cancellable(id: CancelID.modelPreparation, cancelInFlight: true)
  }

  func suspendModelPreparation(state: inout State) -> Effect<Action> {
    guard let mode = state.modelPreparationModeInFlight,
      let attemptID = state.modelPreparationAttemptID
    else { return .none }
    state.modelPreparationModeInFlight = nil
    state.modelPreparationAttemptID = nil
    state.modelPreparationInFlight = false
    state.suspendedModelPreparationMode = mode
    state.drainingModelPreparationAttemptID = attemptID
    diagnostics.info(
      category: .model,
      code: "model_preparation_suspending",
      summary: "Model preparation is waiting for raw model work to settle.",
      context: ["runtime_mode": mode.rawValue])
    return .concatenate(
      .run { _ in await preparationJournal.requestSuspension(attemptID) },
      .cancel(id: CancelID.modelPreparation),
      .run { send in
        await pipeline.waitUntilInferenceIdle()
        await preparationJournal.completeSuspension(attemptID)
        await send(.modelPreparationSuspended(attemptID))
      })
  }

  func resumeSuspendedModelPreparation(state: inout State) -> Effect<Action> {
    guard state.isSceneActive,
      state.pressureGeneration == nil,
      !state.thermalPressure,
      !state.modelPreparationInFlight,
      state.isModelRecoveryIdle,
      state.modelReadiness == .preparing,
      let mode = state.suspendedModelPreparationMode
    else { return .none }
    state.suspendedModelPreparationMode = nil
    state.modelPreparationModeInFlight = mode
    state.modelPreparationInFlight = true
    let attemptID = uuid()
    state.modelPreparationAttemptID = attemptID
    return preparationEffect(mode: mode, attemptID: attemptID)
  }

  /// A retained Scope Verdict memo does not gate explicit preparation. The
  /// recovery context is parked until model maintenance finishes.
  func canStartModelPreparation(state: State) -> Bool {
    !state.modelPreparationInFlight
      && state.drainingModelPreparationAttemptID == nil
      && state.isSceneActive && state.pressureGeneration == nil
      && !state.thermalPressure
      && (state.modelReadiness == .ready
        ? state.isInferenceIdleIgnoringScopeDiagnosis
          || (state.activeTurn == nil && state.pendingInterruptedTurn == nil
            && state.pendingTurnPersistence == nil
            && !state.retryOperationsHoldScheduler
            && state.runnableQueue.allSatisfy(\.automaticRetry)
            && state.followUpPreparation == nil
            && !state.isCapturingAnswerability)
        : state.isModelRecoveryIdle)
  }

  func resumeRequestedModelPreparation(state: inout State) -> Effect<Action> {
    guard let mode = state.pendingPreparationRetryMode,
      canStartModelPreparation(state: state)
    else { return .none }
    state.pendingPreparationRetryMode = nil
    let abandonedDiagnosis = abandonScopeDiagnosisForModelMaintenance(state: &state)
    setModelReadiness(.preparing, state: &state)
    state.modelPreparationReport = nil
    state.modelPreparationInFlight = true
    state.modelPreparationModeInFlight = mode
    let attemptID = uuid()
    state.modelPreparationAttemptID = attemptID
    return .merge(abandonedDiagnosis, preparationEffect(mode: mode, attemptID: attemptID))
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
