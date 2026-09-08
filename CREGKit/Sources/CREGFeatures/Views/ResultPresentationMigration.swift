import AutoTableCharts
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
