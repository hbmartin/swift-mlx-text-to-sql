import ComposableArchitecture
import Foundation
import SwiftUI
import Testing

@testable import CREGEngine
@testable import CREGFeatures

private actor FollowUpHeldOperation {
  private var started = false
  private var released = false
  private var continuation: CheckedContinuation<Void, Never>?
  func hold() async {
    started = true
    if !released { await withCheckedContinuation { continuation = $0 } }
  }
  func wait() async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !started {
      guard ContinuousClock.now < deadline else { throw DiagnosticsTestError.failed("Operation did not start") }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
  func finish() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct PR158FollowUpTests {
  private let a = AppFeatureSchedulerTests.conversationA
  private let b = AppFeatureSchedulerTests.conversationB

  private func state() -> AppFeature.State {
    var value = AppFeatureSchedulerTests.appState()
    value.launchBenchmarkQuestion = nil
    value.didRequestPreparationJournalInspection = true
    value.didHandlePreparationJournalInspection = true
    value.isSceneActive = false
    return value
  }
  private func store(_ initial: AppFeature.State, history: HistoryClient = .noop(),
    recorder: DiagnosticEventRecorder = DiagnosticEventRecorder(),
    support: SupportBundleClient = .noop) -> TestStoreOf<AppFeature> {
    let result = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.historyClient = history
      $0.continuousClock = TestClock()
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.diagnostics = recorder.client
      $0.supportBundle = support
    }
    result.exhaustivity = .off
    return result
  }

  @Test(arguments: ["save", "clear", "correction"],
    ["navigation", "undo", "delete_failed", "committed_before", "committed_after"])
  func heldFeedbackFailuresKeepTheirOrigin(write: String, outcome: String) async throws {
    let held = FollowUpHeldOperation()
    let calls = CallRecorder()
    let recorder = DiagnosticEventRecorder()
    var initial = state()
    var chat = PreviewFixtures.answeredChatState()
    chat.conversationID = a
    let answer = try #require(chat.messages.last(where: { $0.role == .assistant }))
    if write != "save" {
      chat.feedback[answer.id] = .init(messageID: answer.id,
        verdict: write == "clear" ? .helpful : .notRight, updatedAt: Date())
    }
    if write == "correction" {
      chat.correctionContext = .init(messageID: answer.id, answerNarration: "Source")
      chat.composerText = "Use the current holdings"
    }
    initial.chat = chat
    let independent = FailurePresentation(code: "independent", title: "Independent", message: "Keep", diagnostic: "test")
    let owners: [AppFeature.FailureOwner] = [.global, .conversationOperation(b, .rename), .conversationOperation(b, .export)]
      + (outcome == "navigation" ? [.conversationOperation(a, .rename), .conversationOperation(a, .export)] : [])
    for owner in owners { initial.storeFailure(independent, owner: owner) }
    let summaries = initial.conversations
    var history = HistoryClient.noop()
    history.loadConversation = { id in ConversationSnapshot(summary: summaries[id: id]!) }
    history.saveFeedback = { id, _ in
      calls.record(id.uuidString); await held.hold(); throw DiagnosticsTestError.failed("feedback")
    }
    history.clearFeedback = { id, _ in
      calls.record(id.uuidString); await held.hold(); throw DiagnosticsTestError.failed("feedback")
    }
    history.deleteConversation = { _ in
      if outcome == "delete_failed" { throw DiagnosticsTestError.failed("delete") }
    }
    let store = store(initial, history: history, recorder: recorder)
    await store.send(.chat(write == "correction" ? .sendTapped : .feedbackHelpfulTapped(messageID: answer.id)))
    await store.receive(.chat(.delegate(.feedbackWriteRequested(conversationID: a,
      write: write == "clear" ? .clear(answer.id) : .save(store.state.chat!.feedback[answer.id]!)))))
    try await held.wait()
    if outcome == "navigation" {
      await store.send(.conversationSelected(b))
    } else {
      await store.send(.deleteConversationTapped(a))
    }
    await store.receive(\.conversationLoaded)
    if outcome == "committed_before" {
      await store.send(.deleteCountdownFinished(store.state.pendingDeletion!.token))
      await store.receive(\.conversationDeletionFinished)
    }
    await held.finish()
    await store.receive(\.operationFailed)
    #expect(calls.recorded == [a.uuidString])
    #expect(store.state.visibleFailures.allSatisfy { $0.failure.code != "history_feedback_save_failed" })
    #expect(owners.allSatisfy { owner in store.state.failures.contains { $0.owner == owner && $0.failure == independent } })
    if outcome == "undo" {
      #expect(store.state.conversationDeletions[a]?.deferredOperationFailures.count == 1)
      await store.send(.undoDeleteTapped)
    } else if outcome == "delete_failed" || outcome == "committed_after" {
      #expect(store.state.conversationDeletions[a]?.deferredOperationFailures.count == 1)
      await store.send(.deleteCountdownFinished(store.state.pendingDeletion!.token))
      await store.receive(\.conversationDeletionFinished)
    }
    await store.finish()
    if outcome.hasPrefix("committed") {
      #expect(!store.state.failures.contains { $0.failure.code == "history_feedback_save_failed" })
      #expect(recorder.events.filter { $0.code == "conversation_write_failed_after_deletion" }.count == 1)
    } else {
      #expect(store.state.failures.contains { $0.owner == .conversationOperation(a, .feedback) && $0.failure.code == "history_feedback_save_failed" })
      await store.send(.conversationSelected(a))
      await store.receive(\.conversationLoaded)
      await store.finish()
      #expect(store.state.visibleFailures.contains { $0.owner == .conversationOperation(a, .feedback) && $0.failure.code == "history_feedback_save_failed" })
    }
  }

  private func supportArtifact() throws -> AppFeature.SupportBundleExport {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("creg-support-bundle-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("creg-support-bundle.zip")
    try Data("test".utf8).write(to: url)
    return .init(url: url, manifest: .init(createdAt: Date(), appVersion: "test", buildNumber: "1",
      modelKey: "test", modelRevision: "test", conversationCount: 2, messageCount: 3, eventLineCount: 4, feedbackCount: 0,
      entries: [.init(path: "diagnostics.jsonl", byteCount: 4, sha256: "fixture")]))
  }

  @Test func supportDismissalRequestsRetainFilesUntilMatchingCompletion() async throws {
    let recorder = DiagnosticEventRecorder()
    let request = UUID(21001), stale = UUID(21002)
    let export = try supportArtifact()
    let newer = try supportArtifact()
    defer { try? FileManager.default.removeItem(at: export.url.deletingLastPathComponent()) }
    defer { try? FileManager.default.removeItem(at: newer.url.deletingLastPathComponent()) }
    var initial = state()
    initial.supportBuildRequestID = request
    let store = store(initial, recorder: recorder, support: .init { _ in newer })
    await store.send(.supportBundleReady(export, requestID: request))
    #expect(store.state.supportBundlePresentationID == request)
    let event = try #require(recorder.events.first { $0.code == "support_bundle_finished" })
    #expect(event.context["conversation_count"] == "2")
    #expect(event.context["entry_count"] == "1")
    await store.send(.supportBundleDismissalRequested(stale))
    #expect(store.state.supportBundlePresentationID == request)
    await store.send(.supportBundleDismissalRequested(request))
    #expect(store.state.supportBundlePresentationID == nil)
    #expect(store.state.supportBundleExport?.requestID == request)
    #expect(FileManager.default.fileExists(atPath: export.url.path))
    await store.send(.supportBundleExportTapped)
    #expect(store.state.supportBuildRequestID == nil)
    await store.send(.supportBundleReady(export, requestID: request))
    #expect(store.state.supportBundlePresentationID == nil)
    await store.send(.supportBundleDismissed(stale))
    #expect(FileManager.default.fileExists(atPath: export.url.path))
    await store.send(.supportBundleDismissed(request))
    await store.finish()
    #expect(store.state.supportBundleExport == nil)
    #expect(!FileManager.default.fileExists(atPath: export.url.deletingLastPathComponent().path))
    await store.send(.supportBundleExportTapped)
    await store.receive(\.supportBundleReady)
    // A late old callback cannot consume the next retained artifact.
    let nextRequest = try #require(store.state.supportBundleExport?.requestID)
    await store.send(.supportBundleDismissed(request))
    #expect(store.state.supportBundleExport?.requestID == nextRequest)
    await store.send(.supportBundleDismissed(nextRequest))
    await store.finish()
  }

  @Test func moreOwnershipRetainsExportAndIgnoresOldDismissal() async throws {
    let held = FollowUpHeldOperation()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("creg-conversation-\(UUID()).jsonl")
    try Data("{}\n".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    var history = HistoryClient.noop()
    history.exportJSONL = { _ in await held.hold(); return url }
    var initial = state()
    initial.isSceneActive = true
    let store = store(initial, history: history)
    await store.send(.chat(.delegate(.exportRequested(a))))
    try await held.wait()
    let first = UUID(21003), second = UUID(21004)
    await store.send(.answerMorePresented(conversationID: a, presentationID: first))
    #expect(store.state.conversationExports[a]?.intent == .retained)
    await store.send(.answerMorePresented(conversationID: a, presentationID: second))
    await store.send(.answerMoreDismissed(conversationID: a, presentationID: first))
    #expect(store.state.answerMorePresentation?.presentationID == second)
    // Even an explicit reactivation cannot bypass the currently owned popover.
    await store.send(.shareConversationExport(a))
    await held.finish()
    await store.receive(\.conversationExportFinished)
    #expect(store.state.presentation == nil)
    #expect(store.state.presentedExportFiles.isEmpty)
    #expect(store.state.conversationExports[a]?.phase == .ready(url))
    await store.send(.answerMoreDismissed(conversationID: a, presentationID: second))
    #expect(store.state.answerMorePresentation == nil)
    #expect(store.state.presentation == nil)
    await store.finish()
  }

  @Test func discardOwnsOnlyUnleasedReadyResultAndPreservesErrors() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("creg-conversation-\(UUID()).jsonl")
    try Data("{}\n".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let request = UUID(21005)
    var initial = state()
    initial.conversationExports[a] = .init(conversationID: a, requestID: request, phase: .ready(url), intent: .retained)
    let failure = FailurePresentation(code: "rename", title: "Rename failed", message: "Keep", diagnostic: "test")
    initial.storeFailure(failure, owner: .conversationOperation(a, .rename))
    initial.presentedExportFiles[request] = url
    let store = store(initial)
    await store.send(.discardConversationExport(conversationID: a, requestID: UUID(21006)))
    await store.send(.discardConversationExport(conversationID: a, requestID: request))
    #expect(store.state.conversationExports[a] != nil)
    #expect(FileManager.default.fileExists(atPath: url.path))
    await store.finish()
    initial.presentedExportFiles.removeValue(forKey: request)
    let unleased = self.store(initial)
    await unleased.send(.discardConversationExport(conversationID: a, requestID: request))
    await unleased.finish()
    #expect(unleased.state.conversationExports[a] == nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(unleased.state.failures == initial.failures)
  }

  @Test func interruptionDiagnosticOwnershipSurvivesJournalSeeding() async throws {
    let held = FollowUpHeldOperation()
    let recorder = DiagnosticEventRecorder()
    var initial = state()
    let question = ChatMessage(id: UUID(21007), role: .user, body: .text("Question"), createdAt: Date())
    var active = AppFeature.ActiveTurn(questionID: question.id, conversationID: a,
      question: question.previewText, startedAt: question.createdAt)
    active.optimisticUserTurn = .init(message: question, previousSummary: initial.conversations[id: a], previousChatTitle: "")
    initial.activeTurn = active
    var history = HistoryClient.noop()
    history.persistUserTurn = { _, _, _, _, _ in await held.hold() }
    let store = store(initial, history: history, recorder: recorder)
    await store.send(.appEnteredBackground)
    try await held.wait()
    let number = try #require(store.state.pendingInterruptedTurn?.interruptionDiagnosticOperationNumber)
    #expect(recorder.events.first { $0.code == "chat_turn_interrupted" }?.context["operation_number"] == String(number))
    await held.finish()
    await store.receive(\.turnInterruptionRecorded)
    await store.finish()
    #expect(store.state.retryJournals[question.id]?.diagnosticOperationNumber == number)
    var ownership = store.state
    ownership.seedRetry(question.id, conversationID: a, diagnosticOperationNumber: number + 100)
    #expect(ownership.retryJournals[question.id]?.diagnosticOperationNumber == number)
    // Other seeding paths can adopt the number before the durable completion.
    ownership.retryJournals.removeValue(forKey: question.id)
    active.interruptionDiagnosticOperationNumber = number
    ownership.pendingInterruptedTurn = active
    ownership.seedRetry(question.id, conversationID: a)
    #expect(ownership.retryJournals[question.id]?.diagnosticOperationNumber == number)
    let operation = UUID(21008)
    ownership.retryJournals[question.id]?.operations[operation] = .decline(.refusedClaimCleanup)
    let retry = self.store(ownership, history: .noop(), recorder: recorder)
    let failure = FailurePresentation.history(operation: .load, error: DiagnosticsTestError.failed("cleanup"))
    for _ in 0..<2 {
      await retry.send(.retryDeclineFinished(conversationID: a, journalID: question.id,
        operationID: operation, failure: failure))
    }
    await retry.finish()
    let events = recorder.events.filter { $0.code == "retry_claim_cleanup_failed" }
    #expect(events.count == 1)
    #expect(events.first?.context["operation_number"] == String(number))
  }

  @Test func openingFailureDeduplicationUsesOnlyCurrentOwnership() async throws {
    let recorder = DiagnosticEventRecorder()
    let failure = FailurePresentation.history(operation: .load, error: DiagnosticsTestError.failed("opening"))
    var history = HistoryClient.noop()
    history.loadConversation = { _ in throw DiagnosticsTestError.failed("opening") }
    let store = store(state(), history: history, recorder: recorder)
    for _ in 1...1000 {
      await store.send(.conversationSelected(b))
      let request = try #require(store.state.conversationOpening?.requestID)
      await store.receive(\.conversationOpeningFailed)
      await store.send(.conversationOpeningFailed(request, failure))
    }
    #expect(recorder.events.filter { $0.code == failure.code }.count == 1000)
    #expect(store.state.conversationCreations.isEmpty)
    #expect(store.state.failures.filter { if case .conversationOpening = $0.owner { true } else { false } }.count == 1)
    await store.send(.conversationOpeningFailed(2000, failure))
    #expect(recorder.events.filter { $0.code == failure.code }.count == 1000)
    await store.finish()
  }

  @Test func previewExcerptsBoundContentWithoutBreakingGraphemes() {
    #expect(conversationPreviewExcerpt("  First\n\n second\tthird ", accessibility: false) == "First second third")
    for accessibility in [false, true] {
      let limit = accessibility ? 60 : 120
      let paragraphs = String(repeating: "A complete paragraph of narration. \n\n", count: 30)
      let excerpt = conversationPreviewExcerpt(paragraphs, accessibility: accessibility)
      #expect(excerpt.count <= limit)
      #expect(excerpt.hasSuffix("…"))
      #expect(!excerpt.contains("\n"))
      let longToken = String(repeating: "x", count: 200)
      #expect(conversationPreviewExcerpt(longToken, accessibility: accessibility).count == limit)
      let family = "👩🏽‍👩🏽‍👧🏽‍👦🏽"
      #expect(conversationPreviewExcerpt(String(repeating: family, count: 200), accessibility: accessibility)
        == String(repeating: family, count: limit - 1) + "…")
    }
    #expect(conversationPreviewExcerpt(String(repeating: "x", count: 60), accessibility: true).count == 60)
  }

  @Test func unreadProjectionExcludesDeletedSummaries() {
    var state = state()
    state.conversations[id: a]?.isUnread = false
    state.conversations[id: b]?.isUnread = true
    #expect(state.hasUnreadLiveConversation)
    state.conversationDeletions[b] = .init(token: UUID(), summary: state.conversations[id: b]!)
    #expect(!state.hasUnreadLiveConversation)
  }
}
