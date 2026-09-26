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
    public var isExisting: Bool

    public init(
      message: ChatMessage,
      previousSummary: ConversationSummary?,
      previousChatTitle: String?,
      isExisting: Bool = false
    ) {
      self.message = message
      self.previousSummary = previousSummary
      self.previousChatTitle = previousChatTitle
      self.isExisting = isExisting
    }
  }

  /// The single globally active turn.
  public struct ActiveTurn: Equatable, Sendable {
    public var questionID: UUID
    public var conversationID: UUID
    public var question: String
    public var submission: QuestionSubmission
    public var replacingJournalID: UUID?
    public var replacedInterruptedTurn: InterruptedTurn?
    public var starter: StarterQueryID? {
      guard case .starter(let starter) = submission.source else { return nil }
      return starter
    }
    public var provisionalAssistantMessageID: UUID?
    public var resultPresentationPreference: ResultPresentationPreference?
    public var startedAt: Date
    public var autoRetryCount = 0
    public var isAutomaticRetry = false
    public var directlyUserStarted = true
    public var preflightCompleted = false
    public var pipelineStarted = false
    public var backgroundGPUGranted = false
    public var interruptionAmbiguous = false
    /// The Conversation's suggestion generation this turn was accepted
    /// under; its answer's suggestions are owned by exactly this value.
    public var suggestionGeneration = 0
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
      self.replacingJournalID = nil
      self.replacedInterruptedTurn = nil
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
      self.replacingJournalID = nil
      self.replacedInterruptedTurn = nil
      self.startedAt = startedAt
    }
  }

  /// A completed turn whose durable transcript write still owns the scheduler
  /// barrier. A timeout is diagnostic only: advancing while the write remains
  /// alive would let the next turn observe or persist an out-of-order history.
  public struct PendingTurnPersistence: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
      case writing
      case drainingInference
    }

    public var questionID: UUID
    public var conversationID: UUID
    public var phase: Phase = .writing
    public var didTimeOut = false
    public var didDrainTimeOut = false
    public var followUpContext: FollowUpSuggestionContext?
    public var suggestionGeneration = 0
    public var userMessageID: UUID?
    public var terminalMessageID: UUID?
    public var replacedInterruptedTurn: InterruptedTurn?

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
    /// The suggestion generation that owns this context. A newer accepted
    /// question retires it instead of parking or resuming it.
    public var generation: Int
    /// True once the judge ran to completion for this context, so a parked
    /// nil verdict resumes straight into preparation.
    public var scopeDiagnosisCompleted: Bool

    public init(
      conversationID: UUID,
      messageID: UUID,
      context: FollowUpSuggestionContext,
      generation: Int = 0,
      scopeDiagnosisCompleted: Bool = false
    ) {
      self.conversationID = conversationID
      self.messageID = messageID
      self.context = context
      self.generation = generation
      self.scopeDiagnosisCompleted = scopeDiagnosisCompleted
    }

    /// The judge is still owed only for a Recovery Suggestion context that
    /// has neither a verdict nor a completed judge call.
    public var needsScopeDiagnosis: Bool {
      guard case .turnFailure(_, let verdict) = context.seed else { return false }
      return verdict == nil && !scopeDiagnosisCompleted
    }
  }

  public struct FollowUpPreparationState: Equatable, Sendable {
    public var conversationID: UUID
    public var context: FollowUpSuggestionContext
    public var batch: PreparedFollowUpBatch
    public var generation: Int
    public var eventLines: [String] = []

    public init(
      conversationID: UUID,
      context: FollowUpSuggestionContext,
      batch: PreparedFollowUpBatch,
      generation: Int = 0
    ) {
      self.conversationID = conversationID
      self.context = context
      self.batch = batch
      self.generation = generation
    }
  }

  /// An interrupted turn's own data, retained so its single automatic retry
  /// can queue and dispatch even while its conversation is offscreen. Only
  /// interruptions recorded by this process ever become candidates; a
  /// relaunch offers Ask Again alone.
  public struct AutomaticRetryCandidate: Equatable, Sendable {
    public var journalID: UUID
    public var conversationID: UUID
    public var submission: QuestionSubmission
    public var userMessage: ChatMessage
    public var suggestionGeneration: Int?

    public init(
      journalID: UUID,
      conversationID: UUID,
      submission: QuestionSubmission,
      userMessage: ChatMessage,
      suggestionGeneration: Int? = nil
    ) {
      self.journalID = journalID
      self.conversationID = conversationID
      self.submission = submission
      self.userMessage = userMessage
      self.suggestionGeneration = suggestionGeneration
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

  public struct PendingDismissalFailure: Equatable, Sendable {
    public var conversationID: UUID
    public var journalID: UUID
    public var failure: FailurePresentation
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
    /// Holds the scheduler while the cancelled turn's journal is made durable.
    public var pendingInterruptedTurn: ActiveTurn?
    public var retryClaimInFlight = false
    public var retryClaimJournalID: UUID?
    public var retryClaimConversationID: UUID?
    /// Same-process interruptions eligible for their one automatic retry,
    /// keyed by journal ID. Hydrated journals never appear here.
    public var automaticRetryCandidates: [UUID: AutomaticRetryCandidate] = [:]
    public var userPromotedRetryJournalIDs: Set<UUID> = []
    /// Retries the user cancelled from the banner while their claim or
    /// release was still in flight; the completion declines instead of
    /// dispatching.
    public var cancelledRetryJournalIDs: Set<UUID> = []
    public var retryReleaseJournalID: UUID?
    public var retryClaimCleanupJournalID: UUID?
    public var dismissedRetryJournalIDs: Set<UUID> = []
    public var failedDismissalManualRetryIDs: Set<UUID> = []
    public var failedDismissalAwaitingClaim: PendingDismissalFailure?
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
    /// Latest postponed suggestion or recovery context for each conversation.
    public var pendingSuggestionContexts: [UUID: PendingScopeDiagnosis] = [:]
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
    /// A rejected submission whose draft chat could not be created. The text
    /// is retained here so it is never silently lost.
    public var unsavedRejectedSubmission: String?
    public var modelPreparationReport: ModelPreparationReport?
    /// Appearance can re-fire while the root store remains alive. These
    /// session-only flags keep journal inspection and preparation once-only.
    public var didRequestPreparationJournalInspection = false
    public var didHandlePreparationJournalInspection = false
    public var modelPreparationInFlight = false
    public var modelPreparationModeInFlight: ModelRuntimeMode?
    public var modelPreparationAttemptID: UUID?
    public var suspendedModelPreparationMode: ModelRuntimeMode?
    public var drainingModelPreparationAttemptID: UUID?
    public var pendingPreparationRetryMode: ModelRuntimeMode?
    public var pressureGeneration: UUID?
    public var thermalPressure = false
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
      activeTurn == nil && pendingInterruptedTurn == nil
        && !retryClaimInFlight && retryClaimCleanupJournalID == nil
        && retryReleaseJournalID == nil
        && queue.isEmpty
        && pendingTurnPersistence == nil
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

    /// Queued turns cannot run until a failed or suspended model is ready.
    public var isModelRecoveryIdle: Bool {
      activeTurn == nil && pendingInterruptedTurn == nil
        && !retryClaimInFlight && retryClaimCleanupJournalID == nil
        && retryReleaseJournalID == nil
        && pendingTurnPersistence == nil
        && followUpPreparation == nil && !isCapturingAnswerability
        && drainingModelPreparationAttemptID == nil
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

    /// The deactivation invariant folded into the dispatch gate: a turn may
    /// start only from a foregrounded scene with the serializer free and the
    /// SQL model ready. `queue.isEmpty` is deliberately absent — the
    /// scheduler dispatches *from* the queue — and Apple Intelligence
    /// availability is checked separately by the callers that arm the
    /// recovery watch on it. Every start path shares this rather than
    /// re-spelling the scene check, and `dispatch` asserts it.
    public var canDispatchTurn: Bool {
      isSceneActive
        && activeTurn == nil
        && pendingInterruptedTurn == nil
        && !retryClaimInFlight
        && retryClaimCleanupJournalID == nil
        && retryReleaseJournalID == nil
        && pendingTurnPersistence == nil
        && modelReadiness == .ready
    }

    /// `isInferenceIdle` under the same invariant. Low-priority FM/MLX work
    /// — follow-up preparation, scope diagnosis, debug captures — may start
    /// only from here.
    public var canStartLowPriorityInference: Bool {
      isSceneActive && pressureGeneration == nil && !thermalPressure
        && isInferenceIdle
    }

    /// The variant for the paths that consume the pending Scope Verdict memo
    /// instead of waiting behind it.
    public var canStartLowPriorityInferenceIgnoringScopeDiagnosis: Bool {
      isSceneActive && pressureGeneration == nil && !thermalPressure
        && isInferenceIdleIgnoringScopeDiagnosis
    }

    /// The selected conversation's persisted batch when a resume can
    /// actually pick it up. The FM-availability watch arms on exactly what
    /// `resumeFollowUpPreparationIfIdle` resumes on, so the arm condition
    /// and the resume condition cannot drift into arming for batches that
    /// can never resume — or failing to arm for ones that can.
    public var resumableFollowUpBatch: PreparedFollowUpBatch? {
      guard let batch = chat?.followUpBatch,
        batch.status == .preparing,
        batch.context != nil
      else { return nil }
      return batch
    }
  }

  public enum Action: BindableAction, Sendable, Equatable {
    case binding(BindingAction<State>)
    case onAppear
    case appBecameActive
    case appBecameInactive
    case appEnteredBackground
    case resourcePressure
    case thermalPressureBegan
    case thermalPressureEnded
    case pressureQuiet(UUID)
    case preparationJournalLoaded(ModelPreparationJournalSnapshot?)
    case retryPreparation
    case retryCompatibilityPreparation
    case modelPrepared(ModelPreparationReport, attemptID: UUID? = nil)
    case modelPreparationFailed(ModelPreparationFailure, attemptID: UUID? = nil)
    case modelPreparationSuspended(UUID)
    case bootstrapFinished([ConversationSummary])
    case conversationCreated(ConversationSummary)
    case conversationLoaded(ConversationSnapshot)
    case dismissalRefreshLoaded(ConversationSnapshot)
    /// A rejected submission's draft chat was created durably.
    case rejectedSubmissionSaved(
      ConversationSummary, draft: String, selectionID: UUID)
    case rejectedSubmissionSaveFailed(draft: String, failure: FailurePresentation)
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
    case turnInterruptionRecorded(
      questionID: UUID, userPersisted: Bool, marked: Bool)
    case interruptedDismissalFinished(
      conversationID: UUID, journalID: UUID, failure: FailurePresentation?)
    case dismissedRetryClaimSettled(UUID)
    /// The durable retry count after a successful claim, or nil when the
    /// journal refused it.
    case queuedRetryClaimed(QueuedQuestion, Int?)
    case retryClaimReleased(QueuedQuestion, Bool)
    case queuedRetryStaleChecked(QueuedQuestion, Bool)
    case backgroundTurnReady(executionID: UUID, granted: Bool)
    case dispatchPreflightFinished(questionID: UUID, directlyUserStarted: Bool)
    case backgroundTurnExpired(executionID: UUID)
    case turnPersistenceFailed(
      conversationID: UUID, questionID: UUID, failure: FailurePresentation)
    case userTurnPersistenceFailed(
      conversationID: UUID,
      questionID: UUID,
      optimisticTurn: OptimisticUserTurn,
      failure: FailurePresentation?)
    case conversationWriteFailed(
      conversationID: UUID, failure: FailurePresentation)
    case turnPersistenceWriteSettled(UUID)
    case turnPersistenceFinished(UUID)
    case turnPersistenceTimedOut(UUID)
    case turnPersistenceDrainTimedOut(UUID)
    case dispatchNextIfIdle
    case followUpPreparationEvent(
      conversationID: UUID,
      sourceMessageID: UUID,
      event: FollowUpPreparationEvent)
    case followUpPreparationStreamEnded(
      conversationID: UUID, sourceMessageID: UUID)
    case scopeDiagnosisFinished(
      conversationID: UUID,
      messageID: UUID,
      verdict: ScopeVerdictRecord?)
    /// The Scope Verdict's durable enrichment finished; Recovery Suggestion
    /// preparation (D) starts through this action so its idle gates are
    /// re-checked at delivery time rather than captured before the write.
    case scopeDiagnosisPersisted(
      conversationID: UUID,
      context: FollowUpSuggestionContext,
      generation: Int = 0)
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

  struct TurnPersistenceDrainTimeoutID: Hashable {
    var questionID: UUID
  }

  @Dependency(\.queryPipeline) var pipeline
  @Dependency(\.backgroundTurn) var backgroundTurn
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
        let preflight = resumeDispatchedTurnAfterPreflight(state: &state)
        let requestedModel = resumeRequestedModelPreparation(state: &state)
        let resumedModel = resumeSuspendedModelPreparation(state: &state)
        let autoRetry = claimInterruptedRetry(state: &state, automatic: true)
        // Readiness reached while the app was inactive — a prewarmed launch,
        // or a load that completed after backgrounding — leaves the benchmark
        // undispatched by the deactivation invariant. Activation is its only
        // other hook.
        let benchmark = startLaunchBenchmarkIfReady(state: &state)
        let interruptedRecovery =
          resumeInterruptedScopeDiagnosisIfIdle(state: &state)
        let pendingSuggestions =
          resumePendingSuggestionContextIfIdle(state: &state)
        let persistedPreparation = resumeFollowUpPreparationIfIdle(state: &state)
        let queuedTurn = dispatchNextIfIdle(state: &state)
        return .merge(
          preflight, requestedModel, resumedModel, autoRetry, benchmark,
          interruptedRecovery, pendingSuggestions, persistedPreparation,
          queuedTurn)

      case .appBecameInactive:
        // A brief inactive scene (a notification, Control Center, the app
        // switcher) closes new dispatch and stops availability polling. The
        // active turn and any running low-priority work continue; only
        // entering the background interrupts and suspends them.
        state.isSceneActive = false
        return .cancel(id: CancelID.fmAvailabilityWatch)

      case .appEnteredBackground:
        return deactivateScene(state: &state)

      case .resourcePressure:
        let generation = uuid()
        state.pressureGeneration = generation
        return .merge(
          suspendLowPriorityInference(state: &state),
          suspendModelPreparation(state: &state),
          .run { send in
            try await clock.sleep(for: .seconds(5))
            await send(.pressureQuiet(generation))
          })

      case .thermalPressureBegan:
        state.thermalPressure = true
        return .merge(
          suspendLowPriorityInference(state: &state),
          suspendModelPreparation(state: &state))

      case .thermalPressureEnded:
        state.thermalPressure = false
        guard state.pressureGeneration == nil else { return .none }
        return resumeAfterPressure(state: &state)

      case .pressureQuiet(let generation):
        guard state.pressureGeneration == generation else { return .none }
        state.pressureGeneration = nil
        guard !state.thermalPressure else { return .none }
        return resumeAfterPressure(state: &state)

      case .preparationJournalLoaded(let previous):
        guard
          state.didRequestPreparationJournalInspection,
          !state.didHandlePreparationJournalInspection
        else { return .none }
        state.didHandlePreparationJournalInspection = true
        if let previous {
          // A journal left in `suspending` was deliberately paused by the
          // prior process (it entered the background mid-load) and the raw
          // model work never drained before termination. Nothing failed:
          // show the paused state and wait for an explicit Retry tap.
          // Unexpected-interruption reporting is reserved for attempts that
          // were still running when the process ended.
          if previous.outcome == "suspending" {
            let paused = ModelPreparationFailure(
              code: ModelPreparationFailure.previousPreparationSuspendedCode,
              stage: previous.stage,
              mode: previous.mode,
              userMessage:
                "SQL model preparation was paused when CREG left the foreground. Tap Retry to continue.",
              diagnostic:
                "The prior process was suspending \(previous.stage.rawValue) in \(previous.mode.rawValue) mode when it ended."
            )
            setModelReadiness(.failed(paused), state: &state)
            state.modelPreparationReport = nil
            diagnostics.info(
              category: .model,
              code: paused.code,
              summary: "The previous model preparation attempt was paused and awaits Retry.",
              context: [
                "stage": paused.stage.rawValue,
                "runtime_mode": paused.mode.rawValue,
              ])
            return .none
          }
          let failure = ModelPreparationFailure(
            code: ModelPreparationFailure.previousPreparationInterruptedCode,
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
        guard state.isSceneActive else {
          state.suspendedModelPreparationMode = .evaluated
          return .none
        }
        state.modelPreparationInFlight = true
        state.modelPreparationModeInFlight = .evaluated
        let attemptID = uuid()
        state.modelPreparationAttemptID = attemptID
        return preparationEffect(mode: .evaluated, attemptID: attemptID)

      case .retryPreparation:
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
        state.pendingPreparationRetryMode = .evaluated
        return resumeRequestedModelPreparation(state: &state)

      case .retryCompatibilityPreparation:
        guard
          state.developerMode,
          case .failed(let failure) = state.modelReadiness,
          failure.allowsCompatibilityRetry
        else { return .none }
        diagnostics.info(
          category: .submission,
          code: "model_compatibility_preparation_requested",
          summary: "The user requested compatibility model preparation.",
          context: ["failed_stage": failure.stage.rawValue])
        state.pendingPreparationRetryMode = .compatibility
        return resumeRequestedModelPreparation(state: &state)

      case .modelPreparationSuspended(let attemptID):
        guard state.drainingModelPreparationAttemptID == attemptID else {
          return .none
        }
        state.drainingModelPreparationAttemptID = nil
        return resumeAfterPressure(state: &state)

      case .modelPrepared(let report, let attemptID):
        if let attemptID,
          (!state.modelPreparationInFlight
            || state.modelPreparationAttemptID != attemptID)
        { return .none }
        state.modelPreparationInFlight = false
        state.modelPreparationModeInFlight = nil
        state.modelPreparationAttemptID = nil
        state.suspendedModelPreparationMode = nil
        setModelReadiness(.ready, state: &state)
        refreshFMAvailability(state: &state)
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
        let autoRetry = claimInterruptedRetry(state: &state, automatic: true)
        return .merge(
          autoRetry,
          startLaunchBenchmarkIfReady(state: &state),
          resumeInterruptedScopeDiagnosisIfIdle(state: &state),
          resumePendingSuggestionContextIfIdle(state: &state),
          resumeFollowUpPreparationIfIdle(state: &state),
          dispatchNextIfIdle(state: &state))

      case .modelPreparationFailed(let failure, let attemptID):
        if let attemptID,
          (!state.modelPreparationInFlight
            || state.modelPreparationAttemptID != attemptID)
        { return .none }
        state.modelPreparationInFlight = false
        state.modelPreparationModeInFlight = nil
        state.modelPreparationAttemptID = nil
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
        refreshFMAvailability(state: &state)
        return startLaunchBenchmarkIfReady(state: &state)

      case .conversationLoaded(let snapshot):
        let conversationOwnsActiveTurn =
          state.activeTurn?.conversationID == snapshot.summary.id
        let activePreparedAnswerID =
          conversationOwnsActiveTurn
          ? state.activeTurn?.provisionalAssistantMessageID
          : nil
        // The durable generation can trail an acceptance whose transaction
        // is still in flight, so it only ever raises the in-memory value.
        if var summary = state.conversations[id: snapshot.summary.id] {
          summary.suggestionGeneration = max(
            summary.suggestionGeneration, snapshot.suggestionGeneration)
          state.conversations[id: snapshot.summary.id] = summary
        }
        state.chat = ChatFeature.State(
          snapshot: snapshot,
          preservingActiveTurn: conversationOwnsActiveTurn,
          preservingPreparedAnswerID: activePreparedAnswerID)
        if let batch = state.chat?.followUpBatch,
          !ownsSuggestions(
            state: state, conversationID: snapshot.summary.id,
            generation: batch.effectiveGeneration)
        {
          state.chat?.followUpBatch = nil
        }
        syncSchedulerProjection(into: &state)
        state.isBrowserRevealed = false
        // One availability read serves all three gates below: the launch
        // benchmark's dispatch, the stranded-work watch, and the resume.
        refreshFMAvailability(state: &state)
        var effects: [Effect<Action>] = []
        let recovered = snapshot.recoveredPreparedAnswers(
          excluding: activePreparedAnswerID)
        if !recovered.isEmpty {
          let conversationID = snapshot.summary.id
          if let latest = recovered.last {
            state.conversations[id: conversationID]?.latestMessagePreview =
              latest.message.previewText
          }
          effects.append(
            .run { _ in
              for answer in recovered {
                let saved = try? await messageUpdateQueue.save(
                  conversationID: conversationID,
                  messageID: answer.message.id
                ) {
                  try await history.updateMessage(conversationID, answer.message)
                }
                guard saved == .saved,
                  let userMessageID = answer.precedingUserMessageID,
                  let interruption = snapshot.interruptedTurns.first(where: {
                    $0.executionID == userMessageID
                      && $0.question == answer.question
                  }),
                  let journalID = interruption.journalID ?? interruption.executionID
                else { continue }
                try? await history.endTurnJournal(conversationID, journalID)
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
        effects.append(claimInterruptedRetry(state: &state, automatic: true))
        effects.append(startLaunchBenchmarkIfReady(state: &state))
        // Loading can reveal a persisted `.preparing` batch after the scene's
        // activation action already ran. Refresh/arm first so an unavailable
        // FM has a foreground recovery hook, then resume immediately when the
        // refreshed status is already available.
        effects.append(watchFMAvailabilityIfStranded(state: &state))
        effects.append(resumePendingSuggestionContextIfIdle(state: &state))
        effects.append(resumeFollowUpPreparationIfIdle(state: &state))
        return .merge(effects)

      case .dismissalRefreshLoaded(let snapshot):
        guard state.chat?.conversationID == snapshot.summary.id,
          state.pendingDeletion?.summary.id != snapshot.summary.id
        else { return .none }
        let ownsActive = state.activeTurn?.conversationID == snapshot.summary.id
        state.chat = ChatFeature.State(
          snapshot: snapshot,
          preservingActiveTurn: ownsActive,
          preservingPreparedAnswerID:
            ownsActive ? state.activeTurn?.provisionalAssistantMessageID : nil)
        syncSchedulerProjection(into: &state)
        return .none

      case .rejectedSubmissionSaved(let summary, let draft, let selectionID):
        state.conversations.insert(summary, at: 0)
        state.conversations.sort { $0.lastActivityAt > $1.lastActivityAt }
        diagnostics.info(
          category: .submission,
          code: "rejected_submission_saved",
          summary: "A rejected submission was saved as a draft in a new conversation.")
        // Follow the user only if they stayed put: a selection that moved on
        // while the draft chat was being created keeps its own state.
        if state.chat?.conversationID == selectionID,
          state.pendingDeletion?.summary.id != selectionID
        {
          state.chat = ChatFeature.State(
            conversationID: summary.id, composerText: draft)
          syncSchedulerProjection(into: &state)
          state.isBrowserRevealed = false
          refreshFMAvailability(state: &state)
        }
        return .send(.operationFailed(FailurePresentation(
          code: "submission_conversation_unavailable",
          title: "Question not sent",
          message:
            "That conversation is unavailable. Your question is saved as a draft in a new chat.",
          diagnostic:
            "Submission origin was missing, deleted, or no longer selected; the draft chat was created.")))

      case .rejectedSubmissionSaveFailed(let draft, let failure):
        state.unsavedRejectedSubmission = draft
        return .send(.operationFailed(FailurePresentation(
          code: "submission_draft_save_failed",
          title: "Question not sent",
          message:
            "That conversation is unavailable and the question could not be saved. Copy it before continuing: \u{201C}\(draft)\u{201D}",
          diagnostic: failure.diagnostic)))

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

      case .turnInterruptionRecorded(
        let questionID, let userPersisted, let marked):
        guard let interrupted = state.pendingInterruptedTurn,
          interrupted.questionID == questionID
        else { return .none }
        state.pendingInterruptedTurn = nil
        // The retry entry is built from the interrupted turn's own data so it
        // queues, ordered by the original question time, even when its
        // conversation is offscreen. A turn that already spent its single
        // automatic retry never becomes a candidate again.
        if userPersisted, marked, !interrupted.interruptionAmbiguous,
          interrupted.autoRetryCount == 0,
          let optimistic = interrupted.optimisticUserTurn
        {
          state.automaticRetryCandidates[interrupted.questionID] =
            AutomaticRetryCandidate(
              journalID: interrupted.questionID,
              conversationID: interrupted.conversationID,
              submission: interrupted.submission,
              userMessage: optimistic.message,
              suggestionGeneration: interrupted.suggestionGeneration)
        }
        if !userPersisted {
          if let optimistic = interrupted.optimisticUserTurn {
            rollBackOptimisticUserTurn(
              state: &state,
              questionID: questionID,
              conversationID: interrupted.conversationID,
              optimisticTurn: optimistic)
          }
          return .send(.dispatchNextIfIdle)
        }
        if state.chat?.conversationID == interrupted.conversationID {
          let entry = InterruptedTurn(
            question: interrupted.question,
            interruptedAt: now,
            journalID: interrupted.questionID,
            source: interrupted.submission.source,
            executionID: interrupted.questionID,
            status: marked
              ? (interrupted.interruptionAmbiguous
                  ? .ambiguousInterruption : .knownInterruption)
              : .running,
            autoRetryCount: interrupted.autoRetryCount)
          if let index = state.chat?.interruptedTurns.firstIndex(where: {
            $0.journalID == interrupted.questionID
          }) {
            state.chat?.interruptedTurns[index] = entry
          } else {
            state.chat?.interruptedTurns.append(entry)
          }
        }
        syncSchedulerProjection(into: &state)
        let autoRetry = claimInterruptedRetry(state: &state, automatic: true)
        return .merge(
          autoRetry,
          watchFMAvailabilityIfStranded(state: &state),
          dispatchNextIfIdle(state: &state))

      case .queuedRetryClaimed(let queued, let retryCount):
        guard let journalID = queued.retryJournalID else {
          return .send(.dispatchNextIfIdle)
        }
        state.retryClaimInFlight = false
        state.retryClaimJournalID = nil
        state.retryClaimConversationID = nil
        let claimed = retryCount != nil
        if state.dismissedRetryJournalIDs.contains(journalID) {
          return settleDismissedRetryClaim(
            state: &state, conversationID: queued.conversationID,
            journalID: journalID, claimed: claimed)
        }
        if state.cancelledRetryJournalIDs.remove(journalID) != nil {
          // Cancelled from the banner while the claim was in flight. The
          // journal row survives for Ask Again; only the automatic allowance
          // is declined.
          state.automaticRetryCandidates.removeValue(forKey: journalID)
          state.userPromotedRetryJournalIDs.remove(journalID)
          syncSchedulerProjection(into: &state)
          let conversationID = queued.conversationID
          return .merge(
            .run { _ in
              if claimed {
                try? await history.declineAutoRetry(conversationID, journalID)
              }
            },
            .send(.dispatchNextIfIdle))
        }
        if claimed, queued.automaticRetry,
          state.userPromotedRetryJournalIDs.remove(journalID) != nil,
          let executionID = queued.existingUserMessage?.id
        {
          // Ask Again arrived while the automatic claim was in flight: take
          // the row over as a manual claim so the dispatch is user-started
          // and the count the manual claim reports is the durable one.
          let promoted = QueuedQuestion(
            id: queued.id, conversationID: queued.conversationID,
            submission: queued.submission,
            retryJournalID: journalID,
            existingUserMessage: queued.existingUserMessage,
            automaticRetry: false, submittedAt: queued.submittedAt)
          state.automaticRetryCandidates.removeValue(forKey: journalID)
          state.retryClaimInFlight = true
          state.retryClaimJournalID = journalID
          state.retryClaimConversationID = queued.conversationID
          syncSchedulerProjection(into: &state)
          return .run { send in
            do {
              let promotedCount = try await history.claimTurnRetry(
                queued.conversationID, journalID, executionID, false)
              await send(.queuedRetryClaimed(promoted, promotedCount))
            } catch {
              await send(.queuedRetryClaimed(promoted, nil))
              await send(.operationFailed(
                .history(operation: .messageSave, error: error)))
            }
          }
        }
        if !queued.automaticRetry {
          state.userPromotedRetryJournalIDs.remove(journalID)
        }
        guard let retryCount else {
          // Every failed claim restarts the scheduler through the stale
          // check below, so a refused journal can never strand the queue.
          state.automaticRetryCandidates.removeValue(forKey: journalID)
          if queued.automaticRetry,
            state.chat?.conversationID == queued.conversationID,
            let index = state.chat?.interruptedTurns.firstIndex(where: {
              ($0.journalID ?? $0.executionID) == journalID
            })
          {
            state.chat?.interruptedTurns[index].status = .manualRetryRequired
          }
          syncSchedulerProjection(into: &state)
          let failure = FailurePresentation(
            code: "retry_claim_failed",
            title: queued.automaticRetry
              ? "Could not retry automatically" : "Could not retry",
            message: queued.automaticRetry
              ? "Ask Again to retry this question."
              : "Please tap Ask Again to try once more.",
            diagnostic: "The interruption journal claim did not succeed.")
          return .merge(.send(.operationFailed(failure)), .run { send in
            let snapshot = try? await history.loadConversation(queued.conversationID)
            let exists = snapshot?.interruptedTurns.contains(where: {
              $0.journalID == journalID
            }) == true
            await send(.queuedRetryStaleChecked(queued, exists))
          })
        }
        guard state.conversations[id: queued.conversationID] != nil else {
          // The conversation is gone; its row was deleted with it.
          state.automaticRetryCandidates.removeValue(forKey: journalID)
          return .send(.dispatchNextIfIdle)
        }
        if !state.canDispatchTurn || state.fmAvailability != .available
          || state.pendingDeletion?.summary.id == queued.conversationID
        {
          return releaseRetryClaim(state: &state, queued: queued)
        }
        state.automaticRetryCandidates.removeValue(forKey: journalID)
        if state.chat?.conversationID == queued.conversationID {
          state.chat?.interruptedTurns.removeAll {
            ($0.journalID ?? $0.executionID) == journalID
          }
        }
        return dispatch(
          state: &state, conversationID: queued.conversationID,
          submission: queued.submission,
          existingUserMessage: queued.existingUserMessage,
          autoRetryCount: retryCount,
          isAutomaticRetry: queued.automaticRetry,
          directlyUserStarted: !queued.automaticRetry,
          acceptedSuggestionGeneration: queued.suggestionGeneration)

      case .retryClaimReleased(let queued, let released):
        guard let journalID = queued.retryJournalID,
          state.retryReleaseJournalID == journalID
        else { return .none }
        state.retryReleaseJournalID = nil
        let cancelled = state.cancelledRetryJournalIDs.remove(journalID) != nil
        let stillWanted =
          !cancelled
          && !state.dismissedRetryJournalIDs.contains(journalID)
          && state.conversations[id: queued.conversationID] != nil
          && state.pendingDeletion?.summary.id != queued.conversationID
        if released, stillWanted {
          // The row is open again. A manual Ask Again request stays queued
          // for the next open gate; an automatic claim's allowance is back,
          // so its candidate re-enqueues from `dispatchNextIfIdle` unless
          // Ask Again promoted it in the meantime.
          let promoted = state.userPromotedRetryJournalIDs.remove(journalID) != nil
          if !queued.automaticRetry || promoted {
            var manual = queued
            manual.automaticRetry = false
            state.automaticRetryCandidates.removeValue(forKey: journalID)
            if !state.queue.contains(where: { $0.retryJournalID == journalID }) {
              insertQueuedQuestion(manual, into: &state)
            }
          }
          if queued.automaticRetry,
            state.chat?.conversationID == queued.conversationID,
            let index = state.chat?.interruptedTurns.firstIndex(where: {
              ($0.journalID ?? $0.executionID) == journalID
            })
          {
            state.chat?.interruptedTurns[index].status = .knownInterruption
            state.chat?.interruptedTurns[index].autoRetryCount = 0
          }
        } else {
          state.automaticRetryCandidates.removeValue(forKey: journalID)
          state.userPromotedRetryJournalIDs.remove(journalID)
          if state.chat?.conversationID == queued.conversationID,
            let index = state.chat?.interruptedTurns.firstIndex(where: {
              ($0.journalID ?? $0.executionID) == journalID
            })
          {
            state.chat?.interruptedTurns[index].status = .manualRetryRequired
          }
          if !released {
            state.presentedFailure = .history(
              operation: .messageSave,
              error: NSError(
                domain: "CREG.Retry", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not release the retry claim."]))
          }
        }
        syncSchedulerProjection(into: &state)
        if cancelled {
          let conversationID = queued.conversationID
          return .merge(
            .run { _ in
              try? await history.declineAutoRetry(conversationID, journalID)
            },
            .send(.dispatchNextIfIdle))
        }
        return .send(.dispatchNextIfIdle)

      case .queuedRetryStaleChecked(let queued, let journalExists):
        guard let journalID = queued.retryJournalID,
          !state.dismissedRetryJournalIDs.contains(journalID)
        else { return .send(.dispatchNextIfIdle) }
        guard journalExists else { return .send(.dispatchNextIfIdle) }
        if queued.automaticRetry {
          if state.chat?.conversationID == queued.conversationID,
            let index = state.chat?.interruptedTurns.firstIndex(where: {
              $0.journalID == journalID
            })
          {
            state.chat?.interruptedTurns[index].status = .manualRetryRequired
          }
          return .run { send in
            try? await history.declineAutoRetry(queued.conversationID, journalID)
            await send(.dispatchNextIfIdle)
          }
        }
        let appended = QueuedQuestion(
          id: queued.id, conversationID: queued.conversationID,
          submission: queued.submission, retryJournalID: journalID,
          existingUserMessage: nil, submittedAt: queued.submittedAt)
        if !state.canDispatchTurn || state.fmAvailability != .available
          || !state.queue.isEmpty
        {
          state.queue.insert(appended, at: 0)
          syncSchedulerProjection(into: &state)
          return .send(.dispatchNextIfIdle)
        }
        return dispatch(
          state: &state, conversationID: queued.conversationID,
          submission: queued.submission,
          directlyUserStarted: true, replacingJournalID: journalID)

      case .interruptedDismissalFinished(
        let conversationID, let journalID, let failure):
        guard let failure else {
          state.automaticRetryCandidates.removeValue(forKey: journalID)
          state.userPromotedRetryJournalIDs.remove(journalID)
          state.failedDismissalManualRetryIDs.remove(journalID)
          return .none
        }
        if state.retryClaimJournalID == journalID
          || state.retryClaimCleanupJournalID == journalID
        {
          state.failedDismissalAwaitingClaim = PendingDismissalFailure(
            conversationID: conversationID,
            journalID: journalID,
            failure: failure)
          return .none
        }
        let reload = reloadDismissalIfSelected(
          state: state, conversationID: conversationID)
        state.failedDismissalManualRetryIDs.insert(journalID)
        return .merge(.send(.operationFailed(failure)), reload)

      case .dismissedRetryClaimSettled(let journalID):
        guard state.retryClaimCleanupJournalID == journalID else { return .none }
        state.retryClaimCleanupJournalID = nil
        guard let deferred = state.failedDismissalAwaitingClaim,
          deferred.journalID == journalID
        else {
          return .send(.dispatchNextIfIdle)
        }
        state.failedDismissalAwaitingClaim = nil
        state.failedDismissalManualRetryIDs.insert(journalID)
        let reload = reloadDismissalIfSelected(
          state: state, conversationID: deferred.conversationID)
        return .merge(
          .send(.operationFailed(deferred.failure)),
          reload,
          .send(.dispatchNextIfIdle))

      case .backgroundTurnReady(let executionID, let granted):
        guard state.activeTurn?.questionID == executionID else {
          return .run { _ in await backgroundTurn.finish(executionID, false) }
        }
        state.activeTurn?.backgroundGPUGranted = granted
        return .none

      case .dispatchPreflightFinished(let questionID, let directlyUserStarted):
        guard state.activeTurn?.questionID == questionID else { return .none }
        state.activeTurn?.preflightCompleted = true
        state.activeTurn?.directlyUserStarted = directlyUserStarted
        return resumeDispatchedTurnAfterPreflight(state: &state)

      case .backgroundTurnExpired(let executionID):
        guard state.activeTurn?.questionID == executionID else {
          return .run { _ in await backgroundTurn.finish(executionID, false) }
        }
        state.activeTurn?.backgroundGPUGranted = false
        return interruptActiveTurn(state: &state, ambiguous: true)

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
          if !optimisticTurn.isExisting,
            state.chat?.conversationID == conversationID
          {
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
        let replacedInterruptedTurn =
          state.activeTurn?.replacedInterruptedTurn
          ?? state.pendingTurnPersistence?.replacedInterruptedTurn
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
        if let replacedInterruptedTurn,
          state.chat?.conversationID == conversationID
        {
          state.chat?.interruptedTurns.append(replacedInterruptedTurn)
        }
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

      case .turnPersistenceWriteSettled(let questionID):
        guard state.pendingTurnPersistence?.questionID == questionID,
          state.pendingTurnPersistence?.phase == .writing
        else {
          return .none
        }
        state.pendingTurnPersistence?.phase = .drainingInference
        if state.presentedFailure?.code == "turn_persistence_barrier_timed_out" {
          state.presentedFailure = nil
        }
        return .merge(
          .cancel(id: TurnPersistenceTimeoutID(questionID: questionID)),
          turnPersistenceDrainWatchdog(questionID: questionID))

      case .turnPersistenceFinished(let questionID):
        guard let pending = state.pendingTurnPersistence,
          pending.questionID == questionID
        else { return .none }
        state.pendingTurnPersistence = nil
        if state.presentedFailure?.code == "turn_persistence_barrier_timed_out"
          || state.presentedFailure?.code == "turn_inference_drain_timed_out"
        {
          state.presentedFailure = nil
        }
        var effects: [Effect<Action>] = [
          .cancel(id: TurnPersistenceTimeoutID(questionID: questionID)),
          .cancel(id: TurnPersistenceDrainTimeoutID(questionID: questionID)),
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
        if let context = pending.followUpContext,
          ownsSuggestions(
            state: state, conversationID: pending.conversationID,
            generation: pending.suggestionGeneration)
        {
          // The barrier can settle long after the last availability
          // snapshot, and every branch below reads it — the judge gate, the
          // preparation gate, and the retention decision. One read serves
          // them all. A context whose generation was retired by a newer
          // accepted question is dropped here instead of parked.
          refreshFMAvailability(state: &state)
          // A failure-seeded context runs the Scope Verdict first (C before
          // D): the verdict decides the suggestion strategy and enriches the
          // rendered failure in place.
          if context.isRecoverySeed, let messageID = pending.terminalMessageID {
            effects.append(
              startScopeDiagnosis(
                state: &state,
                conversationID: pending.conversationID,
                messageID: messageID,
                context: context,
                generation: pending.suggestionGeneration))
          } else {
            effects.append(
              startOrRetainFollowUpPreparation(
                state: &state,
                conversationID: pending.conversationID,
                context: context,
                generation: pending.suggestionGeneration))
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
          pending.phase == .writing,
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

      case .turnPersistenceDrainTimedOut(let questionID):
        guard var pending = state.pendingTurnPersistence,
          pending.questionID == questionID,
          pending.phase == .drainingInference,
          !pending.didDrainTimeOut
        else { return .none }
        pending.didDrainTimeOut = true
        state.pendingTurnPersistence = pending
        diagnostics.record(DiagnosticEvent(
          level: .error,
          category: .inference,
          code: "turn_inference_drain_timed_out",
          summary:
            "Queue dispatch remains paused because a cancelled model operation has not released the inference serializer.",
          context: ["question_id": questionID.uuidString]))
        if state.presentedFailure == nil {
          state.presentedFailure = FailurePresentation(
            code: "turn_inference_drain_timed_out",
            title: "Finishing model work is taking longer than expected",
            message:
              "CREG is waiting for the previous model operation to finish. New questions remain paused so model work cannot overlap. Restart CREG if it does not recover.",
            diagnostic:
              "The inference serializer remained occupied five seconds after the turn's history write settled.")
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
          resumePendingSuggestionContextIfIdle(state: &state),
          resumeFollowUpPreparationIfIdle(state: &state))

      case .followUpPreparationEvent(
        let conversationID, let sourceMessageID, let event):
        return handleFollowUpPreparationEvent(
          state: &state,
          conversationID: conversationID,
          sourceMessageID: sourceMessageID,
          event: event)

      case .followUpPreparationStreamEnded(
        let conversationID, let sourceMessageID):
        return handleFollowUpPreparationStreamEnded(
          state: &state,
          conversationID: conversationID,
          sourceMessageID: sourceMessageID)

      case .scopeDiagnosisFinished(
        let conversationID, let messageID, let verdict):
        return handleScopeDiagnosisFinished(
          state: &state,
          conversationID: conversationID,
          messageID: messageID,
          verdict: verdict)

      case .scopeDiagnosisPersisted(let conversationID, let context, let generation):
        // Delivery re-checks the gates: a turn dispatched or a conversation
        // deleted while the verdict persisted vetoes the preparation instead
        // of racing it. The write carries no cancel ID, so its completion
        // always lands — including after deactivation or after Apple
        // Intelligence went away — and every other closed gate retains the
        // verdict-enriched context rather than discarding the only copy.
        refreshFMAvailability(state: &state)
        return startOrRetainFollowUpPreparation(
          state: &state,
          conversationID: conversationID,
          context: context,
          generation: generation,
          scopeDiagnosisCompleted: true)

      case .chat(.delegate(.submitQuestion(let submission))):
        refreshFMAvailability(state: &state)
        guard let chat = state.chat else { return .none }
        let conversationID = submission.originConversationID ?? chat.conversationID
        guard chat.conversationID == conversationID,
          state.conversations[id: conversationID] != nil,
          state.pendingDeletion?.summary.id != conversationID
        else {
          // The origin is gone or no longer selected. The text goes into a
          // brand-new chat's draft in one transaction, never into whichever
          // chat happens to be selected, and "saved" is reported only once
          // that transaction has succeeded.
          let question = submission.question
          let selectionID = chat.conversationID
          let id = uuid()
          let startedAt = now
          diagnostics.info(
            category: .submission,
            code: "submission_origin_unavailable",
            summary:
              "A submission's origin conversation was missing, deleted, or no longer selected.")
          return .run { send in
            do {
              let summary = try await history.createConversationWithDraft(
                id, startedAt, question)
              await send(.rejectedSubmissionSaved(
                summary, draft: question, selectionID: selectionID))
            } catch {
              await send(.rejectedSubmissionSaveFailed(
                draft: question,
                failure: .history(operation: .conversationCreate, error: error)))
            }
          }
        }
        let acceptDraft: Effect<Action> =
          if submission.clearsComposerOnAcceptance == true {
            .concatenate(
              .cancel(id: ChatFeature.DraftSaveID(conversationID: conversationID)),
              .run { _ in try? await history.saveDraft(conversationID, "") })
          } else { .none }
        if submission.clearsComposerOnAcceptance == true {
          state.chat?.composerText = ""
        }
        // Accepting the question retires every suggestion owned by the
        // previous generation: the visible chips, any parked context, and
        // the durable batch, in the same transaction that advances the
        // generation. This happens before the question queues or dispatches.
        let generation = acceptQuestion(state: &state, conversationID: conversationID)
        let preparation = state.followUpPreparation
        state.followUpPreparation = nil
        let cancelPreparation = Effect<Action>.cancel(
          id: CancelID.followUpPreparation)
        let retireBatch = Effect<Action>.run { _ in
          if let preparation, !preparation.eventLines.isEmpty {
            try? await history.appendEvents(
              preparation.conversationID,
              preparation.context.sourceAssistantMessageID,
              preparation.eventLines)
          }
          try? await history.acceptQuestion(conversationID, generation)
        }
        if state.canDispatchTurn,
          state.queue.isEmpty,
          state.fmAvailability == .available
        {
          let userTurn = dispatch(
            state: &state,
            conversationID: conversationID,
            submission: submission,
            acceptedSuggestionGeneration: generation)
          let appendPreparationEvents = Effect<Action>.run { _ in
            if let preparation, !preparation.eventLines.isEmpty {
              try? await history.appendEvents(
                preparation.conversationID,
                preparation.context.sourceAssistantMessageID,
                preparation.eventLines)
            }
          }
          return .concatenate(
            acceptDraft,
            cancelPreparation,
            appendPreparationEvents,
            userTurn)
        }
        // Never drop a committed submission: the composer is already cleared
        // and the draft overwritten. A submission that cannot dispatch —
        // scheduler busy, model not ready, or Apple Intelligence unavailable —
        // becomes a Queued Question and dispatches when the gate reopens.
        let queued = QueuedQuestion(
          id: uuid(),
          conversationID: conversationID,
          submission: submission,
          suggestionGeneration: generation,
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
          acceptDraft,
          cancelPreparation,
          retireBatch,
          dispatchNextIfIdle(state: &state))

      case .chat(.delegate(.retryInterruptedTurn)):
        refreshFMAvailability(state: &state)
        return claimInterruptedRetry(state: &state, automatic: false)

      case .chat(.delegate(.retryInterruptedTurnFor(let journalID))):
        refreshFMAvailability(state: &state)
        return claimInterruptedRetry(
          state: &state, automatic: false, journalID: journalID)

      case .chat(.delegate(.dismissInterruptedTurn(let journalID))):
        guard let conversationID = state.chat?.conversationID else { return .none }
        state.dismissedRetryJournalIDs.insert(journalID)
        state.failedDismissalManualRetryIDs.remove(journalID)
        state.automaticRetryCandidates.removeValue(forKey: journalID)
        state.userPromotedRetryJournalIDs.remove(journalID)
        state.cancelledRetryJournalIDs.remove(journalID)
        state.queue.removeAll {
          $0.conversationID == conversationID && $0.retryJournalID == journalID
        }
        syncSchedulerProjection(into: &state)
        return .run { send in
          do {
            try await history.endTurnJournal(conversationID, journalID)
            await send(.interruptedDismissalFinished(
              conversationID: conversationID, journalID: journalID,
              failure: nil))
          } catch {
            try? await history.declineAutoRetry(conversationID, journalID)
            await send(.interruptedDismissalFinished(
              conversationID: conversationID, journalID: journalID,
              failure: .history(operation: .messageSave, error: error)))
          }
        }

      case .chat(.delegate(.stopActiveTurn)):
        return stopActiveTurn(state: &state)

      case .chat(.delegate(.cancelQueued(let id))):
        let cancelled = state.queue.first { $0.id == id }
        state.queue.removeAll { $0.id == id }
        if let journalID = cancelled?.retryJournalID,
          let conversationID = cancelled?.conversationID
        {
          return cancelQueuedRetry(
            state: &state, conversationID: conversationID, journalID: journalID)
        }
        syncSchedulerProjection(into: &state)
        diagnostics.info(
          category: .submission,
          code: "queued_question_cancelled",
          summary: "A queued question was cancelled before dispatch.")
        return .none

      case .chat(.delegate(.cancelQueuedRetry(let journalID))):
        guard let conversationID = state.chat?.conversationID else { return .none }
        return cancelQueuedRetry(
          state: &state, conversationID: conversationID, journalID: journalID)

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

      case .chat(.resultPresentationMigrated(let migration)):
        guard
          state.activeTurn?.conversationID == state.chat?.conversationID,
          state.activeTurn?.provisionalAssistantMessageID == migration.messageID,
          state.activeTurn?.resultPresentationPreference == migration.previous
        else { return .none }
        state.activeTurn?.resultPresentationPreference = migration.updated
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
          guard state.canStartLowPriorityInference,
            state.fmAvailability == .available,
            !state.modelPreparationInFlight
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
