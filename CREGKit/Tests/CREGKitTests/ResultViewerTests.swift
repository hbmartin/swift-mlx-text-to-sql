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
}
