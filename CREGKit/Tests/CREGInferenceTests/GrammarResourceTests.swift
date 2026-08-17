import CryptoKit
import Foundation
import Testing

@testable import CREGCore
@testable import CREGInference

extension SQLGenClient {
  static func cutterFixtureData() throws -> Data {
    guard let url = Bundle.module.url(
      forResource: "sql_cutter_fixtures", withExtension: "json")
    else { throw CocoaError(.fileNoSuchFile) }
    return try Data(contentsOf: url)
  }
}

@Suite struct GrammarResourceTests {
  @Test func systemPromptBytesMatchPythonEvaluationRuns() throws {
    let prompt = MLXSQLGenerator.systemPrompt(
      schema: try MLXSQLGenerator.schemaPrompt())
    let digest = SHA256.hash(data: Data(prompt.utf8))
      .map { String(format: "%02x", $0) }.joined()
    #expect(
      digest
        == "f9edfd023d97867fbd8ea178ddff374de8daef080bff96b2082896971b0dfddc")
  }

  @Test func repairPromptBytesMatchPythonEvaluationRuns() {
    let issue = SQLValidationIssue(
      kind: .binding,
      disposition: .repairable,
      message: "no such column: current_market_value")
    let prompt = MLXSQLGenerator.repairPrompt(
      question: "Total fund value?",
      context: RepairContext(
        failedSQL: "SELECT current_market_value FROM funds",
        errorMessage: issue.message,
        guidance: RepairGuidance(
          issue: issue,
          invalidReference: "current_market_value",
          declaredSources: ["funds"],
          possibleColumnOwners: ["properties"],
          sourceColumns: ["funds": ["fund_id", "name"]],
          relevantForeignKeys: ["properties.fund_id -> funds.fund_id"],
          correctiveInstruction:
            "Join properties and use properties.current_market_value.",
          failedFingerprints: ["abc123"])))
    #expect(
      prompt == """
        Question: Total fund value?

        The previous SQL failed SQLite validation.
        Failed SQL: SELECT current_market_value FROM funds
        Validation error: no such column: current_market_value
        Issue type: binding
        Issue disposition: repairable
        Invalid reference: current_market_value
        Declared sources: funds
        Declared source schemas: funds(fund_id, name)
        Possible owning tables: properties
        Relevant join paths: properties.fund_id -> funds.fund_id
        Required correction: Join properties and use properties.current_market_value.

        Return exactly one corrected SQLite SELECT statement. Use only columns owned by declared sources, add a schema-valid join when another table owns the needed value, and do not repeat the failed SQL.
        """)
  }

  @Test func repairPromptSubstitutesTheOriginalTemplateOnlyOnce() {
    let issue = SQLValidationIssue(
      kind: .binding,
      disposition: .repairable,
      message: "no such column: {{ISSUE_TYPE}}")
    let prompt = MLXSQLGenerator.repairPrompt(
      question: "Why did {{FAILED_SQL}} fail?",
      context: RepairContext(
        failedSQL: "SELECT {{QUESTION}}",
        errorMessage: issue.message,
        guidance: RepairGuidance(issue: issue)))
    #expect(prompt.contains("Question: Why did {{FAILED_SQL}} fail?"))
    #expect(prompt.contains("Failed SQL: SELECT {{QUESTION}}"))
    #expect(prompt.contains("Validation error: no such column: {{ISSUE_TYPE}}"))
  }

  @Test func unconstrainedOutputNormalizationMatchesPythonHarness() {
    let raw =
      "<|im_start|>Here is the query:\n```sql\nSELECT name FROM properties;\n```<|im_end|>"
    let stripped = MLXSQLGenerator.stripSpecialTokens(raw)
    #expect(
      MLXSQLGenerator.extractSQL(stripped)
        == "SELECT name FROM properties")
    #expect(
      MLXSQLGenerator.extractSQL(
        "analysis first\nWITH latest AS (SELECT 1) SELECT * FROM latest; trailing")
        == "WITH latest AS (SELECT 1) SELECT * FROM latest")
    // A semicolon inside a string literal must not truncate the statement.
    #expect(
      MLXSQLGenerator.extractSQL(
        "SELECT name FROM tenants WHERE name = 'Acme; Inc'; trailing prose")
        == "SELECT name FROM tenants WHERE name = 'Acme; Inc'")
    #expect(
      MLXSQLGenerator.extractSQL(
        "SELECT name FROM tenants WHERE name = 'O''Brien; Co' LIMIT 1;")
        == "SELECT name FROM tenants WHERE name = 'O''Brien; Co' LIMIT 1")
  }

  @Test func statementCutterUsesSQLLexicalStatesAndUnicodeScalars() throws {
    struct Fixture: Decodable {
      var generated: String
      var expected: String
    }
    struct Document: Decodable {
      var schemaVersion: Int
      var cases: [Fixture]
      enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case cases
      }
    }
    let document = try JSONDecoder().decode(
      Document.self, from: SQLGenClient.cutterFixtureData())
    #expect(document.schemaVersion == 1)
    for fixture in document.cases {
      #expect(MLXSQLGenerator.extractSQL(fixture.generated) == fixture.expected)
    }
  }

  @Test func grammarResourceContainsSchema() throws {
    let grammar = try MLXSQLGenerator.grammarEBNF()
    #expect(grammar.contains("root ::="))
    #expect(grammar.contains("\"SELECT\""))
    for table in [
      "funds", "properties", "tenants", "leases", "property_financials", "loans", "valuations",
    ] {
      #expect(grammar.contains("\"\(table)\""), "missing table \(table)")
    }
    // write statements must be unrepresentable
    #expect(!grammar.contains("\"INSERT\""))
    #expect(!grammar.contains("\"UPDATE\""))
    #expect(!grammar.contains("\"DELETE\""))
    #expect(!grammar.contains("\"DROP\""))
  }

  @Test func schemaPromptListsAllTables() throws {
    let prompt = try MLXSQLGenerator.schemaPrompt()
    for table in [
      "funds(", "properties(", "tenants(", "leases(", "property_financials(", "loans(",
      "valuations(",
    ] {
      #expect(prompt.contains(table))
    }
  }
}
