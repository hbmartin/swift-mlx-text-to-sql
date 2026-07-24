import CREGEngine
import ComposableArchitecture
import SwiftUI

public struct ChatView: View {
  @Bindable var store: StoreOf<ChatFeature>

  public init(store: StoreOf<ChatFeature>) {
    self.store = store
  }

  public var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            if store.messages.isEmpty && !store.isProcessing {
              emptyState
            }
            ForEach(store.messages) { message in
              MessageCell(message: message, developerMode: store.developerMode)
                .id(message.id)
            }
            if store.isProcessing {
              ThinkingCell(trace: store.currentTrace)
                .id("thinking")
            }
          }
          .padding(.horizontal)
          .padding(.top, 8)
        }
        .onChange(of: store.messages.count) {
          if let last = store.messages.last?.id {
            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
          }
        }
        .onChange(of: store.currentTrace.count) {
          if store.isProcessing {
            withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
          }
        }
      }
      composer
    }
    .navigationTitle("CREG")
    .inlineNavigationTitle()
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          store.isSettingsPresented = true
        } label: {
          Image(systemName: "gearshape")
        }
      }
    }
    .sheet(isPresented: $store.isSettingsPresented) {
      SettingsView(store: store)
    }
    .onAppear { store.send(.onAppear) }
  }

  static let starterQuestions = [
    "Which properties have the highest vacancy?",
    "What's my rent roll by property type?",
    "Which leases expire in the next 12 months?",
  ]

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Ask about your portfolio")
        .font(.headline)
      ForEach(Self.starterQuestions, id: \.self) { question in
        Button {
          store.send(.starterQuestionTapped(question))
        } label: {
          HStack {
            Text(question)
              .font(.subheadline)
              .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Image(systemName: "arrow.up.right")
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, 24)
  }

  private var composer: some View {
    HStack(spacing: 8) {
      TextField("Ask about your portfolio…", text: $store.composerText, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .lineLimit(1...4)
        .onSubmit { store.send(.sendTapped) }
      if store.isProcessing {
        Button {
          store.send(.stopTapped)
        } label: {
          Image(systemName: "stop.circle.fill")
            .font(.title2)
        }
        .accessibilityLabel("Stop answering")
      } else {
        Button {
          store.send(.sendTapped)
        } label: {
          Image(systemName: "arrow.up.circle.fill")
            .font(.title2)
        }
        .disabled(
          store.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityLabel("Send")
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(.bar)
  }
}

struct MessageCell: View {
  let message: ChatMessage
  let developerMode: Bool

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
      Text(text)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.tint, in: RoundedRectangle(cornerRadius: 18))
        .foregroundStyle(.white)
    }
  }

  @ViewBuilder
  private var assistantCell: some View {
    VStack(alignment: .leading, spacing: 8) {
      switch message.body {
      case .text(let body), .clarification(let body):
        assistantBubble(body)
      case .failure(let body):
        Label(body, systemImage: "exclamationmark.triangle")
          .padding(.horizontal, 14)
          .padding(.vertical, 9)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
      case .answer(let result, let narration, let sql, let notice):
        assistantBubble(narration)
        if let confidence = AnswerConfidence(telemetry: message.devInfo) {
          ConfidenceChipView(confidence: confidence)
        }
        if let notice {
          Label(notice, systemImage: "lightbulb")
            .font(.caption)
            .foregroundStyle(.orange)
        }
        ResultTableView(result: result)
        if developerMode {
          DevFooterView(sql: sql, devInfo: message.devInfo)
        }
      }
      if !message.traceSteps.isEmpty {
        TraceView(steps: message.traceSteps)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func assistantBubble(_ body: String) -> some View {
    Text(body)
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
  }

  private var text: String {
    switch message.body {
    case .text(let body), .clarification(let body), .failure(let body): body
    case .answer(_, let narration, _, _): narration
    }
  }
}

/// One line of plain-English trust context under every answer: agreement,
/// verification caveats, and latency from the turn's telemetry. Never SQL.
struct ConfidenceChipView: View {
  let confidence: AnswerConfidence

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: confidence.symbolName)
        .foregroundStyle(iconColor)
      Text(confidence.label)
        .foregroundStyle(.secondary)
    }
    .font(.caption2)
  }

  private var iconColor: Color {
    switch confidence.tone {
    case .agreement: .green
    case .caution: .orange
    case .neutral: .secondary
    }
  }
}

/// Developer-mode internals under an answer: SQL, per-stage stats, and
/// self-consistency candidates with their votes (PRD §11).
struct DevFooterView: View {
  let sql: String
  let devInfo: TurnTelemetry?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .top, spacing: 8) {
        Text(sql)
          .font(.caption.monospaced())
          .textSelection(.enabled)
        Spacer(minLength: 0)
        Button {
          Pasteboard.copy(sql)
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Copy SQL")
      }
      if let devInfo {
        Text("original: \(devInfo.originalQuestion)")
        Text("standalone: \(devInfo.standaloneQuestion)")
        Text(verbatim:
          "rewrite applied=\(devInfo.rewriteApplied) FM=\(devInfo.rewriteUsedFM) · gate=\(devInfo.gateDecision.map { String(describing: $0) } ?? "none") FM=\(devInfo.gateUsedFM) · narration FM=\(devInfo.narrationUsedFM)"
        )
        Text(
          "stages μs: rewrite \(duration(devInfo.stageTimings.rewriteMicroseconds)) · gate \(duration(devInfo.stageTimings.gateMicroseconds)) · grounding \(duration(devInfo.stageTimings.groundingMicroseconds)) · voting \(duration(devInfo.stageTimings.votingMicroseconds)) · narration \(duration(devInfo.stageTimings.narrationMicroseconds)) · total \(devInfo.stageTimings.totalMicroseconds)"
        )
        HStack(spacing: 12) {
          Text(String(
            format: "total %.1f ms",
            Double(devInfo.stageTimings.totalMicroseconds) / 1_000))
          if devInfo.repairAttempts > 0 {
            Text("repairs: \(devInfo.repairAttempts)")
          }
          if let trigger = devInfo.voteTrigger {
            Text("vote: \(trigger)")
          }
        }
        if let outcome = devInfo.voteOutcome {
          Text("outcome: \(String(describing: outcome))")
        }
        if let reason = devInfo.selectionReason {
          Text(
            "selected: \(devInfo.selectedCandidateID?.rawValue ?? "none") · reason: \(reason.rawValue)"
          )
        }
        if let grounding = devInfo.grounding {
          Text(
            "grounding: \(grounding.checks.count) checks, \(grounding.skipped.count) skips, \(grounding.degradations.count) degradations"
          )
          ForEach(
            Array(grounding.degradations.enumerated()), id: \.offset
          ) { entry in
            Text(
              "grounding degradation: \(String(describing: entry.element))")
          }
        }
        ForEach(devInfo.candidates) { candidate in
          VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 4) {
              Image(systemName: candidate.selected
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
                .lineLimit(3)
            }
          }
        }
      }
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
  }

  private func role(_ role: CandidateRole) -> String {
    switch role {
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

struct ThinkingCell: View {
  let trace: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        ProgressView()
        Text(trace.last ?? "Thinking…")
          .foregroundStyle(.secondary)
          .contentTransition(.opacity)
      }
      .font(.subheadline)
    }
    .padding(.vertical, 4)
  }
}

extension View {
  /// iOS-only inline title mode; no-op on macOS (the package also builds for
  /// macOS so `swift test` can run the feature tests).
  @ViewBuilder
  func inlineNavigationTitle() -> some View {
    #if os(iOS)
      self.navigationBarTitleDisplayMode(.inline)
    #else
      self
    #endif
  }
}

struct TraceView: View {
  let steps: [String]

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
      Text("How I answered")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
  }
}
