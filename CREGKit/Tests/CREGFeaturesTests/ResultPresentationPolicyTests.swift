import AutoTableCharts
import ComposableArchitecture
import Foundation
import Testing

@testable import CREGEngine
@testable import CREGFeatures

@Suite struct ResultPresentationPolicyTests {
  @Test func preparationFailureDisplaysTableAndAllowsPersistingTable() {
    let specificationID = chartTestRecommendationID("policy|line|date|value")

    #expect(
      ResultViewerLogic.effectivePresentationMode(
        requestedMode: .chart,
        hasChart: true,
        preparationFailed: true) == .table)
    let intent = ResultViewerLogic.modeSelectionIntent(
      .table,
      requestedMode: .chart,
      preserving: specificationID,
      preparationFailed: true)
    guard case .persist(let changed) = intent else {
      Issue.record("Keeping the visible fallback must persist Table.")
      return
    }
    #expect(changed.mode == .table)
    #expect(changed.specificationID == specificationID)
  }

  @Test func preparationFailureProducesAnExplicitRetryIntent() {
    #expect(
      ResultViewerLogic.modeSelectionIntent(
        .chart,
        requestedMode: .chart,
        preserving: chartTestRecommendationID("policy|line|date|value"),
        preparationFailed: true) == .retryChart(nil))
  }

  @Test func automaticModeSelectionDoesNotPinTheResolvedChart() {
    let intent = ResultViewerLogic.modeSelectionIntent(
      .table,
      requestedMode: .chart,
      preserving: nil,
      preparationFailed: false)

    #expect(
      intent == .persist(
        ResultPresentationPreference(
          mode: .table,
          specificationID: nil)))
  }

  @Test func selectingChartFromFailedTablePersistsAndRetries() {
    let specificationID = chartTestRecommendationID("policy|line|date|value")

    #expect(
      ResultViewerLogic.modeSelectionIntent(
        .chart,
        requestedMode: .table,
        preserving: specificationID,
        preparationFailed: true) == .retryChart(
          ResultPresentationPreference(
            mode: .chart,
            specificationID: specificationID)))
  }

  @Test func staleChartSpecificationMigratesToTheResolvedRecommendation() throws {
    let staleID = chartTestRecommendationID("old-policy|line|date|value")
    let resolvedID = chartTestRecommendationID("new-policy|bar|fund|value")
    let preference = ResultPresentationPreference(
      mode: .table,
      specificationID: staleID)

    let migrated = try #require(
      ResultViewerLogic.migratedPreference(
        preference,
        resolvedSpecificationID: resolvedID))

    #expect(migrated.mode == .table)
    #expect(migrated.specificationID == resolvedID)
    #expect(
      ResultViewerLogic.migratedPreference(
        migrated,
        resolvedSpecificationID: resolvedID) == nil)
    #expect(
      ResultViewerLogic.migratedPreference(
        nil,
        resolvedSpecificationID: resolvedID) == nil)
  }

  @Test func policyVersionBumpDoesNotOverwriteAnExplicitChartPick() {
    let currentVersion = AutoTableCharts.recommendationPolicyVersion
    let previousVersion = currentVersion == 0 ? 1 : currentVersion - 1
    let storedID = chartTestRecommendationID(
      "policy|line|date|value",
      policyVersion: previousVersion)
    let resolvedID = chartTestRecommendationID("policy|bar|fund|value")
    let preference = ResultPresentationPreference(
      mode: .chart,
      specificationID: storedID)

    #expect(
      ResultViewerLogic.migratedPreference(
        preference,
        resolvedSpecificationID: resolvedID) == nil)
  }
}

@MainActor
@Suite struct ResultChartLoaderSupersessionTests {
  @Test func supersededRecommendationCannotFailAfterNewerSuccess() async throws {
    let client = CREGChartAnalysisClient(
      analyzer: AutoChartAnalyzer(configuration: .uncached),
      snapshots: .uncached)
    let gate = SupersededChartPreparationGate()
    let loader = ResultChartLoader(
      client: client,
      warmStart: nil,
      prepareChart: { analysis, recommendationID in
        try await gate.prepare(analysis, recommendationID: recommendationID)
      })
    _ = await loader.analyze(
      ResultChartLoader.Request(
        result: PreviewFixtures.fundValueResult,
        sql: StarterQueryID.portfolioValueByFundV1.sql,
        question: StarterQueryID.portfolioValueByFundV1.question,
        resultFingerprint: "superseded-preparation",
        dataIdentity: "message-1"),
      preferredSpecificationID: nil)
    let analysis = try #require(loader.analysis)
    let recommendations: [AutoChartRecommendation]
    switch analysis.outcome {
    case .charts(let values): recommendations = values
    case .tableFallback: recommendations = []
    }
    let primary = try #require(recommendations.first)
    let alternative = try #require(recommendations.dropFirst().first)

    let first = Task { await loader.prepareSelected(alternative) }
    await gate.waitUntilFirstPreparationStarts()
    await loader.prepareSelected(primary)
    #expect(loader.preparedChart?.recommendation.id == primary.id)
    #expect(!loader.preparationFailed)

    await gate.releaseFirstPreparation()
    await first.value
    #expect(loader.preparedChart?.recommendation.id == primary.id)
    #expect(!loader.preparationFailed)
  }

  @Test func explicitRetryClearsFailureAndRekeysTheRecommendation() async throws {
    let client = CREGChartAnalysisClient(
      analyzer: AutoChartAnalyzer(configuration: .uncached),
      snapshots: .uncached)
    let loader = ResultChartLoader(
      client: client,
      warmStart: nil,
      prepareChart: { _, _ in
        throw PreferenceSaveTestError.failed
      })
    _ = await loader.analyze(
      ResultChartLoader.Request(
        result: PreviewFixtures.fundValueResult,
        sql: StarterQueryID.portfolioValueByFundV1.sql,
        question: StarterQueryID.portfolioValueByFundV1.question,
        resultFingerprint: "retry-preparation",
        dataIdentity: "message-1"),
      preferredSpecificationID: nil)
    let analysis = try #require(loader.analysis)
    let recommendations: [AutoChartRecommendation]
    switch analysis.outcome {
    case .charts(let values): recommendations = values
    case .tableFallback: recommendations = []
    }
    let alternative = try #require(recommendations.dropFirst().first)

    await loader.prepareSelected(alternative)
    let failedKey = loader.preparationTaskKey(
      recommendationID: alternative.id)
    #expect(loader.preparationFailed)

    loader.retryPreparation()
    let retryKey = loader.preparationTaskKey(
      recommendationID: alternative.id)

    #expect(!loader.preparationFailed)
    #expect(failedKey != retryKey)
  }
}

@MainActor
@Suite struct ResultPresentationRetryTests {
  @Test func reducerRetriesAnIdenticalPreferenceAfterSaveFailure() async {
    let preference = ResultPresentationPreference(
      mode: .table,
      specificationID: chartTestRecommendationID("policy|bar|fund|value"))
    let message = chartTestAnswerMessage()
    let recorder = PreferenceRecorder()
    var history = HistoryClient.noop()
    history.updateResultPresentation = { conversationID, updated in
      recorder.record(conversationID: conversationID, message: updated)
      if recorder.writeCount == 1 {
        throw PreferenceSaveTestError.failed
      }
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
        messageID: message.id,
        preference: preference)
    ) {
      $0.messages[id: message.id]?.resultPresentation = preference
    }
    await store.receive(
      .operationFailed(
        .history(
          operation: .messageSave,
          error: PreferenceSaveTestError.failed)))

    await store.send(
      .resultPresentationChanged(
        messageID: message.id,
        preference: preference))
    await store.finish()

    #expect(recorder.writeCount == 2)
    #expect(recorder.preference == preference)
  }

  @Test func duplicateAutomaticMigrationPersistsOnlyOnce() async {
    let previous = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID("policy|stale"))
    let migrated = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID("policy|current"))
    var message = chartTestAnswerMessage()
    message.resultPresentation = previous
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
      .resultPresentationMigrated(
        .init(
          messageID: message.id,
          previous: previous,
          updated: migrated))
    ) {
      $0.messages[id: message.id]?.resultPresentation = migrated
    }
    await store.send(
      .resultPresentationMigrated(
        .init(
          messageID: message.id,
          previous: previous,
          updated: migrated)))
    await store.finish()

    #expect(recorder.writeCount == 1)
    #expect(recorder.preference == migrated)
  }
}

private actor SupersededChartPreparationGate {
  private var preparationCount = 0
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func prepare(
    _ analysis: AutoChartAnalysis<Int>,
    recommendationID: AutoChartRecommendationID
  ) async throws -> AutoChartPreparedChart<Int> {
    preparationCount += 1
    guard preparationCount == 1 else {
      return try await analysis.prepare(recommendationID)
    }
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
    throw PreferenceSaveTestError.failed
  }

  func waitUntilFirstPreparationStarts() async {
    guard preparationCount == 0 else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func releaseFirstPreparation() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}
