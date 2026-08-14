import AutoTableCharts
import ComposableArchitecture
import Foundation
import Testing

@testable import CREGEngine
@testable import CREGFeatures

@Suite struct CREGChartAdapterTests {
  @Test func topLevelProjectionParsingHandlesCTEsAliasesAndNestedFunctions() {
    let projections = CREGChartAdapter.topLevelProjections(
      """
      WITH active AS (
        SELECT property_id, annual_base_rent
        FROM leases
        WHERE status = 'Active'
      )
      SELECT p.name AS property,
             SUM(COALESCE(a.annual_base_rent, 0)) AS annual_rent_roll,
             'from, inside a literal' AS note
      FROM active a
      JOIN properties p ON p.property_id = a.property_id
      GROUP BY p.name
      """)

    #expect(projections.count == 3)
    #expect(projections[0].contains("p.name AS property"))
    #expect(projections[1].contains("SUM(COALESCE"))
    #expect(projections[2].contains("from, inside a literal"))
    #expect(CREGChartAdapter.aggregate(in: projections[1]) == .sum)
  }

  @Test func schemaAndProjectionHintsPreserveIdentifiersUnitsDatesAndAggregates() {
    let result = QueryResult(
      columns: ["loan_id", "current_balance", "maturity_date"],
      rows: [[.integer(42), .real(1_250_000), .text("2027-03-15")]])
    let table = CREGChartTable(
      result: result,
      sql: "SELECT loan_id, SUM(current_balance), MAX(maturity_date) FROM loans",
      question: "What matures next?")

    #expect(table.chartColumns[0].hints.semanticType == .identifier)
    #expect(table.chartColumns[0].hints.aggregationSafety == .unsafe)
    #expect(table.chartColumns[1].hints.unit == .currency(code: "USD"))
    #expect(table.chartColumns[1].hints.aggregation == .sum)
    #expect(table.chartColumns[1].hints.aggregationSafety == .alreadyAggregated)
    #expect(table.chartColumns[2].hints.semanticType == .temporal)
    #expect(table.chartColumns[2].hints.role == .intervalEnd)
    #expect(table.chartRows[0].chartValue(for: table.chartColumns[2].id).dateValue != nil)

    let raw = CREGChartAdapter.hints(for: "unresolved_metric", projection: "metric")
    #expect(raw.aggregationSafety == .unknown)
  }

  @Test(arguments: [
    ("Show the trend over time", "SELECT period_end, noi FROM property_financials", AutoChartGoal.trend),
    ("Which properties are unusual outliers?", "SELECT name, value FROM properties", .outlier),
    ("How are value and balance related?", "SELECT value, balance FROM loans", .relationship),
    ("What share is in each fund?", "SELECT fund, value FROM holdings", .composition),
    ("Which leases expire next?", "SELECT expiration_date FROM leases", .range),
    ("Rank the top properties", "SELECT name, value FROM properties", .ranking),
  ])
  func typedGoalClassification(
    question: String, sql: String, expected: AutoChartGoal
  ) {
    #expect(CREGChartAdapter.goal(question: question, sql: sql) == expected)
  }

  @Test func allStarterQueriesProduceTheExpectedPrimaryFamily() throws {
    let fixtures: [(StarterQueryID, QueryResult, AutoChartFamily)] = [
      (
        .highestVacancyV1,
        QueryResult(
          columns: ["property", "vacancy_rate"],
          rows: [
            [.text("Harbor Point"), .real(0.14)],
            [.text("Meridian Plaza"), .real(0.09)],
            [.text("Eastgate"), .real(0.06)],
          ]),
        .bar
      ),
      (
        .rentRollByPropertyTypeV1,
        QueryResult(
          columns: ["property_type", "annual_rent_roll"],
          rows: [
            [.text("Office"), .real(8_400_000)],
            [.text("Industrial"), .real(6_100_000)],
          ]),
        .bar
      ),
      (
        .leaseExpirationsNextTwelveMonthsV1,
        QueryResult(
          columns: ["lease_id", "tenant", "property", "suite", "expiration_date", "status"],
          rows: [
            [.integer(1), .text("Atlas Data"), .text("Harbor Point"), .text("210"), .text("2026-10-01"), .text("Active")],
            [.integer(2), .text("Béa Café"), .text("Meridian Plaza"), .text("105"), .text("2027-01-15"), .text("Active")],
          ]),
        .range
      ),
      (
        .portfolioValueByFundV1,
        QueryResult(
          columns: ["fund", "current_market_value"],
          rows: [
            [.text("Core Fund I"), .real(412_500_000)],
            [.text("Value-Add II"), .real(268_900_000)],
          ]),
        .bar
      ),
      (
        .loanMaturitiesNextTwentyFourMonthsV1,
        QueryResult(
          columns: ["property", "lender", "current_balance", "maturity_date"],
          rows: [
            [.text("Harbor Point"), .text("Bay Bank"), .real(25_000_000), .text("2027-04-01")],
            [.text("Eastgate"), .text("Union Credit"), .real(18_500_000), .text("2028-02-15")],
          ]),
        .bubble
      ),
    ]

    for (starter, result, expectedFamily) in fixtures {
      let recommendation = try #require(
        CREGChartAdapter.recommendations(
          result: result,
          sql: starter.sql,
          question: starter.question
        ).set.chartRecommendations.first)
      #expect(
        recommendation.specification.family == expectedFamily,
        "\(starter.rawValue) recommended \(recommendation.specification.family)"
      )
    }
  }

  @Test func truncatedResultsSuppressCompositionAndFrequencyClaims() {
    let result = QueryResult(
      columns: ["property_type", "status", "annual_rent_roll"],
      rows: [
        [.text("Office"), .text("Active"), .real(5_000_000)],
        [.text("Industrial"), .text("Holdover"), .real(3_000_000)],
      ],
      isTruncated: true)
    let recommendations = CREGChartAdapter.recommendations(
      result: result,
      sql: "SELECT property_type, status, SUM(annual_base_rent) AS annual_rent_roll FROM leases GROUP BY property_type, status",
      question: "Show the rent roll breakdown"
    ).set.chartRecommendations
    let families = Set(recommendations.map(\.specification.family))

    #expect(!families.contains(.donut))
    #expect(!families.contains(.normalizedBar))
    #expect(!families.contains(.stackedBar))
    #expect(!families.contains(.heatmap))
    #expect(recommendations.allSatisfy { !$0.warnings.isEmpty })
  }

  @Test func exactSelectionMapsBackToOriginalRows() {
    let table = CREGChartTable(
      result: QueryResult(
        columns: ["property", "value"],
        rows: [
          [.text("A"), .integer(1)],
          [.text("B"), .integer(2)],
          [.text("C"), .integer(3)],
        ]),
      sql: "SELECT property, value FROM properties",
      question: nil)
    let selection = AutoChartSelection(
      sourceRowIDs: ["row-0", "row-2"],
      label: "Selected properties",
      valueDescription: "2 rows")

    #expect(table.sourceRowIndexes(for: selection) == [0, 2])
  }

  @Test func invalidStoredSpecificationFallsBackToCurrentTopRecommendation() throws {
    let result = QueryResult(
      columns: ["fund", "current_market_value"],
      rows: [[.text("Core"), .real(10)], [.text("Value-Add"), .real(8)]])
    let recommendations = CREGChartAdapter.recommendations(
      result: result,
      sql: StarterQueryID.portfolioValueByFundV1.sql,
      question: StarterQueryID.portfolioValueByFundV1.question
    ).set.chartRecommendations
    let top = try #require(recommendations.first)

    #expect(
      CREGChartAdapter.resolvedRecommendation(
        preferredID: "obsolete-policy|bar|missing",
        in: recommendations)?.id == top.id)
    #expect(
      CREGChartAdapter.resolvedRecommendation(
        preferredID: top.id,
        in: recommendations)?.id == top.id)
  }
}

@MainActor
@Suite struct ResultPresentationPersistenceTests {
  @Test func legacyMessageWithoutPreferenceDecodesAsAutomatic() throws {
    let message = Self.answerMessage()
    let encoded = try JSONEncoder().encode(message)
    var object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "resultPresentation")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(ChatMessage.self, from: legacyData)
    #expect(decoded.resultPresentation == nil)
  }

  @Test func preferenceRoundTripsAndSurvivesPreparedFinalization() throws {
    let preference = ResultPresentationPreference(
      mode: .chart, specificationID: "policy|bar|fund|value")
    var message = Self.answerMessage()
    message.resultPresentation = preference
    let decoded = try JSONDecoder().decode(
      ChatMessage.self, from: JSONEncoder().encode(message))
    #expect(decoded.resultPresentation == preference)

    let prepared = Self.preparedFollowUp()
    let provisional = ChatMessage(
      id: UUID(), role: .assistant,
      body: .preparedAnswer(prepared),
      createdAt: Date(timeIntervalSince1970: 2),
      resultPresentation: preference)
    #expect(
      provisional.finalizedInterruptedPreparedAnswer?.resultPresentation
        == preference)
  }

  @Test func reducerUpdatesAndPersistsTheMessagePreference() async {
    let message = Self.answerMessage()
    let preference = ResultPresentationPreference(
      mode: .table, specificationID: "policy|bar|fund|value")
    let recorder = PreferenceRecorder()
    var history = HistoryClient.noop()
    history.updateMessage = { conversationID, updated in
      recorder.record(conversationID: conversationID, message: updated)
    }
    var state = ChatFeature.State(conversationID: UUID())
    state.messages.append(message)
    let store = TestStore(initialState: state) { ChatFeature() } withDependencies: {
      $0.historyClient = history
    }

    await store.send(
      .resultPresentationChanged(
        messageID: message.id, preference: preference)
    ) {
      $0.messages[id: message.id]?.resultPresentation = preference
    }
    await store.finish()

    #expect(recorder.preference == preference)
    #expect(recorder.conversationID == state.conversationID)
  }

  @Test func historyReloadPreservesPresentationPreference() async throws {
    let databaseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("creg-chart-history-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString + ".sqlite")
    let history = try HistoryClient.live(databaseURL: databaseURL)
    let conversationID = UUID()
    let preference = ResultPresentationPreference(
      mode: .chart, specificationID: "policy|line|date|value")
    _ = try await history.createConversation(
      conversationID, Date(timeIntervalSince1970: 0))
    var message = Self.answerMessage()
    message.resultPresentation = preference
    try await history.appendMessage(conversationID, message)

    let loaded = try await history.loadConversation(conversationID)
    #expect(loaded.messages.first?.resultPresentation == preference)
  }

  private static func answerMessage() -> ChatMessage {
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

  private static func preparedFollowUp() -> PreparedFollowUp {
    let sql = "SELECT fund, SUM(value) AS current_market_value FROM properties GROUP BY fund"
    let result = QueryResult(
      columns: ["fund", "current_market_value"],
      rows: [[.text("Core"), .real(10)]])
    return PreparedFollowUp(
      id: UUID(),
      sourceAssistantMessageID: UUID(),
      rank: 1,
      question: "How does that compare by fund?",
      sql: sql,
      result: result,
      preparationTelemetry: TurnTelemetry(
        originalQuestion: "How does that compare by fund?"),
      provenance: PreparedQueryProvenance(
        modelKey: "test-model",
        modelRevision: "test-revision",
        runtimeMode: .evaluated,
        preparationPolicyVersion: "prepared-follow-up-v1",
        databaseFingerprint: "test-database",
        sqlFingerprint: PreparedFollowUpIntegrity.fingerprint(sql: sql),
        resultFingerprint: PreparedFollowUpIntegrity.fingerprint(result: result)),
      createdAt: Date(timeIntervalSince1970: 2))
  }
}

private final class PreferenceRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedConversationID: UUID?
  private var storedPreference: ResultPresentationPreference?

  func record(conversationID: UUID, message: ChatMessage) {
    lock.lock()
    storedConversationID = conversationID
    storedPreference = message.resultPresentation
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
}

private extension AutoChartValue {
  var dateValue: Date? {
    guard case .date(let value) = self else { return nil }
    return value
  }
}
