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
      Button("Keep Table", action: keepTable)
        .cregTextButtonTarget()
      Button("Retry Chart", action: retryChart)
        .buttonStyle(.borderedProminent)
        .cregTextButtonTarget()
    }
    .font(.caption)
  }
}
