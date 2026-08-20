import CREGCore
import Foundation

extension QueryPipeline {
  /// Used when the production section of the model manifest is absent or
  /// invalid. The app remains loadable but cannot silently invent a model or
  /// generation configuration.
  public static func unavailable(message: String) -> QueryPipeline {
    QueryPipeline { question, _ in
      AsyncStream { continuation in
        var telemetry = TurnTelemetry(originalQuestion: question)
        telemetry.terminalError = message
        telemetry.failureReason = .pipelineUnavailable
        continuation.yield(.turnStarted(question: question))
        continuation.yield(
          .questionResolved(
            standaloneQuestion: question,
            rewriteApplied: false,
            usedFM: false,
            elapsedMicroseconds: 0))
        continuation.yield(
          .turnFinished(
            outcome: .failed(reason: .pipelineUnavailable),
            telemetry: telemetry))
        continuation.finish()
      }
    }
  }
}
