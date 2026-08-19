import CREGData

/// Shared `DatabaseClient` convenience for the test targets that depend on
/// `CREGTestSupport`.
///
/// The fingerprint is defined once here so the suites cannot drift apart on
/// the identity an unconfigured client reports.
extension DatabaseClient {
  public init(
    execute: @escaping @Sendable (String) async throws -> QueryResult
  ) {
    self.init(
      fingerprint: "test-portfolio-database",
      execute: execute)
  }
}
