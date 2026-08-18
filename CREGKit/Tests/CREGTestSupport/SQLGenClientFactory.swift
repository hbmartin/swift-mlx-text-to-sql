import CREGCore

/// Shared `SQLGenClient` factory for every test target.
///
/// The default schema prompt is defined once here so the engine and feature
/// suites cannot drift apart on what an unconfigured client returns.
public func testSQLGenClient(
  schemaPrompt: @escaping @Sendable () throws -> String = { "test schema" },
  generate:
    @escaping @Sendable (SQLGenerationRequest) async throws
    -> SQLGeneration
) -> SQLGenClient {
  SQLGenClient(schemaPrompt: schemaPrompt, generate: generate)
}
