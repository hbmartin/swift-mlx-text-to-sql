import Foundation
import Testing

@testable import CREGEngine
@testable import CREGFeatures

@Suite struct AnswerConfidenceTests {
  @Test func consensusReadsAsAgreement() {
    var telemetry = TurnTelemetry(originalQuestion: "q")
    telemetry.voteOutcome = .consensus(
      resultDigest: "d", agreement: 3, candidateCount: 3)
    telemetry.stageTimings.totalMicroseconds = 1_200_000
    let confidence = AnswerConfidence(telemetry: telemetry)
    #expect(confidence?.tone == .agreement)
    #expect(confidence?.symbolName == "checkmark.seal")
    #expect(confidence?.label == "3 of 3 readings agree · 1.2s")
  }

  @Test func noConsensusReadsAsCaution() {
    var telemetry = TurnTelemetry(originalQuestion: "q")
    telemetry.voteOutcome = .noConsensus(
      anchorCandidateID: CandidateID(rawValue: "deterministic-anchor"),
      candidateCount: 3)
    telemetry.stageTimings.totalMicroseconds = 3_000
    let confidence = AnswerConfidence(telemetry: telemetry)
    #expect(confidence?.tone == .caution)
    #expect(confidence?.label == "Readings split — deterministic result shown · 3ms")
  }

  @Test func anchorFailureReadsAsCaution() {
    var telemetry = TurnTelemetry(originalQuestion: "q")
    telemetry.voteOutcome = .anchorFailed(
      fallbackCandidateID: CandidateID(rawValue: "initial"), message: "m")
    let confidence = AnswerConfidence(telemetry: telemetry)
    #expect(confidence?.tone == .caution)
    #expect(confidence?.label == "Cross-check incomplete")
  }

  @Test func unvotedTurnReadsAsAnswered() {
    var telemetry = TurnTelemetry(originalQuestion: "q")
    telemetry.stageTimings.totalMicroseconds = 850_000
    let confidence = AnswerConfidence(telemetry: telemetry)
    #expect(confidence?.tone == .neutral)
    #expect(confidence?.symbolName == "checkmark")
    #expect(confidence?.label == "Answered · 850ms")
  }

  @Test func groundingDegradationAddsCaveat() {
    var telemetry = TurnTelemetry(originalQuestion: "q")
    telemetry.grounding = GroundingReport(
      degradations: [
        GroundingDegradation(
          column: GroundingColumn(table: "properties", column: "city"),
          message: "catalog load failed")
      ])
    let confidence = AnswerConfidence(telemetry: telemetry)
    #expect(confidence?.label == "Answered · value check incomplete")
  }

  @Test func missingTelemetryProducesNoChip() {
    #expect(AnswerConfidence(telemetry: nil) == nil)
  }
}

@Suite struct PortfolioValueFormattingTests {
  private func fmt(_ value: SQLValue, _ column: String) -> String {
    PortfolioValueFormatting.displayString(for: value, column: column)
  }

  @Test func currencyColumns() {
    #expect(fmt(.real(45_000_000.0), "current_market_value") == "$45,000,000")
    #expect(fmt(.real(1_234.5), "annual_base_rent") == "$1,234.50")
    #expect(fmt(.integer(2_500_000), "sum(net_operating_income)") == "$2,500,000")
    #expect(fmt(.real(-12_000.0), "vacancy_loss") == "-$12,000")
  }

  @Test func percentColumnsScaleStoredFractions() {
    #expect(fmt(.real(0.62), "occupancy_rate") == "62%")
    #expect(fmt(.real(0.0575), "avg(cap_rate)") == "5.75%")
    #expect(fmt(.real(0.7), "ltv") == "70%")
    #expect(fmt(.real(0.089), "interest_rate") == "8.9%")
    // A query's explicit ×100 stays in percent points.
    #expect(fmt(.real(62.0), "occupancy_rate") == "62%")
  }

  @Test func squareFeetAndPerSquareFoot() {
    #expect(fmt(.integer(12_400), "leased_sqft") == "12,400 sf")
    #expect(fmt(.real(28.5), "base_rent_psf") == "$28.50/sf")
  }

  @Test func ratioYearAndIdentifierStyles() {
    #expect(fmt(.real(1.25), "dscr") == "1.25×")
    #expect(fmt(.integer(2019), "vintage_year") == "2019")
    #expect(fmt(.integer(1984), "year_built") == "1984")
    #expect(fmt(.integer(1024), "property_id") == "1024")
  }

  @Test func datesFormatOnlyInDateColumns() {
    #expect(fmt(.text("2015-03-01"), "acquisition_date") == "Mar 1, 2015")
    #expect(fmt(.text("2026-11-30"), "expiration_date") == "Nov 30, 2026")
    #expect(fmt(.text("2025-07"), "period_end") == "Jul 2025")
    #expect(fmt(.text("not a date"), "maturity_date") == "not a date")
    #expect(fmt(.text("2015-03-01"), "name") == "2015-03-01")
  }

  @Test func unstyledColumnsFallBack() {
    #expect(fmt(.integer(42), "count(*)") == "42")
    #expect(fmt(.null, "current_market_value") == "—")
    #expect(fmt(.text("Fixed"), "rate_type") == "Fixed")
    #expect(fmt(.text("AA-"), "credit_rating") == "AA-")
  }

  @Test func wordBoundariesPreventFalseMatches() {
    #expect(PortfolioValueFormatting.style(forColumn: "credit_rating") == .plain)
    #expect(PortfolioValueFormatting.style(forColumn: "avg(cap_rate)") == .percent)
    #expect(
      PortfolioValueFormatting.style(forColumn: "base_rent_psf")
        == .currencyPerSquareFoot)
    #expect(PortfolioValueFormatting.style(forColumn: "free_rent_months") == .count)
    #expect(PortfolioValueFormatting.style(forColumn: "vacancy_loss") == .currency)
  }
}

@Suite struct ResultExportTests {
  @Test func csvEscapesAndKeepsRawValues() {
    let result = QueryResult(
      columns: ["name", "note", "value"],
      rows: [
        [.text("Sable, Tower"), .text("says \"hi\""), .real(1234567.89)],
        [.null, .text("line\nbreak"), .integer(42)],
      ])
    let expected = """
      name,note,value
      "Sable, Tower","says ""hi""",1234567.89
      ,"line
      break",42

      """
    #expect(result.csvString() == expected)
  }

  @Test func markdownUsesDomainFormattingAndEscapesPipes() {
    let result = QueryResult(
      columns: ["name", "current_market_value"],
      rows: [[.text("Sable|Tower"), .real(45_000_000.0)]])
    let expected = """
      | name | current_market_value |
      | --- | --- |
      | Sable\\|Tower | $45,000,000 |

      """
    #expect(result.markdownTableString() == expected)
  }

  @Test func exportStringStaysRaw() {
    #expect(SQLValue.real(45_000_000.0).exportString == "45000000")
    #expect(SQLValue.integer(1_234_567).exportString == "1234567")
    #expect(SQLValue.null.exportString == "")
    #expect(
      SQLValue.blob(Data([0x01, 0x02])).exportString
        == Data([0x01, 0x02]).base64EncodedString())
  }
}
