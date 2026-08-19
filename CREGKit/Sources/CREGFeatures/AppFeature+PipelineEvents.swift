import CREGEngine
import ComposableArchitecture
import Foundation

extension AppFeature {
  func handlePipelineEvent(
    state: inout State,
    conversationID: UUID,
    questionID: UUID,
    event: PipelineEvent
  ) -> Effect<Action> {
    // A late event racing a stop or delete must not resurrect the turn.
    guard state.activeTurn?.questionID == questionID else { return .none }
    precondition(
      state.pendingTurnPersistence == nil,
      "An active turn cannot emit events while another persistence barrier exists.")
    if let line = event.traceLine {
      state.activeTurn?.trace.append(line)
    }
    if let json = try? event.jsonLine() {
      state.activeTurn?.eventLines.append(json)
    }
    if state.chat?.conversationID == conversationID {
      let trace = state.activeTurn?.trace ?? []
      state.chat?.processing?.trace = trace
    }
    if case .preparedResultReady(let prepared, _) = event {
      guard state.activeTurn?.provisionalAssistantMessageID == nil else {
        return .none
      }
      let messageID = uuid()
      state.activeTurn?.provisionalAssistantMessageID = messageID
      let provisional = ChatMessage(
        id: messageID,
        role: .assistant,
        body: .preparedAnswer(prepared),
        traceSteps: state.activeTurn?.trace ?? [],
        createdAt: now,
        devInfo: nil)
      state.activeTurn?.resultPresentationPreference = provisional.resultPresentation
      if state.chat?.conversationID == conversationID {
        state.chat?.messages.append(provisional)
      }
      updateSummaryAfterMessage(
        state: &state,
        conversationID: conversationID,
        message: provisional)
      return .run { send in
        do {
          _ = try await messageUpdateQueue.save(
            conversationID: conversationID,
            messageID: provisional.id
          ) {
            try await history.appendMessage(conversationID, provisional)
          }
        } catch {
          await send(
            .conversationWriteFailed(
              conversationID: conversationID,
              failure: .history(operation: .messageSave, error: error)))
        }
      }
    }
    guard case .turnFinished(let outcome, let telemetry) = event,
      let active = state.activeTurn
    else { return .none }

    let body: ChatMessage.Body =
      switch outcome {
      case .answered(let result, let narration, let sql, let notice):
        .answer(result: result, narration: narration, sql: sql, notice: notice)
      case .needsClarification(let question):
        .clarification(question)
      case .failed(let reason):
        .failedTurn(reason: reason, scopeVerdict: nil)
      }
    let assistantMessageID = active.provisionalAssistantMessageID ?? uuid()
    let assistantMessage = ChatMessage(
      id: assistantMessageID, role: .assistant, body: body,
      traceSteps: active.trace, createdAt: now,
      devInfo: telemetry,
      resultPresentation: active.resultPresentationPreference)
    let lines = active.eventLines
    state.activeTurn = nil
    state.pendingTurnPersistence = PendingTurnPersistence(
      questionID: active.questionID,
      conversationID: conversationID)
    state.pendingTurnPersistence?.userMessageID =
      active.optimisticUserTurn?.message.id

    diagnostics.info(
      category: .submission,
      code: "chat_turn_rendered",
      summary: "The terminal pipeline outcome was rendered.",
      context: [
        "outcome": outcomeName(outcome),
        "query_origin": telemetry.queryOrigin.rawValue,
        "execution_path": telemetry.executionPath.rawValue,
        "runtime_mode": telemetry.runtimeMode.rawValue,
        "evaluated": String(telemetry.isEvaluated),
        "confidence": telemetry.confidence?.rawValue ?? "none",
        "generated_count": String(telemetry.generatedCount),
        "repair_attempts": String(telemetry.repairAttempts),
        "recovery_outcome": telemetry.recoveryOutcome?.rawValue ?? "none",
        "timeout_stage": timeoutStage(telemetry.timeoutStage),
        "completed_in_background": String(
          state.chat?.conversationID != conversationID),
      ])

    let replacesProvisional = active.provisionalAssistantMessageID != nil
    state.pendingTurnPersistence?.terminalMessageID = assistantMessage.id
    var effects: [Effect<Action>] = [
      turnPersistenceEffect(
        conversationID: conversationID,
        questionID: active.questionID
      ) {
        _ = try await messageUpdateQueue.save(
          conversationID: conversationID,
          messageID: assistantMessage.id
        ) {
          try await history.persistTerminalTurn(
            conversationID, assistantMessage, replacesProvisional, lines)
        }
      }
    ]

    if state.chat?.conversationID == conversationID {
      if replacesProvisional,
        let index = state.chat?.messages.index(id: assistantMessage.id)
      {
        state.chat?.messages[index] = assistantMessage
      } else {
        state.chat?.messages.append(assistantMessage)
      }
    } else {
      // Background completion never changes the selected chat: mark the
      // Recent row unread, banner it, and emit a light haptic.
      state.conversations[id: conversationID]?.isUnread = true
      state.answerReadyBanner = AnswerReadyBanner(
        conversationID: conversationID,
        title: state.conversations[id: conversationID]?.displayTitle
          ?? "New Chat")
      effects.append(
        .run { _ in
          try? await history.setUnread(conversationID, true)
          await haptics.answerReady()
        })
      effects.append(
        .run { send in
          try await clock.sleep(for: .seconds(4))
          await send(.answerReadyBannerTimedOut)
        }
        .cancellable(id: CancelID.bannerTimeout, cancelInFlight: true))
    }
    updateSummaryAfterMessage(
      state: &state,
      conversationID: conversationID,
      message: assistantMessage,
      replacing: replacesProvisional)
    syncSchedulerProjection(into: &state)
    if state.activeTurn == nil, state.queue.isEmpty {
      switch outcome {
      case .answered(let result, let narration, _, _):
        state.pendingTurnPersistence?.followUpContext =
          FollowUpSuggestionContext(
            sourceAssistantMessageID: assistantMessage.id,
            question: active.question,
            standaloneQuestion: telemetry.standaloneQuestion,
            narration: narration,
            result: result)
      case .failed(let reason) where reason.isEligibleForRecoverySuggestions:
        state.pendingTurnPersistence?.followUpContext =
          FollowUpSuggestionContext(
            sourceAssistantMessageID: assistantMessage.id,
            question: active.question,
            standaloneQuestion: telemetry.standaloneQuestion,
            seed: .turnFailure(
              reason: reason, scopeVerdict: telemetry.scopeVerdict))
      case .failed, .needsClarification:
        break
      }
    }
    return .merge(effects)
  }

  func recoverFromUnterminatedPipelineStream(
    state: inout State,
    conversationID: UUID,
    questionID: UUID
  ) -> Effect<Action> {
    guard
      let active = state.activeTurn,
      active.questionID == questionID,
      active.conversationID == conversationID
    else { return .none }

    diagnostics.record(
      DiagnosticEvent(
        level: .error,
        category: .pipeline,
        code: "chat_pipeline_stream_recovered",
        summary: "A pipeline stream ended without a terminal event.",
        context: [
          "query_origin": active.submission.source.queryOrigin.rawValue,
          "provisional_result_visible": String(
            active.provisionalAssistantMessageID != nil),
        ]))

    let outcome: TurnOutcome
    var telemetry: TurnTelemetry
    if active.provisionalAssistantMessageID != nil,
      case .preparedFollowUp(let prepared) = active.submission.source
    {
      telemetry = prepared.preparationTelemetry
      telemetry.originalQuestion = prepared.question
      telemetry.standaloneQuestion = prepared.question
      telemetry.queryOrigin = .preparedFollowUp
      telemetry.executionPath = .preparedFollowUp
      telemetry.preparedFollowUpID = prepared.id
      telemetry.sourceAnswerMessageID = prepared.sourceAssistantMessageID
      telemetry.preparedCacheHit = true
      telemetry.narrationUsedFM = false
      telemetry.terminalError =
        "The prepared-answer stream ended without a terminal event."
      outcome = .answered(
        result: prepared.result,
        narration: PreparedAnswerFallback.narration(for: prepared.result),
        sql: prepared.sql,
        notice: nil)
    } else {
      telemetry = TurnTelemetry(
        originalQuestion: active.question,
        runtimeMode: state.modelPreparationReport?.mode ?? .evaluated)
      telemetry.queryOrigin = active.submission.source.queryOrigin
      telemetry.executionPath = active.submission.source.executionPath
      telemetry.terminalError =
        "The pipeline event stream ended without a terminal event."
      telemetry.failureReason = .unexpected
      outcome = .failed(reason: .unexpected)
    }
    return handlePipelineEvent(
      state: &state,
      conversationID: conversationID,
      questionID: questionID,
      event: .turnFinished(outcome: outcome, telemetry: telemetry))
  }

}
