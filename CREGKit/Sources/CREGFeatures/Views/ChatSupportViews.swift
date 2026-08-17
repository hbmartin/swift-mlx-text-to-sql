import CREGEngine
import ComposableArchitecture
import SwiftUI

// MARK: - Supporting cells

struct ExportedFile: Identifiable {
  var url: URL
  var id: URL { url }
}

struct ExportShareSheet: View {
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
            in: RoundedRectangle(cornerRadius: 18)
          )
          .foregroundStyle(CREGBrand.userBubbleText)
        HStack(spacing: 6) {
          Text("Queued")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
          Button(action: cancel) {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
              .cregIconButtonTarget()
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Cancel queued question")
          .cregLargeContentViewer(
            "Cancel queued question", systemImage: "xmark.circle.fill")
        }
      }
    }
    .accessibilityElement(children: .contain)
  }
}

/// Compact live status row with an expandable plain-English timeline; the
/// disclosure keeps SQL out per PRD §11.
struct ProcessingStatusRow: View {
  let processing: ChatFeature.ProcessingState
  let toggleExpansion: () -> Void
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button(action: toggleExpansion) {
        statusLabel
          .font(.subheadline)
          .frame(minHeight: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        "Working: \(processing.trace.last ?? "thinking"). \(processing.isTimelineExpanded ? "Collapse" : "Expand") timeline"
      )

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

  @ViewBuilder
  private var statusLabel: some View {
    if dynamicTypeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .top, spacing: 8) {
          ProgressView()
          Text(processing.trace.last ?? "Thinking…")
            .foregroundStyle(.secondary)
            .contentTransition(.opacity)
        }
        HStack(spacing: 6) {
          ElapsedTimeText(since: processing.startedAt)
          Image(systemName: "chevron.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(
              .degrees(processing.isTimelineExpanded ? 180 : 0))
        }
      }
    } else {
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
    }
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
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    let bannerLayout =
      dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
      : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 10))
    bannerLayout {
      VStack(alignment: .leading, spacing: 3) {
        Text("Interrupted before it finished")
          .font(.footnote.weight(.semibold))
        Text(interrupted.question)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
      }
      if !dynamicTypeSize.isAccessibilitySize {
        Spacer(minLength: 4)
      }
      HStack(spacing: 4) {
        Button("Ask Again", action: askAgain)
          .font(.footnote.weight(.semibold))
          .cregTextButtonTarget()
        Button(action: dismiss) {
          Image(systemName: "xmark")
            .foregroundStyle(.secondary)
            .cregIconButtonTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss interrupted question")
        .cregLargeContentViewer(
          "Dismiss interrupted question", systemImage: "xmark")
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .cregGlassRounded(cornerRadius: 16)
  }
}

struct CorrectionContextBanner: View {
  let context: ChatFeature.CorrectionContext
  let dismiss: () -> Void
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    let bannerLayout =
      dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
      : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 10))
    bannerLayout {
      Image(systemName: "arrow.uturn.backward.circle")
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text("Tell CREG what was wrong")
          .font(.footnote.weight(.semibold))
        Text(context.answerNarration)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
      }
      if !dynamicTypeSize.isAccessibilitySize {
        Spacer(minLength: 4)
      }
      Button(action: dismiss) {
        Image(systemName: "xmark")
          .foregroundStyle(.secondary)
          .cregIconButtonTarget()
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss correction")
      .cregLargeContentViewer("Dismiss correction", systemImage: "xmark")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .cregGlassRounded(cornerRadius: 16)
  }
}
