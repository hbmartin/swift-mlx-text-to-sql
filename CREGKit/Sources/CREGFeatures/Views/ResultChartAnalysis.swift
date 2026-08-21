import AutoTableCharts
import CREGEngine
import ComposableArchitecture
import Foundation

/// The one app-owned chart analysis service. Its fixed memory budget is split
/// between the analyzer's reusable work and synchronous first-frame snapshots.
struct CREGChartAnalysisClient: Sendable {
  /// One app-wide ceiling across both cache owners. The analyzer gets most
  /// of the budget; the synchronous warm-start LRU gets the remainder.
  static let maximumRetainedCost = 32 * 1_024 * 1_024
  static let snapshotMaximumRetainedCost = 8 * 1_024 * 1_024
  static let configuration = AutoChartAnalyzerConfiguration(
    tables: .init(maximumEntries: 8),
    analyses: .init(maximumEntries: 64),
    preparedCharts: .init(maximumEntries: 16),
    maximumRetainedCost:
      maximumRetainedCost - snapshotMaximumRetainedCost)

  static let live = CREGChartAnalysisClient(
    analyzer: AutoChartAnalyzer(configuration: configuration))

  let analyzer: AutoChartAnalyzer
  let snapshots: ChartAnalysisSnapshotStore

  init(
    analyzer: AutoChartAnalyzer,
    snapshots: ChartAnalysisSnapshotStore = ChartAnalysisSnapshotStore()
  ) {
    self.analyzer = analyzer
    self.snapshots = snapshots
  }

  func analyze(
    result: QueryResult,
    sql: String,
    question: String?,
    resultFingerprint: String? = nil,
    dataIdentity: String? = nil
  ) async throws -> AutoChartAnalysis<Int> {
    let input = try CREGChartAdapter.analysisInput(
      result: result,
      sql: sql,
      question: question,
      resultFingerprint: resultFingerprint,
      dataIdentity: dataIdentity)
    let analysis = try await analyzer.analyze(
      input.dataset, context: input.context)
    if let dataIdentity, let resultFingerprint {
      snapshots.store(
        analysis,
        identity: dataIdentity,
        revision: CREGChartAdapter.dataKeyRevision(
          resultFingerprint: resultFingerprint, sql: sql),
        retainedCost: Self.estimatedSnapshotCost(
          result: result, analysis: analysis))
    }
    return analysis
  }

  /// Synchronous read of a finished analysis, so a transcript cell re-created
  /// by the lazy list can render its chart on first frame instead of paying
  /// the dataset rebuild and analyzer round-trip again.
  func cachedAnalysis(
    resultFingerprint: String,
    sql: String,
    dataIdentity: String
  ) -> AutoChartAnalysis<Int>? {
    snapshots.analysis(
      identity: dataIdentity,
      revision: CREGChartAdapter.dataKeyRevision(
        resultFingerprint: resultFingerprint, sql: sql))
  }

  func trimToMinimum() async {
    snapshots.trimToMinimum()
    await analyzer.trim(to: .minimum)
  }

  func removeAll() async {
    snapshots.removeAll()
    await analyzer.removeAll()
  }

  var cacheStatistics: AutoChartCacheStatistics {
    get async { await analyzer.cacheStatistics }
  }

  var snapshotStatistics: ChartAnalysisSnapshotStore.Statistics {
    snapshots.statistics
  }

  /// A conservative retained-cost estimate for the graph reachable from a
  /// finished analysis. The package's exact prepared-source cost is private,
  /// so this mirrors its per-column/row/cell accounting and adds headroom for
  /// public analysis metadata and prepared marks.
  private static func estimatedSnapshotCost(
    result: QueryResult,
    analysis: AutoChartAnalysis<Int>
  ) -> Int {
    var cost = 1_024
    for column in result.columns {
      add(1_024, to: &cost)
      add(multiplied(column.utf8.count, by: 2), to: &cost)
    }
    for row in result.rows {
      add(256, to: &cost)
      for value in row {
        add(192, to: &cost)
        switch value {
        case .text(let text):
          add(multiplied(text.utf8.count, by: 2), to: &cost)
        case .blob(let data):
          add(multiplied(data.count, by: 2), to: &cost)
        case .null, .integer, .real:
          add(16, to: &cost)
        }
      }
    }
    add(multiplied(analysis.columnProfiles.count, by: 512), to: &cost)
    add(multiplied(analysis.diagnostics.count, by: 1_024), to: &cost)
    switch analysis.outcome {
    case .charts(let recommendations):
      add(multiplied(recommendations.count, by: 2_048), to: &cost)
    case .tableFallback:
      add(1_024, to: &cost)
    }
    add(
      multiplied(analysis.primaryChart?.marks.count ?? 0, by: 384),
      to: &cost)
    return cost
  }

  private static func add(_ amount: Int, to total: inout Int) {
    guard total != Int.max else { return }
    let (sum, overflow) = total.addingReportingOverflow(max(0, amount))
    total = overflow ? Int.max : sum
  }

  private static func multiplied(_ value: Int, by multiplier: Int) -> Int {
    let (product, overflow) = value.multipliedReportingOverflow(by: multiplier)
    return overflow ? Int.max : product
  }
}

/// LRU snapshots of finished analyses keyed by chart-data identity. A
/// revision mismatch (same message, different result bytes or SQL) misses
/// rather than serving a stale analysis.
final class ChartAnalysisSnapshotStore: @unchecked Sendable {
  struct Statistics: Equatable, Sendable {
    var entries = 0
    var retainedCost = 0
    var hits = 0
    var misses = 0
    var evictions = 0
  }

  static let uncached = ChartAnalysisSnapshotStore(
    capacity: 0, maximumRetainedCost: 0)

  private struct Entry {
    var revision: String
    var analysis: AutoChartAnalysis<Int>
    var retainedCost: Int
  }

  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
  private var recency: [String] = []
  private let capacity: Int
  private let maximumRetainedCost: Int
  private var retainedCost = 0
  private var hits = 0
  private var misses = 0
  private var evictions = 0

  init(
    capacity: Int = 24,
    maximumRetainedCost: Int = CREGChartAnalysisClient
      .snapshotMaximumRetainedCost
  ) {
    self.capacity = max(0, capacity)
    self.maximumRetainedCost = max(0, maximumRetainedCost)
  }

  func analysis(
    identity: String, revision: String
  ) -> AutoChartAnalysis<Int>? {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = entries[identity], entry.revision == revision else {
      misses += 1
      return nil
    }
    hits += 1
    recency.removeAll { $0 == identity }
    recency.append(identity)
    return entry.analysis
  }

  func store(
    _ analysis: AutoChartAnalysis<Int>,
    identity: String,
    revision: String,
    retainedCost: Int
  ) {
    lock.lock()
    defer { lock.unlock() }
    if let previous = entries.removeValue(forKey: identity) {
      self.retainedCost -= previous.retainedCost
      recency.removeAll { $0 == identity }
    }
    let retainedCost = max(0, retainedCost)
    guard
      capacity > 0,
      retainedCost <= maximumRetainedCost
    else { return }
    entries[identity] = Entry(
      revision: revision,
      analysis: analysis,
      retainedCost: retainedCost)
    self.retainedCost += retainedCost
    recency.removeAll { $0 == identity }
    recency.append(identity)
    while recency.count > capacity
      || self.retainedCost > maximumRetainedCost
    {
      evictLeastRecent()
    }
  }

  var statistics: Statistics {
    lock.lock()
    defer { lock.unlock() }
    return Statistics(
      entries: entries.count,
      retainedCost: retainedCost,
      hits: hits,
      misses: misses,
      evictions: evictions)
  }

  func trimToMinimum() {
    lock.lock()
    defer { lock.unlock() }
    evictions += entries.count
    entries.removeAll()
    recency.removeAll()
    retainedCost = 0
  }

  func removeAll() {
    lock.lock()
    defer { lock.unlock() }
    entries.removeAll()
    recency.removeAll()
    retainedCost = 0
    hits = 0
    misses = 0
    evictions = 0
  }

  private func evictLeastRecent() {
    guard !recency.isEmpty else { return }
    let identity = recency.removeFirst()
    guard let removed = entries.removeValue(forKey: identity) else { return }
    retainedCost -= removed.retainedCost
    evictions += 1
  }
}

/// The one chart-loading state machine shared by the inline Result Preview
/// and the full-screen Result Viewer. Views keep their own presentation
/// policy — what to select, when to fall back to the table, what to persist —
/// while this owns the analyze/prepare mechanics, so the two surfaces can
/// never render different charts for the same message. It warm-starts from
/// the client's snapshot of a finished analysis so a re-created transcript
/// cell renders its chart immediately instead of re-blanking into a spinner.
@MainActor
@Observable
final class ResultChartLoader {
  struct Request {
    var result: QueryResult
    var sql: String
    var question: String?
    var resultFingerprint: String
    var dataIdentity: String?

    /// Stable identity for the analyze task and the warm-start check.
    var key: String {
      [resultFingerprint, dataIdentity ?? "", sql, question ?? ""]
        .joined(separator: "|")
    }
  }

  enum Resolution {
    case resolved(AutoChartRecommendation)
    case unavailable
  }

  private let client: CREGChartAnalysisClient
  private(set) var analysis: AutoChartAnalysis<Int>?
  private(set) var preparedChart: AutoChartPreparedChart<Int>?
  private(set) var preparationFailed = false
  private var loadedKey: String?

  init(
    client: CREGChartAnalysisClient,
    warmStart request: Request?,
    preferredSpecificationID: AutoChartRecommendationID? = nil
  ) {
    self.client = client
    guard
      let request,
      let dataIdentity = request.dataIdentity,
      let cached = client.cachedAnalysis(
        resultFingerprint: request.resultFingerprint,
        sql: request.sql,
        dataIdentity: dataIdentity)
    else { return }
    analysis = cached
    loadedKey = request.key
    applyResolution(of: cached, preferred: preferredSpecificationID)
  }

  /// Analyzes (or reuses the warm-started analysis) and resolves the
  /// preferred specification. Returns nil when analysis failed or was
  /// cancelled; the caller applies its own policy to the resolution.
  func analyze(
    _ request: Request,
    preferredSpecificationID: AutoChartRecommendationID?
  ) async -> Resolution? {
    preparationFailed = false
    let loaded: AutoChartAnalysis<Int>
    if let analysis, loadedKey == request.key {
      loaded = analysis
    } else {
      preparedChart = nil
      do {
        loaded = try await client.analyze(
          result: request.result,
          sql: request.sql,
          question: request.question,
          resultFingerprint: request.resultFingerprint,
          dataIdentity: request.dataIdentity)
      } catch is CancellationError {
        return nil
      } catch {
        analysis = nil
        loadedKey = nil
        return nil
      }
      analysis = loaded
      loadedKey = request.key
    }
    return applyResolution(
      of: loaded, preferred: preferredSpecificationID)
  }

  /// Prepares the selected recommendation's chart, reusing the analysis's
  /// primary chart when it matches. Returns false only when preparation
  /// genuinely failed (not on cancellation); the caller applies its own
  /// fallback policy.
  func prepareSelected(
    _ recommendation: AutoChartRecommendation?
  ) async -> Bool {
    preparationFailed = false
    guard let analysis, let recommendation else {
      preparedChart = nil
      return true
    }
    if analysis.primaryChart?.recommendation.id == recommendation.id {
      preparedChart = analysis.primaryChart
      return true
    }
    preparedChart = nil
    do {
      preparedChart = try await analysis.prepare(recommendation.id)
      return true
    } catch is CancellationError {
      return true
    } catch {
      preparationFailed = true
      return false
    }
  }

  @discardableResult
  private func applyResolution(
    of loaded: AutoChartAnalysis<Int>,
    preferred: AutoChartRecommendationID?
  ) -> Resolution {
    switch loaded.resolve(preferred) {
    case .exact(let recommendation), .defaulted(let recommendation, _):
      preparedChart =
        loaded.primaryChart?.recommendation.id == recommendation.id
        ? loaded.primaryChart : nil
      return .resolved(recommendation)
    case .unavailable:
      preparedChart = nil
      return .unavailable
    }
  }
}

extension CREGChartAnalysisClient: DependencyKey {
  static let liveValue = CREGChartAnalysisClient.live
  static let testValue = CREGChartAnalysisClient(
    analyzer: AutoChartAnalyzer(configuration: .uncached),
    snapshots: .uncached)
}

extension DependencyValues {
  var chartAnalysis: CREGChartAnalysisClient {
    get { self[CREGChartAnalysisClient.self] }
    set { self[CREGChartAnalysisClient.self] = newValue }
  }
}
