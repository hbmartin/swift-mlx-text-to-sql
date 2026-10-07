import CREGCore
import CREGEngine
import Foundation

@testable import CREGFeatures

extension AppFeature.State {
  mutating func installUndoDeletion(
    summary: ConversationSummary, deferredFailure: FailurePresentation? = nil
  ) {
    if conversations[id: summary.id] == nil { conversations.append(summary) }
    conversationDeletions[summary.id] = .init(token: UUID(99999), summary: summary)
    conversationDeletions[summary.id]?.deferredFailure = deferredFailure
    undoDeletionID = summary.id
  }
  mutating func installAwaitingDeletion(_ id: UUID) {
    guard let summary = conversations[id: id] else { return }
    conversationDeletions[id] = .init(token: UUID(99999), summary: summary)
    conversationDeletions[id]?.phase = .awaitingSettlement
  }
  mutating func holdRetryClaim(journalID: UUID, conversationID: UUID) {
    seedRetry(
      journalID, conversationID: conversationID,
      interruption: chat?.interruptedTurns.first { ($0.journalID ?? $0.executionID) == journalID })
    retryJournals[journalID]?.operations[journalID] = .claim(
      QueuedQuestion(
        id: journalID, conversationID: conversationID,
        submission: QuestionSubmission(question: "Held retry"), retryJournalID: journalID,
        submittedAt: Date(timeIntervalSince1970: 1)))
  }

  mutating func clearHeldRetryClaims() {
    for journalID in retryJournals.keys {
      removeRetryOperations(journalID, matching: { if case .claim = $0 { true } else { false } })
    }
  }

  mutating func holdRetryRelease(journalID: UUID?, conversationID: UUID?) {
    guard let journalID, let conversationID else { return }
    seedRetry(journalID, conversationID: conversationID)
    retryJournals[journalID]?.operations[journalID] = .release(
      QueuedQuestion(
        id: journalID, conversationID: conversationID,
        submission: QuestionSubmission(question: "Held retry"), retryJournalID: journalID,
        submittedAt: Date(timeIntervalSince1970: 1)))
  }

  mutating func installDismissal(
    _ recovery: AppFeature.PendingInterruptedDismissal, settled: Bool = false
  ) {
    seedRetry(
      recovery.journalID, conversationID: recovery.conversationID,
      interruption: recovery.interruption)
    retryJournals[recovery.journalID]?.intent = .dismissed
    retryJournals[recovery.journalID]?.dismissalRecovery = recovery
    retryJournals[recovery.journalID]?.dismissalIsSettled = settled
    if !settled { retryJournals[recovery.journalID]?.operations[recovery.attemptID] = .dismissal }
  }

  mutating func installRetryDeclines(journalID: UUID, writes: AppFeature.RetryDeclineWrites) {
    seedRetry(journalID, conversationID: writes.conversationID)
    for operationID in writes.operationIDs {
      retryJournals[journalID]?.operations[operationID] = .decline(
        writes.purposes[operationID] ?? .cancellation)
    }
  }

  mutating func holdRetryInspection(journalID: UUID, conversationID: UUID, requestID: UUID) {
    seedRetry(journalID, conversationID: conversationID)
    let generation = retryJournals[journalID]!.requestGeneration
    retryJournals[journalID]?.operations[requestID] = .inspection(
      QueuedQuestion(
        id: requestID, conversationID: conversationID, question: "Held inspection",
        submittedAt: Date(timeIntervalSince1970: 1)), generation: generation)
  }
}

private func operationID(
  _ state: AppFeature.State, _ journalID: UUID, matches: (AppFeature.RetryOperation) -> Bool
) -> UUID {
  state.retryJournals[journalID]?.operations.first { matches($0.value) }?.key ?? journalID
}

private func claimedRequest(_ queued: QueuedQuestion, state: AppFeature.State) -> QueuedQuestion {
  var request = queued
  let capturedID = queued.retryJournalID.flatMap { journalID in
    state.retryJournals[journalID]?.operations.values.compactMap { operation -> UUID? in
      switch operation {
      case .claim(let owned), .release(let owned), .cancellation(let owned): owned.retryExecutionID
      default: nil
      }
    }.first
  }
  request.retryExecutionID = capturedID ?? queued.retryExecutionID ?? queued.existingUserMessage?.id
  return request
}
func claimCompletion(
  _ queued: QueuedQuestion, _ count: Int?, _ failure: FailurePresentation? = nil,
  state: AppFeature.State
) -> AppFeature.Action {
  let outcome: AppFeature.RetryClaimOutcome =
    failure.map(AppFeature.RetryClaimOutcome.failed) ?? count.map(
      AppFeature.RetryClaimOutcome.claimed) ?? .refused
  return .queuedRetryClaimed(
    claimedRequest(queued, state: state), outcome,
    operationID: operationID(state, queued.retryJournalID!) {
      if case .claim = $0 { true } else { false }
    })
}
func releaseCompletion(
  _ queued: QueuedQuestion, _ failure: FailurePresentation?, state: AppFeature.State
) -> AppFeature.Action {
  .retryClaimReleased(
    claimedRequest(queued, state: state),
    operationID: operationID(state, queued.retryJournalID!) {
      if case .release = $0 { true } else { false }
    }, failure: failure)
}
func cancellationCompletion(
  _ queued: QueuedQuestion, _ failure: FailurePresentation?, state: AppFeature.State
) -> AppFeature.Action {
  .retryCancellationSettled(
    claimedRequest(queued, state: state),
    operationID: operationID(state, queued.retryJournalID!) {
      switch $0 {
      case .release, .cancellation: true
      default: false
      }
    }, failure: failure)
}
func cleanupCompletion(
  _ journalID: UUID, _ failure: FailurePresentation? = nil, state: AppFeature.State
) -> AppFeature.Action {
  .dismissedRetryClaimSettled(
    journalID, operationID: operationID(state, journalID) { $0 == .cleanup }, failure: failure)
}
func inspectionCompletion(_ queued: QueuedQuestion, _ exists: Bool, state: AppFeature.State)
  -> AppFeature.Action
{
  let journalID = queued.retryJournalID!
  let interruption =
    state.retryJournals[journalID]?.interruption
    ?? InterruptedTurn(
      question: queued.question, interruptedAt: queued.submittedAt, journalID: journalID,
      executionID: queued.existingUserMessage?.id, status: .manualRetryRequired,
      autoRetryCount: state.retryJournals[journalID]?.knownDurableCount ?? 0)
  return .queuedRetryStaleChecked(
    queued, exists ? .nonTrailingInterruption(interruption) : .missingJournal,
    operationID: operationID(state, journalID) { if case .inspection = $0 { true } else { false } })
}
