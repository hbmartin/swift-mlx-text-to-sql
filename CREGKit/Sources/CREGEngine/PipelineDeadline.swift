import CREGCore
import Foundation

struct PipelineDeadlineExceeded: Error, CustomStringConvertible, Sendable {
  var stage: String
  var limitSeconds: Double

  var description: String {
    let limitMilliseconds = max(0, limitSeconds) * 1_000
    return String(
      format:
        "pipeline deadline exceeded during %@ (deadline_ms=%.1f; cancellation cleanup may extend observed elapsed time)",
      stage, limitMilliseconds)
  }
}

func withPipelineDeadline<Value: Sendable>(
  seconds: Double,
  stage: String,
  operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
  guard seconds > 0 else {
    throw PipelineDeadlineExceeded(stage: stage, limitSeconds: seconds)
  }
  return try await withThrowingTaskGroup(of: Value.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: .seconds(seconds))
      throw PipelineDeadlineExceeded(stage: stage, limitSeconds: seconds)
    }
    defer { group.cancelAll() }
    guard let result = try await group.next() else {
      throw PipelineDeadlineExceeded(stage: stage, limitSeconds: seconds)
    }
    return result
  }
}
