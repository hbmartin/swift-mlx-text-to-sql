import ComposableArchitecture
import Foundation

extension AppFeature {
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
      case debouncing, saving
      case failed(FailurePresentation)
    }
    enum PendingWrite: Equatable, Sendable {
      case draft(String)
      case resultPresentation(ChatMessage)

      var value: Value {
        switch self {
        case .draft(let draft): .draft(draft)
        case .resultPresentation(let message): .resultPresentation(message.resultPresentation)
        }
      }
    }
    enum Status: Equatable, Sendable {
      case pending(PendingWrite, Phase)
      case saved(Value)
    }
    var revision: UInt64
    var status: Status
    var value: Value {
      switch status {
      case .pending(let write, _): write.value
      case .saved(let value): value
      }
    }
    var isSaved: Bool { if case .saved = status { true } else { false } }
    var isSaving: Bool { if case .pending(_, .saving) = status { true } else { false } }
    var isRetryable: Bool { if case .pending(_, .failed) = status { true } else { false } }
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
    let write = ConversationEdit.PendingWrite.resultPresentation(message)
    let edit = ConversationEdit(revision: revision, status: .pending(write, .saving))
    state.conversationEdits[chat.conversationID, default: [:]][target] = edit
    return saveConversationEdit(conversationID: chat.conversationID, target: target,
      revision: revision, write: write)
  }

  func acceptDraft(state: inout State, conversationID: UUID, draft: String,
    debounce: Bool
  ) -> Effect<Action> {
    let revision = state.nextConversationWriteRevision()
    let write = ConversationEdit.PendingWrite.draft(draft)
    let edit = ConversationEdit(revision: revision,
      status: .pending(write, debounce ? .debouncing : .saving))
    state.conversationEdits[conversationID, default: [:]][.draft] = edit
    if debounce {
      return .run { send in
        try await clock.sleep(for: .milliseconds(500))
        await send(.draftSaveDue(conversationID: conversationID, revision: revision))
      }.cancellable(id: DraftSaveID(conversationID: conversationID), cancelInFlight: true)
    }
    return .concatenate(
      .cancel(id: DraftSaveID(conversationID: conversationID)),
      saveConversationEdit(conversationID: conversationID, target: .draft,
        revision: revision, write: write))
  }

  func saveConversationEdit(conversationID: UUID, target: ConversationWriteTarget,
    revision: UInt64, write: ConversationEdit.PendingWrite
  ) -> Effect<Action> {
    .run { send in
      do {
        let outcome: MessageUpdateQueue.SaveOutcome
        switch write {
        case .draft(let draft):
          outcome = try await messageUpdateQueue.saveDraft(
            conversationID: conversationID, revision: revision) {
              try await history.saveDraft(conversationID, draft)
            }
        case .resultPresentation(let savedMessage):
          outcome = try await messageUpdateQueue.save(conversationID: conversationID,
            messageID: savedMessage.id, revision: revision) {
              try await history.updateResultPresentation(conversationID, savedMessage)
            }
        }
        await send(.conversationWriteSettled(conversationID: conversationID, target: target,
          revision: revision, settlement: .init(outcome)))
      } catch {
        let failure: FailurePresentation = target == .draft
          ? .history(operation: .draftSave, error: error) : .resultPreferenceSave(error: error)
        await send(.conversationWriteSettled(conversationID: conversationID, target: target,
          revision: revision, settlement: .failed(failure)))
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
      edit.revision == revision, edit.isSaving, case .pending(let write, _) = edit.status else {
      if case .failed(let failure) = settlement { recordFailure(failure) }
      return .none
    }
    let owner = FailureOwner.conversationOperation(conversationID, target.operation)
    switch settlement {
    case .saved:
      edit.status = .saved(write.value)
      state.conversationEdits[conversationID]?[target] = edit
      state.markHistoryStoreAvailable()
      if !state.hasOutstandingConversationWrites(owner: owner) {
        state.failures.removeAll { $0.owner == owner }
        state.conversationDeletions[conversationID]?.deferredOperationFailures.removeAll { $0.owner == owner }
        state.conversationDeletions[conversationID]?.deferredNewOccurrenceOwners.remove(owner)
      }
      return .none
    case .failed(let failure):
      edit.status = .pending(write, .failed(failure))
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
    let failed = (state.conversationEdits[id] ?? [:]).compactMap { target, edit
      -> (target: ConversationWriteTarget, write: ConversationEdit.PendingWrite, revision: UInt64)? in
      guard target.operation == operation, case .pending(let write, .failed) = edit.status else { return nil }
      return (target, write, edit.revision)
    }.sorted { $0.revision < $1.revision }
    return .merge(failed.map { target, write, _ in
      let revision = state.nextConversationWriteRevision()
      let edit = ConversationEdit(revision: revision, status: .pending(write, .saving))
      state.conversationEdits[id]?[target] = edit
      return saveConversationEdit(conversationID: id, target: target, revision: revision, write: write)
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
      $0.key.operation == operation && !$0.value.isSaved
    }
  }

  var retryableConversationWriteOwners: Set<AppFeature.FailureOwner> {
    Set(conversationEdits.flatMap { id, edits in
      guard isConversationLive(id) else { return [AppFeature.FailureOwner]() }
      return edits.compactMap { target, edit in
        edit.isRetryable ? .conversationOperation(id, target.operation) : nil
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
