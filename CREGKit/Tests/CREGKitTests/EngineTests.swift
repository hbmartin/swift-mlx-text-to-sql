import CryptoKit
import Foundation
import GRDB
import Testing

@testable import CREGEngine

@Suite struct DatabaseClientTests {
  func makeDatabase() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("creg-test-\(UUID().uuidString).sqlite")
    let queue = try DatabaseQueue(path: url.path)
    try queue.write { db in
      try db.execute(sql: "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
      try db.execute(sql: "INSERT INTO t VALUES (1, 'alpha'), (2, 'beta')")
    }
    return url
  }

  @Test func selectWorks() async throws {
    let client = try DatabaseClient.live(url: makeDatabase())
    let result = try await client.execute("SELECT id, name FROM t ORDER BY id")
    #expect(result.columns == ["id", "name"])
    #expect(result.rows == [[.integer(1), .text("alpha")], [.integer(2), .text("beta")]])
    #expect(!result.isTruncated)
  }

  @Test func writesAreDenied() async throws {
    let client = try DatabaseClient.live(url: makeDatabase())
    await #expect(throws: (any Error).self) {
      _ = try await client.execute("INSERT INTO t VALUES (3, 'gamma')")
    }
    await #expect(throws: (any Error).self) {
      _ = try await client.execute("UPDATE t SET name = 'x'")
    }
    await #expect(throws: (any Error).self) {
      _ = try await client.execute("DROP TABLE t")
    }
    await #expect(throws: (any Error).self) {
      _ = try await client.execute("PRAGMA journal_mode = DELETE")
    }
    // still read-only afterwards
    let result = try await client.execute("SELECT COUNT(*) FROM t")
    #expect(result.rows == [[.integer(2)]])
  }

  @Test func rowCapTruncates() async throws {
    let client = try DatabaseClient.live(url: makeDatabase(), rowCap: 1)
    let result = try await client.execute("SELECT id FROM t ORDER BY id")
    #expect(result.rowCount == 1)
    #expect(result.isTruncated)
  }
}

@Suite struct InferenceSerializerTests {
  @Test func operationsNeverOverlap() async throws {
    let serializer = InferenceSerializer()
    actor Overlap {
      var active = 0
      var maxActive = 0
      var order: [Int] = []
      func enter(_ id: Int) {
        active += 1
        maxActive = max(maxActive, active)
        order.append(id)
      }
      func exit() { active -= 1 }
    }
    let overlap = Overlap()
    await withTaskGroup(of: Void.self) { group in
      for id in 0..<5 {
        group.addTask {
          try? await serializer.run {
            await overlap.enter(id)
            try? await Task.sleep(for: .milliseconds(20))
            await overlap.exit()
          }
        }
      }
    }
    #expect(await overlap.maxActive == 1)
    #expect(await overlap.order.count == 5)
  }
}

@Suite struct EXScoreTests {
  private struct FixtureDocument: Decodable {
    var schemaVersion: Int
    var cases: [FixtureCase]

    enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case cases
    }
  }

  private struct FixtureCase: Decodable {
    var name: String
    var left: [[FixtureCell]]
    var right: [[FixtureCell]]
    var matches: Bool
    var leftEncoding: String
    var rightEncoding: String
    var leftDigest: String
    var rightDigest: String

    enum CodingKeys: String, CodingKey {
      case name, left, right, matches
      case leftEncoding = "left_encoding"
      case rightEncoding = "right_encoding"
      case leftDigest = "left_digest"
      case rightDigest = "right_digest"
    }
  }

  private struct FixtureCell: Decodable {
    var type: String
    var value: String
  }

  private func result(_ rows: [[FixtureCell]]) -> QueryResult {
    QueryResult(
      columns: [],
      rows: rows.map { row in
        row.map { cell in
          switch cell.type {
          case "null": .null
          case "integer": .integer(Int64(cell.value)!)
          case "real": .real(Double(cell.value)!)
          case "text": .text(cell.value)
          case "blob": .blob(Data(base64Encoded: cell.value)!)
          default:
            fatalError("unknown fixture type \(cell.type)")
          }
        }
      })
  }

  @Test func numericStorageClassesMatchButTextDoesNot() {
    let integer = QueryResult(columns: ["value"], rows: [[.integer(1)]])
    let real = QueryResult(columns: ["value"], rows: [[.real(1.0)]])
    let text = QueryResult(columns: ["value"], rows: [[.text("1")]])
    #expect(EXScore.matches(integer, real))
    #expect(!EXScore.matches(integer, text))
  }

  @Test func blobIdentityUsesFullBytes() {
    let first = QueryResult(columns: ["value"], rows: [[.blob(Data([0, 1]))]])
    let same = QueryResult(columns: ["value"], rows: [[.blob(Data([0, 1]))]])
    let sameLength = QueryResult(columns: ["value"], rows: [[.blob(Data([1, 0]))]])
    #expect(EXScore.matches(first, same))
    #expect(!EXScore.matches(first, sameLength))
  }

  @Test func nullAndDuplicateRowsRemainSignificant() {
    let one = QueryResult(columns: ["value"], rows: [[.null]])
    let two = QueryResult(columns: ["value"], rows: [[.null], [.null]])
    let emptyText = QueryResult(columns: ["value"], rows: [[.text("")]])
    #expect(!EXScore.matches(one, two))
    #expect(!EXScore.matches(one, emptyText))
  }

  @Test func halfEvenNumericNormalization() {
    #expect(CanonicalSQLValue.canonicalNumber(1.00005) == "1")
    #expect(CanonicalSQLValue.canonicalNumber(1.00015) == "1.0002")
    #expect(CanonicalSQLValue.canonicalNumber(-0.0) == "0")
  }

  @Test func canonicalNumberIsTotalOverTheDoubleRange() {
    #expect(CanonicalSQLValue.canonicalNumber(.infinity) == "inf")
    #expect(CanonicalSQLValue.canonicalNumber(-.infinity) == "-inf")
    #expect(CanonicalSQLValue.canonicalNumber(.nan) == "nan")
    #expect(
      CanonicalSQLValue.canonicalNumber(1e24)
        == "1" + String(repeating: "0", count: 24))
    #expect(
      CanonicalSQLValue.canonicalNumber(1.2345e300)
        == "12345" + String(repeating: "0", count: 296))
    #expect(
      CanonicalSQLValue.canonicalNumber(-1.2345e300)
        == "-12345" + String(repeating: "0", count: 296))
    #expect(
      CanonicalSQLValue.canonicalNumber(.greatestFiniteMagnitude)
        .hasPrefix("17976931348623157"))
    #expect(CanonicalSQLValue.canonicalNumber(5e-324) == "0")
    #expect(CanonicalSQLValue.canonicalNumber(-1e-300) == "0")
  }

  @Test func textIdentityUsesCodePointsNotCanonicalEquivalence() {
    // Python compares str by code points; NFC and NFD spellings of the same
    // grapheme must stay distinct values with distinct digests.
    let nfc = QueryResult(columns: ["v"], rows: [[.text("caf\u{E9}")]])
    let nfd = QueryResult(columns: ["v"], rows: [[.text("cafe\u{301}")]])
    #expect(!EXScore.matches(nfc, nfd))
    #expect(CanonicalSQLResult(nfc).digest != CanonicalSQLResult(nfd).digest)
  }

  @Test func rowOrderDoesNotMatterAndTruncationDoes() {
    let first = QueryResult(
      columns: ["n"], rows: [[.integer(1)], [.integer(2)]])
    let second = QueryResult(
      columns: ["n"], rows: [[.real(2)], [.real(1)]])
    #expect(EXScore.matches(first, second))
    var truncated = second
    truncated.isTruncated = true
    #expect(!EXScore.matches(first, truncated))
  }

  @Test func digestIsStableAndTyped() {
    let first = QueryResult(
      columns: ["n"], rows: [[.integer(1)], [.integer(2)]])
    let reordered = QueryResult(
      columns: ["n"], rows: [[.real(2)], [.real(1)]])
    let text = QueryResult(
      columns: ["n"], rows: [[.text("1")], [.text("2")]])
    #expect(CanonicalSQLResult(first).digest == CanonicalSQLResult(reordered).digest)
    #expect(CanonicalSQLResult(first).digest != CanonicalSQLResult(text).digest)
  }

  @Test func sharedCanonicalFixturesMatchPython() throws {
    let document = try JSONDecoder().decode(
      FixtureDocument.self, from: EXScore.canonicalFixtureData())
    #expect(document.schemaVersion == 1)
    for fixture in document.cases {
      let left = result(fixture.left)
      let right = result(fixture.right)
      let canonicalLeft = CanonicalSQLResult(left)
      let canonicalRight = CanonicalSQLResult(right)
      #expect(
        String(decoding: canonicalLeft.encoding, as: UTF8.self)
          == fixture.leftEncoding)
      #expect(
        String(decoding: canonicalRight.encoding, as: UTF8.self)
          == fixture.rightEncoding)
      #expect(canonicalLeft.digest == fixture.leftDigest)
      #expect(canonicalRight.digest == fixture.rightDigest)
      #expect(EXScore.matches(left, right) == fixture.matches)
    }
  }
}

@Suite struct ProductionConfigurationTests {
  private func manifestURL(_ json: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("model-manifest-\(UUID().uuidString).json")
    try Data(json.utf8).write(to: url, options: .atomic)
    return url
  }

  @Test func loadsSelectedPublishedModelAndIgnoresLocalFinalist() throws {
    let revision = String(repeating: "a", count: 40)
    let url = try manifestURL(
      """
      {
        "production_status": "verified",
        "models": [
          {
            "key": "local-finalist",
            "repository": null,
            "revision": null,
            "quantization": {"bits": 4}
          },
          {
            "key": "winner",
            "repository": "owner/winner",
            "revision": "\(revision)",
            "quantization": {"bits": 4}
          }
        ],
        "production": {
          "model_key": "winner",
          "gcd": "off",
          "temperature": 0.1,
          "top_p": 1.0,
          "top_k": 0,
          "max_tokens": 512,
          "voting": {
            "candidate_count": 3,
            "sample_temperature": 0.3,
            "always_vote": true
          }
        }
      }
      """)
    let production = try ModelManifestLoader.production(url: url)
    #expect(production.model.repository == "owner/winner")
    #expect(production.model.revision == revision)
    #expect(production.gcd == .off)
    #expect(production.temperature == 0.1)
    #expect(production.candidateCount == 3)
    #expect(production.alwaysVote)
  }

  @Test func pendingProductionIsExplicit() throws {
    let url = try manifestURL(
      """
      {
        "production_status": "selection_pending",
        "models": [],
        "production": null
      }
      """)
    #expect(throws: ModelManifestError.productionSelectionPending) {
      try ModelManifestLoader.production(url: url)
    }
  }

  @Test func productionSelectionRequiresVerifiedStatus() throws {
    let revision = String(repeating: "a", count: 40)
    let url = try manifestURL(
      """
      {
        "production_status": "selection_pending",
        "models": [{
          "key": "winner",
          "repository": "owner/winner",
          "revision": "\(revision)",
          "quantization": {"bits": 4}
        }],
        "production": {
          "model_key": "winner",
          "gcd": "off",
          "temperature": 0,
          "top_p": 1.0,
          "top_k": 0,
          "max_tokens": 512,
          "voting": {
            "candidate_count": 3,
            "sample_temperature": 0.3,
            "always_vote": true
          }
        }
      }
      """)
    #expect(
      throws: ModelManifestError.invalidProductionConfiguration(
        "production_status must be verified when a production selection is present")
    ) {
      try ModelManifestLoader.production(url: url)
    }
  }
}

@Suite struct QueryPipelineTests {
  static let model = ModelReference(
    key: "test",
    repository: "test/model",
    revision: String(repeating: "a", count: 40))

  static func config(
    selfConsistencyN: Int = 1,
    productionTemperature: Double = 0,
    sampleTemperature: Double = 0.7,
    alwaysVote: Bool = false
  ) -> QueryPipeline.Configuration {
    .init(
      model: model,
      gcd: .on,
      productionTemperature: productionTemperature,
      maxTokens: 512,
      gateSensitivity: 0,
      maxRepairAttempts: 2,
      selfConsistencyN: selfConsistencyN,
      sampleTemperature: sampleTemperature,
      alwaysVote: alwaysVote)
  }

  static func makePipeline(
    executeResults: @escaping @Sendable (String) async throws -> QueryResult,
    configuration: QueryPipeline.Configuration = config()
  ) -> QueryPipeline {
    QueryPipeline.live(
      fm: .fallback(),
      sqlGen: SQLGenClient { request in
        SQLGeneration(
          sql: request.repair == nil ? "SELECT 1" : "SELECT 2",
          tokensPerSecond: 42, modelName: "test")
      },
      db: DatabaseClient(execute: executeResults),
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
    #expect(telemetry.candidates.first?.selected == true)
    // no rewrite events when there is no history
    #expect(!events.contains(.rewriteStarted))
    #expect(events.contains {
      if case .questionResolved("How many properties?", false, false, _) = $0 {
        true
      } else { false }
    })
  }

  @Test func executionErrorTriggersRepair() async throws {
    let pipeline = Self.makePipeline(executeResults: { sql in
      if sql == "SELECT 1" {
        throw NSError(domain: "sqlite", code: 1, userInfo: [NSLocalizedDescriptionKey: "no such column"])
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
    #expect(telemetry.candidates.map(\.id.rawValue) == [
      "initial", "repair-1",
    ])
    #expect(telemetry.selectedCandidateID?.rawValue == "repair-1")
  }

  @Test func emptyResultTriggersVoteAndMajorityWins() async throws {
    // Greedy generation returns an empty result; the heuristic flags it,
    // uncertainty gating triggers a 3-way vote, and the two agreeing
    // sampled candidates flip the answer.
    let counter = Counter()
    let pipeline = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: SQLGenClient { request in
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
    #expect(events.contains {
      if case .groundingFinished(let report, _) = $0 {
        report.findings.contains(.emptyResult)
      } else { false }
    })
    #expect(events.contains {
      if case .selfConsistencyStarted(3, "grounding") = $0 {
        true
      } else { false }
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
      sqlGen: SQLGenClient { request in
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
        .answered(let result, _, _, let notice), let telemetry) = events.last
    else {
      Issue.record("expected answered outcome")
      return
    }
    #expect(result.rows == [[.integer(7)]])
    #expect(telemetry.selectionReason == .noConsensusDeterministicAnchor)
    guard
      case .noConsensus(let anchorID, let candidateCount)? =
        telemetry.voteOutcome
    else {
      Issue.record("expected no-consensus outcome")
      return
    }
    #expect(anchorID.rawValue == "initial")
    #expect(candidateCount == 3)
    #expect(notice?.contains("did not reach a majority") == true)
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
    #expect(
      telemetry.candidates.allSatisfy {
        $0.generationMicroseconds != nil
          && $0.executionMicroseconds != nil
      })
    let attempts = events.filter {
      if case .executionFailed = $0 { return true } else { return false }
    }
    #expect(attempts.count == 3)  // initial + 2 repairs
  }

  @Test func generationFailureRetainsAttemptDuration() async {
    let pipeline = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: SQLGenClient { _ in
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
      configuration: Self.config())

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
      sqlGen: SQLGenClient { request in
        let sql =
          switch request.role {
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
        .answered(let result, _, let sql, let notice),
        let telemetry) = events.last
    else {
      Issue.record("expected deterministic fallback")
      return
    }
    #expect(result.rows == [[.integer(2)]])
    #expect(sql == "SELECT 2")
    #expect(notice?.contains("did not reach a majority") == true)
    #expect(telemetry.selectedCandidateID?.rawValue == "deterministic-anchor")
    #expect(
      telemetry.selectionReason == .noConsensusDeterministicAnchor)
    guard case .noConsensus(let anchorID, 3) = telemetry.voteOutcome else {
      Issue.record("expected no-consensus telemetry")
      return
    }
    #expect(anchorID.rawValue == "deterministic-anchor")
    #expect(telemetry.candidates.map(\.id.rawValue) == [
      "initial", "deterministic-anchor", "consistency-1",
      "consistency-2",
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
      sqlGen: SQLGenClient { request in
        let sql =
          switch request.role {
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
        .answered(let result, _, _, let notice),
        let telemetry) = events.last
    else {
      Issue.record("expected degraded primary fallback")
      return
    }
    #expect(result.rows == [[.integer(1)]])
    #expect(notice?.contains("deterministic cross-check failed") == true)
    #expect(telemetry.selectionReason == .noConsensusAnchorFailed)
    guard case .anchorFailed(let fallbackID, let message) =
      telemetry.voteOutcome
    else {
      Issue.record("expected anchor-failed telemetry")
      return
    }
    #expect(fallbackID.rawValue == "initial")
    #expect(message.contains("anchor execution failed"))
  }

  @Test func truncatedAnchorUsesVisibleDegradedPrimaryFallback() async throws {
    let pipeline = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: SQLGenClient { request in
        let sql =
          switch request.role {
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
        .answered(let result, _, _, let notice),
        let telemetry) = events.last
    else {
      Issue.record("expected degraded primary fallback")
      return
    }
    #expect(result.rows == [[.integer(1)]])
    #expect(notice?.contains("deterministic cross-check failed") == true)
    #expect(telemetry.selectionReason == .noConsensusAnchorFailed)
    guard case .anchorFailed(let fallbackID, let message) =
      telemetry.voteOutcome
    else {
      Issue.record("expected anchor-failed telemetry")
      return
    }
    #expect(fallbackID.rawValue == "initial")
    #expect(message.contains("truncated at the row cap"))
  }
}

@Suite struct HeuristicsTests {
  actor CatalogAttempts {
    var count = 0

    func execute() throws -> QueryResult {
      count += 1
      if count == 1 {
        throw NSError(
          domain: "catalog", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "temporary failure"])
      }
      return QueryResult(
        columns: ["name"],
        rows: [[.text("Kingsley Tower")]])
    }
  }

  actor PartialCatalogAttempts {
    var count = 0

    func execute() -> QueryResult {
      count += 1
      return QueryResult(
        columns: ["name"],
        rows: [[.text("Kingsley Tower")]],
        isTruncated: count == 1)
    }
  }

  actor MalformedCatalogAttempts {
    var count = 0

    func execute() -> QueryResult {
      count += 1
      if count == 1 {
        return QueryResult(
          columns: ["name"],
          rows: [[.integer(1)], [.text("Kingsley Tower")]])
      }
      return QueryResult(
        columns: ["name"],
        rows: [[.text("Kingsley Tower")]])
    }
  }

  @Test func editDistanceBasics() {
    #expect(ResultHeuristics.editDistance("kitten", "sitting") == 3)
    #expect(ResultHeuristics.editDistance("same", "same") == 0)
    #expect(ResultHeuristics.editDistance("", "abc") == 3)
    #expect(ResultHeuristics.editDistance("abc", "") == 3)
    #expect(ResultHeuristics.editDistance("", "") == 0)
  }

  @Test func closestMatchFindsNearMiss() {
    let values = ["Kingsley Tower", "Palisade Tower", "Sable Tower"]
    #expect(ResultHeuristics.closestMatch(to: "Kingsly Tower", in: values) == "Kingsley Tower")
    #expect(ResultHeuristics.closestMatch(to: "Zebra Plaza Nine", in: values) == nil)
  }

  @Test func inspectSuggestsCorrection() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("creg-heuristics-\(UUID().uuidString).sqlite")
    let queue = try DatabaseQueue(path: url.path)
    try await queue.write { db in
      try db.execute(sql: "CREATE TABLE properties (name TEXT)")
      try db.execute(sql: "INSERT INTO properties VALUES ('Kingsley Tower'), ('Sable Tower')")
    }
    let client = try DatabaseClient.live(url: url)
    let heuristics = ResultHeuristics(db: client)
    let findings = await heuristics.inspect(
      sql: "SELECT name FROM properties WHERE name = 'Kingsly Tower'",
      result: QueryResult(columns: ["name"], rows: []))
    #expect(findings == [.literalNotFound(
      column: GroundingColumn(table: "properties", column: "name"),
      literal: "Kingsly Tower",
      suggestion: "Kingsley Tower")])

    let ok = await heuristics.inspect(
      sql: "SELECT name FROM properties WHERE name = 'Kingsley Tower'",
      result: QueryResult(columns: ["name"], rows: [[.text("Kingsley Tower")]]))
    #expect(ok.isEmpty)
  }

  @Test func aliasesAndAmbiguousUnqualifiedColumnsAreHandledConservatively()
    async throws
  {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "creg-aliases-\(UUID().uuidString).sqlite")
    let queue = try DatabaseQueue(path: url.path)
    try await queue.write { db in
      try db.execute(sql: "CREATE TABLE properties (name TEXT)")
      try db.execute(sql: "CREATE TABLE tenants (name TEXT)")
      try db.execute(
        sql: "INSERT INTO properties VALUES ('Kingsley Tower')")
      try db.execute(sql: "INSERT INTO tenants VALUES ('Acme')")
    }
    let heuristics = ResultHeuristics(
      db: try DatabaseClient.live(url: url))
    let aliased = await heuristics.inspectDetailed(
      sql:
        "SELECT p.name FROM properties p WHERE p.name = 'Kingsly Tower'",
      result: QueryResult(columns: ["name"], rows: []))
    #expect(aliased.checks.first?.column == GroundingColumn(
      table: "properties", column: "name"))
    #expect(aliased.findings.first == .literalNotFound(
      column: GroundingColumn(table: "properties", column: "name"),
      literal: "Kingsly Tower",
      suggestion: "Kingsley Tower"))

    let ambiguous = await heuristics.inspectDetailed(
      sql:
        "SELECT p.name FROM properties p JOIN tenants t ON 1=1 WHERE name = 'Acme'",
      result: QueryResult(columns: ["name"], rows: []))
    #expect(ambiguous.findings == [.emptyResult])
    #expect(ambiguous.skipped == [
      .unresolvedColumn(reference: "name", literal: "Acme")
    ])
  }

  @Test func validCategoricalValueAndUnsupportedPredicatesAreReported()
    async throws
  {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "creg-grounding-\(UUID().uuidString).sqlite")
    let queue = try DatabaseQueue(path: url.path)
    try await queue.write { db in
      try db.execute(
        sql:
          "CREATE TABLE leases (status TEXT, expiration_date TEXT, suite TEXT)")
      try db.execute(
        sql: "INSERT INTO leases VALUES ('Active', '2026-07-01', '400')")
    }
    let heuristics = ResultHeuristics(
      db: try DatabaseClient.live(url: url))
    let report = await heuristics.inspectDetailed(
      sql:
        """
        SELECT * FROM leases
        WHERE status = 'Active'
          AND expiration_date >= '2026-07-01'
          AND suite LIKE '%40%'
        """,
      result: QueryResult(columns: [], rows: []))
    #expect(report.checks == [
      GroundingCheck(
        column: GroundingColumn(table: "leases", column: "status"),
        literal: "Active",
        matched: true)
    ])
    // An unexplained empty result stays visible (and keeps its voting
    // trigger) even when some literals could only be skipped.
    #expect(report.findings == [.emptyResult])
    #expect(report.skipped.contains(.dateLiteral(literal: "2026-07-01")))
    #expect(report.skipped.contains(.likePattern(literal: "%40%")))
  }

  @Test func catalogFailuresAreNotCachedAndRetryLater() async {
    let attempts = CatalogAttempts()
    let heuristics = ResultHeuristics(
      db: DatabaseClient { _ in try await attempts.execute() })
    let sql =
      "SELECT name FROM properties WHERE name = 'Kingsly Tower'"
    let empty = QueryResult(columns: ["name"], rows: [])

    let first = await heuristics.inspectDetailed(
      sql: sql, result: empty)
    #expect(first.degradations.count == 1)
    #expect(first.findings == [.emptyResult])
    #expect(await attempts.count == 1)

    let second = await heuristics.inspectDetailed(
      sql: sql, result: empty)
    #expect(second.degradations.isEmpty)
    #expect(second.findings.first == .literalNotFound(
      column: GroundingColumn(table: "properties", column: "name"),
      literal: "Kingsly Tower",
      suggestion: "Kingsley Tower"))
    #expect(await attempts.count == 2)

    _ = await heuristics.inspectDetailed(sql: sql, result: empty)
    #expect(await attempts.count == 2)
  }

  @Test func partialCatalogsAreNotCachedAndRetryLater() async {
    let attempts = PartialCatalogAttempts()
    let heuristics = ResultHeuristics(
      db: DatabaseClient { _ in await attempts.execute() })
    let sql =
      "SELECT name FROM properties WHERE name = 'Kingsly Tower'"
    let empty = QueryResult(columns: ["name"], rows: [])

    let first = await heuristics.inspectDetailed(sql: sql, result: empty)
    #expect(first.degradations.count == 1)
    #expect(first.findings == [.emptyResult])

    let second = await heuristics.inspectDetailed(sql: sql, result: empty)
    #expect(second.degradations.isEmpty)
    #expect(second.findings.first == .literalNotFound(
      column: GroundingColumn(table: "properties", column: "name"),
      literal: "Kingsly Tower",
      suggestion: "Kingsley Tower"))
    #expect(await attempts.count == 2)
  }

  @Test func malformedCatalogsAreNotPartiallyCached() async {
    let attempts = MalformedCatalogAttempts()
    let heuristics = ResultHeuristics(
      db: DatabaseClient { _ in await attempts.execute() })
    let sql =
      "SELECT name FROM properties WHERE name = 'Kingsly Tower'"
    let empty = QueryResult(columns: ["name"], rows: [])

    let first = await heuristics.inspectDetailed(sql: sql, result: empty)
    #expect(first.degradations.count == 1)
    #expect(
      first.degradations.first?.message.contains(
        "non-text or malformed row") == true)
    #expect(first.findings == [.emptyResult])

    let second = await heuristics.inspectDetailed(sql: sql, result: empty)
    #expect(second.degradations.isEmpty)
    #expect(second.findings.first == .literalNotFound(
      column: GroundingColumn(table: "properties", column: "name"),
      literal: "Kingsly Tower",
      suggestion: "Kingsley Tower"))
    #expect(await attempts.count == 2)
  }
}

@Suite struct GrammarResourceTests {
  @Test func systemPromptBytesMatchPythonEvaluationRuns() throws {
    let prompt = MLXSQLGenerator.systemPrompt(
      schema: try MLXSQLGenerator.schemaPrompt())
    let digest = SHA256.hash(data: Data(prompt.utf8))
      .map { String(format: "%02x", $0) }.joined()
    #expect(
      digest
        == "28f89133847e9383cb8a0426ba612735bb1fd278ad5246df578b8e799a9571b3")
  }

  @Test func unconstrainedOutputNormalizationMatchesPythonHarness() {
    let raw =
      "<|im_start|>Here is the query:\n```sql\nSELECT name FROM properties;\n```<|im_end|>"
    let stripped = MLXSQLGenerator.stripSpecialTokens(raw)
    #expect(
      MLXSQLGenerator.extractSQL(stripped)
        == "SELECT name FROM properties")
    #expect(
      MLXSQLGenerator.extractSQL(
        "analysis first\nWITH latest AS (SELECT 1) SELECT * FROM latest; trailing")
        == "WITH latest AS (SELECT 1) SELECT * FROM latest")
    // A semicolon inside a string literal must not truncate the statement.
    #expect(
      MLXSQLGenerator.extractSQL(
        "SELECT name FROM tenants WHERE name = 'Acme; Inc'; trailing prose")
        == "SELECT name FROM tenants WHERE name = 'Acme; Inc'")
    #expect(
      MLXSQLGenerator.extractSQL(
        "SELECT name FROM tenants WHERE name = 'O''Brien; Co' LIMIT 1;")
        == "SELECT name FROM tenants WHERE name = 'O''Brien; Co' LIMIT 1")
  }

  @Test func grammarResourceContainsSchema() throws {
    let grammar = try MLXSQLGenerator.grammarEBNF()
    #expect(grammar.contains("root ::="))
    #expect(grammar.contains("\"SELECT\""))
    for table in ["funds", "properties", "tenants", "leases", "property_financials", "loans", "valuations"] {
      #expect(grammar.contains("\"\(table)\""), "missing table \(table)")
    }
    // write statements must be unrepresentable
    #expect(!grammar.contains("\"INSERT\""))
    #expect(!grammar.contains("\"UPDATE\""))
    #expect(!grammar.contains("\"DELETE\""))
    #expect(!grammar.contains("\"DROP\""))
  }

  @Test func schemaPromptListsAllTables() throws {
    let prompt = try MLXSQLGenerator.schemaPrompt()
    for table in ["funds(", "properties(", "tenants(", "leases(", "property_financials(", "loans(", "valuations("] {
      #expect(prompt.contains(table))
    }
  }
}
