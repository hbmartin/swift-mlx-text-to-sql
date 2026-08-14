import Foundation

private struct FollowUpDeadlineExceeded: Error, Sendable {
  var stage: String

  var telemetryStage: String {
    switch stage {
    case "follow-up-generation": "generation"
    case "follow-up-validation": "validation"
    case "follow-up-execution": "execution"
    case "follow-up-grounding": "grounding"
    case "prepared-validation": "validation"
    default: stage
    }
  }
}

private final class FollowUpDeadlineRace<Value: Sendable>: @unchecked Sendable {
  private typealias Continuation = CheckedContinuation<Value, any Error>

  private let lock = NSLock()
  private var continuation: Continuation?
  private var result: Result<Value, any Error>?
  private var tasks: [Task<Void, Never>] = []

  func wait(
    seconds: Double,
    stage: String,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        install(continuation)
        let operationTask = Task {
          do {
            resolve(.success(try await operation()))
          } catch {
            resolve(.failure(error))
          }
        }
        let deadlineTask = Task {
          do {
            try await Task.sleep(for: .seconds(seconds))
            resolve(.failure(FollowUpDeadlineExceeded(stage: stage)))
          } catch is CancellationError {
            return
          } catch {
            resolve(.failure(error))
          }
        }
        install(tasks: [operationTask, deadlineTask])
      }
    } onCancel: {
      resolve(.failure(CancellationError()))
    }
  }

  private func install(_ continuation: Continuation) {
    lock.lock()
    if let result {
      lock.unlock()
      continuation.resume(with: result)
    } else {
      self.continuation = continuation
      lock.unlock()
    }
  }

  private func install(tasks: [Task<Void, Never>]) {
    lock.lock()
    if result == nil {
      self.tasks = tasks
      lock.unlock()
    } else {
      lock.unlock()
      tasks.forEach { $0.cancel() }
    }
  }

  private func resolve(_ result: Result<Value, any Error>) {
    lock.lock()
    guard self.result == nil else {
      lock.unlock()
      return
    }
    self.result = result
    let continuation = self.continuation
    self.continuation = nil
    let tasks = self.tasks
    self.tasks = []
    lock.unlock()
    tasks.forEach { $0.cancel() }
    continuation?.resume(with: result)
  }
}

private func withFollowUpDeadline<Value: Sendable>(
  seconds: Double,
  stage: String,
  operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
  guard seconds > 0 else { throw FollowUpDeadlineExceeded(stage: stage) }
  return try await FollowUpDeadlineRace<Value>().wait(
    seconds: seconds,
    stage: stage,
    operation: operation)
}

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

      let schema = (try? SQLGenClient.schemaPrompt()) ?? ""
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
        return
      } catch is FollowUpDeadlineExceeded {
        // A timed-out FM call may continue to own the FIFO serializer until it
        // observes cancellation. Retrying here would either overlap inference
        // or spend the retry deadline waiting behind the first call.
        continuation.yield(
          .proposalFailed(reason: .generationTimedOut))
        return
      } catch {
        continuation.yield(
          .proposalFailed(reason: .generationFailed))
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
  telemetry.queryOrigin = .preparedFollowUp
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
  }

  return rejected(
    telemetry.candidates.last?.sql == nil
      ? .generationFailed : .validationFailed)
}

extension FollowUpRejectionTelemetry {
  fileprivate init(_ telemetry: TurnTelemetry) {
    let lastCandidate = telemetry.candidates.last
    self.init(
      timeoutStage: telemetry.timeoutStage,
      stageTimings: telemetry.stageTimings,
      candidateCount: telemetry.candidates.count,
      failedCandidateCount: telemetry.candidates.filter { $0.error != nil }.count,
      repairAttempts: telemetry.repairAttempts,
      lastCandidateRole: lastCandidate?.role,
      lastCandidateGeneratedSQL: lastCandidate?.sql != nil,
      lastCandidateProducedResult: lastCandidate?.result != nil,
      lastCandidateErrorPresent: lastCandidate?.error != nil,
      lastIssueKind: lastCandidate?.validationReport?.issue?.kind,
      lastIssueDisposition:
        lastCandidate?.validationReport?.issue?.disposition)
  }
}

extension GroundingReport {
  fileprivate var isUnhelpfulPreparedFollowUp: Bool {
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
  fallback:
    @escaping @Sendable (String, [ConversationTurn])
    -> AsyncStream<PipelineEvent>
) -> AsyncStream<PipelineEvent> {
  AsyncStream { continuation in
    let task = Task {
      let started = ContinuousClock.now
      let mode = await runtimeMode()
      func runFreeFormFallback(
        reason: PreparedCacheMissReason,
        timeoutStage: String? = nil
      ) async {
        // Prepared suggestions are generated and preflighted as standalone
        // questions. An empty history prevents the free-form pipeline from
        // spending another FM call rewriting the chip label.
        for await event in fallback(prepared.question, []) {
          if case .turnFinished(let outcome, var telemetry) = event {
            telemetry.preparedFollowUpID = prepared.id
            telemetry.sourceAnswerMessageID = prepared.sourceAssistantMessageID
            telemetry.preparedCacheHit = false
            telemetry.preparedCacheMissReason = reason
            if telemetry.timeoutStage == nil {
              telemetry.timeoutStage = timeoutStage
            }
            continuation.yield(
              .turnFinished(outcome: outcome, telemetry: telemetry))
          } else {
            continuation.yield(event)
          }
        }
        continuation.finish()
      }
      let cacheMissReason: PreparedCacheMissReason?
      if prepared.provenance.schemaVersion
        != PreparedQueryProvenance.currentSchemaVersion
      {
        cacheMissReason = .schemaVersion
      } else if prepared.provenance.modelKey != configuration.model.key {
        cacheMissReason = .modelKey
      } else if prepared.provenance.modelRevision != configuration.model.revision {
        cacheMissReason = .modelRevision
      } else if prepared.provenance.runtimeMode != mode {
        cacheMissReason = .runtimeMode
      } else if prepared.provenance.preparationPolicyVersion
        != "prepared-follow-up-v1|\(configuration.repairPolicyVersion)"
      {
        cacheMissReason = .preparationPolicyVersion
      } else if prepared.provenance.databaseFingerprint != db.fingerprint {
        cacheMissReason = .databaseFingerprint
      } else if prepared.provenance.sqlFingerprint
        != PreparedFollowUpIntegrity.fingerprint(sql: prepared.sql)
      {
        cacheMissReason = .sqlFingerprint
      } else if prepared.provenance.resultFingerprint
        != PreparedFollowUpIntegrity.fingerprint(result: prepared.result)
      {
        cacheMissReason = .resultFingerprint
      } else {
        cacheMissReason = nil
      }
      if let cacheMissReason {
        await runFreeFormFallback(reason: cacheMissReason)
        return
      }

      let validation: SQLValidationReport
      do {
        validation = try await withFollowUpDeadline(
          seconds: remainingPreparedAnswerSeconds(
            since: started,
            limit: configuration.deadlines.wholeTurnSeconds),
          stage: "prepared-validation"
        ) {
          try await db.validate(prepared.sql)
        }
      } catch is CancellationError {
        guard Task.isCancelled else {
          await runFreeFormFallback(reason: .validationFailed)
          return
        }
        continuation.finish()
        return
      } catch let deadline as FollowUpDeadlineExceeded {
        await runFreeFormFallback(
          reason: .validationTimedOut,
          timeoutStage: deadline.telemetryStage)
        return
      } catch {
        await runFreeFormFallback(reason: .validationFailed)
        return
      }
      guard validation.isValid else {
        await runFreeFormFallback(reason: .validationFailed)
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
      let grounding: GroundingReport
      do {
        grounding = try await withFollowUpDeadline(
          seconds: remainingPreparedAnswerSeconds(
            since: started,
            limit: configuration.deadlines.wholeTurnSeconds),
          stage: "grounding"
        ) {
          await heuristics.inspectDetailed(
            sql: prepared.sql,
            result: prepared.result)
        }
      } catch is CancellationError {
        if Task.isCancelled {
          continuation.finish()
          return
        }
        grounding = GroundingReport()
      } catch let deadline as FollowUpDeadlineExceeded {
        telemetry.timeoutStage = deadline.telemetryStage
        grounding = GroundingReport()
      } catch {
        grounding = GroundingReport()
      }
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
      let narrationUsedFM: Bool
      do {
        let activeFM = fmAvailable ? fm : .fallback()
        narration = try await withFollowUpDeadline(
          seconds: remainingPreparedAnswerSeconds(
            since: started,
            limit: configuration.deadlines.wholeTurnSeconds),
          stage: "narration"
        ) {
          try await serializer.run(operation: .narration) {
            try await activeFM.narrate(prepared.question, prepared.result)
          }
        }
        narrationUsedFM = fmAvailable
      } catch is CancellationError {
        if Task.isCancelled {
          continuation.finish()
          return
        }
        narration = PreparedAnswerFallback.narration(for: prepared.result)
        narrationUsedFM = false
      } catch let deadline as FollowUpDeadlineExceeded {
        telemetry.timeoutStage = deadline.telemetryStage
        narration = PreparedAnswerFallback.narration(for: prepared.result)
        narrationUsedFM = false
      } catch {
        narration = PreparedAnswerFallback.narration(for: prepared.result)
        narrationUsedFM = false
      }
      let narrationElapsed = narrationStarted.duration(to: .now).microseconds
      telemetry.narrationUsedFM = narrationUsedFM
      telemetry.stageTimings.narrationMicroseconds = narrationElapsed
      telemetry.stageTimings.totalMicroseconds =
        started.duration(to: .now).microseconds
      continuation.yield(
        .narrationFinished(
          narration: narration,
          usedFM: narrationUsedFM,
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

private func remainingPreparedAnswerSeconds(
  since started: ContinuousClock.Instant,
  limit: Double
) -> Double {
  limit - Double(started.duration(to: .now).microseconds) / 1_000_000
}

public enum PreparedAnswerFallback {
  public static func narration(for result: QueryResult) -> String {
    result.rowCount == 0
      ? "I didn't find any matching rows."
      : "Here's what I found — \(result.rowCount) row\(result.rowCount == 1 ? "" : "s")\(result.isTruncated ? " (showing the first \(result.rowCount))" : "")."
  }
}
