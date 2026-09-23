import Foundation
import Testing

@testable import CREGCore
@testable import CREGInference

@Suite struct PreparationCoalescerTests {
  private enum ProbeError: Error { case firstAttempt }

  private actor Probe {
    var attempts = 0
    var failFirst = false

    init(failFirst: Bool = false) { self.failFirst = failFirst }

    func load() async throws -> Int {
      attempts += 1
      let attempt = attempts
      try await Task.sleep(for: .milliseconds(20))
      if failFirst && attempt == 1 { throw ProbeError.firstAttempt }
      return 42
    }
  }

  private actor SuspendedLoad {
    private var started: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Int, Never>?
    private var didStart = false
    private(set) var observedCancellation = false

    func waitUntilStarted() async {
      if didStart { return }
      await withCheckedContinuation { started = $0 }
    }

    func load() async -> Int {
      didStart = true
      started?.resume()
      let value = await withCheckedContinuation {
        (continuation: CheckedContinuation<Int, Never>) in
        release = continuation
      }
      observedCancellation = Task.isCancelled
      return value
    }

    func finish() { release?.resume(returning: 42) }
  }

  @Test func concurrentPreparationCoalescesAndFailureCanRetry() async throws {
    let probe = Probe()
    let coalescer = PreparationCoalescer<Int>()
    let values = try await withThrowingTaskGroup(of: Int.self) { group in
      for _ in 0..<5 {
        group.addTask {
          try await coalescer.value { try await probe.load() }
        }
      }
      return try await group.reduce(into: []) { $0.append($1) }
    }
    #expect(values == [42, 42, 42, 42, 42])
    #expect(await probe.attempts == 1)

    let retryProbe = Probe(failFirst: true)
    let retryCoalescer = PreparationCoalescer<Int>()
    await #expect(throws: ProbeError.firstAttempt) {
      _ = try await retryCoalescer.value { try await retryProbe.load() }
    }
    #expect(
      try await retryCoalescer.value { try await retryProbe.load() } == 42)
    #expect(await retryProbe.attempts == 2)
  }

  @Test func completedAfterCancellationLoadIsNotCached() async throws {
    let gate = SuspendedLoad()
    let coalescer = PreparationCoalescer<Int>()
    let caller = Task { try await coalescer.value { await gate.load() } }
    await gate.waitUntilStarted()
    caller.cancel()
    await gate.finish()
    await #expect(throws: CancellationError.self) { _ = try await caller.value }
    #expect(await gate.observedCancellation)
    #expect(try await coalescer.value { 43 } == 43)
  }
}
