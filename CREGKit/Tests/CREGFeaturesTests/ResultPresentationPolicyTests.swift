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
        return .migrated(updated)
      },
      diagnostics: .noop)

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
  @Test func obsoletePolicyClearsPinInsteadOfPersistingTheDefault() async throws {
    let client = CREGChartAnalysisClient.testValue
    let loader = ResultChartLoader(client: client, warmStart: nil)
    let diagnostics = DiagnosticEventRecorder()
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
      },
      diagnostics: diagnostics.client)

    let resolvedID = try #require(update?.resolvedSpecificationID)
    #expect(resolvedID == loader.analysis?.primaryChart?.recommendation.id)
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
    let loader = ResultChartLoader(client: client, warmStart: nil)
    let diagnostics = DiagnosticEventRecorder()
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
      },
      diagnostics: diagnostics.client)

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
    #expect(diagnostics.events.isEmpty)
  }

  @Test func retainedPreferenceReresolvesLoaderOwnedState() async throws {
    let loader = ResultChartLoader(client: .testValue, warmStart: nil)
    let diagnostics = DiagnosticEventRecorder()
    let request = chartTestRequest(
      resultFingerprint: "viewer-loader-owned-resolution",
      dataIdentity: "viewer-loader-owned-message")
    _ = await loader.analyze(request, preferredSpecificationID: nil)
    let analysis = try #require(loader.analysis)
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
      migratePreference: { _, _ in .retained(authoritative) },
      diagnostics: diagnostics.client)

    #expect(update?.resolvedSpecificationID == alternative.id)
    #expect(loader.resolvedRecommendation?.id == alternative.id)
    #expect(loader.matchingPreparedChart(for: primary.id) == nil)
    #expect(loader.matchingPreparedChart(for: alternative.id) == nil)
    #expect(!loader.preparationFailed(for: alternative.id))
    #expect(diagnostics.events.isEmpty)
  }

  @Test func rejectedMigrationReconcilesAnAuthoritativeObsoletePin() async throws {
    let client = CREGChartAnalysisClient.testValue
    let loader = ResultChartLoader(client: client, warmStart: nil)
    let diagnostics = DiagnosticEventRecorder()
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
    var attempts: [(
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
      },
      diagnostics: diagnostics.client)

    guard
      case .resolved(
        let specificationID,
        preference: .retained(let retainedPreference))? = update
    else {
      Issue.record("The authoritative obsolete pin should be reconciled.")
      return
    }
    let primary = try #require(loader.analysis?.primaryChart?.recommendation)
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
    let loader = ResultChartLoader(client: client, warmStart: nil)
    let diagnostics = DiagnosticEventRecorder()
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
      migratePreference: migration,
      diagnostics: diagnostics.client)
    _ = await analyzeResultPresentation(
      loader,
      request: request,
      preference: previous,
      migratePreference: migration,
      diagnostics: diagnostics.client)

    #expect(diagnostics.events.count == 1)
    #expect(diagnostics.events.first?.category == .presentation)
    #expect(diagnostics.events.first?.code == "chart_recommendation_policy_changed")
  }

  @Test func retainedPreviousPreferenceTerminatesReconciliation() async throws {
    let loader = ResultChartLoader(client: .testValue, warmStart: nil)
    let diagnostics = DiagnosticEventRecorder()
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
      },
      diagnostics: diagnostics.client)

    guard
      case .resolved(
        let specificationID,
        preference: .stalled(let resolvedPreference))? = update
    else {
      Issue.record("The repeated authoritative preference should terminate reconciliation.")
      return
    }
    let primary = try #require(loader.analysis?.primaryChart?.recommendation)
    #expect(attempts == 1)
    #expect(resolvedPreference.mode == previous.mode)
    #expect(resolvedPreference.specificationID == primary.id)
    #expect(specificationID == primary.id)
    #expect(loader.resolvedRecommendation?.id == primary.id)
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
    guard case .resolved(let replacementRecommendation, _, _)? = replacement else {
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

    #expect(!loader.hasLoadedAnalysis(for: loadedRequest.key))
    _ = await loader.analyze(loadedRequest, preferredSpecificationID: nil)
    #expect(loader.hasLoadedAnalysis(for: loadedRequest.key))
    #expect(!loader.hasLoadedAnalysis(for: otherRequest.key))
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
    let loader = ResultChartLoader(client: client, warmStart: nil)
    let request = chartTestRequest(
      resultFingerprint: "reused-analysis-preparation")
    _ = await loader.analyze(request, preferredSpecificationID: nil)
    let analysis = try #require(loader.analysis)
    let recommendations = chartTestRecommendations(from: analysis)
    let alternative = try #require(recommendations.dropFirst().first)

    _ = loader.resolveLoadedRecommendation(
      preferredSpecificationID: alternative.id)
    await loader.prepareResolvedRecommendation()
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

  @Test func preparedChartIsExposedOnlyForItsRecommendation() async throws {
    let loader = ResultChartLoader(client: .testValue, warmStart: nil)
    let request = chartTestRequest(
      resultFingerprint: "matching-prepared-chart")
    _ = await loader.analyze(request, preferredSpecificationID: nil)
    let analysis = try #require(loader.analysis)
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

    _ = loader.resolveLoadedRecommendation(
      preferredSpecificationID: alternative.id)
    await loader.prepareResolvedRecommendation()
    #expect(loader.matchingPreparedChart(for: alternative.id) == nil)
    #expect(loader.preparationFailed(for: alternative.id))
    #expect(!loader.preparationFailed(for: primary.id))

    _ = loader.resolveLoadedRecommendation(
      preferredSpecificationID: primary.id)

    #expect(
      loader.matchingPreparedChart(for: primary.id)?.recommendation.id
        == primary.id)
    #expect(!loader.preparationFailed(for: primary.id))
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

    _ = loader.resolveLoadedRecommendation(
      preferredSpecificationID: alternative.id)
    let first = Task { await loader.prepareResolvedRecommendation() }
    await gate.waitUntilFirstPreparationStarts()
    _ = loader.resolveLoadedRecommendation(
      preferredSpecificationID: primary.id)
    await loader.prepareResolvedRecommendation()
    #expect(
      loader.matchingPreparedChart(for: primary.id)?.recommendation.id
        == primary.id)
    #expect(!loader.preparationFailed(for: primary.id))

    await gate.releaseFirstPreparation()
    await first.value
    #expect(
      loader.matchingPreparedChart(for: primary.id)?.recommendation.id
        == primary.id)
    #expect(!loader.preparationFailed(for: primary.id))
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

    _ = loader.resolveLoadedRecommendation(
      preferredSpecificationID: alternative.id)
    await loader.prepareResolvedRecommendation()
    let failedKey = loader.preparationTaskKey(
      recommendationID: alternative.id)
    #expect(loader.preparationFailed(for: alternative.id))

    _ = await loader.analyze(
      request,
      preferredSpecificationID: alternative.id)
    #expect(loader.preparationFailed(for: alternative.id))
    #expect(
      loader.preparationTaskKey(recommendationID: alternative.id) == failedKey)

    loader.retryPreparation()
    let retryKey = loader.preparationTaskKey(
      recommendationID: alternative.id)

    #expect(!loader.preparationFailed(for: alternative.id))
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

    _ = loader.resolveLoadedRecommendation(
      preferredSpecificationID: recommendation.id)
    let suspended = Task { await loader.prepareResolvedRecommendation() }
    await gate.waitUntilFirstPreparationStarts()

    loader.retryPreparation()
    #expect(!loader.preparationFailed(for: recommendation.id))

    await gate.releaseFirstPreparation()
    await suspended.value
    #expect(!loader.preparationFailed(for: recommendation.id))
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
