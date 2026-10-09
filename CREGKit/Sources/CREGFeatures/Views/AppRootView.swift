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
        case .invalidConfiguration:
          AccessibilityUITestInvalidConfigurationView()
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
  @GestureState private var drawerDrag = DrawerDragState()
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  #if DEBUG
    @Environment(\.cregUITestReduceMotion) private var testReduceMotion
    private var reduceMotion: Bool { testReduceMotion ?? systemReduceMotion }
  #else
    private var reduceMotion: Bool { systemReduceMotion }
  #endif
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  /// The scheme actually in force. With no override applied this is the
  /// device's own setting, which is what `.system` needs to hand a sheet.
  @Environment(\.colorScheme) private var systemColorScheme
  @Environment(\.scenePhase) private var scenePhase

  /// The browser reveals ~80% of the width, capped near 340 points.
  static func revealWidth(for containerWidth: CGFloat) -> CGFloat {
    min(containerWidth * 0.8, 340)
  }

  /// `.inactive` is the earliest reliable boundary before backgrounding.
  /// Without signed background GPU access, active MLX inference is cancelled
  /// there and its journaled question can be retried on activation.
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
      let sheetID = store.presentation?.id
      let offset = currentOffset(revealWidth: revealWidth)
      let progress = revealWidth > 0 ? offset / revealWidth : 0
      let chrome = chatChrome

      ZStack(alignment: .topLeading) {
        ConversationBrowserView(store: store, now: now)
          .frame(width: revealWidth)
          .frame(maxHeight: .infinity)
          .opacity(0.35 + 0.65 * progress)
          // Behind the fade so the drawer itself stays solid while its
          // contents ease in with the reveal.
          .background(CREGBrand.browserPanel.ignoresSafeArea(.container))
          .accessibilityElement(children: .contain)
          .accessibilityHidden(progress < 0.99)

        chatLayer(progress: progress, chrome: chrome)
          .offset(x: offset)
          .accessibilityElement(children: .contain)
          .accessibilityHidden(progress > 0.01 && store.isBrowserRevealed)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(CREGBrand.browserPanel.ignoresSafeArea(.container))
      .simultaneousGesture(revealGesture(revealWidth: revealWidth),
        isEnabled: store.presentation == nil && store.isSceneActive)
      .overlay(alignment: .top) { answerReadyBanner }
      .overlay(alignment: .bottom) { undoDeletionToast }
      .sheet(item: Binding(get: { store.presentation }, set: { value in
        if value == nil, let sheetID { store.send(.sheetDismissalRequested(sheetID)) }
      })) { presentation in
        Group {
          switch presentation {
          case .settings:
            SettingsView(store: store)
              .preferredColorScheme(store.appearance.colorScheme ?? systemColorScheme)
          case .notices(let id):
            if store.chat?.conversationID == id, let chatStore = store.scope(state: \.chat, action: \.chat) {
              ConversationNoticesPanel(store: chatStore, chrome: chrome,
                close: { store.send(.sheetDismissalRequested(presentation.id)) })
            }
          case .conversationExport(let export):
            if case .ready(let url) = export.phase { ExportShareSheet(url: url) }
          }
        }
        .cregPresentedSurfaceProbe()
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        .onDisappear {
          // A nested native share surface can cover this content while the
          // root presentation still owns its file.
          if store.presentation?.id != presentation.id {
            store.send(.sheetDismissed(presentation.id))
          }
        }
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

  private var chatChrome: ChatChrome {
    let failures = store.visibleFailures
    let export = store.chat.flatMap { store.conversationExports[$0.conversationID] }
    let discard: (() -> Void)? = export.flatMap { export in
      guard case .ready = export.phase, export.intent == .retained,
        store.presentedExportFiles[export.requestID] == nil else { return nil }
      return { store.send(.discardConversationExport(conversationID: export.conversationID, requestID: export.requestID)) }
    }
    return ChatChrome(
      modelReadiness: store.modelReadiness,
      fmAvailability: store.fmAvailability,
      modelPreparationReport: store.modelPreparationReport,
      developerMode: store.developerMode,
      resultTableTextSize: $store.resultTableTextSize,
      hasUnreadElsewhere: store.hasUnreadLiveConversation,
      debugModelIdentity: store.debugModelIdentity,
      presentedFailure: failures.last?.failure,
      dismissFailure: { store.send(.dismissFailure) },
      retryPreparation: { store.send(.retryPreparation) },
      retryCompatibilityPreparation: {
        store.send(.retryCompatibilityPreparation)
      },
      ownedFailures: failures,
      dismissOwnedFailure: { store.send(.dismissOwnedFailure($0)) },
      canRetryHistory: store.canRetryHistory,
      historyIsLoading: store.historySummaryPhase.isLoading,
      historyIsSlow: store.slowHistoryRequestID != nil,
      retryHistory: { store.send(.retryHistoryTapped) },
      retryOpening: store.conversationOpening?.phase == .failed
        ? { store.send(.retryConversationOpeningTapped) } : nil,
      canCreateConversation: store.canCreateConversation,
      historyLoadIsRetry: store.historyLoadIsRetry,
      reviewNotices: { store.send(.noticesTapped) },
      exportPhase: export?.phase,
      shareExport: {
        if let id = store.chat?.conversationID { store.send(.shareConversationExport(id)) }
      }, discardExport: discard)
  }

  private func currentOffset(revealWidth: CGFloat) -> CGFloat {
    let base: CGFloat = store.isBrowserRevealed ? revealWidth : 0
    return min(max(base + drawerDrag.translation, 0), revealWidth)
  }

  @ViewBuilder
  private func chatLayer(progress: CGFloat, chrome: ChatChrome) -> some View {
    // The chat lays out inside the safe area — its header and composer depend
    // on the real insets — while its surface, dim, and shadow are painted
    // edge to edge behind it, so no backdrop shows through at the status bar
    // and the keyboard still lifts the composer.
    let shape = UnevenRoundedRectangle(
      topLeadingRadius: 34 * progress,
      bottomLeadingRadius: 34 * progress)
    ZStack {
      if let chatStore = store.scope(state: \.chat, action: \.chat) {
        let conversationID = chatStore.conversationID
        ChatView(
          store: chatStore,
          chrome: chrome,
          retainPendingExport: { store.send(.conversationModalRequested(conversationID)) },
          answerMorePresented: { store.send(.answerMorePresented(conversationID: conversationID, presentationID: $0)) },
          answerMoreDismissed: { store.send(.answerMoreDismissed(conversationID: conversationID, presentationID: $0)) })
      } else {
        ConversationUnavailableView(
          failure: chrome.presentedFailure, developerMode: store.developerMode,
          dismissFailure: { store.send(.dismissFailure) },
          openBrowser: { store.send(.browserButtonTapped) },
          newChat: { store.send(.newChatTapped) },
          isLoading: store.isOpeningConversation, canCreate: store.canCreateConversation,
          retryHistory: store.canRetryHistory || store.historySummaryPhase.isLoading
            ? { store.send(.retryHistoryTapped) } : nil,
          retryOpening: store.conversationOpening?.phase == .failed
            ? { store.send(.retryConversationOpeningTapped) } : nil,
          historyIsLoading: store.historySummaryPhase.isLoading,
          historyLoadIsRetry: store.historyLoadIsRetry,
          historyIsSlow: store.slowHistoryRequestID != nil,
          ownedFailures: chrome.ownedFailures,
          dismissOwnedFailure: { store.send(.dismissOwnedFailure($0)) })
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
      // Handle successful release inside the gesture-state wrapper, before
      // it resets eligibility. Cancellation still resets without onEnded.
      .onEnded { value in
        guard store.presentation == nil, store.isSceneActive,
          drawerDrag.eligibility.canRelease(startX: value.startLocation.x,
          dx: value.translation.width, dy: value.translation.height, revealed: store.isBrowserRevealed)
        else { return }
        let base: CGFloat = store.isBrowserRevealed ? revealWidth : 0
        setRevealed(base + value.predictedEndTranslation.width > revealWidth / 2)
      }
      .updating($drawerDrag) { value, drag, _ in
        guard drag.eligibility.change(startX: value.startLocation.x,
          dx: value.translation.width, dy: value.translation.height, revealed: store.isBrowserRevealed) else {
          drag.translation = 0
          return
        }
        drag.translation = store.isBrowserRevealed ? min(0, value.translation.width) : max(0, value.translation.width)
      }
  }

  private var drawerAnimation: Animation {
    reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.4, dampingFraction: 0.86)
  }

  private func setRevealed(_ revealed: Bool) {
    _ = withAnimation(drawerAnimation) {
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
