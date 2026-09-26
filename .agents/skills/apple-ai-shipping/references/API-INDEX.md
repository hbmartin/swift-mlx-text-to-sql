# API & symbol index — Shipping and operating on-device AI in a released app

**87 symbols, of 1212 across the series, that the guide parts in this skill cover — with whether each exists in the captured 26.5 / 27.0 beta SDK interfaces.**

> A `✓` means the leading type name appears in the corresponding captured `.swiftinterface`; dotted uppercase type paths must be one contiguous subpath of a qualified or declared type chain. A longer chain may prove any contiguous type subpath, but `::` module qualifiers never become nested types. Lowercase members are not signature-matched — the guides carry the signature-level citations. **Blank in both columns means the spelling is not SDK-confirmed**: package types and C/ObjC-only API legitimately show neither, but so does a reconstruction. A symbol absent from this page may still be covered elsewhere in the series — the full index is at https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/API-INDEX.md. Sliced on 2026-09-22; regenerate with `./scripts/build-skills.sh` rather than editing by hand.

## FoundationModels  <sub>11 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `Adapter` | ✓ | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `CoreAILanguageModel` |  |  | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `CoreAILanguageModels` |  |  | [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md) |
| `FoundationModels` | ✓ | ✓ | [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md), [15.README](part-15-shipping-and-operating/README.md) |
| `@Generable` | ✓ | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md), [15.README](part-15-shipping-and-operating/README.md), [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md) |
| `LanguageModel` |  | ✓ | [15.README](part-15-shipping-and-operating/README.md), [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `LanguageModelSession` | ✓ | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `SystemLanguageModel` | ✓ | ✓ | [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md), [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md), [15.README](part-15-shipping-and-operating/README.md) |
| `SystemLanguageModel.Adapter(name:)` | ✓ | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `SystemLanguageModel.availability` | ✓ | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `SystemLanguageModel.default.availability` | ✓ | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |

## CoreAI  <sub>23 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `AIModel` |  | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md), [15.README](part-15-shipping-and-operating/README.md), [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md) |
| `AIModel.bookmarkData` |  | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `AIModel.deviceArchitectureName` |  | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `AIModel.load` |  | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `AIModel.specialize` |  | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `AIModelAsset` |  | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `AIModelAsset.isValid(at:)` |  | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `AIModelAsset.Metadata` |  | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `AIModelCache` |  | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md), [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md) |
| `AIModelCache.default.deleteEntries(for:)` |  | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `AIModelCacheError.failedToPurge` |  |  | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `AIModelError` |  |  | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md), [15.README](part-15-shipping-and-operating/README.md) |
| `AssetError` | ✓ | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `CoreAI` |  | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `CoreAI.framework` |  | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `CoreAIAsset` |  | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `CoreAICache` |  | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `CoreAIDelegates` |  | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `CoreAIRuntime` |  | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `InferenceFunction` |  | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md), [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md), [15.README](part-15-shipping-and-operating/README.md) |
| `InferenceFunctionDescriptor` |  | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md), [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md) |
| `NDArray` |  | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md), [15.README](part-15-shipping-and-operating/README.md) |
| `SpecializationOptions` |  | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md), [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md), [15.README](part-15-shipping-and-operating/README.md) |

## MLX  <sub>2 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `MLX` |  |  | [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md) |
| `MLXLMCommon` |  |  | [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md) |

## Metal/MPP  <sub>1 symbol</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `MTLBuffer` |  | ✓ | [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md), [15.README](part-15-shipping-and-operating/README.md) |

## Swift/Foundation  <sub>8 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `Foundation` | ✓ | ✓ | [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md) |
| `Sendable` | ✓ | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `String` | ✓ | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md), [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md) |
| `Task` |  |  | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `URL` | ✓ | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `URLError` |  |  | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `URLSession` |  |  | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md), [15.README](part-15-shipping-and-operating/README.md) |
| `URLSessionConfiguration.default` |  |  | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |

## other  <sub>42 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `AIProgram.save_asset(path)` |  |  | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `ANECompilerService` |  |  | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `AsyncSequence` | ✓ | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `BackgroundAssets` |  |  | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `BGContinuedProcessingTask` |  |  | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md), [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md) |
| `Bool` | ✓ | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `CancellationError` |  |  | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `D83AP` |  |  | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md), [15.README](part-15-shipping-and-operating/README.md) |
| `Documents` |  | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `Double` | ✓ | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `EngineOptions` |  |  | [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md), [15.README](part-15-shipping-and-operating/README.md) |
| `Equatable` | ✓ | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `GenerationPowerPolicy` |  |  | [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md) |
| `GPU.maxRecommendedWorkingSetBytes()` |  |  | [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md) |
| `Hashable` | ✓ | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `Info.plist` |  |  | [15.README](part-15-shipping-and-operating/README.md), [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md) |
| `Int` | ✓ | ✓ | [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md), [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `Kind` | ✓ | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `KVCacheStrategy` |  |  | [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md), [15.README](part-15-shipping-and-operating/README.md) |
| `LanguageBundle` |  |  | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `LSSupportsOpeningDocumentsInPlace` |  |  | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `Memory` |  |  | [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md) |
| `Memory.cacheLimit` |  |  | [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md), [15.README](part-15-shipping-and-operating/README.md) |
| `Memory.memoryLimit` |  |  | [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md) |
| `Memory.snapshot()` |  |  | [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md) |
| `Memory.Snapshot.activeMemory` |  |  | [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md) |
| `Memory.Snapshot.delta(_:)` |  |  | [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md) |
| `ModelContainer` |  |  | [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md), [15.README](part-15-shipping-and-operating/README.md) |
| `ModelDelivery` |  |  | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `MyModel.aimodel` |  |  | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `NSError` |  |  | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `OptionSet` | ✓ | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `Policy` |  | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `ProcessInfo.ThermalState` |  |  | [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md), [15.README](part-15-shipping-and-operating/README.md) |
| `Progress` | ✓ | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `PurgeConditions` |  | ✓ | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `StoreDownloaderExtension` |  |  | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `TorchMetalKernel` |  |  | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `UIFileSharingEnabled` |  |  | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `UIKit` |  |  | [15.2](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md) |
| `UIRequiredDeviceCapabilities` |  |  | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| `UserDefaults` |  |  | [15.1](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
