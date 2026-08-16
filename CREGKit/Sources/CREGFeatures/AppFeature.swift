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

  /// The optimistic projection applied before the user-turn transaction
  /// settles. Keeping the prior values with the active turn makes a failed
  /// write fully reversible without guessing which transcript row changed.
  public struct OptimisticUserTurn: Equatable, Sendable {
    public var message: ChatMessage
    public var previousSummary: ConversationSummary?
    public var previousChatTitle: String?

    public init(
      message: ChatMessage,
      previousSummary: ConversationSummary?,
      previousChatTitle: String?
    ) {
      self.message = message
      self.previousSummary = previousSummary
      self.previousChatTitle = previousChatTitle
    }
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
    public var optimisticUserTurn: OptimisticUserTurn?
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

  /// A completed turn whose durable transcript write still owns the scheduler
  /// barrier. A timeout is diagnostic only: advancing while the write remains
  /// alive would let the next turn observe or persist an out-of-order history.
  public struct PendingTurnPersistence: Equatable, Sendable {
    public var questionID: UUID
    public var conversationID: UUID
    public var didTimeOut = false
    public var followUpContext: FollowUpSuggestionContext?
    public var userMessageID: UUID?
    public var terminalMessageID: UUID?

    public init(questionID: UUID, conversationID: UUID) {
      self.questionID = questionID
      self.conversationID = conversationID
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
    public var deferredFailure: FailurePresentation?

    public init(
      summary: ConversationSummary,
      index: Int,
      deferredFailure: FailurePresentation? = nil
    ) {
      self.summary = summary
      self.index = index
      self.deferredFailure = deferredFailure
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
    public var pendingTurnPersistence: PendingTurnPersistence?
    /// Compatibility projection used by diagnostics and reducer tests.
    public var pendingTurnPersistenceID: UUID? {
      pendingTurnPersistence?.questionID
    }
    /// A confirmed delete waiting for its conversation's persistence barrier.
    public var deletionAwaitingTurnPersistence: UUID?
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
    case turnPersistenceFailed(
      conversationID: UUID, questionID: UUID, failure: FailurePresentation)
    case userTurnPersistenceFailed(
      conversationID: UUID,
      questionID: UUID,
      optimisticTurn: OptimisticUserTurn,
      failure: FailurePresentation?)
    case conversationWriteFailed(
      conversationID: UUID, failure: FailurePresentation)
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
          setModelReadiness(.preparing, state: &state)
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
          setModelReadiness(.failed(failure), state: &state)
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
        setModelReadiness(.preparing, state: &state)
        state.modelPreparationInFlight = true
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
        setModelReadiness(.preparing, state: &state)
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
        setModelReadiness(.preparing, state: &state)
        state.modelPreparationReport = nil
        state.modelPreparationInFlight = true
        return preparationEffect(mode: .compatibility)

      case .modelPrepared(let report):
        state.modelPreparationInFlight = false
        setModelReadiness(.ready, state: &state)
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
        setModelReadiness(.failed(failure), state: &state)
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
                _ = try? await messageUpdateQueue.save(
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
        var effects: [Effect<Action>] = [
          .cancel(id: CancelID.deleteCountdown)
        ]
        if let failure = pending.deferredFailure {
          effects.append(.send(.operationFailed(failure)))
        }
        return .merge(effects)

      case .deleteCountdownFinished:
        guard let pending = state.pendingDeletion else { return .none }
        state.pendingDeletion = nil
        return commitOrDeferDeletion(
          state: &state, conversationID: pending.summary.id)

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

      case .turnPersistenceFailed(
        let conversationID, let questionID, let failure):
        guard state.pendingTurnPersistence?.questionID == questionID else {
          return .none
        }
        return handleConversationWriteFailure(
          state: &state,
          conversationID: conversationID,
          failure: failure)

      case .userTurnPersistenceFailed(
        let conversationID, let questionID, let optimisticTurn, let failure):
        guard
          state.activeTurn?.questionID == questionID
            || state.pendingTurnPersistence?.questionID == questionID
        else {
          // Coalesced writers can report the same failure after the first
          // action has already released scheduler ownership. Make stale
          // cleanup idempotent without rolling back newer summary state.
          if state.chat?.conversationID == conversationID {
            state.chat?.messages.remove(id: optimisticTurn.message.id)
          }
          return .run { _ in
            await messageUpdateQueue.forgetOnceSave(
              conversationID: conversationID,
              messageID: optimisticTurn.message.id)
          }
        }
        rollBackOptimisticUserTurn(
          state: &state,
          questionID: questionID,
          conversationID: conversationID,
          optimisticTurn: optimisticTurn)
        var effects: [Effect<Action>] = [
          .cancel(id: TurnPersistenceTimeoutID(questionID: questionID)),
          .run { _ in
            await messageUpdateQueue.forgetOnceSave(
              conversationID: conversationID,
              messageID: optimisticTurn.message.id)
          },
          .send(.dispatchNextIfIdle),
        ]
        if let failure {
          effects.append(
            handleConversationWriteFailure(
              state: &state,
              conversationID: conversationID,
              failure: failure))
        }
        return .merge(effects)

      case .conversationWriteFailed(let conversationID, let failure):
        return handleConversationWriteFailure(
          state: &state,
          conversationID: conversationID,
          failure: failure)

      case .turnPersistenceFinished(let questionID):
        guard let pending = state.pendingTurnPersistence,
          pending.questionID == questionID
        else { return .none }
        state.pendingTurnPersistence = nil
        var effects: [Effect<Action>] = [
          .cancel(id: TurnPersistenceTimeoutID(questionID: questionID)),
          .send(.dispatchNextIfIdle),
        ]
        if let userMessageID = pending.userMessageID {
          effects.append(
            .run { _ in
              await messageUpdateQueue.forgetOnceSave(
                conversationID: pending.conversationID,
                messageID: userMessageID)
            })
        }
        if let context = pending.followUpContext {
          effects.append(
            startFollowUpPreparation(
              state: &state,
              conversationID: pending.conversationID,
              context: context))
        }
        if state.deletionAwaitingTurnPersistence == pending.conversationID {
          state.deletionAwaitingTurnPersistence = nil
          effects.append(commitDeletionEffect(conversationID: pending.conversationID))
        }
        return .merge(effects)

      case .turnPersistenceTimedOut(let questionID):
        guard var pending = state.pendingTurnPersistence,
          pending.questionID == questionID,
          !pending.didTimeOut
        else { return .none }
        pending.didTimeOut = true
        state.pendingTurnPersistence = pending
        diagnostics.record(
          DiagnosticEvent(
            level: .error,
            category: .history,
            code: "turn_persistence_barrier_timed_out",
            summary:
              "Queue dispatch remains paused because a completed-turn history write stopped responding.",
            context: ["question_id": questionID.uuidString]))
        if state.presentedFailure == nil {
          state.presentedFailure = FailurePresentation(
            code: "turn_persistence_barrier_timed_out",
            title: "Saving is taking longer than expected",
            message:
              "CREG is still saving this conversation. New questions will remain paused to keep your history in order. Restart CREG if saving does not recover.",
            diagnostic:
              "The completed-turn history write exceeded the five-second persistence watchdog.")
        }
        return .none

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
          state.pendingTurnPersistence == nil
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
    precondition(
      state.activeTurn == nil && state.pendingTurnPersistence == nil,
      "Dispatch requires an idle scheduler and a settled transcript write.")
    let question = submission.question
    let questionID = uuid()
    let startedAt = now
    let userMessage = ChatMessage(
      id: uuid(), role: .user, body: .text(question), createdAt: startedAt)
    let optimisticTurn = OptimisticUserTurn(
      message: userMessage,
      previousSummary: state.conversations[id: conversationID],
      previousChatTitle:
        state.chat?.conversationID == conversationID
        ? state.chat?.title
        : state.conversations[id: conversationID]?.title)
    var activeTurn = ActiveTurn(
      questionID: questionID,
      conversationID: conversationID,
      submission: submission,
      startedAt: startedAt)
    activeTurn.optimisticUserTurn = optimisticTurn
    state.activeTurn = activeTurn

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
      // Unstructured so a Stop cancellation cannot abort the user-message
      // write. Stop coalesces onto this same once-save before writing its
      // terminal message, so the prerequisite remains ordered even when Stop
      // arrives before this effect is scheduled.
      let persistDispatch = Task {
        try await messageUpdateQueue.saveOnce(
          conversationID: conversationID,
          messageID: userMessage.id
        ) {
          try await history.persistUserTurn(
            conversationID, userMessage, question, startedAt)
        }
      }
      let persistenceOutcome: MessageUpdateQueue.SaveOutcome
      do {
        persistenceOutcome = try await persistDispatch.value
      } catch {
        await send(
          .userTurnPersistenceFailed(
            conversationID: conversationID,
            questionID: questionID,
            optimisticTurn: optimisticTurn,
            failure: .history(operation: .messageSave, error: error)))
        return
      }
      guard persistenceOutcome == .saved else {
        await send(
          .userTurnPersistenceFailed(
            conversationID: conversationID,
            questionID: questionID,
            optimisticTurn: optimisticTurn,
            failure: nil))
        return
      }
      guard !Task.isCancelled else { return }
      // Loading after the atomic user write is safe: conversationTurns ignores
      // the trailing unanswered user message and still returns only completed
      // exchanges from ADR 0008.
      let turns: [ConversationTurn]
      switch submission.source {
      case .preparedFollowUp, .starter:
        turns = []
      case .freeForm:
        let snapshot = try? await history.loadConversation(conversationID)
        turns = ChatFeature.conversationTurns(from: snapshot?.messages ?? [])
      }
      guard !Task.isCancelled else { return }
      let events: AsyncStream<PipelineEvent> =
        switch submission.source {
        case .freeForm:
          pipeline.run(question, turns)
        case .starter(let starter):
          pipeline.runStarter(starter)
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
    guard state.activeTurn == nil, state.pendingTurnPersistence == nil,
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

  /// Keeps queue dispatch behind the completed turn's durable history write.
  /// The watchdog surfaces a stalled write but deliberately leaves this
  /// fail-closed ordering barrier intact.
  private func turnPersistenceEffect(
    conversationID: UUID,
    questionID: UUID,
    operation: @escaping @Sendable () async throws -> Void
  ) -> Effect<Action> {
    .merge(
      .run { send in
        do {
          try await operation()
        } catch {
          await send(
            .turnPersistenceFailed(
              conversationID: conversationID,
              questionID: questionID,
              failure: .history(operation: .messageSave, error: error)))
        }
        await send(.turnPersistenceFinished(questionID))
      },
      turnPersistenceWatchdog(questionID: questionID))
  }

  private func turnPersistenceWatchdog(questionID: UUID) -> Effect<Action> {
    .run { send in
      try await clock.sleep(for: .seconds(5))
      await send(.turnPersistenceTimedOut(questionID))
    }
    .cancellable(
      id: TurnPersistenceTimeoutID(questionID: questionID),
      cancelInFlight: true)
  }

  private func stopActiveTurn(state: inout State) -> Effect<Action> {
    guard let active = state.activeTurn,
      active.conversationID == state.chat?.conversationID
    else { return .none }
    precondition(
      state.pendingTurnPersistence == nil,
      "An active turn cannot stop while another persistence barrier exists.")
    state.activeTurn = nil
    state.pendingTurnPersistence = PendingTurnPersistence(
      questionID: active.questionID,
      conversationID: active.conversationID)
    state.pendingTurnPersistence?.userMessageID =
      active.optimisticUserTurn?.message.id
    syncSchedulerProjection(into: &state)
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
      }
      state.pendingTurnPersistence?.terminalMessageID = finalized.id
      updateSummaryAfterMessage(
        state: &state,
        conversationID: active.conversationID,
        message: finalized,
        replacing: true)
      return .merge(
        .cancel(id: CancelID.pipeline),
        stoppedTurnPersistenceEffect(
          active: active,
          terminalMessage: finalized,
          replacesExisting: true))
    }
    let stoppedMessage = ChatMessage(
      id: uuid(), role: .assistant,
      body: .text("Stopped — ask again whenever you're ready."),
      traceSteps: active.trace, createdAt: now)
    if state.chat?.conversationID == active.conversationID {
      state.chat?.messages.append(stoppedMessage)
    }
    state.pendingTurnPersistence?.terminalMessageID = stoppedMessage.id
    updateSummaryAfterMessage(
      state: &state, conversationID: active.conversationID, message: stoppedMessage)
    diagnostics.info(
      category: .submission,
      code: "chat_turn_stopped",
      summary: "The user stopped the in-flight turn.",
      context: ["partial_event_count": String(active.eventLines.count)])
    let effects: [Effect<Action>] = [
      .cancel(id: CancelID.pipeline),
      stoppedTurnPersistenceEffect(
        active: active,
        terminalMessage: stoppedMessage,
        replacesExisting: false),
    ]
    return .merge(effects)
  }

  /// Stop may race the effect that persists the optimistic user message. Both
  /// paths coalesce on the same once-save, and the terminal write cannot begin
  /// until that prerequisite has durably succeeded.
  private func stoppedTurnPersistenceEffect(
    active: ActiveTurn,
    terminalMessage: ChatMessage,
    replacesExisting: Bool
  ) -> Effect<Action> {
    let conversationID = active.conversationID
    let questionID = active.questionID
    let optimisticTurn = active.optimisticUserTurn
    let question = active.question
    let startedAt = active.startedAt
    let eventLines = active.eventLines
    return .merge(
      .run { send in
        if let optimisticTurn {
          let userOutcome: MessageUpdateQueue.SaveOutcome
          do {
            userOutcome = try await messageUpdateQueue.saveOnce(
              conversationID: conversationID,
              messageID: optimisticTurn.message.id
            ) {
              try await history.persistUserTurn(
                conversationID,
                optimisticTurn.message,
                question,
                startedAt)
            }
          } catch {
            await send(
              .userTurnPersistenceFailed(
                conversationID: conversationID,
                questionID: questionID,
                optimisticTurn: optimisticTurn,
                failure: .history(operation: .messageSave, error: error)))
            await send(.turnPersistenceFinished(questionID))
            return
          }
          guard userOutcome == .saved else {
            await send(
              .userTurnPersistenceFailed(
                conversationID: conversationID,
                questionID: questionID,
                optimisticTurn: optimisticTurn,
                failure: nil))
            await send(.turnPersistenceFinished(questionID))
            return
          }
        }
        do {
          _ = try await messageUpdateQueue.save(
            conversationID: conversationID,
            messageID: terminalMessage.id
          ) {
            try await history.persistTerminalTurn(
              conversationID,
              terminalMessage,
              replacesExisting,
              eventLines)
          }
        } catch {
          await send(
            .turnPersistenceFailed(
              conversationID: conversationID,
              questionID: questionID,
              failure: .history(operation: .messageSave, error: error)))
        }
        await send(.turnPersistenceFinished(questionID))
      },
      turnPersistenceWatchdog(questionID: questionID))
  }

  private func handlePipelineEvent(
    state: inout State,
    conversationID: UUID,
    questionID: UUID,
    event: PipelineEvent
  ) -> Effect<Action> {
    // A late event racing a stop or delete must not resurrect the turn.
    guard state.activeTurn?.questionID == questionID else { return .none }
    precondition(
      state.pendingTurnPersistence == nil,
      "An active turn cannot emit events while another persistence barrier exists.")
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
          _ = try await messageUpdateQueue.save(
            conversationID: conversationID,
            messageID: provisional.id
          ) {
            try await history.appendMessage(conversationID, provisional)
          }
        } catch {
          await send(
            .conversationWriteFailed(
              conversationID: conversationID,
              failure: .history(operation: .messageSave, error: error)))
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
    state.pendingTurnPersistence = PendingTurnPersistence(
      questionID: active.questionID,
      conversationID: conversationID)
    state.pendingTurnPersistence?.userMessageID =
      active.optimisticUserTurn?.message.id

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
    state.pendingTurnPersistence?.terminalMessageID = assistantMessage.id
    var effects: [Effect<Action>] = [
      turnPersistenceEffect(
        conversationID: conversationID,
        questionID: active.questionID
      ) {
        _ = try await messageUpdateQueue.save(
          conversationID: conversationID,
          messageID: assistantMessage.id
        ) {
          try await history.persistTerminalTurn(
            conversationID, assistantMessage, replacesProvisional, lines)
        }
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
    syncSchedulerProjection(into: &state)
    if state.activeTurn == nil, state.queue.isEmpty,
      case .answered(let result, let narration, _, _) = outcome
    {
      state.pendingTurnPersistence?.followUpContext = FollowUpSuggestionContext(
        sourceAssistantMessageID: assistantMessage.id,
        question: active.question,
        standaloneQuestion: telemetry.standaloneQuestion,
        narration: narration,
        result: result)
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
      state.pendingTurnPersistence == nil,
      state.modelReadiness == .ready,
      state.conversations[id: conversationID] != nil
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
      state.pendingTurnPersistence == nil,
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
      state.queue.isEmpty,
      state.pendingTurnPersistence == nil
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
        commitOrDeferDeletion(state: &state, conversationID: id))
    }

    let index = state.conversations.index(id: summary.id) ?? 0
    state.conversations.remove(id: summary.id)
    state.pendingDeletion = PendingDeletion(summary: summary, index: index)
    state.queue.removeAll { $0.conversationID == summary.id }
    if state.activeTurn?.conversationID == summary.id {
      state.activeTurn = nil
      effects.append(.cancel(id: CancelID.pipeline))
      effects.append(.send(.dispatchNextIfIdle))
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

  /// Commits a confirmed delete only after its terminal transcript write has
  /// settled. Removing the row sooner would allow the still-live write to fail
  /// visibly or recreate orphaned journal/event data after deletion.
  private func commitOrDeferDeletion(
    state: inout State,
    conversationID: UUID
  ) -> Effect<Action> {
    if state.pendingTurnPersistence?.conversationID == conversationID {
      state.deletionAwaitingTurnPersistence = conversationID
      diagnostics.info(
        category: .history,
        code: "conversation_delete_waiting_for_persistence",
        summary: "Conversation deletion is waiting for its final history write.")
      return .none
    }
    return commitDeletionEffect(conversationID: conversationID)
  }

  private func handleConversationWriteFailure(
    state: inout State,
    conversationID: UUID,
    failure: FailurePresentation
  ) -> Effect<Action> {
    if state.pendingDeletion?.summary.id == conversationID {
      state.pendingDeletion?.deferredFailure = failure
      diagnostics.info(
        category: .history,
        code: "conversation_write_failure_deferred_for_undo",
        summary:
          "A conversation write failure is deferred until the pending deletion is resolved.")
      return .none
    }
    guard state.conversations[id: conversationID] != nil else { return .none }
    return .send(.operationFailed(failure))
  }

  private func rollBackOptimisticUserTurn(
    state: inout State,
    questionID: UUID,
    conversationID: UUID,
    optimisticTurn: OptimisticUserTurn
  ) {
    let terminalMessageID =
      state.pendingTurnPersistence?.questionID == questionID
      ? state.pendingTurnPersistence?.terminalMessageID
      : nil
    if state.activeTurn?.questionID == questionID {
      state.activeTurn = nil
    }
    if state.pendingTurnPersistence?.questionID == questionID {
      state.pendingTurnPersistence = nil
    }
    if state.chat?.conversationID == conversationID {
      let messageIDs = Set(
        [optimisticTurn.message.id, terminalMessageID].compactMap { $0 })
      state.chat?.messages.removeAll { messageIDs.contains($0.id) }
      if state.chat?.isManuallyTitled == false,
        let previousChatTitle = optimisticTurn.previousChatTitle
      {
        state.chat?.title = previousChatTitle
      }
    }

    if var previousSummary = optimisticTurn.previousSummary,
      let currentSummary = state.conversations[id: conversationID]
    {
      if currentSummary.isManuallyTitled {
        previousSummary.title = currentSummary.title
        previousSummary.isManuallyTitled = true
      }
      state.conversations[id: conversationID] = previousSummary
      state.conversations.sort { $0.lastActivityAt > $1.lastActivityAt }
    }
    syncSchedulerProjection(into: &state)
  }

  private func commitDeletionEffect(conversationID: UUID) -> Effect<Action> {
    .run { send in
      await messageUpdateQueue.beginDeletingConversation(conversationID)
      do {
        try await history.deleteConversation(conversationID)
        await messageUpdateQueue.confirmConversationDeletion(conversationID)
      } catch {
        await messageUpdateQueue.cancelConversationDeletion(conversationID)
        await send(
          .operationFailed(.history(operation: .delete, error: error)))
      }
    }
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
  private func setModelReadiness(
    _ readiness: ModelReadiness,
    state: inout State
  ) {
    state.modelReadiness = readiness
    syncSchedulerProjection(into: &state)
  }

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
      state.activeTurn == nil,
      state.pendingTurnPersistence == nil
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
      && state.pendingTurnPersistence == nil
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
