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
  public var generate:
    @Sendable (SQLGenerationRequest) async throws -> SQLGeneration

  public init(
    generate: @escaping @Sendable (SQLGenerationRequest) async throws
      -> SQLGeneration
  ) {
    self.generate = generate
  }
}

extension SQLGenClient {
  public static func live(model: ModelReference) -> SQLGenClient {
    let generator = MLXSQLGenerator(
      source: .hub(repository: model.repository, revision: model.revision))
    return SQLGenClient { request in
      try await generator.generate(request)
    }
  }

  /// Load from a local weights directory (used by creg-eval-cli for parity runs).
  public static func live(directory: URL) -> SQLGenClient {
    let generator = MLXSQLGenerator(source: .directory(directory))
    return SQLGenClient { request in
      try await generator.generate(request)
    }
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
}

/// Keeps the MLX model resident between turns (PRD §7.1) and runs
/// grammar-constrained decoding via MLXStructured (XGrammar).
actor MLXSQLGenerator {
  enum Source {
    case hub(repository: String, revision: String)
    case directory(URL)
  }

  private let source: Source
  private var container: ModelContainer?

  private nonisolated var modelName: String {
    switch source {
    case .hub(let repository, let revision): "\(repository)@\(revision)"
    case .directory(let url): url.lastPathComponent
    }
  }

  init(source: Source) {
    self.source = source
  }

  func generate(_ request: SQLGenerationRequest) async throws -> SQLGeneration {
    let container = try await loadedContainer()
    let schema = try Self.schemaPrompt()

    let repairSuffix = request.repair.map { repair in
      """
      \n\nYour previous attempt failed. Fix it.
      Previous SQL: \(repair.failedSQL)
      SQLite error: \(repair.errorMessage)
      """
    }
    let userContent = "Question: \(request.question)" + (repairSuffix ?? "")
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
    [
      "You translate questions about a commercial real estate portfolio into a single SQLite SELECT statement. Only SELECT is possible. Use only these tables and columns:",
      "",
      schema,
      "",
      "Rules:",
      "- Vacancy means 1 - occupancy_rate from each property's latest monthly property_financials row, never derived from leases.",
      "- \"Current value\" of a property is properties.current_market_value; the valuations table is appraisal history only.",
      "- Dates are ISO text (YYYY-MM-DD); today is 2026-07-01.",
      "- Rates are 0-1 fractions.",
      "Output only the SQL statement.",
    ].joined(separator: "\n")
  }

  private func loadedContainer() async throws -> ModelContainer {
    if let container { return container }
    MLX.Memory.cacheLimit = 20 * 1024 * 1024
    let container: ModelContainer
    switch source {
    case .directory(let url):
      container = try await loadModelContainer(
        from: url,
        using: HuggingFaceTokenizerLoader())
    case .hub(let repository, let revision):
      if let bundled = Bundle.main.url(forResource: "SQLModel", withExtension: nil) {
        container = try await loadModelContainer(
          from: bundled,
          using: HuggingFaceTokenizerLoader())
      } else {
        // Walking-skeleton convenience: resolve from the Hugging Face cache or
        // download on first run. The shipping build bundles the model instead.
        container = try await loadModelContainer(
          from: HubArtifactDownloader(),
          using: HuggingFaceTokenizerLoader(),
          configuration: ModelConfiguration(id: repository, revision: revision))
      }
    }
    self.container = container
    return container
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

  /// Cuts at the first semicolon outside a single-quoted SQL string, so a
  /// literal like 'A; B' cannot truncate an otherwise correct statement.
  /// Mirrors the Python evaluator byte-for-byte.
  static func truncateAtStatementEnd(_ sql: String) -> String {
    var insideString = false
    for index in sql.indices {
      let character = sql[index]
      if character == "'" {
        insideString.toggle()
      } else if character == ";", !insideString {
        return String(sql[..<index])
      }
    }
    return sql
  }
}
