import CREGCore
import Testing

@testable import CREGEngine

/// Pin the diagnostic summaries a support-bundle reader actually sees.
///
/// The exhaustive switches make a new case state something; only these
/// expectations make it state the right thing.
@Suite struct PipelineOperationFormattingTests {
  @Test func proposalFailureSummariesNameTheStageThatStopped() {
    #expect(
      followUpProposalFailureSummary(.schemaLoadingFailed)
        == "Follow-up proposal stopped: the schema prompt could not be loaded.")
    #expect(
      followUpProposalFailureSummary(.generationFailed)
        == "Follow-up candidate proposal generation failed.")
    #expect(
      followUpProposalFailureSummary(.generationTimedOut)
        == "Follow-up candidate proposal generation timed out.")
  }

  @Test func rejectionSummariesNameTheStageThatRejected() {
    #expect(
      followUpPreparationRejectionSummary(.invalidQuestion)
        == "Follow-up candidate rejected: the proposed question was not usable.")
    #expect(
      followUpPreparationRejectionSummary(.generationFailed)
        == "Follow-up candidate rejected: SQL generation failed.")
    #expect(
      followUpPreparationRejectionSummary(.generationTimedOut)
        == "Follow-up candidate rejected: SQL generation timed out.")
    #expect(
      followUpPreparationRejectionSummary(.validationFailed)
        == "Follow-up candidate rejected: the generated SQL failed validation.")
    #expect(
      followUpPreparationRejectionSummary(.validationTimedOut)
        == "Follow-up candidate rejected: SQL validation timed out.")
    #expect(
      followUpPreparationRejectionSummary(.executionFailed)
        == "Follow-up candidate rejected: the generated SQL failed to execute.")
    #expect(
      followUpPreparationRejectionSummary(.executionTimedOut)
        == "Follow-up candidate rejected: SQL execution timed out.")
    #expect(
      followUpPreparationRejectionSummary(.unhelpfulResult)
        == "Follow-up candidate rejected: the result would not help the reader.")
    #expect(
      followUpPreparationRejectionSummary(.groundingTimedOut)
        == "Follow-up candidate rejected: result grounding timed out.")
    #expect(
      followUpPreparationRejectionSummary(.cancelled)
        == "Follow-up candidate rejected: preparation was cancelled.")
  }

  /// Every rejection reason gets its own sentence.
  ///
  /// A duplicated summary would be invisible above -- each expectation would
  /// still pass -- while making two distinct outcomes read identically, which
  /// is the failure this reason-aware mapping exists to prevent. The reasons
  /// are listed rather than derived because the enum is not `CaseIterable`;
  /// the exhaustive switch in the source is what forces a new case to be
  /// handled at all.
  @Test func everyRejectionReasonReadsDifferently() {
    let reasons: [FollowUpPreparationRejection] = [
      .invalidQuestion,
      .generationFailed,
      .generationTimedOut,
      .validationFailed,
      .validationTimedOut,
      .executionFailed,
      .executionTimedOut,
      .unhelpfulResult,
      .groundingTimedOut,
      .cancelled,
    ]
    let summaries = Set(reasons.map(followUpPreparationRejectionSummary))
    #expect(summaries.count == reasons.count)
  }
}
