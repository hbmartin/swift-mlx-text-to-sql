import SwiftUI

/// Shared recovery actions shown when a chart could not be analyzed or
/// prepared. Actions stack at accessibility sizes instead of competing with
/// the status label for one increasingly narrow row.
struct ResultChartRecoveryControls: View {
  var spacing: CGFloat
  var keepTable: () -> Void
  var retryChart: () -> Void

  var body: some View {
    CREGAccessibilityActionLayout(
      horizontalSpacing: spacing,
      accessibilitySpacing: spacing
    ) {
      Label("Chart unavailable", systemImage: "exclamationmark.triangle")
        .foregroundStyle(.secondary)
    } actions: {
      Button(action: keepTable) {
        Text("Keep Table")
          .cregTextButtonLabelTarget()
      }
      .buttonStyle(.bordered)
      Button(action: retryChart) {
        Text("Retry Chart")
          .cregTextButtonLabelTarget()
      }
      .buttonStyle(.borderedProminent)
    }
    .font(.caption)
  }
}
