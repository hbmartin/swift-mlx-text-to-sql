import CREGCore
import Foundation

/// Query-local sources used by grounding and repair guidance.
package struct SQLQueryScope: Sendable, Equatable {
  package var aliases: [String: String]
  package var tables: Set<String>
  /// Output columns exposed by each relation qualifier in this block.
  package var qualifiedColumns: [String: [String: SQLQueryScopeColumn]]
  /// One entry per relation that exposes an unqualified output name. Keeping
  /// relation entries separate preserves SQLite's ambiguity rules for self joins.
  package var unqualifiedColumns: [String: [SQLQueryScopeColumn]]
}

package struct SQLQueryScopeColumn: Sendable, Equatable {
  package var source: SQLSourceColumn?
}

/// One query-block-aware SQL analysis shared by database execution, grounding,
/// and chart presentation. It intentionally implements the constrained CREG
/// SELECT grammar rather than guessing from unrelated words in the statement.
package enum SQLQueryAnalyzer {
  package static func lineage(
    sql: String,
    outputColumnNames: [String],
    directOrigins: [SQLSourceColumn?] = [],
    reads: [SQLSourceRead] = []
  ) -> SQLQueryLineage {
    let tokens = SQLLexer.tokenize(sql)
    guard
      let block = Analyzer(tokens: tokens).analyze(
        range: tokens.indices, inheritedCTEs: [:])
    else {
      return SQLQueryLineage(
        columns: directLineage(
          outputColumnNames: outputColumnNames,
          directOrigins: directOrigins),
        reads: reads)
    }

    var columns: [SQLResultColumnLineage?]
    if block.outputs.count == outputColumnNames.count {
      let readColumns = Set(
        reads.compactMap { read -> SQLSourceColumn? in
          guard let column = read.column else { return nil }
          return SQLSourceColumn(table: read.table, column: column)
        })
      columns = block.outputs.enumerated().map { index, output in
        var descriptor = output.descriptor
        if directOrigins.indices.contains(index), let origin = directOrigins[index] {
          descriptor.sourceColumns = [origin]
          descriptor.preservesSourceDomain = true
          if descriptor.aggregation == nil {
            descriptor.chartGrain = Analyzer.grain(
              for: origin, schema: PortfolioSchemaCatalog.document)
          }
        }
        // The structured analyzer maps projection expressions to sources;
        // SQLite's authorizer independently proves those physical columns were
        // actually read. When runtime evidence contradicts the mapping, omit
        // provenance instead of presenting a guessed grain as authoritative.
        if !readColumns.isEmpty,
          !descriptor.sourceColumns.allSatisfy(readColumns.contains)
        {
          guard let aggregation = descriptor.aggregation else { return nil }
          return SQLResultColumnLineage(
            aggregation: aggregation,
            preservesSourceDomain: false)
        }
        guard
          !descriptor.sourceColumns.isEmpty || !descriptor.chartGrain.isEmpty
            || descriptor.aggregation != nil
        else { return nil }
        return SQLResultColumnLineage(
          sourceColumns: descriptor.sourceColumns,
          sourceGrain: descriptor.chartGrain,
          aggregation: descriptor.aggregation,
          preservesSourceDomain: descriptor.preservesSourceDomain)
      }
    } else {
      columns = directLineage(
        outputColumnNames: outputColumnNames,
        directOrigins: directOrigins)
    }
    return SQLQueryLineage(
      columns: columns,
      rowGrain: block.rowGrain,
      reads: reads)
  }

  package static func scope(in sql: String) -> SQLQueryScope {
    let tokens = SQLLexer.tokenize(sql)
    return Analyzer(tokens: tokens).analyze(
      range: tokens.indices, inheritedCTEs: [:]
    )?.scope
      ?? SQLQueryScope(
        aliases: [:], tables: [], qualifiedColumns: [:], unqualifiedColumns: [:])
  }

  private static func directLineage(
    outputColumnNames: [String],
    directOrigins: [SQLSourceColumn?]
  ) -> [SQLResultColumnLineage?] {
    outputColumnNames.indices.map { index in
      guard directOrigins.indices.contains(index), let origin = directOrigins[index]
      else { return nil }
      return SQLResultColumnLineage(
        sourceColumns: [origin],
        sourceGrain: Analyzer.grain(
          for: origin, schema: PortfolioSchemaCatalog.document),
        preservesSourceDomain: true)
    }
  }
}

private enum SQLToken: Equatable {
  case word(String)
  case string(String)
  case number(String)
  case symbol(Character)

  var word: String? {
    guard case .word(let value) = self else { return nil }
    return value
  }
}

private enum SQLLexer {
  static func tokenize(_ sql: String) -> [SQLToken] {
    let characters = Array(sql)
    var output: [SQLToken] = []
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if character.isWhitespace {
        index += 1
        continue
      }
      if character == "-", index + 1 < characters.count, characters[index + 1] == "-" {
        index += 2
        while index < characters.count, !characters[index].isNewline { index += 1 }
        continue
      }
      if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
        index += 2
        while index + 1 < characters.count,
          !(characters[index] == "*" && characters[index + 1] == "/")
        {
          index += 1
        }
        index = min(index + 2, characters.count)
        continue
      }
      if character == "'" {
        let (value, next) = quoted(characters, from: index, closing: "'")
        output.append(.string(value))
        index = next
        continue
      }
      if character == "\"" || character == "`" || character == "[" {
        let closing: Character = character == "[" ? "]" : character
        let (value, next) = quoted(characters, from: index, closing: closing)
        output.append(.word(value.lowercased()))
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
        output.append(.word(String(characters[start..<index]).lowercased()))
        continue
      }
      if character.isNumber {
        let start = index
        index += 1
        while index < characters.count,
          characters[index].isNumber || characters[index] == "."
        {
          index += 1
        }
        output.append(.number(String(characters[start..<index])))
        continue
      }
      output.append(.symbol(character))
      index += 1
    }
    return output
  }

  private static func quoted(
    _ characters: [Character],
    from start: Int,
    closing: Character
  ) -> (String, Int) {
    var value = ""
    var index = start + 1
    while index < characters.count {
      guard characters[index] == closing else {
        value.append(characters[index])
        index += 1
        continue
      }
      if index + 1 < characters.count, characters[index + 1] == closing {
        value.append(closing)
        index += 2
        continue
      }
      return (value, index + 1)
    }
    return (value, characters.count)
  }
}

private struct ColumnDescriptor {
  var sourceColumns: [SQLSourceColumn]
  /// Grain used when this value is referenced by an enclosing query block.
  var expressionGrain: [String]
  /// Grain exposed to chart safety for this result column.
  var chartGrain: [String]
  var aggregation: SQLAggregateOperation?
  var isAggregateExpression: Bool
  var preservesSourceDomain: Bool
}

private struct AggregateAnalysis {
  var operation: SQLAggregateOperation?
  var hasAggregateCall: Bool
}

private struct QueryOutput {
  var name: String
  var descriptor: ColumnDescriptor
}

private struct Relation {
  var name: String
  var aliases: Set<String>
  var outputs: [QueryOutput]
  var rowGrain: [String]
  var physicalTables: Set<String>
  var columns: [String: ColumnDescriptor]

  init(
    name: String,
    aliases: Set<String>,
    outputs: [QueryOutput],
    rowGrain: [String],
    physicalTables: Set<String>
  ) {
    self.name = name
    self.aliases = aliases
    self.outputs = outputs
    self.rowGrain = rowGrain
    self.physicalTables = physicalTables
    var result: [String: ColumnDescriptor] = [:]
    for output in outputs {
      let name = normalizedRelationColumnName(output.name)
      if result[name] == nil { result[name] = output.descriptor }
    }
    self.columns = result
  }
}

private func normalizedRelationColumnName(_ name: String) -> String {
  name.lowercased().filter { !$0.isWhitespace }
}

private struct QueryBlock {
  var outputs: [QueryOutput]
  var rowGrain: [String]
  var scope: SQLQueryScope
  var physicalTables: Set<String>
}

private struct Analyzer {
  let tokens: [SQLToken]
  private let schema = PortfolioSchemaCatalog.document

  func analyze(
    range: Range<Int>,
    inheritedCTEs: [String: Relation]
  ) -> QueryBlock? {
    let range = unwrapped(range)
    guard !range.isEmpty else { return nil }
    var ctes = inheritedCTEs
    var selectIndex = range.lowerBound

    if tokens[selectIndex].word == "with" {
      selectIndex += 1
      if selectIndex < range.upperBound, tokens[selectIndex].word == "recursive" {
        selectIndex += 1
      }
      while selectIndex < range.upperBound, tokens[selectIndex].word != "select" {
        guard let cteName = tokens[selectIndex].word else { return nil }
        selectIndex += 1
        var declaredOutputNames: [String]?
        if selectIndex < range.upperBound, tokens[selectIndex] == .symbol("(") {
          guard let close = matchingClose(at: selectIndex, upperBound: range.upperBound)
          else { return nil }
          let names = splitTopLevel((selectIndex + 1)..<close).compactMap { nameRange in
            nameRange.count == 1 ? tokens[nameRange.lowerBound].word : nil
          }
          guard names.count == splitTopLevel((selectIndex + 1)..<close).count else {
            return nil
          }
          declaredOutputNames = names
          selectIndex = close + 1
        }
        guard selectIndex < range.upperBound, tokens[selectIndex].word == "as" else {
          return nil
        }
        selectIndex += 1
        guard selectIndex < range.upperBound, tokens[selectIndex] == .symbol("("),
          let close = matchingClose(at: selectIndex, upperBound: range.upperBound),
          let block = analyze(
            range: (selectIndex + 1)..<close, inheritedCTEs: ctes)
        else { return nil }
        var relation = relation(name: cteName, block: block)
        if let declaredOutputNames {
          guard declaredOutputNames.count == relation.outputs.count else { return nil }
          for index in relation.outputs.indices {
            relation.outputs[index].name = declaredOutputNames[index]
          }
          relation = Relation(
            name: relation.name,
            aliases: relation.aliases,
            outputs: relation.outputs,
            rowGrain: relation.rowGrain,
            physicalTables: relation.physicalTables)
        }
        ctes[cteName] = relation
        selectIndex = close + 1
        if selectIndex < range.upperBound, tokens[selectIndex] == .symbol(",") {
          selectIndex += 1
          continue
        }
      }
    }

    if let armRanges = compoundArmRanges(
      in: selectIndex..<range.upperBound)
    {
      guard !armRanges.isEmpty else { return nil }
      let arms = armRanges.compactMap {
        analyze(range: $0, inheritedCTEs: ctes)
      }
      guard arms.count == armRanges.count else { return nil }
      return compoundBlock(from: arms)
    }

    guard selectIndex < range.upperBound, tokens[selectIndex].word == "select",
      let fromIndex = firstTopLevelWord(
        "from", in: (selectIndex + 1)..<range.upperBound)
    else { return nil }

    var projectionStart = selectIndex + 1
    let isDistinct = projectionStart < fromIndex && tokens[projectionStart].word == "distinct"
    if isDistinct { projectionStart += 1 }

    let boundaries = clauseBoundaries(after: fromIndex, upperBound: range.upperBound)
    let fromEnd = boundaries.values.min() ?? range.upperBound
    let relations = parseRelations(
      in: (fromIndex + 1)..<fromEnd, ctes: ctes)
    let fromGrain = normalize(relations.flatMap(\.rowGrain))
    let projectionRanges = splitTopLevel(projectionStart..<fromIndex)

    var drafts = projectionRanges.flatMap { projection -> [QueryOutput] in
      if let expanded = expandedWildcard(projection, relations: relations) {
        return expanded
      }
      let (expression, alias) = expressionAndAlias(projection)
      let references = references(in: expression, relations: relations, ctes: ctes)
      let localAggregation = aggregate(in: expression)
      let aggregation =
        localAggregation.operation
        ?? (!localAggregation.hasAggregateCall && references.count == 1
          ? references[0].aggregation : nil)
      let rawGrain =
        references.isEmpty && aggregation == .count
        ? fromGrain
        : normalize(references.flatMap(\.expressionGrain))
      let descriptor = ColumnDescriptor(
        sourceColumns: orderedUnique(references.flatMap(\.sourceColumns)),
        expressionGrain: rawGrain,
        chartGrain: rawGrain,
        aggregation: aggregation,
        isAggregateExpression: localAggregation.hasAggregateCall,
        preservesSourceDomain:
          !localAggregation.hasAggregateCall
          && references.count == 1
          && isDirectColumnReference(expression)
          && references[0].preservesSourceDomain)
      return [
        QueryOutput(
          name: alias ?? inferredOutputName(expression),
          descriptor: descriptor)
      ]
    }

    let groupGrain: [String] = {
      guard let groupIndex = boundaries["group"] else { return [] }
      let start = groupIndex + 1
      let expressionStart =
        start < range.upperBound && tokens[start].word == "by"
        ? start + 1 : start
      let end =
        boundaries
        .filter { $0.key != "group" && $0.value > groupIndex }
        .map(\.value).min() ?? range.upperBound
      let grains = splitTopLevel(expressionStart..<end).flatMap { expression -> [String] in
        if expression.count == 1,
          case .number(let ordinal) = tokens[expression.lowerBound],
          let position = Int(ordinal), drafts.indices.contains(position - 1)
        {
          return drafts[position - 1].descriptor.expressionGrain
        }
        let sourceGrain = references(
          in: expression, relations: relations, ctes: ctes
        ).flatMap(\.expressionGrain)
        if !sourceGrain.isEmpty { return sourceGrain }
        if expression.count == 1, let alias = tokens[expression.lowerBound].word,
          let output = drafts.first(where: { $0.name == alias })
        {
          return output.descriptor.expressionGrain
        }
        return []
      }
      return normalize(grains)
    }()

    let hasAggregate = drafts.contains { $0.descriptor.isAggregateExpression }
    let rowGrain: [String]
    if boundaries["group"] != nil {
      // A constant or otherwise opaque bucket still groups rows drawn from the
      // FROM grain. Preserve that fallback so safety cannot disappear merely
      // because a grouping expression has no direct output-column lineage.
      rowGrain = groupGrain.isEmpty ? fromGrain : groupGrain
    } else if isDistinct {
      rowGrain = normalize(drafts.flatMap(\.descriptor.expressionGrain))
    } else if hasAggregate {
      rowGrain = []
    } else {
      rowGrain = fromGrain
    }

    for index in drafts.indices {
      guard drafts[index].descriptor.isAggregateExpression,
        let aggregation = drafts[index].descriptor.aggregation
      else { continue }
      let rawGrain = drafts[index].descriptor.expressionGrain
      let effectiveGroup = groupGrain.isEmpty ? rowGrain : groupGrain
      let isUnsafe =
        aggregation.isDuplicateSensitive
        && !fromGrain.isEmpty
        && isStrictlyFiner(fromGrain, than: rawGrain)
      drafts[index].descriptor.chartGrain =
        isUnsafe
        ? rawGrain : (effectiveGroup.isEmpty ? rawGrain : effectiveGroup)
      // Enclosing query blocks consume an aggregate at the grain produced by
      // this block, not at the raw child grain below the aggregation boundary.
      drafts[index].descriptor.expressionGrain = rowGrain
    }

    var aliases: [String: String] = [:]
    var tables: Set<String> = []
    var qualifiedColumns: [String: [String: SQLQueryScopeColumn]] = [:]
    var unqualifiedColumns: [String: [SQLQueryScopeColumn]] = [:]
    for relation in relations {
      tables.formUnion(relation.physicalTables)
      let exposedColumns = relation.columns.mapValues { descriptor in
        SQLQueryScopeColumn(
          source: descriptor.sourceColumns.count == 1
            ? descriptor.sourceColumns[0] : nil)
      }
      for alias in relation.aliases { qualifiedColumns[alias] = exposedColumns }
      for (name, column) in exposedColumns {
        unqualifiedColumns[name, default: []].append(column)
      }
      guard relation.physicalTables.count == 1, let table = relation.physicalTables.first
      else { continue }
      for alias in relation.aliases { aliases[alias] = table }
    }
    return QueryBlock(
      outputs: drafts,
      rowGrain: rowGrain,
      scope: SQLQueryScope(
        aliases: aliases,
        tables: tables,
        qualifiedColumns: qualifiedColumns,
        unqualifiedColumns: unqualifiedColumns),
      physicalTables: tables)
  }

  private func relation(name: String, block: QueryBlock) -> Relation {
    Relation(
      name: name,
      aliases: [name],
      outputs: block.outputs,
      rowGrain: block.rowGrain,
      physicalTables: block.physicalTables)
  }

  private func physicalRelation(name: String) -> Relation? {
    guard let columns = schema.tables[name] else { return nil }
    return Relation(
      name: name,
      aliases: [name],
      outputs: columns.map { column in
        let source = SQLSourceColumn(table: name, column: column)
        let grain = Self.grain(for: source, schema: schema)
        return QueryOutput(
          name: column,
          descriptor: ColumnDescriptor(
            sourceColumns: [source],
            expressionGrain: grain,
            chartGrain: grain,
            aggregation: nil,
            isAggregateExpression: false,
            preservesSourceDomain: true))
      },
      rowGrain: [name],
      physicalTables: [name])
  }

  private func parseRelations(
    in range: Range<Int>,
    ctes: [String: Relation]
  ) -> [Relation] {
    var relations: [Relation] = []
    var index = range.lowerBound
    var expectsRelation = true
    while index < range.upperBound {
      if expectsRelation {
        if tokens[index] == .symbol("(") {
          guard let close = matchingClose(at: index, upperBound: range.upperBound)
          else { break }
          if let block = analyze(range: (index + 1)..<close, inheritedCTEs: ctes) {
            var relation = relation(name: "derived", block: block)
            index = close + 1
            index = applyingAlias(to: &relation, at: index, upperBound: range.upperBound)
            relations.append(relation)
          } else {
            index = close + 1
          }
          expectsRelation = false
          continue
        }
        guard let name = tokens[index].word else {
          index += 1
          continue
        }
        var relationName = name
        var nextIndex = index + 1
        if index + 2 < range.upperBound,
          tokens[index + 1] == .symbol("."),
          let qualifiedName = tokens[index + 2].word,
          schema.tables[qualifiedName] != nil
        {
          relationName = qualifiedName
          nextIndex = index + 3
        }
        guard var relation = ctes[relationName] ?? physicalRelation(name: relationName) else {
          // Unknown relations, including table-valued functions, are outside the
          // frozen schema. Skip them without inventing a chart entity.
          index = nextIndex
          if index < range.upperBound, tokens[index] == .symbol("("),
            let close = matchingClose(at: index, upperBound: range.upperBound)
          {
            index = close + 1
          }
          expectsRelation = false
          continue
        }
        index = nextIndex
        index = applyingAlias(to: &relation, at: index, upperBound: range.upperBound)
        relations.append(relation)
        expectsRelation = false
        continue
      }

      if tokens[index] == .symbol("("),
        let close = matchingClose(at: index, upperBound: range.upperBound)
      {
        index = close + 1
        continue
      }
      if tokens[index] == .symbol(",") {
        expectsRelation = true
        index += 1
        continue
      }
      if tokens[index].word == "join" {
        expectsRelation = true
        index += 1
        continue
      }
      index += 1
    }
    return relations
  }

  private func applyingAlias(
    to relation: inout Relation,
    at start: Int,
    upperBound: Int
  ) -> Int {
    var index = start
    if index < upperBound, tokens[index].word == "as" { index += 1 }
    guard index < upperBound, let alias = tokens[index].word,
      !Self.sourceBoundaryWords.contains(alias)
    else { return start }
    relation.aliases.insert(alias)
    return index + 1
  }

  private func references(
    in range: Range<Int>,
    relations: [Relation],
    ctes: [String: Relation]
  ) -> [ColumnDescriptor] {
    var output: [ColumnDescriptor] = []
    var consumed: Set<Int> = []
    var index = range.lowerBound
    while index < range.upperBound {
      if tokens[index] == .symbol("("),
        let close = matchingClose(at: index, upperBound: range.upperBound),
        index + 1 < close,
        ["select", "with"].contains(tokens[index + 1].word)
      {
        if let block = analyze(range: (index + 1)..<close, inheritedCTEs: ctes),
          let descriptor = block.outputs.first?.descriptor
        {
          output.append(descriptor)
        }
        consumed.formUnion(index...close)
        index = close + 1
        continue
      }
      if index + 4 < range.upperBound,
        tokens[index].word != nil,
        tokens[index + 1] == .symbol("."),
        let qualifier = tokens[index + 2].word,
        tokens[index + 3] == .symbol("."),
        let column = tokens[index + 4].word,
        let relation = relations.first(where: { $0.aliases.contains(qualifier) }),
        let descriptor = relation.columns[normalizedRelationColumnName(column)]
      {
        output.append(descriptor)
        consumed.formUnion(index...(index + 4))
        index += 5
        continue
      }
      if index + 2 < range.upperBound, let qualifier = tokens[index].word,
        tokens[index + 1] == .symbol("."), let column = tokens[index + 2].word,
        let relation = relations.first(where: { $0.aliases.contains(qualifier) }),
        let descriptor = relation.columns[normalizedRelationColumnName(column)]
      {
        output.append(descriptor)
        consumed.formUnion(index...(index + 2))
        index += 3
        continue
      }
      index += 1
    }

    for index in range where !consumed.contains(index) {
      guard let column = tokens[index].word else { continue }
      if index + 1 < range.upperBound, tokens[index + 1] == .symbol("(") { continue }
      if index > range.lowerBound, tokens[index - 1] == .symbol(".") { continue }
      if index + 1 < range.upperBound, tokens[index + 1] == .symbol(".") { continue }
      let matches = relations.compactMap {
        $0.columns[normalizedRelationColumnName(column)]
      }
      if matches.count == 1 { output.append(matches[0]) }
    }
    return orderedUniqueDescriptors(output)
  }

  private func aggregate(in range: Range<Int>) -> AggregateAnalysis {
    let searchable = indicesOutsideSubqueries(in: range)
    guard !searchable.contains(where: { tokens[$0].word == "over" }) else {
      return AggregateAnalysis(operation: nil, hasAggregateCall: false)
    }
    var operations: [SQLAggregateOperation] = []
    for index in searchable {
      guard let name = tokens[index].word,
        index + 1 < range.upperBound, tokens[index + 1] == .symbol("(")
      else { continue }
      switch name {
      case "sum": operations.append(.sum)
      case "avg": operations.append(.average)
      case "min": operations.append(.minimum)
      case "max": operations.append(.maximum)
      case "total": operations.append(.total)
      case "count":
        if index + 2 < range.upperBound, tokens[index + 2].word == "distinct" {
          operations.append(.countDistinct)
        } else {
          operations.append(.count)
        }
      default: continue
      }
    }
    return AggregateAnalysis(
      operation: operations.count == 1 ? operations[0] : nil,
      hasAggregateCall: !operations.isEmpty)
  }

  private func expandedWildcard(
    _ range: Range<Int>,
    relations: [Relation]
  ) -> [QueryOutput]? {
    if range.count == 1, tokens[range.lowerBound] == .symbol("*") {
      return relations.flatMap(\.outputs)
    }
    if range.count == 3, let qualifier = tokens[range.lowerBound].word,
      tokens[range.lowerBound + 1] == .symbol("."),
      tokens[range.lowerBound + 2] == .symbol("*"),
      let relation = relations.first(where: { $0.aliases.contains(qualifier) })
    {
      return relation.outputs
    }
    if range.count == 5,
      tokens[range.lowerBound + 1] == .symbol("."),
      let qualifier = tokens[range.lowerBound + 2].word,
      tokens[range.lowerBound + 3] == .symbol("."),
      tokens[range.lowerBound + 4] == .symbol("*"),
      let relation = relations.first(where: { $0.aliases.contains(qualifier) })
    {
      return relation.outputs
    }
    return nil
  }

  private func expressionAndAlias(
    _ range: Range<Int>
  ) -> (Range<Int>, String?) {
    var depth = 0
    var aliasIndex: Int?
    for index in range {
      if tokens[index] == .symbol("(") { depth += 1 }
      if tokens[index] == .symbol(")") { depth = max(0, depth - 1) }
      if depth == 0, tokens[index].word == "as", index + 1 < range.upperBound {
        aliasIndex = index
      }
    }
    guard let aliasIndex else { return (range, nil) }
    let alias: String?
    switch tokens[aliasIndex + 1] {
    case .word(let value), .string(let value): alias = value.lowercased()
    case .number, .symbol: alias = nil
    }
    return (range.lowerBound..<aliasIndex, alias)
  }

  private func inferredOutputName(_ range: Range<Int>) -> String {
    if range.count == 1, let word = tokens[range.lowerBound].word { return word }
    if range.count == 3, tokens[range.lowerBound + 1] == .symbol("."),
      let word = tokens[range.lowerBound + 2].word
    {
      return word
    }
    if range.count == 5,
      tokens[range.lowerBound + 1] == .symbol("."),
      tokens[range.lowerBound + 3] == .symbol("."),
      let word = tokens[range.lowerBound + 4].word
    {
      return word
    }
    return range.map { index in
      switch tokens[index] {
      case .word(let value), .number(let value): value
      case .string(let value): "'\(value.replacingOccurrences(of: "'", with: "''"))'"
      case .symbol(let value): String(value)
      }
    }.joined()
  }

  private func isDirectColumnReference(_ range: Range<Int>) -> Bool {
    if range.count == 1 { return tokens[range.lowerBound].word != nil }
    if range.count == 3 {
      return tokens[range.lowerBound].word != nil
        && tokens[range.lowerBound + 1] == .symbol(".")
        && tokens[range.lowerBound + 2].word != nil
    }
    if range.count == 5 {
      return tokens[range.lowerBound].word != nil
        && tokens[range.lowerBound + 1] == .symbol(".")
        && tokens[range.lowerBound + 2].word != nil
        && tokens[range.lowerBound + 3] == .symbol(".")
        && tokens[range.lowerBound + 4].word != nil
    }
    return false
  }

  private func indicesOutsideSubqueries(in range: Range<Int>) -> [Int] {
    var output: [Int] = []
    var index = range.lowerBound
    while index < range.upperBound {
      if tokens[index] == .symbol("("),
        let close = matchingClose(at: index, upperBound: range.upperBound),
        index + 1 < close,
        ["select", "with"].contains(tokens[index + 1].word)
      {
        index = close + 1
        continue
      }
      output.append(index)
      index += 1
    }
    return output
  }

  private func compoundArmRanges(
    in range: Range<Int>
  ) -> [Range<Int>]? {
    guard !range.isEmpty else { return nil }
    var arms: [Range<Int>] = []
    var depth = 0
    var start = range.lowerBound
    for index in range {
      if tokens[index] == .symbol("(") {
        depth += 1
      } else if tokens[index] == .symbol(")") {
        depth = max(0, depth - 1)
      } else if depth == 0,
        let word = tokens[index].word,
        Self.compoundWords.contains(word)
      {
        guard start < index else { return [] }
        arms.append(start..<index)
        start = index + 1
        if start < range.upperBound,
          let modifier = tokens[start].word,
          modifier == "all" || modifier == "distinct"
        {
          start += 1
        }
      }
    }
    guard !arms.isEmpty else { return nil }
    guard start < range.upperBound else { return [] }
    arms.append(start..<range.upperBound)
    return arms
  }

  private func compoundBlock(from arms: [QueryBlock]) -> QueryBlock {
    let emptyDescriptor = ColumnDescriptor(
      sourceColumns: [],
      expressionGrain: [],
      chartGrain: [],
      aggregation: nil,
      isAggregateExpression: false,
      preservesSourceDomain: false)
    let outputs = arms[0].outputs.map {
      QueryOutput(name: $0.name, descriptor: emptyDescriptor)
    }
    let scope = mergedScope(arms.map(\.scope))
    return QueryBlock(
      outputs: outputs,
      rowGrain: [],
      scope: scope,
      physicalTables: Set(arms.flatMap(\.physicalTables)))
  }

  private func mergedScope(_ scopes: [SQLQueryScope]) -> SQLQueryScope {
    var aliasTables: [String: Set<String>] = [:]
    var tables: Set<String> = []
    var qualifiedCandidates: [String: [String: [SQLQueryScopeColumn]]] = [:]
    var unqualifiedCandidates: [String: [[SQLQueryScopeColumn]]] = [:]

    for scope in scopes {
      tables.formUnion(scope.tables)
      for (alias, table) in scope.aliases {
        aliasTables[alias, default: []].insert(table)
      }
      for (qualifier, columns) in scope.qualifiedColumns {
        for (name, column) in columns {
          qualifiedCandidates[qualifier, default: [:]][name, default: []]
            .append(column)
        }
      }
      for (name, columns) in scope.unqualifiedColumns {
        unqualifiedCandidates[name, default: []].append(columns)
      }
    }

    let aliases = aliasTables.compactMapValues { candidates in
      candidates.count == 1 ? candidates.first : nil
    }
    let qualifiedColumns = qualifiedCandidates.mapValues { columns in
      columns.mapValues { conservativeColumn(from: $0) }
    }
    let unqualifiedColumns = unqualifiedCandidates.mapValues { candidates in
      guard candidates.allSatisfy({ $0.count == 1 }),
        let first = candidates.first?.first,
        candidates.allSatisfy({ $0[0] == first })
      else {
        return [SQLQueryScopeColumn(source: nil)]
      }
      return [first]
    }
    return SQLQueryScope(
      aliases: aliases,
      tables: tables,
      qualifiedColumns: qualifiedColumns,
      unqualifiedColumns: unqualifiedColumns)
  }

  private func conservativeColumn(
    from candidates: [SQLQueryScopeColumn]
  ) -> SQLQueryScopeColumn {
    guard let first = candidates.first,
      candidates.allSatisfy({ $0 == first })
    else { return SQLQueryScopeColumn(source: nil) }
    return first
  }

  private func clauseBoundaries(
    after fromIndex: Int,
    upperBound: Int
  ) -> [String: Int] {
    var result: [String: Int] = [:]
    var depth = 0
    var index = fromIndex + 1
    while index < upperBound {
      if tokens[index] == .symbol("(") { depth += 1 }
      if tokens[index] == .symbol(")") { depth = max(0, depth - 1) }
      if depth == 0, let word = tokens[index].word,
        Self.clauseWords.contains(word), result[word] == nil
      {
        result[word] = index
      }
      index += 1
    }
    return result
  }

  private func firstTopLevelWord(
    _ word: String,
    in range: Range<Int>
  ) -> Int? {
    var depth = 0
    for index in range {
      if tokens[index] == .symbol("(") {
        depth += 1
        continue
      }
      if tokens[index] == .symbol(")") {
        depth = max(0, depth - 1)
        continue
      }
      if depth == 0, tokens[index].word == word { return index }
    }
    return nil
  }

  private func splitTopLevel(_ range: Range<Int>) -> [Range<Int>] {
    guard !range.isEmpty else { return [] }
    var output: [Range<Int>] = []
    var depth = 0
    var start = range.lowerBound
    for index in range {
      if tokens[index] == .symbol("(") { depth += 1 }
      if tokens[index] == .symbol(")") { depth = max(0, depth - 1) }
      if depth == 0, tokens[index] == .symbol(",") {
        if start < index { output.append(start..<index) }
        start = index + 1
      }
    }
    if start < range.upperBound { output.append(start..<range.upperBound) }
    return output
  }

  private func matchingClose(at open: Int, upperBound: Int) -> Int? {
    var depth = 0
    for index in open..<upperBound {
      if tokens[index] == .symbol("(") { depth += 1 }
      if tokens[index] == .symbol(")") {
        depth -= 1
        if depth == 0 { return index }
      }
    }
    return nil
  }

  private func unwrapped(_ original: Range<Int>) -> Range<Int> {
    var range = original
    while range.count >= 2, tokens[range.lowerBound] == .symbol("("),
      matchingClose(at: range.lowerBound, upperBound: range.upperBound) == range.upperBound - 1
    {
      range = (range.lowerBound + 1)..<(range.upperBound - 1)
    }
    return range
  }

  private func normalize(_ entities: [String]) -> [String] {
    var unique: [String] = []
    for entity in entities where !unique.contains(entity) { unique.append(entity) }
    return unique.filter { candidate in
      !unique.contains { other in
        other != candidate && isAncestor(candidate, of: other)
      }
    }
  }

  private func isStrictlyFiner(_ candidate: [String], than reference: [String]) -> Bool {
    let candidate = normalize(candidate)
    let reference = normalize(reference)
    guard !candidate.isEmpty, !reference.isEmpty, candidate != reference else { return false }
    let candidateSet = Set(candidate)
    if Set(reference).isSubset(of: candidateSet) { return true }
    var traversed = false
    for entity in reference {
      var matched = false
      for candidateEntity in candidate {
        if entity == candidateEntity {
          matched = true
          break
        }
        if isAncestor(entity, of: candidateEntity) {
          matched = true
          traversed = true
          break
        }
      }
      if !matched { return false }
    }
    return traversed
  }

  private func isAncestor(_ ancestor: String, of descendant: String) -> Bool {
    Self.ancestorPairs.contains(EntityPair(ancestor: ancestor, descendant: descendant))
  }

  static func grain(
    for source: SQLSourceColumn,
    schema: PortfolioSchemaDocument
  ) -> [String] {
    if let relationship = schema.foreignKeys.first(where: {
      $0.fromTable == source.table && $0.fromColumn == source.column
    }) {
      return [relationship.toTable]
    }
    return [source.table]
  }

  private func orderedUnique(_ columns: [SQLSourceColumn]) -> [SQLSourceColumn] {
    var seen: Set<SQLSourceColumn> = []
    return columns.filter { seen.insert($0).inserted }
  }

  private func orderedUniqueDescriptors(
    _ descriptors: [ColumnDescriptor]
  ) -> [ColumnDescriptor] {
    var seen: Set<[SQLSourceColumn]> = []
    return descriptors.filter { seen.insert($0.sourceColumns).inserted }
  }

  private static let sourceBoundaryWords: Set<String> = [
    "where", "join", "left", "right", "inner", "outer", "cross", "full",
    "on", "using", "group", "order", "having", "limit", "union", "except",
    "intersect", "offset",
  ]

  private static let clauseWords: Set<String> = [
    "where", "group", "having", "order", "limit", "union", "except", "intersect",
  ]

  private struct EntityPair: Hashable {
    var ancestor: String
    var descendant: String
  }

  private static let ancestorPairs: Set<EntityPair> = {
    let schema = PortfolioSchemaCatalog.document
    var pairs: Set<EntityPair> = []
    for ancestor in schema.tables.keys {
      var frontier = [ancestor]
      var visited: Set<String> = []
      while let current = frontier.popLast() {
        guard visited.insert(current).inserted else { continue }
        for relationship in schema.foreignKeys where relationship.toTable == current {
          pairs.insert(
            EntityPair(ancestor: ancestor, descendant: relationship.fromTable))
          frontier.append(relationship.fromTable)
        }
      }
    }
    return pairs
  }()

  private static let compoundWords: Set<String> = [
    "union", "except", "intersect",
  ]
}
