import CREGEngine
import ComposableArchitecture
import SwiftUI

@MainActor
struct ChatNoticeSummary {
  var count: Int
  var title: String
  var accessibilityDescription: String
  init(store: StoreOf<ChatFeature>, chrome: ChatChrome) {
    count =
      chrome.ownedFailures.isEmpty
      ? (chrome.presentedFailure == nil ? 0 : 1) : chrome.ownedFailures.count
    let historyFailure =
      chrome.ownedFailures.contains { $0.failure.recovery == .retryHistory }
      || chrome.presentedFailure?.recovery == .retryHistory
    count += (chrome.historyIsLoading || (chrome.canRetryHistory && !historyFailure)) ? 1 : 0
    let openingFailure = chrome.ownedFailures.contains {
      if case .conversationOpening = $0.owner { true } else { false }
    }
    count += (chrome.retryOpening != nil && !openingFailure) ? 1 : 0
    count += store.interruptedTurns.count + (store.correctionContext == nil ? 0 : 1)
    count += chrome.exportPhase == nil ? 0 : 1
    if chrome.modelReadiness != .ready || chrome.modelPreparationReport?.mode == .compatibility {
      count += 1
    }
    if chrome.fmAvailability != .available { count += 1 }
    if let blocking = chrome.ownedFailures.first(where: {
      $0.failure.code == "turn_persistence_barrier_timed_out"
        || $0.failure.code == "turn_inference_drain_timed_out"
    }) {
      title = blocking.failure.title
    } else if chrome.modelReadiness != .ready {
      title =
        chrome.modelReadiness == .preparing ? "Preparing the SQL model" : "SQL model unavailable"
    } else if chrome.fmAvailability != .available {
      title = "Apple Intelligence unavailable"
    } else if case .ready = chrome.exportPhase {
      title = "Export ready"
    } else {
      title = "Conversation notices"
    }
    accessibilityDescription = title
    if chrome.ownedFailures.contains(where: {
      $0.failure.code == "turn_persistence_barrier_timed_out"
    }) {
      accessibilityDescription += ". New questions are paused while CREG saves this conversation."
    } else if chrome.ownedFailures.contains(where: {
      $0.failure.code == "turn_inference_drain_timed_out"
    }) {
      accessibilityDescription +=
        ". New questions are paused until the previous model operation finishes."
    } else if chrome.modelReadiness != .ready || chrome.fmAvailability != .available {
      accessibilityDescription += ". CREG cannot answer new questions yet."
    }
  }
}

struct ConversationNoticesPanel: View {
  let store: StoreOf<ChatFeature>
  let chrome: ChatChrome
  let close: () -> Void
  var body: some View {
    VStack(spacing: 0) {
      CREGAccessibilityActionLayout(horizontalSpacing: 12, accessibilitySpacing: 8) {
        Text("Conversation notices")
          .font(.headline)
          .fixedSize(horizontal: false, vertical: true)
          .frame(minHeight: 44, alignment: .leading)
          .accessibilityAddTraits(.isHeader)
      } actions: {
        Button(action: close) { Text("Done").frame(minWidth: 44).cregTextButtonLabelTarget() }
          .buttonStyle(.plain)
          .fixedSize(horizontal: true, vertical: true)
          .accessibilityIdentifier("conversation-notices-done")
      }.padding(16)
      Divider()
      ScrollView {
        ChatNoticesContent(store: store, chrome: chrome)
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityIdentifier("conversation-notices-scroll")
    }
    .presentationDetents([.large])
  }
}

struct ChatNoticesContent: View {
  @Bindable var store: StoreOf<ChatFeature>
  let chrome: ChatChrome
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var body: some View {
    VStack(spacing: 12) {
      if !chrome.ownedFailures.isEmpty {
        OwnedFailureBanners(
          failures: chrome.ownedFailures, developerMode: chrome.developerMode,
          dismiss: chrome.dismissOwnedFailure)
      } else if let failure = chrome.presentedFailure {
        FailureBanner(
          failure: failure,
          developerMode: chrome.developerMode,
          dismiss: chrome.dismissFailure)
      }
      if chrome.canRetryHistory || chrome.historyIsLoading {
        RetryHistoryButton(
          isLoading: chrome.historyIsLoading, retry: chrome.retryHistory,
          isRetry: chrome.historyLoadIsRetry)
      }
      if let retry = chrome.retryOpening {
        Button(action: retry) { Text("Retry opening conversation").cregTextButtonLabelTarget() }
          .accessibilityIdentifier("conversation-retry-opening")
      }
      readinessBanner
      fmAvailabilityBanner
      ForEach(Array(store.interruptedTurns.enumerated()), id: \.offset) { _, interrupted in
        let retryID = interrupted.journalID ?? interrupted.executionID
        InterruptedTurnBanner(
          interrupted: interrupted,
          retryQueued: retryID.map { store.queuedRetryJournalIDs.contains($0) }
            ?? false,
          retryInspecting: retryID.map { store.inspectingRetryJournalIDs.contains($0) } ?? false,
          askAgain: {
            if let id = interrupted.journalID {
              store.send(.askAgainTappedFor(id))
            } else {
              store.send(.askAgainTapped)
            }
          },
          cancelRetry: {
            if let retryID { store.send(.cancelQueuedRetryTapped(retryID)) }
          },
          dismiss: {
            if let id = interrupted.journalID {
              store.send(.interruptedDismissedFor(id))
            } else {
              store.send(.interruptedDismissed)
            }
          })
      }
      if let context = store.correctionContext {
        CorrectionContextBanner(
          context: context,
          dismiss: { store.send(.correctionDismissed) })
      }
      if let phase = chrome.exportPhase {
        switch phase {
        case .exporting: ProgressView("Exporting conversation…")
        case .ready:
          VStack(alignment: .leading, spacing: 8) {
            Text("Export ready").font(.headline)
            Button(action: chrome.shareExport) {
              Label("Share JSONL export", systemImage: "square.and.arrow.up")
                .cregTextButtonLabelTarget()
            }.accessibilityIdentifier("conversation-export-share")
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }
  @ViewBuilder
  private var readinessBanner: some View {
    switch chrome.modelReadiness {
    case .ready:
      if chrome.modelPreparationReport?.mode == .compatibility {
        let warningLayout =
          dynamicTypeSize.isAccessibilitySize
          ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
          : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        warningLayout {
          Label(
            "Compatibility mode — unevaluated results",
            systemImage: "wrench.and.screwdriver.fill"
          )
          .font(.callout)
          .foregroundStyle(.orange)
          if !dynamicTypeSize.isAccessibilitySize {
            Spacer()
          }
          Button {
            chrome.retryPreparation()
          } label: {
            Text("Retry evaluated")
              .cregTextButtonLabelTarget()
          }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .cregGlassRounded(cornerRadius: 16)
        .accessibilityIdentifier("compatibility-mode-warning")
      }
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
    case .failed(let failure):
      ModelPreparationFailureBanner(
        failure: failure,
        developerMode: chrome.developerMode,
        retry: chrome.retryPreparation,
        retryCompatibility:
          chrome.developerMode && failure.allowsCompatibilityRetry
          ? chrome.retryCompatibilityPreparation : nil)
    }
  }

  /// Apple Intelligence is required for every new turn (ADR 0011). The
  /// enable-AI case is the product's only designed no-FM surface; asset
  /// download is a transient state, and anything else renders honestly as
  /// unavailable.
  @ViewBuilder
  private var fmAvailabilityBanner: some View {
    if case .unavailable(let reason) = chrome.fmAvailability {
      switch reason {
      case .appleIntelligenceNotEnabled:
        Label(
          "Turn on Apple Intelligence in Settings › Apple Intelligence & Siri.",
          systemImage: "apple.intelligence"
        )
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .cregGlassRounded(cornerRadius: 16)
        .accessibilityIdentifier("apple-intelligence-callout")
      case .modelNotReady:
        HStack(spacing: 8) {
          ProgressView()
          Text("Preparing Apple Intelligence…")
            .font(.callout)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cregGlassRounded(cornerRadius: 16)
      case .deviceNotEligible, .other:
        Label(
          "Apple Intelligence is unavailable, so CREG can't answer right now.",
          systemImage: "exclamationmark.triangle"
        )
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cregGlassRounded(cornerRadius: 16)
      }
    }
  }

}
