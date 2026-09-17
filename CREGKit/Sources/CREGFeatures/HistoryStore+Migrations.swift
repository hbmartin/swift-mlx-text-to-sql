import Foundation
import GRDB

extension HistoryStore {
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

    migrator.registerMigration("v4-prepared-follow-ups") { db in
      try db.execute(
        sql: """
          CREATE TABLE prepared_follow_up_batch (
            conversation_id TEXT PRIMARY KEY REFERENCES conversation(id),
            source_message_id TEXT NOT NULL,
            updated_at REAL NOT NULL,
            payload TEXT NOT NULL
          );
          """)
    }

    return migrator
  }
}
