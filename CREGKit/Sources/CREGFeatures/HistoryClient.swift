import CREGEngine
import Foundation
import GRDB

/// Persists Conversations, messages, drafts, Answer Feedback, the
/// interruption journal, and the per-message JSONL event stream in a
/// writable history.sqlite — separate from the read-only portfolio DB.
public struct HistoryClient: Sendable {
  /// Runs migrations and returns Recents summaries, newest activity first.
  public var bootstrap: @Sendable () async throws -> [ConversationSummary]
  public var listConversations: @Sendable () async throws -> [ConversationSummary]
  public var createConversation:
    @Sendable (_ id: UUID, _ startedAt: Date) async throws -> ConversationSummary
  public var loadConversation: @Sendable (_ id: UUID) async throws -> ConversationSnapshot
  /// Manual rename; wins over auto-titles thereafter.
  public var renameConversation: @Sendable (_ id: UUID, _ title: String) async throws -> Void
  public var deleteConversation: @Sendable (_ id: UUID) async throws -> Void
  public var saveDraft: @Sendable (_ id: UUID, _ draft: String) async throws -> Void
  public var setUnread: @Sendable (_ id: UUID, _ isUnread: Bool) async throws -> Void
  /// Local FTS over titles, user questions, and assistant narrations only.
  public var search: @Sendable (_ query: String) async throws -> [ConversationSearchHit]
  public var saveFeedback:
    @Sendable (_ conversationID: UUID, _ feedback: AnswerFeedback) async throws -> Void
  public var clearFeedback:
    @Sendable (_ conversationID: UUID, _ messageID: UUID) async throws -> Void
  public var endTurnJournal: @Sendable (_ conversationID: UUID) async throws -> Void
  public var appendMessage:
    @Sendable (_ conversationID: UUID, _ message: ChatMessage) async throws -> Void
  /// Replaces an existing body/telemetry payload without changing transcript
  /// position, while preserving any newer result-presentation preference. It
  /// inserts the supplied message when finalization beats its provisional
  /// append to the store.
  public var updateMessage:
    @Sendable (_ conversationID: UUID, _ message: ChatMessage) async throws -> Void
  /// Updates only a message's result-presentation preference. The supplied
  /// message is used as an insert fallback if its provisional append has not
  /// reached the store yet; an existing payload's body and telemetry are never
  /// replaced by this operation.
  public var updateResultPresentation:
    @Sendable (_ conversationID: UUID, _ message: ChatMessage) async throws -> Void
  public var appendEvents:
    @Sendable (_ conversationID: UUID, _ messageID: UUID, _ jsonLines: [String]) async throws ->
      Void
  /// Atomically enriches a persisted failed message and appends the matching
  /// post-render scope-diagnosis event.
  public var persistScopeDiagnosis:
    @Sendable (
      _ conversationID: UUID, _ messageID: UUID,
      _ verdict: ScopeVerdictRecord, _ jsonLine: String
    ) async throws -> Void
  /// Atomically appends a user message and opens its interruption journal.
  public var persistUserTurn:
    @Sendable (
      _ conversationID: UUID, _ message: ChatMessage, _ question: String,
      _ startedAt: Date
    ) async throws -> Void
  /// Atomically appends or finalizes an assistant message, records its events,
  /// and closes the interruption journal.
  public var persistTerminalTurn:
    @Sendable (
      _ conversationID: UUID, _ message: ChatMessage, _ replacesExisting: Bool,
      _ jsonLines: [String]
    ) async throws -> Void
  /// Writes the conversation's full JSONL event log to a temp file for export.
  public var exportJSONL: @Sendable (_ conversationID: UUID) async throws -> URL
  /// Gathers everything the Support Bundle includes from the history store.
  public var supportBundleSource: @Sendable () async throws -> SupportBundleSource
  public var saveFollowUpBatch:
    @Sendable (_ conversationID: UUID, _ batch: PreparedFollowUpBatch) async throws -> Void
  public var clearFollowUpBatch: @Sendable (_ conversationID: UUID) async throws -> Void
}

/// History-store contribution to a Support Bundle: a database snapshot plus
/// normalized JSON payloads, ready for the ZIP builder.
public struct SupportBundleSource: Sendable {
  public var databaseSnapshotURL: URL
  public var conversationsJSON: Data
  public var messagesJSON: Data
  public var eventsJSONL: Data
  public var feedbackJSON: Data
  public var followUpsJSON: Data
  public var conversationCount: Int
  public var messageCount: Int
  public var eventLineCount: Int
  public var feedbackCount: Int

  public init(
    databaseSnapshotURL: URL,
    conversationsJSON: Data,
    messagesJSON: Data,
    eventsJSONL: Data,
    feedbackJSON: Data,
    followUpsJSON: Data = Data("[]".utf8),
    conversationCount: Int,
    messageCount: Int,
    eventLineCount: Int,
    feedbackCount: Int
  ) {
    self.databaseSnapshotURL = databaseSnapshotURL
    self.conversationsJSON = conversationsJSON
    self.messagesJSON = messagesJSON
    self.eventsJSONL = eventsJSONL
    self.feedbackJSON = feedbackJSON
    self.followUpsJSON = followUpsJSON
    self.conversationCount = conversationCount
    self.messageCount = messageCount
    self.eventLineCount = eventLineCount
    self.feedbackCount = feedbackCount
  }
}

// MARK: - Live store

extension HistoryClient {
  public static func live(databaseURL: URL) throws -> HistoryClient {
    try FileManager.default.createDirectory(
      at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let store = try HistoryStore(databaseURL: databaseURL)
    return HistoryClient(
      bootstrap: { try await store.bootstrap() },
      listConversations: { try await store.listConversations() },
      createConversation: { try await store.createConversation(id: $0, startedAt: $1) },
      loadConversation: { try await store.loadConversation(id: $0) },
      renameConversation: { try await store.rename(id: $0, title: $1) },
      deleteConversation: { try await store.delete(id: $0) },
      saveDraft: { try await store.saveDraft(id: $0, draft: $1) },
      setUnread: { try await store.setUnread(id: $0, isUnread: $1) },
      search: { try await store.search(query: $0) },
      saveFeedback: { try await store.saveFeedback(conversationID: $0, feedback: $1) },
      clearFeedback: { try await store.clearFeedback(conversationID: $0, messageID: $1) },
      endTurnJournal: { try await store.endTurnJournal(conversationID: $0) },
      appendMessage: { try await store.appendMessage(conversationID: $0, message: $1) },
      updateMessage: { try await store.updateMessage(conversationID: $0, message: $1) },
      updateResultPresentation: {
        try await store.updateResultPresentation(conversationID: $0, message: $1)
      },
      appendEvents: {
        try await store.appendEvents(conversationID: $0, messageID: $1, lines: $2)
      },
      persistScopeDiagnosis: {
        try await store.persistScopeDiagnosis(
          conversationID: $0, messageID: $1, verdict: $2, line: $3)
      },
      persistUserTurn: {
        try await store.persistUserTurn(
          conversationID: $0, message: $1, question: $2, startedAt: $3)
      },
      persistTerminalTurn: {
        try await store.persistTerminalTurn(
          conversationID: $0, message: $1, replacesExisting: $2, lines: $3)
      },
      exportJSONL: { try await store.exportJSONL(conversationID: $0) },
      supportBundleSource: { try await store.supportBundleSource() },
      saveFollowUpBatch: {
        try await store.saveFollowUpBatch(conversationID: $0, batch: $1)
      },
      clearFollowUpBatch: { try await store.clearFollowUpBatch(conversationID: $0) }
    )
  }
}
