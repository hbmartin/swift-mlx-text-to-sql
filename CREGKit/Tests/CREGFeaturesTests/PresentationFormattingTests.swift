import Foundation
import Testing

@testable import CREGEngine
@testable import CREGFeatures

@Suite struct PresentationFormattingTests {
  @Test func snapshotDateUsesTheSameCalendarIndependentFormatAsTables() {
    let asOf = PortfolioSnapshot.asOfDate
    #expect(PortfolioAsOfDateDisplay.text
      == PortfolioValueFormatting.displayString(for: .text(asOf), column: "as_of_date"))
    #expect(PortfolioAsOfDateDisplay.text == "Jul 1, 2026")
  }

  @Test func chartValueLabelsAndAmountsShareTableFormatting() {
    let result = PreviewFixtures.datedValueResult
    let rows = SimpleChartValues.rows(for: result)!
    #expect(rows.map(\.label) == ["Jun 30, 2024", "Dec 31, 2024"])
    #expect(rows.map(\.value) == ["$412,500,000", "$426,000,000"])
    #expect(SimpleChartValues.accessibilitySummary(for: result)
      == "Jun 30, 2024, $412,500,000; Dec 31, 2024, $426,000,000")
    #expect(result.rows[0][0] == .text("2024-06-30"))
  }

  @Test func ordinaryFundNamesRemainCompleteAndDistinct() {
    let result = QueryResult(
      columns: ["fund", "occupancy_rate"],
      rows: [
        [.text("Meridian Core Fund I"), .real(0.95)],
        [.text("Meridian Value-Add II"), .real(0.875)],
      ])
    let rows = SimpleChartValues.rows(for: result)!
    #expect(rows.map(\.label) == ["Meridian Core Fund I", "Meridian Value-Add II"])
    #expect(rows.map(\.value) == ["95%", "87.5%"])
    #expect(SimpleChartValues.accessibilitySummary(for: result)
      == "Meridian Core Fund I, 95%; Meridian Value-Add II, 87.5%")
  }

  @Test func unsupportedValueRowsDoNotProduceAnAccessibilitySummary() {
    #expect(SimpleChartValues.accessibilitySummary(for:
      QueryResult(columns: ["value"], rows: [[.integer(1)]])) == "")
  }
}
