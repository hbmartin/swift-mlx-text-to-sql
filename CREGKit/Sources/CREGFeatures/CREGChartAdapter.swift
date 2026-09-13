import AutoTableCharts
import CREGData
import CREGEngine
import Foundation

enum CREGChartAdapter {
  /// The one chart-data identity for a transcript message, shared by the
  /// inline preview and the full-screen viewer so analyzer caching keys off
  /// the same string everywhere.
  static func resultDataIdentity(messageID: UUID) -> String {
    "CREG.Result.v3:\(messageID.uuidString.lowercased())"
  }

  static func analysisRequest(
    result: QueryResult,
    sql: String,
    question: String?,
    resultFingerprint: String? = nil,
    dataIdentity: String? = nil
  ) throws -> AutoChartRequest<Int> {
    let dataset = try analysisDataset(
      result: result,
      sql: sql,
      resultFingerprint: resultFingerprint,
      dataIdentity: dataIdentity)
    return try AutoChartRequest(
      table: dataset,
      context: analysisContext(question: question, sql: sql))
  }

  /// Exposed internally so adapter tests can verify CREG's row normalization,
  /// semantic hints, and stable data identity without retaining a duplicate
  /// dataset alongside every production request.
  static func analysisDataset(
    result: QueryResult,
    sql: String,
    resultFingerprint: String? = nil,
    dataIdentity: String? = nil
  ) throws -> AutoChartDataset<Int> {
    let queryLineage =
      result.lineage
      ?? SQLQueryAnalyzer.lineage(
        sql: sql, outputColumnNames: result.columns)
    let columns = result.columns.enumerated().map { index, name in
      let lineage =
        queryLineage.columns.indices.contains(index)
        ? queryLineage.columns[index] : nil
      let aggregation = aggregation(for: lineage?.aggregation)
      let orderedSourceName =
        lineage?.sourceColumns.count == 1
        ? lineage?.sourceColumns.first?.column : nil
      let categoryOrder = categoryOrder(for: orderedSourceName ?? name)
      return AutoChartColumn(
        id: columnID(index: index, name: name),
        name: name,
        categoryOrder: categoryOrder,
        provenance: columnProvenance(lineage),
        semantics: semantics(
          for: name,
          aggregation: aggregation,
          categoryOrder: categoryOrder,
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
    let fingerprint =
      resultFingerprint
      ?? PreparedFollowUpIntegrity.fingerprint(result: result)
    let dataset = try AutoChartDataset<Int>(
      columns: columns,
      rows: rows,
      metadata: AutoChartTableMetadata(
        isTruncated: result.isTruncated,
        rowGrain: queryLineage.rowGrain.isEmpty
          ? nil
          : AutoChartGrain(
            queryLineage.rowGrain.map(AutoChartEntityID.init(rawValue:))),
        semanticModel: portfolioSemanticModel,
        provenance: "CREG query result"),
      key: .trusted(
        identity: dataIdentity ?? "CREG.Result.v3:\(fingerprint)",
        revision: dataKeyRevision(resultFingerprint: fingerprint, sql: sql)))
    return dataset
  }

  static func analysisContext(
    question: String?,
    sql: String
  ) -> AutoChartContext {
    AutoChartContext(
      goal: goal(question: question, sql: sql),
      title: question)
  }

  /// Restores table-owned row intent without changing the package's complete
  /// mark-lineage semantics for selections made directly in a chart.
  static func tableSelections(
    in chart: AutoChartPreparedChart<Int>,
    for sourceRows: Set<Int>,
    analysisID: AutoChartAnalysisID
  ) -> AutoChartSelectionSet<Int> {
    AutoChartSelectionSet(
      chart.selections(for: sourceRows, analysisID: analysisID).compactMap { selection in
        var narrowed = selection
        narrowed.sourceRowIDs.formIntersection(sourceRows)
        return narrowed.sourceRowIDs.isEmpty ? nil : narrowed
      })
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
      "CREG.ChartData.v3",
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

  static func semantics(
    for name: String,
    aggregation: AutoChartAggregation?,
    categoryOrder: [AutoChartValue]?,
    values: @autoclosure () -> [SQLValue] = []
  ) -> AutoChartColumnSemantics {
    let normalized = name.lowercased()

    if categoryOrder != nil {
      guard !containsBlob(values()) else {
        return .inferred(
          measureSemantics: measureSemantics(for: aggregation))
      }
      return .dimension(semanticType: .ordinal)
    }

    if normalized == "id" || normalized.hasSuffix("_id") {
      return .identifier(semanticType: .identifier)
    }
    let style = PortfolioValueFormatting.style(forColumn: normalized)
    if style == .date {
      let temporalValues = values()
      guard temporalValues.isEmpty || hasValidTemporalValues(temporalValues) else {
        return .inferred(
          measureSemantics: measureSemantics(for: aggregation))
      }
      if containsWord(
          normalized,
          [
            "commencement", "origination", "acquisition", "inception", "start",
          ])
      {
        return .intervalStart()
      }
      if containsWord(
          normalized,
          [
            "expiration", "maturity", "disposition", "end",
          ])
      {
        return .intervalEnd()
      }
      return .dimension(semanticType: .temporal)
    }
    if normalized.hasPrefix("is_") || normalized.hasPrefix("has_") {
      // SQLite permits mixed storage classes in one result column. Do not force
      // opaque bytes into a categorical identity that charting would collapse
      // into the same missing group as SQL NULL.
      guard !containsBlob(values()) else {
        return .inferred(
          measureSemantics: measureSemantics(for: aggregation))
      }
      return .dimension(semanticType: .boolean)
    }
    if style == .percent {
      let sourceValues = values()
      return quantitativeSemantics(
        values: sourceValues,
        unit: percentUnit(for: sourceValues),
        aggregation: aggregation)
    }
    if style == .currency || style == .currencyPerSquareFoot {
      return quantitativeSemantics(
        values: values(),
        unit: .currency(code: "USD"),
        aggregation: aggregation)
    }
    if style == .squareFeet {
      return quantitativeSemantics(
        values: values(),
        unit: .area(unit: "sq ft"),
        aggregation: aggregation)
    }
    if style == .count, containsWord(normalized, ["month", "months"]) {
      return quantitativeSemantics(
        values: values(),
        unit: .duration(unit: "months"),
        aggregation: aggregation)
    }
    if style == .ratio {
      return quantitativeSemantics(
        values: values(),
        aggregation: aggregation)
    }
    if style == .plainDigits, containsWord(normalized, ["year"]) {
      guard !containsBlob(values()) else {
        return .inferred(
          measureSemantics: measureSemantics(for: aggregation))
      }
      return .dimension(semanticType: .ordinal)
    }
    return .inferred(
      measureSemantics: measureSemantics(for: aggregation))
  }

  private static func categoryOrder(for name: String) -> [AutoChartValue]? {
    switch name.lowercased() {
    case "building_class":
      ["A", "B", "C"].map(AutoChartValue.text)
    case "strategy":
      ["Core", "Core-Plus", "Value-Add", "Opportunistic"].map(AutoChartValue.text)
    case "credit_rating":
      [
        "AAA", "AA+", "AA", "AA-", "A+", "A", "A-", "BBB+", "BBB", "BBB-",
        "BB+", "BB", "BB-", "B+", "B", "B-", "CCC+", "CCC", "CCC-", "CC",
        "C", "D", "NR",
      ].map(AutoChartValue.text)
    default:
      nil
    }
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
    if containsAny(
      text,
      ["compare", " by ", "group by", "for each", "for every", " each "])
      || containsAny(
        text,
        [
          " per property", " per properties", " per fund", " per funds",
          " per lease", " per leases", " per tenant", " per tenants",
          " per loan", " per loans", " per valuation", " per valuations",
        ])
    {
      return .comparison
    }
    return .overview
  }

  private static let portfolioSchema = PortfolioSchemaCatalog.document

  private static let portfolioSemanticModel = AutoChartSemanticModel(
    relationships: portfolioSchema.foreignKeys.map { foreignKey in
      AutoChartEntityRelationship(
        one: AutoChartEntityID(rawValue: foreignKey.toTable),
        many: AutoChartEntityID(rawValue: foreignKey.fromTable))
    })

  private static func columnProvenance(
    _ lineage: SQLResultColumnLineage?
  ) -> AutoChartColumnProvenance? {
    guard let lineage,
      !lineage.sourceColumns.isEmpty || !lineage.sourceGrain.isEmpty
    else { return nil }
    return AutoChartColumnProvenance(
      sourceColumns: lineage.sourceColumns.map {
        AutoChartSourceColumn(
          entity: AutoChartEntityID(rawValue: $0.table), name: $0.column)
      },
      sourceGrain: lineage.sourceGrain.isEmpty
        ? nil
        : AutoChartGrain(
          lineage.sourceGrain.map(AutoChartEntityID.init(rawValue:))))
  }

  private static func aggregation(
    for operation: SQLAggregateOperation?
  ) -> AutoChartAggregation? {
    switch operation {
    case .sum, .total: .sum
    case .average: .mean
    case .minimum: .minimum
    case .maximum: .maximum
    case .count: .count
    case .countDistinct: .countDistinct
    case nil: nil
    }
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

  private static func hasValidTemporalValues(_ values: [SQLValue]) -> Bool {
    // SQL NULL is genuinely absent. BLOBs are present but opaque to charting,
    // so they must consume the same invalid-value budget as malformed scalars.
    var nonNullCount = 0
    var validCount = 0
    for value in values {
      if case .null = value { continue }
      nonNullCount += 1
      if case .text(let text) = value, parseISODate(text) != nil {
        validCount += 1
      }
    }
    guard nonNullCount > 0 else { return false }
    return validCount == nonNullCount
      || (validCount >= 2
        && validCount * 5 >= nonNullCount * 4)
  }

  private static func containsBlob(_ values: [SQLValue]) -> Bool {
    values.contains { value in
      if case .blob = value { true } else { false }
    }
  }

  private static func quantitativeSemantics(
    values: [SQLValue],
    unit: AutoChartUnit? = nil,
    aggregation: AutoChartAggregation?
  ) -> AutoChartColumnSemantics {
    guard values.isEmpty || hasQuantitativeValues(values) else {
      return .inferred(
        measureSemantics: measureSemantics(for: aggregation))
    }
    return .measure(
      semanticType: .quantitative,
      unit: unit,
      semantics: measureSemantics(for: aggregation))
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
