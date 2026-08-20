import Foundation

enum HistoryStoreError: Error, Sendable {
  case conversationNotFound
  case messageNotFound
}

// MARK: - Test and degraded variants

extension HistoryClient {
  public static func noop() -> HistoryClient {
    HistoryClient(
      bootstrap: { [] },
      listConversations: { [] },
      createConversation: { id, startedAt in
        ConversationSummary(
          id: id, title: "", startedAt: startedAt, lastActivityAt: startedAt)
      },
      loadConversation: { id in
        ConversationSnapshot(
          summary: ConversationSummary(
            id: id, title: "",
            startedAt: Date(timeIntervalSince1970: 0),
            lastActivityAt: Date(timeIntervalSince1970: 0)))
      },
      renameConversation: { _, _ in },
      deleteConversation: { _ in },
      saveDraft: { _, _ in },
      setUnread: { _, _ in },
      search: { _ in [] },
      saveFeedback: { _, _ in },
      clearFeedback: { _, _ in },
      endTurnJournal: { _ in },
      appendMessage: { _, _ in },
      updateMessage: { _, _ in },
      updateResultPresentation: { _, _ in },
      appendEvents: { _, _, _ in },
      persistScopeDiagnosis: { _, _, _, _ in },
      persistUserTurn: { _, _, _, _ in },
      persistTerminalTurn: { _, _, _, _ in },
      exportJSONL: { _ in FileManager.default.temporaryDirectory },
      supportBundleSource: {
        SupportBundleSource(
          databaseSnapshotURL: FileManager.default.temporaryDirectory,
          conversationsJSON: Data("[]".utf8),
          messagesJSON: Data("[]".utf8),
          eventsJSONL: Data(),
          feedbackJSON: Data("[]".utf8),
          conversationCount: 0,
          messageCount: 0,
          eventLineCount: 0,
          feedbackCount: 0)
      },
      saveFollowUpBatch: { _, _ in },
      clearFollowUpBatch: { _ in }
    )
  }

  /// Keeps startup recoverable while ensuring every attempted history
  /// operation reaches the feature's diagnostics and presentation boundary.
  package static func unavailable(diagnostic: String) -> HistoryClient {
    let error = HistoryUnavailableError(diagnostic: diagnostic)
    return HistoryClient(
      bootstrap: { throw error },
      listConversations: { throw error },
      createConversation: { _, _ in throw error },
      loadConversation: { _ in throw error },
      renameConversation: { _, _ in throw error },
      deleteConversation: { _ in throw error },
      saveDraft: { _, _ in throw error },
      setUnread: { _, _ in throw error },
      search: { _ in throw error },
      saveFeedback: { _, _ in throw error },
      clearFeedback: { _, _ in throw error },
      endTurnJournal: { _ in throw error },
      appendMessage: { _, _ in throw error },
      updateMessage: { _, _ in throw error },
      updateResultPresentation: { _, _ in throw error },
      appendEvents: { _, _, _ in throw error },
      persistScopeDiagnosis: { _, _, _, _ in throw error },
      persistUserTurn: { _, _, _, _ in throw error },
      persistTerminalTurn: { _, _, _, _ in throw error },
      exportJSONL: { _ in throw error },
      supportBundleSource: { throw error },
      saveFollowUpBatch: { _, _ in throw error },
      clearFollowUpBatch: { _ in throw error }
    )
  }
}

private struct HistoryUnavailableError:
  CustomStringConvertible, LocalizedError, Sendable
{
  var diagnostic: String

  var description: String { diagnostic }
  var errorDescription: String? { diagnostic }
}
