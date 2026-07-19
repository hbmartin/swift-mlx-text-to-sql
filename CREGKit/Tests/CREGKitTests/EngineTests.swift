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

@Suite struct QueryPipelineTests {
  static func makePipeline(
    executeResults: @escaping @Sendable (String) async throws -> QueryResult,
    gateSensitivity: Double = 0
  ) -> QueryPipeline {
    QueryPipeline.live(
      fm: .fallback(),
      sqlGen: SQLGenClient { question, repair in
        SQLGeneration(
          sql: repair == nil ? "SELECT 1" : "SELECT 2",
          tokensPerSecond: 42, modelName: "test")
      },
      db: DatabaseClient(execute: executeResults),
      serializer: InferenceSerializer(),
      configuration: .init(gateSensitivity: gateSensitivity)
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
    guard case .turnFinished(.answered(let result, _, let sql)) = events.last else {
      Issue.record("expected answered outcome, got \(String(describing: events.last))")
      return
    }
    #expect(result.rows == [[.integer(1)]])
    #expect(sql == "SELECT 1")
    // no rewrite events when there is no history
    #expect(!events.contains(.rewriteStarted))
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
    guard case .turnFinished(.answered(_, _, let sql)) = events.last else {
      Issue.record("expected answered outcome after repair")
      return
    }
    #expect(sql == "SELECT 2")
  }

  @Test func repeatedFailuresGiveUpGracefully() async throws {
    let pipeline = Self.makePipeline(executeResults: { _ in
      throw NSError(domain: "sqlite", code: 1)
    })
    var events: [PipelineEvent] = []
    for await event in pipeline.run("q", []) {
      events.append(event)
    }
    guard case .turnFinished(.failed) = events.last else {
      Issue.record("expected failed outcome")
      return
    }
    let attempts = events.filter {
      if case .executionFailed = $0 { return true } else { return false }
    }
    #expect(attempts.count == 3)  // initial + 2 repairs
  }
}

@Suite struct GrammarResourceTests {
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
