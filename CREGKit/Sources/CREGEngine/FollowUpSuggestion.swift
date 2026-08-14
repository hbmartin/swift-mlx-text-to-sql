import CryptoKit
import Foundation

/// The single completed exchange used to propose the next questions. Older
/// conversation turns are deliberately excluded so suggestions stay local to
/// the answer the user is looking at.
public struct FollowUpSuggestionContext: Sendable, Equatable, Codable {
  public var sourceAssistantMessageID: UUID
  public var question: String
  public var standaloneQuestion: String
  public var narration: String
  public var result: QueryResult

  public init(
    sourceAssistantMessageID: UUID,
    question: String,
    standaloneQuestion: String,
    narration: String,
    result: QueryResult
  ) {
    self.sourceAssistantMessageID = sourceAssistantMessageID
    self.question = question
    self.standaloneQuestion = standaloneQuestion
    self.narration = narration
    self.result = result
  }
}

/// Versioned evidence that a prepared question, SQL statement, and cached
/// result were produced by the currently bundled model and portfolio data.
public struct PreparedQueryProvenance: Sendable, Equatable, Codable {
  public static let currentSchemaVersion = 3

  public var schemaVersion: Int
  public var modelKey: String
  public var modelRevision: String
  public var runtimeMode: ModelRuntimeMode
  public var preparationPolicyVersion: String
  public var databaseFingerprint: String
  public var sqlFingerprint: String
  public var resultFingerprint: String

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    modelKey: String,
    modelRevision: String,
    runtimeMode: ModelRuntimeMode,
    preparationPolicyVersion: String,
    databaseFingerprint: String,
    sqlFingerprint: String,
    resultFingerprint: String
  ) {
    self.schemaVersion = schemaVersion
    self.modelKey = modelKey
    self.modelRevision = modelRevision
    self.runtimeMode = runtimeMode
    self.preparationPolicyVersion = preparationPolicyVersion
    self.databaseFingerprint = databaseFingerprint
    self.sqlFingerprint = sqlFingerprint
    self.resultFingerprint = resultFingerprint
  }
}

/// A follow-up whose SQL has already been generated, repaired if necessary,
/// validated, executed, and grounded. The result may be rendered before the
/// on-tap narration call finishes.
public struct PreparedFollowUp: Identifiable, Sendable, Equatable, Codable {
  public var id: UUID
  public var sourceAssistantMessageID: UUID
  public var rank: Int
  public var question: String
  public var sql: String
  public var result: QueryResult
  public var preparationTelemetry: TurnTelemetry
  public var provenance: PreparedQueryProvenance
  public var createdAt: Date

  public init(
    id: UUID,
    sourceAssistantMessageID: UUID,
    rank: Int,
    question: String,
    sql: String,
    result: QueryResult,
    preparationTelemetry: TurnTelemetry,
    provenance: PreparedQueryProvenance,
    createdAt: Date
  ) {
    self.id = id
    self.sourceAssistantMessageID = sourceAssistantMessageID
    self.rank = rank
    self.question = question
    self.sql = sql
    self.result = result
    self.preparationTelemetry = preparationTelemetry
    self.provenance = provenance
    self.createdAt = createdAt
  }
}

/// The latest answer's persisted, progressively populated suggestion batch.
public struct PreparedFollowUpBatch: Sendable, Equatable, Codable {
  public static let maximumSuggestionCount = 3

  public enum Status: String, Sendable, Equatable, Codable {
    case preparing
    case completed
  }

  public var sourceAssistantMessageID: UUID
  public var context: FollowUpSuggestionContext?
  public var status: Status
  public var suggestions: [PreparedFollowUp]
  public var updatedAt: Date

  public init(
    sourceAssistantMessageID: UUID,
    context: FollowUpSuggestionContext? = nil,
    status: Status = .preparing,
    suggestions: [PreparedFollowUp] = [],
    updatedAt: Date
  ) {
    self.sourceAssistantMessageID = sourceAssistantMessageID
    self.context = context
    self.status = status
    self.suggestions = Self.normalized(suggestions)
    self.updatedAt = updatedAt
  }

  /// Adds a progressively prepared suggestion while preserving the product
  /// contract: at most three distinct questions with one suggestion per rank.
  @discardableResult
  public mutating func appendIfEligible(_ suggestion: PreparedFollowUp) -> Bool {
    suggestions = Self.normalized(suggestions)
    guard suggestions.count < Self.maximumSuggestionCount else { return false }
    let identity = PreparedFollowUpIntegrity.questionIdentity(
      suggestion.question)
    guard
      !suggestions.contains(where: { $0.rank == suggestion.rank }),
      !suggestions.contains(where: {
        PreparedFollowUpIntegrity.questionIdentity($0.question) == identity
      })
    else { return false }
    suggestions.append(suggestion)
    suggestions = Self.normalized(suggestions)
    return suggestions.contains(where: { $0.id == suggestion.id })
  }

  private static func normalized(
    _ suggestions: [PreparedFollowUp]
  ) -> [PreparedFollowUp] {
    var ranks = Set<Int>()
    var questions = Set<String>()
    var result: [PreparedFollowUp] = []
    let ordered = suggestions.enumerated().sorted { lhs, rhs in
      lhs.element.rank == rhs.element.rank
        ? lhs.offset < rhs.offset
        : lhs.element.rank < rhs.element.rank
    }
    for entry in ordered {
      let suggestion = entry.element
      let identity = PreparedFollowUpIntegrity.questionIdentity(
        suggestion.question)
      guard
        ranks.insert(suggestion.rank).inserted,
        questions.insert(identity).inserted
      else { continue }
      result.append(suggestion)
      if result.count == maximumSuggestionCount { break }
    }
    return result
  }

  enum CodingKeys: String, CodingKey {
    case sourceAssistantMessageID, context, status, suggestions, updatedAt
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      sourceAssistantMessageID: try values.decode(
        UUID.self, forKey: .sourceAssistantMessageID),
      context: try values.decodeIfPresent(
        FollowUpSuggestionContext.self, forKey: .context),
      status: try values.decode(Status.self, forKey: .status),
      suggestions: try values.decode(
        [PreparedFollowUp].self, forKey: .suggestions),
      updatedAt: try values.decode(Date.self, forKey: .updatedAt))
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(sourceAssistantMessageID, forKey: .sourceAssistantMessageID)
    try values.encodeIfPresent(context, forKey: .context)
    try values.encode(status, forKey: .status)
    try values.encode(Self.normalized(suggestions), forKey: .suggestions)
    try values.encode(updatedAt, forKey: .updatedAt)
  }
}

public enum FollowUpPreparationRejection: String, Sendable, Equatable, Codable {
  case invalidQuestion
  case generationFailed
  case generationTimedOut
  case validationFailed
  case validationTimedOut
  case executionFailed
  case executionTimedOut
  case unhelpfulResult
  case groundingTimedOut
  case cancelled
}

public enum FollowUpProposalFailure: String, Sendable, Equatable, Codable {
  case generationFailed
  case generationTimedOut
}

/// Payload-free preparation details retained when a candidate is rejected.
/// This keeps timeout and candidate-stage diagnostics observable without
/// persisting the generated SQL, result rows, or question a second time.
public struct FollowUpRejectionTelemetry: Sendable, Equatable, Codable {
  public var timeoutStage: String?
  public var stageTimings: StageTimings
  public var candidateCount: Int
  public var failedCandidateCount: Int
  public var repairAttempts: Int
  public var lastCandidateRole: CandidateRole?
  public var lastCandidateGeneratedSQL: Bool
  public var lastCandidateProducedResult: Bool
  public var lastCandidateErrorPresent: Bool
  public var lastIssueKind: SQLValidationIssue.Kind?
  public var lastIssueDisposition: SQLValidationDisposition?

  public init(
    timeoutStage: String? = nil,
    stageTimings: StageTimings = StageTimings(),
    candidateCount: Int = 0,
    failedCandidateCount: Int = 0,
    repairAttempts: Int = 0,
    lastCandidateRole: CandidateRole? = nil,
    lastCandidateGeneratedSQL: Bool = false,
    lastCandidateProducedResult: Bool = false,
    lastCandidateErrorPresent: Bool = false,
    lastIssueKind: SQLValidationIssue.Kind? = nil,
    lastIssueDisposition: SQLValidationDisposition? = nil
  ) {
    self.timeoutStage = timeoutStage
    self.stageTimings = stageTimings
    self.candidateCount = candidateCount
    self.failedCandidateCount = failedCandidateCount
    self.repairAttempts = repairAttempts
    self.lastCandidateRole = lastCandidateRole
    self.lastCandidateGeneratedSQL = lastCandidateGeneratedSQL
    self.lastCandidateProducedResult = lastCandidateProducedResult
    self.lastCandidateErrorPresent = lastCandidateErrorPresent
    self.lastIssueKind = lastIssueKind
    self.lastIssueDisposition = lastIssueDisposition
  }
}

/// Background preparation events are separate from user-turn events. They can
/// be persisted alongside the source answer without pretending the work was a
/// user-visible turn.
public enum FollowUpPreparationEvent: Sendable, Equatable, Codable {
  case started(candidateCount: Int)
  case proposalRetrying(attempt: Int, reason: FollowUpProposalFailure)
  case proposalFailed(reason: FollowUpProposalFailure)
  case prepared(PreparedFollowUp)
  case rejected(
    rank: Int,
    reason: FollowUpPreparationRejection,
    telemetry: FollowUpRejectionTelemetry? = nil)
  case finished
}

extension FollowUpPreparationEvent {
  /// Uses the same canonical JSONL representation as user-turn events.
  public func jsonLine(
    encoder: JSONEncoder = PipelineEvent.jsonlEncoder
  ) throws -> String {
    String(decoding: try encoder.encode(self), as: UTF8.self)
  }
}

public enum PreparedFollowUpIntegrityError: Error, Equatable, Sendable {
  case invalidChunkSize(Int)
}

public enum PreparedFollowUpIntegrity {
  public static func fingerprint(sql: String) -> String {
    sha256(Data(normalizedSQL(sql).utf8))
  }

  public static func fingerprint(result: QueryResult) -> String {
    var data = Data("CREG.PreparedResult.v3\0".utf8)
    append(result.columns.count, to: &data)
    for column in result.columns { append(column, to: &data) }
    append(result.rows.count, to: &data)
    for row in result.rows {
      append(row.count, to: &data)
      for value in row {
        switch value {
        case .null:
          data.append(0)
        case .integer(let value):
          data.append(1)
          append(value, to: &data)
        case .real(let value):
          data.append(2)
          append(value.bitPattern, to: &data)
        case .text(let value):
          data.append(3)
          append(value, to: &data)
        case .blob(let value):
          data.append(4)
          append(value, to: &data)
        }
      }
    }
    data.append(result.isTruncated ? 1 : 0)
    return sha256(data)
  }

  /// Canonical identity used at both proposal and persistence boundaries.
  /// Whitespace and punctuation do not make two follow-up questions distinct.
  public static func questionIdentity(_ question: String) -> String {
    question
      .lowercased()
      .filter { $0.isLetter || $0.isNumber }
  }

  public static func normalizedSQL(_ sql: String) -> String {
    sql
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
  }

  public static func sha256(
    contentsOf url: URL,
    chunkSize: Int = 1 << 20
  ) throws -> String {
    guard chunkSize > 0 else {
      throw PreparedFollowUpIntegrityError.invalidChunkSize(chunkSize)
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize()
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private static func append(_ value: Int, to data: inout Data) {
    append(UInt64(value), to: &data)
  }

  private static func append(_ value: Int64, to data: inout Data) {
    append(UInt64(bitPattern: value), to: &data)
  }

  private static func append(_ value: UInt64, to data: inout Data) {
    var bigEndian = value.bigEndian
    Swift.withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
  }

  private static func append(_ value: String, to data: inout Data) {
    append(Data(value.utf8), to: &data)
  }

  private static func append(_ value: Data, to data: inout Data) {
    append(value.count, to: &data)
    data.append(value)
  }
}
