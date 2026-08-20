import Foundation

/// One structured event from the query pipeline.
///
/// This is the single event stream the PRD requires: it drives the
/// plain-English thinking trace in the UI *and* is persisted as JSONL for the
/// eval harness. Events are data, never display strings — the UI maps them to
/// user-facing language.
public enum PipelineEvent: Sendable, Equatable, Codable {
  case turnStarted(question: String)
  case rewriteStarted
  /// Emitted for every turn, including first turns where no rewrite is needed.
  case questionResolved(
    standaloneQuestion: String,
    rewriteApplied: Bool,
    usedFM: Bool,
    elapsedMicroseconds: Int64)
  case gateStarted
  case gateFinished(
    decision: GateDecision,
    usedFM: Bool,
    elapsedMicroseconds: Int64)
  case generationStarted(request: SQLGenerationRequest)
  case generationFinished(
    candidateID: CandidateID,
    generation: SQLGeneration)
  case validationStarted(candidateID: CandidateID)
  case validationFinished(
    candidateID: CandidateID,
    report: SQLValidationReport)
  case executionStarted(candidateID: CandidateID, sql: String)
  case executionFinished(candidateID: CandidateID, result: QueryResult)
  /// A cache hit has passed provenance, integrity, and SQLite validation. The
  /// result can render immediately while grounding and narration continue.
  case preparedResultReady(
    prepared: PreparedFollowUp,
    elapsedMicroseconds: Int64)
  case executionFailed(
    candidateID: CandidateID,
    message: String,
    attempt: Int)
  case repairStarted(attempt: Int)
  case groundingFinished(report: GroundingReport, elapsedMicroseconds: Int64)
  /// Uncertainty-gated self-consistency voting (layers C+D) kicked in.
  case selfConsistencyStarted(candidateCount: Int, trigger: String)
  case selfConsistencyFinished(VoteOutcome)
  case narrationStarted
  case narrationFinished(
    narration: String,
    usedFM: Bool,
    elapsedMicroseconds: Int64)
  /// The terminal telemetry snapshot is stored with the final event and chat
  /// history. Post-render enrichments are appended as their own typed events.
  case turnFinished(outcome: TurnOutcome, telemetry: TurnTelemetry)
  /// Appended after a failed turn when the lower-priority FM scope diagnosis
  /// completes. Keeping this distinct preserves the event log's append-only
  /// ordering while making the rendered verdict export-visible.
  case scopeDiagnosisFinished(
    sourceAssistantMessageID: UUID,
    verdict: ScopeVerdictRecord)
}

extension PipelineEvent {
  /// Serializes one event as a single JSONL line.
  public func jsonLine(encoder: JSONEncoder = PipelineEvent.jsonlEncoder) throws -> String {
    let data = try encoder.encode(self)
    return String(decoding: data, as: UTF8.self)
  }

  public static let jsonlEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()
}
