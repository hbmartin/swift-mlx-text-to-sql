import AutoTableCharts
import CREGEngine
import SwiftUI

#if DEBUG
  /// DEBUG-only entry into deterministic, inert screens for accessibility UI
  /// audits. Release and Beta builds do not compile this path.
  struct AccessibilityUITestConfiguration: Equatable, Sendable {
    enum Scenario: String, CaseIterable, Sendable {
      case emptyChat = "empty-chat"
      case answeredChat = "answered-chat"
      case processingQueue = "processing-queue"
      case error
      case recovery
      case browser
      case settings
      case resultExplorer = "result-explorer"
      case resultPreviewIdentity = "result-preview-identity"
      case resultChartPreparation = "result-chart-preparation"
      case resultChartRecovery = "result-chart-recovery"
      case resultChartTerminalRecovery = "result-chart-terminal-recovery"
      case resultChartUnresolvedSelection = "result-chart-unresolved-selection"
      case transientBanners = "transient-banners"
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
        errorChat

      case .recovery:
        ChatView(
          store: PreviewFixtures.chatStore(PreviewFixtures.recoveryChatState()),
          chrome: PreviewFixtures.chrome)

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

      case .transientBanners:
        AppRootView(
          store: PreviewFixtures.appStore(
            PreviewFixtures.appState(
              revealed: false,
              chat: PreviewFixtures.answeredChatState())),
          now: PreviewFixtures.now)
      }
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
    @State private var actionFeedback = "No recovery action"
    @State private var keepTableSelectionCount = 0
    @State private var selectedChartTypeID: AutoChartRecommendationID?
    @State private var preference: ResultPresentationPreference

    init(failureRetryability: Bool?, startsSelected: Bool = true) {
      self.failureRetryability = failureRetryability
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
      case "ax1", "accessibility1": .accessibility1
      case "ax3", "accessibility3": .accessibility3
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
