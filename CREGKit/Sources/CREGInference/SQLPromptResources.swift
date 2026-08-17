import CREGCore
import Foundation

extension MLXSQLGenerator {
  static func systemPrompt(schema: String) -> String {
    renderTemplate(
      resourceText(name: "system_prompt_template"),
      replacements: ["{{SCHEMA}}": schema])
  }

  static func repairPrompt(
    question: String,
    context: RepairContext
  ) -> String {
    let guidance = context.guidance
    let sourceColumns =
      guidance?.sourceColumns
      .sorted { $0.key < $1.key }
      .map { "\($0.key)(\($0.value.joined(separator: ", ")))" }
      .joined(separator: "; ") ?? ""
    let issueType = guidance?.issue.kind.rawValue ?? "unknown"
    let issueDisposition =
      guidance?.issue.disposition.rawValue ?? "repairable"
    let invalidReference = guidance?.invalidReference ?? ""
    let declaredSources =
      guidance?.declaredSources.joined(separator: ", ") ?? ""
    let possibleOwners =
      guidance?.possibleColumnOwners.joined(separator: ", ") ?? ""
    let foreignKeys =
      guidance?.relevantForeignKeys.joined(separator: "; ") ?? ""
    let correctiveInstruction = guidance?.correctiveInstruction ?? ""
    let replacements: [String: String] = [
      "{{QUESTION}}": question,
      "{{FAILED_SQL}}": context.failedSQL,
      "{{SQLITE_ERROR}}": context.errorMessage,
      "{{ISSUE_TYPE}}": issueType,
      "{{ISSUE_DISPOSITION}}": issueDisposition,
      "{{INVALID_REFERENCE}}": invalidReference,
      "{{DECLARED_SOURCES}}": declaredSources,
      "{{SOURCE_COLUMNS}}": sourceColumns,
      "{{POSSIBLE_COLUMN_OWNERS}}": possibleOwners,
      "{{RELEVANT_FOREIGN_KEYS}}": foreignKeys,
      "{{CORRECTIVE_INSTRUCTION}}": correctiveInstruction,
    ]
    return renderTemplate(
      resourceText(name: "repair_prompt_template"),
      replacements: replacements)
  }

  /// Replaces placeholders found in the original template exactly once.
  /// User-controlled values that contain placeholder-shaped text are data,
  /// not a second template pass.
  private static func renderTemplate(
    _ template: String,
    replacements: [String: String]
  ) -> String {
    guard
      let expression = try? NSRegularExpression(
        pattern: #"\{\{[A-Z_]+\}\}"#)
    else { return template }
    let matches = expression.matches(
      in: template,
      range: NSRange(template.startIndex..<template.endIndex, in: template))
    var result = ""
    var cursor = template.startIndex
    for match in matches {
      guard let range = Range(match.range, in: template) else { continue }
      result += template[cursor..<range.lowerBound]
      let token = String(template[range])
      result += replacements[token] ?? token
      cursor = range.upperBound
    }
    result += template[cursor...]
    return result
  }

  private static func resourceText(name: String) -> String {
    guard let url = Bundle.module.url(forResource: name, withExtension: "txt"),
      let value = try? String(contentsOf: url, encoding: .utf8)
    else {
      preconditionFailure("missing prompt resource: \(name).txt")
    }
    return value.trimmingCharacters(in: .newlines)
  }

}
