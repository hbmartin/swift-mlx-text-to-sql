import Foundation
import Testing

@testable import CREGEngine

@Suite struct ProductionManifestCompatibilityTests {
  private let selectedQuantizationError =
    ModelManifestError.invalidProductionConfiguration(
      "the selected production model must declare positive quantization bits")

  private func manifestURL(_ json: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("model-manifest-\(UUID().uuidString).json")
    try Data(json.utf8).write(to: url, options: .atomic)
    return url
  }

  private var checkedInManifestURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("model-manifest.json")
  }

  @Test func checkedInManifestLoadsVerifiedProductionConfiguration() throws {
    let production = try ModelManifestLoader.production(
      url: checkedInManifestURL)

    #expect(production.model.key == "ft-xiyansql-qwencoder-3b")
    #expect(
      production.model.repository
        == "hbmartin/creg-sql-xgenerationlab-xiyansql-qwencoder-3b-2502-mlx-4bit")
    #expect(
      production.model.revision
        == "7f97a54819b9329338a5353266d6d2a1294eb341")
    #expect(production.model.quantization == "4-bit")
    #expect(production.gcd == .on)
    #expect(production.temperature == 0)
    #expect(production.topP == 1)
    #expect(production.topK == 0)
    #expect(production.maxTokens == 512)
    #expect(production.candidateCount == 3)
    #expect(production.sampleTemperature == 0.7)
    #expect(production.alwaysVote)
  }

  @Test func unselectedSourceModelMayOmitQuantization() throws {
    let revision = String(repeating: "a", count: 40)
    let url = try manifestURL(
      """
      {
        "production_status": "verified",
        "models": [
          {
            "key": "source-model",
            "repository": "owner/source-model",
            "revision": "\(revision)"
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
          "gcd": "on",
          "temperature": 0,
          "top_p": 1,
          "top_k": 0,
          "max_tokens": 512,
          "voting": {
            "candidate_count": 3,
            "sample_temperature": 0.7,
            "always_vote": true
          }
        }
      }
      """)

    let production = try ModelManifestLoader.production(url: url)
    #expect(production.model.key == "winner")
    #expect(production.model.quantization == "4-bit")
  }

  @Test func selectedModelWithoutQuantizationFailsClearly() throws {
    let revision = String(repeating: "a", count: 40)
    let url = try manifestURL(
      """
      {
        "production_status": "verified",
        "models": [{
          "key": "winner",
          "repository": "owner/winner",
          "revision": "\(revision)"
        }],
        "production": {
          "model_key": "winner",
          "gcd": "on",
          "temperature": 0,
          "top_p": 1,
          "top_k": 0,
          "max_tokens": 512,
          "voting": {
            "candidate_count": 3,
            "sample_temperature": 0.7,
            "always_vote": true
          }
        }
      }
      """)

    #expect(throws: selectedQuantizationError) {
      try ModelManifestLoader.production(url: url)
    }
  }

  @Test func selectedModelWithZeroQuantizationBitsFailsClearly() throws {
    let revision = String(repeating: "a", count: 40)
    let url = try manifestURL(
      """
      {
        "production_status": "verified",
        "models": [{
          "key": "winner",
          "repository": "owner/winner",
          "revision": "\(revision)",
          "quantization": {"bits": 0}
        }],
        "production": {
          "model_key": "winner",
          "gcd": "on",
          "temperature": 0,
          "top_p": 1,
          "top_k": 0,
          "max_tokens": 512,
          "voting": {
            "candidate_count": 3,
            "sample_temperature": 0.7,
            "always_vote": true
          }
        }
      }
      """)

    #expect(throws: selectedQuantizationError) {
      try ModelManifestLoader.production(url: url)
    }
  }
}
