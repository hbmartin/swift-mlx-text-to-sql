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
    } else {
      await store.receive(\.conversationExportFinished)
      await store.receive(\.operationFailed)
    }
    await store.finish()
    #expect(store.state.presentedFailure == failure)
    let owned = store.state.failures.first { $0.owner == .conversationOperation(a, write ? .rename : .export) }
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
    await store.send(.conversationOpeningFailed(creationRequest, .history(operation: .conversationCreate, error: DiagnosticsTestError.failed("create"))))
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
    var initial = state()
    initial.isSceneActive = true
    let store = store(initial, history: history, clock: clock)
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
    let owners: [AppFeature.FailureOwner] = [.conversation(a), .conversationOperation(a, .rename), .conversationOperation(a, .export)]
    for owner in owners {
      await store.send(.operationFailed(failure, owner: owner))
      #expect(store.state.failures.contains { $0.owner == owner })
    }
    await store.send(.deleteConversationTapped(a))
    let deletion = store.state.pendingDeletion!
    await store.send(.deleteCountdownFinished(deletion.token))
    await store.receive(\.conversationDeletionFinished)
    await store.finish()
    #expect(!store.state.failures.contains { owners.contains($0.owner) })
  }

  @Test(arguments: 0..<10)
  func exportCompletingInAnotherChatIsRetainedUntilExplicitShare(iteration: Int) async throws {
    let held = RecoveryHeldRead()
    let calls = CallRecorder()
    var initial = state(populated: true)
    initial.isSceneActive = true
    let snapshot = ConversationSnapshot(summary: initial.conversations[id: b]!)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("creg-conversation-test-\(UUID()).jsonl")
    try Data("export".utf8).write(to: url)
    var history = HistoryClient.noop()
    history.exportJSONL = { _ in calls.record("export"); if calls.recorded.count == 1 { await held.hold() }; try Data("export".utf8).write(to: url); return url }
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
    #expect(store.state.conversationExports[a]?.phase == .exporting)
    await held.finish()
    await store.receive(\.conversationExportFinished)
    #expect(calls.recorded == ["export", "export"])
    #expect(store.state.presentation == .conversationExport(store.state.conversationExports[a]!))
    await store.send(.sheetDismissed(.export(store.state.conversationExports[a]!.requestID)))
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

  @Test(arguments: ["none", "settings", "notices", "result", "rename"])
  func selectedExportAutomaticallyPresentsOnlyWhenNoRootSheetIsOpen(sheet: String) async throws {
    var initial = state(populated: true)
    initial.isSceneActive = true
    let request = UUID(17505)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("creg-conversation-test-\(UUID()).jsonl")
    try Data("export".utf8).write(to: url)
    initial.conversationExports[a] = .init(conversationID: a, requestID: request, phase: .exporting)
    if sheet == "settings" { initial.presentation = .settings }
    if sheet == "notices" { initial.presentation = .notices(a) }
    if sheet == "result" { initial.chat?.resultViewerMessageID = UUID(17506) }
    if sheet == "rename" { initial.chat?.isRenamePresented = true }
    let previous = initial.presentation
    let store = store(initial, history: .noop())
    await store.send(.conversationExportFinished(a, requestID: request, .success(url)))
    let export = store.state.conversationExports[a]!
    #expect(export.phase == .ready(url))
    #expect(store.state.presentation == (sheet == "none" ? .conversationExport(export) : previous))
    if sheet == "none" {
      await store.send(.sheetDismissed(.export(request)))
      await store.finish()
      #expect(store.state.conversationExports[a] == nil)
      #expect(!FileManager.default.fileExists(atPath: url.path))
    } else {
      if let presentation = store.state.presentation {
        await store.send(.sheetDismissed(presentation.id))
      } else if sheet == "result" {
        await store.send(.chat(.resultViewerDismissed))
      } else if sheet == "rename" {
        await store.send(.chat(.binding(.set(\.isRenamePresented, false))))
      }
      await store.finish()
      #expect(store.state.conversationExports[a]?.phase == .ready(url))
      try? FileManager.default.removeItem(at: url)
    }
  }

  @Test func answerSharingRetainsPendingExportAndIgnoresAnotherConversation() async throws {
    var initial = state(populated: true)
    initial.isSceneActive = true
    let requestID = UUID(17507)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("creg-conversation-test-\(UUID()).jsonl")
    try Data("export".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    initial.conversationExports[a] = .init(
      conversationID: a, requestID: requestID, phase: .exporting)
    let store = store(initial, history: .noop())
    await store.send(.conversationModalRequested(b))
    #expect(store.state.conversationExports[a]?.intent == .export)
    await store.send(.conversationModalRequested(a))
    #expect(store.state.conversationExports[a]?.intent == .retained)
    await store.send(.conversationExportFinished(a, requestID: requestID, .success(url)))
    #expect(store.state.presentation == nil)
    #expect(store.state.conversationExports[a]?.phase == .ready(url))
    await store.finish()
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

extension HistoryRecoveryRegressionTests {
  @Test func slowReadContinuesAndFulfillsAcceptedNewChat() async {
    let held = RecoveryHeldRead()
    let clock = TestClock()
    var initial = state()
    initial.isSceneActive = true
    var history = HistoryClient.noop()
    history.bootstrap = { await held.hold(); return [] }
    let recorder = DiagnosticEventRecorder()
    let store = store(initial, history: history, clock: clock, recorder: recorder)
    await store.send(.onAppear)
    await held.wait()
    let request = store.state.historyRequestSequence
    await store.send(.newChatTapped)
    await clock.advance(by: .seconds(5))
    await store.receive(\.historySummaryTimedOut)
    #expect(store.state.historySummaryPhase == .loading(request))
    #expect(store.state.newChatRequestedDuringBootstrap)
    await store.send(.historySummaryTimedOut(request, generation: store.state.historyWatchdogGeneration))
    #expect(recorder.events.filter { $0.code == "history_summary_timed_out" }.count == 1)
    await held.finish()
    await store.receive(\.bootstrapFinished)
    await store.receive(\.conversationCreated)
    await store.finish()
    #expect(store.state.chat != nil)
    #expect(store.state.failures.isEmpty)
    #expect(store.state.slowHistoryRequestID == nil)
  }

  @Test func inactiveWarningIsCancelledAndResumeOwnsFreshInterval() async {
    let held = RecoveryHeldRead()
    let clock = TestClock()
    var initial = state()
    initial.isSceneActive = true
    var history = HistoryClient.noop()
    history.bootstrap = { await held.hold(); return [] }
    let store = store(initial, history: history, clock: clock)
    await store.send(.onAppear)
    await held.wait()
    let request = store.state.historyRequestSequence
    let oldGeneration = store.state.historyWatchdogGeneration
    await clock.advance(by: .seconds(3))
    await store.send(.appBecameInactive)
    await clock.advance(by: .seconds(10))
    await store.send(.historySummaryTimedOut(request, generation: oldGeneration))
    #expect(store.state.slowHistoryRequestID == nil)
    await store.send(.appBecameActive)
    await store.send(.historySummaryTimedOut(request, generation: oldGeneration))
    await clock.advance(by: .seconds(4))
    #expect(store.state.slowHistoryRequestID == nil)
    await clock.advance(by: .seconds(1))
    await store.receive(\.historySummaryTimedOut)
    #expect(store.state.slowHistoryRequestID == request)
    await held.finish()
    await store.receive(\.bootstrapFinished)
    await store.receive(\.conversationCreated)
    await store.finish()
  }

  @Test func reopenedStoreClearsUnavailableEvenWhenSummariesFail() async {
    var initial = state(populated: true)
    initial.historyStoreAvailability = .unavailable
    initial.storeFailure(.history(operation: .supportBundle,
      error: HistoryStoreUnavailableError(diagnostic: "open failed")), owner: .global)
    initial.storeFailure(failure, owner: .conversationOperation(a, .rename))
    var history = HistoryClient.noop()
    history.bootstrap = { throw DiagnosticsTestError.failed("summary read") }
    let store = store(initial, history: history)
    await store.send(.retryHistoryTapped)
    await store.receive(\.historyBootstrapFailed)
    await store.finish()
    #expect(store.state.historyStoreAvailability == .available)
    #expect(!store.state.failures.contains { $0.failure.cause == .historyStoreUnavailable })
    #expect(store.state.failures.contains { $0.owner == .conversationOperation(a, .rename) })
  }

  @Test func deletingSelectedChatReplacesFailedOpening() async {
    var initial = state(populated: true)
    initial.conversationOpening = .init(requestID: 42, kind: .load(b), phase: .failed)
    initial.storeFailure(failure, owner: .conversationOpening(42))
    let snapshot = ConversationSnapshot(summary: initial.conversations[id: b]!)
    var history = HistoryClient.noop()
    history.loadConversation = { _ in snapshot }
    let store = store(initial, history: history)
    await store.send(.deleteConversationTapped(a))
    #expect(store.state.conversationOpening?.phase == .loading)
    await store.receive(\.conversationLoaded)
    await store.send(.undoDeleteTapped)
    await store.finish()
    #expect(store.state.chat?.conversationID == b)
    #expect(!store.state.failures.contains { if case .conversationOpening = $0.owner { true } else { false } })
  }

  @Test(arguments: [false, true])
  func unreadFailureRollsBackOnlyLatestMutation(newer: Bool) async {
    let operation = UUID(18001)
    var initial = state(populated: true)
    initial.conversations[id: a]?.isUnread = false
    initial.summaryWrites[operation] = .init(conversationID: a, kind: .unread(previous: true))
    initial.unreadMutationOwners[a] = newer ? UUID(18002) : operation
    initial.storeFailure(failure, owner: .conversationOperation(a, .rename))
    initial.storeFailure(failure, owner: .conversationOperation(a, .export))
    let recorder = DiagnosticEventRecorder()
    let store = store(initial, history: .noop(), recorder: recorder)
    await store.send(.summaryWriteSettled(operation, .history(operation: .messageSave, error: DiagnosticsTestError.failed("unread"))))
    await store.finish()
    #expect(store.state.conversations[id: a]?.isUnread == !newer)
    #expect(store.state.visibleFailures.count == 2)
    #expect(recorder.events.map(\.code) == ["history_unread_update_failed"])
  }

  @Test func supportRequestSurvivesUnrelatedFailureAndIgnoresStaleSettlement() async {
    let held = RecoveryHeldRead()
    let calls = CallRecorder()
    let initial = state(populated: true)
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.historyClient = .noop()
      $0.supportBundle = .init { _ in calls.record("build"); await held.hold(); throw DiagnosticsTestError.failed("support") }
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.supportBundleExportTapped)
    await held.wait()
    let request = store.state.supportBuildRequestID
    await store.send(.operationFailed(failure))
    await store.send(.supportBundleExportTapped)
    #expect(store.state.supportBuildRequestID == request)
    #expect(calls.recorded == ["build"])
    await store.send(.supportBundleFailed(failure, requestID: UUID(18003)))
    #expect(store.state.isBuildingSupportBundle)
    await held.finish()
    await store.receive(\.supportBundleFailed)
    await store.finish()
    #expect(!store.state.isBuildingSupportBundle)
  }

  @Test(arguments: ["inactive", "opening", "dismissed"])
  func exportCompletionRetainsWhenPresentationIntentCannotBeHonored(reason: String) async throws {
    var initial = state(populated: true)
    initial.isSceneActive = reason != "inactive"
    let request = UUID(18004)
    initial.conversationExports[a] = .init(conversationID: a, requestID: request, phase: .exporting, intent: .share)
    if reason == "opening" { initial.conversationOpening = .init(requestID: 1, kind: .load(b)) }
    if reason == "dismissed" { initial.presentation = .notices(a) }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("creg-conversation-\(UUID()).jsonl")
    try Data("{}\n".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let store = store(initial, history: .noop())
    if reason == "dismissed" { await store.send(.sheetDismissed(.notices(a))) }
    await store.send(.conversationExportFinished(a, requestID: request, .success(url)))
    await store.finish()
    #expect(store.state.presentation == nil)
    #expect(store.state.conversationExports[a]?.intent == .retained)
  }

  @Test func obsoleteExportDismissalCannotConsumeNewResult() async throws {
    var initial = state(populated: true)
    let old = UUID(18005), new = UUID(18006)
    let directory = FileManager.default.temporaryDirectory
    let oldURL = directory.appendingPathComponent("creg-conversation-\(old).jsonl")
    let newURL = directory.appendingPathComponent("creg-conversation-\(new).jsonl")
    try Data().write(to: oldURL); try Data().write(to: newURL)
    defer { try? FileManager.default.removeItem(at: newURL) }
    let export = AppFeature.ConversationExport(conversationID: a, requestID: new, phase: .ready(newURL))
    initial.conversationExports[a] = export
    initial.presentation = .conversationExport(export)
    initial.presentedExportFiles = [old: oldURL, new: newURL]
    let store = store(initial, history: .noop())
    await store.send(.sheetDismissed(.export(old)))
    await store.finish()
    #expect(store.state.presentation == .conversationExport(export))
    #expect(store.state.conversationExports[a] == export)
    #expect(!FileManager.default.fileExists(atPath: oldURL.path))
    #expect(FileManager.default.fileExists(atPath: newURL.path))
  }

  @Test func agedExportCleanupExcludesProtectedRecentAndSymlinkFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("creg-export-cleanup-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let old = directory.appendingPathComponent("creg-conversation-old.jsonl")
    let protected = directory.appendingPathComponent("creg-conversation-protected.jsonl")
    let recent = directory.appendingPathComponent("creg-conversation-recent.jsonl")
    let target = directory.appendingPathComponent("unrelated.jsonl")
    let link = directory.appendingPathComponent("creg-conversation-link.jsonl")
    for url in [old, protected, recent, target] { try Data().write(to: url) }
    for url in [old, protected] { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: url.path) }
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    ConversationExportFiles.removeOlderThan(Date(timeIntervalSince1970: 100), protected: [protected], directory: directory)
    #expect(!FileManager.default.fileExists(atPath: old.path))
    for url in [protected, recent, target, link] { #expect(FileManager.default.fileExists(atPath: url.path)) }
  }
}

extension HistoryRecoveryRegressionTests {
  @Test(arguments: [false, true])
  func newExportAndShareRegenerateRetainedSnapshot(share: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("creg-fresh-export-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let live = try HistoryClient.live(databaseURL: directory.appendingPathComponent("history.sqlite"))
    var initial = state(populated: true)
    initial.isSceneActive = true
    for id in [a, b] { _ = try await live.createConversation(id, Date()) }
    let message = ChatMessage(id: UUID(), role: .user, body: .text("first"), createdAt: Date())
    try await live.appendMessage(a, message)
    try await live.appendEvents(a, message.id, ["{\"turn\":1}"])
    let held = RecoveryHeldRead()
    let calls = CallRecorder()
    var history = live
    history.exportJSONL = { id in
      let url = try await live.exportJSONL(id)
      calls.record("read")
      if calls.recorded.count == 1 { await held.hold() }
      return url
    }
    let store = store(initial, history: history)
    await store.send(.chat(.delegate(.exportRequested(a))))
    await held.wait()
    await store.send(.conversationSelected(b))
    await store.receive(\.conversationLoaded)
    for turn in [2, 3] {
      let next = ChatMessage(id: UUID(), role: .user, body: .text("turn \(turn)"),
        createdAt: message.createdAt.addingTimeInterval(Double(turn)))
      try await live.appendMessage(a, next)
      try await live.appendEvents(a, next.id, ["{\"turn\":\(turn)}"])
    }
    await held.finish()
    await store.receive(\.conversationExportFinished)
    let old = try #require(store.state.conversationExports[a])
    guard case .ready(let oldURL) = old.phase else { Issue.record("Expected retained export"); return }
    #expect(try String(contentsOf: oldURL, encoding: .utf8).split(separator: "\n").count == 1)
    await store.send(.conversationSelected(a))
    await store.receive(\.conversationLoaded)
    #expect(store.state.chat?.messages.count == 3)
    #expect(store.state.presentation == nil)
    if share {
      await store.send(.noticesTapped)
      await store.send(.shareConversationExport(a))
    } else { await store.send(.chat(.delegate(.exportRequested(a)))) }
    await store.receive(\.conversationExportFinished)
    let fresh = try #require(store.state.conversationExports[a])
    guard case .ready(let url) = fresh.phase else { Issue.record("Expected regenerated export"); return }
    #expect(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count == 3)
    #expect(fresh.requestID != old.requestID)
    #expect(store.state.presentation == .conversationExport(fresh))
    await store.send(.sheetDismissed(.export(fresh.requestID)))
    await store.finish()
    #expect(!FileManager.default.fileExists(atPath: oldURL.path))
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test(arguments: ["undo", "failed", "committed"])
  func exportFailureDuringDeletionUsesUndoRecovery(outcome: String) async {
    let held = RecoveryHeldRead()
    let recorder = DiagnosticEventRecorder()
    var history = HistoryClient.noop()
    history.exportJSONL = { _ in await held.hold(); throw DiagnosticsTestError.failed("export") }
    if outcome == "failed" { history.deleteConversation = { _ in throw DiagnosticsTestError.failed("delete") } }
    let store = store(state(populated: true), history: history, recorder: recorder)
    await store.send(.chat(.delegate(.exportRequested(a))))
    await held.wait()
    await store.send(.deleteConversationTapped(a))
    await store.receive(\.conversationLoaded)
    await held.finish()
    await store.receive(\.conversationExportFinished)
    #expect(store.state.presentedFailure == nil)
    #expect(store.state.conversationDeletions[a]?.deferredOperationFailures.map(\.owner) == [.conversationOperation(a, .export)])
    if outcome == "undo" { await store.send(.undoDeleteTapped) }
    else {
      await store.send(.deleteCountdownFinished(store.state.pendingDeletion!.token))
      await store.receive(\.conversationDeletionFinished)
    }
    await store.finish()
    if outcome == "committed" {
      #expect(store.state.presentedFailure == nil)
      #expect(recorder.events.contains { $0.code == "conversation_write_failed_after_deletion" })
    } else {
      #expect(store.state.failures.contains { $0.owner == .conversationOperation(a, .export) && $0.failure.code == "history_export_failed" })
      #expect(!store.state.visibleFailures.contains { $0.owner == .conversationOperation(a, .export) },
        "Undo recovery preserves the originating conversation's owner while B remains selected")
    }
  }
}

extension HistoryRecoveryRegressionTests {
  @Test func explicitExportCanReactivatePresentationOfAnOngoingRetainedRequest() async throws {
    let held = RecoveryHeldRead()
    let calls = CallRecorder()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("creg-conversation-\(UUID()).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    var history = HistoryClient.noop()
    history.exportJSONL = { _ in calls.record("export"); await held.hold(); return url }
    var initial = state(populated: true)
    initial.isSceneActive = true
    let store = store(initial, history: history)
    await store.send(.chat(.delegate(.exportRequested(a))))
    await held.wait()
    let request = try #require(store.state.conversationExports[a]?.requestID)
    await store.send(.conversationSelected(b))
    await store.receive(\.conversationLoaded)
    await store.send(.conversationSelected(a))
    await store.receive(\.conversationLoaded)
    #expect(store.state.conversationExports[a]?.intent == .retained)
    await store.send(.chat(.delegate(.exportRequested(a))))
    #expect(store.state.conversationExports[a]?.intent == .export)
    #expect(store.state.conversationExports[a]?.requestID == request)
    #expect(calls.recorded.count == 1)
    await held.finish()
    await store.receive(\.conversationExportFinished)
    #expect(store.state.presentation?.id == .export(request))
    await store.send(.sheetDismissed(.export(request)))
    await store.finish()
  }

  @Test func exportFailureArrivingAfterCommittedDeletionIsLogged() async {
    let held = RecoveryHeldRead()
    let clock = TestClock()
    let recorder = DiagnosticEventRecorder()
    var history = HistoryClient.noop()
    history.exportJSONL = { _ in await held.hold(); throw DiagnosticsTestError.failed("export") }
    let store = store(state(populated: true), history: history, clock: clock, recorder: recorder)
    await store.send(.chat(.delegate(.exportRequested(a))))
    await held.wait()
    await store.send(.deleteConversationTapped(a))
    await store.receive(\.conversationLoaded)
    await clock.advance(by: .seconds(5))
    await store.receive(\.deleteCountdownFinished)
    await store.receive(\.conversationDeletionFinished)
    #expect(store.state.conversationExports[a] == nil)
    await held.finish()
    await store.receive(\.conversationExportFinished)
    #expect(store.state.failures.isEmpty)
    #expect(recorder.events.filter { $0.code == "conversation_write_failed_after_deletion" }.count == 1)
    await store.finish()
  }

  @Test func undoPreservesDistinctRenameAndExportOwnersAndUnrelatedFailure() async {
    let operation = UUID(19001)
    let request = UUID(19002)
    var initial = state(populated: true)
    initial.conversationDeletions[a] = .init(token: UUID(19003), summary: initial.conversations[id: a]!)
    initial.undoDeletionID = a
    initial.summaryWrites[operation] = .init(conversationID: a, kind: .rename)
    initial.conversationExports[a] = .init(conversationID: a, requestID: request, phase: .exporting)
    let unrelated = FailurePresentation(code: "unrelated", title: "Unrelated", message: "Preserve this", diagnostic: "Test")
    initial.storeFailure(unrelated, owner: .global)
    let store = store(initial, history: .noop())
    await store.send(.summaryWriteSettled(operation, failure))
    await store.send(.conversationExportFinished(a, requestID: request, .failure(failure)))
    #expect(store.state.conversationDeletions[a]?.deferredOperationFailures.count == 2)
    await store.send(.undoDeleteTapped)
    #expect(store.state.failures.map(\.owner) == [.global, .conversationOperation(a, .rename), .conversationOperation(a, .export)])
    #expect(store.state.failures.first?.failure == unrelated)
    await store.finish()
  }

  @Test func supportCompletionAndDismissalOwnOnlyMatchingArtifacts() async throws {
    func artifact() throws -> AppFeature.SupportBundleExport {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("creg-support-bundle-\(UUID())")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent("creg-support-bundle.zip")
      try Data("ZIP fixture".utf8).write(to: url)
      return .init(url: url, manifest: .init(createdAt: Date(), appVersion: "test", buildNumber: "1",
        modelKey: "test", modelRevision: "test", conversationCount: 0, messageCount: 0, eventLineCount: 0, feedbackCount: 0))
    }
    let request = UUID(19004), staleRequest = UUID(19005)
    let stale = try artifact(), current = try artifact()
    defer {
      try? FileManager.default.removeItem(at: stale.url.deletingLastPathComponent())
      try? FileManager.default.removeItem(at: current.url.deletingLastPathComponent())
    }
    var initial = state(populated: true)
    initial.supportBuildRequestID = request
    let store = store(initial, history: .noop())
    await store.send(.supportBundleReady(stale, requestID: staleRequest))
    await store.finish()
    #expect(store.state.supportBuildRequestID == request)
    #expect(!FileManager.default.fileExists(atPath: stale.url.deletingLastPathComponent().path))
    await store.send(.supportBundleReady(current, requestID: request))
    await store.send(.supportBundleReady(current, requestID: request))
    await store.send(.supportBundleDismissed(staleRequest))
    #expect(store.state.supportBundleExport?.requestID == request)
    #expect(FileManager.default.fileExists(atPath: current.url.path))
    await store.send(.supportBundleDismissed(request))
    await store.finish()
    #expect(store.state.supportBundleExport == nil)
    #expect(!FileManager.default.fileExists(atPath: current.url.deletingLastPathComponent().path))
  }
}
