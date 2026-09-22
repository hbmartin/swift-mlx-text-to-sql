import Foundation
import Testing

@testable import CREGCore

@Suite struct BackendAssetDescriptorTests {
  private static let hash = String(repeating: "a", count: 64)

  private static func descriptor(
    unsafeWrites: Int = 0
  ) -> BackendAssetDescriptor {
    BackendAssetDescriptor(
      backendID: .coreAI,
      sourceRevision: String(repeating: "b", count: 40),
      artifactTreeSHA256: hash,
      tokenizerSHA256: hash,
      promptContractSHA256: hash,
      licenseFileSHA256: ["LICENSE": hash],
      supportedDeviceIdentifiers: ["iPhone16,1"],
      evaluation: BackendEvaluationEvidence(
        corpusQuestionCount: 200,
        executionAccuracy: 0.6,
        validSQLRate: 0.9,
        p95LatencyMilliseconds: 1200,
        peakFootprintMegabytes: 1800,
        appSizeDeltaBytes: 500_000_000,
        unsafeWriteCount: unsafeWrites,
        assetMismatchCount: 0,
        unsupportedDeviceLoadCount: 0,
        jetsamCount: 0,
        physicalDeviceIdentifier: "iPhone16,1"))
  }

  @Test func qualityCanBeLowerButSafetyAndProvenanceCannot() throws {
    let valid = Self.descriptor()
    #expect(valid.isEligible(
      observedArtifactTreeSHA256: Self.hash,
      deviceIdentifier: "iPhone16,1", iosMajor: 27,
      assetBundled: true, licenseEligible: true))
    #expect(!Self.descriptor(unsafeWrites: 1).isEligible(
      observedArtifactTreeSHA256: Self.hash,
      deviceIdentifier: "iPhone16,1", iosMajor: 27,
      assetBundled: true, licenseEligible: true))
    #expect(!valid.isEligible(
      observedArtifactTreeSHA256: String(repeating: "0", count: 64),
      deviceIdentifier: "iPhone16,1", iosMajor: 27,
      assetBundled: true, licenseEligible: true))
    #expect(!valid.isEligible(
      observedArtifactTreeSHA256: Self.hash,
      deviceIdentifier: "iPhone15,2", iosMajor: 27,
      assetBundled: true, licenseEligible: true))
    #expect(!valid.isEligible(
      observedArtifactTreeSHA256: Self.hash,
      deviceIdentifier: "iPhone16,1", iosMajor: 27,
      assetBundled: true, licenseEligible: false))
    #expect(!valid.isEligible(
      observedArtifactTreeSHA256: Self.hash,
      deviceIdentifier: "iPhone16,1", iosMajor: 27,
      assetBundled: false, licenseEligible: true))
  }

  @Test func descriptorRoundTrips() throws {
    let descriptor = Self.descriptor()
    let encoded = try JSONEncoder().encode(descriptor)
    #expect(try JSONDecoder().decode(
      BackendAssetDescriptor.self, from: encoded) == descriptor)
  }
}
