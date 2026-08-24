import AutoTableCharts
import CREGEngine
import ComposableArchitecture
import SwiftUI

// MARK: - Pure viewer logic

/// Sorting, searching, and truncation labeling for the Result Viewer. Pure
/// so result tests never need a rendered view.
public enum ResultViewerLogic {
  public static let pinchArmThreshold: CGFloat = 1.12
  public static let pinchDisarmThreshold: CGFloat = 1.08

  public struct SortState: Equatable, Sendable {
    public var column: Int
    public var ascending: Bool

    public init(column: Int, ascending: Bool) {
      self.column = column
      self.ascending = ascending
    }
  }

  /// One-column typed sorting: a new column starts ascending; the active
  /// column toggles direction.
  public static func toggleSort(_ current: SortState?, column: Int) -> SortState {
    guard let current, current.column == column else {
      return SortState(column: column, ascending: true)
    }
    return SortState(column: column, ascending: !current.ascending)
  }

  /// Case- and diacritic-insensitive local normalization shared by the
  /// query and every searched cell.
  public static func normalizedForSearch(_ text: String) -> String {
    text.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: nil)
  }

  /// Rows filtered by search text and ordered by the sort state. Sorting is
  /// typed: NULL, then the unified numeric domain, then text, then BLOB —
  /// never string comparison of formatted numbers.
  public static func displayRows(
    result: QueryResult,
    sort: SortState?,
    searchText: String
  ) -> [[SQLValue]] {
    var rows = result.rows
    let query = normalizedForSearch(
      searchText.trimmingCharacters(in: .whitespacesAndNewlines))
    if !query.isEmpty {
      rows = rows.filter { row in
        row.contains { cell in
          normalizedForSearch(cell.displayString).contains(query)
            || normalizedForSearch(cell.exportString).contains(query)
        }
      }
    }
    guard let sort, sort.column >= 0, sort.column < result.columns.count else {
      return rows
    }
    // Index tie-break keeps equal cells in their original result order.
    return rows.enumerated()
      .sorted { lhs, rhs in
        let left = cell(lhs.element, at: sort.column)
        let right = cell(rhs.element, at: sort.column)
        if valuesEqual(left, right) {
          return lhs.offset < rhs.offset
        }
        let ascending = isOrderedAscending(left, right)
        return sort.ascending ? ascending : !ascending
      }
      .map(\.element)
  }

  public static func truncationLabel(for result: QueryResult) -> String? {
    guard result.isTruncated else { return nil }
    return "First \(result.rowCount)+ rows"
  }

  public static func rowCountLabel(for result: QueryResult) -> String {
    truncationLabel(for: result)
      ?? "\(result.rowCount) row\(result.rowCount == 1 ? "" : "s")"
  }

  public static func rowStatusLabel(
    for result: QueryResult,
    displayedRowCount: Int,
    searchIsActive: Bool
  ) -> String {
    guard searchIsActive else { return rowCountLabel(for: result) }
    if let truncation = truncationLabel(for: result) {
      return "\(truncation) · \(displayedRowCount) matching returned rows"
    }
    return "\(displayedRowCount) of \(result.rowCount) returned rows"
  }

  public static func selectedRowStatusLabel(
    for result: QueryResult,
    selectedRowCount: Int,
    displayedRowCount: Int,
    searchIsActive: Bool
  ) -> String {
    let selection =
      searchIsActive
      ? "\(displayedRowCount) matching selected row\(displayedRowCount == 1 ? "" : "s")"
      : "\(selectedRowCount) selected of \(result.rowCount) returned rows"
    guard let truncation = truncationLabel(for: result) else { return selection }
    return "\(truncation) · \(selection)"
  }

  public static func runtimeMode(for message: ChatMessage) -> ModelRuntimeMode {
    if let mode = message.devInfo?.runtimeMode { return mode }
    if case .preparedAnswer(let prepared) = message.body {
      return prepared.provenance.runtimeMode
    }
    return .evaluated
  }

  /// The visible mode may temporarily fall back without rewriting the user's
  /// persisted choice. This keeps the picker and rendered content consistent
  /// while chart analysis or preparation makes Chart unavailable.
  static func effectivePresentationMode(
    requestedMode: ResultPresentationPreference.Mode,
    hasChart: Bool,
    preparationFailed: Bool
  ) -> ResultPresentationPreference.Mode {
    guard hasChart, !preparationFailed else { return .table }
    return requestedMode
  }

  enum ModeSelectionIntent: Equatable {
    case none
    case persist(ResultPresentationPreference)
    /// A failed chart can be retried without rewriting an existing Chart
    /// preference. When the user is changing from Table to Chart, the new
    /// preference accompanies the retry.
    case retryChart(ResultPresentationPreference?)
  }

  /// Interprets a Chart/Table action without conflating the resolved chart
  /// recommendation with the persisted one. This preserves `nil` as automatic
  /// and keeps retry behavior explicit and testable.
  static func modeSelectionIntent(
    _ selectedMode: ResultPresentationPreference.Mode,
    requestedMode: ResultPresentationPreference.Mode,
    preserving specificationID: AutoChartRecommendationID?,
    preparationFailed: Bool
  ) -> ModeSelectionIntent {
    if selectedMode == .chart, preparationFailed {
      let updated =
        selectedMode == requestedMode
        ? nil
        : ResultPresentationPreference(
          mode: selectedMode,
          specificationID: specificationID)
      return .retryChart(updated)
    }
    guard selectedMode != requestedMode else { return .none }
    return .persist(
      ResultPresentationPreference(
        mode: selectedMode,
        specificationID: specificationID))
  }

  /// Choosing a chart type is also an explicit request to show a chart. This
  /// matters while the recovery menu remains available over a Table fallback.
  static func chartTypeSelectionPreference(
    specificationID: AutoChartRecommendationID?
  ) -> ResultPresentationPreference {
    ResultPresentationPreference(
      mode: .chart,
      specificationID: specificationID)
  }

  /// Migrates a stored chart ID when analysis resolves it to a current
  /// recommendation. A policy bump invalidates the obsolete explicit pin but
  /// does not misrepresent the newly defaulted chart as a user selection.
  /// An automatic nil preference remains automatic.
  static func migratedPreference(
    _ preference: ResultPresentationPreference?,
    resolvedSpecificationID: AutoChartRecommendationID
  ) -> ResultPresentationPreference? {
    guard let preference, let storedID = preference.specificationID else {
      return nil
    }
    if storedID.policyVersion != resolvedSpecificationID.policyVersion {
      return ResultPresentationPreference(
        mode: preference.mode,
        specificationID: nil)
    }
    guard storedID != resolvedSpecificationID else { return nil }
    return ResultPresentationPreference(
      mode: preference.mode,
      specificationID: resolvedSpecificationID)
  }

  /// Pinch arming uses hysteresis so tiny reversals around the activation
  /// threshold do not flicker the visual or haptic feedback.
  public static func pinchIsArmed(
    magnification: CGFloat,
    wasArmed: Bool
  ) -> Bool {
    if wasArmed {
      return magnification >= pinchDisarmThreshold
    }
    return magnification >= pinchArmThreshold
  }

  /// Direct manipulation stays restrained: the card follows the fingers but
  /// never grows enough to disturb transcript layout before presentation.
  public static func previewScale(for magnification: CGFloat) -> CGFloat {
    min(max(1 + (magnification - 1) * 0.25, 1), 1.04)
  }

  public static func displayedCopyValue(
    _ value: SQLValue,
    column: String
  ) -> String {
    PortfolioValueFormatting.displayString(for: value, column: column)
  }

  public static func rawCopyValue(_ value: SQLValue) -> String {
    value.exportString
  }

  /// A headerless RFC-4180 record pastes cleanly into spreadsheet tools while
  /// preserving the result's raw, full-precision values.
  public static func csvRowString(_ row: [SQLValue]) -> String {
    row.map { QueryResult.csvField($0.exportString) }
      .joined(separator: ",") + "\n"
  }

  private static func cell(_ row: [SQLValue], at index: Int) -> SQLValue {
    index < row.count ? row[index] : .null
  }

  private static func valuesEqual(_ lhs: SQLValue, _ rhs: SQLValue) -> Bool {
    if let left = numeric(lhs), let right = numeric(rhs) {
      return left == right
    }
    return lhs == rhs
  }

  /// Typed ascending order: NULL < numeric < text < blob, numbers compared
  /// in the unified INTEGER/REAL domain and text case-insensitively.
  static func isOrderedAscending(_ lhs: SQLValue, _ rhs: SQLValue) -> Bool {
    let leftRank = domainRank(lhs)
    let rightRank = domainRank(rhs)
    guard leftRank == rightRank else { return leftRank < rightRank }
    switch (lhs, rhs) {
    case (.null, .null):
      return false
    case (.text(let left), .text(let right)):
      let folded = normalizedForSearch(left)
        .compare(normalizedForSearch(right))
      if folded == .orderedSame { return left < right }
      return folded == .orderedAscending
    case (.blob(let left), .blob(let right)):
      return left.count < right.count
    default:
      guard let left = numeric(lhs), let right = numeric(rhs)
      else { return false }
      return left < right
    }
  }

  private static func numeric(_ value: SQLValue) -> Double? {
    switch value {
    case .integer(let value): Double(value)
    case .real(let value): value
    default: nil
    }
  }

  private static func domainRank(_ value: SQLValue) -> Int {
    switch value {
    case .null: 0
    case .integer, .real: 1
    case .text: 2
    case .blob: 3
    }
  }
}
