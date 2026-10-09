import ComposableArchitecture
import Foundation

extension AppFeature {
  func saveDraft(conversationID: UUID, draft: String, revision: UInt64) -> Effect<Action> {
    .run { send in
      do {
        try await messageUpdateQueue.saveDraft(conversationID: conversationID, revision: revision) {
          try await history.saveDraft(conversationID, draft)
        }
      } catch {
        await send(.operationFailed(.history(operation: .draftSave, error: error),
          owner: .conversationOperation(conversationID, .draft)))
      }
    }
  }
}
