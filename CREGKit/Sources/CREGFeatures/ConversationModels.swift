import CREGEngine
import Foundation

/// One row in the Conversation Browser: enough to render the Recents list
/// without loading transcripts (CONTEXT.md "Conversation Browser").
public struct ConversationSummary: Identifiable, Equatable, Sendable, Codable {
  public var id: UUID
  public var title: String
  /// Manual rename wins over the first-question auto-title thereafter.
  public var isManuallyTitled: Bool
  public var startedAt: Date
  public var lastActivityAt: Date
  /// Plain-text preview of the latest message (narration for answers).
  public var latestMessagePreview: String
  /// A background completion the user has not opened yet.
  public var isUnread: Bool
  public var messageCount: Int
  /// The durable suggestion generation: advanced by every accepted question,
  /// and the identity a prepared batch must match to be saved or shown.
  public var suggestionGeneration: Int

  public init(
    id: UUID,
    title: String,
    isManuallyTitled: Bool = false,
    startedAt: Date,
    lastActivityAt: Date,
    latestMessagePreview: String = "",
    isUnread: Bool = false,
    messageCount: Int = 0,
    suggestionGeneration: Int = 0
  ) {
    self.id = id
    self.title = title
    self.isManuallyTitled = isManuallyTitled
    self.startedAt = startedAt
    self.lastActivityAt = lastActivityAt
    self.latestMessagePreview = latestMessagePreview
    self.isUnread = isUnread
    self.messageCount = messageCount
    self.suggestionGeneration = suggestionGeneration
  }

  private enum CodingKeys: String, CodingKey {
    case id, title, isManuallyTitled, startedAt, lastActivityAt,
      latestMessagePreview, isUnread, messageCount, suggestionGeneration
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try values.decode(UUID.self, forKey: .id),
      title: try values.decode(String.self, forKey: .title),
      isManuallyTitled: try values.decodeIfPresent(
        Bool.self, forKey: .isManuallyTitled) ?? false,
      startedAt: try values.decode(Date.self, forKey: .startedAt),
      lastActivityAt: try values.decode(Date.self, forKey: .lastActivityAt),
      latestMessagePreview: try values.decodeIfPresent(
        String.self, forKey: .latestMessagePreview) ?? "",
      isUnread: try values.decodeIfPresent(Bool.self, forKey: .isUnread)
        ?? false,
      messageCount: try values.decodeIfPresent(Int.self, forKey: .messageCount)
        ?? 0,
      suggestionGeneration: try values.decodeIfPresent(
        Int.self, forKey: .suggestionGeneration) ?? 0)
  }

  /// Untitled conversations render as "New Chat" everywhere.
  public var displayTitle: String {
    title.isEmpty ? "New Chat" : title
  }
}

/// A journaled turn that did not reach a terminal transcript write. Known
/// lifecycle interruptions may auto-retry once; ambiguous or exhausted
/// entries remain behind the explicit Ask Again affordance.
public struct InterruptedTurn: Equatable, Sendable, Codable {
  public enum Status: String, Equatable, Sendable, Codable {
    case running
    case knownInterruption = "known_interruption"
    case ambiguousInterruption = "ambiguous_interruption"
    case manualRetryRequired = "manual_retry_required"
  }

  public var question: String
  public var journalID: UUID?
  public var source: QuestionSubmissionSource
  public var interruptedAt: Date
  /// The durable execution/user-message ID. Older journals lack it and are
  /// matched to the trailing unanswered user message when loaded.
  public var executionID: UUID?
  public var status: Status
  public var autoRetryCount: Int

  public var canAutoRetry: Bool {
    status == .knownInterruption && autoRetryCount == 0
  }

  public init(
    question: String, interruptedAt: Date,
    journalID: UUID? = nil,
    source: QuestionSubmissionSource = .freeForm,
    executionID: UUID? = nil,
    status: Status = .running,
    autoRetryCount: Int = 0
  ) {
    self.question = question
    self.journalID = journalID
    self.source = source
    self.interruptedAt = interruptedAt
    self.executionID = executionID
    self.status = status
    self.autoRetryCount = autoRetryCount
  }

  private enum CodingKeys: String, CodingKey {
    case question, journalID, source, interruptedAt, executionID, status,
      autoRetryCount
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    question = try values.decode(String.self, forKey: .question)
    journalID = try values.decodeIfPresent(UUID.self, forKey: .journalID)
    source = try values.decodeIfPresent(QuestionSubmissionSource.self, forKey: .source)
      ?? .freeForm
    interruptedAt = try values.decode(Date.self, forKey: .interruptedAt)
    executionID = try values.decodeIfPresent(UUID.self, forKey: .executionID)
    status = try values.decode(Status.self, forKey: .status)
    autoRetryCount = try values.decode(Int.self, forKey: .autoRetryCount)
  }
}

/// The complete persisted state of one Conversation, loaded on selection.
public struct ConversationSnapshot: Equatable, Sendable {
  public var summary: ConversationSummary
  public var draft: String
  public var messages: [ChatMessage]
  /// Feedback keyed by the assistant message it judges.
  public var feedback: [UUID: AnswerFeedback]
  public var interruptedTurns: [InterruptedTurn]
  public var interruptedTurn: InterruptedTurn? { interruptedTurns.first }
  public var followUpBatch: PreparedFollowUpBatch?
  /// Mirrors `summary.suggestionGeneration`; the batch above, when present,
  /// already matched it and the latest persisted message at load time.
  public var suggestionGeneration: Int { summary.suggestionGeneration }

  public init(
    summary: ConversationSummary,
    draft: String = "",
    messages: [ChatMessage] = [],
    feedback: [UUID: AnswerFeedback] = [:],
    interruptedTurn: InterruptedTurn? = nil,
    interruptedTurns: [InterruptedTurn] = [],
    followUpBatch: PreparedFollowUpBatch? = nil
  ) {
    self.summary = summary
    self.draft = draft
    self.messages = messages
    self.feedback = feedback
    self.interruptedTurns = interruptedTurns.isEmpty
      ? interruptedTurn.map { [$0] } ?? [] : interruptedTurns
    self.followUpBatch = followUpBatch
  }
}

struct RecoveredPreparedAnswer: Sendable {
  let message: ChatMessage
  let question: String
  let precedingUserMessageID: UUID?
}

extension ConversationSnapshot {
  func recoveredPreparedAnswers(excluding preservedMessageID: UUID? = nil)
    -> [RecoveredPreparedAnswer]
  {
    messages.enumerated().compactMap { index, message in
      guard message.id != preservedMessageID,
        case .preparedAnswer(let prepared) = message.body,
        let finalized = message.finalizedInterruptedPreparedAnswer
      else { return nil }
      let precedingUserID: UUID?
      if index > 0, messages[index - 1].role == .user {
        precedingUserID = messages[index - 1].id
      } else {
        precedingUserID = nil
      }
      return RecoveredPreparedAnswer(
        message: finalized,
        question: prepared.question,
        precedingUserMessageID: precedingUserID)
    }
  }
}

/// The execution contract carried from submission through the global queue.
/// Only a tapped prepared follow-up contains cached SQL and result data.
public enum QuestionSubmissionSource: Equatable, Sendable, Codable {
  case freeForm
  case starter(StarterQueryID)
  case preparedFollowUp(PreparedFollowUp)
}

public struct QuestionSubmission: Equatable, Sendable, Codable {
  public var question: String
  public var source: QuestionSubmissionSource
  public var originConversationID: UUID?
  public var clearsComposerOnAcceptance: Bool?

  public init(
    question: String,
    source: QuestionSubmissionSource = .freeForm,
    originConversationID: UUID? = nil,
    clearsComposerOnAcceptance: Bool? = nil
  ) {
    self.question = question
    self.source = source
    self.originConversationID = originConversationID
    self.clearsComposerOnAcceptance = clearsComposerOnAcceptance
  }
}

/// One local full-text search match over titles, user questions, and
/// assistant narrations only — never SQL, rows, or diagnostics.
public struct ConversationSearchHit: Identifiable, Equatable, Sendable {
  public var id: UUID { conversationID }
  public var conversationID: UUID
  public var title: String
  /// The matched excerpt with FTS highlight markers stripped.
  public var snippet: String
  public var lastActivityAt: Date

  public init(
    conversationID: UUID,
    title: String,
    snippet: String,
    lastActivityAt: Date
  ) {
    self.conversationID = conversationID
    self.title = title
    self.snippet = snippet
    self.lastActivityAt = lastActivityAt
  }
}

/// A submitted question waiting for the single global pipeline. Queued
/// Questions live only in the current process (ADR 0008).
public struct QueuedQuestion: Identifiable, Equatable, Sendable {
  public var id: UUID
  public var conversationID: UUID
  public var submission: QuestionSubmission
  public var retryJournalID: UUID?
  public var existingUserMessage: ChatMessage?
  public var automaticRetry: Bool = false
  /// Ownership assigned when a new question is accepted, before it queues.
  /// Retries without a new submission acquire ownership at dispatch instead.
  public var suggestionGeneration: Int?
  public var question: String { submission.question }
  public var starter: StarterQueryID? {
    guard case .starter(let starter) = submission.source else { return nil }
    return starter
  }
  public var submittedAt: Date

  public init(
    id: UUID,
    conversationID: UUID,
    question: String,
    starter: StarterQueryID? = nil,
    submittedAt: Date
  ) {
    self.id = id
    self.conversationID = conversationID
    self.submission = QuestionSubmission(
      question: question,
      source: starter.map(QuestionSubmissionSource.starter) ?? .freeForm)
    self.retryJournalID = nil
    self.existingUserMessage = nil
    self.automaticRetry = false
    self.suggestionGeneration = nil
    self.submittedAt = submittedAt
  }

  public init(
    id: UUID,
    conversationID: UUID,
    submission: QuestionSubmission,
    retryJournalID: UUID? = nil,
    existingUserMessage: ChatMessage? = nil,
    automaticRetry: Bool = false,
    suggestionGeneration: Int? = nil,
    submittedAt: Date
  ) {
    self.id = id
    self.conversationID = conversationID
    self.submission = submission
    self.retryJournalID = retryJournalID
    self.existingUserMessage = existingUserMessage
    self.automaticRetry = automaticRetry
    self.suggestionGeneration = suggestionGeneration
    self.submittedAt = submittedAt
  }
}

/// A user's reversible Helpful / Not right judgment on one completed answer,
/// optionally followed by correction context (CONTEXT.md "Answer Feedback").
public struct AnswerFeedback: Equatable, Sendable, Codable {
  public enum Verdict: String, Equatable, Sendable, Codable {
    case helpful
    case notRight = "not_right"
  }

  public var messageID: UUID
  public var verdict: Verdict
  /// The eventual correction the user sent after a Not right judgment.
  public var correction: String?
  public var updatedAt: Date
  public var runtimeMode: ModelRuntimeMode
  public var isEvaluated: Bool

  public init(
    messageID: UUID,
    verdict: Verdict,
    correction: String? = nil,
    updatedAt: Date,
    runtimeMode: ModelRuntimeMode = .evaluated,
    isEvaluated: Bool? = nil
  ) {
    self.messageID = messageID
    self.verdict = verdict
    self.correction = correction
    self.updatedAt = updatedAt
    self.runtimeMode = runtimeMode
    self.isEvaluated = isEvaluated ?? runtimeMode.isEvaluated
  }

  private enum CodingKeys: String, CodingKey {
    case messageID
    case verdict
    case correction
    case updatedAt
    case runtimeMode
    case isEvaluated
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    messageID = try values.decode(UUID.self, forKey: .messageID)
    verdict = try values.decode(Verdict.self, forKey: .verdict)
    correction = try values.decodeIfPresent(String.self, forKey: .correction)
    updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    runtimeMode =
      try values.decodeIfPresent(ModelRuntimeMode.self, forKey: .runtimeMode)
      ?? .evaluated
    isEvaluated =
      try values.decodeIfPresent(Bool.self, forKey: .isEvaluated)
      ?? runtimeMode.isEvaluated
  }
}

/// The reviewable table of contents inside a Support Bundle: what was
/// included, what was deliberately excluded, and the hashes that stand in
/// for the excluded artifacts (CONTEXT.md "Support Bundle").
public struct SupportBundleManifest: Equatable, Sendable, Codable {
  public struct Entry: Equatable, Sendable, Codable {
    public var path: String
    public var byteCount: Int
    public var sha256: String

    public init(path: String, byteCount: Int, sha256: String) {
      self.path = path
      self.byteCount = byteCount
      self.sha256 = sha256
    }
  }

  public struct Exclusion: Equatable, Sendable, Codable {
    public var name: String
    public var reason: String
    /// Content hash or receipt standing in for the excluded artifact.
    public var sha256: String?

    public init(name: String, reason: String, sha256: String? = nil) {
      self.name = name
      self.reason = reason
      self.sha256 = sha256
    }
  }

  public var createdAt: Date
  public var appVersion: String
  public var buildNumber: String
  public var buildChannel: String
  public var modelRuntimeContractVersion: Int?
  public var sourceRevision: String?
  public var sourceDirty: Bool?
  public var modelKey: String
  public var modelRevision: String
  public var runtimeMode: ModelRuntimeMode
  public var isEvaluated: Bool
  public var conversationCount: Int
  public var messageCount: Int
  public var eventLineCount: Int
  public var feedbackCount: Int
  public var entries: [Entry]
  public var exclusions: [Exclusion]

  public init(
    createdAt: Date,
    appVersion: String,
    buildNumber: String,
    buildChannel: String = "unknown",
    modelRuntimeContractVersion: Int? = nil,
    sourceRevision: String? = nil,
    sourceDirty: Bool? = nil,
    modelKey: String,
    modelRevision: String,
    runtimeMode: ModelRuntimeMode = .evaluated,
    isEvaluated: Bool? = nil,
    conversationCount: Int,
    messageCount: Int,
    eventLineCount: Int,
    feedbackCount: Int,
    entries: [Entry] = [],
    exclusions: [Exclusion] = []
  ) {
    self.createdAt = createdAt
    self.appVersion = appVersion
    self.buildNumber = buildNumber
    self.buildChannel = buildChannel
    self.modelRuntimeContractVersion = modelRuntimeContractVersion
    self.sourceRevision = sourceRevision
    self.sourceDirty = sourceDirty
    self.modelKey = modelKey
    self.modelRevision = modelRevision
    self.runtimeMode = runtimeMode
    self.isEvaluated = isEvaluated ?? runtimeMode.isEvaluated
    self.conversationCount = conversationCount
    self.messageCount = messageCount
    self.eventLineCount = eventLineCount
    self.feedbackCount = feedbackCount
    self.entries = entries
    self.exclusions = exclusions
  }
}

extension ChatMessage {
  /// The plain-text line shown in Recents previews and used as the
  /// first-question auto-title source.
  public var previewText: String {
    switch body {
    case .text(let text), .clarification(let text), .failure(let text):
      text
    case .failedTurn(let reason, _):
      FailurePresentation.turnFailure(reason).message
    case .preparedAnswer(let prepared):
      "Result ready — summarizing \(prepared.result.rowCount) row\(prepared.result.rowCount == 1 ? "" : "s")…"
    case .answer(_, let narration, _, _):
      narration
    }
  }
}
