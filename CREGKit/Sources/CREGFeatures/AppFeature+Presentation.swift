import ComposableArchitecture
import Foundation

extension AppFeature {
  public struct AnswerMorePresentation: Equatable, Sendable {
    public var conversationID: UUID
    public var presentationID: UUID
  }

  public struct ConversationExport: Equatable, Sendable, Identifiable {
    public enum Phase: Equatable, Sendable {
      case exporting
      case ready(URL)
    }
    public enum Intent: Equatable, Sendable { case export, share, retained }
    public var conversationID: UUID
    public var requestID: UUID
    public var phase: Phase
    public var intent: Intent = .export
    public var id: UUID { requestID }
  }

  public enum Presentation: Equatable, Sendable, Identifiable {
    case settings
    case notices(UUID)
    case conversationExport(ConversationExport)
    public enum ID: Hashable, Sendable { case settings, notices(UUID), export(UUID) }
    public var id: ID {
      switch self {
      case .settings: .settings
      case .notices(let id): .notices(id)
      case .conversationExport(let export): .export(export.requestID)
      }
    }
  }

  func beginConversationExport(
    state: inout State, conversationID: UUID, intent: ConversationExport.Intent = .export
  ) -> Effect<Action> {
    guard state.isConversationLive(conversationID) else { return .none }
    if var existing = state.conversationExports[conversationID], case .exporting = existing.phase {
      if intent == .share || existing.intent == .retained {
        existing.intent = intent
        state.conversationExports[conversationID] = existing
      }
      return .none
    }
    var cleanup: Effect<Action> = .none
    if let existing = state.conversationExports[conversationID],
      case .ready(let url) = existing.phase,
      state.presentedExportFiles[existing.requestID] == nil
    {
      cleanup = removeExportFile(url)
    }
    let requestID = uuid()
    state.conversationExports[conversationID] = .init(
      conversationID: conversationID, requestID: requestID, phase: .exporting, intent: intent)
    diagnostics.info(
      category: .history, code: "history_export_started", summary: "Conversation export started.")
    return .merge(
      cleanup,
      .run { send in
        do {
          let url = try await history.exportJSONL(conversationID)
          await send(
            .conversationExportFinished(conversationID, requestID: requestID, .success(url)))
        } catch {
          await send(
            .conversationExportFinished(
              conversationID, requestID: requestID,
              .failure(.history(operation: .export, error: error))))
        }
      })
  }

  func finishConversationExport(
    state: inout State, conversationID: UUID,
    requestID: UUID, result: Result<URL, FailurePresentation>
  ) -> Effect<Action> {
    guard var export = state.conversationExports[conversationID], export.requestID == requestID
    else {
      if case .success(let url) = result { return removeExportFile(url) }
      if case .failure(let failure) = result,
        let deletion = state.conversationDeletions[conversationID], deletion.phase == .committed
      {
        recordDeletedConversationWriteFailure(
          failure: failure, operationNumber: deletion.diagnosticOperationNumber)
      }
      return .none
    }
    switch result {
    case .failure(let failure):
      state.conversationExports.removeValue(forKey: conversationID)
      return handleConversationWriteFailure(
        state: &state, conversationID: conversationID,
        failure: failure, owner: .conversationOperation(conversationID, .export))
    case .success(let url):
      guard state.conversationDeletions[conversationID]?.phase != .committed else {
        state.conversationExports.removeValue(forKey: conversationID)
        return removeExportFile(url)
      }
      export.phase = .ready(url)
      let permittedSheet =
        state.presentation == nil
        || (export.intent == .share && state.presentation == .notices(conversationID))
      let present =
        export.intent != .retained && state.isSceneActive
        && state.chat?.conversationID == conversationID && state.isConversationLive(conversationID)
        && state.conversationOpening == nil && !state.newChatRequestedDuringBootstrap
        && state.chat?.resultViewerMessageID == nil && state.chat?.isRenamePresented != true
        && state.answerMorePresentation == nil
        && permittedSheet
      export.intent = .retained
      state.conversationExports[conversationID] = export
      diagnostics.info(
        category: .history, code: "history_export_finished",
        summary: "Conversation export finished.")
      if present {
        state.presentedExportFiles[requestID] = url
        state.presentation = .conversationExport(export)
      }
      return .none
    }
  }

  func dismissConversationPresentation(state: inout State, id: Presentation.ID?) -> Effect<Action> {
    guard let id else { return .none }
    if state.presentation?.id == id { state.presentation = nil }
    switch id {
    case .notices(let conversationID):
      if state.conversationExports[conversationID]?.intent == .share {
        state.conversationExports[conversationID]?.intent = .retained
      }
      return .none
    case .export(let requestID):
      guard let url = state.presentedExportFiles.removeValue(forKey: requestID) else {
        return .none
      }
      if let export = state.conversationExports.values.first(where: { $0.requestID == requestID }) {
        state.conversationExports.removeValue(forKey: export.conversationID)
      }
      return removeExportFile(url)
    case .settings: return .none
    }
  }

  func removeExportFile(_ url: URL) -> Effect<Action> {
    .run { _ in ConversationExportFiles.remove(url) }
  }

  func cleanOldConversationExports(protected: Set<URL>) -> Effect<Action> {
    let cutoff = now.addingTimeInterval(-24 * 60 * 60)
    return .run { _ in ConversationExportFiles.removeOlderThan(cutoff, protected: protected) }
  }

  func removeSupportBundle(_ url: URL) -> Effect<Action> {
    .run { _ in
      let manager = FileManager.default
      let temp = manager.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
      let file = url.standardizedFileURL
      let directory = file.deletingLastPathComponent()
      guard directory.deletingLastPathComponent().resolvingSymlinksInPath() == temp,
        directory.lastPathComponent.hasPrefix("creg-support-bundle-"),
        file.lastPathComponent == "creg-support-bundle.zip",
        (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
        (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
      else { return }
      try? manager.removeItem(at: directory)
    }
  }
}

// Only direct, regular temporary exports belong to this cleanup policy.
enum ConversationExportFiles {
  static func eligible(_ url: URL, directory: URL) -> Bool {
    let file = url.standardizedFileURL
    let temp = directory.resolvingSymlinksInPath().standardizedFileURL
    guard file.deletingLastPathComponent().resolvingSymlinksInPath() == temp,
      file.lastPathComponent.hasPrefix("creg-conversation-"), file.pathExtension == "jsonl",
      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
      values.isRegularFile == true, values.isSymbolicLink == false
    else { return false }
    return true
  }
  static func remove(_ url: URL, directory: URL = FileManager.default.temporaryDirectory) {
    guard eligible(url, directory: directory) else { return }
    try? FileManager.default.removeItem(at: url)
  }
  static func removeOlderThan(
    _ cutoff: Date, protected: Set<URL>, directory: URL = FileManager.default.temporaryDirectory
  ) {
    let excluded = Set(protected.map { $0.resolvingSymlinksInPath().standardizedFileURL })
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    for url in files where eligible(url, directory: directory) {
      guard !excluded.contains(url.resolvingSymlinksInPath().standardizedFileURL),
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate,
        modified < cutoff
      else { continue }
      remove(url, directory: directory)
    }
  }
}

extension AppFeature.State {
  mutating func closeConversationPresentation() {
    answerMorePresentation = nil
    for id in conversationExports.keys where conversationExports[id]?.phase == .exporting {
      conversationExports[id]?.intent = .retained
    }
    if case .settings = presentation { return }
    presentation = nil
  }
}
