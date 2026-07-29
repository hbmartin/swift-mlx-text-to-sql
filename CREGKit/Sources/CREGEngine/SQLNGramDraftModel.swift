import Foundation
import MLX
import MLXLMCommon

private struct SQLNGramSpeculationError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

/// Immutable SQL token predictor used by the CPU-only speculative draft path.
final class SQLNGramPredictor: @unchecked Sendable {
  private final class BuildNode {
    var children: [Int: Int] = [:]
    var nextTokenCounts: [Int: Int] = [:]
  }

  private struct Node: Sendable {
    let children: [Int: Int]
    let prediction: Int
    let support: Int
    let predictionCount: Int
  }

  struct PredictionEvidence: Sendable {
    let token: Int
    let support: Int
    let predictionCount: Int
  }

  private let order: Int
  private let firstToken: Int
  private let firstSupport: Int
  private let firstPredictionCount: Int
  private let nodes: [Node]

  init(sequences: [[Int]], order: Int = 6) {
    precondition(order > 0)
    self.order = order

    var firstCounts: [Int: Int] = [:]
    var buildNodes = [BuildNode()]
    for sequence in sequences where !sequence.isEmpty {
      firstCounts[sequence[0], default: 0] += 1
      for (index, token) in sequence.enumerated() where index > 0 {
        var nodeIndex = 0
        for width in 1...min(order, index) {
          let contextToken = sequence[index - width]
          if let child = buildNodes[nodeIndex].children[contextToken] {
            nodeIndex = child
          } else {
            let child = buildNodes.count
            buildNodes.append(BuildNode())
            buildNodes[nodeIndex].children[contextToken] = child
            nodeIndex = child
          }
          buildNodes[nodeIndex].nextTokenCounts[token, default: 0] += 1
        }
      }
    }

    let firstToken = Self.mostFrequent(firstCounts) ?? 0
    self.firstToken = firstToken
    self.firstSupport = firstCounts.values.reduce(0, +)
    self.firstPredictionCount = firstCounts[firstToken, default: 0]
    self.nodes = buildNodes.map {
      let prediction = Self.mostFrequent($0.nextTokenCounts) ?? firstToken
      return Node(
        children: $0.children,
        prediction: prediction,
        support: $0.nextTokenCounts.values.reduce(0, +),
        predictionCount: $0.nextTokenCounts[prediction, default: 0])
    }
  }

  func prediction(for history: [Int]) -> Int {
    evidence(for: history).token
  }

  func evidence(for history: [Int]) -> PredictionEvidence {
    guard !history.isEmpty else {
      return PredictionEvidence(
        token: firstToken,
        support: firstSupport,
        predictionCount: firstPredictionCount)
    }
    var nodeIndex = 0
    var evidence: PredictionEvidence?
    for token in history.suffix(order).reversed() {
      guard let child = nodes[nodeIndex].children[token] else { break }
      nodeIndex = child
      let node = nodes[nodeIndex]
      evidence = PredictionEvidence(
        token: node.prediction,
        support: node.support,
        predictionCount: node.predictionCount)
    }
    return evidence ?? PredictionEvidence(
      token: firstToken,
      support: firstSupport,
      predictionCount: firstPredictionCount)
  }

  func append(_ token: Int, to history: inout [Int]) {
    if history.count >= order {
      history.removeFirst(history.count - order + 1)
    }
    history.append(token)
  }

  private static func mostFrequent(_ counts: [Int: Int]) -> Int? {
    counts.max {
      if $0.value == $1.value {
        return $0.key > $1.key
      }
      return $0.value < $1.value
    }?.key
  }
}

/// Speculative iterator that obtains draft tokens directly from a CPU table.
/// The 3B target still verifies every proposal and supplies every emitted token.
private struct SQLNGramSpeculativeTokenIterator: TokenIteratorProtocol {
  private let mainModel: any LanguageModel
  private let predictor: SQLNGramPredictor
  private let sampler: LogitSampler
  private let numDraftTokens: Int
  private let serialPrefixTokens: Int
  private let adaptiveDraftMinimumSupport: Int
  private let confidenceSkipPolicies: [VerificationMLPConfidenceSkipPolicy]
  private let kvBits: Int?
  private let kvGroupSize: Int
  private let quantizedKVStart: Int
  private let kvScheme: String?
  private let compactGlobalTokenIDs: [Int]?

  private var y: LMInput.Text
  private var mainState: LMOutput.State?
  private var mainCache: [KVCache]
  private var processor: LogitProcessor?
  private var history: [Int] = []
  private var pendingTokens: [Int] = []
  private var pendingIndex = 0

  private var roundCount = 0
  private var draftTokenCount = 0
  private var acceptedDraftTokenCount = 0
  private var targetVerifiedTokenCount = 0
  private var emittedTokenCount = 0

  let maxTokens: Int?
  private(set) var promptPrefillTime: TimeInterval = 0

  var tokenCount: Int { emittedTokenCount }
  var speculativeDecodingTelemetry: SpeculativeDecodingTelemetry? {
    guard roundCount > 0 else { return nil }
    return SpeculativeDecodingTelemetry(
      roundCount: roundCount,
      draftTokenCount: draftTokenCount,
      acceptedDraftTokenCount: acceptedDraftTokenCount,
      targetModelCallCount: roundCount,
      draftModelCallCount: 0,
      targetVerifiedTokenCount: targetVerifiedTokenCount,
      emittedTokenCount: emittedTokenCount)
  }

  init(
    input: LMInput,
    mainModel: any LanguageModel,
    mainCache: [KVCache]?,
    parameters: GenerateParameters,
    predictor: SQLNGramPredictor,
    numDraftTokens: Int,
    serialPrefixTokens: Int,
    adaptiveDraftMinimumSupport: Int,
    confidenceSkipPolicies: [VerificationMLPConfidenceSkipPolicy]
  ) throws {
    precondition(numDraftTokens > 0)
    precondition(serialPrefixTokens >= 0)
    self.y = input.text
    self.mainModel = mainModel
    self.mainCache = mainCache ?? mainModel.newCache(parameters: parameters)
    guard canTrimPromptCache(self.mainCache) else {
      throw SQLNGramSpeculationError(
        message: "SQL n-gram speculation requires trimmable target caches.")
    }
    self.predictor = predictor
    self.sampler = parameters.sampler()
    self.processor = parameters.processor()
    self.compactGlobalTokenIDs =
      CompiledQwen2ModelFactory.compactGlobalTokenIDs(of: mainModel)
    guard compactGlobalTokenIDs == nil || serialPrefixTokens == 1 else {
      throw SQLNGramSpeculationError(
        message: "Compact SQL logits require one serial prefix token.")
    }
    guard compactGlobalTokenIDs == nil || processor == nil else {
      throw SQLNGramSpeculationError(
        message: "Compact SQL logits require unprocessed greedy sampling.")
    }
    self.numDraftTokens = numDraftTokens
    self.serialPrefixTokens = serialPrefixTokens
    self.adaptiveDraftMinimumSupport = adaptiveDraftMinimumSupport
    for confidenceSkipPolicy in confidenceSkipPolicies {
      guard confidenceSkipPolicy.layer >= 0,
        (2...(numDraftTokens + 1)).contains(
          confidenceSkipPolicy.targetInputLength),
        confidenceSkipPolicy.minimumSupport > 0
      else {
        throw SQLNGramSpeculationError(
          message: "The confidence-gated MLP skip policy is invalid.")
      }
    }
    self.confidenceSkipPolicies = confidenceSkipPolicies
    self.maxTokens = parameters.maxTokens
    self.kvBits = parameters.kvBits
    self.kvGroupSize = parameters.kvGroupSize
    self.quantizedKVStart = parameters.quantizedKVStart
    self.kvScheme = parameters.kvScheme

    let started = Date.timeIntervalSinceReferenceDate
    try prepare(input: input, windowSize: parameters.prefillStepSize)
    self.promptPrefillTime = Date.timeIntervalSinceReferenceDate - started
  }

  mutating func discardGeneratedToken() {
    emittedTokenCount = Swift.max(0, emittedTokenCount - 1)
  }

  private mutating func prepare(
    input: LMInput,
    windowSize: Int?
  ) throws {
    processor?.prompt(input.text.tokens)
    switch try mainModel.prepare(
      input,
      cache: mainCache,
      windowSize: windowSize)
    {
    case .tokens(let tokens):
      y = tokens
      if serialPrefixTokens > 0 {
        let token = step(previous: y)
        y = .init(tokens: token)
        asyncEval(token)
      }
    case .logits(let result):
      var logits = result.logits[0..., -1, 0...]
      logits = processor?.process(logits: logits) ?? logits
      let token = sampler.sample(logits: logits)
      processor?.didSample(token: token)
      y = .init(tokens: token)
      mainState = result.state
      asyncEval(token)
    }
  }

  private mutating func step(previous: LMInput.Text) -> MLXArray {
    let result = withPreparedCache(
      mainCache,
      lengths: previous.sequenceLengths
    ) {
      mainModel(
        previous[text: .newAxis],
        cache: mainCache.isEmpty ? nil : mainCache,
        state: mainState)
    }
    mainState = result.state
    maybeQuantizeKVCache(
      cache: &mainCache,
      kvBits: kvBits,
      kvGroupSize: kvGroupSize,
      quantizedKVStart: quantizedKVStart,
      kvScheme: kvScheme)

    var logits = result.logits[0..., -1, 0...]
    logits = processor?.process(logits: logits) ?? logits
    let token = sampler.sample(logits: logits)
    processor?.didSample(token: token)
    return token
  }

  private mutating func speculateRound() {
    let remaining = maxTokens.map { $0 - tokenCount } ?? numDraftTokens
    let maximumDraftCount = Swift.min(remaining, numDraftTokens)
    guard maximumDraftCount > 0 else { return }

    var draftTokens: [Int] = []
    var draftEvidence: [SQLNGramPredictor.PredictionEvidence] = []
    draftTokens.reserveCapacity(maximumDraftCount)
    if maximumDraftCount == 1 {
      // The production policy proposes one token. Avoid a copy-on-write clone
      // of the complete generated history on every speculative round.
      draftTokens.append(predictor.prediction(for: history))
    } else if adaptiveDraftMinimumSupport > 0 {
      var draftHistory = history
      let first = predictor.evidence(for: draftHistory)
      draftTokens.append(first.token)
      draftEvidence.append(first)
      predictor.append(first.token, to: &draftHistory)
      var previous = first
      while draftTokens.count < maximumDraftCount,
        isAdaptiveDraftEligible(previous)
      {
        let next = predictor.evidence(for: draftHistory)
        guard isAdaptiveDraftEligible(next) else { break }
        draftTokens.append(next.token)
        draftEvidence.append(next)
        predictor.append(next.token, to: &draftHistory)
        previous = next
      }
    } else {
      var draftHistory = history
      for _ in 0..<maximumDraftCount {
        let token = predictor.prediction(for: draftHistory)
        draftTokens.append(token)
        predictor.append(token, to: &draftHistory)
      }
    }
    let draftCount = draftTokens.count

    let verifyInput = LMInput.Text(tokens: concatenated(
      [y.tokens] + draftTokens.map { MLXArray($0).reshaped([1]) }))
    let verifyStart = verifyInput.tokens.dim(0) - (draftCount + 1)
    let matchingConfidenceSkipPolicies = confidenceSkipPolicies.filter {
      policy in
      guard draftCount + 1 == policy.targetInputLength,
        draftEvidence.count == draftCount
      else { return false }
      return draftEvidence.allSatisfy { evidence in
        evidence.support >= policy.minimumSupport
          && (!policy.requiresUnanimity
            || evidence.predictionCount == evidence.support)
      }
    }
    let confidenceSkipLayers = Set(
      matchingConfidenceSkipPolicies.map(\.layer))
    let result: LMOutput
    if !confidenceSkipLayers.isEmpty,
      mainState == nil,
      let logits = CompiledQwen2ModelFactory.verificationLogits(
        of: mainModel,
        inputs: verifyInput.tokens[.newAxis],
        cache: mainCache,
        extraMLPSkipLayers: confidenceSkipLayers)
    {
      result = LMOutput(logits: logits)
    } else {
      result = mainModel(
        verifyInput[text: .newAxis],
        cache: mainCache,
        state: mainState)
    }
    mainState = result.state

    let mainTokens: MLXArray
    if var verifyProcessor = processor {
      var sampled: [MLXArray] = []
      sampled.reserveCapacity(draftCount + 1)
      for index in 0...draftCount {
        var logits = result.logits[0..., verifyStart + index, 0...]
        logits = verifyProcessor.process(logits: logits)
        let token = sampler.sample(logits: logits)
        verifyProcessor.didSample(token: token)
        sampled.append(token)
      }
      mainTokens = concatenated(sampled)
    } else {
      let logits = result.logits[0..., verifyStart..., 0...]
        .squeezed(axis: 0)
      mainTokens = sampler.sample(logits: logits)
    }

    eval(mainTokens)
    var mainTokenList = mainTokens.asArray(Int.self)
    if let compactGlobalTokenIDs {
      for index in mainTokenList.indices {
        let sampledTokenID = mainTokenList[index]
        precondition(compactGlobalTokenIDs.indices.contains(sampledTokenID))
        mainTokenList[index] = compactGlobalTokenIDs[sampledTokenID]
      }
    }
    var accepted = 0
    while accepted < draftCount,
      mainTokenList[accepted] == draftTokens[accepted]
    {
      processor?.didSample(token: MLXArray(draftTokens[accepted]))
      pendingTokens.append(mainTokenList[accepted])
      accepted += 1
    }

    let finalToken = MLXArray(mainTokenList[accepted]).reshaped([1])
    processor?.didSample(token: finalToken)
    pendingTokens.append(mainTokenList[accepted])
    for token in mainTokenList[0...accepted] {
      predictor.append(token, to: &history)
    }

    roundCount += 1
    draftTokenCount += draftCount
    acceptedDraftTokenCount += accepted
    targetVerifiedTokenCount += draftCount + 1

    trimPromptCache(mainCache, numTokens: draftCount - accepted)
    maybeQuantizeKVCache(
      cache: &mainCache,
      kvBits: kvBits,
      kvGroupSize: kvGroupSize,
      quantizedKVStart: quantizedKVStart,
      kvScheme: kvScheme)
    y = .init(tokens: finalToken)
  }

  private func isAdaptiveDraftEligible(
    _ evidence: SQLNGramPredictor.PredictionEvidence
  ) -> Bool {
    evidence.support >= adaptiveDraftMinimumSupport
      && evidence.predictionCount == evidence.support
  }

  mutating func next() -> Int? {
    if let maxTokens, tokenCount >= maxTokens { return nil }

    if emittedTokenCount < serialPrefixTokens {
      let previous = y
      if emittedTokenCount + 1 < serialPrefixTokens {
        let token = step(previous: previous)
        y = .init(tokens: token)
        asyncEval(token)
      }
      let output = globalTokenID(for: previous.tokens.item(Int.self))
      if compactGlobalTokenIDs != nil {
        y = .init(tokens: MLXArray(output).reshaped([1]))
      }
      predictor.append(output, to: &history)
      emittedTokenCount += 1
      return output
    }

    if pendingIndex >= pendingTokens.count {
      pendingTokens.removeAll(keepingCapacity: true)
      pendingIndex = 0
      speculateRound()
    }
    guard pendingIndex < pendingTokens.count else { return nil }

    let token = pendingTokens[pendingIndex]
    pendingIndex += 1
    emittedTokenCount += 1
    return token
  }

  private func globalTokenID(for sampledTokenID: Int) -> Int {
    guard let compactGlobalTokenIDs else { return sampledTokenID }
    precondition(compactGlobalTokenIDs.indices.contains(sampledTokenID))
    return compactGlobalTokenIDs[sampledTokenID]
  }
}

func generateWithSQLNGramDraft(
  input: LMInput,
  cache: [KVCache]?,
  parameters: GenerateParameters,
  context: ModelContext,
  predictor: SQLNGramPredictor,
  numDraftTokens: Int,
  serialPrefixTokens: Int,
  adaptiveDraftMinimumSupport: Int = 0,
  confidenceSkipPolicies: [VerificationMLPConfidenceSkipPolicy] = [],
  wiredMemoryTicket: WiredMemoryTicket?
) throws -> AsyncStream<Generation> {
  let iterator = try SQLNGramSpeculativeTokenIterator(
    input: input,
    mainModel: context.model,
    mainCache: cache,
    parameters: parameters,
    predictor: predictor,
    numDraftTokens: numDraftTokens,
    serialPrefixTokens: serialPrefixTokens,
    adaptiveDraftMinimumSupport: adaptiveDraftMinimumSupport,
    confidenceSkipPolicies: confidenceSkipPolicies)
  let (stream, _) = MLXLMCommon.generateTask(
    promptTokenCount: input.text.tokens.size,
    modelConfiguration: context.configuration,
    tokenizer: context.tokenizer,
    iterator: iterator,
    wiredMemoryTicket: wiredMemoryTicket)
  return stream
}
