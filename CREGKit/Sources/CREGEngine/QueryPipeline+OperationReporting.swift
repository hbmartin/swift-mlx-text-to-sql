import CREGCore
import CREGData
import Foundation

extension QueryPipeline {
  /// Mirrors useful on-device lifecycle boundaries to unified logging while
  /// forwarding the original event stream byte-for-byte. Payload-bearing
  /// values (question text, SQL, rows, narration, result digests, paths, and
  /// portfolio/user identifiers) are intentionally never copied into
  /// diagnostic events. Generated trace tokens and per-turn candidate
  /// sequence numbers make the payload-free events correlatable.
  public func reportingOperations(
    to diagnostics: DiagnosticsClient
  ) -> QueryPipeline {
    let source = reportingTerminalFailures(to: diagnostics)

    @Sendable func observed(
      question: String,
      history: [ConversationTurn],
      queryOrigin: QueryOrigin,
      starterQueryID: StarterQueryID?,
      events: AsyncStream<PipelineEvent>
    ) -> AsyncStream<PipelineEvent> {
      AsyncStream { continuation in
        let traceID = operationTraceID()
        let task = Task {
          var observer = PipelineOperationObserver(
            diagnostics: diagnostics,
            question: question,
            history: history,
            traceID: traceID,
            queryOrigin: queryOrigin,
            starterQueryID: starterQueryID)
          observer.streamOpened(historyTurnCount: history.count)
          for await event in events {
            guard !Task.isCancelled else { break }
            observer.record(event)
            continuation.yield(event)
          }
          observer.streamClosed(cancelled: Task.isCancelled)
          continuation.finish()
        }
        continuation.onTermination = { termination in
          if case .cancelled = termination {
            diagnostics.info(
              category: .pipeline,
              code: "pipeline_stream_cancelled",
              summary: "The pipeline event stream was cancelled.",
              context: [
                "trace_id": traceID,
                "query_origin": queryOrigin.rawValue,
                "starter_query_id": starterQueryID?.rawValue ?? "none",
              ])
          }
          task.cancel()
        }
      }
    }

    @Sendable func observedPreparation(
      events: AsyncStream<FollowUpPreparationEvent>
    ) -> AsyncStream<FollowUpPreparationEvent> {
      AsyncStream { continuation in
        let traceID = operationTraceID()
        let baseContext = ["trace_id": traceID]
        let task = Task {
          let started = ContinuousClock.now
          var accepted = 0
          var firstPrepared = false
          var finishedSeen = false
          diagnostics.info(
            category: .pipeline,
            code: "follow_up_preparation_started",
            summary: "Prepared follow-up generation started.",
            context: baseContext)
          for await event in events {
            guard !Task.isCancelled else { break }
            switch event {
            case .started(let candidateCount):
              diagnostics.info(
                category: .pipeline,
                code: "follow_up_candidates_proposed",
                summary: "Follow-up candidates were proposed.",
                context: baseContext.merging([
                  "candidate_count": String(candidateCount)
                ]) { current, _ in current })
            case .proposalFailed(let reason):
              diagnostics.record(
                DiagnosticEvent(
                  level: .error,
                  category: .pipeline,
                  code: "follow_up_proposal_failed",
                  summary: "Follow-up candidate proposal generation failed.",
                  context: baseContext.merging([
                    "reason": reason.rawValue
                  ]) { current, _ in current }))
            case .prepared(let prepared):
              accepted += 1
              var eventContext = [
                "rank": String(prepared.rank),
                "accepted_count": String(accepted),
              ]
              if !firstPrepared {
                firstPrepared = true
                eventContext["time_to_first_ms"] = operationMilliseconds(
                  started.duration(to: .now).microseconds)
              }
              diagnostics.info(
                category: .pipeline,
                code: "follow_up_candidate_prepared",
                summary: "A follow-up candidate passed preparation.",
                context: baseContext.merging(eventContext) { current, _ in
                  current
                })
            case .rejected(let rank, let reason, let telemetry):
              var rejectionContext = [
                "rank": String(rank),
                "reason": reason.rawValue,
              ]
              if let telemetry {
                rejectionContext["candidate_count"] = String(
                  telemetry.candidateCount)
                rejectionContext["failed_candidate_count"] = String(
                  telemetry.failedCandidateCount)
                rejectionContext["repair_attempts"] = String(
                  telemetry.repairAttempts)
                rejectionContext["elapsed_ms"] = operationMilliseconds(
                  telemetry.stageTimings.totalMicroseconds)
                rejectionContext["timeout_stage"] = timeoutStage(
                  telemetry.timeoutStage)
              }
              diagnostics.info(
                category: .pipeline,
                code: "follow_up_candidate_rejected",
                summary: "A follow-up candidate did not pass preparation.",
                context: baseContext.merging(rejectionContext) {
                  current, _ in current
                })
            case .finished:
              finishedSeen = true
              diagnostics.info(
                category: .pipeline,
                code: "follow_up_preparation_finished",
                summary: "Prepared follow-up generation finished.",
                context: baseContext.merging([
                  "accepted_count": String(accepted),
                  "elapsed_ms": operationMilliseconds(
                    started.duration(to: .now).microseconds),
                ]) { current, _ in current })
            }
            continuation.yield(event)
          }
          if !finishedSeen {
            let context = baseContext.merging([
              "accepted_count": String(accepted),
              "elapsed_ms": operationMilliseconds(
                started.duration(to: .now).microseconds),
            ]) { current, _ in current }
            if Task.isCancelled {
              diagnostics.info(
                category: .pipeline,
                code: "follow_up_preparation_cancelled",
                summary: "Prepared follow-up generation was cancelled.",
                context: context)
            } else {
              diagnostics.record(
                DiagnosticEvent(
                  level: .error,
                  category: .pipeline,
                  code: "pipeline_stream_ended_without_terminal_event",
                  summary:
                    "The pipeline event stream ended without a terminal event.",
                  context: context))
            }
          }
          continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }

    return QueryPipeline(
      prepareMode: { mode in
        let started = ContinuousClock.now
        diagnostics.info(
          category: .pipeline,
          code: "pipeline_preparation_started",
          summary: "Pipeline preparation started.")
        do {
          let report = try await source.prepare(mode)
          diagnostics.info(
            category: .pipeline,
            code: "pipeline_preparation_finished",
            summary: "Pipeline preparation finished.",
            context: [
              "runtime_mode": mode.rawValue,
              "elapsed_ms": operationMilliseconds(
                started.duration(to: .now).microseconds),
            ])
          return report
        } catch {
          diagnostics.record(
            DiagnosticEvent(
              level: .error,
              category: .pipeline,
              code: "pipeline_preparation_failed",
              summary: "Pipeline preparation failed.",
              details: DiagnosticDetails.describe(error),
              context: [
                "runtime_mode": mode.rawValue,
                "elapsed_ms": operationMilliseconds(
                  started.duration(to: .now).microseconds),
              ]))
          throw error
        }
      },
      runtimeMode: { await source.runtimeMode() },
      run: { question, history in
        observed(
          question: question,
          history: history,
          queryOrigin: .freeForm,
          starterQueryID: nil,
          events: source.run(question, history))
      },
      runStarter: { starter in
        observed(
          question: starter.question,
          history: [],
          queryOrigin: .starter,
          starterQueryID: starter,
          events: source.runStarter(starter))
      },
      prepareFollowUps: { context in
        observedPreparation(
          events: source.prepareFollowUps(context))
      },
      runPrepared: { prepared, history in
        observed(
          question: prepared.question,
          history: history,
          queryOrigin: .preparedFollowUp,
          starterQueryID: nil,
          events: source.runPrepared(prepared, history))
      })
  }
}

func operationTraceID() -> String {
  UUID().uuidString
    .replacingOccurrences(of: "-", with: "")
    .lowercased()
}
