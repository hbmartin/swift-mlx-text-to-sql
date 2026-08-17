import ComposableArchitecture
import Foundation
import Testing

@testable import CREGEngine
@testable import CREGFeatures

/// Records what the reducer asked the system to do, so the tests assert on the
/// call rather than on UIKit, which is unavailable under `swift test` on macOS.
private struct AppIconRecorder {
  // `LockIsolated` rather than `NSLock`, because the client's `select` closure
  // is async and `NSLock.lock()` is unavailable there.
  private let storage = LockIsolated<[AppIconVariant]>([])

  var selections: [AppIconVariant] { storage.value }

  func client(
    current: AppIconVariant = .midnight,
    supportsAlternates: Bool = true,
    failure: (any Error)? = nil
  ) -> AppIconClient {
    // Mirror the system: after a successful selection, `current` reports the
    // applied variant, so the reducer's confirming re-read sees it.
    let currentIcon = LockIsolated(current)
    return AppIconClient(
      current: { currentIcon.value },
      select: { variant in
        if let failure { throw failure }
        storage.withValue { $0.append(variant) }
        currentIcon.setValue(variant)
      },
      supportsAlternates: { supportsAlternates })
  }
}

private enum AppIconTestError: Error {
  case denied
}

@MainActor
@Suite struct AppIconTests {
  @Test func variantRoundTripsThroughTheSystemsAlternateName() {
    #expect(AppIconVariant.midnight.alternateName == nil)
    #expect(AppIconVariant.indigo.alternateName == "AppIconIndigo")
    #expect(AppIconVariant(alternateName: nil) == .midnight)
    #expect(AppIconVariant(alternateName: "AppIconMidnightGold") == .midnightGold)
    // An icon this build no longer ships must not strand the picker.
    #expect(AppIconVariant(alternateName: "AppIconRetired") == .midnight)
  }

  @Test func selectingAnIconAppliesItAndTellsTheSystem() async {
    let recorder = AppIconRecorder()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.appIcon = recorder.client()
    }
    store.exhaustivity = .off

    await store.send(.appIconSelected(.indigo))
    await store.finish()
    // A successful change re-reads the system icon, so the confirming
    // `appIconLoaded` must land without disturbing the applied selection.
    await store.skipReceivedActions()

    #expect(store.state.appIcon == .indigo)
    #expect(recorder.selections == [.indigo])
    #expect(store.state.presentedFailure == nil)
  }

  @Test func reselectingTheCurrentIconDoesNothing() async {
    let recorder = AppIconRecorder()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.appIcon = recorder.client()
    }
    store.exhaustivity = .off

    await store.send(.appIconSelected(.midnight))
    await store.finish()

    #expect(recorder.selections.isEmpty)
  }

  @Test func aRefusedIconChangeRollsBackAndSurfaces() async {
    let recorder = AppIconRecorder()
    var initialState = AppFeature.State()
    initialState.supportsAlternateIcons = true
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.appIcon = recorder.client(failure: AppIconTestError.denied)
    }
    store.exhaustivity = .off

    await store.send(.appIconSelected(.midnightGold))
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.appIcon == .midnight)
    #expect(store.state.supportsAlternateIcons)
    #expect(store.state.presentedFailure?.code == "app_icon_change_failed")
  }

  @Test func appearingHydratesTheIconFromTheSystem() async {
    let recorder = AppIconRecorder()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.appIcon = recorder.client(current: .midnightGold)
      $0.historyClient = .noop()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.onAppear)
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.appIcon == .midnightGold)
    #expect(store.state.supportsAlternateIcons)
  }

  @Test func selectingAnIconDropsAStaleAppearanceRead() async {
    let recorder = AppIconRecorder()
    let base = recorder.client()
    // The appearance read captures the pre-change icon, then parks while no
    // selection has landed, so the user's tap always races ahead of it. Only
    // the reducer cancelling that read keeps the stale value from reverting
    // the selection; the confirming re-read sees a selection and falls
    // through immediately.
    let client = AppIconClient(
      current: {
        let captured = await base.current()
        if recorder.selections.isEmpty {
          try? await Task.sleep(for: .seconds(5))
        }
        return captured
      },
      select: base.select,
      supportsAlternates: base.supportsAlternates)
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.appIcon = client
      $0.historyClient = .noop()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.onAppear)
    await store.send(.appIconSelected(.indigo))
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.appIcon == .indigo)
    #expect(recorder.selections == [.indigo])
  }
}
