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

    @Test func zeroValuesAreUnsetForEveryKnownKey() {
      let liveRoot = AccessibilityUITestConfiguration.request(environment: [
        AccessibilityUITestConfiguration.scenarioEnvironmentKey: "0",
        AccessibilityUITestConfiguration.dynamicTypeEnvironmentKey: "0",
        AccessibilityUITestConfiguration.scenarioManifestEnvironmentKey: "0",
      ])
      let manifest = AccessibilityUITestConfiguration.request(environment: [
        AccessibilityUITestConfiguration.scenarioEnvironmentKey: "0",
        AccessibilityUITestConfiguration.dynamicTypeEnvironmentKey: "0",
        AccessibilityUITestConfiguration.scenarioManifestEnvironmentKey: "1",
      ])
      let scenario = AccessibilityUITestConfiguration.request(environment: [
        AccessibilityUITestConfiguration.scenarioEnvironmentKey: "settings",
        AccessibilityUITestConfiguration.dynamicTypeEnvironmentKey: "0",
        AccessibilityUITestConfiguration.scenarioManifestEnvironmentKey: "0",
      ])
      let empty = AccessibilityUITestConfiguration.request(environment: [
        AccessibilityUITestConfiguration.scenarioEnvironmentKey: "",
        AccessibilityUITestConfiguration.dynamicTypeEnvironmentKey: "",
        AccessibilityUITestConfiguration.scenarioManifestEnvironmentKey: "0",
      ])

      #expect(liveRoot == nil)
      #expect(manifest == .scenarioManifest)
      #expect(
        scenario
          == .scenario(
            AccessibilityUITestConfiguration(
              scenario: .settings,
              dynamicTypeSize: nil)))
      #expect(empty == nil)
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

    @Test func unsetUnknownUITestNamespaceConfigurationRequestsTheLiveRoot() {
      let unset = AccessibilityUITestConfiguration.request(environment: [
        "CREG_UI_TEST_FUTURE_OPTION": "0"
      ])

      #expect(unset == nil)
    }
  }
#endif
