import Foundation
@_weakLinked import FoundationModels

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
  /// Three schema-answerable next questions derived from one completed pair.
  public var suggestFollowUps:
    @Sendable (_ context: FollowUpSuggestionContext, _ schema: String) async throws
      -> [String]

  public init(
    availability: @escaping @Sendable () -> FMAvailability,
    rewrite: @escaping @Sendable (String, [ConversationTurn]) async throws -> String,
    gate: @escaping @Sendable (String, Double) async throws -> GateDecision,
    narrate: @escaping @Sendable (String, QueryResult) async throws -> String,
    suggestFollowUps:
      @escaping @Sendable (FollowUpSuggestionContext, String) async throws
      -> [String]
  ) {
    self.availability = availability
    self.rewrite = rewrite
    self.gate = gate
    self.narrate = narrate
    self.suggestFollowUps = suggestFollowUps
  }
}

// MARK: - Live implementation

@Generable
@available(macOS 26.0, iOS 26.0, *)
private struct GateProbe {
  @Guide(description: "True only when the question is genuinely ambiguous and cannot be answered with a reasonable best guess.")
  var needsClarification: Bool
  @Guide(description: "If clarification is needed, one short friendly question to ask the user. Otherwise an empty string.")
  var clarifyingQuestion: String
}

@Generable
@available(macOS 26.0, iOS 26.0, *)
private struct FollowUpQuestionSet {
  @Guide(description: "Exactly three distinct, concise, standalone questions. Each must end with a question mark and be answerable from the supplied portfolio schema.")
  var questions: [String]
}

@available(macOS 26.0, iOS 26.0, *)
extension FMUnavailabilityReason {
  init(_ reason: SystemLanguageModel.Availability.UnavailableReason) {
    switch reason {
    case .appleIntelligenceNotEnabled: self = .appleIntelligenceNotEnabled
    case .modelNotReady: self = .modelNotReady
    case .deviceNotEligible: self = .deviceNotEligible
    @unknown default: self = .other(String(describing: reason))
    }
  }
}

/// The app-level view of Foundation Model availability. Apple Intelligence is
/// required (ADR 0011): the reducer polls this on scene activation and gates
/// all new turns on it.
public struct FMStatusClient: Sendable {
  public var availability: @Sendable () -> FMAvailability

  public init(availability: @escaping @Sendable () -> FMAvailability) {
    self.availability = availability
  }

  public static func live() -> FMStatusClient {
    FMStatusClient(availability: FMClient.live().availability)
  }
}

extension FMClient {
  public static func live() -> FMClient {
    if #available(macOS 26.0, iOS 26.0, *) {
      return foundationModelClient()
    }
    return fallback()
  }

  @available(macOS 26.0, iOS 26.0, *)
  private static func foundationModelClient() -> FMClient {
    FMClient(
      availability: {
        switch SystemLanguageModel.default.availability {
        case .available:
          return .available
        case .unavailable(let reason):
          return .unavailable(reason: FMUnavailabilityReason(reason))
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
        // Sensitivity 0 parks the gate at "always pass through" (v1 default).
        guard sensitivity > 0 else { return .proceed }
        let session = LanguageModelSession(instructions: """
          You judge whether a question about a commercial real estate portfolio database \
          is answerable as-is. Prefer answering with a best guess; only flag questions \
          that are genuinely ambiguous, where a wrong guess would mislead.
          """)
        let probe = try await session.respond(to: question, generating: GateProbe.self).content
        if probe.needsClarification, !probe.clarifyingQuestion.isEmpty, sensitivity >= 0.5 {
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
      },
      suggestFollowUps: { context, schema in
        switch context.seed {
        case .answer(let result, let narration):
          let session = LanguageModelSession(instructions: """
            You suggest the next questions a commercial real estate professional would ask. \
            Return exactly three distinct, concise, standalone questions. Every question \
            must be answerable from the supplied portfolio schema, must not repeat the \
            source question, and must not require older conversation context. Prefer a \
            useful mix of drill-down, comparison, and adjacent portfolio analysis. Never \
            mention SQL, tables, columns, or unavailable data.
            """)
          let preview = result.rows.prefix(8)
            .map { row in row.map(\.displayString).joined(separator: " | ") }
            .joined(separator: "\n")
          let response = try await session.respond(
            to: """
              Portfolio as-of date: \(PortfolioSnapshot.asOfDate)
              Portfolio schema:
              \(schema)

              Source question: \(context.question)
              Standalone interpretation: \(context.standaloneQuestion)
              Answer summary: \(narration)
              Result columns: \(result.columns.joined(separator: ", "))
              Result row count: \(result.rowCount)\(result.isTruncated ? " (truncated)" : "")
              First rows:
              \(preview)
              """,
            generating: FollowUpQuestionSet.self)
          return response.content.questions

        case .turnFailure(_, let scopeVerdict):
          // Recovery Suggestions: the source question produced no answer, so
          // the prompt steers toward nearby questions the schema CAN answer
          // instead of drilling into a result that does not exist.
          let session = LanguageModelSession(instructions: """
            A commercial real estate professional asked a question their portfolio \
            database could not answer. Suggest exactly three distinct, concise, \
            standalone questions that come closest to what they wanted to learn AND \
            are directly answerable from the supplied portfolio schema. Never repeat \
            the failed question, never require older conversation context, and never \
            mention SQL, tables, columns, or unavailable data.
            """)
          let coverage: String =
            switch scopeVerdict?.verdict {
            case .outsideRealEstate:
              "The question was outside the portfolio's domain."
            case .inDomainButNotTracked:
              "The portfolio does not track the information the question needs."
            case .needsDataNotInSnapshot:
              "The question needs data beyond the portfolio's recorded snapshot."
            case .likelyAnswerableModelFailed, nil:
              "The question itself may be answerable; the attempt failed."
            }
          let response = try await session.respond(
            to: """
              Portfolio as-of date: \(PortfolioSnapshot.asOfDate)
              Portfolio schema:
              \(schema)

              Failed question: \(context.question)
              Standalone interpretation: \(context.standaloneQuestion)
              Coverage note: \(coverage)
              """,
            generating: FollowUpQuestionSet.self)
          return response.content.questions
        }
      }
    )
  }

  /// Deterministic fallback used when the FM is unavailable on device:
  /// no rewriting, no gating, templated narration (per plan decision 10).
  ///
  /// Apple Intelligence is required (ADR 0011), so this is a mid-turn safety
  /// net for a turn already in flight when availability flips — never a
  /// designed experience.
  public static func fallback() -> FMClient {
    FMClient(
      availability: { .unavailable(reason: .other("fallback")) },
      rewrite: { question, _ in question },
      gate: { _, _ in .proceed },
      narrate: { _, result in
        PreparedAnswerFallback.narration(for: result)
      },
      suggestFollowUps: { _, _ in [] }
    )
  }
}
