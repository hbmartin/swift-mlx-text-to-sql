import ComposableArchitecture
import SwiftUI

/// The Conversation Browser revealed behind the chat: CREG, search, New Chat,
/// Recents, and Settings. Rows carry title, latest-message preview, relative
/// activity time, unread dot, and running/queued state.
struct ConversationBrowserView: View {
  @Bindable var store: StoreOf<AppFeature>
  /// Fixed for previews; live rendering uses the current date.
  var now: Date = Date()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("CREG")
        .font(.largeTitle.bold())
        .padding(.horizontal, 20)
        .padding(.top, 8)

      searchField

      Button {
        store.send(.newChatTapped)
      } label: {
        Label("New Chat", systemImage: "square.and.pencil")
          .font(.body.weight(.medium))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 8)

      if isSearching {
        searchResults
      } else {
        recents
      }

      Spacer(minLength: 0)

      Button {
        store.isSettingsPresented = true
      } label: {
        Label("Settings", systemImage: "gearshape")
          .font(.body)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 8)
      .padding(.bottom, 8)
    }
    .frame(maxHeight: .infinity, alignment: .top)
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
      if isSearching {
        Button {
          store.browserSearchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    .padding(.horizontal, 16)
  }

  private var recents: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Recents")
        .font(.footnote.weight(.semibold))
        .textCase(.uppercase)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
      ScrollView {
        LazyVStack(spacing: 2) {
          ForEach(store.conversations) { summary in
            ConversationRow(
              summary: summary,
              isSelected: store.chat?.conversationID == summary.id,
              isRunning: store.activeTurn?.conversationID == summary.id,
              queuedCount: store.queue
                .count { $0.conversationID == summary.id },
              now: now,
              select: { store.send(.conversationSelected(summary.id)) },
              delete: {
                store.send(.deleteConversationTapped(summary.id))
              })
          }
        }
        .padding(.horizontal, 8)
      }
    }
  }

  private var searchResults: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 2) {
        if store.searchHits.isEmpty {
          Text("No matches")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
        ForEach(store.searchHits) { hit in
          Button {
            store.send(.conversationSelected(hit.conversationID))
          } label: {
            VStack(alignment: .leading, spacing: 3) {
              Text(hit.title.isEmpty ? "New Chat" : hit.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
              Text(hit.snippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 8)
    }
  }
}

struct ConversationRow: View {
  let summary: ConversationSummary
  let isSelected: Bool
  let isRunning: Bool
  let queuedCount: Int
  let now: Date
  let select: () -> Void
  let delete: () -> Void

  var body: some View {
    Button(action: select) {
      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(summary.displayTitle)
              .font(.subheadline.weight(.medium))
              .lineLimit(1)
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
              .lineLimit(2)
          }
        }
        Spacer(minLength: 4)
        VStack(alignment: .trailing, spacing: 4) {
          Text(relativeTime)
            .font(.caption2)
            .foregroundStyle(.secondary)
          if summary.isUnread {
            Circle()
              .fill(CREGBrand.turquoise)
              .frame(width: 9, height: 9)
              .accessibilityLabel("Unread")
          }
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(minHeight: 44)
      .background(
        isSelected ? CREGBrand.blue.opacity(0.12) : .clear,
        in: RoundedRectangle(cornerRadius: 12))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button(role: .destructive, action: delete) {
        Label("Delete", systemImage: "trash")
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var relativeTime: String {
    let interval = now.timeIntervalSince(summary.lastActivityAt)
    if interval < 60 { return "Now" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: summary.lastActivityAt, relativeTo: now)
  }
}
