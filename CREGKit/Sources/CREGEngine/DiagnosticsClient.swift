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
    case pipeline
    case database
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
    recordEvent(event)
  }

  public static let noop = DiagnosticsClient { _ in }

  public static let live = DiagnosticsClient { event in
    let subsystem = Bundle.main.bundleIdentifier ?? "dev.haroldmartin.CREG"
    let logger = Logger(subsystem: subsystem, category: event.category.rawValue)
    let context = event.context
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: " ")
    let details = event.details.map(DiagnosticPrivacy.redact) ?? ""

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
    var value = details
    value = replacing(
      #"(?i)\b(SELECT|WITH|INSERT|UPDATE|DELETE|CREATE|DROP|ALTER|PRAGMA)\b[\s\S]*"#,
      in: value,
      with: "<redacted SQL>")
    value = replacing(
      #"file://\S+|/(?:[^\s/:]+/)+[^\s:]+"#,
      in: value,
      with: "<redacted path>")
    value = replacing(
      #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}\b"#,
      in: value,
      with: "<redacted identifier>")
    return value
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
