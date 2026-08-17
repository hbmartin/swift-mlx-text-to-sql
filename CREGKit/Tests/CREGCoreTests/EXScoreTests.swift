import CryptoKit
import Foundation
import Testing

@testable import CREGCore

extension EXScore {
  static func canonicalFixtureData() throws -> Data {
    guard let url = Bundle.module.url(
      forResource: "canonical_result_fixtures", withExtension: "json")
    else { throw CocoaError(.fileNoSuchFile) }
    return try Data(contentsOf: url)
  }
}
@Suite struct EXScoreTests {
  private struct FixtureDocument: Decodable {
    var schemaVersion: Int
    var cases: [FixtureCase]

    enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case cases
    }
  }

  private struct FixtureCase: Decodable {
    var name: String
    var left: [[FixtureCell]]
    var right: [[FixtureCell]]
    var matches: Bool
    var leftEncoding: String
    var rightEncoding: String
    var leftDigest: String
    var rightDigest: String

    enum CodingKeys: String, CodingKey {
      case name, left, right, matches
      case leftEncoding = "left_encoding"
      case rightEncoding = "right_encoding"
      case leftDigest = "left_digest"
      case rightDigest = "right_digest"
    }
  }

  private struct FixtureCell: Decodable {
    var type: String
    var value: String
  }

  private func result(_ rows: [[FixtureCell]]) -> QueryResult {
    QueryResult(
      columns: [],
      rows: rows.map { row in
        row.map { cell in
          switch cell.type {
          case "null": .null
          case "integer": .integer(Int64(cell.value)!)
          case "real": .real(Double(cell.value)!)
          case "text": .text(cell.value)
          case "blob": .blob(Data(base64Encoded: cell.value)!)
          default:
            fatalError("unknown fixture type \(cell.type)")
          }
        }
      })
  }

  @Test func numericStorageClassesMatchButTextDoesNot() {
    let integer = QueryResult(columns: ["value"], rows: [[.integer(1)]])
    let real = QueryResult(columns: ["value"], rows: [[.real(1.0)]])
    let text = QueryResult(columns: ["value"], rows: [[.text("1")]])
    #expect(EXScore.matches(integer, real))
    #expect(!EXScore.matches(integer, text))
  }

  @Test func blobIdentityUsesFullBytes() {
    let first = QueryResult(columns: ["value"], rows: [[.blob(Data([0, 1]))]])
    let same = QueryResult(columns: ["value"], rows: [[.blob(Data([0, 1]))]])
    let sameLength = QueryResult(columns: ["value"], rows: [[.blob(Data([1, 0]))]])
    #expect(EXScore.matches(first, same))
    #expect(!EXScore.matches(first, sameLength))
  }

  @Test func nullAndDuplicateRowsRemainSignificant() {
    let one = QueryResult(columns: ["value"], rows: [[.null]])
    let two = QueryResult(columns: ["value"], rows: [[.null], [.null]])
    let emptyText = QueryResult(columns: ["value"], rows: [[.text("")]])
    #expect(!EXScore.matches(one, two))
    #expect(!EXScore.matches(one, emptyText))
  }

  @Test func halfEvenNumericNormalization() {
    #expect(CanonicalSQLValue.canonicalNumber(1.00005) == "1")
    #expect(CanonicalSQLValue.canonicalNumber(1.00015) == "1.0002")
    #expect(CanonicalSQLValue.canonicalNumber(-0.0) == "0")
  }

  @Test func canonicalNumberIsTotalOverTheDoubleRange() {
    #expect(CanonicalSQLValue.canonicalNumber(.infinity) == "inf")
    #expect(CanonicalSQLValue.canonicalNumber(-.infinity) == "-inf")
    #expect(CanonicalSQLValue.canonicalNumber(.nan) == "nan")
    #expect(
      CanonicalSQLValue.canonicalNumber(1e24)
        == "1" + String(repeating: "0", count: 24))
    #expect(
      CanonicalSQLValue.canonicalNumber(1.2345e300)
        == "12345" + String(repeating: "0", count: 296))
    #expect(
      CanonicalSQLValue.canonicalNumber(-1.2345e300)
        == "-12345" + String(repeating: "0", count: 296))
    #expect(
      CanonicalSQLValue.canonicalNumber(.greatestFiniteMagnitude)
        .hasPrefix("17976931348623157"))
    #expect(CanonicalSQLValue.canonicalNumber(5e-324) == "0")
    #expect(CanonicalSQLValue.canonicalNumber(-1e-300) == "0")
  }

  @Test func textIdentityUsesCodePointsNotCanonicalEquivalence() {
    // Python compares str by code points; NFC and NFD spellings of the same
    // grapheme must stay distinct values with distinct digests.
    let nfc = QueryResult(columns: ["v"], rows: [[.text("caf\u{E9}")]])
    let nfd = QueryResult(columns: ["v"], rows: [[.text("cafe\u{301}")]])
    #expect(!EXScore.matches(nfc, nfd))
    #expect(CanonicalSQLResult(nfc).digest != CanonicalSQLResult(nfd).digest)
  }

  @Test func rowOrderDoesNotMatterAndTruncationDoes() {
    let first = QueryResult(
      columns: ["n"], rows: [[.integer(1)], [.integer(2)]])
    let second = QueryResult(
      columns: ["n"], rows: [[.real(2)], [.real(1)]])
    #expect(EXScore.matches(first, second))
    var truncated = second
    truncated.isTruncated = true
    #expect(!EXScore.matches(first, truncated))
  }

  @Test func digestIsStableAndTyped() {
    let first = QueryResult(
      columns: ["n"], rows: [[.integer(1)], [.integer(2)]])
    let reordered = QueryResult(
      columns: ["n"], rows: [[.real(2)], [.real(1)]])
    let text = QueryResult(
      columns: ["n"], rows: [[.text("1")], [.text("2")]])
    #expect(CanonicalSQLResult(first).digest == CanonicalSQLResult(reordered).digest)
    #expect(CanonicalSQLResult(first).digest != CanonicalSQLResult(text).digest)
  }

  @Test func sharedCanonicalFixturesMatchPython() throws {
    let document = try JSONDecoder().decode(
      FixtureDocument.self, from: EXScore.canonicalFixtureData())
    #expect(document.schemaVersion == 1)
    for fixture in document.cases {
      let left = result(fixture.left)
      let right = result(fixture.right)
      let canonicalLeft = CanonicalSQLResult(left)
      let canonicalRight = CanonicalSQLResult(right)
      #expect(
        String(decoding: canonicalLeft.encoding, as: UTF8.self)
          == fixture.leftEncoding)
      #expect(
        String(decoding: canonicalRight.encoding, as: UTF8.self)
          == fixture.rightEncoding)
      #expect(canonicalLeft.digest == fixture.leftDigest)
      #expect(canonicalRight.digest == fixture.rightDigest)
      #expect(EXScore.matches(left, right) == fixture.matches)
    }
  }
}
