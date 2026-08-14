/// Owns every model call — Apple FM and the bundled MLX model alike — and
/// guarantees no two inferences ever overlap, so active-inference peak memory
/// is max(FM, bundled), not the sum. See PRD §7.1.
///
/// Actors are reentrant, so a plain actor method would interleave awaited
/// operations; this instead chains each operation onto the previous one's
/// completion, giving strict arrival-order FIFO execution.
public actor InferenceSerializer {
  public enum SerializerError: Error, Sendable, Equatable {
    /// A cancelled model call has not returned yet. Starting another call
    /// would either overlap inference or wait behind work the user abandoned.
    case cancelledOperationStillRunning
  }

  public enum Operation: String, Sendable {
    case unspecified
    case modelPreparation = "model_preparation"
    case rewrite
    case gate
    case followUpSuggestion = "follow_up_suggestion"
    case sqlGeneration = "sql_generation"
    case narration
  }

  private var tail: Task<Void, Never>?
  private var pendingCount = 0
  private var nextOperationID = 0
  private var pendingOperationIDs: Set<Int> = []
  private var abandonedOperationIDs: Set<Int> = []
  private let diagnostics: DiagnosticsClient

  public init(diagnostics: DiagnosticsClient = .noop) {
    self.diagnostics = diagnostics
  }

  public func run<T: Sendable>(
    operation operationKind: Operation = .unspecified,
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    guard abandonedOperationIDs.isEmpty else {
      diagnostics.record(DiagnosticEvent(
        level: .error,
        category: .inference,
        code: "inference_rejected_while_cancelled_operation_runs",
        summary: "Inference was rejected because a cancelled model call is still running.",
        details:
          "The shared model slot remains occupied until the cancelled operation returns.",
        context: ["operation": operationKind.rawValue]))
      throw SerializerError.cancelledOperationStillRunning
    }

    let operationID = nextOperationID
    nextOperationID += 1
    pendingOperationIDs.insert(operationID)
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
      // Cancellation can arrive while this operation is queued. Never start
      // model work merely because the preceding FIFO entry eventually ended.
      try Task.checkCancellation()
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
      let result = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
        Task {
          await self.operationAbandoned(
            id: operationID,
            kind: operationKind)
        }
      }
      // A model operation can finish at the same instant its deadline cancels
      // the parent task. Do not report that race as a successful inference or
      // allow its value to escape after cancellation.
      try Task.checkCancellation()
      operationCompleted(
        id: operationID,
        kind: operationKind,
        error: nil,
        elapsedMicroseconds: waitStarted.duration(to: .now).microseconds)
      return result
    } catch {
      operationCompleted(
        id: operationID,
        kind: operationKind,
        error: error,
        elapsedMicroseconds: waitStarted.duration(to: .now).microseconds)
      throw error
    }
  }

  private func operationCompleted(
    id: Int,
    kind: Operation,
    error: (any Error)?,
    elapsedMicroseconds: Int64
  ) {
    pendingOperationIDs.remove(id)
    abandonedOperationIDs.remove(id)
    pendingCount -= 1
    if pendingCount == 0 { tail = nil }
    var context = [
      "operation": kind.rawValue,
      "remaining_operations": String(pendingCount),
      "total_elapsed_ms": Self.milliseconds(elapsedMicroseconds),
    ]
    if let error {
      context["error_type"] = String(reflecting: type(of: error))
      context["is_cancellation"] = String(error is CancellationError)
      let details =
        error is CancellationError
        ? "The serialized inference task was cancelled by its parent operation."
        : "error_type=\(String(reflecting: type(of: error)))"
      diagnostics.record(DiagnosticEvent(
        level: .error,
        category: .inference,
        code: "inference_failed",
        summary: "An inference operation failed and released the shared model slot.",
        details: details,
        context: context))
    } else {
      diagnostics.info(
        category: .inference,
        code: "inference_finished",
        summary: "An inference operation released the shared model slot.",
        context: context)
    }
  }

  private func operationAbandoned(id: Int, kind: Operation) {
    guard pendingOperationIDs.contains(id),
      abandonedOperationIDs.insert(id).inserted
    else { return }
    diagnostics.record(DiagnosticEvent(
      level: .error,
      category: .inference,
      code: "inference_cancelled_operation_still_running",
      summary: "A cancelled inference operation still owns the shared model slot.",
      details:
        "New inference will fail fast until the cancelled model call returns.",
      context: ["operation": kind.rawValue]))
  }

  private nonisolated static func milliseconds(_ microseconds: Int64) -> String {
    String(format: "%.1f", Double(microseconds) / 1_000)
  }
}
