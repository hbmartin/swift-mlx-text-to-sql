import CREGEngine
import Foundation

extension QuestionSubmissionSource {
  var queryOrigin: QueryOrigin {
    switch self {
    case .freeForm: .freeForm
    case .starter: .starter
    case .preparedFollowUp: .preparedFollowUp
    }
  }

  var executionPath: QueryExecutionPath {
    switch self {
    case .freeForm: .generated
    case .starter: .deterministicStarter
    case .preparedFollowUp: .preparedFollowUp
    }
  }
}
