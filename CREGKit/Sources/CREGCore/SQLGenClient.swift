import Foundation

/// The bundled SQL specialist façade.
///
/// Runtime implementations live in CREGInference; orchestration depends only
/// on these closures and shared CREGCore values.
public struct SQLGenClient: Sendable {
  private var prepareMode:
    @Sendable (ModelRuntimeMode) async throws -> ModelPreparationReport
  private var readRuntimeMode: @Sendable () async -> ModelRuntimeMode
  private var readBackendID: @Sendable () async -> SQLBackendID
  private var loadSchemaPrompt: @Sendable () throws -> String
  public var generate: @Sendable (SQLGenerationRequest) async throws -> SQLGeneration

  public init(
    prepare: @escaping @Sendable () async throws -> Void = {},
    schemaPrompt: @escaping @Sendable () throws -> String,
    generate:
      @escaping @Sendable (SQLGenerationRequest) async throws
      -> SQLGeneration
  ) {
    self.prepareMode = { mode in
      let started = ContinuousClock.now
      try await prepare()
      return ModelPreparationReport(
        mode: mode,
        elapsedMilliseconds:
          Double(started.duration(to: .now).microseconds) / 1_000)
    }
    self.readRuntimeMode = { .evaluated }
    self.readBackendID = { .mlx }
    self.loadSchemaPrompt = schemaPrompt
    self.generate = generate
  }

  public init(
    prepareMode:
      @escaping @Sendable (ModelRuntimeMode) async throws
      -> ModelPreparationReport,
    runtimeMode: @escaping @Sendable () async -> ModelRuntimeMode,
    backendID: @escaping @Sendable () async -> SQLBackendID = { .mlx },
    schemaPrompt: @escaping @Sendable () throws -> String,
    generate:
      @escaping @Sendable (SQLGenerationRequest) async throws
      -> SQLGeneration
  ) {
    self.prepareMode = prepareMode
    self.readRuntimeMode = runtimeMode
    self.readBackendID = backendID
    self.loadSchemaPrompt = schemaPrompt
    self.generate = generate
  }

  public func prepare(
    _ mode: ModelRuntimeMode = .evaluated
  ) async throws -> ModelPreparationReport {
    try await prepareMode(mode)
  }

  public func runtimeMode() async -> ModelRuntimeMode {
    await readRuntimeMode()
  }

  public func backendID() async -> SQLBackendID {
    await readBackendID()
  }

  public func schemaPrompt() throws -> String {
    try loadSchemaPrompt()
  }
}
