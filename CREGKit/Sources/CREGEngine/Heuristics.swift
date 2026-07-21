import Foundation

private struct SchemaCatalogDocument: Decodable {
  var schemaVersion: Int
  var tables: [String: [String]]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case tables
  }
}

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

/// Conservative empty-result grounding. Only string literals bound to a
/// single declared entity/categorical column are eligible for correction.
public actor ResultHeuristics {
  private struct Predicate {
    var reference: String?
    var column: String
    var literals: [String]
    var literalRanges: [NSRange]
  }

  private let db: DatabaseClient
  private var catalogs: [GroundingColumn: [String]] = [:]

  static let eligibleColumns: Set<GroundingColumn> = [
    GroundingColumn(table: "funds", column: "name"),
    GroundingColumn(table: "funds", column: "strategy"),
    GroundingColumn(table: "funds", column: "status"),
    GroundingColumn(table: "properties", column: "name"),
    GroundingColumn(table: "properties", column: "city"),
    GroundingColumn(table: "properties", column: "state"),
    GroundingColumn(table: "properties", column: "market"),
    GroundingColumn(table: "properties", column: "submarket"),
    GroundingColumn(table: "properties", column: "property_type"),
    GroundingColumn(table: "properties", column: "building_class"),
    GroundingColumn(table: "properties", column: "status"),
    GroundingColumn(table: "tenants", column: "name"),
    GroundingColumn(table: "tenants", column: "industry"),
    GroundingColumn(table: "tenants", column: "credit_rating"),
    GroundingColumn(table: "tenants", column: "headquarters_city"),
    GroundingColumn(table: "tenants", column: "headquarters_state"),
    GroundingColumn(table: "leases", column: "lease_type"),
    GroundingColumn(table: "leases", column: "status"),
    GroundingColumn(table: "property_financials", column: "period_type"),
    GroundingColumn(table: "loans", column: "lender"),
    GroundingColumn(table: "loans", column: "rate_type"),
    GroundingColumn(table: "valuations", column: "method"),
    GroundingColumn(table: "valuations", column: "appraiser"),
  ]

  private static let reservedAliases: Set<String> = [
    "where", "join", "left", "right", "inner", "outer", "cross", "on",
    "group", "order", "having", "limit", "union",
  ]

  private static let tableColumns: [String: Set<String>] = {
    guard let url = Bundle.module.url(
      forResource: "schema_catalog", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let catalog = try? JSONDecoder().decode(
        SchemaCatalogDocument.self, from: data),
      catalog.schemaVersion == 1
    else {
      preconditionFailure("schema_catalog.json is missing or incompatible")
    }
    return catalog.tables.mapValues(Set.init)
  }()

  public init(db: DatabaseClient) {
    self.db = db
  }

  static func repairGuidance(
    issue: SQLValidationIssue,
    sql: String,
    failedFingerprints: [String]
  ) -> RepairGuidance {
    let sources = querySources(in: sql).tables.sorted()
    let expression = try? NSRegularExpression(
      pattern: #"(?i)(?:no such|ambiguous) column:\s*(?:\w+\.)?([A-Za-z_][A-Za-z0-9_]*)"#)
    let range = NSRange(issue.message.startIndex..., in: issue.message)
    let column: String? = expression
      .flatMap { $0.firstMatch(in: issue.message, range: range) }
      .flatMap { match in
        Range(match.range(at: 1), in: issue.message)
          .map { String(issue.message[$0]).lowercased() }
      }
    let owners = column.map { column in
      tableColumns
        .filter { $0.value.contains(column) }
        .map(\.key)
        .sorted()
    } ?? []
    return RepairGuidance(
      issue: issue,
      declaredSources: sources,
      possibleColumnOwners: owners,
      failedFingerprints: failedFingerprints)
  }

  /// Compatibility entry point for callers that only need user-facing
  /// findings. Pipeline telemetry uses ``inspectDetailed(sql:result:)``.
  public func inspect(sql: String, result: QueryResult) async -> [HeuristicFinding] {
    await inspectDetailed(sql: sql, result: result).findings
  }

  public func inspectDetailed(sql: String, result: QueryResult) async -> GroundingReport {
    if result.rows.count == 1, result.rows[0].allSatisfy({ $0 == .null }) {
      return GroundingReport(findings: [.nullScalar])
    }
    guard result.rows.isEmpty else { return GroundingReport() }

    let sources = Self.querySources(in: sql)
    let predicates = Self.predicates(in: sql)
    var report = GroundingReport()
    var consumedLiteralRanges: [NSRange] = []

    for predicate in predicates {
      consumedLiteralRanges.append(contentsOf: predicate.literalRanges)
      for literal in predicate.literals {
        if Self.isISODate(literal) {
          report.skipped.append(.dateLiteral(literal: literal))
          continue
        }
        guard
          let column = Self.resolve(
            reference: predicate.reference,
            column: predicate.column,
            sources: sources)
        else {
          let reference = predicate.reference.map { "\($0)." } ?? ""
          report.skipped.append(.unresolvedColumn(
            reference: reference + predicate.column, literal: literal))
          continue
        }
        guard Self.eligibleColumns.contains(column) else {
          report.skipped.append(.ineligibleColumn(column: column, literal: literal))
          continue
        }
        do {
          let values = try await loadCatalog(for: column)
          let matches = values.contains { $0.caseInsensitiveCompare(literal) == .orderedSame }
          report.checks.append(GroundingCheck(
            column: column, literal: literal, matched: matches))
          if !matches {
            report.findings.append(.literalNotFound(
              column: column,
              literal: literal,
              suggestion: Self.closestMatch(to: literal, in: values)))
          }
        } catch {
          report.degradations.append(GroundingDegradation(
            column: column, message: error.localizedDescription))
        }
      }
    }

    for (literal, range) in Self.allStringLiterals(in: sql)
    where !consumedLiteralRanges.contains(where: { NSIntersectionRange($0, range).length > 0 })
    {
      report.skipped.append(Self.classifyUnresolvedLiteral(
        literal: literal, range: range, sql: sql))
    }
    // Every empty result without a blamed literal is reported, including
    // when some literals were skipped or a catalog degraded: the user notice
    // and the voting trigger must not silently disappear just because a
    // LIKE pattern or date literal could not be entity-checked.
    if report.findings.isEmpty {
      report.findings.append(.emptyResult)
    }
    return report
  }

  static func closestMatch(to literal: String, in values: [String]) -> String? {
    let target = literal.lowercased()
    var best: (value: String, distance: Int)?
    for value in values {
      let candidate = value.lowercased()
      if candidate.hasPrefix(target) || candidate.contains(target) {
        return value
      }
      let distance = editDistance(target, candidate)
      if best == nil || distance < best!.distance {
        best = (value, distance)
      }
    }
    guard let best else { return nil }
    return best.distance <= max(2, literal.count / 4) ? best.value : nil
  }

  static func editDistance(_ a: String, _ b: String) -> Int {
    let left = Array(a)
    let right = Array(b)
    if left.isEmpty { return right.count }
    if right.isEmpty { return left.count }

    var row = Array(0...right.count)
    for leftIndex in 1...left.count {
      var diagonal = row[0]
      row[0] = leftIndex
      for rightIndex in 1...right.count {
        let above = row[rightIndex]
        let insertOrDelete = min(above, row[rightIndex - 1]) + 1
        let substitute =
          diagonal + (left[leftIndex - 1] == right[rightIndex - 1] ? 0 : 1)
        diagonal = above
        row[rightIndex] = min(insertOrDelete, substitute)
      }
    }
    return row[right.count]
  }

  private func loadCatalog(for column: GroundingColumn) async throws -> [String] {
    if let cached = catalogs[column] { return cached }
    // Identifiers come exclusively from the static eligible-column set.
    let sql = """
      SELECT DISTINCT \(column.column)
      FROM \(column.table)
      WHERE \(column.column) IS NOT NULL
      ORDER BY \(column.column)
      """
    let result = try await db.execute(sql)
    guard !result.isTruncated else {
      throw GroundingCatalogError.truncated(column)
    }
    var values: [String] = []
    for row in result.rows {
      guard row.count == 1, case .text(let value) = row[0] else {
        throw GroundingCatalogError.invalidRow(column)
      }
      values.append(value)
    }
    // Only successful, complete loads enter the cache. An error is retried on
    // the next turn rather than poisoning every future grounding check.
    catalogs[column] = values
    return values
  }

  private static func querySources(
    in sql: String
  ) -> (aliases: [String: String], tables: Set<String>) {
    let pattern =
      #"\b(?:FROM|JOIN)\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s+(?:AS\s+)?([A-Za-z_][A-Za-z0-9_]*))?"#
    let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    let string = sql as NSString
    var aliases: [String: String] = [:]
    var tables: Set<String> = []
    for match in regex.matches(in: sql, range: NSRange(location: 0, length: string.length)) {
      let table = string.substring(with: match.range(at: 1)).lowercased()
      tables.insert(table)
      aliases[table] = table
      if match.range(at: 2).location != NSNotFound {
        let alias = string.substring(with: match.range(at: 2)).lowercased()
        if !reservedAliases.contains(alias) {
          aliases[alias] = table
        }
      }
    }
    return (aliases, tables)
  }

  private static func resolve(
    reference: String?,
    column: String,
    sources: (aliases: [String: String], tables: Set<String>)
  ) -> GroundingColumn? {
    let column = column.lowercased()
    if let reference {
      guard let table = sources.aliases[reference.lowercased()] else { return nil }
      guard tableColumns[table]?.contains(column) == true else { return nil }
      return GroundingColumn(table: table, column: column)
    }
    let matches = sources.tables.map {
      GroundingColumn(table: $0, column: column)
    }.filter {
      tableColumns[$0.table]?.contains($0.column) == true
    }
    return matches.count == 1 ? matches[0] : nil
  }

  private static func predicates(in sql: String) -> [Predicate] {
    equalityPredicates(in: sql) + inPredicates(in: sql)
  }

  private static func equalityPredicates(in sql: String) -> [Predicate] {
    let pattern =
      #"\b(?:(\w+)\s*\.\s*)?(\w+)\s*=\s*'((?:''|[^'])*)'"#
    let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    let string = sql as NSString
    return regex.matches(
      in: sql, range: NSRange(location: 0, length: string.length)
    ).map { match in
      let reference =
        match.range(at: 1).location == NSNotFound
        ? nil : string.substring(with: match.range(at: 1))
      return Predicate(
        reference: reference,
        column: string.substring(with: match.range(at: 2)),
        literals: [unescape(string.substring(with: match.range(at: 3)))],
        literalRanges: [match.range(at: 3)])
    }
  }

  private static func inPredicates(in sql: String) -> [Predicate] {
    let pattern =
      #"\b(?:(\w+)\s*\.\s*)?(\w+)\s+IN\s*\(((?:\s*'(?:''|[^'])*'\s*,?)+)\)"#
    let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    let literalRegex = try! NSRegularExpression(pattern: #"'((?:''|[^'])*)'"#)
    let string = sql as NSString
    return regex.matches(
      in: sql, range: NSRange(location: 0, length: string.length)
    ).map { match in
      let reference =
        match.range(at: 1).location == NSNotFound
        ? nil : string.substring(with: match.range(at: 1))
      let contentRange = match.range(at: 3)
      let literalMatches = literalRegex.matches(in: sql, range: contentRange)
      return Predicate(
        reference: reference,
        column: string.substring(with: match.range(at: 2)),
        literals: literalMatches.map {
          unescape(string.substring(with: $0.range(at: 1)))
        },
        literalRanges: literalMatches.map { $0.range(at: 1) })
    }
  }

  private static func allStringLiterals(in sql: String) -> [(String, NSRange)] {
    let regex = try! NSRegularExpression(pattern: #"'((?:''|[^'])*)'"#)
    let string = sql as NSString
    return regex.matches(
      in: sql, range: NSRange(location: 0, length: string.length)
    ).map {
      (unescape(string.substring(with: $0.range(at: 1))), $0.range(at: 1))
    }
  }

  private static func unescape(_ literal: String) -> String {
    literal.replacingOccurrences(of: "''", with: "'")
  }

  private static func isISODate(_ literal: String) -> Bool {
    literal.range(
      of: #"^\d{4}-\d{2}-\d{2}$"#,
      options: .regularExpression) != nil
  }

  private static func classifyUnresolvedLiteral(
    literal: String,
    range: NSRange,
    sql: String
  ) -> GroundingSkipReason {
    if isISODate(literal) {
      return .dateLiteral(literal: literal)
    }
    let string = sql as NSString
    let prefixStart = max(0, range.location - 64)
    let prefix = string.substring(
      with: NSRange(
        location: prefixStart,
        length: range.location - prefixStart)
    ).uppercased()
    if prefix.range(
      of: #"\bLIKE\s*'\s*$"#,
      options: .regularExpression) != nil
    {
      return .likePattern(literal: literal)
    }
    if prefix.range(
      of: #"(?:>=|<=|<>|!=|>|<|BETWEEN)\s*'\s*$"#,
      options: .regularExpression) != nil
    {
      return .rangePredicate(literal: literal)
    }
    return .unresolvedExpression(literal: literal)
  }
}

public enum GroundingCatalogError: LocalizedError, Equatable {
  case truncated(GroundingColumn)
  case invalidRow(GroundingColumn)

  public var errorDescription: String? {
    switch self {
    case .truncated(let column):
      "value-domain load for \(column) exceeded the row cap"
    case .invalidRow(let column):
      "value-domain load for \(column) returned a non-text or malformed row"
    }
  }
}
