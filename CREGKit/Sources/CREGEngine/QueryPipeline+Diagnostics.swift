import CREGCore
import CREGData
import Foundation

extension QueryPipeline {
  /// A non-running pipeline used when startup configuration cannot be loaded.
  /// Friendly copy and developer diagnostics are deliberately kept separate.
  public static func unavailable(
    userMessage: String,
    diagnosticCode: String,
    diagnostic: String
  ) -> QueryPipeline {
    let stage: ModelPreparationStage =
      diagnosticCode.contains("receipt") ? .receiptValidation : .buildPolicy
    return unavailable(
      failure: ModelPreparationFailure(
        code: diagnosticCode,
        stage: stage,
        mode: .evaluated,
        userMessage: userMessage,
        diagnostic: diagnostic))
  }

  public static func unavailable(
    failure: ModelPreparationFailure
  ) -> QueryPipeline {
    QueryPipeline(
      prepareMode: { mode in
        var failure = failure
        failure.mode = mode
        throw failure
      },
      runtimeMode: { failure.mode },
      run: { question, _ in
        AsyncStream { continuation in
          let reason = TurnFailureReason.pipelineUnavailable(
            userMessage: failure.userMessage)
          var telemetry = TurnTelemetry(
            originalQuestion: question,
            runtimeMode: failure.mode)
          telemetry.terminalError = "[\(failure.code)] \(failure.diagnostic)"
          telemetry.failureReason = reason
          continuation.yield(.turnStarted(question: question))
          continuation.yield(
            .questionResolved(
              standaloneQuestion: question,
              rewriteApplied: false,
              usedFM: false,
              elapsedMicroseconds: 0))
          continuation.yield(
            .turnFinished(
              outcome: .failed(reason: reason),
              telemetry: telemetry))
          continuation.finish()
        }
      })
  }

  /// Observes only terminal failures. Candidate failures that recover, normal
  /// completions, and cancellation pass through without an error log.
  public func reportingTerminalFailures(
    to diagnostics: DiagnosticsClient
  ) -> QueryPipeline {
    @Sendable func reported(
      question: String,
      history: [ConversationTurn],
      events: AsyncStream<PipelineEvent>
    ) -> AsyncStream<PipelineEvent> {
      AsyncStream { continuation in
        let task = Task {
          var stage = PipelineDiagnosticStage.unexpected
          var didReport = false
          for await event in events {
            guard !Task.isCancelled else { break }
            stage.observe(event)

            guard
              case .turnFinished(.failed(let reason), var telemetry) = event,
              !didReport
            else {
              continuation.yield(event)
              continue
            }

            didReport = true
            // Diagnostics only: the typed reason emitted at the failure site
            // is authoritative and passes through untouched — this wrapper
            // never rewrites the outcome, it enriches the log record and the
            // developer-facing terminalError.
            let failure = PipelineTerminalFailure(
              reason: reason,
              stage: stage,
              telemetry: telemetry)
            telemetry.terminalError = "[\(failure.code)] \(failure.diagnostic)"
            let logDiagnostic = PipelineDiagnosticPrivacy.redact(
              failure.diagnostic,
              question: question,
              history: history,
              telemetry: telemetry)
            diagnostics.record(
              DiagnosticEvent(
                level: .error,
                category: failure.category,
                code: failure.code,
                summary: failure.summary,
                details: logDiagnostic,
                context: failure.context.merging(
                  ["failure_reason": reason.label]) { current, _ in current }))
            continuation.yield(
              .turnFinished(
                outcome: .failed(reason: reason),
                telemetry: telemetry))
          }
          continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }

    return QueryPipeline(
      prepareMode: { try await self.prepare($0) },
      runtimeMode: { await self.runtimeMode() },
      run: { question, history in
        reported(
          question: question,
          history: history,
          events: self.run(question, history))
      },
      runStarter: { starter in
        reported(
          question: starter.question,
          history: [],
          events: self.runStarter(starter))
      },
      prepareFollowUps: self.prepareFollowUps,
      runPrepared: { prepared, history in
        reported(
          question: prepared.question,
          history: history,
          events: self.runPrepared(prepared, history))
      })
  }
}

private enum PipelineDiagnosticStage: String, Sendable {
  case rewrite
  case gate
  case generation
  case validation
  case execution
  case narration
  case unexpected

  mutating func observe(_ event: PipelineEvent) {
    switch event {
    case .rewriteStarted:
      self = .rewrite
    case .gateStarted:
      self = .gate
    case .generationStarted:
      self = .generation
    case .validationStarted:
      self = .validation
    case .executionStarted:
      self = .execution
    case .narrationStarted:
      self = .narration
    default:
      break
    }
  }
}

private struct PipelineTerminalFailure: Sendable {
  var category: DiagnosticEvent.Category
  var code: String
  var summary: String
  var diagnostic: String
  var context: [String: String]

  private init(
    category: DiagnosticEvent.Category,
    code: String,
    summary: String,
    diagnostic: String,
    context: [String: String]
  ) {
    self.category = category
    self.code = code
    self.summary = summary
    self.diagnostic = diagnostic
    self.context = context
  }

  /// The diagnostics code, category, and summary derive from the typed
  /// reason alone — one mapping, no second failure taxonomy. Telemetry only
  /// enriches the record with stage context and the best diagnostic string;
  /// it never decides how the event is filed.
  init(
    reason: TurnFailureReason,
    stage: PipelineDiagnosticStage,
    telemetry: TurnTelemetry
  ) {
    let lastFailure =
      telemetry.candidates.last(where: {
        $0.error != nil && $0.duplicateSuppressed != true
      })
      ?? telemetry.candidates.last(where: { $0.error != nil })
    let candidateDiagnostic = lastFailure?.error
    let terminalDiagnostic = telemetry.terminalError
    let fallbackDiagnostic =
      terminalDiagnostic
      ?? candidateDiagnostic
      ?? "The pipeline ended without an underlying diagnostic."
    var baseContext = [
      "stage": stage.rawValue,
      "query_origin": telemetry.queryOrigin.rawValue,
      "execution_path": telemetry.executionPath.rawValue,
      "candidate_count": String(telemetry.candidates.count),
      "repair_attempts": String(telemetry.repairAttempts),
      "recovery_outcome": telemetry.recoveryOutcome?.rawValue ?? "none",
      "total_elapsed_ms": terminalMilliseconds(
        telemetry.stageTimings.totalMicroseconds),
    ]
    if let lastFailure {
      baseContext["candidate_role"] = terminalCandidateRole(lastFailure.role)
      baseContext["candidate_generation_elapsed_ms"] =
        lastFailure.generationMicroseconds.map(terminalMilliseconds) ?? "not_started"
      baseContext["candidate_execution_elapsed_ms"] =
        lastFailure.executionMicroseconds.map(terminalMilliseconds) ?? "not_started"
      baseContext["issue_kind"] =
        lastFailure.validationReport?.issue?.kind.rawValue ?? "none"
      baseContext["disposition"] =
        lastFailure.validationReport?.issue?.disposition.rawValue ?? "none"
      baseContext["generated_sql"] = String(lastFailure.sql != nil)
      baseContext["produced_result"] = String(lastFailure.result != nil)
    }
    if let timeoutStage = telemetry.timeoutStage {
      baseContext["timeout_stage"] = timeoutStage
    }

    let category: DiagnosticEvent.Category
    let code: String
    let summary: String
    var diagnostic = candidateDiagnostic ?? fallbackDiagnostic
    switch reason {
    case .timedOut:
      category = .pipeline
      code = "pipeline_deadline_exceeded"
      summary = "The on-device query turn exceeded its deadline."
    case .cancelled:
      category = .pipeline
      code = "pipeline_turn_cancelled"
      summary = "The on-device query turn was cancelled."
    case .databaseUnavailable:
      category = .database
      code = "pipeline_portfolio_database_unavailable"
      summary = "The bundled portfolio database is unavailable."
    case .generationFailed:
      category = .pipeline
      code = "pipeline_model_generation_failed"
      summary = "The SQL model failed to generate a query."
    case .generationExhausted:
      category = .pipeline
      code = "pipeline_generation_exhausted"
      summary = "Every generated candidate failed validation or execution."
    case .noCandidateSelected:
      category = .pipeline
      code = "pipeline_no_candidate_selected"
      summary = "No generated candidate produced a selectable answer."
    case .languageServiceFailed:
      category = .pipeline
      code = "pipeline_foundation_model_failed"
      summary = "The on-device language service failed."
      diagnostic = terminalDiagnostic ?? diagnostic
    case .starterQueryUnavailable:
      category = .database
      code = "pipeline_starter_query_unavailable"
      summary = "A reviewed Starter Query could not run."
    case .pipelineUnavailable:
      category = .pipeline
      code = "pipeline_unavailable"
      summary = "The query pipeline is unavailable."
      diagnostic = terminalDiagnostic ?? diagnostic
    case .unexpected:
      category = .pipeline
      code = "pipeline_unexpected_failure"
      summary = "The query pipeline ended unexpectedly."
      diagnostic = fallbackDiagnostic
    }
    self.init(
      category: category,
      code: code,
      summary: summary,
      diagnostic: diagnostic,
      context: baseContext)
  }
}

private func terminalCandidateRole(_ role: CandidateRole) -> String {
  switch role {
  case .starter(let starter):
    "starter_\(starter.rawValue)"
  case .followUpPreflight(let rank):
    "follow_up_preflight_\(rank)"
  case .initial:
    "initial"
  case .repair(let attempt):
    "repair_\(attempt)"
  case .deterministicAnchor:
    "deterministic_anchor"
  case .consistencySample(let index):
    "consistency_sample_\(index)"
  }
}

private func terminalMilliseconds(_ microseconds: Int64) -> String {
  String(format: "%.1f", Double(microseconds) / 1_000)
}
