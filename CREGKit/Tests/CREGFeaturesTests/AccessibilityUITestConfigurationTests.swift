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
        "result-chart-preparation",
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

    @Test func noUITestEnvironmentRequestsTheLiveRoot() {
      #expect(
        AccessibilityUITestConfiguration.request(environment: [:]) == nil)
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

    @Test func malformedExplicitConfigurationFallsBackToRequestedManifest() {
      let invalidScenario = AccessibilityUITestConfiguration.request(environment: [
        AccessibilityUITestConfiguration.scenarioEnvironmentKey: "unknown",
        AccessibilityUITestConfiguration.scenarioManifestEnvironmentKey: "1",
      ])
      let invalidDynamicType = AccessibilityUITestConfiguration.request(environment: [
        AccessibilityUITestConfiguration.scenarioEnvironmentKey: "settings",
        AccessibilityUITestConfiguration.dynamicTypeEnvironmentKey: "enormous",
        AccessibilityUITestConfiguration.scenarioManifestEnvironmentKey: "1",
      ])

      #expect(invalidScenario == .scenarioManifest)
      #expect(invalidDynamicType == .scenarioManifest)
    }
  }
#endif
