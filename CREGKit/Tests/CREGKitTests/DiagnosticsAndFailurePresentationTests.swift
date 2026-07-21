import ComposableArchitecture
import Foundation
import Testing

@testable import CREGEngine
@testable import CREGFeatures

private final class DiagnosticEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [DiagnosticEvent] = []

  var client: DiagnosticsClient {
    DiagnosticsClient { [self] event in
      lock.lock()
      storage.append(event)
      lock.unlock()
    }
  }

  var events: [DiagnosticEvent] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

private enum DiagnosticsTestError: LocalizedError, Sendable {
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .failed(let message): message
    }
  }
}

@Suite struct DiagnosticsAndFailurePresentationTests {
  private struct ManifestProbe: Decodable {
    struct Model: Decodable {
      struct Quantization: Decodable {
        var bits: Int
      }

      var quantization: Quantization
    }

    var models: [Model]
  }

  private static let model = ModelReference(
    key: "test-model",
    repository: "owner/test-model",
    revision: String(repeating: "a", count: 40))

  private func configuration(maxRepairAttempts: Int = 0)
    -> QueryPipeline.Configuration
  {
    QueryPipeline.Configuration(
      model: Self.model,
      gcd: .off,
      productionTemperature: 0,
      maxTokens: 64,
      gateSensitivity: 0,
      maxRepairAttempts: maxRepairAttempts,
      selfConsistencyN: 1,
      sampleTemperature: 0.7,
      alwaysVote: false)
  }

  private func manifestDecodingError() -> any Error {
    do {
      _ = try JSONDecoder().decode(
        ManifestProbe.self,
        from: Data(
          """
          {"models":[
            {"quantization":{"bits":4}},
            {"quantization":{"bits":4}},
            {"quantization":{"bits":4}},
            {}
          ]}
          """.utf8))
      Issue.record("expected manifest decoding to fail")
      return DiagnosticsTestError.failed("test did not produce a decoding error")
    } catch {
      return error
    }
  }

  private func terminalEvent(_ events: [PipelineEvent])
    -> (TurnOutcome, TurnTelemetry)?
  {
    for event in events.reversed() {
      if case .turnFinished(let outcome, let telemetry) = event {
        return (outcome, telemetry)
      }
    }
    return nil
  }

  @Test func diagnosticRedactionPreservesOrdinaryEnglishAndDecodingContext() {
    let ordinary =
      "No value associated with key quantization. The operation could not be completed with error 14; update the bundle and create a new build."
    #expect(DiagnosticPrivacy.redact(ordinary) == ordinary)

    let decoding = DiagnosticDetails.describe(manifestDecodingError())
    let redacted = DiagnosticPrivacy.redact(decoding)
    #expect(redacted.contains("models[3].quantization"))
    #expect(!redacted.contains("<redacted SQL>"))

    let instruction = "Select a valid model before retrying."
    #expect(DiagnosticPrivacy.redact(instruction) == instruction)
    #expect(DiagnosticPrivacy.redact("SELECT 1") == "<redacted SQL>")
    #expect(
      DiagnosticPrivacy.redact("SELECT char(97, 0, 98)")
        == "<redacted SQL>")
    #expect(
      DiagnosticPrivacy.redact(
        "SELECT CASE WHEN tenant_id IS NULL THEN 'unknown' ELSE tenant_id END FROM tenants")
        == "<redacted SQL>")
    #expect(
      DiagnosticPrivacy.redact("SELECT EXISTS(SELECT 1 FROM tenants)")
        == "<redacted SQL>")
    #expect(
      DiagnosticPrivacy.redact("SELECT (SELECT COUNT(*) FROM tenants)")
        == "<redacted SQL>")
    #expect(
      DiagnosticPrivacy.redact(
        "SELECT\nCASE WHEN tenant_id IS NULL THEN 'unknown' ELSE tenant_id END FROM tenants")
        == "<redacted SQL>")
    #expect(
      DiagnosticPrivacy.redact("SELECT\nEXISTS(SELECT 1 FROM tenants)")
        == "<redacted SQL>")
    #expect(
      DiagnosticPrivacy.redact("SELECT\n(SELECT COUNT(*) FROM tenants)")
        == "<redacted SQL>")
  }

  @Test func diagnosticRedactionTargetsStatementShapesLabelsAndIdentifiers() {
    let identifier = "5f70da4c-e71f-4b6a-b4e8-6e37fa393ce2"
    let details =
      "SQL: SELECT secret FROM leases\nSELECT name FROM properties\nfile:///private/tmp/creg.sqlite /creg.sqlite \(identifier)"
    let redacted = DiagnosticPrivacy.redact(details)

    #expect(!redacted.contains("secret"))
    #expect(!redacted.contains("properties"))
    #expect(!redacted.contains("/creg.sqlite"))
    #expect(!redacted.contains(identifier))
    #expect(redacted.contains("SQL=<redacted SQL>"))
    #expect(redacted.contains("<redacted path>"))
    #expect(redacted.contains("<redacted identifier>"))
  }

  @Test func manifestFailureIsFriendlyButRetainsCodingPathForDevelopers() {
    let failure = FailurePresentation.productionConfiguration(
      manifestDecodingError())

    #expect(failure.code == "production_manifest_incompatible")
    #expect(failure.title == "SQL model unavailable")
    #expect(failure.message.contains("incompatible model configuration"))
    #expect(!failure.message.contains("quantization"))
    #expect(failure.technicalDetails(developerMode: false) == nil)
    #expect(
      failure.technicalDetails(developerMode: true)?
        .contains("models[3].quantization") == true)
    #expect(
      failure.technicalDetails(developerMode: true)?
        .contains("production_manifest_incompatible") == true)
  }

  @Test func manifestDomainErrorsMapToStableActionablePresentations() {
    let cases: [(ModelManifestError, String)] = [
      (.missing, "production_manifest_missing"),
      (.productionSelectionPending, "production_selection_pending"),
      (.unknownProductionModel("missing-model"), "production_model_unknown"),
      (
        .invalidProductionConfiguration("quantization is invalid"),
        "production_configuration_invalid"
      ),
    ]

    for (error, code) in cases {
      let failure = FailurePresentation.productionConfiguration(error)
      #expect(failure.code == code)
      #expect(failure.title == "SQL model unavailable")
      #expect(failure.message.contains("build"))
      #expect(failure.message.contains("Install") || failure.message.contains("install"))
      #expect(!failure.message.contains("missing-model"))
      #expect(!failure.message.contains("quantization"))
      #expect(failure.technicalDetails(developerMode: false) == nil)
    }
  }

  @Test func unreadableAndUnexpectedBootstrapFailuresHaveDistinctCodes() {
    let unreadable = FailurePresentation.productionConfiguration(
      CocoaError(.fileReadNoPermission))
    #expect(unreadable.code == "production_manifest_unreadable")
    #expect(unreadable.message.contains("Reinstall"))

    let unexpected = FailurePresentation.productionConfiguration(
      DiagnosticsTestError.failed("MLX initialization failed"))
    #expect(unexpected.code == "production_bootstrap_unexpected")
    #expect(unexpected.message.contains("contact support"))
    #expect(unexpected.message != unreadable.message)
  }

  @Test func productionBootstrapLogsOneFailureWithPrivateDetails() {
    let recorder = DiagnosticEventRecorder()
    let result = ProductionModelBootstrap.load(
      diagnostics: recorder.client
    ) {
      throw manifestDecodingError()
    }

    guard case .failure(let failure) = result else {
      Issue.record("expected production bootstrap failure")
      return
    }
    #expect(failure.code == "production_manifest_incompatible")
    #expect(recorder.events.count == 1)
    #expect(recorder.events.first?.level == .error)
    #expect(recorder.events.first?.category == .configuration)
    #expect(recorder.events.first?.code == failure.code)
    #expect(recorder.events.first?.details?.contains("models[3].quantization") == true)
  }

  @Test func productionBootstrapLogsSuccessfulSelectionWithoutUserData() throws {
    let recorder = DiagnosticEventRecorder()
    let production = ProductionGenerationConfiguration(
      model: Self.model,
      gcd: .on,
      temperature: 0,
      topP: 1,
      topK: 0,
      maxTokens: 512,
      candidateCount: 3,
      sampleTemperature: 0.7,
      alwaysVote: true)

    let result = ProductionModelBootstrap.load(
      diagnostics: recorder.client
    ) {
      production
    }

    #expect(try result.get() == production)
    #expect(recorder.events.count == 1)
    #expect(recorder.events.first?.level == .info)
    #expect(recorder.events.first?.category == .configuration)
    #expect(recorder.events.first?.code == "production_configuration_loaded")
    #expect(recorder.events.first?.context["model_key"] == Self.model.key)
    #expect(recorder.events.first?.context["revision"] == Self.model.revision)
    #expect(recorder.events.first?.details == nil)
  }

  @Test func unavailablePipelineSeparatesUserMessageFromDiagnostic() async throws {
    let pipeline = QueryPipeline.unavailable(
      userMessage: "This build contains an incompatible model configuration. Rebuild and reinstall CREG.",
      diagnosticCode: "production_manifest_incompatible",
      diagnostic: "Missing key at models[3].quantization")

    let terminal = try #require(
      terminalEvent(await Array(pipeline.run("question", []))))
    guard case .failed(let message) = terminal.0 else {
      Issue.record("expected failed outcome")
      return
    }
    #expect(message.contains("Rebuild and reinstall CREG"))
    #expect(!message.contains("quantization"))
    #expect(
      terminal.1.terminalError
        == "[production_manifest_incompatible] Missing key at models[3].quantization")
  }

  @Test func terminalModelGenerationFailureLogsExactlyOnce() async throws {
    let recorder = DiagnosticEventRecorder()
    let pipeline = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: SQLGenClient { _ in
        throw DiagnosticsTestError.failed("weights could not be loaded")
      },
      db: DatabaseClient { _ in
        Issue.record("database must not run after generation failure")
        return QueryResult(columns: [], rows: [])
      },
      serializer: InferenceSerializer(),
      configuration: configuration()
    ).reportingTerminalFailures(to: recorder.client)

    let terminal = try #require(
      terminalEvent(await Array(pipeline.run("question", []))))
    guard case .failed(let message) = terminal.0 else {
      Issue.record("expected failed outcome")
      return
    }
    #expect(message.contains("SQL model couldn’t run"))
    #expect(!message.contains("weights"))
    #expect(
      terminal.1.terminalError?.contains(
        "[pipeline_model_generation_failed]") == true)
    #expect(recorder.events.map(\.code) == ["pipeline_model_generation_failed"])
  }

  @Test func terminalDatabaseFailureLogsExactlyOnce() async throws {
    let recorder = DiagnosticEventRecorder()
    let pipeline = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: SQLGenClient { _ in
        SQLGeneration(
          sql: "SELECT broken",
          tokensPerSecond: 1,
          modelName: "test")
      },
      db: DatabaseClient { _ in
        throw DiagnosticsTestError.failed("no such column: broken")
      },
      serializer: InferenceSerializer(),
      configuration: configuration()
    ).reportingTerminalFailures(to: recorder.client)

    let terminal = try #require(
      terminalEvent(await Array(pipeline.run("question", []))))
    guard case .failed(let message) = terminal.0 else {
      Issue.record("expected failed outcome")
      return
    }
    #expect(message.contains("valid portfolio query"))
    #expect(!message.contains("broken"))
    #expect(recorder.events.map(\.code) == ["pipeline_database_execution_failed"])
    #expect(recorder.events.first?.details?.contains("no such column") == true)
  }

  @Test func unavailablePortfolioDatabaseGetsSpecificTerminalFailure() async throws {
    let recorder = DiagnosticEventRecorder()
    let pipeline = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: SQLGenClient { _ in
        SQLGeneration(sql: "SELECT 1", tokensPerSecond: 1, modelName: "test")
      },
      db: .unavailableBundledPortfolioDatabase(
        diagnostic: "creg.sqlite is missing"),
      serializer: InferenceSerializer(),
      configuration: configuration()
    ).reportingTerminalFailures(to: recorder.client)

    let terminal = try #require(
      terminalEvent(await Array(pipeline.run("question", []))))
    guard case .failed(let message) = terminal.0 else {
      Issue.record("expected failed outcome")
      return
    }
    #expect(message.contains("portfolio data is unavailable"))
    #expect(!message.contains("sqlite"))
    #expect(recorder.events.map(\.code) == ["pipeline_portfolio_database_unavailable"])
  }

  @Test func databaseFailureClassificationDoesNotScrapeDiagnosticText() async throws {
    let recorder = DiagnosticEventRecorder()
    let pipeline = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: SQLGenClient { _ in
        SQLGeneration(sql: "SELECT 1", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient { _ in
        throw DiagnosticsTestError.failed(
          "[portfolio_database_unavailable] user-controlled text")
      },
      serializer: InferenceSerializer(),
      configuration: configuration()
    ).reportingTerminalFailures(to: recorder.client)

    _ = await Array(pipeline.run("question", []))
    #expect(recorder.events.map(\.code) == ["pipeline_database_execution_failed"])
  }

  @Test func foundationModelTerminalFailureIncludesStageWithoutQuestion() async throws {
    let recorder = DiagnosticEventRecorder()
    let fm = FMClient(
      availability: { .available },
      rewrite: { question, _ in
        throw DiagnosticsTestError.failed(
          "rewrite service failed for \(question)")
      },
      gate: { _, _ in .proceed },
      narrate: { _, _ in "unused" })
    let pipeline = QueryPipeline.live(
      fm: fm,
      sqlGen: SQLGenClient { _ in
        Issue.record("generation must not run after rewrite failure")
        return SQLGeneration(sql: "", tokensPerSecond: 0, modelName: "test")
      },
      db: DatabaseClient { _ in QueryResult(columns: [], rows: []) },
      serializer: InferenceSerializer(),
      configuration: configuration()
    ).reportingTerminalFailures(to: recorder.client)

    let question = "private portfolio question"
    let history = [ConversationTurn(question: "prior", answerSummary: "answer")]
    _ = await Array(pipeline.run(question, history))

    #expect(recorder.events.map(\.code) == ["pipeline_foundation_model_failed"])
    #expect(recorder.events.first?.context["stage"] == "rewrite")
    #expect(!recorder.events.first!.summary.contains(question))
    #expect(!recorder.events.first!.context.values.contains(question))
    #expect(recorder.events.first?.details?.contains(question) == false)
  }

  @Test func oneCharacterQuestionOnlyRedactsExplicitlyLabelledContent() async {
    let recorder = DiagnosticEventRecorder()
    let source = QueryPipeline { question, _ in
      AsyncStream { continuation in
        var telemetry = TurnTelemetry(originalQuestion: question)
        telemetry.terminalError = "failure code x remained; question=Q"
        continuation.yield(.turnStarted(question: question))
        continuation.yield(.turnFinished(
          outcome: .failed(message: "failed"),
          telemetry: telemetry))
        continuation.finish()
      }
    }

    _ = await Array(source.reportingTerminalFailures(to: recorder.client)
      .run("Q", []))

    let details = recorder.events.first?.details ?? ""
    #expect(details.contains("failure code x remained"))
    #expect(!details.contains("question=Q"))
    #expect(details.contains("question=<redacted conversation content>"))
  }

  @Test func recoveredCandidateFailureDoesNotEmitTerminalLog() async throws {
    let recorder = DiagnosticEventRecorder()
    let attempts = LockIsolated(0)
    let pipeline = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: SQLGenClient { request in
        SQLGeneration(
          sql: request.repair == nil ? "SELECT broken" : "SELECT fixed",
          tokensPerSecond: 1,
          modelName: "test")
      },
      db: DatabaseClient { sql in
        if sql.contains("broken") {
          attempts.withValue { $0 += 1 }
          throw DiagnosticsTestError.failed("repairable SQL")
        }
        return QueryResult(columns: ["n"], rows: [[.integer(1)]])
      },
      serializer: InferenceSerializer(),
      configuration: configuration(maxRepairAttempts: 1)
    ).reportingTerminalFailures(to: recorder.client)

    let terminal = try #require(
      terminalEvent(await Array(pipeline.run("question", []))))
    guard case .answered = terminal.0 else {
      Issue.record("expected repaired answer")
      return
    }
    #expect(attempts.value == 1)
    #expect(recorder.events.isEmpty)
  }

  @Test func recoveredCandidateFailureDoesNotMaskNarrationFailure() async throws {
    let recorder = DiagnosticEventRecorder()
    let fm = FMClient(
      availability: { .available },
      rewrite: { question, _ in question },
      gate: { _, _ in .proceed },
      narrate: { _, _ in
        throw DiagnosticsTestError.failed("narration service failed")
      })
    let pipeline = QueryPipeline.live(
      fm: fm,
      sqlGen: SQLGenClient { request in
        SQLGeneration(
          sql: request.repair == nil ? "SELECT broken" : "SELECT fixed",
          tokensPerSecond: 1,
          modelName: "test")
      },
      db: DatabaseClient { sql in
        if sql.contains("broken") {
          throw DiagnosticsTestError.failed("repairable SQL")
        }
        return QueryResult(columns: ["n"], rows: [[.integer(1)]])
      },
      serializer: InferenceSerializer(),
      configuration: configuration(maxRepairAttempts: 1)
    ).reportingTerminalFailures(to: recorder.client)

    _ = await Array(pipeline.run("question", []))

    #expect(recorder.events.map(\.code) == ["pipeline_foundation_model_failed"])
    #expect(recorder.events.first?.context["stage"] == "narration")
    #expect(recorder.events.first?.details?.contains("narration service failed") == true)
  }

  @Test func unexpectedTerminalFailureUsesStableFallback() async throws {
    let recorder = DiagnosticEventRecorder()
    let source = QueryPipeline { question, _ in
      AsyncStream { continuation in
        var telemetry = TurnTelemetry(originalQuestion: question)
        telemetry.terminalError = "unexpected low-level failure"
        continuation.yield(.turnStarted(question: question))
        continuation.yield(.turnFinished(
          outcome: .failed(message: "unexpected low-level failure"),
          telemetry: telemetry))
        continuation.finish()
      }
    }

    let terminal = try #require(terminalEvent(
      await Array(source.reportingTerminalFailures(to: recorder.client)
        .run("question", []))))
    guard case .failed(let message) = terminal.0 else {
      Issue.record("expected failed outcome")
      return
    }

    #expect(message.contains("couldn’t finish"))
    #expect(!message.contains("low-level"))
    #expect(recorder.events.map(\.code) == ["pipeline_unexpected_failure"])
    #expect(
      terminal.1.terminalError
        == "[pipeline_unexpected_failure] unexpected low-level failure")
  }

  @Test func cancelledPipelineDoesNotEmitTerminalLog() async {
    let recorder = DiagnosticEventRecorder()
    let source = QueryPipeline { question, _ in
      AsyncStream { continuation in
        continuation.yield(.turnStarted(question: question))
      }
    }
    let pipeline = source.reportingTerminalFailures(to: recorder.client)
    let task = Task {
      for await _ in pipeline.run("question", []) {}
    }

    await Task.yield()
    task.cancel()
    await task.value

    #expect(recorder.events.isEmpty)
  }
}

@MainActor
@Suite struct FeatureFailureDiagnosticsTests {
  private func history(
    load: @escaping @Sendable () async throws -> (UUID, [ChatMessage]) = {
      (UUID(), [])
    },
    appendMessage: @escaping @Sendable (UUID, ChatMessage) async throws -> Void = {
      _, _ in
    },
    appendEvents: @escaping @Sendable (UUID, UUID, [String]) async throws -> Void = {
      _, _, _ in
    },
    export: @escaping @Sendable (UUID) async throws -> URL = { _ in
      FileManager.default.temporaryDirectory
    }
  ) -> HistoryClient {
    HistoryClient(
      loadCurrentConversation: load,
      appendMessage: appendMessage,
      appendEvents: appendEvents,
      exportJSONL: export)
  }

  @Test func historyLoadFailureIsLoggedAndPresented() async {
    let recorder = DiagnosticEventRecorder()
    let store = TestStore(initialState: ChatFeature.State()) {
      ChatFeature()
    } withDependencies: {
      $0.historyClient = history(load: {
        throw DiagnosticsTestError.failed("database could not be opened")
      })
      $0.diagnostics = recorder.client
    }
    store.exhaustivity = .off

    await store.send(.onAppear)
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.presentedFailure?.code == "history_load_failed")
    #expect(store.state.presentedFailure?.title == "History unavailable")
    #expect(
      store.state.presentedFailure?.technicalDetails(developerMode: false) == nil)
    #expect(recorder.events.map(\.code) == ["history_load_failed"])
  }

  @Test func exportFailureIsLoggedAndPresented() async {
    let recorder = DiagnosticEventRecorder()
    var initialState = ChatFeature.State()
    initialState.conversationID = UUID()
    let store = TestStore(initialState: initialState) {
      ChatFeature()
    } withDependencies: {
      $0.historyClient = history(export: { _ in
        throw DiagnosticsTestError.failed("temporary directory is unavailable")
      })
      $0.diagnostics = recorder.client
    }
    store.exhaustivity = .off

    await store.send(.exportTapped)
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.presentedFailure?.code == "history_export_failed")
    #expect(store.state.presentedFailure?.title == "Export failed")
    #expect(recorder.events.map(\.code) == ["history_export_failed"])
  }

  @Test func messageAndEventSaveFailuresAreLogged() async {
    let recorder = DiagnosticEventRecorder()
    var initialState = ChatFeature.State()
    initialState.conversationID = UUID()
    initialState.modelReadiness = .ready
    let store = TestStore(initialState: initialState) {
      ChatFeature()
    } withDependencies: {
      $0.queryPipeline = QueryPipeline { question, _ in
        AsyncStream { continuation in
          var telemetry = TurnTelemetry(originalQuestion: question)
          telemetry.standaloneQuestion = question
          continuation.yield(.turnFinished(
            outcome: .failed(message: "Please try again."),
            telemetry: telemetry))
          continuation.finish()
        }
      }
      $0.historyClient = history(
        appendMessage: { _, _ in
          throw DiagnosticsTestError.failed("message write failed")
        },
        appendEvents: { _, _, _ in
          throw DiagnosticsTestError.failed("event write failed")
        })
      $0.diagnostics = recorder.client
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    await store.send(.binding(.set(\.composerText, "question")))
    await store.send(.sendTapped)
    await store.finish()
    await store.skipReceivedActions()

    #expect(recorder.events.map(\.code).contains("history_message_save_failed"))
    #expect(recorder.events.map(\.code).contains("history_event_save_failed"))
    #expect(store.state.presentedFailure?.title == "Conversation not saved")
  }

  @Test func dismissFailureClearsTheBanner() async {
    var initialState = ChatFeature.State()
    initialState.presentedFailure = FailurePresentation(
      code: "history_export_failed",
      title: "Export failed",
      message: "Try again.",
      diagnostic: "disk full")
    let store = TestStore(initialState: initialState) {
      ChatFeature()
    }

    await store.send(.dismissFailure) {
      $0.presentedFailure = nil
    }
  }
}
