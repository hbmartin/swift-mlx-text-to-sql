import SwiftUI

/// Places leading content and trailing actions in one row at ordinary Dynamic
/// Type sizes, then stacks them against the leading edge at accessibility
/// sizes. Owning the spacer here keeps the stacked form full-width without
/// leaving an inert flexible gap between its children.
struct CREGAccessibilityActionLayout<Leading: View, Actions: View>: View {
  private let horizontalAlignment: VerticalAlignment
  private let horizontalSpacing: CGFloat
  private let accessibilitySpacing: CGFloat
  private let spacerMinLength: CGFloat
  private let leading: Leading
  private let actions: Actions
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  init(
    horizontalAlignment: VerticalAlignment = .center,
    horizontalSpacing: CGFloat,
    accessibilitySpacing: CGFloat,
    spacerMinLength: CGFloat = 0,
    @ViewBuilder leading: () -> Leading,
    @ViewBuilder actions: () -> Actions
  ) {
    self.horizontalAlignment = horizontalAlignment
    self.horizontalSpacing = horizontalSpacing
    self.accessibilitySpacing = accessibilitySpacing
    self.spacerMinLength = spacerMinLength
    self.leading = leading()
    self.actions = actions()
  }

  @ViewBuilder
  var body: some View {
    if dynamicTypeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: accessibilitySpacing) {
        leading
        actions
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      HStack(alignment: horizontalAlignment, spacing: horizontalSpacing) {
        leading
        Spacer(minLength: spacerMinLength)
        actions
      }
    }
  }
}

/// Shared geometry for custom icon-only controls.
///
/// A semantic font lets SF Symbols follow Dynamic Type. The minimum frame keeps
/// the hit region comfortable at ordinary sizes without preventing the symbol
/// or its control from growing at accessibility sizes.
extension View {
  func cregIconButtonTarget(
    font: Font = .body.weight(.medium)
  ) -> some View {
    self
      .font(font)
      .imageScale(.large)
      .frame(minWidth: 44, minHeight: 44)
      .contentShape(Rectangle())
  }

  /// Expands a text control's label to the minimum interactive height.
  ///
  /// Apply this inside a `Button` or `Menu` label so the control's gesture owns
  /// the complete shaped region. Keeping label and control geometry together
  /// avoids visually large but only partially tappable outer frames.
  func cregTextButtonLabelTarget() -> some View {
    self
      .frame(minHeight: 44)
      .contentShape(Rectangle())
  }

  @ViewBuilder
  func cregLargeContentViewer(
    _ title: LocalizedStringKey,
    systemImage: String
  ) -> some View {
    #if os(iOS)
      self.accessibilityShowsLargeContentViewer {
        Label(title, systemImage: systemImage)
      }
    #else
      self
    #endif
  }
}
