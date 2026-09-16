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

package struct SQLScopedQueryBlock: Sendable, Equatable {
  package var range: NSRange
  package var scope: SQLQueryScope
}

extension SQLQueryScope {
  package static func mergedConservatively(
    _ scopes: [SQLQueryScope]
  ) -> SQLQueryScope {
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
      columns.mapValues { candidates in
        guard let first = candidates.first,
          candidates.allSatisfy({ $0 == first })
        else { return SQLQueryScopeColumn(source: nil) }
        return first
      }
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
}

/// One query-block-aware SQL analysis shared by database execution, grounding,
/// and chart presentation. It intentionally implements the constrained CREG
/// SELECT grammar rather than guessing from unrelated words in the statement.
package enum SQLQueryAnalyzer {
  package static func lineage(
    sql: String,
    outputColumnNames: [String],
    directOrigins: [SQLSourceColumn?] = [],
    reads: [SQLSourceRead] = [],
    fallbackColumns: [SQLResultColumnLineage?] = []
  ) -> SQLQueryLineage {
    let tokenization = SQLLexer.tokenize(sql)
    let analyzer = Analyzer(tokenization: tokenization)
    let readColumns = Set(
      reads.compactMap { read -> SQLSourceColumn? in
        guard let column = read.column else { return nil }
        return SQLSourceColumn(table: read.table, column: column)
      })
    guard let block = analyzer.analyze(
      range: tokenization.tokens.indices, inheritedCTEs: [:])
    else {
      let rejectsExternalOrigins = analyzer.rejectsExternalOrigins(
        in: tokenization.tokens.indices)
      return SQLQueryLineage(
        columns: outputColumnNames.indices.map { index in
          guard !rejectsExternalOrigins else { return nil }
          if directOrigins.indices.contains(index), let origin = directOrigins[index] {
            return directLineage(for: origin)
          }
          return fallbackLineage(
            at: index,
            fallbackColumns: fallbackColumns,
            readColumns: readColumns)
        },
        reads: reads,
        completeness: .incomplete)
    }

    let alignedOutputs = alignedOutputs(
      block.outputs, with: outputColumnNames)
    let columns = outputColumnNames.indices.map { index -> SQLResultColumnLineage? in
      let alignedOutput = alignedOutputs[index]
      var descriptor = alignedOutput?.descriptor
      let positionalOutput =
        block.outputs.count == outputColumnNames.count
        ? block.outputs[index] : nil
      let candidateOutput = alignedOutput
        ?? positionalOutput
      let permitsPhysicalOnlyOrigin = block.externalOriginPolicy != .physicalOnly
        || candidateOutput?.descriptor.hasOpaqueOrigin == false
      if permitsPhysicalOnlyOrigin,
        descriptor?.hasOpaqueOrigin != true,
        block.externalOriginPolicy.allows(
        directOrigins.indices.contains(index) ? directOrigins[index] : nil,
        physicalTables: block.physicalTables),
        directOrigins.indices.contains(index),
        let origin = directOrigins[index],
        descriptor == nil
          || descriptor?.preservesSourceDomain == true
          || descriptor.map({
            $0.isDirectReference
              && $0.sourceColumns.isEmpty
              && $0.chartGrain.isEmpty
              && $0.aggregation == nil
          }) == true
      {
        let grain = Analyzer.grain(
          for: origin, schema: PortfolioSchemaCatalog.document)
        descriptor = ColumnDescriptor(
          sourceColumns: [origin],
          expressionGrain: grain,
          chartGrain: grain,
          aggregation: nil,
          aggregateCalls: [],
          preservesSourceDomain: true,
          isDirectReference: true)
      }
      if let descriptor {
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
        if !descriptor.sourceColumns.isEmpty || !descriptor.chartGrain.isEmpty
          || descriptor.aggregation != nil
        {
          return SQLResultColumnLineage(
            sourceColumns: descriptor.sourceColumns,
            sourceGrain: descriptor.chartGrain,
            aggregation: descriptor.aggregation,
            preservesSourceDomain: descriptor.preservesSourceDomain)
        }
      }
      guard alignedOutput == nil,
        block.externalOriginPolicy == .all,
        let fallback = fallbackLineage(
          at: index,
          fallbackColumns: fallbackColumns,
          readColumns: readColumns)
      else { return nil }
      return fallback
    }
    return SQLQueryLineage(
      columns: columns,
      rowGrain: block.rowGrain,
      reads: reads,
      completeness: .complete)
  }

  package static func scope(in sql: String) -> SQLQueryScope {
    let tokenization = SQLLexer.tokenize(sql)
    return Analyzer(tokenization: tokenization).analyze(
      range: tokenization.tokens.indices, inheritedCTEs: [:]
    )?.scope
      ?? SQLQueryScope(
        aliases: [:], tables: [], qualifiedColumns: [:], unqualifiedColumns: [:])
  }

  package static func scopedQueryBlocks(in sql: String) -> [SQLScopedQueryBlock] {
    let tokenization = SQLLexer.tokenize(sql)
    let analyzer = Analyzer(tokenization: tokenization, collectsNestedScopes: true)
    if analyzer.analyze(
      range: tokenization.tokens.indices, inheritedCTEs: [:]) == nil
    {
      // An unsupported VALUES construct does not invalidate independently
      // analyzed SELECT blocks. A fresh analyzer keeps scopes cached by the
      // failed pass from leaking into a different CTE environment.
      let recovery = Analyzer(
        tokenization: tokenization, collectsNestedScopes: true)
      guard recovery.recoverScopesInValidUnsupportedConstruct() else { return [] }
      return recovery.scopedQueryBlocks
    }
    return analyzer.scopedQueryBlocks
  }

  private static func alignedOutputs(
    _ analyzed: [QueryOutput],
    with outputColumnNames: [String]
  ) -> [QueryOutput?] {
    let left = analyzed.map { normalizedRelationColumnName($0.name) }
    let right = outputColumnNames.map(normalizedRelationColumnName)
    if left.count == right.count,
      zip(left, right).allSatisfy({ $0 == $1 })
    {
      return analyzed.map(Optional.some)
    }
    let prefix = lcsTable(left, right)
    let optimal = prefix[left.count][right.count]
    guard optimal > 0 else { return Array(repeating: nil, count: right.count) }
    let suffix = lcsSuffixTable(left, right)
    return right.indices.map { rightIndex in
      var candidates: [Int] = []
      for leftIndex in left.indices where left[leftIndex] == right[rightIndex] {
        if prefix[leftIndex][rightIndex] + 1
          + suffix[leftIndex + 1][rightIndex + 1] == optimal
        {
          candidates.append(leftIndex)
        }
      }
      let bestWithoutColumn = (0...left.count).reduce(0) { best, leftIndex in
        max(
          best,
          prefix[leftIndex][rightIndex]
            + suffix[leftIndex][rightIndex + 1])
      }
      guard bestWithoutColumn < optimal,
        candidates.count == 1,
        let match = candidates.first
      else { return nil }
      return analyzed[match]
    }
  }

  private static func lcsTable(_ left: [String], _ right: [String]) -> [[Int]] {
    var table = Array(
      repeating: Array(repeating: 0, count: right.count + 1),
      count: left.count + 1)
    for leftIndex in left.indices {
      for rightIndex in right.indices {
        table[leftIndex + 1][rightIndex + 1] =
          left[leftIndex] == right[rightIndex]
          ? table[leftIndex][rightIndex] + 1
          : max(
            table[leftIndex][rightIndex + 1],
            table[leftIndex + 1][rightIndex])
      }
    }
    return table
  }

  private static func lcsSuffixTable(
    _ left: [String], _ right: [String]
  ) -> [[Int]] {
    var table = Array(
      repeating: Array(repeating: 0, count: right.count + 1),
      count: left.count + 1)
    for leftIndex in left.indices.reversed() {
      for rightIndex in right.indices.reversed() {
        table[leftIndex][rightIndex] =
          left[leftIndex] == right[rightIndex]
          ? table[leftIndex + 1][rightIndex + 1] + 1
          : max(
            table[leftIndex + 1][rightIndex],
            table[leftIndex][rightIndex + 1])
      }
    }
    return table
  }

  private static func directLineage(
    for origin: SQLSourceColumn
  ) -> SQLResultColumnLineage {
    SQLResultColumnLineage(
      sourceColumns: [origin],
      sourceGrain: Analyzer.grain(
        for: origin, schema: PortfolioSchemaCatalog.document),
      preservesSourceDomain: true)
  }

  private static func fallbackLineage(
    at index: Int,
    fallbackColumns: [SQLResultColumnLineage?],
    readColumns: Set<SQLSourceColumn>
  ) -> SQLResultColumnLineage? {
    guard !readColumns.isEmpty,
      fallbackColumns.indices.contains(index),
      let fallback = fallbackColumns[index],
      fallback.aggregation == nil,
      !fallback.sourceColumns.isEmpty,
      fallback.sourceColumns.allSatisfy(readColumns.contains)
    else { return nil }
    return SQLResultColumnLineage(
      sourceColumns: fallback.sourceColumns,
      sourceGrain: Analyzer.normalizedGrain(
        for: fallback.sourceColumns,
        schema: PortfolioSchemaCatalog.document),
      preservesSourceDomain: false)
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

private struct SQLTokenization {
  var tokens: [SQLToken]
  var ranges: [NSRange]
}

private enum SQLLexer {
  static func tokenize(_ sql: String) -> SQLTokenization {
    let characters = Array(sql)
    var offsets: [Int] = []
    var utf16Offset = 0
    for character in characters {
      offsets.append(utf16Offset)
      utf16Offset += String(character).utf16.count
    }
    offsets.append(utf16Offset)
    var output: [SQLToken] = []
    var ranges: [NSRange] = []
    func append(_ token: SQLToken, from start: Int, to end: Int) {
      output.append(token)
      ranges.append(
        NSRange(
          location: offsets[start],
          length: offsets[end] - offsets[start]))
    }
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
        append(.string(value), from: index, to: next)
        index = next
        continue
      }
      if character == "\"" || character == "`" || character == "[" {
        let closing: Character = character == "[" ? "]" : character
        let (value, next) = quoted(characters, from: index, closing: closing)
        append(.word(value.lowercased()), from: index, to: next)
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
        append(
          .word(String(characters[start..<index]).lowercased()),
          from: start,
          to: index)
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
        append(.number(String(characters[start..<index])), from: start, to: index)
        continue
      }
      append(.symbol(character), from: index, to: index + 1)
      index += 1
    }
    return SQLTokenization(tokens: output, ranges: ranges)
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
  var aggregateCalls: [AggregateCallAnalysis]
  var preservesSourceDomain: Bool
  var isDirectReference: Bool
  var hasOpaqueOrigin = false

  var hasGroupedAggregateCall: Bool {
    aggregateCalls.contains { !$0.isWindowed }
  }
}

private struct AggregateCallAnalysis {
  var operation: SQLAggregateOperation
  var inputGrain: [String]
  var isWindowed: Bool
}

private struct AggregateAnalysis {
  var operation: SQLAggregateOperation?
  var calls: [AggregateCallAnalysis]

  var hasGroupedAggregateCall: Bool {
    calls.contains { !$0.isWindowed }
  }
}

private struct QueryOutput {
  var name: String
  var descriptor: ColumnDescriptor
}

private enum ExternalOriginPolicy: Equatable {
  case all
  case physicalOnly
  case none

  static func mostRestrictive<S: Sequence>(
    _ policies: S
  ) -> ExternalOriginPolicy where S.Element == ExternalOriginPolicy {
    policies.reduce(.all) { current, candidate in
      switch (current, candidate) {
      case (.none, _), (_, .none): .none
      case (.physicalOnly, _), (_, .physicalOnly): .physicalOnly
      case (.all, .all): .all
      }
    }
  }

  func allows(_ origin: SQLSourceColumn?, physicalTables: Set<String>) -> Bool {
    guard let origin else { return false }
    switch self {
    case .all: return true
    case .physicalOnly: return physicalTables.contains(origin.table)
    case .none: return false
    }
  }
}

private struct Relation {
  var name: String
  var aliases: Set<String>
  let outputs: [QueryOutput]
  let rowGrain: [String]
  let physicalTables: Set<String>
  let externalOriginPolicy: ExternalOriginPolicy
  let columns: [String: ColumnDescriptor]

  init(
    name: String,
    aliases: Set<String>,
    outputs: [QueryOutput],
    rowGrain: [String],
    physicalTables: Set<String>,
    externalOriginPolicy: ExternalOriginPolicy
  ) {
    self.name = name
    self.aliases = aliases
    self.outputs = outputs
    self.rowGrain = rowGrain
    self.physicalTables = physicalTables
    self.externalOriginPolicy = externalOriginPolicy
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
  var externalOriginPolicy: ExternalOriginPolicy
}

private enum BlockAnalysisOutcome {
  case success(QueryBlock)
  case failure(rejectsExternalOrigins: Bool)
}

private final class Analyzer {
  deinit {}

  let tokens: [SQLToken]
  let tokenRanges: [NSRange]
  private let schema = PortfolioSchemaCatalog.document
  private let collectsNestedScopes: Bool
  private var outcomes: [Range<Int>: BlockAnalysisOutcome] = [:]

  init(
    tokenization: SQLTokenization,
    collectsNestedScopes: Bool = false
  ) {
    tokens = tokenization.tokens
    tokenRanges = tokenization.ranges
    self.collectsNestedScopes = collectsNestedScopes
  }

  var scopedQueryBlocks: [SQLScopedQueryBlock] {
    outcomes.compactMap { range, outcome in
      guard case .success(let block) = outcome else { return nil }
      guard let sourceRange = sourceRange(for: range) else { return nil }
      return SQLScopedQueryBlock(range: sourceRange, scope: block.scope)
    }.sorted {
      if $0.range.location != $1.range.location {
        return $0.range.location < $1.range.location
      }
      return $0.range.length > $1.range.length
    }
  }

  private struct ParsedCTEs {
    var mainStart: Int
    var ctes: [String: Relation]
    var containsValues: Bool
  }

  /// Parse one WITH clause for both ordinary analysis and VALUES recovery.
  /// A VALUES CTE shadows a same-named schema table but proves no physical
  /// column origin, even when its explicit output names are known.
  private func parseCTEs(
    in range: Range<Int>, inheritedCTEs: [String: Relation]
  ) -> ParsedCTEs? {
    var index = range.lowerBound
    var ctes = inheritedCTEs
    var containsValues = false
    guard tokens[index].word == "with" else {
      return ParsedCTEs(mainStart: index, ctes: ctes, containsValues: false)
    }
    index += 1
    if index < range.upperBound, tokens[index].word == "recursive" {
      index += 1
    }
    repeat {
      guard index < range.upperBound,
        let name = tokens[index].word,
        name != "select", name != "values"
      else { return nil }
      index += 1
      var declaredOutputNames: [String]?
      if index < range.upperBound, tokens[index] == .symbol("(") {
        guard let close = matchingClose(at: index, upperBound: range.upperBound)
        else { return nil }
        let declarations = splitTopLevel(
          (index + 1)..<close, preservingEmptySegments: true)
        guard !declarations.isEmpty,
          declarations.allSatisfy({
            $0.count == 1 && tokens[$0.lowerBound].word != nil
          })
        else { return nil }
        declaredOutputNames = declarations.compactMap {
          tokens[$0.lowerBound].word
        }
        index = close + 1
      }
      guard index < range.upperBound, tokens[index].word == "as"
      else { return nil }
      index += 1
      if index < range.upperBound, tokens[index].word == "materialized" {
        index += 1
      } else if index + 1 < range.upperBound,
        tokens[index].word == "not",
        tokens[index + 1].word == "materialized"
      {
        index += 2
      }
      guard index < range.upperBound,
        tokens[index] == .symbol("("),
        let close = matchingClose(at: index, upperBound: range.upperBound),
        index + 1 < close
      else { return nil }
      let body = (index + 1)..<close
      if tokens[body.lowerBound].word == "values" {
        let valuesBody: Range<Int>
        let recursiveArms: [Range<Int>]
        switch compoundArmRanges(in: body) {
        case .none:
          valuesBody = body
          recursiveArms = []
        case .arms(let arms):
          guard let anchor = arms.first,
            tokens[anchor.lowerBound].word == "values",
            arms.dropFirst().allSatisfy({
              tokens[$0.lowerBound].word == "select"
            })
          else { return nil }
          valuesBody = anchor
          recursiveArms = Array(arms.dropFirst())
        case .malformed:
          return nil
        }
        guard let arity = valuesArity(in: valuesBody),
          declaredOutputNames == nil || declaredOutputNames?.count == arity
        else { return nil }
        let outputNames = declaredOutputNames
          ?? (1...arity).map { "column\($0)" }
        ctes[name] = opaqueRelation(
          name: name, outputNames: outputNames,
          externalOriginPolicy: .physicalOnly)
        if collectsNestedScopes {
          analyzeNestedQueryBlocks(in: valuesBody, inheritedCTEs: ctes)
        }
        for arm in recursiveArms {
          guard let analyzed = analyze(range: arm, inheritedCTEs: ctes),
            analyzed.outputs.count == arity
          else { return nil }
        }
        containsValues = true
      } else {
        // A self-reference must resolve to this CTE while its body is parsed.
        // SQLite rejects invalid cycles when the statement is executed.
        ctes[name] = opaqueRelation(
          name: name, outputNames: declaredOutputNames ?? [],
          externalOriginPolicy: .physicalOnly)
        if declaredOutputNames == nil {
          switch compoundArmRanges(in: body) {
          case .arms(let arms):
            guard let anchor = arms.first,
              tokens[anchor.lowerBound].word == "select",
              let anchorBlock = analyze(range: anchor, inheritedCTEs: ctes)
            else { return nil }
            ctes[name] = opaqueRelation(
              name: name,
              outputNames: anchorBlock.outputs.map(\.name),
              externalOriginPolicy: .physicalOnly)
          case .none:
            break
          case .malformed:
            return nil
          }
        }
        guard let block = analyze(range: body, inheritedCTEs: ctes)
        else { return nil }
        var parsed = relation(name: name, block: block)
        if let declaredOutputNames {
          guard declaredOutputNames.count == parsed.outputs.count else {
            return nil
          }
          parsed = Relation(
            name: parsed.name,
            aliases: parsed.aliases,
            outputs: zip(parsed.outputs, declaredOutputNames).map {
              output, declaredName in
              QueryOutput(name: declaredName, descriptor: output.descriptor)
            },
            rowGrain: parsed.rowGrain,
            physicalTables: parsed.physicalTables,
            externalOriginPolicy: parsed.externalOriginPolicy)
        }
        ctes[name] = parsed
      }
      index = close + 1
      if index < range.upperBound, tokens[index] == .symbol(",") {
        index += 1
        continue
      }
      break
    } while true
    return ParsedCTEs(
      mainStart: index, ctes: ctes, containsValues: containsValues)
  }

  private func emptyOpaqueDescriptor() -> ColumnDescriptor {
    ColumnDescriptor(
      sourceColumns: [], expressionGrain: [], chartGrain: [],
      aggregation: nil, aggregateCalls: [],
      preservesSourceDomain: false, isDirectReference: false)
  }

  private func opaqueRelation(
    name: String,
    outputNames: [String] = [],
    externalOriginPolicy: ExternalOriginPolicy
  ) -> Relation {
    var descriptor = emptyOpaqueDescriptor()
    descriptor.hasOpaqueOrigin = true
    return Relation(
      name: name, aliases: [name],
      outputs: outputNames.map {
        QueryOutput(name: $0, descriptor: descriptor)
      },
      rowGrain: [Self.opaqueEntity(for: name)],
      physicalTables: [], externalOriginPolicy: externalOriginPolicy)
  }

  /// Recover only SELECT scopes whose containing unsupported construct has a
  /// well-formed CTE/compound/VALUES skeleton. Never treat a malformed outer
  /// statement as proof that its inner predicates belong to a real query.
  func recoverScopesInValidUnsupportedConstruct() -> Bool {
    let range = tokens.indices
    guard !range.isEmpty, hasBalancedParentheses(in: range) else { return false }
    guard let parsed = parseCTEs(in: range, inheritedCTEs: [:]) else {
      return false
    }
    let mainStart = parsed.mainStart
    let ctes = parsed.ctes
    var foundUnsupportedValues = parsed.containsValues

    guard mainStart < range.upperBound else { return false }
    let main = mainStart..<range.upperBound
    switch compoundArmRanges(in: main) {
    case .malformed:
      return false
    case .arms(let arms):
      guard arms.allSatisfy({ isRecoverableArm($0) }) else { return false }
      foundUnsupportedValues = foundUnsupportedValues
        || arms.contains { tokens[$0.lowerBound].word == "values" }
      guard foundUnsupportedValues else { return false }
      for arm in arms where tokens[arm.lowerBound].word == "select" {
        guard analyze(range: arm, inheritedCTEs: ctes) != nil else { return false }
      }
      for arm in arms where tokens[arm.lowerBound].word == "values" {
        analyzeNestedQueryBlocks(in: arm, inheritedCTEs: ctes)
      }
    case .none:
      guard isRecoverableArm(main) else { return false }
      foundUnsupportedValues = foundUnsupportedValues
        || tokens[main.lowerBound].word == "values"
      guard foundUnsupportedValues else { return false }
      if tokens[main.lowerBound].word == "select" {
        guard analyze(range: main, inheritedCTEs: ctes) != nil else { return false }
      } else {
        analyzeNestedQueryBlocks(in: main, inheritedCTEs: ctes)
      }
    }
    return true
  }

  private func hasBalancedParentheses(in range: Range<Int>) -> Bool {
    var depth = 0
    for index in range {
      if tokens[index] == .symbol("(") { depth += 1 }
      if tokens[index] == .symbol(")") {
        depth -= 1
        if depth < 0 { return false }
      }
    }
    return depth == 0
  }

  private func isRecoverableArm(_ range: Range<Int>) -> Bool {
    if tokens[range.lowerBound].word == "values" {
      return valuesArity(in: range) != nil
    }
    guard tokens[range.lowerBound].word == "select",
      range.count > 1,
      tokens[range.lowerBound + 1].word != "from"
    else { return false }
    return true
  }

  private func valuesArity(in range: Range<Int>) -> Int? {
    var index = range.lowerBound + 1
    guard index < range.upperBound else { return nil }
    var arity: Int?
    while index < range.upperBound {
      guard tokens[index] == .symbol("("),
        let close = matchingClose(at: index, upperBound: range.upperBound),
        index + 1 < close
      else { return nil }
      let cells = splitTopLevel(
        (index + 1)..<close, preservingEmptySegments: true)
      guard cells.allSatisfy({ !$0.isEmpty }),
        arity == nil || arity == cells.count
      else { return nil }
      arity = cells.count
      index = close + 1
      if index == range.upperBound { return arity }
      guard tokens[index] == .symbol(",") else { return nil }
      index += 1
    }
    return nil
  }

  func rejectsExternalOrigins(in range: Range<Int>) -> Bool {
    guard case .failure(let rejectsExternalOrigins) = outcomes[unwrapped(range)]
    else { return false }
    return rejectsExternalOrigins
  }

  func analyze(
    range: Range<Int>,
    inheritedCTEs: [String: Relation]
  ) -> QueryBlock? {
    let range = unwrapped(range)
    guard !range.isEmpty else { return nil }
    if let cached = outcomes[range] {
      guard case .success(let block) = cached else { return nil }
      return block
    }
    let rejectsForTopLevelCompound = containsTopLevelCompound(in: range)
    var ctes = inheritedCTEs
    var publishesNestedScopes = true
    defer {
      if collectsNestedScopes, publishesNestedScopes {
        analyzeNestedQueryBlocks(in: range, inheritedCTEs: ctes)
      }
    }
    func fail(rejectsExternalOrigins: Bool = false) -> QueryBlock? {
      outcomes[range] = .failure(
        rejectsExternalOrigins:
          rejectsForTopLevelCompound || rejectsExternalOrigins)
      return nil
    }
    func succeed(_ block: QueryBlock) -> QueryBlock {
      outcomes[range] = .success(block)
      return block
    }
    // Snapshot only WITH ranges; retaining this dictionary for every plain
    // SELECT would force a copy whenever its analysis caches a new block.
    let outcomesBeforeCTEs =
      tokens[range.lowerBound].word == "with" ? outcomes : nil
    guard let parsed = parseCTEs(in: range, inheritedCTEs: inheritedCTEs)
    else {
      // A malformed WITH clause must not publish nested SELECTs analyzed
      // while parsing its bodies, or scan them again with inherited tables.
      if let outcomesBeforeCTEs { outcomes = outcomesBeforeCTEs }
      publishesNestedScopes = false
      return fail(rejectsExternalOrigins: true)
    }
    let selectIndex = parsed.mainStart
    ctes = parsed.ctes

    switch compoundArmRanges(in: selectIndex..<range.upperBound) {
    case .malformed:
      return fail(rejectsExternalOrigins: true)
    case .arms(let armRanges):
      let arms = armRanges.compactMap {
        analyze(range: $0, inheritedCTEs: ctes)
      }
      guard arms.count == armRanges.count else {
        return fail(rejectsExternalOrigins: true)
      }
      let block = compoundBlock(from: arms)
      return succeed(block)
    case .none:
      break
    }

    guard selectIndex < range.upperBound, tokens[selectIndex].word == "select"
    else { return fail() }

    var projectionStart = selectIndex + 1
    let boundaries = clauseBoundaries(in: projectionStart..<range.upperBound)
    let fromIndex = firstTopLevelWord(
      "from", in: projectionStart..<range.upperBound)
    let projectionEnd = fromIndex ?? boundaries.values.min() ?? range.upperBound
    let isDistinct =
      projectionStart < projectionEnd
      && tokens[projectionStart].word == "distinct"
    if isDistinct { projectionStart += 1 }

    let relations: [Relation]
    if let fromIndex {
      let fromEnd =
        boundaries.values.filter { $0 > fromIndex }.min()
        ?? range.upperBound
      relations = parseRelations(
        in: (fromIndex + 1)..<fromEnd, ctes: ctes)
    } else {
      relations = []
    }
    let fromGrain = normalize(relations.flatMap(\.rowGrain))
    let projectionRanges = splitTopLevel(projectionStart..<projectionEnd)

    var drafts = projectionRanges.flatMap { projection -> [QueryOutput] in
      if let expanded = expandedWildcard(projection, relations: relations) {
        return expanded
      }
      let (expression, alias) = expressionAndAlias(projection)
      let references = references(in: expression, relations: relations, ctes: ctes)
      let localAggregation = aggregate(
        in: expression,
        relations: relations,
        ctes: ctes,
        fromGrain: fromGrain)
      let aggregation =
        localAggregation.operation
        ?? (!localAggregation.hasGroupedAggregateCall
          && localAggregation.calls.isEmpty
          && references.count == 1
          ? references[0].aggregation : nil)
      let rawGrain =
        references.isEmpty && aggregation == .count
        ? fromGrain
        : normalize(references.flatMap(\.expressionGrain))
      let chartGrain =
        localAggregation.calls.isEmpty
        ? normalize(references.flatMap(\.chartGrain))
        : rawGrain
      let descriptor = ColumnDescriptor(
        sourceColumns: orderedUnique(references.flatMap(\.sourceColumns)),
        expressionGrain: rawGrain,
        chartGrain: chartGrain,
        aggregation: aggregation,
        aggregateCalls: localAggregation.calls,
        preservesSourceDomain:
          localAggregation.calls.isEmpty
          && references.count == 1
          && isDirectColumnReference(expression)
          && references[0].preservesSourceDomain,
        isDirectReference: isDirectColumnReference(expression),
        hasOpaqueOrigin: references.contains(where: \.hasOpaqueOrigin))
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

    let hasAggregate = drafts.contains { $0.descriptor.hasGroupedAggregateCall }
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
      guard drafts[index].descriptor.hasGroupedAggregateCall else { continue }
      let rawGrain = drafts[index].descriptor.expressionGrain
      let effectiveGroup = groupGrain.isEmpty ? rowGrain : groupGrain
      let unsafeGrain = normalize(
        drafts[index].descriptor.aggregateCalls
          .filter {
            !$0.isWindowed
              && $0.operation.isDuplicateSensitive
              && !fromGrain.isEmpty
              && isStrictlyFiner(fromGrain, than: $0.inputGrain)
          }
          .flatMap(\.inputGrain))
      drafts[index].descriptor.chartGrain =
        !unsafeGrain.isEmpty
        ? unsafeGrain : (effectiveGroup.isEmpty ? rawGrain : effectiveGroup)
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
          source: descriptor.preservesSourceDomain
            && descriptor.sourceColumns.count == 1
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
    let block = QueryBlock(
      outputs: drafts,
      rowGrain: rowGrain,
      scope: SQLQueryScope(
        aliases: aliases,
        tables: tables,
        qualifiedColumns: qualifiedColumns,
        unqualifiedColumns: unqualifiedColumns),
      physicalTables: tables,
      externalOriginPolicy: ExternalOriginPolicy.mostRestrictive(
        relations.lazy.map(\.externalOriginPolicy)))
    return succeed(block)
  }

  private func relation(name: String, block: QueryBlock) -> Relation {
    Relation(
      name: name,
      aliases: [name],
      outputs: block.outputs,
      rowGrain: block.rowGrain,
      physicalTables: block.physicalTables,
      externalOriginPolicy: block.externalOriginPolicy)
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
            aggregateCalls: [],
            preservesSourceDomain: true,
            isDirectReference: true))
      },
      rowGrain: [name],
      physicalTables: [name],
      externalOriginPolicy: .all)
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
            var relation = opaqueRelation(
              name: "derived", externalOriginPolicy: .none)
            index = close + 1
            index = applyingAlias(to: &relation, at: index, upperBound: range.upperBound)
            relations.append(relation)
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
        var explicitlyQualifiedPhysicalTable = false
        if index + 2 < range.upperBound,
          tokens[index + 1] == .symbol("."),
          let qualifiedName = tokens[index + 2].word,
          schema.tables[qualifiedName] != nil
        {
          relationName = qualifiedName
          nextIndex = index + 3
          explicitlyQualifiedPhysicalTable = true
        }
        let knownRelation =
          explicitlyQualifiedPhysicalTable
          ? physicalRelation(name: relationName)
          : (ctes[relationName] ?? physicalRelation(name: relationName))
        var relation =
          knownRelation
          ?? opaqueRelation(
            name: relationName, externalOriginPolicy: .all)
        if knownRelation == nil {
          // Unknown relations have no usable columns or physical-table scope,
          // but their cardinality can still duplicate every known source row.
          index = nextIndex
          if index < range.upperBound, tokens[index] == .symbol("("),
            let close = matchingClose(at: index, upperBound: range.upperBound)
          {
            index = close + 1
          }
        } else {
          index = nextIndex
        }
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

  private func aggregate(
    in range: Range<Int>,
    relations: [Relation],
    ctes: [String: Relation],
    fromGrain: [String]
  ) -> AggregateAnalysis {
    let searchable = indicesOutsideSubqueries(in: range)
    var calls: [AggregateCallAnalysis] = []
    for index in searchable {
      guard let name = tokens[index].word,
        index + 1 < range.upperBound,
        tokens[index + 1] == .symbol("("),
        let close = matchingClose(at: index + 1, upperBound: range.upperBound)
      else { continue }
      let argumentStart =
        index + 2 < close && tokens[index + 2].word == "distinct"
        ? index + 3 : index + 2
      let argumentRanges = splitTopLevel(argumentStart..<close)
      let operation: SQLAggregateOperation
      switch name {
      case "sum": operation = .sum
      case "avg": operation = .average
      case "min":
        guard argumentRanges.count == 1 else { continue }
        operation = .minimum
      case "max":
        guard argumentRanges.count == 1 else { continue }
        operation = .maximum
      case "total": operation = .total
      case "count":
        if index + 2 < range.upperBound, tokens[index + 2].word == "distinct" {
          operation = .countDistinct
        } else {
          operation = .count
        }
      default: continue
      }
      let references = references(
        in: argumentStart..<close, relations: relations, ctes: ctes)
      let inputGrain =
        references.isEmpty && operation == .count
        ? fromGrain
        : normalize(references.flatMap(\.expressionGrain))
      calls.append(
        AggregateCallAnalysis(
          operation: operation,
          inputGrain: inputGrain,
          isWindowed: isWindowedAggregate(
            after: close, upperBound: range.upperBound)))
    }
    return AggregateAnalysis(
      operation:
        calls.count == 1 && calls[0].isWindowed == false
        ? calls[0].operation : nil,
      calls: calls)
  }

  private func isWindowedAggregate(after callClose: Int, upperBound: Int) -> Bool {
    var index = callClose + 1
    if index < upperBound, tokens[index].word == "filter",
      index + 1 < upperBound, tokens[index + 1] == .symbol("("),
      let filterClose = matchingClose(at: index + 1, upperBound: upperBound)
    {
      index = filterClose + 1
    }
    return index < upperBound && tokens[index].word == "over"
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
    let range = unwrapped(range)
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

  private enum CompoundArmSplit {
    case none
    case malformed
    case arms([Range<Int>])
  }

  private func compoundArmRanges(
    in range: Range<Int>
  ) -> CompoundArmSplit {
    guard !range.isEmpty else { return .none }
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
        guard start < index else { return .malformed }
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
    guard !arms.isEmpty else { return .none }
    guard start < range.upperBound else { return .malformed }
    arms.append(start..<range.upperBound)
    return .arms(arms)
  }

  private func compoundBlock(from arms: [QueryBlock]) -> QueryBlock {
    let emptyDescriptor = emptyOpaqueDescriptor()
    let outputs = arms[0].outputs.map {
      QueryOutput(name: $0.name, descriptor: emptyDescriptor)
    }
    let scope = SQLQueryScope.mergedConservatively(arms.map(\.scope))
    return QueryBlock(
      outputs: outputs,
      rowGrain: [],
      scope: scope,
      physicalTables: Set(arms.flatMap(\.physicalTables)),
      externalOriginPolicy: .none)
  }

  private func containsTopLevelCompound(in range: Range<Int>) -> Bool {
    var depth = 0
    for index in range {
      if tokens[index] == .symbol("(") {
        depth += 1
      } else if tokens[index] == .symbol(")") {
        depth = max(0, depth - 1)
      } else if depth == 0, let word = tokens[index].word,
        Self.compoundWords.contains(word)
      {
        return true
      }
    }
    return false
  }

  private func clauseBoundaries(
    in range: Range<Int>
  ) -> [String: Int] {
    var result: [String: Int] = [:]
    var depth = 0
    var index = range.lowerBound
    while index < range.upperBound {
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

  private func splitTopLevel(
    _ range: Range<Int>,
    preservingEmptySegments: Bool = false
  ) -> [Range<Int>] {
    guard !range.isEmpty else { return [] }
    var output: [Range<Int>] = []
    var depth = 0
    var start = range.lowerBound
    for index in range {
      if tokens[index] == .symbol("(") { depth += 1 }
      if tokens[index] == .symbol(")") { depth = max(0, depth - 1) }
      if depth == 0, tokens[index] == .symbol(",") {
        if preservingEmptySegments || start < index {
          output.append(start..<index)
        }
        start = index + 1
      }
    }
    if preservingEmptySegments || start < range.upperBound {
      output.append(start..<range.upperBound)
    }
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

  private func sourceRange(for tokenRange: Range<Int>) -> NSRange? {
    guard !tokenRange.isEmpty,
      tokenRanges.indices.contains(tokenRange.lowerBound),
      tokenRanges.indices.contains(tokenRange.upperBound - 1)
    else { return nil }
    let first = tokenRanges[tokenRange.lowerBound]
    let last = tokenRanges[tokenRange.upperBound - 1]
    return NSRange(
      location: first.location,
      length: NSMaxRange(last) - first.location)
  }

  private func analyzeNestedQueryBlocks(
    in range: Range<Int>,
    inheritedCTEs: [String: Relation]
  ) {
    var index = range.lowerBound
    while index < range.upperBound {
      guard tokens[index] == .symbol("("),
        index + 1 < range.upperBound,
        let firstWord = tokens[index + 1].word,
        firstWord == "select" || firstWord == "with",
        let close = matchingClose(at: index, upperBound: range.upperBound)
      else {
        index += 1
        continue
      }
      if index + 1 < close {
        _ = analyze(
          range: (index + 1)..<close,
          inheritedCTEs: inheritedCTEs)
        index = close + 1
      } else {
        index += 1
      }
    }
  }

  private func normalize(_ entities: [String]) -> [String] {
    Self.normalizedEntities(entities)
  }

  private static func normalizedEntities(_ entities: [String]) -> [String] {
    var unique: [String] = []
    for entity in entities where !unique.contains(entity) { unique.append(entity) }
    return unique.filter { candidate in
      !unique.contains { other in
        other != candidate && isAncestor(candidate, of: other)
      }
    }.sorted()
  }

  private func isStrictlyFiner(_ candidate: [String], than reference: [String]) -> Bool {
    let candidate = normalize(candidate)
    let reference = normalize(reference)
    guard !candidate.isEmpty, !reference.isEmpty else { return false }
    return isAtLeastAsFine(candidate, as: reference)
      && !isAtLeastAsFine(reference, as: candidate)
  }

  private func isAtLeastAsFine(
    _ candidate: [String],
    as reference: [String]
  ) -> Bool {
    reference.allSatisfy { entity in
      candidate.contains { candidateEntity in
        entity == candidateEntity || isAncestor(entity, of: candidateEntity)
      }
    }
  }

  private func isAncestor(_ ancestor: String, of descendant: String) -> Bool {
    Self.isAncestor(ancestor, of: descendant)
  }

  private static func isAncestor(_ ancestor: String, of descendant: String) -> Bool {
    ancestorPairs.contains(EntityPair(ancestor: ancestor, descendant: descendant))
  }

  static func grain(
    for source: SQLSourceColumn,
    schema: PortfolioSchemaDocument
  ) -> [String] {
    guard schema.tables[source.table] != nil else {
      return [opaqueEntity(for: source.table)]
    }
    if let relationship = schema.foreignKeys.first(where: {
      $0.fromTable == source.table && $0.fromColumn == source.column
    }) {
      return [relationship.toTable]
    }
    return [source.table]
  }

  static func normalizedGrain(
    for sources: [SQLSourceColumn],
    schema: PortfolioSchemaDocument
  ) -> [String] {
    normalizedEntities(sources.flatMap { grain(for: $0, schema: schema) })
  }

  private static func opaqueEntity(for relationName: String) -> String {
    "creg.opaque.\(relationName)"
  }

  private func orderedUnique(_ columns: [SQLSourceColumn]) -> [SQLSourceColumn] {
    var seen: Set<SQLSourceColumn> = []
    return columns.filter { seen.insert($0).inserted }.sorted {
      if $0.table != $1.table { return $0.table < $1.table }
      return $0.column < $1.column
    }
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
