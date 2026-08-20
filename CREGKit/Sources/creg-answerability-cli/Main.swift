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
      let value = Int(arguments[flagIndex + 1]),
      value >= 0
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

    if let maxFalseAbstentions {
      let failures = score.shippingGateFailures(
        maxFalseAbstentions: maxFalseAbstentions)
      for failure in failures {
        FileHandle.standardError.write(
          Data("GATE FAILED: \(failure)\n".utf8))
      }
      if !failures.isEmpty { exit(1) }
    }
  }
}
