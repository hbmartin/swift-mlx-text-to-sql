import CREGCore
import CREGData
import Foundation

/// The strictly sequential per-turn pipeline:
/// rewrite → gate → generation/repair → grounding → voting → narration.
///
/// Candidate identity is preserved from generation through execution and the
/// final immutable telemetry record. Foundation Models and MLX work continue
/// to share one ``InferenceSerializer`` so the two inference stacks never
/// overlap.
public struct QueryPipeline: Sendable {
  public struct Configuration: Sendable, Equatable {
    public var model: ModelReference
    public var gcd: GCDMode
    public var productionTemperature: Double
    public var maxTokens: Int
    public var gateSensitivity: Double
    public var maxRepairAttempts: Int
    public var selfConsistencyN: Int
    public var sampleTemperature: Double
    public var repairSampleTemperature: Double
    public var repairPolicyVersion: String
    public var alwaysVote: Bool
    public var deadlines: PipelineDeadlines

    public init(
      model: ModelReference,
      gcd: GCDMode,
      productionTemperature: Double,
      maxTokens: Int,
      gateSensitivity: Double,
      maxRepairAttempts: Int,
      selfConsistencyN: Int,
      sampleTemperature: Double,
      alwaysVote: Bool,
      repairSampleTemperature: Double = 0.3,
      repairPolicyVersion: String = "binding-repair-v2",
      deadlines: PipelineDeadlines = PipelineDeadlines()
    ) {
      precondition((0...1).contains(productionTemperature))
      precondition((0...1).contains(sampleTemperature))
      precondition((0...1).contains(repairSampleTemperature))
      precondition(repairSampleTemperature > 0 || maxRepairAttempts < 2)
      precondition((0...1).contains(gateSensitivity))
      precondition(maxTokens > 0)
      precondition(maxRepairAttempts >= 0)
      precondition(selfConsistencyN >= 1)
      precondition(!repairPolicyVersion.isEmpty)
      self.model = model
      self.gcd = gcd
      self.productionTemperature = productionTemperature
      self.maxTokens = maxTokens
      self.gateSensitivity = gateSensitivity
      self.maxRepairAttempts = maxRepairAttempts
      self.selfConsistencyN = selfConsistencyN
      self.sampleTemperature = sampleTemperature
      self.repairSampleTemperature = repairSampleTemperature
      self.repairPolicyVersion = repairPolicyVersion
      self.alwaysVote = alwaysVote
      self.deadlines = deadlines
    }
  }

  private var prepareMode: @Sendable (ModelRuntimeMode) async throws -> ModelPreparationReport
  private var readRuntimeMode: @Sendable () async -> ModelRuntimeMode
  public var run:
    @Sendable (_ question: String, _ history: [ConversationTurn])
      -> AsyncStream<PipelineEvent>
  public var runStarter: @Sendable (_ starter: StarterQueryID) -> AsyncStream<PipelineEvent>
  public var prepareFollowUps:
    @Sendable (_ context: FollowUpSuggestionContext)
      -> AsyncStream<FollowUpPreparationEvent>
  public var runPrepared:
    @Sendable (_ prepared: PreparedFollowUp, _ history: [ConversationTurn])
      -> AsyncStream<PipelineEvent>

  public init(
    prepare: @escaping @Sendable () async throws -> Void = {},
    run:
      @escaping @Sendable (String, [ConversationTurn])
      -> AsyncStream<PipelineEvent>,
    runStarter: (
      @Sendable (StarterQueryID) -> AsyncStream<PipelineEvent>
    )? = nil,
    prepareFollowUps: (
      @Sendable (FollowUpSuggestionContext)
        -> AsyncStream<FollowUpPreparationEvent>
    )? = nil,
    runPrepared: (
      @Sendable (PreparedFollowUp, [ConversationTurn])
        -> AsyncStream<PipelineEvent>
    )? = nil
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
    self.run = run
    self.runStarter =
      runStarter ?? { starter in
        run(starter.question, [])
      }
    self.prepareFollowUps =
      prepareFollowUps ?? { _ in
        AsyncStream { $0.finish() }
      }
    self.runPrepared =
      runPrepared ?? { prepared, history in
        run(prepared.question, history)
      }
  }

  public init(
    prepareMode:
      @escaping @Sendable (ModelRuntimeMode) async throws
      -> ModelPreparationReport,
    runtimeMode: @escaping @Sendable () async -> ModelRuntimeMode,
    run:
      @escaping @Sendable (String, [ConversationTurn])
      -> AsyncStream<PipelineEvent>,
    runStarter: (
      @Sendable (StarterQueryID) -> AsyncStream<PipelineEvent>
    )? = nil,
    prepareFollowUps: (
      @Sendable (FollowUpSuggestionContext)
        -> AsyncStream<FollowUpPreparationEvent>
    )? = nil,
    runPrepared: (
      @Sendable (PreparedFollowUp, [ConversationTurn])
        -> AsyncStream<PipelineEvent>
    )? = nil
  ) {
    self.prepareMode = prepareMode
    self.readRuntimeMode = runtimeMode
    self.run = run
    self.runStarter =
      runStarter ?? { starter in
        run(starter.question, [])
      }
    self.prepareFollowUps =
      prepareFollowUps ?? { _ in
        AsyncStream { $0.finish() }
      }
    self.runPrepared =
      runPrepared ?? { prepared, history in
        run(prepared.question, history)
      }
  }

  public func prepare(
    _ mode: ModelRuntimeMode = .evaluated
  ) async throws -> ModelPreparationReport {
    try await prepareMode(mode)
  }

  public func runtimeMode() async -> ModelRuntimeMode {
    await readRuntimeMode()
  }
}
