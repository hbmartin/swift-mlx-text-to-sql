import ComposableArchitecture
import Foundation
import SwiftUI
import Testing

@testable import CREGEngine
@testable import CREGFeatures

private actor RegressionWriteGate {
  var started = false
  var released = false
  var continuation: CheckedContinuation<Void, Never>?
  var snapshot: ConversationSnapshot
  init(_ snapshot: ConversationSnapshot) { self.snapshot = snapshot }
  func hold() async {
    started = true
    if !released {
      let backstop = Task {
        try? await Task.sleep(for: .seconds(10))
        if !Task.isCancelled { finish() }
      }
      await withCheckedContinuation { continuation = $0 }
      backstop.cancel()
    }
  }
  func wait() async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !started {
      guard ContinuousClock.now < deadline else { throw DiagnosticsTestError.failed("Write did not start") }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
  func reset() { started = false; released = false }
  func finish() { released = true; continuation?.resume(); continuation = nil }
  func saveDraft(_ draft: String) { snapshot.draft = draft }
  func savePreference(_ message: ChatMessage) {
    snapshot.messages[snapshot.messages.firstIndex(where: { $0.id == message.id })!] = message
  }
  func load() -> ConversationSnapshot { snapshot }
  var fails = false
  var attempts = 0
  func setFailure(_ value: Bool) { fails = value }
  func attempt() throws {
    attempts += 1
    if fails { throw DiagnosticsTestError.failed("held save") }
  }
  func attemptCount() -> Int { attempts }
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct PR158RegressionFixTests {
  private let a = AppFeatureSchedulerTests.conversationA
  private let b = AppFeatureSchedulerTests.conversationB

  private func initialState() -> AppFeature.State {
    var state = AppFeatureSchedulerTests.appState()
    var chat = PreviewFixtures.answeredChatState()
    chat.conversationID = a
    state.chat = chat
    state.isSceneActive = false
    state.launchBenchmarkQuestion = nil
    state.didRequestPreparationJournalInspection = true
    state.didHandlePreparationJournalInspection = true
    return state
  }

  private func store(_ state: AppFeature.State, history: HistoryClient = .noop(),
    clock: TestClock<Duration> = TestClock(), recorder: DiagnosticEventRecorder = .init()
  ) -> TestStoreOf<AppFeature> {
    let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
      $0.historyClient = history
      $0.continuousClock = clock
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.diagnostics = recorder.client
      $0.queryPipeline = AppFeatureSchedulerTests.hangingPipeline()
    }
    store.exhaustivity = .off
    return store
  }

  @Test(arguments: ["draft", "preference"],
    ["navigation", "undo", "delete_failed", "committed"].flatMap { outcome in
      [false, true].map { (outcome, $0) }
    })
  func acceptedWritesSurviveChildRemoval(write: String, scenario: (String, Bool)) async throws {
    let (outcome, fails) = scenario
    let initial = initialState()
    let answer = initial.chat!.messages.last!
    let gate = RegressionWriteGate(.init(summary: initial.conversations[id: a]!,
      draft: "stored draft", messages: Array(initial.chat!.messages)))
    let other = initial.conversations[id: b]!
    let source = a
    var history = HistoryClient.noop()
    history.loadConversation = { id in
      if id == source { return await gate.load() }
      return ConversationSnapshot(summary: other)
    }
    history.saveDraft = { _, draft in
      await gate.hold()
      if fails { throw DiagnosticsTestError.failed("draft") }
      await gate.saveDraft(draft)
    }
    history.updateResultPresentation = { _, message in
      await gate.hold()
      if fails { throw DiagnosticsTestError.failed("preference") }
      await gate.savePreference(message)
    }
    history.deleteConversation = { _ in
      if outcome == "delete_failed" { throw DiagnosticsTestError.failed("delete") }
    }
    let clock = TestClock()
    let recorder = DiagnosticEventRecorder()
    let store = store(initial, history: history, clock: clock, recorder: recorder)
    if write == "draft" {
      await store.send(.chat(.binding(.set(\.composerText, "new draft"))))
      await clock.advance(by: .milliseconds(500))
      await store.receive(\.draftSaveDue)
    } else {
      await store.send(.chat(.resultPresentationChanged(messageID: answer.id, preference: .table)))
    }
    try await gate.wait()
    if outcome == "navigation" {
      await store.send(.conversationSelected(b))
    } else {
      await store.send(.deleteConversationTapped(a))
    }
    await store.receive(\.conversationLoaded)
    if outcome == "undo" { await store.send(.undoDeleteTapped) }
    if outcome == "delete_failed" || outcome == "committed" {
      await clock.advance(by: .seconds(5))
      await store.receive(\.deleteCountdownFinished)
    }
    await gate.finish()
    if outcome == "delete_failed" || outcome == "committed" {
      await store.receive(\.conversationDeletionFinished)
    }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    let owner: AppFeature.FailureOwner = .conversationOperation(a, write == "draft" ? .draft : .resultPresentation)
    if outcome == "committed" {
      #expect(store.state.conversationEdits[a] == nil)
      #expect(!store.state.failures.contains { $0.owner == owner })
      #expect(recorder.events.filter { $0.code == "conversation_write_failed_after_deletion" }.count == (fails ? 1 : 0))
    } else {
      #expect(store.state.failures.contains { $0.owner == owner } == fails)
      await store.send(.conversationSelected(a))
      await store.receive(\.conversationLoaded)
      await store.finish()
      if write == "draft" {
        #expect(store.state.chat?.composerText == "new draft")
      } else {
        #expect(store.state.chat?.messages[id: answer.id]?.resultPresentation == .table)
      }
    }
  }

  @Test func draftDebounceIsRootOwnedAndKeepsOnlyNewestEdit() async {
    let drafts = CallRecorder()
    var history = HistoryClient.noop()
    history.saveDraft = { _, draft in drafts.record(draft) }
    let clock = TestClock()
    let store = store(initialState(), history: history, clock: clock)
    await store.send(.chat(.binding(.set(\.composerText, "old"))))
    await clock.advance(by: .milliseconds(250))
    await store.send(.chat(.binding(.set(\.composerText, "new"))))
    await clock.advance(by: .milliseconds(499))
    #expect(drafts.recorded.isEmpty)
    await clock.advance(by: .milliseconds(1))
    await store.receive(\.draftSaveDue)
    await store.finish()
    #expect(drafts.recorded == ["new"])
  }

  @Test func submissionClearWinsOverAnAlreadyStartedDraftSave() async throws {
    let initial = initialState()
    let gate = RegressionWriteGate(.init(summary: initial.conversations[id: a]!))
    let drafts = CallRecorder()
    var history = HistoryClient.noop()
    history.saveDraft = { _, draft in
      if !draft.isEmpty { await gate.hold() }
      await gate.saveDraft(draft)
      drafts.record(draft)
    }
    let clock = TestClock()
    let store = store(initial, history: history, clock: clock)
    await store.send(.chat(.binding(.set(\.composerText, "submitted question"))))
    await clock.advance(by: .milliseconds(500))
    await store.receive(\.draftSaveDue)
    try await gate.wait()
    let delayedRevision = store.state.conversationEdits[a]![.draft]!.revision
    await store.send(.chat(.sendTapped))
    await store.receive(\.chat.delegate)
    #expect(store.state.chat?.composerText == "")
    await store.send(.draftSaveDue(conversationID: a, revision: delayedRevision))
    await gate.finish()
    await store.send(.chat(.stopTapped))
    await store.finish()
    #expect(drafts.recorded == ["submitted question", ""])
    #expect(await gate.load().draft == "")
  }

  @Test func pendingDraftTimerSurvivesNavigationAndKeepsItsOrigin() async {
    let calls = CallRecorder()
    var initial = initialState()
    initial.chat?.composerText = ""
    let other = initial.conversations[id: b]!
    var history = HistoryClient.noop()
    history.saveDraft = { id, draft in calls.record("\(id):\(draft)") }
    history.loadConversation = { _ in ConversationSnapshot(summary: other) }
    let clock = TestClock()
    let store = store(initial, history: history, clock: clock)
    await store.send(.chat(.binding(.set(\.composerText, "origin draft"))))
    await store.send(.conversationSelected(b))
    await store.receive(\.conversationLoaded)
    await clock.advance(by: .milliseconds(500))
    await store.receive(\.draftSaveDue)
    await store.finish()
    #expect(calls.recorded == ["\(a):origin draft"])
    #expect(store.state.chat?.composerText == "")
  }

  @Test(arguments: ["draft", "preference"])
  func navigationDuringHeldWritePersistsToTheRealDatabase(write: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let live = try HistoryClient.live(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let summary = try await live.createConversation(a, Date(timeIntervalSince1970: 0))
    let other = try await live.createConversation(b, Date(timeIntervalSince1970: 1))
    var initial = initialState()
    initial.conversations = [summary, other]
    let answer = initial.chat!.messages.last!
    try await live.appendMessage(a, answer)
    let gate = RegressionWriteGate(.init(summary: summary))
    var history = live
    history.saveDraft = { id, draft in await gate.hold(); try await live.saveDraft(id, draft) }
    history.updateResultPresentation = { id, message in
      await gate.hold(); try await live.updateResultPresentation(id, message)
    }
    let clock = TestClock()
    let store = store(initial, history: history, clock: clock)
    if write == "draft" {
      await store.send(.chat(.binding(.set(\.composerText, "durable draft"))))
      await clock.advance(by: .milliseconds(500))
      await store.receive(\.draftSaveDue)
    } else {
      await store.send(.chat(.resultPresentationChanged(messageID: answer.id, preference: .table)))
    }
    try await gate.wait()
    await store.send(.conversationSelected(b))
    await store.receive(\.conversationLoaded)
    await gate.finish()
    await store.finish()
    let persisted = try await live.loadConversation(a)
    if write == "draft" { #expect(persisted.draft == "durable draft") }
    else { #expect(persisted.messages.first?.resultPresentation == .table) }
    #expect(try await live.loadConversation(b).draft == "")
  }

  @Test func rapidReturnReconcilesDraftBeforeDebounceAndNextEdit() async {
    let initial = initialState()
    let source = a
    let other = initial.conversations[id: b]!
    let gate = RegressionWriteGate(.init(summary: initial.conversations[id: a]!, draft: "old"))
    var history = HistoryClient.noop()
    history.loadConversation = { id in
      id == source ? await gate.load() : .init(summary: other)
    }
    history.saveDraft = { _, draft in await gate.saveDraft(draft) }
    let clock = TestClock()
    let store = store(initial, history: history, clock: clock)
    await store.send(.chat(.binding(.set(\.composerText, "latest"))))
    await store.send(.conversationSelected(b))
    await store.receive(\.conversationLoaded)
    await store.send(.conversationSelected(a))
    await store.receive(\.conversationLoaded)
    #expect(store.state.chat?.composerText == "latest")
    await store.send(.chat(.binding(.set(\.composerText, "latest!"))))
    await clock.advance(by: .milliseconds(500))
    await store.receive(\.draftSaveDue)
    await store.receive(\.conversationWriteSettled)
    await store.finish()
    #expect(await gate.load().draft == "latest!")
    #expect(store.state.chat?.composerText == "latest!")
  }

  @Test(arguments: ["draft", "preference"])
  func rapidReturnWhileSavingShowsLatestEdit(write: String) async throws {
    let initial = initialState(), source = a
    let answer = initial.chat!.messages.last!
    let gate = RegressionWriteGate(.init(summary: initial.conversations[id: a]!,
      draft: "old", messages: Array(initial.chat!.messages)))
    let other = initial.conversations[id: b]!
    var history = HistoryClient.noop()
    history.loadConversation = { id in id == source ? await gate.load() : .init(summary: other) }
    history.saveDraft = { _, draft in await gate.hold(); await gate.saveDraft(draft) }
    history.updateResultPresentation = { _, message in await gate.hold(); await gate.savePreference(message) }
    let clock = TestClock()
    let store = store(initial, history: history, clock: clock)
    if write == "draft" {
      await store.send(.chat(.binding(.set(\.composerText, "latest"))))
      await clock.advance(by: .milliseconds(500))
      await store.receive(\.draftSaveDue)
    } else {
      await store.send(.chat(.resultPresentationChanged(messageID: answer.id, preference: .table)))
    }
    try await gate.wait()
    await store.send(.conversationSelected(b)); await store.receive(\.conversationLoaded)
    await store.send(.conversationSelected(a)); await store.receive(\.conversationLoaded)
    let target: AppFeature.ConversationWriteTarget = write == "draft" ? .draft : .resultPresentation(answer.id)
    #expect(store.state.conversationEdits[a]?[target]?.isSaving == true)
    if write == "draft" { #expect(store.state.chat?.composerText == "latest") }
    else { #expect(store.state.chat?.messages[id: answer.id]?.resultPresentation == .table) }
    await gate.finish(); await store.receive(\.conversationWriteSettled); await store.finish()
    if write == "draft" { #expect(await gate.load().draft == "latest") }
    else { #expect(await gate.load().messages.last?.resultPresentation == .table) }
  }

  @Test(arguments: ["draft", "preference"])
  func lateSnapshotCannotUndoSuccessfulWrite(write: String) async throws {
    let initial = initialState(), source = a
    let answer = initial.chat!.messages.last!
    let snapshot = ConversationSnapshot(summary: initial.conversations[id: a]!,
      draft: "old", messages: Array(initial.chat!.messages))
    let writeGate = RegressionWriteGate(snapshot)
    var stale = snapshot
    let answerIndex = stale.messages.firstIndex { $0.id == answer.id }!
    stale.messages[answerIndex].createdAt = Date(timeIntervalSince1970: 999)
    let loadGate = RegressionWriteGate(stale)
    let other = initial.conversations[id: b]!
    var history = HistoryClient.noop()
    history.loadConversation = { id in
      guard id == source else { return .init(summary: other) }
      await loadGate.hold()
      return await loadGate.load()
    }
    history.saveDraft = { _, draft in await writeGate.hold(); await writeGate.saveDraft(draft) }
    history.updateResultPresentation = { _, message in
      await writeGate.hold(); await writeGate.savePreference(message)
    }
    let clock = TestClock()
    let store = store(initial, history: history, clock: clock)
    if write == "draft" {
      await store.send(.chat(.binding(.set(\.composerText, "latest"))))
    } else {
      await store.send(.chat(.resultPresentationChanged(messageID: answer.id, preference: .table)))
    }
    await store.send(.conversationSelected(b))
    await store.receive(\.conversationLoaded)
    await store.send(.conversationSelected(a))
    try await loadGate.wait()
    if write == "draft" {
      await clock.advance(by: .milliseconds(500))
      await store.receive(\.draftSaveDue)
    }
    try await writeGate.wait()
    await writeGate.finish()
    await store.receive(\.conversationWriteSettled)
    await loadGate.finish()
    await store.receive(\.conversationLoaded)
    await store.finish()
    if write == "draft" {
      #expect(store.state.chat?.composerText == "latest")
      #expect(await writeGate.load().draft == "latest")
    } else {
      #expect(store.state.chat?.messages[id: answer.id]?.resultPresentation == .table)
      #expect(store.state.chat?.messages[id: answer.id]?.createdAt == Date(timeIntervalSince1970: 999))
      #expect(store.state.conversationEdits[a]?[.resultPresentation(answer.id)]?.status == .saved(.resultPresentation(.table)))
      #expect(await writeGate.load().messages.last?.resultPresentation == .table)
    }
  }

  @Test(arguments: [false, true])
  func newerDraftIgnoresOlderSaveSettlement(fails: Bool) async throws {
    let initial = initialState()
    let gate = RegressionWriteGate(.init(summary: initial.conversations[id: a]!))
    await gate.setFailure(fails)
    var history = HistoryClient.noop()
    history.saveDraft = { _, draft in
      await gate.hold(); try await gate.attempt(); await gate.saveDraft(draft)
    }
    let clock = TestClock()
    let store = store(initial, history: history, clock: clock)
    await store.send(.chat(.binding(.set(\.composerText, "old"))))
    await clock.advance(by: .milliseconds(500))
    await store.receive(\.draftSaveDue)
    try await gate.wait()
    await store.send(.chat(.binding(.set(\.composerText, "new"))))
    await gate.finish()
    await store.receive(\.conversationWriteSettled)
    #expect(store.state.conversationEdits[a]?[.draft]?.status == .pending(.draft("new"), .debouncing))
    #expect(!store.state.failures.contains { $0.owner == .conversationOperation(a, .draft) })
    await gate.setFailure(false)
    await clock.advance(by: .milliseconds(500))
    await store.receive(\.draftSaveDue)
    await store.receive(\.conversationWriteSettled)
    await store.finish()
    #expect(await gate.load().draft == "new")
  }

  @Test(arguments: ["draft", "preference"])
  func failedWritesRemainEditableAndRetryLatestValueOnce(write: String) async throws {
    let initial = initialState(), source = a
    let answer = initial.chat!.messages.last!
    let gate = RegressionWriteGate(.init(summary: initial.conversations[id: a]!,
      draft: "old", messages: Array(initial.chat!.messages)))
    await gate.setFailure(true)
    await gate.finish()
    let other = initial.conversations[id: b]!
    var history = HistoryClient.noop()
    history.loadConversation = { id in id == source ? await gate.load() : .init(summary: other) }
    history.saveDraft = { _, draft in await gate.hold(); try await gate.attempt(); await gate.saveDraft(draft) }
    history.updateResultPresentation = { _, message in
      await gate.hold(); try await gate.attempt(); await gate.savePreference(message)
    }
    let clock = TestClock()
    let store = store(initial, history: history, clock: clock)
    let target: AppFeature.ConversationWriteTarget = write == "draft" ? .draft : .resultPresentation(answer.id)
    let owner = AppFeature.FailureOwner.conversationOperation(a, target.operation)
    if write == "draft" {
      await store.send(.chat(.binding(.set(\.composerText, "latest"))))
      await clock.advance(by: .milliseconds(500))
      await store.receive(\.draftSaveDue)
    } else {
      await store.send(.chat(.resultPresentationChanged(messageID: answer.id, preference: .table)))
    }
    await store.receive(\.conversationWriteSettled)
    await store.send(.conversationSelected(b))
    await store.receive(\.conversationLoaded)
    await store.send(.conversationSelected(a))
    await store.receive(\.conversationLoaded)
    #expect(store.state.retryableConversationWriteOwners.contains(owner))
    let originalOccurrence = store.state.failures.first { $0.owner == owner }!.id
    await store.send(.dismissOwnedFailure(owner))
    if write == "draft" { #expect(store.state.chat?.composerText == "latest") }
    else { #expect(store.state.chat?.messages[id: answer.id]?.resultPresentation == .table) }
    await gate.reset()
    await store.send(.retryConversationWrites(owner))
    await store.send(.retryConversationWrites(owner))
    try await gate.wait()
    await gate.finish()
    await store.receive(\.conversationWriteSettled)
    #expect(await gate.attemptCount() == 2)
    let retryFailure = store.state.failures.first { $0.owner == owner }!
    #expect(retryFailure.id != originalOccurrence)
    await store.send(.conversationWriteSettled(conversationID: a, target: target,
      revision: store.state.conversationEdits[a]![target]!.revision, settlement: .failed(retryFailure.failure)))
    #expect(store.state.failures.first { $0.owner == owner }?.id == retryFailure.id)
    await gate.setFailure(false)
    await gate.reset()
    await store.send(.retryConversationWrites(owner))
    await store.send(.retryConversationWrites(owner))
    try await gate.wait()
    await gate.finish()
    await store.receive(\.conversationWriteSettled)
    await store.send(.retryConversationWrites(owner))
    await store.finish()
    #expect(await gate.attemptCount() == 3)
    #expect(store.state.conversationEdits[a]?[target]?.isSaved == true)
    #expect(!store.state.failures.contains { $0.owner == owner })
    if write == "draft" { #expect(await gate.load().draft == "latest") }
    else { #expect(await gate.load().messages.last?.resultPresentation == .table) }
  }

  @Test func preferenceCaptureSharesMigrationGuardsAndAcceptsExplicitRetry() async {
    var initial = initialState()
    let messageID = initial.chat!.messages.last!.id
    initial.chat?.messages[id: messageID]?.resultPresentation = .automatic
    let writes = CallRecorder()
    var history = HistoryClient.noop()
    history.updateResultPresentation = { _, message in writes.record("\(message.resultPresentation.mode)") }
    let store = store(initial, history: history)
    await store.send(.chat(.resultPresentationMigrated(.init(messageID: messageID,
      previous: .automatic, updated: .table))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.chat?.messages[id: messageID]?.resultPresentation == .table)
    #expect(store.state.conversationWriteSequence == 1)
    await store.send(.chat(.resultPresentationMigrated(.init(messageID: messageID,
      previous: .automatic, updated: .automatic))))
    await store.finish()
    #expect(store.state.conversationWriteSequence == 1)
    await store.send(.chat(.resultPresentationChanged(messageID: messageID, preference: .table)))
    await store.finish()
    #expect(store.state.conversationWriteSequence == 2)
    #expect(writes.recorded.count == 2)
  }

  @Test func onePreferenceSuccessKeepsAnotherMessagesRecoveryNotice() async {
    var initial = initialState()
    let failure = FailurePresentation.history(operation: .messageSave, error: DiagnosticsTestError.failed("save"))
    var firstMessage = initial.chat!.messages.last!
    firstMessage.id = UUID()
    firstMessage.resultPresentation = .table
    var secondMessage = firstMessage
    secondMessage.id = UUID()
    let first = firstMessage.id, second = secondMessage.id
    let owner = AppFeature.FailureOwner.conversationOperation(a, .resultPresentation)
    initial.conversationEdits[a] = [
      .resultPresentation(first): .init(revision: 1, status: .pending(.resultPresentation(firstMessage), .saving)),
      .resultPresentation(second): .init(revision: 2, status: .pending(.resultPresentation(secondMessage), .saving)),
    ]
    initial.storeFailure(failure, owner: owner)
    let store = store(initial)
    await store.send(.conversationWriteSettled(conversationID: a, target: .resultPresentation(first),
      revision: 1, settlement: .saved))
    #expect(store.state.failures.contains { $0.owner == owner })
    await store.send(.conversationWriteSettled(conversationID: a, target: .resultPresentation(second),
      revision: 2, settlement: .saved))
    #expect(!store.state.failures.contains { $0.owner == owner })
  }

  @Test func historyReadDoesNotClearFailedDraftRecovery() {
    var state = initialState()
    let failure = FailurePresentation(code: "history_draft_save_failed", title: "Draft not saved",
      message: "Retry", diagnostic: "store unavailable", cause: .historyStoreUnavailable, recovery: .retryHistory)
    let owner = AppFeature.FailureOwner.conversationOperation(a, .draft)
    state.conversationEdits[a] = [.draft: .init(revision: 1, status: .pending(.draft("latest"), .failed(failure)))]
    state.storeFailure(failure, owner: owner)
    state.markHistoryStoreAvailable()
    #expect(state.failures.contains { $0.owner == owner })
    #expect(state.retryableConversationWriteOwners.contains(owner))
  }

  @Test(arguments: ["undo", "failed", "committed"])
  func deletionKeepsOrPrunesThePendingDraftTimer(outcome: String) async {
    let initial = initialState(), source = a
    let other = initial.conversations[id: b]!
    let gate = RegressionWriteGate(.init(summary: initial.conversations[id: a]!, draft: "old"))
    let drafts = CallRecorder()
    var history = HistoryClient.noop()
    history.loadConversation = { id in id == source ? await gate.load() : .init(summary: other) }
    history.saveDraft = { _, draft in drafts.record(draft); await gate.saveDraft(draft) }
    history.deleteConversation = { _ in
      if outcome == "failed" { throw DiagnosticsTestError.failed("delete") }
    }
    let clock = TestClock()
    let store = store(initial, history: history, clock: clock)
    await store.send(.chat(.binding(.set(\.composerText, "latest"))))
    await store.send(.deleteConversationTapped(a))
    await store.receive(\.conversationLoaded)
    if outcome == "undo" { await store.send(.undoDeleteTapped) }
    else {
      await store.send(.deleteCountdownFinished(store.state.pendingDeletion!.token))
      await store.receive(\.conversationDeletionFinished)
    }
    await clock.advance(by: .milliseconds(500))
    if outcome == "committed" {
      #expect(store.state.conversationEdits[a] == nil)
      await store.finish()
      #expect(drafts.recorded.isEmpty)
    } else {
      await store.receive(\.draftSaveDue)
      await store.receive(\.conversationWriteSettled)
      await store.send(.conversationSelected(a)); await store.receive(\.conversationLoaded)
      await store.finish()
      #expect(store.state.chat?.composerText == "latest")
      #expect(await gate.load().draft == "latest")
    }
  }

  @Test func draftRevisionsAreDistinctFromMessageRevisionsAndRejectLateEdits() async throws {
    let queue = MessageUpdateQueue()
    let calls = CallRecorder()
    #expect(try await queue.saveDraft(conversationID: a, revision: 2) {
      calls.record("cleared")
    } == .saved)
    #expect(try await queue.save(conversationID: a, messageID: UUID(), revision: 1) {
      calls.record("preference")
    } == .saved)
    #expect(try await queue.saveDraft(conversationID: a, revision: 1) {
      calls.record("stale")
    } == .superseded)
    await queue.beginDeletingConversation(a)
    await queue.confirmConversationDeletion(a)
    #expect(try await queue.saveDraft(conversationID: a, revision: 3) {
      calls.record("deleted")
    } == .discardedDuringDeletion)
    #expect(calls.recorded == ["cleared", "preference"])
  }

  @Test func launchSweepRemovesOnlyAbandonedOwnedArtifactsOnce() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let owned = root.appendingPathComponent("creg-support-bundle-\(UUID())")
    let active = root.appendingPathComponent("creg-support-bundle-\(UUID())")
    let legacy = root.appendingPathComponent("creg-support-bundle")
    let foreign = root.appendingPathComponent("creg-support-bundle-other-app")
    let target = root.appendingPathComponent("unrelated")
    let symlink = root.appendingPathComponent("creg-support-bundle-\(UUID())")
    let legacyZip = root.appendingPathComponent("creg-support-bundle.zip")
    for folder in [owned, active, legacy, foreign, target] {
      try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    try manager.createSymbolicLink(at: symlink, withDestinationURL: target)
    try Data().write(to: legacyZip)
    let protected = active.appendingPathComponent("creg-support-bundle.zip")
    try Data().write(to: protected)
    let files = SupportBundleFiles()
    await files.cleanAbandoned(protected: [protected], directory: root)
    for url in [owned, legacy, legacyZip] { #expect(!manager.fileExists(atPath: url.path)) }
    for url in [active, foreign, target, symlink] { #expect(manager.fileExists(atPath: url.path)) }
    // New artifacts survive repeat appearances in one launch. A new launch
    // sweeps those artifacts after their old lease has ceased to exist.
    try manager.createDirectory(at: owned, withIntermediateDirectories: true)
    await files.cleanAbandoned(protected: [], directory: root)
    #expect(manager.fileExists(atPath: owned.path))
    await SupportBundleFiles().cleanAbandoned(protected: [], directory: root)
    #expect(!manager.fileExists(atPath: owned.path))
    #expect(!manager.fileExists(atPath: active.path))
    #expect(manager.fileExists(atPath: target.path))
  }

  @Test func supportDismissalBeforeContentAppearsUsesCapturedIdentity() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("creg-support-bundle-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("creg-support-bundle.zip")
    try Data("fixture".utf8).write(to: url)
    let request = UUID(), stale = UUID()
    var initial = initialState()
    initial.supportBundleExport = .init(url: url,
      manifest: .init(createdAt: Date(), appVersion: "test", buildNumber: "1",
        modelKey: "test", modelRevision: "test", conversationCount: 0,
        messageCount: 0, eventLineCount: 0, feedbackCount: 0))
    initial.supportBundleExport?.requestID = request
    initial.supportBundlePresentationID = request
    let store = store(initial)
    // No view has appeared to remember this identity. The binding setter
    // must retain it before clearing presentation, for onDismiss's fallback.
    await store.send(.supportBundleDismissalRequested(request))
    #expect(store.state.supportBundlePresentationID == nil)
    let captured = try #require(store.state.supportBundleDismissalID)
    #expect(captured == request)
    await store.send(.supportBundleDismissalRequested(request))
    await store.send(.supportBundleDismissed(stale))
    #expect(store.state.supportBundleDismissalID == captured)
    #expect(FileManager.default.fileExists(atPath: url.path))
    await store.send(.supportBundleDismissed(captured))
    await store.finish()
    #expect(store.state.supportBundleExport == nil)
    #expect(store.state.supportBundleDismissalID == nil)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    await store.send(.supportBundleDismissed(captured))
    await store.finish()
  }

  @Test(arguments: ["settings", "notices", "rename", "result", "more", "delete_confirmation", "answer_share"])
  func everyCompetingModalRetainsExportAfterClosing(modal: String) async {
    var initial = initialState()
    initial.isSceneActive = true
    let request = UUID()
    initial.conversationExports[a] = .init(conversationID: a, requestID: request, phase: .exporting)
    let store = store(initial)
    switch modal {
    case "settings":
      await store.send(.binding(.set(\.isSettingsPresented, true)))
      await store.send(.binding(.set(\.isSettingsPresented, false)))
    case "notices":
      await store.send(.noticesTapped)
      await store.send(.sheetDismissalRequested(.notices(a)))
    case "rename":
      await store.send(.chat(.renameTapped))
      await store.send(.chat(.binding(.set(\.isRenamePresented, false))))
    case "result":
      await store.send(.chat(.resultViewerPresented(messageID: initial.chat!.messages.last!.id)))
      await store.send(.chat(.resultViewerDismissed))
    case "more":
      let id = UUID()
      await store.send(.answerMorePresented(conversationID: a, presentationID: id))
      await store.send(.answerMoreDismissed(conversationID: a, presentationID: id))
    default: await store.send(.conversationModalRequested(a))
    }
    await store.send(.conversationExportFinished(a, requestID: request,
      .success(URL(fileURLWithPath: "/tmp/creg-conversation-fixture.jsonl"))))
    #expect(store.state.presentation == nil)
    #expect(store.state.conversationExports[a]?.intent == .retained)
    await store.finish()
  }

  @Test(arguments: [false, true])
  func failedOpeningDoesNotBlockExportPresentation(explicitShare: Bool) async {
    var initial = initialState()
    initial.isSceneActive = true
    initial.conversationOpening = .init(requestID: 42, kind: .load(b), phase: .failed)
    initial.presentation = explicitShare ? .notices(a) : nil
    let request = UUID()
    initial.conversationExports[a] = .init(conversationID: a, requestID: request, phase: .exporting,
      intent: explicitShare ? .share : .export)
    let store = store(initial)
    await store.send(.conversationExportFinished(a, requestID: request,
      .success(URL(fileURLWithPath: "/tmp/creg-conversation-fixture.jsonl"))))
    #expect(store.state.presentation?.id == .export(request))
    #expect(store.state.conversationOpening?.phase == .failed)
    await store.finish()
  }

  @Test func renameNormalizesOptimisticTitleBeforePersistence() async {
    let names = CallRecorder()
    var history = HistoryClient.noop()
    history.renameConversation = { _, title in names.record(title) }
    var initial = initialState()
    initial.chat?.renameDraft = "  " + String(repeating: "👩🏽‍💻 ", count: 500) + "\n tail"
    let expected = HistoryStore.normalizedRenameTitle(from: initial.chat!.renameDraft)
    let store = store(initial, history: history)
    await store.send(.chat(.renameCommitted))
    await store.receive(\.chat.delegate)
    await store.finish()
    #expect(store.state.chat?.title == expected)
    #expect(store.state.conversations[id: a]?.title == expected)
    #expect(names.recorded == [expected])
    #expect(expected.count <= 80)
    #expect(HistoryStore.normalizedRenameTitle(from: expected) == expected)
  }

  @Test func excerptsKeepUsefulPrefixesAndCompleteWords() {
    #expect(conversationPreviewExcerpt("…July 2027…", accessibility: true) == "…July 2027…")
    #expect(conversationPreviewExcerpt("a " + String(repeating: "x", count: 200), accessibility: true).count == 60)
    #expect(conversationPreviewExcerpt("Compare https://" + String(repeating: "x", count: 200), accessibility: true).hasPrefix("Compare https://"))
    #expect(conversationPreviewExcerpt(String(repeating: "a", count: 29) + " " + String(repeating: "z", count: 100), accessibility: true).count == 60)
    #expect(conversationPreviewExcerpt(String(repeating: "a", count: 30) + " " + String(repeating: "z", count: 100), accessibility: true)
      == String(repeating: "a", count: 30) + "…")
    let complete = String(repeating: "x", count: 49) + " July 2027 " + String(repeating: "z", count: 100)
    #expect(conversationPreviewExcerpt(complete, accessibility: true).hasSuffix("July 2027…"))
    for size in [false, true] {
      let result = conversationPreviewExcerpt(String(repeating: "👩🏽‍💻 ", count: 200), accessibility: size)
      #expect(result.count <= (size ? 60 : 120))
      #expect(result.hasSuffix("…"))
    }
  }
}

extension PR158RegressionFixTests {
  @Test func groupedPreferenceRetryKeepsFailedSiblingUntilItsNextSave() async throws {
    var initial = initialState()
    var first = initial.chat!.messages.last!
    var sibling = first
    sibling.id = UUID()
    initial.chat?.messages.append(sibling)
    let firstTarget = AppFeature.ConversationWriteTarget.resultPresentation(first.id)
    let siblingTarget = AppFeature.ConversationWriteTarget.resultPresentation(sibling.id)
    let owner = AppFeature.FailureOwner.conversationOperation(a, .resultPresentation)
    let snapshot = ConversationSnapshot(summary: initial.conversations[id: a]!,
      messages: Array(initial.chat!.messages))
    let firstGate = RegressionWriteGate(snapshot), siblingGate = RegressionWriteGate(snapshot)
    let persistenceGate = RegressionWriteGate(snapshot)
    await firstGate.setFailure(true)
    await siblingGate.setFailure(true)
    await persistenceGate.finish()
    let firstID = first.id
    var history = HistoryClient.noop()
    history.updateResultPresentation = { _, message in
      let gate = message.id == firstID ? firstGate : siblingGate
      await persistenceGate.hold()
      try await gate.attempt()
      await persistenceGate.savePreference(message)
    }
    let store = store(initial, history: history)
    await store.send(.chat(.resultPresentationChanged(messageID: first.id, preference: .table)))
    await store.receive(\.conversationWriteSettled)
    await store.send(.chat(.resultPresentationChanged(messageID: sibling.id, preference: .table)))
    await store.receive(\.conversationWriteSettled)
    first.resultPresentation = .table
    sibling.resultPresentation = .table
    #expect(store.state.failures.filter { $0.owner == owner }.count == 1)
    #expect(store.state.retryableConversationWriteOwners.contains(owner))
    let originalNotice = try #require(store.state.failures.first { $0.owner == owner })

    await firstGate.setFailure(false)
    await persistenceGate.reset()
    await store.send(.retryConversationWrites(owner))
    await store.send(.retryConversationWrites(owner))
    try await persistenceGate.wait()
    #expect(store.state.conversationEdits[a]?[firstTarget]?.status == .pending(.resultPresentation(first), .saving))
    #expect(store.state.conversationEdits[a]?[siblingTarget]?.status == .pending(.resultPresentation(sibling), .saving))
    await persistenceGate.finish()
    await store.receive(\.conversationWriteSettled)
    await store.receive(\.conversationWriteSettled)
    #expect(store.state.conversationEdits[a]?[firstTarget]?.status == .saved(.resultPresentation(.table)))
    let retryNotice = try #require(store.state.failures.first { $0.owner == owner })
    #expect(retryNotice.id != originalNotice.id)
    #expect(store.state.failures.filter { $0.owner == owner }.count == 1)
    #expect(store.state.conversationEdits[a]?[siblingTarget]?.status == .pending(.resultPresentation(sibling), .failed(retryNotice.failure)))
    #expect(store.state.retryableConversationWriteOwners.contains(owner))
    #expect(await firstGate.attemptCount() == 2)
    #expect(await siblingGate.attemptCount() == 2)
    #expect(await persistenceGate.load().messages.first { $0.id == firstID }?.resultPresentation == .table)

    await siblingGate.setFailure(false)
    await persistenceGate.reset()
    await store.send(.retryConversationWrites(owner))
    await store.send(.retryConversationWrites(owner))
    try await persistenceGate.wait()
    await persistenceGate.finish()
    await store.receive(\.conversationWriteSettled)
    await store.send(.retryConversationWrites(owner))
    await store.finish()
    #expect(await firstGate.attemptCount() == 2)
    #expect(await siblingGate.attemptCount() == 3)
    #expect(await persistenceGate.load().messages.first { $0.id == sibling.id }?.resultPresentation == .table)
    #expect(store.state.conversationEdits[a]?[firstTarget]?.status == .saved(.resultPresentation(.table)))
    #expect(store.state.conversationEdits[a]?[siblingTarget]?.status == .saved(.resultPresentation(.table)))
    #expect(!store.state.retryableConversationWriteOwners.contains(owner))
    #expect(!store.state.failures.contains { $0.owner == owner })
  }

  @Test(arguments: ["  hello\n\t world  ", "  " + String(repeating: "👩🏽‍💻 ", count: 500) + "\n tail", " \n\t "])
  func directRenameDelegateNormalizesBeforeOptimisticDisplay(title: String) async {
    let writes = CallRecorder()
    var history = HistoryClient.noop()
    history.renameConversation = { _, title in writes.record(title) }
    let initial = initialState()
    let store = store(initial, history: history)
    let normalized = HistoryStore.normalizedRenameTitle(from: title)
    await store.send(.chat(.delegate(.renameRequested(a, title))))
    #expect(store.state.conversations[id: a]?.title == (normalized.isEmpty ? initial.conversations[id: a]?.title : normalized))
    await store.finish()
    #expect(writes.recorded == (normalized.isEmpty ? [] : [normalized]))
    #expect(normalized.count <= 80)
    if normalized.isEmpty { #expect(store.state.summaryWrites.isEmpty) }
  }

  @Test(arguments: ["rename", "export", "feedback"])
  func freshIdenticalAttemptMovesNoticeAndDuplicateDeliveryDoesNot(operation: String) async {
    let error = DiagnosticsTestError.failed("same attempt failure")
    let failure = FailurePresentation.history(operation: operation == "rename" ? .rename : operation == "export" ? .export : .feedbackSave, error: error)
    let kind: AppFeature.ConversationOperation = operation == "rename" ? .rename : operation == "export" ? .export : .feedback
    let owner = AppFeature.FailureOwner.conversationOperation(a, kind)
    var initial = initialState()
    initial.storeFailure(failure, owner: owner)
    let original = initial.failures.last!.id
    let other = FailurePresentation(code: "other", title: "Other failure", message: "Other", diagnostic: "Other")
    initial.storeFailure(other, owner: .global)
    let otherID = initial.failures.last!.id
    var history = HistoryClient.noop()
    history.renameConversation = { _, _ in throw error }
    history.exportJSONL = { _ in throw error }
    history.clearFeedback = { _, _ in throw error }
    let store = store(initial, history: history)
    var operationID: UUID?
    var requestID: UUID?
    if operation == "rename" {
      await store.send(.chat(.delegate(.renameRequested(a, "Name"))))
      operationID = store.state.summaryWrites.keys.first!
      await store.receive(\.summaryWriteSettled)
    } else if operation == "export" {
      await store.send(.chat(.delegate(.exportRequested(a))))
      requestID = store.state.conversationExports[a]!.requestID
      await store.receive(\.conversationExportFinished)
    } else {
      await store.send(.chat(.delegate(.feedbackWriteRequested(conversationID: a, write: .clear(UUID())))))
    }
    await store.receive(\.operationFailed)
    let fresh = store.state.failures.last!.id
    #expect(fresh != original)
    #expect(store.state.failures.map(\.id) == [otherID, fresh])
    #expect(store.state.presentedFailure == failure)
    if let operationID { await store.send(.summaryWriteSettled(operationID, failure)) }
    if let requestID { await store.send(.conversationExportFinished(a, requestID: requestID, .failure(failure))) }
    await store.send(.operationFailed(failure, owner: owner))
    #expect(store.state.failures.map(\.id) == [otherID, fresh])
    await store.send(.binding(.set(\.presentedFailure, nil)))
    #expect(store.state.failures.map(\.id) == [otherID])
    #expect(store.state.presentedFailure == other)
    await store.finish()
  }

  @Test(arguments: ["draft", "preference", "rename", "export", "feedback"], ["undo", "failed", "committed"])
  func freshHeldFailureKeepsOccurrenceIntentThroughDeletion(operation: String, outcome: String) async throws {
    let error = DiagnosticsTestError.failed("held failure")
    let kind: AppFeature.ConversationOperation = operation == "draft" ? .draft : operation == "preference" ? .resultPresentation : operation == "rename" ? .rename : operation == "export" ? .export : .feedback
    let failure = FailurePresentation.history(operation: operation == "draft" ? .draftSave : operation == "preference" ? .resultPreferenceSave : operation == "rename" ? .rename : operation == "export" ? .export : .feedbackSave, error: error)
    let owner = AppFeature.FailureOwner.conversationOperation(a, kind)
    var initial = initialState()
    initial.storeFailure(failure, owner: owner)
    let oldID = initial.failures.last!.id
    let other = FailurePresentation(code: "other", title: "Other", message: "Keep", diagnostic: "Keep")
    initial.storeFailure(other, owner: .historySummaries(77))
    let otherID = initial.failures.last!.id
    let answer = initial.chat!.messages.last!
    let gate = RegressionWriteGate(.init(summary: initial.conversations[id: a]!, messages: Array(initial.chat!.messages)))
    var history = HistoryClient.noop()
    let summaries = initial.conversations
    history.loadConversation = { id in .init(summary: summaries[id: id]!) }
    history.saveDraft = { _, _ in await gate.hold(); throw error }
    history.updateResultPresentation = { _, _ in await gate.hold(); throw error }
    history.renameConversation = { _, _ in await gate.hold(); throw error }
    history.exportJSONL = { _ in await gate.hold(); throw error }
    history.clearFeedback = { _, _ in await gate.hold(); throw error }
    if outcome == "failed" { history.deleteConversation = { _ in throw DiagnosticsTestError.failed("delete") } }
    let clock = TestClock()
    let recorder = DiagnosticEventRecorder()
    let store = store(initial, history: history, clock: clock, recorder: recorder)
    switch operation {
    case "draft":
      await store.send(.chat(.binding(.set(\.composerText, "new"))))
      await clock.advance(by: .milliseconds(500))
      await store.receive(\.draftSaveDue)
    case "preference": await store.send(.chat(.resultPresentationChanged(messageID: answer.id, preference: .table)))
    case "rename": await store.send(.chat(.delegate(.renameRequested(a, "New"))))
    case "export": await store.send(.chat(.delegate(.exportRequested(a))))
    default: await store.send(.chat(.delegate(.feedbackWriteRequested(conversationID: a, write: .clear(answer.id)))))
    }
    try await gate.wait()
    await store.send(.deleteConversationTapped(a))
    await store.receive(\.conversationLoaded)
    await gate.finish()
    switch operation {
    case "draft", "preference": await store.receive(\.conversationWriteSettled)
    case "rename": await store.receive(\.summaryWriteSettled)
    case "export": await store.receive(\.conversationExportFinished)
    default: await store.receive(\.operationFailed)
    }
    #expect(store.state.conversationDeletions[a]?.deferredNewOccurrenceOwners == [owner])
    #expect(store.state.failures.first { $0.owner == owner }?.id == oldID)
    if outcome == "undo" { await store.send(.undoDeleteTapped) }
    else {
      await store.send(.deleteCountdownFinished(store.state.pendingDeletion!.token))
      await store.receive(\.conversationDeletionFinished)
    }
    await store.finish()
    if outcome == "committed" {
      #expect(!store.state.failures.contains { $0.owner == owner })
      #expect(recorder.events.contains { $0.code == "conversation_write_failed_after_deletion" })
    } else {
      let restored = try #require(store.state.failures.first { $0.owner == owner })
      #expect(restored.id != oldID)
      #expect(store.state.failures.first { $0.owner == .historySummaries(77) }?.id == otherID)
      #expect(store.state.failures.last?.owner == owner)
    }
  }

  @Test func freshDeferredFailureReplacesOwnerAndMovesAfterOtherDeferredFailures() async {
    var initial = initialState()
    initial.conversationDeletions[a] = .init(token: UUID(), summary: initial.conversations[id: a]!)
    initial.undoDeletionID = a
    let first = AppFeature.FailureOwner.conversationOperation(a, .rename)
    let second = AppFeature.FailureOwner.conversationOperation(a, .feedback)
    let failure = FailurePresentation.history(operation: .rename, error: DiagnosticsTestError.failed("same"))
    let store = store(initial)
    await store.send(.operationFailed(failure, owner: first, newOccurrence: true))
    await store.send(.operationFailed(failure, owner: second, newOccurrence: true))
    await store.send(.operationFailed(failure, owner: first))
    #expect(store.state.conversationDeletions[a]?.deferredOperationFailures.map(\.owner) == [first, second])
    await store.send(.operationFailed(failure, owner: first, newOccurrence: true))
    #expect(store.state.conversationDeletions[a]?.deferredOperationFailures.map(\.owner) == [second, first])
    await store.send(.undoDeleteTapped)
    #expect(store.state.failures.map(\.owner) == [second, first])
    await store.finish()
  }
}
