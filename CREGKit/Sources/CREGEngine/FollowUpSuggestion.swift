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
  public static let currentSchemaVersion = 1

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
    self.suggestions = suggestions.sorted { $0.rank < $1.rank }
    self.updatedAt = updatedAt
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

public enum PreparedFollowUpIntegrity {
  public static func fingerprint(sql: String) -> String {
    sha256(Data(sql.utf8))
  }

  public static func fingerprint(result: QueryResult) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(result)) ?? Data()
    return sha256(data)
  }

  public static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
  }
}
