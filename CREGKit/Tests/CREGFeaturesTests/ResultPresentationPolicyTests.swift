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
      intent
        == .persist(
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
        preparationFailed: true)
        == .retryChart(
          ResultPresentationPreference(
            mode: .chart,
            specificationID: specificationID)))
  }

  @Test func selectingAChartTypeFromTableRequestsChartPresentation() {
    let specificationID = chartTestRecommendationID("policy|bar|fund|value")

    let preference = ResultViewerLogic.chartTypeSelectionPreference(
      specificationID: specificationID)

    #expect(preference.mode == .chart)
    #expect(preference.specificationID == specificationID)
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

  @Test func policyVersionBumpClearsTheExpiredPinWithoutPinningTheDefault() throws {
    let currentVersion = AutoTableCharts.recommendationPolicyVersion
    try #require(currentVersion == 10)
    let storedID = chartTestRecommendationID(
      "policy|line|date|value",
      policyVersion: 9)
    let resolvedID = chartTestRecommendationID("policy|bar|fund|value")
    let preference = ResultPresentationPreference(
      mode: .chart,
      specificationID: storedID)

    let migrated = try #require(
      ResultViewerLogic.migratedPreference(
        preference,
        resolvedSpecificationID: resolvedID))

    #expect(migrated.mode == .chart)
    #expect(migrated.specificationID == nil)
  }
}

@MainActor
@Suite struct ResultPreviewAnalysisTests {
  @Test func leaseListingPreviewUsesAResolvableSelectionSpecification() async throws {
    let loader = ResultChartLoader(
      client: CREGChartAnalysisClient.testValue,
      warmStart: nil)
    let request = chartTestRequest(
      result: PreviewFixtures.leaseListingResult,
      sql: StarterQueryID.leaseExpirationsNextTwelveMonthsV1.sql,
      question: StarterQueryID.leaseExpirationsNextTwelveMonthsV1.question,
      resultFingerprint: "lease-listing-preview")

    _ = await loader.analyze(request, preferredSpecificationID: nil)

    let recommendation = try #require(loader.analysis?.primaryChart?.recommendation)
    #expect(
      PreviewFixtures.filteredLeaseChartSelection.specificationID
        == recommendation.specification.id)
  }

  @Test func automaticPreferenceAnalyzesAChartOnAColdLoader() async throws {
    let client = CREGChartAnalysisClient.testValue
    let loader = ResultChartLoader(client: client, warmStart: nil)
    let request = chartTestRequest(
      resultFingerprint: "automatic-preview-cold-loader",
      dataIdentity: "automatic-preview-message")
    var migrationCalled = false

    _ = await analyzeResultPresentation(
      loader,
      request: request,
      preference: nil,
      migratePreference: { _, updated in
        migrationCalled = true
        return .retained(updated)
      })

    let analysis = try #require(loader.analysis)
    switch analysis.resolve(nil) {
    case .exact, .defaulted:
      break
    case .unavailable:
      Issue.record("The chartable fixture should resolve a preview chart.")
    }
    #expect(!migrationCalled)
  }
}

@MainActor
@Suite struct ResultViewerAnalysisTests {
  @Test func replacementResultTreatsRetainedSelectionAsInactiveSynchronously() {
    let selection = AutoChartSelection<Int>(
      sourceRowIDs: [0],
      family: .bar,
      specificationID: AutoChartSpecificationID(rawValue: "bar|fund|value"),
      markID: "core")
    let retainedState = ResultChartSelectionState(
      selection: selection,
      resultFingerprint: "replaced-result")
    let replacementResult = QueryResult(
      columns: ["fund", "value"],
      rows: [
        [.text("Replacement A"), .real(100)],
        [.text("Replacement B"), .real(200)],
      ])

    #expect(
      retainedState.selection(for: "replaced-result") == selection)
    #expect(retainedState.selection(for: "current-result") == nil)
    #expect(retainedState.isStale(comparedTo: "current-result"))
    #expect(
      ResultViewerLogic.filteredResult(
        replacementResult,
        selectionState: retainedState,
        currentResultFingerprint: "current-result") == replacementResult)
  }

  @Test func unavailableAnalysisInvalidatesExactMarkSelection() {
    let update = ResultPresentationAnalysisUpdate.unavailable
    let selection = AutoChartSelection<Int>(
      sourceRowIDs: [0],
      family: .bar,
      specificationID: AutoChartSpecificationID(rawValue: "bar|fund|value"),
      markID: "core")

    #expect(update.resolvedSpecificationID == nil)
    #expect(update.preferenceReconciliation == .unchanged)
    #expect(update.invalidatesChartSelection(selection.specificationID))
    #expect(!update.invalidatesChartSelection(nil))
  }

  @Test func resolvedAnalysisInvalidatesOnlyAMismatchedChartSelection() {
    let resolvedID = chartTestRecommendationID("bar|fund|value")
    let update = ResultPresentationAnalysisUpdate.resolved(
      specificationID: resolvedID,
      preference: .unchanged)
    let matchingSelection = AutoChartSelection<Int>(
      sourceRowIDs: [0],
      family: .bar,
      specificationID: resolvedID.specificationID,
      markID: "core")
    let staleSelection = AutoChartSelection<Int>(
      sourceRowIDs: [0],
      family: .line,
      specificationID: AutoChartSpecificationID(rawValue: "line|date|value"),
      markID: "2026-08-24")

    #expect(!update.invalidatesChartSelection(nil))
    #expect(!update.invalidatesChartSelection(matchingSelection.specificationID))
    #expect(update.invalidatesChartSelection(staleSelection.specificationID))
  }

  @Test func analysisUpdateInvalidatesRetainedSelectionFromAReplacedResult() {
    let state = ResultChartSelectionState(
      selection: AutoChartSelection<Int>(
        sourceRowIDs: [0],
        family: .bar,
        specificationID: AutoChartSpecificationID(rawValue: "bar|fund|value"),
        markID: "core"),
      resultFingerprint: "replaced-result")
    let update = ResultPresentationAnalysisUpdate.resolved(
      specificationID: chartTestRecommendationID("bar|fund|value"),
      preference: .unchanged)

    #expect(
      state.isInvalidated(
        by: update,
        currentResultFingerprint: "current-result"))
  }

  @Test func rejectedMigrationReturnsTheAuthoritativePreference() async throws {
    let client = CREGChartAnalysisClient.testValue
    let loader = ResultChartLoader(client: client, warmStart: nil)
    let request = chartTestRequest(
      resultFingerprint: "viewer-migration-compare-and-set",
      dataIdentity: "viewer-migration-message")
    let previous = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID("missing-specification"))
    let authoritative = ResultPresentationPreference(
      mode: .table,
      specificationID: nil)
    var proposedMigration: ResultPresentationPreference?

    let update = await analyzeResultPresentation(
      loader,
      request: request,
      preference: previous,
      migratePreference: { receivedPrevious, updated in
        #expect(receivedPrevious == previous)
        proposedMigration = updated
        return .retained(authoritative)
      })

    guard
      case .resolved(
        let specificationID,
        preference: .retained(let retainedPreference))? = update
    else {
      Issue.record("The chartable fixture should resolve a viewer chart.")
      return
    }
    let analysis = try #require(loader.analysis)
    let primary = try #require(analysis.primaryChart?.recommendation)
    #expect(proposedMigration?.specificationID == primary.id)
    #expect(retainedPreference == authoritative)
    #expect(specificationID == primary.id)
  }
}

@MainActor
@Suite struct ResultPresentationMigrationHandlerTests {
  @Test func acceptedMigrationReturnsTheStoredPreference() {
    let previous = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID("policy|stale"))
    let updated = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID("policy|current"))
    var message = chartTestAnswerMessage()
    message.resultPresentation = previous
    var state = ChatFeature.State(conversationID: UUID())
    state.messages.append(message)
    let store = migrationStore(state: state)

    let outcome = resultPresentationMigrationHandler(
      store: store,
      messageID: message.id
    )(previous, updated)

    #expect(outcome == .retained(updated))
    #expect(store.messages[id: message.id]?.resultPresentation == updated)
  }

  @Test func rejectedMigrationReturnsAnAuthoritativeNilPreference() {
    let previous = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID("policy|stale"))
    let updated = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID("policy|current"))
    let message = chartTestAnswerMessage()
    var state = ChatFeature.State(conversationID: UUID())
    state.messages.append(message)
    let store = migrationStore(state: state)

    let outcome = resultPresentationMigrationHandler(
      store: store,
      messageID: message.id
    )(previous, updated)

    #expect(outcome == .retained(nil))
    #expect(store.messages[id: message.id]?.resultPresentation == nil)
  }

  @Test func missingMessageIsNotReportedAsThePreviousPreference() {
    let previous = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID("policy|stale"))
    let updated = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID("policy|current"))
    let store = migrationStore(
      state: ChatFeature.State(conversationID: UUID()))

    let outcome = resultPresentationMigrationHandler(
      store: store,
      messageID: UUID()
    )(previous, updated)

    #expect(outcome == .messageMissing)
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

@MainActor
@Suite struct ResultChartLoaderSupersessionTests {
  @Test func supersededAnalysisCannotReplaceANewerResult() async throws {
    let gate = SupersededChartAnalysisGate()
    let loader = ResultChartLoader(
      client: .testValue,
      warmStart: nil,
      analyzeChart: { request in
        try await gate.analyze(request)
      })
    let originalRequest = chartTestRequest(
      resultFingerprint: "superseded-analysis-original")
    let replacementRequest = chartTestRequest(
      result: PreviewFixtures.leaseListingResult,
      sql: StarterQueryID.leaseExpirationsNextTwelveMonthsV1.sql,
      question: StarterQueryID.leaseExpirationsNextTwelveMonthsV1.question,
      resultFingerprint: "superseded-analysis-replacement")

    let superseded = Task {
      await loader.analyze(
        originalRequest,
        preferredSpecificationID: nil)
    }
    await gate.waitUntilFirstAnalysisStarts()

    let replacement = await loader.analyze(
      replacementRequest,
      preferredSpecificationID: nil)
    guard case .resolved(let replacementRecommendation, _)? = replacement else {
      Issue.record("The replacement fixture should resolve a chart.")
      await gate.releaseFirstAnalysis()
      _ = await superseded.value
      return
    }

    await gate.releaseFirstAnalysis()
    let supersededResolution = await superseded.value
    #expect(supersededResolution == nil)
    let retainedAnalysis = try #require(loader.analysis)
    switch retainedAnalysis.resolve(nil) {
    case .exact(let recommendation), .defaulted(let recommendation, _):
      #expect(recommendation.id == replacementRecommendation.id)
    case .unavailable:
      Issue.record("The replacement analysis must remain installed.")
    }
  }

  @Test func cancelledAnalysisCannotProduceAnUpdate() async {
    let loader = ResultChartLoader(
      client: .testValue,
      warmStart: nil,
      analyzeChart: { _ in throw CancellationError() })

    let resolution = await loader.analyze(
      chartTestRequest(resultFingerprint: "cancelled-analysis"),
      preferredSpecificationID: nil)

    #expect(resolution == nil)
    #expect(loader.analysis == nil)
  }

  @Test func selectionGateAcceptsOnlyTheCurrentlyLoadedRequest() async {
    let loader = ResultChartLoader(client: .testValue, warmStart: nil)
    let loadedRequest = chartTestRequest(
      resultFingerprint: "selection-gate-loaded")
    let otherRequest = chartTestRequest(
      resultFingerprint: "selection-gate-other")

    #expect(!loader.hasLoadedAnalysis(for: loadedRequest))
    _ = await loader.analyze(loadedRequest, preferredSpecificationID: nil)
    #expect(loader.hasLoadedAnalysis(for: loadedRequest))
    #expect(!loader.hasLoadedAnalysis(for: otherRequest))
  }

  @Test func reusedAnalysisPreservesItsMatchingPreparedChart() async throws {
    let client = CREGChartAnalysisClient.testValue
    let loader = ResultChartLoader(client: client, warmStart: nil)
    let request = chartTestRequest(
      resultFingerprint: "reused-analysis-preparation")
    _ = await loader.analyze(request, preferredSpecificationID: nil)
    let analysis = try #require(loader.analysis)
    let recommendations = chartTestRecommendations(from: analysis)
    let alternative = try #require(recommendations.dropFirst().first)

    await loader.prepareSelected(alternative)
    let preparationKey = loader.preparationTaskKey(
      recommendationID: alternative.id)
    #expect(loader.preparedChart?.recommendation.id == alternative.id)

    _ = await loader.analyze(
      request,
      preferredSpecificationID: alternative.id)

    #expect(loader.preparedChart?.recommendation.id == alternative.id)
    #expect(
      loader.preparationTaskKey(recommendationID: alternative.id)
        == preparationKey)
  }

  @Test func resolvingPreparedPrimaryClearsAnAlternativePreparationFailure()
    async throws
  {
    let client = CREGChartAnalysisClient.testValue
    let loader = ResultChartLoader(
      client: client,
      warmStart: nil,
      prepareChart: { _, _ in
        throw PreferenceSaveTestError.failed
      })
    let request = chartTestRequest(
      resultFingerprint: "failure-followed-by-primary-resolution")
    _ = await loader.analyze(request, preferredSpecificationID: nil)
    let analysis = try #require(loader.analysis)
    let recommendations = chartTestRecommendations(from: analysis)
    let primary = try #require(recommendations.first)
    let alternative = try #require(recommendations.dropFirst().first)

    await loader.prepareSelected(alternative)
    #expect(loader.preparedChart == nil)
    #expect(loader.preparationFailed)

    _ = await loader.analyze(
      request,
      preferredSpecificationID: primary.id)

    #expect(loader.preparedChart?.recommendation.id == primary.id)
    #expect(!loader.preparationFailed)
  }

  @Test func supersededRecommendationCannotFailAfterNewerSuccess() async throws {
    let client = CREGChartAnalysisClient.testValue
    let gate = SupersededChartPreparationGate()
    let loader = ResultChartLoader(
      client: client,
      warmStart: nil,
      prepareChart: { analysis, recommendationID in
        try await gate.prepare(analysis, recommendationID: recommendationID)
      })
    _ = await loader.analyze(
      chartTestRequest(resultFingerprint: "superseded-preparation"),
      preferredSpecificationID: nil)
    let analysis = try #require(loader.analysis)
    let recommendations = chartTestRecommendations(from: analysis)
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
    let client = CREGChartAnalysisClient.testValue
    let loader = ResultChartLoader(
      client: client,
      warmStart: nil,
      prepareChart: { _, _ in
        throw PreferenceSaveTestError.failed
      })
    let request = chartTestRequest(resultFingerprint: "retry-preparation")
    _ = await loader.analyze(request, preferredSpecificationID: nil)
    let analysis = try #require(loader.analysis)
    let recommendations = chartTestRecommendations(from: analysis)
    let alternative = try #require(recommendations.dropFirst().first)

    await loader.prepareSelected(alternative)
    let failedKey = loader.preparationTaskKey(
      recommendationID: alternative.id)
    #expect(loader.preparationFailed)

    _ = await loader.analyze(
      request,
      preferredSpecificationID: alternative.id)
    #expect(loader.preparationFailed)
    #expect(
      loader.preparationTaskKey(recommendationID: alternative.id) == failedKey)

    loader.retryPreparation()
    let retryKey = loader.preparationTaskKey(
      recommendationID: alternative.id)

    #expect(!loader.preparationFailed)
    #expect(failedKey != retryKey)
  }

  @Test func retryInvalidatesSuspendedPreparationBeforeReplacementStarts()
    async throws
  {
    let gate = SupersededChartPreparationGate()
    let loader = ResultChartLoader(
      client: .testValue,
      warmStart: nil,
      prepareChart: { analysis, recommendationID in
        try await gate.prepare(analysis, recommendationID: recommendationID)
      })
    _ = await loader.analyze(
      chartTestRequest(resultFingerprint: "retry-suspended-preparation"),
      preferredSpecificationID: nil)
    let analysis = try #require(loader.analysis)
    let recommendation = try #require(
      chartTestRecommendations(from: analysis).dropFirst().first)

    let suspended = Task { await loader.prepareSelected(recommendation) }
    await gate.waitUntilFirstPreparationStarts()

    loader.retryPreparation()
    #expect(!loader.preparationFailed)

    await gate.releaseFirstPreparation()
    await suspended.value
    #expect(!loader.preparationFailed)
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
  private let firstCallGate = FirstCallGate()

  func prepare(
    _ analysis: AutoChartAnalysis<Int>,
    recommendationID: AutoChartRecommendationID
  ) async throws -> AutoChartPreparedChart<Int> {
    guard await firstCallGate.pauseIfFirstCall() else {
      return try await analysis.prepare(recommendationID)
    }
    throw PreferenceSaveTestError.failed
  }

  func waitUntilFirstPreparationStarts() async {
    await firstCallGate.waitUntilFirstCallStarts()
  }

  func releaseFirstPreparation() async {
    await firstCallGate.releaseFirstCall()
  }
}

private actor SupersededChartAnalysisGate {
  private let client = CREGChartAnalysisClient.testValue
  private let firstCallGate = FirstCallGate()

  func analyze(
    _ request: ResultChartLoader.Request
  ) async throws -> AutoChartAnalysis<Int> {
    _ = await firstCallGate.pauseIfFirstCall()
    return try await client.analyze(
      result: request.result,
      sql: request.sql,
      question: request.question,
      resultFingerprint: request.resultFingerprint,
      dataIdentity: request.dataIdentity)
  }

  func waitUntilFirstAnalysisStarts() async {
    await firstCallGate.waitUntilFirstCallStarts()
  }

  func releaseFirstAnalysis() async {
    await firstCallGate.releaseFirstCall()
  }
}

private actor FirstCallGate {
  private var callCount = 0
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func pauseIfFirstCall() async -> Bool {
    callCount += 1
    guard callCount == 1 else { return false }
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
    return true
  }

  func waitUntilFirstCallStarts() async {
    guard callCount == 0 else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func releaseFirstCall() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}
