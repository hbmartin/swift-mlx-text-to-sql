import Foundation

public struct ProductionGenerationConfiguration:
  Sendable, Equatable
{
  public var model: ModelReference
  public var gcd: GCDMode
  public var temperature: Double
  public var topP: Double
  public var topK: Int
  public var maxTokens: Int
  public var candidateCount: Int
  public var sampleTemperature: Double
  public var alwaysVote: Bool
}

public enum ModelManifestError: LocalizedError, Equatable {
  case missing
  case productionSelectionPending
  case unknownProductionModel(String)
  case invalidProductionConfiguration(String)

  public var errorDescription: String? {
    switch self {
    case .missing:
      "model-manifest.json is missing from the app bundle"
    case .productionSelectionPending:
      "Production model selection is pending verified evaluation."
    case .unknownProductionModel(let key):
      "Production model key “\(key)” is not declared in the model manifest."
    case .invalidProductionConfiguration(let message):
      "Invalid production generation configuration: \(message)"
    }
  }
}

public enum ModelManifestLoader {
  private struct Document: Decodable {
    var models: [Model]
    var productionStatus: String
    var production: Production?

    enum CodingKeys: String, CodingKey {
      case models
      case productionStatus = "production_status"
      case production
    }
  }

  private struct Model: Decodable {
    struct Quantization: Decodable {
      var bits: Int
    }

    var key: String
    var repository: String?
    var revision: String?
    var quantization: Quantization?
  }

  private struct Production: Decodable {
    struct Voting: Decodable {
      var candidateCount: Int
      var sampleTemperature: Double
      var alwaysVote: Bool

      enum CodingKeys: String, CodingKey {
        case candidateCount = "candidate_count"
        case sampleTemperature = "sample_temperature"
        case alwaysVote = "always_vote"
      }
    }

    var modelKey: String
    var gcd: GCDMode
    var temperature: Double
    var topP: Double
    var topK: Int
    var maxTokens: Int
    var voting: Voting

    enum CodingKeys: String, CodingKey {
      case modelKey = "model_key"
      case gcd, temperature
      case topP = "top_p"
      case topK = "top_k"
      case maxTokens = "max_tokens"
      case voting
    }
  }

  public static func production(url: URL) throws
    -> ProductionGenerationConfiguration
  {
    let decoder = JSONDecoder()
    let document = try decoder.decode(
      Document.self, from: Data(contentsOf: url))
    guard let production = document.production else {
      throw ModelManifestError.productionSelectionPending
    }
    guard document.productionStatus == "verified" else {
      throw ModelManifestError.invalidProductionConfiguration(
        "production_status must be verified when a production selection is present")
    }
    guard let model = document.models.first(
      where: { $0.key == production.modelKey })
    else {
      throw ModelManifestError.unknownProductionModel(
        production.modelKey)
    }
    guard let repository = model.repository,
      let revision = model.revision,
      revision.count == 40,
      revision.allSatisfy(\.isHexDigit)
    else {
      throw ModelManifestError.invalidProductionConfiguration(
        "the model revision must be a full 40-character commit")
    }
    guard let quantization = model.quantization,
      quantization.bits > 0
    else {
      throw ModelManifestError.invalidProductionConfiguration(
        "the selected production model must declare positive quantization bits")
    }
    guard (0...1).contains(production.temperature),
      (0...1).contains(production.voting.sampleTemperature),
      production.topP == 1,
      production.topK == 0,
      production.maxTokens > 0,
      production.voting.candidateCount >= 1
    else {
      throw ModelManifestError.invalidProductionConfiguration(
        "temperature/top-p/top-k/token-cap/voting values are outside the supported contract")
    }
    return ProductionGenerationConfiguration(
      model: ModelReference(
        key: model.key,
        repository: repository,
        revision: revision,
        quantization: "\(quantization.bits)-bit"),
      gcd: production.gcd,
      temperature: production.temperature,
      topP: production.topP,
      topK: production.topK,
      maxTokens: production.maxTokens,
      candidateCount: production.voting.candidateCount,
      sampleTemperature: production.voting.sampleTemperature,
      alwaysVote: production.voting.alwaysVote)
  }

  public static func production(bundle: Bundle = .main) throws
    -> ProductionGenerationConfiguration
  {
    guard
      let url = bundle.url(
        forResource: "model-manifest", withExtension: "json")
    else {
      throw ModelManifestError.missing
    }
    return try production(url: url)
  }
}

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
      alwaysVote: production.alwaysVote)
  }
}
