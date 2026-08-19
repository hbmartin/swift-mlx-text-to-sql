import Foundation

/// Why a turn produced no answer (CONTEXT.md "Turn Failure").
///
/// Emitted as typed data at each pipeline site — never as a display string —
/// per the `PipelineEvent` convention; `CREGFeatures` maps every case to
/// user-facing copy. Exactly one reason accompanies every failed turn, in the
/// outcome and in `TurnTelemetry.failureReason`.
public enum TurnFailureReason: Sendable, Equatable, Codable {
  /// A pipeline deadline expired; `stage` is the deadline's stage label.
  case timedOut(stage: String)
  /// The turn's task was cancelled. Distinct from a timeout so copy never
  /// blames a cancellation on slowness.
  case cancelled
  /// SQL validation reported a terminal disposition — the portfolio database
  /// cannot be used safely.
  case databaseUnavailable
  /// The SQL model produced no query at all.
  case generationFailed
  /// The model produced SQL but no candidate survived: nothing repairable,
  /// or every repair attempt failed.
  case generationExhausted
  /// Candidates existed but voting selected none, or the winner carried no
  /// result.
  case noCandidateSelected
  /// An Apple Foundation Model step (rewrite, gate, or narration) threw.
  case languageServiceFailed(stage: String)
  /// A reviewed Starter Query failed validation or execution.
  case starterQueryUnavailable
  /// The pipeline itself never became available (model manifest or
  /// configuration failure).
  case pipelineUnavailable
  case unexpected

  /// Timeout and cancellation share one telemetry field (`timeoutStage`);
  /// the `"cancelled"` sentinel distinguishes them at the emitting site.
  public static func interrupted(stage: String) -> TurnFailureReason {
    stage == "cancelled" ? .cancelled : .timedOut(stage: stage)
  }

  /// Stable diagnostics label; never shown to the user.
  public var label: String {
    switch self {
    case .timedOut(let stage): return "timed_out(\(stage))"
    case .cancelled: return "cancelled"
    case .databaseUnavailable: return "database_unavailable"
    case .generationFailed: return "generation_failed"
    case .generationExhausted: return "generation_exhausted"
    case .noCandidateSelected: return "no_candidate_selected"
    case .languageServiceFailed(let stage):
      return "language_service_failed(\(stage))"
    case .starterQueryUnavailable: return "starter_query_unavailable"
    case .pipelineUnavailable: return "pipeline_unavailable"
    case .unexpected: return "unexpected"
    }
  }

  /// Recovery Suggestions run only where the model failed on plausibly
  /// answerable input. Timeouts and cancellations get the retry affordance
  /// instead; database/pipeline-terminal states cannot pre-execute anything;
  /// a failed Starter Query must not circularly suggest starter queries.
  public var isEligibleForRecoverySuggestions: Bool {
    switch self {
    case .generationFailed, .generationExhausted, .noCandidateSelected:
      return true
    case .timedOut, .cancelled, .databaseUnavailable, .languageServiceFailed,
      .starterQueryUnavailable, .pipelineUnavailable, .unexpected:
      return false
    }
  }

  /// Test oracle only. Telemetry under-determines the reason: the vote sites
  /// set no fields locally, `.exhausted` also occurs on turns that went on to
  /// answer, and the FM stage is not recorded — so production reasons are
  /// emitted at each site and this reconstruction is advisory
  /// (`languageServiceFailed` is never derivable here).
  public static func derive(from telemetry: TurnTelemetry) -> TurnFailureReason {
    if let stage = telemetry.timeoutStage {
      return interrupted(stage: stage)
    }
    let lastFailure =
      telemetry.candidates.last(where: {
        $0.error != nil && $0.duplicateSuppressed != true
      })
      ?? telemetry.candidates.last(where: { $0.error != nil })
    if lastFailure?.validationReport?.issue?.disposition == .terminal {
      return telemetry.queryOrigin == .starter
        ? .starterQueryUnavailable : .databaseUnavailable
    }
    if let lastFailure, lastFailure.sql == nil { return .generationFailed }
    if telemetry.recoveryOutcome == .exhausted { return .generationExhausted }
    if lastFailure != nil { return .noCandidateSelected }
    return .unexpected
  }
}

/// The enumerated bucket of a Scope Verdict (CONTEXT.md "Scope Verdict"):
/// whether the portfolio covers a Standalone Question's subject. Produced only
/// by an FM that has seen the schema — never inferred from SQL errors
/// (ADR 0010).
public enum ScopeVerdict: String, Sendable, Equatable, Codable, CaseIterable {
  case outsideRealEstate = "outside_real_estate"
  case inDomainButNotTracked = "in_domain_but_not_tracked"
  case needsDataNotInSnapshot = "needs_data_not_in_snapshot"
  case likelyAnswerableModelFailed = "likely_answerable_model_failed"
}

/// One Scope Verdict as attached to a Turn Failure. The verdict annotates a
/// typed reason; it is never a reason itself.
public struct ScopeVerdictRecord: Sendable, Equatable, Codable {
  public var verdict: ScopeVerdict
  /// FM-supplied noun phrase naming what the portfolio lacks. Rendered ONLY
  /// for `inDomainButNotTracked`, and only after the deterministic
  /// schema-coverage guard passes (ADR 0010).
  public var missingSubject: String?

  public init(verdict: ScopeVerdict, missingSubject: String? = nil) {
    self.verdict = verdict
    self.missingSubject = missingSubject
  }
}

extension TurnTelemetry {
  /// The diagnostics whitelist for `timeoutStage` values, shared by every
  /// formatter so the starter stages never collapse to "unknown".
  public static func normalizedTimeoutStage(_ stage: String?) -> String {
    guard let stage else { return "none" }
    switch stage {
    case "turn", "generation", "validation", "execution", "grounding",
      "rewrite", "gate", "narration", "cancelled",
      "starter-validation", "starter-execution", "starter-grounding",
      "starter-narration":
      return stage
    default:
      return "unknown"
    }
  }
}
