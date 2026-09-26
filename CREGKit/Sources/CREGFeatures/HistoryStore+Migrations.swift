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

    migrator.registerMigration("v5-turn-execution-identity") { db in
      try db.execute(
        sql: """
          ALTER TABLE turn_journal
            ADD COLUMN execution_id TEXT NOT NULL DEFAULT '';
          ALTER TABLE turn_journal
            ADD COLUMN status TEXT NOT NULL DEFAULT 'running';
          ALTER TABLE turn_journal
            ADD COLUMN auto_retry_count INTEGER NOT NULL DEFAULT 0;
          """)
    }

    migrator.registerMigration("v6-multiple-interrupted-turns") { db in
      try db.execute(sql: """
        CREATE TABLE turn_journal_v6 (
          journal_id TEXT PRIMARY KEY,
          conversation_id TEXT NOT NULL REFERENCES conversation(id),
          question TEXT NOT NULL,
          started_at REAL NOT NULL,
          execution_id TEXT NOT NULL,
          status TEXT NOT NULL,
          auto_retry_count INTEGER NOT NULL,
          submission_source TEXT
        );
        INSERT INTO turn_journal_v6
          (journal_id, conversation_id, question, started_at, execution_id,
           status, auto_retry_count, submission_source)
        SELECT CASE WHEN execution_id = '' THEN conversation_id ELSE execution_id END,
               conversation_id, question, started_at, execution_id,
               status, auto_retry_count, NULL
        FROM turn_journal;
        DROP TABLE turn_journal;
        ALTER TABLE turn_journal_v6 RENAME TO turn_journal;
        CREATE INDEX turn_journal_conversation_started
          ON turn_journal(conversation_id, started_at, journal_id);
        """)
    }

    // One monotonically increasing counter per Conversation. Every accepted
    // question advances it inside the transaction that retires the prior
    // batch, so a late suggestion write can prove which answer it belongs to.
    migrator.registerMigration("v7-suggestion-generation") { db in
      try db.execute(
        sql: """
          ALTER TABLE conversation
            ADD COLUMN suggestion_generation INTEGER NOT NULL DEFAULT 0;
          """)
    }

    return migrator
  }
}
