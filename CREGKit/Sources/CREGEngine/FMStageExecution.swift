import CREGCore
import Foundation

/// Runs one Foundation-Model-backed pipeline stage with the shared
/// degradation ladder: when the FM is available, run the live call through
/// the serializer under the stage deadline; rethrow deadline and cancellation
/// errors untouched; on any other error, degrade to the deterministic
/// `FMClient.fallback()` only when availability actually flipped mid-stage —
/// a genuine FM error under stable availability rethrows (ADR 0011).
///
/// `perform` receives whichever client the ladder selected, so each stage
/// states its FM call once. Only the live call runs under the deadline and
/// the serializer; the fallback client is deterministic local work.
func runFMStage<Value: Sendable>(
  fm: FMClient,
  serializer: InferenceSerializer,
  operation: InferenceSerializer.Operation,
  deadlineSeconds: Double,
  stage: String,
  perform: @escaping @Sendable (FMClient) async throws -> Value
) async throws -> (value: Value, usedFM: Bool) {
  guard fm.availability() == .available else {
    return (try await perform(.fallback()), false)
  }
  do {
    let value = try await withPipelineDeadline(
      seconds: deadlineSeconds,
      stage: stage
    ) {
      try await serializer.run(operation: operation) {
        try await perform(fm)
      }
    }
    return (value, true)
  } catch {
    if error is PipelineDeadlineExceeded || error is CancellationError {
      throw error
    }
    guard fm.availability() != .available else { throw error }
    return (try await perform(.fallback()), false)
  }
}
