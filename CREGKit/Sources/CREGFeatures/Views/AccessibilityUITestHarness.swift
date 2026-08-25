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
      case resultPreview = "result-preview"
      case resultExplorer = "result-explorer"
      case resultChartRecovery = "result-chart-recovery"
      case transientBanners = "transient-banners"
    }

    var scenario: Scenario
    var dynamicTypeSize: DynamicTypeSize?

    static var current: Self? {
      let environment = ProcessInfo.processInfo.environment
      guard
        let rawScenario = environment["CREG_UI_TEST_SCENARIO"],
        let scenario = Scenario(rawValue: rawScenario)
      else { return nil }

      let dynamicTypeSize: DynamicTypeSize?
      if let rawSize = environment["CREG_UI_TEST_DYNAMIC_TYPE"] {
        guard let parsed = DynamicTypeSize.uiTestValue(rawSize) else { return nil }
        dynamicTypeSize = parsed
      } else {
        dynamicTypeSize = nil
      }
      return Self(scenario: scenario, dynamicTypeSize: dynamicTypeSize)
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

      case .answeredChat, .resultPreview:
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
      AccessibilityScenarioView(scenario: configuration.scenario)
        .cregDynamicTypeSize(configuration.dynamicTypeSize)
        .accessibilityIdentifier("ui-test-\(configuration.scenario.rawValue)")
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
