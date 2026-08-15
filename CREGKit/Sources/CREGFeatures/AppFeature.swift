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
    case failed(ModelPreparationFailure)
  }

  /// The single globally active turn.
  public struct ActiveTurn: Equatable, Sendable {
    public var questionID: UUID
    public var conversationID: UUID
    public var question: String
    public var submission: QuestionSubmission
    public var starter: StarterQueryID? {
      guard case .starter(let starter) = submission.source else { return nil }
      return starter
    }
    public var provisionalAssistantMessageID: UUID?
    public var resultPresentationPreference: ResultPresentationPreference?
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
      self.submission = QuestionSubmission(
        question: question,
        source: starter.map(QuestionSubmissionSource.starter) ?? .freeForm)
      self.startedAt = startedAt
    }

    public init(
      questionID: UUID,
      conversationID: UUID,
      submission: QuestionSubmission,
      startedAt: Date
    ) {
      self.questionID = questionID
      self.conversationID = conversationID
      self.question = submission.question
      self.submission = submission
      self.startedAt = startedAt
    }
  }

  public struct FollowUpPreparationState: Equatable, Sendable {
    public var conversationID: UUID
    public var context: FollowUpSuggestionContext
    public var batch: PreparedFollowUpBatch
    public var eventLines: [String] = []

    public init(
      conversationID: UUID,
      context: FollowUpSuggestionContext,
      batch: PreparedFollowUpBatch
    ) {
      self.conversationID = conversationID
      self.context = context
      self.batch = batch
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
    /// The completed turn whose history write currently gates queue dispatch.
    /// A watchdog clears this barrier if local persistence stops responding.
    public var pendingTurnPersistenceID: UUID?
    public var followUpPreparation: FollowUpPreparationState?
    /// Session-only Queued Questions across all Conversations, oldest first.
    public var queue: [QueuedQuestion] = []
    public var answerReadyBanner: AnswerReadyBanner?
    public var isSettingsPresented = false
    @Shared(.appStorage(DeveloperModePreference.storageKey))
    public var developerMode = false
    /// Reader-controlled density for full-screen result tables. Inline table
    /// previews continue to use the transcript's typography.
    @Shared(.appStorage(ResultTableTextSize.storageKey))
    public var resultTableTextSize: ResultTableTextSize = .standard
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
    public var modelPreparationReport: ModelPreparationReport?
    /// Appearance can re-fire while the root store remains alive. These
    /// session-only flags keep journal inspection and preparation once-only.
    public var didRequestPreparationJournalInspection = false
    public var didHandlePreparationJournalInspection = false
    public var modelPreparationInFlight = false
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
      let buildChannel = try? BuildChannel.load()
      self.debugModelIdentity =
        if buildChannel == .debug || buildChannel == .beta {
          debugModelIdentity ?? Self.bundledDebugModelIdentity()
        } else {
          nil
        }
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
    case appBecameActive
    case appBecameInactive
    case preparationJournalLoaded(ModelPreparationJournalSnapshot?)
    case retryPreparation
    case retryCompatibilityPreparation
    case modelPrepared(ModelPreparationReport)
    case modelPreparationFailed(ModelPreparationFailure)
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
    case pipelineStreamEnded(conversationID: UUID, questionID: UUID)
    case turnPersistenceFinished(UUID)
    case turnPersistenceTimedOut(UUID)
    case dispatchNextIfIdle
    case followUpPreparationEvent(
      conversationID: UUID,
      sourceMessageID: UUID,
      event: FollowUpPreparationEvent)
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
    case followUpPreparation
    case search
    case deleteCountdown
    case bannerTimeout
    case iconRead
    case modelPreparation
  }

  private struct TurnPersistenceTimeoutID: Hashable {
    var questionID: UUID
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
  @Dependency(\.modelPreparationJournal) var preparationJournal
  private let messageUpdateQueue = MessageUpdateQueue()

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
        syncSchedulerProjection(into: &state)
        var effects: [Effect<Action>] = []
        if !state.didRequestPreparationJournalInspection {
          state.didRequestPreparationJournalInspection = true
          state.modelReadiness = .preparing
          effects.append(
            .run { send in
              await send(
                .preparationJournalLoaded(
                  await preparationJournal.unfinishedAttempt()))
            })
        }
        // The system owns which icon is showing, so read it back on every
        // appearance rather than trusting stored state.
        let readIcon = Effect<Action>.run { send in
          await send(
            .appIconLoaded(
              appIconClient.current(),
              supportsAlternates: appIconClient.supportsAlternates()))
        }
        .cancellable(id: CancelID.iconRead, cancelInFlight: true)
        effects.append(readIcon)
        if state.chat == nil {
          effects.append(
            .run { send in
              let summaries = try await history.bootstrap()
              await send(.bootstrapFinished(summaries))
            } catch: { error, send in
              await send(
                .operationFailed(.history(operation: .load, error: error)))
            })
        }
        return .merge(effects)

      case .appBecameActive:
        return resumeFollowUpPreparationIfIdle(state: &state)

      case .appBecameInactive:
        let preparation = state.followUpPreparation
        state.followUpPreparation = nil
        var followOnEffects: [Effect<Action>] = []
        if let preparation, !preparation.eventLines.isEmpty {
          followOnEffects.append(
            .run { _ in
              try? await history.appendEvents(
                preparation.conversationID,
                preparation.context.sourceAssistantMessageID,
                preparation.eventLines)
            })
        }
        return .concatenate(
          .cancel(id: CancelID.followUpPreparation),
          .merge(followOnEffects))

      case .preparationJournalLoaded(let previous):
        guard
          state.didRequestPreparationJournalInspection,
          !state.didHandlePreparationJournalInspection
        else { return .none }
        state.didHandlePreparationJournalInspection = true
        if let previous {
          let failure = ModelPreparationFailure(
            code: "previous_preparation_interrupted",
            stage: previous.stage,
            mode: previous.mode,
            userMessage:
              "The previous SQL model preparation stopped unexpectedly. Review Developer Mode details, then retry.",
            diagnostic:
              "The prior process ended during \(previous.stage.rawValue) in \(previous.mode.rawValue) mode."
          )
          state.modelReadiness = .failed(failure)
          state.modelPreparationReport = nil
          diagnostics.record(
            DiagnosticEvent(
              level: .error,
              category: .model,
              code: failure.code,
              summary: "The previous model preparation attempt was interrupted.",
              context: [
                "stage": failure.stage.rawValue,
                "runtime_mode": failure.mode.rawValue,
              ]))
          return .none
        }
        state.modelReadiness = .preparing
        state.modelPreparationInFlight = true
        syncSchedulerProjection(into: &state)
        return preparationEffect(mode: .evaluated)

      case .retryPreparation:
        guard canStartModelPreparation(state: state) else { return .none }
        switch state.modelReadiness {
        case .failed:
          break
        case .ready:
          guard state.modelPreparationReport?.mode == .compatibility
          else { return .none }
        case .preparing:
          return .none
        }
        diagnostics.info(
          category: .submission,
          code: "model_preparation_retry_requested",
          summary: "The user requested another model preparation attempt.")
        state.modelReadiness = .preparing
        state.modelPreparationReport = nil
        state.modelPreparationInFlight = true
        return preparationEffect(mode: .evaluated)

      case .retryCompatibilityPreparation:
        guard
          canStartModelPreparation(state: state),
          state.developerMode,
          case .failed(let failure) = state.modelReadiness,
          failure.allowsCompatibilityRetry
        else { return .none }
        diagnostics.info(
          category: .submission,
          code: "model_compatibility_preparation_requested",
          summary: "The user requested compatibility model preparation.",
          context: ["failed_stage": failure.stage.rawValue])
        state.modelReadiness = .preparing
        state.modelPreparationReport = nil
        state.modelPreparationInFlight = true
        return preparationEffect(mode: .compatibility)

      case .modelPrepared(let report):
        state.modelPreparationInFlight = false
        state.modelReadiness = .ready
        state.modelPreparationReport = report
        diagnostics.info(
          category: .submission,
          code: "chat_model_ready",
          summary: "Chat submission is enabled because the SQL model is ready.",
          context: [
            "runtime_mode": report.mode.rawValue,
            "evaluated": String(report.mode.isEvaluated),
          ])
        return .merge(
          startLaunchBenchmarkIfReady(state: &state),
          resumeFollowUpPreparationIfIdle(state: &state),
          dispatchNextIfIdle(state: &state))

      case .modelPreparationFailed(let failure):
        state.modelPreparationInFlight = false
        state.modelReadiness = .failed(failure)
        state.modelPreparationReport = nil
        diagnostics.record(
          DiagnosticEvent(
            level: .error,
            category: .configuration,
            code: failure.code,
            summary: "The SQL model could not be prepared.",
            details: failure.diagnostic,
            context: [
              "stage": failure.stage.rawValue,
              "runtime_mode": failure.mode.rawValue,
              "error_domain": failure.errorDomain ?? "none",
              "error_code": failure.errorCode.map(String.init) ?? "none",
            ]))
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
        let conversationOwnsActiveTurn =
          state.activeTurn?.conversationID == snapshot.summary.id
        let activePreparedAnswerID =
          conversationOwnsActiveTurn
          ? state.activeTurn?.provisionalAssistantMessageID
          : nil
        state.chat = ChatFeature.State(
          snapshot: snapshot,
          preservingActiveTurn: conversationOwnsActiveTurn,
          preservingPreparedAnswerID: activePreparedAnswerID)
        syncSchedulerProjection(into: &state)
        state.isBrowserRevealed = false
        var effects: [Effect<Action>] = []
        let recovered = snapshot.messages.compactMap { message -> ChatMessage? in
          guard message.id != activePreparedAnswerID else { return nil }
          return message.finalizedInterruptedPreparedAnswer
        }
        if !recovered.isEmpty {
          let conversationID = snapshot.summary.id
          if let latest = recovered.last {
            state.conversations[id: conversationID]?.latestMessagePreview =
              latest.previewText
          }
          effects.append(
            .run { _ in
              for message in recovered {
                try? await messageUpdateQueue.save(
                  conversationID: conversationID,
                  messageID: message.id
                ) {
                  try await history.updateMessage(conversationID, message)
                }
              }
              if !conversationOwnsActiveTurn {
                try? await history.endTurnJournal(conversationID)
              }
            })
        }
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
        effects.append(resumeFollowUpPreparationIfIdle(state: &state))
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
            await messageUpdateQueue.removeConversation(id)
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

      case .pipelineStreamEnded(let conversationID, let questionID):
        return recoverFromUnterminatedPipelineStream(
          state: &state,
          conversationID: conversationID,
          questionID: questionID)

      case .turnPersistenceFinished(let questionID):
        guard state.pendingTurnPersistenceID == questionID else { return .none }
        state.pendingTurnPersistenceID = nil
        return .merge(
          .cancel(id: TurnPersistenceTimeoutID(questionID: questionID)),
          .send(.dispatchNextIfIdle))

      case .turnPersistenceTimedOut(let questionID):
        guard state.pendingTurnPersistenceID == questionID else { return .none }
        state.pendingTurnPersistenceID = nil
        diagnostics.record(
          DiagnosticEvent(
            level: .error,
            category: .history,
            code: "turn_persistence_barrier_timed_out",
            summary:
              "Queue dispatch resumed after a completed-turn history write stopped responding.",
            context: ["question_id": questionID.uuidString]))
        return .send(.dispatchNextIfIdle)

      case .dispatchNextIfIdle:
        return dispatchNextIfIdle(state: &state)

      case .followUpPreparationEvent(
        let conversationID, let sourceMessageID, let event):
        return handleFollowUpPreparationEvent(
          state: &state,
          conversationID: conversationID,
          sourceMessageID: sourceMessageID,
          event: event)

      case .chat(.delegate(.submitQuestion(let submission))):
        guard state.modelReadiness == .ready, let chat = state.chat
        else { return .none }
        let conversationID = chat.conversationID
        let preparation = state.followUpPreparation
        state.followUpPreparation = nil
        state.chat?.followUpBatch = nil
        let cancelPreparation = Effect<Action>.cancel(
          id: CancelID.followUpPreparation)
        let clearBatch = Effect<Action>.run { _ in
          if let preparation, !preparation.eventLines.isEmpty {
            try? await history.appendEvents(
              preparation.conversationID,
              preparation.context.sourceAssistantMessageID,
              preparation.eventLines)
          }
          try? await history.clearFollowUpBatch(conversationID)
        }
        if state.activeTurn == nil, state.queue.isEmpty,
          state.pendingTurnPersistenceID == nil
        {
          let userTurn = dispatch(
            state: &state,
            conversationID: conversationID,
            submission: submission)
          return .concatenate(
            cancelPreparation,
            .merge(clearBatch, userTurn))
        }
        let queued = QueuedQuestion(
          id: uuid(),
          conversationID: conversationID,
          submission: submission,
          submittedAt: now)
        state.queue.append(queued)
        syncSchedulerProjection(into: &state)
        diagnostics.info(
          category: .submission,
          code: "question_queued",
          summary: "A submission became a queued question behind active work.",
          context: ["queue_depth": String(state.queue.count)])
        return .concatenate(cancelPreparation, clearBatch)

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

      case .chat(.resultPresentationChanged(let messageID, let preference)):
        guard
          state.activeTurn?.conversationID == state.chat?.conversationID,
          state.activeTurn?.provisionalAssistantMessageID == messageID
        else { return .none }
        state.activeTurn?.resultPresentationPreference = preference
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
    .onChange(of: \.modelReadiness) { _, state in
      syncSchedulerProjection(into: &state)
      return .none
    }
    .ifLet(\.chat, action: \.chat) {
      ChatFeature(messageUpdateQueue: messageUpdateQueue)
    }
  }

  // MARK: - Scheduler (ADR 0008)

  /// Starts a turn immediately. Callers guarantee no turn is active.
  private func dispatch(
    state: inout State,
    conversationID: UUID,
    submission: QuestionSubmission
  ) -> Effect<Action> {
    let question = submission.question
    let questionID = uuid()
    let startedAt = now
    let userMessage = ChatMessage(
      id: uuid(), role: .user, body: .text(question), createdAt: startedAt)
    state.activeTurn = ActiveTurn(
      questionID: questionID,
      conversationID: conversationID,
      submission: submission,
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
        "query_origin": submission.source.queryOrigin.rawValue,
        "queue_depth": String(state.queue.count),
      ])

    return .run { send in
      // Dispatch against the conversation's latest completed history
      // (ADR 0008), loaded before this turn's user message lands.
      let turns: [ConversationTurn]
      switch submission.source {
      case .preparedFollowUp:
        // Prepared chips are already standalone and their fallback deliberately
        // skips conversational rewriting, so avoid an unnecessary history read.
        turns = []
      case .freeForm, .starter:
        let snapshot = try? await history.loadConversation(conversationID)
        turns = ChatFeature.conversationTurns(from: snapshot?.messages ?? [])
      }
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
      let events: AsyncStream<PipelineEvent> =
        switch submission.source {
        case .freeForm:
          pipeline.run(question, turns)
        case .starter(let starter):
          pipeline.runStarter(starter, turns)
        case .preparedFollowUp(let prepared):
          pipeline.runPrepared(prepared, [])
        }
      var terminalEventSeen = false
      for await event in events {
        if case .turnFinished = event {
          terminalEventSeen = true
        }
        await send(
          .pipelineEvent(
            conversationID: conversationID,
            questionID: questionID,
            event: event))
      }
      guard !Task.isCancelled, !terminalEventSeen else { return }
      await send(
        .pipelineStreamEnded(
          conversationID: conversationID,
          questionID: questionID))
    }
    .cancellable(id: CancelID.pipeline, cancelInFlight: true)
  }

  /// Visible-conversation priority: the oldest Queued Question in the
  /// selected Conversation, else the globally oldest.
  private func dispatchNextIfIdle(state: inout State) -> Effect<Action> {
    guard state.activeTurn == nil, state.pendingTurnPersistenceID == nil,
      state.modelReadiness == .ready
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
      submission: next.submission)
  }

  /// Keeps queue dispatch behind the completed turn's durable history write,
  /// while a separate watchdog guarantees a stuck local write cannot hold the
  /// process-wide scheduler forever.
  private func turnPersistenceEffect(
    questionID: UUID,
    operation: @escaping @Sendable () async throws -> Void
  ) -> Effect<Action> {
    .merge(
      .run { send in
        do {
          try await operation()
        } catch {
          await send(
            .operationFailed(.history(operation: .messageSave, error: error)))
        }
        await send(.turnPersistenceFinished(questionID))
      },
      .run { send in
        try await clock.sleep(for: .seconds(5))
        await send(.turnPersistenceTimedOut(questionID))
      }
      .cancellable(
        id: TurnPersistenceTimeoutID(questionID: questionID),
        cancelInFlight: true))
  }

  private func stopActiveTurn(state: inout State) -> Effect<Action> {
    guard let active = state.activeTurn,
      active.conversationID == state.chat?.conversationID
    else { return .none }
    state.activeTurn = nil
    state.pendingTurnPersistenceID = active.questionID
    if let provisionalID = active.provisionalAssistantMessageID,
      case .preparedFollowUp(let prepared) = active.submission.source
    {
      let finalized = ChatMessage(
        id: provisionalID,
        role: .assistant,
        body: .answer(
          result: prepared.result,
          narration: PreparedAnswerFallback.narration(for: prepared.result),
          sql: prepared.sql,
          notice: nil),
        traceSteps: active.trace,
        createdAt: now,
        devInfo: prepared.preparationTelemetry,
        resultPresentation: active.resultPresentationPreference)
      if state.chat?.conversationID == active.conversationID,
        let index = state.chat?.messages.index(id: provisionalID)
      {
        state.chat?.messages[index] = finalized
        state.chat?.processing = nil
      }
      updateSummaryAfterMessage(
        state: &state,
        conversationID: active.conversationID,
        message: finalized,
        replacing: true)
      let conversationID = active.conversationID
      let lines = active.eventLines
      return .merge(
        .cancel(id: CancelID.pipeline),
        turnPersistenceEffect(questionID: active.questionID) {
          try await messageUpdateQueue.save(
            conversationID: conversationID,
            messageID: finalized.id
          ) {
            try await history.updateMessage(conversationID, finalized)
          }
          try await history.appendEvents(conversationID, finalized.id, lines)
          try await history.endTurnJournal(conversationID)
        })
    }
    let stoppedMessage = ChatMessage(
      id: uuid(), role: .assistant,
      body: .text("Stopped — ask again whenever you're ready."),
      traceSteps: active.trace, createdAt: now)
    state.chat?.messages.append(stoppedMessage)
    state.chat?.processing = nil
    updateSummaryAfterMessage(
      state: &state, conversationID: active.conversationID, message: stoppedMessage)
    diagnostics.info(
      category: .submission,
      code: "chat_turn_stopped",
      summary: "The user stopped the in-flight turn.",
      context: ["partial_event_count": String(active.eventLines.count)])
    let conversationID = active.conversationID
    let lines = active.eventLines
    let effects: [Effect<Action>] = [
      .cancel(id: CancelID.pipeline),
      turnPersistenceEffect(questionID: active.questionID) {
        try await history.appendMessage(conversationID, stoppedMessage)
        try await history.appendEvents(conversationID, stoppedMessage.id, lines)
        try await history.endTurnJournal(conversationID)
      },
    ]
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
    if case .preparedResultReady(let prepared, _) = event {
      guard state.activeTurn?.provisionalAssistantMessageID == nil else {
        return .none
      }
      let messageID = uuid()
      state.activeTurn?.provisionalAssistantMessageID = messageID
      let provisional = ChatMessage(
        id: messageID,
        role: .assistant,
        body: .preparedAnswer(prepared),
        traceSteps: state.activeTurn?.trace ?? [],
        createdAt: now,
        devInfo: nil)
      state.activeTurn?.resultPresentationPreference = provisional.resultPresentation
      if state.chat?.conversationID == conversationID {
        state.chat?.messages.append(provisional)
      }
      updateSummaryAfterMessage(
        state: &state,
        conversationID: conversationID,
        message: provisional)
      return .run { send in
        do {
          try await history.appendMessage(conversationID, provisional)
        } catch {
          await send(
            .operationFailed(.history(operation: .messageSave, error: error)))
        }
      }
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
    let assistantMessageID = active.provisionalAssistantMessageID ?? uuid()
    let assistantMessage = ChatMessage(
      id: assistantMessageID, role: .assistant, body: body,
      traceSteps: active.trace, createdAt: now,
      devInfo: telemetry,
      resultPresentation: active.resultPresentationPreference)
    let lines = active.eventLines
    state.activeTurn = nil
    state.pendingTurnPersistenceID = active.questionID

    diagnostics.info(
      category: .submission,
      code: "chat_turn_rendered",
      summary: "The terminal pipeline outcome was rendered.",
      context: [
        "outcome": outcomeName(outcome),
        "query_origin": telemetry.queryOrigin.rawValue,
        "execution_path": telemetry.executionPath.rawValue,
        "runtime_mode": telemetry.runtimeMode.rawValue,
        "evaluated": String(telemetry.isEvaluated),
        "confidence": telemetry.confidence?.rawValue ?? "none",
        "generated_count": String(telemetry.generatedCount),
        "repair_attempts": String(telemetry.repairAttempts),
        "recovery_outcome": telemetry.recoveryOutcome?.rawValue ?? "none",
        "timeout_stage": timeoutStage(telemetry.timeoutStage),
        "completed_in_background": String(
          state.chat?.conversationID != conversationID),
      ])

    let replacesProvisional = active.provisionalAssistantMessageID != nil
    var effects: [Effect<Action>] = [
      turnPersistenceEffect(questionID: active.questionID) {
        if replacesProvisional {
          try await messageUpdateQueue.save(
            conversationID: conversationID,
            messageID: assistantMessage.id
          ) {
            try await history.updateMessage(conversationID, assistantMessage)
          }
        } else {
          try await history.appendMessage(conversationID, assistantMessage)
        }
        try await history.appendEvents(
          conversationID, assistantMessage.id, lines)
        try await history.endTurnJournal(conversationID)
      }
    ]

    if state.chat?.conversationID == conversationID {
      if replacesProvisional,
        let index = state.chat?.messages.index(id: assistantMessage.id)
      {
        state.chat?.messages[index] = assistantMessage
      } else {
        state.chat?.messages.append(assistantMessage)
      }
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
      state: &state,
      conversationID: conversationID,
      message: assistantMessage,
      replacing: replacesProvisional)
    if state.activeTurn == nil, state.queue.isEmpty,
      case .answered(let result, let narration, _, _) = outcome
    {
      let context = FollowUpSuggestionContext(
        sourceAssistantMessageID: assistantMessage.id,
        question: active.question,
        standaloneQuestion: telemetry.standaloneQuestion,
        narration: narration,
        result: result)
      effects.append(
        startFollowUpPreparation(
          state: &state,
          conversationID: conversationID,
          context: context))
    }
    return .merge(effects)
  }

  private func recoverFromUnterminatedPipelineStream(
    state: inout State,
    conversationID: UUID,
    questionID: UUID
  ) -> Effect<Action> {
    guard
      let active = state.activeTurn,
      active.questionID == questionID,
      active.conversationID == conversationID
    else { return .none }

    diagnostics.record(
      DiagnosticEvent(
        level: .error,
        category: .pipeline,
        code: "chat_pipeline_stream_recovered",
        summary: "A pipeline stream ended without a terminal event.",
        context: [
          "query_origin": active.submission.source.queryOrigin.rawValue,
          "provisional_result_visible": String(
            active.provisionalAssistantMessageID != nil),
        ]))

    let outcome: TurnOutcome
    var telemetry: TurnTelemetry
    if active.provisionalAssistantMessageID != nil,
      case .preparedFollowUp(let prepared) = active.submission.source
    {
      telemetry = prepared.preparationTelemetry
      telemetry.originalQuestion = prepared.question
      telemetry.standaloneQuestion = prepared.question
      telemetry.queryOrigin = .preparedFollowUp
      telemetry.executionPath = .preparedFollowUp
      telemetry.preparedFollowUpID = prepared.id
      telemetry.sourceAnswerMessageID = prepared.sourceAssistantMessageID
      telemetry.preparedCacheHit = true
      telemetry.narrationUsedFM = false
      telemetry.terminalError =
        "The prepared-answer stream ended without a terminal event."
      outcome = .answered(
        result: prepared.result,
        narration: PreparedAnswerFallback.narration(for: prepared.result),
        sql: prepared.sql,
        notice: nil)
    } else {
      telemetry = TurnTelemetry(
        originalQuestion: active.question,
        runtimeMode: state.modelPreparationReport?.mode ?? .evaluated)
      telemetry.queryOrigin = active.submission.source.queryOrigin
      telemetry.executionPath = active.submission.source.executionPath
      telemetry.terminalError =
        "The pipeline event stream ended without a terminal event."
      outcome = .failed(
        message: "CREG couldn’t finish that answer. Please try again.")
    }
    return handlePipelineEvent(
      state: &state,
      conversationID: conversationID,
      questionID: questionID,
      event: .turnFinished(outcome: outcome, telemetry: telemetry))
  }

  private func startFollowUpPreparation(
    state: inout State,
    conversationID: UUID,
    context: FollowUpSuggestionContext
  ) -> Effect<Action> {
    guard
      state.activeTurn == nil,
      state.queue.isEmpty,
      state.modelReadiness == .ready
    else { return .none }
    let batch = PreparedFollowUpBatch(
      sourceAssistantMessageID: context.sourceAssistantMessageID,
      context: context,
      status: .preparing,
      updatedAt: now)
    state.followUpPreparation = FollowUpPreparationState(
      conversationID: conversationID,
      context: context,
      batch: batch)
    if state.chat?.conversationID == conversationID {
      state.chat?.followUpBatch = batch
    }
    return .run(priority: .low) { send in
      try? await history.saveFollowUpBatch(conversationID, batch)
      for await event in pipeline.prepareFollowUps(context) {
        guard !Task.isCancelled else { return }
        await send(
          .followUpPreparationEvent(
            conversationID: conversationID,
            sourceMessageID: context.sourceAssistantMessageID,
            event: event))
      }
    }
    .cancellable(
      id: CancelID.followUpPreparation,
      cancelInFlight: true)
  }

  private func resumeFollowUpPreparationIfIdle(
    state: inout State
  ) -> Effect<Action> {
    guard
      state.activeTurn == nil,
      state.queue.isEmpty,
      state.followUpPreparation == nil,
      state.modelReadiness == .ready,
      let chat = state.chat,
      let batch = chat.followUpBatch,
      batch.status == .preparing,
      let context = batch.context
    else { return .none }
    state.followUpPreparation = FollowUpPreparationState(
      conversationID: chat.conversationID,
      context: context,
      batch: batch)
    let conversationID = chat.conversationID
    return .run(priority: .low) { send in
      for await event in pipeline.prepareFollowUps(context) {
        guard !Task.isCancelled else { return }
        await send(
          .followUpPreparationEvent(
            conversationID: conversationID,
            sourceMessageID: context.sourceAssistantMessageID,
            event: event))
      }
    }
    .cancellable(
      id: CancelID.followUpPreparation,
      cancelInFlight: true)
  }

  private func handleFollowUpPreparationEvent(
    state: inout State,
    conversationID: UUID,
    sourceMessageID: UUID,
    event: FollowUpPreparationEvent
  ) -> Effect<Action> {
    guard
      var preparation = state.followUpPreparation,
      preparation.conversationID == conversationID,
      preparation.context.sourceAssistantMessageID == sourceMessageID,
      state.activeTurn == nil,
      state.queue.isEmpty
    else { return .none }

    if let line = try? event.jsonLine() {
      preparation.eventLines.append(line)
    }
    switch event {
    case .started, .proposalFailed, .rejected:
      state.followUpPreparation = preparation
      return .none

    case .prepared(let prepared):
      _ = preparation.batch.appendIfEligible(prepared)
      preparation.batch.updatedAt = now
      state.followUpPreparation = preparation
      if state.chat?.conversationID == conversationID {
        state.chat?.followUpBatch = preparation.batch
      }
      let batch = preparation.batch
      return .run { _ in
        try? await history.saveFollowUpBatch(conversationID, batch)
      }

    case .finished:
      preparation.batch.status = .completed
      preparation.batch.updatedAt = now
      state.followUpPreparation = nil
      if state.chat?.conversationID == conversationID {
        state.chat?.followUpBatch = preparation.batch
      }
      let batch = preparation.batch
      let lines = preparation.eventLines
      return .run { _ in
        try? await history.saveFollowUpBatch(conversationID, batch)
        try? await history.appendEvents(
          conversationID, sourceMessageID, lines)
      }
    }
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
        .run { _ in
          do {
            try await history.deleteConversation(id)
            await messageUpdateQueue.removeConversation(id)
          } catch {
            // The countdown path reports deletion failures. Preserve the
            // existing best-effort behavior when a second delete commits the
            // first immediately, but retain its revision tombstones on failure.
          }
        })
    }

    let index = state.conversations.index(id: summary.id) ?? 0
    state.conversations.remove(id: summary.id)
    state.pendingDeletion = PendingDeletion(summary: summary, index: index)
    state.queue.removeAll { $0.conversationID == summary.id }
    if state.activeTurn?.conversationID == summary.id {
      state.activeTurn = nil
      effects.append(.cancel(id: CancelID.pipeline))
    }
    if state.followUpPreparation?.conversationID == summary.id {
      state.followUpPreparation = nil
      effects.append(.cancel(id: CancelID.followUpPreparation))
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
    chat.isSubmissionEnabled = state.modelReadiness == .ready
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
    message: ChatMessage,
    replacing: Bool = false
  ) {
    guard var summary = state.conversations[id: conversationID] else { return }
    summary.lastActivityAt = message.createdAt
    summary.latestMessagePreview = message.previewText
    if !replacing { summary.messageCount += 1 }
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
      submission: QuestionSubmission(question: question))
  }

  private func preparationEffect(
    mode: ModelRuntimeMode
  ) -> Effect<Action> {
    .run { send in
      var environment = ModelPreparationEnvironment.snapshot()
      environment["runtime_mode"] = mode.rawValue
      diagnostics.info(
        category: .model,
        code: "model_preparation_attempt_started",
        summary: "A SQL model preparation attempt started.",
        context: environment)
      await preparationJournal.begin(
        mode,
        environment)
      do {
        let report = try await pipeline.prepare(mode)
        await preparationJournal.complete(report)
        await send(.modelPrepared(report))
      } catch {
        let failure: ModelPreparationFailure
        if let preparationFailure = error as? ModelPreparationFailure {
          failure = preparationFailure
        } else {
          let nsError = error as NSError
          failure = ModelPreparationFailure(
            code: "model_preparation_unexpected",
            stage: .containerLoad,
            mode: mode,
            userMessage:
              "The SQL model could not be prepared. Restart CREG and try again.",
            diagnostic: DiagnosticDetails.sanitizedDescription(error),
            errorDomain: nsError.domain,
            errorCode: nsError.code)
        }
        await preparationJournal.fail(failure)
        await send(.modelPreparationFailed(failure))
      }
    }
    .cancellable(id: CancelID.modelPreparation, cancelInFlight: true)
  }

  private func canStartModelPreparation(state: State) -> Bool {
    !state.modelPreparationInFlight
      && state.activeTurn == nil
      && state.pendingTurnPersistenceID == nil
      && state.queue.isEmpty
      && state.followUpPreparation == nil
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

extension QuestionSubmissionSource {
  fileprivate var queryOrigin: QueryOrigin {
    switch self {
    case .freeForm: .freeForm
    case .starter: .starter
    case .preparedFollowUp: .preparedFollowUp
    }
  }

  fileprivate var executionPath: QueryExecutionPath {
    switch self {
    case .freeForm: .generated
    case .starter: .deterministicStarter
    case .preparedFollowUp: .preparedFollowUp
    }
  }
}
