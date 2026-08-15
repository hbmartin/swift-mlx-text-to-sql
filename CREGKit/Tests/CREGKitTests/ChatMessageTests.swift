import Foundation
import Testing

@testable import CREGEngine
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

  @Test func resultFingerprintPersistsWithLegacyDecodeFallback() throws {
    let result = QueryResult(
      columns: ["fund", "value"],
      rows: [[.text("Core"), .real(10)]])
    let message = ChatMessage(
      id: UUID(),
      role: .assistant,
      body: .answer(
        result: result,
        narration: "Core is worth $10.",
        sql: "SELECT fund, value FROM properties",
        notice: nil),
      createdAt: Date(timeIntervalSince1970: 1))
    let data = try JSONEncoder().encode(message)
    var object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["resultFingerprint"] as? String == message.resultFingerprint)
    #expect(
      try JSONDecoder().decode(ChatMessage.self, from: data).resultFingerprint
        == message.resultFingerprint)

    object.removeValue(forKey: "resultFingerprint")
    let legacy = try JSONSerialization.data(withJSONObject: object)
    #expect(
      try JSONDecoder().decode(ChatMessage.self, from: legacy).resultFingerprint
        == PreparedFollowUpIntegrity.fingerprint(result: result))
  }
}
