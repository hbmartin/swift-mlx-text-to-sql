import AutoTableCharts
import AutoTableChartsUI
import ComposableArchitecture
import Foundation

/// CREG keeps only optimistic compare-and-set persistence. Recommendation
/// replacement suggestions are supplied by AutoTableCharts.
enum ResultPresentationMigrationOutcome: Equatable {
  case migrated(ResultPresentationPreference)
  case retained(ResultPresentationPreference)
  case messageMissing
}

typealias ResultPresentationMigrationHandler = (
  ResultPresentationPreference, ResultPresentationPreference
) -> ResultPresentationMigrationOutcome

@MainActor
func applyResultPresentationPreference(
  _ updated: ResultPresentationPreference,
  chartOwner: CREGChartSessionOwner,
  persistPreference: (ResultPresentationPreference) -> Void,
  beforeSessionRestart: () -> Void = {}
) {
  chartOwner.setPreferenceIfNeeded(
    updated.packagePreference,
    beforeRestart: beforeSessionRestart)
  persistPreference(updated)
}

@MainActor
func applyResultPresentationModeSelection(
  _ intent: ResultViewerLogic.ModeSelectionIntent,
  chartOwner: CREGChartSessionOwner,
  persistPreference: (ResultPresentationPreference) -> Void,
  beforeSessionRestart: () -> Void = {}
) {
  switch intent {
  case .none:
    return
  case .persist(let updated):
    applyResultPresentationPreference(
      updated,
      chartOwner: chartOwner,
      persistPreference: persistPreference,
      beforeSessionRestart: beforeSessionRestart)
  case .retryChart(let updated):
    if let updated {
      chartOwner.retry(
        preference: updated.packagePreference,
        beforeRestart: beforeSessionRestart)
      persistPreference(updated)
    } else {
      chartOwner.retry(beforeRestart: beforeSessionRestart)
    }
  }
}

struct ResultPresentationMigrationSuggestion: Hashable {
  var analysisID: AutoChartAnalysisID
  var previous: ResultPresentationPreference
  var updated: ResultPresentationPreference
}

func resultPresentationMigrationSuggestion(
  analysis: AutoChartAnalysis<Int>?,
  preference: ResultPresentationPreference,
  resolution suppliedResolution: AutoChartPreferenceResolution? = nil
) -> ResultPresentationMigrationSuggestion? {
  guard let analysis else { return nil }
  let resolution = suppliedResolution
    ?? analysis.resolve(preference.packagePreference)
  guard let replacement = resolution.replacementPreference else { return nil }
  return ResultPresentationMigrationSuggestion(
    analysisID: analysis.id,
    previous: preference,
    updated: preference.applyingPackageReplacement(replacement))
}

/// Reconciles compare-and-set rejection immediately. A retained authoritative
/// preference can resolve to the same package replacement, so observing only
/// `replacementPreference` would never schedule another attempt.
@MainActor
func applyResultPresentationMigration(
  _ suggestion: ResultPresentationMigrationSuggestion,
  analysis: AutoChartAnalysis<Int>,
  chartOwner: CREGChartSessionOwner,
  beforeSessionRestart: () -> Void = {},
  migratePreference: ResultPresentationMigrationHandler
) {
  var previous = suggestion.previous
  var updated = suggestion.updated
  var visited: Set<ResultPresentationPreference> = []

  while visited.insert(previous).inserted {
    switch migratePreference(previous, updated) {
    case .migrated(let stored):
      chartOwner.setPreferenceIfNeeded(
        stored.packagePreference,
        beforeRestart: beforeSessionRestart)
      return
    case .retained(let authoritative):
      guard authoritative != previous else { return }
      chartOwner.setPreferenceIfNeeded(
        authoritative.packagePreference,
        beforeRestart: beforeSessionRestart)
      let resolution = analysis.resolve(authoritative.packagePreference)
      guard let replacement = resolution.replacementPreference else { return }
      previous = authoritative
      updated = authoritative.applyingPackageReplacement(replacement)
    case .messageMissing:
      return
    }
  }
}

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
        .init(messageID: messageID, previous: previous, updated: updated)))
    guard let message = store.messages[id: messageID] else {
      return .messageMissing
    }
    return message.resultPresentation == updated
      ? .migrated(updated)
      : .retained(message.resultPresentation)
  }
}
