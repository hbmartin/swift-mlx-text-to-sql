import ComposableArchitecture
import SwiftUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// The app's single entry point; owns the root store so the app shell
/// needs no TCA import.
public struct RootView: View {
  @MainActor
  static let store = Store(initialState: AppFeature.State()) {
    AppFeature()
  }

  public init() {}

  public var body: some View {
    AppRootView(store: Self.store)
  }
}

/// The reveal-behind hierarchy (ADR 0007): the Conversation Browser lives
/// visually behind the foreground chat. The browser button or a left-edge
/// swipe moves the chat right one-to-one with the gesture, rounds its leading
/// corners, and dims it slightly. The transition is velocity-aware,
/// interruptible, and reversible.
struct AppRootView: View {
  @Bindable var store: StoreOf<AppFeature>
  /// Fixed by previews; live rendering uses the current date.
  var now: Date = Date()
  /// In-flight gesture translation, composed with the settled reveal state.
  @State private var dragTranslation: CGFloat = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// The browser reveals ~80% of the width, capped near 340 points.
  static func revealWidth(for containerWidth: CGFloat) -> CGFloat {
    min(containerWidth * 0.8, 340)
  }

  var body: some View {
    GeometryReader { proxy in
      let revealWidth = Self.revealWidth(for: proxy.size.width)
      let offset = currentOffset(revealWidth: revealWidth)
      let progress = revealWidth > 0 ? offset / revealWidth : 0

      ZStack(alignment: .topLeading) {
        ConversationBrowserView(store: store, now: now)
          .frame(width: revealWidth)
          .frame(maxHeight: .infinity)
          .opacity(0.35 + 0.65 * progress)
          .accessibilityHidden(progress < 0.99)

        chatLayer(progress: progress)
          .offset(x: offset)
          .accessibilityHidden(progress > 0.01 && store.isBrowserRevealed)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(white: 0.06).ignoresSafeArea())
      .gesture(revealGesture(revealWidth: revealWidth))
      .overlay(alignment: .top) { answerReadyBanner }
      .overlay(alignment: .bottom) { undoDeletionToast }
      .sheet(isPresented: $store.isSettingsPresented) {
        SettingsView(store: store)
      }
      .onAppear { store.send(.onAppear) }
    }
  }

  private func currentOffset(revealWidth: CGFloat) -> CGFloat {
    let base: CGFloat = store.isBrowserRevealed ? revealWidth : 0
    return min(max(base + dragTranslation, 0), revealWidth)
  }

  @ViewBuilder
  private func chatLayer(progress: CGFloat) -> some View {
    let cornerRadius = 34 * progress
    ZStack {
      if let chatStore = store.scope(state: \.chat, action: \.chat) {
        ChatView(
          store: chatStore,
          chrome: ChatChrome(
            modelReadiness: store.modelReadiness,
            developerMode: store.developerMode,
            hasUnreadElsewhere: store.conversations.contains { $0.isUnread },
            debugModelIdentity: store.debugModelIdentity,
            presentedFailure: store.presentedFailure,
            dismissFailure: { store.send(.dismissFailure) },
            retryPreparation: { store.send(.retryPreparation) }))
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .background(Color(uiColorBackground).ignoresSafeArea())
    .clipShape(
      UnevenRoundedRectangle(
        topLeadingRadius: cornerRadius,
        bottomLeadingRadius: cornerRadius))
    .overlay {
      // Subtle dim over the translated chat; a tap or left swipe closes
      // along the same spatial path.
      UnevenRoundedRectangle(
        topLeadingRadius: cornerRadius,
        bottomLeadingRadius: cornerRadius
      )
      .fill(Color.black.opacity(0.18 * progress))
      .allowsHitTesting(store.isBrowserRevealed)
      .onTapGesture { setRevealed(false) }
      .accessibilityLabel("Close conversation browser")
      .accessibilityAddTraits(.isButton)
      .accessibilityHidden(!store.isBrowserRevealed)
    }
    .shadow(
      color: .black.opacity(0.25 * progress), radius: 18, x: -4, y: 0)
    .ignoresSafeArea(edges: .bottom)
  }

  private var uiColorBackground: Color {
    #if canImport(UIKit)
      Color(uiColor: .systemBackground)
    #else
      Color(nsColor: .windowBackgroundColor)
    #endif
  }

  /// Tracks the gesture one-to-one and projects release velocity to decide
  /// whether the browser settles open or closed.
  private func revealGesture(revealWidth: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 12, coordinateSpace: .local)
      .onChanged { value in
        if store.isBrowserRevealed {
          dragTranslation = min(0, value.translation.width)
        } else {
          // Opening is reserved for the leading edge so transcript swipes
          // stay free.
          guard value.startLocation.x < 44 else { return }
          dragTranslation = max(0, value.translation.width)
        }
      }
      .onEnded { value in
        let base: CGFloat = store.isBrowserRevealed ? revealWidth : 0
        guard dragTranslation != 0 || !store.isBrowserRevealed else {
          dragTranslation = 0
          return
        }
        let projected = base + value.predictedEndTranslation.width
        setRevealed(projected > revealWidth / 2)
      }
  }

  private func setRevealed(_ revealed: Bool) {
    let animation: Animation =
      reduceMotion
      ? .easeInOut(duration: 0.18)
      : .spring(response: 0.4, dampingFraction: 0.86)
    withAnimation(animation) {
      dragTranslation = 0
      if revealed {
        store.send(.browserButtonTapped)
      } else {
        store.send(.browserDismissTapped)
      }
    }
  }

  @ViewBuilder
  private var answerReadyBanner: some View {
    if let banner = store.answerReadyBanner {
      Button {
        store.send(.answerReadyBannerTapped)
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
          VStack(alignment: .leading, spacing: 1) {
            Text("Answer ready")
              .font(.subheadline.weight(.semibold))
            Text(banner.title)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .cregGlassCapsule(interactive: true)
      }
      .buttonStyle(.plain)
      .padding(.top, 4)
      .transition(.move(edge: .top).combined(with: .opacity))
      .accessibilityLabel("Answer ready in \(banner.title)")
    }
  }

  @ViewBuilder
  private var undoDeletionToast: some View {
    if let pending = store.pendingDeletion {
      HStack(spacing: 12) {
        Text("Deleted “\(pending.summary.displayTitle)”")
          .font(.subheadline)
          .lineLimit(1)
        Button("Undo") {
          store.send(.undoDeleteTapped)
        }
        .font(.subheadline.weight(.semibold))
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .cregGlassCapsule()
      .padding(.bottom, 8)
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }
}
