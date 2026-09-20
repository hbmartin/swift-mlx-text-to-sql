import AutoTableCharts
import AutoTableChartsUI
import CREGData
import ComposableArchitecture
import Foundation
import Observation
import SwiftUI
import Testing

@testable import CREGEngine
@testable import CREGFeatures

private let chartTestReadyTimeout: Duration = .seconds(10)

private func chartTestCompleteLineage(
  _ columns: [String]
) -> SQLQueryLineage {
  SQLQueryLineage(
    columns: columns.map { name in
      SQLResultColumnLineage(
        sourceColumns: [.init(table: "chart_test", column: name)],
        sourceGrain: ["chart_test"],
        preservesSourceDomain: true)
    },
    rowGrain: ["chart_test"],
    completeness: .complete)
}

private final class PickerLabelCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storedCalls = 0

  func increment() { lock.withLock { storedCalls += 1 } }
  var calls: Int { lock.withLock { storedCalls } }
}

private final class ChartPresentationBlockingCallback: @unchecked Sendable {
  private let lock = NSLock()
  private let releaseGate = DispatchSemaphore(value: 0)
  private var didBlock = false
  private var blocked = false
  private var timedOut = false

  var isBlocked: Bool { lock.withLock { blocked } }
  var didTimeOut: Bool { lock.withLock { timedOut } }

  func invoke() {
    let shouldBlock = lock.withLock {
      guard !didBlock else { return false }
      didBlock = true
      blocked = true
      return true
    }
    guard shouldBlock else { return }
    let result = releaseGate.wait(timeout: .now() + 15)
    lock.withLock {
      blocked = false
      timedOut = result == .timedOut
    }
  }

  func release() {
    releaseGate.signal()
  }
}

@MainActor
private final class ChartTestObservationLoop {
  private var isActive = true

  func track(
    _ values: @escaping @MainActor () -> Void,
    onChange: @escaping @MainActor () -> Void
  ) {
    guard isActive else { return }
    withObservationTracking {
      values()
    } onChange: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.isActive else { return }
        self.track(values, onChange: onChange)
        onChange()
      }
    }
  }

  func cancel() {
    isActive = false
  }
}

@MainActor
@discardableResult
private func waitForChartSessionState(
  _ session: AutoChartSession<Int>,
  timeout: Duration = chartTestReadyTimeout,
  until condition: (AutoChartSession<Int>.State) -> Bool
) async throws -> AutoChartSession<Int>.State {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    try Task.checkCancellation()
    let state = session.state
    if case .failed(let failure) = state { throw failure }
    if condition(state) { return state }
    try await Task.sleep(for: .milliseconds(5))
  }
  try Task.checkCancellation()
  let state = session.state
  if case .failed(let failure) = state { throw failure }
  if condition(state) { return state }
  throw AutoChartFailure(
    stage: .presentationPreparation,
    kind: .transient,
    isRetryable: true,
    diagnosticID: "CREG.test.sessionTimeout",
    message: "The chart session did not settle: \(state).")
}

@MainActor
private func waitForReadyChart(
  _ session: AutoChartSession<Int>,
  timeout: Duration = chartTestReadyTimeout
) async throws -> (
  analysis: AutoChartAnalysis<Int>, presented: AutoChartPresentedChart<Int>
) {
  let state = try await waitForChartSessionState(session, timeout: timeout) {
    if case .ready(_, _?) = $0 { return true }
    return false
  }
  guard case .ready(let analysis, let presented?) = state else {
    preconditionFailure("Ready-chart condition returned a non-ready state.")
  }
  return (analysis, presented)
}

@Suite struct CREGChartAdapterTests {
  @Test func lineageAnalysisVersionIsSeven() {
    #expect(SQLQueryLineage.currentAnalysisVersion == 7)
  }

  @Test func incompleteLineageAllowsOnlyUnaggregatedRawRecommendations() async throws {
    let lineage = SQLQueryLineage(
      columns: [
        SQLResultColumnLineage(
          sourceColumns: [.init(table: "property_financials", column: "period_end")],
          sourceGrain: ["property_financials"],
          preservesSourceDomain: true),
        SQLResultColumnLineage(
          sourceColumns: [
            .init(table: "property_financials", column: "net_operating_income")
          ],
          sourceGrain: ["property_financials"],
          preservesSourceDomain: true),
      ],
      reads: [
        .init(table: "property_financials", column: "period_end"),
        .init(table: "property_financials", column: "net_operating_income"),
      ],
      completeness: .incomplete)
    let result = QueryResult(
      columns: ["period_end", "net_operating_income"],
      rows: [
        [.text("2026-01-31"), .real(100)],
        [.text("2026-02-28"), .real(120)],
        [.text("2026-03-31"), .real(110)],
      ],
      lineage: lineage)
    let request = try CREGChartAdapter.analysisRequest(
      result: result,
      sql: "WITH unused(value) AS (VALUES (1)) SELECT period_end, net_operating_income FROM property_financials",
      question: "Show the NOI trend")
    let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
      request,
      preparation: .none)
    let catalog = try #require(analysis.cregRecommendationCatalog)
    let rawFamilies: Set<AutoChartFamily> = [
      .kpi, .scatter, .bubble, .range, .line, .pointLine, .area,
    ]

    #expect(request.constraints.includedAggregations == [.none])
    #expect(request.constraints.includedFamilies == rawFamilies)
    #expect(catalog.cataloged.contains { $0.specification.family == .line })
    #expect(catalog.cataloged.allSatisfy {
      rawFamilies.contains($0.specification.family)
        && $0.specification.aggregation == .none
    })
  }

  @Test func missingGrainColumnsReceiveRawOnlyRecommendations()
    async throws
  {
    let result = QueryResult(
      columns: ["period_end", "net_operating_income", "current_market_value"],
      rows: [
        [.text("2026-01-31"), .real(100), .real(1_000)],
        [.text("2026-01-31"), .real(120), .real(1_200)],
      ],
      lineage: SQLQueryLineage(
        columns: [nil, nil, nil],
        completeness: .incomplete))
    let request = try CREGChartAdapter.analysisRequest(
      result: result,
      sql: "WITH unused(value) AS (VALUES (1)) SELECT period_end, net_operating_income, current_market_value FROM property_financials",
      question: "Show the NOI trend")
    let rawFamilies: Set<AutoChartFamily> = [
      .kpi, .scatter, .bubble, .range, .line, .pointLine, .area,
    ]
    #expect(request.constraints.excludedColumns.isEmpty)
    #expect(request.constraints.includedFamilies == rawFamilies)
    #expect(request.constraints.includedAggregations == [.none])

    let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
      request,
      preparation: .none)
    let catalog = try #require(analysis.cregRecommendationCatalog)
    #expect(catalog.cataloged.contains { $0.specification.family == .scatter })
    #expect(!catalog.cataloged.contains {
      [.line, .pointLine, .area].contains($0.specification.family)
    })
  }

  @Test func unusualUnaliasedAggregateRetainsSafeRawRecommendations() async throws {
    let result = QueryResult(
      columns: ["COUNT(\"property_id\")", "SUM(current_market_value /* total */)"],
      rows: [[.integer(2), .real(32_000_000)]])
    let request = try CREGChartAdapter.analysisRequest(
      result: result,
      sql: "SELECT COUNT(\"property_id\"), SUM(current_market_value /* total */) FROM properties",
      question: "Summarize the portfolio")
    let rawFamilies: Set<AutoChartFamily> = [
      .kpi, .scatter, .bubble, .range, .line, .pointLine, .area,
    ]

    #expect(request.constraints.includedFamilies == rawFamilies)
    #expect(request.constraints.includedAggregations == [.none])
    #expect(request.constraints.excludedColumns.isEmpty)
    let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
      request, preparation: .none)
    let catalog = try #require(analysis.cregRecommendationCatalog)
    #expect(catalog.cataloged.contains {
      $0.specification.family == .kpi
        && $0.specification.aggregation == .none
    })
  }

  @Test func duplicateTemporalPointsRejectContinuousRawChartsWithCompleteLineage()
    async throws
  {
    let result = QueryResult(
      columns: ["period_end", "net_operating_income"],
      rows: [
        [.text("2026-01-31"), .real(100)],
        [.text("2026-01-31"), .real(120)],
      ],
      lineage: chartTestCompleteLineage(["period_end", "net_operating_income"]))
    let request = try CREGChartAdapter.analysisRequest(
      result: result,
      sql: "SELECT period_end, net_operating_income FROM property_financials",
      question: "Show the NOI trend")

    #expect(request.constraints.includedFamilies == nil)
    #expect(request.constraints.includedAggregations == nil)
    let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
      request, preparation: .none)
    let catalog = try #require(analysis.cregRecommendationCatalog)
    #expect(!catalog.cataloged.contains {
      [.line, .pointLine, .area].contains($0.specification.family)
    })
  }

  @Test func analysisDatasetUsesOffsetIDsTypedSemanticsAndStableDataKey() throws {
    let result = QueryResult(
      columns: ["loan_id", "current_balance", "maturity_date"],
      rows: [
        [.integer(42), .real(1_250_000), .text("2027-03-15")],
        [.integer(43), .real(900_000), .text("2028-01-01")],
      ])
    let fingerprint = PreparedFollowUpIntegrity.fingerprint(result: result)
    let sql = """
      SELECT loan_id,
             SUM(current_balance) AS current_balance,
             MAX(maturity_date) AS maturity_date
      FROM loans
      """
    let dataset = try CREGChartAdapter.analysisDataset(
      result: result,
      sql: sql,
      resultFingerprint: fingerprint,
      dataIdentity: "conversation-result")

    #expect(dataset.chartRows.map(\.chartRowID) == [0, 1])
    #expect(dataset.chartColumns[0].hints.semanticType == .identifier)
    #expect(
      dataset.chartColumns[1].hints.measureSemantics
        == AutoChartMeasureSemantics(
          source: .aggregated(.sum), rollup: .additive,
          preferredTransform: .sum))
    #expect(dataset.chartColumns[2].hints.semanticType == .temporal)
    #expect(
      dataset.chartRows[0]
        .chartValue(for: dataset.chartColumns[2].id).dateValue != nil)
    #expect(dataset.chartDataKey.identity == "conversation-result")
    #expect(
      dataset.chartDataKey.trustedRevision
        == CREGChartAdapter.dataKeyRevision(resultFingerprint: fingerprint, sql: sql))
    #expect(
      CREGChartAdapter.analysisContext(
        question: "What matures next?",
        sql: sql).goal == .range)
  }

  @Test func chartProvenanceUsesTheFrozenSchemaAndRejectsJoinFanOut() async throws {
    let sql = """
      SELECT l.lease_type, SUM(p.current_market_value) AS total_value
      FROM leases l
      JOIN properties p ON p.property_id = l.property_id
      GROUP BY l.lease_type
      """
    let dataset = try CREGChartAdapter.analysisDataset(
      result: QueryResult(
        columns: ["lease_type", "total_value"],
        rows: [
          [.text("Gross"), .real(20_000_000)],
          [.text("NNN"), .real(15_000_000)],
        ]),
      sql: sql)
    let category = dataset.chartColumns[0]
    let measure = dataset.chartColumns[1]

    #expect(category.provenance?.sourceGrain == AutoChartGrain(entity: "leases"))
    #expect(measure.provenance?.sourceGrain == AutoChartGrain(entity: "properties"))
    #expect(
      measure.provenance?.sourceColumns
        == [.init(entity: "properties", name: "current_market_value")])

    let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
      AutoChartRequest(table: dataset))
    let validation = analysis.validate(
      .bar(category: category.id, measure: measure.id))
    #expect(!validation.isValid)
    #expect(validation.issues.contains { $0.messageValue.code == .fanOutRisk })
  }

  @Test func chartProvenanceAllowsMeasuresGroupedAtACoarserGrain() async throws {
    let dataset = try CREGChartAdapter.analysisDataset(
      result: QueryResult(
        columns: ["fund_name", "total_value"],
        rows: [
          [.text("Core"), .real(20_000_000)],
          [.text("Value-Add"), .real(15_000_000)],
        ]),
      sql: """
        SELECT f.name AS fund_name, SUM(p.current_market_value) AS total_value
        FROM funds f
        JOIN properties p ON p.fund_id = f.fund_id
        GROUP BY f.name
        """)
    let category = dataset.chartColumns[0]
    let measure = dataset.chartColumns[1]

    #expect(category.provenance?.sourceGrain == AutoChartGrain(entity: "funds"))
    #expect(measure.provenance?.sourceGrain == AutoChartGrain(entity: "funds"))
    let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
      AutoChartRequest(table: dataset))
    #expect(analysis.validate(.bar(category: category.id, measure: measure.id)).isValid)
  }

  @Test func chartProvenanceRejectsSiblingMeasureChasms() async throws {
    let dataset = try CREGChartAdapter.analysisDataset(
      result: QueryResult(
        columns: ["annual_base_rent", "current_balance"],
        rows: [[.real(100_000), .real(2_000_000)]]),
      sql: """
        SELECT l.annual_base_rent, n.current_balance
        FROM leases l
        JOIN properties p ON p.property_id = l.property_id
        JOIN loans n ON n.property_id = p.property_id
        """)
    let rent = dataset.chartColumns[0]
    let balance = dataset.chartColumns[1]
    let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
      AutoChartRequest(table: dataset))
    let validation = analysis.validate(.scatter(x: rent.id, y: balance.id))

    #expect(rent.provenance?.sourceGrain == AutoChartGrain(entity: "leases"))
    #expect(balance.provenance?.sourceGrain == AutoChartGrain(entity: "loans"))
    #expect(!validation.isValid)
    #expect(validation.issues.contains { $0.messageValue.code == .chasmRisk })
  }

  @Test func groupedSiblingAggregatesStillRejectChasmRisk() async throws {
    let dataset = try CREGChartAdapter.analysisDataset(
      result: QueryResult(
        columns: ["total_rent", "total_debt"],
        rows: [[.real(100_000), .real(2_000_000)]]),
      sql: """
        SELECT SUM(l.annual_base_rent) AS total_rent,
               SUM(n.current_balance) AS total_debt
        FROM properties p
        JOIN leases l ON l.property_id = p.property_id
        JOIN loans n ON n.property_id = p.property_id
        GROUP BY p.name
        """)
    let rent = dataset.chartColumns[0]
    let debt = dataset.chartColumns[1]
    let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
      AutoChartRequest(table: dataset))
    let validation = analysis.validate(.scatter(x: rent.id, y: debt.id))

    #expect(rent.provenance?.sourceGrain == AutoChartGrain(entity: "leases"))
    #expect(debt.provenance?.sourceGrain == AutoChartGrain(entity: "loans"))
    #expect(validation.issues.contains { $0.messageValue.code == .chasmRisk })
  }

  @Test func unaliasedJoinStillRejectsParentMeasureFanOut() async throws {
    let dataset = try CREGChartAdapter.analysisDataset(
      result: QueryResult(
        columns: ["status", "total_value"],
        rows: [[.text("Active"), .real(20_000_000)]]),
      sql: """
        SELECT leases.status, SUM(properties.current_market_value) AS total_value
        FROM properties JOIN leases ON leases.property_id = properties.property_id
        GROUP BY leases.status
        """)
    let category = dataset.chartColumns[0]
    let measure = dataset.chartColumns[1]
    let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
      AutoChartRequest(table: dataset))
    let validation = analysis.validate(
      .bar(category: category.id, measure: measure.id))

    #expect(!validation.isValid)
    #expect(validation.issues.contains { $0.messageValue.code == .fanOutRisk })
  }

  @Test func identifierEvidenceRequiresARealSourceIdentifier() async throws {
    let renamedSourceID = try CREGChartAdapter.analysisDataset(
      result: QueryResult(
        columns: ["row_key"],
        rows: [[.integer(1)], [.integer(2)]]),
      sql: "SELECT financial_id AS row_key FROM property_financials")
    let fakeIdentifierAlias = try CREGChartAdapter.analysisDataset(
      result: QueryResult(
        columns: ["financial_id"],
        rows: [[.text("2026-01-31")], [.text("2026-02-28")]]),
      sql: "SELECT period_end AS financial_id FROM property_financials")

    #expect(renamedSourceID.chartColumns[0].hints.role == .identifier)
    #expect(renamedSourceID.chartColumns[0].hints.semanticType == .identifier)
    #expect(fakeIdentifierAlias.chartColumns[0].hints.role == .dimension)
    #expect(fakeIdentifierAlias.chartColumns[0].hints.semanticType == .nominal)

    let unionResult = QueryResult(
      columns: ["property_id", "current_market_value", "other_value"],
      rows: [
        [.integer(1), .real(100), .real(110)],
        [.integer(2), .real(200), .real(210)],
      ])
    let unionSQL = "SELECT property_id, current_market_value, current_market_value + 10 AS other_value FROM properties UNION ALL SELECT property_id, current_market_value, current_market_value + 10 AS other_value FROM properties"
    let castResult = QueryResult(
      columns: ["property_id", "current_market_value", "other_value"],
      rows: [
        [.text("1"), .real(100), .real(110)],
        [.text("2"), .real(200), .real(210)],
      ])
    let castSQL = "SELECT CAST(property_id AS TEXT) AS property_id, current_market_value, current_market_value + 10 AS other_value FROM properties"
    let unionIdentifier = try CREGChartAdapter.analysisDataset(
      result: unionResult, sql: unionSQL)
    let castIdentifier = try CREGChartAdapter.analysisDataset(
      result: castResult, sql: castSQL)
    #expect(unionIdentifier.chartColumns[0].hints.role == nil)
    #expect(castIdentifier.chartColumns[0].hints.role == nil)
    let analyzer = AutoChartAnalyzer(cache: AutoChartCache())
    let unionAnalysis = try await analyzer.analyze(
      CREGChartAdapter.analysisRequest(
        result: unionResult, sql: unionSQL, question: nil),
      preparation: .none)
    let castAnalysis = try await analyzer.analyze(
      CREGChartAdapter.analysisRequest(
        result: castResult, sql: castSQL, question: nil),
      preparation: .none)
    #expect(unionAnalysis.columnProfiles[0].semanticType == .identifier)
    #expect(castAnalysis.columnProfiles[0].semanticType == .identifier)
    let unionCatalog = try #require(unionAnalysis.cregRecommendationCatalog)
    #expect(unionCatalog.cataloged.contains {
      $0.specification.family == .scatter
        && $0.specification.aggregation == .none
    })
    #expect(!unionCatalog.cataloged.contains {
      [.line, .pointLine, .area].contains($0.specification.family)
    })
    let castCatalog = try #require(castAnalysis.cregRecommendationCatalog)
    #expect(!castCatalog.cataloged.contains {
      $0.specification.family == .bar
        && $0.specification.encoding.x == castAnalysis.columnProfiles[0].column.id
    })
  }

  @Test func fakeIdentifierAliasesRelyOnObservedGroupingUniqueness() async throws {
    for (periods, expectsFanOut) in [
      (["2026-01-31", "2026-01-31"], true),
      (["2026-01-31", "2026-02-28"], false),
    ] {
      let dataset = try CREGChartAdapter.analysisDataset(
        result: QueryResult(
          columns: ["loan_id", "annual_base_rent"],
          rows: [
            [.text(periods[0]), .real(100)],
            [.text(periods[1]), .real(200)],
          ]),
        sql: """
          SELECT n.maturity_date AS loan_id, l.annual_base_rent
          FROM leases l
          JOIN properties p ON p.property_id = l.property_id
          JOIN loans n ON n.property_id = p.property_id
          """)
      let grouping = dataset.chartColumns[0]
      let measure = dataset.chartColumns[1]
      let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
        AutoChartRequest(table: dataset))
      let validation = analysis.validate(
        .bar(
          category: grouping.id,
          measure: measure.id,
          aggregation: .sum))

      #expect(grouping.hints.role == .dimension)
      #expect(
        validation.issues.contains { $0.messageValue.code == .fanOutRisk }
          == expectsFanOut)
    }
  }

  @Test func rowGrainFallbackRejectsOpaqueFanOutBucket() async throws {
    let dataset = try CREGChartAdapter.analysisDataset(
      result: QueryResult(
        columns: ["bucket", "total_value"],
        rows: [[.text("All"), .real(20_000_000)]]),
      sql: """
        SELECT 'All' AS bucket, SUM(p.current_market_value) AS total_value
        FROM properties p JOIN leases l ON l.property_id = p.property_id
        GROUP BY bucket
        """)
    let category = dataset.chartColumns[0]
    let measure = dataset.chartColumns[1]
    let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
      AutoChartRequest(table: dataset))
    let validation = analysis.validate(
      .bar(category: category.id, measure: measure.id))

    #expect(category.provenance == nil)
    #expect(dataset.chartMetadata.rowGrain == AutoChartGrain(entity: "leases"))
    #expect(validation.issues.contains { $0.messageValue.code == .fanOutRisk })
  }

  @Test func unknownRelationsRemainInRowGrainAndRejectFanOut() async throws {
    let dataset = try CREGChartAdapter.analysisDataset(
      result: QueryResult(
        columns: ["city", "current_market_value"],
        rows: [
          [.text("Phoenix"), .real(20_000_000)],
          [.text("Phoenix"), .real(20_000_000)],
        ]),
      sql: """
        SELECT p.city, p.current_market_value
        FROM properties p JOIN json_each('[1,2]') j
        """)
    let category = dataset.chartColumns[0]
    let measure = dataset.chartColumns[1]
    let rowEntities = try #require(dataset.chartMetadata.rowGrain).entities
    let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
      AutoChartRequest(table: dataset))
    #expect(rowEntities.contains("properties"))
    #expect(rowEntities.contains("creg.opaque.json_each"))
    for aggregation in [AutoChartAggregation.sum, .mean] {
      let validation = analysis.validate(
        .bar(
          category: category.id,
          measure: measure.id,
          aggregation: aggregation))
      #expect(validation.issues.contains { $0.messageValue.code == .fanOutRisk })
    }
  }

  @Test func failedDerivedRelationsRemainInRowGrainAndRejectFanOut() async throws {
    let dataset = try CREGChartAdapter.analysisDataset(
      result: QueryResult(
        columns: ["city", "current_market_value"],
        rows: [
          [.text("Phoenix"), .real(20_000_000)],
          [.text("Phoenix"), .real(20_000_000)],
        ]),
      sql: """
        SELECT p.city, p.current_market_value
        FROM properties p JOIN (VALUES (1), (2)) v
        """)
    let category = dataset.chartColumns[0]
    let measure = dataset.chartColumns[1]
    let rowEntities = try #require(dataset.chartMetadata.rowGrain).entities
    let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
      AutoChartRequest(table: dataset))
    let validation = analysis.validate(
      .bar(category: category.id, measure: measure.id, aggregation: .sum))

    #expect(rowEntities.contains("properties"))
    #expect(rowEntities.contains("creg.opaque.derived"))
    #expect(validation.issues.contains { $0.messageValue.code == .fanOutRisk })
  }

  @Test func inflatedAggregateKeepsItsSafetyGrainAcrossACTE() async throws {
    let dataset = try CREGChartAdapter.analysisDataset(
      result: QueryResult(
        columns: ["lease_type", "total_value"],
        rows: [[.text("Gross"), .real(20_000_000)]]),
      sql: """
        WITH inflated AS (
          SELECT l.lease_type, SUM(p.current_market_value) AS total_value
          FROM properties p
          JOIN leases l ON l.property_id = p.property_id
          GROUP BY l.lease_type
        )
        SELECT lease_type, total_value FROM inflated
        """)
    let category = dataset.chartColumns[0]
    let measure = dataset.chartColumns[1]
    let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
      AutoChartRequest(table: dataset))
    let validation = analysis.validate(
      .bar(category: category.id, measure: measure.id))

    #expect(measure.provenance?.sourceGrain == AutoChartGrain(entity: "properties"))
    #expect(validation.issues.contains { $0.messageValue.code == .fanOutRisk })
  }

  @Test func childCountAndAncestorNormalizedExpressionAvoidFalseFanOut() async throws {
    let cases: [(String, String)] = [
      (
        "COUNT(*)",
        "lease_count"
      ),
      (
        "SUM(l.annual_base_rent * p.ownership_pct)",
        "owned_rent"
      ),
    ]
    for (expression, outputName) in cases {
      let dataset = try CREGChartAdapter.analysisDataset(
        result: QueryResult(
          columns: ["lease_type", outputName],
          rows: [[.text("Gross"), .real(10)], [.text("NNN"), .real(20)]]),
        sql: """
          SELECT l.lease_type, \(expression) AS \(outputName)
          FROM leases l JOIN properties p ON p.property_id = l.property_id
          GROUP BY l.lease_type
          """)
      let category = dataset.chartColumns[0]
      let measure = dataset.chartColumns[1]
      let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
        AutoChartRequest(table: dataset))
      let validation = analysis.validate(
        .bar(category: category.id, measure: measure.id))

      #expect(!validation.issues.contains { $0.messageValue.code == .fanOutRisk })
    }
  }

  @Test func duplicateInvariantAggregatesAvoidFalseFanOut() async throws {
    for expression in [
      "MIN(p.current_market_value)",
      "MAX(p.current_market_value)",
      "COUNT(DISTINCT p.property_id)",
    ] {
      let dataset = try CREGChartAdapter.analysisDataset(
        result: QueryResult(
          columns: ["lease_type", "value"],
          rows: [[.text("Gross"), .real(10)], [.text("NNN"), .real(20)]]),
        sql: """
          SELECT l.lease_type, \(expression) AS value
          FROM properties p JOIN leases l ON l.property_id = p.property_id
          GROUP BY l.lease_type
          """)
      let category = dataset.chartColumns[0]
      let measure = dataset.chartColumns[1]
      let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
        AutoChartRequest(table: dataset))
      let validation = analysis.validate(
        .bar(category: category.id, measure: measure.id))

      #expect(!validation.issues.contains { $0.messageValue.code == .fanOutRisk })
    }
  }

  @Test func preAggregatedCTEsAvoidFalseChasmRisk() async throws {
    let dataset = try CREGChartAdapter.analysisDataset(
      result: QueryResult(
        columns: ["total_rent", "total_debt"],
        rows: [[.real(10), .real(20)], [.real(30), .real(40)]]),
      sql: """
        WITH rent AS (
          SELECT property_id, SUM(annual_base_rent) AS total_rent
          FROM leases GROUP BY property_id
        ), debt AS (
          SELECT property_id, SUM(current_balance) AS total_debt
          FROM loans GROUP BY property_id
        )
        SELECT r.total_rent, d.total_debt
        FROM rent r JOIN debt d USING (property_id)
        """)
    let x = dataset.chartColumns[0]
    let y = dataset.chartColumns[1]
    let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
      AutoChartRequest(table: dataset))
    let validation = analysis.validate(.scatter(x: x.id, y: y.id))

    #expect(x.provenance?.sourceGrain == AutoChartGrain(entity: "properties"))
    #expect(y.provenance?.sourceGrain == AutoChartGrain(entity: "properties"))
    #expect(!validation.issues.contains { $0.messageValue.code == .chasmRisk })
  }

  @Test func ratioAggregatesUseTheirProducedPropertyGrain() async throws {
    for expression in [
      "SUM(l.annual_base_rent) / SUM(l.leased_sqft)",
      "SUM(l.annual_base_rent) / SUM(SUM(l.annual_base_rent)) OVER ()",
    ] {
      let dataset = try CREGChartAdapter.analysisDataset(
        result: QueryResult(
          columns: ["city", "value"],
          rows: [[.text("Phoenix"), .real(24.5)]]),
        sql: """
          SELECT p.city, \(expression) AS value
          FROM properties p
          JOIN leases l ON l.property_id = p.property_id
          GROUP BY p.city
          """)
      let category = dataset.chartColumns[0]
      let measure = dataset.chartColumns[1]
      let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
        AutoChartRequest(table: dataset))
      let validation = analysis.validate(
        .bar(category: category.id, measure: measure.id))

      #expect(measure.provenance?.sourceGrain == AutoChartGrain(entity: "properties"))
      #expect(!validation.issues.contains { $0.messageValue.code == .fanOutRisk })
    }
  }

  @Test func derivedRatiosAndSharesStillExposeRealFanOut() async throws {
    for expression in [
      "SUM(annual_base_rent) / SUM(leased_sqft)",
      "SUM(annual_base_rent) / SUM(SUM(annual_base_rent)) OVER ()",
    ] {
      let dataset = try CREGChartAdapter.analysisDataset(
        result: QueryResult(
          columns: ["status", "total_ratio"],
          rows: [[.text("Active"), .real(24.5)]]),
        sql: """
          WITH rent AS (
            SELECT property_id, \(expression) AS rent_ratio
            FROM leases GROUP BY property_id
          )
          SELECT l.status, SUM(r.rent_ratio) AS total_ratio
          FROM rent r JOIN leases l USING (property_id)
          GROUP BY l.status
          """)
      let category = dataset.chartColumns[0]
      let measure = dataset.chartColumns[1]
      let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
        AutoChartRequest(table: dataset))
      let validation = analysis.validate(
        .bar(category: category.id, measure: measure.id))

      #expect(measure.provenance?.sourceGrain == AutoChartGrain(entity: "properties"))
      #expect(validation.issues.contains { $0.messageValue.code == .fanOutRisk })
    }
  }

  @Test func pairedPerPropertyRatioCTEsAvoidFalseChasmRisk() async throws {
    let dataset = try CREGChartAdapter.analysisDataset(
      result: QueryResult(
        columns: ["rent_ratio", "margin_ratio"],
        rows: [[.real(24.5), .real(0.6)]]),
      sql: """
        WITH rent AS (
          SELECT property_id,
                 SUM(annual_base_rent) / SUM(leased_sqft) AS rent_ratio
          FROM leases GROUP BY property_id
        ), margins AS (
          SELECT property_id,
                 SUM(net_operating_income) / SUM(effective_gross_income)
                   AS margin_ratio
          FROM property_financials GROUP BY property_id
        )
        SELECT r.rent_ratio, m.margin_ratio
        FROM rent r JOIN margins m USING (property_id)
        """)
    let x = dataset.chartColumns[0]
    let y = dataset.chartColumns[1]
    let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
      AutoChartRequest(table: dataset))
    let validation = analysis.validate(.scatter(x: x.id, y: y.id))

    #expect(x.provenance?.sourceGrain == AutoChartGrain(entity: "properties"))
    #expect(y.provenance?.sourceGrain == AutoChartGrain(entity: "properties"))
    #expect(!validation.issues.contains { $0.messageValue.code == .chasmRisk })
  }

  @Test func compositeExpressionOrderDoesNotChangeChartSafety() async throws {
    var issueCodes: [[AutoChartMessage.Code]] = []
    for expression in [
      "SUM(pf.net_operating_income / v.market_value)",
      "SUM(v.market_value / pf.net_operating_income)",
    ] {
      let dataset = try CREGChartAdapter.analysisDataset(
        result: QueryResult(
          columns: ["city", "value"],
          rows: [[.text("Phoenix"), .real(0.08)]]),
        sql: """
          SELECT p.city, \(expression) AS value
          FROM properties p
          JOIN property_financials pf ON pf.property_id = p.property_id
          JOIN valuations v ON v.property_id = p.property_id
          GROUP BY p.city
          """)
      let category = dataset.chartColumns[0]
      let measure = dataset.chartColumns[1]
      let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
        AutoChartRequest(table: dataset))
      issueCodes.append(
        analysis.validate(.bar(category: category.id, measure: measure.id))
          .issues.map(\.messageValue.code))
    }

    #expect(issueCodes[0] == issueCodes[1])
  }

  @Test func repeatedEntityLanguageClassifiesAsComparison() {
    #expect(
      CREGChartAdapter.analysisContext(
        question: "Show current market value for each property",
        sql: "SELECT name, current_market_value FROM properties"
      ).goal == .comparison)
  }

  @Test func unitLanguageDoesNotBecomeAComparisonGoal() {
    for question in [
      "Show rent per square foot",
      "Show free rent per month",
      "Show rent per leased square foot",
    ] {
      #expect(
        CREGChartAdapter.analysisContext(
          question: question,
          sql: "SELECT base_rent_psf FROM leases"
        ).goal == .overview)
    }
    #expect(
      CREGChartAdapter.analysisContext(
        question: "Show rent per property",
        sql: "SELECT property_id, annual_base_rent FROM leases"
      ).goal == .comparison)
    #expect(
      CREGChartAdapter.analysisContext(
        question: "Per property, show annual rent",
        sql: "SELECT property_id, annual_base_rent FROM leases"
      ).goal == .comparison)
  }

  @Test func frozenOrdinalDomainsCarrySemanticOrder() throws {
    let dataset = try CREGChartAdapter.analysisDataset(
      result: QueryResult(
        columns: ["building_class"],
        rows: [[.text("C")], [.text("A")], [.text("B")]]),
      sql: "SELECT building_class FROM properties")
    let column = try #require(dataset.chartColumns.first)

    #expect(column.hints.semanticType == .ordinal)
    #expect(column.categoryOrder == ["A", "B", "C"].map(AutoChartValue.text))
  }

  @Test func ordinalDomainsFollowSourceColumnsInsteadOfOutputAliases() throws {
    let rating = try CREGChartAdapter.analysisDataset(
      result: QueryResult(
        columns: ["rating"],
        rows: [[.text("AAA")], [.text("BBB")]]),
      sql: "SELECT credit_rating AS rating FROM tenants")
    let strategyAlias = try CREGChartAdapter.analysisDataset(
      result: QueryResult(
        columns: ["strategy"],
        rows: [[.text("Gross")], [.text("NNN")]]),
      sql: "SELECT lease_type AS strategy FROM leases")

    #expect(
      rating.chartColumns[0].categoryOrder?.first == .text("AAA"))
    #expect(rating.chartColumns[0].categoryOrder?.last == .text("NR"))
    #expect(strategyAlias.chartColumns[0].categoryOrder == nil)
  }

  @Test func aggregatesAndDerivedExpressionsDoNotInheritSourceCategoryOrder() throws {
    let aggregate = try CREGChartAdapter.analysisDataset(
      result: QueryResult(
        columns: ["credit_rating"],
        rows: [[.integer(3)]]),
      sql: "SELECT COUNT(credit_rating) AS credit_rating FROM tenants")
    let derived = try CREGChartAdapter.analysisDataset(
      result: QueryResult(
        columns: ["building_class"],
        rows: [[.text("Upper")], [.text("Other")]]),
      sql: """
        SELECT CASE WHEN building_class = 'A' THEN 'Upper' ELSE 'Other' END
          AS building_class
        FROM properties
        """)

    #expect(aggregate.chartColumns[0].categoryOrder == nil)
    #expect(aggregate.chartColumns[0].hints.semanticType != .ordinal)
    #expect(
      aggregate.chartColumns[0].hints.measureSemantics?.source
        == .aggregated(.count))
    #expect(derived.chartColumns[0].categoryOrder == nil)
  }

  @Test(arguments: [6, SQLQueryLineage.currentAnalysisVersion + 1, Int.max])
  func versionMismatchedLineageFallsBackToTable(analysisVersion: Int) async throws {
    let stale = SQLQueryLineage(
      columns: [
        SQLResultColumnLineage(
          sourceColumns: [.init(table: "funds", column: "name")],
          sourceGrain: ["funds"],
          preservesSourceDomain: true)
      ],
      rowGrain: ["funds"],
      analysisVersion: analysisVersion)
    let result = QueryResult(
      columns: ["city"],
      rows: [[.text("Phoenix")]],
      lineage: stale)
    let dataset = try CREGChartAdapter.analysisDataset(
      result: result,
      sql: "SELECT city FROM properties")
    let request = try CREGChartAdapter.analysisRequest(
      result: result,
      sql: "SELECT city FROM properties",
      question: "Where are the properties?")
    let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
      request,
      preparation: .none)

    #expect(dataset.chartColumns[0].provenance == nil)
    #expect(dataset.chartColumns[0].categoryOrder == nil)
    #expect(dataset.chartMetadata.rowGrain == nil)
    #expect(request.constraints.includedFamilies == [])
    guard case .tableFallback = analysis.outcome else {
      Issue.record("Version-mismatched lineage remained chart-eligible.")
      return
    }
  }

  @Test func missingLineageIsReanalyzedAndRemainsChartEligible() async throws {
    let result = QueryResult(
      columns: ["period_end", "net_operating_income"],
      rows: [
        [.text("2026-01-31"), .real(100)],
        [.text("2026-02-28"), .real(120)],
      ])
    let request = try CREGChartAdapter.analysisRequest(
      result: result,
      sql: "SELECT period_end, net_operating_income FROM property_financials",
      question: "Show the NOI trend")
    let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
      request, preparation: .none)

    #expect(request.constraints.includedFamilies == nil)
    #expect(analysis.cregRecommendationCatalog != nil)
  }

  @Test func currentLineageRetainsRuntimeOriginSemantics() throws {
    let origin = SQLSourceColumn(table: "tenants", column: "credit_rating")
    let current = SQLQueryLineage(
      columns: [
        SQLResultColumnLineage(
          sourceColumns: [origin],
          sourceGrain: ["tenants"],
          preservesSourceDomain: true)
      ],
      reads: [.init(table: origin.table, column: origin.column)],
      completeness: .complete)
    let dataset = try CREGChartAdapter.analysisDataset(
      result: QueryResult(
        columns: ["runtime_rating"],
        rows: [[.text("AAA")]],
        lineage: current),
      sql: "SELECT credit_rating FROM tenants")

    #expect(
      dataset.chartColumns[0].provenance?.sourceColumns
        == [.init(entity: "tenants", name: "credit_rating")])
    #expect(dataset.chartColumns[0].categoryOrder?.first == .text("AAA"))
    #expect(dataset.chartColumns[0].categoryOrder?.last == .text("NR"))
  }

  @Test func blobBearingOrdinalColumnsAreNotForcedIntoCategorySemantics() throws {
    let dataset = try CREGChartAdapter.analysisDataset(
      result: QueryResult(
        columns: ["rating"],
        rows: [
          [.text("AAA")],
          [.blob(Data([0x01]))],
          [.null],
        ]),
      sql: "SELECT credit_rating AS rating FROM tenants")

    #expect(dataset.chartColumns[0].hints.semanticType == nil)
    #expect(dataset.chartColumns[0].hints.role == nil)
  }

  /// A ragged row (a prepared result decoded from history written by an
  /// older or buggy producer) pads with nulls — matching the defensive
  /// padding in the hints closure — instead of throwing and silently
  /// disabling charts for the whole result.
  @Test func raggedQueryResultRowsPadToTheColumnCount() throws {
    let result = QueryResult(
      columns: ["fund", "current_market_value"],
      rows: [
        [.text("Core")],
        [.text("Value-Add"), .real(1_000), .text("spurious extra cell")],
      ])

    let dataset = try CREGChartAdapter.analysisDataset(
      result: result,
      sql: "SELECT fund, current_market_value FROM properties")

    #expect(dataset.chartRows.count == 2)
    let valueColumn = dataset.chartColumns[1].id
    #expect(
      dataset.chartRows[0].chartValue(for: valueColumn) == .null)
    #expect(
      dataset.chartRows[1].chartValue(for: valueColumn)
        == .double(1_000))
  }

  @Test func formattersRetainCREGTableFormattingInEveryChartContext() {
    let cases: [(String, SQLValue, AutoChartValue)] = [
      ("current_market_value", .real(1_250_000), .double(1_250_000)),
      ("occupancy_rate", .real(0.925), .double(0.925)),
      ("rentable_sqft", .integer(12500), .integer(12500)),
      ("maturity_date", .text("2027-03-15"), .date(CREGChartAdapter.parseISODate("2027-03-15")!)),
    ]
    for context in AutoChartFormattingContext.allCases {
      for (name, sqlValue, chartValue) in cases {
        let column = AutoChartColumn(id: "value", name: name)
        #expect(
          CREGChartAdapter.formatters.format(
            column: column, value: chartValue, context: context)
            == PortfolioValueFormatting.displayString(for: sqlValue, column: name))
      }
    }
  }

  @Test func formattersRespectChartGeneratedValueSemantics() {
    let currencyColumn = AutoChartColumn(
      id: "value",
      name: "current_market_value")

    #expect(
      CREGChartAdapter.formatters.format(
        column: currencyColumn,
        aggregation: .sum,
        value: .integer(2),
        context: .detail) == "$2")
    #expect(
      CREGChartAdapter.formatters.format(
        column: currencyColumn,
        aggregation: .count,
        value: .integer(2),
        context: .detail) == "2")
    #expect(
      CREGChartAdapter.formatters.formatNormalizedFraction(
        0.25,
        column: currencyColumn,
        aggregation: .sum,
        context: .axisTick) == "25%")
  }

  @Test func dependencyUpgradePreservesSelectionFormattingAndAccessibilityContract()
    throws
  {
    let dataset = try CREGChartAdapter.analysisDataset(
      result: QueryResult(
        columns: ["fund", "current_market_value"],
        rows: [
          [.text("Core"), .integer(2)],
          [.text("Core"), .null],
        ]),
      sql:
        "SELECT fund, SUM(current_market_value) AS current_market_value FROM properties GROUP BY fund")
    let columns = dataset.chartColumns
    let fundID = try #require(columns.first?.id)
    let valueID = try #require(columns.dropFirst().first?.id)

    #expect(fundID == CREGChartAdapter.columnID(index: 0, name: "fund"))
    #expect(
      valueID
        == CREGChartAdapter.columnID(
          index: 1, name: "current_market_value"))
    let selection = AutoChartSelection<Int>(
      sourceRowIDs: [0, 1],
      dimensions: [
        AutoChartSelectedDimension(columnID: fundID, value: .text("Core"))
      ],
      measure: AutoChartSelectedMeasure(
        columnID: valueID,
        aggregation: .sum,
        value: .scalar(.integer(2))),
      family: .bar,
      specificationID: AutoChartSpecificationID(
        rawValue: "creg-dependency-upgrade-contract"),
      markID: "core")

    let presentation = selection.presentation(
      columns: columns,
      formatters: CREGChartAdapter.formatters,
      textResolver: CREGChartAdapter.textResolver)

    #expect(presentation.label == "Core")
    #expect(presentation.valueDescription == "$2")
    #expect(presentation.accessibilityDescription == "Core, $2")
  }

  @Test func chartDiagnosticsUseCREGReviewedCopy() {
    let upstream = AutoChartMessage(
      category: .diagnostic,
      code: .boxPlotMissingCategoryGroup,
      defaultText:
        "Unrenderable box-plot categories are combined into one missing-value group.")
    let unrelated = AutoChartMessage(
      category: .diagnostic,
      code: .validationFailed,
      defaultText: "Upstream fallback")
    let sameCodeInAnotherCategory = AutoChartMessage(
      category: .rationale,
      code: .boxPlotMissingCategoryGroup,
      defaultText: "Rationale fallback")
    let sameCodeWithFutureArguments = AutoChartMessage(
      category: .diagnostic,
      code: .boxPlotMissingCategoryGroup,
      arguments: ["label": .string("Future label")],
      defaultText: "Argument-aware fallback")

    #expect(
      CREGChartAdapter.textResolver(upstream)
        == "Some category values couldn’t be displayed and are grouped as “Missing value”.")
    #expect(CREGChartAdapter.textResolver(unrelated) == "Upstream fallback")
    #expect(
      CREGChartAdapter.textResolver(sameCodeInAnotherCategory)
        == "Rationale fallback")
    #expect(
      CREGChartAdapter.textResolver(sameCodeWithFutureArguments)
        == "Argument-aware fallback")
  }

  @Test func blobBearingColumnsAreNotForcedIntoCategorySemantics() throws {
    let dataset = try CREGChartAdapter.analysisDataset(
      result: QueryResult(
        columns: ["is_segment", "value"],
        rows: [
          [.integer(1), .real(10)],
          [.blob(Data([0x01])), .real(20)],
          [.null, .real(30)],
        ]),
      sql: "SELECT is_segment, value FROM observations")

    #expect(dataset.chartColumns[0].hints.semanticType == nil)
    #expect(dataset.chartColumns[0].hints.role == nil)
  }

  @Test func blobDoesNotEraseOtherwiseValidTemporalSemantics() throws {
    let dataset = try CREGChartAdapter.analysisDataset(
      result: QueryResult(
        columns: ["maturity_date"],
        rows: [
          [.text("2027-01-01")],
          [.text("2027-02-01")],
          [.text("2027-03-01")],
          [.text("2027-04-01")],
          [.blob(Data([0x01]))],
        ]),
      sql: "SELECT maturity_date FROM loans")
    let column = dataset.chartColumns[0]

    #expect(column.hints.semanticType == .temporal)
    #expect(dataset.chartRows[0].chartValue(for: column.id).dateValue != nil)
    #expect(
      dataset.chartRows[4].chartValue(for: column.id)
        == .binary(Data([0x01])))
  }

  @Test func temporalSemanticsAllowTheExactValidityThreshold() throws {
    let dataset = try CREGChartAdapter.analysisDataset(
      result: QueryResult(
        columns: ["maturity_date"],
        rows: [
          [.text("2027-01-01")],
          [.text("2027-02-01")],
          [.text("2027-03-01")],
          [.text("2027-04-01")],
          [.text("not-a-date")],
        ]),
      sql: "SELECT maturity_date FROM loans")

    #expect(dataset.chartColumns[0].hints.semanticType == .temporal)
  }

  @Test func mostlyBlobColumnsDoNotAcquireTemporalSemantics() throws {
    let dataset = try CREGChartAdapter.analysisDataset(
      result: QueryResult(
        columns: ["maturity_date"],
        rows: [
          [.text("2027-01-01")],
          [.text("2027-02-01")],
          [.blob(Data([0x01]))],
          [.blob(Data([0x02]))],
          [.blob(Data([0x03]))],
          [.blob(Data([0x04]))],
          [.blob(Data([0x05]))],
          [.blob(Data([0x06]))],
          [.blob(Data([0x07]))],
          [.blob(Data([0x08]))],
        ]),
      sql: "SELECT maturity_date FROM loans")

    #expect(dataset.chartColumns[0].hints.semanticType == nil)
  }

  @Test func malformedScalarsStillPreventTemporalSemantics() throws {
    for malformed in [SQLValue.text("not-a-date"), .integer(20_270_101)] {
      let dataset = try CREGChartAdapter.analysisDataset(
        result: QueryResult(
          columns: ["maturity_date"],
          rows: [
            [.text("2027-01-01")],
            [.text("2027-02-01")],
            [malformed],
            [.blob(Data([0x01]))],
          ]),
        sql: "SELECT maturity_date FROM loans")

      #expect(dataset.chartColumns[0].hints.semanticType == nil)
    }
  }

  @Test func chartLayoutKeepsExplicitHeightsAcrossDependencyDefaultChange() {
    #expect(AutoChartPresentation().plotHeight == 280)
    #expect(AutoChartPresentation.explorer().plotHeight == 280)
    #expect(ResultChartLayout.previewPlotHeight == 156)
    #expect(ResultChartLayout.explorerPlotHeight == 360)
    #expect(
      AutoChartPresentation.preview(
        plotHeight: ResultChartLayout.previewPlotHeight
      ).plotHeight == 156)
    #expect(
      AutoChartPresentation.explorer(
        plotHeight: ResultChartLayout.explorerPlotHeight
      ).plotHeight == 360)

    let preview = AutoChartPresentation.preview(
      plotHeight: ResultChartLayout.previewPlotHeight)
    #expect(preview.typography == .compact)
    #expect(preview.chrome == [.diagnostics])
    #expect(preview.interactions == [])

    let explorer = AutoChartPresentation.explorer(
      plotHeight: ResultChartLayout.explorerPlotHeight)
    #expect(explorer.typography == .standard)
    #expect(explorer.chrome == .all)
    #expect(explorer.interactions == .all)
  }

  @Test func recommendationPolicyVersionRemainsExplicitlyReviewed() {
    #expect(AutoTableCharts.recommendationPolicyVersion == 15)
  }

  @Test func stalePolicySelectionsRebindBySpecificationAndPreserveMode() async throws {
    let result = QueryResult(
      columns: ["fund", "value"],
      rows: [
        [.text("A"), .real(10)],
        [.text("B"), .real(20)],
      ],
      lineage: chartTestCompleteLineage(["fund", "value"]))
    let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
      CREGChartAdapter.analysisRequest(
        result: result,
        sql: "SELECT fund, current_market_value AS value FROM properties",
        question: "Compare value by fund"),
      preparation: .none)
    let current = try #require(
      analysis.cregRecommendationCatalog?.cataloged.first)
    let staleID = AutoChartRecommendationID(
      policyVersion: AutoTableCharts.recommendationPolicyVersion - 1,
      specificationID: current.specification.id)
    #expect(
      resultPresentationMigrationSuggestion(
        analysis: analysis,
        preference: ResultPresentationPreference(
          mode: .chart,
          specificationID: current.id)) == nil)

    for mode in [ResultPresentationMode.chart, .table] {
      let previous = ResultPresentationPreference(
        mode: mode,
        specificationID: staleID)
      let suggestion = try #require(
        resultPresentationMigrationSuggestion(
          analysis: analysis,
          preference: previous))

      #expect(suggestion.previous == previous)
      #expect(suggestion.updated.mode == mode)
      #expect(suggestion.updated.specificationID == current.id)
    }
  }

  @Test func chartAndTableSelectionsRetainValidChoicesBeyondCatalogLimit()
    async throws
  {
    let dimensions = (0..<8).map { "category_\($0)" }
    let measures = (0..<8).map { "measure_\($0)" }
    let names = dimensions + measures
    let rows: [[SQLValue]] = (0..<4).map { row in
      dimensions.indices.map { column in
        .text("D\(column)-R\(row)")
      } + measures.indices.map { column in
        .real(Double((column + 1) * (row + 1)))
      }
    }
    let result = QueryResult(
      columns: names,
      rows: rows,
      lineage: chartTestCompleteLineage(names))
    let sql = "SELECT * FROM properties"
    let dataset = try CREGChartAdapter.analysisDataset(result: result, sql: sql)
    let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
      CREGChartAdapter.analysisRequest(
        result: result, sql: sql, question: nil),
      preparation: .none)
    let catalog = try #require(analysis.cregRecommendationCatalog)
    #expect(catalog.cataloged.count == AutoChartRecommendationCatalog.maximumCatalogedCount)
    let catalogIDs = Set(catalog.cataloged.map(\.id))
    let offCatalog = try #require(
      dimensions.indices.lazy.flatMap { dimension in
        measures.indices.map { measure in
          AutoChartRecommendation(
            specification: .bar(
              category: dataset.chartColumns[dimension].id,
              measure: dataset.chartColumns[dimensions.count + measure].id),
            score: 0,
            rationale: [])
        }
      }.first { candidate in
        !catalogIDs.contains(candidate.id)
          && analysis.resolve(.chart(.specific(candidate.id))).recommendation?.id
            == candidate.id
      })
    let selected = try #require(
      analysis.resolve(.chart(.specific(offCatalog.id))).recommendation)
    let picker = resultChartPickerOptions(
      catalog: catalog, selectedRecommendation: selected)
    #expect(picker.count == 5)
    #expect(picker.last?.id == offCatalog.id)
    #expect(
      picker.prefix(4).map(\.id) == catalog.featured.prefix(4).map(\.id))
    for mode in [ResultPresentationMode.chart, .table] {
      let preference = ResultPresentationPreference(
        mode: mode, specificationID: offCatalog.id)
      #expect(resultPresentationMigrationSuggestion(
        analysis: analysis, preference: preference) == nil)
      let stale = ResultPresentationPreference(
        mode: mode,
        specificationID: AutoChartRecommendationID(
          policyVersion: AutoTableCharts.recommendationPolicyVersion - 1,
          specificationID: offCatalog.specification.id))
      let rebound = try #require(resultPresentationMigrationSuggestion(
        analysis: analysis, preference: stale))
      #expect(rebound.updated.mode == mode)
      #expect(rebound.updated.specificationID == offCatalog.id)
    }
  }

  @Test func unavailableSpecificSelectionsFallBackSilentlyAndPreserveTableMode()
    async throws
  {
    let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
      CREGChartAdapter.analysisRequest(
        result: QueryResult(
          columns: ["fund", "value"],
          rows: [[.text("A"), .real(10)], [.text("B"), .real(20)]],
          lineage: chartTestCompleteLineage(["fund", "value"])),
        sql: "SELECT fund, current_market_value AS value FROM properties",
        question: "Compare value by fund"),
      preparation: .none)
    let unavailable = chartTestRecommendationID(
      "unavailable",
      policyVersion: AutoTableCharts.recommendationPolicyVersion - 1)

    for mode in [ResultPresentationMode.chart, .table] {
      let suggestion = try #require(
        resultPresentationMigrationSuggestion(
          analysis: analysis,
          preference: ResultPresentationPreference(
            mode: mode,
            specificationID: unavailable)))

      #expect(suggestion.updated.mode == mode)
      #expect(suggestion.updated.specificationID == nil)
      #expect(
        suggestion.updated.packagePreference
          == (mode == .chart ? .chart(.recommended) : .table))
    }
  }

  @MainActor
  @Test func staleSpecificSelectionClearsWhenNoChartIsAvailable() async throws {
    let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
      CREGChartAdapter.analysisRequest(
        result: QueryResult(
          columns: ["label"],
          rows: [[.text("Only text")]]),
        sql: "SELECT name AS label FROM properties",
        question: nil),
      preparation: .none)
    #expect(analysis.cregRecommendationCatalog == nil)
    let previous = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID(
        "stale",
        policyVersion: AutoTableCharts.recommendationPolicyVersion - 1))
    let suggestion = try #require(
      resultPresentationMigrationSuggestion(
        analysis: analysis,
        preference: previous))

    #expect(suggestion.updated == .automatic)
    let tablePrevious = previous.selectingMode(.table)
    let tableSuggestion = try #require(resultPresentationMigrationSuggestion(
      analysis: analysis, preference: tablePrevious))
    #expect(tableSuggestion.updated == .table)

    let identity = CREGChartInputIdentity(
      resultFingerprint: "no-chart-one-save",
      dataIdentity: nil,
      sql: "SELECT name AS label FROM properties",
      question: nil)
    let owner = CREGChartSessionOwner(
      client: .testValue,
      inputIdentity: identity,
      result: QueryResult(columns: ["label"], rows: [[.text("Only text")]]))
    owner.load(
      result: QueryResult(columns: ["label"], rows: [[.text("Only text")]]),
      inputIdentity: identity,
      preference: previous.packagePreference)
    var saves = 0
    await applyResultPresentationMigration(
      suggestion,
      analysis: analysis,
      chartOwner: owner
    ) { _, updated in
      saves += 1
      return .migrated(updated)
    }
    #expect(saves == 1)
    #expect(owner.session.preference == .automatic)
  }

  @Test func chartPickerCapsAtFiveAndKeepsAnOffFeaturedSelection() {
    let recommendations = (0..<6).map { index in
      AutoChartRecommendation(
        specification: .bar(
          category: AutoChartColumnID(rawValue: "category-\(index)"),
          measure: "value"),
        score: Double(6 - index),
        rationale: [])
    }
    let catalog = AutoChartRecommendationCatalog(
      featured: Array(recommendations.prefix(5)),
      cataloged: Array(recommendations.prefix(5)),
      preferred: recommendations[5])

    let defaultOptions = resultChartPickerOptions(
      catalog: catalog,
      selectedRecommendation: nil)
    let selectedOptions = resultChartPickerOptions(
      catalog: catalog,
      selectedRecommendation: recommendations[5])
    let featuredSelectedOptions = resultChartPickerOptions(
      catalog: catalog,
      selectedRecommendation: recommendations[2])

    #expect(defaultOptions.map(\.id) == recommendations.prefix(5).map(\.id))
    #expect(selectedOptions.count == 5)
    #expect(
      selectedOptions.map(\.id)
        == recommendations.prefix(4).map(\.id)
          + [recommendations[5].id])
    #expect(featuredSelectedOptions.count == 5)
    #expect(featuredSelectedOptions.map(\.id) == recommendations.prefix(5).map(\.id))
    #expect(Set(featuredSelectedOptions.map(\.id)).count == 5)

    let counter = PickerLabelCounter()
    let resolver = AutoChartTextResolver { message in
      counter.increment()
      return message.defaultText
    }
    let bounded = resultChartPickerOptions(
      catalog: catalog,
      selectedRecommendation: recommendations[5],
      resolver: resolver)
    #expect(bounded.count == 5)
    #expect(counter.calls == 5)
  }

  @Test func chartTypeMenuStaysAvailableAcrossChartFailures() {
    #expect(ResultViewerLogic.shouldShowChartTypeMenu(
      optionCount: 2, requestedMode: .chart, hasFailure: false))
    #expect(ResultViewerLogic.shouldShowChartTypeMenu(
      optionCount: 2, requestedMode: .chart, hasFailure: true))
    #expect(ResultViewerLogic.shouldShowChartTypeMenu(
      optionCount: 2, requestedMode: .table, hasFailure: true))
    #expect(!ResultViewerLogic.shouldShowChartTypeMenu(
      optionCount: 1, requestedMode: .chart, hasFailure: true))
    #expect(!ResultViewerLogic.shouldShowChartTypeMenu(
      optionCount: 2, requestedMode: .table, hasFailure: false))
  }

  @Test func chartPickerSelectionRepresentsOnlyAnActualChoice() {
    let first = chartTestRecommendationID("first")
    let second = chartTestRecommendationID("second")
    let missing = chartTestRecommendationID("missing")
    let options = [first, second]

    #expect(ResultViewerLogic.chartPickerSelectionID(
      selectedRecommendationID: second,
      persistedSpecificationID: first,
      optionIDs: options) == second)
    #expect(ResultViewerLogic.chartPickerSelectionID(
      selectedRecommendationID: nil,
      persistedSpecificationID: second,
      optionIDs: options) == second)
    #expect(ResultViewerLogic.chartPickerSelectionID(
      selectedRecommendationID: nil,
      persistedSpecificationID: missing,
      optionIDs: options) == nil)
    #expect(ResultViewerLogic.chartPickerSelectionID(
      selectedRecommendationID: nil,
      persistedSpecificationID: nil,
      optionIDs: options) == nil)
    #expect(ResultViewerLogic.chartPickerSelectionID(
      selectedRecommendationID: second,
      persistedSpecificationID: first,
      optionIDs: []) == nil)
  }

  @Test func chartTypeSelectionIntentDistinguishesPersistenceAndRecovery() {
    let first = chartTestRecommendationID("first")
    let second = chartTestRecommendationID("second")
    let pinned = ResultPresentationPreference(
      mode: .chart,
      specificationID: first)
    let replacement = ResultPresentationPreference(
      mode: .chart,
      specificationID: second)

    #expect(ResultViewerLogic.chartTypeSelectionIntent(
      first,
      currentlySelectedID: first,
      currentPreference: pinned,
      failureRetryability: nil) == .none)
    #expect(ResultViewerLogic.chartTypeSelectionIntent(
      second,
      currentlySelectedID: first,
      currentPreference: pinned,
      failureRetryability: nil) == .persist(replacement))
    #expect(ResultViewerLogic.chartTypeSelectionIntent(
      first,
      currentlySelectedID: first,
      currentPreference: pinned,
      failureRetryability: true) == .retryChart(nil))
    #expect(ResultViewerLogic.chartTypeSelectionIntent(
      first,
      currentlySelectedID: first,
      currentPreference: .automatic,
      failureRetryability: true) == .retryChart(pinned))
    #expect(ResultViewerLogic.chartTypeSelectionIntent(
      first,
      currentlySelectedID: first,
      currentPreference: pinned,
      failureRetryability: false) == .none)
    #expect(ResultViewerLogic.chartTypeSelectionIntent(
      second,
      currentlySelectedID: first,
      currentPreference: pinned,
      failureRetryability: false) == .retryChart(replacement))
  }

  @MainActor
  @Test func previewAndViewerSessionsWarmReuseOneCREGPackageCache() async throws {
    let cache = AutoChartCache(configuration: CREGChartAnalysisClient.configuration)
    let client = CREGChartAnalysisClient(cache: cache)
    let request = try CREGChartAdapter.analysisRequest(
      result: QueryResult(
        columns: ["property_type", "market_value"],
        rows: [
          [.text("Office"), .real(20_000_000)],
          [.text("Retail"), .real(12_000_000)],
        ]),
      sql: "SELECT property_type, market_value FROM properties",
      question: "Compare market value by property type",
      resultFingerprint: "result-v3",
      dataIdentity: "message-v3")

    let preview = client.makeSession()
    let viewer = client.makeSession()
    preview.load(request, preference: .automatic)
    let previewAnalysis = try await readyAnalysis(from: preview)

    viewer.load(request, preference: .automatic)
    let viewerAnalysis = try await readyAnalysis(from: viewer)

    #expect(preview !== viewer)
    #expect(previewAnalysis.id == viewerAnalysis.id)
    #expect(client.cachedAnalysis(for: request)?.id == previewAnalysis.id)
  }

  @MainActor
  private func readyAnalysis(
    from session: AutoChartSession<Int>
  ) async throws -> AutoChartAnalysis<Int> {
    let state = try await waitForChartSessionState(session) {
      switch $0 {
      case .ready, .fallback: true
      case .idle, .analyzing, .preparing, .failed: false
      }
    }
    switch state {
    case .ready(let analysis, _), .fallback(let analysis, _):
      return analysis
    case .idle, .analyzing, .preparing, .failed:
      preconditionFailure("Settled condition returned an unsettled session state.")
    }
  }
}

@MainActor
@Suite struct CREGSemanticSelectionTests {
  @Test func viewerPreservesAndFiltersIntegerSourceRowIDsThroughSearchAndSort() {
    let result = QueryResult(
      columns: ["fund", "value"],
      rows: [
        [.text("A"), .real(10)],
        [.text("B"), .real(20)],
        [.text("C"), .real(30)],
      ])
    let rows = ResultViewerLogic.identifiedDisplayRows(
      result: result,
      sourceRowIDs: [0, 2],
      sort: .init(column: 1, ascending: false),
      searchText: "a c")

    #expect(rows.isEmpty)

    let sorted = ResultViewerLogic.identifiedDisplayRows(
      result: result,
      sourceRowIDs: [0, 2],
      sort: .init(column: 1, ascending: false),
      searchText: "")
    #expect(sorted.map(\.sourceRowID) == [2, 0])
    #expect(sorted.map(\.values) == [result.rows[2], result.rows[0]])
  }

  @Test func tableRowsDeriveHighlightsAndChartSelectionsUnionBeforeSearchAndSort()
    async throws
  {
    let result = QueryResult(
      columns: ["property_type", "market_value"],
      rows: [
        [.text("Office"), .real(10)],
        [.text("Retail"), .real(20)],
        [.text("Industrial"), .real(30)],
      ])
    let request = try CREGChartAdapter.analysisRequest(
      result: result,
      sql: "SELECT property_type, current_market_value AS market_value FROM properties",
      question: "Compare market value by property type")
    let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
      request, preparation: .primary)
    let chart = try #require(analysis.primaryChart)

    let tableHighlight = CREGChartAdapter.tableSelections(
      in: chart,
      for: [1],
      analysisID: analysis.id)
    #expect(tableHighlight.belongs(to: analysis))
    #expect(tableHighlight.belongs(to: chart))
    #expect(tableHighlight.unionedSourceRows.contains(1))

    let chartSelection = CREGChartAdapter.tableSelections(
      in: chart,
      for: [0, 2],
      analysisID: analysis.id)
    let filtered = ResultViewerLogic.identifiedDisplayRows(
      result: result,
      sourceRowIDs: chartSelection.unionedSourceRows,
      sort: .init(column: 1, ascending: false),
      searchText: "")
    #expect(filtered.map(\.sourceRowID) == [2, 0])
  }

  @Test func aggregateChartSelectionRetainsOnlyTheRequestedTableRow() async throws {
    let result = QueryResult(
      columns: ["category", "value"],
      rows: [
        [.text("A"), .real(10)],
        [.text("A"), .real(20)],
        [.text("B"), .real(30)],
      ])
    let request = try CREGChartAdapter.analysisRequest(
      result: result,
      sql: "SELECT category, SUM(value) AS value FROM properties GROUP BY category",
      question: "Compare total value by category")
    let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
      request, preparation: .none)
    let chart = try await analysis.prepare(
      AutoChartSpecification(
        .bar(
          category: CREGChartAdapter.columnID(index: 0, name: "category"),
          measure: CREGChartAdapter.columnID(index: 1, name: "value"),
          aggregation: .sum,
          orientation: .vertical,
          sort: .source,
          title: "")))
    let aggregateMark = try #require(
      chart.marks.first { $0.sourceRowIDs == [0, 1] })
    let packageSelection = chart.selections(
      for: [0], analysisID: analysis.id)

    let selection = CREGChartAdapter.tableSelections(
      in: chart,
      for: [0],
      analysisID: analysis.id)

    #expect(packageSelection.unionedSourceRows == [0, 1])
    #expect(selection.count == 1)
    #expect(selection.first?.markID == aggregateMark.identity)
    #expect(selection.unionedSourceRows == [0])
  }

  @Test func userSelectionCancelsPendingRestorationBeforeBindingAssignment()
    async throws
  {
    let result = QueryResult(
      columns: ["category", "value"],
      rows: [
        [.text("A"), .real(10)],
        [.text("B"), .real(20)],
        [.text("C"), .real(30)],
      ])
    let request = try CREGChartAdapter.analysisRequest(
      result: result,
      sql: "SELECT property_type AS category, current_market_value AS value FROM properties",
      question: "Compare value by category")
    let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
      request, preparation: .primary)
    let chart = try #require(analysis.primaryChart)
    let previousSelection = chart.selections(for: [0], analysisID: analysis.id)
    let userSelection = chart.selections(for: [2], analysisID: analysis.id)
    let session = AutoChartSession<Int>()
    session.selection = previousSelection
    var lifecycle = ResultViewerLogic.ChartSelectionLifecycle(
      initialChartSourceRows: previousSelection.unionedSourceRows)
    lifecycle.pendingSelectionApplied(
      sourceRows: previousSelection.unionedSourceRows)
    lifecycle.prepareForSessionRestart()

    lifecycle.chartSelectionChanged(
      sourceRows: userSelection.unionedSourceRows)
    session.selection = userSelection
    if let staleRows = lifecycle.pendingSourceRows {
      session.selection = chart.selections(
        for: staleRows, analysisID: analysis.id)
    }

    #expect(lifecycle.pendingSourceRows == nil)
    #expect(lifecycle.restorableSourceRows == [2])
    #expect(session.selection.unionedSourceRows == [2])
  }

  @Test func pendingChartUpdateDefersSourceRowRestoration() {
    #expect(
      ResultViewerLogic.sourceRowsForChartRestoration(
        pendingSourceRows: [1, 2],
        isChartUpdatePending: true) == nil)
    #expect(
      ResultViewerLogic.sourceRowsForChartRestoration(
        pendingSourceRows: [1, 2],
        isChartUpdatePending: false) == [1, 2])
  }

  @Test func chartFailureDiagnosticsRetainPackageEpisodeProvenance() throws {
    let recorder = DiagnosticEventRecorder()
    let client = CREGChartAnalysisClient.testValue
    let failure = AutoChartFailure(
      stage: .chartPreparation,
      kind: .invalidSpecification,
      isRetryable: false,
      diagnosticID: "ATC.chartPreparation.invalidSpecification",
      message: "The chart specification is invalid.")
    recordChartFailure(
      failure,
      chartAnalysis: client,
      diagnostics: recorder.client)
    recordChartFailure(
      failure,
      chartAnalysis: client,
      diagnostics: recorder.client)

    let event = try #require(recorder.events.first)
    #expect(recorder.events.count == 1)
    #expect(event.code == failure.diagnosticID)
    #expect(event.context["stage"] == failure.stage.rawValue)
    #expect(event.context["kind"] == failure.kind.rawValue)
    #expect(
      event.context["episode_id"]
        == failure.episodeID.uuidString.lowercased()
          .replacingOccurrences(of: "-", with: ""))
  }

  @Test func requestConstructionFailuresShareAnEpisodeAcrossSurfaces() {
    let client = CREGChartAnalysisClient.testValue
    let inputIdentity = CREGChartInputIdentity(
      resultFingerprint: "failed-result",
      dataIdentity: "message-result",
      sql: "SELECT value FROM properties",
      question: "Show property values")

    let previewFailure = client.requestConstructionFailure(
      inputIdentity: inputIdentity,
      kind: .invalidData,
      message: "The chart dataset is invalid.")
    let viewerFailure = client.requestConstructionFailure(
      inputIdentity: inputIdentity,
      kind: .invalidData,
      message: "The chart dataset is invalid.")
    let differentFailure = client.requestConstructionFailure(
      inputIdentity: inputIdentity,
      kind: .invalidData,
      message: "A different dataset validation failed.")
    let otherFailure = client.requestConstructionFailure(
      inputIdentity: CREGChartInputIdentity(
        resultFingerprint: "other-result",
        dataIdentity: "other-message-result",
        sql: inputIdentity.sql,
        question: inputIdentity.question),
      kind: .invalidData,
      message: "The chart dataset is invalid.")

    #expect(previewFailure.episodeID == viewerFailure.episodeID)
    #expect(previewFailure.episodeID != differentFailure.episodeID)
    #expect(previewFailure.episodeID != otherFailure.episodeID)
  }

  @Test func minimumMemoryTrimPreservesRequestFailureEpisodes() async {
    let client = CREGChartAnalysisClient.testValue
    let inputIdentity = CREGChartInputIdentity(
      resultFingerprint: "failed-result",
      dataIdentity: "message-result",
      sql: "SELECT value FROM properties",
      question: "Show property values")
    let first = client.requestConstructionFailure(
      inputIdentity: inputIdentity,
      kind: .invalidData,
      message: "The chart dataset is invalid.")

    await client.trimToMinimum()

    let recreated = client.requestConstructionFailure(
      inputIdentity: inputIdentity,
      kind: .invalidData,
      message: "The chart dataset is invalid.")
    #expect(first.episodeID == recreated.episodeID)
  }

  @Test func minimumMemoryTrimPreservesClaimedFailureEpisodes() async {
    let client = CREGChartAnalysisClient.testValue
    let failure = AutoChartFailure(
      stage: .chartPreparation,
      kind: .invalidSpecification,
      isRetryable: true,
      diagnosticID: "ATC.chartPreparation.invalidSpecification",
      message: "The chart specification is invalid.")

    #expect(client.claimFailureEpisode(failure))
    await client.trimToMinimum()
    #expect(!client.claimFailureEpisode(failure))
  }
}

@MainActor
@Suite struct ResultPresentationPersistenceTests {
  @Test func legacyPreferenceRetainsItsModeAndChartType() throws {
    let message = chartTestAnswerMessage()
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(message))
        as? [String: Any])
    object["resultPresentation"] = [
      "mode": "chart", "specificationID": "1:2|3:bar",
    ]

    let decoded = try JSONDecoder().decode(
      ChatMessage.self,
      from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.resultPresentation.mode == .chart)
    #expect(decoded.resultPresentation.specificationID?.policyVersion == 2)
    #expect(
      decoded.resultPresentation.specificationID?.specificationID.rawValue
        == "3:bar")

    let reencoded = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded))
        as? [String: Any])
    let preference = try #require(
      reencoded["resultPresentation"] as? [String: Any])
    #expect(preference["mode"] as? String == "chart")
    #expect(preference["specificationID"] != nil)
  }

  @Test func legacyMessageWithoutPreferenceDecodesAsAutomatic() throws {
    let message = chartTestAnswerMessage()
    let encoded = try JSONEncoder().encode(message)
    var object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "resultPresentation")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(ChatMessage.self, from: legacyData)
    #expect(decoded.resultPresentation == .automatic)
  }

  @Test func legacyTablePreferenceDoesNotBecomeAutomaticChart() throws {
    let message = chartTestAnswerMessage()
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(message))
        as? [String: Any])
    object["resultPresentation"] = ["mode": "table"]

    let decoded = try JSONDecoder().decode(
      ChatMessage.self,
      from: JSONSerialization.data(withJSONObject: object))

    #expect(decoded.resultPresentation == .table)
    #expect(decoded.resultPresentation.packagePreference == .table)
  }

  @Test func tableRoundTripRetainsTheLastExplicitChartType() {
    let id = chartTestRecommendationID("policy|line|date|value")
    let chart = ResultPresentationPreference.chart(.specific(id))

    let table = chart.selectingMode(.table)
    let restored = table.selectingMode(.chart)

    #expect(table.mode == .table)
    #expect(table.specificationID == id)
    #expect(table.packagePreference == .table)
    #expect(restored == chart)
    #expect(restored.packagePreference == .chart(.specific(id)))
  }

  @Test func firstV3PackagePreferencePayloadStillDecodes() throws {
    let packagePreference = AutoChartPreference.chart(.recommended)
    let decoded = try JSONDecoder().decode(
      ResultPresentationPreference.self,
      from: JSONEncoder().encode(packagePreference))

    #expect(decoded == .chart(.recommended))
  }

  @Test func preferenceRoundTripsAndSurvivesPreparedFinalization() throws {
    let preference = ResultPresentationPreference(
      mode: .chart, specificationID: chartTestRecommendationID("policy|bar|fund|value"))
    var message = chartTestAnswerMessage()
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
    let message = chartTestAnswerMessage()
    let preference = ResultPresentationPreference(
      mode: .table, specificationID: chartTestRecommendationID("policy|bar|fund|value"))
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
      mode: .chart, specificationID: chartTestRecommendationID("policy|line|date|value"))
    _ = try await history.createConversation(
      conversationID, Date(timeIntervalSince1970: 0))
    var message = chartTestAnswerMessage()
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
    let message = chartTestAnswerMessage()
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
      mode: .table, specificationID: chartTestRecommendationID("policy|bar|fund|value"))

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

@MainActor
@Suite struct ResultPresentationMigrationHandlerTests {
  @Test func pendingPresentationSameChartRebindDoesNotRestartRestoration()
    async throws
  {
    let result = QueryResult(
      columns: ["property_type", "current_market_value"],
      rows: [
        [.text("Office"), .real(20_000_000)],
        [.text("Retail"), .real(12_000_000)],
        [.text("Industrial"), .real(15_000_000)],
      ])
    let identity = CREGChartInputIdentity(
      resultFingerprint: "pending-presentation-same-chart-rebind",
      dataIdentity: nil,
      sql: "SELECT property_type, current_market_value FROM properties",
      question: "Compare value by type")
    let owner = CREGChartSessionOwner(
      client: CREGChartAnalysisClient(cache: AutoChartCache()),
      inputIdentity: identity,
      result: result)
    defer { owner.session.cancel() }
    owner.load(result: result, inputIdentity: identity, preference: .automatic)
    let (_, presented) = try await waitForReadyChart(owner.session)

    let callback = ChartPresentationBlockingCallback()
    defer { callback.release() }
    owner.session.setPresentationContext(
      .init(identity: "pending-same-chart-rebind"),
      formatters: AutoChartFormatters(
        cacheIdentity: "pending-same-chart-rebind",
        request: { _, _, _ in
          callback.invoke()
          return nil
        }))
    try await waitForChartSessionState(owner.session, timeout: .seconds(5)) { _ in
      callback.isBlocked
    }
    #expect(owner.session.isChartUpdatePending)
    let restorationAttempt = owner.selectionRestorationAttempt
    var restarts = 0

    let application = owner.setPreferenceIfNeeded(
      .chart(.specific(presented.preparedChart.recommendation.id)),
      onRestart: { restarts += 1 })

    #expect(application == .reusedPreparedChart)
    #expect(owner.session.isChartUpdatePending)
    #expect(owner.selectionRestorationAttempt == restorationAttempt)
    #expect(restarts == 0)
    callback.release()
    try await waitForChartSessionState(owner.session, timeout: .seconds(5)) { _ in
      !callback.isBlocked
    }
    #expect(!callback.didTimeOut)
  }

  @Test func preferenceReplacementSignalsOneRestorationAttempt() async throws {
    let result = QueryResult(
      columns: ["property_type", "current_market_value"],
      rows: [
        [.text("Office"), .real(20_000_000)],
        [.text("Retail"), .real(12_000_000)],
        [.text("Industrial"), .real(15_000_000)],
      ])
    let identity = CREGChartInputIdentity(
      resultFingerprint: "preference-replacement-restoration",
      dataIdentity: nil,
      sql: "SELECT property_type, current_market_value FROM properties",
      question: "Compare value by type")
    let owner = CREGChartSessionOwner(
      client: CREGChartAnalysisClient(cache: AutoChartCache()),
      inputIdentity: identity,
      result: result)
    defer { owner.session.cancel() }
    owner.load(result: result, inputIdentity: identity, preference: .automatic)
    let (analysis, presented) = try await waitForReadyChart(owner.session)
    let alternative = try #require(
      analysis.cregRecommendationCatalog?.cataloged.first {
        $0.id != presented.preparedChart.recommendation.id
      })
    let restorationAttempt = owner.selectionRestorationAttempt
    var restarts = 0

    let application = owner.setPreferenceIfNeeded(
      .chart(.specific(alternative.id)),
      onRestart: { restarts += 1 })

    #expect(application == .startedReplacement)
    #expect(restarts == 1)
    #expect(owner.selectionRestorationAttempt == restorationAttempt + 1)
    #expect(owner.session.preference == .chart(.specific(alternative.id)))
  }

  @Test func differentPreparedChartReuseSignalsRestoration() async throws {
    let result = QueryResult(
      columns: ["property_type", "current_market_value"],
      rows: [
        [.text("Office"), .real(20_000_000)],
        [.text("Retail"), .real(12_000_000)],
        [.text("Industrial"), .real(15_000_000)],
      ])
    let identity = CREGChartInputIdentity(
      resultFingerprint: "prepared-chart-reuse-restoration",
      dataIdentity: nil,
      sql: "SELECT property_type, current_market_value FROM properties",
      question: "Compare value by type")
    let owner = CREGChartSessionOwner(
      client: CREGChartAnalysisClient(cache: AutoChartCache()),
      inputIdentity: identity,
      result: result,
      preparation: .allCataloged)
    defer { owner.session.cancel() }
    owner.load(result: result, inputIdentity: identity, preference: .automatic)
    let (analysis, presented) = try await waitForReadyChart(owner.session)
    let presentedSpecificationID =
      presented.preparedChart.recommendation.specification.id
    let alternative = try #require(
      analysis.cregRecommendationCatalog?.cataloged.first {
        $0.specification.id != presentedSpecificationID
          && analysis.preparedCharts[$0.id] != nil
      })
    let restorationAttempt = owner.selectionRestorationAttempt
    var restarts = 0

    let application = owner.setPreferenceIfNeeded(
      .chart(.specific(alternative.id)),
      onRestart: { restarts += 1 })

    #expect(application == .reusedPreparedChart)
    #expect(restarts == 1)
    #expect(owner.selectionRestorationAttempt == restorationAttempt + 1)
    #expect(owner.session.currentRecommendation?.specification.id
      == alternative.specification.id)
  }

  @Test func reentrantReplacementCoalescesRestorationAndPersistsNewestChoice()
    async throws
  {
    let result = QueryResult(
      columns: ["property_type", "current_market_value"],
      rows: [
        [.text("Office"), .real(20_000_000)],
        [.text("Retail"), .real(12_000_000)],
        [.text("Industrial"), .real(15_000_000)],
      ])
    let identity = CREGChartInputIdentity(
      resultFingerprint: "reentrant-preference-persistence",
      dataIdentity: nil,
      sql: "SELECT property_type, current_market_value FROM properties",
      question: "Compare value by type")
    let owner = CREGChartSessionOwner(
      client: CREGChartAnalysisClient(cache: AutoChartCache()),
      inputIdentity: identity,
      result: result)
    defer { owner.session.cancel() }
    owner.load(result: result, inputIdentity: identity, preference: .automatic)
    let (analysis, presented) = try await waitForReadyChart(owner.session)
    let alternative = try #require(
      analysis.cregRecommendationCatalog?.cataloged.first {
        $0.id != presented.preparedChart.recommendation.id
      })
    let outerPreference = ResultPresentationPreference.chart(
      .specific(alternative.id))
    let restorationAttempt = owner.selectionRestorationAttempt
    var persisted: [ResultPresentationPreference] = []
    var restarts = 0
    let observation = ChartTestObservationLoop()
    observation.track {
      _ = owner.session.preference
    } onChange: {
      observation.cancel()
      applyResultPresentationPreference(
        .table,
        chartOwner: owner,
        persistPreference: { persisted.append($0) },
        beforeSessionRestart: { restarts += 1 })
    }

    let application = applyResultPresentationPreference(
      outerPreference,
      chartOwner: owner,
      persistPreference: { persisted.append($0) },
      beforeSessionRestart: { restarts += 1 })

    #expect(application == .superseded)
    #expect(owner.session.preference == .table)
    #expect(persisted == [.table])
    #expect(restarts == 1)
    #expect(owner.selectionRestorationAttempt == restorationAttempt + 1)
  }

  @Test func cancellationSupersessionPersistsStillCurrentPreference() async throws {
    let result = QueryResult(
      columns: ["property_type", "current_market_value"],
      rows: [
        [.text("Office"), .real(20_000_000)],
        [.text("Retail"), .real(12_000_000)],
        [.text("Industrial"), .real(15_000_000)],
      ])
    let identity = CREGChartInputIdentity(
      resultFingerprint: "cancelled-preference-persistence",
      dataIdentity: nil,
      sql: "SELECT property_type, current_market_value FROM properties",
      question: "Compare value by type")
    let owner = CREGChartSessionOwner(
      client: CREGChartAnalysisClient(cache: AutoChartCache()),
      inputIdentity: identity,
      result: result)
    defer { owner.session.cancel() }
    owner.load(result: result, inputIdentity: identity, preference: .automatic)
    let (analysis, presented) = try await waitForReadyChart(owner.session)
    let alternative = try #require(
      analysis.cregRecommendationCatalog?.cataloged.first {
        $0.id != presented.preparedChart.recommendation.id
      })
    let updated = ResultPresentationPreference.chart(.specific(alternative.id))
    let restorationAttempt = owner.selectionRestorationAttempt
    var persisted: [ResultPresentationPreference] = []
    var restarts = 0
    let observation = ChartTestObservationLoop()
    observation.track {
      _ = owner.session.preference
    } onChange: {
      observation.cancel()
      owner.session.setPreference(updated.packagePreference)
      owner.session.cancel()
    }

    let application = applyResultPresentationPreference(
      updated,
      chartOwner: owner,
      persistPreference: { persisted.append($0) },
      beforeSessionRestart: { restarts += 1 })

    #expect(application == .superseded)
    #expect(owner.session.preference == updated.packagePreference)
    #expect(persisted == [updated])
    #expect(restarts == 1)
    #expect(owner.selectionRestorationAttempt == restorationAttempt + 1)
    guard case .idle = owner.session.state else {
      Issue.record("Cancellation supersession did not leave the session idle.")
      return
    }
  }

  @Test func sessionWaitPropagatesCancellation() async {
    let session = AutoChartSession<Int>(cache: AutoChartCache())
    let waiter = Task {
      try await waitForChartSessionState(session) { _ in false }
    }
    await Task.yield()

    waiter.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await waiter.value
    }
  }

  #if ATC_TEST_HOOKS
  @Test func sessionWaitThrowsPackageFailureImmediately() async throws {
    let result = QueryResult(
      columns: ["fund", "value"],
      rows: [[.text("A"), .real(10)], [.text("B"), .real(20)]])
    let identity = CREGChartInputIdentity(
      resultFingerprint: "session-wait-failure",
      dataIdentity: nil,
      sql: "SELECT fund, value FROM properties",
      question: "Compare value by fund")
    let owner = CREGChartSessionOwner(
      client: CREGChartAnalysisClient(cache: AutoChartCache()),
      inputIdentity: identity,
      result: result)
    defer { owner.session.cancel() }
    owner.load(result: result, inputIdentity: identity, preference: .automatic)
    let failure = AutoChartFailure(
      stage: .chartPreparation,
      kind: .internalFailure,
      isRetryable: true,
      diagnosticID: "CREG.test.waitFailure",
      message: "A controlled package failure.")
    owner.session.failCurrentAttemptForTesting(failure)

    do {
      try await waitForChartSessionState(owner.session) { _ in false }
      Issue.record("The session wait ignored a terminal package failure.")
    } catch let received as AutoChartFailure {
      #expect(received.diagnosticID == failure.diagnosticID)
    }
  }
  #endif

  @Test func cachedChartPreparationKeepsChartModeThroughTableToChartChoice()
    async throws
  {
    let result = QueryResult(
      columns: ["fund", "value"],
      rows: [[.text("A"), .real(10)], [.text("B"), .real(20)]])
    let identity = CREGChartInputIdentity(
      resultFingerprint: "cached-chart-mode",
      dataIdentity: nil,
      sql: "SELECT property_type AS fund, current_market_value AS value FROM properties",
      question: "Compare value by fund")
    let cache = AutoChartCache()
    let request = try CREGChartAdapter.analysisRequest(
      result: result,
      sql: identity.sql,
      question: identity.question,
      resultFingerprint: identity.resultFingerprint)
    let base = try await AutoChartAnalyzer(cache: cache).analyze(
      request, preparation: .none)
    let primary = try #require(base.cregRecommendationCatalog?.primary)
    let owner = CREGChartSessionOwner(
      client: CREGChartAnalysisClient(cache: cache),
      inputIdentity: identity,
      result: result)
    owner.load(result: result, inputIdentity: identity, preference: .table)
    owner.setPreferenceIfNeeded(.chart(.recommended))

    #expect(owner.displayedMode(for: identity, fallback: .table) == .chart)
    #expect(owner.displayedRecommendation(for: identity)?.id == primary.id)
    let analysis = owner.analysis(for: identity)
    #expect(owner.hasPendingChart(for: identity, analysis: analysis))
    #expect(ResultViewerLogic.effectivePresentationMode(
      requestedMode: .chart,
      hasChart: owner.hasPendingChart(for: identity, analysis: analysis),
      chartFailed: false) == .chart)
  }

  @Test func pendingChartRejectsAnalysisFromAnotherRequest() async throws {
    let result = QueryResult(
      columns: ["fund", "value"],
      rows: [[.text("A"), .real(10)], [.text("B"), .real(20)]])
    let identity = CREGChartInputIdentity(
      resultFingerprint: "pending-current",
      dataIdentity: nil,
      sql: "SELECT fund, value FROM properties",
      question: "Compare value by fund")
    var foreignIdentity = identity
    foreignIdentity.resultFingerprint = "pending-foreign"
    let cache = AutoChartCache()
    let foreignRequest = try CREGChartAdapter.analysisRequest(
      result: result,
      sql: foreignIdentity.sql,
      question: foreignIdentity.question,
      resultFingerprint: foreignIdentity.resultFingerprint)
    let foreignAnalysis = try await AutoChartAnalyzer(cache: cache).analyze(
      foreignRequest,
      preparation: .none)
    let owner = CREGChartSessionOwner(
      client: CREGChartAnalysisClient(cache: cache),
      inputIdentity: identity,
      result: result)

    owner.load(result: result, inputIdentity: identity, preference: .automatic)

    #expect(!owner.hasPendingChart(for: identity, analysis: foreignAnalysis))
    owner.session.cancel()
  }

  @Test func newIdentityCannotDisplayOldChartBeforeItsLoadTask() async throws {
    let result = QueryResult(
      columns: ["fund", "value"],
      rows: [[.text("A"), .real(10)], [.text("B"), .real(20)]])
    let old = CREGChartInputIdentity(
      resultFingerprint: "identity-old-chart",
      dataIdentity: nil,
      sql: "SELECT fund, value FROM properties",
      question: "Compare value by fund")
    var replacement = old
    replacement.resultFingerprint = "identity-new-result"
    let cache = AutoChartCache()
    let request = try CREGChartAdapter.analysisRequest(
      result: result,
      sql: old.sql,
      question: old.question,
      resultFingerprint: old.resultFingerprint)
    let base = try await AutoChartAnalyzer(cache: cache).analyze(
      request, preparation: .none)
    let owner = CREGChartSessionOwner(
      client: CREGChartAnalysisClient(cache: cache),
      inputIdentity: old,
      result: result)
    owner.load(result: result, inputIdentity: old, preference: .automatic)
    #expect(owner.displayedRecommendation(for: old)?.id
      == base.cregRecommendationCatalog?.primary?.id)

    // SwiftUI may render with the new input before .task(id:) runs. Its body
    // must see only fallback state for that identity in this exact interval.
    #expect(owner.displayedRecommendation(for: replacement) == nil)
    #expect(owner.analysis(for: replacement)?.id == nil)
    #expect(owner.displayedMode(for: replacement, fallback: .table) == .table)
    #expect(!owner.hasPendingChart(
      for: replacement, analysis: owner.analysis(for: replacement)))
  }

  #if ATC_TEST_HOOKS
  @Test func terminalFailureAlternativeRetriesAndPersistsSelection() async throws {
    let result = QueryResult(
      columns: ["fund", "value"],
      rows: [[.text("A"), .real(10)], [.text("B"), .real(20)]])
    let identity = CREGChartInputIdentity(
      resultFingerprint: "terminal-alternative",
      dataIdentity: nil,
      sql: "SELECT property_type AS fund, current_market_value AS value FROM properties",
      question: "Compare value by fund")
    let cache = AutoChartCache()
    let request = try CREGChartAdapter.analysisRequest(
      result: result,
      sql: identity.sql,
      question: identity.question,
      resultFingerprint: identity.resultFingerprint)
    let base = try await AutoChartAnalyzer(cache: cache).analyze(
      request,
      preparation: .none)
    let catalog = try #require(base.cregRecommendationCatalog)
    let selected = try #require(catalog.primary)
    let alternative = try #require(catalog.cataloged.first { $0.id != selected.id })
    let owner = CREGChartSessionOwner(
      client: CREGChartAnalysisClient(cache: cache),
      inputIdentity: identity,
      result: result)
    let currentPreference = ResultPresentationPreference.chart(.specific(selected.id))
    owner.load(
      result: result,
      inputIdentity: identity,
      preference: currentPreference.packagePreference)
    let firstFailure = AutoChartFailure(
      stage: .chartPreparation,
      kind: .invalidSpecification,
      isRetryable: false,
      diagnosticID: "ATC.test.terminalAlternative",
      message: "The selected chart is invalid.")
    owner.session.failCurrentAttemptForTesting(firstFailure)
    var persisted: [ResultPresentationPreference] = []
    let intent = ResultViewerLogic.chartTypeSelectionIntent(
      alternative.id,
      currentlySelectedID: selected.id,
      currentPreference: currentPreference,
      failureRetryability: false)
    let updatedPreference = ResultPresentationPreference.chart(
      .specific(alternative.id))
    #expect(intent == .retryChart(updatedPreference))
    let attemptBeforeSelection = owner.selectionRestorationAttempt

    applyResultPresentationModeSelection(
      intent,
      chartOwner: owner,
      persistPreference: { persisted.append($0) })

    guard case .preparing = owner.session.state else {
      Issue.record("A terminal failure alternative did not start a fresh attempt.")
      return
    }
    #expect(persisted == [updatedPreference])
    #expect(owner.session.preference == updatedPreference.packagePreference)
    #expect(owner.selectionRestorationAttempt == attemptBeforeSelection + 1)
  }

  @Test func failedOffFeaturedChartStaysSelectedAndSameChoiceRetries()
    async throws
  {
    let dimensions = (0..<8).map { "category_\($0)" }
    let measures = (0..<8).map { "measure_\($0)" }
    let names = dimensions + measures
    let rows: [[SQLValue]] = (0..<4).map { row in
      dimensions.indices.map { column in
        .text("D\(column)-R\(row)")
      } + measures.indices.map { column in
        .real(Double((column + 1) * (row + 1)))
      }
    }
    let result = QueryResult(
      columns: names,
      rows: rows,
      lineage: chartTestCompleteLineage(names))
    let identity = CREGChartInputIdentity(
      resultFingerprint: "failed-off-featured-chart",
      dataIdentity: nil,
      sql: "SELECT * FROM properties",
      question: nil)
    let cache = AutoChartCache()
    let request = try CREGChartAdapter.analysisRequest(
      result: result,
      sql: identity.sql,
      question: nil,
      resultFingerprint: identity.resultFingerprint)
    let base = try await AutoChartAnalyzer(cache: cache).analyze(
      request, preparation: .none)
    let catalog = try #require(base.cregRecommendationCatalog)
    let featuredIDs = Set(catalog.featured.map(\.id))
    let selected = try #require(catalog.cataloged.first {
      !featuredIDs.contains($0.id)
    })
    let owner = CREGChartSessionOwner(
      client: CREGChartAnalysisClient(cache: cache),
      inputIdentity: identity,
      result: result)
    owner.load(
      result: result,
      inputIdentity: identity,
      preference: .chart(.specific(selected.id)))
    owner.session.failCurrentAttemptForTesting(AutoChartFailure(
      stage: .chartPreparation,
      kind: .internalFailure,
      isRetryable: true,
      diagnosticID: "ATC.test.offFeaturedFailure",
      message: "A controlled chart failure."))

    #expect(owner.failure(for: identity)?.isRetryable == true)
    let visible = try #require(owner.displayedRecommendation(for: identity))
    #expect(visible.id == selected.id)
    let options = owner.pickerOptions(
      analysis: owner.analysis(for: identity),
      selectedRecommendation: visible)
    #expect(options.last?.id == selected.id)
    #expect(options.count == AutoChartRecommendationCatalog.maximumFeaturedCount)

    #expect(owner.retry(preference: .chart(.specific(selected.id))))
    guard case .preparing = owner.session.state else {
      Issue.record("Choosing the selected chart type did not retry.")
      return
    }
    #expect(owner.displayedRecommendation(for: identity)?.id == selected.id)
    owner.session.cancel()
  }
  #endif

  @Test func failedNewRequestCannotRestartThePreviousResult() throws {
    let result = QueryResult(
      columns: ["fund", "value"],
      rows: [[.text("A"), .real(10)], [.text("B"), .real(20)]])
    let old = CREGChartInputIdentity(
      resultFingerprint: "old-request",
      dataIdentity: nil,
      sql: "SELECT fund, value FROM properties",
      question: "Compare value by fund")
    var replacement = old
    replacement.resultFingerprint = "failed-new-request"
    let client = CREGChartAnalysisClient(cache: AutoChartCache())
    let owner = CREGChartSessionOwner(
      client: client,
      inputIdentity: old,
      result: result,
      requestFactory: { client, result, identity in
        if identity == replacement {
          return (
            nil,
            client.requestConstructionFailure(
              inputIdentity: identity,
              kind: .invalidData,
              message: "The new result cannot form a chart request."))
        }
        return (
          try! CREGChartAdapter.analysisRequest(
            result: result,
            sql: identity.sql,
            question: identity.question,
            resultFingerprint: identity.resultFingerprint),
          nil)
      })
    owner.load(result: result, inputIdentity: old, preference: .automatic)
    owner.load(result: result, inputIdentity: replacement, preference: .automatic)
    #expect(owner.failure(for: replacement) != nil)
    #expect(owner.analysis(for: replacement) == nil)
    owner.setPreferenceIfNeeded(.chart(.recommended))
    guard case .idle = owner.session.state else {
      Issue.record("A preference change restarted the previous request.")
      return
    }
    #expect(owner.displayedRecommendation(for: replacement) == nil)
  }

  @Test func drawnChartAndChromeStayAlignedUntilMigrationActuallySucceeds()
    async throws
  {
    let result = QueryResult(
      columns: ["property_type", "current_market_value"],
      rows: [
        [.text("Office"), .real(20_000_000)],
        [.text("Retail"), .real(12_000_000)],
        [.text("Industrial"), .real(15_000_000)],
      ])
    let identity = CREGChartInputIdentity(
      resultFingerprint: "drawn-chart-migration",
      dataIdentity: nil,
      sql: "SELECT property_type, current_market_value FROM properties",
      question: "Compare value by type")
    let owner = CREGChartSessionOwner(
      client: CREGChartAnalysisClient(cache: AutoChartCache()),
      inputIdentity: identity,
      result: result)
    defer { owner.session.cancel() }
    owner.load(result: result, inputIdentity: identity, preference: .automatic)
    let (analysis, drawn) = try await waitForReadyChart(owner.session)
    var replacementIdentity = identity
    replacementIdentity.resultFingerprint = "next-result"
    #expect(owner.displayedRecommendation(for: replacementIdentity) == nil)
    #expect(owner.displayedMode(
      for: replacementIdentity, fallback: .table) == .table)
    #expect(owner.displayedRecommendation(for: identity)?.id
      == drawn.preparedChart.recommendation.id)
    let drawnID = drawn.preparedChart.recommendation.id
    let staleID = AutoChartRecommendationID(
      policyVersion: AutoTableCharts.recommendationPolicyVersion - 1,
      specificationID: drawn.preparedChart.recommendation.specification.id)
    let previous = ResultPresentationPreference(
      mode: .chart, specificationID: staleID)
    owner.setPreferenceIfNeeded(previous.packagePreference)
    let suggestion = try #require(resultPresentationMigrationSuggestion(
      analysis: analysis, preference: previous))
    let restorationAttempt = owner.selectionRestorationAttempt
    var restarts = 0

    await applyResultPresentationMigration(
      suggestion,
      analysis: analysis,
      chartOwner: owner,
      beforeSessionRestart: { restarts += 1 },
      migratePreference: { _, _ in .messageMissing })
    #expect(owner.session.preference == previous.packagePreference)
    #expect(owner.selectionRestorationAttempt == restorationAttempt)
    #expect(restarts == 0)

    let other = ResultPresentationPreference(
      mode: .chart, specificationID: chartTestRecommendationID("other-stale"))
    var missingAttempts = 0
    await applyResultPresentationMigration(
      suggestion,
      analysis: analysis,
      chartOwner: owner,
      beforeSessionRestart: { restarts += 1 },
      migratePreference: { _, _ in
        missingAttempts += 1
        return missingAttempts == 1 ? .retained(other) : .messageMissing
      })
    #expect(missingAttempts == 2)
    #expect(owner.session.preference == other.packagePreference)
    #expect(owner.selectionRestorationAttempt == restorationAttempt + 1)
    #expect(restarts == 1)
    owner.setPreferenceIfNeeded(previous.packagePreference)
    restarts = 0

    var attempts = 0
    await applyResultPresentationMigration(
      suggestion,
      analysis: analysis,
      chartOwner: owner,
      beforeSessionRestart: { restarts += 1 },
      migratePreference: { _, _ in
        attempts += 1
        return .retained(attempts == 1 ? other : previous)
      })
    #expect(attempts == 2)
    #expect(owner.session.preference == previous.packagePreference)
    #expect(restarts == 0)

    if case .ready(let activeAnalysis, let presented?) = owner.session.state {
      let displayed = presented.preparedChart.recommendation
      let picker = owner.pickerOptions(
        analysis: activeAnalysis, selectedRecommendation: displayed)
      #expect(displayed.id == drawnID)
      #expect(presented.preparedChart.id == drawn.preparedChart.id)
      #expect(picker.contains { $0.id == displayed.id })
      #expect(activeAnalysis.resolve(owner.session.preference).recommendation?.id == drawnID)
    } else {
      Issue.record("Migration changed the drawn chart before persistence succeeded")
    }

    let restorationAttemptBeforeSuccess = owner.selectionRestorationAttempt
    await applyResultPresentationMigration(
      suggestion,
      analysis: analysis,
      chartOwner: owner,
      beforeSessionRestart: { restarts += 1 },
      migratePreference: { _, updated in .migrated(updated) })
    #expect(owner.session.preference == .chart(.specific(drawnID)))
    #expect(owner.selectionRestorationAttempt == restorationAttemptBeforeSuccess)
    #expect(restarts == 0)
    if case .ready(let updatedAnalysis, let presented?) = owner.session.state {
      #expect(presented.preparedChart.id == drawn.preparedChart.id)
      #expect(updatedAnalysis.preferenceResolution?.recommendation?.id == drawnID)
    } else {
      Issue.record("Same-chart rebind unexpectedly entered preparation")
    }
  }

  @Test func loadedRetryChangesPreferenceInOneOwnerAttempt() {
    let result = QueryResult(
      columns: ["fund", "value"],
      rows: [
        [.text("A"), .real(10)],
        [.text("B"), .real(20)],
      ])
    let inputIdentity = CREGChartInputIdentity(
      resultFingerprint: "atomic-retry-result",
      dataIdentity: nil,
      sql: "SELECT fund, value FROM properties",
      question: "Compare value by fund")
    let chartOwner = CREGChartSessionOwner(
      client: .testValue,
      inputIdentity: inputIdentity,
      result: result)
    chartOwner.load(
      result: result,
      inputIdentity: inputIdentity,
      preference: .automatic)
    let previousAttempt = chartOwner.selectionRestorationAttempt
    var restartCount = 0

    let didStart = chartOwner.retry(
      preference: .chart(.recommended),
      beforeRestart: { restartCount += 1 })

    #expect(didStart)
    #expect(restartCount == 1)
    #expect(chartOwner.selectionRestorationAttempt == previousAttempt + 1)
    #expect(chartOwner.session.preference == .chart(.recommended))
  }

  @Test func unloadedRetryDoesNotPersistAnUnappliedPreference() {
    let result = QueryResult(
      columns: ["fund", "value"],
      rows: [[.text("A"), .real(10)]])
    let inputIdentity = CREGChartInputIdentity(
      resultFingerprint: "unloaded-retry-result",
      dataIdentity: nil,
      sql: "SELECT fund, value FROM properties",
      question: "Compare value by fund")
    let chartOwner = CREGChartSessionOwner(
      client: .testValue,
      inputIdentity: inputIdentity,
      result: result)
    let updated = ResultPresentationPreference.chart(.recommended)
    var persisted: [ResultPresentationPreference] = []
    var restartCount = 0

    applyResultPresentationModeSelection(
      .retryChart(updated),
      chartOwner: chartOwner,
      persistPreference: { persisted.append($0) },
      beforeSessionRestart: { restartCount += 1 })

    #expect(persisted.isEmpty)
    #expect(restartCount == 0)
    #expect(chartOwner.selectionRestorationAttempt == 0)
    #expect(chartOwner.session.preference == .automatic)
  }

  @Test func acceptedMigrationReturnsTheStoredPreference() {
    let previous = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID("policy|stale"))
    let updated = ResultPresentationPreference.chart(.recommended)
    var message = chartTestAnswerMessage()
    message.resultPresentation = previous
    var state = ChatFeature.State(conversationID: UUID())
    state.messages.append(message)
    let store = migrationStore(state: state)

    let outcome = resultPresentationMigrationHandler(
      store: store,
      messageID: message.id
    )(previous, updated)

    #expect(outcome == .migrated(updated))
    #expect(store.messages[id: message.id]?.resultPresentation == updated)
  }

  @MainActor
  @Test func standaloneViewerBindingPersistsSelectionsAndMigratesWithCompareAndSet() {
    var stored = ResultPresentationPreference.automatic
    let binding = Binding(
      get: { stored },
      set: { stored = $0 })
    let viewer = ResultViewerView(
      result: QueryResult(
        columns: ["fund", "value"],
        rows: [[.text("A"), .real(10)], [.text("B"), .real(20)]]),
      runtimeMode: .evaluated,
      textSize: .constant(.standard),
      preference: binding)

    viewer.persistPreference(.table)
    #expect(stored == .table)
    #expect(viewer.preference == .table)

    let previous = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID(
        "stale",
        policyVersion: AutoTableCharts.recommendationPolicyVersion - 1))
    let updated = ResultPresentationPreference.chart(.recommended)
    stored = previous
    #expect(viewer.preference == previous)
    #expect(viewer.migratePreference(previous, updated) == .migrated(updated))
    #expect(stored == updated)
    #expect(viewer.preference == updated)

    stored = .automatic
    #expect(
      viewer.migratePreference(previous, updated)
        == .retained(.automatic))
    #expect(stored == .automatic)
  }

  @Test func rejectedMigrationReturnsTheAuthoritativePreference() {
    let previous = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID("policy|stale"))
    let updated = ResultPresentationPreference.chart(.recommended)
    let message = chartTestAnswerMessage()
    var state = ChatFeature.State(conversationID: UUID())
    state.messages.append(message)
    let store = migrationStore(state: state)

    let outcome = resultPresentationMigrationHandler(
      store: store,
      messageID: message.id
    )(previous, updated)

    #expect(outcome == .retained(.automatic))
    #expect(store.messages[id: message.id]?.resultPresentation == .automatic)
  }

  @Test func missingMessageRemainsDistinctFromRetainedAutomatic() {
    let previous = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID("policy|stale"))
    let store = migrationStore(
      state: ChatFeature.State(conversationID: UUID()))

    let outcome = resultPresentationMigrationHandler(
      store: store,
      messageID: UUID()
    )(previous, .chart(.recommended))

    #expect(outcome == .messageMissing)
  }

  @Test func retainedStalePreferenceWithSameReplacementIsReconciled() async throws {
    let result = QueryResult(
      columns: ["fund", "value"],
      rows: [
        [.text("A"), .real(10)],
        [.text("B"), .real(20)],
      ])
    let request = try CREGChartAdapter.analysisRequest(
      result: result,
      sql: "SELECT property_type AS fund, current_market_value AS value FROM properties",
      question: "Compare value by fund")
    let previous = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID("missing-first"))
    let authoritative = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID("missing-second"))
    let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
      request,
      preference: previous.packagePreference,
      preparation: .none)
    let tableSuggestion = try #require(
      resultPresentationMigrationSuggestion(
        analysis: analysis,
        preference: previous.selectingMode(.table)))
    #expect(tableSuggestion.updated == .table)
    let suggestion = try #require(
      resultPresentationMigrationSuggestion(
        analysis: analysis,
        preference: previous))
    let inputIdentity = CREGChartInputIdentity(
      resultFingerprint: "migration-result",
      dataIdentity: nil,
      sql: "SELECT property_type AS fund, current_market_value AS value FROM properties",
      question: "Compare value by fund")
    let chartOwner = CREGChartSessionOwner(
      client: .testValue,
      inputIdentity: inputIdentity,
      result: result)
    chartOwner.load(
      result: result,
      inputIdentity: inputIdentity,
      preference: .automatic)
    let restorationAttemptBeforeMigration =
      chartOwner.selectionRestorationAttempt
    var attempts: [(ResultPresentationPreference, ResultPresentationPreference)] = []
    var sessionRestarts = 0

    await applyResultPresentationMigration(
      suggestion,
      analysis: analysis,
      chartOwner: chartOwner,
      beforeSessionRestart: { sessionRestarts += 1 }
    ) { receivedPrevious, updated in
      attempts.append((receivedPrevious, updated))
      return attempts.count == 1
        ? .retained(authoritative)
        : .migrated(updated)
    }

    #expect(attempts.count == 2)
    #expect(attempts[0].0 == previous)
    #expect(attempts[1].0 == authoritative)
    #expect(attempts[1].1 == .chart(.recommended))
    #expect(sessionRestarts == 1)
    #expect(
      chartOwner.selectionRestorationAttempt
        == restorationAttemptBeforeMigration + 1)
    #expect(chartOwner.session.preference == .chart(.recommended))
  }

  @Test func retainedMigrationStopsWhenItsResultIdentityChanges() async throws {
    let result = QueryResult(
      columns: ["fund", "value"],
      rows: [[.text("A"), .real(10)], [.text("B"), .real(20)]])
    let sql = "SELECT fund, value FROM properties"
    let previous = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID("missing-old"))
    let authoritative = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID("missing-authoritative"))
    let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
      CREGChartAdapter.analysisRequest(
        result: result, sql: sql, question: nil),
      preparation: .none)
    let suggestion = try #require(resultPresentationMigrationSuggestion(
      analysis: analysis, preference: previous))
    let old = CREGChartInputIdentity(
      resultFingerprint: "migration-old-result",
      dataIdentity: nil,
      sql: sql,
      question: nil)
    var replacement = old
    replacement.resultFingerprint = "migration-replacement-result"
    let owner = CREGChartSessionOwner(
      client: CREGChartAnalysisClient(cache: AutoChartCache()),
      inputIdentity: old,
      result: result)
    owner.load(result: result, inputIdentity: old, preference: .automatic)
    var attempts = 0

    await applyResultPresentationMigration(
      suggestion,
      analysis: analysis,
      chartOwner: owner,
      isStillCurrent: { owner.inputIdentity == old }
    ) { _, _ in
      attempts += 1
      owner.load(
        result: result,
        inputIdentity: replacement,
        preference: .automatic)
      return .retained(authoritative)
    }

    #expect(attempts == 1)
    #expect(owner.inputIdentity == replacement)
    #expect(owner.session.preference == .automatic)
  }

  private func migrationStore(
    state: ChatFeature.State
  ) -> StoreOf<ChatFeature> {
    Store(initialState: state) {
      ChatFeature()
    } withDependencies: {
      $0.historyClient = .noop()
    }
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
