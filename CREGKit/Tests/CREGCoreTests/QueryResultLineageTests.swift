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
