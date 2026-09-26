# Part 15 — Shipping and operating on device

**Version floor:** **iOS · iPadOS · macOS · tvOS · visionOS · watchOS 27.0 — all Beta** — plus
**Xcode 27** and the **Metal Toolchain**, a separate download (`xcodebuild -downloadComponent
MetalToolchain`) whose absence fails any build containing a `.aimodel` with a *missing Metal
compiler* error that never mentions Core AI. Ahead-of-time compilation has a much narrower floor
than the framework: Apple's article states verbatim that it *"only compiles for devices that support
Apple Intelligence, including iPhone or iPad with the A17 Pro chipset or later, a Mac with the M1
chipset or later, or Apple Vision Pro with the M2 chipset or later"* — everything older takes the
portable path regardless of what you do. Guide 15.2 is deliberately *older* than 27: jetsam,
`os_proc_available_memory()`, `phys_footprint`, `ProcessInfo.ThermalState` and the
`com.apple.developer.kernel.increased-memory-limit` entitlement all long predate 2026, and the
shipping app it leans on hardest targets `IPHONEOS_DEPLOYMENT_TARGET = 18`.

**Who this is for:** anyone who has a model that works on their desk and now has to put it in
strangers' hands — get the bytes there, get them specialized, keep the app alive under memory
pressure, replace the model later, and quote a number about it without lying. Nothing here requires
Apple Intelligence to be *enabled*, and nothing here uses `SystemLanguageModel` as a subject; this
is the plumbing under a bring-your-own-model feature.

---

## ⚠️ Read this before anything else in this part

**Almost every failure mode in Part 15 is silent, and every one of them lands after a green CI
build.** That is not a stylistic flourish; it is the structural property of this part, and it is
what makes it the closing loop of [Part 1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/README.md). Part 1 asked *which
backend*. This part is where that decision is tested by the only judge that counts, and the judge
does not file a bug report — it force-quits.

Consider what your pipeline actually validates. `coreai-build compile` **exits 0 for architectures
no device will load**. A model that **loads successfully** is not a model that runs — a 1.8 GB
bundle was community-measured loading cleanly on an iPhone 17 Pro in 6.5–8.1 s and then
jetsam-SIGKILLed on its *first inference step*. `AIModel(resolvingBookmark:)` returns **`nil`, not a
throw**, when the entry it names is gone, so the recovery path is an `else` branch — in Apple's own
sample, a bare comment — and the recovery itself is a multi-gigabyte re-download. Two
`SpecializationOptions` values that differ by one flag produce **two multi-gigabyte specializations**
with no error, no warning and no log line. The macOS version of your *build machine* changed
throughput by **2.2×** and memory by **2×** on an identical recipe, and no runtime API reports which
toolchain produced your artifact. The simulator catches none of it: there is no jetsam there,
thermal state is meaningless, and a compiled variant is never loaded at all.

---

## Why this part exists

Three separate problems converge after the model works and before Submit for Review.

1. **Size.** WWDC26 session 326's presenter, building on SAM 3 plus Qwen3 0.6B, hits it verbatim:
   *"I'd been assuming the models would just be bundled with the app and when I checked, they're
   adding over 1 GB to my download size. That hits everyone who updates, even people who'll never
   touch this feature."* Two sub-1B-class models. Over a gigabyte, charged to every updater.
   Guide 15.1 is the machinery for not doing that.
2. **The device is a hostile runtime.** iOS does not hand you an allocation failure; it kills you.
   The arithmetic "model is 4 GB, the phone has 8 GB, therefore fine" is wrong in at least five
   separate ways, and guide 15.2 documents three recorded device failures that a file-size check
   would have waved straight through — including an 18 GB bundle dying with `signal 9` **during a
   26-minute cold compile**, before inference was ever attempted.
3. **You cannot exclude the users this will not work for.** An Apple Frameworks Engineer, on thread
   836810: *"The App Store doesn't support a required device capability for Apple Intelligence."*
   There is no install-time gate. The same thread is where Apple recommends *this part's subject
   matter* as the answer — bring your own model via Core AI or MLX, because its hardware envelope is
   wider than Apple Intelligence's.

---

## Read this first: the triage table

| If your situation is… | Read | Why |
|---|---|---|
| "My models add over a gigabyte to the app download" | [15.1 §1–§3](references/01-model-distribution-and-updates.md#1-the-size-problem) | Host remotely, download one variant; the first-run screen is where the wait belongs |
| "How do I actually deliver the bytes?" | [15.1 §3](references/01-model-distribution-and-updates.md#3-background-assets) | 🔴 no verified 2026 Background Assets surface for Core AI — own the delivery protocol, `URLSession` first |
| "Works on my Mac, `invalidCompiledModel` on device" | [15.1 §4.4, §5](references/01-model-distribution-and-updates.md#44-️-architecture-codes-track-the-device-identifier-not-the-marketing-name) | iPhone 17 Pro is `iPhone18,1` → **`h18p`**, not `h17p`. Never hardcode an arch code |
| "Users report 'Download failed' on a perfectly good connection" | [15.1 §5.2](references/01-model-distribution-and-updates.md#52-why-this-is-worse-than-an-ordinary-build-failure) | A wrong `--architecture` becomes a **404 from your asset host**, which your retry logic hides forever |
| "First launch stalls for tens of seconds, or minutes" | [15.1 §2, §6](references/01-model-distribution-and-updates.md#2-the-feature-introduction-screen) | Specialization. 19.2 s JIT vs 4.9 s AOT on one measured model; ≥ 1 GB means AOT |
| "The stall came back after I fixed it" · "storage grew by a multiple of my model" | [15.1 §9](references/01-model-distribution-and-updates.md#9-️-silent-failure-two-options-structs-two-multi-gigabyte-specializations) | `SpecializationOptions` is part of the cache key and has a mutable property |
| "I deleted the source `.aimodel` and now nothing loads" | [15.1 §8](references/01-model-distribution-and-updates.md#8-️-silent-failure-the-bookmark-that-quietly-stops-working) | Bookmarks do not pin the cache entry, and resolution fails by returning `nil` |
| "I need to push a model update to shipped users" | [15.1 §7](references/01-model-distribution-and-updates.md#7-updating-a-model) | Delete cache entries **before** replacing the file; `deleteEntries(for:)`, not the single-entry form |
| "Can I stop this installing on devices where it won't work?" | [15.1 §12](references/01-model-distribution-and-updates.md#12-the-app-store-reality-you-cannot-gate-installation) | No. Four strategies for the world where you can't |
| "It loaded, then the app just vanished" · `signal 9` · `std::bad_alloc` | [15.2 §1–§3](references/02-memory-thermals-and-honest-benchmarking.md#1-the-jetsam-model) | Jetsam. Load success is not a fit test; the first step is the test |
| "My tok/s moves 40% between runs on the same device" | [15.2 §7.1](references/02-memory-thermals-and-honest-benchmarking.md#71-the-dvfs-finding) | DVFS clock ramp, with thermals eliminated as the cause. 66 → 102 tok/s, one afternoon |
| "Which backend should I ship?" | [15.2 §7.3, §8](references/02-memory-thermals-and-honest-benchmarking.md#73-sustained-throughput-the-gpuane-inversion) | Burst and sustained give different rankings; so do tok/s and battery |
| "I'm about to publish a comparison" | [15.2 §9–§10](references/02-memory-thermals-and-honest-benchmarking.md#9-honest-benchmarking) | Read §9.9 first. A harness once manufactured an 80%-vs-20% gap that was entirely its own bugs |

---

## The guides in this part

### [15.1 — Shipping models: Background Assets, per-architecture variants, and updates](references/01-model-distribution-and-updates.md)

The operational guide for how a model reaches a device and how it gets replaced later: the size
problem, the feature-introduction screen (which does three jobs at once and is where you hide
specialization latency), delivery, `coreai-build compile` and per-architecture `.aimodelc` variants,
specialization and its cache, the update sequence, storage hygiene, app groups, and the App Store
reality. It ends with a checklist and **twelve declared gaps collected in one table** (§14) — two
of them closed 2026-07-29 against the captured beta SDK interface — each with what would close it
and a safe default. Two numbers worth carrying in from §4.5: omitting
`--architecture` emitted **~20 Mac variants totalling 34 GB** on one measured export, and each
`.aimodelc` runs about **2× the size of its source** `.aimodel`.

> ⚠️ **SILENT FAILURE — three, and they compound.** (§5) `xcrun coreai-build compile` **exits 0 for
> any requested architecture**; only a device load validates the choice, and the arch codes track the
> *device identifier*, not the marketing name, so "iPhone 17 Pro" plausibly reads as `h17p` and is
> actually `h18p` — CI green, simulator green, every non-17-Pro device green, and
> `invalidCompiledModel` in a user's hands. (§8) `bookmarkData` **does not pin the cache entry** and
> `init?(resolvingBookmark:)` **returns `nil` rather than throwing**, so the failure lands in an
> `else` — and by design you already deleted the source file. (§9) Two code paths constructing
> *almost* the same `SpecializationOptions` each get their own multi-gigabyte cache entry and their
> own multi-minute stall, silently; the only mutable property has **no initializer that sets it**, so
> the value depends on how far down a function you got. §9.5 ships a build-phase check that makes the
> divergence impossible to reintroduce.
>
> 🔴 **GAP — nobody has shown Background Assets delivering a Core AI model (§3.2).** No Apple sample,
> no WWDC26 transcript, no documentation page in this corpus does it; session 326 names the framework
> in one sentence and refers you to a WWDC25 session, and Apple's `coreai` sample-code index returns
> **zero projects**. The only attested packaging CLI is `xcrun ba-package foundation-models`, which is
> adapter-specific and therefore dead in 27. The guide's answer is a seam: build against a delivery
> protocol you own, implement it with `URLSession`, swap in Background Assets later without touching
> any Core AI code. Also open here: the full authoritative `deviceArchitectureName` value set
> (community sources actively *disagree* about the M4 Max); the attached iPhone 15 Pro now anchors
> `iPhone16,1`/`D83AP` to `h16p`. The cache-deletion contradiction is device-resolved for iOS build
> `24A5408d`: deleting an in-use entry throws and succeeds after release. Two former unknowns
> were settled 2026-07-29 against the captured macOS 27.0 beta SDK interface: `AIModelError` (the
> `CoreAIDelegates.AIModelError error 3` breadcrumb) is confirmed **non-public** — the loading APIs
> throw untyped, so there is nothing to pattern-match — and the **absence** of any progress API for
> specialization and of any API to size or locate the Core AI cache is now SDK-confirmed, not just
> unindexed (§5.3, §6.4, §11.6). And a 2026-07-31 resolution: `coreai-build` is not part of the
> Xcode 27.0 beta app bundle and failed to resolve on the 2026-07-29 install because the optional
> **Metal Toolchain component was not installed** — its full `--help` is now captured, and probing it
> enumerated the 24 valid
> `--architecture` codes, though the code→*device* mapping (the M4 Max disagreement above) remains
> community-only (§4.2).

### [15.2 — Memory, jetsam, thermals, energy, and measuring honestly](references/02-memory-thermals-and-honest-benchmarking.md)

The gap between a demo that works on your desk and an app that survives a week on someone else's
phone. It has the highest crash-avoidance value in the series and almost none of it is about writing
better inference code. Four movements: the jetsam model and why your size arithmetic is wrong (§1–§3,
with three recorded device failures); living inside the budget — a hysteretic governor rather than a
threshold, a background unload policy, verified unloads, the MLX memory dials, and the unified-memory
hazard that **another framework's allocator can starve yours** (§4–§6); thermals and energy, the
sections most benchmarks omit (§7–§8); and a real methodology section built from measurement failures
other people paid for (§9–§10). Get the
`com.apple.developer.kernel.increased-memory-limit` entitlement in place before anything else — it is
called *mandatory* by a shipping app, enabled by **every** LLM sample in `mlx-swift-examples`, and it
is what resolved `apple/coreai-models` issue #112.

> ⚠️ **SILENT FAILURE — a successful load is not a fit test (§1.1, §3.2).** Loading establishes the
> weights; the first step additionally allocates activations, workspace and possibly a full-context KV
> cache. And the compute unit moves the answer by 2×: the *same* 1.8 GB core left ~2.8 GB of headroom
> on the ANE path and ~6.0 GB on the GPU path, with **no API that reports the difference**. Also here:
> mmap'd weights are free until inference touches them, at which point a broad logical overcommit
> "can launch but then OOM at large contexts" (§2.2); an allocator's reclaim path freed an `MTLBuffer`
> an in-flight command buffer still referenced, **only under pressure**, so it will never reproduce on
> your desk (§6.2); and `FoundationModels` exposes **no tokenizer**, so every third-party tok/s figure
> for Apple's model is a `utf8.count / 4` estimate at roughly **±20%** — a wider error bar than most
> of the runtime differences it gets quoted against (§9.8).
>
> ⚠️ **SILENT FAILURE — your build machine is a benchmark variable and nothing reports it (§9.5).**
> Same recipe, same wheels, different macOS on the *build* host: 2.2× slower, 2× the memory, exports
> cleanly, loads cleanly, produces correct tokens. Compounding it, conversion is **not
> byte-deterministic** — the same recipe run twice minutes apart produces differing bundles — so a
> stored hash is worthless as a reproducibility criterion. Benchmark the artifact you will ship, built
> on the machine you will ship from. §9.9 is the companion horror story: a comparison about to publish
> *"Core AI 80% vs MLX ~20%. Both numbers were meaningless"* — two independent harness bugs whose
> product was a plausible, flattering result.
>
> 🔴 **GAP — seven, collected in §11.** The most operationally important: **where the Core AI depth
> jetsam wall is** (real, measured, uncharacterised — cap generation length explicitly rather than
> running to EOS), **no quantitative memory model** for Core AI or ANE loads that would predict that
> 3.2 GB compute-unit delta, **no runtime API reporting the building toolchain** (inject a stamp into
> `Info.plist` yourself), and **two attested spellings for the MLX Swift buffer-cache dial** —
> `MLX.GPU.set(cacheLimit:)` in a shipping App Store app versus `Memory.cacheLimit` throughout
> `mlx-swift-examples` — resolvable with one `grep` in your resolved revision. The guide also flags,
> at the table rather than in a footnote, that the iPhone energy figures in §8.1 cite a report file
> **not present in the repository that cites it**; treat them as directional.

---

## Reading order

**If you have not yet run your model on a physical device, start with [15.2 §1–§3](references/02-memory-thermals-and-honest-benchmarking.md#1-the-jetsam-model).**
It is short, it is the highest-value hour in this part, and it may tell you your model does not fit —
which is cheaper to learn now than after you have built a delivery pipeline for it. Run §3.2's
minimum viable fit test (measure available memory before load, after load, **and after one generated
token**) before reading anything else.

**Then work [15.1](references/01-model-distribution-and-updates.md) front to back through §9.** §1–§3
decide your delivery architecture, §4–§5 decide whether you ship AOT variants at all and stop you
shipping a green build the device rejects, §6–§7 are first run and updates, and §8–§9 are the two
silent failures you cannot retrofit cheaply — both are structural, and both are far easier to design
around than to debug. Return to [15.2 §4–§6](references/02-memory-thermals-and-honest-benchmarking.md#4-responding-to-pressure)
when you wire up pressure handling.

**Deferrable.** [15.1 §10](references/01-model-distribution-and-updates.md#10-app-groups-sharing-one-specialization-across-targets) (app groups) until you
actually have an extension or widget sharing the model — but read §10.5 before you assume one can,
because Core AI models count against the extension's limit. [15.1 §11–§12](references/01-model-distribution-and-updates.md#11-storage-hygiene)
belong to the fortnight before submission, not to week one. [15.2 §7–§8](references/02-memory-thermals-and-honest-benchmarking.md#7-thermals-and-dvfs)
are deferrable *only* if your feature is one-shot; if it runs for minutes — transcription, an agent
loop, anything always-on — §7.3's sprint-versus-marathon inversion may reorder your backend choice
and belongs before you commit. [15.2 §9–§10](references/02-memory-thermals-and-honest-benchmarking.md#9-honest-benchmarking)
are deferrable until you quote a number to anyone, internally or externally — at which point they stop
being optional.

---

## What this part deliberately does not cover

- **Producing the `.aimodel`.** This part starts from a bundle that already exists and already runs:
  [Part 8](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/README.md), with the ANE-vs-GPU authoring rules in
  [Part 10](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-10-coreai-hardware-authoring-debugging/README.md).
- **Compression and quantization** — the other half of the size story, and usually the larger half.
  It is also the single biggest lever on every number in 15.2: [Part 9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md).
- **The Core AI runtime API itself** — `AIModel`, `InferenceFunction`, `NDArray`, states, the engine
  selection that decides whether `@Generable` works: [Part 7](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/README.md).
  **The instrument, the debug gauge and the Debugger in depth:**
  [Part 10](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-10-coreai-hardware-authoring-debugging/README.md); they appear here only as how you *see* a
  specialization event.
- **KV cache mechanics, prefix reuse and context management as a discipline** —
  [Part 3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/README.md) and [Part 7](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/README.md). 15.2
  cares only about the *bytes* those caches occupy.
- **MLX Swift package layout, concurrency and `ModelContainer`** — [Part 13](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/README.md).
  15.2 §5 covers only the memory-limit APIs and how to refcount them.
- **Model quality and evaluation** — [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md). 15.2 §9 is methodology for
  latency, throughput, memory and energy, and touches quality only where a quality-harness bug
  masqueraded as a runtime difference.
- **`SystemLanguageModel` itself**, which ships with the OS and has no distribution story at all —
  which is exactly why it is attractive and exactly why 15.1 §12 exists:
  [Part 2](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/README.md). **Choosing among the five `LanguageModel`
  conformers:** [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md). **Coming from an iOS 26 app or
  `coreai-torch` 0.4.x:** [Part 17](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/README.md).

---

## Sources for this part

**Apple documentation**, harvested 2026-07-27 via `sosumi.ai` plus the raw DocC JSON API: the
`coreai` framework page and the `aimodel` / `aimodelasset` / `aimodelcache` / `specializationoptions`
/ `computeunitkind` / `asseterror` references, plus the four articles on integrating models, managing
specialization and caching, compiling ahead of time, and the debug gauge — the update sequence, the
bookmark workflow and the cache-key rule are all quoted verbatim from these. **WWDC26 transcripts:**
sessions 324 *"Meet Core AI"* and 326 (Core AI app features), the latter supplying the >1 GB discovery
and the first-run screen. **Apple Developer Forums**, all quoted answers Apple-badged: **836810** (no
Required Device Capability, plus the Apple Designer's explanation of why), **829108** (adapters
discontinued; `ensureLocalAvailability`), **832910** (AFM 3 Core vs Core Advanced), **833575**
(extension memory limits), **836760** (the Siri-enablement symptom, confirmed a bug), **833666** (no
NPU priority entitlement), **824753** (the MPS "other allocations" report, unanswered). **Apple
shipping source:** `apple/coreai-models` — `ModelStructure.swift`, `ModelBundle.swift`, and the
`EngineOptions` / `KVCacheStrategy` memory dials. **Community sources, labelled as such at every point
of use and never presented as Apple figures:** a model-porting archive whose measurements are one
engineer on one M4 Max and one iPhone 17 Pro, on beta OSes, 2026-06-10 through 2026-07-23 (the arch
validation, the exit-0 finding, the DVFS runs, the jetsam failures, the macOS 26-vs-27 artifact A/B,
the harness post-mortem); a shipping App Store app with six inference backends behind one enum (the
two-gate launch check, the governor, the unload policy, the entitlements);
`mlx-swift-examples` and `mlx-swift-lm`; GitHub issues on `apple/coreai-models` (#5, #27, #55, #77,
#110, #112) and `ml-explore/mlx` (#3461/#3462, #3689); and community blog benchmarks. **Apple has
published essentially no performance figure for anything in this part** — not specialization time, not
specialized-asset size, not throughput, not energy — which is why every number above carries hardware,
OS build and date.
