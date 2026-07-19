import Foundation

/// The strictly sequential per-turn pipeline (PRD §7):
/// rewrite → gate → constrained generation → execute (with self-repair) → narrate.
/// Emits the structured event stream consumed by the UI trace and the JSONL log.
public struct QueryPipeline: Sendable {
  public struct Configuration: Sendable, Equatable {
    /// The ambiguity-gate dial; 0 = always pass through (v1 default).
    public var gateSensitivity: Double
    /// Maximum self-repair attempts after a SQLite error (PRD correction layer 2).
    public var maxRepairAttempts: Int

    public init(gateSensitivity: Double = 0, maxRepairAttempts: Int = 2) {
      self.gateSensitivity = gateSensitivity
      self.maxRepairAttempts = maxRepairAttempts
    }
  }

  public var run: @Sendable (_ question: String, _ history: [ConversationTurn]) -> AsyncStream<PipelineEvent>

  public init(run: @escaping @Sendable (String, [ConversationTurn]) -> AsyncStream<PipelineEvent>) {
    self.run = run
  }
}

extension QueryPipeline {
  public static func live(
    fm: FMClient,
    sqlGen: SQLGenClient,
    db: DatabaseClient,
    serializer: InferenceSerializer,
    configuration: Configuration = Configuration()
  ) -> QueryPipeline {
    QueryPipeline { question, history in
      AsyncStream { continuation in
        let task = Task {
          defer { continuation.finish() }
          continuation.yield(.turnStarted(question: question))

          let fmAvailable = fm.availability() == .available
          let activeFM = fmAvailable ? fm : .fallback()

          do {
            // 1. Follow-up rewrite (decontextualization)
            let standalone: String
            if history.isEmpty {
              standalone = question
            } else {
              continuation.yield(.rewriteStarted)
              standalone = try await serializer.run { try await activeFM.rewrite(question, history) }
              continuation.yield(.rewriteFinished(standaloneQuestion: standalone, usedFM: fmAvailable))
            }

            // 2. Ambiguity gate
            continuation.yield(.gateStarted)
            let decision = try await serializer.run {
              try await activeFM.gate(standalone, configuration.gateSensitivity)
            }
            continuation.yield(.gateFinished(decision))
            if case .clarify(let clarifyingQuestion) = decision {
              continuation.yield(.turnFinished(.needsClarification(question: clarifyingQuestion)))
              return
            }

            // 3-7. Constrained generation → execution, with self-repair
            var repair: RepairContext? = nil
            var attempt = 0
            while true {
              if attempt > 0 {
                continuation.yield(.repairStarted(attempt: attempt))
              }
              continuation.yield(.generationStarted(modelName: ""))
              let currentRepair = repair
              let generation = try await serializer.run {
                try await sqlGen.generate(standalone, currentRepair)
              }
              continuation.yield(.generationFinished(
                sql: generation.sql, tokensPerSecond: generation.tokensPerSecond))

              continuation.yield(.executionStarted(sql: generation.sql))
              do {
                let result = try await db.execute(generation.sql)
                continuation.yield(.executionFinished(
                  rowCount: result.rowCount, elapsedMilliseconds: result.elapsedMilliseconds))

                // 8. Narration
                continuation.yield(.narrationStarted)
                let narration = try await serializer.run {
                  try await activeFM.narrate(standalone, result)
                }
                continuation.yield(.narrationFinished(narration: narration, usedFM: fmAvailable))
                continuation.yield(.turnFinished(.answered(
                  result: result, narration: narration, sql: generation.sql)))
                return
              } catch {
                let message = "\(error)"
                continuation.yield(.executionFailed(message: message, attempt: attempt))
                attempt += 1
                if attempt > configuration.maxRepairAttempts {
                  continuation.yield(.turnFinished(.failed(
                    message: "I couldn't answer that one — try rephrasing the question.")))
                  return
                }
                repair = RepairContext(failedSQL: generation.sql, errorMessage: message)
              }
            }
          } catch {
            continuation.yield(.turnFinished(.failed(
              message: "Something went wrong while answering — please try again.")))
          }
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }
  }
}
