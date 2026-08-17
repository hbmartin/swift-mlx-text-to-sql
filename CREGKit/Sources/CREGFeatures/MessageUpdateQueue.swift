import Foundation

actor MessageUpdateQueue {
  enum SaveOutcome: Equatable, Sendable {
    case saved
    case superseded
    case discardedDuringDeletion
  }

  private struct Key: Hashable {
    var conversationID: UUID
    var messageID: UUID
  }

  private enum OnceSaveState {
    case active(
      [CheckedContinuation<Result<SaveOutcome, any Error>, Never>]
    )
    case resolved(Result<SaveOutcome, any Error>)
  }

  /// Every history mutation in one conversation shares a FIFO. Message-level
  /// revisions still suppress stale preference effects, but distinct message
  /// IDs can no longer overtake each other in the durable transcript.
  private var activeConversationIDs: Set<UUID> = []
  private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
  private var latestRevisions: [Key: UInt64] = [:]
  private var onceSaves: [Key: OnceSaveState] = [:]
  /// Saves that arrive during deletion wait for its outcome. A failed delete
  /// resumes them; a confirmed delete permanently rejects late scheduled work.
  private var deletingConversationIDs: Set<UUID> = []
  private var deletedConversationIDs: Set<UUID> = []
  private var deletionResolutionWaiters: [UUID: [CheckedContinuation<Bool, Never>]] = [:]
  private var deletionDrainWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

  @discardableResult
  func save(
    conversationID: UUID,
    messageID: UUID,
    revision: UInt64? = nil,
    operation: @escaping @Sendable () async throws -> Void
  ) async throws -> SaveOutcome {
    let key = Key(conversationID: conversationID, messageID: messageID)
    guard await waitForDeletionResolutionIfNeeded(conversationID) else {
      return .discardedDuringDeletion
    }
    if let revision {
      guard revision > (latestRevisions[key] ?? 0) else { return .superseded }
      latestRevisions[key] = revision
    }

    while true {
      await acquire(conversationID)
      if deletedConversationIDs.contains(conversationID) {
        finish(conversationID)
        return .discardedDuringDeletion
      }
      guard deletingConversationIDs.contains(conversationID) else { break }
      finish(conversationID)
      guard await waitForDeletionResolutionIfNeeded(conversationID) else {
        return .discardedDuringDeletion
      }
      if let revision, revision < (latestRevisions[key] ?? 0) {
        return .superseded
      }
    }

    do {
      try await operation()
      finish(conversationID)
      return .saved
    } catch {
      finish(conversationID)
      guard await waitForDeletionResolutionIfNeeded(conversationID) else {
        return .discardedDuringDeletion
      }
      throw error
    }
  }

  /// Coalesces logically identical saves. Stop and the dispatch effect both
  /// use this for the user-message prerequisite, so whichever reaches the
  /// actor first performs the write and every other caller observes its exact
  /// outcome without retrying or overtaking it.
  @discardableResult
  func saveOnce(
    conversationID: UUID,
    messageID: UUID,
    operation: @escaping @Sendable () async throws -> Void
  ) async throws -> SaveOutcome {
    let key = Key(conversationID: conversationID, messageID: messageID)
    if let state = onceSaves[key] {
      let result: Result<SaveOutcome, any Error>
      switch state {
      case .resolved(let resolved):
        result = resolved
      case .active(var continuations):
        result = await withCheckedContinuation { continuation in
          continuations.append(continuation)
          onceSaves[key] = .active(continuations)
        }
      }
      return try result.get()
    }

    onceSaves[key] = .active([])
    let result: Result<SaveOutcome, any Error>
    do {
      result = .success(
        try await save(
          conversationID: conversationID,
          messageID: messageID,
          operation: operation))
    } catch {
      result = .failure(error)
    }
    resolveOnceSave(key, with: result)
    return try result.get()
  }

  func forgetOnceSave(conversationID: UUID, messageID: UUID) {
    let key = Key(conversationID: conversationID, messageID: messageID)
    guard case .resolved = onceSaves[key] else { return }
    onceSaves[key] = nil
  }

  func beginDeletingConversation(_ conversationID: UUID) async {
    deletingConversationIDs.insert(conversationID)
    guard activeConversationIDs.contains(conversationID) else {
      return
    }
    await withCheckedContinuation { continuation in
      deletionDrainWaiters[conversationID, default: []].append(continuation)
    }
  }

  /// Revision tombstones are needed while a message can still receive a late
  /// save, but a permanently deleted conversation can never be reconstructed
  /// under the same UUID. Keeping the deletion tombstone also prevents a save
  /// that reaches this actor after pruning from recreating revision state.
  func confirmConversationDeletion(_ conversationID: UUID) {
    deletingConversationIDs.remove(conversationID)
    deletedConversationIDs.insert(conversationID)
    latestRevisions = latestRevisions.filter {
      $0.key.conversationID != conversationID
    }
    // An active once-save can outlive the conversation FIFO while its owner
    // waits for deletion resolution. Retain it until `resolveOnceSave` resumes
    // every coalesced caller; resolved cache entries can be pruned immediately.
    onceSaves = onceSaves.filter {
      guard $0.key.conversationID == conversationID else { return true }
      if case .active = $0.value { return true }
      return false
    }
    resolveDeletionWaiters(conversationID, shouldSave: false)
  }

  func cancelConversationDeletion(_ conversationID: UUID) {
    deletingConversationIDs.remove(conversationID)
    resolveDeletionWaiters(conversationID, shouldSave: true)
  }

  func retainedRevisionCount() -> Int {
    latestRevisions.count
  }

  func onceSaveWaiterCount(conversationID: UUID, messageID: UUID) -> Int {
    let key = Key(conversationID: conversationID, messageID: messageID)
    guard case .active(let continuations) = onceSaves[key] else { return 0 }
    return continuations.count
  }

  func isDeletingConversation(_ conversationID: UUID) -> Bool {
    deletingConversationIDs.contains(conversationID)
  }

  private func acquire(_ conversationID: UUID) async {
    if activeConversationIDs.contains(conversationID) {
      await withCheckedContinuation { continuation in
        waiters[conversationID, default: []].append(continuation)
      }
    } else {
      activeConversationIDs.insert(conversationID)
    }
  }

  private func waitForDeletionResolutionIfNeeded(
    _ conversationID: UUID
  ) async -> Bool {
    if deletedConversationIDs.contains(conversationID) { return false }
    guard deletingConversationIDs.contains(conversationID) else { return true }
    return await withCheckedContinuation { continuation in
      deletionResolutionWaiters[conversationID, default: []].append(continuation)
    }
  }

  private func resolveDeletionWaiters(
    _ conversationID: UUID,
    shouldSave: Bool
  ) {
    let continuations =
      deletionResolutionWaiters.removeValue(
        forKey: conversationID) ?? []
    for continuation in continuations {
      continuation.resume(returning: shouldSave)
    }
  }

  private func resumeDeletionDrainIfReady(_ conversationID: UUID) {
    guard !activeConversationIDs.contains(conversationID) else {
      return
    }
    let continuations =
      deletionDrainWaiters.removeValue(
        forKey: conversationID) ?? []
    for continuation in continuations {
      continuation.resume()
    }
  }

  private func resolveOnceSave(
    _ key: Key,
    with result: Result<SaveOutcome, any Error>
  ) {
    let continuations: [CheckedContinuation<Result<SaveOutcome, any Error>, Never>]
    if case .active(let activeContinuations) = onceSaves[key] {
      continuations = activeContinuations
    } else {
      continuations = []
    }
    if deletedConversationIDs.contains(key.conversationID) {
      onceSaves[key] = nil
    } else {
      onceSaves[key] = .resolved(result)
    }
    for continuation in continuations {
      continuation.resume(returning: result)
    }
  }

  private func finish(_ conversationID: UUID) {
    guard var queued = waiters[conversationID], !queued.isEmpty else {
      activeConversationIDs.remove(conversationID)
      waiters[conversationID] = nil
      resumeDeletionDrainIfReady(conversationID)
      return
    }
    let next = queued.removeFirst()
    waiters[conversationID] = queued.isEmpty ? nil : queued
    next.resume()
  }
}

/// Reducers allocate revisions synchronously, before their effects can be
/// scheduled out of order. The process-wide counter also stays monotonic when
/// a conversation is unloaded and later reconstructed from history.
let resultPresentationSaveRevisionCounter = MessageUpdateRevisionCounter()

final class MessageUpdateRevisionCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value: UInt64 = 0

  func next() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    value &+= 1
    return value
  }
}
