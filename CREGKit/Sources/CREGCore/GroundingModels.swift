import Foundation

public struct GroundingColumn: Sendable, Equatable, Hashable, Codable,
  CustomStringConvertible
{
  public var table: String
  public var column: String

  public init(table: String, column: String) {
    self.table = table
    self.column = column
  }

  public var description: String { "\(table).\(column)" }
}

public enum HeuristicFinding: Sendable, Equatable, Codable {
  case literalNotFound(
    column: GroundingColumn, literal: String, suggestion: String?)
  case emptyResult
  case nullScalar

  public var userNotice: String {
    switch self {
    case .literalNotFound(let column, let literal, let suggestion?):
      "Nothing in \(column) matched “\(literal)” — did you mean “\(suggestion)”?"
    case .literalNotFound(let column, let literal, nil):
      "Nothing in \(column) matched “\(literal)”."
    case .emptyResult:
      "No rows matched — a filter may be too narrow."
    case .nullScalar:
      "That calculation came back empty — the filter may not match anything."
    }
  }
}

public struct GroundingCheck: Sendable, Equatable, Codable {
  public var column: GroundingColumn
  public var literal: String
  public var matched: Bool

  public init(column: GroundingColumn, literal: String, matched: Bool) {
    self.column = column
    self.literal = literal
    self.matched = matched
  }
}

public enum GroundingSkipReason: Sendable, Equatable, Codable {
  case unresolvedColumn(reference: String, literal: String)
  case ineligibleColumn(column: GroundingColumn, literal: String)
  case dateLiteral(literal: String)
  case likePattern(literal: String)
  case rangePredicate(literal: String)
  case unresolvedExpression(literal: String)
}

public struct GroundingDegradation: Sendable, Equatable, Codable {
  public var column: GroundingColumn
  public var message: String

  public init(column: GroundingColumn, message: String) {
    self.column = column
    self.message = message
  }
}

public struct GroundingReport: Sendable, Equatable, Codable {
  public var findings: [HeuristicFinding]
  public var checks: [GroundingCheck]
  public var skipped: [GroundingSkipReason]
  public var degradations: [GroundingDegradation]

  public init(
    findings: [HeuristicFinding] = [],
    checks: [GroundingCheck] = [],
    skipped: [GroundingSkipReason] = [],
    degradations: [GroundingDegradation] = []
  ) {
    self.findings = findings
    self.checks = checks
    self.skipped = skipped
    self.degradations = degradations
  }
}
