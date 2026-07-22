/// Owns every model call — Apple FM and the bundled MLX model alike — and
/// guarantees no two inferences ever overlap, so active-inference peak memory
/// is max(FM, bundled), not the sum. See PRD §7.1.
///
/// Actors are reentrant, so a plain actor method would interleave awaited
/// operations; this instead chains each operation onto the previous one's
/// completion, giving strict arrival-order FIFO execution.
public actor InferenceSerializer {
  public enum Operation: String, Sendable {
    case unspecified
    case modelPreparation = "model_preparation"
    case rewrite
    case gate
    case sqlGeneration = "sql_generation"
    case narration
  }

  private var tail: Task<Void, Never>?
  private var pendingCount = 0
  private let diagnostics: DiagnosticsClient

  public init(diagnostics: DiagnosticsClient = .noop) {
    self.diagnostics = diagnostics
  }

  public func run<T: Sendable>(
    operation operationKind: Operation = .unspecified,
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    let previous = tail
    let queuedAhead = pendingCount
    pendingCount += 1
    let waitStarted = ContinuousClock.now
    if queuedAhead > 0 {
      diagnostics.info(
        category: .inference,
        code: "inference_queued",
        summary: "An inference operation is waiting for the shared model slot.",
        context: [
          "operation": operationKind.rawValue,
          "queued_ahead": String(queuedAhead),
        ])
    }
    let task = Task<T, Error> {
      await previous?.value
      let waitMicroseconds = waitStarted.duration(to: .now).microseconds
      self.diagnostics.info(
        category: .inference,
        code: "inference_started",
        summary: "An inference operation acquired the shared model slot.",
        context: [
          "operation": operationKind.rawValue,
          "wait_ms": Self.milliseconds(waitMicroseconds),
        ])
      return try await operation()
    }
    tail = Task { _ = try? await task.value }
    do {
      let result = try await task.value
      operationCompleted(
        kind: operationKind,
        succeeded: true,
        elapsedMicroseconds: waitStarted.duration(to: .now).microseconds)
      return result
    } catch {
      operationCompleted(
        kind: operationKind,
        succeeded: false,
        elapsedMicroseconds: waitStarted.duration(to: .now).microseconds)
      throw error
    }
  }

  private func operationCompleted(
    kind: Operation,
    succeeded: Bool,
    elapsedMicroseconds: Int64
  ) {
    pendingCount -= 1
    if pendingCount == 0 { tail = nil }
    let context = [
      "operation": kind.rawValue,
      "remaining_operations": String(pendingCount),
      "total_elapsed_ms": Self.milliseconds(elapsedMicroseconds),
    ]
    if succeeded {
      diagnostics.info(
        category: .inference,
        code: "inference_finished",
        summary: "An inference operation released the shared model slot.",
        context: context)
    } else {
      diagnostics.record(DiagnosticEvent(
        level: .error,
        category: .inference,
        code: "inference_failed",
        summary: "An inference operation failed and released the shared model slot.",
        context: context))
    }
  }

  private nonisolated static func milliseconds(_ microseconds: Int64) -> String {
    String(format: "%.1f", Double(microseconds) / 1_000)
  }
}
