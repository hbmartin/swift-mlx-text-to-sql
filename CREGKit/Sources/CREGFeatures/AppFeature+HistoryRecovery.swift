import CREGEngine
import ComposableArchitecture
import Foundation

extension AppFeature {
  public enum HistoryStoreAvailability: Equatable, Sendable {
    case unopened, available, unavailable
  }
  struct HistorySummaryTimeoutID: Hashable { var requestID: UInt64 }

  struct SummaryWrite: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
      case rename
      case unread(previous: Bool)
    }
    var conversationID: UUID
    var kind: Kind
  }
  public enum ConversationOperation: Equatable, Hashable, Sendable {
    case rename, export, feedback, draft, resultPresentation
  }
  public enum HistorySummaryPhase: Equatable, Sendable {
    case idle
    case loading(UInt64)
    case loaded
    case failed(UInt64)
    public var isLoading: Bool { if case .loading = self { true } else { false } }
  }

  public struct ConversationOpening: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
      case load(UUID)
      case create(UUID)
    }
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
    case conversationOperation(UUID, ConversationOperation)
    case turnPersistence(UUID)
    case retry(conversationID: UUID, journalID: UUID, generation: Int)
  }

  public struct OwnedFailure: Equatable, Sendable, Identifiable {
    public struct ID: Hashable, Sendable {
      public var owner: FailureOwner
      public var occurrence: UInt64
      var accessibilityToken: String {
        let scope: String
        switch owner {
        case .global: scope = "global"
        case .historySummaries(let request): scope = "history-\(request)"
        case .conversationOpening(let request): scope = "opening-\(request)"
        case .conversation(let id): scope = "conversation-\(id)"
        case .conversationOperation(let id, let operation): scope = "operation-\(id)-\(operation)"
        case .turnPersistence(let id): scope = "turn-\(id)"
        case .retry(let id, let journal, let generation): scope = "retry-\(id)-\(journal)-\(generation)"
        }
        return "\(scope)-\(occurrence)"
      }
    }
    public var owner: FailureOwner
    public var failure: FailurePresentation
    public var occurrence: UInt64 = 0
    public var id: ID { .init(owner: owner, occurrence: occurrence) }
  }

  func bootstrapHistory(state: inout State, restart: Bool = false) -> Effect<Action> {
    guard restart || !state.historySummaryPhase.isLoading else { return .none }
    let cancelWarning = cancelHistoryWarning(state: &state)
    state.clearSummaryFailures()
    state.slowHistoryRequestID = nil
    let requestID = state.nextHistoryRequestID()
    if state.chat != nil, state.historyStoreAvailability == .unopened {
      state.historyStoreAvailability = .available
    }
    state.historyLoadIsRetry = state.historySummaryPhase != .idle
    state.historySummaryPhase = .loading(requestID)
    state.historySummaryBaseline = Dictionary(
      uniqueKeysWithValues: state.conversations.map { ($0.id, $0) })
    state.historySummaryProtectedIDs = state.summaryProtectedConversationIDs
    let load = Effect<Action>.run { send in
      do {
        let summaries = try await history.bootstrap()
        guard !Task.isCancelled else { return }
        await send(.bootstrapFinished(summaries, requestID: requestID))
      } catch {
        guard !Task.isCancelled else { return }
        await send(
          .historyBootstrapFailed(
            requestID,
            .history(operation: .summaryLoad, error: error),
            storeUnavailable: error is HistoryStoreUnavailableError))
      }
    }.cancellable(id: CancelID.historySummaries, cancelInFlight: true)
    return .merge(cancelWarning, load, armHistoryWarning(state: &state))
  }

  func cancelHistoryWarning(state: inout State) -> Effect<Action> {
    state.historyWatchdogGeneration += 1
    guard case .loading(let requestID) = state.historySummaryPhase else { return .none }
    return .cancel(id: HistorySummaryTimeoutID(requestID: requestID))
  }

  func armHistoryWarning(state: inout State) -> Effect<Action> {
    guard state.isSceneActive, case .loading(let requestID) = state.historySummaryPhase,
      state.slowHistoryRequestID != requestID
    else { return .none }
    state.historyWatchdogGeneration += 1
    let generation = state.historyWatchdogGeneration
    return .run { send in
      try await clock.sleep(for: .seconds(5))
      await send(.historySummaryTimedOut(requestID, generation: generation))
    }.cancellable(id: HistorySummaryTimeoutID(requestID: requestID), cancelInFlight: true)
  }

  func setConversationUnread(state: inout State, id: UUID, unread: Bool) -> Effect<Action> {
    let previous = state.conversations[id: id]?.isUnread ?? false
    let operationID = uuid()
    state.conversations[id: id]?.isUnread = unread
    state.unreadMutationOwners[id] = operationID
    state.summaryWrites[operationID] = .init(conversationID: id, kind: .unread(previous: previous))
    return .run { send in
      do {
        try await history.setUnread(id, unread)
        await send(.summaryWriteSettled(operationID, nil))
      } catch {
        await send(
          .summaryWriteSettled(operationID, .history(operation: .messageSave, error: error)))
      }
    }
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
          await send(
            .conversationCreated(
              try await history.createConversation(id, startedAt), requestID: requestID))
        } catch {
          await send(
            .conversationOpeningFailed(
              requestID, .history(operation: .conversationCreate, error: error)))
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
    diagnostics.record(
      DiagnosticEvent(
        level: .error, category: .history,
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
    if slowHistoryRequestID != nil { return true }
    if failures.contains(where: { $0.failure.recovery == .retryHistory }) { return true }
    if case .failed = historySummaryPhase { return true }
    return false
  }

  public var visibleFailures: [AppFeature.OwnedFailure] {
    failures.filter {
      switch $0.owner {
      case .global, .historySummaries: true
      case .conversationOpening(let requestID): conversationOpening?.requestID == requestID
      case .conversation(let id), .conversationOperation(let id, _):
        chat?.conversationID == id && isConversationLive(id)
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
      if let newValue {
        storeFailure(newValue, owner: .global)
      } else if let owner = visibleFailures.last?.owner {
        failures.removeAll { $0.owner == owner }
      }
    }
  }

  mutating func storeFailure(_ failure: FailurePresentation, owner: AppFeature.FailureOwner,
    newOccurrence: Bool = false
  ) {
    if !newOccurrence, failures.contains(where: { $0.owner == owner && $0.failure == failure }) { return }
    failureOccurrenceSequence += 1
    failures.removeAll { $0.owner == owner }
    failures.append(.init(owner: owner, failure: failure, occurrence: failureOccurrenceSequence))
  }

  mutating func markHistoryStoreAvailable() {
    historyStoreAvailability = .available
    let protected = Set(failures.filter { hasOutstandingConversationWrites(owner: $0.owner) }.map(\.owner))
    failures.removeAll { $0.failure.cause == .historyStoreUnavailable
      && !protected.contains($0.owner) }
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
    var ids = Set(summaryWrites.values.map(\.conversationID))
    ids.formUnion(conversationCreations.values)
    ids.formUnion(queue.map(\.conversationID))
    for id in [
      activeTurn?.conversationID, pendingTurnPersistence?.conversationID,
      pendingInterruptedTurn?.conversationID,
    ].compactMap({ $0 }) { ids.insert(id) }
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
          || current.suggestionGeneration > summary.suggestionGeneration
        {
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
