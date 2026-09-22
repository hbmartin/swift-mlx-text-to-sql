import SwiftUI
import Testing

@testable import CREGFeatures

@MainActor
@Suite struct AppRootViewLifecycleTests {
  /// `.inactive` is the safe GPU stop boundary when continued processing is
  /// not granted; `.background` also tears down lower-priority work.
  @Test func scenePhasesSeparateTheGateFromTheBackgroundTeardown() {
    #expect(AppRootView.lifecycleAction(for: .active) == .appBecameActive)
    #expect(AppRootView.lifecycleAction(for: .inactive) == .appBecameInactive)
    #expect(
      AppRootView.lifecycleAction(for: .background) == .appEnteredBackground)
  }
}
