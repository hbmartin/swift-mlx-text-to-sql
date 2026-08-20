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
    case scopeVerdict = "scope_verdict"
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
    let callerResultRelay = InferenceOneShotRelay<Result<T, any Error>>()
    let callerDispositionRelay = InferenceOneShotRelay<(any Error)?>()
    let task = Task<InferenceRawCompletion<T>, Never> {
      let outcome: Result<T, any Error>
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
        outcome = .success(result)
      } catch {
        outcome = .failure(error)
      }
      let elapsedMicroseconds = waitStarted.duration(to: .now).microseconds
      let remainingOperations = self.operationReleased(id: operationID)
      let completion = InferenceRawCompletion(
        result: outcome,
        remainingOperations: remainingOperations,
        elapsedMicroseconds: elapsedMicroseconds)
      callerResultRelay.resolve(outcome)
      return completion
    }
    // FIFO ownership ends with the raw model operation. Diagnostics may still
    // wait for the caller's cancellation decision, but that must not keep the
    // now-idle model slot from advancing.
    tail = Task { _ = await task.value }
    let diagnosticsTask = Task {
      let completion = await task.value
      let callerError = await callerDispositionRelay.value()
      let reportedError: (any Error)?
      switch completion.result {
      case .failure(let operationError):
        // A genuine model failure remains primary even when parent
        // cancellation races its delivery.
        reportedError = operationError
      case .success:
        reportedError = callerError
      }
      self.reportOperationCompletion(
        kind: operationKind,
        error: reportedError,
        remainingOperations: completion.remainingOperations,
        elapsedMicroseconds: completion.elapsedMicroseconds)
    }
    do {
      let result = try await withTaskCancellationHandler {
        try await callerResultRelay.value().get()
      } onCancel: {
        task.cancel()
        let cancellation = CancellationError()
        callerResultRelay.resolve(.failure(cancellation))
        callerDispositionRelay.resolve(cancellation)
        Task {
          await self.operationAbandoned(
            id: operationID,
            kind: operationKind)
        }
      }
      // A model operation can finish at the same instant its deadline cancels
      // the parent task. The caller decides the reported outcome so a rejected
      // value is never diagnosed as a successful inference.
      try Task.checkCancellation()
      callerDispositionRelay.resolve(nil)
      await diagnosticsTask.value
      return result
    } catch {
      callerDispositionRelay.resolve(error)
      // Ordinary completion keeps the historical contract that terminal
      // diagnostics are observable when `run` returns. A cancelled caller must
      // still be released immediately when model work ignores cancellation;
      // its eventual diagnostic is emitted by `diagnosticsTask` after the raw
      // operation finishes.
      if !Task.isCancelled {
        await diagnosticsTask.value
      }
      throw error
    }
  }

  private func operationReleased(
    id: Int
  ) -> Int {
    pendingOperationIDs.remove(id)
    if activeOperationID == id { activeOperationID = nil }
    pendingCount -= 1
    if pendingCount == 0 { tail = nil }
    return pendingCount
  }

  private func reportOperationCompletion(
    kind: Operation,
    error: (any Error)?,
    remainingOperations: Int,
    elapsedMicroseconds: Int64
  ) {
    var context = [
      "operation": kind.rawValue,
      "remaining_operations": String(remainingOperations),
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

private struct InferenceRawCompletion<Value: Sendable>: Sendable {
  var result: Result<Value, any Error>
  var remainingOperations: Int
  var elapsedMicroseconds: Int64
}

/// A lock-backed one-shot value used for raw completion, caller delivery, and
/// caller disposition without duplicating three subtly different state
/// machines. The first resolver wins and the value may be awaited once.
private final class InferenceOneShotRelay<Value: Sendable>: @unchecked Sendable {
  private enum State {
    case pending
    case waiting(CheckedContinuation<Value, Never>)
    case resolved(Value)
  }

  private let lock = NSLock()
  private var state: State = .pending

  func value() async -> Value {
    await withCheckedContinuation { continuation in
      var immediate: State?
      lock.lock()
      switch state {
      case .pending:
        state = .waiting(continuation)
      case .resolved(let value):
        immediate = .resolved(value)
      case .waiting:
        preconditionFailure("Inference relay may only be awaited once.")
      }
      lock.unlock()
      if case .resolved(let value) = immediate {
        continuation.resume(returning: value)
      }
    }
  }

  func resolve(_ value: Value) {
    var continuation: CheckedContinuation<Value, Never>?
    lock.lock()
    switch state {
    case .pending:
      state = .resolved(value)
    case .waiting(let waiting):
      state = .resolved(value)
      continuation = waiting
    case .resolved:
      break
    }
    lock.unlock()
    continuation?.resume(returning: value)
  }
}
