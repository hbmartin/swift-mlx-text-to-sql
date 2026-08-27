import AutoTableCharts
import CREGEngine
import ComposableArchitecture
import Foundation
import SwiftUI

#if DEBUG
// MARK: - Named design previews

#Preview("Chat — Empty — Light") {
  ChatView(
    store: PreviewFixtures.chatStore(PreviewFixtures.chatState()),
    chrome: PreviewFixtures.chrome)
    .preferredColorScheme(.light)
}

#Preview("Chat — Conversation — Result") {
  ChatView(
    store: PreviewFixtures.chatStore(
      PreviewFixtures.chatState(
        messages: PreviewFixtures.conversationMessages,
        title: "Current market value by fund")),
    chrome: PreviewFixtures.chrome)
}

#Preview("Chat — Conversation — Dark") {
  ChatView(
    store: PreviewFixtures.chatStore(
      PreviewFixtures.chatState(
        messages: PreviewFixtures.conversationMessages,
        title: "Current market value by fund")),
    chrome: PreviewFixtures.chrome)
    // The chat surface is painted by AppRootView, so previews of ChatView
    // alone supply it to judge bubble contrast against the real background.
    .background(CREGBrand.chatSurface.ignoresSafeArea())
    .preferredColorScheme(.dark)
}

#Preview("Turn Failure — Generation Exhausted") {
  ChatView(
    store: PreviewFixtures.chatStore(
      PreviewFixtures.failedTurnChatState(reason: .generationExhausted)),
    chrome: PreviewFixtures.chrome)
}

#Preview("Turn Failure — Timed Out — Retry") {
  ChatView(
    store: PreviewFixtures.chatStore(
      PreviewFixtures.failedTurnChatState(
        reason: .timedOut(stage: "generation"))),
    chrome: PreviewFixtures.chrome)
}

#Preview("Turn Failure — Cancelled") {
  ChatView(
    store: PreviewFixtures.chatStore(
      PreviewFixtures.failedTurnChatState(reason: .cancelled)),
    chrome: PreviewFixtures.chrome)
}

#Preview("Turn Failure — Database Unavailable — Dark") {
  ChatView(
    store: PreviewFixtures.chatStore(
      PreviewFixtures.failedTurnChatState(reason: .databaseUnavailable)),
    chrome: PreviewFixtures.chrome)
    .background(CREGBrand.chatSurface.ignoresSafeArea())
    .preferredColorScheme(.dark)
}

#Preview("Turn Failure — Not Tracked Verdict") {
  ChatView(
    store: PreviewFixtures.chatStore(
      PreviewFixtures.failedTurnChatState(
        reason: .generationExhausted,
        scopeVerdict: ScopeVerdictRecord(
          verdict: .inDomainButNotTracked,
          missingSubject: "property managers"))),
    chrome: PreviewFixtures.chrome)
}

#Preview("Turn Failure — Answerable Verdict") {
  ChatView(
    store: PreviewFixtures.chatStore(
      PreviewFixtures.failedTurnChatState(
        reason: .noCandidateSelected,
        scopeVerdict: ScopeVerdictRecord(
          verdict: .likelyAnswerableModelFailed))),
    chrome: PreviewFixtures.chrome)
}

#Preview("Chat — Apple Intelligence Off") {
  ChatView(
    store: PreviewFixtures.chatStore(PreviewFixtures.chatState()),
    chrome: PreviewFixtures.chrome(
      fmAvailability: .unavailable(reason: .appleIntelligenceNotEnabled)))
}

#Preview("Chat — Apple Intelligence Preparing") {
  ChatView(
    store: PreviewFixtures.chatStore(PreviewFixtures.chatState()),
    chrome: PreviewFixtures.chrome(
      fmAvailability: .unavailable(reason: .modelNotReady)))
}

#Preview("Chat — Processing and Queue") {
  ChatView(
    store: PreviewFixtures.chatStore(PreviewFixtures.processingChatState()),
    chrome: PreviewFixtures.chrome)
}

#Preview("Chat — Follow-up Suggestions — Partial") {
  ChatView(
    store: PreviewFixtures.chatStore(
      PreviewFixtures.followUpChatState(count: 1)),
    chrome: PreviewFixtures.chrome)
}

#Preview("Chat — Follow-up Suggestions — Ready — Dark") {
  ChatView(
    store: PreviewFixtures.chatStore(
      PreviewFixtures.followUpChatState(count: 3)),
    chrome: PreviewFixtures.chrome)
    .background(CREGBrand.chatSurface.ignoresSafeArea())
    .preferredColorScheme(.dark)
}

#Preview("Chat — Prepared Answer — Summarizing") {
  ChatView(
    store: PreviewFixtures.chatStore(
      PreviewFixtures.summarizingPreparedChatState()),
    chrome: PreviewFixtures.chrome)
}

#Preview("Chat — Follow-up Suggestions — Accessibility") {
  ChatView(
    store: PreviewFixtures.chatStore(
      PreviewFixtures.followUpChatState(count: 3)),
    chrome: PreviewFixtures.chrome)
    .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("Chat — Developer Mode Expanded") {
  var chrome = PreviewFixtures.chrome
  chrome.developerMode = true
  return ChatView(
    store: PreviewFixtures.chatStore(
      PreviewFixtures.chatState(
        messages: PreviewFixtures.conversationMessages,
        title: "Current market value by fund")),
    chrome: chrome)
}

#Preview("Conversation Browser — Revealed") {
  AppRootView(
    store: PreviewFixtures.appStore(
      PreviewFixtures.appState(
        revealed: true,
        chat: PreviewFixtures.chatState(
          messages: PreviewFixtures.conversationMessages,
          title: "Current market value by fund"))),
    now: PreviewFixtures.now)
}

#Preview("Conversation Browser — Revealed — Dark") {
  AppRootView(
    store: PreviewFixtures.appStore(
      PreviewFixtures.appState(
        revealed: true,
        chat: PreviewFixtures.chatState(
          messages: PreviewFixtures.conversationMessages,
          title: "Current market value by fund"))),
    now: PreviewFixtures.now)
    .preferredColorScheme(.dark)
}
#endif
