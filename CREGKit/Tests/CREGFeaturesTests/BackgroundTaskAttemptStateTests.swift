import Foundation
import Testing

@testable import CREGFeatures

@Suite struct BackgroundTaskAttemptStateTests {
  @Test func reusedUserMessageGetsFreshAttemptAndOldLaunchCannotClaimIt() throws {
    var state = BackgroundTaskAttemptState()
    let executionID = UUID()
    let firstAttempt = state.begin(executionID)
    let first = try #require(firstAttempt)
    #expect(state.begin(executionID) == nil)
    #expect(state.executionID(for: first) == executionID)
    #expect(state.end(executionID) == first)

    let secondAttempt = state.begin(executionID)
    let second = try #require(secondAttempt)
    #expect(second != first)
    #expect(state.executionID(for: first) == nil)
    #expect(state.executionID(for: second) == executionID)
    #expect(state.end(executionID) == second)
  }
}
