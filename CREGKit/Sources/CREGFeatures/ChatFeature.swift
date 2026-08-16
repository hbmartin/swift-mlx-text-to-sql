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
  private struct DraftSaveID: Hashable {
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

  /// Commits the composer text as a submission; shared by the send path, the
  /// starter chips, and Ask Again. The parent decides whether it dispatches
  /// immediately or becomes a Queued Question.
  private func commitSubmission(
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
  private func toggleFeedback(
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

actor MessageUpdateQueue {
  enum SaveOutcome: Equatable, Sendable {
    case saved
    case superseded
    case discardedDuringDeletion
  }

  private struct Key: Hashable {
    var conversationID: UUID
    var messageID: UUID
  }

  private enum OnceSaveState {
    case active(
      [CheckedContinuation<Result<SaveOutcome, any Error>, Never>]
    )
    case resolved(Result<SaveOutcome, any Error>)
  }

  /// Every history mutation in one conversation shares a FIFO. Message-level
  /// revisions still suppress stale preference effects, but distinct message
  /// IDs can no longer overtake each other in the durable transcript.
  private var activeConversationIDs: Set<UUID> = []
  private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
  private var latestRevisions: [Key: UInt64] = [:]
  private var onceSaves: [Key: OnceSaveState] = [:]
  /// Saves that arrive during deletion wait for its outcome. A failed delete
  /// resumes them; a confirmed delete permanently rejects late scheduled work.
  private var deletingConversationIDs: Set<UUID> = []
  private var deletedConversationIDs: Set<UUID> = []
  private var deletionResolutionWaiters: [UUID: [CheckedContinuation<Bool, Never>]] = [:]
  private var deletionDrainWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

  @discardableResult
  func save(
    conversationID: UUID,
    messageID: UUID,
    revision: UInt64? = nil,
    operation: @escaping @Sendable () async throws -> Void
  ) async throws -> SaveOutcome {
    let key = Key(conversationID: conversationID, messageID: messageID)
    guard await waitForDeletionResolutionIfNeeded(conversationID) else {
      return .discardedDuringDeletion
    }
    if let revision {
      guard revision > (latestRevisions[key] ?? 0) else { return .superseded }
      latestRevisions[key] = revision
    }

    while true {
      await acquire(conversationID)
      if deletedConversationIDs.contains(conversationID) {
        finish(conversationID)
        return .discardedDuringDeletion
      }
      guard deletingConversationIDs.contains(conversationID) else { break }
      finish(conversationID)
      guard await waitForDeletionResolutionIfNeeded(conversationID) else {
        return .discardedDuringDeletion
      }
      if let revision, revision < (latestRevisions[key] ?? 0) {
        return .superseded
      }
    }

    do {
      try await operation()
      finish(conversationID)
      return .saved
    } catch {
      finish(conversationID)
      guard await waitForDeletionResolutionIfNeeded(conversationID) else {
        return .discardedDuringDeletion
      }
      throw error
    }
  }

  /// Coalesces logically identical saves. Stop and the dispatch effect both
  /// use this for the user-message prerequisite, so whichever reaches the
  /// actor first performs the write and every other caller observes its exact
  /// outcome without retrying or overtaking it.
  @discardableResult
  func saveOnce(
    conversationID: UUID,
    messageID: UUID,
    operation: @escaping @Sendable () async throws -> Void
  ) async throws -> SaveOutcome {
    let key = Key(conversationID: conversationID, messageID: messageID)
    if let state = onceSaves[key] {
      let result: Result<SaveOutcome, any Error>
      switch state {
      case .resolved(let resolved):
        result = resolved
      case .active(var continuations):
        result = await withCheckedContinuation { continuation in
          continuations.append(continuation)
          onceSaves[key] = .active(continuations)
        }
      }
      return try result.get()
    }

    onceSaves[key] = .active([])
    let result: Result<SaveOutcome, any Error>
    do {
      result = .success(
        try await save(
          conversationID: conversationID,
          messageID: messageID,
          operation: operation))
    } catch {
      result = .failure(error)
    }
    resolveOnceSave(key, with: result)
    return try result.get()
  }

  func forgetOnceSave(conversationID: UUID, messageID: UUID) {
    let key = Key(conversationID: conversationID, messageID: messageID)
    guard case .resolved = onceSaves[key] else { return }
    onceSaves[key] = nil
  }

  func beginDeletingConversation(_ conversationID: UUID) async {
    deletingConversationIDs.insert(conversationID)
    guard activeConversationIDs.contains(conversationID) else {
      return
    }
    await withCheckedContinuation { continuation in
      deletionDrainWaiters[conversationID, default: []].append(continuation)
    }
  }

  /// Revision tombstones are needed while a message can still receive a late
  /// save, but a permanently deleted conversation can never be reconstructed
  /// under the same UUID. Keeping the deletion tombstone also prevents a save
  /// that reaches this actor after pruning from recreating revision state.
  func confirmConversationDeletion(_ conversationID: UUID) {
    deletingConversationIDs.remove(conversationID)
    deletedConversationIDs.insert(conversationID)
    latestRevisions = latestRevisions.filter {
      $0.key.conversationID != conversationID
    }
    // An active once-save can outlive the conversation FIFO while its owner
    // waits for deletion resolution. Retain it until `resolveOnceSave` resumes
    // every coalesced caller; resolved cache entries can be pruned immediately.
    onceSaves = onceSaves.filter {
      guard $0.key.conversationID == conversationID else { return true }
      if case .active = $0.value { return true }
      return false
    }
    resolveDeletionWaiters(conversationID, shouldSave: false)
  }

  func cancelConversationDeletion(_ conversationID: UUID) {
    deletingConversationIDs.remove(conversationID)
    resolveDeletionWaiters(conversationID, shouldSave: true)
  }

  func retainedRevisionCount() -> Int {
    latestRevisions.count
  }

  func onceSaveWaiterCount(conversationID: UUID, messageID: UUID) -> Int {
    let key = Key(conversationID: conversationID, messageID: messageID)
    guard case .active(let continuations) = onceSaves[key] else { return 0 }
    return continuations.count
  }

  func isDeletingConversation(_ conversationID: UUID) -> Bool {
    deletingConversationIDs.contains(conversationID)
  }

  private func acquire(_ conversationID: UUID) async {
    if activeConversationIDs.contains(conversationID) {
      await withCheckedContinuation { continuation in
        waiters[conversationID, default: []].append(continuation)
      }
    } else {
      activeConversationIDs.insert(conversationID)
    }
  }

  private func waitForDeletionResolutionIfNeeded(
    _ conversationID: UUID
  ) async -> Bool {
    if deletedConversationIDs.contains(conversationID) { return false }
    guard deletingConversationIDs.contains(conversationID) else { return true }
    return await withCheckedContinuation { continuation in
      deletionResolutionWaiters[conversationID, default: []].append(continuation)
    }
  }

  private func resolveDeletionWaiters(
    _ conversationID: UUID,
    shouldSave: Bool
  ) {
    let continuations =
      deletionResolutionWaiters.removeValue(
        forKey: conversationID) ?? []
    for continuation in continuations {
      continuation.resume(returning: shouldSave)
    }
  }

  private func resumeDeletionDrainIfReady(_ conversationID: UUID) {
    guard !activeConversationIDs.contains(conversationID) else {
      return
    }
    let continuations =
      deletionDrainWaiters.removeValue(
        forKey: conversationID) ?? []
    for continuation in continuations {
      continuation.resume()
    }
  }

  private func resolveOnceSave(
    _ key: Key,
    with result: Result<SaveOutcome, any Error>
  ) {
    let continuations: [CheckedContinuation<Result<SaveOutcome, any Error>, Never>]
    if case .active(let activeContinuations) = onceSaves[key] {
      continuations = activeContinuations
    } else {
      continuations = []
    }
    if deletedConversationIDs.contains(key.conversationID) {
      onceSaves[key] = nil
    } else {
      onceSaves[key] = .resolved(result)
    }
    for continuation in continuations {
      continuation.resume(returning: result)
    }
  }

  private func finish(_ conversationID: UUID) {
    guard var queued = waiters[conversationID], !queued.isEmpty else {
      activeConversationIDs.remove(conversationID)
      waiters[conversationID] = nil
      resumeDeletionDrainIfReady(conversationID)
      return
    }
    let next = queued.removeFirst()
    waiters[conversationID] = queued.isEmpty ? nil : queued
    next.resume()
  }
}

/// Reducers allocate revisions synchronously, before their effects can be
/// scheduled out of order. The process-wide counter also stays monotonic when
/// a conversation is unloaded and later reconstructed from history.
private let resultPresentationSaveRevisionCounter = MessageUpdateRevisionCounter()

private final class MessageUpdateRevisionCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value: UInt64 = 0

  func next() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    value &+= 1
    return value
  }
}
