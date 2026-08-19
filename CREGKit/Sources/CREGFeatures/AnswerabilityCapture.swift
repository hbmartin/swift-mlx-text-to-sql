import CREGEngine
import Foundation
import ZIPFoundation

/// Debug-only on-device capture (docs/eval.md "Answerability"): streams the
/// bundled corpus through the live scope-verdict judge and exports the
/// judgements plus a content-addressed manifest as a ZIP, following the
/// Support Bundle export precedent. The bundled corpus is a byte-exact copy
/// of `eval/gold/answerability.jsonl` (pinned by a test).
enum AnswerabilityCapture {
  struct Manifest: Codable {
    var capturedAt: Date
    var corpusSHA256: String
    var itemCount: Int
    var judgedCount: Int
    var osVersion: String
  }

  static func corpusJSONL() throws -> String {
    guard
      let url = Bundle.module.url(
        forResource: "answerability", withExtension: "jsonl")
    else { throw CocoaError(.fileNoSuchFile) }
    return try String(contentsOf: url, encoding: .utf8)
  }

  /// Runs the full capture and returns the ZIP to share, or nil when the
  /// corpus cannot load or nothing could be judged.
  static func run(
    judge: @Sendable (String) async -> ScopeVerdictRecord?,
    capturedAt: Date
  ) async -> URL? {
    guard
      let jsonl = try? corpusJSONL(),
      let corpus = try? AnswerabilityScorer.parseCorpus(jsonl: jsonl),
      !corpus.isEmpty
    else { return nil }

    var judgements: [AnswerabilityJudgement] = []
    for item in corpus {
      guard let record = await judge(item.question) else { continue }
      judgements.append(
        AnswerabilityJudgement(
          id: item.id,
          verdict: record.verdict,
          missingSubject: record.missingSubject))
    }
    guard !judgements.isEmpty else { return nil }

    let manifest = Manifest(
      capturedAt: capturedAt,
      corpusSHA256: PreparedFollowUpIntegrity.sha256(Data(jsonl.utf8)),
      itemCount: corpus.count,
      judgedCount: judgements.count,
      osVersion: ProcessInfo.processInfo.operatingSystemVersionString)

    do {
      let fileManager = FileManager.default
      let stage = fileManager.temporaryDirectory
        .appendingPathComponent(
          "answerability-capture-\(UUID().uuidString)", isDirectory: true)
      try fileManager.createDirectory(
        at: stage, withIntermediateDirectories: true)
      defer { try? fileManager.removeItem(at: stage) }

      let lineEncoder = JSONEncoder()
      lineEncoder.outputFormatting = [.sortedKeys]
      let lines = try judgements.map { judgement in
        String(decoding: try lineEncoder.encode(judgement), as: UTF8.self)
      }
      try Data((lines.joined(separator: "\n") + "\n").utf8)
        .write(to: stage.appendingPathComponent("judgements.jsonl"))

      let manifestEncoder = JSONEncoder()
      manifestEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      manifestEncoder.dateEncodingStrategy = .iso8601
      try manifestEncoder.encode(manifest)
        .write(to: stage.appendingPathComponent("manifest.json"))

      let zipURL = fileManager.temporaryDirectory
        .appendingPathComponent("answerability-capture.zip")
      try? fileManager.removeItem(at: zipURL)
      let archive = try Archive(url: zipURL, accessMode: .create)
      for name in ["judgements.jsonl", "manifest.json"] {
        try archive.addEntry(
          with: name, relativeTo: stage, compressionMethod: .deflate)
      }
      return zipURL
    } catch {
      return nil
    }
  }
}
