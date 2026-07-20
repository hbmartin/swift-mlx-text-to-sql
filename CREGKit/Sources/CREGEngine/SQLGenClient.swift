import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXStructured
import Tokenizers

private enum SQLGenerationRuntimeError: LocalizedError {
  case tokenLimitExceeded

  var errorDescription: String? {
    switch self {
    case .tokenLimitExceeded:
      "SQL generation reached its token limit before completing a statement."
    }
  }
}

/// The bundled SQL specialist: grammar-constrained SQL generation on MLX.
public struct SQLGenClient: Sendable {
  /// `temperature` 0 = greedy (default path); >0 for self-consistency samples.
  public var generate: @Sendable (_ standaloneQuestion: String, _ repair: RepairContext?, _ temperature: Double) async throws -> SQLGeneration

  public init(generate: @escaping @Sendable (String, RepairContext?, Double) async throws -> SQLGeneration) {
    self.generate = generate
  }
}

extension SQLGenClient {
  /// Default model for the walking skeleton; the eval harness re-decides (plan decision 10).
  public static let defaultModelID = "mlx-community/Qwen2.5-Coder-3B-Instruct-4bit"

  public static func live(modelID: String = defaultModelID) -> SQLGenClient {
    let generator = MLXSQLGenerator(source: .hub(modelID))
    return SQLGenClient { question, repair, temperature in
      try await generator.generate(question: question, repair: repair, temperature: temperature)
    }
  }

  /// Load from a local weights directory (used by creg-eval-cli for parity runs).
  public static func live(directory: URL) -> SQLGenClient {
    let generator = MLXSQLGenerator(source: .directory(directory))
    return SQLGenClient { question, repair, temperature in
      try await generator.generate(question: question, repair: repair, temperature: temperature)
    }
  }
}

/// Keeps the MLX model resident between turns (PRD §7.1) and runs
/// grammar-constrained decoding via MLXStructured (XGrammar).
actor MLXSQLGenerator {
  private static let maxGenerationTokens = 512
  private static let repetitionPenalty: Float = 1.1
  private static let repetitionContextSize = 64

  enum Source {
    case hub(String)
    case directory(URL)
  }

  private let source: Source
  private var container: ModelContainer?
  private var resolvedModelName: String?

  private var modelName: String {
    if let resolvedModelName { return resolvedModelName }
    switch source {
    case .hub(let id): return id
    case .directory(let url): return url.lastPathComponent
    }
  }

  init(source: Source) {
    self.source = source
  }

  func generate(question: String, repair: RepairContext?, temperature: Double) async throws -> SQLGeneration {
    let container = try await loadedContainer()
    let modelName = self.modelName
    let grammar = try Self.grammarEBNF()
    let schema = try Self.schemaPrompt()
    let asOfDate = try Self.asOfDate()

    let repairSuffix = repair.map { repair in
      """
      \n\nYour previous attempt failed. Fix it.
      Previous SQL: \(repair.failedSQL)
      SQLite error: \(repair.errorMessage)
      """
    }
    let userContent = "Question: \(question)" + (repairSuffix ?? "")
    let systemContent = """
      You translate questions about a commercial real estate portfolio into a single \
      SQLite SELECT statement. Only SELECT is possible. Use only these tables and columns:

      \(schema)

      Rules:
      - Vacancy means 1 - occupancy_rate from each property's latest monthly \
        property_financials row, never derived from leases.
      - "Current value" of a property is properties.current_market_value; the \
        valuations table is appraisal history only.
      - Dates are ISO text (YYYY-MM-DD); today is \(asOfDate).
      - Rates are 0-1 fractions.
      Output only the SQL statement.
      """

    return try await container.perform { (context: ModelContext) in
      let chat: [Chat.Message] = [.system(systemContent), .user(userContent)]
      let input = try await context.processor.prepare(input: UserInput(chat: chat))
      let parameters = GenerateParameters(
        maxTokens: Self.maxGenerationTokens,
        temperature: Float(temperature),
        repetitionPenalty: Self.repetitionPenalty,
        repetitionContextSize: Self.repetitionContextSize
      )
      let stream = try await MLXStructured.generate(
        input: input,
        parameters: parameters,
        context: context,
        ebnf: grammar
      )
      var sql = ""
      var tokensPerSecond = 0.0
      for await generation in stream {
        switch generation {
        case .chunk(let chunk):
          sql += chunk
        case .info(let info):
          tokensPerSecond = info.tokensPerSecond
          switch info.stopReason {
          case .stop:
            break
          case .length:
            throw SQLGenerationRuntimeError.tokenLimitExceeded
          case .cancelled:
            throw CancellationError()
          }
        default:
          break
        }
      }
      return SQLGeneration(
        sql: sql.trimmingCharacters(in: .whitespacesAndNewlines),
        tokensPerSecond: tokensPerSecond,
        modelName: modelName
      )
    }
  }

  private func loadedContainer() async throws -> ModelContainer {
    if let container { return container }
    MLX.Memory.cacheLimit = 20 * 1024 * 1024
    let container: ModelContainer
    switch source {
    case .directory(let url):
      container = try await loadModelContainer(from: url, using: #huggingFaceTokenizerLoader())
      resolvedModelName = url.lastPathComponent
    case .hub(let modelID):
      if let bundled = Bundle.main.url(forResource: "SQLModel", withExtension: nil) {
        container = try await loadModelContainer(
          from: bundled, using: #huggingFaceTokenizerLoader())
        resolvedModelName = bundled.lastPathComponent
      } else {
        // Walking-skeleton convenience: resolve from the Hugging Face cache or
        // download on first run. The shipping build bundles the model instead.
        container = try await #huggingFaceLoadModelContainer(
          configuration: ModelConfiguration(id: modelID))
        resolvedModelName = modelID
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
  }

  static func asOfDate() throws -> String {
    guard let url = Bundle.module.url(forResource: "as_of_date", withExtension: "txt") else {
      throw CocoaError(.fileNoSuchFile)
    }
    return try String(contentsOf: url, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
