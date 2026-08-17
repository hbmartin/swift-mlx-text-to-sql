import CryptoKit
import Foundation
import Testing

@testable import CREGCore
@testable import CREGData
@testable import CREGEngine

@Suite struct ProductionConfigurationTests {
  private func manifestURL(_ json: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("model-manifest-\(UUID().uuidString).json")
    try Data(json.utf8).write(to: url, options: .atomic)
    return url
  }

  @Test func loadsSelectedPublishedModelAndIgnoresLocalFinalist() throws {
    let revision = String(repeating: "a", count: 40)
    let url = try manifestURL(
      """
      {
        "production_status": "verified",
        "models": [
          {
            "key": "local-finalist",
            "repository": null,
            "revision": null,
            "quantization": {"bits": 4}
          },
          {
            "key": "winner",
            "repository": "owner/winner",
            "revision": "\(revision)",
            "quantization": {"bits": 4}
          }
        ],
        "production": {
          "model_key": "winner",
          "gcd": "off",
          "temperature": 0.1,
          "top_p": 1.0,
          "top_k": 0,
          "max_tokens": 512,
          "voting": {
            "candidate_count": 3,
            "sample_temperature": 0.3,
            "always_vote": true
          }
        }
      }
      """)
    let production = try ModelManifestLoader.production(url: url)
    #expect(production.model.repository == "owner/winner")
    #expect(production.model.revision == revision)
    #expect(production.gcd == .off)
    #expect(production.temperature == 0.1)
    #expect(production.candidateCount == 3)
    #expect(production.alwaysVote)
    let pipeline = QueryPipeline.Configuration(production: production)
    #expect(pipeline.repairSampleTemperature == 0.3)
  }

  @Test func pendingProductionIsExplicit() throws {
    let url = try manifestURL(
      """
      {
        "production_status": "selection_pending",
        "models": [],
        "production": null
      }
      """)
    #expect(throws: ModelManifestError.productionSelectionPending) {
      try ModelManifestLoader.production(url: url)
    }
  }

  @Test func productionReceiptMustBindManifestAndModelIdentity() throws {
    let revision = String(repeating: "a", count: 40)
    let manifest = try manifestURL(
      """
      {
        "production_status": "verified",
        "models": [{
          "key": "winner",
          "repository": "owner/winner",
          "revision": "\(revision)",
          "quantization": {"bits": 4}
        }],
        "production": {
          "model_key": "winner", "gcd": "on", "temperature": 0,
          "top_p": 1.0, "top_k": 0, "max_tokens": 512,
          "voting": {"candidate_count": 3, "sample_temperature": 0.7, "always_vote": true}
        }
      }
      """)
    let configuration = try ModelManifestLoader.production(url: manifest)
    let modelDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SQLModel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: modelDirectory, withIntermediateDirectories: false)
    let digest = SHA256.hash(data: try Data(contentsOf: manifest))
      .map { String(format: "%02x", $0) }.joined()
    let receipt = FileManager.default.temporaryDirectory
      .appendingPathComponent("production-model-receipt-\(UUID().uuidString).json")
    try Data(
      """
      {
        "schema_version": 1,
        "model_key": "winner",
        "repository": "owner/winner",
        "revision": "\(revision)",
        "directory_sha256": "\(String(repeating: "b", count: 64))",
        "file_count": 2,
        "source_manifest_sha256": "\(digest)"
      }
      """.utf8
    ).write(to: receipt, options: .atomic)

    try ProductionModelReceiptLoader.validate(
      manifestURL: manifest,
      receiptURL: receipt,
      modelDirectory: modelDirectory,
      production: configuration)

    try Data(
      """
      {"schema_version":1,"model_key":"other","repository":"owner/winner",
       "revision":"\(revision)","directory_sha256":"\(String(repeating: "b", count: 64))",
       "file_count":2,"source_manifest_sha256":"\(digest)"}
      """.utf8
    ).write(to: receipt, options: .atomic)
    #expect(
      throws: ModelManifestError.receiptMismatch(
        "model identity or source-manifest hash disagrees")
    ) {
      try ProductionModelReceiptLoader.validate(
        manifestURL: manifest,
        receiptURL: receipt,
        modelDirectory: modelDirectory,
        production: configuration)
    }
  }

  @Test func productionSelectionRequiresVerifiedStatus() throws {
    let revision = String(repeating: "a", count: 40)
    let url = try manifestURL(
      """
      {
        "production_status": "selection_pending",
        "models": [{
          "key": "winner",
          "repository": "owner/winner",
          "revision": "\(revision)",
          "quantization": {"bits": 4}
        }],
        "production": {
          "model_key": "winner",
          "gcd": "off",
          "temperature": 0,
          "top_p": 1.0,
          "top_k": 0,
          "max_tokens": 512,
          "voting": {
            "candidate_count": 3,
            "sample_temperature": 0.3,
            "always_vote": true
          }
        }
      }
      """)
    #expect(
      throws: ModelManifestError.invalidProductionConfiguration(
        "production_status must be verified when a production selection is present")
    ) {
      try ModelManifestLoader.production(url: url)
    }
  }

  @Test func debugCandidateRequiresExplicitOptInAndLoadsIdentity() throws {
    let revision = String(repeating: "b", count: 40)
    let checkpoint = String(repeating: "b", count: 64)
    let url = try manifestURL(
      """
      {
        "production_status": "debug-candidate",
        "models": [{
          "key": "debug-ft-run-new",
          "repository": "local-debug/run-new",
          "revision": "\(revision)",
          "quantization": {"bits": 4}
        }],
        "production": {
          "model_key": "debug-ft-run-new",
          "gcd": "on",
          "temperature": 0,
          "top_p": 1.0,
          "top_k": 0,
          "max_tokens": 512,
          "voting": {
            "candidate_count": 1,
            "sample_temperature": 0,
            "always_vote": false
          }
        },
        "debug_candidate": {
          "model_key": "debug-ft-run-new",
          "base_model_key": "qwen25-coder-3b",
          "training_run_id": "run-new",
          "selected_iteration": 600,
          "selected_checkpoint_sha256": "\(checkpoint)",
          "local_evidence_status": "awaiting_wandb",
          "wandb_receipt_required": false
        }
      }
      """)

    #expect(
      throws: ModelManifestError.invalidProductionConfiguration(
        "Debug candidate manifests are forbidden in this build configuration")
    ) {
      try ModelManifestLoader.production(url: url)
    }

    let production = try ModelManifestLoader.production(
      url: url,
      allowDebugCandidate: true)
    #expect(production.model.key == "debug-ft-run-new")
    #expect(production.candidateCount == 1)
    #expect(production.debugModelIdentity?.trainingRunID == "run-new")
    #expect(production.debugModelIdentity?.selectedIteration == 600)
    #expect(production.debugModelIdentity?.wandbReceiptRequired == false)
  }
}
