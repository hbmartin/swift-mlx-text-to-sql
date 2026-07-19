import CREGEngine
import ComposableArchitecture
import SwiftUI

public struct ChatView: View {
  @Bindable var store: StoreOf<ChatFeature>

  public init(store: StoreOf<ChatFeature>) {
    self.store = store
  }

  public var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            if store.messages.isEmpty && !store.isProcessing {
              emptyState
            }
            ForEach(store.messages) { message in
              MessageCell(message: message, developerMode: store.developerMode)
                .id(message.id)
            }
            if store.isProcessing {
              ThinkingCell(trace: store.currentTrace)
                .id("thinking")
            }
          }
          .padding(.horizontal)
          .padding(.top, 8)
        }
        .onChange(of: store.messages.count) {
          if let last = store.messages.last?.id {
            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
          }
        }
        .onChange(of: store.currentTrace.count) {
          if store.isProcessing {
            withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
          }
        }
      }
      composer
    }
    .navigationTitle("CREG")
    .inlineNavigationTitle()
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          store.isSettingsPresented = true
        } label: {
          Image(systemName: "gearshape")
        }
      }
    }
    .sheet(isPresented: $store.isSettingsPresented) {
      SettingsView(store: store)
    }
    .onAppear { store.send(.onAppear) }
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Ask about your portfolio")
        .font(.headline)
      Text("Try: “Which properties have the highest vacancy?”, “What's my rent roll by property type?”, or “Which leases expire in the next 12 months?”")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    .padding(.top, 24)
  }

  private var composer: some View {
    HStack(spacing: 8) {
      TextField("Ask about your portfolio…", text: $store.composerText, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .lineLimit(1...4)
        .onSubmit { store.send(.sendTapped) }
      Button {
        store.send(.sendTapped)
      } label: {
        Image(systemName: "arrow.up.circle.fill")
          .font(.title2)
      }
      .disabled(
        store.isProcessing
          || store.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(.bar)
  }
}

struct MessageCell: View {
  let message: ChatMessage
  let developerMode: Bool

  var body: some View {
    switch message.role {
    case .user:
      userBubble
    case .assistant:
      assistantCell
    }
  }

  private var userBubble: some View {
    HStack {
      Spacer(minLength: 48)
      Text(text)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.tint, in: RoundedRectangle(cornerRadius: 18))
        .foregroundStyle(.white)
    }
  }

  @ViewBuilder
  private var assistantCell: some View {
    VStack(alignment: .leading, spacing: 8) {
      switch message.body {
      case .text(let body), .clarification(let body):
        assistantBubble(body)
      case .failure(let body):
        Label(body, systemImage: "exclamationmark.triangle")
          .padding(.horizontal, 14)
          .padding(.vertical, 9)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
      case .answer(let result, let narration, let sql):
        assistantBubble(narration)
        ResultTableView(result: result)
        if developerMode {
          Text(sql)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
      }
      if !message.traceSteps.isEmpty {
        TraceView(steps: message.traceSteps)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func assistantBubble(_ body: String) -> some View {
    Text(body)
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
  }

  private var text: String {
    switch message.body {
    case .text(let body), .clarification(let body), .failure(let body): body
    case .answer(_, let narration, _): narration
    }
  }
}

struct ThinkingCell: View {
  let trace: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        ProgressView()
        Text(trace.last ?? "Thinking…")
          .foregroundStyle(.secondary)
          .contentTransition(.opacity)
      }
      .font(.subheadline)
    }
    .padding(.vertical, 4)
  }
}

extension View {
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

struct TraceView: View {
  let steps: [String]

  var body: some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
          Label(step, systemImage: "checkmark")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    } label: {
      Text("How I answered")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
  }
}
