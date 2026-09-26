import Foundation
import GRDB
import Testing

@testable import CREGEngine
@testable import CREGFeatures

/// Live-store persistence tests against a temporary history.sqlite.
@Suite struct HistoryClientTests {
  private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("creg-history-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString + ".sqlite")
  }

  private func makeClient(_ url: URL) throws -> HistoryClient {
    try HistoryClient.live(databaseURL: url)
  }

  private func userMessage(
    _ text: String, id: UUID = UUID(), at seconds: TimeInterval
  ) -> ChatMessage {
    ChatMessage(
      id: id, role: .user, body: .text(text),
      createdAt: Date(timeIntervalSince1970: seconds))
  }

  private func answerMessage(
    narration: String, id: UUID = UUID(), at seconds: TimeInterval
  ) -> ChatMessage {
    ChatMessage(
      id: id, role: .assistant,
      body: .answer(
        result: QueryResult(columns: ["n"], rows: [[.integer(1)]]),
        narration: narration,
        sql: "SELECT 1",
        notice: nil),
      createdAt: Date(timeIntervalSince1970: seconds))
  }

  private func preparedFollowUp(
    id: UUID = UUID(), sourceMessageID: UUID
  ) -> PreparedFollowUp {
    let sql = "SELECT 1"
    let result = QueryResult(columns: ["n"], rows: [[.integer(1)]])
    return PreparedFollowUp(
      id: id,
      sourceAssistantMessageID: sourceMessageID,
      rank: 1,
      question: "How does that compare by fund?",
      sql: sql,
      result: result,
      preparationTelemetry: TurnTelemetry(originalQuestion: "How does that compare by fund?"),
      provenance: PreparedQueryProvenance(
        modelKey: "test-model",
        modelRevision: "test-revision",
        runtimeMode: .evaluated,
        preparationPolicyVersion: "prepared-follow-up-v1|binding-repair-v2",
        databaseFingerprint: "test-database",
        sqlFingerprint: PreparedFollowUpIntegrity.fingerprint(sql: sql),
        resultFingerprint: PreparedFollowUpIntegrity.fingerprint(result: result)),
      createdAt: Date(timeIntervalSince1970: 20))
  }

  // MARK: Migration

  @Test func legacyStoreMigratesPreservingConversationAndMessages() async throws {
    let url = temporaryDatabaseURL()
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    let legacyID = UUID()
    let encoder = JSONEncoder()
    let legacyMessages = [
      userMessage("Which properties have the highest vacancy?", at: 100),
      answerMessage(narration: "Five properties found.", at: 160),
    ]
    do {
      let queue = try DatabaseQueue(path: url.path)
      try await queue.write { db in
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
        try db.execute(
          sql: "INSERT INTO conversation (id, started_at) VALUES (?, datetime('now'))",
          arguments: [legacyID.uuidString])
        for (index, message) in legacyMessages.enumerated() {
          let payload = String(decoding: try encoder.encode(message), as: UTF8.self)
          try db.execute(
            sql: """
              INSERT INTO message (id, conversation_id, position, payload)
              VALUES (?, ?, ?, ?)
              """,
            arguments: [
              message.id.uuidString, legacyID.uuidString, index + 1, payload,
            ])
        }
      }
    }

    let client = try makeClient(url)
    let summaries = try await client.bootstrap()

    #expect(summaries.count == 1)
    #expect(summaries.first?.id == legacyID)
    #expect(summaries.first?.title == "Which properties have the highest vacancy?")
    #expect(summaries.first?.isManuallyTitled == false)
    #expect(summaries.first?.messageCount == 2)
    #expect(summaries.first?.latestMessagePreview == "Five properties found.")

    let snapshot = try await client.loadConversation(legacyID)
    #expect(snapshot.messages == legacyMessages)
    #expect(snapshot.draft.isEmpty)
    #expect(snapshot.interruptedTurn == nil)
    #expect(try await client.search("vacancy").map(\.conversationID) == [legacyID])
  }

  @Test func versionFourStoreOpeningPreservesEveryHistoryTable() async throws {
    let url = temporaryDatabaseURL()
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    let queue = try DatabaseQueue(path: url.path)
    try HistoryStore.migrator.migrate(queue, upTo: "v4-prepared-follow-ups")
    let legacyID = UUID()
    let legacyMessage = userMessage("Old lineage", at: 100)
    let payload = String(
      decoding: try JSONEncoder().encode(legacyMessage),
      as: UTF8.self)
    try await queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO conversation
            (id, title, is_manually_titled, started_at, last_activity_at, draft, is_unread)
          VALUES (?, 'Old', 0, 100, 100, 'saved draft', 0);
          INSERT INTO message (id, conversation_id, position, payload)
          VALUES (?, ?, 1, ?);
          INSERT INTO event (conversation_id, message_id, seq, line)
          VALUES (?, ?, 1, '{}');
          INSERT INTO feedback
            (message_id, conversation_id, verdict, correction, updated_at,
             runtime_mode, is_evaluated)
          VALUES (?, ?, 'up', NULL, 100, 'evaluated', 1);
          INSERT INTO turn_journal (conversation_id, question, started_at)
          VALUES (?, 'Old question', 100);
          INSERT INTO search_index (content, conversation_id, message_id, kind)
          VALUES ('Old lineage', ?, ?, 'message');
          INSERT INTO prepared_follow_up_batch
            (conversation_id, source_message_id, updated_at, payload)
          VALUES (?, ?, 100, '{}');
          """,
        arguments: [
          legacyID.uuidString,
          legacyMessage.id.uuidString, legacyID.uuidString, payload,
          legacyID.uuidString, legacyMessage.id.uuidString,
          legacyMessage.id.uuidString, legacyID.uuidString,
          legacyID.uuidString,
          legacyID.uuidString, legacyMessage.id.uuidString,
          legacyID.uuidString, legacyMessage.id.uuidString,
        ])
      }

    let client = try makeClient(url)
    let summaries = try await client.bootstrap()
    #expect(summaries.map(\.id) == [legacyID])
    let snapshot = try await client.loadConversation(legacyID)
    #expect(snapshot.messages == [legacyMessage])
    #expect(snapshot.draft == "saved draft")
    #expect(snapshot.interruptedTurn?.source == .freeForm)
    #expect(snapshot.interruptedTurn?.journalID != nil)
    let tables = [
      "prepared_follow_up_batch", "turn_journal", "feedback", "event",
      "message", "search_index", "conversation",
    ]
    let counts = try await queue.read { db in
      try Dictionary(uniqueKeysWithValues: tables.map { table in
        (table, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1)
      })
    }
    #expect(counts.values.allSatisfy { $0 == 1 })
    #expect(try await client.search("Old lineage").map(\.conversationID) == [legacyID])
  }

  // MARK: CRUD, titles, drafts, unread

  @Test func autoTitleComesFromFirstQuestionAndManualRenameWins() async throws {
    let client = try makeClient(temporaryDatabaseURL())
    let id = UUID()
    _ = try await client.createConversation(id, Date(timeIntervalSince1970: 0))

    try await client.appendMessage(
      id, userMessage("What's my rent roll   by  property type?", at: 10))
    var snapshot = try await client.loadConversation(id)
    #expect(snapshot.summary.title == "What's my rent roll by property type?")
    #expect(snapshot.summary.isManuallyTitled == false)

    try await client.renameConversation(id, "Rent roll deep dive")
    try await client.appendMessage(id, userMessage("another question", at: 20))
    snapshot = try await client.loadConversation(id)
    #expect(snapshot.summary.title == "Rent roll deep dive")
    #expect(snapshot.summary.isManuallyTitled == true)
  }

  @Test func draftsPersistPerConversation() async throws {
    let client = try makeClient(temporaryDatabaseURL())
    let id = UUID()
    _ = try await client.createConversation(id, Date(timeIntervalSince1970: 0))

    try await client.saveDraft(id, "unsent thought")
    let snapshot = try await client.loadConversation(id)
    #expect(snapshot.draft == "unsent thought")

    try await client.saveDraft(id, "")
    let cleared = try await client.loadConversation(id)
    #expect(cleared.draft.isEmpty)
  }

  @Test func unreadFlagRoundTrips() async throws {
    let client = try makeClient(temporaryDatabaseURL())
    let id = UUID()
    _ = try await client.createConversation(id, Date(timeIntervalSince1970: 0))

    try await client.setUnread(id, true)
    #expect(try await client.listConversations().first?.isUnread == true)
    try await client.setUnread(id, false)
    #expect(try await client.listConversations().first?.isUnread == false)
  }

  @Test func listOrdersByLatestActivity() async throws {
    let client = try makeClient(temporaryDatabaseURL())
    let older = UUID()
    let newer = UUID()
    _ = try await client.createConversation(older, Date(timeIntervalSince1970: 0))
    _ = try await client.createConversation(newer, Date(timeIntervalSince1970: 5))
    try await client.appendMessage(older, userMessage("bump activity", at: 100))

    let summaries = try await client.listConversations()
    #expect(summaries.map(\.id) == [older, newer])
  }

  @Test func deleteRemovesConversationMessagesEventsAndSearch() async throws {
    let client = try makeClient(temporaryDatabaseURL())
    let id = UUID()
    _ = try await client.createConversation(id, Date(timeIntervalSince1970: 0))
    let message = userMessage("unique zanzibar query", at: 10)
    try await client.appendMessage(id, message)
    try await client.appendEvents(id, message.id, ["{\"event\":\"line\"}"])

    try await client.deleteConversation(id)

    #expect(try await client.listConversations().isEmpty)
    #expect(try await client.search("zanzibar").isEmpty)
    await #expect(throws: (any Error).self) {
      _ = try await client.loadConversation(id)
    }
  }

  // MARK: Search

  @Test func searchMatchesTitlesQuestionsAndNarrationsInsensitively() async throws {
    let client = try makeClient(temporaryDatabaseURL())
    let id = UUID()
    _ = try await client.createConversation(id, Date(timeIntervalSince1970: 0))
    try await client.appendMessage(
      id, userMessage("Which tenants rent at Béa Café?", at: 10))
    try await client.appendMessage(
      id, answerMessage(narration: "Two tenants rent there.", at: 20))

    // Case-insensitive.
    #expect(try await client.search("BEA").count == 1)
    // Diacritic-insensitive.
    #expect(try await client.search("cafe").count == 1)
    // Narrations are searchable.
    #expect(try await client.search("tenants rent").count == 1)
    // Prefix matching while typing.
    #expect(try await client.search("tenan").count == 1)
    #expect(try await client.search("nomatch").isEmpty)
  }

  @Test func searchNeverIndexesSQLOrFailures() async throws {
    let client = try makeClient(temporaryDatabaseURL())
    let id = UUID()
    _ = try await client.createConversation(id, Date(timeIntervalSince1970: 0))
    try await client.appendMessage(
      id,
      ChatMessage(
        id: UUID(), role: .assistant,
        body: .failure("uniquefailuretext happened"),
        createdAt: Date(timeIntervalSince1970: 10)))
    try await client.appendMessage(
      id, answerMessage(narration: "Fine narration.", at: 20))

    // The failure body and the answer's SQL are not searchable.
    #expect(try await client.search("uniquefailuretext").isEmpty)
    #expect(try await client.search("SELECT").isEmpty)
  }

  @Test func ftsMatchExpressionQuotesAndPrefixes() {
    #expect(HistoryStore.ftsMatchExpression(from: "market value") == "\"market\" \"value\"*")
    #expect(HistoryStore.ftsMatchExpression(from: "a-b") == "\"a\" \"b\"*")
    #expect(HistoryStore.ftsMatchExpression(from: "  ") == nil)
    // FTS operators arrive as plain quoted tokens, never syntax.
    #expect(HistoryStore.ftsMatchExpression(from: "OR") == "\"OR\"*")
  }

  // MARK: Feedback

  @Test func feedbackSavesUpdatesAndClears() async throws {
    let client = try makeClient(temporaryDatabaseURL())
    let id = UUID()
    _ = try await client.createConversation(id, Date(timeIntervalSince1970: 0))
    let message = answerMessage(narration: "Answer.", at: 10)
    try await client.appendMessage(id, message)

    try await client.saveFeedback(
      id,
      AnswerFeedback(
        messageID: message.id, verdict: .notRight,
        updatedAt: Date(timeIntervalSince1970: 20)))
    var snapshot = try await client.loadConversation(id)
    #expect(snapshot.feedback[message.id]?.verdict == .notRight)
    #expect(snapshot.feedback[message.id]?.correction == nil)

    // The eventual correction updates the same judgment.
    try await client.saveFeedback(
      id,
      AnswerFeedback(
        messageID: message.id, verdict: .notRight,
        correction: "Exclude sold properties",
        updatedAt: Date(timeIntervalSince1970: 30),
        runtimeMode: .compatibility))
    snapshot = try await client.loadConversation(id)
    #expect(snapshot.feedback[message.id]?.correction == "Exclude sold properties")
    #expect(snapshot.feedback[message.id]?.runtimeMode == .compatibility)
    #expect(snapshot.feedback[message.id]?.isEvaluated == false)

    try await client.clearFeedback(id, message.id)
    snapshot = try await client.loadConversation(id)
    #expect(snapshot.feedback.isEmpty)
  }

  // MARK: Interruption journal

  @Test func turnJournalSurvivesAsInterruptedTurnUntilEnded() async throws {
    let client = try makeClient(temporaryDatabaseURL())
    let id = UUID()
    _ = try await client.createConversation(id, Date(timeIntervalSince1970: 0))

    let message = userMessage("Which loans mature soonest?", at: 50)
    try await client.persistUserTurn(
      id, message, QuestionSubmission(question: "Which loans mature soonest?"), message.createdAt, nil)
    var snapshot = try await client.loadConversation(id)
    #expect(snapshot.interruptedTurn?.question == "Which loans mature soonest?")
    #expect(snapshot.interruptedTurn?.executionID == message.id)
    #expect(
      snapshot.interruptedTurn?.interruptedAt == Date(timeIntervalSince1970: 50))

    try await client.endTurnJournal(id, message.id)
    snapshot = try await client.loadConversation(id)
    #expect(snapshot.interruptedTurn == nil)
  }

  @Test func knownInterruptionCanBeAutomaticallyClaimedOnlyOnce() async throws {
    let url = temporaryDatabaseURL()
    let client = try makeClient(url)
    let id = UUID()
    _ = try await client.createConversation(id, Date(timeIntervalSince1970: 0))
    let message = userMessage("Which loans mature soonest?", at: 50)
    try await client.persistUserTurn(
      id, message, QuestionSubmission(question: "Which loans mature soonest?"), message.createdAt, nil)
    try await client.markTurnInterrupted(id, message.id, false)
    var snapshot = try await client.loadConversation(id)
    #expect(snapshot.interruptedTurn?.canAutoRetry == true)
    #expect(try await makeClient(url).loadConversation(id).interruptedTurn?.canAutoRetry == true)

    #expect(try await client.claimTurnRetry(
      id, message.id, message.id, true) == 1)
    #expect(try await client.claimTurnRetry(
      id, message.id, message.id, true) == nil)
    snapshot = try await client.loadConversation(id)
    #expect(snapshot.interruptedTurn?.autoRetryCount == 1)
    #expect(snapshot.interruptedTurn?.canAutoRetry == false)
    #expect(try await makeClient(url).loadConversation(id).interruptedTurn?.canAutoRetry == false)
    #expect(snapshot.messages == [message])
  }

  @Test func retryClaimRequiresTrailingUserAndDeclineSurvivesReload() async throws {
    let url = temporaryDatabaseURL()
    let client = try makeClient(url)
    let conversationID = UUID()
    _ = try await client.createConversation(
      conversationID, Date(timeIntervalSince1970: 0))
    let first = userMessage("Repeated question", at: 10)
    let second = userMessage("Repeated question", at: 20)
    try await client.persistUserTurn(
      conversationID, first, QuestionSubmission(question: first.previewText),
      first.createdAt, nil)
    try await client.markTurnInterrupted(conversationID, first.id, false)
    try await client.persistUserTurn(
      conversationID, second, QuestionSubmission(question: second.previewText),
      second.createdAt, nil)
    #expect(try await client.claimTurnRetry(
      conversationID, first.id, first.id, true) == nil)
    try await client.markTurnInterrupted(conversationID, second.id, false)
    #expect(try await client.claimTurnRetry(
      conversationID, second.id, second.id, true) == 1)
    try await client.releaseAutoRetryClaim(
      conversationID, second.id, second.id, true)
    #expect(try await client.loadConversation(conversationID)
      .interruptedTurns.last?.canAutoRetry == true)
    try await client.declineAutoRetry(conversationID, second.id)
    let reloaded = try await makeClient(url).loadConversation(conversationID)
    #expect(reloaded.interruptedTurns.last?.status == .manualRetryRequired)
    #expect(reloaded.interruptedTurns.last?.canAutoRetry == false)
    #expect(try await client.claimTurnRetry(
      conversationID, second.id, second.id, true) == nil)
  }

  /// The journal is authoritative for the retry count: a manual takeover
  /// preserves the count the automatic claim spent, and releasing the manual
  /// claim leaves it spent. Ask Again never replenishes the allowance.
  @Test func manualTakeoverPreservesAutomaticCountAndReleasesAsManual() async throws {
    let url = temporaryDatabaseURL()
    let client = try makeClient(url)
    let conversationID = UUID()
    _ = try await client.createConversation(
      conversationID, Date(timeIntervalSince1970: 0))
    let user = userMessage("Retry after interruption", at: 10)
    try await client.persistUserTurn(
      conversationID, user, QuestionSubmission(question: user.previewText),
      user.createdAt, nil)
    try await client.markTurnInterrupted(conversationID, user.id, false)
    #expect(try await client.claimTurnRetry(
      conversationID, user.id, user.id, true) == 1)
    #expect(try await client.claimTurnRetry(
      conversationID, user.id, user.id, false) == 1)
    try await client.releaseAutoRetryClaim(conversationID, user.id, user.id, false)
    let saved = try await client.loadConversation(conversationID)
    #expect(saved.interruptedTurn?.status == .manualRetryRequired)
    #expect(saved.interruptedTurn?.autoRetryCount == 1)
    // The count survives reload and a fresh process cannot claim automatically.
    let reloaded = try await makeClient(url).loadConversation(conversationID)
    #expect(reloaded.interruptedTurn?.autoRetryCount == 1)
    #expect(try await client.claimTurnRetry(
      conversationID, user.id, user.id, true) == nil)
    #expect(try await client.claimTurnRetry(
      conversationID, user.id, user.id, false) == 1)
  }

  /// A manual claim on a never-retried row keeps the count at zero, and its
  /// release reopens the row as a known interruption.
  @Test func manualClaimOnFreshRowPreservesZeroCount() async throws {
    let client = try makeClient(temporaryDatabaseURL())
    let conversationID = UUID()
    _ = try await client.createConversation(
      conversationID, Date(timeIntervalSince1970: 0))
    let user = userMessage("Ask again first", at: 10)
    try await client.persistUserTurn(
      conversationID, user, QuestionSubmission(question: user.previewText),
      user.createdAt, nil)
    try await client.markTurnInterrupted(conversationID, user.id, false)
    #expect(try await client.claimTurnRetry(
      conversationID, user.id, user.id, false) == 0)
    try await client.releaseAutoRetryClaim(conversationID, user.id, user.id, false)
    let saved = try await client.loadConversation(conversationID)
    #expect(saved.interruptedTurn?.status == .knownInterruption)
    #expect(saved.interruptedTurn?.autoRetryCount == 0)
    // An automatic release of a row that never made an automatic claim is a
    // missing source, not a silent reset.
    #expect(try await client.claimTurnRetry(
      conversationID, user.id, user.id, false) == 0)
    await #expect(throws: (any Error).self) {
      try await client.releaseAutoRetryClaim(conversationID, user.id, user.id, true)
    }
  }

  @Test func twoInterruptionsRemainIndependentThroughOffscreenCompletionAndDismissal() async throws {
    let client = try makeClient(temporaryDatabaseURL())
    let conversationID = UUID()
    _ = try await client.createConversation(conversationID, Date(timeIntervalSince1970: 0))
    let first = userMessage("Which properties are vacant?", at: 10)
    let prepared = preparedFollowUp(sourceMessageID: UUID())
    let second = userMessage(prepared.question, at: 20)
    try await client.persistUserTurn(
      conversationID, first,
      QuestionSubmission(question: first.previewText, source: .starter(.highestVacancyV1)),
      first.createdAt, nil)
    try await client.markTurnInterrupted(conversationID, first.id, false)
    try await client.persistUserTurn(
      conversationID, second,
      QuestionSubmission(question: second.previewText, source: .preparedFollowUp(prepared)),
      second.createdAt, nil)
    try await client.markTurnInterrupted(conversationID, second.id, false)

    var snapshot = try await client.loadConversation(conversationID)
    #expect(snapshot.interruptedTurns.map(\.journalID) == [first.id, second.id])
    #expect(snapshot.interruptedTurns.first?.source == .starter(.highestVacancyV1))
    #expect(snapshot.interruptedTurns.last?.source == .preparedFollowUp(prepared))

    // Completion of a queued turn while this conversation is offscreen must
    // close only that execution's row.
    let answer = answerMessage(narration: "A loan matures soon.", at: 30)
    try await client.persistTerminalTurn(conversationID, second.id, answer, false, [])
    snapshot = try await client.loadConversation(conversationID)
    #expect(snapshot.interruptedTurns.map(\.journalID) == [first.id])

    try await client.endTurnJournal(conversationID, first.id)
    snapshot = try await client.loadConversation(conversationID)
    #expect(snapshot.interruptedTurns.isEmpty)
    #expect(snapshot.messages == [first, second, answer])
  }

  @Test func olderRetryTransfersJournalOnlyWithNewUserTurn() async throws {
    let client = try makeClient(temporaryDatabaseURL())
    let conversationID = UUID()
    _ = try await client.createConversation(conversationID, Date(timeIntervalSince1970: 0))
    let old = userMessage("Old question", at: 10)
    let later = userMessage("Later question", at: 20)
    try await client.persistUserTurn(
      conversationID, old, QuestionSubmission(question: old.previewText), old.createdAt, nil)
    try await client.markTurnInterrupted(conversationID, old.id, false)
    try await client.persistUserTurn(
      conversationID, later, QuestionSubmission(question: later.previewText), later.createdAt, nil)
    try await client.persistTerminalTurn(
      conversationID, later.id, answerMessage(narration: "Later answer", at: 25), false, [])

    let beforeClaim = try await client.loadConversation(conversationID)
    #expect(beforeClaim.interruptedTurns.map(\.journalID) == [old.id])
    let retry = userMessage("Old question", at: 30)
    try await client.persistUserTurn(
      conversationID, retry, QuestionSubmission(question: retry.previewText),
      retry.createdAt, old.id)
    let afterClaim = try await client.loadConversation(conversationID)
    #expect(afterClaim.interruptedTurns.map(\.journalID) == [retry.id])
    #expect(afterClaim.messages.last == retry)
    #expect(afterClaim.messages.map(\.id).prefix(2) == [old.id, later.id])

    let duplicate = userMessage("Old question", at: 40)
    var rejectedMissingSource = false
    do {
      try await client.persistUserTurn(
        conversationID, duplicate, QuestionSubmission(question: duplicate.previewText),
        duplicate.createdAt, old.id)
    } catch {
      rejectedMissingSource = true
    }
    #expect(rejectedMissingSource)
    #expect(try await client.loadConversation(conversationID).messages.last == retry)
  }

  /// The durable count is what a fresh process reads: after one automatic
  /// claim the row never auto-retries again, in this process or the next.
  @Test func automaticClaimCountSurvivesReloadAndBlocksASecondAutomaticClaim() async throws {
    let url = temporaryDatabaseURL()
    let client = try makeClient(url)
    let conversationID = UUID()
    _ = try await client.createConversation(conversationID, Date(timeIntervalSince1970: 0))
    let user = userMessage("Retry once", at: 10)
    try await client.persistUserTurn(
      conversationID, user, QuestionSubmission(question: user.previewText),
      user.createdAt, nil)
    try await client.markTurnInterrupted(conversationID, user.id, false)
    #expect(try await client.claimTurnRetry(conversationID, user.id, user.id, true) == 1)
    // The retried turn is interrupted again before it finishes.
    try await client.markTurnInterrupted(conversationID, user.id, false)

    let reloaded = try await makeClient(url).loadConversation(conversationID)
    #expect(reloaded.interruptedTurn?.status == .knownInterruption)
    #expect(reloaded.interruptedTurn?.autoRetryCount == 1)
    #expect(reloaded.interruptedTurn?.canAutoRetry == false)
    #expect(try await makeClient(url).claimTurnRetry(
      conversationID, user.id, user.id, true) == nil)
    // Ask Again still works and reports the spent count.
    #expect(try await makeClient(url).claimTurnRetry(
      conversationID, user.id, user.id, false) == 1)
  }

  @Test func transferredJournalKeepsItsSpentCount() async throws {
    let client = try makeClient(temporaryDatabaseURL())
    let conversationID = UUID()
    _ = try await client.createConversation(conversationID, Date(timeIntervalSince1970: 0))
    let old = userMessage("Old question", at: 10)
    try await client.persistUserTurn(
      conversationID, old, QuestionSubmission(question: old.previewText), old.createdAt, nil)
    try await client.markTurnInterrupted(conversationID, old.id, false)
    #expect(try await client.claimTurnRetry(conversationID, old.id, old.id, true) == 1)
    try await client.markTurnInterrupted(conversationID, old.id, false)
    let later = userMessage("Later question", at: 20)
    try await client.persistUserTurn(
      conversationID, later, QuestionSubmission(question: later.previewText), later.createdAt, nil)
    try await client.persistTerminalTurn(
      conversationID, later.id, answerMessage(narration: "Later answer", at: 25), false, [])

    let retry = userMessage("Old question", at: 30)
    try await client.persistUserTurn(
      conversationID, retry, QuestionSubmission(question: retry.previewText),
      retry.createdAt, old.id)
    try await client.markTurnInterrupted(conversationID, retry.id, false)
    let snapshot = try await client.loadConversation(conversationID)
    #expect(snapshot.interruptedTurns.map(\.journalID) == [retry.id])
    #expect(snapshot.interruptedTurns.first?.autoRetryCount == 1)
    #expect(snapshot.interruptedTurns.first?.canAutoRetry == false)
  }

  @Test func createConversationWithDraftIsAtomicAndVisibleOnReload() async throws {
    let url = temporaryDatabaseURL()
    let client = try makeClient(url)
    let id = UUID()
    let summary = try await client.createConversationWithDraft(
      id, Date(timeIntervalSince1970: 7), "Rejected question text")
    #expect(summary.id == id)
    let snapshot = try await makeClient(url).loadConversation(id)
    #expect(snapshot.draft == "Rejected question text")
    #expect(snapshot.messages.isEmpty)
    #expect(try await client.bootstrap().map(\.id) == [id])
  }

  // MARK: Prepared follow-ups

  /// Accepting a question retires the prior batch and advances the durable
  /// generation in one transaction; a suggestion write that lost the race
  /// is refused, and a relaunch sees no chips for the retired answer.
  @Test func acceptedQuestionRetiresBatchAndRejectsLateWritesAcrossRelaunch() async throws {
    let url = temporaryDatabaseURL()
    let client = try makeClient(url)
    let conversationID = UUID()
    _ = try await client.createConversation(conversationID, Date(timeIntervalSince1970: 0))
    let firstAnswer = answerMessage(narration: "First answer", at: 10)
    try await client.appendMessage(conversationID, firstAnswer)
    let context = FollowUpSuggestionContext(
      sourceAssistantMessageID: firstAnswer.id,
      question: "First", standaloneQuestion: "First",
      narration: "First answer", result: QueryResult(columns: [], rows: []))
    let batch = PreparedFollowUpBatch(
      sourceAssistantMessageID: firstAnswer.id, context: context,
      status: .completed,
      suggestions: [preparedFollowUp(sourceMessageID: firstAnswer.id)],
      updatedAt: Date(timeIntervalSince1970: 11), generation: 0)
    try await client.saveFollowUpBatch(conversationID, batch)
    #expect(try await client.loadConversation(conversationID).followUpBatch == batch)

    // Q2 is accepted: generation 1, batch retired, all in one transaction.
    try await client.acceptQuestion(conversationID, 1)
    #expect(try await client.loadConversation(conversationID).followUpBatch == nil)
    #expect(try await client.loadConversation(conversationID).suggestionGeneration == 1)
    // A late write from the retired generation is refused even though its
    // source is still the latest message.
    var late = batch
    late.updatedAt = Date(timeIntervalSince1970: 12)
    await #expect(throws: HistoryStoreError.staleFollowUpBatch) {
      try await client.saveFollowUpBatch(conversationID, late)
    }
    let relaunched = try await makeClient(url).loadConversation(conversationID)
    #expect(relaunched.followUpBatch == nil)
    #expect(relaunched.summary.suggestionGeneration == 1)
    #expect(try await makeClient(url).bootstrap().first?.suggestionGeneration == 1)

    // The durable counter never moves backwards.
    try await client.acceptQuestion(conversationID, 1)
    #expect(try await client.loadConversation(conversationID).suggestionGeneration == 1)

    // The new answer's batch, prepared under generation 1, saves and loads.
    let secondUser = userMessage("Second", at: 20)
    let secondAnswer = answerMessage(narration: "Second answer", at: 21)
    try await client.appendMessage(conversationID, secondUser)
    try await client.appendMessage(conversationID, secondAnswer)
    let secondContext = FollowUpSuggestionContext(
      sourceAssistantMessageID: secondAnswer.id,
      question: "Second", standaloneQuestion: "Second",
      narration: "Second answer", result: QueryResult(columns: [], rows: []))
    let second = PreparedFollowUpBatch(
      sourceAssistantMessageID: secondAnswer.id, context: secondContext,
      updatedAt: Date(timeIntervalSince1970: 22), generation: 1)
    try await client.saveFollowUpBatch(conversationID, second)
    #expect(try await makeClient(url).loadConversation(conversationID).followUpBatch == second)
  }

  /// Batches persisted before generations existed decode with a nil
  /// generation, compare as generation zero, and are discarded on load once
  /// the Conversation moves on or their answer stops being the latest.
  @Test func legacyBatchDecodesCompatiblyAndIsDiscardedWhenStale() async throws {
    let url = temporaryDatabaseURL()
    let client = try makeClient(url)
    let conversationID = UUID()
    _ = try await client.createConversation(conversationID, Date(timeIntervalSince1970: 0))
    let answer = answerMessage(narration: "Legacy answer", at: 10)
    try await client.appendMessage(conversationID, answer)
    let legacyPayload = """
      {"sourceAssistantMessageID":"\(answer.id.uuidString)","status":"completed",
       "suggestions":[],"updatedAt":11}
      """
    let queue = try DatabaseQueue(path: url.path)
    try await queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO prepared_follow_up_batch
            (conversation_id, source_message_id, updated_at, payload)
          VALUES (?, ?, 11, ?)
          """,
        arguments: [conversationID.uuidString, answer.id.uuidString, legacyPayload])
    }
    let loaded = try await client.loadConversation(conversationID).followUpBatch
    #expect(loaded?.generation == nil)
    #expect(loaded?.effectiveGeneration == 0)
    #expect(loaded?.scopeDiagnosisCompleted == false)
    #expect(loaded?.status == .completed)

    // A newer message makes the legacy batch stale on load.
    try await client.appendMessage(conversationID, userMessage("Next", at: 12))
    #expect(try await client.loadConversation(conversationID).followUpBatch == nil)
  }

  @Test func preparedBatchRoundTripsProgressivelyAndClears() async throws {
    let client = try makeClient(temporaryDatabaseURL())
    let conversationID = UUID()
    let sourceID = UUID()
    _ = try await client.createConversation(
      conversationID, Date(timeIntervalSince1970: 0))
    try await client.appendMessage(
      conversationID, answerMessage(narration: "Portfolio value is shown.", id: sourceID, at: 5))
    let context = FollowUpSuggestionContext(
      sourceAssistantMessageID: sourceID,
      question: "What is portfolio value?",
      standaloneQuestion: "What is portfolio value?",
      narration: "Portfolio value is shown.",
      result: QueryResult(columns: ["value"], rows: [[.integer(1)]]))
    var batch = PreparedFollowUpBatch(
      sourceAssistantMessageID: sourceID,
      context: context,
      updatedAt: Date(timeIntervalSince1970: 10))
    try await client.saveFollowUpBatch(conversationID, batch)
    #expect(
      try await client.loadConversation(conversationID).followUpBatch?.status
        == .preparing)

    batch.suggestions = [preparedFollowUp(sourceMessageID: sourceID)]
    batch.status = .completed
    try await client.saveFollowUpBatch(conversationID, batch)
    let loaded = try await client.loadConversation(conversationID).followUpBatch
    #expect(loaded == batch)
    let exported = try JSONDecoder().decode(
      [PreparedFollowUpBatch].self,
      from: try await client.supportBundleSource().followUpsJSON)
    let provenance = try #require(
      exported.first?.suggestions.first?.provenance)
    #expect(provenance.databaseFingerprint == "test-database")
    #expect(
      provenance.preparationPolicyVersion
        == "prepared-follow-up-v1|binding-repair-v2")

    try await client.clearFollowUpBatch(conversationID)
    #expect(
      try await client.loadConversation(conversationID).followUpBatch == nil)
  }

  @Test func olderSuggestionSaveCannotReplaceLatestAnsweredTurn() async throws {
    let client = try makeClient(temporaryDatabaseURL())
    let conversationID = UUID()
    _ = try await client.createConversation(
      conversationID, Date(timeIntervalSince1970: 0))
    let earlier = answerMessage(narration: "Earlier", at: 10)
    let latest = answerMessage(narration: "Latest", at: 20)
    try await client.appendMessage(conversationID, earlier)
    try await client.appendMessage(conversationID, latest)
    let oldContext = FollowUpSuggestionContext(
      sourceAssistantMessageID: earlier.id,
      question: "Earlier", standaloneQuestion: "Earlier",
      narration: "Earlier", result: QueryResult(columns: [], rows: []))
    let latestContext = FollowUpSuggestionContext(
      sourceAssistantMessageID: latest.id,
      question: "Latest", standaloneQuestion: "Latest",
      narration: "Latest", result: QueryResult(columns: [], rows: []))
    let newer = PreparedFollowUpBatch(
      sourceAssistantMessageID: latest.id, context: latestContext,
      status: .completed, updatedAt: Date(timeIntervalSince1970: 20))
    let older = PreparedFollowUpBatch(
      sourceAssistantMessageID: earlier.id, context: oldContext,
      updatedAt: Date(timeIntervalSince1970: 30))
    try await client.saveFollowUpBatch(conversationID, newer)
    // A batch whose source answer is no longer the latest message is stale.
    await #expect(throws: HistoryStoreError.staleFollowUpBatch) {
      try await client.saveFollowUpBatch(conversationID, older)
    }
    #expect(try await client.loadConversation(conversationID).followUpBatch == newer)
    // A late `.preparing` write can never regress the completed batch.
    let latePreparing = PreparedFollowUpBatch(
      sourceAssistantMessageID: latest.id, context: latestContext,
      updatedAt: newer.updatedAt)
    await #expect(throws: HistoryStoreError.staleFollowUpBatch) {
      try await client.saveFollowUpBatch(conversationID, latePreparing)
    }
    #expect(try await client.loadConversation(conversationID).followUpBatch == newer)
  }

  @Test func preparedAnswerUpdateKeepsPositionAndLateAppendCannotRegressIt() async throws {
    let client = try makeClient(temporaryDatabaseURL())
    let conversationID = UUID()
    let sourceID = UUID()
    let prepared = preparedFollowUp(sourceMessageID: sourceID)
    _ = try await client.createConversation(
      conversationID, Date(timeIntervalSince1970: 0))
    try await client.appendMessage(
      conversationID, userMessage(prepared.question, at: 10))
    let provisional = ChatMessage(
      id: UUID(), role: .assistant, body: .preparedAnswer(prepared),
      createdAt: Date(timeIntervalSince1970: 11))
    try await client.appendMessage(conversationID, provisional)
    var final = provisional
    final.body = .answer(
      result: prepared.result,
      narration: "One matching row.",
      sql: prepared.sql,
      notice: nil)
    try await client.updateMessage(conversationID, final)
    try await client.appendMessage(conversationID, provisional)

    let messages = try await client.loadConversation(conversationID).messages
    #expect(messages.count == 2)
    #expect(messages.last == final)
    #expect(try await client.search("matching row").count == 1)
    #expect(try await client.search("compare by fund").count == 1)
  }

  @Test func preparedAnswerFinalUpdateCanWinTheProvisionalInsertRace() async throws {
    let client = try makeClient(temporaryDatabaseURL())
    let conversationID = UUID()
    let prepared = preparedFollowUp(sourceMessageID: UUID())
    _ = try await client.createConversation(
      conversationID, Date(timeIntervalSince1970: 0))
    try await client.appendMessage(
      conversationID, userMessage(prepared.question, at: 10))
    let provisional = ChatMessage(
      id: UUID(), role: .assistant, body: .preparedAnswer(prepared),
      createdAt: Date(timeIntervalSince1970: 11))
    var final = provisional
    final.body = .answer(
      result: prepared.result,
      narration: "The final narration won.",
      sql: prepared.sql,
      notice: nil)

    // Reproduce the reducer ordering where finalization reaches SQLite before
    // the independently scheduled provisional append.
    try await client.updateMessage(conversationID, final)
    try await client.appendMessage(conversationID, provisional)

    let messages = try await client.loadConversation(conversationID).messages
    #expect(messages.count == 2)
    #expect(messages.last == final)
    #expect(try await client.search("final narration").count == 1)
  }

  @Test func resultPresentationPatchCannotRegressFinalizedPayload() async throws {
    let client = try makeClient(temporaryDatabaseURL())
    let conversationID = UUID()
    let prepared = preparedFollowUp(sourceMessageID: UUID())
    _ = try await client.createConversation(
      conversationID, Date(timeIntervalSince1970: 0))
    let provisional = ChatMessage(
      id: UUID(), role: .assistant, body: .preparedAnswer(prepared),
      createdAt: Date(timeIntervalSince1970: 11))
    try await client.appendMessage(conversationID, provisional)

    var final = provisional
    final.body = .answer(
      result: prepared.result,
      narration: "The finalized narration must survive.",
      sql: prepared.sql,
      notice: nil)
    try await client.updateMessage(conversationID, final)

    var stalePresentationWrite = provisional
    stalePresentationWrite.resultPresentation = ResultPresentationPreference(
      mode: .table, specificationID: chartTestRecommendationID("policy|table"))
    try await client.updateResultPresentation(
      conversationID, stalePresentationWrite)

    let stored = try #require(
      try await client.loadConversation(conversationID).messages.last)
    guard case .answer(_, let narration, _, _) = stored.body else {
      Issue.record("Expected the finalized answer payload to survive")
      return
    }
    #expect(narration == "The finalized narration must survive.")
    #expect(stored.resultPresentation == stalePresentationWrite.resultPresentation)
    #expect(try await client.search("finalized narration").count == 1)
  }

  @Test func terminalUpdatePreservesANewerPresentationPreference() async throws {
    let client = try makeClient(temporaryDatabaseURL())
    let conversationID = UUID()
    _ = try await client.createConversation(
      conversationID, Date(timeIntervalSince1970: 0))
    let original = answerMessage(
      narration: "Initial narration.", at: 10)
    try await client.appendMessage(conversationID, original)

    var preferenceWrite = original
    preferenceWrite.resultPresentation = ResultPresentationPreference(
      mode: .table, specificationID: chartTestRecommendationID("policy|table"))
    try await client.updateResultPresentation(conversationID, preferenceWrite)

    var staleWholeMessage = original
    staleWholeMessage.body = .answer(
      result: QueryResult(columns: ["n"], rows: [[.integer(2)]]),
      narration: "Recovered final narration.",
      sql: "SELECT 2",
      notice: nil)
    try await client.persistTerminalTurn(
      conversationID, original.id, staleWholeMessage, true, [])

    let stored = try #require(
      try await client.loadConversation(conversationID).messages.last)
    #expect(stored.resultPresentation == preferenceWrite.resultPresentation)
    guard case .answer(let result, let narration, let sql, _) = stored.body else {
      Issue.record("Expected the recovered whole-message body")
      return
    }
    #expect(result.rows == [[.integer(2)]])
    #expect(narration == "Recovered final narration.")
    #expect(sql == "SELECT 2")
  }

  @Test func wholeMessageUpdatePreservesANewerPresentationPreference() async throws {
    let client = try makeClient(temporaryDatabaseURL())
    let conversationID = UUID()
    _ = try await client.createConversation(
      conversationID, Date(timeIntervalSince1970: 0))
    let original = answerMessage(
      narration: "Initial narration.", at: 10)
    try await client.appendMessage(conversationID, original)

    var preferenceWrite = original
    preferenceWrite.resultPresentation = ResultPresentationPreference(
      mode: .table, specificationID: chartTestRecommendationID("policy|table"))
    try await client.updateResultPresentation(conversationID, preferenceWrite)

    var staleWholeMessage = original
    staleWholeMessage.body = .answer(
      result: QueryResult(columns: ["n"], rows: [[.integer(2)]]),
      narration: "Recovered final narration.",
      sql: "SELECT 2",
      notice: nil)
    try await client.updateMessage(conversationID, staleWholeMessage)

    let stored = try #require(
      try await client.loadConversation(conversationID).messages.last)
    #expect(stored.resultPresentation == preferenceWrite.resultPresentation)
    guard case .answer(let result, let narration, let sql, _) = stored.body else {
      Issue.record("Expected the recovered whole-message body")
      return
    }
    #expect(result.rows == [[.integer(2)]])
    #expect(narration == "Recovered final narration.")
    #expect(sql == "SELECT 2")
  }

  @Test func wholeMessageUpdateRepairsAnUndecodableStoredPayload() async throws {
    let url = temporaryDatabaseURL()
    let client = try makeClient(url)
    let conversationID = UUID()
    _ = try await client.createConversation(
      conversationID, Date(timeIntervalSince1970: 0))
    let original = answerMessage(narration: "Legacy narration.", at: 10)
    try await client.appendMessage(conversationID, original)

    let database = try DatabaseQueue(path: url.path)
    try await database.write { db in
      try db.execute(
        sql: "UPDATE message SET payload = ? WHERE id = ?",
        arguments: ["{not-valid-json", original.id.uuidString])
    }

    var final = original
    final.body = .answer(
      result: QueryResult(columns: ["n"], rows: [[.integer(2)]]),
      narration: "Recovered final narration.",
      sql: "SELECT 2",
      notice: nil)
    try await client.updateMessage(conversationID, final)

    let stored = try #require(
      try await client.loadConversation(conversationID).messages.last)
    #expect(stored == final)
    #expect(try await client.search("recovered final").count == 1)
  }

  @Test func resultPresentationUpdateRepairsAnUndecodableStoredPayload() async throws {
    let url = temporaryDatabaseURL()
    let client = try makeClient(url)
    let conversationID = UUID()
    _ = try await client.createConversation(
      conversationID, Date(timeIntervalSince1970: 0))
    var message = answerMessage(narration: "Recovered presentation.", at: 10)
    try await client.appendMessage(conversationID, message)
    let messageID = message.id

    let database = try DatabaseQueue(path: url.path)
    try await database.write { db in
      try db.execute(
        sql: "UPDATE message SET payload = ? WHERE id = ?",
        arguments: ["{not-valid-json", messageID.uuidString])
    }

    message.resultPresentation = ResultPresentationPreference(
      mode: .table, specificationID: chartTestRecommendationID("policy|table"))
    try await client.updateResultPresentation(conversationID, message)

    let stored = try #require(
      try await client.loadConversation(conversationID).messages.last)
    #expect(stored == message)
    #expect(try await client.search("recovered presentation").count == 1)
  }

  @Test func turnPersistenceCommitsTranscriptEventsAndJournalAtomically() async throws {
    let client = try makeClient(temporaryDatabaseURL())
    let conversationID = UUID()
    _ = try await client.createConversation(
      conversationID, Date(timeIntervalSince1970: 0))
    let question = userMessage("Which fund leads?", at: 10)
    try await client.persistUserTurn(
      conversationID, question, QuestionSubmission(question: "Which fund leads?"), question.createdAt, nil)

    var snapshot = try await client.loadConversation(conversationID)
    #expect(snapshot.messages == [question])
    #expect(snapshot.interruptedTurn?.question == "Which fund leads?")

    let answer = answerMessage(narration: "Core leads.", at: 20)
    try await client.persistTerminalTurn(
      conversationID, question.id, answer, false, ["{\"turn\":\"finished\"}"])

    snapshot = try await client.loadConversation(conversationID)
    #expect(snapshot.messages == [question, answer])
    #expect(snapshot.interruptedTurn == nil)

    // A Stop path can win the race to persist this user message. A late copy
    // of the original effect must remain idempotent and must not reopen the
    // journal that terminal persistence just closed.
    try await client.persistUserTurn(
      conversationID, question, QuestionSubmission(question: "Which fund leads?"), question.createdAt, nil)
    snapshot = try await client.loadConversation(conversationID)
    #expect(snapshot.messages == [question, answer])
    #expect(snapshot.interruptedTurn == nil)

    let exportURL = try await client.exportJSONL(conversationID)
    #expect(
      try String(contentsOf: exportURL, encoding: .utf8)
        == "{\"turn\":\"finished\"}\n")
  }

  @Test func scopeDiagnosisAtomicallyEnrichesMessageAndEventLog() async throws {
    let client = try makeClient(temporaryDatabaseURL())
    let conversationID = UUID()
    _ = try await client.createConversation(
      conversationID, Date(timeIntervalSince1970: 0))
    var telemetry = TurnTelemetry(originalQuestion: "Who manages it?")
    telemetry.failureReason = .generationExhausted
    let message = ChatMessage(
      id: UUID(),
      role: .assistant,
      body: .failedTurn(reason: .generationExhausted, scopeVerdict: nil),
      createdAt: Date(timeIntervalSince1970: 10),
      devInfo: telemetry)
    let terminalLine = try PipelineEvent.turnFinished(
      outcome: .failed(reason: .generationExhausted),
      telemetry: telemetry
    ).jsonLine()
    try await client.persistTerminalTurn(
      conversationID, UUID(), message, false, [terminalLine])

    let verdict = ScopeVerdictRecord(
      verdict: .inDomainButNotTracked,
      missingSubject: "property managers")
    let diagnosisLine = try PipelineEvent.scopeDiagnosisFinished(
      sourceAssistantMessageID: message.id,
      verdict: verdict
    ).jsonLine()
    try await client.persistScopeDiagnosis(
      conversationID, message.id, verdict, diagnosisLine)

    let stored = try #require(
      try await client.loadConversation(conversationID).messages.last)
    guard case .failedTurn(let reason, let storedVerdict) = stored.body else {
      Issue.record("Expected the failed message to remain a failed message")
      return
    }
    #expect(reason == .generationExhausted)
    #expect(storedVerdict == verdict)
    #expect(stored.devInfo?.scopeVerdict == verdict)

    let exportURL = try await client.exportJSONL(conversationID)
    let exportedLines = try String(contentsOf: exportURL, encoding: .utf8)
      .split(separator: "\n")
    #expect(exportedLines.count == 2)
    guard
      case .scopeDiagnosisFinished(let sourceID, let exportedVerdict) =
        try JSONDecoder().decode(
          PipelineEvent.self,
          from: Data(exportedLines[1].utf8))
    else {
      Issue.record("Expected scope diagnosis as the second append-only event")
      return
    }
    #expect(sourceID == message.id)
    #expect(exportedVerdict == verdict)
  }

  @Test func preparedSuggestionTextAndProvisionalResultsAreNotSearchable() async throws {
    let client = try makeClient(temporaryDatabaseURL())
    let conversationID = UUID()
    let sourceID = UUID()
    let prepared = preparedFollowUp(sourceMessageID: sourceID)
    _ = try await client.createConversation(
      conversationID, Date(timeIntervalSince1970: 0))
    try await client.appendMessage(
      conversationID,
      ChatMessage(
        id: sourceID, role: .assistant, body: .preparedAnswer(prepared),
        createdAt: Date(timeIntervalSince1970: 9)))
    let batch = PreparedFollowUpBatch(
      sourceAssistantMessageID: sourceID,
      suggestions: [prepared],
      updatedAt: Date(timeIntervalSince1970: 10))
    try await client.saveFollowUpBatch(conversationID, batch)

    #expect(try await client.search("compare fund").isEmpty)
    #expect(try await client.search("SELECT").isEmpty)
  }

  // MARK: Support bundle

  @Test func supportBundleSourceCountsAndNormalizes() async throws {
    let client = try makeClient(temporaryDatabaseURL())
    let id = UUID()
    _ = try await client.createConversation(id, Date(timeIntervalSince1970: 0))
    let question = userMessage("What's the value by fund?", at: 10)
    let reply = answerMessage(narration: "Four funds found.", at: 20)
    try await client.appendMessage(id, question)
    try await client.appendMessage(id, reply)
    try await client.appendEvents(id, reply.id, ["{\"a\":1}", "{\"b\":2}"])
    try await client.saveDraft(id, "next question draft")
    try await client.saveFeedback(
      id,
      AnswerFeedback(
        messageID: reply.id, verdict: .helpful,
        updatedAt: Date(timeIntervalSince1970: 30)))

    let source = try await client.supportBundleSource()

    #expect(source.conversationCount == 1)
    #expect(source.messageCount == 2)
    #expect(source.eventLineCount == 2)
    #expect(source.feedbackCount == 1)
    #expect(
      FileManager.default.fileExists(atPath: source.databaseSnapshotURL.path))
    let conversations = String(decoding: source.conversationsJSON, as: UTF8.self)
    #expect(conversations.contains("next question draft"))
    let messages = String(decoding: source.messagesJSON, as: UTF8.self)
    #expect(messages.contains("Four funds found."))
    #expect(
      try JSONDecoder().decode(
        [PreparedFollowUpBatch].self,
        from: source.followUpsJSON
      ).isEmpty)
  }

  @Test func supportBundleInventoryIncludesCoreFilesAndExclusions() {
    let source = SupportBundleSource(
      databaseSnapshotURL: FileManager.default.temporaryDirectory,
      conversationsJSON: Data("[]".utf8),
      messagesJSON: Data("[]".utf8),
      eventsJSONL: Data(),
      feedbackJSON: Data("[]".utf8),
      conversationCount: 0,
      messageCount: 0,
      eventLineCount: 0,
      feedbackCount: 0)

    let files = SupportBundleBuilder.inventory(
      source: source,
      diagnosticsText: "log line\n",
      modelManifestJSON: Data("{}".utf8),
      modelReceiptJSON: Data("{}".utf8),
      modelPreparationJSON: Data("{}".utf8))
    let names = files.map(\.name)
    #expect(names.contains("conversations.json"))
    #expect(names.contains("messages.json"))
    #expect(names.contains("events.jsonl"))
    #expect(names.contains("feedback.json"))
    #expect(names.contains("prepared-follow-ups.json"))
    #expect(names.contains("diagnostics.txt"))
    #expect(names.contains("model-manifest.json"))
    #expect(names.contains("production-model-receipt.json"))
    #expect(names.contains("model-preparation.json"))
    // The weights and the portfolio database never join the inventory.
    #expect(!names.contains { $0.contains("safetensors") || $0.contains("creg.sqlite") })

    let exclusions = SupportBundleBuilder.exclusions(
      portfolioDatabaseSHA256: "abc123", hasModelReceipt: true)
    #expect(exclusions.map(\.name) == ["model-weights", "portfolio-database"])
    #expect(exclusions.last?.sha256 == "abc123")
  }

  @Test func supportBundleBuildProducesZipWithManifest() async throws {
    let client = try makeClient(temporaryDatabaseURL())
    let id = UUID()
    _ = try await client.createConversation(id, Date(timeIntervalSince1970: 0))
    try await client.appendMessage(id, userMessage("hello", at: 5))
    let source = try await client.supportBundleSource()

    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("creg-bundle-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: scratch, withIntermediateDirectories: true)
    let export = try SupportBundleBuilder.build(
      source: source,
      context: SupportBundleBuilder.Context(
        appVersion: "2.0",
        buildNumber: "42",
        buildChannel: "beta",
        modelRuntimeContract: ModelRuntimeContract(
          version: 1,
          sourceRevision: String(repeating: "a", count: 40),
          sourceDirty: false),
        modelIdentity: (key: "test-model", revision: "deadbeef"),
        runtimeMode: .compatibility,
        createdAt: Date(timeIntervalSince1970: 100)),
      bundledModelManifest: nil,
      bundledModelReceipt: nil,
      bundledPortfolioDatabase: nil,
      diagnosticsText: "line\n",
      scratchDirectory: scratch)

    #expect(FileManager.default.fileExists(atPath: export.url.path))
    let size =
      try FileManager.default
      .attributesOfItem(atPath: export.url.path)[.size] as? Int ?? 0
    #expect(size > 0)
    #expect(export.manifest.appVersion == "2.0")
    #expect(export.manifest.modelKey == "test-model")
    #expect(export.manifest.buildChannel == "beta")
    #expect(export.manifest.modelRuntimeContractVersion == 1)
    #expect(export.manifest.sourceRevision == String(repeating: "a", count: 40))
    #expect(export.manifest.sourceDirty == false)
    #expect(export.manifest.runtimeMode == .compatibility)
    #expect(!export.manifest.isEvaluated)
    #expect(export.manifest.conversationCount == 1)
    let entryPaths = export.manifest.entries.map(\.path)
    #expect(entryPaths.contains("history-snapshot.sqlite"))
    #expect(entryPaths.contains("conversations.json"))
    #expect(
      export.manifest.exclusions.map(\.name)
        == ["model-weights", "portfolio-database"])
    #expect(export.manifest.entries.allSatisfy { $0.sha256.count == 64 })
  }

  @Test func failedSupportBundleBuildRemovesTheHistorySnapshot() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "creg-bundle-failure-test-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    let snapshot = directory.appendingPathComponent("history.sqlite")
    try Data("private conversation history".utf8).write(to: snapshot)
    let invalidScratch = directory.appendingPathComponent("not-a-directory")
    try Data("file".utf8).write(to: invalidScratch)
    let source = SupportBundleSource(
      databaseSnapshotURL: snapshot,
      conversationsJSON: Data("[]".utf8),
      messagesJSON: Data("[]".utf8),
      eventsJSONL: Data(),
      feedbackJSON: Data("[]".utf8),
      conversationCount: 0,
      messageCount: 0,
      eventLineCount: 0,
      feedbackCount: 0)

    #expect(throws: (any Error).self) {
      try SupportBundleBuilder.build(
        source: source,
        context: SupportBundleBuilder.Context(
          appVersion: "2.0",
          buildNumber: "42",
          modelIdentity: (key: "test", revision: "test"),
          createdAt: Date(timeIntervalSince1970: 1)),
        bundledModelManifest: nil,
        bundledModelReceipt: nil,
        bundledPortfolioDatabase: nil,
        diagnosticsText: "",
        scratchDirectory: invalidScratch)
    }
    #expect(!FileManager.default.fileExists(atPath: snapshot.path))
  }

  // MARK: Title normalization

  @Test func autoTitleCollapsesWhitespaceAndCapsLength() {
    #expect(HistoryStore.autoTitle(from: "  a \n b\t c  ") == "a b c")
    let long = String(repeating: "word ", count: 40)
    #expect(HistoryStore.autoTitle(from: long).count == HistoryStore.titleLimit)
  }
}
