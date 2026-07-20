import Foundation
import FoundationModels

/// Apple Foundation Model operations: the conversational glue around the SQL
/// specialist (PRD §8.3). Every closure must be called through the
/// ``InferenceSerializer`` so FM and MLX inference never overlap.
public struct FMClient: Sendable {
  public var availability: @Sendable () -> FMAvailability
  /// Rewrites a follow-up into a standalone question using prior turns.
  public var rewrite: @Sendable (_ question: String, _ history: [ConversationTurn]) async throws -> String
  /// Decides whether a standalone question needs clarification.
  /// `sensitivity` is the PRD's single dial: 0 = always pass through, 1 = eager to clarify.
  public var gate: @Sendable (_ standaloneQuestion: String, _ sensitivity: Double) async throws -> GateDecision
  /// One-line plain-English summary of what was looked at and found.
  public var narrate: @Sendable (_ standaloneQuestion: String, _ result: QueryResult) async throws -> String

  public init(
    availability: @escaping @Sendable () -> FMAvailability,
    rewrite: @escaping @Sendable (String, [ConversationTurn]) async throws -> String,
    gate: @escaping @Sendable (String, Double) async throws -> GateDecision,
    narrate: @escaping @Sendable (String, QueryResult) async throws -> String
  ) {
    self.availability = availability
    self.rewrite = rewrite
    self.gate = gate
    self.narrate = narrate
  }
}

// MARK: - Live implementation

@Generable
private struct GateProbe {
  @Guide(description: "True only when the question is genuinely ambiguous and cannot be answered with a reasonable best guess.")
  var needsClarification: Bool
  @Guide(description: "If clarification is needed, one short friendly question to ask the user. Otherwise an empty string.")
  var clarifyingQuestion: String
}

extension FMClient {
  public static func live() -> FMClient {
    FMClient(
      availability: {
        switch SystemLanguageModel.default.availability {
        case .available:
          return .available
        case .unavailable(let reason):
          return .unavailable(reason: String(describing: reason))
        }
      },
      rewrite: { question, history in
        guard !history.isEmpty else { return question }
        let session = LanguageModelSession(instructions: """
          You rewrite a follow-up question about a commercial real estate portfolio into a \
          single standalone question that needs no conversation context. Resolve references \
          like "those", "there", "last year" using the prior turns. If the question is \
          already standalone, return it unchanged. Return only the rewritten question, \
          nothing else.
          """)
        let transcript = history.suffix(4)
          .map { "Q: \($0.question)\nA: \($0.answerSummary)" }
          .joined(separator: "\n")
        let response = try await session.respond(
          to: "Prior turns:\n\(transcript)\n\nFollow-up: \(question)"
        )
        let rewritten = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return rewritten.isEmpty ? question : rewritten
      },
      gate: { question, sensitivity in
        // Below 0.5 the probe verdict cannot trigger clarification, so avoid
        // spending an FM inference on a decision that will be discarded.
        guard sensitivity >= 0.5 else { return .proceed }
        let session = LanguageModelSession(instructions: """
          You judge whether a question about a commercial real estate portfolio database \
          is answerable as-is. Prefer answering with a best guess; only flag questions \
          that are genuinely ambiguous, where a wrong guess would mislead.
          """)
        let probe = try await session.respond(to: question, generating: GateProbe.self).content
        if probe.needsClarification, !probe.clarifyingQuestion.isEmpty {
          return .clarify(question: probe.clarifyingQuestion)
        }
        return .proceed
      },
      narrate: { question, result in
        let session = LanguageModelSession(instructions: """
          You summarize a data lookup for a commercial real estate professional in ONE \
          short sentence: what was looked at and what was found. Plain English, no SQL, \
          no column names, mention a headline number or leader when there is one.
          """)
        let preview = result.rows.prefix(8)
          .map { row in row.map(\.displayString).joined(separator: " | ") }
          .joined(separator: "\n")
        let response = try await session.respond(to: """
          Question: \(question)
          Columns: \(result.columns.joined(separator: ", "))
          Row count: \(result.rowCount)\(result.isTruncated ? " (truncated)" : "")
          First rows:
          \(preview)
          """)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    )
  }

  /// Deterministic fallback used when the FM is unavailable on device:
  /// no rewriting, no gating, templated narration (per plan decision 10).
  public static func fallback() -> FMClient {
    FMClient(
      availability: { .unavailable(reason: "fallback") },
      rewrite: { question, _ in question },
      gate: { _, _ in .proceed },
      narrate: { _, result in
        result.rowCount == 0
          ? "I didn't find any matching rows."
          : "Here's what I found — \(result.rowCount) row\(result.rowCount == 1 ? "" : "s")\(result.isTruncated ? " (showing the first \(result.rowCount))" : "")."
      }
    )
  }
}
