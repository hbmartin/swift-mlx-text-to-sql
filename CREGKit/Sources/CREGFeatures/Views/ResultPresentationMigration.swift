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

/// Identity of one SwiftUI analysis task. Presentation mode is deliberately
/// projected out because switching Chart/Table does not repeat analysis;
/// explicit retries advance `attempt` without changing result identity.
struct ResultPresentationAnalysisTaskKey: Hashable {
  private var chartRequest: ResultChartLoader.Request.Key
  private var preferredSpecificationID: AutoChartRecommendationID?
  private var attempt: Int

  init(
    chartRequest: ResultChartLoader.Request.Key,
    preference: ResultPresentationPreference?,
    attempt: Int = 0
  ) {
    self.chartRequest = chartRequest
    self.preferredSpecificationID = preference?.specificationID
    self.attempt = attempt
  }
}

/// Surface-local presentation policy with explicit provenance. Reconciled and
/// optimistic preferences remain useful while the parent still supplies the
/// preceding value, but can never cross into a replacement result request.
struct ResultPresentationState: Equatable {
  private enum LocalOverride: Equatable {
    /// Reconciliation could not update the authoritative store, so explicit
    /// user writes must preserve this resolvable replacement instead of the
    /// dead specification that remains in the store.
    case stalled(specificationID: AutoChartRecommendationID?)
  }

  private var preference: ResultPresentationPreference?
  private var requestKey: ResultChartLoader.Request.Key
  private var synchronizedInputPreference: ResultPresentationPreference?
  private var localOverride: LocalOverride?

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
    return synchronizedValue(with: authoritativePreference).preference
  }

  /// The optional authoritative preference preserves automatic chart choice;
  /// callers that only need a visible mode use this single defaulting point.
  func requestedMode(
    authoritativePreference: ResultPresentationPreference?,
    requestKey: ResultChartLoader.Request.Key
  ) -> ResultPresentationPreference.Mode {
    Self.mode(
      for: effectivePreference(
        authoritativePreference: authoritativePreference,
        requestKey: requestKey))
  }

  mutating func synchronize(
    with authoritativePreference: ResultPresentationPreference?,
    requestKey: ResultChartLoader.Request.Key
  ) {
    guard
      !isSynchronized(
        with: authoritativePreference,
        requestKey: requestKey)
    else { return }
    let synchronized =
      requestKey == self.requestKey
      ? synchronizedValue(with: authoritativePreference)
      : (preference: authoritativePreference, localOverride: nil)
    recordSynchronization(
      authoritativePreference: authoritativePreference,
      requestKey: requestKey,
      localOverride: synchronized.localOverride)
    preference = synchronized.preference
  }

  mutating func applyUserPreference(
    _ updated: ResultPresentationPreference,
    authoritativePreference: ResultPresentationPreference?,
    requestKey: ResultChartLoader.Request.Key
  ) {
    if !isSynchronized(
      with: authoritativePreference,
      requestKey: requestKey)
    {
      recordSynchronization(
        authoritativePreference: authoritativePreference,
        requestKey: requestKey,
        localOverride: nil)
    }
    preference = updated
    localOverride = nil
  }

  @discardableResult
  mutating func apply(
    _ reconciliation: ResultPresentationPreferenceReconciliation,
    requestKey: ResultChartLoader.Request.Key
  ) -> Bool {
    guard requestKey == self.requestKey else { return false }
    switch reconciliation {
    case .retained(let authoritativePreference):
      preference = authoritativePreference
      localOverride = nil
    case .stalled(let resolvedPreference):
      preference = resolvedPreference
      localOverride = .stalled(
        specificationID: resolvedPreference.specificationID)
    case .unchanged, .messageMissing:
      break
    }
    return true
  }

  private func synchronizedValue(
    with authoritativePreference: ResultPresentationPreference?
  ) -> (
    preference: ResultPresentationPreference?,
    localOverride: LocalOverride?
  ) {
    guard authoritativePreference != synchronizedInputPreference else {
      return (preference, localOverride)
    }
    guard
      case .some(.stalled(let resolvedSpecificationID)) = localOverride,
      let previous = synchronizedInputPreference,
      let authoritativePreference,
      previous.specificationID == authoritativePreference.specificationID
    else {
      return (authoritativePreference, nil)
    }

    // A mode-only authoritative update does not make the old specification
    // resolvable. Adopt its mode while preserving the repaired local pin.
    return (
      ResultPresentationPreference(
        mode: authoritativePreference.mode,
        specificationID: resolvedSpecificationID),
      localOverride
    )
  }

  private static func mode(
    for preference: ResultPresentationPreference?
  ) -> ResultPresentationPreference.Mode {
    preference?.mode ?? .chart
  }

  private func isSynchronized(
    with authoritativePreference: ResultPresentationPreference?,
    requestKey: ResultChartLoader.Request.Key
  ) -> Bool {
    requestKey == self.requestKey
      && authoritativePreference == synchronizedInputPreference
  }

  private mutating func recordSynchronization(
    authoritativePreference: ResultPresentationPreference?,
    requestKey: ResultChartLoader.Request.Key,
    localOverride: LocalOverride?
  ) {
    self.requestKey = requestKey
    self.synchronizedInputPreference = authoritativePreference
    self.localOverride = localOverride
  }
}

struct ResultPresentationModeSelectionTransition {
  fileprivate enum Effect {
    case none
    case persist(ResultPresentationPreference)
    case retry
    case retryAndPersist(ResultPresentationPreference)
  }

  private let state: ResultPresentationState
  private let effect: Effect

  fileprivate init(
    state: ResultPresentationState,
    effect: Effect
  ) {
    self.state = state
    self.effect = effect
  }

  /// Commits local presentation state before exposing any retry or persistence
  /// effect. Keeping effects private makes that ordering part of this type's API
  /// rather than a convention repeated by SwiftUI call sites.
  @MainActor
  func commit(
    setState: (ResultPresentationState) -> Void,
    retryChart: () -> Void,
    persistPreference: (ResultPresentationPreference) -> Void
  ) {
    setState(state)
    switch effect {
    case .none:
      break
    case .persist(let updated):
      persistPreference(updated)
    case .retry:
      retryChart()
    case .retryAndPersist(let updated):
      retryChart()
      persistPreference(updated)
    }
  }
}

func resultPresentationModeSelectionTransition(
  _ selectedMode: ResultPresentationPreference.Mode,
  state: ResultPresentationState,
  authoritativePreference: ResultPresentationPreference?,
  requestKey: ResultChartLoader.Request.Key,
  chartFailed: Bool
) -> ResultPresentationModeSelectionTransition {
  var updatedState = state
  let currentPreference = updatedState.effectivePreference(
    authoritativePreference: authoritativePreference,
    requestKey: requestKey)
  let intent = ResultViewerLogic.modeSelectionIntent(
    selectedMode,
    requestedMode: currentPreference?.mode ?? .chart,
    preserving: currentPreference?.specificationID,
    preparationFailed: chartFailed
  )

  switch intent {
  case .none:
    updatedState.synchronize(
      with: authoritativePreference,
      requestKey: requestKey)
    return ResultPresentationModeSelectionTransition(
      state: updatedState,
      effect: .none)
  case .persist(let updated):
    updatedState.applyUserPreference(
      updated,
      authoritativePreference: authoritativePreference,
      requestKey: requestKey)
    return ResultPresentationModeSelectionTransition(
      state: updatedState,
      effect: .persist(updated))
  case .retryChart(nil):
    updatedState.synchronize(
      with: authoritativePreference,
      requestKey: requestKey)
    return ResultPresentationModeSelectionTransition(
      state: updatedState,
      effect: .retry)
  case .retryChart(.some(let updated)):
    updatedState.applyUserPreference(
      updated,
      authoritativePreference: authoritativePreference,
      requestKey: requestKey)
    return ResultPresentationModeSelectionTransition(
      state: updatedState,
      effect: .retryAndPersist(updated))
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
  guard !Task.isCancelled else { return nil }
  let resolution = await chart.analyze(
    request,
    preferredSpecificationID: preference?.specificationID
  )
  guard !Task.isCancelled else { return nil }
  switch resolution {
  case .resolved(let recommendation, _, let defaultReason)?:
    var resolvedRecommendation = recommendation
    var resolvedDefaultReason = defaultReason
    var authoritativePreference = preference
    var reconciliation = ResultPresentationPreferenceReconciliation.unchanged
    var attemptedPreferences: Set<ResultPresentationPreference> = []

    while true {
      guard !Task.isCancelled else { return nil }
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
        diagnostics.record(
          DiagnosticEvent(
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
      case .failed?:
        assertionFailure("A loaded analysis cannot become an analyzer failure.")
        return nil
      case nil:
        return nil
      }
    }
  case .unavailable?:
    return .unavailable
  case .failed(let details)?:
    diagnostics.record(
      DiagnosticEvent(
        level: .error,
        category: .presentation,
        code: "chart_analysis_failed",
        summary: "Chart analysis failed and can be retried.",
        details: details))
    return nil
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
