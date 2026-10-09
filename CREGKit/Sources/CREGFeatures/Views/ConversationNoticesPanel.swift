import CREGEngine
import ComposableArchitecture
import SwiftUI

@MainActor
struct ChatNotice {
  enum ID: Hashable {
    case failure(AppFeature.FailureOwner)
    case genericFailure(String)
    case history, opening, sql, intelligence, export
    case interrupted(UUID?, UUID?, Date, String)
  }
  enum Kind {
    case failure(AppFeature.OwnedFailure)
    case genericFailure(FailurePresentation)
    case history, opening, sql, intelligence
    case interrupted(InterruptedTurn)
    case export
  }
  var kind: Kind
  var priority: Int
  var title: String
  var description: String
  var isError = false
  var id: ID {
    switch kind {
    case .failure(let owned): .failure(owned.owner)
    case .genericFailure(let failure): .genericFailure(failure.code)
    case .history: .history
    case .opening: .opening
    case .sql: .sql
    case .intelligence: .intelligence
    case .export: .export
    case .interrupted(let value):
      .interrupted(value.journalID, value.executionID, value.interruptedAt, value.question)
    }
  }

  static func items(store: StoreOf<ChatFeature>, chrome: ChatChrome) -> [Self] {
    var items: [Self] = []
    func failure(_ value: FailurePresentation, kind: Kind) -> Self {
      let blocking =
        value.code == "turn_persistence_barrier_timed_out"
        || value.code == "turn_inference_drain_timed_out"
      let progress = !value.isError
      return .init(
        kind: kind, priority: blocking ? 0 : (progress ? 5 : 2),
        title: value.title, description: value.title + ". " + value.message, isError: value.isError)
    }
    if chrome.ownedFailures.isEmpty {
      if let value = chrome.presentedFailure {
        items.append(failure(value, kind: .genericFailure(value)))
      }
    } else {
      items += chrome.ownedFailures.map { failure($0.failure, kind: .failure($0)) }
    }
    let hasHistory = items.contains {
      if case .failure(let owned) = $0.kind { return owned.failure.recovery == .retryHistory }
      if case .genericFailure(let value) = $0.kind { return value.recovery == .retryHistory }
      return false
    }
    if (chrome.historyIsLoading || chrome.canRetryHistory) && !hasHistory {
      items.append(
        .init(
          kind: .history, priority: 5,
          title: chrome.historyIsLoading ? "Loading history" : "History unavailable",
          description: chrome.historyIsLoading ? "Loading conversation history." : "Retry loading conversation history."))
    }
    if chrome.retryOpening != nil
      && !chrome.ownedFailures.contains(where: {
        if case .conversationOpening = $0.owner { true } else { false }
      })
    {
      items.append(
        .init(
          kind: .opening, priority: 2, title: "Conversation could not open",
          description: "Retry opening conversation.", isError: true))
    }
    switch chrome.modelReadiness {
    case .ready:
      if chrome.modelPreparationReport?.mode == .compatibility {
        items.append(
          .init(
            kind: .sql, priority: 1, title: "Compatibility mode",
            description: "Compatibility mode uses unevaluated results.", isError: true))
      }
    case .preparing:
      items.append(
        .init(
          kind: .sql, priority: 3, title: "Preparing the SQL model",
          description: "Preparing the SQL model."))
    case .failed(let value):
      let title = value.isPaused ? "SQL model preparation paused" : "SQL model unavailable"
      items.append(
        .init(
          kind: .sql, priority: 1, title: title,
          description: title + ". CREG cannot answer new questions yet.", isError: !value.isPaused))
    }
    if case .unavailable(let reason) = chrome.fmAvailability {
      let preparing = reason == .modelNotReady
      let title = preparing ? "Preparing Apple Intelligence" : "Apple Intelligence unavailable"
      items.append(
        .init(
          kind: .intelligence, priority: preparing ? 3 : 1, title: title,
          description: title + ". CREG cannot answer new questions yet.", isError: !preparing))
    }
    items += store.interruptedTurns.map {
      .init(
        kind: .interrupted($0), priority: 4,
        title: "Interrupted question", description: "An interrupted question can be asked again.")
    }
    if let phase = chrome.exportPhase {
      let title = phase == .exporting ? "Exporting conversation" : "Export ready"
      items.append(.init(kind: .export, priority: 6, title: title, description: title))
    }
    return items.enumerated().sorted { lhs, rhs in
      lhs.element.priority == rhs.element.priority
        ? lhs.offset < rhs.offset : lhs.element.priority < rhs.element.priority
    }.map(\.element)
  }
}

@MainActor
struct ChatNoticeSummary {
  var count: Int
  var title: String
  var accessibilityDescription: String
  var isError: Bool
  var symbol: String { isError ? "exclamationmark.bubble" : "info.bubble" }
  init(store: StoreOf<ChatFeature>, chrome: ChatChrome) {
    let items = ChatNotice.items(store: store, chrome: chrome)
    count = items.count
    title = items.first?.title ?? "Conversation notices"
    accessibilityDescription = items.first?.description ?? title
    isError = items.first?.isError ?? false
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
      ForEach(ChatNotice.items(store: store, chrome: chrome), id: \.id) { notice in
        switch notice.kind {
        case .failure(let owned):
          FailureBanner(
            failure: owned.failure, developerMode: chrome.developerMode,
            dismiss: { chrome.dismissOwnedFailure(owned.owner) })
          if owned.failure.recovery == .retryHistory { historyControl }
          if case .conversationOpening = owned.owner { openingControl }
        case .genericFailure(let failure):
          FailureBanner(
            failure: failure, developerMode: chrome.developerMode, dismiss: chrome.dismissFailure)
          if failure.recovery == .retryHistory { historyControl }
        case .history: historyControl
        case .opening: openingControl
        case .sql: readinessBanner
        case .intelligence: fmAvailabilityBanner
        case .interrupted(let interrupted): interruptionBanner(interrupted)
        case .export: exportContent
        }
      }
    }
  }

  private var historyControl: some View {
    RetryHistoryButton(
      isLoading: chrome.historyIsLoading, retry: chrome.retryHistory,
      isRetry: chrome.historyLoadIsRetry, isSlow: chrome.historyIsSlow)
  }
  @ViewBuilder private var openingControl: some View {
    if let retry = chrome.retryOpening {
      Button(action: retry) { Text("Retry opening conversation").cregTextButtonLabelTarget() }
        .accessibilityIdentifier("conversation-retry-opening")
    }
  }
  private func interruptionBanner(_ interrupted: InterruptedTurn) -> some View {
    let retryID = interrupted.journalID ?? interrupted.executionID
    return InterruptedTurnBanner(
      interrupted: interrupted,
      retryQueued: retryID.map { store.queuedRetryJournalIDs.contains($0) } ?? false,
      retryInspecting: retryID.map { store.inspectingRetryJournalIDs.contains($0) } ?? false,
      askAgain: {
        if let id = interrupted.journalID {
          store.send(.askAgainTappedFor(id))
        } else {
          store.send(.askAgainTapped)
        }
      },
      cancelRetry: { if let retryID { store.send(.cancelQueuedRetryTapped(retryID)) } },
      dismiss: {
        if let id = interrupted.journalID {
          store.send(.interruptedDismissedFor(id))
        } else {
          store.send(.interruptedDismissed)
        }
      })
  }
  @ViewBuilder private var exportContent: some View {
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
          if let discard = chrome.discardExport {
            Button(action: discard) {
              Label("Discard export", systemImage: "xmark.circle")
                .cregTextButtonLabelTarget()
            }.accessibilityIdentifier("conversation-export-discard")
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
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
