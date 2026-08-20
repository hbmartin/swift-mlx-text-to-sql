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

struct FailureBanner: View {
  let failure: FailurePresentation
  let developerMode: Bool
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
        Text(failure.title)
          .font(.headline)
        Spacer()
        Button(action: dismiss) {
          Image(systemName: "xmark")
            .cregIconButtonTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss error")
        .cregLargeContentViewer("Dismiss error", systemImage: "xmark")
      }

      Text(failure.message)
        .font(.subheadline)

      if let details = failure.technicalDetails(
        developerMode: developerMode)
      {
        TechnicalDetailsView(details: details)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(.orange.opacity(0.35))
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
        Button("Try again") { retry() }
          .cregTextButtonTarget()
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

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(failure.userMessage, systemImage: "exclamationmark.triangle.fill")
        .font(.callout)
        .foregroundStyle(.orange)

      let actionLayout = dynamicTypeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
        : AnyLayout(HStackLayout(spacing: 12))
      actionLayout {
        Button("Retry") { retry() }
          .cregTextButtonTarget()
        if let retryCompatibility {
          Button("Retry in compatibility mode") { retryCompatibility() }
            .cregTextButtonTarget()
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
    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
    .overlay {
      RoundedRectangle(cornerRadius: 16)
        .stroke(.orange.opacity(0.35))
    }
    .accessibilityIdentifier("model-preparation-failure")
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
