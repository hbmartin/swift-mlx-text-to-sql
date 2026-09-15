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

struct ResultPresentationMigrationSuggestion: Hashable {
  var analysisID: AutoChartAnalysisID
  var previous: ResultPresentationPreference
  var updated: ResultPresentationPreference
}

func resultPresentationMigrationSuggestion(
  analysis: AutoChartAnalysis<Int>?,
  preference: ResultPresentationPreference
) -> ResultPresentationMigrationSuggestion? {
  guard let analysis else { return nil }
  if let previousID = preference.specificationID {
    let catalog = analysis.cregRecommendationCatalog
    let replacementID =
      catalog?.cataloged.first {
        $0.specification.id == previousID.specificationID
      }?.id
      ?? catalog?.preferred.flatMap {
        $0.specification.id == previousID.specificationID ? $0.id : nil
      }
    let updated = ResultPresentationPreference(
      mode: preference.mode,
      specificationID: replacementID)
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
      guard
        let next = resultPresentationMigrationSuggestion(
          analysis: analysis,
          preference: authoritative)
      else { return }
      previous = next.previous
      updated = next.updated
    case .messageMissing:
      return
    }
  }
}

func resultChartPickerOptions(
  catalog: AutoChartRecommendationCatalog?,
  selectedID: AutoChartRecommendationID?,
  resolver: AutoChartTextResolver = .default
) -> [AutoChartPickerOption] {
  guard let catalog else { return [] }
  let allOptions = catalog.pickerOptions(resolver: resolver)
  let optionsByID = Dictionary(
    uniqueKeysWithValues: allOptions.map { ($0.id, $0) })
  let featured = catalog.featured.compactMap { optionsByID[$0.id] }
  guard let selectedID,
    let selectedRecommendation = catalog.recommendation(for: selectedID)
  else {
    return Array(featured.prefix(AutoChartRecommendationCatalog.maximumFeaturedCount))
  }
  let selected: AutoChartPickerOption
  if let cataloged = optionsByID[selectedID] {
    selected = cataloged
  } else {
    let singleOptionCatalog = AutoChartRecommendationCatalog(
      featured: [selectedRecommendation],
      cataloged: [selectedRecommendation])
    guard
      let preferred = singleOptionCatalog.pickerOptions(resolver: resolver).first
    else {
      return Array(
        featured.prefix(AutoChartRecommendationCatalog.maximumFeaturedCount))
    }
    selected = preferred
  }
  return [selected]
    + Array(
      featured.filter { $0.id != selectedID }
        .prefix(AutoChartRecommendationCatalog.maximumFeaturedCount - 1))
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
