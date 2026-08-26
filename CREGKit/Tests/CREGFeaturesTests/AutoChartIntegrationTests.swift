import AutoTableCharts
import CREGData
import ComposableArchitecture
import Foundation
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

  @Test func analysisInputUsesOffsetIDsTypedSemanticsAndStableDataKey() throws {
    let result = QueryResult(
      columns: ["loan_id", "current_balance", "maturity_date"],
      rows: [
        [.integer(42), .real(1_250_000), .text("2027-03-15")],
        [.integer(43), .real(900_000), .text("2028-01-01")],
      ])
    let fingerprint = PreparedFollowUpIntegrity.fingerprint(result: result)
    let sql = "SELECT loan_id, SUM(current_balance), MAX(maturity_date) FROM loans"
    let input = try CREGChartAdapter.analysisInput(
      result: result,
      sql: sql,
      question: "What matures next?",
      resultFingerprint: fingerprint,
      dataIdentity: "conversation-result")

    #expect(input.dataset.chartRows.map(\.chartRowID) == [0, 1])
    #expect(input.dataset.chartColumns[0].hints.semanticType == .identifier)
    #expect(
      input.dataset.chartColumns[1].hints.measureSemantics
        == AutoChartMeasureSemantics(
          source: .aggregated(.sum), rollup: .additive,
          preferredTransform: .sum))
    #expect(input.dataset.chartColumns[2].hints.semanticType == .temporal)
    #expect(
      input.dataset.chartRows[0]
        .chartValue(for: input.dataset.chartColumns[2].id).dateValue != nil)
    #expect(input.dataset.chartDataKey?.identity == "conversation-result")
    #expect(
      input.dataset.chartDataKey?.revision
        == CREGChartAdapter.dataKeyRevision(resultFingerprint: fingerprint, sql: sql))
    #expect(input.context.goal == .range)
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

    let input = try CREGChartAdapter.analysisInput(
      result: result,
      sql: "SELECT fund, current_market_value FROM properties",
      question: nil)

    #expect(input.dataset.chartRows.count == 2)
    let valueColumn = input.dataset.chartColumns[1].id
    #expect(
      input.dataset.chartRows[0].chartValue(for: valueColumn) == .null)
    #expect(
      input.dataset.chartRows[1].chartValue(for: valueColumn)
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
  }

  @Test func recommendationPolicyVersionRemainsExplicitlyReviewed() {
    // A bump invalidates persisted chart-type pins. Keep this exact assertion
    // separate from the version-agnostic migration behavior test.
    #expect(AutoTableCharts.recommendationPolicyVersion == 10)
  }
}

@Suite struct CREGChartAnalysisClientTests {
  @Test func liveConfigurationUsesTheAppOwnedBudget() {
    let configuration = CREGChartAnalysisClient.configuration
    #expect(configuration.tables.maximumEntries == 8)
    #expect(configuration.analyses.maximumEntries == 64)
    #expect(configuration.preparedCharts.maximumEntries == 16)
    // Literal pins, not the subtraction the source performs: the 32 MiB
    // app-wide contract and its split are the regression surface here.
    #expect(
      CREGChartAnalysisClient.maximumRetainedCost == 32 * 1_024 * 1_024)
    #expect(
      CREGChartAnalysisClient.snapshotMaximumRetainedCost == 8 * 1_024 * 1_024)
    #expect(configuration.maximumRetainedCost == 24 * 1_024 * 1_024)
  }

  @Test func primaryIsEagerAndAlternativePreparationIsExplicit() async throws {
    let client = CREGChartAnalysisClient(
      analyzer: AutoChartAnalyzer(configuration: .uncached))
    let analysis = try await client.analyze(
      result: PreviewFixtures.fundValueResult,
      sql: StarterQueryID.portfolioValueByFundV1.sql,
      question: StarterQueryID.portfolioValueByFundV1.question)
    let recommendations = chartTestRecommendations(from: analysis)

    let primary = try #require(analysis.primaryChart)
    #expect(primary.recommendation.id == recommendations.first?.id)
    #expect(!primary.marks.isEmpty)
    if recommendations.count > 1 {
      let alternative = try await analysis.prepare(recommendations[1].id)
      #expect(alternative.recommendation.id == recommendations[1].id)
      #expect(alternative.recommendation.id != primary.recommendation.id)
    }
  }

  @Test func keyedAnalysisReusesScopedStateAndTrimKeepsHeldValuesUsable() async throws {
    let analyzer = AutoChartAnalyzer(
      configuration: AutoChartAnalyzerConfiguration(
        tables: .init(maximumEntries: 8),
        analyses: .init(maximumEntries: 8),
        preparedCharts: .init(maximumEntries: 8),
        maximumRetainedCost: 8 * 1_024 * 1_024))
    let client = CREGChartAnalysisClient(analyzer: analyzer)
    let first = try await client.analyze(
      result: PreviewFixtures.fundValueResult,
      sql: StarterQueryID.portfolioValueByFundV1.sql,
      question: StarterQueryID.portfolioValueByFundV1.question,
      resultFingerprint: "stable-result",
      dataIdentity: "message-1")
    let second = try await client.analyze(
      result: PreviewFixtures.fundValueResult,
      sql: StarterQueryID.portfolioValueByFundV1.sql,
      question: StarterQueryID.portfolioValueByFundV1.question,
      resultFingerprint: "stable-result",
      dataIdentity: "message-1")

    #expect(first.primaryChart?.recommendation.id == second.primaryChart?.recommendation.id)
    let heldPrimary = try #require(first.primaryChart)
    let beforeTrim = await client.cacheStatistics
    #expect(beforeTrim.analyses.hits >= 1)
    #expect(beforeTrim.analyses.entries == 1)
    #expect(client.snapshotStatistics.entries == 1)

    await client.trimToMinimum()
    let afterTrim = await client.cacheStatistics
    #expect(afterTrim.tables.entries == 0)
    #expect(afterTrim.analyses.entries == 0)
    #expect(afterTrim.preparedCharts.entries == 0)
    #expect(client.snapshotStatistics.entries == 0)
    #expect(client.snapshotStatistics.retainedCost == 0)
    #expect(!heldPrimary.marks.isEmpty)
  }

  @Test func snapshotLRUEnforcesByteBudgetRevisionAndTrim() async throws {
    let uncached = CREGChartAnalysisClient(
      analyzer: AutoChartAnalyzer(configuration: .uncached),
      snapshots: .uncached)
    let analysis = try await uncached.analyze(
      result: PreviewFixtures.fundValueResult,
      sql: StarterQueryID.portfolioValueByFundV1.sql,
      question: StarterQueryID.portfolioValueByFundV1.question)
    let snapshots = ChartAnalysisSnapshotStore(
      capacity: 3, maximumRetainedCost: 100)
    let contextKey = ChartAnalysisSnapshotContextKey(question: nil)

    snapshots.store(
      analysis, identity: "first", revision: "r1", contextKey: contextKey,
      retainedCost: 60)
    snapshots.store(
      analysis, identity: "second", revision: "r1", contextKey: contextKey,
      retainedCost: 60)

    #expect(
      snapshots.analysis(
        identity: "first", revision: "r1", contextKey: contextKey) == nil)
    #expect(
      snapshots.analysis(
        identity: "second", revision: "stale", contextKey: contextKey) == nil)
    #expect(
      snapshots.analysis(
        identity: "second", revision: "r1", contextKey: contextKey) != nil)
    #expect(snapshots.statistics.entries == 1)
    #expect(snapshots.statistics.retainedCost == 60)
    #expect(snapshots.statistics.evictions == 1)

    // A same-identity, same-revision store is a recency refresh, never a
    // replacement: the retained cost must not change.
    snapshots.store(
      analysis, identity: "second", revision: "r1", contextKey: contextKey,
      retainedCost: 999)
    #expect(snapshots.statistics.entries == 1)
    #expect(snapshots.statistics.retainedCost == 60)

    // A snapshot larger than the whole budget still warm-starts — large
    // results are where re-analysis hurts most — evicting everything else
    // and remaining as the sole resident.
    snapshots.store(
      analysis, identity: "oversized", revision: "r1", contextKey: contextKey,
      retainedCost: 101)
    #expect(snapshots.statistics.entries == 1)
    #expect(snapshots.statistics.retainedCost == 101)
    #expect(
      snapshots.analysis(
        identity: "oversized", revision: "r1", contextKey: contextKey) != nil)
    #expect(snapshots.statistics.evictions == 2)

    // Memory-pressure trims clear everything but are not LRU evictions.
    snapshots.trimToMinimum()
    #expect(snapshots.statistics.entries == 0)
    #expect(snapshots.statistics.retainedCost == 0)
    #expect(snapshots.statistics.evictions == 2)
  }

  @Test func contextReplacementUpdatesCostAndMismatchPreservesCurrentSnapshot() async throws {
    let uncached = CREGChartAnalysisClient(
      analyzer: AutoChartAnalyzer(configuration: .uncached),
      snapshots: .uncached)
    let analysis = try await uncached.analyze(
      result: PreviewFixtures.fundValueResult,
      sql: StarterQueryID.portfolioValueByFundV1.sql,
      question: StarterQueryID.portfolioValueByFundV1.question)
    let snapshots = ChartAnalysisSnapshotStore(
      capacity: 2, maximumRetainedCost: 1_000)
    let original = ChartAnalysisSnapshotContextKey(question: "Original title")
    let replacement = ChartAnalysisSnapshotContextKey(question: "Replacement title")

    snapshots.store(
      analysis, identity: "message", revision: "r1", contextKey: original,
      retainedCost: 40)
    snapshots.store(
      analysis, identity: "message", revision: "r1", contextKey: replacement,
      retainedCost: 70)

    #expect(snapshots.statistics.entries == 1)
    #expect(snapshots.statistics.retainedCost == 70)
    #expect(
      snapshots.analysis(
        identity: "message", revision: "r1", contextKey: original) == nil)
    #expect(
      snapshots.analysis(
        identity: "message", revision: "r1", contextKey: replacement) != nil)
    #expect(snapshots.statistics.entries == 1)
    #expect(snapshots.statistics.retainedCost == 70)
    #expect(snapshots.statistics.evictions == 0)
  }

  @Test func defaultTestDependencyNeverWarmStartsAcrossRequests() async throws {
    let client = CREGChartAnalysisClient.testValue
    let sql = StarterQueryID.portfolioValueByFundV1.sql
    _ = try await client.analyze(
      result: PreviewFixtures.fundValueResult,
      sql: sql,
      question: StarterQueryID.portfolioValueByFundV1.question,
      resultFingerprint: "test-result",
      dataIdentity: "shared-test-identity")

    #expect(
      client.cachedAnalysis(
        resultFingerprint: "test-result",
        sql: sql,
        question: StarterQueryID.portfolioValueByFundV1.question,
        dataIdentity: "shared-test-identity") == nil)
    #expect(client.snapshotStatistics.entries == 0)
    #expect(client.snapshotStatistics.retainedCost == 0)
  }

  @MainActor
  @Test func warmStartRequiresMatchingTitleWhenGoalIsUnchanged() async throws {
    let client = CREGChartAnalysisClient(
      analyzer: AutoChartAnalyzer(configuration: .uncached))
    let result = PreviewFixtures.fundValueResult
    let sql = StarterQueryID.portfolioValueByFundV1.sql
    let originalQuestion = "Rank portfolio value"
    let replacementQuestion = "Rank portfolio value across funds"
    let resultFingerprint = "context-sensitive-result"
    let dataIdentity = "context-sensitive-message"
    let originalContext = CREGChartAdapter.analysisContext(
      question: originalQuestion, sql: sql)
    let replacementContext = CREGChartAdapter.analysisContext(
      question: replacementQuestion, sql: sql)

    #expect(originalContext.goal == replacementContext.goal)
    #expect(originalContext.title != replacementContext.title)

    let original = try await client.analyze(
      result: result,
      sql: sql,
      question: originalQuestion,
      resultFingerprint: resultFingerprint,
      dataIdentity: dataIdentity)
    #expect(
      original.primaryChart?.recommendation.specification.title
        == originalQuestion)
    #expect(
      client.cachedAnalysis(
        resultFingerprint: resultFingerprint,
        sql: sql,
        question: originalQuestion,
        dataIdentity: dataIdentity) != nil)
    #expect(
      client.cachedAnalysis(
        resultFingerprint: resultFingerprint,
        sql: sql,
        question: replacementQuestion,
        dataIdentity: dataIdentity) == nil)

    let replacementRequest = ResultChartLoader.Request(
      result: result,
      sql: sql,
      question: replacementQuestion,
      resultFingerprint: resultFingerprint,
      dataIdentity: dataIdentity)
    let loader = ResultChartLoader(
      client: client,
      warmStart: replacementRequest)
    #expect(loader.analysis == nil)

    _ = await loader.analyze(
      replacementRequest,
      preferredSpecificationID: nil)

    #expect(
      loader.analysis?.primaryChart?.recommendation.specification.title
        == replacementQuestion)
    #expect(
      client.cachedAnalysis(
        resultFingerprint: resultFingerprint,
        sql: sql,
        question: originalQuestion,
        dataIdentity: dataIdentity) == nil)
    #expect(
      client.cachedAnalysis(
        resultFingerprint: resultFingerprint,
        sql: sql,
        question: replacementQuestion,
        dataIdentity: dataIdentity) != nil)
  }

  @Test func analyzersAreIsolatedAndTestsNeedNoGlobalSerialization() async throws {
    let first = CREGChartAnalysisClient(
      analyzer: AutoChartAnalyzer(configuration: .standard))
    let second = CREGChartAnalysisClient(
      analyzer: AutoChartAnalyzer(configuration: .standard))
    _ = try await first.analyze(
      result: PreviewFixtures.fundValueResult,
      sql: StarterQueryID.portfolioValueByFundV1.sql,
      question: nil)

    let firstStatistics = await first.cacheStatistics
    let secondStatistics = await second.cacheStatistics
    #expect(firstStatistics.analyses.entries == 1)
    #expect(secondStatistics.analyses.entries == 0)
  }

  /// Two result revisions can resolve to the same chart specification. The
  /// preparation task must still restart for the replacement analysis, while
  /// selecting an alternative or explicitly retrying re-keys the same analysis.
  @MainActor
  @Test func preparationTaskIdentityIncludesAnalysisRecommendationAndRetry() async throws {
    let client = CREGChartAnalysisClient(
      analyzer: AutoChartAnalyzer(configuration: .uncached),
      snapshots: .uncached)
    let firstResult = PreviewFixtures.fundValueResult
    let secondResult = QueryResult(
      columns: firstResult.columns,
      rows: [
        [.text("Meridian Core Fund I"), .real(430_000_000)],
        [.text("Meridian Value-Add II"), .real(275_000_000)],
        [.text("Harborline Opportunistic"), .real(160_000_000)],
        [.text("Coastal Core-Plus III"), .real(105_000_000)],
      ])
    let sql = StarterQueryID.portfolioValueByFundV1.sql
    let question = StarterQueryID.portfolioValueByFundV1.question
    let loader = ResultChartLoader(client: client, warmStart: nil)

    _ = await loader.analyze(
      chartTestRequest(
        result: firstResult,
        sql: sql,
        question: question,
        resultFingerprint: "first-revision",
        dataIdentity: "message-1"),
      preferredSpecificationID: nil)
    let firstRecommendationID = try #require(
      loader.analysis?.primaryChart?.recommendation.id)
    let firstKey = loader.preparationTaskKey(
      recommendationID: firstRecommendationID)

    _ = await loader.analyze(
      chartTestRequest(
        result: secondResult,
        sql: sql,
        question: question,
        resultFingerprint: "second-revision",
        dataIdentity: "message-1"),
      preferredSpecificationID: nil)
    let secondRecommendationID = try #require(
      loader.analysis?.primaryChart?.recommendation.id)
    try #require(firstRecommendationID == secondRecommendationID)
    let replacementKey = loader.preparationTaskKey(
      recommendationID: secondRecommendationID)
    let recommendations = chartTestRecommendations(
      from: try #require(loader.analysis))
    let alternativeID = try #require(recommendations.dropFirst().first?.id)
    let alternativeKey = loader.preparationTaskKey(
      recommendationID: alternativeID)
    loader.retryPreparation()
    let retryKey = loader.preparationTaskKey(
      recommendationID: alternativeID)

    #expect(firstKey != replacementKey)
    #expect(replacementKey != alternativeKey)
    #expect(alternativeKey != retryKey)
  }
}

@MainActor
@Suite struct CREGSemanticSelectionTests {
  @Test func viewerFiltersDirectlyWithIntegerSourceRowIDs() {
    let result = QueryResult(
      columns: ["fund", "value"],
      rows: [
        [.text("A"), .real(10)],
        [.text("B"), .real(20)],
        [.text("C"), .real(30)],
      ])
    let selection = AutoChartSelection<Int>(
      sourceRowIDs: [0, 2],
      family: .bar,
      specificationID: AutoChartSpecification.bar(
        category: "fund", measure: "value").id,
      markID: "selected")
    let view = ResultViewerView(
      result: result,
      runtimeMode: .evaluated,
      textSize: .constant(.standard),
      initialChartSelection: selection)

    #expect(view.filteredResult.rows == [result.rows[0], result.rows[2]])
  }
}

@MainActor
@Suite struct ResultPresentationPersistenceTests {
  @Test func legacyLengthPrefixedRecommendationIDDecodesAndReencodesTyped() throws {
    let legacy = Data(
      #"{"mode":"chart","specificationID":"1:2|3:bar"}"#.utf8)
    let preference = try JSONDecoder().decode(
      ResultPresentationPreference.self, from: legacy)

    #expect(preference.specificationID?.policyVersion == 2)
    #expect(preference.specificationID?.specificationID.rawValue == "3:bar")
    let encoded = try JSONEncoder().encode(preference)
    let object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["specificationID"] is [String: Any])
  }

  @Test func legacyMessageWithoutPreferenceDecodesAsAutomatic() throws {
    let message = chartTestAnswerMessage()
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
