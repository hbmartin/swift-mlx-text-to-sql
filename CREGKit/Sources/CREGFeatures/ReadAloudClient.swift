import AVFoundation
import ComposableArchitecture
import Foundation

// MARK: - Read Aloud

/// Narration-only speech playback with play/pause/stop. The stream finishes
/// when the utterance completes; cancellation stops speech.
public struct ReadAloudClient: Sendable {
  public enum Event: Sendable, Equatable {
    case finished
  }

  public var speak: @Sendable (String) -> AsyncStream<Event>
  public var pause: @Sendable () async -> Void
  public var resume: @Sendable () async -> Void
  public var stop: @Sendable () async -> Void

  public init(
    speak: @escaping @Sendable (String) -> AsyncStream<Event>,
    pause: @escaping @Sendable () async -> Void,
    resume: @escaping @Sendable () async -> Void,
    stop: @escaping @Sendable () async -> Void
  ) {
    self.speak = speak
    self.pause = pause
    self.resume = resume
    self.stop = stop
  }
}

extension ReadAloudClient {
  public static func live() -> ReadAloudClient {
    let speaker = NarrationSpeaker()
    return ReadAloudClient(
      speak: { text in
        AsyncStream { continuation in
          Task { @MainActor in
            speaker.speak(text) {
              continuation.yield(.finished)
              continuation.finish()
            }
          }
          continuation.onTermination = { _ in
            Task { @MainActor in speaker.stop() }
          }
        }
      },
      pause: { await speaker.pause() },
      resume: { await speaker.resume() },
      stop: { await speaker.stop() }
    )
  }

  /// Silent playback that stays "playing" until stopped or cancelled, so
  /// reducer tests can assert intermediate Read Aloud states.
  public static let noop = ReadAloudClient(
    speak: { _ in AsyncStream { _ in } },
    pause: {},
    resume: {},
    stop: {}
  )
}

@MainActor
private final class NarrationSpeaker: NSObject, AVSpeechSynthesizerDelegate {
  private let synthesizer = AVSpeechSynthesizer()
  private var onFinish: (() -> Void)?

  nonisolated override init() {
    super.init()
  }

  func speak(_ text: String, onFinish: @escaping () -> Void) {
    synthesizer.stopSpeaking(at: .immediate)
    self.onFinish = onFinish
    synthesizer.delegate = self
    synthesizer.speak(AVSpeechUtterance(string: text))
  }

  func pause() {
    synthesizer.pauseSpeaking(at: .word)
  }

  func resume() {
    synthesizer.continueSpeaking()
  }

  func stop() {
    onFinish = nil
    synthesizer.stopSpeaking(at: .immediate)
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didFinish utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in
      let finish = self.onFinish
      self.onFinish = nil
      finish?()
    }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didCancel utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in
      self.onFinish = nil
    }
  }
}

extension ReadAloudClient: DependencyKey {
  public static var testValue: ReadAloudClient { .noop }
  public static var liveValue: ReadAloudClient { .live() }
}
