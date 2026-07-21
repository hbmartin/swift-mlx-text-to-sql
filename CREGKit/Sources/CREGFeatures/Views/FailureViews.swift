import SwiftUI

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
            .font(.caption.bold())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss error")
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

struct FailureMessageView: View {
  let message: String
  let diagnostic: String?
  let developerMode: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Unable to answer", systemImage: "exclamationmark.triangle")
        .font(.headline)
      Text(message)
      if developerMode, let diagnostic {
        TechnicalDetailsView(details: diagnostic)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
  }
}

private struct TechnicalDetailsView: View {
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
