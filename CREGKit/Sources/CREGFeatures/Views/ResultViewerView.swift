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
  let chartInputIdentity: CREGChartInputIdentity
  @Dependency(\.chartAnalysis) private var chartAnalysis
  @Dependency(\.diagnostics) private var diagnostics
  @Binding var textSize: ResultTableTextSize
  @StateObject private var chartOwner: CREGChartSessionOwner
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
    let inputIdentity = CREGChartInputIdentity(
      resultFingerprint: fingerprint,
      dataIdentity: dataIdentity,
      sql: sql,
      question: question)
    let chartAnalysis = _chartAnalysis.wrappedValue
    self.chartInputIdentity = inputIdentity
    self._chartOwner = StateObject(
      wrappedValue: CREGChartSessionOwner(
        client: chartAnalysis,
        inputIdentity: inputIdentity,
        result: result))
  }

  var session: AutoChartSession<Int> {
    chartOwner.session
  }

  var analysis: AutoChartAnalysis<Int>? {
    guard chartOwner.inputIdentity == chartInputIdentity else { return nil }
    return switch session.state {
    case .preparing(let analysis, _), .ready(let analysis, _),
      .fallback(let analysis, _):
      analysis
    case .idle, .analyzing, .failed:
      chartOwner.request.flatMap { chartAnalysis.cachedAnalysis(for: $0) }
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
    guard let analysis else { return nil }
    return analysis.resolve(
      (preference ?? .automatic).packagePreference
    ).recommendation
  }

  var selectedChartFailure: AutoChartFailure? {
    guard chartOwner.inputIdentity == chartInputIdentity else { return nil }
    if case .failed(let failure) = session.state { return failure }
    return chartOwner.requestFailure
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
    guard chartOwner.inputIdentity == chartInputIdentity else { return nil }
    return session.selection.isEmpty ? nil : session.selection.unionedSourceRows
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

  var chartSelection: AutoChartSelection<Int>? {
    guard chartOwner.inputIdentity == chartInputIdentity else { return nil }
    return session.selection.first
  }

  var migrationSuggestion: ResultPresentationMigrationSuggestion? {
    resultPresentationMigrationSuggestion(
      analysis: analysis,
      preference: preference ?? .automatic)
  }

  func clearChartSelection() { session.selection.removeAll() }

  func selectTableRow(_ sourceRowID: Int?) {
    guard let sourceRowID else {
      initialChartSourceRows = nil
      clearChartSelection()
      return
    }
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
    @Bindable var session = chartOwner.session
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
    .task(id: chartInputIdentity) {
      if chartOwner.inputIdentity != chartInputIdentity {
        initialChartSourceRows = nil
        selectedCell = nil
      }
      chartOwner.load(
        result: result,
        inputIdentity: chartInputIdentity,
        preference: (preference ?? .automatic).packagePreference)
    }
    .onChange(of: preference) { _, updated in
      let packagePreference = (updated ?? .automatic).packagePreference
      if session.preference != packagePreference {
        session.setPreference(packagePreference)
      }
    }
    .onChange(of: chartSelection) { _, _ in
      guard let selectedCell, let selectedSourceRows,
        !selectedSourceRows.contains(selectedCell.row)
      else { return }
      self.selectedCell = nil
    }
    .task(id: selectedChartFailure?.episodeID) {
      guard let failure = selectedChartFailure else { return }
      recordChartFailure(
        failure,
        chartAnalysis: chartAnalysis,
        diagnostics: diagnostics)
    }
    .task(id: migrationSuggestion) {
      guard let migrationSuggestion, let analysis else { return }
      applyResultPresentationMigration(
        migrationSuggestion,
        analysis: analysis,
        session: session,
        migratePreference: migratePreference)
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
    guard chartOwner.inputIdentity == chartInputIdentity else { return nil }
    guard case .ready(_, let presented?) = session.state else { return nil }
    return presented.preparedChart.id
  }

  private func selectMode(_ mode: ResultPresentationMode) {
    let updated = (preference ?? .automatic).selectingMode(mode)
    applyUserPreference(updated)
  }

  func applyUserPreference(_ updated: ResultPresentationPreference) {
    if session.preference != updated.packagePreference {
      session.setPreference(updated.packagePreference)
    }
    persistPreference(updated)
  }
}
