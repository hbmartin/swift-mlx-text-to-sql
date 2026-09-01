import SwiftUI

/// Keeps the inline preview and full-screen viewer on one authoritative
/// presentation lifecycle. The task synchronizes provenance before analysis so
/// a fast warm-start cannot race the corresponding `onChange` callback.
private struct ResultPresentationLifecycleModifier: ViewModifier {
  let chart: ResultChartLoader
  let request: ResultChartLoader.Request
  let authoritativePreference: ResultPresentationPreference?
  let migratePreference: ResultPresentationMigrationHandler
  let diagnostics: DiagnosticsClient
  @Binding var presentationState: ResultPresentationState
  let willAnalyze: @MainActor () -> Void
  let didApplyAnalysis: @MainActor (ResultPresentationAnalysisUpdate) -> Void

  private var analysisTaskKey: ResultPresentationAnalysisTaskKey {
    chart.analysisTaskKey(
      requestKey: request.key,
      preference: authoritativePreference)
  }

  func body(content: Content) -> some View {
    content
      .onChange(of: authoritativePreference) { _, updatedPreference in
        presentationState.synchronize(
          with: updatedPreference,
          requestKey: request.key)
      }
      .onChange(of: request.key) { _, updatedRequestKey in
        chart.synchronizeRequest(updatedRequestKey)
        presentationState.synchronize(
          with: authoritativePreference,
          requestKey: updatedRequestKey)
      }
      .task(id: analysisTaskKey) {
        let requestKey = request.key
        presentationState.synchronize(
          with: authoritativePreference,
          requestKey: requestKey)
        willAnalyze()
        guard
          let update = await analyzeResultPresentation(
            chart,
            request: request,
            preference: authoritativePreference,
            migratePreference: migratePreference,
            diagnostics: diagnostics)
        else { return }
        guard
          presentationState.apply(
            update.preferenceReconciliation,
            requestKey: requestKey)
        else { return }
        didApplyAnalysis(update)
      }
  }
}

extension View {
  func resultPresentationLifecycle(
    chart: ResultChartLoader,
    request: ResultChartLoader.Request,
    authoritativePreference: ResultPresentationPreference?,
    presentationState: Binding<ResultPresentationState>,
    migratePreference: @escaping ResultPresentationMigrationHandler,
    diagnostics: DiagnosticsClient,
    willAnalyze: @escaping @MainActor () -> Void = {},
    didApplyAnalysis:
      @escaping @MainActor (
        ResultPresentationAnalysisUpdate
      ) -> Void = { _ in }
  ) -> some View {
    modifier(
      ResultPresentationLifecycleModifier(
        chart: chart,
        request: request,
        authoritativePreference: authoritativePreference,
        migratePreference: migratePreference,
        diagnostics: diagnostics,
        presentationState: presentationState,
        willAnalyze: willAnalyze,
        didApplyAnalysis: didApplyAnalysis))
  }
}
