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

  func cregTextButtonTarget() -> some View {
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
