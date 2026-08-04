import AVFoundation
import CREGEngine
import ComposableArchitecture
import Foundation

// MARK: - Read Aloud

/// Narration-only speech playback with play/pause/stop. The stream finishes
/// when the utterance completes; cancellation stops speech.
public struct ReadAloudClient: Sendable {
  public enum Event: Sendable, Equatable {
    case finished
  }

  public var speak: @Sendable (String) -> AsyncStream<Event>
  public var pause: @Sendable () async -> Void
  public var resume: @Sendable () async -> Void
  public var stop: @Sendable () async -> Void

  public init(
    speak: @escaping @Sendable (String) -> AsyncStream<Event>,
    pause: @escaping @Sendable () async -> Void,
    resume: @escaping @Sendable () async -> Void,
    stop: @escaping @Sendable () async -> Void
  ) {
    self.speak = speak
    self.pause = pause
    self.resume = resume
    self.stop = stop
  }
}

extension ReadAloudClient {
  public static func live() -> ReadAloudClient {
    let speaker = NarrationSpeaker()
    return ReadAloudClient(
      speak: { text in
        AsyncStream { continuation in
          Task { @MainActor in
            speaker.speak(text) {
              continuation.yield(.finished)
              continuation.finish()
            }
          }
          continuation.onTermination = { _ in
            Task { @MainActor in speaker.stop() }
          }
        }
      },
      pause: { await speaker.pause() },
      resume: { await speaker.resume() },
      stop: { await speaker.stop() }
    )
  }

  /// Silent playback that stays "playing" until stopped or cancelled, so
  /// reducer tests can assert intermediate Read Aloud states.
  public static let noop = ReadAloudClient(
    speak: { _ in AsyncStream { _ in } },
    pause: {},
    resume: {},
    stop: {}
  )
}

@MainActor
private final class NarrationSpeaker: NSObject, AVSpeechSynthesizerDelegate {
  private let synthesizer = AVSpeechSynthesizer()
  private var onFinish: (() -> Void)?

  nonisolated override init() {
    super.init()
  }

  func speak(_ text: String, onFinish: @escaping () -> Void) {
    synthesizer.stopSpeaking(at: .immediate)
    self.onFinish = onFinish
    synthesizer.delegate = self
    synthesizer.speak(AVSpeechUtterance(string: text))
  }

  func pause() {
    synthesizer.pauseSpeaking(at: .word)
  }

  func resume() {
    synthesizer.continueSpeaking()
  }

  func stop() {
    onFinish = nil
    synthesizer.stopSpeaking(at: .immediate)
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didFinish utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in
      let finish = self.onFinish
      self.onFinish = nil
      finish?()
    }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didCancel utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in
      self.onFinish = nil
    }
  }
}

extension ReadAloudClient: DependencyKey {
  public static var testValue: ReadAloudClient { .noop }
  public static var liveValue: ReadAloudClient { LiveDependencies.readAloud }
}

// MARK: - Haptics

/// The light haptic accompanying a background Answer Ready completion.
public struct HapticsClient: Sendable {
  public var answerReady: @Sendable () async -> Void

  public init(answerReady: @escaping @Sendable () async -> Void) {
    self.answerReady = answerReady
  }
}

extension HapticsClient {
  public static let noop = HapticsClient(answerReady: {})

  public static func live() -> HapticsClient {
    HapticsClient(
      answerReady: {
        #if canImport(UIKit)
          await MainActor.run {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
          }
        #endif
      })
  }
}

extension HapticsClient: DependencyKey {
  public static var testValue: HapticsClient { .noop }
  public static var liveValue: HapticsClient { .live() }
}

// MARK: - Dependency registrations

extension QueryPipeline: DependencyKey {
  public static var testValue: QueryPipeline {
    QueryPipeline { _, _ in AsyncStream { $0.finish() } }
  }

  public static var liveValue: QueryPipeline { LiveDependencies.pipeline }
}

extension HistoryClient: DependencyKey {
  public static var testValue: HistoryClient { .noop() }
  public static var liveValue: HistoryClient { LiveDependencies.history }
}

extension SupportBundleClient: DependencyKey {
  public static var testValue: SupportBundleClient { .noop }
  public static var liveValue: SupportBundleClient { .live() }
}

extension DependencyValues {
  public var queryPipeline: QueryPipeline {
    get { self[QueryPipeline.self] }
    set { self[QueryPipeline.self] = newValue }
  }

  public var historyClient: HistoryClient {
    get { self[HistoryClient.self] }
    set { self[HistoryClient.self] = newValue }
  }

  public var readAloud: ReadAloudClient {
    get { self[ReadAloudClient.self] }
    set { self[ReadAloudClient.self] = newValue }
  }

  public var haptics: HapticsClient {
    get { self[HapticsClient.self] }
    set { self[HapticsClient.self] = newValue }
  }

  public var supportBundle: SupportBundleClient {
    get { self[SupportBundleClient.self] }
    set { self[SupportBundleClient.self] = newValue }
  }
}

#if canImport(UIKit)
  import UIKit
#endif

/// Builds the live dependency graph exactly once. The single
/// ``InferenceSerializer`` shared by FM and MLX calls is the PRD §7.1
/// "never overlap" guarantee.
enum LiveDependencies {
  static let diagnostics = DiagnosticsClient.live
  static let serializer = InferenceSerializer(diagnostics: diagnostics)
  static let readAloud = ReadAloudClient.live()

  static let pipeline: QueryPipeline = {
    let bundle = Bundle.main
    let bundledManifest = bundle.url(
      forResource: "model-manifest", withExtension: "json")
    let bundledReceipt = bundle.url(
      forResource: "production-model-receipt", withExtension: "json")
    let bundledModelDirectory = bundle.url(
      forResource: "SQLModel", withExtension: nil)
    diagnostics.info(
      category: .configuration,
      code: "application_bootstrap_started",
      summary: "The on-device SQL runtime bootstrap started.",
      context: [
        "has_manifest": String(bundledManifest != nil),
        "has_model_directory": String(bundledModelDirectory != nil),
        "has_receipt": String(bundledReceipt != nil),
      ])
    let production: ProductionGenerationConfiguration
    let productionResult = ProductionModelBootstrap.load(
      diagnostics: diagnostics
    ) {
      guard let bundledManifest else { throw ModelManifestError.missing }
      #if DEBUG || CREG_DEVICE_BENCHMARK
        let configuration = try ModelManifestLoader.production(
          url: bundledManifest,
          allowDebugCandidate: true)
      #else
        let configuration = try ModelManifestLoader.production(
          url: bundledManifest)
      #endif
      guard let bundledReceipt, let bundledModelDirectory else {
        throw ModelManifestError.missingReceipt
      }
      #if !DEBUG && !CREG_DEVICE_BENCHMARK
        guard configuration.debugModelIdentity == nil else {
          throw ModelManifestError.invalidProductionConfiguration(
            "Release refuses Debug candidate model identities")
        }
        guard configuration.policyVersion == "bounded-three-generation-v1" else {
          throw ModelManifestError.invalidProductionConfiguration(
            "Release requires schema-v3 bounded-policy evidence")
        }
      #endif
      try ProductionModelReceiptLoader.validate(
        manifestURL: bundledManifest,
        receiptURL: bundledReceipt,
        modelDirectory: bundledModelDirectory,
        production: configuration,
        diagnostics: diagnostics)
      return configuration
    }
    switch productionResult {
    case .success(let configuration):
      production = configuration
    case .failure(let failure):
      diagnostics.info(
        category: .configuration,
        code: "application_bootstrap_blocked",
        summary: "The on-device SQL runtime bootstrap was blocked.",
        context: ["failure_code": failure.code])
      return .unavailable(
        userMessage: failure.message,
        diagnosticCode: failure.code,
        diagnostic: failure.diagnostic)
    }
    guard let bundledModelDirectory else {
      return .unavailable(
        userMessage: "This build is missing its verified SQL model.",
        diagnosticCode: "production_receipt_missing",
        diagnostic: ModelManifestError.missingReceipt.localizedDescription)
    }
    #if DEBUG || CREG_DEVICE_BENCHMARK
      let useWiredMemory =
        ProcessInfo.processInfo.environment["CREG_WIRED_MEMORY"] == "true"
    #else
      let useWiredMemory = false
    #endif
    let sqlGen = SQLGenClient.live(
      directory: bundledModelDirectory,
      diagnostics: diagnostics,
      useWiredMemory: useWiredMemory,
      useDirectPromptSuffix: true,
      metalCommandBufferLimitMB: production.metalCommandBufferLimitMB,
      compiledQwen2MLPFusion: production.compiledQwen2MLPFusion,
      compiledQwen2QKVVerificationFusion:
        production.compiledQwen2QKVVerificationFusion,
      verificationMLPSkipLayers: production.verificationMLPSkipLayers,
      verificationMLPLongBatchExtraSkipLayers:
        production.verificationMLPLongBatchExtraSkipLayers,
      verificationMLPConfidenceSkip:
        production.verificationMLPConfidenceSkip,
      verificationMLPAdditionalConfidenceSkips:
        production.verificationMLPAdditionalConfidenceSkips,
      questionAwareOutputHead: production.questionAwareOutputHead,
      compactQuestionAwareOutputHead:
        production.compactQuestionAwareOutputHead,
      productionNGramSpeculation: production.sqlNGramSpeculation
    )
    .reportingModelLoad(
      to: diagnostics,
      modelKey: production.model.key)

    let db: DatabaseClient
    let databaseReady: Bool
    diagnostics.info(
      category: .database,
      code: "portfolio_database_open_started",
      summary: "The bundled portfolio database open started.")
    if let url = Bundle.main.url(forResource: "creg", withExtension: "sqlite") {
      do {
        db = try DatabaseClient.live(url: url)
        databaseReady = true
        diagnostics.info(
          category: .database,
          code: "portfolio_database_open_finished",
          summary: "The bundled portfolio database opened read-only.",
          context: ["row_cap": String(DatabaseClient.defaultRowCap)])
      } catch {
        databaseReady = false
        diagnostics.record(
          DiagnosticEvent(
            level: .error,
            category: .database,
            code: "portfolio_database_open_failed",
            summary: "The bundled portfolio database could not be opened.",
            details: DiagnosticDetails.describe(error)))
        db = .unavailableBundledPortfolioDatabase(
          diagnostic: DiagnosticDetails.describe(error))
      }
    } else {
      databaseReady = false
      diagnostics.record(
        DiagnosticEvent(
          level: .error,
          category: .database,
          code: "portfolio_database_missing",
          summary: "The bundled portfolio database resource is missing."))
      db = .unavailableBundledPortfolioDatabase(
        diagnostic: "The bundled portfolio database resource is missing.")
    }
    diagnostics.info(
      category: .configuration,
      code: databaseReady
        ? "application_bootstrap_finished" : "application_bootstrap_degraded",
      summary: databaseReady
        ? "The on-device SQL runtime bootstrap finished."
        : "The on-device SQL runtime bootstrap finished without a usable database.",
      context: [
        "database_ready": String(databaseReady),
        "model_key": production.model.key,
        "policy_version": production.policyVersion ?? "legacy",
        "runtime_policy_version": production.runtimePolicyVersion ?? "legacy",
        "debug_training_run": production.debugModelIdentity?.trainingRunID ?? "none",
      ])
    return QueryPipeline.live(
      fm: .live(),
      sqlGen: sqlGen,
      db: db,
      serializer: serializer,
      configuration: .init(
        production: production,
        gateSensitivity: 0,
        maxRepairAttempts: 2)
    ).reportingOperations(to: diagnostics)
  }()

  static let history: HistoryClient = {
    let url = URL.applicationSupportDirectory
      .appendingPathComponent("CREG", isDirectory: true)
      .appendingPathComponent("history.sqlite")
    diagnostics.info(
      category: .history,
      code: "history_store_open_started",
      summary: "The local conversation history store open started.")
    do {
      let client = try HistoryClient.live(databaseURL: url)
      diagnostics.info(
        category: .history,
        code: "history_store_open_finished",
        summary: "The local conversation history store opened.")
      return client
    } catch {
      diagnostics.record(
        DiagnosticEvent(
          level: .error,
          category: .history,
          code: "history_store_open_failed",
          summary: "The local conversation history store could not be opened.",
          details: DiagnosticDetails.describe(error)))
      return .unavailable(
        diagnostic: DiagnosticDetails.describe(error))
    }
  }()
}
