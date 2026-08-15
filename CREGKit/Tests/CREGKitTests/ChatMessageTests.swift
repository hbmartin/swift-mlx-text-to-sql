import Foundation
import Testing

@testable import CREGFeatures

@Suite struct ChatMessageTests {
  @Test func nonResultBodiesHaveNoResultFingerprint() {
    let text = ChatMessage(
      id: UUID(), role: .user, body: .text("Question"), createdAt: Date())
    let clarification = ChatMessage(
      id: UUID(), role: .assistant, body: .clarification("Which fund?"),
      createdAt: Date())
    let failure = ChatMessage(
      id: UUID(), role: .assistant, body: .failure("Unable to answer"),
      createdAt: Date())

    #expect(text.resultFingerprint == nil)
    #expect(clarification.resultFingerprint == nil)
    #expect(failure.resultFingerprint == nil)
  }
}
