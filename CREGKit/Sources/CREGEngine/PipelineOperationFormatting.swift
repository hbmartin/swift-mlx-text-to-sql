import CREGCore
import CREGData
import Foundation

struct CandidateOperationState {
  var startedAt: ContinuousClock.Instant
  var stageStartedAt: ContinuousClock.Instant
  var stage: CandidateOperationStage
  var generationMicroseconds: Int64?
  var validationMicroseconds: Int64?
  var issueKind: String?
  var disposition: String?
}

enum CandidateOperationStage: String {
  case generation
  case postGeneration = "post_generation"
  case validation
  case postValidation = "post_validation"
  case execution
  case finished
}

func candidateRole(_ role: CandidateRole) -> String {
  switch role {
  case .starter(let starter):
    "starter_\(starter.rawValue)"
  case .followUpPreflight(let rank):
    "follow_up_preflight_\(rank)"
  case .initial:
    "initial"
  case .repair(let attempt):
    "repair_\(attempt)"
  case .deterministicAnchor:
    "deterministic_anchor"
  case .consistencySample(let index):
    "consistency_sample_\(index)"
  }
}

func gateDecision(_ decision: GateDecision) -> String {
  switch decision {
  case .proceed: "proceed"
  case .clarify: "clarify"
  }
}

func voteContext(_ outcome: VoteOutcome) -> [String: String] {
  switch outcome {
  case .consensus(_, let agreement, let candidateCount):
    [
      "outcome": "consensus",
      "agreement": String(agreement),
      "candidate_count": String(candidateCount),
    ]
  case .noConsensus(_, let candidateCount, let reason):
    [
      "outcome": "no_consensus",
      "candidate_count": String(candidateCount),
      "reason": reason?.rawValue ?? "unknown",
    ]
  case .anchorFailed(_, _):
    ["outcome": "anchor_failed"]
  }
}

func voteTrigger(_ trigger: String) -> String {
  switch trigger {
  case "initial-validation", "repair": trigger
  default: "unknown"
  }
}

func timeoutStage(_ stage: String?) -> String {
  TurnTelemetry.normalizedTimeoutStage(stage)
}

func turnOutcome(_ outcome: TurnOutcome) -> String {
  switch outcome {
  case .answered: "answered"
  case .needsClarification: "needs_clarification"
  case .failed: "failed"
  }
}

func candidateValidationState(
  _ candidate: CandidateTelemetry
) -> String {
  guard let report = candidate.validationReport else { return "not_started" }
  return report.isValid ? "valid" : "invalid"
}

func candidateExecutionState(
  _ candidate: CandidateTelemetry
) -> String {
  if candidate.result != nil { return "succeeded" }
  if candidate.validationReport?.isValid == true && candidate.error != nil {
    return "failed"
  }
  return "not_started"
}

func speculationAcceptancePercent(
  _ speculation: SQLSpeculationMetrics
) -> String {
  guard speculation.draftTokenCount > 0 else { return "0.0" }
  return String(
    format: "%.1f",
    100 * Double(speculation.acceptedDraftTokenCount)
      / Double(speculation.draftTokenCount))
}

/// Human-readable summary for a follow-up proposal failure.
///
/// The exhaustive switch is deliberate: a new `FollowUpProposalFailure` case
/// must state what a support-bundle reader should look at, rather than
/// inheriting a message about generation that may not have run.
func followUpProposalFailureSummary(
  _ reason: FollowUpProposalFailure
) -> String {
  switch reason {
  case .schemaLoadingFailed:
    "Follow-up proposal stopped: the schema prompt could not be loaded."
  case .generationFailed:
    "Follow-up candidate proposal generation failed."
  case .generationTimedOut:
    "Follow-up candidate proposal generation timed out."
  case .languageServiceUnavailable:
    "Follow-up proposal stopped: Apple Intelligence became unavailable before the FM call could run."
  }
}

/// Human-readable summary for a rejected follow-up candidate.
///
/// Rejection is the common outcome, so a single summary would make bundles
/// where every candidate timed out read exactly like bundles where every
/// candidate was unusable, forcing the reader to cross-reference the reason
/// in context to learn anything.
func followUpPreparationRejectionSummary(
  _ reason: FollowUpPreparationRejection
) -> String {
  switch reason {
  case .invalidQuestion:
    "Follow-up candidate rejected: the proposed question was not usable."
  case .generationFailed:
    "Follow-up candidate rejected: SQL generation failed."
  case .generationTimedOut:
    "Follow-up candidate rejected: SQL generation timed out."
  case .validationFailed:
    "Follow-up candidate rejected: the generated SQL failed validation."
  case .validationTimedOut:
    "Follow-up candidate rejected: SQL validation timed out."
  case .executionFailed:
    "Follow-up candidate rejected: the generated SQL failed to execute."
  case .executionTimedOut:
    "Follow-up candidate rejected: SQL execution timed out."
  case .unhelpfulResult:
    "Follow-up candidate rejected: the result would not help the reader."
  case .groundingTimedOut:
    "Follow-up candidate rejected: result grounding timed out."
  case .cancelled:
    "Follow-up candidate rejected: preparation was cancelled."
  }
}

func operationMilliseconds(_ microseconds: Int64) -> String {
  String(format: "%.1f", Double(microseconds) / 1_000)
}

func optionalMilliseconds(_ microseconds: Int64?) -> String {
  microseconds.map(operationMilliseconds) ?? "not_started"
}
