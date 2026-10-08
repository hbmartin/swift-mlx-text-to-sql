import CREGCore
import CREGEngine
import ComposableArchitecture
import Foundation

extension AppFeature {
  public enum DeletionPhase: Equatable, Sendable {
    case undoWindow, awaitingSettlement, committing, committed
  }

  public struct ConversationDeletion: Equatable, Sendable {
    public var token: UUID
    public var summary: ConversationSummary
    public var phase: DeletionPhase = .undoWindow
    public var deferredFailures: [FailurePresentation] = []
    public var diagnosticOperationNumber: UInt64 = 0
    public init(token: UUID, summary: ConversationSummary) {
      self.token = token
      self.summary = summary
    }
  }

  struct DeletionCountdownID: Hashable { let token: UUID }
}

extension AppFeature.State {
  struct SchedulerReconciliation: Equatable {
    var selectedID: UUID?
    var gateHeld: Bool
    var runnableIDs: [UUID]
    var candidateIDs: Set<UUID>
    var contextGenerations: [UUID: Int]
    var deletionPhases: [UUID: AppFeature.DeletionPhase]
    var readyDeletionIDs: Set<UUID>
    var readiness: AppFeature.ModelReadiness
    var sceneActive: Bool
  }
  var schedulerReconciliation: SchedulerReconciliation {
    .init(
      selectedID: chat?.conversationID,
      gateHeld: activeTurn != nil || pendingInterruptedTurn != nil || pendingTurnPersistence != nil
        || retryOperationsHoldScheduler,
      runnableIDs: runnableQueue.map(\.id), candidateIDs: Set(automaticRetryCandidates.keys),
      contextGenerations: pendingSuggestionContexts.mapValues(\.generation),
      deletionPhases: conversationDeletions.mapValues(\.phase),
      readyDeletionIDs: Set(conversationDeletions.compactMap { id, deletion in
        deletion.phase == .awaitingSettlement && !hasOutstandingWrites(in: id) ? id : nil
      }), readiness: modelReadiness,
      sceneActive: isSceneActive)
  }
  public var pendingDeletion: AppFeature.ConversationDeletion? {
    undoDeletionID.flatMap { conversationDeletions[$0] }.flatMap {
      $0.phase == .undoWindow ? $0 : nil
    }
  }
  public var visibleConversations: IdentifiedArrayOf<ConversationSummary> {
    IdentifiedArray(uniqueElements: conversations.filter { isConversationLive($0.id) })
  }
  public func isConversationLive(_ id: UUID) -> Bool {
    conversations[id: id] != nil && conversationDeletions[id] == nil
  }
  public func isConversationPendingDeletion(_ id: UUID) -> Bool {
    guard let deletion = conversationDeletions[id] else { return false }
    return deletion.phase != .committed
  }
  public var runnableQueue: [QueuedQuestion] {
    queue.filter { isConversationLive($0.conversationID) }
  }
  public var visibleSearchHits: [ConversationSearchHit] {
    searchHits.filter { isConversationLive($0.conversationID) }
  }
  public func hasOutstandingWrites(in id: UUID) -> Bool {
    pendingTurnPersistence?.conversationID == id || pendingInterruptedTurn?.conversationID == id
      || activeTurn?.conversationID == id
      || retryJournals.values.contains {
        $0.conversationID == id && $0.operations.values.contains(where: \.isWrite)
      }
  }
}
