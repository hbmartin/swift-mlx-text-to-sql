import ComposableArchitecture
import Foundation
import SwiftUI
import Testing

@testable import CREGFeatures

@MainActor
@Suite struct AppearancePreferenceTests {
  @Test func systemDefersToTheDeviceAndTheOverridesDoNot() {
    #expect(AppearancePreference.system.colorScheme == nil)
    #expect(AppearancePreference.light.colorScheme == .light)
    #expect(AppearancePreference.dark.colorScheme == .dark)
  }

  @Test func theDefaultIsToFollowTheSystem() {
    #expect(AppFeature.State().appearance == .system)
  }

  @Test func selectingAThemeAppliesItAndPersistsIt() async {
    let defaults = UserDefaults.inMemory
    let initialState = withDependencies {
      $0.defaultAppStorage = defaults
    } operation: {
      AppFeature.State()
    }
    let store = TestStore(initialState: initialState) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.appearanceSelected(.light))
    await store.finish()

    #expect(store.state.appearance == .light)
    #expect(
      defaults.string(forKey: AppearancePreference.storageKey) == "light")
  }

  /// A relaunch reads the override back rather than falling to `.system`,
  /// which is the whole point of persisting it.
  @Test func aStoredOverrideSurvivesStateReconstruction() {
    let defaults = UserDefaults.inMemory
    defaults.set("dark", forKey: AppearancePreference.storageKey)

    let state = withDependencies {
      $0.defaultAppStorage = defaults
    } operation: {
      AppFeature.State()
    }

    #expect(state.appearance == .dark)
  }

  @Test func reselectingTheCurrentThemeChangesNothing() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.appearanceSelected(.system))
    await store.finish()

    #expect(store.state.appearance == .system)
  }
}
