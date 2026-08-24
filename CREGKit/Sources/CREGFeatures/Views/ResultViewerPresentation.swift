import AutoTableCharts
import CREGEngine
import ComposableArchitecture
import SwiftUI

// MARK: - Presentation

extension View {
  /// Full-screen on iPhone; a sheet on the macOS host-test target, which has
  /// no full-screen cover.
  @ViewBuilder
  func resultViewerPresentation(
    store: StoreOf<ChatFeature>,
    textSize: Binding<ResultTableTextSize>
  ) -> some View {
    let binding = Binding<ResultViewerItem?>(
      get: {
        guard let id = store.resultViewerMessageID,
          let message = store.messages[id: id]
        else { return nil }
        let result: QueryResult
        let resultFingerprint: String
        let sql: String
        let question: String?
        switch message.body {
        case .answer(let answerResult, _, let answerSQL, _):
          guard let fingerprint = message.resultFingerprint else { return nil }
          result = answerResult
          resultFingerprint = fingerprint
          sql = answerSQL
          question = message.devInfo?.originalQuestion
        case .preparedAnswer(let prepared):
          result = prepared.result
          resultFingerprint = prepared.provenance.resultFingerprint
          sql = prepared.sql
          question = prepared.question
        default:
          return nil
        }
        return ResultViewerItem(
          messageID: id,
          resultFingerprint: resultFingerprint,
          result: result,
          runtimeMode: ResultViewerLogic.runtimeMode(for: message),
          sql: sql,
          question: question,
          preference: message.resultPresentation)
      },
      set: { item in
        if item == nil {
          store.send(.resultViewerDismissed)
        }
      })
    #if os(iOS)
      self.fullScreenCover(item: binding) { item in
        ResultViewerView(
          result: item.result,
          runtimeMode: item.runtimeMode,
          textSize: textSize,
          messageID: item.messageID,
          resultFingerprint: item.resultFingerprint,
          sql: item.sql,
          question: item.question,
          preference: item.preference,
          persistPreference: {
            store.send(
              .resultPresentationChanged(
                messageID: item.messageID, preference: $0))
          },
          migratePreference: { previous, updated in
            store.send(
              .resultPresentationMigrated(
                .init(
                  messageID: item.messageID,
                  previous: previous,
                  updated: updated)))
          })
      }
    #else
      self.sheet(item: binding) { item in
        ResultViewerView(
          result: item.result,
          runtimeMode: item.runtimeMode,
          textSize: textSize,
          messageID: item.messageID,
          resultFingerprint: item.resultFingerprint,
          sql: item.sql,
          question: item.question,
          preference: item.preference,
          persistPreference: {
            store.send(
              .resultPresentationChanged(
                messageID: item.messageID, preference: $0))
          },
          migratePreference: { previous, updated in
            store.send(
              .resultPresentationMigrated(
                .init(
                  messageID: item.messageID,
                  previous: previous,
                  updated: updated)))
          })
      }
    #endif
  }
}

struct ResultViewerItem: Identifiable, Equatable {
  var messageID: UUID
  var resultFingerprint: String
  var result: QueryResult
  var runtimeMode: ModelRuntimeMode
  var sql: String
  var question: String?
  var preference: ResultPresentationPreference?
  var id: UUID { messageID }
}
