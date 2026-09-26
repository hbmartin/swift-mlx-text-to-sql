# API & symbol index — MLX in Python and Swift, and bridges to Core AI

**334 symbols, of 1212 across the series, that the guide parts in this skill cover — with whether each exists in the captured 26.5 / 27.0 beta SDK interfaces.**

> A `✓` means the leading type name appears in the corresponding captured `.swiftinterface`; dotted uppercase type paths must be one contiguous subpath of a qualified or declared type chain. A longer chain may prove any contiguous type subpath, but `::` module qualifiers never become nested types. Lowercase members are not signature-matched — the guides carry the signature-level citations. **Blank in both columns means the spelling is not SDK-confirmed**: package types and C/ObjC-only API legitimately show neither, but so does a reconstruction. A symbol absent from this page may still be covered elsewhere in the series — the full index is at https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/API-INDEX.md. Sliced on 2026-09-22; regenerate with `./scripts/build-skills.sh` rather than editing by hand.

## FoundationModels  <sub>21 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `ChatCompletionsLanguageModel` |  |  | [12.5](part-12-mlx-python/references/05-serving-and-distributed.md), [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [12.README](part-12-mlx-python/README.md), [12.6](part-12-mlx-python/references/06-finetuning-and-porting-models.md) |
| `CoreAILanguageModel` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [14.README](part-14-bridges-between-stacks/README.md), [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `CoreAILanguageModels` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [14.README](part-14-bridges-between-stacks/README.md) |
| `DynamicProfile` |  | ✓ | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `FoundationModels` | ✓ | ✓ | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `FoundationModels.LanguageModel` |  | ✓ | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `@Generable` | ✓ | ✓ | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [13.README](part-13-mlx-swift/README.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) +2 more |
| `GeneratedContent` | ✓ | ✓ | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `LanguageModel` |  | ✓ | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [12.5](part-12-mlx-python/references/05-serving-and-distributed.md), [13.README](part-13-mlx-swift/README.md), [12.6](part-12-mlx-python/references/06-finetuning-and-porting-models.md) +2 more |
| `LanguageModelError.unsupportedCapability` |  | ✓ | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `LanguageModelError.unsupportedGenerationGuide` |  | ✓ | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `LanguageModelExecutor` |  | ✓ | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [12.5](part-12-mlx-python/references/05-serving-and-distributed.md), [13.README](part-13-mlx-swift/README.md) |
| `LanguageModelMacro` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `LanguageModelSession` | ✓ | ✓ | [12.5](part-12-mlx-python/references/05-serving-and-distributed.md), [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) +4 more |
| `MLXLanguageModel` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.README](part-13-mlx-swift/README.md), [14.README](part-14-bridges-between-stacks/README.md) |
| `Profile` |  | ✓ | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `SystemLanguageModel` | ✓ | ✓ | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [13.README](part-13-mlx-swift/README.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `SystemLanguageModel.Adapter(name:)` | ✓ | ✓ | [12.6](part-12-mlx-python/references/06-finetuning-and-porting-models.md) |
| `Tool` | ✓ | ✓ | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [13.README](part-13-mlx-swift/README.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `Transcript.Entry` | ✓ | ✓ | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `TranscriptConverter` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |

## CoreAI  <sub>15 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `AIModel` |  | ✓ | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md), [14.README](part-14-bridges-between-stacks/README.md) |
| `AIModel.load` |  | ✓ | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `AIModelAsset` |  | ✓ | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `AIModelAsset.load` |  | ✓ | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `AIModelAsset.load(path)` |  | ✓ | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `AIModelCache` |  | ✓ | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `CoreAI` |  | ✓ | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `CoreAI.framework` |  | ✓ | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `InferenceFunction` |  | ✓ | [14.README](part-14-bridges-between-stacks/README.md), [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `InferenceFunction.MutableViews` |  | ✓ | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `NDArray` |  | ✓ | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md), [14.README](part-14-bridges-between-stacks/README.md) |
| `SpecializationOptions` |  | ✓ | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md), [14.README](part-14-bridges-between-stacks/README.md) |
| `SpecializationOptions.default` |  | ✓ | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `SpecializationOptions.default()` |  | ✓ | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `SpecializationOptions.expectFrequentReshapes` |  | ✓ | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md), [14.README](part-14-bridges-between-stacks/README.md) |

## MLX  <sub>23 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `MLX` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `MLXArray` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [13.README](part-13-mlx-swift/README.md) |
| `MLXChatExample` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.README](part-13-mlx-swift/README.md) |
| `MLXCXGrammar` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `MLXDownloadProgress` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `MLXEmbedders` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.README](part-13-mlx-swift/README.md) |
| `MLXEmbedders.loadModelContainer(hub:configuration:)` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `MLXEmbedders.ModelConfiguration.nomic_text_v1_5` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `MLXEmbeddersHuggingFace` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.README](part-13-mlx-swift/README.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `MLXFast.scaledDotProductAttention` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `MLXFoundationModels` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.README](part-13-mlx-swift/README.md) +2 more |
| `MLXFoundationModelsTests` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `MLXGuidedGeneration` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [13.README](part-13-mlx-swift/README.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `MLXHuggingFace` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.README](part-13-mlx-swift/README.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `MLXHuggingFaceMacros` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `MLXLLM` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.README](part-13-mlx-swift/README.md) |
| `MLXLMCommon` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.README](part-13-mlx-swift/README.md) |
| `MLXLMCommon.generate(input:parameters:context:)` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `MLXLMHuggingFace` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.README](part-13-mlx-swift/README.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `MLXLMTokenizers` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.README](part-13-mlx-swift/README.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `MLXMNIST` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `MLXNN` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `MLXVLM` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [13.README](part-13-mlx-swift/README.md) |

## Speech  <sub>1 symbol</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `SpeechBundle` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |

## CoreSpotlight  <sub>1 symbol</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `SpotlightSearchTool` |  | ✓ | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |

## Metal/MPP  <sub>6 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `MetalPerformancePrimitives` |  |  | [12.3](part-12-mlx-python/references/03-quantization.md) |
| `MTLBuffer` |  | ✓ | [12.README](part-12-mlx-python/README.md), [12.2](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md), [12.3](part-12-mlx-python/references/03-quantization.md) |
| `MTLTensor.auxiliaryPlanes` |  |  | [12.3](part-12-mlx-python/references/03-quantization.md) |
| `MTLTensorAuxiliaryPlaneDescriptor` |  |  | [12.2](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md), [12.3](part-12-mlx-python/references/03-quantization.md) |
| `MTLTensorDataType` |  |  | [12.2](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md), [12.3](part-12-mlx-python/references/03-quantization.md) |
| `MTLTensorDescriptor.auxiliaryPlanes` |  |  | [12.2](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md), [12.3](part-12-mlx-python/references/03-quantization.md) |

## Media/Core*  <sub>3 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `CGImageSourceCreateImageAtIndex` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `CIImage` | ✓ | ✓ | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `CVPixelBuffer` | ✓ | ✓ | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |

## Swift/Foundation  <sub>20 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `Array` | ✓ | ✓ | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `ArrayAttr` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `ArraysCache` |  |  | [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [12.5](part-12-mlx-python/references/05-serving-and-distributed.md) |
| `Codable` | ✓ | ✓ | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `Data` | ✓ | ✓ | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `Foundation` | ✓ | ✓ | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `Foundation.Progress` | ✓ | ✓ | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `FoundationModelsIntegration` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `JSONEncoder` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `JSONSerialization` |  | ✓ | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `Sendable` | ✓ | ✓ | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.README](part-13-mlx-swift/README.md) |
| `@Sendable` | ✓ | ✓ | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `SendableBox` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.README](part-13-mlx-swift/README.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `SendableBox.consume()` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `String` | ✓ | ✓ | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [13.README](part-13-mlx-swift/README.md) |
| `Task` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `Task.detached` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `URL` | ✓ | ✓ | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `URLSession` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `URLSessionConfiguration.default` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |

## other  <sub>244 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `AIProgram` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `AIProgram._from_mlir_module` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md), [14.README](part-14-bridges-between-stacks/README.md) |
| `AIProgram.optimize()` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `ArgMaxSampler` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `Arguments` | ✓ | ✓ | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `AsyncSequence` | ✓ | ✓ | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `AsyncStream` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `Attachment` |  | ✓ | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `AttributeError` |  |  | [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [12.6](part-12-mlx-python/references/06-finetuning-and-porting-models.md) |
| `AutoTokenizer.from(directory:)` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `AutoTokenizer.register(_:for:)` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `Availability` | ✓ | ✓ | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `BatchGenerator` |  |  | [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [12.5](part-12-mlx-python/references/05-serving-and-distributed.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `BatchKVCache` |  |  | [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [12.5](part-12-mlx-python/references/05-serving-and-distributed.md), [12.README](part-12-mlx-python/README.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `BatchRotatingKVCache` |  |  | [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [12.5](part-12-mlx-python/references/05-serving-and-distributed.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `BenchmarkHelpers` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `BGContinuedProcessingTask` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `Bool` | ✓ | ✓ | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `BooleanOptionalAction` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md), [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [12.6](part-12-mlx-python/references/06-finetuning-and-porting-models.md) |
| `Broadcast` |  |  | [12.1](part-12-mlx-python/references/01-core-fundamentals.md), [12.2](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md) |
| `BundleKind` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `CacheList` |  |  | [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [12.5](part-12-mlx-python/references/05-serving-and-distributed.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `CancellationError` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `Chat.Message` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `ChatSession` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.README](part-13-mlx-swift/README.md), [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md) +1 more |
| `ChunkedKVCache` |  |  | [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [12.README](part-12-mlx-python/README.md), [12.5](part-12-mlx-python/references/05-serving-and-distributed.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `CompositeSampler` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `ComputeUnitKind` |  | ✓ | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `ConcatenateKVCache` |  |  | [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [12.5](part-12-mlx-python/references/05-serving-and-distributed.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `ConstrainedGenerationSession` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `ConversionConfig` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md), [14.README](part-14-bridges-between-stacks/README.md) |
| `CoreAIExecutor` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `CoreAILM` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `CoreAIModelAssetError` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `CoreAISequentialVLMEngine` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `CoreAIShared` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `CoreAIStateSession` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `CoreAITensorSpec._to_mlir_type()` |  |  | [14.README](part-14-bridges-between-stacks/README.md), [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `CXGrammar` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `DEBUG` |  |  | [12.5](part-12-mlx-python/references/05-serving-and-distributed.md) |
| `DecodingError` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `DictAttr` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `DIFF` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md), [14.README](part-14-bridges-between-stacks/README.md) |
| `DistributedGroup` |  |  | [12.README](part-12-mlx-python/README.md), [12.5](part-12-mlx-python/references/05-serving-and-distributed.md) |
| `DLTensor` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `Documents` |  | ✓ | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `DoRAEmbedding.from_base` |  |  | [12.6](part-12-mlx-python/references/06-finetuning-and-porting-models.md) |
| `Double` | ✓ | ✓ | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `Downloader` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [13.README](part-13-mlx-swift/README.md) |
| `Dtype` |  |  | [12.2](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md) |
| `DynamicGenerationSchema` | ✓ | ✓ | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `DynamicSliceUpdate` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `EmbedderModelContainer` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `EmbedderModelFactory.shared.loadContainer(from:using:configuration:)` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `EmbedderRegistry.nomic_text_v1_5` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `Embedding` |  |  | [12.6](part-12-mlx-python/references/06-finetuning-and-porting-models.md) |
| `Encodable` | ✓ | ✓ | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `EngineFactory` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `Executor` |  | ✓ | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `Executor.Configuration` |  | ✓ | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `FAIL` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md), [14.README](part-14-bridges-between-stacks/README.md) |
| `False` |  |  | [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [12.5](part-12-mlx-python/references/05-serving-and-distributed.md), [12.2](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md), [12.6](part-12-mlx-python/references/06-finetuning-and-porting-models.md) +2 more |
| `FileNotFoundError` |  |  | [12.6](part-12-mlx-python/references/06-finetuning-and-porting-models.md) |
| `Float` | ✓ | ✓ | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `Float16` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `FunctionMap` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `GatedDeltaUpdate` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `GatherMM` |  |  | [12.3](part-12-mlx-python/references/03-quantization.md), [12.1](part-12-mlx-python/references/01-core-fundamentals.md) |
| `GenerateParameters` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.README](part-13-mlx-swift/README.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `GenerateParameters.sampler()` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `Generation` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `GenerationOptions` | ✓ | ✓ | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `GenerationOptions.SamplingMode.Kind` |  | ✓ | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `GenerationPowerPolicy` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `GenerationResponse` |  |  | [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `GenerationSchema` | ✓ | ✓ | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `GLM4ToolCallParser` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `GPU.maxRecommendedWorkingSetBytes()` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `GrammarConstraint` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `GrammarMatcher` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `GrammarTokenizer` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `GuidedGenerationError` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `GuidedGenerationLoop` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `GuidedGenerationLoop.run` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `HubApi` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.README](part-13-mlx-swift/README.md) |
| `HubClient` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `HubClient.default` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `HuggingFace` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `HuggingFace.HubClient` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `HuggingFace.Repo.ID` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `InferenceEngine.supportsLogits` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `INFO` |  |  | [12.5](part-12-mlx-python/references/05-serving-and-distributed.md), [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md) |
| `Info.plist` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `Input` | ✓ | ✓ | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `Int` | ✓ | ✓ | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `IntegrationPackage` |  |  | [13.README](part-13-mlx-swift/README.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `IntegrationTestHelpers` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `KeyError` |  |  | [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [12.5](part-12-mlx-python/references/05-serving-and-distributed.md), [12.6](part-12-mlx-python/references/06-finetuning-and-porting-models.md) |
| `KimiK2ToolCallParser` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `KVCache` |  |  | [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [12.5](part-12-mlx-python/references/05-serving-and-distributed.md), [13.README](part-13-mlx-swift/README.md) +1 more |
| `KVCacheSimple` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md) |
| `KVCacheStrategy` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `KVCacheStrategy.auto` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `LanguageBundle` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `Linear` |  |  | [12.3](part-12-mlx-python/references/03-quantization.md), [12.6](part-12-mlx-python/references/06-finetuning-and-porting-models.md) |
| `Llama3ToolCallParser` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `LLMBasic` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.README](part-13-mlx-swift/README.md) |
| `LLMEval` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.README](part-13-mlx-swift/README.md) |
| `LLMModelFactory._load` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `LLMRegistry` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `LMInput` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `LMOutput` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `LMOutput.State` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `Location` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `Logger` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `LoRAConfiguration` |  |  | [12.6](part-12-mlx-python/references/06-finetuning-and-porting-models.md) |
| `LoRAContainer` |  |  | [12.6](part-12-mlx-python/references/06-finetuning-and-porting-models.md), [13.README](part-13-mlx-swift/README.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `LoRATrain` |  |  | [12.6](part-12-mlx-python/references/06-finetuning-and-porting-models.md), [13.README](part-13-mlx-swift/README.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `LoRATrainingExample` |  |  | [12.6](part-12-mlx-python/references/06-finetuning-and-porting-models.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `LRUPromptCache` |  |  | [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [12.5](part-12-mlx-python/references/05-serving-and-distributed.md) |
| `LSSupportsOpeningDocumentsInPlace` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `@MainActor` | ✓ | ✓ | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `MambaCache` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `MediaProcessing` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `Memory` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `Memory.cacheLimit` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [12.6](part-12-mlx-python/references/06-finetuning-and-porting-models.md), [13.README](part-13-mlx-swift/README.md) +1 more |
| `Memory.memoryLimit` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `Memory.snapshot()` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.README](part-13-mlx-swift/README.md) |
| `Memory.Snapshot.activeMemory` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `Memory.Snapshot.delta(_:)` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `MemoryArguments` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `MiniMaxM2ToolCallParser` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `MistralToolCallParser` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `Model` | ✓ | ✓ | [12.1](part-12-mlx-python/references/01-core-fundamentals.md), [12.6](part-12-mlx-python/references/06-finetuning-and-porting-models.md) |
| `ModelBundle` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `ModelBundle.ComponentKey` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `ModelBundle.verify()` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `ModelConfiguration` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `ModelConfiguration.modelDirectory(hub:)` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `ModelConfiguration.preparePrompt` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `ModelConfiguration.tokenizerId` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `ModelConfigurationResolver` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [13.README](part-13-mlx-swift/README.md) |
| `ModelContainer` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.README](part-13-mlx-swift/README.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `ModelContext` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.README](part-13-mlx-swift/README.md) |
| `ModelFactory` |  |  | [13.README](part-13-mlx-swift/README.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `ModelFactory._loadContainer` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `ModelFactoryError.noModelFactoryAvailable` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [13.README](part-13-mlx-swift/README.md) |
| `ModelProvider` |  |  | [12.5](part-12-mlx-python/references/05-serving-and-distributed.md), [12.6](part-12-mlx-python/references/06-finetuning-and-porting-models.md) |
| `ModelRegistry` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `ModelStructure` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `Module` |  |  | [12.1](part-12-mlx-python/references/01-core-fundamentals.md), [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `@ModuleInfo` |  |  | [13.README](part-13-mlx-swift/README.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `MovePhotoToStepTool` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `MTPDrafterTypeRegistry.shared` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `MutableBuffers.buffer_mutation` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `MutableViews` |  | ✓ | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md), [14.README](part-14-bridges-between-stacks/README.md) |
| `NaiveStreamingDetokenizer` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `NameError` |  |  | [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [12.6](part-12-mlx-python/references/06-finetuning-and-porting-models.md) |
| `NaN` |  |  | [12.3](part-12-mlx-python/references/03-quantization.md) |
| `Noema.entitlements` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `None` |  |  | [12.1](part-12-mlx-python/references/01-core-fundamentals.md), [12.5](part-12-mlx-python/references/05-serving-and-distributed.md), [12.6](part-12-mlx-python/references/06-finetuning-and-porting-models.md), [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md) +4 more |
| `NoSystemMessageGenerator` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.README](part-13-mlx-swift/README.md) |
| `NotImplementedError` |  |  | [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [14.README](part-14-bridges-between-stacks/README.md), [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `NSClassFromString` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.README](part-13-mlx-swift/README.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `@Observable` | ✓ | ✓ | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `Optional` | ✓ | ✓ | [12.3](part-12-mlx-python/references/03-quantization.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `Output` | ✓ | ✓ | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `Package.resolved` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `@ParameterInfo` |  |  | [13.README](part-13-mlx-swift/README.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `PASS` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md), [14.README](part-14-bridges-between-stacks/README.md) |
| `PhotosPicker` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `Processing` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `Progress` | ✓ | ✓ | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `PromptTrie` |  |  | [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [12.5](part-12-mlx-python/references/05-serving-and-distributed.md) |
| `PromptTrie.search` |  |  | [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [12.5](part-12-mlx-python/references/05-serving-and-distributed.md) |
| `PythonicToolCallParser` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `QQLinear` |  |  | [12.3](part-12-mlx-python/references/03-quantization.md) |
| `QuantizedEmbedding` |  |  | [12.3](part-12-mlx-python/references/03-quantization.md), [12.6](part-12-mlx-python/references/06-finetuning-and-porting-models.md) |
| `QuantizedKVCache` |  |  | [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [12.3](part-12-mlx-python/references/03-quantization.md), [12.5](part-12-mlx-python/references/05-serving-and-distributed.md) |
| `QuantizedLinear` |  |  | [12.3](part-12-mlx-python/references/03-quantization.md), [12.6](part-12-mlx-python/references/06-finetuning-and-porting-models.md) |
| `QuantizedLinear._extra_repr` |  |  | [12.3](part-12-mlx-python/references/03-quantization.md) |
| `QuantizedSwitchLinear` |  |  | [12.3](part-12-mlx-python/references/03-quantization.md), [12.6](part-12-mlx-python/references/06-finetuning-and-porting-models.md) |
| `ReasoningConfig.isSpecialToken` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `ReasoningHeuristics` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `Response.Action.updateUsage(input:output:)` |  | ✓ | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `RMSNorm` |  |  | [12.3](part-12-mlx-python/references/03-quantization.md) |
| `RotatingKVCache` |  |  | [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [12.5](part-12-mlx-python/references/05-serving-and-distributed.md), [12.3](part-12-mlx-python/references/03-quantization.md) +1 more |
| `RotatingKVCache.toQuantized()` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.README](part-13-mlx-swift/README.md) |
| `RotatingQuantizedKVCache` |  |  | [12.3](part-12-mlx-python/references/03-quantization.md), [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md) |
| `SamplingConfiguration` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `SamplingMode.Kind` |  | ✓ | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `Select` |  |  | [12.1](part-12-mlx-python/references/01-core-fundamentals.md), [12.2](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md) |
| `Sequence` | ✓ | ✓ | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `SerialAccessContainer` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `SocketThread` |  |  | [12.README](part-12-mlx-python/README.md), [12.5](part-12-mlx-python/references/05-serving-and-distributed.md), [12.6](part-12-mlx-python/references/06-finetuning-and-porting-models.md) |
| `SpeculativeTokenIterator` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.README](part-13-mlx-swift/README.md) |
| `SpeculativeTokenIterator.speculateRound()` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md) |
| `StableDiffusion` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `StopReason` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `SwiGLU` |  |  | [12.3](part-12-mlx-python/references/03-quantization.md) |
| `SwitchGLU` |  |  | [12.3](part-12-mlx-python/references/03-quantization.md) |
| `SwitchLinear` |  |  | [12.3](part-12-mlx-python/references/03-quantization.md), [12.6](part-12-mlx-python/references/06-finetuning-and-porting-models.md), [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md) |
| `TemporaryDirectory` |  |  | [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [12.5](part-12-mlx-python/references/05-serving-and-distributed.md) |
| `TextStateMachine` |  |  | [12.5](part-12-mlx-python/references/05-serving-and-distributed.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `TM` |  |  | [12.3](part-12-mlx-python/references/03-quantization.md) |
| `TN` |  |  | [12.3](part-12-mlx-python/references/03-quantization.md) |
| `TODO` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `TokenIterator` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [13.README](part-13-mlx-swift/README.md) |
| `TokenIterator.init` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `Tokenizer` |  |  | [13.README](part-13-mlx-swift/README.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `TokenizerError.missingChatTemplate` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `TokenizerInfo` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `TokenizerInfo.init` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `TokenizerInfoCache` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `TokenizerLoader` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `TokenizerReplacementRegistry` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `Tokenizers` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `TokenizerWrapper.apply_chat_template` |  |  | [12.README](part-12-mlx-python/README.md), [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [12.6](part-12-mlx-python/references/06-finetuning-and-porting-models.md) |
| `ToolCall` | ✓ | ✓ | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `ToolCallFormat` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.README](part-13-mlx-swift/README.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `ToolCallFormat.generateToolCallID()` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `ToolCallFormat.infer` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.README](part-13-mlx-swift/README.md) |
| `ToolCallingModeResolution` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `ToolCallParser` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.README](part-13-mlx-swift/README.md) |
| `ToolCallProcessor` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
| `TorchConverter` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `Transferable` |  | ✓ | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `True` |  |  | [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [12.1](part-12-mlx-python/references/01-core-fundamentals.md), [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md), [12.2](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md) +3 more |
| `TurboQuantKVCache` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `UIFileSharingEnabled` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `UIGraphicsImageRenderer` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `UIImage` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `UnboundLocalError` |  |  | [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [12.6](part-12-mlx-python/references/06-finetuning-and-porting-models.md) |
| `UserInput` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.README](part-13-mlx-swift/README.md) |
| `UserInputProcessor` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md), [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `UserWarning` |  |  | [12.3](part-12-mlx-python/references/03-quantization.md) |
| `ValueError` |  |  | [12.4](part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md), [12.1](part-12-mlx-python/references/01-core-fundamentals.md), [12.2](part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md), [12.5](part-12-mlx-python/references/05-serving-and-distributed.md) |
| `VisionConfig` |  |  | [14.1](part-14-bridges-between-stacks/references/01-mlx2coreai-and-third-party-bridges.md) |
| `VLMError.imageRequired` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) |
| `VLMRegistry` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `WARNING` |  |  | [12.5](part-12-mlx-python/references/05-serving-and-distributed.md), [12.3](part-12-mlx-python/references/03-quantization.md) |
| `WiredMemoryManager` |  |  | [13.1](part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `XMLFunctionParser` |  |  | [13.2](part-13-mlx-swift/references/02-generation-tools-and-caching.md) |
| `ZooLanguageModel` |  |  | [13.3](part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) |
