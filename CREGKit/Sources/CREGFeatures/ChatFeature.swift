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
  public enum FailureOrigin: Equatable, Sendable {
    case conversationWrite(UUID)
  }
  public enum FeedbackWrite: Equatable, Sendable {
    case save(AnswerFeedback)
    case clear(UUID)
  }

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
    public var interruptedTurns: [InterruptedTurn] = []
    public var interruptedTurn: InterruptedTurn? {
      get { interruptedTurns.first }
      set {
        if let newValue {
          if interruptedTurns.isEmpty { interruptedTurns = [newValue] }
          else { interruptedTurns[0] = newValue }
        } else if !interruptedTurns.isEmpty {
          interruptedTurns.removeFirst()
        }
      }
    }
    public var correctionContext: CorrectionContext?
    public var readAloud: ReadAloudState?
    /// Maintained by ``AppFeature``: the active turn when it belongs to this
    /// conversation, and this conversation's Queued Questions.
    public var processing: ProcessingState?
    public var queued: [QueuedQuestion] = []
    /// Maintained by ``AppFeature``: interruption journals whose retry is
    /// queued, being claimed, or being released, so the banner can show
    /// "Retry queued" with a cancel action instead of Ask Again.
    public var queuedRetryJournalIDs: Set<UUID> = []
    public var inspectingRetryJournalIDs: Set<UUID> = []
    /// Only the latest successful answer may own prepared follow-up chips.
    public var followUpBatch: PreparedFollowUpBatch?
    /// Full-screen Result Viewer presentation (the message whose result is
    /// being inspected).
    public var resultViewerMessageID: UUID?
    public var isRenamePresented = false
    public var renameDraft = ""
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
      let recovered = snapshot.recoveredPreparedAnswers(
        excluding: preservingPreparedAnswerID)
      let activeUserMessage: ChatMessage? = {
        if let preservingPreparedAnswerID {
          if let index = snapshot.messages.firstIndex(where: {
            $0.id == preservingPreparedAnswerID
          }), index > 0, snapshot.messages[index - 1].role == .user {
            return snapshot.messages[index - 1]
          }
        }
        guard snapshot.messages.last?.role == .user else { return nil }
        return snapshot.messages.last
      }()
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
        interruptedTurn: nil)
      self.interruptedTurns = snapshot.interruptedTurns.filter { interruption in
        if preservingActiveTurn, let activeUserMessage,
          (interruption.executionID == activeUserMessage.id
            || (interruption.executionID == nil
              && interruption.question == activeUserMessage.previewText)) {
          return false
        }
        if recovered.contains(where: { answer in
          guard answer.question == interruption.question else { return false }
          guard let executionID = interruption.executionID else { return true }
          return answer.precedingUserMessageID == executionID
        }) { return false }
        return true
      }
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
    case askAgainTappedFor(UUID)
    case cancelQueuedRetryTapped(UUID)
    case interruptedDismissed
    case interruptedDismissedFor(UUID)
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
    case operationFailed(FailurePresentation, origin: FailureOrigin? = nil)
    case delegate(Delegate)

    /// Global work only ``AppFeature`` can perform.
    public enum Delegate: Sendable, Equatable {
      case feedbackWriteRequested(conversationID: UUID, write: FeedbackWrite)
      case submitQuestion(QuestionSubmission)
      case retryInterruptedTurn
      case retryInterruptedTurnFor(UUID)
      case dismissInterruptedTurn(
        conversationID: UUID, journalID: UUID, interruption: InterruptedTurn)
      /// Cancels a queued retry; the journal survives for Ask Again.
      case cancelQueuedRetry(UUID)
      case stopActiveTurn
      case cancelQueued(UUID)
      case openBrowser
      case newChatRequested
      case deleteRequested
      case renameRequested(UUID, String)
      case exportRequested(UUID)
    }
  }

  private enum CancelID {
    case readAloud
  }

  @Dependency(\.readAloud) var readAloud
  @Dependency(\.date.now) var now
  @Dependency(\.diagnostics) var diagnostics

  public init() {}

  public var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
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
        return commitSubmission(state: &state, capturesCorrection: true)

      case .sendTapped:
        state.isSubmissionPending = false
        diagnostics.info(
          category: .submission,
          code: "chat_send_tapped",
          summary: "The send action was invoked.")
        return commitSubmission(state: &state, capturesCorrection: true)

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
          preparedFollowUp: prepared)

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
        diagnostics.info(
          category: .submission,
          code: "chat_interrupted_turn_resubmitted",
          summary: "An interrupted turn was requested with Ask Again.",
          context: ["has_execution_id": String(interrupted.executionID != nil)])
        return .send(.delegate(.retryInterruptedTurn))

      case .askAgainTappedFor(let journalID):
        guard state.interruptedTurns.contains(where: { $0.journalID == journalID })
        else { return .none }
        return .send(.delegate(.retryInterruptedTurnFor(journalID)))

      case .cancelQueuedRetryTapped(let journalID):
        guard state.queuedRetryJournalIDs.contains(journalID) else { return .none }
        diagnostics.info(
          category: .submission,
          code: "chat_queued_retry_cancelled",
          summary: "A queued retry was cancelled from the interruption banner.")
        return .send(.delegate(.cancelQueuedRetry(journalID)))

      case .interruptedDismissed:
        guard let interrupted = state.interruptedTurn else { return .none }
        state.interruptedTurn = nil
        guard let journalID = interrupted.journalID ?? interrupted.executionID
        else { return .none }
        return .send(.delegate(.dismissInterruptedTurn(
          conversationID: state.conversationID, journalID: journalID,
          interruption: interrupted)))

      case .interruptedDismissedFor(let journalID):
        guard let interrupted = state.interruptedTurns.first(where: { $0.journalID == journalID })
        else { return .none }
        state.interruptedTurns.removeAll { $0.journalID == journalID }
        return .send(.delegate(.dismissInterruptedTurn(
          conversationID: state.conversationID, journalID: journalID,
          interruption: interrupted)))

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

      case .resultPresentationChanged, .resultPresentationMigrated:
        guard let message = Self.resultPresentationWrite(state: state, action: action) else { return .none }
        state.messages[id: message.id] = message
        return .none

      case .renameTapped:
        state.renameDraft = state.title
        state.isRenamePresented = true
        return .none

      case .renameCommitted:
        let title = HistoryStore.normalizedRenameTitle(from: state.renameDraft)
        state.isRenamePresented = false
        guard !title.isEmpty else { return .none }
        state.title = title
        state.isManuallyTitled = true
        return .send(.delegate(.renameRequested(state.conversationID, title)))

      case .exportTapped:
        return .send(.delegate(.exportRequested(state.conversationID)))

      case .operationFailed:
        // Presented by AppFeature, which owns the failure surface.
        return .none

      case .delegate:
        return .none
      }
    }
  }

  /// Shared with the parent, which captures the accepted write before this
  /// reducer applies it. Explicit identical changes remain retryable.
  static func resultPresentationWrite(state: State, action: Action) -> ChatMessage? {
    let messageID: UUID
    let preference: ResultPresentationPreference
    switch action {
    case .resultPresentationChanged(let id, let updated):
      messageID = id
      preference = updated
    case .resultPresentationMigrated(let migration):
      guard state.messages[id: migration.messageID]?.resultPresentation == migration.previous
      else { return nil }
      messageID = migration.messageID
      preference = migration.updated
    default: return nil
    }
    guard var message = state.messages[id: messageID] else { return nil }
    message.resultPresentation = preference
    return message
  }
}
