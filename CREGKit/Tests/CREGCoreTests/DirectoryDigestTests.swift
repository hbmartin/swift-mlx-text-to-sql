import CryptoKit
import Foundation
import Testing

@testable import CREGCore

@Suite struct DirectoryDigestTests {
  /// Reference values produced by `fine-tuning/eval/file_integrity.py` for
  /// the identical fixture (`directory_digest(directory_inventory(...))`).
  static let pythonCanonicalJSON = """
    [{"path":"B.txt","sha256":"202617cc32e7923d62a33c5536c47fd10d3a9f8eb4f2fa5be6e1388d66043210","size":25},{"path":"a.txt","sha256":"b6a98d9ce9a2d9149288fa3df42d377c3e42737afdcdaf714e33c0a100b51060","size":6},{"path":"nested/b.json","sha256":"a033e9c21892dcf6ff13a7921d73b88c0430084653346ac6b183a93720c3d39b","size":34},{"path":"z name.txt","sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","size":0}]
    """
  static let pythonModelDigest =
    "022ce6d73a27ca13abf3a945b23ff64ac4afe13847383bcdbe5cfaba9731701e"
  static let pythonFullDigest =
    "263fdd724b8e91c60f3d1c9295ed39414bb5003c9076696f7fb0f0004581c87c"

  private func makeFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("creg-digest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".cache/skipped"), withIntermediateDirectories: true)
    try Data("alpha\n".utf8).write(to: root.appendingPathComponent("a.txt"))
    try Data("{\"k\": \"v/\u{E9} \\\"quoted\\\" \\\\ tab\\t\"}\n".utf8)
      .write(to: root.appendingPathComponent("nested/b.json"))
    try Data().write(to: root.appendingPathComponent("z name.txt"))
    try Data("{\"directory_sha256\":\"x\"}".utf8)
      .write(to: root.appendingPathComponent(".creg-artifact.json"))
    try Data("cache".utf8).write(to: root.appendingPathComponent(".cache/skipped/c.bin"))
    try Data("upper sorts before lower\n".utf8).write(to: root.appendingPathComponent("B.txt"))
    return root
  }

  @Test func modelDirectoryDigestMatchesThePythonReference() throws {
    let root = try makeFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let inventory = try DirectoryDigest.inventory(
      of: root, include: DirectoryDigest.isModelArtifactPath)
    #expect(inventory.map(\.path) == ["B.txt", "a.txt", "nested/b.json", "z name.txt"])
    #expect(
      String(decoding: DirectoryDigest.canonicalJSON(inventory), as: UTF8.self)
        == Self.pythonCanonicalJSON)
    #expect(DirectoryDigest.digest(inventory) == Self.pythonModelDigest)
    #expect(
      try DirectoryDigest.digest(of: root, include: DirectoryDigest.isModelArtifactPath)
        == Self.pythonModelDigest)
  }

  @Test func fullInventoryIncludesLockAndCacheAndMatchesPython() throws {
    let root = try makeFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let inventory = try DirectoryDigest.inventory(of: root)
    #expect(inventory.count == 6)
    #expect(DirectoryDigest.digest(inventory) == Self.pythonFullDigest)
  }

  @Test func changedBytesChangeTheDigestAndSymbolicLinksAreRejected() throws {
    let root = try makeFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("beta\n".utf8).write(to: root.appendingPathComponent("a.txt"))
    #expect(
      try DirectoryDigest.digest(of: root, include: DirectoryDigest.isModelArtifactPath)
        != Self.pythonModelDigest)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("link.txt"),
      withDestinationURL: root.appendingPathComponent("a.txt"))
    #expect(throws: DirectoryDigest.Error.symbolicLink("link.txt")) {
      try DirectoryDigest.inventory(of: root)
    }
  }

  @Test func corpusFileHashesAndParsesTheSameBytes() throws {
    let line = #"{"messages":[{"role":"user","content":"q"},{"role":"assistant","content":"SELECT 1"}]}"#
    let other = #"{"messages":[{"role":"assistant","content":"SELECT 2"}]}"#
    let data = Data((line + "\n\n" + other + "\n").utf8)
    let first = try NGramDraftCorpusFile(data: data)
    let second = try NGramDraftCorpusFile(data: data)
    #expect(first == second)
    #expect(first.statements == ["SELECT 1", "SELECT 2"])
    #expect(first.sha256 == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    let changed = try NGramDraftCorpusFile(data: Data((line + "\n").utf8))
    #expect(changed.sha256 != first.sha256)
    #expect(changed.statements == ["SELECT 1"])
  }

  @Test func corpusFileRejectsInvalidUTF8InsideAssistantSQL() {
    var data = Data(#"{"messages":[{"role":"assistant","content":"SELECT "#.utf8)
    data.append(0xFF)
    data.append(contentsOf: Data(#" FROM property"}]}"#.utf8))
    #expect(throws: NGramDraftCorpusFile.Error.invalidUTF8) {
      try NGramDraftCorpusFile(data: data)
    }
  }

  @Test func legacyBatchPayloadDecodesWithoutGenerationFields() throws {
    let sourceID = UUID()
    let payload = Data(
      """
      {"sourceAssistantMessageID":"\(sourceID.uuidString)","status":"preparing",
       "suggestions":[],"updatedAt":5}
      """.utf8)
    let batch = try JSONDecoder().decode(PreparedFollowUpBatch.self, from: payload)
    #expect(batch.generation == nil)
    #expect(batch.effectiveGeneration == 0)
    #expect(batch.scopeDiagnosisCompleted == false)
    var owned = batch
    owned.generation = 3
    owned.scopeDiagnosisCompleted = true
    let decoded = try JSONDecoder().decode(
      PreparedFollowUpBatch.self, from: JSONEncoder().encode(owned))
    #expect(decoded.generation == 3)
    #expect(decoded.effectiveGeneration == 3)
    #expect(decoded.scopeDiagnosisCompleted)
  }
}
