# API & symbol index — Evaluations: measuring on-device model output

**162 symbols, of 1212 across the series, that the guide parts in this skill cover — with whether each exists in the captured 26.5 / 27.0 beta SDK interfaces.**

> A `✓` means the leading type name appears in the corresponding captured `.swiftinterface`; dotted uppercase type paths must be one contiguous subpath of a qualified or declared type chain. A longer chain may prove any contiguous type subpath, but `::` module qualifiers never become nested types. Lowercase members are not signature-matched — the guides carry the signature-level citations. **Blank in both columns means the spelling is not SDK-confirmed**: package types and C/ObjC-only API legitimately show neither, but so does a reconstruction. A symbol absent from this page may still be covered elsewhere in the series — the full index is at https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/API-INDEX.md. Sliced on 2026-09-22; regenerate with `./scripts/build-skills.sh` rather than editing by hand.

## FoundationModels  <sub>17 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `FoundationModels` | ✓ | ✓ | [6.README](part-06-evaluations/README.md) |
| `FoundationModels.Transcript` | ✓ | ✓ | [6.README](part-06-evaluations/README.md), [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md) |
| `@Generable` | ✓ | ✓ | [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md), [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.README](part-06-evaluations/README.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md) +1 more |
| `Generable` | ✓ | ✓ | [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) |
| `@Guide` | ✓ | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md), [6.README](part-06-evaluations/README.md) |
| `LanguageModel` |  | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md) |
| `LanguageModelSession` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md), [6.README](part-06-evaluations/README.md), [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) |
| `PrivateCloudComputeLanguageModel` |  | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) |
| `PrivateCloudComputeLanguageModel.Error.quotaLimitReached(_:)` |  | ✓ | [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) |
| `Prompt` | ✓ | ✓ | [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md), [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md) |
| `StructuredTranscript` |  | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) |
| `SystemLanguageModel` | ✓ | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.README](part-06-evaluations/README.md) |
| `SystemLanguageModel.default` | ✓ | ✓ | [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md) |
| `SystemLanguageModel.default.availability` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `Tool` | ✓ | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.README](part-06-evaluations/README.md), [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md), [16.README](part-16-adjacent-capabilities/README.md) |
| `Transcript` | ✓ | ✓ | [6.README](part-06-evaluations/README.md), [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) |
| `Transcript.structuredTranscript` | ✓ | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md), [6.README](part-06-evaluations/README.md) |

## CoreAI  <sub>3 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `AIModel` |  | ✓ | [16.README](part-16-adjacent-capabilities/README.md), [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `InferenceFunction` |  | ✓ | [16.README](part-16-adjacent-capabilities/README.md), [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `NDArray` |  | ✓ | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |

## Evaluations  <sub>8 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `Evaluation` |  | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md), [6.README](part-06-evaluations/README.md), [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) |
| `Evaluation.run(info:)` |  | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md) |
| `EvaluationResult` |  | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md) |
| `EvaluationResult.saveJSON(to:)` |  | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.README](part-06-evaluations/README.md) |
| `Evaluations` |  | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.README](part-06-evaluations/README.md), [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md) |
| `Evaluations.framework` |  | ✓ | [6.README](part-06-evaluations/README.md), [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md), [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) |
| `Evaluations.StructuredTranscript` |  | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md) |
| `Evaluator` |  | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md), [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md), [6.README](part-06-evaluations/README.md) |

## Speech  <sub>9 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `AnalyzerInputConverter` |  | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `AnalyzerInputConverter.flush()` |  | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `AssetInventory` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `CaptureInputSequenceProvider` |  | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `DictationTranscriber` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `SFCustomLanguageModelData` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `SFSpeechLanguageModel.Configuration` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `SpeechAnalyzer` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `SpeechBundle` |  |  | [16.README](part-16-adjacent-capabilities/README.md) |

## AppIntents  <sub>13 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `AppEntity` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `AppIntent` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `EntityCollection` |  | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `ExecutionTargets` |  | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `IndexedEntity` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `IndexedEntityQuery` |  | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `LongRunningIntent` |  | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `RelevantEntities` |  | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `SnippetIntent` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `StringSearchCriteria` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `SyncableEntity` |  | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `@UnionValue` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `ValueRepresentation` |  | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |

## CoreSpotlight  <sub>3 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `CSSearchableIndex.indexAppEntities(_:)` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `CSSearchableItem` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `SpotlightSearchTool` |  | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |

## Swift/Foundation  <sub>5 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `Array` | ✓ | ✓ | [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) |
| `ArrayLoader` |  | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.README](part-06-evaluations/README.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md), [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) |
| `Codable` | ✓ | ✓ | [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md), [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md), [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md) |
| `JSONLoader` |  | ✓ | [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md), [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.README](part-06-evaluations/README.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md) |
| `String` | ✓ | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md), [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) |

## other  <sub>104 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `AggregationOperation` |  | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md) |
| `ArgumentMatcher` |  | ✓ | [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md), [6.README](part-06-evaluations/README.md), [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md) |
| `ArgumentValue` |  | ✓ | [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) |
| `AssertionError` |  |  | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `AsyncSequence` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `AsyncStream` |  |  | [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) |
| `Batch` |  |  | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `Batch.StdKeys.IDENTIFIER` |  |  | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `BookTaggingService` |  |  | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md), [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) |
| `BookTaggingService.generateTags(for:)` |  |  | [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md), [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) |
| `BookTags` |  |  | [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md), [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md) |
| `Cacher` |  |  | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `Collection` | ✓ | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md) |
| `CoreAISpeech` |  |  | [16.README](part-16-adjacent-capabilities/README.md) |
| `DataFrame` |  | ✓ | [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md), [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md), [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `DataLoader` |  |  | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `DataRepresentation` |  |  | [16.README](part-16-adjacent-capabilities/README.md) |
| `DatasetExtractor` |  |  | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md) |
| `DatasetReport` |  |  | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `DimensionReduction` |  |  | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `Double` | ✓ | ✓ | [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md), [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md) |
| `Duplicates` |  |  | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md), [16.README](part-16-adjacent-capabilities/README.md) |
| `Duplicates.introspect` |  |  | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `Energy` | ✓ | ✓ | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `EntityIdentifier` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `EvaluationContext.current.result` |  | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md) |
| `EvaluationError` |  | ✓ | [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md), [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md) |
| `EvaluationError.missingTranscript` |  | ✓ | [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) |
| `EvaluatorError` |  | ✓ | [6.README](part-06-evaluations/README.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md) |
| `EvaluatorProtocol` |  | ✓ | [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md) |
| `Evaluators` |  | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md) |
| `EvaluatorsBuilder` |  | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md) |
| `Familiarity` |  |  | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md), [16.README](part-16-adjacent-capabilities/README.md) |
| `FieldRenamer` |  |  | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `FileEntityIdentifier` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `FileEntityIdentifier.file(url:)` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `FileRepresentation` |  |  | [16.README](part-16-adjacent-capabilities/README.md) |
| `ForEach` |  | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `GenerationOptions` | ✓ | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md), [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) |
| `HillClimbingEvaluations` |  |  | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md) |
| `IDENTIFIER` |  |  | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `Input` | ✓ | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md) |
| `Input.ExpectedValue` |  | ✓ | [6.README](part-06-evaluations/README.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md), [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md) |
| `IntentParameter.valueState` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `IntentValueRepresentation` |  | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `IUA` |  |  | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `LABELS` |  |  | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `LLMSearchUsingCoreSpotlightApp` |  |  | [16.README](part-16-adjacent-capabilities/README.md) |
| `Loader` |  | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md) |
| `Makefile` |  |  | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `Metric` |  | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md), [6.README](part-06-evaluations/README.md), [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) |
| `MetricsAggregator` |  | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md), [6.README](part-06-evaluations/README.md), [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) |
| `Model` | ✓ | ✓ | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `ModelJudgeError` |  | ✓ | [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md), [6.README](part-06-evaluations/README.md) |
| `ModelJudgeEvaluator` |  | ✓ | [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md), [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.README](part-06-evaluations/README.md), [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) |
| `ModelJudgePrompt` |  | ✓ | [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md), [6.README](part-06-evaluations/README.md), [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md) |
| `ModelJudgePrompt.instructions` |  | ✓ | [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md) |
| `ModelJudgePrompt.reference` |  | ✓ | [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md), [6.README](part-06-evaluations/README.md), [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md) |
| `ModelSample` |  | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md), [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) |
| `ModelSampleInput` |  | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md) |
| `ModelSampleProtocol` |  | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md), [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) |
| `ModelSubject` |  | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md), [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) |
| `ModelSubject.transcript` |  | ✓ | [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md), [6.README](part-06-evaluations/README.md) |
| `None` |  |  | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `OSLog` |  | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md), [6.README](part-06-evaluations/README.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md) |
| `PCA` |  |  | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `PFA` |  |  | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `PFA.introspect` |  |  | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `PipelineStage` |  |  | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `Pooler` |  |  | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `Processor` |  |  | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `Producer` |  |  | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `ProducerTorchDataset` |  |  | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `Relevance` |  |  | [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md) |
| `Sample` |  | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md) |
| `SampleGenerator` |  | ✓ | [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md), [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md), [6.README](part-06-evaluations/README.md) |
| `SampleProtocol` |  | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md) |
| `SamplingStrategy` |  | ✓ | [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md), [6.README](part-06-evaluations/README.md) |
| `ScoreDimension` |  | ✓ | [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md), [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.README](part-06-evaluations/README.md) |
| `ScoreDimension.description` |  | ✓ | [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md) |
| `ScoreLevel` |  | ✓ | [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md) |
| `ScoringMode` |  | ✓ | [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md), [6.README](part-06-evaluations/README.md), [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md) |
| `ScoringScale` |  | ✓ | [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md), [6.README](part-06-evaluations/README.md), [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md) |
| `SearchReply` |  | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `Self.samples` | ✓ | ✓ | [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md) |
| `Sequence` | ✓ | ✓ | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `Statistics.cohensKappa` |  |  | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) |
| `StructuredValue` |  | ✓ | [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) |
| `Subject` | ✓ | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md) |
| `SubjectInferenceError` |  | ✓ | [6.README](part-06-evaluations/README.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md) |
| `TagCount` |  |  | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) |
| `TagQuality` |  |  | [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md) |
| `@Test` |  | ✓ | [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.README](part-06-evaluations/README.md) |
| `Testing` |  | ✓ | [6.README](part-06-evaluations/README.md), [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md) |
| `Testing.framework` |  | ✓ | [6.README](part-06-evaluations/README.md), [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md) |
| `ToolCallEvaluator` |  | ✓ | [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md), [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.README](part-06-evaluations/README.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md) |
| `ToolDefinition` | ✓ | ✓ | [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) |
| `ToolExpectation` |  | ✓ | [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md), [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md) |
| `TorchProducer` |  |  | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `TrajectoryExpectation` |  | ✓ | [6.3](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md), [6.README](part-06-evaluations/README.md), [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md), [6.2](part-06-evaluations/references/02-model-judges-and-alignment.md) |
| `Transferable` |  | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `UNKNOWN` |  |  | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `ValueError` |  |  | [16.5](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md) |
| `XCTest.framework` |  |  | [6.README](part-06-evaluations/README.md), [6.1](part-06-evaluations/references/01-foundations-and-hill-climbing.md) |
