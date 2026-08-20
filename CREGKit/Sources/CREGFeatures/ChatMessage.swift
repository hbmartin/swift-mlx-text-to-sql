import AutoTableCharts
import CREGEngine
import Foundation

public struct ResultPresentationPreference: Equatable, Hashable, Sendable, Codable {
  public enum Mode: String, Equatable, Hashable, Sendable, Codable {
    case chart
    case table
  }

  public var mode: Mode
  public var specificationID: AutoChartRecommendationID?

  public init(mode: Mode, specificationID: AutoChartRecommendationID? = nil) {
    self.mode = mode
    self.specificationID = specificationID
  }
}

/// One message cell in the chat transcript.
public struct ChatMessage: Identifiable, Equatable, Sendable, Codable {
  public enum Role: String, Equatable, Sendable, Codable {
    case user
    case assistant
  }

  public enum Body: Equatable, Sendable, Codable {
    case text(String)
    /// A prepared result is visible while grounding and narration continue.
    /// The persisted message is updated in place to `.answer` at completion.
    case preparedAnswer(PreparedFollowUp)
    case answer(result: QueryResult, narration: String, sql: String, notice: String?)
    case clarification(String)
    /// Legacy stringly failure kept decodable for persisted history; new
    /// failures are always `.failedTurn`.
    case failure(String)
    /// A Turn Failure: exactly one typed reason, plus the Scope Verdict once
    /// the post-render diagnosis lands (updated in place, like
    /// `.preparedAnswer` → `.answer`).
    case failedTurn(reason: TurnFailureReason, scopeVerdict: ScopeVerdictRecord?)
  }

  public var id: UUID
  public var role: Role
  public var body: Body {
    didSet { resultFingerprint = Self.fingerprint(for: body) }
  }
  /// Stable result identity computed once when message content is created or
  /// decoded, rather than repeatedly during SwiftUI view construction.
  public private(set) var resultFingerprint: String?
  /// Plain-English thinking-trace lines (never SQL) shown in the disclosure.
  public var traceSteps: [String]
  public var createdAt: Date
  public var devInfo: TurnTelemetry?
  /// Per-result display choice. Nil is the backward-compatible automatic
  /// default: chart when a safe recommendation exists, otherwise table.
  public var resultPresentation: ResultPresentationPreference?

  public init(
    id: UUID, role: Role, body: Body, traceSteps: [String] = [],
    createdAt: Date, devInfo: TurnTelemetry? = nil,
    resultPresentation: ResultPresentationPreference? = nil
  ) {
    self.id = id
    self.role = role
    self.body = body
    self.resultFingerprint = Self.fingerprint(for: body)
    self.traceSteps = traceSteps
    self.createdAt = createdAt
    self.devInfo = devInfo
    self.resultPresentation = resultPresentation
  }

  enum CodingKeys: String, CodingKey {
    case id, role, body, resultFingerprint, traceSteps, createdAt, devInfo,
      resultPresentation
  }

  /// SQLite patches this field without decoding the full payload. Derive the
  /// path from the durable Codable key so schema changes update both together.
  static let persistedResultPresentationJSONPath =
    "$.\(CodingKeys.resultPresentation.stringValue)"

  /// Old histories stored a mutable six-field developer summary under
  /// `devInfo`. If that legacy shape cannot decode as TurnTelemetry, the
  /// message still loads and retains all user-visible content.
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    role = try values.decode(Role.self, forKey: .role)
    body = try values.decode(Body.self, forKey: .body)
    resultFingerprint =
      (try? values.decodeIfPresent(String.self, forKey: .resultFingerprint))
      ?? Self.fingerprint(for: body)
    traceSteps =
      try values.decodeIfPresent([String].self, forKey: .traceSteps) ?? []
    createdAt = try values.decode(Date.self, forKey: .createdAt)
    devInfo = try? values.decodeIfPresent(
      TurnTelemetry.self, forKey: .devInfo)
    resultPresentation = try? values.decodeIfPresent(
      ResultPresentationPreference.self, forKey: .resultPresentation)
  }

  private static func fingerprint(for body: Body) -> String? {
    switch body {
    case .preparedAnswer(let prepared):
      prepared.provenance.resultFingerprint
    case .answer(let result, _, _, _):
      PreparedFollowUpIntegrity.fingerprint(result: result)
    case .text, .clarification, .failure, .failedTurn:
      nil
    }
  }
}

extension ChatMessage {
  public var finalizedInterruptedPreparedAnswer: ChatMessage? {
    guard case .preparedAnswer(let prepared) = body else { return nil }
    var message = self
    message.body = .answer(
      result: prepared.result,
      narration: PreparedAnswerFallback.narration(for: prepared.result),
      sql: prepared.sql,
      notice: nil)
    message.devInfo = prepared.preparationTelemetry
    return message
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
    case .generationStarted(let request):
      switch request.role {
      case .starter:
        "Running the reviewed starter query"
      case .followUpPreflight:
        "Using the prepared follow-up lookup"
      case .initial:
        "Generating the initial lookup"
      case .repair(let attempt):
        "Correcting attempt \(attempt)"
      case .deterministicAnchor:
        "Generating the deterministic cross-check"
      case .consistencySample(let index):
        "Generating cross-check \(index) of 2"
      }
    case .generationFinished: nil
    case .validationStarted: "Validating the generated lookup"
    case .validationFinished: nil
    case .executionStarted: "Running the numbers"
    case .executionFinished(_, let result):
      "Looking through the results (\(result.rowCount) row\(result.rowCount == 1 ? "" : "s"))"
    case .preparedResultReady(let prepared, _):
      "Showing the prepared result (\(prepared.result.rowCount) row\(prepared.result.rowCount == 1 ? "" : "s"))"
    case .executionFailed: "Fixing a hiccup and retrying"
    case .repairStarted: nil
    case .groundingFinished: "Double-checking the result"
    case .selfConsistencyStarted: "Reading the question a few ways to be sure"
    case .selfConsistencyFinished(.consensus(_, let agreement, let candidateCount)):
      "\(agreement) of \(candidateCount) readings agreed"
    case .selfConsistencyFinished(.noConsensus(_, _, .some(.insufficientNonEmptyEvidence))):
      "There was not enough matching non-empty evidence"
    case .selfConsistencyFinished(.noConsensus):
      "The valid readings returned conflicting results"
    case .selfConsistencyFinished(.anchorFailed):
      "The deterministic cross-check could not run"
    case .narrationStarted: "Summarizing what I found"
    case .narrationFinished: nil
    case .turnFinished: nil
    case .scopeDiagnosisFinished: nil
    }
  }
}
