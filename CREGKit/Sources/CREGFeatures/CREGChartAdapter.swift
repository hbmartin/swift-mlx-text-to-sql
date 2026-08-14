import AutoTableCharts
import CREGEngine
import Foundation

struct CREGChartRow: AutoChartRow {
  var chartRowID: AutoChartRowID
  var values: [AutoChartColumnID: AutoChartValue]

  func chartValue(for columnID: AutoChartColumnID) -> AutoChartValue {
    values[columnID] ?? .null
  }
}

struct CREGChartTable: AutoChartTable {
  var chartColumns: [AutoChartColumn]
  var chartRows: [CREGChartRow]
  var chartMetadata: AutoChartTableMetadata
  var context: AutoChartContext

  init(result: QueryResult, sql: String, question: String?) {
    let projections = CREGChartAdapter.topLevelProjections(sql)
    let columns = result.columns.enumerated().map { index, name in
      AutoChartColumn(
        id: CREGChartAdapter.columnID(index: index, name: name),
        name: name,
        hints: CREGChartAdapter.hints(
          for: name,
          projection: projections.indices.contains(index) ? projections[index] : nil))
    }
    chartColumns = columns
    chartRows = result.rows.enumerated().map { rowIndex, row in
      let values = Dictionary(
        uniqueKeysWithValues: columns.enumerated().map { columnIndex, column in
          let value = row.indices.contains(columnIndex) ? row[columnIndex] : .null
          return (
            column.id,
            CREGChartAdapter.value(
              value,
              temporal: column.hints.semanticType == .temporal))
        })
      return CREGChartRow(
        chartRowID: AutoChartRowID(rawValue: "row-\(rowIndex)"),
        values: values)
    }
    chartMetadata = AutoChartTableMetadata(
      isTruncated: result.isTruncated,
      provenance: "CREG query result")
    context = AutoChartContext(
      goal: CREGChartAdapter.goal(question: question, sql: sql),
      title: question)
  }

  func sourceRowIndexes(for selection: AutoChartSelection?) -> Set<Int>? {
    guard let selection else { return nil }
    return Set(selection.sourceRowIDs.compactMap { id in
      guard id.rawValue.hasPrefix("row-") else { return nil }
      return Int(id.rawValue.dropFirst(4))
    })
  }
}

enum CREGChartAdapter {
  static func recommendations(
    result: QueryResult,
    sql: String,
    question: String?
  ) -> (table: CREGChartTable, set: AutoChartRecommendationSet) {
    let table = CREGChartTable(result: result, sql: sql, question: question)
    return (
      table,
      AutoChartEngine.recommendations(for: table, context: table.context))
  }

  static func columnID(index: Int, name: String) -> AutoChartColumnID {
    let slug = name.lowercased().map { character in
      character.isLetter || character.isNumber ? character : "-"
    }
    return AutoChartColumnID(rawValue: "c\(index)-\(String(slug))")
  }

  static func resolvedRecommendation(
    preferredID: String?,
    in recommendations: [AutoChartRecommendation]
  ) -> AutoChartRecommendation? {
    if let preferredID,
      let persisted = recommendations.first(where: { $0.id == preferredID })
    {
      return persisted
    }
    return recommendations.first
  }

  static func value(_ value: SQLValue, temporal: Bool) -> AutoChartValue {
    switch value {
    case .null: .null
    case .integer(let value): .integer(value)
    case .real(let value): .double(value)
    case .text(let value):
      if temporal, let date = parseISODate(value) { .date(date) }
      else { .text(value) }
    case .blob(let value): .binary(value)
    }
  }

  static func hints(
    for name: String,
    projection: String?
  ) -> AutoChartColumnHints {
    let normalized = name.lowercased()
    let aggregation = aggregate(in: projection)
    let safety: AutoChartAggregationSafety = aggregation == nil
      ? .unknown : .alreadyAggregated

    if normalized == "id" || normalized.hasSuffix("_id") {
      return AutoChartColumnHints(
        semanticType: .identifier,
        role: .identifier,
        aggregation: aggregation,
        aggregationSafety: .unsafe)
    }
    if isDate(normalized) {
      let role: AutoChartAnalyticRole =
        normalized.contains("commencement") || normalized.contains("origination")
        || normalized.contains("acquisition") || normalized.contains("start")
        ? .intervalStart
        : normalized.contains("expiration") || normalized.contains("maturity")
          || normalized.contains("disposition") || normalized.contains("end")
          ? .intervalEnd : .dimension
      return AutoChartColumnHints(
        semanticType: .temporal,
        role: role,
        aggregation: aggregation,
        aggregationSafety: safety)
    }
    if normalized.hasPrefix("is_") || normalized.hasPrefix("has_") {
      return AutoChartColumnHints(
        semanticType: .boolean,
        role: .dimension,
        aggregation: aggregation,
        aggregationSafety: safety)
    }
    if normalized.contains("year") {
      return AutoChartColumnHints(
        semanticType: .ordinal,
        role: .dimension,
        aggregation: aggregation,
        aggregationSafety: safety)
    }
    if isPercent(normalized) {
      return AutoChartColumnHints(
        semanticType: .quantitative,
        role: .measure,
        unit: .percent(fractional: true),
        aggregation: aggregation,
        aggregationSafety: safety)
    }
    if isCurrency(normalized) {
      return AutoChartColumnHints(
        semanticType: .quantitative,
        role: .measure,
        unit: .currency(code: "USD"),
        aggregation: aggregation,
        aggregationSafety: safety)
    }
    if normalized.contains("sqft") || normalized.contains("square_feet") {
      return AutoChartColumnHints(
        semanticType: .quantitative,
        role: .measure,
        unit: .area(unit: "sq ft"),
        aggregation: aggregation,
        aggregationSafety: safety)
    }
    if normalized.contains("months") {
      return AutoChartColumnHints(
        semanticType: .quantitative,
        role: .measure,
        unit: .duration(unit: "months"),
        aggregation: aggregation,
        aggregationSafety: safety)
    }
    return AutoChartColumnHints(
      aggregation: aggregation,
      aggregationSafety: safety)
  }

  static func goal(question: String?, sql: String) -> AutoChartGoal {
    let text = "\(question ?? "") \(sql)".lowercased()
    if containsAny(text, ["outlier", "unusual", "anomal"]) { return .outlier }
    if containsAny(text, ["correlat", "relationship", "related", " versus ", " vs "]) {
      return .relationship
    }
    if containsAny(text, ["trend", "over time", "history", "growth", "change over"]) {
      return .trend
    }
    if containsAny(text, ["expir", "matur", "upcoming", "between", "next 12", "next 24"]) {
      return .range
    }
    if containsAny(text, ["share", "mix", "portion", "composition", "percent of", "breakdown"]) {
      return .composition
    }
    if containsAny(text, ["highest", "lowest", "top ", "bottom ", "rank", "order by"]) {
      return .ranking
    }
    if containsAny(text, ["distribution", "spread", "histogram"]) { return .distribution }
    if containsAny(text, ["compare", " by ", "group by"]) { return .comparison }
    return .overview
  }

  static func aggregate(in projection: String?) -> AutoChartAggregation? {
    guard let projection else { return nil }
    let compact = projection.lowercased().filter { !$0.isWhitespace }
    if compact.contains("sum(") { return .sum }
    if compact.contains("avg(") { return .mean }
    if compact.contains("min(") { return .minimum }
    if compact.contains("max(") { return .maximum }
    if compact.contains("count(distinct") { return .countDistinct }
    if compact.contains("count(") { return .count }
    return nil
  }

  static func topLevelProjections(_ sql: String) -> [String] {
    let characters = Array(sql)
    var depth = 0
    var quote: Character?
    var selectStart: Int?
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if let activeQuote = quote {
        if character == activeQuote {
          if index + 1 < characters.count, characters[index + 1] == activeQuote {
            index += 2
            continue
          }
          quote = nil
        }
        index += 1
        continue
      }
      if character == "'" || character == "\"" || character == "`" {
        quote = character
        index += 1
        continue
      }
      if character == "[" { quote = "]"; index += 1; continue }
      if character == "(" { depth += 1; index += 1; continue }
      if character == ")" { depth = max(0, depth - 1); index += 1; continue }
      if depth == 0, character.isLetter {
        let wordStart = index
        while index < characters.count,
          characters[index].isLetter || characters[index] == "_"
        {
          index += 1
        }
        let word = String(characters[wordStart..<index]).lowercased()
        if word == "select" {
          selectStart = index
        } else if word == "from", let start = selectStart {
          return splitTopLevel(String(characters[start..<wordStart]))
        }
        continue
      }
      index += 1
    }
    return []
  }

  private static func splitTopLevel(_ text: String) -> [String] {
    let characters = Array(text)
    var output: [String] = []
    var depth = 0
    var quote: Character?
    var start = 0
    for index in characters.indices {
      let character = characters[index]
      if let activeQuote = quote {
        if character == activeQuote { quote = nil }
        continue
      }
      if character == "'" || character == "\"" || character == "`" {
        quote = character
      } else if character == "[" {
        quote = "]"
      } else if character == "(" {
        depth += 1
      } else if character == ")" {
        depth = max(0, depth - 1)
      } else if character == ",", depth == 0 {
        output.append(String(characters[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines))
        start = index + 1
      }
    }
    if start < characters.count {
      output.append(String(characters[start...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return output
  }

  private static func parseISODate(_ text: String) -> Date? {
    if let date = try? Date(text, strategy: .iso8601) { return date }
    let parts = text.split(separator: "-")
    guard parts.count == 3,
      let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
    else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(year: year, month: month, day: day))
  }

  private static func isDate(_ name: String) -> Bool {
    name.contains("date") || name.contains("period_end")
      || name.contains("commencement") || name.contains("expiration")
      || name.contains("maturity") || name.contains("origination")
  }

  private static func isPercent(_ name: String) -> Bool {
    name.hasSuffix("_pct") || name.hasSuffix("_rate")
      || ["ltv", "occupancy", "occupancy_rate", "vacancy", "vacancy_rate",
        "ownership_pct", "target_irr", "cap_rate", "interest_rate"].contains(name)
  }

  private static func isCurrency(_ name: String) -> Bool {
    containsAny(name, [
      "price", "value", "balance", "rent", "income", "expense", "capital",
      "deposit", "allowance", "capex", "debt_service", "noi",
    ])
  }

  private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
    needles.contains { value.contains($0) }
  }
}
