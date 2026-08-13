import Foundation
import Testing

@testable import CREGEngine

private actor FollowUpCalls {
  var generations = 0
  var validations = 0
  var executions = 0
  var narrations = 0

  func generated() { generations += 1 }
  func validated() { validations += 1 }
  func executed() { executions += 1 }
  func narrated() { narrations += 1 }
}

@Suite struct PreparedFollowUpTests {
  private static let model = ModelReference(
    key: "test-model",
    repository: "test/model",
    revision: "0123456789abcdef",
    quantization: "4-bit")

  private static func configuration() -> QueryPipeline.Configuration {
    .init(
      model: model,
      gcd: .on,
      productionTemperature: 0,
      maxTokens: 128,
      gateSensitivity: 0,
      maxRepairAttempts: 2,
      selfConsistencyN: 1,
      sampleTemperature: 0,
      alwaysVote: false)
  }

  private static let result = QueryResult(
    columns: ["fund", "value"],
    rows: [[.text("Core Fund"), .real(42_000_000)]],
    elapsedMicroseconds: 100)

  private static func context() -> FollowUpSuggestionContext {
    FollowUpSuggestionContext(
      sourceAssistantMessageID: UUID(1),
      question: "What is portfolio value by fund?",
      standaloneQuestion: "What is portfolio value by fund?",
      narration: "Core Fund leads at $42M.",
      result: result)
  }

  private static func fm(
    suggestions: [String] = [
      "Which properties contribute the most value?",
      "How does value compare with acquisition cost?",
      "What is outstanding debt by fund?",
    ],
    calls: FollowUpCalls? = nil
  ) -> FMClient {
    FMClient(
      availability: { .available },
      rewrite: { question, _ in question },
      gate: { _, _ in .proceed },
      narrate: { _, _ in
        if let calls { await calls.narrated() }
        return "Prepared narration."
      },
      suggestFollowUps: { _, _ in suggestions })
  }

  @Test func normalizesAndDeduplicatesSuggestedQuestions() {
    let questions = normalizedFollowUpQuestions(
      [
        "  What is debt by fund  ",
        "what is debt by fund?",
        "What is portfolio value by fund?",
        "Which properties lead?",
        "How do values compare?",
        "A fourth question?",
      ],
      excluding: ["What is portfolio value by fund?"])

    #expect(questions == [
      "What is debt by fund?",
      "Which properties lead?",
      "How do values compare?",
    ])
  }

  @Test func preparationEmitsProgressiveValidatedExecutedSubset() async {
    let calls = FollowUpCalls()
    let db = DatabaseClient(
      fingerprint: "snapshot-v1",
      validate: { _ in
        await calls.validated()
        return SQLValidationReport()
      },
      execute: { sql in
        await calls.executed()
        if sql.contains("empty") {
          return QueryResult(columns: ["value"], rows: [])
        }
        return Self.result
      })
    let pipeline = QueryPipeline.live(
      fm: Self.fm(
        suggestions: ["First?", "Empty?", "Third?"],
        calls: calls),
      sqlGen: SQLGenClient { request in
        await calls.generated()
        let sql = request.question == "Empty?" ? "SELECT empty" : "SELECT 1"
        return SQLGeneration(
          sql: sql, tokensPerSecond: 1, modelName: "test")
      },
      db: db,
      serializer: InferenceSerializer(),
      configuration: Self.configuration(),
      uuid: { UUID(9) },
      now: { Date(timeIntervalSince1970: 10) })

    var events: [FollowUpPreparationEvent] = []
    for await event in pipeline.prepareFollowUps(Self.context()) {
      events.append(event)
    }
    let prepared = events.compactMap { event -> PreparedFollowUp? in
      guard case .prepared(let value) = event else { return nil }
      return value
    }
    #expect(prepared.map(\.question) == ["First?", "Third?"])
    #expect(events.contains(.rejected(rank: 2, reason: .unhelpfulResult)))
    #expect(await calls.generations == 3)
    #expect(await calls.validations == 3)
    #expect(await calls.executions == 3)
  }

  @Test func preparationStopsAfterTheExistingTwoBoundedRepairs() async {
    let calls = FollowUpCalls()
    let issue = SQLValidationIssue(
      kind: .binding,
      disposition: .repairable,
      message: "no such column")
    let pipeline = QueryPipeline.live(
      fm: Self.fm(suggestions: ["Needs repair?"], calls: calls),
      sqlGen: SQLGenClient { request in
        await calls.generated()
        return SQLGeneration(
          sql: "SELECT bad_\(request.candidateID.rawValue)",
          tokensPerSecond: 1,
          modelName: "test")
      },
      db: DatabaseClient(
        fingerprint: "snapshot-v1",
        validate: { _ in
          await calls.validated()
          return SQLValidationReport(issue: issue)
        },
        execute: { _ in
          await calls.executed()
          return Self.result
        }),
      serializer: InferenceSerializer(),
      configuration: Self.configuration())

    let events = await Array(pipeline.prepareFollowUps(Self.context()))

    #expect(await calls.generations == 3)
    #expect(await calls.validations == 3)
    #expect(await calls.executions == 0)
    #expect(events.contains(.rejected(rank: 1, reason: .validationFailed)))
  }

  @Test func cacheHitShowsResultBeforeNarrationWithoutGenerationOrExecution() async {
    let calls = FollowUpCalls()
    let sql = "SELECT 1"
    var telemetry = TurnTelemetry(originalQuestion: "Prepared?")
    telemetry.runtimeMode = .evaluated
    let prepared = PreparedFollowUp(
      id: UUID(2),
      sourceAssistantMessageID: UUID(1),
      rank: 1,
      question: "Prepared?",
      sql: sql,
      result: Self.result,
      preparationTelemetry: telemetry,
      provenance: PreparedQueryProvenance(
        modelKey: Self.model.key,
        modelRevision: Self.model.revision,
        runtimeMode: .evaluated,
        preparationPolicyVersion: "prepared-follow-up-v1|binding-repair-v2",
        databaseFingerprint: "snapshot-v1",
        sqlFingerprint: PreparedFollowUpIntegrity.fingerprint(sql: sql),
        resultFingerprint: PreparedFollowUpIntegrity.fingerprint(result: Self.result)),
      createdAt: Date(timeIntervalSince1970: 0))
    let pipeline = QueryPipeline.live(
      fm: Self.fm(calls: calls),
      sqlGen: SQLGenClient { _ in
        await calls.generated()
        return SQLGeneration(
          sql: "SELECT fallback", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient(
        fingerprint: "snapshot-v1",
        validate: { _ in
          await calls.validated()
          return SQLValidationReport()
        },
        execute: { _ in
          await calls.executed()
          return Self.result
        }),
      serializer: InferenceSerializer(),
      configuration: Self.configuration())

    var events: [PipelineEvent] = []
    for await event in pipeline.runPrepared(prepared, []) {
      events.append(event)
    }
    let previewIndex = events.firstIndex {
      if case .preparedResultReady = $0 { true } else { false }
    }
    let narrationIndex = events.firstIndex(of: .narrationStarted)
    #expect(previewIndex != nil)
    #expect(narrationIndex != nil)
    #expect(previewIndex! < narrationIndex!)
    #expect(await calls.generations == 0)
    #expect(await calls.executions == 0)
    #expect(await calls.validations == 1)
    #expect(await calls.narrations == 1)
    guard case .turnFinished(.answered, let finalTelemetry) = events.last else {
      Issue.record("Expected prepared answer")
      return
    }
    #expect(finalTelemetry.preparedCacheHit == true)
    #expect(finalTelemetry.queryOrigin == .preparedFollowUp)
  }

  @Test func tamperedCacheFallsBackToFreeFormGeneration() async {
    let calls = FollowUpCalls()
    let prepared = PreparedFollowUp(
      id: UUID(2),
      sourceAssistantMessageID: UUID(1),
      rank: 1,
      question: "Prepared?",
      sql: "SELECT tampered",
      result: Self.result,
      preparationTelemetry: TurnTelemetry(originalQuestion: "Prepared?"),
      provenance: PreparedQueryProvenance(
        modelKey: Self.model.key,
        modelRevision: Self.model.revision,
        runtimeMode: .evaluated,
        preparationPolicyVersion: "prepared-follow-up-v1|binding-repair-v2",
        databaseFingerprint: "snapshot-v1",
        sqlFingerprint: "wrong",
        resultFingerprint: PreparedFollowUpIntegrity.fingerprint(result: Self.result)),
      createdAt: Date(timeIntervalSince1970: 0))
    let pipeline = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: SQLGenClient { _ in
        await calls.generated()
        return SQLGeneration(
          sql: "SELECT fallback", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient(
        fingerprint: "snapshot-v1",
        validate: { _ in SQLValidationReport() },
        execute: { _ in
          await calls.executed()
          return Self.result
        }),
      serializer: InferenceSerializer(),
      configuration: Self.configuration())

    var events: [PipelineEvent] = []
    for await event in pipeline.runPrepared(prepared, []) {
      events.append(event)
    }
    #expect(await calls.generations == 1)
    #expect(await calls.executions == 1)
    #expect(!events.contains {
      if case .preparedResultReady = $0 { true } else { false }
    })
    guard case .turnFinished(_, let telemetry) = events.last else {
      Issue.record("Expected a free-form fallback outcome")
      return
    }
    #expect(telemetry.preparedCacheHit == false)
    #expect(telemetry.preparedFollowUpID == prepared.id)
  }
}
