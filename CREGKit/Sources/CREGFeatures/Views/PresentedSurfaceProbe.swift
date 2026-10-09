import SwiftUI

extension View {
  @ViewBuilder func cregPresentedSurfaceProbe() -> some View {
    #if DEBUG
      self.overlay(alignment: .topLeading) { PresentedSurfaceProbe() }
    #else
      self
    #endif
  }
}

#if DEBUG
  private struct PresentedSurfaceProbe: View {
    @Environment(\.dynamicTypeSize) private var size
    var body: some View {
      if AccessibilityUITestConfiguration.currentRequest != nil {
        Color.clear.frame(width: 1, height: 1)
          .accessibilityElement()
          .accessibilityLabel(String(describing: size))
          .accessibilityIdentifier("ui-test-effective-dynamic-type")
          .allowsHitTesting(false)
      }
    }
  }
#endif
