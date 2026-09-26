import CryptoKit
import Foundation

/// Content-derived identity for a model directory, matching the repository's
/// Python `eval.file_integrity` digest: every regular file (no symbolic links
/// or special entries) sorted by POSIX relative path, serialized as canonical
/// JSON `[{"path","sha256","size"}]` with sorted keys, compact separators,
/// and raw UTF-8, then hashed with SHA-256. A lock file's declared digest can
/// only claim what was true at fetch time; this re-derives it from bytes.
public enum DirectoryDigest {
  public struct Entry: Sendable, Equatable {
    public var path: String
    public var size: Int
    public var sha256: String

    public init(path: String, size: Int, sha256: String) {
      self.path = path
      self.size = size
      self.sha256 = sha256
    }
  }

  public enum Error: Swift.Error, Equatable, Sendable {
    case notADirectory(String)
    case symbolicLink(String)
    case irregularEntry(String)
  }

  /// The model-tree exclusions shared with `fetch_model.py`: the artifact lock
  /// itself and every Hugging Face cache path.
  public static func isModelArtifactPath(_ relativePath: String) -> Bool {
    let components = relativePath.split(separator: "/")
    guard let name = components.last else { return false }
    return name != ".creg-artifact.json" && !components.contains(".cache")
  }

  public static func inventory(
    of directory: URL,
    include: (String) -> Bool = { _ in true },
    chunkSize: Int = 1 << 20
  ) throws -> [Entry] {
    let root = directory.standardizedFileURL
    let rootValues = try root.resourceValues(
      forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
    guard rootValues.isSymbolicLink != true else {
      throw Error.symbolicLink(root.path)
    }
    guard rootValues.isDirectory == true else {
      throw Error.notADirectory(root.path)
    }
    var entries: [Entry] = []
    try visit(root, relativeComponents: [], include: include,
      chunkSize: chunkSize, into: &entries)
    return entries.sorted { lhs, rhs in
      Array(lhs.path.utf8).lexicographicallyPrecedes(Array(rhs.path.utf8))
    }
  }

  private static func visit(
    _ directory: URL,
    relativeComponents: [String],
    include: (String) -> Bool,
    chunkSize: Int,
    into entries: inout [Entry]
  ) throws {
    let children = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [
        .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey,
        .fileSizeKey,
      ],
      options: [])
    for child in children.sorted(by: {
      Array($0.lastPathComponent.utf8)
        .lexicographicallyPrecedes(Array($1.lastPathComponent.utf8))
    }) {
      let values = try child.resourceValues(forKeys: [
        .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey,
      ])
      let components = relativeComponents + [child.lastPathComponent]
      let relativePath = components.joined(separator: "/")
      if values.isSymbolicLink == true {
        throw Error.symbolicLink(relativePath)
      }
      if values.isDirectory == true {
        try visit(child, relativeComponents: components, include: include,
          chunkSize: chunkSize, into: &entries)
        continue
      }
      guard values.isRegularFile == true else {
        throw Error.irregularEntry(relativePath)
      }
      guard include(relativePath) else { continue }
      entries.append(Entry(
        path: relativePath,
        size: values.fileSize ?? 0,
        sha256: try PreparedFollowUpIntegrity.sha256(
          contentsOf: child, chunkSize: chunkSize)))
    }
  }

  /// `json.dumps(inventory, sort_keys=True, separators=(",", ":"),
  /// ensure_ascii=False)` for the fixed entry shape.
  public static func canonicalJSON(_ inventory: [Entry]) -> Data {
    var text = "["
    for (index, entry) in inventory.enumerated() {
      if index > 0 { text += "," }
      text += "{\"path\":\(jsonString(entry.path))"
      text += ",\"sha256\":\(jsonString(entry.sha256))"
      text += ",\"size\":\(entry.size)}"
    }
    text += "]"
    return Data(text.utf8)
  }

  public static func digest(_ inventory: [Entry]) -> String {
    SHA256.hash(data: canonicalJSON(inventory))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  public static func digest(
    of directory: URL,
    include: (String) -> Bool = { _ in true }
  ) throws -> String {
    digest(try inventory(of: directory, include: include))
  }

  private static func jsonString(_ value: String) -> String {
    var escaped = "\""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": escaped += "\\\""
      case "\\": escaped += "\\\\"
      case "\n": escaped += "\\n"
      case "\r": escaped += "\\r"
      case "\t": escaped += "\\t"
      case "\u{08}": escaped += "\\b"
      case "\u{0C}": escaped += "\\f"
      default:
        if scalar.value < 0x20 {
          escaped += String(format: "\\u%04x", scalar.value)
        } else {
          escaped.unicodeScalars.append(scalar)
        }
      }
    }
    return escaped + "\""
  }
}

/// The experimental n-gram draft corpus: one JSON conversation per line whose
/// first assistant message is a SQL statement. The bytes are hashed and parsed
/// from one read so the recorded digest can never describe different content
/// than the corpus the run actually drafted from.
public struct NGramDraftCorpusFile: Sendable, Equatable {
  public var sha256: String
  public var statements: [String]

  private struct Conversation: Decodable {
    struct Message: Decodable {
      let role: String
      let content: String
    }

    let messages: [Message]
  }

  public init(data: Data) throws {
    sha256 = PreparedFollowUpIntegrity.sha256(data)
    let text = String(decoding: data, as: UTF8.self)
    statements = try text.split(separator: "\n")
      .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      .compactMap { line in
        try JSONDecoder().decode(Conversation.self, from: Data(line.utf8))
          .messages.first { $0.role == "assistant" }?.content
      }
  }

  public static func load(contentsOf url: URL) throws -> NGramDraftCorpusFile {
    try NGramDraftCorpusFile(data: try Data(contentsOf: url))
  }
}
