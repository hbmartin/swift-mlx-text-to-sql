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
      case resultChartPreparation = "result-chart-preparation"
      case resultChartRecovery = "result-chart-recovery"
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

    @ViewBuilder
    var body: some View {
      switch scenario {
      case .emptyChat:
        ChatView(
          store: PreviewFixtures.chatStore(PreviewFixtures.chatState()),
          chrome: PreviewFixtures.chrome)

      case .answeredChat:
        answeredChat

      case .resultExplorer:
        // This scenario has no transcript store, matching the preview harness.
        ResultViewerView(
          result: PreviewFixtures.fundValueResult,
          runtimeMode: .evaluated,
          textSize: .constant(.standard),
          sql: StarterQueryID.portfolioValueByFundV1.sql,
          question: StarterQueryID.portfolioValueByFundV1.question)

      case .resultChartRecovery:
        ResultChartRecoveryAccessibilityHarness()

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

    private var answeredChat: some View {
      ChatView(
        store: PreviewFixtures.chatStore(PreviewFixtures.answeredChatState()),
        chrome: PreviewFixtures.chrome)
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
  private struct ResultChartRecoveryAccessibilityHarness: View {
    @State private var actionFeedback = "No recovery action"

    var body: some View {
      VStack(spacing: 8) {
        ResultChartRecoveryControls(
          spacing: 12,
          keepTable: { actionFeedback = "Keep Table selected" },
          retryChart: { actionFeedback = "Retry Chart selected" }
        )
        .padding(.horizontal)
        .accessibilityIdentifier("result-chart-recovery")
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
