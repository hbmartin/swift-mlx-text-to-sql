import AutoTableCharts
import CREGEngine
import Foundation

struct CREGChartAnalysisInput: Sendable {
  var dataset: AutoChartDataset<Int>
  var context: AutoChartContext
}

enum CREGChartAdapter {
  /// The one chart-data identity for a transcript message, shared by the
  /// inline preview and the full-screen viewer so analyzer caching keys off
  /// the same string everywhere.
  static func resultDataIdentity(messageID: UUID) -> String {
    "CREG.Result.v2:\(messageID.uuidString.lowercased())"
  }

  static func analysisInput(
    result: QueryResult,
    sql: String,
    question: String?,
    resultFingerprint: String? = nil,
    dataIdentity: String? = nil
  ) throws -> CREGChartAnalysisInput {
    let projections = alignedProjections(
      sql, columnCount: result.columns.count)
    let columns = result.columns.enumerated().map { index, name in
      AutoChartColumn(
        id: columnID(index: index, name: name),
        name: name,
        hints: hints(
          for: name,
          projection: projections[index],
          values: result.rows.map { row in
            row.indices.contains(index) ? row[index] : .null
          }))
    }
    // Pad (or clamp) every row to the column count: a ragged row otherwise
    // makes the dataset initializer throw and silently disables charts for
    // the whole result, while the hints above already treat the missing
    // cells as null.
    let rows = result.rows.map { row in
      result.columns.indices.map { columnIndex in
        CREGChartAdapter.value(
          row.indices.contains(columnIndex) ? row[columnIndex] : .null,
          temporal: columns[columnIndex].hints.semanticType == .temporal)
      }
    }
    let fingerprint = resultFingerprint
      ?? PreparedFollowUpIntegrity.fingerprint(result: result)
    let dataset = try AutoChartDataset<Int>(
      columns: columns,
      rows: rows,
      metadata: AutoChartTableMetadata(
        isTruncated: result.isTruncated,
        provenance: "CREG query result"),
      key: AutoChartDataKey(
        identity: dataIdentity ?? "CREG.Result.v2:\(fingerprint)",
        revision: dataKeyRevision(resultFingerprint: fingerprint, sql: sql)))
    return CREGChartAnalysisInput(
      dataset: dataset,
      context: analysisContext(question: question, sql: sql))
  }

  static func analysisContext(
    question: String?,
    sql: String
  ) -> AutoChartContext {
    AutoChartContext(
      goal: goal(question: question, sql: sql),
      title: question)
  }

  static let formatters = AutoChartFormatters(
    locale: Locale(identifier: "en_US"),
    timeZone: .gmt,
    request: { request, _, _ in
      switch request.purpose {
      case .aggregatedMeasure(.count), .aggregatedMeasure(.countDistinct),
        .normalizedFraction:
        // Let AutoTableCharts format dimensionless chart-generated values.
        return nil
      case .value, .aggregatedMeasure:
        break
      }
      guard let column = request.column else { return nil }
      let sqlValue: SQLValue
      switch request.value {
      case .null: sqlValue = .null
      case .boolean(let value): sqlValue = .integer(value ? 1 : 0)
      case .integer(let value): sqlValue = .integer(value)
      case .double(let value): sqlValue = .real(value)
      case .decimal(let value): sqlValue = .real(NSDecimalNumber(decimal: value).doubleValue)
      case .text(let value): sqlValue = .text(value)
      case .date(let value):
        let components = gregorianGMTCalendar.dateComponents([.year, .month, .day], from: value)
        guard let year = components.year, let month = components.month, let day = components.day
        else { return nil }
        sqlValue = .text(String(format: "%04d-%02d-%02d", year, month, day))
      case .binary(let value): sqlValue = .blob(value)
      }
      return PortfolioValueFormatting.displayString(for: sqlValue, column: column.name)
    })

  /// App-reviewed copy shared by preparation diagnostics and selection,
  /// prepared chart chrome, and recommendation rationale. Returning nil keeps
  /// AutoTableCharts' default text for codes CREG has not explicitly adapted.
  static let textResolver = AutoChartTextResolver { message -> String? in
    switch message.code {
    case .boxPlotMissingCategoryGroup
    where message.category == .diagnostic && message.arguments.isEmpty:
      return "Some category values couldn’t be displayed and are grouped as “Missing value”."
    default:
      return nil
    }
  }

  static func dataKeyRevision(
    resultFingerprint: String,
    sql: String
  ) -> String {
    [
      "CREG.ChartData.v2",
      resultFingerprint,
      PreparedFollowUpIntegrity.fingerprint(sql: sql),
    ].joined(separator: ":")
  }

  static func columnID(index: Int, name: String) -> AutoChartColumnID {
    let slug = name.lowercased().map { character in
      character.isLetter || character.isNumber ? character : "-"
    }
    return AutoChartColumnID(rawValue: "c\(index)-\(String(slug))")
  }

  static func value(_ value: SQLValue, temporal: Bool) -> AutoChartValue {
    switch value {
    case .null: .null
    case .integer(let value): .integer(value)
    case .real(let value): .double(value)
    case .text(let value):
      if temporal, let date = parseISODate(value) { .date(date) } else { .text(value) }
    case .blob(let value): .binary(value)
    }
  }

  static func hints(
    for name: String,
    projection: String?,
    values: @autoclosure () -> [SQLValue] = []
  ) -> AutoChartColumnHints {
    let normalized = name.lowercased()
    let aggregation = aggregate(in: projection)

    if normalized == "id" || normalized.hasSuffix("_id") {
      return AutoChartColumnHints(
        semanticType: .identifier,
        role: .identifier)
    }
    let style = PortfolioValueFormatting.style(forColumn: normalized)
    if style == .date {
      let temporalValues = values()
      guard temporalValues.isEmpty || hasValidTemporalValues(temporalValues) else {
        return AutoChartColumnHints(
          measureSemantics: measureSemantics(for: aggregation))
      }
      let role: AutoChartAnalyticRole =
        containsWord(
          normalized,
          [
            "commencement", "origination", "acquisition", "inception", "start",
          ])
        ? .intervalStart
        : containsWord(
          normalized,
          [
            "expiration", "maturity", "disposition", "end",
          ])
          ? .intervalEnd : .dimension
      return AutoChartColumnHints(
        semanticType: .temporal,
        role: role)
    }
    if normalized.hasPrefix("is_") || normalized.hasPrefix("has_") {
      // SQLite permits mixed storage classes in one result column. Do not force
      // opaque bytes into a categorical identity that charting would collapse
      // into the same missing group as SQL NULL.
      guard !containsBlob(values()) else {
        return AutoChartColumnHints(
          measureSemantics: measureSemantics(for: aggregation))
      }
      return AutoChartColumnHints(
        semanticType: .boolean,
        role: .dimension)
    }
    if style == .percent {
      let sourceValues = values()
      return quantitativeHints(
        values: sourceValues,
        unit: percentUnit(for: sourceValues),
        aggregation: aggregation)
    }
    if style == .currency || style == .currencyPerSquareFoot {
      return quantitativeHints(
        values: values(),
        unit: .currency(code: "USD"),
        aggregation: aggregation)
    }
    if style == .squareFeet {
      return quantitativeHints(
        values: values(),
        unit: .area(unit: "sq ft"),
        aggregation: aggregation)
    }
    if style == .count, containsWord(normalized, ["month", "months"]) {
      return quantitativeHints(
        values: values(),
        unit: .duration(unit: "months"),
        aggregation: aggregation)
    }
    if style == .ratio {
      return quantitativeHints(
        values: values(),
        aggregation: aggregation)
    }
    if style == .plainDigits, containsWord(normalized, ["year"]) {
      guard !containsBlob(values()) else {
        return AutoChartColumnHints(
          measureSemantics: measureSemantics(for: aggregation))
      }
      return AutoChartColumnHints(
        semanticType: .ordinal,
        role: .dimension)
    }
    return AutoChartColumnHints(
      measureSemantics: measureSemantics(for: aggregation))
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
    var selectStart: Int?
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if let next = skippingComment(characters, from: index) {
        index = next
        continue
      }
      if let next = skippingQuotedRegion(characters, from: index) {
        index = next
        continue
      }
      if character == "(" {
        depth += 1
        index += 1
        continue
      }
      if character == ")" {
        depth = max(0, depth - 1)
        index += 1
        continue
      }
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
    var start = 0
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if let next = skippingComment(characters, from: index) {
        index = next
        continue
      }
      if let next = skippingQuotedRegion(characters, from: index) {
        index = next
        continue
      }
      if character == "(" {
        depth += 1
      } else if character == ")" {
        depth = max(0, depth - 1)
      } else if character == ",", depth == 0 {
        output.append(
          String(characters[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines))
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
      if let next = skippingComment(characters, from: index) {
        index = next
        continue
      }
      if let next = skippingQuotedRegion(characters, from: index) {
        index = next
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

  /// Advances past a SQL line or block comment beginning at `index`.
  private static func skippingComment(
    _ characters: [Character], from index: Int
  ) -> Int? {
    guard index + 1 < characters.count else { return nil }
    if characters[index] == "-", characters[index + 1] == "-" {
      var next = index + 2
      while next < characters.count, !characters[next].isNewline { next += 1 }
      return next
    }
    if characters[index] == "/", characters[index + 1] == "*" {
      var next = index + 2
      while next + 1 < characters.count,
        !(characters[next] == "*" && characters[next + 1] == "/")
      {
        next += 1
      }
      return min(next + 2, characters.count)
    }
    return nil
  }

  /// Advances past a quoted value or quoted/bracketed identifier, including
  /// SQL's doubled-delimiter escaping. Returns nil when `index` is unquoted.
  private static func skippingQuotedRegion(
    _ characters: [Character], from index: Int
  ) -> Int? {
    guard let closing = closingDelimiter(for: characters[index]) else {
      return nil
    }
    var next = index + 1
    while next < characters.count {
      guard characters[next] == closing else {
        next += 1
        continue
      }
      if next + 1 < characters.count, characters[next + 1] == closing {
        next += 2
        continue
      }
      return next + 1
    }
    return characters.count
  }

  private static func closingDelimiter(for character: Character) -> Character? {
    switch character {
    case "'", "\"", "`": character
    case "[": "]"
    default: nil
    }
  }

  private static func hasValidTemporalValues(_ values: [SQLValue]) -> Bool {
    // SQL NULL is genuinely absent. BLOBs are present but opaque to charting,
    // so they must consume the same invalid-value budget as malformed scalars.
    let nonNull = values.filter { if case .null = $0 { false } else { true } }
    guard !nonNull.isEmpty else { return false }
    let validCount = nonNull.reduce(into: 0) { count, value in
      guard case .text(let text) = value, parseISODate(text) != nil else { return }
      count += 1
    }
    return validCount == nonNull.count
      || (validCount >= 2
        && Double(validCount) / Double(nonNull.count) >= 0.8)
  }

  private static func containsBlob(_ values: [SQLValue]) -> Bool {
    values.contains { value in
      if case .blob = value { true } else { false }
    }
  }

  private static func quantitativeHints(
    values: [SQLValue],
    unit: AutoChartUnit? = nil,
    aggregation: AutoChartAggregation?
  ) -> AutoChartColumnHints {
    guard values.isEmpty || hasQuantitativeValues(values) else {
      return AutoChartColumnHints(
        measureSemantics: measureSemantics(for: aggregation))
    }
    return AutoChartColumnHints(
      semanticType: .quantitative,
      role: .measure,
      unit: unit,
      measureSemantics: measureSemantics(for: aggregation))
  }

  private static func measureSemantics(
    for aggregation: AutoChartAggregation?
  ) -> AutoChartMeasureSemantics {
    guard let aggregation else {
      return AutoChartMeasureSemantics(source: .rowLevel, rollup: .unknown)
    }
    let rollup: AutoChartRollupPolicy =
      switch aggregation {
      case .sum, .count: .additive
      case .minimum: .safe(.minimum)
      case .maximum: .safe(.maximum)
      case .mean, .countDistinct, .none: .nonAdditive
      }
    return AutoChartMeasureSemantics(
      source: .aggregated(aggregation),
      rollup: rollup,
      preferredTransform: aggregation)
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
    // Zero carries no scale information, so it never decides the unit.
    let scaled = numeric.filter { $0 != 0 }
    guard !scaled.isEmpty else { return .percent(fractional: true) }
    let fractional = scaled.allSatisfy { abs($0) <= 1.5 }
    let pointScaled = scaled.allSatisfy { abs($0) > 1.5 }
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
