import ComposableArchitecture
import Foundation
import Testing

@testable import CREGEngine
@testable import CREGFeatures

private actor DismissalHeldOperation {
  private var held = false
  private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  private var release: CheckedContinuation<Void, Never>?

  func hold() async {
    held = true
    let started = waiters.values
    waiters.removeAll()
    for waiter in started { waiter.resume() }
    await withCheckedContinuation { release = $0 }
  }

  func waitUntilHeld() async {
    guard !held else { return }
    let id = UUID()
    let timeout = Task {
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled, let waiter = waiters.removeValue(forKey: id) else { return }
      Issue.record("The history operation did not start within five seconds.")
      waiter.resume()
    }
    await withCheckedContinuation { waiters[id] = $0 }
    timeout.cancel()
  }

  func finish() {
    release?.resume()
    release = nil
  }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct InterruptedDismissalRecoveryTests {
  private typealias Scheduler = AppFeatureSchedulerTests
  private static let conversationID = Scheduler.conversationA

  private func dismissal(_ id: Int, at seconds: TimeInterval = 1)
    -> AppFeature.PendingInterruptedDismissal
  {
    let journalID = UUID(id)
    return AppFeature.PendingInterruptedDismissal(
      conversationID: Self.conversationID, journalID: journalID, attemptID: UUID(id + 100),
      interruption: InterruptedTurn(
        question: "Question \(id)", interruptedAt: Date(timeIntervalSince1970: seconds),
        journalID: journalID, executionID: journalID, status: .knownInterruption))
  }

  private func failure(_ id: Int) -> FailurePresentation {
    .history(operation: .messageSave, error: NSError(domain: "CREG.Dismissal", code: id))
  }

  private func completion(
    _ pending: AppFeature.PendingInterruptedDismissal, failure: FailurePresentation?
  ) -> AppFeature.Action {
    .interruptedDismissalFinished(
      conversationID: pending.conversationID, journalID: pending.journalID,
      attemptID: pending.attemptID, failure: failure)
  }

  @Test(arguments: [false, true])
  func overlappingFailuresRecoverIndependently(reverseOrder: Bool) async {
    let first = dismissal(9300)
    let second = dismissal(9301, at: 2)
    let successful = dismissal(9302, at: 3)
    var state = Scheduler.appState()
    state.isSceneActive = false
    state.retryReleaseJournalID = first.journalID
    state.retryReleaseConversationID = Self.conversationID
    for pending in [first, second, successful] {
      state.pendingInterruptedDismissals[pending.journalID] = pending
      state.dismissedRetryJournalIDs.insert(pending.journalID)
    }
    let diagnostics = DiagnosticEventRecorder()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.historyClient = .noop()
      $0.diagnostics = diagnostics.client
    }
    store.exhaustivity = .off
    for pending in reverseOrder ? [second, first] : [first, second] {
      await store.send(completion(pending, failure: failure(pending == first ? 1 : 2)))
      if pending == second { await store.receive(.operationFailed(failure(2))) }
    }
    #expect(store.state.pendingInterruptedDismissals[first.journalID]?.failure == failure(1))
    #expect(store.state.chat?.interruptedTurns.map(\.journalID) == [second.journalID])
    await store.send(completion(successful, failure: nil))
    #expect(store.state.pendingInterruptedDismissals[first.journalID] != nil)
    #expect(store.state.failedDismissalManualRetryIDs == [second.journalID])

    let user = ChatMessage(
      id: first.journalID, role: .user, body: .text(first.interruption.question),
      createdAt: first.interruption.interruptedAt)
    let queued = QueuedQuestion(
      id: UUID(9390), conversationID: Self.conversationID,
      submission: QuestionSubmission(question: first.interruption.question),
      retryJournalID: first.journalID,
      existingUserMessage: user, automaticRetry: true, submittedAt: user.createdAt)
    await store.send(.retryClaimReleased(queued, nil))
    await store.receive(.operationFailed(failure(1)))
    await store.finish()
    #expect(store.state.pendingInterruptedDismissals.isEmpty)
    #expect(store.state.failedDismissalManualRetryIDs == [first.journalID, second.journalID])
    #expect(
      store.state.chat?.interruptedTurns.map(\.journalID) == [first.journalID, second.journalID])
    #expect(
      store.state.chat?.interruptedTurns.allSatisfy { $0.status == .manualRetryRequired } == true)
    #expect(diagnostics.events.filter { $0.code == "history_message_save_failed" }.count == 2)
    #expect(store.state.presentedFailure == failure(1))
    await store.send(completion(first, failure: failure(3)))
    await store.finish()
    #expect(diagnostics.events.filter { $0.code == "history_message_save_failed" }.count == 2)
  }

  @Test(arguments: [false, true])
  func directCancellationWaitsAndSuppressesLateError(declineFails: Bool) async {
    let original = dismissal(9400)
    let user = ChatMessage(
      id: original.journalID, role: .user, body: .text(original.interruption.question),
      createdAt: original.interruption.interruptedAt)
    var state = Scheduler.appState()
    state.isSceneActive = false
    state.chat?.messages.append(user)
    state.chat?.interruptedTurns = [original.interruption]
    state.chat?.queuedRetryJournalIDs = [original.journalID]
    state.queue = [
      QueuedQuestion(
        id: UUID(9401), conversationID: Self.conversationID,
        submission: QuestionSubmission(question: user.previewText),
        retryJournalID: user.id, existingUserMessage: user, automaticRetry: true,
        submittedAt: user.createdAt)
    ]
    let held = DismissalHeldOperation()
    let writes = CallRecorder()
    let reloads = CallRecorder()
    let diagnostics = DiagnosticEventRecorder()
    let dismissalError = NSError(domain: "CREG.Dismissal", code: 4)
    let declineError = NSError(domain: "CREG.Decline", code: 5)
    var history = HistoryClient.noop()
    history.declineAutoRetry = { _, _ in
      writes.record("decline")
      if writes.recorded.count == 1 {
        await held.hold()
        if declineFails { throw declineError }
      }
    }
    history.endTurnJournal = { _, _ in throw dismissalError }
    history.loadConversation = { _ in
      reloads.record("load")
      throw DiagnosticsTestError.failed("History is unavailable")
    }
    history.claimTurnRetry = { _, _, _, _ in 0 }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.historyClient = history
      $0.diagnostics = diagnostics.client
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 4))
      $0.queryPipeline = Scheduler.hangingPipeline()
    }
    store.exhaustivity = .off
    await store.send(.chat(.cancelQueuedRetryTapped(user.id)))
    await store.receive(.chat(.delegate(.cancelQueuedRetry(user.id))))
    await held.waitUntilHeld()
    let operationID = store.state.pendingRetryDeclines[user.id]!.operationIDs.first!
    #expect(!store.state.isTurnSchedulerIdle)
    #expect(!store.state.isModelRecoveryIdle)
    await store.send(.chat(.interruptedDismissedFor(user.id)))
    await store.receive(
      .chat(
        .delegate(
          .dismissInterruptedTurn(
            conversationID: Self.conversationID, journalID: user.id,
            interruption: InterruptedTurn(
              question: original.interruption.question, interruptedAt: user.createdAt,
              journalID: user.id, executionID: user.id, status: .manualRetryRequired)))))
    let pending = store.state.pendingInterruptedDismissals[user.id]!
    let dismissalFailure = FailurePresentation.history(
      operation: .messageSave, error: dismissalError)
    await store.receive(completion(pending, failure: dismissalFailure))
    #expect(store.state.chat?.interruptedTurns.isEmpty == true)
    #expect(store.state.presentedFailure == nil)
    await store.send(.appBecameActive)
    #expect(!store.state.canDispatchTurn)
    #expect(store.state.activeTurn == nil)
    await held.finish()
    await store.receive(
      .retryDeclineFinished(
        conversationID: Self.conversationID, journalID: user.id, operationID: operationID,
        failure: declineFails ? .history(operation: .messageSave, error: declineError) : nil))
    // Assert before the original error's presentation can conceal a late decline error.
    #expect(store.state.presentedFailure == nil)
    #expect(store.state.chat?.interruptedTurn?.status == .manualRetryRequired)
    await store.receive(.operationFailed(dismissalFailure))
    await store.finish()
    #expect(store.state.pendingRetryDeclines.isEmpty)
    #expect(store.state.pendingInterruptedDismissals.isEmpty)
    #expect(store.state.failedDismissalManualRetryIDs.contains(user.id))
    #expect(store.state.presentedFailure == dismissalFailure)
    #expect(reloads.recorded.isEmpty)
    #expect(
      diagnostics.events.filter { $0.code == "retry_write_failed_after_dismissal" }.count
        == (declineFails ? 1 : 0))
    await store.send(.chat(.askAgainTappedFor(user.id)))
    await store.receive(.chat(.delegate(.retryInterruptedTurnFor(user.id))))
    await store.skipReceivedActions()
    #expect(store.state.activeTurn?.directlyUserStarted == true)
    #expect(store.state.failedDismissalRecoveries.isEmpty)
    #expect(!store.state.dismissedRetryJournalIDs.contains(user.id))
    await store.skipInFlightEffects()
  }

  @Test func recoveryWaitsForEveryDeclineAndIgnoresDuplicateCompletions() async {
    let pending = dismissal(9500)
    let first = UUID(9501)
    let second = UUID(9502)
    var state = Scheduler.appState()
    state.pendingInterruptedDismissals[pending.journalID] = pending
    state.dismissedRetryJournalIDs.insert(pending.journalID)
    state.pendingRetryDeclines[pending.journalID] = AppFeature.RetryDeclineWrites(
      conversationID: Self.conversationID, operationIDs: [first, second])
    let store = TestStore(initialState: state) { AppFeature() }
    store.exhaustivity = .off
    await store.send(completion(pending, failure: failure(6)))
    for repetition in 0..<2 {
      await store.send(
        .retryDeclineFinished(
          conversationID: Self.conversationID, journalID: pending.journalID,
          operationID: first, failure: nil))
      if repetition == 0 { await store.receive(.dispatchNextIfIdle) }
      #expect(store.state.pendingRetryDeclines[pending.journalID]?.operationIDs == [second])
      #expect(store.state.pendingInterruptedDismissals[pending.journalID] != nil)
      #expect(store.state.presentedFailure == nil)
    }
    await store.send(
      .retryDeclineFinished(
        conversationID: Self.conversationID, journalID: pending.journalID,
        operationID: second, failure: nil))
    await store.receive(.operationFailed(failure(6)))
    await store.finish()
    #expect(store.state.pendingRetryDeclines.isEmpty)
    #expect(store.state.chat?.interruptedTurn?.journalID == pending.journalID)
    #expect(store.state.canDispatchTurn)
  }

  @Test func directAndPostClaimDeclinesBothGateRecovery() async {
    let original = dismissal(9550)
    let user = ChatMessage(
      id: original.journalID, role: .user, body: .text(original.interruption.question),
      createdAt: original.interruption.interruptedAt)
    var state = Scheduler.appState()
    state.isSceneActive = false
    state.chat?.messages.append(user)
    state.chat?.interruptedTurns = [original.interruption]
    state.chat?.queuedRetryJournalIDs = [user.id]
    state.retryClaimInFlight = true
    state.retryClaimJournalID = user.id
    state.retryClaimConversationID = Self.conversationID
    let queued = QueuedQuestion(
      id: UUID(9551), conversationID: Self.conversationID,
      submission: QuestionSubmission(question: user.previewText),
      retryJournalID: user.id, existingUserMessage: user, automaticRetry: true,
      submittedAt: user.createdAt)
    let first = DismissalHeldOperation()
    let second = DismissalHeldOperation()
    let writes = CallRecorder()
    let error = NSError(domain: "CREG.Dismissal", code: 55)
    var history = HistoryClient.noop()
    history.endTurnJournal = { _, _ in throw error }
    history.declineAutoRetry = { _, _ in
      writes.record("decline")
      switch writes.recorded.count {
      case 1: await first.hold()
      case 2: await second.hold()
      default: break
      }
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.historyClient = history
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.chat(.delegate(.cancelQueuedRetry(user.id))))
    await first.waitUntilHeld()
    let firstID = store.state.pendingRetryDeclines[user.id]!.operationIDs.first!
    await store.send(.queuedRetryClaimed(queued, 1))
    await second.waitUntilHeld()
    let operations = store.state.pendingRetryDeclines[user.id]!.operationIDs
    #expect(operations.count == 2)
    let secondID = operations.first { $0 != firstID }!
    await store.send(.chat(.interruptedDismissedFor(user.id)))
    await store.receive(
      .chat(
        .delegate(
          .dismissInterruptedTurn(
            conversationID: Self.conversationID, journalID: user.id,
            interruption: InterruptedTurn(
              question: user.previewText, interruptedAt: user.createdAt,
              journalID: user.id, executionID: user.id, status: .manualRetryRequired)))))
    let pending = store.state.pendingInterruptedDismissals[user.id]!
    let originalFailure = FailurePresentation.history(operation: .messageSave, error: error)
    await store.receive(completion(pending, failure: originalFailure))
    await first.finish()
    await store.receive(
      .retryDeclineFinished(
        conversationID: Self.conversationID, journalID: user.id,
        operationID: firstID, failure: nil))
    #expect(store.state.pendingRetryDeclines[user.id]?.operationIDs == [secondID])
    #expect(store.state.chat?.interruptedTurns.isEmpty == true)
    #expect(store.state.presentedFailure == nil)
    await second.finish()
    await store.receive(
      .retryDeclineFinished(
        conversationID: Self.conversationID, journalID: user.id,
        operationID: secondID, failure: nil))
    #expect(store.state.pendingRetryDeclines.isEmpty)
    #expect(store.state.chat?.interruptedTurn?.status == .manualRetryRequired)
    await store.receive(.operationFailed(originalFailure))
    await store.finish()
  }

  @Test func recoveredAskAgainCanQueueBehindAnotherJournalsClaim() async {
    var recovered = dismissal(9570)
    recovered.interruption.status = .manualRetryRequired
    recovered.failure = failure(57)
    var state = Scheduler.appState()
    state.retryClaimInFlight = true
    state.retryClaimJournalID = UUID(9571)
    state.retryClaimConversationID = Self.conversationID
    state.failedDismissalRecoveries[recovered.journalID] = recovered
    state.dismissedRetryJournalIDs.insert(recovered.journalID)
    state.chat?.interruptedTurns = [recovered.interruption]
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 4))
    }
    store.exhaustivity = .off
    await store.send(.chat(.askAgainTappedFor(recovered.journalID)))
    await store.receive(.chat(.delegate(.retryInterruptedTurnFor(recovered.journalID))))
    #expect(store.state.queue.first?.retryJournalID == recovered.journalID)
    #expect(store.state.queue.first?.automaticRetry == false)
    #expect(!store.state.dismissedRetryJournalIDs.contains(recovered.journalID))
    #expect(store.state.activeTurn == nil)
  }

  @Test func recoveryPreservesLiveChatAndRejectsStaleDismissalAttempts() async {
    let pending = dismissal(9600)
    let activeUser = ChatMessage(
      id: UUID(9601), role: .user, body: .text("Active question"),
      createdAt: Date(timeIntervalSince1970: 2))
    var state = Scheduler.appState()
    state.chat?.messages.append(activeUser)
    state.chat?.composerText = "Unsaved draft"
    state.chat?.correctionContext = .init(messageID: UUID(9602), answerNarration: "Correction")
    state.chat?.readAloud = .init(messageID: UUID(9602))
    state.chat?.processing = .init(
      questionID: activeUser.id, question: activeUser.previewText,
      startedAt: activeUser.createdAt, isTimelineExpanded: true)
    state.activeTurn = AppFeature.ActiveTurn(
      questionID: activeUser.id, conversationID: Self.conversationID,
      question: activeUser.previewText, startedAt: activeUser.createdAt)
    state.pendingInterruptedDismissals[pending.journalID] = pending
    state.dismissedRetryJournalIDs.insert(pending.journalID)
    let store = TestStore(initialState: state) { AppFeature() }
    store.exhaustivity = .off
    await store.send(
      .interruptedDismissalFinished(
        conversationID: Self.conversationID, journalID: pending.journalID,
        attemptID: UUID(9699), failure: nil))
    #expect(store.state == state)
    await store.send(completion(pending, failure: failure(7)))
    await store.finish()
    #expect(store.state.chat?.messages == state.chat?.messages)
    #expect(store.state.chat?.composerText == "Unsaved draft")
    #expect(store.state.chat?.correctionContext == state.chat?.correctionContext)
    #expect(store.state.chat?.readAloud == state.chat?.readAloud)
    #expect(store.state.chat?.processing?.questionID == activeUser.id)
    #expect(store.state.chat?.processing?.isTimelineExpanded == true)
    #expect(store.state.activeTurn == state.activeTurn)
    #expect(
      store.state.chat?.interruptedTurns == [
        InterruptedTurn(
          question: pending.interruption.question,
          interruptedAt: pending.interruption.interruptedAt,
          journalID: pending.journalID, executionID: pending.journalID,
          status: .manualRetryRequired)
      ])
  }

  @Test func selectionLoadsHidePendingAndSuccessfulDismissalsAndRestoreFailedOnes() async {
    let pending = dismissal(9700)
    let failed = dismissal(9701, at: 2)
    let successful = dismissal(9702, at: 3)
    var state = Scheduler.appState(selected: Scheduler.conversationB)
    state.isSceneActive = false
    let summary = state.conversations[id: Self.conversationID]!
    state.pendingInterruptedDismissals[pending.journalID] = pending
    state.pendingInterruptedDismissals[failed.journalID] = failed
    state.dismissedRetryJournalIDs = [pending.journalID, failed.journalID, successful.journalID]
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 4))
    }
    store.exhaustivity = .off
    await store.send(completion(failed, failure: failure(8)))
    await store.receive(.operationFailed(failure(8)))
    await store.finish()
    #expect(store.state.chat?.conversationID == Scheduler.conversationB)
    #expect(store.state.chat?.interruptedTurns.isEmpty == true)
    await store.send(
      .conversationLoaded(
        ConversationSnapshot(
          summary: summary,
          interruptedTurns: [pending.interruption, failed.interruption, successful.interruption])))
    await store.finish()
    #expect(store.state.chat?.interruptedTurns.map(\.journalID) == [failed.journalID])
    #expect(store.state.chat?.interruptedTurn?.canAutoRetry == false)
    await store.send(.chat(.askAgainTappedFor(failed.journalID)))
    await store.receive(.chat(.delegate(.retryInterruptedTurnFor(failed.journalID))))
    #expect(store.state.queue.first?.retryJournalID == failed.journalID)
    #expect(store.state.queue.first?.automaticRetry == false)
  }

  @Test(arguments: [false, true])
  func deletionRetainsRecoveryForUndoAndClearsItOnCommit(undo: Bool) async {
    let pending = dismissal(9800)
    var state = Scheduler.appState()
    state.isSceneActive = false
    let summary = state.conversations[id: Self.conversationID]!
    state.conversations.remove(id: Self.conversationID)
    state.pendingDeletion = .init(summary: summary, index: 0)
    state.pendingInterruptedDismissals[pending.journalID] = pending
    state.dismissedRetryJournalIDs.insert(pending.journalID)
    if !undo {
      state.pendingRetryDeclines[UUID(9801)] = AppFeature.RetryDeclineWrites(
        conversationID: Self.conversationID, operationIDs: [UUID(9802)])
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.historyClient = .noop()
    }
    store.exhaustivity = .off
    await store.send(completion(pending, failure: failure(9)))
    #expect(store.state.chat?.interruptedTurns.isEmpty == true)
    #expect(store.state.failedDismissalManualRetryIDs.contains(pending.journalID))
    if undo {
      await store.send(.undoDeleteTapped)
      await store.receive(.operationFailed(failure(9)))
      await store.finish()
      #expect(store.state.conversations[id: Self.conversationID] != nil)
      #expect(store.state.chat?.interruptedTurn?.journalID == pending.journalID)
      #expect(store.state.presentedFailure == failure(9))
    } else {
      await store.send(.deleteCountdownFinished)
      await store.finish()
      #expect(store.state.pendingInterruptedDismissals.isEmpty)
      #expect(store.state.failedDismissalRecoveries.isEmpty)
      #expect(store.state.pendingRetryDeclines.isEmpty)
      await store.send(completion(pending, failure: failure(10)))
      await store.send(
        .retryDeclineFinished(
          conversationID: Self.conversationID, journalID: UUID(9801),
          operationID: UUID(9802), failure: failure(10)))
      #expect(store.state.failedDismissalRecoveries.isEmpty)
      #expect(store.state.presentedFailure == nil)
    }
  }

  @Test(arguments: [false, true], [false, true])
  func claimErrorsAfterDismissalAreIdentifiedAndSuppressed(
    promoted: Bool, dismissalFails: Bool
  ) async {
    let original = dismissal(9700)
    let user = ChatMessage(
      id: original.journalID, role: .user, body: .text(original.interruption.question),
      createdAt: original.interruption.interruptedAt)
    let queued = QueuedQuestion(
      id: UUID(9701), conversationID: Self.conversationID,
      submission: QuestionSubmission(question: user.previewText), retryJournalID: user.id,
      existingUserMessage: user, automaticRetry: true, submittedAt: user.createdAt)
    var state = Scheduler.appState()
    state.chat?.messages.append(user)
    state.chat?.interruptedTurns = [original.interruption]
    state.queue = [queued]
    if promoted { state.userPromotedRetryJournalIDs.insert(user.id) }
    let held = DismissalHeldOperation()
    let claims = CallRecorder()
    let loads = CallRecorder()
    let diagnostics = DiagnosticEventRecorder()
    let claimError = NSError(domain: "CREG.Claim", code: 97)
    let claimFailure = FailurePresentation.history(operation: .messageSave, error: claimError)
    let dismissalError = NSError(domain: "CREG.Dismissal", code: 98)
    let dismissalFailure = FailurePresentation.history(
      operation: .messageSave, error: dismissalError)
    var history = HistoryClient.noop()
    history.claimTurnRetry = { _, _, _, automatic in
      claims.record(automatic ? "automatic" : "manual")
      if promoted && automatic { return 1 }
      await held.hold()
      throw claimError
    }
    history.endTurnJournal = { _, _ in if dismissalFails { throw dismissalError } }
    history.loadConversation = { _ in
      loads.record("load")
      throw DiagnosticsTestError.failed("Recovery must not load history")
    }
    let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
      $0.historyClient = history
      $0.diagnostics = diagnostics.client
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.dispatchNextIfIdle)
    if promoted { await store.receive(.queuedRetryClaimed(queued, 1)) }
    await held.waitUntilHeld()
    await store.send(.appBecameInactive)
    let removed = store.state.chat!.interruptedTurn!
    await store.send(.chat(.interruptedDismissedFor(user.id)))
    await store.receive(.chat(.delegate(.dismissInterruptedTurn(
      conversationID: Self.conversationID, journalID: user.id, interruption: removed))))
    let pending = store.state.pendingInterruptedDismissals[user.id]!
    await store.receive(completion(pending, failure: dismissalFails ? dismissalFailure : nil))
    #expect(store.state.retryClaimInFlight)
    #expect(store.state.chat?.interruptedTurns.isEmpty == true)
    #expect(store.state.presentedFailure == nil)
    await held.finish()
    var completed = queued
    completed.automaticRetry = !promoted
    await store.receive(.queuedRetryClaimed(completed, nil, claimFailure))
    #expect(store.state.presentedFailure == nil)
    await store.receive(.dismissedRetryClaimSettled(user.id))
    if dismissalFails { await store.receive(.operationFailed(dismissalFailure)) }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(!store.state.retryClaimInFlight)
    #expect(store.state.retryClaimJournalID == nil)
    #expect(store.state.retryClaimCleanupJournalID == nil)
    #expect(store.state.pendingRetryDeclines.isEmpty)
    #expect(store.state.pendingInterruptedDismissals.isEmpty)
    #expect(store.state.presentedFailure == (dismissalFails ? dismissalFailure : nil))
    #expect(store.state.failedDismissalManualRetryIDs.contains(user.id) == dismissalFails)
    #expect(loads.recorded.isEmpty)
    #expect(claims.recorded == (promoted ? ["automatic", "manual"] : ["automatic"]))
    #expect(diagnostics.events.filter { $0.code == "retry_write_failed_after_dismissal" }.count == 1)
    let presented = diagnostics.events.filter { $0.code == "history_message_save_failed" }
    #expect(presented.count == (dismissalFails ? 1 : 0))
    #expect(presented.first?.details == (dismissalFails ? dismissalFailure.diagnostic : nil))
    await store.send(.queuedRetryClaimed(completed, nil, claimFailure))
    #expect(diagnostics.events.filter { $0.code == "retry_write_failed_after_dismissal" }.count == 1)
    if dismissalFails {
      await store.send(.chat(.askAgainTappedFor(user.id)))
      await store.receive(.chat(.delegate(.retryInterruptedTurnFor(user.id))))
      #expect(store.state.queue.first?.retryJournalID == user.id)
      #expect(store.state.queue.first?.automaticRetry == false)
    }
  }

  @Test func staleClaimCompletionCannotClearAnotherJournalsClaim() async {
    let original = dismissal(9710)
    let user = ChatMessage(
      id: original.journalID, role: .user, body: .text(original.interruption.question),
      createdAt: original.interruption.interruptedAt)
    let queued = QueuedQuestion(
      id: UUID(9711), conversationID: Self.conversationID,
      submission: QuestionSubmission(question: user.previewText), retryJournalID: user.id,
      existingUserMessage: user, automaticRetry: true, submittedAt: user.createdAt)
    var state = Scheduler.appState()
    state.retryClaimInFlight = true
    state.retryClaimJournalID = UUID(9712)
    state.retryClaimConversationID = Self.conversationID
    let diagnostics = DiagnosticEventRecorder()
    let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
      $0.diagnostics = diagnostics.client
    }
    await store.send(.queuedRetryClaimed(queued, nil, failure(99)))
    #expect(store.state == state)
    #expect(diagnostics.events.isEmpty)
  }

  @Test func thrownClaimPresentsOnlyTheActualFailure() async {
    let original = dismissal(9720)
    let user = ChatMessage(
      id: original.journalID, role: .user, body: .text(original.interruption.question),
      createdAt: original.interruption.interruptedAt)
    let queued = QueuedQuestion(
      id: UUID(9721), conversationID: Self.conversationID,
      submission: QuestionSubmission(question: user.previewText), retryJournalID: user.id,
      existingUserMessage: user, automaticRetry: true, submittedAt: user.createdAt)
    var state = Scheduler.appState()
    state.chat?.messages.append(user)
    state.chat?.interruptedTurns = [original.interruption]
    state.queue = [queued]
    let diagnostics = DiagnosticEventRecorder()
    let error = NSError(domain: "CREG.Claim", code: 100)
    let actual = FailurePresentation.history(operation: .messageSave, error: error)
    let snapshot = ConversationSnapshot(
      summary: state.conversations[id: Self.conversationID]!, messages: [user])
    var history = HistoryClient.noop()
    history.claimTurnRetry = { _, _, _, _ in throw error }
    history.loadConversation = { _ in snapshot }
    let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
      $0.historyClient = history
      $0.diagnostics = diagnostics.client
    }
    store.exhaustivity = .off
    await store.send(.dispatchNextIfIdle)
    await store.receive(.queuedRetryClaimed(queued, nil, actual))
    await store.receive(.operationFailed(actual))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.presentedFailure == actual)
    #expect(diagnostics.events.filter { $0.code == actual.code }.count == 1)
    #expect(!diagnostics.events.contains { $0.code == "retry_claim_failed" })
  }

  @Test(arguments: [false, true])
  func refusedClaimDeclineGatesDismissalRecovery(declineFails: Bool) async {
    let original = dismissal(9730)
    let user = ChatMessage(
      id: original.journalID, role: .user, body: .text(original.interruption.question),
      createdAt: original.interruption.interruptedAt)
    let queued = QueuedQuestion(
      id: UUID(9731), conversationID: Self.conversationID,
      submission: QuestionSubmission(question: user.previewText), retryJournalID: user.id,
      existingUserMessage: user, automaticRetry: true, submittedAt: user.createdAt)
    var state = Scheduler.appState()
    state.isSceneActive = false
    state.chat?.messages.append(user)
    state.chat?.interruptedTurns = [original.interruption]
    let held = DismissalHeldOperation()
    let declines = CallRecorder()
    let diagnostics = DiagnosticEventRecorder()
    let dismissalError = NSError(domain: "CREG.Dismissal", code: 101)
    let declineError = NSError(domain: "CREG.Decline", code: 102)
    let originalFailure = FailurePresentation.history(operation: .messageSave, error: dismissalError)
    var history = HistoryClient.noop()
    history.endTurnJournal = { _, _ in throw dismissalError }
    history.declineAutoRetry = { _, _ in
      declines.record("decline")
      if declines.recorded.count == 1 {
        await held.hold()
        if declineFails { throw declineError }
      }
    }
    let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
      $0.historyClient = history
      $0.diagnostics = diagnostics.client
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.queuedRetryStaleChecked(queued, true))
    await held.waitUntilHeld()
    let operationID = store.state.pendingRetryDeclines[user.id]!.operationIDs.first!
    let removed = store.state.chat!.interruptedTurn!
    await store.send(.chat(.interruptedDismissedFor(user.id)))
    await store.receive(.chat(.delegate(.dismissInterruptedTurn(
      conversationID: Self.conversationID, journalID: user.id, interruption: removed))))
    let pending = store.state.pendingInterruptedDismissals[user.id]!
    await store.receive(completion(pending, failure: originalFailure))
    #expect(store.state.chat?.interruptedTurns.isEmpty == true)
    #expect(store.state.presentedFailure == nil)
    await held.finish()
    await store.receive(.retryDeclineFinished(
      conversationID: Self.conversationID, journalID: user.id, operationID: operationID,
      failure: declineFails ? .history(operation: .messageSave, error: declineError) : nil))
    await store.receive(.operationFailed(originalFailure))
    await store.finish()
    #expect(store.state.pendingRetryDeclines.isEmpty)
    #expect(store.state.pendingInterruptedDismissals.isEmpty)
    #expect(store.state.chat?.interruptedTurn?.status == .manualRetryRequired)
    #expect(diagnostics.events.filter { $0.code == originalFailure.code }.count == 1)
    #expect(diagnostics.events.filter { $0.code == "retry_write_failed_after_dismissal" }.count
      == (declineFails ? 1 : 0))
  }

}
