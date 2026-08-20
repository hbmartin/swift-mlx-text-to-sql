import ComposableArchitecture
import Foundation
import Testing

@testable import CREGEngine
@testable import CREGFeatures

@MainActor
@Suite struct FeatureFailureDiagnosticsTests {
  private static func appState() -> AppFeature.State {
    var state = AppFeature.State(
      debugModelIdentity: nil, launchBenchmarkQuestion: nil)
    state.launchBenchmarkQuestion = nil
    state.modelReadiness = .ready
    state.chat = ChatFeature.State(conversationID: UUID(9))
    state.conversations = [
      ConversationSummary(
        id: UUID(9), title: "",
        startedAt: Date(timeIntervalSince1970: 0),
        lastActivityAt: Date(timeIntervalSince1970: 0))
    ]
    return state
  }

  @Test func historyBootstrapFailureIsLoggedAndPresented() async {
    let recorder = DiagnosticEventRecorder()
    var initialState = AppFeature.State(
      debugModelIdentity: nil, launchBenchmarkQuestion: nil)
    initialState.launchBenchmarkQuestion = nil
    var history = HistoryClient.noop()
    history.bootstrap = {
      throw DiagnosticsTestError.failed("database could not be opened")
    }
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: { [history] in
      $0.historyClient = history
      $0.diagnostics = recorder.client
    }
    store.exhaustivity = .off

    await store.send(.onAppear)
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.presentedFailure?.code == "history_load_failed")
    #expect(store.state.presentedFailure?.title == "History unavailable")
    #expect(
      store.state.presentedFailure?.technicalDetails(developerMode: false) == nil)
    #expect(recorder.events.map(\.code).contains("history_load_failed"))
    #expect(recorder.events.map(\.code).contains("app_appeared"))
  }

  @Test func exportFailureIsLoggedAndPresented() async {
    let recorder = DiagnosticEventRecorder()
    var history = HistoryClient.noop()
    history.exportJSONL = { _ in
      throw DiagnosticsTestError.failed("temporary directory is unavailable")
    }
    let store = TestStore(initialState: Self.appState()) {
      AppFeature()
    } withDependencies: { [history] in
      $0.historyClient = history
      $0.diagnostics = recorder.client
    }
    store.exhaustivity = .off

    await store.send(.chat(.exportTapped))
    await store.finish()
    await store.skipReceivedActions()

    #expect(store.state.presentedFailure?.code == "history_export_failed")
    #expect(store.state.presentedFailure?.title == "Export failed")
    #expect(recorder.events.map(\.code).contains("history_export_started"))
    #expect(recorder.events.map(\.code).contains("history_export_failed"))
  }

  @Test func messageSaveFailureIsLoggedAndPresented() async {
    let recorder = DiagnosticEventRecorder()
    var history = HistoryClient.noop()
    history.persistUserTurn = { _, _, _, _ in
      throw DiagnosticsTestError.failed("message write failed")
    }
    history.persistTerminalTurn = { _, _, _, _ in
      throw DiagnosticsTestError.failed("message write failed")
    }
    let store = TestStore(initialState: Self.appState()) {
      AppFeature()
    } withDependencies: { [history] in
      $0.queryPipeline = QueryPipeline { question, _ in
        AsyncStream { continuation in
          var telemetry = TurnTelemetry(originalQuestion: question)
          telemetry.standaloneQuestion = question
          continuation.yield(
            .turnFinished(
              outcome: .failed(reason: .unexpected),
              telemetry: telemetry))
          continuation.finish()
        }
      }
      $0.historyClient = history
      $0.diagnostics = recorder.client
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.chat(.binding(.set(\.composerText, "question"))))
    await store.send(.chat(.sendTapped))
    await store.finish()
    await store.skipReceivedActions()

    #expect(recorder.events.map(\.code).contains("history_message_save_failed"))
    #expect(store.state.presentedFailure?.title == "Conversation not saved")
  }

  @Test func dismissFailureClearsTheBanner() async {
    var initialState = AppFeature.State(
      debugModelIdentity: nil, launchBenchmarkQuestion: nil)
    initialState.presentedFailure = FailurePresentation(
      code: "history_export_failed",
      title: "Export failed",
      message: "Try again.",
      diagnostic: "disk full")
    let store = TestStore(initialState: initialState) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.dismissFailure) {
      $0.presentedFailure = nil
    }
  }

  @Test func submissionLifecycleLogsNoQuestionOrIdentifiers() async {
    let recorder = DiagnosticEventRecorder()
    let question = "private on-device question"
    var initialState = Self.appState()
    initialState.chat?.composerText = question
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.queryPipeline = QueryPipeline { receivedQuestion, _ in
        AsyncStream { continuation in
          var telemetry = TurnTelemetry(originalQuestion: receivedQuestion)
          telemetry.generatedCount = 1
          continuation.yield(
            .turnFinished(
              outcome: .failed(reason: .unexpected),
              telemetry: telemetry))
          continuation.finish()
        }
      }
      $0.historyClient = .noop()
      $0.diagnostics = recorder.client
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.chat(.submissionRequested))
    await store.send(.chat(.submissionFocusSettled))
    await store.finish()
    await store.skipReceivedActions()

    let rendered = recorder.events.map(String.init(describing:))
      .joined(separator: "\n")
    #expect(!rendered.contains(question))
    #expect(!rendered.contains(UUID(9).uuidString))
    #expect(recorder.events.map(\.code).contains("chat_submission_pending"))
    #expect(recorder.events.map(\.code).contains("chat_submission_focus_settled"))
    #expect(recorder.events.map(\.code).contains("chat_submission_committed"))
    #expect(recorder.events.map(\.code).contains("chat_turn_rendered"))
  }
}
