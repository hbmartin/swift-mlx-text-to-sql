import Foundation

extension QueryPipeline {
  /// A non-running pipeline used when startup configuration cannot be loaded.
  /// Friendly copy and developer diagnostics are deliberately kept separate.
  public static func unavailable(
    userMessage: String,
    diagnosticCode: String,
    diagnostic: String
  ) -> QueryPipeline {
    QueryPipeline(prepare: {
      throw PipelineUnavailableError(diagnostic)
    }) { question, _ in
      AsyncStream { continuation in
        var telemetry = TurnTelemetry(originalQuestion: question)
        telemetry.terminalError = "[\(diagnosticCode)] \(diagnostic)"
        continuation.yield(.turnStarted(question: question))
        continuation.yield(.questionResolved(
          standaloneQuestion: question,
          rewriteApplied: false,
          usedFM: false,
          elapsedMicroseconds: 0))
        continuation.yield(.turnFinished(
          outcome: .failed(message: userMessage),
          telemetry: telemetry))
        continuation.finish()
      }
    }
  }

  /// Observes only terminal failures. Candidate failures that recover, normal
  /// completions, and cancellation pass through without an error log.
  public func reportingTerminalFailures(
    to diagnostics: DiagnosticsClient
  ) -> QueryPipeline {
    QueryPipeline(prepare: self.prepare) { question, history in
      AsyncStream { continuation in
        let task = Task {
          var stage = PipelineDiagnosticStage.unexpected
          var didReport = false
          for await event in self.run(question, history) {
            guard !Task.isCancelled else { break }
            stage.observe(event)

            guard
              case .turnFinished(.failed, var telemetry) = event,
              !didReport
            else {
              continuation.yield(event)
              continue
            }

            didReport = true
            let failure = PipelineTerminalFailure(
              stage: stage,
              telemetry: telemetry)
            telemetry.terminalError = "[\(failure.code)] \(failure.diagnostic)"
            let logDiagnostic = PipelineDiagnosticPrivacy.redact(
              failure.diagnostic,
              question: question,
              history: history,
              telemetry: telemetry)
            diagnostics.record(DiagnosticEvent(
              level: .error,
              category: failure.category,
              code: failure.code,
              summary: failure.summary,
              details: logDiagnostic,
              context: failure.context))
            continuation.yield(.turnFinished(
              outcome: .failed(message: failure.userMessage),
              telemetry: telemetry))
          }
          continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }
  }
}

private struct PipelineUnavailableError: Error, CustomStringConvertible {
  var diagnostic: String

  init(_ diagnostic: String) {
    self.diagnostic = diagnostic
  }

  var description: String { diagnostic }
}

enum PipelineDiagnosticPrivacy {
  static func redact(
    _ diagnostic: String,
    question: String,
    history: [ConversationTurn],
    telemetry: TurnTelemetry
  ) -> String {
    redact(
      diagnostic,
      conversationContent:
      [question, telemetry.originalQuestion, telemetry.standaloneQuestion]
        + history.flatMap { [$0.question, $0.answerSummary] })
  }

  static func redact(
    _ diagnostic: String,
    conversationContent: [String]
  ) -> String {
    var value = diagnostic
    let conversationContent = Set(conversationContent)
      .filter { !$0.isEmpty }
      .sorted { $0.count > $1.count }
    for content in conversationContent {
      if value.trimmingCharacters(in: .whitespacesAndNewlines) == content {
        value = "<redacted conversation content>"
      } else if content.count >= 8 {
        value = value.replacingOccurrences(
          of: content,
          with: "<redacted conversation content>")
      } else {
        value = redactShortLabelledContent(content, in: value)
      }
    }
    return value
  }

  private static func redactShortLabelledContent(
    _ content: String,
    in value: String
  ) -> String {
    let escaped = NSRegularExpression.escapedPattern(for: content)
    let pattern =
      #"(?i)\b(question|prompt|input|content)\s*[:=]\s*"# + escaped
      + #"(?=$|[\s,;])"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      return value
    }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return expression.stringByReplacingMatches(
      in: value,
      range: range,
      withTemplate: "$1=<redacted conversation content>")
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
  var userMessage: String
  var diagnostic: String
  var context: [String: String]

  private init(
    category: DiagnosticEvent.Category,
    code: String,
    summary: String,
    userMessage: String,
    diagnostic: String,
    context: [String: String]
  ) {
    self.category = category
    self.code = code
    self.summary = summary
    self.userMessage = userMessage
    self.diagnostic = diagnostic
    self.context = context
  }

  init(stage: PipelineDiagnosticStage, telemetry: TurnTelemetry) {
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
      "candidate_count": String(telemetry.candidates.count),
      "repair_attempts": String(telemetry.repairAttempts),
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
      let cancelled = timeoutStage == "cancelled"
      self.init(
        category: .pipeline,
        code: cancelled
          ? "pipeline_turn_cancelled" : "pipeline_deadline_exceeded",
        summary: cancelled
          ? "The on-device query turn was cancelled."
          : "The on-device query turn exceeded its deadline.",
        userMessage: cancelled
          ? "That answer was cancelled. Please try again."
          : "That answer took too long. Please try again.",
        diagnostic: candidateDiagnostic ?? fallbackDiagnostic,
        context: baseContext.merging(["timeout_stage": timeoutStage]) {
          current, _ in current
        })
    } else if [.rewrite, .gate, .narration].contains(stage),
      let terminalDiagnostic
    {
      self.init(
        category: .pipeline,
        code: "pipeline_foundation_model_failed",
        summary: "The on-device language service failed.",
        userMessage:
          "The on-device language service couldn’t finish this step. Try again.",
        diagnostic: terminalDiagnostic,
        context: baseContext)
    } else if lastFailure?.validationReport?.issue?.kind == .databaseUnavailable
    {
      self.init(
        category: .database,
        code: "pipeline_portfolio_database_unavailable",
        summary: "The bundled portfolio database is unavailable.",
        userMessage:
          "CREG’s portfolio data is unavailable. Reinstall CREG; if the problem continues, contact support.",
        diagnostic: candidateDiagnostic ?? fallbackDiagnostic,
        context: baseContext)
    } else if let lastFailure, lastFailure.sql == nil {
      self.init(
        category: .pipeline,
        code: "pipeline_model_generation_failed",
        summary: "The SQL model failed to generate a query.",
        userMessage:
          "The SQL model couldn’t run. Try again; if the problem continues, reinstall CREG.",
        diagnostic: candidateDiagnostic ?? fallbackDiagnostic,
        context: baseContext)
    } else if lastFailure != nil {
      self.init(
        category: .database,
        code: "pipeline_database_execution_failed",
        summary: "The generated portfolio query could not be executed.",
        userMessage:
          "CREG couldn’t run a valid portfolio query. Try rephrasing the question.",
        diagnostic: candidateDiagnostic ?? fallbackDiagnostic,
        context: baseContext)
    } else {
      self.init(
        category: .pipeline,
        code: "pipeline_unexpected_failure",
        summary: "The query pipeline ended unexpectedly.",
        userMessage: "CREG couldn’t finish that answer. Please try again.",
        diagnostic: fallbackDiagnostic,
        context: baseContext)
    }
  }
}

private func terminalCandidateRole(_ role: CandidateRole) -> String {
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

private func terminalMilliseconds(_ microseconds: Int64) -> String {
  String(format: "%.1f", Double(microseconds) / 1_000)
}
