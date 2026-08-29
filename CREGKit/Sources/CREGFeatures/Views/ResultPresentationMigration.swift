import AutoTableCharts
import ComposableArchitecture
import Foundation

enum ResultPresentationMigrationOutcome: Equatable {
  case retained(ResultPresentationPreference?)
  case messageMissing
}

typealias ResultPresentationMigrationHandler = (
  ResultPresentationPreference, ResultPresentationPreference
) -> ResultPresentationMigrationOutcome

enum ResultPresentationPreferenceReconciliation: Equatable {
  case unchanged
  case retained(ResultPresentationPreference?)
  case messageMissing
}

/// Exact-mark row IDs index one result revision. Keeping selection and
/// provenance in one value prevents either half from outliving the other.
struct ResultChartSelectionState {
  private let selection: AutoChartSelection<Int>
  private let resultFingerprint: String

  init(
    selection: AutoChartSelection<Int>,
    resultFingerprint: String
  ) {
    self.selection = selection
    self.resultFingerprint = resultFingerprint
  }

  func selection(for currentResultFingerprint: String) -> AutoChartSelection<Int>? {
    resultFingerprint == currentResultFingerprint ? selection : nil
  }

  func isStale(comparedTo currentResultFingerprint: String) -> Bool {
    resultFingerprint != currentResultFingerprint
  }

  func isInvalidated(
    by update: ResultPresentationAnalysisUpdate,
    currentResultFingerprint: String
  ) -> Bool {
    guard !isStale(comparedTo: currentResultFingerprint) else { return true }
    return update.invalidatesChartSelection(selection.specificationID)
  }
}

enum ResultPresentationAnalysisUpdate: Equatable {
  case resolved(
    specificationID: AutoChartRecommendationID,
    preference: ResultPresentationPreferenceReconciliation)
  case unavailable

  var resolvedSpecificationID: AutoChartRecommendationID? {
    switch self {
    case .resolved(let specificationID, _): specificationID
    case .unavailable: nil
    }
  }

  var preferenceReconciliation: ResultPresentationPreferenceReconciliation {
    switch self {
    case .resolved(_, let preference): preference
    case .unavailable: .unchanged
    }
  }

  func invalidatesChartSelection(
    _ selectionSpecificationID: AutoChartSpecificationID?
  ) -> Bool {
    guard let selectionSpecificationID else { return false }
    switch self {
    case .resolved(let specificationID, _):
      return selectionSpecificationID != specificationID.specificationID
    case .unavailable:
      return true
    }
  }
}

/// Sends an automatic chart-ID migration and reports the preference that the
/// compare-and-set reducer actually retained. A missing message is distinct
/// from a retained automatic `nil` preference. Capturing the stable ID keeps
/// view callbacks from retaining an entire message or result-viewer item.
@MainActor
func resultPresentationMigrationHandler(
  store: StoreOf<ChatFeature>,
  messageID: UUID
) -> ResultPresentationMigrationHandler {
  { previous, updated in
    store.send(
      .resultPresentationMigrated(
        .init(
          messageID: messageID,
          previous: previous,
          updated: updated)))
    guard let message = store.messages[id: messageID] else {
      return .messageMissing
    }
    return .retained(message.resultPresentation)
  }
}

/// Shared analysis and compare-and-set reconciliation for the inline preview
/// and full-screen viewer. Each surface remains responsible only for applying
/// the returned presentation update to its own state model.
@MainActor
func analyzeResultPresentation(
  _ chart: ResultChartLoader,
  request: ResultChartLoader.Request,
  preference: ResultPresentationPreference?,
  migratePreference: ResultPresentationMigrationHandler,
  diagnostics: DiagnosticsClient = .noop
) async -> ResultPresentationAnalysisUpdate? {
  switch await chart.analyze(
    request,
    preferredSpecificationID: preference?.specificationID
  ) {
  case .resolved(let recommendation, let analysis, let defaultReason)?:
    recordChartResolutionDefault(
      defaultReason,
      diagnostics: diagnostics)
    guard
      let previous = preference,
      let migrated = ResultViewerLogic.migratedPreference(
        previous,
        resolvedSpecificationID: recommendation.id)
    else {
      return .resolved(
        specificationID: recommendation.id,
        preference: .unchanged)
    }

    switch migratePreference(previous, migrated) {
    case .retained(let authoritativePreference):
      switch analysis.resolve(authoritativePreference?.specificationID) {
      case .exact(let authoritative), .defaulted(let authoritative, _):
        return .resolved(
          specificationID: authoritative.id,
          preference: .retained(authoritativePreference))
      case .unavailable:
        // The outer resolution proves this immutable analysis has a chart, so
        // resolving another preference cannot become unavailable. Preserve the
        // committed reconciliation if that package invariant ever changes,
        // while retaining the chart the analysis already resolved.
        assertionFailure("A resolved chart analysis became unavailable.")
        return .resolved(
          specificationID: recommendation.id,
          preference: .retained(authoritativePreference))
      }
    case .messageMissing:
      return .resolved(
        specificationID: recommendation.id,
        preference: .messageMissing)
    }
  case .unavailable?:
    return .unavailable
  case nil:
    return nil
  }
}

private func recordChartResolutionDefault(
  _ reason: AutoChartRecommendationResolution.DefaultReason?,
  diagnostics: DiagnosticsClient
) {
  guard let reason else { return }
  switch reason {
  case .noPersistedPreference:
    return
  case .policyVersionChanged(let previous, let current):
    diagnostics.info(
      category: .pipeline,
      code: "chart_recommendation_policy_changed",
      summary: "A stored chart pin used an obsolete recommendation policy.",
      context: [
        "previous_policy": String(previous),
        "current_policy": String(current),
      ])
  case .specificationUnavailable:
    diagnostics.info(
      category: .pipeline,
      code: "chart_specification_unavailable",
      summary: "A stored chart pin was unavailable and the default chart was selected.")
  }
}
