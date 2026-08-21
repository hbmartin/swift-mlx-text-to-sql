import CREGCore
import CREGData
import Foundation

struct FollowUpDeadlineExceeded: Error, Sendable {
  var stage: String

  var telemetryStage: String {
    switch stage {
    case "follow-up-generation": "generation"
    case "follow-up-validation": "validation"
    case "follow-up-execution": "execution"
    case "follow-up-grounding": "grounding"
    case "prepared-validation": "validation"
    default: stage
    }
  }
}

private final class FollowUpDeadlineRace<Value: Sendable>: @unchecked Sendable {
  private typealias Continuation = CheckedContinuation<Value, any Error>

  private let lock = NSLock()
  private var continuation: Continuation?
  private var result: Result<Value, any Error>?
  private var tasks: [Task<Void, Never>] = []

  /// `armed` defers the deadline clock: the timer task awaits it before
  /// sleeping, so time spent before the closure returns — e.g. FIFO queue
  /// wait ahead of serialized model work — does not consume the budget. The
  /// closure must be cancellation-responsive; it is cancelled when the
  /// operation settles first.
  func wait(
    seconds: Double,
    stage: String,
    armed: (@Sendable () async -> Void)? = nil,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        install(continuation)
        let operationTask = Task {
          do {
            resolve(.success(try await operation()))
          } catch {
            resolve(.failure(error))
          }
        }
        let deadlineTask = Task {
          do {
            await armed?()
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(seconds))
            resolve(.failure(FollowUpDeadlineExceeded(stage: stage)))
          } catch is CancellationError {
            return
          } catch {
            resolve(.failure(error))
          }
        }
        install(tasks: [operationTask, deadlineTask])
      }
    } onCancel: {
      resolve(.failure(CancellationError()))
    }
  }

  private func install(_ continuation: Continuation) {
    lock.lock()
    if let result {
      lock.unlock()
      continuation.resume(with: result)
    } else {
      self.continuation = continuation
      lock.unlock()
    }
  }

  private func install(tasks: [Task<Void, Never>]) {
    lock.lock()
    if result == nil {
      self.tasks = tasks
      lock.unlock()
    } else {
      lock.unlock()
      tasks.forEach { $0.cancel() }
    }
  }

  private func resolve(_ result: Result<Value, any Error>) {
    lock.lock()
    guard self.result == nil else {
      lock.unlock()
      return
    }
    self.result = result
    let continuation = self.continuation
    self.continuation = nil
    let tasks = self.tasks
    self.tasks = []
    lock.unlock()
    tasks.forEach { $0.cancel() }
    continuation?.resume(with: result)
  }
}

func withFollowUpDeadline<Value: Sendable>(
  seconds: Double,
  stage: String,
  operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
  guard seconds > 0 else { throw FollowUpDeadlineExceeded(stage: stage) }
  return try await FollowUpDeadlineRace<Value>().wait(
    seconds: seconds,
    stage: stage,
    operation: operation)
}

public struct ScopeVerdictDeadlineExceeded: Error, Sendable {}

/// Deadline for the app-level Scope Verdict FM call. The diagnosis runs
/// outside the turn deadlines by design, but still needs a bound so its
/// caller can stop waiting when Foundation Models stalls.
public func withScopeVerdictDeadline<Value: Sendable>(
  seconds: Double = 15,
  operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
  do {
    return try await withFollowUpDeadline(
      seconds: seconds,
      stage: "scope-verdict",
      operation: operation)
  } catch is FollowUpDeadlineExceeded {
    throw ScopeVerdictDeadlineExceeded()
  }
}

/// Runs a Scope Verdict through the shared inference FIFO while timing out
/// delivery to its caller. The deadline deliberately wraps `serializer.run`:
/// cancelling the serializer caller releases the UI task immediately, while
/// the serializer's raw queue entry remains chained until cancellation-
/// insensitive Foundation Models work really returns. A following FM or MLX
/// operation therefore cannot overlap the timed-out verdict.
///
/// The deadline budgets Foundation Models time, not queue time: its clock
/// arms only when the verdict acquires the shared slot, so a verdict queued
/// behind long-running model work still gets its full budget — the congested
/// pipeline is exactly the case the diagnosis exists for.
public func withSerializedScopeVerdictDeadline<Value: Sendable>(
  serializer: InferenceSerializer,
  seconds: Double = 15,
  operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
  guard seconds > 0 else { throw ScopeVerdictDeadlineExceeded() }
  let (slotAcquired, slotSignal) = AsyncStream<Void>.makeStream()
  do {
    return try await FollowUpDeadlineRace<Value>().wait(
      seconds: seconds,
      stage: "scope-verdict",
      armed: {
        for await _ in slotAcquired { break }
      },
      operation: {
        try await serializer.run(operation: .scopeVerdict) {
          slotSignal.yield()
          slotSignal.finish()
          return try await operation()
        }
      })
  } catch is FollowUpDeadlineExceeded {
    throw ScopeVerdictDeadlineExceeded()
  }
}
