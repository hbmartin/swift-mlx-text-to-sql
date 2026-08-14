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
    let projections = CREGChartAdapter.alignedProjections(
      sql, columnCount: result.columns.count)
    let columns = result.columns.enumerated().map { index, name in
      AutoChartColumn(
        id: CREGChartAdapter.columnID(index: index, name: name),
        name: name,
        hints: CREGChartAdapter.hints(
          for: name,
          projection: projections[index],
          values: result.rows.map { row in
            row.indices.contains(index) ? row[index] : .null
          }))
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
    projection: String?,
    values: [SQLValue] = []
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
    let style = PortfolioValueFormatting.style(forColumn: normalized)
    if style == .date, hasValidTemporalValues(values) {
      let role: AutoChartAnalyticRole =
        containsWord(normalized, [
          "commencement", "origination", "acquisition", "inception", "start",
        ])
        ? .intervalStart
        : containsWord(normalized, [
          "expiration", "maturity", "disposition", "end", "period_end",
        ])
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
    if style == .percent, values.isEmpty || hasQuantitativeValues(values) {
      return AutoChartColumnHints(
        semanticType: .quantitative,
        role: .measure,
        unit: percentUnit(for: values),
        aggregation: aggregation,
        aggregationSafety: safety)
    }
    if (style == .currency || style == .currencyPerSquareFoot),
      values.isEmpty || hasQuantitativeValues(values)
    {
      return AutoChartColumnHints(
        semanticType: .quantitative,
        role: .measure,
        unit: .currency(code: "USD"),
        aggregation: aggregation,
        aggregationSafety: safety)
    }
    if style == .squareFeet, values.isEmpty || hasQuantitativeValues(values) {
      return AutoChartColumnHints(
        semanticType: .quantitative,
        role: .measure,
        unit: .area(unit: "sq ft"),
        aggregation: aggregation,
        aggregationSafety: safety)
    }
    if style == .count, containsWord(normalized, ["month", "months"]),
      values.isEmpty || hasQuantitativeValues(values)
    {
      return AutoChartColumnHints(
        semanticType: .quantitative,
        role: .measure,
        unit: .duration(unit: "months"),
        aggregation: aggregation,
        aggregationSafety: safety)
    }
    if style == .ratio, values.isEmpty || hasQuantitativeValues(values) {
      return AutoChartColumnHints(
        semanticType: .quantitative,
        role: .measure,
        aggregation: aggregation,
        aggregationSafety: safety)
    }
    if style == .plainDigits, containsWord(normalized, ["year"]) {
      return AutoChartColumnHints(
        semanticType: .ordinal,
        role: .dimension,
        aggregation: aggregation,
        aggregationSafety: safety)
    }
    return AutoChartColumnHints(
      aggregation: aggregation,
      aggregationSafety: safety)
  }

  static func goal(question: String?, sql: String) -> AutoChartGoal {
    let questionGoal = classifiedGoal(in: (question ?? "").lowercased())
    guard questionGoal == .overview else { return questionGoal }
    return classifiedGoal(in: "\(question ?? "") \(sql)".lowercased())
  }

  private static func classifiedGoal(in text: String) -> AutoChartGoal {
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
    let tokens = sqlTokens(in: projection)
    guard !tokens.contains(.word("over")) else { return nil }
    for index in tokens.indices {
      guard case .word(let name) = tokens[index],
        index + 1 < tokens.count,
        tokens[index + 1] == .symbol("(")
      else { continue }
      switch name {
      case "sum": return .sum
      case "avg": return .mean
      case "min": return .minimum
      case "max": return .maximum
      case "count":
        if index + 2 < tokens.count, tokens[index + 2] == .word("distinct") {
          return .countDistinct
        }
        return .count
      default: continue
      }
    }
    return nil
  }

  static func alignedProjections(
    _ sql: String,
    columnCount: Int
  ) -> [String?] {
    let projections = topLevelProjections(sql)
    guard projections.count == columnCount,
      !projections.contains(where: isWildcardProjection)
    else { return Array(repeating: nil, count: columnCount) }
    return projections.map(Optional.some)
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
      if character == "-", index + 1 < characters.count,
        characters[index + 1] == "-"
      {
        index += 2
        while index < characters.count, !characters[index].isNewline {
          index += 1
        }
        continue
      }
      if character == "/", index + 1 < characters.count,
        characters[index + 1] == "*"
      {
        index += 2
        while index + 1 < characters.count,
          !(characters[index] == "*" && characters[index + 1] == "/")
        {
          index += 1
        }
        index = min(index + 2, characters.count)
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
      if character == "-", index + 1 < characters.count,
        characters[index + 1] == "-"
      {
        index += 2
        while index < characters.count, !characters[index].isNewline {
          index += 1
        }
        continue
      }
      if character == "/", index + 1 < characters.count,
        characters[index + 1] == "*"
      {
        index += 2
        while index + 1 < characters.count,
          !(characters[index] == "*" && characters[index + 1] == "/")
        {
          index += 1
        }
        index = min(index + 2, characters.count)
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
      index += 1
    }
    if start < characters.count {
      output.append(String(characters[start...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return output
  }

  static func parseISODate(
    _ text: String,
    calendar: Calendar = gregorianGMTCalendar
  ) -> Date? {
    let parts = text.split(
      separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
    if parts.count == 3,
      parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
      parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
      let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
    {
      let localCalendar = calendar
      let components = DateComponents(year: year, month: month, day: day)
      guard components.isValidDate(in: localCalendar) else { return nil }
      return localCalendar.date(from: components)
    }
    return try? Date(text, strategy: .iso8601)
  }

  private enum SQLToken: Equatable {
    case word(String)
    case symbol(Character)
  }

  private static func sqlTokens(in sql: String) -> [SQLToken] {
    let characters = Array(sql)
    var tokens: [SQLToken] = []
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if character.isWhitespace {
        index += 1
        continue
      }
      if character == "-", index + 1 < characters.count,
        characters[index + 1] == "-"
      {
        index += 2
        while index < characters.count, !characters[index].isNewline {
          index += 1
        }
        continue
      }
      if character == "/", index + 1 < characters.count,
        characters[index + 1] == "*"
      {
        index += 2
        while index + 1 < characters.count,
          !(characters[index] == "*" && characters[index + 1] == "/")
        {
          index += 1
        }
        index = min(index + 2, characters.count)
        continue
      }
      if character == "'" || character == "\"" || character == "`"
        || character == "["
      {
        let closing: Character = character == "[" ? "]" : character
        index += 1
        while index < characters.count {
          guard characters[index] == closing else {
            index += 1
            continue
          }
          if index + 1 < characters.count, characters[index + 1] == closing {
            index += 2
            continue
          }
          index += 1
          break
        }
        continue
      }
      if character.isLetter || character == "_" {
        let start = index
        index += 1
        while index < characters.count,
          characters[index].isLetter || characters[index].isNumber
            || characters[index] == "_" || characters[index] == "$"
        {
          index += 1
        }
        tokens.append(.word(String(characters[start..<index]).lowercased()))
        continue
      }
      tokens.append(.symbol(character))
      index += 1
    }
    return tokens
  }

  private static func isWildcardProjection(_ projection: String) -> Bool {
    let tokens = sqlTokens(in: projection)
    if tokens == [.symbol("*")] { return true }
    return tokens.count >= 2
      && Array(tokens.suffix(2)) == [.symbol("."), .symbol("*")]
  }

  private static func hasValidTemporalValues(_ values: [SQLValue]) -> Bool {
    let nonNull = values.filter { if case .null = $0 { false } else { true } }
    guard !nonNull.isEmpty else { return false }
    let validCount = nonNull.reduce(into: 0) { count, value in
      guard case .text(let text) = value, parseISODate(text) != nil else { return }
      count += 1
    }
    return validCount == nonNull.count
      || (validCount >= 2 && Double(validCount) / Double(nonNull.count) >= 0.8)
  }

  private static func hasQuantitativeValues(_ values: [SQLValue]) -> Bool {
    let nonNull = values.filter { if case .null = $0 { false } else { true } }
    guard !nonNull.isEmpty else { return false }
    return nonNull.allSatisfy { value in
      switch value {
      case .integer, .real: true
      case .null, .text, .blob: false
      }
    }
  }

  private static func percentUnit(
    for values: [SQLValue]
  ) -> AutoChartUnit? {
    let numeric = values.compactMap { value -> Double? in
      switch value {
      case .integer(let value): Double(value)
      case .real(let value): value
      case .null, .text, .blob: nil
      }
    }
    guard !numeric.isEmpty else { return .percent(fractional: true) }
    let fractional = numeric.allSatisfy { abs($0) <= 1.5 }
    let pointScaled = numeric.allSatisfy { abs($0) > 1.5 }
    guard fractional || pointScaled else { return nil }
    return .percent(fractional: fractional)
  }

  private static func containsWord(_ value: String, _ words: [String]) -> Bool {
    words.contains { PortfolioValueFormatting.containsWord(value, word: $0) }
  }

  private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
    needles.contains { value.contains($0) }
  }

  private static let gregorianGMTCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar
  }()
}
