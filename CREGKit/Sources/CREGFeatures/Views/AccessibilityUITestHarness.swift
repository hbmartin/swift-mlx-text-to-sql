import AutoTableCharts
import CREGCore
import CREGEngine
import ComposableArchitecture
import SwiftUI
import Synchronization

#if DEBUG
  /// DEBUG-only entry into deterministic, inert screens for accessibility UI
  /// audits. Release and Beta builds do not compile this path.
  struct AccessibilityUITestConfiguration: Equatable, Sendable {
    enum Scenario: String, CaseIterable, Sendable {
      case emptyChat = "empty-chat"
      case answeredChat = "answered-chat"
      case answeredChatHelpful = "answered-chat-helpful"
      case answeredChatReading = "answered-chat-reading"
      case longTranscriptSharing = "long-transcript-sharing"
      case conversationLoadFailure = "conversation-load-failure"
      case historyStoreUnavailable = "history-store-unavailable"
      case retryInspection = "retry-inspection"
      case supportBundleFallback = "support-bundle-fallback"
      case processingQueue = "processing-queue"
      case error
      case recovery
      case browser
      case settings
      case resultExplorer = "result-explorer"
      case resultPreviewIdentity = "result-preview-identity"
      case resultChartPreparation = "result-chart-preparation"
      case resultChartRecovery = "result-chart-recovery"
      case resultChartRejectedRetry = "result-chart-rejected-retry"
      case resultChartTerminalRecovery = "result-chart-terminal-recovery"
      case resultChartUnresolvedSelection = "result-chart-unresolved-selection"
      case transientBanners = "transient-banners"
      case conversationNotices = "conversation-notices"
      case retainedExport = "retained-export"
      case browserRefresh = "browser-refresh"
    }

    enum Request: Equatable, Sendable {
      case scenario(AccessibilityUITestConfiguration)
      case scenarioManifest
      case invalidConfiguration
    }

    static let scenarioEnvironmentKey = "CREG_UI_TEST_SCENARIO"
    static let dynamicTypeEnvironmentKey = "CREG_UI_TEST_DYNAMIC_TYPE"
    static let scenarioManifestEnvironmentKey =
      "CREG_UI_TEST_SCENARIO_MANIFEST"
    private static let environmentKeyPrefix = "CREG_UI_TEST_"

    static var scenarioManifest: String {
      Scenario.allCases.map(\.rawValue).joined(separator: "|")
    }

    var scenario: Scenario
    var dynamicTypeSize: DynamicTypeSize?

    static var currentRequest: Request? {
      request(environment: ProcessInfo.processInfo.environment)
    }

    static func request(environment: [String: String]) -> Request? {
      let knownKeys: Set<String> = [
        scenarioEnvironmentKey,
        dynamicTypeEnvironmentKey,
        scenarioManifestEnvironmentKey,
      ]
      let hasUnknownConfiguration = environment.contains { key, value in
        key.hasPrefix(environmentKeyPrefix)
          && !knownKeys.contains(key)
          && !isDisabledEnvironmentValue(value)
      }
      guard !hasUnknownConfiguration else { return .invalidConfiguration }

      let rawManifest = environment[scenarioManifestEnvironmentKey] ?? ""
      guard rawManifest.isEmpty || rawManifest == "0" || rawManifest == "1"
      else { return .invalidConfiguration }
      let manifestRequested = rawManifest == "1"

      let rawScenario = environment[scenarioEnvironmentKey] ?? ""
      let rawSize = environment[dynamicTypeEnvironmentKey] ?? ""
      guard !rawScenario.isEmpty else {
        guard rawSize.isEmpty else {
          return .invalidConfiguration
        }
        return manifestRequested ? .scenarioManifest : nil
      }
      guard let scenario = Scenario(rawValue: rawScenario)
      else { return .invalidConfiguration }

      let dynamicTypeSize: DynamicTypeSize?
      if !rawSize.isEmpty {
        guard let parsed = DynamicTypeSize.uiTestValue(rawSize) else {
          return .invalidConfiguration
        }
        dynamicTypeSize = parsed
      } else {
        dynamicTypeSize = nil
      }
      return .scenario(
        Self(
          scenario: scenario,
          dynamicTypeSize: dynamicTypeSize))
    }

    private static func isDisabledEnvironmentValue(_ value: String) -> Bool {
      value.isEmpty || value == "0"
    }
  }

  @MainActor
  private struct LongTranscriptSharingAccessibilityHarness: View {
    @State private var didComplete = false
    @State private var store = StoreOf<ChatFeature>(initialState: Self.initialState()) {
      BindingReducer()
    }

    private static func initialState() -> ChatFeature.State {
      var state = PreviewFixtures.answeredChatState()
      var originalAnswer = state.messages.removeLast()
      originalAnswer.id = UUID(uuidString: "00000000-0000-0000-0000-000000006099")!
      state.messages.append(originalAnswer)
      for index in 0..<24 {
        state.messages.append(
          ChatMessage(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 6000 + index))!,
            role: .user, body: .text("Later transcript question \(index + 1)."),
            createdAt: PreviewFixtures.now.addingTimeInterval(Double(index))))
      }
      return state
    }

    var body: some View {
      ChatView(
        store: store, chrome: PreviewFixtures.chrome,
        answerSharePresented: {
          guard !didComplete else { return }
          didComplete = true
          let fixture = PreviewFixtures.answeredChatState().messages.last!
          var completion = fixture
          completion.id = UUID(uuidString: "00000000-0000-0000-0000-000000006100")!
          if case .answer(let result, _, let sql, let notice) = completion.body {
            completion.body = .answer(
              result: result, narration: "Concurrent answer completed", sql: sql, notice: notice)
          }
          store.messages.append(completion)
        })
    }
  }

  @MainActor
  private struct ConversationLoadFailureAccessibilityHarness: View {
    let scenario: AccessibilityUITestConfiguration.Scenario
    @State private var store: StoreOf<AppFeature>
    private static let journalID = UUID(uuidString: "00000000-0000-4000-8000-000000006201")!

    init(scenario: AccessibilityUITestConfiguration.Scenario = .conversationLoadFailure) {
      self.scenario = scenario
      let initial = Self.initialState(scenario: scenario)
      let summary = ConversationSummary(id: PreviewFixtures.chatState().conversationID,
        title: "Saved conversation", startedAt: PreviewFixtures.now, lastActivityAt: PreviewFixtures.now)
      var history = HistoryClient.noop()
      history.bootstrap = { [summary] }
      switch scenario {
      case .historyStoreUnavailable:
        let attempts = Mutex(0)
        let healthy = history
        history = .recoverable(open: {
          let attempt = attempts.withLock { $0 += 1; return $0 }
          if attempt == 1 { throw PreviewHistoryError() }
          return healthy
        })
      case .retryInspection:
        history.claimTurnRetry = { _, _, _, _ in nil }
        history.loadConversation = { _ in
          // Cancellation settles this held read; a frozen clock keeps the
          // inspection timeout deterministic while the UI exercises Dismiss.
          try await Task.sleep(for: .seconds(30))
          return ConversationSnapshot(summary: summary)
        }
      default:
        history.loadConversation = { _ in throw PreviewHistoryError() }
      }
      let controlledHistory = history
      _store = State(initialValue: Store(initialState: initial) { AppFeature() } withDependencies: {
        $0.historyClient = controlledHistory
        $0.fmStatus = FMStatusClient(availability: { .available })
        $0.haptics = .noop
        $0.diagnostics = .noop
        $0.continuousClock = TestClock()
      })
    }

    private static func initialState(scenario: AccessibilityUITestConfiguration.Scenario) -> AppFeature.State {
      var state = AppFeature.State(debugModelIdentity: nil, launchBenchmarkQuestion: nil)
      state.modelReadiness = .ready
      state.didRequestPreparationJournalInspection = true
      state.didHandlePreparationJournalInspection = true
      if scenario == .retryInspection {
        var chat = PreviewFixtures.chatState()
        let message = ChatMessage(id: UUID(uuidString: "00000000-0000-4000-8000-000000006202")!,
          role: .user, body: .text("What is my portfolio worth?"), createdAt: PreviewFixtures.now)
        chat.messages.append(message)
        chat.interruptedTurns.append(InterruptedTurn(question: message.previewText,
          interruptedAt: message.createdAt, journalID: journalID, executionID: message.id,
          status: .knownInterruption))
        state.chat = chat
        state.conversations.append(ConversationSummary(id: chat.conversationID,
          title: chat.title, startedAt: PreviewFixtures.now, lastActivityAt: PreviewFixtures.now))
        state.historySummaryPhase = .loaded
      }
      return state
    }

    var body: some View {
      AppRootView(store: store, now: PreviewFixtures.now)
        .task {
          if scenario == .retryInspection {
            store.send(.chat(.delegate(.retryInterruptedTurnFor(Self.journalID))))
          }
        }
    }

    private struct PreviewHistoryError: Error {}
  }

  private struct SupportBundleFallbackAccessibilityHarness: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isPresented = true
    var body: some View {
      Color.clear.sheet(isPresented: $isPresented) {
        SupportBundleFallbackView(
          url: URL(fileURLWithPath: "/tmp/creg-preview-support.zip"), done: { isPresented = false }
        )
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        .accessibilityIdentifier("ui-test-support-bundle-fallback")
      }
    }
  }

  @MainActor
  struct AccessibilityScenarioView: View {
    let scenario: AccessibilityUITestConfiguration.Scenario
    @State private var resultExplorerPreference = ResultPresentationPreference.automatic

    @ViewBuilder
    var body: some View {
      switch scenario {
      case .emptyChat:
        ChatView(
          store: PreviewFixtures.chatStore(PreviewFixtures.chatState()),
          chrome: PreviewFixtures.chrome)

      case .answeredChat:
        ChatView(
          store: PreviewFixtures.chatStore(PreviewFixtures.answeredChatState()),
          chrome: PreviewFixtures.chrome)

      case .answeredChatHelpful:
        ChatView(
          store: PreviewFixtures.chatStore(PreviewFixtures.helpfulChatState()),
          chrome: PreviewFixtures.chrome)

      case .answeredChatReading:
        ChatView(
          store: PreviewFixtures.chatStore(readingChatState),
          chrome: PreviewFixtures.chrome)

      case .longTranscriptSharing:
        LongTranscriptSharingAccessibilityHarness()

      case .conversationLoadFailure:
        ConversationLoadFailureAccessibilityHarness()

      case .historyStoreUnavailable, .retryInspection:
        ConversationLoadFailureAccessibilityHarness(scenario: scenario)

      case .supportBundleFallback:
        SupportBundleFallbackAccessibilityHarness()

      case .resultExplorer:
        // This scenario has no transcript store, matching the preview harness.
        ResultViewerView(
          result: PreviewFixtures.fundValueResult,
          runtimeMode: .evaluated,
          textSize: .constant(.standard),
          sql: StarterQueryID.portfolioValueByFundV1.sql,
          question: StarterQueryID.portfolioValueByFundV1.question,
          preference: $resultExplorerPreference)

      case .resultPreviewIdentity:
        ResultPreviewIdentityAccessibilityHarness()

      case .resultChartRecovery:
        ResultChartTypeAccessibilityHarness(failureRetryability: true)

      case .resultChartRejectedRetry:
        ResultChartTypeAccessibilityHarness(
          failureRetryability: true,
          retryStarts: false)

      case .resultChartTerminalRecovery:
        ResultChartTypeAccessibilityHarness(failureRetryability: false)

      case .resultChartUnresolvedSelection:
        ResultChartTypeAccessibilityHarness(
          failureRetryability: nil,
          startsSelected: false)

      case .resultChartPreparation:
        ResultChartPreparationAccessibilityHarness()

      case .processingQueue:
        ChatView(
          store: PreviewFixtures.chatStore(PreviewFixtures.processingChatState()),
          chrome: PreviewFixtures.chrome)

      case .error:
        NoticesAccessibilityHarness(scenario: .error)

      case .recovery:
        NoticesAccessibilityHarness(scenario: .recovery)

      case .browser:
        AppRootView(
          store: PreviewFixtures.appStore(
            PreviewFixtures.appState(
              revealed: true,
              chat: PreviewFixtures.answeredChatState())),
          now: PreviewFixtures.now)

      case .settings:
        SettingsView(
          store: PreviewFixtures.appStore(PreviewFixtures.settingsState()))

      case .conversationNotices, .retainedExport, .browserRefresh:
        NoticesAccessibilityHarness(scenario: scenario)

      case .transientBanners:
        AppRootView(
          store: PreviewFixtures.appStore(
            PreviewFixtures.appState(
              revealed: false,
              chat: PreviewFixtures.answeredChatState())),
          now: PreviewFixtures.now)
      }
    }

    private var readingChatState: ChatFeature.State {
      var state = PreviewFixtures.helpfulChatState()
      state.readAloud = .init(messageID: PreviewFixtures.id("2"), phase: .playing)
      return state
    }

    private var errorChat: some View {
      var chrome = PreviewFixtures.chrome
      chrome.presentedFailure = PreviewFixtures.presentationFailure
      return ChatView(
        store: PreviewFixtures.chatStore(PreviewFixtures.answeredChatState()),
        chrome: chrome)
    }
  }

  @MainActor
  struct NoticesAccessibilityHarness: View {
    @State private var store: StoreOf<AppFeature>
    init(scenario: AccessibilityUITestConfiguration.Scenario = .conversationNotices) {
      var initial = PreviewFixtures.appState(revealed: scenario == .browserRefresh,
        chat: scenario == .recovery ? PreviewFixtures.recoveryChatState() : PreviewFixtures.answeredChatState())
      initial.historyStoreAvailability = .available
      initial.historySummaryPhase = .loaded
      initial.launchBenchmarkQuestion = nil
      initial.didRequestPreparationJournalInspection = true
      initial.didHandlePreparationJournalInspection = true
      let id = initial.chat!.conversationID
      if scenario == .error || scenario == .conversationNotices {
        for index in 0..<(scenario == .error ? 1 : 6) {
          initial.storeFailure(PreviewFixtures.presentationFailure, owner: .historySummaries(UInt64(index)))
        }
      }
      if scenario == .conversationNotices {
        initial.chat?.interruptedTurns = PreviewFixtures.recoveryChatState().interruptedTurns
        initial.chat?.correctionContext = PreviewFixtures.recoveryChatState().correctionContext
      }
      if scenario == .retainedExport || scenario == .conversationNotices {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("creg-conversation-preview-\(UUID()).jsonl")
        try? Data("{}\n".utf8).write(to: url)
        initial.conversationExports[id] = .init(conversationID: id, requestID: PreviewFixtures.id("9"), phase: .ready(url))
      }
      if scenario == .browserRefresh {
        initial.historySummaryPhase = .failed(1)
        initial.storeFailure(.history(operation: .summaryLoad, error: NSError(domain: "Preview.History", code: 1)),
          owner: .historySummaries(1))
      }
      let summaries = Array(initial.conversations)
      var history = HistoryClient.noop()
      history.bootstrap = { try await Task.sleep(for: .milliseconds(300)); return summaries }
      let controlledHistory = history
      _store = State(initialValue: Store(initialState: initial) { AppFeature() } withDependencies: {
        $0.historyClient = controlledHistory
        $0.fmStatus = FMStatusClient(availability: { .available })
        $0.haptics = .noop
        $0.diagnostics = .noop
        $0.continuousClock = ContinuousClock()
      })
    }
    var body: some View { AppRootView(store: store, now: PreviewFixtures.now) }
  }

  @MainActor
  private struct ResultPreviewIdentityAccessibilityHarness: View {
    @State private var showsReplacement = false
    @State private var preference = ResultPresentationPreference.automatic

    private let replacement = QueryResult(
      columns: ["note"],
      rows: [
        [.text("First replacement")],
        [.text("Second replacement")],
        [.text("Third replacement")],
      ])

    var body: some View {
      VStack(spacing: 12) {
        Button("Replace result") { showsReplacement = true }
          .accessibilityIdentifier("replace-preview-result")
        ResultPreviewView(
          messageID: PreviewFixtures.id("9"),
          resultFingerprint: showsReplacement
            ? "preview-replacement" : "preview-original",
          result: showsReplacement
            ? replacement : PreviewFixtures.fundValueResult,
          sql: showsReplacement
            ? "SELECT note FROM properties"
            : StarterQueryID.portfolioValueByFundV1.sql,
          question: showsReplacement
            ? "Show notes" : StarterQueryID.portfolioValueByFundV1.question,
          preference: preference,
          setPreference: { preference = $0 },
          migratePreference: { _, updated in
            preference = updated
            return .migrated(updated)
          },
          open: {})
        Spacer(minLength: 0)
      }
      .padding()
    }
  }

  @MainActor
  private struct ResultChartPreparationAccessibilityHarness: View {
    var body: some View {
      ResultChartExplorerContainer(
        recommendation: PreviewFixtures.ChartPreparation.recommendation
      ) {
        ResultChartExplorerPreparationView(
          recommendation: PreviewFixtures.ChartPreparation.recommendation)
      }
    }
  }

  @MainActor
  private struct ResultChartTypeAccessibilityHarness: View {
    private static let chartTypeRecommendations = [
      AutoChartRecommendation(
        specification: .bar(category: "fund", measure: "value"),
        score: 1,
        rationale: []),
      AutoChartRecommendation(
        specification: .rankedDot(category: "fund", measure: "value"),
        score: 0.9,
        rationale: []),
    ]
    private static let chartTypeCatalog = AutoChartRecommendationCatalog(
      featured: chartTypeRecommendations,
      cataloged: chartTypeRecommendations)
    private static let chartTypeOptions = resultChartPickerOptions(
      catalog: chartTypeCatalog,
      selectedRecommendation: chartTypeRecommendations.first)

    let failureRetryability: Bool?
    let retryStarts: Bool
    @State private var actionFeedback = "No recovery action"
    @State private var keepTableSelectionCount = 0
    @State private var selectedChartTypeID: AutoChartRecommendationID?
    @State private var preference: ResultPresentationPreference

    init(
      failureRetryability: Bool?,
      startsSelected: Bool = true,
      retryStarts: Bool = true
    ) {
      self.failureRetryability = failureRetryability
      self.retryStarts = retryStarts
      let selectedID = startsSelected ? Self.chartTypeOptions.first?.id : nil
      _selectedChartTypeID = State(
        initialValue: selectedID)
      _preference = State(
        initialValue: selectedID.map {
          ResultPresentationPreference.chart(.specific($0))
        } ?? .automatic)
    }

    private var retryAvailable: Bool {
      failureRetryability == true
    }

    private var showsChartTypeMenu: Bool {
      ResultViewerLogic.shouldShowChartTypeMenu(
        optionCount: Self.chartTypeOptions.count,
        requestedMode: .chart,
        hasFailure: failureRetryability != nil)
    }

    private func selectChartType(_ id: AutoChartRecommendationID) {
      let label = Self.chartTypeOptions.first(where: { $0.id == id })?.label
        ?? "Chart type"
      let intent = ResultViewerLogic.chartTypeSelectionIntent(
        id,
        currentlySelectedID: selectedChartTypeID,
        currentPreference: preference,
        failureRetryability: failureRetryability)
      switch intent {
      case .none:
        return
      case .persist(let updated):
        preference = updated
        selectedChartTypeID = id
        actionFeedback = "\(label) selected"
      case .retryChart(let updated):
        guard retryStarts else {
          actionFeedback = "Chart retry unavailable"
          return
        }
        if let updated { preference = updated }
        selectedChartTypeID = id
        actionFeedback = updated == nil
          ? "\(label) selected again" : "\(label) selected"
      }
    }

    var body: some View {
      VStack(spacing: 8) {
        if failureRetryability != nil {
          ResultChartRecoveryControls(
            spacing: 12,
            keepTable: {
              keepTableSelectionCount += 1
              actionFeedback =
                keepTableSelectionCount == 1
                ? "Keep Table selected" : "Keep Table selected again"
            },
            retryChart:
              retryAvailable
              ? { actionFeedback = "Retry Chart selected" } : nil
          )
          .padding(.horizontal)
          .accessibilityIdentifier("result-chart-recovery")
        }
        if showsChartTypeMenu {
          Menu {
            resultChartTypeMenuContent(
              selectedID: selectedChartTypeID,
              options: Self.chartTypeOptions,
              allowsReselection: retryAvailable,
              select: selectChartType)
          } label: {
            Label("Chart type", systemImage: "chart.xyaxis.line")
          }
          .accessibilityIdentifier("result-chart-type-retry")
        }
        Text(actionFeedback)
          .font(.caption2)
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @MainActor
  struct AccessibilityUITestRootView: View {
    let configuration: AccessibilityUITestConfiguration

    var body: some View {
      ZStack(alignment: .topLeading) {
        AccessibilityScenarioView(scenario: configuration.scenario)
        Color.clear
          .frame(width: 1, height: 1)
          .accessibilityElement()
          .accessibilityLabel("UI test scenario")
          .accessibilityIdentifier("ui-test-\(configuration.scenario.rawValue)")
          .allowsHitTesting(false)
      }
      .cregDynamicTypeSize(configuration.dynamicTypeSize)
    }
  }

  @MainActor
  struct AccessibilityUITestScenarioManifestView: View {
    var body: some View {
      Text(AccessibilityUITestConfiguration.scenarioManifest)
        .accessibilityIdentifier("ui-test-scenario-manifest")
    }
  }

  @MainActor
  struct AccessibilityUITestInvalidConfigurationView: View {
    var body: some View {
      Text("Invalid accessibility UI test configuration")
        .accessibilityIdentifier("ui-test-invalid-configuration")
    }
  }

  extension DynamicTypeSize {
    fileprivate static func uiTestValue(_ value: String) -> Self? {
      switch value.lowercased() {
      case "large": .large
      case "xxlarge": .xxLarge
      case "xxxlarge": .xxxLarge
      case "ax1", "accessibility1": .accessibility1
      case "ax3", "accessibility3": .accessibility3
      case "ax4", "accessibility4": .accessibility4
      case "ax5", "accessibility5": .accessibility5
      default: nil
      }
    }
  }

  extension View {
    @ViewBuilder
    fileprivate func cregDynamicTypeSize(_ size: DynamicTypeSize?) -> some View {
      if let size {
        self.environment(\.dynamicTypeSize, size)
      } else {
        self
      }
    }
  }
#endif
