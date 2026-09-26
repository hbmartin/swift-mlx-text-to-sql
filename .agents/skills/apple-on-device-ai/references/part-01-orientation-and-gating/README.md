# Part 1 — Orientation and gating

**Version floor:** **iOS / iPadOS / macOS / visionOS 26.0 → 27.0**, **watchOS 27.0**, **tvOS 27.0**,
built with **Xcode 26 → 27**. Four OS floors are live at once — **26.0**, **26.2**, **26.4** and
**27.0** — and this part is where they are told apart.

**Who this is for:** everyone. Whatever you plan to build on this stack, the two guides here are
the ones you read before the part that covers your actual job. If you read nothing else in the
series, read [1.1 §1](references/01-apple-ai-stack-2026-map.md#1-the-one-thing-that-changed) and the
SILENT FAILURE callouts in [1.2](references/02-platform-and-version-gating.md).

---

## Why this part exists

Two questions decide almost everything downstream, and both get answered *before* you write code.

**The first is that the question itself changed.** Through 2025 you picked a *framework* —
Foundation Models, or Core ML, or MLX — and the pick was a fork in the road: different types,
different file formats, no path between them that didn't mean rewriting your call sites. In 2026
`LanguageModelSession` grew a public `LanguageModel` / `LanguageModelExecutor` protocol pair, and
Apple shipped conformers that put Core AI and MLX *underneath* the Foundation Models API rather than
beside it. So the question became **which backend runs behind one session API** — a per-feature
decision you can change later without touching your app code. Real apps ship five or six backends at
once; that is not indecision, it is what the protocol makes cheap.

**The second is that nothing in this stack tells you when you got the gate wrong.** A version
mistake here does not produce a diagnostic. It produces an empty library that imports fine, a
`catch` block that stops catching, a model that reports `isAvailable == true` and then fails with
error `-1`, a `#if` block that evaporates and takes your feature with it, or a `prewarm` that
compiles and is never called. Version confusion is the single largest generator of phantom bug
reports in the developer forums, and it is cheap to eliminate up front and expensive to debug later.

A third thing this part carries, which no other part does: **the known-bad-claims reference**. There
is material in circulation about this stack that is demonstrably fabricated — `.coreaimodel`,
`.aiasset`, a `coreai-torch convert` CLI, "iOS 20 / macOS 17", an on-device LoRA training API that
never shipped. If you search the web for a Core AI tutorial you will land on it, and so will your
coding agent. Both guides carry the inoculation.

---

## Read this first: the triage table

Two guides, but they are long. Work down this table and jump straight to the section named.

| If your situation is… | Read | Where |
|---|---|---|
| "I don't know whether I want Foundation Models, Core AI, or MLX" | 1.1 | [§3](references/01-apple-ai-stack-2026-map.md#3-the-five-languagemodel-conformers) then [§5](references/01-apple-ai-stack-2026-map.md#5-the-decision-table) |
| "I want a Hugging Face model in my app's real prompt flow *this afternoon*" | 1.1 | [§3.5](references/01-apple-ai-stack-2026-map.md#35-chatcompletionslanguagemodel--the-one-that-works-today) — `mlx_lm.server` + `ChatCompletionsLanguageModel` |
| "I have a tok/s number and want to know whether it means anything" | 1.1 | [§6.4](references/01-apple-ai-stack-2026-map.md#64-why-a-toks-number-without-a-protocol-is-meaningless) |
| "My feature is always-on / battery-sensitive" | 1.1 | [§6.2](references/01-apple-ai-stack-2026-map.md#62-iphone-17-pro-matched-bytes-throughput-parity-and-an-energy-inversion) and [§6.3](references/01-apple-ai-stack-2026-map.md#63-three-rankings-from-one-device-burst-sustained-and-joules) — the ranking inverts by axis |
| "I need `@Generable` **and** my own weights" | 1.1 | [§3.3](references/01-apple-ai-stack-2026-map.md#33-coreailanguagemodel--270-your-weights-apples-runtime) — Core AI's *fastest* engine can't do it |
| "I have a working Core ML model — do I move it?" | 1.1 | [§4](references/01-apple-ai-stack-2026-map.md#4-where-core-ml-still-belongs) |
| "My streaming UI spins forever and nothing threw" | 1.1 | [§7](references/01-apple-ai-stack-2026-map.md#7-silent-failures-you-can-hit-before-you-write-a-line-of-model-code) — a tool-only turn yields zero partials |
| "A blog post gave me an API that doesn't compile" | 1.1 | [§8](references/01-apple-ai-stack-2026-map.md#8-known-bad-claims-material-in-circulation-that-is-fabricated) |
| "Am I even allowed to use Private Cloud Compute?" | 1.2 | [§8.2](references/02-platform-and-version-gating.md#82-private-cloud-compute-three-conditions-and-two-of-them-are-commercial) — two of the three conditions are commercial |
| "`cannot find 'MLXLanguageModel' in scope`" | 1.2 | [§3.3](references/02-platform-and-version-gating.md#33-️-the-empty-library-failure) — it's your Xcode version, not your dependency |
| "It fails in the Simulator with error `-1`" | 1.2 | [§10.1](references/02-platform-and-version-gating.md#101-the-simulator-punches-out-to-the-host-mac) |
| "Apple Intelligence is on, but availability says it isn't" | 1.2 | [§7.4](references/02-platform-and-version-gating.md#74-the-siri-toggle-coupling--an-acknowledged-defect-not-a-gate) — the Siri coupling, an acknowledged bug |
| "I'm rebuilding an iOS 26 app with Xcode 27" | 1.2 | [§3.4](references/02-platform-and-version-gating.md#34-️-the-xcode-26--27-rebuild-changes-which-catch-fires), then [Part 17](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/README.md) |
| "I'm shipping to watchOS" | 1.2 | [§2.2](references/02-platform-and-version-gating.md#22-️-the-watchos-contradiction-you-must-plan-around) and [§10.3](references/02-platform-and-version-gating.md#103-watchos--pcc-needs-a-paired-iphone) |
| "I want the App Store to only offer my app to capable devices" | 1.2 | [§9](references/02-platform-and-version-gating.md#9-app-store-distribution-there-is-no-capability-flag) — you can't; build a baseline |
| "I'm bundling `.aimodel` files" | 1.2 | [§4.1](references/02-platform-and-version-gating.md#41-the-apple-intelligence-floor) and [§5.2](references/02-platform-and-version-gating.md#52-the-metal-toolchain-is-not-installed-by-default) |
| "What hardware do I actually need to test on?" | 1.2 | [§12](references/02-platform-and-version-gating.md#12-what-to-test-on) |
| "Just give me something that compiles and tells me what I can use" | 1.2 | [§11](references/02-platform-and-version-gating.md#11-a-runnable-preflight-check) |

---

## The guides in this part

### [1.1 — The 2026 Apple AI stack, and how to choose a model backend](references/01-apple-ai-stack-2026-map.md)

The map, and the decision it replaced. It walks the layer diagram (Foundation Models → Core AI / MLX
→ Metal Performance Primitives, with Evaluations cutting across and Core ML narrowed to non-neural
models beside it), then the five shipping `LanguageModel` conformers — `SystemLanguageModel`,
`PrivateCloudComputeLanguageModel`, `CoreAILanguageModel`, `MLXLanguageModel` and
`ChatCompletionsLanguageModel` — with what each asks you to bring, what it costs, and where it
breaks. It ends in a decision table keyed on constraints you actually have (privacy, offline, cost,
model choice, context, latency, energy, app size, eligibility), a fully-attributed performance
section, and the series' known-bad-claims blacklist.

The performance section is the part most readers underestimate. **The ranking inverts depending on
what you measure** on the same hardware: Core AI ties or beats MLX by 4–12% on dense models and
loses MoE by 28%; the ANE wins sustained throughput and GPU exclusivity but is the *worst* joules
per token when it is slow; Apple's own system model is the energy champion at half the token rate;
MLX owns the Mac energy Pareto frontier. Every number is community-measured on beta OSes by one
research group, and the guide says so on the section header.

> ⚠️ **SILENT FAILURE** — `LanguageModelExecutor.prewarm(model:transcript:)` ships with a default
> no-op extension. A near-miss signature compiles, fails to bind as the protocol witness, and the
> framework's no-op wins silently. Three independent sources report it, including in Apple's own
> Core AI adapter today. Put a breakpoint in your `prewarm`; do not infer it from timing.
>
> ⚠️ **SILENT FAILURE** — a response stream can finish having yielded **zero** partials. If the model
> answers a turn with only a tool call, the stream completes normally, and any UI that shows a spinner
> "until the first token" hangs forever — nothing threw and nothing timed out. Count the partials you
> consumed and branch on zero. Apple's Origami sample is the only one that handles this, and no WWDC26
> session mentions it.
>
> 🔴 **GAP (narrowed)** — which `LanguageModelSession.init(model:…)` overload actually exists on the
> 27 SDK. Apple's reference page types the classic initializers against `SystemLanguageModel`; Apple's
> PCC article says you can pass any conformer to the same initializer; and Apple's sample code
> instructs you to swap the model property to `PrivateCloudComputeLanguageModel` by editing one line,
> which only makes sense if the generic overload exists — but ships the `SystemLanguageModel`
> configuration, so the swapped form is untested code in a comment. The generic reading is now much
> the likelier one. Resolution still needs a read of `FoundationModels.swiftinterface` from an
> Xcode 27 SDK.
>
> 🔴 **GAP** — **Core AI has no Apple sample code at all.** A sweep of Apple's sample-code indexes
> found zero projects for `coreai`, against three for `foundationmodels` / `evaluations` /
> `corespotlight`. Every Core AI claim in this series is doc-, transcript- or community-sourced,
> never confirmed against compiling first-party code — weigh §3.3 and Parts 7–10 accordingly.

### [1.2 — Every version, hardware, entitlement and runtime-surface gate](references/02-platform-and-version-gating.md)

The complete inventory of everything sitting between the code you write and a feature that runs:
the four OS floors and what each one *means*, a per-symbol decoder ring for FoundationModels, Core
AI, Evaluations, Speech and TensorOps, the SDK-versus-runtime distinction that `@available` cannot
paper over, the Apple Intelligence hardware floor (A17 Pro / M1 / M2) and the **two on-device model
tiers** that split by device from the fall Siri release, four first-party packages with four
different version floors, the PCC entitlement and its three conditions, and the full
`availability` / quota / locale runtime surface. It closes with a runnable preflight check, a
test-matrix table, and the version-specific known-bad claims.

This guide is *mostly* silent failures, and it says so in its own opening callout. The ones worth
knowing before you start:

> ⚠️ **SILENT FAILURE** — when `#if canImport(FoundationModels, _version: 2)` is false, the guarded
> code does not error, it **ceases to exist**. `MLXFoundationModels` compiles to an empty library on
> the 26 SDK; your import succeeds, your build succeeds, and the diagnostic you eventually get
> points at your call site instead of your Xcode version. This broke mlx-swift-lm's own nightly job.
>
> ⚠️ **SILENT FAILURE** — rebuilding with Xcode 27 changes which `catch` fires. Your
> `catch let e as LanguageModelSession.GenerationError` block still compiles (deprecated, not
> removed) and simply never fires again. Apple states this in a deprecation notice rather than a
> release note.
>
> ⚠️ **SILENT FAILURE** — the canonical three-arm `catch` an Apple engineer posted on the forums, now
> confirmed verbatim in **two** Apple sample projects, does **not** mention `SystemLanguageModel.Error`
> — and that type is not reachable as a `LanguageModelError` case. Copy the pattern as-is and every
> "Apple Intelligence isn't available right now" failure falls straight through to your bare
> `catch { }`, which is the one category of failure the user could have fixed themselves. Check
> `SystemLanguageModel.Error` **first**.
>
> ⚠️ **Not silent — fatal.** Constructing a `PrivateCloudComputeLanguageModel` without the granted
> entitlement triggers a `fatalError`, not a catchable throw.
>
> 🔴 **GAP** — `SystemLanguageModel`'s symbol page carries no watchOS availability, while the same
> page's model-version list and session 339 both say watchOS 27 is supported. Unresolved. Until
> someone greps the watchOS 27 SDK's `.swiftinterface`, design watch features as if the on-device
> model may not be reachable there — PCC on watchOS is not in doubt.
>
> 🔴 **GAP** — what actually differs between **AFM 3 Core** and **AFM 3 Core Advanced** is unknown,
> and there is no API that tells you which tier you got. Apple named the device split and said
> "guidance will evolve." Evaluate on both tiers.

---

## Reading order

1. **[1.1 §1](references/01-apple-ai-stack-2026-map.md#1-the-one-thing-that-changed) — the one thing
   that changed.** Four minutes. Nothing else in the series parses correctly without it.
2. **[1.1 §5](references/01-apple-ai-stack-2026-map.md#5-the-decision-table) — the decision table.**
   Stop at the first row describing a constraint you actually have. If it lands on
   `SystemLanguageModel`, you are done choosing; go to
   [Part 2](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/README.md).
3. **All of [1.2](references/02-platform-and-version-gating.md) — before you write code, not after.**
   This is the guide that pays for itself. If you read it selectively, read §3 (SDK vs runtime
   gates), §7 (the runtime availability surface) and §11 (the preflight check).
4. **[1.1 §6](references/01-apple-ai-stack-2026-map.md#6-the-honest-performance-picture) — the
   performance picture**, only if you are choosing between backends on speed or energy grounds, or
   about to quote a benchmark. Its conclusion is that 4–12% deltas are not a reason to change
   frameworks, because they are smaller than the swing from a different measurement protocol (1.6×),
   a different export environment (2.2×), or a different downloaded file (84 GSM8K points).

**Safe to defer:** [1.1 §3.6](references/01-apple-ai-stack-2026-map.md#36-the-protocol-itself-and-why-it-is-two-types)
(the protocol shape) until you author or debug a provider — [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md)
covers it properly. **Safe to skip entirely** unless it applies: §4 (Core ML) if you have no Core ML
models; §8 (known-bad claims) if you are not consuming third-party tutorials or letting an agent
write against this stack — though that exemption is narrower than it sounds.

---

## What this part deliberately does not cover

- **How to actually use a session** — prompting, `@Generable`, tools, streaming, the error taxonomy.
  This part tells you which backend and whether it will run; [Part 2](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/README.md)
  and [Part 3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/README.md) tell you what to do with it.
- **PCC in practice** — reasoning levels, quota UX, the fallback architecture. Eligibility is here;
  the implementation is in [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md).
- **Authoring a `LanguageModel` provider** — capabilities, the generation channel, the executor
  store and KV reuse. [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md).
- **Regression-testing across OS updates.** There is no model version pinning API and three distinct
  on-device model versions in the wild; the only mitigation, recommended by Apple staff directly, is
  [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md).
- **The 26 → 27 migration itself** — the adapter sunset, the error-mapping table, dual-SDK builds,
  toolchain and asset compatibility. Gates are here; the migration is
  [Part 17](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/README.md).
- **Benchmarking methodology, thermals, jetsam and memory.** §6 gives the numbers and their caveats;
  [Part 15](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/README.md) gives the method.

---

## Sources for this part

Apple documentation harvested 2026-07-27: the `foundationmodels`, `coreai`, `evaluations` and
`speech` framework indexes plus individual symbol pages; the Private Cloud Compute, ahead-of-time
compilation, language/locale, and model-version articles; and the live
`developer.apple.com/private-cloud-compute/` and `/core-ai-debugger/` pages. WWDC26 sessions 241,
243, 246, 319, 330, 334 and 339, plus the Meet-with-Apple 205 code-along. Roughly thirty Apple Developer
Forums threads fetched individually — among them 831404 (the Simulator punch-out and the canonical
three-arm `catch`), 832910 (the AFM 3 Core / Core Advanced device split), 835211 and 836760 (the
Siri-toggle coupling), 833575 (extensions and XPC), 836810 (App Store distribution), 838444 (the
`/v1` path defect) and 835897 (cumulative PCC downloads). Source read on disk: the
`MetalPerformancePrimitives` headers shipped in the Xcode SDK, and the `apple/coreai-models`,
`apple/foundation-models-utilities`, `apple/python-apple-fm-sdk`, `ml-explore/mlx-swift-lm` and
`ml-explore/mlx` repositories. **Three Apple sample-code archives were downloaded and read as
compiling first-party source** — Origami ("Crafting a dynamic tutorial for Apple Intelligence", 61
Swift files at 27.0), the Core Spotlight hiking-trails app, and Book Tracker (Evaluations) — and they
outrank transcript reconstructions throughout both guides; `coreai` has none. Every performance number in 1.1 §6 is **community-measured on beta
operating systems** by the `apple-silicon-llm-bench` / `coreai-model-zoo` project and is attributed
as such at the point of use, alongside that project's own published self-corrections.
