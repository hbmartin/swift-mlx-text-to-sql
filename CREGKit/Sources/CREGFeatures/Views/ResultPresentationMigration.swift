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

enum ResultPresentationAnalysisUpdate: Equatable {
  case resolved(
    specificationID: AutoChartRecommendationID,
    preference: ResultPresentationPreferenceReconciliation)
  case unavailable(preference: ResultPresentationPreferenceReconciliation)
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
  migratePreference: ResultPresentationMigrationHandler
) async -> ResultPresentationAnalysisUpdate? {
  switch await chart.analyze(
    request,
    preferredSpecificationID: preference?.specificationID
  ) {
  case .resolved(let recommendation, let analysis)?:
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
        // resolving another preference cannot become unavailable. If that
        // package invariant ever changes, keep availability and the committed
        // reconciliation as separate, internally consistent facts.
        return .unavailable(
          preference: .retained(authoritativePreference))
      }
    case .messageMissing:
      return .resolved(
        specificationID: recommendation.id,
        preference: .messageMissing)
    }
  case .unavailable?:
    return .unavailable(preference: .unchanged)
  case nil:
    return nil
  }
}
