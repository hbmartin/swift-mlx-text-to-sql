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
  public var elapsedMilliseconds: Double

  public init(columns: [String], rows: [[SQLValue]], isTruncated: Bool = false, elapsedMilliseconds: Double = 0) {
    self.columns = columns
    self.rows = rows
    self.isTruncated = isTruncated
    self.elapsedMilliseconds = elapsedMilliseconds
  }

  public var rowCount: Int { rows.count }
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

/// Context passed back to the SQL model when repairing a failed query.
public struct RepairContext: Sendable, Equatable {
  public var failedSQL: String
  public var errorMessage: String

  public init(failedSQL: String, errorMessage: String) {
    self.failedSQL = failedSQL
    self.errorMessage = errorMessage
  }
}

/// Output of one constrained SQL generation.
public struct SQLGeneration: Sendable, Equatable {
  public var sql: String
  public var tokensPerSecond: Double
  public var modelName: String

  public init(sql: String, tokensPerSecond: Double, modelName: String) {
    self.sql = sql
    self.tokensPerSecond = tokensPerSecond
    self.modelName = modelName
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

/// One candidate in a self-consistency vote (correction layer C).
public struct ConsistencyCandidate: Sendable, Equatable, Codable {
  public var sql: String
  public var rowCount: Int?
  public var error: String?
  public var agreedWithWinner: Bool

  public init(sql: String, rowCount: Int?, error: String?, agreedWithWinner: Bool) {
    self.sql = sql
    self.rowCount = rowCount
    self.error = error
    self.agreedWithWinner = agreedWithWinner
  }
}
