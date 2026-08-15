import CREGEngine
import SwiftUI

#Preview("Result Viewer — Loan Maturities — Range Chart") {
  ResultViewerView(
    result: PreviewFixtures.loanMaturityResult,
    runtimeMode: .evaluated,
    textSize: .constant(.standard),
    sql: StarterQueryID.loanMaturitiesNextTwentyFourMonthsV1.sql,
    question:
      StarterQueryID.loanMaturitiesNextTwentyFourMonthsV1.question
  )
  .frame(width: 402, height: 874)
}
