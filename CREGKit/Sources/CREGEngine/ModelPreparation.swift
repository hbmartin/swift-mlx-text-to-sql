import Foundation
import MLX

/// The SQL runtime selected for the current process.
///
/// Compatibility mode is deliberately unevaluated. It is a developer-only
/// recovery path and must never be conflated with production evidence.
public enum ModelRuntimeMode: String, Sendable, Equatable, Codable {
  case evaluated
  case compatibility

  public var isEvaluated: Bool { self == .evaluated }
}

/// Stable preparation stages shared by diagnostics, support bundles, and UI.
public enum ModelPreparationStage:
  String, Sendable, Equatable, Hashable, CaseIterable, Codable
{
  case buildPolicy = "build_policy"
  case receiptValidation = "receipt_validation"
  case metalResource = "metal_resource"
  case containerLoad = "container_load"
  case qkvFusion = "qkv_fusion"
  case promptCache = "prompt_cache"
  case ngramDraft = "ngram_draft"
  case outputVocabulary = "output_vocabulary"

  /// Integrity and packaging failures cannot be repaired by changing MLX
  /// execution policy. Compatibility is offered only for runtime stages.
  public var allowsCompatibilityRetry: Bool {
    switch self {
    case .containerLoad, .qkvFusion, .promptCache, .ngramDraft,
      .outputVocabulary:
      true
    case .buildPolicy, .receiptValidation, .metalResource:
      false
    }
  }
}

/// One safe, stable failure that can cross the engine/UI boundary.
public struct ModelPreparationFailure: Error, Sendable, Equatable, Codable {
  public var code: String
  public var stage: ModelPreparationStage
  public var mode: ModelRuntimeMode
  public var userMessage: String
  public var diagnostic: String
  public var errorDomain: String?
  public var errorCode: Int?

  public init(
    code: String,
    stage: ModelPreparationStage,
    mode: ModelRuntimeMode,
    userMessage: String,
    diagnostic: String,
    errorDomain: String? = nil,
    errorCode: Int? = nil
  ) {
    self.code = code
    self.stage = stage
    self.mode = mode
    self.userMessage = userMessage
    self.diagnostic = diagnostic
    self.errorDomain = errorDomain
    self.errorCode = errorCode
  }

  public var allowsCompatibilityRetry: Bool {
    mode == .evaluated && stage.allowsCompatibilityRetry
  }
}

/// Successful preparation metadata retained in app state and support exports.
public struct ModelPreparationReport: Sendable, Equatable, Codable {
  public var mode: ModelRuntimeMode
  public var elapsedMilliseconds: Double

  public init(mode: ModelRuntimeMode, elapsedMilliseconds: Double) {
    self.mode = mode
    self.elapsedMilliseconds = elapsedMilliseconds
  }
}

/// Injectable progress sink used by the MLX adapter. Live code persists these
/// milestones; tests can record them without depending on unified logging.
public struct ModelPreparationProgress: Sendable {
  public var stageStarted:
    @Sendable (ModelPreparationStage, ModelRuntimeMode) async -> Void
  public var stageFinished:
    @Sendable (ModelPreparationStage, ModelRuntimeMode) async -> Void
  public var stageFailed:
    @Sendable (ModelPreparationFailure) async -> Void

  public init(
    stageStarted:
      @escaping @Sendable (ModelPreparationStage, ModelRuntimeMode) async -> Void,
    stageFinished:
      @escaping @Sendable (ModelPreparationStage, ModelRuntimeMode) async -> Void,
    stageFailed:
      @escaping @Sendable (ModelPreparationFailure) async -> Void
  ) {
    self.stageStarted = stageStarted
    self.stageFinished = stageFinished
    self.stageFailed = stageFailed
  }

  public static let noop = ModelPreparationProgress(
    stageStarted: { _, _ in },
    stageFinished: { _, _ in },
    stageFailed: { _ in })
}

/// Payload-free MLX memory dimensions suitable for public diagnostic context.
public enum ModelRuntimeDiagnostics {
  public static func memoryContext(prefix: String = "memory") -> [String: String] {
    let snapshot = Memory.snapshot()
    return [
      "\(prefix)_active_mb": megabytes(snapshot.activeMemory),
      "\(prefix)_cache_mb": megabytes(snapshot.cacheMemory),
      "\(prefix)_peak_mb": megabytes(snapshot.peakMemory),
    ]
  }

  public static func deviceContext() -> [String: String] {
    let info = GPU.deviceInfo()
    return [
      "gpu_architecture": info.architecture,
      "gpu_recommended_working_set_mb": megabytes(
        clamping: info.maxRecommendedWorkingSetSize),
      "physical_memory_mb": megabytes(
        clamping: ProcessInfo.processInfo.physicalMemory),
    ]
  }

  private static func megabytes(_ bytes: Int) -> String {
    String(max(0, bytes) / (1024 * 1024))
  }

  private static func megabytes(clamping bytes: UInt64) -> String {
    String(bytes / UInt64(1024 * 1024))
  }
}
