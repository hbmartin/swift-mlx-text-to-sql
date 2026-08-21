import AutoTableCharts
import CREGEngine
import ComposableArchitecture
import Foundation

/// The one app-owned chart analysis service. Its analyzer owns all reusable
/// snapshots, analyses, and prepared charts for CREG.
struct CREGChartAnalysisClient: Sendable {
  static let configuration = AutoChartAnalyzerConfiguration(
    tables: .init(maximumEntries: 8),
    analyses: .init(maximumEntries: 64),
    preparedCharts: .init(maximumEntries: 16),
    maximumRetainedCost: 32 * 1_024 * 1_024)

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
          resultFingerprint: resultFingerprint, sql: sql))
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
    snapshots.removeAll()
    await analyzer.trim(to: .minimum)
  }

  func removeAll() async {
    snapshots.removeAll()
    await analyzer.removeAll()
  }

  var cacheStatistics: AutoChartCacheStatistics {
    get async { await analyzer.cacheStatistics }
  }
}

/// LRU snapshots of finished analyses keyed by chart-data identity. A
/// revision mismatch (same message, different result bytes or SQL) misses
/// rather than serving a stale analysis.
final class ChartAnalysisSnapshotStore: @unchecked Sendable {
  private struct Entry {
    var revision: String
    var analysis: AutoChartAnalysis<Int>
  }

  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
  private var recency: [String] = []
  private let capacity: Int

  init(capacity: Int = 24) {
    self.capacity = capacity
  }

  func analysis(
    identity: String, revision: String
  ) -> AutoChartAnalysis<Int>? {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = entries[identity], entry.revision == revision else {
      return nil
    }
    recency.removeAll { $0 == identity }
    recency.append(identity)
    return entry.analysis
  }

  func store(
    _ analysis: AutoChartAnalysis<Int>,
    identity: String,
    revision: String
  ) {
    lock.lock()
    defer { lock.unlock() }
    entries[identity] = Entry(revision: revision, analysis: analysis)
    recency.removeAll { $0 == identity }
    recency.append(identity)
    while recency.count > capacity {
      entries[recency.removeFirst()] = nil
    }
  }

  func removeAll() {
    lock.lock()
    defer { lock.unlock() }
    entries.removeAll()
    recency.removeAll()
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
    analyzer: AutoChartAnalyzer(configuration: .uncached))
}

extension DependencyValues {
  var chartAnalysis: CREGChartAnalysisClient {
    get { self[CREGChartAnalysisClient.self] }
    set { self[CREGChartAnalysisClient.self] = newValue }
  }
}
