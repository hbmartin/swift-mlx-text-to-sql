# `AIModel`, `InferenceFunction`, `NDArray`, and the memory model

**Part 7 · Core AI: the Swift runtime · Reference 01**

**Version floor: everything in this guide is 27.0 and only 27.0.** `import CoreAI` requires
**iOS 27.0 · iPadOS 27.0 · macOS 27.0 · Mac Catalyst 27.0 · tvOS 27.0 · visionOS 27.0 ·
watchOS 27.0**, all marked **Beta** in Apple's documentation as of this writing (2026-07-27).
There is no back-deployment: Core AI is a *new framework* in the 27 cycle, not a rename of
Core ML, and nothing here exists on a 26.x SDK.

> ⚠️ **No Simulator destination in this beta.** ✅ **Probe-verified, 2026-07-31** (`probes/`
> package, Xcode 27.0 beta): `CoreAI.framework` and all six of its SubFrameworks are present in
> `iPhoneOS27.0.sdk` and **ABSENT from `iPhoneSimulator27.0.sdk`** — `canImport(CoreAI)` is false
> for a simulator build, so Core AI code cannot even *compile* for that destination, let alone run.
> Gate any shared target with `#if canImport(CoreAI)` and plan on device (or Mac) testing only. Three APIs are narrower than the framework *per
the doc pages* — `NDArray.RawView.init(metalBuffer:…)`, `InferenceFunction.AsyncValue.init(unsafeBuffer:…)`
and `ComputeStream.init(commandQueue:)` **drop watchOS** — and are marked as such where they
appear. (⚠️ The captured macOS 27.0 beta SDK interface declares all three `watchOS 27.0`; see
§16.3 for the discrepancy.)
Build with **Xcode 27**, and install the **Metal Toolchain** (see §0.3) or your first build with a
`.aimodel` in it will fail.

---

## What this covers

This is the object-model primer that every other Core AI guide in this series assumes. Four types
carry the whole framework:

```
.aimodel  ──specialize──▶  AIModel  ──loadFunction──▶  InferenceFunction  ──run──▶  NDArray
(portable source)          (device-specific)           (one compute graph)          (your data)
```

Read this guide to learn:

- **What a `.aimodel` actually is** — a portable *source* representation, and a directory, not a
  file — and why that single fact explains the shape of the loading API.
- **Why `AIModel.init(contentsOf:options:)` is `async`.** Not because I/O is slow. Because
  specialization has to finish before a valid `AIModel` can exist.
- **`loadFunction(named:)` returns an Optional *and* throws**, and the two failure modes mean
  completely different things. Most first-draft Core AI code gets this backwards.
- **`InferenceFunction` is `Sendable`** — you can call the same function from many tasks — and the
  memory that quietly costs you.
- **Runtime introspection**: `InferenceFunctionDescriptor` → `InferenceValue.Descriptor` →
  `NDArrayDescriptor`, and the reason Apple built it: so your app can adapt to a model whose
  signature changes between deployments *without changing code*.
- **`NDArray` in depth.** This is the part readers find hardest, and it is hard for a real reason:
  Core AI is one of the heaviest adopters of Swift's non-escapable-types machinery in the whole
  SDK. `Span`, `MutableSpan`, `RawSpan`, `InlineArray`, value generics (`<let rank: Int>`),
  `consuming`/`borrowing`, typed throws — all of them show up in `NDArray`'s signatures. Section 7
  teaches what non-escapable means, why Apple used it here, and what it buys you.
- **The three low-level performance APIs** WWDC26 session 324 lists and barely explains: querying
  the preferred memory layout and allocating to match; pre-allocating output buffers; and
  `AsyncValue` + `ComputeStream` pipelining.
- **Image-typed inputs and outputs** — `CVMutablePixelBuffer`, `ImageDescriptor` — and the fact
  that image orientation is *entirely your problem*, which Apple's own repository demonstrates by
  getting it wrong two different ways.
- **The error-type answer** — settled against the macOS 27.0 beta SDK interface: the runtime's
  throws are untyped, `AssetError` is the only public error type, and §13 shows the `catch` block
  that follows from that.

## What this does *not* cover

- **Specialization scheduling, `AIModelCache`, bookmarks and AOT compilation.** Covered by the
  specialization-and-caching guide in this part. This guide touches specialization only where it
  explains an API shape (§3).
- **States / KV caching as a modelling technique.** `states:` appears here as a `run` parameter
  (§10); the authoring side, cache growth strategies and prefix reuse live in this part's states
  guide and in [Part 3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/README.md).
- **Converting a PyTorch model.** [Part 8](../../part-08-coreai-pytorch-conversion/README.md).
- **Scalar types, quantization and palettization** — why `NDArray.ScalarType` has `uint1` through
  `uint7` and `float8e8m0fn`. [Part 9](../../part-09-coreai-compression-numerics/README.md).
- **The Debugger, the debug gauge and the Instruments template.**
  [Part 10](../../part-10-coreai-hardware-authoring-debugging/README.md).

## What you need

- **Xcode 27** and the **Metal Toolchain component** (§0.3). Without it, any target containing a
  `.aimodel` fails to build with a missing-Metal-compiler error.
- A `.aimodel` to point at. If you don't have one, the fastest source is Apple's
  [`apple/coreai-models`](https://github.com/apple/coreai-models) repository, which ships export
  recipes for ~22 model families.
- A **real device** for anything you intend to trust. Specialization output is tied to the exact
  device *and* OS version.
- No prior Core ML knowledge. Core AI is not Core ML and shares no API surface with it. Apple
  explicitly routes decision trees and tabular feature engineering back to Core ML; Core AI is for
  neural networks.

---

## ⚠️ Read this before you trust a single signature below

Core AI has **zero Apple sample-code projects.** This is not a research gap on our side; it is
verified:

> ✅ **VERIFIED** — Apple's own documentation index at
> `https://developer.apple.com/tutorials/data/index/coreai` enumerates **312 symbol and page
> entries** (1 module, 7 articles, 2 collections, 31 structs, 6 enums, 3 classes, 3 protocols, 100
> properties, 56 methods, 53 cases, 42 inits, 8 subscripts). Filtering that index for
> `type == "sampleCode"` returns **zero entries**. Separately,
> `https://sosumi.ai/documentation/updates/coreai` returns **HTTP 404** — there is no Core AI
> release-notes page at all, and the `/documentation/updates` hub contains zero `coreai` mentions.
> Harvested 2026-07-27.

For Parts 1–6 of this series, the strongest evidence class was a *compiling Apple sample project*.
Here there is none. So the evidence ladder used in this guide is, strongest first:

1. **Shipping source on disk** — the Swift in `apple/coreai-models`, which is Apple-authored code
   that calls these APIs for real. When Apple's own package and Apple's own prose disagree, the
   package wins, because the package compiles.
2. **Apple's agent skills** in `apple/coreai-models/skills/` — Apple's own empirical rules,
   written for coding agents, and unusually blunt.
3. **Apple documentation pages**, including the raw DocC JSON, which preserves content that the
   rendered pages and Markdown mirrors drop.
4. **WWDC26 session transcripts** — 324 *"Meet Core AI"* and 326 *"Core AI app features"*. Spoken
   narration over code that is on screen but not in the transcript. Useful for *intent*, weak for
   spelling.
5. **Community repositories and issue threads**, always labelled as such.

Two consequences you should hold onto while reading:

- **Apple's own documentation code samples do not all compile.** Three of them are demonstrably
  broken (§16.2). Where this guide reproduces one, it says so and gives the corrected form.
- **Every marker in this guide is load-bearing.** ✅ VERIFIED means quoted from a source read this
  session, with the citation attached. 🟡 RECONSTRUCTED means the concept is attested but the exact
  spelling is inferred. 🔴 GAP means we could not verify it and are telling you rather than
  guessing — and every GAP box ends with a safe default you can ship today.

---

## Contents

- [0. Orientation: the pipeline, the file, the toolchain](#0-orientation-the-pipeline-the-file-the-toolchain)
- [1. The five types, and what each one owns](#1-the-five-types-and-what-each-one-owns)
- [2. `.aimodel` is a portable *source* representation](#2-aimodel-is-a-portable-source-representation)
- [3. `AIModel`: why the initializer is `async`](#3-aimodel-why-the-initializer-is-async)
- [4. `loadFunction` vs `functionDescriptor`: `nil` and `throws` mean different things](#4-loadfunction-vs-functiondescriptor-nil-and-throws-mean-different-things)
- [5. `InferenceFunction` is `Sendable` — and what that costs](#5-inferencefunction-is-sendable--and-what-that-costs)
- [6. Runtime introspection: descriptors all the way down](#6-runtime-introspection-descriptors-all-the-way-down)
- [7. `NDArray` and non-escapable types](#7-ndarray-and-non-escapable-types)
- [8. Writing inputs](#8-writing-inputs)
- [9. Reading outputs: `InferenceValue` and the take-once bag](#9-reading-outputs-inferencevalue-and-the-take-once-bag)
- [10. States and pre-allocated outputs: `MutableViews`](#10-states-and-pre-allocated-outputs-mutableviews)
- [11. The three low-level performance APIs](#11-the-three-low-level-performance-apis)
- [12. Image-typed values, and whose problem orientation is](#12-image-typed-values-and-whose-problem-orientation-is)
- [13. ✅ The error-type answer, and how to write a `catch` block](#13--the-error-type-answer-and-how-to-write-a-catch-block)
- [14. A complete runner you can paste](#14-a-complete-runner-you-can-paste)
- [15. Quick reference](#15-quick-reference)
- [16. Sources and evidence ledger](#16-sources-and-evidence-ledger)

---

## 0. Orientation: the pipeline, the file, the toolchain

### 0.1 The pipeline, end to end

```
PyTorch model
  │
  │  coreai-torch  (TorchConverter → AIProgram → save_asset)
  ▼
.aimodel                      ← portable SOURCE. A directory. Runs nowhere yet.
  │
  │  optional: xcrun coreai-build compile   (on your Mac, at build time)
  ▼
.aimodelc  (one per device architecture)    ← still not executable; just pre-compiled
  │
  │  SPECIALIZATION  (on the user's device, once, cached)
  ▼
specialized asset in AIModelCache
  │
  │  AIModel(contentsOf:options:)            ← async, because of the step above
  ▼
AIModel  ──loadFunction(named:)──▶  InferenceFunction  ──run(inputs:states:outputViews:)──▶  Outputs
```

Everything from `AIModel` rightward is this guide. Everything to the left is Parts 8–10.

### 0.2 The import, and the default function name

> ✅ **VERIFIED** — Apple's article *"Integrating on-device AI models in your app with Core AI"*
> (`/documentation/coreai/integrating-on-device-ai-models-in-your-app-with-core-ai`), verbatim:
>
> ```swift
> import CoreAI
>
> // Specialize the model for this device and load it.
> let model = try await AIModel(contentsOf: urlOfModel)
>
> // Load a function from the model.
> guard let function = try model.loadFunction(named: "main") else {
>     // Handle case where expected function is not found.
> }
> ```

The module is **`CoreAI`** (framework identifier `CoreAI`, documentation slug `coreai`). The
conventional entry-point function name is **`"main"`** — that is `coreai-torch`'s
`entrypoint_name` default, it is what the Instruments template calls out as "the default function
name", and it is the constant Apple's own Swift package hardcodes:

> ✅ **VERIFIED** — `apple/coreai-models`,
> `swift/Sources/CoreAIShared/Runtime/ModelStructure.swift:13-20`:
>
> ```swift
> public enum GraphNames {
>     public static let main = "main"
>     public static let loadEmbeddings = "load_embeddings"
>     public static let extendPrefix = "extend"
>     // Multi-function segmenter (lite SAM3 export for iOS).
>     public static let imageEncode = "image_encode"
>     public static let textEncode = "text_encode"
>     public static let detect = "detect"
> }
> ```

Note the snake_case. The WWDC26 session 326 narration says "imageEncode"; the actual graph name is
`image_encode`. Spoken camel-case in a transcript is a presenter reading a screen, not an API name.

### 0.3 The build-time footgun you will hit first

Before any of the code below runs, your project has to build, and the very first build of a target
containing a `.aimodel` fails on a stock Xcode install.

> ⚠️ **The Metal Toolchain is not installed by default.**
>
> ✅ **VERIFIED** — Apple's integration article, verbatim IMPORTANT callout: *"If the Metal toolchain
> isn't included, **builds that include `.aimodel` files fail with a missing Metal compiler
> error**."*
>
> Two fixes, both from the same page:
> - Xcode ▸ Settings ▸ Components ▸ Other Components ▸ **Get** next to *Metal Toolchain*; or
> - select any `.aimodel` in your project and click **Get** in the download bar that appears.
>
> From CI or a script:
>
> ```shell
> xcodebuild -downloadComponent MetalToolchain
> ```
>
> Also verified on the same page: after you add the file, *"you should also see the model in the
> **Compile Sources** build phase for that target."* If it landed in Copy Bundle Resources instead,
> move it.

A second, quieter one, if you plan to use the debug gauge later:

> ✅ **VERIFIED** — *"Monitoring model performance with the debug gauge"*, verbatim NOTE: *"**The
> gauge only appears in projects that link the Core AI framework. The gauge does not support the
> Core ML framework.**"* Transitive linkage through a Swift package is not enough — the framework
> must appear in **General ▸ Frameworks, Libraries, and Embedded Content** for the target you run.

---

## 1. The five types, and what each one owns

Session 324 introduces three types. There are really five you need on day one, and the thing that
makes the API make sense is asking *what owns memory*.

| Type | Kind | Owns | Lifetime you should give it |
|---|---|---|---|
| `AIModel` | `struct`, `Sendable` | **Nothing heavy.** A handle onto a cache entry. | One per model, for the app's life |
| `InferenceFunction` | `struct`, `Sendable` | **Weights and intermediate buffers.** | One per function, for the feature's life |
| `NDArray` | `struct`, `Sendable`, `Escapable` | Its own backing storage | Per call, or pre-allocated and reused |
| `NDArray.View<T>` / `MutableView<T>` | non-escapable view | Nothing — borrows the `NDArray` | The narrowest scope that compiles |
| `InferenceValue` | `struct` | An `NDArray` **or** a pixel buffer | Taken out of `Outputs`, consumed once |

The `AIModel`-owns-nothing point is stated outright by Apple and it is the single most useful fact
for structuring an app:

> ✅ **VERIFIED** — `/documentation/coreai/aimodel`, NOTE, verbatim: *"The model instance is
> lightweight and doesn't own weights or intermediate buffers. **Those resources belong to the
> functions you load from it.**"*

and, from the same page's overview:

> ✅ **VERIFIED**: *"An `AIModel` represents a specialized `.aimodel` asset, optimized for the
> current device's hardware."* … *"Use `functionDescriptor(for:)` to inspect a function's inputs
> and outputs, then load an `InferenceFunction` to run inference."*

Contrast that with `InferenceFunction`:

> ✅ **VERIFIED** — `/documentation/coreai/inferencefunction`, overview, verbatim: *"An
> `InferenceFunction` **owns the resources needed for inference, including model weights and
> intermediate buffers.** You load a function from an `AIModel` and call
> `run(inputs:states:outputViews:)` to perform inference."*

So the memory question — "when does this model actually cost me a gigabyte?" — has a precise
answer: **when you call `loadFunction`, not when you construct the `AIModel`.** That is also why
`AIModel` pins a cache entry (it is a handle to one) while holding it costs almost nothing, and
why the presenter's advice about *when* to construct these objects is what it is:

> ✅ **VERIFIED** — WWDC26 session 324, lines 71–77, verbatim: *"An **AIModel** is initialized from
> a URL to a `.aimodel` file and is used primarily to **inspect and load one or more inference
> functions**. An **InferenceFunction** is the runnable object which represents a **single loaded
> compute graph**. In the common case, your AIModel will only have a single main InferenceFunction,
> though **you can convert a single model with multiple functions**. The AIModel and
> InferenceFunction are typically objects you'll construct when **preparing your app's AI feature.
> For example this could be on app initialization.**"*

### 1.1 There is a sixth type, and it is the one people miss

`AIModelAsset` is listed under "Essentials" alongside `AIModel` and never appears in a single Apple
code sample. It is the *unspecialized* view of the same file:

> ✅ **VERIFIED** — `/documentation/coreai/aimodelasset`, verbatim: *"An unspecialized source model
> asset."* … *"Use a model asset to inspect a model's structure and metadata **without specializing
> it** for a specific device. This lets you query model information **without performing
> specialization, which is an expensive operation**."* … *"Unlike `AIModel`, a model asset can't
> perform inference."*
>
> ```swift
> init(contentsOf url: URL) throws            // note: NOT async — no specialization
> static func isValid(at url: URL) -> Bool
> var metadata: AIModelAsset.Metadata { get }
> func summary(includingStatistics: Bool) throws -> AIModelAsset.Summary?
> let url: URL
> mutating func updateMetadata(_ updates: (inout AIModelAsset.Metadata) throws -> Void) throws
> mutating func removeDerivedArtifacts() throws
> ```

The `throws`-not-`async throws` initializer is the tell: no specialization happens, so there is
nothing to await. And this is not a theoretical API — it is how Apple's own package decides *how*
to specialize before it specializes:

> ✅ **VERIFIED** — `apple/coreai-models`, `PreparedModel.prepare(at:)`:
>
> ```swift
> let asset = try AIModelAsset(contentsOf: url)
> let summary = try asset.summary(includingStatistics: false)   // probe function names WITHOUT specializing
> let model = try await AIModel(contentsOf: url, options: probedStructure.specializationOptions)
> ```

That two-phase load — *probe cheaply, then specialize with the right options* — is the single most
reusable pattern in Apple's Core AI Swift code, and §4.3 shows why the options it picks matter so
much.

> ⚠️ Pass `includingStatistics: false` unless you actually want the numbers. Apple: *"**Including
> model statistics is considerably slower for large models.**"* With `false` you get "only version
> information and function signatures" — which is exactly what a structure probe needs.

---

## 2. `.aimodel` is a portable *source* representation

Everything about the loading API follows from one sentence, said the same way in the transcript and
in the docs.

> ✅ **VERIFIED** — WWDC26 session 324, lines 141–147, verbatim: *"One thing that was glossed over
> in the snake game implementation is the process of **model specialization**. When you **ship an AI
> model with your app, that is a source representation of the model, which can be run on any Apple
> device**. However, **to actually load and run the model within your app, it must be specialized
> for the device that the app is running on**. When your model is loaded it is **checked to see if
> it has already been specialized and cached**. The specialization process **can take a significant
> amount of time for very large models**. While future loads are from the cache and fast, **that
> first time is something you may need to plan for**. **It is recommended you avoid having model
> specialization occur within user interactive flows.**"*

> ✅ **VERIFIED** — *"Managing model specialization and caching"*, verbatim: *"The `.aimodel` file
> contains your model in a **portable format that works across Apple devices**. Before the model can
> run, Core AI specializes it for the current device, producing **executable code tied to that
> device's hardware and OS version**."*

Three consequences that will bite you if you skip them:

**(a) A `.aimodel` is not a program.** It is closer to LLVM IR than to a `.dylib`. Nothing in it
runs until specialization produces device-specific executable artifacts. This is why there is no
"just mmap and go" path, and why the initializer is `async` (§3).

**(b) A `.aimodel` is a directory, not a file.**

> ✅ **VERIFIED** — `apple/coreai-torch` docs, `construct-a-graph.ipynb:164`: *"`AIProgram.save_asset(path)`
> writes the program out as an `.aimodel` **directory**"*, and `:192`: *"An `.aimodel` is a
> directory."* Corroborated on the Swift side: `AIModelAsset(contentsOf:)`'s parameter doc says
> *"the URL of an `.aimodel` **bundle** on disk"*, and Apple's Python export pipeline calls
> `shutil.rmtree(aimodel_path)` when overwriting.

Finder and Xcode present it as a bundle, so you may never notice — until you write a file-size
calculation, a copy, or a download-and-unpack path. Apple's own helper is recursive for exactly
this reason:

> ✅ **VERIFIED** — `apple/coreai-models`, `CoreAIShared/Runtime/FileSize.swift:17`:
> `extension URL { public func recursiveFileSizeInBytes() -> Int? }`, doc comment: *"This reflects
> bytes on disk, not resident memory."*

**(c) Specialized output dies on every OS update, unconditionally.**

> ✅ **VERIFIED** — `AIModelCache.Policy` overview NOTE, verbatim: *"**Regardless of policy, the
> system always purges assets when the OS updates**, as specialized assets are OS-version specific."*

So "the model is already prepared" is never a permanent state. Design the first-run experience you
will need after every point release. The specialization-and-caching guide in this part covers the
scheduling; what matters *here* is only that it explains the `async`.

### 2.1 The one place `.aimodel` and `.aimodelc` differ at the call site: nowhere

Ahead-of-time compilation produces a second extension, and the loading code is identical.

> ✅ **VERIFIED** — *"Compiling Core AI models ahead of time"*, verbatim: *"To load the downloaded
> `.aimodelc` asset, use `init(contentsOf:options:)`. **This is the same API you use to load
> `.aimodel` files, so you don't need to change your loading code when you adopt ahead-of-time
> compilation.**"* And: *"`init(contentsOf modelURL: URL, …)` — modelURL: The URL of a `.aimodel`
> **or `.aimodelc`** file."*

> ⚠️ AOT does **not** remove specialization. Apple, verbatim: *"**Even with ahead-of-time
> compilation, the compiled asset still requires some specialization on the device.**"* Nor does
> `AIModel.specialize(…)` reduce work: *"With `specialize`, **the full specialization process runs
> on the person's device. You are controlling *when* specialization happens, not *reducing the work
> it does*.**"* Two different levers, frequently confused.

---

## 3. `AIModel`: why the initializer is `async`

### 3.1 The full type

> ✅ **VERIFIED** — `/documentation/coreai/aimodel`. `struct AIModel`, conforming to `Sendable`,
> `SendableMetatype`.
>
> ```swift
> // Creating a model
> init(contentsOf modelURL: URL, options: SpecializationOptions = .default) async throws
> init?(resolvingBookmark bookmark: Data) throws
>
> // Loading inference functions
> func loadFunction(named functionName: String) throws -> InferenceFunction?
> func functionDescriptor(for functionName: String) -> InferenceFunctionDescriptor?
> var functionNames: [String] { get }
>
> // Specializing a model
> @discardableResult
> static func specialize(contentsOf modelURL: URL,
>                        options: SpecializationOptions = .default,
>                        cache: AIModelCache = .default,
>                        cachePolicy: AIModelCache.Policy = .default) async throws -> AIModel
>
> // Inspecting a model
> var bookmarkData: Data { get }
> static var deviceArchitectureName: String { get }
> ```

Eight members. That is the whole type. Note what is *absent*: there is no `run`, no `predict`, no
input dictionary. `AIModel` cannot perform inference; it is a directory of functions.

### 3.2 The `async` is not about I/O

The reason is stated once, plainly, and it is worth internalising because it changes how you
structure app startup:

> ✅ **VERIFIED** — Apple's integration article, verbatim: *"Core AI specializes the model for the
> current device, considering all available compute units and selecting the combination that
> delivers the best performance. **`init(contentsOf:options:)` is asynchronous because
> specialization needs to complete before a valid `AIModel` is returned.** Depending on the model
> size, specialization can take a significant amount of time."*

Read that again: the `await` is not hiding a disk read. It is hiding a **compiler**. Apple splits
specialization into two phases:

> ✅ **VERIFIED** — session 324, lines 162–173: *"During specialization, the model goes through
> **two main transformations**. **First, it goes through a core set of compilation steps which
> segment, plan and optimize compute.** **Second, executable artifacts are generated for the compute
> units used. These artifacts are tied to the device and OS version they were generated on.** Of
> these two steps, **compilation is the one which incurs most of the latency**."*

Session 326 repeats the same two-phase description almost word for word, which is a good sign that
it is the team's settled framing rather than one presenter's simplification.

**What that means for your code.** A `try await AIModel(contentsOf:)` on a cold cache is not a
"maybe 100 ms" await. Apple's own Instruments documentation shows a specialize event of roughly
**800 ms** in a screenshot; session 326's demo shows the same thing as a visible UI stall that the
presenter treats as a bug in her app, not in the framework.

> **Numbers, attributed.** Apple-published, from screenshots in *"Analyzing model runtime
> performance with Instruments"*: a `Compile Asset, Specialize` event spanning roughly 00:13.000 →
> 00:13.800 (~**800 ms**) with a nested `Compile segment` sub-event; `Load model::main`
> **10.54 µs**; `Setup for model::main` **66.96 µs** with a nested `Context.alloc` **22.83 µs**.
> Hardware tracks in the same trace are labelled `GPU (M3 Max)`, so read these as *an unnamed model
> on an M3 Max Mac, Apple's own capture, no model or build identified*. They are useful for **shape**
> — specialization is milliseconds-to-seconds, load and setup are microseconds — and useless as a
> budget for your model.

### 3.3 The load ladder, in the order you should write it

Putting §1.1 and §3.2 together gives a four-step ladder. Each step is cheap and answers a question
before you pay for the next one.

```swift illustrative
import CoreAI
import Foundation

// Step 0 — is this even a model asset? Cheap, synchronous, no throw.
guard AIModelAsset.isValid(at: modelURL) else { … }

// Step 1 — inspect WITHOUT specializing. Throws; does not await.
let asset = try AIModelAsset(contentsOf: modelURL)
let summary = try asset.summary(includingStatistics: false)   // -> AIModelAsset.Summary?

// Step 2 — has this (URL, options) pair already been specialized? Never specializes.
if let model = try AIModelCache.default.model(for: modelURL, options: options) {
    return model                                              // fast path: no await needed
}

// Step 3 — the expensive one. Show UI first.
let model = try await AIModel(contentsOf: modelURL, options: options)
```

> ✅ **VERIFIED** — `AIModelAsset.isValid(at:)` discussion, verbatim: *"This checks that: the URL is
> a file URL; the extension is one of the known model asset extensions; the model contains either a
> source program or a derived artifact."*

> ✅ **VERIFIED** — `AIModelCache.model(for:options:)` discussion, verbatim: *"If this cache holds a
> specialized asset from previously specializing the model at `modelURL` with the specified
> `options`, this method loads and returns the model. **This method never performs
> specialization.**"* Session 324, line 151: *"If **nil is returned, it is not present and requires
> specialization**. You can use this to **gate features or inform the users that they may need to
> wait a bit while your app prepares the model**."*

Apple ships this exact pattern as a code sample:

> ✅ **VERIFIED** — *"Managing model specialization and caching"*, verbatim:
>
> ```swift
> func loadModel(from modelURL: URL) async throws -> AIModel {
>     // The default cache stores all specialized assets for your app bundle.
>     let cache = AIModelCache.default
>
>     // A non-`nil` result means the model was previously specialized and cached.
>     if let model = try cache.model(for: modelURL, options: .default) {
>         return model
>     }
>
>     // No cached specialization exists. Inform the person and specialize now.
>     Task { @MainActor in
>         informUser("Preparing AI features. This may take a while…")
>     }
>
>     // This call performs specialization, caches the result, and returns the model.
>     return try await AIModel(contentsOf: modelURL, options: .default)
> }
> ```

> ⚠️ **The cache key includes the options.** `SpecializationOptions` is `Hashable`, and Apple states
> the key explicitly: *"**Each cache entry contains a specialized asset formed from a specific
> `.aimodel` or `.aimodelc` and `SpecializationOptions` combination.**"* If step 2 checks
> `.default` and step 3 specializes with `SpecializationOptions(preferredComputeUnitKind: .gpu)`,
> you will miss the cache **forever** and re-specialize on every launch — silently, because both
> calls succeed. Thread one `options` value through both, as the ladder above does.

### 3.4 `AIModel` is `Sendable`, and that is not free advice

`AIModel` conforms to `Sendable` and `SendableMetatype`. You can store one in an `actor`, pass it
across task boundaries, and hold it in a `@MainActor` view model without ceremony. Since it owns no
weights (§1), holding several is cheap — but each live `AIModel` **pins its cache entry**:

> ✅ **VERIFIED** — `AIModel.bookmarkData` NOTE, verbatim: *"Bookmark data is just data. It does not
> pin entries in the cache. **Only a `AIModel` will pin its associated entry in the cache while it
> is held.**"*

Which produces a contradiction in Apple's own documentation that you should know about before you
write a cache-eviction path:

> ⚠️ **Documentation conflict — deletion while an `AIModel` is alive.**
>
> The **reference pages** for all four `AIModelCache` delete APIs say, verbatim: *"For each entry,
> if no `AIModel` instance currently references it, deletion happens immediately. **Otherwise, an
> error is thrown.** Deletion can only occur for an entry when the last `AIModel` releases it."*
>
> The **prose article** says, verbatim: *"If an `AIModel` instance still uses a cache entry, Core AI
> **defers deletion** until that instance is deallocated."*
>
> Those are different contracts. **The iOS 27 beta build `24A5408d` runtime follows the reference
> pages:** on an iPhone 15 Pro, `deleteEntries(for:)` threw while a live `AIModel` retained the entry,
> the entry remained findable, and deletion succeeded after the model was released. The observed
> dynamic error was `AIModelCacheError.failedToPurge`, but that type is absent from the public beta
> interface, so keep a generic `catch`; see §13. Release, delete, and verify the cache lookup.

---

## 4. `loadFunction` vs `functionDescriptor`: `nil` and `throws` mean different things

### 4.1 The distinction, stated by Apple

```swift illustrative
func loadFunction(named functionName: String) throws -> InferenceFunction?
func functionDescriptor(for functionName: String) -> InferenceFunctionDescriptor?
var functionNames: [String] { get }
```

Look at those three signatures side by side. `functionDescriptor(for:)` **does not throw** — it
only answers "does a function with this name exist, and what is its signature". `loadFunction`
**both throws and returns an Optional**, and the two channels carry different information:

> ✅ **VERIFIED** — Apple's integration article, verbatim: *"Call `loadFunction(named:)` to get an
> `InferenceFunction` for running the model with your inputs and receiving its outputs. **Loading a
> function prepares the resources needed to run that function and can also be expensive.** The
> method **throws on a load failure, and returns `nil` when no function with that name exists.**"*

> ✅ **VERIFIED** — `functionDescriptor(for:)` return doc, verbatim: *"A descriptor for the function,
> **or `nil` if the model doesn't contain a function with the specified name**."* Discussion: *"Use
> the descriptor to inspect the function's inputs, outputs, and state names **before loading it for
> inference**."*

So:

| Outcome | Meaning | What you should do |
|---|---|---|
| returns a function | ✅ loaded, weights resident | proceed |
| returns **`nil`** | **the name is wrong.** The model has no such function. | a *programming* or *asset-versioning* bug. Log `functionNames`. Do not retry. |
| **throws** | the name was right; loading it failed. | a *runtime* failure — memory, a corrupt cache entry, an incompatible artifact. Degrading or retrying may be reasonable. |

Getting this backwards is the most common shape of broken Core AI code, because the ergonomic
temptation is to write `try? model.loadFunction(named:)` and collapse both channels into one
`nil` — which turns a recoverable runtime failure and an unrecoverable name typo into the same,
uninformative branch.

**Write it like this:**

```swift compile:27 imports:CoreAI
enum ModelSetupError: Error {
    case functionNotFound(requested: String, available: [String])
    case functionLoadFailed(name: String, underlying: any Error)
}

func loadMainFunction(from model: AIModel,
                      named name: String = "main") throws -> InferenceFunction {
    let loaded: InferenceFunction?
    do {
        loaded = try model.loadFunction(named: name)
    } catch {
        // The name existed; preparing its resources failed. Runtime problem.
        throw ModelSetupError.functionLoadFailed(name: name, underlying: error)
    }
    guard let function = loaded else {
        // No such function. Asset/version problem — surface what IS there.
        throw ModelSetupError.functionNotFound(requested: name,
                                               available: model.functionNames)
    }
    return function
}
```

The `available: model.functionNames` payload is the whole point. When someone hands you a
re-exported model six months from now and the entry point is `extend_4096_64` instead of `main`,
that array is the entire diagnosis.

> 🟡 **RECONSTRUCTED** — the `do`/`catch` split above is composed from the two verified sentences,
> not copied from an Apple sample; no Apple sample separates the channels. The **signatures** are
> ✅ VERIFIED; the error enum is mine. See §13 before you write anything narrower than
> `catch { … }` in that inner block.

> ⚠️ **A cross-language trap.** The Python runtime does *not* mirror this. ✅ VERIFIED —
> `apple/coreai-torch` docs, `construct-a-graph.ipynb:231`: Python's `ai_model.load_function("main")`
> **raises `KeyError`** when the name is missing. Swift returns `nil`. If you are porting a parity
> test from the notebook to Swift, the missing-name branch changes shape.

### 4.2 `functionDescriptor(for:)` is the pre-flight check

Because `loadFunction` is expensive and `functionDescriptor` is not, the descriptor is how you
validate an asset **before** paying for it. This matters most in the download-a-model case: you
have just fetched 600 MB over the network and you would like to know it is the model you think it
is before you specialize it.

```swift prelude:guide-context
// Cheap: no resources prepared, no weights resident.
guard let descriptor = model.functionDescriptor(for: "main") else {
    throw ModelSetupError.functionNotFound(requested: "main",
                                           available: model.functionNames)
}
// …validate descriptor.inputNames / shapes / scalar types here (§6)…
// Only now:
let function = try loadMainFunction(from: model)
```

### 4.3 `functionNames` and the multi-function model — a bigger deal than it looks

> ✅ **VERIFIED** — Apple's integration article, verbatim: *"Most models have a single function. **If
> the model contains multiple functions, check `functionNames` to see all available names.**"*

Session 324 mentions multi-function models in passing ("you can convert a single model with
multiple functions"). Session 325 presents splitting SAM 3 into `image_encode` / `text_encode` /
`detect` as a **latency** trick — run each at a different cadence, and the second inference is
*76% faster* (Apple-published, session 325, no hardware stated). But reading the optional
`apple/coreai-models` Swift package shows that its loader does something else as well:

> ✅ **VERIFIED** — `apple/coreai-models`,
> `swift/Sources/CoreAIShared/Runtime/ModelStructure.swift:70-81`:
>
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
>
> and the detection that feeds it: `extend*` + `load_embeddings` → `.chunkedStatic`;
> `image_encode` + `text_encode` + `detect` → `.multiFunctionSegmenter`; a bare `main` →
> `.dynamic`.

**For callers using this package’s `PreparedModel` helper, the set of names in `functionNames`
selects its compute-unit preference.** A single-`main` model receives the helper’s GPU preference
with `expectFrequentReshapes = true`; the recognized three-entrypoint form receives its Neural
Engine preference. Direct `AIModel` callers choose their own `SpecializationOptions`, and Core AI’s
`.default` is independent of these names.[^sample-routing-policy]

> ⚠️ **But Apple's own package does not cash the latency cheque for you.** ✅ VERIFIED —
> `CoreAISegmentationEngine.runMultiFunctionInference` **re-runs `image_encode` on every
> `segment()` call** and exposes no way to reuse `backbone_features`. The 76% figure requires
> caller-side caching of the encoder output that the shipped package does not do. If you adopt the
> multi-function pattern for latency, you are writing that cache. See
> [Part 16](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/README.md) for the vision-pipeline treatment.

> ⚠️ **`SpecializationOptions.expectFrequentReshapes` is real but undocumented.** ✅ VERIFIED as a
> mutable property in Apple's shipping Swift (above) and now ✅ **SDK-verified**
> (`CoreAIDelegates-27.0-macos.swiftinterface:100`): `public var expectFrequentReshapes: Bool`, the
> only settable property on the type. Its documentation page carries an abstract — *"Setting to
> allow more optimal specialization if the model performs frequent reshapes based on usage"* — and
> **no Discussion section at all**. The default remains **undocumented**, but it is no longer
> unmeasured: ✅ `probes/` printed **`false`** for both
> `SpecializationOptions.default.expectFrequentReshapes` and `.cpuOnly.expectFrequentReshapes` on
> a physical iPhone 15 Pro running iOS 27 beta 5 (`24A5408d`, 2026-08-20). On that device,
> `.default` allowed CPU + GPU + Neural Engine with no preferred unit; `.cpuOnly` allowed only CPU.
> Treat those as runtime evidence, not an API promise. Safe default: leave the flag alone unless
> your model has dynamic shapes that change every call, in which case follow Apple's own code and
> set it on a `var` copy of the options.

---

## 5. `InferenceFunction` is `Sendable` — and what that costs

### 5.1 The guarantee

> ✅ **VERIFIED** — `/documentation/coreai/inferencefunction`, overview, verbatim: *"This type is
> `Sendable`, so you can run it concurrently from multiple tasks. **The function automatically
> allocates additional intermediate buffers as needed to support concurrency.**"*

> ✅ **VERIFIED** — Apple's integration article, verbatim: *"**If your app processes multiple inputs
> simultaneously, you can safely call the same inference function from different tasks.**"*

This is a real, useful guarantee and session 326 leans on it: the macOS build of the
language-learning app parallelises segmentation across a folder of photos with no extra
synchronisation, because the *same* `InferenceFunction` is safe to hit from N tasks.

```swift prelude:guide-context
// Safe. One function, many tasks. No lock, no actor needed.
let results = try await withThrowingTaskGroup(of: (Int, [Float]).self) { group in
    for (index, image) in images.enumerated() {
        group.addTask {
            (index, try await self.classify(image))    // self.function is shared
        }
    }
    var out = [Int: [Float]]()
    for try await (i, v) in group { out[i] = v }
    return out
}
```

### 5.2 ⚠️ SILENT FAILURE: concurrency buys you memory you never asked for

> ⚠️ **SILENT FAILURE — parallelism silently multiplies your scratch footprint.**
>
> That second sentence in Apple's overview — *"The function automatically allocates additional
> intermediate buffers as needed to support concurrency"* — is a memory contract disguised as a
> convenience. Every concurrent `run` in flight needs its own intermediate buffers. The framework
> allocates them for you, **on demand, with no API to cap them, no callback, no warning, and no
> error.**
>
> The failure mode is not a thrown error. It is that a `TaskGroup` with unbounded width works
> beautifully on your M4 Max with 64 GB and gets jetsammed on an iPhone — or, worse, works on the
> phone with 4 images and dies at 9, because the growth is invisible until it isn't.
>
> **There is no "how much" in the documentation.** Intermediate-buffer size is model-dependent and
> unpublished.
>
> **Safe default: bound the width yourself.** Never write an unbounded `TaskGroup` over an
> `InferenceFunction`. Pick a small constant (2–4 on iOS), measure resident memory with the Core AI
> instrument and the Memory gauge, and treat the number as device-class-specific.
>
> ```swift
> // Bounded fan-out: at most `width` inferences in flight at once.
> func classifyAll(_ images: [CGImage], width: Int = 3) async throws -> [[Float]] {
>     var results = [Int: [Float]]()
>     try await withThrowingTaskGroup(of: (Int, [Float]).self) { group in
>         var next = 0
>         for _ in 0..<min(width, images.count) {
>             let i = next; next += 1
>             group.addTask { (i, try await self.classify(images[i])) }
>         }
>         while let (i, v) = try await group.next() {
>             results[i] = v
>             if next < images.count {
>                 let j = next; next += 1
>                 group.addTask { (j, try await self.classify(images[j])) }
>             }
>         }
>     }
>     return (0..<images.count).map { results[$0]! }
> }
> ```

Apple's own package independently arrived at the same conclusion for its GPU pipeline, with a
different mechanism and a very precise failure description:

> ✅ **VERIFIED** — `apple/coreai-models`, `CoreAIPipelinedEngine.swift`, `PipelineGate` doc comment:
> *"Without this, the decode loop submits encodes (~220/s) faster than the sampler callback drains
> them (~70/s); depth grows until `MPSCommandBufferImageCache` fails to allocate another private
> `MTLBuffer`."* The gate's capacity is `pipelineDepth`, a hardcoded **3**.
>
> Two numbers there — ~220 encodes/s produced against ~70/s consumed — are **Apple-authored source
> comments** in a shipping package, not a benchmark: no hardware, model or OS build is stated. Treat
> them as evidence that *the ratio can be 3×*, not as a figure for your workload.

Backpressure is not optional in this framework. Apple hardcodes 3; you should pick your own number
and measure it.

### 5.3 What is *not* safe

`Sendable` covers `InferenceFunction`. It does not cover the mutable state you thread through it.
`states:` (§10) reads and writes the arrays you pass in-place, so two concurrent `run` calls sharing
one KV cache are a data race that the type system will fight you about (`insert(_:for:)` takes
`inout`) but that you can still contrive with reference-typed backing storage. **One state set per
concurrent stream.** Apple's engines serialise generation with an explicit hand-rolled async mutex
for exactly this reason:

> ✅ **VERIFIED** — `1amageek/swift-lm` (⚠️ **community**, not Apple: single-author repo,
> `0.11.0-alpha.1`, HEAD `db7a802`, 2026-07-18), `CoreAIStateSession`:
>
> ```swift
> private func acquireExecution() async {
>     guard isExecuting else { isExecuting = true; return }
>     await withCheckedContinuation { continuation in
>         executionWaiters.append(continuation)
>     }
> }
> ```
>
> A hand-rolled async mutex, because actor reentrancy is not sufficient to serialise a stateful
> function. Apple's own `CoreAISequentialEngine` reaches the same place by a different route
> (`isBusy` + `drain()`).

---

## 6. Runtime introspection: descriptors all the way down

### 6.1 Why this exists

Apple states the motivation in one sentence, and it is more ambitious than "validate your inputs":

> ✅ **VERIFIED** — Apple's integration article, verbatim: *"You can use this descriptor to verify
> that a function accepts the inputs your app provides, or to **dynamically adapt your app's
> behavior as the model's inputs and outputs change between deployments, without needing to change
> your code**."*

That is the design goal: **your app should survive a model re-export.** If the model you ship in
version 1.4 takes a `[1, 3, 224, 224]` float32 image and the model you push over Background Assets
in 1.4.1 takes `[1, 3, 336, 336]`, code written against the descriptor keeps working; code written
against a hardcoded shape ships a bug to everyone who updates the asset but not the binary.

This is not hypothetical in a Core AI app, because the whole point of the `.aimodelc` +
BackgroundAssets pattern Apple recommends is that **the model updates independently of the app
binary**. Descriptor-driven code is what makes that safe.

### 6.2 The three-level descriptor chain

```
InferenceFunctionDescriptor           ← names + counts, per function
   └─ inputDescriptor(of:)  ──▶  InferenceValue.Descriptor      ← enum: image or ndArray?
        └─ case .ndArray  ──▶   NDArrayDescriptor               ← shape, scalarType, strides, dynamism
        └─ case .image    ──▶   ImageDescriptor                 ← pixel format, width, height
```

> ✅ **VERIFIED** — `/documentation/coreai/inferencefunctiondescriptor`. `struct
> InferenceFunctionDescriptor`, `Sendable`, `SendableMetatype`:
>
> ```swift
> var name: String { get }
>
> var inputCount: Int { get }
> var inputNames: [String] { get }
> func inputDescriptor(of inputName: String) -> InferenceValue.Descriptor?
>
> var outputCount: Int { get }
> var outputNames: [String] { get }
> func outputDescriptor(of outputName: String) -> InferenceValue.Descriptor?
>
> var stateNames: [String] { get }
> func stateDescriptor(of stateName: String) -> InferenceValue.Descriptor?
> ```
>
> Overview: *"Use a descriptor to inspect the names and types of a function's inputs, outputs, and
> states **before running inference**. You obtain a descriptor from `functionDescriptor(for:)` or
> from the `descriptor` property."*

Two asymmetries worth noticing, both real:

- There is **`inputCount` and `outputCount` but no `stateCount`.** Use `stateNames.count`.
- On `InferenceFunction`, `descriptor` is a **stored `let`**, not a computed property:
  ✅ VERIFIED — `let descriptor: InferenceFunctionDescriptor`. Reading it is free; cache it or
  don't, it doesn't matter.

> ✅ **VERIFIED** — `/documentation/coreai/inferencevalue/descriptor`:
>
> ```swift
> enum Descriptor: Sendable, SendableMetatype {
>     case image(ImageDescriptor)
>     case ndArray(NDArrayDescriptor)
> }
> ```
>
> Overview: *"You obtain descriptors from `InferenceFunctionDescriptor` to inspect what kind of
> value a function expects for each input or output."*

Exactly two cases. Core AI's entire I/O type system is "a tensor, or an image". There is no string
type, no dictionary type, no sequence type — tokenization and detokenization are your problem, on
the outside.

### 6.3 The canonical pattern, from Apple

> ✅ **VERIFIED** — Apple's integration article, verbatim:
>
> ```swift
> let function: InferenceFunction = ...
>
> let functionDescriptor = function.descriptor
> guard let valueDescriptor = functionDescriptor.inputDescriptor(of: "input"),
>       case .ndArray(let arrayDescriptor) = valueDescriptor else {
>         // Handle input not found, or an unexpected type.
> }
>
> guard arrayDescriptor.shape == [3, 4] else {
>     // Handle an unexpected shape.
> }
>
> guard arrayDescriptor.scalarType == .float32 else {
>     // Handle an unexpected scalar type.
> }
> ```

The `guard let … , case .ndArray(let x) = …` line is the idiom. You will write it dozens of times.
It does two jobs at once: "is there an input by this name" and "is it a tensor rather than an
image".

### 6.4 `NDArrayDescriptor`, and the `-1` sentinel

> ✅ **VERIFIED** — `/documentation/coreai/ndarraydescriptor`. `struct NDArrayDescriptor`,
> `Equatable`, `Sendable`, `SendableMetatype`:
>
> ```swift
> var shape: [Int] { get }
> var scalarType: NDArray.ScalarType { get }
> var rank: Int { get }
> var hasDynamicShape: Bool { get }
> var interleaveLayout: NDArray.InterleaveLayout? { get }
>
> var minimumByteCount: Int { get }
> var preferredStrides: [Int] { get }
>
> func resolvingDynamicDimensions(_ newShape: [Int]) -> NDArrayDescriptor
> ```
>
> Overview: *"The descriptor contains the expectations for an array value that you provide to an
> `InferenceFunction`. **Most expectations are strict**: for example, if the descriptor specifies
> `scalarType` as `.float32`, the array you provide must use `.float32`."*
>
> `shape` discussion: *"The shape contains `rank` elements. **A value of `-1` in any dimension
> indicates a dynamic size.**"*

> ⚠️ **`-1` in the API, `?` in Xcode.** ✅ VERIFIED — the Xcode model viewer's Functions tab shows a
> **question mark** for a dynamic dimension (*"A question mark in an `NDArray` dimension means the
> dimension is dynamic and is supplied or determined at runtime"*), while `NDArrayDescriptor.shape`
> reports **`-1`**. Same fact, two spellings; do not go looking for a `?` in your Swift.

Resolving a dynamic dimension is a pure function that returns a *new* descriptor:

> ✅ **VERIFIED** — `resolvingDynamicDimensions(_:)` discussion + example, verbatim:
>
> ```swift
> // The 'dynamic_shape_input' argument is a rank 3 ndArray with a dynamic shape for the final dimension.
> // ndArrayDescriptor.shape == [128, 128, -1]
>
> // Make a resolved descriptor which fills in the -1 dimension with the concrete value 10
> let resolvedDescriptor = ndArrayDescriptor.resolvingDynamicDimensions([128, 128, 10])
> ```
>
> NOTE: *"`newShape` must be the same size as the `shape` of the descriptor it is called on. Also
> for each dimension, it must hold true that the provided new shape either **matches the existing
> shape, or the existing shape is `-1`**."*

> ⚠️ **`preferredStrides` and `minimumByteCount` are *programming errors* on an unresolved
> descriptor.** ✅ VERIFIED, verbatim: *"Accessing this property on a descriptor for which
> `hasDynamicShape` is true, is a **programming error**. If the descriptor has a dynamic shape, you
> must first call `resolvingDynamicDimensions` to provide a concrete size for each dimension."*
> "Programming error" is Apple's language for *this may trap*, not *this returns garbage*. Always
> resolve first. Same rule for `NDArray.init(descriptor:)`: *"The descriptor's `hasDynamicShape`
> must be `false`."*

And do not reach for the obvious shortcut of mutating `shape`. Apple's own package explicitly
switched away from it:

> ✅ **VERIFIED** — `apple/coreai-models` PR #74, merged: *"Use `NDArrayDescriptor.resolvingDynamicDimensions(_:)`
> instead of modifying `NDArrayDescriptor.shape` directly — 'will check for validity of swapped
> shaped'."* (`shape` is `get`-only in the public API anyway; the PR title is the guidance.)

### 6.5 A reusable validator

Here is the descriptor pattern packaged so you write it once. Every member it touches is ✅ VERIFIED
above; the assembly is mine.

```swift compile:27
import CoreAI

/// What a call site needs to know about one tensor argument.
struct TensorContract: Sendable, Equatable {
    let name: String
    let shape: [Int]          // -1 for dynamic
    let scalarType: NDArray.ScalarType
    let isDynamic: Bool
}

enum ContractError: Error {
    case notFound(String, available: [String])
    case notATensor(String)                       // it's an image-typed argument
    case scalarTypeMismatch(String, expected: NDArray.ScalarType, actual: NDArray.ScalarType)
    case rankMismatch(String, expected: Int, actual: Int)
    case dimensionMismatch(String, axis: Int, expected: Int, actual: Int)
}

extension InferenceFunctionDescriptor {

    func tensorInput(_ name: String) throws -> TensorContract {
        guard let value = inputDescriptor(of: name) else {
            throw ContractError.notFound(name, available: inputNames)
        }
        guard case .ndArray(let d) = value else { throw ContractError.notATensor(name) }
        return TensorContract(name: name, shape: d.shape,
                              scalarType: d.scalarType, isDynamic: d.hasDynamicShape)
    }

    func tensorOutput(_ name: String) throws -> TensorContract {
        guard let value = outputDescriptor(of: name) else {
            throw ContractError.notFound(name, available: outputNames)
        }
        guard case .ndArray(let d) = value else { throw ContractError.notATensor(name) }
        return TensorContract(name: name, shape: d.shape,
                              scalarType: d.scalarType, isDynamic: d.hasDynamicShape)
    }
}

extension TensorContract {
    /// Check a concrete shape against this contract. `-1` axes accept anything.
    func validate(concreteShape: [Int],
                  scalarType actual: NDArray.ScalarType) throws {
        guard actual == scalarType else {
            throw ContractError.scalarTypeMismatch(name, expected: scalarType, actual: actual)
        }
        guard concreteShape.count == shape.count else {
            throw ContractError.rankMismatch(name, expected: shape.count,
                                             actual: concreteShape.count)
        }
        for (axis, expected) in shape.enumerated() where expected != -1 {
            guard concreteShape[axis] == expected else {
                throw ContractError.dimensionMismatch(name, axis: axis,
                                                      expected: expected,
                                                      actual: concreteShape[axis])
            }
        }
    }
}
```

The `where expected != -1` clause is the whole trick, and it is exactly what a community
implementation independently arrived at:

> ✅ **VERIFIED** — `1amageek/swift-lm` (⚠️ **community**), `CoreAIStateSession` input validation:
> checks *"unexpected inputs, missing inputs, non-NDArray inputs, `scalarType` equality,
> `shape.count == arrayDescriptor.rank`, and per-axis `expected == -1 || expected == actual`."*

### 6.6 Discovering names instead of hardcoding them

Apple's own package does not hardcode tensor names for its vision products; it *discovers* them. It
is worth knowing both approaches exist because they fail differently.

| Approach | Where Apple uses it | Fails how |
|---|---|---|
| **Positional** — `inputNames[0]` is `input_ids`, `[1]` is `position_ids` | `CoreAISequentialEngine` (validates `inputNames.count == 2`, `stateNames.count == 2`, `outputNames.count >= 1`, then indexes) | silently wrong if the exporter reorders |
| **Substring matching** — find the input whose name contains `text` | `ImageSegmentationEngine.findTextInputName` | silently wrong on an ambiguous name |
| **Literal names** — six hardcoded descriptor lookups | `WhisperDecoder`, `StaticShapeEngine` (`out_logits`, `key_cache`, `value_cache`) | throws loudly if the model changes |

> ✅ **VERIFIED** — all three patterns are in `apple/coreai-models`. `CoreAIStaticShapeEngine.swift`
> even carries the comment `// MARK: I/O name contracts — models must use these exact names`.

**Recommendation:** hardcode the names, validate them against `inputNames` at load, and put the
*discovery* logic behind a fallback. Positional indexing is the one to avoid: it is the only one of
the three that can be wrong without throwing.

---

## 7. `NDArray` and non-escapable types

This is the section readers find hardest, and it is worth slowing down for, because the difficulty
is not accidental complexity — it is a deliberate design choice that Apple called out from the
stage:

> ✅ **VERIFIED** — WWDC26 session 324, lines 66–70, verbatim: *"The Core AI framework is a new Swift
> API surface for loading and running Core AI models. It offers a **progressively disclosing set of
> APIs**, which makes it simple to get things up and running, while also having deeper layers of
> flexibility for supporting performance critical applications. Also, it uses modern Swift language
> features like **non-escapable types**, to offer memory-safe APIs while not sacrificing
> performance."*

### 7.1 What "non-escapable" means, in one page

A normal Swift value can be stored anywhere: in a property, in an array, captured by a closure that
outlives the current scope. That freedom is what forces Swift to *own* the memory behind it —
either by copying it or by retaining it. Both cost something.

A **non-escapable** type (`~Escapable`) gives that freedom up. The compiler tracks its lifetime and
refuses to let it outlive the thing it borrows from. In exchange, it doesn't have to own anything:
it can be a raw pointer plus a length, with **zero retain traffic and zero copying**, and still be
memory-safe, because the compiler has statically proven the pointer cannot dangle.

The standard-library carriers for this are `Span<T>` (read-only), `MutableSpan<T>`, `RawSpan` and
`MutableRawSpan`. Core AI's views are built on them.

So the two-line summary:

- **`NDArray`** is a normal, escapable, `Sendable` value that **owns** storage. Store it, pass it,
  keep it in a property.
- **`NDArray.View<T>` / `NDArray.MutableView<T>` / `RawView` / `MutableRawView`** are
  **non-escapable borrows** of that storage. Use them, don't keep them.

> ✅ **VERIFIED** — `/documentation/coreai/ndarray` conformance list: `NDArray` conforms to
> **`Escapable`**, `InferenceValue.MutableViewRepresentable`, `InferenceValue.ViewRepresentable`,
> `Sendable`, `SendableMetatype`.

> 📌 **A correction to a claim you may have seen.** It is sometimes said that "`NDArray` is a
> non-escapable type". It is not — Apple's conformance list says `Escapable` explicitly, and it is
> `Sendable`, which a non-escapable type could not usefully be. What session 324 actually says is
> narrower and correct: *"The **`NDArray.MutableView`** type is a **non-escapable type** which
> provides safe and efficient access to the backing storage of the NDArray"* (324:88–89). **The
> views are the non-escapable part.** Getting this backwards leads people to fight the compiler
> over the wrong type.

### 7.2 Read-only by default

```swift illustrative
func view<T>(as type: T.Type = T.self) -> NDArray.View<T> where T : BitwiseCopyable
mutating func mutableView<T>(as type: T.Type = T.self) -> NDArray.MutableView<T> where T : BitwiseCopyable
func rawView() -> NDArray.RawView
mutating func mutableRawView() -> NDArray.MutableRawView
```
> ✅ **VERIFIED** — `/documentation/coreai/ndarray`. Note which two are `mutating`.

The `mutating` keyword is doing real work here. It means:

```swift xfail:27 imports:CoreAI
let a = NDArray(shape: [3, 4], scalarType: .float32)
let r = a.view(as: Float.self)          // ✅ fine
var w = a.mutableView(as: Float.self)   // ❌ compile error: `a` is a `let`
```

You need `var input = NDArray(...)` to write into it. That is not a nuisance — it is the API
telling you, at compile time, which of your arrays are being written. Apple states the intent:

> ✅ **VERIFIED** — Apple's integration article, verbatim: *"For `NDArray` values, write input data
> with `MutableView` and read results with `View`. **Swift enforces this at compile time.** A
> mutable view allows writes, and a view allows only reads, **so you always know how your data is
> accessed**."*

Also note the defaulted type parameter — `as type: T.Type = T.self`. That is why Apple's sample can
write `prediction.view()` with no argument: `T` is inferred from the call site.

> ✅ **VERIFIED** — from Apple's own article, the no-argument form in context:
> ```swift
> // Read the output data through a view.
> processOutput(prediction.view())
> ```
> `T` is inferred from `processOutput`'s parameter type. Spell it out (`view(as: Float.self)`) when
> the call site does not pin it — an unspecified `T` in a generic context is a confusing error.

### 7.3 Creating an `NDArray`

> ✅ **VERIFIED** — all five initializers, `/documentation/coreai/ndarray`:
>
> ```swift
> init(shape: [Int], scalarType: NDArray.ScalarType)
> init(shape: [Int], scalarType: NDArray.ScalarType, strides: [Int])
> init(shape: [Int], scalarType: NDArray.ScalarType, strides: [Int], interleaveLayout: NDArray.InterleaveLayout)
> init<Scalar>(scalars: some Sequence, shape: [Int]) where Scalar : BitwiseCopyable
> init(descriptor: consuming NDArrayDescriptor)
> ```
>
> - `init(shape:scalarType:)`: *"This initializer creates an array with **contiguous, row-major
>   strides**."*
> - `init(shape:scalarType:strides:)`: *"The `shape` and `strides` arrays must have the same number
>   of elements."*
> - `init(scalars:shape:)` example, verbatim:
>   ```swift
>   var ndArray = NDArray(scalars: (0..<4) as Range<Int32>, shape: [2, 2])
>   // The resulting NDArray has contents:
>   [[0, 1], [2, 3]]
>   ```
>   with the parameter note: *"`Scalar` must be a type that corresponds to a scalar type found on
>   the `NDArray.ScalarType` enum"*, and *"The ndArray will be stored in row-major order and the
>   scalars will be assigned in row-major order."*

> ⚠️ **Do not assume shape-based allocation zero-initializes storage.** Six allocation rounds on
> stable macOS 27 and six on iPhone 15 Pro / iOS build `24A435` happened to read all zeroes, but the
> API does not promise initialization and the probe cannot prove it. Explicitly write every input
> and state element whose value matters. [Guide 7.3 §8.3](03-states-and-pipelined-execution.md#83-️-silent-failure--uninitialised-state-storage)
> owns the full evidence history and safe default.

`init(descriptor:)` is the one you will use in production, because it is how you get the
framework's preferred layout (§11.1) — and it comes with the most consequential doc note in the
whole type:

> ✅ **VERIFIED** — `init(descriptor:)` discussion, verbatim: *"**The resulting array may not have a
> contiguous layout.** The strides match the values returned by the descriptor's preferred strides,
> so **`contiguousElements` on a view of this array may return `nil`**. In that case, use
> `withUnsafePointer` or `withUnsafeMutablePointer` to access the data while respecting the
> strides."* … *"If the descriptor has an `InterleaveLayout`, the resulting ndArray will carry that
> interleave metadata."* … *"**The descriptor's `hasDynamicShape` must be `false`.** If the
> descriptor has dynamic shapes, call `resolvingDynamicDimensions(_:)` first."*

### 7.4 The read view: `NDArray.View<Element>`

> ✅ **VERIFIED** — `/documentation/coreai/ndarray/view`:
>
> ```swift
> struct View<Element> where Element : BitwiseCopyable
> init(span: Span<Element>, shape: [Int], strides: [Int])
>
> var isContiguous: Bool { get }        // "true if the elements … have a row-major contiguous layout"
> var rank: Int { get }
> var shape: Span<Int> { get }
> var strides: Span<Int> { get }
> var interleaveLayout: NDArray.InterleaveLayout? { get }
>
> var contiguousElements: Span<Element>? { get }
> subscript<let rank : Int>(scalarAt index: InlineArray<rank, Int>) -> Element { get }
>
> func withUnsafePointer<R, E>(_ body: (UnsafePointer<Element>, Span<Int>, Span<Int>) throws(E) -> R) throws(E) -> R
>
> func slice(at ranges: [any NDArray.RangeExpression]) -> NDArray.View<Element>
> func slice<let indexRank : Int>(at: [indexRank of any NDArray.RangeExpression]) -> NDArray.View<Element>
>
> var rawView: NDArray.RawView { get }
> ```

Every modern-Swift feature in one declaration: `Span`, value generics (`<let rank: Int>`),
`InlineArray`, the fixed-count array parameter syntax `[indexRank of any …]`, and typed throws
(`throws(E) -> R`). You do not need to *write* any of that to use the type — but you do need to
read it, because the compiler will echo it back at you in diagnostics.

**`contiguousElements` is the fast path, and it is optional for a reason.**

> ✅ **VERIFIED** — `contiguousElements` NOTE, verbatim: *"`contiguous` here refers to elements in
> row-major order with **zero padding**."*

Three things can make it `nil`: you built the array with explicit non-contiguous `strides`; you
built it from a descriptor whose `preferredStrides` were padded for hardware alignment (§11.1); or
the array carries an `InterleaveLayout`. In all three cases the data is fine — it is just not a
flat run of elements, so there is no single `Span` that can describe it.

Apple's own doc example, showing the "I know this one is contiguous" force-unwrap:

> ✅ **VERIFIED** — verbatim from `/documentation/coreai/ndarray/view/contiguouselements`:
>
> ```swift
> /// Returns the sum of the given row.
> func sumOfRow(
>   of view: borrowing NDArray.View<Float>,
>   row: Int
> ) -> Float {
>   let rowSlice = view.slice(at: [row])
>   let elements = rowSlice.contiguousElements! // contiguous row expected in this case
>
>   var sum: Float = 0
>   for i in elements.indices {
>     sum += elements[i]
>   }
>   return sum
> }
> ```

Two details to steal from that: the parameter is `borrowing` (a non-escapable view can't be
owned by the callee), and the loop uses `elements.indices` with subscripting rather than
`for x in elements` — which brings us to the single most surprising practical consequence of the
whole non-escapable design.

### 7.5 ⚠️ `Span` does not conform to `Sequence`

> ⚠️ **`Span` is non-escapable, so it cannot conform to `Sequence`.** No `map`. No `reduce`. No
> `filter`. No `for … in` over it as a `Sequence`. `shape` and `strides` come back as `Span<Int>`,
> and the obvious `shape.reduce(1, *)` to compute an element count **does not compile**.
>
> ✅ **VERIFIED** — this is not a guess; Apple hit it in their own package and wrote the workaround
> with the reason in a comment. `apple/coreai-models`,
> `swift/Sources/CoreAIShared/Runtime/NDArray+Helpers.swift`:
>
> ```swift
> /// `Span` doesn't conform to `Sequence` (non-escapable by design), so `.reduce` isn't available.
> extension Span where Element == Int {
>     var product: Int {
>         var result = 1
>         for i in 0..<count { result *= self[i] }
>         return result
>     }
> }
> ```
>
> **Copy that extension into your project on day one.** You will want it inside every
> `withUnsafePointer` closure, because the `shape` and `strides` the closure hands you are `Span`s.

### 7.6 The write view: `NDArray.MutableView<Element>`

> ✅ **VERIFIED** — `/documentation/coreai/ndarray/mutableview`:
>
> ```swift
> struct MutableView<Element> where Element : BitwiseCopyable
> init(mutableSpan: consuming MutableSpan<Element>, shape: [Int], strides: [Int])
>
> var isContiguous: Bool { get }
> var rank: Int { get }
> var shape: Span<Int> { get }
> var strides: Span<Int> { get }
> var interleaveLayout: NDArray.InterleaveLayout? { get }
>
> var contiguousElements: MutableSpan<Element>? { get }
> subscript<let rank : Int>(scalarAt _: InlineArray<rank, Int>) -> Element { get }
>
> mutating func copyElements(from sequence: some Sequence<Element>)
> mutating func copyElements(fromContentsOf: some Collection<Element>)
>
> func withUnsafeMutablePointer<R, E>((UnsafeMutablePointer<Element>, Span<Int>, Span<Int>) throws(E) -> R) throws(E) -> R
>
> func slice(at: [any NDArray.RangeExpression]) -> NDArray.MutableView<Element>
> func slice<let indexRank : Int>(at: [indexRank of any NDArray.RangeExpression]) -> NDArray.MutableView<Element>
> mutating func mutatingSlice(at ranges: [any NDArray.RangeExpression]) -> NDArray.MutableView<Element>
> mutating func mutatingSlice<let indexRank : Int>(at: [indexRank of any NDArray.RangeExpression]) -> NDArray.MutableView<Element>
>
> var view: NDArray.View<Element> { get }
> var mutableRawView: NDArray.MutableRawView { get }
> ```

Three traps live in that list.

**(a) `slice` vs `mutatingSlice`.** Both exist on `MutableView`. `mutatingSlice` is `mutating` — it
borrows `self` mutably and yields a writable sub-view. `slice` is not. **Use `mutatingSlice` when
you intend to write through the sub-view.** Apple's own example:

> ✅ **VERIFIED** — verbatim from `/documentation/coreai/ndarray/mutableview/mutatingslice(at:)`:
>
> ```swift
> /// Updates the desired channel and range of rows
> func incrementRegion(
>   of mutableView: inout NDArray.MutableView<Float>,
>   channel: Int,
>   startRow: Int,
>   endRow: Int
> ) {
>   var region = mutableView.mutatingSlice(at: [channel, startRow..<endRow, .all])
>   var mutableSpan = region.contiguousElements! // contiguous region expected in this case
>
>   for i in mutableSpan.indices {
>     mutableSpan[i] += 1
>   }
> }
> ```
>
> Note the heterogeneous range list in one array: an `Int`, a `Range<Int>`, and `.all`. That works
> because the parameter type is `[any NDArray.RangeExpression]`.

**(b) Trailing dimensions default to `.all`.**

> ✅ **VERIFIED** — `slice(at:)` parameter doc, verbatim: *"The range expressions describing where to
> slice along each dimension. `ranges.count` must be ≤ `rank`. **Unspecified trailing dimensions are
> assumed to be `.all`.**"*

So `view.slice(at: [row])` on a rank-2 view gives you the whole row. Convenient, and easy to
misread as an error when you meant to index a scalar.

**(c) `contiguousElements` behaves like a consuming read.** The documentation declares it as a
getter, but Apple's own code treats obtaining it as a one-shot operation and says so:

> ✅ **VERIFIED** — `apple/coreai-models`, `CoreAIObjectDetector`, doc comment: *"**`contiguousElements`
> is consuming**, so the `MutableSpan` is obtained **once outside the loop** and indexed per image;
> being a safe, bounds-checked handle lets `try` stay inline. It is `nil` for a non-contiguous
> buffer, which the slot arithmetic's dense row-major assumption treats as an error."*
>
> ```swift
> var view = imageArray.mutableView(as: Float.self)
> guard var span = view.contiguousElements else {
>     throw DetectionRuntimeError.invalidConfiguration("Image input NDArray is not contiguous")
> }
> for (b, image) in images.enumerated() {
>     let chw = try preprocessor.preprocessCHW(cgImage: image)
>     let start = b * slotCount                     // slotCount = 3 * H * W
>     for i in 0..<slotCount { span[start + i] = chw[i] }
> }
> ```

**Pattern to internalise: hoist `contiguousElements` out of your loop.** Not for style — because
re-obtaining it inside the loop is at best redundant and at worst does not compile.

### 7.7 The raw views: `MTLBuffer` and `IOSurface` interop

When you need Core AI to read memory you already own — a Metal buffer you filled with a compute
kernel, an `IOSurface` from a capture session — the raw views are the door.

> ✅ **VERIFIED** — `/documentation/coreai/ndarray/rawview`:
>
> ```swift
> struct RawView   // "A type-erased immutable view over the memory owned by a tensor."
> init(bytes: RawSpan, byteOffset: Int, scalarType: NDArray.ScalarType,
>      shape: [Int], strides: [Int], interleaveLayout: NDArray.InterleaveLayout?)
> init(metalBuffer: borrowing any MTLBuffer, byteOffset: Int = 0, scalarType: NDArray.ScalarType,
>      shape: [Int], strides: [Int] = [], interleaveLayout: NDArray.InterleaveLayout? = nil)   // ⚠️ no watchOS
> init(ioSurface: borrowing IOSurface, byteOffset: Int, scalarType: NDArray.ScalarType,
>      shape: [Int], strides: [Int], interleaveLayout: NDArray.InterleaveLayout?)
>
> var scalarType: NDArray.ScalarType { get }
> var shape: Span<Int> { get }
> var strides: Span<Int> { get }
> var bytes: RawSpan { get }
> var interleaveLayout: NDArray.InterleaveLayout? { get }
>
> consuming func view<T>(as: T.Type = T.self) -> NDArray.View<T> where T : BitwiseCopyable
> func slice(at: [any NDArray.RangeExpression]) -> NDArray.RawView
> func withUnsafeBytes<R, E>((UnsafeRawPointer, Span<Int>, Span<Int>) throws(E) -> R) throws(E) -> R
> ```

> ⚠️ **The `metalBuffer:` initializer is explicitly unsafe, in Apple's own words.** Verbatim from the
> discussion:
> - *"`metalBuffer` must have **`shared` storage mode**."*
> - *"Note that the provided `scalarType` will be stored and later checked if you attempt to convert
>   the raw view to a typed view."*
> - *"Also note that the `shape/strides` must not be able to produce offsets that go outside of the
>   range of `metalBuffer`."*
> - *"**This initializer is unsafe, you are responsible for ensuring that no other code (or GPU
>   pipeline) writes to the buffer while the resulting view is alive.**"*
> - `strides`: *"If left empty, they will be computed as contiguous row-major."*

Two naming traps in the raw views, both real, both easy to trip over:

- **`NDArray.RawView.view(as:)` is `consuming`** and asserts the type matches the stored
  `scalarType`. ✅ VERIFIED: *"Consume this raw view to create a typed view"*, NOTE: *"`T` must match
  `self.scalarType.type`."*
- **`NDArray.MutableRawView.view(as:)` returns a `MutableView`, not a `View`**, despite the name.
  ✅ VERIFIED from the declaration: `func view<T>(as: T.Type) -> NDArray.MutableView<T>`.

### 7.8 Strides, and `InterleaveLayout`

`strides[i]` is the distance between consecutive elements along axis `i`. ✅ VERIFIED, verbatim:
*"The strides array has the same number of elements as `shape`, where `strides[i]` describes the
distance between consecutive elements in the `i`th dimension."*

`InterleaveLayout` is the one place that rule bends, and it has the most carefully written
documentation page in the framework:

> ✅ **VERIFIED** — `/documentation/coreai/ndarray/interleavelayout`:
>
> ```swift
> struct InterleaveLayout: Equatable, Sendable, SendableMetatype
> init(dimension: Int, factor: Int)
> var dimension: Int { get }
> var factor: Int { get }
> ```
>
> Overview, verbatim: *"An interleaved layout means that elements of the interleaved `dimension` are
> stored in physically contiguous blocks of `factor` elements (stride 1 between adjacent elements
> within a block). … A common use case is representing an image with interleaved channels: a
> `[C, H, W]` tensor uses `InterleaveLayout(dimension: 0, factor: C)` to store all channels for each
> pixel contiguously — like `RGBRGB...` — rather than in separate planar slices — like
> `RRR...GGG...BBB...`."*
>
> Stride semantics, verbatim: *"The stride for the interleaved dimension (as reported by
> `NDArray.strides`) is a ***block stride*** — the distance in memory between adjacent blocks of
> `factor` elements, **not** between individual elements. Within a block, adjacent elements have
> stride 1. The element offset formula is:"*
>
> ```swift
> // Given strides and InterleaveLayout with dimension d and factor f:
> // offset = (index[d] / f) * strides[d] + (index[d] % f)
> //        + Σ index[i] * strides[i]  for all i ≠ d
> ```

> ⚠️ **If you index by hand and ignore `interleaveLayout`, you read the wrong elements — silently.**
> The strides array *looks* usable. The values in it are block strides for one axis. Apple restates
> the warning inside `withUnsafePointer`'s note: *"If the view has an `interleaveLayout`, the strides
> for that dimension are **block strides** and must be interpreted accordingly."*
>
> **Safe default: check `view.interleaveLayout == nil` before doing manual stride arithmetic**, and
> take the `contiguousElements` path or throw otherwise. Only reach for the offset formula when you
> have a measured reason to.

Apple also documents when the interleaved form is *necessary* rather than merely convenient:

> ✅ **VERIFIED**, verbatim: *"When `factor` divides the size of the interleaved dimension evenly,
> the layout can equivalently be expressed as a shape/stride transformation without interleave
> metadata."* — with a worked example, `shape=[8,256,256] strides=[262144,1024,4]` +
> `InterleaveLayout(dimension: 0, factor: 4)` ≡ `shape=[2,256,256,4] strides=[262144,1024,4,1]`,
> `interleaveLayout=nil` — and then: *"**When `factor` does not divide the dimension size evenly,
> the shape/stride equivalence is not possible. In such case the interleaved representation is the
> only way to express the layout.**"*

### 7.9 `ScalarType`: 35 cases, and the two that don't exist in Swift

`NDArray.ScalarType` is `CaseIterable, Equatable, Hashable, Sendable, SendableMetatype` and has
**35 cases** — far more than the Swift standard library has types.[^scalar-type-count]

| Group | Cases |
|---|---|
| Float | `float16`, `float32`, `float64`, `bfloat16` |
| 8-bit float | `float8e4m3fn`, `float8e5m2` |
| MX block formats | `float4e2m1fn`, `float8e8m0fn` |
| Complex | `cfloat16`, `cfloat32`, `cfloat64` |
| Signed int | `int8`, `int16`, `int32`, `int64`, `int128` |
| Unsigned int | `uint8`, `uint16`, `uint32`, `uint64`, `uint128` |
| Sub-byte signed | `int2`, `int3`, `int4`, `int5`, `int6`, `int7` |
| Sub-byte unsigned | `uint1`, `uint2`, `uint3`, `uint4`, `uint5`, `uint6`, `uint7` |
| Bool | `bool` |

> ✅ **VERIFIED** — full enumeration from `/documentation/coreai/ndarray/scalartype`. `int4` doc,
> verbatim: *"Four-bit signed integers can represent values in the range **[-8, 7]**. Widely used in
> model quantization for efficient storage and computation."* Note there is **no `int1`** (only
> `uint1`) and **no `uint0`**. All 35 cases confirmed, byte for byte, against the SDK
> (✅ **SDK-verified** — `CoreAIRuntime-27.0-macos.swiftinterface:1361-1396`).

Why those exist at all is a Part 9 question — they are the storage types Core AI Optimization
produces. What matters *here* is the runtime consequence:

> ✅ **RESOLVED (was a GAP) — there is no typed `View` for sub-byte or 8-bit-float scalar types in
> the macOS 27.0 beta SDK.**
>
> The interface dump settles both halves (✅ **SDK-verified** —
> `CoreAIRuntime-27.0-macos.swiftinterface`, captured 2026-07-29, recaptured 2026-08-20):
>
> - `view(as:)` requires `T : BitwiseCopyable` (`:591-599`), and the module declares **no element
>   type** for `int4`, `uint3`, `float8e4m3fn` or `float8e8m0fn` — no Core AI `Int4` or
>   `Float8E4M3FN` exists anywhere in the public surface. The raw-bytes path is the only public
>   route to these tensors.
> - **`ScalarType.type` is not in the public interface.** The `ScalarType` declaration
>   (`:1359-1408`) contains only the 35 cases, `CaseIterable`/`Hashable` machinery, and nothing
>   else — the member `RawView.view(as:)`'s doc note references is internal, leaked into the docs.
>
> **Safe default (unchanged, now the *only* option):** treat sub-byte and 8-bit-float tensors as
> **opaque**. Use `rawView()` / `mutableRawView()` and `withUnsafeBytes` / `withUnsafeMutableBytes`,
> and do your own bit unpacking. In practice you rarely need to: these types appear as *weight
> storage* inside the model, not as function I/O. If one shows up as an input or output scalar
> type, that is worth a second look at the export before you write an unpacker.

### 7.10 ⚠️ SILENT FAILURE: assuming the output dtype from the input descriptor

> ⚠️ **The output's scalar type is not the input's scalar type, and the model can change it under
> you.**
>
> ✅ **VERIFIED** — `apple/coreai-models`, `NDArray+Helpers.swift`, doc comment, verbatim: *"Output
> dtype can differ from the model's input dtype, so **always inspect the array rather than threading
> an `isFloat16` flag from input descriptors**."*
>
> The implementation branches on the *array's own* `scalarType`:
>
> ```swift
> public func flattenAsFloat(_ array: NDArray) -> [Float] {
>     switch array.scalarType {
>     #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
>     case .float16: return flattenNDArray(array, as: Float16.self)
>     #endif
>     case .float32: return flattenNDArray(array, as: Float.self)
>     default: preconditionFailure("flattenAsFloat: unsupported scalar type \(array.scalarType)")
>     }
> }
> ```
>
> If you cache "this model is fp16" at load and later read an fp32 output through
> `view(as: Float16.self)`, you do not get a type error — you get **numeric garbage**, because
> `view(as:)` reinterprets bits. The `NDArrayDescriptor` for the *output* is the authority, or the
> `scalarType` of the returned array itself.
>
> **Safe default: branch on `array.scalarType` at the point of read.** Never carry a dtype flag
> across a function boundary.

Note also the `#if` guard in Apple's code, which is a real portability constraint:

> ⚠️ **`Float16` does not exist on Intel macOS.** ✅ VERIFIED — that guard appears at **nine sites**
> across `apple/coreai-models`' Swift, and the `#else` branch is
> `fatalError("Float16 is not supported on this platform")`. Consequence: an fp16 model **cannot
> run** on an Intel Mac through this code path — you get a crash, not a graceful degradation. If you
> still ship an x86_64 slice, gate the feature, don't gate the type.

---

## 8. Writing inputs

### 8.1 The simple path, from Apple

> ✅ **VERIFIED** — Apple's integration article, four consecutive snippets, verbatim:
>
> ```swift
> // Create an `NDArray` that matches the expected type and shape.
> var input = NDArray(shape: [3, 4], scalarType: .float32)
> ```
> ```swift
> // Access a mutable view to write data into the array.
> var mutableView = input.mutableView(as: Float.self)
> guard let elements = mutableView.contiguousElements else {
>     // Handle non-contiguous memory layout.
> }
>
> // Your function that writes input data into the mutable span.
> writeInputData(into: elements)
> ```
> ```swift
> // Run the function with the `NDArray` input.
> var outputs = try await function.run(inputs: ["input": input])
> ```

That is the whole "hello world". Three notes on it:

- `var input`, not `let` — `mutableView(as:)` is `mutating`.
- `var mutableView` — `contiguousElements` on a `MutableView` yields a `MutableSpan`, which needs a
  mutable binding.
- `var outputs` — `Outputs.remove(_:)` is `mutating` (§9).

### 8.2 The three ways to get data in

Apple's own package wraps all three in free functions, which is a good sign they are the three you
need:

> ✅ **VERIFIED** — `apple/coreai-models`,
> `swift/Sources/CoreAIShared/Runtime/NDArray+Helpers.swift`:
>
> ```swift
> public func resolvedStrides(descriptor: NDArrayDescriptor, shape: [Int]) throws -> [Int]
>
> public func fillNDArray<T: BitwiseCopyable>(
>     _ array: inout NDArray, as type: T.Type, with elements: some Collection<T>)
>
> public func fillNDArray<T: BitwiseCopyable>(
>     _ array: inout NDArray, as type: T.Type, count: Int, using generator: (Int) -> T)
>
> public func readNDArray<T: BitwiseCopyable>(
>     _ array: NDArray, as type: T.Type, count: Int) -> [T]
>
> public func flattenAsFloat(_ array: NDArray) -> [Float]
> ```
>
> with the bodies:
>
> ```swift
> /// Fill an NDArray from a collection of elements.
> public func fillNDArray<T: BitwiseCopyable>(
>     _ array: inout NDArray, as type: T.Type, with elements: some Collection<T>
> ) {
>     var view = array.mutableView(as: type)
>     view.copyElements(fromContentsOf: elements)
> }
>
> /// Fill an NDArray using a closure that maps index → value.
> public func fillNDArray<T: BitwiseCopyable>(
>     _ array: inout NDArray, as type: T.Type, count: Int, using generator: (Int) -> T
> ) {
>     var view = array.mutableView(as: type)
>     view.withUnsafeMutablePointer { ptr, shape, _ in
>         let capacity = shape.product
>         precondition(count <= capacity, "fillNDArray: count \(count) exceeds array capacity \(capacity)")
>         for i in 0..<count {
>             ptr[i] = generator(i)
>         }
>     }
> }
> ```

**(a) `copyElements(fromContentsOf:)`** — you already have a Swift `Array` or other `Collection`.
Simplest, and it works regardless of contiguity because the view handles the walk.

> ✅ **VERIFIED** — both overloads exist: `copyElements(from: some Sequence<Element>)` and
> `copyElements(fromContentsOf: some Collection<Element>)`. The doc note on the first: *"The number
> of elements in `sequence` must be less than or equal to `layout.scalarCount`."*
>
> ⚠️ That doc references `layout.scalarCount`, which **is not in the public API** — an internal-doc
> leak. Read it as "the array's element count"; compute it yourself with the `Span.product`
> extension from §7.5.

**(b) `contiguousElements` + direct indexing** — the fastest path when contiguous, and the one to
prefer when you are writing many elements. Bounds-checked, no unsafe pointers.

**(c) `withUnsafeMutablePointer { ptr, shape, strides in … }`** — the escape hatch. Required when
`contiguousElements` is `nil`. **You are responsible for honouring the strides:**

> ✅ **VERIFIED** — `withUnsafePointer(_:)` NOTE, verbatim: *"This function is intended for
> situations where you may not be working with contiguous layouts, and as such cannot use
> `contiguousElements`. **You are responsible for reading the `strides` passed in when indexing the
> backing data.** If the view has an `interleaveLayout`, the strides for that dimension are **block
> strides** and must be interpreted accordingly."*

Notice that Apple's own `fillNDArray(_:as:count:using:)` above indexes `ptr[i]` linearly and ignores
the strides it was handed. That is correct *only* for a contiguous array — which it is, in every
call site in that package. Do not copy it into a `preferredStrides`-allocated array (§11.1) without
adding the stride walk.

### 8.3 A stride-respecting writer you can actually reuse

```swift compile:27
import CoreAI

extension Span where Element == Int {
    /// `Span` is non-escapable and doesn't conform to `Sequence`, so `.reduce` is unavailable.
    var product: Int {
        var result = 1
        for i in 0..<count { result *= self[i] }
        return result
    }
}

enum TensorWriteError: Error {
    case interleavedLayoutUnsupported
    case countMismatch(expected: Int, provided: Int)
}

/// Write a dense row-major `[T]` into an `NDArray` that may have arbitrary strides.
/// Takes the fast path when the destination is contiguous.
func writeRowMajor<T: BitwiseCopyable>(
    _ source: [T],
    into array: inout NDArray,
    as type: T.Type
) throws {
    var view = array.mutableView(as: type)

    guard view.interleaveLayout == nil else {
        // Block strides — the linear walk below would be silently wrong. See §7.8.
        throw TensorWriteError.interleavedLayoutUnsupported
    }

    if var elements = view.contiguousElements {
        guard elements.count == source.count else {
            throw TensorWriteError.countMismatch(expected: elements.count, provided: source.count)
        }
        for i in 0..<source.count { elements[i] = source[i] }
        return
    }

    // Non-contiguous: walk an odometer over the logical shape, honouring strides.
    try view.withUnsafeMutablePointer { ptr, shape, strides in
        let total = shape.product
        guard total == source.count else {
            throw TensorWriteError.countMismatch(expected: total, provided: source.count)
        }
        let rank = shape.count
        var index = [Int](repeating: 0, count: rank)
        for linear in 0..<total {
            var offset = 0
            for axis in 0..<rank { offset += index[axis] * strides[axis] }
            ptr[offset] = source[linear]

            // increment the odometer, least-significant axis last
            var axis = rank - 1
            while axis >= 0 {
                index[axis] += 1
                if index[axis] < shape[axis] { break }
                index[axis] = 0
                axis -= 1
            }
        }
    }
}
```

> 🟡 **RECONSTRUCTED assembly, ✅ VERIFIED members.** Every member used — `mutableView(as:)`,
> `interleaveLayout`, `contiguousElements`, `withUnsafeMutablePointer { ptr, shape, strides in }`,
> `Span.count`, `Span` subscript — is verified above. The odometer walk mirrors the one Apple's
> `flattenNDArray` uses on the read side (✅ VERIFIED as existing: *"`flattenNDArray` checks whether
> the strides are already row-major and, if so, does a flat copy; otherwise it walks an odometer of
> indices"*), but the code is mine, not a transcription.

### 8.4 `InferenceFunction.Inputs` — the zero-copy input collection

The dictionary overload of `run` is a convenience. The other overload takes a purpose-built
collection that can hold *views* rather than owned arrays, which is what you want when the data
lives in a `MTLBuffer` or an `IOSurface`.

> ✅ **VERIFIED** — `/documentation/coreai/inferencefunction/inputs`:
>
> ```swift
> struct Inputs
> init()
> mutating func insert(_ rawView: consuming NDArray.RawView, for inputName: String)
> mutating func insert(_ value: borrowing some InferenceValue.ViewRepresentable & ~Copyable, for inputName: String)
> mutating func insert<Element>(_ view: consuming NDArray.View<Element>, for inputName: String)
>     where Element : BitwiseCopyable
> ```
>
> Overview: *"Build an `Inputs` collection by calling `insert(_:for:)` for each named input the
> function expects, then pass it to `InferenceFunction/run(inputs:states:outputViews:)`."*

Both `run` overloads are otherwise identical:

> ✅ **VERIFIED** — `/documentation/coreai/inferencefunction`, both declarations:
>
> ```swift
> func run(inputs: [String : NDArray],
>          states: consuming InferenceFunction.MutableViews = MutableViews(),
>          outputViews: consuming InferenceFunction.MutableViews = MutableViews())
>     async throws -> InferenceFunction.Outputs
>
> func run(inputs: borrowing InferenceFunction.Inputs,
>          states: consuming InferenceFunction.MutableViews = MutableViews(),
>          outputViews: consuming InferenceFunction.MutableViews = MutableViews())
>     async throws -> InferenceFunction.Outputs
> ```
>
> The discussion on the first: *"This is a convenience overload that accepts a dictionary of
> `NDArray` values instead of an `InferenceFunction.Inputs` collection."*

Note that `states:` and `outputViews:` **both default to an empty `MutableViews()`**, which is why
`try await function.run(inputs: ["input": input])` compiles. Apple's own code passes the empty
collection explicitly in one place, which reads oddly until you know the defaults exist:

> ✅ **VERIFIED** — `apple/coreai-models`, `SpeechModel.swift:81`:
> `states: InferenceFunction.MutableViews(), outputViews: consume out)`

---

## 9. Reading outputs: `InferenceValue` and the take-once bag

### 9.1 `Outputs` is not a dictionary

> ✅ **VERIFIED** — `/documentation/coreai/inferencefunction/outputs`:
>
> ```swift
> struct Outputs
> mutating func remove(_ outputName: String) -> InferenceValue?
> var count: Int { get }
> var names: some Collection<String> { get }
> ```
>
> `remove(_:)` discussion, verbatim: *"After you remove a value, **subsequent calls with the same
> name return `nil`**."*

There is no subscript. There is no `first`. There is `remove`, and it is `mutating`, and it is
**destructive**. `Outputs` is a *take-once bag*: each value can be extracted exactly once, and after
that the name reads as absent.

Apple's canonical extraction:

> ✅ **VERIFIED** — Apple's integration article, verbatim:
>
> ```swift
> // Extract the returned output.
> guard let predictionValue = outputs.remove("prediction") else {
>     // Handle output not found.
> }
>
> guard let prediction = predictionValue.ndArray else {
>     // Handle output of unexpected type of value.
> }
>
> // Read the output data through a view.
> // Your function that processes the output.
> processOutput(prediction.view())
> ```

Two `guard`s, two different meanings — same shape as `loadFunction` in §4:

- `remove` returns `nil` → **no output by that name** (or you already took it).
- `.ndArray` returns `nil` → the output exists but is an **image**, not a tensor.

### 9.2 ⚠️ `InferenceValue.ndArray` is a consuming read wearing a getter's clothes

> ✅ **VERIFIED** — `/documentation/coreai/inferencevalue/ndarray`, discussion, verbatim: *"This
> property is `nil` when the value contains an image instead of an array. **Accessing this property
> consumes the value and transfers ownership of the array to the caller.**"*

```swift illustrative
struct InferenceValue
var kind: InferenceValue.Kind { get }        // .image or .ndArray
var ndArray: NDArray? { get }                // ⚠️ consuming
var pixelBuffer: CVMutablePixelBuffer? { get }
init(_ pixelBuffer: consuming CVMutablePixelBuffer)

enum Kind { case image; case ndArray }
```
> ✅ **VERIFIED** — `/documentation/coreai/inferencevalue`. Overview: *"An `InferenceValue` wraps
> either an `NDArray` or a pixel buffer, and you retrieve it after inference using the `ndArray`
> property."*

So this is a bug:

```swift illustrative
guard let value = outputs.remove("prediction") else { … }
if value.ndArray != nil {              // ⚠️ consumes here…
    let array = value.ndArray!         // …and this is a second consuming read
}
```

Check `kind` first, or bind once:

```swift illustrative
guard let value = outputs.remove("prediction") else { throw … }
guard value.kind == .ndArray else { throw … }        // cheap, non-consuming
guard let array = value.ndArray else { throw … }     // consume exactly once
```

### 9.3 Returned arrays are always row-major contiguous

This is a genuinely useful guarantee, stated on both `run` overloads:

> ✅ **VERIFIED** — verbatim: *"Any `NDArray` values in the returned outputs have a **row-major
> contiguous layout**."*

So on the **output** side, `contiguousElements` is safe to force-unwrap for values that came out of
`run` — but *only* those. An array you built with `preferredStrides` (§11.1), or one you got back
from `AsyncValue.ndArray`, carries no such promise. Write the `guard let … else { throw }` anyway;
it costs a line and it survives refactoring.

### 9.4 ⚠️ SILENT FAILURE: outputs you pre-allocate disappear from `Outputs`

> ⚠️ **SILENT FAILURE — an output with a pre-allocated view is *not* in the returned `Outputs`.**
>
> ✅ **VERIFIED** — `run`'s `outputViews:` parameter documentation, verbatim: *"Pre-allocated output
> values that the function updates during inference. **Outputs with a provided view are updated
> in-place and are not included in the returned `InferenceFunction.Outputs`.** Outputs without a
> provided view produce new values in the returned `InferenceFunction.Outputs`."*
>
> The same rule is restated for `encode`: *"The returned dictionary doesn't contain
> `InferenceFunction` outputs for which you provide a view, because the inference updates the
> mutable view in place."*
>
> **The failure shape.** You add an `outputViews:` entry for `"logits"` as a performance
> optimisation (§11.2). Every existing call site that does
>
> ```swift
> guard let logits = outputs.remove("logits")?.ndArray else {
>     throw RunError.missingOutput("logits")   // ← now fires on every single call
> }
> ```
>
> starts throwing "missing output". Nothing warns you. `run` returned successfully, the inference
> ran, the data is *in your pre-allocated array* — the returned bag is simply empty for that name.
> A reader debugging this looks at the model, the export, the shapes, and the tokenizer before they
> look at the parameter they added three commits ago.
>
> **Safe default: make the two mutually exclusive in your own wrapper**, so the type system stops
> you:
>
> ```swift
> enum OutputBinding {
>     case returned                                  // read it from Outputs
>     case preallocated                              // read it from the array you passed in
> }
> ```
>
> and assert it: after a `run` where you passed `outputViews` for name `n`,
> `outputs.names.contains(n)` must be `false`. If it is `true`, your view was not accepted and you
> are reading stale data from your own buffer.

Apple's own package hits this and simply discards the return value, which is the honest expression
of "everything I care about is in `outputViews`":

> ✅ **VERIFIED** — `apple/coreai-models`, `CoreAISequentialEngine.swift:275-291`, verbatim:
>
> ```swift
> // Build states (KV cache — persistent, inout)
> var states = InferenceFunction.MutableViews()
> states.insert(&keyCache, for: keyCacheName)
> states.insert(&valueCache, for: valueCacheName)
>
> // Build output backings (logits — written in-place)
> var outputViews = InferenceFunction.MutableViews()
> outputViews.insert(&logitsArray, for: logitsName)
>
> // Execute
> _ = try await function.run(
>     inputs: [inputIdsName: inputIdsArray, positionIdsName: positionIds],
>     states: consume states,
>     outputViews: consume outputViews
> )
> ```
>
> Note `_ =`. The `Outputs` is empty of `logits` by design.

### 9.5 `NamedMutableViews.take(_:)` crashes on a double take

A cousin of §9.1 with a much less forgiving failure mode:

> ✅ **VERIFIED** — `/documentation/coreai/inferencevalue/namedmutableviews`. Overview: *"Each view
> can only be taken once to ensure exclusive access."* `take(_:)` discussion, verbatim: *"Each value
> can only be taken once. **Requesting the same value again produces a fatal error.**"*
>
> ```swift
> struct InferenceValue.NamedMutableViews
> mutating func take(_ valueName: String) -> InferenceValue.MutableView?
> ```

So on this type `nil` means "no value with that name" and a **second take traps**. Compare
`Outputs.remove`, where a second call returns `nil` benignly. Two collections, two different
double-access policies. Do not build intuition from one and apply it to the other.

---

## 10. States and pre-allocated outputs: `MutableViews`

### 10.1 One type, two parameters

`states:` and `outputViews:` take the *same* type, `InferenceFunction.MutableViews`, and it exists
because both parameters mean "here is memory I own; write into it".

> ✅ **VERIFIED** — `/documentation/coreai/inferencefunction/mutableviews`:
>
> ```swift
> struct MutableViews
> init()
> mutating func insert(_ value: inout some InferenceValue.MutableViewRepresentable & ~Copyable, for name: String)
> mutating func insert<Element>(_ mutableView: consuming NDArray.MutableView<Element>, for name: String)
>     where Element : BitwiseCopyable
> mutating func insert(_ mutableRawView: consuming NDArray.MutableRawView, for name: String)
> ```

The first overload is the one you will use, because `NDArray` conforms to
`InferenceValue.MutableViewRepresentable` — so `insert(&myArray, for: "key_cache")` works directly
on the array, no view construction needed.

### 10.2 States: what they are, in one paragraph

> ✅ **VERIFIED** — session 324, lines 109–112, verbatim: *"This can be achieved through Core AI by
> using **states**. **States are inputs to the model which are both read, and updated in-place
> during inference.** By introducing the key and value caches as states on the model, we both avoid
> recomputing them on each inference, and also **remove the need to provide the full history of the
> game as an input** since the data needed from older steps are stored in the states."*

On the Python side they come from `torch.register_buffer` + in-place mutation, named through
`state_names` at conversion time. That is Part 8's material. On the Swift side, the entire surface
is: `descriptor.stateNames`, `descriptor.stateDescriptor(of:)`, and the `states:` parameter.

### 10.3 ⚠️ You must supply a view for *every* state

> ✅ **VERIFIED** — `run`'s `states:` parameter documentation, verbatim: *"The in-out arguments of the
> function, which the function reads and writes during inference. **You must provide views for all
> states; omitting any state produces an error.**"*
>
> Restated on `InferenceFunctionDescriptor.stateNames`: *"States are function arguments that the
> function both reads and writes during inference. **You must provide a mutable view for every
> state** when calling `InferenceFunction/run(inputs:states:outputViews:)`."*
>
> And again on `encode`: *"Note that views for states are not optional. Omitting a view for any state
> results in an error."*

Three separate documentation pages say the same thing, which usually means the API team got tired
of the bug report. Since there is no `stateCount`, drive it from `stateNames`:

```swift prelude:guide-context
// Allocate one NDArray per state, sized from its own descriptor. Do this ONCE, at setup.
var stateArrays: [String: NDArray] = [:]
for name in function.descriptor.stateNames {
    guard let value = function.descriptor.stateDescriptor(of: name),
          case .ndArray(let d) = value else {
        throw ModelSetupError.unsupportedStateKind(name)
    }
    let resolved = d.hasDynamicShape
        ? d.resolvingDynamicDimensions(concreteShape(for: name))   // your policy
        : d
    stateArrays[name] = NDArray(descriptor: resolved)
}
```

and then, on every call:

```swift prelude:guide-context
var states = InferenceFunction.MutableViews()
for name in function.descriptor.stateNames {
    states.insert(&stateArrays[name]!, for: name)     // see the note below
}
let outputs = try await function.run(inputs: inputs, states: consume states)
```

> ⚠️ `&stateArrays[name]!` through a dictionary subscript is legal but fragile — a force-unwrap and
> an exclusivity check per iteration. For anything beyond two or three states, hold the arrays in
> named stored properties (as Apple's engines do: `keyCache`, `valueCache`) or in a small
> `~Copyable` box. `1amageek/swift-lm` (⚠️ **community**) solves the general-N case with **recursion**
> — one stack frame per state, because `AsyncMutableValue` is non-copyable and inserted by `inout`:
>
> ✅ **VERIFIED** — `swift-lm`, `CoreAIStateSession`:
> ```swift
> private func encode(
>     stateIndex: Int,
>     inputs: [String: InferenceFunction.AsyncValue],
>     stateViews: consuming InferenceFunction.AsyncMutableViews,
>     stream: borrowing ComputeStream
> ) throws -> [String: InferenceFunction.AsyncValue] {
>     guard stateIndex < states.count else {
>         let outputViews = InferenceFunction.AsyncMutableViews()
>         return try function.encode(inputs: inputs, states: stateViews,
>                                    outputViews: consume outputViews, to: stream)
>     }
>     let state = states[stateIndex]
>     var stateValue = unsafe InferenceFunction.AsyncMutableValue(
>         unsafeBuffer: state.buffer,
>         scalarType: state.descriptor.scalarType,
>         shape: state.descriptor.shape,
>         strides: state.descriptor.preferredStrides,
>         interleaveLayout: state.descriptor.interleaveLayout
>     )
>     var nextViews = stateViews
>     nextViews.insert(&stateValue, for: state.name)
>     return try encode(stateIndex: stateIndex + 1, inputs: inputs,
>                       stateViews: consume nextViews, stream: stream)
> }
> ```
> It is not elegant, but it is the shape the ownership rules force, and it is worth knowing that a
> real integration ended up here.

### 10.4 `consume` is not optional

Both `states:` and `outputViews:` are declared `consuming`. Swift will often insert the consume for
you, but Apple's own package writes it explicitly and even landed a commit to do so:

> ✅ **VERIFIED** — `apple/coreai-models` commit `7bd9d32`, *"Use views in consuming manner, not
> mutating (#89)"*.

Write `states: consume states, outputViews: consume outputViews`. The collection is dead after the
call; treating it as reusable is the mistake this makes impossible.

### 10.5 What Apple's own engine actually does, end to end

The complete decode step from `CoreAISequentialEngine` is worth reading once as a whole, because it
is the densest correct example of §8, §9 and §10 together:

> ✅ **VERIFIED** — `apple/coreai-models`, `CoreAISequentialEngine.swift`. Model contract from its
> own doc comment: *"Expects a `.aimodel` with: **2 inputs** — `input_ids` (Int32), `position_ids`
> (Int32); **1 output** — `logits`; **2 states** — `keyCache`, `valueCache`, persistent across
> steps, updated in-place. KV cache NDArrays start small (256 tokens) and grow dynamically with 2×
> expansion."*
>
> ```swift
> var states = InferenceFunction.MutableViews()
> states.insert(&keyCache, for: keyCacheName)
> states.insert(&valueCache, for: valueCacheName)
> var outputViews = InferenceFunction.MutableViews()
> outputViews.insert(&logitsArray, for: logitsName)
> _ = try await function.run(
>     inputs: [inputIdsName: inputIdsArray, positionIdsName: positionIds],
>     states: consume states,
>     outputViews: consume outputViews)
> ```

Two performance notes from that same file, both **Apple-authored source comments** (no hardware or
build stated — read them as engineering rationale, not benchmarks):

> ✅ **VERIFIED**, verbatim: *"Reuse pre-allocated `input_ids` when the batch size is unchanged.
> Steady-state decode keeps batchSize=1 forever, so this avoids the `NDArray(descriptor:)` +
> `resolvingDynamicDimensions` work on every step — small per call, but compounds over long
> generations."* The file elsewhere quantifies it as *"Saves ~50-100 µs/step"*.

> ✅ **VERIFIED**, verbatim: *"under `-Onone`, `fillNDArray`'s `(Int) -> LogitsScalarType` closure is
> invoked per element … which made zeroing the KV cache (~14.7M elements for a 32K-context Qwen3)
> take **~6 seconds per `reset()`**"* — which is why that path is a hand-rolled pointer loop.
> **Build optimized.** A debug build of Core AI code is not a slow version of the release build; it
> is a different performance class.

---

## 11. The three low-level performance APIs

Session 324 lists three, in a single slide, in about forty seconds:

> ✅ **VERIFIED** — WWDC26 session 324, lines 175–181, verbatim: *"Another area you may want to
> optimize is **removing any overheads in tight inference loops** using your model. The Core AI
> Framework has several APIs to help you here.
> 1. You can **dynamically check the optimal memory layout of NDArray arguments and allocate them
>    with that structure to avoid layout conversions at inference time**.
> 2. You can also **pre-allocate output values for the framework to write into, to avoid allocating
>    new output values during inference**.
> 3. And you can also use **asynchronous values to efficiently pipeline execution of multiple
>    inference functions together**.
>
> For most use cases, the higher-level inference APIs will get you exactly where you need to be. But
> when you're **optimizing a tight inference loop or integrating a model into a complex compute
> pipeline**, these lower-level APIs are there when you need them."*

The transcript names no API. Each of the three maps onto a concrete symbol, and all three mappings
are corroborated by Apple's own shipping Swift — which is why they are ✅ rather than 🟡.

### 11.1 Optimal memory layout: `preferredStrides`

**The mapping:** `NDArrayDescriptor.resolvingDynamicDimensions(_:)` → `.preferredStrides` →
`NDArray(shape:scalarType:strides:)` or `NDArray(descriptor:)`.

> ✅ **VERIFIED** — `apple/coreai-models`, `NDArray+Helpers.swift:12-19`, verbatim including the doc
> comment:
>
> ```swift
> /// Resolve strides from an NDArrayDescriptor for a given concrete shape.
> ///
> /// Uses `NDArrayDescriptor.resolvingDynamicDimensions().preferredStrides` to get
> /// framework-blessed strides that respect hardware alignment constraints.
> public func resolvedStrides(descriptor: NDArrayDescriptor, shape: [Int]) throws -> [Int] {
>     let resolved = descriptor.resolvingDynamicDimensions(shape)
>     return resolved.preferredStrides
> }
> ```

#### What `preferredStrides` actually is

> ✅ **VERIFIED** — `/documentation/coreai/ndarraydescriptor/preferredstrides`, discussion, verbatim:
>
> *"During the specialization of an `AIModel`, a preferred memory layout for a given ndArray value
> may be set depending on structure of the model and which compute units it is specialized for. In
> some cases, this can result in a **non-contiguous layout being preferred/required by the backing
> compute**. In such case, you are still able to provide `InferenceFunction.run` normal contiguous
> ndArray values, however **it may incur a copy to the preferred layout**. As such, this property
> provides an opportunity for you to optimize performance by creating your source ndArray value with
> the preferred striding and avoiding that copy."*
>
> NOTE, verbatim: *"Constructing an ndArray with these preferred strides may result in a
> non-contiguous layout. In such case calling `ndArrayView.contiguousElements` on a view of the
> ndArray will return `nil`. **If you choose to use the preferred strides, you must read/write the
> resulting ndArray by dynamically respecting whatever strides are returned.**"*

#### ⚠️ SILENT FAILURE: the layout-conversion copy

> ⚠️ **SILENT FAILURE — the copy you never see, on every inference, forever.**
>
> This is the defining Core AI performance bug and it has **no observable symptom in your code**.
> You allocate `NDArray(shape:scalarType:)` — Apple's own hello-world initializer, contiguous
> row-major, exactly what the descriptor's `shape` and `scalarType` said. You call `run`. It
> succeeds. The numbers are right. Nothing is logged, nothing throws, nothing appears in the debug
> gauge as an error.
>
> And on every single call, the framework copies your tensor into a different memory layout first,
> because specialization decided the Neural Engine wants padded or interleaved strides for that
> argument.
>
> **Why it is invisible:** the copy is *correct*. It is not a bug in Core AI; it is the framework
> doing the right thing with what you gave it. There is no "you could have avoided this" diagnostic
> anywhere in the API, the docs, or the tooling.
>
> **How to detect it:** compare `descriptor.preferredStrides` against the contiguous row-major
> strides for the same shape. If they differ, you are paying the copy.
>
> ```swift
> /// Row-major contiguous strides for a shape, in elements.
> func rowMajorStrides(_ shape: [Int]) -> [Int] {
>     var strides = [Int](repeating: 1, count: shape.count)
>     for axis in stride(from: shape.count - 2, through: 0, by: -1) {
>         strides[axis] = strides[axis + 1] * shape[axis + 1]
>     }
>     return strides
> }
>
> /// Log once at setup. Costs nothing; tells you whether §11.1 is worth doing for this model.
> func auditLayout(_ fd: InferenceFunctionDescriptor, concrete: [String: [Int]]) {
>     for name in fd.inputNames {
>         guard let v = fd.inputDescriptor(of: name), case .ndArray(let d) = v else { continue }
>         let resolved = d.hasDynamicShape
>             ? d.resolvingDynamicDimensions(concrete[name] ?? d.shape)
>             : d
>         let preferred = resolved.preferredStrides
>         let contiguous = rowMajorStrides(resolved.shape)
>         if preferred != contiguous {
>             print("[CoreAI] input '\(name)': preferred \(preferred) != contiguous \(contiguous) "
>                   + "— a contiguous NDArray will be copied on every run.")
>         }
>         if resolved.interleaveLayout != nil {
>             print("[CoreAI] input '\(name)' has an interleave layout: \(resolved.interleaveLayout!)")
>         }
>     }
> }
> ```
>
> **Safe default if you do nothing:** contiguous arrays are *correct*. This is a throughput bug, not
> a correctness one. Ship contiguous, measure with the Core AI instrument, and adopt preferred
> strides only for the arguments the audit above flags — because the cost of adopting them is that
> `contiguousElements` starts returning `nil` and every writer you have must grow a stride walk
> (§8.3).

#### Apple's own worked example

> ✅ **VERIFIED** — verbatim from the `preferredStrides` documentation:
>
> ```swift
> guard case .ndArray(let inputDescriptor) = inferenceFunctionDescriptor.inputDescriptor(of: "input") else {
>   throw UnexpectedInferenceValueType()
> }
> let preferredStrides = inputDescriptor.preferredStrides
> var ndArray = NDArray(shape: [theShape], scalarType: .float32, strides: preferredStrides)
> var view = ndArray.mutableView(as: Float.self)
> if let contiguousElements = view.contiguousElements {
>   // The preferred strides were a normal contiguous layout
> } else {
>   // The preferred strides were non-contiguous
>   view.withUnsafeMutablePointer { data, shape, strides in
>     ... logic which respects whatever strides were preferred ...
>   }
> }
> ```
>
> Note the branch: **preferred strides are often just contiguous**, in which case the fast path is
> still available. Write both branches, take whichever you get.

#### `minimumByteCount`, for manual allocation

If you are allocating the backing store yourself — a `MTLBuffer`, an `IOSurface` — this is how you
size it:

> ✅ **VERIFIED** — `minimumByteCount` discussion, verbatim: *"The shape/strides/scalarType of this
> descriptor are used to compute the addressable byte range of the layout, and the size of that
> range is returned as the minimum size a backing storage would need to be to contain the ndArray."*
> … *"In most cases it is preferred to make `NDArray` instances which handle creating the
> allocations for you, but in circumstances where you need to manually handle your allocations, this
> property can be useful."* … *"`hasDynamicShape` must be false when accessing this property."*

Apple's own package uses it exactly that way:

> ✅ **VERIFIED** — `1amageek/swift-lm` (⚠️ **community**), state allocation:
> ```swift
> guard let device = MTLCreateSystemDefaultDevice(),
>       let buffer = device.makeBuffer(
>         length: resolvedDescriptor.minimumByteCount,
>         options: .storageModeShared
>       ) else { throw CoreAIModelAssetError.stateAllocationFailed(name) }
> memset(buffer.contents(), 0, buffer.length)
> ```
> `.storageModeShared` is not a preference — it is the documented requirement for every Core AI
> Metal interop path (§7.7). And note the explicit `memset`: nothing zeroes a fresh `MTLBuffer` for
> you, and a KV cache full of garbage produces plausible-looking wrong output.

> ⚠️ **Apple's own `minimumByteCount` sample does not compile.** The documentation page shows
> `NDArray.RawView(metalBuffer:byteOffset:shape:scalarType:strides:)` — `shape:` before
> `scalarType:` — but the declared order is
> `(metalBuffer:byteOffset:scalarType:shape:strides:interleaveLayout:)`. The same snippet also
> writes `var outputs = inferenceFunction.run(inputs: inputs)` with no `try await` on an
> `async throws` method. Treat that page's code as illustrative pseudo-code; the *prose* is
> reliable.

> ⚠️ **A 64-byte floor exists in practice.** ✅ VERIFIED — `apple/coreai-models` PR #62, merged:
> *"Some machine configurations seem to require minimum 64 byte size buffers. This bumps up the new
> ones from 4 bytes to that minimum."* The engine carries
> `private let minimumMPSNDArrayBufferSize = 64` with the comment *"MPSNDArray enforces 64-byte
> row-stride alignment"*. The symptom before the fix was a hard assertion:
> `MPSNDArray.mm:893: failed assertion '[MPSNDArray, initWithBufferImpl:…] Error: buffer is not
> large enough. Must be 64 bytes'`. If you allocate a tiny scalar tensor by hand, floor it at 64
> bytes.

### 11.2 Pre-allocated outputs: the `outputViews:` parameter

**The mapping:** `InferenceFunction.MutableViews` passed as `outputViews:`.

The mechanics are §10 and the trap is §9.4. What is worth adding here is *when it is worth doing*.

The saving is one allocation per output per call. In a vision app that runs one inference per
camera frame, that is noise. In a token-decode loop at 200 steps/second with a
`[1, 1, 151936]`-shaped logits tensor, it is not — and Apple's own engine quantifies its
sibling optimisation (reusing the *input* array) at *"~50-100 µs/step"* (Apple source comment; no
hardware stated). At 200 steps/s that is 1–2% of wall time, recovered for free.

**Rule of thumb:** pre-allocate outputs when (a) you call the function in a loop, (b) the output
shape is stable across iterations, and (c) you were going to copy the output somewhere anyway. If
the shape changes every call, you are re-allocating regardless and the parameter buys you nothing
but the §9.4 trap.

> ⚠️ There is a real counter-case in Apple's own tree. PR #85 (**closed unmerged 2026-08-23;
> previously marked "do not merge"**)
> observes: *"if we don't use the pre-allocated output view flow, it'll return an `NDArray` backed
> by the constant directly without making a copy"* — the author flagged a **performance regression**
> from pre-allocating. So for outputs that alias a model constant (an embedding table, say), letting
> the framework return its own array can be *faster*. Measure; don't assume.

### 11.3 Asynchronous values and `ComputeStream`

**The mapping:** `InferenceFunction.AsyncValue`, `AsyncMutableValue`, `AsyncMutableViews`,
`ComputeStream`, and `InferenceFunction.encode(inputs:states:outputViews:to:)`.

#### The one signature that changes everything

> ✅ **VERIFIED** — `/documentation/coreai/inferencefunction/encode(inputs:states:outputviews:to:)`:
>
> ```swift
> func encode(inputs: [String : InferenceFunction.AsyncValue],
>             states: consuming InferenceFunction.AsyncMutableViews = AsyncMutableViews(),
>             outputViews: consuming InferenceFunction.AsyncMutableViews = AsyncMutableViews(),
>             to stream: ComputeStream)
>     throws -> [String : InferenceFunction.AsyncValue]
> ```
>
> **It is `throws`, not `async throws`.** Discussion, verbatim: *"When this method returns, the
> compute may still be running on `stream`. You can pass the returned async values as inputs to
> subsequent `encode` calls to build a pipeline of inferences without waiting for intermediate
> results, or await them to retrieve the final compute outputs on the CPU."*

`run` is "do the work and give me the answer". `encode` is "queue the work and give me a receipt".
The receipt is an `AsyncValue`, and awaiting it is where the `async` moved to.

#### The types

> ✅ **VERIFIED** — `/documentation/coreai/inferencefunction/asyncvalue`. Note it is a **`final
> class`**, and `Sendable`:
>
> ```swift
> final class AsyncValue
> init(_: CVReadOnlyPixelBuffer)
> init(_: consuming InferenceFunction.AsyncMutableValue)
> init(_: consuming NDArray)
> init(unsafeBuffer: consuming any MTLBuffer, byteOffset: Int = 0,
>      scalarType: NDArray.ScalarType, shape: [Int], strides: [Int] = [],
>      interleaveLayout: NDArray.InterleaveLayout? = nil)          // ⚠️ no watchOS
>
> var kind: InferenceValue.Kind { get }
> final var ndArray: NDArray? { get async throws }
> final var pixelBuffer: CVReadOnlyPixelBuffer? { get async throws }
> ```
>
> Overview, verbatim: *"An `AsyncValue` contains an underlying `InferenceValue` however that value
> may be actively in-use by some previously dispatched async work, and thus accessing the underlying
> value below an `AsyncValue` requires an `await` to wait for any previous compute writing it to be
> complete."* … *"An `AsyncValue` is **immutable once any previous compute has completed**."*

> ✅ **VERIFIED** — `/documentation/coreai/inferencefunction/asyncmutablevalue`. Note it is a
> **`struct`**, not a class:
>
> ```swift
> struct AsyncMutableValue
> init(_: consuming CVMutablePixelBuffer)
> init(_: consuming NDArray)
> init(descriptor: consuming InferenceValue.Descriptor)      // "the descriptor must not have a dynamic shape"
> init(unsafeBuffer: consuming any MTLBuffer, byteOffset: Int = 0,
>      scalarType: NDArray.ScalarType, shape: [Int], strides: [Int] = [],
>      interleaveLayout: NDArray.InterleaveLayout? = nil)
>
> var ndArray: NDArray? { get async throws }
> var pixelBuffer: CVMutablePixelBuffer? { get async throws }
> ```
>
> Overview, verbatim (typo Apple's): *"When dispatching an `encode(inputs:states:outputViews:to:)`,
> mutable values are what is included in the states and output vaiews."* … *"**When encoding a
> sequence of inferences which each mutate the same `AsyncMutableValue`, the framework will insert
> the necessary synchronization to avoid it being read or written while a previous write is
> occurring.**"*

That last sentence is the load-bearing one: **you do not hand-synchronise a KV cache across
pipelined steps.** The framework inserts the dependency edges.

> ✅ **VERIFIED** — `/documentation/coreai/computestream`:
>
> ```swift
> final class ComputeStream
> convenience init()                                      // "Initialize an empty compute stream."
> init(commandQueue: any MTLCommandQueue)                 // ⚠️ no watchOS
> final func currentWorkCompleted() async
> ```
>
> Overview, verbatim (typo Apple's): *"A compute stream is what is provided to
> `encode(inputs:states:outputViews:to:)` to encode the work onto the stream. **Multiple inferences
> encoded to the same stream are serialized as needed based on the the values read/written.**"*
> `currentWorkCompleted()`: *"Waits for all previous work encoded to this stream to be complete."*
> — `async`, non-throwing, no return.

`init(commandQueue:)` is the interop door: *"You can use this to encode inferences to your own metal
queue."*

#### Apple's pipelining example

> ✅ **VERIFIED** — verbatim from the `encode` documentation page. **This one does compile** (unlike
> the abbreviated version on the `AsyncValue` page, which omits the required `to:` argument and
> misspells a variable):
>
> ```swift
> let computeStream = ComputeStream()
> let pipelineFunctionOne: InferenceFunction = ...
> let pipelineFunctionTwo: InferenceFunction = ...
> let initialInput: NDArray = ...
>
> // Run stage one of pipeline and get async value output.
> let asyncInput = InferenceFunction.AsyncValue(initialInput)
> let functionOneOutputs = try pipelineFunctionOne.encode(inputs: ["input": asyncInput], to: computeStream)
> guard let functionOneOutput = functionOneOutputs["output"] else {
>     // Handle unexpected missing output
>     return
> }
>
> // Feed output from function one as an input to function two.
> // Note that function one may be running the actual compute asynchronously while function two
> // encodes its inference.
> let functionTwoOutputs = try pipelineFunctionTwo.encode(inputs: ["input": functionOneOutput], to: computeStream)
> guard let functionTwoOutput = functionTwoOutputs["output"] else {
>     // Handle unexpected missing output
>     return
> }
>
> // Now both inferences have been encoded
> guard let finalNDArray = try await functionTwoOutput.ndArray else {
>     // Handle case where output is not an NDArray
>     return
> }
> ```

**This is the pattern for a multi-function model.** The `image_encode` → `detect` handoff in a SAM 3
lite export is precisely stage-one-feeds-stage-two, and doing it with `encode` means the encoder's
GPU work can still be running while the detector's work is being encoded.

#### ⚠️ SILENT FAILURE: `AsyncValue.ndArray` copies when the value came from a `MTLBuffer`

> ⚠️ **SILENT COPY — reading `.ndArray` from an `MTLBuffer`-backed `AsyncValue` gives you a copy,
> not a view.**
>
> ✅ **VERIFIED** — `AsyncValue.ndArray` discussion, verbatim: *"If this value was constructed from a
> provided MTLBuffer directly, then this will return a **copy** of the data to avoid unsafe
> aliasing. If aliasing is desired, you can work with the original MTLBuffer directly."*
>
> The whole point of `init(unsafeBuffer:)` was to avoid a copy. Then you `await value.ndArray` to
> "look at the result" and quietly reintroduce the copy you were avoiding — per call, for the full
> tensor. Nothing warns. On a `[1, 1, 151936]` fp16 logits tensor that is ~300 KB per decode step.
>
> **Safe default:** if you built the value from an `MTLBuffer`, **read the `MTLBuffer`**, not
> `.ndArray`. Apple's own pipelined engine never round-trips: it reads the previous step's token
> straight out of `decodeOutputBuffers[(step + pipelineDepth - 1) % pipelineDepth]`.

#### The unsafe-buffer contract

> ✅ **VERIFIED** — `AsyncValue.init(unsafeBuffer:)` discussion, verbatim: *"`unsafeBuffer` must have
> **`shared` storage mode**. Initializing an async value this way requires that you **manually
> ensure the provided metal buffer is not mutated while this value is being used by an inference
> function**."* Defaults: `byteOffset: Int = 0`, `strides: [Int] = []` (*"If left empty, they will
> be computed as contiguous row-major"*), `interleaveLayout: … = nil`.

And in real use, Swift 6's `unsafe` expression prefix is required at the call site:

> ✅ **VERIFIED** — `apple/coreai-models`, `CoreAIPipelinedEngine.swift:707-800`, verbatim:
>
> ```swift
> let tokenValue = unsafe InferenceFunction.AsyncValue(
>     unsafeBuffer: decodeOutputBuffers[(step + pipelineDepth - 1) % pipelineDepth],
>     byteOffset: 0,
>     scalarType: .int32,
>     shape: tokenShape,
>     strides: tokenStrides
> )
> var keyState = unsafe InferenceFunction.AsyncMutableValue(
>     unsafeBuffer: keyBuffer,
>     byteOffset: 0,
>     scalarType: keyCacheScalarType,
>     shape: keyShape,
>     strides: keyStrides
> )
> var asyncStates = InferenceFunction.AsyncMutableViews()
> asyncStates.insert(&keyState, for: keyCacheName)
> asyncStates.insert(&valState, for: valueCacheName)
>
> // Encode inference using the public encode() API.
> // This commits + uses runAfterSyncPoint (no stream wait) — enables true pipelining.
> let _ = try function.encode(
>     inputs: asyncInputs,
>     states: consume asyncStates,
>     outputViews: consume asyncOutputs,
>     to: computeStream
> )
> ```
> with `let computeStream = ComputeStream(commandQueue: pipelineQueue)`.

#### When not to do this

Apple's own package pays a real price for the pipelined path, and the price list is instructive:

> ✅ **VERIFIED** — `apple/coreai-models`, `CoreAIPipelinedEngine` throws on all of these:
> - *"CoreAI pipelined engine **does not support logits** (GPU-side sampling). Use a sequential
>   engine for constrained generation or evaluation."*
> - *"CoreAI pipelined engine does not support `forcedContinuation`."*
> - *"Sampling configuration changed mid-generation. Call `reset()` first."*
>
> and `supportsLogits == false` on that engine.

Pipelining pushes work onto the GPU and keeps it there, which means intermediate values you used to
read on the CPU are no longer conveniently available. **That is the trade.** For a Core AI LLM this
costs you grammar-constrained generation entirely — a first-class architectural constraint covered
in [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md) and Part 1's backend decision table.

**Use `run` until you have a profile that says otherwise.** Session 324's own framing —
*"For most use cases, the higher-level inference APIs will get you exactly where you need to be"* —
is not modesty.


---

## 12. Image-typed values, and whose problem orientation is

### 12.1 The type system

Core AI has exactly one alternative to `NDArray`, and it appears when the model author marked a
value as an image at conversion time:

> ✅ **VERIFIED** — Apple's integration article, verbatim: *"The `NDArray` type represents the input
> and output tensors from the converted model function at runtime. **Values marked as images at
> conversion time use `CVMutablePixelBuffer`.** Pass your data using the same input names defined at
> model conversion time."*

```swift illustrative
enum InferenceValue.Kind { case image; case ndArray }
enum InferenceValue.Descriptor { case image(ImageDescriptor); case ndArray(NDArrayDescriptor) }

struct ImageDescriptor: Equatable, Sendable, SendableMetatype
let pixelFormatType: OSType    // "The four-character code that identifies the pixel format."
let width: Int
let height: Int
```
> ✅ **VERIFIED** — `/documentation/coreai/imagedescriptor`. `pixelFormatType` discussion, verbatim:
> *"Compare this value to the `pixelFormatType` of a `CVPixelBuffer`."*

Three members. There is no colour space, no bytes-per-row, no orientation, no alpha policy. What
the framework will tell you about an image argument is: this format code, this width, this height.
Everything else is a contract between you and whoever exported the model.

Note the two pixel-buffer types in play, and that they are **not** `CVPixelBuffer`:

| Where | Type |
|---|---|
| `InferenceValue.pixelBuffer`, `InferenceValue.init(_:)`, `AsyncMutableValue` | `CVMutablePixelBuffer` |
| `AsyncValue.init(_:)`, `AsyncValue.pixelBuffer` | `CVReadOnlyPixelBuffer` |

> ✅ **VERIFIED** from the declarations in §9.2 and §11.3. These are the Swift-native pixel-buffer
> types, and the mutable/read-only split mirrors the `MutableView`/`View` split on `NDArray` — same
> design idea, applied to CoreVideo.

### 12.2 What Apple's own vision code actually does: not this

Here is the finding that should reset your expectations about the image path:

> ✅ **VERIFIED** — grepping the entire `swift/Sources/` tree of `apple/coreai-models`,
> **`CVPixelBuffer` appears zero times.** Every vision product — segmentation, object detection,
> diffusion — takes a `CGImage` (or a `URL`/`CIImage` it immediately converts to `CGImage`) and
> **hand-builds a Float32 `NDArray`** with Core Graphics and Accelerate. There is no
> `CVPixelBuffer`-backed zero-copy path anywhere in that repository.

So Apple ships an image-typed value system in the framework, and Apple's own Swift package does not
use it. Two readings, and we cannot distinguish them:

> 🔴 **GAP — is the `CVMutablePixelBuffer` path the recommended one for camera input?**
>
> **What is unknown:** whether Core AI supports binding an `NDArray` to a `CVPixelBuffer` or
> `IOSurface` for zero-copy camera input in practice, and why Apple's own vision products don't use
> the image path. `NDArray.RawView.init(ioSurface:…)` exists and a `CVPixelBuffer` is
> `IOSurface`-backed, so a zero-copy route is at least *plausible* — but no Apple code or
> documentation demonstrates it end to end.
>
> **What would resolve it:** an Apple sample project (there are none), a `coreai-torch` doc page
> showing how a value is *marked* as an image at conversion time (we could not find one), or an
> Apple-staff forum answer.
>
> **Safe default meanwhile: follow Apple's own package, not Apple's own framework.** Take a
> `CGImage`, render it into a known bitmap context, normalise with vDSP, and write Float32 into an
> `NDArray`. That path is fully worked, ships in `apple/coreai-models`, and does not depend on the
> unresolved question. Revisit if you measure the render+copy as a bottleneck.

### 12.3 The CGImage → tensor recipe, from Apple's package

Every decision in this code is deliberate and worth copying:

> ✅ **VERIFIED** — `apple/coreai-models`, `CoreAIShared/Image/ImagePreprocessor.swift`:
>
> ```swift
> public enum ImageStrategy: String, Codable, Sendable {
>     case stretch
>     case centerCrop = "center_crop"
>     case pad
> }
>
> public struct ImagePreprocessor: Sendable {
>     public let targetSize: CGSize
>     public let mean: (CGFloat, CGFloat, CGFloat)
>     public let std: (CGFloat, CGFloat, CGFloat)
>     public let rescaleFactor: CGFloat
>
>     public static let gemma3: ImagePreprocessor   // 896×896, ImageNet mean/std, rescale 1.0
>     public static let clip:   ImagePreprocessor   // 336×336, CLIP mean/std,     rescale 1.0
>
>     // NHWC RGBA Float32 — returns (Data, width, height)
>     public func preprocess(cgImage: CGImage) throws -> (Data, Int, Int)
>
>     // Planar CHW Float32 — [3, H, W] flattened
>     public func preprocessCHW(cgImage: CGImage) throws -> [Float]
>     public func preprocessCHW(cgImage: CGImage, strategy: ImageStrategy) throws -> [Float]
> }
> ```

The pixel-format decisions, all ✅ VERIFIED from that file:

- **Colour space is hard-pinned to `CGColorSpace.sRGB`** in both the resize and normalize contexts —
  *not* device RGB — so results are display-independent.
- `bitsPerComponent: 8`, `bytesPerRow: width * 4`,
  `bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue` — RGBA8 with alpha ignored.
- **`ctx.interpolationQuality = .high`**, with the source's own claim that it *"matches PIL BICUBIC
  closely"*. **This is the PyTorch-parity lever.** If your Swift outputs drift from your Python
  reference and the model is otherwise correct, check this first.
- Output is `[H, W, 4]` Float32 NHWC with **alpha zero-filled**, and the doc says: *"The caller
  transposes to `[1, 3, H, W]` (NCHW) before binding to a vision encoder input."*
- Normalisation is `(pixel * rescale − mean) / std`, folded into a single fused multiply-add per
  channel, with `/255.0` folded into `scale` — *so `rescaleFactor: 1.0` means "map [0,255] → [0,1]"*.

```swift prelude:guide-context
// ✅ VERIFIED — apple/coreai-models, ImagePreprocessor.swift:251-265, verbatim
let scale = Float(rescaleFactor) / 255.0
let means: [Float] = [Float(mean.0), Float(mean.1), Float(mean.2)]
let stds:  [Float] = [Float(std.0),  Float(std.1),  Float(std.2)]

var channel = [Float](repeating: 0, count: pixelCount)
let n = vDSP_Length(pixelCount)
for c in 0..<3 {
    var a = scale / stds[c]
    var b = -means[c] / stds[c]
    vDSP_vfltu8(rawPixels.advanced(by: c), 4, &channel, 1, n)          // UInt8 -> Float, stride 4
    vDSP_vsmsa(channel, 1, &a, &b, dstBase.advanced(by: c), 4, n)      // out = in*a + b, stride 4
}
var zero: Float = 0
vDSP_vfill(&zero, dstBase.advanced(by: 3), 4, n)                        // alpha = 0
```

There is a second, faster implementation in the same repo for the no-per-channel-stats case:

> ✅ **VERIFIED** — `CGImageUtils.toNormalizedPlanarRGB` hardcodes the diffusion normalisation
> `(pixel / 127.5) − 1.0` and does the whole planar conversion in **four vDSP calls total**, because
> the de-interleave already writes planar so a single `vDSP_vsmsa` covers all `3 * pixelCount`
> elements at once. **This is the faster of the two** and the one to copy when you don't need
> per-channel mean/std. (⚠️ It uses `CGImageAlphaInfo.premultipliedLast`, not `noneSkipLast`, and
> its `resize` is square-only — the two files disagree with each other.)

Resize-strategy semantics, exactly as implemented (✅ VERIFIED):

| Strategy | Implementation | Trap |
|---|---|---|
| `.stretch` | draw into `targetW × targetH`, filling the rect | aspect ratio **not** preserved |
| `.centerCrop` | shortest edge → target, render, then centered crop | **renders twice**; negative crop origin when the source is smaller than the target in the long dimension → `cropping(to:)` returns `nil` → `.renderFailed` |
| `.pad` | longest edge → target, draw centered on a zero canvas | pads with zeros in **pixel** space, so the padding becomes `(0 − mean)/std` after normalisation, **not** tensor-space zero |

### 12.4 ⚠️ SILENT FAILURE: EXIF orientation is nobody's job, so it is yours

> ⚠️ **SILENT FAILURE — the same JPEG produces two differently-oriented tensors depending on which
> loader you used, and nothing tells you.**
>
> ✅ **VERIFIED** — grepping `apple/coreai-models`' entire non-LLM Swift tree for
> `orientation|exif|kCGImageProperty` returns **zero** handling. And the two entry points in that
> repository disagree:
> - `ImagePreprocessor.preprocess(imageURL:)` goes through **`CIImage(contentsOf:)`**, which **does**
>   apply EXIF orientation.
> - The CLI tools go through **`CGImageSourceCreateImageAtIndex`**, which **does not**.
>
> So a photo shot in portrait on an iPhone — EXIF orientation 6, pixels stored landscape — is fed to
> the model rotated 90° by one path and upright by the other. The research pass that found this
> called it *"a real, unfixed inconsistency in the repo."*
>
> **Why it is silent:** a segmentation model handed a sideways image does not throw. It returns
> masks. They are just wrong, in a way that looks like "the model isn't very good" rather than "the
> input was rotated". This is the single most expensive debugging session in on-device vision, and
> the cause is four lines of missing code.
>
> **Safe default — normalise orientation at the boundary, once, explicitly:**
>
> ```swift
> import ImageIO
> import CoreImage
> import UniformTypeIdentifiers
>
> /// Load a file into an upright CGImage with EXIF orientation applied.
> func loadUprightCGImage(at url: URL) -> CGImage? {
>     guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
>           let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
>
>     let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
>     let raw = props?[kCGImagePropertyOrientation] as? UInt32 ?? 1
>     guard raw != 1 else { return cgImage }            // already up
>
>     let ci = CIImage(cgImage: cgImage)
>         .oriented(forExifOrientation: Int32(raw))
>     return CIContext().createCGImage(ci, from: ci.extent)
> }
> ```
>
> For live camera frames the orientation comes from the connection, not from EXIF — read
> `AVCaptureConnection.videoRotationAngle` (or your capture pipeline's equivalent) and normalise
> before preprocessing. For `PhotosPicker` / `Transferable` loads, the item may or may not be
> pre-rotated depending on the representation you asked for; assert on it in a test.
>
> **Write a test with a deliberately EXIF-rotated fixture.** It is the only way this stays fixed.

### 12.5 One more coordinate trap, for completeness

Since you are already in vision-land: the *output* side has a matching problem, and this one is
platform-conditional.

> ⚠️ ✅ **VERIFIED** — `apple/coreai-models`, `SegmentationPostprocessor.decodeSegment`:
>
> ```swift
> // AppKit/macOS uses bottom-left origin, so flip Y for macOS.
> // UIKit/iOS uses top-left origin matching the model output directly.
> #if os(macOS)
> box = CGRect(x: x0 * imageWidth, y: (1.0 - y1) * imageHeight, …)
> #else
> box = CGRect(x: x0 * imageWidth, y: y0 * imageHeight, …)
> #endif
> ```
>
> **`Segment.box` origin flips on macOS. `DetectedObject.boundingBox` does not** — it is always
> top-left, on every platform. And `SegmentationVisualization.renderPromptBoxes` demands top-left
> *"regardless of platform"*, so on macOS you must **not** feed `Segment.box` straight into it. Two
> box conventions (XYXY normalized vs `cxcywh` normalized) and two origin conventions coexist in one
> Apple repository.
>
> Full treatment in [Part 16](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/README.md). Mentioned here so that when your
> masks land in the right place on iPhone and upside-down on Mac, you know it is not your code.

---

## 13. ✅ The error-type answer, and how to write a `catch` block

This was the most consequential unknown in the Core AI Swift API, and it blocked something you have
to do on day one. It is now settled — by reading the SDK itself.

### 13.1 The answer, stated precisely

> ✅ **VERIFIED (SDK) — in the macOS 27.0 beta interface, the throwing runtime APIs throw *untyped*
> errors, and the only public error type in the entire Core AI Swift surface is
> `CoreAIAsset.AssetError`.**
>
> On 2026-07-29 the shipped module interfaces were dumped from the Xcode 27.0 beta (27A5228h)
> macOS 27.0 SDK into `notes/sdk-interfaces/`. The structural discovery first:
> **`CoreAI` is an umbrella.** The `CoreAI` module is a one-line
> `@_exported public import CoreAIDelegates`, and `CoreAIDelegates` in turn re-exports
> `CoreAIAsset`, `CoreAICommon`, `CoreAICompiler` and `CoreAIRuntime`
> (`CoreAIDelegates-27.0-macos.swiftinterface:5-8`). `CoreAICommon`, `CoreAICompiler` and
> `CoreAICache` have **empty public Swift surfaces** in this beta.
>
> With the whole surface in hand, the error question closes:
>
> - **`CoreAIRuntime` declares no public error type at all.** Every throwing API is a plain,
>   untyped `throws` / `async throws`: both `run` overloads
>   (✅ **SDK-verified** — `CoreAIRuntime-27.0-macos.swiftinterface:96-103`), `encode` (`:92-95`),
>   and the async value getters on `AsyncValue` / `AsyncMutableValue` (`:28-36`, `:60-68`).
> - **The loading surface lives in `CoreAIDelegates`, and it is untyped too:**
>   `AIModel.init(contentsOf:options:)` and `AIModel.specialize(…)` are `async throws`
>   (✅ **SDK-verified** — `CoreAIDelegates-27.0-macos.swiftinterface:22-26`),
>   `loadFunction(named:)` is `throws -> InferenceFunction?` (`:119-122`), and all four cache
>   `delete*` methods plus `model(for:options:)` are plain `throws` (`:33-43`).
> - **The one public error type** is `AssetError` in `CoreAIAsset`
>   (✅ **SDK-verified** — `CoreAIAsset-27.0-macos.swiftinterface:230-237`, `Kind` at `:239-247`):
>
> ```swift
> public struct AssetError: Error, LocalizedError {     // CoreAIAsset-27.0:230-237
>     public var kind: AssetError.Kind
>     public var debugMessage: String?
>     public init(kind: AssetError.Kind, debugMessage: String?)
>     public var errorDescription: String? { get }
> }
> extension AssetError {                                // CoreAIAsset-27.0:239-247
>     public enum Kind: Sendable {
>         case unsupportedVersion(String)   // "a more recent version of this library generated the asset"
>         case invalidFeatureType(String)
>         case corruptedMetadata            // "the asset metadata is corrupted"
>         case invalidName
>         case duplicateName                // "a component with that name already exists in the asset"
>     }
> }
> ```
>
> Its documentation abstract is *"An error that occurs during **model asset operations**."* Every
> case is about the *asset file*: metadata, names, versions. **Nothing in it describes an inference
> failure, a specialization failure, a compute-unit failure, or a cache-eviction conflict — and in
> the macOS 27.0 beta interface, no public type does.** There is no public inference,
> specialization or cache error enum to catch.
>
> Note also that `AssetError` has a **public initializer**, so it is not a sealed system error — app
> code can construct one. It is a *reporting* type for asset tooling, not the framework's error
> taxonomy; the framework does not publish one.
>
> **What Apple's own documentation does instead of naming a type.** Several `- Throws:` clauses are
> malformed in the published docs and render as orphaned Notes with no type attached:
> - on `AIModel.init(contentsOf:options:)` and `AIModel.specialize(…)`: *"If specializing or loading
>   the model fails."*
> - on `AIModelCache.model(for:options:)`: *"If a cache entry was found but the specialized asset
>   failed to load."*
>
> Those clauses now read as consistent with the interface: there is no type name to print, because
> the throws are untyped.
>
> **What about `AIModelError`?** ⚠️ **Community-reported**, from a `apple/coreai-models`
> GitHub issue thread (2026-07, macOS 27 beta, AOT-compiled `.aimodelc`): a failed load surfaced as
>
> ```
> CoreAIDelegates.AIModelError error 3      ← raw AIModel.load
> invalidCompiledModel                      ← as re-mapped by llm-runner / LanguageBundle
> ```
>
> The interface dump confirms what that breadcrumb implied: something spelled `AIModelError` exists
> *inside* `CoreAIDelegates`, but it is **not present in the module's public interface in the
> macOS 27.0 beta SDK** — it is internal, surfacing only through `NSError` bridging with a numeric
> code. You still cannot pattern-match on it, and that is now a verified fact about the beta SDK
> rather than a documentation hole.
>
> **What this means for your `catch` blocks:** match `AssetError` (and switch on its five `Kind`
> cases above) for asset operations; everything else — specialization, load, run, cache deletion —
> must go through a generic `catch`, logging the `NSError` domain/code for diagnostics. Branching on
> "out of memory" vs "compute unit unavailable" vs "cache invalidated" is not possible with the
> public API in this beta. If a later seed publishes an error taxonomy, this section will be
> revised; the diagnostic helper in §13.2 is how you would notice first.

### 13.2 The practice: catch `AssetError`, then catch broadly, log richly, degrade

Because the beta SDK publishes no taxonomy beyond `AssetError`, correct Core AI error handling has
three properties: it **catches everything**, it **records enough to diagnose later**, and it
**degrades rather than retrying blindly**.

```swift compile:27
import CoreAI
import Foundation
import os

private let log = Logger(subsystem: "com.example.app", category: "CoreAI")

/// Everything we can learn about an unknown error, without naming its type.
func describeCoreAIError(_ error: any Error) -> String {
    let dynamicType = String(reflecting: type(of: error))     // e.g. "CoreAI.AssetError"
    let ns = error as NSError
    var parts: [String] = [
        "type=\(dynamicType)",
        "domain=\(ns.domain)",
        "code=\(ns.code)",
        "localized=\(error.localizedDescription)",
    ]
    if let localized = error as? LocalizedError {
        if let d = localized.errorDescription { parts.append("errorDescription=\(d)") }
        if let r = localized.failureReason     { parts.append("failureReason=\(r)") }
        if let s = localized.recoverySuggestion { parts.append("recovery=\(s)") }
    }
    if let assetError = error as? AssetError {                 // the ONE type we can name
        parts.append("assetKind=\(assetError.kind)")
        if let m = assetError.debugMessage { parts.append("debugMessage=\(m)") }
    }
    if !ns.userInfo.isEmpty {
        parts.append("userInfo=\(ns.userInfo.keys.sorted { "\($0)" < "\($1)" })")
    }
    return parts.joined(separator: " ")
}
```

`String(reflecting: type(of: error))` is the important line. It gives you the fully-qualified
dynamic type of whatever was actually thrown — including non-public types like
`CoreAIDelegates.AIModelError` that the interface hides (§13.1). **Log it: it is your only window
into the internal taxonomy, and the first place a future seed's public error type will show up.**

Now the ladder. Note the ordering rule: **the specific named type first, the broad catch last** —
Swift matches `catch` clauses in order, so a bare `catch` above a typed one makes the typed one dead
code.

```swift illustrative
enum FeatureState {
    case ready(InferenceFunction)
    case unavailable(reason: String)      // degrade: hide or disable the feature
    case needsRedownload                  // the asset itself is bad
}

func prepareFeature(modelURL: URL,
                    options: SpecializationOptions = .default) async -> FeatureState {
    do {
        // 1. Cheap probe. Distinct failure domain from specialization.
        guard AIModelAsset.isValid(at: modelURL) else {
            return .needsRedownload
        }

        // 2. Cache check, then specialize.
        let model: AIModel
        if let cached = try AIModelCache.default.model(for: modelURL, options: options) {
            model = cached
        } else {
            model = try await AIModel(contentsOf: modelURL, options: options)
        }

        // 3. Load the function. `nil` and `throws` mean different things — see §4.
        guard let function = try model.loadFunction(named: "main") else {
            log.error("No 'main' function. Available: \(model.functionNames, privacy: .public)")
            return .needsRedownload
        }
        return .ready(function)

    } catch let error as AssetError {
        // The one type Apple documents. Asset-level problems: corrupt metadata,
        // an asset written by a newer toolchain, an invalid component name.
        log.error("Core AI asset error: \(describeCoreAIError(error), privacy: .public)")
        return .needsRedownload

    } catch {
        // EVERYTHING else — specialization failure, load failure, OOM, the
        // non-public AIModelError. We cannot distinguish these today (§13.1).
        log.error("Core AI failure: \(describeCoreAIError(error), privacy: .public)")
        return .unavailable(reason: error.localizedDescription)
    }
}
```

> ⚠️ **Ordering matters and it is easy to get wrong.** `catch let error as AssetError` must come
> **before** the bare `catch`. An earlier batch of guides in this series shipped a catch ladder in
> the wrong order; it compiles, it just never runs the specific branch. If you add more typed
> clauses later, keep the bare `catch` last, always.

### 13.3 Four rules that survive the gap

**(1) Never `try?` a Core AI call whose failure you would want to know about.** `try?` collapses
"the name was wrong" and "the device ran out of memory" into `nil`, and the gap means you cannot
recover the difference afterwards.

**(2) Distinguish the `nil` channels, which *are* documented.** Three APIs return `nil` with a
precise, verified meaning, and none of them is an error:

| API | `nil` means | `throws` means |
|---|---|---|
| `loadFunction(named:)` | no function with that name | loading it failed |
| `functionDescriptor(for:)` | no function with that name | *(does not throw)* |
| `AIModelCache.model(for:options:)` | not cached — specialize | a cache entry existed but failed to load |
| `AIModel.init?(resolvingBookmark:)` | valid bookmark, stale entry | **malformed** bookmark data |
| `AIModelCache(appGroup:)` | invalid identifier / entitlement / container | *(does not throw)* |

> ✅ **VERIFIED** — the bookmark row is worth reading twice. From `init(resolvingBookmark:)`:
> *"If it cannot be resolved due to the specialized asset entry no longer being present **nil is
> returned**"*, and NOTE: *"If the bookmark data is malformed due to not being sourced from
> `AIModel.bookmarkData` **an error is thrown**."* **`nil` is the recoverable case** (re-download and
> re-specialize); the throw is a programming error.

**(3) Treat cache-deletion failure as expected, not exceptional.** Per §3.4, the reference
documentation says deleting an entry still referenced by a live `AIModel` **throws**. Release your
models, then delete, then retry once.

**(4) Degrade, don't loop.** Because you cannot tell a transient failure from a permanent one, a
retry loop around `AIModel.init` is a battery bug waiting to happen. Fail the feature, tell the
person, offer a manual retry.

### 13.4 What the *rest* of the stack throws, for contrast

It is worth knowing that the layer above Core AI has a perfectly good error taxonomy, so if you are
using `apple/coreai-models` rather than raw Core AI, you are not in this position:

> ✅ **VERIFIED** — `apple/coreai-models`, `ModelBundle.BundleError`: `.missingMetadata(URL)`,
> `.malformedMetadata(URL, underlying:)`, `.unsupportedVersion(String)`,
> `.kindMismatch(expected:got:)`, `.missingField(String)`, `.missingAsset(key:path:)`,
> `.pointedAtModelAsset(URL)`. Plus `KVCacheError.capacityExceeded`,
> `XGrammarError.schemaCompilationFailed(String)`, `ConstrainedGenerationError.{invalidSchema,
> generationFailed}`.

and a community integration defines twenty cases of its own rather than rely on the framework's:

> ✅ **VERIFIED** — `1amageek/swift-lm` (⚠️ **community**), `CoreAIModelAssetError`:
> `.invalidAsset(URL)`, `.functionNotFound(String)`, `.inputNotFound(function:input:)`,
> `.unexpectedInput(function:input:)`, `.invalidInputShape(function:input:expected:provided:)`,
> `.invalidInputDataType(function:input:expected:provided:)`, `.stateNotFound(function:state:)`,
> `.statefulFunctionRequiresStateSession(String)`, `.stateAllocationFailed(String)`,
> `.unsupportedOutputCount(Int)`, `.contractMismatch(function:message:)`, and nine more.

**Both of them wrap Core AI rather than propagating it.** That is the pattern: define your own
error enum at the boundary, put the framework's opaque error in an `underlying: any Error`
associated value, and never let an un-named error escape into your app's control flow.

---

## 14. A complete runner you can paste

This puts §3, §4, §6, §8, §9 and §13 together into one type. It is **descriptor-driven** — it never
hardcodes a shape — so it survives a model re-export (§6.1). Every Core AI member it calls is
✅ VERIFIED in the sections above; the assembly is mine and is marked 🟡 RECONSTRUCTED as a whole.

```swift compile:27
import CoreAI
import Foundation
import os

// MARK: - Span helper (see §7.5 — Span doesn't conform to Sequence)

extension Span where Element == Int {
    var product: Int {
        var result = 1
        for i in 0..<count { result *= self[i] }
        return result
    }
}

// MARK: - Errors (see §13 — wrap, never propagate an unnamed error)

enum TensorRunnerError: Error, LocalizedError {
    case notAModelAsset(URL)
    case functionNotFound(requested: String, available: [String])
    case functionLoadFailed(name: String, underlying: any Error)
    case argumentNotFound(String, available: [String])
    case argumentIsImage(String)
    case scalarTypeMismatch(String, expected: NDArray.ScalarType, actual: NDArray.ScalarType)
    case shapeMismatch(String, expected: [Int], provided: [Int])
    case elementCountMismatch(String, expected: Int, provided: Int)
    case nonContiguous(String)
    case interleavedLayout(String)
    case outputMissing(String)
    case outputNotATensor(String)
    case unsupportedScalarType(NDArray.ScalarType)
    case coreAIFailure(stage: String, underlying: any Error)

    var errorDescription: String? {
        switch self {
        case .notAModelAsset(let url):
            return "Not a Core AI model asset: \(url.lastPathComponent)"
        case .functionNotFound(let requested, let available):
            return "No function '\(requested)'. Available: \(available)"
        case .functionLoadFailed(let name, let underlying):
            return "Failed to load function '\(name)': \(underlying.localizedDescription)"
        case .argumentNotFound(let name, let available):
            return "No argument '\(name)'. Available: \(available)"
        case .argumentIsImage(let name):
            return "Argument '\(name)' is image-typed; this runner handles tensors only."
        case .scalarTypeMismatch(let name, let expected, let actual):
            return "Argument '\(name)' expects \(expected) but got \(actual)."
        case .shapeMismatch(let name, let expected, let provided):
            return "Argument '\(name)' expects shape \(expected) but got \(provided)."
        case .elementCountMismatch(let name, let expected, let provided):
            return "Argument '\(name)' needs \(expected) elements; \(provided) provided."
        case .nonContiguous(let name):
            return "Argument '\(name)' has a non-contiguous layout; use the stride-walking writer."
        case .interleavedLayout(let name):
            return "Argument '\(name)' has an interleave layout; block strides are not handled here."
        case .outputMissing(let name):
            return "Output '\(name)' was not returned. Did you pass an outputView for it? (§9.4)"
        case .outputNotATensor(let name):
            return "Output '\(name)' is an image, not a tensor."
        case .unsupportedScalarType(let t):
            return "Unsupported scalar type \(t)."
        case .coreAIFailure(let stage, let underlying):
            return "Core AI failed during \(stage): \(underlying.localizedDescription)"
        }
    }
}

// MARK: - The runner

/// A descriptor-driven wrapper around one Core AI inference function.
///
/// Deliberately narrow: Float32 tensor in, Float32 tensor out, no states.
/// Extend from here — the descriptor plumbing is the reusable part.
public actor TensorRunner {

    private static let log = Logger(subsystem: "com.example.app", category: "CoreAI")

    private let model: AIModel
    private let function: InferenceFunction
    private let descriptor: InferenceFunctionDescriptor

    // MARK: Setup

    /// Loads and (if necessary) specializes the model, then loads one function.
    ///
    /// - Parameter onSpecializationNeeded: called on the main actor *before* a cold
    ///   specialization begins. Show explanatory UI here; this can take seconds.
    public init(
        modelURL: URL,
        functionName: String = "main",
        options: SpecializationOptions = .default,
        onSpecializationNeeded: @Sendable @MainActor () -> Void = {}
    ) async throws {
        // §3.3 step 0 — cheap validity probe, no throw, no await.
        guard AIModelAsset.isValid(at: modelURL) else {
            throw TensorRunnerError.notAModelAsset(modelURL)
        }

        // §3.3 steps 2–3 — cache first, then specialize. One `options` value throughout,
        // because the cache key is (URL, options). See the §3.3 warning.
        let model: AIModel
        do {
            if let cached = try AIModelCache.default.model(for: modelURL, options: options) {
                model = cached
            } else {
                await onSpecializationNeeded()
                model = try await AIModel(contentsOf: modelURL, options: options)
            }
        } catch {
            throw TensorRunnerError.coreAIFailure(stage: "specialization", underlying: error)
        }
        self.model = model

        // §4 — separate the two failure channels.
        let loaded: InferenceFunction?
        do {
            loaded = try model.loadFunction(named: functionName)
        } catch {
            throw TensorRunnerError.functionLoadFailed(name: functionName, underlying: error)
        }
        guard let function = loaded else {
            throw TensorRunnerError.functionNotFound(requested: functionName,
                                                     available: model.functionNames)
        }
        self.function = function
        self.descriptor = function.descriptor

        Self.log.info("""
            Core AI function '\(functionName, privacy: .public)' ready — \
            inputs: \(self.descriptor.inputNames, privacy: .public), \
            outputs: \(self.descriptor.outputNames, privacy: .public), \
            states: \(self.descriptor.stateNames, privacy: .public)
            """)
    }

    // MARK: Introspection

    public var inputNames: [String]  { descriptor.inputNames }
    public var outputNames: [String] { descriptor.outputNames }
    public var stateNames: [String]  { descriptor.stateNames }

    /// Concrete shape and scalar type for an input, with `-1` for dynamic axes. See §6.
    public func inputShape(_ name: String) throws -> (shape: [Int], scalarType: NDArray.ScalarType) {
        guard let value = descriptor.inputDescriptor(of: name) else {
            throw TensorRunnerError.argumentNotFound(name, available: descriptor.inputNames)
        }
        guard case .ndArray(let d) = value else {
            throw TensorRunnerError.argumentIsImage(name)
        }
        return (d.shape, d.scalarType)
    }

    /// Log every input whose preferred layout is not plain contiguous. See §11.1.
    public func auditLayouts(concreteShapes: [String: [Int]] = [:]) {
        for name in descriptor.inputNames {
            guard let v = descriptor.inputDescriptor(of: name),
                  case .ndArray(let d) = v else { continue }
            let resolved = d.hasDynamicShape
                ? d.resolvingDynamicDimensions(concreteShapes[name] ?? d.shape)
                : d
            let preferred = resolved.preferredStrides
            let contiguous = Self.rowMajorStrides(resolved.shape)
            if preferred != contiguous {
                Self.log.notice("""
                    input '\(name, privacy: .public)': preferred strides \
                    \(preferred, privacy: .public) != contiguous \(contiguous, privacy: .public) \
                    — a contiguous NDArray will be copied on every run.
                    """)
            }
        }
    }

    // MARK: Inference

    /// Run with a single Float32 input and read a single Float32 output.
    public func run(
        _ values: [Float],
        inputName: String,
        outputName: String,
        concreteShape: [Int]? = nil
    ) async throws -> (values: [Float], shape: [Int]) {

        // --- Build the input, validated against the descriptor (§6, §8) ---
        guard let inputValue = descriptor.inputDescriptor(of: inputName) else {
            throw TensorRunnerError.argumentNotFound(inputName, available: descriptor.inputNames)
        }
        guard case .ndArray(let inputDescriptor) = inputValue else {
            throw TensorRunnerError.argumentIsImage(inputName)
        }
        guard inputDescriptor.scalarType == .float32 else {
            throw TensorRunnerError.scalarTypeMismatch(inputName,
                                                       expected: inputDescriptor.scalarType,
                                                       actual: .float32)
        }

        let resolved: NDArrayDescriptor
        if inputDescriptor.hasDynamicShape {
            // §6.4 — you MUST resolve before touching preferredStrides/minimumByteCount,
            // and before NDArray(descriptor:).
            guard let concreteShape else {
                throw TensorRunnerError.shapeMismatch(inputName,
                                                      expected: inputDescriptor.shape,
                                                      provided: [])
            }
            resolved = inputDescriptor.resolvingDynamicDimensions(concreteShape)
        } else {
            resolved = inputDescriptor
        }

        let elementCount = resolved.shape.reduce(1, *)
        guard elementCount == values.count else {
            throw TensorRunnerError.elementCountMismatch(inputName,
                                                         expected: elementCount,
                                                         provided: values.count)
        }

        // Contiguous allocation. Swap for `NDArray(descriptor: resolved)` once
        // `auditLayouts` says the preferred strides differ — and then use the
        // stride-walking writer from §8.3.
        var input = NDArray(shape: resolved.shape, scalarType: .float32)
        var writeView = input.mutableView(as: Float.self)
        guard writeView.interleaveLayout == nil else {
            throw TensorRunnerError.interleavedLayout(inputName)
        }
        guard var slots = writeView.contiguousElements else {
            throw TensorRunnerError.nonContiguous(inputName)
        }
        for i in 0..<values.count { slots[i] = values[i] }

        // --- Run (§8.4). No states, no pre-allocated outputs. ---
        var outputs: InferenceFunction.Outputs
        do {
            outputs = try await function.run(inputs: [inputName: input])
        } catch {
            throw TensorRunnerError.coreAIFailure(stage: "run", underlying: error)
        }

        // --- Extract (§9). remove() is destructive; .ndArray is consuming. ---
        guard let value = outputs.remove(outputName) else {
            throw TensorRunnerError.outputMissing(outputName)
        }
        guard value.kind == .ndArray else {
            throw TensorRunnerError.outputNotATensor(outputName)
        }
        guard let array = value.ndArray else {
            throw TensorRunnerError.outputNotATensor(outputName)
        }

        // Branch on the ARRAY's own scalar type, never on a cached flag (§7.10).
        let shape = array.shape
        switch array.scalarType {
        case .float32:
            return (Self.flatten(array, as: Float.self), shape)
        #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
        case .float16:
            return (Self.flatten(array, as: Float16.self).map(Float.init), shape)
        #endif
        default:
            throw TensorRunnerError.unsupportedScalarType(array.scalarType)
        }
    }

    // MARK: Helpers

    /// `run`'s returned arrays are documented row-major contiguous (§9.3), but we
    /// still handle the general case so this is safe to reuse elsewhere.
    private static func flatten<T: BitwiseCopyable>(_ array: NDArray, as type: T.Type) -> [T] {
        let view = array.view(as: type)
        if let elements = view.contiguousElements {
            var out = [T]()
            out.reserveCapacity(elements.count)
            for i in elements.indices { out.append(elements[i]) }
            return out
        }
        return view.withUnsafePointer { ptr, shape, strides in
            let total = shape.product
            let rank = shape.count
            var out = [T]()
            out.reserveCapacity(total)
            var index = [Int](repeating: 0, count: rank)
            for _ in 0..<total {
                var offset = 0
                for axis in 0..<rank { offset += index[axis] * strides[axis] }
                out.append(ptr[offset])
                var axis = rank - 1
                while axis >= 0 {
                    index[axis] += 1
                    if index[axis] < shape[axis] { break }
                    index[axis] = 0
                    axis -= 1
                }
            }
            return out
        }
    }

    private static func rowMajorStrides(_ shape: [Int]) -> [Int] {
        var strides = [Int](repeating: 1, count: shape.count)
        for axis in stride(from: shape.count - 2, through: 0, by: -1) {
            strides[axis] = strides[axis + 1] * shape[axis + 1]
        }
        return strides
    }
}
```

### 14.1 Using it

```swift prelude:guide-context
let runner = try await TensorRunner(
    modelURL: Bundle.main.url(forResource: "MyModel", withExtension: "aimodel")!,
    functionName: "main"
) {
    // Runs on the main actor, only on a cold cache. Show your first-run UI here.
    appState.showModelPreparationScreen()
}

await runner.auditLayouts()                             // one-time §11.1 check

let (logits, shape) = try await runner.run(
    features,
    inputName: "features",
    outputName: "logits"
)
print("logits \(shape): \(logits.prefix(8))")
```

### 14.2 Where to extend it

| Need | Change |
|---|---|
| States (KV cache) | allocate one `NDArray` per `stateNames` entry at init (§10.3), hold them as stored properties, rebuild `MutableViews` per call |
| Pre-allocated outputs | add an `outputViews:` argument — and delete the `outputs.remove` for that name (§9.4) |
| Preferred strides | `NDArray(descriptor: resolved)` + the stride-walking writer from §8.3 |
| Image inputs | `case .image(let d) = inputValue`, build a `CVMutablePixelBuffer` matching `d.pixelFormatType`/`width`/`height`, and normalise orientation first (§12.4) |
| Multi-function pipelines | `encode(…to: stream)` and `AsyncValue` (§11.3) instead of `run` |
| Concurrency | the actor already serialises; for real parallelism drop the actor, keep `InferenceFunction` shared, and **bound the fan-out** (§5.2) |

---

## 15. Quick reference

### 15.1 The whole runtime API on one screen

> ✅ **SDK-verified as a whole (2026-07-29):** every declaration in this block was checked against
> the captured macOS 27.0 beta interfaces (`CoreAIRuntime` / `CoreAIDelegates` / `CoreAIAsset` —
> see §16.1). `import CoreAI` works because `CoreAI` is an umbrella re-export of `CoreAIDelegates`,
> which re-exports the rest.

```swift illustrative
import CoreAI      // iOS/iPadOS/macOS/Mac Catalyst/tvOS/visionOS/watchOS 27.0+ (Beta)

// ───────── Model ─────────
struct AIModel: Sendable, SendableMetatype
  init(contentsOf: URL, options: SpecializationOptions = .default) async throws
  init?(resolvingBookmark: Data) throws
  func loadFunction(named: String) throws -> InferenceFunction?
  func functionDescriptor(for: String) -> InferenceFunctionDescriptor?
  var functionNames: [String]
  @discardableResult static func specialize(contentsOf:options:cache:cachePolicy:) async throws -> AIModel
  var bookmarkData: Data
  static var deviceArchitectureName: String

struct AIModelAsset                                   // unspecialized; cannot infer
  init(contentsOf: URL) throws                        // NOT async
  static func isValid(at: URL) -> Bool
  func summary(includingStatistics: Bool) throws -> AIModelAsset.Summary?
  var metadata: AIModelAsset.Metadata
  mutating func updateMetadata(_: (inout Metadata) throws -> Void) throws
  mutating func removeDerivedArtifacts() throws

// ───────── Function ─────────
struct InferenceFunction: Sendable, SendableMetatype
  let descriptor: InferenceFunctionDescriptor
  func run(inputs: [String: NDArray],
           states: consuming MutableViews = .init(),
           outputViews: consuming MutableViews = .init()) async throws -> Outputs
  func run(inputs: borrowing Inputs, states: …, outputViews: …) async throws -> Outputs
  func encode(inputs: [String: AsyncValue],
              states: consuming AsyncMutableViews = .init(),
              outputViews: consuming AsyncMutableViews = .init(),
              to stream: ComputeStream) throws -> [String: AsyncValue]     // NOT async

  struct Inputs        { init(); mutating func insert(…, for: String) }    // 3 overloads
  struct Outputs       { mutating func remove(_: String) -> InferenceValue?
                         var count: Int; var names: some Collection<String> }
  struct MutableViews  { init(); mutating func insert(…, for: String) }    // 3 overloads
  final class AsyncValue          // Sendable; init(NDArray) / (CVReadOnlyPixelBuffer) /
                                  //   (unsafeBuffer:…) / (AsyncMutableValue)
                                  // var ndArray: NDArray? { get async throws }
  struct AsyncMutableValue        // init(NDArray) / (CVMutablePixelBuffer) / (descriptor:) / (unsafeBuffer:…)
  struct AsyncMutableViews { init(); mutating func insert(_: inout AsyncMutableValue, for: String) }

struct InferenceFunctionDescriptor: Sendable
  var name: String
  var inputCount: Int;  var inputNames: [String];  func inputDescriptor(of: String) -> InferenceValue.Descriptor?
  var outputCount: Int; var outputNames: [String]; func outputDescriptor(of: String) -> InferenceValue.Descriptor?
  /* no stateCount */   var stateNames: [String];  func stateDescriptor(of: String) -> InferenceValue.Descriptor?

// ───────── Values ─────────
struct InferenceValue
  var kind: Kind                                       // .image | .ndArray
  var ndArray: NDArray?                                // ⚠️ CONSUMING read
  var pixelBuffer: CVMutablePixelBuffer?
  init(_ pixelBuffer: consuming CVMutablePixelBuffer)
  enum Kind { case image, ndArray }
  enum Descriptor { case image(ImageDescriptor), ndArray(NDArrayDescriptor) }
  struct View; struct MutableView
  struct NamedMutableViews { mutating func take(_: String) -> MutableView? }   // ⚠️ 2nd take = fatal
  protocol ViewRepresentable        { func view() -> InferenceValue.View }
  protocol MutableViewRepresentable { mutating func mutableView() -> InferenceValue.MutableView }

struct ImageDescriptor: Equatable, Sendable
  let pixelFormatType: OSType; let width: Int; let height: Int

// ───────── Arrays ─────────
struct NDArray: Escapable, Sendable, ViewRepresentable, MutableViewRepresentable
  init(shape: [Int], scalarType: ScalarType)                          // contiguous row-major
  init(shape: [Int], scalarType: ScalarType, strides: [Int])
  init(shape: [Int], scalarType: ScalarType, strides: [Int], interleaveLayout: InterleaveLayout)
  init<Scalar: BitwiseCopyable>(scalars: some Sequence, shape: [Int])
  init(descriptor: consuming NDArrayDescriptor)                       // ⚠️ may be non-contiguous
  var shape: [Int]; var scalarType: ScalarType; var strides: [Int]
  var interleaveLayout: InterleaveLayout?
  func view<T: BitwiseCopyable>(as: T.Type = T.self) -> View<T>
  mutating func mutableView<T: BitwiseCopyable>(as: T.Type = T.self) -> MutableView<T>
  func rawView() -> RawView
  mutating func mutableRawView() -> MutableRawView

  struct View<Element: BitwiseCopyable>            // non-escapable borrow
    var isContiguous: Bool; var rank: Int
    var shape: Span<Int>; var strides: Span<Int>   // ⚠️ Span is NOT a Sequence
    var contiguousElements: Span<Element>?         // nil when padded/strided/interleaved
    subscript<let rank: Int>(scalarAt: InlineArray<rank, Int>) -> Element
    func withUnsafePointer<R, E>((UnsafePointer<Element>, Span<Int>, Span<Int>) throws(E) -> R) throws(E) -> R
    func slice(at: [any RangeExpression]) -> View<Element>     // trailing dims default to .all
    var rawView: RawView

  struct MutableView<Element: BitwiseCopyable>
    var contiguousElements: MutableSpan<Element>?
    mutating func copyElements(from: some Sequence<Element>)
    mutating func copyElements(fromContentsOf: some Collection<Element>)
    func withUnsafeMutablePointer<R, E>((UnsafeMutablePointer<Element>, Span<Int>, Span<Int>) throws(E) -> R) throws(E) -> R
    func slice(at:) -> MutableView<Element>
    mutating func mutatingSlice(at:) -> MutableView<Element>   // ⚠️ use THIS to write through
    var view: View<Element>; var mutableRawView: MutableRawView

  struct RawView          // init(bytes:…) / init(metalBuffer:…) / init(ioSurface:…)
    consuming func view<T: BitwiseCopyable>(as: T.Type = T.self) -> View<T>   // ⚠️ consuming
  struct MutableRawView
    func view<T>(as: T.Type) -> MutableView<T>                  // ⚠️ returns MUTABLE view

  struct InterleaveLayout: Equatable, Sendable { init(dimension: Int, factor: Int) }
  protocol RangeExpression: Sendable { static var all: _AllRange { get }
                                       func relative(to: Range<Int>) -> Range<Int> }
  enum ScalarType: CaseIterable, Hashable, Sendable   // 35 cases — see §7.9

struct NDArrayDescriptor: Equatable, Sendable
  var shape: [Int]              // -1 == dynamic
  var scalarType: NDArray.ScalarType; var rank: Int
  var hasDynamicShape: Bool; var interleaveLayout: NDArray.InterleaveLayout?
  var minimumByteCount: Int     // ⚠️ programming error when hasDynamicShape
  var preferredStrides: [Int]   // ⚠️ same
  func resolvingDynamicDimensions(_ newShape: [Int]) -> NDArrayDescriptor

// ───────── Streams & configuration ─────────
final class ComputeStream
  convenience init(); init(commandQueue: any MTLCommandQueue)     // docs say no watchOS on the
  final func currentWorkCompleted() async                          //   latter; SDK declares
                                                                   //   watchOS 27.0 (§16.3). non-throwing

struct SpecializationOptions: Hashable, Sendable                   // ⚠️ part of the cache key
  static let `default`; static let cpuOnly
  init(preferredComputeUnitKind: ComputeUnitKind)
  var allowedComputeUnitKinds: Set<ComputeUnitKind>
  var preferredComputeUnitKind: ComputeUnitKind?
  var expectFrequentReshapes: Bool                                 // the only settable property

enum ComputeUnitKind: Hashable, Sendable { case cpu, gpu, neuralEngine
                                           static var availableKinds: Set<ComputeUnitKind> }

final class AIModelCache: Sendable
  static let `default`; init?(appGroup: String)
  func model(for: URL, options: SpecializationOptions) throws -> AIModel?   // never specializes
  func deleteEntry(for: URL, options: SpecializationOptions) throws
  func deleteEntries(for: URL) throws
  func deleteAll() throws
  static func deleteEntry(referencedBy bookmark: Data) throws
  struct Policy { static let `default`, persistent; init(purgeConditions:) }

// ───────── Errors ─────────
struct AssetError: Error, LocalizedError               // ⚠️ ASSET operations only — see §13
  enum Kind { case unsupportedVersion(String), invalidFeatureType(String),
                   corruptedMetadata, invalidName, duplicateName }
// ✅ SDK-verified: the ONLY public error type in the whole Core AI surface
// (CoreAIAsset-27.0-macos.swiftinterface:230-247). Everything else throws untyped.
// (Docs also list Sendable on AssetError; the beta interface does not declare it.)
```

### 15.2 `nil` vs `throws` vs trap — the cheat sheet

| API | `nil` | `throws` | traps |
|---|---|---|---|
| `AIModel.loadFunction(named:)` | no such function | load failed | — |
| `AIModel.functionDescriptor(for:)` | no such function | — | — |
| `AIModel.init?(resolvingBookmark:)` | stale entry | malformed data | — |
| `AIModelCache.model(for:options:)` | not cached | entry found but failed to load | — |
| `AIModelCache(appGroup:)` | bad id / entitlement / container | — | — |
| `AIModelAsset.summary(_:)` | no program bytecode | asset problem | — |
| `Outputs.remove(_:)` | absent, or already taken | — | — |
| `InferenceValue.ndArray` | it's an image | — | — |
| `View.contiguousElements` | non-contiguous layout | — | — |
| `NamedMutableViews.take(_:)` | no such name | — | **second take** |
| `NDArrayDescriptor.preferredStrides` | — | — | **when `hasDynamicShape`** |
| `NDArrayDescriptor.minimumByteCount` | — | — | **when `hasDynamicShape`** |

### 15.3 Every silent failure in this guide

| # | What silently goes wrong | Section |
|---|---|---|
| 1 | A contiguous `NDArray` gets **copied into the preferred layout on every `run`** — correct results, permanent throughput tax, zero diagnostics | §11.1 |
| 2 | Passing `outputViews:` for a name **removes it from the returned `Outputs`** — existing `outputs.remove(name)` code starts reporting "missing output" | §9.4 |
| 3 | Concurrent `run` calls **silently allocate more intermediate buffers**; unbounded fan-out works on a Mac and gets jetsammed on a phone | §5.2 |
| 4 | **EXIF orientation** is applied by `CIImage(contentsOf:)` and not by `CGImageSourceCreateImageAtIndex` — same JPEG, two orientations, no error | §12.4 |
| 5 | `AsyncValue.ndArray` **returns a copy** when the value was built from an `MTLBuffer`, silently undoing the zero-copy you engineered | §11.3 |
| 6 | Caching a dtype flag from the input descriptor and reading an output with it **reinterprets bits** → numeric garbage, no type error | §7.10 |
| 7 | Manual stride arithmetic that ignores `interleaveLayout` reads **the wrong elements**; the strides array looks perfectly usable | §7.8 |
| 8 | Cache-checking with one `SpecializationOptions` and specializing with another **misses the cache forever**; both calls succeed | §3.3 |
| 9 | `Segment.box` **flips origin on macOS** while `DetectedObject.boundingBox` does not | §12.5 |
| 10 | A fresh `MTLBuffer` used as a KV cache is **not zeroed**; garbage state produces plausible wrong output | §11.1 |

### 15.4 The ten rules

1. **Never specialize inside an interactive flow.** Session 324, line 147, verbatim recommendation.
2. **Check the cache first**, with the *same* options you will specialize with.
3. **`AIModel` is free, `InferenceFunction` is expensive.** Construct both at feature-preparation
   time, not per call.
4. **Separate `nil` from `throws`** on `loadFunction`. They are different bugs.
5. **Drive everything from the descriptor.** Hardcoded shapes break when the model updates
   independently of the binary — which is the whole point of the `.aimodelc` + Background Assets
   delivery model.
6. **`guard let elements = view.contiguousElements else { … }`, always.** Never force-unwrap outside
   a value you got back from `run`.
7. **Copy the `Span.product` extension** into your project before you need it.
8. **Bound your fan-out.** `Sendable` is a correctness guarantee, not a memory guarantee.
9. **Build optimized.** `-Onone` changes the performance class, not just the constant factor.
10. **Wrap every Core AI error in your own type at the boundary**, with `underlying: any Error`.
    The beta SDK publishes no taxonomy beyond `AssetError` (§13), so an unnamed error must never
    reach your control flow.

---

## 16. Sources and evidence ledger

### 16.1 What was read for this guide

**SDK module interfaces** (captured 2026-07-29, Xcode 27A5228h; recaptured 2026-08-20, beta 5 27A5237l, macOS 27.0 SDK —
now the strongest evidence class in this guide, stronger than doc pages): the shipped
`.swiftinterface` files for `CoreAI` (a one-line umbrella re-exporting `CoreAIDelegates`),
`CoreAIDelegates` (which re-exports `CoreAIAsset`, `CoreAICommon`, `CoreAICompiler`,
`CoreAIRuntime` and adds the `AIModel` loading/caching surface), `CoreAIRuntime` (1,428 lines —
`AIModel`, `InferenceFunction`, `InferenceValue`, `NDArray` and all views, `NDArrayDescriptor`,
`ImageDescriptor`, `ComputeStream`), `CoreAIAsset` (`AIModelAsset`, `AssetError`), plus
`CoreAICache`/`CoreAICommon`/`CoreAICompiler`, whose public Swift surfaces are **empty** in this
beta. All under `notes/sdk-interfaces/*-27.0-macos.swiftinterface`. Citations in this guide of the
form `Module-27.0-macos.swiftinterface:lines` refer to these captures.

**Apple documentation** (harvested 2026-07-27 via `sosumi.ai` plus Apple's raw DocC JSON API at
`developer.apple.com/tutorials/data/documentation/<path>.json`, which preserves `termList` and
`table` blocks that the Markdown mirror drops):

- `/documentation/coreai` — framework page and the full 312-entry symbol index
- `/documentation/coreai/aimodel`, `/aimodelasset`, `/aimodelcache`, `/inferencefunction`,
  `/inferencefunctiondescriptor`, `/inferencevalue`, `/imagedescriptor`, `/computestream`,
  `/ndarray`, `/ndarraydescriptor`, `/computeunitkind`, `/specializationoptions`, `/asseterror`
  — plus roughly 70 individual member pages beneath them
- Articles: *"Integrating on-device AI models in your app with Core AI"*, *"Managing model
  specialization and caching"*, *"Compiling Core AI models ahead of time"*, *"Inspecting, debugging
  and profiling Core AI models"*, *"Monitoring model performance with the debug gauge"*,
  *"Analyzing model runtime performance with Instruments"*, *"Inspecting Core AI models with Core AI
  Debugger"*, *"Validating inference correctness against a reference run"*
- `https://developer.apple.com/core-ai-debugger/` (system requirements)

**WWDC26 transcripts:**

- Session **324**, *"Meet Core AI"* (presenter Ben, Core AI team) — 189 lines
- Session **326**, *"Core AI app features"* (presenter Carina, Core AI team) — 216 lines
- Session **325** is referenced once (the SAM 3 split and the 76% figure) and belongs to Part 10.

**Apple-authored shipping source — `apple/coreai-models`** (requires macOS/iOS 27.0+, Xcode 27.0+;
products `CoreAILM`, `CoreAIDiffusion`, `CoreAISegmentation`, `CoreAISpeech`,
`CoreAIObjectDetection`):

- `swift/Sources/CoreAIShared/Runtime/{NDArray+Helpers,ModelStructure,ResourceManaging,FileSize}.swift`
- `swift/Sources/CoreAIShared/Image/{ImagePreprocessor,CGImageUtils}.swift`
- `swift/Sources/CoreAILanguageModels/InferenceEngines/{CoreAISequentialEngine,CoreAIPipelinedEngine,CoreAIStaticShapeEngine}.swift`
- `swift/Sources/CoreAIImageSegmenter/{ImageSegmenter,ImageSegmentationEngine,SegmentationPostprocessor}.swift`
- `swift/Sources/CoreAIObjectDetector/*`, `swift/Sources/CoreAISpeech/SpeechModel.swift`
- `skills/{working-with-coreai,model-authoring,model-compression-exploration}/`
- `Package.swift`, `models/{sam3,qwen3}/README.md`
- GitHub issues and merged PRs, read live: **#62** (64-byte buffer floor), **#74**
  (`resolvingDynamicDimensions` over `.shape` mutation), **#85** (pre-allocated outputs can
  *regress* perf), **#89** (`consume` on `MutableViews`), plus the `AIModelError error 3` thread

**Apple-authored — `apple/coreai-torch`** (v0.4.1, 2026-07-06): `README.md`, `converter.py`,
`docs/getting-started/quickstart.ipynb`, `docs/coreai-core/tutorials/construct-a-graph.ipynb`,
`docs/api/debugging.md`, `tests/test_stateful.py`.

**Community — labelled as such everywhere it is used:**

- `1amageek/swift-lm` (single author, `0.11.0-alpha.1`, HEAD `db7a802`, 2026-07-18) — one of the
  very few real third-party Core AI integrations, and the only source in this corpus for the
  general-N state-view recursion and the `CoreAIStateSession` validation ladder.

### 16.2 Apple documentation samples that do not compile

Reproduced here so nobody wastes an afternoon on them. All ✅ VERIFIED as broken by reading the
declared signatures on the adjacent pages.

| Page | Defect |
|---|---|
| `NDArrayDescriptor.minimumByteCount` | passes `RawView.init` arguments **out of declared order** (`shape:` before `scalarType:`) and omits `try await` on the `async throws` `run` |
| `InferenceFunction.AsyncValue` overview | omits the **required `to:` stream argument** on `encode`, and misspells a variable (`embeddingsOutputs` vs `embeddingOutputs`) |
| `MutableView.copyElements(from:)` | doc references **`layout.scalarCount`**, a symbol absent from the public API — an internal-doc leak |
| `AIModel.init(contentsOf:options:)`, `AIModel.specialize`, `AIModelCache.model(for:options:)` | `- Throws:` clauses render as **orphaned Notes with no type** — consistent, per §13, with the throws being untyped in the SDK |

Also: Apple's own prose contains the typos *"vaiews"* (`AsyncMutableValue` overview) and *"the the"*
(`ComputeStream` overview). Harmless, but useful confirmation that a quotation is verbatim rather
than paraphrased.

### 16.3 Open questions — updated 2026-07-29 against the SDK interface dump

The macOS 27.0 beta `.swiftinterface` capture (§16.1) closed four of the ten questions this guide
originally carried. The ledger, updated:

**Closed by the interface dump:**

1. ~~**The inference/specialization/cache error taxonomy** (§13).~~ **Closed:** the throws are
   untyped; `AssetError` is the only public error type; `AIModelError` is not public in the beta
   SDK. See §13.1.
2. ~~**`NDArray.ScalarType.type`** (§7.9).~~ **Closed:** not present in the beta interface — an
   internal member leaked into `RawView.view(as:)`'s documentation.
3. ~~**Typed views for sub-byte and 8-bit-float scalar types** (§7.9).~~ **Closed:** none exist in
   the beta SDK; the raw-bytes path is the only public route.
4. ~~**macOS symbol availability.**~~ **Closed:** every declaration in the captured macOS 27.0
   interfaces carries `@available(macOS 27.0, …)`. The symbol pages' missing-macOS
   `metadata.platforms` arrays are a docs-generation bug, as suspected. ⚠️ A related surprise ran
   the *other* way: the doc pages mark `NDArray.RawView.init(metalBuffer:…)`,
   `AsyncValue.init(unsafeBuffer:…)` and `ComputeStream.init(commandQueue:)` **unavailable on
   watchOS**, but the captured interface declares all three `watchOS 27.0`
   (`CoreAIRuntime-27.0-macos.swiftinterface:26`, `:40-45`, `:1034-1041`). Metal's own
   watchOS absence is the practical constraint; treat the docs' watchOS note as advisory.

**Still open:**

5. **Whether `CVMutablePixelBuffer` / `IOSurface` gives a real zero-copy camera path** (§12.2).
   `RawView.init(ioSurface:)` exists; Apple's own vision package never uses it.
6. **How a value is *marked* as an image at conversion time.** Neither transcript covers it and we
   could not find a `coreai-torch` page for it. Blocks writing the image half of §12 with the same
   confidence as the tensor half.
7. **`SpecializationOptions.expectFrequentReshapes` semantics** (§4.3). The interface confirms the
   spelling, and a 2026-08-20 physical-device probe measured `false` for `.default` and `.cpuOnly`,
   but Apple still does not document the semantic effect or guarantee those defaults.
8. ~~**Deletion-while-referenced: throws or defers?**~~ **Closed on iPhone 15 Pro / iOS build
   `24A5408d` (§3.4):** the call throws while referenced and succeeds after release, matching the
   reference pages. Re-run on later seeds for drift.
9. **`ComputeStream` guidance beyond "serialized as needed"** — how many concurrent streams are
   advisable, and how a stream interacts with `run`'s implicit one. Undocumented.
10. **`AIModelAsset.removeDerivedArtifacts()`** — spelling confirmed
    (`CoreAIAsset-27.0-macos.swiftinterface:19`, `mutating`, `throws`); still no abstract, no
    discussion, no known caller.

### 16.4 Corrections applied while writing

Two claims in circulation are corrected in the body rather than repeated:

- **"`NDArray` is a non-escapable type."** It is not. Apple's conformance list says `Escapable`, and
  it is `Sendable`. The **views** are the non-escapable part; session 324 says exactly that about
  `NDArray.MutableView` and nothing else. See §7.1.
- **"Splitting a model into functions is a latency optimisation."** True, and incomplete. Reading
  `ModelStructure.swift:70-81` shows that the optional `coreai-models` loader also uses the
  function-name set to select **its compute-unit preference**—a three-function segmenter gets its
  Neural Engine preference and a single-`main` structure gets its GPU preference. Direct `AIModel`
  callers choose their own options. See §4.3.[^sample-routing-policy]

Two known-fabricated claims that appear in third-party Core AI material and are **absent from this
guide on purpose**: the extensions `.coreaimodel` and `.aiasset` (the real ones are `.aimodel`,
`.aimodelc` and `.aimodelintermediates`), and a `coreai-torch convert` CLI (the CLI is
`xcrun coreai-build compile`; conversion is a Python API). Part 1 carries the full known-bad-claims
register.

### 16.5 Where to go next

| You want | Go to |
|---|---|
| Schedule specialization, manage the cache, ship `.aimodelc` | the specialization-and-caching guide in this part |
| KV caches, `states:` as a modelling technique, prefix reuse | this part's states guide; [Part 3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/README.md) |
| Put a Core AI model behind `LanguageModelSession` | [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md) |
| Convert a PyTorch model, `state_names`, dynamic shapes | [Part 8](../../part-08-coreai-pytorch-conversion/README.md) |
| Why `ScalarType` has 35 cases; palettization and quantization | [Part 9](../../part-09-coreai-compression-numerics/README.md) |
| The Debugger, the gauge, the Instruments template, ANE authoring | [Part 10](../../part-10-coreai-hardware-authoring-debugging/README.md) |
| Vision pipelines, orientation, box conventions end to end | [Part 16](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/README.md) |
| Background Assets delivery, first-run UX, OS-update invalidation | [Part 15](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/README.md) |

[^scalar-type-count]: Apple’s current `NDArray.ScalarType` reference enumerates the 35 cases in this
    section: [Apple Developer — `NDArray.ScalarType`](https://developer.apple.com/documentation/coreai/ndarray/scalartype-swift.enum).

[^sample-routing-policy]: The classifier and preferences are implemented in the optional
    `apple/coreai-models` package’s pinned
    [`ModelStructure.swift`](https://github.com/apple/coreai-models/blob/5ed9981303b38d5a44aa6b45509bc4f6945029f5/swift/Sources/CoreAIShared/Runtime/ModelStructure.swift#L12-L218).
    Core AI’s `.default` behavior is documented separately in
    [Managing model specialization and caching](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/docs/Managing%20model%20specialization%20and%20caching.md).
