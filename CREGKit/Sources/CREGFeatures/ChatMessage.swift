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
    case answer(result: QueryResult, narration: String, sql: String, notice: String?)
    case clarification(String)
    case failure(String)
  }

  public var id: UUID
  public var role: Role
  public var body: Body
  /// Plain-English thinking-trace lines (never SQL) shown in the disclosure.
  public var traceSteps: [String]
  public var createdAt: Date
  public var devInfo: TurnTelemetry?

  public init(
    id: UUID, role: Role, body: Body, traceSteps: [String] = [],
    createdAt: Date, devInfo: TurnTelemetry? = nil
  ) {
    self.id = id
    self.role = role
    self.body = body
    self.traceSteps = traceSteps
    self.createdAt = createdAt
    self.devInfo = devInfo
  }

  enum CodingKeys: String, CodingKey {
    case id, role, body, traceSteps, createdAt, devInfo
  }

  /// Old histories stored a mutable six-field developer summary under
  /// `devInfo`. If that legacy shape cannot decode as TurnTelemetry, the
  /// message still loads and retains all user-visible content.
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    role = try values.decode(Role.self, forKey: .role)
    body = try values.decode(Body.self, forKey: .body)
    traceSteps =
      try values.decodeIfPresent([String].self, forKey: .traceSteps) ?? []
    createdAt = try values.decode(Date.self, forKey: .createdAt)
    devInfo = try? values.decodeIfPresent(
      TurnTelemetry.self, forKey: .devInfo)
  }
}

extension PipelineEvent {
  /// The user-facing thinking-trace line for this event, if it deserves one.
  /// Plain English only — SQL never appears here (PRD §11).
  public var traceLine: String? {
    switch self {
    case .turnStarted: "Understanding your question"
    case .rewriteStarted: nil
    case .questionResolved(_, let rewriteApplied, _, _):
      rewriteApplied
        ? "Rephrasing your follow-up as a standalone question"
        : nil
    case .gateStarted: nil
    case .gateFinished(.proceed, _, _):
      "Checking the question is clear enough"
    case .gateFinished(.clarify, _, _):
      "This one needs a quick clarification"
    case .generationStarted: "Working out how to look that up"
    case .generationFinished: nil
    case .executionStarted: "Running the numbers"
    case .executionFinished(_, let result):
      "Looking through the results (\(result.rowCount) row\(result.rowCount == 1 ? "" : "s"))"
    case .executionFailed: "Fixing a hiccup and retrying"
    case .repairStarted: nil
    case .groundingFinished: "Double-checking the result"
    case .selfConsistencyStarted: "Reading the question a few ways to be sure"
    case .selfConsistencyFinished(.consensus(_, let agreement, let candidateCount)):
      "\(agreement) of \(candidateCount) readings agreed"
    case .selfConsistencyFinished(.noConsensus):
      "The readings did not reach a majority"
    case .selfConsistencyFinished(.anchorFailed):
      "The deterministic cross-check could not run"
    case .narrationStarted: "Summarizing what I found"
    case .narrationFinished: nil
    case .turnFinished: nil
    }
  }
}
