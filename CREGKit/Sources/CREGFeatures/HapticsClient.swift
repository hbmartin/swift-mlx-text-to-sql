import ComposableArchitecture
import Foundation

#if canImport(UIKit)
  import UIKit
#endif

// MARK: - Haptics

/// The light haptic accompanying a background Answer Ready completion.
public struct HapticsClient: Sendable {
  public var answerReady: @Sendable () async -> Void

  public init(answerReady: @escaping @Sendable () async -> Void) {
    self.answerReady = answerReady
  }
}

extension HapticsClient {
  public static let noop = HapticsClient(answerReady: {})

  public static func live() -> HapticsClient {
    HapticsClient(
      answerReady: {
        #if canImport(UIKit)
          await MainActor.run {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
          }
        #endif
      })
  }
}

extension HapticsClient: DependencyKey {
  public static var testValue: HapticsClient { .noop }
  public static var liveValue: HapticsClient { .live() }
}
