import ComposableArchitecture
import Foundation
import GRDB
import Testing

@testable import CREGEngine
@testable import CREGFeatures

private actor ReviewHeldOperation {
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
  func finish() {
    release?.resume()
    release = nil
  }
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct ReviewFixRegressionTests {
  private typealias Scheduler = AppFeatureSchedulerTests
  private let a = Scheduler.conversationA
  private let b = Scheduler.conversationB
  private let journal = UUID(12501)
  private let operation = UUID(12503)
  private let writeFailure = FailurePresentation(
    code: "history_message_save_failed", title: "Conversation not saved",
    message: "Changes could not be saved.", diagnostic: "write diagnostic")
  private let deleteFailure = FailurePresentation(
    code: "history_delete_failed", title: "Delete failed",
    message: "The conversation could not be deleted.", diagnostic: "delete diagnostic")

  private func fixture() -> (AppFeature.State, QueuedQuestion, InterruptedTurn, ChatMessage) {
    var state = Scheduler.appState()
    let user = ChatMessage(
      id: UUID(12502), role: .user, body: .text("Retry question"),
      createdAt: Date(timeIntervalSince1970: 1))
    let interruption = InterruptedTurn(
      question: user.previewText, interruptedAt: user.createdAt,
      journalID: journal, executionID: user.id, status: .manualRetryRequired, autoRetryCount: 0)
    state.chat?.messages.append(user)
    state.chat?.interruptedTurns.append(interruption)
    state.seedRetry(journal, conversationID: a, interruption: interruption)
    let queued = QueuedQuestion(
      id: UUID(12504), conversationID: a,
      submission: QuestionSubmission(question: user.previewText), retryJournalID: journal,
      existingUserMessage: user, submittedAt: user.createdAt)
    return (state, queued, interruption, user)
  }

  @Test(arguments: [false, true])
  func finalDismissalWriteCommitsDeletionEvenWhenUnrelatedTurnHoldsGate(busy: Bool) async {
    var (state, _, interruption, _) = fixture()
    state.chat = ChatFeature.State(conversationID: b)
    state.isSceneActive = false
    if busy {
      state.activeTurn = .init(
        questionID: UUID(12505), conversationID: b,
        question: "Unrelated work", startedAt: Date(timeIntervalSince1970: 2))
    }
    state.installDismissal(
      .init(
        conversationID: a, journalID: journal,
        attemptID: operation, interruption: interruption))
    let clock = TestClock()
    let deletes = CallRecorder()
    let diagnostics = DiagnosticEventRecorder()
    var history = HistoryClient.noop()
    history.deleteConversation = { _ in deletes.record("deleted") }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.historyClient = history
      $0.diagnostics = diagnostics.client
    }
    store.exhaustivity = .off
    await store.send(.deleteConversationTapped(a))
    await clock.advance(by: .seconds(5))
    await store.receive(\.deleteCountdownFinished)
    #expect(store.state.conversationDeletions[a]?.phase == .awaitingSettlement)
    #expect(deletes.recorded.isEmpty)
    #expect(store.state.schedulerReconciliation.readyDeletionIDs.isEmpty)
    let settled = AppFeature.Action.interruptedDismissalFinished(
      conversationID: a, journalID: journal, attemptID: operation, failure: nil)
    await store.send(settled)
    await store.receive(\.conversationDeletionFinished)
    await store.send(settled)
    await store.finish()
    #expect(deletes.recorded == ["deleted"])
    #expect(store.state.conversationDeletions[a]?.phase == .committed)
    #expect(store.state.activeTurn == state.activeTurn)
    let events = diagnostics.events.filter { $0.code.hasPrefix("conversation_delete_") }
    #expect(
      events.map(\.code) == [
        "conversation_delete_pending",
        "conversation_delete_waiting_for_persistence", "conversation_delete_commit_started",
        "conversation_delete_committed",
      ])
    #expect(events.allSatisfy { $0.context["operation_number"] != nil && $0.context["conversation_id"] == nil })
    #expect(
      events.first { $0.code == "conversation_delete_commit_started" }?.context["deferred"]
        == "true")
    #expect(Set(events.compactMap { $0.context["operation_number"] }).count == 1)
  }

  @Test(arguments: [false, true])
  func deletionResolutionPreservesDeferredDetailsAndIgnoresDuplicateCompletion(failed: Bool) async {
    var state = Scheduler.appState(selected: b)
    state.isSceneActive = false
    state.installUndoDeletion(summary: state.conversations[id: a]!, deferredFailure: writeFailure)
    state.conversationDeletions[a]?.phase = .committing
    state.undoDeletionID = nil
    let token = state.conversationDeletions[a]!.token
    let diagnostics = DiagnosticEventRecorder()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diagnostics = diagnostics.client
      $0.historyClient = .noop()
    }
    store.exhaustivity = .off
    let completion = AppFeature.Action.conversationDeletionFinished(
      a, token: token,
      failure: failed ? deleteFailure : nil)
    await store.send(completion)
    await store.finish()
    #expect(
      diagnostics.events.filter {
        $0.code == (failed ? "conversation_delete_failed" : "conversation_delete_committed")
      }.count == 1)
    if failed {
      #expect(store.state.isConversationLive(a))
      #expect(store.state.presentedFailure?.code == deleteFailure.code)
      #expect(store.state.presentedFailure?.title == deleteFailure.title)
      #expect(
        store.state.presentedFailure?.message
          == "The conversation could not be deleted.\n\nChanges could not be saved.")
      #expect(
        store.state.presentedFailure?.diagnostic
          == "delete diagnostic\n\n[history_message_save_failed] write diagnostic"
      )
      for failure in [deleteFailure, writeFailure] {
        let events = diagnostics.events.filter { $0.code == failure.code }
        #expect(events.count == 1)
        #expect(events.first?.details == failure.diagnostic)
        #expect(events.first?.level == .error)
      }
    } else {
      #expect(store.state.conversations[id: a] == nil)
      #expect(store.state.presentedFailure == nil)
      #expect(store.state.conversationDeletions[a]?.deferredFailures.isEmpty == true)
      let events = diagnostics.events.filter {
        $0.code == "conversation_write_failed_after_deletion"
      }
      #expect(events.count == 1)
      #expect(events.first?.details == writeFailure.diagnostic)
      #expect(events.first?.context["failure_code"] == writeFailure.code)
      #expect(events.first?.context["operation_number"] != nil)
      #expect(events.first?.level == .error)
    }
    let recorded = diagnostics.events
    await store.send(completion)
    #expect(diagnostics.events == recorded)
  }

  @Test(arguments: ["undo", "failure", "success"])
  func incomingSearchHitsSurviveReversibleDeletion(resolution: String) async {
    var state = Scheduler.appState(selected: b)
    state.isSceneActive = false
    state.installUndoDeletion(summary: state.conversations[id: a]!)
    let token = state.conversationDeletions[a]!.token
    if resolution != "undo" { state.conversationDeletions[a]?.phase = .committing }
    let hit = ConversationSearchHit(
      conversationID: a, title: "Result", snippet: "Matching question",
      lastActivityAt: Date(timeIntervalSince1970: 1))
    let diagnostics = DiagnosticEventRecorder()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.historyClient = .noop()
      $0.diagnostics = diagnostics.client
    }
    store.exhaustivity = .off
    await store.send(.searchResults([hit]))
    #expect(store.state.searchHits == [hit])
    #expect(store.state.visibleSearchHits.isEmpty)
    if resolution == "undo" {
      await store.send(.undoDeleteTapped)
    } else {
      await store.send(
        .conversationDeletionFinished(
          a, token: token,
          failure: resolution == "failure" ? deleteFailure : nil))
    }
    await store.finish()
    #expect(store.state.visibleSearchHits == (resolution == "success" ? [] : [hit]))
    #expect(store.state.searchHits == (resolution == "success" ? [] : [hit]))
    if resolution == "undo" {
      let undone = diagnostics.events.first { $0.code == "conversation_delete_undone" }
      #expect(undone?.context["operation_number"] != nil)
      #expect(undone?.context["deletion_token"] == nil)
    }
  }

  @Test(arguments: [false, true])
  func missingJournalRetiresStaleBannerWithoutRetiringOutstandingWrites(automatic: Bool) async {
    var (state, queued, _, user) = fixture()
    queued.automaticRetry = automatic
    state.queue = [queued]
    if automatic {
      state.installAutomaticCandidate(
        .init(
          journalID: journal, conversationID: a,
          submission: queued.submission, userMessage: user))
      state.presentedFailure = writeFailure
    } else {
      state.promoteRetry(journal)
    }
    state.retryJournals[journal]?.operations[operation] = .inspection(queued, generation: 0)
    let cleanup = UUID(12506)
    state.retryJournals[journal]?.operations[cleanup] = .cleanup
    let diagnostics = DiagnosticEventRecorder()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diagnostics = diagnostics.client
      $0.historyClient = .noop()
    }
    store.exhaustivity = .off
    await store.send(.queuedRetryStaleChecked(queued, .missingJournal, operationID: operation))
    if !automatic { await store.receive(\.operationFailed) }
    await store.finish()
    #expect(store.state.chat?.interruptedTurns.isEmpty == true)
    #expect(store.state.retryJournals[journal]?.interruption == nil)
    #expect(store.state.retryJournals[journal]?.operations == [cleanup: .cleanup])
    #expect(store.state.chat?.queuedRetryJournalIDs.isEmpty == true)
    #expect(store.state.queue.isEmpty)
    #expect(store.state.automaticRetryCandidates.isEmpty)
    #expect(store.state.userPromotedRetryJournalIDs.isEmpty)
    #expect(
      store.state.presentedFailure?.code
        == (automatic ? writeFailure.code : "retry_journal_missing"))
    if !automatic {
      #expect(store.state.presentedFailure?.title == "Retry unavailable")
      #expect(store.state.presentedFailure?.message.contains("Send it as a new question") == true)
    }
    let events = diagnostics.events.filter { $0.code == "retry_journal_missing" }
    #expect(events.count == 1)
    #expect(events.first?.details?.contains(journal.uuidString) == true)
  }

  @Test func inspectionShowsCheckingAndDismissalRejectsLateCompletion() async throws {
    var (state, queued, interruption, _) = fixture()
    state.queue = [queued]
    let read = ReviewHeldOperation()
    let summary = state.conversations[id: a]!
    var history = HistoryClient.noop()
    history.claimTurnRetry = { _, _, _, _ in nil }
    history.loadConversation = { [interruption] _ in
      await read.hold()
      return ConversationSnapshot(summary: summary, interruptedTurns: [interruption])
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.historyClient = history
    }
    store.exhaustivity = .off
    await store.send(.dispatchNextIfIdle)
    await store.receive(\.queuedRetryClaimed)
    await read.wait()
    #expect(store.state.chat?.inspectingRetryJournalIDs.contains(journal) == true)
    #expect(store.state.chat?.queuedRetryJournalIDs.contains(journal) == false)
    let inspectionID = try #require(
      store.state.retryJournals[journal]?.operations.first {
        if case .inspection = $0.value { return true }
        return false
      }?.key)
    await store.send(.chat(.delegate(.cancelQueuedRetry(journal))))
    #expect(store.state.pendingRetryDeclines.isEmpty)
    #expect(store.state.chat?.inspectingRetryJournalIDs.contains(journal) == true)
    await store.send(.chat(.interruptedDismissedFor(journal)))
    await store.receive(\.interruptedDismissalFinished)
    #expect(store.state.chat?.queuedRetryJournalIDs.contains(journal) == false)
    await read.finish()
    await store.send(
      .queuedRetryStaleChecked(
        queued, .nonTrailingInterruption(interruption),
        operationID: inspectionID))
    await store.finish()
    #expect(store.state.activeTurn == nil)
    #expect(store.state.presentedFailure == nil)
    #expect(store.state.chat?.interruptedTurns.isEmpty == true)
  }

  @Test(arguments: ["undo", "failure", "success"])
  func cancellationPromotionSurvivesPendingDeletion(resolution: String) async {
    var (state, queued, _, _) = fixture()
    state.isSceneActive = false
    state.installUndoDeletion(summary: state.conversations[id: a]!)
    let token = state.conversationDeletions[a]!.token
    state.retryJournals[journal]?.intent = .cancelled(manualRequested: true)
    state.retryJournals[journal]?.operations[operation] = .cancellation(queued)
    var history = HistoryClient.noop()
    if resolution == "failure" {
      history.deleteConversation = { _ in throw DiagnosticsTestError.failed("delete") }
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.historyClient = history
    }
    store.exhaustivity = .off
    let settled = AppFeature.Action.retryCancellationSettled(
      queued, operationID: operation, failure: nil)
    await store.send(settled)
    #expect(store.state.queue == [queued])
    #expect(store.state.runnableQueue.isEmpty)
    await store.send(settled)
    #expect(store.state.queue == [queued])
    if resolution == "undo" {
      await store.send(.undoDeleteTapped)
    } else {
      await store.send(.deleteCountdownFinished(token))
      await store.receive(\.conversationDeletionFinished)
    }
    await store.finish()
    #expect(store.state.runnableQueue == (resolution == "success" ? [] : [queued]))
    #expect(store.state.queue == (resolution == "success" ? [] : [queued]))
  }

  @Test(arguments: [false, true])
  func missingMessageClaimReleasesCapturedExecutionInSQLite(automatic: Bool) async throws {
    var (state, queued, _, user) = fixture()
    queued.existingUserMessage = nil
    queued.automaticRetry = automatic
    state.queue = [queued]
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "creg-release-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let live = try HistoryClient.live(
      databaseURL: directory.appendingPathComponent("history.sqlite"))
    _ = try await live.bootstrap()
    _ = try await live.createConversation(a, user.createdAt)
    try await live.persistUserTurn(a, user, queued.submission, user.createdAt, nil)
    try await live.markTurnInterrupted(a, user.id, false)
    let database = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let journalID = journal
    // Exercise the distinction between journal identity and execution identity
    // without changing the production schema or transfer transaction.
    try await database.queue.write { [user] db in
      try db.execute(
        sql: "UPDATE turn_journal SET journal_id = ? WHERE journal_id = ?",
        arguments: [journalID.uuidString, user.id.uuidString])
    }
    let claim = ReviewHeldOperation()
    let released = CallRecorder()
    var history = live
    history.claimTurnRetry = { id, journalID, executionID, automatic in
      let count = try await live.claimTurnRetry(id, journalID, executionID, automatic)
      await claim.hold()
      return count
    }
    history.releaseAutoRetryClaim = { id, journalID, executionID, automatic in
      released.record(executionID.uuidString)
      try await live.releaseAutoRetryClaim(id, journalID, executionID, automatic)
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.historyClient = history
    }
    store.exhaustivity = .off
    await store.send(.dispatchNextIfIdle)
    await claim.wait()
    let runningStatus = try await database.queue.read { db in
      try String.fetchOne(
        db, sql: "SELECT status FROM turn_journal WHERE journal_id = ?",
        arguments: [journalID.uuidString])
    }
    #expect(runningStatus == "running")
    await store.send(.appBecameInactive)
    await claim.finish()
    await store.receive(\.queuedRetryClaimed)
    await store.receive(\.retryClaimReleased)
    await store.finish()
    let snapshot = try await live.loadConversation(a)
    #expect(released.recorded == [user.id.uuidString])
    #expect(user.id != journal)
    #expect(snapshot.interruptedTurns.first?.status == .knownInterruption)
    #expect(snapshot.interruptedTurns.first?.autoRetryCount == 0)
    #expect(store.state.queue.first?.retryExecutionID == user.id)
    #expect(store.state.queue.first?.existingUserMessage == nil)
    #expect(!store.state.retryOperationsHoldScheduler)
  }

  @Test func replacementLoadFailureCanRecoverThroughNewChat() async {
    var state = Scheduler.appState()
    state.isSceneActive = false
    let clock = TestClock()
    let diagnostics = DiagnosticEventRecorder()
    var history = HistoryClient.noop()
    history.loadConversation = { _ in throw DiagnosticsTestError.failed("replacement load") }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 3)
      $0.continuousClock = clock
      $0.historyClient = history
      $0.diagnostics = diagnostics.client
    }
    store.exhaustivity = .off
    await store.send(.deleteConversationTapped(a))
    await store.receive(\.conversationOpeningFailed)
    #expect(store.state.chat == nil)
    #expect(store.state.presentedFailure?.code == "history_load_failed")
    await store.send(.browserButtonTapped)
    #expect(store.state.isBrowserRevealed)
    await store.send(.newChatTapped)
    await store.receive(\.conversationCreated)
    #expect(store.state.chat != nil)
    #expect(store.state.presentedFailure == nil)
    await clock.advance(by: .seconds(5))
    await store.finish()
    #expect(diagnostics.events.filter { $0.code == "history_load_failed" }.count == 1)
  }

  @Test(arguments: ["background_entry", "background_task_expiration", "conversation_deletion"])
  func interruptionDiagnosticsIdentifyTheActualCause(reason: String) async {
    var state = Scheduler.appState()
    let executionID = UUID(12590)
    state.activeTurn = .init(
      questionID: executionID, conversationID: a,
      question: "Active question", startedAt: Date(timeIntervalSince1970: 1))
    let diagnostics = DiagnosticEventRecorder()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.historyClient = .noop()
      $0.diagnostics = diagnostics.client
    }
    store.exhaustivity = .off
    let action: AppFeature.Action =
      switch reason {
      case "background_entry": .appEnteredBackground
      case "background_task_expiration": .backgroundTurnExpired(executionID: executionID)
      default: .deleteConversationTapped(a)
      }
    await store.send(action)
    let event = diagnostics.events.first { $0.code == "chat_turn_interrupted" }
    #expect(event?.context["reason"] == reason)
    #expect(event?.context["operation_number"] != nil)
    #expect(event?.context["execution_id"] == nil)
    #expect(event?.summary.contains("scene interruption") == false)
    #expect(store.state.pendingInterruptedTurn?.questionID == executionID)
    await store.skipInFlightEffects(strict: false)
  }
}
