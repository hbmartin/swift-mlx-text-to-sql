import CREGEngine
import Foundation
import GRDB

extension HistoryStore {
  // MARK: Interruption journal

  func endTurnJournal(conversationID: UUID) async throws {
    try await queue.write { db in
      try db.execute(
        sql: "DELETE FROM turn_journal WHERE conversation_id = ?",
        arguments: [conversationID.uuidString])
    }
  }

  // MARK: Messages and events

  func appendMessage(conversationID: UUID, message: ChatMessage) async throws {
    let payload = try Self.encodedPayload(for: message)
    try await queue.write { db in
      _ = try Self.appendMessage(
        db, conversationID: conversationID, message: message, payload: payload)
    }
  }

  @discardableResult
  private static func appendMessage(
    _ db: Database,
    conversationID: UUID,
    message: ChatMessage,
    payload: String
  ) throws -> Bool {
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
        INSERT OR IGNORE INTO message (id, conversation_id, position, payload)
        VALUES (?, ?, ?, ?)
        """,
      arguments: [
        message.id.uuidString, conversationID.uuidString, position, payload,
      ])
    // A prepared result and its final narration are persisted by separate
    // effects. If the final update wins that race, a late provisional append
    // must not replace it or move it to the end of the transcript.
    guard db.changesCount == 1 else { return false }
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
    return true
  }

  func updateMessage(conversationID: UUID, message: ChatMessage) async throws {
    let payload = try Self.encodedPayload(for: message)
    try await queue.write { db in
      try Self.updateMessage(
        db,
        conversationID: conversationID,
        message: message,
        payload: payload)
    }
  }

  private static func updateMessage(
    _ db: Database,
    conversationID: UUID,
    message: ChatMessage,
    payload: String
  ) throws {
    // A chart/table preference can race final narration. Merge that one field
    // in SQLite so the large message is encoded before acquiring the writer
    // and never decoded or re-encoded while the transaction is open.
    let presentationPath = ChatMessage.persistedResultPresentationJSONPath
    try db.execute(
      sql: """
        UPDATE message
        SET payload = CASE
          WHEN json_valid(payload) THEN
            CASE
              WHEN json_type(payload, '\(presentationPath)') = 'object'
              THEN json_set(
                ?1, '\(presentationPath)',
                json_extract(payload, '\(presentationPath)'))
              ELSE ?1
            END
          ELSE ?1
        END
        WHERE id = ?2 AND conversation_id = ?3
        """,
      arguments: [
        payload, message.id.uuidString, conversationID.uuidString,
      ])
    if db.changesCount != 1 {
      // A prepared-result preview and its final narration are emitted by
      // separate reducer effects. If finalization reaches the store first,
      // insert the final message directly; the late provisional append is
      // INSERT OR IGNORE and therefore cannot regress it.
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
          INSERT OR IGNORE INTO message (id, conversation_id, position, payload)
          VALUES (?, ?, ?, ?)
          """,
        arguments: [
          message.id.uuidString, conversationID.uuidString, position, payload,
        ])
      guard db.changesCount == 1 else {
        throw HistoryStoreError.messageNotFound
      }
      try db.execute(
        sql: "UPDATE conversation SET last_activity_at = ? WHERE id = ?",
        arguments: [
          message.createdAt.timeIntervalSince1970,
          conversationID.uuidString,
        ])
    }
    try db.execute(
      sql: "DELETE FROM search_index WHERE conversation_id = ? AND message_id = ?",
      arguments: [conversationID.uuidString, message.id.uuidString])
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

  func updateResultPresentation(
    conversationID: UUID,
    message: ChatMessage
  ) async throws {
    let fallbackPayload = String(
      decoding: try Self.encoder.encode(message), as: UTF8.self)
    try await queue.write { db in
      let storedPayload = try String.fetchOne(
        db,
        sql: """
          SELECT payload FROM message
          WHERE id = ? AND conversation_id = ?
          """,
        arguments: [message.id.uuidString, conversationID.uuidString])

      if let storedPayload {
        var storedMessage =
          (try? Self.decoder.decode(
            ChatMessage.self, from: Data(storedPayload.utf8))) ?? message
        storedMessage.resultPresentation = message.resultPresentation
        let patchedPayload = String(
          decoding: try Self.encoder.encode(storedMessage), as: UTF8.self)
        try db.execute(
          sql: """
            UPDATE message SET payload = ?
            WHERE id = ? AND conversation_id = ?
            """,
          arguments: [
            patchedPayload, message.id.uuidString, conversationID.uuidString,
          ])
        guard db.changesCount == 1 else {
          throw HistoryStoreError.messageNotFound
        }
        return
      }

      // The result can become interactive before its independent provisional
      // append reaches SQLite. Preserve that behavior without allowing a stale
      // provisional payload to replace an already-finalized message.
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
          INSERT OR IGNORE INTO message (id, conversation_id, position, payload)
          VALUES (?, ?, ?, ?)
          """,
        arguments: [
          message.id.uuidString, conversationID.uuidString, position,
          fallbackPayload,
        ])
      guard db.changesCount == 1 else {
        throw HistoryStoreError.messageNotFound
      }
      try db.execute(
        sql: "UPDATE conversation SET last_activity_at = ? WHERE id = ?",
        arguments: [
          message.createdAt.timeIntervalSince1970, conversationID.uuidString,
        ])
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

  func saveFollowUpBatch(
    conversationID: UUID,
    batch: PreparedFollowUpBatch
  ) async throws {
    let payload = String(
      decoding: try Self.encoder.encode(batch), as: UTF8.self)
    try await queue.write { db in
      try db.execute(
        sql: """
          INSERT OR REPLACE INTO prepared_follow_up_batch
            (conversation_id, source_message_id, updated_at, payload)
          VALUES (?, ?, ?, ?)
          """,
        arguments: [
          conversationID.uuidString,
          batch.sourceAssistantMessageID.uuidString,
          batch.updatedAt.timeIntervalSince1970,
          payload,
        ])
    }
  }

  func clearFollowUpBatch(conversationID: UUID) async throws {
    try await queue.write { db in
      try db.execute(
        sql: "DELETE FROM prepared_follow_up_batch WHERE conversation_id = ?",
        arguments: [conversationID.uuidString])
    }
  }

  func appendEvents(
    conversationID: UUID, messageID: UUID, lines: [String]
  ) async throws {
    try await queue.write { db in
      try Self.appendEvents(
        db, conversationID: conversationID, messageID: messageID, lines: lines)
    }
  }

  private static func appendEvents(
    _ db: Database,
    conversationID: UUID,
    messageID: UUID,
    lines: [String]
  ) throws {
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

  func persistUserTurn(
    conversationID: UUID,
    message: ChatMessage,
    question: String,
    startedAt: Date
  ) async throws {
    let payload = try Self.encodedPayload(for: message)
    try await queue.write { db in
      let inserted = try Self.appendMessage(
        db, conversationID: conversationID, message: message, payload: payload)
      // A Stop path may have already persisted and completed this exact turn.
      // A late duplicate user write must not reopen its interruption journal.
      guard inserted else { return }
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

  func persistTerminalTurn(
    conversationID: UUID,
    message: ChatMessage,
    replacesExisting: Bool,
    lines: [String]
  ) async throws {
    let payload = try Self.encodedPayload(for: message)
    try await queue.write { db in
      if replacesExisting {
        try Self.updateMessage(
          db,
          conversationID: conversationID,
          message: message,
          payload: payload)
      } else {
        try Self.appendMessage(
          db, conversationID: conversationID, message: message, payload: payload)
      }
      try Self.appendEvents(
        db, conversationID: conversationID, messageID: message.id, lines: lines)
      try db.execute(
        sql: "DELETE FROM turn_journal WHERE conversation_id = ?",
        arguments: [conversationID.uuidString])
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

}
