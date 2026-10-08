import CREGEngine
import ComposableArchitecture
import Foundation

extension AppFeature {
  func inspectRetry(state: inout State, queued: QueuedQuestion) -> Effect<Action> {
    guard let journalID = queued.retryJournalID else { return .none }
    state.seedRetry(journalID, conversationID: queued.conversationID)
    let generation = state.retryJournals[journalID]!.requestGeneration
    let operationID = uuid()
    state.retryJournals[journalID]?.operations[operationID] = .inspection(
      queued, generation: generation)
    syncSchedulerProjection(into: &state)
    let cancellationID = RetryInspectionID(journalID: journalID)
    return .merge(
      .run { send in
        let result: RetryInspectionResult
        do {
          let snapshot = try await history.loadConversation(queued.conversationID)
          if let interruption = snapshot.interruptedTurns.first(where: {
            ($0.journalID ?? $0.executionID) == journalID
          }) {
            let trailing = snapshot.messages.last
            if trailing?.role == .user,
              trailing?.id == interruption.executionID,
              trailing?.previewText == interruption.question
            {
              result = .trailingUnansweredUserTurn(interruption)
            } else {
              result = .nonTrailingInterruption(interruption)
            }
          } else {
            result = .missingJournal
          }
        } catch {
          var failure = FailurePresentation.history(operation: .load, error: error)
          if failure.cause == nil {
            failure.title = "Could not check this retry"
            failure.message = "Please tap Ask Again to try once more."
            failure.recovery = .askAgain
          }
          result = .failed(failure)
        }
        guard !Task.isCancelled else { return }
        await send(.queuedRetryStaleChecked(queued, result, operationID: operationID))
      },
      .run { send in
        try await clock.sleep(for: .seconds(5))
        await send(
          .queuedRetryStaleChecked(
            queued,
            .failed(
              FailurePresentation(
                code: "retry_inspection_timed_out", title: "Could not check this retry",
                message: "Please tap Ask Again to try once more.",
                diagnostic: "History inspection did not settle within five seconds.", recovery: .askAgain)),
            operationID: operationID))
      }
    ).cancellable(id: cancellationID)
  }

  func retireMissingRetry(state: inout State, queued: QueuedQuestion) -> Effect<Action> {
    guard let journalID = queued.retryJournalID else { return .none }
    let manualRequested = !queued.automaticRetry || state.userPromotedRetryJournalIDs.contains(journalID)
    let generation = state.retryJournals[journalID]?.requestGeneration ?? 0
    state.removeAutomaticCandidate(journalID)
    state.removeRetryPromotion(journalID)
    state.retryJournals[journalID]?.interruption = nil
    state.queue.removeAll { $0.retryJournalID == journalID }
    if state.chat?.conversationID == queued.conversationID {
      state.chat?.interruptedTurns.removeAll { ($0.journalID ?? $0.executionID) == journalID }
    }
    syncSchedulerProjection(into: &state)
    let failure = FailurePresentation(
      code: "retry_journal_missing", title: "Retry unavailable",
      message: "This interrupted question is no longer available to retry. Send it as a new question to try again.",
      diagnostic: "History inspection found no journal for retry \(journalID.uuidString).")
    if !manualRequested {
      diagnostics.record(DiagnosticEvent(
        level: .info, category: .history, code: failure.code, summary: failure.title,
        details: failure.diagnostic,
        context: ["operation_number": String(state.retryJournals[journalID]?.diagnosticOperationNumber ?? 0)]))
      return .none
    }
    return .send(.operationFailed(failure,
      owner: .retry(conversationID: queued.conversationID, journalID: journalID, generation: generation)))
  }

  func restoreManualRetry(state: inout State, journalID: UUID) {
    state.removeAutomaticCandidate(journalID)
    state.retryJournals[journalID]?.intent = .idle
    state.retryJournals[journalID]?.interruption?.status = .manualRetryRequired
    if let conversationID = state.retryJournals[journalID]?.conversationID,
      state.chat?.conversationID == conversationID,
      let index = state.chat?.interruptedTurns.firstIndex(where: {
        ($0.journalID ?? $0.executionID) == journalID
      })
    {
      state.chat?.interruptedTurns[index].status = .manualRetryRequired
    }
    syncSchedulerProjection(into: &state)
  }
}
