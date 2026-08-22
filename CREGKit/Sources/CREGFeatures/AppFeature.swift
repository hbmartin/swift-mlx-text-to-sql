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

  /// One Scope Verdict in flight for a rendered Turn Failure, or its retained
  /// Recovery Suggestion context after background cancellation. Recovery
  /// Suggestions (D) normally wait for C; reactivation resumes D without the
  /// optional verdict.
  public struct PendingScopeDiagnosis: Equatable, Sendable {
    public var conversationID: UUID
    public var messageID: UUID
    public var context: FollowUpSuggestionContext

    public init(
      conversationID: UUID,
      messageID: UUID,
      context: FollowUpSuggestionContext
    ) {
      self.conversationID = conversationID
      self.messageID = messageID
      self.context = context
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
    /// Apple Intelligence availability, refreshed on every scene activation.
    /// Apple Intelligence is required (ADR 0011): submission gates on this
    /// alongside `modelReadiness`.
    public var fmAvailability: FMAvailability = .available
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
    public var pendingScopeDiagnosis: PendingScopeDiagnosis?
    /// True while the Scope Verdict judge effect is actually running.
    /// `pendingScopeDiagnosis` alone cannot distinguish a live judge from an
    /// interrupted memo, and the resume hooks (`.modelPrepared`,
    /// `.dispatchNextIfIdle`, activation after a transient `.inactive`) must
    /// never consume the memo out from under an in-flight judge — that would
    /// start verdict-free preparation and discard the verdict on arrival.
    public var isScopeDiagnosisInFlight = false
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
    /// Debug-only answerability capture (docs/eval.md "Answerability").
    public var isCapturingAnswerability = false
    /// Identity of the in-flight capture. A completion action must present
    /// this identity to be consumed; anything else is a stale completion
    /// racing its own cancellation and is cleaned up instead.
    public var answerabilityCaptureID: UUID?
    public var answerabilityCaptureExport: URL?
    /// Scene activity per the deactivation invariant: low-priority FM/MLX
    /// work (scope diagnosis, follow-up preparation, debug captures) must
    /// never start while the app is inactive, even when the action that
    /// would start it — a persistence barrier settling, a verdict write
    /// completing — arrives in the background.
    public var isSceneActive = true
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

    /// The ADR 0008 idle core: no turn is active, queued, or holding the
    /// completed-turn persistence barrier.
    public var isTurnSchedulerIdle: Bool {
      activeTurn == nil && queue.isEmpty && pendingTurnPersistence == nil
    }

    /// The idle core plus every lower-priority inference owner except the
    /// pending Scope Verdict memo. The gates that deliberately consume or
    /// abandon the memo — diagnosis resume, user-requested model
    /// maintenance — start from here; everything else uses
    /// `isInferenceIdle`.
    public var isInferenceIdleIgnoringScopeDiagnosis: Bool {
      isTurnSchedulerIdle
        && followUpPreparation == nil
        && !isCapturingAnswerability
    }

    /// The idle core plus every lower-priority inference owner: no Scope
    /// Verdict outstanding, no follow-up preparation running, and no debug
    /// capture streaming its 87 serialized FM calls. Low-priority FM/MLX
    /// work (preparation, diagnosis resume, model preparation, debug
    /// captures) may start only from here, so every such gate shares this
    /// one predicate instead of hand-enumerating the conditions.
    public var isInferenceIdle: Bool {
      isInferenceIdleIgnoringScopeDiagnosis && pendingScopeDiagnosis == nil
    }
  }

  public enum Action: BindableAction, Sendable, Equatable {
    case binding(BindingAction<State>)
    case onAppear
    case appBecameActive
    case appBecameInactive
    case appEnteredBackground
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
    case scopeDiagnosisFinished(
      conversationID: UUID,
      messageID: UUID,
      verdict: ScopeVerdictRecord?)
    /// The Scope Verdict's durable enrichment finished; Recovery Suggestion
    /// preparation (D) starts through this action so its idle gates are
    /// re-checked at delivery time rather than captured before the write.
    case scopeDiagnosisPersisted(
      conversationID: UUID,
      context: FollowUpSuggestionContext)
    case supportBundleExportTapped
    case supportBundleReady(SupportBundleExport)
    case supportBundleDismissed
    case answerabilityCaptureTapped
    case answerabilityCaptureReady(id: UUID, url: URL?)
    case appIconLoaded(AppIconVariant, supportsAlternates: Bool)
    case appIconSelected(AppIconVariant)
    case appearanceSelected(AppearancePreference)
    case operationFailed(FailurePresentation)
    case dismissFailure
  }

  enum CancelID {
    case pipeline
    case followUpPreparation
    case scopeDiagnosis
    case answerabilityCapture
    case fmAvailabilityWatch
    case search
    case deleteCountdown
    case bannerTimeout
    case iconRead
    case modelPreparation
  }

  struct TurnPersistenceTimeoutID: Hashable {
    var questionID: UUID
  }

  @Dependency(\.queryPipeline) var pipeline
  @Dependency(\.fmStatus) var fmStatus
  @Dependency(\.scopeDiagnosis) var scopeDiagnosis
  @Dependency(\.historyClient) var history
  @Dependency(\.supportBundle) var supportBundle
  @Dependency(\.haptics) var haptics
  @Dependency(\.appIcon) var appIconClient
  @Dependency(\.uuid) var uuid
  @Dependency(\.date.now) var now
  @Dependency(\.continuousClock) var clock
  @Dependency(\.diagnostics) var diagnostics
  @Dependency(\.modelPreparationJournal) var preparationJournal
  @Dependency(\.modelPreparationEnvironment) var preparationEnvironment
  let messageUpdateQueue = MessageUpdateQueue()

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
        refreshFMAvailability(state: &state)
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
        state.isSceneActive = true
        refreshFMAvailability(state: &state)
        let interruptedRecovery =
          resumeInterruptedScopeDiagnosisIfIdle(state: &state)
        let persistedPreparation = resumeFollowUpPreparationIfIdle(state: &state)
        let queuedTurn = dispatchNextIfIdle(state: &state)
        return .merge(interruptedRecovery, persistedPreparation, queuedTurn)

      case .appBecameInactive:
        // A transient interruption — Control Center, an app-switcher peek, a
        // Face ID or permission dialog — passes through `.inactive` without
        // ever backgrounding. Destroying in-flight capture, diagnosis, or
        // preparation for a one-second blip would force a full FM/MLX re-run
        // on the paired reactivation, so this only gates *new* low-priority
        // starts; `.appEnteredBackground` performs the real teardown.
        state.isSceneActive = false
        return .none

      case .appEnteredBackground:
        state.isSceneActive = false
        // The judge effect is cancelled below; the memo survives as an
        // interrupted diagnosis for activation to resume.
        state.isScopeDiagnosisInFlight = false
        let preparation = state.followUpPreparation
        state.followUpPreparation = nil
        // Keep the pending context while cancelling its FM call. Reactivation
        // starts Recovery Suggestion preparation without a verdict, preserving
        // the lower-priority work without running it in the background.
        if state.isCapturingAnswerability {
          // Cancellation drops the effect's completion action, so this is the
          // only record that the capture died rather than finishing.
          diagnostics.info(
            category: .model,
            code: "answerability_capture_cancelled",
            summary:
              "Deactivation cancelled the in-flight answerability capture; no export was produced.")
        }
        state.isCapturingAnswerability = false
        state.answerabilityCaptureID = nil
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
          .cancel(id: CancelID.scopeDiagnosis),
          .cancel(id: CancelID.answerabilityCapture),
          .cancel(id: CancelID.fmAvailabilityWatch),
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
        let abandonedDiagnosis =
          abandonScopeDiagnosisForModelMaintenance(state: &state)
        diagnostics.info(
          category: .submission,
          code: "model_preparation_retry_requested",
          summary: "The user requested another model preparation attempt.")
        setModelReadiness(.preparing, state: &state)
        state.modelPreparationReport = nil
        state.modelPreparationInFlight = true
        return .merge(abandonedDiagnosis, preparationEffect(mode: .evaluated))

      case .retryCompatibilityPreparation:
        guard
          canStartModelPreparation(state: state),
          state.developerMode,
          case .failed(let failure) = state.modelReadiness,
          failure.allowsCompatibilityRetry
        else { return .none }
        let abandonedDiagnosis =
          abandonScopeDiagnosisForModelMaintenance(state: &state)
        diagnostics.info(
          category: .submission,
          code: "model_compatibility_preparation_requested",
          summary: "The user requested compatibility model preparation.",
          context: ["failed_stage": failure.stage.rawValue])
        setModelReadiness(.preparing, state: &state)
        state.modelPreparationReport = nil
        state.modelPreparationInFlight = true
        return .merge(
          abandonedDiagnosis, preparationEffect(mode: .compatibility))

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
        // A diagnosis memo retained while the model was preparing has no
        // other foreground re-check hook; give it the same interrupted-first
        // ordering activation uses.
        return .merge(
          startLaunchBenchmarkIfReady(state: &state),
          resumeInterruptedScopeDiagnosisIfIdle(state: &state),
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
          var effects: [Effect<Action>] = [
            .run { _ in
              await messageUpdateQueue.forgetOnceSave(
                conversationID: conversationID,
                messageID: optimisticTurn.message.id)
            }
          ]
          if let failure {
            let alreadyDeferredForDeletion =
              state.pendingDeletion?.summary.id == conversationID
              && state.pendingDeletion?.deferredFailure != nil
            if !alreadyDeferredForDeletion,
              state.presentedFailure != failure
            {
              effects.append(
                handleConversationWriteFailure(
                  state: &state,
                  conversationID: conversationID,
                  failure: failure))
            }
          }
          return .merge(effects)
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
          // A failure-seeded context runs the Scope Verdict first (C before
          // D): the verdict decides the suggestion strategy and enriches the
          // rendered failure in place.
          if context.isRecoverySeed, let messageID = pending.terminalMessageID {
            effects.append(
              startScopeDiagnosis(
                state: &state,
                conversationID: pending.conversationID,
                messageID: messageID,
                context: context))
          } else {
            effects.append(
              startFollowUpPreparation(
                state: &state,
                conversationID: pending.conversationID,
                context: context))
          }
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
        // The FM-availability watch lands here on recovery. A retained
        // diagnosis memo or persisted `.preparing` batch stranded behind the
        // same outage must get its chance alongside the queue; each resume
        // re-checks its own gates and no-ops when a turn dispatched.
        let queuedTurn = dispatchNextIfIdle(state: &state)
        return .merge(
          queuedTurn,
          resumeInterruptedScopeDiagnosisIfIdle(state: &state),
          resumeFollowUpPreparationIfIdle(state: &state))

      case .followUpPreparationEvent(
        let conversationID, let sourceMessageID, let event):
        return handleFollowUpPreparationEvent(
          state: &state,
          conversationID: conversationID,
          sourceMessageID: sourceMessageID,
          event: event)

      case .scopeDiagnosisFinished(
        let conversationID, let messageID, let verdict):
        return handleScopeDiagnosisFinished(
          state: &state,
          conversationID: conversationID,
          messageID: messageID,
          verdict: verdict)

      case .scopeDiagnosisPersisted(let conversationID, let context):
        // Delivery re-checks the idle gates inside startFollowUpPreparation:
        // a turn dispatched or a conversation deleted while the verdict
        // persisted vetoes the preparation instead of racing it.
        guard state.isSceneActive else {
          // Deactivation raced the verdict write, which carries no cancel ID
          // so the durable enrichment always lands. Never start FM/MLX work
          // in the background; retain the verdict-enriched context exactly
          // like a backgrounded diagnosis so reactivation resumes Recovery
          // Suggestion preparation.
          if state.conversations[id: conversationID] != nil {
            state.pendingScopeDiagnosis = PendingScopeDiagnosis(
              conversationID: conversationID,
              messageID: context.sourceAssistantMessageID,
              context: context)
          }
          return .none
        }
        return startFollowUpPreparation(
          state: &state,
          conversationID: conversationID,
          context: context)

      case .chat(.delegate(.submitQuestion(let submission))):
        refreshFMAvailability(state: &state)
        guard let chat = state.chat else { return .none }
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
        if state.isTurnSchedulerIdle,
          state.modelReadiness == .ready,
          state.fmAvailability == .available
        {
          let userTurn = dispatch(
            state: &state,
            conversationID: conversationID,
            submission: submission)
          return .concatenate(
            cancelPreparation,
            .merge(clearBatch, userTurn))
        }
        // Never drop a committed submission: the composer is already cleared
        // and the draft overwritten. A submission that cannot dispatch —
        // scheduler busy, model not ready, or Apple Intelligence unavailable —
        // becomes a Queued Question and dispatches when the gate reopens.
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
          context: [
            "queue_depth": String(state.queue.count),
            "fm_available": String(state.fmAvailability == .available),
          ])
        // Re-running the scheduler here is what arms the availability watch
        // when the queue is stranded behind an unavailable FM, and what
        // drains an already-idle queue after recovery.
        return .concatenate(
          cancelPreparation,
          .merge(clearBatch, dispatchNextIfIdle(state: &state)))

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

      case .answerabilityCaptureTapped:
        #if DEBUG
          guard !state.isCapturingAnswerability else { return .none }
          // The capture's 87 serialized Scope Verdict calls share the
          // InferenceSerializer with turn stages, whose deadlines keep
          // ticking while queued, and the 1.75 GB model load must never
          // overlap them. Start only from a fully idle scheduler with no
          // model preparation in flight.
          guard state.isSceneActive,
            state.fmAvailability == .available,
            !state.modelPreparationInFlight,
            state.isInferenceIdle
          else { return .none }
          let captureID = uuid()
          state.isCapturingAnswerability = true
          state.answerabilityCaptureID = captureID
          let previousExport = state.answerabilityCaptureExport
          state.answerabilityCaptureExport = nil
          let capturedAt = now
          let client = scopeDiagnosis
          return .run { send in
            if let previousExport {
              try? FileManager.default.removeItem(at: previousExport)
            }
            let url = await AnswerabilityCapture.run(
              client: client,
              capturedAt: capturedAt)
            await send(.answerabilityCaptureReady(id: captureID, url: url))
          }
          .cancellable(
            id: CancelID.answerabilityCapture,
            cancelInFlight: true)
        #else
          return .none
        #endif

      case .answerabilityCaptureReady(let captureID, let url):
        guard state.isCapturingAnswerability,
          state.answerabilityCaptureID == captureID
        else {
          // A cancelled capture's completion can win the race with its
          // cancellation, including while a NEWER capture is already in
          // flight. The archive path is unique per capture, so removing a
          // stale one can never touch a live capture's output.
          guard let url else { return .none }
          return .run { _ in try? FileManager.default.removeItem(at: url) }
        }
        state.isCapturingAnswerability = false
        state.answerabilityCaptureID = nil
        state.answerabilityCaptureExport = url
        if url == nil {
          state.presentedFailure = FailurePresentation(
            code: "answerability_capture_failed",
            title: "Capture failed",
            message:
              "CREG couldn't judge every corpus item. Keep Apple Intelligence available and try the capture again.",
            diagnostic:
              "Answerability capture returned no complete corpus-exact artifact.")
        }
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
}
