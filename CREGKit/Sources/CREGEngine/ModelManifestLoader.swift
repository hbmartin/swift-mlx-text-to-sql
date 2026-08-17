import CREGCore
import Foundation

extension ModelManifestLoader {
  public static func production(
    url: URL,
    allowDebugCandidate: Bool = false,
    requiredRuntimeContract: ModelRuntimeContract? = nil
  ) throws
    -> ProductionGenerationConfiguration
  {
    let decoder = JSONDecoder()
    let document = try decoder.decode(
      Document.self, from: Data(contentsOf: url))
    if let requiredRuntimeContract {
      guard let bundled = document.modelRuntimeContract else {
        throw ModelManifestError.missingRuntimeContract
      }
      guard bundled.version == ModelRuntimeContract.currentVersion else {
        throw ModelManifestError.unsupportedRuntimeContract(
          expected: ModelRuntimeContract.currentVersion,
          actual: bundled.version)
      }
      guard bundled == requiredRuntimeContract else {
        throw ModelManifestError.runtimeProvenanceMismatch
      }
    }
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
    guard
      let model = document.models.first(
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
      debugModelIdentity: debugIdentity,
      modelRuntimeContract: document.modelRuntimeContract)
  }

  public static func production(
    bundle: Bundle = .main,
    allowDebugCandidate: Bool = false,
    requiredRuntimeContract: ModelRuntimeContract? = nil
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
      allowDebugCandidate: allowDebugCandidate,
      requiredRuntimeContract: requiredRuntimeContract)
  }

  /// Loads an app-bundled manifest together with the processed Info.plist
  /// contract. Unlike the URL-oriented tooling API, this always fails closed
  /// when runtime provenance is absent or inconsistent.
  public static func bundledProduction(
    bundle: Bundle = .main,
    allowDebugCandidate: Bool = false
  ) throws -> ProductionGenerationConfiguration {
    let runtimeContract = try ModelRuntimeContract.load(
      info: bundle.infoDictionary ?? [:])
    return try production(
      bundle: bundle,
      allowDebugCandidate: allowDebugCandidate,
      requiredRuntimeContract: runtimeContract)
  }
}
