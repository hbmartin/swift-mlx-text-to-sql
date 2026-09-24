import ComposableArchitecture
import Foundation
import Testing

@testable import CREGEngine
@testable import CREGFeatures

private actor PreparationDrainGate {
  private var arrived = false
  private var arrivalWaiter: CheckedContinuation<Void, Never>?
  private var releaseWaiter: CheckedContinuation<Void, Never>?

  func waitForDrain() async {
    arrived = true
    arrivalWaiter?.resume()
    await withCheckedContinuation { releaseWaiter = $0 }
  }

  func waitUntilDraining() async {
    if arrived { return }
    await withCheckedContinuation { arrivalWaiter = $0 }
  }

  func release() { releaseWaiter?.resume() }
}

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

    try await store.begin(attemptID: UUID(3), mode: .evaluated, environment: ["build": "test"])
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

  @Test func suspensionBeforeOrAfterJournalBeginIsACompletedOutcome() async throws {
    for suspendFirst in [true, false] {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("creg-suspension-test-\(UUID().uuidString).json")
      let owner = ModelPreparationJournalStore(url: url, processSessionID: UUID(11))
      let attemptID = UUID()
      if suspendFirst { try await owner.suspend(attemptID) }
      try await owner.begin(
        attemptID: attemptID, mode: .evaluated, environment: [:])
      if !suspendFirst { try await owner.suspend(attemptID) }
      try await owner.stageStarted(.promptCache, mode: .evaluated)
      try await owner.fail(ModelPreparationFailure(
        code: "model_container_load_failed", stage: .containerLoad,
        mode: .evaluated, userMessage: "failed", diagnostic: "late callback"),
        attemptID: attemptID)
      let data = try #require(await owner.exportData())
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let saved = try decoder.decode(ModelPreparationJournalSnapshot.self, from: data)
      #expect(saved.attemptID == attemptID)
      #expect(saved.completed)
      #expect(saved.outcome == "suspended")
      let relaunched = ModelPreparationJournalStore(url: url, processSessionID: UUID(12))
      #expect(await relaunched.unfinishedAttempt() == nil)
    }
  }

  @Test func lateSuspendedBeginCannotReplaceTheResumedAttempt() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("creg-late-suspension-test-\(UUID().uuidString).json")
    let owner = ModelPreparationJournalStore(url: url, processSessionID: UUID(13))
    let suspendedID = UUID(14)
    let resumedID = UUID(15)
    try await owner.suspend(suspendedID)
    try await owner.begin(
      attemptID: resumedID, mode: .evaluated, environment: [:])
    try await owner.begin(
      attemptID: suspendedID, mode: .evaluated, environment: [:])
    let data = try #require(await owner.exportData())
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let saved = try decoder.decode(ModelPreparationJournalSnapshot.self, from: data)
    #expect(saved.attemptID == resumedID)
    #expect(!saved.completed)
  }
}

@MainActor
@Suite struct ModelPreparationFeatureTests {
  @Test func suspendedJournalWaitsForRawPreparationDrain() async throws {
    let attemptID = UUID()
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString + ".json")
    let journalStore = ModelPreparationJournalStore(url: file)
    try await journalStore.begin(
      attemptID: attemptID, mode: .evaluated, environment: [:])
    let drain = PreparationDrainGate()
    let pipeline = QueryPipeline(
      waitUntilInferenceIdle: { await drain.waitForDrain() },
      run: { _, _ in AsyncStream { $0.finish() } })
    var state = AppFeature.State()
    state.modelPreparationInFlight = true
    state.modelPreparationModeInFlight = .evaluated
    state.modelPreparationAttemptID = attemptID
    let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
      $0.queryPipeline = pipeline
      $0.modelPreparationJournal = .live(store: journalStore)
    }
    store.exhaustivity = .off

    await store.send(.appEnteredBackground)
    await drain.waitUntilDraining()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let before = try #require(await journalStore.exportData())
    #expect(try decoder.decode(ModelPreparationJournalSnapshot.self, from: before).outcome == "suspended")
    #expect(store.state.drainingModelPreparationAttemptID == attemptID)
    await drain.release()
    await store.receive(.modelPreparationSuspended(attemptID))
    let after = try #require(await journalStore.exportData())
    #expect(try decoder.decode(ModelPreparationJournalSnapshot.self, from: after).outcome == "suspended")
    #expect(store.state.drainingModelPreparationAttemptID == nil)
    await store.finish()
  }

  @Test func cancelledPreparationCompletionCannotReplaceDrainingAttempt() async {
    let oldID = UUID()
    var state = AppFeature.State()
    state.drainingModelPreparationAttemptID = oldID
    state.suspendedModelPreparationMode = .evaluated
    let store = TestStore(initialState: state) { AppFeature() }
    store.exhaustivity = .off

    await store.send(.modelPrepared(
      ModelPreparationReport(mode: .evaluated, elapsedMilliseconds: 0),
      attemptID: oldID))
    #expect(store.state.modelReadiness == .preparing)
    #expect(store.state.drainingModelPreparationAttemptID == oldID)
  }

  @Test func quietMemoryWindowResumesSuspendedPreparation() async {
    let modes = LockIsolated<[ModelRuntimeMode]>([])
    let pipeline = QueryPipeline(
      prepareMode: { mode in
        modes.withValue { $0.append(mode) }
        return ModelPreparationReport(mode: mode, elapsedMilliseconds: 0)
      },
      runtimeMode: { .evaluated },
      run: { _, _ in AsyncStream { $0.finish() } })
    var state = AppFeature.State()
    state.didHandlePreparationJournalInspection = true
    state.suspendedModelPreparationMode = .evaluated
    let clock = TestClock()
    let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
      $0.queryPipeline = pipeline
      $0.modelPreparationJournal = .noop
      $0.continuousClock = clock
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.resourcePressure)
    await clock.advance(by: .seconds(4))
    #expect(modes.value.isEmpty)
    await store.send(.resourcePressure)
    await clock.advance(by: .seconds(1))
    #expect(modes.value.isEmpty)
    await clock.advance(by: .seconds(4))
    await store.finish()
    await store.skipReceivedActions()
    #expect(modes.value == [.evaluated])
    #expect(store.state.modelReadiness == .ready)
  }

  @Test func explicitRetryDuringPressureStartsOnceAfterQuietEvenWithQueuedQuestion() async {
    let modes = LockIsolated<[ModelRuntimeMode]>([])
    let pipeline = QueryPipeline(
      prepareMode: { mode in
        modes.withValue { $0.append(mode) }
        return ModelPreparationReport(mode: mode, elapsedMilliseconds: 0)
      },
      runtimeMode: { .evaluated },
      run: { _, _ in AsyncStream { $0.finish() } })
    let pressureID = UUID()
    var state = AppFeature.State()
    state.modelReadiness = .failed(ModelPreparationFailure(
      code: "model_load_failed", stage: .containerLoad, mode: .evaluated,
      userMessage: "failed", diagnostic: "safe"))
    state.pressureGeneration = pressureID
    state.queue = [QueuedQuestion(
      id: UUID(), conversationID: UUID(), question: "Waiting question",
      submittedAt: Date(timeIntervalSince1970: 1))]
    let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
      $0.queryPipeline = pipeline
      $0.modelPreparationJournal = .noop
      $0.historyClient = .noop()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 2))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.retryPreparation)
    await store.send(.retryPreparation)
    #expect(store.state.pendingPreparationRetryMode == .evaluated)
    #expect(modes.value.isEmpty)
    await store.send(.pressureQuiet(pressureID))
    await store.receive(\.modelPrepared)
    #expect(modes.value == [.evaluated])
    #expect(store.state.pendingPreparationRetryMode == nil)
  }

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
      $0.uuid = .incrementing
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
      $0.uuid = .incrementing
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
      $0.uuid = .incrementing
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
