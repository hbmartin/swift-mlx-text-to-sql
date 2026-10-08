import CREGEngine
import ComposableArchitecture
import Foundation

extension AppFeature {
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
    case retry(conversationID: UUID, journalID: UUID, generation: Int)
  }

  public struct OwnedFailure: Equatable, Sendable {
    public var owner: FailureOwner
    public var failure: FailurePresentation
  }

  func bootstrapHistory(state: inout State) -> Effect<Action> {
    guard !state.historySummaryPhase.isLoading else { return .none }
    let requestID = state.nextHistoryRequestID()
    state.historySummaryPhase = .loading(requestID)
    state.historySummaryBaseline = Dictionary(uniqueKeysWithValues: state.conversations.map { ($0.id, $0) })
    return .run { send in
      do {
        await send(.bootstrapFinished(try await history.bootstrap(), requestID: requestID))
      } catch {
        await send(.historyBootstrapFailed(requestID,
          .history(operation: .summaryLoad, error: error), storeUnavailable: error is HistoryStoreUnavailableError))
      }
    }
  }

  func beginConversationCreation(state: inout State) -> Effect<Action> {
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
    if case .failed = historySummaryPhase { return true }
    return false
  }

  public var visibleFailures: [AppFeature.OwnedFailure] {
    failures.filter {
      switch $0.owner {
      case .global, .historySummaries: true
      case .conversationOpening(let requestID): conversationOpening?.requestID == requestID
      case .conversation(let id), .retry(let id, _, _): chat?.conversationID == id
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

  mutating func mergeHistorySummaries(_ summaries: [ConversationSummary]) {
    for summary in summaries {
      if conversationDeletions[summary.id]?.phase == .committed { continue }
      let current = conversations[id: summary.id]
      if current != historySummaryBaseline[summary.id] { continue }
      conversations[id: summary.id] = summary
    }
    conversations.sort { $0.lastActivityAt > $1.lastActivityAt }
    historySummaryBaseline = [:]
  }
}
