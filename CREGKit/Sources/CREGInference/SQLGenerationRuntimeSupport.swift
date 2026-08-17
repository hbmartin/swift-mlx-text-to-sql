import Foundation
import MLX
import MLXLMCommon

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

final class MLXGenerationDiagnosticState: @unchecked Sendable {
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
final class MLXPromptPrefixCache: @unchecked Sendable {
  let tokens: [Int]
  let suffixTokens: [Int]?
  let cache: [KVCache]

  init(tokens: [Int], suffixTokens: [Int]?, cache: [KVCache]) {
    self.tokens = tokens
    self.suffixTokens = suffixTokens
    self.cache = cache
  }
}

struct SQLDraftCorpusResource: Decodable {
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
final class SQLQuestionOutputVocabulary: @unchecked Sendable {
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
