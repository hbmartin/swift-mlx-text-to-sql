import CREGCore
import CREGData
import CREGEngine
import CREGFeatures
import CREGInference
import Foundation

private actor SQLGenRuntimeRouter {
  private let makeEvaluated: @Sendable () -> SQLGenClient
  private let makeCompatibility: @Sendable () -> SQLGenClient
  private var evaluated: SQLGenClient?
  private var compatibility: SQLGenClient?
  private var activeMode: ModelRuntimeMode = .evaluated
  private var isPrepared = false

  init(
    evaluated: @escaping @Sendable () -> SQLGenClient,
    compatibility: @escaping @Sendable () -> SQLGenClient
  ) {
    self.makeEvaluated = evaluated
    self.makeCompatibility = compatibility
  }

  func prepare(_ mode: ModelRuntimeMode) async throws -> ModelPreparationReport {
    let client: SQLGenClient
    switch mode {
    case .evaluated:
      compatibility = nil
      if evaluated == nil { evaluated = makeEvaluated() }
      client = evaluated!
    case .compatibility:
      // Release a partially prepared optimized container before loading the
      // baseline; retaining both can exceed the iOS working-set budget.
      evaluated = nil
      if compatibility == nil { compatibility = makeCompatibility() }
      client = compatibility!
    }
    do {
      let report = try await client.prepare(mode)
      activeMode = mode
      isPrepared = true
      return report
    } catch {
      if mode == .evaluated {
        evaluated = nil
      } else {
        compatibility = nil
      }
      isPrepared = false
      throw error
    }
  }

  func runtimeMode() -> ModelRuntimeMode { activeMode }

  func generate(
    _ request: SQLGenerationRequest
  ) async throws -> SQLGeneration {
    guard isPrepared else {
      throw ModelPreparationFailure(
        code: "model_runtime_not_prepared",
        stage: .containerLoad,
        mode: activeMode,
        userMessage: "The SQL model is not ready yet.",
        diagnostic: "Generation was requested before preparation completed.")
    }
    guard let client = activeMode == .evaluated ? evaluated : compatibility else {
      throw ModelPreparationFailure(
        code: "model_runtime_not_prepared",
        stage: .containerLoad,
        mode: activeMode,
        userMessage: "The SQL model is not ready yet.",
        diagnostic: "The active runtime client is unavailable.")
    }
    return try await client.generate(request)
  }
}

/// Builds the live dependency graph exactly once. The single
/// `InferenceSerializer` shared by FM and MLX calls is the PRD §7.1
/// "never overlap" guarantee.
enum LiveDependencies {
  static let diagnostics = DiagnosticsClient.live
  static let serializer = InferenceSerializer(diagnostics: diagnostics)

  static let pipeline: QueryPipeline = {
    // ``RootView`` already walls off unsupported hardware before the store is
    // built, so reaching here means a future entry point bypassed it. Refuse
    // rather than load 1.75 GB of weights onto a device that will jetsam.
    guard DeviceCapability.isCurrentDeviceSupported else {
      diagnostics.info(
        category: .configuration,
        code: "application_bootstrap_blocked",
        summary: "The device is below the supported hardware floor.",
        context: ["failure_code": "unsupported_device"])
      return .unavailable(failure: ModelPreparationFailure(
        code: "unsupported_device",
        stage: .buildPolicy,
        mode: .evaluated,
        userMessage: DeviceCapability.requirementMessage,
        diagnostic: """
          The device identifier \(DeviceCapability.currentIdentifier) is below \
          the iPhone 15 floor required by the bundled model.
          """))
    }
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
    let channel: BuildChannel
    let runtimeContract: ModelRuntimeContract
    let production: ProductionGenerationConfiguration
    do {
      let info = bundle.infoDictionary ?? [:]
      channel = try BuildChannel.load(info: info)
      runtimeContract = try ModelRuntimeContract.load(info: info)
      guard let bundledManifest else { throw ModelManifestError.missing }
      production = try ModelManifestLoader.production(
        url: bundledManifest,
        allowDebugCandidate: channel.allowsDebugCandidate,
        requiredRuntimeContract: runtimeContract)
      try channel.validate(production, info: info)
      diagnostics.info(
        category: .configuration,
        code: "production_configuration_loaded",
        summary: "The production SQL model configuration loaded.",
        context: [
          "build_channel": channel.rawValue,
          "model_key": production.model.key,
          "revision": production.model.revision,
          "quantization": production.model.quantization,
          "gcd": production.gcd.rawValue,
          "max_tokens": String(production.maxTokens),
          "runtime_policy_version": production.runtimePolicyVersion ?? "legacy",
          "runtime_contract_version": String(runtimeContract.version),
          "source_revision": runtimeContract.sourceRevision,
          "source_dirty": String(runtimeContract.sourceDirty),
        ])
    } catch {
      let presentation = FailurePresentation.productionConfiguration(error)
      let code = error is BuildChannel.Error
        ? "build_channel_invalid" : presentation.code
      let failure = ModelPreparationFailure(
        code: code,
        stage: .buildPolicy,
        mode: .evaluated,
        userMessage: presentation.message,
        diagnostic: DiagnosticDetails.sanitizedDescription(error),
        errorDomain: (error as NSError).domain,
        errorCode: (error as NSError).code)
      diagnostics.record(DiagnosticEvent(
        level: .error,
        category: .configuration,
        code: failure.code,
        summary: "The production SQL model configuration could not be loaded.",
        details: DiagnosticDetails.describe(error),
        context: ["stage": failure.stage.rawValue]))
      diagnostics.info(
        category: .configuration,
        code: "application_bootstrap_blocked",
        summary: "The on-device SQL runtime bootstrap was blocked.",
        context: ["failure_code": failure.code])
      return .unavailable(failure: failure)
    }
    guard
      let bundledManifest,
      let bundledReceipt,
      let bundledModelDirectory
    else {
      return .unavailable(failure: ModelPreparationFailure(
        code: "production_receipt_missing",
        stage: .receiptValidation,
        mode: .evaluated,
        userMessage: "This build is missing its verified SQL model.",
        diagnostic: ModelManifestError.missingReceipt.localizedDescription))
    }
    #if DEBUG || CREG_DEVICE_BENCHMARK
      let useWiredMemory =
        ProcessInfo.processInfo.environment["CREG_WIRED_MEMORY"] == "true"
    #else
      let useWiredMemory = false
    #endif
    let evaluatedSQLGen: @Sendable () -> SQLGenClient = {
      SQLGenClient.live(
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
        productionNGramSpeculation: production.sqlNGramSpeculation,
        runtimeMode: .evaluated,
        preparationProgress: .liveJournaled
      )
      .reportingModelLoad(
        to: diagnostics,
        modelKey: production.model.key)
    }

    let compatibilitySQLGen: @Sendable () -> SQLGenClient = {
      SQLGenClient.live(
        directory: bundledModelDirectory,
        diagnostics: diagnostics,
        useWiredMemory: false,
        useDirectPromptSuffix: false,
        metalCommandBufferLimitMB: nil,
        compiledQwen2MLPFusion: false,
        compiledQwen2QKVVerificationFusion: false,
        verificationMLPSkipLayers: [],
        verificationMLPLongBatchExtraSkipLayers: [],
        verificationMLPConfidenceSkip: nil,
        verificationMLPAdditionalConfidenceSkips: [],
        questionAwareOutputHead: false,
        compactQuestionAwareOutputHead: false,
        productionNGramSpeculation: nil,
        enablePromptPrefixCache: false,
        runtimeMode: .compatibility,
        preparationProgress: .liveJournaled
      )
      .reportingModelLoad(
        to: diagnostics,
        modelKey: production.model.key)
    }

    let runtimeRouter = SQLGenRuntimeRouter(
      evaluated: evaluatedSQLGen,
      compatibility: compatibilitySQLGen)
    let progress = ModelPreparationProgress.liveJournaled
    let sqlGen = SQLGenClient(
      prepareMode: { mode in
        try await preparationPreflight(
          stage: .buildPolicy,
          mode: mode,
          progress: progress)
        {
          let currentChannel = try BuildChannel.load(bundle: bundle)
          guard currentChannel == channel else {
            throw BuildChannel.Error.unknown(
              "changed from \(channel.rawValue) to \(currentChannel.rawValue)")
          }
          try currentChannel.validate(
            production,
            info: bundle.infoDictionary ?? [:])
          guard
            try ModelRuntimeContract.load(
              info: bundle.infoDictionary ?? [:]) == runtimeContract
          else {
            throw ModelManifestError.runtimeProvenanceMismatch
          }
        }
        try await preparationPreflight(
          stage: .receiptValidation,
          mode: mode,
          progress: progress)
        {
          try ProductionModelReceiptLoader.validate(
            manifestURL: bundledManifest,
            receiptURL: bundledReceipt,
            modelDirectory: bundledModelDirectory,
            production: production,
            diagnostics: diagnostics)
        }
        try await preparationPreflight(
          stage: .metalResource,
          mode: mode,
          progress: progress)
        {
          guard MetalResourcePreflight.isPresent(bundle: bundle) else {
            throw CocoaError(.fileNoSuchFile)
          }
        }
        return try await runtimeRouter.prepare(mode)
      },
      runtimeMode: { await runtimeRouter.runtimeMode() },
      schemaPrompt: { try SQLGenClient.schemaPrompt() },
      generate: { try await runtimeRouter.generate($0) })

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
        "build_channel": channel.rawValue,
        "model_key": production.model.key,
        "policy_version": production.policyVersion ?? "legacy",
        "runtime_policy_version": production.runtimePolicyVersion ?? "legacy",
        "debug_training_run": production.debugModelIdentity?.trainingRunID ?? "none",
        "runtime_contract_version": String(runtimeContract.version),
        "source_revision": runtimeContract.sourceRevision,
        "source_dirty": String(runtimeContract.sourceDirty),
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

  private static func preparationPreflight(
    stage: ModelPreparationStage,
    mode: ModelRuntimeMode,
    progress: ModelPreparationProgress,
    operation: () throws -> Void
  ) async throws {
    let started = ContinuousClock.now
    await progress.stageStarted(stage, mode)
    diagnostics.info(
      category: .configuration,
      code: "model_preparation_stage_started",
      summary: "A SQL model preparation preflight started.",
      context: ModelRuntimeDiagnostics.memoryContext(prefix: "before").merging([
        "stage": stage.rawValue,
        "runtime_mode": mode.rawValue,
      ]) { _, new in new })
    do {
      try operation()
      diagnostics.info(
        category: .configuration,
        code: "model_preparation_stage_finished",
        summary: "A SQL model preparation preflight finished.",
        context: ModelRuntimeDiagnostics.memoryContext(prefix: "after").merging([
          "stage": stage.rawValue,
          "runtime_mode": mode.rawValue,
          "elapsed_ms": String(
            format: "%.1f",
            Double(started.duration(to: .now).microseconds) / 1_000),
        ]) { _, new in new })
      await progress.stageFinished(stage, mode)
    } catch {
      let presentation = FailurePresentation.productionConfiguration(error)
      let code = switch stage {
      case .buildPolicy:
        error is BuildChannel.Error ? "build_channel_invalid" : presentation.code
      case .receiptValidation:
        presentation.code
      case .metalResource:
        "metal_resource_missing"
      case .containerLoad, .qkvFusion, .promptCache, .ngramDraft,
        .outputVocabulary:
        "model_\(stage.rawValue)_failed"
      }
      let failure = ModelPreparationFailure(
        code: code,
        stage: stage,
        mode: mode,
        userMessage: stage == .metalResource
          ? "This build is missing the Metal runtime required by the SQL model. Install a fresh build of CREG."
          : presentation.message,
        diagnostic: DiagnosticDetails.sanitizedDescription(error),
        errorDomain: (error as NSError).domain,
        errorCode: (error as NSError).code)
      diagnostics.record(DiagnosticEvent(
        level: .error,
        category: .configuration,
        code: failure.code,
        summary: "A SQL model preparation preflight failed.",
        details: DiagnosticDetails.describe(error),
        context: [
          "stage": stage.rawValue,
          "runtime_mode": mode.rawValue,
          "error_domain": (error as NSError).domain,
          "error_code": String((error as NSError).code),
        ]))
      await progress.stageFailed(failure)
      throw failure
    }
  }

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
