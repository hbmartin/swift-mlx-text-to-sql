import AutoTableCharts
import CREGCore
import CREGEngine
import ComposableArchitecture
import SwiftUI
import Synchronization

#if DEBUG
  /// DEBUG-only entry into deterministic, inert screens for accessibility UI
  /// audits. Release and Beta builds do not compile this path.
  struct AccessibilityUITestConfiguration: Equatable, Sendable {
    enum Scenario: String, CaseIterable, Sendable {
      case emptyChat = "empty-chat"
      case answeredChat = "answered-chat"
      case answeredChatHelpful = "answered-chat-helpful"
      case answeredChatReading = "answered-chat-reading"
      case longTranscriptSharing = "long-transcript-sharing"
      case conversationLoadFailure = "conversation-load-failure"
      case historyStoreUnavailable = "history-store-unavailable"
      case retryInspection = "retry-inspection"
      case supportBundleFallback = "support-bundle-fallback"
      case supportBundleDismissal = "support-bundle-dismissal"
      case processingQueue = "processing-queue"
      case error
      case recovery
      case browser
      case settings
      case resultExplorer = "result-explorer"
      case resultPreviewIdentity = "result-preview-identity"
      case resultChartPreparation = "result-chart-preparation"
      case resultChartRecovery = "result-chart-recovery"
      case resultChartRejectedRetry = "result-chart-rejected-retry"
      case resultChartTerminalRecovery = "result-chart-terminal-recovery"
      case resultChartUnresolvedSelection = "result-chart-unresolved-selection"
      case transientBanners = "transient-banners"
      case conversationNotices = "conversation-notices"
      case noticeOccurrences = "notice-occurrences"
      case retainedExport = "retained-export"
      case browserRefresh = "browser-refresh"
      case browserPerformance = "browser-performance"
      case appleIntelligenceDisabled = "apple-intelligence-disabled"
      case exportMore = "export-more"
      case browserLongPreviews = "browser-long-previews"
      case compactJump = "compact-jump"
      case historyProgress = "history-progress"
      case historyProgressUnavailable = "history-progress-unavailable"
      case drawerGestureCancellation = "drawer-gesture-cancellation"
    }

    enum Request: Equatable, Sendable {
      case scenario(AccessibilityUITestConfiguration)
      case scenarioManifest
      case invalidConfiguration
    }

    static let scenarioEnvironmentKey = "CREG_UI_TEST_SCENARIO"
    static let dynamicTypeEnvironmentKey = "CREG_UI_TEST_DYNAMIC_TYPE"
    static let developerModeEnvironmentKey = "CREG_UI_TEST_DEVELOPER_MODE"
    static let scenarioManifestEnvironmentKey =
      "CREG_UI_TEST_SCENARIO_MANIFEST"
    private static let environmentKeyPrefix = "CREG_UI_TEST_"

    static var scenarioManifest: String {
      Scenario.allCases.map(\.rawValue).joined(separator: "|")
    }

    var scenario: Scenario
    var dynamicTypeSize: DynamicTypeSize?
    var developerMode = false

    static var currentRequest: Request? {
      request(environment: ProcessInfo.processInfo.environment)
    }

    static func request(environment: [String: String]) -> Request? {
      let knownKeys: Set<String> = [
        scenarioEnvironmentKey,
        dynamicTypeEnvironmentKey,
        developerModeEnvironmentKey,
        scenarioManifestEnvironmentKey,
      ]
      let hasUnknownConfiguration = environment.contains { key, value in
        key.hasPrefix(environmentKeyPrefix)
          && !knownKeys.contains(key)
          && !isDisabledEnvironmentValue(value)
      }
      guard !hasUnknownConfiguration else { return .invalidConfiguration }

      let rawManifest = environment[scenarioManifestEnvironmentKey] ?? ""
      guard rawManifest.isEmpty || rawManifest == "0" || rawManifest == "1"
      else { return .invalidConfiguration }
      let manifestRequested = rawManifest == "1"
      let rawDeveloperMode = environment[developerModeEnvironmentKey] ?? ""
      guard rawDeveloperMode.isEmpty || rawDeveloperMode == "0" || rawDeveloperMode == "1"
      else { return .invalidConfiguration }

      let rawScenario = environment[scenarioEnvironmentKey] ?? ""
      let rawSize = environment[dynamicTypeEnvironmentKey] ?? ""
      guard !rawScenario.isEmpty else {
        guard rawSize.isEmpty, rawDeveloperMode != "1" else {
          return .invalidConfiguration
        }
        return manifestRequested ? .scenarioManifest : nil
      }
      guard let scenario = Scenario(rawValue: rawScenario)
      else { return .invalidConfiguration }

      let dynamicTypeSize: DynamicTypeSize?
      if !rawSize.isEmpty {
        guard let parsed = DynamicTypeSize.uiTestValue(rawSize) else {
          return .invalidConfiguration
        }
        dynamicTypeSize = parsed
      } else {
        dynamicTypeSize = nil
      }
      return .scenario(
        Self(
          scenario: scenario,
          dynamicTypeSize: dynamicTypeSize, developerMode: rawDeveloperMode == "1"))
    }

    private static func isDisabledEnvironmentValue(_ value: String) -> Bool {
      value.isEmpty || value == "0"
    }
  }

  @MainActor
  private struct LongTranscriptSharingAccessibilityHarness: View {
    @State private var didComplete = false
    @State private var store = StoreOf<ChatFeature>(initialState: Self.initialState()) {
      BindingReducer()
    }

    private static func initialState() -> ChatFeature.State {
      var state = PreviewFixtures.answeredChatState()
      var originalAnswer = state.messages.removeLast()
      originalAnswer.id = UUID(uuidString: "00000000-0000-0000-0000-000000006099")!
      state.messages.append(originalAnswer)
      for index in 0..<24 {
        state.messages.append(
          ChatMessage(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 6000 + index))!,
            role: .user, body: .text("Later transcript question \(index + 1)."),
            createdAt: PreviewFixtures.now.addingTimeInterval(Double(index))))
      }
      return state
    }

    var body: some View {
      ChatView(
        store: store, chrome: PreviewFixtures.chrome,
        answerSharePresented: {
          guard !didComplete else { return }
          didComplete = true
          let fixture = PreviewFixtures.answeredChatState().messages.last!
          var completion = fixture
          completion.id = UUID(uuidString: "00000000-0000-0000-0000-000000006100")!
          if case .answer(let result, _, let sql, let notice) = completion.body {
            completion.body = .answer(
              result: result, narration: "Concurrent answer completed", sql: sql, notice: notice)
          }
          store.messages.append(completion)
        })
    }
  }

  @MainActor
  private struct ConversationLoadFailureAccessibilityHarness: View {
    let scenario: AccessibilityUITestConfiguration.Scenario
    @State private var store: StoreOf<AppFeature>
    private static let journalID = UUID(uuidString: "00000000-0000-4000-8000-000000006201")!

    init(scenario: AccessibilityUITestConfiguration.Scenario = .conversationLoadFailure) {
      self.scenario = scenario
      let initial = Self.initialState(scenario: scenario)
      let summary = ConversationSummary(id: PreviewFixtures.chatState().conversationID,
        title: "Saved conversation", startedAt: PreviewFixtures.now, lastActivityAt: PreviewFixtures.now)
      var history = HistoryClient.noop()
      history.bootstrap = { [summary] }
      switch scenario {
      case .historyStoreUnavailable:
        let attempts = Mutex(0)
        let healthy = history
        history = .recoverable(open: {
          let attempt = attempts.withLock { $0 += 1; return $0 }
          if attempt == 1 { throw PreviewHistoryError() }
          return healthy
        })
      case .retryInspection:
        history.claimTurnRetry = { _, _, _, _ in nil }
        history.loadConversation = { _ in
          // Cancellation settles this held read; a frozen clock keeps the
          // inspection timeout deterministic while the UI exercises Dismiss.
          try await Task.sleep(for: .seconds(30))
          return ConversationSnapshot(summary: summary)
        }
      default:
        history.loadConversation = { _ in throw PreviewHistoryError() }
      }
      let controlledHistory = history
      _store = State(initialValue: Store(initialState: initial) { AppFeature() } withDependencies: {
        $0.historyClient = controlledHistory
        $0.fmStatus = FMStatusClient(availability: { .available })
        $0.haptics = .noop
        $0.diagnostics = .noop
        $0.continuousClock = TestClock()
      })
    }

    private static func initialState(scenario: AccessibilityUITestConfiguration.Scenario) -> AppFeature.State {
      var state = AppFeature.State(debugModelIdentity: nil, launchBenchmarkQuestion: nil)
      state.modelReadiness = .ready
      state.didRequestPreparationJournalInspection = true
      state.didHandlePreparationJournalInspection = true
      if scenario == .retryInspection {
        var chat = PreviewFixtures.chatState()
        let message = ChatMessage(id: UUID(uuidString: "00000000-0000-4000-8000-000000006202")!,
          role: .user, body: .text("What is my portfolio worth?"), createdAt: PreviewFixtures.now)
        chat.messages.append(message)
        chat.interruptedTurns.append(InterruptedTurn(question: message.previewText,
          interruptedAt: message.createdAt, journalID: journalID, executionID: message.id,
          status: .knownInterruption))
        state.chat = chat
        state.conversations.append(ConversationSummary(id: chat.conversationID,
          title: chat.title, startedAt: PreviewFixtures.now, lastActivityAt: PreviewFixtures.now))
        state.historySummaryPhase = .loaded
      }
      return state
    }

    var body: some View {
      AppRootView(store: store, now: PreviewFixtures.now)
        .task {
          if scenario == .retryInspection {
            store.send(.chat(.delegate(.retryInterruptedTurnFor(Self.journalID))))
          }
        }
    }

    private struct PreviewHistoryError: Error {}
  }

  private final class SupportArtifactLedger: Sendable {
    let directories = Mutex<[URL]>([])
  }

  private struct SupportBundleAccessibilityHarness: View {
    @State private var store: StoreOf<AppFeature>
    @State private var artifactCount = 0
    @State private var retainedCount = 0
    private let ledger: SupportArtifactLedger
    let autoBuild: Bool

    init(autoBuild: Bool) {
      self.autoBuild = autoBuild
      let ledger = SupportArtifactLedger()
      self.ledger = ledger
      var state = PreviewFixtures.appState(revealed: false, chat: PreviewFixtures.answeredChatState())
      state.historySummaryPhase = .loaded
      state.historyStoreAvailability = .available
      state.launchBenchmarkQuestion = nil
      state.didRequestPreparationJournalInspection = true
      state.didHandlePreparationJournalInspection = true
      _store = State(initialValue: Store(initialState: state) { AppFeature() } withDependencies: {
        $0.historyClient = .noop()
        $0.diagnostics = .noop
        $0.haptics = .noop
        $0.fmStatus = .init(availability: { .available })
        $0.supportBundle = .init { _ in
          let directory = FileManager.default.temporaryDirectory.appendingPathComponent("creg-support-bundle-\(UUID())")
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          ledger.directories.withLock { $0.append(directory) }
          let url = directory.appendingPathComponent("creg-support-bundle.zip")
          try Data("Support ZIP fixture".utf8).write(to: url)
          return .init(url: url, manifest: .init(createdAt: PreviewFixtures.now,
            appVersion: "test", buildNumber: "1", modelKey: "test", modelRevision: "test",
            conversationCount: 2, messageCount: 4, eventLineCount: 4, feedbackCount: 0))
        }
      })
    }
    var body: some View {
      VStack(spacing: 0) {
        if !autoBuild {
          Text("\(artifactCount):\(retainedCount)").font(.caption)
            .accessibilityIdentifier("support-artifact-count")
        }
        // Exercise Settings' production binding, not a substitute sheet.
        SettingsView(store: store)
      }
      .task {
        // Wait until Settings is mounted before requesting its nested sheet.
        if autoBuild {
          try? await Task.sleep(for: .milliseconds(300))
          store.send(.supportBundleExportTapped)
        }
        while !Task.isCancelled {
          let directories = ledger.directories.withLock { $0 }
          artifactCount = directories.count
          retainedCount = directories.filter { FileManager.default.fileExists(atPath: $0.path) }.count
          try? await Task.sleep(for: .milliseconds(100))
        }
      }
    }
  }

  @MainActor
  struct AccessibilityScenarioView: View {
    let scenario: AccessibilityUITestConfiguration.Scenario
    var developerMode = false
    @State private var resultExplorerPreference = ResultPresentationPreference.automatic

    @ViewBuilder
    var body: some View {
      switch scenario {
      case .emptyChat:
        ChatView(
          store: PreviewFixtures.chatStore(PreviewFixtures.chatState()),
          chrome: PreviewFixtures.chrome)

      case .answeredChat:
        ChatView(
          store: PreviewFixtures.chatStore(PreviewFixtures.answeredChatState()),
          chrome: PreviewFixtures.chrome)

      case .answeredChatHelpful:
        ChatView(
          store: PreviewFixtures.chatStore(PreviewFixtures.helpfulChatState()),
          chrome: PreviewFixtures.chrome)

      case .answeredChatReading:
        ChatView(
          store: PreviewFixtures.chatStore(readingChatState),
          chrome: PreviewFixtures.chrome)

      case .longTranscriptSharing:
        LongTranscriptSharingAccessibilityHarness()

      case .conversationLoadFailure:
        ConversationLoadFailureAccessibilityHarness()

      case .historyStoreUnavailable, .retryInspection:
        ConversationLoadFailureAccessibilityHarness(scenario: scenario)

      case .supportBundleFallback:
        SupportBundleAccessibilityHarness(autoBuild: true)
      case .supportBundleDismissal:
        SupportBundleAccessibilityHarness(autoBuild: false)

      case .resultExplorer:
        // This scenario has no transcript store, matching the preview harness.
        ResultViewerView(
          result: PreviewFixtures.fundValueResult,
          runtimeMode: .evaluated,
          textSize: .constant(.standard),
          sql: StarterQueryID.portfolioValueByFundV1.sql,
          question: StarterQueryID.portfolioValueByFundV1.question,
          preference: $resultExplorerPreference)
          .cregPresentedSurfaceProbe()

      case .resultPreviewIdentity:
        ResultPreviewIdentityAccessibilityHarness()

      case .resultChartRecovery:
        ResultChartTypeAccessibilityHarness(failureRetryability: true)

      case .resultChartRejectedRetry:
        ResultChartTypeAccessibilityHarness(
          failureRetryability: true,
          retryStarts: false)

      case .resultChartTerminalRecovery:
        ResultChartTypeAccessibilityHarness(failureRetryability: false)

      case .resultChartUnresolvedSelection:
        ResultChartTypeAccessibilityHarness(
          failureRetryability: nil,
          startsSelected: false)

      case .resultChartPreparation:
        ResultChartPreparationAccessibilityHarness()

      case .processingQueue:
        ChatView(
          store: PreviewFixtures.chatStore(PreviewFixtures.processingChatState()),
          chrome: PreviewFixtures.chrome)

      case .error:
        NoticesAccessibilityHarness(scenario: .error, developerMode: developerMode)

      case .recovery:
        NoticesAccessibilityHarness(scenario: .recovery, developerMode: developerMode)

      case .browser:
        AppRootView(
          store: PreviewFixtures.appStore(
            PreviewFixtures.appState(
              revealed: true,
              chat: PreviewFixtures.answeredChatState())),
          now: PreviewFixtures.now)

      case .settings:
        SettingsView(
          store: PreviewFixtures.appStore(PreviewFixtures.settingsState()))

      case .noticeOccurrences:
        NoticeOccurrenceAccessibilityHarness()
      case .conversationNotices, .retainedExport, .browserRefresh, .browserPerformance, .appleIntelligenceDisabled,
        .exportMore, .browserLongPreviews, .compactJump, .historyProgress, .historyProgressUnavailable,
        .drawerGestureCancellation:
        NoticesAccessibilityHarness(scenario: scenario, developerMode: developerMode)

      case .transientBanners:
        AppRootView(
          store: PreviewFixtures.appStore(
            PreviewFixtures.appState(
              revealed: false,
              chat: PreviewFixtures.answeredChatState())),
          now: PreviewFixtures.now)
      }
    }

    private var readingChatState: ChatFeature.State {
      var state = PreviewFixtures.helpfulChatState()
      state.readAloud = .init(messageID: PreviewFixtures.id("2"), phase: .playing)
      return state
    }


  }

  @MainActor
  struct NoticesAccessibilityHarness: View {
    @State private var store: StoreOf<AppFeature>
    @State private var heldExport: HeldUITestExport
    private let scenario: AccessibilityUITestConfiguration.Scenario
    @State private var drawerReduceMotion = false
    @State private var drawerMotionProbe: DrawerMotionProbe?
    @State private var drawerRowProbe: DrawerRowProbe?
    private let selectedID: UUID
    private let otherID: UUID
    init(scenario: AccessibilityUITestConfiguration.Scenario = .conversationNotices,
      developerMode: Bool = false) {
      self.scenario = scenario
      let held = HeldUITestExport()
      _heldExport = State(initialValue: held)
      var chat = scenario == .recovery || scenario == .compactJump
        ? PreviewFixtures.recoveryChatState() : PreviewFixtures.answeredChatState()
      if scenario == .exportMore { chat.title = "Export" }
      if scenario == .compactJump {
        for index in 0..<24 {
          chat.messages.append(.init(id: UUID(), role: .user,
            body: .text("Later transcript question \(index + 1)."), createdAt: PreviewFixtures.now))
        }
      }
      var initial = PreviewFixtures.appState(revealed: scenario == .browserRefresh || scenario == .browserPerformance || scenario == .browserLongPreviews,
        chat: chat)
      // Keep disclosure coverage independent of persisted app preferences.
      initial.$developerMode = Shared(value: developerMode)
      initial.historyStoreAvailability = .available
      initial.historySummaryPhase = .loaded
      initial.launchBenchmarkQuestion = nil
      initial.didRequestPreparationJournalInspection = true
      initial.didHandlePreparationJournalInspection = true
      let id = initial.chat!.conversationID
      selectedID = id
      otherID = initial.conversations.first(where: { $0.id != id })!.id
      _drawerMotionProbe = State(initialValue: scenario == .drawerGestureCancellation ? DrawerMotionProbe() : nil)
      _drawerRowProbe = State(initialValue: scenario == .browserPerformance ? DrawerRowProbe() : nil)
      if scenario == .browserPerformance {
        initial.conversations = IdentifiedArray(uniqueElements: (0..<1000).map { index in
          ConversationSummary(id: UUID(), title: "Saved conversation \(index)", startedAt: PreviewFixtures.now,
            lastActivityAt: PreviewFixtures.now, latestMessagePreview: "Saved question")
        })
      }
      if scenario == .browserLongPreviews {
        for id in initial.conversations.ids {
          initial.conversations[id: id]?.latestMessagePreview =
            String(repeating: "A long answer paragraph with portfolio details. \n\n", count: 30) + "DRAWER_FULL_PREVIEW_TAIL"
        }
      }
      if scenario == .error || scenario == .conversationNotices {
        for index in 0..<(scenario == .error ? 1 : 6) {
          var failure = PreviewFixtures.presentationFailure
          failure.code = "notice_fixture_\(index)"
          failure.diagnostic = "notice-details-\(index)"
          initial.storeFailure(failure, owner: .historySummaries(UInt64(index)))
        }
      }
      if scenario == .historyProgress || scenario == .historyProgressUnavailable {
        initial.historySummaryPhase = .loading(42)
        initial.slowHistoryRequestID = 42
        initial.storeFailure(.init(code: "history_summary_timed_out",
          title: "History is taking longer than expected", message: "CREG is still loading your conversations.",
          diagnostic: "Slow history fixture", recovery: .retryHistory, severity: .informational), owner: .historySummaries(42))
        if scenario == .historyProgressUnavailable { initial.chat = nil }
      }
      if scenario == .conversationNotices {
        initial.chat?.interruptedTurns = PreviewFixtures.recoveryChatState().interruptedTurns
        initial.chat?.correctionContext = PreviewFixtures.recoveryChatState().correctionContext
      }
      if scenario == .conversationNotices {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("creg-conversation-preview-\(UUID()).jsonl")
        try? Data("{}\n".utf8).write(to: url)
        initial.conversationExports[id] = .init(conversationID: id, requestID: PreviewFixtures.id("9"), phase: .ready(url), intent: .retained)
      }
      if scenario == .browserRefresh {
        initial.historySummaryPhase = .failed(1)
        initial.storeFailure(.history(operation: .summaryLoad, error: NSError(domain: "Preview.History", code: 1)),
          owner: .historySummaries(1))
      }
      let summaries = Array(initial.conversations)
      var history = HistoryClient.noop()
      history.bootstrap = { try await Task.sleep(for: .milliseconds(300)); return summaries }
      history.loadConversation = { id in ConversationSnapshot(summary: summaries.first(where: { $0.id == id })!) }
      history.exportJSONL = { id in try await held.export(id) }
      let controlledHistory = history
      _store = State(initialValue: Store(initialState: initial) { AppFeature() } withDependencies: {
        $0.historyClient = controlledHistory
        $0.fmStatus = FMStatusClient(availability: { scenario == .appleIntelligenceDisabled ? .unavailable(reason: .appleIntelligenceNotEnabled) : .available })
        $0.haptics = .noop
        $0.diagnostics = .noop
        $0.continuousClock = ContinuousClock()
      })
    }
    var body: some View {
      VStack(spacing: 0) {
        if scenario == .drawerGestureCancellation {
          HStack {
            Button("Reset motion capture") { drawerMotionProbe?.reset() }
              .accessibilityIdentifier("reset-drawer-motion").frame(minHeight: 44)
            Button("Reduce Motion") { drawerReduceMotion.toggle() }
              .accessibilityIdentifier("toggle-drawer-motion").frame(minHeight: 44)
          }
          Button("Interrupt drawer drag") {
            Task { @MainActor in
              try? await Task.sleep(for: .milliseconds(1500))
              store.send(.binding(.set(\.isSettingsPresented, true)))
            }
          }.frame(minHeight: 44).accessibilityIdentifier("interrupt-drawer-drag")
        }
        if scenario == .retainedExport {
          HStack {
            Button("Finish") { Task { await heldExport.finish() } }
              .accessibilityLabel("Complete held export")
              .accessibilityIdentifier("held-export-complete").frame(minHeight: 44)
            Button("Return") { store.send(.conversationSelected(selectedID)) }
              .accessibilityLabel("Return to source chat")
              .accessibilityIdentifier("held-export-return").frame(minHeight: 44)
          }
        }
        if scenario == .browserPerformance { DrawerPerformanceProbe(store: store) }
        if scenario == .exportMore {
          HStack(spacing: 0) {
            Color.clear.accessibilityElement()
              .accessibilityLabel(store.conversationExports[selectedID]?.phase == .exporting ? "exporting" : "ready")
              .accessibilityIdentifier("more-export-state")
            Color.clear.accessibilityElement()
              .accessibilityLabel("\(store.presentedExportFiles.count)")
              .accessibilityIdentifier("more-export-leases")
          }.frame(width: 2, height: 1)
        }
        AppRootView(store: store, now: PreviewFixtures.now)
      }
      .environment(\.cregDrawerMotionProbe, drawerMotionProbe)
      .environment(\.cregDrawerRowProbe, drawerRowProbe)
      .environment(\.cregUITestReduceMotion, scenario == .recovery || scenario == .compactJump ? true : scenario == .drawerGestureCancellation ? drawerReduceMotion : nil)
      .task {
        if scenario == .retainedExport || scenario == .exportMore {
          store.send(.chat(.delegate(.exportRequested(selectedID))))
          if scenario == .retainedExport { store.send(.conversationSelected(otherID)) }
        }
      }
      .task(id: store.answerMorePresentation?.presentationID) {
        if scenario == .exportMore, store.answerMorePresentation != nil {
          try? await Task.sleep(for: .milliseconds(500))
          if !Task.isCancelled { await heldExport.finish() }
        }
      }
    }
  }

  @MainActor
  private struct NoticeOccurrenceAccessibilityHarness: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var store: StoreOf<AppFeature>
    @State private var settings = false
    private static let failure = FailurePresentation(code: "same_code", title: "Save failed",
      message: "An unrelated save needs attention.", diagnostic: "occurrence-original")

    init() {
      var initial = PreviewFixtures.appState(revealed: false, chat: PreviewFixtures.answeredChatState())
      initial.$developerMode = Shared(value: true)
      let id = initial.chat!.conversationID
      if initial.conversations[id: id] == nil {
        initial.conversations.append(.init(id: id, title: "Recovery", startedAt: PreviewFixtures.now, lastActivityAt: PreviewFixtures.now))
      }
      let draftFailure = FailurePresentation.history(operation: .draftSave, error: NSError(domain: "Fixture", code: 1))
      var answer = initial.chat!.messages.last!
      answer.resultPresentation = .table
      let preferenceFailure = FailurePresentation.resultPreferenceSave(error: NSError(domain: "Fixture", code: 2))
      initial.storeFailure(Self.failure, owner: .global)
      var second = Self.failure; second.diagnostic = "occurrence-survivor"
      initial.storeFailure(second, owner: .historySummaries(2))
      initial.storeFailure(draftFailure, owner: .conversationOperation(id, .draft))
      initial.storeFailure(preferenceFailure, owner: .conversationOperation(id, .resultPresentation))
      initial.conversationWriteSequence = 2
      initial.conversationEdits[id] = [
        .resultPresentation(answer.id): .init(revision: 2,
          status: .pending(.resultPresentation(answer), .failed(preferenceFailure))),
        .draft: .init(revision: 1, status: .pending(.draft("Retained fixture draft"), .failed(draftFailure))),
      ]
      initial.overlayConversationEdits()
      _store = State(initialValue: Store(initialState: initial) { AppFeature() } withDependencies: {
        $0.historyClient = .noop()
        $0.haptics = .noop
      })
    }

    var body: some View {
      VStack {
        HStack {
          Button("Duplicate") { store.send(.operationFailed(Self.failure)) }
            .accessibilityIdentifier("notice-duplicate").frame(minHeight: 44)
          Button("Replace") {
            var failure = Self.failure; failure.diagnostic = "occurrence-replacement"
            store.send(.operationFailed(failure))
          }.accessibilityIdentifier("notice-replace").frame(minHeight: 44)
          Button("Settings") { settings = true }.frame(minHeight: 44)
        }.accessibilityHidden(settings)
        ScrollView {
          if let chat = store.scope(state: \.chat, action: \.chat) {
            ChatNoticesContent(store: chat, chrome: chrome).padding(16)
          }
        }.accessibilityIdentifier("conversation-notices-scroll")
          .accessibilityHidden(settings)
      }
      .sheet(isPresented: $settings) {
        SettingsView(store: store).cregPresentedSurfaceProbe().environment(\.dynamicTypeSize, dynamicTypeSize)
      }
    }

    private var chrome: ChatChrome {
      var value = PreviewFixtures.chrome
      value.modelReadiness = .ready
      value.fmAvailability = .available
      value.developerMode = true
      value.ownedFailures = store.visibleFailures
      value.dismissOwnedFailure = { store.send(.dismissOwnedFailure($0)) }
      value.retryableWriteOwners = store.retryableConversationWriteOwners
      value.retrySaving = { store.send(.retryConversationWrites($0)) }
      return value
    }
  }

  @MainActor
  private struct ResultPreviewIdentityAccessibilityHarness: View {
    @State private var showsReplacement = false
    @State private var preference = ResultPresentationPreference.automatic

    private let replacement = QueryResult(
      columns: ["note"],
      rows: [
        [.text("First replacement")],
        [.text("Second replacement")],
        [.text("Third replacement")],
      ])

    var body: some View {
      VStack(spacing: 12) {
        Button("Replace result") { showsReplacement = true }
          .accessibilityIdentifier("replace-preview-result")
        ResultPreviewView(
          messageID: PreviewFixtures.id("9"),
          resultFingerprint: showsReplacement
            ? "preview-replacement" : "preview-original",
          result: showsReplacement
            ? replacement : PreviewFixtures.fundValueResult,
          sql: showsReplacement
            ? "SELECT note FROM properties"
            : StarterQueryID.portfolioValueByFundV1.sql,
          question: showsReplacement
            ? "Show notes" : StarterQueryID.portfolioValueByFundV1.question,
          preference: preference,
          setPreference: { preference = $0 },
          migratePreference: { _, updated in
            preference = updated
            return .migrated(updated)
          },
          open: {})
        Spacer(minLength: 0)
      }
      .padding()
    }
  }

  @MainActor
  private struct ResultChartPreparationAccessibilityHarness: View {
    var body: some View {
      ResultChartExplorerContainer(
        recommendation: PreviewFixtures.ChartPreparation.recommendation
      ) {
        ResultChartExplorerPreparationView(
          recommendation: PreviewFixtures.ChartPreparation.recommendation)
      }
    }
  }

  @MainActor
  private struct ResultChartTypeAccessibilityHarness: View {
    private static let chartTypeRecommendations = [
      AutoChartRecommendation(
        specification: .bar(category: "fund", measure: "value"),
        score: 1,
        rationale: []),
      AutoChartRecommendation(
        specification: .rankedDot(category: "fund", measure: "value"),
        score: 0.9,
        rationale: []),
    ]
    private static let chartTypeCatalog = AutoChartRecommendationCatalog(
      featured: chartTypeRecommendations,
      cataloged: chartTypeRecommendations)
    private static let chartTypeOptions = resultChartPickerOptions(
      catalog: chartTypeCatalog,
      selectedRecommendation: chartTypeRecommendations.first)

    let failureRetryability: Bool?
    let retryStarts: Bool
    @State private var actionFeedback = "No recovery action"
    @State private var keepTableSelectionCount = 0
    @State private var selectedChartTypeID: AutoChartRecommendationID?
    @State private var preference: ResultPresentationPreference

    init(
      failureRetryability: Bool?,
      startsSelected: Bool = true,
      retryStarts: Bool = true
    ) {
      self.failureRetryability = failureRetryability
      self.retryStarts = retryStarts
      let selectedID = startsSelected ? Self.chartTypeOptions.first?.id : nil
      _selectedChartTypeID = State(
        initialValue: selectedID)
      _preference = State(
        initialValue: selectedID.map {
          ResultPresentationPreference.chart(.specific($0))
        } ?? .automatic)
    }

    private var retryAvailable: Bool {
      failureRetryability == true
    }

    private var showsChartTypeMenu: Bool {
      ResultViewerLogic.shouldShowChartTypeMenu(
        optionCount: Self.chartTypeOptions.count,
        requestedMode: .chart,
        hasFailure: failureRetryability != nil)
    }

    private func selectChartType(_ id: AutoChartRecommendationID) {
      let label = Self.chartTypeOptions.first(where: { $0.id == id })?.label
        ?? "Chart type"
      let intent = ResultViewerLogic.chartTypeSelectionIntent(
        id,
        currentlySelectedID: selectedChartTypeID,
        currentPreference: preference,
        failureRetryability: failureRetryability)
      switch intent {
      case .none:
        return
      case .persist(let updated):
        preference = updated
        selectedChartTypeID = id
        actionFeedback = "\(label) selected"
      case .retryChart(let updated):
        guard retryStarts else {
          actionFeedback = "Chart retry unavailable"
          return
        }
        if let updated { preference = updated }
        selectedChartTypeID = id
        actionFeedback = updated == nil
          ? "\(label) selected again" : "\(label) selected"
      }
    }

    var body: some View {
      VStack(spacing: 8) {
        if failureRetryability != nil {
          ResultChartRecoveryControls(
            spacing: 12,
            keepTable: {
              keepTableSelectionCount += 1
              actionFeedback =
                keepTableSelectionCount == 1
                ? "Keep Table selected" : "Keep Table selected again"
            },
            retryChart:
              retryAvailable
              ? { actionFeedback = "Retry Chart selected" } : nil
          )
          .padding(.horizontal)
          .accessibilityIdentifier("result-chart-recovery")
        }
        if showsChartTypeMenu {
          Menu {
            resultChartTypeMenuContent(
              selectedID: selectedChartTypeID,
              options: Self.chartTypeOptions,
              allowsReselection: retryAvailable,
              select: selectChartType)
          } label: {
            Label("Chart type", systemImage: "chart.xyaxis.line")
          }
          .accessibilityIdentifier("result-chart-type-retry")
        }
        Text(actionFeedback)
          .font(.caption2)
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @MainActor
  struct AccessibilityUITestRootView: View {
    let configuration: AccessibilityUITestConfiguration

    var body: some View {
      ZStack(alignment: .topLeading) {
        AccessibilityScenarioView(scenario: configuration.scenario,
          developerMode: configuration.developerMode)
        Color.clear
          .frame(width: 1, height: 1)
          .accessibilityElement()
          .accessibilityLabel("UI test scenario")
          .accessibilityIdentifier("ui-test-\(configuration.scenario.rawValue)")
          .allowsHitTesting(false)
      }
      .cregDynamicTypeSize(configuration.dynamicTypeSize)
    }
  }

  @MainActor
  struct AccessibilityUITestScenarioManifestView: View {
    var body: some View {
      Text(AccessibilityUITestConfiguration.scenarioManifest)
        .accessibilityIdentifier("ui-test-scenario-manifest")
    }
  }

  @MainActor
  struct AccessibilityUITestInvalidConfigurationView: View {
    var body: some View {
      Text("Invalid accessibility UI test configuration")
        .accessibilityIdentifier("ui-test-invalid-configuration")
    }
  }

  extension DynamicTypeSize {
    fileprivate static func uiTestValue(_ value: String) -> Self? {
      switch value.lowercased() {
      case "large": .large
      case "xxlarge": .xxLarge
      case "xxxlarge": .xxxLarge
      case "ax1", "accessibility1": .accessibility1
      case "ax3", "accessibility3": .accessibility3
      case "ax4", "accessibility4": .accessibility4
      case "ax5", "accessibility5": .accessibility5
      default: nil
      }
    }
  }

  extension View {
    @ViewBuilder
    fileprivate func cregDynamicTypeSize(_ size: DynamicTypeSize?) -> some View {
      if let size {
        self.environment(\.dynamicTypeSize, size)
      } else {
        self
      }
    }
  }
#endif
