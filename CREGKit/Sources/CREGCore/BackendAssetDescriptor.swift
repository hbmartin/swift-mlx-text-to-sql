import Foundation

/// Release-bundled qualification record for an alternative SQL backend.
/// Evaluation quality may be lower than MLX and shown with a warning; any
/// failure of safety, asset integrity, licensing, or device fit is fatal to
/// eligibility. There is intentionally no network acquisition path.
public struct BackendAssetDescriptor: Sendable, Equatable, Codable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var backendID: SQLBackendID
  public var sourceRevision: String
  public var artifactTreeSHA256: String
  public var tokenizerSHA256: String
  public var promptContractSHA256: String
  public var licenseFileSHA256: [String: String]
  public var minimumIOSMajor: Int
  public var supportedDeviceIdentifiers: [String]
  public var evaluation: BackendEvaluationEvidence

  public init(
    backendID: SQLBackendID,
    sourceRevision: String,
    artifactTreeSHA256: String,
    tokenizerSHA256: String,
    promptContractSHA256: String,
    licenseFileSHA256: [String: String],
    minimumIOSMajor: Int = 27,
    supportedDeviceIdentifiers: [String],
    evaluation: BackendEvaluationEvidence
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.backendID = backendID
    self.sourceRevision = sourceRevision
    self.artifactTreeSHA256 = artifactTreeSHA256
    self.tokenizerSHA256 = tokenizerSHA256
    self.promptContractSHA256 = promptContractSHA256
    self.licenseFileSHA256 = licenseFileSHA256
    self.minimumIOSMajor = minimumIOSMajor
    self.supportedDeviceIdentifiers = supportedDeviceIdentifiers
    self.evaluation = evaluation
  }

  public func isEligible(
    observedArtifactTreeSHA256: String,
    deviceIdentifier: String,
    iosMajor: Int,
    assetBundled: Bool,
    licenseEligible: Bool
  ) -> Bool {
    guard schemaVersion == Self.currentSchemaVersion,
      backendID != .mlx,
      assetBundled,
      licenseEligible,
      iosMajor >= minimumIOSMajor,
      supportedDeviceIdentifiers.contains(deviceIdentifier),
      artifactTreeSHA256 == observedArtifactTreeSHA256,
      Self.isSHA256(artifactTreeSHA256),
      Self.isSHA256(tokenizerSHA256),
      Self.isSHA256(promptContractSHA256),
      sourceRevision.count == 40,
      sourceRevision.allSatisfy(\.isHexDigit),
      !licenseFileSHA256.isEmpty,
      licenseFileSHA256.allSatisfy({ !$0.key.isEmpty && Self.isSHA256($0.value) }),
      evaluation.isSafetyQualified
    else { return false }
    return true
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy(\.isHexDigit)
  }
}

public struct BackendEvaluationEvidence: Sendable, Equatable, Codable {
  public var corpusQuestionCount: Int
  public var executionAccuracy: Double
  public var validSQLRate: Double
  public var p95LatencyMilliseconds: Double
  public var peakFootprintMegabytes: Double
  public var appSizeDeltaBytes: Int64
  public var unsafeWriteCount: Int
  public var assetMismatchCount: Int
  public var unsupportedDeviceLoadCount: Int
  public var jetsamCount: Int
  public var physicalDeviceIdentifier: String

  public init(
    corpusQuestionCount: Int,
    executionAccuracy: Double,
    validSQLRate: Double,
    p95LatencyMilliseconds: Double,
    peakFootprintMegabytes: Double,
    appSizeDeltaBytes: Int64,
    unsafeWriteCount: Int,
    assetMismatchCount: Int,
    unsupportedDeviceLoadCount: Int,
    jetsamCount: Int,
    physicalDeviceIdentifier: String
  ) {
    self.corpusQuestionCount = corpusQuestionCount
    self.executionAccuracy = executionAccuracy
    self.validSQLRate = validSQLRate
    self.p95LatencyMilliseconds = p95LatencyMilliseconds
    self.peakFootprintMegabytes = peakFootprintMegabytes
    self.appSizeDeltaBytes = appSizeDeltaBytes
    self.unsafeWriteCount = unsafeWriteCount
    self.assetMismatchCount = assetMismatchCount
    self.unsupportedDeviceLoadCount = unsupportedDeviceLoadCount
    self.jetsamCount = jetsamCount
    self.physicalDeviceIdentifier = physicalDeviceIdentifier
  }

  public var isSafetyQualified: Bool {
    corpusQuestionCount >= 200
      && (0...1).contains(executionAccuracy)
      && (0...1).contains(validSQLRate)
      && p95LatencyMilliseconds > 0
      && peakFootprintMegabytes > 0
      && unsafeWriteCount == 0
      && assetMismatchCount == 0
      && unsupportedDeviceLoadCount == 0
      && jetsamCount == 0
      && !physicalDeviceIdentifier.isEmpty
  }
}
