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
  let migratePreference: ResultPresentationMigrationHandler
  let chartRequest: ResultChartLoader.Request
  @Dependency(\.chartAnalysis) private var chartAnalysis
  @Binding var textSize: ResultTableTextSize
  @State var chart: ResultChartLoader
  @State var sort: ResultViewerLogic.SortState?
  @State var searchText: String
  @State var selectedCell: ResultCellSelection?
  @State var presentationPreference: ResultPresentationPreference
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
  /// a transcript message. Automatic migrations remain local because there is
  /// no authoritative store to update.
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
      migratePreference: { _, updated in .retained(updated) },
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
    let resultFingerprint =
      cacheIdentity?.resultFingerprint
      ?? PreparedFollowUpIntegrity.fingerprint(result: result)
    self.resultFingerprint = resultFingerprint
    let chartDataIdentity = cacheIdentity.map {
      CREGChartAdapter.resultDataIdentity(messageID: $0.messageID)
    }
    self.chartDataIdentity = chartDataIdentity
    self.persistPreference = persistPreference
    self.migratePreference = migratePreference
    self._textSize = textSize
    self._searchText = State(initialValue: initialSearchText)
    self._selectedCell = State(initialValue: initialSelection)
    self._presentationPreference = State(
      initialValue: preference ?? ResultPresentationPreference(mode: .chart))
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
        client: _chartAnalysis.wrappedValue,
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

  var effectiveResultMode: ResultPresentationPreference.Mode {
    ResultViewerLogic.effectivePresentationMode(
      requestedMode: presentationPreference.mode,
      hasChart: selectedRecommendation != nil,
      preparationFailed: chart.preparationFailed)
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
          // Requested-mode persistence rides the binding's setter. Analysis
          // migrations use their separate compare-and-set callback below.
          Picker(
            "Result view",
            selection: Binding(
              get: { effectiveResultMode },
              set: { selectedMode in
                selectMode(selectedMode)
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

        if chart.preparationFailed,
          presentationPreference.mode == .chart
        {
          ResultChartRecoveryControls(
            spacing: 12,
            keepTable: { selectMode(.table) },
            retryChart: { selectMode(.chart) }
          )
          .padding(.horizontal)
          .padding(.bottom, 8)
          .accessibilityIdentifier("result-chart-recovery")
        }

        if effectiveResultMode == .chart, let selectedRecommendation {
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
          if chartRecommendations.count > 1,
            presentationPreference.mode == .chart || chart.preparationFailed {
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
      guard
        let update = await analyzeResultPresentation(
          chart,
          request: chartRequest,
          preference: presentationPreference,
          migratePreference: migratePreference
        )
      else { return }

      if update.invalidatesChartSelection(chartSelection) {
        chartSelection = nil
      }
      selectedSpecificationID = update.resolvedSpecificationID
      if case .retained(let authoritativePreference) = update.preferenceReconciliation {
        presentationPreference =
          authoritativePreference ?? ResultPresentationPreference(mode: .chart)
      }
    }
    .task(
      id: chart.preparationTaskKey(
        recommendationID: selectedRecommendation?.id)
    ) {
      // Analysis reconciliation and chart-type changes own selection
      // invalidation. Preparation preserves a matching initial selection from
      // deep links and the preview harness.
      await chart.prepareSelected(selectedRecommendation)
    }
  }

  private func selectMode(_ selectedMode: ResultPresentationPreference.Mode) {
    switch ResultViewerLogic.modeSelectionIntent(
      selectedMode,
      requestedMode: presentationPreference.mode,
      preserving: presentationPreference.specificationID,
      preparationFailed: chart.preparationFailed
    ) {
    case .none:
      break
    case .persist(let updated):
      presentationPreference = updated
      persistPreference(updated)
    case .retryChart(let updated):
      chart.retryPreparation()
      if let updated {
        presentationPreference = updated
        persistPreference(updated)
      }
    }
  }
}
