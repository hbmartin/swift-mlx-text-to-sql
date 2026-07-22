import Foundation

extension QueryPipeline {
  /// Mirrors useful on-device lifecycle boundaries to unified logging while
  /// forwarding the original event stream byte-for-byte. Payload-bearing
  /// values (question text, SQL, rows, narration, result digests, paths, and
  /// identifiers) are intentionally never copied into diagnostic events.
  public func reportingOperations(
    to diagnostics: DiagnosticsClient
  ) -> QueryPipeline {
    let source = reportingTerminalFailures(to: diagnostics)
    return QueryPipeline(
      prepare: {
        let started = ContinuousClock.now
        diagnostics.info(
          category: .pipeline,
          code: "pipeline_preparation_started",
          summary: "Pipeline preparation started.")
        do {
          try await source.prepare()
          diagnostics.info(
            category: .pipeline,
            code: "pipeline_preparation_finished",
            summary: "Pipeline preparation finished.",
            context: [
              "elapsed_ms": operationMilliseconds(
                started.duration(to: .now).microseconds)
            ])
        } catch {
          diagnostics.record(
            DiagnosticEvent(
              level: .error,
              category: .pipeline,
              code: "pipeline_preparation_failed",
              summary: "Pipeline preparation failed.",
              details: DiagnosticDetails.describe(error),
              context: [
                "elapsed_ms": operationMilliseconds(
                  started.duration(to: .now).microseconds)
              ]))
          throw error
        }
      },
      run: { question, history in
        AsyncStream { continuation in
          let task = Task {
            var observer = PipelineOperationObserver(diagnostics: diagnostics)
            diagnostics.info(
              category: .pipeline,
              code: "pipeline_stream_opened",
              summary: "A pipeline event stream opened.",
              context: [
                "has_history": String(!history.isEmpty),
                "history_turn_count": String(history.count),
              ])
            for await event in source.run(question, history) {
              guard !Task.isCancelled else { break }
              observer.record(event)
              continuation.yield(event)
            }
            continuation.finish()
          }
          continuation.onTermination = { termination in
            if case .cancelled = termination {
              diagnostics.info(
                category: .pipeline,
                code: "pipeline_stream_cancelled",
                summary: "The pipeline event stream was cancelled.")
            }
            task.cancel()
          }
        }
      })
  }
}

private struct PipelineOperationObserver {
  var diagnostics: DiagnosticsClient
  private var roles: [CandidateID: CandidateRole] = [:]

  init(diagnostics: DiagnosticsClient) {
    self.diagnostics = diagnostics
  }

  mutating func record(_ event: PipelineEvent) {
    switch event {
    case .turnStarted:
      info("pipeline_turn_started", "Pipeline turn started.")

    case .rewriteStarted:
      info("pipeline_rewrite_started", "Question rewrite started.")

    case .questionResolved(
      _, let rewriteApplied, let usedFM, let elapsedMicroseconds):
      info(
        "pipeline_question_resolved",
        "Question resolution finished.",
        context: [
          "rewrite_applied": String(rewriteApplied),
          "used_fm": String(usedFM),
          "elapsed_ms": operationMilliseconds(elapsedMicroseconds),
        ])

    case .gateStarted:
      info("pipeline_gate_started", "Ambiguity gate started.")

    case .gateFinished(let decision, let usedFM, let elapsedMicroseconds):
      info(
        "pipeline_gate_finished",
        "Ambiguity gate finished.",
        context: [
          "decision": gateDecision(decision),
          "used_fm": String(usedFM),
          "elapsed_ms": operationMilliseconds(elapsedMicroseconds),
        ])

    case .generationStarted(let request):
      roles[request.candidateID] = request.role
      info(
        "pipeline_generation_started",
        "SQL candidate generation started.",
        context: [
          "candidate_role": candidateRole(request.role),
          "gcd": request.gcd.rawValue,
          "is_repair": String(request.repair != nil),
          "max_tokens": String(request.maxTokens),
        ])

    case .generationFinished(let candidateID, let generation):
      var context = candidateContext(candidateID)
      context["elapsed_ms"] = operationMilliseconds(
        generation.elapsedMicroseconds)
      context["token_count"] = generation.tokenCount.map(String.init) ?? "unknown"
      context["tokens_per_second"] = String(
        format: "%.1f", generation.tokensPerSecond)
      info(
        "pipeline_generation_finished",
        "SQL candidate generation finished.",
        context: context)

    case .validationStarted(let candidateID):
      info(
        "pipeline_validation_started",
        "SQL candidate validation started.",
        context: candidateContext(candidateID))

    case .validationFinished(let candidateID, let report):
      var context = candidateContext(candidateID)
      context["elapsed_ms"] = operationMilliseconds(
        report.elapsedMicroseconds)
      context["is_valid"] = String(report.isValid)
      context["issue_kind"] = report.issue?.kind.rawValue ?? "none"
      context["disposition"] = report.issue?.disposition.rawValue ?? "none"
      info(
        "pipeline_validation_finished",
        "SQL candidate validation finished.",
        context: context)

    case .executionStarted(let candidateID, _):
      info(
        "pipeline_execution_started",
        "SQL candidate execution started.",
        context: candidateContext(candidateID))

    case .executionFinished(let candidateID, let result):
      var context = candidateContext(candidateID)
      context["column_count"] = String(result.columns.count)
      context["row_count"] = String(result.rowCount)
      context["is_empty"] = String(result.rows.isEmpty)
      context["is_truncated"] = String(result.isTruncated)
      context["elapsed_ms"] = operationMilliseconds(
        result.elapsedMicroseconds)
      info(
        "pipeline_execution_finished",
        "SQL candidate execution finished.",
        context: context)

    case .executionFailed(let candidateID, _, let attempt):
      var context = candidateContext(candidateID)
      context["attempt"] = String(attempt)
      info(
        "pipeline_candidate_failed",
        "A SQL candidate did not produce an executable result.",
        context: context)

    case .repairStarted(let attempt):
      info(
        "pipeline_repair_started",
        "SQL repair generation started.",
        context: ["attempt": String(attempt)])

    case .groundingFinished(let report, let elapsedMicroseconds):
      info(
        "pipeline_grounding_finished",
        "Result grounding checks finished.",
        context: [
          "check_count": String(report.checks.count),
          "degradation_count": String(report.degradations.count),
          "finding_count": String(report.findings.count),
          "skipped_count": String(report.skipped.count),
          "elapsed_ms": operationMilliseconds(elapsedMicroseconds),
        ])

    case .selfConsistencyStarted(let candidateCount, let trigger):
      info(
        "pipeline_voting_started",
        "Candidate voting started.",
        context: [
          "candidate_count": String(candidateCount),
          "trigger": voteTrigger(trigger),
        ])

    case .selfConsistencyFinished(let outcome):
      info(
        "pipeline_voting_finished",
        "Candidate voting finished.",
        context: voteContext(outcome))

    case .narrationStarted:
      info("pipeline_narration_started", "Answer narration started.")

    case .narrationFinished(_, let usedFM, let elapsedMicroseconds):
      info(
        "pipeline_narration_finished",
        "Answer narration finished.",
        context: [
          "used_fm": String(usedFM),
          "elapsed_ms": operationMilliseconds(elapsedMicroseconds),
        ])

    case .turnFinished(let outcome, let telemetry):
      var context = [
        "outcome": turnOutcome(outcome),
        "generated_count": String(telemetry.generatedCount),
        "repair_attempts": String(telemetry.repairAttempts),
        "total_elapsed_ms": operationMilliseconds(
          telemetry.stageTimings.totalMicroseconds),
      ]
      context["confidence"] = telemetry.confidence?.rawValue ?? "none"
      context["selection_reason"] = telemetry.selectionReason?.rawValue ?? "none"
      context["timeout_stage"] = timeoutStage(telemetry.timeoutStage)
      context["no_consensus_reason"] =
        telemetry.noConsensusReason?.rawValue ?? "none"
      info(
        "pipeline_turn_finished",
        "Pipeline turn finished.",
        context: context)
    }
  }

  private func candidateContext(_ id: CandidateID) -> [String: String] {
    ["candidate_role": roles[id].map(candidateRole) ?? "unknown"]
  }

  private func info(
    _ code: String,
    _ summary: String,
    context: [String: String] = [:]
  ) {
    diagnostics.info(
      category: .pipeline,
      code: code,
      summary: summary,
      context: context)
  }
}

private func candidateRole(_ role: CandidateRole) -> String {
  switch role {
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

private func gateDecision(_ decision: GateDecision) -> String {
  switch decision {
  case .proceed: "proceed"
  case .clarify: "clarify"
  }
}

private func voteContext(_ outcome: VoteOutcome) -> [String: String] {
  switch outcome {
  case .consensus(_, let agreement, let candidateCount):
    [
      "outcome": "consensus",
      "agreement": String(agreement),
      "candidate_count": String(candidateCount),
    ]
  case .noConsensus(_, let candidateCount, let reason):
    [
      "outcome": "no_consensus",
      "candidate_count": String(candidateCount),
      "reason": reason?.rawValue ?? "unknown",
    ]
  case .anchorFailed(_, _):
    ["outcome": "anchor_failed"]
  }
}

private func voteTrigger(_ trigger: String) -> String {
  switch trigger {
  case "initial-validation", "repair": trigger
  default: "unknown"
  }
}

private func timeoutStage(_ stage: String?) -> String {
  guard let stage else { return "none" }
  return switch stage {
  case "turn", "generation", "validation", "execution", "grounding",
    "rewrite", "gate", "narration", "cancelled":
    stage
  default:
    "unknown"
  }
}

private func turnOutcome(_ outcome: TurnOutcome) -> String {
  switch outcome {
  case .answered: "answered"
  case .needsClarification: "needs_clarification"
  case .failed: "failed"
  }
}

private func operationMilliseconds(_ microseconds: Int64) -> String {
  String(format: "%.1f", Double(microseconds) / 1_000)
}
