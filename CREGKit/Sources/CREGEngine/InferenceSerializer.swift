import Foundation

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
    case followUpSuggestion = "follow_up_suggestion"
    case sqlGeneration = "sql_generation"
    case narration
  }

  private var tail: Task<Void, Never>?
  private var pendingCount = 0
  private var nextOperationID = 0
  private var pendingOperationIDs: Set<Int> = []
  /// The FIFO entry that has crossed the queue boundary and invoked model work.
  /// Queued entries deliberately never appear here.
  private var activeOperationID: Int?
  private let diagnostics: DiagnosticsClient

  public init(diagnostics: DiagnosticsClient = .noop) {
    self.diagnostics = diagnostics
  }

  public func run<T: Sendable>(
    operation operationKind: Operation = .unspecified,
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
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
    let resultRelay = InferenceResultRelay<T>()
    let task = Task<T, Error> {
      do {
        await previous?.value
        // The queue task remains chained for FIFO ownership, but its caller is
        // released independently when cancelled. Once the prior entry settles,
        // this check drops cancelled queued work without invoking the model.
        try Task.checkCancellation()
        self.activeOperationID = operationID
        let waitMicroseconds = waitStarted.duration(to: .now).microseconds
        self.diagnostics.info(
          category: .inference,
          code: "inference_started",
          summary: "An inference operation acquired the shared model slot.",
          context: [
            "operation": operationKind.rawValue,
            "wait_ms": Self.milliseconds(waitMicroseconds),
          ])
        let result = try await operation()
        try Task.checkCancellation()
        self.operationCompleted(
          id: operationID,
          kind: operationKind,
          error: nil,
          elapsedMicroseconds: waitStarted.duration(to: .now).microseconds)
        resultRelay.resolve(.success(result))
        return result
      } catch {
        self.operationCompleted(
          id: operationID,
          kind: operationKind,
          error: error,
          elapsedMicroseconds: waitStarted.duration(to: .now).microseconds)
        resultRelay.resolve(.failure(error))
        throw error
      }
    }
    tail = Task { _ = try? await task.value }
    return try await withTaskCancellationHandler {
      let result = try await resultRelay.value()
      try Task.checkCancellation()
      return result
    } onCancel: {
      task.cancel()
      resultRelay.cancel()
      Task {
        await self.operationAbandoned(
          id: operationID,
          kind: operationKind)
      }
    }
  }

  private func operationCompleted(
    id: Int,
    kind: Operation,
    error: (any Error)?,
    elapsedMicroseconds: Int64
  ) {
    pendingOperationIDs.remove(id)
    if activeOperationID == id { activeOperationID = nil }
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
      diagnostics.record(
        DiagnosticEvent(
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
    guard pendingOperationIDs.contains(id) else { return }
    guard activeOperationID == id else {
      diagnostics.info(
        category: .inference,
        code: "inference_queued_operation_cancelled",
        summary: "A queued inference operation was cancelled before acquiring the model slot.",
        context: ["operation": kind.rawValue])
      return
    }
    diagnostics.record(
      DiagnosticEvent(
        level: .error,
        category: .inference,
        code: "inference_cancelled_operation_still_running",
        summary: "A cancelled inference operation still owns the shared model slot.",
        details:
          "Queued inference remains serialized until the cancelled model call returns.",
        context: ["operation": kind.rawValue]))
  }

  private nonisolated static func milliseconds(_ microseconds: Int64) -> String {
    String(format: "%.1f", Double(microseconds) / 1_000)
  }
}

/// Lets a cancelled caller stop waiting immediately while the serializer's
/// private FIFO task remains chained behind any still-running model operation.
private final class InferenceResultRelay<Value: Sendable>: @unchecked Sendable {
  private enum State {
    case pending
    case waiting(CheckedContinuation<Value, any Error>)
    case resolved(Result<Value, any Error>)
    case cancelled
  }

  private let lock = NSLock()
  private var state: State = .pending

  func value() async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      var immediate: Result<Value, any Error>?
      lock.lock()
      switch state {
      case .pending:
        state = .waiting(continuation)
      case .resolved(let result):
        immediate = result
      case .cancelled:
        immediate = .failure(CancellationError())
      case .waiting:
        preconditionFailure("Inference result may only be awaited once.")
      }
      lock.unlock()
      if let immediate { continuation.resume(with: immediate) }
    }
  }

  func resolve(_ result: Result<Value, any Error>) {
    var continuation: CheckedContinuation<Value, any Error>?
    lock.lock()
    switch state {
    case .pending:
      state = .resolved(result)
    case .waiting(let waiting):
      state = .resolved(result)
      continuation = waiting
    case .cancelled, .resolved:
      break
    }
    lock.unlock()
    continuation?.resume(with: result)
  }

  func cancel() {
    var continuation: CheckedContinuation<Value, any Error>?
    lock.lock()
    switch state {
    case .pending:
      state = .cancelled
    case .waiting(let waiting):
      state = .cancelled
      continuation = waiting
    case .cancelled, .resolved:
      break
    }
    lock.unlock()
    continuation?.resume(throwing: CancellationError())
  }
}
