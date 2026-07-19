import ComposableArchitecture
import Foundation
import Testing

@testable import CREGEngine
@testable import CREGFeatures

private let answer = QueryResult(columns: ["name"], rows: [[.text("Sable Tower")]])

@MainActor
@Suite struct ChatFeatureTests {
  static func scriptedPipeline() -> QueryPipeline {
    QueryPipeline { question, _ in
      AsyncStream { continuation in
        continuation.yield(.turnStarted(question: question))
        continuation.yield(.gateStarted)
        continuation.yield(.gateFinished(.proceed))
        continuation.yield(.generationStarted(modelName: "test"))
        continuation.yield(.generationFinished(sql: "SELECT name FROM properties", tokensPerSecond: 42))
        continuation.yield(.executionStarted(sql: "SELECT name FROM properties"))
        continuation.yield(.executionFinished(rowCount: 1, elapsedMilliseconds: 3))
        continuation.yield(.narrationStarted)
        continuation.yield(.narrationFinished(narration: "One property found.", usedFM: false))
        continuation.yield(.turnFinished(.answered(
          result: answer, narration: "One property found.", sql: "SELECT name FROM properties")))
        continuation.finish()
      }
    }
  }

  @Test func sendProducesAnswerMessage() async {
    var initialState = ChatFeature.State()
    initialState.conversationID = UUID()
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
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.messages.count == 2)
    #expect(store.state.isProcessing == false)
    let assistant = store.state.messages.last
    guard case .answer(let result, let narration, let sql)? = assistant?.body else {
      Issue.record("expected an answer message, got \(String(describing: assistant?.body))")
      return
    }
    #expect(result == answer)
    #expect(narration == "One property found.")
    #expect(sql == "SELECT name FROM properties")
    #expect(assistant?.traceSteps.isEmpty == false)
    // trace lines never contain SQL
    #expect(assistant?.traceSteps.allSatisfy { !$0.contains("SELECT") } == true)
  }

  @Test func conversationTurnsPairQuestionsWithAnswers() {
    let messages: IdentifiedArrayOf<ChatMessage> = [
      ChatMessage(id: UUID(0), role: .user, body: .text("q1"), createdAt: .distantPast),
      ChatMessage(
        id: UUID(1), role: .assistant,
        body: .answer(result: answer, narration: "a1", sql: "s"), createdAt: .distantPast),
      ChatMessage(id: UUID(2), role: .user, body: .text("q2"), createdAt: .distantPast),
      ChatMessage(id: UUID(3), role: .assistant, body: .failure("boom"), createdAt: .distantPast),
    ]
    let turns = ChatFeature.conversationTurns(from: messages)
    #expect(turns == [ConversationTurn(question: "q1", answerSummary: "a1")])
  }
}
