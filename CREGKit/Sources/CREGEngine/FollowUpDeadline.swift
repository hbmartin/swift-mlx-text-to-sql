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

  func wait(
    seconds: Double,
    stage: String,
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
