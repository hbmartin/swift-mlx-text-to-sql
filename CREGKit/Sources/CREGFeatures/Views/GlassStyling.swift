import SwiftUI

/// CREG's Liquid Glass vocabulary. Glass belongs to the floating interactive
/// layer — header, composer, menus, and high-value controls — never to the
/// transcript or the browser underneath (ADR 0007).
///
/// The package's older macOS host-test target renders a material fallback;
/// iOS always uses the native iOS 26 glass APIs.
enum CREGBrand {
  /// Branded turquoise-to-blue used by trailing user bubbles and accents.
  static let turquoise = Color(red: 0.20, green: 0.71, blue: 0.82)
  static let blue = Color(red: 0.12, green: 0.44, blue: 0.93)

  static var bubbleGradient: LinearGradient {
    LinearGradient(
      colors: [turquoise, blue],
      startPoint: .topLeading,
      endPoint: .bottomTrailing)
  }
}

/// `GlassEffectContainer` on iOS so sibling glass controls share one sampling
/// region and can morph; a plain group on the macOS fallback.
struct CREGGlassContainer<Content: View>: View {
  var spacing: CGFloat
  @ViewBuilder var content: Content

  init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
    self.spacing = spacing
    self.content = content()
  }

  var body: some View {
    #if os(iOS)
      GlassEffectContainer(spacing: spacing) { content }
    #else
      content
    #endif
  }
}

extension View {
  /// Regular glass in a capsule; the default treatment for floating controls.
  @ViewBuilder
  func cregGlassCapsule(interactive: Bool = false) -> some View {
    #if os(iOS)
      if interactive {
        self.glassEffect(.regular.interactive(), in: .capsule)
      } else {
        self.glassEffect(.regular, in: .capsule)
      }
    #else
      self.background(.ultraThinMaterial, in: Capsule())
    #endif
  }

  /// Regular glass in a rounded rectangle for larger floating surfaces such
  /// as the composer.
  @ViewBuilder
  func cregGlassRounded(cornerRadius: CGFloat = 24) -> some View {
    #if os(iOS)
      self.glassEffect(
        .regular, in: RoundedRectangle(cornerRadius: cornerRadius))
    #else
      self.background(
        .ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
    #endif
  }

  /// Tinted interactive glass for the primary Send/Stop control.
  @ViewBuilder
  func cregGlassProminent(tint: Color) -> some View {
    #if os(iOS)
      self.glassEffect(.regular.tint(tint).interactive(), in: .circle)
    #else
      self.background(tint.opacity(0.85), in: Circle())
    #endif
  }

  /// Participates in glass morphing on iOS; inert on the macOS fallback.
  @ViewBuilder
  func cregGlassID(
    _ id: some Hashable & Sendable, in namespace: Namespace.ID
  ) -> some View {
    #if os(iOS)
      self.glassEffectID(id, in: namespace)
    #else
      self
    #endif
  }

  /// iOS-only inline title mode; no-op on macOS (the package also builds for
  /// macOS so `swift test` can run the feature tests).
  @ViewBuilder
  func inlineNavigationTitle() -> some View {
    #if os(iOS)
      self.navigationBarTitleDisplayMode(.inline)
    #else
      self
    #endif
  }
}
