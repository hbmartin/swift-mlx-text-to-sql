import CREGCore
import Foundation

public enum ModelManifestLoader {}

extension ModelManifestLoader {
  struct Document: Decodable {
    var models: [Model]
    var productionStatus: String
    var production: Production?
    var debugCandidate: DebugCandidate?
    var modelRuntimeContract: ModelRuntimeContract?

    enum CodingKeys: String, CodingKey {
      case models
      case productionStatus = "production_status"
      case production
      case debugCandidate = "debug_candidate"
      case modelRuntimeContract = "model_runtime_contract"
    }
  }

  struct DebugCandidate: Decodable {
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

  struct Model: Decodable {
    struct Quantization: Decodable {
      var bits: Int
    }

    var key: String
    var repository: String?
    var revision: String?
    var quantization: Quantization?
  }

  struct Production: Decodable {
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
}
