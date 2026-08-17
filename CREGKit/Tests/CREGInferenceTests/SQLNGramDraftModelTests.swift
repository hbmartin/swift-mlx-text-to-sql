import Foundation
import Testing

@testable import CREGInference

@Suite struct SQLNGramDraftModelTests {
  @Test func predictorUsesLongestContextAndDeterministicTieBreaking() {
    let predictor = SQLNGramPredictor(
      sequences: [
        [10, 20, 30],
        [11, 20, 31],
        [12, 40, 30],
      ],
      order: 2)

    #expect(predictor.prediction(for: []) == 10)
    #expect(predictor.prediction(for: [99]) == 10)
    #expect(predictor.prediction(for: [20]) == 30)
    #expect(predictor.prediction(for: [10, 20]) == 30)
    #expect(predictor.prediction(for: [11, 20]) == 31)
    #expect(predictor.prediction(for: [12, 40]) == 30)

    let repeated = predictor.evidence(for: [20])
    #expect(repeated.token == 30)
    #expect(repeated.support == 2)
    #expect(repeated.predictionCount == 1)
    let deterministic = predictor.evidence(for: [10, 20])
    #expect(deterministic.token == 30)
    #expect(deterministic.support == 1)
    #expect(deterministic.predictionCount == 1)

    var history = [1, 2]
    predictor.append(3, to: &history)
    #expect(history == [2, 3])
  }

  @Test func productionCorpusMatchesSupportedPolicy() throws {
    let statements = try SQLGenClient.productionDraftCorpus(
      policy: .supported)

    #expect(statements.count == SQLNGramSpeculationPolicy.supported.statementCount)
    #expect(statements.allSatisfy {
      let sql = $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      return sql.hasPrefix("SELECT") || sql.hasPrefix("WITH")
    })

    var corruptedPolicy = SQLNGramSpeculationPolicy.supported
    corruptedPolicy.corpusSHA256 = String(repeating: "0", count: 64)
    #expect(throws: CocoaError.self) {
      try SQLGenClient.productionDraftCorpus(policy: corruptedPolicy)
    }
  }
}
