import CryptoKit
import Foundation

/// A type-preserving SQLite value used for EX scoring and vote grouping.
///
/// INTEGER and REAL intentionally share the numeric case. TEXT, BLOB, and
/// NULL never compare equal to a display-identical value in another domain.
///
/// Text equality, hashing, and ordering are Unicode code-point based (via
/// UTF-8 bytes) to stay byte-identical with the Python evaluator, which
/// compares `str` values without canonical normalization. Swift's default
/// `String` semantics would equate NFC/NFD pairs that Python distinguishes.
public enum CanonicalSQLValue: Sendable, Hashable, Codable, Comparable {
  case null
  case number(String)
  case text(String)
  case blob(Data)

  public init(_ value: SQLValue) {
    switch value {
    case .null:
      self = .null
    case .integer(let value):
      self = .number(String(value))
    case .real(let value):
      self = .number(Self.canonicalNumber(value))
    case .text(let value):
      self = .text(value)
    case .blob(let value):
      self = .blob(value)
    }
  }

  private var domainRank: Int {
    switch self {
    case .null: 0
    case .number: 1
    case .text: 2
    case .blob: 3
    }
  }

  /// The serialized payload string; blob payloads sort and encode as base64,
  /// matching the Python canonical value tuple.
  var payload: String {
    switch self {
    case .null: ""
    case .number(let value): value
    case .text(let value): value
    case .blob(let value): value.base64EncodedString()
    }
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.domainRank == rhs.domainRank
      && lhs.payload.utf8.elementsEqual(rhs.payload.utf8)
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(domainRank)
    hasher.combine(Array(payload.utf8))
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.domainRank != rhs.domainRank {
      return lhs.domainRank < rhs.domainRank
    }
    return lhs.payload.utf8.lexicographicallyPrecedes(rhs.payload.utf8)
  }

  /// Decimal, four-place, half-even normalization shared with Python EX.
  ///
  /// Total over every double: finite values quantize half-even to four
  /// decimals and render as plain decimals with trailing zeros stripped,
  /// negative zero is "0", and non-finite values render as "nan", "inf",
  /// and "-inf". SQLite converts NaN to NULL but can produce infinities
  /// (`SELECT 9e999`), so generated SQL can reach every branch.
  static func canonicalNumber(_ value: Double) -> String {
    guard value.isFinite else {
      if value.isNaN { return "nan" }
      return value.sign == .minus ? "-inf" : "inf"
    }
    let representation = String(value)
    guard
      var input = Decimal(
        string: representation, locale: Locale(identifier: "en_US_POSIX")),
      !input.isNaN
    else {
      // Beyond NSDecimal's ~1e±165 representable range. Below one the value
      // quantizes to zero; above one the double is integer-valued far past
      // 2^53, so the shortest representation expands exactly.
      return abs(value) < 1 ? "0" : Self.plainExpansion(of: representation)
    }
    var rounded = Decimal()
    NSDecimalRound(&rounded, &input, 4, .bankers)
    if rounded == 0 { return "0" }
    return NSDecimalNumber(decimal: rounded).stringValue
  }

  /// Expands a shortest-round-trip scientific representation (for example
  /// "1.2345e+300") into plain decimal digits, matching Python's
  /// `format(Decimal(str(value)), "f")` for magnitudes past the NSDecimal
  /// range.
  static func plainExpansion(of representation: String) -> String {
    let lowered = representation.lowercased()
    let sign = lowered.hasPrefix("-") ? "-" : ""
    let unsigned = sign.isEmpty ? lowered : String(lowered.dropFirst())
    let parts = unsigned.split(separator: "e", maxSplits: 1)
    let mantissa = String(parts[0])
    let exponent = parts.count == 2 ? (Int(parts[1]) ?? 0) : 0
    let pieces = mantissa.split(
      separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    let integerDigits = String(pieces[0])
    let fractionDigits = pieces.count == 2 ? String(pieces[1]) : ""
    let digits = integerDigits + fractionDigits
    let pointPosition = integerDigits.count + exponent
    guard pointPosition >= digits.count else {
      // Unreachable for the huge-magnitude call site; keep the function
      // total by re-inserting the point without rounding.
      if pointPosition <= 0 {
        return sign + "0." + String(repeating: "0", count: -pointPosition)
          + digits
      }
      let index = digits.index(digits.startIndex, offsetBy: pointPosition)
      return sign + digits[..<index] + "." + digits[index...]
    }
    return sign + digits
      + String(repeating: "0", count: pointPosition - digits.count)
  }
}

public struct CanonicalSQLRow: Sendable, Equatable, Hashable, Codable, Comparable {
  public var values: [CanonicalSQLValue]

  public init(values: [CanonicalSQLValue]) {
    self.values = values
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.values.lexicographicallyPrecedes(rhs.values)
  }
}

/// Stable, order-insensitive multiset identity for a query result.
public struct CanonicalSQLResult: Sendable, Equatable, Hashable, Codable {
  public var rows: [CanonicalSQLRow]
  public var isTruncated: Bool

  public init(_ result: QueryResult) {
    self.rows = result.rows.map {
      CanonicalSQLRow(values: $0.map(CanonicalSQLValue.init))
    }.sorted()
    self.isTruncated = result.isTruncated
  }

  /// Stable type-tagged JSON bytes shared with the Python evaluator.
  ///
  /// Serialized by hand so the bytes are defined by this file, not by
  /// JSONEncoder's escaping policy: compact separators, keys in sorted
  /// order, raw UTF-8 for non-ASCII, and exactly CPython `json.dumps`
  /// escapes for quote, backslash, and control characters. The encoder is
  /// total — there is no failure path that could silently collide digests.
  public var encoding: Data {
    var output = Data()
    output.append(UInt8(ascii: "["))
    for (rowIndex, row) in rows.enumerated() {
      if rowIndex > 0 { output.append(UInt8(ascii: ",")) }
      output.append(UInt8(ascii: "["))
      for (valueIndex, value) in row.values.enumerated() {
        if valueIndex > 0 { output.append(UInt8(ascii: ",")) }
        let kind =
          switch value {
          case .null: "null"
          case .number: "number"
          case .text: "text"
          case .blob: "blob"
          }
        output.append(contentsOf: Array(#"{"type":"#.utf8))
        Self.appendJSONString(kind, to: &output)
        output.append(contentsOf: Array(#","value":"#.utf8))
        Self.appendJSONString(value.payload, to: &output)
        output.append(UInt8(ascii: "}"))
      }
      output.append(UInt8(ascii: "]"))
    }
    output.append(UInt8(ascii: "]"))
    return output
  }

  static func appendJSONString(_ value: String, to output: inout Data) {
    output.append(UInt8(ascii: "\""))
    for byte in value.utf8 {
      switch byte {
      case UInt8(ascii: "\""):
        output.append(contentsOf: Array(#"\""#.utf8))
      case UInt8(ascii: "\\"):
        output.append(contentsOf: Array(#"\\"#.utf8))
      case 0x08:
        output.append(contentsOf: Array(#"\b"#.utf8))
      case 0x09:
        output.append(contentsOf: Array(#"\t"#.utf8))
      case 0x0A:
        output.append(contentsOf: Array(#"\n"#.utf8))
      case 0x0C:
        output.append(contentsOf: Array(#"\f"#.utf8))
      case 0x0D:
        output.append(contentsOf: Array(#"\r"#.utf8))
      case 0x00..<0x20:
        output.append(contentsOf: Array(String(format: "\\u%04x", byte).utf8))
      default:
        output.append(byte)
      }
    }
    output.append(UInt8(ascii: "\""))
  }

  /// SHA-256 over the stable type-tagged JSON representation.
  public var digest: String {
    SHA256.hash(data: encoding)
      .map { String(format: "%02x", $0) }.joined()
  }
}

/// Execution-accuracy comparison shared by the parity CLI and voting.
public enum EXScore {
  public static func matches(_ predicted: QueryResult, _ gold: QueryResult) -> Bool {
    guard !predicted.isTruncated, !gold.isTruncated else { return false }
    return CanonicalSQLResult(predicted).rows == CanonicalSQLResult(gold).rows
  }

  public static func canonicalFixtureData() throws -> Data {
    guard
      let url = Bundle.module.url(
        forResource: "canonical_result_fixtures",
        withExtension: "json")
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    return try Data(contentsOf: url)
  }
}
