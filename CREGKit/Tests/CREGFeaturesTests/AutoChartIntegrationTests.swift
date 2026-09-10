import AutoTableCharts
import AutoTableChartsUI
import CREGData
import ComposableArchitecture
import Foundation
import SwiftUI
import Testing

@testable import CREGEngine
@testable import CREGFeatures

@Suite struct CREGChartAdapterTests {
  @Test func topLevelProjectionParsingHandlesCTEsCommentsAndNestedFunctions() {
    let projections = CREGChartAdapter.topLevelProjections(
      """
      WITH active AS (
        SELECT property_id, annual_base_rent FROM leases
      )
      SELECT p.name AS property,
             /* FROM fake, ignored comma */ SUM(COALESCE(a.annual_base_rent, 0)) AS rent,
             'from, inside a literal' AS note
      FROM active a JOIN properties p ON p.property_id = a.property_id
      """)

    #expect(projections.count == 3)
    #expect(projections[0].contains("p.name AS property"))
    #expect(CREGChartAdapter.aggregate(in: projections[1]) == .sum)
    #expect(projections[2].contains("from, inside a literal"))
  }

  @Test func aggregateDetectionRejectsWindowedAndStringValues() {
    #expect(CREGChartAdapter.aggregate(in: "COUNT(DISTINCT tenant_id)") == .countDistinct)
    #expect(CREGChartAdapter.aggregate(in: "COALESCE(SUM(value), 0)") == .sum)
    #expect(CREGChartAdapter.aggregate(in: "checksum(value)") == nil)
    #expect(CREGChartAdapter.aggregate(in: "'SUM(fake)' AS label") == nil)
    #expect(
      CREGChartAdapter.aggregate(
        in: "SUM(value) OVER (PARTITION BY fund_id)") == nil)
  }

  @Test func analysisDatasetUsesOffsetIDsTypedSemanticsAndStableDataKey() throws {
    let result = QueryResult(
      columns: ["loan_id", "current_balance", "maturity_date"],
      rows: [
        [.integer(42), .real(1_250_000), .text("2027-03-15")],
        [.integer(43), .real(900_000), .text("2028-01-01")],
      ])
    let fingerprint = PreparedFollowUpIntegrity.fingerprint(result: result)
    let sql = "SELECT loan_id, SUM(current_balance), MAX(maturity_date) FROM loans"
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
    // A bump invalidates persisted chart-type pins. Keep this exact assertion
    // separate from the version-agnostic migration behavior test.
    #expect(AutoTableCharts.recommendationPolicyVersion == 12)
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
    for _ in 0..<200 {
      switch session.state {
      case .ready(let analysis, _), .fallback(let analysis, _):
        return analysis
      case .failed(let failure):
        throw failure
      case .idle, .analyzing, .preparing:
        try await Task.sleep(for: .milliseconds(5))
      }
    }
    throw AutoChartFailure(
      stage: .presentationPreparation,
      kind: .transient,
      isRetryable: true,
      diagnosticID: "CREG.test.sessionTimeout",
      message: "The chart session did not settle during the test.")
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
      sql: "SELECT property_type, market_value FROM properties",
      question: "Compare market value by property type")
    let analysis = try await AutoChartAnalyzer(cache: AutoChartCache()).analyze(
      request, preparation: .primary)
    let chart = try #require(analysis.primaryChart)

    let tableHighlight = chart.selections(for: [1], analysisID: analysis.id)
    #expect(tableHighlight.belongs(to: analysis))
    #expect(tableHighlight.belongs(to: chart))
    #expect(tableHighlight.unionedSourceRows.contains(1))

    let chartSelection = chart.selections(for: [0, 2], analysisID: analysis.id)
    let filtered = ResultViewerLogic.identifiedDisplayRows(
      result: result,
      sourceRowIDs: chartSelection.unionedSourceRows,
      sort: .init(column: 1, ascending: false),
      searchText: "")
    #expect(filtered.map(\.sourceRowID) == [2, 0])
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

  @Test func minimumMemoryTrimReleasesRequestFailureEpisodes() async {
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
    #expect(first.episodeID != recreated.episodeID)
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
      sql: "SELECT fund, value FROM properties",
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
    #expect(
      resultPresentationMigrationSuggestion(
        analysis: analysis,
        preference: previous.selectingMode(.table)) == nil)
    let suggestion = try #require(
      resultPresentationMigrationSuggestion(
        analysis: analysis,
        preference: previous))
    let inputIdentity = CREGChartInputIdentity(
      resultFingerprint: "migration-result",
      dataIdentity: nil,
      sql: "SELECT fund, value FROM properties",
      question: "Compare value by fund")
    let chartOwner = CREGChartSessionOwner(
      client: .testValue,
      inputIdentity: inputIdentity,
      result: result)
    var attempts: [(ResultPresentationPreference, ResultPresentationPreference)] = []
    var sessionRestarts = 0

    applyResultPresentationMigration(
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
    #expect(sessionRestarts == 2)
    #expect(chartOwner.selectionRestorationAttempt == 2)
    #expect(chartOwner.session.preference == .chart(.recommended))
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
