import SwiftUI

/// Shared recovery actions shown when a recommended chart could not be
/// prepared. Actions stack at accessibility sizes instead of competing with
/// the status label for one increasingly narrow row.
struct ResultChartRecoveryControls: View {
  var spacing: CGFloat
  var keepTable: () -> Void
  var retryChart: () -> Void
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    let layout =
      dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(
        VStackLayout(alignment: .leading, spacing: spacing))
      : AnyLayout(HStackLayout(spacing: spacing))
    layout {
      Label("Chart unavailable", systemImage: "exclamationmark.triangle")
        .foregroundStyle(.secondary)
      if !dynamicTypeSize.isAccessibilitySize {
        Spacer(minLength: 0)
      }
      Button(action: keepTable) {
        Text("Keep Table")
      }
      .buttonStyle(.bordered)
      .cregStyledTextButtonTarget()
      Button(action: retryChart) {
        Text("Retry Chart")
      }
      .buttonStyle(.borderedProminent)
      .cregStyledTextButtonTarget()
    }
    .font(.caption)
  }
}
