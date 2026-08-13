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

  public static func runtimeMode(for message: ChatMessage) -> ModelRuntimeMode {
    if let mode = message.devInfo?.runtimeMode { return mode }
    if case .preparedAnswer(let prepared) = message.body {
      return prepared.provenance.runtimeMode
    }
    return .evaluated
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

private struct SelectedResultCell {
  var selection: ResultCellSelection
  var row: [SQLValue]
  var columnName: String
  var displayedValue: String
  var rawValue: String
}

// MARK: - Inline preview

/// The four-row Result Preview shown inline in the transcript; tapping it
/// opens the full-screen Result Viewer.
struct ResultPreviewView: View {
  let result: QueryResult
  let open: () -> Void

  static let previewRowLimit = 4
  @State private var pinchMagnification: CGFloat = 1
  @State private var pinchIsArmed = false
  @State private var pinchHapticTrigger = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private var renderedScale: CGFloat {
    reduceMotion
      ? 1
      : ResultViewerLogic.previewScale(for: pinchMagnification)
  }

  var body: some View {
    if result.rows.isEmpty {
      Text("No matching rows.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(10)
    } else {
      Button(action: open) {
        VStack(alignment: .leading, spacing: 6) {
          ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 6) {
              GridRow {
                ForEach(result.columns, id: \.self) { column in
                  Text(column)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
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
                      ResultViewerLogic.displayedCopyValue(
                        value,
                        column: index < result.columns.count
                          ? result.columns[index] : "")
                    )
                    .font(.caption.monospacedDigit())
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                  }
                }
              }
            }
            .fixedSize(horizontal: true, vertical: false)
          }
          .scrollIndicators(.visible)

          HStack(spacing: 6) {
            Text(ResultViewerLogic.rowCountLabel(for: result))
              .font(.caption2)
              .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Label(
              pinchIsArmed ? "Release to expand" : "View table",
              systemImage: "arrow.up.left.and.arrow.down.right"
            )
            .font(.caption2.weight(.medium))
            .foregroundStyle(CREGBrand.blue)
            .contentTransition(.symbolEffect(.replace))
          }
        }
        .padding(10)
        .background(
          .quaternary.opacity(0.5),
          in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 12)
            .stroke(
              CREGBrand.blue.opacity(pinchIsArmed ? 0.85 : 0),
              lineWidth: 2)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .scaleEffect(renderedScale)
      .simultaneousGesture(pinchGesture)
      .sensoryFeedback(.selection, trigger: pinchHapticTrigger)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "Result table, \(ResultViewerLogic.rowCountLabel(for: result))"
      )
      .accessibilityHint("Double-tap or pinch outward to open the full table")
    }
  }

  private var pinchGesture: some Gesture {
    MagnifyGesture()
      .onChanged { value in
        let magnification = value.magnification
        let armed = ResultViewerLogic.pinchIsArmed(
          magnification: magnification,
          wasArmed: pinchIsArmed)
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
          pinchMagnification = magnification
          if armed && !pinchIsArmed {
            pinchHapticTrigger += 1
          }
          pinchIsArmed = armed
        }
      }
      .onEnded { value in
        let shouldOpen = ResultViewerLogic.pinchIsArmed(
          magnification: value.magnification,
          wasArmed: pinchIsArmed)
        withAnimation(
          reduceMotion ? nil : .spring(duration: 0.24, bounce: 0.18)
        ) {
          pinchMagnification = 1
          pinchIsArmed = false
        }
        if shouldOpen {
          open()
        }
      }
  }
}

// MARK: - Full-screen viewer

/// Full-screen Result Viewer: frozen headers, two-axis scrolling, one-column
/// typed sorting, local search, and copy/share/export of all returned rows.
struct ResultViewerView: View {
  let result: QueryResult
  let runtimeMode: ModelRuntimeMode
  @Binding var textSize: ResultTableTextSize
  @State private var sort: ResultViewerLogic.SortState?
  @State private var searchText: String
  @State private var selectedCell: ResultCellSelection?
  @State private var copyFeedbackMessage: String?
  @State private var copyFeedbackTrigger = 0
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ScaledMetric(relativeTo: .caption) private var baseCharacterWidth = 8.5
  @ScaledMetric(relativeTo: .caption) private var baseHorizontalPadding = 6.0
  @ScaledMetric(relativeTo: .caption) private var baseMinimumWidth = 96.0
  @ScaledMetric(relativeTo: .caption) private var baseMaximumWidth = 240.0
  @ScaledMetric(relativeTo: .caption) private var baseRowVerticalPadding = 8.0

  init(
    result: QueryResult,
    runtimeMode: ModelRuntimeMode,
    textSize: Binding<ResultTableTextSize>,
    initialSearchText: String = "",
    initialSelection: ResultCellSelection? = nil
  ) {
    self.result = result
    self.runtimeMode = runtimeMode
    self._textSize = textSize
    self._searchText = State(initialValue: initialSearchText)
    self._selectedCell = State(initialValue: initialSelection)
  }

  private func columnWidths() -> [CGFloat] {
    let scale = textSize.metricScale
    return ResultTableColumnMetrics(
      characterWidth: baseCharacterWidth * scale,
      horizontalPadding: baseHorizontalPadding * scale,
      minimumWidth: baseMinimumWidth * scale,
      maximumWidth: baseMaximumWidth * scale
    ).widths(for: result)
  }

  private var cellHorizontalPadding: CGFloat {
    baseHorizontalPadding * textSize.metricScale
  }

  private var rowVerticalPadding: CGFloat {
    baseRowVerticalPadding * textSize.metricScale
  }

  private var normalizedSearchText: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var searchIsActive: Bool {
    !normalizedSearchText.isEmpty
  }

  private func selectedResultCell(
    in displayRows: [[SQLValue]]
  ) -> SelectedResultCell? {
    guard let selectedCell,
      displayRows.indices.contains(selectedCell.row),
      result.columns.indices.contains(selectedCell.column)
    else { return nil }
    let row = displayRows[selectedCell.row]
    let value =
      selectedCell.column < row.count
      ? row[selectedCell.column] : .null
    let columnName = result.columns[selectedCell.column]
    return SelectedResultCell(
      selection: selectedCell,
      row: row,
      columnName: columnName,
      displayedValue: ResultViewerLogic.displayedCopyValue(
        value, column: columnName),
      rawValue: ResultViewerLogic.rawCopyValue(value))
  }

  var body: some View {
    let displayRows = ResultViewerLogic.displayRows(
      result: result, sort: sort, searchText: searchText)
    let widths = columnWidths()
    let selectedResultCell = selectedResultCell(in: displayRows)
    NavigationStack {
      searchable(
        VStack(spacing: 0) {
          table(displayRows: displayRows, widths: widths)
          if let selectedResultCell {
            selectionAccessory(selectedResultCell)
          }
          footer(displayedRowCount: displayRows.count)
        }
      )
      .navigationTitle("Result Table")
      .inlineNavigationTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItemGroup(placement: .primaryAction) {
          textSizeMenu
          exportMenu
        }
      }
    }
    .onChange(of: searchText) { _, _ in
      selectedCell = nil
    }
    .onChange(of: sort) { _, _ in
      selectedCell = nil
    }
  }

  @ViewBuilder
  private func searchable<Content: View>(_ content: Content) -> some View {
    #if os(iOS)
      content.searchable(
        text: $searchText,
        placement: .navigationBarDrawer(displayMode: .always),
        prompt: "Search rows")
    #else
      content.searchable(text: $searchText, prompt: "Search rows")
    #endif
  }

  private func table(
    displayRows: [[SQLValue]],
    widths: [CGFloat]
  ) -> some View {
    ZStack(alignment: .top) {
      ScrollView(.horizontal) {
        VStack(alignment: .leading, spacing: 0) {
          headerRow(widths: widths)
          Divider()
          ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(Array(displayRows.enumerated()), id: \.offset) { entry in
                rowView(
                  entry.element,
                  displayIndex: entry.offset,
                  widths: widths)
              }
            }
          }
          .scrollDismissesKeyboard(.interactively)
        }
      }
      .scrollIndicators(.visible)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

      if searchIsActive && displayRows.isEmpty {
        noMatchesState
      }
    }
    .overlay(alignment: .bottom) { copyFeedback }
    .sensoryFeedback(.success, trigger: copyFeedbackTrigger)
    .task(id: copyFeedbackTrigger) {
      guard copyFeedbackTrigger > 0 else { return }
      let trigger = copyFeedbackTrigger
      try? await Task.sleep(for: .seconds(1.4))
      guard !Task.isCancelled, trigger == copyFeedbackTrigger else { return }
      withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) {
        copyFeedbackMessage = nil
      }
    }
  }

  private func headerRow(widths: [CGFloat]) -> some View {
    HStack(alignment: .top, spacing: 0) {
      ForEach(Array(result.columns.enumerated()), id: \.offset) { index, column in
        Button {
          sort = ResultViewerLogic.toggleSort(sort, column: index)
        } label: {
          HStack(alignment: .top, spacing: 4) {
            Text(column)
              .font(textSize.headerFont)
              .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
              .multilineTextAlignment(.leading)
            if sort?.column == index {
              Image(
                systemName: sort?.ascending == true
                  ? "chevron.up" : "chevron.down"
              )
              .font(.caption2.weight(.bold))
              .contentTransition(.symbolEffect(.replace))
            }
          }
          .foregroundStyle(
            sort?.column == index ? CREGBrand.blue : Color.secondary
          )
          .padding(.horizontal, cellHorizontalPadding)
          .padding(.vertical, 8)
          .frame(width: widths[index], alignment: .leading)
          .frame(minHeight: 44, alignment: .topLeading)
          .contentShape(Rectangle())
          .overlay(alignment: .trailing) { Divider() }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          sort?.column == index
            ? "Sort by \(column), \(sort?.ascending == true ? "ascending" : "descending")"
            : "Sort by \(column)")
      }
    }
    .padding(.horizontal, 10)
    .background(.thinMaterial)
    .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: sort)
  }

  private func rowView(
    _ row: [SQLValue],
    displayIndex: Int,
    widths: [CGFloat]
  ) -> some View {
    let rowIsSelected = selectedCell?.row == displayIndex
    return HStack(alignment: .top, spacing: 0) {
      ForEach(result.columns.indices, id: \.self) { index in
        let value: SQLValue = index < row.count ? row[index] : .null
        let column = result.columns[index]
        let displayed = ResultViewerLogic.displayedCopyValue(
          value, column: column)
        let raw = ResultViewerLogic.rawCopyValue(value)
        let selection = ResultCellSelection(row: displayIndex, column: index)
        let isSelected = selectedCell == selection

        Button {
          selectedCell = isSelected ? nil : selection
        } label: {
          Text(displayed)
            .font(textSize.cellFont)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, cellHorizontalPadding)
            .frame(
              width: index < widths.count ? widths[index] : 120,
              alignment: .topLeading
            )
            .padding(.vertical, rowVerticalPadding)
            .background(
              isSelected ? CREGBrand.blue.opacity(0.14) : Color.clear
            )
            .overlay(alignment: .trailing) { Divider() }
            .overlay {
              if isSelected {
                RoundedRectangle(cornerRadius: 6)
                  .stroke(CREGBrand.blue, lineWidth: 2)
                  .padding(2)
              }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
          cellCopyActions(displayed: displayed, raw: raw, row: row)
        }
        .accessibilityLabel(
          "Row \(displayIndex + 1), \(column), \(displayed)"
        )
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Copy value") {
          copy(displayed, confirmation: "Value copied")
        }
        .accessibilityAction(named: "Copy row as CSV") {
          copy(
            ResultViewerLogic.csvRowString(row),
            confirmation: "Row copied")
        }
      }
    }
    .padding(.horizontal, 10)
    .background(
      rowIsSelected
        ? CREGBrand.blue.opacity(0.06)
        : displayIndex.isMultiple(of: 2)
          ? Color.clear
          : Color.primary.opacity(0.035))
  }

  @ViewBuilder
  private func cellCopyActions(
    displayed: String,
    raw: String,
    row: [SQLValue]
  ) -> some View {
    Button {
      copy(displayed, confirmation: "Value copied")
    } label: {
      Label("Copy Value", systemImage: "doc.on.doc")
    }
    if raw != displayed {
      Button {
        copy(raw, confirmation: "Raw value copied")
      } label: {
        Label("Copy Raw Value", systemImage: "number")
      }
    }
    Button {
      copy(
        ResultViewerLogic.csvRowString(row),
        confirmation: "Row copied")
    } label: {
      Label("Copy Row as CSV", systemImage: "tablecells")
    }
  }

  private func selectionAccessory(
    _ selected: SelectedResultCell
  ) -> some View {
    let layout =
      dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
      : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
    return layout {
      VStack(alignment: .leading, spacing: 2) {
        Text("Row \(selected.selection.row + 1) · \(selected.columnName)")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(selected.displayedValue)
          .font(textSize.cellFont)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
          .textSelection(.enabled)
      }
      if !dynamicTypeSize.isAccessibilitySize {
        Spacer(minLength: 0)
      }
      selectionActions(selected)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(.thinMaterial)
    .transition(
      reduceMotion
        ? .opacity
        : .opacity.combined(with: .move(edge: .bottom))
    )
    .animation(
      reduceMotion ? nil : .smooth(duration: 0.22),
      value: selectedCell)
  }

  private func selectionActions(_ selected: SelectedResultCell) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 6) {
        selectionCopyButton(selected)
        selectionMoreMenu(selected)
        clearSelectionButton
      }
      VStack(alignment: .leading, spacing: 4) {
        selectionCopyButton(selected)
        selectionMoreMenu(selected)
        clearSelectionButton
      }
    }
  }

  private func selectionCopyButton(
    _ selected: SelectedResultCell
  ) -> some View {
    Button {
      copy(selected.displayedValue, confirmation: "Value copied")
    } label: {
      Label("Copy Value", systemImage: "doc.on.doc")
    }
    .buttonStyle(.borderedProminent)
    .cregTextButtonTarget()
  }

  private func selectionMoreMenu(_ selected: SelectedResultCell) -> some View {
    Menu {
      if selected.rawValue != selected.displayedValue {
        Button {
          copy(selected.rawValue, confirmation: "Raw value copied")
        } label: {
          Label("Copy Raw Value", systemImage: "number")
        }
      }
      Button {
        copy(
          ResultViewerLogic.csvRowString(selected.row),
          confirmation: "Row copied")
      } label: {
        Label("Copy Row as CSV", systemImage: "tablecells")
      }
    } label: {
      Label("More", systemImage: "ellipsis.circle")
    }
    .buttonStyle(.bordered)
    .cregTextButtonTarget()
  }

  private var clearSelectionButton: some View {
    Button {
      selectedCell = nil
    } label: {
      Image(systemName: "xmark")
        .cregIconButtonTarget()
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Clear cell selection")
    .cregLargeContentViewer("Clear selection", systemImage: "xmark")
  }

  private func footer(displayedRowCount: Int) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        rowStatus(displayedRowCount: displayedRowCount)
        Spacer(minLength: 0)
        sortChip
      }
      VStack(alignment: .leading, spacing: 6) {
        rowStatus(displayedRowCount: displayedRowCount)
        sortChip
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 6)
    .background(Color.primary.opacity(0.025))
    .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: sort)
  }

  private func rowStatus(displayedRowCount: Int) -> some View {
    Text(
      ResultViewerLogic.rowStatusLabel(
        for: result,
        displayedRowCount: displayedRowCount,
        searchIsActive: !normalizedSearchText.isEmpty)
    )
    .font(.caption)
    .foregroundStyle(result.isTruncated ? .orange : .secondary)
  }

  @ViewBuilder
  private var sortChip: some View {
    if let sort, result.columns.indices.contains(sort.column) {
      Button {
        self.sort = nil
      } label: {
        HStack(spacing: 5) {
          Image(systemName: sort.ascending ? "arrow.up" : "arrow.down")
          Text(result.columns[sort.column])
            .lineLimit(1)
          Image(systemName: "xmark.circle.fill")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(CREGBrand.blue)
        .padding(.horizontal, 10)
        .background(CREGBrand.blue.opacity(0.1), in: Capsule())
      }
      .buttonStyle(.plain)
      .cregTextButtonTarget()
      .accessibilityLabel(
        "Clear sort by \(result.columns[sort.column]), \(sort.ascending ? "ascending" : "descending")"
      )
    }
  }

  private var noMatchesState: some View {
    ContentUnavailableView {
      Label("No Matching Rows", systemImage: "magnifyingglass")
    } description: {
      Text("No returned row contains “\(normalizedSearchText)”.")
    } actions: {
      Button("Clear Search") { searchText = "" }
        .buttonStyle(.borderedProminent)
        .cregTextButtonTarget()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(CREGBrand.chatSurface.opacity(0.96))
  }

  @ViewBuilder
  private var copyFeedback: some View {
    if let copyFeedbackMessage {
      Label(copyFeedbackMessage, systemImage: "checkmark.circle.fill")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.green)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 12)
        .transition(
          reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.96))
        )
        .accessibilityLabel(copyFeedbackMessage)
    }
  }

  private func copy(_ string: String, confirmation: String) {
    Pasteboard.copy(string)
    withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) {
      copyFeedbackMessage = confirmation
      copyFeedbackTrigger += 1
    }
  }

  private var textSizeMenu: some View {
    Menu {
      Picker("Table Text Size", selection: $textSize) {
        ForEach(ResultTableTextSize.allCases, id: \.self) { size in
          Text(size.title).tag(size)
        }
      }
    } label: {
      Image(systemName: "textformat.size")
        .cregIconButtonTarget()
    }
    .accessibilityLabel("Table text size")
    .accessibilityValue(textSize.title)
    .cregLargeContentViewer("Table text size", systemImage: "textformat.size")
  }

  private var exportMenu: some View {
    Menu {
      Button("Copy as CSV") {
        Pasteboard.copy(result.csvString(runtimeMode: runtimeMode))
      }
      Button("Copy as Markdown") {
        Pasteboard.copy(result.markdownTableString(runtimeMode: runtimeMode))
      }
      ShareLink(
        item: ResultCSVTransfer(result: result, runtimeMode: runtimeMode),
        preview: SharePreview("Result table (CSV)")
      ) {
        Label("Share CSV", systemImage: "square.and.arrow.up")
      }
      ShareLink(item: result.markdownTableString(runtimeMode: runtimeMode)) {
        Label("Share Markdown", systemImage: "square.and.arrow.up")
      }
    } label: {
      Image(systemName: "square.and.arrow.up")
        .cregIconButtonTarget()
    }
    .accessibilityLabel("Export table")
    .cregLargeContentViewer("Export table", systemImage: "square.and.arrow.up")
  }
}

// MARK: - Presentation

extension View {
  /// Full-screen on iPhone; a sheet on the macOS host-test target, which has
  /// no full-screen cover.
  @ViewBuilder
  func resultViewerPresentation(
    store: StoreOf<ChatFeature>,
    textSize: Binding<ResultTableTextSize>
  ) -> some View {
    let binding = Binding<ResultViewerItem?>(
      get: {
        guard let id = store.resultViewerMessageID,
          let message = store.messages[id: id]
        else { return nil }
        let result: QueryResult
        switch message.body {
        case .answer(let answerResult, _, _, _):
          result = answerResult
        case .preparedAnswer(let prepared):
          result = prepared.result
        default:
          return nil
        }
        return ResultViewerItem(
          messageID: id,
          result: result,
          runtimeMode: ResultViewerLogic.runtimeMode(for: message))
      },
      set: { item in
        if item == nil {
          store.send(.resultViewerDismissed)
        }
      })
    #if os(iOS)
      self.fullScreenCover(item: binding) { item in
        ResultViewerView(
          result: item.result,
          runtimeMode: item.runtimeMode,
          textSize: textSize)
      }
    #else
      self.sheet(item: binding) { item in
        ResultViewerView(
          result: item.result,
          runtimeMode: item.runtimeMode,
          textSize: textSize)
      }
    #endif
  }
}

struct ResultViewerItem: Identifiable, Equatable {
  var messageID: UUID
  var result: QueryResult
  var runtimeMode: ModelRuntimeMode
  var id: UUID { messageID }
}
