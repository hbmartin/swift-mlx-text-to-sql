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

  @Test func topLevelProjectionParsingIgnoresSQLComments() {
    let projections = CREGChartAdapter.topLevelProjections(
      """
      -- SELECT ignored FROM ignored
      /* SELECT ignored_again FROM ignored_again */
      SELECT p.name AS property,
             /* FROM fake, ignored comma */
             SUM(p.value) AS total_value,
             p.city -- FROM fake, ignored comma
      FROM properties p
      """)

    #expect(projections.count == 3)
    #expect(projections[0].contains("p.name AS property"))
    #expect(projections[1].contains("SUM(p.value) AS total_value"))
    #expect(projections[2].contains("p.city"))
  }

  @Test func sharedScannerSkipsEscapedQuotesAndCommentLikeLiterals() {
    let projections = CREGChartAdapter.topLevelProjections(
      #"""
      SELECT "from, ""quoted""" AS label,
             'it''s, /* still literal */ from here' AS note,
             SUM(value /* ignored, FROM fake */) AS total
      FROM properties
      """#)

    #expect(projections.count == 3)
    #expect(projections[0].contains(#""from, ""quoted""""#))
    #expect(projections[1].contains("/* still literal */"))
    #expect(CREGChartAdapter.aggregate(in: projections[2]) == .sum)
  }

  @Test func aggregateDetectionUsesSQLTokensAndRejectsWindowedValues() {
    #expect(CREGChartAdapter.aggregate(in: "COUNT(DISTINCT tenant_id)") == .countDistinct)
    #expect(CREGChartAdapter.aggregate(in: "COALESCE(SUM(value), 0)") == .sum)
    #expect(CREGChartAdapter.aggregate(in: "checksum(value)") == nil)
    #expect(CREGChartAdapter.aggregate(in: "value /* SUM(fake) */") == nil)
    #expect(CREGChartAdapter.aggregate(in: "'SUM(fake)' AS label") == nil)
    #expect(
      CREGChartAdapter.aggregate(
        in: "SUM(value) OVER (PARTITION BY fund_id)") == nil)
  }

  @Test func wildcardOrMismatchedProjectionsSuppressPositionalHints() {
    #expect(
      CREGChartAdapter.alignedProjections(
        "SELECT p.*, SUM(value) FROM properties p", columnCount: 4)
        == [nil, nil, nil, nil])
    #expect(
      CREGChartAdapter.alignedProjections(
        "SELECT name, value FROM properties", columnCount: 3)
        == [nil, nil, nil])
    #expect(
      CREGChartAdapter.alignedProjections(
        "SELECT name, SUM(value) FROM properties", columnCount: 2)[1]
        == "SUM(value)")
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

  @Test func unitHintsTakePriorityOverExplicitYearDimensions() {
    let percent = CREGChartAdapter.hints(
      for: "year_over_year_growth_rate", projection: nil)
    let currency = CREGChartAdapter.hints(for: "yearly_rent", projection: nil)
    let area = CREGChartAdapter.hints(for: "yearly_square_feet", projection: nil)
    let duration = CREGChartAdapter.hints(for: "year_over_year_months", projection: nil)
    let year = CREGChartAdapter.hints(for: "year_built", projection: nil)

    #expect(percent.unit == .percent(fractional: true))
    #expect(percent.role == .measure)
    #expect(currency.unit == .currency(code: "USD"))
    #expect(currency.role == .measure)
    #expect(area.unit == .area(unit: "sq ft"))
    #expect(area.role == .measure)
    #expect(duration.unit == .duration(unit: "months"))
    #expect(duration.role == .measure)
    #expect(year.semanticType == .ordinal)
    #expect(year.role == .dimension)
  }

  @Test func frozenSchemaUnitsUseWordBoundariesAndSpecificUnitsFirst() {
    let area = CREGChartAdapter.hints(for: "rentable_sqft", projection: nil)
    let duration = CREGChartAdapter.hints(for: "free_rent_months", projection: nil)
    let credit = CREGChartAdapter.hints(for: "credit_rating", projection: nil)

    #expect(area.unit == .area(unit: "sq ft"))
    #expect(duration.unit == .duration(unit: "months"))
    #expect(credit.unit == nil)
    #expect(credit.semanticType == nil)
  }

  @Test func textRateColumnsRemainNominalAndPercentScaleFollowsValues() {
    let rateType = CREGChartAdapter.hints(
      for: "rate_type",
      projection: "rate_type",
      values: [.text("Fixed"), .text("Floating")])
    #expect(rateType.semanticType == nil)
    #expect(rateType.role == nil)
    #expect(rateType.unit == nil)

    let fractions = CREGChartAdapter.hints(
      for: "occupancy_rate",
      projection: "occupancy_rate",
      values: [.real(0.62), .real(0.91)])
    let points = CREGChartAdapter.hints(
      for: "occupancy_rate",
      projection: "occupancy_rate * 100",
      values: [.real(62), .real(91)])
    let mixed = CREGChartAdapter.hints(
      for: "occupancy_rate",
      projection: "occupancy_rate",
      values: [.real(0.62), .real(91)])
    #expect(fractions.unit == .percent(fractional: true))
    #expect(points.unit == .percent(fractional: false))
    #expect(mixed.unit == nil)
  }

  @Test func hintValuesAreMaterializedOnlyForValueAwareStyles() {
    var nominalMaterializations = 0
    func nominalValues() -> [SQLValue] {
      nominalMaterializations += 1
      return [.text("Core")]
    }
    _ = CREGChartAdapter.hints(
      for: "fund_name",
      projection: "fund_name",
      values: nominalValues())
    #expect(nominalMaterializations == 0)

    var percentMaterializations = 0
    func percentValues() -> [SQLValue] {
      percentMaterializations += 1
      return [.real(0.62)]
    }
    _ = CREGChartAdapter.hints(
      for: "occupancy_rate",
      projection: "occupancy_rate",
      values: percentValues())
    #expect(percentMaterializations == 1)
  }

  @Test func temporalAliasesAllowSparseInvalidValues() {
    let table = CREGChartTable(
      result: QueryResult(
        columns: ["lease_commencement", "rent"],
        rows: [
          [.text("2025-01-01"), .real(10)],
          [.text("2025-02-01"), .real(11)],
          [.text("unknown"), .real(12)],
          [.text("2025-04-01"), .real(13)],
          [.text("2025-05-01"), .real(14)],
        ]),
      sql: "SELECT lease_commencement, rent FROM leases",
      question: "Show lease starts")

    #expect(table.chartColumns[0].hints.semanticType == .temporal)
    #expect(table.chartColumns[0].hints.role == .intervalStart)
  }

  @Test func temporalHintsRequireValidValuesAndDateOnlyParsingUsesTheProvidedCalendar() throws {
    let invalid = CREGChartTable(
      result: QueryResult(
        columns: ["maturity_date", "current_balance"],
        rows: [[.text("not scheduled"), .real(10)]]),
      sql: "SELECT maturity_date, current_balance FROM loans",
      question: "Show the trend")
    #expect(invalid.chartColumns[0].hints.semanticType != .temporal)
    #expect(invalid.chartRows[0].chartValue(for: invalid.chartColumns[0].id).dateValue == nil)

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let date = try #require(
      CREGChartAdapter.parseISODate("2027-03-15", calendar: calendar))
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    #expect(components.year == 2027)
    #expect(components.month == 3)
    #expect(components.day == 15)
    #expect(CREGChartAdapter.parseISODate("2027-02-31", calendar: calendar) == nil)
  }

  @Test func defaultDateOnlyParsingUsesGregorianGMT() throws {
    let date = try #require(CREGChartAdapter.parseISODate("2027-03-15"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let components = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: date)
    #expect(components.year == 2027)
    #expect(components.month == 3)
    #expect(components.day == 15)
    #expect(components.hour == 0)
    #expect(components.minute == 0)
    #expect(components.second == 0)
  }

  @Test @MainActor
  func previewChartAnalysisIsCachedByMessageAndInvalidatedByInput() {
    ResultPreviewChartCache.removeAll()
    let messageID = UUID()
    let result = QueryResult(
      columns: ["fund", "current_market_value"],
      rows: [[.text("Core"), .real(10)]])
    let first = ResultPreviewChartCache.analysis(
      messageID: messageID, result: result,
      sql: "SELECT fund, current_market_value FROM properties", question: nil)
    let second = ResultPreviewChartCache.analysis(
      messageID: messageID, result: result,
      sql: "SELECT fund, current_market_value FROM properties", question: nil)
    #expect(first === second)

    var retimed = result
    retimed.elapsedMicroseconds = 42_000
    let equivalent = ResultPreviewChartCache.analysis(
      messageID: messageID, result: retimed,
      sql: "SELECT fund, current_market_value FROM properties", question: nil)
    #expect(first === equivalent)

    var changed = result
    changed.rows.append([.text("Value-Add"), .real(8)])
    let third = ResultPreviewChartCache.analysis(
      messageID: messageID, result: changed,
      sql: "SELECT fund, current_market_value FROM properties", question: nil)
    #expect(first !== third)

    ResultPreviewChartCache.removeAll()
    let afterRelease = ResultPreviewChartCache.analysis(
      messageID: messageID, result: changed,
      sql: "SELECT fund, current_market_value FROM properties", question: nil)
    #expect(third !== afterRelease)
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

  @Test func questionIntentTakesPriorityBeforeSQLFallback() {
    #expect(
      CREGChartAdapter.goal(
        question: "Rank the top properties",
        sql: "SELECT name FROM properties WHERE note = 'trend over time' ORDER BY value"
      ) == .ranking)
    #expect(
      CREGChartAdapter.goal(
        question: "Show the results",
        sql: "SELECT name, value FROM properties ORDER BY value DESC"
      ) == .ranking)
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
        .line
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
    history.updateResultPresentation = { conversationID, updated in
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
    defer { try? FileManager.default.removeItem(at: databaseURL) }
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

  @Test func delayedPreferenceSaveCannotOverwriteTheLatestPreference() async throws {
    let databaseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("creg-chart-history-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let liveHistory = try HistoryClient.live(databaseURL: databaseURL)
    let conversationID = UUID()
    _ = try await liveHistory.createConversation(
      conversationID, Date(timeIntervalSince1970: 0))
    let message = Self.answerMessage()
    try await liveHistory.appendMessage(conversationID, message)

    let gate = FirstPreferenceSaveGate()
    var delayedHistory = liveHistory
    delayedHistory.updateResultPresentation = { conversationID, message in
      await gate.delayFirstSave()
      try await liveHistory.updateResultPresentation(conversationID, message)
    }
    var state = ChatFeature.State(conversationID: conversationID)
    state.messages.append(message)
    let store = TestStore(initialState: state) { ChatFeature() } withDependencies: {
      $0.historyClient = delayedHistory
    }
    let firstPreference = ResultPresentationPreference(mode: .chart)
    let finalPreference = ResultPresentationPreference(
      mode: .table, specificationID: "policy|bar|fund|value")

    await store.send(
      .resultPresentationChanged(
        messageID: message.id, preference: firstPreference)
    ) {
      $0.messages[id: message.id]?.resultPresentation = firstPreference
    }
    await gate.waitUntilFirstSaveStarts()
    await store.send(
      .resultPresentationChanged(
        messageID: message.id, preference: finalPreference)
    ) {
      $0.messages[id: message.id]?.resultPresentation = finalPreference
    }
    await gate.releaseFirstSave()
    await store.finish()

    let loaded = try await liveHistory.loadConversation(conversationID)
    #expect(loaded.messages.first?.resultPresentation == finalPreference)
  }

  @Test func reducerRevisionsRejectAnOlderEffectThatReachesTheActorLast() async throws {
    let queue = MessageUpdateQueue()
    let conversationID = UUID()
    let messageID = UUID()
    let writes = PreferenceWriteRecorder()

    try await queue.save(
      conversationID: conversationID,
      messageID: messageID,
      revision: 2
    ) {
      writes.record("new")
    }
    try await queue.save(
      conversationID: conversationID,
      messageID: messageID,
      revision: 1
    ) {
      writes.record("old")
    }

    #expect(writes.values == ["new"])
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

private actor FirstPreferenceSaveGate {
  private var didStartFirstSave = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func delayFirstSave() async {
    guard !didStartFirstSave else { return }
    didStartFirstSave = true
    let waiters = startWaiters
    startWaiters.removeAll()
    waiters.forEach { $0.resume() }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilFirstSaveStarts() async {
    guard !didStartFirstSave else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func releaseFirstSave() {
    releaseContinuation?.resume()
    releaseContinuation = nil
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

private final class PreferenceWriteRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValues: [String] = []

  func record(_ value: String) {
    lock.lock()
    storedValues.append(value)
    lock.unlock()
  }

  var values: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storedValues
  }
}

private extension AutoChartValue {
  var dateValue: Date? {
    guard case .date(let value) = self else { return nil }
    return value
  }
}
