import Foundation
import Testing

@testable import CREGEngine
@testable import CREGFeatures

@Suite struct ChatTranscriptScrollTests {
  private let conversationA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  private let conversationB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
  private let result = QueryResult(
    columns: ["name"], rows: [[.text("Sable Tower")]])

  private func message(
    id: UInt8,
    role: ChatMessage.Role,
    body: ChatMessage.Body
  ) -> ChatMessage {
    ChatMessage(
      id: UUID(
        uuid: (
          0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, id
        )),
      role: role,
      body: body,
      createdAt: Date(timeIntervalSince1970: TimeInterval(id)))
  }

  @Test(arguments: [
    ChatMessage.Body.answer(
      result: QueryResult(columns: ["name"], rows: [[.text("Sable Tower")]]),
      narration: "One property found.",
      sql: "SELECT name FROM properties",
      notice: nil),
    .clarification("Which fund did you mean?"),
    .failure("I couldn't finish that answer."),
    .text("Stopped — ask again whenever you're ready."),
  ])
  func everyAssistantCompletionScrollsFromOlderContent(
    completion: ChatMessage.Body
  ) {
    let question = message(id: 1, role: .user, body: .text("Show properties"))
    let previous = ChatTranscriptSnapshot(
      conversationID: conversationA, messages: [question])
    let current = ChatTranscriptSnapshot(
      conversationID: conversationA,
      messages: [question, message(id: 2, role: .assistant, body: completion)])

    #expect(
      chatTranscriptScrollDecision(
        from: previous, to: current, isNearBottom: false)
        == .scrollToBottom)
  }

  @Test func completionFollowedByQueuedQuestionStillScrolls() {
    let firstQuestion = message(id: 1, role: .user, body: .text("Show properties"))
    let answer = message(
      id: 2,
      role: .assistant,
      body: .answer(
        result: result,
        narration: "One property found.",
        sql: "SELECT name FROM properties",
        notice: nil))
    let queuedQuestion = message(
      id: 3, role: .user, body: .text("What is its value?"))
    let previous = ChatTranscriptSnapshot(
      conversationID: conversationA, messages: [firstQuestion])
    let current = ChatTranscriptSnapshot(
      conversationID: conversationA,
      messages: [firstQuestion, answer, queuedQuestion])

    #expect(
      chatTranscriptScrollDecision(
        from: previous, to: current, isNearBottom: false)
        == .scrollToBottom)
  }

  @Test func userMessageWhileReadingOlderContentIncrementsUnseen() {
    let answer = message(
      id: 1, role: .assistant,
      body: .clarification("Which fund did you mean?"))
    let question = message(
      id: 2, role: .user, body: .text("The Indigo fund"))
    let previous = ChatTranscriptSnapshot(
      conversationID: conversationA, messages: [answer])
    let current = ChatTranscriptSnapshot(
      conversationID: conversationA, messages: [answer, question])

    #expect(
      chatTranscriptScrollDecision(
        from: previous, to: current, isNearBottom: false)
        == .incrementUnseen(by: 1))
  }

  @Test func userMessageNearBottomPreservesFollowBehavior() {
    let question = message(id: 1, role: .user, body: .text("Show properties"))
    let previous = ChatTranscriptSnapshot(
      conversationID: conversationA, messages: [])
    let current = ChatTranscriptSnapshot(
      conversationID: conversationA, messages: [question])

    #expect(
      chatTranscriptScrollDecision(
        from: previous, to: current, isNearBottom: true)
        == .scrollToBottom)
  }

  @Test(arguments: [true, false])
  func progressiveSuggestionArrivalFollowsOnlyNearTheBottom(
    isNearBottom: Bool
  ) {
    let answer = message(
      id: 1,
      role: .assistant,
      body: .answer(
        result: result,
        narration: "One property found.",
        sql: "SELECT name FROM properties",
        notice: nil))
    let previous = ChatTranscriptSnapshot(
      conversationID: conversationA,
      messages: [answer],
      suggestionCount: 1)
    let current = ChatTranscriptSnapshot(
      conversationID: conversationA,
      messages: [answer],
      suggestionCount: 2)

    #expect(
      chatTranscriptScrollDecision(
        from: previous, to: current, isNearBottom: isNearBottom)
        == (isNearBottom ? .scrollToBottom : .incrementUnseen(by: 1)))
  }

  @Test(arguments: [true, false])
  func submittingWhileSuggestionsRetireStillTracksTheNewMessage(
    isNearBottom: Bool
  ) {
    let answer = message(
      id: 1,
      role: .assistant,
      body: .answer(
        result: result,
        narration: "One property found.",
        sql: "SELECT name FROM properties",
        notice: nil))
    let question = message(
      id: 2, role: .user, body: .text("What is its value?"))
    let previous = ChatTranscriptSnapshot(
      conversationID: conversationA,
      messages: [answer],
      suggestionCount: 3)
    let current = ChatTranscriptSnapshot(
      conversationID: conversationA,
      messages: [answer, question],
      suggestionCount: 0)

    #expect(
      chatTranscriptScrollDecision(
        from: previous, to: current, isNearBottom: isNearBottom)
        == (isNearBottom ? .scrollToBottom : .incrementUnseen(by: 1)))
  }

  @Test func switchingConversationsIsNotACompletion() {
    let previous = ChatTranscriptSnapshot(
      conversationID: conversationA,
      messages: [message(id: 1, role: .user, body: .text("Old question"))])
    let current = ChatTranscriptSnapshot(
      conversationID: conversationB,
      messages: [
        message(id: 2, role: .user, body: .text("Another question")),
        message(id: 3, role: .assistant, body: .failure("Unable to answer")),
      ])

    #expect(
      chatTranscriptScrollDecision(
        from: previous, to: current, isNearBottom: false)
        == .none)
  }
}
