import AutoTableCharts
import AutoTableChartsUI
import CREGEngine
import ComposableArchitecture
import SwiftUI

#if DEBUG
private struct ConversationRecoveryPreviewFrame: View {
  let failure: FailurePresentation?
  var size: DynamicTypeSize = .large
  var isLoading = false
  var storeUnavailable = false
  var canRetryOpening = false
  var historyFailed = false

  static let loadFailure = FailurePresentation.history(
    operation: .load, error: NSError(domain: "Preview.History", code: 1))
  static let combinedFailure = FailurePresentation.history(
    operation: .delete, error: NSError(domain: "Preview.Deletion", code: 2))
    .combining(.history(operation: .messageSave, error: NSError(domain: "Preview.Write", code: 3)))

  var body: some View {
    ConversationUnavailableView(failure: failure, developerMode: false,
      dismissFailure: {}, openBrowser: {}, newChat: {},
      isLoading: isLoading, canCreate: !storeUnavailable,
      retryHistory: storeUnavailable || historyFailed || isLoading ? {} : nil,
      retryOpening: canRetryOpening ? {} : nil, historyIsLoading: isLoading)
      .environment(\.dynamicTypeSize, size)
      .frame(width: 370, height: 700)
      .background(CREGBrand.chatSurface)
  }
}

#Preview("Conversation Recovery — Loading — Standard", traits: .sizeThatFitsLayout) {
  ConversationRecoveryPreviewFrame(failure: nil, isLoading: true)
}
#Preview("Conversation Recovery — Loading — AX5", traits: .sizeThatFitsLayout) {
  ConversationRecoveryPreviewFrame(failure: nil, size: .accessibility5, isLoading: true)
}
#Preview("Conversation Recovery — Load Failure — Standard", traits: .sizeThatFitsLayout) {
  ConversationRecoveryPreviewFrame(failure: ConversationRecoveryPreviewFrame.loadFailure, canRetryOpening: true)
}
#Preview("Conversation Recovery — Load Failure — AX5", traits: .sizeThatFitsLayout) {
  ConversationRecoveryPreviewFrame(failure: ConversationRecoveryPreviewFrame.loadFailure, size: .accessibility5, canRetryOpening: true)
}
#Preview("Conversation Recovery — Combined Errors — Standard", traits: .sizeThatFitsLayout) {
  ConversationRecoveryPreviewFrame(failure: ConversationRecoveryPreviewFrame.combinedFailure)
}
#Preview("Conversation Recovery — Combined Errors — AX5", traits: .sizeThatFitsLayout) {
  ConversationRecoveryPreviewFrame(failure: ConversationRecoveryPreviewFrame.combinedFailure, size: .accessibility5)
}

#Preview("Conversation Recovery — Idle — AX5", traits: .sizeThatFitsLayout) {
  ConversationRecoveryPreviewFrame(failure: nil, size: .accessibility5, canRetryOpening: true)
}
#Preview("Conversation Recovery — Store Unavailable — AX5", traits: .sizeThatFitsLayout) {
  ConversationRecoveryPreviewFrame(failure: .history(operation: .load,
    error: HistoryStoreUnavailableError(diagnostic: "Preview open failure")),
    size: .accessibility5, storeUnavailable: true)
}
#Preview("Interrupted Retry — Checking — AX5", traits: .sizeThatFitsLayout) {
  InterruptedTurnBanner(interrupted: PreviewFixtures.recoveryChatState().interruptedTurn!,
    retryInspecting: true, askAgain: {}, dismiss: {})
    .environment(\.dynamicTypeSize, .accessibility5).padding()
}
#Preview("Conversation Recovery — Summary Failure — AX5", traits: .sizeThatFitsLayout) {
  ConversationRecoveryPreviewFrame(failure: .history(operation: .summaryLoad,
    error: NSError(domain: "Preview.History", code: 1)), size: .accessibility5, historyFailed: true)
}

@MainActor
private enum NoticesPreviewFixture {
  static var chrome: ChatChrome {
    var chrome = PreviewFixtures.chrome
    chrome.ownedFailures = (0..<4).map { .init(owner: .historySummaries(UInt64($0)), failure: PreviewFixtures.presentationFailure) }
    chrome.exportPhase = .ready(URL(fileURLWithPath: "/tmp/creg-conversation-preview.jsonl"))
    return chrome
  }
}

#Preview("Conversation notices — Compact — Standard") {
  NoticesAccessibilityHarness()
}
#Preview("Conversation notices — Compact — AX5 landscape") {
  NoticesAccessibilityHarness().environment(\.dynamicTypeSize, .accessibility5)
    .frame(width: 852, height: 393)
}
#Preview("Conversation notices — Stacked content — AX5") {
  ChatNoticesContent(store: PreviewFixtures.chatStore(PreviewFixtures.recoveryChatState()),
    chrome: NoticesPreviewFixture.chrome).environment(\.dynamicTypeSize, .accessibility5)
}
#Preview("Conversation notices — Scrolling panel — AX5") {
  ConversationNoticesPanel(store: PreviewFixtures.chatStore(PreviewFixtures.recoveryChatState()),
    chrome: NoticesPreviewFixture.chrome, close: {}).environment(\.dynamicTypeSize, .accessibility5)
}
#Preview("Conversation notices — Retained export") {
  NoticesAccessibilityHarness(scenario: .retainedExport)
}

private struct AnswerActionsPreviewFrame: View {
  let width: CGFloat
  let size: DynamicTypeSize

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      actions(phase: nil)
      actions(phase: .playing)
      actions(phase: .paused)
    }
    .frame(width: width)
    .environment(\.dynamicTypeSize, size)
    .padding(16)
    .background(CREGBrand.chatSurface)
  }

  private func actions(phase: ChatFeature.ReadAloudState.Phase?) -> some View {
    AnswerActionsRow(
      messageID: PreviewFixtures.id("2"),
      narration: PreviewFixtures.answeredNarration,
      result: PreviewFixtures.fundValueResult,
      runtimeMode: .evaluated,
      feedback: nil,
      readAloud: phase.map { .init(messageID: PreviewFixtures.id("2"), phase: $0) },
      store: PreviewFixtures.chatStore(PreviewFixtures.answeredChatState()))
  }
}

#Preview("Answer Actions — 343pt — Large", traits: .sizeThatFitsLayout) {
  AnswerActionsPreviewFrame(width: 343, size: .large)
}

#Preview("Answer Actions — 343pt — XXL", traits: .sizeThatFitsLayout) {
  AnswerActionsPreviewFrame(width: 343, size: .xxLarge)
}

#Preview("Answer Actions — 343pt — XXXL", traits: .sizeThatFitsLayout) {
  AnswerActionsPreviewFrame(width: 343, size: .xxxLarge)
}

#Preview("Answer Actions — 343pt — AX4", traits: .sizeThatFitsLayout) {
  AnswerActionsPreviewFrame(width: 343, size: .accessibility4)
}

#Preview("Answer Actions — 343pt — AX5", traits: .sizeThatFitsLayout) {
  AnswerActionsPreviewFrame(width: 343, size: .accessibility5)
}

#Preview("Answer Actions — 370pt — Large", traits: .sizeThatFitsLayout) {
  AnswerActionsPreviewFrame(width: 370, size: .large)
}

#Preview("Answer Actions — 370pt — XXL", traits: .sizeThatFitsLayout) {
  AnswerActionsPreviewFrame(width: 370, size: .xxLarge)
}

#Preview("Answer Actions — 370pt — XXXL", traits: .sizeThatFitsLayout) {
  AnswerActionsPreviewFrame(width: 370, size: .xxxLarge)
}

#Preview("Answer Actions — 370pt — AX4", traits: .sizeThatFitsLayout) {
  AnswerActionsPreviewFrame(width: 370, size: .accessibility4)
}

#Preview("Answer Actions — 370pt — AX5", traits: .sizeThatFitsLayout) {
  AnswerActionsPreviewFrame(width: 370, size: .accessibility5)
}

#Preview("Featured Starter — XXL", traits: .sizeThatFitsLayout) {
  EmptyChatState(isEnabled: true, submit: { _ in })
    .frame(width: 343)
    .environment(\.dynamicTypeSize, .xxLarge)
    .padding(16)
}

#Preview("Featured Starter — AX5", traits: .sizeThatFitsLayout) {
  EmptyChatState(isEnabled: true, submit: { _ in })
    .frame(width: 343)
    .environment(\.dynamicTypeSize, .accessibility5)
    .padding(16)
}

#Preview("Portfolio Date — Gregorian", traits: .sizeThatFitsLayout) {
  PortfolioSnapshotContextView()
    .environment(\.calendar, Calendar(identifier: .gregorian))
    .environment(\.locale, Locale(identifier: "en_US"))
    .padding(16)
}

#Preview("Portfolio Date — Buddhist", traits: .sizeThatFitsLayout) {
  PortfolioSnapshotContextView()
    .environment(\.calendar, Calendar(identifier: .buddhist))
    .environment(\.locale, Locale(identifier: "th_TH"))
    .padding(16)
}

#Preview("Portfolio Date — Japanese", traits: .sizeThatFitsLayout) {
  PortfolioSnapshotContextView()
    .environment(\.calendar, Calendar(identifier: .japanese))
    .environment(\.locale, Locale(identifier: "ja_JP"))
    .padding(16)
}

#Preview("Chart Value Rows — Funds — Standard", traits: .sizeThatFitsLayout) {
  SimpleChartValuesView(values: SimpleChartValues.rows(for: PreviewFixtures.fundValueResult)!)
    .frame(width: 323)
    .environment(\.dynamicTypeSize, .large)
    .padding(10)
}

#Preview("Chart Value Rows — Funds — AX5", traits: .sizeThatFitsLayout) {
  SimpleChartValuesView(values: SimpleChartValues.rows(for: PreviewFixtures.fundValueResult)!)
    .frame(width: 323)
    .environment(\.dynamicTypeSize, .accessibility5)
    .padding(10)
}

#Preview("Chart Value Rows — Dates — Standard", traits: .sizeThatFitsLayout) {
  SimpleChartValuesView(values: SimpleChartValues.rows(for: PreviewFixtures.datedValueResult)!)
    .frame(width: 323)
    .environment(\.dynamicTypeSize, .large)
    .padding(10)
}

#Preview("Chart Value Rows — Dates — AX5", traits: .sizeThatFitsLayout) {
  SimpleChartValuesView(values: SimpleChartValues.rows(for: PreviewFixtures.datedValueResult)!)
    .frame(width: 323)
    .environment(\.dynamicTypeSize, .accessibility5)
    .padding(10)
}

#Preview("More Actions — Selected Helpful — Light", traits: .sizeThatFitsLayout) {
  AnswerMoreActions(exportedAnswer: "Fixture answer", isHelpful: true, markHelpful: {}, stopReading: {})
    .frame(width: 343)
    .environment(\.dynamicTypeSize, .accessibility5)
    .preferredColorScheme(.light)
}

#Preview("Chart Appearance — Preparation — Light", traits: .sizeThatFitsLayout) {
  ResultChartPreparationView(
    recommendation: PreviewFixtures.ChartPreparation.recommendation,
    presentation: .preview(plotHeight: 180),
    formatters: CREGChartAdapter.formatters,
    textResolver: CREGChartAdapter.textResolver)
    .autoChartTheme(CREGChartAppearance.theme)
    .frame(width: 343)
    .preferredColorScheme(.light)
}

#Preview("Chart Appearance — Explorer — Light") {
  @Previewable @State var preference = ResultPresentationPreference.automatic
  ResultViewerView(
    result: PreviewFixtures.fundValueResult, runtimeMode: .evaluated,
    textSize: .constant(.standard), preference: $preference)
    .frame(width: 402, height: 874)
    .preferredColorScheme(.light)
}

#Preview("Chart Appearance — KPI — Light") {
  @Previewable @State var preference = ResultPresentationPreference.automatic
  ResultViewerView(
    result: QueryResult(columns: ["current_market_value"], rows: [[.integer(934_450_000)]]),
    runtimeMode: .evaluated, textSize: .constant(.standard), preference: $preference)
    .frame(width: 402, height: 874)
    .preferredColorScheme(.light)
}

#Preview("More Actions — Selected Helpful — Dark", traits: .sizeThatFitsLayout) {
  AnswerMoreActions(exportedAnswer: "Fixture answer", isHelpful: true, markHelpful: {}, stopReading: {})
    .frame(width: 343)
    .environment(\.dynamicTypeSize, .accessibility5)
    .preferredColorScheme(.dark)
}

#Preview("Chart Appearance — Preparation — Dark", traits: .sizeThatFitsLayout) {
  ResultChartPreparationView(
    recommendation: PreviewFixtures.ChartPreparation.recommendation,
    presentation: .preview(plotHeight: 180),
    formatters: CREGChartAdapter.formatters,
    textResolver: CREGChartAdapter.textResolver)
    .autoChartTheme(CREGChartAppearance.theme)
    .frame(width: 343)
    .preferredColorScheme(.dark)
}

#Preview("Chart Appearance — Explorer — Dark") {
  @Previewable @State var preference = ResultPresentationPreference.automatic
  ResultViewerView(
    result: PreviewFixtures.fundValueResult, runtimeMode: .evaluated,
    textSize: .constant(.standard), preference: $preference)
    .frame(width: 402, height: 874)
    .preferredColorScheme(.dark)
}

#Preview("Chart Appearance — KPI — Dark") {
  @Previewable @State var preference = ResultPresentationPreference.automatic
  ResultViewerView(
    result: QueryResult(columns: ["current_market_value"], rows: [[.integer(934_450_000)]]),
    runtimeMode: .evaluated, textSize: .constant(.standard), preference: $preference)
    .frame(width: 402, height: 874)
    .preferredColorScheme(.dark)
}

#Preview("Support Warning — AX5 Portrait") {
    SupportBundleFallbackView(url: URL(fileURLWithPath: "/tmp/creg-preview-support.zip"), done: {})
      .environment(\.dynamicTypeSize, .accessibility5)
      .frame(width: 402, height: 874)
  }

  #Preview("Support Warning — AX5 Landscape") {
    SupportBundleFallbackView(url: URL(fileURLWithPath: "/tmp/creg-preview-support.zip"), done: {})
      .environment(\.dynamicTypeSize, .accessibility5)
      .frame(width: 874, height: 402)
  }

#endif
