import Foundation

/// Stable, payload-free failures at the Foundation Models boundary. Model
/// output is never used as a scope claim or answer merely because it parsed.
public struct FMOutputValidationError: Error, Sendable, Equatable {
  public enum Reason: String, Sendable, Equatable {
    case empty
    case tooLong
    case multiline
    case refusalLike
    case notAQuestion
    case duplicate
    case unsupported
  }

  public let stage: String
  public let reason: Reason

  public init(stage: String, reason: Reason) {
    self.stage = stage
    self.reason = reason
  }
}

public enum FMOutputValidation {
  public static func rewrite(_ value: String) throws -> String {
    try cleaned(value, stage: "rewrite", maximumLength: 400)
  }

  public static func narration(_ value: String) throws -> String {
    try cleaned(value, stage: "narration", maximumLength: 360)
  }

  public static func clarification(_ value: String) throws -> String {
    let question = try cleaned(value, stage: "gate", maximumLength: 240)
    guard question.hasSuffix("?") else {
      throw FMOutputValidationError(stage: "gate", reason: .notAQuestion)
    }
    return question
  }

  public static func followUps(_ values: [String]) throws -> [String] {
    guard values.count == 3 else {
      throw FMOutputValidationError(stage: "follow_up", reason: .empty)
    }
    let questions = try values.map {
      let question = try cleaned($0, stage: "follow_up", maximumLength: 240)
      guard question.hasSuffix("?") else {
        throw FMOutputValidationError(
          stage: "follow_up", reason: .notAQuestion)
      }
      return question
    }
    let unique = Set(questions.map {
      $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    })
    guard unique.count == 3 else {
      throw FMOutputValidationError(stage: "follow_up", reason: .duplicate)
    }
    return questions
  }

  public static func scopeSubject(
    _ value: String, verdict: ScopeVerdict
  ) throws -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if verdict == .inDomainButNotTracked {
      return try cleaned(
        trimmed, stage: "scope_verdict", maximumLength: 100)
    }
    guard trimmed.isEmpty else {
      throw FMOutputValidationError(
        stage: "scope_verdict", reason: .unsupported)
    }
    return nil
  }

  private static func cleaned(
    _ value: String,
    stage: String,
    maximumLength: Int
  ) throws -> String {
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else {
      throw FMOutputValidationError(stage: stage, reason: .empty)
    }
    guard cleaned.count <= maximumLength else {
      throw FMOutputValidationError(stage: stage, reason: .tooLong)
    }
    guard !cleaned.contains("\n"), !cleaned.contains("\r") else {
      throw FMOutputValidationError(stage: stage, reason: .multiline)
    }
    let lower = cleaned.lowercased()
    let refusalPrefixes = [
      "i'm sorry", "i am sorry", "i apologize", "i cannot", "i can't",
      "as an ai", "sorry, i cannot", "sorry, i can't",
    ]
    guard !refusalPrefixes.contains(where: lower.hasPrefix) else {
      throw FMOutputValidationError(stage: stage, reason: .refusalLike)
    }
    return cleaned
  }
}
