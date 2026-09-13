import Foundation
import Testing

@testable import CREGCore

@Suite struct QueryResultLineageTests {
  @Test func lineageRoundTripsAndLegacyResultsRemainDecodable() throws {
    let lineage = SQLQueryLineage(
      columns: [
        SQLResultColumnLineage(
          sourceColumns: [.init(table: "properties", column: "city")],
          sourceGrain: ["properties"])
      ],
      rowGrain: ["properties"],
      reads: [
        SQLSourceRead(
          table: "properties", column: "city", database: "main")
      ])
    let result = QueryResult(
      columns: ["city"], rows: [[.text("Phoenix")]], lineage: lineage)

    #expect(
      try JSONDecoder().decode(
        QueryResult.self, from: JSONEncoder().encode(result)) == result)

    var legacyObject = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(result))
        as? [String: Any])
    legacyObject.removeValue(forKey: "lineage")
    let legacy = try JSONSerialization.data(withJSONObject: legacyObject)
    let decoded = try JSONDecoder().decode(QueryResult.self, from: legacy)
    #expect(decoded.lineage == nil)
  }

  @Test func futureOrMalformedLineageDoesNotMakeTheResultUndecodable() throws {
    let result = QueryResult(
      columns: ["total"],
      rows: [[.integer(1)]],
      lineage: SQLQueryLineage(
        columns: [
          SQLResultColumnLineage(
            sourceColumns: [.init(table: "properties", column: "property_id")],
            sourceGrain: ["properties"],
            aggregation: .count)
        ]))
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(result))
        as? [String: Any])
    var lineage = try #require(object["lineage"] as? [String: Any])
    var columns = try #require(lineage["columns"] as? [[String: Any]])
    columns[0]["aggregation"] = "futureAggregate"
    lineage["columns"] = columns
    object["lineage"] = lineage
    let data = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(QueryResult.self, from: data)
    #expect(decoded.columns == result.columns)
    #expect(decoded.rows == result.rows)
    #expect(decoded.lineage?.columns[0]?.aggregation == nil)
  }

  @Test func lineageWithoutAVersionDecodesAsLegacy() throws {
    let result = QueryResult(
      columns: ["city"], rows: [[.text("Phoenix")]],
      lineage: SQLQueryLineage(columns: [nil]))
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(result))
        as? [String: Any])
    var lineage = try #require(object["lineage"] as? [String: Any])
    lineage.removeValue(forKey: "analysisVersion")
    object["lineage"] = lineage
    let data = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(QueryResult.self, from: data)
    #expect(decoded.lineage?.analysisVersion == 1)
  }

  @Test func presentationLineageDoesNotChangeResultContentFingerprint() {
    let plain = QueryResult(columns: ["city"], rows: [[.text("Phoenix")]])
    let enriched = QueryResult(
      columns: plain.columns,
      rows: plain.rows,
      lineage: SQLQueryLineage(
        columns: [
          SQLResultColumnLineage(
            sourceColumns: [.init(table: "properties", column: "city")],
            sourceGrain: ["properties"])
        ]))

    #expect(
      PreparedFollowUpIntegrity.fingerprint(result: plain)
        == PreparedFollowUpIntegrity.fingerprint(result: enriched))
  }
}
