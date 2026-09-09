import AutoTableCharts
import AutoTableChartsUI
import CREGEngine
import ComposableArchitecture
import SwiftUI

/// The four-row result preview. It owns a session independent from the viewer,
/// while both sessions share the package cache supplied by the dependency.
struct ResultPreviewView: View {
  let messageID: UUID
  let resultFingerprint: String
  let result: QueryResult
  let sql: String
  let question: String?
  let preference: ResultPresentationPreference?
  let setPreference: (ResultPresentationPreference) -> Void
  let migratePreference: ResultPresentationMigrationHandler
  let open: () -> Void

  static let previewRowLimit = 4
  let chartInputIdentity: CREGChartInputIdentity
  @Dependency(\.chartAnalysis) private var chartAnalysis
  @Dependency(\.diagnostics) private var diagnostics
  @StateObject private var chartOwner: CREGChartSessionOwner
  @State private var pinchMagnification: CGFloat = 1
  @State private var pinchIsArmed = false
  @State private var pinchHapticTrigger = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  init(
    messageID: UUID,
    resultFingerprint: String,
    result: QueryResult,
    sql: String,
    question: String?,
    preference: ResultPresentationPreference?,
    setPreference: @escaping (ResultPresentationPreference) -> Void,
    migratePreference: @escaping ResultPresentationMigrationHandler,
    open: @escaping () -> Void
  ) {
    self.messageID = messageID
    self.resultFingerprint = resultFingerprint
    self.result = result
    self.sql = sql
    self.question = question
    self.preference = preference
    self.setPreference = setPreference
    self.migratePreference = migratePreference
    self.open = open
    let inputIdentity = CREGChartInputIdentity(
      resultFingerprint: resultFingerprint,
      dataIdentity: CREGChartAdapter.resultDataIdentity(messageID: messageID),
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

  private var session: AutoChartSession<Int> {
    chartOwner.session
  }

  private var analysis: AutoChartAnalysis<Int>? {
    chartOwner.analysis(for: chartInputIdentity)
  }

  private var failure: AutoChartFailure? {
    chartOwner.failure(for: chartInputIdentity)
  }

  private var renderedScale: CGFloat {
    reduceMotion ? 1 : ResultViewerLogic.previewScale(for: pinchMagnification)
  }

  var body: some View {
    if result.rows.isEmpty {
      Text("No matching rows.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(10)
    } else {
      let analysis = self.analysis
      let currentPreference = preference ?? .automatic
      let preferenceResolution = analysis?.resolve(currentPreference.packagePreference)
      let selectedRecommendation = preferenceResolution?.recommendation
      let failure = self.failure
      let hasChartOptions: Bool = {
        guard let analysis, case .charts(let catalog) = analysis.outcome else { return false }
        return !catalog.cataloged.isEmpty
      }()
      let migrationSuggestion = resultPresentationMigrationSuggestion(
        analysis: analysis,
        preference: currentPreference,
        resolution: preferenceResolution)
      let effectiveResultMode = ResultViewerLogic.effectivePresentationMode(
        requestedMode: currentPreference.mode,
        hasChart: selectedRecommendation != nil,
        chartFailed: failure != nil)
      let selected = selectedRecommendation
      VStack(alignment: .leading, spacing: 8) {
        if hasChartOptions || failure?.isRetryable == true {
          Picker(
            "Result preview",
            selection: Binding(
              get: { effectiveResultMode },
              set: { selectMode($0) })
          ) {
            Label("Chart", systemImage: "chart.xyaxis.line")
              .tag(ResultPresentationMode.chart)
            Label("Table", systemImage: "tablecells")
              .tag(ResultPresentationMode.table)
          }
          .pickerStyle(.segmented)
          .accessibilityIdentifier("result-preview-mode")
        }

        if let failure, currentPreference.mode == .chart {
          ResultChartRecoveryControls(
            spacing: 10,
            keepTable: { selectMode(.table) },
            retryChart: failure.isRetryable ? { session.retry() } : nil)
            .accessibilityIdentifier("result-preview-chart-recovery")
        }

        Button(action: open) {
          VStack(alignment: .leading, spacing: 6) {
            if effectiveResultMode == .chart, let selected {
              chartArea(recommendation: selected)
            } else {
              tablePreview
            }
            HStack(spacing: 6) {
              Text(ResultViewerLogic.rowCountLabel(for: result))
                .font(.caption2)
                .foregroundStyle(.tertiary)
              Spacer(minLength: 0)
              Label(
                pinchIsArmed ? "Release to expand" : "Explore result",
                systemImage: "arrow.up.left.and.arrow.down.right")
                .font(.caption2.weight(.medium))
                .foregroundStyle(CREGBrand.blue)
                .contentTransition(.symbolEffect(.replace))
            }
          }
          .padding(10)
          .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
          .overlay {
            RoundedRectangle(cornerRadius: 12)
              .stroke(CREGBrand.blue.opacity(pinchIsArmed ? 0.85 : 0), lineWidth: 2)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(renderedScale)
        .simultaneousGesture(pinchGesture)
        .sensoryFeedback(.selection, trigger: pinchHapticTrigger)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          "Result \(effectiveResultMode == .chart ? "chart" : "table"), \(ResultViewerLogic.rowCountLabel(for: result))")
        .accessibilityHint("Double-tap or pinch outward to open the result explorer")
      }
      .task(id: chartInputIdentity) {
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
      .task(id: failure?.episodeID) {
        guard let failure else { return }
        chartOwner.recordFailure(failure, diagnostics: diagnostics)
      }
      .task(id: migrationSuggestion) {
        guard let migrationSuggestion, let analysis else { return }
        applyResultPresentationMigration(
          migrationSuggestion,
          analysis: analysis,
          session: session,
          migratePreference: migratePreference)
      }
    }
  }

  @ViewBuilder
  private func chartArea(recommendation: AutoChartRecommendation) -> some View {
    if case .ready(let analysis, let presented?) = session.state {
      AutoChartView(
        presentedChart: presented,
        analysisID: analysis.id,
        presentation: .preview(plotHeight: ResultChartLayout.previewPlotHeight),
        formatters: CREGChartAdapter.formatters,
        textResolver: CREGChartAdapter.textResolver)
    } else {
      ResultChartPreparationView(
        recommendation: recommendation,
        presentation: .preview(plotHeight: ResultChartLayout.previewPlotHeight),
        formatters: CREGChartAdapter.formatters,
        textResolver: CREGChartAdapter.textResolver)
    }
  }

  private func selectMode(_ mode: ResultPresentationMode) {
    let currentPreference = preference ?? .automatic
    applyResultPresentationModeSelection(
      ResultViewerLogic.modeSelectionIntent(
        mode,
        requestedMode: currentPreference.mode,
        preserving: currentPreference.specificationID,
        retryAvailable: failure?.isRetryable == true),
      chartOwner: chartOwner,
      persistPreference: setPreference)
  }

  private var tablePreview: some View {
    ScrollView(.horizontal) {
      Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 6) {
        GridRow {
          ForEach(Array(result.columns.enumerated()), id: \.offset) { _, column in
            Text(column).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          }
        }
        Divider()
        ForEach(Array(result.rows.prefix(Self.previewRowLimit).enumerated()), id: \.offset) {
          _, row in
          GridRow {
            ForEach(Array(row.enumerated()), id: \.offset) { index, value in
              Text(
                ResultViewerLogic.displayedCopyValue(
                  value,
                  column: index < result.columns.count ? result.columns[index] : ""))
                .font(.caption.monospacedDigit())
            }
          }
        }
      }
      .fixedSize(horizontal: true, vertical: false)
    }
    .scrollIndicators(.visible)
  }

  private var pinchGesture: some Gesture {
    MagnifyGesture()
      .onChanged { value in
        let armed = ResultViewerLogic.pinchIsArmed(
          magnification: value.magnification, wasArmed: pinchIsArmed)
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
          pinchMagnification = value.magnification
          if armed && !pinchIsArmed { pinchHapticTrigger += 1 }
          pinchIsArmed = armed
        }
      }
      .onEnded { value in
        let shouldOpen = ResultViewerLogic.pinchIsArmed(
          magnification: value.magnification, wasArmed: pinchIsArmed)
        withAnimation(reduceMotion ? nil : .spring(duration: 0.24, bounce: 0.18)) {
          pinchMagnification = 1
          pinchIsArmed = false
        }
        if shouldOpen { open() }
      }
  }
}
