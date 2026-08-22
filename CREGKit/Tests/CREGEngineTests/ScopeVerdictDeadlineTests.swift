import CREGCore
import Foundation
import Testing

@testable import CREGEngine

@Suite struct ScopeVerdictDeadlineTests {
  @Test func timedOutVerdictRetainsFIFOOwnershipUntilModelWorkReturns() async throws {
    let diagnostics = ScopeDeadlineDiagnosticRecorder()
    let serializer = InferenceSerializer(diagnostics: diagnostics.client)
    let verdictGate = CancellationInsensitiveScopeVerdictGate()
    let nextStarted = ScopeDeadlineFlag()

    let verdict = Task {
      try await withSerializedScopeVerdictDeadline(
        serializer: serializer,
        seconds: 0.01
      ) {
        await verdictGate.holdUntilReleased()
        return 1
      }
    }
    await verdictGate.waitUntilStarted()

    await #expect(throws: ScopeVerdictDeadlineExceeded.self) {
      _ = try await verdict.value
    }
    diagnostics.discardRecordedEvents()

    let next = Task {
      try await serializer.run(operation: .sqlGeneration) {
        await nextStarted.set()
        return 2
      }
    }
    let disposition = await diagnostics.waitForAny(
      ["inference_queued", "inference_started"])

    #expect(disposition == "inference_queued")
    #expect(await nextStarted.value == false)

    await verdictGate.release()
    #expect(try await next.value == 2)
    #expect(await nextStarted.value)
  }

  /// The deadline budgets Foundation Models time, not FIFO time: a verdict
  /// queued behind long-running model work must still get its full budget
  /// once the slot frees, because the congested pipeline is exactly the case
  /// the diagnosis exists for.
  @Test func queueWaitDoesNotConsumeTheVerdictBudget() async throws {
    let diagnostics = ScopeDeadlineDiagnosticRecorder()
    let serializer = InferenceSerializer(diagnostics: diagnostics.client)
    let blockerGate = CancellationInsensitiveScopeVerdictGate()

    let blocker = Task {
      try await serializer.run(operation: .sqlGeneration) {
        await blockerGate.holdUntilReleased()
        return 1
      }
    }
    await blockerGate.waitUntilStarted()

    let verdict = Task {
      try await withSerializedScopeVerdictDeadline(
        serializer: serializer,
        seconds: 0.05
      ) { 2 }
    }
    _ = await diagnostics.waitForAny(["inference_queued"])
    // Hold the slot for several multiples of the verdict deadline; an
    // enqueue-anchored clock would have expired the verdict long before the
    // release.
    try await Task.sleep(for: .seconds(0.25))
    await blockerGate.release()

    #expect(try await verdict.value == 2)
    #expect(try await blocker.value == 1)
  }
}

private actor ScopeDeadlineFlag {
  var value = false

  func set() { value = true }
}

private actor CancellationInsensitiveScopeVerdictGate {
  private var started = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func holdUntilReleased() async {
    started = true
    let waiters = startWaiters
    startWaiters.removeAll()
    waiters.forEach { $0.resume() }
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

private final class ScopeDeadlineDiagnosticRecorder: @unchecked Sendable {
  private struct Waiter {
    var codes: Set<String>
    var continuation: CheckedContinuation<String, Never>
  }

  private let lock = NSLock()
  private var events: [String] = []
  private var waiters: [Waiter] = []

  var client: DiagnosticsClient {
    DiagnosticsClient { [weak self] event in
      self?.record(event.code)
    }
  }

  func discardRecordedEvents() {
    lock.lock()
    events.removeAll()
    lock.unlock()
  }

  func waitForAny(_ codes: Set<String>) async -> String {
    await withCheckedContinuation { continuation in
      lock.lock()
      if let event = events.first(where: codes.contains) {
        lock.unlock()
        continuation.resume(returning: event)
      } else {
        waiters.append(Waiter(codes: codes, continuation: continuation))
        lock.unlock()
      }
    }
  }

  private func record(_ code: String) {
    lock.lock()
    events.append(code)
    var resumed: [CheckedContinuation<String, Never>] = []
    waiters.removeAll { waiter in
      guard waiter.codes.contains(code) else { return false }
      resumed.append(waiter.continuation)
      return true
    }
    lock.unlock()
    resumed.forEach { $0.resume(returning: code) }
  }
}
