import CREGCore
import Foundation

extension QueryPipeline.Configuration {
  public init(
    production: ProductionGenerationConfiguration,
    gateSensitivity: Double = 0,
    maxRepairAttempts: Int = 2
  ) {
    self.init(
      model: production.model,
      gcd: production.gcd,
      productionTemperature: production.temperature,
      maxTokens: production.maxTokens,
      gateSensitivity: gateSensitivity,
      maxRepairAttempts: maxRepairAttempts,
      selfConsistencyN: production.candidateCount,
      sampleTemperature: production.sampleTemperature,
      alwaysVote: production.alwaysVote,
      repairSampleTemperature: max(production.sampleTemperature, 0.3))
  }
}
