# Section maps for the deep reference guides

The deep guides are bundled with this skill. Each entry links the local file, then lists every **top-level** (`##`) section as an anchor; a guide's own `## Contents` lists its subsections. Open the narrowest relevant section first.

> Generated 2026-09-22 from the guide headings. Regenerate with `./scripts/build-skills.sh` rather than editing by hand.

## Part 17 — Migration from pre-iOS 27

### 17.1 — What changed between iOS 26 and iOS 27: the complete checklist

The exhaustive diff, organised by framework, with each item marked as *additive*, *behavioural*, *renamed* or *withdrawn*.

**Local reference:** [part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. The four version floors — the table | `#1-the-four-version-floors--the-table` |
| 2. The TensorOps ladder is a different ladder | `#2-the-tensorops-ladder-is-a-different-ladder` |
| 3. The three on-device model versions | `#3-the-three-on-device-model-versions` |
| 4. ADDITIVE — Foundation Models | `#4-additive--foundation-models` |
| 5. ADDITIVE — beyond Foundation Models | `#5-additive--beyond-foundation-models` |
| 6. BEHAVIOURAL — the category where your diff is empty | `#6-behavioural--the-category-where-your-diff-is-empty` |
| 7. RENAMED and SUPERSEDED | `#7-renamed-and-superseded` |
| 8. WITHDRAWN | `#8-withdrawn` |
| 9. The Python SDK generation lag | `#9-the-python-sdk-generation-lag` |
| 10. Toolchain breakages | `#10-toolchain-breakages` |
| 11. Every silent failure in this migration, collected | `#11-every-silent-failure-in-this-migration-collected` |
| 12. The migration checklist | `#12-the-migration-checklist` |
| 13. Quick reference: the one-page diff | `#13-quick-reference-the-one-page-diff` |
| 14. Sources and evidence ledger | `#14-sources-and-evidence-ledger` |

### 17.2 — The adapter sunset: migrating off custom LoRA adapters

What was withdrawn, what the evidence for the withdrawal actually is, and the three realistic forward paths: re-frame the task as prompting plus guided generation; move the specialised model to Core AI and drive it through `CoreAILanguageModel`; or move it to MLX and drive it through `MLXFoundationModels`.

**Local reference:** [part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. The news, and exactly what the evidence is | `#1-the-news-and-exactly-what-the-evidence-is` |
| 2. What "no longer supported" concretely means | `#2-what-no-longer-supported-concretely-means` |
| 3. The historical record: the 26.x adapter pipeline | `#3-the-historical-record-the-26x-adapter-pipeline` |
| 4. `compatibleAdapterNotFound`, and the leak underneath it | `#4-compatibleadapternotfound-and-the-leak-underneath-it` |
| 5. First, ask why you had an adapter — the decision table | `#5-first-ask-why-you-had-an-adapter--the-decision-table` |
| 6. Path 1 — prompting plus guided generation | `#6-path-1--prompting-plus-guided-generation` |
| 7. Path 2 — Core AI and `CoreAILanguageModel` | `#7-path-2--core-ai-and-coreailanguagemodel` |
| 8. Path 3 — MLX and `MLXFoundationModels` | `#8-path-3--mlx-and-mlxfoundationmodels` |
| 9. 🔴 The gap: Apple named the path and documented it nowhere | `#9--the-gap-apple-named-the-path-and-documented-it-nowhere` |
| 10. If you have an adapter shipping to users today | `#10-if-you-have-an-adapter-shipping-to-users-today` |
| 11. What not to do: the fabricated APIs circulating about this exact topic | `#11-what-not-to-do-the-fabricated-apis-circulating-about-this-exact-topic` |
| 12. Quick reference | `#12-quick-reference` |
| 13. Sources and evidence ledger | `#13-sources-and-evidence-ledger` |
| Where to go next | `#where-to-go-next` |

### 17.3 — Error taxonomy migration: `GenerationError` → `LanguageModelError`

The mapping table, old case to new case — now SDK-interface-verified on **both** sides (the 26.5 and 27.0 beta `FoundationModels.swiftinterface` dumps), with every destination confirmed by the per-case deprecation messages Apple attached to the old enum in the 27 SDK.

**Local reference:** [part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. The one sentence that decides everything | `#1-the-one-sentence-that-decides-everything` |
| 2. The 2026 error map: seven types, and which one is which | `#2-the-2026-error-map-seven-types-and-which-one-is-which` |
| 3. `LanguageModelError`: nine cases, three sources, one non-frozen enum | `#3-languagemodelerror-nine-cases-three-sources-one-non-frozen-enum` |
| 4. The mapping table: every old case, every new home | `#4-the-mapping-table-every-old-case-every-new-home` |
| 5. Coexistence: TN3193 and the samples disagree, and both are right | `#5-coexistence-tn3193-and-the-samples-disagree-and-both-are-right` |
| 6. Ordering, and what ordering actually buys you | `#6-ordering-and-what-ordering-actually-buys-you` |
| 7. `GeneratedContent.ParsingError` is not a `LanguageModelError` | `#7-generatedcontentparsingerror-is-not-a-languagemodelerror` |
| 8. Provider packages throw their own types | `#8-provider-packages-throw-their-own-types` |
| 9. The two refusal mechanisms — and the health-app regression | `#9-the-two-refusal-mechanisms--and-the-health-app-regression` |
| 10. Guardrail configuration, and the no-op nobody sees | `#10-guardrail-configuration-and-the-no-op-nobody-sees` |
| 11. Reading a refusal: `explanation` and `explanationStream` | `#11-reading-a-refusal-explanation-and-explanationstream` |
| 12. `contextSizeExceeded`: the retry pattern, before and after | `#12-contextsizeexceeded-the-retry-pattern-before-and-after` |
| 13. Errors in the wild that are none of the above | `#13-errors-in-the-wild-that-are-none-of-the-above` |
| 14. The complete catch ladder | `#14-the-complete-catch-ladder` |
| 15. Auditing your codebase: what to grep for | `#15-auditing-your-codebase-what-to-grep-for` |
| 16. A refusal-regression suite with the Evaluations framework | `#16-a-refusal-regression-suite-with-the-evaluations-framework` |
| 17. Quick reference | `#17-quick-reference` |
| 18. Sources and evidence ledger | `#18-sources-and-evidence-ledger` |

### 17.4 — Building for two SDKs: conditional compilation across 26 and 27

`#if canImport` versus `@available` versus SDK-version checks, and when each is the right tool.

**Local reference:** [part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| How evidence is marked in this guide | `#how-evidence-is-marked-in-this-guide` |
| Contents | `#contents` |
| 1. The three tools, and how to choose | `#1-the-three-tools-and-how-to-choose` |
| 2. `@available` and `if #available`: the runtime tool | `#2-available-and-if-available-the-runtime-tool` |
| 3. `#if canImport(Module)`: the module-absence tool | `#3-if-canimportmodule-the-module-absence-tool` |
| 4. `#if canImport(Module, _version:)`: what the number actually is | `#4-if-canimportmodule-_version-what-the-number-actually-is` |
| 5. SDK checks by build setting: the `[sdk=…27.*]` pattern | `#5-sdk-checks-by-build-setting-the-sdk27-pattern` |
| 6. SwiftPM traits: the package author's half | `#6-swiftpm-traits-the-package-authors-half` |
| 7. ⚠️ The empty library | `#7-️-the-empty-library` |
| 8. The worked example: `mlx-swift-lm` commit `3cbf928` | `#8-the-worked-example-mlx-swift-lm-commit-3cbf928` |
| 9. What is hard 27-only | `#9-what-is-hard-27-only` |
| 10. What is genuinely runtime-gateable | `#10-what-is-genuinely-runtime-gateable` |
| 11. Over-gating: the mistake in the other direction | `#11-over-gating-the-mistake-in-the-other-direction` |
| 12. Writing the shim layer | `#12-writing-the-shim-layer` |
| 13. ⚠️ The load-time failure no runtime guard can catch | `#13-️-the-load-time-failure-no-runtime-guard-can-catch` |
| 14. Drift inside a single major version | `#14-drift-inside-a-single-major-version` |
| 15. Known toolchain breakages | `#15-known-toolchain-breakages` |
| 16. CI strategy: the matrix, and why compiling is a weak signal | `#16-ci-strategy-the-matrix-and-why-compiling-is-a-weak-signal` |
| 17. A complete dual-SDK package and app target | `#17-a-complete-dual-sdk-package-and-app-target` |
| 18. Checklist | `#18-checklist` |
| 19. Declared gaps | `#19-declared-gaps` |
| Sources | `#sources` |

### 17.5 — Core ML to Core AI: what moves, what stays, and how

Core AI is the successor path for **neural networks**; Core ML remains correct for decision trees, tabular feature engineering, and the rest of its non-neural surface — so this is a partial migration by design.

**Local reference:** [part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| Evidence markers, and one standing caveat about the left column | `#evidence-markers-and-one-standing-caveat-about-the-left-column` |
| Contents | `#contents` |
| 1. Should you migrate at all? | `#1-should-you-migrate-at-all` |
| 2. The translation table | `#2-the-translation-table` |
| 3. ⚠️ What does not announce itself | `#3-️-what-does-not-announce-itself` |
| 4. What genuinely improves, and why | `#4-what-genuinely-improves-and-why` |
| 5. What you give up, honestly | `#5-what-you-give-up-honestly` |
| 6. The conversion path: `coremltools` versus `coreai-torch` | `#6-the-conversion-path-coremltools-versus-coreai-torch` |
| 7. A decision table for "don't migrate yet" | `#7-a-decision-table-for-dont-migrate-yet` |
| 8. The incremental strategy | `#8-the-incremental-strategy` |
| 9. Quick reference | `#9-quick-reference` |
| 10. Sources and evidence ledger | `#10-sources-and-evidence-ledger` |

### 17.6 — Toolchain and asset compatibility

The migration nobody warns you about: your *build artifacts* have compatibility constraints independent of your source.

**Local reference:** [part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. The thesis: your artifacts are not a pure function of your recipe | `#1-the-thesis-your-artifacts-are-not-a-pure-function-of-your-recipe` |
| 2. The artifact inventory: five classes, five invalidation rules | `#2-the-artifact-inventory-five-classes-five-invalidation-rules` |
| 3. Incident 1 — the `coreai-torch` 0.4.0 IR-location break | `#3-incident-1--the-coreai-torch-040-ir-location-break` |
| 4. Incident 2 — the macOS 26 → 27 export-lowering regression | `#4-incident-2--the-macos-26--27-export-lowering-regression` |
| 5. Specialization artifacts are tied to the device *and the OS version* | `#5-specialization-artifacts-are-tied-to-the-device-and-the-os-version` |
| 6. Bookmarks stop resolving — into a silent `else` | `#6-bookmarks-stop-resolving--into-a-silent-else` |
| 7. `coreai-build compile` exits 0 for architectures a device will reject | `#7-coreai-build-compile-exits-0-for-architectures-a-device-will-reject` |
| 8. `metadata.json`'s `compression` field records the request, not the result | `#8-metadatajsons-compression-field-records-the-request-not-the-result` |
| 9. Package-level migrations | `#9-package-level-migrations` |
| 10. The artifact provenance checklist | `#10-the-artifact-provenance-checklist` |
| 11. Triage: what to check, in what order | `#11-triage-what-to-check-in-what-order` |
| 12. Sources and evidence ledger | `#12-sources-and-evidence-ledger` |
