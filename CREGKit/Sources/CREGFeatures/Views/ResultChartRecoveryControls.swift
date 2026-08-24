import SwiftUI

/// Shared recovery actions shown when a recommended chart could not be
/// prepared. Both buttons retain a full touch target at compact text sizes.
struct ResultChartRecoveryControls: View {
  var spacing: CGFloat
  var keepTable: () -> Void
  var retryChart: () -> Void

  var body: some View {
    HStack(spacing: spacing) {
      Label("Chart unavailable", systemImage: "exclamationmark.triangle")
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
      Button(action: keepTable) {
        Text("Keep Table")
          .cregTextButtonTarget()
      }
      Button(action: retryChart) {
        Text("Retry Chart")
          .cregTextButtonTarget()
      }
        .buttonStyle(.borderedProminent)
    }
    .font(.caption)
  }
}
