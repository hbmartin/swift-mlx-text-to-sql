// Copyright © 2024 Apple Inc.
//
// CREG-specific Qwen2 execution path derived from the pinned mlx-swift-lm
// Qwen2 model. The only graph change is compiling the elementwise SiLU/product
// pair as one shapeless function so MLX can dispatch it as one fused kernel.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

private let compiledQwen2SiluProduct: @Sendable (MLXArray, MLXArray) -> MLXArray = compile(
  shapeless: true
) {
  gate, up in
  silu(gate) * up
}

private struct CompiledQwen2Configuration: Codable, Sendable {
  var hiddenSize: Int
  var hiddenLayers: Int
  var intermediateSize: Int
  var attentionHeads: Int
  var rmsNormEps: Float
  var vocabularySize: Int
  var kvHeads: Int
  var ropeTheta: Float = 1_000_000
  var ropeTraditional: Bool = false
  var ropeScaling: [String: StringOrNumber]? = nil
  var tieWordEmbeddings = false

  enum CodingKeys: String, CodingKey {
    case hiddenSize = "hidden_size"
    case hiddenLayers = "num_hidden_layers"
    case intermediateSize = "intermediate_size"
    case attentionHeads = "num_attention_heads"
    case rmsNormEps = "rms_norm_eps"
    case vocabularySize = "vocab_size"
    case kvHeads = "num_key_value_heads"
    case ropeTheta = "rope_theta"
    case ropeTraditional = "rope_traditional"
    case ropeScaling = "rope_scaling"
    case tieWordEmbeddings = "tie_word_embeddings"
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    hiddenSize = try values.decode(Int.self, forKey: .hiddenSize)
    hiddenLayers = try values.decode(Int.self, forKey: .hiddenLayers)
    intermediateSize = try values.decode(Int.self, forKey: .intermediateSize)
    attentionHeads = try values.decode(Int.self, forKey: .attentionHeads)
    rmsNormEps = try values.decode(Float.self, forKey: .rmsNormEps)
    vocabularySize = try values.decode(Int.self, forKey: .vocabularySize)
    kvHeads = try values.decode(Int.self, forKey: .kvHeads)
    ropeTheta =
      try values.decodeIfPresent(Float.self, forKey: .ropeTheta)
      ?? 1_000_000
    ropeTraditional =
      try values.decodeIfPresent(
        Bool.self,
        forKey: .ropeTraditional) ?? false
    ropeScaling = try values.decodeIfPresent(
      [String: StringOrNumber].self,
      forKey: .ropeScaling)
    tieWordEmbeddings =
      try values.decodeIfPresent(
        Bool.self,
        forKey: .tieWordEmbeddings) ?? false
  }
}

private final class CompiledQwen2Attention: Module {
  let configuration: CompiledQwen2Configuration
  let scale: Float

  @ModuleInfo(key: "q_proj") var queryProjection: Linear
  @ModuleInfo(key: "k_proj") var keyProjection: Linear
  @ModuleInfo(key: "v_proj") var valueProjection: Linear
  @ModuleInfo(key: "o_proj") var outputProjection: Linear

  let rope: RoPE
  private var usesFusedQKVForVerification = false
  private var fusedQKVProjection: QuantizedLinear?

  init(_ configuration: CompiledQwen2Configuration) {
    self.configuration = configuration
    let dimensions = configuration.hiddenSize
    let heads = configuration.attentionHeads
    let kvHeads = configuration.kvHeads
    let headDimensions = dimensions / heads
    scale = pow(Float(headDimensions), -0.5)

    _queryProjection.wrappedValue = Linear(
      dimensions,
      heads * headDimensions,
      bias: true)
    _keyProjection.wrappedValue = Linear(
      dimensions,
      kvHeads * headDimensions,
      bias: true)
    _valueProjection.wrappedValue = Linear(
      dimensions,
      kvHeads * headDimensions,
      bias: true)
    _outputProjection.wrappedValue = Linear(
      heads * headDimensions,
      dimensions,
      bias: false)

    let ropeScale: Float
    if let ropeScaling = configuration.ropeScaling,
      ropeScaling["type"] == .string("linear"),
      let factor = ropeScaling["factor"]?.asFloat()
    {
      ropeScale = 1 / factor
    } else {
      ropeScale = 1
    }
    rope = RoPE(
      dimensions: headDimensions,
      traditional: configuration.ropeTraditional,
      base: configuration.ropeTheta,
      scale: ropeScale)
  }

  func callAsFunction(
    _ input: MLXArray,
    mask: MLXFast.ScaledDotProductAttentionMaskMode,
    cache: KVCache?
  ) -> MLXArray {
    let batch = input.dim(0)
    let length = input.dim(1)

    var (queries, keys, values) = projectedQKV(
      input,
      sequenceLength: length)
    values = values
      .reshaped(batch, length, configuration.kvHeads, -1)
      .transposed(0, 2, 1, 3)

    queries =
      queries
      .reshaped(batch, length, configuration.attentionHeads, -1)
      .transposed(0, 2, 1, 3)
    keys =
      keys
      .reshaped(batch, length, configuration.kvHeads, -1)
      .transposed(0, 2, 1, 3)

    let offset = cache?.ropeOffset
    queries = applyRotaryPosition(rope, to: queries, offset: offset)
    keys = applyRotaryPosition(rope, to: keys, offset: offset)

    return outputProjection(
      attentionWithCacheUpdate(
        queries: queries,
        keys: keys,
        values: values,
        cache: cache,
        scale: scale,
        mask: mask
      )
      .transposed(0, 2, 1, 3)
      .reshaped(batch, length, -1))
  }

  private func projectedQKV(
    _ input: MLXArray,
    sequenceLength: Int
  ) -> (MLXArray, MLXArray, MLXArray) {
    // Production speculation verifies two to four tokens at a time. Fusing
    // Q/K/V for those small verification tensors removes two quantized
    // projection dispatches without changing the long-prefill graph, whose
    // different floating-point reduction order did change one evaluated SQL
    // result.
    guard usesFusedQKVForVerification, 2...4 ~= sequenceLength,
      let fusedQKVProjection
    else {
      return (
        queryProjection(input),
        keyProjection(input),
        valueProjection(input))
    }
    let headDimensions = configuration.hiddenSize
      / configuration.attentionHeads
    let queryDimensions = configuration.attentionHeads * headDimensions
    let keyValueDimensions = configuration.kvHeads * headDimensions
    let values = split(
      fusedQKVProjection(input),
      indices: [queryDimensions, queryDimensions + keyValueDimensions],
      axis: -1)
    precondition(values.count == 3)
    return (values[0], values[1], values[2])
  }

  fileprivate var supportsFusedQKVProjection: Bool {
    guard let query = queryProjection as? QuantizedLinear,
      let key = keyProjection as? QuantizedLinear,
      let value = valueProjection as? QuantizedLinear
    else { return false }
    return query.groupSize == key.groupSize
      && query.groupSize == value.groupSize
      && query.bits == key.bits
      && query.bits == value.bits
      && query.mode == key.mode
      && query.mode == value.mode
      && query.bias != nil
      && key.bias != nil
      && value.bias != nil
      && query.biases != nil
      && key.biases != nil
      && value.biases != nil
  }

  fileprivate func prepareFusedQKVProjection() {
    guard let query = queryProjection as? QuantizedLinear,
      let key = keyProjection as? QuantizedLinear,
      let value = valueProjection as? QuantizedLinear,
      supportsFusedQKVProjection
    else { return }
    if fusedQKVProjection == nil {
      let projection = QuantizedLinear(
        weight: concatenated([query.weight, key.weight, value.weight]),
        bias: concatenated([query.bias!, key.bias!, value.bias!]),
        scales: concatenated([query.scales, key.scales, value.scales]),
        biases: concatenated([
          query.biases!, key.biases!, value.biases!,
        ]),
        groupSize: query.groupSize,
        bits: query.bits,
        mode: query.mode)
      eval(
        [projection.weight, projection.scales, projection.bias!]
          + (projection.biases.map { [$0] } ?? []))
      fusedQKVProjection = projection
    }
    usesFusedQKVForVerification = true
  }
}

private final class CompiledQwen2MLP: Module, UnaryLayer {
  @ModuleInfo(key: "gate_proj") var gate: Linear
  @ModuleInfo(key: "down_proj") var down: Linear
  @ModuleInfo(key: "up_proj") var up: Linear

  init(dimensions: Int, hiddenDimensions: Int) {
    _gate.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
    _down.wrappedValue = Linear(hiddenDimensions, dimensions, bias: false)
    _up.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
  }

  func callAsFunction(_ input: MLXArray) -> MLXArray {
    down(compiledQwen2SiluProduct(gate(input), up(input)))
  }
}

private final class CompiledQwen2TransformerBlock: Module {
  @ModuleInfo(key: "self_attn") var attention: CompiledQwen2Attention
  let mlp: CompiledQwen2MLP

  @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
  @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm

  init(_ configuration: CompiledQwen2Configuration) {
    _attention.wrappedValue = CompiledQwen2Attention(configuration)
    mlp = CompiledQwen2MLP(
      dimensions: configuration.hiddenSize,
      hiddenDimensions: configuration.intermediateSize)
    _inputLayerNorm.wrappedValue = RMSNorm(
      dimensions: configuration.hiddenSize,
      eps: configuration.rmsNormEps)
    _postAttentionLayerNorm.wrappedValue = RMSNorm(
      dimensions: configuration.hiddenSize,
      eps: configuration.rmsNormEps)
  }

  func callAsFunction(
    _ input: MLXArray,
    mask: MLXFast.ScaledDotProductAttentionMaskMode,
    cache: KVCache?,
    skipMLP: Bool = false
  ) -> MLXArray {
    let residual = attention(
      inputLayerNorm(input), mask: mask, cache: cache)
    let hidden = input + residual
    guard !skipMLP else { return hidden }
    let mlpResidual = mlp(postAttentionLayerNorm(hidden))
    return hidden + mlpResidual
  }
}

private final class CompiledQwen2InnerModel: Module {
  @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
  fileprivate let layers: [CompiledQwen2TransformerBlock]
  let norm: RMSNorm
  private let verificationMLPSkipLayers: Set<Int>
  private let verificationMLPLongBatchExtraSkipLayers: Set<Int>

  init(
    _ configuration: CompiledQwen2Configuration,
    verificationMLPSkipLayers: Set<Int>,
    verificationMLPLongBatchExtraSkipLayers: Set<Int>
  ) {
    precondition(configuration.vocabularySize > 0)
    precondition(
      verificationMLPSkipLayers.allSatisfy {
        (0..<configuration.hiddenLayers).contains($0)
      })
    precondition(
      verificationMLPLongBatchExtraSkipLayers.allSatisfy {
        (0..<configuration.hiddenLayers).contains($0)
      })
    self.verificationMLPSkipLayers = verificationMLPSkipLayers
    self.verificationMLPLongBatchExtraSkipLayers =
      verificationMLPLongBatchExtraSkipLayers
    _embedTokens.wrappedValue = Embedding(
      embeddingCount: configuration.vocabularySize,
      dimensions: configuration.hiddenSize)
    layers = (0..<configuration.hiddenLayers).map { _ in
      CompiledQwen2TransformerBlock(configuration)
    }
    norm = RMSNorm(
      dimensions: configuration.hiddenSize,
      eps: configuration.rmsNormEps)
  }

  func callAsFunction(
    _ inputs: MLXArray,
    cache: [KVCache]? = nil,
    extraVerificationMLPSkipLayers: Set<Int> = []
  ) -> MLXArray {
    var hidden = embedTokens(inputs)
    let mask = createAttentionMask(h: hidden, cache: cache?.first)
    let isVerification = 2...4 ~= inputs.dim(1)
    let isLongVerification = 3...4 ~= inputs.dim(1)
    for (index, layer) in layers.enumerated() {
      hidden = layer(
        hidden,
        mask: mask,
        cache: cache?[index],
        skipMLP: isVerification
          && (verificationMLPSkipLayers.contains(index)
            || (isLongVerification
              && verificationMLPLongBatchExtraSkipLayers.contains(index))
            || extraVerificationMLPSkipLayers.contains(index)))
    }
    return norm(hidden)
  }
}

private final class CompiledQwen2Model:
  Module, LLMModel, KVCacheDimensionProvider
{
  let vocabularySize: Int
  let kvHeads: [Int]
  let model: CompiledQwen2InnerModel
  private let configuration: CompiledQwen2Configuration

  @ModuleInfo(key: "lm_head") var lmHead: Linear?

  init(
    _ configuration: CompiledQwen2Configuration,
    verificationMLPSkipLayers: Set<Int>,
    verificationMLPLongBatchExtraSkipLayers: Set<Int>
  ) {
    self.configuration = configuration
    vocabularySize = configuration.vocabularySize
    kvHeads = (0..<configuration.hiddenLayers).map { _ in
      configuration.kvHeads
    }
    model = CompiledQwen2InnerModel(
      configuration,
      verificationMLPSkipLayers: verificationMLPSkipLayers,
      verificationMLPLongBatchExtraSkipLayers:
        verificationMLPLongBatchExtraSkipLayers)
    if !configuration.tieWordEmbeddings {
      _lmHead.wrappedValue = Linear(
        configuration.hiddenSize,
        configuration.vocabularySize,
        bias: false)
    }
  }

  func callAsFunction(
    _ inputs: MLXArray,
    cache: [KVCache]?
  ) -> MLXArray {
    logits(model(inputs, cache: cache))
  }

  fileprivate func verificationLogits(
    _ inputs: MLXArray,
    cache: [KVCache]?,
    extraMLPSkipLayers: Set<Int>
  ) -> MLXArray {
    logits(model(
      inputs,
      cache: cache,
      extraVerificationMLPSkipLayers: extraMLPSkipLayers))
  }

  private func logits(_ output: MLXArray) -> MLXArray {
    if let lmHead {
      return lmHead(output)
    }
    return model.embedTokens.asLinear(output)
  }

  func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
    var weights = weights
    if configuration.tieWordEmbeddings {
      weights["lm_head.weight"] = nil
    }
    return weights.filter {
      !$0.key.contains("self_attn.rotary_emb.inv_freq")
    }
  }

  fileprivate func prepareFusedQKVVerificationProjections() -> Bool {
    guard model.layers.allSatisfy({
        $0.attention.supportsFusedQKVProjection
      })
    else { return false }
    for layer in model.layers {
      layer.attention.prepareFusedQKVProjection()
    }
    return true
  }

}

extension CompiledQwen2Model: LoRAModel {
  var loraLayers: [Module] { model.layers }
}

/// Projects tied Qwen logits through only the token rows that can be useful for
/// the current SQL request. Ordinary callers receive the vocabulary-shaped
/// tensor expected by MLXLM; the evaluated n-gram path can instead consume the
/// compact rows directly. The transformer and KV-cache path are exactly the
/// same as the full-head model.
private final class RestrictedCompiledQwen2Model:
  Module, LanguageModel, @unchecked Sendable
{
  private let base: CompiledQwen2Model
  fileprivate let allowedTokenIDs: [Int]
  fileprivate let returnsCompactLogits: Bool
  private let tokenIDs: MLXArray
  private let weight: MLXArray
  private let scales: MLXArray
  private let biases: MLXArray?
  private let groupSize: Int
  private let bits: Int
  private let mode: QuantizationMode

  init?(
    base: CompiledQwen2Model,
    allowedTokenIDs: [Int],
    returnsCompactLogits: Bool
  ) {
    guard
      let embedding = base.model.leafModules().flattened()
        .first(where: { $0.0 == "embed_tokens" })?.1
        as? QuantizedEmbedding
    else { return nil }
    let allowedTokenIDs = Array(Set(allowedTokenIDs.filter {
      0..<base.vocabularySize ~= $0
    })).sorted()
    guard !allowedTokenIDs.isEmpty else { return nil }

    let tokenIDs = MLXArray(allowedTokenIDs)
    let weight = embedding.weight[tokenIDs]
    let scales = embedding.scales[tokenIDs]
    let biases = embedding.biases.map { $0[tokenIDs] }
    self.base = base
    self.allowedTokenIDs = allowedTokenIDs
    self.returnsCompactLogits = returnsCompactLogits
    self.tokenIDs = tokenIDs
    self.weight = weight
    self.scales = scales
    self.biases = biases
    self.groupSize = embedding.groupSize
    self.bits = embedding.bits
    self.mode = embedding.mode
    eval([weight, scales] + (biases.map { [$0] } ?? []))
  }

  func prepare(
    _ input: LMInput,
    cache: [KVCache],
    windowSize: Int?
  ) throws -> PrepareResult {
    try base.prepare(input, cache: cache, windowSize: windowSize)
  }

  func callAsFunction(
    _ inputs: MLXArray,
    cache: [KVCache]?
  ) -> MLXArray {
    restrictedLogits(base.model(inputs, cache: cache))
  }

  fileprivate func verificationLogits(
    _ inputs: MLXArray,
    cache: [KVCache]?,
    extraMLPSkipLayers: Set<Int>
  ) -> MLXArray {
    restrictedLogits(base.model(
      inputs,
      cache: cache,
      extraVerificationMLPSkipLayers: extraMLPSkipLayers))
  }

  private func restrictedLogits(_ hidden: MLXArray) -> MLXArray {
    let restrictedLogits = quantizedMM(
      hidden,
      weight,
      scales: scales,
      biases: biases,
      transpose: true,
      groupSize: groupSize,
      bits: bits,
      mode: mode)
    if returnsCompactLogits {
      return restrictedLogits
    }
    let fullShape = restrictedLogits.shape.dropLast() + [base.vocabularySize]
    let fullLogits = full(
      fullShape,
      values: MLXArray(-Float.infinity),
      dtype: restrictedLogits.dtype)
    let indices = broadcast(
      tokenIDs.reshaped([1, 1, -1]),
      to: restrictedLogits.shape)
    return putAlong(
      fullLogits,
      indices,
      values: restrictedLogits,
      axis: -1)
  }

  func newCache(parameters: GenerateParameters?) -> [KVCache] {
    base.newCache(parameters: parameters)
  }

  func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
    base.sanitize(weights: weights)
  }
}

enum CompiledQwen2ModelFactory {
  static func make(
    verificationMLPSkipLayers: Set<Int> = [],
    verificationMLPLongBatchExtraSkipLayers: Set<Int> = []
  ) -> LLMModelFactory {
    let registry = ModelTypeRegistry<LanguageModel>(creators: [
      "qwen2": { data in
        let configuration = try JSONDecoder.json5().decode(
          CompiledQwen2Configuration.self,
          from: data)
        return CompiledQwen2Model(
          configuration,
          verificationMLPSkipLayers: verificationMLPSkipLayers,
          verificationMLPLongBatchExtraSkipLayers:
            verificationMLPLongBatchExtraSkipLayers)
      }
    ])
    return LLMModelFactory(
      typeRegistry: registry,
      modelRegistry: LLMRegistry.shared)
  }

  static func vocabularySize(of model: any LanguageModel) -> Int? {
    (model as? CompiledQwen2Model)?.vocabularySize
  }

  static func restricting(
    _ model: any LanguageModel,
    to allowedTokenIDs: [Int],
    returnsCompactLogits: Bool = false
  ) -> (any LanguageModel)? {
    guard let model = model as? CompiledQwen2Model else { return nil }
    return RestrictedCompiledQwen2Model(
      base: model,
      allowedTokenIDs: allowedTokenIDs,
      returnsCompactLogits: returnsCompactLogits)
  }

  static func compactGlobalTokenIDs(
    of model: any LanguageModel
  ) -> [Int]? {
    guard
      let model = model as? RestrictedCompiledQwen2Model,
      model.returnsCompactLogits
    else { return nil }
    return model.allowedTokenIDs
  }

  static func verificationLogits(
    of model: any LanguageModel,
    inputs: MLXArray,
    cache: [KVCache]?,
    extraMLPSkipLayers: Set<Int>
  ) -> MLXArray? {
    if let model = model as? RestrictedCompiledQwen2Model {
      return model.verificationLogits(
        inputs,
        cache: cache,
        extraMLPSkipLayers: extraMLPSkipLayers)
    }
    if let model = model as? CompiledQwen2Model {
      return model.verificationLogits(
        inputs,
        cache: cache,
        extraMLPSkipLayers: extraMLPSkipLayers)
    }
    return nil
  }

  static func prepareFusedQKVVerificationProjections(
    in model: any LanguageModel
  ) -> Bool {
    guard let model = model as? CompiledQwen2Model else { return false }
    return model.prepareFusedQKVVerificationProjections()
  }

}
