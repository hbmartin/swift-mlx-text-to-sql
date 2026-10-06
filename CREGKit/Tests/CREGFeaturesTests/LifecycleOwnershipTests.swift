import ComposableArchitecture
import Foundation
import Testing

@testable import CREGEngine
@testable import CREGFeatures

private actor HeldLifecycleOperation {
  private var started = false
  private var release: CheckedContinuation<Void, Never>?
  private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

  func hold() async {
    guard !started else { return }
    started = true
    for waiter in waiters.values { waiter.resume() }
    waiters.removeAll()
    await withCheckedContinuation { release = $0 }
  }
  func wait() async {
    if started { return }
    let id = UUID()
    let timeout = Task {
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled, let waiter = waiters.removeValue(forKey: id) else { return }
      Issue.record("Expected held operation did not start within five seconds")
      waiter.resume()
    }
    await withCheckedContinuation { waiters[id] = $0 }
    timeout.cancel()
  }
  func finish() {
    release?.resume()
    release = nil
  }
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct LifecycleOwnershipTests {
  private typealias Scheduler = AppFeatureSchedulerTests
  private let a = Scheduler.conversationA
  private let b = Scheduler.conversationB
  private func question(_ id: Int, _ conversation: UUID, _ time: Double) -> QueuedQuestion {
    QueuedQuestion(
      id: UUID(id), conversationID: conversation, question: "Question \(id)",
      submittedAt: Date(timeIntervalSince1970: time))
  }
  private func retryFixture() -> (AppFeature.State, QueuedQuestion, InterruptedTurn) {
    let user = ChatMessage(
      id: UUID(12000), role: .user, body: .text("Retry me"),
      createdAt: Date(timeIntervalSince1970: 1))
    let interruption = InterruptedTurn(
      question: user.previewText, interruptedAt: user.createdAt,
      journalID: user.id, executionID: user.id, status: .manualRetryRequired, autoRetryCount: 1)
    var state = Scheduler.appState()
    state.chat?.messages.append(user)
    state.chat?.interruptedTurns.append(interruption)
    state.seedRetry(user.id, conversationID: a, interruption: interruption)
    let queued = QueuedQuestion(
      id: UUID(12001), conversationID: a,
      submission: QuestionSubmission(question: user.previewText), retryJournalID: user.id,
      existingUserMessage: user, submittedAt: user.createdAt)
    return (state, queued, interruption)
  }

  @Test func undoRestoresQueueIdentityOrderingAndRetryEligibility() async {
    var state = Scheduler.appState(selected: b)
    state.isSceneActive = false
    var oldest = question(12010, a, 1)
    let tie = question(12011, a, 1)
    let other = question(12012, b, 2)
    let newest = question(12013, a, 3)
    state.conversations[id: a]?.suggestionGeneration = 7
    let user = ChatMessage(
      id: UUID(12014), role: .user, body: .text("Automatic"), createdAt: oldest.submittedAt)
    oldest.retryJournalID = user.id
    oldest.existingUserMessage = user
    oldest.automaticRetry = true
    state.queue = [oldest, tie, other, newest]
    state.installAutomaticCandidate(
      .init(
        journalID: user.id, conversationID: a,
        submission: QuestionSubmission(question: user.previewText), userMessage: user,
        suggestionGeneration: 7))
    let journals = state.retryJournals
    let queue = state.queue
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.historyClient = .noop()
    }
    store.exhaustivity = .off
    await store.send(.deleteConversationTapped(a))
    #expect(store.state.queue == queue)
    #expect(store.state.runnableQueue == [other])
    #expect(store.state.conversations[id: a] != nil)
    #expect(!store.state.visibleConversations.contains { $0.id == a })
    await store.send(.undoDeleteTapped)
    await store.finish()
    #expect(store.state.queue == queue)
    #expect(store.state.runnableQueue == queue)
    #expect(store.state.automaticRetryCandidates == journals.compactMapValues(\.automaticCandidate))
    #expect(
      store.state.retryJournals.mapValues(\.knownDurableCount)
        == journals.mapValues(\.knownDurableCount))
    #expect(store.state.conversations[id: a]?.suggestionGeneration == 7)
    #expect(store.state.chat?.conversationID == b)
  }

  @Test func failedDeletionRestoresWorkWithoutChangingSelection() async {
    var state = Scheduler.appState(selected: b)
    state.isSceneActive = false
    let queued = question(12020, a, 1)
    state.queue = [queued]
    let deletion = HeldLifecycleOperation()
    var history = HistoryClient.noop()
    history.deleteConversation = { _ in
      await deletion.hold()
      throw NSError(domain: "Deletion", code: 1)
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.historyClient = history
    }
    store.exhaustivity = .off
    await store.send(.deleteConversationTapped(a))
    await store.send(.deleteCountdownFinished(store.state.pendingDeletion!.token))
    await deletion.wait()
    #expect(store.state.conversationDeletions[a]?.phase == .committing)
    await deletion.finish()
    await store.receive(\.conversationDeletionFinished)
    await store.receive(\.operationFailed)
    await store.finish()
    #expect(store.state.isConversationLive(a))
    #expect(store.state.queue == [queued])
    #expect(store.state.runnableQueue == [queued])
    #expect(store.state.presentedFailure != nil)
    #expect(store.state.chat?.conversationID == b)
  }

  @Test(arguments: [AppFeature.DeletionPhase.undoWindow, .committed])
  func deletedConversationRejectsBannerNavigationAndLateLoads(phase: AppFeature.DeletionPhase) async
  {
    var state = Scheduler.appState(selected: b)
    let summary = state.conversations[id: a]!
    state.installUndoDeletion(summary: summary)
    state.conversationDeletions[a]?.phase = phase
    state.answerReadyBanner = .init(conversationID: a, title: "Answer ready")
    let loads = CallRecorder()
    var history = HistoryClient.noop()
    history.loadConversation = { id in
      loads.record("load")
      return ConversationSnapshot(summary: summary)
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.historyClient = history
    }
    store.exhaustivity = .off
    await store.send(.answerReadyBannerTapped)
    await store.send(.conversationSelected(a))
    await store.send(.conversationLoaded(ConversationSnapshot(summary: summary)))
    await store.finish()
    #expect(store.state.chat?.conversationID == b)
    #expect(loads.recorded.isEmpty)
  }

  @Test func interruptionWriteSettlementReleasesHiddenConversationGate() async {
    var state = Scheduler.appState(selected: b)
    let user = ChatMessage(
      id: UUID(12030), role: .user, body: .text("Interrupted"),
      createdAt: Date(timeIntervalSince1970: 1))
    var interrupted = AppFeature.ActiveTurn(
      questionID: user.id, conversationID: a,
      question: user.previewText, startedAt: user.createdAt)
    interrupted.optimisticUserTurn = .init(
      message: user, previousSummary: nil, previousChatTitle: nil)
    state.pendingInterruptedTurn = interrupted
    let next = question(12031, b, 2)
    state.queue = [next]
    let deletes = CallRecorder()
    var history = HistoryClient.noop()
    history.deleteConversation = { _ in deletes.record("delete") }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.historyClient = history
      $0.queryPipeline = Scheduler.hangingPipeline()
    }
    store.exhaustivity = .off
    await store.send(.deleteConversationTapped(a))
    await store.send(.deleteCountdownFinished(store.state.pendingDeletion!.token))
    #expect(store.state.conversationDeletions[a]?.phase == .awaitingSettlement)
    #expect(store.state.pendingInterruptedTurn?.questionID == user.id)
    await store.send(
      .turnInterruptionRecorded(questionID: user.id, userPersisted: true, marked: true))
    await store.receive(\.conversationDeletionFinished)
    await store.skipReceivedActions(strict: false)
    #expect(store.state.pendingInterruptedTurn == nil)
    #expect(store.state.activeTurn?.conversationID == b)
    #expect(deletes.recorded == ["delete"])
    await store.send(
      .turnInterruptionRecorded(questionID: user.id, userPersisted: true, marked: true))
    #expect(deletes.recorded == ["delete"])
    await store.skipInFlightEffects()
  }

  @Test func thrownManualClaimDoesNotReadAppendOrRedispatch() async {
    let (state, queued, _) = retryFixture()
    let reads = CallRecorder()
    let writes = CallRecorder()
    let claims = CallRecorder()
    var history = HistoryClient.noop()
    history.claimTurnRetry = { _, _, _, _ in
      claims.record("claim")
      throw NSError(domain: "Claim", code: 1)
    }
    history.loadConversation = { _ in
      reads.record("read")
      throw NSError(domain: "Unexpected", code: 1)
    }
    history.persistUserTurn = { _, _, _, _, _ in writes.record("write") }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.historyClient = history
      $0.queryPipeline = Scheduler.hangingPipeline()
    }
    store.exhaustivity = .off
    await store.send(.chat(.delegate(.retryInterruptedTurnFor(queued.retryJournalID!))))
    await store.receive(\.queuedRetryClaimed)
    await store.receive(\.operationFailed)
    await store.finish()
    #expect(store.state.chat?.messages == state.chat?.messages)
    #expect(store.state.chat?.interruptedTurn?.status == .manualRetryRequired)
    #expect(store.state.activeTurn == nil && store.state.queue.isEmpty)
    #expect(claims.recorded == ["claim"] && reads.recorded.isEmpty && writes.recorded.isEmpty)
  }

  @Test(arguments: [false, true])
  func refusedClaimInspectionReservesAgeOrderAndTimesOut(timeout: Bool) async {
    var (state, queued, interruption) = retryFixture()
    state.holdRetryClaim(journalID: queued.retryJournalID!, conversationID: a)
    let later = question(12040, a, 2)
    state.queue = [later, question(12041, b, 3)]
    let read = HeldLifecycleOperation()
    let clock = TestClock()
    var history = HistoryClient.noop()
    let summary = state.conversations[id: a]!
    history.loadConversation = { [queued, interruption] _ in
      await read.hold()
      return ConversationSnapshot(
        summary: summary,
        messages: [
          queued.existingUserMessage!,
          ChatMessage(
            id: UUID(12042), role: .assistant, body: .text("Later answer"),
            createdAt: later.submittedAt),
        ],
        interruptedTurns: [interruption])
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.historyClient = history
      $0.queryPipeline = Scheduler.hangingPipeline()
    }
    store.exhaustivity = .off
    await store.send(claimCompletion(queued, nil, state: store.state))
    await read.wait()
    await store.send(.dispatchNextIfIdle)
    #expect(store.state.activeTurn == nil)
    #expect(store.state.retryOperationsHoldScheduler)
    if timeout {
      await clock.advance(by: .seconds(5))
      await store.receive(\.queuedRetryStaleChecked)
      await store.receive(\.operationFailed)
      #expect(store.state.chat?.interruptedTurn?.status == .manualRetryRequired)
    }
    await read.finish()
    if !timeout { await store.receive(\.queuedRetryStaleChecked) }
    await store.skipReceivedActions(strict: false)
    #expect(!store.state.retryOperationsHoldScheduler)
    #expect(store.state.activeTurn?.question == (timeout ? later.question : queued.question))
    #expect(store.state.activeTurn?.replacingJournalID == (timeout ? nil : interruption.journalID))
    await store.skipInFlightEffects()
  }

  @Test(arguments: [false, true])
  func inspectionDistinguishesTrailingRefusalFromUnknownTransfer(trailing: Bool) async {
    var (state, queued, interruption) = retryFixture()
    let summary = state.conversations[id: a]!
    let user = queued.existingUserMessage!
    let messages =
      trailing
      ? [user]
      : [
        user,
        ChatMessage(
          id: UUID(12043), role: .assistant, body: .text("Later answer"),
          createdAt: Date(timeIntervalSince1970: 2)),
      ]
    let snapshot = ConversationSnapshot(
      summary: summary, messages: messages, interruptedTurns: [interruption])
    if !trailing {
      queued.retryTransferConfirmed = true
      queued.existingUserMessage = nil
      state.retryJournals[queued.retryJournalID!]?.knownDurableCount = nil
    }
    state.queue = [queued]
    let reads = CallRecorder()
    let claims = CallRecorder()
    var history = HistoryClient.noop()
    history.claimTurnRetry = { _, _, _, _ in
      claims.record("claim")
      return nil
    }
    history.loadConversation = { _ in
      reads.record("read")
      return snapshot
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.historyClient = history
      $0.queryPipeline = Scheduler.hangingPipeline()
    }
    store.exhaustivity = .off
    await store.send(.dispatchNextIfIdle)
    if trailing { await store.receive(\.queuedRetryClaimed) }
    await store.receive(\.queuedRetryStaleChecked)
    if trailing {
      await store.finish()
      #expect(store.state.activeTurn == nil)
      #expect(store.state.chat?.messages == state.chat?.messages)
      #expect(store.state.chat?.interruptedTurn?.status == .manualRetryRequired)
      #expect(claims.recorded == ["claim"] && reads.recorded == ["read"])
    } else {
      await store.receive(\.backgroundTurnReady)
      #expect(store.state.activeTurn?.autoRetryCount == 1)
      #expect(store.state.activeTurn?.replacingJournalID == interruption.journalID)
      #expect(claims.recorded.isEmpty)
      await store.skipInFlightEffects()
    }
  }

  @Test func offscreenTransferPreservesConsumedRetryInMemoryAndSQLite() async throws {
    var (state, queued, interruption) = retryFixture()
    state.chat = ChatFeature.State(conversationID: b)
    state.queue = [queued]
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "creg-transfer-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let live = try HistoryClient.live(
      databaseURL: directory.appendingPathComponent("history.sqlite"))
    _ = try await live.bootstrap()
    _ = try await live.createConversation(a, queued.submittedAt)
    try await live.persistUserTurn(
      a, queued.existingUserMessage!, queued.submission, queued.submittedAt, nil)
    try await live.markTurnInterrupted(a, queued.retryJournalID!, false)
    #expect(
      try await live.claimTurnRetry(a, queued.retryJournalID!, queued.existingUserMessage!.id, true)
        == 1)
    try await live.markTurnInterrupted(a, queued.retryJournalID!, false)
    let later = ChatMessage(
      id: UUID(12050), role: .assistant, body: .text("Later answer"),
      createdAt: Date(timeIntervalSince1970: 2))
    try await live.appendMessage(a, later)
    let wrote = CallRecorder()
    var history = live
    history.persistUserTurn = { id, user, submission, time, replacing in
      try await live.persistUserTurn(id, user, submission, time, replacing)
      wrote.record("saved")
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.historyClient = history
      $0.queryPipeline = Scheduler.hangingPipeline()
    }
    store.exhaustivity = .off
    await store.send(.dispatchNextIfIdle)
    await store.receive(\.queuedRetryClaimed)
    await store.receive(\.queuedRetryStaleChecked)
    await store.receive(\.dispatchPreflightFinished)
    await store.receive(\.backgroundTurnReady)
    let executionID = try #require(store.state.activeTurn?.questionID)
    #expect(store.state.activeTurn?.conversationID == a)
    #expect(store.state.activeTurn?.autoRetryCount == interruption.autoRetryCount)
    #expect(store.state.retryJournals[executionID]?.knownDurableCount == 1)
    // The background grant is requested only after the SQLite user write settles.
    let snapshot = try await live.loadConversation(a)
    #expect(snapshot.interruptedTurns.first?.autoRetryCount == 1)
    #expect(snapshot.messages.filter { $0.previewText == queued.question }.count == 2)
    #expect(wrote.recorded == ["saved"])
    await store.skipInFlightEffects()
  }

  @Test(arguments: [false, true])
  func followUpContextSurvivesUndoAndRetiredGenerationDoesNotResume(retired: Bool) async {
    var state = Scheduler.appState(selected: b)
    state.isSceneActive = false
    let context = FollowUpSuggestionContext(
      sourceAssistantMessageID: UUID(12060),
      question: "Question", standaloneQuestion: "Question", narration: "Answer",
      result: QueryResult(columns: ["name"], rows: [[.text("Sable Tower")]]))
    state.conversations[id: a]?.suggestionGeneration = retired ? 4 : 3
    let pending = AppFeature.PendingScopeDiagnosis(
      conversationID: a, messageID: context.sourceAssistantMessageID,
      context: context, generation: 3, scopeDiagnosisCompleted: true)
    state.pendingSuggestionContexts[a] = pending
    let prepared = CallRecorder()
    let pipeline = QueryPipeline(
      run: { _, _ in AsyncStream { _ in } },
      prepareFollowUps: { context in
        prepared.record(context.question)
        return AsyncStream {
          $0.yield(.finished)
          $0.finish()
        }
      })
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.historyClient = .noop()
      $0.queryPipeline = pipeline
    }
    store.exhaustivity = .off
    await store.send(.deleteConversationTapped(a))
    #expect(store.state.pendingSuggestionContexts[a] == pending)
    await store.send(.undoDeleteTapped)
    #expect(store.state.pendingSuggestionContexts[a] == pending)
    await store.send(.appBecameActive)
    if !retired { await store.receive(\.followUpPreparationEvent) }
    await store.skipReceivedActions(strict: false)
    #expect(prepared.recorded == (retired ? [] : [context.question]))
    await store.finish()
  }
}
