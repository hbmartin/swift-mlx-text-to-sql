---
name: apple-ai-shipping
description: "Ship and operate on-device AI models in released Apple apps: distribution outside the app binary, background asset packs and updates, download and disk budgets, memory pressure and jetsam, thermal throttling, and honest inference benchmarks. Use when choosing an update channel, diagnosing termination or throttling mid-inference, sizing deployed assets, or designing and interpreting cold-start, steady-state, memory, power, and thermal measurements."
---

# Shipping and operating on-device AI in a released app

Part 15 of an independent, evidence-backed guide series on Apple's 2026 on-device AI stack, covering the iOS/iPadOS/macOS/watchOS/visionOS/tvOS 27 and Xcode 27 generation. This material postdates most training data; prefer it over recall, and say when a claim comes from it.

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
| [15](references/part-15-shipping-and-operating/README.md) | **iOS · iPadOS · macOS · tvOS · visionOS · watchOS 27.0 — all Beta** — plus **Xcode 27** and the **Metal Toolchain**, a separate download (`xcodebuild -downloadComponent MetalToolchain`) whose absence fails any build containing a `.aimodel` with a *missing Metal compiler* error that never mentions Core AI. |

## Read these before you trust a signature

- **Part 15** — [Read this before anything else in this part](references/part-15-shipping-and-operating/README.md#️-read-this-before-anything-else-in-this-part)

## Triage

A `N.M` label is a deep reference guide; look it up in `references/SECTION-MAPS.md` for its local file and section anchors.

**Part 15 — Shipping and operating on device** ([all 13 rows](references/part-15-shipping-and-operating/README.md#read-this-first-the-triage-table))

| If your situation is… | Read | Why |
|---|---|---|
| "My models add over a gigabyte to the app download" | [15.1 §1–§3](references/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#1-the-size-problem) | Host remotely, download one variant; the first-run screen is where the wait belongs |
| "How do I actually deliver the bytes?" | [15.1 §3](references/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#3-background-assets) | 🔴 no verified 2026 Background Assets surface for Core AI — own the delivery protocol, `URLSession` first |
| "Works on my Mac, `invalidCompiledModel` on device" | [15.1 §4.4, §5](references/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#44-️-architecture-codes-track-the-device-identifier-not-the-marketing-name) | iPhone 17 Pro is `iPhone18,1` → **`h18p`**, not `h17p`. Never hardcode an arch code |
| "Users report 'Download failed' on a perfectly good connection" | [15.1 §5.2](references/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#52-why-this-is-worse-than-an-ordinary-build-failure) | A wrong `--architecture` becomes a **404 from your asset host**, which your retry logic hides forever |
| "First launch stalls for tens of seconds, or minutes" | [15.1 §2, §6](references/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#2-the-feature-introduction-screen) | Specialization. 19.2 s JIT vs 4.9 s AOT on one measured model; ≥ 1 GB means AOT |
| "The stall came back after I fixed it" · "storage grew by a multiple of my model" | [15.1 §9](references/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#9-️-silent-failure-two-options-structs-two-multi-gigabyte-specializations) | `SpecializationOptions` is part of the cache key and has a mutable property |
| "I deleted the source `.aimodel` and now nothing loads" | [15.1 §8](references/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#8-️-silent-failure-the-bookmark-that-quietly-stops-working) | Bookmarks do not pin the cache entry, and resolution fails by returning `nil` |
| "I need to push a model update to shipped users" | [15.1 §7](references/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#7-updating-a-model) | Delete cache entries **before** replacing the file; `deleteEntries(for:)`, not the single-entry form |
| "Can I stop this installing on devices where it won't work?" | [15.1 §12](references/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#12-the-app-store-reality-you-cannot-gate-installation) | No. Four strategies for the world where you can't |
| "It loaded, then the app just vanished" · `signal 9` · `std::bad_alloc` | [15.2 §1–§3](references/part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md#1-the-jetsam-model) | Jetsam. Load success is not a fit test; the first step is the test |
| "My tok/s moves 40% between runs on the same device" | [15.2 §7.1](references/part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md#71-the-dvfs-finding) | DVFS clock ramp, with thermals eliminated as the cause. 66 → 102 tok/s, one afternoon |
| "Which backend should I ship?" | [15.2 §7.3, §8](references/part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md#73-sustained-throughput-the-gpuane-inversion) | Burst and sustained give different rankings; so do tok/s and battery |
| "I'm about to publish a comparison" | [15.2 §9–§10](references/part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md#9-honest-benchmarking) | Read §9.9 first. A harness once manufactured an 80%-vs-20% gap that was entirely its own bugs |

## The deep reference guides

Bundled locally. `references/SECTION-MAPS.md` has every top-level section anchor.

- **[15.1 Shipping models: Background Assets, per-architecture variants, and updates](references/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md)** — The operational guide for how a model reaches a device and how it gets replaced later: the size problem, the feature-introduction screen (which does three jobs at once and is where you hide specialization latency), delivery, `coreai-build compile` and per-architecture `.aimodelc` variants, specialization and its cache, the update sequence, storage hygiene, app groups, and the App Store reality.
- **[15.2 Memory, jetsam, thermals, energy, and measuring honestly](references/part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md)** — The gap between a demo that works on your desk and an app that survives a week on someone else's phone.

Search the local guide first, then open only the section needed for the answer. Preserve its evidence marker and citation when carrying a claim into code or prose.

## Related skills

Adjacent parts of the series live in these sibling skills: `apple-core-ai`, `apple-foundation-models`, `apple-ai-evaluations`.
