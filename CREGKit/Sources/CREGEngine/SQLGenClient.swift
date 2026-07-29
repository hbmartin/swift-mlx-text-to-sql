import CryptoKit
import Darwin
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXStructured
import Tokenizers

private struct HuggingFaceTokenizerBridge: MLXLMCommon.Tokenizer {
  let tokenizer: any Tokenizers.Tokenizer

  func encode(text: String, addSpecialTokens: Bool) -> [Int] {
    tokenizer.encode(text: text, addSpecialTokens: addSpecialTokens)
  }

  func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
    tokenizer.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
  }

  func convertTokenToId(_ token: String) -> Int? {
    tokenizer.convertTokenToId(token)
  }

  func convertIdToToken(_ id: Int) -> String? {
    tokenizer.convertIdToToken(id)
  }

  var bosToken: String? { tokenizer.bosToken }
  var eosToken: String? { tokenizer.eosToken }
  var unknownToken: String? { tokenizer.unknownToken }

  func applyChatTemplate(
    messages: [[String: any Sendable]],
    tools: [[String: any Sendable]]?,
    additionalContext: [String: any Sendable]?
  ) throws -> [Int] {
    do {
      return try tokenizer.applyChatTemplate(
        messages: messages,
        tools: tools,
        additionalContext: additionalContext)
    } catch Tokenizers.TokenizerError.missingChatTemplate {
      throw MLXLMCommon.TokenizerError.missingChatTemplate
    }
  }
}

private struct HuggingFaceTokenizerLoader: MLXLMCommon.TokenizerLoader {
  func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
    let tokenizer = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
    return HuggingFaceTokenizerBridge(tokenizer: tokenizer)
  }
}

/// The bundled SQL specialist: grammar-constrained SQL generation on MLX.
public struct SQLGenClient: Sendable {
  public var prepare: @Sendable () async throws -> Void
  public var generate: @Sendable (SQLGenerationRequest) async throws -> SQLGeneration

  public init(
    prepare: @escaping @Sendable () async throws -> Void = {},
    generate:
      @escaping @Sendable (SQLGenerationRequest) async throws
      -> SQLGeneration
  ) {
    self.prepare = prepare
    self.generate = generate
  }
}

actor PreparationCoalescer<Value: Sendable> {
  private var loaded: Value?
  private var inFlight: Task<Value, any Error>?

  func value(
    loading: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    if let loaded { return loaded }
    if let inFlight { return try await inFlight.value }
    let task = Task { try await loading() }
    inFlight = task
    do {
      let result = try await task.value
      loaded = result
      inFlight = nil
      return result
    } catch {
      inFlight = nil
      throw error
    }
  }
}

private final class MLXGenerationDiagnosticState: @unchecked Sendable {
  private let lock = NSLock()
  private var storedPhase: String

  init(phase: String) {
    self.storedPhase = phase
  }

  var phase: String {
    lock.lock()
    defer { lock.unlock() }
    return storedPhase
  }

  func setPhase(_ phase: String) {
    lock.lock()
    storedPhase = phase
    lock.unlock()
  }
}

/// An evaluated, immutable KV-cache snapshot for the prompt tokens shared by
/// every request. Generation always receives deep copies, so concurrent model
/// work cannot mutate the stored prefix.
private final class MLXPromptPrefixCache: @unchecked Sendable {
  let tokens: [Int]
  let suffixTokens: [Int]?
  let cache: [KVCache]

  init(tokens: [Int], suffixTokens: [Int]?, cache: [KVCache]) {
    self.tokens = tokens
    self.suffixTokens = suffixTokens
    self.cache = cache
  }
}

private struct SQLDraftCorpusResource: Decodable {
  let schemaVersion: Int
  let sourceSHA256: String
  let statementCount: Int
  let statements: [String]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case sourceSHA256 = "source_sha256"
    case statementCount = "statement_count"
    case statements
  }
}

/// Immutable request-vocabulary index. Static SQL/schema rows come only from
/// bundled production resources; request rows are selected when their decoded
/// text occurs in the current question or repair context.
private final class SQLQuestionOutputVocabulary: @unchecked Sendable {
  private static let trimCharacters = CharacterSet(
    charactersIn: " \t\r\n'\"`.,;:()[]{}<>!=+-*/%_|&")
  private static let lexicalPrefixes = [
    "", " ", ".", "_", "'", " '", "\"", "(", ", ",
  ]
  private static let syntaxLexemes = """
    SELECT FROM WHERE JOIN LEFT INNER OUTER ON AS AND OR NOT IN IS NULL
    GROUP BY ORDER ASC DESC HAVING LIMIT OFFSET DISTINCT WITH UNION ALL
    COUNT SUM AVG MIN MAX CASE WHEN THEN ELSE END BETWEEN LIKE GLOB
    = != <> < <= > >= + - * / % ( ) , . ; ' " _
    0 1 2 3 4 5 6 7 8 9 Yes No True False YES NO TRUE FALSE
    """.split(whereSeparator: { $0.isWhitespace }).map(String.init)

  private let staticTokenIDs: Set<Int>
  private let coreTokenIDs: [String: [Int]]

  init(
    vocabularySize: Int,
    tokenizer: any MLXLMCommon.Tokenizer,
    draftCorpus: [String],
    lexicalSources: [String],
    stopStrings: Set<String>
  ) {
    var staticTokenIDs = Set<Int>()
    func include(_ text: String) {
      staticTokenIDs.formUnion(
        tokenizer.encode(text: text, addSpecialTokens: false))
    }

    for statement in draftCorpus { include(statement) }
    var lexemes = Set<String>()
    for source in lexicalSources {
      lexemes.formUnion(
        source.split { character in
          !(character.isLetter || character.isNumber || character == "_")
        }.map(String.init))
    }
    lexemes.formUnion(Self.syntaxLexemes)
    for lexeme in lexemes {
      let variants = [
        lexeme,
        lexeme.lowercased(),
        lexeme.uppercased(),
        lexeme.capitalized,
      ]
      for variant in variants {
        for prefix in Self.lexicalPrefixes { include(prefix + variant) }
      }
    }
    for stopString in stopStrings { include(stopString) }
    for token in [tokenizer.eosToken, tokenizer.unknownToken].compactMap({ $0 }) {
      if let id = tokenizer.convertTokenToId(token) {
        staticTokenIDs.insert(id)
      }
    }
    self.staticTokenIDs = staticTokenIDs

    var coreTokenIDs: [String: [Int]] = [:]
    coreTokenIDs.reserveCapacity(vocabularySize)
    for tokenID in 0..<vocabularySize
    where tokenizer.convertIdToToken(tokenID) != nil {
      let decoded = tokenizer.decode(
        tokenIds: [tokenID],
        skipSpecialTokens: false)
      guard !decoded.isEmpty, decoded.count <= 40 else { continue }
      let core = decoded.trimmingCharacters(
        in: Self.trimCharacters
      ).lowercased()
      guard !core.isEmpty else { continue }
      coreTokenIDs[core, default: []].append(tokenID)
    }
    self.coreTokenIDs = coreTokenIDs
  }

  func allowedTokenIDs(for requestText: String) -> [Int] {
    var allowed = staticTokenIDs
    let words = requestText.split { character in
      !(character.isLetter || character.isNumber || character == "_")
    }
    for word in words {
      let characters = Array(word.lowercased())
      guard characters.count >= 2 else { continue }
      for start in 0..<(characters.count - 1) {
        var fragment = String(characters[start])
        for end in (start + 1)..<characters.count {
          fragment.append(characters[end])
          if let tokenIDs = coreTokenIDs[fragment] {
            allowed.formUnion(tokenIDs)
          }
        }
      }
    }
    return allowed.sorted()
  }
}

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
    experimentalNGramAdaptiveDraftMinimumSupport: Int = 0
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
        experimentalNGramAdaptiveDraftMinimumSupport)
    return SQLGenClient(
      prepare: { try await generator.prepare() },
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
      prepare: {
        let started = ContinuousClock.now
        diagnostics.info(
          category: .model,
          code: "model_load_started",
          summary: "The bundled SQL model load started.",
          context: ["model_key": modelKey])
        do {
          try await self.prepare()
          diagnostics.info(
            category: .model,
            code: "model_load_finished",
            summary: "The bundled SQL model is ready.",
            context: [
              "model_key": modelKey,
              "elapsed_ms": Self.milliseconds(
                started.duration(to: .now).microseconds),
            ])
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
                "elapsed_ms": Self.milliseconds(
                  started.duration(to: .now).microseconds),
              ]))
          throw error
        }
      },
      generate: self.generate)
  }

  private static func milliseconds(_ microseconds: Int64) -> String {
    String(format: "%.1f", Double(microseconds) / 1_000)
  }

  public static func systemPrompt(schema: String) -> String {
    MLXSQLGenerator.systemPrompt(schema: schema)
  }

  static func cutterFixtureData() throws -> Data {
    guard
      let url = Bundle.module.url(
        forResource: "sql_cutter_fixtures", withExtension: "json")
    else { throw CocoaError(.fileNoSuchFile) }
    return try Data(contentsOf: url)
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

/// Keeps the MLX model resident between turns (PRD §7.1) and runs
/// grammar-constrained decoding via MLXStructured (XGrammar).
actor MLXSQLGenerator {
  enum Source: Sendable {
    case directory(URL)
  }

  private let source: Source
  private let diagnostics: DiagnosticsClient
  private let experimentalKVBits: Int?
  private let useWiredMemory: Bool
  private let useDirectPromptSuffix: Bool
  private let metalCommandBufferLimitMB: Int?
  private let compiledQwen2MLPFusion: Bool
  private let compiledQwen2QKVVerificationFusion: Bool
  private let verificationMLPSkipLayers: Set<Int>
  private let verificationMLPLongBatchExtraSkipLayers: Set<Int>
  private let verificationMLPConfidenceSkips: [VerificationMLPConfidenceSkipPolicy]
  private let questionAwareOutputHead: Bool
  private let compactQuestionAwareOutputHead: Bool
  private let productionNGramSpeculation: SQLNGramSpeculationPolicy?
  private let experimentalNGramDraftCorpus: [String]
  private let ngramDraftTokens: Int
  private let ngramSerialPrefixTokens: Int
  private let ngramAdaptiveDraftMinimumSupport: Int
  private let ngramOrder: Int
  private let containerLoader = PreparationCoalescer<ModelContainer>()
  private var didPrepareCompiledQwen2QKVFusion = false
  private var promptPrefixCache: MLXPromptPrefixCache?
  private var ngramDraftModel: SQLNGramPredictor?
  private var questionOutputVocabulary: SQLQuestionOutputVocabulary?

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
    experimentalNGramAdaptiveDraftMinimumSupport: Int = 0
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
  }

  func prepare() async throws {
    let container = try await loadedContainer()
    try await preparedCompiledQwen2QKVFusion(using: container)
    _ = try await preparedPromptPrefixCache(using: container)
    _ = try await preparedNGramDraftModel(using: container)
    _ = try await preparedQuestionOutputVocabulary(using: container)
  }

  func generate(_ request: SQLGenerationRequest) async throws -> SQLGeneration {
    let operationStarted = ContinuousClock.now
    let state = MLXGenerationDiagnosticState(phase: "model_access")
    let baseContext = Self.generationDiagnosticContext(request)
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

  static func systemPrompt(schema: String) -> String {
    renderTemplate(
      resourceText(name: "system_prompt_template"),
      replacements: ["{{SCHEMA}}": schema])
  }

  static func repairPrompt(
    question: String,
    context: RepairContext
  ) -> String {
    let guidance = context.guidance
    let sourceColumns =
      guidance?.sourceColumns
      .sorted { $0.key < $1.key }
      .map { "\($0.key)(\($0.value.joined(separator: ", ")))" }
      .joined(separator: "; ") ?? ""
    let issueType = guidance?.issue.kind.rawValue ?? "unknown"
    let issueDisposition =
      guidance?.issue.disposition.rawValue ?? "repairable"
    let invalidReference = guidance?.invalidReference ?? ""
    let declaredSources =
      guidance?.declaredSources.joined(separator: ", ") ?? ""
    let possibleOwners =
      guidance?.possibleColumnOwners.joined(separator: ", ") ?? ""
    let foreignKeys =
      guidance?.relevantForeignKeys.joined(separator: "; ") ?? ""
    let correctiveInstruction = guidance?.correctiveInstruction ?? ""
    let replacements: [String: String] = [
      "{{QUESTION}}": question,
      "{{FAILED_SQL}}": context.failedSQL,
      "{{SQLITE_ERROR}}": context.errorMessage,
      "{{ISSUE_TYPE}}": issueType,
      "{{ISSUE_DISPOSITION}}": issueDisposition,
      "{{INVALID_REFERENCE}}": invalidReference,
      "{{DECLARED_SOURCES}}": declaredSources,
      "{{SOURCE_COLUMNS}}": sourceColumns,
      "{{POSSIBLE_COLUMN_OWNERS}}": possibleOwners,
      "{{RELEVANT_FOREIGN_KEYS}}": foreignKeys,
      "{{CORRECTIVE_INSTRUCTION}}": correctiveInstruction,
    ]
    return renderTemplate(
      resourceText(name: "repair_prompt_template"),
      replacements: replacements)
  }

  /// Replaces placeholders found in the original template exactly once.
  /// User-controlled values that contain placeholder-shaped text are data,
  /// not a second template pass.
  private static func renderTemplate(
    _ template: String,
    replacements: [String: String]
  ) -> String {
    guard
      let expression = try? NSRegularExpression(
        pattern: #"\{\{[A-Z_]+\}\}"#)
    else { return template }
    let matches = expression.matches(
      in: template,
      range: NSRange(template.startIndex..<template.endIndex, in: template))
    var result = ""
    var cursor = template.startIndex
    for match in matches {
      guard let range = Range(match.range, in: template) else { continue }
      result += template[cursor..<range.lowerBound]
      let token = String(template[range])
      result += replacements[token] ?? token
      cursor = range.upperBound
    }
    result += template[cursor...]
    return result
  }

  private static func resourceText(name: String) -> String {
    guard let url = Bundle.module.url(forResource: name, withExtension: "txt"),
      let value = try? String(contentsOf: url, encoding: .utf8)
    else {
      preconditionFailure("missing prompt resource: \(name).txt")
    }
    return value.trimmingCharacters(in: .newlines)
  }

  private func loadedContainer() async throws -> ModelContainer {
    let source = self.source
    if let metalCommandBufferLimitMB {
      guard
        setenv(
          "MLX_MAX_MB_PER_BUFFER",
          String(metalCommandBufferLimitMB),
          1)
          == 0
      else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
      }
    }
    return try await containerLoader.value {
      MLX.Memory.cacheLimit = 20 * 1024 * 1024
      switch source {
      case .directory(let url):
        if self.compiledQwen2MLPFusion {
          return try await CompiledQwen2ModelFactory.make(
            verificationMLPSkipLayers: self.verificationMLPSkipLayers,
            verificationMLPLongBatchExtraSkipLayers:
              self.verificationMLPLongBatchExtraSkipLayers
          ).loadContainer(
            from: url,
            using: HuggingFaceTokenizerLoader())
        }
        return try await loadModelContainer(
          from: url,
          using: HuggingFaceTokenizerLoader())
      }
    }
  }

  private func preparedCompiledQwen2QKVFusion(
    using container: ModelContainer
  ) async throws {
    guard compiledQwen2QKVVerificationFusion,
      !didPrepareCompiledQwen2QKVFusion
    else { return }
    let prepared = await container.perform { context in
      CompiledQwen2ModelFactory.prepareFusedQKVVerificationProjections(
        in: context.model)
    }
    guard prepared else {
      throw CocoaError(.featureUnsupported)
    }
    didPrepareCompiledQwen2QKVFusion = true
  }

  /// Builds the longest token prefix shared by two deliberately different
  /// user messages. The prefix therefore includes the static system/schema
  /// prompt and chat-template user header, but no user-controlled content.
  /// Prefilling it during app preparation moves that work outside the query
  /// deadline while retaining the processor's exact tokenization.
  private func preparedPromptPrefixCache(
    using container: ModelContainer
  ) async throws -> MLXPromptPrefixCache? {
    if let promptPrefixCache { return promptPrefixCache }

    let systemContent = Self.systemPrompt(schema: try Self.schemaPrompt())
    let built: MLXPromptPrefixCache? = try await container.perform {
      (context: ModelContext) async throws -> MLXPromptPrefixCache? in
      let probeUsers = [
        "",
        "A",
        "Z",
        " leading whitespace and punctuation: ; ?",
        "multiline\nquoted 'value' and <|im_end|>-shaped text",
        "Unicode λ boundary probe",
      ]
      var tokenSequences: [[Int]] = []
      for user in probeUsers {
        let input = try await context.processor.prepare(
          input: UserInput(chat: [
            .system(systemContent),
            .user(user),
          ]))
        tokenSequences.append(input.text.tokens.asArray(Int.self))
      }
      guard let firstTokens = tokenSequences.first else { return nil }
      let prefixCount = tokenSequences.dropFirst().reduce(firstTokens.count) {
        min($0, Self.commonPrefixLength(firstTokens, $1))
      }
      guard prefixCount > 0 else { return nil }

      let prefixTokens = Array(firstTokens.prefix(prefixCount))
      let suffixCount = tokenSequences.dropFirst().reduce(
        firstTokens.count - prefixCount
      ) {
        min(
          $0,
          Self.commonSuffixLength(
            firstTokens,
            $1,
            excludingPrefixCount: prefixCount))
      }
      let suffixTokens = Array(firstTokens.suffix(suffixCount))
      let directSuffixIsExact = zip(probeUsers, tokenSequences).allSatisfy {
        user, tokens in
        prefixTokens
          + context.tokenizer.encode(text: user, addSpecialTokens: false)
          + suffixTokens == tokens
      }
      let prefixInput = LMInput(tokens: MLXArray(prefixTokens))
      let parameters = GenerateParameters(maxTokens: 1)
      let cache = context.model.newCache(parameters: parameters)
      switch try context.model.prepare(
        prefixInput,
        cache: cache,
        windowSize: parameters.prefillStepSize)
      {
      case .tokens(let tokens):
        let output = context.model(
          tokens[text: .newAxis],
          cache: cache.isEmpty ? nil : cache,
          state: nil)
        eval(output.logits)
      case .logits(let output):
        eval(output.logits)
      }
      return MLXPromptPrefixCache(
        tokens: prefixTokens,
        suffixTokens: directSuffixIsExact ? suffixTokens : nil,
        cache: cache)
    }
    promptPrefixCache = built
    return built
  }

  private func preparedNGramDraftModel(
    using container: ModelContainer
  ) async throws -> SQLNGramPredictor? {
    guard ngramDraftTokens > 0 else { return nil }
    if let ngramDraftModel { return ngramDraftModel }

    let corpus =
      if let productionNGramSpeculation {
        try SQLGenClient.productionDraftCorpus(
          policy: productionNGramSpeculation)
      } else {
        experimentalNGramDraftCorpus
      }
    guard !corpus.isEmpty else { return nil }
    let built = await container.perform { context in
      let eosToken = context.tokenizer.eosTokenId
      let sequences = corpus.map { sql in
        var tokens = context.tokenizer.encode(
          text: sql,
          addSpecialTokens: false)
        if let eosToken { tokens.append(eosToken) }
        return tokens
      }
      return SQLNGramPredictor(sequences: sequences, order: ngramOrder)
    }
    ngramDraftModel = built
    return built
  }

  private func preparedQuestionOutputVocabulary(
    using container: ModelContainer
  ) async throws -> SQLQuestionOutputVocabulary? {
    guard questionAwareOutputHead else { return nil }
    if let questionOutputVocabulary { return questionOutputVocabulary }

    let corpus =
      if let productionNGramSpeculation {
        try SQLGenClient.productionDraftCorpus(
          policy: productionNGramSpeculation)
      } else {
        experimentalNGramDraftCorpus
      }
    guard !corpus.isEmpty else { return nil }
    let lexicalSources = [try Self.grammarEBNF(), try Self.schemaPrompt()]
    let built = await container.perform { context in
      guard
        let vocabularySize = CompiledQwen2ModelFactory.vocabularySize(
          of: context.model)
      else { return nil as SQLQuestionOutputVocabulary? }
      let vocabulary = SQLQuestionOutputVocabulary(
        vocabularySize: vocabularySize,
        tokenizer: context.tokenizer,
        draftCorpus: corpus,
        lexicalSources: lexicalSources,
        stopStrings: context.configuration.effectiveStopStrings)
      let warmupTokenIDs = vocabulary.allowedTokenIDs(
        for: "Question: warm up SQL output projection")
      if let model = CompiledQwen2ModelFactory.restricting(
        context.model,
        to: warmupTokenIDs)
      {
        let token = context.tokenizer.eosTokenId ?? 0
        for tokens in [[token], [token, token]] {
          let input = MLXArray(tokens).reshaped([1, -1])
          let cache = model.newCache(
            parameters: GenerateParameters(maxTokens: 1))
          eval(model(input, cache: cache))
        }
      }
      return vocabulary
    }
    questionOutputVocabulary = built
    return built
  }

  private nonisolated static func commonPrefixLength(
    _ lhs: [Int],
    _ rhs: [Int]
  ) -> Int {
    var index = 0
    let limit = min(lhs.count, rhs.count)
    while index < limit, lhs[index] == rhs[index] {
      index += 1
    }
    return index
  }

  private nonisolated static func commonSuffixLength(
    _ lhs: [Int],
    _ rhs: [Int],
    excludingPrefixCount prefixCount: Int
  ) -> Int {
    var count = 0
    let limit = min(lhs.count, rhs.count) - prefixCount
    while count < limit,
      lhs[lhs.count - count - 1] == rhs[rhs.count - count - 1]
    {
      count += 1
    }
    return count
  }

  private nonisolated static func applyingDirectPromptSuffix(
    _ prefix: MLXPromptPrefixCache?,
    userContent: String,
    tokenizer: any MLXLMCommon.Tokenizer
  ) -> (LMInput, [KVCache]?, Int)? {
    guard let prefix, let suffixTokens = prefix.suffixTokens else {
      return nil
    }
    let userTokens = tokenizer.encode(
      text: userContent,
      addSpecialTokens: false)
    return (
      LMInput(tokens: MLXArray(userTokens + suffixTokens)),
      prefix.cache.map { $0.copy() },
      prefix.tokens.count
    )
  }

  /// Returns the unchanged input when a tokenizer/model does not share the
  /// prepared prefix. This keeps directory-based evaluation compatible with
  /// arbitrary supported model families.
  private nonisolated static func applyingPromptPrefixCache(
    _ prefix: MLXPromptPrefixCache?,
    to input: LMInput
  ) -> (LMInput, [KVCache]?, Int) {
    guard let prefix else { return (input, nil, 0) }
    let tokens = input.text.tokens.asArray(Int.self)
    guard tokens.count > prefix.tokens.count,
      tokens.starts(with: prefix.tokens)
    else {
      return (input, nil, 0)
    }
    let remainder = Array(tokens.dropFirst(prefix.tokens.count))
    return (
      LMInput(tokens: MLXArray(remainder)),
      prefix.cache.map { $0.copy() },
      prefix.tokens.count
    )
  }

  static func grammarEBNF() throws -> String {
    guard let url = Bundle.module.url(forResource: "sql_grammar", withExtension: "ebnf") else {
      throw CocoaError(.fileNoSuchFile)
    }
    return try String(contentsOf: url, encoding: .utf8)
  }

  static func schemaPrompt() throws -> String {
    guard let url = Bundle.module.url(forResource: "schema_prompt", withExtension: "txt") else {
      throw CocoaError(.fileNoSuchFile)
    }
    return try String(contentsOf: url, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func stripSpecialTokens(_ text: String) -> String {
    text.replacingOccurrences(
      of: #"<\|[a-zA-Z0-9_]+\|>"#,
      with: "",
      options: .regularExpression)
  }

  /// Mirrors the Python evaluator's unconstrained-output normalization so
  /// parity measures runtime inference rather than fence/prose cleanup drift.
  static func extractSQL(_ text: String) -> String {
    var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let expression = try? NSRegularExpression(
      pattern: #"```(?:sql)?\s*(.*?)```"#,
      options: [.caseInsensitive, .dotMatchesLineSeparators]),
      let match = expression.firstMatch(
        in: value, range: NSRange(value.startIndex..., in: value)),
      let range = Range(match.range(at: 1), in: value)
    {
      value = String(value[range]).trimmingCharacters(
        in: .whitespacesAndNewlines)
    }
    if let expression = try? NSRegularExpression(
      pattern: #"(SELECT|WITH)\b.*"#,
      options: [.caseInsensitive, .dotMatchesLineSeparators]),
      let match = expression.firstMatch(
        in: value, range: NSRange(value.startIndex..., in: value)),
      let range = Range(match.range(at: 0), in: value)
    {
      value = String(value[range])
    }
    return truncateAtStatementEnd(value)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Cuts at the first SQL statement terminator outside quoted tokens and
  /// comments. Unicode-scalar iteration mirrors Python code-point iteration;
  /// grapheme composition and canonical equivalence cannot affect the cut.
  static func truncateAtStatementEnd(_ sql: String) -> String {
    enum State {
      case normal
      case singleQuote
      case doubleQuote
      case backtick
      case bracket
      case lineComment
      case blockComment
    }

    let scalars = sql.unicodeScalars
    var state = State.normal
    var index = scalars.startIndex
    while index < scalars.endIndex {
      let scalar = scalars[index].value
      let nextIndex = scalars.index(after: index)
      let following = nextIndex < scalars.endIndex ? scalars[nextIndex].value : nil

      switch state {
      case .normal:
        switch scalar {
        case 0x27: state = .singleQuote
        case 0x22: state = .doubleQuote
        case 0x60: state = .backtick
        case 0x5B: state = .bracket
        case 0x2D where following == 0x2D:
          state = .lineComment
          index = nextIndex
        case 0x2F where following == 0x2A:
          state = .blockComment
          index = nextIndex
        case 0x3B:
          return String(scalars[..<index])
        default: break
        }
      case .lineComment:
        if scalar == 0x0A || scalar == 0x0D { state = .normal }
      case .blockComment:
        if scalar == 0x2A, following == 0x2F {
          state = .normal
          index = nextIndex
        }
      case .singleQuote, .doubleQuote, .backtick, .bracket:
        let closing: UInt32
        switch state {
        case .singleQuote: closing = 0x27
        case .doubleQuote: closing = 0x22
        case .backtick: closing = 0x60
        case .bracket: closing = 0x5D
        default: preconditionFailure("unreachable SQL lexical state")
        }
        if scalar == closing {
          if following == closing {
            index = nextIndex
          } else {
            state = .normal
          }
        }
      }
      index = scalars.index(after: index)
    }
    return sql
  }
}
