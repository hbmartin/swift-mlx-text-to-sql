import CREGEngine
import ComposableArchitecture
import SwiftUI

/// App-level context the chat surface renders but does not own.
struct ChatChrome {
  var modelReadiness: AppFeature.ModelReadiness
  var modelPreparationReport: ModelPreparationReport?
  var developerMode: Bool
  var resultTableTextSize: Binding<ResultTableTextSize>
  var hasUnreadElsewhere: Bool
  var debugModelIdentity: DebugModelIdentity?
  var presentedFailure: FailurePresentation?
  var dismissFailure: () -> Void
  var retryPreparation: () -> Void
  var retryCompatibilityPreparation: () -> Void
}

/// The minimum transcript state needed to distinguish a completed assistant
/// response from ordinary message growth. Counting assistant messages makes
/// the completion detectable even when the scheduler appends the next queued
/// user question in the same state update.
struct ChatTranscriptSnapshot: Equatable {
  var conversationID: UUID
  var messageCount: Int
  var assistantMessageCount: Int
  var suggestionCount: Int

  init<Messages: Sequence>(
    conversationID: UUID,
    messages: Messages,
    suggestionCount: Int = 0
  ) where Messages.Element == ChatMessage {
    self.conversationID = conversationID
    var messageCount = 0
    var assistantMessageCount = 0
    for message in messages {
      messageCount += 1
      if message.role == .assistant {
        assistantMessageCount += 1
      }
    }
    self.messageCount = messageCount
    self.assistantMessageCount = assistantMessageCount
    self.suggestionCount = suggestionCount
  }

  var contentCount: Int { messageCount + suggestionCount }
}

enum ChatTranscriptScrollDecision: Equatable {
  case none
  case scrollToBottom
  case incrementUnseen(by: Int)
}

/// Pure policy kept outside `ChatView` so completion and queue-coalescing
/// behavior can be covered without relying on SwiftUI rendering timing.
func chatTranscriptScrollDecision(
  from previous: ChatTranscriptSnapshot,
  to current: ChatTranscriptSnapshot,
  isNearBottom: Bool
) -> ChatTranscriptScrollDecision {
  guard previous.conversationID == current.conversationID else { return .none }

  if current.assistantMessageCount > previous.assistantMessageCount {
    return .scrollToBottom
  }
  let newMessages = max(0, current.messageCount - previous.messageCount)
  let newSuggestions = max(0, current.suggestionCount - previous.suggestionCount)
  let addedContent = newMessages + newSuggestions
  guard addedContent > 0 else { return .none }
  if isNearBottom { return .scrollToBottom }
  return .incrementUnseen(by: addedContent)
}
