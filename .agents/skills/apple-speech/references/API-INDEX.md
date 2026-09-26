# API & symbol index — SpeechAnalyzer: live and file-based transcription

**113 symbols, of 1212 across the series, that the guide parts in this skill cover — with whether each exists in the captured 26.5 / 27.0 beta SDK interfaces.**

> A `✓` means the leading type name appears in the corresponding captured `.swiftinterface`; dotted uppercase type paths must be one contiguous subpath of a qualified or declared type chain. A longer chain may prove any contiguous type subpath, but `::` module qualifiers never become nested types. Lowercase members are not signature-matched — the guides carry the signature-level citations. **Blank in both columns means the spelling is not SDK-confirmed**: package types and C/ObjC-only API legitimately show neither, but so does a reconstruction. A symbol absent from this page may still be covered elsewhere in the series — the full index is at https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/API-INDEX.md. Sliced on 2026-09-22; regenerate with `./scripts/build-skills.sh` rather than editing by hand.

## FoundationModels  <sub>7 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `CoreAILanguageModel` |  |  | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `CoreAILanguageModels` |  |  | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `@Generable` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `LanguageModelSession` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md), [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `Prompt` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `SystemLanguageModel.default.availability` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `Tool` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |

## CoreAI  <sub>2 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `AIModel` |  | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md), [16.README](part-16-adjacent-capabilities/README.md) |
| `InferenceFunction` |  | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md), [16.README](part-16-adjacent-capabilities/README.md) |

## Speech  <sub>24 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `AnalyzerInput` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `AnalyzerInputConverter` |  | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md), [16.README](part-16-adjacent-capabilities/README.md) |
| `AnalyzerInputConverter.flush()` |  | ✓ | [16.README](part-16-adjacent-capabilities/README.md), [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `AssetInputSequenceProvider` |  | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `AssetInventory` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md), [16.README](part-16-adjacent-capabilities/README.md) |
| `AssetInventory.Status` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `CaptureInputSequenceProvider` |  | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md), [16.README](part-16-adjacent-capabilities/README.md) |
| `DictationTranscriber` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md), [16.README](part-16-adjacent-capabilities/README.md) |
| `DictationTranscriber.Preset` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `DictationTranscriber.Result` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `SFCustomLanguageModelData` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md), [16.README](part-16-adjacent-capabilities/README.md) |
| `SFSpeechError.Code.insufficientResources` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `SFSpeechLanguageModel` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `SFSpeechLanguageModel.Configuration` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md), [16.README](part-16-adjacent-capabilities/README.md) |
| `SFSpeechRecognizer` |  |  | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `SpeechAnalyzer` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md), [16.README](part-16-adjacent-capabilities/README.md) |
| `SpeechAnalyzer.Options` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `SpeechBundle` |  |  | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md), [16.README](part-16-adjacent-capabilities/README.md) |
| `SpeechDetector` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `SpeechDetector.Result` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `SpeechModuleResult` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `SpeechTests` |  |  | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `SpeechTranscriber` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `SpeechTranscriber.Result` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |

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

## SwiftUI  <sub>1 symbol</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `ObservableObject` |  |  | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |

## Media/Core*  <sub>9 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `AVAsset` |  | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `AVAudioBuffer` |  | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `AVAudioConverter` |  | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `AVAudioFormat` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `AVAudioPCMBuffer` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `AVCaptureAudioDataOutput` |  | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `AVCaptureSession` |  | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `AVFoundation` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `CMTime` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |

## Swift/Foundation  <sub>7 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `Foundation` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `Result` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `Sendable` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `Task` |  |  | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `Task.checkCancellation()` |  |  | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `Task.isCancelled` |  |  | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `URL` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |

## other  <sub>47 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `AnalysisContext` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `AnalysisContext.contextualStrings` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `AsyncSequence` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md), [16.README](part-16-adjacent-capabilities/README.md) |
| `AttributedString` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `AttributedString.rangeOfAudioTimeRangeAttributes(intersecting:)` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `AttributeScopes.SpeechAttributes.ConfidenceAttribute` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `AttributeScopes.SpeechAttributes.TimeRangeAttribute` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `Beta` |  |  | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `Bool` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `BundleKind` |  |  | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `CancellationError` |  |  | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `CaseIterable` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `Comparable` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `Configuration` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `ContentHint` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `CoreAISpeech` |  |  | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md), [16.README](part-16-adjacent-capabilities/README.md) |
| `CustomPronunciation` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `DataInsertable` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `DataRepresentation` |  |  | [16.README](part-16-adjacent-capabilities/README.md) |
| `Double` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `Duplicates` |  |  | [16.README](part-16-adjacent-capabilities/README.md) |
| `EntityIdentifier` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `Familiarity` |  |  | [16.README](part-16-adjacent-capabilities/README.md) |
| `FileEntityIdentifier` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `FileEntityIdentifier.file(url:)` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `FileRepresentation` |  |  | [16.README](part-16-adjacent-capabilities/README.md) |
| `ForEach` |  | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `Int` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `IntentParameter.valueState` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `IntentValueRepresentation` |  | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `LLMSearchUsingCoreSpotlightApp` |  |  | [16.README](part-16-adjacent-capabilities/README.md) |
| `Locale` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `Locale.current` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `ModelBundle` |  |  | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `NSObject` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `PhraseCount` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `PhraseCountsFromTemplates` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `PreparedModel` |  |  | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `Progress` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `ProgressReporting` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `SearchReply` |  | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `SensitivityLevel` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `Set` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `SwiftTranscriptionSampleApp` |  |  | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `TaskPriority` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `Template` | ✓ | ✓ | [16.1](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md) |
| `Transferable` |  | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
