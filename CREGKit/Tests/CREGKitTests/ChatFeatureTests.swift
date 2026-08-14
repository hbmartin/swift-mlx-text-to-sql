import ComposableArchitecture
import Foundation
import Testing

@testable import CREGEngine
@testable import CREGFeatures

private let answer = QueryResult(columns: ["name"], rows: [[.text("Sable Tower")]])

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
      runStarter: { starter, _ in
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
    guard case .failure(let message)? = store.state.chat?.messages.last?.body else {
      Issue.record("Expected unterminated stream recovery to render a failure")
      return
    }
    #expect(message == "CREG couldn’t finish that answer. Please try again.")
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
    var history = HistoryClient.noop()
    history.appendMessage = { _, message in
      let kind =
        if case .preparedAnswer = message.body {
          "provisional"
        } else if message.role == .user {
          "user"
        } else {
          "assistant"
        }
      writes.record("append:\(kind):\(message.id.uuidString)")
    }
    history.updateMessage = { _, message in
      writes.record("update:final:\(message.id.uuidString)")
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
    history.updateMessage = { _, message in
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
      mode: .table, specificationID: "policy|table")
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
    history.updateMessage = { _, message in
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

  @Test func appInactivityCancelsPreparationAndPersistsItsEventsForResume() async {
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

    await store.send(.appBecameInactive)
    await store.finish()

    #expect(store.state.followUpPreparation == nil)
    #expect(store.state.chat?.followUpBatch == batch)
    #expect(eventWrites.recorded == ["{\"prepared\":true}"])
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
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.queryPipeline = Self.hangingPipeline()
      $0.historyClient = .noop()
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
        event: Self.finishedEvent()))

    #expect(store.state.activeTurn?.question == "newer question in visible A")
    #expect(store.state.activeTurn?.conversationID == Self.conversationA)
    #expect(store.state.queue.map(\.question) == ["older question in B"])

    await store.send(.chat(.stopTapped))
    await store.skipInFlightEffects()
    await store.skipReceivedActions()
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
      .pipelineEvent(
        conversationID: Self.conversationA,
        questionID: activeID,
        event: Self.finishedEvent()))
    await store.finish()
    await store.skipReceivedActions()

    #expect(starterRuns.recorded == [StarterQueryID.portfolioValueByFundV1.rawValue])
    #expect(store.state.queue.isEmpty)
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
    #expect(store.state.followUpBatch == nil)
    #expect(drafts.recorded.isEmpty)
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
