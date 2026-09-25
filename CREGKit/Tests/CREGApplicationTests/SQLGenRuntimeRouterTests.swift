import CREGCore
import Foundation
import Testing
@testable import CREGApplication

private actor HeldLoad {
  private var continuation: CheckedContinuation<Void, Never>?
  private var startedContinuation: CheckedContinuation<Void, Never>?
  private var started = false

  func wait() async {
    started = true
    startedContinuation?.resume()
    startedContinuation = nil
    await withCheckedContinuation { continuation = $0 }
  }

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { startedContinuation = $0 }
  }

  func release() {
    continuation?.resume()
    continuation = nil
    started = false
  }
}

@Suite struct SQLGenRuntimeRouterTests {
  @Test func cancellationRetainsOneLoadedClientForResumption() async throws {
    let load = HeldLoad()
    let creations = MutexCounter()
    let client = SQLGenClient(
      prepare: {
        await load.wait()
      },
      schemaPrompt: { "schema" },
      generate: { _ in throw CancellationError() })
    let router = SQLGenRuntimeRouter(
      evaluated: {
        creations.increment()
        return client
      },
      compatibility: { client })

    let first = Task { try await router.prepare(.evaluated) }
    await load.waitUntilStarted()
    first.cancel()
    await load.release()
    do {
      _ = try await first.value
      Issue.record("Cancelled preparation unexpectedly succeeded")
    } catch is CancellationError {
      // The client remains retained, but generation stays gated.
    }
    let second = Task { try await router.prepare(.evaluated) }
    await load.waitUntilStarted()
    await load.release()
    _ = try await second.value
    #expect(creations.value == 1)
  }
}

private final class MutexCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}
