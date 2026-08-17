import CryptoKit
import Foundation
import Testing

@testable import CREGCore

@Suite struct InferenceSerializerTests {
  private enum ProbeError: Error, Sendable {
    case failed
  }

  @Test func operationsNeverOverlap() async throws {
    let serializer = InferenceSerializer()
    actor Overlap {
      var active = 0
      var maxActive = 0
      var order: [Int] = []
      func enter(_ id: Int) {
        active += 1
        maxActive = max(maxActive, active)
        order.append(id)
      }
      func exit() { active -= 1 }
    }
    let overlap = Overlap()
    await withTaskGroup(of: Void.self) { group in
      for id in 0..<5 {
        group.addTask {
          try? await serializer.run {
            await overlap.enter(id)
            try? await Task.sleep(for: .milliseconds(20))
            await overlap.exit()
          }
        }
      }
    }
    #expect(await overlap.maxActive == 1)
    #expect(await overlap.order.count == 5)
  }

  @Test func cancelledActiveInferenceIsNeverReportedAsFinished() async {
    let recorder = InferenceSerializerEventRecorder()
    let serializer = InferenceSerializer(diagnostics: recorder.client)
    let gate = CancellationInsensitiveInferenceGate()
    let operation = Task {
      try await serializer.run(operation: .rewrite) {
        await gate.holdUntilReleased()
        return 1
      }
    }
    await gate.waitUntilStarted()

    operation.cancel()
    await recorder.wait(for: "inference_cancelled_operation_still_running")
    await #expect(throws: CancellationError.self) {
      _ = try await operation.value
    }
    await gate.release()
    await recorder.wait(for: "inference_failed")

    #expect(!recorder.contains("inference_finished"))
  }

  @Test func modelFailureRemainsPrimaryWhenCallerCancellationRacesIt() async {
    let recorder = InferenceSerializerEventRecorder()
    let serializer = InferenceSerializer(diagnostics: recorder.client)
    let gate = CancellationInsensitiveInferenceGate()
    let operation = Task {
      try await serializer.run(operation: .rewrite) { () async throws -> Int in
        await gate.holdUntilReleased()
        throw ProbeError.failed
      }
    }
    await gate.waitUntilStarted()

    operation.cancel()
    await #expect(throws: CancellationError.self) {
      _ = try await operation.value
    }
    await gate.release()
    await recorder.wait(for: "inference_failed")

    let failure = recorder.event(for: "inference_failed")
    #expect(failure?.context["is_cancellation"] == "false")
    #expect(failure?.context["error_type"]?.contains("ProbeError") == true)
  }

  @Test func nextOperationWaitsWhileCancelledInferenceStillRuns() async throws {
    let recorder = InferenceSerializerEventRecorder()
    let serializer = InferenceSerializer(diagnostics: recorder.client)
    let gate = CancellationInsensitiveInferenceGate()
    let nextStarted = AsyncFlag()
    let first = Task {
      try await serializer.run(operation: .rewrite) {
        await gate.holdUntilReleased()
        return 1
      }
    }
    await gate.waitUntilStarted()

    first.cancel()
    await recorder.wait(for: "inference_cancelled_operation_still_running")
    #expect(recorder.contains("inference_cancelled_operation_still_running"))
    await #expect(throws: CancellationError.self) {
      _ = try await first.value
    }

    let next = Task {
      try await serializer.run(operation: .sqlGeneration) {
        await nextStarted.set()
        return 2
      }
    }
    await recorder.wait(for: "inference_queued")
    #expect(await nextStarted.value == false)

    await gate.release()
    #expect(try await next.value == 2)
    #expect(await nextStarted.value)
  }

  @Test func cancellingQueuedOperationDoesNotOccupyModelSlot() async throws {
    let recorder = InferenceSerializerEventRecorder()
    let serializer = InferenceSerializer(diagnostics: recorder.client)
    let gate = CancellationInsensitiveInferenceGate()
    let first = Task {
      try await serializer.run(operation: .rewrite) {
        await gate.holdUntilReleased()
        return 1
      }
    }
    await gate.waitUntilStarted()

    let queued = Task {
      try await serializer.run(operation: .gate) { 2 }
    }
    await recorder.wait(for: "inference_queued")
    queued.cancel()
    await recorder.wait(for: "inference_queued_operation_cancelled")
    #expect(!recorder.contains("inference_cancelled_operation_still_running"))
    await #expect(throws: CancellationError.self) {
      _ = try await queued.value
    }

    let next = Task {
      try await serializer.run(operation: .sqlGeneration) { 3 }
    }
    await gate.release()
    #expect(try await first.value == 1)
    #expect(try await next.value == 3)
  }
}
private actor AsyncFlag {
  var value = false

  func set() { value = true }
}

private actor CancellationInsensitiveInferenceGate {
  private var started = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func holdUntilReleased() async {
    started = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

private final class InferenceSerializerEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [DiagnosticEvent] = []
  private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

  var client: DiagnosticsClient {
    DiagnosticsClient { [weak self] event in
      self?.record(event)
    }
  }

  func contains(_ code: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return events.contains { $0.code == code }
  }

  func event(for code: String) -> DiagnosticEvent? {
    lock.lock()
    defer { lock.unlock() }
    return events.first { $0.code == code }
  }

  func wait(for code: String) async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if events.contains(where: { $0.code == code }) {
        lock.unlock()
        continuation.resume()
      } else {
        waiters[code, default: []].append(continuation)
        lock.unlock()
      }
    }
  }

  private func record(_ event: DiagnosticEvent) {
    lock.lock()
    events.append(event)
    let continuations = waiters.removeValue(forKey: event.code) ?? []
    lock.unlock()
    for continuation in continuations {
      continuation.resume()
    }
  }
}
