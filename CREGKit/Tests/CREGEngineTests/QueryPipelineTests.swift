import CREGTestSupport
import CryptoKit
import Foundation
import Testing

@testable import CREGCore
@testable import CREGData
@testable import CREGEngine

@Suite struct QueryPipelineTests {
  static let model = ModelReference(
    key: "test",
    repository: "test/model",
    revision: String(repeating: "a", count: 40))

  static func config(
    selfConsistencyN: Int = 1,
    productionTemperature: Double = 0,
    sampleTemperature: Double = 0.7,
    maxRepairAttempts: Int = 2,
    repairSampleTemperature: Double = 0.3,
    alwaysVote: Bool = false
  ) -> QueryPipeline.Configuration {
    .init(
      model: model,
      gcd: .on,
      productionTemperature: productionTemperature,
      maxTokens: 512,
      gateSensitivity: 0,
      maxRepairAttempts: maxRepairAttempts,
      selfConsistencyN: selfConsistencyN,
      sampleTemperature: sampleTemperature,
      alwaysVote: alwaysVote,
      repairSampleTemperature: repairSampleTemperature)
  }

  static func makePipeline(
    executeResults: @escaping @Sendable (String) async throws -> QueryResult,
    configuration: QueryPipeline.Configuration = config()
  ) -> QueryPipeline {
    QueryPipeline.live(
      fm: .fallback(),
      sqlGen: testSQLGenClient { request in
        SQLGeneration(
          sql: request.repair == nil ? "SELECT 1" : "SELECT 2",
          tokensPerSecond: 42, modelName: "test")
      },
      db: DatabaseClient(
        fingerprint: "test-portfolio-database",
        execute: executeResults),
      serializer: InferenceSerializer(),
      configuration: configuration
    )
  }

  @Test func happyPathEmitsOrderedEvents() async throws {
    let pipeline = Self.makePipeline(executeResults: { _ in
      QueryResult(columns: ["n"], rows: [[.integer(1)]])
    })
    var events: [PipelineEvent] = []
    for await event in pipeline.run("How many properties?", []) {
      events.append(event)
    }
    #expect(events.first == .turnStarted(question: "How many properties?"))
    guard
      case .turnFinished(
        .answered(let result, _, let sql, _), let telemetry) = events.last
    else {
      Issue.record("expected answered outcome, got \(String(describing: events.last))")
      return
    }
    #expect(result.rows == [[.integer(1)]])
    #expect(sql == "SELECT 1")
    #expect(telemetry.originalQuestion == "How many properties?")
    #expect(telemetry.standaloneQuestion == "How many properties?")
    #expect(!telemetry.rewriteApplied)
    #expect(telemetry.candidates.map(\.id.rawValue) == ["initial"])
    #expect(telemetry.generatedCount == 1)
    #expect(telemetry.confidence == .unconfirmed)
    #expect(
      telemetry.voteOutcome
        == .noConsensus(
          anchorCandidateID: CandidateID(rawValue: "initial"),
          candidateCount: 1,
          reason: .insufficientNonEmptyEvidence))
    #expect(telemetry.candidates.first?.selected == true)
    // no rewrite events when there is no history
    #expect(!events.contains(.rewriteStarted))
    #expect(
      events.contains {
        if case .questionResolved("How many properties?", false, false, _) = $0 {
          true
        } else {
          false
        }
      })
  }

  @Test func executionErrorTriggersRepair() async throws {
    let pipeline = Self.makePipeline(executeResults: { sql in
      if sql == "SELECT 1" {
        throw NSError(
          domain: "sqlite", code: 1, userInfo: [NSLocalizedDescriptionKey: "no such column"])
      }
      return QueryResult(columns: ["n"], rows: [[.integer(2)]])
    })
    var events: [PipelineEvent] = []
    for await event in pipeline.run("q", []) {
      events.append(event)
    }
    #expect(events.contains(.repairStarted(attempt: 1)))
    guard
      case .turnFinished(
        .answered(_, _, let sql, _), let telemetry) = events.last
    else {
      Issue.record("expected answered outcome after repair")
      return
    }
    #expect(sql == "SELECT 2")
    #expect(telemetry.repairAttempts == 1)
    #expect(
      telemetry.candidates.map(\.id.rawValue) == [
        "initial", "repair-1-deterministic",
      ])
    #expect(telemetry.selectedCandidateID?.rawValue == "repair-1-deterministic")
    #expect(telemetry.confidence == .unconfirmed)
    #expect(telemetry.recoveryOutcome == .repaired)
  }

  @Test func deterministicStarterBypassesSQLGenerationAndRecordsItsPath() async {
    actor Calls {
      var generations = 0
      func generated() { generations += 1 }
    }
    let calls = Calls()
    let pipeline = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: testSQLGenClient { _ in
        await calls.generated()
        return SQLGeneration(
          sql: "SELECT forbidden", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient(
        fingerprint: "test-portfolio-database",
        validate: { sql in
          #expect(sql == StarterQueryID.leaseExpirationsNextTwelveMonthsV1.sql)
          return SQLValidationReport()
        },
        execute: { _ in
          QueryResult(
            columns: ["lease_id", "tenant"],
            rows: [[.integer(1), .text("Tenant")]])
        }),
      serializer: InferenceSerializer(),
      configuration: Self.config())

    let events = await Array(
      pipeline.runStarter(.leaseExpirationsNextTwelveMonthsV1))
    #expect(await calls.generations == 0)
    #expect(!events.contains { if case .generationStarted = $0 { true } else { false } })
    guard case .turnFinished(.answered(_, _, let sql, _), let telemetry) = events.last
    else {
      Issue.record("expected deterministic starter answer")
      return
    }
    #expect(sql == StarterQueryID.leaseExpirationsNextTwelveMonthsV1.sql)
    #expect(telemetry.queryOrigin == .starter)
    #expect(
      telemetry.starterQueryID == .leaseExpirationsNextTwelveMonthsV1)
    #expect(telemetry.executionPath == .deterministicStarter)
    #expect(telemetry.gateMode == .bypassed)
    #expect(telemetry.generatedCount == 0)
    #expect(telemetry.selectionReason == .starterQuery)
    #expect(telemetry.confidence == .confirmed)
  }

  @Test func repairStateMachineSuppressesRepeatsAndDiversifiesAttemptTwo() async {
    actor Requests {
      var values: [SQLGenerationRequest] = []
      func append(_ request: SQLGenerationRequest) { values.append(request) }
    }
    let requests = Requests()
    let issue = SQLValidationIssue(
      kind: .binding,
      disposition: .repairable,
      message: "no such column: l.name")
    let pipeline = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: testSQLGenClient { request in
        await requests.append(request)
        let sql =
          request.candidateID.rawValue == "repair-2-sampled"
          ? "SELECT l.lease_id FROM leases l"
          : "SELECT l.name FROM leases l"
        return SQLGeneration(sql: sql, tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient(
        fingerprint: "test-portfolio-database",
        validate: { sql in
          sql.contains("l.name")
            ? SQLValidationReport(issue: issue)
            : SQLValidationReport()
        },
        execute: { _ in
          QueryResult(columns: ["lease_id"], rows: [[.integer(1)]])
        }),
      serializer: InferenceSerializer(),
      configuration: Self.config(
        sampleTemperature: 0,
        maxRepairAttempts: 3,
        repairSampleTemperature: 0.35),
      randomSeed: { 42 })

    let events = await Array(pipeline.run("Which leases expire?", []))
    guard case .turnFinished(.answered, let telemetry) = events.last else {
      Issue.record("expected sampled repair to recover")
      return
    }
    let recorded = await requests.values
    #expect(
      recorded.map(\.candidateID.rawValue) == [
        "initial", "repair-1-deterministic", "repair-2-sampled",
      ])
    #expect(recorded.map(\.temperature) == [0, 0, 0.35])
    #expect(recorded.last?.seed == 42)
    #expect(recorded.last?.repair?.failedSQL == "SELECT l.name FROM leases l")
    #expect(
      recorded.last?.repair?.errorMessage.contains("duplicate SQL matched") == true)
    #expect(telemetry.candidates[1].duplicateOf?.rawValue == "initial")
    #expect(telemetry.candidates[1].duplicateSuppressed == true)
    #expect(telemetry.repairAttempts == 2)
    #expect(telemetry.recoveryOutcome == .repaired)
    #expect(telemetry.repairPolicyVersion == "binding-repair-v2")
  }

  @Test func zeroRepairBudgetIsEnforced() async {
    let issue = SQLValidationIssue(
      kind: .binding,
      disposition: .repairable,
      message: "no such column")
    let pipeline = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: testSQLGenClient { _ in
        SQLGeneration(
          sql: "SELECT missing", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient(
        fingerprint: "test-portfolio-database",
        validate: { _ in SQLValidationReport(issue: issue) },
        execute: { _ in
          Issue.record("invalid SQL must not execute")
          return QueryResult(columns: [], rows: [])
        }),
      serializer: InferenceSerializer(),
      configuration: Self.config(maxRepairAttempts: 0))

    let events = await Array(pipeline.run("q", []))
    guard case .turnFinished(.failed, let telemetry) = events.last else {
      Issue.record("expected exhausted repair budget")
      return
    }
    #expect(telemetry.generatedCount == 1)
    #expect(telemetry.repairAttempts == 0)
    #expect(telemetry.recoveryOutcome == .exhausted)
  }

  @Test func emptyResultTriggersVoteAndMajorityWins() async throws {
    // Greedy generation returns an empty result; the heuristic flags it,
    // uncertainty gating triggers a 3-way vote, and the two agreeing
    // sampled candidates flip the answer.
    let counter = Counter()
    let pipeline = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: testSQLGenClient { request in
        let n = await counter.next()
        return SQLGeneration(
          sql: n == 0
            ? "SELECT empty"
            : "SELECT good \(request.temperature)",
          tokensPerSecond: 42, modelName: "test")
      },
      db: DatabaseClient { sql in
        sql.contains("empty")
          ? QueryResult(columns: ["n"], rows: [])
          : QueryResult(columns: ["n"], rows: [[.integer(7)]])
      },
      serializer: InferenceSerializer(),
      configuration: Self.config(selfConsistencyN: 3)
    )
    var events: [PipelineEvent] = []
    for await event in pipeline.run("q", []) {
      events.append(event)
    }
    #expect(
      events.contains {
        if case .selfConsistencyStarted(3, "initial-validation") = $0 {
          true
        } else {
          false
        }
      })
    guard
      case .turnFinished(
        .answered(let result, _, let sql, let notice),
        let telemetry) = events.last
    else {
      Issue.record("expected answered outcome")
      return
    }
    #expect(result.rows == [[.integer(7)]])
    #expect(sql.hasPrefix("SELECT good"))
    #expect(notice == nil)  // findings re-evaluated on the winning result
    #expect(telemetry.voteOutcome != nil)
    #expect(telemetry.stageTimings.votingMicroseconds != nil)
    #expect(telemetry.candidates.count == 3)
  }

  actor Counter {
    private var value = -1
    func next() -> Int {
      value += 1
      return value
    }
  }

  @Test func emptyResultsCarryNoConsensusEvidence() async throws {
    // Two agreeing empty samples share the empty digest but must not
    // outvote a correct non-empty deterministic anchor.
    let pipeline = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: testSQLGenClient { request in
        SQLGeneration(
          sql: request.candidateID.rawValue == "initial"
            ? "SELECT good" : "SELECT empty",
          tokensPerSecond: 42, modelName: "test")
      },
      db: DatabaseClient { sql in
        sql.contains("empty")
          ? QueryResult(columns: ["n"], rows: [])
          : QueryResult(columns: ["n"], rows: [[.integer(7)]])
      },
      serializer: InferenceSerializer(),
      configuration: Self.config(selfConsistencyN: 3, alwaysVote: true))
    let events = await Array(pipeline.run("q", []))
    guard
      case .turnFinished(
        .answered(let result, _, _, _), let telemetry) = events.last
    else {
      Issue.record("expected answered outcome")
      return
    }
    #expect(result.rows == [[.integer(7)]])
    #expect(telemetry.selectionReason == .noConsensusDeterministicAnchor)
    guard
      case .noConsensus(let anchorID, let candidateCount, let reason)? =
        telemetry.voteOutcome
    else {
      Issue.record("expected no-consensus outcome")
      return
    }
    #expect(anchorID.rawValue == "initial")
    #expect(candidateCount == 3)
    #expect(reason == .insufficientNonEmptyEvidence)
    #expect(telemetry.confidence == .unconfirmed)
  }

  @Test func allEmptyVoteStillDeliversTheAnchorResult() async throws {
    // With no consensus evidence at all, the anchor's own (empty) result
    // remains the deliverable outcome through the visible no-consensus path.
    let pipeline = Self.makePipeline(
      executeResults: { _ in QueryResult(columns: ["n"], rows: []) },
      configuration: Self.config(selfConsistencyN: 3, alwaysVote: true))
    let events = await Array(pipeline.run("q", []))
    guard
      case .turnFinished(.answered(let result, _, _, _), let telemetry) =
        events.last
    else {
      Issue.record("expected answered outcome")
      return
    }
    #expect(result.rows.isEmpty)
    #expect(telemetry.selectionReason == .noConsensusDeterministicAnchor)
    #expect(telemetry.noConsensusReason == .insufficientNonEmptyEvidence)
    #expect(telemetry.confidence == .unconfirmed)
  }

  @Test func repeatedFailuresGiveUpGracefully() async throws {
    let pipeline = Self.makePipeline(executeResults: { _ in
      throw NSError(domain: "sqlite", code: 1)
    })
    var events: [PipelineEvent] = []
    for await event in pipeline.run("q", []) {
      events.append(event)
    }
    guard case .turnFinished(.failed, let telemetry) = events.last else {
      Issue.record("expected failed outcome")
      return
    }
    #expect(telemetry.candidates.count == 3)
    #expect(telemetry.candidates.allSatisfy { $0.generationMicroseconds != nil })
    #expect(telemetry.candidates.last?.duplicateSuppressed == true)
    let attempts = events.filter {
      if case .executionFailed = $0 { return true } else { return false }
    }
    #expect(attempts.count == 3)  // initial + 2 repairs
  }

  @Test func generationFailureRetainsAttemptDuration() async {
    let pipeline = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: testSQLGenClient { _ in
        throw NSError(
          domain: "generation",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: "model unavailable"])
      },
      db: DatabaseClient { _ in
        Issue.record("execution must not run after generation failure")
        return QueryResult(columns: [], rows: [])
      },
      serializer: InferenceSerializer(),
      configuration: Self.config()
    ).reportingOperations(to: .noop)

    let events = await Array(pipeline.run("q", []))
    guard case .turnFinished(.failed, let telemetry) = events.last,
      let candidate = telemetry.candidates.first
    else {
      Issue.record("expected failed generation telemetry")
      return
    }
    #expect(telemetry.candidates.count == 1)
    #expect(candidate.generationMicroseconds != nil)
    #expect(candidate.executionMicroseconds == nil)
    #expect(candidate.error?.contains("model unavailable") == true)
  }

  @Test func allUniqueVoteFallsBackToDeterministicAnchor() async throws {
    let pipeline = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: testSQLGenClient { request in
        let sql =
          switch request.role {
          case .starter: "SELECT 1"
          case .followUpPreflight: "SELECT 1"
          case .initial: "SELECT 1"
          case .deterministicAnchor: "SELECT 2"
          case .consistencySample(let index): "SELECT \(index + 2)"
          case .repair: "SELECT 5"
          }
        return SQLGeneration(
          sql: sql,
          tokensPerSecond: 10,
          modelName: "test",
          tokenCount: 2,
          elapsedMicroseconds: 456)
      },
      db: DatabaseClient { sql in
        QueryResult(
          columns: ["n"],
          rows: [[.integer(Int64(sql.split(separator: " ").last!)!)]],
          elapsedMicroseconds: 123)
      },
      serializer: InferenceSerializer(),
      configuration: Self.config(
        selfConsistencyN: 3,
        productionTemperature: 0.3,
        alwaysVote: true),
      randomSeed: { 99 })

    let events = await Array(pipeline.run("q", []))
    guard
      case .turnFinished(
        .answered(let result, _, let sql, _),
        let telemetry) = events.last
    else {
      Issue.record("expected deterministic fallback")
      return
    }
    #expect(result.rows == [[.integer(1)]])
    #expect(sql == "SELECT 1")
    #expect(telemetry.confidence == .unconfirmed)
    #expect(telemetry.selectedCandidateID?.rawValue == "initial")
    #expect(
      telemetry.selectionReason == .noConsensusDeterministicAnchor)
    guard case .noConsensus(let anchorID, 3, .some(.conflictingResults)) = telemetry.voteOutcome
    else {
      Issue.record("expected no-consensus telemetry")
      return
    }
    #expect(anchorID.rawValue == "initial")
    #expect(
      telemetry.candidates.map(\.id.rawValue) == [
        "initial", "consistency-1", "consistency-2",
      ])
    #expect(
      telemetry.candidates.filter {
        if case .consistencySample = $0.role { true } else { false }
      }.map(\.temperature) == [0.7, 0.7])
    #expect(
      telemetry.candidates.filter { $0.temperature > 0 }
        .allSatisfy { $0.seed == 99 })
    #expect(
      telemetry.candidates.first?.generationMicroseconds == 456)
    #expect(
      telemetry.candidates.first?.executionMicroseconds == 123)
  }

  @Test func anchorFailureUsesVisibleDegradedPrimaryFallback() async throws {
    let pipeline = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: testSQLGenClient { request in
        let sql =
          switch request.role {
          case .starter: "SELECT 1"
          case .followUpPreflight: "SELECT 1"
          case .initial: "SELECT 1"
          case .deterministicAnchor: "SELECT anchor"
          case .consistencySample(let index): "SELECT \(index + 2)"
          case .repair: "SELECT 5"
          }
        return SQLGeneration(
          sql: sql, tokensPerSecond: 10, modelName: "test")
      },
      db: DatabaseClient { sql in
        if sql.contains("anchor") {
          throw NSError(
            domain: "sqlite", code: 1,
            userInfo: [
              NSLocalizedDescriptionKey: "anchor execution failed"
            ])
        }
        let value = Int64(sql.split(separator: " ").last!)!
        return QueryResult(columns: ["n"], rows: [[.integer(value)]])
      },
      serializer: InferenceSerializer(),
      configuration: Self.config(
        selfConsistencyN: 3,
        productionTemperature: 0.3,
        alwaysVote: true),
      randomSeed: { 7 })

    let events = await Array(pipeline.run("q", []))
    guard
      case .turnFinished(
        .answered(let result, _, _, _),
        let telemetry) = events.last
    else {
      Issue.record("expected degraded primary fallback")
      return
    }
    #expect(result.rows == [[.integer(1)]])
    #expect(telemetry.noConsensusReason == .conflictingResults)
    #expect(telemetry.selectionReason == .noConsensusDeterministicAnchor)
    #expect(telemetry.confidence == .unconfirmed)
  }

  @Test func truncatedAnchorUsesVisibleDegradedPrimaryFallback() async throws {
    let pipeline = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: testSQLGenClient { request in
        let sql =
          switch request.role {
          case .starter: "SELECT 1"
          case .followUpPreflight: "SELECT 1"
          case .initial: "SELECT 1"
          case .deterministicAnchor: "SELECT 2"
          case .consistencySample(let index): "SELECT \(index + 2)"
          case .repair: "SELECT 5"
          }
        return SQLGeneration(
          sql: sql, tokensPerSecond: 10, modelName: "test")
      },
      db: DatabaseClient { sql in
        let value = Int64(sql.split(separator: " ").last!)!
        return QueryResult(
          columns: ["n"],
          rows: [[.integer(value)]],
          isTruncated: value == 2)
      },
      serializer: InferenceSerializer(),
      configuration: Self.config(
        selfConsistencyN: 3,
        productionTemperature: 0.3,
        alwaysVote: true),
      randomSeed: { 7 })

    let events = await Array(pipeline.run("q", []))
    guard
      case .turnFinished(
        .answered(let result, _, _, _),
        let telemetry) = events.last
    else {
      Issue.record("expected degraded primary fallback")
      return
    }
    #expect(result.rows == [[.integer(1)]])
    #expect(telemetry.noConsensusReason == .conflictingResults)
    #expect(telemetry.selectionReason == .noConsensusDeterministicAnchor)
    #expect(telemetry.confidence == .unconfirmed)
  }

  @Test func validDuplicateReusesExecutionButStillConfirms() async throws {
    actor Calls {
      var count = 0
      func execute() -> QueryResult {
        count += 1
        return QueryResult(columns: ["n"], rows: [[.integer(1)]])
      }
    }
    let calls = Calls()
    let pipeline = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: testSQLGenClient { _ in
        SQLGeneration(sql: "SELECT 1", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient { _ in await calls.execute() },
      serializer: InferenceSerializer(),
      configuration: Self.config(selfConsistencyN: 3, alwaysVote: true))

    let events = await Array(pipeline.run("q", []))
    guard case .turnFinished(.answered, let telemetry) = events.last else {
      Issue.record("expected confirmed answer")
      return
    }
    #expect(await calls.count == 1)
    #expect(telemetry.confidence == .confirmed)
    #expect(telemetry.candidates.dropFirst().allSatisfy { $0.duplicateOf != nil })
  }

  @Test func repairSelectionPrecedenceCoversOneOrTwoValidRepairs() async throws {
    let repairable = SQLValidationIssue(
      kind: .binding,
      disposition: .repairable,
      message: "no such column")
    for (deterministicValid, sampledValid, expected, generated, attempts) in [
      (true, false, "repair-1-deterministic", 2, 1),
      (false, true, "repair-2-sampled", 3, 2),
      (true, true, "repair-1-deterministic", 2, 1),
    ] {
      let pipeline = QueryPipeline.live(
        fm: .fallback(),
        sqlGen: testSQLGenClient { request in
          let sql =
            switch request.candidateID.rawValue {
            case "initial": "SELECT initial_bad"
            case "repair-1-deterministic":
              deterministicValid ? "SELECT 1" : "SELECT deterministic_bad"
            default:
              sampledValid ? "SELECT 2" : "SELECT sampled_bad"
            }
          return SQLGeneration(sql: sql, tokensPerSecond: 1, modelName: "test")
        },
        db: DatabaseClient(
          fingerprint: "test-portfolio-database",
          validate: { sql in
            sql.contains("bad")
              ? SQLValidationReport(issue: repairable)
              : SQLValidationReport()
          },
          execute: { sql in
            let value: Int64 = sql.hasSuffix("1") ? 1 : 2
            return QueryResult(columns: ["n"], rows: [[.integer(value)]])
          }),
        serializer: InferenceSerializer(),
        configuration: Self.config(selfConsistencyN: 3, alwaysVote: true))
      let events = await Array(pipeline.run("q", []))
      guard case .turnFinished(.answered, let telemetry) = events.last else {
        Issue.record("expected repaired answer")
        continue
      }
      #expect(telemetry.generatedCount == generated)
      #expect(telemetry.repairAttempts == attempts)
      #expect(telemetry.selectedCandidateID?.rawValue == expected)
      #expect(telemetry.confidence == .unconfirmed)
      #expect(telemetry.recoveryOutcome == .repaired)
    }
  }

  @Test func terminalValidationStopsAfterOneGeneration() async throws {
    actor Calls {
      var generation = 0
      var execution = 0
      func generated() { generation += 1 }
      func executed() { execution += 1 }
    }
    let calls = Calls()
    let terminal = SQLValidationIssue(
      kind: .databaseCorrupt,
      disposition: .terminal,
      message: "database disk image is malformed")
    let pipeline = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: testSQLGenClient { _ in
        await calls.generated()
        return SQLGeneration(sql: "SELECT 1", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient(
        fingerprint: "test-portfolio-database",
        validate: { _ in SQLValidationReport(issue: terminal) },
        execute: { _ in
          await calls.executed()
          return QueryResult(columns: [], rows: [])
        }),
      serializer: InferenceSerializer(),
      configuration: Self.config(selfConsistencyN: 3, alwaysVote: true))

    let events = await Array(pipeline.run("q", []))
    guard case .turnFinished(.failed, let telemetry) = events.last else {
      Issue.record("expected terminal failure")
      return
    }
    #expect(await calls.generation == 1)
    #expect(await calls.execution == 0)
    #expect(telemetry.generatedCount == 1)
  }

  @Test func generationAndWholeTurnDeadlinesAreRecorded() async throws {
    let generationTimeout = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: testSQLGenClient { _ in
        try await Task.sleep(for: .milliseconds(100))
        return SQLGeneration(sql: "SELECT 1", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient { _ in QueryResult(columns: [], rows: []) },
      serializer: InferenceSerializer(),
      configuration: .init(
        model: Self.model, gcd: .on, productionTemperature: 0, maxTokens: 64,
        gateSensitivity: 1, maxRepairAttempts: 2, selfConsistencyN: 3,
        sampleTemperature: 0.7, alwaysVote: true,
        deadlines: PipelineDeadlines(
          generationSeconds: 0.01, wholeTurnSeconds: 1)))
    let generationEvents = await Array(generationTimeout.run("q", []))
    guard case .turnFinished(.failed, let generationTelemetry) = generationEvents.last else {
      Issue.record("expected generation timeout")
      return
    }
    #expect(generationTelemetry.timeoutStage == "generation")
    #expect(generationTelemetry.generatedCount == 1)

    let repairIssue = SQLValidationIssue(
      kind: .binding, disposition: .repairable, message: "no such column")
    let repairTimeout = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: testSQLGenClient { request in
        if request.repair != nil {
          try await Task.sleep(for: .milliseconds(100))
        }
        return SQLGeneration(
          sql: "SELECT missing", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient(
        fingerprint: "test-portfolio-database",
        validate: { _ in SQLValidationReport(issue: repairIssue) },
        execute: { _ in
          Issue.record("invalid SQL must not execute")
          return QueryResult(columns: [], rows: [])
        }),
      serializer: InferenceSerializer(),
      configuration: .init(
        model: Self.model, gcd: .on, productionTemperature: 0, maxTokens: 64,
        gateSensitivity: 0, maxRepairAttempts: 2, selfConsistencyN: 3,
        sampleTemperature: 0.7, alwaysVote: true,
        deadlines: PipelineDeadlines(
          generationSeconds: 0.01, wholeTurnSeconds: 1)))
    let repairEvents = await Array(repairTimeout.run("q", []))
    guard case .turnFinished(.failed, let repairTelemetry) = repairEvents.last else {
      Issue.record("expected first-repair timeout")
      return
    }
    #expect(repairTelemetry.timeoutStage == "generation")
    #expect(repairTelemetry.generatedCount == 2)
    #expect(repairTelemetry.repairAttempts == 1)

    let slowFM = FMClient(
      availability: { .available },
      rewrite: { question, _ in question },
      gate: { _, _ in
        try await Task.sleep(for: .milliseconds(100))
        return .proceed
      },
      narrate: { _, _ in "unused" },
      suggestFollowUps: { _, _ in [] })
    let turnTimeout = QueryPipeline.live(
      fm: slowFM,
      sqlGen: testSQLGenClient { _ in
        SQLGeneration(sql: "SELECT 1", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient { _ in QueryResult(columns: [], rows: []) },
      serializer: InferenceSerializer(),
      configuration: .init(
        model: Self.model, gcd: .on, productionTemperature: 0, maxTokens: 64,
        gateSensitivity: 1, maxRepairAttempts: 2, selfConsistencyN: 3,
        sampleTemperature: 0.7, alwaysVote: true,
        deadlines: PipelineDeadlines(
          generationSeconds: 1, wholeTurnSeconds: 0.01)))
    let turnEvents = await Array(turnTimeout.run("q", []))
    guard case .turnFinished(.failed, let turnTelemetry) = turnEvents.last else {
      Issue.record("expected turn timeout")
      return
    }
    #expect(turnTelemetry.timeoutStage == "gate")
    #expect(turnTelemetry.generatedCount == 0)
  }
}
