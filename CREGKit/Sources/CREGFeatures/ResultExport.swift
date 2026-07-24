import CREGEngine
import Foundation

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

extension QueryResult {
  /// Machine-facing CSV: raw full-precision values, RFC-4180 quoting, no
  /// display formatting, trailing newline. Exports carry portfolio data —
  /// the same caveat as the JSONL session export.
  public func csvString() -> String {
    var lines = [columns.map(Self.csvField).joined(separator: ",")]
    for row in rows {
      lines.append(
        row.map { Self.csvField($0.exportString) }.joined(separator: ","))
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// Human-facing Markdown table using the same column-aware display
  /// formatting as the transcript.
  public func markdownTableString() -> String {
    func cell(_ raw: String) -> String {
      raw
        .replacingOccurrences(of: "|", with: "\\|")
        .replacingOccurrences(of: "\n", with: " ")
    }
    var lines = [
      "| " + columns.map(cell).joined(separator: " | ") + " |",
      "|" + Array(repeating: " --- |", count: columns.count).joined(),
    ]
    for row in rows {
      let rendered = row.enumerated().map { index, value in
        cell(
          PortfolioValueFormatting.displayString(
            for: value,
            column: index < columns.count ? columns[index] : ""))
      }
      lines.append("| " + rendered.joined(separator: " | ") + " |")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  static func csvField(_ raw: String) -> String {
    guard
      raw.contains(where: {
        $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r"
      })
    else { return raw }
    return "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}

extension SQLValue {
  /// Raw export value: NULL is empty, numbers keep full precision without
  /// grouping, BLOBs are base64 so the export stays lossless.
  var exportString: String {
    switch self {
    case .null: ""
    case .integer(let value): String(value)
    case .real(let value):
      value == value.rounded() && abs(value) < 1e15
        ? String(Int64(value))
        : String(value)
    case .text(let string): string
    case .blob(let data): data.base64EncodedString()
    }
  }
}

/// Cross-platform clipboard; the package also builds for macOS so
/// `swift test` can run the feature tests.
public enum Pasteboard {
  @MainActor
  public static func copy(_ string: String) {
    #if canImport(UIKit)
      UIPasteboard.general.string = string
    #elseif canImport(AppKit)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(string, forType: .string)
    #endif
  }
}
