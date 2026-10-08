import CREGEngine
import Foundation

/// Opening failure is distinct from a read or write failure on an open store.
public struct HistoryStoreUnavailableError: CustomStringConvertible, LocalizedError, Sendable {
  public var diagnostic: String
  public init(diagnostic: String) { self.diagnostic = diagnostic }
  public var errorDescription: String? { diagnostic }
  public var description: String { diagnostic }
}

extension HistoryClient {
  static func recoverable(
    open: @escaping @Sendable () throws -> HistoryClient,
    diagnostics: DiagnosticsClient = .noop
  ) -> HistoryClient {
    let connection = RecoverableHistoryConnection(open: open, diagnostics: diagnostics)
    return HistoryClient(
      bootstrap: { try await connection.perform(openIfNeeded: true) { try await $0.bootstrap() } },
      listConversations: { try await connection.perform { try await $0.listConversations() } },
      createConversation: { a0, a1 in try await connection.perform { try await $0.createConversation(a0, a1) } },
      createConversationWithDraft: { a0, a1, a2 in try await connection.perform { try await $0.createConversationWithDraft(a0, a1, a2) } },
      loadConversation: { a0 in try await connection.perform { try await $0.loadConversation(a0) } },
      renameConversation: { a0, a1 in try await connection.perform { try await $0.renameConversation(a0, a1) } },
      deleteConversation: { a0 in try await connection.perform { try await $0.deleteConversation(a0) } },
      saveDraft: { a0, a1 in try await connection.perform { try await $0.saveDraft(a0, a1) } },
      setUnread: { a0, a1 in try await connection.perform { try await $0.setUnread(a0, a1) } },
      search: { a0 in try await connection.perform { try await $0.search(a0) } },
      saveFeedback: { a0, a1 in try await connection.perform { try await $0.saveFeedback(a0, a1) } },
      clearFeedback: { a0, a1 in try await connection.perform { try await $0.clearFeedback(a0, a1) } },
      endTurnJournal: { a0, a1 in try await connection.perform { try await $0.endTurnJournal(a0, a1) } },
      markTurnInterrupted: { a0, a1, a2 in try await connection.perform { try await $0.markTurnInterrupted(a0, a1, a2) } },
      claimTurnRetry: { a0, a1, a2, a3 in try await connection.perform { try await $0.claimTurnRetry(a0, a1, a2, a3) } },
      declineAutoRetry: { a0, a1 in try await connection.perform { try await $0.declineAutoRetry(a0, a1) } },
      releaseAutoRetryClaim: { a0, a1, a2, a3 in try await connection.perform { try await $0.releaseAutoRetryClaim(a0, a1, a2, a3) } },
      appendMessage: { a0, a1 in try await connection.perform { try await $0.appendMessage(a0, a1) } },
      updateMessage: { a0, a1 in try await connection.perform { try await $0.updateMessage(a0, a1) } },
      updateResultPresentation: { a0, a1 in try await connection.perform { try await $0.updateResultPresentation(a0, a1) } },
      appendEvents: { a0, a1, a2 in try await connection.perform { try await $0.appendEvents(a0, a1, a2) } },
      persistScopeDiagnosis: { a0, a1, a2, a3 in try await connection.perform { try await $0.persistScopeDiagnosis(a0, a1, a2, a3) } },
      persistUserTurn: { a0, a1, a2, a3, a4 in try await connection.perform { try await $0.persistUserTurn(a0, a1, a2, a3, a4) } },
      persistTerminalTurn: { a0, a1, a2, a3, a4 in try await connection.perform { try await $0.persistTerminalTurn(a0, a1, a2, a3, a4) } },
      exportJSONL: { a0 in try await connection.perform { try await $0.exportJSONL(a0) } },
      supportBundleSource: { try await connection.perform { try await $0.supportBundleSource() } },
      saveFollowUpBatch: { a0, a1 in try await connection.perform { try await $0.saveFollowUpBatch(a0, a1) } },
      clearFollowUpBatch: { a0 in try await connection.perform { try await $0.clearFollowUpBatch(a0) } },
      acceptQuestion: { a0, a1 in try await connection.perform { try await $0.acceptQuestion(a0, a1) } }
    )
  }
}

private actor RecoverableHistoryConnection {
  private var client: HistoryClient?
  private var unavailable = HistoryStoreUnavailableError(diagnostic: "History has not been opened.")
  private let open: @Sendable () throws -> HistoryClient
  private let diagnostics: DiagnosticsClient

  init(open: @escaping @Sendable () throws -> HistoryClient, diagnostics: DiagnosticsClient) {
    self.open = open
    self.diagnostics = diagnostics
  }

  func perform<Value: Sendable>(
    openIfNeeded: Bool = false,
    _ operation: @Sendable (HistoryClient) async throws -> Value
  ) async throws -> Value {
    // Opening is synchronous and actor-isolated: concurrent bootstrap calls
    // cannot install separate connections. Database operations may then await.
    if client == nil, openIfNeeded {
      diagnostics.info(category: .history, code: "history_store_open_started",
        summary: "The local conversation history store open started.")
      do {
        client = try open()
        diagnostics.info(category: .history, code: "history_store_open_finished",
          summary: "The local conversation history store opened.")
      } catch {
        unavailable = HistoryStoreUnavailableError(diagnostic: DiagnosticDetails.describe(error))
        diagnostics.record(DiagnosticEvent(level: .error, category: .history,
          code: "history_store_open_failed",
          summary: "The local conversation history store could not be opened.",
          details: unavailable.diagnostic))
      }
    }
    guard let client else { throw unavailable }
    return try await operation(client)
  }
}
