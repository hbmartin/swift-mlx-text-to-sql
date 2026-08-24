import AutoTableCharts
import CREGEngine
import ComposableArchitecture
import Foundation
import SwiftUI

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
    initialChartSelection: AutoChartSelection(
      sourceRowIDs: [0, 4, 8],
      dimensions: [],
      measure: nil,
      family: .range,
      specificationID: AutoChartSpecification.range(
        label: "lease", start: "start", end: "end").id,
      markID: "selected-expiration"))
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
