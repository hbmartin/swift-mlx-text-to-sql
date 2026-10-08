import Foundation

enum HistoryStoreError: Error, Sendable {
  case conversationNotFound
  case messageNotFound
  /// The batch no longer owns its Conversation's suggestion slot.
  case staleFollowUpBatch
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
      createConversationWithDraft: { id, startedAt, _ in
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
      endTurnJournal: { _, _ in },
      markTurnInterrupted: { _, _, _ in },
      claimTurnRetry: { _, _, _, automatic in automatic ? 1 : 0 },
      declineAutoRetry: { _, _ in },
      releaseAutoRetryClaim: { _, _, _, _ in },
      appendMessage: { _, _ in },
      updateMessage: { _, _ in },
      updateResultPresentation: { _, _ in },
      appendEvents: { _, _, _ in },
      persistScopeDiagnosis: { _, _, _, _ in },
      persistUserTurn: { _, _, _, _, _ in },
      persistTerminalTurn: { _, _, _, _, _ in },
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
      clearFollowUpBatch: { _ in },
      acceptQuestion: { _, _ in }
    )
  }

}
