import SwiftUI
import Testing

@testable import CREGFeatures

#if DEBUG
  @Suite struct AccessibilityUITestConfigurationTests {
    @Test func canonicalScenarioManifestRemainsExplicitlyReviewed() {
      let expectedScenarios = [
        "empty-chat",
        "answered-chat",
        "answered-chat-helpful",
        "answered-chat-reading",
        "long-transcript-sharing",
        "conversation-load-failure",
        "history-store-unavailable",
        "retry-inspection",
        "support-bundle-fallback",
        "support-bundle-dismissal",
        "processing-queue",
        "error",
        "recovery",
        "browser",
        "settings",
        "result-explorer",
        "result-preview-identity",
        "result-chart-preparation",
        "result-chart-recovery",
        "result-chart-rejected-retry",
        "result-chart-terminal-recovery",
        "result-chart-unresolved-selection",
        "transient-banners",
        "conversation-notices",
        "retained-export",
        "browser-refresh",
        "browser-performance",
        "apple-intelligence-disabled",
        "export-more",
        "browser-long-previews",
        "compact-jump",
      ]

      #expect(
        AccessibilityUITestConfiguration.Scenario.allCases.map(\.rawValue)
          == expectedScenarios)
      #expect(
        AccessibilityUITestConfiguration.scenarioManifest
          == expectedScenarios.joined(separator: "|"))
    }

    @Test func anExplicitScenarioTakesPrecedenceOverTheManifestFlag() {
      let request = AccessibilityUITestConfiguration.request(environment: [
        AccessibilityUITestConfiguration.scenarioEnvironmentKey: "settings",
        AccessibilityUITestConfiguration.dynamicTypeEnvironmentKey: "ax3",
        AccessibilityUITestConfiguration.scenarioManifestEnvironmentKey: "1",
      ])

      #expect(
        request
          == .scenario(
            AccessibilityUITestConfiguration(
              scenario: .settings,
              dynamicTypeSize: .accessibility3)))
    }

    @Test func manifestLaunchIgnoresEmptyScenarioAndDynamicTypeValues() {
      let request = AccessibilityUITestConfiguration.request(environment: [
        AccessibilityUITestConfiguration.scenarioEnvironmentKey: "",
        AccessibilityUITestConfiguration.dynamicTypeEnvironmentKey: "",
        AccessibilityUITestConfiguration.scenarioManifestEnvironmentKey: "1",
      ])

      #expect(request == .scenarioManifest)
    }

    @Test func noUITestEnvironmentRequestsTheLiveRoot() {
      #expect(
        AccessibilityUITestConfiguration.request(environment: [:]) == nil)
    }

    @Test func explicitScenarioAllowsAnUnsetDynamicType() {
      let request = AccessibilityUITestConfiguration.request(environment: [
        AccessibilityUITestConfiguration.scenarioEnvironmentKey: "settings",
        AccessibilityUITestConfiguration.dynamicTypeEnvironmentKey: "",
        AccessibilityUITestConfiguration.scenarioManifestEnvironmentKey: "0",
      ])

      #expect(
        request
          == .scenario(
            AccessibilityUITestConfiguration(
              scenario: .settings,
              dynamicTypeSize: nil)))
    }

    @Test func zeroDisablesOnlyBooleanEnvironmentValues() {
      let empty = AccessibilityUITestConfiguration.request(environment: [
        AccessibilityUITestConfiguration.scenarioEnvironmentKey: "",
        AccessibilityUITestConfiguration.dynamicTypeEnvironmentKey: "",
        AccessibilityUITestConfiguration.scenarioManifestEnvironmentKey: "0",
      ])

      #expect(empty == nil)
    }

    @Test func zeroFailsClosedForTypedStringEnvironmentValues() {
      let invalidScenario = AccessibilityUITestConfiguration.request(environment: [
        AccessibilityUITestConfiguration.scenarioEnvironmentKey: "0",
        AccessibilityUITestConfiguration.scenarioManifestEnvironmentKey: "0",
      ])
      let invalidDynamicType = AccessibilityUITestConfiguration.request(environment: [
        AccessibilityUITestConfiguration.scenarioEnvironmentKey: "settings",
        AccessibilityUITestConfiguration.dynamicTypeEnvironmentKey: "0",
        AccessibilityUITestConfiguration.scenarioManifestEnvironmentKey: "0",
      ])

      #expect(invalidScenario == .invalidConfiguration)
      #expect(invalidDynamicType == .invalidConfiguration)
    }

    @Test func malformedExplicitConfigurationNeverRequestsTheLiveRoot() {
      let invalidScenario = AccessibilityUITestConfiguration.request(environment: [
        AccessibilityUITestConfiguration.scenarioEnvironmentKey: "unknown"
      ])
      let invalidDynamicType = AccessibilityUITestConfiguration.request(environment: [
        AccessibilityUITestConfiguration.scenarioEnvironmentKey: "settings",
        AccessibilityUITestConfiguration.dynamicTypeEnvironmentKey: "enormous",
      ])

      #expect(invalidScenario == .invalidConfiguration)
      #expect(invalidDynamicType == .invalidConfiguration)
    }

    @Test func malformedExplicitConfigurationOutranksRequestedManifest() {
      let invalidScenario = AccessibilityUITestConfiguration.request(environment: [
        AccessibilityUITestConfiguration.scenarioEnvironmentKey: "unknown",
        AccessibilityUITestConfiguration.scenarioManifestEnvironmentKey: "1",
      ])
      let invalidDynamicType = AccessibilityUITestConfiguration.request(environment: [
        AccessibilityUITestConfiguration.scenarioEnvironmentKey: "settings",
        AccessibilityUITestConfiguration.dynamicTypeEnvironmentKey: "enormous",
        AccessibilityUITestConfiguration.scenarioManifestEnvironmentKey: "1",
      ])

      #expect(invalidScenario == .invalidConfiguration)
      #expect(invalidDynamicType == .invalidConfiguration)
    }

    @Test func nonemptyUnknownUITestNamespaceConfigurationFailsClosed() {
      let invalid = AccessibilityUITestConfiguration.request(environment: [
        "CREG_UI_TEST_FUTURE_OPTION": "enabled"
      ])

      #expect(invalid == .invalidConfiguration)
    }

    @Test func disabledUnknownUITestNamespaceConfigurationRequestsTheLiveRoot() {
      let disabled = AccessibilityUITestConfiguration.request(environment: [
        "CREG_UI_TEST_FUTURE_OPTION": "0"
      ])

      #expect(disabled == nil)
    }
    @Test(arguments: ["xxlarge", "xxxlarge", "ax4"])
    func largeTextRegressionSizesAreRecognized(size: String) {
      let request = AccessibilityUITestConfiguration.request(environment: [
        AccessibilityUITestConfiguration.scenarioEnvironmentKey: "answered-chat",
        AccessibilityUITestConfiguration.dynamicTypeEnvironmentKey: size,
      ])
      guard case .scenario(let configuration) = request else {
        Issue.record("Expected a recognized Dynamic Type fixture")
        return
      }
      let expected: DynamicTypeSize = size == "xxlarge" ? .xxLarge
        : (size == "xxxlarge" ? .xxxLarge : .accessibility4)
      #expect(configuration.dynamicTypeSize == expected)
    }

  }
#endif
