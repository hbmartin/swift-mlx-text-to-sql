import CREGEngine
import Foundation
import GRDB

extension HistoryStore {
  // MARK: Support bundle

  func supportBundleSource() async throws -> SupportBundleSource {
    let snapshotURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "creg-history-snapshot-\(UUID().uuidString).sqlite")
    var transfersSnapshotOwnership = false
    defer {
      if !transfersSnapshotOwnership {
        try? FileManager.default.removeItem(at: snapshotURL)
      }
    }
    // VACUUM cannot run inside a transaction, so the snapshot copy happens
    // outside the transactional read below.
    try await queue.writeWithoutTransaction { db in
      try db.execute(sql: "VACUUM INTO ?", arguments: [snapshotURL.path])
    }
    let source = try await queue.read { db in
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
      let followUpPayloads = try String.fetchAll(
        db,
        sql: "SELECT payload FROM prepared_follow_up_batch ORDER BY conversation_id")
      let followUps = followUpPayloads.compactMap {
        try? Self.decoder.decode(
          PreparedFollowUpBatch.self, from: Data($0.utf8))
      }

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      return SupportBundleSource(
        databaseSnapshotURL: snapshotURL,
        conversationsJSON: try encoder.encode(conversations),
        messagesJSON: try encoder.encode(messages),
        eventsJSONL: Data(
          (eventLines.joined(separator: "\n") + "\n").utf8),
        feedbackJSON: try encoder.encode(feedback),
        followUpsJSON: try encoder.encode(followUps),
        conversationCount: conversations.count,
        messageCount: messages.count,
        eventLineCount: eventLines.count,
        feedbackCount: feedback.count)
    }
    transfersSnapshotOwnership = true
    return source
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

  static func replaceTitleSearchRow(
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
