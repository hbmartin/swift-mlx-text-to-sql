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

  @MainActor enum DrawerRowProbe {
    static var enabled = false
    static var realized: Set<UUID> = []
    static var renders: [UUID: Int] = [:]
    static func render(_ id: UUID) { if enabled { renders[id, default: 0] += 1 } }
    static func appear(_ id: UUID) { if enabled { realized.insert(id) } }
  }

  struct DrawerPerformanceProbe: View {
    let store: StoreOf<AppFeature>
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
          realized = DrawerRowProbe.realized.count
          renders = DrawerRowProbe.renders.values.reduce(0, +)
          if pendingCheck { settled = true }
          try? await Task.sleep(for: .milliseconds(200))
        }
      }
    }
  }
#endif
