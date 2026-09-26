# API & symbol index — App Intents, Siri schema domains, and Spotlight entity indexing

**165 symbols, of 1212 across the series, that the guide parts in this skill cover — with whether each exists in the captured 26.5 / 27.0 beta SDK interfaces.**

> A `✓` means the leading type name appears in the corresponding captured `.swiftinterface`; dotted uppercase type paths must be one contiguous subpath of a qualified or declared type chain. A longer chain may prove any contiguous type subpath, but `::` module qualifiers never become nested types. Lowercase members are not signature-matched — the guides carry the signature-level citations. **Blank in both columns means the spelling is not SDK-confirmed**: package types and C/ObjC-only API legitimately show neither, but so does a reconstruction. A symbol absent from this page may still be covered elsewhere in the series — the full index is at https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/API-INDEX.md. Sliced on 2026-09-22; regenerate with `./scripts/build-skills.sh` rather than editing by hand.

## FoundationModels  <sub>8 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `FoundationModels` | ✓ | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `@Generable` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `Guide` | ✓ | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `LanguageModelSession` | ✓ | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md), [16.README](part-16-adjacent-capabilities/README.md), [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `LanguageModelSession.ToolCallError` | ✓ | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `SystemLanguageModel` | ✓ | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `SystemLanguageModel.default.availability` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md), [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md), [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `Tool` | ✓ | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md), [16.README](part-16-adjacent-capabilities/README.md) |

## CoreAI  <sub>2 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `AIModel` |  | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `InferenceFunction` |  | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |

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

## AppIntents  <sub>32 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `AppEntity` | ✓ | ✓ | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md), [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md), [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.README](part-16-adjacent-capabilities/README.md) |
| `@AppEntity` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `AppEntityAnnotatable` | ✓ | ✓ | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `AppEntityContext` |  | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md), [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `AppEntityUIElement` |  | ✓ | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `@AppEnum` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `AppIntent` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.README](part-16-adjacent-capabilities/README.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md), [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `@AppIntent` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `AppIntentError.init(description:)` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `AppIntents` | ✓ | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `AppIntentsTesting` |  |  | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md), [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `AppShortcutsProvider` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `AssistantSchemas` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `DisplayRepresentation` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `DisplayRepresentation.Components` |  |  | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `DisplayRepresentation.Image` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `EntityCollection` |  | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.README](part-16-adjacent-capabilities/README.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `EntityQuery` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md), [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `EntityQuery.entities(for:)` | ✓ | ✓ | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md), [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `ExecutionTargets` |  | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.README](part-16-adjacent-capabilities/README.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `IndexedEntity` | ✓ | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md), [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.README](part-16-adjacent-capabilities/README.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `IndexedEntityQuery` |  | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md), [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.README](part-16-adjacent-capabilities/README.md) |
| `LongRunningIntent` |  | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.README](part-16-adjacent-capabilities/README.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `OwnershipProvidingEntity` |  | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `RelevantEntities` |  | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md), [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.README](part-16-adjacent-capabilities/README.md) |
| `RelevantEntities.shared` |  | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `SnippetIntent` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.README](part-16-adjacent-capabilities/README.md), [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `StringSearchCriteria` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md), [16.README](part-16-adjacent-capabilities/README.md) |
| `SyncableEntity` |  | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.README](part-16-adjacent-capabilities/README.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `@UnionValue` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.README](part-16-adjacent-capabilities/README.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `UnionValue` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `ValueRepresentation` |  | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md), [16.README](part-16-adjacent-capabilities/README.md) |

## CoreSpotlight  <sub>8 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `CSSearchableIndex` | ✓ | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `CSSearchableIndex.indexAppEntities(_:)` | ✓ | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md), [16.README](part-16-adjacent-capabilities/README.md), [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `CSSearchableIndex.indexAppEntities(_:priority:)` | ✓ | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `CSSearchableIndexDelegate` |  | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `CSSearchableItem` | ✓ | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md), [16.README](part-16-adjacent-capabilities/README.md) |
| `CSSearchableItemAttributeSet` | ✓ | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `SpotlightSearchTool` |  | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md), [16.README](part-16-adjacent-capabilities/README.md), [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `SpotlightSearchTool.Configuration` |  | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |

## Vision  <sub>2 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `BarcodeReaderTool` |  | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md), [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `OCRTool` |  | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md), [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |

## SwiftUI  <sub>2 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `List` | ✓ | ✓ | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `SwiftUI` |  |  | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |

## Media/Core*  <sub>1 symbol</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `CGRect` | ✓ | ✓ | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |

## Swift/Foundation  <sub>10 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `Codable` | ✓ | ✓ | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `Data` | ✓ | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `Duration` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `Foundation.Progress` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `Sendable` | ✓ | ✓ | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md), [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `@Sendable` | ✓ | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `String` | ✓ | ✓ | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md), [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `Task` |  |  | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `URLError` |  |  | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `UUID` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |

## other  <sub>91 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `AlbumView` |  |  | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `AppDependencyManager.shared.add(dependency:)` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `AppSchema` |  | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `AppSchema.JournalIntent` |  | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `AppSchema.MailIntent` |  | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `AppUnionValue` |  | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `AsyncSequence` | ✓ | ✓ | [16.README](part-16-adjacent-capabilities/README.md) |
| `AttendeeEntity` |  | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `AudioContext` |  | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `AudioEntity` |  | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `AudioSearch` |  |  | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `Bool` | ✓ | ✓ | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `CalendarManager` |  |  | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `CancellableIntent` |  | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `Cases` |  | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `Collection` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `CoreAISpeech` |  |  | [16.README](part-16-adjacent-capabilities/README.md) |
| `CoreSpotlight` | ✓ | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `CoreSpotlightSource` |  | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `CSCustomAttributeKey` | ✓ | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `CSSearchQuery` | ✓ | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `CustomAppIntentErrorConvertible` |  | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `CustomLocalizedStringResourceConvertible` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `DataRepresentation` |  |  | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md), [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.README](part-16-adjacent-capabilities/README.md) |
| `DecodingError` |  |  | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `@Dependency` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `Duplicates` |  |  | [16.README](part-16-adjacent-capabilities/README.md) |
| `EmptySnippetIntent` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `EntityIdentifier` | ✓ | ✓ | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md), [16.README](part-16-adjacent-capabilities/README.md), [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `EntityOwnership` |  | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `EntityStringQuery` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `EnumerableEntityQuery` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `Equatable` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `Error` | ✓ | ✓ | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md), [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `EventEntity` |  | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `EventEntityStatus` |  | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `Familiarity` |  |  | [16.README](part-16-adjacent-capabilities/README.md) |
| `FileEntityIdentifier` | ✓ | ✓ | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md), [16.README](part-16-adjacent-capabilities/README.md), [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `FileEntityIdentifier.draft(identifier:)` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `FileEntityIdentifier.file(url:)` | ✓ | ✓ | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md), [16.README](part-16-adjacent-capabilities/README.md) |
| `FileRepresentation` |  |  | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md), [16.README](part-16-adjacent-capabilities/README.md), [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `ForEach` |  | ✓ | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md), [16.README](part-16-adjacent-capabilities/README.md), [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `FormatLevel` |  | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `GuidanceLevel` |  | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `GuidanceProfile` |  | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `Hashable` | ✓ | ✓ | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md), [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `ID` | ✓ | ✓ | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `Int` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `IntentCancellationReason` |  | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `IntentExecutionTargets` |  | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `IntentModes` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `IntentParameter` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `IntentParameter.valueState` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.README](part-16-adjacent-capabilities/README.md) |
| `IntentPerson` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md), [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `IntentResult` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `IntentValueQuery` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `IntentValueRepresentation` |  | ✓ | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md), [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.README](part-16-adjacent-capabilities/README.md) |
| `LLMSearchUsingCoreSpotlightApp` |  |  | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md), [16.README](part-16-adjacent-capabilities/README.md) |
| `@MainActor` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `NowPlaying` |  |  | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `NowPlayingView` |  |  | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `NSError` |  |  | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `NSObject` | ✓ | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `NSUserActivity` | ✓ | ✓ | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `NSUserActivity.appEntityIdentifier` | ✓ | ✓ | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `OptionSet` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `OSSignposter` |  |  | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `@Parameter` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `PersonNameComponents` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `PianoRollView` |  |  | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `PlaceDescriptor` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `PlaylistDetailView` |  |  | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `ProgressReportingIntent` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `@Property` | ✓ | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md), [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `RawRepresentable` | ✓ | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `SearchableItem` |  | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `SearchableItemAttribute` |  | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `SearchReply` |  | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md), [16.README](part-16-adjacent-capabilities/README.md) |
| `ShowInAppSearchResultsIntent` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `ShowsSnippetView` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `SystemSearchInAppIntent` |  | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `Transferable` |  | ✓ | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md), [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.README](part-16-adjacent-capabilities/README.md) |
| `TransientAppEntity` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md), [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
| `UIKit` |  |  | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `UndoableIntent` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `UniqueAppEntityQuery` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `UNMutableNotificationContent.appEntityIdentifiers` |  |  | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md), [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `UserActionRequired` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `UTType` | ✓ | ✓ | [16.3](part-16-adjacent-capabilities/references/03-onscreen-awareness.md) |
| `Value` | ✓ | ✓ | [16.2](part-16-adjacent-capabilities/references/02-app-schema-domains.md) |
| `Void` | ✓ | ✓ | [16.4](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) |
