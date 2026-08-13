import CREGEngine
import ComposableArchitecture
import Foundation
import SwiftUI

/// Deterministic, side-effect-free fixtures for the named design previews.
/// Fixed identifiers and dates, an inert reducer, and stub dependencies —
/// no pipeline, history store, network, or clock access.
enum PreviewFixtures {
  /// 2026-07-01 12:00:00 UTC — aligned with the Portfolio As-of Date.
  static let now = Date(timeIntervalSince1970: 1_782_907_200)

  static func id(_ digit: String) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-00000000000\(digit)")!
  }

  static let fundValueResult = QueryResult(
    columns: ["fund", "current_market_value"],
    rows: [
      [.text("Meridian Core Fund I"), .real(412_500_000)],
      [.text("Meridian Value-Add II"), .real(268_900_000)],
      [.text("Harborline Opportunistic"), .real(154_300_000)],
      [.text("Coastal Core-Plus III"), .real(98_750_000)],
    ],
    isTruncated: false,
    elapsedMicroseconds: 5_800)

  static let leaseListingResult: QueryResult = {
    let tenants = ["Northwind Logistics", "Cascade Legal Group", "Béa Café", "Atlas Data"]
    let properties = ["Harbor Point Tower", "Meridian Plaza", "Eastgate Industrial"]
    var rows: [[SQLValue]] = []
    for index in 1...48 {
      var row: [SQLValue] = []
      row.append(.integer(Int64(4000 + index)))
      row.append(.text(tenants[index % 4]))
      row.append(.text(properties[index % 3]))
      row.append(.text("Suite \(100 + index)"))
      row.append(.text("2026-\(String(format: "%02d", (index % 12) + 1))-15"))
      row.append(.text(index % 5 == 0 ? "Holdover" : "Active"))
      rows.append(row)
    }
    return QueryResult(
      columns: ["lease_id", "tenant", "property", "suite", "expiration_date", "status"],
      rows: rows,
      isTruncated: false,
      elapsedMicroseconds: 12_400)
  }()

  static let truncatedResult: QueryResult = {
    var rows: [[SQLValue]] = []
    for index in 0..<500 {
      var row: [SQLValue] = []
      row.append(.text("Property \(index % 40)"))
      row.append(.text("Tenant \(index)"))
      row.append(.real(Double(48_000 + index * 250)))
      rows.append(row)
    }
    return QueryResult(
      columns: ["property", "tenant", "annual_base_rent"],
      rows: rows,
      isTruncated: true,
      elapsedMicroseconds: 48_200)
  }()

  static var answeredTelemetry: TurnTelemetry {
    var telemetry = TurnTelemetry(
      originalQuestion: "What's the current market value of the portfolio by fund?")
    telemetry.queryOrigin = .freeForm
    telemetry.executionPath = .generated
    telemetry.gateDecision = .proceed
    var timings = StageTimings(totalMicroseconds: 8_432_000)
    timings.rewriteMicroseconds = 412_000
    timings.gateMicroseconds = 128_000
    timings.groundingMicroseconds = 61_000
    timings.votingMicroseconds = 22_000
    timings.narrationMicroseconds = 540_000
    telemetry.stageTimings = timings
    telemetry.generatedCount = 3
    telemetry.voteTrigger = "always"
    telemetry.voteOutcome = .consensus(
      resultDigest: "3f2a9c1d", agreement: 3, candidateCount: 3)
    telemetry.selectionReason = .majorityVote
    telemetry.confidence = .confirmed

    let model = ModelReference(
      key: "creg-sql-xiyansql-3b",
      repository: "creg/xiyansql-qwencoder-3b",
      revision: "aa11bb22cc33dd44",
      quantization: "4bit")
    telemetry.candidates = [
      CandidateID(rawValue: "anchor-0"),
      CandidateID(rawValue: "sample-1"),
      CandidateID(rawValue: "sample-2"),
    ].enumerated().map { index, candidateID in
      var candidate = CandidateTelemetry(
        request: SQLGenerationRequest(
          candidateID: candidateID,
          role: index == 0 ? .deterministicAnchor : .consistencySample(index: index),
          model: model,
          question: telemetry.originalQuestion,
          gcd: .on,
          temperature: index == 0 ? 0 : 0.6,
          seed: UInt64(41 + index)))
      candidate.sql = starterSQL
      candidate.tokensPerSecond = 38.2
      candidate.tokenCount = 61
      candidate.generationMicroseconds = 1_920_000
      candidate.executionMicroseconds = 5_800
      candidate.result = fundValueResult
      candidate.resultDigest = "3f2a9c1d"
      candidate.selected = index == 0
      return candidate
    }
    telemetry.selectedCandidateID = CandidateID(rawValue: "anchor-0")
    return telemetry
  }

  static let starterSQL = StarterQueryID.portfolioValueByFundV1.sql

  static let answeredNarration =
    "Across your four active funds, held properties total $934.5M in current market value, led by Meridian Core Fund I at $412.5M."

  static var conversationMessages: IdentifiedArrayOf<ChatMessage> {
    [
      ChatMessage(
        id: id("1"), role: .user,
        body: .text("What's the current market value of the portfolio by fund?"),
        createdAt: now.addingTimeInterval(-320)),
      ChatMessage(
        id: id("2"), role: .assistant,
        body: .answer(
          result: fundValueResult,
          narration: answeredNarration,
          sql: starterSQL,
          notice: nil),
        traceSteps: [
          "Understanding your question",
          "Checking the question is clear enough",
          "Generating the initial lookup",
          "Running the numbers",
          "Looking through the results (4 rows)",
          "Reading the question a few ways to be sure",
          "3 of 3 readings agreed",
          "Summarizing what I found",
        ],
        createdAt: now.addingTimeInterval(-300),
        devInfo: answeredTelemetry),
    ]
  }

  static func chatState(
    messages: IdentifiedArrayOf<ChatMessage> = [],
    title: String = ""
  ) -> ChatFeature.State {
    ChatFeature.State(
      conversationID: id("9"),
      title: title,
      messages: messages)
  }

  static func answeredChatState() -> ChatFeature.State {
    chatState(
      messages: conversationMessages,
      title: "Current market value by fund")
  }

  static func processingChatState() -> ChatFeature.State {
    var state = answeredChatState()
    state.processing = ChatFeature.ProcessingState(
      questionID: id("3"),
      question: "Which of those funds grew the most since acquisition?",
      startedAt: now.addingTimeInterval(-6),
      trace: [
        "Understanding your question",
        "Rephrasing your follow-up as a standalone question",
        "Generating the initial lookup",
      ],
      isTimelineExpanded: true)
    state.messages.append(
      ChatMessage(
        id: id("4"), role: .user,
        body: .text("Which of those funds grew the most since acquisition?"),
        createdAt: now.addingTimeInterval(-6)))
    state.queued = [
      QueuedQuestion(
        id: id("5"),
        conversationID: id("9"),
        question: "And what's the total debt service across them?",
        submittedAt: now.addingTimeInterval(-2))
    ]
    return state
  }

  static func recoveryChatState() -> ChatFeature.State {
    var state = answeredChatState()
    state.interruptedTurn = InterruptedTurn(
      question:
        "Compare every property’s debt maturity with its lease expiration schedule.",
      interruptedAt: now.addingTimeInterval(-30))
    state.correctionContext = ChatFeature.CorrectionContext(
      messageID: id("2"),
      answerNarration: answeredNarration)
    state.composerText = "The Harborline total should exclude sold properties."
    return state
  }

  static let presentationFailure = FailurePresentation(
    code: "preview_history_unavailable",
    title: "History unavailable",
    message:
      "CREG couldn’t load the saved conversation. You can continue, but changes may not be saved until the app reconnects to its local history store.",
    diagnostic: "Deterministic preview failure")

  static var summaries: [ConversationSummary] {
    [
      ConversationSummary(
        id: id("9"),
        title: "Current market value by fund",
        startedAt: now.addingTimeInterval(-320),
        lastActivityAt: now.addingTimeInterval(-300),
        latestMessagePreview: answeredNarration,
        messageCount: 2),
      ConversationSummary(
        id: id("8"),
        title: "Lease expirations this year",
        startedAt: now.addingTimeInterval(-86_400),
        lastActivityAt: now.addingTimeInterval(-7_200),
        latestMessagePreview:
          "12 active leases at held properties expire before July 2027.",
        isUnread: true,
        messageCount: 6),
      ConversationSummary(
        id: id("7"),
        title: "Debt maturities",
        startedAt: now.addingTimeInterval(-260_000),
        lastActivityAt: now.addingTimeInterval(-172_800),
        latestMessagePreview:
          "Three loans mature in the next 24 months, totaling $84.2M.",
        messageCount: 4),
    ]
  }

  static func appState(
    revealed: Bool,
    chat: ChatFeature.State
  ) -> AppFeature.State {
    var state = AppFeature.State(
      debugModelIdentity: nil, launchBenchmarkQuestion: nil)
    state.conversations = IdentifiedArray(uniqueElements: summaries)
    state.chat = chat
    state.isBrowserRevealed = revealed
    state.modelReadiness = .ready
    return state
  }

  /// Settings with the icon picker visible. `supportsAlternateIcons` is false
  /// by default because the system answers it, and the preview store never
  /// runs the effect that would.
  static func settingsState(
    icon: AppIconVariant = .midnight
  ) -> AppFeature.State {
    var state = AppFeature.State(
      debugModelIdentity: nil, launchBenchmarkQuestion: nil)
    state.isSettingsPresented = true
    state.supportsAlternateIcons = true
    state.appIcon = icon
    return state
  }

  static var chrome: ChatChrome {
    ChatChrome(
      modelReadiness: .ready,
      developerMode: false,
      resultTableTextSize: .constant(.standard),
      hasUnreadElsewhere: true,
      debugModelIdentity: nil,
      presentedFailure: nil,
      dismissFailure: {},
      retryPreparation: {})
  }

  /// An inert store: state renders, every action is ignored, and no
  /// dependency is ever touched.
  @MainActor
  static func chatStore(_ state: ChatFeature.State) -> StoreOf<ChatFeature> {
    Store(initialState: state) {}
  }

  @MainActor
  static func appStore(_ state: AppFeature.State) -> StoreOf<AppFeature> {
    Store(initialState: state) {}
  }
}

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

#Preview("Chat — Processing and Queue") {
  ChatView(
    store: PreviewFixtures.chatStore(PreviewFixtures.processingChatState()),
    chrome: PreviewFixtures.chrome)
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

#Preview("Result Viewer — Populated") {
  ResultViewerView(
    result: PreviewFixtures.leaseListingResult,
    runtimeMode: .evaluated,
    textSize: .constant(.standard))
    .frame(width: 402, height: 874)
}

#Preview("Result Viewer — Truncated — Dark") {
  ResultViewerView(
    result: PreviewFixtures.truncatedResult,
    runtimeMode: .evaluated,
    textSize: .constant(.standard))
    .frame(width: 402, height: 874)
    .preferredColorScheme(.dark)
}

#Preview("Result Viewer — Large Text — Selected Cell") {
  @Previewable @State var textSize = ResultTableTextSize.large
  ResultViewerView(
    result: PreviewFixtures.leaseListingResult,
    runtimeMode: .evaluated,
    textSize: $textSize,
    initialSelection: ResultCellSelection(row: 1, column: 2))
    .frame(width: 402, height: 874)
}

#Preview("Result Viewer — No Search Matches") {
  ResultViewerView(
    result: PreviewFixtures.leaseListingResult,
    runtimeMode: .evaluated,
    textSize: .constant(.standard),
    initialSearchText: "no such tenant")
    .frame(width: 402, height: 874)
}

#Preview("Result Viewer — Accessibility Dynamic Type") {
  ResultViewerView(
    result: PreviewFixtures.leaseListingResult,
    runtimeMode: .evaluated,
    textSize: .constant(.large),
    initialSelection: ResultCellSelection(row: 0, column: 1))
    .frame(width: 402, height: 874)
    .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("Settings — App Icon Picker") {
  SettingsView(store: PreviewFixtures.appStore(PreviewFixtures.settingsState()))
}

#Preview("Settings — App Icon Picker — Dark") {
  SettingsView(store: PreviewFixtures.appStore(PreviewFixtures.settingsState()))
    .preferredColorScheme(.dark)
}

#if DEBUG
  private struct AccessibilityPreviewFrame: View {
    let scenario: AccessibilityUITestConfiguration.Scenario
    let size: DynamicTypeSize

    var body: some View {
      AccessibilityScenarioView(scenario: scenario)
        .environment(\.dynamicTypeSize, size)
    }
  }

  #Preview("Chat — Empty — AX1") {
    AccessibilityPreviewFrame(scenario: .emptyChat, size: .accessibility1)
  }

  #Preview("Chat — Empty — AX3") {
    AccessibilityPreviewFrame(scenario: .emptyChat, size: .accessibility3)
  }

  #Preview("Chat — Empty — AX5") {
    AccessibilityPreviewFrame(scenario: .emptyChat, size: .accessibility5)
  }

  #Preview("Chat — Answered — AX1") {
    AccessibilityPreviewFrame(scenario: .answeredChat, size: .accessibility1)
  }

  #Preview("Chat — Answered — AX3") {
    AccessibilityPreviewFrame(scenario: .answeredChat, size: .accessibility3)
  }

  #Preview("Chat — Answered — AX5") {
    AccessibilityPreviewFrame(scenario: .answeredChat, size: .accessibility5)
  }

  #Preview("Chat — Answered — AX5 — Dark") {
    AccessibilityPreviewFrame(scenario: .answeredChat, size: .accessibility5)
      .preferredColorScheme(.dark)
  }

  #Preview("Chat — Processing and Queue — AX1") {
    AccessibilityPreviewFrame(scenario: .processingQueue, size: .accessibility1)
  }

  #Preview("Chat — Processing and Queue — AX3") {
    AccessibilityPreviewFrame(scenario: .processingQueue, size: .accessibility3)
  }

  #Preview("Chat — Processing and Queue — AX5") {
    AccessibilityPreviewFrame(scenario: .processingQueue, size: .accessibility5)
  }

  #Preview("Chat — Error — AX1") {
    AccessibilityPreviewFrame(scenario: .error, size: .accessibility1)
  }

  #Preview("Chat — Error — AX3") {
    AccessibilityPreviewFrame(scenario: .error, size: .accessibility3)
  }

  #Preview("Chat — Error — AX5") {
    AccessibilityPreviewFrame(scenario: .error, size: .accessibility5)
  }

  #Preview("Chat — Recovery — AX1") {
    AccessibilityPreviewFrame(scenario: .recovery, size: .accessibility1)
  }

  #Preview("Chat — Recovery — AX3") {
    AccessibilityPreviewFrame(scenario: .recovery, size: .accessibility3)
  }

  #Preview("Chat — Recovery — AX5") {
    AccessibilityPreviewFrame(scenario: .recovery, size: .accessibility5)
  }

  #Preview("Conversation Browser — AX1") {
    AccessibilityPreviewFrame(scenario: .browser, size: .accessibility1)
  }

  #Preview("Conversation Browser — AX3") {
    AccessibilityPreviewFrame(scenario: .browser, size: .accessibility3)
  }

  #Preview("Conversation Browser — AX5") {
    AccessibilityPreviewFrame(scenario: .browser, size: .accessibility5)
  }

  #Preview("Settings — App Icon Picker — AX1") {
    AccessibilityPreviewFrame(scenario: .settings, size: .accessibility1)
  }

  #Preview("Settings — App Icon Picker — AX3") {
    AccessibilityPreviewFrame(scenario: .settings, size: .accessibility3)
  }

  #Preview("Settings — App Icon Picker — AX5") {
    AccessibilityPreviewFrame(scenario: .settings, size: .accessibility5)
  }

  #Preview("Settings — App Icon Picker — AX5 — Dark") {
    AccessibilityPreviewFrame(scenario: .settings, size: .accessibility5)
      .preferredColorScheme(.dark)
  }

  #Preview("Transient Banners — AX1") {
    AccessibilityPreviewFrame(scenario: .transientBanners, size: .accessibility1)
  }

  #Preview("Transient Banners — AX3") {
    AccessibilityPreviewFrame(scenario: .transientBanners, size: .accessibility3)
  }

  #Preview("Transient Banners — AX5") {
    AccessibilityPreviewFrame(scenario: .transientBanners, size: .accessibility5)
  }

  #if os(iOS)
    #Preview("Chat — Answered — AX5 — Landscape") {
      AccessibilityPreviewFrame(scenario: .answeredChat, size: .accessibility5)
        .previewInterfaceOrientation(.landscapeLeft)
    }

    #Preview("Conversation Browser — AX5 — Landscape") {
      AccessibilityPreviewFrame(scenario: .browser, size: .accessibility5)
        .previewInterfaceOrientation(.landscapeLeft)
    }
  #endif
#endif
