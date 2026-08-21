import SwiftUI
import Testing

@testable import CREGFeatures

@MainActor
@Suite struct AppRootViewLifecycleTests {
  @Test func activeAndInactiveScenePhasesDriveTheInferenceGate() {
    #expect(AppRootView.lifecycleAction(for: .active) == .appBecameActive)
    #expect(AppRootView.lifecycleAction(for: .inactive) == .appBecameInactive)
    #expect(AppRootView.lifecycleAction(for: .background) == .appBecameInactive)
  }
}
