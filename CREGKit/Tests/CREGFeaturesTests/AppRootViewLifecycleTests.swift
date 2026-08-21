import SwiftUI
import Testing

@testable import CREGFeatures

@MainActor
@Suite struct AppRootViewLifecycleTests {
  /// `.inactive` covers momentary interruptions (Control Center, an
  /// app-switcher peek, a system dialog) and must only gate new starts;
  /// only a real `.background` transition may tear down in-flight work.
  @Test func scenePhasesSeparateTheGateFromTheBackgroundTeardown() {
    #expect(AppRootView.lifecycleAction(for: .active) == .appBecameActive)
    #expect(AppRootView.lifecycleAction(for: .inactive) == .appBecameInactive)
    #expect(
      AppRootView.lifecycleAction(for: .background) == .appEnteredBackground)
  }
}
