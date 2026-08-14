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

    // Recreate the pre-browser schema exactly as the old client wrote it.
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

    // Migrated content is searchable.
    let hits = try await client.search("vacancy")
    #expect(hits.map(\.conversationID) == [legacyID])
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

    try await client.beginTurnJournal(
      id, "Which loans mature soonest?", Date(timeIntervalSince1970: 50))
    var snapshot = try await client.loadConversation(id)
    #expect(snapshot.interruptedTurn?.question == "Which loans mature soonest?")
    #expect(
      snapshot.interruptedTurn?.interruptedAt == Date(timeIntervalSince1970: 50))

    try await client.endTurnJournal(id)
    snapshot = try await client.loadConversation(id)
    #expect(snapshot.interruptedTurn == nil)
  }

  // MARK: Prepared follow-ups

  @Test func preparedBatchRoundTripsProgressivelyAndClears() async throws {
    let client = try makeClient(temporaryDatabaseURL())
    let conversationID = UUID()
    let sourceID = UUID()
    _ = try await client.createConversation(
      conversationID, Date(timeIntervalSince1970: 0))
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
      mode: .table, specificationID: "policy|table")
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

  @Test func preparedSuggestionTextAndProvisionalResultsAreNotSearchable() async throws {
    let client = try makeClient(temporaryDatabaseURL())
    let conversationID = UUID()
    let sourceID = UUID()
    let prepared = preparedFollowUp(sourceMessageID: sourceID)
    _ = try await client.createConversation(
      conversationID, Date(timeIntervalSince1970: 0))
    let batch = PreparedFollowUpBatch(
      sourceAssistantMessageID: sourceID,
      suggestions: [prepared],
      updatedAt: Date(timeIntervalSince1970: 10))
    try await client.saveFollowUpBatch(conversationID, batch)
    try await client.appendMessage(
      conversationID,
      ChatMessage(
        id: UUID(), role: .assistant, body: .preparedAnswer(prepared),
        createdAt: Date(timeIntervalSince1970: 11)))

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
