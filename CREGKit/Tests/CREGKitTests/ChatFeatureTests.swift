import ComposableArchitecture
import Foundation
import Testing

@testable import CREGEngine
@testable import CREGFeatures

private let answer = QueryResult(columns: ["name"], rows: [[.text("Sable Tower")]])

private enum ChatTestError: Error {
  case preparationFailed
}

private final class CallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func increment() {
    lock.lock()
    value += 1
    lock.unlock()
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

@MainActor
@Suite struct ChatFeatureTests {
  static func scriptedPipeline() -> QueryPipeline {
    QueryPipeline { question, _ in
      AsyncStream { continuation in
        var telemetry = TurnTelemetry(originalQuestion: question)
        telemetry.stageTimings.totalMicroseconds = 3_000
        continuation.yield(.turnStarted(question: question))
        continuation.yield(.questionResolved(
          standaloneQuestion: question,
          rewriteApplied: false,
          usedFM: false,
          elapsedMicroseconds: 0))
        continuation.yield(.gateStarted)
        continuation.yield(.narrationStarted)
        continuation.yield(.narrationFinished(
          narration: "One property found.",
          usedFM: false,
          elapsedMicroseconds: 100))
        continuation.yield(.turnFinished(
          outcome: .answered(
            result: answer,
            narration: "One property found.",
            sql: "SELECT name FROM properties",
            notice: nil),
          telemetry: telemetry))
        continuation.finish()
      }
    }
  }

  @Test func sendProducesAnswerMessage() async {
    var initialState = ChatFeature.State()
    initialState.conversationID = UUID()
    initialState.modelReadiness = .ready
    let store = TestStore(initialState: initialState) {
      ChatFeature()
    } withDependencies: {
      $0.queryPipeline = Self.scriptedPipeline()
      $0.historyClient = .noop()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    await store.send(.binding(.set(\.composerText, "Which property leads?")))
    await store.send(.sendTapped)
    #expect(store.state.composerText.isEmpty)
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.messages.count == 2)
    #expect(store.state.isProcessing == false)
    let assistant = store.state.messages.last
    guard case .answer(let result, let narration, let sql, _)? = assistant?.body else {
      Issue.record("expected an answer message, got \(String(describing: assistant?.body))")
      return
    }
    #expect(result == answer)
    #expect(narration == "One property found.")
    #expect(sql == "SELECT name FROM properties")
    #expect(assistant?.traceSteps.isEmpty == false)
    // trace lines never contain SQL
    #expect(assistant?.traceSteps.allSatisfy { !$0.contains("SELECT") } == true)
    #expect(assistant?.devInfo?.originalQuestion == "Which property leads?")
    #expect(assistant?.devInfo?.standaloneQuestion == "Which property leads?")
  }

  @Test func duplicateSendWhileProcessingStartsOnlyOneTurn() async {
    let pipelineCalls = CallCounter()
    var initialState = ChatFeature.State()
    initialState.modelReadiness = .ready
    let store = TestStore(initialState: initialState) {
      ChatFeature()
    } withDependencies: {
      $0.queryPipeline = QueryPipeline { _, _ in
        pipelineCalls.increment()
        return AsyncStream { continuation in
          var telemetry = TurnTelemetry(originalQuestion: "Which property leads?")
          telemetry.terminalError = "test completion"
          continuation.yield(.turnFinished(
            outcome: .failed(message: "test completion"),
            telemetry: telemetry))
          continuation.finish()
        }
      }
      $0.historyClient = .noop()
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    await store.send(.binding(.set(\.composerText, "Which property leads?")))
    await store.send(.sendTapped)
    await store.send(.sendTapped)
    await store.finish()

    #expect(store.state.composerText.isEmpty)
    #expect(!store.state.isProcessing)
    #expect(store.state.messages.count == 2)
    #expect(pipelineCalls.count == 1)
  }

  @Test func submissionLatchCommitsOnlyAfterFocusSettles() async {
    var initialState = ChatFeature.State()
    initialState.modelReadiness = .ready
    let store = TestStore(initialState: initialState) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.historyClient = .noop()
    }
    store.exhaustivity = .off

    await store.send(.binding(.set(\.composerText, "question")))
    await store.send(.submissionRequested)
    #expect(store.state.isSubmissionPending)
    #expect(!store.state.isProcessing)

    await store.send(.submissionFocusSettled)
    #expect(!store.state.isSubmissionPending)
    #expect(store.state.isProcessing)
    #expect(store.state.composerText.isEmpty)
    await store.finish()
  }

  @Test func refocusCancelsPendingSubmissionWithoutWedge() async {
    var initialState = ChatFeature.State()
    initialState.conversationID = UUID(0)
    initialState.composerText = "question"
    initialState.modelReadiness = .ready
    let store = TestStore(initialState: initialState) {
      ChatFeature()
    }

    await store.send(.submissionRequested) {
      $0.isSubmissionPending = true
    }
    await store.send(.submissionRefocused) {
      $0.isSubmissionPending = false
    }
    await store.send(.submissionRequested) {
      $0.isSubmissionPending = true
    }
    #expect(store.state.composerText == "question")
  }

  @Test func readinessFailureCanRetryAndSubmissionIsGated() async {
    let attempts = LockIsolated(0)
    let pipeline = QueryPipeline(
      prepare: {
        let attempt = attempts.withValue {
          $0 += 1
          return $0
        }
        if attempt == 1 { throw ChatTestError.preparationFailed }
      },
      run: { _, _ in AsyncStream { $0.finish() } })
    var initialState = ChatFeature.State()
    initialState.composerText = "question"
    let store = TestStore(initialState: initialState) {
      ChatFeature()
    } withDependencies: {
      $0.queryPipeline = pipeline
      $0.historyClient = .noop()
    }
    store.exhaustivity = .off

    #expect(store.state.modelReadiness == .preparing)
    await store.send(.onAppear)
    await store.receive(\.modelPreparationFailed)
    guard case .failed = store.state.modelReadiness else {
      Issue.record("expected failed readiness")
      return
    }
    await store.send(.submissionRequested)
    #expect(!store.state.isSubmissionPending)
    #expect(store.state.composerText == "question")

    await store.send(.retryPreparation)
    await store.receive(\.modelPrepared)
    await store.finish()
    #expect(store.state.modelReadiness == .ready)
    #expect(attempts.value == 2)
  }

  @Test func emptySendIsIgnored() async {
    var initialState = ChatFeature.State()
    initialState.composerText = "  \n  "
    let store = TestStore(initialState: initialState) {
      ChatFeature()
    }

    await store.send(.sendTapped)

    #expect(store.state.composerText == "  \n  ")
    #expect(store.state.messages.isEmpty)
    #expect(!store.state.isProcessing)
  }

  @Test func conversationTurnsPairQuestionsWithAnswers() {
    let messages: IdentifiedArrayOf<ChatMessage> = [
      ChatMessage(id: UUID(0), role: .user, body: .text("q1"), createdAt: .distantPast),
      ChatMessage(
        id: UUID(1), role: .assistant,
        body: .answer(result: answer, narration: "a1", sql: "s", notice: nil), createdAt: .distantPast),
      ChatMessage(id: UUID(2), role: .user, body: .text("q2"), createdAt: .distantPast),
      ChatMessage(id: UUID(3), role: .assistant, body: .failure("boom"), createdAt: .distantPast),
    ]
    let turns = ChatFeature.conversationTurns(from: messages)
    #expect(turns == [ConversationTurn(question: "q1", answerSummary: "a1")])
  }

  @Test func fullTelemetryPersistsAndLegacyDeveloperInfoStillLoads()
    throws
  {
    let model = ModelReference(
      key: "test",
      repository: "test/model",
      revision: String(repeating: "a", count: 40))
    let request = SQLGenerationRequest(
      candidateID: CandidateID(rawValue: "initial"),
      role: .initial,
      model: model,
      question: "q",
      gcd: .on,
      temperature: 0,
      seed: nil)
    var candidate = CandidateTelemetry(request: request)
    candidate.sql = "SELECT 1"
    candidate.result = QueryResult(
      columns: ["n"],
      rows: [[.integer(1)]],
      elapsedMicroseconds: 77)
    candidate.resultDigest =
      CanonicalSQLResult(candidate.result!).digest
    candidate.selected = true
    var telemetry = TurnTelemetry(originalQuestion: "q")
    telemetry.candidates = [candidate]
    telemetry.selectedCandidateID = candidate.id
    telemetry.selectionReason = .initialSuccess
    telemetry.stageTimings.totalMicroseconds = 123

    let message = ChatMessage(
      id: UUID(0),
      role: .assistant,
      body: .answer(
        result: candidate.result!,
        narration: "one",
        sql: "SELECT 1",
        notice: nil),
      createdAt: Date(timeIntervalSince1970: 0),
      devInfo: telemetry)
    let encoded = try JSONEncoder().encode(message)
    let decoded = try JSONDecoder().decode(
      ChatMessage.self, from: encoded)
    #expect(decoded.devInfo == telemetry)
    #expect(decoded.devInfo?.candidates.first?.result?.rows == [
      [.integer(1)]
    ])

    var legacyObject =
      try #require(
        JSONSerialization.jsonObject(with: encoded)
          as? [String: Any])
    legacyObject["devInfo"] = [
      "standaloneQuestion": "old q",
      "tokensPerSecond": 12.0,
      "executionMilliseconds": 3.0,
      "repairAttempts": 0,
      "candidates": [],
    ]
    let legacyData = try JSONSerialization.data(
      withJSONObject: legacyObject)
    let legacy = try JSONDecoder().decode(
      ChatMessage.self, from: legacyData)
    #expect(legacy.body == message.body)
    #expect(legacy.devInfo == nil)
  }

  @Test func legacyMillisecondQueryResultDecodesToMicroseconds() throws {
    // Obtain the compiler's enum representation while preserving an old
    // timing key, rather than depending on a hand-authored SQLValue shape.
    let current = QueryResult(
      columns: ["n"],
      rows: [[.integer(1)]],
      elapsedMicroseconds: 2_500)
    var object =
      try #require(
        JSONSerialization.jsonObject(
          with: JSONEncoder().encode(current)) as? [String: Any])
    object.removeValue(forKey: "elapsedMicroseconds")
    object["elapsedMilliseconds"] = 2.5
    let decoded = try JSONDecoder().decode(
      QueryResult.self,
      from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.elapsedMicroseconds == 2_500)
  }

  @Test func legacyNoConsensusTelemetryMigratesToUnconfirmed() throws {
    var telemetry = TurnTelemetry(originalQuestion: "q")
    telemetry.schemaVersion = 1
    telemetry.voteOutcome = .noConsensus(
      anchorCandidateID: CandidateID(rawValue: "initial"),
      candidateCount: 3,
      reason: nil)
    telemetry.confidence = nil
    telemetry.noConsensusReason = nil

    let decoded = try JSONDecoder().decode(
      TurnTelemetry.self,
      from: JSONEncoder().encode(telemetry))
    #expect(decoded.confidence == .unconfirmed)
    #expect(decoded.noConsensusReason == .conflictingResults)
  }
}
