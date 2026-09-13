import CREGCore
import Foundation

package struct PortfolioSchemaDocument: Decodable, Sendable {
  package var schemaVersion: Int
  package var tables: [String: [String]]
  package var foreignKeys: [PortfolioSchemaForeignKey]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case tables
    case foreignKeys = "foreign_keys"
  }
}

package struct PortfolioSchemaForeignKey: Decodable, Hashable, Sendable {
  package var fromTable: String
  package var fromColumn: String
  package var toTable: String
  package var toColumn: String

  enum CodingKeys: String, CodingKey {
    case fromTable = "from_table"
    case fromColumn = "from_column"
    case toTable = "to_table"
    case toColumn = "to_column"
  }

  package var description: String {
    "\(fromTable).\(fromColumn) -> \(toTable).\(toColumn)"
  }
}

/// One process-wide, resource-backed view of CREG's frozen portfolio schema.
/// Consumers use this instead of duplicating table and relationship lists.
package enum PortfolioSchemaCatalog {
  package static let document: PortfolioSchemaDocument = {
    guard
      let url = Bundle.module.url(
        forResource: "schema_catalog", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let catalog = try? JSONDecoder().decode(
        PortfolioSchemaDocument.self, from: data),
      catalog.schemaVersion == 2
    else {
      preconditionFailure("schema_catalog.json is missing or incompatible")
    }
    return catalog
  }()
}

/// Conservative empty-result grounding. Only string literals bound to a
/// single declared entity/categorical column are eligible for correction.
public actor ResultHeuristics {
  private struct Predicate {
    var reference: String?
    var column: String
    var literals: [String]
    var literalRanges: [NSRange]
    /// Innermost query block first, followed by correlated outer scopes.
    var scopes: [SQLQueryScope]
  }

  private struct ScopedQueryBlock {
    var range: NSRange
    var scope: SQLQueryScope
  }

  private struct QuerySources {
    var scopes: [SQLQueryScope]
    var aliases: [String: String]
    var tables: Set<String>
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

  private static let schemaCatalog = PortfolioSchemaCatalog.document
  private static let queryBlockPrefixExpression = try! NSRegularExpression(
    pattern:
      #"(?is)\A\s*(?:(?:--[^\r\n]*(?:\r?\n|\z)|/\*.*?\*/)\s*)*(?:SELECT|WITH)\b"#)

  private static let tableColumns = schemaCatalog.tables.mapValues(Set.init)
  private static let foreignKeys = schemaCatalog.foreignKeys

  public init(db: DatabaseClient) {
    self.db = db
  }

  package static func repairGuidance(
    issue: SQLValidationIssue,
    sql: String,
    failedFingerprints: [String]
  ) -> RepairGuidance {
    let querySources = querySources(in: sql)
    let sources = querySources.tables.sorted()
    let expression = try? NSRegularExpression(
      pattern:
        #"(?i)(?:no such|ambiguous) column:\s*(?:([A-Za-z_][A-Za-z0-9_]*)\.)?([A-Za-z_][A-Za-z0-9_]*)"#
    )
    let range = NSRange(issue.message.startIndex..., in: issue.message)
    let match = expression?.firstMatch(in: issue.message, range: range)
    let qualifier: String? = match.flatMap { match in
      guard match.range(at: 1).location != NSNotFound else { return nil }
      return Range(match.range(at: 1), in: issue.message)
        .map { String(issue.message[$0]).lowercased() }
    }
    let column: String? = match.flatMap { match in
      Range(match.range(at: 2), in: issue.message)
        .map { String(issue.message[$0]).lowercased() }
    }
    let invalidReference = column.map { column in
      qualifier.map { "\($0).\(column)" } ?? column
    }
    let owners =
      column.map { column in
        tableColumns
          .filter { $0.value.contains(column) }
          .map(\.key)
          .sorted()
      } ?? []
    let relevantTables = Set(sources + owners)
    let relationships =
      foreignKeys
      .filter {
        relevantTables.contains($0.fromTable)
          && relevantTables.contains($0.toTable)
      }
      .map(\.description)
      .sorted()
    let sourceColumns = Dictionary(
      uniqueKeysWithValues: sources.map { table in
        (table, schemaCatalog.tables[table] ?? [])
      })
    let correctiveInstruction: String
    if let qualifier, let table = querySources.aliases[qualifier], let column,
      !querySources.scopes.contains(where: {
        $0.qualifiedColumns[qualifier]?[column] != nil
      })
    {
      let adjacentOwners = owners.filter { owner in
        foreignKeys.contains {
          ($0.fromTable == table && $0.toTable == owner)
            || ($0.toTable == table && $0.fromTable == owner)
        }
      }
      let usableOwners = adjacentOwners.isEmpty ? owners : adjacentOwners
      correctiveInstruction =
        "Do not use \(qualifier).\(column): \(qualifier) refers to \(table), which does not own that column. "
        + (usableOwners.isEmpty
          ? "Choose a column that belongs to a declared source."
          : "Use or join the owning table: \(usableOwners.joined(separator: ", ")).")
    } else if issue.message.lowercased().contains("ambiguous column"), let column {
      let declaredOwners = owners.filter(querySources.tables.contains)
      correctiveInstruction =
        "Qualify \(column) with the intended declared source alias. Declared owners: "
        + (declaredOwners.isEmpty ? "none" : declaredOwners.joined(separator: ", "))
        + "."
    } else if let column, !owners.isEmpty {
      correctiveInstruction =
        "Reference \(column) only through an owning source: \(owners.joined(separator: ", ")). Add the required join when it is not already declared."
    } else {
      correctiveInstruction =
        "Use only columns owned by declared FROM or JOIN sources and return SQL different from the failed statement."
    }
    return RepairGuidance(
      issue: issue,
      invalidReference: invalidReference,
      invalidQualifier: qualifier,
      invalidColumn: column,
      declaredSources: sources,
      possibleColumnOwners: owners,
      sourceColumns: sourceColumns,
      relevantForeignKeys: relationships,
      correctiveInstruction: correctiveInstruction,
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
            scopes: predicate.scopes)
        else {
          let reference = predicate.reference.map { "\($0)." } ?? ""
          report.skipped.append(
            .unresolvedColumn(
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
          report.checks.append(
            GroundingCheck(
              column: column, literal: literal, matched: matches))
          if !matches {
            report.findings.append(
              .literalNotFound(
                column: column,
                literal: literal,
                suggestion: Self.closestMatch(to: literal, in: values)))
          }
        } catch {
          report.degradations.append(
            GroundingDegradation(
              column: column, message: error.localizedDescription))
        }
      }
    }

    for (literal, range) in Self.allStringLiterals(in: sql)
    where !consumedLiteralRanges.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
      report.skipped.append(
        Self.classifyUnresolvedLiteral(
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
  ) -> QuerySources {
    let scopes = scopedQueryBlocks(in: sql).map(\.scope)
    var aliasesByName: [String: Set<String>] = [:]
    var tables: Set<String> = []
    for scope in scopes {
      tables.formUnion(scope.tables)
      for (alias, table) in scope.aliases {
        aliasesByName[alias, default: []].insert(table)
      }
    }
    let aliases = aliasesByName.compactMapValues { tables in
      tables.count == 1 ? tables.first : nil
    }
    return QuerySources(scopes: scopes, aliases: aliases, tables: tables)
  }

  private static func resolve(
    reference: String?,
    column: String,
    scopes: [SQLQueryScope]
  ) -> GroundingColumn? {
    let column = column.lowercased()
    if let reference {
      let reference = reference.lowercased()
      for scope in scopes {
        guard let exposed = scope.qualifiedColumns[reference] else { continue }
        return exposed[column]?.source.map {
          GroundingColumn(table: $0.table, column: $0.column)
        }
      }
      return nil
    }
    for scope in scopes {
      guard let exposed = scope.unqualifiedColumns[column] else { continue }
      guard exposed.count == 1, let source = exposed[0].source else { return nil }
      return GroundingColumn(table: source.table, column: source.column)
    }
    return nil
  }

  private static func predicates(in sql: String) -> [Predicate] {
    let blocks = scopedQueryBlocks(in: sql)
    return equalityPredicates(in: sql, blocks: blocks)
      + inPredicates(in: sql, blocks: blocks)
  }

  private static func equalityPredicates(
    in sql: String,
    blocks: [ScopedQueryBlock]
  ) -> [Predicate] {
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
        literalRanges: [match.range(at: 3)],
        scopes: scopes(containing: match.range, blocks: blocks))
    }
  }

  private static func inPredicates(
    in sql: String,
    blocks: [ScopedQueryBlock]
  ) -> [Predicate] {
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
        literalRanges: literalMatches.map { $0.range(at: 1) },
        scopes: scopes(containing: match.range, blocks: blocks))
    }
  }

  private static func scopes(
    containing range: NSRange,
    blocks: [ScopedQueryBlock]
  ) -> [SQLQueryScope] {
    blocks
      .filter { NSLocationInRange(range.location, $0.range) }
      .sorted { $0.range.length < $1.range.length }
      .map(\.scope)
  }

  /// Finds SELECT/WITH blocks without treating parentheses inside literals,
  /// quoted identifiers, or comments as SQL structure. Ranges use UTF-16 so
  /// they align with NSRegularExpression predicate matches.
  private static func scopedQueryBlocks(in sql: String) -> [ScopedQueryBlock] {
    let string = sql as NSString
    var ranges: [NSRange] = []
    let whole = NSRange(location: 0, length: string.length)
    if beginsWithQuery(in: string, range: whole) { ranges.append(whole) }

    enum ScanState {
      case normal, singleQuote, doubleQuote, backtick, bracket
      case lineComment, blockComment
    }
    var state = ScanState.normal
    var stack: [Int] = []
    var index = 0
    while index < string.length {
      let character = string.character(at: index)
      let next = index + 1 < string.length ? string.character(at: index + 1) : 0
      switch state {
      case .normal:
        if character == 0x2D, next == 0x2D {
          state = .lineComment
          index += 2
          continue
        }
        if character == 0x2F, next == 0x2A {
          state = .blockComment
          index += 2
          continue
        }
        if character == 0x27 { state = .singleQuote }
        else if character == 0x22 { state = .doubleQuote }
        else if character == 0x60 { state = .backtick }
        else if character == 0x5B { state = .bracket }
        else if character == 0x28 { stack.append(index) }
        else if character == 0x29, let open = stack.popLast() {
          let range = NSRange(
            location: open + 1,
            length: max(0, index - open - 1))
          if beginsWithQuery(in: string, range: range) { ranges.append(range) }
        }
      case .singleQuote:
        if character == 0x27 {
          if next == 0x27 {
            index += 2
            continue
          }
          state = .normal
        }
      case .doubleQuote:
        if character == 0x22 {
          if next == 0x22 {
            index += 2
            continue
          }
          state = .normal
        }
      case .backtick:
        if character == 0x60 {
          if next == 0x60 {
            index += 2
            continue
          }
          state = .normal
        }
      case .bracket:
        if character == 0x5D {
          if next == 0x5D {
            index += 2
            continue
          }
          state = .normal
        }
      case .lineComment:
        if character == 0x0A || character == 0x0D { state = .normal }
      case .blockComment:
        if character == 0x2A, next == 0x2F {
          state = .normal
          index += 2
          continue
        }
      }
      index += 1
    }

    return ranges.map { range in
      let blockSQL = string.substring(with: range)
      return ScopedQueryBlock(
        range: range,
        scope: SQLQueryAnalyzer.scope(in: blockSQL))
    }
  }

  private static func beginsWithQuery(
    in string: NSString,
    range: NSRange
  ) -> Bool {
    let substring = string.substring(with: range)
    let substringRange = NSRange(location: 0, length: (substring as NSString).length)
    return queryBlockPrefixExpression.firstMatch(
      in: substring, range: substringRange) != nil
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
