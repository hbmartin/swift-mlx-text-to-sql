import Foundation

/// Tracks the current system request separately from the durable user message.
/// An Ask Again can reuse the message ID after an earlier request has finished.
package struct BackgroundTaskAttemptState: Sendable {
  private var current: [UUID: UUID] = [:]

  package init() {}

  package subscript(executionID: UUID) -> UUID? { current[executionID] }

  package mutating func begin(_ executionID: UUID) -> UUID? {
    guard current[executionID] == nil else { return nil }
    let attemptID = UUID()
    current[executionID] = attemptID
    return attemptID
  }

  @discardableResult
  package mutating func end(_ executionID: UUID) -> UUID? {
    current.removeValue(forKey: executionID)
  }

  package func executionID(for attemptID: UUID) -> UUID? {
    current.first { $0.value == attemptID }?.key
  }
}
