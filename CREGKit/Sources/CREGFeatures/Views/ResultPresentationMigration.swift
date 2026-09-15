import AutoTableCharts
import AutoTableChartsUI
import ComposableArchitecture
import Foundation

/// CREG owns persisted-preference migration and uses optimistic compare-and-set
/// persistence so a delayed migration cannot overwrite a newer user choice.
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
    onRestart: beforeSessionRestart)
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
      let didStartRetry = chartOwner.retry(
        preference: updated.packagePreference,
        beforeRestart: beforeSessionRestart)
      if didStartRetry {
        persistPreference(updated)
      }
    } else {
      chartOwner.retry(beforeRestart: beforeSessionRestart)
    }
  }
}

struct ResultPresentationMigrationSuggestion: Hashable, Sendable {
  var analysisID: AutoChartAnalysisID
  var previous: ResultPresentationPreference
  var updated: ResultPresentationPreference
}

struct ResultPresentationMigrationTaskID: Hashable, Sendable {
  var inputIdentity: CREGChartInputIdentity
  var analysisID: AutoChartAnalysisID
  var preference: ResultPresentationPreference
}

func resultPresentationMigrationSuggestion(
  analysis: AutoChartAnalysis<Int>?,
  preference: ResultPresentationPreference
) -> ResultPresentationMigrationSuggestion? {
  guard let analysis else { return nil }
  if let previousID = preference.specificationID {
    // Table keeps a latent chart ID, which the package's Table preference cannot
    // inspect. Resolve that ID as a shadow Chart choice, then preserve Table mode.
    let resolution = analysis.resolve(.chart(.specific(previousID)))
    guard let replacement = resolution.replacementPreference else { return nil }
    let reboundID: AutoChartRecommendationID? = {
      if case .chart(.specific(let id)) = replacement { return id }
      return nil
    }()
    let updated = preference.mode == .table
      ? ResultPresentationPreference(mode: .table, specificationID: reboundID)
      : preference.applyingPackageReplacement(replacement)
    guard updated != preference else { return nil }
    return ResultPresentationMigrationSuggestion(
      analysisID: analysis.id,
      previous: preference,
      updated: updated)
  }

  let resolution = analysis.resolve(preference.packagePreference)
  guard let replacement = resolution.replacementPreference else { return nil }
  return ResultPresentationMigrationSuggestion(
    analysisID: analysis.id,
    previous: preference,
    updated: preference.applyingPackageReplacement(replacement))
}

/// Preference resolution may validate an off-catalog chart against every row.
/// Keep that work off the SwiftUI body and the main actor.
func resultPresentationMigrationSuggestionOffMain(
  analysis: AutoChartAnalysis<Int>,
  preference: ResultPresentationPreference
) async -> ResultPresentationMigrationSuggestion? {
  let worker = Task.detached(priority: .utility) {
    resultPresentationMigrationSuggestion(
      analysis: analysis, preference: preference)
  }
  return await withTaskCancellationHandler(
    operation: { await worker.value },
    onCancel: { worker.cancel() })
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
) async {
  var previous = suggestion.previous
  var updated = suggestion.updated
  var visited: Set<ResultPresentationPreference> = []

  while visited.insert(previous).inserted {
    guard !Task.isCancelled else { return }
    switch migratePreference(previous, updated) {
    case .migrated(let stored):
      chartOwner.setPreferenceIfNeeded(
        stored.packagePreference,
        onRestart: beforeSessionRestart)
      return
    case .retained(let authoritative):
      chartOwner.setPreferenceIfNeeded(
        authoritative.packagePreference,
        onRestart: beforeSessionRestart)
      guard authoritative != previous else { return }
      guard let next = await resultPresentationMigrationSuggestionOffMain(
        analysis: analysis, preference: authoritative)
      else {
        return
      }
      guard !Task.isCancelled else { return }
      previous = next.previous
      updated = next.updated
    case .messageMissing:
      return
    }
  }
}

func resultChartPickerOptions(
  catalog: AutoChartRecommendationCatalog?,
  selectedRecommendation: AutoChartRecommendation?,
  resolver: AutoChartTextResolver = .default
) -> [AutoChartPickerOption] {
  guard let catalog else { return [] }
  let featured = Array(
    catalog.featured.prefix(AutoChartRecommendationCatalog.maximumFeaturedCount))
  guard let selectedRecommendation,
    !featured.contains(where: { $0.id == selectedRecommendation.id })
  else {
    return catalog.pickerOptions(for: featured, resolver: resolver)
  }
  return catalog.pickerOptions(
    for: Array(featured.prefix(AutoChartRecommendationCatalog.maximumFeaturedCount - 1))
      + [selectedRecommendation],
    resolver: resolver)
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
