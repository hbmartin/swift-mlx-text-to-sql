import CREGEngine
import ComposableArchitecture
import Foundation

@Reducer
public struct ChatFeature: Sendable {
  public enum ModelReadiness: Sendable, Equatable {
    case preparing
    case ready
    case failed(message: String)
  }

  @ObservableState
  public struct State: Equatable {
    public var messages: IdentifiedArrayOf<ChatMessage> = []
    public var composerText = ""
    public var isProcessing = false
    /// Keyboard-candidate protection owned by the reducer so every cancel and
    /// commit path is deterministic and testable.
    public var isSubmissionPending = false
    public var modelReadiness: ModelReadiness = .preparing
    /// Trace lines accumulating for the in-flight turn.
    public var currentTrace: [String] = []
    /// JSONL lines accumulating for the in-flight turn.
    public var currentEventLines: [String] = []
    public var developerMode = false
    public var isSettingsPresented = false
    public var conversationID: UUID?
    /// Set after a successful export, consumed by the share sheet.
    public var exportURL: URL?
    public var presentedFailure: FailurePresentation?

    public init() {}
  }

  public enum Action: BindableAction, Sendable, Equatable {
    case binding(BindingAction<State>)
    case onAppear
    case retryPreparation
    case modelPrepared
    case modelPreparationFailed(String)
    case historyLoaded(conversationID: UUID, messages: [ChatMessage])
    case submissionRequested
    case submissionFocusSettled
    case submissionRefocused
    case sendTapped
    case pipelineEvent(PipelineEvent)
    case exportTapped
    case exportReady(URL)
    case operationFailed(FailurePresentation)
    case dismissFailure
  }

  @Dependency(\.queryPipeline) var pipeline
  @Dependency(\.historyClient) var history
  @Dependency(\.uuid) var uuid
  @Dependency(\.date.now) var now
  @Dependency(\.diagnostics) var diagnostics

  public init() {}

  public var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .onAppear:
        diagnostics.info(
          category: .submission,
          code: "chat_appeared",
          summary: "The chat surface appeared.",
          context: [
            "has_conversation": String(state.conversationID != nil),
            "message_count": String(state.messages.count),
          ])
        state.modelReadiness = .preparing
        let prepare = preparationEffect()
        guard state.conversationID == nil else { return prepare }
        return .merge(
          prepare,
          .run { send in
            let (id, messages) = try await history.loadCurrentConversation()
            await send(.historyLoaded(conversationID: id, messages: messages))
          } catch: { error, send in
            await send(.operationFailed(.history(
              operation: .load, error: error)))
          })

      case .retryPreparation:
        diagnostics.info(
          category: .submission,
          code: "model_preparation_retry_requested",
          summary: "The user requested another model preparation attempt.")
        state.modelReadiness = .preparing
        return preparationEffect()

      case .modelPrepared:
        state.modelReadiness = .ready
        diagnostics.info(
          category: .submission,
          code: "chat_model_ready",
          summary: "Chat submission is enabled because the SQL model is ready.")
        return .none

      case .modelPreparationFailed(let diagnostic):
        state.modelReadiness = .failed(
          message: "The SQL model couldn’t be prepared. Check storage and try again.")
        state.isSubmissionPending = false
        diagnostics.record(DiagnosticEvent(
          level: .error,
          category: .configuration,
          code: "model_preparation_failed",
          summary: "The SQL model could not be prepared.",
          details: diagnostic))
        return .none

      case .historyLoaded(let conversationID, let messages):
        state.conversationID = conversationID
        state.messages = IdentifiedArray(uniqueElements: messages)
        diagnostics.info(
          category: .history,
          code: "history_loaded",
          summary: "Conversation history loaded.",
          context: ["message_count": String(messages.count)])
        return .none

      case .submissionRequested:
        guard
          !state.isSubmissionPending,
          !state.isProcessing,
          state.modelReadiness == .ready,
          !state.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          diagnostics.info(
            category: .submission,
            code: "chat_submission_rejected",
            summary: "A chat submission request was not eligible to start.",
            context: [
              "has_content": String(
                !state.composerText.trimmingCharacters(
                  in: .whitespacesAndNewlines).isEmpty),
              "is_pending": String(state.isSubmissionPending),
              "is_processing": String(state.isProcessing),
              "readiness": readiness(state.modelReadiness),
            ])
          return .none
        }
        state.isSubmissionPending = true
        diagnostics.info(
          category: .submission,
          code: "chat_submission_pending",
          summary: "A chat submission is waiting for focus resignation.")
        return .none

      case .submissionRefocused:
        let wasPending = state.isSubmissionPending
        state.isSubmissionPending = false
        diagnostics.info(
          category: .submission,
          code: "chat_submission_refocus_cancelled",
          summary: "Composer refocus cancelled a pending submission.",
          context: ["was_pending": String(wasPending)])
        return .none

      case .submissionFocusSettled:
        guard state.isSubmissionPending else {
          diagnostics.info(
            category: .submission,
            code: "chat_submission_focus_settle_ignored",
            summary: "A focus-settled action had no pending submission.")
          return .none
        }
        state.isSubmissionPending = false
        diagnostics.info(
          category: .submission,
          code: "chat_submission_focus_settled",
          summary: "Focus resigned and the pending submission will commit.")
        return startSubmission(state: &state)

      case .sendTapped:
        state.isSubmissionPending = false
        diagnostics.info(
          category: .submission,
          code: "chat_send_tapped",
          summary: "The send action was invoked.")
        return startSubmission(state: &state)

      case .pipelineEvent(let event):
        if let line = event.traceLine {
          state.currentTrace.append(line)
        }
        if let json = try? event.jsonLine() {
          state.currentEventLines.append(json)
        }
        guard case .turnFinished(let outcome, let telemetry) = event
        else { return .none }

        let body: ChatMessage.Body =
          switch outcome {
          case .answered(let result, let narration, let sql, let notice):
            .answer(result: result, narration: narration, sql: sql, notice: notice)
          case .needsClarification(let question):
            .clarification(question)
          case .failed(let message):
            .failure(message)
          }
        let assistantMessage = ChatMessage(
          id: uuid(), role: .assistant, body: body,
          traceSteps: state.currentTrace, createdAt: now,
          devInfo: telemetry)
        state.messages.append(assistantMessage)
        state.isProcessing = false
        diagnostics.info(
          category: .submission,
          code: "chat_turn_rendered",
          summary: "The terminal pipeline outcome was rendered in chat.",
          context: [
            "outcome": outcomeName(outcome),
            "confidence": telemetry.confidence?.rawValue ?? "none",
            "generated_count": String(telemetry.generatedCount),
            "repair_attempts": String(telemetry.repairAttempts),
            "timeout_stage": timeoutStage(telemetry.timeoutStage),
          ])

        guard let conversationID = state.conversationID else { return .none }
        let lines = state.currentEventLines
        return .merge(
          .run { send in
            do {
              try await history.appendMessage(conversationID, assistantMessage)
            } catch {
              await send(.operationFailed(.history(
                operation: .messageSave, error: error)))
            }
          },
          .run { send in
            do {
              try await history.appendEvents(
                conversationID, assistantMessage.id, lines)
            } catch {
              await send(.operationFailed(.history(
                operation: .eventSave, error: error)))
            }
          })

      case .exportTapped:
        guard let conversationID = state.conversationID else { return .none }
        diagnostics.info(
          category: .history,
          code: "history_export_started",
          summary: "Conversation export started.")
        return .run { send in
          let url = try await history.exportJSONL(conversationID)
          await send(.exportReady(url))
        } catch: { error, send in
          await send(.operationFailed(.history(
            operation: .export, error: error)))
        }

      case .exportReady(let url):
        state.exportURL = url
        diagnostics.info(
          category: .history,
          code: "history_export_finished",
          summary: "Conversation export finished.")
        return .none

      case .operationFailed(let failure):
        state.presentedFailure = failure
        diagnostics.record(DiagnosticEvent(
          level: .error,
          category: .history,
          code: failure.code,
          summary: failure.title,
          details: failure.diagnostic))
        return .none

      case .dismissFailure:
        let code = state.presentedFailure?.code ?? "none"
        state.presentedFailure = nil
        diagnostics.info(
          category: .submission,
          code: "failure_presentation_dismissed",
          summary: "A failure presentation was dismissed.",
          context: ["failure_code": code])
        return .none
      }
    }
  }

  private func startSubmission(state: inout State) -> Effect<Action> {
    let question = state.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !question.isEmpty,
      !state.isProcessing,
      state.modelReadiness == .ready
    else { return .none }
    state.composerText = ""
    state.isProcessing = true
    state.currentTrace = []
    state.currentEventLines = []

    let userMessage = ChatMessage(
      id: uuid(), role: .user, body: .text(question), createdAt: now)
    state.messages.append(userMessage)
    let conversationID = state.conversationID
    let turns = Self.conversationTurns(from: state.messages)
    diagnostics.info(
      category: .submission,
      code: "chat_submission_committed",
      summary: "A chat submission started a pipeline turn.",
      context: [
        "history_turn_count": String(turns.count),
        "message_count": String(state.messages.count),
      ])
    return .merge(
      .run { send in
        if let conversationID {
          do {
            try await history.appendMessage(conversationID, userMessage)
          } catch {
            await send(.operationFailed(.history(
              operation: .messageSave, error: error)))
          }
        }
      },
      .run { send in
        for await event in pipeline.run(question, turns) {
          await send(.pipelineEvent(event))
        }
      }
    )
  }

  private func preparationEffect() -> Effect<Action> {
    .run { send in
      try await pipeline.prepare()
      await send(.modelPrepared)
    } catch: { error, send in
      await send(.modelPreparationFailed(DiagnosticDetails.describe(error)))
    }
  }

  private func readiness(_ readiness: ModelReadiness) -> String {
    switch readiness {
    case .preparing: "preparing"
    case .ready: "ready"
    case .failed: "failed"
    }
  }

  private func outcomeName(_ outcome: TurnOutcome) -> String {
    switch outcome {
    case .answered: "answered"
    case .needsClarification: "needs_clarification"
    case .failed: "failed"
    }
  }

  private func timeoutStage(_ stage: String?) -> String {
    guard let stage else { return "none" }
    return switch stage {
    case "turn", "generation", "validation", "execution", "grounding",
      "rewrite", "gate", "narration", "cancelled":
      stage
    default:
      "unknown"
    }
  }

  /// Prior answered exchanges, oldest first, for the FM follow-up rewrite.
  static func conversationTurns(from messages: IdentifiedArrayOf<ChatMessage>) -> [ConversationTurn] {
    var turns: [ConversationTurn] = []
    var pendingQuestion: String?
    for message in messages {
      switch (message.role, message.body) {
      case (.user, .text(let question)):
        pendingQuestion = question
      case (.assistant, .answer(_, let narration, _, _)):
        if let question = pendingQuestion {
          turns.append(ConversationTurn(question: question, answerSummary: narration))
          pendingQuestion = nil
        }
      default:
        break
      }
    }
    return turns
  }
}

// MARK: - Dependencies

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

extension DependencyValues {
  public var queryPipeline: QueryPipeline {
    get { self[QueryPipeline.self] }
    set { self[QueryPipeline.self] = newValue }
  }

  public var historyClient: HistoryClient {
    get { self[HistoryClient.self] }
    set { self[HistoryClient.self] = newValue }
  }
}

/// Builds the live dependency graph exactly once. The single
/// ``InferenceSerializer`` shared by FM and MLX calls is the PRD §7.1
/// "never overlap" guarantee.
private enum LiveDependencies {
  static let diagnostics = DiagnosticsClient.live
  static let serializer = InferenceSerializer(diagnostics: diagnostics)

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
      let configuration = try ModelManifestLoader.production(url: bundledManifest)
      guard let bundledReceipt, let bundledModelDirectory else {
        throw ModelManifestError.missingReceipt
      }
      guard configuration.policyVersion == "bounded-three-generation-v1" else {
        throw ModelManifestError.invalidProductionConfiguration(
          "Every build requires schema-v3 bounded-policy evidence")
      }
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
    let sqlGen = SQLGenClient.live(directory: bundledModelDirectory)
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
        diagnostics.record(DiagnosticEvent(
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
      diagnostics.record(DiagnosticEvent(
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
      diagnostics.record(DiagnosticEvent(
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
