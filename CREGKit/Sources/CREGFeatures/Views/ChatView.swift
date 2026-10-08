import CREGEngine
import ComposableArchitecture
import SwiftUI

/// The Messages-style chat surface: floating glass header, open transcript,
/// and floating glass composer. Liquid Glass stays on the floating
/// interactive layer; the transcript itself is plain content.
struct ChatView: View {
  @Bindable var store: StoreOf<ChatFeature>
  let chrome: ChatChrome
  var answerSharePresented: (() -> Void)? = nil
  @State private var answerSharing = AnswerShareCoordinator()
  @FocusState private var composerIsFocused: Bool
  /// Sentinel at the end of the transcript, outside the `LazyVStack` so it is
  /// always realized. Scrolling to it lands exactly at the bottom no matter
  /// which cells the lazy stack has built, and — unlike a `ScrollPosition`
  /// value, which stops applying once it already equals the target edge — an
  /// imperative scroll runs on every tap.
  private static let bottomAnchor = "transcript-bottom"
  @State private var isNearBottom = true
  @State private var unseenMessageCount = 0
  @State private var isDeleteConfirmationPresented = false
  @Namespace private var glassNamespace
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    ScrollViewReader { proxy in
      transcript(proxy: proxy)
    }
    #if canImport(UIKit)
      .sheet(item: $answerSharing.presented, onDismiss: { answerSharing.reset() }) { share in
        AnswerActivitySheet(markdown: share.markdown)
      }
      .onChange(of: answerSharing.presented?.id) { _, id in
        if id != nil { answerSharePresented?() }
      }
    #endif
  }

  private var transcriptSnapshot: ChatTranscriptSnapshot {
    ChatTranscriptSnapshot(
      conversationID: store.conversationID,
      messages: store.messages,
      suggestionCount: store.followUpBatch?.suggestions.count ?? 0)
  }

  private func transcript(proxy: ScrollViewProxy) -> some View {
    ScrollView {
      VStack(spacing: 0) {
        LazyVStack(alignment: .leading, spacing: 14) {
          if let identity = chrome.debugModelIdentity {
            ExperimentalModelBanner(identity: identity)
          }
          if store.messages.isEmpty && store.queued.isEmpty && !store.isProcessing {
            EmptyChatState(
              isEnabled: chrome.modelReadiness == .ready
                && chrome.fmAvailability == .available,
              submit: { store.send(.starterQuestionTapped($0)) })
          }
          ForEach(store.messages) { message in
            MessageCell(
              message: message,
              feedback: store.feedback[message.id],
              readAloud: store.readAloud,
              developerMode: chrome.developerMode,
              store: store,
              shareRequested: { moreID, markdown in
                answerSharing.request(
                  conversationID: store.conversationID, moreID: moreID, markdown: markdown)
              },
              moreDismissed: { answerSharing.moreDidDismiss($0) }
            )
            .id(message.id)
          }
          ForEach(store.queued) { queued in
            QueuedQuestionCell(
              queued: queued,
              cancel: { store.send(.cancelQueuedTapped(queued.id)) })
          }
          if let processing = store.processing {
            ProcessingStatusRow(
              processing: processing,
              toggleExpansion: { store.send(.timelineExpansionToggled) })
          }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 12)

        Color.clear
          .frame(height: 1)
          .id(Self.bottomAnchor)
      }
    }
    .scrollDismissesKeyboard(.interactively)
    .onScrollGeometryChange(for: Bool.self) { geometry in
      // `visibleRect` already accounts for the header and composer content
      // insets, so this is the true distance to the end of the transcript —
      // composing `containerSize` with `contentInsets` by hand double-counts
      // the composer and leaves the pill showing at the bottom.
      geometry.contentSize.height - geometry.visibleRect.maxY < 80
    } action: { _, nearBottom in
      withAnimation(.snappy(duration: 0.25)) { isNearBottom = nearBottom }
      if nearBottom { unseenMessageCount = 0 }
    }
    .onChange(of: transcriptSnapshot) { previous, current in
      switch chatTranscriptScrollDecision(
        from: previous,
        to: current,
        isNearBottom: isNearBottom)
      {
      case .none:
        break
      case .scrollToBottom:
        unseenMessageCount = 0
        scrollToLatest(proxy: proxy)
      case .incrementUnseen(let count):
        unseenMessageCount += count
      }
    }
    .onChange(of: store.processing?.trace.count ?? 0) {
      if store.isProcessing, isNearBottom {
        scrollToLatest(proxy: proxy)
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) { header }
    .safeAreaInset(edge: .bottom, spacing: 0) { bottomStack(proxy: proxy) }
    .alert("Rename Conversation", isPresented: $store.isRenamePresented) {
      TextField("Title", text: $store.renameDraft)
      Button("Save") { store.send(.renameCommitted) }
      Button("Cancel", role: .cancel) {}
    }
    .confirmationDialog(
      "Delete this conversation?",
      isPresented: $isDeleteConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        store.send(.delegate(.deleteRequested))
      }
    }
    .onChange(of: store.conversationID) { answerSharing.reset() }
    .resultViewerPresentation(
      store: store,
      textSize: chrome.resultTableTextSize)
  }

  // MARK: Header

  @ViewBuilder
  private var header: some View {
    if dynamicTypeSize.isAccessibilitySize {
      VStack(spacing: 8) {
        HStack(spacing: 10) {
          browserButton
          Spacer(minLength: 0)
          newChatButton
        }
        conversationMenu(lineLimit: nil)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
    } else {
      HStack(spacing: 10) {
        browserButton
        Spacer(minLength: 0)
        conversationMenu(lineLimit: 2)
          .layoutPriority(1)
        Spacer(minLength: 0)
        newChatButton
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
    }
  }

  private var browserButton: some View {
    CREGGlassContainer(spacing: 10) {
      Button {
        store.send(.delegate(.openBrowser))
      } label: {
        Image(systemName: "sidebar.leading")
          .cregIconButtonTarget()
          .overlay(alignment: .topTrailing) {
            if chrome.hasUnreadElsewhere {
              Circle()
                .fill(CREGBrand.turquoise)
                .frame(width: 8, height: 8)
                .offset(x: -8, y: 9)
            }
          }
      }
      .cregGlassCapsule(interactive: true)
      .accessibilityLabel(
        chrome.hasUnreadElsewhere
          ? "Conversations, unread answers available" : "Conversations"
      )
      .cregLargeContentViewer(
        "Conversations", systemImage: "sidebar.leading")
    }
  }

  private var newChatButton: some View {
    CREGGlassContainer(spacing: 10) {
      Button {
        store.send(.delegate(.newChatRequested))
      } label: {
        Image(systemName: "square.and.pencil")
          .cregIconButtonTarget()
      }
      .cregGlassCapsule(interactive: true)
      .accessibilityLabel("New chat")
      .disabled(!chrome.canCreateConversation)
      .cregLargeContentViewer("New chat", systemImage: "square.and.pencil")
    }
  }

  private func conversationMenu(lineLimit: Int?) -> some View {
    // The overflow Menu stays outside morphing glass containers to avoid the
    // iOS 26.1 Menu-in-container morph break.
    Menu {
      Text(store.displayTitle)
      Button {
        store.send(.renameTapped)
      } label: {
        Label("Rename", systemImage: "pencil")
      }
      Button {
        store.send(.exportTapped)
      } label: {
        Label("Export JSONL", systemImage: "square.and.arrow.up")
      }
      Button(role: .destructive) {
        isDeleteConfirmationPresented = true
      } label: {
        Label("Delete", systemImage: "trash")
      }
    } label: {
      HStack(spacing: 6) {
        Text(store.displayTitle)
          .font(.headline)
          .lineLimit(lineLimit)
          .multilineTextAlignment(.center)
        Image(systemName: "chevron.down")
          .font(.caption2.weight(.semibold))
      }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 44)
        .cregGlassCapsule(interactive: true)
    }
    .accessibilityLabel("\(store.displayTitle), conversation actions")
  }

  // MARK: Bottom stack

  @ViewBuilder
  private func bottomStack(proxy: ScrollViewProxy) -> some View {
    VStack(spacing: 8) {
      // In the stack's normal flow rather than an overlay: `safeAreaInset`
      // insets the transcript's safe area but not its frame, so a floating
      // pill anchored to the scroll view lands beneath this stack.
      jumpToLatest(proxy: proxy)
      let summary = ChatNoticeSummary(store: store, chrome: chrome)
      if summary.count > 0 {
        Button(action: chrome.reviewNotices) {
          HStack {
            Image(systemName: "exclamationmark.bubble")
            Text(summary.title).lineLimit(1)
            Spacer(minLength: 4)
            Text("\(summary.count)").monospacedDigit()
            Image(systemName: "chevron.up")
          }
          .font(.callout)
          .frame(maxWidth: .infinity, minHeight: 44)
          .contentShape(Rectangle())
        }
        .accessibilityLabel("\(summary.accessibilityDescription), \(summary.count) conversation notices")
        .accessibilityIdentifier("conversation-notices")
      }
      composer
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 12)
  }

  private var composer: some View {
    // The container's spacing is the glass merge radius: keep it below the
    // stack's gap so the field and the Send control read as two controls
    // rather than blending into one blob.
    CREGGlassContainer(spacing: 6) {
      HStack(alignment: .bottom, spacing: 14) {
        TextField(
          "Ask about your portfolio…",
          text: $store.composerText,
          axis: .vertical
        )
        .lineLimit(1...5)
        .textFieldStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .disabled(
          chrome.modelReadiness != .ready
            || chrome.fmAvailability != .available)
        .focused($composerIsFocused)
        .onSubmit { requestSend() }
        .onChange(of: composerIsFocused) {
          if composerIsFocused, store.isSubmissionPending {
            store.send(.submissionRefocused)
            return
          }
          guard !composerIsFocused, store.isSubmissionPending else { return }
          Task { @MainActor in
            // Let SwiftUI commit the first-responder change before the reducer
            // clears the bound text and invalidates the keyboard's candidates.
            await Task.yield()
            guard !composerIsFocused else {
              store.send(.submissionRefocused)
              return
            }
            store.send(.submissionFocusSettled)
          }
        }
        .cregGlassRounded(cornerRadius: 24)
        .cregGlassID("composer-field", in: glassNamespace)

        if store.isProcessing {
          Button {
            store.send(.stopTapped)
          } label: {
            Image(systemName: "stop.fill")
              .foregroundStyle(.white)
              .cregIconButtonTarget(font: .body.weight(.semibold))
          }
          .cregGlassProminent(tint: .red)
          .cregGlassID("composer-primary", in: glassNamespace)
          .accessibilityLabel("Stop answering")
          .cregLargeContentViewer("Stop answering", systemImage: "stop.fill")
        } else {
          Button {
            requestSend()
          } label: {
            Image(systemName: "arrow.up")
              .foregroundStyle(.white)
              .cregIconButtonTarget(font: .body.weight(.semibold))
          }
          .cregGlassProminent(tint: CREGBrand.blue)
          .cregGlassID("composer-primary", in: glassNamespace)
          .disabled(
            store.isSubmissionPending
              || chrome.modelReadiness != .ready
              || chrome.fmAvailability != .available
              || store.composerText.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty
          )
          .accessibilityLabel("Send")
          .cregLargeContentViewer("Send", systemImage: "arrow.up")
        }
      }
    }
    .animation(.snappy(duration: 0.3), value: store.isProcessing)
  }

  @ViewBuilder
  private func jumpToLatest(proxy: ScrollViewProxy) -> some View {
    if !isNearBottom, !store.messages.isEmpty {
      // Interactive glass needs a `GlassEffectContainer` around it — every
      // other glass control here has one, and outside a container the effect
      // swallows the touch instead of forwarding it to the button. The
      // explicit content shape keeps the whole capsule tappable rather than
      // just the chevron glyph.
      CREGGlassContainer(spacing: 0) {
        Button {
          unseenMessageCount = 0
          scrollToLatest(proxy: proxy)
        } label: {
          HStack(spacing: 5) {
            if unseenMessageCount > 0 {
              Text("\(unseenMessageCount)")
            }
            Image(systemName: "chevron.down")
          }
          .font(.body.weight(.semibold))
          .padding(.horizontal, 12)
          .frame(minHeight: 44)
          .contentShape(.capsule)
          .cregGlassCapsule(interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
      }
      .transition(.scale.combined(with: .opacity))
      .accessibilityLabel(
        unseenMessageCount > 0
          ? "Jump to latest, \(unseenMessageCount) new" : "Jump to latest"
      )
      .cregLargeContentViewer("Jump to latest", systemImage: "chevron.down")
    }
  }

  private func scrollToLatest(proxy: ScrollViewProxy) {
    withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
  }

  private func requestSend() {
    guard
      !store.isSubmissionPending,
      !store.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }

    store.send(.submissionRequested)
    if composerIsFocused {
      // Dismiss the keyboard after a focus-safe send; the reducer commits
      // once focus resignation settles.
      composerIsFocused = false
    } else {
      store.send(.submissionFocusSettled)
    }
  }
}
