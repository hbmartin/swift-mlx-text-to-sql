import ComposableArchitecture
import Foundation
import Testing

@testable import CREGEngine
@testable import CREGFeatures

@Suite struct BuildChannelTests {
  private func configuration(
    debugIdentity: DebugModelIdentity? = nil,
    policyVersion: String? = nil
  ) -> ProductionGenerationConfiguration {
    ProductionGenerationConfiguration(
      model: .selectionPending,
      gcd: .off,
      temperature: 0,
      topP: 1,
      topK: 0,
      maxTokens: 128,
      candidateCount: 1,
      sampleTemperature: 0,
      alwaysVote: false,
      policyVersion: policyVersion,
      debugModelIdentity: debugIdentity)
  }

  private let identity = DebugModelIdentity(
    modelKey: "debug-model",
    baseModelKey: "base-model",
    trainingRunID: "pinned-run",
    selectedIteration: 600,
    selectedCheckpointSHA256: String(repeating: "a", count: 64),
    localEvidenceStatus: "complete",
    wandbReceiptRequired: false)

  @Test func parsesEveryExplicitChannelAndFailsClosed() throws {
    #expect(
      try BuildChannel.load(info: [BuildChannel.infoKey: "debug"]) == .debug)
    #expect(
      try BuildChannel.load(info: [BuildChannel.infoKey: "beta"]) == .beta)
    #expect(
      try BuildChannel.load(info: [BuildChannel.infoKey: "release"]) == .release)
    #expect(throws: BuildChannel.Error.missing) {
      try BuildChannel.load(info: [:])
    }
    #expect(throws: BuildChannel.Error.unknown("nightly")) {
      try BuildChannel.load(info: [BuildChannel.infoKey: "nightly"])
    }
  }

  @Test func debugAndBetaAcceptVerifiedOrCandidateSelectionsWithoutPins() throws {
    for channel in [BuildChannel.debug, .beta] {
      try channel.validate(configuration(), info: [:])
      try channel.validate(
        configuration(debugIdentity: identity), info: [:])
    }
  }

  @Test func releaseRefusesCandidatesAndRequiresBoundedPolicy() throws {
    #expect(throws: BuildChannel.Error.candidateForbidden) {
      try BuildChannel.release.validate(
        configuration(debugIdentity: identity), info: [:])
    }
    #expect(throws: BuildChannel.Error.boundedPolicyRequired) {
      try BuildChannel.release.validate(configuration(), info: [:])
    }
    try BuildChannel.release.validate(
      configuration(policyVersion: "bounded-three-generation-v1"), info: [:])
  }
}

@Suite struct ModelPreparationContractTests {
  @Test func compatibilityEligibilityExcludesIntegrityFailures() {
    let integrityStages: Set<ModelPreparationStage> = [
      ModelPreparationStage.buildPolicy,
      .receiptValidation,
      .metalResource,
    ]
    let compatibilityStages: Set<ModelPreparationStage> = [
      .containerLoad,
      .qkvFusion,
      .promptCache,
      .ngramDraft,
      .outputVocabulary,
    ]
    #expect(integrityStages.isDisjoint(with: compatibilityStages))
    #expect(
      integrityStages.union(compatibilityStages)
        == Set(ModelPreparationStage.allCases))
    for stage in integrityStages {
      #expect(!stage.allowsCompatibilityRetry)
    }
    for stage in compatibilityStages {
      #expect(stage.allowsCompatibilityRetry)
    }
  }

  @Test func legacyTelemetryDefaultsToEvaluated() throws {
    let data = Data(
      #"{"schemaVersion":3,"originalQuestion":"legacy"}"#.utf8)
    let telemetry = try JSONDecoder().decode(TurnTelemetry.self, from: data)
    #expect(telemetry.runtimeMode == .evaluated)
    #expect(telemetry.isEvaluated)
  }

  @Test func currentTelemetryRetainsCompatibilityTag() throws {
    let source = TurnTelemetry(
      originalQuestion: "question",
      runtimeMode: .compatibility)
    let decoded = try JSONDecoder().decode(
      TurnTelemetry.self,
      from: JSONEncoder().encode(source))
    #expect(decoded.schemaVersion == TurnTelemetry.currentSchemaVersion)
    #expect(decoded.runtimeMode == .compatibility)
    #expect(!decoded.isEvaluated)
  }

  @Test func legacyFeedbackDefaultsToEvaluated() throws {
    let source = AnswerFeedback(
      messageID: UUID(),
      verdict: .helpful,
      updatedAt: Date(timeIntervalSince1970: 1))
    var object = try #require(
      JSONSerialization.jsonObject(
        with: JSONEncoder().encode(source)) as? [String: Any])
    object.removeValue(forKey: "runtimeMode")
    object.removeValue(forKey: "isEvaluated")

    let decoded = try JSONDecoder().decode(
      AnswerFeedback.self,
      from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.runtimeMode == .evaluated)
    #expect(decoded.isEvaluated)
  }

  @Test func journalDetectsOnlyUnfinishedAttempts() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("creg-preparation-test-\(UUID().uuidString)")
    let url = directory.appendingPathComponent("model-preparation.json")
    let store = ModelPreparationJournalStore(
      url: url,
      processSessionID: UUID(1))

    try await store.begin(mode: .evaluated, environment: ["build": "test"])
    try await store.stageStarted(.promptCache, mode: .evaluated)
    // A live attempt owned by this process is not crash recovery input.
    #expect(await store.unfinishedAttempt() == nil)
    let relaunched = ModelPreparationJournalStore(
      url: url,
      processSessionID: UUID(2))
    #expect(await relaunched.unfinishedAttempt()?.stage == .promptCache)

    try await store.complete(
      ModelPreparationReport(mode: .evaluated, elapsedMilliseconds: 1))
    let completedRelaunch = ModelPreparationJournalStore(
      url: url,
      processSessionID: UUID(3))
    #expect(await completedRelaunch.unfinishedAttempt() == nil)
    #expect(await store.exportData() != nil)
  }
}

@MainActor
@Suite struct ModelPreparationFeatureTests {
  @Test func appearanceSynchronizesExistingChatWhilePreparing() async {
    var state = AppFeature.State()
    state.chat = ChatFeature.State(conversationID: UUID(9))
    state.didRequestPreparationJournalInspection = true
    let store = TestStore(initialState: state) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.onAppear)
    await store.finish()

    #expect(store.state.chat?.isSubmissionEnabled == false)
  }

  @Test func journalStartupSynchronizesExistingChatWhilePreparing() async {
    let pipeline = QueryPipeline(
      prepareMode: { mode in
        ModelPreparationReport(mode: mode, elapsedMilliseconds: 0)
      },
      runtimeMode: { .evaluated },
      run: { _, _ in AsyncStream { $0.finish() } })
    var state = AppFeature.State()
    state.chat = ChatFeature.State(conversationID: UUID(9))
    state.didRequestPreparationJournalInspection = true
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.queryPipeline = pipeline
      $0.modelPreparationJournal = .noop
    }
    store.exhaustivity = .off

    await store.send(.preparationJournalLoaded(nil)) {
      $0.didHandlePreparationJournalInspection = true
      $0.modelPreparationInFlight = true
      $0.chat?.isSubmissionEnabled = false
    }
    await store.receive(\.modelPrepared)
    await store.finish()
  }

  @Test func developerModeSurvivesStateReconstruction() {
    let defaults = UserDefaults.inMemory
    defaults.set(true, forKey: DeveloperModePreference.storageKey)
    let state = withDependencies {
      $0.defaultAppStorage = defaults
    } operation: {
      AppFeature.State()
    }
    #expect(state.developerMode)
  }

  @Test func developerCanManuallyActivateCompatibilityMode() async {
    let modes = LockIsolated<[ModelRuntimeMode]>([])
    let pipeline = QueryPipeline(
      prepareMode: { mode in
        modes.withValue { $0.append(mode) }
        return ModelPreparationReport(mode: mode, elapsedMilliseconds: 2)
      },
      runtimeMode: { .compatibility },
      run: { _, _ in AsyncStream { $0.finish() } })
    var state = AppFeature.State()
    state.$developerMode.withLock { $0 = true }
    state.modelReadiness = .failed(
      ModelPreparationFailure(
        code: "model_prompt_cache_failed",
        stage: .promptCache,
        mode: .evaluated,
        userMessage: "failed",
        diagnostic: "safe"))
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.queryPipeline = pipeline
      $0.modelPreparationJournal = .noop
    }
    store.exhaustivity = .off

    await store.send(.retryCompatibilityPreparation)
    await store.receive(\.modelPrepared)
    await store.finish()

    #expect(modes.value == [.compatibility])
    #expect(
      store.state.modelPreparationReport?.mode == .compatibility)
    #expect(store.state.modelReadiness == .ready)
  }

  @Test func repeatedAppearanceDoesNotRestartLivePreparation() async {
    let inspections = LockIsolated(0)
    let modes = LockIsolated<[ModelRuntimeMode]>([])
    var journal = ModelPreparationJournalClient.noop
    journal.unfinishedAttempt = {
      inspections.withValue { $0 += 1 }
      return nil
    }
    let pipeline = QueryPipeline(
      prepareMode: { mode in
        modes.withValue { $0.append(mode) }
        return ModelPreparationReport(mode: mode, elapsedMilliseconds: 0)
      },
      runtimeMode: { .evaluated },
      run: { _, _ in AsyncStream { $0.finish() } })
    var state = AppFeature.State()
    state.chat = ChatFeature.State(conversationID: UUID(9))
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.queryPipeline = pipeline
      $0.modelPreparationJournal = journal
    }
    store.exhaustivity = .off

    await store.send(.onAppear)
    await store.finish()
    await store.skipReceivedActions()
    await store.send(.onAppear)
    await store.finish()
    await store.skipReceivedActions()

    #expect(inspections.value == 1)
    #expect(modes.value == [.evaluated])
    #expect(store.state.modelReadiness == .ready)
  }

  @Test func retriesAreRejectedWhileTurnsOrQueuesOwnTheRuntime() async {
    let modes = LockIsolated<[ModelRuntimeMode]>([])
    let pipeline = QueryPipeline(
      prepareMode: { mode in
        modes.withValue { $0.append(mode) }
        return ModelPreparationReport(mode: mode, elapsedMilliseconds: 0)
      },
      runtimeMode: { .compatibility },
      run: { _, _ in AsyncStream { $0.finish() } })

    var queuedState = AppFeature.State()
    queuedState.modelReadiness = .ready
    queuedState.modelPreparationReport = ModelPreparationReport(
      mode: .compatibility, elapsedMilliseconds: 0)
    queuedState.queue = [
      QueuedQuestion(
        id: UUID(1),
        conversationID: UUID(2),
        question: "Queued",
        submittedAt: Date(timeIntervalSince1970: 1))
    ]
    let queuedDiagnosis = AppFeature.PendingScopeDiagnosis(
      conversationID: UUID(2),
      messageID: UUID(20),
      context: FollowUpSuggestionContext(
        sourceAssistantMessageID: UUID(20),
        question: "Queued recovery",
        standaloneQuestion: "Queued recovery",
        seed: .turnFailure(reason: .generationExhausted, scopeVerdict: nil)))
    queuedState.pendingScopeDiagnosis = queuedDiagnosis
    let queuedStore = TestStore(initialState: queuedState) {
      AppFeature()
    } withDependencies: {
      $0.queryPipeline = pipeline
    }
    queuedStore.exhaustivity = .off
    await queuedStore.send(.retryPreparation)
    await queuedStore.finish()
    #expect(queuedStore.state.pendingScopeDiagnosis == queuedDiagnosis)

    var activeState = AppFeature.State()
    activeState.$developerMode.withLock { $0 = true }
    activeState.modelReadiness = .failed(
      ModelPreparationFailure(
        code: "model_prompt_cache_failed",
        stage: .promptCache,
        mode: .evaluated,
        userMessage: "failed",
        diagnostic: "safe"))
    activeState.activeTurn = AppFeature.ActiveTurn(
      questionID: UUID(3),
      conversationID: UUID(2),
      question: "Running",
      startedAt: Date(timeIntervalSince1970: 1))
    let activeDiagnosis = AppFeature.PendingScopeDiagnosis(
      conversationID: UUID(2),
      messageID: UUID(21),
      context: FollowUpSuggestionContext(
        sourceAssistantMessageID: UUID(21),
        question: "Active recovery",
        standaloneQuestion: "Active recovery",
        seed: .turnFailure(reason: .generationExhausted, scopeVerdict: nil)))
    activeState.pendingScopeDiagnosis = activeDiagnosis
    let activeStore = TestStore(initialState: activeState) {
      AppFeature()
    } withDependencies: {
      $0.queryPipeline = pipeline
    }
    activeStore.exhaustivity = .off
    await activeStore.send(.retryCompatibilityPreparation)
    await activeStore.finish()

    #expect(modes.value.isEmpty)
    #expect(activeStore.state.pendingScopeDiagnosis == activeDiagnosis)
  }

  @Test func compatibilityIsNotOfferedForBuildPolicyFailures() async {
    let modes = LockIsolated<[ModelRuntimeMode]>([])
    let pipeline = QueryPipeline(
      prepareMode: { mode in
        modes.withValue { $0.append(mode) }
        return ModelPreparationReport(mode: mode, elapsedMilliseconds: 0)
      },
      runtimeMode: { .evaluated },
      run: { _, _ in AsyncStream { $0.finish() } })
    var state = AppFeature.State()
    state.$developerMode.withLock { $0 = true }
    state.modelReadiness = .failed(
      ModelPreparationFailure(
        code: "build_channel_invalid",
        stage: .buildPolicy,
        mode: .evaluated,
        userMessage: "failed",
        diagnostic: "safe"))
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.queryPipeline = pipeline
    }
    store.exhaustivity = .off

    await store.send(.retryCompatibilityPreparation)

    #expect(modes.value.isEmpty)
    #expect(store.state.modelPreparationReport == nil)
  }
}
