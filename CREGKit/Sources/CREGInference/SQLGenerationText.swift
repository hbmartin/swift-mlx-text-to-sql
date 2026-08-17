import Foundation

extension MLXSQLGenerator {
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
