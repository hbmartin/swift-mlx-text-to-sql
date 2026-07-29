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

  private func checkedInManifestURL() throws -> URL {
    var ancestor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<8 {
      let candidate = ancestor.appendingPathComponent("model-manifest.json")
      if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
      ancestor.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
  }

  @Test func checkedInManifestLoadsVerifiedProductionConfiguration() throws {
    let production = try ModelManifestLoader.production(
      url: checkedInManifestURL())

    #expect(production.model.key == "ft-xiyansql-qwencoder-3b")
    #expect(
      production.model.repository
        == "hbmartin/creg-sql-xgenerationlab-xiyansql-qwencoder-3b-2502-mlx-4bit")
    #expect(
      production.model.revision
        == "7f97a54819b9329338a5353266d6d2a1294eb341")
    #expect(production.model.quantization == "4-bit")
    #expect(production.gcd == .off)
    #expect(production.temperature == 0)
    #expect(production.topP == 1)
    #expect(production.topK == 0)
    #expect(production.maxTokens == 128)
    #expect(production.runtimePolicyVersion == "iphone-30-second-v1")
    #expect(production.metalCommandBufferLimitMB == nil)
    #expect(!production.compiledQwen2MLPFusion)
    #expect(!production.compiledQwen2QKVVerificationFusion)
    #expect(production.verificationMLPSkipLayers.isEmpty)
    #expect(!production.questionAwareOutputHead)
    #expect(production.sqlNGramSpeculation == nil)
    #expect(production.candidateCount == 3)
    #expect(production.sampleTemperature == 0.7)
    #expect(
      QueryPipeline.Configuration(production: production)
        .repairSampleTemperature == 0.7)
    #expect(production.alwaysVote)
  }

  @Test func supportedSpeculativeDecodingPolicyLoadsFailClosed() throws {
    let revision = String(repeating: "a", count: 40)
    let policy = SQLNGramSpeculationPolicy.supported
    let url = try manifestURL(
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
          "model_key": "winner",
          "gcd": "off",
          "temperature": 0,
          "top_p": 1,
          "top_k": 0,
          "max_tokens": 128,
          "device_runtime": {
            "policy_version": "iphone-30-second-v2",
            "gcd": "off",
            "max_tokens": 128,
            "metal_command_buffer_limit_mb": 10,
            "speculative_decoding": {
              "strategy": "\(policy.strategy)",
              "order": \(policy.order),
              "draft_tokens": \(policy.draftTokens),
              "serial_prefix_tokens": \(policy.serialPrefixTokens),
              "adaptive_draft_min_support": \(policy.adaptiveDraftMinimumSupport),
              "corpus_sha256": "\(policy.corpusSHA256)",
              "source_corpus_sha256": "\(policy.sourceCorpusSHA256)",
              "statement_count": \(policy.statementCount)
            }
          },
          "voting": {
            "candidate_count": 1,
            "sample_temperature": 0,
            "always_vote": false
          }
        }
      }
      """)

    let production = try ModelManifestLoader.production(url: url)
    #expect(production.runtimePolicyVersion == "iphone-30-second-v2")
    #expect(production.metalCommandBufferLimitMB == 10)
    #expect(!production.compiledQwen2MLPFusion)
    #expect(!production.compiledQwen2QKVVerificationFusion)
    #expect(!production.questionAwareOutputHead)
    #expect(production.sqlNGramSpeculation == .supported)

    var corrupted = try String(contentsOf: url, encoding: .utf8)
    corrupted = corrupted.replacingOccurrences(
      of: "\"serial_prefix_tokens\": 1",
      with: "\"serial_prefix_tokens\": 0")
    let corruptedURL = try manifestURL(corrupted)
    #expect(throws: ModelManifestError.self) {
      try ModelManifestLoader.production(url: corruptedURL)
    }

    let corruptedSupport = try String(contentsOf: url, encoding: .utf8)
      .replacingOccurrences(
        of: "\"adaptive_draft_min_support\": 8",
        with: "\"adaptive_draft_min_support\": 7")
    let corruptedSupportURL = try manifestURL(corruptedSupport)
    #expect(throws: ModelManifestError.self) {
      try ModelManifestLoader.production(url: corruptedSupportURL)
    }
  }

  @Test func deviceRuntimeOverridesEvaluatedDecodingWithinItsTokenCap() throws {
    let revision = String(repeating: "a", count: 40)
    let url = try manifestURL(
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
          "model_key": "winner",
          "gcd": "on",
          "temperature": 0,
          "top_p": 1,
          "top_k": 0,
          "max_tokens": 512,
          "device_runtime": {
            "policy_version": "iphone-30-second-v1",
            "gcd": "off",
            "max_tokens": 128
          },
          "voting": {
            "candidate_count": 1,
            "sample_temperature": 0,
            "always_vote": false
          }
        }
      }
      """)

    let production = try ModelManifestLoader.production(url: url)
    #expect(production.gcd == .off)
    #expect(production.maxTokens == 128)
    #expect(production.runtimePolicyVersion == "iphone-30-second-v1")
    #expect(production.metalCommandBufferLimitMB == nil)
    #expect(!production.compiledQwen2MLPFusion)
    #expect(!production.questionAwareOutputHead)
  }

  @Test func deviceRuntimeV2RequiresEvaluatedMetalCommandBufferLimit() throws {
    let revision = String(repeating: "a", count: 40)
    let manifest =
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
          "model_key": "winner",
          "gcd": "off",
          "temperature": 0,
          "top_p": 1,
          "top_k": 0,
          "max_tokens": 128,
          "device_runtime": {
            "policy_version": "iphone-30-second-v2",
            "gcd": "off",
            "max_tokens": 128,
            "metal_command_buffer_limit_mb": 10
          },
          "voting": {
            "candidate_count": 1,
            "sample_temperature": 0,
            "always_vote": false
          }
        }
      }
      """

    let production = try ModelManifestLoader.production(
      url: manifestURL(manifest))
    #expect(production.metalCommandBufferLimitMB == 10)
    #expect(!production.compiledQwen2MLPFusion)
    #expect(!production.questionAwareOutputHead)

    for invalidLimit in [nil, 9, 40] as [Int?] {
      let declaration =
        invalidLimit.map {
          "\"metal_command_buffer_limit_mb\": \($0)"
        } ?? ""
      let invalidManifest = manifest.replacingOccurrences(
        of: "\"metal_command_buffer_limit_mb\": 10",
        with: declaration)
      #expect(throws: ModelManifestError.self) {
        try ModelManifestLoader.production(
          url: manifestURL(invalidManifest))
      }
    }

    let mislabeledV1 = manifest.replacingOccurrences(
      of: "iphone-30-second-v2",
      with: "iphone-30-second-v1")
    #expect(throws: ModelManifestError.self) {
      try ModelManifestLoader.production(url: manifestURL(mislabeledV1))
    }
  }

  @Test func deviceRuntimeV3RequiresEvaluatedQwen2FusionPolicy() throws {
    let revision = String(repeating: "a", count: 40)
    let policy = SQLNGramSpeculationPolicy.supported
    let manifest =
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
          "model_key": "winner",
          "gcd": "off",
          "temperature": 0,
          "top_p": 1,
          "top_k": 0,
          "max_tokens": 128,
          "device_runtime": {
            "policy_version": "iphone-30-second-v3",
            "gcd": "off",
            "max_tokens": 128,
            "metal_command_buffer_limit_mb": 10,
            "compiled_qwen2_mlp_fusion": true,
            "speculative_decoding": {
              "strategy": "\(policy.strategy)",
              "order": \(policy.order),
              "draft_tokens": \(policy.draftTokens),
              "serial_prefix_tokens": \(policy.serialPrefixTokens),
              "adaptive_draft_min_support": \(policy.adaptiveDraftMinimumSupport),
              "corpus_sha256": "\(policy.corpusSHA256)",
              "source_corpus_sha256": "\(policy.sourceCorpusSHA256)",
              "statement_count": \(policy.statementCount)
            }
          },
          "voting": {
            "candidate_count": 1,
            "sample_temperature": 0,
            "always_vote": false
          }
        }
      }
      """

    let production = try ModelManifestLoader.production(
      url: manifestURL(manifest))
    #expect(production.runtimePolicyVersion == "iphone-30-second-v3")
    #expect(production.metalCommandBufferLimitMB == 10)
    #expect(production.compiledQwen2MLPFusion)
    #expect(!production.compiledQwen2QKVVerificationFusion)
    #expect(!production.questionAwareOutputHead)
    #expect(production.sqlNGramSpeculation == .supported)

    let v4Manifest =
      manifest
      .replacingOccurrences(
        of: "iphone-30-second-v3",
        with: "iphone-30-second-v4"
      )
      .replacingOccurrences(
        of: "\"compiled_qwen2_mlp_fusion\": true,",
        with: """
          "compiled_qwen2_mlp_fusion": true,
          "question_aware_output_head": true,
          """)
    let v4Production = try ModelManifestLoader.production(
      url: manifestURL(v4Manifest))
    #expect(v4Production.runtimePolicyVersion == "iphone-30-second-v4")
    #expect(!v4Production.compiledQwen2QKVVerificationFusion)
    #expect(v4Production.questionAwareOutputHead)

    let v5Manifest =
      v4Manifest
      .replacingOccurrences(
        of: "iphone-30-second-v4",
        with: "iphone-30-second-v5"
      )
      .replacingOccurrences(
        of: "\"compiled_qwen2_mlp_fusion\": true,",
        with: """
          "compiled_qwen2_mlp_fusion": true,
          "compiled_qwen2_qkv_verification_fusion": true,
          """)
    let v5Production = try ModelManifestLoader.production(
      url: manifestURL(v5Manifest))
    #expect(v5Production.runtimePolicyVersion == "iphone-30-second-v5")
    #expect(v5Production.compiledQwen2QKVVerificationFusion)
    #expect(!v5Production.compactQuestionAwareOutputHead)

    let v6Manifest = v5Manifest.replacingOccurrences(
      of: "iphone-30-second-v5",
      with: "iphone-30-second-v6")
    let v6Production = try ModelManifestLoader.production(
      url: manifestURL(v6Manifest))
    #expect(v6Production.runtimePolicyVersion == "iphone-30-second-v6")
    #expect(v6Production.compiledQwen2QKVVerificationFusion)
    #expect(v6Production.questionAwareOutputHead)
    #expect(v6Production.compactQuestionAwareOutputHead)

    let v7Manifest =
      v6Manifest
      .replacingOccurrences(
        of: "iphone-30-second-v6",
        with: "iphone-30-second-v7"
      )
      .replacingOccurrences(
        of: "\"compiled_qwen2_qkv_verification_fusion\": true,",
        with: """
          "compiled_qwen2_qkv_verification_fusion": true,
          "verification_mlp_skip_layers": [8, 10],
          """)
    let v7Production = try ModelManifestLoader.production(
      url: manifestURL(v7Manifest))
    #expect(v7Production.runtimePolicyVersion == "iphone-30-second-v7")
    #expect(v7Production.verificationMLPSkipLayers == [8, 10])
    #expect(v7Production.compactQuestionAwareOutputHead)

    let v8Manifest =
      v7Manifest
      .replacingOccurrences(
        of: "iphone-30-second-v7",
        with: "iphone-30-second-v8"
      )
      .replacingOccurrences(
        of: "\"verification_mlp_skip_layers\": [8, 10],",
        with: """
          "verification_mlp_skip_layers": [8, 10],
          "verification_mlp_long_batch_extra_skip_layers": [2],
          """)
    let v8Production = try ModelManifestLoader.production(
      url: manifestURL(v8Manifest))
    #expect(v8Production.runtimePolicyVersion == "iphone-30-second-v8")
    #expect(v8Production.verificationMLPSkipLayers == [8, 10])
    #expect(v8Production.verificationMLPLongBatchExtraSkipLayers == [2])
    #expect(v8Production.verificationMLPConfidenceSkip == nil)
    #expect(v8Production.compactQuestionAwareOutputHead)

    let confidenceSkip = VerificationMLPConfidenceSkipPolicy.supported
    let v9Manifest =
      v8Manifest
      .replacingOccurrences(
        of: "iphone-30-second-v8",
        with: "iphone-30-second-v9"
      )
      .replacingOccurrences(
        of: "\"verification_mlp_long_batch_extra_skip_layers\": [2],",
        with: """
          "verification_mlp_long_batch_extra_skip_layers": [2],
          "verification_mlp_confidence_skip": {
            "layer": \(confidenceSkip.layer),
            "target_input_length": \(confidenceSkip.targetInputLength),
            "minimum_support": \(confidenceSkip.minimumSupport),
            "requires_unanimity": \(confidenceSkip.requiresUnanimity)
          },
          """)
    let v9Production = try ModelManifestLoader.production(
      url: manifestURL(v9Manifest))
    #expect(v9Production.runtimePolicyVersion == "iphone-30-second-v9")
    #expect(v9Production.verificationMLPSkipLayers == [8, 10])
    #expect(v9Production.verificationMLPLongBatchExtraSkipLayers == [2])
    #expect(v9Production.verificationMLPConfidenceSkip == .supported)
    #expect(v9Production.verificationMLPAdditionalConfidenceSkips.isEmpty)
    #expect(v9Production.compactQuestionAwareOutputHead)

    let singleDraftConfidenceSkip =
      VerificationMLPConfidenceSkipPolicy.supportedSingleDraft
    let v10Manifest =
      v9Manifest
      .replacingOccurrences(
        of: "iphone-30-second-v9",
        with: "iphone-30-second-v10"
      )
      .replacingOccurrences(
        of: """
          "verification_mlp_confidence_skip": {
            "layer": \(confidenceSkip.layer),
            "target_input_length": \(confidenceSkip.targetInputLength),
            "minimum_support": \(confidenceSkip.minimumSupport),
            "requires_unanimity": \(confidenceSkip.requiresUnanimity)
          },
          """,
        with: """
          "verification_mlp_confidence_skip": {
            "layer": \(confidenceSkip.layer),
            "target_input_length": \(confidenceSkip.targetInputLength),
            "minimum_support": \(confidenceSkip.minimumSupport),
            "requires_unanimity": \(confidenceSkip.requiresUnanimity)
          },
          "verification_mlp_additional_confidence_skips": [{
            "layer": \(singleDraftConfidenceSkip.layer),
            "target_input_length": \(singleDraftConfidenceSkip.targetInputLength),
            "minimum_support": \(singleDraftConfidenceSkip.minimumSupport),
            "requires_unanimity": \(singleDraftConfidenceSkip.requiresUnanimity)
          }],
          """)
    let v10Production = try ModelManifestLoader.production(
      url: manifestURL(v10Manifest))
    #expect(v10Production.runtimePolicyVersion == "iphone-30-second-v10")
    #expect(v10Production.verificationMLPConfidenceSkip == .supported)
    #expect(
      v10Production.verificationMLPAdditionalConfidenceSkips
        == [.supportedSingleDraft])
    #expect(v10Production.compactQuestionAwareOutputHead)

    let mislabeledV9WithAdditionalConfidenceSkip =
      v10Manifest.replacingOccurrences(
        of: "iphone-30-second-v10",
        with: "iphone-30-second-v9")
    #expect(throws: ModelManifestError.self) {
      try ModelManifestLoader.production(
        url: manifestURL(mislabeledV9WithAdditionalConfidenceSkip))
    }

    let invalidV10ConfidenceSkip = v10Manifest.replacingOccurrences(
      of: "\"layer\": 35",
      with: "\"layer\": 34")
    #expect(throws: ModelManifestError.self) {
      try ModelManifestLoader.production(
        url: manifestURL(invalidV10ConfidenceSkip))
    }

    for invalidConfidenceValue in ["256", "1024"] {
      let invalidManifest = v9Manifest.replacingOccurrences(
        of: "512",
        with: invalidConfidenceValue)
      #expect(throws: ModelManifestError.self) {
        try ModelManifestLoader.production(
          url: manifestURL(invalidManifest))
      }
    }

    let mislabeledV8WithConfidenceSkip = v9Manifest.replacingOccurrences(
      of: "iphone-30-second-v9",
      with: "iphone-30-second-v8")
    #expect(throws: ModelManifestError.self) {
      try ModelManifestLoader.production(
        url: manifestURL(mislabeledV8WithConfidenceSkip))
    }

    for invalidLongBatchSkipLayers in ["[14]", "[2, 14]", "null"] {
      let invalidManifest = v8Manifest.replacingOccurrences(
        of: "[2]",
        with: invalidLongBatchSkipLayers)
      #expect(throws: ModelManifestError.self) {
        try ModelManifestLoader.production(
          url: manifestURL(invalidManifest))
      }
    }

    let mislabeledV7WithLongBatchSkip = v8Manifest.replacingOccurrences(
      of: "iphone-30-second-v8",
      with: "iphone-30-second-v7")
    #expect(throws: ModelManifestError.self) {
      try ModelManifestLoader.production(
        url: manifestURL(mislabeledV7WithLongBatchSkip))
    }

    for invalidSkipLayers in ["[8]", "[10, 8]", "null"] {
      let invalidManifest = v7Manifest.replacingOccurrences(
        of: "[8, 10]",
        with: invalidSkipLayers)
      #expect(throws: ModelManifestError.self) {
        try ModelManifestLoader.production(
          url: manifestURL(invalidManifest))
      }
    }

    let mislabeledV6WithSkipLayers = v7Manifest.replacingOccurrences(
      of: "iphone-30-second-v7",
      with: "iphone-30-second-v6")
    #expect(throws: ModelManifestError.self) {
      try ModelManifestLoader.production(
        url: manifestURL(mislabeledV6WithSkipLayers))
    }

    for invalidQKVFusion in ["false", "null"] {
      let invalidManifest = v5Manifest.replacingOccurrences(
        of: "\"compiled_qwen2_qkv_verification_fusion\": true",
        with:
          "\"compiled_qwen2_qkv_verification_fusion\": \(invalidQKVFusion)")
      #expect(throws: ModelManifestError.self) {
        try ModelManifestLoader.production(
          url: manifestURL(invalidManifest))
      }
    }

    let invalidV6Manifest = v6Manifest.replacingOccurrences(
      of: "\"compiled_qwen2_qkv_verification_fusion\": true",
      with: "\"compiled_qwen2_qkv_verification_fusion\": false")
    #expect(throws: ModelManifestError.self) {
      try ModelManifestLoader.production(
        url: manifestURL(invalidV6Manifest))
    }

    for invalidHead in ["false", "null"] {
      let invalidManifest = v4Manifest.replacingOccurrences(
        of: "\"question_aware_output_head\": true",
        with: "\"question_aware_output_head\": \(invalidHead)")
      #expect(throws: ModelManifestError.self) {
        try ModelManifestLoader.production(
          url: manifestURL(invalidManifest))
      }
    }

    for invalidFusion in ["false", "null"] {
      let invalidManifest = manifest.replacingOccurrences(
        of: "\"compiled_qwen2_mlp_fusion\": true",
        with: "\"compiled_qwen2_mlp_fusion\": \(invalidFusion)")
      #expect(throws: ModelManifestError.self) {
        try ModelManifestLoader.production(
          url: manifestURL(invalidManifest))
      }
    }

    let mislabeledV2 = manifest.replacingOccurrences(
      of: "iphone-30-second-v3",
      with: "iphone-30-second-v2")
    #expect(throws: ModelManifestError.self) {
      try ModelManifestLoader.production(url: manifestURL(mislabeledV2))
    }
  }

  @Test func deviceRuntimeCannotExceedEvaluatedTokenCap() throws {
    let revision = String(repeating: "a", count: 40)
    let url = try manifestURL(
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
          "model_key": "winner",
          "gcd": "on",
          "temperature": 0,
          "top_p": 1,
          "top_k": 0,
          "max_tokens": 128,
          "device_runtime": {
            "policy_version": "iphone-30-second-v1",
            "gcd": "off",
            "max_tokens": 129
          },
          "voting": {
            "candidate_count": 1,
            "sample_temperature": 0,
            "always_vote": false
          }
        }
      }
      """)

    #expect(throws: ModelManifestError.self) {
      try ModelManifestLoader.production(url: url)
    }
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
