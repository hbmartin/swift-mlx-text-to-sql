import CREGFeatures
import CREGInference
import ComposableArchitecture
import Combine
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The production composition root. The store is initialized at most once
/// and only after the feature shell has admitted the live-device path.
public struct RootView: View {
  @MainActor
  private static let store = Store(initialState: AppFeature.State()) {
    AppFeature()
  } withDependencies: {
    $0.queryPipeline = LiveDependencies.pipeline
    #if os(iOS)
    $0.backgroundTurn = BackgroundTurnCoordinator.shared.client
    #endif
    $0.historyClient = LiveDependencies.history
    $0.scopeDiagnosis = LiveDependencies.scopeDiagnosis
    $0.modelPreparationEnvironment = ModelPreparationEnvironmentClient {
      ModelPreparationEnvironment.snapshot().merging(
        ModelRuntimeDiagnostics.deviceContext()
      ) { _, runtime in runtime }
    }
  }

  public init() {}

  public var body: some View {
    #if os(iOS)
    CREGFeatures.RootView(storeFactory: { Self.store })
      .onReceive(
        NotificationCenter.default.publisher(for: .cregBackgroundTurnExpired)
          .receive(on: DispatchQueue.main)
      ) { notification in
        guard let id = notification.object as? UUID else { return }
        Self.store.send(.backgroundTurnExpired(executionID: id))
      }
      .onReceive(
        NotificationCenter.default.publisher(
          for: UIApplication.didReceiveMemoryWarningNotification)
      ) { _ in
        Self.store.send(.resourcePressure)
        Task {
          guard let context = await ModelRuntimeDiagnostics.relievePressureAsync()
          else { return }
          LiveDependencies.diagnostics.info(
            category: .model,
            code: "memory_pressure_cache_evicted",
            summary: "A memory warning evicted dispensable MLX cache.",
            context: context)
        }
      }
      .onReceive(
        NotificationCenter.default.publisher(
          for: ProcessInfo.thermalStateDidChangeNotification)
      ) { _ in
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical {
          Self.store.send(.thermalPressureBegan)
          Task {
            guard let context = await ModelRuntimeDiagnostics.relievePressureAsync()
            else { return }
            LiveDependencies.diagnostics.info(
              category: .model,
              code: "thermal_pressure_cache_evicted",
              summary: "Serious thermal pressure evicted dispensable MLX cache.",
              context: context)
          }
        } else {
          Self.store.send(.thermalPressureEnded)
        }
      }
    #else
    CREGFeatures.RootView(storeFactory: { Self.store })
    #endif
  }
}
