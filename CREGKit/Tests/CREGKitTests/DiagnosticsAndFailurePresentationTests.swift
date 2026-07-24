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
    #expect(
      DiagnosticPrivacy.redact("SQL: SELECT\nCASE WHEN active THEN 1 ELSE 0 END FROM leases")
        == "SQL=<redacted SQL>")
    #expect(DiagnosticPrivacy.redact("SELECT -amount FROM leases") == "<redacted SQL>")
    #expect(DiagnosticPrivacy.redact("SELECT NOT active FROM leases") == "<redacted SQL>")
    let caseInstruction = "Select case studies before retrying."
    #expect(DiagnosticPrivacy.redact(caseInstruction) == caseInstruction)
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

  @Test func diagnosticBoundaryAlsoSanitizesPublicContextValues() {
    let recorder = DiagnosticEventRecorder()
    let identifier = "5f70da4c-e71f-4b6a-b4e8-6e37fa393ce2"
    recorder.client.info(
      category: .pipeline,
      code: "privacy_probe",
      summary: "Privacy probe.",
      context: [
        "path_probe": "/private/model/weights.safetensors",
        "identifier_probe": identifier,
        "sql_probe": "SELECT secret FROM leases",
      ])

    let context = recorder.events.first?.context ?? [:]
    #expect(context["path_probe"] == "<redacted path>")
    #expect(context["identifier_probe"] == "<redacted identifier>")
    #expect(context["sql_probe"] == "<redacted SQL>")
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

  @Test func deadlineFailureUsesStableStageCode() async {
    let recorder = DiagnosticEventRecorder()
    let source = QueryPipeline { question, _ in
      AsyncStream { continuation in
        var telemetry = TurnTelemetry(originalQuestion: question)
        telemetry.timeoutStage = "generation"
        telemetry.terminalError = "pipeline deadline exceeded during generation"
        continuation.yield(.turnStarted(question: question))
        continuation.yield(.generationStarted(request: SQLGenerationRequest(
          candidateID: CandidateID(rawValue: "initial"),
          role: .initial,
          model: Self.model,
          question: question,
          gcd: .on,
          temperature: 0,
          seed: nil)))
        continuation.yield(.turnFinished(
          outcome: .failed(message: "timeout"),
          telemetry: telemetry))
        continuation.finish()
      }
    }

    _ = await Array(source.reportingTerminalFailures(to: recorder.client)
      .run("private question", []))

    #expect(recorder.events.map(\.code) == ["pipeline_deadline_exceeded"])
    #expect(recorder.events.first?.context["timeout_stage"] == "generation")
    #expect(recorder.events.first?.details?.contains("private question") == false)
  }

  @Test func operationalCandidateFailureIncludesExactStageTimingAndSafeDetails()
    async
  {
    let recorder = DiagnosticEventRecorder()
    let privateQuestion = "private portfolio vacancy question"
    let privateSQL = "SELECT secret_value FROM private_table"
    let request = SQLGenerationRequest(
      candidateID: CandidateID(rawValue: "initial"),
      role: .initial,
      model: Self.model,
      question: privateQuestion,
      gcd: .on,
      temperature: 0,
      seed: nil,
      maxTokens: 64)
    let message =
      "validation rejected question=\(privateQuestion) at /private/db.sqlite; SQL: \(privateSQL)"
    let report = SQLValidationReport(
      issue: SQLValidationIssue(
        kind: .binding,
        disposition: .repairable,
        message: message),
      elapsedMicroseconds: 2_000)
    var candidate = CandidateTelemetry(request: request)
    candidate.sql = privateSQL
    candidate.error = message
    candidate.generationMicroseconds = 1_000
    candidate.validationReport = report
    let telemetry: TurnTelemetry = {
      var telemetry = TurnTelemetry(originalQuestion: privateQuestion)
      telemetry.candidates = [candidate]
      telemetry.generatedCount = 1
      telemetry.terminalError = message
      telemetry.stageTimings.totalMicroseconds = 4_000
      return telemetry
    }()

    let source = QueryPipeline { _, _ in
      AsyncStream { continuation in
        continuation.yield(.turnStarted(question: privateQuestion))
        continuation.yield(.generationStarted(request: request))
        continuation.yield(.generationFinished(
          candidateID: request.candidateID,
          generation: SQLGeneration(
            sql: privateSQL,
            tokensPerSecond: 1,
            modelName: "test",
            tokenCount: 1,
            elapsedMicroseconds: 1_000)))
        continuation.yield(.validationStarted(
          candidateID: request.candidateID))
        continuation.yield(.validationFinished(
          candidateID: request.candidateID,
          report: report))
        continuation.yield(.executionFailed(
          candidateID: request.candidateID,
          message: message,
          attempt: 0))
        continuation.yield(.turnFinished(
          outcome: .failed(message: "Try again."),
          telemetry: telemetry))
        continuation.finish()
      }
    }.reportingOperations(to: recorder.client)

    _ = await Array(source.run(privateQuestion, []))

    let failure = recorder.events.first {
      $0.code == "pipeline_candidate_failed"
    }
    #expect(failure?.level == .error)
    #expect(failure?.context["candidate_role"] == "initial")
    #expect(failure?.context["failure_stage"] == "validation")
    #expect(failure?.context["issue_kind"] == "binding")
    #expect(failure?.context["disposition"] == "repairable")
    #expect(failure?.context["generation_elapsed_ms"] == "1.0")
    #expect(failure?.context["validation_elapsed_ms"] == "2.0")
    #expect(failure?.context["candidate_elapsed_ms"] != nil)
    #expect(failure?.context["stage_elapsed_ms"] != nil)
    #expect(failure?.context["turn_elapsed_ms"] != nil)
    #expect(failure?.details?.contains(privateQuestion) == false)
    #expect(failure?.details?.contains(privateSQL) == false)
    #expect(failure?.details?.contains("/private/db.sqlite") == false)
    #expect(
      failure?.details?.contains("<redacted conversation content>") == true)
    #expect(failure?.details?.contains("<redacted SQL>") == true)
    #expect(failure?.details?.contains("<redacted path>") == true)
  }

  @Test func operationalStreamWithoutTerminalEventIsReportedAsAnError() async {
    let recorder = DiagnosticEventRecorder()
    let source = QueryPipeline { question, _ in
      AsyncStream { continuation in
        continuation.yield(.turnStarted(question: question))
        continuation.finish()
      }
    }.reportingOperations(to: recorder.client)

    _ = await Array(source.run("question", []))

    let failure = recorder.events.last
    #expect(failure?.code == "pipeline_stream_ended_without_terminal_event")
    #expect(failure?.level == .error)
    #expect(failure?.context["cancelled"] == "false")
    #expect(failure?.context["event_count"] == "1")
    #expect(failure?.context["terminal_event_seen"] == "false")
    #expect(failure?.context["turn_elapsed_ms"] != nil)
  }

  @Test func liveGenerationDeadlineExplainsLimitAndCancellationCleanup()
    async throws
  {
    let recorder = DiagnosticEventRecorder()
    var config = configuration()
    config.deadlines = PipelineDeadlines(
      generationSeconds: 0.01,
      wholeTurnSeconds: 1)
    let pipeline = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: SQLGenClient { _ in
        try await Task.sleep(for: .milliseconds(100))
        return SQLGeneration(
          sql: "SELECT 1", tokensPerSecond: 1, modelName: "test")
      },
      db: DatabaseClient { _ in
        Issue.record("database must not run after a generation deadline")
        return QueryResult(columns: [], rows: [])
      },
      serializer: InferenceSerializer(diagnostics: recorder.client),
      configuration: config
    ).reportingOperations(to: recorder.client)

    let terminal = try #require(terminalEvent(
      await Array(pipeline.run("question", []))))
    #expect(terminal.1.timeoutStage == "generation")

    let candidateFailure = recorder.events.first {
      $0.code == "pipeline_candidate_failed"
    }
    #expect(candidateFailure?.context["failure_stage"] == "generation")
    #expect(candidateFailure?.context["candidate_role"] == "initial")
    #expect(candidateFailure?.context["candidate_elapsed_ms"] != nil)
    #expect(candidateFailure?.details?.contains("deadline_ms=10.0") == true)
    #expect(
      candidateFailure?.details?.contains("cancellation cleanup") == true)

    let deadline = recorder.events.first {
      $0.code == "pipeline_deadline_exceeded"
    }
    #expect(deadline?.context["timeout_stage"] == "generation")
    #expect(deadline?.context["candidate_role"] == "initial")
    #expect(deadline?.context["total_elapsed_ms"] != nil)
    #expect(deadline?.details?.contains("deadline_ms=10.0") == true)
    #expect(recorder.events.map(\.code).contains("inference_failed"))
  }

  @Test func operationalPipelineLogsMetadataWithoutPayloads() async {
    let recorder = DiagnosticEventRecorder()
    let privateQuestion = "private vacancy question"
    let privateSQL = "SELECT secret_value FROM private_table"
    let privateNarration = "Secret portfolio narration"
    let privateRow = "private row value"
    let privateIdentifier = "5f70da4c-e71f-4b6a-b4e8-6e37fa393ce2"
    let model = Self.model
    let request = SQLGenerationRequest(
      candidateID: CandidateID(rawValue: privateIdentifier),
      role: .initial,
      model: model,
      question: privateQuestion,
      gcd: .on,
      temperature: 0,
      seed: nil,
      maxTokens: 64)
    let result = QueryResult(
      columns: ["secret_column"],
      rows: [[.text(privateRow)]],
      elapsedMicroseconds: 2_000)
    let telemetry: TurnTelemetry = {
      var value = TurnTelemetry(originalQuestion: privateQuestion)
      value.generatedCount = 1
      value.confidence = .confirmed
      value.selectionReason = .majorityVote
      value.stageTimings.totalMicroseconds = 9_000
      return value
    }()
    let source = QueryPipeline(
      prepare: {},
      run: { _, _ in
        AsyncStream { continuation in
          continuation.yield(.turnStarted(question: privateQuestion))
          continuation.yield(.generationStarted(request: request))
          continuation.yield(.generationFinished(
            candidateID: request.candidateID,
            generation: SQLGeneration(
              sql: privateSQL,
              tokensPerSecond: 8,
              modelName: "/private/model/path",
              tokenCount: 4,
              elapsedMicroseconds: 1_000)))
          continuation.yield(.validationStarted(
            candidateID: request.candidateID))
          continuation.yield(.validationFinished(
            candidateID: request.candidateID,
            report: SQLValidationReport(elapsedMicroseconds: 500)))
          continuation.yield(.executionStarted(
            candidateID: request.candidateID,
            sql: privateSQL))
          continuation.yield(.executionFinished(
            candidateID: request.candidateID,
            result: result))
          continuation.yield(.selfConsistencyFinished(.consensus(
            resultDigest: "private-result-digest",
            agreement: 2,
            candidateCount: 3)))
          continuation.yield(.narrationFinished(
            narration: privateNarration,
            usedFM: true,
            elapsedMicroseconds: 3_000))
          continuation.yield(.turnFinished(
            outcome: .answered(
              result: result,
              narration: privateNarration,
              sql: privateSQL,
              notice: nil),
            telemetry: telemetry))
          continuation.finish()
        }
      })
      .reportingOperations(to: recorder.client)

    try? await source.prepare()
    _ = await Array(source.run(privateQuestion, [
      ConversationTurn(question: "prior private question", answerSummary: "prior private answer")
    ]))

    let events = recorder.events
    let rendered = events.map(String.init(describing:)).joined(separator: "\n")
    for secret in [
      privateQuestion, privateSQL, privateNarration, privateRow,
      privateIdentifier, "secret_column", "private-result-digest",
      "/private/model/path", "prior private question", "prior private answer",
    ] {
      #expect(!rendered.contains(secret))
    }
    #expect(events.map(\.code).contains("pipeline_preparation_finished"))
    #expect(events.map(\.code).contains("pipeline_generation_finished"))
    #expect(events.map(\.code).contains("pipeline_validation_finished"))
    #expect(events.map(\.code).contains("pipeline_execution_finished"))
    #expect(events.map(\.code).contains("pipeline_voting_finished"))
    #expect(events.map(\.code).contains("pipeline_turn_finished"))
    #expect(
      events.first(where: { $0.code == "pipeline_execution_finished" })?
        .context["row_count"] == "1")
  }

  @Test func modelLoadLoggingHasStableSuccessAndFailureEvents() async {
    let recorder = DiagnosticEventRecorder()
    let success = SQLGenClient(
      prepare: {},
      generate: { _ in
        SQLGeneration(sql: "", tokensPerSecond: 0, modelName: "test")
      })
      .reportingModelLoad(to: recorder.client, modelKey: "test-model")
    try? await success.prepare()

    let failure = SQLGenClient(
      prepare: {
        throw DiagnosticsTestError.failed(
          "weights unavailable at /private/model/weights.safetensors")
      },
      generate: { _ in
        SQLGeneration(sql: "", tokensPerSecond: 0, modelName: "test")
      })
      .reportingModelLoad(to: recorder.client, modelKey: "test-model")
    await #expect(throws: (any Error).self) {
      try await failure.prepare()
    }

    #expect(recorder.events.map(\.code) == [
      "model_load_started", "model_load_finished",
      "model_load_started", "model_load_failed",
    ])
    #expect(
      recorder.events.last?.details?.contains(
        "weights unavailable at <redacted path>") == true)
    #expect(
      recorder.events.last?.details?.contains(
        "/private/model/weights.safetensors") == false)
    #expect(recorder.events.allSatisfy { $0.context["model_key"] == "test-model" })
  }

  @Test func inferenceSerializerLogsTypedOperationAndTiming() async throws {
    let recorder = DiagnosticEventRecorder()
    let serializer = InferenceSerializer(diagnostics: recorder.client)

    let value = try await serializer.run(operation: .gate) { 42 }

    #expect(value == 42)
    #expect(recorder.events.map(\.code) == [
      "inference_started", "inference_finished",
    ])
    #expect(recorder.events.allSatisfy { $0.category == .inference })
    #expect(recorder.events.allSatisfy { $0.context["operation"] == "gate" })
    #expect(recorder.events.first?.context["wait_ms"] != nil)
    #expect(recorder.events.last?.context["total_elapsed_ms"] != nil)
    #expect(recorder.events.allSatisfy { $0.details == nil })
  }

  @Test func inferenceSerializerFailureIncludesSafeErrorClassification() async {
    let recorder = DiagnosticEventRecorder()
    let serializer = InferenceSerializer(diagnostics: recorder.client)

    await #expect(throws: (any Error).self) {
      _ = try await serializer.run(operation: .sqlGeneration) {
        throw DiagnosticsTestError.failed(
          "decoder weights unavailable at /private/model/weights.safetensors")
      } as Int
    }

    let failure = recorder.events.last
    #expect(failure?.code == "inference_failed")
    #expect(failure?.level == .error)
    #expect(failure?.context["operation"] == "sql_generation")
    #expect(failure?.context["error_type"]?.contains("DiagnosticsTestError") == true)
    #expect(failure?.context["is_cancellation"] == "false")
    #expect(failure?.context["total_elapsed_ms"] != nil)
    #expect(failure?.details?.contains("DiagnosticsTestError") == true)
    #expect(
      failure?.details?.contains("/private/model/weights.safetensors") == false)
    #expect(failure?.details?.contains("decoder weights unavailable") == false)
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
    #expect(recorder.events.map(\.code).contains("history_load_failed"))
    #expect(recorder.events.map(\.code).contains("chat_appeared"))
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
    #expect(recorder.events.map(\.code).contains("history_export_started"))
    #expect(recorder.events.map(\.code).contains("history_export_failed"))
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

  @Test func submissionLifecycleLogsNoQuestionOrIdentifiers() async {
    let recorder = DiagnosticEventRecorder()
    let question = "private on-device question"
    var initialState = ChatFeature.State()
    initialState.conversationID = UUID(0)
    initialState.modelReadiness = .ready
    initialState.composerText = question
    let store = TestStore(initialState: initialState) {
      ChatFeature()
    } withDependencies: {
      $0.queryPipeline = QueryPipeline { receivedQuestion, _ in
        AsyncStream { continuation in
          var telemetry = TurnTelemetry(originalQuestion: receivedQuestion)
          telemetry.generatedCount = 1
          continuation.yield(.turnFinished(
            outcome: .failed(message: "Try again."),
            telemetry: telemetry))
          continuation.finish()
        }
      }
      $0.historyClient = .noop()
      $0.diagnostics = recorder.client
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    await store.send(.submissionRequested)
    await store.send(.submissionFocusSettled)
    await store.finish()
    await store.skipReceivedActions()

    let rendered = recorder.events.map(String.init(describing:))
      .joined(separator: "\n")
    #expect(!rendered.contains(question))
    #expect(!rendered.contains(UUID(0).uuidString))
    #expect(recorder.events.map(\.code).contains("chat_submission_pending"))
    #expect(recorder.events.map(\.code).contains("chat_submission_focus_settled"))
    #expect(recorder.events.map(\.code).contains("chat_submission_committed"))
    #expect(recorder.events.map(\.code).contains("chat_turn_rendered"))
  }
}
