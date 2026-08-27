import CREGEngine
import Combine
import ComposableArchitecture
import SwiftUI

#if os(iOS)
  import UIKit
#endif

/// The feature shell accepts a lazy store factory so accessibility and
/// unsupported-device paths never construct the live model graph.
public struct RootView: View {
  private let storeFactory: @MainActor () -> StoreOf<AppFeature>

  public init(
    storeFactory: @escaping @MainActor () -> StoreOf<AppFeature>
  ) {
    self.storeFactory = storeFactory
  }

  /// Hardware below the `DeviceCapability` floor never reaches
  /// `AppRootView`. The factory is not invoked on either alternate path.
  @ViewBuilder
  public var body: some View {
    #if DEBUG
      if let request = AccessibilityUITestConfiguration.currentRequest {
        switch request {
        case .scenario(let configuration):
          AccessibilityUITestRootView(configuration: configuration)
        case .scenarioManifest:
          AccessibilityUITestScenarioManifestView()
        }
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
      AppRootView(store: storeFactory())
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
  @Dependency(\.chartAnalysis) private var chartAnalysis
  /// Fixed by previews; live rendering uses the current date.
  var now: Date = Date()
  /// In-flight gesture translation, composed with the settled reveal state.
  @State private var dragTranslation: CGFloat = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  /// The scheme actually in force. With no override applied this is the
  /// device's own setting, which is what `.system` needs to hand a sheet.
  @Environment(\.colorScheme) private var systemColorScheme
  @Environment(\.scenePhase) private var scenePhase

  /// The browser reveals ~80% of the width, capped near 340 points.
  static func revealWidth(for containerWidth: CGFloat) -> CGFloat {
    min(containerWidth * 0.8, 340)
  }

  /// `.inactive` covers momentary interruptions (Control Center, the app
  /// switcher, system dialogs) as well as the instant before backgrounding,
  /// so it only gates new low-priority starts; the destructive teardown of
  /// in-flight inference waits for a real `.background` transition.
  static func lifecycleAction(for phase: ScenePhase) -> AppFeature.Action? {
    switch phase {
    case .active:
      .appBecameActive
    case .inactive:
      .appBecameInactive
    case .background:
      .appEnteredBackground
    @unknown default:
      nil
    }
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
      // `initial: true` delivers the launch phase itself: a prewarmed or
      // background launch never transitions, and `isSceneActive` defaults to
      // true, so without it the inference gates would treat an invisible
      // scene as active.
      .onChange(of: scenePhase, initial: true) { _, phase in
        if let action = Self.lifecycleAction(for: phase) {
          store.send(action)
        }
      }
    }
    // Applied at the root rather than per-surface so the override reaches the
    // Settings sheet and the browser drawer too. `.system` resolves to nil,
    // which leaves the device's own setting in charge.
    .preferredColorScheme(store.appearance.colorScheme)
    .onChange(of: store.chat?.conversationID) { previous, current in
      guard previous != nil, previous != current else { return }
      Task { await chartAnalysis.trimToMinimum() }
    }
    #if os(iOS)
      .onReceive(
        NotificationCenter.default.publisher(
          for: UIApplication.didReceiveMemoryWarningNotification)
      ) { _ in
        Task { await chartAnalysis.trimToMinimum() }
      }
    #endif
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
            fmAvailability: store.fmAvailability,
            modelPreparationReport: store.modelPreparationReport,
            developerMode: store.developerMode,
            resultTableTextSize: $store.resultTableTextSize,
            hasUnreadElsewhere: store.conversations.contains { $0.isUnread },
            debugModelIdentity: store.debugModelIdentity,
            presentedFailure: store.presentedFailure,
            dismissFailure: { store.send(.dismissFailure) },
            retryPreparation: { store.send(.retryPreparation) },
            retryCompatibilityPreparation: {
              store.send(.retryCompatibilityPreparation)
            }))
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
        Button {
          store.send(.undoDeleteTapped)
        } label: {
          Text("Undo")
            .cregTextButtonLabelTarget()
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
