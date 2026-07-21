import Foundation

extension QueryPipeline {
  /// A non-running pipeline used when startup configuration cannot be loaded.
  /// Friendly copy and developer diagnostics are deliberately kept separate.
  public static func unavailable(
    userMessage: String,
    diagnosticCode: String,
    diagnostic: String
  ) -> QueryPipeline {
    QueryPipeline { question, _ in
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
    QueryPipeline { question, history in
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

private enum PipelineDiagnosticPrivacy {
  static func redact(
    _ diagnostic: String,
    question: String,
    history: [ConversationTurn],
    telemetry: TurnTelemetry
  ) -> String {
    var value = diagnostic
    let conversationContent = Set(
      [question, telemetry.originalQuestion, telemetry.standaloneQuestion]
        + history.flatMap { [$0.question, $0.answerSummary] })
      .filter { !$0.isEmpty }
      .sorted { $0.count > $1.count }
    for content in conversationContent {
      value = value.replacingOccurrences(
        of: content,
        with: "<redacted conversation content>")
    }
    return value
  }
}

private enum PipelineDiagnosticStage: String, Sendable {
  case rewrite
  case gate
  case generation
  case database
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
    case .executionStarted:
      self = .database
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
    let lastFailure = telemetry.candidates.last(where: { $0.error != nil })
    let candidateDiagnostic = lastFailure?.error
    let terminalDiagnostic = telemetry.terminalError
    let fallbackDiagnostic =
      terminalDiagnostic
      ?? candidateDiagnostic
      ?? "The pipeline ended without an underlying diagnostic."
    let baseContext = [
      "stage": stage.rawValue,
      "candidate_count": String(telemetry.candidates.count),
      "repair_attempts": String(telemetry.repairAttempts),
    ]

    if [.rewrite, .gate, .narration].contains(stage),
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
    } else if candidateDiagnostic?.contains(
      "[portfolio_database_unavailable]") == true
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
