import ComposableArchitecture
import Foundation
import Testing

@testable import CREGEngine
@testable import CREGFeatures

private actor SettlementGate {
  private var started = false
  private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  private var release: CheckedContinuation<Void, Never>?

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
      Issue.record("The expected history operation did not start.")
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

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RetrySettlementRegressionTests {
  private typealias Scheduler = AppFeatureSchedulerTests
  private static let conversationID = Scheduler.conversationA

  private func fixture(automatic: Bool = true) -> (AppFeature.State, QueuedQuestion) {
    let user = ChatMessage(
      id: UUID(11000), role: .user, body: .text("Retry this question"),
      createdAt: Date(timeIntervalSince1970: 1))
    let queued = QueuedQuestion(
      id: UUID(11001), conversationID: Self.conversationID,
      submission: QuestionSubmission(question: user.previewText), retryJournalID: user.id,
      existingUserMessage: user, automaticRetry: automatic, submittedAt: user.createdAt)
    var state = Scheduler.appState()
    state.chat?.messages.append(user)
    state.chat?.interruptedTurn = InterruptedTurn(
      question: user.previewText, interruptedAt: user.createdAt,
      journalID: user.id, executionID: user.id, status: .knownInterruption)
    state.holdRetryClaim(journalID: user.id, conversationID: Self.conversationID)
    return (state, queued)
  }

  private func database() throws -> (HistoryClient, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("creg-settlement-\(UUID().uuidString)", isDirectory: true)
    return (
      try HistoryClient.live(databaseURL: directory.appendingPathComponent("history.sqlite")),
      directory
    )
  }

  private func seed(_ history: HistoryClient, queued: QueuedQuestion) async throws {
    _ = try await history.bootstrap()
    _ = try await history.createConversation(Self.conversationID, queued.submittedAt)
    try await history.persistUserTurn(
      Self.conversationID, queued.existingUserMessage!, queued.submission, queued.submittedAt, nil)
    try await history.markTurnInterrupted(Self.conversationID, queued.retryJournalID!, false)
  }

  @Test func newerAskAgainInvalidatesHeldStaleRead() async throws {
    let (state, queued) = fixture()
    let (live, directory) = try database()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seed(live, queued: queued)
    let read = SettlementGate()
    let declines = CallRecorder()
    let claims = CallRecorder()
    var history = live
    history.loadConversation = { id in
      let snapshot = try await live.loadConversation(id)
      await read.hold()
      return snapshot
    }
    history.declineAutoRetry = { id, journal in
      declines.record("decline")
      try await live.declineAutoRetry(id, journal)
    }
    history.claimTurnRetry = { id, journal, execution, automatic in
      claims.record(automatic ? "automatic" : "manual")
      return try await live.claimTurnRetry(id, journal, execution, automatic)
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = ContinuousClock()
      $0.historyClient = history
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 3))
      $0.queryPipeline = Scheduler.hangingPipeline()
    }
    store.exhaustivity = .off
    await store.send(claimCompletion(queued, nil, state: store.state))
    await read.wait()
    await store.send(.chat(.delegate(.retryInterruptedTurnFor(queued.retryJournalID!))))
    await store.receive(\.queuedRetryClaimed)
    #expect(store.state.activeTurn?.directlyUserStarted == true)
    let activeID = store.state.activeTurn?.questionID
    await read.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.activeTurn?.questionID == activeID)
    #expect(store.state.pendingRetryStaleChecks.isEmpty)
    #expect(declines.recorded.isEmpty)
    #expect(claims.recorded == ["manual"])
    #expect(
      try await live.loadConversation(Self.conversationID).interruptedTurns.first?.status
        == .running)
    await store.skipInFlightEffects()
  }

  @Test func staleCheckBeforeAskAgainKeepsPrimaryFailureAndDispatchesOnce() async {
    var (state, queued) = fixture()
    state.clearHeldRetryClaims()
    state.holdRetryInspection(
      journalID: queued.retryJournalID!, conversationID: Self.conversationID, requestID: queued.id)
    let primary = FailurePresentation(
      code: "retry_claim_failed", title: "Could not retry automatically",
      message: "Ask Again to retry this question.", diagnostic: "refused")
    state.presentedFailure = primary
    let decline = SettlementGate()
    let diagnostics = DiagnosticEventRecorder()
    let claims = CallRecorder()
    let error = NSError(domain: "CREG.Cleanup", code: 1)
    var history = HistoryClient.noop()
    history.declineAutoRetry = { _, _ in
      await decline.hold()
      throw error
    }
    history.claimTurnRetry = { _, _, _, automatic in
      claims.record(automatic ? "automatic" : "manual")
      return 0
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = ContinuousClock()
      $0.historyClient = history
      $0.diagnostics = diagnostics.client
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 3))
      $0.queryPipeline = Scheduler.hangingPipeline()
    }
    store.exhaustivity = .off
    await store.send(inspectionCompletion(queued, true, state: store.state))
    await decline.wait()
    await store.send(.chat(.delegate(.retryInterruptedTurnFor(queued.retryJournalID!))))
    #expect(store.state.queue.count == 1)
    #expect(store.state.activeTurn == nil)
    await decline.finish()
    await store.receive(\.retryDeclineFinished)
    await store.receive(\.queuedRetryClaimed)
    await store.skipReceivedActions(strict: false)
    #expect(store.state.presentedFailure == primary)
    #expect(store.state.activeTurn?.directlyUserStarted == true)
    #expect(claims.recorded == ["manual"])
    #expect(diagnostics.events.filter { $0.code == "retry_claim_cleanup_failed" }.count == 1)
    await store.send(inspectionCompletion(queued, true, state: store.state))
    #expect(store.state.pendingRetryDeclines.isEmpty)
    await store.skipInFlightEffects()
  }

  @Test(arguments: [false, true])
  func deletionRetainsHeldDeclineAndWakesAnotherConversation(declineFails: Bool) async throws {
    var (state, queued) = fixture()
    state.clearHeldRetryClaims()
    state.queue = [
      queued,
      QueuedQuestion(
        id: UUID(11002), conversationID: Scheduler.conversationB,
        question: "Next question", submittedAt: Date(timeIntervalSince1970: 2)),
    ]
    let (live, directory) = try database()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seed(live, queued: queued)
    _ = try await live.createConversation(Scheduler.conversationB, queued.submittedAt)
    let decline = SettlementGate()
    let deletion = SettlementGate()
    let clock = TestClock()
    var history = live
    history.declineAutoRetry = { id, journal in
      await decline.hold()
      if declineFails { throw NSError(domain: "CREG.Decline", code: 2) }
      try await live.declineAutoRetry(id, journal)
    }
    history.deleteConversation = { id in
      try await live.deleteConversation(id)
      await deletion.hold()
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.historyClient = history
      $0.continuousClock = clock
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 3))
      $0.queryPipeline = Scheduler.hangingPipeline()
    }
    store.exhaustivity = .off
    await store.send(.chat(.delegate(.cancelQueued(queued.id))))
    await decline.wait()
    await store.send(.deleteConversationTapped(Self.conversationID))
    await store.send(.deleteCountdownFinished(store.state.pendingDeletion!.token))
    #expect(store.state.conversationDeletions[Self.conversationID]?.phase == .awaitingSettlement)
    #expect(!store.state.pendingRetryDeclines.isEmpty)
    await decline.finish()
    await store.receive(\.retryDeclineFinished)
    await deletion.wait()
    #expect(!(try await live.listConversations()).contains { $0.id == Self.conversationID })
    await deletion.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.pendingRetryDeclines.isEmpty)
    #expect(store.state.activeTurn?.conversationID == Scheduler.conversationB)
    #expect(store.state.presentedFailure == nil)
    await store.skipInFlightEffects()
  }

  @Test(
    arguments: [false, true],
    [
      (active: false, pressure: false), (active: true, pressure: false),
      (active: true, pressure: true),
    ])
  func declineSettlementResumesSuspendedPreparation(
    fails: Bool, environment: (active: Bool, pressure: Bool)
  ) async {
    let (sceneActive, pressure) = environment
    var state = Scheduler.appState()
    state.modelReadiness = .preparing
    state.isSceneActive = sceneActive
    state.thermalPressure = pressure
    state.suspendedModelPreparationMode = .evaluated
    let journal = UUID(11003)
    let operation = UUID(11004)
    state.installRetryDeclines(
      journalID: journal,
      writes: .init(
        conversationID: Self.conversationID, operationIDs: [operation]))
    let preparation = SettlementGate()
    let starts = CallRecorder()
    let pipeline = QueryPipeline(
      prepare: {
        starts.record("prepare")
        await preparation.hold()
      },
      run: { _, _ in AsyncStream { $0.finish() } })
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = ContinuousClock()
      $0.historyClient = .noop()
      $0.queryPipeline = pipeline
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 3))
    }
    store.exhaustivity = .off
    await store.send(.dispatchNextIfIdle)
    #expect(!store.state.modelPreparationInFlight)
    await store.send(
      .retryDeclineFinished(
        conversationID: Self.conversationID, journalID: journal, operationID: operation,
        failure: fails
          ? .history(operation: .messageSave, error: NSError(domain: "CREG.Decline", code: 3)) : nil
      ))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.modelPreparationInFlight == (sceneActive && !pressure))
    if sceneActive && !pressure {
      await preparation.wait()
      #expect(starts.recorded == ["prepare"])
      await store.send(
        .retryDeclineFinished(
          conversationID: Self.conversationID, journalID: journal, operationID: operation,
          failure: nil))
      #expect(starts.recorded == ["prepare"])
      await preparation.finish()
    } else {
      #expect(starts.recorded.isEmpty)
    }
    await store.finish()
  }

  @Test(arguments: [false, true])
  func claimedRetryDuringUndoIsReleasedDurably(automatic: Bool) async throws {
    var (state, queued) = fixture(automatic: automatic)
    let (live, directory) = try database()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seed(live, queued: queued)
    if !automatic {
      #expect(
        try await live.claimTurnRetry(
          Self.conversationID, queued.retryJournalID!, queued.existingUserMessage!.id, true) == 1)
      try await live.markTurnInterrupted(Self.conversationID, queued.retryJournalID!, false)
    }
    let count = try #require(
      try await live.claimTurnRetry(
        Self.conversationID, queued.retryJournalID!, queued.existingUserMessage!.id, automatic))
    let summary = state.conversations[id: Self.conversationID]!
    state.conversations.remove(id: Self.conversationID)
    state.installUndoDeletion(summary: summary)
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = ContinuousClock()
      $0.historyClient = live
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 3))
      $0.queryPipeline = Scheduler.hangingPipeline()
    }
    store.exhaustivity = .off
    await store.send(claimCompletion(queued, count, state: store.state))
    await store.receive(releaseCompletion(queued, nil, state: store.state))
    await store.skipReceivedActions(strict: false)
    let released = try #require(
      try await live.loadConversation(Self.conversationID).interruptedTurns.first)
    #expect(released.status == (automatic ? .knownInterruption : .manualRetryRequired))
    #expect(released.autoRetryCount == (automatic ? 0 : 1))
    #expect(store.state.activeTurn == nil)
    await store.send(.undoDeleteTapped)
    await store.receive(\.queuedRetryClaimed)
    #expect(store.state.activeTurn?.directlyUserStarted == !automatic)
    await store.skipInFlightEffects()
  }

  @Test(arguments: [false, true])
  func failedStoppedUserWriteCompletesDeferredDeletionOnce(timedOut: Bool) async throws {
    var (state, queued) = fixture()
    let (live, directory) = try database()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seed(live, queued: queued)
    _ = try await live.createConversation(Scheduler.conversationB, queued.submittedAt)
    state.clearHeldRetryClaims()
    state.chat?.interruptedTurns = []
    var active = AppFeature.ActiveTurn(
      questionID: queued.existingUserMessage!.id, conversationID: Self.conversationID,
      submission: queued.submission, startedAt: queued.submittedAt)
    active.optimisticUserTurn = .init(
      message: queued.existingUserMessage!, previousSummary: nil, previousChatTitle: nil)
    state.activeTurn = active
    let write = SettlementGate()
    let deletions = CallRecorder()
    let clock = TestClock()
    var history = live
    history.persistUserTurn = { _, _, _, _, _ in
      await write.hold()
      throw NSError(domain: "CREG.UserWrite", code: 4)
    }
    history.deleteConversation = { id in
      deletions.record("delete")
      try await live.deleteConversation(id)
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.historyClient = history
      $0.continuousClock = clock
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 3))
    }
    store.exhaustivity = .off
    await store.send(.chat(.delegate(.stopActiveTurn)))
    await write.wait()
    if timedOut {
      await store.send(.turnPersistenceTimedOut(queued.existingUserMessage!.id))
      #expect(store.state.presentedFailure?.code == "turn_persistence_barrier_timed_out")
    }
    await store.send(.deleteConversationTapped(Self.conversationID))
    await store.send(.deleteCountdownFinished(store.state.pendingDeletion!.token))
    #expect(store.state.conversationDeletions[Self.conversationID]?.phase == .awaitingSettlement)
    await write.finish()
    await store.receive(\.userTurnPersistenceFailed)
    await store.receive(.turnPersistenceFinished(queued.existingUserMessage!.id))
    await store.skipReceivedActions(strict: false)
    await clock.advance(by: .seconds(5))
    await store.finish()
    #expect(!store.state.conversationDeletions.values.contains { $0.phase == .awaitingSettlement })
    #expect(store.state.pendingTurnPersistence == nil)
    #expect(store.state.presentedFailure?.code != "turn_persistence_barrier_timed_out")
    #expect(deletions.recorded == ["delete"])
    #expect(!(try await live.listConversations()).contains { $0.id == Self.conversationID })
    await store.send(.turnPersistenceFinished(queued.existingUserMessage!.id))
    #expect(deletions.recorded == ["delete"])
  }

  @Test(arguments: [false, true])
  func cancellationClaimAndFailedReleaseRetainConsumedCount(cancelled: Bool) async {
    var (state, queued) = fixture()
    state.isSceneActive = false
    if cancelled { state.retryJournals[queued.retryJournalID!]?.intent = .cancelled(manualRequested: false) }
    let releaseError = NSError(domain: "CREG.Release", code: 5)
    var history = HistoryClient.noop()
    history.releaseAutoRetryClaim = { _, _, _, _ in throw releaseError }
    history.endTurnJournal = { _, _ in throw releaseError }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = ContinuousClock()
      $0.historyClient = history
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 3))
    }
    store.exhaustivity = .off
    await store.send(claimCompletion(queued, 1, state: store.state))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.chat?.interruptedTurn?.autoRetryCount == 1)
    let interruption = store.state.chat!.interruptedTurn!
    await store.send(
      .chat(
        .delegate(
          .dismissInterruptedTurn(
            conversationID: Self.conversationID, journalID: queued.retryJournalID!,
            interruption: interruption))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.pendingRetryDeclines.isEmpty)
    #expect(store.state.chat?.interruptedTurn?.autoRetryCount == 1)
    #expect(
      store.state.failedDismissalRecoveries[queued.retryJournalID!]?.interruption.autoRetryCount
        == 1)
  }

  @Test(arguments: ["release", "cancellation"])
  func retryWriteErrorsAreDeferredUntilUndo(operation: String) async {
    var (state, queued) = fixture()
    state.clearHeldRetryClaims()
    state.holdRetryRelease(journalID: queued.retryJournalID, conversationID: Self.conversationID)
    let summary = state.conversations[id: Self.conversationID]!
    state.conversations.remove(id: Self.conversationID)
    state.installUndoDeletion(summary: summary)
    let failure = FailurePresentation.history(
      operation: .messageSave, error: NSError(domain: "CREG.Release", code: 6))
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = ContinuousClock()
      $0.historyClient = .noop()
    }
    store.exhaustivity = .off
    await store.send(
      operation == "cancellation"
        ? cancellationCompletion(queued, failure, state: store.state)
        : releaseCompletion(queued, failure, state: store.state))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.presentedFailure == nil)
    #expect(store.state.pendingDeletion?.deferredFailure == failure)
    await store.send(.undoDeleteTapped)
    await store.receive(.operationFailed(failure))
    await store.finish()
  }

  @Test(arguments: ["release", "cancellation", "decline"])
  func deletedRetryWriteFailureIsSuppressedOnce(operation: String) async {
    var (state, queued) = fixture()
    let journal = queued.retryJournalID!
    let operationID = UUID(11020)
    state.clearHeldRetryClaims()
    state.conversations.remove(id: Self.conversationID)
    state.chat = nil
    state.holdRetryRelease(
      journalID: operation == "decline" ? nil : journal,
      conversationID: operation == "decline" ? nil : Self.conversationID)
    if operation == "decline" {
      state.installRetryDeclines(
        journalID: journal,
        writes: .init(
          conversationID: Self.conversationID, operationIDs: [operationID],
          purposes: [operationID: .cancellation]))
    }
    let failure = FailurePresentation.history(
      operation: .messageSave, error: NSError(domain: "CREG.Deleted", code: 10))
    let diagnostics = DiagnosticEventRecorder()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = ContinuousClock()
      $0.historyClient = .noop()
      $0.diagnostics = diagnostics.client
    }
    store.exhaustivity = .off
    let action: AppFeature.Action =
      switch operation {
      case "release": releaseCompletion(queued, failure, state: store.state)
      case "cancellation": cancellationCompletion(queued, failure, state: store.state)
      default:
        .retryDeclineFinished(
          conversationID: Self.conversationID, journalID: journal,
          operationID: operationID, failure: failure)
      }
    await store.send(action)
    await store.finish()
    await store.skipReceivedActions(strict: false)
    await store.send(action)
    #expect(store.state.presentedFailure == nil)
    #expect(
      diagnostics.events.filter { $0.code == "conversation_write_failed_after_deletion" }.count == 1
    )
  }

  @Test func dismissalFallbackFailurePreservesPrimaryAndRecordsOnce() async {
    var (state, queued) = fixture()
    state.clearHeldRetryClaims()
    state.isSceneActive = false
    let primaryError = NSError(domain: "CREG.Dismissal", code: 11)
    let cleanupError = NSError(domain: "CREG.Cleanup", code: 12)
    let primary = FailurePresentation.history(operation: .messageSave, error: primaryError)
    var history = HistoryClient.noop()
    history.endTurnJournal = { _, _ in throw primaryError }
    history.declineAutoRetry = { _, _ in throw cleanupError }
    let diagnostics = DiagnosticEventRecorder()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = ContinuousClock()
      $0.historyClient = history
      $0.diagnostics = diagnostics.client
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(
      .chat(
        .delegate(
          .dismissInterruptedTurn(
            conversationID: Self.conversationID, journalID: queued.retryJournalID!,
            interruption: state.chat!.interruptedTurn!))))
    await store.receive(\.interruptedDismissalFinished)
    await store.receive(.operationFailed(primary))
    await store.finish()
    #expect(store.state.presentedFailure == primary)
    #expect(store.state.chat?.interruptedTurn != nil)
    #expect(
      diagnostics.events.filter { $0.code == "retry_write_failed_after_dismissal" }.count == 1)
  }

  @Test(arguments: [false, true])
  func unrelatedDeclinePreservesReleasedRetry(automatic: Bool) async {
    var (state, queued) = fixture(automatic: automatic)
    let journal = UUID(11010)
    let operation = UUID(11011)
    state.installRetryDeclines(
      journalID: journal,
      writes: .init(
        conversationID: Scheduler.conversationB, operationIDs: [operation]))
    if automatic {
      state.installAutomaticCandidate(
        .init(
          journalID: queued.retryJournalID!, conversationID: Self.conversationID,
          submission: queued.submission, userMessage: queued.existingUserMessage!))
    }
    let claims = CallRecorder()
    var history = HistoryClient.noop()
    history.claimTurnRetry = { _, _, _, automatic in
      claims.record(automatic ? "automatic" : "manual")
      return automatic ? 1 : 0
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = ContinuousClock()
      $0.historyClient = history
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 3))
      $0.queryPipeline = Scheduler.hangingPipeline()
    }
    store.exhaustivity = .off
    await store.send(claimCompletion(queued, automatic ? 1 : 0, state: store.state))
    await store.receive(releaseCompletion(queued, nil, state: store.state))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.activeTurn == nil)
    #expect(store.state.queue.contains { $0.retryJournalID == queued.retryJournalID })
    await store.send(
      .retryDeclineFinished(
        conversationID: Scheduler.conversationB, journalID: journal, operationID: operation,
        failure: nil))
    await store.receive(\.queuedRetryClaimed)
    await store.skipReceivedActions(strict: false)
    #expect(store.state.activeTurn?.isAutomaticRetry == automatic)
    #expect(claims.recorded == [automatic ? "automatic" : "manual"])
    let activeID = store.state.activeTurn?.questionID
    await store.send(
      .retryDeclineFinished(
        conversationID: Scheduler.conversationB, journalID: journal, operationID: operation,
        failure: nil))
    #expect(store.state.activeTurn?.questionID == activeID)
    await store.skipInFlightEffects()
  }

  @Test(arguments: [false, true])
  func dismissedReleaseRestoresAuthoritativeCount(fails: Bool) async {
    var (state, queued) = fixture()
    let journal = queued.retryJournalID!
    state.clearHeldRetryClaims()
    state.holdRetryRelease(journalID: journal, conversationID: Self.conversationID)
    state.retryJournals[journal]?.intent = .dismissed
    var interruption = state.chat!.interruptedTurn!
    interruption.autoRetryCount = 1
    state.chat?.interruptedTurns = []
    let primary = FailurePresentation(
      code: "dismiss_failed", title: "Dismiss failed", message: "Try again.", diagnostic: "dismiss")
    state.installDismissal(
      .init(
        conversationID: Self.conversationID, journalID: journal, attemptID: UUID(11012),
        interruption: interruption, failure: primary))
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = ContinuousClock()
      $0.historyClient = .noop()
    }
    store.exhaustivity = .off
    await store.send(
      releaseCompletion(
        queued,
        fails
          ? .history(operation: .messageSave, error: NSError(domain: "CREG.Release", code: 9))
          : nil, state: store.state))
    await store.receive(.operationFailed(primary))
    await store.finish()
    #expect(store.state.chat?.interruptedTurn?.autoRetryCount == (fails ? 1 : 0))
    #expect(store.state.chat?.interruptedTurn?.canAutoRetry == false)
    #expect(
      store.state.failedDismissalRecoveries[journal]?.interruption.autoRetryCount == (fails ? 1 : 0)
    )
  }

  @Test func dismissedClaimCleanupFailureIsRecordedOnce() async {
    var (state, queued) = fixture()
    state.isSceneActive = false
    let journal = queued.retryJournalID!
    let interruption = state.chat!.interruptedTurn!
    let dismissalFailure = FailurePresentation.history(
      operation: .messageSave, error: NSError(domain: "CREG.Dismissal", code: 7))
    state.retryJournals[journal]?.intent = .dismissed
    state.chat?.interruptedTurns = []
    state.installDismissal(
      .init(
        conversationID: Self.conversationID, journalID: journal, attemptID: UUID(11005),
        interruption: interruption, failure: dismissalFailure))
    let cleanupError = NSError(domain: "CREG.Cleanup", code: 8)
    let diagnostics = DiagnosticEventRecorder()
    var history = HistoryClient.noop()
    history.declineAutoRetry = { _, _ in throw cleanupError }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = ContinuousClock()
      $0.historyClient = history
      $0.diagnostics = diagnostics.client
    }
    store.exhaustivity = .off
    await store.send(claimCompletion(queued, 1, state: store.state))
    let cleanupFailure = FailurePresentation.history(operation: .messageSave, error: cleanupError)
    await store.receive(cleanupCompletion(journal, cleanupFailure, state: store.state))
    await store.receive(.operationFailed(dismissalFailure))
    await store.finish()
    #expect(store.state.chat?.interruptedTurn?.autoRetryCount == 1)
    #expect(store.state.chat?.interruptedTurn?.status == .manualRetryRequired)
    await store.send(cleanupCompletion(journal, cleanupFailure, state: store.state))
    #expect(
      diagnostics.events.filter { $0.code == "retry_write_failed_after_dismissal" }.count == 1)
    #expect(store.state.presentedFailure == dismissalFailure)
  }
}
