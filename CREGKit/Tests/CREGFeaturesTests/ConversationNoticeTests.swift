import ComposableArchitecture
import SwiftUI
import Testing

@testable import CREGEngine
@testable import CREGFeatures

@MainActor @Suite struct ConversationNoticeTests {
  @Test func renameFailureOutranksReadyExportAndRecoveryCountsOnce() {
    let chat = PreviewFixtures.chatStore(PreviewFixtures.answeredChatState())
    var chrome = PreviewFixtures.chrome
    chrome.modelReadiness = .ready
    chrome.fmAvailability = .available
    chrome.exportPhase = .ready(URL(fileURLWithPath: "/tmp/export.jsonl"))
    let failure = FailurePresentation(
      code: "history_rename_failed", title: "Rename failed", message: "Retry", diagnostic: "test")
    chrome.ownedFailures = [
      .init(owner: .conversationOperation(chat.conversationID, .rename), failure: failure)
    ]
    var summary = ChatNoticeSummary(store: chat, chrome: chrome)
    #expect(summary.title == "Rename failed")
    #expect(summary.count == 2)
    #expect(summary.isError)
    chrome.exportPhase = nil
    chrome.ownedFailures = [
      .init(
        owner: .historySummaries(1),
        failure: .init(
          code: "history_summary_timed_out", title: "History is taking longer than expected",
          message: "Still loading", diagnostic: "test", recovery: .retryHistory))
    ]
    chrome.historyIsLoading = true
    chrome.canRetryHistory = true
    chrome.historyIsSlow = true
    summary = ChatNoticeSummary(store: chat, chrome: chrome)
    #expect(summary.count == 1)
    #expect(!summary.isError)
  }

  @Test func temporaryAndPausedPreparationUseAccurateTitles() {
    let chat = PreviewFixtures.chatStore(PreviewFixtures.chatState())
    var chrome = PreviewFixtures.chrome
    chrome.modelReadiness = .ready
    chrome.fmAvailability = .unavailable(reason: .modelNotReady)
    #expect(ChatNoticeSummary(store: chat, chrome: chrome).title == "Preparing Apple Intelligence")
    chrome.fmAvailability = .available
    chrome.modelReadiness = .failed(
      .init(
        code: ModelPreparationFailure.previousPreparationSuspendedCode,
        stage: .containerLoad, mode: .evaluated, userMessage: "Paused", diagnostic: "test"))
    #expect(ChatNoticeSummary(store: chat, chrome: chrome).title == "SQL model preparation paused")
  }

  @Test func drawerEligibilityRejectsMiddleFlicksAndCancelsDirectionChanges() {
    var middle = DrawerGestureEligibility()
    let changed1 = middle.change(startX: 150, dx: 100, dy: 1, revealed: false)
    #expect(!changed1)
    #expect(!middle.canRelease(startX: 150, dx: 300, dy: 1, revealed: false))
    var edge = DrawerGestureEligibility()
    let changed2 = edge.change(startX: 10, dx: 80, dy: 1, revealed: false)
    #expect(changed2)
    let changed3 = edge.change(startX: 10, dx: 80, dy: 120, revealed: false)
    #expect(!changed3)
    let changed4 = edge.change(startX: 10, dx: 200, dy: 120, revealed: false)
    #expect(!changed4)
    #expect(!edge.canRelease(startX: 10, dx: 200, dy: 120, revealed: false))
    var interrupted = DrawerGestureEligibility()
    let changed5 = interrupted.change(startX: 10, dx: 80, dy: 1, revealed: false)
    #expect(changed5)
    #expect(!interrupted.canRelease(startX: 10, dx: 200, dy: 1, revealed: true))
  }
}
