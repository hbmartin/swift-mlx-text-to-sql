import CREGTestSupport
import CryptoKit
import Foundation
import GRDB
import Testing

@testable import CREGCore
@testable import CREGData
@testable import CREGInference

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

  @Test func leaseNameBindingFailureProducesJoinAwareRepairGuidance() {
    let issue = SQLValidationIssue(
      kind: .binding,
      disposition: .repairable,
      message: "no such column: l.name")
    let guidance = ResultHeuristics.repairGuidance(
      issue: issue,
      sql:
        "SELECT l.name, l.expiration_date FROM leases l WHERE l.status = 'Active'",
      failedFingerprints: ["private-fingerprint"])

    #expect(guidance.invalidReference == "l.name")
    #expect(guidance.invalidQualifier == "l")
    #expect(guidance.invalidColumn == "name")
    #expect(guidance.declaredSources == ["leases"])
    #expect(guidance.sourceColumns["leases"]?.contains("lease_id") == true)
    #expect(guidance.sourceColumns["leases"]?.contains("name") == false)
    #expect(guidance.possibleColumnOwners.contains("tenants"))
    #expect(guidance.possibleColumnOwners.contains("properties"))
    #expect(
      guidance.relevantForeignKeys.contains(
        "leases.tenant_id -> tenants.tenant_id"))
    #expect(
      guidance.relevantForeignKeys.contains(
        "leases.property_id -> properties.property_id"))
    #expect(guidance.correctiveInstruction.contains("Do not use l.name"))

    let prompt = MLXSQLGenerator.repairPrompt(
      question: "Which leases expire in the next 12 months?",
      context: RepairContext(
        failedSQL: "SELECT l.name FROM leases l",
        errorMessage: issue.message,
        guidance: guidance))
    #expect(prompt.contains("leases.tenant_id -> tenants.tenant_id"))
    #expect(prompt.contains("Do not use l.name"))
    #expect(!prompt.contains("private-fingerprint"))
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
    #expect(
      findings == [
        .literalNotFound(
          column: GroundingColumn(table: "properties", column: "name"),
          literal: "Kingsly Tower",
          suggestion: "Kingsley Tower")
      ])

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
    #expect(
      aliased.checks.first?.column
        == GroundingColumn(
          table: "properties", column: "name"))
    #expect(
      aliased.findings.first
        == .literalNotFound(
          column: GroundingColumn(table: "properties", column: "name"),
          literal: "Kingsly Tower",
          suggestion: "Kingsley Tower"))

    let ambiguous = await heuristics.inspectDetailed(
      sql:
        "SELECT p.name FROM properties p JOIN tenants t ON 1=1 WHERE name = 'Acme'",
      result: QueryResult(columns: ["name"], rows: []))
    #expect(ambiguous.findings == [.emptyResult])
    #expect(
      ambiguous.skipped == [
        .unresolvedColumn(reference: "name", literal: "Acme")
      ])
  }

  @Test func nestedPredicatesUseTheirOwnQueryBlockScope() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("creg-nested-grounding-\(UUID().uuidString).sqlite")
    let queue = try DatabaseQueue(path: url.path)
    try await queue.write { db in
      try db.execute(sql: "CREATE TABLE properties (property_id INTEGER, name TEXT)")
      try db.execute(sql: "CREATE TABLE leases (property_id INTEGER, status TEXT)")
      try db.execute(sql: "INSERT INTO leases VALUES (1, 'Active')")
    }
    let heuristics = ResultHeuristics(db: try DatabaseClient.live(url: url))
    let report = await heuristics.inspectDetailed(
      sql: """
        SELECT p.name || '🏢' AS name
        FROM properties p
        WHERE p.property_id IN (
          SELECT l.property_id FROM leases l WHERE l.status = 'Actve'
        )
        """,
      result: QueryResult(columns: ["name"], rows: []))

    #expect(
      report.findings.first
        == .literalNotFound(
          column: GroundingColumn(table: "leases", column: "status"),
          literal: "Actve",
          suggestion: "Active"))
  }

  @Test func nestedPredicatesRemainGroundedWhenTheOuterBlockHasNoFromOrIsUnsupported()
    async throws
  {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("creg-failed-outer-grounding-\(UUID().uuidString).sqlite")
    let queue = try DatabaseQueue(path: url.path)
    try await queue.write { db in
      try db.execute(sql: "CREATE TABLE leases (status TEXT)")
      try db.execute(sql: "INSERT INTO leases VALUES ('Active')")
    }
    let heuristics = ResultHeuristics(db: try DatabaseClient.live(url: url))
    let queries = [
      """
      SELECT EXISTS (
        SELECT l.status FROM leases l WHERE l.status = 'Actve'
      ) AS matches
      """,
      """
      VALUES ((
        SELECT l.status FROM leases l WHERE l.status = 'Actve'
      ))
      """,
    ]

    for sql in queries {
      let report = await heuristics.inspectDetailed(
        sql: sql,
        result: QueryResult(columns: ["matches"], rows: []))
      #expect(
        report.findings.first
          == .literalNotFound(
            column: GroundingColumn(table: "leases", column: "status"),
            literal: "Actve",
            suggestion: "Active"))
    }
  }

  @Test func derivedAliasesGroundThroughTheirExposedOutputLineage() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("creg-derived-grounding-\(UUID().uuidString).sqlite")
    let queue = try DatabaseQueue(path: url.path)
    try await queue.write { db in
      try db.execute(sql: "CREATE TABLE properties (name TEXT, city TEXT)")
      try db.execute(sql: "INSERT INTO properties VALUES ('Desert Plaza', 'Phoenix')")
    }
    let heuristics = ResultHeuristics(db: try DatabaseClient.live(url: url))
    let report = await heuristics.inspectDetailed(
      sql: """
        SELECT d.name
        FROM (SELECT city AS name FROM properties) d
        WHERE d.name = 'Phoenx'
        """,
      result: QueryResult(columns: ["name"], rows: []))

    #expect(
      report.findings.first
        == .literalNotFound(
          column: GroundingColumn(table: "properties", column: "city"),
          literal: "Phoenx",
          suggestion: "Phoenix"))
  }

  @Test func computedDerivedOutputsAreNotGroundedAsRawColumns() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("creg-computed-grounding-\(UUID().uuidString).sqlite")
    let queue = try DatabaseQueue(path: url.path)
    try await queue.write { db in
      try db.execute(sql: "CREATE TABLE properties (building_class TEXT)")
      try db.execute(sql: "INSERT INTO properties VALUES ('A'), ('B')")
    }
    let heuristics = ResultHeuristics(db: try DatabaseClient.live(url: url))
    let projections = [
      "CASE WHEN building_class = 'A' THEN 'Upper' ELSE 'Other' END AS bucket",
      "UPPER(building_class) AS bucket",
      "COUNT(building_class) AS bucket",
    ]
    for projection in projections {
      let report = await heuristics.inspectDetailed(
        sql: """
          SELECT d.bucket FROM (SELECT \(projection) FROM properties) d
          WHERE d.bucket = 'Upper'
          """,
        result: QueryResult(columns: ["bucket"], rows: []))

      #expect(report.findings == [.emptyResult], "\(projection)")
    }

    let direct = await heuristics.inspectDetailed(
      sql: """
        SELECT d.bucket
        FROM (SELECT building_class AS bucket FROM properties) d
        WHERE d.bucket = 'Upper'
        """,
      result: QueryResult(columns: ["bucket"], rows: []))
    #expect(
      direct.findings.first
        == .literalNotFound(
          column: GroundingColumn(
            table: "properties", column: "building_class"),
          literal: "Upper",
          suggestion: nil))
  }

  @Test func nestedAndLaterCTEBlocksInheritEarlierCTEScopes() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("creg-cte-grounding-\(UUID().uuidString).sqlite")
    let queue = try DatabaseQueue(path: url.path)
    try await queue.write { db in
      try db.execute(
        sql: "CREATE TABLE properties (property_id INTEGER, name TEXT, status TEXT)")
      try db.execute(
        sql: "CREATE TABLE leases (property_id INTEGER, status TEXT)")
      try db.execute(sql: "INSERT INTO properties VALUES (1, 'Tower', 'Owned')")
      try db.execute(sql: "INSERT INTO leases VALUES (1, 'Active')")
    }
    let heuristics = ResultHeuristics(db: try DatabaseClient.live(url: url))
    let queries = [
      """
      WITH active AS (SELECT property_id, status FROM leases)
      SELECT p.name FROM properties p
      WHERE p.property_id IN (
        SELECT property_id FROM active WHERE status = 'Actve'
      )
      """,
      """
      WITH active AS (SELECT property_id, status FROM leases),
           filtered AS (
             SELECT property_id FROM active WHERE status = 'Actve'
           )
      SELECT p.name FROM properties p
      WHERE p.property_id IN (SELECT property_id FROM filtered)
      """,
    ]
    for sql in queries {
      let report = await heuristics.inspectDetailed(
        sql: sql,
        result: QueryResult(columns: ["name"], rows: []))

      #expect(
        report.findings.first
          == .literalNotFound(
            column: GroundingColumn(table: "leases", column: "status"),
            literal: "Actve",
            suggestion: "Active"))
    }
  }

  @Test func repairGuidanceFindsAliasesInsideSubqueries() {
    let issue = SQLValidationIssue(
      kind: .binding,
      disposition: .repairable,
      message: "no such column: l.name")
    let guidance = ResultHeuristics.repairGuidance(
      issue: issue,
      sql: """
        SELECT p.name FROM properties p
        WHERE p.property_id IN (
          SELECT l.property_id FROM leases l WHERE l.name = 'Suite 1'
        )
        """,
      failedFingerprints: [])

    #expect(guidance.declaredSources.contains("properties"))
    #expect(guidance.declaredSources.contains("leases"))
    #expect(guidance.correctiveInstruction.contains("l refers to leases"))
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
    #expect(
      report.checks == [
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
    #expect(
      second.findings.first
        == .literalNotFound(
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
    #expect(
      second.findings.first
        == .literalNotFound(
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
    #expect(
      second.findings.first
        == .literalNotFound(
          column: GroundingColumn(table: "properties", column: "name"),
          literal: "Kingsly Tower",
          suggestion: "Kingsley Tower"))
    #expect(await attempts.count == 2)
  }
}
