import Foundation

/// The strictly sequential per-turn pipeline (PRD §7):
/// rewrite → gate → constrained generation → execute (with self-repair)
/// → heuristics → uncertainty-gated self-consistency → narrate.
/// Emits the structured event stream consumed by the UI trace and the JSONL log.
public struct QueryPipeline: Sendable {
  public struct Configuration: Sendable, Equatable {
    /// The ambiguity-gate dial; 0 = always pass through (v1 default).
    public var gateSensitivity: Double
    /// Maximum self-repair attempts after a SQLite error (correction layer 2).
    public var maxRepairAttempts: Int
    /// Total candidates (including the greedy one) when self-consistency
    /// voting triggers (correction layer C). 1 disables voting.
    public var selfConsistencyN: Int
    /// Sampling temperature for the extra self-consistency candidates.
    public var sampleTemperature: Double
    /// When false (default), voting only triggers on uncertainty signals
    /// (layer D): a heuristic finding or a repaired execution. When true,
    /// every turn votes.
    public var alwaysVote: Bool

    public init(
      gateSensitivity: Double = 0,
      maxRepairAttempts: Int = 2,
      selfConsistencyN: Int = 3,
      sampleTemperature: Double = 0.7,
      alwaysVote: Bool = false
    ) {
      self.gateSensitivity = gateSensitivity
      self.maxRepairAttempts = maxRepairAttempts
      self.selfConsistencyN = selfConsistencyN
      self.sampleTemperature = sampleTemperature
      self.alwaysVote = alwaysVote
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
    let heuristics = ResultHeuristics(db: db)
    return QueryPipeline { question, history in
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

            // 3-6. Constrained generation → execution, with self-repair
            @Sendable func generateAndExecute(
              repair: RepairContext?, temperature: Double
            ) async throws -> (sql: String, result: Result<QueryResult, Error>) {
              continuation.yield(.generationStarted(modelName: ""))
              let generation = try await serializer.run {
                try await sqlGen.generate(standalone, repair, temperature)
              }
              continuation.yield(.generationFinished(
                sql: generation.sql, tokensPerSecond: generation.tokensPerSecond))
              continuation.yield(.executionStarted(sql: generation.sql))
              do {
                let result = try await db.execute(generation.sql)
                continuation.yield(.executionFinished(
                  rowCount: result.rowCount, elapsedMilliseconds: result.elapsedMilliseconds))
                return (generation.sql, .success(result))
              } catch {
                return (generation.sql, .failure(error))
              }
            }

            var repair: RepairContext? = nil
            var attempt = 0
            var chosenSQL = ""
            var chosenResult: QueryResult? = nil
            while chosenResult == nil {
              if attempt > 0 {
                continuation.yield(.repairStarted(attempt: attempt))
              }
              let (sql, outcome) = try await generateAndExecute(repair: repair, temperature: 0.1)
              switch outcome {
              case .success(let result):
                chosenSQL = sql
                chosenResult = result
              case .failure(let error):
                let message = "\(error)"
                continuation.yield(.executionFailed(message: message, attempt: attempt))
                attempt += 1
                if attempt > configuration.maxRepairAttempts {
                  continuation.yield(.turnFinished(.failed(
                    message: "I couldn't answer that one — try rephrasing the question.")))
                  return
                }
                repair = RepairContext(failedSQL: sql, errorMessage: message)
              }
            }
            var result = chosenResult!

            // 7a. Correction layer A: result-shape + value-grounding heuristics
            var findings = await heuristics.inspect(sql: chosenSQL, result: result)
            for finding in findings {
              continuation.yield(.heuristicFlagged(finding))
            }

            // 7b. Layers C+D: self-consistency voting, uncertainty-gated
            let trigger: String? =
              configuration.alwaysVote ? "always"
              : attempt > 0 ? "repair"
              : !findings.isEmpty ? "heuristic"
              : nil
            if let trigger, configuration.selfConsistencyN > 1 {
              continuation.yield(.selfConsistencyStarted(
                candidateCount: configuration.selfConsistencyN, trigger: trigger))
              var candidates: [(sql: String, result: QueryResult?, error: String?)] = [
                (chosenSQL, result, nil)
              ]
              for _ in 1..<configuration.selfConsistencyN {
                let (sql, outcome) = try await generateAndExecute(
                  repair: nil, temperature: configuration.sampleTemperature)
                switch outcome {
                case .success(let sampled): candidates.append((sql, sampled, nil))
                case .failure(let error): candidates.append((sql, nil, "\(error)"))
                }
              }
              var tally: [Int: Int] = [:]
              for candidate in candidates {
                if let signature = candidate.result.map(Self.resultSignature) {
                  tally[signature, default: 0] += 1
                }
              }
              if let (winningSignature, agreement) = tally.max(by: {
                $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key)
              }),
                let winner = candidates.first(where: {
                  $0.result.map(Self.resultSignature) == winningSignature
                }), let winnerResult = winner.result
              {
                let summaries = candidates.map { candidate in
                  ConsistencyCandidate(
                    sql: candidate.sql,
                    rowCount: candidate.result?.rowCount,
                    error: candidate.error,
                    agreedWithWinner: candidate.result.map(Self.resultSignature) == winningSignature)
                }
                continuation.yield(.selfConsistencyFinished(
                  chosenSQL: winner.sql, agreement: agreement, candidates: summaries))
                if Self.resultSignature(result) != winningSignature {
                  chosenSQL = winner.sql
                  result = winnerResult
                  findings = await heuristics.inspect(sql: chosenSQL, result: result)
                }
              }
            }

            // 8. Narration
            continuation.yield(.narrationStarted)
            let finalResult = result
            let narration = try await serializer.run {
              try await activeFM.narrate(standalone, finalResult)
            }
            continuation.yield(.narrationFinished(narration: narration, usedFM: fmAvailable))
            continuation.yield(.turnFinished(.answered(
              result: result, narration: narration, sql: chosenSQL,
              notice: findings.first?.userNotice)))
          } catch {
            continuation.yield(.turnFinished(.failed(
              message: "Something went wrong while answering — please try again.")))
          }
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }
  }

  /// Order-insensitive result identity for vote clustering; reals are rounded
  /// to 4 decimals to match the harness's EX comparison.
  static func resultSignature(_ result: QueryResult) -> Int {
    var hasher = Hasher()
    hasher.combine(result.columns.count)
    let rows = result.rows.map { row in
      row.map { value -> String in
        if case .real(let v) = value { return String((v * 10_000).rounded() / 10_000) }
        return value.displayString
      }.joined(separator: "\u{1}")
    }.sorted()
    hasher.combine(rows)
    return hasher.finalize()
  }
}
