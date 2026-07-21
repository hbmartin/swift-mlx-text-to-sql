struct LegacyDiagnosticClassification {
  func direct(_ diagnostic: String) -> Bool {
    // ruleid: creg-typed-diagnostic-classification
    diagnostic.contains("portfolio_database_unavailable")
  }

  func multiline(_ diagnostic: String) -> Bool {
    // ruleid: creg-typed-diagnostic-classification
    diagnostic.hasPrefix(
      "portfolio_database_unavailable"
    )
  }

  func indirect(_ diagnostic: String) -> Bool {
    let marker = "portfolio_database_unavailable"
    // ruleid: creg-typed-diagnostic-classification
    return diagnostic.hasSuffix(marker)
  }

  func typed(_ issue: SQLValidationIssue) -> Bool {
    // ok: creg-typed-diagnostic-classification
    issue.kind == .databaseUnavailable
  }
}
