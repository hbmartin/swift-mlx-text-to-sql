import CREGEngine
import ComposableArchitecture
import SwiftUI

/// One transcript cell: branded trailing bubbles for the user, open
/// full-width content for CREG.
struct MessageCell: View {
  let message: ChatMessage
  let feedback: AnswerFeedback?
  let readAloud: ChatFeature.ReadAloudState?
  let developerMode: Bool
  let store: StoreOf<ChatFeature>

  var body: some View {
    switch message.role {
    case .user:
      userBubble
    case .assistant:
      assistantCell
    }
  }

  private var userBubble: some View {
    HStack {
      Spacer(minLength: 48)
      Text(message.previewText)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
          CREGBrand.userBubble, in: RoundedRectangle(cornerRadius: 18)
        )
        .foregroundStyle(CREGBrand.userBubbleText)
    }
  }

  @ViewBuilder
  private var assistantCell: some View {
    VStack(alignment: .leading, spacing: 10) {
      switch message.body {
      case .text(let body), .clarification(let body):
        Text(body)
          .frame(maxWidth: .infinity, alignment: .leading)
      case .failure(let body):
        // Legacy persisted failures carry a finished sentence and no reason.
        FailureMessageView(
          presentation: FailurePresentation(
            code: "legacy_turn_failure",
            title: "Unable to answer",
            message: body,
            diagnostic: message.devInfo?.terminalError ?? ""),
          developerMode: developerMode)
      case .failedTurn(let reason, let scopeVerdict):
        FailureMessageView(
          presentation: .turnFailure(
            reason, diagnostic: message.devInfo?.terminalError),
          scopeVerdict: scopeVerdict,
          developerMode: developerMode,
          retry: retryAction(for: reason))
      case .preparedAnswer(let prepared):
        HStack(spacing: 8) {
          ProgressView()
          Text("Result ready — summarizing…")
            .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        ResultPreviewView(
          messageID: message.id,
          resultFingerprint: prepared.provenance.resultFingerprint,
          result: prepared.result,
          sql: prepared.sql,
          question: prepared.question,
          preference: message.resultPresentation,
          setPreference: {
            store.send(
              .resultPresentationChanged(
                messageID: message.id, preference: $0))
          },
          migratePreference: { previous, updated in
            store.send(
              .resultPresentationMigrated(
                .init(
                  messageID: message.id,
                  previous: previous,
                  updated: updated)))
          },
          open: {
            store.send(.resultViewerPresented(messageID: message.id))
          })
        if developerMode {
          DevInfoSectionsView(
            sql: prepared.sql,
            devInfo: prepared.preparationTelemetry)
        }
      case .answer(let result, let narration, let sql, let notice):
        Text(narration)
          .frame(maxWidth: .infinity, alignment: .leading)
        if message.devInfo?.confidence == .unconfirmed {
          Label(
            unconfirmedMessage,
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.caption.weight(.semibold))
          .foregroundStyle(.orange)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            .orange.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 10))
        }
        if let summary = ConfidenceSummary(telemetry: message.devInfo) {
          ConfidenceChipView(summary: summary)
        }
        if let notice {
          Label(notice, systemImage: "lightbulb")
            .font(.caption)
            .foregroundStyle(.orange)
        }
        if let resultFingerprint = message.resultFingerprint {
          ResultPreviewView(
            messageID: message.id,
            resultFingerprint: resultFingerprint,
            result: result,
            sql: sql,
            question: message.devInfo?.originalQuestion,
            preference: message.resultPresentation,
            setPreference: {
              store.send(
                .resultPresentationChanged(
                  messageID: message.id, preference: $0))
            },
            migratePreference: { previous, updated in
              store.send(
                .resultPresentationMigrated(
                  .init(
                    messageID: message.id,
                    previous: previous,
                    updated: updated)))
            },
            open: {
              store.send(.resultViewerPresented(messageID: message.id))
            })
        }
        AnswerActionsRow(
          messageID: message.id,
          narration: narration,
          result: result,
          runtimeMode: message.devInfo?.runtimeMode ?? .evaluated,
          feedback: feedback,
          readAloud: readAloud,
          store: store)
        if developerMode {
          DevInfoSectionsView(sql: sql, devInfo: message.devInfo)
        }
      }
      if !message.traceSteps.isEmpty {
        TraceView(
          steps: message.traceSteps,
          elapsedMicroseconds: message.devInfo?.stageTimings.totalMicroseconds)
      }
      if let batch = store.followUpBatch,
        batch.sourceAssistantMessageID == message.id,
        !batch.suggestions.isEmpty
      {
        FollowUpSuggestionsView(
          title: batch.context?.isRecoverySeed == true
            ? "Try one of these instead" : "Ask a follow-up",
          suggestions: batch.suggestions,
          select: { store.send(.preparedFollowUpTapped($0)) }
        )
        .disabled(!store.isSubmissionEnabled)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Retry is offered only where the same question can plausibly succeed
  /// unchanged — a timeout or a cancellation — and only while submission is
  /// open.
  private func retryAction(for reason: TurnFailureReason) -> (() -> Void)? {
    switch reason {
    case .timedOut, .cancelled:
      guard store.isSubmissionEnabled else { return nil }
      return { store.send(.retryFailedTurnTapped(messageID: message.id)) }
    default:
      return nil
    }
  }

  private var unconfirmedMessage: String {
    switch message.devInfo?.noConsensusReason {
    case .insufficientNonEmptyEvidence:
      "The corrected query ran, but there wasn’t enough matching non-empty evidence to confirm it."
    case .conflictingResults, .none:
      "The corrected query ran, but another valid candidate did not independently confirm it."
    }
  }
}

struct FollowUpSuggestionsView: View {
  var title = "Ask a follow-up"
  let suggestions: [PreparedFollowUp]
  let select: (UUID) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      ForEach(suggestions) { suggestion in
        Button {
          select(suggestion.id)
        } label: {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(suggestion.question)
              .font(.subheadline)
              .multilineTextAlignment(.leading)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Image(systemName: "arrow.up.right")
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 14)
          .padding(.vertical, 12)
          .background(
            .quaternary.opacity(0.5),
            in: RoundedRectangle(cornerRadius: 14)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask follow-up: \(suggestion.question)")
      }
    }
    .padding(.top, 4)
  }
}

/// Answer actions: copy the combined answer as Markdown, share it, narration
/// Read Aloud, and reversible Helpful / Not right feedback.
struct AnswerActionsRow: View {
  let messageID: UUID
  let narration: String
  let result: QueryResult
  let runtimeMode: ModelRuntimeMode
  let feedback: AnswerFeedback?
  let readAloud: ChatFeature.ReadAloudState?
  let store: StoreOf<ChatFeature>
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  @ViewBuilder
  var body: some View {
    if dynamicTypeSize.isAccessibilitySize {
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 68), spacing: 8)],
        alignment: .leading,
        spacing: 8
      ) {
        copyButton
        shareControl
        readAloudButtons
        helpfulButton
        notRightButton
      }
    } else {
      HStack(spacing: 8) {
        copyButton
        shareControl
        readAloudButtons
        Spacer(minLength: 0)
        helpfulButton
        notRightButton
      }
    }
  }

  private var exportedAnswer: String {
    AnswerExport.combinedMarkdown(
      narration: narration,
      result: result,
      runtimeMode: runtimeMode)
  }

  private var copyButton: some View {
    Button {
      Pasteboard.copy(exportedAnswer)
    } label: {
      Image(systemName: "doc.on.doc")
        .cregIconButtonTarget()
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .accessibilityLabel("Copy answer as Markdown")
    .cregLargeContentViewer(
      "Copy answer as Markdown", systemImage: "doc.on.doc")
  }

  private var shareControl: some View {
    ShareLink(item: exportedAnswer) {
      Image(systemName: "square.and.arrow.up")
        .cregIconButtonTarget()
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .accessibilityLabel("Share answer")
    .cregLargeContentViewer("Share answer", systemImage: "square.and.arrow.up")
  }

  private var helpfulButton: some View {
    Button {
      store.send(.feedbackHelpfulTapped(messageID: messageID))
    } label: {
      Image(
        systemName: feedback?.verdict == .helpful
          ? "hand.thumbsup.fill" : "hand.thumbsup"
      )
      .cregIconButtonTarget()
    }
    .buttonStyle(.plain)
    .foregroundStyle(
      feedback?.verdict == .helpful ? CREGBrand.blue : Color.secondary
    )
    .accessibilityLabel("Helpful")
    .accessibilityAddTraits(
      feedback?.verdict == .helpful ? [.isSelected] : []
    )
    .cregLargeContentViewer("Helpful", systemImage: "hand.thumbsup")
  }

  private var notRightButton: some View {
    Button {
      store.send(.feedbackNotRightTapped(messageID: messageID))
    } label: {
      Image(
        systemName: feedback?.verdict == .notRight
          ? "hand.thumbsdown.fill" : "hand.thumbsdown"
      )
      .cregIconButtonTarget()
    }
    .buttonStyle(.plain)
    .foregroundStyle(
      feedback?.verdict == .notRight ? Color.orange : Color.secondary
    )
    .accessibilityLabel("Not right")
    .accessibilityAddTraits(
      feedback?.verdict == .notRight ? [.isSelected] : []
    )
    .cregLargeContentViewer("Not right", systemImage: "hand.thumbsdown")
  }

  @ViewBuilder
  private var readAloudButtons: some View {
    if let readAloud, readAloud.messageID == messageID {
      if readAloud.phase == .playing {
        Button {
          store.send(.readAloudPauseTapped)
        } label: {
          Image(systemName: "pause.fill")
            .cregIconButtonTarget()
        }
        .buttonStyle(.plain)
        .foregroundStyle(CREGBrand.blue)
        .accessibilityLabel("Pause reading")
        .cregLargeContentViewer("Pause reading", systemImage: "pause.fill")
      } else {
        Button {
          store.send(.readAloudResumeTapped)
        } label: {
          Image(systemName: "play.fill")
            .cregIconButtonTarget()
        }
        .buttonStyle(.plain)
        .foregroundStyle(CREGBrand.blue)
        .accessibilityLabel("Resume reading")
        .cregLargeContentViewer("Resume reading", systemImage: "play.fill")
      }
      Button {
        store.send(.readAloudStopTapped)
      } label: {
        Image(systemName: "stop.fill")
          .cregIconButtonTarget()
      }
      .accessibilityLabel("Stop reading")
      .cregLargeContentViewer("Stop reading", systemImage: "stop.fill")
      .buttonStyle(.plain)
      .foregroundStyle(CREGBrand.blue)
    } else {
      Button {
        store.send(.readAloudTapped(messageID: messageID))
      } label: {
        Image(systemName: "speaker.wave.2")
          .cregIconButtonTarget()
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .accessibilityLabel("Read narration aloud")
      .cregLargeContentViewer(
        "Read narration aloud", systemImage: "speaker.wave.2")
    }
  }
}

/// Shared answer-export text: narration plus the returned table as Markdown.
public enum AnswerExport {
  public static func combinedMarkdown(
    narration: String,
    result: QueryResult,
    runtimeMode: ModelRuntimeMode? = nil
  ) -> String {
    let metadata =
      runtimeMode.map {
        "Runtime mode: \($0.rawValue) · Evaluated: \($0.isEvaluated)\n\n"
      } ?? ""
    guard !result.rows.isEmpty || !result.columns.isEmpty else {
      return metadata + narration + "\n"
    }
    return metadata + narration + "\n\n"
      + result.markdownTableString(runtimeMode: nil)
  }
}

/// One line of plain-English trust context under an answer: agreement,
/// verification caveats, and latency from the turn's telemetry. Never SQL,
/// and never rendered when the unconfirmed banner already carries the
/// warning.
struct ConfidenceChipView: View {
  let summary: ConfidenceSummary

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: summary.symbolName)
        .foregroundStyle(iconColor)
      Text(summary.label)
        .foregroundStyle(.secondary)
    }
    .font(.caption2)
  }

  private var iconColor: Color {
    switch summary.tone {
    case .agreement: .green
    case .caution: .orange
    case .neutral: .secondary
    }
  }
}

/// Completed answers retain the plain-English timeline behind an
/// elapsed-time "How I answered" disclosure.
struct TraceView: View {
  let steps: [String]
  let elapsedMicroseconds: Int64?

  var body: some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
          Label(step, systemImage: "checkmark")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    } label: {
      Text(label)
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
  }

  private var label: String {
    guard let elapsedMicroseconds, elapsedMicroseconds > 0 else {
      return "How I answered"
    }
    let seconds = Double(elapsedMicroseconds) / 1_000_000
    return String(format: "How I answered · %.1fs", seconds)
  }
}

/// Developer-mode internals under an answer, fully expanded inline and
/// organized into labeled sections (PRD §11).
struct DevInfoSectionsView: View {
  let sql: String
  let devInfo: TurnTelemetry?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      section("Generated SQL") {
        HStack(alignment: .top, spacing: 8) {
          Text(sql)
            .font(.caption.monospaced())
            .textSelection(.enabled)
          Spacer(minLength: 0)
          Button {
            Pasteboard.copy(sql)
          } label: {
            Image(systemName: "doc.on.doc")
              .cregIconButtonTarget()
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Copy SQL")
          .cregLargeContentViewer("Copy SQL", systemImage: "doc.on.doc")
        }
      }

      if let devInfo {
        section("Question Resolution") {
          Text("original: \(devInfo.originalQuestion)")
          Text("standalone: \(devInfo.standaloneQuestion)")
          Text(
            verbatim:
              "rewrite applied=\(devInfo.rewriteApplied) FM=\(devInfo.rewriteUsedFM) · gate=\(devInfo.gateDecision.map { String(describing: $0) } ?? "none") FM=\(devInfo.gateUsedFM) · narration FM=\(devInfo.narrationUsedFM)"
          )
        }

        section("Stage Timings") {
          Text(
            "stages μs: rewrite \(duration(devInfo.stageTimings.rewriteMicroseconds)) · gate \(duration(devInfo.stageTimings.gateMicroseconds)) · grounding \(duration(devInfo.stageTimings.groundingMicroseconds)) · voting \(duration(devInfo.stageTimings.votingMicroseconds)) · narration \(duration(devInfo.stageTimings.narrationMicroseconds)) · total \(devInfo.stageTimings.totalMicroseconds)"
          )
          HStack(spacing: 12) {
            Text(
              String(
                format: "total %.1f ms",
                Double(devInfo.stageTimings.totalMicroseconds) / 1_000))
            if devInfo.repairAttempts > 0 {
              Text("repairs: \(devInfo.repairAttempts)")
            }
          }
        }

        section("Voting") {
          if let trigger = devInfo.voteTrigger {
            Text("vote: \(trigger)")
          }
          if let outcome = devInfo.voteOutcome {
            Text("outcome: \(String(describing: outcome))")
          }
          if let reason = devInfo.selectionReason {
            Text(
              "selected: \(devInfo.selectedCandidateID?.rawValue ?? "none") · reason: \(reason.rawValue)"
            )
          }
          if devInfo.voteTrigger == nil, devInfo.voteOutcome == nil {
            Text("no vote ran")
          }
        }

        if let grounding = devInfo.grounding {
          section("Grounding") {
            Text(
              "\(grounding.checks.count) checks, \(grounding.skipped.count) skips, \(grounding.degradations.count) degradations"
            )
            ForEach(
              Array(grounding.degradations.enumerated()), id: \.offset
            ) { entry in
              Text("degradation: \(String(describing: entry.element))")
            }
          }
        }

        section("Candidates") {
          ForEach(devInfo.candidates) { candidate in
            VStack(alignment: .leading, spacing: 2) {
              HStack(alignment: .top, spacing: 4) {
                Image(
                  systemName: candidate.selected
                    ? "checkmark.circle.fill" : "circle")
                Text(
                  "\(candidate.id.rawValue) · \(role(candidate.role)) · \(candidate.model.repository)@\(candidate.model.revision.prefix(8)) · GCD \(candidate.gcd.rawValue) · T=\(candidate.temperature.formatted()) · seed=\(candidate.seed.map(String.init) ?? "none")"
                )
              }
              if let generated = candidate.generationMicroseconds {
                Text(
                  String(
                    format: "generation %.1f ms · %.1f tok/s · %@ tokens",
                    Double(generated) / 1_000,
                    candidate.tokensPerSecond ?? 0,
                    candidate.tokenCount.map(String.init) ?? "unknown"))
              }
              if let result = candidate.result {
                Text(
                  String(
                    format: "execution %.1f ms · %d rows%@ · group %@",
                    Double(candidate.executionMicroseconds ?? 0) / 1_000,
                    result.rowCount,
                    result.isTruncated ? " (truncated)" : "",
                    candidate.resultDigest ?? "none"))
              }
              if let error = candidate.error {
                Text("error: \(error)")
              }
              if let candidateSQL = candidate.sql {
                Text(candidateSQL)
              }
            }
          }
        }
      }
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
  }

  @ViewBuilder
  private func section(
    _ title: String, @ViewBuilder content: () -> some View
  ) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.caption2.weight(.bold))
        .textCase(.uppercase)
        .foregroundStyle(.tertiary)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func role(_ role: CandidateRole) -> String {
    switch role {
    case .starter(let starter): "starter-\(starter.rawValue)"
    case .followUpPreflight(let rank): "follow-up-preflight-\(rank)"
    case .initial: "initial"
    case .repair(let attempt): "repair-\(attempt)"
    case .deterministicAnchor: "anchor"
    case .consistencySample(let index): "sample-\(index)"
    }
  }

  private func duration(_ microseconds: Int64?) -> String {
    microseconds.map(String.init) ?? "n/a"
  }
}
