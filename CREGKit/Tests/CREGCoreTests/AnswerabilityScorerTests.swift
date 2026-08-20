import Foundation
import Testing

@testable import CREGCore

@Suite struct AnswerabilityScorerTests {
  private static let corpusJSONL = """
    {"id": "OR-01", "question": "Weather?", "expectedVerdict": "outside_real_estate"}
    {"id": "NT-01", "question": "Property managers?", "expectedVerdict": "in_domain_but_not_tracked"}
    {"id": "NS-01", "question": "Next quarter occupancy?", "expectedVerdict": "needs_data_not_in_snapshot", "acceptableVerdicts": ["outside_real_estate"]}
    {"id": "T2-21", "question": "Highest vacancy right now?", "expectedVerdict": "likely_answerable_model_failed"}
    {"id": "T1-02", "question": "Technology tenants?", "expectedVerdict": "likely_answerable_model_failed"}
    {"id": "T1-06", "question": "Average fixed rate?", "expectedVerdict": "likely_answerable_model_failed"}
    """

  private static let judgementsJSONL = """
    {"id": "OR-01", "verdict": "outside_real_estate"}
    {"id": "NT-01", "verdict": "in_domain_but_not_tracked", "missingSubject": "property managers"}
    {"id": "NS-01", "verdict": "outside_real_estate"}
    {"id": "T2-21", "verdict": "likely_answerable_model_failed"}
    {"id": "T1-02", "verdict": "in_domain_but_not_tracked"}
    {"id": "GHOST", "verdict": "outside_real_estate"}
    """

  @Test func scoresTheHandLabelledFixture() throws {
    let corpus = try AnswerabilityScorer.parseCorpus(jsonl: Self.corpusJSONL)
    let judgements = try AnswerabilityScorer.parseJudgements(
      jsonl: Self.judgementsJSONL)
    let score = try AnswerabilityScorer.score(
      corpus: corpus, judgements: judgements)

    #expect(score.judgedCount == 5)
    // OR-01, NT-01, T2-21 exact; NS-01 via acceptableVerdicts.
    #expect(score.correctCount == 4)
    #expect(score.falseAbstentionIDs == ["T1-02"])
    #expect(score.answerableJudgedCount == 2)
    #expect(abs(score.falseAbstentionRate - 0.5) < 0.0001)
    #expect(score.missingIDs == ["T1-06"])
    #expect(score.unknownIDs == ["GHOST"])
    #expect(
      score.matrix[.likelyAnswerableModelFailed]?[.inDomainButNotTracked] == 1)
    #expect(
      score.matrix[.likelyAnswerableModelFailed]?[.likelyAnswerableModelFailed]
        == 1)
    #expect(score.matrix[.needsDataNotInSnapshot]?[.outsideRealEstate] == 1)
  }

  /// The report is the artifact the run discipline records — it must
  /// reproduce byte-for-byte from a fixed input.
  @Test func reportIsByteStable() throws {
    let corpus = try AnswerabilityScorer.parseCorpus(jsonl: Self.corpusJSONL)
    let judgements = try AnswerabilityScorer.parseJudgements(
      jsonl: Self.judgementsJSONL)
    let first = try AnswerabilityScorer.score(
      corpus: corpus, judgements: judgements
    ).report()
    let second = try AnswerabilityScorer.score(
      corpus: corpus, judgements: judgements.shuffled()
    ).report()
    #expect(first == second)
    #expect(first.contains("false abstentions: 1/2 [T1-02]"))
    #expect(first.contains("false abstention rate: 0.5000"))
    #expect(first.contains("missing: 1 [T1-06]"))
    #expect(first.contains("unknown: 1 [GHOST]"))
  }

  @Test func rejectsDuplicateAndMalformedRows() throws {
    #expect(throws: AnswerabilityScorerError.malformedLine(1)) {
      _ = try AnswerabilityScorer.parseCorpus(jsonl: "{not json}")
    }
    #expect(throws: AnswerabilityScorerError.malformedLine(3)) {
      _ = try AnswerabilityScorer.parseCorpus(
        jsonl: "\n  \n{still not json}\n")
    }
    let corpus = try AnswerabilityScorer.parseCorpus(jsonl: Self.corpusJSONL)
    #expect(throws: AnswerabilityScorerError.duplicateID("OR-01")) {
      _ = try AnswerabilityScorer.score(
        corpus: corpus,
        judgements: [
          AnswerabilityJudgement(id: "OR-01", verdict: .outsideRealEstate),
          AnswerabilityJudgement(id: "OR-01", verdict: .outsideRealEstate),
        ])
    }
  }

  @Test func shippingGateRequiresACompleteCorpusExactCapture() throws {
    let corpus = try AnswerabilityScorer.parseCorpus(jsonl: Self.corpusJSONL)
    let complete = corpus.map {
      AnswerabilityJudgement(id: $0.id, verdict: $0.expectedVerdict)
    }
    let passing = try AnswerabilityScorer.score(
      corpus: corpus,
      judgements: complete)
    #expect(passing.shippingGateFailures(maxFalseAbstentions: 1).isEmpty)

    let withoutKeystone = try AnswerabilityScorer.score(
      corpus: corpus,
      judgements: complete.filter { $0.id != "T2-21" })
    let missingFailures = withoutKeystone.shippingGateFailures(
      maxFalseAbstentions: 1)
    #expect(missingFailures.contains { $0.contains("judgements are missing") })
    #expect(missingFailures.contains("T2-21 is missing (hard gate)"))

    let withUnknown = try AnswerabilityScorer.score(
      corpus: corpus,
      judgements: complete + [
        AnswerabilityJudgement(
          id: "UNKNOWN", verdict: .likelyAnswerableModelFailed)
      ])
    #expect(
      withUnknown.shippingGateFailures(maxFalseAbstentions: 1)
        .contains { $0.contains("unknown judgement ids") })
  }

  /// The checked-in corpus itself: parses, holds exactly the 23 recovered
  /// real failures (T2-21 among them), and keeps unique ids.
  @Test func checkedInCorpusIsWellFormed() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // CREGCoreTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // CREGKit
      .deletingLastPathComponent()  // repo root
      .appendingPathComponent("eval/gold/answerability.jsonl")
    let corpus = try AnswerabilityScorer.parseCorpus(
      jsonl: String(contentsOf: url, encoding: .utf8))
    #expect(corpus.count == 87)
    let ids = Set(corpus.map(\.id))
    #expect(ids.count == corpus.count)
    let answerable = corpus.filter {
      $0.expectedVerdict == .likelyAnswerableModelFailed
    }
    #expect(answerable.count == 23)
    #expect(answerable.contains { $0.id == "T2-21" })
    #expect(
      answerable.first { $0.id == "MT-60" }?.question
        == "Which tenants on active leases expiring in the next 12 months have a renewal option?")
    // Answerable items are recovered gold questions and never carry
    // acceptable alternates — a refusal on one is always a false abstention.
    #expect(answerable.allSatisfy { $0.acceptableVerdicts == nil })
  }
}
