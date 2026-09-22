import Foundation
@_weakLinked import FoundationModels

/// A stable, payload-free classification of an Apple Foundation Models call.
/// The underlying framework errors can contain transcript details and must
/// not cross the diagnostic or persisted-telemetry boundary verbatim.
public struct FMCallFailure: Error, Sendable, Equatable {
  public enum Kind: String, Sendable, Equatable, Codable {
    case refusal
    case decoding
    case unavailable
    case contextExhausted
    case timedOut
    case unsupported
    case invalidOutput
    case session
    case unexpected
  }

  public var stage: String
  public var kind: Kind

  public init(stage: String, kind: Kind) {
    self.stage = stage
    self.kind = kind
  }

  @available(macOS 26.0, iOS 26.0, *)
  static func run<Value: Sendable>(
    stage: String,
    diagnostics: DiagnosticsClient,
    _ operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    do {
      return try await operation()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let failure = FMCallFailure(stage: stage, kind: classify(error))
      diagnostics.record(DiagnosticEvent(
        level: .error,
        category: .inference,
        code: "fm_stage_failed",
        summary: "A Foundation Models stage failed.",
        context: ["stage": stage, "kind": failure.kind.rawValue]))
      throw failure
    }
  }

  @available(macOS 26.0, iOS 26.0, *)
  private static func classify(_ error: any Error) -> Kind {
    if let failure = error as? FMCallFailure { return failure.kind }
    if error is FMOutputValidationError { return .invalidOutput }
    if #available(macOS 27.0, iOS 27.0, *) {
      if error is GeneratedContent.ParsingError { return .decoding }
      if error is SystemLanguageModel.Error { return .unavailable }
      if error is LanguageModelSession.Error { return .session }
      if let modelError = error as? LanguageModelError {
        switch modelError {
        case .refusal, .guardrailViolation: return .refusal
        case .contextSizeExceeded: return .contextExhausted
        case .timeout: return .timedOut
        case .unsupportedCapability, .unsupportedTranscriptContent,
          .unsupportedGenerationGuide, .unsupportedLanguageOrLocale:
          return .unsupported
        case .rateLimited: return .unavailable
        @unknown default: return .unexpected
        }
      }
    }
    return .unexpected
  }
}
