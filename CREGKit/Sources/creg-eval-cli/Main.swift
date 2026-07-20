import CREGEngine
import Foundation

/// Parity harness: re-scores a model on the gold set using the app's exact
/// production inference stack (MLX-Swift + MLXStructured grammar + the app's
/// prompts) so Python-harness winners are validated before selection.
/// See docs/adr/0003-hybrid-eval-harness.md.
///
/// Usage: creg-eval-cli --model <weights-dir> --db <creg.sqlite> --gold <gold.jsonl> [--out <results.json>]
@main
struct EvalCLI {
  struct GoldItem: Decodable {
    let id: String
    let tier: Int
    let question: String
    let standalone: String?
    let sql: String
    let expectedGateAction: String?
    let sqlRole: String?

    enum CodingKeys: String, CodingKey {
      case id, tier, question, standalone, sql
      case expectedGateAction = "expected_gate_action"
      case sqlRole = "sql_role"
    }
  }

  static func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--\(name)"), index + 1 < args.count else { return nil }
    return args[index + 1]
  }

  static func main() async {
    guard
      let modelPath = argument("model"),
      let dbPath = argument("db"),
      let goldPath = argument("gold")
    else {
      print("usage: creg-eval-cli --model <weights-dir> --db <creg.sqlite> --gold <gold.jsonl> [--out <results.json>]")
      exit(2)
    }

    do {
      let goldText = try String(contentsOfFile: goldPath, encoding: .utf8)
      let items = try goldText.split(separator: "\n")
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .map { try JSONDecoder().decode(GoldItem.self, from: Data($0.utf8)) }
      guard !items.isEmpty else {
        print("creg-eval-cli: gold set is empty at \(goldPath)")
        exit(2)
      }

      let db = try DatabaseClient.live(url: URL(fileURLWithPath: dbPath), rowCap: 10_000)
      let sqlGen = SQLGenClient.live(directory: URL(fileURLWithPath: modelPath))

      var results: [[String: Any]] = []
      var correct = 0
      var scored = 0
      var valid = 0
      var fallbackCorrect = 0
      var fallbackScored = 0
      for item in items {
        let question = item.standalone ?? item.question
        let start = ContinuousClock.now
        var predictedSQL = ""
        var ex = false
        var errorMessage: String?
        do {
          let generation = try await sqlGen.generate(question, nil, 0.1)
          predictedSQL = generation.sql
          let gold = try await db.execute(item.sql)
          do {
            let predicted = try await db.execute(predictedSQL)
            valid += 1
            ex = EXScore.matches(predicted, gold)
          } catch {
            errorMessage = "\(error)"
          }
        } catch {
          errorMessage = "generation: \(error)"
        }
        let isFallbackSQL = item.sqlRole == "best_guess_fallback"
        if isFallbackSQL {
          fallbackScored += 1
          if ex { fallbackCorrect += 1 }
        } else {
          scored += 1
          if ex { correct += 1 }
        }
        let duration = start.duration(to: .now).components
        let seconds =
          Double(duration.seconds) + Double(duration.attoseconds) / 1_000_000_000_000_000_000
        let reportedEX: Any = isFallbackSQL ? NSNull() : ex
        let fallbackEX: Any = isFallbackSQL ? ex : NSNull()
        results.append([
          "id": item.id, "tier": item.tier, "ex": reportedEX,
          "expected_gate_action": item.expectedGateAction ?? NSNull(),
          "sql_role": item.sqlRole ?? "primary", "fallback_ex": fallbackEX,
          "predicted_sql": predictedSQL, "error": errorMessage ?? NSNull(),
          "seconds": seconds,
        ])
        let status = isFallbackSQL ? "– fallback SQL" : (ex ? "✓" : "✗")
        print("[\(item.id)] \(status)\(errorMessage.map { " (\($0.prefix(60)))" } ?? "")")
      }

      let primaryEX: Any
      if scored > 0 {
        primaryEX = Double(correct) / Double(scored)
      } else {
        primaryEX = NSNull()
      }
      let fallbackSQLEx: Any
      if fallbackScored > 0 {
        fallbackSQLEx = Double(fallbackCorrect) / Double(fallbackScored)
      } else {
        fallbackSQLEx = NSNull()
      }
      let summary: [String: Any] = [
        "runtime": "swift-mlx",
        "model": modelPath,
        "n": items.count,
        "scored_n": scored,
        "fallback_sql_n": fallbackScored,
        "fallback_sql_ex": fallbackSQLEx,
        "ex": primaryEX,
        "valid_sql_rate": Double(valid) / Double(items.count),
      ]
      let payload: [String: Any] = ["summary": summary, "results": results]
      let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
      if let outPath = argument("out") {
        try data.write(to: URL(fileURLWithPath: outPath))
      }
      print(String(decoding: try JSONSerialization.data(
        withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    } catch {
      print("creg-eval-cli failed: \(error)")
      exit(1)
    }
  }
}
