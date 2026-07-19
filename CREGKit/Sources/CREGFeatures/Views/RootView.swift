import ComposableArchitecture
import SwiftUI

/// The app's single entry point; owns the root store so the app shell
/// needs no TCA import.
public struct RootView: View {
  @MainActor
  static let store = Store(initialState: ChatFeature.State()) {
    ChatFeature()
  }

  public init() {}

  public var body: some View {
    NavigationStack {
      ChatView(store: Self.store)
    }
  }
}
