import AutoTableCharts
import CREGEngine
import ComposableArchitecture
import SwiftUI

// MARK: - Presentation

enum ResultChartLayout {
  static let previewPlotHeight: CGFloat = 156
  static let explorerPlotHeight: CGFloat = 360
}

struct ResultChartPreparationView: View {
  struct SelectionConfiguration {
    let value: AutoChartSelection<Int>
    let columns: [AutoChartColumn]
    let clear: () -> Void
  }

  let recommendation: AutoChartRecommendation
  let presentation: AutoChartPresentation
  let selection: SelectionConfiguration?
  let formatters: AutoChartFormatters
  let textResolver: AutoChartTextResolver

  init(
    recommendation: AutoChartRecommendation,
    presentation: AutoChartPresentation,
    selection: SelectionConfiguration? = nil,
    formatters: AutoChartFormatters,
    textResolver: AutoChartTextResolver
  ) {
    self.recommendation = recommendation
    self.presentation = presentation
    self.selection = selection
    self.formatters = formatters
    self.textResolver = textResolver
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if presentation.chrome.contains(.title),
        !recommendation.specification.title.isEmpty
      {
        Text(recommendation.specification.title)
          .font(.headline)
      }
      ProgressView("Preparing chart")
        .frame(
          maxWidth: .infinity,
          maxHeight: presentation.plotHeight == nil ? .infinity : nil)
        .frame(height: presentation.plotHeight)
        .accessibilityIdentifier("auto-chart-preparing-plot")
      if presentation.chrome.contains(.selectionSummary), let selection {
        let summary = selection.value.presentation(
          columns: selection.columns,
          formatters: formatters,
          textResolver: textResolver)
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 2) {
            Text(summary.label)
              .font(.subheadline.weight(.semibold))
            Text(summary.valueDescription)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button(
            textResolver(.init(
              category: .interface,
              code: .clearSelection,
              defaultText: "Clear")),
            action: selection.clear)
            .buttonStyle(.borderless)
            .accessibilityIdentifier("auto-chart-clear-selection")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary.accessibilityDescription)
      }
      if presentation.chrome.contains(.diagnostics) {
        ForEach(Array(recommendation.diagnostics.enumerated()), id: \.offset) {
          _, diagnostic in
          Label(
            textResolver(diagnostic.messageValue),
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.caption)
          .foregroundStyle(.orange)
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      recommendation.specification.title.isEmpty
        ? recommendation.specification.family.displayName
        : recommendation.specification.title
    )
    .accessibilityIdentifier(
      "auto-chart-preparing-\(recommendation.specification.family.rawValue)")
  }
}

extension View {
  /// Full-screen on iPhone; a sheet on the macOS host-test target, which has
  /// no full-screen cover.
  @ViewBuilder
  func resultViewerPresentation(
    store: StoreOf<ChatFeature>,
    textSize: Binding<ResultTableTextSize>
  ) -> some View {
    let binding = Binding<ResultViewerItem?>(
      get: {
        guard let id = store.resultViewerMessageID,
          let message = store.messages[id: id]
        else { return nil }
        let result: QueryResult
        let resultFingerprint: String
        let sql: String
        let question: String?
        switch message.body {
        case .answer(let answerResult, _, let answerSQL, _):
          guard let fingerprint = message.resultFingerprint else { return nil }
          result = answerResult
          resultFingerprint = fingerprint
          sql = answerSQL
          question = message.devInfo?.originalQuestion
        case .preparedAnswer(let prepared):
          result = prepared.result
          resultFingerprint = prepared.provenance.resultFingerprint
          sql = prepared.sql
          question = prepared.question
        default:
          return nil
        }
        return ResultViewerItem(
          messageID: id,
          resultFingerprint: resultFingerprint,
          result: result,
          runtimeMode: ResultViewerLogic.runtimeMode(for: message),
          sql: sql,
          question: question,
          preference: message.resultPresentation)
      },
      set: { item in
        if item == nil {
          store.send(.resultViewerDismissed)
        }
      })
    #if os(iOS)
      self.fullScreenCover(item: binding) { item in
        ResultViewerView(
          result: item.result,
          runtimeMode: item.runtimeMode,
          textSize: textSize,
          messageID: item.messageID,
          resultFingerprint: item.resultFingerprint,
          sql: item.sql,
          question: item.question,
          preference: item.preference,
          persistPreference: { [messageID = item.messageID] preference in
            store.send(
              .resultPresentationChanged(
                messageID: messageID, preference: preference))
          },
          migratePreference: resultPresentationMigrationHandler(
            store: store,
            messageID: item.messageID))
      }
    #else
      self.sheet(item: binding) { item in
        ResultViewerView(
          result: item.result,
          runtimeMode: item.runtimeMode,
          textSize: textSize,
          messageID: item.messageID,
          resultFingerprint: item.resultFingerprint,
          sql: item.sql,
          question: item.question,
          preference: item.preference,
          persistPreference: { [messageID = item.messageID] preference in
            store.send(
              .resultPresentationChanged(
                messageID: messageID, preference: preference))
          },
          migratePreference: resultPresentationMigrationHandler(
            store: store,
            messageID: item.messageID))
      }
    #endif
  }
}

struct ResultViewerItem: Identifiable, Equatable {
  var messageID: UUID
  var resultFingerprint: String
  var result: QueryResult
  var runtimeMode: ModelRuntimeMode
  var sql: String
  var question: String?
  var preference: ResultPresentationPreference?
  var id: UUID { messageID }
}
