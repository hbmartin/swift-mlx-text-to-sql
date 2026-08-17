import AutoTableCharts
import CREGEngine
import ComposableArchitecture
import SwiftUI

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
  }

  private static func markRecent(_ messageID: UUID) {
    recency.removeAll { $0 == messageID }
    recency.append(messageID)
  }
}
