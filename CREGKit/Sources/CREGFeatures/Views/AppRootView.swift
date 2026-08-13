import CREGEngine
import ComposableArchitecture
import SwiftUI

/// The app's single entry point; owns the root store so the app shell
/// needs no TCA import.
public struct RootView: View {
  @MainActor
  static let store = Store(initialState: AppFeature.State()) {
    AppFeature()
  }

  public init() {}

  /// Hardware below the ``DeviceCapability`` floor never reaches
  /// ``AppRootView``. `store` is a `static let`, so leaving it unreferenced on
  /// this path means the reducer, `LiveDependencies`, and the 1.75 GB model
  /// load are never constructed at all.
  @ViewBuilder
  public var body: some View {
    #if DEBUG
      if let configuration = AccessibilityUITestConfiguration.current {
        AccessibilityUITestRootView(configuration: configuration)
      } else {
        liveRoot
      }
    #else
      liveRoot
    #endif
  }

  @ViewBuilder
  private var liveRoot: some View {
    if DeviceCapability.isCurrentDeviceSupported {
      AppRootView(store: Self.store)
    } else {
      UnsupportedDeviceView()
    }
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
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  /// The scheme actually in force. With no override applied this is the
  /// device's own setting, which is what `.system` needs to hand a sheet.
  @Environment(\.colorScheme) private var systemColorScheme

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
          // Behind the fade so the drawer itself stays solid while its
          // contents ease in with the reveal.
          .background(CREGBrand.browserPanel.ignoresSafeArea())
          .accessibilityHidden(progress < 0.99)

        chatLayer(progress: progress)
          .offset(x: offset)
          .accessibilityHidden(progress > 0.01 && store.isBrowserRevealed)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(CREGBrand.browserPanel.ignoresSafeArea())
      .gesture(revealGesture(revealWidth: revealWidth))
      .overlay(alignment: .top) { answerReadyBanner }
      .overlay(alignment: .bottom) { undoDeletionToast }
      .sheet(isPresented: $store.isSettingsPresented) {
        // The Appearance picker lives in this sheet, so it has to restyle
        // itself. A sheet is its own presentation: the root's preference
        // reaches it when it resolves to a scheme, but clearing that
        // preference back to nil leaves the presented sheet on the old
        // override, so it states the resolved scheme itself.
        SettingsView(store: store)
          .preferredColorScheme(
            store.appearance.colorScheme ?? systemColorScheme)
      }
      .onAppear { store.send(.onAppear) }
    }
    // Applied at the root rather than per-surface so the override reaches the
    // Settings sheet and the browser drawer too. `.system` resolves to nil,
    // which leaves the device's own setting in charge.
    .preferredColorScheme(store.appearance.colorScheme)
  }

  private func currentOffset(revealWidth: CGFloat) -> CGFloat {
    let base: CGFloat = store.isBrowserRevealed ? revealWidth : 0
    return min(max(base + dragTranslation, 0), revealWidth)
  }

  @ViewBuilder
  private func chatLayer(progress: CGFloat) -> some View {
    // The chat lays out inside the safe area — its header and composer depend
    // on the real insets — while its surface, dim, and shadow are painted
    // edge to edge behind it, so no backdrop shows through at the status bar
    // and the keyboard still lifts the composer.
    let shape = UnevenRoundedRectangle(
      topLeadingRadius: 34 * progress,
      bottomLeadingRadius: 34 * progress)
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
    .background {
      shape
        .fill(CREGBrand.chatSurface)
        .shadow(
          color: .black.opacity(0.25 * progress), radius: 18, x: -4, y: 0)
        .ignoresSafeArea()
    }
    .overlay {
      // Subtle dim over the translated chat; a tap or left swipe closes
      // along the same spatial path.
      shape
        .fill(Color.black.opacity(0.18 * progress))
        .ignoresSafeArea()
        .allowsHitTesting(store.isBrowserRevealed)
        .onTapGesture { setRevealed(false) }
        .accessibilityLabel("Close conversation browser")
        .accessibilityAddTraits(.isButton)
        .accessibilityHidden(!store.isBrowserRevealed)
    }
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
        let bannerLayout = dynamicTypeSize.isAccessibilitySize
          ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
          : AnyLayout(HStackLayout(spacing: 8))
        bannerLayout {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
          VStack(alignment: .leading, spacing: 1) {
            Text("Answer ready")
              .font(.subheadline.weight(.semibold))
            Text(banner.title)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
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
      let toastLayout = dynamicTypeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
        : AnyLayout(HStackLayout(spacing: 12))
      toastLayout {
        Text("Deleted “\(pending.summary.displayTitle)”")
          .font(.subheadline)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        Button("Undo") {
          store.send(.undoDeleteTapped)
        }
        .font(.subheadline.weight(.semibold))
        .cregTextButtonTarget()
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .cregGlassCapsule()
      .padding(.bottom, 8)
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }
}
