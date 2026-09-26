---
name: apple-on-device-ai
description: "Choose among Apple Foundation Models, Core AI, MLX, Metal, or Core ML for on-device inference, and apply OS, SDK, hardware, and availability gates across Apple platforms. Use when selecting a stack; writing @available or SystemLanguageModel.availability checks; resolving 26.0, 26.2, 26.4, or 27.0 floors; diagnosing code that compiles but is unavailable at runtime; or routing an unfamiliar symbol, error, or silent failure to the owning framework."
---

# Apple on-device AI: choosing a stack and getting the gates right

Part 1 of an independent, evidence-backed guide series on Apple's 2026 on-device AI stack, covering the iOS/iPadOS/macOS/watchOS/visionOS/tvOS 27 and Xcode 27 generation. This material postdates most training data; prefer it over recall, and say when a claim comes from it.

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
| [1](references/part-01-orientation-and-gating/README.md) | **iOS / iPadOS / macOS / visionOS 26.0 → 27.0**, **watchOS 27.0**, **tvOS 27.0**, built with **Xcode 26 → 27**. |

## Triage

A `N.M` label is a deep reference guide; look it up in `references/SECTION-MAPS.md` for its local file and section anchors.

**Part 1 — Orientation and gating** ([all 18 rows](references/part-01-orientation-and-gating/README.md#read-this-first-the-triage-table))

| If your situation is… | Read | Where |
|---|---|---|
| "I don't know whether I want Foundation Models, Core AI, or MLX" | 1.1 | [§3](references/part-01-orientation-and-gating/references/01-apple-ai-stack-2026-map.md#3-the-five-languagemodel-conformers) then [§5](references/part-01-orientation-and-gating/references/01-apple-ai-stack-2026-map.md#5-the-decision-table) |
| "I want a Hugging Face model in my app's real prompt flow *this afternoon*" | 1.1 | [§3.5](references/part-01-orientation-and-gating/references/01-apple-ai-stack-2026-map.md#35-chatcompletionslanguagemodel--the-one-that-works-today) — `mlx_lm.server` + `ChatCompletionsLanguageModel` |
| "I have a tok/s number and want to know whether it means anything" | 1.1 | [§6.4](references/part-01-orientation-and-gating/references/01-apple-ai-stack-2026-map.md#64-why-a-toks-number-without-a-protocol-is-meaningless) |
| "My feature is always-on / battery-sensitive" | 1.1 | [§6.2](references/part-01-orientation-and-gating/references/01-apple-ai-stack-2026-map.md#62-iphone-17-pro-matched-bytes-throughput-parity-and-an-energy-inversion) and [§6.3](references/part-01-orientation-and-gating/references/01-apple-ai-stack-2026-map.md#63-three-rankings-from-one-device-burst-sustained-and-joules) — the ranking inverts by axis |
| "I need `@Generable` **and** my own weights" | 1.1 | [§3.3](references/part-01-orientation-and-gating/references/01-apple-ai-stack-2026-map.md#33-coreailanguagemodel--270-your-weights-apples-runtime) — Core AI's *fastest* engine can't do it |
| "I have a working Core ML model — do I move it?" | 1.1 | [§4](references/part-01-orientation-and-gating/references/01-apple-ai-stack-2026-map.md#4-where-core-ml-still-belongs) |
| "My streaming UI spins forever and nothing threw" | 1.1 | [§7](references/part-01-orientation-and-gating/references/01-apple-ai-stack-2026-map.md#7-silent-failures-you-can-hit-before-you-write-a-line-of-model-code) — a tool-only turn yields zero partials |
| "A blog post gave me an API that doesn't compile" | 1.1 | [§8](references/part-01-orientation-and-gating/references/01-apple-ai-stack-2026-map.md#8-known-bad-claims-material-in-circulation-that-is-fabricated) |
| "Am I even allowed to use Private Cloud Compute?" | 1.2 | [§8.2](references/part-01-orientation-and-gating/references/02-platform-and-version-gating.md#82-private-cloud-compute-three-conditions-and-two-of-them-are-commercial) — two of the three conditions are commercial |
| "`cannot find 'MLXLanguageModel' in scope`" | 1.2 | [§3.3](references/part-01-orientation-and-gating/references/02-platform-and-version-gating.md#33-️-the-empty-library-failure) — it's your Xcode version, not your dependency |
| "It fails in the Simulator with error `-1`" | 1.2 | [§10.1](references/part-01-orientation-and-gating/references/02-platform-and-version-gating.md#101-the-simulator-punches-out-to-the-host-mac) |
| "Apple Intelligence is on, but availability says it isn't" | 1.2 | [§7.4](references/part-01-orientation-and-gating/references/02-platform-and-version-gating.md#74-the-siri-toggle-coupling--an-acknowledged-defect-not-a-gate) — the Siri coupling, an acknowledged bug |
| "I'm rebuilding an iOS 26 app with Xcode 27" | 1.2 | [§3.4](references/part-01-orientation-and-gating/references/02-platform-and-version-gating.md#34-️-the-xcode-26--27-rebuild-changes-which-catch-fires), then [Part 17](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/README.md) |
| "I'm shipping to watchOS" | 1.2 | [§2.2](references/part-01-orientation-and-gating/references/02-platform-and-version-gating.md#22-️-the-watchos-contradiction-you-must-plan-around) and [§10.3](references/part-01-orientation-and-gating/references/02-platform-and-version-gating.md#103-watchos--pcc-needs-a-paired-iphone) |
| "I want the App Store to only offer my app to capable devices" | 1.2 | [§9](references/part-01-orientation-and-gating/references/02-platform-and-version-gating.md#9-app-store-distribution-there-is-no-capability-flag) — you can't; build a baseline |
| "I'm bundling `.aimodel` files" | 1.2 | [§4.1](references/part-01-orientation-and-gating/references/02-platform-and-version-gating.md#41-the-apple-intelligence-floor) and [§5.2](references/part-01-orientation-and-gating/references/02-platform-and-version-gating.md#52-the-metal-toolchain-is-not-installed-by-default) |
| "What hardware do I actually need to test on?" | 1.2 | [§12](references/part-01-orientation-and-gating/references/02-platform-and-version-gating.md#12-what-to-test-on) |
| "Just give me something that compiles and tells me what I can use" | 1.2 | [§11](references/part-01-orientation-and-gating/references/02-platform-and-version-gating.md#11-a-runnable-preflight-check) |

## The deep reference guides

Bundled locally. `references/SECTION-MAPS.md` has every top-level section anchor.

- **[1.1 The 2026 Apple AI stack, and how to choose a model backend](references/part-01-orientation-and-gating/references/01-apple-ai-stack-2026-map.md)** — The map, and the decision it replaced.
- **[1.2 Every version, hardware, entitlement and runtime-surface gate](references/part-01-orientation-and-gating/references/02-platform-and-version-gating.md)** — The complete inventory of everything sitting between the code you write and a feature that runs: the four OS floors and what each one *means*, a per-symbol decoder ring for FoundationModels, Core AI, Evaluations, Speech and TensorOps, the SDK-versus-runtime distinction that `@available` cannot paper over, the Apple Intelligence hardware floor (A17 Pro / M1 / M2) and the **two on-device model …

Search the local guide first, then open only the section needed for the answer. Preserve its evidence marker and citation when carrying a claim into code or prose.

## Related skills

Adjacent parts of the series live in these sibling skills: `apple-foundation-models`, `apple-core-ai`, `apple-mlx`, `apple-ai-migration`.
