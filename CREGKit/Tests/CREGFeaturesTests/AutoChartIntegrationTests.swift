import AutoTableCharts
import CREGData
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

  @Test func chartCacheKeysTrackIdentityAndEveryAdaptedTableInput() {
    let result = QueryResult(
      columns: ["fund", "current_market_value"],
      rows: [[.text("Core"), .real(10)]],
      elapsedMicroseconds: 50)
    let resultFingerprint = PreparedFollowUpIntegrity.fingerprint(result: result)
    let directSQL = "SELECT fund, current_market_value FROM properties"
    let table = CREGChartTable(
      result: result,
      sql: directSQL,
      question: "Show value by fund",
      resultFingerprint: resultFingerprint,
      dataIdentity: "CREG.Result.v1:message-1")

    var retimed = result
    retimed.elapsedMicroseconds = 9_999
    let retimedTable = CREGChartTable(
      result: retimed,
      sql: directSQL,
      question: "Show value by fund",
      resultFingerprint: resultFingerprint,
      dataIdentity: "CREG.Result.v1:message-1")

    var changed = result
    changed.rows[0][1] = .real(11)
    let changedFingerprint = PreparedFollowUpIntegrity.fingerprint(result: changed)
    let changedTable = CREGChartTable(
      result: changed,
      sql: directSQL,
      question: "Show value by fund",
      resultFingerprint: changedFingerprint,
      dataIdentity: "CREG.Result.v1:message-1")

    let aggregatedTable = CREGChartTable(
      result: result,
      sql: """
        SELECT fund, SUM(current_market_value) AS current_market_value
        FROM properties
        GROUP BY fund
        """,
      question: "Show value by fund",
      resultFingerprint: resultFingerprint,
      dataIdentity: "CREG.Result.v1:message-1")
    let distinctTable = CREGChartTable(
      result: result,
      sql: directSQL,
      question: "Show value by fund",
      resultFingerprint: resultFingerprint,
      dataIdentity: "CREG.Result.v1:message-2")

    #expect(retimedTable.chartDataIdentity == table.chartDataIdentity)
    #expect(changedTable.chartDataIdentity == table.chartDataIdentity)
    #expect(distinctTable.chartDataIdentity != table.chartDataIdentity)
    #expect(distinctTable.chartDataVersion == table.chartDataVersion)
    #expect(retimedTable.chartDataVersion == table.chartDataVersion)
    #expect(changedTable.chartDataVersion != table.chartDataVersion)
    #expect(aggregatedTable.chartColumns != table.chartColumns)
    #expect(aggregatedTable.chartDataVersion != table.chartDataVersion)
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
    let fractionsWithZero = CREGChartAdapter.hints(
      for: "occupancy_rate",
      projection: "occupancy_rate",
      values: [.real(0), .real(0.62)])
    let pointsWithZero = CREGChartAdapter.hints(
      for: "occupancy_rate",
      projection: "occupancy_rate * 100",
      values: [.real(0), .real(62)])
    #expect(fractions.unit == .percent(fractional: true))
    #expect(points.unit == .percent(fractional: false))
    #expect(mixed.unit == nil)
    #expect(fractionsWithZero.unit == .percent(fractional: true))
    #expect(pointsWithZero.unit == .percent(fractional: false))
  }

  @Test func lifecyclePrefixesDoNotHideNumericUnits() {
    let acquisitionPrice = CREGChartAdapter.hints(
      for: "acquisition_price",
      projection: "acquisition_price",
      values: [.real(12_000_000)])
    let expirationYear = CREGChartAdapter.hints(
      for: "expiration_year",
      projection: "expiration_year",
      values: [.integer(2028)])

    #expect(acquisitionPrice.unit == .currency(code: "USD"))
    #expect(acquisitionPrice.semanticType == .quantitative)
    #expect(expirationYear.semanticType == .ordinal)
    #expect(expirationYear.role == .dimension)
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

  @Test func emptyResultsPreserveTemporalHints() {
    let table = CREGChartTable(
      result: QueryResult(
        columns: ["period_end", "net_operating_income"],
        rows: []),
      sql: "SELECT period_end, net_operating_income FROM property_financials",
      question: "Show NOI over time")

    #expect(table.chartColumns[0].hints.semanticType == .temporal)
    #expect(table.chartColumns[0].hints.role == .intervalEnd)
    #expect(table.chartColumns[1].hints.semanticType == .quantitative)
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

  @Test(arguments: [
    (
      "Show the trend over time", "SELECT period_end, noi FROM property_financials",
      AutoChartGoal.trend
    ),
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
            [
              .integer(1), .text("Atlas Data"), .text("Harbor Point"), .text("210"),
              .text("2026-10-01"), .text("Active"),
            ],
            [
              .integer(2), .text("Béa Café"), .text("Meridian Plaza"), .text("105"),
              .text("2027-01-15"), .text("Active"),
            ],
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
        .range
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

  /// Each named chart preview exists to show one family. Policy version 8
  /// re-scores every candidate, so pin what the preview fixtures resolve to
  /// here rather than discovering a Canvas full of bar charts by eye.
  @Test func chartPreviewFixturesResolveTheirIntendedFamily() throws {
    let fixtures: [(String, QueryResult, String, String?, AutoChartFamily)] = [
      (
        "Result Viewer — Range Chart — Light",
        PreviewFixtures.leaseListingResult,
        StarterQueryID.leaseExpirationsNextTwelveMonthsV1.sql,
        StarterQueryID.leaseExpirationsNextTwelveMonthsV1.question,
        .range
      ),
      (
        "Result Viewer — Loan Maturities — Range Chart",
        PreviewFixtures.loanMaturityResult,
        StarterQueryID.loanMaturitiesNextTwentyFourMonthsV1.sql,
        StarterQueryID.loanMaturitiesNextTwentyFourMonthsV1.question,
        .range
      ),
      (
        "Result Viewer — Bar Chart — Light",
        PreviewFixtures.fundValueResult,
        StarterQueryID.portfolioValueByFundV1.sql,
        StarterQueryID.portfolioValueByFundV1.question,
        .bar
      ),
    ]

    for (name, result, sql, question, expected) in fixtures {
      let recommendation = try #require(
        CREGChartAdapter.recommendations(
          result: result, sql: sql, question: question
        ).set.chartRecommendations.first,
        "\(name) has no chart to show")
      #expect(
        recommendation.specification.family == expected,
        "\(name) now resolves to \(recommendation.specification.family)")
    }
  }

  /// The truncation preview exists to show the incomplete-result caution, so it
  /// needs a chart to hang that caution on.
  @Test func theTruncationPreviewFixtureStillWarnsOnAChart() throws {
    let recommendation = try #require(
      CREGChartAdapter.recommendations(
        result: PreviewFixtures.truncatedResult,
        sql: "SELECT property, tenant, annual_base_rent FROM leases LIMIT 500",
        question: "Show the distribution of returned annual base rent"
      ).set.chartRecommendations.first)

    #expect(!recommendation.warnings.isEmpty)
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
      sql:
        "SELECT property_type, status, SUM(annual_base_rent) AS annual_rent_roll FROM leases GROUP BY property_type, status",
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

  /// The package's recommendation policy version is a component of every
  /// `AutoChartSpecification.id`, so a policy bump — 6 to 8 in this revision —
  /// makes every `ResultPresentationPreference.specificationID` already
  /// persisted in a user's history stale. The chart-or-table mode survives
  /// because it is stored separately; the chosen variant degrades to the
  /// current top recommendation rather than dropping the chart.
  @Test func preferencesPersistedUnderAnEarlierPolicyVersionStillResolve() throws {
    let result = QueryResult(
      columns: ["fund", "current_market_value"],
      rows: [[.text("Core"), .real(10)], [.text("Value-Add"), .real(8)]])
    let recommendations = CREGChartAdapter.recommendations(
      result: result,
      sql: StarterQueryID.portfolioValueByFundV1.sql,
      question: StarterQueryID.portfolioValueByFundV1.question
    ).set.chartRecommendations
    let top = try #require(recommendations.first)

    var components = top.id.split(
      separator: "|", omittingEmptySubsequences: false)
    #expect(components.count > 1)
    components[0] = "1:6"
    let policyV6ID = components.joined(separator: "|")
    #expect(policyV6ID != top.id)

    #expect(
      CREGChartAdapter.resolvedRecommendation(
        preferredID: policyV6ID, in: recommendations)?.id == top.id)
  }

  /// SQLite can hand back an overflowed REAL, which the adapter forwards as a
  /// non-finite `.double`. Such a value cannot position a mark, so the package
  /// omits it and says so: families that would misstate a whole are rejected
  /// outright, and the ones that survive carry a validation diagnostic that
  /// `AutoChartView` shows alongside the chart.
  @Test func nonFiniteMeasuresAreReportedAndNeverSilentlyCharted() throws {
    let chart = CREGChartAdapter.recommendations(
      result: QueryResult(
        columns: ["fund", "current_market_value"],
        rows: [
          [.text("Core"), .real(412_500_000)],
          [.text("Value-Add"), .real(.infinity)],
          [.text("Opportunistic"), .real(98_750_000)],
        ]),
      sql: StarterQueryID.portfolioValueByFundV1.sql,
      question: StarterQueryID.portfolioValueByFundV1.question)

    let families = Set(chart.set.chartRecommendations.map(\.specification.family))
    #expect(!families.contains(.kpi))
    #expect(!families.contains(.donut))
    #expect(!families.contains(.stackedBar))
    #expect(!families.contains(.normalizedBar))

    let top = try #require(chart.set.chartRecommendations.first)
    let validation = AutoChartEngine.validate(
      specification: top.specification, for: chart.table)
    #expect(validation.isValid)
    #expect(
      validation.issues.contains {
        $0.severity == .warning && $0.message.contains("non-finite")
      },
      "\(top.specification.family) charted a non-finite measure silently")
  }

  /// Two finite extremes can still subtract to infinity, so an axis over them
  /// cannot be positioned. The package rejects that span; CREG has to degrade
  /// to the table rather than offer an unrenderable chart.
  @Test func measuresSpanningAnUnrenderableRangeFallBackToTheTable() {
    let set = CREGChartAdapter.recommendations(
      result: QueryResult(
        columns: ["fund", "current_market_value"],
        rows: [
          [.text("Core"), .real(-.greatestFiniteMagnitude)],
          [.text("Value-Add"), .real(.greatestFiniteMagnitude)],
        ]),
      sql: StarterQueryID.portfolioValueByFundV1.sql,
      question: StarterQueryID.portfolioValueByFundV1.question
    ).set

    #expect(set.chartRecommendations.isEmpty)
    #expect(set.fallbackReason != nil)
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

/// Both tests here mutate `ResultPreviewChartCache`, a process-wide store, so
/// they must not run concurrently with each other.
@MainActor
@Suite(.serialized) struct PreviewChartCacheTests {
  @Test func previewChartAnalysisSurvivesUndoAndIsInvalidatedByInput() async {
    ResultPreviewChartCache.removeAll()
    defer { ResultPreviewChartCache.removeAll() }
    let messageID = UUID()
    let result = QueryResult(
      columns: ["fund", "current_market_value"],
      rows: [[.text("Core"), .real(10)]])
    let resultFingerprint = PreparedFollowUpIntegrity.fingerprint(result: result)
    let first = ResultPreviewChartCache.analysis(
      messageID: messageID, resultFingerprint: resultFingerprint, result: result,
      sql: "SELECT fund, current_market_value FROM properties", question: nil)
    let second = ResultPreviewChartCache.analysis(
      messageID: messageID, resultFingerprint: resultFingerprint, result: result,
      sql: "SELECT fund, current_market_value FROM properties", question: nil)
    #expect(first === second)
    #expect(
      first.table.chartDataIdentity
        == "CREG.Result.v1:\(messageID.uuidString.lowercased())")

    var retimed = result
    retimed.elapsedMicroseconds = 42_000
    let equivalent = ResultPreviewChartCache.analysis(
      messageID: messageID, resultFingerprint: resultFingerprint, result: retimed,
      sql: "SELECT fund, current_market_value FROM properties", question: nil)
    #expect(first === equivalent)

    let selectedID = UUID()
    let deletedID = UUID()
    var state = AppFeature.State(
      debugModelIdentity: nil, launchBenchmarkQuestion: nil)
    state.modelReadiness = .ready
    state.chat = ChatFeature.State(conversationID: selectedID)
    state.conversations = [
      ConversationSummary(
        id: selectedID, title: "Selected",
        startedAt: Date(timeIntervalSince1970: 0),
        lastActivityAt: Date(timeIntervalSince1970: 2)),
      ConversationSummary(
        id: deletedID, title: "Deleted then restored",
        startedAt: Date(timeIntervalSince1970: 0),
        lastActivityAt: Date(timeIntervalSince1970: 1)),
    ]
    let clock = TestClock()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.historyClient = .noop()
      $0.continuousClock = clock
    }
    store.exhaustivity = .off

    await store.send(.deleteConversationTapped(deletedID))
    await store.send(.undoDeleteTapped)
    await store.finish()
    let afterUndo = ResultPreviewChartCache.analysis(
      messageID: messageID, resultFingerprint: resultFingerprint, result: result,
      sql: "SELECT fund, current_market_value FROM properties", question: nil)
    #expect(first === afterUndo)

    var changed = result
    changed.rows.append([.text("Value-Add"), .real(8)])
    let changedFingerprint = PreparedFollowUpIntegrity.fingerprint(result: changed)
    let third = ResultPreviewChartCache.analysis(
      messageID: messageID, resultFingerprint: changedFingerprint, result: changed,
      sql: "SELECT fund, current_market_value FROM properties", question: nil)
    #expect(first !== third)
    #expect(third.table.chartDataIdentity == first.table.chartDataIdentity)

    ResultPreviewChartCache.removeAll()
    let afterRelease = ResultPreviewChartCache.analysis(
      messageID: messageID, resultFingerprint: changedFingerprint, result: changed,
      sql: "SELECT fund, current_market_value FROM properties", question: nil)
    #expect(third !== afterRelease)
  }

  /// Clearing CREG's analyses hands the release through to the package, whose
  /// entries were all keyed on tables those analyses owned. The package exposes
  /// no retained-entry count, so this pins the behavior CREG depends on across
  /// the release: the same message re-prepares into a fresh analysis that still
  /// resolves the same chart.
  @Test func clearingPreviewAnalysesReleasesPreparedRendersAndReprepares() throws {
    ResultPreviewChartCache.removeAll()
    defer { ResultPreviewChartCache.removeAll() }
    let messageID = UUID()
    let result = PreviewFixtures.fundValueResult
    let fingerprint = PreparedFollowUpIntegrity.fingerprint(result: result)
    let sql = StarterQueryID.portfolioValueByFundV1.sql
    let question = StarterQueryID.portfolioValueByFundV1.question

    let before = ResultPreviewChartCache.analysis(
      messageID: messageID, resultFingerprint: fingerprint, result: result,
      sql: sql, question: question)
    let beforeRecommendation = try #require(before.recommendations.first)
    _ = AutoChartView(
      table: before.table,
      recommendation: beforeRecommendation,
      interaction: .preview)

    ResultPreviewChartCache.removeAll()
    #expect(
      AutoChartRenderCache.configuration == CREGChartRenderCache.configuration)

    let after = ResultPreviewChartCache.analysis(
      messageID: messageID, resultFingerprint: fingerprint, result: result,
      sql: sql, question: question)
    let afterRecommendation = try #require(after.recommendations.first)

    #expect(before !== after)
    #expect(afterRecommendation.id == beforeRecommendation.id)
  }
}

@MainActor
@Suite struct CREGChartRenderCacheTests {
  /// Every `AutoChartView` CREG builds renders a table that came from a
  /// `ResultChartAnalysis`, so preparing one has to apply the host budget
  /// before the package can retain anything for it.
  @Test func preparingAChartAppliesTheHostBudget() {
    _ = ResultChartAnalysis(
      result: PreviewFixtures.fundValueResult,
      sql: StarterQueryID.portfolioValueByFundV1.sql,
      question: StarterQueryID.portfolioValueByFundV1.question)

    #expect(
      AutoChartRenderCache.configuration == CREGChartRenderCache.configuration)
  }

  /// A margin check on CREG's own numbers rather than a copy of the package's
  /// accounting: the package refuses to cache an entry that exceeds its byte
  /// budget outright, so the budget has to stay well clear of anything CREG's
  /// row cap can produce. This fails if the row cap grows, the schema widens,
  /// or the budget shrinks without someone re-checking the headroom.
  @Test func theHostBudgetStaysClearOfTheWidestChartableResult() {
    // `properties` is the widest table in the schema catalog at 20 columns;
    // allow double that for a join. 160 bytes per cell covers the package's
    // per-value overhead plus a text payload far longer than this schema's.
    let widestPlausibleColumnCount = 40
    let bytesPerCell = 160
    let worstCase =
      DatabaseClient.defaultRowCap * widestPlausibleColumnCount * bytesPerCell

    #expect(CREGChartRenderCache.configuration.maximumTableCost >= worstCase * 4)
    #expect(CREGChartRenderCache.configuration.maximumRenderCost >= worstCase * 4)
    #expect(CREGChartRenderCache.configuration.maximumTableEntries > 0)
    #expect(CREGChartRenderCache.configuration.maximumRenderEntries > 0)
  }

  /// `AutoChartView.init` runs the package's whole preparation, validation, and
  /// cache-admission path, so building one over the row-cap fixture exercises
  /// admission under CREG's budget rather than only the recommendation stage.
  @Test func rowCapResultsPrepareARenderableChart() throws {
    let analysis = ResultChartAnalysis(
      result: PreviewFixtures.truncatedResult,
      sql: "SELECT property, tenant, annual_base_rent FROM leases LIMIT 500",
      question: "Show the distribution of returned annual base rent")
    let recommendation = try #require(analysis.recommendations.first)

    _ = AutoChartView(
      table: analysis.table,
      recommendation: recommendation,
      interaction: .preview)

    #expect(
      AutoChartRenderCache.configuration == CREGChartRenderCache.configuration)
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
    #expect(decoded.resultFingerprint == message.resultFingerprint)

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
    let store = TestStore(initialState: state) {
      ChatFeature()
    } withDependencies: {
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
    let store = TestStore(initialState: state) {
      ChatFeature()
    } withDependencies: {
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

    let newOutcome = try await queue.save(
      conversationID: conversationID,
      messageID: messageID,
      revision: 2
    ) {
      writes.record("new")
    }
    let oldOutcome = try await queue.save(
      conversationID: conversationID,
      messageID: messageID,
      revision: 1
    ) {
      writes.record("old")
    }

    #expect(writes.values == ["new"])
    #expect(newOutcome == .saved)
    #expect(oldOutcome == .superseded)
  }

  @Test func distinctMessagesSerializeWithinOneConversation() async throws {
    let queue = MessageUpdateQueue()
    let conversationID = UUID()
    let gate = FirstPreferenceSaveGate()
    let writes = PreferenceWriteRecorder()
    let first = Task {
      try await queue.save(
        conversationID: conversationID,
        messageID: UUID()
      ) {
        writes.record("first-started")
        await gate.delayFirstSave()
        writes.record("first-finished")
      }
    }
    await gate.waitUntilFirstSaveStarts()

    let second = Task {
      try await queue.save(
        conversationID: conversationID,
        messageID: UUID()
      ) {
        writes.record("second")
      }
    }
    await gate.releaseFirstSave()

    _ = try await first.value
    _ = try await second.value
    #expect(writes.values == ["first-started", "first-finished", "second"])
  }

  @Test func onceSaveCoalescesConcurrentUserTurnWriters() async throws {
    let queue = MessageUpdateQueue()
    let conversationID = UUID()
    let messageID = UUID()
    let gate = FirstPreferenceSaveGate()
    let writes = PreferenceWriteRecorder()
    let first = Task {
      try await queue.saveOnce(
        conversationID: conversationID,
        messageID: messageID
      ) {
        writes.record("write")
        await gate.delayFirstSave()
      }
    }
    await gate.waitUntilFirstSaveStarts()

    let second = Task {
      try await queue.saveOnce(
        conversationID: conversationID,
        messageID: messageID
      ) {
        writes.record("duplicate")
      }
    }
    await gate.releaseFirstSave()

    #expect(try await first.value == .saved)
    #expect(try await second.value == .saved)
    #expect(writes.values == ["write"])
  }

  @Test func forgettingAnActiveOnceSaveDoesNotAbandonItsWaiters() async throws {
    let queue = MessageUpdateQueue()
    let conversationID = UUID()
    let messageID = UUID()
    let gate = FirstPreferenceSaveGate()
    let writes = PreferenceWriteRecorder()
    let first = Task {
      try await queue.saveOnce(
        conversationID: conversationID,
        messageID: messageID
      ) {
        writes.record("write")
        await gate.delayFirstSave()
      }
    }
    await gate.waitUntilFirstSaveStarts()
    let second = Task {
      try await queue.saveOnce(
        conversationID: conversationID,
        messageID: messageID
      ) {
        writes.record("duplicate")
      }
    }
    while await queue.onceSaveWaiterCount(
      conversationID: conversationID, messageID: messageID) == 0
    {
      await Task.yield()
    }

    await queue.forgetOnceSave(
      conversationID: conversationID, messageID: messageID)
    await gate.releaseFirstSave()

    #expect(try await first.value == .saved)
    #expect(try await second.value == .saved)
    #expect(writes.values == ["write"])
  }

  @Test func confirmedDeletionResumesCoalescedOnceSaveCallers() async throws {
    let queue = MessageUpdateQueue()
    let conversationID = UUID()
    let messageID = UUID()
    let gate = FirstPreferenceSaveGate()
    let first = Task {
      try await queue.saveOnce(
        conversationID: conversationID,
        messageID: messageID
      ) {
        await gate.delayFirstSave()
        throw PreferenceSaveTestError.failed
      }
    }
    await gate.waitUntilFirstSaveStarts()
    let second = Task {
      try await queue.saveOnce(
        conversationID: conversationID,
        messageID: messageID
      ) {}
    }
    while await queue.onceSaveWaiterCount(
      conversationID: conversationID, messageID: messageID) == 0
    {
      await Task.yield()
    }

    let deletion = Task {
      await queue.beginDeletingConversation(conversationID)
    }
    while !(await queue.isDeletingConversation(conversationID)) {
      await Task.yield()
    }
    await gate.releaseFirstSave()
    await deletion.value
    await queue.confirmConversationDeletion(conversationID)

    #expect(try await first.value == .discardedDuringDeletion)
    #expect(try await second.value == .discardedDuringDeletion)
  }

  @Test func confirmedConversationDeletionPrunesRevisionTombstones() async throws {
    let queue = MessageUpdateQueue()
    let deletedConversationID = UUID()
    let retainedConversationID = UUID()
    try await queue.save(
      conversationID: deletedConversationID,
      messageID: UUID(),
      revision: 1
    ) {}
    try await queue.save(
      conversationID: retainedConversationID,
      messageID: UUID(),
      revision: 2
    ) {}
    #expect(await queue.retainedRevisionCount() == 2)

    await queue.beginDeletingConversation(deletedConversationID)
    await queue.confirmConversationDeletion(deletedConversationID)

    #expect(await queue.retainedRevisionCount() == 1)
  }

  @Test func lateSaveCannotRecreateDeletedConversationRevisionState() async throws {
    let queue = MessageUpdateQueue()
    let conversationID = UUID()
    let writes = PreferenceWriteRecorder()
    try await queue.save(
      conversationID: conversationID,
      messageID: UUID(),
      revision: 1
    ) {
      writes.record("initial")
    }

    await queue.beginDeletingConversation(conversationID)
    await queue.confirmConversationDeletion(conversationID)
    let outcome = try await queue.save(
      conversationID: conversationID,
      messageID: UUID(),
      revision: 2
    ) {
      writes.record("late")
    }

    #expect(writes.values == ["initial"])
    #expect(await queue.retainedRevisionCount() == 0)
    #expect(outcome == .discardedDuringDeletion)
  }

  @Test func failedInFlightSaveReportsDiscardWhenDeletionBegins() async throws {
    let queue = MessageUpdateQueue()
    let conversationID = UUID()
    let gate = FirstPreferenceSaveGate()
    let save = Task {
      try await queue.save(
        conversationID: conversationID,
        messageID: UUID()
      ) {
        await gate.delayFirstSave()
        throw PreferenceSaveTestError.failed
      }
    }
    await gate.waitUntilFirstSaveStarts()

    let deletion = Task {
      await queue.beginDeletingConversation(conversationID)
    }
    while !(await queue.isDeletingConversation(conversationID)) {
      await Task.yield()
    }
    await gate.releaseFirstSave()
    await deletion.value
    await queue.confirmConversationDeletion(conversationID)

    #expect(try await save.value == .discardedDuringDeletion)
  }

  @Test func failedDeleteRestoresTheOriginalInFlightSaveError() async throws {
    let queue = MessageUpdateQueue()
    let conversationID = UUID()
    let gate = FirstPreferenceSaveGate()
    let save = Task {
      try await queue.save(
        conversationID: conversationID,
        messageID: UUID()
      ) {
        await gate.delayFirstSave()
        throw PreferenceSaveTestError.failed
      }
    }
    await gate.waitUntilFirstSaveStarts()

    let deletion = Task {
      await queue.beginDeletingConversation(conversationID)
    }
    while !(await queue.isDeletingConversation(conversationID)) {
      await Task.yield()
    }
    await gate.releaseFirstSave()
    await deletion.value
    await queue.cancelConversationDeletion(conversationID)

    await #expect(throws: PreferenceSaveTestError.failed) {
      _ = try await save.value
    }
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
    for waiter in waiters {
      waiter.resume()
    }
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

private enum PreferenceSaveTestError: Error, Sendable {
  case failed
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

extension AutoChartValue {
  fileprivate var dateValue: Date? {
    guard case .date(let value) = self else { return nil }
    return value
  }
}
