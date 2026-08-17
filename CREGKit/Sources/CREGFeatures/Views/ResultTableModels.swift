import AutoTableCharts
import CREGEngine
import ComposableArchitecture
import SwiftUI

/// The reader-controlled density of full-screen result tables. This is
/// deliberately independent from Dynamic Type: the preset is an additional
/// preference, while every semantic font and scaled metric still follows the
/// system accessibility size.
public enum ResultTableTextSize: String, CaseIterable, Sendable, Equatable, Hashable {
  case small
  case standard
  case large

  public static let storageKey = "resultTableTextSize"

  public var title: String {
    switch self {
    case .small: "Small"
    case .standard: "Standard"
    case .large: "Large"
    }
  }

  var cellFont: Font {
    switch self {
    case .small: .caption2.monospacedDigit()
    case .standard: .caption.monospacedDigit()
    case .large: .body.monospacedDigit()
    }
  }

  var headerFont: Font {
    switch self {
    case .small: .caption2.weight(.semibold)
    case .standard: .caption.weight(.semibold)
    case .large: .callout.weight(.semibold)
    }
  }

  var metricScale: CGFloat {
    switch self {
    case .small: 0.84
    case .standard: 1
    case .large: 1.22
    }
  }
}

/// Shared geometry keeps headers and cells aligned and makes the scaling
/// policy independently testable from SwiftUI rendering.
struct ResultTableColumnMetrics: Equatable, Sendable {
  var characterWidth: CGFloat
  var horizontalPadding: CGFloat
  var minimumWidth: CGFloat
  var maximumWidth: CGFloat

  func widths(for result: QueryResult) -> [CGFloat] {
    result.columns.enumerated().map { index, column in
      var longest = column.count
      for row in result.rows.prefix(60) where index < row.count {
        longest = max(
          longest,
          ResultViewerLogic.displayedCopyValue(row[index], column: column).count)
      }
      let ideal = CGFloat(longest) * characterWidth + horizontalPadding * 2
      return min(max(ideal, minimumWidth), maximumWidth)
    }
  }
}

struct ResultCellSelection: Equatable, Sendable {
  var row: Int
  var column: Int
}

struct SelectedResultCell {
  var selection: ResultCellSelection
  var row: [SQLValue]
  var columnName: String
  var displayedValue: String
  var rawValue: String
}
