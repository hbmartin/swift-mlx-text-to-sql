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

/// Deterministic guards on the one FM-supplied phrase a user can read.
///
/// `missingSubject` is rendered only for `inDomainButNotTracked`, and never
/// when it names something the schema does cover — otherwise the annotation
/// itself would make a false scope claim (ADR 0010).
public enum ScopeVerdictGuard {
  static let maximumSubjectLength = 40

  /// Phrases the schema covers, derived from the schema prompt's identifiers
  /// so the guard stays in sync with the schema automatically. Snake_case
  /// identifiers contribute both the space-joined phrase ("interest_rate" →
  /// "interest rate") and each component word ("vacancy" from
  /// `vacancy_loss`); a trailing "s" is trimmed for plural-insensitive
  /// comparison. Only a full-phrase match drops a subject, so a multi-word
  /// subject like "property managers" survives even though "property" is
  /// covered.
  public static func coveredPhrases(fromSchemaPrompt schema: String) -> Set<String> {
    var phrases = Set<String>()
    var identifier = ""
    func flush() {
      defer { identifier = "" }
      guard identifier.count >= 3 else { return }
      let components = identifier
        .lowercased()
        .split(separator: "_")
        .map(String.init)
      // Every contiguous sub-phrase: "has_renewal_option" also covers
      // "renewal option", so that subject can never render as missing.
      for start in components.indices {
        for end in start..<components.count {
          let phrase = components[start...end].joined(separator: " ")
          guard phrase.count >= 3 else { continue }
          phrases.insert(normalized(phrase))
        }
      }
    }
    for character in schema {
      if character.isLetter || character.isNumber || character == "_" {
        identifier.append(character)
      } else {
        flush()
      }
    }
    flush()
    return phrases
  }

  /// Returns the subject when it is safe to render; nil drops the annotation.
  public static func sanitize(
    _ subject: String?,
    coveredPhrases: Set<String>
  ) -> String? {
    guard var subject else { return nil }
    subject = subject
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
    subject.removeAll(where: { "`*_#<>[]{}|\"".contains($0) })
    subject = subject
      .split(whereSeparator: \Character.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !subject.isEmpty, subject.count <= maximumSubjectLength else {
      return nil
    }
    guard !coveredPhrases.contains(normalized(subject.lowercased())) else {
      return nil
    }
    return subject
  }

  private static func normalized(_ phrase: String) -> String {
    phrase.hasSuffix("s") ? String(phrase.dropLast()) : phrase
  }
}

/// The app-level scope diagnosis: judges one Standalone Question after its
/// Turn Failure has rendered. The live client checks FM availability, loads
/// the schema prompt, serializes the FM call, and sanitizes `missingSubject`;
/// nil means no verdict could be produced and the reason-only copy stands.
public struct ScopeDiagnosisClient: Sendable {
  public var judge:
    @Sendable (_ standaloneQuestion: String) async -> ScopeVerdictRecord?

  public init(
    judge: @escaping @Sendable (String) async -> ScopeVerdictRecord?
  ) {
    self.judge = judge
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
