import Foundation

private struct FollowUpDeadlineExceeded: Error, Sendable {}

private func withFollowUpDeadline<Value: Sendable>(
  seconds: Double,
  operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
  guard seconds > 0 else { throw FollowUpDeadlineExceeded() }
  return try await withThrowingTaskGroup(of: Value.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: .seconds(seconds))
      throw FollowUpDeadlineExceeded()
    }
    defer { group.cancelAll() }
    guard let value = try await group.next() else {
      throw FollowUpDeadlineExceeded()
    }
    return value
  }
}

private enum PreparedCandidateOutcome {
  case prepared(PreparedFollowUp)
  case rejected(FollowUpPreparationRejection)
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

      let schema = (try? SQLGenClient.schemaPrompt()) ?? ""
      let proposed: [String]
      do {
        proposed = try await serializer.run(operation: .followUpSuggestion) {
          try await fm.suggestFollowUps(context, schema)
        }
      } catch {
        continuation.yield(.started(candidateCount: 0))
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
        case .rejected(let reason):
          continuation.yield(.rejected(rank: rank, reason: reason))
        }
      }
    }
    continuation.onTermination = { _ in task.cancel() }
  }
}

func normalizedFollowUpQuestions(
  _ questions: [String],
  excluding sourceQuestions: [String]
) -> [String] {
  let excluded = Set(sourceQuestions.map(normalizedQuestionIdentity))
  var seen = Set<String>()
  var result: [String] = []
  for raw in questions {
    var question = raw
      .split(whereSeparator: \Character.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty, question.count <= 180 else { continue }
    if !question.hasSuffix("?") { question.append("?") }
    let identity = normalizedQuestionIdentity(question)
    guard !identity.isEmpty, !excluded.contains(identity), seen.insert(identity).inserted
    else { continue }
    result.append(question)
    if result.count == 3 { break }
  }
  return result
}

private func normalizedQuestionIdentity(_ question: String) -> String {
  question
    .lowercased()
    .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
    .split(whereSeparator: \Character.isWhitespace)
    .joined(separator: " ")
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
  telemetry.queryOrigin = .preparedFollowUp
  telemetry.executionPath = .preparedFollowUp
  telemetry.standaloneQuestion = question
  telemetry.gateMode = .bypassed
  telemetry.repairPolicyVersion = configuration.repairPolicyVersion
  var failedFingerprints = Set<String>()
  var failedSQL: String?
  var currentIssue: SQLValidationIssue?

  for attempt in 0...configuration.maxRepairAttempts {
    guard !Task.isCancelled else { return .rejected(.cancelled) }
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
    let elapsedSeconds =
      Double(started.duration(to: .now).microseconds) / 1_000_000
    let remaining = configuration.deadlines.wholeTurnSeconds - elapsedSeconds

    do {
      let generation = try await withFollowUpDeadline(
        seconds: min(configuration.deadlines.generationSeconds, remaining)
      ) {
        try await serializer.run(operation: .sqlGeneration) {
          try await sqlGen.generate(request)
        }
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

      let validation = try await db.validate(generation.sql)
      candidate.validationReport = validation
      telemetry.stageTimings.validationMicroseconds =
        (telemetry.stageTimings.validationMicroseconds ?? 0)
        + validation.elapsedMicroseconds
      if let issue = validation.issue {
        candidate.error = issue.message
        telemetry.candidates.append(candidate)
        guard issue.disposition == .repairable else {
          telemetry.stageTimings.totalMicroseconds =
            started.duration(to: .now).microseconds
          return .rejected(.validationFailed)
        }
        failedSQL = generation.sql
        currentIssue = issue
        continue
      }

      do {
        let result = try await db.execute(generation.sql)
        candidate.executionMicroseconds = result.elapsedMicroseconds
        candidate.result = result
        if !result.isTruncated {
          candidate.resultDigest = CanonicalSQLResult(result).digest
        }
        let groundingStarted = ContinuousClock.now
        let grounding = await heuristics.inspectDetailed(
          sql: generation.sql,
          result: result)
        telemetry.stageTimings.groundingMicroseconds =
          groundingStarted.duration(to: .now).microseconds
        telemetry.grounding = grounding
        guard !grounding.isUnhelpfulPreparedFollowUp else {
          candidate.error = "preflight result was empty or not grounded"
          telemetry.candidates.append(candidate)
          telemetry.stageTimings.totalMicroseconds =
            started.duration(to: .now).microseconds
          return .rejected(.unhelpfulResult)
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
          preparationPolicyVersion:
            "prepared-follow-up-v1|\(configuration.repairPolicyVersion)",
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
      } catch {
        let issue = SQLValidationIssue.classify(error)
        candidate.error = issue.message
        candidate.validationReport = SQLValidationReport(issue: issue)
        telemetry.candidates.append(candidate)
        guard issue.disposition == .repairable else {
          telemetry.stageTimings.totalMicroseconds =
            started.duration(to: .now).microseconds
          return .rejected(.executionFailed)
        }
        failedSQL = generation.sql
        currentIssue = issue
      }
    } catch is CancellationError {
      return .rejected(.cancelled)
    } catch {
      candidate.error = "generation: \(String(reflecting: type(of: error)))"
      telemetry.candidates.append(candidate)
      telemetry.stageTimings.totalMicroseconds =
        started.duration(to: .now).microseconds
      return .rejected(.generationFailed)
    }
  }

  telemetry.generatedCount = telemetry.candidates.count
  telemetry.stageTimings.totalMicroseconds =
    started.duration(to: .now).microseconds
  return .rejected(
    telemetry.candidates.last?.sql == nil
      ? .generationFailed : .validationFailed)
}

private extension GroundingReport {
  var isUnhelpfulPreparedFollowUp: Bool {
    findings.contains { finding in
      switch finding {
      case .emptyResult, .nullScalar, .literalNotFound:
        true
      }
    }
  }
}

func preparedAnswerStream(
  prepared: PreparedFollowUp,
  history: [ConversationTurn],
  fm: FMClient,
  db: DatabaseClient,
  serializer: InferenceSerializer,
  heuristics: ResultHeuristics,
  configuration: QueryPipeline.Configuration,
  runtimeMode: @escaping @Sendable () async -> ModelRuntimeMode,
  fallback: @escaping @Sendable (String, [ConversationTurn])
    -> AsyncStream<PipelineEvent>
) -> AsyncStream<PipelineEvent> {
  AsyncStream { continuation in
    let task = Task {
      let started = ContinuousClock.now
      let mode = await runtimeMode()
      func runFreeFormFallback() async {
        for await event in fallback(prepared.question, history) {
          if case .turnFinished(let outcome, var telemetry) = event {
            telemetry.preparedFollowUpID = prepared.id
            telemetry.sourceAnswerMessageID = prepared.sourceAssistantMessageID
            telemetry.preparedCacheHit = false
            continuation.yield(
              .turnFinished(outcome: outcome, telemetry: telemetry))
          } else {
            continuation.yield(event)
          }
        }
        continuation.finish()
      }
      guard prepared.provenance.schemaVersion
        == PreparedQueryProvenance.currentSchemaVersion,
        prepared.provenance.modelKey == configuration.model.key,
        prepared.provenance.modelRevision == configuration.model.revision,
        prepared.provenance.runtimeMode == mode,
        prepared.provenance.preparationPolicyVersion
          == "prepared-follow-up-v1|\(configuration.repairPolicyVersion)",
        prepared.provenance.databaseFingerprint == db.fingerprint,
        prepared.provenance.sqlFingerprint
          == PreparedFollowUpIntegrity.fingerprint(sql: prepared.sql),
        prepared.provenance.resultFingerprint
          == PreparedFollowUpIntegrity.fingerprint(result: prepared.result)
      else {
        await runFreeFormFallback()
        return
      }

      let validation: SQLValidationReport
      do {
        validation = try await db.validate(prepared.sql)
      } catch {
        await runFreeFormFallback()
        return
      }
      guard validation.isValid else {
        await runFreeFormFallback()
        return
      }

      var telemetry = TurnTelemetry(
        originalQuestion: prepared.question,
        runtimeMode: mode)
      telemetry.standaloneQuestion = prepared.question
      telemetry.queryOrigin = .preparedFollowUp
      telemetry.executionPath = .preparedFollowUp
      telemetry.preparedFollowUpID = prepared.id
      telemetry.sourceAnswerMessageID = prepared.sourceAssistantMessageID
      telemetry.preparedCacheHit = true
      telemetry.gateDecision = .proceed
      telemetry.gateMode = .bypassed
      telemetry.repairPolicyVersion = configuration.repairPolicyVersion
      telemetry.selectionReason = .preparedFollowUp
      telemetry.recoveryOutcome = .notNeeded
      telemetry.generatedCount = 0
      telemetry.stageTimings.validationMicroseconds =
        validation.elapsedMicroseconds

      let candidateID = CandidateID(
        rawValue: "prepared-\(prepared.id.uuidString.lowercased())")
      var candidate = CandidateTelemetry(
        request: SQLGenerationRequest(
          candidateID: candidateID,
          role: .followUpPreflight(rank: prepared.rank),
          model: configuration.model,
          question: prepared.question,
          gcd: configuration.gcd,
          temperature: 0,
          seed: nil,
          maxTokens: configuration.maxTokens))
      candidate.sql = prepared.sql
      candidate.sqlFingerprint = prepared.provenance.sqlFingerprint
      candidate.validationReport = validation
      candidate.result = prepared.result
      if !prepared.result.isTruncated {
        candidate.resultDigest = CanonicalSQLResult(prepared.result).digest
      }
      candidate.selected = true
      telemetry.candidates = [candidate]
      telemetry.selectedCandidateID = candidateID

      continuation.yield(.turnStarted(question: prepared.question))
      continuation.yield(
        .questionResolved(
          standaloneQuestion: prepared.question,
          rewriteApplied: false,
          usedFM: false,
          elapsedMicroseconds: 0))
      continuation.yield(.validationStarted(candidateID: candidateID))
      continuation.yield(
        .validationFinished(candidateID: candidateID, report: validation))
      continuation.yield(
        .preparedResultReady(
          prepared: prepared,
          elapsedMicroseconds: started.duration(to: .now).microseconds))

      let groundingStarted = ContinuousClock.now
      let grounding = await heuristics.inspectDetailed(
        sql: prepared.sql,
        result: prepared.result)
      let groundingElapsed = groundingStarted.duration(to: .now).microseconds
      telemetry.grounding = grounding
      telemetry.stageTimings.groundingMicroseconds = groundingElapsed
      continuation.yield(
        .groundingFinished(
          report: grounding,
          elapsedMicroseconds: groundingElapsed))

      continuation.yield(.narrationStarted)
      let narrationStarted = ContinuousClock.now
      let fmAvailable = fm.availability() == .available
      let narration: String
      do {
        let activeFM = fmAvailable ? fm : .fallback()
        narration = try await serializer.run(operation: .narration) {
          try await activeFM.narrate(prepared.question, prepared.result)
        }
      } catch is CancellationError {
        continuation.finish()
        return
      } catch {
        narration = (try? await FMClient.fallback().narrate(
          prepared.question, prepared.result))
          ?? PreparedAnswerFallback.narration(for: prepared.result)
      }
      let narrationElapsed = narrationStarted.duration(to: .now).microseconds
      telemetry.narrationUsedFM = fmAvailable
      telemetry.stageTimings.narrationMicroseconds = narrationElapsed
      telemetry.stageTimings.totalMicroseconds =
        started.duration(to: .now).microseconds
      continuation.yield(
        .narrationFinished(
          narration: narration,
          usedFM: fmAvailable,
          elapsedMicroseconds: narrationElapsed))
      let notice = grounding.findings.first?.userNotice
      continuation.yield(
        .turnFinished(
          outcome: .answered(
            result: prepared.result,
            narration: narration,
            sql: prepared.sql,
            notice: notice),
          telemetry: telemetry))
      continuation.finish()
    }
    continuation.onTermination = { _ in task.cancel() }
  }
}

public enum PreparedAnswerFallback {
  public static func narration(for result: QueryResult) -> String {
    result.rowCount == 0
      ? "I didn't find any matching rows."
      : "Here's what I found — \(result.rowCount) row\(result.rowCount == 1 ? "" : "s")\(result.isTruncated ? " (showing the first \(result.rowCount))" : "")."
  }
}
