import CryptoKit
import Foundation

/// A type-preserving SQLite value used for EX scoring and vote grouping.
///
/// INTEGER and REAL intentionally share the numeric case. TEXT, BLOB, and
/// NULL never compare equal to a display-identical value in another domain.
public enum CanonicalSQLValue: Sendable, Equatable, Hashable, Codable, Comparable {
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

  private var sortKey: (Int, String) {
    switch self {
    case .null: (0, "")
    case .number(let value): (1, value)
    case .text(let value): (2, value)
    case .blob(let value): (3, value.base64EncodedString())
    }
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.sortKey.0 != rhs.sortKey.0 {
      return lhs.sortKey.0 < rhs.sortKey.0
    }
    return lhs.sortKey.1 < rhs.sortKey.1
  }

  /// Decimal, four-place, half-even normalization shared with Python EX.
  static func canonicalNumber(_ value: Double) -> String {
    guard value.isFinite else {
      // SQLite converts NaN to NULL and should not produce infinities for the
      // frozen corpus. Keep an explicit value if a custom client does.
      if value.isNaN { return "nan" }
      return value.sign == .minus ? "-inf" : "inf"
    }
    var input = Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX"))
      ?? Decimal(value)
    var rounded = Decimal()
    NSDecimalRound(&rounded, &input, 4, .bankers)
    if rounded == 0 { return "0" }
    return NSDecimalNumber(decimal: rounded).stringValue
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
  public var encoding: Data {
    struct PayloadValue: Encodable {
      let type: String
      let value: String
    }
    let payload: [[PayloadValue]] = rows.map { row in
      row.values.map { value in
        switch value {
        case .null: PayloadValue(type: "null", value: "")
        case .number(let number): PayloadValue(type: "number", value: number)
        case .text(let text): PayloadValue(type: "text", value: text)
        case .blob(let data):
          PayloadValue(type: "blob", value: data.base64EncodedString())
        }
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(payload)) ?? Data()
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
