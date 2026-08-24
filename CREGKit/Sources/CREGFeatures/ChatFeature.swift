import CREGEngine
import ComposableArchitecture
import Foundation

/// The Conversation reducer: one persisted, user-visible thread of portfolio
/// questions and CREG responses, with its own title and unsent draft
/// (CONTEXT.md "Conversation"). Global concerns — the single inference
/// pipeline, the cross-conversation queue, model readiness, and the
/// Conversation Browser — belong to ``AppFeature``.
@Reducer
public struct ChatFeature: Sendable {
  /// The in-flight turn this conversation is showing: a compact live status
  /// row with an expandable plain-English timeline.
  public struct ProcessingState: Equatable, Sendable {
    public var questionID: UUID
    public var question: String
    public var startedAt: Date
    public var trace: [String]
    public var isTimelineExpanded: Bool

    public init(
      questionID: UUID,
      question: String,
      startedAt: Date,
      trace: [String] = [],
      isTimelineExpanded: Bool = false
    ) {
      self.questionID = questionID
      self.question = question
      self.startedAt = startedAt
      self.trace = trace
      self.isTimelineExpanded = isTimelineExpanded
    }
  }

  /// Correction context shown above the composer after a Not right judgment;
  /// the next submitted question records as that answer's correction.
  public struct CorrectionContext: Equatable, Sendable {
    public var messageID: UUID
    public var answerNarration: String

    public init(messageID: UUID, answerNarration: String) {
      self.messageID = messageID
      self.answerNarration = answerNarration
    }
  }

  /// Narration-only Read Aloud playback for one answer.
  public struct ReadAloudState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
      case playing
      case paused
    }

    public var messageID: UUID
    public var phase: Phase

    public init(messageID: UUID, phase: Phase = .playing) {
      self.messageID = messageID
      self.phase = phase
    }
  }

  public struct ResultPresentationMigration: Equatable, Sendable {
    public var messageID: UUID
    public var previous: ResultPresentationPreference
    public var updated: ResultPresentationPreference

    public init(
      messageID: UUID,
      previous: ResultPresentationPreference,
      updated: ResultPresentationPreference
    ) {
      self.messageID = messageID
      self.previous = previous
      self.updated = updated
    }
  }

  @ObservableState
  public struct State: Equatable {
    public var conversationID: UUID
    public var title: String
    public var isManuallyTitled: Bool
    public var messages: IdentifiedArrayOf<ChatMessage>
    public var feedback: [UUID: AnswerFeedback]
    public var composerText: String
    /// Mirrors app-level model readiness so every reducer submission path,
    /// including prepared follow-up chips, can reject before mutating state.
    public var isSubmissionEnabled: Bool
    /// Keyboard-candidate protection owned by the reducer so every cancel and
    /// commit path is deterministic and testable.
    public var isSubmissionPending = false
    public var interruptedTurn: InterruptedTurn?
    public var correctionContext: CorrectionContext?
    public var readAloud: ReadAloudState?
    /// Maintained by ``AppFeature``: the active turn when it belongs to this
    /// conversation, and this conversation's Queued Questions.
    public var processing: ProcessingState?
    public var queued: [QueuedQuestion] = []
    /// Only the latest successful answer may own prepared follow-up chips.
    public var followUpBatch: PreparedFollowUpBatch?
    /// Full-screen Result Viewer presentation (the message whose result is
    /// being inspected).
    public var resultViewerMessageID: UUID?
    public var isRenamePresented = false
    public var renameDraft = ""
    /// Set after a successful JSONL export, consumed by the share sheet.
    public var exportURL: URL?
    public init(
      conversationID: UUID,
      title: String = "",
      isManuallyTitled: Bool = false,
      messages: IdentifiedArrayOf<ChatMessage> = [],
      feedback: [UUID: AnswerFeedback] = [:],
      composerText: String = "",
      isSubmissionEnabled: Bool = true,
      interruptedTurn: InterruptedTurn? = nil
    ) {
      self.conversationID = conversationID
      self.title = title
      self.isManuallyTitled = isManuallyTitled
      self.messages = messages
      self.feedback = feedback
      self.composerText = composerText
      self.isSubmissionEnabled = isSubmissionEnabled
      self.interruptedTurn = interruptedTurn
    }

    public init(
      snapshot: ConversationSnapshot,
      preservingActiveTurn: Bool = false,
      preservingPreparedAnswerID: UUID? = nil
    ) {
      let recoveredPreparedAnswer = snapshot.messages.contains {
        guard $0.id != preservingPreparedAnswerID else { return false }
        if case .preparedAnswer = $0.body { return true }
        return false
      }
      self.init(
        conversationID: snapshot.summary.id,
        title: snapshot.summary.title,
        isManuallyTitled: snapshot.summary.isManuallyTitled,
        messages: IdentifiedArray(
          uniqueElements: snapshot.messages.map {
            guard $0.id != preservingPreparedAnswerID else { return $0 }
            return $0.finalizedInterruptedPreparedAnswer ?? $0
          }),
        feedback: snapshot.feedback,
        composerText: snapshot.draft,
        interruptedTurn:
          recoveredPreparedAnswer || preservingActiveTurn
          ? nil : snapshot.interruptedTurn)
      self.followUpBatch = snapshot.followUpBatch
    }

    public var displayTitle: String {
      title.isEmpty ? "New Chat" : title
    }

    /// The composer shows Stop while this conversation owns the active turn.
    public var isProcessing: Bool { processing != nil }
  }

  public enum Action: BindableAction, Sendable, Equatable {
    case binding(BindingAction<State>)
    case draftSaveDebounced
    case submissionRequested
    case submissionFocusSettled
    case submissionRefocused
    case sendTapped
    case starterQuestionTapped(StarterQueryID)
    case preparedFollowUpTapped(UUID)
    case retryFailedTurnTapped(messageID: UUID)
    case stopTapped
    case cancelQueuedTapped(UUID)
    case askAgainTapped
    case interruptedDismissed
    case timelineExpansionToggled
    case feedbackHelpfulTapped(messageID: UUID)
    case feedbackNotRightTapped(messageID: UUID)
    case correctionDismissed
    case readAloudTapped(messageID: UUID)
    case readAloudPauseTapped
    case readAloudResumeTapped
    case readAloudStopTapped
    case readAloudFinished
    case resultViewerPresented(messageID: UUID)
    case resultViewerDismissed
    case resultPresentationChanged(
      messageID: UUID,
      preference: ResultPresentationPreference)
    /// Compare-and-set migration emitted by chart analysis. A second surface
    /// resolving the same stale preference is ignored after the first one
    /// updates state, while explicit identical user writes remain retryable.
    case resultPresentationMigrated(ResultPresentationMigration)
    case renameTapped
    case renameCommitted
    case exportTapped
    case exportReady(URL)
    case operationFailed(FailurePresentation)
    case delegate(Delegate)

    /// Global work only ``AppFeature`` can perform.
    public enum Delegate: Sendable, Equatable {
      case submitQuestion(QuestionSubmission)
      case stopActiveTurn
      case cancelQueued(UUID)
      case openBrowser
      case newChatRequested
      case deleteRequested
      case renamed(String)
    }
  }

  private enum CancelID {
    case readAloud
  }

  /// Conversation-scoped so switching conversations cannot cancel another
  /// conversation's pending draft write.
  struct DraftSaveID: Hashable {
    let conversationID: UUID
  }

  private let messageUpdateQueue: MessageUpdateQueue

  @Dependency(\.historyClient) var history
  @Dependency(\.readAloud) var readAloud
  @Dependency(\.date.now) var now
  @Dependency(\.continuousClock) var clock
  @Dependency(\.diagnostics) var diagnostics

  public init() {
    self.messageUpdateQueue = MessageUpdateQueue()
  }

  init(messageUpdateQueue: MessageUpdateQueue) {
    self.messageUpdateQueue = messageUpdateQueue
  }

  public var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.composerText):
        let conversationID = state.conversationID
        let draft = state.composerText
        return .run { _ in
          try await clock.sleep(for: .milliseconds(500))
          try await history.saveDraft(conversationID, draft)
        }
        .cancellable(
          id: DraftSaveID(conversationID: conversationID), cancelInFlight: true)

      case .binding:
        return .none

      case .draftSaveDebounced:
        return .none

      case .submissionRequested:
        guard
          !state.isSubmissionPending,
          !state.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          diagnostics.info(
            category: .submission,
            code: "chat_submission_rejected",
            summary: "A chat submission request was not eligible to start.",
            context: [
              "has_content": String(
                !state.composerText.trimmingCharacters(
                  in: .whitespacesAndNewlines
                ).isEmpty),
              "is_pending": String(state.isSubmissionPending),
            ])
          return .none
        }
        state.isSubmissionPending = true
        diagnostics.info(
          category: .submission,
          code: "chat_submission_pending",
          summary: "A chat submission is waiting for focus resignation.")
        return .none

      case .submissionRefocused:
        let wasPending = state.isSubmissionPending
        state.isSubmissionPending = false
        diagnostics.info(
          category: .submission,
          code: "chat_submission_refocus_cancelled",
          summary: "Composer refocus cancelled a pending submission.",
          context: ["was_pending": String(wasPending)])
        return .none

      case .submissionFocusSettled:
        guard state.isSubmissionPending else {
          diagnostics.info(
            category: .submission,
            code: "chat_submission_focus_settle_ignored",
            summary: "A focus-settled action had no pending submission.")
          return .none
        }
        state.isSubmissionPending = false
        diagnostics.info(
          category: .submission,
          code: "chat_submission_focus_settled",
          summary: "Focus resigned and the pending submission will commit.")
        return commitSubmission(state: &state)

      case .sendTapped:
        state.isSubmissionPending = false
        diagnostics.info(
          category: .submission,
          code: "chat_send_tapped",
          summary: "The send action was invoked.")
        return commitSubmission(state: &state)

      case .starterQuestionTapped(let starter):
        // Starter chips carry no typed keyboard candidates, so they bypass
        // the focus-settling latch and submit directly.
        state.isSubmissionPending = false
        diagnostics.info(
          category: .submission,
          code: "chat_starter_question_tapped",
          summary: "A starter-query chip submitted its reviewed query.",
          context: ["starter_query_id": starter.rawValue])
        return commitSubmission(
          state: &state,
          submittedQuestion: starter.question,
          clearsComposer: false,
          starter: starter)

      case .preparedFollowUpTapped(let id):
        guard state.isSubmissionEnabled else { return .none }
        guard
          let prepared = state.followUpBatch?.suggestions.first(where: {
            $0.id == id
          })
        else { return .none }
        state.isSubmissionPending = false
        diagnostics.info(
          category: .submission,
          code: "chat_prepared_follow_up_tapped",
          summary: "A prepared follow-up chip was submitted.")
        return commitSubmission(
          state: &state,
          submittedQuestion: prepared.question,
          clearsComposer: false,
          preparedFollowUp: prepared,
          clearsFollowUpBatch: false)

      case .retryFailedTurnTapped(let messageID):
        guard
          let message = state.messages[id: messageID],
          case .failedTurn = message.body,
          let question = message.devInfo?.originalQuestion,
          !question.isEmpty
        else { return .none }
        state.isSubmissionPending = false
        diagnostics.info(
          category: .submission,
          code: "chat_failed_turn_retried",
          summary: "A failed turn's Try again affordance resubmitted it.",
          context: [
            "failure_reason":
              message.devInfo?.failureReason?.label ?? "unknown"
          ])
        return commitSubmission(
          state: &state,
          submittedQuestion: question,
          clearsComposer: false,
          starter: message.devInfo?.starterQueryID)

      case .stopTapped:
        guard state.isProcessing else { return .none }
        return .send(.delegate(.stopActiveTurn))

      case .cancelQueuedTapped(let id):
        return .send(.delegate(.cancelQueued(id)))

      case .askAgainTapped:
        guard let interrupted = state.interruptedTurn else { return .none }
        state.interruptedTurn = nil
        state.composerText = interrupted.question
        let conversationID = state.conversationID
        diagnostics.info(
          category: .submission,
          code: "chat_interrupted_turn_resubmitted",
          summary: "An interrupted turn was resubmitted with Ask Again.")
        return .merge(
          .run { _ in try? await history.endTurnJournal(conversationID) },
          commitSubmission(state: &state))

      case .interruptedDismissed:
        state.interruptedTurn = nil
        let conversationID = state.conversationID
        return .run { _ in try? await history.endTurnJournal(conversationID) }

      case .timelineExpansionToggled:
        state.processing?.isTimelineExpanded.toggle()
        return .none

      case .feedbackHelpfulTapped(let messageID):
        return toggleFeedback(state: &state, messageID: messageID, verdict: .helpful)

      case .feedbackNotRightTapped(let messageID):
        return toggleFeedback(state: &state, messageID: messageID, verdict: .notRight)

      case .correctionDismissed:
        state.correctionContext = nil
        return .none

      case .readAloudTapped(let messageID):
        guard case .answer(_, let narration, _, _)? = state.messages[id: messageID]?.body
        else { return .none }
        state.readAloud = ReadAloudState(messageID: messageID)
        return .run { send in
          for await event in readAloud.speak(narration) {
            if event == .finished {
              await send(.readAloudFinished)
            }
          }
        }
        .cancellable(id: CancelID.readAloud, cancelInFlight: true)

      case .readAloudPauseTapped:
        guard state.readAloud?.phase == .playing else { return .none }
        state.readAloud?.phase = .paused
        return .run { _ in await readAloud.pause() }

      case .readAloudResumeTapped:
        guard state.readAloud?.phase == .paused else { return .none }
        state.readAloud?.phase = .playing
        return .run { _ in await readAloud.resume() }

      case .readAloudStopTapped:
        state.readAloud = nil
        return .merge(
          .cancel(id: CancelID.readAloud),
          .run { _ in await readAloud.stop() })

      case .readAloudFinished:
        state.readAloud = nil
        return .none

      case .resultViewerPresented(let messageID):
        state.resultViewerMessageID = messageID
        return .none

      case .resultViewerDismissed:
        state.resultViewerMessageID = nil
        return .none

      case .resultPresentationChanged(let messageID, let preference):
        return persistResultPresentation(
          state: &state,
          messageID: messageID,
          preference: preference)

      case .resultPresentationMigrated(let migration):
        guard
          state.messages[id: migration.messageID]?.resultPresentation
            == migration.previous
        else { return .none }
        return persistResultPresentation(
          state: &state,
          messageID: migration.messageID,
          preference: migration.updated)

      case .renameTapped:
        state.renameDraft = state.title
        state.isRenamePresented = true
        return .none

      case .renameCommitted:
        let title = state.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        state.isRenamePresented = false
        guard !title.isEmpty else { return .none }
        state.title = title
        state.isManuallyTitled = true
        let conversationID = state.conversationID
        return .merge(
          .send(.delegate(.renamed(title))),
          .run { send in
            do {
              try await history.renameConversation(conversationID, title)
            } catch {
              await send(
                .operationFailed(.history(operation: .rename, error: error)))
            }
          })

      case .exportTapped:
        let conversationID = state.conversationID
        diagnostics.info(
          category: .history,
          code: "history_export_started",
          summary: "Conversation export started.")
        return .run { send in
          let url = try await history.exportJSONL(conversationID)
          await send(.exportReady(url))
        } catch: { error, send in
          await send(
            .operationFailed(.history(operation: .export, error: error)))
        }

      case .exportReady(let url):
        state.exportURL = url
        diagnostics.info(
          category: .history,
          code: "history_export_finished",
          summary: "Conversation export finished.")
        return .none

      case .operationFailed:
        // Presented by AppFeature, which owns the failure surface.
        return .none

      case .delegate:
        return .none
      }
    }
  }

  private func persistResultPresentation(
    state: inout State,
    messageID: UUID,
    preference: ResultPresentationPreference
  ) -> Effect<Action> {
    guard var message = state.messages[id: messageID] else { return .none }
    message.resultPresentation = preference
    state.messages[id: messageID] = message
    let conversationID = state.conversationID
    let updatedMessage = message
    let revision = resultPresentationSaveRevisionCounter.next()
    return .run { send in
      do {
        try await messageUpdateQueue.save(
          conversationID: conversationID,
          messageID: updatedMessage.id,
          revision: revision
        ) {
          try await history.updateResultPresentation(
            conversationID, updatedMessage)
        }
      } catch {
        await send(
          .operationFailed(.history(operation: .messageSave, error: error)))
      }
    }
  }

}
