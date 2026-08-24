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
  @State private var chart: ResultChartLoader
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
    self._chart = State(
      initialValue: ResultChartLoader(
        client: _chartAnalysis.wrappedValue,
        warmStart: request,
        preferredSpecificationID: preference?.specificationID))
  }

  private var renderedScale: CGFloat {
    reduceMotion
      ? 1
      : ResultViewerLogic.previewScale(for: pinchMagnification)
  }

  private var selectedRecommendation: AutoChartRecommendation? {
    guard let analysis = chart.analysis else { return nil }
    switch analysis.resolve(preference?.specificationID) {
    case .exact(let recommendation), .defaulted(let recommendation, _):
      return recommendation
    case .unavailable:
      return nil
    }
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
        if selected != nil {
          Picker(
            "Result preview",
            selection: Binding(
              get: { effectiveMode(hasChart: true) },
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

        if chart.preparationFailed,
          (preference?.mode ?? .chart) == .chart
        {
          ResultChartRecoveryControls(
            spacing: 10,
            keepTable: { selectMode(.table) },
            retryChart: { selectMode(.chart) }
          )
          .accessibilityIdentifier("result-preview-chart-recovery")
        }

        Button(action: open) {
          VStack(alignment: .leading, spacing: 6) {
            if mode == .chart, selected != nil {
              chartArea
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
      .task(id: chartRequest.key) {
        await Self.analyzeChart(
          chart,
          request: chartRequest,
          preference: preference,
          migratePreference: migratePreference)
      }
      .task(
        id: chart.preparationTaskKey(
          recommendationID: selected?.id)
      ) {
        await chart.prepareSelected(selected)
      }
    }
  }

  @MainActor
  static func analyzeChart(
    _ chart: ResultChartLoader,
    request: ResultChartLoader.Request,
    preference: ResultPresentationPreference?,
    migratePreference: ResultPresentationMigrationHandler
  ) async {
    let resolution = await chart.analyze(
      request,
      preferredSpecificationID: preference?.specificationID)
    guard
      case .resolved(let recommendation)? = resolution,
      let previous = preference,
      let migrated = ResultViewerLogic.migratedPreference(
        previous,
        resolvedSpecificationID: recommendation.id)
    else { return }
    _ = migratePreference(previous, migrated)
  }

  @ViewBuilder
  private var chartArea: some View {
    if let preparedChart = chart.preparedChart {
      AutoChartView(
        preparedChart: preparedChart,
        presentation: .preview(plotHeight: 156),
        formatters: CREGChartAdapter.formatters)
    } else {
      ProgressView("Preparing chart")
        .frame(maxWidth: .infinity)
        .frame(height: 156)
    }
  }

  private func effectiveMode(hasChart: Bool) -> ResultPresentationPreference.Mode {
    ResultViewerLogic.effectivePresentationMode(
      requestedMode: preference?.mode ?? .chart,
      hasChart: hasChart,
      preparationFailed: chart.preparationFailed)
  }

  private func selectMode(_ selectedMode: ResultPresentationPreference.Mode) {
    switch ResultViewerLogic.modeSelectionIntent(
      selectedMode,
      requestedMode: preference?.mode ?? .chart,
      preserving: preference?.specificationID,
      preparationFailed: chart.preparationFailed
    ) {
    case .none:
      break
    case .persist(let updated):
      setPreference(updated)
    case .retryChart(let updated):
      chart.retryPreparation()
      if let updated {
        setPreference(updated)
      }
    }
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
