import CREGEngine
import ComposableArchitecture
import SwiftUI

// MARK: - Pure viewer logic

/// Sorting, searching, and truncation labeling for the Result Viewer. Pure
/// so result tests never need a rendered view.
public enum ResultViewerLogic {
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

// MARK: - Inline preview

/// The four-row Result Preview shown inline in the transcript; tapping it
/// opens the full-screen Result Viewer.
struct ResultPreviewView: View {
  let result: QueryResult
  let open: () -> Void

  static let previewRowLimit = 4

  var body: some View {
    if result.rows.isEmpty {
      Text("No matching rows.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(10)
    } else {
      Button(action: open) {
        VStack(alignment: .leading, spacing: 6) {
          Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
              ForEach(result.columns, id: \.self) { column in
                Text(column)
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
            }
            Divider()
            ForEach(
              Array(result.rows.prefix(Self.previewRowLimit).enumerated()),
              id: \.offset
            ) { _, row in
              GridRow {
                ForEach(Array(row.enumerated()), id: \.offset) { index, value in
                  Text(
                    PortfolioValueFormatting.displayString(
                      for: value,
                      column: index < result.columns.count
                        ? result.columns[index] : "")
                  )
                  .font(.caption.monospacedDigit())
                  .lineLimit(1)
                }
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .clipped()

          HStack(spacing: 6) {
            Text(ResultViewerLogic.rowCountLabel(for: result))
              .font(.caption2)
              .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Label("View table", systemImage: "arrow.up.left.and.arrow.down.right")
              .font(.caption2.weight(.medium))
              .foregroundStyle(CREGBrand.blue)
          }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        "Result table, \(ResultViewerLogic.rowCountLabel(for: result)). Opens full table")
    }
  }
}

// MARK: - Full-screen viewer

/// Full-screen Result Viewer: frozen headers, two-axis scrolling, one-column
/// typed sorting, local search, and copy/share/export of all returned rows.
struct ResultViewerView: View {
  let result: QueryResult
  @State private var sort: ResultViewerLogic.SortState?
  @State private var searchText = ""
  @Environment(\.dismiss) private var dismiss

  private var displayRows: [[SQLValue]] {
    ResultViewerLogic.displayRows(
      result: result, sort: sort, searchText: searchText)
  }

  /// Fixed per-column widths keep the frozen header aligned with rows.
  private var columnWidths: [CGFloat] {
    result.columns.enumerated().map { index, column in
      var longest = column.count
      for row in result.rows.prefix(60) where index < row.count {
        longest = max(
          longest,
          PortfolioValueFormatting.displayString(
            for: row[index], column: column
          ).count)
      }
      return min(max(CGFloat(longest) * 8.5 + 24, 96), 240)
    }
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        searchBar
        table
        footer
      }
      .navigationTitle("Result")
      .inlineNavigationTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          exportMenu
        }
      }
    }
  }

  private var searchBar: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField("Search rows", text: $searchText)
        .textFieldStyle(.plain)
        .autocorrectionDisabled()
      if !searchText.isEmpty {
        Button {
          searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    .padding(.horizontal)
    .padding(.vertical, 8)
  }

  private var table: some View {
    let widths = columnWidths
    return ScrollView(.horizontal) {
      VStack(alignment: .leading, spacing: 0) {
        headerRow(widths: widths)
        Divider()
        ScrollView(.vertical) {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(displayRows.enumerated()), id: \.offset) { entry in
              rowView(entry.element, widths: widths)
                .background(
                  entry.offset.isMultiple(of: 2)
                    ? Color.clear
                    : Color.primary.opacity(0.03))
            }
          }
        }
      }
    }
  }

  private func headerRow(widths: [CGFloat]) -> some View {
    HStack(spacing: 0) {
      ForEach(Array(result.columns.enumerated()), id: \.offset) { index, column in
        Button {
          sort = ResultViewerLogic.toggleSort(sort, column: index)
        } label: {
          HStack(spacing: 4) {
            Text(column)
              .font(.caption.weight(.semibold))
              .lineLimit(1)
            if sort?.column == index {
              Image(
                systemName: sort?.ascending == true
                  ? "chevron.up" : "chevron.down")
              .font(.caption2.weight(.bold))
            }
          }
          .foregroundStyle(
            sort?.column == index ? CREGBrand.blue : Color.secondary)
          .frame(width: widths[index], alignment: .leading)
          .padding(.vertical, 10)
          .padding(.horizontal, 6)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          sort?.column == index
            ? "Sort by \(column), \(sort?.ascending == true ? "ascending" : "descending")"
            : "Sort by \(column)")
      }
    }
    .padding(.horizontal, 10)
  }

  private func rowView(_ row: [SQLValue], widths: [CGFloat]) -> some View {
    HStack(spacing: 0) {
      ForEach(Array(row.enumerated()), id: \.offset) { index, value in
        Text(
          PortfolioValueFormatting.displayString(
            for: value,
            column: index < result.columns.count ? result.columns[index] : "")
        )
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .frame(
          width: index < widths.count ? widths[index] : 120,
          alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
      }
    }
    .padding(.horizontal, 10)
  }

  private var footer: some View {
    HStack(spacing: 8) {
      // Never imply hidden rows were loaded: truncated results stay labeled.
      Text(ResultViewerLogic.rowCountLabel(for: result))
        .font(.caption)
        .foregroundStyle(result.isTruncated ? .orange : .secondary)
      if !searchText.isEmpty {
        Text("· \(displayRows.count) matching")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal)
    .padding(.vertical, 10)
  }

  private var exportMenu: some View {
    Menu {
      Button("Copy as CSV") {
        Pasteboard.copy(result.csvString())
      }
      Button("Copy as Markdown") {
        Pasteboard.copy(result.markdownTableString())
      }
      ShareLink(
        item: ResultCSVTransfer(result: result),
        preview: SharePreview("Result table (CSV)")
      ) {
        Label("Share CSV", systemImage: "square.and.arrow.up")
      }
      ShareLink(item: result.markdownTableString()) {
        Label("Share Markdown", systemImage: "square.and.arrow.up")
      }
    } label: {
      Image(systemName: "square.and.arrow.up")
    }
    .accessibilityLabel("Export table")
  }
}

// MARK: - Presentation

extension View {
  /// Full-screen on iPhone; a sheet on the macOS host-test target, which has
  /// no full-screen cover.
  @ViewBuilder
  func resultViewerPresentation(store: StoreOf<ChatFeature>) -> some View {
    let binding = Binding<ResultViewerItem?>(
      get: {
        guard let id = store.resultViewerMessageID,
          let message = store.messages[id: id],
          case .answer(let result, _, _, _) = message.body
        else { return nil }
        return ResultViewerItem(messageID: id, result: result)
      },
      set: { item in
        if item == nil {
          store.send(.resultViewerDismissed)
        }
      })
    #if os(iOS)
      self.fullScreenCover(item: binding) { item in
        ResultViewerView(result: item.result)
      }
    #else
      self.sheet(item: binding) { item in
        ResultViewerView(result: item.result)
      }
    #endif
  }
}

struct ResultViewerItem: Identifiable, Equatable {
  var messageID: UUID
  var result: QueryResult
  var id: UUID { messageID }
}
