import AutoTableCharts
import AutoTableChartsUI
import CREGEngine
import ComposableArchitecture
import SwiftUI

/// Full-screen chart/table explorer. Export always uses the complete result;
/// chart selection filters only the displayed table rows.
struct ResultViewerView: View {
  let result: QueryResult
  let runtimeMode: ModelRuntimeMode
  let sql: String
  let question: String?
  let resultFingerprint: String
  let chartDataIdentity: String?
  let preference: ResultPresentationPreference?
  let persistPreference: (ResultPresentationPreference) -> Void
  let migratePreference: ResultPresentationMigrationHandler
  let chartRequest: AutoChartRequest<Int>
  @Dependency(\.chartAnalysis) private var chartAnalysis
  @Dependency(\.diagnostics) private var diagnostics
  @Binding var textSize: ResultTableTextSize
  @State var session: AutoChartSession<Int>
  @State private var initialChartSourceRows: Set<Int>?
  @State var sort: ResultViewerLogic.SortState?
  @State var searchText: String
  @State var selectedCell: ResultCellSelection?
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
      migratePreference: { _, updated in .migrated(updated) },
      initialSearchText: initialSearchText,
      initialSelection: initialSelection,
      initialChartSelection: initialChartSelection)
  }

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
    migratePreference: @escaping ResultPresentationMigrationHandler,
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
      migratePreference: migratePreference,
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
    migratePreference: @escaping ResultPresentationMigrationHandler,
    initialSearchText: String,
    initialSelection: ResultCellSelection?,
    initialChartSelection: AutoChartSelection<Int>?
  ) {
    self.result = result
    self.runtimeMode = runtimeMode
    self.sql = sql
    self.question = question
    let fingerprint = cacheIdentity?.resultFingerprint
      ?? PreparedFollowUpIntegrity.fingerprint(result: result)
    self.resultFingerprint = fingerprint
    let dataIdentity = cacheIdentity.map {
      CREGChartAdapter.resultDataIdentity(messageID: $0.messageID)
    }
    self.chartDataIdentity = dataIdentity
    self.preference = preference
    self.persistPreference = persistPreference
    self.migratePreference = migratePreference
    self._textSize = textSize
    self._searchText = State(initialValue: initialSearchText)
    self._selectedCell = State(initialValue: initialSelection)
    self._initialChartSourceRows = State(
      initialValue: initialChartSelection?.sourceRowIDs)
    let input = try! CREGChartAdapter.analysisInput(
      result: result,
      sql: sql,
      question: question,
      resultFingerprint: fingerprint,
      dataIdentity: dataIdentity)
    self.chartRequest = input.request
    self._session = State(initialValue: _chartAnalysis.wrappedValue.makeSession())
  }

  var analysis: AutoChartAnalysis<Int>? {
    switch session.state {
    case .preparing(let analysis, _), .ready(let analysis, _),
      .fallback(let analysis, _):
      analysis
    case .idle, .analyzing, .failed:
      nil
    }
  }

  var chartRecommendations: [AutoChartRecommendation] {
    guard let analysis, case .charts(let catalog) = analysis.outcome else { return [] }
    return catalog.cataloged
  }

  var chartPickerOptions: [AutoChartPickerOption] {
    guard let analysis, case .charts(let catalog) = analysis.outcome else { return [] }
    return catalog.pickerOptions(resolver: CREGChartAdapter.textResolver)
  }

  var selectedRecommendation: AutoChartRecommendation? {
    analysis?.preferenceResolution?.recommendation
  }

  var selectedChartFailure: AutoChartFailure? {
    guard case .failed(let failure) = session.state else { return nil }
    return failure
  }

  var selectedPreparationFailed: Bool {
    selectedChartFailure?.stage == .chartPreparation
  }

  var requestedMode: ResultPresentationMode {
    (preference ?? .automatic).mode
  }

  var effectiveResultMode: ResultPresentationMode {
    ResultViewerLogic.effectivePresentationMode(
      requestedMode: requestedMode,
      hasChart: selectedRecommendation != nil,
      preparationFailed: selectedPreparationFailed)
  }

  var selectedSourceRows: Set<Int>? {
    session.selection.isEmpty ? nil : session.selection.unionedSourceRows
  }

  var filteredResult: QueryResult {
    guard let selectedSourceRows else { return result }
    return QueryResult(
      columns: result.columns,
      rows: result.rows.enumerated().compactMap { index, row in
        selectedSourceRows.contains(index) ? row : nil
      },
      isTruncated: result.isTruncated,
      elapsedMicroseconds: result.elapsedMicroseconds)
  }

  var chartSelection: AutoChartSelection<Int>? { session.selection.first }

  func clearChartSelection() { session.selection.removeAll() }

  func selectTableRow(_ sourceRowID: Int?) {
    guard let sourceRowID else {
      initialChartSourceRows = nil
      clearChartSelection()
      return
    }
    initialChartSourceRows = [sourceRowID]
    guard let analysis, case .ready(_, let presented?) = session.state else {
      clearChartSelection()
      return
    }
    session.selection = presented.preparedChart.selections(
      for: [sourceRowID], analysisID: analysis.id)
    initialChartSourceRows = nil
  }

  func columnWidths() -> [CGFloat] {
    ResultTableColumnMetrics(
      characterWidth: baseCharacterWidth * textSize.metricScale,
      horizontalPadding: baseHorizontalPadding * textSize.metricScale,
      minimumWidth: baseMinimumWidth * textSize.metricScale,
      maximumWidth: baseMaximumWidth * textSize.metricScale
    ).widths(for: result)
  }

  var cellHorizontalPadding: CGFloat { baseHorizontalPadding * textSize.metricScale }
  var rowVerticalPadding: CGFloat { baseRowVerticalPadding * textSize.metricScale }
  var normalizedSearchText: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  var searchIsActive: Bool { !normalizedSearchText.isEmpty }

  func selectedResultCell(
    in displayRows: [ResultViewerLogic.DisplayRow]
  ) -> SelectedResultCell? {
    guard let selectedCell,
      let displayRow = displayRows.first(where: { $0.sourceRowID == selectedCell.row }),
      result.columns.indices.contains(selectedCell.column)
    else { return nil }
    let value = displayRow.values.indices.contains(selectedCell.column)
      ? displayRow.values[selectedCell.column] : .null
    let columnName = result.columns[selectedCell.column]
    return SelectedResultCell(
      selection: selectedCell,
      row: displayRow.values,
      columnName: columnName,
      displayedValue: ResultViewerLogic.displayedCopyValue(value, column: columnName),
      rawValue: ResultViewerLogic.rawCopyValue(value))
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if !chartRecommendations.isEmpty || selectedChartFailure?.isRetryable == true {
          Picker(
            "Result view",
            selection: Binding(
              get: { effectiveResultMode },
              set: { mode in selectMode(mode) })
          ) {
            Label("Chart", systemImage: "chart.xyaxis.line")
              .tag(ResultPresentationMode.chart)
            Label("Table", systemImage: "tablecells")
              .tag(ResultPresentationMode.table)
          }
          .pickerStyle(.segmented)
          .padding(.horizontal)
          .padding(.vertical, 8)
          .accessibilityIdentifier("result-view-mode")
        }

        if let failure = selectedChartFailure, requestedMode == .chart {
          ResultChartRecoveryControls(
            spacing: 12,
            keepTable: { selectMode(.table) },
            retryChart: failure.isRetryable ? { session.retry() } : nil)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .accessibilityIdentifier("result-chart-recovery")
        }

        if effectiveResultMode == .chart,
          let analysis,
          let selectedRecommendation
        {
          ResultChartExplorerContainer(recommendation: selectedRecommendation) {
            if case .ready(_, let presented?) = session.state {
              AutoChartView(
                presentedChart: presented,
                analysisID: analysis.id,
                selection: $session.selection,
                presentation: .explorer(
                  plotHeight: ResultChartLayout.explorerPlotHeight),
                formatters: CREGChartAdapter.formatters,
                textResolver: CREGChartAdapter.textResolver)
            } else {
              ResultChartExplorerPreparationView(
                recommendation: selectedRecommendation,
                selection: chartSelection.map { selection in
                  ResultChartPreparationView.SelectionConfiguration(
                    value: selection,
                    columns: analysis.columnProfiles.map(\.column),
                    clear: clearChartSelection)
                })
            }
          }
        } else {
          let displayRows = ResultViewerLogic.identifiedDisplayRows(
            result: result,
            sourceRowIDs: selectedSourceRows,
            sort: sort,
            searchText: searchText)
          let selectedResultCell = selectedResultCell(in: displayRows)
          searchable(
            VStack(spacing: 0) {
              table(displayRows: displayRows, widths: columnWidths())
              if let selectedResultCell { selectionAccessory(selectedResultCell) }
              footer(
                displayedRowCount: displayRows.count,
                sourceResult: filteredResult,
                selectionIsActive: selectedSourceRows != nil)
            })
            .accessibilityIdentifier("result-table-explorer")
        }
      }
      .navigationTitle("Result")
      .inlineNavigationTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        ToolbarItemGroup(placement: .primaryAction) {
          if chartRecommendations.count > 1,
            requestedMode == .chart || selectedPreparationFailed
          {
            chartTypeMenu
          }
          textSizeMenu
          exportMenu
        }
      }
    }
    .task(id: chartRequest.id) {
      session.load(
        chartRequest,
        preference: preference ?? .automatic,
        preparation: .preferredOrPrimary,
        presentationContext: .init(identity: "creg-v3"),
        formatters: CREGChartAdapter.formatters,
        textResolver: CREGChartAdapter.textResolver)
    }
    .onChange(of: preference) { _, updated in
      session.setPreference(updated ?? .automatic)
    }
    .onChange(of: searchText) { _, _ in selectedCell = nil }
    .onChange(of: sort) { _, _ in selectedCell = nil }
    .onChange(of: chartSelection) { _, _ in selectedCell = nil }
    .onChange(of: selectedChartFailure?.episodeID) { _, episodeID in
      guard let failure = selectedChartFailure, episodeID != nil else { return }
      recordChartFailure(failure, diagnostics: diagnostics)
    }
    .onChange(of: analysis?.preferenceResolution?.replacementPreference) {
      _, replacement in
      guard let replacement else { return }
      _ = migratePreference(preference ?? .automatic, replacement)
    }
    .onChange(of: presentedPreparedChartID) { _, _ in
      guard let rows = initialChartSourceRows,
        let analysis,
        case .ready(_, let presented?) = session.state
      else { return }
      session.selection = presented.preparedChart.selections(
        for: rows, analysisID: analysis.id)
      initialChartSourceRows = nil
    }
  }

  private var presentedPreparedChartID: AutoChartPreparedChartID? {
    guard case .ready(_, let presented?) = session.state else { return nil }
    return presented.preparedChart.id
  }

  private func selectMode(_ mode: ResultPresentationMode) {
    let updated: AutoChartPreference = mode == .table ? .table : .chart(.recommended)
    applyUserPreference(updated)
  }

  func applyUserPreference(_ updated: ResultPresentationPreference) {
    session.setPreference(updated)
    persistPreference(updated)
  }
}
