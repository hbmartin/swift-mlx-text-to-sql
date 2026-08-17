import CREGCore
import CREGData
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
  public var verificationMLPConfidenceSkip: VerificationMLPConfidenceSkipPolicy? = nil
  public var verificationMLPAdditionalConfidenceSkips: [VerificationMLPConfidenceSkipPolicy] = []
  public var questionAwareOutputHead: Bool = false
  public var compactQuestionAwareOutputHead: Bool = false
  public var sqlNGramSpeculation: SQLNGramSpeculationPolicy? = nil
  public var debugModelIdentity: DebugModelIdentity? = nil
  public var modelRuntimeContract: ModelRuntimeContract? = nil
}

public enum ModelManifestError: LocalizedError, Equatable {
  case missing
  case missingReceipt
  case receiptMismatch(String)
  case productionSelectionPending
  case unknownProductionModel(String)
  case invalidProductionConfiguration(String)
  case missingRuntimeContract
  case unsupportedRuntimeContract(expected: Int, actual: Int)
  case runtimeProvenanceMismatch

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
    case .missingRuntimeContract:
      "The bundled model manifest is missing its runtime contract."
    case .unsupportedRuntimeContract(let expected, let actual):
      "The bundled model runtime contract is unsupported (expected \(expected), actual \(actual))."
    case .runtimeProvenanceMismatch:
      "The bundled model manifest and executable provenance disagree."
    }
  }
}
