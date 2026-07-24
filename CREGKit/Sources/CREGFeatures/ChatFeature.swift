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

    public init() {}
  }

  public enum Action: BindableAction, Sendable {
    case binding(BindingAction<State>)
    case onAppear
    case historyLoaded(conversationID: UUID, messages: [ChatMessage])
    case sendTapped
    case starterQuestionTapped(String)
    case stopTapped
    case pipelineEvent(PipelineEvent)
    case exportTapped
    case exportReady(URL)
  }

  private enum CancelID { case pipeline }

  @Dependency(\.queryPipeline) var pipeline
  @Dependency(\.historyClient) var history
  @Dependency(\.uuid) var uuid
  @Dependency(\.date.now) var now

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
        } catch: { _, _ in }

      case .historyLoaded(let conversationID, let messages):
        state.conversationID = conversationID
        state.messages = IdentifiedArray(uniqueElements: messages)
        return .none

      case .sendTapped:
        return submitComposer(&state)

      case .starterQuestionTapped(let question):
        guard !state.isProcessing else { return .none }
        state.composerText = question
        return submitComposer(&state)

      case .stopTapped:
        guard state.isProcessing else { return .none }
        state.isProcessing = false
        let stoppedMessage = ChatMessage(
          id: uuid(), role: .assistant,
          body: .text("Stopped — ask again whenever you're ready."),
          traceSteps: state.currentTrace, createdAt: now)
        state.messages.append(stoppedMessage)
        state.currentTrace = []
        let lines = state.currentEventLines
        state.currentEventLines = []
        guard let conversationID = state.conversationID else {
          return .cancel(id: CancelID.pipeline)
        }
        return .merge(
          .cancel(id: CancelID.pipeline),
          .run { _ in
            try await history.appendMessage(conversationID, stoppedMessage)
            try await history.appendEvents(conversationID, stoppedMessage.id, lines)
          } catch: { _, _ in }
        )

      case .pipelineEvent(let event):
        // A late event racing a stop must not resurrect the turn.
        guard state.isProcessing else { return .none }
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
        return .run { _ in
          try await history.appendMessage(conversationID, assistantMessage)
          try await history.appendEvents(conversationID, assistantMessage.id, lines)
        } catch: { _, _ in }

      case .exportTapped:
        guard let conversationID = state.conversationID else { return .none }
        return .run { send in
          let url = try await history.exportJSONL(conversationID)
          await send(.exportReady(url))
        } catch: { _, _ in }

      case .exportReady(let url):
        state.exportURL = url
        return .none
      }
    }
  }

  /// Starts a turn from the composer text; shared by the send button and the
  /// starter-question chips. The pipeline effect is cancellable so Stop can
  /// end the turn (the stream's onTermination cancels the underlying task).
  private func submitComposer(_ state: inout State) -> Effect<Action> {
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
      .run { _ in
        if let conversationID {
          try? await history.appendMessage(conversationID, userMessage)
        }
      },
      .run { send in
        for await event in pipeline.run(question, turns) {
          await send(.pipelineEvent(event))
        }
      }
      .cancellable(id: CancelID.pipeline, cancelInFlight: true)
    )
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

  static let pipeline: QueryPipeline = {
    let production: ProductionGenerationConfiguration
    do {
      production = try ModelManifestLoader.production()
    } catch {
      return .unavailable(
        message:
          "The production model is not configured: \(error.localizedDescription)")
    }

    let db: DatabaseClient
    if let url = Bundle.main.url(forResource: "creg", withExtension: "sqlite"),
      let client = try? DatabaseClient.live(url: url)
    {
      db = client
    } else {
      db = DatabaseClient { _ in
        throw NSError(
          domain: "CREG", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "creg.sqlite is missing from the app bundle"])
      }
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
    )
  }()

  static let history: HistoryClient = {
    let url = URL.applicationSupportDirectory
      .appendingPathComponent("CREG", isDirectory: true)
      .appendingPathComponent("history.sqlite")
    return (try? HistoryClient.live(databaseURL: url)) ?? .noop()
  }()
}
