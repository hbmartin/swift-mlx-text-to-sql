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
  public static let currentSchemaVersion = 2

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
    let identity = Self.questionIdentity(suggestion.question)
    guard
      !suggestions.contains(where: { $0.rank == suggestion.rank }),
      !suggestions.contains(where: {
        Self.questionIdentity($0.question) == identity
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
      let identity = questionIdentity(suggestion.question)
      guard
        ranks.insert(suggestion.rank).inserted,
        questions.insert(identity).inserted
      else { continue }
      result.append(suggestion)
      if result.count == maximumSuggestionCount { break }
    }
    return result
  }

  private static func questionIdentity(_ question: String) -> String {
    question
      .lowercased()
      .filter { $0.isLetter || $0.isNumber }
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
  case validationFailed
  case executionFailed
  case unhelpfulResult
  case cancelled
}

/// Background preparation events are separate from user-turn events. They can
/// be persisted alongside the source answer without pretending the work was a
/// user-visible turn.
public enum FollowUpPreparationEvent: Sendable, Equatable, Codable {
  case started(candidateCount: Int)
  case prepared(PreparedFollowUp)
  case rejected(rank: Int, reason: FollowUpPreparationRejection)
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

public enum PreparedFollowUpIntegrity {
  public static func fingerprint(sql: String) -> String {
    sha256(Data(normalizedSQL(sql).utf8))
  }

  public static func fingerprint(result: QueryResult) -> String {
    var data = Data("CREG.PreparedResult.v2\0".utf8)
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
    append(result.elapsedMicroseconds, to: &data)
    return sha256(data)
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
