import CREGEngine
import CryptoKit
import Foundation
import OSLog
import ZIPFoundation

/// Builds the explicit developer-support export: a ZIP with the history
/// database snapshot, normalized conversations/messages/events/feedback,
/// drafts, sanitized diagnostics, and model/build manifests. Model weights
/// and the bundled portfolio database are excluded; hashes and receipts
/// stand in for them (CONTEXT.md "Support Bundle").
public struct SupportBundleClient: Sendable {
  public var build:
    @Sendable (SupportBundleSource) async throws -> AppFeature.SupportBundleExport

  public init(
    build: @escaping @Sendable (SupportBundleSource) async throws ->
      AppFeature.SupportBundleExport
  ) {
    self.build = build
  }
}

extension SupportBundleClient {
  public static let noop = SupportBundleClient { source in
    AppFeature.SupportBundleExport(
      url: source.databaseSnapshotURL,
      manifest: SupportBundleManifest(
        createdAt: Date(timeIntervalSince1970: 0),
        appVersion: "0",
        buildNumber: "0",
        modelKey: "none",
        modelRevision: "none",
        conversationCount: source.conversationCount,
        messageCount: source.messageCount,
        eventLineCount: source.eventLineCount,
        feedbackCount: source.feedbackCount))
  }

  public static func live() -> SupportBundleClient {
    SupportBundleClient { source in
      let bundle = Bundle.main
      let info = bundle.infoDictionary ?? [:]
      let preparationJSON =
        await ModelPreparationJournalClient.live().exportData()
      let preparation: ModelPreparationJournalSnapshot? = preparationJSON
        .flatMap { data in
          let decoder = JSONDecoder()
          decoder.dateDecodingStrategy = .iso8601
          return try? decoder.decode(
            ModelPreparationJournalSnapshot.self, from: data)
        }
      let context = SupportBundleBuilder.Context(
        appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
        buildNumber: info["CFBundleVersion"] as? String ?? "unknown",
        buildChannel: (try? BuildChannel.load(info: info).rawValue) ?? "invalid",
        modelIdentity: SupportBundleBuilder.bundledModelIdentity(),
        runtimeMode: preparation?.mode ?? .evaluated,
        createdAt: Date())
      return try SupportBundleBuilder.build(
        source: source,
        context: context,
        bundledModelManifest: bundle.url(
          forResource: "model-manifest", withExtension: "json"),
        bundledModelReceipt: bundle.url(
          forResource: "production-model-receipt", withExtension: "json"),
        bundledPortfolioDatabase: bundle.url(
          forResource: "creg", withExtension: "sqlite"),
        diagnosticsText: SupportBundleBuilder.recentSanitizedDiagnostics(),
        modelPreparationJSON: preparationJSON,
        scratchDirectory: FileManager.default.temporaryDirectory)
    }
  }
}

public enum SupportBundleBuilder {
  public struct Context: Sendable {
    public var appVersion: String
    public var buildNumber: String
    public var buildChannel: String
    public var modelIdentity: (key: String, revision: String)
    public var runtimeMode: ModelRuntimeMode
    public var createdAt: Date

    public init(
      appVersion: String,
      buildNumber: String,
      buildChannel: String = "unknown",
      modelIdentity: (key: String, revision: String),
      runtimeMode: ModelRuntimeMode = .evaluated,
      createdAt: Date
    ) {
      self.appVersion = appVersion
      self.buildNumber = buildNumber
      self.buildChannel = buildChannel
      self.modelIdentity = modelIdentity
      self.runtimeMode = runtimeMode
      self.createdAt = createdAt
    }
  }

  /// The fixed non-manifest inventory: file name to payload. Pure so tests
  /// can verify inclusion and exclusion decisions without touching disk.
  public static func inventory(
    source: SupportBundleSource,
    diagnosticsText: String,
    modelManifestJSON: Data?,
    modelReceiptJSON: Data?,
    modelPreparationJSON: Data? = nil
  ) -> [(name: String, data: Data)] {
    var files: [(String, Data)] = [
      ("conversations.json", source.conversationsJSON),
      ("messages.json", source.messagesJSON),
      ("events.jsonl", source.eventsJSONL),
      ("feedback.json", source.feedbackJSON),
      ("diagnostics.txt", Data(diagnosticsText.utf8)),
    ]
    if let modelManifestJSON {
      files.append(("model-manifest.json", modelManifestJSON))
    }
    if let modelReceiptJSON {
      files.append(("production-model-receipt.json", modelReceiptJSON))
    }
    if let modelPreparationJSON {
      files.append(("model-preparation.json", modelPreparationJSON))
    }
    return files
  }

  /// What the bundle deliberately leaves out, with hashes or receipts
  /// standing in for the excluded artifacts.
  public static func exclusions(
    portfolioDatabaseSHA256: String?,
    hasModelReceipt: Bool
  ) -> [SupportBundleManifest.Exclusion] {
    [
      SupportBundleManifest.Exclusion(
        name: "model-weights",
        reason: hasModelReceipt
          ? "Excluded for size; production-model-receipt.json carries the weight hashes."
          : "Excluded for size; no receipt was bundled in this build.",
        sha256: nil),
      SupportBundleManifest.Exclusion(
        name: "portfolio-database",
        reason:
          "The bundled portfolio snapshot is excluded; its content hash identifies the exact data version.",
        sha256: portfolioDatabaseSHA256),
    ]
  }

  public static func build(
    source: SupportBundleSource,
    context: Context,
    bundledModelManifest: URL?,
    bundledModelReceipt: URL?,
    bundledPortfolioDatabase: URL?,
    diagnosticsText: String,
    modelPreparationJSON: Data? = nil,
    scratchDirectory: URL
  ) throws -> AppFeature.SupportBundleExport {
    let fileManager = FileManager.default
    let stageDirectory = scratchDirectory.appendingPathComponent(
      "creg-support-bundle", isDirectory: true)
    try? fileManager.removeItem(at: stageDirectory)
    try fileManager.createDirectory(
      at: stageDirectory, withIntermediateDirectories: true)

    var files = inventory(
      source: source,
      diagnosticsText: diagnosticsText,
      modelManifestJSON: bundledModelManifest.flatMap { try? Data(contentsOf: $0) },
      modelReceiptJSON: bundledModelReceipt.flatMap { try? Data(contentsOf: $0) },
      modelPreparationJSON: modelPreparationJSON)
    files.append(
      ("history-snapshot.sqlite", try Data(contentsOf: source.databaseSnapshotURL)))

    var entries: [SupportBundleManifest.Entry] = []
    for (name, data) in files {
      try data.write(to: stageDirectory.appendingPathComponent(name))
      entries.append(
        SupportBundleManifest.Entry(
          path: name,
          byteCount: data.count,
          sha256: sha256Hex(data)))
    }

    let portfolioHash = bundledPortfolioDatabase
      .flatMap { try? Data(contentsOf: $0) }
      .map(sha256Hex)
    let manifest = SupportBundleManifest(
      createdAt: context.createdAt,
      appVersion: context.appVersion,
      buildNumber: context.buildNumber,
      buildChannel: context.buildChannel,
      modelKey: context.modelIdentity.key,
      modelRevision: context.modelIdentity.revision,
      runtimeMode: context.runtimeMode,
      conversationCount: source.conversationCount,
      messageCount: source.messageCount,
      eventLineCount: source.eventLineCount,
      feedbackCount: source.feedbackCount,
      entries: entries,
      exclusions: exclusions(
        portfolioDatabaseSHA256: portfolioHash,
        hasModelReceipt: bundledModelReceipt != nil))

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest)
      .write(to: stageDirectory.appendingPathComponent("manifest.json"))

    let zipURL = scratchDirectory.appendingPathComponent("creg-support-bundle.zip")
    try? fileManager.removeItem(at: zipURL)
    let archive = try Archive(url: zipURL, accessMode: .create)
    for name in (files.map(\.0) + ["manifest.json"]).sorted() {
      try archive.addEntry(
        with: name,
        relativeTo: stageDirectory,
        compressionMethod: .deflate)
    }
    try? fileManager.removeItem(at: stageDirectory)
    try? fileManager.removeItem(at: source.databaseSnapshotURL)
    return AppFeature.SupportBundleExport(url: zipURL, manifest: manifest)
  }

  static func bundledModelIdentity() -> (key: String, revision: String) {
    guard
      let url = Bundle.main.url(
        forResource: "model-manifest", withExtension: "json"),
      let configuration = try? ModelManifestLoader.production(
        url: url, allowDebugCandidate: true)
    else { return ("unavailable", "unavailable") }
    return (configuration.model.key, configuration.model.revision)
  }

  /// Recent unified-log entries for this process. ``DiagnosticsClient`` is
  /// the single sanitization boundary, so everything it logged is already
  /// privacy-redacted; private interpolations render as <private>.
  static func recentSanitizedDiagnostics() -> String {
    let subsystem = Bundle.main.bundleIdentifier ?? "dev.haroldmartin.CREG"
    guard
      let store = try? OSLogStore(scope: .currentProcessIdentifier),
      let entries = try? store.getEntries()
    else { return "Diagnostics were unavailable for this export.\n" }
    let formatter = ISO8601DateFormatter()
    var lines: [String] = []
    for entry in entries {
      guard let logEntry = entry as? OSLogEntryLog,
        logEntry.subsystem == subsystem
      else { continue }
      lines.append(
        "\(formatter.string(from: logEntry.date)) [\(logEntry.category)] \(logEntry.composedMessage)")
    }
    return lines.isEmpty
      ? "No diagnostics were recorded in this process.\n"
      : lines.joined(separator: "\n") + "\n"
  }

  static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
  }
}
