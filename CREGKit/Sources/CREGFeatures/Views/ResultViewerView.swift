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
  let sql: String
  let question: String?
  let resultFingerprint: String
  let chartDataIdentity: String?
  let persistPreference: (ResultPresentationPreference) -> Void
  let chartRequest: ResultChartLoader.Request
  @Binding var textSize: ResultTableTextSize
  @State var chart: ResultChartLoader
  @State var sort: ResultViewerLogic.SortState?
  @State var searchText: String
  @State var selectedCell: ResultCellSelection?
  @State var resultMode: ResultPresentationPreference.Mode
  @State var selectedSpecificationID: AutoChartRecommendationID?
  @State var chartSelection: AutoChartSelection<Int>?
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
    initialChartSelection: AutoChartSelection<Int>? = nil
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
    initialChartSelection: AutoChartSelection<Int>? = nil
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
    initialChartSelection: AutoChartSelection<Int>?
  ) {
    self.result = result
    self.runtimeMode = runtimeMode
    self.sql = sql
    self.question = question
    let resultFingerprint =
      cacheIdentity?.resultFingerprint
      ?? PreparedFollowUpIntegrity.fingerprint(result: result)
    self.resultFingerprint = resultFingerprint
    let chartDataIdentity = cacheIdentity.map {
      CREGChartAdapter.resultDataIdentity(messageID: $0.messageID)
    }
    self.chartDataIdentity = chartDataIdentity
    self.persistPreference = persistPreference
    self._textSize = textSize
    self._searchText = State(initialValue: initialSearchText)
    self._selectedCell = State(initialValue: initialSelection)
    self._resultMode = State(
      initialValue: preference?.mode ?? .chart)
    self._selectedSpecificationID = State(initialValue: preference?.specificationID)
    self._chartSelection = State(initialValue: initialChartSelection)
    let request = ResultChartLoader.Request(
      result: result,
      sql: sql,
      question: question,
      resultFingerprint: resultFingerprint,
      dataIdentity: chartDataIdentity)
    self.chartRequest = request
    self._chart = State(
      initialValue: ResultChartLoader(
        client: Dependency(\.chartAnalysis).wrappedValue,
        warmStart: request,
        preferredSpecificationID: preference?.specificationID))
  }

  var chartRecommendations: [AutoChartRecommendation] {
    guard let analysis = chart.analysis,
      case .charts(let recommendations) = analysis.outcome
    else {
      return []
    }
    return recommendations
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
    guard let analysis = chart.analysis else { return nil }
    switch analysis.resolve(selectedSpecificationID) {
    case .exact(let recommendation), .defaulted(let recommendation, _):
      return recommendation
    case .unavailable:
      return nil
    }
  }

  var filteredResult: QueryResult {
    guard let indexes = chartSelection?.sourceRowIDs else {
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
          // Persistence rides the binding's setter, not an onChange handler:
          // only the user's own tap may write the stored preference, never a
          // programmatic mode flip from the analysis or preparation tasks.
          Picker(
            "Result view",
            selection: Binding(
              get: { resultMode },
              set: { mode in
                guard mode != resultMode else { return }
                resultMode = mode
                persistPreference(
                  ResultPresentationPreference(
                    mode: mode,
                    specificationID: selectedRecommendation?.id))
              })
          ) {
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

        if resultMode == .chart, let selectedRecommendation,
          !chart.preparationFailed
        {
          ScrollView {
            if let preparedChart = chart.preparedChart {
              AutoChartView(
                preparedChart: preparedChart,
                selection: $chartSelection,
                presentation: .explorer(plotHeight: 360),
                formatters: CREGChartAdapter.formatters
              )
              .padding()
            } else {
              ProgressView("Preparing chart")
                .frame(maxWidth: .infinity)
                .frame(height: 360)
                .padding()
            }
            if let reason = selectedRecommendation.rationale.first {
              Label(reason.defaultText, systemImage: "lightbulb")
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
    .task(id: chartRequest.key) {
      switch await chart.analyze(
        chartRequest, preferredSpecificationID: selectedSpecificationID)
      {
      case .resolved(let recommendation)?:
        // Programmatic selection of the resolved recommendation; only a
        // user's own pick in `chartTypeMenu` persists a preference.
        selectedSpecificationID = recommendation.id
      case .unavailable?:
        resultMode = .table
        selectedSpecificationID = nil
      case nil:
        break
      }
    }
    .task(id: selectedRecommendation?.id) {
      // The initial chart selection (deep links, the preview harness) must
      // survive this task's first run; a user switching chart types clears
      // it in `chartTypeMenu` where the stale row indexes actually die.
      guard await chart.prepareSelected(selectedRecommendation) else {
        resultMode = .table
        return
      }
    }
  }


}
