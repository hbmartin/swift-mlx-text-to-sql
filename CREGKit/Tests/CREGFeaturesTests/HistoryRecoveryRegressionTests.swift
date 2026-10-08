import ComposableArchitecture
import Foundation
import Testing

@testable import CREGEngine
@testable import CREGFeatures

private actor RecoveryHeldRead {
  private var started = false
  private var release: CheckedContinuation<Void, Never>?
  private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

  func hold() async {
    started = true
    waiters.values.forEach { $0.resume() }
    waiters.removeAll()
    await withCheckedContinuation { release = $0 }
  }
  func wait() async {
    if started { return }
    let id = UUID()
    let backstop = Task {
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled, let waiter = waiters.removeValue(forKey: id) else { return }
      Issue.record("Expected history operation did not start")
      waiter.resume()
    }
    await withCheckedContinuation { waiters[id] = $0 }
    backstop.cancel()
  }
  func finish() { release?.resume(); release = nil }
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct HistoryRecoveryRegressionTests {
  private typealias Scheduler = AppFeatureSchedulerTests
  private let a = Scheduler.conversationA
  private let b = Scheduler.conversationB
  private let failure = FailurePresentation(code: "history_load_failed", title: "Read failed",
    message: "Please retry.", diagnostic: "read diagnostic")

  private func state(populated: Bool = false) -> AppFeature.State {
    var result = populated ? Scheduler.appState() : AppFeature.State(debugModelIdentity: nil, launchBenchmarkQuestion: nil)
    result.launchBenchmarkQuestion = nil
    result.didRequestPreparationJournalInspection = true
    result.didHandlePreparationJournalInspection = true
    result.modelReadiness = .ready
    result.isSceneActive = false
    return result
  }

  private func store(
    _ state: AppFeature.State, history: HistoryClient,
    clock: TestClock<Duration> = TestClock(), recorder: DiagnosticEventRecorder = DiagnosticEventRecorder()
  ) -> TestStoreOf<AppFeature> {
    let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
      $0.historyClient = history
      $0.continuousClock = clock
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.diagnostics = recorder.client
    }
    store.exhaustivity = .off
    return store
  }

  @Test func summaryFailureSurvivesNewChatAndRetryRestoresSearchWithoutSelecting() async throws {
    let calls = CallRecorder()
    let summary = Scheduler.appState().conversations[id: a]!
    var history = HistoryClient.noop()
    history.bootstrap = {
      calls.record("bootstrap")
      if calls.recorded.count == 1 { throw DiagnosticsTestError.failed("summaries") }
      return [summary]
    }
    let store = store(state(), history: history)
    await store.send(.onAppear)
    await store.receive(\.historyBootstrapFailed)
    await store.send(.newChatTapped)
    await store.receive(\.conversationCreated)
    let selected = try #require(store.state.chat?.conversationID)
    #expect(store.state.presentedFailure?.code == "history_load_failed")
    #expect(store.state.presentedFailure?.message == "CREG couldn’t load your conversation history. Tap Retry history to try again.")
    let hit = ConversationSearchHit(conversationID: a, title: "Saved", snippet: "Question",
      lastActivityAt: Date(timeIntervalSince1970: 1))
    await store.send(.searchResults([hit]))
    #expect(store.state.visibleSearchHits.isEmpty)
    await store.send(.retryHistoryTapped)
    await store.receive(\.bootstrapFinished)
    await store.finish()
    #expect(store.state.chat?.conversationID == selected)
    #expect(store.state.visibleConversations.count == 2)
    #expect(store.state.visibleSearchHits == [hit])
    #expect(store.state.presentedFailure == nil)
  }

  @Test(arguments: [false, true])
  func newChatWinsHeldBootstrapWithoutExtraCreation(savedHistory: Bool) async {
    let held = RecoveryHeldRead()
    let creates = CallRecorder()
    let summaries = savedHistory ? Array(Scheduler.appState().conversations) : []
    var history = HistoryClient.noop()
    history.bootstrap = { await held.hold(); return summaries }
    history.createConversation = { id, date in
      creates.record(id.uuidString)
      return ConversationSummary(id: id, title: "", startedAt: date, lastActivityAt: date)
    }
    let store = store(state(), history: history)
    await store.send(.onAppear)
    await held.wait()
    await store.send(.newChatTapped)
    await store.send(.newChatTapped)
    #expect(creates.recorded.isEmpty)
    await held.finish()
    await store.receive(\.bootstrapFinished)
    await store.receive(\.conversationCreated)
    await store.finish()
    #expect(creates.recorded.count == 1)
    #expect(store.state.chat?.messages.isEmpty == true)
    #expect(store.state.conversations.count == summaries.count + 1)
  }

  @Test func newChatWinsAutomaticLoadAndObsoleteResultsCannotCloseBrowser() async throws {
    let held = RecoveryHeldRead()
    let summary = Scheduler.appState().conversations[id: a]!
    var history = HistoryClient.noop()
    history.bootstrap = { [summary] }
    history.loadConversation = { _ in
      await held.hold()
      return ConversationSnapshot(summary: summary)
    }
    let store = store(state(), history: history)
    await store.send(.onAppear)
    await store.receive(\.bootstrapFinished)
    await held.wait()
    let oldRequest = try #require(store.state.conversationOpening?.requestID)
    await store.send(.newChatTapped)
    await store.receive(\.conversationCreated)
    let selected = store.state.chat?.conversationID
    await store.send(.browserButtonTapped)
    await held.finish()
    await store.send(.conversationLoaded(ConversationSnapshot(summary: summary), requestID: oldRequest))
    await store.send(.conversationOpeningFailed(oldRequest, failure))
    await store.finish()
    #expect(store.state.chat?.conversationID == selected)
    #expect(store.state.isBrowserRevealed)
    #expect(store.state.presentedFailure == nil)
  }

  @Test(arguments: [false, true])
  func newChatAdoptsAutomaticCreationAndCoalescesRepeatedTaps(refreshInFlight: Bool) async {
    let held = RecoveryHeldRead()
    let refresh = RecoveryHeldRead()
    let calls = CallRecorder()
    let bootstraps = CallRecorder()
    var history = HistoryClient.noop()
    history.bootstrap = {
      bootstraps.record("bootstrap")
      if bootstraps.recorded.count > 1 { await refresh.hold() }
      return []
    }
    history.createConversation = { id, date in
      calls.record(id.uuidString)
      await held.hold()
      return ConversationSummary(id: id, title: "", startedAt: date, lastActivityAt: date)
    }
    let store = store(state(), history: history)
    await store.send(.onAppear)
    await store.receive(\.bootstrapFinished)
    await held.wait()
    if refreshInFlight {
      await store.send(.retryHistoryTapped)
      await refresh.wait()
    }
    await store.send(.newChatTapped)
    await store.send(.newChatTapped)
    await held.finish()
    await store.receive(\.conversationCreated)
    if refreshInFlight {
      await refresh.finish()
      await store.receive(\.bootstrapFinished)
    }
    await store.finish()
    #expect(calls.recorded.count == 1)
    #expect(store.state.visibleConversations.count == 1)
    #expect(store.state.chat != nil)
  }

  @Test func deletingAnOpeningCreationCannotAdoptOrResurrectItsLateCompletion() async throws {
    let held = RecoveryHeldRead()
    let creates = CallRecorder()
    var history = HistoryClient.noop()
    history.bootstrap = {
      guard let value = creates.recorded.first, let id = UUID(uuidString: value) else { return [] }
      return [ConversationSummary(id: id, title: "", startedAt: Date(timeIntervalSince1970: 100),
        lastActivityAt: Date(timeIntervalSince1970: 100))]
    }
    history.createConversation = { id, date in
      creates.record(id.uuidString)
      if creates.recorded.count == 1 { await held.hold() }
      return ConversationSummary(id: id, title: "", startedAt: date, lastActivityAt: date)
    }
    let store = store(state(), history: history)
    await store.send(.onAppear)
    await store.receive(\.bootstrapFinished)
    await held.wait()
    let oldID = try #require(creates.recorded.first.flatMap(UUID.init(uuidString:)))
    await store.send(.retryHistoryTapped)
    await store.receive(\.bootstrapFinished)
    await store.send(.deleteConversationTapped(oldID))
    let token = try #require(store.state.pendingDeletion?.token)
    await store.receive(\.conversationCreated)
    let selection = try #require(store.state.chat?.conversationID)
    #expect(selection != oldID)
    await store.send(.deleteCountdownFinished(token))
    #expect(store.state.conversationDeletions[oldID]?.phase == .awaitingSettlement)
    await store.send(.browserButtonTapped)
    await held.finish()
    await store.receive(\.conversationCreated)
    await store.receive(\.conversationDeletionFinished)
    await store.finish()
    #expect(creates.recorded.count == 2)
    #expect(store.state.chat?.conversationID == selection)
    #expect(store.state.conversations[id: oldID] == nil)
    #expect(store.state.isBrowserRevealed)
    #expect(!store.state.isOpeningConversation)
  }

  @Test func refreshedSummariesPreserveLocalEditsCreationsAndDeletionState() async {
    let held = RecoveryHeldRead()
    var initial = state(populated: true)
    initial.installUndoDeletion(summary: initial.conversations[id: b]!)
    let snapshot = Array(initial.conversations)
    let newID = UUID(17020)
    let newSummary = ConversationSummary(id: newID, title: "Local new chat",
      startedAt: Date(timeIntervalSince1970: 100), lastActivityAt: Date(timeIntervalSince1970: 100))
    var history = HistoryClient.noop()
    history.bootstrap = { await held.hold(); return snapshot }
    initial.conversationOpening = .init(requestID: 9000, kind: .create(newID))
    let store = store(initial, history: history)
    await store.send(.retryHistoryTapped)
    await held.wait()
    await store.send(.chat(.delegate(.renameRequested(a, "Local edit"))))
    await store.send(.conversationCreated(newSummary, requestID: 9000))
    await held.finish()
    await store.receive(\.bootstrapFinished)
    await store.finish()
    #expect(store.state.conversations[id: a]?.title == "Local edit")
    #expect(store.state.conversations[id: newID] == newSummary)
    #expect(store.state.visibleConversations.contains { $0.id == b } == false)
    #expect(store.state.chat?.conversationID == newID)
  }

  @Test func dismissedOpeningFailureIsIdleAndCanRetryWithoutClearingOtherErrors() async {
    let calls = CallRecorder()
    let summary = Scheduler.appState().conversations[id: b]!
    var history = HistoryClient.noop()
    history.loadConversation = { _ in
      calls.record("load")
      if calls.recorded.count == 1 { throw DiagnosticsTestError.failed("load") }
      return ConversationSnapshot(summary: summary)
    }
    var initial = state(populated: true)
    initial.chat = nil
    let store = store(initial, history: history)
    await store.send(.conversationSelected(b))
    await store.receive(\.conversationOpeningFailed)
    await store.send(.dismissFailure)
    #expect(!store.state.isOpeningConversation)
    #expect(store.state.presentedFailure == nil)
    await store.send(.operationFailed(failure))
    await store.send(.retryConversationOpeningTapped)
    await store.receive(\.conversationLoaded)
    await store.finish()
    #expect(store.state.chat?.conversationID == b)
    #expect(store.state.presentedFailure == failure)
  }

  @Test func deletingReplacementBeforeItsLoadCompletesRejectsTheLateSnapshot() async throws {
    let held = RecoveryHeldRead()
    let clock = TestClock()
    let summary = Scheduler.appState().conversations[id: b]!
    var history = HistoryClient.noop()
    history.loadConversation = { _ in await held.hold(); return ConversationSnapshot(summary: summary) }
    let store = store(state(populated: true), history: history, clock: clock)
    await store.send(.deleteConversationTapped(a))
    await held.wait()
    let request = try #require(store.state.conversationOpening?.requestID)
    await store.send(.deleteConversationTapped(b))
    await store.receive(\.conversationCreated)
    let selected = store.state.chat?.conversationID
    await held.finish()
    await store.send(.conversationLoaded(ConversationSnapshot(summary: summary), requestID: request))
    #expect(store.state.chat?.conversationID == selected)
    #expect(!store.state.isOpeningConversation)
    await clock.advance(by: .seconds(5))
    await store.finish()
  }

  @Test func newChatIntentSurvivesStoreOpenFailureUntilExplicitRetry() async {
    let held = RecoveryHeldRead()
    let bootstraps = CallRecorder()
    let creates = CallRecorder()
    let summary = Scheduler.appState().conversations[id: a]!
    var history = HistoryClient.noop()
    history.bootstrap = {
      bootstraps.record("bootstrap")
      if bootstraps.recorded.count == 1 {
        await held.hold()
        throw HistoryStoreUnavailableError(diagnostic: "open failed")
      }
      return [summary]
    }
    history.createConversation = { id, date in
      creates.record(id.uuidString)
      return ConversationSummary(id: id, title: "", startedAt: date, lastActivityAt: date)
    }
    let store = store(state(), history: history)
    await store.send(.onAppear)
    await held.wait()
    await store.send(.newChatTapped)
    await held.finish()
    await store.receive(\.historyBootstrapFailed)
    #expect(!store.state.canCreateConversation)
    #expect(store.state.newChatRequestedDuringBootstrap)
    await store.send(.retryHistoryTapped)
    await store.receive(\.bootstrapFinished)
    await store.receive(\.conversationCreated)
    await store.finish()
    #expect(creates.recorded.count == 1)
    #expect(store.state.chat?.conversationID != a)
    #expect(store.state.presentedFailure == nil)
  }

  @Test func unavailableStoreDisablesNewChatAndRepeatedRetryRemainsHonest() async {
    let calls = CallRecorder()
    var history = HistoryClient.noop()
    history.bootstrap = {
      calls.record("open")
      throw HistoryStoreUnavailableError(diagnostic: "open failed")
    }
    let store = store(state(), history: history)
    await store.send(.onAppear)
    await store.receive(\.historyBootstrapFailed)
    #expect(!store.state.canCreateConversation)
    #expect(store.state.presentedFailure?.message == "CREG couldn’t open your conversation history. Tap Retry history to try again.")
    await store.send(.newChatTapped)
    #expect(store.state.conversationCreationInFlight == nil)
    await store.send(.dismissFailure)
    #expect(!store.state.isOpeningConversation)
    #expect(store.state.canRetryHistory)
    await store.send(.retryHistoryTapped)
    await store.receive(\.historyBootstrapFailed)
    await store.finish()
    #expect(calls.recorded.count == 2)
    #expect(store.state.presentedFailure?.code == "history_load_failed")
    await store.send(.retryHistoryTapped)
    await store.receive(\.historyBootstrapFailed)
    await store.finish()
    #expect(store.state.visibleFailures.count == 1)
  }

  @Test func recoverableClientRetriesOpeningAndRetainsTheHealthyConnection() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("creg-recovery-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let calls = CallRecorder()
    let url = directory.appendingPathComponent("history.sqlite")
    let history = HistoryClient.recoverable(open: {
      calls.record("open")
      if calls.recorded.count == 1 { throw DiagnosticsTestError.failed("temporary open failure") }
      return try .live(databaseURL: url)
    })
    do {
      _ = try await history.bootstrap()
      Issue.record("The first open must fail")
    } catch { #expect(error is HistoryStoreUnavailableError) }
    do {
      _ = try await history.createConversation(a, Date(timeIntervalSince1970: 1))
      Issue.record("Only bootstrap may reopen the store")
    } catch { #expect(error is HistoryStoreUnavailableError) }
    #expect(calls.recorded.count == 1)
    _ = try await history.bootstrap()
    _ = try await history.createConversation(a, Date(timeIntervalSince1970: 1))
    try await history.renameConversation(a, "Recovered conversation")
    let message = ChatMessage(id: UUID(17021), role: .user, body: .text("Recovered question"),
      createdAt: Date(timeIntervalSince1970: 2))
    try await history.appendMessage(a, message)
    async let first = history.bootstrap()
    async let second = history.bootstrap()
    _ = try await (first, second)
    let snapshot = try await history.loadConversation(a)
    #expect(snapshot.messages == [message])
    #expect(snapshot.summary.title == "Recovered conversation")
    #expect(try await history.search("Recovered").contains { $0.conversationID == a })
    #expect(calls.recorded.count == 2)
  }

  @Test func promotedAutomaticRefusalProducesManualFeedbackInItsOwnConversation() async throws {
    var initial = state(populated: true)
    let journal = UUID(17030)
    let operation = UUID(17031)
    let user = ChatMessage(id: UUID(17032), role: .user, body: .text("Retry question"),
      createdAt: Date(timeIntervalSince1970: 1))
    let interruption = InterruptedTurn(question: user.previewText, interruptedAt: user.createdAt,
      journalID: journal, executionID: user.id, status: .knownInterruption)
    initial.chat?.messages.append(user)
    initial.chat?.interruptedTurns.append(interruption)
    initial.seedRetry(journal, conversationID: a, interruption: interruption)
    let queued = QueuedQuestion(id: UUID(17033), conversationID: a,
      submission: QuestionSubmission(question: user.previewText), retryJournalID: journal,
      existingUserMessage: user, automaticRetry: true, submittedAt: user.createdAt)
    initial.retryJournals[journal]?.operations[operation] = .claim(queued)
    let summaryA = initial.conversations[id: a]!
    let summaryB = initial.conversations[id: b]!
    let held = RecoveryHeldRead()
    var history = HistoryClient.noop()
    history.claimTurnRetry = { _, _, _, _ in nil }
    history.loadConversation = { id in
      if id == summaryA.id { await held.hold() }
      return ConversationSnapshot(summary: id == summaryA.id ? summaryA : summaryB)
    }
    let store = store(initial, history: history)
    await store.send(.chat(.delegate(.retryInterruptedTurnFor(journal))))
    await store.send(.queuedRetryClaimed(queued, .refused, operationID: operation))
    await store.receive(\.queuedRetryClaimed)
    await held.wait()
    #expect(store.state.chat?.inspectingRetryJournalIDs.contains(journal) == true)
    #expect(store.state.chat?.queuedRetryJournalIDs.contains(journal) == false)
    await store.send(.conversationSelected(b))
    await store.receive(\.conversationLoaded)
    await store.send(.operationFailed(failure, owner: .conversation(b)))
    await held.finish()
    await store.receive(\.queuedRetryStaleChecked)
    await store.receive(\.operationFailed)
    #expect(store.state.presentedFailure == failure)
    let retained = try #require(store.state.failures.first { $0.failure.code == "retry_journal_missing" })
    if case .retry(let id, let journalID, _) = retained.owner {
      #expect(id == a)
      #expect(journalID == journal)
    } else { Issue.record("The retry must retain its conversation owner") }
    // Inspect visibility without starting another held history operation.
    var returned = store.state
    returned.chat = ChatFeature.State(conversationID: a)
    #expect(returned.presentedFailure?.title == "Retry unavailable")
    await store.finish()
  }

  @Test(arguments: [false, true])
  func childOperationFailuresRetainTheirOriginAfterSwitching(write: Bool) async {
    let held = RecoveryHeldRead()
    var initial = state(populated: true)
    initial.chat?.renameDraft = "Updated title"
    var history = HistoryClient.noop()
    history.renameConversation = { _, _ in
      await held.hold(); throw DiagnosticsTestError.failed("rename failure")
    }
    history.exportJSONL = { _ in
      await held.hold(); throw DiagnosticsTestError.failed("export failure")
    }
    let store = store(initial, history: history)
    await store.send(.chat(write ? .renameCommitted : .exportTapped))
    await store.receive(\.chat.delegate)
    await held.wait()
    await store.send(.conversationSelected(b))
    await store.receive(\.conversationLoaded)
    await store.send(.operationFailed(failure, owner: .conversation(b)))
    await held.finish()
    if write {
      await store.receive(\.summaryWriteSettled)
      await store.receive(\.operationFailed)
    } else { await store.receive(\.conversationExportFinished) }
    await store.finish()
    #expect(store.state.presentedFailure == failure)
    let owned = store.state.failures.first { $0.owner == .conversation(a) }
    #expect(owned?.failure.code == (write ? "history_rename_failed" : "history_export_failed"))
  }

  @Test(arguments: [false, true])
  func inspectionTimeoutRestoresManualRetryOrStaysDismissed(dismiss: Bool) async {
    var initial = state(populated: true)
    let journal = UUID(17100)
    let operation = UUID(17101)
    let message = ChatMessage(id: UUID(17102), role: .user, body: .text("Check this retry"),
      createdAt: Date(timeIntervalSince1970: 1))
    let interruption = InterruptedTurn(question: message.previewText, interruptedAt: message.createdAt,
      journalID: journal, executionID: message.id, status: .knownInterruption)
    initial.chat?.messages.append(message)
    initial.chat?.interruptedTurns.append(interruption)
    initial.seedRetry(journal, conversationID: a, interruption: interruption)
    let queued = QueuedQuestion(id: UUID(17103), conversationID: a,
      submission: QuestionSubmission(question: message.previewText), retryJournalID: journal,
      existingUserMessage: message, automaticRetry: false, submittedAt: message.createdAt)
    initial.retryJournals[journal]?.operations[operation] = .claim(queued)
    let held = RecoveryHeldRead()
    let summary = initial.conversations[id: a]!
    let clock = TestClock()
    var history = HistoryClient.noop()
    history.loadConversation = { _ in await held.hold(); return ConversationSnapshot(summary: summary) }
    let store = store(initial, history: history, clock: clock)
    await store.send(.queuedRetryClaimed(queued, .refused, operationID: operation))
    await held.wait()
    #expect(store.state.chat?.inspectingRetryJournalIDs.contains(journal) == true)
    if dismiss {
      await store.send(.chat(.interruptedDismissedFor(journal)))
      await store.receive(\.interruptedDismissalFinished)
    }
    await clock.advance(by: .seconds(5))
    if !dismiss {
      await store.receive(\.queuedRetryStaleChecked)
      await store.receive(\.operationFailed)
      #expect(store.state.presentedFailure?.code == "retry_inspection_timed_out")
      #expect(store.state.chat?.interruptedTurns.last?.status == .manualRetryRequired)
    }
    #expect(store.state.chat?.inspectingRetryJournalIDs.contains(journal) == false)
    #expect(store.state.chat?.queuedRetryJournalIDs.contains(journal) == false)
    await held.finish()
    await store.finish()
    if dismiss {
      #expect(store.state.presentedFailure == nil)
      #expect(store.state.chat?.interruptedTurns.isEmpty == true)
    }
  }

  @Test(arguments: ["undo", "failure", "success"])
  func multipleDeferredFailuresSurviveResolutionWithoutDuplicateReporting(resolution: String) async {
    var initial = state(populated: true)
    initial.chat = ChatFeature.State(conversationID: b)
    initial.installUndoDeletion(summary: initial.conversations[id: a]!)
    let token = initial.pendingDeletion!.token
    if resolution != "undo" { initial.conversationDeletions[a]?.phase = .committing }
    let first = FailurePresentation(code: "write_one", title: "First", message: "First failure", diagnostic: "first detail")
    let second = FailurePresentation(code: "write_two", title: "Second", message: "Second failure", diagnostic: "second detail")
    let deletion = FailurePresentation(code: "history_delete_failed", title: "Delete", message: "Delete failure", diagnostic: "delete detail")
    let recorder = DiagnosticEventRecorder()
    let store = store(initial, history: .noop(), recorder: recorder)
    await store.send(.conversationWriteFailed(conversationID: a, failure: first))
    await store.send(.conversationWriteFailed(conversationID: a, failure: second))
    await store.send(.conversationWriteFailed(conversationID: a, failure: first))
    #expect(store.state.conversationDeletions[a]?.deferredFailures == [first, second])
    if resolution == "undo" { await store.send(.undoDeleteTapped) }
    else { await store.send(.conversationDeletionFinished(a, token: token, failure: resolution == "failure" ? deletion : nil)) }
    await store.finish()
    if resolution == "success" {
      #expect(store.state.presentedFailure == nil)
      let events = recorder.events.filter { $0.code == "conversation_write_failed_after_deletion" }
      #expect(events.map { $0.context["failure_code"] } == [first.code, second.code])
    } else {
      let presentation = store.state.presentedFailure
      #expect(presentation?.message.contains(first.message) == true)
      #expect(presentation?.message.contains(second.message) == true)
      for failure in [first, second] { #expect(recorder.events.filter { $0.code == failure.code }.count == 1) }
      let details = presentation?.technicalDetails(developerMode: true) ?? ""
      for code in resolution == "failure" ? [deletion.code, first.code, second.code] : [first.code, second.code] {
        #expect(details.components(separatedBy: "[\(code)]").count == 2)
      }
    }
    await store.send(.conversationDeletionFinished(a, token: token, failure: nil))
    #expect(recorder.events.filter { $0.code == first.code }.count == (resolution == "success" ? 0 : 1))
  }

  @Test func retryAndDeletionDiagnosticsShareOneCounterAndIgnoreDuplicateCompletions() async {
    let journal = UUID(uuidString: "17AE93D3-94B8-4A7E-B881-CC51CBB9E110")!
    let other = UUID(uuidString: "17AE93D3-94B8-4A7E-B881-CC51CBB9E111")!
    var initial = state(populated: true)
    initial.seedRetry(journal, conversationID: a)
    initial.seedRetry(other, conversationID: b)
    for operation in [UUID(17200), UUID(17201)] {
      initial.retryJournals[journal]?.operations[operation] = .decline(.refusedClaimCleanup)
    }
    initial.retryJournals[other]?.operations[UUID(17202)] = .decline(.refusedClaimCleanup)
    let recorder = DiagnosticEventRecorder()
    let store = store(initial, history: .noop(), recorder: recorder)
    for (id, conversationID, operation) in [(journal, a, UUID(17200)), (journal, a, UUID(17200)),
      (journal, a, UUID(17201)), (other, b, UUID(17202))] {
      await store.send(.retryDeclineFinished(conversationID: conversationID, journalID: id,
        operationID: operation, failure: failure))
    }
    await store.send(.deleteConversationTapped(a))
    await store.send(.undoDeleteTapped)
    await store.finish()
    let retryEvents = recorder.events.filter { $0.code == "retry_claim_cleanup_failed" }
    #expect(retryEvents.count == 3)
    let numbers = retryEvents.map { $0.context["operation_number"] }
    #expect(numbers[0] == numbers[1])
    #expect(numbers[0] != numbers[2])
    let deletionNumber = recorder.events.first { $0.code == "conversation_delete_pending" }?.context["operation_number"]
    #expect(deletionNumber != nil, "\(recorder.events.map(\.code))")
    #expect(!numbers.contains(deletionNumber))
    #expect(retryEvents.allSatisfy { $0.context["journal_id"] == nil })
  }

  @Test func deletionDiagnosticsUseDistinctNumbersWithRealVersionFourUUIDs() async {
    let id = UUID(uuidString: "17AE93D3-94B8-4A7E-B881-CC51CBB9E100")!
    var initial = state(populated: true)
    initial.conversations[id: id] = ConversationSummary(id: id, title: "Version four",
      startedAt: Date(timeIntervalSince1970: 1), lastActivityAt: Date(timeIntervalSince1970: 1))
    let recorder = DiagnosticEventRecorder()
    let store = store(initial, history: .noop(), recorder: recorder)
    for _ in 0..<2 {
      await store.send(.deleteConversationTapped(id))
      await store.send(.undoDeleteTapped)
    }
    await store.finish()
    let events = recorder.events.filter { $0.code.hasPrefix("conversation_delete_") }
    #expect(events.count == 4)
    #expect(events[0].context["operation_number"] == events[1].context["operation_number"])
    #expect(events[2].context["operation_number"] == events[3].context["operation_number"])
    #expect(events[0].context["operation_number"] != events[2].context["operation_number"])
    #expect(events.allSatisfy { !$0.context.values.contains(id.uuidString) && $0.context["deletion_token"] == nil })
    let privacy = DiagnosticEventRecorder()
    privacy.client.info(category: .history, code: "privacy_test", summary: "Identifier boundary",
      context: ["identifier": id.uuidString])
    #expect(privacy.events.first?.context["identifier"] == "<redacted identifier>")
  }
  @Test(arguments: 0..<10)
  func reselectingCurrentConversationCancelsReplacedLoad(iteration: Int) async throws {
    let held = RecoveryHeldRead()
    let initial = state(populated: true)
    let snapshot = ConversationSnapshot(summary: initial.conversations[id: b]!)
    var history = HistoryClient.noop()
    history.loadConversation = { _ in await held.hold(); return snapshot }
    let store = store(initial, history: history)
    await store.send(.conversationSelected(b))
    await held.wait()
    let request = try #require(store.state.conversationOpening?.requestID)
    await store.send(.conversationSelected(a))
    await held.finish()
    await store.send(.conversationLoaded(snapshot, requestID: request))
    await store.finish()
    #expect(store.state.chat?.conversationID == a)
    #expect(store.state.conversationOpening == nil)
    #expect(!store.state.isBrowserRevealed)
  }

  @Test(arguments: 0..<10)
  func deletingCurrentChatPreservesAnotherOpening(iteration: Int) async throws {
    let held = RecoveryHeldRead()
    let initial = state(populated: true)
    let snapshot = ConversationSnapshot(summary: initial.conversations[id: b]!)
    var history = HistoryClient.noop()
    history.loadConversation = { _ in await held.hold(); return snapshot }
    let store = store(initial, history: history)
    await store.send(.conversationSelected(b))
    await held.wait()
    let opening = store.state.conversationOpening
    await store.send(.deleteConversationTapped(a))
    #expect(store.state.conversationOpening == opening)
    await held.finish()
    await store.receive(\.conversationLoaded)
    await store.send(.undoDeleteTapped)
    await store.finish()
    #expect(store.state.chat?.conversationID == b)
  }

  @Test func creationFailureAfterReplacementLogsOnceWithoutPresentation() async throws {
    let held = RecoveryHeldRead()
    let initial = state(populated: true)
    let snapshot = ConversationSnapshot(summary: initial.conversations[id: b]!)
    var history = HistoryClient.noop()
    history.createConversation = { _, _ in await held.hold(); throw DiagnosticsTestError.failed("create") }
    history.loadConversation = { _ in snapshot }
    let recorder = DiagnosticEventRecorder()
    let store = store(initial, history: history, recorder: recorder)
    await store.send(.newChatTapped)
    await held.wait()
    let creationRequest = store.state.conversationOpening!.requestID
    await store.send(.conversationSelected(b))
    await store.receive(\.conversationLoaded)
    await held.finish()
    await store.receive(\.conversationOpeningFailed)
    await store.send(.conversationOpeningFailed(creationRequest, failure))
    await store.finish()
    #expect(store.state.chat?.conversationID == b)
    #expect(store.state.visibleFailures.isEmpty)
    #expect(recorder.events.filter { $0.code == "history_conversation_create_failed" }.count == 1)
  }

  @Test func newChatStartsDuringRefreshAndCoalescesRepeatedRequests() async {
    let read = RecoveryHeldRead()
    let create = RecoveryHeldRead()
    let calls = CallRecorder()
    var history = HistoryClient.noop()
    history.bootstrap = { await read.hold(); return [] }
    history.createConversation = { id, date in
      calls.record("create")
      await create.hold()
      return ConversationSummary(id: id, title: "", startedAt: date, lastActivityAt: date)
    }
    let store = store(state(populated: true), history: history)
    await store.send(.retryHistoryTapped)
    await read.wait()
    await store.send(.newChatTapped)
    await create.wait()
    await store.send(.newChatTapped)
    #expect(calls.recorded == ["create"])
    await create.finish()
    await store.receive(\.conversationCreated)
    let selected = store.state.chat?.conversationID
    await read.finish()
    await store.receive(\.bootstrapFinished)
    await store.finish()
    #expect(store.state.chat?.conversationID == selected)
    #expect(selected != a)
  }

  @Test func summaryTimeoutRetainsNewChatIntentAndRejectsLateResults() async throws {
    let read = RecoveryHeldRead()
    let calls = CallRecorder()
    let clock = TestClock()
    var history = HistoryClient.noop()
    history.bootstrap = {
      calls.record("read")
      if calls.recorded.count == 1 { await read.hold() }
      return []
    }
    let store = store(state(), history: history, clock: clock)
    await store.send(.onAppear)
    await read.wait()
    let old = store.state.historyRequestSequence
    await store.send(.newChatTapped)
    await clock.advance(by: .seconds(5))
    await store.receive(\.historySummaryTimedOut)
    #expect(store.state.canRetryHistory)
    #expect(store.state.newChatRequestedDuringBootstrap)
    #expect(store.state.chat == nil)
    await store.send(.retryHistoryTapped)
    await store.receive(\.bootstrapFinished)
    await store.receive(\.conversationCreated)
    let selected = store.state.chat?.conversationID
    await read.finish()
    await store.send(.bootstrapFinished([], requestID: old))
    await store.finish()
    #expect(store.state.chat?.conversationID == selected)
    #expect(store.state.historyStoreAvailability == .available)
    #expect(store.state.failures.isEmpty)
  }

  @Test(arguments: [false, true])
  func warningOwnershipSurvivesOtherErrorsAndNavigation(dismissWarning: Bool) async {
    let question = UUID(17500)
    var initial = state(populated: true)
    initial.pendingTurnPersistence = .init(questionID: question, conversationID: a)
    initial.storeFailure(failure, owner: .historySummaries(1))
    initial.storeFailure(failure, owner: .conversation(a))
    initial.seedRetry(UUID(17501), conversationID: a)
    initial.storeFailure(failure, owner: .retry(conversationID: a, journalID: UUID(17501), generation: 0))
    let clock = TestClock()
    let recorder = DiagnosticEventRecorder()
    let store = store(initial, history: .noop(), clock: clock, recorder: recorder)
    await store.send(.turnPersistenceTimedOut(question))
    #expect(store.state.visibleFailures.count == 4)
    await store.send(.operationFailed(failure, owner: .conversation(a)))
    if dismissWarning {
      await store.send(.dismissOwnedFailure(.turnPersistence(question)))
      await store.send(.dismissOwnedFailure(.turnPersistence(question)))
    }
    #expect(store.state.pendingTurnPersistence != nil)
    #expect(recorder.events.filter { $0.code == "failure_presentation_dismissed" }.count == (dismissWarning ? 1 : 0))
    await store.send(.turnPersistenceWriteSettled(question))
    #expect(!store.state.failures.contains { $0.owner == .turnPersistence(question) })
    await clock.advance(by: .seconds(5))
    await store.receive(\.turnPersistenceDrainTimedOut)
    #expect(store.state.visibleFailures.contains { $0.owner == .turnPersistence(question) })
    await store.send(.conversationSelected(b))
    await store.receive(\.conversationLoaded)
    #expect(store.state.visibleFailures.contains { $0.owner == .turnPersistence(question) })
    await store.send(.turnPersistenceFinished(question))
    await store.finish()
    #expect(!store.state.failures.contains { $0.owner == .turnPersistence(question) })
    #expect(store.state.failures.count == 3)
  }

  @Test func refreshPreservesOutstandingOptimisticRowsAndGeneration() async {
    let read = RecoveryHeldRead()
    let rename = RecoveryHeldRead()
    var initial = state(populated: true)
    let stale = Array(initial.conversations)
    initial.conversations[id: a]?.suggestionGeneration = 8
    initial.conversations[id: a]?.messageCount = 5
    initial.activeTurn = .init(questionID: UUID(17502), conversationID: a,
      question: "In progress", startedAt: Date(timeIntervalSince1970: 2))
    var history = HistoryClient.noop()
    history.bootstrap = { await read.hold(); return stale }
    history.renameConversation = { _, _ in await rename.hold() }
    let store = store(initial, history: history)
    await store.send(.chat(.delegate(.renameRequested(a, "Optimistic title"))))
    await rename.wait()
    await store.send(.retryHistoryTapped)
    await read.wait()
    await rename.finish()
    await store.receive(\.summaryWriteSettled)
    await read.finish()
    await store.receive(\.bootstrapFinished)
    await store.finish()
    #expect(store.state.conversations[id: a]?.title == "Optimistic title")
    #expect(store.state.conversations[id: a]?.suggestionGeneration == 8)
    #expect(store.state.conversations[id: a]?.messageCount == 5)
  }

  @Test func retryFailuresFilterGenerationAndRetireOnDismissalAndDeletion() async {
    let journal = UUID(17503)
    var initial = state(populated: true)
    let interruption = InterruptedTurn(question: "Retry", interruptedAt: Date(timeIntervalSince1970: 1),
      journalID: journal, executionID: journal, status: .manualRetryRequired)
    initial.seedRetry(journal, conversationID: a, interruption: interruption)
    initial.chat?.interruptedTurns.append(interruption)
    initial.retryJournals[journal]?.requestGeneration = 2
    initial.storeFailure(failure, owner: .retry(conversationID: a, journalID: journal, generation: 1))
    #expect(initial.visibleFailures.isEmpty)
    initial.storeFailure(failure, owner: .retry(conversationID: a, journalID: journal, generation: 2))
    let store = store(initial, history: .noop())
    await store.send(.chat(.delegate(.dismissInterruptedTurn(conversationID: a, journalID: journal, interruption: interruption))))
    await store.finish()
    #expect(!store.state.failures.contains { if case .retry = $0.owner { true } else { false } })
    await store.send(.conversationSelected(b))
    await store.receive(\.conversationLoaded)
    await store.send(.conversationSelected(a))
    await store.receive(\.conversationLoaded)
    #expect(store.state.visibleFailures.isEmpty)
    await store.send(.deleteConversationTapped(a))
    let deletion = store.state.pendingDeletion!
    await store.send(.deleteCountdownFinished(deletion.token))
    await store.receive(\.conversationDeletionFinished)
    await store.finish()
    #expect(!store.state.failures.contains { $0.owner == .conversation(a) })
  }

  @Test(arguments: 0..<10)
  func exportCompletingInAnotherChatIsRetainedUntilExplicitShare(iteration: Int) async throws {
    let held = RecoveryHeldRead()
    let calls = CallRecorder()
    let initial = state(populated: true)
    let snapshot = ConversationSnapshot(summary: initial.conversations[id: b]!)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("creg-conversation-test-\(UUID()).jsonl")
    try Data("export".utf8).write(to: url)
    var history = HistoryClient.noop()
    history.exportJSONL = { _ in calls.record("export"); await held.hold(); return url }
    let snapshotA = ConversationSnapshot(summary: initial.conversations[id: a]!)
    history.loadConversation = { id in id == b ? snapshot : snapshotA }
    let store = store(initial, history: history)
    await store.send(.chat(.exportTapped))
    await store.receive(\.chat.delegate)
    await held.wait()
    await store.send(.chat(.exportTapped))
    await store.receive(\.chat.delegate)
    await store.send(.conversationSelected(b))
    await store.receive(\.conversationLoaded)
    await held.finish()
    await store.receive(\.conversationExportFinished)
    #expect(store.state.presentation == nil)
    #expect(store.state.conversationExports[a]?.phase == .ready(url))
    #expect(calls.recorded == ["export"])
    await store.send(.conversationSelected(a))
    await store.receive(\.conversationLoaded)
    #expect(store.state.presentation == nil)
    await store.send(.noticesTapped)
    await store.send(.shareConversationExport(a))
    #expect(store.state.presentation == .conversationExport(store.state.conversationExports[a]!))
    await store.send(.sheetDismissed)
    await store.finish()
    #expect(store.state.conversationExports[a] == nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test(arguments: [false, true])
  func exportFinishingDuringDeletionRetainsForUndoOrDiscardsAfterCommit(undo: Bool) async throws {
    let held = RecoveryHeldRead()
    let initial = state(populated: true)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("creg-conversation-test-\(UUID()).jsonl")
    try Data("export".utf8).write(to: url)
    var history = HistoryClient.noop()
    history.exportJSONL = { _ in await held.hold(); return url }
    let snapshotB = ConversationSnapshot(summary: initial.conversations[id: b]!)
    history.loadConversation = { _ in snapshotB }
    let store = store(initial, history: history)
    await store.send(.chat(.delegate(.exportRequested(a))))
    await held.wait()
    await store.send(.deleteConversationTapped(a))
    await store.receive(\.conversationLoaded)
    if undo { await store.send(.undoDeleteTapped) }
    else {
      await store.send(.deleteCountdownFinished(store.state.pendingDeletion!.token))
      await store.receive(\.conversationDeletionFinished)
    }
    await held.finish()
    await store.receive(\.conversationExportFinished)
    await store.finish()
    #expect((store.state.conversationExports[a] != nil) == undo)
    #expect(FileManager.default.fileExists(atPath: url.path) == undo)
    try? FileManager.default.removeItem(at: url)
  }

  @Test func successfulReopenClearsUnavailableCauseButKeepsUnrelatedErrors() async {
    var initial = state(populated: true)
    initial.storeFailure(.history(operation: .supportBundle,
      error: HistoryStoreUnavailableError(diagnostic: "open failed")), owner: .global)
    initial.storeFailure(failure, owner: .conversation(a))
    let store = store(initial, history: .noop())
    await store.send(.retryHistoryTapped)
    await store.receive(\.bootstrapFinished)
    await store.finish()
    #expect(store.state.failures.map(\.failure) == [failure])
  }

  @Test(arguments: ["none", "settings", "notices"])
  func selectedExportAutomaticallyPresentsOnlyWhenNoRootSheetIsOpen(sheet: String) async throws {
    var initial = state(populated: true)
    let request = UUID(17505)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("creg-conversation-test-\(UUID()).jsonl")
    try Data("export".utf8).write(to: url)
    initial.conversationExports[a] = .init(conversationID: a, requestID: request, phase: .exporting)
    if sheet == "settings" { initial.presentation = .settings }
    if sheet == "notices" { initial.presentation = .notices(a) }
    let previous = initial.presentation
    let store = store(initial, history: .noop())
    await store.send(.conversationExportFinished(a, requestID: request, .success(url)))
    let export = store.state.conversationExports[a]!
    #expect(export.phase == .ready(url))
    #expect(store.state.presentation == (sheet == "none" ? .conversationExport(export) : previous))
    await store.send(.shareConversationExport(a))
    await store.send(.sheetDismissed)
    await store.finish()
    #expect(store.state.conversationExports[a] == nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test func deletionKeepsDeferredNewChatIntentAndWaitsForSummaryWrite() async {
    let held = RecoveryHeldRead()
    var initial = state(populated: true)
    initial.newChatRequestedDuringBootstrap = true
    var history = HistoryClient.noop()
    history.renameConversation = { _, _ in await held.hold() }
    let store = store(initial, history: history)
    await store.send(.chat(.delegate(.renameRequested(a, "Rename before deletion"))))
    await held.wait()
    await store.send(.deleteConversationTapped(a))
    #expect(store.state.newChatRequestedDuringBootstrap)
    #expect(store.state.conversationOpening == nil)
    await store.send(.deleteCountdownFinished(store.state.pendingDeletion!.token))
    #expect(store.state.conversationDeletions[a]?.phase == .awaitingSettlement)
    await held.finish()
    await store.receive(\.summaryWriteSettled)
    await store.receive(\.conversationDeletionFinished)
    await store.finish()
    #expect(store.state.conversationDeletions[a]?.phase == .committed)
  }

}
