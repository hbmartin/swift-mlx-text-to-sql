import Foundation
import Testing

@testable import CREGCore
@testable import CREGInference

/// Pins `ScopeVerdictGuard`'s hand-reviewed vocabulary to the real schema
/// prompt bytes the live Scope Verdict sees (ADR 0010). Schema-derived
/// coverage self-heals, but the allowlist is a literal: a concept that
/// becomes answerable while staying listed would render a false "not
/// tracked" claim, and only this module loads both sides to catch it.
@Suite struct ScopeVerdictSchemaCoverageTests {
  @Test func reviewedAllowlistSurvivesTheRealSchemaPrompt() throws {
    let covered = ScopeVerdictGuard.coveredPhrases(
      fromSchemaPrompt: try MLXSQLGenerator.schemaPrompt())
    for (concept, display) in ScopeVerdictGuard.reviewedMissingSubjects {
      #expect(
        ScopeVerdictGuard.sanitize(concept, coveredPhrases: covered) == display,
        "\(concept) is reviewed as untracked; if the schema now covers it, remove the allowlist entry")
      #expect(
        ScopeVerdictGuard.sanitize(display, coveredPhrases: covered) == display,
        "\(display) is the reviewed phrasing and must round-trip through sanitize")
    }
  }
}
