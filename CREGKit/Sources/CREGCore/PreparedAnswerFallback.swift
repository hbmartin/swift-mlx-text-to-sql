import Foundation

public enum PreparedAnswerFallback {
  public static func narration(for result: QueryResult) -> String {
    result.rowCount == 0
      ? "I didn't find any matching rows."
      : "Here's what I found — \(result.rowCount) row\(result.rowCount == 1 ? "" : "s")\(result.isTruncated ? " (showing the first \(result.rowCount))" : "")."
  }
}
