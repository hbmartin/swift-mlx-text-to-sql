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
      retryAvailable: true)
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
        retryAvailable: true) == .retryChart(nil))
  }

  @Test func terminalFailureDoesNotProduceARetryIntent() {
    #expect(
      ResultViewerLogic.modeSelectionIntent(
        .chart,
        requestedMode: .chart,
        preserving: chartTestRecommendationID("policy|terminal|chart"),
        retryAvailable: false) == .none)
  }

  @Test func automaticModeSelectionDoesNotPinTheResolvedChart() {
    let intent = ResultViewerLogic.modeSelectionIntent(
      .table,
      requestedMode: .chart,
      preserving: nil,
      retryAvailable: false)

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
        retryAvailable: true)
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
    try #require(currentVersion > 0)
    let storedID = chartTestRecommendationID(
      "policy|line|date|value",
      policyVersion: currentVersion - 1)
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
  @Test func analysisTaskIdentityTracksOnlyRequestAndSpecification() {
    let request = chartTestRequest(
      resultFingerprint: "same-preview-result",
      dataIdentity: "same-preview-message")
    let specificationID = chartTestRecommendationID("line|date|value")
    let chartPreference = ResultPresentationPreference(
      mode: .chart,
      specificationID: specificationID)
    let tablePreference = ResultPresentationPreference(
      mode: .table,
      specificationID: specificationID)

    let chartKey = ResultPresentationAnalysisTaskKey(
      chartRequest: request.key,
      preference: chartPreference)
    let tableKey = ResultPresentationAnalysisTaskKey(
      chartRequest: request.key,
      preference: tablePreference)
    let selectionKey = ResultPresentationAnalysisTaskKey(
      chartRequest: request.key,
      preference: ResultPresentationPreference(
        mode: .chart,
        specificationID: chartTestRecommendationID(
          "bar|category|value")))
    let replacementRequestKey = ResultPresentationAnalysisTaskKey(
      chartRequest: chartTestRequest(
        resultFingerprint: "replacement-preview-result",
        dataIdentity: "same-preview-message"
      ).key,
      preference: chartPreference)

    #expect(chartKey == tableKey)
    #expect(chartKey != selectionKey)
    #expect(chartKey != replacementRequestKey)
  }

  @Test func changedPreferenceReresolvesTheReusedPreviewAnalysis() async throws {
    let loader = ResultChartLoader(
      client: .testValue, diagnostics: .noop, warmStart: nil)
    let request = chartTestRequest(
      resultFingerprint: "reused-preview-result",
      dataIdentity: "reused-preview-message")
    _ = await analyzeResultPresentation(
      loader,
      request: request,
      preference: nil,
      migratePreference: { _, updated in .migrated(updated) })
    let analysis = try #require(loader.analysis(for: request.key))
    let alternative = try #require(
      chartTestRecommendations(from: analysis).dropFirst().first)
    let changedPreference = ResultPresentationPreference(
      mode: .chart,
      specificationID: alternative.id)

    let update = await analyzeResultPresentation(
      loader,
      request: request,
      preference: changedPreference,
      migratePreference: { _, _ in
        Issue.record("An exact changed preference must not migrate.")
        return .retained(changedPreference)
      })

    guard case .resolved(let resolvedID, _)? = update else {
      Issue.record("The changed preference should resolve a chart.")
      return
    }
    #expect(resolvedID == alternative.id)
    #expect(loader.resolvedRecommendation(for: request.key)?.id == alternative.id)
  }

  @Test func stalledReconciliationBecomesThePreviewWritePreference() {
    let stale = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID("obsolete|line|date|value"))
    let resolved = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID("bar|category|value"))
    let requestKey = chartTestRequest(
      resultFingerprint: "stalled-preview-result"
    ).key
    var state = ResultPresentationState(
      preference: stale,
      requestKey: requestKey)

    state.apply(.stalled(resolved), requestKey: requestKey)
    state.synchronize(with: stale, requestKey: requestKey)
    let expectedPreference = ResultPresentationPreference(
      mode: .table,
      specificationID: resolved.specificationID)
    var expectedState = state
    expectedState.applyUserPreference(
      expectedPreference,
      authoritativePreference: stale,
      requestKey: requestKey)
    let stateBox = ResultPresentationStateBox(state)
    var persistedPreference: ResultPresentationPreference?
    var stateObservedByPersistence: ResultPresentationState?

    #expect(
      state.effectivePreference(
        authoritativePreference: stale,
        requestKey: requestKey) == resolved)
    resultPresentationModeSelectionTransition(
      .table,
      state: stateBox.value,
      authoritativePreference: stale,
      requestKey: requestKey,
      chartRetryAvailable: false
    ).commit(
      setState: { stateBox.value = $0 },
      retryChart: {
        Issue.record("A normal mode change must not retry preparation.")
      },
      persistPreference: { updated in
        stateObservedByPersistence = stateBox.value
        persistedPreference = updated
      })

    #expect(stateBox.value == expectedState)
    #expect(stateObservedByPersistence == expectedState)
    #expect(persistedPreference == expectedPreference)
  }

  @Test func synchronizingAnAutomaticPreferenceDoesNotPinTheResolvedChart() {
    let requestKey = chartTestRequest(
      resultFingerprint: "automatic-preview-result"
    ).key
    var state = ResultPresentationState(
      preference: ResultPresentationPreference(
        mode: .chart,
        specificationID: chartTestRecommendationID("bar|category|value")),
      requestKey: requestKey)

    state.synchronize(with: nil, requestKey: requestKey)
    let expectedState = ResultPresentationState(
      preference: nil,
      requestKey: requestKey)
    let stateBox = ResultPresentationStateBox(state)
    let expectedPreference = ResultPresentationPreference(mode: .table)
    var persistedPreference: ResultPresentationPreference?

    #expect(state == expectedState)
    resultPresentationModeSelectionTransition(
      .table,
      state: stateBox.value,
      authoritativePreference: nil,
      requestKey: requestKey,
      chartRetryAvailable: false
    ).commit(
      setState: { stateBox.value = $0 },
      retryChart: {
        Issue.record("A normal mode change must not retry preparation.")
      },
      persistPreference: { persistedPreference = $0 })

    #expect(persistedPreference == expectedPreference)
    #expect(
      stateBox.value.effectivePreference(
        authoritativePreference: nil,
        requestKey: requestKey) == expectedPreference)
  }

  @Test func modeOnlyAuthoritativeUpdatePreservesAStalledSpecification() {
    let stale = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID("obsolete|line|date|value"))
    let resolved = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID("bar|category|value"))
    let authoritativeTable = ResultPresentationPreference(
      mode: .table,
      specificationID: stale.specificationID)
    let requestKey = chartTestRequest(
      resultFingerprint: "stalled-mode-only-result"
    ).key
    var state = ResultPresentationState(
      preference: stale,
      requestKey: requestKey)
    state.apply(.stalled(resolved), requestKey: requestKey)
    let expected = ResultPresentationPreference(
      mode: .table,
      specificationID: resolved.specificationID)

    #expect(
      state.effectivePreference(
        authoritativePreference: authoritativeTable,
        requestKey: requestKey) == expected)

    state.synchronize(
      with: authoritativeTable,
      requestKey: requestKey)
    let stateBox = ResultPresentationStateBox(state)
    let expectedSelection = ResultPresentationPreference(
      mode: .chart,
      specificationID: resolved.specificationID)
    var persistedPreference: ResultPresentationPreference?

    #expect(
      state.effectivePreference(
        authoritativePreference: authoritativeTable,
        requestKey: requestKey) == expected)
    resultPresentationModeSelectionTransition(
      .chart,
      state: stateBox.value,
      authoritativePreference: authoritativeTable,
      requestKey: requestKey,
      chartRetryAvailable: false
    ).commit(
      setState: { stateBox.value = $0 },
      retryChart: {
        Issue.record("A normal mode change must not retry preparation.")
      },
      persistPreference: { persistedPreference = $0 })

    #expect(persistedPreference == expectedSelection)
    #expect(
      stateBox.value.effectivePreference(
        authoritativePreference: authoritativeTable,
        requestKey: requestKey) == expectedSelection)
  }

  @Test func retryTransitionCommitsBeforeRetryAndPersistence() {
    let specificationID = chartTestRecommendationID("retry|bar|category|value")
    let authoritative = ResultPresentationPreference(
      mode: .table,
      specificationID: specificationID)
    let requestKey = chartTestRequest(
      resultFingerprint: "commit-before-retry"
    ).key
    let stateBox = ResultPresentationStateBox(
      ResultPresentationState(
        preference: authoritative,
        requestKey: requestKey))
    let expected = ResultPresentationPreference(
      mode: .chart,
      specificationID: specificationID)
    var events: [String] = []

    resultPresentationModeSelectionTransition(
      .chart,
      state: stateBox.value,
      authoritativePreference: authoritative,
      requestKey: requestKey,
      chartRetryAvailable: true
    ).commit(
      setState: {
        stateBox.value = $0
        events.append("commit")
      },
      retryChart: {
        #expect(
          stateBox.value.effectivePreference(
            authoritativePreference: authoritative,
            requestKey: requestKey) == expected)
        events.append("retry")
      },
      persistPreference: { updated in
        #expect(updated == expected)
        #expect(
          stateBox.value.effectivePreference(
            authoritativePreference: authoritative,
            requestKey: requestKey) == expected)
        events.append("persist")
      })

    #expect(events == ["commit", "retry", "persist"])
  }

  @Test func replacementRequestRejectsAStalledPreferenceSynchronously() {
    let stale = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID("obsolete|line|date|value"))
    let resolved = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID("bar|category|value"))
    let originalKey = chartTestRequest(
      resultFingerprint: "original-preview-result",
      dataIdentity: "reused-preview-message"
    ).key
    let replacementKey = chartTestRequest(
      resultFingerprint: "replacement-preview-result",
      dataIdentity: "reused-preview-message"
    ).key
    var state = ResultPresentationState(
      preference: stale,
      requestKey: originalKey)
    state.apply(.stalled(resolved), requestKey: originalKey)

    #expect(
      state.effectivePreference(
        authoritativePreference: stale,
        requestKey: replacementKey) == stale)

    state.synchronize(with: stale, requestKey: replacementKey)
    state.apply(.stalled(resolved), requestKey: originalKey)

    #expect(
      state
        == ResultPresentationState(
          preference: stale,
          requestKey: replacementKey))
  }

  @Test func changedAuthoritativeInputIsEffectiveBeforeStateSynchronization() {
    let requestKey = chartTestRequest(
      resultFingerprint: "authoritative-preview-result"
    ).key
    let original = ResultPresentationPreference(mode: .chart)
    let replacement = ResultPresentationPreference(mode: .table)
    var state = ResultPresentationState(
      preference: original,
      requestKey: requestKey)

    #expect(
      state.effectivePreference(
        authoritativePreference: replacement,
        requestKey: requestKey) == replacement)

    state.synchronize(with: replacement, requestKey: requestKey)

    #expect(
      state
        == ResultPresentationState(
          preference: replacement,
          requestKey: requestKey))
  }

  @Test func leaseListingPreviewUsesAResolvableSelectionSpecification() async throws {
    let loader = ResultChartLoader(
      client: CREGChartAnalysisClient.testValue,
      diagnostics: .noop,
      warmStart: nil)
    let request = chartTestRequest(
      result: PreviewFixtures.leaseListingResult,
      sql: StarterQueryID.leaseExpirationsNextTwelveMonthsV1.sql,
      question: StarterQueryID.leaseExpirationsNextTwelveMonthsV1.question,
      resultFingerprint: "lease-listing-preview")

    _ = await loader.analyze(request, preferredSpecificationID: nil)

    let recommendation = try #require(
      loader.analysis(for: request.key)?.primaryChart?.recommendation)
    #expect(
      PreviewFixtures.filteredLeaseChartSelection.specificationID
        == recommendation.specification.id)
  }

  @Test func automaticPreferenceAnalyzesAChartOnAColdLoader() async throws {
    let client = CREGChartAnalysisClient.testValue
    let loader = ResultChartLoader(
      client: client, diagnostics: .noop, warmStart: nil)
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
        return .migrated(updated)
      })

    let analysis = try #require(loader.analysis(for: request.key))
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
  @Test func analyzerFailureRecordsOnceAndRemainsRetryable() async {
    let attempts = FailingFirstChartAnalysis()
    let diagnostics = DiagnosticEventRecorder()
    let loader = ResultChartLoader(
      client: .testValue,
      diagnostics: diagnostics.client,
      warmStart: nil,
      analyzeChart: { request in
        try await attempts.analyze(request)
      })
    let request = chartTestRequest(
      resultFingerprint: "diagnosed-analysis-failure")

    let failed = await analyzeResultPresentation(
      loader,
      request: request,
      preference: nil,
      migratePreference: { _, updated in .migrated(updated) })

    guard case .failed(let failure)? = failed else {
      Issue.record("The analyzer failure should remain explicit.")
      return
    }
    #expect(failure.stage == .analysis)
    #expect(failure.kind == .transient)
    #expect(failure.retryability == .retryable)
    #expect(
      loader.failure(for: request.key, recommendationID: nil) == failure)
    #expect(diagnostics.events.count == 1)
    #expect(diagnostics.events.first?.level == .error)
    #expect(diagnostics.events.first?.category == .presentation)
    #expect(diagnostics.events.first?.code == "chart_analysis_failed")
    #expect(diagnostics.events.first?.details != nil)

    let retained = await analyzeResultPresentation(
      loader,
      request: request,
      preference: nil,
      migratePreference: { _, updated in .migrated(updated) })
    guard case .failed(let retainedFailure)? = retained else {
      Issue.record("A retained analyzer failure should remain explicit.")
      return
    }
    #expect(retainedFailure == failure)
    #expect(await attempts.count == 1)
    #expect(diagnostics.events.count == 1)

    #expect(
      loader.retryFailure(for: request.key, recommendationID: nil))
    let retried = await analyzeResultPresentation(
      loader,
      request: request,
      preference: nil,
      migratePreference: { _, updated in .migrated(updated) })

    guard case .resolved? = retried else {
      Issue.record("The explicit analysis retry should resolve a chart.")
      return
    }
    #expect(loader.failure(for: request.key, recommendationID: nil) == nil)
    #expect(diagnostics.events.count == 1)
  }

  @Test func committedAnalyzerFailureRecordsBeforeCallerCancellation() async {
    let gate = FirstCallGate()
    let cancellation = TestTaskCancellationHandle()
    let recorder = DiagnosticEventRecorder { _ in
      cancellation.cancel()
    }
    let diagnostics = recorder.client
    let loader = ResultChartLoader(
      client: .testValue,
      diagnostics: diagnostics,
      warmStart: nil,
      analyzeChart: { _ in
        _ = await gate.pauseIfFirstCall()
        throw PreferenceSaveTestError.failed
      })
    let request = chartTestRequest(
      resultFingerprint: "cancelled-after-analysis-commit")
    let analysis = Task {
      await analyzeResultPresentation(
        loader,
        request: request,
        preference: nil,
        migratePreference: { _, updated in .migrated(updated) })
    }
    cancellation.install { analysis.cancel() }
    await gate.waitUntilFirstCallStarts()

    await gate.releaseFirstCall()

    #expect(await analysis.value == nil)
    #expect(loader.failure(for: request.key, recommendationID: nil) != nil)
    #expect(recorder.events.count == 1)

    let retained = await analyzeResultPresentation(
      loader,
      request: request,
      preference: nil,
      migratePreference: { _, updated in .migrated(updated) })
    guard case .failed? = retained else {
      Issue.record("The committed failure should remain visible after cancellation.")
      return
    }
    #expect(recorder.events.count == 1)
  }

  @Test func recreatedLoadersShareDiagnosticsUntilEveryOwnerReleases() async {
    let client = CREGChartAnalysisClient.testValue
    let diagnostics = DiagnosticEventRecorder()
    let invocations = ChartAnalysisInvocationCounter()
    let analyze: ResultChartLoader.AnalyzeChart = { _ in
      await invocations.record()
      throw PreferenceSaveTestError.failed
    }
    let first = ResultChartLoader(
      client: client,
      diagnostics: diagnostics.client,
      warmStart: nil,
      analyzeChart: analyze)
    let recreated = ResultChartLoader(
      client: client,
      diagnostics: diagnostics.client,
      warmStart: nil,
      analyzeChart: analyze)
    let request = chartTestRequest(
      resultFingerprint: "shared-analysis-failure-diagnostic")

    _ = await first.analyze(request, preferredSpecificationID: nil)
    _ = await recreated.analyze(request, preferredSpecificationID: nil)

    #expect(await invocations.count == 2)
    #expect(diagnostics.events.count == 1)

    #expect(first.retryFailure(for: request.key, recommendationID: nil))
    _ = await first.analyze(request, preferredSpecificationID: nil)

    #expect(await invocations.count == 3)
    #expect(diagnostics.events.count == 1)

    let replacement = chartTestRequest(
      resultFingerprint: "shared-diagnostic-replacement")
    first.synchronizeRequest(replacement.key)
    recreated.synchronizeRequest(replacement.key)
    _ = await first.analyze(request, preferredSpecificationID: nil)

    #expect(await invocations.count == 4)
    #expect(diagnostics.events.count == 2)
  }

  @Test func changingFailureDetailsKeepOneLogicalDiagnosticIdentity() async {
    let client = CREGChartAnalysisClient.testValue
    let diagnostics = DiagnosticEventRecorder()
    let first = ResultChartLoader(
      client: client,
      diagnostics: diagnostics.client,
      warmStart: nil,
      analyzeChart: { _ in throw DiagnosticsTestError.failed("first occurrence") })
    let recreated = ResultChartLoader(
      client: client,
      diagnostics: diagnostics.client,
      warmStart: nil,
      analyzeChart: { _ in throw DiagnosticsTestError.failed("second occurrence") })
    let request = chartTestRequest(
      resultFingerprint: "stable-analysis-failure-diagnostic")

    _ = await first.analyze(request, preferredSpecificationID: nil)
    _ = await recreated.analyze(request, preferredSpecificationID: nil)

    #expect(diagnostics.events.count == 1)
    #expect(diagnostics.events.first?.details?.contains("first occurrence") == true)
  }

  @Test func returningToARequestStartsANewFailureDiagnosticEpisode() async {
    let diagnostics = DiagnosticEventRecorder()
    let invocations = ChartAnalysisInvocationCounter()
    let loader = ResultChartLoader(
      client: .testValue,
      diagnostics: diagnostics.client,
      warmStart: nil,
      analyzeChart: { _ in
        await invocations.record()
        throw PreferenceSaveTestError.failed
      })
    let first = chartTestRequest(resultFingerprint: "diagnostic-request-a")
    let replacement = chartTestRequest(resultFingerprint: "diagnostic-request-b")

    _ = await loader.analyze(first, preferredSpecificationID: nil)
    _ = await loader.analyze(replacement, preferredSpecificationID: nil)
    _ = await loader.analyze(first, preferredSpecificationID: nil)

    #expect(await invocations.count == 3)
    #expect(diagnostics.events.count == 3)
  }

  @Test func staleSurfaceRetryCannotReleaseANewerDiagnosticEpisode() async {
    let client = CREGChartAnalysisClient.testValue
    let diagnostics = DiagnosticEventRecorder()
    let analyze: ResultChartLoader.AnalyzeChart = { _ in
      throw PreferenceSaveTestError.failed
    }
    let first = ResultChartLoader(
      client: client,
      diagnostics: diagnostics.client,
      warmStart: nil,
      analyzeChart: analyze)
    let stale = ResultChartLoader(
      client: client,
      diagnostics: diagnostics.client,
      warmStart: nil,
      analyzeChart: analyze)
    let recreated = ResultChartLoader(
      client: client,
      diagnostics: diagnostics.client,
      warmStart: nil,
      analyzeChart: analyze)
    let request = chartTestRequest(
      resultFingerprint: "stale-diagnostic-release")

    _ = await first.analyze(request, preferredSpecificationID: nil)
    _ = await stale.analyze(request, preferredSpecificationID: nil)
    #expect(diagnostics.events.count == 1)

    #expect(first.retryFailure(for: request.key, recommendationID: nil))
    _ = await first.analyze(request, preferredSpecificationID: nil)
    #expect(diagnostics.events.count == 1)

    #expect(stale.retryFailure(for: request.key, recommendationID: nil))
    _ = await recreated.analyze(request, preferredSpecificationID: nil)

    #expect(diagnostics.events.count == 1)
  }

  @Test func recycledLoaderReleasesItsFailureDiagnosticClaim() async {
    let client = CREGChartAnalysisClient.testValue
    let diagnostics = DiagnosticEventRecorder()
    let analyze: ResultChartLoader.AnalyzeChart = { _ in
      throw PreferenceSaveTestError.failed
    }
    let request = chartTestRequest(
      resultFingerprint: "recycled-diagnostic-loader")
    weak var releasedLoader: ResultChartLoader?

    do {
      let loader = ResultChartLoader(
        client: client,
        diagnostics: diagnostics.client,
        warmStart: nil,
        analyzeChart: analyze)
      releasedLoader = loader
      _ = await loader.analyze(request, preferredSpecificationID: nil)
    }

    #expect(releasedLoader == nil)
    let recreated = ResultChartLoader(
      client: client,
      diagnostics: diagnostics.client,
      warmStart: nil,
      analyzeChart: analyze)
    _ = await recreated.analyze(request, preferredSpecificationID: nil)

    #expect(diagnostics.events.count == 2)
  }

  @Test func invalidDatasetFailureRemainsTerminalWithoutOfferingRetry() async {
    let invocations = ChartAnalysisInvocationCounter()
    let diagnostics = DiagnosticEventRecorder()
    let loader = ResultChartLoader(
      client: .testValue,
      diagnostics: diagnostics.client,
      warmStart: nil,
      analyzeChart: { _ in
        await invocations.record()
        throw AutoChartDatasetError(
          code: .duplicateColumnID,
          identifier: "duplicate-column")
      })
    let request = chartTestRequest(
      resultFingerprint: "terminal-analysis-failure")
    let taskKey = loader.analysisTaskKey(
      requestKey: request.key,
      preference: nil)

    let update = await analyzeResultPresentation(
      loader,
      request: request,
      preference: nil,
      migratePreference: { _, updated in .migrated(updated) })

    guard case .failed(let failure)? = update else {
      Issue.record("The terminal failure must remain distinct from unavailable.")
      return
    }
    #expect(failure.stage == .analysis)
    #expect(failure.kind == .invalidDataset)
    #expect(failure.retryability == .terminal)
    #expect(
      loader.failure(for: request.key, recommendationID: nil) == failure)
    #expect(diagnostics.events.count == 1)
    #expect(diagnostics.events.first?.level == .error)
    #expect(
      diagnostics.events.first?.code == "chart_analysis_invalid_dataset")

    #expect(
      !loader.retryFailure(for: request.key, recommendationID: nil))
    #expect(
      loader.analysisTaskKey(requestKey: request.key, preference: nil)
        == taskKey)

    let repeated = await analyzeResultPresentation(
      loader,
      request: request,
      preference: nil,
      migratePreference: { _, updated in .migrated(updated) })
    guard case .failed(let repeatedFailure)? = repeated else {
      Issue.record("The retained terminal failure should be returned again.")
      return
    }
    #expect(repeatedFailure == failure)
    #expect(await invocations.count == 1)
    #expect(diagnostics.events.count == 1)
  }

  @Test func obsoletePolicyClearsPinInsteadOfPersistingTheDefault() async throws {
    let client = CREGChartAnalysisClient.testValue
    let diagnostics = DiagnosticEventRecorder()
    let loader = ResultChartLoader(
      client: client, diagnostics: diagnostics.client, warmStart: nil)
    let request = chartTestRequest(
      resultFingerprint: "viewer-obsolete-policy",
      dataIdentity: "viewer-obsolete-policy-message")
    let previousPolicy = AutoTableCharts.recommendationPolicyVersion - 1
    let previous = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID(
        "old-policy-specification",
        policyVersion: previousPolicy))
    var proposedMigration: ResultPresentationPreference?

    let update = await analyzeResultPresentation(
      loader,
      request: request,
      preference: previous,
      migratePreference: { receivedPrevious, updated in
        #expect(receivedPrevious == previous)
        proposedMigration = updated
        return .migrated(updated)
      })

    guard case .resolved(let resolvedID, _)? = update else {
      Issue.record("The chartable fixture should resolve a viewer chart.")
      return
    }
    #expect(
      resolvedID
        == loader.analysis(for: request.key)?.primaryChart?.recommendation.id)
    #expect(proposedMigration?.mode == .chart)
    #expect(proposedMigration?.specificationID == nil)
    #expect(
      diagnostics.events
        == [
          DiagnosticEvent(
            level: .info,
            category: .presentation,
            code: "chart_recommendation_policy_changed",
            summary: "A stored chart pin used an obsolete recommendation policy.",
            context: [
              "previous_policy": String(previousPolicy),
              "current_policy": String(AutoTableCharts.recommendationPolicyVersion),
            ])
        ])
  }

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

    #expect(update.preferenceReconciliation == .unchanged)
    #expect(update.invalidatesChartSelection(selection.specificationID))
    #expect(!update.invalidatesChartSelection(nil))
  }

  @Test func failedAnalysisInvalidatesExactMarkSelection() {
    let update = ResultPresentationAnalysisUpdate.failed(
      ResultChartLoader.Failure(
        PreferenceSaveTestError.failed,
        stage: .analysis))
    let selection = AutoChartSelection<Int>(
      sourceRowIDs: [0],
      family: .bar,
      specificationID: AutoChartSpecificationID(rawValue: "bar|fund|value"),
      markID: "core")

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

  @Test func analysisUpdatePreservesOnlyCurrentMatchingSelection() {
    let matchingID = chartTestRecommendationID("bar|fund|value")
    let state = ResultChartSelectionState(
      selection: AutoChartSelection<Int>(
        sourceRowIDs: [0],
        family: .bar,
        specificationID: matchingID.specificationID,
        markID: "core"),
      resultFingerprint: "current-result")
    let matchingUpdate = ResultPresentationAnalysisUpdate.resolved(
      specificationID: matchingID,
      preference: .unchanged)
    let mismatchedUpdate = ResultPresentationAnalysisUpdate.resolved(
      specificationID: chartTestRecommendationID("line|date|value"),
      preference: .unchanged)

    #expect(
      !state.isInvalidated(
        by: matchingUpdate,
        currentResultFingerprint: "current-result"))
    #expect(
      state.isInvalidated(
        by: mismatchedUpdate,
        currentResultFingerprint: "current-result"))
  }

  @Test func rejectedMigrationReturnsTheAuthoritativePreference() async throws {
    let client = CREGChartAnalysisClient.testValue
    let diagnostics = DiagnosticEventRecorder()
    let loader = ResultChartLoader(
      client: client, diagnostics: diagnostics.client, warmStart: nil)
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
    let analysis = try #require(loader.analysis(for: request.key))
    let primary = try #require(analysis.primaryChart?.recommendation)
    #expect(proposedMigration?.specificationID == primary.id)
    #expect(retainedPreference == authoritative)
    #expect(specificationID == primary.id)
    #expect(diagnostics.events.isEmpty)
  }

  @Test func retainedPreferenceReresolvesLoaderOwnedState() async throws {
    let diagnostics = DiagnosticEventRecorder()
    let loader = ResultChartLoader(
      client: .testValue, diagnostics: diagnostics.client, warmStart: nil)
    let request = chartTestRequest(
      resultFingerprint: "viewer-loader-owned-resolution",
      dataIdentity: "viewer-loader-owned-message")
    _ = await loader.analyze(request, preferredSpecificationID: nil)
    let analysis = try #require(loader.analysis(for: request.key))
    let recommendations = chartTestRecommendations(from: analysis)
    let primary = try #require(recommendations.first)
    let alternative = try #require(recommendations.dropFirst().first)
    let previous = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID("missing-specification"))
    let authoritative = ResultPresentationPreference(
      mode: .table,
      specificationID: alternative.id)

    let update = await analyzeResultPresentation(
      loader,
      request: request,
      preference: previous,
      migratePreference: { _, _ in .retained(authoritative) })

    guard case .resolved(let resolvedID, _)? = update else {
      Issue.record("The retained preference should resolve a chart.")
      return
    }
    #expect(resolvedID == alternative.id)
    #expect(loader.resolvedRecommendation(for: request.key)?.id == alternative.id)
    #expect(loader.matchingPreparedChart(for: primary.id) == nil)
    #expect(loader.matchingPreparedChart(for: alternative.id) == nil)
    #expect(
      loader.failure(
        for: request.key,
        recommendationID: alternative.id) == nil)
    #expect(diagnostics.events.isEmpty)
  }

  @Test func rejectedMigrationReconcilesAnAuthoritativeObsoletePin() async throws {
    let client = CREGChartAnalysisClient.testValue
    let diagnostics = DiagnosticEventRecorder()
    let loader = ResultChartLoader(
      client: client, diagnostics: diagnostics.client, warmStart: nil)
    let request = chartTestRequest(
      resultFingerprint: "viewer-authoritative-obsolete-policy",
      dataIdentity: "viewer-authoritative-obsolete-policy-message")
    let previous = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID("missing-specification"))
    let previousPolicy = AutoTableCharts.recommendationPolicyVersion - 1
    let authoritative = ResultPresentationPreference(
      mode: .table,
      specificationID: chartTestRecommendationID(
        "authoritative-obsolete-specification",
        policyVersion: previousPolicy))
    var attempts:
      [(
        previous: ResultPresentationPreference,
        updated: ResultPresentationPreference
      )] = []

    let update = await analyzeResultPresentation(
      loader,
      request: request,
      preference: previous,
      migratePreference: { receivedPrevious, updated in
        attempts.append((receivedPrevious, updated))
        return attempts.count == 1
          ? .retained(authoritative)
          : .migrated(updated)
      })

    guard
      case .resolved(
        let specificationID,
        preference: .retained(let retainedPreference))? = update
    else {
      Issue.record("The authoritative obsolete pin should be reconciled.")
      return
    }
    let primary = try #require(
      loader.analysis(for: request.key)?.primaryChart?.recommendation)
    #expect(specificationID == primary.id)
    #expect(attempts.count == 2)
    #expect(attempts[0].previous == previous)
    #expect(attempts[1].previous == authoritative)
    #expect(attempts[1].updated.mode == .table)
    #expect(attempts[1].updated.specificationID == nil)
    #expect(retainedPreference == attempts[1].updated)
    #expect(
      diagnostics.events
        == [
          DiagnosticEvent(
            level: .info,
            category: .presentation,
            code: "chart_recommendation_policy_changed",
            summary: "A stored chart pin used an obsolete recommendation policy.",
            context: [
              "previous_policy": String(previousPolicy),
              "current_policy": String(AutoTableCharts.recommendationPolicyVersion),
            ])
        ])
  }

  @Test func repeatedAnalysisRecordsOnlyTheCommittedMigration() async throws {
    let client = CREGChartAnalysisClient.testValue
    let diagnostics = DiagnosticEventRecorder()
    let loader = ResultChartLoader(
      client: client, diagnostics: diagnostics.client, warmStart: nil)
    let request = chartTestRequest(
      resultFingerprint: "viewer-repeated-obsolete-policy",
      dataIdentity: "viewer-repeated-obsolete-policy-message")
    let previousPolicy = AutoTableCharts.recommendationPolicyVersion - 1
    let previous = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID(
        "old-policy-specification",
        policyVersion: previousPolicy))
    var storedPreference = previous
    let migration: ResultPresentationMigrationHandler = { receivedPrevious, updated in
      guard storedPreference == receivedPrevious else {
        return .retained(storedPreference)
      }
      storedPreference = updated
      return .migrated(updated)
    }

    _ = await analyzeResultPresentation(
      loader,
      request: request,
      preference: previous,
      migratePreference: migration)
    _ = await analyzeResultPresentation(
      loader,
      request: request,
      preference: previous,
      migratePreference: migration)

    #expect(diagnostics.events.count == 1)
    #expect(diagnostics.events.first?.category == .presentation)
    #expect(diagnostics.events.first?.code == "chart_recommendation_policy_changed")
  }

  @Test func retainedPreviousPreferenceTerminatesReconciliation() async throws {
    let diagnostics = DiagnosticEventRecorder()
    let loader = ResultChartLoader(
      client: .testValue, diagnostics: diagnostics.client, warmStart: nil)
    let request = chartTestRequest(
      resultFingerprint: "viewer-retained-previous-preference",
      dataIdentity: "viewer-retained-previous-message")
    let previous = ResultPresentationPreference(
      mode: .chart,
      specificationID: chartTestRecommendationID("missing-specification"))
    var attempts = 0

    let update = await analyzeResultPresentation(
      loader,
      request: request,
      preference: previous,
      migratePreference: { receivedPrevious, _ in
        attempts += 1
        return .retained(receivedPrevious)
      })

    guard
      case .resolved(
        let specificationID,
        preference: .stalled(let resolvedPreference))? = update
    else {
      Issue.record("The repeated authoritative preference should terminate reconciliation.")
      return
    }
    let primary = try #require(
      loader.analysis(for: request.key)?.primaryChart?.recommendation)
    #expect(attempts == 1)
    #expect(resolvedPreference.mode == previous.mode)
    #expect(resolvedPreference.specificationID == primary.id)
    #expect(specificationID == primary.id)
    #expect(loader.resolvedRecommendation(for: request.key)?.id == primary.id)
    #expect(
      diagnostics.events
        == [
          DiagnosticEvent(
            level: .error,
            category: .presentation,
            code: "chart_preference_reconciliation_stalled",
            summary: "Chart preference reconciliation made no progress.")
        ])
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

    #expect(outcome == .migrated(updated))
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
  @Test func loaderOwnerDefersForwardsAndReplacesByRequest() {
    var constructions:
      [(
        key: ResultChartLoader.Request.Key,
        preferredSpecificationID: AutoChartRecommendationID?
      )] = []
    let owner = ResultChartLoaderOwner { request, preferredSpecificationID in
      constructions.append((request.key, preferredSpecificationID))
      return ResultChartLoader(
        client: .testValue, diagnostics: .noop, warmStart: nil)
    }
    let firstRequest = chartTestRequest(
      resultFingerprint: "deferred-loader-owner")
    let firstPreferred = chartTestRecommendationID("preferred-first-loader")
    let replacementRequest = chartTestRequest(
      resultFingerprint: "replacement-loader-owner")
    let replacementPreferred = chartTestRecommendationID(
      "preferred-replacement-loader")

    #expect(constructions.isEmpty)
    let first = owner.loader(
      warmStart: firstRequest,
      preferredSpecificationID: firstPreferred)
    let reused = owner.loader(
      warmStart: firstRequest,
      preferredSpecificationID: replacementPreferred)
    let replacement = owner.loader(
      warmStart: replacementRequest,
      preferredSpecificationID: replacementPreferred)

    #expect(first === reused)
    #expect(first !== replacement)
    #expect(constructions.count == 2)
    #expect(constructions[0].key == firstRequest.key)
    #expect(constructions[0].preferredSpecificationID == firstPreferred)
    #expect(constructions[1].key == replacementRequest.key)
    #expect(
      constructions[1].preferredSpecificationID == replacementPreferred)
  }

  @Test func supersededAnalysisCannotReplaceANewerResult() async throws {
    let gate = SupersededChartAnalysisGate()
    let loader = ResultChartLoader(
      client: .testValue,
      diagnostics: .noop,
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
    guard case .resolved(let replacementRecommendation, _, _)? = replacement else {
      Issue.record("The replacement fixture should resolve a chart.")
      await gate.releaseFirstAnalysis()
      _ = await superseded.value
      return
    }

    await gate.releaseFirstAnalysis()
    let supersededResolution = await superseded.value
    #expect(supersededResolution == nil)
    let retainedAnalysis = try #require(
      loader.analysis(for: replacementRequest.key))
    switch retainedAnalysis.resolve(nil) {
    case .exact(let recommendation), .defaulted(let recommendation, _):
      #expect(recommendation.id == replacementRecommendation.id)
    case .unavailable:
      Issue.record("The replacement analysis must remain installed.")
    }
  }

  @Test func cancellationErrorFromLiveAnalysisRemainsRetryable() async {
    let loader = ResultChartLoader(
      client: .testValue,
      diagnostics: .noop,
      warmStart: nil,
      analyzeChart: { _ in throw CancellationError() })
    let request = chartTestRequest(
      resultFingerprint: "live-analysis-cancellation-error")

    let resolution = await loader.analyze(
      request,
      preferredSpecificationID: nil)

    guard case .failed(_)? = resolution else {
      Issue.record("A live caller must retain a retryable analyzer failure.")
      return
    }
    #expect(
      loader.failure(for: request.key, recommendationID: nil)?.retryability
        == .retryable)
    #expect(loader.analysis(for: request.key) == nil)
  }

  @Test func cancellingAnalysisCancelsTheInjectedOperation() async {
    let probe = ChartAnalysisCancellationProbe()
    let loader = ResultChartLoader(
      client: .testValue,
      diagnostics: .noop,
      warmStart: nil,
      analyzeChart: { _ in
        try await probe.waitUntilCancelled()
        throw CancellationError()
      })
    let request = chartTestRequest(
      resultFingerprint: "cancel-propagates-to-analysis")
    let analysis = Task {
      await loader.analyze(
        request,
        preferredSpecificationID: nil)
    }
    await probe.waitUntilStarted()

    analysis.cancel()

    #expect(await analysis.value == nil)
    #expect(await probe.cancellationWasObserved)
    #expect(loader.analysis(for: request.key) == nil)
  }

  @Test func failedAnalysisDoesNotPoisonTheNextAttempt() async {
    let attempts = FailingFirstChartAnalysis()
    let loader = ResultChartLoader(
      client: .testValue,
      diagnostics: .noop,
      warmStart: nil,
      analyzeChart: { request in
        try await attempts.analyze(request)
      })
    let request = chartTestRequest(
      resultFingerprint: "retry-after-analysis-failure")
    let failedTaskKey = loader.analysisTaskKey(
      requestKey: request.key,
      preference: nil)

    let failed = await loader.analyze(
      request,
      preferredSpecificationID: nil)
    guard case .failed(_)? = failed else {
      Issue.record("A real analyzer error should remain distinct from cancellation.")
      return
    }
    #expect(
      loader.failure(for: request.key, recommendationID: nil)?.retryability
        == .retryable)

    loader.retryAnalysis(for: request.key)
    let retryTaskKey = loader.analysisTaskKey(
      requestKey: request.key,
      preference: nil)
    let retried = await loader.analyze(
      request,
      preferredSpecificationID: nil)

    #expect(failedTaskKey != retryTaskKey)
    #expect(loader.failure(for: request.key, recommendationID: nil) == nil)
    guard case .resolved? = retried else {
      Issue.record("A retry should start fresh after an analysis failure.")
      return
    }
    #expect(await attempts.count == 2)
  }

  @Test func alreadyCancelledReplacementInvalidatesAnEarlierRetryState() async {
    let invocations = ChartAnalysisInvocationCounter()
    let loader = ResultChartLoader(
      client: .testValue,
      diagnostics: .noop,
      warmStart: nil,
      analyzeChart: { _ in
        await invocations.record()
        throw PreferenceSaveTestError.failed
      })
    let failedRequest = chartTestRequest(
      resultFingerprint: "failed-before-replacement")
    let replacementRequest = chartTestRequest(
      resultFingerprint: "replacement-before-analysis")

    _ = await loader.analyze(
      failedRequest,
      preferredSpecificationID: nil)
    #expect(
      loader.failure(
        for: failedRequest.key,
        recommendationID: nil)?.retryability == .retryable)
    #expect(await invocations.count == 1)

    let cancelledReplacement = Task { @MainActor in
      await analyzeResultPresentation(
        loader,
        request: replacementRequest,
        preference: nil,
        migratePreference: { _, updated in .migrated(updated) })
    }
    cancelledReplacement.cancel()

    #expect(await cancelledReplacement.value == nil)
    #expect(await invocations.count == 1)
    loader.synchronizeRequest(failedRequest.key)

    #expect(
      loader.failure(
        for: failedRequest.key,
        recommendationID: nil) == nil)
  }

  @Test func selectionGateAcceptsOnlyTheCurrentlyLoadedRequest() async {
    let loader = ResultChartLoader(
      client: .testValue, diagnostics: .noop, warmStart: nil)
    let loadedRequest = chartTestRequest(
      resultFingerprint: "selection-gate-loaded")
    let otherRequest = chartTestRequest(
      resultFingerprint: "selection-gate-other")

    #expect(!loader.hasLoadedAnalysis(for: loadedRequest.key))
    _ = await loader.analyze(loadedRequest, preferredSpecificationID: nil)
    #expect(loader.hasLoadedAnalysis(for: loadedRequest.key))
    #expect(!loader.hasLoadedAnalysis(for: otherRequest.key))
    #expect(loader.analysis(for: loadedRequest.key) != nil)
    #expect(loader.analysis(for: otherRequest.key) == nil)
    #expect(loader.resolvedRecommendation(for: loadedRequest.key) != nil)
    #expect(loader.resolvedRecommendation(for: otherRequest.key) == nil)
  }

  @Test func mismatchedPreparationRequestCannotClearTheActiveFailure() async throws {
    let invocations = ChartAnalysisInvocationCounter()
    let loader = ResultChartLoader(
      client: .testValue,
      diagnostics: .noop,
      warmStart: nil,
      prepareChart: { _, _ in
        await invocations.record()
        throw PreferenceSaveTestError.failed
      })
    let loadedRequest = chartTestRequest(
      resultFingerprint: "keyed-preparation-loaded")
    let replacementRequest = chartTestRequest(
      resultFingerprint: "keyed-preparation-replacement")
    _ = await loader.analyze(loadedRequest, preferredSpecificationID: nil)
    let analysis = try #require(loader.analysis(for: loadedRequest.key))
    let alternative = try #require(
      chartTestRecommendations(from: analysis).dropFirst().first)

    #expect(
      loader.selectLoadedRecommendation(
        alternative.id,
        for: loadedRequest.key))
    await loader.prepareResolvedRecommendation(for: loadedRequest.key)
    let activeFailure = try #require(
      loader.failure(
        for: loadedRequest.key,
        recommendationID: alternative.id))

    guard
      case nil = loader.resolveLoadedRecommendation(
        for: replacementRequest.key,
        preferredSpecificationID: alternative.id)
    else {
      Issue.record("A replacement request must not resolve stale analysis.")
      return
    }
    await loader.prepareResolvedRecommendation(for: replacementRequest.key)

    #expect(
      loader.failure(
        for: loadedRequest.key,
        recommendationID: alternative.id) == activeFailure)
    #expect(await invocations.count == 1)
  }

  @Test func cancelledWarmAnalysisCannotChangeTheResolvedRecommendation() async throws {
    let loader = ResultChartLoader(
      client: .testValue, diagnostics: .noop, warmStart: nil)
    let request = chartTestRequest(
      resultFingerprint: "cancelled-warm-analysis")
    _ = await loader.analyze(request, preferredSpecificationID: nil)
    let analysis = try #require(loader.analysis(for: request.key))
    let recommendations = chartTestRecommendations(from: analysis)
    let original = try #require(recommendations.first)
    let alternative = try #require(recommendations.dropFirst().first)

    let cancelled = Task {
      while !Task.isCancelled {
        await Task.yield()
      }
      return await loader.analyze(
        request,
        preferredSpecificationID: alternative.id)
    }
    cancelled.cancel()

    #expect(await cancelled.value == nil)
    #expect(loader.resolvedRecommendation(for: request.key)?.id == original.id)
  }

  @Test func requestKeysKeepStructuredComponentsDistinct() {
    let delimiterInSQL = chartTestRequest(
      sql: "c|d",
      question: "e",
      resultFingerprint: "a",
      dataIdentity: "b")
    let delimiterInIdentity = chartTestRequest(
      sql: "d",
      question: "e",
      resultFingerprint: "a",
      dataIdentity: "b|c")
    let missingQuestion = chartTestRequest(
      sql: "SELECT 1",
      question: nil,
      resultFingerprint: "nil-question")
    let emptyQuestion = chartTestRequest(
      sql: "SELECT 1",
      question: "",
      resultFingerprint: "nil-question")

    #expect(delimiterInSQL.key != delimiterInIdentity.key)
    #expect(missingQuestion.key != emptyQuestion.key)
  }

  @Test func reusedAnalysisPreservesItsMatchingPreparedChart() async throws {
    let client = CREGChartAnalysisClient.testValue
    let loader = ResultChartLoader(
      client: client, diagnostics: .noop, warmStart: nil)
    let request = chartTestRequest(
      resultFingerprint: "reused-analysis-preparation")
    _ = await loader.analyze(request, preferredSpecificationID: nil)
    let analysis = try #require(loader.analysis(for: request.key))
    let recommendations = chartTestRecommendations(from: analysis)
    let alternative = try #require(recommendations.dropFirst().first)

    #expect(loader.selectLoadedRecommendation(alternative.id, for: request.key))
    await loader.prepareResolvedRecommendation(for: request.key)
    let preparationKey = loader.preparationTaskKey(
      recommendationID: alternative.id)
    #expect(
      loader.matchingPreparedChart(for: alternative.id)?.recommendation.id
        == alternative.id)

    _ = await loader.analyze(
      request,
      preferredSpecificationID: alternative.id)

    #expect(
      loader.matchingPreparedChart(for: alternative.id)?.recommendation.id
        == alternative.id)
    #expect(
      loader.preparationTaskKey(recommendationID: alternative.id)
        == preparationKey)
  }

  @Test func loadedRecommendationSelectionRejectsAnUnknownID() async throws {
    let loader = ResultChartLoader(
      client: .testValue, diagnostics: .noop, warmStart: nil)
    let request = chartTestRequest(
      resultFingerprint: "invalid-loaded-recommendation-selection")
    _ = await loader.analyze(request, preferredSpecificationID: nil)
    let selectedBefore = try #require(
      loader.resolvedRecommendation(for: request.key)?.id)
    let unknownID = chartTestRecommendationID("unknown|category|value")

    #expect(!loader.selectLoadedRecommendation(unknownID, for: request.key))
    #expect(loader.resolvedRecommendation(for: request.key)?.id == selectedBefore)
  }

  @Test func loadedRecommendationSelectionRejectsAReplacementRequest() async throws {
    let loader = ResultChartLoader(
      client: .testValue, diagnostics: .noop, warmStart: nil)
    let loadedRequest = chartTestRequest(
      resultFingerprint: "stale-recommendation-loaded")
    let replacementRequest = chartTestRequest(
      resultFingerprint: "stale-recommendation-replacement")
    _ = await loader.analyze(loadedRequest, preferredSpecificationID: nil)
    let selectedBefore = try #require(
      loader.resolvedRecommendation(for: loadedRequest.key)?.id)
    let analysis = try #require(loader.analysis(for: loadedRequest.key))
    let alternative = try #require(
      chartTestRecommendations(from: analysis)
        .dropFirst().first)

    #expect(
      !loader.selectLoadedRecommendation(
        alternative.id,
        for: replacementRequest.key))
    #expect(
      loader.resolvedRecommendation(for: loadedRequest.key)?.id
        == selectedBefore)
  }

  @Test func preparedChartIsExposedOnlyForItsRecommendation() async throws {
    let loader = ResultChartLoader(
      client: .testValue, diagnostics: .noop, warmStart: nil)
    let request = chartTestRequest(
      resultFingerprint: "matching-prepared-chart")
    _ = await loader.analyze(request, preferredSpecificationID: nil)
    let analysis = try #require(loader.analysis(for: request.key))
    let recommendations = chartTestRecommendations(from: analysis)
    let primary = try #require(recommendations.first)
    let alternative = try #require(recommendations.dropFirst().first)

    #expect(
      loader.matchingPreparedChart(for: primary.id)?.recommendation.id
        == primary.id)
    #expect(
      loader.matchingPreparedChart(for: alternative.id)?.recommendation.id
        == nil)
  }

  @Test func resolvingPreparedPrimaryClearsAnAlternativePreparationFailure()
    async throws
  {
    let client = CREGChartAnalysisClient.testValue
    let diagnostics = DiagnosticEventRecorder()
    let loader = ResultChartLoader(
      client: client,
      diagnostics: diagnostics.client,
      warmStart: nil,
      prepareChart: { _, _ in
        throw PreferenceSaveTestError.failed
      })
    let request = chartTestRequest(
      resultFingerprint: "failure-followed-by-primary-resolution")
    _ = await loader.analyze(request, preferredSpecificationID: nil)
    let analysis = try #require(loader.analysis(for: request.key))
    let recommendations = chartTestRecommendations(from: analysis)
    let primary = try #require(recommendations.first)
    let alternative = try #require(recommendations.dropFirst().first)

    _ = loader.resolveLoadedRecommendation(
      for: request.key,
      preferredSpecificationID: alternative.id)
    await loader.prepareResolvedRecommendation(for: request.key)
    #expect(loader.matchingPreparedChart(for: alternative.id) == nil)
    #expect(
      loader.failure(
        for: request.key,
        recommendationID: alternative.id)?.stage == .preparation)
    #expect(
      loader.failure(
        for: request.key,
        recommendationID: primary.id) == nil)

    _ = loader.resolveLoadedRecommendation(
      for: request.key,
      preferredSpecificationID: primary.id)

    #expect(
      loader.matchingPreparedChart(for: primary.id)?.recommendation.id
        == primary.id)
    #expect(
      loader.failure(
        for: request.key,
        recommendationID: primary.id) == nil)

    _ = loader.resolveLoadedRecommendation(
      for: request.key,
      preferredSpecificationID: alternative.id)
    await loader.prepareResolvedRecommendation(for: request.key)

    #expect(diagnostics.events.count == 2)
  }

  @Test func cancellationErrorFromLivePreparationRemainsRetryable() async throws {
    let diagnostics = DiagnosticEventRecorder()
    let loader = ResultChartLoader(
      client: .testValue,
      diagnostics: diagnostics.client,
      warmStart: nil,
      prepareChart: { _, _ in throw CancellationError() })
    let request = chartTestRequest(
      resultFingerprint: "live-preparation-cancellation-error")
    _ = await loader.analyze(request, preferredSpecificationID: nil)
    let analysis = try #require(loader.analysis(for: request.key))
    let recommendation = try #require(
      chartTestRecommendations(from: analysis).dropFirst().first)

    _ = loader.resolveLoadedRecommendation(
      for: request.key,
      preferredSpecificationID: recommendation.id)
    await loader.prepareResolvedRecommendation(for: request.key)

    #expect(
      loader.failure(
        for: request.key,
        recommendationID: recommendation.id)?.retryability == .retryable)
    #expect(diagnostics.events.count == 1)
    #expect(diagnostics.events.first?.code == "chart_preparation_failed")
  }

  @Test func deterministicPreparationFailureIsTerminalAndCannotRetry() async throws {
    let invocations = ChartAnalysisInvocationCounter()
    let diagnostics = DiagnosticEventRecorder()
    let loader = ResultChartLoader(
      client: .testValue,
      diagnostics: diagnostics.client,
      warmStart: nil,
      prepareChart: { _, recommendationID in
        await invocations.record()
        throw AutoChartPreparationError.recommendationUnavailable(
          recommendationID)
      })
    let request = chartTestRequest(
      resultFingerprint: "terminal-preparation-failure")
    _ = await loader.analyze(request, preferredSpecificationID: nil)
    let analysis = try #require(loader.analysis(for: request.key))
    let recommendation = try #require(
      chartTestRecommendations(from: analysis).dropFirst().first)
    _ = loader.resolveLoadedRecommendation(
      for: request.key,
      preferredSpecificationID: recommendation.id)

    await loader.prepareResolvedRecommendation(for: request.key)

    let failure = try #require(
      loader.failure(
        for: request.key,
        recommendationID: recommendation.id))
    let failedKey = loader.preparationTaskKey(
      recommendationID: recommendation.id)
    #expect(failure.stage == .preparation)
    #expect(failure.kind == .invalidSpecification)
    #expect(failure.retryability == .terminal)
    #expect(diagnostics.events.count == 1)
    #expect(
      diagnostics.events.first?.code
        == "chart_preparation_invalid_specification")
    #expect(
      diagnostics.events.first?.summary
        == "Chart preparation failed because the chart specification was invalid.")
    #expect(
      !loader.retryFailure(
        for: request.key,
        recommendationID: recommendation.id))
    #expect(
      loader.preparationTaskKey(recommendationID: recommendation.id)
        == failedKey)

    await loader.prepareResolvedRecommendation(for: request.key)
    #expect(await invocations.count == 1)
    #expect(diagnostics.events.count == 1)
  }

  @Test func independentLoadersSharePreparationDiagnosticsUntilEveryRelease() async throws {
    let client = CREGChartAnalysisClient.testValue
    let diagnostics = DiagnosticEventRecorder()
    let invocations = ChartAnalysisInvocationCounter()
    let prepare: ResultChartLoader.PrepareChart = { _, _ in
      await invocations.record()
      throw PreferenceSaveTestError.failed
    }
    let first = ResultChartLoader(
      client: client,
      diagnostics: diagnostics.client,
      warmStart: nil,
      prepareChart: prepare)
    let viewer = ResultChartLoader(
      client: client,
      diagnostics: diagnostics.client,
      warmStart: nil,
      prepareChart: prepare)
    let request = chartTestRequest(
      resultFingerprint: "shared-preparation-failure-diagnostic")

    for loader in [first, viewer] {
      _ = await loader.analyze(request, preferredSpecificationID: nil)
      let analysis = try #require(loader.analysis(for: request.key))
      let recommendation = try #require(
        chartTestRecommendations(from: analysis).dropFirst().first)
      _ = loader.resolveLoadedRecommendation(
        for: request.key,
        preferredSpecificationID: recommendation.id)
      await loader.prepareResolvedRecommendation(for: request.key)
    }

    #expect(await invocations.count == 2)
    #expect(diagnostics.events.count == 1)

    let recommendation = try #require(
      first.resolvedRecommendation(for: request.key))
    #expect(
      first.retryFailure(
        for: request.key,
        recommendationID: recommendation.id))
    await first.prepareResolvedRecommendation(for: request.key)

    #expect(await invocations.count == 3)
    #expect(diagnostics.events.count == 1)

    let analysis = try #require(first.analysis(for: request.key))
    let primary = try #require(chartTestRecommendations(from: analysis).first)
    for loader in [first, viewer] {
      _ = loader.resolveLoadedRecommendation(
        for: request.key,
        preferredSpecificationID: primary.id)
    }
    _ = first.resolveLoadedRecommendation(
      for: request.key,
      preferredSpecificationID: recommendation.id)
    await first.prepareResolvedRecommendation(for: request.key)

    #expect(await invocations.count == 4)
    #expect(diagnostics.events.count == 2)
  }

  @Test func supersededRecommendationCannotFailAfterNewerSuccess() async throws {
    let client = CREGChartAnalysisClient.testValue
    let gate = SupersededChartPreparationGate()
    let loader = ResultChartLoader(
      client: client,
      diagnostics: .noop,
      warmStart: nil,
      prepareChart: { analysis, recommendationID in
        try await gate.prepare(analysis, recommendationID: recommendationID)
      })
    let request = chartTestRequest(
      resultFingerprint: "superseded-preparation")
    _ = await loader.analyze(request, preferredSpecificationID: nil)
    let analysis = try #require(loader.analysis(for: request.key))
    let recommendations = chartTestRecommendations(from: analysis)
    let primary = try #require(recommendations.first)
    let alternative = try #require(recommendations.dropFirst().first)

    _ = loader.resolveLoadedRecommendation(
      for: request.key,
      preferredSpecificationID: alternative.id)
    let first = Task {
      await loader.prepareResolvedRecommendation(for: request.key)
    }
    await gate.waitUntilFirstPreparationStarts()
    _ = loader.resolveLoadedRecommendation(
      for: request.key,
      preferredSpecificationID: primary.id)
    await loader.prepareResolvedRecommendation(for: request.key)
    #expect(
      loader.matchingPreparedChart(for: primary.id)?.recommendation.id
        == primary.id)
    #expect(
      loader.failure(
        for: request.key,
        recommendationID: primary.id) == nil)

    await gate.releaseFirstPreparation()
    await first.value
    #expect(
      loader.matchingPreparedChart(for: primary.id)?.recommendation.id
        == primary.id)
    #expect(
      loader.failure(
        for: request.key,
        recommendationID: primary.id) == nil)
  }

  @Test func explicitRetryClearsFailureAndRekeysTheRecommendation() async throws {
    let client = CREGChartAnalysisClient.testValue
    let loader = ResultChartLoader(
      client: client,
      diagnostics: .noop,
      warmStart: nil,
      prepareChart: { _, _ in
        throw PreferenceSaveTestError.failed
      })
    let request = chartTestRequest(resultFingerprint: "retry-preparation")
    _ = await loader.analyze(request, preferredSpecificationID: nil)
    let analysis = try #require(loader.analysis(for: request.key))
    let recommendations = chartTestRecommendations(from: analysis)
    let alternative = try #require(recommendations.dropFirst().first)

    _ = loader.resolveLoadedRecommendation(
      for: request.key,
      preferredSpecificationID: alternative.id)
    await loader.prepareResolvedRecommendation(for: request.key)
    let failedKey = loader.preparationTaskKey(
      recommendationID: alternative.id)
    #expect(
      loader.failure(
        for: request.key,
        recommendationID: alternative.id) != nil)

    _ = await loader.analyze(
      request,
      preferredSpecificationID: alternative.id)
    #expect(
      loader.failure(
        for: request.key,
        recommendationID: alternative.id) != nil)
    #expect(
      loader.preparationTaskKey(recommendationID: alternative.id) == failedKey)

    #expect(
      loader.retryFailure(
        for: request.key,
        recommendationID: alternative.id))
    let retryKey = loader.preparationTaskKey(
      recommendationID: alternative.id)

    #expect(
      loader.failure(
        for: request.key,
        recommendationID: alternative.id) == nil)
    #expect(failedKey != retryKey)
  }

  @Test func retryInvalidatesSuspendedPreparationBeforeReplacementStarts()
    async throws
  {
    let gate = SupersededChartPreparationGate()
    let loader = ResultChartLoader(
      client: .testValue,
      diagnostics: .noop,
      warmStart: nil,
      prepareChart: { analysis, recommendationID in
        try await gate.prepare(analysis, recommendationID: recommendationID)
      })
    let request = chartTestRequest(
      resultFingerprint: "retry-suspended-preparation")
    _ = await loader.analyze(request, preferredSpecificationID: nil)
    let analysis = try #require(loader.analysis(for: request.key))
    let recommendation = try #require(
      chartTestRecommendations(from: analysis).dropFirst().first)

    _ = loader.resolveLoadedRecommendation(
      for: request.key,
      preferredSpecificationID: recommendation.id)
    let suspended = Task {
      await loader.prepareResolvedRecommendation(for: request.key)
    }
    await gate.waitUntilFirstPreparationStarts()

    loader.retryPreparation()
    #expect(
      loader.failure(
        for: request.key,
        recommendationID: recommendation.id) == nil)

    await gate.releaseFirstPreparation()
    await suspended.value
    #expect(
      loader.failure(
        for: request.key,
        recommendationID: recommendation.id) == nil)
  }

  @Test func firstCallGateRemembersReleaseBeforePause() async {
    let gate = FirstCallGate()

    await gate.releaseFirstCall()

    #expect(await gate.pauseIfFirstCall())
    #expect(!(await gate.pauseIfFirstCall()))
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

@MainActor
private final class ResultPresentationStateBox {
  var value: ResultPresentationState

  init(_ value: ResultPresentationState) {
    self.value = value
  }
}

private actor ChartAnalysisCancellationProbe {
  private var didStart = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var cancellationContinuation: CheckedContinuation<Void, Never>?
  private(set) var cancellationWasObserved = false

  func waitUntilCancelled() async throws {
    didStart = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }

    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if cancellationWasObserved {
          continuation.resume()
        } else {
          cancellationContinuation = continuation
        }
      }
    } onCancel: {
      Task { await self.observeCancellation() }
    }
    try Task.checkCancellation()
  }

  func waitUntilStarted() async {
    guard !didStart else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  private func observeCancellation() {
    cancellationWasObserved = true
    cancellationContinuation?.resume()
    cancellationContinuation = nil
  }
}

private actor ChartAnalysisInvocationCounter {
  private(set) var count = 0

  func record() {
    count += 1
  }
}

private final class TestTaskCancellationHandle: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelTask: (@Sendable () -> Void)?

  func install(_ cancelTask: @escaping @Sendable () -> Void) {
    lock.lock()
    self.cancelTask = cancelTask
    lock.unlock()
  }

  func cancel() {
    lock.lock()
    let cancelTask = cancelTask
    lock.unlock()
    cancelTask?()
  }
}

private actor FailingFirstChartAnalysis {
  private let client = CREGChartAnalysisClient.testValue
  private(set) var count = 0

  func analyze(
    _ request: ResultChartLoader.Request
  ) async throws -> AutoChartAnalysis<Int> {
    count += 1
    if count == 1 {
      throw PreferenceSaveTestError.failed
    }
    return try await client.analyze(
      result: request.result,
      sql: request.sql,
      question: request.question,
      resultFingerprint: request.resultFingerprint,
      dataIdentity: request.dataIdentity)
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
  private var releaseRequested = false

  func pauseIfFirstCall() async -> Bool {
    callCount += 1
    guard callCount == 1 else { return false }
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    if releaseRequested {
      releaseRequested = false
      return true
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
    if let releaseContinuation {
      self.releaseContinuation = nil
      releaseContinuation.resume()
    } else if callCount == 0 {
      releaseRequested = true
    }
  }
}
