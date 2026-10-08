import CREGEngine
import ComposableArchitecture
import Foundation

extension AppFeature {
  public enum HistoryStoreAvailability: Equatable, Sendable { case unopened, available, unavailable }
  struct HistorySummaryTimeoutID: Hashable { var requestID: UInt64 }
  public enum HistorySummaryPhase: Equatable, Sendable {
    case idle, loading(UInt64), loaded, failed(UInt64)
    public var isLoading: Bool { if case .loading = self { true } else { false } }
  }

  public struct ConversationOpening: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case load(UUID), create(UUID) }
    public enum Phase: Equatable, Sendable { case loading, failed }
    public var requestID: UInt64
    public var kind: Kind
    public var phase: Phase = .loading
  }

  public enum FailureOwner: Equatable, Hashable, Sendable {
    case global
    case historySummaries(UInt64)
    case conversationOpening(UInt64)
    case conversation(UUID)
    case turnPersistence(UUID)
    case retry(conversationID: UUID, journalID: UUID, generation: Int)
  }

  public struct OwnedFailure: Equatable, Sendable {
    public var owner: FailureOwner
    public var failure: FailurePresentation
  }

  func bootstrapHistory(state: inout State) -> Effect<Action> {
    guard !state.historySummaryPhase.isLoading else { return .none }
    let requestID = state.nextHistoryRequestID()
    if state.chat != nil, state.historyStoreAvailability == .unopened {
      state.historyStoreAvailability = .available
    }
    state.historyLoadIsRetry = state.historySummaryPhase != .idle
    state.historySummaryPhase = .loading(requestID)
    state.historySummaryBaseline = Dictionary(uniqueKeysWithValues: state.conversations.map { ($0.id, $0) })
    state.historySummaryProtectedIDs = state.summaryProtectedConversationIDs
    let load = Effect<Action>.run { send in
      do {
        let summaries = try await history.bootstrap()
        guard !Task.isCancelled else { return }
        await send(.bootstrapFinished(summaries, requestID: requestID))
      } catch {
        guard !Task.isCancelled else { return }
        await send(.historyBootstrapFailed(requestID,
          .history(operation: .summaryLoad, error: error), storeUnavailable: error is HistoryStoreUnavailableError))
      }
    }.cancellable(id: CancelID.historySummaries, cancelInFlight: true)
    return .merge(load, .run { send in
      try await clock.sleep(for: .seconds(5))
      await send(.historySummaryTimedOut(requestID))
    }.cancellable(id: HistorySummaryTimeoutID(requestID: requestID)))
  }

  func beginConversationCreation(state: inout State) -> Effect<Action> {
    state.closeConversationPresentation()
    guard !state.historyStoreUnavailable else { return .none }
    if let creation = state.conversationCreationInFlight {
      state.clearOpeningFailures()
      state.conversationOpening = creation
      state.newChatRequestedDuringBootstrap = false
      return .cancel(id: CancelID.conversationLoad)
    }
    let requestID = state.nextHistoryRequestID()
    let id = uuid()
    state.clearOpeningFailures()
    state.conversationOpening = .init(requestID: requestID, kind: .create(id))
    state.conversationCreationInFlight = state.conversationOpening
    state.conversationCreations[requestID] = id
    state.newChatRequestedDuringBootstrap = false
    let startedAt = now
    return .merge(
      .cancel(id: CancelID.conversationLoad),
      .run { send in
        do {
          await send(.conversationCreated(try await history.createConversation(id, startedAt), requestID: requestID))
        } catch {
          await send(.conversationOpeningFailed(requestID, .history(operation: .conversationCreate, error: error)))
        }
      })
  }

  func beginConversationLoad(state: inout State, id: UUID) -> Effect<Action> {
    state.closeConversationPresentation()
    if state.historyStoreAvailability == .unopened { state.historyStoreAvailability = .available }
    let requestID = state.nextHistoryRequestID()
    state.newChatRequestedDuringBootstrap = false
    state.clearOpeningFailures()
    state.conversationOpening = .init(requestID: requestID, kind: .load(id))
    return .run { send in
      do {
        let snapshot = try await history.loadConversation(id)
        guard !Task.isCancelled else { return }
        await send(.conversationLoaded(snapshot, requestID: requestID))
      } catch {
        guard !Task.isCancelled else { return }
        await send(.conversationOpeningFailed(requestID, .history(operation: .load, error: error)))
      }
    }.cancellable(id: CancelID.conversationLoad, cancelInFlight: true)
  }

  func recordFailure(_ failure: FailurePresentation) {
    diagnostics.record(DiagnosticEvent(level: .error, category: .history,
      code: failure.code, summary: failure.title, details: failure.diagnostic))
  }
}

extension AppFeature.State {
  mutating func nextHistoryRequestID() -> UInt64 {
    historyRequestSequence += 1
    return historyRequestSequence
  }

  /// Correlates deletion and retry events within this root store's lifetime.
  /// These numbers share one counter, are never persisted, and carry no user
  /// or database identity. UUID redaction remains enabled independently.
  mutating func nextDiagnosticOperationNumber() -> UInt64 {
    diagnosticOperationSequence += 1
    return diagnosticOperationSequence
  }

  public var isOpeningConversation: Bool {
    conversationOpening?.phase == .loading
      || (chat == nil && historySummaryPhase.isLoading)
  }

  public var canCreateConversation: Bool { !historyStoreUnavailable }
  public var canRetryHistory: Bool {
    if failures.contains(where: { $0.failure.recovery == .retryHistory }) { return true }
    if case .failed = historySummaryPhase { return true }
    return false
  }

  public var visibleFailures: [AppFeature.OwnedFailure] {
    failures.filter {
      switch $0.owner {
      case .global, .historySummaries: true
      case .conversationOpening(let requestID): conversationOpening?.requestID == requestID
      case .conversation(let id): chat?.conversationID == id && isConversationLive(id)
      case .turnPersistence(let questionID): pendingTurnPersistence?.questionID == questionID
      case .retry(let id, let journalID, let generation):
        chat?.conversationID == id && isConversationLive(id)
          && retryJournals[journalID]?.requestGeneration == generation
          && !dismissedRetryJournalIDs.contains(journalID)
      }
    }
  }

  /// Compatibility for generic failures and existing callers. Scoped failures
  /// are stored independently, so another operation cannot overwrite them.
  public var presentedFailure: FailurePresentation? {
    get { visibleFailures.last?.failure }
    set {
      if let newValue { storeFailure(newValue, owner: .global) }
      else if let owner = visibleFailures.last?.owner { failures.removeAll { $0.owner == owner } }
    }
  }

  mutating func storeFailure(_ failure: FailurePresentation, owner: AppFeature.FailureOwner) {
    failures.removeAll { $0.owner == owner }
    failures.append(.init(owner: owner, failure: failure))
  }

  mutating func clearSummaryFailures() {
    failures.removeAll { if case .historySummaries = $0.owner { true } else { false } }
  }

  mutating func clearOpeningFailures() {
    failures.removeAll { if case .conversationOpening = $0.owner { true } else { false } }
  }

  mutating func clearRetryFailures(_ journalID: UUID) {
    failures.removeAll {
      if case .retry(_, let id, _) = $0.owner { return id == journalID }
      return false
    }
  }

  var summaryProtectedConversationIDs: Set<UUID> {
    var ids = Set(summaryWrites.values)
    ids.formUnion(conversationCreations.values)
    ids.formUnion(queue.map(\.conversationID))
    for id in [activeTurn?.conversationID, pendingTurnPersistence?.conversationID,
      pendingInterruptedTurn?.conversationID].compactMap({ $0 }) { ids.insert(id) }
    for journal in retryJournals.values where journal.operations.values.contains(where: \.isWrite) {
      ids.insert(journal.conversationID)
    }
    return ids
  }

  mutating func mergeHistorySummaries(_ summaries: [ConversationSummary]) {
    var merged = conversations
    let protected = historySummaryProtectedIDs.union(summaryProtectedConversationIDs)
    for summary in summaries {
      if conversationDeletions[summary.id]?.phase == .committed { continue }
      let current = merged[id: summary.id]
      var next = summary
      if let current {
        if current != historySummaryBaseline[summary.id] || protected.contains(summary.id)
          || current.suggestionGeneration > summary.suggestionGeneration {
          next = current
        }
        next.suggestionGeneration = max(current.suggestionGeneration, summary.suggestionGeneration)
      }
      merged[id: summary.id] = next
    }
    merged.sort { $0.lastActivityAt > $1.lastActivityAt }
    conversations = merged
    historySummaryBaseline = [:]
    historySummaryProtectedIDs = []
  }
}
