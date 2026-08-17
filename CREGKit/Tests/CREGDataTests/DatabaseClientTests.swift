import CryptoKit
import Foundation
import GRDB
import Testing

@testable import CREGCore
@testable import CREGData

extension DatabaseClient {
  static func sqliteTextFixtureData() throws -> Data {
    guard let url = Bundle.module.url(
      forResource: "sqlite_text_fixtures", withExtension: "json")
    else { throw CocoaError(.fileNoSuchFile) }
    return try Data(contentsOf: url)
  }
}
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

  func productionDatabase() throws -> URL {
    var ancestor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<8 {
      let candidate =
        ancestor
        .appendingPathComponent("db")
        .appendingPathComponent("creg.sqlite")
      if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
      ancestor.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
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

  @Test func textPreservesNULAndReplacesInvalidUTF8() async throws {
    let client = try DatabaseClient.live(url: makeDatabase())
    struct Fixture: Decodable {
      var sql: String
      var expected: String
    }
    struct Document: Decodable {
      var schemaVersion: Int
      var cases: [Fixture]
      enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case cases
      }
    }
    let document = try JSONDecoder().decode(
      Document.self, from: DatabaseClient.sqliteTextFixtureData())
    #expect(document.schemaVersion == 1)
    for fixture in document.cases {
      let result = try await client.execute(fixture.sql)
      #expect(result.rows == [[.text(fixture.expected)]])
    }
  }

  @Test func validationPreparesWithoutSteppingAndClassifiesFailures() async throws {
    let client = try DatabaseClient.live(url: makeDatabase())
    let valid = try await client.validate(
      "WITH ranked AS (SELECT id, ROW_NUMBER() OVER (ORDER BY id) AS n FROM t) SELECT MAX(n) FROM ranked"
    )
    #expect(valid.isValid)

    let binding = try await client.validate("SELECT missing FROM t")
    #expect(binding.issue?.kind == .binding)
    #expect(binding.issue?.disposition == .repairable)

    let unauthorized = try await client.validate("DELETE FROM t")
    #expect(unauthorized.issue?.disposition == .terminal)
    #expect(unauthorized.issue?.kind == .authorization)
  }

  @Test func validatesAllFifteenProductionBindingRegressions() async throws {
    let client = try DatabaseClient.live(url: productionDatabase())
    let failures = [
      "SELECT COUNT(*) FROM tenants WHERE industry = 'Technology' AND status != 'Sold'",
      "SELECT AVG(current_rate) FROM loans WHERE rate_type = 'Fixed'",
      "SELECT current_balance, maturity_date FROM loans WHERE maturity_date < '2028-01-01' AND status = 'Active'",
      "SELECT name FROM properties WHERE status != 'Sold' ORDER BY vacancy DESC LIMIT 5",
      "SELECT p.name, ln.ltv FROM loans ln JOIN properties p ON p.property_id = ln.property_id WHERE ln.status != 'Sold' AND ln.ltv != 0",
      "SELECT f.name, SUM(current_market_value) FROM properties WHERE status != 'Sold' GROUP BY f.name",
      "SELECT name FROM properties WHERE status = 'Current' AND holdover = 1",
      "SELECT year, COUNT(*) FROM leases WHERE status = 'Active' AND expiration_date >= '2026-01-01' AND expiration_date <= '2026-12-31' GROUP BY year",
      "WITH cte AS (SELECT p.name, SUM(f.net_operating_income) AS total FROM property_financials f JOIN properties p ON p.property_id = f.property_id WHERE f.period_end >= '2026-07-01' AND f.period_end <= '2027-07-01' GROUP BY p.name) SELECT rnk, name, total FROM cte ORDER BY total DESC LIMIT 10",
      "SELECT name FROM properties WHERE status != 'Sold' ORDER BY capex DESC LIMIT 5",
      "SELECT name, f.occupancy_rate FROM properties p JOIN funds f ON f.fund_id = p.fund_id WHERE p.period_end = '2026-06-30' AND f.occupancy_rate > 0.90",
      "SELECT DISTINCT t.name FROM tenants t JOIN leases l ON l.tenant_id = t.tenant_id WHERE l.status = 'Active' AND l.year_built >= 2025",
      "SELECT name FROM properties WHERE status != 'Sold' ORDER BY net_operating_income DESC LIMIT 3",
      "SELECT name FROM properties WHERE status != 'Sold' ORDER BY net_operating_income DESC LIMIT 5",
      "SELECT l.name, l.expiration_date FROM leases l WHERE l.status = 'Active'",
    ]
    for sql in failures {
      let report = try await client.validate(sql)
      #expect(report.issue?.kind == .binding, "expected binding failure for \(sql)")
      #expect(report.issue?.disposition == .repairable)
    }
  }

  @Test func everyStarterQueryValidatesAndExecutesAgainstProduction() async throws {
    let client = try DatabaseClient.live(url: productionDatabase())
    for starter in StarterQueryID.allCases {
      let validation = try await client.validate(starter.sql)
      #expect(validation.isValid, "\(starter.rawValue): \(String(describing: validation.issue))")
      let result = try await client.execute(starter.sql)
      #expect(!result.isTruncated, "\(starter.rawValue) unexpectedly truncated")
      #expect(!result.rows.isEmpty, "\(starter.rawValue) unexpectedly returned no rows")
    }

    let leaseStarter = StarterQueryID.leaseExpirationsNextTwelveMonthsV1
    #expect(!leaseStarter.sql.lowercased().contains("l.name"))
    let leaseResult = try await client.execute(leaseStarter.sql)
    #expect(
      leaseResult.columns
        == ["lease_id", "tenant", "property", "suite", "expiration_date", "status"])
    #expect(leaseResult.rowCount == 33)
  }

  @Test func missingAndCorruptDatabasesAreTerminal() async throws {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("missing-\(UUID().uuidString).sqlite")
    do {
      let client = try DatabaseClient.live(url: missing)
      let report = try await client.validate("SELECT 1")
      #expect(report.issue?.disposition == .terminal)
    } catch {
      // Opening a missing read-only database may fail before a client exists.
    }
    let corrupt = FileManager.default.temporaryDirectory
      .appendingPathComponent("corrupt-\(UUID().uuidString).sqlite")
    try Data("not sqlite".utf8).write(to: corrupt, options: .atomic)
    do {
      let client = try DatabaseClient.live(url: corrupt)
      let report = try await client.validate("SELECT 1")
      #expect(report.issue?.disposition == .terminal)
      #expect(report.issue?.kind == .databaseCorrupt)
    } catch {
      // Opening a corrupt database may fail before validation on some SQLite builds.
    }
  }
}
