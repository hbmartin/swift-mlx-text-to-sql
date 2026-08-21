import CREGEngine
import ComposableArchitecture
import Foundation

extension AppFeature {
  // MARK: - Scheduler (ADR 0008)

  /// Starts a turn immediately. Callers guarantee no turn is active.
  func dispatch(
    state: inout State,
    conversationID: UUID,
    submission: QuestionSubmission
  ) -> Effect<Action> {
    precondition(
      state.activeTurn == nil && state.pendingTurnPersistence == nil
        && state.modelReadiness == .ready
        && state.fmAvailability == .available,
      "Dispatch requires an idle, ready scheduler with Apple Intelligence available.")
    // A new turn owns the serializer; an in-flight scope diagnosis for an
    // older failure is abandoned rather than queued ahead of it.
    state.pendingScopeDiagnosis = nil
    state.isScopeDiagnosisInFlight = false
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
    let questionID = uuid()
    let startedAt = now
    let userMessage = ChatMessage(
      id: uuid(), role: .user, body: .text(question), createdAt: startedAt)
    let optimisticTurn = OptimisticUserTurn(
      message: userMessage,
      previousSummary: state.conversations[id: conversationID],
      previousChatTitle:
        state.chat?.conversationID == conversationID
        ? state.chat?.title
        : state.conversations[id: conversationID]?.title)
    var activeTurn = ActiveTurn(
      questionID: questionID,
      conversationID: conversationID,
      submission: submission,
      startedAt: startedAt)
    activeTurn.optimisticUserTurn = optimisticTurn
    state.activeTurn = activeTurn

    // Reflect the dispatch in whatever surfaces show this conversation.
    if state.chat?.conversationID == conversationID {
      state.chat?.messages.append(userMessage)
      if state.chat?.title.isEmpty == true,
        state.chat?.isManuallyTitled == false
      {
        state.chat?.title = HistoryStore.autoTitle(from: question)
      }
    }
    if var summary = state.conversations[id: conversationID] {
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

    let run: Effect<Action> = .run { send in
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
            conversationID, userMessage, question, startedAt)
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
      }
      guard !Task.isCancelled, !terminalEventSeen else { return }
      await send(
        .pipelineStreamEnded(
          conversationID: conversationID,
          questionID: questionID))
    }
    return .merge(
      .cancel(id: CancelID.scopeDiagnosis),
      .cancel(id: CancelID.answerabilityCapture),
      run.cancellable(id: CancelID.pipeline, cancelInFlight: true))
  }

  /// Visible-conversation priority: the oldest Queued Question in the
  /// selected Conversation, else the globally oldest.
  func dispatchNextIfIdle(state: inout State) -> Effect<Action> {
    // Persistence completion can happen long after the last scene-activation
    // snapshot. Re-read the synchronous system status before consuming a
    // queued item so a mid-foreground availability flip also fails closed.
    refreshFMAvailability(state: &state)
    guard state.activeTurn == nil, state.pendingTurnPersistence == nil,
      state.modelReadiness == .ready
    else { return .none }
    guard state.fmAvailability == .available else {
      return watchFMAvailabilityIfStranded(state: &state)
    }
    let visibleID = state.chat?.conversationID
    let next =
      state.queue.first { $0.conversationID == visibleID }
      ?? state.queue.first
    guard let next else { return .none }
    state.queue.removeAll { $0.id == next.id }
    return .merge(
      .cancel(id: CancelID.fmAvailabilityWatch),
      dispatch(
        state: &state,
        conversationID: next.conversationID,
        submission: next.submission))
  }

  /// fmAvailability is the one gate with no action to hook when it reopens:
  /// every other gate re-runs its work from a completion. While stranded work
  /// waits behind an unavailable Apple Intelligence — a Queued Question or a
  /// retained Scope Verdict memo — watch for recovery so it proceeds without
  /// waiting for the next scene activation. Recovery re-runs the scheduler,
  /// whose action also gives the low-priority resumes their chance. Entering
  /// the background cancels the watch.
  func watchFMAvailabilityIfStranded(state: inout State) -> Effect<Action> {
    refreshFMAvailability(state: &state)
    guard
      state.fmAvailability != .available,
      !state.queue.isEmpty || state.pendingScopeDiagnosis != nil
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
        do {
          try await operation()
        } catch {
          await send(
            .turnPersistenceFailed(
              conversationID: conversationID,
              questionID: questionID,
              failure: .history(operation: .messageSave, error: error)))
        }
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
      return .merge(
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
    let effects: [Effect<Action>] = [
      .cancel(id: CancelID.pipeline),
      stoppedTurnPersistenceEffect(
        active: active,
        terminalMessage: stoppedMessage,
        replacesExisting: false),
    ]
    return .merge(effects)
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
    let question = active.question
    let startedAt = active.startedAt
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
                question,
                startedAt)
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
              terminalMessage,
              replacesExisting,
              eventLines)
          }
        } catch {
          await send(
            .turnPersistenceFailed(
              conversationID: conversationID,
              questionID: questionID,
              failure: .history(operation: .messageSave, error: error)))
        }
        await send(.turnPersistenceFinished(questionID))
      },
      turnPersistenceWatchdog(questionID: questionID))
  }

}
