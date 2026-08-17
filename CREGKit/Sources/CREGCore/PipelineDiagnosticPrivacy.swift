import Foundation

public enum PipelineDiagnosticPrivacy {
  public static func redact(
    _ diagnostic: String,
    question: String,
    history: [ConversationTurn],
    telemetry: TurnTelemetry
  ) -> String {
    redact(
      diagnostic,
      conversationContent: [question, telemetry.originalQuestion, telemetry.standaloneQuestion]
        + history.flatMap { [$0.question, $0.answerSummary] })
  }

  public static func redact(
    _ diagnostic: String,
    conversationContent: [String]
  ) -> String {
    var value = diagnostic
    let conversationContent = Set(conversationContent)
      .filter { !$0.isEmpty }
      .sorted { $0.count > $1.count }
    for content in conversationContent {
      if value.trimmingCharacters(in: .whitespacesAndNewlines) == content {
        value = "<redacted conversation content>"
      } else if content.count >= 8 {
        value = value.replacingOccurrences(
          of: content,
          with: "<redacted conversation content>")
      } else {
        value = redactShortLabelledContent(content, in: value)
      }
    }
    return value
  }

  private static func redactShortLabelledContent(
    _ content: String,
    in value: String
  ) -> String {
    let escaped = NSRegularExpression.escapedPattern(for: content)
    let pattern =
      #"(?i)\b(question|prompt|input|content)\s*[:=]\s*"# + escaped
      + #"(?=$|[\s,;])"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      return value
    }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return expression.stringByReplacingMatches(
      in: value,
      range: range,
      withTemplate: "$1=<redacted conversation content>")
  }
}
