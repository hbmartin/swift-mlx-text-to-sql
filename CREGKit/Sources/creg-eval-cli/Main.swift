import CREGEngine
import CryptoKit
import Foundation
import SQLite3

/// Full-gold Swift parity harness using the app's generation prompt,
/// MLX-Swift runtime, optional structured decoding, typed result identity, and
/// 10,000-row evaluation cap.
@main
struct EvalCLI {
  struct GoldItem: Decodable {
    let id: String
    let tier: Int
    let question: String
    let standalone: String?
    let sql: String
  }

  struct ItemResult: Encodable {
    var id: String
    var tier: Int
    var candidateID: CandidateID
    var model: ModelReference
    var gcd: GCDMode
    var temperature: Double
    var seed: UInt64
    var predictedSQL: String
    var goldSQL: String
    var validSQL: Bool
    var ex: Bool
    var generation: SQLGeneration?
    var predictedResult: QueryResult?
    var goldResult: QueryResult?
    var predictedDigest: String?
    var goldDigest: String?
    var error: String?
    var totalMicroseconds: Int64
  }

  struct Summary: Encodable {
    var runtime: String
    var model: ModelReference
    var gcd: GCDMode
    var temperature: Double
    var seed: UInt64
    var topP: Double
    var topK: Int
    var maxTokens: Int
    var rowCap: Int
    var itemCount: Int
    var correctCount: Int
    var validSQLCount: Int
    var ex: Double
    var validSQLRate: Double
  }

  struct Output: Encodable {
    var schemaVersion: Int
    var runID: String
    var startedAt: String
    var completedAt: String
    var command: [String]
    var provenance: Provenance
    var summary: Summary
    var results: [ItemResult]
  }

  struct FileEvidence: Encodable {
    var path: String
    var size: Int
    var sha256: String
  }

  struct Provenance: Encodable {
    var gitCommit: String?
    var gitDirty: Bool?
    var osVersion: String
    var physicalMemoryBytes: UInt64
    var processorCount: Int
    var swiftVersion: String?
    var sqliteVersion: String
    var database: FileEvidence
    var gold: FileEvidence
    var modelArtifactLock: FileEvidence?
    var modelDirectorySHA256: String?
    var grammarSHA256: String
    var schemaPromptSHA256: String
    var systemPromptSHA256: String
    var packageLock: FileEvidence?
  }

  static func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard
      let index = args.firstIndex(of: "--\(name)"),
      index + 1 < args.count
    else { return nil }
    return args[index + 1]
  }

  static func usage() -> Never {
    print(
      """
      usage: creg-eval-cli \
        --model <weights-dir> --model-key <manifest-key> \
        --repository <repo> --revision <40-char-commit> \
        --db <creg.sqlite> --gold <gold.jsonl> \
        --gcd <on|off> --temperature <0...1> --seed <uint64> \
        --out <new-results.json>
      """)
    exit(2)
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }.joined()
  }

  static func fileEvidence(_ path: String) throws -> FileEvidence {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let data = try Data(contentsOf: url)
    return FileEvidence(
      path: url.path,
      size: data.count,
      sha256: sha256(data))
  }

  static func commandOutput(_ command: [String]) -> String? {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = command
    process.standardOutput = output
    process.standardError = Pipe()
    do {
      try process.run()
      // Drain the pipe before waiting so output larger than the pipe
      // buffer cannot deadlock the child.
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return nil }
      return String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      return nil
    }
  }

  static func main() async {
    guard
      let modelPath = argument("model"),
      let modelKey = argument("model-key"),
      let repository = argument("repository"),
      let revision = argument("revision"),
      let dbPath = argument("db"),
      let goldPath = argument("gold"),
      let gcdRaw = argument("gcd"),
      let gcd = GCDMode(rawValue: gcdRaw),
      let temperatureRaw = argument("temperature"),
      let temperature = Double(temperatureRaw),
      (0...1).contains(temperature),
      let seedRaw = argument("seed"),
      let seed = UInt64(seedRaw),
      let outPath = argument("out")
    else { usage() }

    let outURL = URL(fileURLWithPath: outPath)
    guard !FileManager.default.fileExists(atPath: outURL.path) else {
      print("refusing to overwrite immutable output: \(outURL.path)")
      exit(2)
    }
    guard revision.count == 40, revision.allSatisfy(\.isHexDigit)
    else {
      print("--revision must be a full 40-character hexadecimal commit")
      exit(2)
    }

    do {
      let startedAt = ISO8601DateFormatter().string(from: Date())
      let goldText = try String(
        contentsOfFile: goldPath, encoding: .utf8)
      let items = try goldText.split(separator: "\n")
        .filter {
          !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        .map {
          try JSONDecoder().decode(
            GoldItem.self, from: Data($0.utf8))
        }

      let model = ModelReference(
        key: modelKey,
        repository: repository,
        revision: revision)
      let db = try DatabaseClient.live(
        url: URL(fileURLWithPath: dbPath), rowCap: 10_000)
      let sqlGen = SQLGenClient.live(
        directory: URL(fileURLWithPath: modelPath))
      let grammar = try SQLGenClient.grammarEBNF()
      let schema = try SQLGenClient.schemaPrompt()
      let systemPrompt = SQLGenClient.systemPrompt(schema: schema)
      let artifactLockPath = URL(fileURLWithPath: modelPath)
        .appendingPathComponent(".creg-artifact.json").path
      let artifactLock = try? fileEvidence(artifactLockPath)
      let artifactDirectorySHA256: String? = {
        guard
          let data = try? Data(contentsOf: URL(fileURLWithPath: artifactLockPath)),
          let document = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        else { return nil }
        return document["directory_sha256"] as? String
      }()
      let packageLockPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Package.resolved").path
      let gitCommit = commandOutput(["git", "rev-parse", "HEAD"])
      let gitStatus = commandOutput(["git", "status", "--porcelain"])
      let provenance = Provenance(
        gitCommit: gitCommit,
        gitDirty: gitStatus.map { !$0.isEmpty },
        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
        processorCount: ProcessInfo.processInfo.processorCount,
        swiftVersion: commandOutput(["swift", "--version"]),
        sqliteVersion: String(cString: sqlite3_libversion()),
        database: try fileEvidence(dbPath),
        gold: try fileEvidence(goldPath),
        modelArtifactLock: artifactLock,
        modelDirectorySHA256: artifactDirectorySHA256,
        grammarSHA256: sha256(Data(grammar.utf8)),
        schemaPromptSHA256: sha256(Data(schema.utf8)),
        systemPromptSHA256: sha256(Data(systemPrompt.utf8)),
        packageLock: try? fileEvidence(packageLockPath))

      var results: [ItemResult] = []
      var correct = 0
      var valid = 0
      for (index, item) in items.enumerated() {
        let question = item.standalone ?? item.question
        let itemSeed = seed &* 1_000_000 &+ UInt64(index)
        let candidateID = CandidateID(rawValue: "item-\(item.id)")
        let request = SQLGenerationRequest(
          candidateID: candidateID,
          role: .initial,
          model: model,
          question: question,
          gcd: gcd,
          temperature: temperature,
          seed: itemSeed,
          maxTokens: 512)
        let started = ContinuousClock.now
        var row = ItemResult(
          id: item.id,
          tier: item.tier,
          candidateID: candidateID,
          model: model,
          gcd: gcd,
          temperature: temperature,
          seed: itemSeed,
          predictedSQL: "",
          goldSQL: item.sql,
          validSQL: false,
          ex: false,
          totalMicroseconds: 0)
        var generatedSQL: String?
        do {
          let generation = try await sqlGen.generate(request)
          row.generation = generation
          row.predictedSQL = generation.sql
          generatedSQL = generation.sql
        } catch {
          row.error = "generation: \(error)"
        }
        if let generatedSQL {
          do {
            let gold = try await db.execute(item.sql)
            row.goldResult = gold
            if !gold.isTruncated {
              row.goldDigest = CanonicalSQLResult(gold).digest
            }
            do {
              let predicted = try await db.execute(generatedSQL)
              valid += 1
              row.validSQL = true
              row.predictedResult = predicted
              if !predicted.isTruncated {
                row.predictedDigest =
                  CanonicalSQLResult(predicted).digest
              }
              row.ex = EXScore.matches(predicted, gold)
            } catch {
              row.error = String(describing: error)
            }
          } catch {
            // A failing gold query is a harness defect, not a prediction
            // failure; label it so it is never read as generation drift.
            row.error = "gold: \(error)"
          }
        }
        if row.ex { correct += 1 }
        row.totalMicroseconds =
          started.duration(to: .now).microseconds
        results.append(row)
        print(
          "[\(item.id)] \(row.ex ? "✓" : "✗")"
            + (row.error.map { " (\($0.prefix(60)))" } ?? ""))
      }

      let summary = Summary(
        runtime: "swift-mlx",
        model: model,
        gcd: gcd,
        temperature: temperature,
        seed: seed,
        topP: 1,
        topK: 0,
        maxTokens: 512,
        rowCap: 10_000,
        itemCount: items.count,
        correctCount: correct,
        validSQLCount: valid,
        ex: Double(correct) / Double(items.count),
        validSQLRate: Double(valid) / Double(items.count))
      let payload = Output(
        schemaVersion: 2,
        runID:
          "swift-parity-\(modelKey)-gcd-\(gcd.rawValue)-t-\(temperature)-s-\(seed)",
        startedAt: startedAt,
        completedAt: ISO8601DateFormatter().string(from: Date()),
        command: CommandLine.arguments,
        provenance: provenance,
        summary: summary,
        results: results)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [
        .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
      ]
      try FileManager.default.createDirectory(
        at: outURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      try encoder.encode(payload).write(
        to: outURL, options: .withoutOverwriting)
      print(String(decoding: try encoder.encode(summary), as: UTF8.self))
    } catch {
      print("creg-eval-cli failed: \(error)")
      exit(1)
    }
  }
}
