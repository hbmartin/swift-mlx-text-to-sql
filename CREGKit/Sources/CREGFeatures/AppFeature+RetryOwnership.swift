import CREGEngine
import ComposableArchitecture
import Foundation

extension AppFeature {
  public enum RetryClaimOutcome: Equatable, Sendable {
    case claimed(Int)
    case refused
    case failed(FailurePresentation)
  }
  public enum RetryInspectionResult: Equatable, Sendable {
    case missingJournal
    case trailingUnansweredUserTurn(InterruptedTurn)
    case nonTrailingInterruption(InterruptedTurn)
    case failed(FailurePresentation)
  }
  struct RetryInspectionID: Hashable { let journalID: UUID }

  /// User intent is independent of outstanding durable operations. Cancelling
  /// an effect never cancels ownership of a write which has already started.
  public enum RetryIntent: Equatable, Sendable {
    case idle, automatic, manual
    case cancelled(manualRequested: Bool)
    case dismissed
  }

  public enum RetryOperation: Equatable, Sendable {
    case claim(QueuedQuestion)
    case release(QueuedQuestion)
    case cancellation(QueuedQuestion)
    case decline(RetryDeclinePurpose)
    case cleanup
    case inspection(QueuedQuestion, generation: Int)
    case dismissal

    var holdsScheduler: Bool {
      switch self {
      case .dismissal: false
      default: true
      }
    }
    var isWrite: Bool {
      if case .inspection = self { return false }
      return true
    }
  }

  public struct RetryJournalState: Equatable, Sendable {
    public var conversationID: UUID
    public var interruption: InterruptedTurn?
    public var knownDurableCount: Int?
    public var intent: RetryIntent = .idle
    public var requestGeneration = 0
    public var dismissalRecovery: PendingInterruptedDismissal?
    public var dismissalIsSettled = false
    public var automaticCandidate: AutomaticRetryCandidate?
    public var operations: [UUID: RetryOperation] = [:]

    public init(conversationID: UUID, interruption: InterruptedTurn? = nil) {
      self.conversationID = conversationID
      self.interruption = interruption
      self.knownDurableCount = interruption?.autoRetryCount
    }
  }
}

extension AppFeature.State {
  public var automaticRetryCandidates: [UUID: AppFeature.AutomaticRetryCandidate] {
    retryJournals.compactMapValues(\.automaticCandidate)
  }
  mutating func installAutomaticCandidate(_ candidate: AppFeature.AutomaticRetryCandidate) {
    seedRetry(candidate.journalID, conversationID: candidate.conversationID)
    if retryJournals[candidate.journalID]?.knownDurableCount == nil {
      retryJournals[candidate.journalID]?.knownDurableCount = 0
    }
    retryJournals[candidate.journalID]?.automaticCandidate = candidate
  }
  mutating func removeAutomaticCandidate(_ journalID: UUID) {
    retryJournals[journalID]?.automaticCandidate = nil
  }
  public var retryOperationsHoldScheduler: Bool {
    retryJournals.values.contains { $0.operations.values.contains(where: \.holdsScheduler) }
  }

  // Read-only projections for presentation and diagnostics. Ownership can
  // only be changed in the journal registry, never through these views.
  public var retryClaimJournalID: UUID? {
    journalID { if case .claim = $0 { true } else { false } }
  }
  public var retryClaimConversationID: UUID? {
    retryClaimJournalID.flatMap { retryJournals[$0]?.conversationID }
  }
  public var retryClaimInFlight: Bool { retryClaimJournalID != nil }
  public var retryReleaseJournalID: UUID? {
    journalID {
      switch $0 {
      case .release, .cancellation: true
      default: false
      }
    }
  }
  public var retryReleaseConversationID: UUID? {
    retryReleaseJournalID.flatMap { retryJournals[$0]?.conversationID }
  }
  public var retryClaimCleanupJournalID: UUID? { journalID { $0 == .cleanup } }
  public var dismissedRetryJournalIDs: Set<UUID> {
    Set(retryJournals.filter { $0.value.intent == .dismissed }.keys)
  }
  public var cancelledRetryJournalIDs: Set<UUID> {
    Set(
      retryJournals.filter {
        if case .cancelled = $0.value.intent {
          true
        } else {
          $0.value.operations.values.contains { if case .cancellation = $0 { true } else { false } }
        }
      }.keys)
  }
  public var userPromotedRetryJournalIDs: Set<UUID> {
    Set(
      retryJournals.filter {
        $0.value.intent == .manual || $0.value.intent == .cancelled(manualRequested: true)
      }.keys)
  }
  public var pendingInterruptedDismissals: [UUID: AppFeature.PendingInterruptedDismissal] {
    retryJournals.compactMapValues { $0.dismissalIsSettled ? nil : $0.dismissalRecovery }
  }
  public var failedDismissalRecoveries: [UUID: AppFeature.PendingInterruptedDismissal] {
    retryJournals.compactMapValues { $0.dismissalIsSettled ? $0.dismissalRecovery : nil }
  }
  public var failedDismissalManualRetryIDs: Set<UUID> { Set(failedDismissalRecoveries.keys) }
  public var pendingRetryDeclines: [UUID: AppFeature.RetryDeclineWrites] {
    retryJournals.compactMapValues { journal in
      let purposes = journal.operations.compactMapValues {
        operation -> AppFeature.RetryDeclinePurpose? in
        if case .decline(let purpose) = operation { return purpose }
        return nil
      }
      return purposes.isEmpty
        ? nil
        : .init(
          conversationID: journal.conversationID, operationIDs: Set(purposes.keys),
          purposes: purposes)
    }
  }
  public var pendingRetryStaleChecks: [UUID: AppFeature.RetryStaleCheck] {
    retryJournals.compactMapValues { journal in
      guard
        let request = journal.operations.values.compactMap({ operation -> UUID? in
          if case .inspection(let queued, _) = operation { return queued.id }
          return nil
        }).first
      else { return nil }
      return .init(conversationID: journal.conversationID, requestID: request)
    }
  }

  func journalID(matching predicate: (AppFeature.RetryOperation) -> Bool) -> UUID? {
    retryJournals.keys.sorted { $0.uuidString < $1.uuidString }.first {
      retryJournals[$0]!.operations.values.contains(where: predicate)
    }
  }

  mutating func seedRetry(
    _ journalID: UUID, conversationID: UUID, interruption: InterruptedTurn? = nil
  ) {
    if retryJournals[journalID] == nil {
      retryJournals[journalID] = .init(conversationID: conversationID, interruption: interruption)
    } else if let interruption {
      retryJournals[journalID]?.interruption = interruption
      if retryJournals[journalID]?.knownDurableCount == nil {
        retryJournals[journalID]?.knownDurableCount = interruption.autoRetryCount
      }
    }
  }

  mutating func invalidateRetryInspection(_ journalID: UUID) {
    guard let journal = retryJournals[journalID] else { return }
    retryJournals[journalID]?.requestGeneration += 1
    retryJournals[journalID]?.operations = journal.operations.filter {
      if case .inspection = $0.value { return false }
      return true
    }
  }

  @discardableResult mutating func removeRetryPromotion(_ journalID: UUID) -> UUID? {
    guard userPromotedRetryJournalIDs.contains(journalID) else { return nil }
    let intent: AppFeature.RetryIntent =
      cancelledRetryJournalIDs.contains(journalID) ? .cancelled(manualRequested: false) : .idle
    retryJournals[journalID]?.intent = intent
    return journalID
  }
  @discardableResult mutating func removeRetryCancellation(_ journalID: UUID) -> UUID? {
    guard cancelledRetryJournalIDs.contains(journalID) else { return nil }
    let intent: AppFeature.RetryIntent =
      userPromotedRetryJournalIDs.contains(journalID) ? .manual : .idle
    retryJournals[journalID]?.intent = intent
    return journalID
  }
  mutating func promoteRetry(_ journalID: UUID) {
    let intent: AppFeature.RetryIntent =
      cancelledRetryJournalIDs.contains(journalID) ? .cancelled(manualRequested: true) : .manual
    retryJournals[journalID]?.intent = intent
  }

  mutating func removeRetryOperations(
    _ journalID: UUID, matching predicate: (AppFeature.RetryOperation) -> Bool
  ) {
    guard let journal = retryJournals[journalID] else { return }
    retryJournals[journalID]?.operations = journal.operations.filter { !predicate($0.value) }
  }

  mutating func clearFailedDismissal(_ journalID: UUID) -> Bool {
    guard retryJournals[journalID]?.dismissalIsSettled == true,
      retryJournals[journalID]?.dismissalRecovery != nil
    else { return false }
    retryJournals[journalID]?.dismissalRecovery = nil
    return true
  }
}
