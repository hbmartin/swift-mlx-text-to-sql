import CREGCore
import Foundation

extension FollowUpRejectionTelemetry {
  init(_ telemetry: TurnTelemetry) {
    let lastCandidate = telemetry.candidates.last
    self.init(
      timeoutStage: telemetry.timeoutStage,
      stageTimings: telemetry.stageTimings,
      candidateCount: telemetry.candidates.count,
      failedCandidateCount: telemetry.candidates.filter { $0.error != nil }.count,
      repairAttempts: telemetry.repairAttempts,
      lastCandidateRole: lastCandidate?.role,
      lastCandidateGeneratedSQL: lastCandidate?.sql != nil,
      lastCandidateProducedResult: lastCandidate?.result != nil,
      lastCandidateErrorPresent: lastCandidate?.error != nil,
      lastIssueKind: lastCandidate?.validationReport?.issue?.kind,
      lastIssueDisposition:
        lastCandidate?.validationReport?.issue?.disposition)
  }
}

extension GroundingReport {
  var isUnhelpfulPreparedFollowUp: Bool {
    findings.contains { finding in
      switch finding {
      case .emptyResult, .nullScalar, .literalNotFound:
        true
      }
    }
  }
}
