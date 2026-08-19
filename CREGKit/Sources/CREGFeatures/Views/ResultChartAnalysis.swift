import AutoTableCharts
import CREGEngine
import ComposableArchitecture
import SwiftUI

// MARK: - Rendering cache budget

/// CREG's process-wide limits for the prepared rendering data AutoTableCharts
/// retains behind `AutoChartView`.
///
/// The package defaults to 32 MiB for each of its two layers. CREG charts run
/// on a device that already holds a multi-gigabyte model resident, and every
/// result it can chart is capped at `DatabaseClient.defaultRowCap` rows, so
/// halving each layer still admits the widest table in the schema catalog with
/// room to spare while capping the worst case at 32 MiB rather than 64 MiB.
enum CREGChartRenderCache {
  static let configuration = AutoChartRenderCacheConfiguration(
    maximumTableEntries: 8,
    maximumTableCost: 16 * 1_024 * 1_024,
    maximumRenderEntries: 16,
    maximumRenderCost: 16 * 1_024 * 1_024)

  /// Applies `configuration` the first time CREG prepares a chart.
  ///
  /// The package asks hosts to configure at startup so every chart in the
  /// process sees the same limits. Every `AutoChartView` CREG builds renders a
  /// table that came from a `ResultChartAnalysis`, so applying it there is
  /// ordered before the first cached render without depending on an app
  /// lifecycle the previews and tests don't have.
  static func applyOnce() {
    _ = isApplied
  }

  /// Releases the package's retained snapshots and prepared results.
  ///
  /// The package clears itself on a UIKit memory warning. This covers the
  /// paths it cannot see: CREG dropping every analysis of its own.
  static func releasePrepared() {
    AutoChartRenderCache.removeAll()
  }

  private static let isApplied: Bool = {
    AutoChartRenderCache.configure(configuration)
    return true
  }()
}

// MARK: - Inline preview

@MainActor
final class ResultChartAnalysis {
  let table: CREGChartTable
  let recommendations: [AutoChartRecommendation]

  init(
    result: QueryResult,
    sql: String,
    question: String?,
    resultFingerprint: String? = nil,
    dataIdentity: String? = nil
  ) {
    CREGChartRenderCache.applyOnce()
    let chart = CREGChartAdapter.recommendations(
      result: result,
      sql: sql,
      question: question,
      resultFingerprint: resultFingerprint,
      dataIdentity: dataIdentity)
    table = chart.table
    recommendations = chart.set.chartRecommendations
  }
}

@MainActor
enum ResultPreviewChartCache {
  private struct Entry {
    var resultFingerprint: String
    var sql: String
    var question: String?
    var analysis: ResultChartAnalysis
  }

  private static let limit = 64
  private static var entries: [UUID: Entry] = [:]
  private static var recency: [UUID] = []

  static func analysis(
    messageID: UUID,
    resultFingerprint: String,
    result: QueryResult,
    sql: String,
    question: String?
  ) -> ResultChartAnalysis {
    if let entry = entries[messageID],
      entry.resultFingerprint == resultFingerprint,
      entry.sql == sql,
      entry.question == question
    {
      markRecent(messageID)
      return entry.analysis
    }
    let analysis = ResultChartAnalysis(
      result: result,
      sql: sql,
      question: question,
      resultFingerprint: resultFingerprint,
      dataIdentity: "CREG.Result.v1:\(messageID.uuidString.lowercased())")
    entries[messageID] = Entry(
      resultFingerprint: resultFingerprint,
      sql: sql,
      question: question,
      analysis: analysis)
    markRecent(messageID)
    while recency.count > limit {
      entries[recency.removeFirst()] = nil
    }
    return analysis
  }

  static func removeAll() {
    entries.removeAll()
    recency.removeAll()
    // Every prepared render the package still holds was keyed on a table these
    // analyses owned, so it is unreachable once they are gone.
    CREGChartRenderCache.releasePrepared()
  }

  private static func markRecent(_ messageID: UUID) {
    recency.removeAll { $0 == messageID }
    recency.append(messageID)
  }
}
