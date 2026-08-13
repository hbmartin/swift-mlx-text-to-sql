import CREGEngine
import ComposableArchitecture
import SwiftUI

/// App-level context the chat surface renders but does not own.
struct ChatChrome {
  var modelReadiness: AppFeature.ModelReadiness
  var developerMode: Bool
  var hasUnreadElsewhere: Bool
  var debugModelIdentity: DebugModelIdentity?
  var presentedFailure: FailurePresentation?
  var dismissFailure: () -> Void
  var retryPreparation: () -> Void
}

/// The minimum transcript state needed to distinguish a completed assistant
/// response from ordinary message growth. Counting assistant messages makes
/// the completion detectable even when the scheduler appends the next queued
/// user question in the same state update.
struct ChatTranscriptSnapshot: Equatable {
  var conversationID: UUID
  var messageCount: Int
  var assistantMessageCount: Int

  init<Messages: Sequence>(
    conversationID: UUID,
    messages: Messages
  ) where Messages.Element == ChatMessage {
    self.conversationID = conversationID
    var messageCount = 0
    var assistantMessageCount = 0
    for message in messages {
      messageCount += 1
      if message.role == .assistant {
        assistantMessageCount += 1
      }
    }
    self.messageCount = messageCount
    self.assistantMessageCount = assistantMessageCount
  }
}

enum ChatTranscriptScrollDecision: Equatable {
  case none
  case scrollToBottom
  case incrementUnseen(by: Int)
}

/// Pure policy kept outside `ChatView` so completion and queue-coalescing
/// behavior can be covered without relying on SwiftUI rendering timing.
func chatTranscriptScrollDecision(
  from previous: ChatTranscriptSnapshot,
  to current: ChatTranscriptSnapshot,
  isNearBottom: Bool
) -> ChatTranscriptScrollDecision {
  guard
    previous.conversationID == current.conversationID,
    current.messageCount > previous.messageCount
  else { return .none }

  if current.assistantMessageCount > previous.assistantMessageCount
    || isNearBottom
  {
    return .scrollToBottom
  }
  return .incrementUnseen(by: current.messageCount - previous.messageCount)
}

/// The Messages-style chat surface: floating glass header, open transcript,
/// and floating glass composer. Liquid Glass stays on the floating
/// interactive layer; the transcript itself is plain content.
struct ChatView: View {
  @Bindable var store: StoreOf<ChatFeature>
  let chrome: ChatChrome
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

  var body: some View {
    ScrollViewReader { proxy in
      transcript(proxy: proxy)
    }
  }

  private var transcriptSnapshot: ChatTranscriptSnapshot {
    ChatTranscriptSnapshot(
      conversationID: store.conversationID,
      messages: store.messages)
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
              isEnabled: chrome.modelReadiness == .ready,
              submit: { store.send(.starterQuestionTapped($0)) })
          }
          ForEach(store.messages) { message in
            MessageCell(
              message: message,
              feedback: store.feedback[message.id],
              readAloud: store.readAloud,
              developerMode: chrome.developerMode,
              store: store)
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
    .sheet(item: exportItem) { item in
      ExportShareSheet(url: item.url)
    }
    .resultViewerPresentation(store: store)
  }

  private var exportItem: Binding<ExportedFile?> {
    Binding(
      get: { store.exportURL.map(ExportedFile.init(url:)) },
      set: { if $0 == nil { store.exportURL = nil } })
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 10) {
      CREGGlassContainer(spacing: 10) {
        Button {
          store.send(.delegate(.openBrowser))
        } label: {
          Image(systemName: "sidebar.leading")
            .font(.body.weight(.medium))
            .frame(width: 44, height: 44)
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
            ? "Conversations, unread answers available" : "Conversations")
      }

      Spacer(minLength: 0)

      Text(store.displayTitle)
        .font(.headline)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .frame(height: 44)
        .cregGlassCapsule()
        .layoutPriority(1)

      Spacer(minLength: 0)

      CREGGlassContainer(spacing: 10) {
        Button {
          store.send(.delegate(.newChatRequested))
        } label: {
          Image(systemName: "square.and.pencil")
            .font(.body.weight(.medium))
            .frame(width: 44, height: 44)
        }
        .cregGlassCapsule(interactive: true)
        .accessibilityLabel("New chat")
      }

      // The overflow Menu stays outside morphing glass containers to avoid
      // the iOS 26.1 Menu-in-container morph break.
      Menu {
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
        Image(systemName: "ellipsis")
          .font(.body.weight(.medium))
          .frame(width: 44, height: 44)
          .cregGlassCapsule(interactive: true)
      }
      .accessibilityLabel("More")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }

  // MARK: Bottom stack

  @ViewBuilder
  private func bottomStack(proxy: ScrollViewProxy) -> some View {
    VStack(spacing: 8) {
      // In the stack's normal flow rather than an overlay: `safeAreaInset`
      // insets the transcript's safe area but not its frame, so a floating
      // pill anchored to the scroll view lands beneath this stack.
      jumpToLatest(proxy: proxy)
      if let failure = chrome.presentedFailure {
        FailureBanner(
          failure: failure,
          developerMode: chrome.developerMode,
          dismiss: chrome.dismissFailure)
      }
      readinessBanner
      if let interrupted = store.interruptedTurn {
        InterruptedTurnBanner(
          interrupted: interrupted,
          askAgain: { store.send(.askAgainTapped) },
          dismiss: { store.send(.interruptedDismissed) })
      }
      if let context = store.correctionContext {
        CorrectionContextBanner(
          context: context,
          dismiss: { store.send(.correctionDismissed) })
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
        .disabled(chrome.modelReadiness != .ready)
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
              .font(.body.weight(.semibold))
              .foregroundStyle(.white)
              .frame(width: 44, height: 44)
          }
          .cregGlassProminent(tint: .red)
          .cregGlassID("composer-primary", in: glassNamespace)
          .accessibilityLabel("Stop answering")
        } else {
          Button {
            requestSend()
          } label: {
            Image(systemName: "arrow.up")
              .font(.body.weight(.semibold))
              .foregroundStyle(.white)
              .frame(width: 44, height: 44)
          }
          .cregGlassProminent(tint: CREGBrand.blue)
          .cregGlassID("composer-primary", in: glassNamespace)
          .disabled(
            store.isSubmissionPending
              || chrome.modelReadiness != .ready
              || store.composerText.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty
          )
          .accessibilityLabel("Send")
        }
      }
    }
    .animation(.snappy(duration: 0.3), value: store.isProcessing)
  }

  @ViewBuilder
  private var readinessBanner: some View {
    switch chrome.modelReadiness {
    case .ready:
      EmptyView()
    case .preparing:
      HStack(spacing: 8) {
        ProgressView()
        Text("Preparing the SQL model…")
          .font(.callout)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .cregGlassRounded(cornerRadius: 16)
    case .failed(let message):
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.orange)
        Spacer()
        Button("Retry") { chrome.retryPreparation() }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .cregGlassRounded(cornerRadius: 16)
    }
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
                .font(.caption.weight(.bold))
            }
            Image(systemName: "chevron.down")
              .font(.caption.weight(.bold))
          }
          .padding(.horizontal, 12)
          .frame(height: 36)
          .contentShape(.capsule)
          .cregGlassCapsule(interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
      }
      .transition(.scale.combined(with: .opacity))
      .accessibilityLabel(
        unseenMessageCount > 0
          ? "Jump to latest, \(unseenMessageCount) new" : "Jump to latest")
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

// MARK: - Supporting cells

struct ExportedFile: Identifiable {
  var url: URL
  var id: URL { url }
}

private struct ExportShareSheet: View {
  let url: URL
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 16) {
      Text("Conversation events exported")
        .font(.headline)
      Text(
        "Structured JSONL for offline accuracy analysis. Exports include questions, generated SQL, errors, and full result rows; treat them as portfolio data."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
      ShareLink(item: url) {
        Label("Share JSONL", systemImage: "square.and.arrow.up")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      Button("Done") { dismiss() }
    }
    .padding(24)
    .presentationDetents([.medium])
  }
}

struct ExperimentalModelBanner: View {
  let identity: DebugModelIdentity

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Label("Experimental SQL model", systemImage: "testtube.2")
        .font(.caption.weight(.bold))
        .textCase(.uppercase)
      Text(
        "\(identity.baseModelKey) · iteration \(identity.selectedIteration) · run \(identity.trainingRunID.suffix(8))"
      )
      .font(.caption2.monospaced())
      Text("Local Debug evidence only — not production finalized")
        .font(.caption2)
    }
    .foregroundStyle(.orange)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    .accessibilityIdentifier("experimental-model-banner")
  }
}

struct EmptyChatState: View {
  let isEnabled: Bool
  let submit: (StarterQueryID) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Ask about your portfolio")
        .font(.title3.weight(.semibold))
        .padding(.top, 24)
      ForEach(StarterQueryID.allCases) { starter in
        Button {
          submit(starter)
        } label: {
          HStack {
            Text(starter.question)
              .font(.subheadline)
              .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Image(systemName: "arrow.up.right")
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 14)
          .padding(.vertical, 12)
          .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A submitted question waiting behind active work: styled like a user
/// bubble, visibly queued, and cancellable (ADR 0008).
struct QueuedQuestionCell: View {
  let queued: QueuedQuestion
  let cancel: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      Spacer(minLength: 48)
      VStack(alignment: .trailing, spacing: 4) {
        Text(queued.question)
          .padding(.horizontal, 14)
          .padding(.vertical, 9)
          .background(
            CREGBrand.userBubble.opacity(0.6),
            in: RoundedRectangle(cornerRadius: 18))
          .foregroundStyle(CREGBrand.userBubbleText)
        HStack(spacing: 6) {
          Text("Queued")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
          Button(action: cancel) {
            Image(systemName: "xmark.circle.fill")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Cancel queued question")
        }
      }
    }
    .accessibilityElement(children: .combine)
  }
}

/// Compact live status row with an expandable plain-English timeline; the
/// disclosure keeps SQL out per PRD §11.
struct ProcessingStatusRow: View {
  let processing: ChatFeature.ProcessingState
  let toggleExpansion: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button(action: toggleExpansion) {
        HStack(spacing: 8) {
          ProgressView()
          Text(processing.trace.last ?? "Thinking…")
            .foregroundStyle(.secondary)
            .contentTransition(.opacity)
            .lineLimit(1)
          Spacer(minLength: 4)
          ElapsedTimeText(since: processing.startedAt)
          Image(systemName: "chevron.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(
              .degrees(processing.isTimelineExpanded ? 180 : 0))
        }
        .font(.subheadline)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        "Working: \(processing.trace.last ?? "thinking"). \(processing.isTimelineExpanded ? "Collapse" : "Expand") timeline")

      if processing.isTimelineExpanded {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(Array(processing.trace.enumerated()), id: \.offset) { entry in
            Label(entry.element, systemImage: "checkmark")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.leading, 26)
        .transition(.opacity)
      }
    }
    .padding(.vertical, 4)
    .animation(.default, value: processing.isTimelineExpanded)
  }
}

/// Live elapsed readout for the in-flight turn.
struct ElapsedTimeText: View {
  let since: Date

  var body: some View {
    TimelineView(.periodic(from: since, by: 1)) { context in
      let seconds = max(0, Int(context.date.timeIntervalSince(since)))
      Text("\(seconds)s")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.tertiary)
    }
  }
}

struct InterruptedTurnBanner: View {
  let interrupted: InterruptedTurn
  let askAgain: () -> Void
  let dismiss: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Interrupted before it finished")
          .font(.footnote.weight(.semibold))
        Text(interrupted.question)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Spacer(minLength: 4)
      Button("Ask Again", action: askAgain)
        .font(.footnote.weight(.semibold))
      Button(action: dismiss) {
        Image(systemName: "xmark")
          .font(.caption.bold())
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss interrupted question")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .cregGlassRounded(cornerRadius: 16)
  }
}

struct CorrectionContextBanner: View {
  let context: ChatFeature.CorrectionContext
  let dismiss: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: "arrow.uturn.backward.circle")
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text("Tell CREG what was wrong")
          .font(.footnote.weight(.semibold))
        Text(context.answerNarration)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Spacer(minLength: 4)
      Button(action: dismiss) {
        Image(systemName: "xmark")
          .font(.caption.bold())
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss correction")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .cregGlassRounded(cornerRadius: 16)
  }
}
