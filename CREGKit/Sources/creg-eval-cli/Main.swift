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

  struct TrainingConversation: Decodable {
    struct Message: Decodable {
      let role: String
      let content: String
    }

    let messages: [Message]
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
    var primarySQL: String? = nil
    var primaryValidSQL: Bool? = nil
    var primaryGeneration: SQLGeneration? = nil
    var primaryError: String? = nil
    var fallbackUsed: Bool? = nil
    var fallbackGeneration: SQLGeneration? = nil
    var fallbackMicroseconds: Int64? = nil
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
    var fallbackModel: ModelReference? = nil
    var fallbackCount: Int? = nil
    var primaryValidSQLCount: Int? = nil
    var primaryPreparationMicroseconds: Int64? = nil
    var fallbackPreparationMicroseconds: Int64? = nil
    var residentBytesAfterPrimaryPreparation: UInt64? = nil
    var residentBytesAfterFallbackPreparation: UInt64? = nil
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
        [--fallback-model <weights-dir> --fallback-model-key <manifest-key> \
         --fallback-repository <repo> --fallback-revision <40-char-commit>] \
        --db <creg.sqlite> --gold <gold.jsonl> \
        --gcd <on|off> --temperature <0...1> --seed <uint64> \
        [--max-tokens <positive-int>] [--max-items <positive-int>] \
        [--kv-bits <4|8>] [--wired-memory <true|false>] \
        [--direct-prompt-suffix <true|false>] \
        [--compiled-qwen2-mlp-fusion <true|false>] \
        [--compiled-qwen2-qkv-verification-fusion <true|false>] \
        [--verification-mlp-skip-layers <comma-separated-indices>] \
        [--verification-mlp-long-batch-extra-skip-layers \
         <comma-separated-indices>] \
        [--verification-mlp-confidence-skip \
         <layer,target-input-length,minimum-support>] \
        [--verification-mlp-additional-confidence-skip \
         <layer,target-input-length,minimum-support>] \
        [--question-aware-output-head <true|false>] \
        [--compact-question-aware-output-head <true|false>] \
        [--production-ngram <true|false>] \
        [--ngram-draft-corpus <training.jsonl> \
         --ngram-draft-tokens <positive-int> \
         --ngram-serial-prefix-tokens <nonnegative-int> \
         --ngram-adaptive-min-support <positive-int>] \
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
    // These provenance probes intentionally ignore stderr. Sending it to the
    // null device avoids a second bounded pipe that could block the child.
    process.standardError = FileHandle.nullDevice
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

  static func residentMemoryBytes() -> UInt64? {
    guard
      let output = commandOutput([
        "ps", "-o", "rss=", "-p",
        String(ProcessInfo.processInfo.processIdentifier),
      ]),
      let kibibytes = UInt64(
        output.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return nil }
    return kibibytes * 1_024
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

    let maxTokens: Int
    if let raw = argument("max-tokens") {
      guard let value = Int(raw), value > 0 else { usage() }
      maxTokens = value
    } else {
      maxTokens = 512
    }
    let maxItems: Int?
    if let raw = argument("max-items") {
      guard let value = Int(raw), value > 0 else { usage() }
      maxItems = value
    } else {
      maxItems = nil
    }
    let kvBits: Int?
    if let raw = argument("kv-bits") {
      guard let value = Int(raw), value == 4 || value == 8 else { usage() }
      kvBits = value
    } else {
      kvBits = nil
    }
    let useWiredMemory: Bool
    if let raw = argument("wired-memory") {
      switch raw {
      case "true": useWiredMemory = true
      case "false": useWiredMemory = false
      default: usage()
      }
    } else {
      useWiredMemory = false
    }
    let directPromptSuffix: Bool
    if let raw = argument("direct-prompt-suffix") {
      switch raw {
      case "true": directPromptSuffix = true
      case "false": directPromptSuffix = false
      default: usage()
      }
    } else {
      directPromptSuffix = true
    }
    let useProductionNGram: Bool
    if let raw = argument("production-ngram") {
      switch raw {
      case "true": useProductionNGram = true
      case "false": useProductionNGram = false
      default: usage()
      }
    } else {
      useProductionNGram = false
    }
    let compiledQwen2MLPFusion: Bool
    if let raw = argument("compiled-qwen2-mlp-fusion") {
      switch raw {
      case "true": compiledQwen2MLPFusion = true
      case "false": compiledQwen2MLPFusion = false
      default: usage()
      }
    } else {
      compiledQwen2MLPFusion = false
    }
    let compiledQwen2QKVVerificationFusion: Bool
    if let raw = argument("compiled-qwen2-qkv-verification-fusion") {
      switch raw {
      case "true": compiledQwen2QKVVerificationFusion = true
      case "false": compiledQwen2QKVVerificationFusion = false
      default: usage()
      }
    } else {
      compiledQwen2QKVVerificationFusion = false
    }
    guard !compiledQwen2QKVVerificationFusion || compiledQwen2MLPFusion
    else { usage() }
    let verificationMLPSkipLayers: [Int]
    if let raw = argument("verification-mlp-skip-layers") {
      let components = raw.split(
        separator: ",", omittingEmptySubsequences: false)
      let parsed = components.compactMap { Int($0) }
      guard !components.isEmpty,
        parsed.count == components.count,
        parsed.allSatisfy({ $0 >= 0 }),
        Set(parsed).count == parsed.count,
        compiledQwen2MLPFusion
      else { usage() }
      verificationMLPSkipLayers = parsed.sorted()
    } else {
      verificationMLPSkipLayers = []
    }
    let verificationMLPLongBatchExtraSkipLayers: [Int]
    if let raw = argument(
      "verification-mlp-long-batch-extra-skip-layers")
    {
      let components = raw.split(
        separator: ",", omittingEmptySubsequences: false)
      let parsed = components.compactMap { Int($0) }
      guard !components.isEmpty,
        parsed.count == components.count,
        parsed.allSatisfy({ $0 >= 0 }),
        Set(parsed).count == parsed.count,
        compiledQwen2MLPFusion
      else { usage() }
      verificationMLPLongBatchExtraSkipLayers = parsed.sorted()
    } else {
      verificationMLPLongBatchExtraSkipLayers = []
    }
    let verificationMLPConfidenceSkip:
      VerificationMLPConfidenceSkipPolicy?
    if let raw = argument("verification-mlp-confidence-skip") {
      let components = raw.split(
        separator: ",", omittingEmptySubsequences: false)
      let parsed = components.compactMap { Int($0) }
      guard parsed.count == 3,
        parsed.count == components.count,
        parsed[0] >= 0,
        (2...4).contains(parsed[1]),
        parsed[2] > 0,
        compiledQwen2MLPFusion,
        useProductionNGram
      else { usage() }
      verificationMLPConfidenceSkip = VerificationMLPConfidenceSkipPolicy(
        layer: parsed[0],
        targetInputLength: parsed[1],
        minimumSupport: parsed[2],
        requiresUnanimity: true)
    } else {
      verificationMLPConfidenceSkip = nil
    }
    let verificationMLPAdditionalConfidenceSkips:
      [VerificationMLPConfidenceSkipPolicy]
    if let raw = argument("verification-mlp-additional-confidence-skip") {
      let components = raw.split(
        separator: ",", omittingEmptySubsequences: false)
      let parsed = components.compactMap { Int($0) }
      guard parsed.count == 3,
        parsed.count == components.count,
        parsed[0] >= 0,
        (2...4).contains(parsed[1]),
        parsed[2] > 0,
        compiledQwen2MLPFusion,
        useProductionNGram
      else { usage() }
      verificationMLPAdditionalConfidenceSkips = [
        VerificationMLPConfidenceSkipPolicy(
          layer: parsed[0],
          targetInputLength: parsed[1],
          minimumSupport: parsed[2],
          requiresUnanimity: true)
      ]
    } else {
      verificationMLPAdditionalConfidenceSkips = []
    }
    let questionAwareOutputHead: Bool
    if let raw = argument("question-aware-output-head") {
      switch raw {
      case "true": questionAwareOutputHead = true
      case "false": questionAwareOutputHead = false
      default: usage()
      }
    } else {
      questionAwareOutputHead = false
    }
    let compactQuestionAwareOutputHead: Bool
    if let raw = argument("compact-question-aware-output-head") {
      switch raw {
      case "true": compactQuestionAwareOutputHead = true
      case "false": compactQuestionAwareOutputHead = false
      default: usage()
      }
    } else {
      compactQuestionAwareOutputHead = false
    }
    guard !compactQuestionAwareOutputHead
      || (questionAwareOutputHead && useProductionNGram)
    else { usage() }
    let ngramDraftArguments = (
      corpusPath: argument("ngram-draft-corpus"),
      tokenCount: argument("ngram-draft-tokens"))
    let ngramDraft: (corpusPath: String, tokenCount: Int)?
    switch ngramDraftArguments {
    case let (corpusPath?, rawTokenCount?):
      guard let tokenCount = Int(rawTokenCount), tokenCount > 0 else {
        usage()
      }
      ngramDraft = (corpusPath, tokenCount)
    case (nil, nil):
      ngramDraft = nil
    default:
      print("--ngram-draft-corpus and --ngram-draft-tokens are required together")
      exit(2)
    }
    guard !useProductionNGram || ngramDraft == nil else {
      print("--production-ngram cannot be combined with --ngram-draft-*")
      exit(2)
    }
    let ngramSerialPrefixTokens: Int
    if let raw = argument("ngram-serial-prefix-tokens") {
      guard let value = Int(raw), value >= 0, ngramDraft != nil else {
        usage()
      }
      ngramSerialPrefixTokens = value
    } else {
      ngramSerialPrefixTokens = 0
    }
    let ngramAdaptiveMinimumSupport: Int
    if let raw = argument("ngram-adaptive-min-support") {
      guard let value = Int(raw), value > 0,
        (ngramDraft?.tokenCount ?? 0) >= 2
      else { usage() }
      ngramAdaptiveMinimumSupport = value
    } else {
      ngramAdaptiveMinimumSupport = 0
    }
    let fallbackArguments = (
      modelPath: argument("fallback-model"),
      modelKey: argument("fallback-model-key"),
      repository: argument("fallback-repository"),
      revision: argument("fallback-revision"))
    let fallback: (
      modelPath: String, model: ModelReference
    )?
    switch fallbackArguments {
    case let (modelPath?, modelKey?, repository?, revision?):
      guard revision.count == 40, revision.allSatisfy(\.isHexDigit)
      else {
        print("--fallback-revision must be a full 40-character hexadecimal commit")
        exit(2)
      }
      fallback = (
        modelPath,
        ModelReference(
          key: modelKey,
          repository: repository,
          revision: revision))
    case (nil, nil, nil, nil):
      fallback = nil
    default:
      print("all four --fallback-* arguments are required together")
      exit(2)
    }

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
      var items = try goldText.split(separator: "\n")
        .filter {
          !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        .map {
          try JSONDecoder().decode(
            GoldItem.self, from: Data($0.utf8))
        }
      if let maxItems {
        items = Array(items.prefix(maxItems))
      }
      let ngramDraftCorpus: [String]
      if let ngramDraft {
        let text = try String(
          contentsOfFile: ngramDraft.corpusPath,
          encoding: .utf8)
        ngramDraftCorpus = try text.split(separator: "\n")
          .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
          .compactMap {
            let conversation = try JSONDecoder().decode(
              TrainingConversation.self,
              from: Data($0.utf8))
            return conversation.messages.first { $0.role == "assistant" }?.content
          }
      } else {
        ngramDraftCorpus = []
      }

      let model = ModelReference(
        key: modelKey,
        repository: repository,
        revision: revision)
      let db = try DatabaseClient.live(
        url: URL(fileURLWithPath: dbPath), rowCap: 10_000)
      let sqlGen = SQLGenClient.live(
        directory: URL(fileURLWithPath: modelPath),
        experimentalKVBits: kvBits,
        useWiredMemory: useWiredMemory,
        useDirectPromptSuffix: directPromptSuffix,
        compiledQwen2MLPFusion: compiledQwen2MLPFusion,
        compiledQwen2QKVVerificationFusion:
          compiledQwen2QKVVerificationFusion,
        verificationMLPSkipLayers: verificationMLPSkipLayers,
        verificationMLPLongBatchExtraSkipLayers:
          verificationMLPLongBatchExtraSkipLayers,
        verificationMLPConfidenceSkip: verificationMLPConfidenceSkip,
        verificationMLPAdditionalConfidenceSkips:
          verificationMLPAdditionalConfidenceSkips,
        questionAwareOutputHead: questionAwareOutputHead,
        compactQuestionAwareOutputHead: compactQuestionAwareOutputHead,
        productionNGramSpeculation:
          useProductionNGram ? .supported : nil,
        experimentalNGramDraftCorpus: ngramDraftCorpus,
        experimentalNGramDraftTokens: ngramDraft?.tokenCount ?? 0,
        experimentalNGramSerialPrefixTokens: ngramSerialPrefixTokens,
        experimentalNGramAdaptiveDraftMinimumSupport:
          ngramAdaptiveMinimumSupport)
      // Match the app lifecycle: load the model and prefill its invariant
      // schema/system prompt before measuring individual queries.
      let primaryPreparationStarted = ContinuousClock.now
      try await sqlGen.prepare()
      let primaryPreparationMicroseconds =
        primaryPreparationStarted.duration(to: .now).microseconds
      let residentBytesAfterPrimaryPreparation = residentMemoryBytes()
      let fallbackSQLGen = fallback.map {
        SQLGenClient.live(
          directory: URL(fileURLWithPath: $0.modelPath),
          experimentalKVBits: kvBits,
          useWiredMemory: useWiredMemory,
          useDirectPromptSuffix: directPromptSuffix,
          compiledQwen2MLPFusion: compiledQwen2MLPFusion,
          compiledQwen2QKVVerificationFusion:
            compiledQwen2QKVVerificationFusion,
          verificationMLPSkipLayers: verificationMLPSkipLayers,
          verificationMLPLongBatchExtraSkipLayers:
            verificationMLPLongBatchExtraSkipLayers,
          verificationMLPConfidenceSkip: verificationMLPConfidenceSkip,
          verificationMLPAdditionalConfidenceSkips:
            verificationMLPAdditionalConfidenceSkips,
          questionAwareOutputHead: questionAwareOutputHead,
          compactQuestionAwareOutputHead: compactQuestionAwareOutputHead,
          productionNGramSpeculation:
            useProductionNGram ? .supported : nil,
          experimentalNGramDraftCorpus: ngramDraftCorpus,
          experimentalNGramDraftTokens: ngramDraft?.tokenCount ?? 0,
          experimentalNGramSerialPrefixTokens: ngramSerialPrefixTokens,
          experimentalNGramAdaptiveDraftMinimumSupport:
            ngramAdaptiveMinimumSupport)
      }
      let fallbackPreparationMicroseconds: Int64?
      let residentBytesAfterFallbackPreparation: UInt64?
      if let fallbackSQLGen {
        let fallbackPreparationStarted = ContinuousClock.now
        try await fallbackSQLGen.prepare()
        fallbackPreparationMicroseconds =
          fallbackPreparationStarted.duration(to: .now).microseconds
        residentBytesAfterFallbackPreparation = residentMemoryBytes()
      } else {
        fallbackPreparationMicroseconds = nil
        residentBytesAfterFallbackPreparation = nil
      }
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
      var primaryValid = 0
      var fallbackCount = 0
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
          maxTokens: maxTokens)
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
        if fallback != nil {
          row.fallbackUsed = false
        }
        var generatedSQL: String?
        do {
          let generation = try await sqlGen.generate(request)
          row.generation = generation
          row.predictedSQL = generation.sql
          if fallback != nil {
            row.primaryGeneration = generation
            row.primarySQL = generation.sql
          }
          generatedSQL = generation.sql
        } catch {
          row.error = "generation: \(error)"
          if fallback != nil {
            row.primaryError = row.error
          }
        }
        let gold: QueryResult
        do {
          gold = try await db.execute(item.sql)
          row.goldResult = gold
          if !gold.isTruncated {
            row.goldDigest = CanonicalSQLResult(gold).digest
          }
        } catch {
          // A failing gold query is a harness defect, not a prediction
          // failure; label it so it is never read as generation drift.
          row.error = "gold: \(error)"
          row.totalMicroseconds =
            started.duration(to: .now).microseconds
          results.append(row)
          print("[\(item.id)] ✗ (\(row.error!))")
          continue
        }

        if let generatedSQL {
          do {
            let predicted = try await db.execute(generatedSQL)
            primaryValid += 1
            if fallback != nil {
              row.primaryValidSQL = true
            }
            row.validSQL = true
            row.predictedResult = predicted
            if !predicted.isTruncated {
              row.predictedDigest =
                CanonicalSQLResult(predicted).digest
            }
            row.ex = EXScore.matches(predicted, gold)
            row.error = nil
          } catch {
            if fallback != nil {
              row.primaryValidSQL = false
              row.primaryError = String(describing: error)
              row.error = row.primaryError
            } else {
              row.error = String(describing: error)
            }
          }
        } else if fallback != nil {
          row.primaryValidSQL = false
        }

        if !row.validSQL, let fallback, let fallbackSQLGen {
          fallbackCount += 1
          row.fallbackUsed = true
          let fallbackStarted = ContinuousClock.now
          let fallbackRequest = SQLGenerationRequest(
            candidateID: CandidateID(rawValue: "fallback-\(item.id)"),
            role: .repair(attempt: 1),
            model: fallback.model,
            question: question,
            gcd: gcd,
            temperature: temperature,
            seed: itemSeed,
            maxTokens: maxTokens)
          do {
            let generation = try await fallbackSQLGen.generate(fallbackRequest)
            row.fallbackGeneration = generation
            row.generation = generation
            row.predictedSQL = generation.sql
            let predicted = try await db.execute(generation.sql)
            row.validSQL = true
            row.predictedResult = predicted
            row.predictedDigest = predicted.isTruncated
              ? nil : CanonicalSQLResult(predicted).digest
            row.ex = EXScore.matches(predicted, gold)
            row.error = nil
          } catch {
            row.error = "fallback: \(error)"
          }
          row.fallbackMicroseconds =
            fallbackStarted.duration(to: .now).microseconds
        }
        if row.validSQL { valid += 1 }
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
        maxTokens: maxTokens,
        rowCap: 10_000,
        itemCount: items.count,
        correctCount: correct,
        validSQLCount: valid,
        ex: Double(correct) / Double(items.count),
        validSQLRate: Double(valid) / Double(items.count),
        fallbackModel: fallback?.model,
        fallbackCount: fallback.map { _ in fallbackCount },
        primaryValidSQLCount: fallback.map { _ in primaryValid },
        primaryPreparationMicroseconds: primaryPreparationMicroseconds,
        fallbackPreparationMicroseconds: fallbackPreparationMicroseconds,
        residentBytesAfterPrimaryPreparation:
          residentBytesAfterPrimaryPreparation,
        residentBytesAfterFallbackPreparation:
          residentBytesAfterFallbackPreparation)
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
