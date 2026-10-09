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
    if !released { await withCheckedContinuation { continuation = $0 } }
  }
  func wait() async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !started {
      guard ContinuousClock.now < deadline else { throw DiagnosticsTestError.failed("Write did not start") }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
  func finish() { released = true; continuation?.resume(); continuation = nil }
  func saveDraft(_ draft: String) { snapshot.draft = draft }
  func savePreference(_ message: ChatMessage) {
    snapshot.messages[snapshot.messages.firstIndex(where: { $0.id == message.id })!] = message
  }
  func load() -> ConversationSnapshot { snapshot }
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
      await store.receive(\.chat.delegate)
      await clock.advance(by: .milliseconds(500))
      await store.receive(\.draftSaveDue)
    } else {
      await store.send(.chat(.resultPresentationChanged(messageID: answer.id, preference: .table)))
      await store.receive(\.chat.delegate)
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
    if fails { await store.receive(\.operationFailed) }
    await store.finish()
    let owner: AppFeature.FailureOwner = .conversationOperation(a, write == "draft" ? .draft : .resultPresentation)
    if outcome == "committed" {
      #expect(!store.state.failures.contains { $0.owner == owner })
      #expect(recorder.events.filter { $0.code == "conversation_write_failed_after_deletion" }.count == (fails ? 1 : 0))
    } else {
      #expect(store.state.failures.contains { $0.owner == owner } == fails)
      await store.send(.conversationSelected(a))
      await store.receive(\.conversationLoaded)
      await store.finish()
      if write == "draft" {
        #expect(store.state.chat?.composerText == (fails ? "stored draft" : "new draft"))
      } else if !fails {
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
    await store.receive(\.chat.delegate)
    await clock.advance(by: .milliseconds(250))
    await store.send(.chat(.binding(.set(\.composerText, "new"))))
    await store.receive(\.chat.delegate)
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
    await store.receive(\.chat.delegate)
    await clock.advance(by: .milliseconds(500))
    await store.receive(\.draftSaveDue)
    try await gate.wait()
    let delayedRevision = store.state.draftSaveRevisions[a]!
    await store.send(.chat(.sendTapped))
    await store.receive(\.chat.delegate)
    #expect(store.state.chat?.composerText == "")
    await store.send(.chat(.delegate(.draftChanged(conversationID: a,
      draft: "late pre-submission edit", revision: delayedRevision))))
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
    await store.receive(\.chat.delegate)
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
      await store.receive(\.chat.delegate)
      await clock.advance(by: .milliseconds(500))
      await store.receive(\.draftSaveDue)
    } else {
      await store.send(.chat(.resultPresentationChanged(messageID: answer.id, preference: .table)))
      await store.receive(\.chat.delegate)
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
