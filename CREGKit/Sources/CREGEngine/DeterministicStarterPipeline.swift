import CREGCore
import CREGData
import Foundation

package func deterministicStarterStream(
  starter: StarterQueryID,
  fm: FMClient,
  db: DatabaseClient,
  serializer: InferenceSerializer,
  heuristics: ResultHeuristics,
  configuration: QueryPipeline.Configuration,
  runtimeMode: @escaping @Sendable () async -> ModelRuntimeMode
) -> AsyncStream<PipelineEvent> {
  AsyncStream { continuation in
    let task = Task {
      let turnStarted = ContinuousClock.now
      let question = starter.question
      let sql = starter.sql
      let candidateID = CandidateID(rawValue: "starter-\(starter.rawValue)")
      let request = SQLGenerationRequest(
        candidateID: candidateID,
        role: .starter(starter),
        model: configuration.model,
        question: question,
        gcd: .off,
        temperature: 0,
        seed: nil,
        maxTokens: configuration.maxTokens)
      var candidate = CandidateTelemetry(request: request)
      candidate.sql = sql
      candidate.sqlFingerprint = PreparedFollowUpIntegrity.fingerprint(sql: sql)
      var telemetry = TurnTelemetry(
        originalQuestion: question,
        runtimeMode: await runtimeMode())
      telemetry.queryOrigin = .starter
      telemetry.starterQueryID = starter
      telemetry.executionPath = .deterministicStarter
      telemetry.gateDecision = .proceed
      telemetry.gateMode = .bypassed
      telemetry.recoveryOutcome = .notNeeded
      defer { continuation.finish() }

      func remainingSeconds() -> Double {
        configuration.deadlines.wholeTurnSeconds
          - Double(turnStarted.duration(to: .now).microseconds) / 1_000_000
      }

      func finish(_ outcome: TurnOutcome) {
        telemetry.candidates = [candidate]
        telemetry.generatedCount = 0
        telemetry.stageTimings.totalMicroseconds =
          turnStarted.duration(to: .now).microseconds
        continuation.yield(.turnFinished(outcome: outcome, telemetry: telemetry))
      }

      continuation.yield(.turnStarted(question: question))
      continuation.yield(
        .questionResolved(
          standaloneQuestion: question,
          rewriteApplied: false,
          usedFM: false,
          elapsedMicroseconds: 0))

      do {
        continuation.yield(.validationStarted(candidateID: candidateID))
        let validation = try await withPipelineDeadline(
          seconds: remainingSeconds(),
          stage: "starter-validation"
        ) {
          try await db.validate(sql)
        }
        candidate.validationReport = validation
        telemetry.stageTimings.validationMicroseconds = validation.elapsedMicroseconds
        continuation.yield(
          .validationFinished(
            candidateID: candidateID,
            report: validation))
        if let issue = validation.issue {
          candidate.error = issue.message
          telemetry.recoveryOutcome = .terminal
          telemetry.terminalError = issue.message
          continuation.yield(
            .executionFailed(
              candidateID: candidateID,
              message: issue.message,
              attempt: 0))
          finish(
            .failed(
              message: "That built-in portfolio query is temporarily unavailable."))
          return
        }

        continuation.yield(.executionStarted(candidateID: candidateID, sql: sql))
        let result = try await withPipelineDeadline(
          seconds: remainingSeconds(),
          stage: "starter-execution"
        ) {
          try await db.execute(sql)
        }
        candidate.executionMicroseconds = result.elapsedMicroseconds
        candidate.result = result
        if !result.isTruncated {
          candidate.resultDigest = CanonicalSQLResult(result).digest
        }
        continuation.yield(
          .executionFinished(
            candidateID: candidateID,
            result: result))

        let groundingStarted = ContinuousClock.now
        let grounding = try await withPipelineDeadline(
          seconds: remainingSeconds(),
          stage: "starter-grounding"
        ) {
          await heuristics.inspectDetailed(sql: sql, result: result)
        }
        let groundingElapsed =
          groundingStarted.duration(to: .now).microseconds
        telemetry.stageTimings.groundingMicroseconds = groundingElapsed
        telemetry.grounding = grounding
        continuation.yield(
          .groundingFinished(
            report: grounding,
            elapsedMicroseconds: groundingElapsed))

        candidate.selected = true
        telemetry.selectedCandidateID = candidateID
        telemetry.selectionReason = .starterQuery
        telemetry.confidence = .confirmed

        let fmAvailable = fm.availability() == .available
        let activeFM = fmAvailable ? fm : .fallback()
        continuation.yield(.narrationStarted)
        let narrationStarted = ContinuousClock.now
        let narration = try await withPipelineDeadline(
          seconds: remainingSeconds(),
          stage: "starter-narration"
        ) {
          try await serializer.run(operation: .narration) {
            try await activeFM.narrate(question, result)
          }
        }
        let narrationElapsed =
          narrationStarted.duration(to: .now).microseconds
        telemetry.narrationUsedFM = fmAvailable
        telemetry.stageTimings.narrationMicroseconds = narrationElapsed
        continuation.yield(
          .narrationFinished(
            narration: narration,
            usedFM: fmAvailable,
            elapsedMicroseconds: narrationElapsed))

        let notice = grounding.findings.first?.userNotice
        finish(
          .answered(
            result: result,
            narration: narration,
            sql: sql,
            notice: notice))
      } catch {
        if let deadline = error as? PipelineDeadlineExceeded {
          telemetry.timeoutStage = deadline.stage
        } else if error is CancellationError {
          telemetry.timeoutStage = "cancelled"
        }
        candidate.error = String(describing: error)
        telemetry.recoveryOutcome = .terminal
        telemetry.terminalError = candidate.error
        continuation.yield(
          .executionFailed(
            candidateID: candidateID,
            message: candidate.error!,
            attempt: 0))
        finish(
          .failed(
            message: telemetry.timeoutStage == nil
              ? "That built-in portfolio query is temporarily unavailable."
              : "That answer took too long. Please try again."))
      }
    }
    continuation.onTermination = { _ in task.cancel() }
  }
}
