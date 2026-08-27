import AutoTableCharts
import CREGEngine
import ComposableArchitecture
import Foundation
import SwiftUI

#if DEBUG
private enum ResultChartPreparationPreviewFixtures {
  static let columns = [
    AutoChartColumn(id: "c0-fund", name: "fund"),
    AutoChartColumn(id: "c1-current-market-value", name: "current_market_value"),
  ]

  static let specification = AutoChartSpecification.bar(
    category: columns[0].id,
    measure: columns[1].id,
    title: "Portfolio value by fund")

  static let recommendation = AutoChartRecommendation(
    specification: specification,
    score: 0.92,
    rationale: [],
    diagnostics: [
      AutoChartDiagnostic(
        severity: .warning,
        message: "Long fund names may be shortened on the category axis.")
    ])

  static let selection = AutoChartSelection<Int>(
    sourceRowIDs: [0],
    dimensions: [
      AutoChartSelectedDimension(
        columnID: columns[0].id,
        value: .text("Meridian Core Fund I"))
    ],
    measure: AutoChartSelectedMeasure(
      columnID: columns[1].id,
      aggregation: .none,
      value: .scalar(.double(412_500_000))),
    family: .bar,
    specificationID: specification.id,
    markID: "meridian-core-fund-i")
}

// Standalone previews intentionally use ResultViewerView's cacheless harness.
#Preview("Result Viewer — Range Chart — Light") {
  ResultViewerView(
    result: PreviewFixtures.leaseListingResult,
    runtimeMode: .evaluated,
    textSize: .constant(.standard),
    sql: StarterQueryID.leaseExpirationsNextTwelveMonthsV1.sql,
    question: StarterQueryID.leaseExpirationsNextTwelveMonthsV1.question)
    .frame(width: 402, height: 874)
}

#Preview("Result Viewer — Loan Maturities — Range Chart") {
  ResultViewerView(
    result: PreviewFixtures.loanMaturityResult,
    runtimeMode: .evaluated,
    textSize: .constant(.standard),
    sql: StarterQueryID.loanMaturitiesNextTwentyFourMonthsV1.sql,
    question: StarterQueryID.loanMaturitiesNextTwentyFourMonthsV1.question
  )
  .frame(width: 402, height: 874)
}

#Preview("Result Viewer — Bar Chart — Light") {
  ResultViewerView(
    result: PreviewFixtures.fundValueResult,
    runtimeMode: .evaluated,
    textSize: .constant(.standard),
    sql: StarterQueryID.portfolioValueByFundV1.sql,
    question: StarterQueryID.portfolioValueByFundV1.question)
    .frame(width: 402, height: 874)
}

#Preview("Result Viewer — Truncation Warning — Dark") {
  ResultViewerView(
    result: PreviewFixtures.truncatedResult,
    runtimeMode: .evaluated,
    textSize: .constant(.standard),
    sql: "SELECT property, tenant, annual_base_rent FROM leases LIMIT 500",
    question: "Show the distribution of returned annual base rent")
    .frame(width: 402, height: 874)
    .preferredColorScheme(.dark)
}

#Preview("Result Viewer — Large Text — Selected Cell") {
  @Previewable @State var textSize = ResultTableTextSize.large
  ResultViewerView(
    result: PreviewFixtures.leaseListingResult,
    runtimeMode: .evaluated,
    textSize: $textSize,
    preference: ResultPresentationPreference(mode: .table),
    initialSelection: ResultCellSelection(row: 1, column: 2))
    .frame(width: 402, height: 874)
}

#Preview("Result Viewer — No Search Matches") {
  ResultViewerView(
    result: PreviewFixtures.leaseListingResult,
    runtimeMode: .evaluated,
    textSize: .constant(.standard),
    preference: ResultPresentationPreference(mode: .table),
    initialSearchText: "no such tenant")
    .frame(width: 402, height: 874)
}

#Preview("Result Viewer — Filtered Table") {
  ResultViewerView(
    result: PreviewFixtures.leaseListingResult,
    runtimeMode: .evaluated,
    textSize: .constant(.standard),
    sql: StarterQueryID.leaseExpirationsNextTwelveMonthsV1.sql,
    question: StarterQueryID.leaseExpirationsNextTwelveMonthsV1.question,
    preference: ResultPresentationPreference(mode: .table),
    initialChartSelection: PreviewFixtures.filteredLeaseChartSelection)
    .frame(width: 402, height: 874)
}

#Preview("Result Viewer — Chart — Accessibility Dynamic Type") {
  ResultViewerView(
    result: PreviewFixtures.fundValueResult,
    runtimeMode: .evaluated,
    textSize: .constant(.large),
    sql: StarterQueryID.portfolioValueByFundV1.sql,
    question: StarterQueryID.portfolioValueByFundV1.question)
    .frame(width: 402, height: 874)
    .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("Result Chart Preparation — Preview") {
  ResultChartPreparationView(
    recommendation: ResultChartPreparationPreviewFixtures.recommendation,
    presentation: .preview(
      plotHeight: ResultChartLayout.previewPlotHeight),
    formatters: CREGChartAdapter.formatters,
    textResolver: CREGChartAdapter.textResolver)
    .padding()
    .frame(width: 370)
}

#Preview("Result Chart Preparation — Explorer — Selected") {
  @Previewable @State var selection: AutoChartSelection<Int>? =
    ResultChartPreparationPreviewFixtures.selection
  ResultChartPreparationView(
    recommendation: ResultChartPreparationPreviewFixtures.recommendation,
    presentation: .explorer(
      plotHeight: ResultChartLayout.explorerPlotHeight),
    selection: selection.map { value in
      ResultChartPreparationView.SelectionConfiguration(
        value: value,
        columns: ResultChartPreparationPreviewFixtures.columns,
        clear: { selection = nil })
    },
    formatters: CREGChartAdapter.formatters,
    textResolver: CREGChartAdapter.textResolver)
    .padding()
    .frame(width: 402)
}

#Preview("Result Chart Recovery Controls — Standard") {
  ResultChartRecoveryControls(spacing: 12, keepTable: {}, retryChart: {})
    .padding()
    .frame(width: 402)
}

#Preview("Result Chart Recovery Controls — Accessibility") {
  ResultChartRecoveryControls(spacing: 12, keepTable: {}, retryChart: {})
    .padding()
    .frame(width: 402)
    .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
