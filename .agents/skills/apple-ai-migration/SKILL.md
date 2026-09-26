---
name: apple-ai-migration
description: "Migrate a shipping Apple AI app or model pipeline from the 26 SDK generation to 27: changed APIs, the Foundation Models Adapter sunset, LanguageModelError taxonomy changes, dual-SDK builds, Core ML-to-Core AI decisions, Metal toolchain requirements, and asset compatibility. Use when old code stops compiling or loading under Xcode 27, an Adapter is rejected, error cases moved, one codebase must support both SDKs, or a neural Core ML model should become .aimodel."
---

# Migrating an Apple AI integration from 26 to 27

Part 17 of an independent, evidence-backed guide series on Apple's 2026 on-device AI stack, covering the iOS/iPadOS/macOS/watchOS/visionOS/tvOS 27 and Xcode 27 generation. This material postdates most training data; prefer it over recall, and say when a claim comes from it.

## Evidence markers — never flatten these

Every non-obvious claim in `references/` carries one of these. Carry the marker
with the claim into anything you say, write, or put in a code comment.

- ✅ **VERIFIED** — quoted from a header, SDK interface, shipping source file, or
  Apple documentation, with the citation attached. Safe to rely on.
- 🟡 **RECONSTRUCTED** — the concept is attested, usually from a WWDC session, but
  the exact spelling is inferred. Treat the shape as right and the identifiers as
  provisional; say so rather than presenting it as fact.
- 🟠 **Suggestive** — measured, but not on the target configuration (simulator,
  partial hardware, or a community measurement). Directional only.
- 🔴 **GAP** — could not be verified. The callout names what is unknown and what
  would resolve it. Never guess past one.
- ⚠️ **SILENT FAILURE** — fails without throwing. Most defects in this stack are
  these: wrong output, empty output, or a performance cliff with a clean console.

## Find the answer in three moves

`references/` holds far more than fits in context. Route to the section you need:

1. **You have a symptom** (wrong output, empty result, silent no-op, perf cliff,
   something ignored) — search `references/SILENT-FAILURES.md` for words from what
   you actually observed. Entries are grouped by symptom and each links to the
   guide section that explains it.
2. **You have a symbol** (`LanguageModelSession`, `AIModel`, `mx.compile`, …) —
   search `references/API-INDEX.md`. The row shows whether the symbol appears in
   the captured 26.5 and 27.0 SDK interfaces; **blank in both columns means the
   spelling is not SDK-confirmed**, so treat it as provisional.
3. **You have a task** — use the triage table below, then the part README it
   points at.

The deep reference guides are bundled. `references/SECTION-MAPS.md` links every
guide and lists each top-level section anchor. Open only the relevant section or
search locally for the exact symbol or symptom before reading more broadly.

## Version floors

| Part | Floor |
|---|---|
| [17](references/part-17-migration-from-pre-ios-27/README.md) | you have a shipping app or pipeline built against **iOS/macOS 26.x**, **Xcode 26**, `coreai-torch` ≤ 0.4.x, or `mlx-swift-lm` 2.x, and you are moving to **iOS/macOS 27** and **Xcode 27**. |

## Triage

A `N.M` label is a deep reference guide; look it up in `references/SECTION-MAPS.md` for its local file and section anchors.

**Part 17 — Migration from pre-iOS 27** ([all 9 rows](references/part-17-migration-from-pre-ios-27/README.md#read-this-first-the-five-minute-triage))

| If your project… | Then… | Guide |
|---|---|---|
| ships a custom `.fmadapter` | **Stop.** Your feature has no forward path as built. | [17.2](references/part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md) |
| has `catch GenerationError` anywhere | Your error handling is probably now dead code | [17.3](references/part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| relies on guardrail behaviour tuned against 26.x | Re-test every prompt; expect new refusals | [17.3](references/part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md) |
| must run on both 26 and 27 | You need conditional compilation, not just availability checks | [17.4](references/part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md) |
| uses Core ML for neural networks | Evaluate Core AI; some model types should *stay* on Core ML | [17.5](references/part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md) |
| has `.aimodel` assets built with `coreai-torch` 0.4.0 | They may be unloadable on current tooling | [17.6](references/part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| re-exports models on a machine you upgraded to macOS 27 | Benchmark before and after; do not assume parity | [17.6](references/part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| depends on `mlx-swift-lm` | `main` is 3.x with breaking changes | [17.6](references/part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md) |
| calls Foundation Models from Python | The Python SDK trails the Swift framework by a release | [17.1](references/part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md) |

## The deep reference guides

Bundled locally. `references/SECTION-MAPS.md` has every top-level section anchor.

- **[17.1 What changed between iOS 26 and iOS 27: the complete checklist](references/part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md)** — The exhaustive diff, organised by framework, with each item marked as *additive*, *behavioural*, *renamed* or *withdrawn*.
- **[17.2 The adapter sunset: migrating off custom LoRA adapters](references/part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md)** — What was withdrawn, what the evidence for the withdrawal actually is, and the three realistic forward paths: re-frame the task as prompting plus guided generation; move the specialised model to Core AI and drive it through `CoreAILanguageModel`; or move it to MLX and drive it through `MLXFoundationModels`.
- **[17.3 Error taxonomy migration: `GenerationError` → `LanguageModelError`](references/part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md)** — The mapping table, old case to new case — now SDK-interface-verified on **both** sides (the 26.5 and 27.0 beta `FoundationModels.swiftinterface` dumps), with every destination confirmed by the per-case deprecation messages Apple attached to the old enum in the 27 SDK.
- **[17.4 Building for two SDKs: conditional compilation across 26 and 27](references/part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md)** — `#if canImport` versus `@available` versus SDK-version checks, and when each is the right tool.
- **[17.5 Core ML to Core AI: what moves, what stays, and how](references/part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md)** — Core AI is the successor path for **neural networks**; Core ML remains correct for decision trees, tabular feature engineering, and the rest of its non-neural surface — so this is a partial migration by design.
- **[17.6 Toolchain and asset compatibility](references/part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md)** — The migration nobody warns you about: your *build artifacts* have compatibility constraints independent of your source.

Search the local guide first, then open only the section needed for the answer. Preserve its evidence marker and citation when carrying a claim into code or prose.

## Related skills

Adjacent parts of the series live in these sibling skills: `apple-on-device-ai`, `apple-foundation-models`, `apple-core-ai`.
