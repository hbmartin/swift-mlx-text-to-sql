import AutoTableCharts
import ComposableArchitecture
import Foundation

enum ResultPresentationMigrationOutcome: Equatable {
  case migrated(ResultPresentationPreference)
  case retained(ResultPresentationPreference?)
  case messageMissing
}

typealias ResultPresentationMigrationHandler = (
  ResultPresentationPreference, ResultPresentationPreference
) -> ResultPresentationMigrationOutcome

enum ResultPresentationPreferenceReconciliation: Equatable {
  case unchanged
  case retained(ResultPresentationPreference?)
  /// The migration callback returned an unchanged stale preference. The store
  /// remains authoritative, but views use this resolvable preference for any
  /// subsequent explicit user write instead of persisting the dead pin again.
  case stalled(ResultPresentationPreference)
  case messageMissing
}

/// Inputs that can change which recommendation an existing analysis resolves.
/// Presentation mode is deliberately excluded: switching Chart/Table does not
/// require cancelling or repeating chart analysis.
struct ResultPresentationAnalysisTaskKey: Hashable {
  var chartRequest: ResultChartLoader.Request.Key
  var preferredSpecificationID: AutoChartRecommendationID?
}

/// Surface-local presentation policy with explicit provenance. Reconciled and
/// optimistic preferences remain useful while the parent still supplies the
/// preceding value, but can never cross into a replacement result request.
struct ResultPresentationState: Equatable {
  private(set) var preference: ResultPresentationPreference?
  private var requestKey: ResultChartLoader.Request.Key
  private var synchronizedInputPreference: ResultPresentationPreference?

  init(
    preference: ResultPresentationPreference?,
    requestKey: ResultChartLoader.Request.Key
  ) {
    self.preference = preference
    self.requestKey = requestKey
    self.synchronizedInputPreference = preference
  }

  /// Returns the authoritative input immediately when SwiftUI has rebuilt the
  /// view but has not yet delivered its change callback to local state.
  func effectivePreference(
    authoritativePreference: ResultPresentationPreference?,
    requestKey: ResultChartLoader.Request.Key
  ) -> ResultPresentationPreference? {
    guard requestKey == self.requestKey else {
      return authoritativePreference
    }
    guard authoritativePreference == synchronizedInputPreference else {
      return authoritativePreference
    }
    return preference
  }

  mutating func synchronize(
    with authoritativePreference: ResultPresentationPreference?,
    requestKey: ResultChartLoader.Request.Key
  ) {
    guard requestKey == self.requestKey else {
      self.requestKey = requestKey
      synchronizedInputPreference = authoritativePreference
      preference = authoritativePreference
      return
    }
    guard authoritativePreference != synchronizedInputPreference else { return }
    synchronizedInputPreference = authoritativePreference
    preference = authoritativePreference
  }

  mutating func applyUserPreference(
    _ updated: ResultPresentationPreference,
    authoritativePreference: ResultPresentationPreference?,
    requestKey: ResultChartLoader.Request.Key
  ) {
    synchronize(
      with: authoritativePreference,
      requestKey: requestKey)
    preference = updated
  }

  mutating func apply(
    _ reconciliation: ResultPresentationPreferenceReconciliation,
    requestKey: ResultChartLoader.Request.Key
  ) {
    guard requestKey == self.requestKey else { return }
    switch reconciliation {
    case .retained(let authoritativePreference):
      preference = authoritativePreference
    case .stalled(let resolvedPreference):
      preference = resolvedPreference
    case .unchanged, .messageMissing:
      break
    }
  }
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

/// Attempts an automatic chart-ID migration with compare-and-set semantics.
/// A stale precondition returns the authoritative preference without sending,
/// and `.migrated` is returned only after the reducer retains the update. A
/// missing message remains distinct from a retained automatic `nil`
/// preference. Capturing the stable ID keeps view callbacks from retaining an
/// entire message or viewer item.
@MainActor
func resultPresentationMigrationHandler(
  store: StoreOf<ChatFeature>,
  messageID: UUID
) -> ResultPresentationMigrationHandler {
  { previous, updated in
    guard let message = store.messages[id: messageID] else {
      return .messageMissing
    }
    guard message.resultPresentation == previous else {
      return .retained(message.resultPresentation)
    }
    store.send(
      .resultPresentationMigrated(
        .init(
          messageID: messageID,
          previous: previous,
          updated: updated)))
    guard let message = store.messages[id: messageID] else {
      return .messageMissing
    }
    guard message.resultPresentation == updated else {
      return .retained(message.resultPresentation)
    }
    return .migrated(updated)
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
  diagnostics: DiagnosticsClient
) async -> ResultPresentationAnalysisUpdate? {
  switch await chart.analyze(
    request,
    preferredSpecificationID: preference?.specificationID
  ) {
  case .resolved(let recommendation, _, let defaultReason)?:
    var resolvedRecommendation = recommendation
    var resolvedDefaultReason = defaultReason
    var authoritativePreference = preference
    var reconciliation = ResultPresentationPreferenceReconciliation.unchanged
    var attemptedPreferences: Set<ResultPresentationPreference> = []

    while true {
      guard
        let previous = authoritativePreference,
        let migrated = ResultViewerLogic.migratedPreference(
          previous,
          resolvedSpecificationID: resolvedRecommendation.id)
      else {
        return .resolved(
          specificationID: resolvedRecommendation.id,
          preference: reconciliation)
      }
      guard attemptedPreferences.insert(previous).inserted else {
        diagnostics.record(DiagnosticEvent(
          level: .error,
          category: .presentation,
          code: "chart_preference_reconciliation_stalled",
          summary: "Chart preference reconciliation made no progress."))
        return .resolved(
          specificationID: resolvedRecommendation.id,
          preference: .stalled(migrated))
      }

      switch migratePreference(previous, migrated) {
      case .migrated(let retainedPreference):
        recordChartPreferenceMigration(
          resolvedDefaultReason,
          diagnostics: diagnostics)
        authoritativePreference = retainedPreference
        reconciliation = .retained(retainedPreference)
      case .retained(let retainedPreference):
        authoritativePreference = retainedPreference
        reconciliation = .retained(retainedPreference)
      case .messageMissing:
        return .resolved(
          specificationID: resolvedRecommendation.id,
          preference: .messageMissing)
      }

      switch chart.resolveLoadedRecommendation(
        preferredSpecificationID: authoritativePreference?.specificationID
      ) {
      case .resolved(let authoritative, _, let reason)?:
        resolvedRecommendation = authoritative
        resolvedDefaultReason = reason
      case .unavailable?:
        // The outer resolution proves this immutable analysis has a chart, so
        // resolving another preference cannot become unavailable. Preserve the
        // latest reconciliation if that package invariant ever changes,
        // while retaining the chart the analysis already resolved.
        assertionFailure("A resolved chart analysis became unavailable.")
        return .resolved(
          specificationID: resolvedRecommendation.id,
          preference: reconciliation)
      case nil:
        return nil
      }
    }
  case .unavailable?:
    return .unavailable
  case nil:
    return nil
  }
}

private func recordChartPreferenceMigration(
  _ reason: AutoChartRecommendationResolution.DefaultReason?,
  diagnostics: DiagnosticsClient
) {
  guard let reason else { return }
  switch reason {
  case .noPersistedPreference:
    return
  case .policyVersionChanged(let previous, let current):
    diagnostics.info(
      category: .presentation,
      code: "chart_recommendation_policy_changed",
      summary: "A stored chart pin used an obsolete recommendation policy.",
      context: [
        "previous_policy": String(previous),
        "current_policy": String(current),
      ])
  case .specificationUnavailable:
    diagnostics.info(
      category: .presentation,
      code: "chart_specification_unavailable",
      summary: "A stored chart pin was unavailable and the default chart was selected.")
  }
}
