import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import CREGInference

/// Exercises the compiled Qwen2 graph itself, on a small randomly initialized
/// model, to pin the execution path: an explicit verification call applies
/// the configured two-to-four-token MLP skips, while the ordinary forward
/// pass — the prefill tail and one-token serial steps — never does.
@Suite(.serialized) struct CompiledQwen2VerificationExecutionTests {
  static let configuration = Data(
    """
    {
      "hidden_size": 32,
      "num_hidden_layers": 3,
      "intermediate_size": 64,
      "num_attention_heads": 4,
      "num_key_value_heads": 2,
      "rms_norm_eps": 1e-6,
      "vocab_size": 96,
      "tie_word_embeddings": true,
      "rope_theta": 10000
    }
    """.utf8)

  /// `swift test` loads the test bundle in a way MLX's automatic Metal
  /// library search does not see, so point MLX at the library SwiftPM
  /// copied next to this test bundle before the first array is evaluated.
  init() {
    Self.configureMetalLibrary()
  }

  private final class BundleToken {}

  private static func configureMetalLibrary() {
    guard GPU.metallib == nil else { return }
    let testBundle = Bundle(for: BundleToken.self)
    var candidates: [URL] = []
    if let resources = testBundle.resourceURL {
      candidates.append(
        resources.appendingPathComponent(
          "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"))
    }
    candidates.append(
      testBundle.bundleURL.deletingLastPathComponent().appendingPathComponent(
        "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"))
    if let found = candidates.first(where: {
      FileManager.default.fileExists(atPath: $0.path)
    }) {
      GPU.metallib = found
    }
  }

  /// Two models built from the same seed share every parameter, so their
  /// outputs differ only through the skip configuration.
  private func makeModel(
    skipLayers: Set<Int>, longBatchExtraSkipLayers: Set<Int> = []
  ) throws -> any LanguageModel {
    MLXRandom.seed(1_337)
    let model = try CompiledQwen2ModelFactory.makeModel(
      configurationJSON: Self.configuration,
      verificationMLPSkipLayers: skipLayers,
      verificationMLPLongBatchExtraSkipLayers: longBatchExtraSkipLayers)
    return model
  }

  private func tokens(_ count: Int) -> MLXArray {
    MLXArray((0..<count).map { Int32(($0 * 7 + 3) % 96) }).reshaped([1, count])
  }

  private func ordinaryLogits(_ model: any LanguageModel, _ input: MLXArray) -> MLXArray {
    let output = model(LMInput.Text(tokens: input), cache: nil, state: nil).logits
    eval(output)
    return output
  }

  private func verificationLogits(
    _ model: any LanguageModel, _ input: MLXArray, extra: Set<Int> = []
  ) throws -> MLXArray {
    let logits = try #require(
      CompiledQwen2ModelFactory.verificationLogits(
        of: model, inputs: input, cache: nil, extraMLPSkipLayers: extra))
    eval(logits)
    return logits
  }

  private func same(_ lhs: MLXArray, _ rhs: MLXArray) -> Bool {
    allClose(lhs, rhs, rtol: 1e-5, atol: 1e-6).item(Bool.self)
  }

  @Test(arguments: [2, 3, 4])
  func ordinaryVerificationCheckAppliesTheConfiguredSkip(_ length: Int) throws {
    let skipping = try makeModel(skipLayers: [1])
    let reference = try makeModel(skipLayers: [])
    let input = tokens(length)
    // Same seed, same weights: the plain forward passes agree exactly.
    #expect(same(ordinaryLogits(skipping, input), ordinaryLogits(reference, input)))
    // The explicit verification call omits layer 1's MLP on the skipping
    // model only, with no confidence-gated extras involved.
    let skipped = try verificationLogits(skipping, input)
    let unskipped = try verificationLogits(reference, input)
    #expect(!same(skipped, unskipped))
    // The reference model has nothing configured, so its verification path
    // is the plain forward pass.
    #expect(same(unskipped, ordinaryLogits(reference, input)))
  }

  @Test(arguments: [2, 3, 4])
  func prefillTailOfTheSameLengthKeepsEveryMLP(_ length: Int) throws {
    let skipping = try makeModel(skipLayers: [1], longBatchExtraSkipLayers: [0])
    let reference = try makeModel(skipLayers: [])
    let input = tokens(length)
    // The prompt path hands short prompts back untouched; the iterator then
    // runs the ordinary forward pass over them, which must not skip.
    let parameters = GenerateParameters(maxTokens: 1)
    let cache = try skipping.newCache(parameters: parameters)
    let prepared = try skipping.prepare(
      LMInput(tokens: input.squeezed(axis: 0)), cache: cache, state: nil,
      prefill: parameters.prefill)
    guard case .tokens(let text) = prepared else {
      Issue.record("Expected the short prompt to be returned as tokens")
      return
    }
    let prefill = skipping(text[text: .newAxis], cache: cache, state: nil).logits
    eval(prefill)
    let referenceCache = try reference.newCache(parameters: parameters)
    let referencePrefill = reference(
      text[text: .newAxis], cache: referenceCache, state: nil).logits
    eval(referencePrefill)
    #expect(same(prefill, referencePrefill))
  }

  @Test func oneTokenStepIsNeverAVerificationCheck() throws {
    let skipping = try makeModel(skipLayers: [0, 1, 2], longBatchExtraSkipLayers: [2])
    let reference = try makeModel(skipLayers: [])
    let input = tokens(1)
    #expect(same(ordinaryLogits(skipping, input), ordinaryLogits(reference, input)))
    #expect(same(
      try verificationLogits(skipping, input),
      try verificationLogits(reference, input)))
  }

  @Test func longBatchAndConfidenceExtrasApplyOnlyToTheirLengths() throws {
    let skipping = try makeModel(skipLayers: [], longBatchExtraSkipLayers: [2])
    let reference = try makeModel(skipLayers: [])
    // Two tokens: the long-batch extra does not apply.
    #expect(same(
      try verificationLogits(skipping, tokens(2)),
      try verificationLogits(reference, tokens(2))))
    // Three and four tokens: it does.
    #expect(!same(
      try verificationLogits(skipping, tokens(3)),
      try verificationLogits(reference, tokens(3))))
    #expect(!same(
      try verificationLogits(skipping, tokens(4)),
      try verificationLogits(reference, tokens(4))))
    // A confidence-gated extra skip changes only the call that names it.
    #expect(!same(
      try verificationLogits(reference, tokens(2), extra: [0]),
      try verificationLogits(reference, tokens(2))))
  }

  @Test func compiledModelsRouteThroughTheExplicitVerificationPath() throws {
    let model = try makeModel(skipLayers: [1])
    #expect(CompiledQwen2ModelFactory.isCompiledQwen2(model))
    #expect(
      CompiledQwen2ModelFactory.verificationLogits(
        of: model, inputs: tokens(3), cache: nil, extraMLPSkipLayers: []) != nil)
  }
}
