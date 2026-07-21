import CREGEngine
import ComposableArchitecture
import Foundation

@Reducer
public struct ChatFeature: Sendable {
  @ObservableState
  public struct State: Equatable {
    public var messages: IdentifiedArrayOf<ChatMessage> = []
    public var composerText = ""
    public var isProcessing = false
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

  public enum Action: BindableAction, Sendable {
    case binding(BindingAction<State>)
    case onAppear
    case historyLoaded(conversationID: UUID, messages: [ChatMessage])
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
        guard state.conversationID == nil else { return .none }
        return .run { send in
          let (id, messages) = try await history.loadCurrentConversation()
          await send(.historyLoaded(conversationID: id, messages: messages))
        } catch: { error, send in
          await send(.operationFailed(.history(
            operation: .load, error: error)))
        }

      case .historyLoaded(let conversationID, let messages):
        state.conversationID = conversationID
        state.messages = IdentifiedArray(uniqueElements: messages)
        return .none

      case .sendTapped:
        let question = state.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !state.isProcessing else { return .none }
        state.composerText = ""
        state.isProcessing = true
        state.currentTrace = []
        state.currentEventLines = []

        let userMessage = ChatMessage(id: uuid(), role: .user, body: .text(question), createdAt: now)
        state.messages.append(userMessage)
        let conversationID = state.conversationID

        let turns = Self.conversationTurns(from: state.messages)
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
        return .run { send in
          let url = try await history.exportJSONL(conversationID)
          await send(.exportReady(url))
        } catch: { error, send in
          await send(.operationFailed(.history(
            operation: .export, error: error)))
        }

      case .exportReady(let url):
        state.exportURL = url
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
        state.presentedFailure = nil
        return .none
      }
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
  static let serializer = InferenceSerializer()
  static let diagnostics = DiagnosticsClient.live

  static let pipeline: QueryPipeline = {
    let production: ProductionGenerationConfiguration
    let productionResult = ProductionModelBootstrap.load(
      diagnostics: diagnostics
    ) {
      try ModelManifestLoader.production()
    }
    switch productionResult {
    case .success(let configuration):
      production = configuration
    case .failure(let failure):
      return .unavailable(
        userMessage: failure.message,
        diagnosticCode: failure.code,
        diagnostic: failure.diagnostic)
    }

    let db: DatabaseClient
    if let url = Bundle.main.url(forResource: "creg", withExtension: "sqlite") {
      do {
        db = try DatabaseClient.live(url: url)
      } catch {
        db = .unavailableBundledPortfolioDatabase(
          diagnostic: DiagnosticDetails.describe(error))
      }
    } else {
      db = .unavailableBundledPortfolioDatabase(
        diagnostic: "The bundled portfolio database resource is missing.")
    }
    return QueryPipeline.live(
      fm: .live(),
      sqlGen: .live(model: production.model),
      db: db,
      serializer: serializer,
      configuration: .init(
        production: production,
        gateSensitivity: 0,
        maxRepairAttempts: 2)
    ).reportingTerminalFailures(to: diagnostics)
  }()

  static let history: HistoryClient = {
    let url = URL.applicationSupportDirectory
      .appendingPathComponent("CREG", isDirectory: true)
      .appendingPathComponent("history.sqlite")
    do {
      return try HistoryClient.live(databaseURL: url)
    } catch {
      return .unavailable(
        diagnostic: DiagnosticDetails.describe(error))
    }
  }()
}

private struct BundledPortfolioDatabaseUnavailable:
  CustomStringConvertible, LocalizedError, Sendable
{
  var diagnostic: String

  var description: String { errorDescription ?? diagnostic }
  var errorDescription: String? {
    "[portfolio_database_unavailable] \(diagnostic)"
  }
}

private extension DatabaseClient {
  static func unavailableBundledPortfolioDatabase(
    diagnostic: String
  ) -> DatabaseClient {
    DatabaseClient { _ in
      throw BundledPortfolioDatabaseUnavailable(diagnostic: diagnostic)
    }
  }
}
