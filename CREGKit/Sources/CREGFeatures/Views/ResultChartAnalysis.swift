import AutoTableCharts
import AutoTableChartsUI
import CREGEngine
import ComposableArchitecture
import Foundation

/// The single app-owned package cache shared by independent preview and viewer sessions.
struct CREGChartAnalysisClient: Sendable {
  static let maximumRetainedCost = 32 * 1_024 * 1_024
  static let configuration = AutoChartAnalyzerConfiguration(
    tables: .init(maximumEntries: 8),
    analyses: .init(maximumEntries: 64),
    preparedCharts: .init(maximumEntries: 16),
    maximumRetainedCost: maximumRetainedCost)

  static let live = CREGChartAnalysisClient(
    cache: AutoChartCache(configuration: configuration))

  let cache: AutoChartCache
  let analyzer: AutoChartAnalyzer

  init(cache: AutoChartCache) {
    self.cache = cache
    self.analyzer = AutoChartAnalyzer(cache: cache)
  }

  @MainActor
  func makeSession() -> AutoChartSession<Int> {
    AutoChartSession(cache: cache)
  }

  func analyze(
    result: QueryResult,
    sql: String,
    question: String?,
    resultFingerprint: String? = nil,
    dataIdentity: String? = nil,
    preference: AutoChartPreference = .automatic,
    preparation: AutoChartPreparationStrategy = .preferredOrPrimary
  ) async throws -> AutoChartAnalysis<Int> {
    let input = try CREGChartAdapter.analysisInput(
      result: result,
      sql: sql,
      question: question,
      resultFingerprint: resultFingerprint,
      dataIdentity: dataIdentity)
    return try await analyzer.analyze(
      input.request,
      preference: preference,
      preparation: preparation)
  }

  func cachedAnalysis(
    for request: AutoChartRequest<Int>
  ) -> AutoChartAnalysis<Int>? {
    cache.completedAnalysis(for: request.id)
  }

  func trimToMinimum() async {
    await cache.trim(to: .minimum)
  }

  var cacheStatistics: AutoChartCacheStatistics {
    get async { await cache.statistics() }
  }
}

extension CREGChartAnalysisClient: DependencyKey {
  static let liveValue = CREGChartAnalysisClient.live
  static var testValue: CREGChartAnalysisClient {
    CREGChartAnalysisClient(cache: AutoChartCache(configuration: .uncached))
  }
}

extension DependencyValues {
  var chartAnalysis: CREGChartAnalysisClient {
    get { self[CREGChartAnalysisClient.self] }
    set { self[CREGChartAnalysisClient.self] = newValue }
  }
}

func recordChartFailure(
  _ failure: AutoChartFailure,
  diagnostics: DiagnosticsClient
) {
  diagnostics.record(
    DiagnosticEvent(
      level: .error,
      category: .presentation,
      code: failure.diagnosticID,
      summary: "Chart presentation failed.",
      details: failure.message,
      context: [
        // Compact UUID form remains a stable episode token without matching
        // the diagnostics scrubber's user-identifier UUID pattern.
        "episode_id": failure.episodeID.uuidString.lowercased()
          .replacingOccurrences(of: "-", with: ""),
        "stage": failure.stage.rawValue,
        "kind": failure.kind.rawValue,
      ]))
}
