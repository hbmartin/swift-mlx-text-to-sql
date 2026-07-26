import CryptoKit
import Foundation

public struct ProductionGenerationConfiguration:
  Sendable, Equatable
{
  public var model: ModelReference
  public var gcd: GCDMode
  public var temperature: Double
  public var topP: Double
  public var topK: Int
  public var maxTokens: Int
  public var candidateCount: Int
  public var sampleTemperature: Double
  public var alwaysVote: Bool
  public var policyVersion: String? = nil
  public var runtimePolicyVersion: String? = nil
  public var metalCommandBufferLimitMB: Int? = nil
  public var compiledQwen2MLPFusion: Bool = false
  public var compiledQwen2QKVVerificationFusion: Bool = false
  public var verificationMLPSkipLayers: [Int] = []
  public var verificationMLPLongBatchExtraSkipLayers: [Int] = []
  public var verificationMLPConfidenceSkip:
    VerificationMLPConfidenceSkipPolicy? = nil
  public var verificationMLPAdditionalConfidenceSkips:
    [VerificationMLPConfidenceSkipPolicy] = []
  public var questionAwareOutputHead: Bool = false
  public var compactQuestionAwareOutputHead: Bool = false
  public var sqlNGramSpeculation: SQLNGramSpeculationPolicy? = nil
  public var debugModelIdentity: DebugModelIdentity? = nil
}

public struct VerificationMLPConfidenceSkipPolicy: Sendable, Equatable {
  public static let supported = VerificationMLPConfidenceSkipPolicy(
    layer: 16,
    targetInputLength: 3,
    minimumSupport: 512,
    requiresUnanimity: true)
  public static let supportedSingleDraft = VerificationMLPConfidenceSkipPolicy(
    layer: 35,
    targetInputLength: 2,
    minimumSupport: 512,
    requiresUnanimity: true)

  public var layer: Int
  public var targetInputLength: Int
  public var minimumSupport: Int
  public var requiresUnanimity: Bool

  public init(
    layer: Int,
    targetInputLength: Int,
    minimumSupport: Int,
    requiresUnanimity: Bool
  ) {
    self.layer = layer
    self.targetInputLength = targetInputLength
    self.minimumSupport = minimumSupport
    self.requiresUnanimity = requiresUnanimity
  }
}

public struct SQLNGramSpeculationPolicy: Sendable, Equatable {
  public static let supported = SQLNGramSpeculationPolicy(
    strategy: "sql-ngram-target-verification-v3",
    order: 6,
    draftTokens: 3,
    serialPrefixTokens: 1,
    adaptiveDraftMinimumSupport: 8,
    corpusSHA256:
      "a7cc3c8cc3d7771353c5133c24f6516d201d31a25897949c94d048684c8244dc",
    sourceCorpusSHA256:
      "3a9ad4806692cdc89e8e68c77e29c5e1eedaefac5745c3a87bd4e4fb1758021e",
    statementCount: 1_353)

  public var strategy: String
  public var order: Int
  public var draftTokens: Int
  public var serialPrefixTokens: Int
  public var adaptiveDraftMinimumSupport: Int
  public var corpusSHA256: String
  public var sourceCorpusSHA256: String
  public var statementCount: Int

  public init(
    strategy: String,
    order: Int,
    draftTokens: Int,
    serialPrefixTokens: Int,
    adaptiveDraftMinimumSupport: Int,
    corpusSHA256: String,
    sourceCorpusSHA256: String,
    statementCount: Int
  ) {
    self.strategy = strategy
    self.order = order
    self.draftTokens = draftTokens
    self.serialPrefixTokens = serialPrefixTokens
    self.adaptiveDraftMinimumSupport = adaptiveDraftMinimumSupport
    self.corpusSHA256 = corpusSHA256
    self.sourceCorpusSHA256 = sourceCorpusSHA256
    self.statementCount = statementCount
  }
}

public struct DebugModelIdentity: Sendable, Equatable {
  public var modelKey: String
  public var baseModelKey: String
  public var trainingRunID: String
  public var selectedIteration: Int
  public var selectedCheckpointSHA256: String
  public var localEvidenceStatus: String
  public var wandbReceiptRequired: Bool

  public init(
    modelKey: String,
    baseModelKey: String,
    trainingRunID: String,
    selectedIteration: Int,
    selectedCheckpointSHA256: String,
    localEvidenceStatus: String,
    wandbReceiptRequired: Bool
  ) {
    self.modelKey = modelKey
    self.baseModelKey = baseModelKey
    self.trainingRunID = trainingRunID
    self.selectedIteration = selectedIteration
    self.selectedCheckpointSHA256 = selectedCheckpointSHA256
    self.localEvidenceStatus = localEvidenceStatus
    self.wandbReceiptRequired = wandbReceiptRequired
  }
}

public enum ModelManifestError: LocalizedError, Equatable {
  case missing
  case missingReceipt
  case receiptMismatch(String)
  case productionSelectionPending
  case unknownProductionModel(String)
  case invalidProductionConfiguration(String)

  public var errorDescription: String? {
    switch self {
    case .missing:
      "model-manifest.json is missing from the app bundle"
    case .missingReceipt:
      "production-model-receipt.json or SQLModel is missing from the app bundle"
    case .receiptMismatch(let message):
      "The bundled production model receipt is invalid: \(message)"
    case .productionSelectionPending:
      "Production model selection is pending verified evaluation."
    case .unknownProductionModel(let key):
      "Production model key “\(key)” is not declared in the model manifest."
    case .invalidProductionConfiguration(let message):
      "Invalid production generation configuration: \(message)"
    }
  }
}

public enum ProductionModelReceiptLoader {
  private struct Receipt: Decodable {
    var schemaVersion: Int
    var modelKey: String
    var repository: String
    var revision: String
    var directorySHA256: String
    var fileCount: Int
    var sourceManifestSHA256: String

    enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case modelKey = "model_key"
      case repository, revision
      case directorySHA256 = "directory_sha256"
      case fileCount = "file_count"
      case sourceManifestSHA256 = "source_manifest_sha256"
    }
  }

  public static func validate(
    manifestURL: URL,
    receiptURL: URL,
    modelDirectory: URL,
    production: ProductionGenerationConfiguration,
    diagnostics: DiagnosticsClient = .noop
  ) throws {
    let started = ContinuousClock.now
    diagnostics.info(
      category: .configuration,
      code: "production_receipt_verification_started",
      summary: "Production model receipt verification started.",
      context: ["model_key": production.model.key])
    do {
      let receipt = try validateContents(
        manifestURL: manifestURL,
        receiptURL: receiptURL,
        modelDirectory: modelDirectory,
        production: production)
      diagnostics.info(
        category: .configuration,
        code: "production_receipt_verified",
        summary: "Production model receipt verification succeeded.",
        context: [
          "model_key": production.model.key,
          "file_count": String(receipt.fileCount),
          "elapsed_ms": milliseconds(started.duration(to: .now).microseconds),
        ])
    } catch {
      diagnostics.record(DiagnosticEvent(
        level: .error,
        category: .configuration,
        code: "production_receipt_verification_failed",
        summary: "Production model receipt verification failed.",
        details: DiagnosticDetails.describe(error),
        context: [
          "model_key": production.model.key,
          "elapsed_ms": milliseconds(started.duration(to: .now).microseconds),
        ]))
      throw error
    }
  }

  private static func validateContents(
    manifestURL: URL,
    receiptURL: URL,
    modelDirectory: URL,
    production: ProductionGenerationConfiguration
  ) throws -> Receipt {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(
      atPath: modelDirectory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw ModelManifestError.missingReceipt }
    let manifestData = try Data(contentsOf: manifestURL)
    let receipt = try JSONDecoder().decode(
      Receipt.self, from: Data(contentsOf: receiptURL))
    let manifestDigest = SHA256.hash(data: manifestData)
      .map { String(format: "%02x", $0) }
      .joined()
    guard receipt.schemaVersion == 1 else {
      throw ModelManifestError.receiptMismatch("schema_version must be 1")
    }
    guard receipt.modelKey == production.model.key,
      receipt.repository == production.model.repository,
      receipt.revision == production.model.revision,
      receipt.sourceManifestSHA256 == manifestDigest
    else {
      throw ModelManifestError.receiptMismatch(
        "model identity or source-manifest hash disagrees")
    }
    guard receipt.fileCount > 0,
      receipt.directorySHA256.count == 64,
      receipt.directorySHA256.allSatisfy(\.isHexDigit)
    else {
      throw ModelManifestError.receiptMismatch(
        "directory digest or file count is invalid")
    }
    return receipt
  }

  private static func milliseconds(_ microseconds: Int64) -> String {
    String(format: "%.1f", Double(microseconds) / 1_000)
  }
}

public enum ModelManifestLoader {
  private struct Document: Decodable {
    var models: [Model]
    var productionStatus: String
    var production: Production?
    var debugCandidate: DebugCandidate?

    enum CodingKeys: String, CodingKey {
      case models
      case productionStatus = "production_status"
      case production
      case debugCandidate = "debug_candidate"
    }
  }

  private struct DebugCandidate: Decodable {
    var modelKey: String
    var baseModelKey: String
    var trainingRunID: String
    var selectedIteration: Int
    var selectedCheckpointSHA256: String
    var localEvidenceStatus: String
    var wandbReceiptRequired: Bool

    enum CodingKeys: String, CodingKey {
      case modelKey = "model_key"
      case baseModelKey = "base_model_key"
      case trainingRunID = "training_run_id"
      case selectedIteration = "selected_iteration"
      case selectedCheckpointSHA256 = "selected_checkpoint_sha256"
      case localEvidenceStatus = "local_evidence_status"
      case wandbReceiptRequired = "wandb_receipt_required"
    }
  }

  private struct Model: Decodable {
    struct Quantization: Decodable {
      var bits: Int
    }

    var key: String
    var repository: String?
    var revision: String?
    var quantization: Quantization?
  }

  private struct Production: Decodable {
    struct DeviceRuntime: Decodable {
      struct ConfidenceSkip: Decodable {
        var layer: Int
        var targetInputLength: Int
        var minimumSupport: Int
        var requiresUnanimity: Bool

        enum CodingKeys: String, CodingKey {
          case layer
          case targetInputLength = "target_input_length"
          case minimumSupport = "minimum_support"
          case requiresUnanimity = "requires_unanimity"
        }

        var policy: VerificationMLPConfidenceSkipPolicy {
          VerificationMLPConfidenceSkipPolicy(
            layer: layer,
            targetInputLength: targetInputLength,
            minimumSupport: minimumSupport,
            requiresUnanimity: requiresUnanimity)
        }
      }

      struct SpeculativeDecoding: Decodable {
        var strategy: String
        var order: Int
        var draftTokens: Int
        var serialPrefixTokens: Int
        var adaptiveDraftMinimumSupport: Int
        var corpusSHA256: String
        var sourceCorpusSHA256: String
        var statementCount: Int

        enum CodingKeys: String, CodingKey {
          case strategy, order
          case draftTokens = "draft_tokens"
          case serialPrefixTokens = "serial_prefix_tokens"
          case adaptiveDraftMinimumSupport = "adaptive_draft_min_support"
          case corpusSHA256 = "corpus_sha256"
          case sourceCorpusSHA256 = "source_corpus_sha256"
          case statementCount = "statement_count"
        }

        var policy: SQLNGramSpeculationPolicy {
          SQLNGramSpeculationPolicy(
            strategy: strategy,
            order: order,
            draftTokens: draftTokens,
            serialPrefixTokens: serialPrefixTokens,
            adaptiveDraftMinimumSupport: adaptiveDraftMinimumSupport,
            corpusSHA256: corpusSHA256,
            sourceCorpusSHA256: sourceCorpusSHA256,
            statementCount: statementCount)
        }
      }

      var policyVersion: String
      var gcd: GCDMode
      var maxTokens: Int
      var metalCommandBufferLimitMB: Int?
      var compiledQwen2MLPFusion: Bool?
      var compiledQwen2QKVVerificationFusion: Bool?
      var verificationMLPSkipLayers: [Int]?
      var verificationMLPLongBatchExtraSkipLayers: [Int]?
      var verificationMLPConfidenceSkip: ConfidenceSkip?
      var verificationMLPAdditionalConfidenceSkips: [ConfidenceSkip]?
      var questionAwareOutputHead: Bool?
      var speculativeDecoding: SpeculativeDecoding?

      enum CodingKeys: String, CodingKey {
        case policyVersion = "policy_version"
        case gcd
        case maxTokens = "max_tokens"
        case metalCommandBufferLimitMB = "metal_command_buffer_limit_mb"
        case compiledQwen2MLPFusion = "compiled_qwen2_mlp_fusion"
        case compiledQwen2QKVVerificationFusion =
          "compiled_qwen2_qkv_verification_fusion"
        case verificationMLPSkipLayers = "verification_mlp_skip_layers"
        case verificationMLPLongBatchExtraSkipLayers =
          "verification_mlp_long_batch_extra_skip_layers"
        case verificationMLPConfidenceSkip =
          "verification_mlp_confidence_skip"
        case verificationMLPAdditionalConfidenceSkips =
          "verification_mlp_additional_confidence_skips"
        case questionAwareOutputHead = "question_aware_output_head"
        case speculativeDecoding = "speculative_decoding"
      }
    }

    struct Voting: Decodable {
      var candidateCount: Int
      var sampleTemperature: Double
      var alwaysVote: Bool

      enum CodingKeys: String, CodingKey {
        case candidateCount = "candidate_count"
        case sampleTemperature = "sample_temperature"
        case alwaysVote = "always_vote"
      }
    }

    var modelKey: String
    var gcd: GCDMode
    var temperature: Double
    var topP: Double
    var topK: Int
    var maxTokens: Int
    var deviceRuntime: DeviceRuntime?
    var policyVersion: String?
    var voting: Voting

    enum CodingKeys: String, CodingKey {
      case modelKey = "model_key"
      case gcd, temperature
      case topP = "top_p"
      case topK = "top_k"
      case maxTokens = "max_tokens"
      case deviceRuntime = "device_runtime"
      case policyVersion = "policy_version"
      case voting
    }
  }

  public static func production(
    url: URL,
    allowDebugCandidate: Bool = false
  ) throws
    -> ProductionGenerationConfiguration
  {
    let decoder = JSONDecoder()
    let document = try decoder.decode(
      Document.self, from: Data(contentsOf: url))
    guard let production = document.production else {
      throw ModelManifestError.productionSelectionPending
    }
    let debugIdentity: DebugModelIdentity?
    switch document.productionStatus {
    case "verified":
      debugIdentity = nil
    case "debug-candidate":
      guard allowDebugCandidate, let candidate = document.debugCandidate else {
        throw ModelManifestError.invalidProductionConfiguration(
          "Debug candidate manifests are forbidden in this build configuration")
      }
      guard
        candidate.modelKey == production.modelKey,
        candidate.selectedIteration > 0,
        candidate.selectedCheckpointSHA256.count == 64,
        candidate.selectedCheckpointSHA256.allSatisfy(\.isHexDigit),
        candidate.wandbReceiptRequired == false
      else {
        throw ModelManifestError.invalidProductionConfiguration(
          "Debug candidate identity is incomplete or inconsistent")
      }
      debugIdentity = DebugModelIdentity(
        modelKey: candidate.modelKey,
        baseModelKey: candidate.baseModelKey,
        trainingRunID: candidate.trainingRunID,
        selectedIteration: candidate.selectedIteration,
        selectedCheckpointSHA256: candidate.selectedCheckpointSHA256,
        localEvidenceStatus: candidate.localEvidenceStatus,
        wandbReceiptRequired: candidate.wandbReceiptRequired)
    default:
      throw ModelManifestError.invalidProductionConfiguration(
        "production_status must be verified when a production selection is present")
    }
    guard let model = document.models.first(
      where: { $0.key == production.modelKey })
    else {
      throw ModelManifestError.unknownProductionModel(
        production.modelKey)
    }
    guard let repository = model.repository,
      let revision = model.revision,
      revision.count == 40,
      revision.allSatisfy(\.isHexDigit)
    else {
      throw ModelManifestError.invalidProductionConfiguration(
        "the model revision must be a full 40-character commit")
    }
    guard let quantization = model.quantization,
      quantization.bits > 0
    else {
      throw ModelManifestError.invalidProductionConfiguration(
        "the selected production model must declare positive quantization bits")
    }
    guard (0...1).contains(production.temperature),
      (0...1).contains(production.voting.sampleTemperature),
      production.topP == 1,
      production.topK == 0,
      production.maxTokens > 0,
      production.voting.candidateCount >= 1
    else {
      throw ModelManifestError.invalidProductionConfiguration(
        "temperature/top-p/top-k/token-cap/voting values are outside the supported contract")
    }
    if production.policyVersion != nil {
      guard production.policyVersion == "bounded-three-generation-v1",
        production.voting.candidateCount == 3,
        production.voting.sampleTemperature == 0.7,
        production.voting.alwaysVote == false
      else {
        throw ModelManifestError.invalidProductionConfiguration(
          "the bounded policy version requires three generations and a 0.7 sample temperature")
      }
    }
    if let runtime = production.deviceRuntime {
      guard runtime.maxTokens > 0,
        runtime.maxTokens <= production.maxTokens
      else {
        throw ModelManifestError.invalidProductionConfiguration(
          "the iPhone runtime policy requires a positive token cap no larger than the evaluated cap"
        )
      }
      switch runtime.policyVersion {
      case "iphone-30-second-v1":
        guard runtime.metalCommandBufferLimitMB == nil,
          runtime.compiledQwen2MLPFusion == nil,
          runtime.compiledQwen2QKVVerificationFusion == nil,
          runtime.verificationMLPSkipLayers == nil,
          runtime.verificationMLPLongBatchExtraSkipLayers == nil,
          runtime.verificationMLPConfidenceSkip == nil,
          runtime.verificationMLPAdditionalConfidenceSkips == nil,
          runtime.questionAwareOutputHead == nil
        else {
          throw ModelManifestError.invalidProductionConfiguration(
            "the v1 iPhone runtime policy cannot declare newer runtime optimizations"
          )
        }
      case "iphone-30-second-v2":
        guard runtime.metalCommandBufferLimitMB == 10,
          runtime.compiledQwen2MLPFusion == nil,
          runtime.compiledQwen2QKVVerificationFusion == nil,
          runtime.verificationMLPSkipLayers == nil,
          runtime.verificationMLPLongBatchExtraSkipLayers == nil,
          runtime.verificationMLPConfidenceSkip == nil,
          runtime.verificationMLPAdditionalConfidenceSkips == nil,
          runtime.questionAwareOutputHead == nil
        else {
          throw ModelManifestError.invalidProductionConfiguration(
            "the v2 iPhone runtime policy requires only the 10 MB Metal command-buffer limit"
          )
        }
      case "iphone-30-second-v3":
        guard runtime.metalCommandBufferLimitMB == 10,
          runtime.compiledQwen2MLPFusion == true,
          runtime.compiledQwen2QKVVerificationFusion == nil,
          runtime.verificationMLPSkipLayers == nil,
          runtime.verificationMLPLongBatchExtraSkipLayers == nil,
          runtime.verificationMLPConfidenceSkip == nil,
          runtime.verificationMLPAdditionalConfidenceSkips == nil,
          runtime.questionAwareOutputHead == nil,
          runtime.speculativeDecoding?.policy == .supported
        else {
          throw ModelManifestError.invalidProductionConfiguration(
            "the v3 iPhone runtime policy requires the evaluated Metal, Qwen2 MLP fusion, and SQL n-gram settings"
          )
        }
      case "iphone-30-second-v4":
        guard runtime.metalCommandBufferLimitMB == 10,
          runtime.compiledQwen2MLPFusion == true,
          runtime.compiledQwen2QKVVerificationFusion == nil,
          runtime.verificationMLPSkipLayers == nil,
          runtime.verificationMLPLongBatchExtraSkipLayers == nil,
          runtime.verificationMLPConfidenceSkip == nil,
          runtime.verificationMLPAdditionalConfidenceSkips == nil,
          runtime.questionAwareOutputHead == true,
          runtime.speculativeDecoding?.policy == .supported
        else {
          throw ModelManifestError.invalidProductionConfiguration(
            "the v4 iPhone runtime policy requires the evaluated Metal, Qwen2 MLP fusion, question-aware output head, and SQL n-gram settings"
          )
        }
      case "iphone-30-second-v5":
        guard runtime.metalCommandBufferLimitMB == 10,
          runtime.compiledQwen2MLPFusion == true,
          runtime.compiledQwen2QKVVerificationFusion == true,
          runtime.verificationMLPSkipLayers == nil,
          runtime.verificationMLPLongBatchExtraSkipLayers == nil,
          runtime.verificationMLPConfidenceSkip == nil,
          runtime.verificationMLPAdditionalConfidenceSkips == nil,
          runtime.questionAwareOutputHead == true,
          runtime.speculativeDecoding?.policy == .supported
        else {
          throw ModelManifestError.invalidProductionConfiguration(
            "the v5 iPhone runtime policy requires the evaluated Metal, Qwen2 MLP fusion, verification-only Q/K/V fusion, question-aware output head, and SQL n-gram settings"
          )
        }
      case "iphone-30-second-v6":
        guard runtime.metalCommandBufferLimitMB == 10,
          runtime.compiledQwen2MLPFusion == true,
          runtime.compiledQwen2QKVVerificationFusion == true,
          runtime.verificationMLPSkipLayers == nil,
          runtime.verificationMLPLongBatchExtraSkipLayers == nil,
          runtime.verificationMLPConfidenceSkip == nil,
          runtime.verificationMLPAdditionalConfidenceSkips == nil,
          runtime.questionAwareOutputHead == true,
          runtime.speculativeDecoding?.policy == .supported
        else {
          throw ModelManifestError.invalidProductionConfiguration(
            "the v6 iPhone runtime policy requires the evaluated Metal, Qwen2 MLP fusion, verification-only Q/K/V fusion, compact question-aware output head, and SQL n-gram settings"
          )
        }
      case "iphone-30-second-v7":
        guard runtime.metalCommandBufferLimitMB == 10,
          runtime.compiledQwen2MLPFusion == true,
          runtime.compiledQwen2QKVVerificationFusion == true,
          runtime.verificationMLPSkipLayers == [8, 10],
          runtime.verificationMLPLongBatchExtraSkipLayers == nil,
          runtime.verificationMLPConfidenceSkip == nil,
          runtime.verificationMLPAdditionalConfidenceSkips == nil,
          runtime.questionAwareOutputHead == true,
          runtime.speculativeDecoding?.policy == .supported
        else {
          throw ModelManifestError.invalidProductionConfiguration(
            "the v7 iPhone runtime policy requires the evaluated Metal, Qwen2 MLP/Q/K/V fusion, verification-only MLP skip layers, compact question-aware output head, and SQL n-gram settings"
          )
        }
      case "iphone-30-second-v8":
        guard runtime.metalCommandBufferLimitMB == 10,
          runtime.compiledQwen2MLPFusion == true,
          runtime.compiledQwen2QKVVerificationFusion == true,
          runtime.verificationMLPSkipLayers == [8, 10],
          runtime.verificationMLPLongBatchExtraSkipLayers == [2],
          runtime.verificationMLPConfidenceSkip == nil,
          runtime.verificationMLPAdditionalConfidenceSkips == nil,
          runtime.questionAwareOutputHead == true,
          runtime.speculativeDecoding?.policy == .supported
        else {
          throw ModelManifestError.invalidProductionConfiguration(
            "the v8 iPhone runtime policy requires the evaluated Metal, Qwen2 MLP/Q/K/V fusion, shape-specific verification MLP skip layers, compact question-aware output head, and SQL n-gram settings"
          )
        }
      case "iphone-30-second-v9":
        guard runtime.metalCommandBufferLimitMB == 10,
          runtime.compiledQwen2MLPFusion == true,
          runtime.compiledQwen2QKVVerificationFusion == true,
          runtime.verificationMLPSkipLayers == [8, 10],
          runtime.verificationMLPLongBatchExtraSkipLayers == [2],
          runtime.verificationMLPConfidenceSkip?.policy == .supported,
          runtime.verificationMLPAdditionalConfidenceSkips == nil,
          runtime.questionAwareOutputHead == true,
          runtime.speculativeDecoding?.policy == .supported
        else {
          throw ModelManifestError.invalidProductionConfiguration(
            "the v9 iPhone runtime policy requires the evaluated Metal, Qwen2 fusion, shape/confidence-gated verification MLP skips, compact question-aware output head, and SQL n-gram settings"
          )
        }
      case "iphone-30-second-v10":
        guard runtime.metalCommandBufferLimitMB == 10,
          runtime.compiledQwen2MLPFusion == true,
          runtime.compiledQwen2QKVVerificationFusion == true,
          runtime.verificationMLPSkipLayers == [8, 10],
          runtime.verificationMLPLongBatchExtraSkipLayers == [2],
          runtime.verificationMLPConfidenceSkip?.policy == .supported,
          runtime.verificationMLPAdditionalConfidenceSkips?.map(\.policy)
            == [.supportedSingleDraft],
          runtime.questionAwareOutputHead == true,
          runtime.speculativeDecoding?.policy == .supported
        else {
          throw ModelManifestError.invalidProductionConfiguration(
            "the v10 iPhone runtime policy requires the evaluated Metal, Qwen2 fusion, exact shape/confidence-gated verification MLP skips, compact question-aware output head, and SQL n-gram settings"
          )
        }
      default:
        throw ModelManifestError.invalidProductionConfiguration(
          "the iPhone runtime policy version is unsupported"
        )
      }
      if let speculativeDecoding = runtime.speculativeDecoding {
        guard speculativeDecoding.policy == .supported else {
          throw ModelManifestError.invalidProductionConfiguration(
            "the SQL n-gram speculative-decoding policy is unsupported or its corpus provenance is invalid"
          )
        }
      }
    }
    let deployedGCD = production.deviceRuntime?.gcd ?? production.gcd
    let deployedMaxTokens =
      production.deviceRuntime?.maxTokens ?? production.maxTokens
    return ProductionGenerationConfiguration(
      model: ModelReference(
        key: model.key,
        repository: repository,
        revision: revision,
        quantization: "\(quantization.bits)-bit"),
      gcd: deployedGCD,
      temperature: production.temperature,
      topP: production.topP,
      topK: production.topK,
      maxTokens: deployedMaxTokens,
      candidateCount: production.voting.candidateCount,
      sampleTemperature: production.voting.sampleTemperature,
      alwaysVote: production.voting.alwaysVote,
      policyVersion: production.policyVersion,
      runtimePolicyVersion: production.deviceRuntime?.policyVersion,
      metalCommandBufferLimitMB:
        production.deviceRuntime?.metalCommandBufferLimitMB,
      compiledQwen2MLPFusion:
        production.deviceRuntime?.compiledQwen2MLPFusion == true,
      compiledQwen2QKVVerificationFusion:
        production.deviceRuntime?.compiledQwen2QKVVerificationFusion == true,
      verificationMLPSkipLayers:
        production.deviceRuntime?.verificationMLPSkipLayers ?? [],
      verificationMLPLongBatchExtraSkipLayers:
        production.deviceRuntime?.verificationMLPLongBatchExtraSkipLayers ?? [],
      verificationMLPConfidenceSkip:
        production.deviceRuntime?.verificationMLPConfidenceSkip?.policy,
      verificationMLPAdditionalConfidenceSkips:
        production.deviceRuntime?.verificationMLPAdditionalConfidenceSkips?
          .map(\.policy) ?? [],
      questionAwareOutputHead:
        production.deviceRuntime?.questionAwareOutputHead == true,
      compactQuestionAwareOutputHead:
        production.deviceRuntime?.policyVersion == "iphone-30-second-v6"
        || production.deviceRuntime?.policyVersion == "iphone-30-second-v7"
        || production.deviceRuntime?.policyVersion == "iphone-30-second-v8"
        || production.deviceRuntime?.policyVersion == "iphone-30-second-v9"
        || production.deviceRuntime?.policyVersion == "iphone-30-second-v10",
      sqlNGramSpeculation:
        production.deviceRuntime?.speculativeDecoding?.policy,
      debugModelIdentity: debugIdentity)
  }

  public static func production(
    bundle: Bundle = .main,
    allowDebugCandidate: Bool = false
  ) throws
    -> ProductionGenerationConfiguration
  {
    guard
      let url = bundle.url(
        forResource: "model-manifest", withExtension: "json")
    else {
      throw ModelManifestError.missing
    }
    return try production(
      url: url,
      allowDebugCandidate: allowDebugCandidate)
  }
}

extension QueryPipeline.Configuration {
  public init(
    production: ProductionGenerationConfiguration,
    gateSensitivity: Double = 0,
    maxRepairAttempts: Int = 2
  ) {
    self.init(
      model: production.model,
      gcd: production.gcd,
      productionTemperature: production.temperature,
      maxTokens: production.maxTokens,
      gateSensitivity: gateSensitivity,
      maxRepairAttempts: maxRepairAttempts,
      selfConsistencyN: production.candidateCount,
      sampleTemperature: production.sampleTemperature,
      alwaysVote: production.alwaysVote)
  }
}
