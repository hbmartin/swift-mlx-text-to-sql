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
  @Dependency(\.chartAnalysis) var chartAnalysisClient
  @Binding var textSize: ResultTableTextSize
  @State var sort: ResultViewerLogic.SortState?
  @State var searchText: String
  @State var selectedCell: ResultCellSelection?
  @State var resultMode: ResultPresentationPreference.Mode
  @State var selectedSpecificationID: AutoChartRecommendationID?
  @State var chartSelection: AutoChartSelection<Int>?
  @State var chartAnalysis: AutoChartAnalysis<Int>?
  @State var preparedChart: AutoChartPreparedChart<Int>?
  @State var chartPreparationFailed = false
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
    self.resultFingerprint = cacheIdentity?.resultFingerprint
      ?? PreparedFollowUpIntegrity.fingerprint(result: result)
    self.chartDataIdentity = cacheIdentity.map {
      "CREG.Result.v2:\($0.messageID.uuidString.lowercased())"
    }
    self.persistPreference = persistPreference
    self._textSize = textSize
    self._searchText = State(initialValue: initialSearchText)
    self._selectedCell = State(initialValue: initialSelection)
    self._resultMode = State(
      initialValue: preference?.mode ?? .chart)
    self._selectedSpecificationID = State(initialValue: preference?.specificationID)
    self._chartSelection = State(initialValue: initialChartSelection)
  }

  var chartRecommendations: [AutoChartRecommendation] {
    guard let chartAnalysis, case .charts(let recommendations) = chartAnalysis.outcome else {
      return []
    }
    return recommendations
  }

  var analysisTaskID: String {
    [resultFingerprint, chartDataIdentity ?? "", sql, question ?? ""].joined(separator: "|")
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
    guard let chartAnalysis else { return nil }
    switch chartAnalysis.resolve(selectedSpecificationID) {
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
            if let preparedChart {
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
    .onChange(of: resultMode) { _, mode in
      persistPreference(
        ResultPresentationPreference(
          mode: mode,
          specificationID: selectedRecommendation?.id))
    }
    .onChange(of: selectedSpecificationID) { _, id in
      chartSelection = nil
      persistPreference(
        ResultPresentationPreference(mode: resultMode, specificationID: id))
    }
    .task(id: analysisTaskID) {
      chartAnalysis = nil
      preparedChart = nil
      chartPreparationFailed = false
      do {
        let analysis = try await chartAnalysisClient.analyze(
          result: result,
          sql: sql,
          question: question,
          resultFingerprint: resultFingerprint,
          dataIdentity: chartDataIdentity)
        chartAnalysis = analysis
        switch analysis.resolve(selectedSpecificationID) {
        case .exact(let recommendation), .defaulted(let recommendation, _):
          preparedChart = analysis.primaryChart?.recommendation.id == recommendation.id
            ? analysis.primaryChart : nil
          selectedSpecificationID = recommendation.id
        case .unavailable:
          resultMode = .table
          selectedSpecificationID = nil
        }
      } catch is CancellationError {
        return
      } catch {
        chartAnalysis = nil
      }
    }
    .task(id: selectedRecommendation?.id) {
      chartSelection = nil
      chartPreparationFailed = false
      guard let chartAnalysis, let selectedRecommendation else {
        preparedChart = nil
        return
      }
      if chartAnalysis.primaryChart?.recommendation.id == selectedRecommendation.id {
        preparedChart = chartAnalysis.primaryChart
        return
      }
      preparedChart = nil
      do {
        preparedChart = try await chartAnalysis.prepare(selectedRecommendation.id)
      } catch is CancellationError {
        return
      } catch {
        chartPreparationFailed = true
        resultMode = .table
      }
    }
  }


}
