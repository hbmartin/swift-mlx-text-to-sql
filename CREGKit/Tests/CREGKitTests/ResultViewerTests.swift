import ComposableArchitecture
import Foundation
import Testing

@testable import CREGEngine
@testable import CREGFeatures

/// Result Viewer logic: formatting, typed sorting, search, truncation
/// labels, and export text — all without rendering a view.
@Suite struct ResultViewerTests {
  private let result = QueryResult(
    columns: ["property", "value"],
    rows: [
      [.text("Harbor Point"), .integer(10)],
      [.text("Béa Café"), .integer(2)],
      [.text("atlas yard"), .real(2.5)],
      [.null, .null],
    ])

  // MARK: Sorting

  @Test func toggleSortStartsAscendingThenFlips() {
    let first = ResultViewerLogic.toggleSort(nil, column: 1)
    #expect(first == ResultViewerLogic.SortState(column: 1, ascending: true))
    let flipped = ResultViewerLogic.toggleSort(first, column: 1)
    #expect(flipped == ResultViewerLogic.SortState(column: 1, ascending: false))
    let newColumn = ResultViewerLogic.toggleSort(flipped, column: 0)
    #expect(newColumn == ResultViewerLogic.SortState(column: 0, ascending: true))
  }

  @Test func numericSortIsTypedNotLexicographic() {
    let rows = ResultViewerLogic.displayRows(
      result: result,
      sort: ResultViewerLogic.SortState(column: 1, ascending: true),
      searchText: "")
    // NULL sorts first; then 2 < 2.5 < 10 across the unified INTEGER/REAL
    // domain (a string sort would have put 10 before 2).
    #expect(rows.map { $0[1] } == [.null, .integer(2), .real(2.5), .integer(10)])
  }

  @Test func descendingSortReversesTypedOrder() {
    let rows = ResultViewerLogic.displayRows(
      result: result,
      sort: ResultViewerLogic.SortState(column: 1, ascending: false),
      searchText: "")
    #expect(rows.map { $0[1] } == [.integer(10), .real(2.5), .integer(2), .null])
  }

  @Test func textSortIsCaseInsensitiveWithNullFirst() {
    let rows = ResultViewerLogic.displayRows(
      result: result,
      sort: ResultViewerLogic.SortState(column: 0, ascending: true),
      searchText: "")
    #expect(rows.map { $0[0] } == [
      .null, .text("atlas yard"), .text("Béa Café"), .text("Harbor Point"),
    ])
  }

  @Test func equalCellsKeepOriginalRowOrder() {
    let tied = QueryResult(
      columns: ["k", "v"],
      rows: [
        [.text("first"), .integer(1)],
        [.text("second"), .integer(1)],
        [.text("third"), .integer(1)],
      ])
    let rows = ResultViewerLogic.displayRows(
      result: tied,
      sort: ResultViewerLogic.SortState(column: 1, ascending: true),
      searchText: "")
    #expect(rows.map { $0[0] } == [.text("first"), .text("second"), .text("third")])
  }

  // MARK: Search

  @Test func searchIsCaseAndDiacriticInsensitive() {
    let hits = ResultViewerLogic.displayRows(
      result: result, sort: nil, searchText: "bea cafe")
    #expect(hits.count == 1)
    #expect(hits.first?.first == .text("Béa Café"))

    let upper = ResultViewerLogic.displayRows(
      result: result, sort: nil, searchText: "HARBOR")
    #expect(upper.count == 1)
  }

  @Test func searchMatchesNumbersByDisplayOrRawForm() {
    let hits = ResultViewerLogic.displayRows(
      result: result, sort: nil, searchText: "2.5")
    #expect(hits.count == 1)
    #expect(hits.first?.first == .text("atlas yard"))
  }

  @Test func emptySearchKeepsEveryRow() {
    let rows = ResultViewerLogic.displayRows(
      result: result, sort: nil, searchText: "   ")
    #expect(rows.count == result.rows.count)
  }

  // MARK: Truncation labels

  @Test func truncatedResultsAreLabeledFirstNPlusRows() {
    var truncated = result
    truncated.isTruncated = true
    #expect(ResultViewerLogic.truncationLabel(for: truncated) == "First 4+ rows")
    #expect(ResultViewerLogic.rowCountLabel(for: truncated) == "First 4+ rows")
  }

  @Test func completeResultsNeverImplyTruncation() {
    #expect(ResultViewerLogic.truncationLabel(for: result) == nil)
    #expect(ResultViewerLogic.rowCountLabel(for: result) == "4 rows")
    let single = QueryResult(columns: ["a"], rows: [[.integer(1)]])
    #expect(ResultViewerLogic.rowCountLabel(for: single) == "1 row")
  }

  // MARK: Pinch interaction

  @Test func pinchArmingUsesTheApprovedHysteresisThresholds() {
    #expect(!ResultViewerLogic.pinchIsArmed(magnification: 1.119, wasArmed: false))
    #expect(ResultViewerLogic.pinchIsArmed(magnification: 1.12, wasArmed: false))
    #expect(ResultViewerLogic.pinchIsArmed(magnification: 1.081, wasArmed: true))
    #expect(!ResultViewerLogic.pinchIsArmed(magnification: 1.079, wasArmed: true))
  }

  @Test func previewScaleTracksOutwardMotionAndStaysRestrained() {
    #expect(ResultViewerLogic.previewScale(for: 0.8) == 1)
    #expect(ResultViewerLogic.previewScale(for: 1) == 1)
    #expect(abs(ResultViewerLogic.previewScale(for: 1.12) - 1.03) < 0.0001)
    #expect(ResultViewerLogic.previewScale(for: 2) == 1.04)
  }

  // MARK: Cell inspection

  @Test func displayedAndRawCopyValuesRemainDistinct() {
    let value = SQLValue.integer(1_200)
    #expect(
      ResultViewerLogic.displayedCopyValue(value, column: "property_value")
        == "$1,200")
    #expect(ResultViewerLogic.rawCopyValue(value) == "1200")
  }

  @Test func copiedRowIsOneHeaderlessRFC4180Record() {
    let row: [SQLValue] = [
      .text("Harbor, Point"),
      .text("Suite \"A\""),
      .text("line one\nline two"),
      .null,
    ]
    #expect(
      ResultViewerLogic.csvRowString(row)
        == "\"Harbor, Point\",\"Suite \"\"A\"\"\",\"line one\nline two\",\n")
  }

  @Test func columnMetricsShareBoundsAcrossHeadersAndCells() {
    let widths = ResultTableColumnMetrics(
      characterWidth: 10,
      horizontalPadding: 4,
      minimumWidth: 40,
      maximumWidth: 100
    ).widths(for: result)

    #expect(widths == [100, 58])
  }

  // MARK: Export

  @Test func combinedMarkdownJoinsNarrationAndTable() {
    let text = AnswerExport.combinedMarkdown(
      narration: "Two rows found.", result: result)
    #expect(text.hasPrefix("Two rows found.\n\n"))
    #expect(text.contains("| property | value |"))
    #expect(text.contains("Béa Café"))
  }

  @Test func combinedMarkdownWithEmptyResultIsNarrationOnly() {
    let empty = QueryResult(columns: [], rows: [])
    let text = AnswerExport.combinedMarkdown(narration: "Nothing matched.", result: empty)
    #expect(text == "Nothing matched.\n")
  }

  @Test func compatibilityExportsAreExplicitlyUnevaluated() {
    let markdown = AnswerExport.combinedMarkdown(
      narration: "Two rows found.",
      result: result,
      runtimeMode: .compatibility)
    #expect(markdown.contains("Runtime mode: compatibility"))
    #expect(markdown.contains("Evaluated: false"))

    let csv = result.csvString(runtimeMode: .compatibility)
    #expect(csv.contains("__creg_runtime_mode,__creg_evaluated"))
    #expect(csv.contains(",compatibility,false"))
  }
}

@MainActor
@Suite struct ResultTableTextSizePreferenceTests {
  @Test func standardIsTheDefaultPreset() {
    let defaults = UserDefaults.inMemory
    let state = withDependencies {
      $0.defaultAppStorage = defaults
    } operation: {
      AppFeature.State()
    }

    #expect(state.resultTableTextSize == .standard)
    #expect(ResultTableTextSize.allCases == [.small, .standard, .large])
    #expect(ResultTableTextSize.allCases.map(\.title) == ["Small", "Standard", "Large"])
  }

  @Test func changedPresetSurvivesStateReconstruction() {
    let defaults = UserDefaults.inMemory
    let initialState = withDependencies {
      $0.defaultAppStorage = defaults
    } operation: {
      AppFeature.State()
    }
    initialState.$resultTableTextSize.withLock { $0 = .large }

    let reconstructed = withDependencies {
      $0.defaultAppStorage = defaults
    } operation: {
      AppFeature.State()
    }

    #expect(reconstructed.resultTableTextSize == .large)
    #expect(defaults.string(forKey: ResultTableTextSize.storageKey) == "large")
  }
}
