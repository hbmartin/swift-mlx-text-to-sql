import AutoTableCharts
import Foundation

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
