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

  @Test func failedTurnBodyRoundTripsReasonAndVerdict() throws {
    let message = ChatMessage(
      id: UUID(),
      role: .assistant,
      body: .failedTurn(
        reason: .generationExhausted,
        scopeVerdict: ScopeVerdictRecord(
          verdict: .inDomainButNotTracked,
          missingSubject: "tenant contacts")),
      createdAt: Date(timeIntervalSince1970: 1))
    let data = try JSONEncoder().encode(message)
    let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
    #expect(decoded.body == message.body)
    #expect(decoded.resultFingerprint == nil)
  }

  /// Histories written before the typed-reason change carry `.failure(String)`
  /// payloads; they must keep decoding and rendering forever.
  @Test func legacyStringFailureBodyStillDecodes() throws {
    let legacy = ChatMessage(
      id: UUID(),
      role: .assistant,
      body: .failure("I couldn't answer that one — try rephrasing the question."),
      createdAt: Date(timeIntervalSince1970: 1))
    let data = try JSONEncoder().encode(legacy)
    let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
    #expect(decoded.body == legacy.body)
    #expect(decoded.previewText.contains("try rephrasing"))
  }

  @Test func failedTurnPreviewTextUsesThePresentationMessage() {
    let message = ChatMessage(
      id: UUID(),
      role: .assistant,
      body: .failedTurn(reason: .timedOut(stage: "generation"), scopeVerdict: nil),
      createdAt: Date())
    #expect(message.previewText == "That answer took too long. Please try again.")
  }

  /// The debug capture judges the bundled corpus; it must be a byte-exact
  /// copy of eval/gold/answerability.jsonl or captures silently diverge from
  /// the scorer's corpus.
  @Test func bundledAnswerabilityCorpusMatchesEvalGold() throws {
    let bundled = try AnswerabilityCapture.corpusJSONL()
    let goldURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // CREGFeaturesTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // CREGKit
      .deletingLastPathComponent()  // repo root
      .appendingPathComponent("eval/gold/answerability.jsonl")
    let gold = try String(contentsOf: goldURL, encoding: .utf8)
    #expect(bundled == gold)
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
