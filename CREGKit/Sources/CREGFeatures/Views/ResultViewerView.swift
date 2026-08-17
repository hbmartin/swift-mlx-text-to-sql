import AutoTableCharts
import CREGEngine
import ComposableArchitecture
import SwiftUI

// MARK: - Full-screen viewer

/// Full-screen Chart/Table explorer with exact-mark linked filtering. Table
/// export always retains the complete returned result rather than the current
/// chart selection.
struct ResultViewerView: View {
  let result: QueryResult
  let runtimeMode: ModelRuntimeMode
  let chartTable: CREGChartTable
  let chartRecommendations: [AutoChartRecommendation]
  let persistPreference: (ResultPresentationPreference) -> Void
  @Binding var textSize: ResultTableTextSize
  @State var sort: ResultViewerLogic.SortState?
  @State var searchText: String
  @State var selectedCell: ResultCellSelection?
  @State var resultMode: ResultPresentationPreference.Mode
  @State var selectedSpecificationID: String?
  @State var chartSelection: AutoChartSelection?
  @State var copyFeedbackMessage: String?
  @State var copyFeedbackTrigger = 0
  @Environment(\.dismiss) var dismiss
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @Environment(\.dynamicTypeSize) var dynamicTypeSize
  @ScaledMetric(relativeTo: .caption) var baseCharacterWidth = 8.5
  @ScaledMetric(relativeTo: .caption) var baseHorizontalPadding = 6.0
  @ScaledMetric(relativeTo: .caption) var baseMinimumWidth = 96.0
  @ScaledMetric(relativeTo: .caption) var baseMaximumWidth = 240.0
  @ScaledMetric(relativeTo: .caption) var baseRowVerticalPadding = 8.0

  struct CacheIdentity {
    var messageID: UUID
    var resultFingerprint: String
  }

  /// Cacheless harness/preview initializer for results that are not backed by
  /// a transcript message.
  init(
    result: QueryResult,
    runtimeMode: ModelRuntimeMode,
    textSize: Binding<ResultTableTextSize>,
    sql: String = "",
    question: String? = nil,
    preference: ResultPresentationPreference? = nil,
    persistPreference: @escaping (ResultPresentationPreference) -> Void = { _ in },
    initialSearchText: String = "",
    initialSelection: ResultCellSelection? = nil,
    initialChartSelection: AutoChartSelection? = nil
  ) {
    self.init(
      result: result,
      runtimeMode: runtimeMode,
      textSize: textSize,
      cacheIdentity: nil,
      sql: sql,
      question: question,
      preference: preference,
      persistPreference: persistPreference,
      initialSearchText: initialSearchText,
      initialSelection: initialSelection,
      initialChartSelection: initialChartSelection)
  }

  /// Transcript initializer. Cache identity is required, so a caller cannot
  /// silently turn repeated chart analysis back on by omitting a fingerprint.
  init(
    result: QueryResult,
    runtimeMode: ModelRuntimeMode,
    textSize: Binding<ResultTableTextSize>,
    messageID: UUID,
    resultFingerprint: String,
    sql: String = "",
    question: String? = nil,
    preference: ResultPresentationPreference? = nil,
    persistPreference: @escaping (ResultPresentationPreference) -> Void = { _ in },
    initialSearchText: String = "",
    initialSelection: ResultCellSelection? = nil,
    initialChartSelection: AutoChartSelection? = nil
  ) {
    self.init(
      result: result,
      runtimeMode: runtimeMode,
      textSize: textSize,
      cacheIdentity: CacheIdentity(
        messageID: messageID, resultFingerprint: resultFingerprint),
      sql: sql,
      question: question,
      preference: preference,
      persistPreference: persistPreference,
      initialSearchText: initialSearchText,
      initialSelection: initialSelection,
      initialChartSelection: initialChartSelection)
  }

  private init(
    result: QueryResult,
    runtimeMode: ModelRuntimeMode,
    textSize: Binding<ResultTableTextSize>,
    cacheIdentity: CacheIdentity?,
    sql: String,
    question: String?,
    preference: ResultPresentationPreference?,
    persistPreference: @escaping (ResultPresentationPreference) -> Void,
    initialSearchText: String,
    initialSelection: ResultCellSelection?,
    initialChartSelection: AutoChartSelection?
  ) {
    let analysis =
      cacheIdentity.map {
        ResultPreviewChartCache.analysis(
          messageID: $0.messageID,
          resultFingerprint: $0.resultFingerprint,
          result: result,
          sql: sql,
          question: question)
      } ?? ResultChartAnalysis(result: result, sql: sql, question: question)
    let recommendations = analysis.recommendations
    let selectedID = CREGChartAdapter.resolvedRecommendation(
      preferredID: preference?.specificationID,
      in: recommendations)?.id
    self.result = result
    self.runtimeMode = runtimeMode
    self.chartTable = analysis.table
    self.chartRecommendations = recommendations
    self.persistPreference = persistPreference
    self._textSize = textSize
    self._searchText = State(initialValue: initialSearchText)
    self._selectedCell = State(initialValue: initialSelection)
    self._resultMode = State(
      initialValue: recommendations.isEmpty ? .table : preference?.mode ?? .chart)
    self._selectedSpecificationID = State(initialValue: selectedID)
    self._chartSelection = State(initialValue: initialChartSelection)
  }

  func columnWidths() -> [CGFloat] {
    let scale = textSize.metricScale
    return ResultTableColumnMetrics(
      characterWidth: baseCharacterWidth * scale,
      horizontalPadding: baseHorizontalPadding * scale,
      minimumWidth: baseMinimumWidth * scale,
      maximumWidth: baseMaximumWidth * scale
    ).widths(for: result)
  }

  var cellHorizontalPadding: CGFloat {
    baseHorizontalPadding * textSize.metricScale
  }

  var rowVerticalPadding: CGFloat {
    baseRowVerticalPadding * textSize.metricScale
  }

  var normalizedSearchText: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var searchIsActive: Bool {
    !normalizedSearchText.isEmpty
  }

  var selectedRecommendation: AutoChartRecommendation? {
    if let selectedSpecificationID,
      let recommendation = chartRecommendations.first(where: {
        $0.id == selectedSpecificationID
      })
    {
      return recommendation
    }
    return chartRecommendations.first
  }

  var filteredResult: QueryResult {
    guard let indexes = chartTable.sourceRowIndexes(for: chartSelection) else {
      return result
    }
    return QueryResult(
      columns: result.columns,
      rows: result.rows.enumerated().compactMap { index, row in
        indexes.contains(index) ? row : nil
      },
      isTruncated: result.isTruncated,
      elapsedMicroseconds: result.elapsedMicroseconds)
  }

  func selectedResultCell(
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
    NavigationStack {
      VStack(spacing: 0) {
        if !chartRecommendations.isEmpty {
          Picker("Result view", selection: $resultMode) {
            Label("Chart", systemImage: "chart.xyaxis.line")
              .tag(ResultPresentationPreference.Mode.chart)
            Label("Table", systemImage: "tablecells")
              .tag(ResultPresentationPreference.Mode.table)
          }
          .pickerStyle(.segmented)
          .padding(.horizontal)
          .padding(.vertical, 8)
          .accessibilityIdentifier("result-view-mode")
        }

        if resultMode == .chart, let selectedRecommendation {
          ScrollView {
            AutoChartView(
              table: chartTable,
              recommendation: selectedRecommendation,
              selection: $chartSelection,
              interaction: .explore,
              height: 360
            )
            .padding()
            if let reason = selectedRecommendation.rationale.first {
              Label(reason, systemImage: "lightbulb")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .accessibilityIdentifier("result-chart-explorer")
        } else {
          let tableResult = filteredResult
          let displayRows = ResultViewerLogic.displayRows(
            result: tableResult, sort: sort, searchText: searchText)
          let widths = columnWidths()
          let selectedResultCell = selectedResultCell(in: displayRows)
          searchable(
            VStack(spacing: 0) {
              table(displayRows: displayRows, widths: widths)
              if let selectedResultCell {
                selectionAccessory(selectedResultCell)
              }
              footer(
                displayedRowCount: displayRows.count,
                sourceResult: tableResult,
                selectionIsActive: chartSelection != nil)
            }
          )
          .accessibilityIdentifier("result-table-explorer")
        }
      }
      .navigationTitle("Result")
      .inlineNavigationTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItemGroup(placement: .primaryAction) {
          if resultMode == .chart, chartRecommendations.count > 1 {
            chartTypeMenu
          }
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
    .onChange(of: chartSelection) { _, _ in
      selectedCell = nil
    }
    .onChange(of: resultMode) { _, mode in
      persistPreference(
        ResultPresentationPreference(
          mode: mode,
          specificationID: selectedRecommendation?.id))
    }
    .onChange(of: selectedSpecificationID) { _, id in
      chartSelection = nil
      persistPreference(
        ResultPresentationPreference(mode: .chart, specificationID: id))
    }
  }


}
