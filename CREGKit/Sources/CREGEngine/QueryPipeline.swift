import CryptoKit
import Foundation

/// The strictly sequential per-turn pipeline:
/// rewrite → gate → generation/repair → grounding → voting → narration.
///
/// Candidate identity is preserved from generation through execution and the
/// final immutable telemetry record. Foundation Models and MLX work continue
/// to share one ``InferenceSerializer`` so the two inference stacks never
/// overlap.
public struct QueryPipeline: Sendable {
  public struct Configuration: Sendable, Equatable {
    public var model: ModelReference
    public var gcd: GCDMode
    public var productionTemperature: Double
    public var maxTokens: Int
    public var gateSensitivity: Double
    public var maxRepairAttempts: Int
    public var selfConsistencyN: Int
    public var sampleTemperature: Double
    public var alwaysVote: Bool
    public var deadlines: PipelineDeadlines

    public init(
      model: ModelReference,
      gcd: GCDMode,
      productionTemperature: Double,
      maxTokens: Int,
      gateSensitivity: Double,
      maxRepairAttempts: Int,
      selfConsistencyN: Int,
      sampleTemperature: Double,
      alwaysVote: Bool,
      deadlines: PipelineDeadlines = PipelineDeadlines()
    ) {
      precondition((0...1).contains(productionTemperature))
      precondition((0...1).contains(sampleTemperature))
      precondition(maxTokens > 0)
      precondition(maxRepairAttempts >= 0)
      precondition(selfConsistencyN >= 1)
      self.model = model
      self.gcd = gcd
      self.productionTemperature = productionTemperature
      self.maxTokens = maxTokens
      self.gateSensitivity = gateSensitivity
      self.maxRepairAttempts = maxRepairAttempts
      self.selfConsistencyN = selfConsistencyN
      self.sampleTemperature = sampleTemperature
      self.alwaysVote = alwaysVote
      self.deadlines = deadlines
    }
  }

  public var prepare: @Sendable () async throws -> Void
  public var run:
    @Sendable (_ question: String, _ history: [ConversationTurn])
      -> AsyncStream<PipelineEvent>

  public init(
    prepare: @escaping @Sendable () async throws -> Void = {},
    run: @escaping @Sendable (String, [ConversationTurn])
      -> AsyncStream<PipelineEvent>
  ) {
    self.prepare = prepare
    self.run = run
  }
}

private struct PipelineDeadlineExceeded: Error, CustomStringConvertible, Sendable {
  var stage: String
  var description: String { "pipeline deadline exceeded during \(stage)" }
}

private func withPipelineDeadline<Value: Sendable>(
  seconds: Double,
  stage: String,
  operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
  guard seconds > 0 else { throw PipelineDeadlineExceeded(stage: stage) }
  return try await withThrowingTaskGroup(of: Value.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: .seconds(seconds))
      throw PipelineDeadlineExceeded(stage: stage)
    }
    defer { group.cancelAll() }
    guard let result = try await group.next() else {
      throw PipelineDeadlineExceeded(stage: stage)
    }
    return result
  }
}

extension QueryPipeline {
  public static func live(
    fm: FMClient,
    sqlGen: SQLGenClient,
    db: DatabaseClient,
    serializer: InferenceSerializer,
    configuration: Configuration,
    randomSeed: @escaping @Sendable () -> UInt64 = {
      UInt64.random(in: UInt64.min...UInt64.max)
    }
  ) -> QueryPipeline {
    let heuristics = ResultHeuristics(db: db)
    return QueryPipeline(
      prepare: {
        try await serializer.run { try await sqlGen.prepare() }
      },
      run: { question, history in
      AsyncStream { continuation in
        let task = Task {
          let turnStarted = ContinuousClock.now
          var telemetry = TurnTelemetry(originalQuestion: question)
          defer { continuation.finish() }
          continuation.yield(.turnStarted(question: question))

          let fmAvailable = fm.availability() == .available
          let activeFM = fmAvailable ? fm : .fallback()

          func finish(_ outcome: TurnOutcome) {
            telemetry.generatedCount = telemetry.candidates.count
            telemetry.stageTimings.totalMicroseconds =
              turnStarted.duration(to: .now).microseconds
            continuation.yield(.turnFinished(
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

          var failedFingerprints: Set<String> = []
          var validByFingerprint: [String: CandidateTelemetry] = [:]

          func fingerprint(_ sql: String) -> String {
            let normalized = sql
              .replacingOccurrences(of: "\r\n", with: "\n")
              .replacingOccurrences(of: "\r", with: "\n")
              .trimmingCharacters(in: .whitespacesAndNewlines)
            return SHA256.hash(data: Data(normalized.utf8))
              .map { String(format: "%02x", $0) }
              .joined()
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
                throw PipelineDeadlineExceeded(stage: "turn")
              }
              let generation = try await withPipelineDeadline(
                seconds: min(configuration.deadlines.generationSeconds, remaining),
                stage: "generation"
              ) {
                try await serializer.run {
                  try await sqlGen.generate(request)
                }
              }
              candidate.sql = generation.sql
              candidate.tokensPerSecond = generation.tokensPerSecond
              candidate.tokenCount = generation.tokenCount
              candidate.generationMicroseconds =
                generation.elapsedMicroseconds
              continuation.yield(.generationFinished(
                candidateID: request.candidateID,
                generation: generation))
              let sqlFingerprint = fingerprint(generation.sql)
              candidate.sqlFingerprint = sqlFingerprint
              if failedFingerprints.contains(sqlFingerprint) {
                candidate.duplicateSuppressed = true
                candidate.error =
                  "duplicate SQL matched a previously failed fingerprint"
                continuation.yield(.executionFailed(
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
                  continuation.yield(.executionFinished(
                    candidateID: request.candidateID,
                    result: result))
                }
                return candidate
              }

              continuation.yield(.validationStarted(
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
              continuation.yield(.validationFinished(
                candidateID: request.candidateID,
                report: validation))
              telemetry.stageTimings.validationMicroseconds =
                (telemetry.stageTimings.validationMicroseconds ?? 0)
                + validation.elapsedMicroseconds
              if let issue = validation.issue {
                candidate.error = issue.message
                if issue.disposition == .repairable {
                  failedFingerprints.insert(sqlFingerprint)
                }
                continuation.yield(.executionFailed(
                  candidateID: request.candidateID,
                  message: issue.message,
                  attempt: attempt))
                return candidate
              }

              continuation.yield(.executionStarted(
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
                continuation.yield(.executionFinished(
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
                  failedFingerprints.insert(sqlFingerprint)
                }
                continuation.yield(.executionFailed(
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
              continuation.yield(.executionFailed(
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
            continuation.yield(.groundingFinished(
              report: report, elapsedMicroseconds: elapsed))
            return report
          }

          do {
            // 1. Follow-up rewrite. First turns still emit an explicit
            // standalone-question record with a zero-duration no-op.
            let rewriteStarted = ContinuousClock.now
            let standalone: String
            if history.isEmpty {
              standalone = question
            } else {
              continuation.yield(.rewriteStarted)
              standalone = try await withPipelineDeadline(
                seconds: remainingTurnSeconds(),
                stage: "rewrite"
              ) {
                try await serializer.run {
                  try await activeFM.rewrite(question, history)
                }
              }
            }
            let rewriteElapsed =
              rewriteStarted.duration(to: .now).microseconds
            telemetry.standaloneQuestion = standalone
            telemetry.rewriteApplied = !history.isEmpty
            telemetry.rewriteUsedFM = !history.isEmpty && fmAvailable
            telemetry.stageTimings.rewriteMicroseconds = rewriteElapsed
            continuation.yield(.questionResolved(
              standaloneQuestion: standalone,
              rewriteApplied: !history.isEmpty,
              usedFM: telemetry.rewriteUsedFM,
              elapsedMicroseconds: rewriteElapsed))

            // 2. Ambiguity gate.
            continuation.yield(.gateStarted)
            let gateStarted = ContinuousClock.now
            let decision = try await withPipelineDeadline(
              seconds: remainingTurnSeconds(),
              stage: "gate"
            ) {
              try await serializer.run {
                try await activeFM.gate(
                  standalone, configuration.gateSensitivity)
              }
            }
            let gateElapsed =
              gateStarted.duration(to: .now).microseconds
            telemetry.gateDecision = decision
            telemetry.gateUsedFM = fmAvailable
            telemetry.stageTimings.gateMicroseconds = gateElapsed
            continuation.yield(.gateFinished(
              decision: decision,
              usedFM: fmAvailable,
              elapsedMicroseconds: gateElapsed))
            if case .clarify(let clarifyingQuestion) = decision {
              finish(.needsClarification(question: clarifyingQuestion))
              return
            }

            // 3–7. Exactly three SQL-generation calls: initial plus two
            // independent validation candidates, or initial plus two repairs.
            let initial = await generateAndExecute(
              request(
                id: "initial",
                role: .initial,
                repair: nil,
                temperature: 0),
              attempt: 0)
            telemetry.candidates.append(initial)

            if let stage = telemetry.timeoutStage {
              telemetry.terminalError = "turn stopped during \(stage)"
              finish(.failed(
                message: "That answer took too long. Please try again."))
              return
            }

            if initial.validationReport?.issue?.disposition == .terminal {
              telemetry.terminalError = initial.error
              finish(.failed(
                message: "CREG couldn’t access the portfolio database safely."))
              return
            }

            var voteCandidates = [initial]
            let preferredCandidateIDs: [CandidateID]
            let trigger: String
            if initial.result != nil {
              trigger = "initial-validation"
              preferredCandidateIDs = [initial.id]
              for index in 1...2 {
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
                  telemetry.terminalError = "turn stopped during \(stage)"
                  finish(.failed(
                    message: "That answer took too long. Please try again."))
                  return
                }
                if sample.validationReport?.issue?.disposition == .terminal {
                  telemetry.terminalError = sample.error
                  finish(.failed(
                    message: "CREG couldn’t access the portfolio database safely."))
                  return
                }
              }
            } else {
              guard
                let originalSQL = initial.sql,
                let issue = initial.validationReport?.issue,
                issue.disposition == .repairable
              else {
                finish(.failed(
                  message:
                    "I couldn't answer that one — try rephrasing the question."))
                return
              }
              trigger = "repair"
              let initialGuidance = ResultHeuristics.repairGuidance(
                issue: issue,
                sql: originalSQL,
                failedFingerprints: failedFingerprints.sorted())
              continuation.yield(.repairStarted(attempt: 1))
              let deterministic = await generateAndExecute(
                request(
                  id: "repair-deterministic",
                  role: .repair(attempt: 1),
                  repair: RepairContext(
                    failedSQL: originalSQL,
                    errorMessage: issue.message,
                    guidance: initialGuidance),
                  temperature: 0),
                attempt: 1)
              telemetry.candidates.append(deterministic)
              telemetry.repairAttempts += 1
              voteCandidates.append(deterministic)
              if let stage = telemetry.timeoutStage {
                telemetry.terminalError = "turn stopped during \(stage)"
                finish(.failed(
                  message: "That answer took too long. Please try again."))
                return
              }
              if deterministic.validationReport?.issue?.disposition == .terminal {
                telemetry.terminalError = deterministic.error
                finish(.failed(
                  message: "CREG couldn’t access the portfolio database safely."))
                return
              }

              var sampledErrors = [issue.message]
              if deterministic.result == nil, let error = deterministic.error {
                sampledErrors.append(error)
              }
              let sampledGuidance = ResultHeuristics.repairGuidance(
                issue: issue,
                sql: originalSQL,
                failedFingerprints: failedFingerprints.sorted())
              continuation.yield(.repairStarted(attempt: 2))
              let sampled = await generateAndExecute(
                request(
                  id: "repair-sampled",
                  role: .repair(attempt: 2),
                  repair: RepairContext(
                    failedSQL: originalSQL,
                    errorMessage: sampledErrors.joined(separator: "\n"),
                    guidance: sampledGuidance),
                  temperature: configuration.sampleTemperature),
                attempt: 2)
              telemetry.candidates.append(sampled)
              telemetry.repairAttempts += 1
              voteCandidates.append(sampled)
              if let stage = telemetry.timeoutStage {
                telemetry.terminalError = "turn stopped during \(stage)"
                finish(.failed(
                  message: "That answer took too long. Please try again."))
                return
              }
              if sampled.validationReport?.issue?.disposition == .terminal {
                telemetry.terminalError = sampled.error
                finish(.failed(
                  message: "CREG couldn’t access the portfolio database safely."))
                return
              }
              preferredCandidateIDs = [deterministic.id, sampled.id]
            }

            telemetry.generatedCount = telemetry.candidates.count
            precondition(telemetry.generatedCount <= 3)
            let votingStarted = ContinuousClock.now
            telemetry.voteTrigger = trigger
            continuation.yield(.selfConsistencyStarted(
              candidateCount: 3,
              trigger: trigger))
            var agreementByDigest: [String: Int] = [:]
            for candidate in voteCandidates {
              if let digest = candidate.resultDigest,
                candidate.result?.rows.isEmpty == false
              {
                agreementByDigest[digest, default: 0] += 1
              }
            }
            let majority = agreementByDigest
              .filter { $0.value >= 2 }
              .sorted {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
              }
              .first

            let chosenCandidate: CandidateTelemetry
            if let (digest, agreement) = majority,
              let winner = voteCandidates.first(where: {
                $0.resultDigest == digest && $0.result != nil
              })
            {
              chosenCandidate = winner
              telemetry.confidence = .confirmed
              telemetry.selectionReason = .majorityVote
              let outcome = VoteOutcome.consensus(
                resultDigest: digest,
                agreement: agreement,
                candidateCount: 3)
              telemetry.voteOutcome = outcome
              continuation.yield(.selfConsistencyFinished(outcome))
            } else {
              guard let preferred = preferredCandidateIDs
                .compactMap({ id in voteCandidates.first(where: { $0.id == id }) })
                .first(where: { $0.result != nil })
              else {
                finish(.failed(
                  message:
                    "I couldn't answer that one — try rephrasing the question."))
                return
              }
              chosenCandidate = preferred
              telemetry.confidence = .unconfirmed
              let nonEmptyEvidence = voteCandidates.filter {
                $0.resultDigest != nil && $0.result?.rows.isEmpty == false
              }.count
              let reason: NoConsensusReason =
                nonEmptyEvidence < 2
                ? .insufficientNonEmptyEvidence : .conflictingResults
              telemetry.noConsensusReason = reason
              telemetry.selectionReason =
                initial.result != nil
                ? .noConsensusDeterministicAnchor : .repairSuccess
              let outcome = VoteOutcome.noConsensus(
                anchorCandidateID: preferred.id,
                candidateCount: 3,
                reason: reason)
              telemetry.voteOutcome = outcome
              continuation.yield(.selfConsistencyFinished(outcome))
            }
            telemetry.stageTimings.votingMicroseconds =
              votingStarted.duration(to: .now).microseconds

            guard
              let chosenResult = chosenCandidate.result,
              let chosenSQL = chosenCandidate.sql
            else {
              finish(.failed(
                message:
                  "I couldn't answer that one — try rephrasing the question."))
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
            let narration = try await withPipelineDeadline(
              seconds: remainingTurnSeconds(),
              stage: "narration"
            ) {
              try await serializer.run {
                try await activeFM.narrate(standalone, narrationResult)
              }
            }
            let narrationElapsed =
              narrationStarted.duration(to: .now).microseconds
            telemetry.narrationUsedFM = fmAvailable
            telemetry.stageTimings.narrationMicroseconds =
              narrationElapsed
            continuation.yield(.narrationFinished(
              narration: narration,
              usedFM: fmAvailable,
              elapsedMicroseconds: narrationElapsed))

            let notices =
              grounding.findings.first.map(\.userNotice).map { [$0] }
              ?? []
            let notice = notices.joined(separator: " ")
            finish(.answered(
              result: chosenResult,
              narration: narration,
              sql: chosenSQL,
              notice: notice.isEmpty ? nil : notice))
          } catch {
            if let deadline = error as? PipelineDeadlineExceeded {
              telemetry.timeoutStage = deadline.stage
            } else if error is CancellationError {
              telemetry.timeoutStage = "cancelled"
            }
            telemetry.terminalError = String(describing: error)
            finish(.failed(
              message:
                telemetry.timeoutStage != nil
                ? "That answer took too long. Please try again."
                : "Something went wrong while answering — please try again."))
          }
        }
        continuation.onTermination = { _ in task.cancel() }
      }
      })
  }

  /// Used when the production section of the model manifest is absent or
  /// invalid. The app remains loadable but cannot silently invent a model or
  /// generation configuration.
  public static func unavailable(message: String) -> QueryPipeline {
    QueryPipeline { question, _ in
      AsyncStream { continuation in
        var telemetry = TurnTelemetry(originalQuestion: question)
        telemetry.terminalError = message
        continuation.yield(.turnStarted(question: question))
        continuation.yield(.questionResolved(
          standaloneQuestion: question,
          rewriteApplied: false,
          usedFM: false,
          elapsedMicroseconds: 0))
        continuation.yield(.turnFinished(
          outcome: .failed(message: message),
          telemetry: telemetry))
        continuation.finish()
      }
    }
  }
}
