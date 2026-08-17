import CREGCore
import CryptoKit
import Foundation

extension SQLGenClient {
  /// Load from a local weights directory (used by creg-eval-cli for parity runs).
  public static func live(
    directory: URL,
    diagnostics: DiagnosticsClient = .noop,
    experimentalKVBits: Int? = nil,
    useWiredMemory: Bool = false,
    useDirectPromptSuffix: Bool = true,
    metalCommandBufferLimitMB: Int? = nil,
    compiledQwen2MLPFusion: Bool = false,
    compiledQwen2QKVVerificationFusion: Bool = false,
    verificationMLPSkipLayers: [Int] = [],
    verificationMLPLongBatchExtraSkipLayers: [Int] = [],
    verificationMLPConfidenceSkip: VerificationMLPConfidenceSkipPolicy? = nil,
    verificationMLPAdditionalConfidenceSkips:
      [VerificationMLPConfidenceSkipPolicy] = [],
    questionAwareOutputHead: Bool = false,
    compactQuestionAwareOutputHead: Bool = false,
    productionNGramSpeculation: SQLNGramSpeculationPolicy? = nil,
    experimentalNGramDraftCorpus: [String] = [],
    experimentalNGramDraftTokens: Int = 0,
    experimentalNGramSerialPrefixTokens: Int = 0,
    experimentalNGramAdaptiveDraftMinimumSupport: Int = 0,
    enablePromptPrefixCache: Bool = true,
    runtimeMode: ModelRuntimeMode = .evaluated,
    preparationProgress: ModelPreparationProgress = .noop
  ) -> SQLGenClient {
    let generator = MLXSQLGenerator(
      source: .directory(directory),
      diagnostics: diagnostics,
      experimentalKVBits: experimentalKVBits,
      useWiredMemory: useWiredMemory,
      useDirectPromptSuffix: useDirectPromptSuffix,
      metalCommandBufferLimitMB: metalCommandBufferLimitMB,
      compiledQwen2MLPFusion: compiledQwen2MLPFusion,
      compiledQwen2QKVVerificationFusion:
        compiledQwen2QKVVerificationFusion,
      verificationMLPSkipLayers: verificationMLPSkipLayers,
      verificationMLPLongBatchExtraSkipLayers:
        verificationMLPLongBatchExtraSkipLayers,
      verificationMLPConfidenceSkip: verificationMLPConfidenceSkip,
      verificationMLPAdditionalConfidenceSkips:
        verificationMLPAdditionalConfidenceSkips,
      questionAwareOutputHead: questionAwareOutputHead,
      compactQuestionAwareOutputHead: compactQuestionAwareOutputHead,
      productionNGramSpeculation: productionNGramSpeculation,
      experimentalNGramDraftCorpus: experimentalNGramDraftCorpus,
      experimentalNGramDraftTokens: experimentalNGramDraftTokens,
      experimentalNGramSerialPrefixTokens:
        experimentalNGramSerialPrefixTokens,
      experimentalNGramAdaptiveDraftMinimumSupport:
        experimentalNGramAdaptiveDraftMinimumSupport,
      enablePromptPrefixCache: enablePromptPrefixCache,
      runtimeMode: runtimeMode,
      preparationProgress: preparationProgress)
    return SQLGenClient(
      prepareMode: { requestedMode in
        guard requestedMode == runtimeMode else {
          throw ModelPreparationFailure(
            code: "model_runtime_mode_unavailable",
            stage: .containerLoad,
            mode: requestedMode,
            userMessage: "That SQL model recovery mode is unavailable.",
            diagnostic:
              "Requested \(requestedMode.rawValue), client provides \(runtimeMode.rawValue).")
        }
        return try await generator.prepare(mode: runtimeMode)
      },
      runtimeMode: { runtimeMode },
      schemaPrompt: { try Self.schemaPrompt() },
      generate: { request in try await generator.generate(request) })
  }

  public static func grammarEBNF() throws -> String {
    try MLXSQLGenerator.grammarEBNF()
  }

  public static func schemaPrompt() throws -> String {
    try MLXSQLGenerator.schemaPrompt()
  }

  /// Adds payload-free model-load milestones around `prepare()`. Generation
  /// lifecycle details are emitted by the pipeline observer and live MLX
  /// adapter; both deliberately omit question text, SQL, seeds, model paths,
  /// and generated content.
  public func reportingModelLoad(
    to diagnostics: DiagnosticsClient,
    modelKey: String
  ) -> SQLGenClient {
    SQLGenClient(
      prepareMode: { mode in
        let started = ContinuousClock.now
        diagnostics.info(
          category: .model,
          code: "model_load_started",
          summary: "The bundled SQL model load started.",
          context: [
            "model_key": modelKey,
            "runtime_mode": mode.rawValue,
          ])
        do {
          let report = try await self.prepare(mode)
          diagnostics.info(
            category: .model,
            code: "model_load_finished",
            summary: "The bundled SQL model is ready.",
            context: [
              "model_key": modelKey,
              "runtime_mode": mode.rawValue,
              "elapsed_ms": Self.milliseconds(
                started.duration(to: .now).microseconds),
            ])
          return report
        } catch {
          diagnostics.record(
            DiagnosticEvent(
              level: .error,
              category: .model,
              code: "model_load_failed",
              summary: "The bundled SQL model load failed.",
              details: DiagnosticDetails.describe(error),
              context: [
                "model_key": modelKey,
                "runtime_mode": mode.rawValue,
                "elapsed_ms": Self.milliseconds(
                  started.duration(to: .now).microseconds),
              ]))
          throw error
        }
      },
      runtimeMode: { await self.runtimeMode() },
      schemaPrompt: { try self.schemaPrompt() },
      generate: self.generate)
  }

  private static func milliseconds(_ microseconds: Int64) -> String {
    String(format: "%.1f", Double(microseconds) / 1_000)
  }

  public static func systemPrompt(schema: String) -> String {
    MLXSQLGenerator.systemPrompt(schema: schema)
  }

  static func productionDraftCorpus(
    policy: SQLNGramSpeculationPolicy
  ) throws -> [String] {
    guard
      let url = Bundle.module.url(
        forResource: "sql_draft_corpus",
        withExtension: "json")
    else { throw CocoaError(.fileNoSuchFile) }
    let data = try Data(contentsOf: url)
    let digest = SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
    guard digest == policy.corpusSHA256 else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let resource = try JSONDecoder().decode(
      SQLDraftCorpusResource.self,
      from: data)
    guard resource.schemaVersion == 1,
      resource.statementCount == policy.statementCount,
      resource.statementCount == resource.statements.count,
      resource.sourceSHA256 == policy.sourceCorpusSHA256,
      resource.statements.allSatisfy({ statement in
        let normalized =
          statement
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .uppercased()
        return normalized.hasPrefix("SELECT") || normalized.hasPrefix("WITH")
      })
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return resource.statements
  }
}
