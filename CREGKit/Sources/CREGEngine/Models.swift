import Foundation

/// A single cell value from a query result.
public enum SQLValue: Sendable, Equatable, Hashable, Codable {
  case null
  case integer(Int64)
  case real(Double)
  case text(String)
  case blob(Data)

  public var displayString: String {
    switch self {
    case .null: "—"
    case .integer(let v): v.formatted(.number.grouping(.automatic))
    case .real(let v):
      v == v.rounded() && abs(v) < 1e15
        ? Int64(v).formatted(.number.grouping(.automatic))
        : v.formatted(.number.precision(.fractionLength(0...2)))
    case .text(let s): s
    case .blob: "<blob>"
    }
  }
}

/// The table returned by executing a query.
public struct QueryResult: Sendable, Equatable, Codable {
  public var columns: [String]
  public var rows: [[SQLValue]]
  /// True when the row set was cut off at the client's row cap.
  public var isTruncated: Bool
  /// Monotonic execution duration. Microseconds are the persisted canonical
  /// unit across the app and both evaluation harnesses.
  public var elapsedMicroseconds: Int64

  public init(
    columns: [String],
    rows: [[SQLValue]],
    isTruncated: Bool = false,
    elapsedMicroseconds: Int64 = 0
  ) {
    self.columns = columns
    self.rows = rows
    self.isTruncated = isTruncated
    self.elapsedMicroseconds = elapsedMicroseconds
  }

  /// Source-compatible bridge for callers and stored histories created before
  /// microseconds became the canonical timing unit.
  public init(
    columns: [String],
    rows: [[SQLValue]],
    isTruncated: Bool = false,
    elapsedMilliseconds: Double
  ) {
    self.init(
      columns: columns,
      rows: rows,
      isTruncated: isTruncated,
      elapsedMicroseconds: Int64((elapsedMilliseconds * 1_000).rounded()))
  }

  public var rowCount: Int { rows.count }
  public var elapsedMilliseconds: Double { Double(elapsedMicroseconds) / 1_000 }

  enum CodingKeys: String, CodingKey {
    case columns, rows, isTruncated, elapsedMicroseconds, elapsedMilliseconds
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    columns = try values.decode([String].self, forKey: .columns)
    rows = try values.decode([[SQLValue]].self, forKey: .rows)
    isTruncated = try values.decodeIfPresent(Bool.self, forKey: .isTruncated) ?? false
    if let microseconds = try values.decodeIfPresent(
      Int64.self, forKey: .elapsedMicroseconds)
    {
      elapsedMicroseconds = microseconds
    } else {
      let milliseconds =
        try values.decodeIfPresent(Double.self, forKey: .elapsedMilliseconds) ?? 0
      elapsedMicroseconds = Int64((milliseconds * 1_000).rounded())
    }
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(columns, forKey: .columns)
    try values.encode(rows, forKey: .rows)
    try values.encode(isTruncated, forKey: .isTruncated)
    try values.encode(elapsedMicroseconds, forKey: .elapsedMicroseconds)
  }
}

/// One prior exchange, used to rewrite follow-ups into standalone questions.
public struct ConversationTurn: Sendable, Equatable, Codable {
  public var question: String
  public var answerSummary: String

  public init(question: String, answerSummary: String) {
    self.question = question
    self.answerSummary = answerSummary
  }
}

/// The ambiguity gate's verdict on a standalone question.
public enum GateDecision: Sendable, Equatable, Codable {
  case proceed
  case clarify(question: String)
}

/// Availability of Apple's on-device Foundation Model.
public enum FMAvailability: Sendable, Equatable {
  case available
  case unavailable(reason: String)
}

public enum SQLValidationDisposition: String, Sendable, Equatable, Codable {
  case repairable
  case terminal
}

public struct SQLValidationIssue: Sendable, Equatable, Codable {
  public enum Kind: String, Sendable, Equatable, Codable {
    case syntax
    case binding
    case authorization
    case nonQuerySecurityViolation
    case databaseUnavailable
    case databaseCorrupt
    case interrupted
    case unknown
  }

  public var kind: Kind
  public var disposition: SQLValidationDisposition
  public var message: String

  public init(
    kind: Kind,
    disposition: SQLValidationDisposition,
    message: String
  ) {
    self.kind = kind
    self.disposition = disposition
    self.message = message
  }
}

public struct SQLValidationReport: Sendable, Equatable, Codable {
  public var issue: SQLValidationIssue?
  public var elapsedMicroseconds: Int64

  public init(
    issue: SQLValidationIssue? = nil,
    elapsedMicroseconds: Int64 = 0
  ) {
    self.issue = issue
    self.elapsedMicroseconds = elapsedMicroseconds
  }

  public var isValid: Bool { issue == nil }
}

public struct RepairGuidance: Sendable, Equatable, Codable {
  public var issue: SQLValidationIssue
  public var declaredSources: [String]
  public var possibleColumnOwners: [String]
  public var failedFingerprints: [String]

  public init(
    issue: SQLValidationIssue,
    declaredSources: [String] = [],
    possibleColumnOwners: [String] = [],
    failedFingerprints: [String] = []
  ) {
    self.issue = issue
    self.declaredSources = declaredSources
    self.possibleColumnOwners = possibleColumnOwners
    self.failedFingerprints = failedFingerprints
  }
}

public struct PipelineDeadlines: Sendable, Equatable, Codable {
  public var generationSeconds: Double
  public var wholeTurnSeconds: Double

  public init(generationSeconds: Double = 30, wholeTurnSeconds: Double = 90) {
    precondition(generationSeconds > 0)
    precondition(wholeTurnSeconds > 0)
    self.generationSeconds = generationSeconds
    self.wholeTurnSeconds = wholeTurnSeconds
  }
}

public enum AnswerConfidence: String, Sendable, Equatable, Codable {
  case confirmed
  case unconfirmed
}

public enum NoConsensusReason: String, Sendable, Equatable, Codable {
  case conflictingResults
  case insufficientNonEmptyEvidence
}

/// Context passed back to the SQL model when repairing a failed query.
public struct RepairContext: Sendable, Equatable, Codable {
  public var failedSQL: String
  public var errorMessage: String
  public var guidance: RepairGuidance?

  public init(
    failedSQL: String,
    errorMessage: String,
    guidance: RepairGuidance? = nil
  ) {
    self.failedSQL = failedSQL
    self.errorMessage = errorMessage
    self.guidance = guidance
  }
}

public struct CandidateID: RawRepresentable, Sendable, Equatable, Hashable, Codable,
  CustomStringConvertible
{
  public var rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public var description: String { rawValue }
}

public enum CandidateRole: Sendable, Equatable, Hashable, Codable {
  case initial
  case repair(attempt: Int)
  case deterministicAnchor
  case consistencySample(index: Int)
}

public enum GCDMode: String, Sendable, Equatable, Hashable, Codable {
  case on
  case off
}

public struct ModelReference: Sendable, Equatable, Hashable, Codable {
  public var key: String
  public var repository: String
  public var revision: String
  public var quantization: String

  public init(
    key: String,
    repository: String,
    revision: String,
    quantization: String = "4-bit"
  ) {
    self.key = key
    self.repository = repository
    self.revision = revision
    self.quantization = quantization
  }

  public static let selectionPending = ModelReference(
    key: "selection-pending",
    repository: "selection-pending",
    revision: String(repeating: "0", count: 40)
  )
}

public struct SQLGenerationRequest: Sendable, Equatable, Codable {
  public var candidateID: CandidateID
  public var role: CandidateRole
  public var model: ModelReference
  public var question: String
  public var repair: RepairContext?
  public var gcd: GCDMode
  public var temperature: Double
  public var seed: UInt64?
  public var maxTokens: Int

  public init(
    candidateID: CandidateID,
    role: CandidateRole,
    model: ModelReference,
    question: String,
    repair: RepairContext? = nil,
    gcd: GCDMode,
    temperature: Double,
    seed: UInt64?,
    maxTokens: Int = 512
  ) {
    self.candidateID = candidateID
    self.role = role
    self.model = model
    self.question = question
    self.repair = repair
    self.gcd = gcd
    self.temperature = temperature
    self.seed = seed
    self.maxTokens = maxTokens
  }
}

/// Output of one SQL generation.
public struct SQLGeneration: Sendable, Equatable, Codable {
  public var sql: String
  public var tokensPerSecond: Double
  public var tokenCount: Int?
  public var elapsedMicroseconds: Int64
  public var modelName: String

  public init(
    sql: String,
    tokensPerSecond: Double,
    modelName: String,
    tokenCount: Int? = nil,
    elapsedMicroseconds: Int64 = 0
  ) {
    self.sql = sql
    self.tokensPerSecond = tokensPerSecond
    self.modelName = modelName
    self.tokenCount = tokenCount
    self.elapsedMicroseconds = elapsedMicroseconds
  }
}

public struct CandidateTelemetry: Sendable, Equatable, Codable, Identifiable {
  public var id: CandidateID
  public var role: CandidateRole
  public var model: ModelReference
  public var question: String
  public var repairContext: RepairContext?
  public var gcd: GCDMode
  public var temperature: Double
  public var seed: UInt64?
  public var maxTokens: Int
  public var sql: String?
  public var tokensPerSecond: Double?
  public var tokenCount: Int?
  public var generationMicroseconds: Int64?
  public var executionMicroseconds: Int64?
  public var result: QueryResult?
  public var error: String?
  public var resultDigest: String?
  public var sqlFingerprint: String?
  public var validationReport: SQLValidationReport?
  public var duplicateOf: CandidateID?
  public var duplicateSuppressed: Bool?
  public var selected: Bool

  public init(request: SQLGenerationRequest) {
    self.id = request.candidateID
    self.role = request.role
    self.model = request.model
    self.question = request.question
    self.repairContext = request.repair
    self.gcd = request.gcd
    self.temperature = request.temperature
    self.seed = request.seed
    self.maxTokens = request.maxTokens
    self.selected = false
  }
}

public enum VoteOutcome: Sendable, Equatable, Codable {
  case consensus(resultDigest: String, agreement: Int, candidateCount: Int)
  case noConsensus(
    anchorCandidateID: CandidateID,
    candidateCount: Int,
    reason: NoConsensusReason?)
  case anchorFailed(fallbackCandidateID: CandidateID, message: String)
}

public enum CandidateSelectionReason: String, Sendable, Equatable, Codable {
  case initialSuccess
  case repairSuccess
  case majorityVote
  case noConsensusDeterministicAnchor
  case noConsensusAnchorFailed
}

public struct StageTimings: Sendable, Equatable, Codable {
  public var preparationMicroseconds: Int64?
  public var rewriteMicroseconds: Int64?
  public var gateMicroseconds: Int64?
  public var validationMicroseconds: Int64?
  public var groundingMicroseconds: Int64?
  public var votingMicroseconds: Int64?
  public var narrationMicroseconds: Int64?
  public var totalMicroseconds: Int64

  public init(totalMicroseconds: Int64 = 0) {
    self.totalMicroseconds = totalMicroseconds
  }
}

public struct TurnTelemetry: Sendable, Equatable, Codable {
  public static let currentSchemaVersion = 2

  public var schemaVersion: Int
  public var originalQuestion: String
  public var standaloneQuestion: String
  public var rewriteApplied: Bool
  public var rewriteUsedFM: Bool
  public var gateUsedFM: Bool
  public var narrationUsedFM: Bool
  public var gateDecision: GateDecision?
  public var stageTimings: StageTimings
  public var candidates: [CandidateTelemetry]
  public var repairAttempts: Int
  public var voteTrigger: String?
  public var voteOutcome: VoteOutcome?
  public var selectedCandidateID: CandidateID?
  public var selectionReason: CandidateSelectionReason?
  public var confidence: AnswerConfidence?
  public var noConsensusReason: NoConsensusReason?
  public var generatedCount: Int
  public var timeoutStage: String?
  public var grounding: GroundingReport?
  public var terminalError: String?

  public init(originalQuestion: String) {
    self.schemaVersion = Self.currentSchemaVersion
    self.originalQuestion = originalQuestion
    self.standaloneQuestion = originalQuestion
    self.rewriteApplied = false
    self.rewriteUsedFM = false
    self.gateUsedFM = false
    self.narrationUsedFM = false
    self.stageTimings = StageTimings()
    self.candidates = []
    self.repairAttempts = 0
    self.generatedCount = 0
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion
    case originalQuestion
    case standaloneQuestion
    case rewriteApplied
    case rewriteUsedFM
    case gateUsedFM
    case narrationUsedFM
    case gateDecision
    case stageTimings
    case candidates
    case repairAttempts
    case voteTrigger
    case voteOutcome
    case selectedCandidateID
    case selectionReason
    case confidence
    case noConsensusReason
    case generatedCount
    case timeoutStage
    case grounding
    case terminalError
  }

  /// Schema-versioned tolerant decoding keeps chat history readable as
  /// telemetry fields are added. Missing fields receive neutral values;
  /// unsupported future schema versions fail explicitly.
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    guard
      values.contains(.schemaVersion)
        || values.contains(.originalQuestion)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion,
        in: values,
        debugDescription:
          "Legacy developer info is not structured turn telemetry")
    }
    schemaVersion =
      try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
    guard schemaVersion <= Self.currentSchemaVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion,
        in: values,
        debugDescription:
          "Unsupported turn telemetry schema \(schemaVersion); current is \(Self.currentSchemaVersion)")
    }
    originalQuestion =
      try values.decodeIfPresent(String.self, forKey: .originalQuestion) ?? ""
    standaloneQuestion =
      try values.decodeIfPresent(String.self, forKey: .standaloneQuestion)
      ?? originalQuestion
    rewriteApplied =
      try values.decodeIfPresent(Bool.self, forKey: .rewriteApplied) ?? false
    rewriteUsedFM =
      try values.decodeIfPresent(Bool.self, forKey: .rewriteUsedFM) ?? false
    gateUsedFM =
      try values.decodeIfPresent(Bool.self, forKey: .gateUsedFM) ?? false
    narrationUsedFM =
      try values.decodeIfPresent(Bool.self, forKey: .narrationUsedFM) ?? false
    gateDecision =
      try values.decodeIfPresent(GateDecision.self, forKey: .gateDecision)
    stageTimings =
      try values.decodeIfPresent(StageTimings.self, forKey: .stageTimings)
      ?? StageTimings()
    candidates =
      try values.decodeIfPresent([CandidateTelemetry].self, forKey: .candidates)
      ?? []
    repairAttempts =
      try values.decodeIfPresent(Int.self, forKey: .repairAttempts) ?? 0
    voteTrigger =
      try values.decodeIfPresent(String.self, forKey: .voteTrigger)
    voteOutcome =
      try values.decodeIfPresent(VoteOutcome.self, forKey: .voteOutcome)
    selectedCandidateID =
      try values.decodeIfPresent(CandidateID.self, forKey: .selectedCandidateID)
    selectionReason =
      try values.decodeIfPresent(
        CandidateSelectionReason.self, forKey: .selectionReason)
    confidence =
      try values.decodeIfPresent(AnswerConfidence.self, forKey: .confidence)
    noConsensusReason =
      try values.decodeIfPresent(NoConsensusReason.self, forKey: .noConsensusReason)
    if case .noConsensus(_, _, let legacyReason) = voteOutcome {
      confidence = confidence ?? .unconfirmed
      noConsensusReason = noConsensusReason ?? legacyReason ?? .conflictingResults
    }
    generatedCount =
      try values.decodeIfPresent(Int.self, forKey: .generatedCount)
      ?? candidates.count
    timeoutStage =
      try values.decodeIfPresent(String.self, forKey: .timeoutStage)
    grounding =
      try values.decodeIfPresent(GroundingReport.self, forKey: .grounding)
    terminalError =
      try values.decodeIfPresent(String.self, forKey: .terminalError)
  }
}

/// How a pipeline turn ended.
public enum TurnOutcome: Sendable, Equatable, Codable {
  /// `notice` carries a correction-layer heads-up (fuzzy-literal suggestion,
  /// empty-result warning) shown alongside the answer.
  case answered(result: QueryResult, narration: String, sql: String, notice: String?)
  case needsClarification(question: String)
  case failed(message: String)
}
