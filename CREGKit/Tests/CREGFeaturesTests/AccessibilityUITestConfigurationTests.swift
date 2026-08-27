import SwiftUI
import Testing

@testable import CREGFeatures

#if DEBUG
  @Suite struct AccessibilityUITestConfigurationTests {
    @Test func canonicalScenarioManifestRemainsExplicitlyReviewed() {
      let expectedScenarios = [
        "empty-chat",
        "answered-chat",
        "processing-queue",
        "error",
        "recovery",
        "browser",
        "settings",
        "result-preview",
        "result-explorer",
        "result-chart-recovery",
        "transient-banners",
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
  }
#endif
