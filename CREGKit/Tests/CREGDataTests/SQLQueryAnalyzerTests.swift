import CREGCore
import Foundation
import Testing

@testable import CREGData

@Suite struct SQLQueryAnalyzerTests {
  @Test func lineageCompletenessDefaultsFailClosedInConstructorAndDecoder() throws {
    let constructed = SQLQueryLineage(columns: [nil])
    let decoded = try JSONDecoder().decode(
      SQLQueryLineage.self,
      from: Data(#"{"columns":[null],"rowGrain":[],"reads":[]}"#.utf8))
    let analyzed = SQLQueryAnalyzer.lineage(
      sql: "SELECT city FROM properties", outputColumnNames: ["city"])
    #expect(constructed.completeness == .incomplete)
    #expect(decoded.completeness == .incomplete)
    #expect(analyzed.completeness == .complete)
  }

  @Test func discoversUnaliasedAndCommaJoinsWithoutSkippingSources() throws {
    let joined = SQLQueryAnalyzer.lineage(
      sql: """
        SELECT leases.status, SUM(properties.current_market_value) AS total_value
        FROM properties JOIN leases ON leases.property_id = properties.property_id
        GROUP BY leases.status
        """,
      outputColumnNames: ["status", "total_value"])
    let category = try #require(joined.columns[0])
    let measure = try #require(joined.columns[1])

    #expect(category.sourceColumns == [.init(table: "leases", column: "status")])
    #expect(category.sourceGrain == ["leases"])
    #expect(measure.sourceGrain == ["properties"])
    #expect(joined.rowGrain == ["leases"])

    let comma = SQLQueryAnalyzer.lineage(
      sql: """
        SELECT leases.status, SUM(properties.current_market_value) AS total_value
        FROM properties, leases
        WHERE leases.property_id = properties.property_id
        GROUP BY leases.status
        """,
      outputColumnNames: ["status", "total_value"])
    #expect(comma.columns == joined.columns)
    #expect(comma.rowGrain == joined.rowGrain)
  }

  @Test func keepsAliasesLocalToTheirQueryBlock() throws {
    let lineage = SQLQueryAnalyzer.lineage(
      sql: """
        SELECT p.status,
               (SELECT p.status FROM leases p LIMIT 1) AS lease_status
        FROM properties p
        """,
      outputColumnNames: ["status", "lease_status"])

    #expect(
      try #require(lineage.columns[0]).sourceColumns
        == [.init(table: "properties", column: "status")])
    #expect(
      try #require(lineage.columns[1]).sourceColumns
        == [.init(table: "leases", column: "status")])
  }

  @Test func unqualifiedScalarSubqueryColumnsStayInTheirQueryBlock() throws {
    let lineage = SQLQueryAnalyzer.lineage(
      sql: """
        SELECT p.name,
               (SELECT status FROM leases LIMIT 1) AS lease_status
        FROM properties p
        """,
      outputColumnNames: ["name", "lease_status"])

    #expect(
      try #require(lineage.columns[1]).sourceColumns
        == [.init(table: "leases", column: "status")])
  }

  @Test func scalarSubqueryAggregatesDoNotCollapseTheOuterRowGrain() throws {
    let lineage = SQLQueryAnalyzer.lineage(
      sql: """
        SELECT p.name,
               (SELECT SUM(l.annual_base_rent)
                FROM leases l
                WHERE l.property_id = p.property_id) AS total_rent
        FROM properties p
        """,
      outputColumnNames: ["name", "total_rent"])

    #expect(lineage.rowGrain == ["properties"])
    #expect(try #require(lineage.columns[1]).aggregation == .sum)
  }

  @Test func derivesCaseAndOpaqueBucketRowGrain() throws {
    let caseLineage = SQLQueryAnalyzer.lineage(
      sql: """
        SELECT CASE WHEN l.status = 'Active' THEN 'Active' ELSE 'Other' END AS bucket,
               SUM(p.current_market_value) AS total_value
        FROM properties p JOIN leases l ON l.property_id = p.property_id
        GROUP BY bucket
        """,
      outputColumnNames: ["bucket", "total_value"])
    #expect(try #require(caseLineage.columns[0]).sourceGrain == ["leases"])
    #expect(caseLineage.rowGrain == ["leases"])
    #expect(try #require(caseLineage.columns[1]).sourceGrain == ["properties"])

    let opaque = SQLQueryAnalyzer.lineage(
      sql: """
        SELECT 'All' AS bucket, SUM(p.current_market_value) AS total_value
        FROM properties p JOIN leases l ON l.property_id = p.property_id
        GROUP BY bucket
        """,
      outputColumnNames: ["bucket", "total_value"])
    #expect(opaque.columns[0] == nil)
    #expect(opaque.rowGrain == ["leases"])
    #expect(try #require(opaque.columns[1]).sourceGrain == ["properties"])
  }

  @Test func countStarUsesOnlyTheOuterNormalizedRowGrain() throws {
    let joined = SQLQueryAnalyzer.lineage(
      sql: """
        SELECT l.lease_type, COUNT(*) AS lease_count
        FROM leases l JOIN properties p ON p.property_id = l.property_id
        GROUP BY l.lease_type
        """,
      outputColumnNames: ["lease_type", "lease_count"])
    #expect(try #require(joined.columns[1]).sourceGrain == ["leases"])

    let subquery = SQLQueryAnalyzer.lineage(
      sql: """
        SELECT p.property_type, COUNT(*) AS property_count
        FROM properties p
        WHERE p.property_id IN (SELECT n.property_id FROM loans n)
        GROUP BY p.property_type
        """,
      outputColumnNames: ["property_type", "property_count"])
    #expect(try #require(subquery.columns[1]).sourceGrain == ["properties"])
    #expect(subquery.rowGrain == ["properties"])
  }

  @Test func ignoresFunctionAndOutputAliasWordsWhenResolvingColumns() throws {
    let lineage = SQLQueryAnalyzer.lineage(
      sql: """
        SELECT FLOOR(p.num_floors) AS city,
               SUM(p.current_market_value) AS total_value
        FROM properties p
        GROUP BY city
        """,
      outputColumnNames: ["city", "total_value"])
    let category = try #require(lineage.columns[0])

    #expect(category.sourceColumns == [.init(table: "properties", column: "num_floors")])
    #expect(category.sourceGrain == ["properties"])
    #expect(!category.sourceColumns.contains(.init(table: "leases", column: "floor")))
    #expect(!category.sourceColumns.contains(.init(table: "properties", column: "city")))
  }

  @Test func removesAncestorEntitiesFromExpressionGrain() throws {
    let lineage = SQLQueryAnalyzer.lineage(
      sql: """
        SELECT l.lease_type,
               SUM(l.annual_base_rent * p.ownership_pct) AS owned_rent
        FROM leases l JOIN properties p ON p.property_id = l.property_id
        GROUP BY l.lease_type
        """,
      outputColumnNames: ["lease_type", "owned_rent"])

    #expect(try #require(lineage.columns[1]).sourceGrain == ["leases"])
  }

  @Test func preservesPreAggregationBoundariesAcrossCTEs() throws {
    let lineage = SQLQueryAnalyzer.lineage(
      sql: """
        WITH rent AS (
          SELECT property_id, SUM(annual_base_rent) AS total_rent
          FROM leases GROUP BY property_id
        ), debt AS (
          SELECT property_id, SUM(current_balance) AS total_debt
          FROM loans GROUP BY property_id
        )
        SELECT r.total_rent, d.total_debt
        FROM rent r JOIN debt d USING (property_id)
        """,
      outputColumnNames: ["total_rent", "total_debt"])

    #expect(try #require(lineage.columns[0]).sourceGrain == ["properties"])
    #expect(try #require(lineage.columns[1]).sourceGrain == ["properties"])
    #expect(lineage.rowGrain == ["properties"])

    let derived = SQLQueryAnalyzer.lineage(
      sql: """
        SELECT r.total_rent, d.total_debt
        FROM (
          SELECT property_id, SUM(annual_base_rent) AS total_rent
          FROM leases GROUP BY property_id
        ) r
        JOIN (
          SELECT property_id, SUM(current_balance) AS total_debt
          FROM loans GROUP BY property_id
        ) d USING (property_id)
        """,
      outputColumnNames: ["total_rent", "total_debt"])

    #expect(try #require(derived.columns[0]).sourceGrain == ["properties"])
    #expect(try #require(derived.columns[1]).sourceGrain == ["properties"])
    #expect(derived.rowGrain == ["properties"])
  }

  @Test func groupedSiblingAggregatesKeepTheirPreAggregationGrains() throws {
    let lineage = SQLQueryAnalyzer.lineage(
      sql: """
        SELECT p.name,
               SUM(l.annual_base_rent) AS total_rent,
               SUM(n.current_balance) AS total_debt
        FROM properties p
        JOIN leases l ON l.property_id = p.property_id
        JOIN loans n ON n.property_id = p.property_id
        GROUP BY p.name
        """,
      outputColumnNames: ["name", "total_rent", "total_debt"])

    #expect(try #require(lineage.columns[1]).sourceGrain == ["leases"])
    #expect(try #require(lineage.columns[2]).sourceGrain == ["loans"])
    #expect(lineage.rowGrain == ["properties"])
  }

  @Test func groupByPrefersSourceColumnsOverConflictingOutputAliases() {
    let lineage = SQLQueryAnalyzer.lineage(
      sql: """
        SELECT l.status AS name, COUNT(*) AS row_count
        FROM properties p
        JOIN leases l ON l.property_id = p.property_id
        GROUP BY name
        """,
      outputColumnNames: ["name", "row_count"])

    #expect(lineage.rowGrain == ["properties"])
  }

  @Test func cteColumnListsRenameExposedOutputs() throws {
    let lineage = SQLQueryAnalyzer.lineage(
      sql: """
        WITH cte(label) AS (SELECT city FROM properties)
        SELECT label FROM cte
        """,
      outputColumnNames: ["label"])

    #expect(
      try #require(lineage.columns[0]).sourceColumns
        == [.init(table: "properties", column: "city")])
  }

  @Test func materializedCTEsPreserveLineage() throws {
    for modifier in ["MATERIALIZED", "NOT MATERIALIZED"] {
      let lineage = SQLQueryAnalyzer.lineage(
        sql: """
          WITH cte(label) AS \(modifier) (
            SELECT city FROM properties
          )
          SELECT label FROM cte
          """,
        outputColumnNames: ["label"])

      #expect(lineage.completeness == .complete)
      #expect(lineage.rowGrain == ["properties"])
      #expect(
        try #require(lineage.columns[0]).sourceColumns
          == [.init(table: "properties", column: "city")])
    }
  }

  @Test func malformedCTEColumnListsFailClosed() {
    for declaration in ["a,,b", "a,"] {
      let lineage = SQLQueryAnalyzer.lineage(
        sql: """
          WITH cte(\(declaration)) AS (
            SELECT city, state FROM properties
          )
          SELECT a FROM cte
          """,
        outputColumnNames: ["a"])

      #expect(lineage.completeness == .incomplete)
      #expect(lineage.columns == [nil])
      #expect(lineage.rowGrain.isEmpty)
      #expect(
        SQLQueryAnalyzer.scopedQueryBlocks(
          in: """
            WITH cte(\(declaration)) AS (
              SELECT city, state FROM properties
            )
            SELECT a FROM cte
            """).isEmpty)
    }
  }

  @Test func unusedValuesCTEDoesNotDegradePhysicalLineage() throws {
    let lineage = SQLQueryAnalyzer.lineage(
      sql: """
        WITH unused(value) AS (VALUES (1))
        SELECT name FROM properties
        """,
      outputColumnNames: ["name"],
      directOrigins: [.init(table: "properties", column: "name")],
      reads: [.init(table: "properties", column: "name")])

    #expect(lineage.completeness == .complete)
    #expect(lineage.rowGrain == ["properties"])
    #expect(
      try #require(lineage.columns[0]).sourceColumns
        == [.init(table: "properties", column: "name")])
    #expect(lineage.columns[0]?.preservesSourceDomain == true)
  }

  @Test func aliaslessDerivedExpressionsRetainTheirSQLiteOutputName() throws {
    let lineage = SQLQueryAnalyzer.lineage(
      sql: """
        SELECT d."city || state"
        FROM (SELECT city || state FROM properties) d
        """,
      outputColumnNames: ["city || state"])

    #expect(
      try #require(lineage.columns[0]).sourceColumns
        == [
          .init(table: "properties", column: "city"),
          .init(table: "properties", column: "state"),
        ])
  }

  @Test func schemaQualifiedAndUnknownRelationsStayConservative() throws {
    let qualified = SQLQueryAnalyzer.lineage(
      sql: "SELECT properties.city FROM main.properties",
      outputColumnNames: ["city"])
    #expect(
      try #require(qualified.columns[0]).sourceColumns
        == [.init(table: "properties", column: "city")])
    #expect(qualified.rowGrain == ["properties"])

    let unknown = SQLQueryAnalyzer.lineage(
      sql: "SELECT value FROM json_each('[1]')",
      outputColumnNames: ["value"])
    #expect(unknown.columns == [nil])
    #expect(unknown.rowGrain == ["creg.opaque.json_each"])

    let runtimeGrounded = SQLQueryAnalyzer.lineage(
      sql: "SELECT value FROM json_each('[1]')",
      outputColumnNames: ["value"],
      directOrigins: [.init(table: "json_each", column: "value")])
    #expect(
      try #require(runtimeGrounded.columns[0]).sourceColumns
        == [.init(table: "json_each", column: "value")])
    #expect(
      try #require(runtimeGrounded.columns[0]).sourceGrain
        == ["creg.opaque.json_each"])
    #expect(runtimeGrounded.rowGrain == ["creg.opaque.json_each"])
  }

  @Test func computedRelationOutputsDoNotPreserveRawSourceDomains() {
    let cases = [
      "SELECT CASE WHEN building_class = 'A' THEN 'Upper' ELSE 'Other' END AS bucket FROM properties",
      "SELECT UPPER(building_class) AS bucket FROM properties",
      "SELECT COUNT(building_class) AS bucket FROM properties",
    ]
    for projection in cases {
      let scope = SQLQueryAnalyzer.scope(
        in: "SELECT d.bucket FROM (\(projection)) d WHERE d.bucket = 'Upper'")
      #expect(scope.qualifiedColumns["d"]?["bucket"]?.source == nil)
    }

    let direct = SQLQueryAnalyzer.scope(
      in: """
        SELECT d.bucket
        FROM (SELECT building_class AS bucket FROM properties) d
        WHERE d.bucket = 'Upper'
        """)
    #expect(
      direct.qualifiedColumns["d"]?["bucket"]?.source
        == .init(table: "properties", column: "building_class"))

    let computed = SQLQueryAnalyzer.lineage(
      sql: "SELECT UPPER(building_class) AS building_class FROM properties",
      outputColumnNames: ["building_class"],
      directOrigins: [.init(table: "properties", column: "building_class")])
    #expect(computed.columns[0]?.preservesSourceDomain == false)

    let parenthesized = SQLQueryAnalyzer.lineage(
      sql: "SELECT (building_class) AS building_class FROM properties",
      outputColumnNames: ["building_class"],
      directOrigins: [.init(table: "properties", column: "building_class")])
    #expect(parenthesized.columns[0]?.preservesSourceDomain == true)
    #expect(
      parenthesized.columns[0]?.sourceColumns
        == [.init(table: "properties", column: "building_class")])
  }

  @Test func scopedBlocksComeFromTokensInsteadOfParenthesisText() {
    let blocks = SQLQueryAnalyzer.scopedQueryBlocks(
      in: """
        SELECT COALESCE(
          (SELECT l.status FROM leases l WHERE l.status = 'Active'),
          'literal ) (SELECT ignored FROM comments)'
        ) AS status
        FROM properties p
        /* ) (SELECT ignored FROM comments) */
        -- ) (SELECT ignored FROM comments)
        """)

    #expect(blocks.count == 2)
    #expect(blocks.contains { $0.scope.aliases["p"] == "properties" })
    #expect(blocks.contains { $0.scope.aliases["l"] == "leases" })
  }

  @Test func validUnsupportedOuterConstructRetainsProvenSelectScopes() {
    for sql in [
      "VALUES ((SELECT l.status FROM leases l WHERE l.status = 'Actve'))",
      "WITH unused(value) AS (VALUES (1)) SELECT l.status FROM leases l WHERE l.status = 'Actve'",
      "SELECT l.status FROM leases l WHERE l.status = 'Actve' UNION ALL VALUES ('Other')",
    ] {
      let blocks = SQLQueryAnalyzer.scopedQueryBlocks(in: sql)
      #expect(blocks.contains { $0.scope.aliases["l"] == "leases" })
    }
    for malformed in [
      "WITH unused(value,) AS (VALUES (1)) SELECT l.status FROM leases l WHERE l.status = 'Actve'",
      "SELECT l.status FROM leases l WHERE l.status = 'Actve' UNION ALL",
      "VALUES ((SELECT l.status FROM leases l WHERE l.status = 'Actve')",
    ] {
      #expect(SQLQueryAnalyzer.scopedQueryBlocks(in: malformed).isEmpty)
    }
  }

  @Test func valuesCTEShadowsPhysicalTableWithOpaqueDeclaredColumns() {
    let sql = """
      WITH leases(status) AS (VALUES ('Pending'))
      SELECT l.status FROM leases l WHERE l.status = 'Actve'
      """
    let blocks = SQLQueryAnalyzer.scopedQueryBlocks(in: sql)
    let scope = SQLQueryAnalyzer.scope(in: sql)
    #expect(blocks.count == 1)
    #expect(scope.tables.isEmpty)
    #expect(scope.aliases["l"] == nil)
    #expect(scope.qualifiedColumns["l"]?["status"]?.source == nil)

    let joined = SQLQueryAnalyzer.scope(in: """
      WITH leases(status) AS (VALUES ('Pending'))
      SELECT status FROM leases l JOIN funds f ON 1 = 1
      """)
    #expect(joined.unqualifiedColumns["status"]?.count == 2)
    #expect(joined.tables == ["funds"])
  }

  @Test func valuesCTELiteralDoesNotUsePhysicalCatalogOrRepairSource() async {
    let sql = """
      WITH leases(status) AS (VALUES ('Pending'))
      SELECT l.status FROM leases l WHERE l.status = 'Actve'
      """
    let db = DatabaseClient(
      fingerprint: "values-cte-test",
      execute: { _ in
        QueryResult(columns: ["status"], rows: [[.text("Active")]])
      })
    let report = await ResultHeuristics(db: db).inspectDetailed(
      sql: sql, result: QueryResult(columns: ["status"], rows: []))
    #expect(report.checks.isEmpty)
    #expect(!report.findings.contains {
      if case .literalNotFound = $0 { return true }
      return false
    })

    let guidance = ResultHeuristics.repairGuidance(
      issue: SQLValidationIssue(
        kind: .binding, disposition: .repairable,
        message: "no such column: l.status"),
      sql: sql, failedFingerprints: [])
    #expect(!guidance.declaredSources.contains("leases"))
  }

  @Test func recoveryNeverReusesSubqueryScopeFromFailedCTEPass() {
    let sql = """
      WITH leases(status) AS (VALUES ('Pending'))
      VALUES ((SELECT l.status FROM leases l WHERE l.status = 'Actve'))
      """
    let blocks = SQLQueryAnalyzer.scopedQueryBlocks(in: sql)
    #expect(blocks.count == 1)
    #expect(blocks[0].scope.tables.isEmpty)
    #expect(blocks[0].scope.qualifiedColumns["l"]?["status"]?.source == nil)

    let laterCTE = SQLQueryAnalyzer.scopedQueryBlocks(in: """
      WITH leases(status) AS (VALUES ('Pending')),
           picked AS (SELECT 1 AS flag WHERE 'x' IN (
             SELECT l.status FROM leases l WHERE l.status = 'Actve'))
      SELECT flag FROM picked
      """)
    #expect(laterCTE.contains {
      $0.scope.qualifiedColumns["l"]?["status"]?.source == nil
        && $0.scope.qualifiedColumns["l"] != nil
    })
    #expect(!laterCTE.contains { $0.scope.tables.contains("leases") })
  }

  @Test func recursiveCTESelfReferenceShadowsPhysicalLeaseTable() {
    for (header, anchor) in [
      ("leases(status)", "SELECT 'Pending'"),
      ("leases(status)", "VALUES ('Pending')"),
      ("leases", "SELECT 'Pending' AS status"),
    ] {
      let sql = """
        WITH RECURSIVE \(header) AS (
          \(anchor)
          UNION ALL
          SELECT l.status FROM leases l WHERE l.status = 'Actve'
        )
        SELECT status FROM leases
        """
      let blocks = SQLQueryAnalyzer.scopedQueryBlocks(in: sql)
      #expect(blocks.contains {
        $0.scope.qualifiedColumns["l"]?["status"]?.source == nil
          && $0.scope.qualifiedColumns["l"] != nil
      })
      #expect(!blocks.contains { $0.scope.tables.contains("leases") })
      #expect(SQLQueryAnalyzer.scope(in: sql).tables.isEmpty)
    }
  }

  @Test func valuesJoinRetainsOnlyProvenPhysicalOrigins() throws {
    let lineage = SQLQueryAnalyzer.lineage(
      sql: """
        WITH leases(status) AS (VALUES ('Pending'))
        SELECT p.city, l.status
        FROM properties p JOIN leases l ON 1 = 1
        """,
      outputColumnNames: ["city", "status"],
      directOrigins: [
        .init(table: "properties", column: "city"),
        .init(table: "leases", column: "status"),
      ],
      reads: [.init(table: "properties", column: "city")])
    #expect(lineage.completeness == .complete)
    #expect(
      try #require(lineage.columns[0]).sourceColumns
        == [.init(table: "properties", column: "city")])
    #expect(lineage.columns[1] == nil)

    let unaligned = SQLQueryAnalyzer.lineage(
      sql: """
        WITH leases(status) AS (VALUES ('Pending'))
        SELECT p.city FROM properties p JOIN leases l ON 1 = 1
        """,
      outputColumnNames: ["renamed_at_runtime"],
      directOrigins: [.init(table: "properties", column: "city")],
      reads: [.init(table: "properties", column: "city")])
    #expect(
      try #require(unaligned.columns[0]).sourceColumns
        == [.init(table: "properties", column: "city")])

    let shapeMismatch = SQLQueryAnalyzer.lineage(
      sql: """
        WITH leases(status) AS (VALUES ('Pending'))
        SELECT p.city, l.status
        FROM properties p JOIN leases l ON 1 = 1
        """,
      outputColumnNames: ["renamed_at_runtime"],
      directOrigins: [.init(table: "properties", column: "city")],
      reads: [.init(table: "properties", column: "city")])
    #expect(shapeMismatch.columns == [nil])

    let sameNamedPhysicalJoin = SQLQueryAnalyzer.lineage(
      sql: """
        WITH leases(status) AS (VALUES ('Pending'))
        SELECT v.status, p.status
        FROM leases v JOIN main.leases p ON 1 = 1
        """,
      outputColumnNames: ["status", "status"],
      directOrigins: [
        .init(table: "leases", column: "status"),
        .init(table: "leases", column: "status"),
      ],
      reads: [.init(table: "leases", column: "status")])
    #expect(sameNamedPhysicalJoin.columns[0] == nil)
    #expect(
      try #require(sameNamedPhysicalJoin.columns[1]).sourceColumns
        == [.init(table: "leases", column: "status")])
  }

  @Test func explicitlyQualifiedTableBypassesSameNamedCTE() {
    let scope = SQLQueryAnalyzer.scope(in: """
      WITH leases(status) AS (VALUES ('Pending'))
      SELECT l.status FROM main.leases l
      """)
    #expect(scope.tables == ["leases"])
    #expect(scope.aliases["l"] == "leases")
  }

  @Test func malformedValuesCTERejectsAllScopes() {
    for sql in [
      "WITH leases(status) AS (VALUES ('A', 'B')) SELECT status FROM leases",
      "WITH leases(status) AS (VALUES ('A'), ('B', 'C')) SELECT status FROM leases",
      "WITH leases(status) AS (VALUES ('A'),) SELECT status FROM leases",
    ] {
      #expect(SQLQueryAnalyzer.scopedQueryBlocks(in: sql).isEmpty)
    }
  }

  @Test func malformedNestedCTENeverPublishesPhysicalLeaseScope() {
    for cte in [
      "WITH leases(status) (SELECT l.status FROM leases l WHERE l.status = 'Actve')",
      "WITH leases(status, extra) AS (SELECT l.status FROM leases l WHERE l.status = 'Actve')",
    ] {
      let blocks = SQLQueryAnalyzer.scopedQueryBlocks(in: """
        SELECT 1 AS flag FROM (
          \(cte)
          SELECT 1 AS marker FROM leases
        ) x
        """)
      #expect(!blocks.isEmpty)
      #expect(!blocks.contains { $0.scope.tables.contains("leases") })
    }
  }

  @Test func compoundSelectsDoNotBorrowClausesFromLaterArms() {
    let lineage = SQLQueryAnalyzer.lineage(
      sql: """
        SELECT city FROM properties
        UNION ALL
        SELECT headquarters_city FROM tenants GROUP BY headquarters_city
        """,
      outputColumnNames: ["city"])

    #expect(lineage.columns == [nil])
    #expect(lineage.rowGrain.isEmpty)
  }

  @Test func compoundSelectsPreserveConservativeScopeFromEveryArm() {
    let scope = SQLQueryAnalyzer.scope(
      in: """
        SELECT p.city FROM properties p WHERE p.city = 'Seattle'
        UNION ALL
        SELECT t.headquarters_city FROM tenants t
        WHERE t.headquarters_city = 'Seattle'
        """)

    #expect(scope.tables == ["properties", "tenants"])
    #expect(scope.aliases["p"] == "properties")
    #expect(scope.aliases["t"] == "tenants")
    #expect(
      scope.qualifiedColumns["p"]?["city"]?.source
        == .init(table: "properties", column: "city"))
    #expect(
      scope.qualifiedColumns["t"]?["headquarters_city"]?.source
        == .init(table: "tenants", column: "headquarters_city"))
  }

  @Test func compoundSelectsDiscardConflictingAliasAndColumnMappings() {
    let scope = SQLQueryAnalyzer.scope(
      in: """
        SELECT source.name FROM properties source
        UNION ALL
        SELECT source.name FROM tenants source
        """)

    #expect(scope.aliases["source"] == nil)
    #expect(scope.qualifiedColumns["source"]?["name"]?.source == nil)
    #expect(scope.unqualifiedColumns["name"]?.first?.source == nil)
  }

  @Test func compoundArmsShareTopLevelCTEsWithoutPublishingLineage() {
    let sql = """
      WITH places(label) AS (SELECT city FROM properties)
      SELECT places.label FROM places
      UNION ALL
      SELECT places.label FROM places
      """
    let lineage = SQLQueryAnalyzer.lineage(
      sql: sql, outputColumnNames: ["label"])
    let scope = SQLQueryAnalyzer.scope(in: sql)

    #expect(lineage.columns == [nil])
    #expect(lineage.rowGrain.isEmpty)
    #expect(scope.tables == ["properties"])
    #expect(
      scope.qualifiedColumns["places"]?["label"]?.source
        == .init(table: "properties", column: "city"))
  }

  @Test func multipleAggregateCallsDoNotClaimOneOperation() throws {
    for expression in [
      "SUM(p.current_market_value) + MAX(p.current_market_value)",
      "SUM(p.current_market_value) + SUM(p.current_market_value)",
    ] {
      let lineage = SQLQueryAnalyzer.lineage(
        sql: "SELECT \(expression) AS value FROM properties p",
        outputColumnNames: ["value"])
      let column = try #require(lineage.columns[0])

      #expect(column.aggregation == nil)
      #expect(lineage.rowGrain.isEmpty)
    }
  }

  @Test func multipleAndNestedAggregatesCrossToTheProducedGrain() throws {
    for expression in [
      "SUM(l.annual_base_rent) / SUM(l.leased_sqft)",
      "SUM(l.annual_base_rent) / SUM(SUM(l.annual_base_rent)) OVER ()",
    ] {
      let lineage = SQLQueryAnalyzer.lineage(
        sql: """
          SELECT p.city, \(expression) AS value
          FROM properties p
          JOIN leases l ON l.property_id = p.property_id
          GROUP BY p.city
          """,
        outputColumnNames: ["city", "value"])
      let value = try #require(lineage.columns[1])

      #expect(value.aggregation == nil)
      #expect(value.sourceGrain == ["properties"])
      #expect(lineage.rowGrain == ["properties"])
    }
  }

  @Test func compositeGrainSafetyIsIndependentOfExpressionOrder() throws {
    let expressions = [
      "SUM(pf.net_operating_income / v.market_value)",
      "SUM(v.market_value / pf.net_operating_income)",
    ]
    let lineages = expressions.map { expression in
      SQLQueryAnalyzer.lineage(
        sql: """
          SELECT \(expression) AS value
          FROM properties p
          JOIN property_financials pf ON pf.property_id = p.property_id
          JOIN valuations v ON v.property_id = p.property_id
          GROUP BY p.city
          """,
        outputColumnNames: ["value"])
    }
    let first = try #require(lineages[0].columns[0])
    let second = try #require(lineages[1].columns[0])

    #expect(first == second)
    #expect(lineages[0].rowGrain == lineages[1].rowGrain)
  }

  @Test func outputAlignmentKeepsOnlyMatchesProvenAcrossEveryOptimalAlignment()
    throws
  {
    let aligned = SQLQueryAnalyzer.lineage(
      sql: "SELECT * FROM properties JOIN leases USING (property_id)",
      outputColumnNames: [
        "property_id", "fund_id", "name", "address", "city", "state",
        "market", "submarket", "property_type", "building_class",
        "rentable_sqft", "year_built", "year_renovated", "num_floors",
        "acquisition_date", "acquisition_price", "current_market_value",
        "ownership_pct", "status", "disposition_date", "lease_id",
        "tenant_id", "suite", "floor", "leased_sqft", "lease_type",
        "base_rent_psf", "annual_base_rent", "escalation_pct",
        "commencement_date", "expiration_date", "term_months",
        "security_deposit", "has_renewal_option", "free_rent_months",
        "ti_allowance_psf", "status",
      ])

    #expect(
      try #require(aligned.columns[9]).sourceColumns
        == [.init(table: "properties", column: "building_class")])
    #expect(
      try #require(aligned.columns[18]).sourceColumns
        == [.init(table: "properties", column: "status")])
    #expect(
      try #require(aligned.columns[36]).sourceColumns
        == [.init(table: "leases", column: "status")])

    let ambiguous = SQLQueryAnalyzer.lineage(
      sql: "SELECT city, city FROM properties",
      outputColumnNames: ["city"])
    #expect(ambiguous.columns == [nil])

    let originFilled = SQLQueryAnalyzer.lineage(
      sql: "SELECT city, state FROM properties",
      outputColumnNames: ["city", "runtime_only", "state"],
      directOrigins: [
        nil,
        .init(table: "tenants", column: "credit_rating"),
        nil,
      ])
    #expect(
      try #require(originFilled.columns[1]).sourceColumns
        == [.init(table: "tenants", column: "credit_rating")])

    let withSingleton = SQLQueryAnalyzer.lineage(
      sql: """
        SELECT *
        FROM properties JOIN leases USING (property_id)
        CROSS JOIN (SELECT DATE('now') AS today)
        """,
      outputColumnNames: [
        "property_id", "fund_id", "name", "address", "city", "state",
        "market", "submarket", "property_type", "building_class",
        "rentable_sqft", "year_built", "year_renovated", "num_floors",
        "acquisition_date", "acquisition_price", "current_market_value",
        "ownership_pct", "status", "disposition_date", "lease_id",
        "tenant_id", "suite", "floor", "leased_sqft", "lease_type",
        "base_rent_psf", "annual_base_rent", "escalation_pct",
        "commencement_date", "expiration_date", "term_months",
        "security_deposit", "has_renewal_option", "free_rent_months",
        "ti_allowance_psf", "status", "today",
      ],
      directOrigins: Array(repeating: nil, count: 37)
        + [.init(table: "leases", column: "status")])
    #expect(
      withSingleton.columns[9]?.sourceColumns
        == [.init(table: "properties", column: "building_class")])
    #expect(
      withSingleton.columns[36]?.sourceColumns
        == [.init(table: "leases", column: "status")])
    #expect(withSingleton.columns[37] == nil)
  }

  @Test func runtimeOriginsAreRejectedForCompounds() {
    let lineage = SQLQueryAnalyzer.lineage(
      sql: """
        SELECT credit_rating FROM tenants
        UNION ALL
        SELECT status FROM leases
        """,
      outputColumnNames: ["credit_rating"],
      directOrigins: [.init(table: "tenants", column: "credit_rating")],
      reads: [
        .init(table: "tenants", column: "credit_rating"),
        .init(table: "leases", column: "status"),
      ])

    #expect(lineage.columns == [nil])

    for sql in [
      """
      WITH u AS (
        SELECT credit_rating FROM tenants
        UNION ALL
        SELECT status FROM leases
      )
      SELECT credit_rating FROM u
      """,
      """
      SELECT credit_rating FROM (
        SELECT credit_rating FROM tenants
        UNION ALL
        SELECT status FROM leases
      ) u
      """,
    ] {
      let nested = SQLQueryAnalyzer.lineage(
        sql: sql,
        outputColumnNames: ["credit_rating"],
        directOrigins: [.init(table: "leases", column: "status")],
        reads: [
          .init(table: "tenants", column: "credit_rating"),
          .init(table: "leases", column: "status"),
        ])
      #expect(nested.columns == [nil])
    }

    let failedCTE = SQLQueryAnalyzer.lineage(
      sql: """
        WITH unsupported AS (VALUES (1))
        SELECT credit_rating FROM tenants
        UNION ALL
        SELECT status FROM leases
        """,
      outputColumnNames: ["credit_rating"],
      directOrigins: [.init(table: "leases", column: "status")],
      reads: [.init(table: "tenants", column: "credit_rating")])
    #expect(failedCTE.columns == [nil])
  }

  @Test func directOriginInputStaysAlignedWithRuntimeColumns() throws {
    let city = SQLSourceColumn(table: "properties", column: "city")
    let lineage = SQLQueryAnalyzer.lineage(
      sql: "SELECT city, UPPER(state) FROM properties",
      outputColumnNames: ["city", "UPPER(state)"],
      directOrigins: [city])

    #expect(try #require(lineage.columns[0]).sourceColumns == [city])
    #expect(lineage.columns[1]?.sourceColumns != [city])
  }

  @Test func malformedCompoundsStayConservative() {
    let lineage = SQLQueryAnalyzer.lineage(
      sql: "SELECT city FROM properties UNION ALL",
      outputColumnNames: ["city"],
      directOrigins: [.init(table: "properties", column: "city")])

    #expect(SQLQueryAnalyzer.scope(in: "SELECT city FROM properties UNION ALL").tables.isEmpty)
    #expect(lineage.columns == [nil])
  }

  @Test func contradictoryReadsRemoveLineage() {
    let city = SQLSourceColumn(table: "properties", column: "city")
    let lineage = SQLQueryAnalyzer.lineage(
      sql: "SELECT city FROM properties",
      outputColumnNames: ["city"],
      directOrigins: [city],
      reads: [.init(table: "properties", column: "state")])

    #expect(lineage.columns == [nil])
  }

  @Test func nonemptyRuntimeReadsWithoutColumnEvidenceRejectInferredProvenance() {
    let city = SQLSourceColumn(table: "properties", column: "city")
    let lineage = SQLQueryAnalyzer.lineage(
      sql: "SELECT city FROM properties",
      outputColumnNames: ["city"],
      directOrigins: [city],
      reads: [.init(table: "properties")])

    #expect(lineage.columns == [nil])
  }

  @Test func ambiguousLocalAggregatesDoNotInheritAnOperationFromTheirReference()
    throws
  {
    let lineage = SQLQueryAnalyzer.lineage(
      sql: """
        WITH totals AS (
          SELECT SUM(current_market_value) AS value FROM properties
        )
        SELECT SUM(value) + MAX(value) AS combined FROM totals
        """,
      outputColumnNames: ["combined"])

    #expect(try #require(lineage.columns[0]).aggregation == nil)
    #expect(lineage.rowGrain.isEmpty)
  }

  @Test func windowAggregatesDoNotCollapseTheRowGrain() throws {
    for expression in [
      "SUM(p.current_market_value) OVER ()",
      "SUM(p.current_market_value) FILTER (WHERE p.status = 'Owned') OVER ()",
    ] {
      let lineage = SQLQueryAnalyzer.lineage(
        sql: """
          SELECT p.city, \(expression) AS total_value
          FROM properties p
          """,
        outputColumnNames: ["city", "total_value"])

      #expect(try #require(lineage.columns[1]).aggregation == nil)
      #expect(lineage.rowGrain == ["properties"])
    }
  }

  @Test func multiArgumentMaxIsScalar() throws {
    let lineage = SQLQueryAnalyzer.lineage(
      sql: """
        SELECT p.city,
               MAX(p.current_market_value, p.acquisition_price) AS larger_value
        FROM properties p
        """,
      outputColumnNames: ["city", "larger_value"])

    #expect(try #require(lineage.columns[1]).aggregation == nil)
    #expect(lineage.rowGrain == ["properties"])
  }

  @Test func contradictoryReadsPreserveSyntacticAggregation() throws {
    let lineage = SQLQueryAnalyzer.lineage(
      sql: "SELECT SUM(p.current_market_value) AS total FROM properties p",
      outputColumnNames: ["total"],
      reads: [.init(table: "properties", column: "name")])
    let column = try #require(lineage.columns[0])

    #expect(column.sourceColumns.isEmpty)
    #expect(column.sourceGrain.isEmpty)
    #expect(column.aggregation == .sum)
    #expect(!column.preservesSourceDomain)
  }

  @Test func duplicateInvariantAggregatesUseTheProducedGroupGrain() throws {
    for expression in [
      "MIN(p.current_market_value)",
      "MAX(p.current_market_value)",
      "COUNT(DISTINCT p.property_id)",
    ] {
      let lineage = SQLQueryAnalyzer.lineage(
        sql: """
          SELECT l.lease_type, \(expression) AS value
          FROM properties p JOIN leases l ON l.property_id = p.property_id
          GROUP BY l.lease_type
          """,
        outputColumnNames: ["lease_type", "value"])

      #expect(try #require(lineage.columns[1]).sourceGrain == ["leases"])
    }
  }
}
