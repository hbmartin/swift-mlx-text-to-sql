import Testing
@testable import CREGInference

@Suite struct CompiledQwen2VerificationPolicyTests {
  @Test(arguments: [2, 3, 4])
  func shortPrefillTailKeepsEveryMLP(_ length: Int) {
    #expect(!CompiledQwen2VerificationPolicy.skipsMLP(
      layer: 16, inputLength: length, isVerification: false,
      skipLayers: [16], longBatchExtraSkipLayers: [16],
      extraSkipLayers: [16]))
  }

  @Test(arguments: [2, 3, 4])
  func explicitVerificationUsesConfiguredSkip(_ length: Int) {
    #expect(CompiledQwen2VerificationPolicy.skipsMLP(
      layer: 16, inputLength: length, isVerification: true,
      skipLayers: [16], longBatchExtraSkipLayers: [],
      extraSkipLayers: []))
  }
}
