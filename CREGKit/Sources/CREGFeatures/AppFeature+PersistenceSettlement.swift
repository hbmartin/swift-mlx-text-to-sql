import CREGEngine
import ComposableArchitecture
import Foundation

extension AppFeature {
  /// All completed persistence paths retire the same ownership. The reducer
  /// reconciliation hook wakes scheduling after this transition exactly once.
  func settleTurnPersistence(
    state: inout State, questionID: UUID, conversationID: UUID? = nil,
    rollback: OptimisticUserTurn? = nil, failure: FailurePresentation? = nil
  ) -> Effect<Action> {
    let pending = state.pendingTurnPersistence.flatMap { $0.questionID == questionID ? $0 : nil }
    let active = state.activeTurn.flatMap { $0.questionID == questionID ? $0 : nil }
    guard let ownerID = pending?.conversationID ?? active?.conversationID else { return .none }
    if let conversationID, conversationID != ownerID { return .none }
    let replaced = pending?.replacedInterruptedTurn ?? active?.replacedInterruptedTurn
    if let rollback {
      rollBackOptimisticUserTurn(
        state: &state, questionID: questionID,
        conversationID: ownerID, optimisticTurn: rollback)
      if let replaced {
        let journalID = replaced.journalID ?? replaced.executionID
        if let journalID {
          state.seedRetry(journalID, conversationID: ownerID, interruption: replaced)
        }
        if state.chat?.conversationID == ownerID,
          !state.chat!.interruptedTurns.contains(where: {
            ($0.journalID ?? $0.executionID) == journalID
          })
        {
          state.chat?.interruptedTurns.append(replaced)
        }
      }
    }
    if state.pendingTurnPersistence?.questionID == questionID { state.pendingTurnPersistence = nil }
    if ["turn_persistence_barrier_timed_out", "turn_inference_drain_timed_out"].contains(
      state.presentedFailure?.code ?? "")
    {
      state.presentedFailure = nil
    }
    if ["turn_persistence_barrier_timed_out", "turn_inference_drain_timed_out"].contains(
      state.conversationDeletions[ownerID]?.deferredFailure?.code ?? "")
    {
      state.conversationDeletions[ownerID]?.deferredFailure = nil
    }
    var effects: [Effect<Action>] = [
      .cancel(id: TurnPersistenceTimeoutID(questionID: questionID)),
      .cancel(id: TurnPersistenceDrainTimeoutID(questionID: questionID)),
    ]
    if let userMessageID = pending?.userMessageID ?? rollback?.message.id {
      effects.append(
        .run { _ in
          await messageUpdateQueue.forgetOnceSave(conversationID: ownerID, messageID: userMessageID)
        })
    }
    if let failure {
      effects.append(
        handleConversationWriteFailure(state: &state, conversationID: ownerID, failure: failure))
    }
    if rollback == nil, pending?.writeFailure == nil, let pending,
      let context = pending.followUpContext,
      ownsSuggestions(
        state: state, conversationID: ownerID, generation: pending.suggestionGeneration)
    {
      refreshFMAvailability(state: &state)
      if state.isConversationPendingDeletion(ownerID) {
        state.pendingSuggestionContexts[ownerID] = PendingScopeDiagnosis(
          conversationID: ownerID, messageID: context.sourceAssistantMessageID,
          context: context, generation: pending.suggestionGeneration)
      } else if context.isRecoverySeed, let messageID = pending.terminalMessageID {
        effects.append(
          startScopeDiagnosis(
            state: &state, conversationID: ownerID,
            messageID: messageID, context: context, generation: pending.suggestionGeneration))
      } else {
        effects.append(
          startOrRetainFollowUpPreparation(
            state: &state, conversationID: ownerID,
            context: context, generation: pending.suggestionGeneration))
      }
    }
    syncSchedulerProjection(into: &state)
    effects.append(finishDeferredDeletion(state: &state, conversationID: ownerID))
    return .merge(effects)
  }
}
