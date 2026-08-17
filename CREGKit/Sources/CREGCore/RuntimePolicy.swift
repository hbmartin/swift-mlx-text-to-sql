import Foundation

public struct ModelRuntimeContract: Sendable, Equatable, Codable {
  public static let currentVersion = 1
  public static let infoVersionKey = "CREGModelRuntimeContractVersion"
  public static let infoSourceRevisionKey = "CREGSourceRevision"
  public static let infoSourceDirtyKey = "CREGSourceDirty"

  public var version: Int
  public var sourceRevision: String
  public var sourceDirty: Bool

  public init(version: Int, sourceRevision: String, sourceDirty: Bool) {
    self.version = version
    self.sourceRevision = sourceRevision
    self.sourceDirty = sourceDirty
  }

  enum CodingKeys: String, CodingKey {
    case version
    case sourceRevision = "source_revision"
    case sourceDirty = "source_dirty"
  }

  public static func load(info: [String: Any]) throws -> Self {
    let version: Int?
    if let number = info[infoVersionKey] as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    {
      version = number.intValue
    } else if let text = info[infoVersionKey] as? String {
      version = Int(text)
    } else {
      version = nil
    }
    guard let version else {
      throw ModelRuntimeContractInfoError.missing(infoVersionKey)
    }
    guard version == currentVersion else {
      throw ModelRuntimeContractInfoError.unsupportedVersion(
        expected: currentVersion, actual: version)
    }
    guard
      let sourceRevision = info[infoSourceRevisionKey] as? String,
      sourceRevision.count == 40,
      sourceRevision.allSatisfy({ "0123456789abcdef".contains($0) })
    else {
      throw ModelRuntimeContractInfoError.invalidSourceRevision
    }
    let sourceDirty: Bool?
    if let value = info[infoSourceDirtyKey] as? Bool {
      sourceDirty = value
    } else if let text = info[infoSourceDirtyKey] as? String {
      switch text.lowercased() {
      case "true", "yes", "1": sourceDirty = true
      case "false", "no", "0": sourceDirty = false
      default: sourceDirty = nil
      }
    } else {
      sourceDirty = nil
    }
    guard let sourceDirty else {
      throw ModelRuntimeContractInfoError.missing(infoSourceDirtyKey)
    }
    return Self(
      version: version,
      sourceRevision: sourceRevision,
      sourceDirty: sourceDirty)
  }
}

public enum ModelRuntimeContractInfoError: LocalizedError, Equatable {
  case missing(String)
  case unsupportedVersion(expected: Int, actual: Int)
  case invalidSourceRevision

  public var errorDescription: String? {
    switch self {
    case .missing(let key):
      "The bundled app provenance is missing \(key)."
    case .unsupportedVersion(let expected, let actual):
      "The app runtime contract version is unsupported (expected \(expected), actual \(actual))."
    case .invalidSourceRevision:
      "The bundled app source revision is not a full lowercase Git commit."
    }
  }
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
