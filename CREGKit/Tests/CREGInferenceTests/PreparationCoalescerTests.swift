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
}
