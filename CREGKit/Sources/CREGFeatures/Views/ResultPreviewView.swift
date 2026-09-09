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
  let chartRequest: AutoChartRequest<Int>
  @Dependency(\.chartAnalysis) private var chartAnalysis
  @Dependency(\.diagnostics) private var diagnostics
  @State private var session: AutoChartSession<Int>
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
    let input = try! CREGChartAdapter.analysisInput(
      result: result,
      sql: sql,
      question: question,
      resultFingerprint: resultFingerprint,
      dataIdentity: CREGChartAdapter.resultDataIdentity(messageID: messageID))
    self.chartRequest = input.request
    self._session = State(initialValue: _chartAnalysis.wrappedValue.makeSession())
  }

  private var analysis: AutoChartAnalysis<Int>? {
    switch session.state {
    case .preparing(let analysis, _), .ready(let analysis, _),
      .fallback(let analysis, _):
      analysis
    case .idle, .analyzing, .failed:
      nil
    }
  }

  private var selectedRecommendation: AutoChartRecommendation? {
    analysis?.preferenceResolution?.recommendation
  }

  private var failure: AutoChartFailure? {
    guard case .failed(let failure) = session.state else { return nil }
    return failure
  }

  private var requestedMode: ResultPresentationMode {
    (preference ?? .automatic).mode
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
      let selected = selectedRecommendation
      let mode = effectiveMode(hasChart: selected != nil)
      VStack(alignment: .leading, spacing: 8) {
        if selected != nil || failure?.isRetryable == true {
          Picker(
            "Result preview",
            selection: Binding(
              get: { effectiveMode(hasChart: selected != nil) },
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

        if let failure, requestedMode == .chart {
          ResultChartRecoveryControls(
            spacing: 10,
            keepTable: { selectMode(.table) },
            retryChart: failure.isRetryable ? { session.retry() } : nil)
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
          "Result \(mode == .chart ? "chart" : "table"), \(ResultViewerLogic.rowCountLabel(for: result))")
        .accessibilityHint("Double-tap or pinch outward to open the result explorer")
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
      .onChange(of: failure?.episodeID) { _, episodeID in
        guard let failure, episodeID != nil else { return }
        recordChartFailure(failure, diagnostics: diagnostics)
      }
      .onChange(of: analysis?.preferenceResolution?.replacementPreference) {
        _, replacement in
        guard let replacement else { return }
        _ = migratePreference(preference ?? .automatic, replacement)
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

  private func effectiveMode(hasChart: Bool) -> ResultPresentationMode {
    ResultViewerLogic.effectivePresentationMode(
      requestedMode: requestedMode,
      hasChart: hasChart,
      preparationFailed: failure != nil)
  }

  private func selectMode(_ mode: ResultPresentationMode) {
    let updated: AutoChartPreference = mode == .table ? .table : .chart(.recommended)
    session.setPreference(updated)
    setPreference(updated)
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
