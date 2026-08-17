import CREGFeatures
import CREGInference
import ComposableArchitecture
import SwiftUI

/// The production composition root. The store is initialized at most once
/// and only after the feature shell has admitted the live-device path.
public struct RootView: View {
  @MainActor
  private static let store = Store(initialState: AppFeature.State()) {
    AppFeature()
  } withDependencies: {
    $0.queryPipeline = LiveDependencies.pipeline
    $0.historyClient = LiveDependencies.history
    $0.modelPreparationEnvironment = ModelPreparationEnvironmentClient {
      ModelPreparationEnvironment.snapshot().merging(
        ModelRuntimeDiagnostics.deviceContext()
      ) { _, runtime in runtime }
    }
  }

  public init() {}

  public var body: some View {
    CREGFeatures.RootView(storeFactory: { Self.store })
  }
}
