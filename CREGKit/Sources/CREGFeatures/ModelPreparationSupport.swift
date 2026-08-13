import CREGEngine
import ComposableArchitecture
import Foundation

public enum BuildChannel: String, Sendable, Equatable, Codable {
  case debug
  case beta
  case release

  public static let infoKey = "CREGBuildChannel"
  public static let experimentalTrainingRunInfoKey =
    "CREGExperimentalTrainingRun"

  public enum Error: Swift.Error, Sendable, Equatable {
    case missing
    case unknown(String)
    case candidateForbidden
    case candidateRequired
    case trainingRunMissing
    case trainingRunMismatch(expected: String, actual: String)
    case boundedPolicyRequired
  }

  public static func load(info: [String: Any]) throws -> BuildChannel {
    guard let value = info[infoKey] as? String, !value.isEmpty else {
      throw Error.missing
    }
    guard let channel = BuildChannel(rawValue: value.lowercased()) else {
      throw Error.unknown(value)
    }
    return channel
  }

  public static func load(bundle: Bundle = .main) throws -> BuildChannel {
    try load(info: bundle.infoDictionary ?? [:])
  }

  public var allowsDebugCandidate: Bool { self != .release }

  public func validate(
    _ configuration: ProductionGenerationConfiguration,
    info: [String: Any]
  ) throws {
    switch self {
    case .debug:
      break
    case .beta:
      guard let identity = configuration.debugModelIdentity else {
        throw Error.candidateRequired
      }
      guard
        let expected = info[Self.experimentalTrainingRunInfoKey] as? String,
        !expected.isEmpty
      else { throw Error.trainingRunMissing }
      guard expected == identity.trainingRunID else {
        throw Error.trainingRunMismatch(
          expected: expected,
          actual: identity.trainingRunID)
      }
    case .release:
      guard configuration.debugModelIdentity == nil else {
        throw Error.candidateForbidden
      }
      guard configuration.policyVersion == "bounded-three-generation-v1" else {
        throw Error.boundedPolicyRequired
      }
    }
  }
}

public enum DeveloperModePreference {
  public static let storageKey = "developerMode"
}

extension BuildChannel.Error: CustomStringConvertible {
  public var description: String {
    switch self {
    case .missing:
      "CREGBuildChannel is missing from Info.plist"
    case .unknown(let value):
      "Unknown CREGBuildChannel value: \(value)"
    case .candidateForbidden:
      "Release refuses Debug candidate model identities"
    case .candidateRequired:
      "Beta requires a Debug candidate model identity"
    case .trainingRunMissing:
      "Beta is missing CREGExperimentalTrainingRun"
    case .trainingRunMismatch(let expected, let actual):
      "Beta training run mismatch (expected \(expected), actual \(actual))"
    case .boundedPolicyRequired:
      "Release requires schema-v3 bounded-policy evidence"
    }
  }
}

public struct ModelPreparationJournalSnapshot:
  Sendable, Equatable, Codable
{
  public var attemptID: UUID
  /// Identifies the app process that owns an unfinished attempt. Legacy
  /// journals decode nil and are therefore treated as previous-process work.
  public var processSessionID: UUID?
  public var mode: ModelRuntimeMode
  public var stage: ModelPreparationStage
  public var startedAt: Date
  public var stageStartedAt: Date
  public var completed: Bool
  public var failure: ModelPreparationFailure?
  public var environment: [String: String]
}

actor ModelPreparationJournalStore {
  static let shared = ModelPreparationJournalStore()

  private let url: URL
  private let processSessionID: UUID
  private var current: ModelPreparationJournalSnapshot?

  init(url: URL? = nil, processSessionID: UUID = UUID()) {
    self.url =
      url
      ?? URL.applicationSupportDirectory
      .appendingPathComponent("CREG", isDirectory: true)
      .appendingPathComponent("model-preparation.json")
    self.processSessionID = processSessionID
  }

  func unfinishedAttempt() -> ModelPreparationJournalSnapshot? {
    guard
      let snapshot = load(),
      !snapshot.completed,
      snapshot.processSessionID != processSessionID
    else { return nil }
    return snapshot
  }

  func begin(
    mode: ModelRuntimeMode,
    environment: [String: String]
  ) throws {
    let now = Date()
    current = ModelPreparationJournalSnapshot(
      attemptID: UUID(),
      processSessionID: processSessionID,
      mode: mode,
      stage: .buildPolicy,
      startedAt: now,
      stageStartedAt: now,
      completed: false,
      failure: nil,
      environment: environment)
    try persist()
  }

  func stageStarted(
    _ stage: ModelPreparationStage,
    mode: ModelRuntimeMode
  ) throws {
    guard var snapshot = current ?? load() else { return }
    snapshot.mode = mode
    snapshot.stage = stage
    snapshot.stageStartedAt = Date()
    snapshot.completed = false
    snapshot.failure = nil
    current = snapshot
    try persist()
  }

  func stageFinished(
    _ stage: ModelPreparationStage,
    mode: ModelRuntimeMode
  ) throws {
    guard var snapshot = current ?? load() else { return }
    snapshot.mode = mode
    snapshot.stage = stage
    current = snapshot
    try persist()
  }

  func fail(_ failure: ModelPreparationFailure) throws {
    guard var snapshot = current ?? load() else { return }
    snapshot.stage = failure.stage
    snapshot.mode = failure.mode
    snapshot.failure = failure
    snapshot.completed = true
    current = snapshot
    try persist()
  }

  func complete(_ report: ModelPreparationReport) throws {
    guard var snapshot = current ?? load() else { return }
    snapshot.mode = report.mode
    snapshot.completed = true
    snapshot.failure = nil
    current = snapshot
    try persist()
  }

  func exportData() -> Data? {
    guard let snapshot = current ?? load() else { return nil }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try? encoder.encode(snapshot)
  }

  private func load() -> ModelPreparationJournalSnapshot? {
    if let current { return current }
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(ModelPreparationJournalSnapshot.self, from: data)
  }

  private func persist() throws {
    guard let current else { return }
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(current).write(to: url, options: .atomic)
  }
}

public struct ModelPreparationJournalClient: Sendable {
  public var unfinishedAttempt: @Sendable () async -> ModelPreparationJournalSnapshot?
  public var begin: @Sendable (ModelRuntimeMode, [String: String]) async -> Void
  public var stageStarted: @Sendable (ModelPreparationStage, ModelRuntimeMode) async -> Void
  public var stageFinished: @Sendable (ModelPreparationStage, ModelRuntimeMode) async -> Void
  public var fail: @Sendable (ModelPreparationFailure) async -> Void
  public var complete: @Sendable (ModelPreparationReport) async -> Void
  public var exportData: @Sendable () async -> Data?

  static func live(
    store: ModelPreparationJournalStore = .shared
  ) -> ModelPreparationJournalClient {
    ModelPreparationJournalClient(
      unfinishedAttempt: { await store.unfinishedAttempt() },
      begin: { mode, environment in
        try? await store.begin(mode: mode, environment: environment)
      },
      stageStarted: { stage, mode in
        try? await store.stageStarted(stage, mode: mode)
      },
      stageFinished: { stage, mode in
        try? await store.stageFinished(stage, mode: mode)
      },
      fail: { try? await store.fail($0) },
      complete: { try? await store.complete($0) },
      exportData: { await store.exportData() })
  }

  public static let noop = ModelPreparationJournalClient(
    unfinishedAttempt: { nil },
    begin: { _, _ in },
    stageStarted: { _, _ in },
    stageFinished: { _, _ in },
    fail: { _ in },
    complete: { _ in },
    exportData: { nil })
}

extension ModelPreparationJournalClient: DependencyKey {
  public static var testValue: ModelPreparationJournalClient { .noop }
  public static var liveValue: ModelPreparationJournalClient { .live() }
}

extension DependencyValues {
  public var modelPreparationJournal: ModelPreparationJournalClient {
    get { self[ModelPreparationJournalClient.self] }
    set { self[ModelPreparationJournalClient.self] = newValue }
  }
}

extension ModelPreparationProgress {
  static var liveJournaled: ModelPreparationProgress {
    let journal = ModelPreparationJournalClient.live()
    return ModelPreparationProgress(
      stageStarted: journal.stageStarted,
      stageFinished: journal.stageFinished,
      stageFailed: journal.fail)
  }
}

enum ModelPreparationEnvironment {
  static func snapshot(bundle: Bundle = .main) -> [String: String] {
    let info = bundle.infoDictionary ?? [:]
    var context = ModelRuntimeDiagnostics.deviceContext()
    context["build_channel"] =
      (try? BuildChannel.load(info: info).rawValue) ?? "invalid"
    context["app_version"] =
      info["CFBundleShortVersionString"] as? String ?? "unknown"
    context["build_number"] =
      info["CFBundleVersion"] as? String ?? "unknown"
    context["os_version"] = ProcessInfo.processInfo.operatingSystemVersionString
    context["device_identifier"] = DeviceCapability.currentIdentifier
    context["available_disk_mb"] = availableDiskMegabytes()
    context["metal_resource_present"] = String(MetalResourcePreflight.isPresent())
    let model = SupportBundleBuilder.bundledModelIdentity()
    context["model_key"] = model.key
    context["model_revision"] = model.revision
    context["model_receipt_present"] = String(
      bundle.url(
        forResource: "production-model-receipt",
        withExtension: "json") != nil)
    return context
  }

  private static func availableDiskMegabytes() -> String {
    let values = try? URL.applicationSupportDirectory.resourceValues(
      forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    let bytes = values?.volumeAvailableCapacityForImportantUsage ?? 0
    return String(max(0, bytes) / Int64(1024 * 1024))
  }
}

enum MetalResourcePreflight {
  static func resourceURL(bundle: Bundle = .main) -> URL? {
    guard
      let resourceBundle = bundle.url(
        forResource: "mlx-swift_Cmlx", withExtension: "bundle")
    else { return nil }
    let metallib = resourceBundle.appendingPathComponent("default.metallib")
    guard
      let values = try? metallib.resourceValues(forKeys: [.fileSizeKey]),
      (values.fileSize ?? 0) > 0
    else { return nil }
    return metallib
  }

  static func isPresent(bundle: Bundle = .main) -> Bool {
    resourceURL(bundle: bundle) != nil
  }
}
