import CREGTestSupport
import Foundation
import Testing

@testable import CREGEngine

private actor FollowUpCalls {
  var proposals = 0
  var generations = 0
  var validations = 0
  var executions = 0
  var narrations = 0
  var fallbackHistoryCounts: [Int] = []

  func proposed() -> Int {
    proposals += 1
    return proposals
  }
  func generated() { generations += 1 }
  func validated() { validations += 1 }
  func nextValidation() -> Int {
    validations += 1
    return validations
  }
  func executed() { executions += 1 }
  func narrated() { narrations += 1 }
  func recordedFallback(historyCount: Int) {
    fallbackHistoryCounts.append(historyCount)
  }
}

private enum FollowUpTestError: Error {
  case failed
}

@Suite struct PreparedFollowUpTests {
  private static let model = ModelReference(
    key: "test-model",
    repository: "test/model",
    revision: "0123456789abcdef",
    quantization: "4-bit")

  private static func configuration(
    deadlines: PipelineDeadlines = PipelineDeadlines()
  ) -> QueryPipeline.Configuration {
    .init(
      model: model,
      gcd: .on,
      productionTemperature: 0,
      maxTokens: 128,
      gateSensitivity: 0,
      maxRepairAttempts: 2,
      selfConsistencyN: 1,
      sampleTemperature: 0,
      alwaysVote: false,
      deadlines: deadlines)
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

  private static func prepared(
    question: String,
    rank: Int,
    runtimeMode: ModelRuntimeMode = .evaluated
  ) -> PreparedFollowUp {
    let sql = "SELECT 1"
    let telemetry = TurnTelemetry(
      originalQuestion: question,
      runtimeMode: runtimeMode)
    return PreparedFollowUp(
      id: UUID(),
      sourceAssistantMessageID: UUID(1),
      rank: rank,
      question: question,
      sql: sql,
      result: result,
      preparationTelemetry: telemetry,
      provenance: PreparedQueryProvenance(
        modelKey: model.key,
        modelRevision: model.revision,
        runtimeMode: runtimeMode,
        preparationPolicyVersion: "prepared-follow-up-v1|binding-repair-v2",
        databaseFingerprint: "snapshot-v1",
        sqlFingerprint: PreparedFollowUpIntegrity.fingerprint(sql: sql),
        resultFingerprint: PreparedFollowUpIntegrity.fingerprint(result: result)),
      createdAt: Date(timeIntervalSince1970: TimeInterval(rank)))
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

  private static func rejection(
    in events: [FollowUpPreparationEvent],
    rank: Int,
    reason: FollowUpPreparationRejection
  ) -> (found: Bool, telemetry: FollowUpRejectionTelemetry?) {
    for event in events {
      guard
        case .rejected(
          let eventRank,
          let eventReason,
          let telemetry) = event,
        eventRank == rank,
        eventReason == reason
      else { continue }
      return (true, telemetry)
    }
    return (false, nil)
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

    #expect(
      questions == [
        "What is debt by fund?",
        "Which properties lead?",
        "How do values compare?",
      ])
  }

  @Test func proposalAndBatchUseTheSameQuestionIdentity() {
    let questions = normalizedFollowUpQuestions(
      ["AB C?", "A BC?"],
      excluding: [])
    #expect(questions == ["AB C?"])

    let batch = PreparedFollowUpBatch(
      sourceAssistantMessageID: UUID(1),
      suggestions: [
        Self.prepared(question: "AB C?", rank: 1),
        Self.prepared(question: "A BC?", rank: 2),
      ],
      updatedAt: Date(timeIntervalSince1970: 1))
    #expect(batch.suggestions.map(\.question) == ["AB C?"])
  }

  @Test func normalizedQuestionLengthIncludesAnAppendedQuestionMark() {
    let accepted = String(repeating: "a", count: 179)
    let rejected = String(repeating: "b", count: 180)

    #expect(
      normalizedFollowUpQuestions([accepted, rejected], excluding: [])
        == [accepted + "?"])
  }

  @Test func resumedBatchesStayCappedWithUniqueRanksAndQuestions() {
    var batch = PreparedFollowUpBatch(
      sourceAssistantMessageID: UUID(1),
      suggestions: [
        Self.prepared(question: "First?", rank: 1),
        Self.prepared(question: "Different first?", rank: 1),
        Self.prepared(question: "Second?", rank: 2),
        Self.prepared(question: "Third?", rank: 3),
        Self.prepared(question: "Fourth?", rank: 4),
      ],
      updatedAt: Date(timeIntervalSince1970: 1))

    #expect(batch.suggestions.map(\.rank) == [1, 2, 3])
    #expect(batch.suggestions.map(\.question) == ["First?", "Second?", "Third?"])
    let appended = batch.appendIfEligible(
      Self.prepared(question: "Another?", rank: 4))
    #expect(!appended)
    #expect(batch.suggestions.count == PreparedFollowUpBatch.maximumSuggestionCount)
  }

  @Test func integrityFingerprintsAreTotalAndSQLIsCanonicalized() {
    let positiveInfinity = QueryResult(
      columns: ["value"], rows: [[.real(.infinity)]])
    let negativeInfinity = QueryResult(
      columns: ["value"], rows: [[.real(-.infinity)]])

    #expect(
      PreparedFollowUpIntegrity.fingerprint(result: positiveInfinity)
        != PreparedFollowUpIntegrity.fingerprint(result: negativeInfinity))
    #expect(
      PreparedFollowUpIntegrity.fingerprint(sql: "  SELECT 1\r\n")
        == PreparedFollowUpIntegrity.fingerprint(sql: "SELECT 1\n"))
    let slowerEquivalent = QueryResult(
      columns: Self.result.columns,
      rows: Self.result.rows,
      isTruncated: Self.result.isTruncated,
      elapsedMicroseconds: Self.result.elapsedMicroseconds + 10_000)
    #expect(
      PreparedFollowUpIntegrity.fingerprint(result: Self.result)
        == PreparedFollowUpIntegrity.fingerprint(result: slowerEquivalent))
  }

  @Test func streamingFileHashMatchesInMemoryHash() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("prepared-integrity-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: url) }
    let data = Data((0..<10_000).map { UInt8($0 % 251) })
    try data.write(to: url)

    #expect(
      try PreparedFollowUpIntegrity.sha256(contentsOf: url, chunkSize: 127)
        == PreparedFollowUpIntegrity.sha256(data))
  }

  @Test func streamingFileHashRejectsNonpositiveChunkSizes() {
    let url = URL(fileURLWithPath: #filePath)

    for chunkSize in [0, -1] {
      #expect(
        throws: PreparedFollowUpIntegrityError.invalidChunkSize(chunkSize)
      ) {
        try PreparedFollowUpIntegrity.sha256(
          contentsOf: url,
          chunkSize: chunkSize)
      }
    }
  }

  @Test func followUpEventsUseCanonicalJSONL() throws {
    let line = try FollowUpPreparationEvent.rejected(
      rank: 2, reason: .validationFailed
    ).jsonLine()
    #expect(line == #"{"rejected":{"rank":2,"reason":"validationFailed"}}"#)
    guard
      case .rejected(let legacyRank, let legacyReason, nil) =
        try JSONDecoder().decode(
          FollowUpPreparationEvent.self,
          from: Data(line.utf8))
    else {
      Issue.record("Expected legacy rejected events to decode without telemetry")
      return
    }
    #expect(legacyRank == 2)
    #expect(legacyReason == .validationFailed)
    #expect(
      try FollowUpPreparationEvent.proposalFailed(
        reason: .generationTimedOut
      ).jsonLine()
        == #"{"proposalFailed":{"reason":"generationTimedOut"}}"#)

    let telemetry = FollowUpRejectionTelemetry(
      timeoutStage: "validation",
      stageTimings: StageTimings(totalMicroseconds: 12_000),
      candidateCount: 1,
      failedCandidateCount: 1,
      lastCandidateGeneratedSQL: true,
      lastCandidateErrorPresent: true)
    let telemetryLine = try FollowUpPreparationEvent.rejected(
      rank: 1,
      reason: .validationTimedOut,
      telemetry: telemetry
    ).jsonLine()
    guard
      case .rejected(let rank, let reason, let decodedTelemetry) =
        try JSONDecoder().decode(
          FollowUpPreparationEvent.self,
          from: Data(telemetryLine.utf8))
    else {
      Issue.record("Expected rejected-candidate telemetry to round trip")
      return
    }
    #expect(rank == 1)
    #expect(reason == .validationTimedOut)
    #expect(decodedTelemetry?.timeoutStage == "validation")
    #expect(decodedTelemetry?.stageTimings.totalMicroseconds == 12_000)
    #expect(decodedTelemetry?.candidateCount == 1)
  }

  private static func failureContext(
    scopeVerdict: ScopeVerdictRecord? = nil
  ) -> FollowUpSuggestionContext {
    FollowUpSuggestionContext(
      sourceAssistantMessageID: UUID(1),
      question: "Who manages each property day to day?",
      standaloneQuestion: "Who manages each property day to day?",
      seed: .turnFailure(
        reason: .generationExhausted, scopeVerdict: scopeVerdict))
  }

  @Test func failureSeededPreparationStampsRecoveryOriginAndPolicy() async {
    let pipeline = QueryPipeline.live(
      fm: Self.fm(suggestions: ["Which fund holds the most value?"]),
      sqlGen: testSQLGenClient { _ in
        SQLGeneration(sql: "SELECT 1", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient(
        fingerprint: "snapshot-v1",
        execute: { _ in Self.result }),
      serializer: InferenceSerializer(),
      configuration: Self.configuration())

    let events = await Array(pipeline.prepareFollowUps(Self.failureContext()))

    let prepared = events.compactMap { event -> PreparedFollowUp? in
      guard case .prepared(let prepared) = event else { return nil }
      return prepared
    }
    #expect(!prepared.isEmpty)
    for suggestion in prepared {
      #expect(
        suggestion.preparationTelemetry.queryOrigin == .recoverySuggestion)
      #expect(
        suggestion.provenance.preparationPolicyVersion
          == PreparedQueryProvenance.recoverySuggestionPolicyVersion(
            repairPolicyVersion: Self.configuration().repairPolicyVersion))
      #expect(suggestion.result.rowCount > 0)
    }
  }

  @Test func failureSeededProposalFailureFallsBackToStarterQueries() async {
    let fm = FMClient(
      availability: { .available },
      rewrite: { question, _ in question },
      gate: { _, _ in .proceed },
      narrate: { _, _ in "unused" },
      suggestFollowUps: { _, _ in throw FollowUpTestError.failed })
    let pipeline = QueryPipeline.live(
      fm: fm,
      sqlGen: testSQLGenClient { _ in
        Issue.record("SQL generation must not run for starter fallback")
        return SQLGeneration(
          sql: "SELECT 1", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient(
        fingerprint: "snapshot-v1",
        execute: { _ in Self.result }),
      serializer: InferenceSerializer(),
      configuration: Self.configuration())

    let events = await Array(pipeline.prepareFollowUps(Self.failureContext()))

    #expect(events.contains(.proposalFailed(reason: .generationFailed)))
    let prepared = events.compactMap { event -> PreparedFollowUp? in
      guard case .prepared(let prepared) = event else { return nil }
      return prepared
    }
    #expect(
      prepared.count == PreparedFollowUpBatch.maximumSuggestionCount)
    let starterQuestions = Set(StarterQueryID.allCases.map(\.question))
    for suggestion in prepared {
      #expect(starterQuestions.contains(suggestion.question))
      #expect(
        suggestion.preparationTelemetry.queryOrigin == .recoverySuggestion)
      #expect(suggestion.preparationTelemetry.selectionReason == .starterQuery)
      #expect(suggestion.result.rowCount > 0)
    }
    #expect(events.last == .finished)
  }

  @Test func outsideRealEstateVerdictSkipsFMAndOffersStarters() async {
    let fm = FMClient(
      availability: { .available },
      rewrite: { question, _ in question },
      gate: { _, _ in .proceed },
      narrate: { _, _ in "unused" },
      suggestFollowUps: { _, _ in
        Issue.record(
          "An out-of-domain question must not seed FM suggestion generation")
        return []
      })
    let pipeline = QueryPipeline.live(
      fm: fm,
      sqlGen: testSQLGenClient { _ in
        Issue.record("SQL generation must not run for starter fallback")
        return SQLGeneration(
          sql: "SELECT 1", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient(
        fingerprint: "snapshot-v1",
        execute: { _ in Self.result }),
      serializer: InferenceSerializer(),
      configuration: Self.configuration())

    let events = await Array(
      pipeline.prepareFollowUps(
        Self.failureContext(
          scopeVerdict: ScopeVerdictRecord(verdict: .outsideRealEstate))))

    #expect(
      events.contains(
        .started(
          candidateCount: PreparedFollowUpBatch.maximumSuggestionCount)))
    let prepared = events.compactMap { event -> PreparedFollowUp? in
      guard case .prepared(let prepared) = event else { return nil }
      return prepared
    }
    #expect(
      prepared.count == PreparedFollowUpBatch.maximumSuggestionCount)
    #expect(events.last == .finished)
  }

  @Test func answerSeededProposalFailureDoesNotFallBackToStarters() async {
    let fm = FMClient(
      availability: { .available },
      rewrite: { question, _ in question },
      gate: { _, _ in .proceed },
      narrate: { _, _ in "unused" },
      suggestFollowUps: { _, _ in throw FollowUpTestError.failed })
    let pipeline = QueryPipeline.live(
      fm: fm,
      sqlGen: testSQLGenClient { _ in
        SQLGeneration(sql: "SELECT 1", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient(
        fingerprint: "snapshot-v1",
        execute: { _ in Self.result }),
      serializer: InferenceSerializer(),
      configuration: Self.configuration())

    let events = await Array(pipeline.prepareFollowUps(Self.context()))

    #expect(events.contains(.proposalFailed(reason: .generationFailed)))
    let prepared = events.contains { event in
      if case .prepared = event { return true }
      return false
    }
    #expect(!prepared)
  }

  @Test func proposalFailuresAreDistinctFromAnEmptyProposalSet() async {
    let fm = FMClient(
      availability: { .available },
      rewrite: { question, _ in question },
      gate: { _, _ in .proceed },
      narrate: { _, _ in "unused" },
      suggestFollowUps: { _, _ in throw FollowUpTestError.failed })
    let pipeline = QueryPipeline.live(
      fm: fm,
      sqlGen: testSQLGenClient { _ in
        Issue.record("SQL generation must not run after proposal failure")
        return SQLGeneration(
          sql: "SELECT 1", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient(
        fingerprint: "snapshot-v1",
        execute: { _ in Self.result }),
      serializer: InferenceSerializer(),
      configuration: Self.configuration())

    let events = await Array(pipeline.prepareFollowUps(Self.context()))

    #expect(events.contains(.proposalFailed(reason: .generationFailed)))
    #expect(!events.contains(.started(candidateCount: 0)))
    #expect(events.last == .finished)
  }

  @Test func proposalReceivesTheLoadedSchemaPrompt() async {
    // The forwarding assertion lives inside the proposal closure, so the
    // confirmation is what proves the closure ran at all. Without it the
    // event assertions below also pass on the FM-unavailable path, which
    // yields the same .started(candidateCount: 0) without ever proposing.
    await confirmation("the loaded schema reaches the proposal") { proposed in
      let fm = FMClient(
        availability: { .available },
        rewrite: { question, _ in question },
        gate: { _, _ in .proceed },
        narrate: { _, _ in "unused" },
        suggestFollowUps: { _, schema in
          #expect(schema == "follow-up schema")
          proposed()
          return []
        })
      let pipeline = QueryPipeline.live(
        fm: fm,
        sqlGen: testSQLGenClient(
          schemaPrompt: { "follow-up schema" }
        ) { _ in
          Issue.record("SQL generation must not run for an empty proposal set")
          return SQLGeneration(
            sql: "SELECT 1", tokensPerSecond: 1, modelName: "test")
        },
        db: DatabaseClient(
          fingerprint: "snapshot-v1",
          execute: { _ in Self.result }),
        serializer: InferenceSerializer(),
        configuration: Self.configuration())

      let events = await Array(pipeline.prepareFollowUps(Self.context()))

      #expect(events.contains(.started(candidateCount: 0)))
      #expect(events.last == .finished)
    }
  }

  @Test func schemaPromptFailureStopsProposalAndIsReported() async {
    let fm = FMClient(
      availability: { .available },
      rewrite: { question, _ in question },
      gate: { _, _ in .proceed },
      narrate: { _, _ in "unused" },
      suggestFollowUps: { _, _ in
        Issue.record("Follow-up proposal must not run without a schema")
        return []
      })
    let pipeline = QueryPipeline.live(
      fm: fm,
      sqlGen: testSQLGenClient(
        schemaPrompt: { throw FollowUpTestError.failed }
      ) { _ in
        Issue.record("SQL generation must not run after schema loading fails")
        return SQLGeneration(
          sql: "SELECT 1", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient(
        fingerprint: "snapshot-v1",
        execute: { _ in Self.result }),
      serializer: InferenceSerializer(),
      configuration: Self.configuration())

    let events = await Array(pipeline.prepareFollowUps(Self.context()))

    #expect(events.contains(.proposalFailed(reason: .schemaLoadingFailed)))
    #expect(!events.contains(.started(candidateCount: 0)))
    #expect(events.last == .finished)
  }

  @Test func emptySchemaPromptStopsProposalAndIsReported() async {
    let pipeline = QueryPipeline.live(
      fm: Self.fm(suggestions: ["Must not be proposed?"]),
      sqlGen: testSQLGenClient(
        schemaPrompt: { " \n" }
      ) { _ in
        Issue.record("SQL generation must not run with an empty schema")
        return SQLGeneration(
          sql: "SELECT 1", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient(
        fingerprint: "snapshot-v1",
        execute: { _ in Self.result }),
      serializer: InferenceSerializer(),
      configuration: Self.configuration())

    let events = await Array(pipeline.prepareFollowUps(Self.context()))

    #expect(events.contains(.proposalFailed(reason: .schemaLoadingFailed)))
    #expect(!events.contains(.started(candidateCount: 1)))
    #expect(events.last == .finished)
  }

  @Test func proposalGenerationHasADeadline() async {
    let fm = FMClient(
      availability: { .available },
      rewrite: { question, _ in question },
      gate: { _, _ in .proceed },
      narrate: { _, _ in "unused" },
      suggestFollowUps: { _, _ in
        try await Task.sleep(for: .seconds(5))
        return ["Too late?"]
      })
    let pipeline = QueryPipeline.live(
      fm: fm,
      sqlGen: testSQLGenClient { _ in
        Issue.record("SQL generation must not run after proposal timeout")
        return SQLGeneration(
          sql: "SELECT 1", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient(
        fingerprint: "snapshot-v1",
        execute: { _ in Self.result }),
      serializer: InferenceSerializer(),
      configuration: Self.configuration(
        deadlines: PipelineDeadlines(
          generationSeconds: 0.01,
          wholeTurnSeconds: 1)))

    let events = await Array(pipeline.prepareFollowUps(Self.context()))

    #expect(events.contains(.proposalFailed(reason: .generationTimedOut)))
    #expect(events.last == .finished)
  }

  @Test func proposalTimeoutDoesNotQueueBehindTheCancelledInference() async {
    let calls = FollowUpCalls()
    let fm = FMClient(
      availability: { .available },
      rewrite: { question, _ in question },
      gate: { _, _ in .proceed },
      narrate: { _, _ in "unused" },
      suggestFollowUps: { _, _ in
        _ = await calls.proposed()
        try await Task.sleep(for: .seconds(5))
        return ["Too late?"]
      })
    let pipeline = QueryPipeline.live(
      fm: fm,
      sqlGen: testSQLGenClient { _ in
        SQLGeneration(sql: "SELECT 1", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient(
        fingerprint: "snapshot-v1",
        validate: { _ in SQLValidationReport() },
        execute: { _ in Self.result }),
      serializer: InferenceSerializer(),
      configuration: Self.configuration(
        deadlines: PipelineDeadlines(
          generationSeconds: 0.01,
          wholeTurnSeconds: 1)))

    let events = await Array(pipeline.prepareFollowUps(Self.context()))

    #expect(events.contains(.proposalFailed(reason: .generationTimedOut)))
    #expect(await calls.proposals == 1)
    #expect(events.last == .finished)
  }

  @Test func recoveryProposalTimeoutFallsBackToStarterQueries() async {
    let fm = FMClient(
      availability: { .available },
      rewrite: { question, _ in question },
      gate: { _, _ in .proceed },
      narrate: { _, _ in "unused" },
      suggestFollowUps: { _, _ in
        try await Task.sleep(for: .seconds(5))
        return ["Too late?"]
      })
    let pipeline = QueryPipeline.live(
      fm: fm,
      sqlGen: testSQLGenClient { _ in
        Issue.record("Starter recovery must not invoke SQL generation")
        return SQLGeneration(
          sql: "SELECT 1", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient(
        fingerprint: "snapshot-v1",
        validate: { _ in SQLValidationReport() },
        execute: { _ in Self.result }),
      serializer: InferenceSerializer(),
      configuration: Self.configuration(
        deadlines: PipelineDeadlines(
          generationSeconds: 0.05,
          wholeTurnSeconds: 1)))

    let events = await Array(
      pipeline.prepareFollowUps(Self.failureContext()))

    #expect(events.contains(.proposalFailed(reason: .generationTimedOut)))
    #expect(
      events.compactMap { event -> PreparedFollowUp? in
        guard case .prepared(let prepared) = event else { return nil }
        return prepared
      }.count == PreparedFollowUpBatch.maximumSuggestionCount)
    #expect(events.last == .finished)
  }

  @Test func unexpectedProposalCancellationIsReportedAsFailure() async {
    let fm = FMClient(
      availability: { .available },
      rewrite: { question, _ in question },
      gate: { _, _ in .proceed },
      narrate: { _, _ in "unused" },
      suggestFollowUps: { _, _ in throw CancellationError() })
    let pipeline = QueryPipeline.live(
      fm: fm,
      sqlGen: testSQLGenClient { _ in
        Issue.record("SQL generation must not run after proposal failure")
        return SQLGeneration(
          sql: "SELECT 1", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient(
        fingerprint: "snapshot-v1",
        execute: { _ in Self.result }),
      serializer: InferenceSerializer(),
      configuration: Self.configuration())

    let events = await Array(pipeline.prepareFollowUps(Self.context()))

    #expect(events.contains(.proposalFailed(reason: .generationFailed)))
    #expect(events.last == .finished)
  }

  @Test func validationTimeoutIsNotReportedAsGenerationFailure() async {
    let pipeline = QueryPipeline.live(
      fm: Self.fm(suggestions: ["Slow validation?"]),
      sqlGen: testSQLGenClient { _ in
        SQLGeneration(sql: "SELECT 1", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient(
        fingerprint: "snapshot-v1",
        validate: { _ in
          try await Task.sleep(for: .seconds(5))
          return SQLValidationReport()
        },
        execute: { _ in
          Issue.record("execution must not run after validation timeout")
          return Self.result
        }),
      serializer: InferenceSerializer(),
      configuration: Self.configuration(
        deadlines: PipelineDeadlines(
          generationSeconds: 1,
          wholeTurnSeconds: 1)))

    let events = await Array(pipeline.prepareFollowUps(Self.context()))

    let rejection = Self.rejection(
      in: events,
      rank: 1,
      reason: .validationTimedOut)
    #expect(rejection.found)
    #expect(rejection.telemetry?.timeoutStage == "validation")
    #expect(rejection.telemetry?.candidateCount == 1)
    #expect(rejection.telemetry?.lastCandidateGeneratedSQL == true)
    #expect(rejection.telemetry?.lastCandidateErrorPresent == true)
    #expect(
      !Self.rejection(in: events, rank: 1, reason: .generationFailed).found)
  }

  @Test func executionTimeoutIsTerminalInsteadOfRepairable() async {
    let calls = FollowUpCalls()
    let pipeline = QueryPipeline.live(
      fm: Self.fm(suggestions: ["Slow execution?"]),
      sqlGen: testSQLGenClient { _ in
        await calls.generated()
        return SQLGeneration(
          sql: "SELECT 1", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient(
        fingerprint: "snapshot-v1",
        validate: { _ in SQLValidationReport() },
        execute: { _ in
          try await Task.sleep(for: .seconds(5))
          return Self.result
        }),
      serializer: InferenceSerializer(),
      configuration: Self.configuration(
        deadlines: PipelineDeadlines(
          generationSeconds: 1,
          wholeTurnSeconds: 1)))

    let events = await Array(pipeline.prepareFollowUps(Self.context()))

    #expect(
      Self.rejection(in: events, rank: 1, reason: .executionTimedOut).found)
    #expect(await calls.generations == 1)
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
      sqlGen: testSQLGenClient { request in
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
    #expect(
      Self.rejection(in: events, rank: 2, reason: .unhelpfulResult).found)
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
      sqlGen: testSQLGenClient { request in
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
    #expect(
      Self.rejection(in: events, rank: 1, reason: .validationFailed).found)
  }

  @Test func cacheHitShowsResultBeforeNarrationWithoutGenerationOrExecution()
    async throws
  {
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
      sqlGen: testSQLGenClient { _ in
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
    let previewIndex = try #require(
      events.firstIndex {
        if case .preparedResultReady = $0 { true } else { false }
      })
    let narrationIndex = try #require(
      events.firstIndex(of: .narrationStarted))
    #expect(previewIndex < narrationIndex)
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

  @Test func legacyFingerprintSchemaFallsBackAsSchemaVersion() async {
    var prepared = Self.prepared(question: "Prepared?", rank: 1)
    prepared.preparationTelemetry.queryOrigin = .recoverySuggestion
    prepared.provenance.schemaVersion = 2
    prepared.provenance.resultFingerprint = "legacy-v2-fingerprint"
    let pipeline = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: testSQLGenClient { _ in
        SQLGeneration(
          sql: "SELECT 1", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient(
        fingerprint: "snapshot-v1",
        validate: { _ in SQLValidationReport() },
        execute: { _ in Self.result }),
      serializer: InferenceSerializer(),
      configuration: Self.configuration())

    let events = await Array(pipeline.runPrepared(prepared, []))

    #expect(PreparedQueryProvenance.currentSchemaVersion == 3)
    guard case .turnFinished(_, let telemetry) = events.last else {
      Issue.record("Expected schema-version fallback outcome")
      return
    }
    #expect(telemetry.preparedCacheMissReason == .schemaVersion)
    #expect(telemetry.queryOrigin == .recoverySuggestion)
  }

  @Test func preparedFallbackTreatsTheChipQuestionAsStandalone() async {
    let calls = FollowUpCalls()
    var prepared = Self.prepared(question: "Which fund owns it?", rank: 1)
    prepared.provenance.schemaVersion = 2
    let db = DatabaseClient(
      fingerprint: "snapshot-v1",
      validate: { _ in SQLValidationReport() },
      execute: { _ in Self.result })

    let events = await Array(
      preparedAnswerStream(
        prepared: prepared,
        fm: .fallback(),
        db: db,
        serializer: InferenceSerializer(),
        heuristics: ResultHeuristics(db: db),
        configuration: Self.configuration(),
        runtimeMode: { .evaluated },
        fallback: { question, history in
          AsyncStream { continuation in
            Task {
              await calls.recordedFallback(historyCount: history.count)
              var telemetry = TurnTelemetry(originalQuestion: question)
              telemetry.standaloneQuestion = question
              continuation.yield(
                .turnFinished(
                  outcome: .answered(
                    result: Self.result,
                    narration: "Fallback",
                    sql: "SELECT 1",
                    notice: nil),
                  telemetry: telemetry))
              continuation.finish()
            }
          }
        }))

    guard case .turnFinished(_, let telemetry) = events.last else {
      Issue.record("Expected free-form fallback")
      return
    }
    #expect(await calls.fallbackHistoryCounts == [0])
    #expect(telemetry.standaloneQuestion == prepared.question)
  }

  @Test func preparedValidationTimeoutHasADistinctCacheMissReason() async {
    let calls = FollowUpCalls()
    let prepared = Self.prepared(question: "Prepared?", rank: 1)
    let db = DatabaseClient(
      fingerprint: "snapshot-v1",
      validate: { _ in
        _ = await calls.nextValidation()
        try await Task.sleep(for: .seconds(5))
        return SQLValidationReport()
      },
      execute: { _ in Self.result })
    let events = await Array(
      preparedAnswerStream(
        prepared: prepared,
        fm: .fallback(),
        db: db,
        serializer: InferenceSerializer(),
        heuristics: ResultHeuristics(db: db),
        configuration: Self.configuration(
          deadlines: PipelineDeadlines(
            generationSeconds: 0.05,
            wholeTurnSeconds: 0.05)),
        runtimeMode: { .evaluated },
        fallback: { question, _ in
          AsyncStream { continuation in
            continuation.yield(
              .turnFinished(
                outcome: .answered(
                  result: Self.result,
                  narration: "Fallback",
                  sql: "SELECT 1",
                  notice: nil),
                telemetry: TurnTelemetry(originalQuestion: question)))
            continuation.finish()
          }
        }))

    guard case .turnFinished(.answered, let telemetry) = events.last else {
      Issue.record("Expected free-form fallback after validation timeout")
      return
    }
    #expect(telemetry.preparedCacheHit == false)
    #expect(telemetry.preparedCacheMissReason == .validationTimedOut)
    #expect(telemetry.timeoutStage == "validation")
    #expect(await calls.validations == 1)
  }

  @Test func unexpectedPreparedValidationCancellationFallsBack() async {
    let calls = FollowUpCalls()
    let prepared = Self.prepared(question: "Prepared?", rank: 1)
    let pipeline = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: testSQLGenClient { _ in
        SQLGeneration(
          sql: "SELECT 1", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient(
        fingerprint: "snapshot-v1",
        validate: { _ in
          if await calls.nextValidation() == 1 {
            throw CancellationError()
          }
          return SQLValidationReport()
        },
        execute: { _ in Self.result }),
      serializer: InferenceSerializer(),
      configuration: Self.configuration())

    let events = await Array(pipeline.runPrepared(prepared, []))

    guard case .turnFinished(.answered, let telemetry) = events.last else {
      Issue.record("Expected live-task cancellation to use free-form fallback")
      return
    }
    #expect(telemetry.preparedCacheMissReason == .validationFailed)
    #expect(await calls.validations == 2)
  }

  @Test func unexpectedNarrationCancellationFinalizesPreparedAnswer() async {
    let prepared = Self.prepared(question: "Prepared?", rank: 1)
    let fm = FMClient(
      availability: { .available },
      rewrite: { question, _ in question },
      gate: { _, _ in .proceed },
      narrate: { _, _ in throw CancellationError() },
      suggestFollowUps: { _, _ in [] })
    let pipeline = QueryPipeline.live(
      fm: fm,
      sqlGen: testSQLGenClient { _ in
        SQLGeneration(
          sql: "SELECT 1", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient(
        fingerprint: "snapshot-v1",
        validate: { _ in SQLValidationReport() },
        execute: { _ in Self.result }),
      serializer: InferenceSerializer(),
      configuration: Self.configuration())

    let events = await Array(pipeline.runPrepared(prepared, []))

    guard case .turnFinished(let outcome, let telemetry) = events.last,
      case .answered(_, let narration, _, _) = outcome
    else {
      Issue.record("Expected deterministic narration after cancellation")
      return
    }
    #expect(narration == PreparedAnswerFallback.narration(for: prepared.result))
    #expect(telemetry.narrationUsedFM == false)
    #expect(telemetry.timeoutStage == nil)
  }

  @Test func cachedNarrationDeadlineFinalizesWithFallback() async {
    let prepared = Self.prepared(question: "Prepared?", rank: 1)
    let slowFM = FMClient(
      availability: { .available },
      rewrite: { question, _ in question },
      gate: { _, _ in .proceed },
      narrate: { _, _ in
        try await Task.sleep(for: .seconds(5))
        return "Too late"
      },
      suggestFollowUps: { _, _ in [] })
    let pipeline = QueryPipeline.live(
      fm: slowFM,
      sqlGen: testSQLGenClient { _ in
        SQLGeneration(sql: "SELECT 1", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient(
        fingerprint: "snapshot-v1",
        validate: { _ in SQLValidationReport() },
        execute: { _ in Self.result }),
      serializer: InferenceSerializer(),
      configuration: Self.configuration(
        deadlines: PipelineDeadlines(
          generationSeconds: 0.5,
          wholeTurnSeconds: 0.5)))

    let events = await Array(pipeline.runPrepared(prepared, []))

    guard case .turnFinished(let outcome, let telemetry) = events.last else {
      Issue.record("Expected cached answer to finalize after narration timeout")
      return
    }
    guard case .answered(_, let narration, _, _) = outcome else {
      Issue.record("Expected fallback narration answer")
      return
    }
    #expect(narration == PreparedAnswerFallback.narration(for: prepared.result))
    #expect(telemetry.timeoutStage == "narration")
    #expect(telemetry.narrationUsedFM == false)
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
      sqlGen: testSQLGenClient { _ in
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
    #expect(
      !events.contains {
        if case .preparedResultReady = $0 { true } else { false }
      })
    guard case .turnFinished(_, let telemetry) = events.last else {
      Issue.record("Expected a free-form fallback outcome")
      return
    }
    #expect(telemetry.preparedCacheHit == false)
    #expect(telemetry.preparedCacheMissReason == .sqlFingerprint)
    #expect(telemetry.preparedFollowUpID == prepared.id)
  }
}
