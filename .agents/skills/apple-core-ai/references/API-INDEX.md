# API & symbol index — Core AI: the 27-cycle inference runtime and its conversion pipeline

**387 symbols, of 1212 across the series, that the guide parts in this skill cover — with whether each exists in the captured 26.5 / 27.0 beta SDK interfaces.**

> A `✓` means the leading type name appears in the corresponding captured `.swiftinterface`; dotted uppercase type paths must be one contiguous subpath of a qualified or declared type chain. A longer chain may prove any contiguous type subpath, but `::` module qualifiers never become nested types. Lowercase members are not signature-matched — the guides carry the signature-level citations. **Blank in both columns means the spelling is not SDK-confirmed**: package types and C/ObjC-only API legitimately show neither, but so does a reconstruction. A symbol absent from this page may still be covered elsewhere in the series — the full index is at https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/API-INDEX.md. Sliced on 2026-09-22; regenerate with `./scripts/build-skills.sh` rather than editing by hand.

## FoundationModels  <sub>13 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `ChatCompletionsLanguageModel` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `CoreAILanguageModel` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md), [7.README](part-07-coreai-swift-runtime/README.md) +2 more |
| `CoreAILanguageModel.init` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `CoreAILanguageModels` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md) +4 more |
| `FoundationModels` | ✓ | ✓ | [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `@Generable` | ✓ | ✓ | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.README](part-07-coreai-swift-runtime/README.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [10.README](part-10-coreai-hardware-authoring-debugging/README.md) +3 more |
| `LanguageModel` |  | ✓ | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.README](part-07-coreai-swift-runtime/README.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `LanguageModelExecutor` |  | ✓ | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `LanguageModelSession` | ✓ | ✓ | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [10.README](part-10-coreai-hardware-authoring-debugging/README.md), [7.README](part-07-coreai-swift-runtime/README.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) +2 more |
| `MLXLanguageModel` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `SystemLanguageModel` | ✓ | ✓ | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.README](part-07-coreai-swift-runtime/README.md) |
| `Tool` | ✓ | ✓ | [7.README](part-07-coreai-swift-runtime/README.md) |
| `Transcript.Reasoning` |  | ✓ | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |

## CoreAI  <sub>71 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `AIModel` |  | ✓ | [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.5](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md), [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md) +12 more |
| `AIModel.bookmarkData` |  | ✓ | [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `AIModel.deviceArchitectureName` |  | ✓ | [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `AIModel.init` |  | ✓ | [7.README](part-07-coreai-swift-runtime/README.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) |
| `AIModel.load` |  | ✓ | [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md) |
| `AIModel.loadFunction(named:)` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `AIModel.specialize` |  | ✓ | [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [7.README](part-07-coreai-swift-runtime/README.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `AIModelAsset` |  | ✓ | [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) +3 more |
| `AIModelAsset.isValid(at:)` |  | ✓ | [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `AIModelAsset.load` |  | ✓ | [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md) |
| `AIModelAsset.load(path)` |  | ✓ | [8.3](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `AIModelAsset.Summary` |  | ✓ | [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [9.README](part-09-coreai-compression-numerics/README.md) |
| `AIModelAssetMetadata` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `AIModelCache` |  | ✓ | [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) +3 more |
| `AIModelCache.default` |  | ✓ | [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `AIModelCache.default.deleteEntries(for:)` |  | ✓ | [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `AIModelCache.default.model(for:options:)` |  | ✓ | [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md) |
| `AIModelCache.model(for:options:)` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.README](part-07-coreai-swift-runtime/README.md), [7.5](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md) |
| `AIModelCache.Policy` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md) |
| `AIModelCacheError.failedToPurge` |  |  | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `AIModelError` |  |  | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.README](part-07-coreai-swift-runtime/README.md), [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md) |
| `AssetError` | ✓ | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.README](part-07-coreai-swift-runtime/README.md), [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) +1 more |
| `AssetError.Kind` |  | ✓ | [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) |
| `ComputeStream` |  | ✓ | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) +2 more |
| `CoreAI` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.README](part-07-coreai-swift-runtime/README.md) +3 more |
| `CoreAI.framework` |  | ✓ | [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md), [10.README](part-10-coreai-hardware-authoring-debugging/README.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) +3 more |
| `CoreAIAsset` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.README](part-07-coreai-swift-runtime/README.md), [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md) |
| `CoreAIAsset.AssetError` |  | ✓ | [7.README](part-07-coreai-swift-runtime/README.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md) |
| `CoreAICache` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [7.README](part-07-coreai-swift-runtime/README.md) |
| `CoreAICommon` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [7.README](part-07-coreai-swift-runtime/README.md) |
| `CoreAICompiler` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [7.README](part-07-coreai-swift-runtime/README.md) |
| `CoreAIDelegates` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [7.README](part-07-coreai-swift-runtime/README.md) |
| `CoreAIDelegates.AIModelError` |  |  | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `CoreAIRuntime` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.README](part-07-coreai-swift-runtime/README.md), [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md) |
| `ImageDescriptor` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `InferenceFunction` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [7.5](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md), [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md) +8 more |
| `InferenceFunction.__call__` |  | ✓ | [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `InferenceFunction.AsyncValue` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `InferenceFunction.encode` |  | ✓ | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `InferenceFunction.Inputs` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `InferenceFunction.MutableViews` |  | ✓ | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.README](part-07-coreai-swift-runtime/README.md), [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md) |
| `InferenceFunction.MutableViews()` |  | ✓ | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md) |
| `InferenceFunction.Outputs` |  | ✓ | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `InferenceFunction.run` |  | ✓ | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [8.README](part-08-coreai-pytorch-conversion/README.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) +1 more |
| `InferenceFunctionDescriptor` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `InferenceFunctionDescriptor.stateNames` |  | ✓ | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `InferenceValue` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `InferenceValue.Descriptor` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `InferenceValue.Kind` |  | ✓ | [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md) |
| `InferenceValue.MutableViewRepresentable` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `InferenceValue.NamedMutableViews.take(_:)` |  | ✓ | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `InferenceValue.ndArray` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `NDArray` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md) +10 more |
| `NDArray.from_descriptor` |  | ✓ | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md) |
| `NDArray.init(descriptor:)` |  | ✓ | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `NDArray.InterleaveLayout` |  | ✓ | [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) |
| `NDArray.MutableView` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `NDArray.ScalarType` |  | ✓ | [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.README](part-07-coreai-swift-runtime/README.md), [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md) +1 more |
| `NDArray.ScalarType.type` |  | ✓ | [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `NDArray.strides` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) |
| `NDArray.View` |  | ✓ | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) |
| `NDArrayDescriptor` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) |
| `NDArrayDescriptor.minimumByteCount` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `NDArrayDescriptor.preferredStrides` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `NDArrayDescriptor.resolvingDynamicDimensions(_:)` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `NDArrayDescriptor.shape` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `SpecializationOptions` |  | ✓ | [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md) +12 more |
| `SpecializationOptions.cpu_only()` |  | ✓ | [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `SpecializationOptions.cpuOnly` |  | ✓ | [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md) |
| `SpecializationOptions.default()` |  | ✓ | [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `SpecializationOptions.expectFrequentReshapes` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |

## MLX  <sub>5 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `MLX` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `MLXCXGrammar` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `MLXFoundationModels` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `MLXGuidedGeneration` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `MLXLMCommon` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |

## Speech  <sub>4 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `SpeechAnalyzer` | ✓ | ✓ | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `SpeechBundle` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.README](part-07-coreai-swift-runtime/README.md), [7.5](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md) |
| `SpeechTests` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `SpeechTranscriber` | ✓ | ✓ | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |

## Metal/MPP  <sub>15 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `Metal.framework` |  | ✓ | [8.3](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md) |
| `MetalParameter` |  |  | [8.3](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md), [8.README](part-08-coreai-pytorch-conversion/README.md) |
| `MetalPerformancePrimitives` |  |  | [8.3](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md) |
| `MetalPerformancePrimitives.framework` |  |  | [8.3](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md) |
| `MPSCommandBufferImageCache` |  |  | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `MPSGraphAICodeCompilerDelegate` |  |  | [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `MPSGraphCompositeSampler` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `MPSGraphExecutableExecutionDescriptor` |  |  | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `MTLBuffer` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.README](part-07-coreai-swift-runtime/README.md) |
| `MTLTensor` |  |  | [8.3](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [8.README](part-08-coreai-pytorch-conversion/README.md) |
| `MTLTensorAuxiliaryPlaneDescriptor` |  |  | [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [8.3](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md), [8.README](part-08-coreai-pytorch-conversion/README.md), [9.README](part-09-coreai-compression-numerics/README.md) +2 more |
| `MTLTensorAuxiliaryPlaneDescriptorMap` |  |  | [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [8.3](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md) |
| `MTLTensorDataType` |  |  | [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [8.3](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md), [8.README](part-08-coreai-pytorch-conversion/README.md), [9.README](part-09-coreai-compression-numerics/README.md) +1 more |
| `MTLTensorDescriptor.auxiliaryPlanes` |  |  | [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [8.README](part-08-coreai-pytorch-conversion/README.md), [8.3](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md), [9.README](part-09-coreai-compression-numerics/README.md) +2 more |
| `MTLTensorUsageMachineLearning` |  |  | [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) |

## SwiftUI  <sub>1 symbol</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `View` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |

## Media/Core*  <sub>6 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `CGImage` | ✓ | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.5](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md) |
| `CGImageSourceCreateImageAtIndex` |  |  | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `CIImage` | ✓ | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `CVMutablePixelBuffer` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `CVPixelBuffer` | ✓ | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `CVReadOnlyPixelBuffer` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |

## Swift/Foundation  <sub>11 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `Array` | ✓ | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `ArrayAttr` |  |  | [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md) |
| `Codable` | ✓ | ✓ | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `Data` | ✓ | ✓ | [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md) |
| `Duration` | ✓ | ✓ | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `Duration.inSeconds` | ✓ | ✓ | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `JSONSerialization` |  | ✓ | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `Sendable` | ✓ | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `SendableMetatype` | ✓ | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `String` | ✓ | ✓ | [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `URL` | ✓ | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |

## other  <sub>261 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `AIProgram` |  |  | [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md) +4 more |
| `AIProgram.optimize()` |  |  | [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md), [8.README](part-08-coreai-pytorch-conversion/README.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md) +2 more |
| `AIProgram.save_asset(path)` |  |  | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md) |
| `AllocationType` |  |  | [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md), [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [10.README](part-10-coreai-hardware-authoring-debugging/README.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `ANECompiler` |  |  | [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md) |
| `ANECompilerService` |  |  | [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `AsyncMutableValue` |  | ✓ | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `AsyncMutableViews` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `AsyncSequence` | ✓ | ✓ | [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md) |
| `AsyncStream` |  |  | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `AsyncValue` |  | ✓ | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md) |
| `AsyncValue.ndArray` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.README](part-07-coreai-swift-runtime/README.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `BackgroundAssets` |  |  | [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md) |
| `BatchNorm` |  |  | [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [8.3](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md) |
| `BidirectionalSDPA` |  |  | [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `BitwiseCopyable` | ✓ | ✓ | [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) |
| `Bool` | ✓ | ✓ | [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md) |
| `BundleError.missingAsset` |  |  | [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md), [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `BundleKind` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.5](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md) |
| `CaseIterable` | ✓ | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `ChannelStructured` |  |  | [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md) |
| `CLILogger` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md) |
| `CLILogger.setLevel(to:)` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `Collection` | ✓ | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `CompositeSampler` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `ComputeUnitKind` |  | ✓ | [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md) +1 more |
| `Configuration` | ✓ | ✓ | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `ConstrainedDecodingStrategy` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `ConstrainedGenerationSession` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.README](part-07-coreai-swift-runtime/README.md) |
| `Context.alloc` | ✓ | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md) |
| `CoreAIDiffusion` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.README](part-07-coreai-swift-runtime/README.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.5](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md) +1 more |
| `CoreAIDiffusionPipeline` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.5](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md) |
| `CoreAIExecutor` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `CoreAIExecutor.Configuration` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `CoreAIExecutor.respondConstrained` |  |  | [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `CoreAIImageSegmenter` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.5](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md) |
| `CoreAILM` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `CoreAIModelAssetError` |  |  | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `CoreAIObjectDetection` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [7.5](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md), [7.README](part-07-coreai-swift-runtime/README.md) +2 more |
| `CoreAIObjectDetector` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.5](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md) |
| `CoreAIPipelinedEngine` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `CoreAIRunner` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `CoreAIRunner.init(from bundle:)` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `CoreAISegmentation` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [7.5](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md), [7.README](part-07-coreai-swift-runtime/README.md) +3 more |
| `CoreAISegmentationEngine` |  |  | [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [7.5](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md) +3 more |
| `CoreAISequentialEngine` |  |  | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) +2 more |
| `CoreAISequentialVLMEngine` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `CoreAIShared` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.5](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md) |
| `CoreAISpeech` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.README](part-07-coreai-swift-runtime/README.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.5](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md) +1 more |
| `CoreAIStateSession` |  |  | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `CoreAIVisionLanguageModel` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `CoreML` | ✓ | ✓ | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md) |
| `CoreMLExportError` |  |  | [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) |
| `CorePasses` |  |  | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [8.README](part-08-coreai-pytorch-conversion/README.md), [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md) |
| `CorePasses._CORE_OPTIMIZE` |  |  | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md) |
| `CorePasses._PROPAGATE_HANDLE_UPDATES` |  |  | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md) |
| `CorePasses._UPDATE_SIGNATURE_TO_HANDLES` |  |  | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md) |
| `CXGrammar` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `D83AP` |  |  | [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) |
| `DecodingStrategy` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `DetectedObject.boundingBox` |  |  | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `DictAttr` |  |  | [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md) |
| `Dim` |  |  | [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [8.3](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md), [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md) |
| `DLTensor` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `Dropout` |  |  | [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [8.3](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md) |
| `DynamicSliceUpdate` |  |  | [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `E8M0` |  |  | [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) |
| `EAGER` |  |  | [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md), [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [8.README](part-08-coreai-pytorch-conversion/README.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md) |
| `Embedding` |  |  | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) |
| `Encodable` | ✓ | ✓ | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `EngineFactory` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `EngineFactory.autoDetectVariant` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `EngineOptions` |  |  | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `ENOENT` |  |  | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `Equatable` | ✓ | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `Error` | ✓ | ✓ | [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md) |
| `Escapable` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `ExecutionMode` |  |  | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md) |
| `ExecutionMode.GRAPH` |  |  | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [8.README](part-08-coreai-pytorch-conversion/README.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md) |
| `ExportBackend._TORCH` |  |  | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md) |
| `ExportBackend.CoreAI` |  |  | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [9.README](part-09-coreai-compression-numerics/README.md), [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md) |
| `ExportBackend.CoreML` |  |  | [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md) |
| `ExportedProgram` |  |  | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md) +3 more |
| `ExternalizeSpec` |  |  | [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md), [8.README](part-08-coreai-pytorch-conversion/README.md) |
| `F.conv` |  |  | [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `F.linear` |  |  | [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `F.scaled_dot_product_attention` |  |  | [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md), [8.README](part-08-coreai-pytorch-conversion/README.md), [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md) |
| `FakeTensor` |  |  | [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [8.3](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md) |
| `False` |  |  | [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md), [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [9.README](part-09-coreai-compression-numerics/README.md) +1 more |
| `Float` | ✓ | ✓ | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `Float16` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `Float32` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `Float8E4M3FN` |  |  | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) |
| `FunctionMap` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.5](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md) |
| `GatedDeltaUpdate` |  |  | [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [8.3](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md), [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md) |
| `GatherMM` |  |  | [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md), [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [8.3](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md) +2 more |
| `GELUReauthored` |  |  | [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `GenerationOptions` | ✓ | ✓ | [7.README](part-07-coreai-swift-runtime/README.md), [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `GenerationOptions.temperature` | ✓ | ✓ | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `GenerationSchema` | ✓ | ✓ | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `GrammarMatcher` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `GRAPH` |  |  | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md) |
| `GraphModule` |  |  | [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md) |
| `GraphNames` |  |  | [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md) |
| `GrowingLogitsBuffer` |  |  | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `HardwareConstraints` |  |  | [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md), [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [8.README](part-08-coreai-pytorch-conversion/README.md), [10.README](part-10-coreai-hardware-authoring-debugging/README.md) |
| `Hashable` | ✓ | ✓ | [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md), [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `ImagePreprocessor` |  |  | [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md) |
| `ImportError` |  |  | [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `InferenceEngine` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `InlineArray` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.README](part-07-coreai-swift-runtime/README.md) |
| `Input` | ✓ | ✓ | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `Int` | ✓ | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `Int32` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `Int4` |  |  | [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `INT8` |  |  | [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) |
| `InterleaveLayout` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) |
| `IntxTensor` |  |  | [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [9.1](part-09-coreai-compression-numerics/references/01-quantization.md) |
| `IOSurface` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `KeyError` |  |  | [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `Kind` | ✓ | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.README](part-07-coreai-swift-runtime/README.md), [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md) |
| `KMeansPalettizer` |  |  | [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [8.README](part-08-coreai-pytorch-conversion/README.md) +3 more |
| `KMeansPalettizer.finalize` |  |  | [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [9.README](part-09-coreai-compression-numerics/README.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `KMeansPalettizer.finalize()` |  |  | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md) |
| `KMeansPalettizerConfig` |  |  | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md) |
| `KVCache` |  |  | [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md), [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md) |
| `KVCache.update_and_fetch` |  |  | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `KVCacheError.capacityExceeded` |  |  | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `KVCacheHandler` |  |  | [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `KVCacheStrategy` |  |  | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `KVCacheStrategy.auto` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `LanguageBundle` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `LanguageBundle.loadTokenizer()` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `LayerNormReauthored` |  |  | [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md), [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md) |
| `LegalizeToCoreOptions` |  |  | [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `Linear` |  |  | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md), [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md) |
| `LoadEmbeddings` |  |  | [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) |
| `Location` |  |  | [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md) |
| `MagnitudePruner` |  |  | [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [9.README](part-09-coreai-compression-numerics/README.md) |
| `@MainActor` | ✓ | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `Makefile` |  |  | [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md), [9.README](part-09-coreai-compression-numerics/README.md) |
| `MINVAL` |  |  | [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [9.1](part-09-coreai-compression-numerics/references/01-quantization.md) |
| `Mode.DEBUG` |  |  | [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md) |
| `Mode.RELEASE` |  |  | [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `ModelBundle` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.5](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `ModelBundle.ComponentKey` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `ModelBundle.verify()` |  |  | [7.5](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `ModelInspector` |  |  | [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [10.README](part-10-coreai-hardware-authoring-debugging/README.md), [9.1](part-09-coreai-compression-numerics/references/01-quantization.md) +1 more |
| `ModelResources` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `ModelResources.shared(for:)` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `ModelStructure` |  |  | [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md), [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `ModuleKMeansPalettizerConfig` |  |  | [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [9.1](part-09-coreai-compression-numerics/references/01-quantization.md) |
| `ModuleQuantizerConfig` |  |  | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md) |
| `MutableBuffers.buffer_mutation` |  |  | [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md) |
| `MutableRawSpan` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `MutableRawView` |  | ✓ | [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `MutableSpan` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `MutableView` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) |
| `MutableView.copyElements(from:)` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `MutableViews` |  | ✓ | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md) +2 more |
| `Mutex` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `MyModel.aimodel` |  |  | [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md) |
| `NamedMutableViews.take(_:)` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `None` |  |  | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) +5 more |
| `NotImplementedError` |  |  | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md) |
| `NSError` |  |  | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) |
| `Outputs` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [7.README](part-07-coreai-swift-runtime/README.md), [7.5](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md) |
| `Outputs.remove` |  | ✓ | [7.README](part-07-coreai-swift-runtime/README.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `Outputs.remove(_:)` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `Package.resolved` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.README](part-07-coreai-swift-runtime/README.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `PalettizationSpec` |  |  | [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md) |
| `PATH` |  |  | [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md) |
| `Path` |  |  | [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `PerBlockGranularity` |  |  | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) |
| `PerChannelGranularity` |  |  | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) |
| `PerformanceMetrics.setPromptTokenCount(_:)` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `PerGroupedChannelGranularity` |  |  | [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md) |
| `PerTensorGranularity` |  |  | [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) |
| `PhotosPicker` |  |  | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `PipelineGate` |  |  | [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `Policy` |  | ✓ | [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `PreparedModel` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.5](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [8.README](part-08-coreai-pytorch-conversion/README.md) |
| `PreparedModel.prepare` |  |  | [7.5](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md), [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `PreparedModel.prepare(at:)` |  |  | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.5](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md) |
| `PreparedModel.resolveCoreAIModelURL` |  |  | [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `PreparedModel.structure` |  |  | [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md), [7.5](part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md) |
| `Progress` | ✓ | ✓ | [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md) |
| `PurgeConditions` |  | ✓ | [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `QATSchedule` |  |  | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [9.README](part-09-coreai-compression-numerics/README.md), [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md) |
| `QQLinear` |  |  | [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) |
| `QScheme` |  |  | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) |
| `QuantizationSpec` |  |  | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [9.README](part-09-coreai-compression-numerics/README.md) |
| `QuantizedLinear._extra_repr` |  |  | [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) |
| `Quantizer` |  |  | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md) +3 more |
| `Quantizer.finalize` |  |  | [9.README](part-09-coreai-compression-numerics/README.md), [9.1](part-09-coreai-compression-numerics/references/01-quantization.md) |
| `Quantizer.prepare` |  |  | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md) |
| `QuantizerConfig` |  |  | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md), [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md) |
| `QuantizerConfig.presets.w8()` |  |  | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `RawSpan` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `RawView` |  | ✓ | [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `RawView.init` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `RawView.view(as:)` |  | ✓ | [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `RELEASE` |  |  | [10.README](part-10-coreai-hardware-authoring-debugging/README.md), [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md) |
| `RMSNorm` |  |  | [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) +2 more |
| `RMSNormGated` |  |  | [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `RMSNormImpl` |  |  | [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [8.README](part-08-coreai-pytorch-conversion/README.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) +1 more |
| `RMSNormPlusOne` |  |  | [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `RoPE` |  |  | [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [8.3](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) +2 more |
| `RoPECache` |  |  | [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `RuntimeError` |  |  | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md) |
| `SamplingConfiguration` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `Scalar` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md) |
| `ScalarType` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md) |
| `ScalarType.type` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) |
| `SDPA` |  |  | [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md), [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) +2 more |
| `Segment.box` | ✓ | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `SegmentationExportConfig` |  |  | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md) |
| `SegmentationPostprocessor.decodeSegment` |  |  | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `SegmentationVisualization.renderPromptBoxes` |  |  | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `Self` | ✓ | ✓ | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md) |
| `Sequence` | ✓ | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.README](part-07-coreai-swift-runtime/README.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `Setup` |  |  | [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `SharedObserverModulePattern` |  |  | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md) |
| `SIGSEGV` |  |  | [7.README](part-07-coreai-swift-runtime/README.md), [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md) |
| `Softplus` |  |  | [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [9.1](part-09-coreai-compression-numerics/references/01-quantization.md) |
| `Span` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.README](part-07-coreai-swift-runtime/README.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `Span.product` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `StaticKVCache` |  |  | [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [10.README](part-10-coreai-hardware-authoring-debugging/README.md) |
| `StaticShapeEngine` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md), [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `StopReason` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `Summary.computeTypes` | ✓ | ✓ | [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) |
| `SwiGLU` |  |  | [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `SwitchGLU` |  |  | [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md), [8.3](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md) |
| `SwitchLinear` |  |  | [10.1](part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md), [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md), [9.1](part-09-coreai-compression-numerics/references/01-quantization.md) +2 more |
| `SymInt` |  |  | [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md) |
| `SystemExit` |  |  | [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md), [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md) |
| `TaskGroup` |  |  | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md), [7.README](part-07-coreai-swift-runtime/README.md) |
| `TemporaryDirectory` |  |  | [9.1](part-09-coreai-compression-numerics/references/01-quantization.md) |
| `Tensor` |  |  | [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [8.3](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md) |
| `TextGenerator` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.README](part-07-coreai-swift-runtime/README.md) |
| `TODO` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `TokenHistory` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md) |
| `TokenizerInfo` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `TokenizerInfo.init` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `TorchConverter` |  |  | [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [7.3](part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md), [8.3](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md) +8 more |
| `TorchConverter.Mode` |  |  | [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [10.2](part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md) |
| `TorchMetalKernel` |  |  | [8.3](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md), [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md) +2 more |
| `Transferable` |  | ✓ | [7.1](part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md) |
| `True` |  |  | [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md) |
| `TypeError` |  |  | [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [8.3](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md), [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md) +2 more |
| `UintxTensor` |  |  | [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [9.1](part-09-coreai-compression-numerics/references/01-quantization.md) |
| `UserDefaults` |  |  | [7.2](part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md) |
| `UserWarning` |  |  | [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md), [8.README](part-08-coreai-pytorch-conversion/README.md), [8.3](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md) +1 more |
| `Value` | ✓ | ✓ | [8.2](part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md) |
| `ValueError` |  |  | [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md), [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [8.1](part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md), [8.3](part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md) +3 more |
| `Variant` |  | ✓ | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `VisionConfig` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `WARNING` |  |  | [7.README](part-07-coreai-swift-runtime/README.md), [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [9.README](part-09-coreai-compression-numerics/README.md) |
| `WeakBox` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md), [10.3](part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md) |
| `ZooFMProvider` |  |  | [7.4](part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) |
| `ZP` |  |  | [9.3](part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md), [9.1](part-09-coreai-compression-numerics/references/01-quantization.md), [9.2](part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md) |
