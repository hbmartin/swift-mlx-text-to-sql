import Foundation

/// A deterministic finding from the result-shape + value-grounding heuristics
/// (correction layer A). Always on; catches the #1 silent-failure mode —
/// a valid query that quietly matched nothing.
public enum HeuristicFinding: Sendable, Equatable, Codable {
  /// The result was empty and a string literal in the SQL matches no known
  /// entity value; `suggestion` is the closest real value if one is close.
  case literalNotFound(literal: String, suggestion: String?)
  /// The result was empty with no literal to blame.
  case emptyResult
  /// A single-row result whose cells are all NULL (degenerate aggregate).
  case nullScalar

  public var userNotice: String {
    switch self {
    case .literalNotFound(let literal, let suggestion?):
      "Nothing matched “\(literal)” — did you mean “\(suggestion)”?"
    case .literalNotFound(let literal, nil):
      "Nothing in the portfolio matched “\(literal)”."
    case .emptyResult:
      "No rows matched — a filter may be too narrow."
    case .nullScalar:
      "That calculation came back empty — the filter may not match anything."
    }
  }
}

/// Result-shape and value-grounding checks over an executed query.
///
/// The entity catalog (names, markets, lenders…) is loaded once from the
/// read-only portfolio DB and cached; fuzzy matching is plain edit distance.
public actor ResultHeuristics {
  private let db: DatabaseClient
  private var catalog: [String]?

  /// Columns whose values user questions typically reference by name.
  static let catalogColumns: [(table: String, column: String)] = [
    ("properties", "name"), ("tenants", "name"), ("funds", "name"),
    ("properties", "market"), ("properties", "submarket"),
    ("properties", "city"), ("loans", "lender"), ("valuations", "appraiser"),
  ]

  public init(db: DatabaseClient) {
    self.db = db
  }

  public func inspect(sql: String, result: QueryResult) async -> [HeuristicFinding] {
    if result.rows.count == 1, result.rows[0].allSatisfy({ $0 == .null }) {
      return [.nullScalar]
    }
    guard result.rows.isEmpty else { return [] }

    let values = await loadCatalog()
    let lowered = Set(values.map { $0.lowercased() })
    for literal in Self.stringLiterals(in: sql) {
      if lowered.contains(literal.lowercased()) { continue }
      let suggestion = Self.closestMatch(to: literal, in: values)
      return [.literalNotFound(literal: literal, suggestion: suggestion)]
    }
    return [.emptyResult]
  }

  /// Quoted literals worth entity-checking: not dates, not enum-ish shorties.
  static func stringLiterals(in sql: String) -> [String] {
    let matches = sql.matches(of: #/'([^']*)'/#)
    return matches.map { String($0.1) }.filter { literal in
      literal.count >= 3
        && literal.wholeMatch(of: #/[\d\-%\.]+/#) == nil  // dates, numbers, LIKE scraps
    }
  }

  static func closestMatch(to literal: String, in values: [String]) -> String? {
    let target = literal.lowercased()
    var best: (value: String, distance: Int)?
    for value in values {
      let candidate = value.lowercased()
      // cheap prefix/containment wins before edit distance
      if candidate.hasPrefix(target) || candidate.contains(target) {
        return value
      }
      let distance = editDistance(target, candidate)
      if best == nil || distance < best!.distance {
        best = (value, distance)
      }
    }
    guard let best else { return nil }
    // accept only near misses: allow ~1 edit per 4 characters
    return best.distance <= max(2, literal.count / 4) ? best.value : nil
  }

  static func editDistance(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    var row = Array(0...b.count)
    for i in 1...max(a.count, 1) where !a.isEmpty {
      var previous = row[0]
      row[0] = i
      for j in 1...b.count {
        let insertOrDelete = min(row[j], row[j - 1]) + 1
        let substitute = previous + (a[i - 1] == b[j - 1] ? 0 : 1)
        previous = row[j]
        row[j] = min(insertOrDelete, substitute)
      }
    }
    return row[b.count]
  }

  private func loadCatalog() async -> [String] {
    if let catalog { return catalog }
    var values: [String] = []
    for (table, column) in Self.catalogColumns {
      let sql = "SELECT DISTINCT \(column) FROM \(table) WHERE \(column) IS NOT NULL"
      guard let result = try? await db.execute(sql) else { continue }
      values.append(contentsOf: result.rows.compactMap {
        if case .text(let s) = $0.first { s } else { nil }
      })
    }
    catalog = values
    return values
  }
}
