import Foundation
import Testing
@testable import CREGFeatures

@MainActor @Suite
struct AnswerShareCoordinatorTests {
  @Test func dismissalMatchesCapturedPayloadAndCannotReopen() {
    let coordinator = AnswerShareCoordinator()
    let conversation = UUID(12100)
    let more = UUID(12101)
    coordinator.request(conversationID: conversation, moreID: more, markdown: "Captured answer")
    coordinator.moreDidDismiss(UUID(12102))
    #expect(coordinator.presented == nil)
    coordinator.moreDidDismiss(more)
    #expect(coordinator.presented?.markdown == "Captured answer")
    #expect(coordinator.pending == nil)
    coordinator.request(conversationID: conversation, moreID: UUID(12103), markdown: "Later answer")
    #expect(coordinator.pending == nil)
    coordinator.reset()
    coordinator.moreDidDismiss(more)
    #expect(coordinator.presented == nil)
  }
  @Test func conversationChangeInvalidatesPendingRequest() {
    let coordinator = AnswerShareCoordinator()
    let more = UUID(12104)
    coordinator.request(conversationID: UUID(12105), moreID: more, markdown: "Old answer")
    coordinator.reset()
    coordinator.moreDidDismiss(more)
    #expect(coordinator.pending == nil && coordinator.presented == nil)
  }
}
