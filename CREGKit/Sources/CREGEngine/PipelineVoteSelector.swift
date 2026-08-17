import CREGCore
import Foundation

struct PipelineVoteSelection {
  var candidate: CandidateTelemetry
  var confidence: AnswerConfidence
  var selectionReason: CandidateSelectionReason
  var noConsensusReason: NoConsensusReason?
  var outcome: VoteOutcome
}

enum PipelineVoteSelector {
  static func select(
    candidates: [CandidateTelemetry],
    preferredCandidateIDs: [CandidateID],
    initialWasValid: Bool
  ) -> PipelineVoteSelection? {
    let candidateCount = candidates.count
    var agreementByDigest: [String: Int] = [:]
    for candidate in candidates {
      if let digest = candidate.resultDigest,
        candidate.result?.rows.isEmpty == false
      {
        agreementByDigest[digest, default: 0] += 1
      }
    }
    let majority =
      agreementByDigest
      .filter { candidateCount > 1 && $0.value > candidateCount / 2 }
      .sorted {
        $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
      }
      .first

    if let (digest, agreement) = majority,
      let winner = candidates.first(where: {
        $0.resultDigest == digest && $0.result != nil
      })
    {
      return PipelineVoteSelection(
        candidate: winner,
        confidence: .confirmed,
        selectionReason: .majorityVote,
        noConsensusReason: nil,
        outcome: .consensus(
          resultDigest: digest,
          agreement: agreement,
          candidateCount: candidateCount))
    }

    guard
      let preferred = preferredCandidateIDs
        .compactMap({ id in candidates.first(where: { $0.id == id }) })
        .first(where: { $0.result != nil })
    else { return nil }
    let nonEmptyEvidence = candidates.filter {
      $0.resultDigest != nil && $0.result?.rows.isEmpty == false
    }.count
    let reason: NoConsensusReason =
      nonEmptyEvidence < 2
      ? .insufficientNonEmptyEvidence : .conflictingResults
    return PipelineVoteSelection(
      candidate: preferred,
      confidence: .unconfirmed,
      selectionReason: initialWasValid
        ? .noConsensusDeterministicAnchor : .repairSuccess,
      noConsensusReason: reason,
      outcome: .noConsensus(
        anchorCandidateID: preferred.id,
        candidateCount: candidateCount,
        reason: reason))
  }
}
