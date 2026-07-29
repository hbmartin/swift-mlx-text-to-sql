import Foundation

extension QueryPipeline {
  /// Mirrors useful on-device lifecycle boundaries to unified logging while
  /// forwarding the original event stream byte-for-byte. Payload-bearing
  /// values (question text, SQL, rows, narration, result digests, paths, and
  /// portfolio/user identifiers) are intentionally never copied into
  /// diagnostic events. Generated trace tokens and per-turn candidate
  /// sequence numbers make the payload-free events correlatable.
  public func reportingOperations(
    to diagnostics: DiagnosticsClient
  ) -> QueryPipeline {
    let source = reportingTerminalFailures(to: diagnostics)

    @Sendable func observed(
      question: String,
      history: [ConversationTurn],
      queryOrigin: QueryOrigin,
      starterQueryID: StarterQueryID?,
      events: AsyncStream<PipelineEvent>
    ) -> AsyncStream<PipelineEvent> {
      AsyncStream { continuation in
        let traceID = UUID().uuidString.lowercased()
        let task = Task {
          var observer = PipelineOperationObserver(
            diagnostics: diagnostics,
            question: question,
            history: history,
            traceID: traceID,
            queryOrigin: queryOrigin,
            starterQueryID: starterQueryID)
          observer.streamOpened(historyTurnCount: history.count)
          for await event in events {
            guard !Task.isCancelled else { break }
            observer.record(event)
            continuation.yield(event)
          }
          observer.streamClosed(cancelled: Task.isCancelled)
          continuation.finish()
        }
        continuation.onTermination = { termination in
          if case .cancelled = termination {
            diagnostics.info(
              category: .pipeline,
              code: "pipeline_stream_cancelled",
              summary: "The pipeline event stream was cancelled.",
              context: [
                "trace_id": traceID,
                "query_origin": queryOrigin.rawValue,
                "starter_query_id": starterQueryID?.rawValue ?? "none",
              ])
          }
          task.cancel()
        }
      }
    }

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
        observed(
          question: question,
          history: history,
          queryOrigin: .freeForm,
          starterQueryID: nil,
          events: source.run(question, history))
      },
      runStarter: { starter, history in
        observed(
          question: starter.question,
          history: history,
          queryOrigin: .starter,
          starterQueryID: starter,
          events: source.runStarter(starter, history))
      })
  }
}

private struct PipelineOperationObserver {
  var diagnostics: DiagnosticsClient
  private var roles: [CandidateID: CandidateRole] = [:]
  private var candidateStates: [CandidateID: CandidateOperationState] = [:]
  private var eventCount = 0
  private var terminalEventSeen = false
  private var turnStartedAt: ContinuousClock.Instant?
  private var conversationContent: [String]
  private let traceID: String
  private let queryOrigin: QueryOrigin
  private let starterQueryID: StarterQueryID?
  private var candidateSequenceByID: [CandidateID: Int] = [:]
  private var nextCandidateSequence = 1

  init(
    diagnostics: DiagnosticsClient,
    question: String,
    history: [ConversationTurn],
    traceID: String,
    queryOrigin: QueryOrigin,
    starterQueryID: StarterQueryID?
  ) {
    self.diagnostics = diagnostics
    self.traceID = traceID
    self.queryOrigin = queryOrigin
    self.starterQueryID = starterQueryID
    self.conversationContent =
      [question]
      + history.flatMap { [$0.question, $0.answerSummary] }
  }

  mutating func streamOpened(historyTurnCount: Int) {
    info(
      "pipeline_stream_opened",
      "A pipeline event stream opened.",
      context: [
        "has_history": String(historyTurnCount > 0),
        "history_turn_count": String(historyTurnCount),
      ])
  }

  mutating func record(_ event: PipelineEvent) {
    eventCount += 1
    switch event {
    case .turnStarted:
      turnStartedAt = .now
      info(
        "pipeline_turn_started",
        "Pipeline turn started.",
        context: [
          "has_starter_query": String(starterQueryID != nil)
        ])

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
      _ = registerCandidate(request.candidateID)
      roles[request.candidateID] = request.role
      conversationContent.append(request.question)
      candidateStates[request.candidateID] = CandidateOperationState(
        startedAt: .now,
        stageStartedAt: .now,
        stage: .generation)
      info(
        "pipeline_generation_started",
        "SQL candidate generation started.",
        context: [
          "candidate_role": candidateRole(request.role),
          "gcd": request.gcd.rawValue,
          "is_repair": String(request.repair != nil),
          "max_tokens": String(request.maxTokens),
          "model_key": request.model.key,
          "model_revision_prefix": String(request.model.revision.prefix(12)),
          "quantization": request.model.quantization,
          "seed": request.seed.map(String.init) ?? "none",
          "temperature": String(format: "%.3f", request.temperature),
        ])
      if let repair = request.repair {
        logRepairInput(repair, candidateID: request.candidateID)
      }

    case .generationFinished(let candidateID, let generation):
      candidateStates[candidateID]?.generationMicroseconds =
        generation.elapsedMicroseconds
      candidateStates[candidateID]?.stage = .postGeneration
      candidateStates[candidateID]?.stageStartedAt = .now
      var context = candidateContext(candidateID)
      context["elapsed_ms"] = operationMilliseconds(
        generation.elapsedMicroseconds)
      context["token_count"] = generation.tokenCount.map(String.init) ?? "unknown"
      context["tokens_per_second"] = String(
        format: "%.1f", generation.tokensPerSecond)
      if let speculation = generation.speculation {
        context["speculation_round_count"] = String(speculation.roundCount)
        context["speculation_draft_token_count"] = String(
          speculation.draftTokenCount)
        context["speculation_accepted_token_count"] = String(
          speculation.acceptedDraftTokenCount)
        context["speculation_target_call_count"] = String(
          speculation.targetModelCallCount)
        context["speculation_target_verified_token_count"] = String(
          speculation.targetVerifiedTokenCount)
        context["speculation_emitted_token_count"] = String(
          speculation.emittedTokenCount)
        context["speculation_acceptance_percent"] = speculationAcceptancePercent(
          speculation)
      }
      info(
        "pipeline_generation_finished",
        "SQL candidate generation finished.",
        context: context)

    case .validationStarted(let candidateID):
      _ = registerCandidate(candidateID)
      if candidateStates[candidateID] == nil,
        candidateID.rawValue.hasPrefix("starter-"),
        let starter = StarterQueryID(
          rawValue: String(candidateID.rawValue.dropFirst("starter-".count)))
      {
        roles[candidateID] = .starter(starter)
        candidateStates[candidateID] = CandidateOperationState(
          startedAt: .now,
          stageStartedAt: .now,
          stage: .validation)
      }
      candidateStates[candidateID]?.stage = .validation
      candidateStates[candidateID]?.stageStartedAt = .now
      info(
        "pipeline_validation_started",
        "SQL candidate validation started.",
        context: candidateContext(candidateID))

    case .validationFinished(let candidateID, let report):
      candidateStates[candidateID]?.validationMicroseconds =
        report.elapsedMicroseconds
      candidateStates[candidateID]?.issueKind = report.issue?.kind.rawValue
      candidateStates[candidateID]?.disposition =
        report.issue?.disposition.rawValue
      if report.issue == nil {
        candidateStates[candidateID]?.stage = .postValidation
        candidateStates[candidateID]?.stageStartedAt = .now
      }
      var context = candidateContext(candidateID)
      context["elapsed_ms"] = operationMilliseconds(
        report.elapsedMicroseconds)
      context["is_valid"] = String(report.isValid)
      context["issue_kind"] = report.issue?.kind.rawValue ?? "none"
      context["disposition"] = report.issue?.disposition.rawValue ?? "none"
      context["issue_message_present"] = String(report.issue != nil)
      info(
        "pipeline_validation_finished",
        "SQL candidate validation finished.",
        context: context)

    case .executionStarted(let candidateID, _):
      candidateStates[candidateID]?.stage = .execution
      candidateStates[candidateID]?.stageStartedAt = .now
      info(
        "pipeline_execution_started",
        "SQL candidate execution started.",
        context: candidateContext(candidateID))

    case .executionFinished(let candidateID, let result):
      candidateStates[candidateID]?.stage = .finished
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

    case .executionFailed(let candidateID, let message, let attempt):
      var context = candidateContext(candidateID)
      context["attempt"] = String(attempt)
      let state = candidateStates[candidateID]
      let failureStage = state?.stage.rawValue ?? "unknown"
      context["failure_stage"] = failureStage
      context["issue_kind"] = state?.issueKind ?? "none"
      context["disposition"] = state?.disposition ?? "none"
      if let startedAt = state?.startedAt {
        context["candidate_elapsed_ms"] = operationMilliseconds(
          startedAt.duration(to: .now).microseconds)
      }
      if let stageStartedAt = state?.stageStartedAt {
        context["stage_elapsed_ms"] = operationMilliseconds(
          stageStartedAt.duration(to: .now).microseconds)
      }
      diagnostics.record(
        DiagnosticEvent(
          level: .error,
          category: .pipeline,
          code: "pipeline_candidate_failed",
          summary: "A SQL candidate failed during \(failureStage).",
          details: PipelineDiagnosticPrivacy.redact(
            message, conversationContent: conversationContent),
          context: addingTurnElapsed(to: context)))

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
      terminalEventSeen = true
      for candidate in telemetry.candidates {
        logCandidateSummary(candidate)
      }
      var context = [
        "outcome": turnOutcome(outcome),
        "query_origin": telemetry.queryOrigin.rawValue,
        "execution_path": telemetry.executionPath.rawValue,
        "starter_query_id": telemetry.starterQueryID?.rawValue ?? "none",
        "candidate_count": String(telemetry.candidates.count),
        "generated_count": String(telemetry.generatedCount),
        "repair_attempts": String(telemetry.repairAttempts),
        "recovery_outcome": telemetry.recoveryOutcome?.rawValue ?? "none",
        "failed_candidate_count": String(
          telemetry.candidates.filter { $0.error != nil }.count),
        "successful_candidate_count": String(
          telemetry.candidates.filter { $0.result != nil }.count),
        "total_elapsed_ms": operationMilliseconds(
          telemetry.stageTimings.totalMicroseconds),
      ]
      context["confidence"] = telemetry.confidence?.rawValue ?? "none"
      context["rewrite_applied"] = String(telemetry.rewriteApplied)
      context["rewrite_used_fm"] = String(telemetry.rewriteUsedFM)
      context["gate_used_fm"] = String(telemetry.gateUsedFM)
      context["narration_used_fm"] = String(telemetry.narrationUsedFM)
      context["gate_mode"] = telemetry.gateMode?.rawValue ?? "none"
      context["repair_policy_version"] =
        telemetry.repairPolicyVersion ?? "none"
      context["selection_reason"] = telemetry.selectionReason?.rawValue ?? "none"
      context["timeout_stage"] = timeoutStage(telemetry.timeoutStage)
      context["no_consensus_reason"] =
        telemetry.noConsensusReason?.rawValue ?? "none"
      context["terminal_error_present"] = String(telemetry.terminalError != nil)
      context["selected_candidate_sequence"] = selectedCandidateSequence(
        telemetry.selectedCandidateID)
      context["vote_trigger"] = telemetry.voteTrigger.map(voteTrigger) ?? "none"
      context["grounding_check_count"] = String(
        telemetry.grounding?.checks.count ?? 0)
      context["grounding_skipped_count"] = String(
        telemetry.grounding?.skipped.count ?? 0)
      context["grounding_finding_count"] = String(
        telemetry.grounding?.findings.count ?? 0)
      context["grounding_degradation_count"] = String(
        telemetry.grounding?.degradations.count ?? 0)
      if let voteOutcome = telemetry.voteOutcome {
        for (key, value) in voteContext(voteOutcome) {
          context["vote_\(key)"] = value
        }
      }
      addTimingContext(telemetry.stageTimings, to: &context)
      info(
        "pipeline_turn_finished",
        "Pipeline turn finished.",
        context: context)
    }
  }

  mutating func streamClosed(cancelled: Bool) {
    let context = addingTurnElapsed(to: [
      "cancelled": String(cancelled),
      "event_count": String(eventCount),
      "terminal_event_seen": String(terminalEventSeen),
    ])
    if !cancelled && !terminalEventSeen {
      diagnostics.record(
        DiagnosticEvent(
          level: .error,
          category: .pipeline,
          code: "pipeline_stream_ended_without_terminal_event",
          summary: "The pipeline event stream ended without a terminal event.",
          context: context))
    } else {
      diagnostics.info(
        category: .pipeline,
        code: "pipeline_stream_closed",
        summary: "The pipeline event stream closed.",
        context: context)
    }
  }

  private mutating func candidateContext(_ id: CandidateID) -> [String: String] {
    var context = [
      "candidate_sequence": String(registerCandidate(id)),
      "candidate_role": roles[id].map(candidateRole) ?? "unknown",
    ]
    if let generationMicroseconds = candidateStates[id]?.generationMicroseconds {
      context["generation_elapsed_ms"] = operationMilliseconds(
        generationMicroseconds)
    }
    if let validationMicroseconds = candidateStates[id]?.validationMicroseconds {
      context["validation_elapsed_ms"] = operationMilliseconds(
        validationMicroseconds)
    }
    return context
  }

  private mutating func registerCandidate(_ id: CandidateID) -> Int {
    if let sequence = candidateSequenceByID[id] { return sequence }
    let sequence = nextCandidateSequence
    nextCandidateSequence += 1
    candidateSequenceByID[id] = sequence
    return sequence
  }

  private mutating func selectedCandidateSequence(
    _ id: CandidateID?
  ) -> String {
    guard let id else { return "none" }
    return String(registerCandidate(id))
  }

  private mutating func logRepairInput(
    _ repair: RepairContext,
    candidateID: CandidateID
  ) {
    var context = candidateContext(candidateID)
    context["failed_sql_present"] = String(!repair.failedSQL.isEmpty)
    context["error_message_present"] = String(!repair.errorMessage.isEmpty)
    guard let guidance = repair.guidance else {
      context["guidance_present"] = "false"
      info(
        "pipeline_repair_input",
        "SQL repair input was prepared.",
        context: context)
      return
    }
    context["guidance_present"] = "true"
    context["invalid_reference_present"] = String(
      guidance.invalidReference != nil)
    context["invalid_qualifier_present"] = String(
      guidance.invalidQualifier != nil)
    context["invalid_column_present"] = String(guidance.invalidColumn != nil)
    context["declared_source_count"] = String(guidance.declaredSources.count)
    context["possible_owner_count"] = String(
      guidance.possibleColumnOwners.count)
    context["source_schema_count"] = String(guidance.sourceColumns.count)
    context["source_column_count"] = String(
      guidance.sourceColumns.values.reduce(0) { $0 + $1.count })
    context["relevant_foreign_key_count"] = String(
      guidance.relevantForeignKeys.count)
    context["failed_fingerprint_count"] = String(
      guidance.failedFingerprints.count)
    context["corrective_instruction_present"] = String(
      !guidance.correctiveInstruction.isEmpty)
    info(
      "pipeline_repair_input",
      "SQL repair input was prepared.",
      context: context)
  }

  private mutating func logCandidateSummary(_ candidate: CandidateTelemetry) {
    roles[candidate.id] = candidate.role
    var generationContext = candidateContext(candidate.id)
    generationContext["model_key"] = candidate.model.key
    generationContext["model_revision_prefix"] = String(
      candidate.model.revision.prefix(12))
    generationContext["quantization"] = candidate.model.quantization
    generationContext["gcd"] = candidate.gcd.rawValue
    generationContext["temperature"] = String(
      format: "%.3f", candidate.temperature)
    generationContext["seed"] = candidate.seed.map(String.init) ?? "none"
    generationContext["max_tokens"] = String(candidate.maxTokens)
    generationContext["sql_present"] = String(candidate.sql != nil)
    generationContext["sql_fingerprint_present"] = String(
      candidate.sqlFingerprint != nil)
    generationContext["generation_elapsed_ms"] = optionalMilliseconds(
      candidate.generationMicroseconds)
    generationContext["tokens_per_second"] =
      candidate.tokensPerSecond.map {
        String(format: "%.1f", $0)
      } ?? "unknown"
    generationContext["token_count"] =
      candidate.tokenCount.map(String.init) ?? "unknown"
    if let repair = candidate.repairContext {
      generationContext["repair_context_present"] = "true"
      generationContext["repair_guidance_present"] = String(
        repair.guidance != nil)
      generationContext["repair_failed_fingerprint_count"] = String(
        repair.guidance?.failedFingerprints.count ?? 0)
    } else {
      generationContext["repair_context_present"] = "false"
      generationContext["repair_guidance_present"] = "false"
      generationContext["repair_failed_fingerprint_count"] = "0"
    }
    info(
      "pipeline_candidate_generation_summary",
      "SQL candidate generation metadata reached a terminal turn state.",
      context: generationContext)

    var context = candidateContext(candidate.id)
    context["validation_state"] = candidateValidationState(candidate)
    context["issue_kind"] =
      candidate.validationReport?.issue?.kind.rawValue ?? "none"
    context["disposition"] =
      candidate.validationReport?.issue?.disposition.rawValue ?? "none"
    context["execution_state"] = candidateExecutionState(candidate)
    context["execution_elapsed_ms"] = optionalMilliseconds(
      candidate.executionMicroseconds)
    context["column_count"] = String(candidate.result?.columns.count ?? 0)
    context["row_count"] = String(candidate.result?.rowCount ?? 0)
    context["is_empty"] = String(candidate.result?.rows.isEmpty ?? true)
    context["is_truncated"] = String(candidate.result?.isTruncated ?? false)
    context["result_digest_present"] = String(candidate.resultDigest != nil)
    context["error_present"] = String(candidate.error != nil)
    context["duplicate_suppressed"] = String(
      candidate.duplicateSuppressed ?? false)
    context["duplicate_of_sequence"] = selectedCandidateSequence(
      candidate.duplicateOf)
    context["selected"] = String(candidate.selected)
    if let speculation = candidate.speculation {
      var speculationContext = candidateContext(candidate.id)
      speculationContext["speculation_round_count"] = String(
        speculation.roundCount)
      speculationContext["speculation_draft_token_count"] = String(
        speculation.draftTokenCount)
      speculationContext["speculation_accepted_token_count"] = String(
        speculation.acceptedDraftTokenCount)
      speculationContext["speculation_target_call_count"] = String(
        speculation.targetModelCallCount)
      speculationContext["speculation_target_verified_token_count"] = String(
        speculation.targetVerifiedTokenCount)
      speculationContext["speculation_emitted_token_count"] = String(
        speculation.emittedTokenCount)
      speculationContext["speculation_acceptance_percent"] =
        speculationAcceptancePercent(speculation)
      info(
        "pipeline_candidate_speculation_summary",
        "SQL candidate speculation metadata reached a terminal turn state.",
        context: speculationContext)
    }
    info(
      "pipeline_candidate_summary",
      "SQL candidate reached a terminal turn state.",
      context: context)
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
      context: addingTurnElapsed(to: context))
  }

  private func addingTurnElapsed(
    to context: [String: String]
  ) -> [String: String] {
    var context = context
    context["trace_id"] = traceID
    if context["query_origin"] == nil {
      context["query_origin"] = queryOrigin.rawValue
    }
    if context["starter_query_id"] == nil {
      context["starter_query_id"] = starterQueryID?.rawValue ?? "none"
    }
    if let turnStartedAt {
      context["turn_elapsed_ms"] = operationMilliseconds(
        turnStartedAt.duration(to: .now).microseconds)
    }
    return context
  }

  private func addTimingContext(
    _ timings: StageTimings,
    to context: inout [String: String]
  ) {
    context["rewrite_elapsed_ms"] = optionalMilliseconds(
      timings.rewriteMicroseconds)
    context["gate_elapsed_ms"] = optionalMilliseconds(
      timings.gateMicroseconds)
    context["validation_elapsed_ms"] = optionalMilliseconds(
      timings.validationMicroseconds)
    context["grounding_elapsed_ms"] = optionalMilliseconds(
      timings.groundingMicroseconds)
    context["voting_elapsed_ms"] = optionalMilliseconds(
      timings.votingMicroseconds)
    context["narration_elapsed_ms"] = optionalMilliseconds(
      timings.narrationMicroseconds)
  }
}

private struct CandidateOperationState {
  var startedAt: ContinuousClock.Instant
  var stageStartedAt: ContinuousClock.Instant
  var stage: CandidateOperationStage
  var generationMicroseconds: Int64?
  var validationMicroseconds: Int64?
  var issueKind: String?
  var disposition: String?
}

private enum CandidateOperationStage: String {
  case generation
  case postGeneration = "post_generation"
  case validation
  case postValidation = "post_validation"
  case execution
  case finished
}

private func candidateRole(_ role: CandidateRole) -> String {
  switch role {
  case .starter(let starter):
    "starter_\(starter.rawValue)"
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

private func candidateValidationState(
  _ candidate: CandidateTelemetry
) -> String {
  guard let report = candidate.validationReport else { return "not_started" }
  return report.isValid ? "valid" : "invalid"
}

private func candidateExecutionState(
  _ candidate: CandidateTelemetry
) -> String {
  if candidate.result != nil { return "succeeded" }
  if candidate.validationReport?.isValid == true && candidate.error != nil {
    return "failed"
  }
  return "not_started"
}

private func speculationAcceptancePercent(
  _ speculation: SQLSpeculationMetrics
) -> String {
  guard speculation.draftTokenCount > 0 else { return "0.0" }
  return String(
    format: "%.1f",
    100 * Double(speculation.acceptedDraftTokenCount)
      / Double(speculation.draftTokenCount))
}

private func operationMilliseconds(_ microseconds: Int64) -> String {
  String(format: "%.1f", Double(microseconds) / 1_000)
}

private func optionalMilliseconds(_ microseconds: Int64?) -> String {
  microseconds.map(operationMilliseconds) ?? "not_started"
}
