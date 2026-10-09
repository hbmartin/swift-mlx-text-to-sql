import Darwin
import Foundation
import Testing

@testable import CREGFeatures

/// Opt-in, optimized benchmark of the state reads used by chat and notices.
/// CREG_CHROME_BENCHMARK=1 requires the allocation-counting host probe described
/// in HistoryRecoveryValidation.md. Fixture setup and printing are not measured.
@MainActor @Suite(.serialized)
struct ChromeProjectionPerformanceTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["CREG_CHROME_BENCHMARK"] == "1"))
  func compareReviewedAndSharedProjections() throws {
    typealias Begin = @convention(c) () -> Void
    typealias End = @convention(c) (UnsafeMutablePointer<UInt64>) -> UInt64
    let path = try #require(ProcessInfo.processInfo.environment["CREG_ALLOCATION_PROBE_PATH"])
    let handle = try #require(dlopen(path, RTLD_NOW))
    // Keep the host probe loaded until process exit; another allocator thread
    // may still be returning through its callback after the logger is restored.
    let begin = unsafeBitCast(try #require(dlsym(handle, "creg_alloc_begin")), to: Begin.self)
    let end = unsafeBitCast(try #require(dlsym(handle, "creg_alloc_end")), to: End.self)
    var state = AppFeature.State(debugModelIdentity: nil, launchBenchmarkQuestion: nil)
    state.conversations = .init(uniqueElements: (0..<1000).map { index in
      var row = ConversationSummary(id: UUID(), title: "Conversation \(index)", startedAt: Date(),
        lastActivityAt: Date(), latestMessagePreview: "Preview")
      row.isUnread = index == 999
      return row
    })
    let failure = FailurePresentation(code: "benchmark", title: "Failure", message: "Test", diagnostic: "Test")
    for index in 0..<10 { state.storeFailure(failure, owner: .historySummaries(UInt64(index))) }
    var oldTimes: [Double] = [], newTimes: [Double] = []
    var oldAllocations: [UInt64] = [], newAllocations: [UInt64] = []
    var oldBytes: [UInt64] = [], newBytes: [UInt64] = []
    let clock = ContinuousClock()
    for sample in 0..<8 {
      var oldSink = 0, newSink = 0
      var bytes: UInt64 = 0
      let oldStart = clock.now
      for _ in 0..<100 { oldSink += reviewedProjection(state) }
      let oldDuration = oldStart.duration(to: clock.now)
      begin()
      for _ in 0..<100 { oldSink += reviewedProjection(state) }
      let oldCount = end(&bytes)
      let oldRequestedBytes = bytes
      let newStart = clock.now
      for _ in 0..<100 { newSink += sharedProjection(state) }
      let newDuration = newStart.duration(to: clock.now)
      begin()
      for _ in 0..<100 { newSink += sharedProjection(state) }
      let newCount = end(&bytes)
      #expect(oldSink == newSink)
      if sample > 0 {
        oldTimes.append(milliseconds(oldDuration) / 100)
        newTimes.append(milliseconds(newDuration) / 100)
        oldAllocations.append(oldCount / 100); newAllocations.append(newCount / 100)
        oldBytes.append(oldRequestedBytes / 100); newBytes.append(bytes / 100)
      }
    }
    print(String(format: "CHROME_BENCHMARK rows=1000 reviewed_ms=%.5f shared_ms=%.5f reviewed_allocations=%llu shared_allocations=%llu reviewed_bytes=%llu shared_bytes=%llu",
      oldTimes.sorted()[3], newTimes.sorted()[3], oldAllocations.sorted()[3],
      newAllocations.sorted()[3], oldBytes.sorted()[3], newBytes.sorted()[3]))
    #expect(newAllocations.sorted()[3] > 0)
    #expect(newAllocations.sorted()[3] < oldAllocations.sorted()[3])
  }

  @inline(never) private func reviewedProjection(_ state: AppFeature.State) -> Int {
    // 630d471: separately build chrome for chat and its rendered notices sheet.
    var result = 0
    for _ in 0..<2 {
      result += state.visibleFailures.count
      result += state.presentedFailure == nil ? 0 : 1
      result += state.visibleConversations.contains { $0.isUnread } ? 1 : 0
    }
    return result
  }
  @inline(never) private func sharedProjection(_ state: AppFeature.State) -> Int {
    let failures = state.visibleFailures
    let unread = state.hasUnreadLiveConversation
    return 2 * (failures.count + (failures.last == nil ? 0 : 1) + (unread ? 1 : 0))
  }
  private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
  }
}
