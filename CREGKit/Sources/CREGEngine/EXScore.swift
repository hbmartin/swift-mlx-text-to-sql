import Foundation

/// Execution-accuracy comparison, mirroring the Python harness
/// (fine-tuning/eval/ex.py): order-insensitive multiset equality over rows,
/// reals rounded to 4 decimals. Used by creg-eval-cli for parity scoring.
public enum EXScore {
  public static func matches(_ predicted: QueryResult, _ gold: QueryResult) -> Bool {
    guard predicted.rows.count == gold.rows.count else { return false }
    return normalizedRows(predicted) == normalizedRows(gold)
  }

  static func normalizedRows(_ result: QueryResult) -> [[String]] {
    result.rows.map { row in
      row.map { value -> String in
        switch value {
        case .real(let v):
          let rounded = (v * 10_000).rounded() / 10_000
          return rounded == rounded.rounded() && abs(rounded) < 1e15
            ? String(Int64(rounded)) : String(rounded)
        case .integer(let v): return String(v)
        case .text(let s): return s
        case .null: return "\u{0}NULL"
        case .blob(let d): return "\u{0}BLOB\(d.count)"
        }
      }
    }.sorted { $0.lexicographicallyPrecedes($1) }
  }
}
