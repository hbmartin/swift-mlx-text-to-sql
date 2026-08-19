import CREGCore
import CREGData
import Foundation

extension QueryPipeline {
  public static func live(
    fm: FMClient,
    sqlGen: SQLGenClient,
    db: DatabaseClient,
    serializer: InferenceSerializer,
    configuration: Configuration,
    randomSeed: @escaping @Sendable () -> UInt64 = {
      UInt64.random(in: UInt64.min...UInt64.max)
    },
    uuid: @escaping @Sendable () -> UUID = UUID.init,
    now: @escaping @Sendable () -> Date = Date.init
  ) -> QueryPipeline {
    let heuristics = ResultHeuristics(db: db)
    let runFreeForm: @Sendable (String, [ConversationTurn]) -> AsyncStream<PipelineEvent> =
      { question, history in
        AsyncStream { continuation in
          let task = Task {
            let turnStarted = ContinuousClock.now
            let runtimeMode = await sqlGen.runtimeMode()
            var telemetry = TurnTelemetry(
              originalQuestion: question,
              runtimeMode: runtimeMode)
            telemetry.repairPolicyVersion = configuration.repairPolicyVersion
            defer { continuation.finish() }
            continuation.yield(.turnStarted(question: question))

            let fmAvailable = fm.availability() == .available
            let activeFM = fmAvailable ? fm : .fallback()

            func finish(_ outcome: TurnOutcome) {
              if case .failed(let reason) = outcome {
                telemetry.failureReason = reason
              }
              telemetry.generatedCount = telemetry.candidates.count
              telemetry.stageTimings.totalMicroseconds =
                turnStarted.duration(to: .now).microseconds
              continuation.yield(
                .turnFinished(
                  outcome: outcome, telemetry: telemetry))
            }

            func request(
              id: String,
              role: CandidateRole,
              repair: RepairContext?,
              temperature: Double
            ) -> SQLGenerationRequest {
              SQLGenerationRequest(
                candidateID: CandidateID(rawValue: id),
                role: role,
                model: configuration.model,
                question: telemetry.standaloneQuestion,
                repair: repair,
                gcd: configuration.gcd,
                temperature: temperature,
                seed: temperature == 0 ? nil : randomSeed(),
                maxTokens: configuration.maxTokens)
            }

            var failedByFingerprint: [String: CandidateID] = [:]
            var validByFingerprint: [String: CandidateTelemetry] = [:]

            func fingerprint(_ sql: String) -> String {
              PreparedFollowUpIntegrity.fingerprint(sql: sql)
            }

            func remainingTurnSeconds() -> Double {
              configuration.deadlines.wholeTurnSeconds
                - Double(turnStarted.duration(to: .now).microseconds) / 1_000_000
            }

            func generateAndExecute(
              _ request: SQLGenerationRequest,
              attempt: Int
            ) async -> CandidateTelemetry {
              var candidate = CandidateTelemetry(request: request)
              continuation.yield(.generationStarted(request: request))
              let generationStarted = ContinuousClock.now
              do {
                let remaining = remainingTurnSeconds()
                guard remaining > 0 else {
                  throw PipelineDeadlineExceeded(
                    stage: "turn", limitSeconds: remaining)
                }
                let generation = try await withPipelineDeadline(
                  seconds: min(configuration.deadlines.generationSeconds, remaining),
                  stage: "generation"
                ) {
                  try await serializer.run(operation: .sqlGeneration) {
                    try await sqlGen.generate(request)
                  }
                }
                candidate.sql = generation.sql
                candidate.tokensPerSecond = generation.tokensPerSecond
                candidate.tokenCount = generation.tokenCount
                candidate.speculation = generation.speculation
                candidate.generationMicroseconds =
                  generation.elapsedMicroseconds
                continuation.yield(
                  .generationFinished(
                    candidateID: request.candidateID,
                    generation: generation))
                let sqlFingerprint = fingerprint(generation.sql)
                candidate.sqlFingerprint = sqlFingerprint
                if let duplicateID = failedByFingerprint[sqlFingerprint] {
                  candidate.duplicateOf = duplicateID
                  candidate.duplicateSuppressed = true
                  candidate.error =
                    "duplicate SQL matched a previously failed fingerprint"
                  continuation.yield(
                    .executionFailed(
                      candidateID: request.candidateID,
                      message: candidate.error!,
                      attempt: attempt))
                  return candidate
                }
                if let reusable = validByFingerprint[sqlFingerprint] {
                  candidate.validationReport = reusable.validationReport
                  candidate.executionMicroseconds = reusable.executionMicroseconds
                  candidate.result = reusable.result
                  candidate.resultDigest = reusable.resultDigest
                  candidate.duplicateOf = reusable.id
                  candidate.duplicateSuppressed = false
                  if let result = reusable.result {
                    continuation.yield(
                      .executionFinished(
                        candidateID: request.candidateID,
                        result: result))
                  }
                  return candidate
                }

                continuation.yield(
                  .validationStarted(
                    candidateID: request.candidateID))
                let validationStarted = ContinuousClock.now
                let validation: SQLValidationReport
                do {
                  validation = try await withPipelineDeadline(
                    seconds: remainingTurnSeconds(),
                    stage: "validation"
                  ) {
                    try await db.validate(generation.sql)
                  }
                } catch {
                  if let deadline = error as? PipelineDeadlineExceeded {
                    telemetry.timeoutStage = deadline.stage
                  } else if error is CancellationError {
                    telemetry.timeoutStage = "cancelled"
                  }
                  validation = SQLValidationReport(
                    issue: SQLValidationIssue(
                      kind: .interrupted,
                      disposition: .terminal,
                      message: String(describing: error)),
                    elapsedMicroseconds:
                      validationStarted.duration(to: .now).microseconds)
                }
                candidate.validationReport = validation
                continuation.yield(
                  .validationFinished(
                    candidateID: request.candidateID,
                    report: validation))
                telemetry.stageTimings.validationMicroseconds =
                  (telemetry.stageTimings.validationMicroseconds ?? 0)
                  + validation.elapsedMicroseconds
                if let issue = validation.issue {
                  candidate.error = issue.message
                  if issue.disposition == .repairable {
                    failedByFingerprint[sqlFingerprint] =
                      failedByFingerprint[sqlFingerprint] ?? request.candidateID
                  }
                  continuation.yield(
                    .executionFailed(
                      candidateID: request.candidateID,
                      message: issue.message,
                      attempt: attempt))
                  return candidate
                }

                continuation.yield(
                  .executionStarted(
                    candidateID: request.candidateID,
                    sql: generation.sql))
                let executionStarted = ContinuousClock.now
                do {
                  let result = try await withPipelineDeadline(
                    seconds: remainingTurnSeconds(),
                    stage: "execution"
                  ) {
                    try await db.execute(generation.sql)
                  }
                  candidate.executionMicroseconds =
                    result.elapsedMicroseconds
                  candidate.result = result
                  if !result.isTruncated {
                    candidate.resultDigest =
                      CanonicalSQLResult(result).digest
                  }
                  continuation.yield(
                    .executionFinished(
                      candidateID: request.candidateID,
                      result: result))
                } catch {
                  candidate.executionMicroseconds =
                    executionStarted.duration(to: .now).microseconds
                  if let deadline = error as? PipelineDeadlineExceeded {
                    telemetry.timeoutStage = deadline.stage
                  } else if error is CancellationError {
                    telemetry.timeoutStage = "cancelled"
                  }
                  let issue =
                    error is PipelineDeadlineExceeded || error is CancellationError
                    ? SQLValidationIssue(
                      kind: .interrupted,
                      disposition: .terminal,
                      message: String(describing: error))
                    : SQLValidationIssue.classify(error)
                  candidate.validationReport = SQLValidationReport(issue: issue)
                  candidate.error = issue.message
                  if issue.disposition == .repairable {
                    failedByFingerprint[sqlFingerprint] =
                      failedByFingerprint[sqlFingerprint] ?? request.candidateID
                  }
                  continuation.yield(
                    .executionFailed(
                      candidateID: request.candidateID,
                      message: candidate.error!,
                      attempt: attempt))
                }
                if candidate.result != nil {
                  validByFingerprint[sqlFingerprint] = candidate
                }
              } catch {
                candidate.generationMicroseconds =
                  generationStarted.duration(to: .now).microseconds
                candidate.error = "generation: \(error)"
                if let deadline = error as? PipelineDeadlineExceeded {
                  telemetry.timeoutStage = deadline.stage
                }
                continuation.yield(
                  .executionFailed(
                    candidateID: request.candidateID,
                    message: candidate.error!,
                    attempt: attempt))
              }
              return candidate
            }

            func inspectGrounding(
              sql: String,
              result: QueryResult
            ) async throws -> GroundingReport {
              let started = ContinuousClock.now
              let report = try await withPipelineDeadline(
                seconds: remainingTurnSeconds(),
                stage: "grounding"
              ) {
                await heuristics.inspectDetailed(sql: sql, result: result)
              }
              let elapsed = started.duration(to: .now).microseconds
              telemetry.stageTimings.groundingMicroseconds =
                (telemetry.stageTimings.groundingMicroseconds ?? 0) + elapsed
              continuation.yield(
                .groundingFinished(
                  report: report, elapsedMicroseconds: elapsed))
              return report
            }

            // The FM stage currently awaiting a Foundation Model response.
            // A non-deadline, non-cancellation throw in the outer catch can
            // only come from one of these calls, so this is what lets the
            // catch emit `.languageServiceFailed` instead of `.unexpected`.
            var fmStage: String?

            do {
              // 1. Follow-up rewrite. First turns still emit an explicit
              // standalone-question record with a zero-duration no-op.
              let rewriteStarted = ContinuousClock.now
              let standalone: String
              if history.isEmpty {
                standalone = question
              } else {
                continuation.yield(.rewriteStarted)
                fmStage = "rewrite"
                standalone = try await withPipelineDeadline(
                  seconds: remainingTurnSeconds(),
                  stage: "rewrite"
                ) {
                  try await serializer.run(operation: .rewrite) {
                    try await activeFM.rewrite(question, history)
                  }
                }
                fmStage = nil
              }
              let rewriteElapsed =
                rewriteStarted.duration(to: .now).microseconds
              telemetry.standaloneQuestion = standalone
              telemetry.rewriteApplied = !history.isEmpty
              telemetry.rewriteUsedFM = !history.isEmpty && fmAvailable
              telemetry.stageTimings.rewriteMicroseconds = rewriteElapsed
              continuation.yield(
                .questionResolved(
                  standaloneQuestion: standalone,
                  rewriteApplied: !history.isEmpty,
                  usedFM: telemetry.rewriteUsedFM,
                  elapsedMicroseconds: rewriteElapsed))

              // 2. Ambiguity gate.
              continuation.yield(.gateStarted)
              let gateStarted = ContinuousClock.now
              let decision: GateDecision
              let gateUsedFM: Bool
              if configuration.gateSensitivity == 0 {
                decision = .proceed
                gateUsedFM = false
                telemetry.gateMode = .bypassed
              } else {
                fmStage = "gate"
                decision = try await withPipelineDeadline(
                  seconds: remainingTurnSeconds(),
                  stage: "gate"
                ) {
                  try await serializer.run(operation: .gate) {
                    try await activeFM.gate(
                      standalone, configuration.gateSensitivity)
                  }
                }
                fmStage = nil
                gateUsedFM = fmAvailable
                telemetry.gateMode = fmAvailable ? .foundationModel : .fallback
              }
              let gateElapsed =
                gateStarted.duration(to: .now).microseconds
              telemetry.gateDecision = decision
              telemetry.gateUsedFM = gateUsedFM
              telemetry.stageTimings.gateMicroseconds = gateElapsed
              continuation.yield(
                .gateFinished(
                  decision: decision,
                  usedFM: gateUsedFM,
                  elapsedMicroseconds: gateElapsed))
              if case .clarify(let clarifyingQuestion) = decision {
                finish(.needsClarification(question: clarifyingQuestion))
                return
              }

              // 3–7. Run the configured bounded candidate count when the anchor
              // is valid. Repair attempts remain a separate bound because an
              // invalid anchor provides no result to vote on.
              let initial = await generateAndExecute(
                request(
                  id: "initial",
                  role: .initial,
                  repair: nil,
                  temperature: 0),
                attempt: 0)
              telemetry.candidates.append(initial)

              if let stage = telemetry.timeoutStage {
                telemetry.terminalError =
                  initial.error ?? "turn stopped during \(stage)"
                finish(.failed(reason: .interrupted(stage: stage)))
                return
              }

              if initial.validationReport?.issue?.disposition == .terminal {
                telemetry.recoveryOutcome = .terminal
                telemetry.terminalError = initial.error
                finish(.failed(reason: .databaseUnavailable))
                return
              }

              var voteCandidates = [initial]
              let preferredCandidateIDs: [CandidateID]
              let trigger: String
              if initial.result != nil {
                telemetry.recoveryOutcome = .notNeeded
                trigger = "initial-validation"
                preferredCandidateIDs = [initial.id]
                for index in 1..<configuration.selfConsistencyN {
                  let sample = await generateAndExecute(
                    request(
                      id: "consistency-\(index)",
                      role: .consistencySample(index: index),
                      repair: nil,
                      temperature: configuration.sampleTemperature),
                    attempt: 0)
                  telemetry.candidates.append(sample)
                  voteCandidates.append(sample)
                  if let stage = telemetry.timeoutStage {
                    telemetry.terminalError =
                      sample.error ?? "turn stopped during \(stage)"
                    finish(.failed(reason: .interrupted(stage: stage)))
                    return
                  }
                  if sample.validationReport?.issue?.disposition == .terminal {
                    telemetry.recoveryOutcome = .terminal
                    telemetry.terminalError = sample.error
                    finish(.failed(reason: .databaseUnavailable))
                    return
                  }
                }
              } else {
                guard
                  let initialFailedSQL = initial.sql,
                  let initialIssue = initial.validationReport?.issue,
                  initialIssue.disposition == .repairable
                else {
                  telemetry.recoveryOutcome = .exhausted
                  finish(
                    .failed(
                      reason: initial.sql == nil
                        ? .generationFailed : .generationExhausted))
                  return
                }
                trigger = "repair"
                var failedSQL = initialFailedSQL
                var currentIssue = initialIssue
                var errorHistory = [initialIssue.message]
                var successfulRepairIDs: [CandidateID] = []

                for offset in 0..<configuration.maxRepairAttempts {
                  let attempt = offset + 1
                  let guidance = ResultHeuristics.repairGuidance(
                    issue: currentIssue,
                    sql: failedSQL,
                    failedFingerprints: failedByFingerprint.keys.sorted())
                  let temperature =
                    attempt == 1 ? 0 : configuration.repairSampleTemperature
                  let mode = attempt == 1 ? "deterministic" : "sampled"
                  continuation.yield(.repairStarted(attempt: attempt))
                  let repair = await generateAndExecute(
                    request(
                      id: "repair-\(attempt)-\(mode)",
                      role: .repair(attempt: attempt),
                      repair: RepairContext(
                        failedSQL: failedSQL,
                        errorMessage: errorHistory.joined(separator: "\n"),
                        guidance: guidance),
                      temperature: temperature),
                    attempt: attempt)
                  telemetry.candidates.append(repair)
                  telemetry.repairAttempts += 1
                  voteCandidates.append(repair)

                  if let stage = telemetry.timeoutStage {
                    telemetry.recoveryOutcome = .terminal
                    telemetry.terminalError =
                      repair.error ?? "turn stopped during \(stage)"
                    finish(.failed(reason: .interrupted(stage: stage)))
                    return
                  }
                  if repair.validationReport?.issue?.disposition == .terminal {
                    telemetry.recoveryOutcome = .terminal
                    telemetry.terminalError = repair.error
                    finish(.failed(reason: .databaseUnavailable))
                    return
                  }
                  if repair.result != nil {
                    successfulRepairIDs.append(repair.id)
                    telemetry.recoveryOutcome = .repaired
                    break
                  }

                  if let nextSQL = repair.sql {
                    failedSQL = nextSQL
                  }
                  if let nextIssue = repair.validationReport?.issue,
                    nextIssue.disposition == .repairable
                  {
                    currentIssue = nextIssue
                  }
                  if let error = repair.error {
                    errorHistory.append(error)
                  }
                }
                if successfulRepairIDs.isEmpty {
                  telemetry.recoveryOutcome = .exhausted
                  telemetry.terminalError = telemetry.candidates.last?.error
                }
                preferredCandidateIDs = successfulRepairIDs
              }

              telemetry.generatedCount = telemetry.candidates.count
              let candidateCount = voteCandidates.count
              let votingStarted = ContinuousClock.now
              telemetry.voteTrigger = trigger
              continuation.yield(
                .selfConsistencyStarted(
                  candidateCount: candidateCount,
                  trigger: trigger))
              guard
                let selection = PipelineVoteSelector.select(
                  candidates: voteCandidates,
                  preferredCandidateIDs: preferredCandidateIDs,
                  initialWasValid: initial.result != nil)
              else {
                // Exhausted repairs reach voting with only failed candidates;
                // that is still a generation failure, not a voting one.
                finish(
                  .failed(
                    reason: telemetry.recoveryOutcome == .exhausted
                      ? .generationExhausted : .noCandidateSelected))
                return
              }
              let chosenCandidate = selection.candidate
              telemetry.confidence = selection.confidence
              telemetry.selectionReason = selection.selectionReason
              telemetry.noConsensusReason = selection.noConsensusReason
              telemetry.voteOutcome = selection.outcome
              continuation.yield(
                .selfConsistencyFinished(selection.outcome))
              telemetry.stageTimings.votingMicroseconds =
                votingStarted.duration(to: .now).microseconds

              guard
                let chosenResult = chosenCandidate.result,
                let chosenSQL = chosenCandidate.sql
              else {
                finish(.failed(reason: .noCandidateSelected))
                return
              }
              let grounding = try await inspectGrounding(
                sql: chosenSQL, result: chosenResult)
              telemetry.selectedCandidateID = chosenCandidate.id
              if let selectedIndex = telemetry.candidates.firstIndex(
                where: { $0.id == chosenCandidate.id })
              {
                telemetry.candidates[selectedIndex].selected = true
              }
              telemetry.grounding = grounding

              // 8. Narration.
              continuation.yield(.narrationStarted)
              let narrationStarted = ContinuousClock.now
              let narrationResult = chosenResult
              fmStage = "narration"
              let narration = try await withPipelineDeadline(
                seconds: remainingTurnSeconds(),
                stage: "narration"
              ) {
                try await serializer.run(operation: .narration) {
                  try await activeFM.narrate(standalone, narrationResult)
                }
              }
              fmStage = nil
              let narrationElapsed =
                narrationStarted.duration(to: .now).microseconds
              telemetry.narrationUsedFM = fmAvailable
              telemetry.stageTimings.narrationMicroseconds =
                narrationElapsed
              continuation.yield(
                .narrationFinished(
                  narration: narration,
                  usedFM: fmAvailable,
                  elapsedMicroseconds: narrationElapsed))

              let notices =
                grounding.findings.first.map(\.userNotice).map { [$0] }
                ?? []
              let notice = notices.joined(separator: " ")
              finish(
                .answered(
                  result: chosenResult,
                  narration: narration,
                  sql: chosenSQL,
                  notice: notice.isEmpty ? nil : notice))
            } catch {
              telemetry.terminalError = String(describing: error)
              let reason: TurnFailureReason
              if let deadline = error as? PipelineDeadlineExceeded {
                telemetry.timeoutStage = deadline.stage
                reason = .timedOut(stage: deadline.stage)
              } else if error is CancellationError {
                telemetry.timeoutStage = "cancelled"
                reason = .cancelled
              } else if let fmStage {
                reason = .languageServiceFailed(stage: fmStage)
              } else {
                reason = .unexpected
              }
              finish(.failed(reason: reason))
            }
          }
          continuation.onTermination = { _ in task.cancel() }
        }
      }

    return QueryPipeline(
      prepareMode: { mode in
        try await serializer.run(operation: .modelPreparation) {
          try await sqlGen.prepare(mode)
        }
      },
      runtimeMode: { await sqlGen.runtimeMode() },
      run: runFreeForm,
      runStarter: { starter in
        deterministicStarterStream(
          starter: starter,
          fm: fm,
          db: db,
          serializer: serializer,
          heuristics: heuristics,
          configuration: configuration,
          runtimeMode: { await sqlGen.runtimeMode() })
      },
      prepareFollowUps: { context in
        preparedFollowUpStream(
          context: context,
          fm: fm,
          sqlGen: sqlGen,
          db: db,
          serializer: serializer,
          heuristics: heuristics,
          configuration: configuration,
          randomSeed: randomSeed,
          uuid: uuid,
          now: now)
      },
      // Prepared execution is history-independent; its retained history
      // argument is intentionally ignored.
      runPrepared: { prepared, _ in
        preparedAnswerStream(
          prepared: prepared,
          fm: fm,
          db: db,
          serializer: serializer,
          heuristics: heuristics,
          configuration: configuration,
          runtimeMode: { await sqlGen.runtimeMode() },
          fallback: runFreeForm)
      })
  }
}
