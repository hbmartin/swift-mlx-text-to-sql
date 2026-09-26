# API & symbol index — Migrating an Apple AI integration from 26 to 27

**407 symbols, of 1212 across the series, that the guide parts in this skill cover — with whether each exists in the captured 26.5 / 27.0 beta SDK interfaces.**

> A `✓` means the leading type name appears in the corresponding captured `.swiftinterface`; dotted uppercase type paths must be one contiguous subpath of a qualified or declared type chain. A longer chain may prove any contiguous type subpath, but `::` module qualifiers never become nested types. Lowercase members are not signature-matched — the guides carry the signature-level citations. **Blank in both columns means the spelling is not SDK-confirmed**: package types and C/ObjC-only API legitimately show neither, but so does a reconstruction. A symbol absent from this page may still be covered elsewhere in the series — the full index is at https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/API-INDEX.md. Sliced on 2026-09-22; regenerate with `./scripts/build-skills.sh` rather than editing by hand.

## FoundationModels  <sub>110 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `Adapter` | ✓ | ✓ | [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `Adapter.AssetError` | ✓ | ✓ | [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) |
| `ChatCompletionsLanguageModel` |  |  | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `ChatCompletionsLanguageModel.init` |  |  | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `CoreAILanguageModel` |  |  | [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md), [17.README](part-17-migration-from-pre-ios-27/README.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) +1 more |
| `CoreAILanguageModels` |  |  | [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md), [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `DynamicProfile` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `DynamicProfile.toolCallingMode(_:)` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `DynamicProfileModifier` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `DynamicProfiles` |  |  | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `FoundationModels` | ✓ | ✓ | [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md), [17.README](part-17-migration-from-pre-ios-27/README.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `FoundationModels.framework` | ✓ | ✓ | [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `FoundationModels.LanguageModelError` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `FoundationModels.swiftinterface` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md), [17.README](part-17-migration-from-pre-ios-27/README.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `@Generable` | ✓ | ✓ | [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) +1 more |
| `Generable` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md), [17.README](part-17-migration-from-pre-ios-27/README.md) |
| `GeneratedContent` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `GeneratedContent.ParsingError` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `GenerationError` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.README](part-17-migration-from-pre-ios-27/README.md) +2 more |
| `GenerationError.concurrentRequests(_:)` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `GenerationError.Context` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) |
| `GenerationError.decodingFailure` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `GenerationError.decodingFailure(_:)` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `GenerationError.exceededContextWindowSize` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `GenerationError.guardrailViolation` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.README](part-17-migration-from-pre-ios-27/README.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `GenerationError.guardrailViolation(_:)` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `GenerationError.Refusal` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `GenerationError.refusal(_:_:)` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `@Guide` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `Instructions` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `LanguageModel` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) +2 more |
| `LanguageModelCapabilities` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `LanguageModelCapabilities.init(_:)` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `LanguageModelError` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md), [17.README](part-17-migration-from-pre-ios-27/README.md) +2 more |
| `LanguageModelError.contextSizeExceeded` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `LanguageModelError.ContextSizeExceeded` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `LanguageModelError.contextSizeExceeded(_:)` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `LanguageModelError.guardrailViolation` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `LanguageModelError.guardrailViolation(_:)` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `LanguageModelError.rateLimited` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `LanguageModelError.rateLimited(_:)` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `LanguageModelError.refusal` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `LanguageModelError.refusal(_:)` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `LanguageModelError.Refusal.explanation` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `LanguageModelError.unsupportedCapability(_:)` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `LanguageModelError.unsupportedGenerationGuide` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `LanguageModelError.unsupportedGenerationGuide(_:)` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `LanguageModelError.unsupportedLanguageOrLocale(_:)` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `LanguageModelError.unsupportedTranscriptContent` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `LanguageModelExecutor` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `LanguageModelExecutorGenerationChannel` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `LanguageModelExecutorGenerationRequest` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `LanguageModelFeedback` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `LanguageModelFeedback.Issue.Category` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `LanguageModelSession` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) +1 more |
| `LanguageModelSession.DynamicProfile` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `LanguageModelSession.DynamicProfileBuilder` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `LanguageModelSession.DynamicProfileModifier` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `LanguageModelSession.Error` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `LanguageModelSession.Error.concurrentRequests` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `LanguageModelSession.Error.transcriptMutationWhileResponding` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `LanguageModelSession.GenerationError` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) |
| `LanguageModelSession.GenerationError.exceededContextWindowSize(_:)` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `LanguageModelSession.Profile` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `LanguageModelSession.Response.content` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `LanguageModelSession.SessionProperty` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `LanguageModelSession.ToolCallError` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `LanguageModelSession.Usage` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `MLXLanguageModel` |  |  | [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `MLXLanguageModel.Executor` |  |  | [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `PrivateCloudComputeLanguageModel` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `PrivateCloudComputeLanguageModel.Error` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `Profile` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `Prompt` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `Refusal` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `@SessionProperty` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `SessionPropertyKey` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `SessionPropertyValues` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `SessionPropertyValues.history` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `SystemLanguageModel` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `SystemLanguageModel.Adapter` | ✓ | ✓ | [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.README](part-17-migration-from-pre-ios-27/README.md) |
| `SystemLanguageModel.Adapter(name:)` | ✓ | ✓ | [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) |
| `SystemLanguageModel.Adapter.compatibleAdapterIdentifiers(name:)` | ✓ | ✓ | [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) |
| `SystemLanguageModel.Availability` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `SystemLanguageModel.availability` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `SystemLanguageModel.contextSize` | ✓ | ✓ | [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `SystemLanguageModel.default` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `SystemLanguageModel.default.availability` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md), [17.README](part-17-migration-from-pre-ios-27/README.md) |
| `SystemLanguageModel.default.contextSize` | ✓ | ✓ | [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `SystemLanguageModel.default.supportsLocale(_:)` | ✓ | ✓ | [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `SystemLanguageModel.Error` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `SystemLanguageModel.Error.assetsUnavailable` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `SystemLanguageModel.Error.assetsUnavailable(_:)` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `SystemLanguageModel.Guardrails` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `SystemLanguageModel.init(adapter:guardrails:)` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) |
| `SystemLanguageModel.supportsLocale(_:)` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `SystemLanguageModel.tokenCount(for:)` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `Tool` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `Tool.call(arguments:)` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `Tool.Output` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `Tool.parameters` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `Transcript` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `Transcript.CustomSegment` |  |  | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `Transcript.Entry` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) |
| `Transcript.Entry.reasoning` | ✓ | ✓ | [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `Transcript.history` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `Transcript.HistoryView` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `Transcript.Segment` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `Transcript.structuredTranscript` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `TranscriptErrorHandlingPolicy` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |

## CoreAI  <sub>51 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `AIModel` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md), [17.README](part-17-migration-from-pre-ios-27/README.md) +1 more |
| `AIModel.bookmarkData` |  | ✓ | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `AIModel.deviceArchitectureName` |  | ✓ | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `AIModel.load` |  | ✓ | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `AIModel.loadFunction(named:)` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `AIModel.specialize` |  | ✓ | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `AIModelAsset` |  | ✓ | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md), [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `AIModelAsset.load` |  | ✓ | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `AIModelAsset.load(path)` |  | ✓ | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `AIModelAsset.Metadata` |  | ✓ | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `AIModelAssetMetadata` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `AIModelCache` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `AIModelCache.default` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `AIModelCache.default.model(for:options:)` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `AIModelCache.model(for:options:)` |  | ✓ | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md), [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `AIModelCache.Policy` |  | ✓ | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md), [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `AIModelError` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `AssetError` | ✓ | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) |
| `CoreAI` |  | ✓ | [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md), [17.README](part-17-migration-from-pre-ios-27/README.md) +1 more |
| `CoreAI.framework` |  | ✓ | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md), [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `CoreAIAsset` |  | ✓ | [17.README](part-17-migration-from-pre-ios-27/README.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md), [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `CoreAIAsset.AssetError` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `CoreAICache` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `CoreAICommon` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `CoreAICompiler` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `CoreAIDelegates` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md), [17.README](part-17-migration-from-pre-ios-27/README.md) |
| `CoreAIDelegates.AIModelError` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `CoreAIRuntime` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md), [17.README](part-17-migration-from-pre-ios-27/README.md) |
| `ImageDescriptor` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `InferenceFunction` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `InferenceFunction.AsyncValue` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `InferenceFunction.Inputs` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `InferenceFunction.MutableViews` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `InferenceFunction.Outputs` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `InferenceFunction.run` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `InferenceFunctionDescriptor.stateNames` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `InferenceValue` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `InferenceValue.Descriptor` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `InferenceValue.Kind` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `InferenceValue.NamedMutableViews.take(_:)` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `InferenceValue.ndArray` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `NDArray` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md), [17.README](part-17-migration-from-pre-ios-27/README.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `NDArray.InterleaveLayout` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `NDArray.MutableView` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `NDArray.ScalarType` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `NDArray.ScalarType.type` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `NDArrayDescriptor.minimumByteCount` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `NDArrayDescriptor.preferredStrides` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `SpecializationOptions` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md), [17.README](part-17-migration-from-pre-ios-27/README.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) +1 more |
| `SpecializationOptions.cpuOnly` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `SpecializationOptions.default` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |

## Evaluations  <sub>4 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `Evaluation` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) |
| `Evaluations` |  | ✓ | [17.README](part-17-migration-from-pre-ios-27/README.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `Evaluations.StructuredTranscript` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `Evaluator` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |

## MLX  <sub>12 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `MLXDownloadProgress` |  |  | [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `MLXEmbedders` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `MLXEmbedders.loadModelContainer(hub:configuration:)` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `MLXEmbedders.ModelConfiguration.nomic_text_v1_5` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `MLXEmbeddersHuggingFace` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `MLXFoundationModels` |  |  | [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.README](part-17-migration-from-pre-ios-27/README.md) +1 more |
| `MLXGuidedGeneration` |  |  | [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `MLXHuggingFace` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `MLXLLM` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `MLXLMCommon` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `MLXLMHuggingFace` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `MLXVLM` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |

## AppIntents  <sub>2 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `AppIntents` | ✓ | ✓ | [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `IndexedEntity` | ✓ | ✓ | [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) |

## CoreSpotlight  <sub>1 symbol</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `SpotlightSearchTool` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |

## Vision  <sub>2 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `BarcodeReaderTool` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `OCRTool` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |

## Metal/MPP  <sub>6 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `MetalPerformancePrimitives` |  |  | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `MPSGraphAICodeCompilerDelegate` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `MTLTensor` |  |  | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `MTLTensorAuxiliaryPlaneDescriptor` |  |  | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `MTLTensorDataType` |  |  | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `MTLTensorDescriptor.auxiliaryPlanes` |  |  | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |

## SwiftUI  <sub>2 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `SwiftUI` |  |  | [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `View` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |

## Media/Core*  <sub>7 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `AVFoundation` | ✓ | ✓ | [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `CGImage` | ✓ | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `CGImageSourceCreateImageAtIndex` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `CIImage` | ✓ | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `CVMutablePixelBuffer` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `CVPixelBuffer` | ✓ | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `CVReadOnlyPixelBuffer` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |

## Swift/Foundation  <sub>17 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `ArraySlice` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `Data` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `Duration` | ✓ | ✓ | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `Duration.inSeconds` | ✓ | ✓ | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `Foundation` | ✓ | ✓ | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `FoundationContext` |  |  | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `FoundationModelsCoffeeGame` |  |  | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `FoundationModelsIntegration` |  |  | [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `FoundationNetworking` |  |  | [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `JSONDecoder` |  |  | [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) |
| `Sendable` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `SendableMetatype` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `String` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `Task` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `Task.isCancelled` |  |  | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `URL` | ✓ | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `URLSession` |  |  | [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) |

## other  <sub>193 symbols</sub>

| Symbol | 26.5 | 27.0 | Covered in |
|---|:-:|:-:|---|
| `AIProgram` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `AIProgram.optimize()` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `AIProgram.save_asset(path)` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `ANECompiler` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `Any` | ✓ | ✓ | [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `AnyLanguageModel` |  |  | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `APIError` |  |  | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `Arguments` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `AsyncSequence` | ✓ | ✓ | [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `Attachment` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `AttributeError` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `AutoTokenizer.from(directory:)` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `AutoTokenizer.register(_:for:)` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `BackgroundAssets` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `Barcode` |  |  | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `BenchmarkHelpers` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `BitwiseCopyable` | ✓ | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `Bool` | ✓ | ✓ | [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `BundleKind` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `Capability` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `CaseIterable` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `CLILogger.setLevel(to:)` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `ComputeUnitKind` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `Configuration` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `Context` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) |
| `ContextOptions` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `ContextSizeExceeded` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `Copyable` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `CoreAIDiffusion` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `CoreAILM` |  |  | [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) |
| `CoreAIObjectDetection` |  |  | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `CoreAIPipelinedEngine` |  |  | [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) |
| `CoreAIRunner.init(from bundle:)` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `CoreAISegmentation` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `CoreAISegmentationEngine` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) |
| `CoreAISpeech` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `CoreImage` | ✓ | ✓ | [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md), [17.README](part-17-migration-from-pre-ios-27/README.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `CoreML` | ✓ | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `CoreMLExportError` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `CreatorDefinedValue` |  | ✓ | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `CustomDebugStringConvertible` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `CustomSegment` |  |  | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `DatasetExtractor` |  |  | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `DEBUG` |  |  | [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `DetectedObject.boundingBox` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `DoRAEmbedding.from_base` |  |  | [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) |
| `Double` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `Downloader` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `DynamicGenerationSchema` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `DynamicInstructions` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `DynamicInstructionsForEach` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `EmbedderModelFactory.shared.loadContainer(from:using:configuration:)` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `EmbedderRegistry.nomic_text_v1_5` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `Encodable` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `Equatable` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `Error` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `Escapable` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `EvaluationContext.current.result` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `Evaluators` |  | ✓ | [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) |
| `EvaluatorsBuilder` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `ExportBackend.CoreAI` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `ExportBackend.CoreML` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `ExportedProgram` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `Float16` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `Float32` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `FMSystemLanguageModelGetContextSize` |  |  | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `GenerationOptions` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `GenerationOptions.SamplingMode.Kind` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `GenerationOptions.ToolCallingMode` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `GenerationSchema` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) |
| `Guardrails` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `Guardrails.default` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `GuardrailViolation` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `Hashable` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `HistoryView` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `HubApi` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `HubClient` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `HubClient.default` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `HuggingFace` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `ImagePreprocessor` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `ImagePromptError` |  |  | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `ImageReference` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `ImageReference.attachmentLabel` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `ImageReference.resolve(in:)` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `Index` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `Info.plist` |  |  | [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) |
| `Int` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `IntegrationTestHelpers` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `Issue.Category` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `Kind` | ✓ | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `KMeansPalettizer` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `Linear` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `LocalizedError` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `LoRAConfiguration` |  |  | [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) |
| `LoRAContainer` |  |  | [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) |
| `MacOSX26.5.sdk` |  |  | [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `MagnitudePruner` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `Metadata` |  | ✓ | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `Metric` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `MLFeatureProvider` | ✓ | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `MLModel` | ✓ | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md), [17.README](part-17-migration-from-pre-ios-27/README.md) |
| `MLMultiArray` | ✓ | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md), [17.README](part-17-migration-from-pre-ios-27/README.md) |
| `Mode.DEBUG` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `Mode.RELEASE` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `ModelBundle` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `ModelBundle.verify()` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `ModelConfiguration` |  |  | [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) |
| `ModelConfiguration.modelDirectory(hub:)` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `ModelConfiguration.preparePrompt` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `ModelConfiguration.tokenizerId` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `ModelDelivery` |  |  | [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) |
| `ModelFactory._loadContainer` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `ModelJudgeEvaluator` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `ModelManagerServices.ModelManagerError` |  |  | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `MutableCollection` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `MutableRawSpan` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `MutableView` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `MutableView.copyElements(from:)` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `MutableViews` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `MyModel.aimodel` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `None` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `NSError` |  |  | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `NSImage` |  |  | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `NSMultipleUnderlyingErrorsKey` |  |  | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `@Observable` | ✓ | ✓ | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `Optional` | ✓ | ✓ | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `Output` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `Outputs` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `Outputs.remove` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `Outputs.remove(_:)` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `Package.resolved` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `ParsingError` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `PartiallyGenerated` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `PerformanceMetrics.setPromptTokenCount(_:)` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `Policy` |  | ✓ | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `Policy.PurgeConditions` |  | ✓ | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `PreparedModel.resolveCoreAIModelURL` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `Progress` | ✓ | ✓ | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `PromptRepresentable` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) |
| `PurgeConditions` |  | ✓ | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `Quantizer` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `RandomAccessCollection` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `RangeReplaceableCollection` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md), [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `RateLimited` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `RawSpan` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `RawView.init` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `RELEASE` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `RequestError` |  |  | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `RequestError.invalidStreamData` |  |  | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `Response` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `Response.usage` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `ResponseStream` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `ResponseStream.Snapshot` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `RuntimeError` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `SamplingMode` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `SamplingMode.top` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `ScalarType.type` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `Segment.box` | ✓ | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `SegmentationVisualization.renderPromptBoxes` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `SensitiveContentAnalysisML` |  |  | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `Sequence` | ✓ | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `Set` | ✓ | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `Setup` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `Skill` |  |  | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `SkillActivation` |  |  | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `SkillActivations` |  |  | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `Skills` |  |  | [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `Span` |  | ✓ | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `Statistics.cohensKappa` |  |  | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `StoreDownloaderExtension` |  |  | [17.2](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) |
| `SubjectInferenceError` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `SubSequence` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md), [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `SwiftTranscriptionSampleApp` |  |  | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `Timeout` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `ToggleSkillTool` |  |  | [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| `TokenGenerationCore.GuidedGenerationError.invalidConfiguration` |  |  | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `TokenizerLoader` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `TokenizerReplacementRegistry` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `Tokenizers` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `ToolCallError` | ✓ | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `ToolCallEvaluator` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `ToolCallingMode` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `TorchConverter` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md), [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `TorchConverter.Mode` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `UIImage` |  |  | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `UNKNOWN` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `UnsafeRawPointer` | ✓ | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `UnsupportedLanguageOrLocale.languageCode` |  | ✓ | [17.3](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| `Usage` |  | ✓ | [17.1](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |
| `UserDefaults` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `UserWarning` |  |  | [17.6](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| `ValueError` |  |  | [17.5](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| `Vision` | ✓ | ✓ | [17.4](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
