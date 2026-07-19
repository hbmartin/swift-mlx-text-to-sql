import CREGEngine
import Foundation
import GRDB

/// Persists conversations, messages, and the per-message JSONL event stream
/// in a writable history.sqlite — separate from the read-only portfolio DB.
public struct HistoryClient: Sendable {
  public var loadCurrentConversation: @Sendable () async throws -> (id: UUID, messages: [ChatMessage])
  public var appendMessage: @Sendable (_ conversationID: UUID, _ message: ChatMessage) async throws -> Void
  public var appendEvents: @Sendable (_ conversationID: UUID, _ messageID: UUID, _ jsonLines: [String]) async throws -> Void
  /// Writes the conversation's full JSONL event log to a temp file for export.
  public var exportJSONL: @Sendable (_ conversationID: UUID) async throws -> URL

  public init(
    loadCurrentConversation: @escaping @Sendable () async throws -> (id: UUID, messages: [ChatMessage]),
    appendMessage: @escaping @Sendable (UUID, ChatMessage) async throws -> Void,
    appendEvents: @escaping @Sendable (UUID, UUID, [String]) async throws -> Void,
    exportJSONL: @escaping @Sendable (UUID) async throws -> URL
  ) {
    self.loadCurrentConversation = loadCurrentConversation
    self.appendMessage = appendMessage
    self.appendEvents = appendEvents
    self.exportJSONL = exportJSONL
  }
}

extension HistoryClient {
  public static func live(databaseURL: URL) throws -> HistoryClient {
    try FileManager.default.createDirectory(
      at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let queue = try DatabaseQueue(path: databaseURL.path)
    try queue.write { db in
      try db.execute(sql: """
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
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    return HistoryClient(
      loadCurrentConversation: {
        try await queue.write { db in
          if let row = try Row.fetchOne(
            db, sql: "SELECT id FROM conversation ORDER BY started_at DESC LIMIT 1"),
            let id = UUID(uuidString: row["id"])
          {
            let payloads = try String.fetchAll(
              db, sql: "SELECT payload FROM message WHERE conversation_id = ? ORDER BY position",
              arguments: [id.uuidString])
            let messages = try payloads.map {
              try decoder.decode(ChatMessage.self, from: Data($0.utf8))
            }
            return (id, messages)
          }
          let id = UUID()
          try db.execute(
            sql: "INSERT INTO conversation (id, started_at) VALUES (?, datetime('now'))",
            arguments: [id.uuidString])
          return (id, [])
        }
      },
      appendMessage: { conversationID, message in
        let payload = String(decoding: try encoder.encode(message), as: UTF8.self)
        try await queue.write { db in
          let position =
            try Int.fetchOne(
              db, sql: "SELECT COALESCE(MAX(position), 0) + 1 FROM message WHERE conversation_id = ?",
              arguments: [conversationID.uuidString]) ?? 1
          try db.execute(
            sql: "INSERT OR REPLACE INTO message (id, conversation_id, position, payload) VALUES (?, ?, ?, ?)",
            arguments: [message.id.uuidString, conversationID.uuidString, position, payload])
        }
      },
      appendEvents: { conversationID, messageID, lines in
        try await queue.write { db in
          let base =
            try Int.fetchOne(
              db, sql: "SELECT COALESCE(MAX(seq), 0) FROM event WHERE conversation_id = ?",
              arguments: [conversationID.uuidString]) ?? 0
          for (offset, line) in lines.enumerated() {
            try db.execute(
              sql: "INSERT INTO event (conversation_id, message_id, seq, line) VALUES (?, ?, ?, ?)",
              arguments: [conversationID.uuidString, messageID.uuidString, base + offset + 1, line])
          }
        }
      },
      exportJSONL: { conversationID in
        let lines = try await queue.read { db in
          try String.fetchAll(
            db, sql: "SELECT line FROM event WHERE conversation_id = ? ORDER BY seq",
            arguments: [conversationID.uuidString])
        }
        let url = FileManager.default.temporaryDirectory
          .appendingPathComponent("creg-session-\(conversationID.uuidString.prefix(8)).jsonl")
        try lines.joined(separator: "\n").appending("\n")
          .write(to: url, atomically: true, encoding: .utf8)
        return url
      }
    )
  }

  public static func noop() -> HistoryClient {
    HistoryClient(
      loadCurrentConversation: { (UUID(), []) },
      appendMessage: { _, _ in },
      appendEvents: { _, _, _ in },
      exportJSONL: { _ in FileManager.default.temporaryDirectory }
    )
  }
}
