import CREGEngine
import Foundation
import GRDB

extension HistoryStore {
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
      let followUpBatch = try String.fetchOne(
        db,
        sql: "SELECT payload FROM prepared_follow_up_batch WHERE conversation_id = ?",
        arguments: [id.uuidString]
      ).flatMap {
        try? Self.decoder.decode(
          PreparedFollowUpBatch.self, from: Data($0.utf8))
      }
      let messageCount =
        try Int.fetchOne(
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
        interruptedTurn: interrupted,
        followUpBatch: followUpBatch)
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
      for table in [
        "message", "event", "feedback", "turn_journal",
        "prepared_follow_up_batch",
      ] {
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
    let tokens =
      query
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

}
