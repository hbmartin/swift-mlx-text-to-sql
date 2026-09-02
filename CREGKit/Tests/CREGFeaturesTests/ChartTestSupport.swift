import AutoTableCharts
import Foundation
import Testing

@testable import CREGEngine
@testable import CREGFeatures

func chartTestRecommendationID(
  _ rawValue: String = "test-specification",
  policyVersion: Int = AutoTableCharts.recommendationPolicyVersion
) -> AutoChartRecommendationID {
  AutoChartRecommendationID(
    policyVersion: policyVersion,
    specificationID: AutoChartSpecificationID(rawValue: rawValue))
}

func chartTestAnswerMessage() -> ChatMessage {
  ChatMessage(
    id: UUID(), role: .assistant,
    body: .answer(
      result: QueryResult(
        columns: ["fund", "current_market_value"],
        rows: [[.text("Core"), .real(10)]]),
      narration: "Core is worth $10.",
      sql: "SELECT fund, SUM(value) AS current_market_value FROM properties GROUP BY fund",
      notice: nil),
    createdAt: Date(timeIntervalSince1970: 1))
}

func chartTestRequest(
  result: QueryResult = PreviewFixtures.fundValueResult,
  sql: String = StarterQueryID.portfolioValueByFundV1.sql,
  question: String? = StarterQueryID.portfolioValueByFundV1.question,
  resultFingerprint: String,
  dataIdentity: String? = "message-1"
) -> ResultChartLoader.Request {
  ResultChartLoader.Request(
    result: result,
    sql: sql,
    question: question,
    resultFingerprint: resultFingerprint,
    dataIdentity: dataIdentity)
}

func chartTestRecommendations(
  from analysis: AutoChartAnalysis<Int>
) -> [AutoChartRecommendation] {
  switch analysis.outcome {
  case .charts(let recommendations): recommendations
  case .tableFallback: []
  }
}

/// Two loaders sharing one analysis client, standing in for the inline preview
/// and the full-screen viewer of the same result.
@MainActor
func chartTestLoaderPair(
  client: CREGChartAnalysisClient,
  diagnostics: DiagnosticsClient,
  prepareChart: ResultChartLoader.PrepareChart? = nil
) -> (first: ResultChartLoader, viewer: ResultChartLoader) {
  let first = ResultChartLoader(
    client: client,
    diagnostics: diagnostics,
    warmStart: nil,
    prepareChart: prepareChart)
  let viewer = ResultChartLoader(
    client: client,
    diagnostics: diagnostics,
    warmStart: nil,
    prepareChart: prepareChart)
  return (first, viewer)
}

/// Analyzes `request`, resolves the fixture's first non-primary recommendation
/// (the one whose chart must be prepared rather than reused from the analysis),
/// and runs one preparation for it, as either chart surface does before a user
/// can act on the result. Returns that recommendation.
@MainActor
@discardableResult
func chartTestPrepareAlternativeRecommendation(
  on loader: ResultChartLoader,
  request: ResultChartLoader.Request
) async throws -> AutoChartRecommendation {
  _ = await loader.analyze(request, preferredSpecificationID: nil)
  let analysis = try #require(loader.analysis(for: request.key))
  let alternative = try #require(
    chartTestRecommendations(from: analysis).dropFirst().first)
  _ = loader.resolveLoadedRecommendation(
    for: request.key,
    preferredSpecificationID: alternative.id)
  await loader.prepareResolvedRecommendation(for: request.key)
  return alternative
}

enum PreferenceSaveTestError: Error, Sendable {
  case failed
}

final class PreferenceRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedConversationID: UUID?
  private var storedPreference: ResultPresentationPreference?
  private var storedWriteCount = 0

  func record(conversationID: UUID, message: ChatMessage) {
    lock.lock()
    storedConversationID = conversationID
    storedPreference = message.resultPresentation
    storedWriteCount += 1
    lock.unlock()
  }

  var conversationID: UUID? {
    lock.lock()
    defer { lock.unlock() }
    return storedConversationID
  }

  var preference: ResultPresentationPreference? {
    lock.lock()
    defer { lock.unlock() }
    return storedPreference
  }

  var writeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedWriteCount
  }
}
