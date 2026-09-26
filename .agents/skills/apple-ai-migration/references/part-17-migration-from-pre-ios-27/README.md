# Part 17 — Migration from pre-iOS 27

**Version floor:** you have a shipping app or pipeline built against **iOS/macOS 26.x**, **Xcode 26**,
`coreai-torch` ≤ 0.4.x, or `mlx-swift-lm` 2.x, and you are moving to **iOS/macOS 27** and **Xcode 27**.

> ⚠️ **SILENT FAILURE** — this is the part of the series where that warning matters most. Almost
> nothing in this migration announces itself. Your code keeps compiling. Your `catch` blocks keep
> catching — just not the errors they used to. Your model keeps converting — into an artifact that
> is 2.2× slower. The single most expensive assumption you can make this year is *"it still builds,
> so it still works."*

---

## Why this part exists

The 26 → 27 transition is not a normal SDK bump. Four things happened at once:

1. **A capability was withdrawn.** Custom LoRA adapters — the headline extensibility story of the
   2025 release — are discontinued. This is not a deprecation with a replacement; it is a removal
   with a *differently-shaped* replacement in another framework.
2. **The error taxonomy was rewritten.** `LanguageModelError` supersedes `GenerationError`.
   Rebuilding with Xcode 27 can silently change which `catch` clause fires, with no diagnostic.
3. **Model behaviour changed underneath shipping apps.** Guardrails, refusals and the on-device
   model itself were all rebuilt. Apps that worked in production for months began failing on
   27 betas without a line of code changing.
4. **Artifacts stopped being pure functions of recipes.** The same conversion command, same wheels,
   same source checkpoint, run on macOS 26 versus macOS 27, produces materially different assets —
   and some assets built with older tooling are rejected outright by newer compilers.

Points 3 and 4 are the ones that catch teams out, because neither is visible in a diff.

---

## Read this first: the five-minute triage

Work down this table. If any row applies to you, jump to the guide named in the last column.

| If your project… | Then… | Guide |
|---|---|---|
| ships a custom `.fmadapter` | **Stop.** Your feature has no forward path as built. | [17.2](references/02-adapter-sunset.md) |
| has `catch GenerationError` anywhere | Your error handling is probably now dead code | [17.3](references/03-error-taxonomy-migration.md) |
| relies on guardrail behaviour tuned against 26.x | Re-test every prompt; expect new refusals | [17.3](references/03-error-taxonomy-migration.md) |
| must run on both 26 and 27 | You need conditional compilation, not just availability checks | [17.4](references/04-dual-sdk-builds.md) |
| uses Core ML for neural networks | Evaluate Core AI; some model types should *stay* on Core ML | [17.5](references/05-coreml-to-coreai.md) |
| has `.aimodel` assets built with `coreai-torch` 0.4.0 | They may be unloadable on current tooling | [17.6](references/06-toolchain-and-asset-compatibility.md) |
| re-exports models on a machine you upgraded to macOS 27 | Benchmark before and after; do not assume parity | [17.6](references/06-toolchain-and-asset-compatibility.md) |
| depends on `mlx-swift-lm` | `main` is 3.x with breaking changes | [17.6](references/06-toolchain-and-asset-compatibility.md) |
| calls Foundation Models from Python | The Python SDK trails the Swift framework by a release | [17.1](references/01-what-changed-checklist.md) |

---

## The guides in this part

### [17.1 — What changed between iOS 26 and iOS 27: the complete checklist](references/01-what-changed-checklist.md)

The exhaustive diff, organised by framework, with each item marked as *additive*, *behavioural*,
*renamed* or *withdrawn*. Includes the version-floor table (26.0 / 26.4 / 27.0, plus the separate
TensorOps ladder), the
availability-gating change that now ties `SystemLanguageModel.default.availability` to whether the
user has Siri enabled, and the Python-SDK generation lag. **Start here if more than two rows of the
triage table apply to you.**

### [17.2 — The adapter sunset: migrating off custom LoRA adapters](references/02-adapter-sunset.md)

What was withdrawn, what the evidence for the withdrawal actually is, and the three realistic
forward paths: re-frame the task as prompting plus guided generation; move the specialised model to
Core AI and drive it through `CoreAILanguageModel`; or move it to MLX and drive it through
`MLXFoundationModels`. Covers what happens to `.fmadapter` assets, `SystemLanguageModel.Adapter`
(now `deprecated: 26.4, obsoleted: 27.0` in the 27 SDK interface — the sunset is header-level fact,
not just forum replies), the Adapter Training Toolkit (which stops at 26.0.0), and
`xcrun ba-package foundation-models` — which, surprisingly, still ships in the Xcode 27.0 beta even
though the API that consumed its output is obsoleted. Includes the `compatibleAdapterNotFound`
failure that developers hit shipping adapters through TestFlight, for readers still supporting a
26.x build.

> 🔴 **GAP** — Apple named the migration path (Core ML / Core AI plus Background Assets) but has
> documented it end to end nowhere. This guide constructs it from parts and says so explicitly.

### [17.3 — Error taxonomy migration: `GenerationError` → `LanguageModelError`](references/03-error-taxonomy-migration.md)

The mapping table, old case to new case — now SDK-interface-verified on **both** sides (the 26.5 and
27.0 beta `FoundationModels.swiftinterface` dumps), with every destination confirmed by the per-case
deprecation messages Apple attached to the old enum in the 27 SDK. Why a rebuild
changes which `catch` fires without a compiler diagnostic. The distinction that trips up nearly
everyone: a **model-level refusal** (`LanguageModelError`, "the model refused to answer" / "may
contain sensitive content") is a different mechanism from a **guardrail violation**
(`GenerationError.guardrailViolation`), and 27 shifted traffic between them. Includes the
`SystemLanguageModel(guardrails: .permissiveContentTransformations)` escape hatch, its documented
limitation that it does not apply to `Generable`, and a regression-test recipe using the
Evaluations framework so you find out before your users do.

### [17.4 — Building for two SDKs: conditional compilation across 26 and 27](references/04-dual-sdk-builds.md)

`#if canImport` versus `@available` versus SDK-version checks, and when each is the right tool.
How to keep one codebase compiling against both the macOS 26 and 27 SDKs — the pattern
`mlx-swift-lm` uses in CI. Which symbols are hard 27-only (`MLXFoundationModels`, the whole
`LanguageModel` protocol surface, Dynamic Profiles) and therefore cannot be papered over with a
runtime check. Includes the watchOS 27 beta `CoreImage` module-resolution failure and how to work
around it.

### [17.5 — Core ML to Core AI: what moves, what stays, and how](references/05-coreml-to-coreai.md)

Core AI is the successor path for **neural networks**; Core ML remains correct for decision trees,
tabular feature engineering, and the rest of its non-neural surface — so this is a partial
migration by design. Covers the mental-model translation (`MLModel` → `AIModel`, `MLMultiArray` →
`NDArray`, compute-unit selection → `SpecializationOptions`, model compilation → specialization and
caching), what genuinely improves (states, multi-function assets, the debugger, ahead-of-time
compilation), and what you give up (a decade of samples and Stack Overflow answers; Core AI ships
with **zero** Apple sample-code projects). Includes a decision table for *don't migrate yet*.

### [17.6 — Toolchain and asset compatibility](references/06-toolchain-and-asset-compatibility.md)

The migration nobody warns you about: your *build artifacts* have compatibility constraints
independent of your source.
- **The `coreai-torch` 0.4.0 IR incident** — 0.4.0 baked PyTorch stack traces into MLIR locations
  that beta-2+ compilers reject outright. Wheel-pinning does not save you; `inspect` still works,
  which makes it look recoverable when it isn't. How to audit your bundles via the `producer` field
  in `metadata.json`, and how the `strip_debug_info` fix works.
- **The macOS 26 → 27 export-lowering regression** — identical recipe, identical wheels, identical
  device: a 2.2× slower, 2× larger artifact, because the dequantisation-folding decision consults
  the *running* OS. Community-measured; how to check whether it still applies to you.
- **`mlx-swift-lm` 2.x → 3.x** — the tokenizer/downloader decoupling and what it breaks.
- Re-specialisation and cache invalidation on OS update, and why `bookmarkData` can stop resolving.

> 🔴 **GAP** — the current status of several beta-era defects listed here is unknown as of
> 2026-07-29 and must be re-tested against current betas before you act on them. Each carries its
> own callout. (The GitHub-tracked issues behind 17.5/17.6 were re-checked against live state via
> `gh` on 2026-07-29 — see each callout; the beta-only reproductions remain unverified.)

---

## What this part deliberately does not cover

- **Migrating *to* Apple Intelligence from a third-party cloud LLM.** That is not a migration, it is
  an architecture choice — see [Part 1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/README.md) and
  [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md).
- **iOS 25 and earlier.** The Foundation Models framework did not exist; there is nothing to migrate.
- **Speech synthesis.** Developers expecting a new TTS API after the WWDC26 keynote should read the
  known-negative note in [Part 16](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/README.md) — no such API shipped, and
  Apple confirmed this directly on the Developer Forums.

---

## Sources for this part

The compiler-emitted SDK interfaces captured to `notes/sdk-interfaces/` on 2026-07-29 from the
Xcode 27.0 beta (`27A5228h`) — `FoundationModels` 26.5 **and** 27.0 (the BEFORE/AFTER pair that
made 17.3's mapping table symmetric and put the adapter sunset's `obsoleted: 27.0` annotation on
record for 17.2), the Core AI module family (`CoreAI` umbrella, `CoreAIDelegates`, `CoreAIRuntime`,
`CoreAIAsset` — the module map and the only-public-error-type finding in 17.5), and `Evaluations` —
plus direct toolchain probes of the same beta (`aimodelc` present in the app bundle, `fm` absent,
`ba-package foundation-models package` alive; `coreai-build` not included in the app bundle and
unresolved on the component-less 2026-07-29 install, then found 2026-07-31 after installing the
optional Metal Toolchain component, its `--help` captured to
`notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`) used in 17.2 and 17.6. Forum threads 836673 (the
iOS 27 refusal regression, with reproduction detail), 835777 (guardrail change under a shipping
app), 829108 (`compatibleAdapterNotFound` via TestFlight), 835987 (watchOS 27 `CoreImage`), 835211
and 836760 (the Siri-enablement gating change); two Apple-staff statements on the adapter
discontinuation; `apple/coreai-models` commit #123 ("Move away from deprecated FM API");
`apple/foundation-models-utilities` commit `376ca60`, whose message doubles as a precise
beta1 → beta3 framework API changelog; `ml-explore/mlx-swift-lm` 3.x upgrade documentation and its
dual-SDK CI configuration; and community forensics on the export-lowering regression and the
`coreai-torch` 0.4.0 incident, both attributed as community-measured in the guides themselves.
