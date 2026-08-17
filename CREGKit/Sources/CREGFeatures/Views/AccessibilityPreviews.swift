import AutoTableCharts
import CREGEngine
import ComposableArchitecture
import Foundation
import SwiftUI

#if DEBUG
  private struct AccessibilityPreviewFrame: View {
    let scenario: AccessibilityUITestConfiguration.Scenario
    let size: DynamicTypeSize

    var body: some View {
      AccessibilityScenarioView(scenario: scenario)
        .environment(\.dynamicTypeSize, size)
    }
  }

  #Preview("Chat — Empty — AX1") {
    AccessibilityPreviewFrame(scenario: .emptyChat, size: .accessibility1)
  }

  #Preview("Chat — Empty — AX3") {
    AccessibilityPreviewFrame(scenario: .emptyChat, size: .accessibility3)
  }

  #Preview("Chat — Empty — AX5") {
    AccessibilityPreviewFrame(scenario: .emptyChat, size: .accessibility5)
  }

  #Preview("Chat — Answered — AX1") {
    AccessibilityPreviewFrame(scenario: .answeredChat, size: .accessibility1)
  }

  #Preview("Chat — Answered — AX3") {
    AccessibilityPreviewFrame(scenario: .answeredChat, size: .accessibility3)
  }

  #Preview("Chat — Answered — AX5") {
    AccessibilityPreviewFrame(scenario: .answeredChat, size: .accessibility5)
  }

  #Preview("Chat — Answered — AX5 — Dark") {
    AccessibilityPreviewFrame(scenario: .answeredChat, size: .accessibility5)
      .preferredColorScheme(.dark)
  }

  #Preview("Chat — Processing and Queue — AX1") {
    AccessibilityPreviewFrame(scenario: .processingQueue, size: .accessibility1)
  }

  #Preview("Chat — Processing and Queue — AX3") {
    AccessibilityPreviewFrame(scenario: .processingQueue, size: .accessibility3)
  }

  #Preview("Chat — Processing and Queue — AX5") {
    AccessibilityPreviewFrame(scenario: .processingQueue, size: .accessibility5)
  }

  #Preview("Chat — Error — AX1") {
    AccessibilityPreviewFrame(scenario: .error, size: .accessibility1)
  }

  #Preview("Chat — Error — AX3") {
    AccessibilityPreviewFrame(scenario: .error, size: .accessibility3)
  }

  #Preview("Chat — Error — AX5") {
    AccessibilityPreviewFrame(scenario: .error, size: .accessibility5)
  }

  #Preview("Chat — Recovery — AX1") {
    AccessibilityPreviewFrame(scenario: .recovery, size: .accessibility1)
  }

  #Preview("Chat — Recovery — AX3") {
    AccessibilityPreviewFrame(scenario: .recovery, size: .accessibility3)
  }

  #Preview("Chat — Recovery — AX5") {
    AccessibilityPreviewFrame(scenario: .recovery, size: .accessibility5)
  }

  #Preview("Conversation Browser — AX1") {
    AccessibilityPreviewFrame(scenario: .browser, size: .accessibility1)
  }

  #Preview("Conversation Browser — AX3") {
    AccessibilityPreviewFrame(scenario: .browser, size: .accessibility3)
  }

  #Preview("Conversation Browser — AX5") {
    AccessibilityPreviewFrame(scenario: .browser, size: .accessibility5)
  }

  #Preview("Settings — App Icon Picker — AX1") {
    AccessibilityPreviewFrame(scenario: .settings, size: .accessibility1)
  }

  #Preview("Settings — App Icon Picker — AX3") {
    AccessibilityPreviewFrame(scenario: .settings, size: .accessibility3)
  }

  #Preview("Settings — App Icon Picker — AX5") {
    AccessibilityPreviewFrame(scenario: .settings, size: .accessibility5)
  }

  #Preview("Settings — App Icon Picker — AX5 — Dark") {
    AccessibilityPreviewFrame(scenario: .settings, size: .accessibility5)
      .preferredColorScheme(.dark)
  }

  #Preview("Transient Banners — AX1") {
    AccessibilityPreviewFrame(scenario: .transientBanners, size: .accessibility1)
  }

  #Preview("Transient Banners — AX3") {
    AccessibilityPreviewFrame(scenario: .transientBanners, size: .accessibility3)
  }

  #Preview("Transient Banners — AX5") {
    AccessibilityPreviewFrame(scenario: .transientBanners, size: .accessibility5)
  }

  #if os(iOS)
    #Preview("Chat — Answered — AX5 — Landscape") {
      AccessibilityPreviewFrame(scenario: .answeredChat, size: .accessibility5)
        .previewInterfaceOrientation(.landscapeLeft)
    }

    #Preview("Conversation Browser — AX5 — Landscape") {
      AccessibilityPreviewFrame(scenario: .browser, size: .accessibility5)
        .previewInterfaceOrientation(.landscapeLeft)
    }
  #endif
#endif
