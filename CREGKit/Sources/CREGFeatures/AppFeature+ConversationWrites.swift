import ComposableArchitecture
import Foundation

extension AppFeature {
  enum ConversationWriteInvariantError: Error, CustomStringConvertible {
    case missingResultPresentationMessage
    var description: String { "Result presentation write has no fallback message." }
  }

  public enum ConversationWriteTarget: Hashable, Sendable {
    case draft
    case resultPresentation(UUID)
    var operation: ConversationOperation {
      switch self {
      case .draft: .draft
      case .resultPresentation: .resultPresentation
      }
    }
  }

  public enum ConversationWriteSettlement: Equatable, Sendable {
    case saved, superseded, discardedDuringDeletion
    case failed(FailurePresentation)
    init(_ outcome: MessageUpdateQueue.SaveOutcome) {
      switch outcome {
      case .saved: self = .saved
      case .superseded: self = .superseded
      case .discardedDuringDeletion: self = .discardedDuringDeletion
      }
    }
  }

  struct ConversationEdit: Equatable, Sendable {
    enum Value: Equatable, Sendable {
      case draft(String)
      case resultPresentation(ResultPresentationPreference)
    }
    enum Phase: Equatable, Sendable {
      case debouncing, saving, saved
      case failed(FailurePresentation)
      var isFailed: Bool { if case .failed = self { true } else { false } }
      var isRetryable: Bool {
        if case .failed(let failure) = self { failure.allowsConversationWriteRetry }
        else { false }
      }
    }
    var value: Value
    var revision: UInt64
    var phase: Phase
    /// Needed only until the preference is durable, for the store's insert fallback.
    var fallbackMessage: ChatMessage?
  }

  /// Runs before the optional child so a migration's compare-and-set sees
  /// the original preference. Its effects are owned by the root.
  func captureResultPresentationWrite(state: inout State, action: Action) -> Effect<Action> {
    guard case .chat(let action) = action, let chat = state.chat,
      state.isConversationLive(chat.conversationID),
      let message = ChatFeature.resultPresentationWrite(state: chat, action: action)
    else { return .none }
    let revision = state.nextConversationWriteRevision()
    let target = ConversationWriteTarget.resultPresentation(message.id)
    let edit = ConversationEdit(value: .resultPresentation(message.resultPresentation),
      revision: revision, phase: .saving, fallbackMessage: message)
    state.conversationEdits[chat.conversationID, default: [:]][target] = edit
    return saveConversationEdit(conversationID: chat.conversationID, target: target, edit: edit)
  }

  func acceptDraft(state: inout State, conversationID: UUID, draft: String,
    debounce: Bool
  ) -> Effect<Action> {
    let revision = state.nextConversationWriteRevision()
    let edit = ConversationEdit(value: .draft(draft), revision: revision,
      phase: debounce ? .debouncing : .saving)
    state.conversationEdits[conversationID, default: [:]][.draft] = edit
    if debounce {
      return .run { send in
        try await clock.sleep(for: .milliseconds(500))
        await send(.draftSaveDue(conversationID: conversationID, revision: revision))
      }.cancellable(id: DraftSaveID(conversationID: conversationID), cancelInFlight: true)
    }
    return .concatenate(
      .cancel(id: DraftSaveID(conversationID: conversationID)),
      saveConversationEdit(conversationID: conversationID, target: .draft, edit: edit))
  }

  func saveConversationEdit(conversationID: UUID, target: ConversationWriteTarget,
    edit: ConversationEdit
  ) -> Effect<Action> {
    .run { send in
      do {
        let outcome: MessageUpdateQueue.SaveOutcome
        switch edit.value {
        case .draft(let draft):
          outcome = try await messageUpdateQueue.saveDraft(
            conversationID: conversationID, revision: edit.revision) {
              try await history.saveDraft(conversationID, draft)
            }
        case .resultPresentation(let preference):
          guard var message = edit.fallbackMessage else {
            throw ConversationWriteInvariantError.missingResultPresentationMessage
          }
          message.resultPresentation = preference
          let savedMessage = message
          outcome = try await messageUpdateQueue.save(conversationID: conversationID,
            messageID: savedMessage.id, revision: edit.revision) {
              try await history.updateResultPresentation(conversationID, savedMessage)
            }
        }
        await send(.conversationWriteSettled(conversationID: conversationID, target: target,
          revision: edit.revision, settlement: .init(outcome)))
      } catch {
        let failure: FailurePresentation = target == .draft
          ? .history(operation: .draftSave, error: error) : .resultPreferenceSave(error: error)
        await send(.conversationWriteSettled(conversationID: conversationID, target: target,
          revision: edit.revision, settlement: .failed(failure)))
      }
    }
  }

  func settleConversationEdit(state: inout State, conversationID: UUID,
    target: ConversationWriteTarget, revision: UInt64, settlement: ConversationWriteSettlement
  ) -> Effect<Action> {
    if state.conversationDeletions[conversationID]?.phase == .committed {
      if case .failed(let failure) = settlement {
        recordDeletedConversationWriteFailure(failure: failure,
          operationNumber: state.conversationDeletions[conversationID]?.diagnosticOperationNumber)
      }
      return .none
    }
    guard var edit = state.conversationEdits[conversationID]?[target],
      edit.revision == revision, edit.phase == .saving else {
      if case .failed(let failure) = settlement { recordFailure(failure) }
      return .none
    }
    let owner = FailureOwner.conversationOperation(conversationID, target.operation)
    switch settlement {
    case .saved:
      edit.phase = .saved
      edit.fallbackMessage = nil
      state.conversationEdits[conversationID]?[target] = edit
      state.markHistoryStoreAvailable()
      if !state.hasOutstandingConversationWrites(owner: owner) {
        state.failures.removeAll { $0.owner == owner }
        state.conversationDeletions[conversationID]?.deferredOperationFailures.removeAll { $0.owner == owner }
        state.conversationDeletions[conversationID]?.deferredNewOccurrenceOwners.remove(owner)
      }
      return .none
    case .failed(let failure):
      edit.phase = .failed(failure)
      state.conversationEdits[conversationID]?[target] = edit
      if state.isConversationPendingDeletion(conversationID) {
        return handleConversationWriteFailure(state: &state, conversationID: conversationID,
          failure: failure, owner: owner, newOccurrence: true)
      }
      guard state.isConversationLive(conversationID) else {
        recordDeletedConversationWriteFailure(failure: failure, operationNumber: nil)
        return .none
      }
      presentFailure(state: &state, primary: failure, owner: owner, newOccurrence: true)
      return .none
    case .superseded, .discardedDuringDeletion:
      // Superseded revisions have already been replaced in the ledger;
      // deletion discards are consumed by the committed-deletion guard above.
      return .none
    }
  }

  func retryConversationWrites(state: inout State, owner: FailureOwner) -> Effect<Action> {
    guard case .conversationOperation(let id, let operation) = owner,
      state.isConversationLive(id) else { return .none }
    let failed = (state.conversationEdits[id] ?? [:]).filter {
      $0.key.operation == operation && $0.value.phase.isRetryable
    }.sorted { $0.value.revision < $1.value.revision }
    return .merge(failed.map { target, previous in
      var edit = previous
      edit.revision = state.nextConversationWriteRevision()
      edit.phase = .saving
      state.conversationEdits[id]?[target] = edit
      return saveConversationEdit(conversationID: id, target: target, edit: edit)
    })
  }
}

extension AppFeature.State {
  mutating func nextConversationWriteRevision() -> UInt64 {
    conversationWriteSequence += 1
    return conversationWriteSequence
  }

  func hasOutstandingConversationWrites(owner: AppFeature.FailureOwner) -> Bool {
    guard case .conversationOperation(let id, let operation) = owner else { return false }
    return (conversationEdits[id] ?? [:]).contains {
      $0.key.operation == operation && $0.value.phase != .saved
    }
  }

  var retryableConversationWriteOwners: Set<AppFeature.FailureOwner> {
    Set(conversationEdits.flatMap { id, edits in
      guard isConversationLive(id) else { return [AppFeature.FailureOwner]() }
      return edits.compactMap { target, edit in
        edit.phase.isRetryable ? .conversationOperation(id, target.operation) : nil
      }
    })
  }

  mutating func overlayConversationEdits() {
    guard let id = chat?.conversationID, let edits = conversationEdits[id] else { return }
    for (target, edit) in edits {
      switch (target, edit.value) {
      case (.draft, .draft(let draft)):
        chat?.composerText = draft
      case (.resultPresentation(let messageID), .resultPresentation(let preference)):
        chat?.messages[id: messageID]?.resultPresentation = preference
      default: break
      }
    }
  }
}
