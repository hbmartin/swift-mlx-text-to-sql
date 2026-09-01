import AutoTableCharts
import CREGEngine
import ComposableArchitecture
import SwiftUI

/// The four-row Result Preview shown inline in the transcript; tapping it
/// opens the full-screen Result Viewer.
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
  let chartRequest: ResultChartLoader.Request
  @Dependency(\.chartAnalysis) private var chartAnalysis
  @Dependency(\.diagnostics) private var diagnostics
  @State private var chartOwner: ResultChartLoaderOwner
  @State private var presentationState: ResultPresentationState
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
    let request = ResultChartLoader.Request(
      result: result,
      sql: sql,
      question: question,
      resultFingerprint: resultFingerprint,
      dataIdentity: CREGChartAdapter.resultDataIdentity(messageID: messageID))
    self.chartRequest = request
    self._chartOwner = State(
      initialValue: ResultChartLoaderOwner(
        client: _chartAnalysis.wrappedValue))
    self._presentationState = State(
      initialValue: ResultPresentationState(
        preference: preference,
        requestKey: request.key))
  }

  private var chart: ResultChartLoader {
    chartOwner.loader(
      warmStart: chartRequest,
      preferredSpecificationID: preference?.specificationID)
  }

  private var renderedScale: CGFloat {
    reduceMotion
      ? 1
      : ResultViewerLogic.previewScale(for: pinchMagnification)
  }

  private var selectedRecommendation: AutoChartRecommendation? {
    chart.resolvedRecommendation(for: chartRequest.key)
  }

  private var selectedChartFailure: ResultChartLoader.Failure? {
    chart.failure(
      for: chartRequest.key,
      recommendationID: selectedRecommendation?.id)
  }

  private var requestedMode: ResultPresentationPreference.Mode {
    presentationState.requestedMode(
      authoritativePreference: preference,
      requestKey: chartRequest.key)
  }

  var body: some View {
    if result.rows.isEmpty {
      Text("No matching rows.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(10)
    } else {
      let selected = selectedRecommendation
      let mode = effectiveMode(hasChart: selected != nil)
      VStack(alignment: .leading, spacing: 8) {
        if selected != nil
          || selectedChartFailure?.retryability == .retryable
        {
          Picker(
            "Result preview",
            selection: Binding(
              get: { effectiveMode(hasChart: selected != nil) },
              set: { selectMode($0) })
          ) {
            Label("Chart", systemImage: "chart.xyaxis.line")
              .tag(ResultPresentationPreference.Mode.chart)
            Label("Table", systemImage: "tablecells")
              .tag(ResultPresentationPreference.Mode.table)
          }
          .pickerStyle(.segmented)
          .accessibilityIdentifier("result-preview-mode")
        }

        if let selectedChartFailure,
          requestedMode == .chart
        {
          ResultChartRecoveryControls(
            spacing: 10,
            keepTable: { selectMode(.table) },
            retryChart:
              selectedChartFailure.retryability == .retryable
              ? { selectMode(.chart) } : nil
          )
          .accessibilityIdentifier("result-preview-chart-recovery")
        }

        Button(action: open) {
          VStack(alignment: .leading, spacing: 6) {
            if mode == .chart, let selected {
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
          "Result \(mode == .chart ? "chart" : "table"), \(ResultViewerLogic.rowCountLabel(for: result))"
        )
        .accessibilityHint("Double-tap or pinch outward to open the result explorer")
      }
      .resultPresentationLifecycle(
        chart: chart,
        request: chartRequest,
        authoritativePreference: preference,
        presentationState: $presentationState,
        migratePreference: migratePreference,
        diagnostics: diagnostics
      )
      .task(
        id: chart.preparationTaskKey(
          recommendationID: selected?.id)
      ) {
        await chart.prepareResolvedRecommendation(for: chartRequest.key)
      }
    }
  }

  @ViewBuilder
  private func chartArea(
    recommendation: AutoChartRecommendation
  ) -> some View {
    if let preparedChart = chart.matchingPreparedChart(for: recommendation.id) {
      AutoChartView(
        preparedChart: preparedChart,
        presentation: .preview(
          plotHeight: ResultChartLayout.previewPlotHeight),
        formatters: CREGChartAdapter.formatters,
        textResolver: CREGChartAdapter.textResolver)
    } else {
      ResultChartPreparationView(
        recommendation: recommendation,
        presentation: .preview(
          plotHeight: ResultChartLayout.previewPlotHeight),
        formatters: CREGChartAdapter.formatters,
        textResolver: CREGChartAdapter.textResolver)
    }
  }

  private func effectiveMode(hasChart: Bool) -> ResultPresentationPreference.Mode {
    ResultViewerLogic.effectivePresentationMode(
      requestedMode: requestedMode,
      hasChart: hasChart,
      preparationFailed: selectedChartFailure?.stage == .preparation)
  }

  private func selectMode(_ selectedMode: ResultPresentationPreference.Mode) {
    resultPresentationModeSelectionTransition(
      selectedMode,
      state: presentationState,
      authoritativePreference: preference,
      requestKey: chartRequest.key,
      chartRetryAvailable: selectedChartFailure?.retryability == .retryable
    ).commit(
      setState: { presentationState = $0 },
      retryChart: retryFailedChart,
      persistPreference: setPreference)
  }

  private func retryFailedChart() {
    chart.retryFailure(
      for: chartRequest.key,
      recommendationID: selectedRecommendation?.id)
  }

  private var tablePreview: some View {
    ScrollView(.horizontal) {
      Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 6) {
        GridRow {
          ForEach(Array(result.columns.enumerated()), id: \.offset) { _, column in
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
                  column: index < result.columns.count ? result.columns[index] : "")
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
