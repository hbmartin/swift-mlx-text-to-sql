@testable import CREGData

extension DatabaseClient {
  init(
    execute: @escaping @Sendable (String) async throws -> QueryResult
  ) {
    self.init(
      fingerprint: "test-portfolio-database",
      execute: execute)
  }
}
