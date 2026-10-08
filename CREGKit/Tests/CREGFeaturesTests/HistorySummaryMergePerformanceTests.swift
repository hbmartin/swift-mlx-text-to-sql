import ComposableArchitecture
import Foundation
import Testing

@testable import CREGFeatures

/// Opt-in benchmark: CREG_MERGE_BENCHMARK=1, release configuration.
/// Fixtures and setup are outside the timed interval; report medians, not limits.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)))
struct HistorySummaryMergePerformanceTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["CREG_MERGE_BENCHMARK"] == "1"),
    arguments: [1_000, 5_000, 10_000])
  func medianMergeTimings(rowCount: Int) {
    let rows = (0..<rowCount).map { index in
      ConversationSummary(
        id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!,
        title: "Conversation \(index)", startedAt: Date(timeIntervalSince1970: 0),
        lastActivityAt: Date(timeIntervalSince1970: Double(index)))
    }
    var fetched = rows
    for index in fetched.indices { fetched[index].messageCount = 2 }
    var legacy: [Double] = []
    var optimized: [Double] = []
    let clock = ContinuousClock()
    for sample in 0..<8 {
      var state = AppFeature.State(debugModelIdentity: nil, launchBenchmarkQuestion: nil)
      state.conversations = .init(uniqueElements: rows)
      state.historySummaryBaseline = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
      let oldStart = clock.now
      for summary in fetched {
        let current = state.conversations[id: summary.id]
        if let baseline = state.historySummaryBaseline[summary.id], current != baseline { continue }
        if state.historySummaryBaseline[summary.id] == nil, current != nil { continue }
        state.conversations[id: summary.id] = summary
      }
      state.conversations.sort { $0.lastActivityAt > $1.lastActivityAt }
      let oldDuration = oldStart.duration(to: clock.now)
      state.conversations = .init(uniqueElements: rows)
      let newStart = clock.now
      state.mergeHistorySummaries(fetched)
      let newDuration = newStart.duration(to: clock.now)
      #expect(state.conversations.count == rowCount)
      #expect(state.conversations.allSatisfy { $0.messageCount == 2 })
      if sample > 0 {
        legacy.append(milliseconds(oldDuration))
        optimized.append(milliseconds(newDuration))
      }
    }
    let oldMedian = legacy.sorted()[legacy.count / 2]
    let newMedian = optimized.sorted()[optimized.count / 2]
    print(
      String(
        format: "MERGE_BENCHMARK rows=%d legacy_ms=%.3f optimized_ms=%.3f speedup=%.2f",
        rowCount, oldMedian, newMedian, oldMedian / newMedian))
  }
  private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
  }
}
