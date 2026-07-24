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
  public var debugModelIdentity: DebugModelIdentity? = nil
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
    var policyVersion: String?
    var voting: Voting

    enum CodingKeys: String, CodingKey {
      case modelKey = "model_key"
      case gcd, temperature
      case topP = "top_p"
      case topK = "top_k"
      case maxTokens = "max_tokens"
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
    return ProductionGenerationConfiguration(
      model: ModelReference(
        key: model.key,
        repository: repository,
        revision: revision,
        quantization: "\(quantization.bits)-bit"),
      gcd: production.gcd,
      temperature: production.temperature,
      topP: production.topP,
      topK: production.topK,
      maxTokens: production.maxTokens,
      candidateCount: production.voting.candidateCount,
      sampleTemperature: production.voting.sampleTemperature,
      alwaysVote: production.voting.alwaysVote,
      policyVersion: production.policyVersion,
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
