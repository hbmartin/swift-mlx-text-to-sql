import ComposableArchitecture
import Foundation
import Testing

@testable import CREGEngine
@testable import CREGFeatures

private let answer = QueryResult(columns: ["name"], rows: [[.text("Sable Tower")]])

private enum SchedulerPersistenceTestError: Error, Sendable {
  case failed
}

final class CallRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []

  func record(_ value: String) {
    lock.lock()
    values.append(value)
    lock.unlock()
  }

  var recorded: [String] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }

  var count: Int { recorded.count }
}

private actor AssistantPersistenceGate {
  private var isHolding = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func holdFirstAssistant() async {
    guard !isHolding else { return }
    isHolding = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilHeld() async {
    guard !isHolding else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

private actor UserPersistenceOrderingGate {
  private var events: [String] = []
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func holdUserWrite() async {
    events.append("user-started")
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
    events.append("user-finished")
  }

  func waitUntilUserWriteStarts() async {
    guard !events.isEmpty else {
      await withCheckedContinuation { continuation in
        startWaiters.append(continuation)
      }
      return
    }
  }

  func recordTerminalWrite() {
    events.append("terminal")
  }

  func releaseUserWrite() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }

  var recordedEvents: [String] { events }
}

@MainActor
@Suite struct AppFeatureSchedulerTests {
  static let conversationA = UUID(10)
  static let conversationB = UUID(11)

  static func scriptedPipeline(
    runs: CallRecorder = CallRecorder(),
    starterRuns: CallRecorder = CallRecorder()
  ) -> QueryPipeline {
    QueryPipeline(
      run: { question, _ in
        runs.record(question)
        return AsyncStream { continuation in
          var telemetry = TurnTelemetry(originalQuestion: question)
          telemetry.stageTimings.totalMicroseconds = 3_000
          continuation.yield(.turnStarted(question: question))
          continuation.yield(
            .turnFinished(
              outcome: .answered(
                result: answer,
                narration: "One property found.",
                sql: "SELECT name FROM properties",
                notice: nil),
              telemetry: telemetry))
          continuation.finish()
        }
      },
      runStarter: { starter in
        starterRuns.record(starter.rawValue)
        return AsyncStream { continuation in
          let telemetry = TurnTelemetry(originalQuestion: starter.question)
          continuation.yield(
            .turnFinished(
              outcome: .answered(
                result: answer,
                narration: "Starter answered.",
                sql: starter.sql,
                notice: nil),
              telemetry: telemetry))
          continuation.finish()
        }
      })
  }

  /// A pipeline whose stream stays open until cancelled, so the global
  /// active turn persists across assertions.
  static func hangingPipeline() -> QueryPipeline {
    QueryPipeline { _, _ in AsyncStream { _ in } }
  }

  static func appState(selected: UUID = conversationA) -> AppFeature.State {
    var state = AppFeature.State(
      debugModelIdentity: nil, launchBenchmarkQuestion: nil)
    state.launchBenchmarkQuestion = nil
    state.modelReadiness = .ready
    state.chat = ChatFeature.State(conversationID: selected)
    state.conversations = [
      ConversationSummary(
        id: conversationA, title: "",
        startedAt: Date(timeIntervalSince1970: 0),
        lastActivityAt: Date(timeIntervalSince1970: 20)),
      ConversationSummary(
        id: conversationB, title: "Lease expirations",
        startedAt: Date(timeIntervalSince1970: 0),
        lastActivityAt: Date(timeIntervalSince1970: 10)),
    ]
    return state
  }

  static func finishedEvent(question: String = "done") -> PipelineEvent {
    var telemetry = TurnTelemetry(originalQuestion: question)
    telemetry.generatedCount = 1
    return .turnFinished(
      outcome: .answered(
        result: answer,
        narration: "One property found.",
        sql: "SELECT name FROM properties",
        notice: nil),
      telemetry: telemetry)
  }

  static func preparedFollowUp(
    id: UUID = UUID(80), sourceMessageID: UUID = UUID(79)
  ) -> PreparedFollowUp {
    let sql = "SELECT name FROM properties"
    var telemetry = TurnTelemetry(originalQuestion: "Which fund owns it?")
    telemetry.queryOrigin = .preparedFollowUp
    return PreparedFollowUp(
      id: id,
      sourceAssistantMessageID: sourceMessageID,
      rank: 1,
      question: "Which fund owns it?",
      sql: sql,
      result: answer,
      preparationTelemetry: telemetry,
      provenance: PreparedQueryProvenance(
        modelKey: "test-model",
        modelRevision: "test-revision",
        runtimeMode: .evaluated,
        preparationPolicyVersion: "prepared-follow-up-v1|binding-repair-v2",
        databaseFingerprint: "test-database",
        sqlFingerprint: PreparedFollowUpIntegrity.fingerprint(sql: sql),
        resultFingerprint: PreparedFollowUpIntegrity.fingerprint(result: answer)),
      createdAt: Date(timeIntervalSince1970: 1))
  }

  @Test func sendDispatchesAndRendersAnswer() async {
    let store = TestStore(initialState: Self.appState()) {
      AppFeature()
    } withDependencies: {
      $0.queryPipeline = Self.scriptedPipeline()
      $0.historyClient = .noop()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.chat(.binding(.set(\.composerText, "Which property leads?"))))
    await store.send(.chat(.sendTapped))
    #expect(store.state.chat?.composerText.isEmpty == true)
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.chat?.messages.count == 2)
    #expect(store.state.activeTurn == nil)
    let assistant = store.state.chat?.messages.last
    guard case .answer(let result, let narration, let sql, _)? = assistant?.body
    else {
      Issue.record("expected an answer, got \(String(describing: assistant?.body))")
      return
    }
    #expect(result == answer)
    #expect(narration == "One property found.")
    #expect(sql == "SELECT name FROM properties")
    // First question becomes the title.
    #expect(store.state.chat?.title == "Which property leads?")
    #expect(
      store.state.conversations[id: Self.conversationA]?.title
        == "Which property leads?")
    #expect(
      store.state.conversations[id: Self.conversationA]?.latestMessagePreview
        == "One property found.")
  }

  @Test func failedUserTurnPersistenceDoesNotStartThePipeline() async {
    let runs = CallRecorder()
    var history = HistoryClient.noop()
    history.persistUserTurn = { _, _, _, _ in
      throw SchedulerPersistenceTestError.failed
    }
    let store = TestStore(initialState: Self.appState()) {
      AppFeature()
    } withDependencies: { [history] in
      $0.queryPipeline = Self.scriptedPipeline(runs: runs)
      $0.historyClient = history
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(
      .chat(
        .delegate(
          .submitQuestion(
            QuestionSubmission(question: "Will this be persisted?")))))
    await store.finish()
    await store.skipReceivedActions()

    #expect(runs.recorded.isEmpty)
    #expect(store.state.activeTurn == nil)
    #expect(store.state.chat?.processing == nil)
    #expect(store.state.chat?.messages.isEmpty == true)
    #expect(store.state.chat?.title.isEmpty == true)
    #expect(store.state.conversations[id: Self.conversationA]?.title.isEmpty == true)
    #expect(store.state.conversations[id: Self.conversationA]?.messageCount == 0)
    #expect(
      store.state.conversations[id: Self.conversationA]?.lastActivityAt
        == Date(timeIntervalSince1970: 20))
    #expect(store.state.presentedFailure?.code == "history_message_save_failed")
  }

  @Test func backgroundPersistenceRollbackPreservesTheLoadedConversationTitle() async {
    let gate = UserPersistenceOrderingGate()
    var state = Self.appState(selected: Self.conversationA)
    state.queue = [
      QueuedQuestion(
        id: UUID(89),
        conversationID: Self.conversationB,
        question: "Fail in the background",
        submittedAt: Date(timeIntervalSince1970: 1))
    ]
    var history = HistoryClient.noop()
    history.persistUserTurn = { _, _, _, _ in
      await gate.holdUserWrite()
      throw SchedulerPersistenceTestError.failed
    }
    let clock = TestClock()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [history] in
      $0.historyClient = history
      $0.queryPipeline = Self.hangingPipeline()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 2))
      $0.continuousClock = clock
    }
    store.exhaustivity = .off

    await store.send(.dispatchNextIfIdle)
    await gate.waitUntilUserWriteStarts()
    #expect(
      store.state.activeTurn?.optimisticUserTurn?.previousChatTitle
        == "Lease expirations")

    let loadedSummary = state.conversations[id: Self.conversationB]!
    await store.send(
      .conversationLoaded(ConversationSnapshot(summary: loadedSummary)))
    #expect(store.state.chat?.title == "Lease expirations")

    await gate.releaseUserWrite()
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.activeTurn == nil)
    #expect(store.state.chat?.conversationID == Self.conversationB)
    #expect(store.state.chat?.title == "Lease expirations")
    #expect(store.state.chat?.messages.isEmpty == true)
  }

  @Test func staleUserPersistenceFailureOnlyPerformsIdempotentCleanup() async {
    var state = Self.appState()
    let message = ChatMessage(
      id: UUID(89), role: .user, body: .text("Never persisted"),
      createdAt: Date(timeIntervalSince1970: 2))
    state.chat?.messages.append(message)
    let deferredDeletionFailure = FailurePresentation(
      code: "conversation_delete_failed",
      title: "Couldn’t delete conversation",
      message: "The conversation was restored.",
      diagnostic: "delete failed")
    let deletedSummary = state.conversations[id: Self.conversationA]!
    let optimisticTurn = AppFeature.OptimisticUserTurn(
      message: message,
      previousSummary: deletedSummary,
      previousChatTitle: state.chat?.title)
    state.conversations.remove(id: Self.conversationA)
    state.pendingDeletion = AppFeature.PendingDeletion(
      summary: deletedSummary,
      index: 0,
      deferredFailure: deferredDeletionFailure)
    let store = TestStore(initialState: state) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .userTurnPersistenceFailed(
        conversationID: Self.conversationA,
        questionID: UUID(90),
        optimisticTurn: optimisticTurn,
        failure: FailurePresentation(
          code: "history_message_save_failed",
          title: "Couldn’t save message",
          message: "Try again.",
          diagnostic: "duplicate coalesced failure")))
    await store.finish()

    #expect(store.state.chat?.messages[id: message.id] == nil)
    #expect(store.state.presentedFailure == nil)
    #expect(store.state.pendingDeletion?.deferredFailure == deferredDeletionFailure)
  }

  @Test func staleUserPersistenceFailureIsDeferredDuringUndoWindow() async {
    var state = Self.appState()
    let message = ChatMessage(
      id: UUID(91), role: .user, body: .text("Never persisted"),
      createdAt: Date(timeIntervalSince1970: 2))
    state.chat?.messages.append(message)
    let deletedSummary = state.conversations[id: Self.conversationA]!
    let optimisticTurn = AppFeature.OptimisticUserTurn(
      message: message,
      previousSummary: deletedSummary,
      previousChatTitle: state.chat?.title)
    state.conversations.remove(id: Self.conversationA)
    state.pendingDeletion = AppFeature.PendingDeletion(
      summary: deletedSummary, index: 0)
    let failure = FailurePresentation(
      code: "history_message_save_failed",
      title: "Couldn’t save message",
      message: "Try again.",
      diagnostic: "first failure during deletion")
    let store = TestStore(initialState: state) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .userTurnPersistenceFailed(
        conversationID: Self.conversationA,
        questionID: UUID(92),
        optimisticTurn: optimisticTurn,
        failure: failure))
    await store.finish()

    #expect(store.state.chat?.messages[id: message.id] == nil)
    #expect(store.state.presentedFailure == nil)
    #expect(store.state.pendingDeletion?.deferredFailure == failure)
  }

  @Test func staleUserPersistenceFailureAfterUndoIsPresented() async {
    var state = Self.appState()
    let message = ChatMessage(
      id: UUID(93), role: .user, body: .text("Never persisted"),
      createdAt: Date(timeIntervalSince1970: 2))
    state.chat?.messages.append(message)
    let optimisticTurn = AppFeature.OptimisticUserTurn(
      message: message,
      previousSummary: state.conversations[id: Self.conversationA],
      previousChatTitle: state.chat?.title)
    let failure = FailurePresentation(
      code: "history_message_save_failed",
      title: "Couldn’t save message",
      message: "Try again.",
      diagnostic: "failure after undo")
    let store = TestStore(initialState: state) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .userTurnPersistenceFailed(
        conversationID: Self.conversationA,
        questionID: UUID(94),
        optimisticTurn: optimisticTurn,
        failure: failure))
    await store.receive(.operationFailed(failure)) {
      $0.presentedFailure = failure
    }
    await store.finish()

    #expect(store.state.chat?.messages[id: message.id] == nil)
    #expect(store.state.presentedFailure == failure)
  }

  @Test func stopWaitsForTheUserWriteBeforePersistingItsTerminalMessage() async {
    let gate = UserPersistenceOrderingGate()
    var history = HistoryClient.noop()
    history.persistUserTurn = { _, _, _, _ in
      await gate.holdUserWrite()
    }
    history.persistTerminalTurn = { _, _, _, _ in
      await gate.recordTerminalWrite()
    }
    let clock = TestClock()
    let store = TestStore(initialState: Self.appState()) {
      AppFeature()
    } withDependencies: { [history] in
      $0.queryPipeline = Self.hangingPipeline()
      $0.historyClient = history
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = clock
    }
    store.exhaustivity = .off

    await store.send(
      .chat(
        .delegate(
          .submitQuestion(
            QuestionSubmission(question: "Persist me before stopping")))))
    await gate.waitUntilUserWriteStarts()

    await store.send(.chat(.delegate(.stopActiveTurn)))
    #expect(await gate.recordedEvents == ["user-started"])

    await gate.releaseUserWrite()
    await store.finish()
    await store.skipReceivedActions()

    #expect(
      await gate.recordedEvents
        == ["user-started", "user-finished", "terminal"])
    #expect(store.state.pendingTurnPersistence == nil)
  }

  @Test func stopRollsBackItsTranscriptWhenTheUserWriteFails() async {
    let gate = UserPersistenceOrderingGate()
    var history = HistoryClient.noop()
    history.persistUserTurn = { _, _, _, _ in
      await gate.holdUserWrite()
      throw SchedulerPersistenceTestError.failed
    }
    history.persistTerminalTurn = { _, _, _, _ in
      await gate.recordTerminalWrite()
    }
    let clock = TestClock()
    let store = TestStore(initialState: Self.appState()) {
      AppFeature()
    } withDependencies: { [history] in
      $0.queryPipeline = Self.hangingPipeline()
      $0.historyClient = history
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = clock
    }
    store.exhaustivity = .off

    await store.send(
      .chat(
        .delegate(
          .submitQuestion(
            QuestionSubmission(question: "This write will fail")))))
    await gate.waitUntilUserWriteStarts()
    await store.send(.chat(.delegate(.stopActiveTurn)))
    #expect(store.state.chat?.messages.count == 2)

    await gate.releaseUserWrite()
    await store.finish()
    await store.skipReceivedActions()

    #expect(await gate.recordedEvents == ["user-started", "user-finished"])
    #expect(store.state.chat?.messages.isEmpty == true)
    #expect(store.state.chat?.title.isEmpty == true)
    #expect(store.state.conversations[id: Self.conversationA]?.messageCount == 0)
    #expect(store.state.pendingTurnPersistence == nil)
    #expect(store.state.presentedFailure?.code == "history_message_save_failed")
  }

  @Test func streamEndingWithoutTerminalEventClearsTheActiveTurn() async {
    let pipeline = QueryPipeline { _, _ in
      AsyncStream { continuation in continuation.finish() }
    }
    let store = TestStore(initialState: Self.appState()) {
      AppFeature()
    } withDependencies: { [pipeline] in
      $0.queryPipeline = pipeline
      $0.historyClient = .noop()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(
      .chat(
        .delegate(
          .submitQuestion(
            QuestionSubmission(question: "Will this finish?")))))
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.activeTurn == nil)
    #expect(store.state.chat?.processing == nil)
    guard
      case .failedTurn(let reason, let scopeVerdict)? =
        store.state.chat?.messages.last?.body
    else {
      Issue.record("Expected unterminated stream recovery to render a failure")
      return
    }
    #expect(reason == .unexpected)
    #expect(scopeVerdict == nil)
    #expect(
      store.state.chat?.messages.last?.devInfo?.failureReason == .unexpected)
  }

  @Test func submitWhileActiveBecomesCancellableQueuedQuestion() async {
    let store = TestStore(initialState: Self.appState()) {
      AppFeature()
    } withDependencies: {
      $0.queryPipeline = Self.hangingPipeline()
      $0.historyClient = .noop()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.chat(.binding(.set(\.composerText, "first question"))))
    await store.send(.chat(.sendTapped))
    await store.receive(
      .chat(
        .delegate(
          .submitQuestion(
            QuestionSubmission(question: "first question")))))
    #expect(store.state.activeTurn?.question == "first question")

    await store.send(.chat(.binding(.set(\.composerText, "second question"))))
    await store.send(.chat(.sendTapped))
    await store.receive(
      .chat(
        .delegate(
          .submitQuestion(
            QuestionSubmission(question: "second question")))))
    #expect(store.state.queue.count == 1)
    #expect(store.state.queue.first?.question == "second question")
    #expect(store.state.chat?.queued.count == 1)

    guard let queuedID = store.state.queue.first?.id else {
      Issue.record("expected a queued question")
      return
    }
    await store.send(.chat(.cancelQueuedTapped(queuedID)))
    await store.receive(.chat(.delegate(.cancelQueued(queuedID))))
    #expect(store.state.queue.isEmpty)
    #expect(store.state.chat?.queued.isEmpty == true)

    // Stop ends the hanging active turn without dispatching anything else.
    await store.send(.chat(.stopTapped))
    await store.receive(.chat(.delegate(.stopActiveTurn)))
    #expect(store.state.activeTurn == nil)
    #expect(
      store.state.chat?.messages.last?.body
        == .text("Stopped — ask again whenever you're ready."))
    await store.finish()
  }

  @Test func submissionRetiresPreparationAndQueuesPreparedPayloadFirst() async {
    let prepared = Self.preparedFollowUp()
    var state = Self.appState()
    state.activeTurn = AppFeature.ActiveTurn(
      questionID: UUID(90),
      conversationID: Self.conversationB,
      question: "already running",
      startedAt: Date(timeIntervalSince1970: 0))
    let context = FollowUpSuggestionContext(
      sourceAssistantMessageID: prepared.sourceAssistantMessageID,
      question: "Which property leads?",
      standaloneQuestion: "Which property leads?",
      narration: "One property found.",
      result: answer)
    let batch = PreparedFollowUpBatch(
      sourceAssistantMessageID: prepared.sourceAssistantMessageID,
      context: context,
      suggestions: [prepared],
      updatedAt: Date(timeIntervalSince1970: 1))
    state.followUpPreparation = AppFeature.FollowUpPreparationState(
      conversationID: Self.conversationA,
      context: context,
      batch: batch)
    state.chat?.followUpBatch = batch
    let clears = CallRecorder()
    var history = HistoryClient.noop()
    history.clearFollowUpBatch = { id in clears.record(id.uuidString) }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [history] in
      $0.queryPipeline = Self.hangingPipeline()
      $0.historyClient = history
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 2))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(
      .chat(
        .delegate(
          .submitQuestion(
            QuestionSubmission(
              question: prepared.question,
              source: .preparedFollowUp(prepared))))))
    await store.finish()

    #expect(store.state.followUpPreparation == nil)
    #expect(store.state.chat?.followUpBatch == nil)
    #expect(store.state.queue.count == 1)
    guard
      case .preparedFollowUp(let queued)? =
        store.state.queue.first?.submission.source
    else {
      Issue.record("Expected the cached prepared payload to stay in the queue")
      return
    }
    #expect(queued == prepared)
    #expect(clears.recorded == [Self.conversationA.uuidString])
  }

  @Test func appReadinessGateKeepsPreparedFollowUpAvailable() async {
    let prepared = Self.preparedFollowUp()
    var state = Self.appState()
    state.chat?.followUpBatch = PreparedFollowUpBatch(
      sourceAssistantMessageID: prepared.sourceAssistantMessageID,
      suggestions: [prepared],
      updatedAt: Date(timeIntervalSince1970: 1))
    let store = TestStore(initialState: state) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .modelPreparationFailed(
        ModelPreparationFailure(
          code: "model_prompt_cache_failed",
          stage: .promptCache,
          mode: .evaluated,
          userMessage: "Model preparation failed.",
          diagnostic: "test failure")))
    #expect(store.state.chat?.isSubmissionEnabled == false)

    await store.send(.chat(.preparedFollowUpTapped(prepared.id)))
    await store.finish()

    #expect(store.state.chat?.followUpBatch?.suggestions == [prepared])
    #expect(store.state.activeTurn == nil)
    #expect(store.state.queue.isEmpty)
  }

  /// Apple Intelligence is required (ADR 0011): a ready SQL model alone must
  /// not open the submission gate when the FM is unavailable, and the gate
  /// reopens once availability returns on scene activation.
  @Test func appleIntelligenceUnavailabilityGatesSubmission() async {
    let store = TestStore(initialState: Self.appState()) {
      AppFeature()
    } withDependencies: {
      $0.fmStatus = FMStatusClient(availability: {
        .unavailable(reason: .appleIntelligenceNotEnabled)
      })
    }
    store.exhaustivity = .off

    await store.send(.appBecameActive)
    #expect(
      store.state.fmAvailability
        == .unavailable(reason: .appleIntelligenceNotEnabled))
    #expect(store.state.modelReadiness == .ready)
    #expect(store.state.chat?.isSubmissionEnabled == false)

    store.dependencies.fmStatus = FMStatusClient(availability: { .available })
    await store.send(.appBecameActive)
    #expect(store.state.fmAvailability == .available)
    #expect(store.state.chat?.isSubmissionEnabled == true)
  }

  @Test func queuedTurnWaitsForAppleIntelligenceAndResumesOnActivation() async {
    var state = Self.appState()
    let activeID = UUID(70)
    state.activeTurn = AppFeature.ActiveTurn(
      questionID: activeID,
      conversationID: Self.conversationA,
      question: "running",
      startedAt: Date(timeIntervalSince1970: 0))
    state.queue = [
      QueuedQuestion(
        id: UUID(71),
        conversationID: Self.conversationA,
        question: "Run after AI returns",
        submittedAt: Date(timeIntervalSince1970: 1))
    ]
    let availability = LockIsolated<FMAvailability>(.available)
    let runs = CallRecorder()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.fmStatus = FMStatusClient(availability: { availability.value })
      $0.queryPipeline = Self.scriptedPipeline(runs: runs)
      $0.historyClient = .noop()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    availability.setValue(.unavailable(reason: .modelNotReady))
    await store.send(
      .pipelineEvent(
        conversationID: Self.conversationA,
        questionID: activeID,
        event: Self.finishedEvent()))
    await store.finish()
    await store.skipReceivedActions()

    #expect(runs.recorded.isEmpty)
    #expect(store.state.queue.map(\.question) == ["Run after AI returns"])
    #expect(store.state.activeTurn == nil)

    availability.setValue(.available)
    await store.send(.appBecameActive)
    await store.finish()
    await store.skipReceivedActions()

    #expect(runs.recorded == ["Run after AI returns"])
    #expect(store.state.queue.isEmpty)
  }

  @Test func preparedTapUpdatesTheSameAssistantMessageAfterImmediatePreview() async {
    let sourceID = UUID(79)
    let prepared = Self.preparedFollowUp(sourceMessageID: sourceID)
    var state = Self.appState()
    state.chat?.messages.append(
      ChatMessage(
        id: sourceID,
        role: .assistant,
        body: .answer(
          result: answer,
          narration: "One property found.",
          sql: "SELECT name FROM properties",
          notice: nil),
        createdAt: Date(timeIntervalSince1970: 0)))
    state.chat?.followUpBatch = PreparedFollowUpBatch(
      sourceAssistantMessageID: sourceID,
      suggestions: [prepared],
      updatedAt: Date(timeIntervalSince1970: 1))
    let writes = CallRecorder()
    let historyLoads = CallRecorder()
    let snapshotSummary = state.conversations[id: Self.conversationA]!
    var history = HistoryClient.noop()
    history.loadConversation = { id in
      historyLoads.record(id.uuidString)
      return ConversationSnapshot(summary: snapshotSummary)
    }
    history.appendMessage = { _, message in
      let kind =
        if case .preparedAnswer = message.body {
          "provisional"
        } else {
          "assistant"
        }
      writes.record("append:\(kind):\(message.id.uuidString)")
    }
    history.persistUserTurn = { _, message, _, _ in
      writes.record("append:user:\(message.id.uuidString)")
    }
    history.persistTerminalTurn = { _, message, replacesExisting, _ in
      writes.record(
        "\(replacesExisting ? "update:final" : "append:assistant"):\(message.id.uuidString)")
    }
    let pipeline = QueryPipeline(
      run: { _, _ in AsyncStream { $0.finish() } },
      prepareFollowUps: { _ in
        AsyncStream { continuation in
          continuation.yield(.finished)
          continuation.finish()
        }
      },
      runPrepared: { prepared, _ in
        AsyncStream { continuation in
          var telemetry = prepared.preparationTelemetry
          telemetry.preparedCacheHit = true
          telemetry.queryOrigin = .preparedFollowUp
          telemetry.executionPath = .preparedFollowUp
          continuation.yield(
            .preparedResultReady(
              prepared: prepared,
              elapsedMicroseconds: 100))
          continuation.yield(.narrationStarted)
          continuation.yield(
            .turnFinished(
              outcome: .answered(
                result: prepared.result,
                narration: "One matching property.",
                sql: prepared.sql,
                notice: nil),
              telemetry: telemetry))
          continuation.finish()
        }
      })
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [history, pipeline] in
      $0.queryPipeline = pipeline
      $0.historyClient = history
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 2))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.chat(.preparedFollowUpTapped(prepared.id)))
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.chat?.messages.count == 3)
    guard
      case .answer(_, let narration, _, _)? =
        store.state.chat?.messages.last?.body
    else {
      Issue.record("Expected the provisional answer to be finalized in place")
      return
    }
    #expect(narration == "One matching property.")
    let provisional = writes.recorded.first {
      $0.hasPrefix("append:provisional:")
    }?.split(separator: ":").last.map(String.init)
    let final = writes.recorded.first {
      $0.hasPrefix("update:final:")
    }?.split(separator: ":").last.map(String.init)
    #expect(provisional != nil)
    #expect(provisional == final)
    #expect(!writes.recorded.contains { $0.hasPrefix("append:assistant:") })
    #expect(historyLoads.recorded.isEmpty)
  }

  @Test func backgroundPreparedCompletionPreservesPresentationPreference() async throws {
    let prepared = Self.preparedFollowUp()
    let questionID = UUID(90)
    var state = Self.appState(selected: Self.conversationA)
    state.activeTurn = AppFeature.ActiveTurn(
      questionID: questionID,
      conversationID: Self.conversationA,
      submission: QuestionSubmission(
        question: prepared.question,
        source: .preparedFollowUp(prepared)),
      startedAt: Date(timeIntervalSince1970: 1))
    let writes = CallRecorder()
    var history = HistoryClient.noop()
    history.persistTerminalTurn = { _, message, _, _ in
      if case .answer = message.body {
        writes.record(message.resultPresentation?.mode.rawValue ?? "nil")
      }
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [history] in
      $0.historyClient = history
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 2))
      $0.continuousClock = ImmediateClock()
      $0.haptics = .noop
    }
    store.exhaustivity = .off

    await store.send(
      .pipelineEvent(
        conversationID: Self.conversationA,
        questionID: questionID,
        event: .preparedResultReady(
          prepared: prepared, elapsedMicroseconds: 100)))
    let provisionalID = try #require(
      store.state.activeTurn?.provisionalAssistantMessageID)
    let preference = ResultPresentationPreference(mode: .table)
    await store.send(
      .chat(
        .resultPresentationChanged(
          messageID: provisionalID, preference: preference)))
    #expect(store.state.activeTurn?.resultPresentationPreference == preference)

    let backgroundSnapshot = ConversationSnapshot(
      summary: try #require(state.conversations[id: Self.conversationB]))
    await store.send(.conversationLoaded(backgroundSnapshot))
    await store.send(
      .pipelineEvent(
        conversationID: Self.conversationA,
        questionID: questionID,
        event: Self.finishedEvent()))
    await store.finish()
    await store.skipReceivedActions()

    #expect(writes.recorded.contains("table"))
  }

  @Test func stoppingPreparedTurnPreservesPresentationPreference() async throws {
    let prepared = Self.preparedFollowUp()
    let questionID = UUID(90)
    let provisionalID = UUID(91)
    let preference = ResultPresentationPreference(
      mode: .table, specificationID: chartTestRecommendationID("policy|table"))
    var state = Self.appState(selected: Self.conversationA)
    var activeTurn = AppFeature.ActiveTurn(
      questionID: questionID,
      conversationID: Self.conversationA,
      submission: QuestionSubmission(
        question: prepared.question,
        source: .preparedFollowUp(prepared)),
      startedAt: Date(timeIntervalSince1970: 1))
    activeTurn.provisionalAssistantMessageID = provisionalID
    activeTurn.resultPresentationPreference = preference
    state.activeTurn = activeTurn
    state.chat?.messages.append(
      ChatMessage(
        id: provisionalID,
        role: .assistant,
        body: .preparedAnswer(prepared),
        createdAt: Date(timeIntervalSince1970: 1),
        resultPresentation: preference))
    let writes = CallRecorder()
    var history = HistoryClient.noop()
    history.persistTerminalTurn = { _, message, _, _ in
      writes.record(message.resultPresentation?.mode.rawValue ?? "nil")
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [history] in
      $0.historyClient = history
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 2))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.chat(.delegate(.stopActiveTurn)))
    await store.finish()

    let message = try #require(store.state.chat?.messages[id: provisionalID])
    #expect(message.resultPresentation == preference)
    #expect(writes.recorded.contains("table"))
  }

  @Test func backgroundingCancelsPreparationAndPersistsItsEventsForResume() async {
    let prepared = Self.preparedFollowUp()
    let context = FollowUpSuggestionContext(
      sourceAssistantMessageID: prepared.sourceAssistantMessageID,
      question: "Which property leads?",
      standaloneQuestion: "Which property leads?",
      narration: "One property found.",
      result: answer)
    let batch = PreparedFollowUpBatch(
      sourceAssistantMessageID: prepared.sourceAssistantMessageID,
      context: context,
      suggestions: [prepared],
      updatedAt: Date(timeIntervalSince1970: 1))
    var state = Self.appState()
    var preparation = AppFeature.FollowUpPreparationState(
      conversationID: Self.conversationA,
      context: context,
      batch: batch)
    preparation.eventLines = ["{\"prepared\":true}"]
    state.followUpPreparation = preparation
    state.chat?.followUpBatch = batch
    state.isCapturingAnswerability = true
    let eventWrites = CallRecorder()
    var history = HistoryClient.noop()
    history.appendEvents = { _, _, lines in
      lines.forEach(eventWrites.record)
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [history] in
      $0.historyClient = history
    }
    store.exhaustivity = .off

    await store.send(.appEnteredBackground)
    await store.finish()

    #expect(store.state.followUpPreparation == nil)
    #expect(store.state.chat?.followUpBatch == batch)
    #expect(store.state.isCapturingAnswerability == false)
    #expect(eventWrites.recorded == ["{\"prepared\":true}"])
  }

  /// A transient `.inactive` blip — Control Center, a system dialog — must
  /// gate new starts without destroying in-flight preparation or capture;
  /// only backgrounding pays the teardown.
  @Test func transientInactivityGatesStartsWithoutCancellingInFlightWork() async {
    let prepared = Self.preparedFollowUp()
    let context = FollowUpSuggestionContext(
      sourceAssistantMessageID: prepared.sourceAssistantMessageID,
      question: "Which property leads?",
      standaloneQuestion: "Which property leads?",
      narration: "One property found.",
      result: answer)
    let batch = PreparedFollowUpBatch(
      sourceAssistantMessageID: prepared.sourceAssistantMessageID,
      context: context,
      suggestions: [prepared],
      updatedAt: Date(timeIntervalSince1970: 1))
    var state = Self.appState()
    state.followUpPreparation = AppFeature.FollowUpPreparationState(
      conversationID: Self.conversationA,
      context: context,
      batch: batch)
    state.chat?.followUpBatch = batch
    state.isCapturingAnswerability = true
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.historyClient = .noop()
    }
    store.exhaustivity = .off

    await store.send(.appBecameInactive)
    await store.finish()

    #expect(store.state.isSceneActive == false)
    #expect(store.state.followUpPreparation != nil)
    #expect(store.state.isCapturingAnswerability)
  }

  @Test func foregroundStartsVerdictFreeRecoveryAfterDiagnosisWasInterrupted() async {
    let sourceMessageID = UUID(77)
    let context = FollowUpSuggestionContext(
      sourceAssistantMessageID: sourceMessageID,
      question: "Who manages each property?",
      standaloneQuestion: "Who manages each property?",
      seed: .turnFailure(reason: .generationExhausted, scopeVerdict: nil))
    var state = Self.appState()
    state.pendingScopeDiagnosis = AppFeature.PendingScopeDiagnosis(
      conversationID: Self.conversationA,
      messageID: sourceMessageID,
      context: context)
    let preparedContexts = LockIsolated<[FollowUpSuggestionContext]>([])
    let pipeline = QueryPipeline(
      run: { _, _ in AsyncStream { $0.finish() } },
      prepareFollowUps: { context in
        preparedContexts.withValue { $0.append(context) }
        return AsyncStream { continuation in
          continuation.yield(.finished)
          continuation.finish()
        }
      })
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [pipeline] in
      $0.queryPipeline = pipeline
      $0.historyClient = .noop()
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.appBecameInactive)
    await store.finish()

    #expect(store.state.pendingScopeDiagnosis?.context == context)
    #expect(store.state.followUpPreparation == nil)
    #expect(preparedContexts.value.isEmpty)

    await store.send(.appBecameActive)
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.pendingScopeDiagnosis == nil)
    #expect(preparedContexts.value == [context])
    guard
      case .turnFailure(let reason, let verdict)? =
        preparedContexts.value.first?.seed
    else {
      Issue.record("Expected verdict-free Recovery Suggestion context")
      return
    }
    #expect(reason == .generationExhausted)
    #expect(verdict == nil)
  }

  /// A scope diagnosis retained across deactivation holds `isInferenceIdle`
  /// false, and with Apple Intelligence off nothing else can clear it. The
  /// user's explicit preparation retry must abandon the memo and run instead
  /// of silently no-oping for the rest of the session.
  @Test func retainedScopeDiagnosisDoesNotBlockAnExplicitPreparationRetry() async {
    let modes = LockIsolated<[ModelRuntimeMode]>([])
    let pipeline = QueryPipeline(
      prepareMode: { mode in
        modes.withValue { $0.append(mode) }
        return ModelPreparationReport(mode: mode, elapsedMilliseconds: 0)
      },
      runtimeMode: { .evaluated },
      run: { _, _ in AsyncStream { $0.finish() } })
    var state = Self.appState()
    state.modelReadiness = .failed(
      ModelPreparationFailure(
        code: "model_container_load_failed",
        stage: .containerLoad,
        mode: .evaluated,
        userMessage: "failed",
        diagnostic: "safe"))
    state.fmAvailability = .unavailable(reason: .appleIntelligenceNotEnabled)
    state.pendingScopeDiagnosis = AppFeature.PendingScopeDiagnosis(
      conversationID: Self.conversationA,
      messageID: UUID(77),
      context: FollowUpSuggestionContext(
        sourceAssistantMessageID: UUID(77),
        question: "Who manages each property?",
        standaloneQuestion: "Who manages each property?",
        seed: .turnFailure(reason: .generationExhausted, scopeVerdict: nil)))
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [pipeline] in
      $0.queryPipeline = pipeline
      $0.historyClient = .noop()
    }
    store.exhaustivity = .off

    await store.send(.retryPreparation)
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.pendingScopeDiagnosis == nil)
    #expect(modes.value == [.evaluated])
    #expect(store.state.modelReadiness == .ready)
  }

  /// The persistence barrier can settle after the user has already deleted
  /// the conversation (the durable delete defers on that barrier). A scope
  /// diagnosis for the deleted conversation must never launch: it would run
  /// a full-schema FM call whose verdict has nothing to enrich, and park a
  /// pending record that holds `isInferenceIdle` false for its duration.
  @Test func persistenceBarrierSettlingAfterDeleteSkipsScopeDiagnosis() async {
    let questionID = UUID(90)
    let messageID = UUID(91)
    var state = Self.appState()
    state.conversations.remove(id: Self.conversationB)
    state.deletionAwaitingTurnPersistence = Self.conversationB
    var pending = AppFeature.PendingTurnPersistence(
      questionID: questionID,
      conversationID: Self.conversationB)
    pending.terminalMessageID = messageID
    pending.followUpContext = FollowUpSuggestionContext(
      sourceAssistantMessageID: messageID,
      question: "Who manages each property?",
      standaloneQuestion: "Who manages each property?",
      seed: .turnFailure(reason: .generationExhausted, scopeVerdict: nil))
    state.pendingTurnPersistence = pending
    let judged = LockIsolated(0)
    let deletes = CallRecorder()
    var history = HistoryClient.noop()
    history.deleteConversation = { id in deletes.record(id.uuidString) }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [history] in
      $0.historyClient = history
      $0.scopeDiagnosis = ScopeDiagnosisClient { _ in
        judged.withValue { $0 += 1 }
        return nil
      }
    }
    store.exhaustivity = .off

    await store.send(.turnPersistenceFinished(questionID))
    await store.finish()

    #expect(judged.value == 0)
    #expect(store.state.pendingScopeDiagnosis == nil)
    #expect(store.state.pendingTurnPersistence == nil)
    #expect(deletes.recorded == [Self.conversationB.uuidString])
  }

  /// The verdict-persistence write deliberately carries no cancel ID, so its
  /// completion can arrive after deactivation. Recovery Suggestion
  /// preparation must not start FM/MLX work in the background; the enriched
  /// context is retained and reactivation resumes it.
  @Test func verdictPersistedWhileInactiveRetainsRecoveryContext() async {
    let messageID = UUID(78)
    let verdict = ScopeVerdictRecord(verdict: .likelyAnswerableModelFailed)
    let context = FollowUpSuggestionContext(
      sourceAssistantMessageID: messageID,
      question: "Who manages each property?",
      standaloneQuestion: "Who manages each property?",
      seed: .turnFailure(reason: .generationExhausted, scopeVerdict: verdict))
    let preparedContexts = LockIsolated<[FollowUpSuggestionContext]>([])
    let pipeline = QueryPipeline(
      run: { _, _ in AsyncStream { $0.finish() } },
      prepareFollowUps: { context in
        preparedContexts.withValue { $0.append(context) }
        return AsyncStream { continuation in
          continuation.yield(.finished)
          continuation.finish()
        }
      })
    let store = TestStore(initialState: Self.appState()) {
      AppFeature()
    } withDependencies: { [pipeline] in
      $0.queryPipeline = pipeline
      $0.historyClient = .noop()
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.appBecameInactive)
    await store.send(
      .scopeDiagnosisPersisted(
        conversationID: Self.conversationA, context: context))
    await store.finish()

    #expect(preparedContexts.value.isEmpty)
    #expect(store.state.followUpPreparation == nil)
    #expect(store.state.pendingScopeDiagnosis?.context == context)

    await store.send(.appBecameActive)
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.pendingScopeDiagnosis == nil)
    #expect(preparedContexts.value == [context])
  }

  @Test func nilVerdictCompletionWhileInactiveRetainsRecoveryContext() async {
    let messageID = UUID(81)
    let context = FollowUpSuggestionContext(
      sourceAssistantMessageID: messageID,
      question: "Who manages each property?",
      standaloneQuestion: "Who manages each property?",
      seed: .turnFailure(reason: .generationExhausted, scopeVerdict: nil))
    var state = Self.appState()
    state.pendingScopeDiagnosis = AppFeature.PendingScopeDiagnosis(
      conversationID: Self.conversationA,
      messageID: messageID,
      context: context)
    let preparedContexts = LockIsolated<[FollowUpSuggestionContext]>([])
    let pipeline = QueryPipeline(
      run: { _, _ in AsyncStream { $0.finish() } },
      prepareFollowUps: { context in
        preparedContexts.withValue { $0.append(context) }
        return AsyncStream { continuation in
          continuation.yield(.finished)
          continuation.finish()
        }
      })
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [pipeline] in
      $0.queryPipeline = pipeline
      $0.historyClient = .noop()
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.appBecameInactive)
    await store.send(
      .scopeDiagnosisFinished(
        conversationID: Self.conversationA,
        messageID: messageID,
        verdict: nil))
    await store.finish()

    #expect(preparedContexts.value.isEmpty)
    #expect(store.state.followUpPreparation == nil)
    #expect(store.state.pendingScopeDiagnosis?.context == context)

    await store.send(.appBecameActive)
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.pendingScopeDiagnosis == nil)
    #expect(preparedContexts.value == [context])
  }

  /// A verdict can complete nil while the model is still preparing; the memo
  /// is then retained with no deactivation coming. `.modelPrepared` must give
  /// the retained diagnosis its foreground re-check instead of stranding
  /// `isInferenceIdle` false until the user backgrounds the app.
  @Test func modelPreparedResumesARetainedScopeDiagnosis() async {
    let messageID = UUID(82)
    let context = FollowUpSuggestionContext(
      sourceAssistantMessageID: messageID,
      question: "Who manages each property?",
      standaloneQuestion: "Who manages each property?",
      seed: .turnFailure(reason: .generationExhausted, scopeVerdict: nil))
    var state = Self.appState()
    state.modelReadiness = .preparing
    state.modelPreparationInFlight = true
    state.pendingScopeDiagnosis = AppFeature.PendingScopeDiagnosis(
      conversationID: Self.conversationA,
      messageID: messageID,
      context: context)
    let preparedContexts = LockIsolated<[FollowUpSuggestionContext]>([])
    let pipeline = QueryPipeline(
      run: { _, _ in AsyncStream { $0.finish() } },
      prepareFollowUps: { context in
        preparedContexts.withValue { $0.append(context) }
        return AsyncStream { continuation in
          continuation.yield(.finished)
          continuation.finish()
        }
      })
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [pipeline] in
      $0.queryPipeline = pipeline
      $0.historyClient = .noop()
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(
      .modelPrepared(
        ModelPreparationReport(mode: .evaluated, elapsedMilliseconds: 0)))
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.pendingScopeDiagnosis == nil)
    #expect(preparedContexts.value == [context])
  }

  @Test func foregroundResumesAnIncompletePersistedBatch() async {
    let prepared = Self.preparedFollowUp()
    let context = FollowUpSuggestionContext(
      sourceAssistantMessageID: prepared.sourceAssistantMessageID,
      question: "Which property leads?",
      standaloneQuestion: "Which property leads?",
      narration: "One property found.",
      result: answer)
    let batch = PreparedFollowUpBatch(
      sourceAssistantMessageID: prepared.sourceAssistantMessageID,
      context: context,
      status: .preparing,
      suggestions: [prepared],
      updatedAt: Date(timeIntervalSince1970: 1))
    var state = Self.appState()
    state.chat?.followUpBatch = batch
    let preparations = CallRecorder()
    let pipeline = QueryPipeline(
      run: { _, _ in AsyncStream { $0.finish() } },
      prepareFollowUps: { _ in
        preparations.record("resumed")
        return AsyncStream { continuation in
          continuation.yield(.finished)
          continuation.finish()
        }
      })
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [pipeline] in
      $0.queryPipeline = pipeline
      $0.historyClient = .noop()
      $0.date = .constant(Date(timeIntervalSince1970: 2))
    }
    store.exhaustivity = .off

    await store.send(.appBecameActive)
    await store.receive(
      .followUpPreparationEvent(
        conversationID: Self.conversationA,
        sourceMessageID: prepared.sourceAssistantMessageID,
        event: .finished))
    await store.finish()

    #expect(preparations.recorded == ["resumed"])
    #expect(store.state.followUpPreparation == nil)
    #expect(store.state.chat?.followUpBatch?.status == .completed)
    #expect(store.state.chat?.followUpBatch?.suggestions == [prepared])
  }

  @Test func completionPrefersVisibleConversationQueuedQuestion() async {
    var state = Self.appState(selected: Self.conversationA)
    let activeID = UUID(90)
    state.activeTurn = AppFeature.ActiveTurn(
      questionID: activeID,
      conversationID: Self.conversationB,
      question: "running elsewhere",
      startedAt: Date(timeIntervalSince1970: 0))
    // The globally oldest item belongs to B, but A is visible: A wins.
    state.queue = [
      QueuedQuestion(
        id: UUID(91), conversationID: Self.conversationB,
        question: "older question in B",
        submittedAt: Date(timeIntervalSince1970: 1)),
      QueuedQuestion(
        id: UUID(92), conversationID: Self.conversationA,
        question: "newer question in visible A",
        submittedAt: Date(timeIntervalSince1970: 2)),
    ]
    let clock = TestClock()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.queryPipeline = Self.hangingPipeline()
      $0.historyClient = .noop()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.continuousClock = clock
      $0.haptics = .noop
    }
    store.exhaustivity = .off

    await store.send(
      .pipelineEvent(
        conversationID: Self.conversationB,
        questionID: activeID,
        event: Self.finishedEvent()))
    await store.receive(.turnPersistenceFinished(activeID))
    await store.receive(.dispatchNextIfIdle)

    #expect(store.state.activeTurn?.question == "newer question in visible A")
    #expect(store.state.activeTurn?.conversationID == Self.conversationA)
    #expect(store.state.queue.map(\.question) == ["older question in B"])

    await store.send(.chat(.stopTapped))
    await store.skipInFlightEffects()
    await store.skipReceivedActions()
  }

  @Test func deletingTheActiveConversationDispatchesRemainingQueuedWork() async {
    var state = Self.appState(selected: Self.conversationA)
    state.activeTurn = AppFeature.ActiveTurn(
      questionID: UUID(93),
      conversationID: Self.conversationB,
      question: "running in deleted conversation",
      startedAt: Date(timeIntervalSince1970: 0))
    state.queue = [
      QueuedQuestion(
        id: UUID(94),
        conversationID: Self.conversationA,
        question: "still eligible",
        submittedAt: Date(timeIntervalSince1970: 1))
    ]
    let clock = TestClock()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.queryPipeline = Self.hangingPipeline()
      $0.historyClient = .noop()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.continuousClock = clock
    }
    store.exhaustivity = .off

    await store.send(.deleteConversationTapped(Self.conversationB))
    await store.receive(.dispatchNextIfIdle)

    #expect(store.state.activeTurn?.conversationID == Self.conversationA)
    #expect(store.state.activeTurn?.question == "still eligible")
    #expect(store.state.queue.isEmpty)

    await store.skipInFlightEffects()
  }

  @Test func persistenceTimeoutKeepsQueuedQuestionBehindTheLiveWrite() async {
    var state = Self.appState(selected: Self.conversationA)
    let activeID = UUID(93)
    state.activeTurn = AppFeature.ActiveTurn(
      questionID: activeID,
      conversationID: Self.conversationA,
      question: "running",
      startedAt: Date(timeIntervalSince1970: 0))
    state.queue = [
      QueuedQuestion(
        id: UUID(94), conversationID: Self.conversationA,
        question: "waiting behind persistence",
        submittedAt: Date(timeIntervalSince1970: 1))
    ]
    let clock = TestClock()
    var history = HistoryClient.noop()
    history.persistTerminalTurn = { _, _, _, _ in
      try await clock.sleep(for: .seconds(30))
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [history] in
      $0.queryPipeline = Self.hangingPipeline()
      $0.historyClient = history
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.continuousClock = clock
      $0.haptics = .noop
    }
    store.exhaustivity = .off

    await store.send(
      .pipelineEvent(
        conversationID: Self.conversationA,
        questionID: activeID,
        event: Self.finishedEvent()))
    #expect(store.state.pendingTurnPersistenceID == activeID)
    #expect(store.state.activeTurn == nil)

    await clock.advance(by: .seconds(5))
    await store.receive(.turnPersistenceTimedOut(activeID))
    let timeoutFailure = FailurePresentation(
      code: "turn_persistence_barrier_timed_out",
      title: "Saving is taking longer than expected",
      message:
        "CREG is still saving this conversation. New questions will remain paused to keep your history in order. Restart CREG if saving does not recover.",
      diagnostic:
        "The completed-turn history write exceeded the five-second persistence watchdog.")
    #expect(store.state.pendingTurnPersistenceID == activeID)
    #expect(store.state.pendingTurnPersistence?.didTimeOut == true)
    #expect(store.state.activeTurn == nil)
    #expect(store.state.queue.map(\.question) == ["waiting behind persistence"])
    #expect(store.state.presentedFailure == timeoutFailure)

    await store.send(.dismissFailure)
    await store.send(.turnPersistenceTimedOut(activeID))
    #expect(store.state.presentedFailure == nil)

    await clock.advance(by: .seconds(25))
    await store.receive(.turnPersistenceFinished(activeID))
    await store.receive(.dispatchNextIfIdle)
    #expect(store.state.pendingTurnPersistenceID == nil)
    #expect(store.state.activeTurn?.question == "waiting behind persistence")

    await store.send(.chat(.stopTapped))
    await store.skipInFlightEffects()
    await store.skipReceivedActions()
  }

  @Test func persistenceTimeoutDoesNotResetUnrelatedFailureOrSupportExport() async {
    var state = Self.appState()
    let questionID = UUID(95)
    state.pendingTurnPersistence = AppFeature.PendingTurnPersistence(
      questionID: questionID,
      conversationID: Self.conversationA)
    state.isBuildingSupportBundle = true
    let existingFailure = FailurePresentation(
      code: "existing_failure",
      title: "Existing failure",
      message: "Keep this presentation.",
      diagnostic: "existing")
    state.presentedFailure = existingFailure
    let store = TestStore(initialState: state) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.turnPersistenceTimedOut(questionID))

    #expect(store.state.pendingTurnPersistence?.didTimeOut == true)
    #expect(store.state.presentedFailure == existingFailure)
    #expect(store.state.isBuildingSupportBundle)
  }

  @Test func backgroundCompletionMarksUnreadWithoutChangingSelection() async {
    var state = Self.appState(selected: Self.conversationA)
    let activeID = UUID(90)
    state.activeTurn = AppFeature.ActiveTurn(
      questionID: activeID,
      conversationID: Self.conversationB,
      question: "running elsewhere",
      startedAt: Date(timeIntervalSince1970: 0))
    let haptics = CallRecorder()
    let unreadWrites = CallRecorder()
    var history = HistoryClient.noop()
    history.setUnread = { id, isUnread in
      unreadWrites.record("\(id.uuidString):\(isUnread)")
    }
    let clock = TestClock()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [history] in
      $0.queryPipeline = Self.hangingPipeline()
      $0.historyClient = history
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.continuousClock = clock
      $0.haptics = HapticsClient(answerReady: { haptics.record("haptic") })
    }
    store.exhaustivity = .off

    await store.send(
      .pipelineEvent(
        conversationID: Self.conversationB,
        questionID: activeID,
        event: Self.finishedEvent()))

    #expect(store.state.chat?.conversationID == Self.conversationA)
    #expect(store.state.chat?.messages.isEmpty == true)
    #expect(store.state.conversations[id: Self.conversationB]?.isUnread == true)
    #expect(store.state.answerReadyBanner?.conversationID == Self.conversationB)

    await clock.advance(by: .seconds(4))
    await store.skipReceivedActions()
    #expect(store.state.answerReadyBanner == nil)
    #expect(haptics.count == 1)
    #expect(
      unreadWrites.recorded.contains(
        "\(Self.conversationB.uuidString):true"))
    await store.finish()
  }

  @Test func selectingUnreadConversationClearsUnread() async {
    var state = Self.appState(selected: Self.conversationA)
    state.conversations[id: Self.conversationB]?.isUnread = true
    let unreadWrites = CallRecorder()
    var history = HistoryClient.noop()
    history.loadConversation = { id in
      ConversationSnapshot(
        summary: ConversationSummary(
          id: id, title: "Lease expirations",
          startedAt: Date(timeIntervalSince1970: 0),
          lastActivityAt: Date(timeIntervalSince1970: 10),
          isUnread: true))
    }
    history.setUnread = { id, isUnread in
      unreadWrites.record("\(id.uuidString):\(isUnread)")
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [history] in
      $0.historyClient = history
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.conversationSelected(Self.conversationB))
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.chat?.conversationID == Self.conversationB)
    #expect(store.state.conversations[id: Self.conversationB]?.isUnread == false)
    #expect(
      unreadWrites.recorded.contains(
        "\(Self.conversationB.uuidString):false"))
    #expect(store.state.isBrowserRevealed == false)
  }

  @Test func switchingBackDoesNotRecoverThisProcessesLivePreparedAnswer() async {
    let prepared = Self.preparedFollowUp()
    let provisionalID = UUID(88)
    var state = Self.appState(selected: Self.conversationB)
    var active = AppFeature.ActiveTurn(
      questionID: UUID(90),
      conversationID: Self.conversationA,
      submission: QuestionSubmission(
        question: prepared.question,
        source: .preparedFollowUp(prepared)),
      startedAt: Date(timeIntervalSince1970: 1))
    active.provisionalAssistantMessageID = provisionalID
    state.activeTurn = active
    let snapshot = ConversationSnapshot(
      summary: state.conversations[id: Self.conversationA]!,
      messages: [
        ChatMessage(
          id: provisionalID,
          role: .assistant,
          body: .preparedAnswer(prepared),
          createdAt: Date(timeIntervalSince1970: 2))
      ])
    let recoveryWrites = CallRecorder()
    var history = HistoryClient.noop()
    history.updateMessage = { _, _ in recoveryWrites.record("update") }
    history.endTurnJournal = { _ in recoveryWrites.record("end") }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [history] in
      $0.historyClient = history
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.conversationLoaded(snapshot))
    await store.finish()

    guard case .preparedAnswer? = store.state.chat?.messages.first?.body else {
      Issue.record("Expected the live provisional answer to remain provisional")
      return
    }
    #expect(store.state.chat?.processing?.questionID == active.questionID)
    #expect(recoveryWrites.recorded.isEmpty)
  }

  @Test func deleteThenUndoRestoresConversation() async {
    let deletes = CallRecorder()
    var history = HistoryClient.noop()
    history.deleteConversation = { id in deletes.record(id.uuidString) }
    let clock = TestClock()
    let store = TestStore(initialState: Self.appState()) {
      AppFeature()
    } withDependencies: { [history] in
      $0.historyClient = history
      $0.continuousClock = clock
    }
    store.exhaustivity = .off

    await store.send(.deleteConversationTapped(Self.conversationB))
    #expect(store.state.conversations[id: Self.conversationB] == nil)
    #expect(store.state.pendingDeletion?.summary.id == Self.conversationB)

    await store.send(.undoDeleteTapped)
    #expect(store.state.conversations[id: Self.conversationB] != nil)
    #expect(store.state.pendingDeletion == nil)

    await store.finish()
    #expect(deletes.count == 0)
  }

  @Test func undoSurfacesATerminalWriteFailureDeferredDuringDeletion() async {
    var state = Self.appState()
    let questionID = UUID(96)
    state.pendingTurnPersistence = AppFeature.PendingTurnPersistence(
      questionID: questionID,
      conversationID: Self.conversationB)
    let failure = FailurePresentation(
      code: "history_message_save_failed",
      title: "Conversation not saved",
      message: "The write failed.",
      diagnostic: "test failure")
    let clock = TestClock()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }
    store.exhaustivity = .off

    await store.send(.deleteConversationTapped(Self.conversationB))
    await store.send(
      .turnPersistenceFailed(
        conversationID: Self.conversationB,
        questionID: questionID,
        failure: failure))
    #expect(store.state.presentedFailure == nil)
    #expect(store.state.pendingDeletion?.deferredFailure == failure)

    await store.send(.undoDeleteTapped)
    await store.receive(.operationFailed(failure))

    #expect(store.state.conversations[id: Self.conversationB] != nil)
    #expect(store.state.presentedFailure == failure)
    await store.finish()
  }

  @Test func deleteCommitsAfterFiveSecondUndoWindow() async {
    let deletes = CallRecorder()
    var history = HistoryClient.noop()
    history.deleteConversation = { id in deletes.record(id.uuidString) }
    let clock = TestClock()
    let store = TestStore(initialState: Self.appState()) {
      AppFeature()
    } withDependencies: { [history] in
      $0.historyClient = history
      $0.continuousClock = clock
    }
    store.exhaustivity = .off

    await store.send(.deleteConversationTapped(Self.conversationB))
    await clock.advance(by: .seconds(5))
    await store.skipReceivedActions()

    #expect(store.state.pendingDeletion == nil)
    #expect(deletes.recorded == [Self.conversationB.uuidString])
    await store.finish()
  }

  @Test func confirmedDeleteWaitsForTheConversationPersistenceBarrier() async {
    var state = Self.appState()
    let deletedSummary = state.conversations[id: Self.conversationB]!
    state.conversations.remove(id: Self.conversationB)
    state.pendingDeletion = AppFeature.PendingDeletion(
      summary: deletedSummary, index: 1)
    let questionID = UUID(95)
    state.pendingTurnPersistence = AppFeature.PendingTurnPersistence(
      questionID: questionID,
      conversationID: Self.conversationB)
    let deletes = CallRecorder()
    var history = HistoryClient.noop()
    history.deleteConversation = { id in deletes.record(id.uuidString) }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [history] in
      $0.historyClient = history
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.deleteCountdownFinished)
    #expect(deletes.recorded.isEmpty)
    #expect(store.state.deletionAwaitingTurnPersistence == Self.conversationB)

    await store.send(.turnPersistenceFinished(questionID))
    await store.finish()
    await store.skipReceivedActions()

    #expect(deletes.recorded == [Self.conversationB.uuidString])
  }

  @Test func deletingSelectedConversationSelectsMostRecentRemaining() async {
    var history = HistoryClient.noop()
    history.loadConversation = { id in
      ConversationSnapshot(
        summary: ConversationSummary(
          id: id, title: "Lease expirations",
          startedAt: Date(timeIntervalSince1970: 0),
          lastActivityAt: Date(timeIntervalSince1970: 10)))
    }
    let clock = TestClock()
    let store = TestStore(initialState: Self.appState(selected: Self.conversationA)) {
      AppFeature()
    } withDependencies: { [history] in
      $0.historyClient = history
      $0.continuousClock = clock
    }
    store.exhaustivity = .off

    await store.send(.deleteConversationTapped(Self.conversationA))
    await store.skipReceivedActions()
    #expect(store.state.chat?.conversationID == Self.conversationB)

    await clock.advance(by: .seconds(5))
    await store.skipReceivedActions()
    await store.finish()
  }

  @Test func renameUpdatesSummariesAndPersists() async {
    let renames = CallRecorder()
    var history = HistoryClient.noop()
    history.renameConversation = { _, title in renames.record(title) }
    let store = TestStore(initialState: Self.appState()) {
      AppFeature()
    } withDependencies: { [history] in
      $0.historyClient = history
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.chat(.renameTapped))
    await store.send(.chat(.binding(.set(\.renameDraft, "Q3 valuations"))))
    await store.send(.chat(.renameCommitted))
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.chat?.title == "Q3 valuations")
    #expect(store.state.chat?.isManuallyTitled == true)
    #expect(
      store.state.conversations[id: Self.conversationA]?.title == "Q3 valuations")
    #expect(
      store.state.conversations[id: Self.conversationA]?.isManuallyTitled == true)
    #expect(renames.recorded == ["Q3 valuations"])
  }

  @Test func manualTitleIsNotOverwrittenByFirstQuestion() async {
    var state = Self.appState()
    state.chat?.title = "My analysis"
    state.chat?.isManuallyTitled = true
    state.conversations[id: Self.conversationA]?.title = "My analysis"
    state.conversations[id: Self.conversationA]?.isManuallyTitled = true
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.queryPipeline = Self.scriptedPipeline()
      $0.historyClient = .noop()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.chat(.binding(.set(\.composerText, "new question"))))
    await store.send(.chat(.sendTapped))
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.chat?.title == "My analysis")
    #expect(
      store.state.conversations[id: Self.conversationA]?.title == "My analysis")
  }

  @Test func queuedStarterKeepsDeterministicExecutionPath() async {
    var state = Self.appState()
    let activeID = UUID(90)
    state.activeTurn = AppFeature.ActiveTurn(
      questionID: activeID,
      conversationID: Self.conversationA,
      question: "running",
      startedAt: Date(timeIntervalSince1970: 0))
    state.queue = [
      QueuedQuestion(
        id: UUID(91), conversationID: Self.conversationA,
        question: StarterQueryID.portfolioValueByFundV1.question,
        starter: .portfolioValueByFundV1,
        submittedAt: Date(timeIntervalSince1970: 1))
    ]
    let starterRuns = CallRecorder()
    let historyLoads = CallRecorder()
    let summary = state.conversations[id: Self.conversationA]!
    var history = HistoryClient.noop()
    history.loadConversation = { id in
      historyLoads.record(id.uuidString)
      return ConversationSnapshot(summary: summary)
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [history] in
      $0.queryPipeline = Self.scriptedPipeline(starterRuns: starterRuns)
      $0.historyClient = history
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(
      .pipelineEvent(
        conversationID: Self.conversationA,
        questionID: activeID,
        event: Self.finishedEvent()))
    await store.finish()
    await store.skipReceivedActions()

    #expect(starterRuns.recorded == [StarterQueryID.portfolioValueByFundV1.rawValue])
    #expect(historyLoads.recorded.isEmpty)
    #expect(store.state.queue.isEmpty)
  }

  @Test func retryingFailedStarterRetainsStarterExecutionSource() async {
    var state = Self.appState()
    let messageID = UUID(89)
    var telemetry = TurnTelemetry(
      originalQuestion: StarterQueryID.portfolioValueByFundV1.question)
    telemetry.failureReason = .starterQueryUnavailable
    telemetry.starterQueryID = .portfolioValueByFundV1
    state.chat?.messages.append(
      ChatMessage(
        id: messageID,
        role: .assistant,
        body: .failedTurn(
          reason: .starterQueryUnavailable,
          scopeVerdict: nil),
        createdAt: Date(timeIntervalSince1970: 1),
        devInfo: telemetry))
    let starterRuns = CallRecorder()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.queryPipeline = Self.scriptedPipeline(starterRuns: starterRuns)
      $0.historyClient = .noop()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(
      .chat(.retryFailedTurnTapped(messageID: messageID)))
    await store.finish()
    await store.skipReceivedActions()

    #expect(
      starterRuns.recorded
        == [StarterQueryID.portfolioValueByFundV1.rawValue])
  }

  @Test func queuedTurnWaitsForThePreviousAssistantToPersistAndPreservesOrder() async {
    var state = Self.appState()
    let activeID = UUID(90)
    state.activeTurn = AppFeature.ActiveTurn(
      questionID: activeID,
      conversationID: Self.conversationA,
      question: "running",
      startedAt: Date(timeIntervalSince1970: 0))
    state.queue = [
      QueuedQuestion(
        id: UUID(91),
        conversationID: Self.conversationA,
        question: "Use the previous answer",
        submittedAt: Date(timeIntervalSince1970: 1))
    ]
    let gate = AssistantPersistenceGate()
    let runs = CallRecorder()
    let clock = TestClock()
    var history = HistoryClient.noop()
    history.persistTerminalTurn = { _, message, _, _ in
      if message.role == .assistant {
        await gate.holdFirstAssistant()
      }
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [history] in
      $0.queryPipeline = Self.scriptedPipeline(runs: runs)
      $0.historyClient = history
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.continuousClock = clock
    }
    store.exhaustivity = .off

    await store.send(
      .pipelineEvent(
        conversationID: Self.conversationA,
        questionID: activeID,
        event: Self.finishedEvent()))
    await gate.waitUntilHeld()

    #expect(runs.recorded.isEmpty)
    #expect(store.state.queue.count == 1)
    #expect(store.state.activeTurn == nil)

    await store.send(
      .chat(
        .delegate(
          .submitQuestion(QuestionSubmission(question: "Late question")))))
    #expect(runs.recorded.isEmpty)
    #expect(
      store.state.queue.map(\.question)
        == ["Use the previous answer", "Late question"])
    #expect(store.state.activeTurn == nil)

    await gate.release()
    await store.finish()
    await store.skipReceivedActions()

    #expect(runs.recorded == ["Use the previous answer", "Late question"])
    #expect(store.state.queue.isEmpty)
  }

  static func failedEvent(
    question: String = "Who manages each property?",
    reason: TurnFailureReason
  ) -> PipelineEvent {
    var telemetry = TurnTelemetry(originalQuestion: question)
    telemetry.failureReason = reason
    return .turnFinished(
      outcome: .failed(reason: reason), telemetry: telemetry)
  }

  /// A model failure on plausibly answerable input runs the Scope Verdict
  /// first (C), enriches the rendered failure in place, and only then seeds
  /// Recovery Suggestions (D) with the verdict in hand.
  @Test func eligibleFailedTurnDiagnosesScopeThenSeedsRecovery() async {
    var state = Self.appState()
    let activeID = UUID(98)
    state.activeTurn = AppFeature.ActiveTurn(
      questionID: activeID,
      conversationID: Self.conversationA,
      question: "Who manages each property?",
      startedAt: Date(timeIntervalSince1970: 0))
    let contexts = LockIsolated<[FollowUpSuggestionContext]>([])
    let judged = LockIsolated<[String]>([])
    let scopeLines = LockIsolated<[String]>([])
    let ordering = CallRecorder()
    let expectedVerdict = ScopeVerdictRecord(
      verdict: .inDomainButNotTracked,
      missingSubject: "property managers")
    let pipeline = QueryPipeline(
      run: { _, _ in AsyncStream { $0.finish() } },
      prepareFollowUps: { context in
        ordering.record("prepare")
        contexts.withValue { $0.append(context) }
        return AsyncStream { continuation in
          continuation.yield(.finished)
          continuation.finish()
        }
      })
    var history = HistoryClient.noop()
    history.persistScopeDiagnosis = { _, _, _, line in
      ordering.record("scope-persist")
      scopeLines.withValue { $0.append(line) }
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [history, pipeline] in
      $0.queryPipeline = pipeline
      $0.historyClient = history
      $0.scopeDiagnosis = ScopeDiagnosisClient { question in
        judged.withValue { $0.append(question) }
        return expectedVerdict
      }
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.continuousClock = ImmediateClock()
      $0.haptics = .noop
    }
    store.exhaustivity = .off

    await store.send(
      .pipelineEvent(
        conversationID: Self.conversationA,
        questionID: activeID,
        event: Self.failedEvent(reason: .generationExhausted)))
    await store.finish()
    await store.skipReceivedActions()

    #expect(judged.value == ["Who manages each property?"])
    #expect(ordering.recorded == ["scope-persist", "prepare"])
    #expect(scopeLines.value.count == 1)
    guard
      let decoded = try? JSONDecoder().decode(
        PipelineEvent.self, from: Data(scopeLines.value[0].utf8)),
      case .scopeDiagnosisFinished(_, let persistedVerdict) = decoded
    else {
      Issue.record("Expected an exportable scope-diagnosis event")
      return
    }
    #expect(persistedVerdict == expectedVerdict)

    // D waited for C: the seeded context already carries the verdict.
    let seeded = contexts.value
    #expect(seeded.count == 1)
    guard case .turnFailure(let reason, let verdict)? = seeded.first?.seed
    else {
      Issue.record("Expected a failure-seeded suggestion context")
      return
    }
    #expect(reason == .generationExhausted)
    #expect(verdict == expectedVerdict)
    #expect(store.state.chat?.followUpBatch?.context?.isRecoverySeed == true)

    // The rendered failure was enriched in place.
    guard
      case .failedTurn(_, let renderedVerdict)? =
        store.state.chat?.messages.last(where: { $0.role == .assistant })?.body
    else {
      Issue.record("Expected the failure message to remain rendered")
      return
    }
    #expect(renderedVerdict == expectedVerdict)
    #expect(
      store.state.chat?.messages.last(where: { $0.role == .assistant })?
        .devInfo?.scopeVerdict == expectedVerdict)
    #expect(store.state.pendingScopeDiagnosis == nil)
  }

  @Test func backgroundFailureStillPersistsDiagnosisBeforeRecovery() async {
    var state = Self.appState(selected: Self.conversationA)
    let activeID = UUID(109)
    state.activeTurn = AppFeature.ActiveTurn(
      questionID: activeID,
      conversationID: Self.conversationB,
      question: "Who manages each property?",
      startedAt: Date(timeIntervalSince1970: 0))
    let expectedVerdict = ScopeVerdictRecord(
      verdict: .inDomainButNotTracked,
      missingSubject: "property managers")
    let ordering = CallRecorder()
    let contexts = LockIsolated<[FollowUpSuggestionContext]>([])
    let persistedConversationIDs = LockIsolated<[UUID]>([])
    let persistedVerdicts = LockIsolated<[ScopeVerdictRecord]>([])
    let pipeline = QueryPipeline(
      run: { _, _ in AsyncStream { $0.finish() } },
      prepareFollowUps: { context in
        ordering.record("prepare")
        contexts.withValue { $0.append(context) }
        return AsyncStream { continuation in
          continuation.yield(.finished)
          continuation.finish()
        }
      })
    var history = HistoryClient.noop()
    history.persistScopeDiagnosis = { conversationID, _, verdict, _ in
      persistedConversationIDs.withValue { $0.append(conversationID) }
      persistedVerdicts.withValue { $0.append(verdict) }
      ordering.record("scope-persist")
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [history, pipeline] in
      $0.queryPipeline = pipeline
      $0.historyClient = history
      $0.scopeDiagnosis = ScopeDiagnosisClient { _ in expectedVerdict }
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.continuousClock = ImmediateClock()
      $0.haptics = .noop
    }
    store.exhaustivity = .off

    await store.send(
      .pipelineEvent(
        conversationID: Self.conversationB,
        questionID: activeID,
        event: Self.failedEvent(reason: .generationExhausted)))
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.chat?.conversationID == Self.conversationA)
    #expect(ordering.recorded == ["scope-persist", "prepare"])
    #expect(persistedConversationIDs.value == [Self.conversationB])
    #expect(persistedVerdicts.value == [expectedVerdict])
    guard case .turnFailure(_, let verdict)? = contexts.value.first?.seed else {
      Issue.record("Expected background recovery context")
      return
    }
    #expect(verdict == expectedVerdict)
  }

  /// Timeouts already know their cause; the diagnosis never runs for them.
  @Test func timedOutFailureNeverRunsScopeDiagnosis() async {
    var state = Self.appState()
    let activeID = UUID(96)
    state.activeTurn = AppFeature.ActiveTurn(
      questionID: activeID,
      conversationID: Self.conversationA,
      question: "Which fund leads?",
      startedAt: Date(timeIntervalSince1970: 0))
    let judged = LockIsolated<[String]>([])
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.queryPipeline = QueryPipeline(
        run: { _, _ in AsyncStream { $0.finish() } })
      $0.historyClient = .noop()
      $0.scopeDiagnosis = ScopeDiagnosisClient { question in
        judged.withValue { $0.append(question) }
        return ScopeVerdictRecord(verdict: .outsideRealEstate)
      }
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.continuousClock = ImmediateClock()
      $0.haptics = .noop
    }
    store.exhaustivity = .off

    await store.send(
      .pipelineEvent(
        conversationID: Self.conversationA,
        questionID: activeID,
        event: Self.failedEvent(reason: .timedOut(stage: "generation"))))
    await store.finish()
    await store.skipReceivedActions()

    #expect(judged.value.isEmpty)
    #expect(store.state.pendingScopeDiagnosis == nil)
  }

  /// Terminal reasons cannot pre-execute anything and must not seed
  /// suggestions.
  @Test func ineligibleFailedTurnDoesNotSeedRecoverySuggestions() async {
    var state = Self.appState()
    let activeID = UUID(99)
    state.activeTurn = AppFeature.ActiveTurn(
      questionID: activeID,
      conversationID: Self.conversationA,
      question: "Who manages each property?",
      startedAt: Date(timeIntervalSince1970: 0))
    let preparations = CallRecorder()
    let pipeline = QueryPipeline(
      run: { _, _ in AsyncStream { $0.finish() } },
      prepareFollowUps: { _ in
        preparations.record("started")
        return AsyncStream { continuation in
          continuation.finish()
        }
      })
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [pipeline] in
      $0.queryPipeline = pipeline
      $0.historyClient = .noop()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.continuousClock = ImmediateClock()
      $0.haptics = .noop
    }
    store.exhaustivity = .off

    for reason in [
      TurnFailureReason.databaseUnavailable,
      .timedOut(stage: "generation"),
      .cancelled,
      .starterQueryUnavailable,
    ] {
      #expect(!reason.isEligibleForRecoverySuggestions)
    }

    await store.send(
      .pipelineEvent(
        conversationID: Self.conversationA,
        questionID: activeID,
        event: Self.failedEvent(reason: .databaseUnavailable)))
    await store.finish()
    await store.skipReceivedActions()

    #expect(preparations.recorded.isEmpty)
    #expect(store.state.chat?.followUpBatch == nil)
  }

  @Test func followUpPreparationWaitsForTerminalPersistence() async {
    var state = Self.appState()
    let activeID = UUID(97)
    state.activeTurn = AppFeature.ActiveTurn(
      questionID: activeID,
      conversationID: Self.conversationA,
      question: "Which property leads?",
      startedAt: Date(timeIntervalSince1970: 0))
    let gate = AssistantPersistenceGate()
    let preparations = CallRecorder()
    let clock = TestClock()
    var history = HistoryClient.noop()
    history.persistTerminalTurn = { _, _, _, _ in
      await gate.holdFirstAssistant()
    }
    let pipeline = QueryPipeline(
      run: { _, _ in AsyncStream { $0.finish() } },
      prepareFollowUps: { _ in
        preparations.record("started")
        return AsyncStream { continuation in
          continuation.yield(.finished)
          continuation.finish()
        }
      })
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [history, pipeline] in
      $0.queryPipeline = pipeline
      $0.historyClient = history
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.continuousClock = clock
      $0.haptics = .noop
    }
    store.exhaustivity = .off

    await store.send(
      .pipelineEvent(
        conversationID: Self.conversationA,
        questionID: activeID,
        event: Self.finishedEvent(question: "Which property leads?")))
    await gate.waitUntilHeld()

    #expect(preparations.recorded.isEmpty)
    #expect(store.state.pendingTurnPersistenceID == activeID)
    #expect(store.state.followUpPreparation == nil)

    await gate.release()
    await store.finish()
    await store.skipReceivedActions()

    #expect(preparations.recorded == ["started"])
    #expect(store.state.pendingTurnPersistence == nil)
  }

  /// A mid-foreground availability flip can leave a stale-enabled composer.
  /// The committed submission must never be dropped — its composer text and
  /// draft are already gone — so it queues and dispatches on recovery.
  @Test func submissionDuringUnavailabilityQueuesInsteadOfDropping() async {
    let availability = LockIsolated<FMAvailability>(
      .unavailable(reason: .modelNotReady))
    let runs = CallRecorder()
    let store = TestStore(initialState: Self.appState()) {
      AppFeature()
    } withDependencies: {
      $0.fmStatus = FMStatusClient(availability: { availability.value })
      $0.queryPipeline = Self.scriptedPipeline(runs: runs)
      $0.historyClient = .noop()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(
      .chat(
        .delegate(
          .submitQuestion(QuestionSubmission(question: "Which fund leads?")))))
    await store.finish()

    #expect(runs.recorded.isEmpty)
    #expect(store.state.activeTurn == nil)
    #expect(store.state.queue.map(\.question) == ["Which fund leads?"])

    availability.setValue(.available)
    await store.send(.appBecameActive)
    await store.finish()
    await store.skipReceivedActions()

    #expect(runs.recorded == ["Which fund leads?"])
    #expect(store.state.queue.isEmpty)
  }

  /// fmAvailability is the only dispatch gate that reopens without an action
  /// of its own. A queued question stranded behind it must dispatch when
  /// availability recovers mid-foreground, without a scene transition.
  @Test func strandedQueueDispatchesWhenAvailabilityRecoversInForeground() async {
    var state = Self.appState()
    let activeID = UUID(70)
    state.activeTurn = AppFeature.ActiveTurn(
      questionID: activeID,
      conversationID: Self.conversationA,
      question: "running",
      startedAt: Date(timeIntervalSince1970: 0))
    state.queue = [
      QueuedQuestion(
        id: UUID(71),
        conversationID: Self.conversationA,
        question: "Run after AI returns",
        submittedAt: Date(timeIntervalSince1970: 1))
    ]
    let availability = LockIsolated<FMAvailability>(.available)
    let watchers = LockIsolated<[AsyncStream<FMAvailability>.Continuation]>([])
    let runs = CallRecorder()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.fmStatus = FMStatusClient(
        availability: { availability.value },
        availabilityUpdates: {
          AsyncStream { continuation in
            watchers.withValue { $0.append(continuation) }
          }
        })
      $0.queryPipeline = Self.scriptedPipeline(runs: runs)
      $0.historyClient = .noop()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    availability.setValue(.unavailable(reason: .modelNotReady))
    await store.send(
      .pipelineEvent(
        conversationID: Self.conversationA,
        questionID: activeID,
        event: Self.finishedEvent()))
    await store.receive(.turnPersistenceFinished(activeID))
    await store.receive(.dispatchNextIfIdle)

    #expect(runs.recorded.isEmpty)
    #expect(store.state.queue.count == 1)
    while watchers.value.isEmpty { await Task.yield() }

    // Availability recovers with the app still foregrounded: the armed
    // watch re-runs the scheduler and the stranded question dispatches.
    availability.setValue(.available)
    watchers.value.forEach { $0.yield(.available) }
    await store.receive(.dispatchNextIfIdle)

    #expect(runs.recorded == ["Run after AI returns"])
    #expect(store.state.queue.isEmpty)

    watchers.value.forEach { $0.finish() }
    await store.finish()
    await store.skipReceivedActions()
  }

  /// Deleting the diagnosed conversation must clear the retained diagnosis;
  /// an unresumable one would gate preparation, resume, and model
  /// maintenance for the rest of the session.
  @Test func deletingTheDiagnosedConversationClearsThePendingDiagnosis() async {
    let sourceMessageID = UUID(77)
    let context = FollowUpSuggestionContext(
      sourceAssistantMessageID: sourceMessageID,
      question: "Who manages each property?",
      standaloneQuestion: "Who manages each property?",
      seed: .turnFailure(reason: .generationExhausted, scopeVerdict: nil))
    var state = Self.appState(selected: Self.conversationA)
    state.pendingScopeDiagnosis = AppFeature.PendingScopeDiagnosis(
      conversationID: Self.conversationB,
      messageID: sourceMessageID,
      context: context)
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.queryPipeline = Self.hangingPipeline()
      $0.historyClient = .noop()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.deleteConversationTapped(Self.conversationB))
    #expect(store.state.pendingScopeDiagnosis == nil)
    await store.finish()
    await store.skipReceivedActions()
  }

  /// A retained diagnosis whose conversation no longer exists clears on the
  /// next resume attempt instead of blocking the idle gates forever.
  @Test func unresumableRetainedDiagnosisClearsOnActivation() async {
    let context = FollowUpSuggestionContext(
      sourceAssistantMessageID: UUID(77),
      question: "Who manages each property?",
      standaloneQuestion: "Who manages each property?",
      seed: .turnFailure(reason: .generationExhausted, scopeVerdict: nil))
    var state = Self.appState()
    state.pendingScopeDiagnosis = AppFeature.PendingScopeDiagnosis(
      conversationID: UUID(200),
      messageID: UUID(77),
      context: context)
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.queryPipeline = Self.hangingPipeline()
      $0.historyClient = .noop()
    }
    store.exhaustivity = .off

    await store.send(.appBecameActive)
    await store.finish()

    #expect(store.state.pendingScopeDiagnosis == nil)
  }

  /// A question submitted while the Scope Verdict's history write is still
  /// in flight owns the scheduler; the write's completion must veto Recovery
  /// Suggestion preparation instead of racing the new turn for the
  /// serializer with an uncancellable zombie effect.
  @Test func submissionDuringVerdictPersistenceVetoesRecoveryPreparation() async {
    var state = Self.appState()
    let activeID = UUID(98)
    state.activeTurn = AppFeature.ActiveTurn(
      questionID: activeID,
      conversationID: Self.conversationA,
      question: "Who manages each property?",
      startedAt: Date(timeIntervalSince1970: 0))
    let gate = AssistantPersistenceGate()
    let preparations = CallRecorder()
    let batchSaves = CallRecorder()
    let pipeline = QueryPipeline(
      run: { _, _ in AsyncStream { _ in } },
      prepareFollowUps: { _ in
        preparations.record("started")
        return AsyncStream { $0.finish() }
      })
    var history = HistoryClient.noop()
    history.persistScopeDiagnosis = { _, _, _, _ in
      await gate.holdFirstAssistant()
    }
    history.saveFollowUpBatch = { _, _ in batchSaves.record("saved") }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [history, pipeline] in
      $0.queryPipeline = pipeline
      $0.historyClient = history
      $0.scopeDiagnosis = ScopeDiagnosisClient { _ in
        ScopeVerdictRecord(verdict: .likelyAnswerableModelFailed)
      }
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 5))
      $0.continuousClock = ImmediateClock()
      $0.haptics = .noop
    }
    store.exhaustivity = .off

    await store.send(
      .pipelineEvent(
        conversationID: Self.conversationA,
        questionID: activeID,
        event: Self.failedEvent(reason: .generationExhausted)))
    await gate.waitUntilHeld()

    // The verdict write is mid-flight when a new question dispatches.
    await store.send(
      .chat(
        .delegate(
          .submitQuestion(QuestionSubmission(question: "New question")))))
    #expect(store.state.activeTurn?.question == "New question")

    await gate.release()
    await store.receive(\.scopeDiagnosisPersisted)

    #expect(preparations.recorded.isEmpty)
    #expect(batchSaves.recorded.isEmpty)
    #expect(store.state.followUpPreparation == nil)
    #expect(store.state.activeTurn?.question == "New question")

    await store.send(.chat(.stopTapped))
    await store.finish()
    await store.skipReceivedActions()
  }

  /// A resumed interrupted diagnosis can occupy the preparation slot ahead
  /// of the selected conversation's persisted `.preparing` batch. When that
  /// preparation finishes, the freed slot must resume the waiting batch
  /// instead of leaving it for the next activation.
  @Test func finishedPreparationResumesTheSelectedConversationsWaitingBatch() async {
    let prepared = Self.preparedFollowUp()
    let contextA = FollowUpSuggestionContext(
      sourceAssistantMessageID: prepared.sourceAssistantMessageID,
      question: "Which property leads?",
      standaloneQuestion: "Which property leads?",
      narration: "One property found.",
      result: answer)
    let batchA = PreparedFollowUpBatch(
      sourceAssistantMessageID: prepared.sourceAssistantMessageID,
      context: contextA,
      status: .preparing,
      suggestions: [prepared],
      updatedAt: Date(timeIntervalSince1970: 1))
    let sourceB = UUID(88)
    let contextB = FollowUpSuggestionContext(
      sourceAssistantMessageID: sourceB,
      question: "Who manages each property?",
      standaloneQuestion: "Who manages each property?",
      seed: .turnFailure(reason: .generationExhausted, scopeVerdict: nil))
    var state = Self.appState(selected: Self.conversationA)
    state.chat?.followUpBatch = batchA
    state.followUpPreparation = AppFeature.FollowUpPreparationState(
      conversationID: Self.conversationB,
      context: contextB,
      batch: PreparedFollowUpBatch(
        sourceAssistantMessageID: sourceB,
        context: contextB,
        status: .preparing,
        updatedAt: Date(timeIntervalSince1970: 2)))
    let preparedContexts = LockIsolated<[FollowUpSuggestionContext]>([])
    let pipeline = QueryPipeline(
      run: { _, _ in AsyncStream { $0.finish() } },
      prepareFollowUps: { context in
        preparedContexts.withValue { $0.append(context) }
        return AsyncStream { continuation in
          continuation.yield(.finished)
          continuation.finish()
        }
      })
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: { [pipeline] in
      $0.queryPipeline = pipeline
      $0.historyClient = .noop()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 5))
    }
    store.exhaustivity = .off

    await store.send(
      .followUpPreparationEvent(
        conversationID: Self.conversationB,
        sourceMessageID: sourceB,
        event: .finished))
    await store.finish()
    await store.skipReceivedActions()

    #expect(
      preparedContexts.value.map(\.sourceAssistantMessageID)
        == [prepared.sourceAssistantMessageID])
    #expect(store.state.followUpPreparation == nil)
    #expect(store.state.chat?.followUpBatch?.status == .completed)
  }

  /// The debug capture funnels 87 serialized FM calls into the shared
  /// serializer while turn deadlines keep ticking; it must refuse to start
  /// unless the scheduler is fully idle.
  @Test func answerabilityCaptureRefusesToStartUnlessSchedulerIsIdle() async {
    var state = Self.appState()
    state.activeTurn = AppFeature.ActiveTurn(
      questionID: UUID(90),
      conversationID: Self.conversationA,
      question: "running",
      startedAt: Date(timeIntervalSince1970: 0))
    let judged = LockIsolated(0)
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.scopeDiagnosis = ScopeDiagnosisClient { _ in
        judged.withValue { $0 += 1 }
        return nil
      }
    }
    store.exhaustivity = .off

    await store.send(.answerabilityCaptureTapped)
    await store.finish()

    #expect(store.state.isCapturingAnswerability == false)
    #expect(judged.value == 0)
  }

  @Test func answerabilityCaptureRefusesToStartWhileSceneIsInactive() async {
    var state = Self.appState()
    state.isSceneActive = false
    let judged = LockIsolated(0)
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.scopeDiagnosis = ScopeDiagnosisClient { _ in
        judged.withValue { $0 += 1 }
        return nil
      }
    }
    store.exhaustivity = .off

    await store.send(.answerabilityCaptureTapped)
    await store.finish()

    #expect(store.state.isCapturingAnswerability == false)
    #expect(judged.value == 0)
  }

  /// A capture completion that lost the race with its cancellation must not
  /// leave the finished archive orphaned in tmp.
  @Test func staleCaptureCompletionRemovesTheOrphanedArchive() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("stale-answerability-\(UUID().uuidString).zip")
    try Data("zip".utf8).write(to: url)
    let store = TestStore(initialState: Self.appState()) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.answerabilityCaptureReady(id: UUID(91), url: url))
    await store.finish()

    #expect(store.state.answerabilityCaptureExport == nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test func debugLaunchBenchmarkWaitsForReadinessAndRunsStandalone() async {
    var state = Self.appState()
    state.modelReadiness = .preparing
    state.launchBenchmarkQuestion = "Which property leads?"
    state.chat?.messages.append(
      ChatMessage(
        id: UUID(50), role: .user, body: .text("old question"),
        createdAt: Date(timeIntervalSince1970: 0)))
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.queryPipeline = Self.scriptedPipeline()
      $0.historyClient = .noop()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(
      .modelPrepared(
        ModelPreparationReport(mode: .evaluated, elapsedMilliseconds: 0)))
    #expect(store.state.launchBenchmarkStarted)
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.chat?.messages.count == 2)
    #expect(store.state.chat?.messages.first?.body == .text("Which property leads?"))
  }
}

@MainActor
@Suite struct ChatFeatureConversationTests {
  static let conversationID = UUID(10)

  static func chatState() -> ChatFeature.State {
    ChatFeature.State(conversationID: conversationID)
  }

  static func answerMessage(id: UUID) -> ChatMessage {
    ChatMessage(
      id: id, role: .assistant,
      body: .answer(
        result: answer,
        narration: "One property found.",
        sql: "SELECT name FROM properties",
        notice: nil),
      createdAt: Date(timeIntervalSince1970: 0))
  }

  @Test func provisionalPreparedAnswerRecoversInPlaceAfterTermination() {
    let prepared = AppFeatureSchedulerTests.preparedFollowUp()
    let messageID = UUID(88)
    let snapshot = ConversationSnapshot(
      summary: ConversationSummary(
        id: Self.conversationID,
        title: "Prepared follow-up",
        startedAt: Date(timeIntervalSince1970: 0),
        lastActivityAt: Date(timeIntervalSince1970: 2)),
      messages: [
        ChatMessage(
          id: messageID,
          role: .assistant,
          body: .preparedAnswer(prepared),
          createdAt: Date(timeIntervalSince1970: 2))
      ],
      interruptedTurn: InterruptedTurn(
        question: prepared.question,
        interruptedAt: Date(timeIntervalSince1970: 1)))

    let state = ChatFeature.State(snapshot: snapshot)

    #expect(state.messages.count == 1)
    #expect(state.messages.first?.id == messageID)
    guard
      case .answer(let result, let narration, let sql, _)? =
        state.messages.first?.body
    else {
      Issue.record("Expected deterministic prepared-answer recovery")
      return
    }
    #expect(result == prepared.result)
    #expect(sql == prepared.sql)
    #expect(narration == PreparedAnswerFallback.narration(for: prepared.result))
    #expect(state.interruptedTurn == nil)
  }

  @Test func keyboardRefocusCancelsPendingSubmission() async {
    var state = Self.chatState()
    state.composerText = "question"
    let store = TestStore(initialState: state) {
      ChatFeature()
    }
    store.exhaustivity = .off

    await store.send(.submissionRequested) {
      $0.isSubmissionPending = true
    }
    await store.send(.submissionRefocused) {
      $0.isSubmissionPending = false
    }
    // Nothing was committed, so the composer keeps its text.
    #expect(store.state.composerText == "question")
  }

  @Test func preparedFollowUpTapPreservesTheTypedDraft() async {
    let prepared = AppFeatureSchedulerTests.preparedFollowUp()
    var state = Self.chatState()
    state.composerText = "Keep this draft for later"
    state.followUpBatch = PreparedFollowUpBatch(
      sourceAssistantMessageID: prepared.sourceAssistantMessageID,
      suggestions: [prepared],
      updatedAt: Date(timeIntervalSince1970: 1))
    let drafts = CallRecorder()
    var history = HistoryClient.noop()
    history.saveDraft = { _, draft in drafts.record(draft) }
    let store = TestStore(initialState: state) {
      ChatFeature()
    } withDependencies: { [history] in
      $0.historyClient = history
    }
    store.exhaustivity = .off

    await store.send(.preparedFollowUpTapped(prepared.id))
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.composerText == "Keep this draft for later")
    // AppFeature owns consuming the batch after its authoritative readiness
    // check accepts the delegated submission.
    #expect(store.state.followUpBatch?.suggestions == [prepared])
    #expect(drafts.recorded.isEmpty)
  }

  @Test func preparedFollowUpTapDuringPreparationKeepsTheChipBatch() async {
    let prepared = AppFeatureSchedulerTests.preparedFollowUp()
    var state = Self.chatState()
    state.isSubmissionEnabled = false
    state.followUpBatch = PreparedFollowUpBatch(
      sourceAssistantMessageID: prepared.sourceAssistantMessageID,
      suggestions: [prepared],
      updatedAt: Date(timeIntervalSince1970: 1))
    let store = TestStore(initialState: state) {
      ChatFeature()
    }
    store.exhaustivity = .off

    await store.send(.preparedFollowUpTapped(prepared.id))
    await store.finish()

    #expect(store.state.followUpBatch?.suggestions == [prepared])
  }

  @Test func feedbackIsReversibleAndSwitchable() async {
    let saved = CallRecorder()
    let cleared = CallRecorder()
    var history = HistoryClient.noop()
    history.saveFeedback = { _, feedback in
      saved.record(feedback.verdict.rawValue)
    }
    history.clearFeedback = { _, messageID in
      cleared.record(messageID.uuidString)
    }
    let messageID = UUID(70)
    var state = Self.chatState()
    state.messages.append(Self.answerMessage(id: messageID))
    let store = TestStore(initialState: state) {
      ChatFeature()
    } withDependencies: { [history] in
      $0.historyClient = history
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.feedbackHelpfulTapped(messageID: messageID))
    #expect(store.state.feedback[messageID]?.verdict == .helpful)
    #expect(store.state.correctionContext == nil)

    // Switching verdicts opens the correction context above the composer.
    await store.send(.feedbackNotRightTapped(messageID: messageID))
    #expect(store.state.feedback[messageID]?.verdict == .notRight)
    #expect(store.state.correctionContext?.messageID == messageID)

    // Tapping the active verdict reverses it.
    await store.send(.feedbackNotRightTapped(messageID: messageID))
    #expect(store.state.feedback[messageID] == nil)
    #expect(store.state.correctionContext == nil)

    await store.finish()
    #expect(saved.recorded == ["helpful", "not_right"])
    #expect(cleared.recorded == [messageID.uuidString])
  }

  @Test func nextSubmissionRecordsTheCorrection() async {
    let corrections = CallRecorder()
    var history = HistoryClient.noop()
    history.saveFeedback = { _, feedback in
      corrections.record(feedback.correction ?? "none")
    }
    let messageID = UUID(70)
    var state = Self.chatState()
    state.messages.append(Self.answerMessage(id: messageID))
    let store = TestStore(initialState: state) {
      ChatFeature()
    } withDependencies: { [history] in
      $0.historyClient = history
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.feedbackNotRightTapped(messageID: messageID))
    await store.send(
      .binding(.set(\.composerText, "No — only include held properties")))
    await store.send(.sendTapped)
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.correctionContext == nil)
    #expect(
      store.state.feedback[messageID]?.correction
        == "No — only include held properties")
    #expect(corrections.recorded.contains("No — only include held properties"))
  }

  @Test func askAgainResubmitsInterruptedTurnAndClearsJournal() async {
    let journalEnds = CallRecorder()
    var history = HistoryClient.noop()
    history.endTurnJournal = { id in journalEnds.record(id.uuidString) }
    var state = Self.chatState()
    state.interruptedTurn = InterruptedTurn(
      question: "Which leases expire soonest?",
      interruptedAt: Date(timeIntervalSince1970: 0))
    let store = TestStore(initialState: state) {
      ChatFeature()
    } withDependencies: { [history] in
      $0.historyClient = history
      $0.date = .constant(Date(timeIntervalSince1970: 1))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.askAgainTapped)
    await store.receive(
      .delegate(
        .submitQuestion(
          QuestionSubmission(question: "Which leases expire soonest?"))))
    await store.finish()

    #expect(store.state.interruptedTurn == nil)
    #expect(store.state.composerText.isEmpty)
    #expect(journalEnds.recorded == [Self.conversationID.uuidString])
  }

  @Test func readAloudLifecyclePlaysPausesResumesStops() async {
    let messageID = UUID(70)
    var state = Self.chatState()
    state.messages.append(Self.answerMessage(id: messageID))
    let store = TestStore(initialState: state) {
      ChatFeature()
    } withDependencies: {
      $0.readAloud = .noop
      $0.historyClient = .noop()
    }
    store.exhaustivity = .off

    await store.send(.readAloudTapped(messageID: messageID))
    #expect(store.state.readAloud?.messageID == messageID)
    #expect(store.state.readAloud?.phase == .playing)

    await store.send(.readAloudPauseTapped)
    #expect(store.state.readAloud?.phase == .paused)

    await store.send(.readAloudResumeTapped)
    #expect(store.state.readAloud?.phase == .playing)

    await store.send(.readAloudStopTapped)
    #expect(store.state.readAloud == nil)
    await store.finish()
  }

  @Test func draftSavesAfterDebounce() async {
    let drafts = CallRecorder()
    var history = HistoryClient.noop()
    history.saveDraft = { _, draft in drafts.record(draft) }
    let clock = TestClock()
    let store = TestStore(initialState: Self.chatState()) {
      ChatFeature()
    } withDependencies: { [history] in
      $0.historyClient = history
      $0.continuousClock = clock
    }
    store.exhaustivity = .off

    await store.send(.binding(.set(\.composerText, "unsent draft")))
    #expect(drafts.count == 0)
    await clock.advance(by: .milliseconds(500))
    await store.finish()
    #expect(drafts.recorded == ["unsent draft"])
  }

  @Test func conversationTurnsPairsQuestionsWithAnswerSummaries() {
    let messages: [ChatMessage] = [
      ChatMessage(
        id: UUID(1), role: .user, body: .text("first question"),
        createdAt: Date(timeIntervalSince1970: 0)),
      ChatMessage(
        id: UUID(2), role: .assistant,
        body: .answer(
          result: answer, narration: "first summary", sql: "SELECT 1",
          notice: nil),
        createdAt: Date(timeIntervalSince1970: 1)),
      ChatMessage(
        id: UUID(3), role: .user, body: .text("clarifying question"),
        createdAt: Date(timeIntervalSince1970: 2)),
      ChatMessage(
        id: UUID(4), role: .assistant, body: .clarification("which fund?"),
        createdAt: Date(timeIntervalSince1970: 3)),
      ChatMessage(
        id: UUID(5), role: .user, body: .text("second question"),
        createdAt: Date(timeIntervalSince1970: 4)),
      ChatMessage(
        id: UUID(6), role: .assistant,
        body: .answer(
          result: answer, narration: "second summary", sql: "SELECT 2",
          notice: nil),
        createdAt: Date(timeIntervalSince1970: 5)),
    ]

    let turns = ChatFeature.conversationTurns(from: messages)

    #expect(
      turns == [
        ConversationTurn(question: "first question", answerSummary: "first summary"),
        ConversationTurn(question: "second question", answerSummary: "second summary"),
      ])
  }
}
