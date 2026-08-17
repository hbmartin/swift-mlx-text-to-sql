import CREGCore
import Darwin
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXStructured

/// Keeps the MLX model resident between turns (PRD §7.1) and runs
/// grammar-constrained decoding via MLXStructured (XGrammar).
actor MLXSQLGenerator {
  enum Source: Sendable {
    case directory(URL)
  }

  let source: Source
  let diagnostics: DiagnosticsClient
  let experimentalKVBits: Int?
  let useWiredMemory: Bool
  let useDirectPromptSuffix: Bool
  let metalCommandBufferLimitMB: Int?
  let compiledQwen2MLPFusion: Bool
  let compiledQwen2QKVVerificationFusion: Bool
  let verificationMLPSkipLayers: Set<Int>
  let verificationMLPLongBatchExtraSkipLayers: Set<Int>
  let verificationMLPConfidenceSkips: [VerificationMLPConfidenceSkipPolicy]
  let questionAwareOutputHead: Bool
  let compactQuestionAwareOutputHead: Bool
  let productionNGramSpeculation: SQLNGramSpeculationPolicy?
  let experimentalNGramDraftCorpus: [String]
  let ngramDraftTokens: Int
  let ngramSerialPrefixTokens: Int
  let ngramAdaptiveDraftMinimumSupport: Int
  let ngramOrder: Int
  let enablePromptPrefixCache: Bool
  let runtimeMode: ModelRuntimeMode
  let preparationProgress: ModelPreparationProgress
  let containerLoader = PreparationCoalescer<ModelContainer>()
  var didPrepareCompiledQwen2QKVFusion = false
  var promptPrefixCache: MLXPromptPrefixCache?
  var ngramDraftModel: SQLNGramPredictor?
  var questionOutputVocabulary: SQLQuestionOutputVocabulary?

  private nonisolated var modelName: String {
    switch source {
    case .directory(let url): url.lastPathComponent
    }
  }

  init(
    source: Source,
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
  ) {
    self.source = source
    self.diagnostics = diagnostics
    self.experimentalKVBits = experimentalKVBits
    self.useWiredMemory = useWiredMemory
    self.useDirectPromptSuffix = useDirectPromptSuffix
    self.metalCommandBufferLimitMB = metalCommandBufferLimitMB
    self.compiledQwen2MLPFusion = compiledQwen2MLPFusion
    self.compiledQwen2QKVVerificationFusion =
      compiledQwen2QKVVerificationFusion
    self.verificationMLPSkipLayers = Set(verificationMLPSkipLayers)
    self.verificationMLPLongBatchExtraSkipLayers =
      Set(verificationMLPLongBatchExtraSkipLayers)
    self.verificationMLPConfidenceSkips =
      (verificationMLPConfidenceSkip.map { [$0] } ?? [])
      + verificationMLPAdditionalConfidenceSkips
    self.questionAwareOutputHead = questionAwareOutputHead
    self.compactQuestionAwareOutputHead = compactQuestionAwareOutputHead
    self.productionNGramSpeculation = productionNGramSpeculation
    self.experimentalNGramDraftCorpus = experimentalNGramDraftCorpus
    self.ngramDraftTokens =
      productionNGramSpeculation?.draftTokens
      ?? experimentalNGramDraftTokens
    self.ngramSerialPrefixTokens =
      productionNGramSpeculation?.serialPrefixTokens
      ?? experimentalNGramSerialPrefixTokens
    self.ngramAdaptiveDraftMinimumSupport =
      productionNGramSpeculation?.adaptiveDraftMinimumSupport
      ?? experimentalNGramAdaptiveDraftMinimumSupport
    self.ngramOrder = productionNGramSpeculation?.order ?? 6
    self.enablePromptPrefixCache = enablePromptPrefixCache
    self.runtimeMode = runtimeMode
    self.preparationProgress = preparationProgress
  }

  func prepare(mode: ModelRuntimeMode) async throws -> ModelPreparationReport {
    precondition(mode == runtimeMode)
    let started = ContinuousClock.now
    let container = try await prepareStage(.containerLoad, mode: mode) {
      try await self.loadedContainer()
    }
    try await prepareStage(.qkvFusion, mode: mode) {
      try await self.preparedCompiledQwen2QKVFusion(using: container)
    }
    _ = try await prepareStage(.promptCache, mode: mode) {
      try await self.preparedPromptPrefixCache(using: container)
    }
    _ = try await prepareStage(.ngramDraft, mode: mode) {
      try await self.preparedNGramDraftModel(using: container)
    }
    _ = try await prepareStage(.outputVocabulary, mode: mode) {
      try await self.preparedQuestionOutputVocabulary(using: container)
    }
    return ModelPreparationReport(
      mode: mode,
      elapsedMilliseconds:
        Double(started.duration(to: .now).microseconds) / 1_000)
  }

  private func prepareStage<Value>(
    _ stage: ModelPreparationStage,
    mode: ModelRuntimeMode,
    operation: () async throws -> Value
  ) async throws -> Value {
    let started = ContinuousClock.now
    let before = ModelRuntimeDiagnostics.memoryContext(prefix: "before")
    await preparationProgress.stageStarted(stage, mode)
    diagnostics.info(
      category: .model,
      code: "model_preparation_stage_started",
      summary: "A SQL model preparation stage started.",
      context: before.merging([
        "stage": stage.rawValue,
        "runtime_mode": mode.rawValue,
      ]) { _, new in new })
    do {
      let value = try await operation()
      let context = ModelRuntimeDiagnostics.memoryContext(prefix: "after")
        .merging([
          "stage": stage.rawValue,
          "runtime_mode": mode.rawValue,
          "elapsed_ms": Self.milliseconds(
            started.duration(to: .now).microseconds),
        ]) { _, new in new }
      diagnostics.info(
        category: .model,
        code: "model_preparation_stage_finished",
        summary: "A SQL model preparation stage finished.",
        context: context)
      await preparationProgress.stageFinished(stage, mode)
      return value
    } catch {
      let nsError = error as NSError
      let failure = ModelPreparationFailure(
        code: "model_\(stage.rawValue)_failed",
        stage: stage,
        mode: mode,
        userMessage: Self.userMessage(for: stage),
        diagnostic: DiagnosticDetails.sanitizedDescription(error),
        errorDomain: nsError.domain,
        errorCode: nsError.code)
      var context = ModelRuntimeDiagnostics.memoryContext(prefix: "after")
      context["stage"] = stage.rawValue
      context["runtime_mode"] = mode.rawValue
      context["elapsed_ms"] = Self.milliseconds(
        started.duration(to: .now).microseconds)
      context["error_domain"] = nsError.domain
      context["error_code"] = String(nsError.code)
      diagnostics.record(DiagnosticEvent(
        level: .error,
        category: .model,
        code: failure.code,
        summary: "A SQL model preparation stage failed.",
        details: DiagnosticDetails.describe(error),
        context: context))
      await preparationProgress.stageFailed(failure)
      throw failure
    }
  }

  private nonisolated static func userMessage(
    for stage: ModelPreparationStage
  ) -> String {
    switch stage {
    case .containerLoad:
      "The SQL model could not be loaded. Restart CREG and try again."
    case .qkvFusion, .promptCache, .ngramDraft, .outputVocabulary:
      "The optimized SQL runtime could not be prepared. Try again or use Developer Mode recovery."
    case .buildPolicy, .receiptValidation, .metalResource:
      "The installed SQL model is unavailable. Install a fresh build of CREG."
    }
  }

  func generate(_ request: SQLGenerationRequest) async throws -> SQLGeneration {
    let operationStarted = ContinuousClock.now
    let state = MLXGenerationDiagnosticState(phase: "model_access")
    let baseContext = Self.generationDiagnosticContext(request).merging([
      "runtime_mode": runtimeMode.rawValue,
      "evaluated": String(runtimeMode.isEvaluated),
    ]) { current, _ in current }
    let diagnosticClient = diagnostics
    let generatedModelName = modelName
    diagnosticClient.info(
      category: .inference,
      code: "mlx_sql_generation_started",
      summary: "MLX SQL generation started.",
      context: baseContext)

    do {
      let container = try await loadedContainer()
      try await preparedCompiledQwen2QKVFusion(using: container)
      let prefixCache = try await preparedPromptPrefixCache(using: container)
      let ngramDraftModel = try await preparedNGramDraftModel(using: container)
      let questionOutputVocabulary = try await preparedQuestionOutputVocabulary(using: container)

      let userContent =
        request.repair.map {
          Self.repairPrompt(question: request.question, context: $0)
        } ?? "Question: \(request.question)"
      let systemContent: String?
      if useDirectPromptSuffix,
        prefixCache?.suffixTokens != nil
      {
        systemContent = nil
      } else {
        state.setPhase("schema_loading")
        systemContent = Self.systemPrompt(schema: try Self.schemaPrompt())
      }

      let generation = try await container.perform { (context: ModelContext) in
        var generationContext = context
        state.setPhase("input_preparation")
        let inputStarted = ContinuousClock.now
        diagnosticClient.info(
          category: .inference,
          code: "mlx_input_preparation_started",
          summary: "MLX prompt tokenization and input preparation started.",
          context: baseContext)
        let inputAndCache: (LMInput, [KVCache]?, Int)
        let inputPreparationMode: String
        if useDirectPromptSuffix,
          let direct = Self.applyingDirectPromptSuffix(
            prefixCache,
            userContent: userContent,
            tokenizer: context.tokenizer)
        {
          inputAndCache = direct
          inputPreparationMode = "direct_user_suffix"
        } else {
          guard let systemContent else {
            preconditionFailure("missing fallback system prompt")
          }
          let chat: [Chat.Message] = [
            .system(systemContent), .user(userContent),
          ]
          let fullInput = try await context.processor.prepare(
            input: UserInput(chat: chat))
          inputAndCache = Self.applyingPromptPrefixCache(
            prefixCache,
            to: fullInput)
          inputPreparationMode = "full_chat_template"
        }
        let (input, generationCache, cachedTokenCount) = inputAndCache
        let inputPreparationMicroseconds =
          inputStarted.duration(to: .now).microseconds
        diagnosticClient.info(
          category: .inference,
          code: "mlx_input_preparation_finished",
          summary: "MLX prompt tokenization and input preparation finished.",
          context: baseContext.merging([
            "cached_prompt_token_count": String(cachedTokenCount),
            "elapsed_ms": Self.milliseconds(
              inputPreparationMicroseconds),
            "input_preparation_mode": inputPreparationMode,
            "remaining_prompt_token_count": String(input.text.tokens.size),
          ]) { current, _ in current })

        state.setPhase("decoder_setup")
        let decoderStarted = ContinuousClock.now
        diagnosticClient.info(
          category: .inference,
          code: "mlx_decoder_setup_started",
          summary: "MLX decoder setup started.",
          context: baseContext)
        let parameters = GenerateParameters(
          maxTokens: request.maxTokens,
          kvBits: experimentalKVBits,
          temperature: Float(request.temperature),
          topP: 1.0,
          topK: 0,
          seed: request.seed)
        if let questionOutputVocabulary,
          request.repair == nil,
          request.gcd == .off,
          request.temperature == 0
        {
          let allowedTokenIDs = questionOutputVocabulary.allowedTokenIDs(
            for: userContent)
          let returnsCompactLogits =
            compactQuestionAwareOutputHead
            && ngramDraftModel != nil
            && ngramDraftTokens > 0
            && ngramSerialPrefixTokens == 1
          if let restrictedModel = CompiledQwen2ModelFactory.restricting(
            context.model,
            to: allowedTokenIDs,
            returnsCompactLogits: returnsCompactLogits)
          {
            generationContext.model = restrictedModel
          }
        }
        let stream: AsyncStream<Generation>
        switch request.gcd {
        case .on:
          stream = try await MLXStructured.generate(
            input: input,
            cache: generationCache,
            parameters: parameters,
            context: generationContext,
            ebnf: try Self.grammarEBNF())
        case .off:
          if let ngramDraftModel,
            ngramDraftTokens > 0,
            request.repair == nil
          {
            stream = try generateWithSQLNGramDraft(
              input: input,
              cache: generationCache,
              parameters: parameters,
              context: generationContext,
              predictor: ngramDraftModel,
              numDraftTokens: ngramDraftTokens,
              serialPrefixTokens: ngramSerialPrefixTokens,
              adaptiveDraftMinimumSupport:
                ngramAdaptiveDraftMinimumSupport,
              confidenceSkipPolicies: verificationMLPConfidenceSkips,
              wiredMemoryTicket: Self.wiredMemoryTicket(
                enabled: useWiredMemory))
          } else {
            stream = try MLXLMCommon.generate(
              input: input,
              cache: generationCache,
              parameters: parameters,
              context: generationContext,
              wiredMemoryTicket: Self.wiredMemoryTicket(
                enabled: useWiredMemory))
          }
        }
        diagnosticClient.info(
          category: .inference,
          code: "mlx_decoder_setup_finished",
          summary: "MLX decoder setup finished.",
          context: baseContext.merging([
            "elapsed_ms": Self.milliseconds(
              decoderStarted.duration(to: .now).microseconds)
          ]) { current, _ in current })

        state.setPhase("token_streaming")
        let decodeStarted = ContinuousClock.now
        diagnosticClient.info(
          category: .inference,
          code: "mlx_token_stream_started",
          summary: "MLX token streaming started.",
          context: baseContext)
        let heartbeat = Task {
          while !Task.isCancelled {
            do {
              try await Task.sleep(for: .seconds(5))
            } catch {
              break
            }
            guard !Task.isCancelled else { break }
            diagnosticClient.info(
              category: .inference,
              code: "mlx_token_stream_heartbeat",
              summary: "MLX token streaming is still in progress.",
              context: baseContext.merging([
                "decode_elapsed_ms": Self.milliseconds(
                  decodeStarted.duration(to: .now).microseconds)
              ]) { current, _ in current })
          }
        }
        defer { heartbeat.cancel() }

        var sql = ""
        var tokensPerSecond = 0.0
        var tokenCount: Int?
        var speculation: SQLSpeculationMetrics?
        var chunkCount = 0
        var didObserveFirstChunk = false
        for await generation in stream {
          switch generation {
          case .chunk(let chunk):
            chunkCount += 1
            sql += chunk
            if !didObserveFirstChunk {
              didObserveFirstChunk = true
              diagnosticClient.info(
                category: .inference,
                code: "mlx_first_output_chunk_observed",
                summary: "MLX produced its first output chunk.",
                context: baseContext.merging([
                  "first_chunk_elapsed_ms": Self.milliseconds(
                    decodeStarted.duration(to: .now).microseconds)
                ]) { current, _ in current })
            }
          case .info(let info):
            tokensPerSecond = info.tokensPerSecond
            tokenCount = info.generationTokenCount
            if let metrics = info.speculativeDecodingTelemetry {
              speculation = SQLSpeculationMetrics(
                roundCount: metrics.roundCount,
                draftTokenCount: metrics.draftTokenCount,
                acceptedDraftTokenCount: metrics.acceptedDraftTokenCount,
                targetModelCallCount: metrics.targetModelCallCount,
                targetVerifiedTokenCount: metrics.targetVerifiedTokenCount,
                emittedTokenCount: metrics.emittedTokenCount)
            }
          default:
            break
          }
        }
        let decodeElapsed = decodeStarted.duration(to: .now).microseconds
        var streamFinishedContext = [
          "chunk_count": String(chunkCount),
          "decode_elapsed_ms": Self.milliseconds(decodeElapsed),
          "output_character_count": String(sql.count),
          "task_cancelled": String(Task.isCancelled),
          "token_count": tokenCount.map(String.init) ?? "unknown",
          "tokens_per_second": String(format: "%.1f", tokensPerSecond),
        ]
        if let speculation {
          streamFinishedContext["speculation_round_count"] = String(
            speculation.roundCount)
          streamFinishedContext["speculation_draft_token_count"] = String(
            speculation.draftTokenCount)
          streamFinishedContext["speculation_accepted_token_count"] = String(
            speculation.acceptedDraftTokenCount)
          streamFinishedContext["speculation_target_call_count"] = String(
            speculation.targetModelCallCount)
        }
        diagnosticClient.info(
          category: .inference,
          code: "mlx_token_stream_finished",
          summary: "MLX token streaming finished.",
          context: baseContext.merging(streamFinishedContext) {
            current, _ in current
          })
        try Task.checkCancellation()

        state.setPhase("output_normalization")
        let normalized = Self.stripSpecialTokens(sql)
        let finalSQL =
          request.gcd == .on
          ? normalized.trimmingCharacters(in: .whitespacesAndNewlines)
          : Self.extractSQL(normalized)
        state.setPhase("finished")
        return SQLGeneration(
          sql: finalSQL,
          tokensPerSecond: tokensPerSecond,
          modelName: generatedModelName,
          tokenCount: tokenCount,
          inputPreparationMicroseconds: inputPreparationMicroseconds,
          speculation: speculation,
          elapsedMicroseconds: decodeElapsed)
      }
      var finishedContext = [
        "decode_elapsed_ms": Self.milliseconds(
          generation.elapsedMicroseconds),
        "token_count": generation.tokenCount.map(String.init) ?? "unknown",
        "tokens_per_second": String(
          format: "%.1f", generation.tokensPerSecond),
        "total_elapsed_ms": Self.milliseconds(
          operationStarted.duration(to: .now).microseconds),
      ]
      if let speculation = generation.speculation {
        finishedContext["speculation_round_count"] = String(
          speculation.roundCount)
        finishedContext["speculation_draft_token_count"] = String(
          speculation.draftTokenCount)
        finishedContext["speculation_accepted_token_count"] = String(
          speculation.acceptedDraftTokenCount)
        finishedContext["speculation_target_call_count"] = String(
          speculation.targetModelCallCount)
      }
      diagnosticClient.info(
        category: .inference,
        code: "mlx_sql_generation_finished",
        summary: "MLX SQL generation finished.",
        context: baseContext.merging(finishedContext) { current, _ in current })
      return generation
    } catch {
      var context = baseContext
      context["error_type"] = String(reflecting: type(of: error))
      context["failure_phase"] = state.phase
      context["is_cancellation"] = String(error is CancellationError)
      context["total_elapsed_ms"] = Self.milliseconds(
        operationStarted.duration(to: .now).microseconds)
      diagnosticClient.record(
        DiagnosticEvent(
          level: .error,
          category: .inference,
          code: "mlx_sql_generation_failed",
          summary: "MLX SQL generation failed during \(state.phase).",
          details: PipelineDiagnosticPrivacy.redact(
            DiagnosticDetails.describe(error),
            conversationContent: [request.question]),
          context: context))
      throw error
    }
  }

  private nonisolated static func generationDiagnosticContext(
    _ request: SQLGenerationRequest
  ) -> [String: String] {
    [
      "candidate_role": diagnosticRole(request.role),
      "gcd": request.gcd.rawValue,
      "is_repair": String(request.repair != nil),
      "max_tokens": String(request.maxTokens),
      "temperature": String(format: "%.2f", request.temperature),
    ]
  }

  private nonisolated static func diagnosticRole(
    _ role: CandidateRole
  ) -> String {
    switch role {
    case .starter(let starter):
      "starter_\(starter.rawValue)"
    case .followUpPreflight(let rank):
      "follow_up_preflight_\(rank)"
    case .initial:
      "initial"
    case .repair(let attempt):
      "repair_\(attempt)"
    case .deterministicAnchor:
      "deterministic_anchor"
    case .consistencySample(let index):
      "consistency_sample_\(index)"
    }
  }

  private nonisolated static func milliseconds(
    _ microseconds: Int64
  ) -> String {
    String(format: "%.1f", Double(microseconds) / 1_000)
  }

  /// Keep model weights resident while unconstrained generation is active.
  /// The OS-recommended working-set limit is a cap, not an allocation, and
  /// MLX restores the previous process limit when the generation task ends.
  private nonisolated static func wiredMemoryTicket(
    enabled: Bool
  ) -> WiredMemoryTicket? {
    guard enabled,
      let limit = GPU.maxRecommendedWorkingSetBytes(),
      limit > 0
    else { return nil }
    return MLXLMCommon.WiredFixedPolicy(limit: limit).ticket(
      size: limit,
      kind: .active)
  }

}
