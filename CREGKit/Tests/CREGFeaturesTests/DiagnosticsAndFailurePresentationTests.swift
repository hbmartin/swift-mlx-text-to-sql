import CREGTestSupport
import ComposableArchitecture
import Foundation
import Testing

@testable import CREGCore
@testable import CREGData
@testable import CREGEngine
@testable import CREGFeatures
@testable import CREGInference

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
      (.missingRuntimeContract, "production_runtime_contract_missing"),
      (
        .unsupportedRuntimeContract(expected: 1, actual: 2),
        "production_runtime_contract_unsupported"
      ),
      (
        .runtimeProvenanceMismatch,
        "production_runtime_provenance_mismatch"
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
      userMessage:
        "This build contains an incompatible model configuration. Rebuild and reinstall CREG.",
      diagnosticCode: "production_manifest_incompatible",
      diagnostic: "Missing key at models[3].quantization")

    let terminal = try #require(
      terminalEvent(await Array(pipeline.run("question", []))))
    guard case .failed(let reason) = terminal.0 else {
      Issue.record("expected failed outcome")
      return
    }
    #expect(
      reason
        == .pipelineUnavailable(
          userMessage:
            "This build contains an incompatible model configuration. Rebuild and reinstall CREG."
        ))
    let presentation = FailurePresentation.turnFailure(reason)
    // The transcript renders the bootstrap failure's authored guidance, and
    // the developer diagnostic never leaks into the user-facing copy.
    #expect(
      presentation.message
        == "This build contains an incompatible model configuration. Rebuild and reinstall CREG."
    )
    #expect(!presentation.message.contains("quantization"))
    #expect(
      terminal.1.terminalError
        == "[production_manifest_incompatible] Missing key at models[3].quantization")
  }

  @Test func terminalModelGenerationFailureLogsExactlyOnce() async throws {
    let recorder = DiagnosticEventRecorder()
    let pipeline = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: testSQLGenClient { _ in
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
    guard case .failed(let reason) = terminal.0 else {
      Issue.record("expected failed outcome")
      return
    }
    #expect(reason == .generationFailed)
    #expect(
      !FailurePresentation.turnFailure(reason).message.contains("weights"))
    #expect(
      terminal.1.terminalError?.contains(
        "[pipeline_model_generation_failed]") == true)
    #expect(recorder.events.map(\.code) == ["pipeline_model_generation_failed"])
  }

  @Test func terminalDatabaseFailureLogsExactlyOnce() async throws {
    let recorder = DiagnosticEventRecorder()
    let pipeline = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: testSQLGenClient { _ in
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
    guard case .failed(let reason) = terminal.0 else {
      Issue.record("expected failed outcome")
      return
    }
    #expect(reason == .generationExhausted)
    #expect(
      !FailurePresentation.turnFailure(reason).message.contains("broken"))
    // The diagnostics code derives from the typed reason — the same taxonomy
    // the failure_reason context carries — never from telemetry sniffing.
    #expect(recorder.events.map(\.code) == ["pipeline_generation_exhausted"])
    #expect(
      recorder.events.first?.context["failure_reason"]
        == "generation_exhausted")
    #expect(recorder.events.first?.details?.contains("no such column") == true)
  }

  @Test func unavailablePortfolioDatabaseGetsSpecificTerminalFailure() async throws {
    let recorder = DiagnosticEventRecorder()
    let pipeline = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: testSQLGenClient { _ in
        SQLGeneration(sql: "SELECT 1", tokensPerSecond: 1, modelName: "test")
      },
      db: .unavailableBundledPortfolioDatabase(
        diagnostic: "creg.sqlite is missing"),
      serializer: InferenceSerializer(),
      configuration: configuration()
    ).reportingTerminalFailures(to: recorder.client)

    let terminal = try #require(
      terminalEvent(await Array(pipeline.run("question", []))))
    guard case .failed(let reason) = terminal.0 else {
      Issue.record("expected failed outcome")
      return
    }
    #expect(reason == .databaseUnavailable)
    #expect(
      !FailurePresentation.turnFailure(reason).message.contains("sqlite"))
    #expect(recorder.events.map(\.code) == ["pipeline_portfolio_database_unavailable"])
  }

  @Test func databaseFailureClassificationDoesNotScrapeDiagnosticText() async throws {
    let recorder = DiagnosticEventRecorder()
    let pipeline = QueryPipeline.live(
      fm: .fallback(),
      sqlGen: testSQLGenClient { _ in
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
    #expect(recorder.events.map(\.code) == ["pipeline_generation_exhausted"])
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
      narrate: { _, _ in "unused" },
      suggestFollowUps: { _, _ in [] })
    let pipeline = QueryPipeline.live(
      fm: fm,
      sqlGen: testSQLGenClient { _ in
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
        continuation.yield(
          .turnFinished(
            outcome: .failed(reason: .unexpected),
            telemetry: telemetry))
        continuation.finish()
      }
    }

    _ = await Array(
      source.reportingTerminalFailures(to: recorder.client)
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
      sqlGen: testSQLGenClient { request in
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
      },
      suggestFollowUps: { _, _ in [] })
    let pipeline = QueryPipeline.live(
      fm: fm,
      sqlGen: testSQLGenClient { request in
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
        continuation.yield(
          .turnFinished(
            outcome: .failed(reason: .unexpected),
            telemetry: telemetry))
        continuation.finish()
      }
    }

    let terminal = try #require(
      terminalEvent(
        await Array(
          source.reportingTerminalFailures(to: recorder.client)
            .run("question", []))))
    guard case .failed(let reason) = terminal.0 else {
      Issue.record("expected failed outcome")
      return
    }

    #expect(reason == .unexpected)
    #expect(
      !FailurePresentation.turnFailure(reason).message.contains("low-level"))
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
        continuation.yield(
          .generationStarted(
            request: SQLGenerationRequest(
              candidateID: CandidateID(rawValue: "initial"),
              role: .initial,
              model: Self.model,
              question: question,
              gcd: .on,
              temperature: 0,
              seed: nil)))
        continuation.yield(
          .turnFinished(
            outcome: .failed(reason: .timedOut(stage: "generation")),
            telemetry: telemetry))
        continuation.finish()
      }
    }

    _ = await Array(
      source.reportingTerminalFailures(to: recorder.client)
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
        continuation.yield(
          .generationFinished(
            candidateID: request.candidateID,
            generation: SQLGeneration(
              sql: privateSQL,
              tokensPerSecond: 1,
              modelName: "test",
              tokenCount: 1,
              elapsedMicroseconds: 1_000)))
        continuation.yield(
          .validationStarted(
            candidateID: request.candidateID))
        continuation.yield(
          .validationFinished(
            candidateID: request.candidateID,
            report: report))
        continuation.yield(
          .executionFailed(
            candidateID: request.candidateID,
            message: message,
            attempt: 0))
        continuation.yield(
          .turnFinished(
            outcome: .failed(reason: .unexpected),
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

  @Test func followUpPreparationDiagnosticsShareAPrivateTrace() async {
    let recorder = DiagnosticEventRecorder()
    let privateSourceID = UUID(5)
    let source = QueryPipeline(
      run: { _, _ in AsyncStream { $0.finish() } },
      prepareFollowUps: { _ in
        AsyncStream { continuation in
          let telemetry = FollowUpRejectionTelemetry(
            timeoutStage: "validation",
            stageTimings: StageTimings(totalMicroseconds: 12_000))
          continuation.yield(
            .proposalFailed(reason: .generationTimedOut))
          continuation.yield(
            .rejected(
              rank: 2,
              reason: .validationTimedOut,
              telemetry: telemetry))
          continuation.yield(.finished)
          continuation.finish()
        }
      }
    )
    .reportingOperations(to: recorder.client)
    let context = FollowUpSuggestionContext(
      sourceAssistantMessageID: privateSourceID,
      question: "private original question",
      standaloneQuestion: "private standalone question",
      narration: "private narration",
      result: QueryResult(
        columns: ["private_column"],
        rows: [[.text("private row")]]))

    _ = await Array(source.prepareFollowUps(context))

    let events = recorder.events.filter {
      $0.code.hasPrefix("follow_up_")
    }
    let traceIDs = Set(events.compactMap { $0.context["trace_id"] })
    #expect(traceIDs.count == 1)
    #expect(traceIDs.first?.isEmpty == false)
    #expect(traceIDs.first != "<redacted identifier>")
    #expect(events.allSatisfy { $0.context["source_message_id"] == nil })
    let failure = events.first { $0.code == "follow_up_proposal_failed" }
    #expect(failure?.level == .error)
    #expect(failure?.context["reason"] == "generationTimedOut")
    #expect(
      failure?.summary == "Follow-up candidate proposal generation timed out.")
    let rejection = events.first { $0.code == "follow_up_candidate_rejected" }
    #expect(rejection?.context["rank"] == "2")
    #expect(rejection?.context["reason"] == "validationTimedOut")
    #expect(
      rejection?.summary
        == "Follow-up candidate rejected: SQL validation timed out.")
    #expect(rejection?.context["timeout_stage"] == "validation")
    #expect(rejection?.context["candidate_count"] == "0")
    #expect(rejection?.context["elapsed_ms"] == "12.0")
    let rendered = events.map(String.init(describing:)).joined(separator: "\n")
    for privateValue in [
      privateSourceID.uuidString,
      "private original question",
      "private standalone question",
      "private narration",
      "private_column",
      "private row",
    ] {
      #expect(!rendered.contains(privateValue))
    }
  }

  @Test func followUpPreparationWithoutFinishedIsReportedAsAnError() async {
    let recorder = DiagnosticEventRecorder()
    let source = QueryPipeline(
      run: { _, _ in AsyncStream { $0.finish() } },
      prepareFollowUps: { _ in
        AsyncStream { continuation in
          continuation.yield(.started(candidateCount: 1))
          continuation.finish()
        }
      }
    )
    .reportingOperations(to: recorder.client)
    let context = FollowUpSuggestionContext(
      sourceAssistantMessageID: UUID(6),
      question: "question",
      standaloneQuestion: "question",
      narration: "answer",
      result: QueryResult(columns: [], rows: []))

    _ = await Array(source.prepareFollowUps(context))

    let failure = recorder.events.last
    #expect(failure?.code == "pipeline_stream_ended_without_terminal_event")
    #expect(failure?.level == .error)
    #expect(failure?.context["accepted_count"] == "0")
    #expect(failure?.context["elapsed_ms"] != nil)
    #expect(failure?.context["trace_id"] != nil)
  }

  @Test func cancelledFollowUpPreparationHasATerminalDiagnostic() async {
    let recorder = DiagnosticEventRecorder()
    let sourceEvents = AsyncStream<FollowUpPreparationEvent>.makeStream()
    let source = QueryPipeline(
      run: { _, _ in AsyncStream { $0.finish() } },
      prepareFollowUps: { _ in sourceEvents.stream }
    )
    .reportingOperations(to: recorder.client)
    let context = FollowUpSuggestionContext(
      sourceAssistantMessageID: UUID(6),
      question: "question",
      standaloneQuestion: "question",
      narration: "answer",
      result: QueryResult(columns: [], rows: []))
    let consumer = Task {
      await Array(source.prepareFollowUps(context))
    }

    sourceEvents.continuation.yield(.started(candidateCount: 1))
    for _ in 0..<100 {
      if recorder.events.contains(where: {
        $0.code == "follow_up_candidates_proposed"
      }) {
        break
      }
      await Task.yield()
    }
    consumer.cancel()
    _ = await consumer.value
    for _ in 0..<100 {
      if recorder.events.contains(where: {
        $0.code == "follow_up_preparation_cancelled"
      }) {
        break
      }
      await Task.yield()
    }
    sourceEvents.continuation.finish()

    let cancellation = recorder.events.first {
      $0.code == "follow_up_preparation_cancelled"
    }
    #expect(cancellation?.context["accepted_count"] == "0")
    #expect(cancellation?.context["elapsed_ms"] != nil)
    #expect(cancellation?.context["trace_id"] != nil)
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
      sqlGen: testSQLGenClient { _ in
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

    let terminal = try #require(
      terminalEvent(
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
          continuation.yield(
            .generationFinished(
              candidateID: request.candidateID,
              generation: SQLGeneration(
                sql: privateSQL,
                tokensPerSecond: 8,
                modelName: "/private/model/path",
                tokenCount: 4,
                elapsedMicroseconds: 1_000)))
          continuation.yield(
            .validationStarted(
              candidateID: request.candidateID))
          continuation.yield(
            .validationFinished(
              candidateID: request.candidateID,
              report: SQLValidationReport(elapsedMicroseconds: 500)))
          continuation.yield(
            .executionStarted(
              candidateID: request.candidateID,
              sql: privateSQL))
          continuation.yield(
            .executionFinished(
              candidateID: request.candidateID,
              result: result))
          continuation.yield(
            .selfConsistencyFinished(
              .consensus(
                resultDigest: "private-result-digest",
                agreement: 2,
                candidateCount: 3)))
          continuation.yield(
            .narrationFinished(
              narration: privateNarration,
              usedFM: true,
              elapsedMicroseconds: 3_000))
          continuation.yield(
            .turnFinished(
              outcome: .answered(
                result: result,
                narration: privateNarration,
                sql: privateSQL,
                notice: nil),
              telemetry: telemetry))
          continuation.finish()
        }
      }
    )
    .reportingOperations(to: recorder.client)

    _ = try? await source.prepare()
    _ = await Array(
      source.run(
        privateQuestion,
        [
          ConversationTurn(
            question: "prior private question", answerSummary: "prior private answer")
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

  @Test func operationalTerminalSummariesExposeRepairStateWithoutPayloads() async {
    let recorder = DiagnosticEventRecorder()
    let privateQuestion = "private lease ownership question"
    let privateSQL = "SELECT l.private_name FROM leases l"
    let privateError = "no such column: l.private_name"
    let issue = SQLValidationIssue(
      kind: .binding,
      disposition: .repairable,
      message: privateError)
    let guidance = RepairGuidance(
      issue: issue,
      invalidReference: "l.private_name",
      invalidQualifier: "l",
      invalidColumn: "private_name",
      declaredSources: ["leases"],
      possibleColumnOwners: ["tenants", "properties"],
      sourceColumns: ["leases": ["lease_id", "tenant_id", "property_id"]],
      relevantForeignKeys: [
        "leases.tenant_id -> tenants.tenant_id",
        "leases.property_id -> properties.property_id",
      ],
      correctiveInstruction: "Use an owning table.",
      failedFingerprints: ["private-fingerprint"])
    let repairContext = RepairContext(
      failedSQL: privateSQL,
      errorMessage: privateError,
      guidance: guidance)

    func request(
      id: String,
      role: CandidateRole,
      repair: RepairContext? = nil,
      temperature: Double = 0,
      seed: UInt64? = nil
    ) -> SQLGenerationRequest {
      SQLGenerationRequest(
        candidateID: CandidateID(rawValue: id),
        role: role,
        model: Self.model,
        question: privateQuestion,
        repair: repair,
        gcd: .off,
        temperature: temperature,
        seed: seed,
        maxTokens: 64)
    }

    let initialRequest = request(id: "private-initial-id", role: .initial)
    var initial = CandidateTelemetry(request: initialRequest)
    initial.sql = privateSQL
    initial.sqlFingerprint = "private-initial-fingerprint"
    initial.tokensPerSecond = 8
    initial.tokenCount = 4
    initial.speculation = SQLSpeculationMetrics(
      roundCount: 2,
      draftTokenCount: 4,
      acceptedDraftTokenCount: 3,
      targetModelCallCount: 2,
      targetVerifiedTokenCount: 4,
      emittedTokenCount: 5)
    initial.generationMicroseconds = 1_000
    initial.validationReport = SQLValidationReport(
      issue: issue,
      elapsedMicroseconds: 500)
    initial.error = privateError

    let duplicateRequest = request(
      id: "private-repair-one-id",
      role: .repair(attempt: 1),
      repair: repairContext)
    var duplicate = CandidateTelemetry(request: duplicateRequest)
    duplicate.sql = privateSQL
    duplicate.sqlFingerprint = "private-duplicate-fingerprint"
    duplicate.validationReport = SQLValidationReport(
      issue: issue,
      elapsedMicroseconds: 600)
    duplicate.error = privateError
    duplicate.duplicateOf = initial.id
    duplicate.duplicateSuppressed = true

    let repairedRequest = request(
      id: "private-repair-two-id",
      role: .repair(attempt: 2),
      repair: repairContext,
      temperature: 0.35,
      seed: 42)
    var repaired = CandidateTelemetry(request: repairedRequest)
    repaired.sql = "SELECT lease_id FROM leases"
    repaired.sqlFingerprint = "private-repaired-fingerprint"
    repaired.tokensPerSecond = 7
    repaired.tokenCount = 6
    repaired.generationMicroseconds = 2_000
    repaired.validationReport = SQLValidationReport(elapsedMicroseconds: 700)
    repaired.executionMicroseconds = 800
    repaired.result = QueryResult(
      columns: ["lease_id"],
      rows: [[.integer(1)]],
      elapsedMicroseconds: 800)
    repaired.resultDigest = "private-result-digest"
    repaired.selected = true

    let telemetry: TurnTelemetry = {
      var value = TurnTelemetry(originalQuestion: privateQuestion)
      value.candidates = [initial, duplicate, repaired]
      value.generatedCount = 3
      value.repairAttempts = 2
      value.repairPolicyVersion = "binding-repair-v2"
      value.recoveryOutcome = .repaired
      value.selectedCandidateID = repaired.id
      value.selectionReason = .repairSuccess
      value.confidence = .unconfirmed
      value.stageTimings.totalMicroseconds = 10_000
      return value
    }()
    let repairedResult = repaired.result!
    let repairedSQL = repaired.sql!
    let source = QueryPipeline { _, _ in
      AsyncStream { continuation in
        continuation.yield(.turnStarted(question: privateQuestion))
        continuation.yield(.generationStarted(request: initialRequest))
        continuation.yield(.generationStarted(request: duplicateRequest))
        continuation.yield(.generationStarted(request: repairedRequest))
        continuation.yield(
          .turnFinished(
            outcome: .answered(
              result: repairedResult,
              narration: "private narration",
              sql: repairedSQL,
              notice: nil),
            telemetry: telemetry))
        continuation.finish()
      }
    }.reportingOperations(to: recorder.client)

    _ = await Array(source.run(privateQuestion, []))

    let events = recorder.events
    let summaries = events.filter {
      $0.code == "pipeline_candidate_summary"
    }
    let generationSummaries = events.filter {
      $0.code == "pipeline_candidate_generation_summary"
    }
    let speculationSummaries = events.filter {
      $0.code == "pipeline_candidate_speculation_summary"
    }
    #expect(summaries.count == 3)
    #expect(generationSummaries.count == 3)
    #expect(speculationSummaries.count == 1)
    #expect(Set(events.compactMap { $0.context["trace_id"] }).count == 1)
    #expect(events.allSatisfy { $0.context["query_origin"] == "freeForm" })
    #expect(summaries.map { $0.context["candidate_sequence"] } == ["1", "2", "3"])
    let repairInputs = events.filter { $0.code == "pipeline_repair_input" }
    #expect(repairInputs.count == 2)
    #expect(
      repairInputs.allSatisfy {
        $0.context["guidance_present"] == "true"
      })
    #expect(
      repairInputs.allSatisfy {
        $0.context["possible_owner_count"] == "2"
      })
    #expect(
      repairInputs.allSatisfy {
        $0.context["relevant_foreign_key_count"] == "2"
      })

    let initialSummary = summaries[0].context
    #expect(initialSummary["validation_state"] == "invalid")
    #expect(initialSummary["issue_kind"] == "binding")
    #expect(initialSummary["execution_state"] == "not_started")
    #expect(initialSummary["error_present"] == "true")
    #expect(
      speculationSummaries[0].context["speculation_acceptance_percent"]
        == "75.0")

    let duplicateSummary = summaries[1].context
    #expect(duplicateSummary["duplicate_suppressed"] == "true")
    #expect(duplicateSummary["duplicate_of_sequence"] == "1")
    #expect(generationSummaries[1].context["repair_guidance_present"] == "true")
    #expect(
      generationSummaries[1].context["repair_failed_fingerprint_count"] == "1")

    let repairedSummary = summaries[2].context
    #expect(generationSummaries[2].context["temperature"] == "0.350")
    #expect(generationSummaries[2].context["seed"] == "42")
    #expect(repairedSummary["validation_state"] == "valid")
    #expect(repairedSummary["execution_state"] == "succeeded")
    #expect(repairedSummary["row_count"] == "1")
    #expect(repairedSummary["selected"] == "true")

    let turn = events.first { $0.code == "pipeline_turn_finished" }
    #expect(turn?.context["candidate_count"] == "3")
    #expect(turn?.context["selected_candidate_sequence"] == "3")
    #expect(turn?.context["repair_policy_version"] == "binding-repair-v2")
    #expect(turn?.context["recovery_outcome"] == "repaired")

    let rendered = events.map(String.init(describing:)).joined(separator: "\n")
    for privateValue in [
      privateQuestion, privateSQL, privateError,
      "private_name", "private-fingerprint", "private-result-digest",
      "private-initial-id", "private-repair-one-id", "private-repair-two-id",
    ] {
      #expect(!rendered.contains(privateValue))
    }
  }

  @Test func modelLoadLoggingHasStableSuccessAndFailureEvents() async {
    let recorder = DiagnosticEventRecorder()
    let success = SQLGenClient(
      prepare: {},
      schemaPrompt: { "test schema" },
      generate: { _ in
        SQLGeneration(sql: "", tokensPerSecond: 0, modelName: "test")
      }
    )
    .reportingModelLoad(to: recorder.client, modelKey: "test-model")
    _ = try? await success.prepare()

    let failure = SQLGenClient(
      prepare: {
        throw DiagnosticsTestError.failed(
          "weights unavailable at /private/model/weights.safetensors")
      },
      schemaPrompt: { "test schema" },
      generate: { _ in
        SQLGeneration(sql: "", tokensPerSecond: 0, modelName: "test")
      }
    )
    .reportingModelLoad(to: recorder.client, modelKey: "test-model")
    await #expect(throws: (any Error).self) {
      try await failure.prepare()
    }

    #expect(
      recorder.events.map(\.code) == [
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
    #expect(
      recorder.events.map(\.code) == [
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
      _ =
        try await serializer.run(operation: .sqlGeneration) {
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
