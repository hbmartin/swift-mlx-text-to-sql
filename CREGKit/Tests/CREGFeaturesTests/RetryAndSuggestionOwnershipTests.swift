import ComposableArchitecture
import Foundation
import Testing

@testable import CREGEngine
@testable import CREGFeatures

private let ownershipAnswer = QueryResult(
  columns: ["name"], rows: [[.text("Sable Tower")]])

/// Holds one asynchronous history operation open until released.
private actor HeldOperation {
  private var isHeld = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var release: CheckedContinuation<Void, Never>?

  func hold() async {
    isHeld = true
    for waiter in startWaiters { waiter.resume() }
    startWaiters.removeAll()
    await withCheckedContinuation { release = $0 }
  }

  func waitUntilHeld() async {
    if isHeld { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func finish() {
    release?.resume()
    release = nil
  }
}

/// Deterministic reducer coverage for the retry queue and suggestion
/// ownership contract: offscreen retries, claim/release/cancel transitions,
/// inactive-versus-background lifecycle, draft recovery, and judge counts.
@MainActor
@Suite struct RetryAndSuggestionOwnershipTests {
  typealias Scheduler = AppFeatureSchedulerTests
  static let conversationA = Scheduler.conversationA
  static let conversationB = Scheduler.conversationB

  private func activeTurn(
    questionID: UUID, conversationID: UUID, question: String, at seconds: TimeInterval
  ) -> AppFeature.ActiveTurn {
    let user = ChatMessage(
      id: questionID, role: .user, body: .text(question),
      createdAt: Date(timeIntervalSince1970: seconds))
    var turn = AppFeature.ActiveTurn(
      questionID: questionID, conversationID: conversationID,
      question: question, startedAt: user.createdAt)
    turn.optimisticUserTurn = AppFeature.OptimisticUserTurn(
      message: user, previousSummary: nil, previousChatTitle: nil)
    turn.preflightCompleted = true
    turn.pipelineStarted = true
    return turn
  }

  // MARK: Offscreen retries

  @Test func offscreenInterruptionQueuesRetryAheadOfLaterQuestionsInItsConversation() async {
    let questionID = UUID(9001)
    var state = Scheduler.appState(selected: Self.conversationA)
    state.activeTurn = activeTurn(
      questionID: questionID, conversationID: Self.conversationB,
      question: "Offscreen question", at: 1)
    let later = QueuedQuestion(
      id: UUID(9002), conversationID: Self.conversationB,
      question: "Later in B", submittedAt: Date(timeIntervalSince1970: 5))
    state.queue = [later]
    let marks = CallRecorder()
    var history = HistoryClient.noop()
    history.markTurnInterrupted = { _, id, ambiguous in
      marks.record("\(id.uuidString):\(ambiguous)")
    }
    let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
      $0.historyClient = history
      $0.queryPipeline = Scheduler.hangingPipeline()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 6))
    }
    store.exhaustivity = .off

    await store.send(.appEnteredBackground)
    await store.finish()
    await store.skipReceivedActions()

    #expect(marks.recorded == ["\(questionID.uuidString):false"])
    #expect(store.state.automaticRetryCandidates[questionID]?.conversationID == Self.conversationB)
    #expect(store.state.queue.map(\.retryJournalID) == [questionID, nil])
    #expect(store.state.queue.map(\.question) == ["Offscreen question", "Later in B"])
    #expect(store.state.queue.first?.automaticRetry == true)
    // Nothing shows in the selected conversation, which owns no interruption.
    #expect(store.state.chat?.interruptedTurns.isEmpty == true)
    #expect(store.state.activeTurn == nil)

    await store.send(.appBecameActive)
    await store.skipReceivedActions()
    #expect(store.state.activeTurn?.conversationID == Self.conversationB)
    #expect(store.state.activeTurn?.isAutomaticRetry == true)
    #expect(store.state.activeTurn?.autoRetryCount == 1)
    #expect(store.state.activeTurn?.optimisticUserTurn?.isExisting == true)
    #expect(store.state.queue.map(\.question) == ["Later in B"])
    #expect(store.state.automaticRetryCandidates.isEmpty)
    await store.skipInFlightEffects()
  }

  @Test func relaunchedProcessNeverQueuesAutomaticRetries() async {
    let user = ChatMessage(
      id: UUID(9010), role: .user, body: .text("From a prior process"),
      createdAt: Date(timeIntervalSince1970: 1))
    var state = Scheduler.appState()
    state.chat?.messages.append(user)
    state.chat?.interruptedTurn = InterruptedTurn(
      question: user.previewText, interruptedAt: user.createdAt,
      journalID: user.id, executionID: user.id, status: .knownInterruption)
    let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
      $0.historyClient = .noop()
      $0.queryPipeline = Scheduler.hangingPipeline()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 2))
    }
    store.exhaustivity = .off

    await store.send(.appBecameActive)
    await store.finish()
    #expect(store.state.queue.isEmpty)
    #expect(store.state.activeTurn == nil)
    #expect(store.state.chat?.interruptedTurn?.canAutoRetry == true)
    #expect(store.state.chat?.queuedRetryJournalIDs.isEmpty == true)
  }

  // MARK: Claim, release, cancel, failure

  @Test func bannerCancelOfQueuedRetryDeclinesAllowanceAndKeepsJournal() async {
    let user = ChatMessage(
      id: UUID(9020), role: .user, body: .text("Cancel me"),
      createdAt: Date(timeIntervalSince1970: 1))
    var state = Scheduler.appState()
    state.isSceneActive = false
    state.chat?.messages.append(user)
    state.chat?.interruptedTurn = InterruptedTurn(
      question: user.previewText, interruptedAt: user.createdAt,
      journalID: user.id, executionID: user.id, status: .knownInterruption)
    state.automaticRetryCandidates[user.id] = AppFeature.AutomaticRetryCandidate(
      journalID: user.id, conversationID: Self.conversationA,
      submission: QuestionSubmission(question: user.previewText), userMessage: user)
    state.queue = [QueuedQuestion(
      id: UUID(9021), conversationID: Self.conversationA,
      submission: QuestionSubmission(question: user.previewText),
      retryJournalID: user.id, existingUserMessage: user,
      automaticRetry: true, submittedAt: user.createdAt)]
    state.chat?.queuedRetryJournalIDs = [user.id]
    let declines = CallRecorder()
    let endings = CallRecorder()
    var history = HistoryClient.noop()
    history.declineAutoRetry = { _, id in declines.record(id.uuidString) }
    history.endTurnJournal = { _, id in endings.record(id.uuidString) }
    let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
      $0.historyClient = history
      $0.queryPipeline = Scheduler.hangingPipeline()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 2))
    }
    store.exhaustivity = .off

    await store.send(.chat(.cancelQueuedRetryTapped(user.id)))
    await store.finish()
    await store.skipReceivedActions()

    #expect(declines.recorded == [user.id.uuidString])
    #expect(endings.recorded.isEmpty)
    #expect(store.state.queue.isEmpty)
    #expect(store.state.automaticRetryCandidates.isEmpty)
    #expect(store.state.chat?.interruptedTurn?.status == .manualRetryRequired)
    #expect(store.state.chat?.queuedRetryJournalIDs.isEmpty == true)

    // Activation no longer retries; Ask Again remains available.
    await store.send(.appBecameActive)
    await store.finish()
    #expect(store.state.activeTurn == nil)
    #expect(store.state.chat?.interruptedTurn?.journalID == user.id)
  }

  @Test func cancelWhileClaimIsInFlightDeclinesInsteadOfDispatching() async {
    let user = ChatMessage(
      id: UUID(9030), role: .user, body: .text("Claimed then cancelled"),
      createdAt: Date(timeIntervalSince1970: 1))
    var state = Scheduler.appState()
    state.chat?.messages.append(user)
    state.chat?.interruptedTurn = InterruptedTurn(
      question: user.previewText, interruptedAt: user.createdAt,
      journalID: user.id, executionID: user.id, status: .knownInterruption)
    state.retryClaimInFlight = true
    state.retryClaimJournalID = user.id
    state.retryClaimConversationID = Self.conversationA
    state.chat?.queuedRetryJournalIDs = [user.id]
    let queued = QueuedQuestion(
      id: UUID(9031), conversationID: Self.conversationA,
      submission: QuestionSubmission(question: user.previewText),
      retryJournalID: user.id, existingUserMessage: user,
      automaticRetry: true, submittedAt: user.createdAt)
    let declines = CallRecorder()
    var history = HistoryClient.noop()
    history.declineAutoRetry = { _, id in declines.record(id.uuidString) }
    let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
      $0.historyClient = history
      $0.queryPipeline = Scheduler.hangingPipeline()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 2))
    }
    store.exhaustivity = .off

    await store.send(.chat(.cancelQueuedRetryTapped(user.id)))
    await store.skipReceivedActions()
    #expect(store.state.cancelledRetryJournalIDs.contains(user.id))
    #expect(store.state.retryClaimInFlight)
    await store.send(.queuedRetryClaimed(queued, 1))
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.activeTurn == nil)
    #expect(store.state.cancelledRetryJournalIDs.isEmpty)
    #expect(declines.recorded == [user.id.uuidString, user.id.uuidString])
    #expect(store.state.chat?.interruptedTurn?.status == .manualRetryRequired)
    #expect(store.state.chat?.messages.count == 1)
  }

  @Test func automaticReleaseRestoresAllowanceAndRetriesOnActivation() async {
    let user = ChatMessage(
      id: UUID(9040), role: .user, body: .text("Release then retry"),
      createdAt: Date(timeIntervalSince1970: 1))
    var state = Scheduler.appState()
    state.isSceneActive = false
    state.chat?.messages.append(user)
    state.chat?.interruptedTurn = InterruptedTurn(
      question: user.previewText, interruptedAt: user.createdAt,
      journalID: user.id, executionID: user.id, status: .knownInterruption)
    state.automaticRetryCandidates[user.id] = AppFeature.AutomaticRetryCandidate(
      journalID: user.id, conversationID: Self.conversationA,
      submission: QuestionSubmission(question: user.previewText), userMessage: user)
    state.retryClaimInFlight = true
    state.retryClaimJournalID = user.id
    state.retryClaimConversationID = Self.conversationA
    let queued = QueuedQuestion(
      id: UUID(9041), conversationID: Self.conversationA,
      submission: QuestionSubmission(question: user.previewText),
      retryJournalID: user.id, existingUserMessage: user,
      automaticRetry: true, submittedAt: user.createdAt)
    let releases = CallRecorder()
    let claims = CallRecorder()
    var history = HistoryClient.noop()
    history.releaseAutoRetryClaim = { _, journalID, _, automatic in
      releases.record("\(journalID):\(automatic)")
    }
    history.claimTurnRetry = { _, journalID, _, automatic in
      claims.record("\(journalID):\(automatic)")
      return automatic ? 1 : 0
    }
    let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
      $0.historyClient = history
      $0.queryPipeline = Scheduler.hangingPipeline()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 2))
    }
    store.exhaustivity = .off

    await store.send(.queuedRetryClaimed(queued, 1))
    await store.receive(.retryClaimReleased(queued, true))
    await store.skipReceivedActions()
    #expect(releases.recorded == ["\(user.id):true"])
    #expect(store.state.automaticRetryCandidates[user.id] != nil)
    #expect(store.state.chat?.interruptedTurn?.canAutoRetry == true)
    #expect(store.state.activeTurn == nil)

    await store.send(.appBecameActive)
    await store.skipReceivedActions()
    #expect(claims.recorded == ["\(user.id):true"])
    #expect(store.state.activeTurn?.isAutomaticRetry == true)
    #expect(store.state.activeTurn?.autoRetryCount == 1)
    #expect(store.state.automaticRetryCandidates.isEmpty)
    await store.skipInFlightEffects()
  }

  @Test func failedClaimRestartsTheSchedulerWithTheNextQueuedQuestion() async {
    let user = ChatMessage(
      id: UUID(9050), role: .user, body: .text("Refused retry"),
      createdAt: Date(timeIntervalSince1970: 1))
    var state = Scheduler.appState()
    state.chat?.messages.append(user)
    state.chat?.interruptedTurn = InterruptedTurn(
      question: user.previewText, interruptedAt: user.createdAt,
      journalID: user.id, executionID: user.id, status: .knownInterruption)
    state.automaticRetryCandidates[user.id] = AppFeature.AutomaticRetryCandidate(
      journalID: user.id, conversationID: Self.conversationA,
      submission: QuestionSubmission(question: user.previewText), userMessage: user)
    state.queue = [QueuedQuestion(
      id: UUID(9051), conversationID: Self.conversationA,
      question: "Next question", submittedAt: Date(timeIntervalSince1970: 3))]
    let runs = CallRecorder()
    var history = HistoryClient.noop()
    history.claimTurnRetry = { _, _, _, _ in nil }
    let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
      $0.historyClient = history
      $0.queryPipeline = Scheduler.scriptedPipeline(runs: runs)
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 4))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.dispatchNextIfIdle)
    await store.finish()
    await store.skipReceivedActions()

    #expect(runs.recorded == ["Next question"])
    #expect(store.state.queue.isEmpty)
    #expect(store.state.automaticRetryCandidates.isEmpty)
    #expect(store.state.chat?.interruptedTurn?.status == .manualRetryRequired)
    #expect(store.state.presentedFailure?.code == "retry_claim_failed")
  }

  // MARK: Inactive versus background

  @Test func inactiveKeepsModelPreparationRunningUntilBackground() async {
    let attemptID = UUID(9060)
    var state = Scheduler.appState()
    state.modelReadiness = .preparing
    state.modelPreparationInFlight = true
    state.modelPreparationModeInFlight = .evaluated
    state.modelPreparationAttemptID = attemptID
    let pipeline = QueryPipeline(
      waitUntilInferenceIdle: {},
      run: { _, _ in AsyncStream { $0.finish() } })
    let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
      $0.queryPipeline = pipeline
      $0.modelPreparationJournal = .noop
    }
    store.exhaustivity = .off

    await store.send(.appBecameInactive)
    #expect(store.state.modelPreparationInFlight)
    #expect(store.state.drainingModelPreparationAttemptID == nil)

    await store.send(.appEnteredBackground)
    #expect(!store.state.modelPreparationInFlight)
    #expect(store.state.suspendedModelPreparationMode == .evaluated)
    await store.receive(.modelPreparationSuspended(attemptID))
    await store.finish()
  }

  // MARK: Draft recovery

  @Test func rejectedSubmissionFollowsIntoItsNewDraftChatWhenSelectionIsUnchanged() async {
    let state = Scheduler.appState(selected: Self.conversationA)
    let drafts = CallRecorder()
    var history = HistoryClient.noop()
    history.saveDraft = { id, text in drafts.record("\(id):\(text)") }
    let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
      $0.historyClient = history
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 50))
    }
    store.exhaustivity = .off

    // The composer committed for B, but A is what is selected now.
    await store.send(.chat(.delegate(.submitQuestion(
      QuestionSubmission(
        question: "Committed for the other chat",
        originConversationID: Self.conversationB,
        clearsComposerOnAcceptance: true)))))
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.conversations.count == 3)
    #expect(store.state.chat?.conversationID == UUID(0))
    #expect(store.state.chat?.composerText == "Committed for the other chat")
    #expect(store.state.chat?.messages.isEmpty == true)
    #expect(store.state.activeTurn == nil)
    #expect(store.state.queue.isEmpty)
    #expect(drafts.recorded.isEmpty)
    #expect(store.state.presentedFailure?.code == "submission_conversation_unavailable")
    #expect(store.state.unsavedRejectedSubmission == nil)
  }

  @Test func rejectedSubmissionDoesNotFollowWhenTheUserNavigatedDuringCreation() async {
    let state = Scheduler.appState(selected: Self.conversationA)
    let held = HeldOperation()
    var history = HistoryClient.noop()
    history.createConversationWithDraft = { id, startedAt, _ in
      await held.hold()
      return ConversationSummary(
        id: id, title: "", startedAt: startedAt, lastActivityAt: startedAt)
    }
    let summaryB = state.conversations[id: Self.conversationB]!
    let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
      $0.historyClient = history
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 50))
    }
    store.exhaustivity = .off

    await store.send(.chat(.delegate(.submitQuestion(
      QuestionSubmission(
        question: "Late draft", originConversationID: Self.conversationB,
        clearsComposerOnAcceptance: true)))))
    await held.waitUntilHeld()
    await store.send(.conversationLoaded(ConversationSnapshot(summary: summaryB)))
    #expect(store.state.chat?.conversationID == Self.conversationB)
    await held.finish()
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.chat?.conversationID == Self.conversationB)
    #expect(store.state.chat?.composerText.isEmpty == true)
    #expect(store.state.conversations.count == 3)
    #expect(store.state.conversations.contains { $0.id == UUID(0) })
    #expect(store.state.presentedFailure?.code == "submission_conversation_unavailable")
  }

  @Test func rejectedSubmissionSaveFailureRetainsTheText() async {
    let state = Scheduler.appState(selected: Self.conversationA)
    var history = HistoryClient.noop()
    history.createConversationWithDraft = { _, _, _ in
      throw HistoryStoreError.conversationNotFound
    }
    let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
      $0.historyClient = history
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 50))
    }
    store.exhaustivity = .off

    await store.send(.chat(.delegate(.submitQuestion(
      QuestionSubmission(
        question: "Keep this text", originConversationID: Self.conversationB,
        clearsComposerOnAcceptance: true)))))
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.conversations.count == 2)
    #expect(store.state.chat?.conversationID == Self.conversationA)
    #expect(store.state.unsavedRejectedSubmission == "Keep this text")
    #expect(store.state.presentedFailure?.code == "submission_draft_save_failed")
    #expect(store.state.presentedFailure?.message.contains("Keep this text") == true)
  }

  // MARK: Suggestion ownership

  @Test func acceptedQueuedQuestionRetiresTheEarlierAnswersSuggestions() async {
    let firstID = UUID(9070)
    var state = Scheduler.appState()
    state.activeTurn = activeTurn(
      questionID: firstID, conversationID: Self.conversationA,
      question: "First question", at: 1)
    let preparedContexts = LockIsolated<[FollowUpSuggestionContext]>([])
    let pipeline = QueryPipeline(
      run: { question, _ in
        AsyncStream { continuation in
          continuation.yield(
            .turnFinished(
              outcome: .answered(
                result: ownershipAnswer, narration: "Answer to \(question)",
                sql: "SELECT 1", notice: nil),
              telemetry: TurnTelemetry(originalQuestion: question)))
          continuation.finish()
        }
      },
      prepareFollowUps: { context in
        preparedContexts.withValue { $0.append(context) }
        return AsyncStream { continuation in
          continuation.yield(.finished)
          continuation.finish()
        }
      })
    let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
      $0.queryPipeline = pipeline
      $0.historyClient = .noop()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.continuousClock = ImmediateClock()
      $0.haptics = .noop
    }
    store.exhaustivity = .off

    // Q2 is accepted while Q1 still runs: it queues and advances the
    // generation before Q1's answer can seed suggestions.
    await store.send(.chat(.delegate(.submitQuestion(
      QuestionSubmission(question: "Second question")))))
    #expect(store.state.queue.map(\.question) == ["Second question"])
    #expect(store.state.conversations[id: Self.conversationA]?.suggestionGeneration == 1)

    await store.send(
      .pipelineEvent(
        conversationID: Self.conversationA, questionID: firstID,
        event: Scheduler.finishedEvent(question: "First question")))
    await store.finish()
    await store.skipReceivedActions()

    // Only Q2's answer owns suggestions; Q1's context was dropped, never
    // parked, and no Q1 batch was shown.
    #expect(preparedContexts.value.map(\.question) == ["Second question"])
    #expect(store.state.pendingSuggestionContexts.isEmpty)
    #expect(store.state.chat?.followUpBatch?.context?.question == "Second question")
    #expect(store.state.chat?.followUpBatch?.generation == 2)
  }

  @Test func loadedBatchFromARetiredGenerationIsNotDisplayed() async {
    let prepared = Scheduler.preparedFollowUp()
    let context = FollowUpSuggestionContext(
      sourceAssistantMessageID: prepared.sourceAssistantMessageID,
      question: "Old", standaloneQuestion: "Old",
      narration: "Old", result: ownershipAnswer)
    let stale = PreparedFollowUpBatch(
      sourceAssistantMessageID: prepared.sourceAssistantMessageID,
      context: context, status: .completed, suggestions: [prepared],
      updatedAt: Date(timeIntervalSince1970: 1), generation: 0)
    var state = Scheduler.appState()
    state.conversations[id: Self.conversationA]?.suggestionGeneration = 2
    var summary = state.conversations[id: Self.conversationA]!
    summary.suggestionGeneration = 1
    let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
      $0.historyClient = .noop()
      $0.date = .constant(Date(timeIntervalSince1970: 3))
    }
    store.exhaustivity = .off

    await store.send(.conversationLoaded(
      ConversationSnapshot(summary: summary, followUpBatch: stale)))
    await store.finish()
    #expect(store.state.chat?.followUpBatch == nil)
    // The durable generation can only raise the in-memory one.
    #expect(store.state.conversations[id: Self.conversationA]?.suggestionGeneration == 2)
  }

  // MARK: Judge invocation counts

  @Test func completedNilVerdictResumesPreparationWithoutASecondJudgeCall() async {
    let questionID = UUID(9080)
    let messageID = UUID(9081)
    let context = FollowUpSuggestionContext(
      sourceAssistantMessageID: messageID,
      question: "Who manages each property?",
      standaloneQuestion: "Who manages each property?",
      seed: .turnFailure(reason: .generationExhausted, scopeVerdict: nil))
    var state = Scheduler.appState()
    state.modelReadiness = .preparing
    var pending = AppFeature.PendingTurnPersistence(
      questionID: questionID, conversationID: Self.conversationA)
    pending.terminalMessageID = messageID
    pending.followUpContext = context
    state.pendingTurnPersistence = pending
    let judged = LockIsolated(0)
    let preparedContexts = LockIsolated<[FollowUpSuggestionContext]>([])
    let savedBatches = LockIsolated<[PreparedFollowUpBatch]>([])
    var history = HistoryClient.noop()
    history.saveFollowUpBatch = { _, batch in
      savedBatches.withValue { $0.append(batch) }
    }
    let pipeline = QueryPipeline(
      run: { _, _ in AsyncStream { $0.finish() } },
      prepareFollowUps: { context in
        preparedContexts.withValue { $0.append(context) }
        return AsyncStream { continuation in
          continuation.yield(.finished)
          continuation.finish()
        }
      })
    let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
      [history, pipeline] in
      $0.queryPipeline = pipeline
      $0.historyClient = history
      $0.scopeDiagnosis = ScopeDiagnosisClient { _ in
        judged.withValue { $0 += 1 }
        return nil
      }
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.turnPersistenceFinished(questionID))
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(judged.value == 1)
    #expect(preparedContexts.value.isEmpty)
    let parked = store.state.pendingSuggestionContexts[Self.conversationA]
    #expect(parked?.scopeDiagnosisCompleted == true)
    #expect(parked?.needsScopeDiagnosis == false)
    #expect(savedBatches.value.last?.scopeDiagnosisCompleted == true)

    await store.send(.modelPrepared(
      ModelPreparationReport(mode: .evaluated, elapsedMilliseconds: 0)))
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(judged.value == 1)
    #expect(preparedContexts.value == [context])
  }

  @Test func parkedVerdictContextIsNeverJudgedAgain() async {
    let messageID = UUID(9090)
    let verdict = ScopeVerdictRecord(verdict: .likelyAnswerableModelFailed)
    let context = FollowUpSuggestionContext(
      sourceAssistantMessageID: messageID,
      question: "Who manages each property?",
      standaloneQuestion: "Who manages each property?",
      seed: .turnFailure(reason: .generationExhausted, scopeVerdict: verdict))
    var state = Scheduler.appState()
    state.pendingSuggestionContexts[Self.conversationA] = AppFeature.PendingScopeDiagnosis(
      conversationID: Self.conversationA, messageID: messageID, context: context)
    let judged = LockIsolated(0)
    let preparedContexts = LockIsolated<[FollowUpSuggestionContext]>([])
    let pipeline = QueryPipeline(
      run: { _, _ in AsyncStream { $0.finish() } },
      prepareFollowUps: { context in
        preparedContexts.withValue { $0.append(context) }
        return AsyncStream { continuation in
          continuation.yield(.finished)
          continuation.finish()
        }
      })
    let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
      [pipeline] in
      $0.queryPipeline = pipeline
      $0.historyClient = .noop()
      $0.scopeDiagnosis = ScopeDiagnosisClient { _ in
        judged.withValue { $0 += 1 }
        return verdict
      }
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.appBecameActive)
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(judged.value == 0)
    #expect(preparedContexts.value == [context])
  }

  @Test func persistedBatchWithCompletedDiagnosisResumesWithoutTheJudge() async {
    let messageID = UUID(9095)
    let context = FollowUpSuggestionContext(
      sourceAssistantMessageID: messageID,
      question: "Who manages each property?",
      standaloneQuestion: "Who manages each property?",
      seed: .turnFailure(reason: .generationExhausted, scopeVerdict: nil))
    var state = Scheduler.appState()
    state.chat?.followUpBatch = PreparedFollowUpBatch(
      sourceAssistantMessageID: messageID, context: context,
      status: .preparing, updatedAt: Date(timeIntervalSince1970: 1),
      generation: 0, scopeDiagnosisCompleted: true)
    let judged = LockIsolated(0)
    let preparedContexts = LockIsolated<[FollowUpSuggestionContext]>([])
    let pipeline = QueryPipeline(
      run: { _, _ in AsyncStream { $0.finish() } },
      prepareFollowUps: { context in
        preparedContexts.withValue { $0.append(context) }
        return AsyncStream { continuation in
          continuation.yield(.finished)
          continuation.finish()
        }
      })
    let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
      [pipeline] in
      $0.queryPipeline = pipeline
      $0.historyClient = .noop()
      $0.scopeDiagnosis = ScopeDiagnosisClient { _ in
        judged.withValue { $0 += 1 }
        return nil
      }
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.appBecameActive)
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(judged.value == 0)
    #expect(preparedContexts.value == [context])
  }

  @Test func judgeCancelledBeforeAVerdictRunsAgainOnActivation() async {
    let questionID = UUID(9100)
    let messageID = UUID(9101)
    let verdict = ScopeVerdictRecord(verdict: .likelyAnswerableModelFailed)
    let context = FollowUpSuggestionContext(
      sourceAssistantMessageID: messageID,
      question: "Who manages each property?",
      standaloneQuestion: "Who manages each property?",
      seed: .turnFailure(reason: .generationExhausted, scopeVerdict: nil))
    var state = Scheduler.appState()
    var pending = AppFeature.PendingTurnPersistence(
      questionID: questionID, conversationID: Self.conversationA)
    pending.terminalMessageID = messageID
    pending.followUpContext = context
    state.pendingTurnPersistence = pending
    let judged = LockIsolated(0)
    let judgeStarted = HeldOperation()
    let preparedContexts = LockIsolated<[FollowUpSuggestionContext]>([])
    let pipeline = QueryPipeline(
      run: { _, _ in AsyncStream { $0.finish() } },
      prepareFollowUps: { context in
        preparedContexts.withValue { $0.append(context) }
        return AsyncStream { continuation in
          continuation.yield(.finished)
          continuation.finish()
        }
      })
    let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
      [pipeline] in
      $0.queryPipeline = pipeline
      $0.historyClient = .noop()
      $0.scopeDiagnosis = ScopeDiagnosisClient { _ in
        let call = judged.withValue { value -> Int in
          value += 1
          return value
        }
        if call == 1 {
          // The first judge is interrupted by the background transition.
          await judgeStarted.hold()
          return nil
        }
        return verdict
      }
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.turnPersistenceFinished(questionID))
    await judgeStarted.waitUntilHeld()
    #expect(store.state.isScopeDiagnosisInFlight)
    await store.send(.appEnteredBackground)
    await judgeStarted.finish()
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(store.state.pendingScopeDiagnosis?.scopeDiagnosisCompleted == false)
    #expect(preparedContexts.value.isEmpty)

    await store.send(.appBecameActive)
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(judged.value == 2)
    guard case .turnFailure(_, let resumedVerdict)? = preparedContexts.value.first?.seed
    else {
      Issue.record("Expected the re-judged Recovery Suggestion context")
      return
    }
    #expect(resumedVerdict == verdict)
  }
}
