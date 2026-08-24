import ComposableArchitecture
import Foundation

typealias ResultPresentationMigrationHandler = (
  ResultPresentationPreference, ResultPresentationPreference
) -> ResultPresentationPreference

/// Sends an automatic chart-ID migration and returns the preference that the
/// compare-and-set reducer actually retained. Capturing the stable ID keeps
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
    return store.messages[id: messageID]?.resultPresentation ?? previous
  }
}
