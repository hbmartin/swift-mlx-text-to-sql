import CREGCore
import Testing

@testable import CREGData

@Suite struct SQLQueryAnalyzerTests {
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
