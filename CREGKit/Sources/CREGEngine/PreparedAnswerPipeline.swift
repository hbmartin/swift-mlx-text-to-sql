import CREGCore
import CREGData
import Foundation

func preparedAnswerStream(
  prepared: PreparedFollowUp,
  fm: FMClient,
  db: DatabaseClient,
  serializer: InferenceSerializer,
  heuristics: ResultHeuristics,
  configuration: QueryPipeline.Configuration,
  runtimeMode: @escaping @Sendable () async -> ModelRuntimeMode,
  fallback:
    @escaping @Sendable (String, [ConversationTurn])
    -> AsyncStream<PipelineEvent>
) -> AsyncStream<PipelineEvent> {
  AsyncStream { continuation in
    let task = Task {
      let started = ContinuousClock.now
      let mode = await runtimeMode()
      func runFreeFormFallback(
        reason: PreparedCacheMissReason,
        timeoutStage: String? = nil
      ) async {
        // Prepared suggestions are generated and preflighted as standalone
        // questions. An empty history prevents the free-form pipeline from
        // spending another FM call rewriting the chip label.
        for await event in fallback(prepared.question, []) {
          if case .turnFinished(let outcome, var telemetry) = event {
            telemetry.preparedFollowUpID = prepared.id
            telemetry.sourceAnswerMessageID = prepared.sourceAssistantMessageID
            telemetry.preparedCacheHit = false
            telemetry.preparedCacheMissReason = reason
            // Stamp the prepared surface's origin exactly as the cache-hit
            // path does, so telemetry segmented by query_origin does not vary
            // with the cache-hit rate.
            telemetry.queryOrigin =
              prepared.preparationTelemetry.queryOrigin == .recoverySuggestion
              ? .recoverySuggestion : .preparedFollowUp
            if telemetry.timeoutStage == nil {
              telemetry.timeoutStage = timeoutStage
            }
            continuation.yield(
              .turnFinished(outcome: outcome, telemetry: telemetry))
          } else {
            continuation.yield(event)
          }
        }
        continuation.finish()
      }
      let cacheMissReason: PreparedCacheMissReason?
      if prepared.provenance.schemaVersion
        != PreparedQueryProvenance.currentSchemaVersion
      {
        cacheMissReason = .schemaVersion
      } else if prepared.provenance.modelKey != configuration.model.key {
        cacheMissReason = .modelKey
      } else if prepared.provenance.modelRevision != configuration.model.revision {
        cacheMissReason = .modelRevision
      } else if prepared.provenance.runtimeMode != mode {
        cacheMissReason = .runtimeMode
      } else if ![
        PreparedQueryProvenance.followUpPolicyVersion(
          repairPolicyVersion: configuration.repairPolicyVersion),
        PreparedQueryProvenance.recoverySuggestionPolicyVersion(
          repairPolicyVersion: configuration.repairPolicyVersion),
      ].contains(prepared.provenance.preparationPolicyVersion) {
        cacheMissReason = .preparationPolicyVersion
      } else if prepared.provenance.databaseFingerprint != db.fingerprint {
        cacheMissReason = .databaseFingerprint
      } else if prepared.provenance.sqlFingerprint
        != PreparedFollowUpIntegrity.fingerprint(sql: prepared.sql)
      {
        cacheMissReason = .sqlFingerprint
      } else if prepared.provenance.resultFingerprint
        != PreparedFollowUpIntegrity.fingerprint(result: prepared.result)
      {
        cacheMissReason = .resultFingerprint
      } else {
        cacheMissReason = nil
      }
      if let cacheMissReason {
        await runFreeFormFallback(reason: cacheMissReason)
        return
      }

      let validation: SQLValidationReport
      do {
        validation = try await withFollowUpDeadline(
          seconds: remainingPreparedAnswerSeconds(
            since: started,
            limit: configuration.deadlines.wholeTurnSeconds),
          stage: "prepared-validation"
        ) {
          try await db.validate(prepared.sql)
        }
      } catch is CancellationError {
        guard Task.isCancelled else {
          await runFreeFormFallback(reason: .validationFailed)
          return
        }
        continuation.finish()
        return
      } catch let deadline as FollowUpDeadlineExceeded {
        await runFreeFormFallback(
          reason: .validationTimedOut,
          timeoutStage: deadline.telemetryStage)
        return
      } catch {
        await runFreeFormFallback(reason: .validationFailed)
        return
      }
      guard validation.isValid else {
        await runFreeFormFallback(reason: .validationFailed)
        return
      }

      var telemetry = TurnTelemetry(
        originalQuestion: prepared.question,
        runtimeMode: mode)
      telemetry.standaloneQuestion = prepared.question
      // A tapped Recovery Suggestion keeps its origin so telemetry and eval
      // can separate the two surfaces.
      telemetry.queryOrigin =
        prepared.preparationTelemetry.queryOrigin == .recoverySuggestion
        ? .recoverySuggestion : .preparedFollowUp
      telemetry.executionPath = .preparedFollowUp
      telemetry.preparedFollowUpID = prepared.id
      telemetry.sourceAnswerMessageID = prepared.sourceAssistantMessageID
      telemetry.preparedCacheHit = true
      telemetry.gateDecision = .proceed
      telemetry.gateMode = .bypassed
      telemetry.repairPolicyVersion = configuration.repairPolicyVersion
      telemetry.selectionReason = .preparedFollowUp
      telemetry.recoveryOutcome = .notNeeded
      telemetry.generatedCount = 0
      telemetry.stageTimings.validationMicroseconds =
        validation.elapsedMicroseconds

      let candidateID = CandidateID(
        rawValue: "prepared-\(prepared.id.uuidString.lowercased())")
      var candidate = CandidateTelemetry(
        request: SQLGenerationRequest(
          candidateID: candidateID,
          role: .followUpPreflight(rank: prepared.rank),
          model: configuration.model,
          question: prepared.question,
          gcd: configuration.gcd,
          temperature: 0,
          seed: nil,
          maxTokens: configuration.maxTokens))
      candidate.sql = prepared.sql
      candidate.sqlFingerprint = prepared.provenance.sqlFingerprint
      candidate.validationReport = validation
      candidate.result = prepared.result
      if !prepared.result.isTruncated {
        candidate.resultDigest = CanonicalSQLResult(prepared.result).digest
      }
      candidate.selected = true
      telemetry.candidates = [candidate]
      telemetry.selectedCandidateID = candidateID

      continuation.yield(.turnStarted(question: prepared.question))
      continuation.yield(
        .questionResolved(
          standaloneQuestion: prepared.question,
          rewriteApplied: false,
          usedFM: false,
          elapsedMicroseconds: 0))
      continuation.yield(.validationStarted(candidateID: candidateID))
      continuation.yield(
        .validationFinished(candidateID: candidateID, report: validation))
      continuation.yield(
        .preparedResultReady(
          prepared: prepared,
          elapsedMicroseconds: started.duration(to: .now).microseconds))

      let groundingStarted = ContinuousClock.now
      let grounding: GroundingReport
      do {
        grounding = try await withFollowUpDeadline(
          seconds: remainingPreparedAnswerSeconds(
            since: started,
            limit: configuration.deadlines.wholeTurnSeconds),
          stage: "grounding"
        ) {
          await heuristics.inspectDetailed(
            sql: prepared.sql,
            result: prepared.result)
        }
      } catch is CancellationError {
        if Task.isCancelled {
          continuation.finish()
          return
        }
        grounding = GroundingReport()
      } catch let deadline as FollowUpDeadlineExceeded {
        telemetry.timeoutStage = deadline.telemetryStage
        grounding = GroundingReport()
      } catch {
        grounding = GroundingReport()
      }
      let groundingElapsed = groundingStarted.duration(to: .now).microseconds
      telemetry.grounding = grounding
      telemetry.stageTimings.groundingMicroseconds = groundingElapsed
      continuation.yield(
        .groundingFinished(
          report: grounding,
          elapsedMicroseconds: groundingElapsed))

      continuation.yield(.narrationStarted)
      let narrationStarted = ContinuousClock.now
      let fmAvailable = fm.availability() == .available
      let narration: String
      let narrationUsedFM: Bool
      do {
        let activeFM = fmAvailable ? fm : .fallback()
        narration = try await withFollowUpDeadline(
          seconds: remainingPreparedAnswerSeconds(
            since: started,
            limit: configuration.deadlines.wholeTurnSeconds),
          stage: "narration"
        ) {
          try await serializer.run(operation: .narration) {
            try await activeFM.narrate(prepared.question, prepared.result)
          }
        }
        narrationUsedFM = fmAvailable
      } catch is CancellationError {
        if Task.isCancelled {
          continuation.finish()
          return
        }
        narration = PreparedAnswerFallback.narration(for: prepared.result)
        narrationUsedFM = false
      } catch let deadline as FollowUpDeadlineExceeded {
        telemetry.timeoutStage = deadline.telemetryStage
        narration = PreparedAnswerFallback.narration(for: prepared.result)
        narrationUsedFM = false
      } catch {
        narration = PreparedAnswerFallback.narration(for: prepared.result)
        narrationUsedFM = false
      }
      let narrationElapsed = narrationStarted.duration(to: .now).microseconds
      telemetry.narrationUsedFM = narrationUsedFM
      telemetry.stageTimings.narrationMicroseconds = narrationElapsed
      telemetry.stageTimings.totalMicroseconds =
        started.duration(to: .now).microseconds
      continuation.yield(
        .narrationFinished(
          narration: narration,
          usedFM: narrationUsedFM,
          elapsedMicroseconds: narrationElapsed))
      let notice = grounding.findings.first?.userNotice
      continuation.yield(
        .turnFinished(
          outcome: .answered(
            result: prepared.result,
            narration: narration,
            sql: prepared.sql,
            notice: notice),
          telemetry: telemetry))
      continuation.finish()
    }
    continuation.onTermination = { _ in task.cancel() }
  }
}

func remainingPreparedAnswerSeconds(
  since started: ContinuousClock.Instant,
  limit: Double
) -> Double {
  limit - Double(started.duration(to: .now).microseconds) / 1_000_000
}
