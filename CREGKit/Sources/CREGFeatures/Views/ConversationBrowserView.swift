import ComposableArchitecture
import SwiftUI

/// The Conversation Browser revealed behind the chat: CREG, search, New Chat,
/// Recents, and Settings. Rows carry title, latest-message preview, relative
/// activity time, unread dot, and running/queued state.
struct ConversationBrowserView: View {
  @Bindable var store: StoreOf<AppFeature>
  /// Fixed for previews; live rendering uses the current date.
  var now: Date = Date()
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @FocusState private var isSearchFocused: Bool

  var body: some View {
    let queuedCounts = Dictionary(store.queue.map { ($0.conversationID, 1) }, uniquingKeysWith: +)
    VStack(alignment: .leading, spacing: 12) {
      // Keep the focused field outside scrolling recovery content. Collapsing
      // the brand heading leaves room for controls above a landscape keyboard.
      if !isSearchFocused {
        Text("CREG")
          .font(.largeTitle.bold())
          .padding(.horizontal, 20)
          .padding(.top, 8)
      }
      searchField
      ViewThatFits(in: .vertical) {
        VStack(alignment: .leading, spacing: 12) {
          historyControls
          historyScroller(compact: false, queuedCounts: queuedCounts).frame(minHeight: 44)
          settingsButton
        }
        historyScroller(compact: true, queuedCounts: queuedCounts)
      }

    }
    .onChange(of: store.isBrowserRevealed) { _, revealed in
      if !revealed { isSearchFocused = false }
    }
  }

  private var historyControls: some View {
    VStack(alignment: .leading, spacing: 12) {
      if store.canRetryHistory || store.historySummaryPhase.isLoading {
        RetryHistoryButton(
          isLoading: store.historySummaryPhase.isLoading,
          retry: { store.send(.retryHistoryTapped) }, accessibilityID: "browser-history-retry",
          isRetry: store.historyLoadIsRetry, isSlow: store.slowHistoryRequestID != nil
        )
        .padding(.horizontal, 20)
      }
      Button {
        store.send(.newChatTapped)
      } label: {
        Label("New Chat", systemImage: "square.and.pencil")
          .font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 12).padding(.vertical, 10).cregTextButtonLabelTarget()
      }
      .buttonStyle(.plain).disabled(!store.canCreateConversation).padding(.horizontal, 8)
    }
  }
  private var settingsButton: some View {
    Button {
      store.isSettingsPresented = true
    } label: {
      Label("Settings", systemImage: "gearshape")
        .font(.body).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10).cregTextButtonLabelTarget()
    }
    .buttonStyle(.plain).padding(.horizontal, 8).padding(.bottom, 8)
  }

  private func historyScroller(compact: Bool, queuedCounts: [UUID: Int]) -> some View {
    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 2) {
        if compact {
          historyControls
          settingsButton
        }
        if isSearching {
          searchResults
        } else {
          Text("Recents").font(.footnote.weight(.semibold)).textCase(.uppercase)
            .foregroundStyle(.secondary).padding(.horizontal, 12)
          ForEach(store.visibleConversations) { summary in
            ConversationRow(
              summary: summary,
              isSelected: store.chat?.conversationID == summary.id,
              isRunning: store.activeTurn?.conversationID == summary.id,
              queuedCount: queuedCounts[summary.id, default: 0], now: now,
              select: { store.send(.conversationSelected(summary.id)) },
              delete: { store.send(.deleteConversationTapped(summary.id)) }
            )
            .equatable()
          }
        }
      }.padding(.horizontal, 8)
    }
    .scrollDismissesKeyboard(.never)
    .accessibilityIdentifier("browser-history-scroll")
  }

  private var isSearching: Bool {
    !store.browserSearchText
      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField("Search", text: $store.browserSearchText)
        .textFieldStyle(.plain)
        .focused($isSearchFocused)
      if isSearching {
        Button {
          store.browserSearchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
            .cregIconButtonTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
        .cregLargeContentViewer("Clear search", systemImage: "xmark.circle.fill")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    .padding(.horizontal, 16)
  }

  private var searchResults: some View {
    Group {
      if store.visibleSearchHits.isEmpty {
        Text("No matches")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 20)
          .padding(.top, 12)
      }
      ForEach(store.visibleSearchHits) { hit in
        Button {
          store.send(.conversationSelected(hit.conversationID))
        } label: {
          VStack(alignment: .leading, spacing: 3) {
            Text(hit.title.isEmpty ? "New Chat" : hit.title)
              .font(.subheadline.weight(.medium))
              .fixedSize(horizontal: false, vertical: true)
            Text(hit.snippet)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .frame(minHeight: 44)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
  }
}

@MainActor
struct ConversationRow: View, Equatable {
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.summary == rhs.summary && lhs.isSelected == rhs.isSelected && lhs.isRunning == rhs.isRunning
      && lhs.queuedCount == rhs.queuedCount && lhs.now == rhs.now
  }
  private static let dateFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
  }()
  let summary: ConversationSummary
  let isSelected: Bool
  let isRunning: Bool
  let queuedCount: Int
  let now: Date
  let select: () -> Void
  let delete: () -> Void
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    #if DEBUG
      let _ = DrawerRowProbe.render(summary.id)
    #endif
    Button(action: select) {
      CREGAccessibilityActionLayout(
        hStackAlignment: .top,
        horizontalSpacing: 10,
        accessibilitySpacing: 8,
        spacerMinLength: 4
      ) {
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(summary.displayTitle)
              .font(.subheadline.weight(.medium))
              .fixedSize(horizontal: false, vertical: true)
            if isRunning {
              ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Answering")
            } else if queuedCount > 0 {
              Text("Queued")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .accessibilityLabel("\(queuedCount) queued")
            }
          }
          if !summary.latestMessagePreview.isEmpty {
            Text(summary.latestMessagePreview)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      } actions: {
        HStack(spacing: 8) {
          Text(relativeTime)
            .font(.caption2)
            .foregroundStyle(.secondary)
          if summary.isUnread {
            Circle()
              .fill(CREGBrand.turquoise)
              .frame(width: 9, height: 9)
              .accessibilityLabel("Unread")
          }
          if dynamicTypeSize.isAccessibilitySize {
            Spacer(minLength: 0)
          }
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(minHeight: 44)
      .background(
        isSelected ? CREGBrand.blue.opacity(0.12) : .clear,
        in: RoundedRectangle(cornerRadius: 12)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button(role: .destructive, action: delete) {
        Label("Delete", systemImage: "trash")
      }
    }
    .accessibilityElement(children: .combine)
    #if DEBUG
      .onAppear { DrawerRowProbe.appear(summary.id) }
    #endif
  }

  private var relativeTime: String {
    let interval = now.timeIntervalSince(summary.lastActivityAt)
    if interval < 60 { return "Now" }
    return Self.dateFormatter.localizedString(for: summary.lastActivityAt, relativeTo: now)
  }
}
