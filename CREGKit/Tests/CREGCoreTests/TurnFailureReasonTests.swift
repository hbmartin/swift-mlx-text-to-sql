import Foundation
import Testing

@testable import CREGCore

@Suite struct TurnFailureReasonTests {
  private static func candidate(
    id: String = "initial",
    role: CandidateRole = .initial,
    sql: String? = "SELECT 1",
    error: String? = nil,
    issue: SQLValidationIssue? = nil
  ) -> CandidateTelemetry {
    var candidate = CandidateTelemetry(
      request: SQLGenerationRequest(
        candidateID: CandidateID(rawValue: id),
        role: role,
        model: ModelReference(
          key: "test", repository: "test/test",
          revision: String(repeating: "0", count: 40)),
        question: "q",
        gcd: .off,
        temperature: 0,
        seed: nil))
    candidate.sql = sql
    candidate.error = error
    if let issue {
      candidate.validationReport = SQLValidationReport(issue: issue)
    }
    return candidate
  }

  @Test func interruptedSplitsCancellationFromTimeout() {
    #expect(TurnFailureReason.interrupted(stage: "cancelled") == .cancelled)
    #expect(
      TurnFailureReason.interrupted(stage: "generation")
        == .timedOut(stage: "generation"))
  }

  // MARK: - The derive oracle

  @Test func deriveTimeoutWinsOverEveryOtherSignal() {
    var telemetry = TurnTelemetry(originalQuestion: "q")
    telemetry.timeoutStage = "execution"
    telemetry.recoveryOutcome = .exhausted
    telemetry.candidates = [
      Self.candidate(
        error: "no such column: x",
        issue: SQLValidationIssue(
          kind: .binding, disposition: .repairable, message: "no such column"))
    ]
    #expect(
      TurnFailureReason.derive(from: telemetry)
        == .timedOut(stage: "execution"))
  }

  @Test func deriveCancelledSentinel() {
    var telemetry = TurnTelemetry(originalQuestion: "q")
    telemetry.timeoutStage = "cancelled"
    #expect(TurnFailureReason.derive(from: telemetry) == .cancelled)
  }

  @Test func deriveTerminalDispositionIsDatabaseUnavailable() {
    var telemetry = TurnTelemetry(originalQuestion: "q")
    telemetry.recoveryOutcome = .terminal
    telemetry.candidates = [
      Self.candidate(
        error: "database is locked",
        issue: SQLValidationIssue(
          kind: .databaseUnavailable,
          disposition: .terminal,
          message: "database is locked"))
    ]
    #expect(TurnFailureReason.derive(from: telemetry) == .databaseUnavailable)
  }

  @Test func deriveStarterTerminalIsStarterQueryUnavailable() {
    var telemetry = TurnTelemetry(originalQuestion: "q")
    telemetry.queryOrigin = .starter
    telemetry.candidates = [
      Self.candidate(
        role: .starter(.highestVacancyV1),
        error: "database is locked",
        issue: SQLValidationIssue(
          kind: .databaseUnavailable,
          disposition: .terminal,
          message: "database is locked"))
    ]
    #expect(
      TurnFailureReason.derive(from: telemetry) == .starterQueryUnavailable)
  }

  @Test func deriveNoSQLIsGenerationFailed() {
    var telemetry = TurnTelemetry(originalQuestion: "q")
    telemetry.recoveryOutcome = .exhausted
    telemetry.candidates = [
      Self.candidate(sql: nil, error: "generation: weights missing")
    ]
    #expect(TurnFailureReason.derive(from: telemetry) == .generationFailed)
  }

  @Test func deriveExhaustedIsGenerationExhausted() {
    var telemetry = TurnTelemetry(originalQuestion: "q")
    telemetry.recoveryOutcome = .exhausted
    telemetry.candidates = [
      Self.candidate(
        error: "no such column: vacancy",
        issue: SQLValidationIssue(
          kind: .binding, disposition: .repairable, message: "no such column"))
    ]
    #expect(TurnFailureReason.derive(from: telemetry) == .generationExhausted)
  }

  @Test func deriveFailureWithoutExhaustionIsNoCandidateSelected() {
    var telemetry = TurnTelemetry(originalQuestion: "q")
    telemetry.recoveryOutcome = .notNeeded
    telemetry.candidates = [
      Self.candidate(
        error: "conflicting result",
        issue: SQLValidationIssue(
          kind: .unknown, disposition: .repairable, message: "conflict"))
    ]
    #expect(TurnFailureReason.derive(from: telemetry) == .noCandidateSelected)
  }

  @Test func deriveZeroSignalTelemetryIsUnexpected() {
    let telemetry = TurnTelemetry(originalQuestion: "q")
    #expect(TurnFailureReason.derive(from: telemetry) == .unexpected)
  }

  // MARK: - Codable

  @Test func reasonAndVerdictRoundTrip() throws {
    let reasons: [TurnFailureReason] = [
      .timedOut(stage: "generation"), .cancelled, .databaseUnavailable,
      .generationFailed, .generationExhausted, .noCandidateSelected,
      .languageServiceFailed(stage: "narration"), .starterQueryUnavailable,
      .pipelineUnavailable, .unexpected,
    ]
    for reason in reasons {
      let data = try JSONEncoder().encode(reason)
      let decoded = try JSONDecoder().decode(TurnFailureReason.self, from: data)
      #expect(decoded == reason)
    }
    let record = ScopeVerdictRecord(
      verdict: .inDomainButNotTracked, missingSubject: "property managers")
    let data = try JSONEncoder().encode(record)
    #expect(
      try JSONDecoder().decode(ScopeVerdictRecord.self, from: data) == record)
  }

  @Test func schemaV6TelemetryDecodesWithNilReason() throws {
    let v6 = Data(
      """
      {"schemaVersion": 6, "originalQuestion": "q"}
      """.utf8)
    let telemetry = try JSONDecoder().decode(TurnTelemetry.self, from: v6)
    #expect(telemetry.failureReason == nil)
    #expect(telemetry.scopeVerdict == nil)
  }

  @Test func schemaV7TelemetryRoundTripsReasonAndVerdict() throws {
    var telemetry = TurnTelemetry(originalQuestion: "q")
    telemetry.failureReason = .generationExhausted
    telemetry.scopeVerdict = ScopeVerdictRecord(
      verdict: .likelyAnswerableModelFailed)
    let data = try JSONEncoder().encode(telemetry)
    let decoded = try JSONDecoder().decode(TurnTelemetry.self, from: data)
    #expect(decoded.schemaVersion == 7)
    #expect(decoded.failureReason == .generationExhausted)
    #expect(
      decoded.scopeVerdict
        == ScopeVerdictRecord(verdict: .likelyAnswerableModelFailed))
  }

  // MARK: - Scope verdict guard (ADR 0010)

  private static let schemaSnippet = """
    loans(loan_id, interest_rate, maturity_date)
    property_financials(vacancy_loss, occupancy_rate)
    properties(property_id, name)
    """

  @Test func guardDropsSubjectsTheSchemaCovers() {
    let covered = ScopeVerdictGuard.coveredPhrases(
      fromSchemaPrompt: Self.schemaSnippet)
    // Column phrase, plural-insensitive.
    #expect(
      ScopeVerdictGuard.sanitize("interest rates", coveredPhrases: covered)
        == nil)
    // Component word of vacancy_loss — the T2-21 lesson.
    #expect(
      ScopeVerdictGuard.sanitize("vacancy", coveredPhrases: covered) == nil)
    #expect(
      ScopeVerdictGuard.sanitize("vacancies", coveredPhrases: covered) == nil)
    #expect(
      ScopeVerdictGuard.sanitize("vacancy.", coveredPhrases: covered) == nil)
    #expect(
      ScopeVerdictGuard.sanitize("vacancy_loss", coveredPhrases: covered) == nil)
    // Table name.
    #expect(
      ScopeVerdictGuard.sanitize("Properties", coveredPhrases: covered) == nil)
    // A genuinely untracked multi-word subject survives even though
    // "property" alone is covered.
    #expect(
      ScopeVerdictGuard.sanitize("property managers", coveredPhrases: covered)
        == "property managers")
    #expect(
      ScopeVerdictGuard.sanitize("PROPERTY-MANAGERS", coveredPhrases: covered)
        == "property managers")
    // Arbitrary FM paraphrases never become absolute scope claims.
    #expect(
      ScopeVerdictGuard.sanitize("loan interest rates", coveredPhrases: covered)
        == nil)
  }

  @Test func guardCapsLengthAndStripsMarkup() {
    let covered = ScopeVerdictGuard.coveredPhrases(
      fromSchemaPrompt: Self.schemaSnippet)
    #expect(
      ScopeVerdictGuard.sanitize(
        "  tenant\n`contacts`  ", coveredPhrases: covered)
        == "tenant contact details")
    #expect(
      ScopeVerdictGuard.sanitize(
        String(repeating: "x", count: 41), coveredPhrases: covered) == nil)
    #expect(ScopeVerdictGuard.sanitize(nil, coveredPhrases: covered) == nil)
    #expect(ScopeVerdictGuard.sanitize("  ", coveredPhrases: covered) == nil)
  }

  /// The dictionary's own doc comment promises the FM may answer with the
  /// reviewed phrasing itself ("fund management fees"); every display phrase
  /// must therefore round-trip through sanitize instead of silently dropping.
  @Test func guardAcceptsItsOwnReviewedDisplayPhrases() {
    let covered = ScopeVerdictGuard.coveredPhrases(
      fromSchemaPrompt: Self.schemaSnippet)
    for display in Set(ScopeVerdictGuard.reviewedMissingSubjects.values) {
      #expect(
        ScopeVerdictGuard.sanitize(display, coveredPhrases: covered) == display,
        "\(display) is reviewed copy and must survive sanitize unchanged")
    }
  }

  @Test func realSchemaPromptCoversItsOwnVocabulary() {
    let covered = ScopeVerdictGuard.coveredPhrases(fromSchemaPrompt: """
      leases(lease_id, base_rent_psf, annual_base_rent, has_renewal_option)
      property_financials(gross_potential_rent, vacancy_loss, net_operating_income, occupancy_rate)
      """)
    for subject in [
      "vacancy", "vacancies", "occupancy rate", "annual base rent",
      "renewal option",
    ] {
      #expect(
        ScopeVerdictGuard.sanitize(subject, coveredPhrases: covered) == nil,
        "\(subject) names covered data and must never render as missing")
    }
  }

  @Test func normalizedTimeoutStageKeepsStarterStages() {
    #expect(
      TurnTelemetry.normalizedTimeoutStage("starter-validation")
        == "starter-validation")
    #expect(
      TurnTelemetry.normalizedTimeoutStage("starter-narration")
        == "starter-narration")
    #expect(TurnTelemetry.normalizedTimeoutStage("cancelled") == "cancelled")
    #expect(TurnTelemetry.normalizedTimeoutStage(nil) == "none")
    #expect(TurnTelemetry.normalizedTimeoutStage("bogus") == "unknown")
  }
}
