import AutoTableCharts
import ComposableArchitecture
import Foundation
import Testing

@testable import CREGEngine
@testable import CREGFeatures

@Suite struct ResultPresentationPolicyTests {
  @Test func preparationFailureDisplaysTableAndAllowsPersistingTable() throws {
    let specificationID = chartTestRecommendationID("policy|line|date|value")

    #expect(
      ResultViewerLogic.effectivePresentationMode(
        requestedMode: .chart,
        hasChart: true,
        preparationFailed: true) == .table)
    let changed = try #require(
      ResultViewerLogic.preferenceForModeSelection(
        .table,
        requestedMode: .chart,
        specificationID: specificationID,
        preparationFailed: true))
    #expect(changed.mode == .table)
    #expect(changed.specificationID == specificationID)
  }

  @Test func deterministicPreparationFailureCannotBlindlyRetryChart() {
    #expect(
      ResultViewerLogic.preferenceForModeSelection(
        .chart,
        requestedMode: .table,
        specificationID: chartTestRecommendationID("policy|line|date|value"),
        preparationFailed: true) == nil)
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
}

@MainActor
@Suite struct ResultPresentationRetryTests {
  @Test func reducerRetriesAnIdenticalPreferenceAfterSaveFailure() async {
    let preference = ResultPresentationPreference(
      mode: .table,
      specificationID: chartTestRecommendationID("policy|bar|fund|value"))
    let message = ChatMessage(
      id: UUID(),
      role: .assistant,
      body: .answer(
        result: QueryResult(columns: ["fund"], rows: [[.text("Core")]]),
        narration: "Saved answer.",
        sql: "SELECT fund FROM portfolio",
        notice: nil),
      createdAt: Date(timeIntervalSince1970: 1),
      devInfo: nil)
    let recorder = FailingPreferenceRecorder()
    var history = HistoryClient.noop()
    history.updateResultPresentation = { _, updated in
      if recorder.recordAttempt(message: updated) {
        throw ResultPresentationPolicyTestError.failed
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
          error: ResultPresentationPolicyTestError.failed)))

    await store.send(
      .resultPresentationChanged(
        messageID: message.id,
        preference: preference))
    await store.finish()

    #expect(recorder.attemptCount == 2)
    #expect(recorder.preference == preference)
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
    throw ResultPresentationPolicyTestError.failed
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

private enum ResultPresentationPolicyTestError: Error, Sendable {
  case failed
}

private final class FailingPreferenceRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedAttemptCount = 0
  private var storedPreference: ResultPresentationPreference?

  /// Returns true only for the first attempt, which the test dependency turns
  /// into a durable-write failure.
  func recordAttempt(message: ChatMessage) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    storedAttemptCount += 1
    guard storedAttemptCount > 1 else { return true }
    storedPreference = message.resultPresentation
    return false
  }

  var attemptCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedAttemptCount
  }

  var preference: ResultPresentationPreference? {
    lock.lock()
    defer { lock.unlock() }
    return storedPreference
  }
}
