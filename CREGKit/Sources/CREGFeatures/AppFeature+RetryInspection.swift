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
          result = .failed(.history(operation: .load, error: error))
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
                diagnostic: "History inspection did not settle within five seconds.")),
            operationID: operationID))
      }
    ).cancellable(id: cancellationID)
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
