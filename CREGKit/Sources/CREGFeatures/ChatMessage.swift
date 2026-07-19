import CREGEngine
import Foundation

/// One message cell in the chat transcript.
public struct ChatMessage: Identifiable, Equatable, Sendable, Codable {
  public enum Role: String, Equatable, Sendable, Codable {
    case user
    case assistant
  }

  public enum Body: Equatable, Sendable, Codable {
    case text(String)
    case answer(result: QueryResult, narration: String, sql: String)
    case clarification(String)
    case failure(String)
  }

  public var id: UUID
  public var role: Role
  public var body: Body
  /// Plain-English thinking-trace lines (never SQL) shown in the disclosure.
  public var traceSteps: [String]
  public var createdAt: Date

  public init(id: UUID, role: Role, body: Body, traceSteps: [String] = [], createdAt: Date) {
    self.id = id
    self.role = role
    self.body = body
    self.traceSteps = traceSteps
    self.createdAt = createdAt
  }
}

extension PipelineEvent {
  /// The user-facing thinking-trace line for this event, if it deserves one.
  /// Plain English only — SQL never appears here (PRD §11).
  public var traceLine: String? {
    switch self {
    case .turnStarted: "Understanding your question"
    case .rewriteStarted: nil
    case .rewriteFinished: "Rephrasing your follow-up as a standalone question"
    case .gateStarted: nil
    case .gateFinished(.proceed): "Checking the question is clear enough"
    case .gateFinished(.clarify): "This one needs a quick clarification"
    case .generationStarted: "Working out how to look that up"
    case .generationFinished: nil
    case .executionStarted: "Running the numbers"
    case .executionFinished(let rowCount, _): "Looking through the results (\(rowCount) row\(rowCount == 1 ? "" : "s"))"
    case .executionFailed: "Fixing a hiccup and retrying"
    case .repairStarted: nil
    case .narrationStarted: "Summarizing what I found"
    case .narrationFinished: nil
    case .turnFinished: nil
    }
  }
}
