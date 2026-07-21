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

    public init(
      model: ModelReference,
      gcd: GCDMode,
      productionTemperature: Double,
      maxTokens: Int,
      gateSensitivity: Double,
      maxRepairAttempts: Int,
      selfConsistencyN: Int,
      sampleTemperature: Double,
      alwaysVote: Bool
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
    }
  }

  public var run:
    @Sendable (_ question: String, _ history: [ConversationTurn])
      -> AsyncStream<PipelineEvent>

  public init(
    run: @escaping @Sendable (String, [ConversationTurn])
      -> AsyncStream<PipelineEvent>
  ) {
    self.run = run
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
    return QueryPipeline { question, history in
      AsyncStream { continuation in
        let task = Task {
          let turnStarted = ContinuousClock.now
          var telemetry = TurnTelemetry(originalQuestion: question)
          defer { continuation.finish() }
          continuation.yield(.turnStarted(question: question))

          let fmAvailable = fm.availability() == .available
          let activeFM = fmAvailable ? fm : .fallback()

          func finish(_ outcome: TurnOutcome) {
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

          func generateAndExecute(
            _ request: SQLGenerationRequest,
            attempt: Int
          ) async -> CandidateTelemetry {
            var candidate = CandidateTelemetry(request: request)
            continuation.yield(.generationStarted(request: request))
            let generationStarted = ContinuousClock.now
            do {
              let generation = try await serializer.run {
                try await sqlGen.generate(request)
              }
              candidate.sql = generation.sql
              candidate.tokensPerSecond = generation.tokensPerSecond
              candidate.tokenCount = generation.tokenCount
              candidate.generationMicroseconds =
                generation.elapsedMicroseconds
              continuation.yield(.generationFinished(
                candidateID: request.candidateID,
                generation: generation))
              continuation.yield(.executionStarted(
                candidateID: request.candidateID,
                sql: generation.sql))
              let executionStarted = ContinuousClock.now
              do {
                let result = try await db.execute(generation.sql)
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
                candidate.error = String(describing: error)
                continuation.yield(.executionFailed(
                  candidateID: request.candidateID,
                  message: candidate.error!,
                  attempt: attempt))
              }
            } catch {
              candidate.generationMicroseconds =
                generationStarted.duration(to: .now).microseconds
              candidate.error = "generation: \(error)"
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
          ) async -> GroundingReport {
            let started = ContinuousClock.now
            let report = await heuristics.inspectDetailed(
              sql: sql, result: result)
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
              standalone = try await serializer.run {
                try await activeFM.rewrite(question, history)
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
            let decision = try await serializer.run {
              try await activeFM.gate(
                standalone, configuration.gateSensitivity)
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

            // 3–6. Production generation and bounded repair.
            var repair: RepairContext?
            var attempt = 0
            var primary: CandidateTelemetry?
            while primary == nil {
              let role: CandidateRole =
                attempt == 0 ? .initial : .repair(attempt: attempt)
              if attempt > 0 {
                continuation.yield(.repairStarted(attempt: attempt))
              }
              let id = attempt == 0 ? "initial" : "repair-\(attempt)"
              let candidate = await generateAndExecute(
                request(
                  id: id,
                  role: role,
                  repair: repair,
                  temperature: configuration.productionTemperature),
                attempt: attempt)
              telemetry.candidates.append(candidate)
              if candidate.result != nil {
                primary = candidate
                break
              }
              attempt += 1
              telemetry.repairAttempts = attempt
              guard
                attempt <= configuration.maxRepairAttempts,
                let sql = candidate.sql,
                let error = candidate.error
              else {
                finish(.failed(
                  message:
                    "I couldn't answer that one — try rephrasing the question."))
                return
              }
              repair = RepairContext(
                failedSQL: sql, errorMessage: error)
            }

            guard
              let successfulPrimary = primary,
              let primaryResult = successfulPrimary.result,
              let primarySQL = successfulPrimary.sql
            else {
              finish(.failed(
                message:
                  "I couldn't answer that one — try rephrasing the question."))
              return
            }

            var chosenCandidate = successfulPrimary
            var chosenResult = primaryResult
            var chosenSQL = primarySQL
            var grounding = await inspectGrounding(
              sql: primarySQL, result: primaryResult)

            // 7. Strict-majority result voting. The configured candidate
            // count is the denominator even when a candidate fails.
            let trigger: String? =
              configuration.alwaysVote ? "always"
              : attempt > 0 ? "repair"
              : !grounding.findings.isEmpty ? "grounding"
              : nil
            var voteNotice: String?
            if let trigger, configuration.selfConsistencyN > 1 {
              let votingStarted = ContinuousClock.now
              telemetry.voteTrigger = trigger
              continuation.yield(.selfConsistencyStarted(
                candidateCount: configuration.selfConsistencyN,
                trigger: trigger))

              // The calibrated vote portfolio is always exactly one
              // deterministic anchor plus N-1 candidates generated at the
              // calibrated sample temperature. A nonzero-temperature primary
              // remains in telemetry and is available only for the explicit
              // degraded fallback; it is not substituted for a calibrated
              // consistency sample.
              var voteCandidates: [CandidateTelemetry]
              let anchor: CandidateTelemetry
              if successfulPrimary.temperature == 0 {
                anchor = successfulPrimary
                voteCandidates = [successfulPrimary]
              } else {
                let generatedAnchor = await generateAndExecute(
                  request(
                    id: "deterministic-anchor",
                    role: .deterministicAnchor,
                    repair: nil,
                    temperature: 0),
                  attempt: 0)
                telemetry.candidates.append(generatedAnchor)
                anchor = generatedAnchor
                voteCandidates = [generatedAnchor]
              }

              var sampleIndex = 1
              while voteCandidates.count < configuration.selfConsistencyN {
                let sample = await generateAndExecute(
                  request(
                    id: "consistency-\(sampleIndex)",
                    role: .consistencySample(index: sampleIndex),
                    repair: nil,
                    temperature: configuration.sampleTemperature),
                  attempt: 0)
                telemetry.candidates.append(sample)
                voteCandidates.append(sample)
                sampleIndex += 1
              }

              let voteSet = Array(
                voteCandidates.prefix(configuration.selfConsistencyN))
              var agreementByDigest: [String: Int] = [:]
              for candidate in voteSet {
                if let digest = candidate.resultDigest {
                  agreementByDigest[digest, default: 0] += 1
                }
              }
              let majority =
                agreementByDigest
                .filter {
                  $0.value > configuration.selfConsistencyN / 2
                }
                .sorted { lhs, rhs in
                  if lhs.value != rhs.value {
                    return lhs.value > rhs.value
                  }
                  return lhs.key < rhs.key
                }
                .first

              if let (digest, agreement) = majority,
                let winner = voteSet.first(where: {
                  $0.resultDigest == digest
                }),
                let winnerResult = winner.result,
                let winnerSQL = winner.sql
              {
                chosenCandidate = winner
                chosenResult = winnerResult
                chosenSQL = winnerSQL
                let outcome = VoteOutcome.consensus(
                  resultDigest: digest,
                  agreement: agreement,
                  candidateCount: configuration.selfConsistencyN)
                telemetry.voteOutcome = outcome
                telemetry.selectionReason = .majorityVote
                continuation.yield(.selfConsistencyFinished(outcome))
              } else if anchor.resultDigest != nil,
                let anchorResult = anchor.result,
                let anchorSQL = anchor.sql
              {
                chosenCandidate = anchor
                chosenResult = anchorResult
                chosenSQL = anchorSQL
                let outcome = VoteOutcome.noConsensus(
                  anchorCandidateID: anchor.id,
                  candidateCount: configuration.selfConsistencyN)
                telemetry.voteOutcome = outcome
                telemetry.selectionReason =
                  .noConsensusDeterministicAnchor
                voteNotice =
                  "The candidates did not reach a majority, so I used the deterministic result."
                continuation.yield(.selfConsistencyFinished(outcome))
              } else {
                let message =
                  anchor.error
                  ?? (anchor.result?.isTruncated == true
                    ? "The deterministic anchor result was truncated at the row cap."
                    : "The deterministic anchor did not return a complete result.")
                let outcome = VoteOutcome.anchorFailed(
                  fallbackCandidateID: successfulPrimary.id,
                  message: message)
                telemetry.voteOutcome = outcome
                telemetry.selectionReason = .noConsensusAnchorFailed
                voteNotice =
                  "The deterministic cross-check failed, so I used the successful primary result."
                continuation.yield(.selfConsistencyFinished(outcome))
              }
              telemetry.stageTimings.votingMicroseconds =
                votingStarted.duration(to: .now).microseconds

              if chosenCandidate.id != successfulPrimary.id {
                grounding = await inspectGrounding(
                  sql: chosenSQL, result: chosenResult)
              }
            }

            if telemetry.selectionReason == nil {
              telemetry.selectionReason =
                attempt == 0 ? .initialSuccess : .repairSuccess
            }
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
            let narration = try await serializer.run {
              try await activeFM.narrate(standalone, narrationResult)
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
            let notice = (notices + [voteNotice].compactMap { $0 })
              .joined(separator: " ")
            finish(.answered(
              result: chosenResult,
              narration: narration,
              sql: chosenSQL,
              notice: notice.isEmpty ? nil : notice))
          } catch {
            telemetry.terminalError = String(describing: error)
            finish(.failed(
              message:
                "Something went wrong while answering — please try again."))
          }
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }
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
