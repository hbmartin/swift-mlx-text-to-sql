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
  /// Records the active turn so termination can reopen it with Ask Again.
  public var beginTurnJournal:
    @Sendable (_ conversationID: UUID, _ question: String, _ startedAt: Date) async throws -> Void
  public var endTurnJournal: @Sendable (_ conversationID: UUID) async throws -> Void
  public var appendMessage:
    @Sendable (_ conversationID: UUID, _ message: ChatMessage) async throws -> Void
  public var appendEvents:
    @Sendable (_ conversationID: UUID, _ messageID: UUID, _ jsonLines: [String]) async throws -> Void
  /// Writes the conversation's full JSONL event log to a temp file for export.
  public var exportJSONL: @Sendable (_ conversationID: UUID) async throws -> URL
  /// Gathers everything the Support Bundle includes from the history store.
  public var supportBundleSource: @Sendable () async throws -> SupportBundleSource
}

/// History-store contribution to a Support Bundle: a database snapshot plus
/// normalized JSON payloads, ready for the ZIP builder.
public struct SupportBundleSource: Sendable {
  public var databaseSnapshotURL: URL
  public var conversationsJSON: Data
  public var messagesJSON: Data
  public var eventsJSONL: Data
  public var feedbackJSON: Data
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
      beginTurnJournal: {
        try await store.beginTurnJournal(conversationID: $0, question: $1, startedAt: $2)
      },
      endTurnJournal: { try await store.endTurnJournal(conversationID: $0) },
      appendMessage: { try await store.appendMessage(conversationID: $0, message: $1) },
      appendEvents: {
        try await store.appendEvents(conversationID: $0, messageID: $1, lines: $2)
      },
      exportJSONL: { try await store.exportJSONL(conversationID: $0) },
      supportBundleSource: { try await store.supportBundleSource() }
    )
  }
}

/// GRDB-backed implementation. All schema changes flow through the versioned
/// migrator; the pre-browser installed base (unversioned `conversation`/
/// `message`/`event` tables) is adopted by the baseline migration and rebuilt
/// with typed columns without losing a message.
final class HistoryStore: Sendable {
  private let queue: DatabaseQueue
  private static let encoder = JSONEncoder()
  private static let decoder = JSONDecoder()
  /// Auto-titles cap at this many characters (first user question).
  static let titleLimit = 80

  init(databaseURL: URL) throws {
    queue = try DatabaseQueue(path: databaseURL.path)
    try Self.migrator.migrate(queue)
  }

  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()

    // Adopts both fresh installs and the pre-browser schema, which created
    // these exact tables outside any migrator.
    migrator.registerMigration("v1-legacy-baseline") { db in
      try db.execute(
        sql: """
          CREATE TABLE IF NOT EXISTS conversation (
            id TEXT PRIMARY KEY,
            started_at TEXT NOT NULL
          );
          CREATE TABLE IF NOT EXISTS message (
            id TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL REFERENCES conversation(id),
            position INTEGER NOT NULL,
            payload TEXT NOT NULL
          );
          CREATE TABLE IF NOT EXISTS event (
            conversation_id TEXT NOT NULL,
            message_id TEXT NOT NULL,
            seq INTEGER NOT NULL,
            line TEXT NOT NULL
          );
          """)
    }

    migrator.registerMigration("v2-conversation-experience") { db in
      try db.execute(
        sql: """
          CREATE TABLE conversation_v2 (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL DEFAULT '',
            is_manually_titled INTEGER NOT NULL DEFAULT 0,
            started_at REAL NOT NULL,
            last_activity_at REAL NOT NULL,
            draft TEXT NOT NULL DEFAULT '',
            is_unread INTEGER NOT NULL DEFAULT 0
          );
          CREATE TABLE feedback (
            message_id TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL,
            verdict TEXT NOT NULL,
            correction TEXT,
            updated_at REAL NOT NULL
          );
          CREATE TABLE turn_journal (
            conversation_id TEXT PRIMARY KEY,
            question TEXT NOT NULL,
            started_at REAL NOT NULL
          );
          CREATE VIRTUAL TABLE search_index USING fts5(
            content,
            conversation_id UNINDEXED,
            message_id UNINDEXED,
            kind UNINDEXED,
            tokenize='unicode61 remove_diacritics 2'
          );
          CREATE INDEX message_conversation_position
            ON message(conversation_id, position);
          """)

      let legacyFormatter = DateFormatter()
      legacyFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
      legacyFormatter.timeZone = TimeZone(identifier: "UTC")
      legacyFormatter.locale = Locale(identifier: "en_US_POSIX")

      let conversations = try Row.fetchAll(
        db, sql: "SELECT id, started_at FROM conversation")
      for row in conversations {
        let id: String = row["id"]
        let startedAtText: String = row["started_at"]
        let startedAt =
          legacyFormatter.date(from: startedAtText)
          ?? ISO8601DateFormatter().date(from: startedAtText)
          ?? Date()

        let payloads = try Row.fetchAll(
          db,
          sql: """
            SELECT id, payload FROM message
            WHERE conversation_id = ? ORDER BY position
            """,
          arguments: [id])
        var title = ""
        var lastActivity = startedAt
        for messageRow in payloads {
          guard
            let message = try? decoder.decode(
              ChatMessage.self, from: Data((messageRow["payload"] as String).utf8))
          else { continue }
          lastActivity = max(lastActivity, message.createdAt)
          if title.isEmpty, message.role == .user, case .text = message.body {
            title = autoTitle(from: message.previewText)
          }
          if let entry = searchEntry(for: message) {
            try db.execute(
              sql: """
                INSERT INTO search_index (content, conversation_id, message_id, kind)
                VALUES (?, ?, ?, ?)
                """,
              arguments: [
                entry.content, id, message.id.uuidString, entry.kind,
              ])
          }
        }
        try db.execute(
          sql: """
            INSERT INTO conversation_v2
              (id, title, is_manually_titled, started_at, last_activity_at)
            VALUES (?, ?, 0, ?, ?)
            """,
          arguments: [
            id, title, startedAt.timeIntervalSince1970,
            lastActivity.timeIntervalSince1970,
          ])
        if !title.isEmpty {
          try insertTitleSearchRow(db, conversationID: id, title: title)
        }
      }
      try db.execute(
        sql: """
          DROP TABLE conversation;
          ALTER TABLE conversation_v2 RENAME TO conversation;
          """)
    }

    migrator.registerMigration("v3-feedback-runtime-mode") { db in
      try db.execute(
        sql: """
          ALTER TABLE feedback
            ADD COLUMN runtime_mode TEXT NOT NULL DEFAULT 'evaluated';
          ALTER TABLE feedback
            ADD COLUMN is_evaluated INTEGER NOT NULL DEFAULT 1;
          """)
    }

    return migrator
  }

  // MARK: Bootstrap and summaries

  func bootstrap() async throws -> [ConversationSummary] {
    try await listConversations()
  }

  func listConversations() async throws -> [ConversationSummary] {
    try await queue.read { db in
      try Self.summaries(db)
    }
  }

  private static func summaries(_ db: Database) throws -> [ConversationSummary] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT c.id, c.title, c.is_manually_titled, c.started_at,
               c.last_activity_at, c.is_unread,
               (SELECT COUNT(*) FROM message m WHERE m.conversation_id = c.id)
                 AS message_count,
               (SELECT m.payload FROM message m
                WHERE m.conversation_id = c.id
                ORDER BY m.position DESC LIMIT 1) AS latest_payload
        FROM conversation c
        ORDER BY c.last_activity_at DESC, c.id
        """)
    return rows.compactMap { row in
      guard let id = UUID(uuidString: row["id"]) else { return nil }
      let latestPreview =
        (row["latest_payload"] as String?)
        .flatMap { try? decoder.decode(ChatMessage.self, from: Data($0.utf8)) }?
        .previewText ?? ""
      return ConversationSummary(
        id: id,
        title: row["title"],
        isManuallyTitled: (row["is_manually_titled"] as Int64) != 0,
        startedAt: Date(timeIntervalSince1970: row["started_at"]),
        lastActivityAt: Date(timeIntervalSince1970: row["last_activity_at"]),
        latestMessagePreview: latestPreview,
        isUnread: (row["is_unread"] as Int64) != 0,
        messageCount: Int(row["message_count"] as Int64))
    }
  }

  // MARK: Conversation CRUD

  func createConversation(id: UUID, startedAt: Date) async throws -> ConversationSummary {
    try await queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO conversation (id, title, started_at, last_activity_at)
          VALUES (?, '', ?, ?)
          """,
        arguments: [
          id.uuidString, startedAt.timeIntervalSince1970,
          startedAt.timeIntervalSince1970,
        ])
    }
    return ConversationSummary(
      id: id, title: "", startedAt: startedAt, lastActivityAt: startedAt)
  }

  func loadConversation(id: UUID) async throws -> ConversationSnapshot {
    try await queue.read { db in
      guard
        let row = try Row.fetchOne(
          db, sql: "SELECT * FROM conversation WHERE id = ?",
          arguments: [id.uuidString])
      else { throw HistoryStoreError.conversationNotFound }
      let payloads = try Row.fetchAll(
        db,
        sql: """
          SELECT payload FROM message WHERE conversation_id = ?
          ORDER BY position
          """,
        arguments: [id.uuidString])
      let messages = payloads.compactMap {
        try? Self.decoder.decode(
          ChatMessage.self, from: Data(($0["payload"] as String).utf8))
      }
      var feedback: [UUID: AnswerFeedback] = [:]
      for feedbackRow in try Row.fetchAll(
        db, sql: "SELECT * FROM feedback WHERE conversation_id = ?",
        arguments: [id.uuidString])
      {
        guard let messageID = UUID(uuidString: feedbackRow["message_id"]),
          let verdict = AnswerFeedback.Verdict(rawValue: feedbackRow["verdict"])
        else { continue }
        feedback[messageID] = AnswerFeedback(
          messageID: messageID,
          verdict: verdict,
          correction: feedbackRow["correction"],
          updatedAt: Date(timeIntervalSince1970: feedbackRow["updated_at"]),
          runtimeMode:
            ModelRuntimeMode(rawValue: feedbackRow["runtime_mode"])
            ?? .evaluated,
          isEvaluated: (feedbackRow["is_evaluated"] as Int64) != 0)
      }
      let interrupted = try Row.fetchOne(
        db, sql: "SELECT * FROM turn_journal WHERE conversation_id = ?",
        arguments: [id.uuidString]
      ).map {
        InterruptedTurn(
          question: $0["question"],
          interruptedAt: Date(timeIntervalSince1970: $0["started_at"]))
      }
      let messageCount = try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM message WHERE conversation_id = ?",
        arguments: [id.uuidString]) ?? 0
      let summary = ConversationSummary(
        id: id,
        title: row["title"],
        isManuallyTitled: (row["is_manually_titled"] as Int64) != 0,
        startedAt: Date(timeIntervalSince1970: row["started_at"]),
        lastActivityAt: Date(timeIntervalSince1970: row["last_activity_at"]),
        latestMessagePreview: messages.last?.previewText ?? "",
        isUnread: (row["is_unread"] as Int64) != 0,
        messageCount: messageCount)
      return ConversationSnapshot(
        summary: summary,
        draft: row["draft"],
        messages: messages,
        feedback: feedback,
        interruptedTurn: interrupted)
    }
  }

  func rename(id: UUID, title: String) async throws {
    let trimmed = Self.autoTitle(from: title)
    try await queue.write { db in
      try db.execute(
        sql: """
          UPDATE conversation SET title = ?, is_manually_titled = 1
          WHERE id = ?
          """,
        arguments: [trimmed, id.uuidString])
      try Self.replaceTitleSearchRow(
        db, conversationID: id.uuidString, title: trimmed)
    }
  }

  func delete(id: UUID) async throws {
    try await queue.write { db in
      for table in ["message", "event", "feedback", "turn_journal"] {
        try db.execute(
          sql: "DELETE FROM \(table) WHERE conversation_id = ?",
          arguments: [id.uuidString])
      }
      try db.execute(
        sql: "DELETE FROM search_index WHERE conversation_id = ?",
        arguments: [id.uuidString])
      try db.execute(
        sql: "DELETE FROM conversation WHERE id = ?",
        arguments: [id.uuidString])
    }
  }

  func saveDraft(id: UUID, draft: String) async throws {
    try await queue.write { db in
      try db.execute(
        sql: "UPDATE conversation SET draft = ? WHERE id = ?",
        arguments: [draft, id.uuidString])
    }
  }

  func setUnread(id: UUID, isUnread: Bool) async throws {
    try await queue.write { db in
      try db.execute(
        sql: "UPDATE conversation SET is_unread = ? WHERE id = ?",
        arguments: [isUnread, id.uuidString])
    }
  }

  // MARK: Search

  func search(query: String) async throws -> [ConversationSearchHit] {
    guard let match = Self.ftsMatchExpression(from: query) else { return [] }
    return try await queue.read { db in
      // The snippet() auxiliary function only works in a plain query over
      // the FTS table, so ranking and excerpting happen in a subquery and
      // best-hit-per-conversation dedup happens here.
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT hits.conversation_id, hits.excerpt,
                 c.title, c.last_activity_at
          FROM (
            SELECT conversation_id,
                   snippet(search_index, 0, '', '', '…', 12) AS excerpt,
                   rank AS search_rank
            FROM search_index
            WHERE search_index MATCH ?
            ORDER BY rank
          ) AS hits
          JOIN conversation c ON c.id = hits.conversation_id
          ORDER BY hits.search_rank
          """,
        arguments: [match])
      var seen: Set<UUID> = []
      var results: [ConversationSearchHit] = []
      for row in rows {
        guard let id = UUID(uuidString: row["conversation_id"]),
          seen.insert(id).inserted
        else { continue }
        results.append(
          ConversationSearchHit(
            conversationID: id,
            title: row["title"],
            snippet: row["excerpt"],
            lastActivityAt: Date(timeIntervalSince1970: row["last_activity_at"])))
      }
      return results
    }
  }

  /// Converts free text into a safe FTS5 MATCH expression: every token is
  /// quoted, and the final token matches as a prefix while the user types.
  static func ftsMatchExpression(from query: String) -> String? {
    let tokens = query
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
    guard !tokens.isEmpty else { return nil }
    return tokens.enumerated()
      .map { index, token in
        let quoted = "\"\(token)\""
        return index == tokens.count - 1 ? quoted + "*" : quoted
      }
      .joined(separator: " ")
  }

  // MARK: Feedback

  func saveFeedback(conversationID: UUID, feedback: AnswerFeedback) async throws {
    try await queue.write { db in
      try db.execute(
        sql: """
          INSERT OR REPLACE INTO feedback
            (message_id, conversation_id, verdict, correction, updated_at,
             runtime_mode, is_evaluated)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          feedback.messageID.uuidString, conversationID.uuidString,
          feedback.verdict.rawValue, feedback.correction,
          feedback.updatedAt.timeIntervalSince1970,
          feedback.runtimeMode.rawValue, feedback.isEvaluated ? 1 : 0,
        ])
    }
  }

  func clearFeedback(conversationID: UUID, messageID: UUID) async throws {
    try await queue.write { db in
      try db.execute(
        sql: "DELETE FROM feedback WHERE message_id = ? AND conversation_id = ?",
        arguments: [messageID.uuidString, conversationID.uuidString])
    }
  }

  // MARK: Interruption journal

  func beginTurnJournal(
    conversationID: UUID, question: String, startedAt: Date
  ) async throws {
    try await queue.write { db in
      try db.execute(
        sql: """
          INSERT OR REPLACE INTO turn_journal
            (conversation_id, question, started_at)
          VALUES (?, ?, ?)
          """,
        arguments: [
          conversationID.uuidString, question, startedAt.timeIntervalSince1970,
        ])
    }
  }

  func endTurnJournal(conversationID: UUID) async throws {
    try await queue.write { db in
      try db.execute(
        sql: "DELETE FROM turn_journal WHERE conversation_id = ?",
        arguments: [conversationID.uuidString])
    }
  }

  // MARK: Messages and events

  func appendMessage(conversationID: UUID, message: ChatMessage) async throws {
    let payload = String(
      decoding: try Self.encoder.encode(message), as: UTF8.self)
    try await queue.write { db in
      let position =
        try Int.fetchOne(
          db,
          sql: """
            SELECT COALESCE(MAX(position), 0) + 1 FROM message
            WHERE conversation_id = ?
            """,
          arguments: [conversationID.uuidString]) ?? 1
      try db.execute(
        sql: """
          INSERT OR REPLACE INTO message (id, conversation_id, position, payload)
          VALUES (?, ?, ?, ?)
          """,
        arguments: [
          message.id.uuidString, conversationID.uuidString, position, payload,
        ])
      try db.execute(
        sql: "UPDATE conversation SET last_activity_at = ? WHERE id = ?",
        arguments: [
          message.createdAt.timeIntervalSince1970, conversationID.uuidString,
        ])

      // First question becomes the title unless a manual rename won already.
      if message.role == .user, case .text = message.body {
        let title = Self.autoTitle(from: message.previewText)
        try db.execute(
          sql: """
            UPDATE conversation SET title = ?
            WHERE id = ? AND is_manually_titled = 0 AND title = ''
            """,
          arguments: [title, conversationID.uuidString])
        if db.changesCount > 0 {
          try Self.replaceTitleSearchRow(
            db, conversationID: conversationID.uuidString, title: title)
        }
      }
      if let entry = Self.searchEntry(for: message) {
        try db.execute(
          sql: """
            INSERT INTO search_index (content, conversation_id, message_id, kind)
            VALUES (?, ?, ?, ?)
            """,
          arguments: [
            entry.content, conversationID.uuidString,
            message.id.uuidString, entry.kind,
          ])
      }
    }
  }

  func appendEvents(
    conversationID: UUID, messageID: UUID, lines: [String]
  ) async throws {
    try await queue.write { db in
      let base =
        try Int.fetchOne(
          db,
          sql: "SELECT COALESCE(MAX(seq), 0) FROM event WHERE conversation_id = ?",
          arguments: [conversationID.uuidString]) ?? 0
      for (offset, line) in lines.enumerated() {
        try db.execute(
          sql: """
            INSERT INTO event (conversation_id, message_id, seq, line)
            VALUES (?, ?, ?, ?)
            """,
          arguments: [
            conversationID.uuidString, messageID.uuidString,
            base + offset + 1, line,
          ])
      }
    }
  }

  func exportJSONL(conversationID: UUID) async throws -> URL {
    let lines = try await queue.read { db in
      try String.fetchAll(
        db, sql: "SELECT line FROM event WHERE conversation_id = ? ORDER BY seq",
        arguments: [conversationID.uuidString])
    }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "creg-conversation-\(conversationID.uuidString.prefix(8)).jsonl")
    try lines.joined(separator: "\n").appending("\n")
      .write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  // MARK: Support bundle

  func supportBundleSource() async throws -> SupportBundleSource {
    let snapshotURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("creg-history-snapshot.sqlite")
    try? FileManager.default.removeItem(at: snapshotURL)
    // VACUUM cannot run inside a transaction, so the snapshot copy happens
    // outside the transactional read below.
    try await queue.writeWithoutTransaction { db in
      try db.execute(sql: "VACUUM INTO ?", arguments: [snapshotURL.path])
    }
    return try await queue.read { db in
      struct NormalizedConversation: Encodable {
        var id: String
        var title: String
        var isManuallyTitled: Bool
        var startedAt: Double
        var lastActivityAt: Double
        var draft: String
        var isUnread: Bool
        var interruptedQuestion: String?
      }
      struct NormalizedMessage: Encodable {
        var conversationID: String
        var position: Int
        var payload: ChatMessage
      }
      struct NormalizedFeedback: Encodable {
        var conversationID: String
        var feedback: AnswerFeedback
      }

      let journals = try Row.fetchAll(db, sql: "SELECT * FROM turn_journal")
        .reduce(into: [String: String]()) {
          $0[$1["conversation_id"] as String] = $1["question"] as String
        }
      let conversations = try Row.fetchAll(
        db, sql: "SELECT * FROM conversation ORDER BY last_activity_at DESC"
      ).map { row in
        NormalizedConversation(
          id: row["id"],
          title: row["title"],
          isManuallyTitled: (row["is_manually_titled"] as Int64) != 0,
          startedAt: row["started_at"],
          lastActivityAt: row["last_activity_at"],
          draft: row["draft"],
          isUnread: (row["is_unread"] as Int64) != 0,
          interruptedQuestion: journals[row["id"] as String])
      }
      let messages = try Row.fetchAll(
        db, sql: "SELECT * FROM message ORDER BY conversation_id, position"
      ).compactMap { row -> NormalizedMessage? in
        guard
          let payload = try? Self.decoder.decode(
            ChatMessage.self, from: Data((row["payload"] as String).utf8))
        else { return nil }
        return NormalizedMessage(
          conversationID: row["conversation_id"],
          position: Int(row["position"] as Int64),
          payload: payload)
      }
      let feedback = try Row.fetchAll(db, sql: "SELECT * FROM feedback")
        .compactMap { row -> NormalizedFeedback? in
          guard let messageID = UUID(uuidString: row["message_id"]),
            let verdict = AnswerFeedback.Verdict(rawValue: row["verdict"])
          else { return nil }
          return NormalizedFeedback(
            conversationID: row["conversation_id"],
            feedback: AnswerFeedback(
              messageID: messageID,
              verdict: verdict,
              correction: row["correction"],
              updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
              runtimeMode:
                ModelRuntimeMode(rawValue: row["runtime_mode"])
                ?? .evaluated,
              isEvaluated: (row["is_evaluated"] as Int64) != 0))
        }
      let eventLines = try String.fetchAll(
        db, sql: "SELECT line FROM event ORDER BY conversation_id, seq")

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      return SupportBundleSource(
        databaseSnapshotURL: snapshotURL,
        conversationsJSON: try encoder.encode(conversations),
        messagesJSON: try encoder.encode(messages),
        eventsJSONL: Data(
          (eventLines.joined(separator: "\n") + "\n").utf8),
        feedbackJSON: try encoder.encode(feedback),
        conversationCount: conversations.count,
        messageCount: messages.count,
        eventLineCount: eventLines.count,
        feedbackCount: feedback.count)
    }
  }

  // MARK: Shared helpers

  /// Single-line, whitespace-collapsed, length-capped title text shared by
  /// auto-titling and manual rename storage.
  static func autoTitle(from text: String) -> String {
    let collapsed =
      text
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    return String(collapsed.prefix(titleLimit))
  }

  /// Only titles, user questions, and assistant narrations are searchable.
  static func searchEntry(
    for message: ChatMessage
  ) -> (content: String, kind: String)? {
    switch (message.role, message.body) {
    case (.user, .text(let question)):
      (question, "question")
    case (.assistant, .answer(_, let narration, _, _)):
      (narration, "narration")
    default:
      nil
    }
  }

  private static func replaceTitleSearchRow(
    _ db: Database, conversationID: String, title: String
  ) throws {
    try db.execute(
      sql: "DELETE FROM search_index WHERE conversation_id = ? AND kind = 'title'",
      arguments: [conversationID])
    try insertTitleSearchRow(db, conversationID: conversationID, title: title)
  }

  static func insertTitleSearchRow(
    _ db: Database, conversationID: String, title: String
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO search_index (content, conversation_id, message_id, kind)
        VALUES (?, ?, '', 'title')
        """,
      arguments: [title, conversationID])
  }
}

enum HistoryStoreError: Error, Sendable {
  case conversationNotFound
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
      beginTurnJournal: { _, _, _ in },
      endTurnJournal: { _ in },
      appendMessage: { _, _ in },
      appendEvents: { _, _, _ in },
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
      }
    )
  }

  /// Keeps startup recoverable while ensuring every attempted history
  /// operation reaches the feature's diagnostics and presentation boundary.
  static func unavailable(diagnostic: String) -> HistoryClient {
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
      beginTurnJournal: { _, _, _ in throw error },
      endTurnJournal: { _ in throw error },
      appendMessage: { _, _ in throw error },
      appendEvents: { _, _, _ in throw error },
      exportJSONL: { _ in throw error },
      supportBundleSource: { throw error }
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
