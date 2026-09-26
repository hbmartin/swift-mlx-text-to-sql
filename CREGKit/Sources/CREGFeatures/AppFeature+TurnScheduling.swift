import CREGEngine
import ComposableArchitecture
import Foundation

extension AppFeature {
  // MARK: - Scheduler (ADR 0008)

  func deactivateScene(state: inout State) -> Effect<Action> {
    state.isSceneActive = false
    let interrupted = state.activeTurn?.backgroundGPUGranted == true
      ? Effect<Action>.none : interruptActiveTurn(state: &state)
    let lowPriority = suspendLowPriorityInference(state: &state)
    let model = suspendModelPreparation(state: &state)
    return .merge(
      .cancel(id: CancelID.fmAvailabilityWatch),
      interrupted, lowPriority, model)
  }

  func resumeAfterPressure(state: inout State) -> Effect<Action> {
    guard state.isSceneActive else { return .none }
    refreshFMAvailability(state: &state)
    return .merge(
      resumeRequestedModelPreparation(state: &state),
      resumeSuspendedModelPreparation(state: &state),
      resumeInterruptedScopeDiagnosisIfIdle(state: &state),
      resumePendingSuggestionContextIfIdle(state: &state),
      resumeFollowUpPreparationIfIdle(state: &state),
      dispatchNextIfIdle(state: &state))
  }

  /// Starts a turn immediately. Callers guarantee no turn is active and the
  /// scene is foregrounded; asserting `canDispatchTurn` here is what keeps
  /// the deactivation invariant from being a per-call-site convention a new
  /// start path can forget.
  func dispatch(
    state: inout State,
    conversationID: UUID,
    submission: QuestionSubmission,
    existingUserMessage: ChatMessage? = nil,
    autoRetryCount: Int = 0,
    isAutomaticRetry: Bool = false,
    directlyUserStarted: Bool = true,
    replacingJournalID: UUID? = nil
  ) -> Effect<Action> {
    precondition(
      state.canDispatchTurn && state.fmAvailability == .available,
      "Dispatch requires an active scene and an idle, ready scheduler with Apple Intelligence available."
    )
    // Every dispatch is an accepted question for its conversation: the
    // generation advances and the retired batch is deleted in the preflight
    // transaction before the pipeline runs.
    let suggestionGeneration = acceptQuestion(
      state: &state, conversationID: conversationID)
    // A new turn owns the serializer; an in-flight scope diagnosis for an
    // older failure is parked rather than queued ahead of it — unless the
    // dispatch just retired its generation, in which case it is dropped.
    if let pending = state.pendingScopeDiagnosis,
      ownsSuggestions(
        state: state, conversationID: pending.conversationID,
        generation: pending.generation)
    {
      state.pendingSuggestionContexts[pending.conversationID] = pending
    }
    state.pendingScopeDiagnosis = nil
    state.isScopeDiagnosisInFlight = false
    state.followUpPreparation = nil
    if state.isCapturingAnswerability {
      // Cancellation drops the effect's completion action, so this is the
      // only record that the capture died rather than finishing.
      diagnostics.info(
        category: .model,
        code: "answerability_capture_cancelled",
        summary:
          "A dispatched turn cancelled the in-flight answerability capture; no export was produced.")
    }
    state.isCapturingAnswerability = false
    state.answerabilityCaptureID = nil
    let question = submission.question
    let startedAt = now
    let userMessage = existingUserMessage ?? ChatMessage(
      id: uuid(), role: .user, body: .text(question), createdAt: startedAt)
    let questionID = userMessage.id
    let optimisticTurn = OptimisticUserTurn(
      message: userMessage,
      previousSummary: state.conversations[id: conversationID],
      previousChatTitle:
        state.chat?.conversationID == conversationID
        ? state.chat?.title
        : state.conversations[id: conversationID]?.title,
      isExisting: existingUserMessage != nil)
    var activeTurn = ActiveTurn(
      questionID: questionID,
      conversationID: conversationID,
      submission: submission,
      startedAt: startedAt)
    activeTurn.autoRetryCount = autoRetryCount
    activeTurn.isAutomaticRetry = isAutomaticRetry
    activeTurn.directlyUserStarted = directlyUserStarted
    activeTurn.replacingJournalID = replacingJournalID
    activeTurn.suggestionGeneration = suggestionGeneration
    if let replacingJournalID {
      activeTurn.replacedInterruptedTurn = state.chat?.interruptedTurns.first {
        $0.journalID == replacingJournalID
      }
      // The transferred journal keeps the count it already spent, so the
      // dispatched turn carries it too and never re-arms automatic retry.
      if existingUserMessage == nil,
        let replaced = activeTurn.replacedInterruptedTurn
      {
        activeTurn.autoRetryCount = max(autoRetryCount, replaced.autoRetryCount)
      }
    }
    activeTurn.optimisticUserTurn = optimisticTurn
    state.activeTurn = activeTurn
    if let replacingJournalID, state.chat?.conversationID == conversationID {
      state.chat?.interruptedTurns.removeAll { $0.journalID == replacingJournalID }
    }

    // Reflect the dispatch in whatever surfaces show this conversation.
    if existingUserMessage == nil,
      state.chat?.conversationID == conversationID
    {
      state.chat?.messages.append(userMessage)
      if state.chat?.title.isEmpty == true,
        state.chat?.isManuallyTitled == false
      {
        state.chat?.title = HistoryStore.autoTitle(from: question)
      }
    }
    if existingUserMessage == nil,
      var summary = state.conversations[id: conversationID]
    {
      if summary.title.isEmpty, !summary.isManuallyTitled {
        summary.title = HistoryStore.autoTitle(from: question)
      }
      summary.lastActivityAt = startedAt
      summary.latestMessagePreview = question
      summary.messageCount += 1
      state.conversations[id: conversationID] = summary
      state.conversations.sort { $0.lastActivityAt > $1.lastActivityAt }
    }
    syncSchedulerProjection(into: &state)

    diagnostics.info(
      category: .submission,
      code: "chat_submission_committed",
      summary: "A submission started a pipeline turn.",
      context: [
        "query_origin": submission.source.queryOrigin.rawValue,
        "queue_depth": String(state.queue.count),
      ])

    return .concatenate(
      .cancel(id: CancelID.followUpPreparation),
      .cancel(id: CancelID.scopeDiagnosis),
      .cancel(id: CancelID.answerabilityCapture),
      .run { send in
        try? await history.acceptQuestion(conversationID, suggestionGeneration)
        await send(.dispatchPreflightFinished(
          questionID: questionID, directlyUserStarted: directlyUserStarted))
      })
  }

  // MARK: - Suggestion ownership

  /// Advances the conversation's suggestion generation in memory and retires
  /// everything the previous generation owned: visible chips, the parked
  /// context, and the in-flight judge. The durable advance travels with the
  /// caller's effect so the counter only ever moves forward.
  @discardableResult
  func acceptQuestion(state: inout State, conversationID: UUID) -> Int {
    guard var summary = state.conversations[id: conversationID] else {
      return 0
    }
    summary.suggestionGeneration += 1
    state.conversations[id: conversationID] = summary
    state.pendingSuggestionContexts.removeValue(forKey: conversationID)
    if state.pendingScopeDiagnosis?.conversationID == conversationID {
      state.pendingScopeDiagnosis = nil
      state.isScopeDiagnosisInFlight = false
    }
    if state.chat?.conversationID == conversationID {
      state.chat?.followUpBatch = nil
    }
    return summary.suggestionGeneration
  }

  /// A context, batch, or preparation may be parked, resumed, or displayed
  /// only while its generation is the conversation's current one.
  func ownsSuggestions(
    state: State, conversationID: UUID, generation: Int
  ) -> Bool {
    state.conversations[id: conversationID]?.suggestionGeneration == generation
  }

  // MARK: - Retry queue

  /// Inserts by original question time so a retry precedes every later
  /// question in its conversation while the queue stays oldest-first.
  func insertQueuedQuestion(_ queued: QueuedQuestion, into state: inout State) {
    let index = state.queue.firstIndex {
      $0.submittedAt > queued.submittedAt
    } ?? state.queue.endIndex
    state.queue.insert(queued, at: index)
    syncSchedulerProjection(into: &state)
  }

  /// The banner's cancel: the queued retry leaves the queue, its automatic
  /// allowance is declined, and the journal row survives for Ask Again. A
  /// claim or release still in flight for the journal completes as a
  /// cancellation instead of dispatching.
  func cancelQueuedRetry(
    state: inout State, conversationID: UUID, journalID: UUID
  ) -> Effect<Action> {
    state.queue.removeAll {
      $0.conversationID == conversationID && $0.retryJournalID == journalID
    }
    state.automaticRetryCandidates.removeValue(forKey: journalID)
    state.userPromotedRetryJournalIDs.remove(journalID)
    if state.retryClaimJournalID == journalID
      || state.retryReleaseJournalID == journalID
    {
      state.cancelledRetryJournalIDs.insert(journalID)
    }
    if state.chat?.conversationID == conversationID,
      let index = state.chat?.interruptedTurns.firstIndex(where: {
        ($0.journalID ?? $0.executionID) == journalID
      })
    {
      state.chat?.interruptedTurns[index].status = .manualRetryRequired
    }
    syncSchedulerProjection(into: &state)
    diagnostics.info(
      category: .submission,
      code: "queued_retry_cancelled",
      summary: "A queued retry was cancelled; the journal remains for Ask Again.")
    return .merge(
      .run { send in
        do {
          try await history.declineAutoRetry(conversationID, journalID)
        } catch {
          await send(.operationFailed(
            .history(operation: .messageSave, error: error)))
        }
      },
      dispatchNextIfIdle(state: &state))
  }

  func resumeDispatchedTurnAfterPreflight(
    state: inout State
  ) -> Effect<Action> {
    guard let active = state.activeTurn, active.preflightCompleted,
      !active.pipelineStarted
    else { return .none }
    guard state.conversations[id: active.conversationID] != nil,
      state.pendingDeletion?.summary.id != active.conversationID
    else {
      state.activeTurn = nil
      if state.chat?.conversationID == active.conversationID {
        if let optimistic = active.optimisticUserTurn, !optimistic.isExisting {
          state.chat?.messages.remove(id: optimistic.message.id)
        }
        if let replaced = active.replacedInterruptedTurn {
          state.chat?.interruptedTurns.append(replaced)
        }
      }
      syncSchedulerProjection(into: &state)
      return .send(.dispatchNextIfIdle)
    }
    guard state.isSceneActive, state.modelReadiness == .ready else {
      return .none
    }
    state.activeTurn?.pipelineStarted = true
    return runDispatchedTurn(
      active: active, directlyUserStarted: active.directlyUserStarted)
  }

  func runDispatchedTurn(
    active: ActiveTurn,
    directlyUserStarted: Bool
  ) -> Effect<Action> {
    guard let optimisticTurn = active.optimisticUserTurn else { return .none }
    let conversationID = active.conversationID
    let questionID = active.questionID
    let userMessage = optimisticTurn.message
    let submission = active.submission
    let startedAt = active.startedAt
    let replacingJournalID = active.replacingJournalID
    let question = active.question
    return .run { send in
      // Unstructured so a Stop cancellation cannot abort the user-message
      // write. Stop coalesces onto this same once-save before writing its
      // terminal message, so the prerequisite remains ordered even when Stop
      // arrives before this effect is scheduled.
      let persistDispatch = Task {
        try await messageUpdateQueue.saveOnce(
          conversationID: conversationID,
          messageID: userMessage.id
        ) {
          try await history.persistUserTurn(
            conversationID, userMessage, submission, startedAt, replacingJournalID)
        }
      }
      let persistenceOutcome: MessageUpdateQueue.SaveOutcome
      do {
        persistenceOutcome = try await persistDispatch.value
      } catch {
        await send(
          .userTurnPersistenceFailed(
            conversationID: conversationID,
            questionID: questionID,
            optimisticTurn: optimisticTurn,
            failure: .history(operation: .messageSave, error: error)))
        return
      }
      guard persistenceOutcome == .saved else {
        await send(
          .userTurnPersistenceFailed(
            conversationID: conversationID,
            questionID: questionID,
            optimisticTurn: optimisticTurn,
            failure: nil))
        return
      }
      guard !Task.isCancelled else { return }
      // Loading after the atomic user write is safe: conversationTurns ignores
      // the trailing unanswered user message and still returns only completed
      // exchanges from ADR 0008.
      let turns: [ConversationTurn]
      switch submission.source {
      case .preparedFollowUp, .starter:
        turns = []
      case .freeForm:
        let snapshot = try? await history.loadConversation(conversationID)
        turns = ChatFeature.conversationTurns(from: snapshot?.messages ?? [])
      }
      guard !Task.isCancelled else { return }
      let backgroundGranted = await backgroundTurn.begin(
        questionID, directlyUserStarted)
      if Task.isCancelled { return }
      await send(.backgroundTurnReady(
        executionID: questionID, granted: backgroundGranted))
      guard !Task.isCancelled else { return }
      let events: AsyncStream<PipelineEvent> =
        switch submission.source {
        case .freeForm:
          pipeline.run(question, turns)
        case .starter(let starter):
          pipeline.runStarter(starter)
        case .preparedFollowUp(let prepared):
          pipeline.runPrepared(prepared, [])
        }
      var terminalEventSeen = false
      for await event in events {
        if case .turnFinished = event {
          terminalEventSeen = true
        }
        await send(
          .pipelineEvent(
            conversationID: conversationID,
            questionID: questionID,
            event: event))
        await backgroundTurn.progress(questionID, event)
      }
      guard !Task.isCancelled, !terminalEventSeen else { return }
      await send(
        .pipelineStreamEnded(
          conversationID: conversationID,
          questionID: questionID))
    }
    .cancellable(id: CancelID.pipeline, cancelInFlight: true)
  }

  /// Without a granted background-GPU task, background entry stops the turn.
  /// The journal write owns the scheduler barrier;
  /// the serializer independently keeps any cancelled raw model call's slot
  /// until it actually settles.
  func interruptActiveTurn(
    state: inout State,
    ambiguous: Bool = false
  ) -> Effect<Action> {
    guard let active = state.activeTurn else { return .none }
    if let provisionalID = active.provisionalAssistantMessageID,
      case .preparedFollowUp(let prepared) = active.submission.source
    {
      state.activeTurn = nil
      state.pendingTurnPersistence = PendingTurnPersistence(
        questionID: active.questionID,
        conversationID: active.conversationID)
      state.pendingTurnPersistence?.userMessageID = active.optimisticUserTurn?.message.id
      state.pendingTurnPersistence?.replacedInterruptedTurn = active.replacedInterruptedTurn
      var telemetry = prepared.preparationTelemetry
      telemetry.narrationUsedFM = false
      telemetry.terminalError = "Prepared narration was interrupted; the validated result was retained."
      let finalized = ChatMessage(
        id: provisionalID, role: .assistant,
        body: .answer(
          result: prepared.result,
          narration: PreparedAnswerFallback.narration(for: prepared.result),
          sql: prepared.sql, notice: nil),
        traceSteps: active.trace, createdAt: now,
        devInfo: telemetry,
        resultPresentation: active.resultPresentationPreference)
      if state.chat?.conversationID == active.conversationID,
        let index = state.chat?.messages.index(id: provisionalID)
      {
        state.chat?.messages[index] = finalized
      }
      state.pendingTurnPersistence?.terminalMessageID = provisionalID
      updateSummaryAfterMessage(
        state: &state, conversationID: active.conversationID,
        message: finalized, replacing: true)
      syncSchedulerProjection(into: &state)
      return .concatenate(
        .cancel(id: CancelID.pipeline),
        stoppedTurnPersistenceEffect(
          active: active, terminalMessage: finalized, replacesExisting: true))
    }
    state.activeTurn = nil
    var interrupted = active
    interrupted.interruptionAmbiguous = ambiguous
    state.pendingInterruptedTurn = interrupted
    syncSchedulerProjection(into: &state)
    diagnostics.info(
      category: .submission,
      code: "chat_turn_interrupted",
      summary: "A scene interruption stopped the active model turn.",
      context: [
        "execution_id": active.questionID.uuidString,
        "ambiguous": String(ambiguous),
      ])
    return .concatenate(
      .cancel(id: CancelID.pipeline),
      .run { send in
        await backgroundTurn.finish(active.questionID, false)
        guard let optimistic = active.optimisticUserTurn else {
          await send(.turnInterruptionRecorded(
            questionID: active.questionID,
            userPersisted: false, marked: false))
          return
        }
        do {
          let outcome = try await messageUpdateQueue.saveOnce(
            conversationID: active.conversationID,
            messageID: optimistic.message.id
          ) {
            try await history.persistUserTurn(
              active.conversationID,
              optimistic.message,
              active.submission,
              active.startedAt,
              active.replacingJournalID)
          }
          guard outcome == .saved else {
            await send(.turnInterruptionRecorded(
              questionID: active.questionID,
              userPersisted: false, marked: false))
            return
          }
        } catch {
          await send(.turnInterruptionRecorded(
            questionID: active.questionID,
            userPersisted: false, marked: false))
          await send(.operationFailed(
            .history(operation: .messageSave, error: error)))
          return
        }
        do {
          try await history.markTurnInterrupted(
            active.conversationID, active.questionID, ambiguous)
          await send(.turnInterruptionRecorded(
            questionID: active.questionID,
            userPersisted: true, marked: true))
        } catch {
          await send(.turnInterruptionRecorded(
            questionID: active.questionID,
            userPersisted: true, marked: false))
          await send(.operationFailed(
            .history(operation: .messageSave, error: error)))
        }
      })
  }

  /// Automatic: enqueue every eligible same-process candidate and run the
  /// scheduler. Manual (Ask Again): the request becomes a queued retry for
  /// the visible conversation, ordered by its original question time, and
  /// the scheduler claims it through the same path every queued retry uses.
  /// If a claim is already in flight, the request promotes it instead.
  func claimInterruptedRetry(
    state: inout State,
    automatic: Bool,
    journalID requestedID: UUID? = nil
  ) -> Effect<Action> {
    if automatic {
      enqueueEligibleAutomaticRetry(state: &state)
      return dispatchNextIfIdle(state: &state)
    }
    guard let chat = state.chat,
      let interrupted = chat.interruptedTurns.first(where: {
        let candidateID = $0.journalID ?? $0.executionID
        guard let candidateID,
          (!state.dismissedRetryJournalIDs.contains(candidateID)
            || (state.failedDismissalManualRetryIDs.contains(candidateID)
              && !state.retryClaimInFlight
              && state.retryClaimCleanupJournalID == nil))
        else { return false }
        if let requestedID { return $0.journalID == requestedID }
        return true
      }),
      state.conversations[id: chat.conversationID] != nil,
      state.pendingDeletion?.summary.id != chat.conversationID
    else { return .none }
    let last = chat.messages.last
    let trailingMessage: ChatMessage? = {
      guard let last, last.role == .user,
        case .text(let savedQuestion) = last.body,
        savedQuestion == interrupted.question,
        interrupted.executionID == nil || interrupted.executionID == last.id
      else { return nil }
      return last
    }()
    let resolvedJournalID = interrupted.journalID ?? interrupted.executionID
      ?? trailingMessage?.id
    guard let resolvedJournalID else { return .none }
    if state.failedDismissalManualRetryIDs.remove(resolvedJournalID) != nil {
      state.dismissedRetryJournalIDs.remove(resolvedJournalID)
    }
    state.cancelledRetryJournalIDs.remove(resolvedJournalID)
    // An Ask Again request supersedes the automatic allowance; it is never
    // replenished by the manual request.
    state.automaticRetryCandidates.removeValue(forKey: resolvedJournalID)
    if let index = state.queue.firstIndex(where: {
      $0.retryJournalID == resolvedJournalID
    }) {
      state.queue[index].automaticRetry = false
      state.userPromotedRetryJournalIDs.insert(resolvedJournalID)
      syncSchedulerProjection(into: &state)
      return dispatchNextIfIdle(state: &state)
    }
    if state.retryClaimJournalID == resolvedJournalID
      || state.retryReleaseJournalID == resolvedJournalID
    {
      state.userPromotedRetryJournalIDs.insert(resolvedJournalID)
      return .none
    }
    let submission = QuestionSubmission(
      question: interrupted.question, source: interrupted.source)
    insertQueuedQuestion(
      QueuedQuestion(
        id: uuid(), conversationID: chat.conversationID,
        submission: submission, retryJournalID: resolvedJournalID,
        existingUserMessage: trailingMessage,
        automaticRetry: false,
        submittedAt: trailingMessage?.createdAt ?? now),
      into: &state)
    diagnostics.info(
      category: .submission,
      code: "chat_interrupted_turn_retry_queued",
      summary: "An Ask Again request was queued for the scheduler.",
      context: ["retries_in_place": String(trailingMessage != nil)])
    return dispatchNextIfIdle(state: &state)
  }

  func settleDismissedRetryClaim(
    state: inout State,
    conversationID: UUID,
    journalID: UUID,
    claimed: Bool
  ) -> Effect<Action> {
    state.retryClaimCleanupJournalID = journalID
    return .run { send in
      // A failed dismissal must restore Ask Again without re-arming an
      // automatic claim that may already have consumed its budget.
      if claimed {
        try? await history.declineAutoRetry(conversationID, journalID)
      }
      await send(.dismissedRetryClaimSettled(journalID))
    }
  }

  /// A claimed retry cannot live in the in-memory queue. Persist the release
  /// before allowing another claim or dispatch to use the journal. The
  /// release names the claim kind so an automatic claim restores its unused
  /// allowance while a manual claim leaves the durable count alone.
  func releaseRetryClaim(
    state: inout State,
    queued: QueuedQuestion
  ) -> Effect<Action> {
    guard let journalID = queued.retryJournalID,
      let executionID = queued.existingUserMessage?.id
    else { return .send(.dispatchNextIfIdle) }
    state.retryReleaseJournalID = journalID
    syncSchedulerProjection(into: &state)
    return .run { send in
      do {
        try await history.releaseAutoRetryClaim(
          queued.conversationID, journalID, executionID, queued.automaticRetry)
        await send(.retryClaimReleased(queued, true))
      } catch {
        await send(.retryClaimReleased(queued, false))
        await send(.operationFailed(
          .history(operation: .messageSave, error: error)))
      }
    }
  }

  /// Queues every same-process candidate that is not already queued,
  /// claimed, releasing, dismissed, or cancelled. Selection is irrelevant:
  /// the entry is built from the interrupted turn's own data, and a
  /// deactivated scene merely leaves it waiting for the next open gate.
  func enqueueEligibleAutomaticRetry(state: inout State) {
    let candidates = state.automaticRetryCandidates.values.sorted {
      $0.userMessage.createdAt < $1.userMessage.createdAt
    }
    for candidate in candidates {
      let journalID = candidate.journalID
      guard state.conversations[id: candidate.conversationID] != nil,
        state.pendingDeletion?.summary.id != candidate.conversationID,
        !state.dismissedRetryJournalIDs.contains(journalID),
        !state.cancelledRetryJournalIDs.contains(journalID),
        state.retryClaimJournalID != journalID,
        state.retryReleaseJournalID != journalID,
        state.activeTurn?.questionID != journalID,
        state.pendingInterruptedTurn?.questionID != journalID,
        !state.queue.contains(where: { $0.retryJournalID == journalID })
      else { continue }
      insertQueuedQuestion(
        QueuedQuestion(
          id: uuid(), conversationID: candidate.conversationID,
          submission: candidate.submission,
          retryJournalID: journalID,
          existingUserMessage: candidate.userMessage,
          automaticRetry: true,
          submittedAt: candidate.userMessage.createdAt),
        into: &state)
    }
  }

  func suspendLowPriorityInference(state: inout State) -> Effect<Action> {
    let preparation = state.followUpPreparation
    state.followUpPreparation = nil
    state.isScopeDiagnosisInFlight = false
    state.isCapturingAnswerability = false
    state.answerabilityCaptureID = nil
    let traceWrite: Effect<Action> =
      if let preparation, !preparation.eventLines.isEmpty {
        .run { _ in
          try? await history.appendEvents(
            preparation.conversationID,
            preparation.context.sourceAssistantMessageID,
            preparation.eventLines)
        }
      } else {
        .none
      }
    return .merge(
      .cancel(id: CancelID.followUpPreparation),
      .cancel(id: CancelID.scopeDiagnosis),
      .cancel(id: CancelID.answerabilityCapture),
      traceWrite)
  }

  /// Visible-conversation priority: the oldest Queued Question in the
  /// selected Conversation, else the globally oldest.
  func dispatchNextIfIdle(state: inout State) -> Effect<Action> {
    // Persistence completion can happen long after the last scene-activation
    // snapshot. Re-read the synchronous system status before consuming a
    // queued item so a mid-foreground availability flip also fails closed.
    refreshFMAvailability(state: &state)
    enqueueEligibleAutomaticRetry(state: &state)
    let requestedModel = resumeRequestedModelPreparation(state: &state)
    if state.modelPreparationInFlight { return requestedModel }
    guard state.canDispatchTurn else { return .none }
    guard state.fmAvailability == .available else {
      return watchFMAvailabilityIfStranded(state: &state)
    }
    if state.retryClaimInFlight || state.retryReleaseJournalID != nil { return .none }
    let visibleID = state.chat?.conversationID
    let next =
      state.queue.first { $0.conversationID == visibleID }
      ?? state.queue.first
    guard let next else { return .none }
    state.queue.removeAll { $0.id == next.id }
    guard state.conversations[id: next.conversationID] != nil,
      state.pendingDeletion?.summary.id != next.conversationID
    else {
      syncSchedulerProjection(into: &state)
      return .send(.dispatchNextIfIdle)
    }
    if let journalID = next.retryJournalID, let userMessage = next.existingUserMessage {
      state.retryClaimInFlight = true
      state.retryClaimJournalID = journalID
      state.retryClaimConversationID = next.conversationID
      syncSchedulerProjection(into: &state)
      return .run { send in
        do {
          let retryCount = try await history.claimTurnRetry(
            next.conversationID, journalID, userMessage.id, next.automaticRetry)
          await send(.queuedRetryClaimed(next, retryCount))
        } catch {
          await send(.queuedRetryClaimed(next, nil))
          await send(.operationFailed(.history(operation: .messageSave, error: error)))
        }
      }
    }
    return .merge(
      .cancel(id: CancelID.fmAvailabilityWatch),
      dispatch(
        state: &state,
        conversationID: next.conversationID,
        submission: next.submission,
        existingUserMessage: next.existingUserMessage,
        directlyUserStarted: false,
        replacingJournalID: next.existingUserMessage == nil ? next.retryJournalID : nil))
  }

  /// fmAvailability is the one gate with no action to hook when it reopens:
  /// every other gate re-runs its work from a completion. While stranded work
  /// waits behind an unavailable Apple Intelligence — a Queued Question, a
  /// retained Scope Verdict memo, a persisted `.preparing` batch — watch for
  /// recovery so it proceeds without waiting for the next scene activation.
  /// Recovery re-runs the scheduler, whose action also gives the low-priority
  /// resumes their chance.
  ///
  /// An inactive scene never arms one: the live stream polls
  /// `SystemLanguageModel.availability` on a timer, which is exactly the
  /// background work the deactivation invariant forbids, and its recovery
  /// send would be refused by the same invariant anyway. `.appBecameActive`
  /// re-arms through the scheduler; entering the background cancels the
  /// watch. Callers refresh availability immediately before calling, so this
  /// reads the value they just gated on rather than paying a second
  /// synchronous system read.
  func watchFMAvailabilityIfStranded(state: inout State) -> Effect<Action> {
    guard
      state.isSceneActive,
      state.fmAvailability != .available,
      !state.queue.isEmpty || state.pendingScopeDiagnosis != nil
        || !state.pendingSuggestionContexts.isEmpty
        || !state.automaticRetryCandidates.isEmpty
        || state.resumableFollowUpBatch != nil
    else { return .none }
    return .run { send in
      for await availability in fmStatus.availabilityUpdates() {
        guard availability == .available else { continue }
        await send(.dispatchNextIfIdle)
        return
      }
    }
    .cancellable(id: CancelID.fmAvailabilityWatch, cancelInFlight: true)
  }

  /// Keeps queue dispatch behind the completed turn's durable history write.
  /// The watchdog surfaces a stalled write but deliberately leaves this
  /// fail-closed ordering barrier intact.
  func turnPersistenceEffect(
    conversationID: UUID,
    questionID: UUID,
    operation: @escaping @Sendable () async throws -> Void
  ) -> Effect<Action> {
    .merge(
      .run { send in
        var persisted = false
        do {
          try await operation()
          persisted = true
        } catch {
          await send(
            .turnPersistenceFailed(
              conversationID: conversationID,
              questionID: questionID,
              failure: .history(operation: .messageSave, error: error)))
        }
        await send(.turnPersistenceWriteSettled(questionID))
        await backgroundTurn.finish(questionID, persisted)
        await send(.turnPersistenceFinished(questionID))
      },
      turnPersistenceWatchdog(questionID: questionID))
  }

  func turnPersistenceWatchdog(questionID: UUID) -> Effect<Action> {
    .run { send in
      try await clock.sleep(for: .seconds(5))
      await send(.turnPersistenceTimedOut(questionID))
    }
    .cancellable(
      id: TurnPersistenceTimeoutID(questionID: questionID),
      cancelInFlight: true)
  }

  func turnPersistenceDrainWatchdog(questionID: UUID) -> Effect<Action> {
    .run { send in
      try await clock.sleep(for: .seconds(5))
      await send(.turnPersistenceDrainTimedOut(questionID))
    }
    .cancellable(
      id: TurnPersistenceDrainTimeoutID(questionID: questionID),
      cancelInFlight: true)
  }

  func stopActiveTurn(state: inout State) -> Effect<Action> {
    guard let active = state.activeTurn,
      active.conversationID == state.chat?.conversationID
    else { return .none }
    precondition(
      state.pendingTurnPersistence == nil,
      "An active turn cannot stop while another persistence barrier exists.")
    state.activeTurn = nil
    state.pendingTurnPersistence = PendingTurnPersistence(
      questionID: active.questionID,
      conversationID: active.conversationID)
    state.pendingTurnPersistence?.userMessageID =
      active.optimisticUserTurn?.message.id
    state.pendingTurnPersistence?.replacedInterruptedTurn = active.replacedInterruptedTurn
    syncSchedulerProjection(into: &state)
    if let provisionalID = active.provisionalAssistantMessageID,
      case .preparedFollowUp(let prepared) = active.submission.source
    {
      let finalized = ChatMessage(
        id: provisionalID,
        role: .assistant,
        body: .answer(
          result: prepared.result,
          narration: PreparedAnswerFallback.narration(for: prepared.result),
          sql: prepared.sql,
          notice: nil),
        traceSteps: active.trace,
        createdAt: now,
        devInfo: prepared.preparationTelemetry,
        resultPresentation: active.resultPresentationPreference)
      if state.chat?.conversationID == active.conversationID,
        let index = state.chat?.messages.index(id: provisionalID)
      {
        state.chat?.messages[index] = finalized
      }
      state.pendingTurnPersistence?.terminalMessageID = finalized.id
      updateSummaryAfterMessage(
        state: &state,
        conversationID: active.conversationID,
        message: finalized,
        replacing: true)
      return .concatenate(
        .cancel(id: CancelID.pipeline),
        stoppedTurnPersistenceEffect(
          active: active,
          terminalMessage: finalized,
          replacesExisting: true))
    }
    let stoppedMessage = ChatMessage(
      id: uuid(), role: .assistant,
      body: .text("Stopped — ask again whenever you're ready."),
      traceSteps: active.trace, createdAt: now)
    if state.chat?.conversationID == active.conversationID {
      state.chat?.messages.append(stoppedMessage)
    }
    state.pendingTurnPersistence?.terminalMessageID = stoppedMessage.id
    updateSummaryAfterMessage(
      state: &state, conversationID: active.conversationID, message: stoppedMessage)
    diagnostics.info(
      category: .submission,
      code: "chat_turn_stopped",
      summary: "The user stopped the in-flight turn.",
      context: ["partial_event_count": String(active.eventLines.count)])
    return .concatenate(
      .cancel(id: CancelID.pipeline),
      stoppedTurnPersistenceEffect(
        active: active,
        terminalMessage: stoppedMessage,
        replacesExisting: false))
  }

  /// Stop may race the effect that persists the optimistic user message. Both
  /// paths coalesce on the same once-save, and the terminal write cannot begin
  /// until that prerequisite has durably succeeded.
  func stoppedTurnPersistenceEffect(
    active: ActiveTurn,
    terminalMessage: ChatMessage,
    replacesExisting: Bool
  ) -> Effect<Action> {
    let conversationID = active.conversationID
    let questionID = active.questionID
    let optimisticTurn = active.optimisticUserTurn
    let submission = active.submission
    let startedAt = active.startedAt
    let replacingJournalID = active.replacingJournalID
    let eventLines = active.eventLines
    return .merge(
      .run { send in
        if let optimisticTurn {
          let userOutcome: MessageUpdateQueue.SaveOutcome
          do {
            userOutcome = try await messageUpdateQueue.saveOnce(
              conversationID: conversationID,
              messageID: optimisticTurn.message.id
            ) {
              try await history.persistUserTurn(
                conversationID,
                optimisticTurn.message,
                submission,
                startedAt,
                replacingJournalID)
            }
          } catch {
            await send(
              .userTurnPersistenceFailed(
                conversationID: conversationID,
                questionID: questionID,
                optimisticTurn: optimisticTurn,
                failure: .history(operation: .messageSave, error: error)))
            await send(.turnPersistenceFinished(questionID))
            return
          }
          guard userOutcome == .saved else {
            await send(
              .userTurnPersistenceFailed(
                conversationID: conversationID,
                questionID: questionID,
                optimisticTurn: optimisticTurn,
                failure: nil))
            await send(.turnPersistenceFinished(questionID))
            return
          }
        }
        do {
          _ = try await messageUpdateQueue.save(
            conversationID: conversationID,
            messageID: terminalMessage.id
          ) {
            try await history.persistTerminalTurn(
              conversationID,
              questionID,
              terminalMessage,
              replacesExisting,
              eventLines)
          }
          await send(.turnPersistenceWriteSettled(questionID))
          await backgroundTurn.finish(questionID, true)
        } catch {
          await send(
            .turnPersistenceFailed(
              conversationID: conversationID,
              questionID: questionID,
              failure: .history(operation: .messageSave, error: error)))
          await send(.turnPersistenceWriteSettled(questionID))
          await backgroundTurn.finish(questionID, false)
        }
        await send(.turnPersistenceFinished(questionID))
      },
      turnPersistenceWatchdog(questionID: questionID))
  }

}
