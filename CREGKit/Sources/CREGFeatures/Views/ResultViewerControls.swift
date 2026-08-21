import AutoTableCharts
import CREGEngine
import ComposableArchitecture
import SwiftUI

extension ResultViewerView {
  func footer(
    displayedRowCount: Int,
    sourceResult: QueryResult,
    selectionIsActive: Bool
  ) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        rowStatus(
          displayedRowCount: displayedRowCount,
          sourceResult: sourceResult,
          selectionIsActive: selectionIsActive)
        Spacer(minLength: 0)
        if selectionIsActive {
          clearChartSelectionButton
        }
        sortChip
      }
      VStack(alignment: .leading, spacing: 6) {
        rowStatus(
          displayedRowCount: displayedRowCount,
          sourceResult: sourceResult,
          selectionIsActive: selectionIsActive)
        if selectionIsActive {
          clearChartSelectionButton
        }
        sortChip
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 6)
    .background(Color.primary.opacity(0.025))
    .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: sort)
  }

  var clearChartSelectionButton: some View {
    Button {
      chartSelection = nil
    } label: {
      Label("Clear chart filter", systemImage: "xmark.circle.fill")
        .font(.caption.weight(.medium))
    }
    .buttonStyle(.bordered)
    .cregTextButtonTarget()
    .accessibilityIdentifier("clear-chart-selection")
  }

  func rowStatus(
    displayedRowCount: Int,
    sourceResult: QueryResult,
    selectionIsActive: Bool
  ) -> some View {
    let label =
      if selectionIsActive {
        ResultViewerLogic.selectedRowStatusLabel(
          for: result,
          selectedRowCount: sourceResult.rowCount,
          displayedRowCount: displayedRowCount,
          searchIsActive: !normalizedSearchText.isEmpty)
      } else {
        ResultViewerLogic.rowStatusLabel(
          for: result,
          displayedRowCount: displayedRowCount,
          searchIsActive: !normalizedSearchText.isEmpty)
      }
    return Text(label)
      .font(.caption)
      .foregroundStyle(result.isTruncated ? .orange : .secondary)
  }

  @ViewBuilder
  var sortChip: some View {
    if let sort, result.columns.indices.contains(sort.column) {
      Button {
        self.sort = nil
      } label: {
        HStack(spacing: 5) {
          Image(systemName: sort.ascending ? "arrow.up" : "arrow.down")
          Text(result.columns[sort.column])
            .lineLimit(1)
          Image(systemName: "xmark.circle.fill")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(CREGBrand.blue)
        .padding(.horizontal, 10)
        .background(CREGBrand.blue.opacity(0.1), in: Capsule())
      }
      .buttonStyle(.plain)
      .cregTextButtonTarget()
      .accessibilityLabel(
        "Clear sort by \(result.columns[sort.column]), \(sort.ascending ? "ascending" : "descending")"
      )
    }
  }

  var noMatchesState: some View {
    ContentUnavailableView {
      Label("No Matching Rows", systemImage: "magnifyingglass")
    } description: {
      Text("No returned row contains “\(normalizedSearchText)”.")
    } actions: {
      Button("Clear Search") { searchText = "" }
        .buttonStyle(.borderedProminent)
        .cregTextButtonTarget()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(CREGBrand.chatSurface.opacity(0.96))
  }

  @ViewBuilder
  var copyFeedback: some View {
    if let copyFeedbackMessage {
      Label(copyFeedbackMessage, systemImage: "checkmark.circle.fill")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.green)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 12)
        .transition(
          reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.96))
        )
        .accessibilityLabel(copyFeedbackMessage)
    }
  }

  func copy(_ string: String, confirmation: String) {
    Pasteboard.copy(string)
    withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) {
      copyFeedbackMessage = confirmation
      copyFeedbackTrigger += 1
    }
  }

  var chartTypeMenu: some View {
    Menu {
      // The one user action that changes the chart specification: persist
      // the preference here, and clear the exact-mark selection whose row
      // indexes are meaningless under the newly picked chart.
      Picker(
        "Chart type",
        selection: Binding(
          get: { selectedSpecificationID },
          set: { id in
            guard id != selectedSpecificationID else { return }
            selectedSpecificationID = id
            chartSelection = nil
            persistPreference(
              ResultPresentationPreference(
                mode: resultMode, specificationID: id))
          })
      ) {
        ForEach(chartRecommendations) { recommendation in
          Text(recommendation.specification.family.displayName)
            .tag(Optional(recommendation.id))
        }
      }
    } label: {
      Image(systemName: "chart.xyaxis.line")
        .cregIconButtonTarget()
    }
    .accessibilityLabel("Chart type")
    .accessibilityIdentifier("result-chart-type")
    .cregLargeContentViewer("Chart type", systemImage: "chart.xyaxis.line")
  }

  var textSizeMenu: some View {
    Menu {
      Picker("Table Text Size", selection: $textSize) {
        ForEach(ResultTableTextSize.allCases, id: \.self) { size in
          Text(size.title).tag(size)
        }
      }
    } label: {
      Image(systemName: "textformat.size")
        .cregIconButtonTarget()
    }
    .accessibilityLabel("Table text size")
    .accessibilityValue(textSize.title)
    .cregLargeContentViewer("Table text size", systemImage: "textformat.size")
  }

  var exportMenu: some View {
    Menu {
      Button("Copy as CSV") {
        Pasteboard.copy(result.csvString(runtimeMode: runtimeMode))
      }
      Button("Copy as Markdown") {
        Pasteboard.copy(result.markdownTableString(runtimeMode: runtimeMode))
      }
      ShareLink(
        item: ResultCSVTransfer(result: result, runtimeMode: runtimeMode),
        preview: SharePreview("Result table (CSV)")
      ) {
        Label("Share CSV", systemImage: "square.and.arrow.up")
      }
      ShareLink(item: result.markdownTableString(runtimeMode: runtimeMode)) {
        Label("Share Markdown", systemImage: "square.and.arrow.up")
      }
    } label: {
      Image(systemName: "square.and.arrow.up")
        .cregIconButtonTarget()
    }
    .accessibilityLabel("Export table")
    .cregLargeContentViewer("Export table", systemImage: "square.and.arrow.up")
  }
}
