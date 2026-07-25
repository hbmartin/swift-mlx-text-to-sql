import CREGEngine
import Foundation

/// The consumer-facing distillation of a turn's telemetry: one plain-English
/// line about agreement, verification caveats, and latency, shown under an
/// answer without developer mode. SQL never appears here (PRD §11).
///
/// The engine's `AnswerConfidence` verdict stays authoritative: when a turn
/// is `.unconfirmed` (or its vote reached no consensus), ChatView's orange
/// unconfirmed banner carries the warning and this summary stays absent so
/// the answer is not double-flagged.
public struct ConfidenceSummary: Equatable, Sendable {
  public enum Tone: Equatable, Sendable {
    case agreement
    case caution
    case neutral
  }

  public var symbolName: String
  public var label: String
  public var tone: Tone

  public init?(telemetry: TurnTelemetry?) {
    guard let telemetry else { return nil }
    guard telemetry.confidence != .unconfirmed else { return nil }

    var tone: Tone
    let symbolName: String
    var label: String
    switch telemetry.voteOutcome {
    case .consensus(_, let agreement, let candidateCount):
      tone = .agreement
      symbolName = "checkmark.seal"
      label = "\(agreement) of \(candidateCount) readings agree"
    case .noConsensus, .anchorFailed:
      // The unconfirmed banner owns this state even when the stored
      // confidence field predates schema v2.
      return nil
    case nil:
      tone = .neutral
      symbolName = "checkmark"
      label = "Answered"
    }

    if telemetry.grounding?.degradations.isEmpty == false {
      tone = .caution
      label += " · value check incomplete"
    }
    if let latency = Self.latencyText(
      microseconds: telemetry.stageTimings.totalMicroseconds)
    {
      label += " · \(latency)"
    }

    self.symbolName = symbolName
    self.label = label
    self.tone = tone
  }

  /// Sub-second turns read in milliseconds, longer ones in tenths of a
  /// second. Zero means the timing was never recorded and is omitted.
  static func latencyText(microseconds: Int64) -> String? {
    guard microseconds > 0 else { return nil }
    if microseconds < 1_000_000 {
      return "\(max(1, microseconds / 1_000))ms"
    }
    return String(format: "%.1fs", Double(microseconds) / 1_000_000)
  }
}
