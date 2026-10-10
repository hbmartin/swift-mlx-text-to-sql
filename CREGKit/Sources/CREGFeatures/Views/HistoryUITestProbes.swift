#if DEBUG
  import ComposableArchitecture
  import SwiftUI

  private struct UITestReduceMotionKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
  }
  extension EnvironmentValues {
    var cregUITestReduceMotion: Bool? {
      get { self[UITestReduceMotionKey.self] }
      set { self[UITestReduceMotionKey.self] = newValue }
    }
  }

  actor HeldUITestExport {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var calls = 0
    func export(_ id: UUID) async throws -> URL {
      calls += 1
      if calls == 1, !released { await withCheckedContinuation { continuation = $0 } }
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "creg-conversation-harness-\(UUID()).jsonl")
      try Data("{\"conversation\":\"\(id)\",\"snapshot\":\(calls)}\n".utf8).write(to: url)
      return url
    }
    func finish() {
      released = true
      continuation?.resume()
      continuation = nil
    }
  }

  private struct DrawerRowProbeKey: EnvironmentKey {
    static let defaultValue: DrawerRowProbe? = nil
  }
  extension EnvironmentValues {
    var cregDrawerRowProbe: DrawerRowProbe? {
      get { self[DrawerRowProbeKey.self] }
      set { self[DrawerRowProbeKey.self] = newValue }
    }
  }

  @MainActor final class DrawerRowProbe {
    var realized: Set<UUID> = []
    var renders: [UUID: Int] = [:]
    func render(_ id: UUID) { renders[id, default: 0] += 1 }
    func appear(_ id: UUID) { realized.insert(id) }
    func reset() { realized = []; renders = [:] }
  }

  struct DrawerPerformanceProbe: View {
    let store: StoreOf<AppFeature>
    @Environment(\.cregDrawerRowProbe) private var probe
    @State private var realized = 0
    @State private var renders = 0
    @State private var pendingCheck = false
    @State private var settled = false
    var body: some View {
      VStack {
        if settled { Text("Settled").accessibilityIdentifier("drawer-error-settled") }
        Text("\(realized)").accessibilityIdentifier("drawer-realized-count")
        Text("\(renders)").accessibilityIdentifier("drawer-render-count")
        Button("Inject unrelated error") {
          store.send(
            .operationFailed(
              .init(
                code: "harness_unrelated", title: "Unrelated error", message: "Test",
                diagnostic: "Test")))
          pendingCheck = true
        }.accessibilityIdentifier("drawer-inject-error").frame(minHeight: 44)
      }
      .task {
        while !Task.isCancelled {
          realized = probe?.realized.count ?? 0
          renders = probe?.renders.values.reduce(0, +) ?? 0
          if pendingCheck { settled = true }
          try? await Task.sleep(for: .milliseconds(200))
        }
      }
    }
  }
  private struct DrawerMotionProbeKey: EnvironmentKey {
    static let defaultValue: DrawerMotionProbe? = nil
  }
  extension EnvironmentValues {
    var cregDrawerMotionProbe: DrawerMotionProbe? {
      get { self[DrawerMotionProbeKey.self] }
      set { self[DrawerMotionProbeKey.self] = newValue }
    }
  }
  /// Captures actual interpolated presentation values, not the target offset.
  /// Owned by each gesture fixture; absent from ordinary DEBUG and release views.
  @MainActor final class DrawerMotionProbe {
    var previous: (offset: CGFloat, revealed: Bool)?
    var openingRollbackFrames = 0
    var closingRollbackFrames = 0
    var samples: [String] = []
    var startedAt = ProcessInfo.processInfo.systemUptime
    func reset() {
      previous = nil; openingRollbackFrames = 0; closingRollbackFrames = 0
      samples = []; startedAt = ProcessInfo.processInfo.systemUptime
    }
    func sample(_ offset: CGFloat, revealed: Bool, width: CGFloat) {
      if previous == nil || abs(offset - previous!.offset) > 0.01, samples.count < 160 {
        samples.append("\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)):\(Int(offset * 100))")
      }
      defer { previous = (offset, revealed) }
      guard let previous, previous.revealed == revealed, offset > 0, offset < width else { return }
      if !revealed && offset < previous.offset - 0.01 { openingRollbackFrames += 1 }
      if revealed && offset > previous.offset + 0.01 { closingRollbackFrames += 1 }
    }
  }
  nonisolated struct DrawerMotionCapture: AnimatableModifier {
    @Environment(\.cregDrawerMotionProbe) private var probe
    var offset: CGFloat
    let revealWidth: CGFloat
    let isRevealed: Bool
    var animatableData: CGFloat {
      get { offset }
      set { offset = newValue }
    }
    @MainActor func body(content: Content) -> some View {
      if let probe {
        let _ = probe.sample(offset, revealed: isRevealed, width: revealWidth)
        content.offset(x: offset).overlay(alignment: .topTrailing) {
          Color.clear.frame(width: 1, height: 1).accessibilityElement()
            .accessibilityLabel("\(probe.openingRollbackFrames),\(probe.closingRollbackFrames)|\(probe.samples.joined(separator: ","))")
            .accessibilityIdentifier("drawer-rollback-frames")
        }
      } else { content.offset(x: offset) }
    }
  }
#endif
