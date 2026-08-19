import CREGCore
import Foundation

/// Offline answerability scorer (docs/eval.md "Answerability").
///
/// Usage: creg-answerability-cli <corpus.jsonl> <judgements.jsonl>
///        [--max-false-abstentions N]
///
/// Prints the deterministic confusion-matrix report. With
/// `--max-false-abstentions`, exits non-zero when the count exceeds the gate —
/// the provisional gate is 1 (see docs/eval.md for the recalibration
/// procedure), with `T2-21` correct as a hard requirement checked here too.
@main
struct AnswerabilityCLI {
  static func main() throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    var maxFalseAbstentions: Int?
    if let flagIndex = arguments.firstIndex(of: "--max-false-abstentions"),
      flagIndex + 1 < arguments.count,
      let value = Int(arguments[flagIndex + 1])
    {
      maxFalseAbstentions = value
      arguments.removeSubrange(flagIndex...(flagIndex + 1))
    }
    guard arguments.count == 2 else {
      FileHandle.standardError.write(
        Data(
          "usage: creg-answerability-cli <corpus.jsonl> <judgements.jsonl> [--max-false-abstentions N]\n"
            .utf8))
      exit(64)
    }
    let corpus = try AnswerabilityScorer.parseCorpus(
      jsonl: String(contentsOfFile: arguments[0], encoding: .utf8))
    let judgements = try AnswerabilityScorer.parseJudgements(
      jsonl: String(contentsOfFile: arguments[1], encoding: .utf8))
    let score = try AnswerabilityScorer.score(
      corpus: corpus, judgements: judgements)
    print(score.report())

    var failed = false
    if let maxFalseAbstentions,
      score.falseAbstentionIDs.count > maxFalseAbstentions
    {
      FileHandle.standardError.write(
        Data(
          "GATE FAILED: \(score.falseAbstentionIDs.count) false abstentions exceed the gate of \(maxFalseAbstentions)\n"
            .utf8))
      failed = true
    }
    // T2-21 is the keystone case (ADR 0010): semantically the
    // highest-vacancy-v1 Starter Query. Refusing it is always a gate failure.
    if maxFalseAbstentions != nil, score.falseAbstentionIDs.contains("T2-21") {
      FileHandle.standardError.write(
        Data("GATE FAILED: T2-21 was misclassified (hard gate)\n".utf8))
      failed = true
    }
    if failed { exit(1) }
  }
}
