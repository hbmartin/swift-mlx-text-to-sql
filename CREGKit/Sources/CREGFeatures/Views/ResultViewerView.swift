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
  @State private var chartSelectionLifecycle: ResultViewerLogic.ChartSelectionLifecycle
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
    initialChartSelection: AutoChartSelection<Int>? = nil,
    initialTableSelectionSourceRowID: Int? = nil
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
      initialChartSelection: initialChartSelection,
      initialTableSelectionSourceRowID: initialTableSelectionSourceRowID)
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
    initialChartSelection: AutoChartSelection<Int>? = nil,
    initialTableSelectionSourceRowID: Int? = nil
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
      initialChartSelection: initialChartSelection,
      initialTableSelectionSourceRowID: initialTableSelectionSourceRowID)
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
    initialChartSelection: AutoChartSelection<Int>?,
    initialTableSelectionSourceRowID: Int?
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
    self._chartSelectionLifecycle = State(
      initialValue: ResultViewerLogic.ChartSelectionLifecycle(
        initialChartSourceRows: initialChartSelection?.sourceRowIDs,
        initialTableSelectionSourceRowID: initialTableSelectionSourceRowID))
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
    chartOwner.analysis(for: chartInputIdentity)
  }

  var selectedChartFailure: AutoChartFailure? {
    chartOwner.failure(for: chartInputIdentity)
  }

  var selectedSourceRows: Set<Int>? {
    guard chartOwner.inputIdentity == chartInputIdentity else { return nil }
    return session.selection.isEmpty ? nil : session.selection.unionedSourceRows
  }

  var chartSelection: AutoChartSelection<Int>? {
    guard chartOwner.inputIdentity == chartInputIdentity else { return nil }
    return session.selection.first
  }

  var interactiveChartSelection: Binding<AutoChartSelectionSet<Int>> {
    Binding(
      get: { session.selection },
      set: { updated in
        guard updated != session.selection else { return }
        chartSelectionLifecycle.chartSelectionChanged(
          sourceRows: updated.unionedSourceRows)
        session.selection = updated
      })
  }

  func clearChartSelection() {
    chartSelectionLifecycle.clearChartSelection()
    session.selection.removeAll()
  }

  func selectTableRow(_ sourceRowID: Int?) {
    clearChartSelection()
    guard let sourceRowID else { return }
    chartSelectionLifecycle.selectTableRow(sourceRowID)
    guard let analysis, case .ready(_, let presented?) = session.state else {
      return
    }
    let selection = presented.preparedChart.selections(
      for: [sourceRowID], analysisID: analysis.id)
    session.selection = selection
    chartSelectionLifecycle.pendingSelectionApplied(
      sourceRows: selection.unionedSourceRows)
  }

  func clearSelectedCellIfHiddenBySearch() {
    guard let selectedCell else { return }
    let row = result.rows.indices.contains(selectedCell.row)
      ? result.rows[selectedCell.row] : nil
    let invalidation = ResultViewerLogic.searchSelectionInvalidation(
      row: row,
      sourceRowID: selectedCell.row,
      searchText: searchText,
      tableSelectionSourceRowID:
        chartSelectionLifecycle.tableSelectionSourceRowID)
    switch invalidation {
    case .keep:
      return
    case .clearCell:
      self.selectedCell = nil
      chartSelectionLifecycle.clearTableSelectionLink()
    case .clearCellAndLinkedChartSelection:
      self.selectedCell = nil
      clearChartSelection()
    }
  }

  func clearSelectedCellIfExcludedByChartSelection(
    _ selectedSourceRows: Set<Int>?
  ) {
    guard let selectedCell, let selectedSourceRows,
      !selectedSourceRows.contains(selectedCell.row)
    else { return }
    self.selectedCell = nil
    chartSelectionLifecycle.clearTableSelectionLink()
  }

  func chartPickerOptions(
    for analysis: AutoChartAnalysis<Int>?
  ) -> [AutoChartPickerOption] {
    analysis?.cregRecommendationCatalog?.pickerOptions(
      resolver: CREGChartAdapter.textResolver) ?? []
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
    let session = chartOwner.session
    let analysis = self.analysis
    let currentPreference = preference ?? .automatic
    let preferenceResolution = analysis?.resolve(currentPreference.packagePreference)
    let selectedRecommendation = preferenceResolution?.recommendation
    let chartRecommendations = analysis?.cregRecommendationCatalog?.cataloged ?? []
    let selectedChartFailure = self.selectedChartFailure
    let effectiveResultMode = ResultViewerLogic.effectivePresentationMode(
      requestedMode: currentPreference.mode,
      hasChart: selectedRecommendation != nil,
      chartFailed: selectedChartFailure != nil)
    let chartSelection = self.chartSelection
    let selectedSourceRows = self.selectedSourceRows
    let selectedRowCount = selectedSourceRows.map { sourceRows in
      sourceRows.lazy.filter { result.rows.indices.contains($0) }.count
    } ?? result.rowCount
    let migrationSuggestion = resultPresentationMigrationSuggestion(
      analysis: analysis,
      preference: currentPreference,
      resolution: preferenceResolution)

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

        if let failure = selectedChartFailure, currentPreference.mode == .chart {
          ResultChartRecoveryControls(
            spacing: 12,
            keepTable: { selectMode(.table) },
            retryChart: failure.isRetryable ? { retryChart() } : nil
          )
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
                selection: interactiveChartSelection,
                presentation: .explorer(
                  plotHeight: ResultChartLayout.explorerPlotHeight),
                formatters: CREGChartAdapter.formatters,
                textResolver: CREGChartAdapter.textResolver
              )
              .id(
                PresentedChartIdentity(
                  analysisID: analysis.id,
                  preparedChartID: presented.preparedChart.id))
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
                selectedRowCount: selectedRowCount,
                selectionIsActive: selectedSourceRows != nil)
            }
          )
          .accessibilityIdentifier("result-table-explorer")
        }
      }
      .navigationTitle("Result")
      .inlineNavigationTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        ToolbarItemGroup(placement: .primaryAction) {
          if chartRecommendations.count > 1,
            currentPreference.mode == .chart || selectedChartFailure != nil
          {
            chartTypeMenu(
              selectedRecommendation: selectedRecommendation,
              options: chartPickerOptions(for: analysis))
          }
          textSizeMenu
          exportMenu
        }
      }
    }
    .task(id: chartInputIdentity) {
      if chartOwner.inputIdentity != chartInputIdentity {
        chartSelectionLifecycle.clearChartSelection()
        selectedCell = nil
      }
      chartOwner.load(
        result: result,
        inputIdentity: chartInputIdentity,
        preference: (preference ?? .automatic).packagePreference,
        beforeRestart: prepareChartSelectionForSessionRestart)
    }
    .onChange(of: preference) { _, updated in
      chartOwner.setPreferenceIfNeeded(
        (updated ?? .automatic).packagePreference,
        beforeRestart: prepareChartSelectionForSessionRestart)
    }
    .onChange(of: searchText) { _, _ in
      guard effectiveResultMode == .table else { return }
      clearSelectedCellIfHiddenBySearch()
    }
    .onChange(of: selectedSourceRows) { _, updated in
      clearSelectedCellIfExcludedByChartSelection(updated)
    }
    .onChange(of: effectiveResultMode) { _, mode in
      guard mode == .table else { return }
      clearSelectedCellIfHiddenBySearch()
    }
    .task(id: selectedChartFailure?.episodeID) {
      guard let failure = selectedChartFailure else { return }
      chartOwner.recordFailure(failure, diagnostics: diagnostics)
    }
    .task(id: migrationSuggestion) {
      guard let migrationSuggestion, let analysis else { return }
      applyResultPresentationMigration(
        migrationSuggestion,
        analysis: analysis,
        chartOwner: chartOwner,
        beforeSessionRestart: prepareChartSelectionForSessionRestart,
        migratePreference: migratePreference)
    }
    .task(id: presentedChartRestorationID) {
      guard let rows = chartSelectionLifecycle.pendingSourceRows,
        let analysis,
        case .ready(_, let presented?) = session.state
      else { return }
      let selection = presented.preparedChart.selections(
        for: rows, analysisID: analysis.id)
      session.selection = selection
      chartSelectionLifecycle.pendingSelectionApplied(
        sourceRows: selection.unionedSourceRows)
    }
  }

  private struct PresentedChartIdentity: Hashable {
    var analysisID: AutoChartAnalysisID
    var preparedChartID: AutoChartPreparedChartID
  }

  private struct PresentedChartRestorationID: Hashable {
    var presentationAttempt: UInt64
    var chart: PresentedChartIdentity
  }

  private var presentedChartRestorationID: PresentedChartRestorationID? {
    guard chartOwner.inputIdentity == chartInputIdentity else { return nil }
    guard case .ready(_, let presented?) = session.state else { return nil }
    guard let analysis else { return nil }
    return PresentedChartRestorationID(
      presentationAttempt: chartOwner.selectionRestorationAttempt,
      chart: PresentedChartIdentity(
        analysisID: analysis.id,
        preparedChartID: presented.preparedChart.id))
  }

  private func prepareChartSelectionForSessionRestart() {
    chartSelectionLifecycle.prepareForSessionRestart()
  }

  private func retryChart() {
    chartOwner.retry(beforeRestart: prepareChartSelectionForSessionRestart)
  }

  private func selectMode(_ mode: ResultPresentationMode) {
    let currentPreference = preference ?? .automatic
    applyResultPresentationModeSelection(
      ResultViewerLogic.modeSelectionIntent(
        mode,
        requestedMode: currentPreference.mode,
        preserving: currentPreference.specificationID,
        retryAvailable: selectedChartFailure?.isRetryable == true),
      chartOwner: chartOwner,
      persistPreference: persistPreference,
      beforeSessionRestart: prepareChartSelectionForSessionRestart)
  }

  func applyUserPreference(_ updated: ResultPresentationPreference) {
    applyResultPresentationPreference(
      updated,
      chartOwner: chartOwner,
      persistPreference: persistPreference,
      beforeSessionRestart: prepareChartSelectionForSessionRestart)
  }
}
