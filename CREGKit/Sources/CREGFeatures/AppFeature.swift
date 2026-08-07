import CREGEngine
import ComposableArchitecture
import Foundation

/// The app-level reducer around the Conversation reducer. Owns Conversation
/// summaries, selection, the reveal-behind Conversation Browser, model
/// readiness, unread state, the transient cross-conversation queue, background
/// completions, Settings, support export, and tagged pipeline events.
///
/// Scheduling follows ADR 0008: at most one query is active globally and it is
/// never preempted. At each completion the scheduler dispatches the oldest
/// Queued Question in the visible Conversation, falling back to the globally
/// oldest. The queue exists only for the current process.
@Reducer
public struct AppFeature: Sendable {
  public enum ModelReadiness: Sendable, Equatable {
    case preparing
    case ready
    case failed(message: String)
  }

  /// The single globally active turn.
  public struct ActiveTurn: Equatable, Sendable {
    public var questionID: UUID
    public var conversationID: UUID
    public var question: String
    public var starter: StarterQueryID?
    public var startedAt: Date
    /// Trace lines accumulating for the in-flight turn.
    public var trace: [String] = []
    /// JSONL lines accumulating for the in-flight turn.
    public var eventLines: [String] = []

    public init(
      questionID: UUID,
      conversationID: UUID,
      question: String,
      starter: StarterQueryID? = nil,
      startedAt: Date
    ) {
      self.questionID = questionID
      self.conversationID = conversationID
      self.question = question
      self.starter = starter
      self.startedAt = startedAt
    }
  }

  /// A deleted Conversation held for the five-second Undo window before the
  /// database delete commits.
  public struct PendingDeletion: Equatable, Sendable {
    public var summary: ConversationSummary
    public var index: Int

    public init(summary: ConversationSummary, index: Int) {
      self.summary = summary
      self.index = index
    }
  }

  /// The in-app banner for a background completion; never changes selection
  /// on its own.
  public struct AnswerReadyBanner: Equatable, Sendable {
    public var conversationID: UUID
    public var title: String

    public init(conversationID: UUID, title: String) {
      self.conversationID = conversationID
      self.title = title
    }
  }

  public struct SupportBundleExport: Equatable, Sendable {
    public var url: URL
    public var manifest: SupportBundleManifest

    public init(url: URL, manifest: SupportBundleManifest) {
      self.url = url
      self.manifest = manifest
    }
  }

  @ObservableState
  public struct State: Equatable {
    public var conversations: IdentifiedArrayOf<ConversationSummary> = []
    /// The selected Conversation's reducer state; nil only before bootstrap.
    public var chat: ChatFeature.State?
    public var isBrowserRevealed = false
    public var browserSearchText = ""
    public var searchHits: [ConversationSearchHit] = []
    public var pendingDeletion: PendingDeletion?
    public var modelReadiness: ModelReadiness = .preparing
    public var activeTurn: ActiveTurn?
    /// Session-only Queued Questions across all Conversations, oldest first.
    public var queue: [QueuedQuestion] = []
    public var answerReadyBanner: AnswerReadyBanner?
    public var isSettingsPresented = false
    public var developerMode = false
    /// The theme override. Unlike the app icon, nothing in the system holds
    /// this for us, so it is persisted in user defaults and hydrated from
    /// there when state is constructed.
    @Shared(.appStorage(AppearancePreference.storageKey))
    public var appearance: AppearancePreference = .system
    /// Mirrors the home-screen icon the system currently shows. Persistence is
    /// the system's job, so this is hydrated from it rather than stored.
    public var appIcon: AppIconVariant = .midnight
    public var supportsAlternateIcons = false
    public var isBuildingSupportBundle = false
    public var supportBundleExport: SupportBundleExport?
    public var presentedFailure: FailurePresentation?
    public var debugModelIdentity: DebugModelIdentity?
    /// Experimental physical-device benchmark input supplied at process
    /// launch. Ordinary Release builds always leave this nil.
    public var launchBenchmarkQuestion: String?
    public var launchBenchmarkStarted = false

    public init(
      debugModelIdentity: DebugModelIdentity? = nil,
      launchBenchmarkQuestion: String? = nil
    ) {
      // The experimental-model banner and the benchmark hook are deliberately
      // decoupled: a Beta build bundles an unfinalized candidate and must say
      // so, but must never auto-submit a question at launch.
      #if DEBUG || CREG_DEVICE_BENCHMARK || CREG_EXPERIMENTAL_MODEL
        self.debugModelIdentity = debugModelIdentity ?? Self.bundledDebugModelIdentity()
      #else
        self.debugModelIdentity = nil
      #endif
      #if DEBUG || CREG_DEVICE_BENCHMARK
        self.launchBenchmarkQuestion =
          launchBenchmarkQuestion
          ?? ProcessInfo.processInfo.environment["CREG_BENCHMARK_QUESTION"]
      #else
        self.launchBenchmarkQuestion = nil
      #endif
    }

    private static func bundledDebugModelIdentity() -> DebugModelIdentity? {
      guard
        let url = Bundle.main.url(
          forResource: "model-manifest", withExtension: "json")
      else { return nil }
      return try? ModelManifestLoader.production(
        url: url,
        allowDebugCandidate: true
      ).debugModelIdentity
    }

    /// Queued Questions belonging to one conversation, oldest first.
    public func queuedQuestions(in conversationID: UUID) -> [QueuedQuestion] {
      queue.filter { $0.conversationID == conversationID }
    }
  }

  public enum Action: BindableAction, Sendable, Equatable {
    case binding(BindingAction<State>)
    case onAppear
    case retryPreparation
    case modelPrepared
    case modelPreparationFailed(String)
    case bootstrapFinished([ConversationSummary])
    case conversationCreated(ConversationSummary)
    case conversationLoaded(ConversationSnapshot)
    case chat(ChatFeature.Action)
    case browserButtonTapped
    case browserDismissTapped
    case searchResults([ConversationSearchHit])
    case conversationSelected(UUID)
    case newChatTapped
    case deleteConversationTapped(UUID)
    case undoDeleteTapped
    case deleteCountdownFinished
    case answerReadyBannerTapped
    case answerReadyBannerTimedOut
    case pipelineEvent(conversationID: UUID, questionID: UUID, event: PipelineEvent)
    case supportBundleExportTapped
    case supportBundleReady(SupportBundleExport)
    case supportBundleDismissed
    case appIconLoaded(AppIconVariant, supportsAlternates: Bool)
    case appIconSelected(AppIconVariant)
    case appearanceSelected(AppearancePreference)
    case operationFailed(FailurePresentation)
    case dismissFailure
  }

  private enum CancelID {
    case pipeline
    case search
    case deleteCountdown
    case bannerTimeout
    case iconRead
  }

  @Dependency(\.queryPipeline) var pipeline
  @Dependency(\.historyClient) var history
  @Dependency(\.supportBundle) var supportBundle
  @Dependency(\.haptics) var haptics
  @Dependency(\.appIcon) var appIconClient
  @Dependency(\.uuid) var uuid
  @Dependency(\.date.now) var now
  @Dependency(\.continuousClock) var clock
  @Dependency(\.diagnostics) var diagnostics

  public init() {}

  public var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.browserSearchText):
        let query = state.browserSearchText
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
          state.searchHits = []
          return .cancel(id: CancelID.search)
        }
        return .run { send in
          try await clock.sleep(for: .milliseconds(250))
          let hits = try await history.search(query)
          await send(.searchResults(hits))
        } catch: { error, send in
          await send(
            .operationFailed(.history(operation: .search, error: error)))
        }
        .cancellable(id: CancelID.search, cancelInFlight: true)

      case .binding:
        return .none

      case .onAppear:
        diagnostics.info(
          category: .submission,
          code: "app_appeared",
          summary: "The app surface appeared.",
          context: ["has_selection": String(state.chat != nil)])
        state.modelReadiness = .preparing
        let prepare = preparationEffect()
        // The system owns which icon is showing, so read it back on every
        // appearance rather than trusting stored state.
        let readIcon = Effect<Action>.run { send in
          await send(
            .appIconLoaded(
              appIconClient.current(),
              supportsAlternates: appIconClient.supportsAlternates()))
        }
        .cancellable(id: CancelID.iconRead, cancelInFlight: true)
        guard state.chat == nil else { return .merge(prepare, readIcon) }
        return .merge(
          prepare,
          readIcon,
          .run { send in
            let summaries = try await history.bootstrap()
            await send(.bootstrapFinished(summaries))
          } catch: { error, send in
            await send(
              .operationFailed(.history(operation: .load, error: error)))
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
        return startLaunchBenchmarkIfReady(state: &state)

      case .modelPreparationFailed(let diagnostic):
        state.modelReadiness = .failed(
          message: "The SQL model couldn’t be prepared. Check storage and try again.")
        diagnostics.record(
          DiagnosticEvent(
            level: .error,
            category: .configuration,
            code: "model_preparation_failed",
            summary: "The SQL model could not be prepared.",
            details: diagnostic))
        return .none

      case .bootstrapFinished(let summaries):
        state.conversations = IdentifiedArray(uniqueElements: summaries)
        diagnostics.info(
          category: .history,
          code: "history_bootstrap_finished",
          summary: "Conversation summaries loaded.",
          context: ["conversation_count": String(summaries.count)])
        guard let mostRecent = summaries.first else {
          return createConversationEffect()
        }
        return loadConversationEffect(id: mostRecent.id)

      case .conversationCreated(let summary):
        state.conversations.insert(summary, at: 0)
        state.chat = ChatFeature.State(conversationID: summary.id)
        syncSchedulerProjection(into: &state)
        state.isBrowserRevealed = false
        return startLaunchBenchmarkIfReady(state: &state)

      case .conversationLoaded(let snapshot):
        state.chat = ChatFeature.State(snapshot: snapshot)
        syncSchedulerProjection(into: &state)
        state.isBrowserRevealed = false
        var effects: [Effect<Action>] = []
        if snapshot.summary.isUnread {
          state.conversations[id: snapshot.summary.id]?.isUnread = false
          let id = snapshot.summary.id
          effects.append(
            .run { _ in try? await history.setUnread(id, false) })
        }
        if state.answerReadyBanner?.conversationID == snapshot.summary.id {
          state.answerReadyBanner = nil
          effects.append(.cancel(id: CancelID.bannerTimeout))
        }
        effects.append(startLaunchBenchmarkIfReady(state: &state))
        return .merge(effects)

      case .browserButtonTapped, .chat(.delegate(.openBrowser)):
        state.isBrowserRevealed = true
        return .none

      case .browserDismissTapped:
        state.isBrowserRevealed = false
        return .none

      case .searchResults(let hits):
        state.searchHits = hits
        return .none

      case .conversationSelected(let id):
        guard state.chat?.conversationID != id else {
          state.isBrowserRevealed = false
          return .none
        }
        diagnostics.info(
          category: .history,
          code: "conversation_selected",
          summary: "A conversation was selected in the browser.")
        return loadConversationEffect(id: id)

      case .newChatTapped, .chat(.delegate(.newChatRequested)):
        return createConversationEffect()

      case .deleteConversationTapped(let id):
        guard let summary = state.conversations[id: id] else { return .none }
        return deleteConversation(state: &state, summary: summary)

      case .chat(.delegate(.deleteRequested)):
        guard let id = state.chat?.conversationID,
          let summary = state.conversations[id: id]
        else { return .none }
        return deleteConversation(state: &state, summary: summary)

      case .undoDeleteTapped:
        guard let pending = state.pendingDeletion else { return .none }
        state.pendingDeletion = nil
        let index = min(pending.index, state.conversations.count)
        state.conversations.insert(pending.summary, at: index)
        return .cancel(id: CancelID.deleteCountdown)

      case .deleteCountdownFinished:
        guard let pending = state.pendingDeletion else { return .none }
        state.pendingDeletion = nil
        let id = pending.summary.id
        return .run { send in
          do {
            try await history.deleteConversation(id)
          } catch {
            await send(
              .operationFailed(.history(operation: .delete, error: error)))
          }
        }

      case .answerReadyBannerTapped:
        guard let banner = state.answerReadyBanner else { return .none }
        state.answerReadyBanner = nil
        return .merge(
          .cancel(id: CancelID.bannerTimeout),
          loadConversationEffect(id: banner.conversationID))

      case .answerReadyBannerTimedOut:
        state.answerReadyBanner = nil
        return .none

      case .pipelineEvent(let conversationID, let questionID, let event):
        return handlePipelineEvent(
          state: &state,
          conversationID: conversationID,
          questionID: questionID,
          event: event)

      case .chat(.delegate(.submitQuestion(let question, let starter))):
        guard state.modelReadiness == .ready, let chat = state.chat
        else { return .none }
        let conversationID = chat.conversationID
        if state.activeTurn == nil {
          return dispatch(
            state: &state,
            conversationID: conversationID,
            question: question,
            starter: starter)
        }
        let queued = QueuedQuestion(
          id: uuid(),
          conversationID: conversationID,
          question: question,
          starter: starter,
          submittedAt: now)
        state.queue.append(queued)
        syncSchedulerProjection(into: &state)
        diagnostics.info(
          category: .submission,
          code: "question_queued",
          summary: "A submission became a queued question behind active work.",
          context: ["queue_depth": String(state.queue.count)])
        return .none

      case .chat(.delegate(.stopActiveTurn)):
        return stopActiveTurn(state: &state)

      case .chat(.delegate(.cancelQueued(let id))):
        state.queue.removeAll { $0.id == id }
        syncSchedulerProjection(into: &state)
        diagnostics.info(
          category: .submission,
          code: "queued_question_cancelled",
          summary: "A queued question was cancelled before dispatch.")
        return .none

      case .chat(.delegate(.renamed(let title))):
        guard let id = state.chat?.conversationID else { return .none }
        state.conversations[id: id]?.title = title
        state.conversations[id: id]?.isManuallyTitled = true
        return .none

      case .chat(.operationFailed(let failure)):
        return .send(.operationFailed(failure))

      case .chat:
        return .none

      case .supportBundleExportTapped:
        guard !state.isBuildingSupportBundle else { return .none }
        state.isBuildingSupportBundle = true
        diagnostics.info(
          category: .history,
          code: "support_bundle_started",
          summary: "A support bundle export started.")
        return .run { send in
          let source = try await history.supportBundleSource()
          let export = try await supportBundle.build(source)
          await send(.supportBundleReady(export))
        } catch: { error, send in
          await send(
            .operationFailed(
              .history(operation: .supportBundle, error: error)))
        }

      case .supportBundleReady(let export):
        state.isBuildingSupportBundle = false
        state.supportBundleExport = export
        diagnostics.info(
          category: .history,
          code: "support_bundle_finished",
          summary: "A support bundle export finished.",
          context: [
            "conversation_count": String(export.manifest.conversationCount),
            "entry_count": String(export.manifest.entries.count),
          ])
        return .none

      case .supportBundleDismissed:
        state.supportBundleExport = nil
        return .none

      case .appIconLoaded(let variant, let supportsAlternates):
        state.appIcon = variant
        state.supportsAlternateIcons = supportsAlternates
        return .none

      case .appIconSelected(let variant):
        guard state.appIcon != variant else { return .none }
        // Reflect the tap immediately; the system alert that follows makes a
        // spinner look broken, and a failure puts the old value back.
        let previous = state.appIcon
        let supportsAlternates = state.supportsAlternateIcons
        state.appIcon = variant
        diagnostics.info(
          category: .configuration,
          code: "app_icon_selected",
          summary: "An app icon change was requested.",
          context: ["icon": variant.rawValue])
        // A still-in-flight appearance read captured the pre-change icon and
        // would revert the selection if it landed after `select` succeeds, so
        // drop it and confirm from the system once the change applies.
        let select = Effect<Action>.run { send in
          try await appIconClient.select(variant)
          await send(
            .appIconLoaded(
              appIconClient.current(),
              supportsAlternates: appIconClient.supportsAlternates()))
        } catch: { error, send in
          await send(
            .appIconLoaded(previous, supportsAlternates: supportsAlternates))
          await send(
            .operationFailed(
              FailurePresentation(
                code: "app_icon_change_failed",
                title: "Icon not changed",
                message: "CREG couldn't change its icon. Please try again.",
                diagnostic: String(describing: error))))
        }
        return .merge(.cancel(id: CancelID.iconRead), select)

      case .appearanceSelected(let preference):
        guard state.appearance != preference else { return .none }
        state.$appearance.withLock { $0 = preference }
        diagnostics.info(
          category: .configuration,
          code: "appearance_preference_changed",
          summary: "The appearance override changed.",
          context: ["appearance": preference.rawValue])
        return .none

      case .operationFailed(let failure):
        state.presentedFailure = failure
        state.isBuildingSupportBundle = false
        diagnostics.record(
          DiagnosticEvent(
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
    .ifLet(\.chat, action: \.chat) {
      ChatFeature()
    }
  }

  // MARK: - Scheduler (ADR 0008)

  /// Starts a turn immediately. Callers guarantee no turn is active.
  private func dispatch(
    state: inout State,
    conversationID: UUID,
    question: String,
    starter: StarterQueryID?
  ) -> Effect<Action> {
    let questionID = uuid()
    let startedAt = now
    let userMessage = ChatMessage(
      id: uuid(), role: .user, body: .text(question), createdAt: startedAt)
    state.activeTurn = ActiveTurn(
      questionID: questionID,
      conversationID: conversationID,
      question: question,
      starter: starter,
      startedAt: startedAt)

    // Reflect the dispatch in whatever surfaces show this conversation.
    if state.chat?.conversationID == conversationID {
      state.chat?.messages.append(userMessage)
      if state.chat?.title.isEmpty == true,
        state.chat?.isManuallyTitled == false
      {
        state.chat?.title = HistoryStore.autoTitle(from: question)
      }
    }
    if var summary = state.conversations[id: conversationID] {
      if summary.title.isEmpty, !summary.isManuallyTitled {
        summary.title = HistoryStore.autoTitle(from: question)
      }
      summary.lastActivityAt = startedAt
      summary.latestMessagePreview = question
      summary.messageCount += 1
      state.conversations[id: conversationID] = summary
      state.conversations.sort { $0.lastActivityAt > $1.lastActivityAt }
    }
    syncSchedulerProjection(into: &state)

    diagnostics.info(
      category: .submission,
      code: "chat_submission_committed",
      summary: "A submission started a pipeline turn.",
      context: [
        "query_origin": starter == nil ? "free_form" : "starter",
        "queue_depth": String(state.queue.count),
      ])

    return .run { send in
      // Dispatch against the conversation's latest completed history
      // (ADR 0008), loaded before this turn's user message lands.
      let snapshot = try? await history.loadConversation(conversationID)
      let turns = ChatFeature.conversationTurns(from: snapshot?.messages ?? [])
      // Unstructured so a Stop cancellation cannot abort the user-message
      // write; the pipeline starts only after the write settles so turn
      // records land in transcript order.
      let persistDispatch = Task {
        try await history.appendMessage(conversationID, userMessage)
        try await history.beginTurnJournal(conversationID, question, startedAt)
      }
      do {
        try await persistDispatch.value
      } catch {
        await send(
          .operationFailed(.history(operation: .messageSave, error: error)))
      }
      guard !Task.isCancelled else { return }
      let events =
        starter.map { pipeline.runStarter($0, turns) }
        ?? pipeline.run(question, turns)
      for await event in events {
        await send(
          .pipelineEvent(
            conversationID: conversationID,
            questionID: questionID,
            event: event))
      }
    }
    .cancellable(id: CancelID.pipeline, cancelInFlight: true)
  }

  /// Visible-conversation priority: the oldest Queued Question in the
  /// selected Conversation, else the globally oldest.
  private func dispatchNextIfIdle(state: inout State) -> Effect<Action> {
    guard state.activeTurn == nil, state.modelReadiness == .ready
    else { return .none }
    let visibleID = state.chat?.conversationID
    let next =
      state.queue.first { $0.conversationID == visibleID }
      ?? state.queue.first
    guard let next else { return .none }
    state.queue.removeAll { $0.id == next.id }
    return dispatch(
      state: &state,
      conversationID: next.conversationID,
      question: next.question,
      starter: next.starter)
  }

  private func stopActiveTurn(state: inout State) -> Effect<Action> {
    guard let active = state.activeTurn,
      active.conversationID == state.chat?.conversationID
    else { return .none }
    state.activeTurn = nil
    let stoppedMessage = ChatMessage(
      id: uuid(), role: .assistant,
      body: .text("Stopped — ask again whenever you're ready."),
      traceSteps: active.trace, createdAt: now)
    state.chat?.messages.append(stoppedMessage)
    state.chat?.processing = nil
    updateSummaryAfterMessage(state: &state, conversationID: active.conversationID, message: stoppedMessage)
    diagnostics.info(
      category: .submission,
      code: "chat_turn_stopped",
      summary: "The user stopped the in-flight turn.",
      context: ["partial_event_count": String(active.eventLines.count)])
    let conversationID = active.conversationID
    let lines = active.eventLines
    var effects: [Effect<Action>] = [
      .cancel(id: CancelID.pipeline),
      .run { send in
        do {
          try await history.appendMessage(conversationID, stoppedMessage)
          try await history.appendEvents(conversationID, stoppedMessage.id, lines)
          try await history.endTurnJournal(conversationID)
        } catch {
          await send(
            .operationFailed(.history(operation: .messageSave, error: error)))
        }
      },
    ]
    effects.append(dispatchNextIfIdle(state: &state))
    return .merge(effects)
  }

  private func handlePipelineEvent(
    state: inout State,
    conversationID: UUID,
    questionID: UUID,
    event: PipelineEvent
  ) -> Effect<Action> {
    // A late event racing a stop or delete must not resurrect the turn.
    guard state.activeTurn?.questionID == questionID else { return .none }
    if let line = event.traceLine {
      state.activeTurn?.trace.append(line)
    }
    if let json = try? event.jsonLine() {
      state.activeTurn?.eventLines.append(json)
    }
    if state.chat?.conversationID == conversationID {
      let trace = state.activeTurn?.trace ?? []
      state.chat?.processing?.trace = trace
    }
    guard case .turnFinished(let outcome, let telemetry) = event,
      let active = state.activeTurn
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
      traceSteps: active.trace, createdAt: now,
      devInfo: telemetry)
    let lines = active.eventLines
    state.activeTurn = nil

    diagnostics.info(
      category: .submission,
      code: "chat_turn_rendered",
      summary: "The terminal pipeline outcome was rendered.",
      context: [
        "outcome": outcomeName(outcome),
        "query_origin": telemetry.queryOrigin.rawValue,
        "execution_path": telemetry.executionPath.rawValue,
        "confidence": telemetry.confidence?.rawValue ?? "none",
        "generated_count": String(telemetry.generatedCount),
        "repair_attempts": String(telemetry.repairAttempts),
        "recovery_outcome": telemetry.recoveryOutcome?.rawValue ?? "none",
        "timeout_stage": timeoutStage(telemetry.timeoutStage),
        "completed_in_background": String(
          state.chat?.conversationID != conversationID),
      ])

    var effects: [Effect<Action>] = [
      .run { send in
        do {
          try await history.appendMessage(conversationID, assistantMessage)
          try await history.appendEvents(
            conversationID, assistantMessage.id, lines)
          try await history.endTurnJournal(conversationID)
        } catch {
          await send(
            .operationFailed(.history(operation: .messageSave, error: error)))
        }
      }
    ]

    if state.chat?.conversationID == conversationID {
      state.chat?.messages.append(assistantMessage)
      state.chat?.processing = nil
    } else {
      // Background completion never changes the selected chat: mark the
      // Recent row unread, banner it, and emit a light haptic.
      state.conversations[id: conversationID]?.isUnread = true
      state.answerReadyBanner = AnswerReadyBanner(
        conversationID: conversationID,
        title: state.conversations[id: conversationID]?.displayTitle
          ?? "New Chat")
      effects.append(
        .run { _ in
          try? await history.setUnread(conversationID, true)
          await haptics.answerReady()
        })
      effects.append(
        .run { send in
          try await clock.sleep(for: .seconds(4))
          await send(.answerReadyBannerTimedOut)
        }
        .cancellable(id: CancelID.bannerTimeout, cancelInFlight: true))
    }
    updateSummaryAfterMessage(
      state: &state, conversationID: conversationID, message: assistantMessage)
    effects.append(dispatchNextIfIdle(state: &state))
    return .merge(effects)
  }

  // MARK: - Conversation lifecycle helpers

  private func deleteConversation(
    state: inout State,
    summary: ConversationSummary
  ) -> Effect<Action> {
    var effects: [Effect<Action>] = []

    // A second delete inside the Undo window commits the first immediately.
    if let previous = state.pendingDeletion {
      let id = previous.summary.id
      effects.append(
        .run { _ in try? await history.deleteConversation(id) })
    }

    let index = state.conversations.index(id: summary.id) ?? 0
    state.conversations.remove(id: summary.id)
    state.pendingDeletion = PendingDeletion(summary: summary, index: index)
    state.queue.removeAll { $0.conversationID == summary.id }

    if state.activeTurn?.conversationID == summary.id {
      state.activeTurn = nil
      effects.append(.cancel(id: CancelID.pipeline))
    }

    if state.chat?.conversationID == summary.id {
      if let nextSummary = state.conversations.first {
        effects.append(loadConversationEffect(id: nextSummary.id))
      } else {
        effects.append(createConversationEffect())
      }
    }
    syncSchedulerProjection(into: &state)

    diagnostics.info(
      category: .history,
      code: "conversation_delete_pending",
      summary: "A conversation entered the undo window before deletion.")
    effects.append(
      .run { send in
        try await clock.sleep(for: .seconds(5))
        await send(.deleteCountdownFinished)
      }
      .cancellable(id: CancelID.deleteCountdown, cancelInFlight: true))
    return .merge(effects)
  }

  private func createConversationEffect() -> Effect<Action> {
    let id = uuid()
    let startedAt = now
    return .run { send in
      let summary = try await history.createConversation(id, startedAt)
      await send(.conversationCreated(summary))
    } catch: { error, send in
      await send(
        .operationFailed(.history(operation: .conversationCreate, error: error)))
    }
  }

  private func loadConversationEffect(id: UUID) -> Effect<Action> {
    .run { send in
      let snapshot = try await history.loadConversation(id)
      await send(.conversationLoaded(snapshot))
    } catch: { error, send in
      await send(
        .operationFailed(.history(operation: .load, error: error)))
    }
  }

  /// Mirrors the global queue and active turn into the selected chat's
  /// parent-maintained projection fields.
  private func syncSchedulerProjection(into state: inout State) {
    guard var chat = state.chat else { return }
    chat.queued = state.queue.filter { $0.conversationID == chat.conversationID }
    if let active = state.activeTurn,
      active.conversationID == chat.conversationID
    {
      let expanded = chat.processing?.isTimelineExpanded ?? false
      chat.processing = ChatFeature.ProcessingState(
        questionID: active.questionID,
        question: active.question,
        startedAt: active.startedAt,
        trace: active.trace,
        isTimelineExpanded: expanded)
    } else {
      chat.processing = nil
    }
    state.chat = chat
  }

  private func updateSummaryAfterMessage(
    state: inout State,
    conversationID: UUID,
    message: ChatMessage
  ) {
    guard var summary = state.conversations[id: conversationID] else { return }
    summary.lastActivityAt = message.createdAt
    summary.latestMessagePreview = message.previewText
    summary.messageCount += 1
    state.conversations[id: conversationID] = summary
    state.conversations.sort { $0.lastActivityAt > $1.lastActivityAt }
  }

  private func startLaunchBenchmarkIfReady(
    state: inout State
  ) -> Effect<Action> {
    guard
      let question = state.launchBenchmarkQuestion?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !question.isEmpty,
      !state.launchBenchmarkStarted,
      state.modelReadiness == .ready,
      state.chat != nil,
      state.activeTurn == nil
    else { return .none }

    // A launch benchmark is a standalone turn. Do not let a prior installed
    // build's conversation trigger Foundation Models rewrite work or alter the
    // SQL prompt being timed.
    state.chat?.messages.removeAll()
    state.launchBenchmarkStarted = true
    diagnostics.info(
      category: .submission,
      code: "launch_benchmark_started",
      summary: "The Debug launch benchmark started.")
    guard let conversationID = state.chat?.conversationID else { return .none }
    return dispatch(
      state: &state,
      conversationID: conversationID,
      question: question,
      starter: nil)
  }

  private func preparationEffect() -> Effect<Action> {
    .run { send in
      try await pipeline.prepare()
      await send(.modelPrepared)
    } catch: { error, send in
      await send(.modelPreparationFailed(DiagnosticDetails.describe(error)))
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
}
