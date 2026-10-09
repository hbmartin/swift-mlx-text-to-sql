import CREGEngine
import SwiftUI

/// The terminal screen shown instead of the app on hardware below the
/// `DeviceCapability` floor. It replaces the whole shell rather
/// than degrading the chat surface, because no part of the product works
/// without the on-device model.
struct UnsupportedDeviceView: View {
  @ScaledMetric(relativeTo: .title2) private var warningSymbolSize = 44.0

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: warningSymbolSize))
        .foregroundStyle(.orange)
      Text("Unsupported iPhone")
        .font(.title2.weight(.semibold))
      Text(DeviceCapability.requirementMessage)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(CREGBrand.chatSurface.ignoresSafeArea())
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("unsupported-device-wall")
  }
}

struct ConversationUnavailableView: View {
  let failure: FailurePresentation?
  let developerMode: Bool
  let dismissFailure: () -> Void
  let openBrowser: () -> Void
  let newChat: () -> Void
  var isLoading = false
  var canCreate = true
  var retryHistory: (() -> Void)?
  var retryOpening: (() -> Void)?
  var historyIsLoading = false
  var historyLoadIsRetry = false
  var historyIsSlow = false
  var ownedFailures: [AppFeature.OwnedFailure] = []
  var dismissOwnedFailure: (AppFeature.FailureOwner) -> Void = { _ in }

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        if !ownedFailures.isEmpty {
          OwnedFailureBanners(failures: ownedFailures, developerMode: developerMode, dismiss: dismissOwnedFailure)
        } else if let failure {
          FailureBanner(failure: failure, developerMode: developerMode, dismiss: dismissFailure)
            .accessibilityIdentifier("conversation-recovery-failure")
        }
        if isLoading {
          ProgressView("Opening conversation…")
            .accessibilityIdentifier("conversation-loading")
        } else if ownedFailures.isEmpty && failure == nil {
          Text(retryOpening != nil ? "Opening this conversation failed. Tap Retry opening to try again." : canCreate ? "Choose a conversation or start a new chat." : "History is unavailable. Tap Retry history to try again.")
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("conversation-recovery-idle")
        }
        if let retryHistory {
          RetryHistoryButton(isLoading: historyIsLoading, retry: retryHistory, isRetry: historyLoadIsRetry, isSlow: historyIsSlow)
        }
        if let retryOpening {
          Button(action: retryOpening) { Text("Retry opening conversation").cregTextButtonLabelTarget() }
            .accessibilityIdentifier("conversation-retry-opening")
        }
        Button(action: openBrowser) {
          Label("Conversations", systemImage: "sidebar.left")
            .cregTextButtonLabelTarget()
        }
        .accessibilityIdentifier("conversation-recovery-browser")
        Button(action: newChat) {
          Label("New chat", systemImage: "square.and.pencil")
            .cregTextButtonLabelTarget()
        }
        .disabled(!canCreate)
        .accessibilityIdentifier("conversation-recovery-new-chat")
      }
      .buttonStyle(.bordered)
      .padding(24)
      .frame(maxWidth: .infinity)
    }
    .accessibilityIdentifier("conversation-recovery-scroll")
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct OwnedFailureBanners: View {
  let failures: [AppFeature.OwnedFailure]
  let developerMode: Bool
  let dismiss: (AppFeature.FailureOwner) -> Void

  var body: some View {
    ForEach(failures, id: \.owner) { owned in
      FailureBanner(failure: owned.failure, developerMode: developerMode, dismiss: { dismiss(owned.owner) })
    }
  }
}

struct RetryHistoryButton: View {
  let isLoading: Bool
  let retry: () -> Void
  var accessibilityID = "history-retry"
  var isRetry = true
  var isSlow = false
  var body: some View {
    if isLoading && !isRetry && !isSlow {
      ProgressView("Loading history…").accessibilityIdentifier("history-loading")
    } else {
      Button(action: retry) {
        Text(isSlow ? "Restart loading history" : (isLoading ? "Retrying history…" : "Retry history"))
          .fixedSize(horizontal: false, vertical: true)
          .cregTextButtonLabelTarget()
      }
      .disabled(isLoading && !isSlow)
      .accessibilityIdentifier(accessibilityID)
    }
  }
}

struct FailureBanner: View {
  let failure: FailurePresentation
  let developerMode: Bool
  let dismiss: () -> Void
  var isError = true
  private var tint: Color { isError ? .orange : .secondary }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      CREGAccessibilityActionLayout(
        hStackAlignment: .top, horizontalSpacing: 8, accessibilitySpacing: 8
      ) {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
            .foregroundStyle(tint)
          Text(failure.title)
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
        }
      } actions: {
        Button(action: dismiss) {
          Image(systemName: "xmark")
            .cregIconButtonTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isError ? "Dismiss error" : "Dismiss notice")
        .cregLargeContentViewer(isError ? "Dismiss error" : "Dismiss notice", systemImage: "xmark")
      }

      Text(failure.message)
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)

      if let details = failure.technicalDetails(
        developerMode: developerMode)
      {
        TechnicalDetailsView(details: details)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(tint.opacity(0.35))
    }
  }
}

/// The transcript cell for a Turn Failure. The title and message come from
/// the reason's `FailurePresentation` mapping; the Scope Verdict notice
/// renders beneath them once the post-render diagnosis lands; `retry`
/// resubmits the same question for reasons where retrying is the honest
/// recovery (timeout, cancellation).
struct FailureMessageView: View {
  let presentation: FailurePresentation
  var scopeVerdict: ScopeVerdictRecord?
  let developerMode: Bool
  var retry: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(presentation.title, systemImage: "exclamationmark.triangle")
        .font(.headline)
      Text(presentation.message)
      if let scopeVerdict {
        Label(scopeVerdict.userNotice, systemImage: "square.stack.3d.up.slash")
          .font(.callout)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("scope-verdict-notice")
      }
      if let retry {
        Button {
          retry()
        } label: {
          Text("Try again")
            .cregTextButtonLabelTarget()
        }
        .font(.callout.weight(.semibold))
        .accessibilityIdentifier("failed-turn-retry")
      }
      if let details = presentation.technicalDetails(
        developerMode: developerMode)
      {
        TechnicalDetailsView(details: details)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
  }
}

struct ModelPreparationFailureBanner: View {
  let failure: ModelPreparationFailure
  let developerMode: Bool
  let retry: () -> Void
  let retryCompatibility: (() -> Void)?
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  /// A paused attempt is not a failure: the prior process was suspending
  /// model preparation when it ended, and the attempt simply waits for Retry.
  private var isPaused: Bool { failure.isPaused }
  private var tint: Color { isPaused ? .secondary : .orange }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(
        failure.userMessage,
        systemImage: isPaused ? "pause.circle.fill" : "exclamationmark.triangle.fill"
      )
      .font(.callout)
      .foregroundStyle(tint)

      let actionLayout = dynamicTypeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
        : AnyLayout(HStackLayout(spacing: 12))
      actionLayout {
        Button {
          retry()
        } label: {
          Text("Retry")
            .cregTextButtonLabelTarget()
        }
        .accessibilityIdentifier("model-preparation-retry")
        if let retryCompatibility, !isPaused {
          Button {
            retryCompatibility()
          } label: {
            Text("Retry in compatibility mode")
              .cregTextButtonLabelTarget()
          }
        }
      }
      .font(.callout.weight(.semibold))

      if developerMode {
        TechnicalDetailsView(details: technicalDetails)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
    .overlay {
      RoundedRectangle(cornerRadius: 16)
        .stroke(tint.opacity(0.35))
    }
    .accessibilityIdentifier(
      isPaused ? "model-preparation-paused" : "model-preparation-failure")
  }

  private var technicalDetails: String {
    var values = [
      "[\(failure.code)]",
      "stage=\(failure.stage.rawValue)",
      "runtime_mode=\(failure.mode.rawValue)",
    ]
    if let domain = failure.errorDomain {
      values.append("error_domain=\(domain)")
    }
    if let code = failure.errorCode {
      values.append("error_code=\(code)")
    }
    return values.joined(separator: " ") + "\n" + failure.diagnostic
  }
}

struct TechnicalDetailsView: View {
  let details: String

  var body: some View {
    DisclosureGroup("Technical details") {
      Text(details)
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }
}
