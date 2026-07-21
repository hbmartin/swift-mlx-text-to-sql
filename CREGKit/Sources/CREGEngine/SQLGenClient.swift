import Foundation
import HuggingFace
import MLX
import MLXLLM
import MLXLMCommon
import MLXStructured
import Tokenizers

private enum ModelArtifactDownloadError: Error {
  case invalidRepositoryID(String)
}

/// Concrete adapters mirror mlx-swift-lm's Hugging Face convenience macros
/// without requiring a compiler plugin in the consuming Xcode target.
private struct HubArtifactDownloader: MLXLMCommon.Downloader {
  let client: HuggingFace.HubClient

  init(client: HuggingFace.HubClient = .default) {
    self.client = client
  }

  func download(
    id: String,
    revision: String?,
    matching patterns: [String],
    useLatest _: Bool,
    progressHandler: @Sendable @escaping (Progress) -> Void
  ) async throws -> URL {
    guard let repository = HuggingFace.Repo.ID(rawValue: id) else {
      throw ModelArtifactDownloadError.invalidRepositoryID(id)
    }
    return try await client.downloadSnapshot(
      of: repository,
      revision: revision ?? "main",
      matching: patterns,
      progressHandler: { @MainActor progress in
        progressHandler(progress)
      })
  }
}

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

extension SQLGenClient {
  public static func live(model: ModelReference) -> SQLGenClient {
    let generator = MLXSQLGenerator(
      source: .hub(repository: model.repository, revision: model.revision))
    return SQLGenClient(
      prepare: { try await generator.prepare() },
      generate: { request in try await generator.generate(request) })
  }

  /// Load from a local weights directory (used by creg-eval-cli for parity runs).
  public static func live(directory: URL) -> SQLGenClient {
    let generator = MLXSQLGenerator(source: .directory(directory))
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
    case hub(repository: String, revision: String)
    case directory(URL)
  }

  private let source: Source
  private let containerLoader = PreparationCoalescer<ModelContainer>()

  private nonisolated var modelName: String {
    switch source {
    case .hub(let repository, let revision): "\(repository)@\(revision)"
    case .directory(let url): url.lastPathComponent
    }
  }

  init(source: Source) {
    self.source = source
  }

  func prepare() async throws {
    _ = try await loadedContainer()
  }

  func generate(_ request: SQLGenerationRequest) async throws -> SQLGeneration {
    let container = try await loadedContainer()
    let schema = try Self.schemaPrompt()

    let userContent = request.repair.map {
      Self.repairPrompt(question: request.question, context: $0)
    } ?? "Question: \(request.question)"
    let systemContent = Self.systemPrompt(schema: schema)

    return try await container.perform { (context: ModelContext) in
      let chat: [Chat.Message] = [.system(systemContent), .user(userContent)]
      let input = try await context.processor.prepare(input: UserInput(chat: chat))
      let parameters = GenerateParameters(
        maxTokens: request.maxTokens,
        temperature: Float(request.temperature),
        topP: 1.0,
        topK: 0,
        seed: request.seed)
      let started = ContinuousClock.now
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
      var sql = ""
      var tokensPerSecond = 0.0
      var tokenCount: Int?
      for await generation in stream {
        switch generation {
        case .chunk(let chunk):
          sql += chunk
        case .info(let info):
          tokensPerSecond = info.tokensPerSecond
          tokenCount = info.generationTokenCount
        default:
          break
        }
      }
      let normalized = Self.stripSpecialTokens(sql)
      let finalSQL =
        request.gcd == .on
        ? normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        : Self.extractSQL(normalized)
      return SQLGeneration(
        sql: finalSQL,
        tokensPerSecond: tokensPerSecond,
        modelName: self.modelName,
        tokenCount: tokenCount,
        elapsedMicroseconds: started.duration(to: .now).microseconds
      )
    }
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
      case .hub(let repository, let revision):
        if let bundled = Bundle.main.url(
          forResource: "SQLModel", withExtension: nil)
        {
          return try await loadModelContainer(
            from: bundled,
            using: HuggingFaceTokenizerLoader())
        }
#if DEBUG
        // Debug convenience only. Release must use the verified bundle path.
        return try await loadModelContainer(
          from: HubArtifactDownloader(),
          using: HuggingFaceTokenizerLoader(),
          configuration: ModelConfiguration(
            id: repository, revision: revision))
#else
        throw CocoaError(.fileNoSuchFile)
#endif
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
