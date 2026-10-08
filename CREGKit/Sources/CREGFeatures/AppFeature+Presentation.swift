import ComposableArchitecture
import Foundation

extension AppFeature {
  public struct ConversationExport: Equatable, Sendable, Identifiable {
    public enum Phase: Equatable, Sendable {
      case exporting
      case ready(URL)
    }
    public var conversationID: UUID
    public var requestID: UUID
    public var phase: Phase
    public var id: UUID { requestID }
  }

  public enum Presentation: Equatable, Sendable, Identifiable {
    case settings
    case notices(UUID)
    case conversationExport(ConversationExport)
    public enum ID: Hashable { case settings, notices(UUID), export(UUID) }
    public var id: ID {
      switch self {
      case .settings: .settings
      case .notices(let id): .notices(id)
      case .conversationExport(let export): .export(export.requestID)
      }
    }
  }

  func beginConversationExport(state: inout State, conversationID: UUID) -> Effect<Action> {
    guard state.isConversationLive(conversationID) else { return .none }
    if let existing = state.conversationExports[conversationID] {
      // Both running and retained exports coalesce until consumed.
      if case .ready = existing.phase, state.chat?.conversationID == conversationID {
        state.presentation = .conversationExport(existing)
      }
      return .none
    }
    let requestID = uuid()
    state.conversationExports[conversationID] = .init(
      conversationID: conversationID, requestID: requestID, phase: .exporting)
    diagnostics.info(
      category: .history, code: "history_export_started",
      summary: "Conversation export started.")
    return .run { send in
      do {
        let url = try await history.exportJSONL(conversationID)
        await send(.conversationExportFinished(conversationID, requestID: requestID, .success(url)))
      } catch {
        await send(
          .conversationExportFinished(
            conversationID, requestID: requestID,
            .failure(.history(operation: .export, error: error))))
      }
    }
  }

  func finishConversationExport(
    state: inout State, conversationID: UUID,
    requestID: UUID, result: Result<URL, FailurePresentation>
  ) -> Effect<Action> {
    guard state.conversationExports[conversationID]?.requestID == requestID else {
      if case .success(let url) = result { return removeExportFile(url) }
      return .none
    }
    switch result {
    case .failure(let failure):
      state.conversationExports.removeValue(forKey: conversationID)
      if state.isConversationLive(conversationID) {
        presentFailure(state: &state, primary: failure, owner: .conversation(conversationID))
      } else {
        recordFailure(failure)
      }
      return .none
    case .success(let url):
      guard state.conversationDeletions[conversationID]?.phase != .committed else {
        state.conversationExports.removeValue(forKey: conversationID)
        return removeExportFile(url)
      }
      let export = ConversationExport(
        conversationID: conversationID, requestID: requestID, phase: .ready(url))
      state.conversationExports[conversationID] = export
      diagnostics.info(
        category: .history, code: "history_export_finished",
        summary: "Conversation export finished.")
      if state.chat?.conversationID == conversationID, state.isConversationLive(conversationID),
        state.presentation == nil
      {
        state.presentation = .conversationExport(export)
      }
      return .none
    }
  }

  func removeExportFile(_ url: URL) -> Effect<Action> {
    .run { _ in
      let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .standardizedFileURL
      let file = url.resolvingSymlinksInPath().standardizedFileURL
      guard file.deletingLastPathComponent() == temp,
        file.lastPathComponent.hasPrefix("creg-conversation-"), file.pathExtension == "jsonl",
        (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
      else { return }
      try? FileManager.default.removeItem(at: file)
    }
  }
}

extension AppFeature.State {
  mutating func closeConversationPresentation() {
    if case .settings = presentation { return }
    presentation = nil
  }
}
