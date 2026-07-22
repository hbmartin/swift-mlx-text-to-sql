import Foundation
import OSLog

/// A privacy-bounded diagnostic suitable for tests, telemetry classification,
/// and Apple unified logging.
public struct DiagnosticEvent: Sendable, Equatable {
  public enum Level: String, Sendable, Equatable {
    case info
    case error
  }

  public enum Category: String, Sendable, Equatable {
    case configuration
    case model
    case inference
    case pipeline
    case database
    case submission
    case history
  }

  public var level: Level
  public var category: Category
  public var code: String
  /// A stable, non-sensitive description of what failed.
  public var summary: String
  /// Underlying diagnostic details. The live client logs this as private data.
  public var details: String?
  /// A small allowlist of non-sensitive dimensions such as pipeline stage.
  public var context: [String: String]

  public init(
    level: Level,
    category: Category,
    code: String,
    summary: String,
    details: String? = nil,
    context: [String: String] = [:]
  ) {
    self.level = level
    self.category = category
    self.code = code
    self.summary = summary
    self.details = details
    self.context = context
  }
}

/// Injectable diagnostics boundary. Production uses Apple unified logging;
/// tests can record events without scraping log output.
public struct DiagnosticsClient: Sendable {
  private let recordEvent: @Sendable (DiagnosticEvent) -> Void

  public init(
    _ record: @escaping @Sendable (DiagnosticEvent) -> Void
  ) {
    self.recordEvent = record
  }

  public func record(_ event: DiagnosticEvent) {
    var event = event
    event.details = event.details.map(DiagnosticPrivacy.redact)
    event.context = event.context.mapValues(DiagnosticPrivacy.redact)
    recordEvent(event)
  }

  /// Records a payload-free operational milestone. Callers must limit context
  /// to typed dimensions (counts, booleans, enum values, and durations); user
  /// questions, SQL, rows, identifiers, and paths belong in neither field.
  public func info(
    category: DiagnosticEvent.Category,
    code: String,
    summary: String,
    context: [String: String] = [:]
  ) {
    record(DiagnosticEvent(
      level: .info,
      category: category,
      code: code,
      summary: summary,
      context: context))
  }

  public static let noop = DiagnosticsClient { _ in }

  public static let live = DiagnosticsClient { event in
    let subsystem = Bundle.main.bundleIdentifier ?? "dev.haroldmartin.CREG"
    let logger = Logger(subsystem: subsystem, category: event.category.rawValue)
    let context = event.context
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: " ")
    // `record(_:)` is the single sanitization boundary. Re-running redaction
    // here risks progressively destroying otherwise actionable diagnostics.
    let details = event.details ?? ""

    switch event.level {
    case .info:
      logger.info(
        "[\(event.code, privacy: .public)] \(event.summary, privacy: .public) \(context, privacy: .public)")
    case .error:
      logger.error(
        "[\(event.code, privacy: .public)] \(event.summary, privacy: .public) \(context, privacy: .public) details=\(details, privacy: .private)")
    }
  }
}

/// Preserves useful `DecodingError` context, including array indices and the
/// missing key, instead of collapsing it into `localizedDescription`.
public enum DiagnosticDetails {
  public static func describe(_ error: any Error) -> String {
    switch error {
    case DecodingError.keyNotFound(let key, let context):
      return "Missing key at \(path(context.codingPath + [key])): \(context.debugDescription)"
    case DecodingError.valueNotFound(let type, let context):
      return "Missing \(String(reflecting: type)) value at \(path(context.codingPath)): \(context.debugDescription)"
    case DecodingError.typeMismatch(let type, let context):
      return "Expected \(String(reflecting: type)) at \(path(context.codingPath)): \(context.debugDescription)"
    case DecodingError.dataCorrupted(let context):
      return "Invalid data at \(path(context.codingPath)): \(context.debugDescription)"
    default:
      return String(describing: error)
    }
  }

  private static func path(_ codingPath: [any CodingKey]) -> String {
    var result = ""
    for key in codingPath {
      if let index = key.intValue {
        result += "[\(index)]"
      } else {
        if !result.isEmpty { result += "." }
        result += key.stringValue
      }
    }
    return result.isEmpty ? "<root>" : result
  }
}

enum DiagnosticPrivacy {
  /// Event producers never intentionally include questions, SQL, result rows,
  /// history payloads, database paths, or conversation IDs. This final live-log
  /// filter guards against those values appearing inside an underlying error.
  static func redact(_ details: String) -> String {
    let labeledMultilineStatement =
      #"(?ix)^\s*(sql|query|statement)\s*[:=]\s*SELECT(?:\s+DISTINCT)?\s*\n[\s\S]+$"#
    if let expression = try? NSRegularExpression(pattern: labeledMultilineStatement) {
      let range = NSRange(details.startIndex..<details.endIndex, in: details)
      if expression.firstMatch(in: details, range: range) != nil {
        return expression.stringByReplacingMatches(
          in: details, range: range, withTemplate: "$1=<redacted SQL>")
      }
    }
    if isStatementShapedSQL(details) {
      return "<redacted SQL>"
    }
    var value = details
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(redactSQLLine)
      .joined(separator: "\n")
    value = replacing(
      #"(?i)file://[^\s\]\[(){}<>,;]+|(?<![A-Za-z0-9._-])/(?:[^\s/\]\[(){}<>,;:]+/)*[^\s/\]\[(){}<>,;:]+"#,
      in: value,
      with: "<redacted path>")
    value = replacing(
      #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}\b"#,
      in: value,
      with: "<redacted identifier>")
    return value
  }

  /// Redact values behind explicit SQL labels and statements that have a
  /// recognizable shape at the beginning of a line. A bare English word such
  /// as "with", "update", "create", or "select" is intentionally preserved.
  private static func redactSQLLine(_ line: Substring) -> String {
    var value = String(line)
    value = replacing(
      #"(?i)\b(sql|query|statement)\s*[:=]\s*.+$"#,
      in: value,
      with: "$1=<redacted SQL>")

    return isStatementShapedSQL(value) ? "<redacted SQL>" : value
  }

  private static func isStatementShapedSQL(_ value: String) -> Bool {
    let statementShape =
      #"(?ix)^\s*(?:SELECT\s+(?:DISTINCT\s+)?(?:\*|[-+]?\d|NULL\b|TRUE\b|FALSE\b|'|\"|`|\[|\?|[:@$][\w]+|CASE\s+WHEN\b|EXISTS\s*\(|\(\s*(?:SELECT|WITH)\b|(?:[-+~]|NOT\b)\s*(?:[\w\"`\[\].]+|\(|\?|[:@$][\w]+)|[\w]+\s*\(|[\w\"`\[\].]+\s*(?:,|\bAS\b|\bFROM\b|\bWHERE\b|\bGROUP\b|\bORDER\b|\bLIMIT\b|\bUNION\b|$))|WITH\s+(?:RECURSIVE\s+)?[\w\"`\[]+\s+AS\s*\(|INSERT\s+INTO\s+|UPDATE\s+[\w\"`\[]+\s+SET\s+|DELETE\s+FROM\s+|CREATE\s+(?:TABLE|INDEX|VIEW|TRIGGER)\s+|DROP\s+(?:TABLE|INDEX|VIEW|TRIGGER)\s+|ALTER\s+TABLE\s+|PRAGMA\s+[\w.]+)"#
    guard let expression = try? NSRegularExpression(pattern: statementShape) else {
      return false
    }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return expression.firstMatch(in: value, range: range) != nil
  }

  private static func replacing(
    _ pattern: String,
    in value: String,
    with replacement: String
  ) -> String {
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      return value
    }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return expression.stringByReplacingMatches(
      in: value, range: range, withTemplate: replacement)
  }
}
