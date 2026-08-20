import Foundation

/// One labelled corpus row from `eval/gold/answerability.jsonl`.
///
/// `acceptableVerdicts` marks the few genuinely bucket-straddling questions;
/// everything else is scored strictly against `expectedVerdict`. There is no
/// gold SQL — answerability is judged, never executed.
public struct AnswerabilityItem: Sendable, Equatable, Codable {
  public var id: String
  public var question: String
  public var expectedVerdict: ScopeVerdict
  public var acceptableVerdicts: [ScopeVerdict]?
  public var note: String?

  public init(
    id: String,
    question: String,
    expectedVerdict: ScopeVerdict,
    acceptableVerdicts: [ScopeVerdict]? = nil,
    note: String? = nil
  ) {
    self.id = id
    self.question = question
    self.expectedVerdict = expectedVerdict
    self.acceptableVerdicts = acceptableVerdicts
    self.note = note
  }
}

/// One FM verdict captured on device for one corpus item.
public struct AnswerabilityJudgement: Sendable, Equatable, Codable {
  public var id: String
  public var verdict: ScopeVerdict
  public var missingSubject: String?

  public init(id: String, verdict: ScopeVerdict, missingSubject: String? = nil) {
    self.id = id
    self.verdict = verdict
    self.missingSubject = missingSubject
  }
}

/// A deterministic scoring of one capture against the corpus. Everything in
/// here reproduces byte-for-byte from a fixed input: iteration is over the
/// fixed `ScopeVerdict.allCases` order and id lists are sorted.
public struct AnswerabilityScore: Sendable, Equatable {
  /// `matrix[expected][actual]` — counts of judged items, primary label only.
  public var matrix: [ScopeVerdict: [ScopeVerdict: Int]]
  public var judgedCount: Int
  public var correctCount: Int
  /// `likelyAnswerableModelFailed` items judged as any not-covered bucket —
  /// the number that gates shipping scope diagnosis (docs/eval.md).
  public var falseAbstentionIDs: [String]
  public var answerableJudgedCount: Int
  /// Corpus items with no judgement; excluded from the matrix and the rate.
  public var missingIDs: [String]
  /// Judgement ids that match no corpus item.
  public var unknownIDs: [String]

  public var falseAbstentionRate: Double {
    guard answerableJudgedCount > 0 else { return 0 }
    return Double(falseAbstentionIDs.count) / Double(answerableJudgedCount)
  }

  /// The byte-stable report the run discipline records.
  public func report() -> String {
    var lines: [String] = []
    let verdicts = ScopeVerdict.allCases
    lines.append("answerability confusion matrix (rows: expected, columns: actual)")
    let header =
      ["expected \\ actual"] + verdicts.map(\.rawValue)
    lines.append(header.joined(separator: "\t"))
    for expected in verdicts {
      var row = [expected.rawValue]
      for actual in verdicts {
        row.append(String(matrix[expected]?[actual] ?? 0))
      }
      lines.append(row.joined(separator: "\t"))
    }
    lines.append("judged: \(judgedCount)")
    lines.append("correct: \(correctCount)")
    lines.append(
      "false abstentions: \(falseAbstentionIDs.count)/\(answerableJudgedCount)"
        + " [\(falseAbstentionIDs.joined(separator: ", "))]")
    lines.append(
      String(format: "false abstention rate: %.4f", falseAbstentionRate))
    lines.append("missing: \(missingIDs.count) [\(missingIDs.joined(separator: ", "))]")
    lines.append("unknown: \(unknownIDs.count) [\(unknownIDs.joined(separator: ", "))]")
    return lines.joined(separator: "\n")
  }
}

public enum AnswerabilityScorerError: Error, Equatable, Sendable {
  case malformedLine(Int)
  case duplicateID(String)
}

/// Pure, offline scorer for the answerability corpus. No FM, no database —
/// this runs identically on the dev Mac, in CI, and inside the debug capture.
public enum AnswerabilityScorer {
  public static func parseCorpus(jsonl: String) throws -> [AnswerabilityItem] {
    try parse(jsonl: jsonl)
  }

  public static func parseJudgements(
    jsonl: String
  ) throws -> [AnswerabilityJudgement] {
    try parse(jsonl: jsonl)
  }

  private static func parse<Row: Decodable>(jsonl: String) throws -> [Row] {
    let decoder = JSONDecoder()
    var rows: [Row] = []
    for (index, line) in jsonl.split(
      separator: "\n", omittingEmptySubsequences: true
    ).enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }
      guard
        let row = try? decoder.decode(Row.self, from: Data(trimmed.utf8))
      else {
        throw AnswerabilityScorerError.malformedLine(index + 1)
      }
      rows.append(row)
    }
    return rows
  }

  public static func score(
    corpus: [AnswerabilityItem],
    judgements: [AnswerabilityJudgement]
  ) throws -> AnswerabilityScore {
    var judged: [String: AnswerabilityJudgement] = [:]
    for judgement in judgements {
      guard judged.updateValue(judgement, forKey: judgement.id) == nil else {
        throw AnswerabilityScorerError.duplicateID(judgement.id)
      }
    }
    var corpusIDs = Set<String>()
    for item in corpus {
      guard corpusIDs.insert(item.id).inserted else {
        throw AnswerabilityScorerError.duplicateID(item.id)
      }
    }

    var matrix: [ScopeVerdict: [ScopeVerdict: Int]] = [:]
    var judgedCount = 0
    var correctCount = 0
    var falseAbstentionIDs: [String] = []
    var answerableJudgedCount = 0
    var missingIDs: [String] = []

    for item in corpus {
      guard let judgement = judged[item.id] else {
        missingIDs.append(item.id)
        continue
      }
      judgedCount += 1
      matrix[item.expectedVerdict, default: [:]][judgement.verdict, default: 0]
        += 1
      let accepted =
        judgement.verdict == item.expectedVerdict
        || item.acceptableVerdicts?.contains(judgement.verdict) == true
      if accepted { correctCount += 1 }
      if item.expectedVerdict == .likelyAnswerableModelFailed {
        answerableJudgedCount += 1
        if judgement.verdict != .likelyAnswerableModelFailed {
          falseAbstentionIDs.append(item.id)
        }
      }
    }

    let unknownIDs = judged.keys.filter { !corpusIDs.contains($0) }
    return AnswerabilityScore(
      matrix: matrix,
      judgedCount: judgedCount,
      correctCount: correctCount,
      falseAbstentionIDs: falseAbstentionIDs.sorted(),
      answerableJudgedCount: answerableJudgedCount,
      missingIDs: missingIDs.sorted(),
      unknownIDs: unknownIDs.sorted())
  }
}
