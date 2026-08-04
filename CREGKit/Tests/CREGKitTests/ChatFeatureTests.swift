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
          var telemetry = TurnTelemetry(originalQuestion: starter.question)
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
      .chat(.delegate(.submitQuestion(question: "first question", starter: nil))))
    #expect(store.state.activeTurn?.question == "first question")

    await store.send(.chat(.binding(.set(\.composerText, "second question"))))
    await store.send(.chat(.sendTapped))
    await store.receive(
      .chat(.delegate(.submitQuestion(question: "second question", starter: nil))))
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
    #expect(unreadWrites.recorded.contains(
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
    #expect(unreadWrites.recorded.contains(
      "\(Self.conversationB.uuidString):false"))
    #expect(store.state.isBrowserRevealed == false)
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

    await store.send(.modelPrepared)
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
        .submitQuestion(question: "Which leases expire soonest?", starter: nil)))
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

    #expect(turns == [
      ConversationTurn(question: "first question", answerSummary: "first summary"),
      ConversationTurn(question: "second question", answerSummary: "second summary"),
    ])
  }
}
