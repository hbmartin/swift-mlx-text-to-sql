import CREGEngine
import ComposableArchitecture
import Foundation

extension ChatFeature {
  /// Commits the composer text as a submission; shared by the send path, the
  /// starter chips, and Ask Again. The parent decides whether it dispatches
  /// immediately or becomes a Queued Question.
  func commitSubmission(
    state: inout State,
    submittedQuestion: String? = nil,
    clearsComposer: Bool = true,
    starter: StarterQueryID? = nil,
    preparedFollowUp: PreparedFollowUp? = nil,
    clearsFollowUpBatch: Bool = true
  ) -> Effect<Action> {
    guard state.isSubmissionEnabled else { return .none }
    let question = (submittedQuestion ?? state.composerText)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty else { return .none }
    if clearsComposer { state.composerText = "" }
    if clearsFollowUpBatch { state.followUpBatch = nil }
    let conversationID = state.conversationID
    let source: QuestionSubmissionSource =
      if let preparedFollowUp {
        .preparedFollowUp(preparedFollowUp)
      } else if let starter {
        .starter(starter)
      } else {
        .freeForm
      }

    var effects: [Effect<Action>] = [
      .send(
        .delegate(
          .submitQuestion(
            QuestionSubmission(question: question, source: source))))
    ]
    if clearsComposer {
      effects.insert(
        .cancel(id: DraftSaveID(conversationID: conversationID)),
        at: 0)
      effects.insert(
        .run { _ in try? await history.saveDraft(conversationID, "") },
        at: 1)
    }

    // A pending Not right correction records the question that follows it.
    if let context = state.correctionContext,
      var existing = state.feedback[context.messageID]
    {
      existing.correction = question
      existing.updatedAt = now
      state.feedback[context.messageID] = existing
      state.correctionContext = nil
      let feedback = existing
      effects.append(
        .run { send in
          do {
            try await history.saveFeedback(conversationID, feedback)
          } catch {
            await send(
              .operationFailed(
                .history(operation: .feedbackSave, error: error)))
          }
        })
    }
    return .merge(effects)
  }

  /// Helpful and Not right are reversible: tapping the active verdict clears
  /// it, switching verdicts replaces it.
  func toggleFeedback(
    state: inout State,
    messageID: UUID,
    verdict: AnswerFeedback.Verdict
  ) -> Effect<Action> {
    let conversationID = state.conversationID
    if state.feedback[messageID]?.verdict == verdict {
      state.feedback[messageID] = nil
      if state.correctionContext?.messageID == messageID {
        state.correctionContext = nil
      }
      diagnostics.info(
        category: .history,
        code: "answer_feedback_cleared",
        summary: "An answer feedback judgment was reversed.")
      return .run { send in
        do {
          try await history.clearFeedback(conversationID, messageID)
        } catch {
          await send(
            .operationFailed(.history(operation: .feedbackSave, error: error)))
        }
      }
    }

    let runtimeMode =
      state.messages[id: messageID]?.devInfo?.runtimeMode ?? .evaluated
    let feedback = AnswerFeedback(
      messageID: messageID,
      verdict: verdict,
      updatedAt: now,
      runtimeMode: runtimeMode)
    state.feedback[messageID] = feedback
    switch verdict {
    case .helpful:
      if state.correctionContext?.messageID == messageID {
        state.correctionContext = nil
      }
    case .notRight:
      if case .answer(_, let narration, _, _)? = state.messages[id: messageID]?.body {
        state.correctionContext = CorrectionContext(
          messageID: messageID, answerNarration: narration)
      }
    }
    diagnostics.info(
      category: .history,
      code: "answer_feedback_recorded",
      summary: "An answer feedback judgment was recorded.",
      context: [
        "verdict": verdict.rawValue,
        "runtime_mode": runtimeMode.rawValue,
        "evaluated": String(runtimeMode.isEvaluated),
      ])
    return .run { send in
      do {
        try await history.saveFeedback(conversationID, feedback)
      } catch {
        await send(
          .operationFailed(.history(operation: .feedbackSave, error: error)))
      }
    }
  }

  /// Prior answered exchanges, oldest first, for the FM follow-up rewrite.
  public static func conversationTurns(
    from messages: some Sequence<ChatMessage>
  ) -> [ConversationTurn] {
    var turns: [ConversationTurn] = []
    var pendingQuestion: String?
    for message in messages {
      switch (message.role, message.body) {
      case (.user, .text(let question)):
        pendingQuestion = question
      case (.assistant, .answer(_, let narration, _, _)):
        if let question = pendingQuestion {
          turns.append(ConversationTurn(question: question, answerSummary: narration))
          pendingQuestion = nil
        }
      default:
        break
      }
    }
    return turns
  }
}
