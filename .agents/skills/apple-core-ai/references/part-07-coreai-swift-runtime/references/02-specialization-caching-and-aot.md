# Specialization, the model cache, and ahead-of-time compilation

**Part 7 · Core AI: the Swift runtime · Reference 02**

**Version floor: everything in this guide is 27.0 and only 27.0.** Core AI shipped as a brand-new
framework in the 27 cycle — **iOS 27.0 · iPadOS 27.0 · Mac Catalyst 27.0 · macOS 27.0 · tvOS 27.0 ·
visionOS 27.0 · watchOS 27.0**, every symbol flagged **Beta**. There is no 26.x back-deployment
story, no `@available(iOS 26, *)` fallback, and no Core AI release-notes page to diff against —
`/documentation/updates/coreai` returns **404**, and the word "Core AI" does not appear anywhere on
Apple's Updates hub. Build with **Xcode 27**, and install the **Metal Toolchain** separately (§15)
or your build will not compile at all. The command-line half of this guide — `xcrun coreai-build` —
runs on **macOS 27** hosts.

> ⚠️ **Core AI has zero Apple sample-code projects.** Verified this cycle: 0 `sampleCode` entries
> across all **312** indexed Core AI symbols. Unlike Foundation Models, there is no first-party
> compiling reference you can open in Xcode and read. The strongest evidence available is Apple's
> documentation prose, Apple's shipped repositories (`apple/coreai-models`, `apple/coreai-torch`,
> `apple/coreai-optimization`) including the agent skills Apple wrote for those repos, and the
> WWDC26 transcripts. Every claim below carries a marker saying which of those it came from, and
> where nobody has run the thing, this guide says so instead of guessing.

---

## What this covers

The single largest source of first-launch stalls, wedged loads and mysterious disk growth in a
Core AI app.

A `.aimodel` is **portable source**. It is not executable. Before it can run, Core AI must
**specialize** it — compile it for *this* device's hardware **and this OS version** — and that
process is expensive enough that Apple's own session says, in as many words, *"It is recommended
you avoid having model specialization occur within user interactive flows."* On a 3 GB model on an
iPhone that first load has been community-measured at **194 seconds**.

What follows:

- **What specialization actually does**, in the two phases Apple describes — and which one is the
  expensive one. This is the fact that makes everything else make sense.
- **The cache API**: `AIModelCache.default`, and `model(for:options:)` — which returns `nil` when
  nothing is cached and **never specializes**. That is the gating primitive for a "Preparing…"
  screen, and it is the most important three lines in the framework.
- **The cache key** — `(source asset, SpecializationOptions)` — and how varying options silently
  leaves you with two multi-gigabyte cache entries where you expected one.
- **`AIModel.specialize(contentsOf:options:cache:cachePolicy:)`**: specializing *without* loading,
  at a moment you choose. It controls **when**, not **how much**.
- **`AIModelCache.Policy`**: `.default` vs `.persistent`, the two purge conditions, and the one
  purge that no policy can prevent.
- **Deleting entries** — and the fact that Apple's reference page and Apple's article **give
  opposite answers** about what happens when you delete an entry a live `AIModel` is using. Both
  are quoted; the conflict is marked as an open gap with a device test that would settle it.
- **App groups**: `AIModelCache(appGroup:)` plus the entitlement, so an app and its extension
  don't each pay for the same specialization.
- **Bookmarks**: `bookmarkData` → persist → `AIModel(resolvingBookmark:)`. This is what lets you
  **delete the source `.aimodel`** and keep running. It also fails in three ways, and one of them
  is an OS update.
- **`SpecializationOptions`** in practice, including the real reason to reach for `.cpuOnly` and
  the undocumented `expectFrequentReshapes` flag, whose behaviour is entirely inferred and which
  has an incident-grade community failure attached to it.
- **Ahead-of-time compilation** with `xcrun coreai-build compile`: what it emits, how the
  per-architecture artifacts are matched at runtime with `AIModel.deviceArchitectureName`, the
  hardware gate that excludes every pre-A17-Pro iPhone, and the residual specialization that AOT
  does *not* remove.
- **Xcode integration**: `.aimodel` in Compile Sources, and the Metal Toolchain download whose
  absence fails your build with a missing-Metal-compiler error.
- **Numbers**, all attributed: Apple-published where Apple published them, community-measured
  where a person with a phone measured them, and clearly labelled as such.

## What this does *not* cover

- **The `AIModel` / `InferenceFunction` / `NDArray` API itself** — descriptors, views, ownership,
  `preferredStrides`. That is reference 01 of this part.
- **States and pipelined execution** — KV caches as Core AI states, `ComputeStream`, `AsyncValue`.
  Reference 03.
- **Producing the `.aimodel` in the first place** — `coreai-torch`, op coverage, custom Metal
  kernels. Part 8.
- **Compression** — quantization, palettization, which of the 35 `ScalarType` cases[^scalar-type-count] you can
  actually reach. Part 9.
- **The Core AI Debugger, the debug gauge and the Instruments template** in depth. Part 10. They
  appear here only where they are the way you *see* specialization happening.

## What you need

- **Xcode 27** and the **Metal Toolchain** component. Not optional — §15.
- A **real device** for anything you intend to trust. Specialization is per-hardware and per-OS;
  a Simulator number is not a number.
- An `.aimodel` to work with. Note that `.aimodel` is a **directory**, not a single file
  (✅ verified — `apple/coreai-models` treats it as one throughout, and its overwrite path calls
  `shutil.rmtree` on it), and so is `.aimodelc`.
- Reference 01 of this part, or at least the knowledge that `AIModel(contentsOf:)` is `async` and
  `AIModelAsset` exists.

---

## Contents

1. [What specialization actually is](#1-what-specialization-actually-is)
2. [The default path, and exactly where it stalls](#2-the-default-path-and-exactly-where-it-stalls)
3. [The cache, and the gating primitive](#3-the-cache-and-the-gating-primitive)
4. [The cache key, and how to double your disk usage by accident](#4-the-cache-key-and-how-to-double-your-disk-usage-by-accident)
5. [`AIModel.specialize` — controlling *when*, not *how much*](#5-aimodelspecialize--controlling-when-not-how-much)
6. [Cache policy and purge conditions](#6-cache-policy-and-purge-conditions)
7. [Deleting entries — and Apple's contradiction](#7-deleting-entries--and-apples-contradiction)
8. [Sharing a cache across an app group](#8-sharing-a-cache-across-an-app-group)
9. [Bookmarks: deleting the source and keeping the model](#9-bookmarks-deleting-the-source-and-keeping-the-model)
10. [`SpecializationOptions` in practice](#10-specializationoptions-in-practice)
11. [`expectFrequentReshapes`: the flag nobody documented](#11-expectfrequentreshapes-the-flag-nobody-documented)
12. [Dynamic shapes re-specialize — bucket them](#12-dynamic-shapes-re-specialize--bucket-them)
13. [Ahead-of-time compilation with `coreai-build`](#13-ahead-of-time-compilation-with-coreai-build)
14. [What AOT does not buy you](#14-what-aot-does-not-buy-you)
15. [Xcode integration: Compile Sources and the Metal Toolchain](#15-xcode-integration-compile-sources-and-the-metal-toolchain)
16. [The numbers, attributed](#16-the-numbers-attributed)
17. [A recovery ladder for wedged loads](#17-a-recovery-ladder-for-wedged-loads)
18. [Quick reference](#18-quick-reference)
19. [Sources and evidence ledger](#19-sources-and-evidence-ledger)

---

## 1. What specialization actually is

Start with the shape of the pipeline, because half the confusion in this area comes from people
using "compile" to mean three different things.

```
PyTorch model
  │
  ├─ coreai-torch ──────────────────────► MyModel.aimodel        portable source, any Apple device
  │                                        (a directory)
  │
  ├─ xcrun coreai-build compile ────────► MyModel.<arch>.aimodelc  per-architecture, AOT-compiled
  │   (optional, on your Mac)              (also a directory)
  │
  └─ on-device specialization ──────────► a cache entry in an AIModelCache
      (automatic, or explicit)             executable code for THIS device + THIS OS version
                                           │
                                           └─► AIModel → InferenceFunction → run(inputs:)
```

> ✅ **VERIFIED** — Apple, *Managing model specialization and caching*
> (`/documentation/coreai/managing-model-specialization-and-caching`), verbatim:
> *"When you load a `.aimodel` file with `AIModel`, Core AI performs **specialization**, the process
> of optimizing the model for the current device's hardware. The `.aimodel` file contains your model
> in a **portable format that works across Apple devices**. Before the model can run, Core AI
> specializes it for the current device, producing **executable code tied to that device's hardware
> and OS version**."*

Read that last clause twice. The artifact is tied to *hardware* **and** *OS version*. That single
sentence is the reason your users will pay the specialization cost again after every OS update, the
reason a saved bookmark can stop resolving, and the reason nothing you cache is permanent.

### The two phases

Apple describes specialization as two transformations, and tells you which one hurts.

> ✅ **VERIFIED** — WWDC26 session 324, *"Meet Core AI"*, verbatim:
> *"During specialization, the model goes through **two main transformations**.
> **First, it goes through a core set of compilation steps which segment, plan and optimize
> compute.**
> **Second, executable artifacts are generated for the compute units used. These artifacts are tied
> to the device and OS version they were generated on.**
> Of these two steps, **compilation is the one which incurs most of the latency**."*

Session 326 repeats it almost word for word — *"Of these two steps, compilation is the most
expensive and takes the most amount of time"* — so this is not one presenter's paraphrase.

| Phase | What it does | Cost | Can it move off-device? |
|---|---|---|---|
| **1 — Compilation** | Segment, plan and optimize compute | **Most of the latency** | **Yes** — `coreai-build`, §13 |
| **2 — Artifact generation** | Emit executable artifacts per compute unit, tied to device + OS version | The remainder | **No** — inherently per-device |

Everything in the rest of this guide is a consequence of that table:

- **You cannot eliminate phase 2.** That is why AOT compilation is a reduction, not a removal
  (§14), and why a 3 GB AOT-compiled asset can still take three minutes to load the first time.
- **You can move most of phase 1** to your build machine. That is `coreai-build` (§13).
- **You can move *when* phase 1 runs on device** without reducing it at all. That is
  `AIModel.specialize` (§5). Apple is explicit that these are different things, and it is the
  distinction most people get wrong first:

> ✅ **VERIFIED** — Apple, *Managing model specialization and caching*, verbatim:
> *"The `specialize` method **differs from ahead-of-time compilation**. With ahead-of-time
> compilation, most of the heavy computation happens on your Mac at build time, so on-device
> specialization finishes faster. With `specialize`, **the full specialization process runs on the
> person's device. You are controlling *when* specialization happens, not *reducing the work it
> does*.**"*

### Two names for two objects

The framework encodes the source/specialized distinction in the type system, and the two type
names are easy to confuse:

| Type | Apple's one-line abstract | Can run inference? |
|---|---|---|
| `AIModelAsset` | *"An unspecialized source model asset."* | **No** |
| `AIModel` | *"A specialized model for running inference on a device."* | Yes |

> ✅ **VERIFIED** — both abstracts quoted from the Core AI symbol index. `AIModelAsset`'s overview
> makes the motivation explicit: *"Use a model asset to inspect a model's structure and metadata
> without specializing it for a specific device. This lets you query model information without
> performing specialization, **which is an expensive operation**."*

That is a genuinely useful capability and it is under-used. If your app ships or downloads several
candidate models and wants to pick one — by function signature, by parameter count, by author
metadata — build `AIModelAsset`s and read `summary(includingStatistics:)`. Inspecting a hundred
assets is cheap; specializing a hundred models would be ruinous.

```swift prelude:guide-context
import CoreAI

// Cheap: reads metadata and function signatures. Never specializes.
let asset = try AIModelAsset(contentsOf: modelURL)
guard let summary = try asset.summary(includingStatistics: false) else {
    // No program bytecode in this asset.
    throw ModelError.notAModel(modelURL)
}
for function in summary.functions {
    print(function.name, function.inputs.map(\.name), function.states.map(\.name))
}
```

> ✅ **VERIFIED** — `AIModelAsset.init(contentsOf:) throws`,
> `func summary(includingStatistics: Bool) throws -> AIModelAsset.Summary?`, returning `nil`
> *"if no program bytecode exists"*. `includingStatistics` is documented as *"Including model
> statistics is considerably slower for large models"* — pass `false` when you only want function
> signatures.

Apple's own `apple/coreai-models` package does exactly this, and uses it to make a decision
*before* paying for specialization:

> ✅ **VERIFIED** — `swift/Sources/CoreAIShared/Runtime/ModelStructure.swift`, Apple's shipped
> Swift code. `probeStructure(at:)` builds an `AIModelAsset`, calls
> `summary(includingStatistics: false)`, reads the function names, and classifies the model — and
> only then calls `AIModel(contentsOf:options:)` with the `SpecializationOptions` that
> classification implies. The source comment is verbatim: *"Probe structure before specializing so
> we can pick the right compute-unit preference."*

That two-step — **probe cheaply, then specialize once, correctly** — is the single most reusable
pattern in this guide, and §10 shows it in full.

---

## 2. The default path, and exactly where it stalls

The happy path is three lines, and it hides the entire subject.

```swift illustrative
import CoreAI

let model = try await AIModel(contentsOf: modelURL)      // specializes if needed, caches the result
guard let function = try model.loadFunction(named: "main") else { … }
let outputs = try await function.run(inputs: ["input": input])
```

> ✅ **VERIFIED** — from Apple's *Integrating on-device AI models in your app with Core AI* article,
> including the default function name `"main"` and the fact that `loadFunction(named:)` *"throws on
> a load failure, and returns `nil` when no function with that name exists."*

Signature, exactly:

```swift illustrative
init(contentsOf modelURL: URL, options: SpecializationOptions = .default) async throws
```

> ✅ **VERIFIED** — `modelURL` is documented as *"The URL of a `.aimodel` **or `.aimodelc`** file"*,
> so the same initializer takes both the portable and the AOT-compiled asset. The discussion is
> verbatim: *"This initializer specializes the model if needed, caching the result for future calls.
> Specializing the model can take a significant amount of time depending on model size and the
> compute unit types it targets. **This initializer always uses the `default` cache.**"*

Two consequences of that last sentence that people trip over:

1. `AIModel(contentsOf:)` **cannot** be pointed at an app-group cache. If you want app-group
   sharing you must go through `AIModel.specialize(…, cache:)` or `cache.model(for:options:)` —
   §8.
2. The `async` on the initializer is not politeness. Apple: *"`init(contentsOf:options:)` is
   asynchronous **because specialization needs to complete before a valid `AIModel` is
   returned**."* There is no partial `AIModel`.

### The stall, as Apple demoed it

WWDC26 session 326 opens its specialization segment with a *failing* demo, which is unusually
honest and worth reproducing as the mental model:

> ✅ **VERIFIED** — WWDC26 session 326, *"Integrate on-device AI models into your app using Core
> AI"*, verbatim:
> *"I'll take a photo… and we're waiting. **The segmentation hasn't come back yet, so we can't get
> to card generation. Something is clearly slow here.** … **I took a trace with the new Core AI
> instruments, and sure enough there's a model load event right at that point, with a large
> sub-event for specialization.** … While future loads are from the cache and are fast, **that
> first time is something I need to plan for**. **Having that happen right in the middle of the
> user experience is... probably not great.**"*

And the recommendation, which is the headline of both Core AI sessions:

> ✅ **VERIFIED** — WWDC26 session 324, verbatim: *"**It is recommended you avoid having model
> specialization occur within user interactive flows.**"*

Session 326 goes one step further and rejects the two obvious workarounds before proposing a
third:

> ✅ **VERIFIED** — WWDC26 session 326, verbatim: *"**I could kick it off at launch or run it in the
> background but that feels wasteful if the user isn't even interested in this feature yet.** **I
> think a better idea is to create a dedicated first-run experience, where I can move this work to
> happen while the user is learning about the feature for the first time. This keeps model loading
> and specialization out of the interactive flow.**"*

So Apple's prescribed shape is **not** "warm it at launch". It is:

```
feature introduction screen  →  explicit opt-in button
      →  Background Assets download (with progress)
      →  specialize (with progress / explanatory copy)
      →  feature becomes available
```

The reason the download step is in there is a number worth remembering:

> ✅ **VERIFIED, Apple-published** — WWDC26 session 326: bundling the demo's models (SAM 3 plus a
> Qwen3 0.6B) added *"over 1 GB to my download size. **That hits everyone who updates, even people
> who'll never touch this feature.**"* Apple's answer in the session is Background Assets, and the
> AOT article repeats the recommendation for compiled assets: *"It's recommended to **host the
> compiled assets remotely and download the matching variant to the device at runtime**, because
> each device only uses one of them."*

### What the stall looks like in the tools

You do not have to guess whether you are paying specialization; three Apple tools will tell you,
and they disagree with each other in small ways that will confuse you if nobody warns you first.

> ✅ **VERIFIED** — Apple, *Monitoring model performance with the debug gauge* and *Analyzing model
> runtime performance with Instruments*:
>
> - The **Xcode Core AI debug gauge** shows **three** event types: **Inference** (blue), **Load**
>   (green), **Specialization** (orange). Specialization *"only appears for models that aren't
>   specialized ahead of time."*
> - The **Core AI Instruments template** shows **four** event categories: **Specialization**
>   (**green**), **Load** (**cyan**), **Setup** (magenta), **Inference** (blue).
>
> ⚠️ The colours for Load and Specialization are **swapped between the two tools**, and Instruments
> has a `Setup` category the gauge does not. Do not carry colour intuitions from one to the other.

> ✅ **VERIFIED** — Instruments article, verbatim: *"**Specialization events are often the most
> time-intensive operations during model runtime. Each model produces at most one Specialization
> event — none if the model is fully specialized for the device or already cached.**"* And on Load:
> *"**If you see frequent Load events during runtime, check that your app doesn't reload models
> repeatedly.**"*

Concrete event labels you will see in the timeline, from Apple's own screenshots: the specialize
event is labelled **`Compile Asset, Specialize`** with a nested **`Compile segment`** sub-event; a
load is **`Load model::main`**; a setup is **`Setup for model::main`** with a nested
**`Context.alloc`**. The naming convention is `model::function`.

> ⚠️ **Gotcha, verified** — the gauge's More menu (*Open in Core AI Debugger* / *Export to file*)
> *"aren't available for events recorded before the report was open."* **Open the gauge's report
> page before you trigger the load you want to investigate**, or you will capture the stall and be
> unable to inspect it.


---

## 3. The cache, and the gating primitive

`AIModelCache` is a `final class`. Here is its whole surface:

```swift illustrative
final class AIModelCache: Sendable, SendableMetatype {

    static let `default`: AIModelCache
    init?(appGroup groupIdentifier: String)

    final func model(for modelURL: URL, options: SpecializationOptions) throws -> AIModel?

    final func deleteEntry(for modelURL: URL, options: SpecializationOptions) throws
    final func deleteEntries(for modelURL: URL) throws
    final func deleteAll() throws
    static func deleteEntry(referencedBy bookmark: Data) throws
}
```

> ✅ **VERIFIED** — every member and signature quoted from the Core AI reference pages
> (`/documentation/coreai/aimodelcache` and its children). Note that `model(for:options:)` has **no
> default** for `options:` — Apple's own article always passes `options: .default` explicitly.

Apple's overview of what an entry *is*, verbatim, because it defines the cache key:

> ✅ **VERIFIED** — *"The cache holds the optimized, device-specific artifacts that `AIModel` loads
> to execute its inference functions. **Each cache entry contains a specialized asset formed from a
> specific `.aimodel` or `.aimodelc` and `SpecializationOptions` combination.**"*

### The one method that matters most

```swift illustrative
final func model(for modelURL: URL, options: SpecializationOptions) throws -> AIModel?
```

> ✅ **VERIFIED** — discussion, verbatim: *"If this cache holds a specialized asset from previously
> specializing the model at `modelURL` with the specified `options`, this method loads and returns
> the model. **This method never performs specialization.**"*

That sentence is the entire reason this method exists. It is a **synchronous, non-specializing
probe**: `nil` means "not cached, and I did not do the expensive thing to find out." It is how you
decide, in a fraction of a millisecond, whether to show a spinner or a three-minute progress
screen.

WWDC26 session 324 names it as the first of three levers:

> ✅ **VERIFIED** — session 324, verbatim: *"First, Core AI gives you **programmatic access to the
> default model cache for your app**. You can **request to load models directly from it**. If
> **nil is returned, it is not present and requires specialization**. You can use this to **gate
> features or inform the users that they may need to wait a bit while your app prepares the
> model**."*

Apple's article ships the canonical implementation. This is Apple's code, verbatim:

```swift illustrative
func loadModel(from modelURL: URL) async throws -> AIModel {
    // The default cache stores all specialized assets for your app bundle.
    let cache = AIModelCache.default

    // A non-`nil` result means the model was previously specialized and cached.
    if let model = try cache.model(for: modelURL, options: .default) {
        return model
    }

    // No cached specialization exists. Inform the person and specialize now.
    Task { @MainActor in
        informUser("Preparing AI features. This may take a while…")
    }

    // This call performs specialization, caches the result, and returns the model.
    return try await AIModel(contentsOf: modelURL, options: .default)
}
```

> ✅ **VERIFIED** — reproduced verbatim from
> `/documentation/coreai/managing-model-specialization-and-caching`.

Note the shape carefully: `model(for:options:)` is `throws` but **not** `async`, because it never
compiles anything. `AIModel(contentsOf:options:)` is `async throws`, because it might. The
asynchrony in this API is a reliable signal of where the cost is.

### A production-shaped version

Apple's snippet fires the UI update and then immediately blocks on specialization, which is fine
for an article and wrong for an app: you want the *caller* to be able to render a different screen,
not just a toast. Here is the same logic expressed as a readiness query plus an explicit prepare
step, which is what the first-run-experience recommendation in §2 actually needs.

```swift compile:27 imports:SwiftUI
import CoreAI
import Observation

@available(iOS 27.0, macOS 27.0, visionOS 27.0, tvOS 27.0, watchOS 27.0, *)
enum ModelReadiness: Equatable {
    case ready           // a cache entry exists; loading is fast
    case needsPreparing  // no cache entry; loading will specialize
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, tvOS 27.0, watchOS 27.0, *)
@Observable
final class ModelGate {

    private let modelURL: URL
    private let options: SpecializationOptions

    private(set) var readiness: ModelReadiness = .needsPreparing
    private(set) var isPreparing = false

    init(modelURL: URL, options: SpecializationOptions = .default) {
        self.modelURL = modelURL
        self.options = options
    }

    /// Synchronous, cheap, never specializes. Safe to call on every appearance of a view.
    func refreshReadiness() {
        // `model(for:)` returns nil when nothing is cached, and throws only when a cache
        // entry was found but its specialized asset failed to load. Either way we are
        // not ready, and the recovery path in §17 handles the throwing case.
        let cached = try? AIModelCache.default.model(for: modelURL, options: options)
        readiness = (cached != nil) ? .ready : .needsPreparing
    }

    /// Explicit, expensive, called behind explanatory UI. Does not return a model —
    /// it makes the *next* load fast.
    func prepare() async throws {
        isPreparing = true
        defer { isPreparing = false }
        try await AIModel.specialize(contentsOf: modelURL,
                                     options: options,
                                     cachePolicy: .persistent)
        refreshReadiness()
    }
}
```

Two notes on that code:

- `refreshReadiness()` discards the returned `AIModel`. That is deliberate and it is safe, but it
  is not free — see the pinning rule in §7. If you *want* the model, keep it; if you only want to
  know whether it exists, let it go immediately.
- `try?` swallows the throw. That is acceptable *here* precisely because the failure and the
  absence lead to the same UI state, and §17 has the recovery ladder. Swallowing a throw is not
  generally acceptable in this framework — see the ladder.

> ⚠️ **A malformed doc string you will meet.** `model(for:options:)`'s page carries an orphaned
> aside reading *"If a cache entry was found but the specialized asset failed to load."* — that is
> a truncated `- Throws:` clause rendered as a Note. The same malformation appears on
> `AIModel.init(contentsOf:options:)` and `AIModel.specialize(…)`, both reading *"If specializing
> or loading the model fails."* These are not behaviour statements; they are the *conditions* under
> which those calls throw.

> ✅ **RESOLVED (was a GAP) — they throw *untyped* errors, and no public error type for
> specialization, loading, inference or cache work exists in the macOS 27.0 beta SDK.**
> The SDK `.swiftinterface` dump was captured 2026-07-29 from Xcode build `27A5228h` and recaptured
> 2026-08-20 from beta 5 build `27A5237l` (`notes/sdk-interfaces/`). It shows: `AIModel.init(contentsOf:options:)` and
> `specialize(…)` are plain `async throws`, `loadFunction(named:)` and every `AIModelCache` method
> plain `throws` (✅ **SDK-verified** — `CoreAIDelegates-27.0-macos.swiftinterface:22-26, :33-43,
> :119-122`), and both `run` overloads plus `encode` untyped as well
> (`CoreAIRuntime-27.0-macos.swiftinterface:92-103`). The only public error type in the entire
> Core AI surface is `CoreAIAsset.AssetError`
> (✅ **SDK-verified** — `CoreAIAsset-27.0-macos.swiftinterface:230-247`), whose five `Kind` cases —
> `unsupportedVersion(String)`, `invalidFeatureType(String)`, `corruptedMetadata`, `invalidName`,
> `duplicateName` — cover **asset** operations only; it is publicly initializable, a reporting
> type, not the system's inference error.
> **What this means in practice:** catch `AssetError` explicitly where you are doing asset work,
> then catch the general `Error` — there is no typed `catch` to write for specialization or
> inference failures in this beta, and do log `(error as NSError).domain` and `.code` so your
> crash reports are useful. Community bug reports in this corpus show at least two shapes
> escaping: `CoreAIDelegates.AIModelError error 3` (an `AIModelError` exists internally but is
> **not present in the beta SDK's public interface**) and an `NSPOSIXErrorDomain Code=2` — the
> errors are **not** all one type. Full treatment: guide 7.1 §13.

---

## 4. The cache key, and how to double your disk usage by accident

The cache key is the pair `(source asset, SpecializationOptions)`. Both halves are load-bearing.

> ✅ **VERIFIED** — `AIModelCache` overview: *"Each cache entry contains a specialized asset formed
> from a specific `.aimodel` or `.aimodelc` and `SpecializationOptions` combination."*
> `SpecializationOptions` is declared `Equatable, Hashable, Sendable, SendableMetatype` — it is
> *designed* to be a key.
> Corroborated by `deleteEntries(for:)`'s discussion, verbatim: *"A model may have multiple entries
> in the cache. For example, one with `cpuOnly` and another with `default`. This method deletes all
> of them."*

So this code, which looks like it loads one model twice, actually specializes twice and stores two
separate multi-gigabyte artifacts:

```swift prelude:guide-context
// ⚠️ Two cache entries. Two specializations. Two copies on disk.
let a = try await AIModel(contentsOf: url)                      // options == .default
let b = try await AIModel(contentsOf: url, options: .cpuOnly)   // a different key entirely
```

Nothing warns you. There is no diagnostic, no log line, no thrown error. The only symptoms are a
second three-minute stall and storage that grows faster than your model files explain.

> ⚠️ **SILENT FAILURE — options drift duplicates the cache.**
> `SpecializationOptions` is part of the cache key, and it is a `struct` with a mutable
> `expectFrequentReshapes` property, so it is *easy* to construct slightly different options in two
> code paths without noticing. A helper that computes options from the model's folder name, a debug
> build that pins `.cpuOnly`, a feature flag that flips `expectFrequentReshapes` — each produces a
> **separate specialization and a separate multi-GB entry**, with no error, no warning, and a
> first-load stall that reappears after you were sure you had already paid it.
>
> **The fix is structural, not defensive:** compute the options for a given model **exactly once**,
> in one function, and pass that value everywhere — to `model(for:options:)`, to
> `AIModel(contentsOf:options:)`, and to `specialize(…)`. If those three call sites can disagree,
> they eventually will.
>
> A shipping community iOS app ([frozen Noema research note](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md),
> community-authored — attribute as such) encodes
> exactly this lesson in a comment on its recovery path: *"each `SpecializationOptions` change
> leaves its own multi-GB entry behind."*

The single-source-of-truth shape:

```swift compile:27 imports:Foundation,CoreAI
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
enum ModelSpecialization {

    /// The ONE place that decides how a given model is specialized.
    /// Every cache probe, load and pre-specialize call must route through this.
    static func options(for modelURL: URL) -> SpecializationOptions {
        // See §10 for what belongs in here. The point of this function is that
        // it exists and that nothing else constructs SpecializationOptions.
        .default
    }

    static func cachedModel(at modelURL: URL) throws -> AIModel? {
        try AIModelCache.default.model(for: modelURL, options: options(for: modelURL))
    }

    static func load(at modelURL: URL) async throws -> AIModel {
        try await AIModel(contentsOf: modelURL, options: options(for: modelURL))
    }
}
```

### The other half of the key: the source URL

The key is the *source asset*, not the specialized artifact. Apple states the consequence directly,
and it is the fact that makes §9 necessary:

> ✅ **VERIFIED** — *Managing model specialization and caching*, verbatim: *"The unspecialized
> `.aimodel` file, **along with the `SpecializationOptions` you pass**, is what Core AI uses to
> index and retrieve the cached specialization at runtime when you call `init(contentsOf:options:)`
> or `model(for:options:)`. Because of this, **you can't simply delete the source file and expect
> those APIs to keep working.**"*

Which raises the obvious question — you downloaded a 3 GB `.aimodel`, you specialized it into
another multi-gigabyte artifact, and now you are holding both. §9 is how you stop doing that.

---

## 5. `AIModel.specialize` — controlling *when*, not *how much*

```swift illustrative
@discardableResult
static func specialize(contentsOf modelURL: URL,
                       options: SpecializationOptions = .default,
                       cache: AIModelCache = .default,
                       cachePolicy: AIModelCache.Policy = .default) async throws -> AIModel
```

> ✅ **VERIFIED** — full signature and the `@discardableResult` attribute quoted from
> `/documentation/coreai/aimodel/specialize(contentsof:options:cache:cachepolicy:)`.

This is lever two. It does exactly what `AIModel(contentsOf:options:)` does, with three
differences that all matter:

1. It is `static` and `@discardableResult` — you can call it purely for its side effect, which is
   *"the cache now contains an entry for this (asset, options) pair."*
2. It takes a **`cache:`** parameter. This is the only way to specialize into an **app-group**
   cache (§8); the initializer *"always uses the `default` cache."*
3. It takes a **`cachePolicy:`** parameter. This is the only way to create an entry with
   `.persistent` retention (§6). The initializer gives you `.default` retention and no say in it.

Apple's article, verbatim:

```swift prelude:guide-context
guard let localModelURL = try await downloadModel(forFeature: feature) else {
    throw AppError.failedToDownloadModel(feature)
}

// Specialize the model so it's ready before the person needs it.
try await AIModel.specialize(contentsOf: localModelURL, options: .default)

// The model is now specialized and cached. Future loads skip specialization.
let model = try await AIModel(contentsOf: localModelURL, options: .default)
```

> ✅ **VERIFIED** — verbatim from the article, including the `NOTE`: *"Calling `specialize` multiple
> times with the same model URL and options returns the cached result without repeating the
> specialization process."* So it is idempotent and cheap to call again — which means you can put
> it behind a retry button without special-casing "already done".

And session 324's framing of when to call it:

> ✅ **VERIFIED** — session 324, verbatim: *"Second, you can **request model specialization
> explicitly in your app independent of it being loaded**. You can do this **after downloading
> assets or when the user opts in to a feature** so the model is ready to go ahead of time."*

### The distinction you must not blur

It is worth restating the sentence from §1 in this context, because `specialize` is the API people
reach for when they mean AOT:

> ✅ **VERIFIED** — *"With `specialize`, **the full specialization process runs on the person's
> device. You are controlling *when* specialization happens, not *reducing the work it does*.**"*

| | Where phase-1 compilation runs | Total device work | Requires | Reduces first-load time? |
|---|---|---|---|---|
| `AIModel(contentsOf:)` | Device, lazily, at load | 100% | nothing | No — it *is* the stall |
| `AIModel.specialize(…)` | Device, eagerly, when you say | 100% | nothing | No — it **moves** it |
| `coreai-build compile` (§13) | **Your Mac**, at build time | Much less | Metal Toolchain, A17 Pro+ target | **Yes** |

The two are complementary, not alternatives. Apple's own demo does both: it ships AOT-compiled
`.aimodelc` assets *and* moves the residual specialization into a first-run experience. The
community-measured numbers in §16 show why — even a fully AOT-compiled 3 GB asset took **194
seconds** to load the first time on an iPhone 17 Pro.

### Where to actually call it

The prescribed shape from §2, wired up:

```swift illustrative
import BackgroundAssets   // Apple's recommended delivery mechanism for model assets
import CoreAI

@available(iOS 27.0, macOS 27.0, *)
func enableFeature(_ feature: Feature, progress: @MainActor (Double, String) -> Void) async throws {

    // 1. The user pressed an explicit opt-in button on a feature-introduction screen.
    await progress(0.0, "Downloading model…")
    let modelURL = try await downloadModelAsset(for: feature)   // Background Assets

    // 2. Specialize now, behind explanatory UI, with the model NOT yet loaded.
    await progress(0.5, "Preparing the model for this device. This happens once.")
    try await AIModel.specialize(
        contentsOf: modelURL,
        options: ModelSpecialization.options(for: modelURL),   // §4: one source of truth
        cachePolicy: .persistent                               // §6: survive storage pressure
    )

    // 3. From here on, every load is a cache hit.
    await progress(1.0, "Ready.")
    featureStore.markEnabled(feature, modelURL: modelURL)
}
```

> 🟡 **RECONSTRUCTED** — the *structure* here (opt-in → Background Assets download → specialize →
> mark ready) is Apple's, from session 326 and the AOT article, both of which name Background
> Assets explicitly. The specific function names in this snippet (`downloadModelAsset`,
> `featureStore`) are illustrative app code, not API. Only the `AIModel.specialize(…)` call and its
> argument labels are verified API.

> ⚠️ **There is no progress reporting.** `AIModel.specialize` and `AIModel.init(contentsOf:)` are
> plain `async throws` calls that return when they are done. There is no `Progress` object, no
> `AsyncSequence` of stages, and no cancellation contract documented. Your "Preparing…" UI is
> necessarily indeterminate. Design the copy accordingly — *"This happens once, and can take a few
> minutes for large models"* is honest; a progress bar that sits at 50% for three minutes is not.
>
> 🟡 **INCONCLUSIVE PROBE, updated 2026-09-16:** cancellation remains undocumented. On both the
> stable Mac and iPhone 15 Pro, the test reported `completed` after about 10 seconds and a cache
> entry remained. The fixture completed before cancellation could establish whether useful work
> stops. A larger model that remains in flight after the cancellation request is still required.
> **Safe default meanwhile:** treat specialization as uncancellable. Do not tie it to a view's
> lifetime, do not start it in `.task { }` on a screen the user can swipe away, and if the user
> backs out, let it finish — the entry it produces is exactly what you want next time.

---

## 6. Cache policy and purge conditions

```swift illustrative
struct AIModelCache.Policy: Codable, Equatable, Hashable, Sendable, SendableMetatype {
    static let `default`: AIModelCache.Policy
    static let persistent: AIModelCache.Policy
    init(purgeConditions: AIModelCache.Policy.PurgeConditions)
    var purgeConditions: AIModelCache.Policy.PurgeConditions   // settable, per the SDK interface
}

struct AIModelCache.Policy.PurgeConditions: OptionSet, SetAlgebra, Codable, Sendable {
    let rawValue: UInt
    init(rawValue: UInt)
    static let sourceAssetChangedOrDeleted: PurgeConditions
    static let storagePressure: PurgeConditions
}
```

> ✅ **VERIFIED** — both types and all members quoted from the reference pages, and confirmed
> against the SDK (✅ **SDK-verified** — `CoreAIDelegates-27.0-macos.swiftinterface:44-71`). One
> doc discrepancy: the reference page shows `purgeConditions` as `{ get }`, but the beta interface
> declares it a settable `public var`.

There are exactly **three** ways a cached specialization can go away. Apple lists them as a term
list in the article:

> ✅ **VERIFIED** — *Managing model specialization and caching*, verbatim:
> - **OS update** — *"Specialized assets are tied to the OS version. **The system always invalidates
>   assets on OS update, regardless of policy.**"*
> - **Source model change** — *"If the source `.aimodel` file is modified or deleted, cached assets
>   derived from it become invalid."*
> - **Storage pressure** — *"The system can reclaim space by deleting assets marked as purgeable."*

The two `PurgeConditions` flags control the second and third. **Nothing** controls the first.

> ✅ **VERIFIED** — `Policy`'s overview NOTE, verbatim: *"**Regardless of policy, the system always
> purges assets when the OS updates**, as specialized assets are OS-version specific."*
> Repeated on `PurgeConditions`: *"The system always purges assets on OS update regardless of these
> conditions."*

The two shipped policies:

| Policy | Apple's description (verbatim) |
|---|---|
| `.default` | *"The default policy marks a specialized asset as purgeable. The system can delete it when low on storage or when its source `.aimodel` changes or you delete it."* |
| `.persistent` | *"This policy ensures the system does not purge specialized assets **until the next OS update**. You can manually delete them, but the system does not automatically purge them under low storage or when the source `.aimodel` changes."* |

> 🟡 **RECONSTRUCTED** — the obvious reading is that
> `.default == Policy(purgeConditions: [.sourceAssetChangedOrDeleted, .storagePressure])` and
> `.persistent == Policy(purgeConditions: [])`. Apple never states the raw values, and the prose
> descriptions imply exactly this mapping, but nothing in the docs confirms it and no one in this
> corpus has printed them. Do not *rely* on the identity — use `.default` and `.persistent` by name.
> If you need a middle ground (say, purge under storage pressure but survive a source-file rewrite),
> `Policy(purgeConditions: [.storagePressure])` is the constructible form and is a reasonable thing
> to try; measure that it behaves as you expect before shipping it.

### When to use `.persistent`

Apple names one case explicitly, and it is the one that matters:

> ✅ **VERIFIED** — *"If your app deletes the source model file to save storage, use the
> `.persistent` policy to keep the cached assets available across launches"*, followed by:
> ```swift
> try await AIModel.specialize(
>     contentsOf: modelURL,
>     options: .default,
>     cachePolicy: .persistent
> )
> ```

The reasoning chains cleanly: if you delete the source `.aimodel` (§9), then under `.default` the
`sourceAssetChangedOrDeleted` condition is satisfied, and the system is now permitted to throw
away the specialized artifact you just paid three minutes for. `.persistent` removes that
permission.

Beyond that, `.persistent` is the right default for anything **expensive and hard to replace**:

- A model the user explicitly opted into and waited for. Re-paying a 194-second stall because the
  device got briefly tight on storage is a terrible experience.
- A model you downloaded over the network — re-specializing is only half the cost; you may also
  need to re-download.

And it is the wrong choice for anything **cheap or speculative**: a small classifier bundled in the
app, a model you specialized "just in case". `.persistent` means *you* are now responsible for
storage management, because the system will not reclaim it for you.

> ⚠️ **`.persistent` does not mean permanent.** It means "until the next OS update." Every user who
> takes an iOS point release loses every specialized asset in your app, `.persistent` or not, and
> the next launch pays for all of them again. Plan the re-specialization UX, not just the first-run
> one — §17.

### Making the OS-update invalidation visible

Because the invalidation is silent and unavoidable, the useful defensive move is to *notice* it
before the user does. `model(for:options:)` is cheap enough to call on launch:

```swift prelude:guide-context
@available(iOS 27.0, macOS 27.0, *)
func modelsNeedingPreparation(_ installed: [URL]) -> [URL] {
    installed.filter { url in
        let options = ModelSpecialization.options(for: url)
        return (try? AIModelCache.default.model(for: url, options: options)) == nil
    }
}
```

If that returns a non-empty array on a launch where it returned empty last time, an OS update (or
a storage purge) happened. That is your cue to show the "preparing" state proactively rather than
letting the user discover it by tapping the feature.

> 🟡 **DEVICE-MEASURED ONCE — the API gap remains.** Apple still exposes **no** API for the
> on-disk size of a cache or an entry, **no** documented location for `AIModelCache.default`'s
> storage, and **no** way to enumerate entries. `deleteAll()` is the only bulk operation. On an
> iPhone 15 Pro (`iPhone16,1`) running iOS 27 beta build `24A5408d`, specializing a deliberately
> tiny 12,288-byte portable model grew `Library/Caches` by 24,576 bytes, left
> `Library/Application Support` unchanged, and created `Library/Caches/coreai-cache`. That is one
> beta/device/model observation, not a storage contract or a general 2× ratio.
> The 2026-09-16 stable-Mac and iOS build `24A435` lanes reproduced the 12,288 → 24,576-byte
> observation, but it remains fixture-specific rather than a sizing formula.
> **Safe default:** treat cache size as *approximately the size of the specialized
> artifact*, which community measurements put in the same order of magnitude as the source asset —
> a 1.9 GB `.aimodelc` and a 3 GB `.aimodelc` both appear in the corpus with device-side load
> footprints of the same scale. Budget as if each `(asset, options)` pair costs you a second copy
> of the model, and use `deleteEntries(for:)` aggressively when you retire a model.

---

## 7. Deleting entries — and Apple's contradiction

Four deletion APIs, at three granularities plus one by-bookmark:

```swift illustrative
final func deleteEntry(for modelURL: URL, options: SpecializationOptions) throws
final func deleteEntries(for modelURL: URL) throws
final func deleteAll() throws
static func deleteEntry(referencedBy bookmark: Data) throws
```

> ✅ **VERIFIED** — Apple's own summary term list, verbatim:
> - `deleteEntries(for:)` — *"Ignores any `SpecializationOptions` and deletes all cache entries for
>   a specific `.aimodel`."*
> - `deleteEntry(for:options:)` — *"Deletes a single cache entry for a specific `.aimodel` and
>   `SpecializationOptions` combination."*
> - `deleteAll()` — *"Deletes all entries in the entire cache."* Discussion: *"Use this method to
>   reclaim storage when the app no longer needs any of its specialized models, or to reset the
>   cache during testing."*
> - `deleteEntry(referencedBy:)` — *"Because bookmark data encodes both the specific cache instance
>   and the entry within it, **this method is static and requires no cache instance to call**."*

**`deleteEntries(for:)` is the one you want** almost every time, precisely because of §4: you
rarely know for certain which options produced entries, and this one ignores options and takes them
all. Apple's model-update example uses it:

```swift prelude:guide-context
func downloadAndUpdateModel(from remoteURL: URL, localModelURL: URL) async throws {
    let tempURL = try await downloadLatestModel(from: remoteURL)

    // Delete cached assets for the old model.
    let cache = AIModelCache.default
    try cache.deleteEntries(for: localModelURL)

    // Replace the old model with the new one.
    try FileManager.default.replaceItemAt(localModelURL, withItemAt: tempURL)

    // Specialize the updated model.
    try await AIModel.specialize(
        contentsOf: localModelURL,
        options: .default,
        cachePolicy: .persistent
    )
}
```

> ✅ **VERIFIED** — verbatim from *Managing model specialization and caching*.

Note the ordering: **delete, then replace, then specialize.** Deleting after replacing would work
too (the entry is keyed on the source URL, which doesn't change), but deleting first means that if
the replace fails you are left with no stale specialization pointing at a file you did not finish
writing.

### ⚠️ The contradiction

Apple's reference pages and Apple's article give **opposite answers** to the same question: what
happens when you delete an entry that a live `AIModel` is still using?

> ✅ **VERIFIED — the reference pages.** This NOTE is repeated on **all four** delete APIs,
> verbatim: *"For each entry, if no `AIModel` instance currently references it, deletion happens
> immediately. **Otherwise, an error is thrown.** Deletion can only occur for an entry when the last
> `AIModel` releases it."*

> ✅ **VERIFIED — the article.** *Managing model specialization and caching*, verbatim: *"If an
> `AIModel` instance still uses a cache entry, **Core AI defers deletion until that instance is
> deallocated.**"*

Those cannot both be true. On the tested beta, the runtime breaks the tie in favor of the reference
pages:

> ✅ **RESOLVED ON DEVICE FOR BUILD `24A5408d`, reverified 2026-09-16 on Mac and iOS build `24A435`.** A probe specialized and loaded a toy model,
> retained the live `AIModel`, and called `deleteEntries(for:)`. The call threw
> `AIModelCacheError.failedToPurge("Deletion could not be completed, assets still in use")`; the
> entry remained findable. After releasing the model, the same delete succeeded. The observed
> dynamic error name is useful for diagnostics, but `AIModelCacheError` is not declared in the
> public beta Swift interface, so production code cannot match it as a public typed error.
>
> **Production rule:**
> 1. **Release every `AIModel` for that asset before deleting.** Scope them, `nil` them, or drop the
>    owning object.
> 2. **Wrap the delete in `do/catch` and treat a still-referenced throw as non-fatal.** The public
>    SDK exposes only an untyped `throws`, so do not depend on the private dynamic type name.
> 3. **Re-probe with `model(for:options:)` afterwards** instead of assuming the delete took effect.
>
> ```swift
> @available(iOS 27.0, macOS 27.0, *)
> func retireModel(at url: URL, holder: inout AIModel?) -> Bool {
>     holder = nil                                  // 1. drop the live reference first
>     do {
>         try AIModelCache.default.deleteEntries(for: url)   // 2. tolerate a throw
>     } catch {
>         log.warning("cache delete threw; an AIModel may still pin the entry: \(error)")
>     }
>     // 3. verify rather than assume
>     let options = ModelSpecialization.options(for: url)
>     return (try? AIModelCache.default.model(for: url, options: options)) == nil
> }
> ```
> Step 3 catches a second live reference and protects the code if a later beta changes behavior.

### The pinning rule that underlies both readings

Both readings agree on the *mechanism*, which is worth stating plainly because it also governs
bookmarks:

> ✅ **VERIFIED** — `AIModel.bookmarkData`'s NOTE, verbatim: *"Bookmark data is just data. It does
> not pin entries in the cache. **Only a `AIModel` will pin its associated entry in the cache while
> it is held.**"*

So: a live `AIModel` **pins** its cache entry. A `Data` bookmark does not. A URL does not. If you
want to guarantee an entry survives the next storage-pressure sweep for the duration of a screen,
the way to do it is to *hold the `AIModel`* — which is cheap, because:

> ✅ **VERIFIED** — `AIModel` overview NOTE: *"The model instance is lightweight and doesn't own
> weights or intermediate buffers. Those resources belong to the functions you load from it."*

That is a genuinely useful asymmetry: holding an `AIModel` pins the cache entry but costs almost
no memory; holding an `InferenceFunction` is what costs memory. If you have a screen that will
need the model soon, load the `AIModel` early and defer `loadFunction(named:)` until you actually
need to run.

### 7.1 How Apple's own tools clear the cache — and the measurement pattern worth stealing

✅ **VERIFIED — source read 2026-08-02.** `apple/coreai-models` commit `aa3bbf6`, *"Add
`--clear-coreai-cache` flag to clear Core AI specialization cache before model load (#127)"*,
2026-07-29. The flag was added to **six** of the repo's runner tools at once — `benchmark`,
`speech-runner`, `diffusion-runner`, `image-segmenter`, `llm-runner`, and `object-detector` — which
is itself the signal: Apple's sample tooling treats "clear the specialization cache before loading"
as a standard operating mode, not a debugging afterthought.

The benchmark tool's sequence is the part worth copying
(`swift/Sources/Tools/benchmark/BenchmarkMain.swift:70-78`):

```swift illustrative
// 🟡 Abridged from apple/coreai-models @ aa3bbf6 — the ordering is the point.
if clearCoreAICache {
    let cleared = try PreparedModel.clearCache(at: bundle.bundlePath)
    print("\n🗑️  Cleared specialization cache for \(bundle.name) (\(cleared.count) component(s))")
}

// Detect an existing cached specialization before loading so we can annotate the load
// time below. This only inspects the cache; it never triggers specialization.
let cacheHit = PreparedModel.isCached(at: modelURL)
```

Three things to take from it:

1. **`clearCache(at:)` returns the asset URLs it discovered and processed**, and the tool prints
   that count. The implementation computes `modelAssetURLs(at:)`, calls
   `AIModelCache.default.deleteEntries(for:)` for each resolved URL, and returns the original URL
   array. The count therefore does **not** prove that those cache entries existed or that that many
   entries were removed. Probe cache state separately if the distinction matters.
2. **`isCached(at:)` is a pure query.** The comment says so explicitly: *"This only inspects the
   cache; it never triggers specialization."* That is the gating primitive §3 is about, in its
   read-only form, and it is the honest way to label a timing number as cold or warm.
3. ⭐ **The tool's pattern is `clear → post-clear probe → load → attribute`**, and it is useful
   for establishing that the timed load begins uncached. If you also need to measure whether a clear
   changed anything, use `pre-clear probe → clear → post-clear probe → load`; the returned URL count
   cannot substitute for the pre-clear observation. Part 15's benchmarking guide argues for this
   explicit state attribution rather than inferring coldness from a helper's return value.

> ⚠️ **`PreparedModel.clearCache(at:)` is `coreai-models` API, not `CoreAI` framework API.** It is a
> helper in Apple's open-source sample package, keyed on a **bundle path**, and it is not one of
> the four `AIModelCache` deletion methods documented above. Do not reach for it in app code
> expecting a framework guarantee — use `AIModelCache.default.deleteEntries(for:)`. The value of
> the flag is as evidence of *how Apple measures*, and as a ready-made escape hatch if you are
> already building on `coreai-models`.
>
> 🔴 **GAP — this does not settle the deletion contradiction below.** The tools clear the cache
> *before* any `AIModel` exists, so they never exercise the disputed case: deleting an entry that a
> live `AIModel` is pinning. `NEEDED-FROM-A-MACOS-27-MACHINE.md` item 7 stands.

---

## 8. Sharing a cache across an app group

If your app and its extensions — a Share extension, a widget, a Siri intent handler, a second app
from the same team — all use the same model, the default cache makes each of them specialize it
separately. `AIModelCache(appGroup:)` fixes that.

```swift illustrative
init?(appGroup groupIdentifier: String)
```

> ✅ **VERIFIED** — parameter documentation, verbatim: *"A string that names the group whose shared
> cache you want to obtain. **This input should exactly match one of the strings in the app's App
> Groups Entitlement.**"*
> Return: *"The shared app group cache, or `nil` when the group identifier is invalid (**on iOS**),
> the app group container cannot be accessed, or entitlement checks fail."*
> Discussion: *"Use this initializer when multiple apps within an app group need to share a cache
> for their specialized assets. **This allows all apps within an app group to avoid each performing
> their own specialization for a shared model.**"*
> Entitlement: **`com.apple.security.application-groups`**.

Apple's two snippets, verbatim — the writer:

```swift prelude:guide-context
// Get the app group cache.
guard let groupCache = AIModelCache(appGroup: groupIdentifier) else {
    fatalError("Invalid group identifier or entitlement.")
    return
}

// Specialize into the shared cache.
try await AIModel.specialize(
    contentsOf: sharedModelURL,
    options: .default,
    cache: groupCache,
    cachePolicy: .persistent
)
```

and the reader:

```swift prelude:guide-context
guard let groupCache = AIModelCache(appGroup: groupIdentifier) else {
    return
}

if let model = try groupCache.model(for: sharedModelURL, options: .default) {
    // Use the model. No specialization needed.
}
```

> ✅ **VERIFIED** — both reproduced verbatim from the article. (Apple's first snippet has an
> unreachable `return` after `fatalError()`; that is a doc artefact, not API. Do not ship
> `fatalError` here — see below.)

### Four things to get right

**1. The model file must be in the shared container too.** The cache key is `(source asset URL,
options)`. If your extension resolves the model to a *different* URL than the app did — because
each has its own sandbox — you get a cache miss and a second specialization, defeating the entire
point. Put the `.aimodel` in the app-group container and resolve it the same way from both
processes:

```swift prelude:guide-context
@available(iOS 27.0, macOS 27.0, *)
enum SharedModel {
    static let groupID = "group.com.example.myapp"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    static var modelURL: URL? {
        containerURL?.appending(path: "Models/MyModel.aimodel")
    }

    static var cache: AIModelCache? {
        AIModelCache(appGroup: groupID)
    }
}
```

> 🟡 **RECONSTRUCTED** — `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` is
> long-standing Foundation API, not Core AI, and predates this release; the *pattern* of pairing it
> with `AIModelCache(appGroup:)` is the obvious consequence of the cache key being a URL, but Apple
> does not spell it out. Verify on device that both processes see the same path before you rely on
> the sharing.

**2. `AIModel(contentsOf:)` will not use the group cache.** The initializer *"always uses the
`default` cache"* (verified, §2). In an app-group design, every specialization must go through
`AIModel.specialize(…, cache: groupCache, …)` and every load through
`groupCache.model(for:options:)`. There is no `AIModel` initializer that takes a cache.

> 🔴 **GAP — how do you *load* from a group cache when the entry does not exist yet?**
> `groupCache.model(for:options:)` returns `nil` and never specializes; `AIModel(contentsOf:)`
> ignores the group cache. The composition that must therefore work is: call
> `AIModel.specialize(contentsOf:options:cache:cachePolicy:)`, which is `@discardableResult` and
> returns an `AIModel` — so *that* returned model is presumably backed by the group entry. Apple
> never demonstrates using the return value of `specialize` in the app-group snippet; it always
> re-reads via `groupCache.model(for:)`.
> **What would resolve it:** a device test asserting that the `AIModel` returned by
> `specialize(…, cache: groupCache, …)` and the one returned by
> `groupCache.model(for:options:)` reference the same entry (compare `bookmarkData`).
> **Narrowed 2026-08-20:** the equivalent test on `AIModelCache.default` produced identical
> 181-byte bookmarks for the returned and re-read models on the iPhone 15 Pro. The app-group
> variant remains open because it needs an entitled host target.
> **Safe default meanwhile:** use the two-step Apple demonstrates — `specialize(…, cache:)` for its
> side effect, then `groupCache.model(for:options:)` to obtain the model you actually use. It is
> one extra cheap call and it is the composition Apple's own examples show.

**3. Do not `fatalError` on the `nil`.** Apple's snippet does, and Apple's snippets are teaching
tools. `init?(appGroup:)` returns `nil` for at least three distinct reasons — bad identifier,
inaccessible container, failed entitlement check — and at least one of them (container access) can
be a transient condition on a locked device. Degrade to the default cache instead:

```swift prelude:guide-context
@available(iOS 27.0, macOS 27.0, *)
func cacheForSharedModel() -> AIModelCache {
    guard let group = AIModelCache(appGroup: SharedModel.groupID) else {
        // Entitlement missing, identifier wrong, or the container is unavailable right now.
        // Falling back means we pay for our own specialization — correct, just not shared.
        log.warning("App group cache unavailable; using the default cache.")
        return .default
    }
    return group
}
```

That fallback is honest: you lose the *sharing*, not the *feature*. But note the consequence — the
fallback specializes into a **different cache**, so the first fallback run pays full price and
leaves an entry in the app's private cache that the group will never see. Log it.

**4. The `(on iOS)` qualifier is a real signal.** Apple qualifies only the invalid-identifier case
with *"(on iOS)"*, which implies the failure modes differ by platform. Do not assume macOS returns
`nil` for the same inputs iOS does. Test on both if you ship on both.

---

## 9. Bookmarks: deleting the source and keeping the model

Here is the problem this API exists to solve. You download a 3 GB `.aimodel`. Core AI specializes
it into a comparably large artifact in the cache. You are now holding **two** multi-gigabyte copies
of the same model, and the only reason you are still holding the source is that it is the cache
key.

Bookmarks break that dependency.

```swift illustrative
var bookmarkData: Data { get }                       // on AIModel
init?(resolvingBookmark bookmark: Data) throws       // on AIModel
static func deleteEntry(referencedBy bookmark: Data) throws   // on AIModelCache
```

> ✅ **VERIFIED** — all three quoted from the reference pages.
> `bookmarkData` discussion: *"The data returned can be stored and later resolved to re-create a
> model with `init?(resolvingBookmark:)`. It contains information about the cache and entry backing
> the model."*

### The full workflow, Apple's code

Step 1 — specialize with `.persistent`, and capture the bookmark:

```swift prelude:guide-context
// Specialize and keep a reference to the model.
let model = try await AIModel.specialize(
    contentsOf: llmURL,
    options: .default,
    cachePolicy: .persistent
)

// Save bookmark data to restore access after the app exits.
let bookmarkData = model.bookmarkData
UserDefaults.standard.set(bookmarkData, forKey: "llm.bookmark")
```

Step 2 — on later launches, resolve instead of loading from the URL:

```swift illustrative
if let bookmarkData = UserDefaults.standard.data(forKey: "llm.bookmark") {
    do {
        if let model = try AIModel(resolvingBookmark: bookmarkData) {
            // Use the model.
            return model
        }
        // The model can't be found or was invalidated by an OS update.
    } catch {
        // The bookmark data is invalid.
    }
}

// Download and specialize the model again.
```

Step 3 — reclaim the source:

```swift prelude:guide-context
// Delete the source model to reclaim storage.
try FileManager.default.removeItem(at: llmURL)
```

> ✅ **VERIFIED** — all three snippets reproduced verbatim from *Managing model specialization and
> caching*. The variable name `llmURL` is Apple's, and is a strong hint about the intended audience:
> this workflow is aimed at large downloaded LLMs, not at a 4 MB classifier in your app bundle.

`.persistent` is not optional in this workflow. Deleting the source satisfies
`sourceAssetChangedOrDeleted`, so under `.default` you would be authorising the system to purge the
very artifact you are about to depend on.

### Two failure modes, and they are different

This is the API detail people get wrong, because the initializer is *both* failable **and**
throwing:

| Situation | Result |
|---|---|
| Bookmark data is **malformed** (not produced by `AIModel.bookmarkData`) | **throws** |
| Bookmark is **well-formed but stale** — entry purged, deleted, or invalidated by an OS update | **returns `nil`** |
| Bookmark resolves | returns the `AIModel`, pinning the entry |

> ✅ **VERIFIED** — return documentation, verbatim: *"If the bookmark data can be resolved, the
> resulting `AIModel` pins and references the cache entry as the model that generated the bookmark
> data. **If it cannot be resolved due to the specialized asset entry no longer being present nil is
> returned.**"* Discussion: *"Resolving bookmark data involves checking it is a valid bookmark,
> validating the associated cache and cache entry it references exists, and returning a `AIModel`
> constructed with that specialized asset contained within that entry. **If any of these steps fail,
> nil is returned**"*. NOTE: *"**If the bookmark data is malformed** due to not being sourced from
> `AIModel.bookmarkData` **an error is thrown**"*.

So `try? AIModel(resolvingBookmark: data)` collapses both failures into one `nil`, which is
tempting and mostly harmless — but it also collapses "your `UserDefaults` value is garbage, you
have a bug" into "the OS updated, this is normal." Keep them apart in your telemetry:

```swift prelude:guide-context
@available(iOS 27.0, macOS 27.0, *)
enum BookmarkResolution {
    case resolved(AIModel)
    case staleNeedsRespecialize      // normal after an OS update or a purge
    case malformedProgrammerError    // your persisted blob is not a Core AI bookmark
}

@available(iOS 27.0, macOS 27.0, *)
func resolveModel(bookmark: Data) -> BookmarkResolution {
    do {
        if let model = try AIModel(resolvingBookmark: bookmark) {
            return .resolved(model)
        }
        return .staleNeedsRespecialize
    } catch {
        // Not a Core AI bookmark at all. Almost always a persistence bug:
        // wrong UserDefaults key, a migrated blob, a Data written by something else.
        log.error("malformed Core AI bookmark: \(error)")
        return .malformedProgrammerError
    }
}
```

### ⚠️ SILENT FAILURE — a bookmark does not pin anything

> ✅ **VERIFIED** — `bookmarkData` NOTE, verbatim: *"**Bookmark data is just data. It does not pin
> entries in the cache.** Only a `AIModel` will pin its associated entry in the cache while it is
> held."*
> And the article, verbatim: *"Bookmark data doesn't prevent removing assets from the device. **If
> the system purges the assets, you manually delete them, or an OS update invalidates them, your app
> can't resolve the bookmark and needs to download and specialize the model again.**"*

> ⚠️ **SILENT FAILURE — the bookmark that quietly stops working.**
> Persisting `bookmarkData` feels like persisting the model. It is not. It is persisting a *pointer*
> to a cache entry that the system is free to delete underneath you — on OS update always, and under
> storage pressure if you did not use `.persistent`.
>
> The failure is silent in the worst possible way: **nothing throws.** `init?(resolvingBookmark:)`
> returns `nil`, your `if let` falls through, and whatever you wrote in the `else` branch runs. If
> that branch is `return nil` or `throw .modelUnavailable`, your feature simply stops existing after
> an OS update, with no diagnostic, in a build that worked perfectly during testing — because your
> test devices did not update mid-session.
>
> **And the amplifying mistake:** you deleted the source `.aimodel` in step 3. So the recovery path
> is not "re-specialize", it is "**re-download 3 GB, then re-specialize**". If you did not keep the
> remote URL and the version identifier alongside the bookmark, you cannot even do that.
>
> **The rule:** never persist a bookmark alone. Persist a record.
>
> ```swift
> struct InstalledModel: Codable {
>     let bookmark: Data          // fast path
>     let remoteURL: URL          // recovery path — you WILL need this
>     let assetVersion: String    // so you re-download the same model, not a newer one
>     let localURL: URL?          // nil once the source has been deleted
>     let specializedAt: Date     // useful telemetry: "how often are we re-paying?"
> }
> ```
> Then the load path is: resolve the bookmark → on `nil`, re-download from `remoteURL` →
> re-specialize → **write a fresh bookmark**. A stale bookmark must always be replaced, never
> retried.

### Deleting by bookmark

`AIModelCache.deleteEntry(referencedBy:)` is `static` because *"bookmark data encodes both the
specific cache instance and the entry within it"* (verified). That makes it the correct way to
retire a model whose source file you have already deleted — you no longer have a URL to pass to
`deleteEntries(for:)`.

```swift prelude:guide-context
@available(iOS 27.0, macOS 27.0, *)
func uninstall(_ installed: InstalledModel, holder: inout AIModel?) {
    holder = nil                                   // release the pin first — §7
    do {
        try AIModelCache.deleteEntry(referencedBy: installed.bookmark)
    } catch {
        log.warning("bookmark-scoped delete threw: \(error)")   // a live model may still pin it
    }
    if let localURL = installed.localURL {
        try? FileManager.default.removeItem(at: localURL)
    }
}
```

> ⚠️ `deleteEntry(referencedBy:)` carries the **same** repeated NOTE about live `AIModel`
> references as the other three delete methods. The iPhone 15 Pro probe in §7 confirms the throws
> branch for URL-keyed deletion; release the model before bookmark-keyed deletion too.

### When *not* to use bookmarks

If your model ships inside the app bundle, do not use this workflow. You cannot delete the source
(it is in a read-only bundle), the source costs you nothing extra at runtime, and the URL-keyed APIs
are simpler. Bookmarks are for **downloaded, large, deletable** assets — which is exactly the case
Apple's `llmURL` variable name signposts.

---

## 10. `SpecializationOptions` in practice

```swift illustrative
struct SpecializationOptions: Equatable, Hashable, Sendable, SendableMetatype {

    static let `default`: SpecializationOptions
    static let cpuOnly: SpecializationOptions
    init(preferredComputeUnitKind: ComputeUnitKind)

    var allowedComputeUnitKinds: Set<ComputeUnitKind> { get }
    var preferredComputeUnitKind: ComputeUnitKind? { get }
    var expectFrequentReshapes: Bool                       // get AND set
}

enum ComputeUnitKind: Equatable, Hashable, Sendable, SendableMetatype {
    case cpu
    case gpu
    case neuralEngine
    static var availableKinds: Set<ComputeUnitKind> { get }
}
```

> ✅ **VERIFIED** — every member quoted from `/documentation/coreai/specializationoptions` and
> `/documentation/coreai/computeunitkind`. Note the asymmetry: `allowedComputeUnitKinds` and
> `preferredComputeUnitKind` are **get-only**; `expectFrequentReshapes` is the **only** settable
> property, and there is **no initializer that sets it** — you must mutate it after constructing
> options some other way. That fact drives all of §11.

### The three constructors, and what each means

| Constructor | Apple's discussion (verbatim) |
|---|---|
| `.default` | *"The specialization process selects the combination of compute units that minimizes inference latency."* |
| `.cpuOnly` | *"The resulting specialized model only uses the CPU during inference. **Because all operations support the CPU, no fallback to other compute units occurs.**"* |
| `init(preferredComputeUnitKind:)` | *"The specialization process maximizes use of the specified compute unit kind, falling back to other allowed compute units for incompatible operations."* |

And Apple's blunt advice about overriding:

> ✅ **VERIFIED** — *"**In most scenarios, the default configuration offers the best performance, so
> test your app's performance carefully before overriding it.** Because not all devices have the
> same compute units available, check what's available with `availableKinds`."*
> Corroborated by `ComputeUnitKind`'s overview: *"**By default, specialization uses all available
> compute units on the device.**"*
> And by Apple's own agent skill in `apple/coreai-models` (`references/guidance.md`), which tells a
> coding agent to *"use `.default` specialization options unless you deliberately pin a compute
> unit"* — the same advice, aimed at a machine.

### The one case Apple names for `.cpuOnly`

> ✅ **VERIFIED** — *Managing model specialization and caching*, verbatim: *"For advanced use cases,
> restrict specialization to CPU only with `.cpuOnly`, or prefer a specific compute unit with
> `init(preferredComputeUnitKind:)`. **For example, if your app runs a small model in the background,
> use `.cpuOnly` to avoid competing with foreground GPU work.**"*

That is the real, non-obvious use, and it is worth expanding because it is easy to misread as a
performance option. It is a **scheduling** option. Consider an app with:

- a **foreground** feature — say a live camera segmentation running on the GPU at 30 fps, where a
  dropped frame is visible; and
- a **background** feature — a small text classifier scoring incoming items as they arrive, where
  nobody notices if a single classification takes 40 ms instead of 6 ms.

If both models specialize with `.default`, both will be told to minimise their own latency, and
both will reach for the GPU. The classifier's dispatches now interleave with your camera pipeline's
and you get intermittent frame hitches that are extremely hard to attribute. Pinning the background
model to `.cpuOnly` makes it slower in isolation and *the whole app* smoother.

```swift prelude:guide-context
@available(iOS 27.0, macOS 27.0, *)
enum ModelSpecialization {

    static func options(for role: ModelRole) -> SpecializationOptions {
        switch role {
        case .interactiveForeground:
            // Let the system pick. It optimises for latency, which is what
            // the user is watching.
            return .default

        case .backgroundBatch:
            // Deliberately give up the accelerators so we never contend with
            // foreground GPU work. All ops support CPU, so there is no fallback
            // and no surprise placement.
            return .cpuOnly
        }
    }
}

enum ModelRole { case interactiveForeground, backgroundBatch }
```

Two things to keep straight when you do this:

1. **`.cpuOnly` is a different cache key** (§4). Your background classifier now has its own entry,
   and if the same model is *also* used in the foreground you will store and specialize it twice.
   That is usually the right trade, but it is a trade — measure the disk cost.
2. **`.cpuOnly` genuinely means CPU.** Because *"all operations support the CPU, no fallback to
   other compute units occurs"*, there is no partial placement and no surprise. That determinism is
   itself valuable: `.cpuOnly` is the correct configuration for a numerical A/B against a PyTorch
   reference, because it removes accelerator-specific numerics from the comparison.

### Preferring a unit is a *preference*, not a lock

This is the single most misunderstood sentence in the whole options API, and Apple spells out why:

> ✅ **VERIFIED** — `preferredComputeUnitKind` discussion, verbatim: *"When set, the specialization
> process maximizes use of this compute unit kind. **Fallback to other kinds in
> `allowedComputeUnitKinds` may still occur for operations or operation patterns that are
> incompatible with the preferred kind. Operation patterns refer to groups of operations that are
> fused or transformed together during specialization; an operation that is individually compatible
> with the preferred unit kind may be part of a fused pattern that is not.**"*

Read the second half again: an op that *is* compatible with the Neural Engine can still land
somewhere else, because specialization **fused it** with a neighbour that is not. This means you
cannot reason about placement op-by-op from a PyTorch graph, and it means
`SpecializationOptions(preferredComputeUnitKind: .neuralEngine)` is not a guarantee of anything.

Community measurement corroborates the practical consequence, hard:

> **Community-measured** (`john-rocky` model zoo, `apple/coreai-models` issue #55, macOS 27.0
> `26A5353q`, M4 Max, `coreai-build 3600.67.5.8.1`, 2026-06 — attribute as community, not Apple):
> *"`--preferred-compute neural-engine` on the **dynamic** export is a **no-op** (still a GPU
> MPSGraph delegate, 0 ANE regions)."* The same author reports the corresponding Mac-side symptom:
> pinning `.gpu` on a Mac still *"spews `ANECCompile() FAILED / MLIR MPS to ANEC conversion failed`
> (dozens) — **these are NON-FATAL**: MPSGraph falls back to GPU and runs."*
> ⚠️ That last point is worth internalising: **`ANECCompile() FAILED` in your console during
> specialization is not necessarily an error.** The same author records having killed a run on the
> first such message and calls it *"wrong call"*.
> On macOS 27 beta 6 (`26A5416b`), the issue author confirmed that the original SIGSEGV no longer
> reproduced, and Apple closed #55 completed on **2026-08-27**. The linear-INT4 static program still
> failed ANE compilation and produced a GPU-only asset with exit 0, so the crash fix does **not**
> establish ANE support; treat the silent fallback as a separate unresolved hazard.

And the structural reason: which compute unit you get is decided far more by **how the model was
exported** than by what you ask for at load time. Apple's own runtime encodes that belief in code.

### What the optional `coreai-models` runtime actually does

This is useful evidence for one package’s option policy because it is Apple-maintained Swift code,
but it is not a Core AI framework naming contract:

> ✅ **VERIFIED** — `apple/coreai-models`,
> `swift/Sources/CoreAIShared/Runtime/ModelStructure.swift:57-80`, verbatim:
> ```swift
> public var specializationOptions: SpecializationOptions {
>     switch self {
>     case .chunkedStatic, .multiFunctionSegmenter:
>         return SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
>     case .dynamic:
>         var opts = SpecializationOptions(preferredComputeUnitKind: .gpu)
>         opts.expectFrequentReshapes = true
>         return opts
>     }
> }
> ```
> The `ModelStructure` cases are `chunkedStatic(batchSize: Int)`, `dynamic`, and
> `multiFunctionSegmenter`, and they are detected from **function names inside the asset**:
> `extend_*` plus `load_embeddings` → `.chunkedStatic`; `image_encode` + `text_encode` + `detect`
> → `.multiFunctionSegmenter`; a single `main` → `.dynamic`.

Read as a decision rule, the helper’s heuristic is:

| Model shape | Preferred unit | `expectFrequentReshapes` |
|---|---|---|
| Static shapes, chunked (a per-shape function set) | `.neuralEngine` | not set |
| Multi-function segmenter (`image_encode`/`text_encode`/`detect`) | `.neuralEngine` | not set |
| A single dynamic-shape `main` (the typical LLM export) | `.gpu` | **`true`** |

Note the second row's implication, which is easy to miss and is the subject of a standing
correction in this series: **when this helper loads the model, splitting it into recognized
entrypoints selects its Neural Engine preference in addition to enabling different cadences.** A
single-`main` SAM 3 export is classified `.dynamic` and receives the helper’s GPU preference. Direct
`AIModel` callers choose their own options.[^sample-routing-policy] Part 8 covers the authoring side.

And note what the code does *first*:

> ✅ **VERIFIED** — `ModelStructure.swift:145-165`, verbatim comment: *"Probe structure before
> specializing so we can pick the right compute-unit preference."* The probe uses
> `AIModelAsset(contentsOf:)` + `summary(includingStatistics: false)` — no specialization — and on
> any failure **silently defaults to `.dynamic`**.

That silent default is worth flagging in your own port of this pattern: if the probe throws for any
reason (a corrupt asset, a permissions problem), you get GPU + reshape-tolerant options rather than
an error. Which, per §11, is not a neutral choice.

Here is the pattern written out as app code, with the probe failure made visible:

```swift prelude:guide-context
import CoreAI

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
enum ProbedStructure: Equatable {
    case chunkedStatic
    case multiFunctionSegmenter
    case dynamic
    case unknown          // deliberately distinct from .dynamic

    var specializationOptions: SpecializationOptions {
        switch self {
        case .chunkedStatic, .multiFunctionSegmenter:
            return SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
        case .dynamic:
            var opts = SpecializationOptions(preferredComputeUnitKind: .gpu)
            opts.expectFrequentReshapes = true      // see §11 before copying this
            return opts
        case .unknown:
            return .default                          // let the system decide
        }
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
func probeStructure(at url: URL) -> ProbedStructure {
    guard AIModelAsset.isValid(at: url) else { return .unknown }
    do {
        let asset = try AIModelAsset(contentsOf: url)
        guard let summary = try asset.summary(includingStatistics: false) else { return .unknown }
        let names = Set(summary.functions.map(\.name))

        if names.contains("load_embeddings"), names.contains(where: { $0.hasPrefix("extend") }) {
            return .chunkedStatic
        }
        if names.isSuperset(of: ["image_encode", "text_encode", "detect"]) {
            return .multiFunctionSegmenter
        }
        if names.contains("main") { return .dynamic }
        return .unknown
    } catch {
        log.warning("structure probe failed for \(url.lastPathComponent): \(error)")
        return .unknown        // NOT .dynamic — we do not want to guess GPU + reshapes
    }
}
```

> ✅ **VERIFIED** — `AIModelAsset.isValid(at:)` exists and is documented as checking *"the URL is a
> file URL; the extension is one of the known model asset extensions; the model contains either a
> source program or a derived artifact."* The `GraphNames` string constants (`main`,
> `load_embeddings`, `extend` prefix, `image_encode`, `text_encode`, `detect`) are verbatim from
> Apple's `ModelStructure.swift`.
> 🟡 **RECONSTRUCTED** — the exact detection *order* above mirrors Apple's described order
> (`extend*` + `load_embeddings` first, then the segmenter triple, then `main`), but the Swift here
> is a re-expression, not a copy of Apple's source. The `.unknown` case is this guide's addition.

### `availableKinds` — check before you prefer

```swift illustrative
static var availableKinds: Set<ComputeUnitKind> { get }   // "The compute unit kinds available on the current device."
```

Not every device has every unit, and asking for one that isn't there is a silent downgrade at best.
A shipping community app guards it (community-authored,
[frozen Noema research note](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md) — attribute as such):

```swift prelude:guide-context
let preferred: ComputeUnitKind = ComputeUnitKind.availableKinds.contains(.neuralEngine)
    ? .neuralEngine
    : .gpu
var options = SpecializationOptions(preferredComputeUnitKind: preferred)
```

> ⚠️ Two traps in that pattern, both worth stating:
> 1. `availableKinds` varies by device, so **the same code produces different `SpecializationOptions`
>    on different devices** — which is correct, but means your cache-key reasoning (§4) is per-device
>    too. That is fine; caches are per-device anyway.
> 2. It does **not** vary by *model*. A device having a Neural Engine says nothing about whether
>    your graph can run on it. `availableKinds` is a hardware query, not a compatibility query, and
>    there is no compatibility query.

---

## 11. `expectFrequentReshapes`: the flag nobody documented

This flag deserves its own section because it is the only mutable knob on `SpecializationOptions`,
Apple's own code sets it to `true`, a third-party package rejects it as a reproducible crash, and
Apple's documentation says essentially nothing about it.

### What is actually known

> ✅ **VERIFIED — it exists, and it is a settable `Bool`.**
> `/documentation/coreai/specializationoptions/expectfrequentreshapes` declares
> `var expectFrequentReshapes: Bool` with **both** a getter and a setter — the only non-get-only
> property on the type. Its **entire** documentation is a one-line abstract:
> *"Setting to allow more optimal specialization if the model performs frequent reshapes based on
> usage"*.
> **There is no Discussion section. There is no stated default. There is no initializer that sets
> it.** The two static constructors (`.default`, `.cpuOnly`) are `let`s and
> `init(preferredComputeUnitKind:)` does not take it. The only way to set it is to mutate a value
> you constructed some other way.

> ✅ **VERIFIED — Apple's own Swift code sets it `true`, in exactly one case.**
> `apple/coreai-models`, `ModelStructure.swift:70-81`: for `.dynamic` models (single `main`
> entrypoint — the standard dynamic-shape LLM export),
> ```swift
> var opts = SpecializationOptions(preferredComputeUnitKind: .gpu)
> opts.expectFrequentReshapes = true
> ```
> For `.chunkedStatic` and `.multiFunctionSegmenter` — the static-shape cases — Apple does **not**
> set it, leaving whatever the default is.

> ✅ **VERIFIED — there is a corresponding compiler flag.**
> `xcrun coreai-build compile` accepts `--expect-frequent-reshapes`
> (community-captured `--help` output, 2026-06-10; also visible in an Apple-repo bug report's
> reproduction command). So the concept exists at both build time and load time.

Everything past those three facts is inference.

### The community incident

The most informative single piece of evidence about this flag is a negative result, and it is
community-measured. Report it as such.

> **Community-measured, device-validated 2026-07-23** — `john-rocky` model zoo,
> `aot-and-specialization.md`. iPhone 17 Pro, iOS 27 beta. **This is single-author community
> material with self-declared uncontrolled benchmarks; it is not an Apple statement.**
>
> The finding, in the author's framing: *"**The hint is not free insurance — it is a request for a
> *reshape-tolerant* specialization.** Ask for it at load time on an all-static graph and the
> runtime **stops using the AOT specialization and compiles on device**"*, which on that device
> crashed inside the MPSGraph compiler:
> ```
> EXC_BAD_ACCESS (SIGSEGV) … MPSGraphAICodeCompilerDelegate getInitializedAICodeBytecodeWithPayloadPrefix:
>   → Compiler_coreAI.compile(moduleBytecode:to:with:) → libODIECompiler … CompileForDelegates
> ```
> *"No error string, no partial output — the app just dies at `AIModel(contentsOf:options:)`."*
>
> Measured on a model with 5 fixed-shape graphs: `expectFrequentReshapes = true` → SIGSEGV on the
> first graph; `= false` → *"all 6 loads in 2.6 s"*.
>
> Two secondary observations from the same test, both important:
> - *"**Compiling with `--expect-frequent-reshapes` does NOT make the runtime hint safe** — both the
>   plain and the reshape-hinted `.aimodelc` crash when the *runtime* asks for the hint. **It is the
>   load-time option that matters.**"*
> - The author's resulting rule: *"`expectFrequentReshapes = true` **only** where shapes really
>   change (dynamic query length / bucketed prefill). Static decode (`S=1`) and fixed-T vocoders
>   must load **without** it."*

Note that this is **consistent** with Apple's own usage rather than contradicting it: Apple sets it
for `.dynamic` models and not for `.chunkedStatic` ones. Two independent parties therefore agree on
the *rule* — set it when shapes vary, don't when they don't — even though only one of them
discovered what happens if you get it wrong.

### ⚠️ SILENT FAILURE — the flag that discards your AOT work

> ⚠️ **SILENT FAILURE.** Per the community finding above, asking for `expectFrequentReshapes = true`
> at load time on an all-static graph causes the runtime to **stop using the ahead-of-time
> specialization and compile on device instead**. There is no warning, no log line, and no error —
> the only symptoms are that the load you carefully AOT-compiled is suddenly slow again (best case),
> or that the process dies with a `SIGSEGV` deep inside the Metal compiler with no message at all
> (observed case, beta 2026-07).
>
> This is a particularly nasty variant of the §4 problem, because the flag is a `var` on a `struct`.
> A helper that sets it "just to be safe", a value copied from a blog post, a default in your own
> options factory — any of them silently converts your AOT-compiled asset back into a JIT-compiled
> one.
>
> **Safe default:** leave `expectFrequentReshapes` **unset** unless (a) your model genuinely takes
> varying input shapes, and (b) you have measured that setting it helps. If you are shipping
> `.aimodelc` assets, verify after every change to your options factory that first-load time is
> still in the AOT range and not the JIT range — that comparison is the only reliable detector
> (§16 gives the shape of the numbers to expect).

### 🔴 GAP

> 🔴 **GAP — `expectFrequentReshapes` remains undocumented in the behavioral respects that matter.**
>
> **What is unknown:**
> 1. ~~**Its default value on a current device.**~~ ✅ **Measured 2026-08-20:** `.default` and
>    `.cpuOnly` both report `false` on a physical iPhone 15 Pro running iOS 27 beta 5
>    (`24A5408d`). This is a runtime observation, not a documented cross-device guarantee; the
>    `init(preferredComputeUnitKind:)` family still needs an explicit read if its default matters.
> 2. **What it actually changes.** "More optimal specialization" is the entire specification. Whether
>    it compiles a shape-generic kernel, defers some compilation, widens a shape-bucket policy, or
>    something else, is not stated anywhere.
> 3. **Whether it is part of the cache key.** `SpecializationOptions` is `Hashable` and the cache key
>    includes the options — so flipping this flag almost certainly creates a second entry, but
>    "almost certainly" is not verification, and `Hashable` synthesis is not documented to include
>    this property.
> 4. **How the load-time flag and `coreai-build --expect-frequent-reshapes` interact.** The community
>    report says the load-time one dominates; Apple documents neither.
> 5. **Whether the observed SIGSEGV is a property of the flag or a beta compiler bug.** The corpus
>    contains several unrelated MPSGraph compiler crashes in the same window, which makes a beta bug
>    entirely plausible.
>
> **What the SDK dump and device probe did and did not resolve:** the 2026-07-29 beta interface
> confirms the spelling — `public var expectFrequentReshapes: Bool`, the only settable property on
> `SpecializationOptions` (✅ **SDK-verified** — `CoreAIDelegates-27.0-macos.swiftinterface:100`) —
> but a `.swiftinterface` prints neither a stored property's default value nor which members feed
> the synthesised `Hashable`. `probes/` closed the concrete `.default` / `.cpuOnly` measurement on
> 2026-08-20 (`false` for both), while unknown 3 survives.
> **What would still resolve the behavioral questions:** a controlled device A/B of first-load time
> with the flag on and off, on both a static-shape and a dynamic-shape asset, on a non-beta OS.
> (`coreai-build compile --help` has now been run — 2026-07-31, via the Metal Toolchain component,
> see §13 — and confirms the compile-side flag spelling `--expect-frequent-reshapes`, *"Hint that
> inference will be run with frequently changing input shapes."*, but says nothing about the
> load-time default or the `Hashable` question:
> `notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`.)
>
> **Safe default meanwhile:**
> - **Do not set it** for static-shape graphs. Apple doesn't, and the one person who tried it
>   crashed.
> - **Do set it** for a single-`main` dynamic-shape LLM export on the GPU — that is precisely
>   Apple's own configuration in shipping code, and it is the best-attested use.
> - **Never toggle it dynamically at runtime.** Decide it once per model, in your one options
>   factory (§4), from the model's structure (§10).
> - **Do not print it in logs as if it were meaningful state** — read it back if you must, but
>   remember you cannot compare against a known default.

---

## 12. Dynamic shapes re-specialize — bucket them

There is a second, quieter cost that only shows up in models with dynamic input shapes, and it is
the reason `expectFrequentReshapes` exists at all.

> **Community-measured** (`john-rocky`, `aot-and-specialization.md`; single-author community
> material — attribute as such): *"a **dynamic**-shape core re-specializes on every new sequence
> length (**~60–80× per-shape compile tax**)."* The author flags the underlying measurement as
> living outside the repository, so treat the *magnitude* as unverified and the *phenomenon* as
> reported.

The phenomenon is corroborated independently by a shipping community iOS app, which built its
prefill strategy around it:

> **Community-measured** ([frozen Noema research note](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md),
> community-authored). Source comment, verbatim: *"…
> re-specialization — so feed a **fixed bucket, then power-of-two remainder chunks**: a handful of
> shapes total, each compiled once and reused across prompts, instead of one fresh compile per
> prompt length."*
>
> ```swift
> private static func prefillChunkSize(remaining: Int, perStep: Int) -> Int {
>     guard remaining > 0 else { return 1 }
>     guard perStep == Int.max else { return min(max(1, perStep), remaining) }
>     let bucket = 32
>     if remaining >= bucket { return bucket }
>     var size = 1
>     while size * 2 <= remaining { size *= 2 }
>     return size
> }
> ```

The idea generalises past LLM prefill: **if a model takes a dynamic dimension, quantise the values
you feed it.** A vision model that accepts any image width will re-specialize per width; snapping to
a small set of widths turns an unbounded number of compilations into a handful. The cost is a little
padding; the benefit is that the *n*-th distinct input is free instead of expensive.

Related, from the same community app, is the "prewarm" idea — deliberately running one dummy
inference at the shape you expect, at load time, so that the compilation happens behind your
loading UI rather than on the user's first real request:

> **Community-measured / community-authored**
> ([frozen Noema research note](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md)): *"Prewarm builds the session's decoder
> at full context so **one state shape** gets specialized at load time rather than on the first
> message, runs one `step`, then `reset()`s it in place."*
>
> Apple's own non-LLM engines expose the same idea as public API: `CoreAISegmentation` and
> `CoreAIObjectDetection` both ship `public func warmup() async throws`, and the object detector's
> is `warmup(imageCount:parameters:)` so you can warm at the **real batch size** you will use.
> ✅ VERIFIED against `apple/coreai-models` Swift sources. The doc comment for the segmentation
> warmup describes it as warming *"the engine with a dummy forward pass to trigger kernel
> compilation."*

> ⚠️ **One caveat on prewarming, from the same community source:** it deliberately *skips* prewarm
> for graphs whose KV cache rides as plain I/O, with the comment *"Skipping prewarm for host-cache
> graph; it would allocate the static KV cache."* A prewarm that allocates gigabytes is not a
> prewarm, it is an out-of-memory kill waiting for a slow device. Prewarm the *shape*, not the
> *capacity*.

So the full latency toolkit, in the order you should reach for it:

| Lever | What it removes | Where it runs | Marker |
|---|---|---|---|
| **Cache probe** (`model(for:options:)`) | Nothing — it tells you the cost is coming | Device, instant | ✅ Apple |
| **`AIModel.specialize`** | Nothing — moves phase 1 out of the interactive flow | Device, when you choose | ✅ Apple |
| **`coreai-build compile`** | Most of phase 1 | **Your Mac**, at build time | ✅ Apple |
| **Shape bucketing** | Repeat re-specializations on dynamic graphs | Device, by not triggering them | Community |
| **Warmup / prewarm** | Moves first-inference kernel compilation into load | Device, at load | ✅ Apple API, community technique |

---

## 13. Ahead-of-time compilation with `coreai-build`

This is the only lever that *reduces* device work rather than rescheduling it.

> ✅ **VERIFIED** — Apple, *Compiling Core AI models ahead of time*
> (`/documentation/coreai/compiling-core-ai-models-ahead-of-time`), verbatim:
> *"Core AI can help reduce on-device specialization time with ahead-of-time compilation through the
> **`coreai-build`** command-line tool. The tool **moves the most expensive part of specialization,
> model compilation, to your build machine**, so on-device specialization has less work to do, and
> your model loads faster when your app runs it."*
> *"Ahead-of-time compilation converts your `.aimodel` model file into `.aimodelc` assets, **one for
> each device architecture**. At runtime, your app picks the asset that matches the current device's
> architecture, and Core AI generates the executable code on device **without repeating the
> compilation step**."*

Map that onto §1's two phases and it is exact: `coreai-build` does phase 1 on your Mac and ships
you the result; the device still does phase 2.

### Prerequisite: the Metal Toolchain

`coreai-build` will not work without it, and neither will your Xcode build (§15).

> ✅ **VERIFIED** — Apple's instructions, verbatim:
> In Xcode: *"Choose Xcode > Settings."* → *"Choose Components, and under Other Components, click
> Get next to Metal Toolchain."*
> From the command line:
> ```shell
> % xcodebuild -downloadComponent MetalToolchain
> ```

### The command

```shell
% xcrun coreai-build compile MyModel.aimodel --platform iOS --min-deployment-version 27.0 --output compiled/
```

> ✅ **VERIFIED** — reproduced verbatim from Apple's article.

Flags Apple names in prose:

| Token | Meaning | Evidence |
|---|---|---|
| `compile` | the subcommand | ✅ Apple |
| `<input>.aimodel` | positional input | ✅ Apple |
| `--platform iOS` | target platform | ✅ Apple |
| `--min-deployment-version 27.0` | minimum OS the artifacts must run on | ✅ Apple |
| `--output compiled/` | output directory | ✅ Apple |
| `--preferred-compute` | *"By default, Core AI selects the compute units that deliver the best performance for the model and platform. To override, pass `--preferred-compute`."* | ✅ Apple |

And then Apple stops, with a pointer rather than a list:

> ✅ **VERIFIED** — verbatim: *"For the available values, the minimum deployment version, **the
> target architecture**, and other options, run `coreai-build compile --help`."*

Which tells you there is at least an architecture-selection flag Apple declines to name in prose.

### ✅ The CLI surface — gap resolved 2026-07-31

> ✅ **GAP — RESOLVED 2026-07-31.** `xcrun coreai-build --help` and every subcommand's `--help`
> have now been run on this machine and captured verbatim in
> **`notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`**. The resolution of the 2026-07-29
> mystery: **`coreai-build` ships in the optional Metal Toolchain component**
> (`xcodebuild -downloadComponent MetalToolchain`), **not in Xcode-beta.app itself**. With the
> component installed, `xcrun --no-cache --find coreai-build` resolves to
> `~/Library/Developer/DVTDownloads/MetalToolchain/mounts/<hash>/Metal.xctoolchain/usr/bin/coreai-build`,
> version **3600.79.1** — the same version number as the CoreAI framework's
> `-user-module-version`. (Plain `xcrun --find` can still fail from a stale cache; `--no-cache`
> is the reliable spelling.)
>
> **The history, kept because the distribution split is reader-critical:** checked 2026-07-29
> against Xcode 27.0 beta (27A5228h) **without the optional Metal Toolchain component**,
> `xcrun --find coreai-build` **failed**, and
> an exhaustive `find` of `Xcode-beta.app` turned up **no file named `coreai*` at all** — the
> wrapper is genuinely absent from the app bundle. What the bundle ships is
> `Xcode-beta.app/Contents/Developer/usr/bin/aimodelc` (project stamp `IDEMLKit-25131.2`,
> linking `IDEMLCompilerCore.framework`; command types `package`/`compile` only, no `--help`),
> whose binary embeds *"'aimodelc' is a tool used by the Xcode compiler."* and *"Please use
> 'xcrun coreai-build' instead."* — a stub pointing at a tool that lives in a **different,
> optional component**. A build machine that installs only Xcode will not have `coreai-build`;
> add the `-downloadComponent MetalToolchain` step (§13's one-time setup) before the compile step.
>
> **The captured surface (✅ verified 2026-07-31, `coreai-build 3600.79.1`):**
> - Subcommands: **`compile` | `package` | `inspect` | `metadata`** — `inspect` exists after all
>   (flags `--io`/`--metadata`/`--storage`/`--compute`/`--ops`/`--json`, the first two on by
>   default), and **`metadata`** (set author/license/description/per-argument descriptions, or a
>   whole-file `--json` update) was previously unknown anywhere in the corpus.
> - `compile`: `<input>` positional; `--output` (defaults to the current directory);
>   `--platform {iOS, macOS, watchOS, visionOS, tvOS}` (default **macOS**);
>   `--min-deployment-version` (default **27.0**); `--preferred-compute {gpu, neural-engine,
>   none}` (default **none**) — the long-sought value list, hyphenated exactly as the community
>   reported; `--architecture` (repeatable — *"If omitted compiles for all supported
>   architectures"*); and `--expect-frequent-reshapes`.
>
> The community synopsis (`john-rocky`, 2026-06-10) is thereby confirmed token-for-token, as are
> both community claims this guide had flagged: the `none` default and the extra subcommands.
>
> **Still unresolved:** how `--preferred-compute`'s values map onto `ComputeUnitKind` semantics at
> runtime, and what the flags *do* on device — the help text names them, nothing more. And the
> silent failure below is unchanged: a green compile still proves nothing about the architecture
> choice, so keep validating by loading the artifact on a real device.

### What it emits

> ✅ **VERIFIED** — Apple, verbatim: *"`coreai-build` outputs **one compiled `.aimodelc` file per
> device architecture**, using the input model's filename as the prefix. For example, compiling
> `MyModel.aimodel` produces files named **`MyModel.<arch>.aimodelc`**, where `<arch>` is the device
> architecture identifier returned by `deviceArchitectureName` at runtime. **Each compiled
> `.aimodelc` works on any OS version at or above the minimum deployment version you pass to
> `coreai-build`.**"*

That last sentence is the good news in this section, and it deserves emphasis because it is
surprising given everything else: **an `.aimodelc` is not pinned to an OS version.** Phase 1's
output is portable across OS versions at or above your floor; only phase 2's output — the
device-side cache entry — is OS-pinned. So an OS update invalidates the *cache*, not your shipped
artifacts.

### Matching the artifact at runtime

```swift illustrative
static var deviceArchitectureName: String { get }    // on AIModel
```

> ✅ **VERIFIED** — discussion, verbatim: *"When compiling model assets ahead of time with
> `xcrun coreai-build compile`, the toolchain produces artifacts for specific device architectures.
> **Use this property to discover which compiled asset matches the current device.**"*
> And Apple's "small amount of code", verbatim:
> ```swift
> let arch = AIModel.deviceArchitectureName
> let assetName = "MyModel.\(arch).aimodelc"
> ```

Loading is unchanged:

> ✅ **VERIFIED** — verbatim: *"To load the downloaded `.aimodelc` asset, use
> `init(contentsOf:options:)`. **This is the same API you use to load `.aimodel` files, so you don't
> need to change your loading code when you adopt ahead-of-time compilation.** Use the default
> options, or **specify options that match the compute units you used at compile time.**"*

Note that final clause. If you compiled with `--preferred-compute neural-engine`, load with
`SpecializationOptions(preferredComputeUnitKind: .neuralEngine)` — mismatching them is one of the
ways to end up doing on-device work you thought you had eliminated.

The full runtime selection, wired to Background Assets:

```swift compile:27
import BackgroundAssets
import CoreAI

@available(iOS 27.0, macOS 27.0, *)
enum CompiledAsset {

    /// The name of the .aimodelc variant this device needs.
    static func name(forModel base: String) -> String {
        "\(base).\(AIModel.deviceArchitectureName).aimodelc"
    }

    /// Resolve a compiled variant if we have one, otherwise fall back to the portable source.
    /// Both go through the same AIModel initializer.
    static func resolve(base: String, in directory: URL) -> URL? {
        let fm = FileManager.default
        let compiled = directory.appending(path: name(forModel: base))
        if fm.fileExists(atPath: compiled.path) { return compiled }
        let portable = directory.appending(path: "\(base).aimodel")
        if fm.fileExists(atPath: portable.path) { return portable }
        return nil
    }
}
```

> ✅ **VERIFIED** — the naming scheme, the `deviceArchitectureName` property, and the
> "same initializer for both" guarantee are all Apple-documented. The `.aimodelc`-then-`.aimodel`
> fallback is Apple's own pattern too: `apple/coreai-models`' diffusion pipeline ships
> `resolveAsset(at:name:)` which *"tries `"<Name>.aimodel"` then `"<Name>.aimodelc"`"*, i.e. the
> compiled artifact is **transparently substitutable** for the portable one.
> 🟡 **RECONSTRUCTED** — the specific Swift above is this guide's composition; the `BackgroundAssets`
> import is there because Apple names that framework as the recommended delivery mechanism, not
> because this snippet demonstrates its API.

### ⚠️ SILENT FAILURE — a successful compile proves nothing about the architecture

This is the AOT footgun, and it is exactly the shape this series exists to document.

> ⚠️ **SILENT FAILURE — `coreai-build compile` exits 0 for architectures the device will reject.**
>
> **Community-measured, device-validated 2026-06-10** (`john-rocky`; single-author community
> material, uncontrolled conditions — attribute as community, never as Apple):
> *"**`coreai-build compile` EXITs 0 for ANY requested arch** — a successful compile does **NOT**
> validate the arch choice; **only a device load does**."*
>
> The reported consequence: an artifact compiled for the wrong architecture *"fails to load with
> `invalidCompiledModel`"* on the device — at runtime, in the user's hands, long after a green CI
> build. The same source records the underlying naming rule that makes this easy to get wrong:
> *"the `--architecture` h-numbers follow the hardware **device-identifier major version**
> (`iPhone18,1`, `Mac16,5`), **not** the marketing name."* — and self-corrects an earlier note in
> its own archive that had guessed `h17p` for the iPhone 17 Pro by name-matching, when the
> device-validated answer was **`h18p`**.
>
> **Why this bites:** the marketing name and the device identifier are off by one for current
> iPhones. "iPhone 17 Pro" is `iPhone18,1`. Any scheme that derives an architecture code from a
> product name is wrong, and wrong *silently*, because the compile succeeds.
>
> **Safe default:**
> 1. **Never hardcode an architecture code you have not loaded on the corresponding device.**
> 2. **Prefer letting `coreai-build` fan out.** Apple's documented invocation passes no
>    `--architecture` at all and emits *"one compiled `.aimodelc` file per device architecture"*;
>    that set is by construction the set the toolchain believes in.
> 3. **Make `AIModel.deviceArchitectureName` the source of truth on device**, exactly as Apple's
>    snippet does. Print it in your diagnostics. It is the only authoritative statement of what this
>    device wants, and it costs nothing.
> 4. **Add a device smoke test that loads each shipped variant on real hardware.** A compile is not
>    a test.

> ✅ **GAP — RESOLVED 2026-07-31 — the set of architecture codes, enumerated by probing.**
> Apple still publishes no enumeration, and `compile --help` does not list the codes either. But
> the codes could be enumerated against the shipped `coreai-build` 3600.79.1 (Metal Toolchain
> component) by using the compiler's own validation as an oracle — it validates `--architecture`
> *before* touching the input file, with three distinct responses (unknown code / valid code but
> wrong platform / "Input model is missing the source bytecode." = accepted). Full matrix and
> method: **`notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`**, final section.
>
> **24 valid codes**: `h11p h11g h12p h13p h13s h13c h13g h14p h14s h14c h14g h15p h15s h15c h15g
> h16p h16s h16c h16g h17p h17s h17c h17g h18p`. Observed grammar: `h<generation><variant>`, with
> `p` = phone-class, `s`/`c` = Mac-class, `g` present from `h13g` up. At the default 27.0
> deployment target, macOS accepts `h13s…h17g` (plus `h17p`), iOS accepts `h11p…h18p`; **`h17p` is
> the one code accepted on both**. The community-attested **`h18p` is confirmed valid** (newest
> phone-class code; no `h19*`/`h20*` exists in this toolchain). This corroborates the community
> fan-out counts above in spirit, though the exact per-platform sets differ from the 2026-06-10
> report — betas moved.
>
> **What the enumeration does *not* give you:** the code→device mapping. Which physical device
> reports which code is still community-attested only (`iPhone18,1` → `h18p`, device-validated).
> **Safe default unchanged:** read the code at runtime with `AIModel.deviceArchitectureName`, ship
> every variant `coreai-build` produces (hosted remotely, per Apple's own advice, since each device
> downloads exactly one), and never map a marketing name to a code in your own code.

### The bundle hand-edit everyone forgets

If your model ships as an `apple/coreai-models`-style bundle — a directory containing the asset, a
tokenizer and a `metadata.json` — then compiling the asset is only half the job.

> ✅ **VERIFIED** — `apple/coreai-models`, `swift/Sources/CoreAIShared/Bundle/ModelBundle.swift`.
> The `.missingAsset` error message is verbatim:
> > *"If you compiled this model with `xcrun coreai-build compile`, update metadata.json "assets" to
> > reference the compiled filename (e.g. modelName.architectureName.aimodelc). See
> > models/README.md#compiled-models"*
>
> The same file also guards against a related mistake: pointing a bundle-expecting API at a
> `.aimodel`/`.aimodelc` path throws `.pointedAtModelAsset` *before any filesystem read*, because
> — verbatim — *"a compiled `.aimodelc` is itself a directory holding its own unrelated
> metadata.json, which would otherwise parse as a bogus 0.1 bundle and surface a misleading
> 'unsupported metadata_version' error."*

Two takeaways beyond the specific repo: **`.aimodelc` is a directory containing its own
`metadata.json`**, and any tooling of your own that walks a model directory needs to know that, or
it will find the wrong metadata file and produce a confusing error a long way from the cause.

---

## 14. What AOT does not buy you

Three limits, in descending order of how likely they are to surprise you.

### 14.1 ⚠️ AOT only compiles for Apple-Intelligence-capable devices

> ✅ **VERIFIED** — Apple, *Compiling Core AI models ahead of time*, verbatim NOTE:
> *"Ahead-of-time compilation **only compiles for devices that support Apple Intelligence**,
> including **iPhone or iPad with the A17 Pro chipset or later, a Mac with the M1 chipset or later,
> or Apple Vision Pro with the M2 chipset or later.**"*

This is the single most consequential sentence in the AOT article and it is stated **nowhere in
either WWDC session**. Its consequences:

- Every iPhone older than the **iPhone 15 Pro** (the first A17 Pro device) gets **no `.aimodelc`
  variant at all** and must specialize the portable `.aimodel` on device, at full price.
- Every Intel Mac is out, and so is every pre-M1 Mac.
- The NOTE names iPhone, iPad, Mac and Vision Pro. **Apple Watch and Apple TV are not in the list**,
  even though Core AI's framework page lists watchOS 27 and tvOS 27 as supported platforms.

> 🔴 **GAP — what `--platform watchOS` and `--platform tvOS` actually do. Narrowed 2026-07-31.**
> The framework supports seven platforms; the AOT hardware NOTE names four device families; and
> `watchOS`/`tvOS` among the `--platform` values is now ✅ **tool-verified**, not just
> community-reported (`coreai-build compile --help`, capture in
> `notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`). Architecture-validation probing on a
> macOS 26.5 host adds: `--platform tvOS` accepts codes `h11p` and `h14p`, while `--platform
> watchOS` accepted **none** of the swept codes (caveat: possibly missing device-support data on
> that host). Whether a full compile actually *produces* artifacts for these platforms remains
> **unverified** — the probe validates flags, not output.
> **What would resolve it:** running `xcrun coreai-build compile x.aimodel --platform watchOS` on
> a real `.aimodel` and reporting the exit code and the output directory contents.
> **Safe default meanwhile:** for watchOS and tvOS, plan for the `.aimodel` JIT path — keep models
> small, and use the §3 gating UI. Do not assume an AOT artifact will exist.

So your delivery matrix has two rows, not one, and you must design for both:

| Device class | Gets `.aimodelc`? | First-load cost | What your app must do |
|---|---|---|---|
| A17 Pro+, M1+ Mac, M2+ Vision Pro | Yes | Reduced (phase 2 only) | Download the matching variant |
| Everything else on iOS/iPadOS 27 | **No** | **Full** (phases 1 + 2) | Ship/download the portable `.aimodel` and gate the UI |

Which means the fallback in `CompiledAsset.resolve(base:in:)` from §13 is not a nicety. It is the
main path for a large slice of your installed base.

### 14.2 Residual specialization is real, and it can still be minutes

> ✅ **VERIFIED** — Apple, verbatim: *"**Even with ahead-of-time compilation, the compiled asset
> still requires some specialization on the device.** The amount of compilation that remains depends
> on the model and the compute units it uses."*

Apple does not quantify "some". The community does, and the number is large:

> **Community-measured** — `john-rocky`, `apple-models-bench.md`, iPhone 17 Pro on iOS 27 beta,
> benchmarking **Apple's own official Qwen3-4B iOS preset**: a **3 GB AOT-compiled `.aimodelc`**
> targeted at the Neural Engine took **194 seconds** to cold-load, and **0.46 s** warm. The author's
> own gloss: *"cold on-device specialization takes ~3 min."* **Single-author community material,
> uncontrolled conditions, beta OS — not an Apple figure.**

Three minutes of *residual* work, after AOT. That is the number to design your first-run experience
around, not the four-second figure from a small model.

### 14.3 AOT does not fix memory

Compilation and execution have different memory profiles, and AOT only helps the first one.

> **Community-measured** — `john-rocky`, `aot-and-specialization.md`, iPhone 17 Pro / iOS 27 beta.
> A 1.8 GB monolithic model AOT-compiled for the Neural Engine *"loads on iPhone 17 Pro with
> `cu=ane` in 6.5–8.1 s, no jetsam"* — and then *"**the first inference step is jetsam-SIGKILLed —
> load ✅ / run ❌**."* The author's diagnosis: the ANE load left ~2.8 GB headroom where the GPU path
> left ~6.0 GB for the same-size core, and the first step's working set exceeded it.
>
> And at the extreme, from the same author's flagship notes: a **Qwen3.6-35B int4 (18 GB)** bundle
> produced **`signal 9` (jetsam OOM)** on the iPhone 17 Pro's ~12 GB of RAM — *"killed during the
> **~26-min cold compile**."* **The flagship 35B cannot run on the phone.**
>
> ⚠️ Both figures are single-author, beta-era, uncontrolled. Cite the *shape* — "compilation itself
> can be killed by jetsam on a large model" — with more confidence than the exact minutes.

Apple's own agent skill sets budgets that are consistent with this and are the most authoritative
guidance available on model sizing:

> ✅ **VERIFIED** — `apple/coreai-models`, `references/guidance.md` (one of Apple's agent skills for
> its own repo): iOS *"Keep models under 2 GB"*; macOS *"Leave at least 6 GB of RAM headroom"*; use
> `os_proc_available_memory()` at runtime.

And there is an entitlement that changes the arithmetic on iOS/iPadOS:

> ✅ **VERIFIED** — `apple/coreai-models` issue #112, resolved by the reporter: an app that crashed
> with *"`libc++abi: terminating due to uncaught exception of type std::bad_alloc` / Debug session
> ended with code 9: killed"* was fixed by adding the **Increased Memory Limit** entitlement. The
> reporter's own method note is worth copying: the Xcode console said nothing useful; **Console.app
> showed `Out of Memory`**.

> ⚠️ **Diagnostic rule for this whole area:** on iOS/iPadOS, `std::bad_alloc` out of a Core AI load
> is almost always **jetsam**, not a Core AI bug. Look in **Console.app**, not the Xcode console,
> and check the Increased Memory Limit entitlement before you file anything.

### 14.4 The unresolved question: does iOS *need* AOT?

Apple frames AOT as an optimisation. Some community material frames it as mandatory on iOS. The
evidence in this corpus points **both ways**, and this guide will not pretend otherwise.

> 🔴 **GAP — is AOT optional or required on iOS?**
>
> **For "optional" (Apple's position):** the AOT article calls it a way to *"help reduce on-device
> specialization time"*, and the loading section says *"you don't need to change your loading code
> when you adopt ahead-of-time compilation"* — the language of an optimisation, not a requirement.
> `AIModel.init(contentsOf:)` documents accepting *"a `.aimodel` **or** `.aimodelc` file"* with no
> platform qualifier.
>
> **For "optional", from the community too:** the same community source that elsewhere says iOS
> requires AOT also reports a clean device A/B in which an **uncompiled `.aimodel` cold-specialized
> on an iPhone in 19.2 s** versus **4.9 s** for the `.aimodelc`. A model that JITs in 19.2 seconds
> is a model that JITs.
>
> **For "required":** the same corpus reports that pointing the runtime at an uncompiled `.aimodel`
> on iOS *"fails at engine load with `NSPOSIXErrorDomain Code=2`"*, and separately that a
> **macOS-tagged** IR on iOS produces exactly that error because there are *"no iOS delegates to
> load"*. It also reports a 4B-class model whose on-device GPU specialization *"exhausts the
> device's scratch disk mid-compile → `LLVM ERROR: No space left on device`"*.
>
> **The most probable reconciliation** — and it is an inference, not a verified finding — is that
> the `Code=2` failures are about **platform-tagged exports** (a model exported `--platform macOS`
> has no iOS-compatible delegates and cannot be specialized on iOS regardless of AOT), and the
> disk/OOM failures are about **size**, not about iOS being unable to JIT at all. Under that reading
> both observations are true and neither generalises to "iOS cannot JIT."
>
> **What would resolve it:** export one small model with `--platform iOS`, load the **uncompiled**
> `.aimodel` on an iPhone, and report whether it specializes. That is a fifteen-minute experiment
> and nobody in this corpus has published it cleanly.
>
> **Safe default meanwhile:** on iOS, **ship AOT-compiled `.aimodelc` for every A17-Pro-or-later
> architecture**, and keep the portable `.aimodel` as the fallback for older devices (§14.1). That
> configuration is correct under every reading of the evidence. And **always export with the
> platform you will run on** — a `--platform macOS` export is not an iOS model.

---

## 15. Xcode integration: Compile Sources and the Metal Toolchain

Two build-time facts that will stop you before you write a line of the code above.

### 15.1 `.aimodel` belongs in Compile Sources

> ✅ **VERIFIED** — Apple, *Integrating on-device AI models in your app with Core AI*, verbatim:
> 1. *"Drag the `.aimodel` file from the Finder into the Project Navigator in Xcode, or choose
>    File > Add Files to add it."*
> 2. *"When the sheet appears, select the targets to include the model under Add to targets, then
>    review the remaining options."*
> 3. *"Click Finish."*
>
> **NOTE:** *"After adding the file, you should also see the model in the **Compile Sources** build
> phase for that target."*

Compile Sources, not Copy Bundle Resources. That is unusual for an asset and it is the tell that
Xcode does real work with the file at build time. If it landed in Copy Bundle Resources instead,
move it.

Related, from a real bug report: if your model is a **bundle directory** (asset + tokenizer +
`metadata.json`), Xcode needs to be told to keep it together.

> ✅ **VERIFIED** — `apple/coreai-models` issue #58, maintainer answer, verbatim: *"for Xcode
> resources **'Apply once to folder'** is necessary to have them move as a single bundle. This can
> be set on the File Inspector on the righthand side."*
> The same thread's root cause is worth internalising: the reporter had pointed `modelURL` at the
> **`.aimodel`** when the API wanted the **parent bundle directory**, and the resulting error was
> the deeply unhelpful `unsupported metadata_version '0.1' (known: 0.2)`.

### 15.2 ⚠️ The Metal Toolchain is not installed by default

> ✅ **VERIFIED** — Apple, verbatim:
> *"Core AI model integration in Xcode requires the **Metal Toolchain, which isn't installed by
> default**. There are two options for adding the Metal Toolchain:*
> - *In Xcode, choose **Xcode > Settings > Components > Other Components**, then click **Get** to
>   download and install the Metal Toolchain.*
> - *In Xcode, select any `.aimodel` file in your project and click the **Get** button in the Metal
>   toolchain download bar that appears."*
>
> **IMPORTANT:** *"**If the Metal toolchain isn't included, builds that include `.aimodel` files
> fail with a missing Metal compiler error.**"*

Command line, for CI:

```shell
% xcodebuild -downloadComponent MetalToolchain
```

> ⚠️ This is the number-one first-contact failure with Core AI, and the error message points at
> Metal, not at Core AI, so it does not obviously lead you here. If a colleague reports "my build
> broke and it says something about a Metal compiler" the day after you added a model: this.
> It is also a **CI** problem — a fresh runner image will not have the toolchain, and
> `xcodebuild -downloadComponent MetalToolchain` needs to run before your first build.

For reference, the toolchain has a version of its own that shows up in bug reports — community
sightings in this corpus include `MetalToolchain-v27.1.5194` paired with `coreai-build` builds
`3600.67.5.8.1`, `3600.73.1` and `3600.75.3` (community-reported, beta era). If you file a bug
about a compile crash, include both.

### 15.3 The debug gauge needs a *direct* link

Not a build failure, but the same class of problem — a tool that silently does not appear:

> ✅ **VERIFIED** — Apple, *Monitoring model performance with the debug gauge*, verbatim NOTE:
> *"**The gauge only appears in projects that link the Core AI framework. The gauge does not support
> the Core ML framework.**"* And: *"If you don't see the gauge, verify that your project **directly
> links** the Core AI framework. To check, go to your project settings in the Xcode Navigator and
> scroll to **Frameworks, Libraries, and Embedded Content** in the **General** section."*

Transitive linkage through a Swift package is not enough. If you consume Core AI only through a
package (say `CoreAILanguageModels`), add `CoreAI.framework` to your app target explicitly or you
lose the one tool that can show you your specialization events.

---

## 16. The numbers, attributed

Every figure below is labelled with who measured it, on what, when. **Nothing in this table is a
performance promise.** Beta-era numbers move.

### 16.1 Apple-published

Apple published remarkably few numbers about specialization. These are the ones that exist:

| Claim | Value | Source |
|---|---|---|
| Bundling SAM 3 + Qwen3 0.6B into an app | *"over 1 GB"* added to download size | ✅ WWDC26 session 326 |
| A specialize event in the Instruments screenshots | ~800 ms (`Compile Asset, Specialize` with a nested `Compile segment`) | ✅ Apple docs screenshot, an unnamed small model |
| Load / Setup events in the same trace | `Load model::main (10.54 μs)`, `Setup for model::main (66.96 μs)` | ✅ Apple docs screenshot |
| Specialization events per model per run | *"at most one … none if the model is fully specialized for the device or already cached"* | ✅ Apple, Instruments article |

That is genuinely all. Apple describes specialization qualitatively — *"can take a significant
amount of time for very large models"* — and leaves the quantities to you.

### 16.2 Community-measured

> ⚠️ **Attribution, stated once and applying to this whole subsection.** These figures come from a
> single community author (`john-rocky`, a ~60-model community Core AI zoo) and one shipping
> community iOS app ([frozen Noema research note](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md)). The author's own benchmark files declare uncontrolled conditions
> — thermal state, protocol differences, and beta OS builds. They are **valuable because they are
> often the only numbers in existence**, and they must never be presented as Apple figures.

**Specialization / load times**

| Measurement | Value | Hardware / OS | Date |
|---|---|---|---|
| `.aimodel` JIT → `.aimodelc` AOT, **true cold** first load, int8-kernel GPU monolith (post cache-wipe) | **19.2 s → 4.9 s (~4×)**; warm **0.0 s both** | iPhone, iOS 27 beta | 2026-06 |
| Apple's official **qwen3-4b ANE preset**, 3 GB `.aimodelc`, cold / warm | **194 s / 0.46 s** | iPhone 17 Pro, iOS 27 beta | 2026-07 |
| qwen3-0.6b ANE preset, cold / warm | 2.85 s / **0.045 s** | iPhone 17 Pro, iOS 27 beta | 2026-07 |
| Cold **GPU** specialization by model size | ≈ **4.8 s** at 0.8 B; ≈ **29 s** at 2.3 GB | iPhone, iOS 27 beta | 2026-07 |
| gpt-oss-20b (13 GB), cold incl. GPU specialization / warm | **13.2 s / 2.1 s** | M4 Max 128 GB, macOS 27 beta | 2026-07 |
| 1.8 GB monolith AOT'd for ANE — **load** | 6.5–8.1 s, no jetsam… | iPhone 17 Pro, iOS 27 beta | 2026-06 |
| …but **first inference** | **jetsam-SIGKILLed** | same | same |
| Qwen3.6-35B int4 (18 GB) on-device compile | **`signal 9` (jetsam OOM)** during a **~26-minute** cold compile | iPhone 17 Pro (~12 GB RAM) | 2026-07 |

The three shapes to take from that table:

1. **AOT is worth roughly 4× on a first cold load** for a GPU monolith — 19.2 s → 4.9 s.
2. **Warm loads are effectively free** — 0.0 s, 0.045 s, 0.46 s — *and the OS cache serves
   `.aimodelc` too*. Everything in this guide is about the first load, because there is no second
   problem.
3. **Size dominates everything.** 0.8 B → ~5 s. 2.3 GB → ~29 s. 3 GB on the ANE → 194 s. 18 GB →
   the process dies. Specialization cost is not linear in anything convenient, and the ANE path is
   dramatically more expensive at the top end than the GPU path.

### 16.3 ⚠️ The artifact is not a function of the recipe

This one is not a latency finding; it is a *reproducibility* finding, and it is the most
uncomfortable item in this guide.

> **Community-measured** (`john-rocky`, `apple-models-bench.md`, 2026-07). Same model
> (`coreai.llm.export qwen3-0.6b`), **same code, same wheels, same recipe** — exported once on
> **macOS 26** and once on the **macOS 27 beta**, then both run on the *same* iPhone 17 Pro:
>
> | Artifact | Prefill tok/s | Decode tok/s (run 1) | Footprint |
> |---|---:|---:|---:|
> | exported on **macOS 26** | **5 807** | **115.1** | **0.22 GB** |
> | exported on the **macOS 27 beta** | 1 519 | 57.2 | 0.47 GB |
>
> The author's summary, verbatim: *"**An `.aimodel` is a build artifact, not a pure function of the
> recipe**: the same `coreai.llm.export qwen3-0.6b` produced a **2.2× faster artifact on macOS 26
> than on the 27 beta** (**native quantized-Linear lowering vs explicit dequant ops**; same code,
> same wheels). … **Version-stamp and keep your artifacts.**"*

The identified mechanism — whether the exporter emits a native quantized-linear lowering or falls
back to explicit dequantize operations — is a decision made by the **toolchain running on the export
host**. Which means:

> ⚠️ **SILENT FAILURE — your build machine's OS is an input to your model's performance.**
> Nothing errors. Nothing warns. The same command, the same Python environment, the same model
> weights, produce two artifacts that behave identically and differ by **~2× in throughput and ~2×
> in memory** on the same phone. If your CI runner is upgraded, or a colleague exports on a
> different laptop, your app gets slower and every dashboard you have will blame the app.
>
> **Mitigations:**
> 1. **Pin the export host.** Treat the macOS version of the machine that produces `.aimodel` files
>    as part of the build recipe, and record it.
> 2. **Version-stamp artifacts.** `coreai-core 1.0.0b2` added a **producer** field to asset
>    metadata (`AIProgram.save_asset` *"now records the producer in asset metadata"*, ✅ verified
>    from the release notes) — read it back with `AIModelAsset.metadata` and log it. Also stamp your
>    own: `metadata["exportHostOS"] = "26.4"` via `updateMetadata` (§1).
> 3. **Benchmark the artifact, not the recipe.** A regression test that re-exports and re-measures
>    is the only thing that catches this.
>
> **Status as of 2026-07-27: unknown.** Nobody has established whether this is a beta regression that
> Apple will fix, a deliberate lowering change, or an artefact of the specific model. It is reported
> once, by one author, and it has not been reproduced independently in this corpus. Treat it as a
> live hazard, not a settled fact.

### 16.4 One more version gate that produces load failures

Unrelated to performance, but it lands in the same place — a model that will not specialize:

> ✅ **VERIFIED** — `apple/coreai-torch` v0.4.1 release notes, verbatim:
> *"**.aimodel artifacts converted with coreai-torch v0.4.0 will fail to load/specialize on-device
> starting with OS 27 second beta onwards. Reconvert your model using coreai-torch v0.4.1 or later
> to produce a compatible artifact.**"*
> Maintainer confirmation on `coreai-torch#37`: *"from macOS beta 2 the assets generated via
> coreai-torch 0.4.0 will fail to compile. Please use coreai-torch 0.4.1 for conversion."*

If a model that used to specialize suddenly does not, check the converter version that produced it
before you debug anything else. Which is another argument for §16.3's advice: **stamp your
artifacts.**

---

## 17. A recovery ladder for wedged loads

Everything up to here has been about the happy path getting slow. This section is about the load
that never completes.

The symptom set is distinctive: an `AIModel(contentsOf:)` that throws an error you cannot decode, or
that used to work and now doesn't, or that works on one device and not another. The cause is almost
always one of five things, and they have a natural order of cheapness to check.

### The ladder

```swift prelude:guide-context
import CoreAI
import os

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
enum ModelLoader {

    private static let log = Logger(subsystem: "com.example.app", category: "coreai")

    /// Load a model, recovering from the failure modes that a retry can actually fix.
    /// Returns the model, or throws the *original* error if nothing recovers it.
    static func load(at url: URL) async throws -> AIModel {

        let options = ModelSpecialization.options(for: url)   // §4: one source of truth

        // ── Rung 0 ─ Is the asset even an asset? Cheap, synchronous, no specialization.
        guard AIModelAsset.isValid(at: url) else {
            log.error("not a valid model asset: \(url.lastPathComponent, privacy: .public)")
            throw LoadError.invalidAsset(url)
        }

        // ── Rung 1 ─ Cache hit. Fast path, never specializes.
        if let cached = try? AIModelCache.default.model(for: url, options: options) {
            log.debug("specialization cache hit")
            return cached
        }

        // ── Rung 2 ─ Normal specialize-and-load.
        do {
            return try await AIModel(contentsOf: url, options: options)
        } catch {
            let ns = error as NSError
            log.error("""
                load failed: domain=\(ns.domain, privacy: .public) code=\(ns.code) \
                arch=\(AIModel.deviceArchitectureName, privacy: .public) \
                asset=\(url.lastPathComponent, privacy: .public)
                """)

            // ── Rung 3 ─ Drop every cached variant of this asset and try once more.
            //  A partially written or evicted entry is a documented way loads get wedged,
            //  and deleteEntries ignores options so it takes them all (§7).
            do { try AIModelCache.default.deleteEntries(for: url) }
            catch { log.warning("cache delete threw (see §7 gap): \(error)") }

            do {
                return try await AIModel(contentsOf: url, options: options)
            } catch {
                // ── Rung 4 ─ Give up our compute-unit preference and let the system choose.
                //  If our options were already .default there is nothing left to try.
                guard options != .default else { throw error }
                log.warning("retrying with .default specialization options")
                if let cached = try? AIModelCache.default.model(for: url, options: .default) {
                    return cached
                }
                return try await AIModel(contentsOf: url, options: .default)
            }
        }
    }

    enum LoadError: Error { case invalidAsset(URL) }
}
```

> 🟡 **RECONSTRUCTED as a composition** — the *shape* of rungs 1, 3 and 4 is taken from a shipping
> community iOS app ([frozen Noema research note](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md),
> community-authored), whose own comment on the delete step reads:
> *"Clear every cached variant of this model: each `SpecializationOptions` change leaves its own
> multi-GB entry behind, and stale/evicted entries are the documented way loads get wedged under
> storage pressure."* Rung 0 (`AIModelAsset.isValid(at:)`) and the diagnostic logging are this
> guide's additions. Every API called is ✅ verified; the *policy* of retrying is community practice,
> not an Apple recommendation.

### What each rung is actually for

| Rung | Fixes | Cost of trying |
|---|---|---|
| 0 — `isValid(at:)` | A truncated download, a wrong path, a `.aimodel` that never finished writing | Microseconds |
| 1 — cache probe | Nothing; it *avoids* the work | Microseconds |
| 2 — normal load | — | The full specialization |
| 3 — delete + retry | A corrupt, partially written or half-evicted cache entry | A second full specialization |
| 4 — fall back to `.default` | A compute-unit preference this model or device cannot satisfy | A third full specialization |

Note the price: a failing load that walks the whole ladder pays for specialization **three times**.
That is acceptable for a rare recovery and unacceptable as a routine path, so instrument it — if
rung 3 fires regularly you have a real bug, not a flaky device.

### What the ladder cannot fix

Be honest with yourself about the failures that are not retryable, because retrying them just burns
the user's battery:

| Symptom | Cause | Fix |
|---|---|---|
| `std::bad_alloc`, "Debug session ended with code 9: killed" | **Jetsam.** Check **Console.app**, not the Xcode console — it will say `Out of Memory` | Smaller model; the **Increased Memory Limit** entitlement (✅ verified fix, `coreai-models` #112) |
| `invalidCompiledModel` on an `.aimodelc` | Wrong `--architecture` for this device (§13) | Ship the variant matching `AIModel.deviceArchitectureName` |
| `NSPOSIXErrorDomain Code=2` at load | Reported for a **platform-tagged mismatch** — a macOS export on iOS (§14.4) | Re-export with the right `--platform` |
| `unsupported metadata_version '0.1' (known: 0.2)` | You pointed at the `.aimodel` when a **bundle directory** was expected (✅ verified, `coreai-models` #58) | Point at the parent directory |
| Load worked yesterday, fails today, artifact unchanged | Converter version gate — `coreai-torch` 0.4.0 assets stopped loading at OS 27 beta 2 (§16.4) | Reconvert with 0.4.1+ |
| Load succeeds, first inference dies | Memory, not compilation (§14.3) | Smaller model, or the GPU path over the ANE path |
| Dozens of `ANECCompile() FAILED` in the console, then it runs | **Not an error.** MPSGraph fell back to the GPU (community-reported, §10) | Ignore; do not kill the run |

### The instrumentation that makes all of this tractable

Log these five things on every model load. They are the exact fields you will be asked for when you
file a bug, and the exact fields that let you attribute a field report without a repro:

```swift prelude:guide-context
log.info("""
    coreai load: asset=\(assetName, privacy: .public) \
    arch=\(AIModel.deviceArchitectureName, privacy: .public) \
    compiled=\(assetName.hasSuffix(".aimodelc")) \
    cacheHit=\(wasCacheHit) \
    elapsed=\(String(format: "%.2f", elapsed))s
    """)
```

> ✅ **VERIFIED** — `AIModel.deviceArchitectureName` is a `static var` returning a `String`, so it
> costs nothing to log and is the single most useful field in a Core AI bug report. The
> maintainers of `apple/coreai-models` ask reporters for hardware tier, RAM, GPU core count, the
> macOS beta number and the Xcode version; the architecture name answers most of that in one token.

---

## 18. Quick reference

### The API, in one block

```swift illustrative
import CoreAI

// ── Inspect without specializing ────────────────────────────────────────────
static func AIModelAsset.isValid(at url: URL) -> Bool
init(contentsOf url: URL) throws                                     // AIModelAsset
func summary(includingStatistics: Bool) throws -> AIModelAsset.Summary?

// ── Specialize + load ───────────────────────────────────────────────────────
init(contentsOf modelURL: URL,
     options: SpecializationOptions = .default) async throws          // AIModel; always the default cache

@discardableResult
static func specialize(contentsOf modelURL: URL,
                       options: SpecializationOptions = .default,
                       cache: AIModelCache = .default,
                       cachePolicy: AIModelCache.Policy = .default) async throws -> AIModel

// ── The cache ───────────────────────────────────────────────────────────────
static let AIModelCache.default: AIModelCache
init?(appGroup groupIdentifier: String)                               // needs com.apple.security.application-groups
func model(for modelURL: URL, options: SpecializationOptions) throws -> AIModel?   // NEVER specializes
func deleteEntry(for modelURL: URL, options: SpecializationOptions) throws
func deleteEntries(for modelURL: URL) throws                          // ignores options; deletes them all
func deleteAll() throws
static func deleteEntry(referencedBy bookmark: Data) throws

// ── Policy ──────────────────────────────────────────────────────────────────
static let AIModelCache.Policy.default: Policy                        // purgeable
static let AIModelCache.Policy.persistent: Policy                     // until the next OS update
init(purgeConditions: PurgeConditions)
static let PurgeConditions.sourceAssetChangedOrDeleted: PurgeConditions
static let PurgeConditions.storagePressure: PurgeConditions

// ── Bookmarks ───────────────────────────────────────────────────────────────
var bookmarkData: Data { get }                                        // does NOT pin the entry
init?(resolvingBookmark bookmark: Data) throws                        // throws=malformed, nil=stale

// ── Options ─────────────────────────────────────────────────────────────────
static let SpecializationOptions.default: SpecializationOptions
static let SpecializationOptions.cpuOnly: SpecializationOptions
init(preferredComputeUnitKind: ComputeUnitKind)
var allowedComputeUnitKinds: Set<ComputeUnitKind> { get }
var preferredComputeUnitKind: ComputeUnitKind? { get }
var expectFrequentReshapes: Bool                                      // the ONLY setter; see §11

enum ComputeUnitKind { case cpu, gpu, neuralEngine }
static var ComputeUnitKind.availableKinds: Set<ComputeUnitKind> { get }

// ── AOT ─────────────────────────────────────────────────────────────────────
static var AIModel.deviceArchitectureName: String { get }
```

> ✅ **VERIFIED** — every declaration above is quoted from the Core AI reference pages. The `import
> CoreAI` module name and the `"main"` default function name are from Apple's integration article.
> ✅ **SDK-verified** (2026-07-29): every declaration in this block also matches the captured
> macOS 27.0 beta interface — the loading/cache/options surface is declared in `CoreAIDelegates`
> (`CoreAIDelegates-27.0-macos.swiftinterface:14-122`) and reaches you because `import CoreAI` is
> an umbrella re-export of it; the asset surface is `CoreAIAsset-27.0-macos.swiftinterface:11-21`.
> All throws are untyped — see §3.

### The CLI, in one block

```shell
# Once, on the build machine (and on CI):
xcodebuild -downloadComponent MetalToolchain

# Per model:
xcrun coreai-build compile MyModel.aimodel \
    --platform iOS \
    --min-deployment-version 27.0 \
    --output compiled/
# → compiled/MyModel.<arch>.aimodelc, one per device architecture

# Optionally override compute-unit selection:
#   --preferred-compute gpu|neural-engine|none   ← ✅ values verified 2026-07-31 (default: none)
# Everything else:
xcrun coreai-build compile --help      # ← run 2026-07-31; capture in
#   notes/sdk-interfaces/coreai-build-help-27.0-beta.txt
#   (subcommands: compile|package|inspect|metadata)
# ⚠️ coreai-build ships in the Metal Toolchain COMPONENT, not Xcode-beta.app —
# the xcodebuild -downloadComponent step above is mandatory, and use
# `xcrun --no-cache --find coreai-build` if plain `xcrun --find` fails (stale
# cache). The bundle's own `usr/bin/aimodelc` is only a stub. See §13.
```

### Decision table

| Situation | Do this |
|---|---|
| Model ships in the app bundle, small (< ~100 MB) | Just `AIModel(contentsOf:)`. Gate with `model(for:options:)` anyway; it costs nothing |
| Model ships in the app bundle, large | AOT-compile at build time; gate the UI; consider `.persistent` |
| Model is downloaded | Feature-intro screen → opt-in → Background Assets → `specialize(…, cachePolicy: .persistent)` |
| You want to delete the source to save space | `specialize` → `bookmarkData` → persist a **record** (§9) → delete source |
| Model shared with an extension | `AIModelCache(appGroup:)` + entitlement + the model in the shared container |
| Two models, one foreground one background | Background one on `.cpuOnly` so it doesn't contend for the GPU |
| Model takes varying input shapes | Bucket the shapes; consider `expectFrequentReshapes` **only** if shapes truly vary |
| Model has fixed shapes | Do **not** set `expectFrequentReshapes` |
| Shipping a new model version | `deleteEntries(for:)` → replace file → `specialize(…, .persistent)` |
| A load is wedged | The §17 ladder: validate → probe → load → delete+retry → fall back to `.default` |
| Targeting pre-A17-Pro iPhones | There is no `.aimodelc` for them. Ship the portable `.aimodel` and gate hard |

### The six things most likely to bite you

1. **The Metal Toolchain is a separate download**, and without it your build fails with a Metal
   compiler error that does not mention Core AI. (§15)
2. **Changing `SpecializationOptions` silently creates a second multi-GB cache entry.** Compute
   options in exactly one function. (§4)
3. **A bookmark does not pin the cache entry**, and a stale one returns `nil` rather than throwing —
   so the failure is a silent `else` branch, not an error. (§9)
4. **`expectFrequentReshapes = true` on a static graph** was device-measured to discard the AOT
   specialization and recompile on device, with no diagnostic. (§11)
5. **`coreai-build compile` exits 0 for architectures the device will reject.** Only a device load
   validates the choice. (§13)
6. **Your export host's OS version changes the artifact's performance** by ~2× in one measured case,
   with no warning anywhere. (§16.3)

---

## 19. Sources and evidence ledger

### Primary — SDK module interfaces (strongest; captured 2026-07-29)

The shipped `.swiftinterface` files from the Xcode 27.0 beta (27A5228h) macOS 27.0 SDK, stored
under `notes/sdk-interfaces/`. `CoreAI` is an umbrella (`@_exported import CoreAIDelegates`);
`CoreAIDelegates` re-exports `CoreAIAsset`/`CoreAICommon`/`CoreAICompiler`/`CoreAIRuntime` and
itself declares the entire loading, caching and options surface this guide covers
(`CoreAIDelegates-27.0-macos.swiftinterface:14-122`). `CoreAICache`, `CoreAICommon` and
`CoreAICompiler` have empty public Swift surfaces in this beta — in particular, the on-device
specialization cache has **no public API in a `CoreAICache` module**; everything public is
`AIModelCache` in `CoreAIDelegates`. Used for: closing the error-type gap (§3), confirming every
declaration in §18, and the `purgeConditions` settability discrepancy (§6).

### Primary — Apple documentation (strongest doc-class evidence; there is no sample code)

| Source | Used for |
|---|---|
| `/documentation/coreai/managing-model-specialization-and-caching` | The definition of specialization; the cache-probe, pre-specialize, delete, app-group and bookmark code; the three purge conditions; the `specialize` ≠ AOT distinction |
| `/documentation/coreai/compiling-core-ai-models-ahead-of-time` | The `coreai-build` command and its six documented tokens; per-arch output naming; the Apple-Intelligence hardware gate; the residual-specialization caveat; the Background Assets recommendation |
| `/documentation/coreai/integrating-on-device-ai-models-in-your-app-with-core-ai` | Compile Sources; the Metal Toolchain requirement and both install paths; `import CoreAI`; the `"main"` default function name; the model viewer |
| `/documentation/coreai/aimodel` + children | `init(contentsOf:options:)`, `init?(resolvingBookmark:)`, `specialize(…)`, `bookmarkData`, `deviceArchitectureName`, `loadFunction`, the lightweight-instance note |
| `/documentation/coreai/aimodelcache` + children | Every cache method; `Policy`; `PurgeConditions`; the app-group initializer; **the deletion NOTE that contradicts the article** |
| `/documentation/coreai/specializationoptions` + children | `.default`, `.cpuOnly`, `init(preferredComputeUnitKind:)`, the get-only properties, `expectFrequentReshapes`'s one-line abstract |
| `/documentation/coreai/computeunitkind` | The three cases and `availableKinds` |
| `/documentation/coreai/aimodelasset` + children | `isValid(at:)`, `summary(includingStatistics:)`, `updateMetadata`, the "inspect without specializing" motivation |
| `/documentation/coreai/monitoring-model-performance-with-the-debug-gauge` | Three event types and their colours; the direct-linkage requirement; the open-the-report-first gotcha |
| `/documentation/coreai/analyzing-model-runtime-performance-with-instruments` | Four event categories and their colours; "at most one Specialization event"; the frequent-Load-events signal; the event labels |

⚠️ **Verified absences.** `/documentation/updates/coreai` returns **404**; the Updates hub contains
zero Core AI mentions; and the Core AI symbol index contains **0 `sampleCode` entries** across all
**312** paths. There is no first-party Core AI sample project to check this guide against.

### Primary — Apple's shipped repositories

| Source | Used for |
|---|---|
| `apple/coreai-models` — `swift/Sources/CoreAIShared/Runtime/ModelStructure.swift` | The structure→options mapping (`.neuralEngine` for static/segmenter, `.gpu` + `expectFrequentReshapes` for dynamic); `GraphNames`; the probe-before-specialize pattern and its comment |
| `apple/coreai-models` — `swift/Sources/CoreAIShared/Bundle/ModelBundle.swift` | The post-AOT `metadata.json` hand-edit message; `.pointedAtModelAsset` and why `.aimodelc` is a directory with its own metadata |
| `apple/coreai-models` — diffusion pipeline `resolveAsset(at:name:)` | `.aimodelc` transparently substituting for `.aimodel` |
| `apple/coreai-models` — `CoreAISegmentation` / `CoreAIObjectDetection` | `warmup()` and `warmup(imageCount:parameters:)` as shipped API |
| `apple/coreai-models` — `references/guidance.md` (Apple's own agent skill) | *"Keep models under 2 GB"* (iOS), *"Leave at least 6 GB of RAM headroom"* (macOS), `os_proc_available_memory()`, and *"use `.default` specialization options unless you deliberately pin a compute unit"* |
| `apple/coreai-torch` v0.4.1 release notes | The 0.4.0 → beta-2 load/specialize failure gate |
| `coreai-core` v1.0.0b2 release notes | `save_asset` now records a **producer** in asset metadata — the version-stamping hook |
| `apple/coreai-models` issues #58, #112, #55, #27, #77 | The bundle-directory error; the Increased Memory Limit / Console.app finding; the ANE pre-compiler SIGSEGV; the macOS `.aimodelc` load regression; the memory-pressure thread |

### Primary — WWDC26 transcripts

| Session | Used for |
|---|---|
| **324 — "Meet Core AI"** | The two-phase description (*"segment, plan and optimize compute"* / *"executable artifacts… tied to the device and OS version"*); *"compilation is the one which incurs most of the latency"*; the three levers; *"avoid having model specialization occur within user interactive flows"* |
| **326 — "Integrate on-device AI models into your app using Core AI"** | The failing demo and the Instruments signature; the rejection of launch-time and background warming; the first-run-experience recommendation; the "over 1 GB" bundling figure; Background Assets; the AOT narration |

### Community — valuable, uniquely detailed, and **not Apple**

> ⚠️ Everything in this block is community-measured on **beta** software under conditions the
> authors themselves describe as uncontrolled. It is cited because in several cases it is the only
> measurement that exists. It is never presented as an Apple figure, and no guidance in this guide
> depends on it alone.

| Source | Used for | Marker |
|---|---|---|
| `john-rocky` Core AI model zoo — `aot-and-specialization.md` | 19.2 s → 4.9 s AOT A/B; the `expectFrequentReshapes` SIGSEGV incident; architecture names tracking the **device identifier** (`iPhone18,1` → `h18p`); *"compile EXITs 0 for ANY requested arch"*; the community `--help` synopsis; the 1.8 GB load-succeeds/run-jetsams result | Community-measured, 2026-06/07 |
| `john-rocky` — `apple-models-bench.md` | qwen3-4b ANE **194 s** cold load; qwen3-0.6b 2.85 s / 0.045 s; gpt-oss-20b 13.2 s / 2.1 s; **the macOS 26 vs 27-beta export A/B (2.2×)** | Community-measured, 2026-07 |
| `john-rocky` — `dense-int4km-flagship-session-findings.md` | Qwen3.6-35B int4 (18 GB) jetsam during a ~26-minute cold compile; the non-fatal `ANECCompile() FAILED` observation | Community-measured, 2026-07 |
| [Frozen Noema 3.5 snapshot](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md) (shipping community iOS app) | The cache-first load with delete-and-retry recovery; per-folder `SpecializationOptions` derivation; prefill shape bucketing; the prewarm rule and its host-cache exception; *"each `SpecializationOptions` change leaves its own multi-GB entry behind"* | Historical community-authored source |

### Open gaps carried by this guide

| # | Gap | What would resolve it | Section |
|---|---|---|---|
| 1 | ~~The error type thrown by `AIModel.init`, `loadFunction`, `run`, and the cache `delete*` methods~~ **CLOSED 2026-07-29 by the SDK interface dump: untyped throws; `AssetError` is the only public error type in the beta SDK** | — | §3 |
| 2 | ~~Deletion while an `AIModel` is live: throws (reference) or defers (article)?~~ **CLOSED and reverified 2026-09-16 on stable Mac and iOS build `24A435`: throws while referenced, remains findable, succeeds after release** | Re-run on later releases to detect drift | §7 |
| 3 | Cancellation semantics of `specialize` / `init(contentsOf:)` — current fixture completed after ~10 s and left a cache entry on Mac/device, so the result is inconclusive | Cancel a genuinely long-running specialization and inspect the cache | §5 |
| 4 | **Cache location/size is undocumented; Mac/device lanes reproduced `Library/Caches/coreai-cache` and 12,288-byte source → 24,576-byte growth** | Repeat across realistic models/devices; a public size/enumeration API | §6 |
| 5 | The exact composition of `.default` / `.persistent` in terms of `PurgeConditions` | Printing the raw values, or Apple documenting them | §6 |
| 6 | Whether the `AIModel` returned by `specialize(…, cache: groupCache)` is backed by the group entry (**default-cache equivalent closed: identical 181-byte bookmarks**) | Repeat the bookmark comparison in an entitled app-group target | §8 |
| 7 | **`expectFrequentReshapes`: semantics, cache-key participation, and interaction with `--expect-frequent-reshapes`** — spelling is SDK-verified; `.default` and `.cpuOnly` both measured `false` on an iPhone 15 Pro, 2026-08-20 | A controlled static/dynamic A/B; Apple documentation for the semantic contract | §11 |
| 8 | ~~The full `coreai-build` CLI surface, `--preferred-compute` values, architecture codes, and any subcommands beyond `compile`/`package`~~ **CLOSED 2026-07-31: `coreai-build` ships in the Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`), not Xcode-beta.app; `--help` captured (`notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`) — subcommands `compile`/`package`/`inspect`/`metadata`, `--preferred-compute {gpu, neural-engine, none}`, 24 architecture codes enumerated by probing** | — | §13 |
| 9 | What `--platform watchOS` / `--platform tvOS` produce, given the AOT hardware gate names neither (narrowed 2026-07-31: tvOS accepts codes `h11p`/`h14p` per the validation probe; watchOS accepted none of the swept codes on a macOS 26.5 host) | Running the compile on a real `.aimodel` and reporting the output | §14.1 |
| 10 | **Whether iOS can JIT a portable `.aimodel` at all**, or whether the reported `Code=2` failures are purely platform-tag mismatches | Export a small model `--platform iOS`, load the **uncompiled** asset on an iPhone | §14.4 |
| 11 | Whether the macOS 26 vs 27 export-lowering regression is a beta bug, a deliberate change, or model-specific | Independent reproduction on a second model and a later build | §16.3 |

### Where to go next

- **Reference 01 of this part** — `AIModel`, `InferenceFunction`, `NDArray`, descriptors, views and
  the ownership model. Read it if any signature above looked unfamiliar.
- **Reference 03 of this part** — states, `ComputeStream`, `AsyncValue`, pipelined decode. Read it
  if your model has states, because a state's shape is one of the things that gets specialized.
- **Part 8** — producing the `.aimodel`. The single biggest lever on specialization cost is the
  *structure* of the exported model (§10), and that is decided during conversion, not at load.
- **Part 10** — the Core AI Debugger, the debug gauge and the Instruments template in depth,
  including how to read a specialization trace properly.
- **Part 15** — shipping and operating: Background Assets delivery, model updates, and the
  operational side of everything in §9 and §16.

---

*Guide last revised 2026-09-16, against the captured Xcode 27 beta-5 interface plus stable macOS 27
and iOS build `24A435` runtime probes. The selected SDK is still beta-era; re-verify signatures
against a coherent shipping Xcode before relying on them.*

[^scalar-type-count]: Apple’s current `NDArray.ScalarType` reference enumerates 35 cases:
    [Apple Developer — `NDArray.ScalarType`](https://developer.apple.com/documentation/coreai/ndarray/scalartype-swift.enum).

[^sample-routing-policy]: The classifier and preferences are source code in the optional
    `apple/coreai-models` package’s pinned
    [`ModelStructure.swift`](https://github.com/apple/coreai-models/blob/5ed9981303b38d5a44aa6b45509bc4f6945029f5/swift/Sources/CoreAIShared/Runtime/ModelStructure.swift#L12-L218),
    whereas Core AI separately documents `.default` as selecting the compute-unit combination that
    minimizes latency: [Managing model specialization and caching](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/docs/Managing%20model%20specialization%20and%20caching.md).
