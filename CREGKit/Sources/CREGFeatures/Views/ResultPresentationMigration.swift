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
  session: AutoChartSession<Int>,
  migratePreference: ResultPresentationMigrationHandler
) {
  var previous = suggestion.previous
  var updated = suggestion.updated
  var visited: Set<ResultPresentationPreference> = []

  while visited.insert(previous).inserted {
    switch migratePreference(previous, updated) {
    case .migrated(let stored):
      if session.preference != stored.packagePreference {
        session.setPreference(stored.packagePreference)
      }
      return
    case .retained(let authoritative):
      guard authoritative != previous else { return }
      if session.preference != authoritative.packagePreference {
        session.setPreference(authoritative.packagePreference)
      }
      let resolution = analysis.resolve(authoritative.packagePreference)
      guard let replacement = resolution.replacementPreference else { return }
      previous = authoritative
      updated = authoritative.applyingPackageReplacement(replacement)
    case .messageMissing:
      return
    }
  }
}

/// Legacy helper retained only for pure table-filter tests; live views use the
/// package selection set directly.
struct ResultChartSelectionState {
  private let selectionValue: AutoChartSelection<Int>
  private let resultFingerprint: String

  init(selection: AutoChartSelection<Int>, resultFingerprint: String) {
    self.selectionValue = selection
    self.resultFingerprint = resultFingerprint
  }

  func selection(for currentResultFingerprint: String) -> AutoChartSelection<Int>? {
    currentResultFingerprint == resultFingerprint ? selectionValue : nil
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
