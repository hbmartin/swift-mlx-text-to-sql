import CREGCore
import CREGData
import Foundation

private enum PreparedCandidateOutcome {
  case prepared(PreparedFollowUp)
  case rejected(FollowUpPreparationRejection, telemetry: TurnTelemetry)
}

func preparedFollowUpStream(
  context: FollowUpSuggestionContext,
  fm: FMClient,
  sqlGen: SQLGenClient,
  db: DatabaseClient,
  serializer: InferenceSerializer,
  heuristics: ResultHeuristics,
  configuration: QueryPipeline.Configuration,
  randomSeed: @escaping @Sendable () -> UInt64,
  uuid: @escaping @Sendable () -> UUID,
  now: @escaping @Sendable () -> Date
) -> AsyncStream<FollowUpPreparationEvent> {
  AsyncStream { continuation in
    let task = Task {
      defer {
        continuation.yield(.finished)
        continuation.finish()
      }
      guard fm.availability() == .available else {
        continuation.yield(.started(candidateCount: 0))
        return
      }

      @Sendable func prepareStarterFallback() async {
        let starters = recoveryStarterQueries(excluding: [
          context.question, context.standaloneQuestion,
        ])
        continuation.yield(.started(candidateCount: starters.count))
        for (offset, starter) in starters.enumerated() {
          guard !Task.isCancelled else { return }
          let rank = offset + 1
          let outcome = await prepareStarterRecoveryCandidate(
            starter: starter,
            rank: rank,
            context: context,
            db: db,
            heuristics: heuristics,
            configuration: configuration,
            runtimeMode: { await sqlGen.runtimeMode() },
            uuid: uuid,
            now: now)
          guard !Task.isCancelled else { return }
          switch outcome {
          case .prepared(let prepared):
            continuation.yield(.prepared(prepared))
          case .rejected(let reason, let telemetry):
            continuation.yield(
              .rejected(
                rank: rank,
                reason: reason,
                telemetry: FollowUpRejectionTelemetry(telemetry)))
          }
        }
      }

      // An out-of-domain question seeds nothing useful: skip FM generation
      // and offer reviewed Starter Queries as "here's what CREG can answer".
      if case .turnFailure(_, let scopeVerdict) = context.seed,
        scopeVerdict?.verdict == .outsideRealEstate
      {
        await prepareStarterFallback()
        return
      }

      let schema: String
      do {
        schema = try sqlGen.schemaPrompt()
      } catch {
        continuation.yield(
          .proposalFailed(reason: .schemaLoadingFailed))
        if context.isRecoverySeed { await prepareStarterFallback() }
        return
      }
      guard !schema.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        continuation.yield(
          .proposalFailed(reason: .schemaLoadingFailed))
        if context.isRecoverySeed { await prepareStarterFallback() }
        return
      }
      let proposed: [String]
      do {
        proposed = try await withFollowUpDeadline(
          seconds: configuration.deadlines.generationSeconds,
          stage: "follow-up-suggestion"
        ) {
          try await serializer.run(operation: .followUpSuggestion) {
            try await fm.suggestFollowUps(context, schema)
          }
        }
      } catch is CancellationError {
        guard !Task.isCancelled else { return }
        continuation.yield(
          .proposalFailed(reason: .generationFailed))
        if context.isRecoverySeed { await prepareStarterFallback() }
        return
      } catch is FollowUpDeadlineExceeded {
        // A timed-out FM call may continue to own the FIFO serializer until it
        // observes cancellation. Retrying here would either overlap inference
        // or spend the retry deadline waiting behind the first call.
        continuation.yield(
          .proposalFailed(reason: .generationTimedOut))
        if context.isRecoverySeed { await prepareStarterFallback() }
        return
      } catch {
        continuation.yield(
          .proposalFailed(reason: .generationFailed))
        if context.isRecoverySeed { await prepareStarterFallback() }
        return
      }

      let questions = normalizedFollowUpQuestions(
        proposed,
        excluding: [context.question, context.standaloneQuestion])
      continuation.yield(.started(candidateCount: questions.count))
      for (offset, question) in questions.enumerated() {
        guard !Task.isCancelled else { return }
        let rank = offset + 1
        let outcome = await prepareFollowUpCandidate(
          question: question,
          rank: rank,
          context: context,
          sqlGen: sqlGen,
          db: db,
          serializer: serializer,
          heuristics: heuristics,
          configuration: configuration,
          randomSeed: randomSeed,
          uuid: uuid,
          now: now)
        guard !Task.isCancelled else { return }
        switch outcome {
        case .prepared(let prepared):
          continuation.yield(.prepared(prepared))
        case .rejected(let reason, let telemetry):
          continuation.yield(
            .rejected(
              rank: rank,
              reason: reason,
              telemetry: FollowUpRejectionTelemetry(telemetry)))
        }
      }
    }
    continuation.onTermination = { _ in task.cancel() }
  }
}

/// Reviewed Starter Queries offered when Recovery Suggestion generation is
/// impossible (FM proposal failed) or pointless (out-of-domain question), in
/// registry order — the starters carry no relevance metadata to rank by.
func recoveryStarterQueries(
  excluding sourceQuestions: [String]
) -> [StarterQueryID] {
  let excluded = Set(
    sourceQuestions.map(PreparedFollowUpIntegrity.questionIdentity))
  return StarterQueryID.allCases
    .filter {
      !excluded.contains(
        PreparedFollowUpIntegrity.questionIdentity($0.question))
    }
    .prefix(PreparedFollowUpBatch.maximumSuggestionCount)
    .map { $0 }
}

func normalizedFollowUpQuestions(
  _ questions: [String],
  excluding sourceQuestions: [String]
) -> [String] {
  let excluded = Set(
    sourceQuestions.map(PreparedFollowUpIntegrity.questionIdentity))
  var seen = Set<String>()
  var result: [String] = []
  for raw in questions {
    var question =
      raw
      .split(whereSeparator: \Character.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty else { continue }
    if !question.hasSuffix("?") { question.append("?") }
    guard question.count <= 180 else { continue }
    let identity = PreparedFollowUpIntegrity.questionIdentity(question)
    guard !identity.isEmpty, !excluded.contains(identity), seen.insert(identity).inserted
    else { continue }
    result.append(question)
    if result.count == PreparedFollowUpBatch.maximumSuggestionCount { break }
  }
  return result
}

private func prepareFollowUpCandidate(
  question: String,
  rank: Int,
  context: FollowUpSuggestionContext,
  sqlGen: SQLGenClient,
  db: DatabaseClient,
  serializer: InferenceSerializer,
  heuristics: ResultHeuristics,
  configuration: QueryPipeline.Configuration,
  randomSeed: @escaping @Sendable () -> UInt64,
  uuid: @escaping @Sendable () -> UUID,
  now: @escaping @Sendable () -> Date
) async -> PreparedCandidateOutcome {
  let started = ContinuousClock.now
  let runtimeMode = await sqlGen.runtimeMode()
  var telemetry = TurnTelemetry(
    originalQuestion: question,
    runtimeMode: runtimeMode)
  telemetry.queryOrigin =
    context.isRecoverySeed ? .recoverySuggestion : .preparedFollowUp
  telemetry.executionPath = .preparedFollowUp
  telemetry.standaloneQuestion = question
  telemetry.gateMode = .bypassed
  telemetry.repairPolicyVersion = configuration.repairPolicyVersion
  var failedFingerprints = Set<String>()
  var failedSQL: String?
  var currentIssue: SQLValidationIssue?

  func rejected(
    _ reason: FollowUpPreparationRejection,
    appending candidate: CandidateTelemetry? = nil
  ) -> PreparedCandidateOutcome {
    var rejectedTelemetry = telemetry
    if let candidate {
      rejectedTelemetry.candidates.append(candidate)
    }
    rejectedTelemetry.generatedCount = rejectedTelemetry.candidates.count
    rejectedTelemetry.stageTimings.totalMicroseconds =
      started.duration(to: .now).microseconds
    return .rejected(reason, telemetry: rejectedTelemetry)
  }

  for attempt in 0...configuration.maxRepairAttempts {
    guard !Task.isCancelled else { return rejected(.cancelled) }
    let candidateID = CandidateID(
      rawValue: attempt == 0
        ? "follow-up-\(rank)-initial"
        : "follow-up-\(rank)-repair-\(attempt)")
    let temperature =
      attempt <= 1 ? 0 : configuration.repairSampleTemperature
    let repair: RepairContext?
    let role: CandidateRole
    if attempt == 0 {
      repair = nil
      role = .followUpPreflight(rank: rank)
    } else if let failedSQL, let currentIssue {
      let guidance = ResultHeuristics.repairGuidance(
        issue: currentIssue,
        sql: failedSQL,
        failedFingerprints: failedFingerprints.sorted())
      repair = RepairContext(
        failedSQL: failedSQL,
        errorMessage: currentIssue.message,
        guidance: guidance)
      role = .repair(attempt: attempt)
      telemetry.repairAttempts += 1
    } else {
      break
    }
    let request = SQLGenerationRequest(
      candidateID: candidateID,
      role: role,
      model: configuration.model,
      question: question,
      repair: repair,
      gcd: configuration.gcd,
      temperature: temperature,
      seed: temperature == 0 ? nil : randomSeed(),
      maxTokens: configuration.maxTokens)
    var candidate = CandidateTelemetry(request: request)
    let generation: SQLGeneration
    do {
      generation = try await withFollowUpDeadline(
        seconds: min(
          configuration.deadlines.generationSeconds,
          remainingPreparedAnswerSeconds(
            since: started,
            limit: configuration.deadlines.wholeTurnSeconds)),
        stage: "follow-up-generation"
      ) {
        try await serializer.run(operation: .sqlGeneration) {
          try await sqlGen.generate(request)
        }
      }
    } catch is CancellationError {
      guard !Task.isCancelled else { return rejected(.cancelled) }
      candidate.error = "generation: unexpected cancellation"
      return rejected(.generationFailed, appending: candidate)
    } catch let deadline as FollowUpDeadlineExceeded {
      telemetry.timeoutStage = deadline.telemetryStage
      candidate.error = "generation deadline exceeded"
      return rejected(.generationTimedOut, appending: candidate)
    } catch {
      candidate.error = "generation: \(String(reflecting: type(of: error)))"
      return rejected(.generationFailed, appending: candidate)
    }
    candidate.sql = generation.sql
    candidate.tokensPerSecond = generation.tokensPerSecond
    candidate.tokenCount = generation.tokenCount
    candidate.speculation = generation.speculation
    candidate.generationMicroseconds = generation.elapsedMicroseconds
    let fingerprint = PreparedFollowUpIntegrity.fingerprint(sql: generation.sql)
    candidate.sqlFingerprint = fingerprint
    guard failedFingerprints.insert(fingerprint).inserted else {
      candidate.error = "duplicate SQL matched an earlier failed preflight"
      candidate.duplicateSuppressed = true
      telemetry.candidates.append(candidate)
      break
    }

    let validation: SQLValidationReport
    do {
      validation = try await withFollowUpDeadline(
        seconds: remainingPreparedAnswerSeconds(
          since: started,
          limit: configuration.deadlines.wholeTurnSeconds),
        stage: "follow-up-validation"
      ) {
        try await db.validate(generation.sql)
      }
    } catch is CancellationError {
      guard !Task.isCancelled else { return rejected(.cancelled) }
      candidate.error = "validation: unexpected cancellation"
      return rejected(.validationFailed, appending: candidate)
    } catch let deadline as FollowUpDeadlineExceeded {
      telemetry.timeoutStage = deadline.telemetryStage
      candidate.error = "validation deadline exceeded"
      return rejected(.validationTimedOut, appending: candidate)
    } catch {
      let issue = SQLValidationIssue.classify(error)
      candidate.error = issue.message
      candidate.validationReport = SQLValidationReport(issue: issue)
      return rejected(.validationFailed, appending: candidate)
    }
    candidate.validationReport = validation
    telemetry.stageTimings.validationMicroseconds =
      (telemetry.stageTimings.validationMicroseconds ?? 0)
      + validation.elapsedMicroseconds
    if let issue = validation.issue {
      candidate.error = issue.message
      telemetry.candidates.append(candidate)
      guard issue.disposition == .repairable else {
        return rejected(.validationFailed)
      }
      failedSQL = generation.sql
      currentIssue = issue
      continue
    }

    let result: QueryResult
    do {
      result = try await withFollowUpDeadline(
        seconds: remainingPreparedAnswerSeconds(
          since: started,
          limit: configuration.deadlines.wholeTurnSeconds),
        stage: "follow-up-execution"
      ) {
        try await db.execute(generation.sql)
      }
    } catch is CancellationError {
      guard !Task.isCancelled else { return rejected(.cancelled) }
      candidate.error = "execution: unexpected cancellation"
      return rejected(.executionFailed, appending: candidate)
    } catch let deadline as FollowUpDeadlineExceeded {
      telemetry.timeoutStage = deadline.telemetryStage
      candidate.error = "execution deadline exceeded"
      return rejected(.executionTimedOut, appending: candidate)
    } catch {
      let issue = SQLValidationIssue.classify(error)
      candidate.error = issue.message
      candidate.validationReport = SQLValidationReport(issue: issue)
      telemetry.candidates.append(candidate)
      guard issue.disposition == .repairable else {
        return rejected(.executionFailed)
      }
      failedSQL = generation.sql
      currentIssue = issue
      continue
    }
    candidate.executionMicroseconds = result.elapsedMicroseconds
    candidate.result = result
    if !result.isTruncated {
      candidate.resultDigest = CanonicalSQLResult(result).digest
    }

    let groundingStarted = ContinuousClock.now
    let grounding: GroundingReport
    do {
      grounding = try await withFollowUpDeadline(
        seconds: remainingPreparedAnswerSeconds(
          since: started,
          limit: configuration.deadlines.wholeTurnSeconds),
        stage: "follow-up-grounding"
      ) {
        await heuristics.inspectDetailed(
          sql: generation.sql,
          result: result)
      }
    } catch is CancellationError {
      guard !Task.isCancelled else { return rejected(.cancelled) }
      candidate.error = "grounding: unexpected cancellation"
      return rejected(.unhelpfulResult, appending: candidate)
    } catch let deadline as FollowUpDeadlineExceeded {
      telemetry.timeoutStage = deadline.telemetryStage
      candidate.error = "grounding deadline exceeded"
      return rejected(.groundingTimedOut, appending: candidate)
    } catch {
      candidate.error = "grounding: \(String(reflecting: type(of: error)))"
      return rejected(.unhelpfulResult, appending: candidate)
    }
    telemetry.stageTimings.groundingMicroseconds =
      groundingStarted.duration(to: .now).microseconds
    telemetry.grounding = grounding
    guard !grounding.isUnhelpfulPreparedFollowUp else {
      candidate.error = "preflight result was empty or not grounded"
      telemetry.candidates.append(candidate)
      return rejected(.unhelpfulResult)
    }

    candidate.selected = true
    telemetry.candidates.append(candidate)
    telemetry.generatedCount = telemetry.candidates.count
    telemetry.selectedCandidateID = candidateID
    telemetry.selectionReason = .preparedFollowUp
    telemetry.recoveryOutcome = attempt == 0 ? .notNeeded : .repaired
    telemetry.stageTimings.totalMicroseconds =
      started.duration(to: .now).microseconds
    let provenance = PreparedQueryProvenance(
      modelKey: configuration.model.key,
      modelRevision: configuration.model.revision,
      runtimeMode: runtimeMode,
      preparationPolicyVersion: context.isRecoverySeed
        ? PreparedQueryProvenance.recoverySuggestionPolicyVersion(
          repairPolicyVersion: configuration.repairPolicyVersion)
        : PreparedQueryProvenance.followUpPolicyVersion(
          repairPolicyVersion: configuration.repairPolicyVersion),
      databaseFingerprint: db.fingerprint,
      sqlFingerprint: fingerprint,
      resultFingerprint: PreparedFollowUpIntegrity.fingerprint(result: result))
    return .prepared(
      PreparedFollowUp(
        id: uuid(),
        sourceAssistantMessageID: context.sourceAssistantMessageID,
        rank: rank,
        question: question,
        sql: generation.sql,
        result: result,
        preparationTelemetry: telemetry,
        provenance: provenance,
        createdAt: now()))
  }

  return rejected(
    telemetry.candidates.last?.sql == nil
      ? .generationFailed : .validationFailed)
}

/// Prepares one reviewed Starter Query as a Recovery Suggestion: fixed SQL,
/// no generation and no repairs — validate, execute, ground, and stamp
/// provenance exactly like a generated candidate so tapping it renders
/// instantly through the same prepared path.
private func prepareStarterRecoveryCandidate(
  starter: StarterQueryID,
  rank: Int,
  context: FollowUpSuggestionContext,
  db: DatabaseClient,
  heuristics: ResultHeuristics,
  configuration: QueryPipeline.Configuration,
  runtimeMode: @escaping @Sendable () async -> ModelRuntimeMode,
  uuid: @escaping @Sendable () -> UUID,
  now: @escaping @Sendable () -> Date
) async -> PreparedCandidateOutcome {
  let started = ContinuousClock.now
  let mode = await runtimeMode()
  let question = starter.question
  let sql = starter.sql
  var telemetry = TurnTelemetry(
    originalQuestion: question,
    runtimeMode: mode)
  telemetry.queryOrigin = .recoverySuggestion
  telemetry.executionPath = .preparedFollowUp
  telemetry.standaloneQuestion = question
  telemetry.starterQueryID = starter
  telemetry.gateMode = .bypassed
  telemetry.repairPolicyVersion = configuration.repairPolicyVersion

  let candidateID = CandidateID(
    rawValue: "recovery-starter-\(rank)-\(starter.rawValue)")
  var candidate = CandidateTelemetry(
    request: SQLGenerationRequest(
      candidateID: candidateID,
      role: .starter(starter),
      model: configuration.model,
      question: question,
      gcd: .off,
      temperature: 0,
      seed: nil,
      maxTokens: configuration.maxTokens))
  candidate.sql = sql
  let fingerprint = PreparedFollowUpIntegrity.fingerprint(sql: sql)
  candidate.sqlFingerprint = fingerprint

  func rejected(
    _ reason: FollowUpPreparationRejection
  ) -> PreparedCandidateOutcome {
    var rejectedTelemetry = telemetry
    rejectedTelemetry.candidates.append(candidate)
    rejectedTelemetry.generatedCount = 0
    rejectedTelemetry.stageTimings.totalMicroseconds =
      started.duration(to: .now).microseconds
    return .rejected(reason, telemetry: rejectedTelemetry)
  }

  let validation: SQLValidationReport
  do {
    validation = try await withFollowUpDeadline(
      seconds: configuration.deadlines.wholeTurnSeconds,
      stage: "follow-up-validation"
    ) {
      try await db.validate(sql)
    }
  } catch let deadline as FollowUpDeadlineExceeded {
    telemetry.timeoutStage = deadline.telemetryStage
    candidate.error = "validation deadline exceeded"
    return rejected(.validationTimedOut)
  } catch {
    guard !Task.isCancelled else { return rejected(.cancelled) }
    candidate.error = SQLValidationIssue.classify(error).message
    return rejected(.validationFailed)
  }
  candidate.validationReport = validation
  telemetry.stageTimings.validationMicroseconds =
    validation.elapsedMicroseconds
  if let issue = validation.issue {
    candidate.error = issue.message
    return rejected(.validationFailed)
  }

  let result: QueryResult
  do {
    result = try await withFollowUpDeadline(
      seconds: remainingPreparedAnswerSeconds(
        since: started,
        limit: configuration.deadlines.wholeTurnSeconds),
      stage: "follow-up-execution"
    ) {
      try await db.execute(sql)
    }
  } catch let deadline as FollowUpDeadlineExceeded {
    telemetry.timeoutStage = deadline.telemetryStage
    candidate.error = "execution deadline exceeded"
    return rejected(.executionTimedOut)
  } catch {
    guard !Task.isCancelled else { return rejected(.cancelled) }
    candidate.error = SQLValidationIssue.classify(error).message
    return rejected(.executionFailed)
  }
  candidate.executionMicroseconds = result.elapsedMicroseconds
  candidate.result = result
  if !result.isTruncated {
    candidate.resultDigest = CanonicalSQLResult(result).digest
  }

  let grounding: GroundingReport
  do {
    grounding = try await withFollowUpDeadline(
      seconds: remainingPreparedAnswerSeconds(
        since: started,
        limit: configuration.deadlines.wholeTurnSeconds),
      stage: "follow-up-grounding"
    ) {
      await heuristics.inspectDetailed(sql: sql, result: result)
    }
  } catch let deadline as FollowUpDeadlineExceeded {
    telemetry.timeoutStage = deadline.telemetryStage
    candidate.error = "grounding deadline exceeded"
    return rejected(.groundingTimedOut)
  } catch {
    guard !Task.isCancelled else { return rejected(.cancelled) }
    candidate.error = "grounding: \(String(reflecting: type(of: error)))"
    return rejected(.unhelpfulResult)
  }
  telemetry.grounding = grounding
  guard !grounding.isUnhelpfulPreparedFollowUp else {
    candidate.error = "starter result was empty or not grounded"
    return rejected(.unhelpfulResult)
  }

  candidate.selected = true
  telemetry.candidates = [candidate]
  telemetry.generatedCount = 0
  telemetry.selectedCandidateID = candidateID
  telemetry.selectionReason = .starterQuery
  telemetry.confidence = .confirmed
  telemetry.recoveryOutcome = .notNeeded
  telemetry.stageTimings.totalMicroseconds =
    started.duration(to: .now).microseconds
  return .prepared(
    PreparedFollowUp(
      id: uuid(),
      sourceAssistantMessageID: context.sourceAssistantMessageID,
      rank: rank,
      question: question,
      sql: sql,
      result: result,
      preparationTelemetry: telemetry,
      provenance: PreparedQueryProvenance(
        modelKey: configuration.model.key,
        modelRevision: configuration.model.revision,
        runtimeMode: mode,
        preparationPolicyVersion:
          PreparedQueryProvenance.recoverySuggestionPolicyVersion(
            repairPolicyVersion: configuration.repairPolicyVersion),
        databaseFingerprint: db.fingerprint,
        sqlFingerprint: fingerprint,
        resultFingerprint: PreparedFollowUpIntegrity.fingerprint(
          result: result)),
      createdAt: now()))
}
