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
  public var generate:
    @Sendable (SQLGenerationRequest) async throws -> SQLGeneration

  public init(
    prepare: @escaping @Sendable () async throws -> Void = {},
    generate: @escaping @Sendable (SQLGenerationRequest) async throws
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

extension SQLGenClient {
  /// Load from a local weights directory (used by creg-eval-cli for parity runs).
  public static func live(
    directory: URL,
    diagnostics: DiagnosticsClient = .noop
  ) -> SQLGenClient {
    let generator = MLXSQLGenerator(
      source: .directory(directory), diagnostics: diagnostics)
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
          diagnostics.record(DiagnosticEvent(
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
    guard let url = Bundle.module.url(
      forResource: "sql_cutter_fixtures", withExtension: "json")
    else { throw CocoaError(.fileNoSuchFile) }
    return try Data(contentsOf: url)
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
  private let containerLoader = PreparationCoalescer<ModelContainer>()

  private nonisolated var modelName: String {
    switch source {
    case .directory(let url): url.lastPathComponent
    }
  }

  init(source: Source, diagnostics: DiagnosticsClient = .noop) {
    self.source = source
    self.diagnostics = diagnostics
  }

  func prepare() async throws {
    _ = try await loadedContainer()
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
      state.setPhase("schema_loading")
      let schema = try Self.schemaPrompt()

      let userContent = request.repair.map {
        Self.repairPrompt(question: request.question, context: $0)
      } ?? "Question: \(request.question)"
      let systemContent = Self.systemPrompt(schema: schema)

      let generation = try await container.perform { (context: ModelContext) in
        state.setPhase("input_preparation")
        let inputStarted = ContinuousClock.now
        diagnosticClient.info(
          category: .inference,
          code: "mlx_input_preparation_started",
          summary: "MLX prompt tokenization and input preparation started.",
          context: baseContext)
        let chat: [Chat.Message] = [.system(systemContent), .user(userContent)]
        let input = try await context.processor.prepare(
          input: UserInput(chat: chat))
        diagnosticClient.info(
          category: .inference,
          code: "mlx_input_preparation_finished",
          summary: "MLX prompt tokenization and input preparation finished.",
          context: baseContext.merging([
            "elapsed_ms": Self.milliseconds(
              inputStarted.duration(to: .now).microseconds)
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
          temperature: Float(request.temperature),
          topP: 1.0,
          topK: 0,
          seed: request.seed)
        let stream: AsyncStream<Generation>
        switch request.gcd {
        case .on:
          stream = try await MLXStructured.generate(
            input: input,
            parameters: parameters,
            context: context,
            ebnf: try Self.grammarEBNF())
        case .off:
          stream = try MLXLMCommon.generate(
            input: input,
            parameters: parameters,
            context: context)
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
          default:
            break
          }
        }
        let decodeElapsed = decodeStarted.duration(to: .now).microseconds
        diagnosticClient.info(
          category: .inference,
          code: "mlx_token_stream_finished",
          summary: "MLX token streaming finished.",
          context: baseContext.merging([
            "chunk_count": String(chunkCount),
            "decode_elapsed_ms": Self.milliseconds(decodeElapsed),
            "output_character_count": String(sql.count),
            "task_cancelled": String(Task.isCancelled),
            "token_count": tokenCount.map(String.init) ?? "unknown",
            "tokens_per_second": String(format: "%.1f", tokensPerSecond),
          ]) { current, _ in current })
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
          elapsedMicroseconds: decodeElapsed)
      }
      diagnosticClient.info(
        category: .inference,
        code: "mlx_sql_generation_finished",
        summary: "MLX SQL generation finished.",
        context: baseContext.merging([
          "decode_elapsed_ms": Self.milliseconds(
            generation.elapsedMicroseconds),
          "token_count": generation.tokenCount.map(String.init) ?? "unknown",
          "tokens_per_second": String(
            format: "%.1f", generation.tokensPerSecond),
          "total_elapsed_ms": Self.milliseconds(
            operationStarted.duration(to: .now).microseconds),
        ]) { current, _ in current })
      return generation
    } catch {
      var context = baseContext
      context["error_type"] = String(reflecting: type(of: error))
      context["failure_phase"] = state.phase
      context["is_cancellation"] = String(error is CancellationError)
      context["total_elapsed_ms"] = Self.milliseconds(
        operationStarted.duration(to: .now).microseconds)
      diagnosticClient.record(DiagnosticEvent(
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
    let replacements = [
      "{{QUESTION}}": question,
      "{{FAILED_SQL}}": context.failedSQL,
      "{{SQLITE_ERROR}}": context.errorMessage,
      "{{ISSUE_TYPE}}": guidance?.issue.kind.rawValue ?? "unknown",
      "{{ISSUE_DISPOSITION}}": guidance?.issue.disposition.rawValue ?? "repairable",
      "{{DECLARED_SOURCES}}": guidance?.declaredSources.joined(separator: ", ") ?? "",
      "{{POSSIBLE_COLUMN_OWNERS}}": guidance?.possibleColumnOwners.joined(separator: ", ") ?? "",
      "{{FAILED_FINGERPRINTS}}": guidance?.failedFingerprints.joined(separator: ", ") ?? "",
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
    guard let expression = try? NSRegularExpression(
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
    return try await containerLoader.value {
      MLX.Memory.cacheLimit = 20 * 1024 * 1024
      switch source {
      case .directory(let url):
        return try await loadModelContainer(
          from: url,
          using: HuggingFaceTokenizerLoader())
      }
    }
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
