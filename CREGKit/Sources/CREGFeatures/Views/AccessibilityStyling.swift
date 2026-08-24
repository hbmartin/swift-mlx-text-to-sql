import SwiftUI

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

  /// Gives a system-styled text control a minimum layout target without
  /// making the style draw its border around an already 44-point-tall label.
  func cregStyledTextButtonTarget() -> some View {
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
