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
  case rewriteFinished(standaloneQuestion: String, usedFM: Bool)
  case gateStarted
  case gateFinished(GateDecision)
  case generationStarted(modelName: String)
  case generationFinished(sql: String, tokensPerSecond: Double)
  case executionStarted(sql: String)
  case executionFinished(rowCount: Int, elapsedMilliseconds: Double)
  case executionFailed(message: String, attempt: Int)
  case repairStarted(attempt: Int)
  /// A correction-layer-A finding on the executed result.
  case heuristicFlagged(HeuristicFinding)
  /// Uncertainty-gated self-consistency voting (layers C+D) kicked in.
  case selfConsistencyStarted(candidateCount: Int, trigger: String)
  case selfConsistencyFinished(chosenSQL: String, agreement: Int, candidates: [ConsistencyCandidate])
  case narrationStarted
  case narrationFinished(narration: String, usedFM: Bool)
  case turnFinished(TurnOutcome)
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
