# Core ML to Core AI: what moves, what stays, and how

**Part 17 · Migration from pre-iOS 27 · Reference 05**

**Version floor.** Core AI is **27.0 and only 27.0** — iOS 27.0 · iPadOS 27.0 · Mac Catalyst 27.0 ·
macOS 27.0 · tvOS 27.0 · visionOS 27.0 · watchOS 27.0, every symbol flagged **Beta**. There is no
26.x back-deployment, no `@available(iOS 26, *)` shim, and no Core AI release-notes page to diff
against: `/documentation/updates/coreai` returns **404**. You need **Xcode 27** plus the separately
downloaded **Metal Toolchain**, and the conversion half of this guide runs on a **macOS 27** host
with `coreai-torch ≥ 0.4.1`. Core ML, meanwhile, has no announced end-of-life and keeps working on
every OS you already support. That asymmetry is the whole subject of this guide.

> ⚠️ **This is a partial migration by design — and Apple says so in one sentence.**
>
> ✅ **VERIFIED** — Apple, *Run AI models in your app on Apple silicon* (the Core AI framework
> overview page), verbatim: *"If your app uses model types other than neural networks, such as
> **decision trees or tabular feature engineering**, see **Core ML**."*
>
> Core AI is the successor path for **neural networks**. Core ML remains the correct — and only —
> home for everything else it does. So the honest first question is not *"how do I migrate?"* It is
> **"should I migrate at all?"**, and for a large number of shipping apps the answer this year is no.

---

## What this covers

The move from `MLModel` to `AIModel`, told as a *decision* rather than a *procedure*.

- **§1 — Should you migrate at all.** Where the Core AI / Core ML boundary sits, what Apple actually
  committed to, and what "narrowed, not deprecated" means for a shipping app.
- **§2 — The translation table.** The single most useful artifact here: the concept-by-concept map
  from the Core ML mental model to the Core AI one. `MLModel` → `AIModel`, `MLMultiArray` →
  `NDArray`, compute-unit selection → `SpecializationOptions`, compilation → specialization plus
  caching, feature providers → a plain named dictionary, and the file extensions — including the
  fact that `.aimodel` and `.aimodelc` are **directories**, not files.
- **§3 — What does not announce itself.** Five silent failures specific to *this* migration, headed
  by the big one: adopt the optional `coreai-models` loader without reading its policy and a
  converted model can load, run, produce correct numbers, and quietly execute on a compute unit
  you did not intend.
- **§4 — What genuinely improves, and why.** States (KV caches as first-class in-place inputs),
  multi-function assets (including how recognized names select the optional `coreai-models`
  loader’s Neural Engine preference), the Core AI Debugger's sync points and PSNR comparison
  against a PyTorch reference run, ahead-of-time compilation, and a memory-safe Swift API built on
  non-escapable views.
- **§5 — What you give up, honestly.** A decade of samples, Stack Overflow answers and blog posts —
  and the hard fact that **Core AI ships with zero Apple sample-code projects**. Plus the gap that
  bites first: **no documented error types**, so you cannot write precise `catch` blocks yet.
- **§6 — The conversion path.** `coremltools` versus `coreai-torch`, and the structural fact that
  decides your project plan: the real input to `coreai-torch` is a **`torch.export.ExportedProgram`**,
  so a model you hold only as a `.mlmodel` may have to go back to source.
- **§7 — A decision table for "don't migrate yet."** Five concrete reasons to stay, written down so
  you can point at one in a planning meeting.
- **§8 — The incremental strategy.** Run both. Migrate one model. Measure. Keep the Core ML path as
  the fallback for older OSes — because you have to anyway.

## What this does *not* cover

- **The Core AI runtime API in depth.** `AIModel`, `InferenceFunction`, `NDArray`, views, ownership,
  `preferredStrides` — that is
  [Part 7 reference 01](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md).
  Specialization, the cache and AOT are
  [Part 7 reference 02](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md).
- **The conversion mechanics.** Op coverage, decomposition tables, dynamic shapes, the IO contract —
  [Part 8](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/README.md). This guide tells you *whether* to start and
  *what shape* the project has; Part 8 tells you how to do it.
- **Compression.** Quantization, palettization, the numeric formats —
  [Part 9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md).
- **Artifact and toolchain compatibility** — the `coreai-torch` 0.4.0 IR incident, the macOS 26 → 27
  export-lowering regression, cache invalidation on OS update. That is
  [17.6](06-toolchain-and-asset-compatibility.md), and if you are re-converting an existing pipeline
  you should read it *before* you trust a benchmark.
- **Core ML's own 2026 changes.** We hold no Core ML documentation harvest — see the gap declared in
  §2 before you rely on any cell in the left column.

## What you need

- **Xcode 27** and the **Metal Toolchain** component. Not optional: builds that include `.aimodel`
  files fail with a *missing Metal compiler* error without it (✅ verified — Apple, *Integrating
  on-device AI models in your app with Core AI*). Install via Xcode ▸ Settings ▸ Components ▸ Other
  Components ▸ Metal Toolchain, or `xcodebuild -downloadComponent MetalToolchain`.
- **A real device.** Specialization is per-hardware and per-OS; a Simulator number is not a number.
  There is also a live report that the Core AI Swift package does not build for the iOS Simulator at
  all — see §5.
- **The PyTorch source of your model**, or a realistic plan to reacquire it. §6 explains why this is
  the gating question for the entire project.
- **A working Core ML baseline you can still run.** You will need it to answer "is this actually
  better?", and §8 is built around keeping it.

---

## Evidence markers, and one standing caveat about the left column

This guide follows the series convention: ✅ **VERIFIED** (quoted from a header, SDK, shipping
source file, or Apple documentation page, with the citation attached), 🟡 **RECONSTRUCTED** (concept
attested, exact spelling inferred), 🔴 **GAP** (unverified, with what would resolve it and a safe
default).

One caveat applies to this guide specifically and is important enough to state before the first
table rather than after it:

> 🔴 **GAP — the Core ML side of every comparison in this guide is unverified against a 2026 SDK.**
>
> **What is unknown:** our research corpus contains a complete harvest of the **Core AI**
> documentation (312 indexed symbols, every declaration read) and **no Core ML harvest at all**. The
> only Apple statement about Core ML anywhere in the corpus is the single routing sentence quoted at
> the top of this guide. Every Core ML type name, method name and behaviour below therefore comes
> from general familiarity with a long-stable framework, not from a source anyone re-read this cycle.
>
> **What would resolve it:** a documentation pass over `/documentation/coreml` on the 27 doc set,
> plus a `.swiftinterface` dump of `CoreML` from the Xcode 27 SDK.
>
> **Safe default meanwhile:** treat the Core ML column as a **memory aid for the concept**, not as
> API you can paste. Every Core ML identifier in this guide is marked 🟡. Before you write the Core
> ML half of a bridging protocol, open the header in Xcode and confirm the spelling. The **Core AI**
> column is ✅ and is safe to rely on to the extent any Beta API is.

That asymmetry is uncomfortable, and pretending otherwise would be the exact failure mode this
series exists to avoid. It also has a silver lining: the direction of travel in this guide is
*toward* the verified column.

---

## Contents

1. [Should you migrate at all?](#1-should-you-migrate-at-all)
2. [The translation table](#2-the-translation-table)
3. [⚠️ What does not announce itself](#3-️-what-does-not-announce-itself)
4. [What genuinely improves, and why](#4-what-genuinely-improves-and-why)
5. [What you give up, honestly](#5-what-you-give-up-honestly)
6. [The conversion path: `coremltools` versus `coreai-torch`](#6-the-conversion-path-coremltools-versus-coreai-torch)
7. [A decision table for "don't migrate yet"](#7-a-decision-table-for-dont-migrate-yet)
8. [The incremental strategy](#8-the-incremental-strategy)
9. [Quick reference](#9-quick-reference)
10. [Sources and evidence ledger](#10-sources-and-evidence-ledger)

---

## 1. Should you migrate at all?

### 1.1 The boundary, in Apple's words

There is exactly one authoritative statement of where the line falls, and it is a single sentence on
the Core AI framework landing page:

> ✅ **VERIFIED** — Apple, *Run AI models in your app on Apple silicon*
> (`/documentation/coreai`), verbatim: *"If your app uses model types other than neural networks,
> such as decision trees or tabular feature engineering, see
> [Core ML](https://developer.apple.com/documentation/coreml)."*[^coreml-boundary]

Read it as a routing rule, because that is what it is. Apple put a pointer to Core ML on the front
door of its brand-new inference framework. Frameworks that intend to absorb their predecessor
entirely do not do that.

Notice also what the sentence does **not** say. It does not deprecate anything. It does not give a
timeline. It does not say Core ML models will stop loading. It says: *these workloads belong over
there.*

The practical partition:

| Stays in Core ML | Moves to Core AI |
|---|---|
| Decision trees, gradient-boosted trees, random forests | Transformers, LLMs, VLMs |
| Tabular feature engineering — pipelines, scalers, imputers, one-hot encoders | CNNs, ViTs, diffusion models |
| Linear and logistic regression, SVMs, k-NN | Encoders (CLIP, T5, RoBERTa-class), ASR and TTS backbones |
| Create ML–trained classifiers built on those primitives | Anything you would export from PyTorch today |
| Your existing shipped `.mlmodel` / `.mlpackage` that meets its budget | Anything new with attention in it |

> 🟡 **RECONSTRUCTED** — the left column enumerates the model families Apple's sentence gestures at
> ("decision trees or tabular feature engineering") and that Core ML has historically supported. The
> *category* boundary is ✅; the *enumeration* is inference from that boundary plus general
> knowledge, and is exactly the kind of claim the gap box above warns you about. The right column is
> ✅ in the sense that everything in it is a neural network, which is the criterion Apple gave.

The same partition appears in
[Part 1 reference 01 §4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/references/01-apple-ai-stack-2026-map.md),
alongside two independent community readings that arrived at it separately — a WWDC26 lab paraphrase
and a Hacker News reader working from the updated docs. Both are **community**, both agree, and
neither is Apple policy. Two parties reaching the same reading from different evidence is worth
something; it is not worth a migration plan on its own.

### 1.2 Three questions that settle it in five minutes

Work down these in order. The first one that answers "stop" answers the whole question.

**Question 1 — Is your model a neural network?**

If any part of your Core ML asset is a decision tree, a GLM, an SVM, a k-NN, a pipeline of feature
transformers, or a Create ML classifier built on those, **that part does not move**. Core AI's
input format is PyTorch. There is no path for a gradient-boosted tree through
`torch.export.export`, and Apple has not published one.

This is not a hedge; it is the plain consequence of the conversion pipeline described in §6. Core
AI's only documented on-ramp is `coreai-torch`, whose entry points are
`TorchConverter().add_exported_program(...)` and `.add_pytorch_module(...)` (✅ verified against the
repo source). Both take PyTorch. A model that is not a PyTorch model has nothing to feed them.

**Mixed assets are the interesting case.** If you ship a Core ML *pipeline* — say, a tabular
preprocessing front end feeding a small neural network — then the neural half is a candidate and the
tabular half is not. That is a partial migration inside a single asset, and it usually means the
migration is not worth it until the neural half is the bottleneck.

**Question 2 — Do you have a problem Core AI solves?**

Core AI's genuine advantages over Core ML for neural work are enumerated in §4. Each of them is a
solution to a specific problem:

| Core AI capability | The problem it solves |
|---|---|
| **States** — in-place read-write model inputs | Recomputing a KV cache every decode step |
| **Multi-function assets** | Re-running an expensive encoder when only the cheap head changed — *and* getting onto the ANE at all |
| **Core AI Debugger** with PSNR sync points | "Quantization changed my outputs and I cannot find where" |
| **Ahead-of-time compilation** | A multi-minute first-load stall |
| **Non-escapable views over `NDArray`** | Buffer-lifetime and aliasing bugs at the framework boundary |
| **Custom Metal kernels embedded in the asset** | An op the converter cannot lower |

If none of those rows describes something you are actually fighting, you do not have a reason yet.
"It is the new framework" is not a reason, and it is worth saying that out loud in a planning
document, because it is the most common reason teams give.

**Question 3 — Can you absorb the costs?**

Three costs, all real, none of them visible in a diff:

1. **A minimum OS floor of 27.0 for the Core AI path.** Every symbol. No back-deployment. If your
   app supports 26.x you are shipping *both* paths, not replacing one with the other (§8).
2. **A first-launch specialization stall.** A `.aimodel` is portable source; it is not executable
   until the device compiles it. Apple's own guidance is blunt: ✅ **VERIFIED** — WWDC26 session 324,
   verbatim: *"It is recommended you avoid having model specialization occur within user interactive
   flows."* On a 3 GB model on an iPhone that first load has been **community-measured at 194
   seconds** (see
   [Part 7 reference 02](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md)).
   Designing around it means a first-run experience, not a spinner.
3. **A support-material cliff.** §5. This is the cost people underestimate most, because it does not
   show up until an engineer is stuck at 4pm on a Friday.

### 1.3 "Narrowed, not deprecated" — what that actually buys you

No deprecation has been announced. Existing `.mlmodel` and `.mlpackage` assets continue to load. The
useful historical analogy from the community is UIKit and SwiftUI: both coexist for years, but every
new platform capability lands in the new framework and the old one quietly stops receiving
investment.

What that means concretely for planning:

- **You are not on a clock.** There is no announced date by which a Core ML model stops working.
- **You are on a slope.** New capability — states designed for KV caches, multi-function assets,
  source-level numeric debugging, embedded Metal kernels — is arriving in Core AI. Expect the gap to
  widen, not close.
- **Your risk is concentrated in the new thing, not the old one.** Core AI is Beta across every
  symbol, has open correctness bugs in its converter (see
  [Part 8](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/README.md)), and had an artifact-compatibility incident
  during the beta cycle severe enough to invalidate previously shipped assets
  ([17.6](06-toolchain-and-asset-compatibility.md)). A working Core ML model is, right now, the
  *low*-risk asset in your app.

That asymmetry is the reason §8 recommends keeping the Core ML path rather than deleting it — and
the reason §7 exists as a table you can point at.

---

## 2. The translation table

This is the artifact most readers came for. Read the master table first, then the per-row notes —
several rows are *not* one-to-one, and the ones that aren't are where migrations go wrong.

Column convention, restated because it matters: **Core AI cells are ✅ VERIFIED** against Apple's
Core AI documentation (312 symbols, every declaration read this cycle). **Core ML cells are 🟡** —
concept-correct, spelling from general knowledge, not re-verified against a 2026 SDK.

### 2.1 The master table

| Concept | Core ML 🟡 | Core AI ✅ | One-to-one? |
|---|---|---|---|
| The loaded, runnable model | `MLModel` | `AIModel` | **No** — see §2.2 |
| Inspect a model without loading it for inference | `MLModelAsset` | `AIModelAsset` | Close |
| The thing you actually call | a `prediction` method on the model | `InferenceFunction`, obtained via `model.loadFunction(named:)` | **No** — a second object |
| Tensor container | `MLMultiArray` / `MLShapedArray` | `NDArray` | **No** — see §2.3 |
| Reading and writing tensor elements | subscripting / `dataPointer` | `NDArray.View<T>` and `NDArray.MutableView<T>` (non-escapable) | **No** — see §2.3 |
| Supplying inputs | `MLFeatureProvider` / `MLDictionaryFeatureProvider` | a plain `[String: NDArray]` dictionary, or `InferenceFunction.Inputs` | **No** — see §2.4 |
| Reading outputs | a feature provider you query by name | `InferenceFunction.Outputs`, via **destructive** `remove(_:)` | **No** — see §2.4 |
| Image inputs | `CVPixelBuffer` | `CVReadOnlyPixelBuffer` / `CVMutablePixelBuffer` | Close, new types |
| Choosing hardware | `MLModelConfiguration.computeUnits` (`MLComputeUnits`) | `SpecializationOptions` + `ComputeUnitKind` | **No** — see §2.5 |
| Turning a portable asset into a runnable one | model compilation → `.mlmodelc` | **specialization** → a cache entry | **No** — see §2.6 |
| Doing that work at build time | (n/a in the same sense) | `xcrun coreai-build compile` → `.aimodelc` | New |
| Where the compiled artifact lives | a URL you manage | `AIModelCache`, keyed by `(asset, SpecializationOptions)` | **No** — see §2.6 |
| In-place mutable model memory across calls | `MLState` | **states** — `InferenceFunction.MutableViews` passed as `states:` | Close — see §4.1 |
| One asset, several entry points | multi-function models, selected by configuration | multiple named functions; `model.functionNames`, `loadFunction(named:)` | Close — see §4.2 |
| Portable, uncompiled artifact | `.mlmodel` / `.mlpackage` | **`.aimodel`** — a **directory** | See §2.7 |
| Device-compiled artifact | `.mlmodelc` | **`.aimodelc`** — also a **directory** | See §2.7 |
| Xcode-generated typed wrapper class | yes, generated from the model | **none** — you write your own | **No** — see §2.8 |
| Converter | `coremltools` | `coreai-torch` (`TorchConverter`) | **No** — see §6 |
| Compression / optimization toolkit | `coremltools.optimize` | `coreai-optimization` (`coreai_opt`) | Close — see §6.4 |
| Numeric debugging against the source model | (ad-hoc) | **Core AI Debugger**, `.aimodelintermediates`, PSNR sync points | New — see §4.3 |
| Profiling in Instruments | Core ML instrument | **Core AI** template — four categories, four instruments | Close |
| Xcode debug gauge | (Core ML had none of this shape) | **Core AI debug gauge**, three event types | New |

Now the rows that are not one-to-one.

### 2.2 `MLModel` → `AIModel` — but the runnable object is a third type

The instinct is that `AIModel` is a drop-in replacement for `MLModel`. It is not, and the difference
is structural rather than cosmetic: Core AI splits *"the model"* into **three** objects where Core ML
had roughly one.

```
AIModelAsset   ← the .aimodel on disk. Portable. Cannot run inference.
     │            "An unspecialized source model asset."
     ▼  (specialization — expensive, per-device, per-OS-version)
AIModel        ← a handle on a specialized asset. Lightweight. Still cannot run anything.
     │            "A specialized model for running inference on a device."
     ▼  loadFunction(named:)
InferenceFunction  ← owns the weights and the intermediate buffers. THIS is what you call.
```

> ✅ **VERIFIED** — the two abstracts are quoted from the Core AI symbol index. `AIModelAsset`'s
> overview adds the motivation: *"Use a model asset to inspect a model's structure and metadata
> without specializing it for a specific device. This lets you query model information without
> performing specialization, **which is an expensive operation**."*

> ✅ **VERIFIED** — `AIModel`'s overview NOTE, verbatim: *"The model instance is **lightweight and
> doesn't own weights or intermediate buffers**. Those resources belong to the functions you load
> from it."* And from Apple's integration article: *"**Loading a function prepares the resources
> needed to run that function and can also be expensive.**"*

That split has three consequences you will feel immediately:

1. **Memory lives on `InferenceFunction`, not `AIModel`.** If you are used to reasoning about "the
   model's memory", relocate that intuition one level down. Holding an `AIModel` costs almost
   nothing; holding an `InferenceFunction` costs the weights.
2. **You can inspect before you commit.** `AIModelAsset` lets you read function signatures,
   metadata, storage types and an operation histogram *without* paying specialization. There is no
   equivalent habit in most Core ML codebases, and §3.1 shows why it turns out to matter enormously.
3. **The initializer is `async`.** ✅ **VERIFIED** — Apple: *"`init(contentsOf:options:)` is
   asynchronous **because specialization needs to complete before a valid `AIModel` is returned**."*
   There is no partially-loaded `AIModel`.

The full signature set:

```swift prelude:guide-context
import CoreAI

// The three-step load.
let asset = try AIModelAsset(contentsOf: modelURL)                 // sync, cheap, inspect-only
let model = try await AIModel(contentsOf: modelURL)                // async — may specialize
guard let function = try model.loadFunction(named: "main") else {  // throws on failure, nil if absent
    throw MigrationError.missingFunction("main")
}
```

> ✅ **VERIFIED** — `AIModelAsset.init(contentsOf:) throws`;
> `AIModel.init(contentsOf modelURL: URL, options: SpecializationOptions = .default) async throws`;
> `AIModel.loadFunction(named functionName: String) throws -> InferenceFunction?`. Apple, integration
> article: *"The method throws on a load failure, and returns `nil` when no function with that name
> exists."* The default function name is **`"main"`**.

⚠️ Note the two failure modes on that last line — a **throw** and a **`nil`** — mean different
things. `nil` means the asset has no function by that name (a conversion-time naming mismatch;
check `model.functionNames`). A throw means the function exists and could not be loaded. Collapsing
them with `try?` will cost you an afternoon eventually.

### 2.3 `MLMultiArray` → `NDArray` — and the view discipline

`NDArray` is Core AI's tensor container. It is not `MLMultiArray` with a new name; the access model
is different, and the difference is the point.

```swift prelude:guide-context
// Create an NDArray that matches the expected type and shape.
var input = NDArray(shape: [3, 4], scalarType: .float32)

// Access a mutable view to write data into the array.
var mutableView = input.mutableView(as: Float.self)
guard let elements = mutableView.contiguousElements else {
    // Handle non-contiguous memory layout.
    throw MigrationError.nonContiguousLayout
}
writeInputData(into: elements)
```

> ✅ **VERIFIED** — reproduced from Apple's *Integrating on-device AI models in your app with Core
> AI*, including the `guard` on `contiguousElements`. Signatures:
> `NDArray.init(shape: [Int], scalarType: NDArray.ScalarType)` — *"This initializer creates an array
> with contiguous, row-major strides"*;
> `mutating func mutableView<T>(as type: T.Type = T.self) -> NDArray.MutableView<T> where T: BitwiseCopyable`.

The design rationale, which is the migration-relevant part:

> ✅ **VERIFIED** — Apple, same article, verbatim: *"For `NDArray` values, **write input data with
> `MutableView` and read results with `View`. Swift enforces this at compile time.** A mutable view
> allows writes, and a view allows only reads, so you always know how your data is accessed."*

And from the session:

> ✅ **VERIFIED** — WWDC26 session 324, verbatim narration: *"The **`NDArray.MutableView` type is a
> non-escapable type** which provides safe and efficient access to the backing storage of the
> NDArray."*

**What changes for you, practically:**

| If you were doing… 🟡 | Now do… ✅ |
|---|---|
| `multiArray[[i, j] as [NSNumber]]` | take a view, then `view[scalarAt: [i, j]]` or `withUnsafePointer` |
| `multiArray.dataPointer` and hand the raw pointer around | `view.withUnsafePointer { ptr, shape, strides in … }` — the pointer does **not** escape the closure |
| `MLMultiArray(dataPointer:shape:dataType:strides:deallocator:)` to wrap your own buffer | `NDArray.RawView(metalBuffer:…)` / `(ioSurface:…)` / `(bytes:…)`, all explicitly unsafe |
| Assume a plain dense row-major buffer | check `view.contiguousElements` — it returns `nil` when the layout is not row-major contiguous |

Three gotchas that catch Core ML migrants specifically:

> ⚠️ **`contiguousElements` can be `nil`, and after specialization that is not hypothetical.**
> `NDArrayDescriptor.preferredStrides` exists because *"during the specialization of an `AIModel`, a
> preferred memory layout for a given ndArray value may be set… In some cases, this can result in a
> **non-contiguous layout being preferred/required by the backing compute**."* (✅ verified, Apple).
> You may still hand Core AI a contiguous array — *"however **it may incur a copy** to the preferred
> layout."* So the choice is: match `preferredStrides` and index defensively, or stay contiguous and
> pay a hidden copy on every `run`. Neither option throws. Neither logs.

> ⚠️ **The `shape` you get inside `withUnsafePointer` is a `Span<Int>`, and `Span` does not conform
> to `Sequence`.** No `map`, no `reduce`, no `for … in` through the `Sequence` protocol. Apple's own
> `apple/coreai-models` package ships an extension to work around it (✅ verified —
> `CoreAIShared/Runtime/NDArray+Helpers.swift` defines `extension Span where Element == Int { var
> product: Int }` with the comment *"`Span` doesn't conform to `Sequence` (non-escapable by design),
> so `.reduce` isn't available."*). Expect to write index loops.

> ⚠️ **The scalar-type zoo is much larger than you are used to.** `NDArray.ScalarType` has **33**
> cases (✅ verified, `CaseIterable`), including `bfloat16`, `float8e4m3fn`, `float8e5m2`,
> `float4e2m1fn`, `float8e8m0fn`, complex types, `int128`/`uint128`, and sub-byte integers all the
> way down to `uint1` — with odd widths (`int3`, `int5`, `int6`, `int7`) present. That is a feature
> for compression (see [Part 9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md)) and a hazard for
> `view(as:)`, since Swift has no standard type for most of them.
>
> 🔴 **GAP — how you read a sub-byte or 8-bit-float `NDArray` from Swift is undocumented.**
> `view(as:)` requires a `BitwiseCopyable` Swift type and Apple's NOTE says *"`T` must match
> `self.scalarType.type`"* — but `NDArray.ScalarType.type` **does not appear in the 312-symbol
> index** at all. **What would resolve it:** an SDK `.swiftinterface` dump, or a device experiment
> reading a palettized weight tensor. **Safe default meanwhile:** treat sub-byte types as
> *storage-only* — they are what your weights are compressed to, not what your inputs and outputs
> are. Keep your function's public I/O in `.float32` / `.float16`, which is what every worked
> example in Apple's docs and repos uses.

### 2.4 `MLFeatureProvider` → a dictionary (and a *destructive* output bag)

The input side gets dramatically simpler. The output side gets a sharp edge.

**Inputs.** There is no protocol to conform to. The convenience overload takes a dictionary:

```swift prelude:guide-context
var outputs = try await function.run(inputs: ["input": input])
```

> ✅ **VERIFIED** — Apple's integration article. The full signature:
> ```swift
> func run(inputs: [String : NDArray],
>          states: consuming InferenceFunction.MutableViews = MutableViews(),
>          outputViews: consuming InferenceFunction.MutableViews = MutableViews())
>     async throws -> InferenceFunction.Outputs
> ```
> Apple's note on the overload: *"This is a convenience overload that accepts a dictionary of
> `NDArray` values instead of an `InferenceFunction.Inputs` collection."*

The names are the names you gave at conversion time. ✅ **VERIFIED** — Apple: *"Pass your data using
the same input names defined at model conversion time."* That makes your `input_names` /
`output_names` arguments in `coreai-torch` a **public API contract between your Python and your
Swift**, which is exactly how [Part 8 reference 01 §7](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md)
frames it.

There is also a builder form, `InferenceFunction.Inputs`, when you want to insert views rather than
whole arrays — that is the zero-copy path, and it is covered in
[Part 7 reference 01](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md).

**Outputs.** This is where the shape differs from anything in Core ML:

```swift prelude:guide-context
// Extract the returned output.
guard let predictionValue = outputs.remove("prediction") else {
    throw MigrationError.missingOutput("prediction")
}

guard let prediction = predictionValue.ndArray else {
    throw MigrationError.unexpectedOutputKind
}

processOutput(prediction.view())
```

> ✅ **VERIFIED** — Apple's integration article, reproduced. `InferenceFunction.Outputs` exposes
> `mutating func remove(_ outputName: String) -> InferenceValue?`, `count`, and `names`.

> ⚠️ **`Outputs` is a take-once bag, not a dictionary.** ✅ **VERIFIED** — `remove(_:)`'s discussion,
> verbatim: *"After you remove a value, **subsequent calls with the same name return `nil`**."* If
> you are used to querying a feature provider repeatedly — once for logging, once for the return
> value — that pattern silently yields `nil` the second time. Take each output exactly once and bind
> it to a local.

And a second consuming read hiding inside a property access:

> ⚠️ **`InferenceValue.ndArray` consumes the value.** ✅ **VERIFIED** — discussion, verbatim: *"This
> property is `nil` when the value contains an image instead of an array. **Accessing this property
> consumes the value and transfers ownership of the array to the caller.**"* It looks like an
> ordinary getter. It is not.

One genuine simplification worth calling out: outputs returned from `run` are **always row-major
contiguous**. ✅ **VERIFIED** — Apple, on both `run` overloads: *"Any `NDArray` values in the
returned outputs have a row-major contiguous layout."* So the `preferredStrides` hazard from §2.3 is
an *input*-side problem only.

### 2.5 Compute-unit selection → `SpecializationOptions`

The concept survives; the mechanics and the consequences change completely.

```swift illustrative
struct SpecializationOptions: Equatable, Hashable, Sendable, SendableMetatype {
    static let `default`: SpecializationOptions
    static let cpuOnly: SpecializationOptions
    init(preferredComputeUnitKind: ComputeUnitKind)

    var allowedComputeUnitKinds: Set<ComputeUnitKind> { get }
    var preferredComputeUnitKind: ComputeUnitKind? { get }
    var expectFrequentReshapes: Bool                   // the only settable property
}

enum ComputeUnitKind: Equatable, Hashable, Sendable {
    case cpu, gpu, neuralEngine
    static var availableKinds: Set<ComputeUnitKind> { get }
}
```

> ✅ **VERIFIED** — every member quoted from `/documentation/coreai/specializationoptions` and
> `/documentation/coreai/computeunitkind`.

Rough equivalences, with the caveat that the left column is 🟡 and the semantics are **not**
identical:

| Core ML 🟡 | Core AI ✅ | Not the same because… |
|---|---|---|
| `MLComputeUnits.all` | `SpecializationOptions.default` | `.default` is described as *"selects the combination of compute units that **minimizes inference latency**"* — a stated optimization goal, not just an allow-list |
| `MLComputeUnits.cpuOnly` | `SpecializationOptions.cpuOnly` | Closest match. Apple: *"**Because all operations support the CPU, no fallback to other compute units occurs.**"* |
| `MLComputeUnits.cpuAndGPU` | `SpecializationOptions(preferredComputeUnitKind: .gpu)` | A **preference**, not a restriction — see the fallback note below |
| `MLComputeUnits.cpuAndNeuralEngine` | `SpecializationOptions(preferredComputeUnitKind: .neuralEngine)` | Same caveat |
| (no equivalent) | `expectFrequentReshapes` | New, undocumented — see below |

The single most important sentence in this area, because it explains a class of "why is my model on
the GPU when I asked for the ANE" question:

> ✅ **VERIFIED** — `preferredComputeUnitKind`'s discussion, verbatim: *"When set, the specialization
> process maximizes use of this compute unit kind. **Fallback to other kinds in
> `allowedComputeUnitKinds` may still occur for operations or operation patterns that are
> incompatible with the preferred kind. Operation patterns refer to groups of operations that are
> fused or transformed together during specialization; an operation that is individually compatible
> with the preferred unit kind may be part of a fused pattern that is not.**"*

Read that twice. Fallback happens at the granularity of *fused patterns*, not individual ops. An op
you verified is ANE-friendly can be dragged onto another unit by its neighbours. Nothing tells you
this happened except the Instruments trace (§4.3).

Apple's own advice is conservative and worth repeating verbatim, because migrants arriving with a
Core ML habit of pinning compute units tend to pin them here too:

> ✅ **VERIFIED** — *Managing model specialization and caching*: *"**In most scenarios, the default
> configuration offers the best performance, so test your app's performance carefully before
> overriding it.** Because not all devices have the same compute units available, check what's
> available with `availableKinds`."* The one case Apple names for `.cpuOnly` is: *"if your app runs a
> small model in the background, use `.cpuOnly` to avoid competing with foreground GPU work."*

And the new flag with no documentation at all:

> 🔴 **GAP — `expectFrequentReshapes` is undocumented.** Its abstract is a single sentence
> (*"Setting to allow more optimal specialization if the model performs frequent reshapes based on
> usage"*) and there is **no Discussion section, no stated default, and no initializer that sets
> it** — it must be set by mutating a copy. **What would resolve it:** an Apple engineer's answer, or
> a controlled A/B on a dynamic-shape model measuring specialization time, first-inference time and
> steady-state throughput. **Safe default meanwhile:** leave it alone unless you are shipping a
> dynamic-shape decode loop. Apple's own `apple/coreai-models` sets it exactly once, on the
> `.dynamic` (GPU) path — see §3.1 — which is the only usage evidence in this corpus.

### 2.6 Model compilation → specialization and caching

This is the row where the two frameworks diverge most, and it is the one that changes your app's
*launch experience*, not just your code.

> ✅ **VERIFIED** — Apple, *Managing model specialization and caching*, verbatim: *"When you load a
> `.aimodel` file with `AIModel`, Core AI performs **specialization**, the process of optimizing the
> model for the current device's hardware. The `.aimodel` file contains your model in a **portable
> format that works across Apple devices**. Before the model can run, Core AI specializes it for the
> current device, producing **executable code tied to that device's hardware and OS version**."*

Three things follow from "hardware **and OS version**":

1. **Every OS update throws it away.** ✅ **VERIFIED** — `AIModelCache.Policy`'s NOTE: *"**Regardless
   of policy, the system always purges assets when the OS updates**, as specialized assets are
   OS-version specific."* There is no policy, no entitlement and no API that prevents this.
2. **The artifact is not something you can ship.** You ship the portable `.aimodel` (or an
   architecture-specific `.aimodelc`); the device produces the executable form.
3. **You do not own the output file.** It lives in an `AIModelCache`, keyed by
   `(source asset, SpecializationOptions)`. You cannot enumerate it, size it, or place it.

The three levers Core AI gives you, in ascending order of effort:

| Lever | API | What it changes |
|---|---|---|
| Ask whether it is already done | `AIModelCache.default.model(for:options:)` | Nothing — it is a **probe**. Returns `nil` if not cached, and *"**never performs specialization**"* |
| Choose *when* it happens | `AIModel.specialize(contentsOf:options:cache:cachePolicy:)` | Moves the cost, does not reduce it |
| Reduce *how much* happens on device | `xcrun coreai-build compile` → `.aimodelc` | Moves most of phase-1 compilation to your Mac |

> ✅ **VERIFIED** — all three, from the Core AI reference pages. The distinction between the second
> and third is stated explicitly by Apple and is the one people conflate: *"The `specialize` method
> **differs from ahead-of-time compilation**. With ahead-of-time compilation, most of the heavy
> computation happens on your Mac at build time… With `specialize`, **the full specialization
> process runs on the person's device. You are controlling *when* specialization happens, not
> *reducing the work it does*.**"*

The probe is the migration-relevant primitive, because it is what lets you keep a Core ML–era
"models are cheap to load" assumption from becoming a three-minute stall:

```swift illustrative
import CoreAI

@available(iOS 27.0, macOS 27.0, visionOS 27.0, tvOS 27.0, watchOS 27.0, *)
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

> ✅ **VERIFIED** — reproduced verbatim from Apple's *Managing model specialization and caching*.
> Note the shape: `model(for:options:)` is `throws` but **not** `async`, because it never compiles
> anything; `AIModel(contentsOf:options:)` is `async throws` because it might. In this framework,
> `async` is a reliable signal of where the cost is.

The full treatment — cache policies, purge conditions, bookmarks, app groups, the AOT hardware gate
that excludes every pre-A17-Pro iPhone — is
[Part 7 reference 02](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md).
For a migration you need exactly two takeaways: **first load is expensive and must be designed
for**, and **you cannot cache your way out of an OS update**.

### 2.7 `.mlmodel` / `.mlmodelc` → `.aimodel` / `.aimodelc` — and both are directories

The extensions map cleanly. The file *system* semantics do not.

> ✅ **VERIFIED** — **`.aimodel` is a directory, not a file.** Three independent confirmations in
> Apple's own shipped code: `apple/coreai-models`' Python `pipeline.py` calls
> **`shutil.rmtree(aimodel_path)`** when overwriting; its Swift `PreparedModel.resolveCoreAIModelURL`
> and `recursiveFileSizeInBytes()` both assume a directory; and a load path guards on
> `isDirectory.boolValue`. Apple's own documentation calls it a *"bundle"* —
> `AIModelAsset(contentsOf:)` takes *"the URL of an `.aimodel` **bundle** on disk"*.
> `coreai-build` emits `.aimodelc` the same way.

Practical consequences, all of which have bitten someone:

- **Copy it with `FileManager.copyItem(at:to:)`, not a byte-stream copy.** A `Data(contentsOf:)`
  round-trip does not work on a directory.
- **Zip it for transport.** If you host models remotely (which Apple recommends for `.aimodelc` —
  see [Part 15 reference 01](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md)),
  you are moving a tree, not a blob. Background Assets is Apple's named mechanism.
- **Your "model size" metric is a recursive sum.** Apple's own package has a
  `recursiveFileSizeInBytes()` helper precisely because a single `attributesOfItem` call reports the
  directory node, not the weights.
- **Source control and CI caching behave differently.** A multi-gigabyte directory of weight files is
  not the same LFS/artifact problem as a single `.mlpackage`.
- **`.aimodel` and `.aimodelc` load through the same initializer.** ✅ **VERIFIED** —
  `AIModel.init(contentsOf:)`'s `modelURL` parameter is documented as *"The URL of a `.aimodel` **or
  `.aimodelc`** file"*, and the AOT article confirms: *"This is the same API you use to load
  `.aimodel` files, so **you don't need to change your loading code** when you adopt ahead-of-time
  compilation."* That is a genuinely nice property — AOT adoption is a build-and-distribution change,
  not a source change.

> ⚠️ **Never write `.coreaimodel` or `.aiasset`.** Both extensions are in circulation and both are
> fabricated. So is a `coreai-torch convert` CLI. The real spellings are `.aimodel`, `.aimodelc`,
> `.aimodelintermediates`, and the real conversion entry point is the `TorchConverter` **class**, not
> a command. See [Part 1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/README.md)'s known-bad-claims reference.

### 2.8 The row with no right-hand side: Xcode's generated wrapper class

If your Core ML integration looks like this 🟡 —

```swift prelude:guide-context
// Core ML, 🟡 from general knowledge: Xcode generates a typed class from the model file.
let model = try MyClassifier(configuration: config)
let output = try model.prediction(image: pixelBuffer)
let label = output.classLabel
```

— then the most jarring part of this migration is that **there is no equivalent**. Core AI does not
generate a Swift wrapper from your `.aimodel`. Apple's documented workflow is: add the model to the
target, open the model viewer to read the function signature, and then **hand-write** the code that
builds `NDArray`s with the right shapes and scalar types and pulls the outputs back out by name.

> ✅ **VERIFIED** — Apple's integration article documents adding the `.aimodel` to *Compile Sources*
> and describes the Xcode **model viewer** with its **General** and **Functions** tabs (*"The
> Functions tab shows the exact function signature of each function in the model, including the
> names, types, and optional descriptions for each input and output"*). Nothing anywhere in the
> 312-symbol index, the three articles or the two Core AI sessions mentions generated code.

What you get instead is **runtime introspection**, which is a real if unequal consolation:

```swift prelude:guide-context
let functionDescriptor = function.descriptor
guard let valueDescriptor = functionDescriptor.inputDescriptor(of: "input"),
      case .ndArray(let arrayDescriptor) = valueDescriptor else {
    throw MigrationError.unexpectedInput
}

guard arrayDescriptor.shape == [3, 4] else { throw MigrationError.unexpectedShape }
guard arrayDescriptor.scalarType == .float32 else { throw MigrationError.unexpectedScalarType }
```

> ✅ **VERIFIED** — reproduced from Apple's integration article. Apple's stated use case is the
> interesting one: *"You can use this descriptor to verify that a function accepts the inputs your
> app provides, or to **dynamically adapt your app's behavior as the model's inputs and outputs
> change between deployments, without needing to change your code**."*

So the trade is: **compile-time typing, gone; runtime adaptability, gained.** For an app that ships
one fixed model, that is a loss. For an app that downloads and updates models independently of app
releases — which is the whole shape of
[Part 15](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) —
it is arguably the better design. Either way, **budget for writing an adapter layer per model**, and
write the shape and scalar-type assertions above into it. They are the only thing standing between a
model update and a garbage-in-garbage-out inference that never throws.

### 2.9 Image inputs, and the pre-processing you used to get for free

This row of the table looks trivial — `CVPixelBuffer` becomes `CVReadOnlyPixelBuffer` /
`CVMutablePixelBuffer` — and is in practice one of the larger hidden costs of a vision-model
migration.

The framework side is straightforward and verified:

> ✅ **VERIFIED** — Apple, integration article: *"The `NDArray` type represents the input and output
> tensors from the converted model function at runtime. **Values marked as images at conversion time
> use `CVMutablePixelBuffer`.**"* `InferenceValue` carries either an `NDArray` or a pixel buffer
> (`InferenceValue.Kind` is exactly `{image, ndArray}`), and `ImageDescriptor` describes the expected
> `pixelFormatType` (an `OSType` four-character code), `width` and `height`. `CVReadOnlyPixelBuffer`
> and `CVMutablePixelBuffer` are the newer Swift-native pixel-buffer types, not `CVPixelBuffer`.

What is *not* there is everything that sat above the model in a typical Core ML vision pipeline. The
strongest evidence is negative and comes from Apple's own package:

> ⚠️ ✅ **VERIFIED** — grepping the entire non-LLM Swift tree of `apple/coreai-models`,
> **`CVPixelBuffer` appears zero times** and there is **zero EXIF or orientation handling anywhere**.
> Every vision product takes a `CGImage` (or a `URL`/`CIImage` it immediately converts to `CGImage`)
> and hand-builds a `Float32` `NDArray` using Core Graphics and Accelerate. The package ships its own
> `ImagePreprocessor` (286 lines) with per-model presets — `gemma3` at 896×896 with ImageNet
> mean/std, `clip` at 336×336 with CLIP mean/std — because nothing in the framework does resizing,
> normalization or layout conversion for you.

If your Core ML integration went through Vision 🟡 — a request handler that took an orientation, a
model input that Core ML resized and normalized according to the model's declared image
preprocessing — then **all of that becomes your code.** Specifically:

| What you used to declare or pass 🟡 | Who does it now ✅ |
|---|---|
| Image scaling to the model's input size | You. Pick and implement a strategy (resize / center-crop / pad) |
| Mean/std normalization and rescale factor | You. It is a per-model constant you must carry alongside the asset |
| Channel layout (`RGB` planar vs interleaved, CHW vs HWC) | You — though `NDArray.InterleaveLayout` exists if the model wants interleaved channels |
| EXIF orientation | You. See §3.5 |
| Coordinate conventions for boxes and masks | You. See §3.5 |

> 🔴 **GAP — is there a zero-copy `CVPixelBuffer` path, and does anyone use it?**
> **What is unknown:** the framework clearly supports image-typed values, but Apple's own vision
> packages do not use them — they build `NDArray`s from `CGImage` by hand. Whether that is a
> performance choice, a portability choice, or a gap in the image path is unverified.
> **What would resolve it:** a converted vision model with image-typed inputs, run both ways on a
> device with the Instruments template. **Safe default meanwhile:** follow Apple's package —
> `CGImage` in, hand-built `Float32` `NDArray` out — and treat the pixel-buffer path as an
> optimization to try after you have correctness, not before.

The practical planning consequence: **budget a pre-processing module per vision model, and treat it
as part of the model's contract.** The `ImagePreprocessor` in `apple/coreai-models` is the best
available template and is worth copying rather than reinventing; the patterns are extracted in
[Part 7 reference 04](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md).

---

## 3. ⚠️ What does not announce itself

Part 17 exists because almost nothing in the 26 → 27 transition throws. This section is the Core ML
→ Core AI subset of that, and it is worse than the rest, because a Core ML migration has an extra
failure axis the others don't: **you have a working baseline, so "it produced an answer" feels like
success.** It isn't. Your Core ML model also produced an answer, and it did so in 8 ms on the Neural
Engine.

### 3.1 ⚠️ SILENT FAILURE: the optional sample loader may request an unintended compute unit

This matters to migrants who adopt Apple’s optional `coreai-models` package without noticing that its
loader makes compute-unit preference partly a **model-structure** decision. It is not a Core AI
framework naming contract.

Here is the evidence, and it is unusually strong: it is Apple's own shipped Swift code.

> ✅ **VERIFIED** — `apple/coreai-models`, `swift/Sources/CoreAIShared/Runtime/ModelStructure.swift`.
> The package classifies an `.aimodel` by **which functions it contains**, and derives the
> specialization options from that classification:
>
> ```swift
> public enum ModelStructure: Equatable, Sendable, CustomStringConvertible {
>     case chunkedStatic(batchSize: Int)   // has extend_* AND load_embeddings
>     case dynamic                         // has main
>     case multiFunctionSegmenter          // has image_encode AND text_encode AND detect
> }
>
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

Read the `.dynamic` case again. **When loaded through this package, a model that exports as a single
`main` function with dynamic shapes is classified `.dynamic` and receives its GPU preference.** The
helper reserves its Neural Engine preference for the recognized static or segmenter structures.
Direct `AIModel` callers choose their own `SpecializationOptions`; `.default` lets Core AI choose the
CPU/GPU/Neural Engine combination that minimizes latency.[^sample-routing-policy]

WWDC26 session 325 presents the same three-function SAM 3 split as a **latency** technique — run
each entry point at its own cadence, get a 76% faster second inference. That framing is true and
incomplete for users of this package. Its code shows the split also selects the helper’s Neural
Engine preference, which changes the shape of a migration that adopts that loader:

> **The migration consequence.** If your Core ML model ran on the Neural Engine, a naive
> single-`main` `coreai-torch` conversion loaded through `coreai-models.PreparedModel` may request the
> GPU. The model will load. It will
> produce correct numbers. It will be slower, and it will use more power, and **nothing anywhere
> reports it.** There is no thrown error, no console warning, no API that returns "I fell back."
>
> The only way to see it is to look: run the **Core AI Instruments template** and check whether the
> Neural Engine track shows activity during your inference events (§4.3).

The defensive pattern is Apple's own two-phase load, and it is worth copying wholesale — note that
it reads the function names from an `AIModelAsset` *without* specializing, precisely so the compute
preference is decided before the expensive step:

```swift compile:27 imports:Foundation
import CoreAI

@available(iOS 27.0, macOS 27.0, visionOS 27.0, tvOS 27.0, watchOS 27.0, *)
enum ModelStructureProbe {

    /// Cheap: reads function names from the asset. Never specializes.
    static func functionNames(at url: URL) -> [String] {
        do {
            let asset = try AIModelAsset(contentsOf: url)
            guard let summary = try asset.summary(includingStatistics: false) else { return [] }
            return summary.functions.map(\.name)
        } catch {
            return []
        }
    }

    /// Decide compute preference from structure, then specialize exactly once, correctly.
    static func load(at url: URL) async throws -> AIModel {
        let names = Set(functionNames(at: url))
        let options: SpecializationOptions
        if names.isSuperset(of: ["image_encode", "text_encode", "detect"]) {
            options = SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
        } else if names.contains("main") {
            var opts = SpecializationOptions(preferredComputeUnitKind: .gpu)
            opts.expectFrequentReshapes = true
            options = opts
        } else {
            options = .default
        }
        return try await AIModel(contentsOf: url, options: options)
    }
}
```

> ✅ **VERIFIED** — the structure of this (probe with `AIModelAsset.summary(includingStatistics:
> false)`, choose options, then `AIModel(contentsOf:options:)`) is Apple's, from
> `ModelStructure.prepare(at:)`, whose source comment reads verbatim: *"Probe structure before
> specializing so we can pick the right compute-unit preference."* The function-name set
> `{image_encode, text_encode, detect}` and the option mappings are quoted above.
> 🟡 The `else` branch and the exact `Set` predicates here are this guide's adaptation — Apple's
> classifier also handles a `chunkedStatic` case keyed on `extend_*` plus `load_embeddings`, which is
> LLM-specific and covered in
> [Part 7 reference 04](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md).

And the caveat that keeps this honest:

> ⚠️ **Apple's own package does not cache the expensive entry point.** ✅ **VERIFIED** —
> `CoreAISegmentationEngine` **re-runs `image_encode` on every call** and exposes no cache. So the
> "76% faster second inference" figure from session 325 requires caller-side work that Apple's
> reference implementation does not do for you. Splitting the asset makes the saving *possible*; you
> still have to hold the encoder output yourself.

### 3.2 ⚠️ SILENT FAILURE: numeric drift with no exception

Core ML migrations almost always involve re-quantizing, because the compression toolkits are
different (§6.4) and because Core AI's format zoo invites it. Quantization changes your outputs. It
does not change your control flow.

> ✅ **VERIFIED** — Apple, *Validating inference correctness against a reference run*, verbatim:
> *"**Quantization and model specialization can introduce numerical drift** between a Core AI model
> and the original source model."*

Note that Apple names **two** sources: quantization *and specialization*. The second is the one
migrants don't expect — the same `.aimodel` specialized for two different compute units can produce
different numbers, which is why the Core AI Debugger's second comparison mode exists
(*"Validate across configurations… compare execution across different hardware targets, compute
units, or inputs"* — ✅ verified).

Two concrete, verified instances of silence in the toolchain itself:

> ⚠️ **Palettization silently skips layers it cannot handle.** ✅ **VERIFIED** — in
> `coreai-optimization`, if a tensor is incompatible with the configured granularity or
> `cluster_dim`, `_FakePalettizeImplBase.forward` logs *"Tensor incompatible with granularity: …
> Skipping palettization."* and **disables palettization for that layer** rather than failing. Your
> model is now partly uncompressed, is larger than you expected, and nothing raised.

> ⚠️ **Diffusion quantization failures are swallowed with a warning.** ✅ **VERIFIED** —
> `apple/coreai-models`, `export/compiler.py:69-72`: quantization failures are caught and reported as
> a warning, and the export continues. Same shape of problem, different repo.

The mitigation is not vigilance; it is a **numeric gate in the pipeline**. §4.3 describes the
Debugger's PSNR comparison, and
[Part 8 reference 01 §11](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md)
describes the Python-side parity check you should run *before* the model ever reaches Swift. If you
take one process change from this guide, take that one: **the migration is not done when the model
loads; it is done when a reference comparison passes a threshold you wrote down in advance.**

### 3.3 ⚠️ SILENT FAILURE: two options structs, two multi-gigabyte cache entries

A Core ML habit that translates badly: constructing a configuration at each call site.

The Core AI cache key is `(source asset, SpecializationOptions)`. ✅ **VERIFIED** — `AIModelCache`'s
overview: *"Each cache entry contains a specialized asset formed from a specific `.aimodel` or
`.aimodelc` **and `SpecializationOptions` combination**."* `SpecializationOptions` is `Hashable`
because it is *designed* to be a key. Which means:

```swift prelude:guide-context
// ⚠️ Two cache entries. Two specializations. Two copies on disk. No warning.
let a = try await AIModel(contentsOf: url)                      // options == .default
let b = try await AIModel(contentsOf: url, options: .cpuOnly)   // a different key entirely
```

There is no diagnostic, no log line, no thrown error. The symptoms are a second multi-minute stall
and storage growth your model files do not explain. Corroborated by Apple's own doc for
`deleteEntries(for:)`: *"A model may have multiple entries in the cache. For example, one with
`cpuOnly` and another with `default`. This method deletes all of them."*

The fix is structural: compute options **once**, in one function, and route every probe, load and
pre-specialize call through it. Full treatment, including a shipping community app's incident report
on exactly this, is in
[Part 15 reference 01 §9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md)
and [Part 7 reference 02 §4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md).

### 3.4 ⚠️ SILENT FAILURE: the converter's `optimize()` can miscompile, and `optimize()` is mandatory

This one belongs to the conversion stage but lands in your migration, so it goes here.

`TorchConverter().…​.to_coreai()` returns an `AIProgram` that has **not** been optimized. You must
call `.optimize()`; stateful models *require* it (mutation outputs become handle tokens). ✅
**VERIFIED** against the `coreai-torch` source and its documented usage.

> ⚠️ **And `optimize()` has an open correctness bug.** ✅ **VERIFIED** — `coreai-torch` issue **#49**,
> open at time of writing: *"`AIProgram.optimize()` removes broadcasting-significant axis moves and
> **silently miscompiles** N×N distance expressions."* A transpose that exists only to make
> broadcasting work can be treated as removable, and the resulting graph computes something else.
>
> 🔴 **GAP — still unresolved.** Re-checked via `gh` on **2026-07-29**: the issue remains **open
> with zero comments** — no maintainer response, last activity 2026-07-23. **What would resolve it:**
> check `github.com/apple/coreai-torch/issues/49`
> before you trust a converted model containing pairwise-distance or explicit-broadcast patterns.
> **Safe default meanwhile:** run the Python-side numeric parity check on the **optimized** program,
> not the unoptimized one — the bug is introduced by `optimize()`, so a parity test that runs before
> it will pass while the shipped asset is wrong.

That last sentence generalizes into the rule this whole section is arguing for: **validate the
artifact you are going to ship, at the stage you are going to ship it from.** Every silent failure
above survives a check performed one stage too early.

### 3.5 ⚠️ SILENT FAILURE: orientation and coordinate conventions, which used to be someone else's job

A vision-specific one, and it is the failure most likely to reach a user, because it produces output
that is *plausible* rather than obviously wrong: a mask in the right shape but flipped, a box on the
wrong half of the image, a portrait photo processed sideways.

**Orientation.** §2.9 established that nothing in the framework handles EXIF. Worse, the two obvious
ways to get a `CGImage` disagree with each other:

> ⚠️ ✅ **VERIFIED** — in `apple/coreai-models`' `ImagePreprocessor`, there is **no orientation
> handling at all**. `CIImage(contentsOf:)` **does** apply EXIF orientation;
> `CGImageSourceCreateImageAtIndex`, which the repo's own CLI tools use, **does not**. So *"the same
> JPEG can be preprocessed two different ways depending on which entry point you use"* — described in
> the source notes as *"a real, unfixed inconsistency in the repo."*

If your Core ML pipeline went through Vision, orientation was a parameter you passed and forgot 🟡.
Now it is a decision you must make explicitly, once, and enforce at every entry point. A photo
picked from the library, a frame from the camera, and a file dragged into a Mac app can each arrive
with a different convention.

**Coordinate origin.** Even within Apple's own package, two box conventions coexist and one of them
is platform-dependent:

> ⚠️ ✅ **VERIFIED** — `apple/coreai-models`, `SegmentationOutputs.swift`. `Segment.box` is
> constructed differently per platform, and the property's own documentation says so verbatim: *"On
> macOS (AppKit), the origin is **bottom-left**. On iOS/iPadOS (UIKit), it is **top-left**, matching
> the model's normalized XYXY output directly."* Meanwhile `DetectedObject.boundingBox` in the
> detection product is *always* top-left pixel coordinates on every platform, and the repo's own
> `SegmentationVisualization.renderPromptBoxes` demands top-left *"regardless of platform"*.
>
> The consequence, stated plainly in the source notes: **the same code, the same model and the same
> image produce a different `Segment.box.y` on a Mac than on an iPhone**, and on macOS you must *not*
> feed `Segment.box` straight into the repo's own renderer. Two conventions — normalized **XYXY** for
> the segmenter, **pixel top-left** for the detector — coexist in one package.

Nothing about either failure throws. Your model runs, your post-processing runs, and a mask lands in
the wrong place.

**The defence is a written-down convention plus a fixture test.** Pick one representation for your
app — normalized, top-left, origin at the image's top-left corner, whatever you like — convert at
exactly one boundary, and add a test that runs a known image with a known non-identity EXIF
orientation through the whole pipeline on both macOS and iOS and asserts the box lands where you
expect. That test is cheap, it fails loudly, and it is the only thing in this section that will
notice the problem before a user does.

---

## 4. What genuinely improves, and why

Five things. Each is a real capability with a stated mechanism, not a marketing bullet, and each maps
to a problem you can name.

### 4.1 States: KV caches as first-class, in-place model inputs

The clearest architectural idea in the whole framework, and the one that most obviously reflects
"we built this for autoregressive models."

> ✅ **VERIFIED** — WWDC26 session 324, verbatim: *"**States are inputs to the model which are both
> read, and updated in-place during inference.** By introducing the key and value caches as states on
> the model, we both avoid recomputing them on each inference, and also **remove the need to provide
> the full history of the game as an input** since the data needed from older steps are stored in the
> states. So after the first input, each subsequent step uses the cache for history and only takes
> the new features of the latest board state."*

The motivating problem, stated in the same session, is one every transformer deployment hits:

> ✅ **VERIFIED** — session 324, verbatim: *"the game is getting slower as it goes on… **transformer
> models have quadratic time complexity with respect to the sequence length**. And in our game the
> sequence length is increasing with every move the model makes… Each time the input sequence is
> increased, the transformer model **recomputes a set of internal key and value embeddings for every
> element in the sequence**."*

**How you author them.** Python side, this is a `torch.register_buffer` plus in-place mutation, named
at conversion time:

```python
import torch
import torch.nn as nn
from coreai_torch import TorchConverter, get_decomp_table

class Decoder(nn.Module):
    def __init__(self, max_context: int, n_heads: int, head_dim: int):
        super().__init__()
        # Fixed-size caches for the maximum possible context length.
        self.register_buffer("key_cache",   torch.zeros(max_context, n_heads, head_dim))
        self.register_buffer("value_cache", torch.zeros(max_context, n_heads, head_dim))
        # … projections, norms, etc.

    def forward(self, features, position):
        k_new, v_new = self.compute_kv(features)
        self.key_cache[position]   = k_new        # in-place write → becomes a state
        self.value_cache[position] = v_new
        k = self.key_cache[: position + 1]        # read history back out
        v = self.value_cache[: position + 1]
        # … attention, MLP, output projection
        return logits

model = Decoder(max_context=4096, n_heads=8, head_dim=64).eval()
ep = torch.export.export(model, args=(sample_features, sample_position))
ep = ep.run_decompositions(get_decomp_table())

program = (
    TorchConverter()
    .add_exported_program(
        ep,
        input_names=["features", "position"],
        output_names=["logits"],
        state_names=["key_cache", "value_cache"],   # ← names the states
    )
    .to_coreai()
)
program.optimize()          # mandatory — stateful models require it
program.save_asset("Decoder.aimodel")
```

> ✅ **VERIFIED** — the `register_buffer` → state mechanism and the `state_names=` argument are
> confirmed in `coreai-torch`'s own test suite (`tests/test_stateful.py`), which asserts the resulting
> Core AI IR carries `{MutableBuffers.buffer_mutation = "b_state", coreai.name = "b_state"}`.
> `add_exported_program`'s naming parameters are **keyword-only** in the real source (there is a `*`
> in the signature) even though the published API doc shows them positionally — write them as
> keywords. `to_coreai()` does **not** optimize; `.optimize()` is required, and stateful models
> require it specifically because mutation outputs become handle tokens.
> 🟡 The body of `Decoder` here is illustrative app code shaped after session 324's narration;
> only the `register_buffer` / `state_names` / `optimize()` mechanics are verified API.

**How you drive them.** Swift side, states are a third argument to `run`:

```swift prelude:guide-context
import CoreAI

@available(iOS 27.0, macOS 27.0, visionOS 27.0, tvOS 27.0, watchOS 27.0, *)
final class Decoder {
    private let function: InferenceFunction
    private var keyCache: NDArray
    private var valueCache: NDArray

    init(model: AIModel) throws {
        guard let function = try model.loadFunction(named: "main") else {
            throw MigrationError.missingFunction("main")
        }
        self.function = function
        // Fixed-size caches, matching what the asset expects.
        self.keyCache   = NDArray(shape: [4096, 8, 64], scalarType: .float16)
        self.valueCache = NDArray(shape: [4096, 8, 64], scalarType: .float16)
    }

    func step(features: NDArray, position: NDArray) async throws -> NDArray {
        // A collection of MutableViews, one per state. All states are required.
        var states = InferenceFunction.MutableViews()
        states.insert(keyCache.mutableView(as: Float16.self),   for: "key_cache")
        states.insert(valueCache.mutableView(as: Float16.self), for: "value_cache")

        var outputs = try await function.run(
            inputs: ["features": features, "position": position],
            states: consume states
        )

        guard let value = outputs.remove("logits"), let logits = value.ndArray else {
            throw MigrationError.missingOutput("logits")
        }
        return logits          // caches were updated in place; nothing to copy back
    }
}
```

> ✅ **VERIFIED** — the API shape: `run(inputs:states:outputViews:)` takes
> `states: consuming InferenceFunction.MutableViews`, and `MutableViews` exposes
> `mutating func insert<Element>(_ mutableView: consuming NDArray.MutableView<Element>, for name: String)`.
> Session 324's narration matches: *"I'll construct a **collection of MutableViews** containing both
> views of the key and value caches. Then provide those as the **`states` argument of the
> `InferenceFunction.run` method**. Now the caches will be both read and updated in-place during each
> inference."*
> 🟡 The `Float16` element type and the specific shapes in this snippet are illustrative; read your
> asset's real state descriptors with `functionDescriptor(for:)?.stateDescriptor(of:)`.

Three sharp edges that Core ML habits do not prepare you for:

> ⚠️ **Every state is mandatory.** ✅ **VERIFIED** — the `states:` parameter documentation, verbatim:
> *"The in-out arguments of the function, which the function reads and writes during inference. **You
> must provide views for all states; omitting any state produces an error.**"* Repeated on
> `InferenceFunctionDescriptor.stateNames`: *"**You must provide a mutable view for every state**."*
> Enumerate them at load time from `descriptor.stateNames` and assert your count matches — and note
> there is **no `stateCount`** property even though `inputCount` and `outputCount` exist, so it is
> `stateNames.count`.

> ⚠️ **A state view's lifetime is tied to the collection.** The `insert` overloads are `consuming` /
> `inout`, and the async variant's parameter doc says outright: *"Its **lifetime is tied to the
> resulting collection**."* You are handing Core AI borrowed access to your buffers for the duration
> of the call. That is exactly the aliasing discipline §4.5 is about, and it is enforced by the
> compiler rather than by a comment.

> ⚠️ **Prefix reuse is enormous — and unavailable on some architectures.** Community-measured
> (`john-rocky-models`, attribute as community, not Apple): trimming a KV cache and reusing the
> prefix took turn-2 time-to-first-token from **23.28 s to 0.230 s (101×)** at 4k context with
> byte-identical greedy output, and 15.2× at 357 tokens. The mechanism is that trimming is *a single
> integer assignment* — nothing is cleared, only a processed-token counter rewinds, which is safe
> because attention is causal. **But** the same source reports that the trim operation returns an
> unsupported sentinel whenever extra non-KV states are present: linear-attention and hybrid
> architectures keep a *running scan* rather than a positionally addressed cache, so they cannot be
> rewound and must re-prefill every turn. If you are choosing a model as part of this migration, that
> is a model-**selection** consequence, not a tuning tip. Full treatment in
> [Part 7 reference 03](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md).

**The migration takeaway.** If your Core ML model is a classifier or a single-shot encoder, states
buy you nothing and you should skip this section. If it is autoregressive — a decoder, a streaming
recognizer, anything with a loop around it — states are probably the single largest reason to move,
and they are worth more than everything else in this section combined.

### 4.2 Multi-function assets — and the finding that reframes them

One `.aimodel` can contain several named entry points. Session 324 mentions it in passing:

> ✅ **VERIFIED** — session 324, verbatim: *"In the common case, your `AIModel` will only have a
> single main `InferenceFunction`, though **you can convert a single model with multiple
> functions**."*

Session 325 makes it the centrepiece of a re-authoring story:

> ✅ **VERIFIED** — WWDC26 session 325, verbatim: *"Instead of converting the model as-is, I can
> **author a new PyTorch implementation that's hand-crafted for my goals**. The biggest change I make
> is to have **three separate functions in the Core AI Model instead of one. `coreai-torch` has APIs
> that lets you do this.** `image_encode` handles the image, `text_encode` processes the prompt, and
> `detect` wraps the final post-processing to generate the output."*
>
> And the payoff, verbatim: *"**I swapped the prompt to butterfly and only re-ran the text encoder
> and the detector.** As a result, the **second inference is 76% faster, even after warmup. This
> shows the benefit of re-authoring.**"*

The mechanism is one keyword argument, staged onto a single converter:

```python
converter = TorchConverter()
converter.add_exported_program(img_program, entrypoint_name="image_encode",
                               input_names=["pixel_values"], output_names=["backbone_features"])
converter.add_exported_program(txt_program, entrypoint_name="text_encode",
                               input_names=["input_ids"], output_names=["text_features"])
converter.add_exported_program(det_program, entrypoint_name="detect",
                               input_names=["backbone_features", "text_features"],
                               output_names=["masks", "scores"])
program = converter.to_coreai()
program.optimize()
program.save_asset("Segmenter.aimodel")
```

> ✅ **VERIFIED** — `entrypoint_name: str = "main"` is a real keyword-only parameter on both
> `add_exported_program` and `add_pytorch_module`, and *"Must be unique across all staged programs"*;
> a duplicate raises `ValueError` with the verbatim message *"A program with entrypoint_name={…!r} is
> already staged. Each staged program must have a unique entrypoint_name."* `to_coreai(entrypoints=…)`
> can convert a subset. The three names `image_encode` / `text_encode` / `detect` are the real graph
> names in `apple/coreai-models`' SAM 3 iOS export.
> 🟡 The `input_names` / `output_names` values in this snippet are illustrative for a segmenter; the
> real SAM 3 recipe is reproduced in
> [Part 8 reference 01 §10](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md).

Swift side, you simply load more than one function from the same `AIModel`:

```swift prelude:guide-context
let model = try await AIModel(contentsOf: url, options: options)
print(model.functionNames)   // ["image_encode", "text_encode", "detect"]

guard let imageEncode = try model.loadFunction(named: "image_encode"),
      let textEncode  = try model.loadFunction(named: "text_encode"),
      let detect      = try model.loadFunction(named: "detect")
else { throw MigrationError.missingFunction("segmenter entry points") }
```

> ✅ **VERIFIED** — `AIModel.functionNames: [String]` and `loadFunction(named:)`. Apple's integration
> article: *"Most models have a single function. If the model contains multiple functions, check
> `functionNames` to see all available names."*

**And now the finding that changes how this should be taught.** As §3.1 established, the optional
`coreai-models` package classifies the three-function segmenter as `.multiFunctionSegmenter` and
requests `preferredComputeUnitKind: .neuralEngine`, while it classifies a single-`main` dynamic-shape
asset `.dynamic` and requests the **GPU**. The split therefore selects that helper’s Neural Engine
policy in addition to avoiding repeated encoder work; it does not control direct Core AI loads.

If you are migrating a Core ML model that ran on the ANE, this is the most actionable paragraph in
the guide: **plan for re-authoring, not just re-converting.** A mechanical `torch.export` of an
existing architecture into one dynamic-shape `main` is the path of least resistance, but when used
with the sample loader it selects the GPU policy. The re-authoring rules — static shapes, conv-instead-of-linear
projections, the ANE's layout preferences — are
[Part 10 reference 01](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md).

Two honest caveats on the 76% figure:

> ⚠️ **Attribution.** The 76% is **Apple-published**, from session 325's demo. 🔴 **GAP:** the
> session does not state the device, the warmup protocol, or whether the comparison is wall-clock for
> the `text_encode` + `detect` pair against all three functions. **What would resolve it:** a
> reproduction on a named device with a stated protocol. **Safe default meanwhile:** treat it as an
> existence proof that the technique pays, not as a number you can quote for your own model.

> ⚠️ **You have to build the cache yourself.** Apple's `CoreAISegmentationEngine` re-runs
> `image_encode` on every call (✅ verified). Splitting the asset creates the *opportunity* to skip
> work; retaining the encoder output between calls is your code.

### 4.3 The Core AI Debugger: sync points and PSNR against a PyTorch reference

This is the capability with no Core ML analogue at all, and for anyone who has ever tried to work out
*why* a converted model's outputs drifted, it is worth the migration on its own.

Three tools ship, and they are distinct:

> ✅ **VERIFIED** — Apple, *Inspecting, debugging, and profiling Core AI models*, verbatim: *"Core AI
> provides **three tools**… **Core AI Debugger**: A standalone macOS app for inspecting model
> structure, running models, and validating inference against reference data. **Core AI debug
> gauge**: An Xcode feature that monitors model load, specialization, and inference activity in real
> time during a debug session. **Core AI instrument**: An Instruments template that profiles
> execution timing across the CPU, GPU, and Neural Engine."*

**The Debugger's three-step workflow** is visualize → execute → validate:

> ✅ **VERIFIED** — verbatim: *"The debugger follows a **three-step workflow: visualize, execute, and
> validate.** You visualize the model first to understand its structure, then execute the model to
> produce tensor outputs for each operation, and finally compare those outputs against a reference
> run to validate correctness."*

The validate step is the one that matters for a migration. You produce a reference run from PyTorch
and compare operation-by-operation:

```python
from pathlib import Path
import torch
from coreai_torch.debugging.torch_utils import save_intermediates, load_intermediates

exported_program = torch.export.export(model, args=example_input)

metadata_path = save_intermediates(
    program=exported_program,
    inputs=example_input,
    output_dir=Path("./debug_output"),
)
# → ./debug_output/main.aimodelintermediates

debug_trace = load_intermediates(Path("./debug_output/main.aimodelintermediates"))
# debug_trace.inputs / .outputs / .intermediates  (dict: node_name -> tensor)
```

> ✅ **VERIFIED** — from `coreai-torch`'s debugging documentation. Apple's article describes the file
> verbatim: *"An `.aimodelintermediates` file **records the intermediate tensor values produced at
> each operation of a PyTorch reference run**. To generate the file, use the `save_intermediates`
> API, **passing both the model you want to validate and the original source model**. The result is a
> per-operation mapping between the PyTorch run and the Core AI model that Core AI Debugger can use
> to compare inference results."* `save_intermediates(..., node_filter=…)` restricts which ops are
> captured.

Then, in the app: open the `.aimodel`, click **Comparison**, set Configuration A to a real target and
Configuration B to **Intermediates File → Load Reference Run**, point it at the
`.aimodelintermediates`, and click **Compare** (✅ verified — Apple documents the six steps).

What comes back is the good part:

> ✅ **VERIFIED** — verbatim: *"Core AI Debugger compares two inference runs using ***sync points*:
> operation pairs whose outputs are expected to match.** When a comparison session starts, the
> debugger **automatically identifies sync points and computes similarity metrics for each one** so
> you can pinpoint where inference diverges."*

Five metrics, with **PSNR** as the default:

> ✅ **VERIFIED** — Apple reports five metrics per sync point; *"**Color indicators are metric-aware,
> so green always signals a good result regardless of which metric you choose.** The **default metric
> is PSNR**."*
>
> | Metric | Apple's guidance (verbatim, abridged) |
> |---|---|
> | **PSNR** | *"A good general-purpose choice that works well for most models and tensor types."* |
> | **Mean Absolute Error** | *"understand overall deviation **without sensitivity to outliers**"* |
> | **Mean Squared Error** | *"**amplifies larger errors**… when large deviations are more consequential"* |
> | **Max Absolute Error** | *"**A high value can expose clipping or overflow even when MAE looks acceptable.**"* |
> | **Mean Relative Error** | *"**Useful when tensor magnitudes vary widely across operations.**"* |

Navigator indicators are green / yellow / red for close match / moderate divergence / large error,
and you can **sort by Similarity** to find the worst pairs or **sort by Operation** to see whether
failures cluster (✅ verified). The clustering behaviour is the diagnostic payoff:

> ✅ **VERIFIED** — verbatim: *"The module hierarchy at the top of the Source Viewer tells you which
> PyTorch module the operation belongs to. **If low-similarity sync points cluster in the same
> module, the divergence is localized there, giving you a precise target for changes to your
> model.**"*

Two prerequisites nobody mentions until you hit them:

> ⚠️ **Source mapping requires debug metadata baked in at export time.** ✅ **VERIFIED** — Apple:
> *"The source-level features, including source line and PyTorch module mappings, **require debug
> metadata embedded in the `.aimodel` at export time**. Without this operation-level metadata, you
> can still view model operations in the Navigator, Structure Viewer, and the Inspector, but **the
> Source Viewer is unavailable**."* During the preview, `coreai-torch`'s documentation says to set:
> ```bash
> export USE_LOCAL_COREAI=1
> export ENABLE_DEBUG_INFO=1
> ```
> ⚠️ And note the tension with [17.6](06-toolchain-and-asset-compatibility.md): baked-in debug
> locations were the *cause* of the `coreai-torch` 0.4.0 artifact-compatibility incident, and
> `coreai_torch.debugging.debug_info.strip_debug_info` exists to remove them. Debug metadata is a
> development-build feature. Strip it for release.

> ⚠️ **The Debugger is a separate download with its own OS floor.** ✅ **VERIFIED** — from
> `developer.apple.com/core-ai-debugger/`: **host machine macOS 27 or later**; **paired devices
> iOS 27+, iPadOS 27+, or macOS 27+**. Note the paired-device list omits visionOS, tvOS and watchOS
> even though the framework supports all seven platforms.

**The gauge and the instrument.** For runtime rather than numerics:

> ✅ **VERIFIED** — the Xcode **Core AI debug gauge** shows three event types — **Inference** (blue),
> **Load** (green), **Specialization** (orange), the last *"only appears for models that aren't
> specialized ahead of time."* The **Core AI Instruments template** shows four categories —
> **Specialization** (green), **Load** (cyan), **Setup** (magenta), **Inference** (blue) — plus
> **Neural Engine**, **GPU** and **Time Profiler** instruments alongside.
>
> ⚠️ The colours for Load and Specialization are **swapped between the two tools**, and Instruments
> has a `Setup` category the gauge does not. Do not carry colour intuition from one to the other.

Two verified operational notes:

> ⚠️ **The gauge only appears if your target links `CoreAI.framework` directly.** ✅ **VERIFIED** —
> Apple: *"**The gauge only appears in projects that link the Core AI framework. The gauge does not
> support the Core ML framework.**"* Transitive linkage through a package is not enough; check
> General ▸ Frameworks, Libraries, and Embedded Content.

> ⚠️ **Open the gauge's report page *before* triggering the event you want to inspect.** ✅
> **VERIFIED** — the More menu (*Open in Core AI Debugger* / *Export to file*) *"aren't available for
> events recorded before the report was open."* The export is how you capture the exact input tensors
> for a specific inference — single-tensor inputs save as `.npy`, multi-tensor as zipped `.npz` —
> and Apple calls the gauge *"**the only entry point to a live Core AI Debugger session, and the only
> way to capture the input tensors that produced a specific Inference event**."*

The Neural Engine track in the Instruments trace is, concretely, how you answer §3.1's question:
*did my model actually go where I think it went?* Full tooling treatment is
[Part 10 reference 02](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md).

### 4.4 Ahead-of-time compilation

Specialization is expensive, and Apple gives you a way to do most of it on your build machine.

> ✅ **VERIFIED** — Apple, *Compiling Core AI models ahead of time*, verbatim: *"Core AI can help
> reduce on-device specialization time with ahead-of-time compilation through the **`coreai-build`**
> command-line tool. The tool **moves the most expensive part of specialization, model compilation,
> to your build machine**, so on-device specialization has less work to do."*

Why "the most expensive part" is a precise claim rather than a hedge:

> ✅ **VERIFIED** — session 324, verbatim: *"During specialization, the model goes through **two main
> transformations**. First, it goes through a core set of compilation steps which segment, plan and
> optimize compute. Second, executable artifacts are generated for the compute units used… **Of these
> two steps, compilation is the one which incurs most of the latency.**"* Session 326 says the same
> thing independently.

The command and the output convention:

```shell
% xcrun coreai-build compile MyModel.aimodel \
    --platform iOS \
    --min-deployment-version 27.0 \
    --output compiled/
```

> ✅ **VERIFIED** — the invocation is Apple's, verbatim from the AOT article, as is the output rule:
> *"`coreai-build` outputs one compiled `.aimodelc` file per device architecture, using the input
> model's filename as the prefix. For example, compiling `MyModel.aimodel` produces files named
> **`MyModel.<arch>.aimodelc`**, where `<arch>` is the device architecture identifier returned by
> `deviceArchitectureName` at runtime. **Each compiled `.aimodelc` works on any OS version at or
> above the minimum deployment version you pass.**"* Apple also documents `--preferred-compute` and
> says a `--help` run reveals *"the target architecture, and other options"*.

> ✅ **Toolchain reality check — resolved 2026-07-31.** The 2026-07-29 finding stands as history:
> the Xcode 27.0 beta app bundle (`27A5228h`) ships **no `coreai-build` binary**, only
> **`aimodelc`** (`Contents/Developer/usr/bin/aimodelc`, command types `package` | `compile`),
> whose binary embeds *"Please use 'xcrun coreai-build' instead."* The resolution: that note points
> at a tool in a **different, optional component** — `coreai-build` ships in the **Metal Toolchain**
> (`xcodebuild -downloadComponent MetalToolchain`), where `xcrun --no-cache --find coreai-build`
> resolves it (version 3600.79.1) and its full `--help` runs
> (`notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`). So: the documented `coreai-build`
> spelling is real and usable today, `aimodelc` is the Xcode-internal stub, and a machine without
> the Metal Toolchain component reproduces the "absent" state. [Reference 06
> §7](06-toolchain-and-asset-compatibility.md) tracks this.

Runtime selection is two lines and no new load API:

```swift prelude:guide-context
let arch = AIModel.deviceArchitectureName
let assetName = "MyModel.\(arch).aimodelc"
// … download or locate that variant, then:
let model = try await AIModel(contentsOf: assetURL, options: .default)
```

> ✅ **VERIFIED** — reproduced from Apple's article, including the reassurance that *"**This is the
> same API you use to load `.aimodel` files, so you don't need to change your loading code when you
> adopt ahead-of-time compilation.**"*

Two limits that keep this from being a free win:

> ⚠️ **AOT has a hardware gate that excludes a large installed base.** ✅ **VERIFIED** — Apple's
> NOTE, verbatim: *"Ahead-of-time compilation only compiles for devices that support Apple
> Intelligence, including **iPhone or iPad with the A17 Pro chipset or later, a Mac with the M1
> chipset or later, or Apple Vision Pro with the M2 chipset or later**."* Everything older falls back
> to specializing from the portable `.aimodel`. If your Core ML model happily ran on an A14, note
> that its Core AI replacement will run there too — just without the AOT benefit.

> ⚠️ **AOT reduces specialization; it does not remove it.** ✅ **VERIFIED** — verbatim: *"**Even with
> ahead-of-time compilation, the compiled asset still requires some specialization on the device.**
> The amount of compilation that remains depends on the model and the compute units it uses."* The
> phase-2 artifact generation is inherently per-device. Community measurement puts a fully
> AOT-compiled 3 GB asset at **194 seconds** for its first load on an iPhone 17 Pro (community, not
> Apple — see
> [Part 7 reference 02 §16](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md)).

There is also a distribution consequence: one `.aimodelc` per architecture means shipping them all in
your bundle is wasteful. ✅ **VERIFIED** — Apple: *"It's recommended to **host the compiled assets
remotely and download the matching variant to the device at runtime**, because each device only uses
one of them. The **`BackgroundAssets`** framework can manage downloads, installs, and updates."* That
is the subject of
[Part 15 reference 01](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md).

### 4.5 A memory-safe Swift API you did not have before

Core AI is one of the heaviest adopters of modern Swift in Apple's SDK, and the adoption is
load-bearing rather than stylistic. The types you will meet:

- **`Span<Element>` / `MutableSpan<Element>` / `RawSpan` / `MutableRawSpan`** as the element-access
  currency, rather than raw pointers.
- **Non-escapable views**: `NDArray.View<Element>` and `NDArray.MutableView<Element>` cannot outlive
  the array that vends them, and the compiler enforces it.
- **Ownership annotations everywhere**: `consuming`, `borrowing`, `~Copyable` on parameters, so the
  aliasing contract is in the signature.
- **Typed throws** (`throws(E)`) on the `withUnsafePointer` family.
- **Value generics** (`<let rank: Int>`) with `InlineArray<rank, Int>` for rank-checked subscripts,
  and the fixed-count array parameter syntax `[indexRank of any NDArray.RangeExpression]`.

> ✅ **VERIFIED** — all of these appear in declarations quoted from the Core AI reference pages. For
> example: `func withUnsafePointer<R, E>(_ body: (UnsafePointer<Element>, Span<Int>, Span<Int>)
> throws(E) -> R) throws(E) -> R where E: Error`, and
> `subscript<let rank: Int>(scalarAt index: InlineArray<rank, Int>) -> Element { get }`.

Why a migrant should care, in one sentence: **the read/write distinction that used to be a comment is
now a type.**

> ✅ **VERIFIED** — Apple: *"For `NDArray` values, write input data with `MutableView` and read
> results with `View`. **Swift enforces this at compile time.** A mutable view allows writes, and a
> view allows only reads, so you always know how your data is accessed."*

The practical effect is that a whole family of Core ML–era bugs becomes uncompilable: handing a
tensor's data pointer to a background task that outlives the tensor; writing through a buffer the
framework is concurrently reading; reusing an output buffer that ownership has already moved out of.
`NDArray.MutableView` cannot escape. `InferenceValue.ndArray` consumes. `Outputs.remove` takes once.
Every one of those is the type system saying something that used to be documentation.

It is not free. Three costs, all real:

- **`Span` does not conform to `Sequence`.** You will write index loops where you used to write
  `map` (§2.3).
- **The unsafe escape hatches are explicitly unsafe and say so.** `NDArray.RawView.init(metalBuffer:…)`
  carries the verbatim warning *"**This initializer is unsafe, you are responsible for ensuring that
  no other code (or GPU pipeline) writes to the buffer while the resulting view is alive**"*, and the
  buffer *"must have `shared` storage mode"* (✅ verified).
- **`InferenceValue.NamedMutableViews.take(_:)` traps rather than returning `nil` on a double take.**
  ✅ **VERIFIED** — *"Each value can only be taken once. **Requesting the same value again produces a
  fatal error.**"* `nil` means "no value with that name"; a second take is a crash. That is a
  deliberate design choice about exclusivity, and it is the one place in the API where the safety
  story is enforced at runtime with a trap instead of at compile time.

---

## 5. What you give up, honestly

Every migration guide has a section like this and most of them are a paragraph of hedging. This one
is not, because the gap is unusually large and unusually easy to underestimate from a demo.

### 5.1 The hard fact: Core AI ships with zero Apple sample-code projects

> ⚠️ ✅ **VERIFIED** — **0 `sampleCode` entries across all 312 indexed Core AI symbols.** The count
> comes from enumerating Apple's own navigation index at
> `developer.apple.com/tutorials/data/index/coreai` — 1 module, 7 articles, 2 collections, 31 structs,
> 6 enums, 3 classes, 3 protocols, 100 properties, 56 methods, 53 cases, 42 inits, 8 subscripts — and
> filtering for `type == "sampleCode"`. The result is empty. An exhaustive sweep of the other 2026
> framework indexes in the same pass found samples for `foundationmodels`, `evaluations` and
> `speech`; `coreai` has none at all.
>
> And there is no release-notes page either: **`/documentation/updates/coreai` returns 404**, and the
> string "Core AI" does not appear anywhere on Apple's Updates hub (✅ verified — the hub itself
> returns 200 and contains zero matches for `core ai`, `coreai`, `mlx` or `evaluation`).

Set that against what you are leaving. Core ML has shipped since 2017. There are Apple sample
projects, a decade of WWDC sessions, thousands of Stack Overflow answers, a large body of blog posts
and conference talks, and — critically — an enormous corpus of *third-party* code that a coding
assistant has seen. Core AI has: **7 documentation articles, three shipped Apple repositories, and
two WWDC sessions.**

That is the whole first-party corpus. It is good — Apple's docs for this framework are unusually
detailed, and `apple/coreai-models` is real compiling Swift and Python you can read — but it is
small, and it is not organized as a project you can open and run.

**What this means in practice:**

- **Your coding assistant will hallucinate this API.** It has seen Core ML. It has not seen Core AI.
  Fabricated extensions (`.coreaimodel`, `.aiasset`), a nonexistent `coreai-torch convert` CLI, and
  invented OS versions ("iOS 20", "macOS 17") are all in circulation right now precisely because of
  this vacuum. Verify every identifier against the documentation or a header.
- **There is no "reference app shape."** Foundation Models migrants can open Apple's Origami or Book
  Tracker sample and copy the architecture. Core AI migrants cannot. The nearest substitutes are the
  Swift engines inside `apple/coreai-models` (`CoreAISegmentation`, `CoreAIObjectDetection`,
  `CoreAISpeech`, `CoreAIDiffusion`, `CoreAILanguageModels`) and the patterns extracted from them in
  [Part 7 reference 04](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md).
- **Budget engineering time for discovery, not just implementation.** The unknown-unknowns rate is
  high. Two examples already in this guide — that the `coreai-models` sample loader gives a
  single-`main` export its GPU preference, and that
  `.aimodel` is a directory — are both facts you can only learn by reading Apple's *code*, not
  Apple's *docs*.[^sample-routing-policy]

### 5.2 🔴 No documented error types, so you cannot write precise `catch` blocks

This is the gap that costs you first, because it shows up the moment you write your first `do`.

> 🔴 **GAP — the Core AI runtime throws untyped, and the SDK interface now confirms there is
> nothing to catch by type.** (Narrowed 2026-07-29.)
>
> The `.swiftinterface` dump this box used to ask for has been read: the Core AI module interfaces
> were captured 2026-07-29 from the Xcode 27.0 beta (`27A5228h`; recaptured 2026-08-20, beta 5 `27A5237l`) into `notes/sdk-interfaces/`.
> **`CoreAIRuntime` declares no public error type at all** — every `throws` in
> `CoreAIRuntime-27.0-macos.swiftinterface` is untyped (the only typed-throws in the file are
> generic `throws(E)` rethrow plumbing on the unsafe-view closures). The **only public error type
> anywhere in the Core AI module family** is `CoreAIAsset.AssetError`
> (`CoreAIAsset-27.0-macos.swiftinterface:229-247`): `struct AssetError : Error, LocalizedError`
> with `kind`, `debugMessage: String?`, and a `Kind` enum of exactly five cases —
> `unsupportedVersion(String)`, `invalidFeatureType(String)`, `corruptedMetadata`, `invalidName`,
> `duplicateName` — publicly initializable by app code, so clearly not the sealed system error for
> inference.
>
> **What is still unknown:** what concrete error *values* escape `AIModel.init(contentsOf:)`,
> `AIModel.specialize(…)`, `loadFunction(named:)`, `run(…)`, `encode(…)`, or `AIModelCache`'s
> `delete*` methods at runtime. Community bug reports show at least two distinct shapes — a
> `CoreAIDelegates.AIModelError error 3` (note: no `AIModelError` appears in the public interface;
> that is an internal type surfacing through `NSError` bridging), and an `NSPOSIXErrorDomain Code=2`.
>
> **What would resolve the rest:** a deliberate `do { … } catch let e as NSError {
> print(e.domain, e.code) }` over a set of induced failures on a real device — the interface pass
> is done and cannot say more.
>
> **Safe default:** unchanged, and now on firmer ground — catch `AssetError` explicitly where you
> are genuinely doing asset work, then catch the general `Error`. **A typed `catch` for any other
> Core AI error cannot even be written**, because no other public error type exists to name. Log
> `(error as NSError).domain` and `.code` so your crash reports are actually useful, and build your
> recovery ladder on *observable state* (does `cache.model(for:options:)` return `nil`?) rather
> than on error identity.

```swift prelude:guide-context
import CoreAI
import os

@available(iOS 27.0, macOS 27.0, visionOS 27.0, tvOS 27.0, watchOS 27.0, *)
func loadOrRecover(at url: URL, options: SpecializationOptions) async throws -> AIModel {
    do {
        return try await AIModel(contentsOf: url, options: options)
    } catch let error as AssetError {
        // The one documented error type. `unsupportedVersion` in particular means
        // "a newer library produced this asset" — a real migration signal.
        logger.error("asset error: \(String(describing: error.kind)) \(error.debugMessage ?? "")")
        throw error
    } catch {
        // Everything else. Record the shape so the next engineer learns something.
        let ns = error as NSError
        logger.error("core ai load failed: domain=\(ns.domain) code=\(ns.code)")
        throw error
    }
}
```

> 🟡 **RECONSTRUCTED** — the `AssetError` members (`kind`, `debugMessage`, and the five `Kind`
> cases) are ✅ verified from the reference page and now ✅ **SDK-verified**
> (`CoreAIAsset-27.0-macos.swiftinterface:229-247`, including
> `init(kind:debugMessage:)` and `errorDescription`). The *pattern* of this snippet — catch the one
> real type, then log domain and code for everything else — is this guide's recommendation, not
> Apple's.

Compare that with what you are used to on the Core ML side 🟡, where an established `NSError` domain
and a documented set of failure conditions have existed for years, and where community answers cover
the common ones. That knowledge does not transfer. Plan for a period where your error handling is
coarse and your logging is verbose.

### 5.3 The documentation itself is beta-quality in places

Not a complaint — a warning about what you will find when you go looking for ground truth.

Verified doc defects in the current Core AI doc set:

| Where | What is wrong |
|---|---|
| `AIModel.init(contentsOf:)`, `specialize(…)` | An orphaned Note reading *"If specializing or loading the model fails."* — a truncated `- Throws:` clause rendered as a behaviour statement |
| `AIModelCache.model(for:options:)` | Same malformation: *"If a cache entry was found but the specialized asset failed to load."* |
| Cache deletion, live-reference behaviour | The **reference pages say it throws**; the **article says deletion is deferred**. On iPhone 15 Pro / iOS build `24A5408d`, the runtime threw while referenced and succeeded after release, matching the reference pages |
| `InferenceFunction.AsyncValue` overview example | Omits the required `to:` stream argument and misspells a variable — it does not compile as written |
| `NDArrayDescriptor.minimumByteCount` example | Passes `RawView.init` arguments out of declared order and omits `try await` on `run` |
| `MutableView.copyElements(from:)` | References `layout.scalarCount`, a symbol not present in the public API — an internal-doc leak |
| Symbol platform lists | Every individual symbol page omits **macOS** from `metadata.platforms` while the framework page lists it. Near-certainly a generation bug, but it will confuse an availability audit |

> ✅ **VERIFIED** — all seven observed directly during the documentation harvest. The deletion
> contradiction is quoted in full and the resolving device result is recorded in
> [Part 7 reference 02 §7](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md).

The practical rule: **when a Core AI doc example does not compile, believe the declaration, not the
example.** The signatures in the reference pages have been reliable throughout this corpus; the prose
snippets have not.

### 5.4 Beta status, open bugs, and one tooling gap you will hit immediately

Every Core AI symbol is flagged **Beta**. That is not a formality here; the corpus contains a
substantial list of open, reproduced defects across the converter, the optimizer and the model
repository. A representative sample, all ✅ verified as filed issues, all with **🔴 unknown current
status** as of the corpus snapshot (2026-07-27):

- **Silent miscompiles** — `AIProgram.optimize()` dropping broadcasting-significant axis moves
  (`coreai-torch` #49); the GPU delegate executing `floor`/`trunc`/`ceil` as identity (#10); float→int→float
  cast round-trips folded away, dropping truncation semantics (#9).
- **Numeric instability on the ANE** — fp16 overflow in `softplus`, `mish`, `logsumexp`,
  `logcumsumexp` for want of stable decompositions (#21); an fp16 discrepancy in MobileNetV3's
  2D-matmul + hardswish path (#51).
- **Crashes at load or compile** — an `ANECompiler` `EXC_BAD_ACCESS` when `slice_update` indices are
  runtime values (#6); `coreai-build compile` segfaulting in `MPSGraph` on a static-shape LLM with
  linear INT4 weights (`coreai-models` #55).

None of these means "do not use Core AI." They mean **your migration needs a numeric gate and a
device test, not just a green build** — which is the same conclusion §3 reached from a different
direction.

And one gap that will stop you on day one if it still applies:

> 🔴 **GAP — the Core AI Swift package may not build for the iOS Simulator.**
> `apple/coreai-models` issue **#49** reports *"Swift package fails to compile for the iOS Simulator
> (no such module 'CoreAI')"*, with maintainer pushback rather than a fix in the thread. **What is
> unknown:** whether this is the package's configuration or the SDK's, and whether it is still true
> on current betas. **What would resolve it:** a clean `xcodebuild -destination 'generic/platform=iOS
> Simulator'` against the current Xcode 27 beta. **Safe default meanwhile:** plan for
> **device-only** development and CI for the Core AI half of your app. Combined with the fact that
> specialization numbers from a Simulator are meaningless anyway, this is less of a loss than it
> sounds — but it does mean your unit-test story changes, and it is worth discovering in planning
> rather than on the second afternoon.

### 5.5 Two smaller losses worth naming

**No generated typed wrapper.** Covered in §2.8. You write the adapter.

**No documented Objective-C or C interface.** ✅ **VERIFIED** — all 312 Core AI symbols are
Swift-only in the doc index; there are no Objective-C interface-language entries. 🔴 **GAP,
narrowed:** the captured Swift interfaces (2026-07-29) point the same way — every public Core AI
type in the dumps is a plain Swift struct/class with no `@objc` exposure, and the runtime leans on
Swift-only features (`~Copyable`, `Span`, lifetime dependencies) that cannot bridge. Whether a
separate C header surface exists in the framework is still unverified — a `.swiftinterface` shows
only the Swift side. **What would resolve the rest:** the framework's `Headers/` directory in the
Xcode 27 SDK. **Safe default meanwhile:** if you have an
Objective-C or C++ codebase calling Core ML directly, budget for a Swift interop layer, and note that
the ownership-annotated Swift API (§4.5) does not bridge naturally — `~Copyable` types and non-escapable
views have no Objective-C representation.

**And one that only matters if you are routing through Foundation Models.** If your plan is to bring
a Core AI model into `LanguageModelSession` via `CoreAILanguageModel`, note this
community-measured constraint: grammar-constrained decoding requires access to engine **logits**, and
GPU-pipelined Core AI bundles never expose them. The consequence is that **an app bringing its own
model loses `@Generable` exactly when it selects the fastest backend** (community-measured,
`john-rocky-models`; attribute as community). That is a first-class architectural constraint rather
than a footnote, and it lives in
[Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md) and Part 1's backend decision table.

---

## 6. The conversion path: `coremltools` versus `coreai-torch`

Everything above is about *whether* and *what*. This section is about the fact that decides your
project plan, and it is a single structural point that many teams discover a month in.

### 6.1 The point: `coreai-torch` consumes an `ExportedProgram`, not a model file

`coreai-torch` is a **PyTorch → Core AI IR** converter. Its entry points are:

```python
def add_exported_program(
    self,
    exported_program: ExportedProgram,
    *,
    input_names:  Sequence[str] | None = None,
    output_names: Sequence[str] | None = None,
    state_names:  Sequence[str] | None = None,
    entrypoint_name: str = "main",
) -> Self

def add_pytorch_module(
    self,
    model: torch.nn.Module,
    *,
    export_fn: Callable[[torch.nn.Module], ExportedProgram],
    externalize_modules: list[type | ExternalizeSpec] | None = None,
    input_names:  Sequence[str] | None = None,
    output_names: Sequence[str] | None = None,
    state_names:  Sequence[str] | None = None,
    entrypoint_name: str = "main",
) -> Self
```

> ✅ **VERIFIED** — both signatures read from the `coreai-torch` source. Note the `*`: **all naming
> parameters are keyword-only** in the real code even though the published API doc shows them
> positionally. `export_fn` is keyword-only **and required** on `add_pytorch_module`. And note the
> naming correction that circulates wrongly: **there is no `convert()` function** in this package and
> **no `coreai-torch convert` CLI**. The entry point is the `TorchConverter` class.

Both paths bottom out in the same object: a **`torch.export.ExportedProgram`**. One takes it
directly; the other takes an `nn.Module` plus a function that produces one. Either way, the input to
Core AI conversion is *a live PyTorch model in a Python process*.

The canonical five lines:

```python
import torch
from coreai_torch import TorchConverter, get_decomp_table

model = ...          # your nn.Module
model.eval()

# Export and decompose — this is your responsibility.
ep = torch.export.export(model, args=(torch.randn(1, 3, 224, 224),))
ep = ep.run_decompositions(get_decomp_table())

# Convert to Core AI IR.
converter = TorchConverter().add_exported_program(ep)
coreai_program = converter.to_coreai()
coreai_program.optimize()
coreai_program.save_asset("MyModel.aimodel")
```

> ✅ **VERIFIED** — the first six lines are verbatim from `coreai-torch`'s README; `save_asset` is
> from `coreai-core`'s `AIProgram`. Two mandatory steps hide in there:
> **`run_decompositions(get_decomp_table())` is required** — `add_exported_program` validates and
> raises an actionable error otherwise, and even `aten.linear` trips it — and **`get_decomp_table()`
> is not interchangeable with `torch.export.default_decompositions()`**, which decomposes
> `instance_norm` into an op Core AI does not support. **`optimize()` is also required**, and does
> not happen inside `to_coreai()`.

Now compare that with where a Core ML model comes from 🟡: `coremltools` has historically accepted a
traced or scripted PyTorch model, a TensorFlow graph, and — importantly — could round-trip its own
`.mlmodel` / `.mlpackage` specs. **Core AI has no equivalent import path.** There is no
`.mlmodel → .aimodel` converter documented anywhere in this corpus, and one piece of negative evidence
suggests the direction of travel is away from such things: `coreai-core` 1.0.0b2's changelog notes it
*"Removed the unused `ml_asset` module and the **legacy Torch importer**"* (✅ verified).

> 🔴 **GAP — is there any `.mlmodel` → `.aimodel` path at all?**
> **What is unknown:** whether Apple ships, plans, or would sanction a direct conversion from a Core
> ML asset into Core AI IR. Nothing in the Core AI documentation, the `coreai-torch` repository, the
> `coreai-optimization` repository, `apple/coreai-models`, or either WWDC session mentions one.
> **What would resolve it:** an Apple statement, or a `coreai-torch` release note introducing an
> importer. **Safe default meanwhile: assume there is none, and plan on going back to source.** Do
> not build a schedule that depends on a converter appearing.

### 6.2 The question that determines your project size

So the migration decomposes into one binary question asked per model:

**Do you still have the PyTorch source and the trained weights?**

| Your situation | What the migration actually is |
|---|---|
| You have the `nn.Module` and a checkpoint, and it exports cleanly | A **conversion** project. Days. Follow [Part 8](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/README.md). |
| You have the source, but it uses ops Core AI cannot lower | A **conversion plus authoring** project. Composite ops, custom lowerings, possibly a Metal kernel. Weeks. |
| You have the source, and the ANE mattered | A **re-authoring** project (§3.1, §4.2). Static shapes, multi-function split, layout choices. Weeks. |
| You have only the compiled Core ML asset | A **reconstruction** project. See below. |
| It was trained with Create ML on non-neural primitives | **Not a migration.** It stays on Core ML (§1). |

The fourth row is the painful one and deserves its own treatment.

### 6.3 If you only have the `.mlmodel`

There is no supported path. Here is the honest menu, worst option last:

1. **Find the source.** This sounds facetious and it is the correct first move. Check the training
   repository, the notebook, the vendor contract, the model card. In most organizations the source
   exists and is merely inconvenient to locate. Every hour spent here is cheaper than any option
   below.

2. **Retrain or fine-tune from a public checkpoint.** If your model was a fine-tune of something
   public — a ResNet, a ViT, a Whisper variant, a BERT-family encoder — reconstructing an equivalent
   PyTorch model and re-fine-tuning is frequently faster and *always* more maintainable than
   reverse-engineering a compiled asset. It also gives you the thing you will need again in two
   years.

3. **Reconstruct the architecture and port the weights.** Rebuild the module in PyTorch, extract the
   weight tensors from the Core ML asset, and load them in. This is genuinely possible for
   straightforward architectures 🟡 (Core ML's model spec is a documented protobuf and `coremltools`
   can read it), and genuinely miserable for anything with fused or reordered layers, because the
   compiled asset's operator graph is not your source graph. You are also on your own for numeric
   validation — which, note, is exactly what §4.3's PSNR comparison is for once you *do* have a
   PyTorch reference.
   > 🟡 **RECONSTRUCTED** — that `coremltools` can load and inspect a model spec is general knowledge
   > about a long-stable tool, not something re-verified in this corpus. Confirm the current API
   > before you plan around it.

4. **Keep it on Core ML.** Which is a legitimate outcome, is free, and is what §7 is about. A model
   you cannot rebuild is a model whose migration cost is unbounded; that is a very good reason to
   leave it where it is and spend the effort on the model you *can* rebuild.

### 6.4 What *does* carry over: the optimization stage

The one genuinely reusable piece of a Core ML pipeline is the compression work — and here there is a
real bridge rather than a hopeful analogy.

`coreai-optimization` (imported as `coreai_opt`) is the compression toolkit on the Core AI side:

> ✅ **VERIFIED** — from the `coreai-opt` v0.2.0 release notes: `coreai_opt.quantization.Quantizer`
> — *"Supports weight-only quantization and activation quantization, via calibration and training
> modes, for **Integer and FP8/FP4** dtypes"*; `coreai_opt.palettization.KMeansPalettizer` —
> *"Supports kmeans + sensitive kmeans based Palettization"*; `coreai_opt.pruning.MagnitudePruner`;
> `coreai_opt.casting.cast_fp32_to_fp16()`; plus `coreai_opt.inspection.*`. The `finalize` API
> *"updates the model to make it ready to conversion via coreai-torch to deploy using the Core AI
> framework."*

And the bridge:

> ✅ **VERIFIED** — `Quantizer.finalize(model=None, backend=ExportBackend.CoreAI, *, mmap_dir=None)`
> takes a **`backend`** argument with two values: `ExportBackend.CoreAI` (the default) and
> **`ExportBackend.CoreML`**. The Core ML target is actively maintained — merged PRs in the corpus add
> `validate_coreml_compatibility` / `validate_coreml_palettization_compatibility` and a
> `CoreMLExportError` raised for incompatible configs as well as dtypes, and separate PRs unskipped
> eager and graph Core ML export tests because *"they now pass"* and *"segfault no longer occurs."*

That is a meaningful finding for a partial migration: **you can standardize your compression pipeline
on `coreai_opt` and emit for either backend.** A team that is moving some models and keeping others
does not need two quantization stacks. It also means the compression work you do while evaluating
Core AI is not wasted if you decide to stay.

Three cautions on that path, all verified:

> ⚠️ **`finalize(backend=ExportBackend.CoreAI)` is destructive.** Verbatim: *"When
> `backend=ExportBackend.CoreAI`, finalize **frees the original dense weights in place**: on each
> parametrized weight, `parametrizations[...].original` is replaced with a zero-size placeholder so
> its storage can be released."* Keep a checkpoint. And Apple's own guidance: *"**Only call
> `finalize` when exporting to a target backend.** For torch-based evaluation, **use the model
> returned by `prepare()` directly**."*

> ⚠️ **`mmap_dir` is Core AI–only** — passing it with the Core ML backend raises `ValueError` — and
> the files it produces *"must remain in place for the lifetime of the returned model; removing them
> invalidates the mmap-backed weights."*

> ⚠️ **Silent skips again.** §3.2 already flagged this: a tensor incompatible with the configured
> granularity gets palettization **disabled for that layer** with a log line, not an exception.

Also worth knowing while planning: `coreai-torch` keeps `coremltools` as a **test** dependency only
(✅ verified from its `pyproject.toml` — it appears under `[project.optional-dependencies].test`),
and `coreai-optimization` **removed** its `coremltools` runtime dependency outright in a merged PR.
So the two ecosystems are separate at runtime and touching only in the test matrix. Do not expect
`coremltools` objects to flow into `coreai-torch` APIs.

### 6.5 A realistic first-conversion checklist

If you got here and decided to proceed, this is the shortest safe path for **one** model. Every item
maps to a section above or a Part 8 section.

1. **Pin your toolchain.** `coreai-torch ≥ 0.4.1`. Assets converted with **0.4.0 fail to load on
   OS 27 beta 2 and later** — this is verbatim from Apple's own release note, and it is the single
   biggest version gate in the stack. See [17.6](06-toolchain-and-asset-compatibility.md).
2. **Get `torch.export.export` to succeed**, before anything Core AI–specific. This is PyTorch's
   problem, not Apple's, and it is where most of the first day goes.
3. **`run_decompositions(get_decomp_table())`.** Not the default table.
4. **Name your inputs and outputs deliberately.** They are the contract your Swift code binds to
   (§2.4). Use keyword arguments; they are keyword-only.
5. **Decide on dynamic shapes now.** Passing `dynamic_shapes=` to `torch.export.export` keeps a
   traced length out of the asset; *not* passing it bakes your sample length in. If you adopt
   `coreai-models.PreparedModel`, see §3.1: its classifier gives a dynamic single-`main` structure
   the package's GPU preference. Direct `AIModel` callers choose their own options.
   [^sample-routing-policy]
6. **`to_coreai()`, then `optimize()`, then `save_asset()`.** In that order. `optimize()` is not
   optional and `to_coreai()` does not do it.
7. **Run the Python-side parity check on the optimized program** (§3.4). Record the threshold you
   accepted.
8. **Open the `.aimodel` in Xcode's model viewer** and read the Functions tab. Confirm the signature
   is what you think it is. The viewer shows a dynamic dimension as **`?`**; the API reports it as
   **`-1`** (✅ verified — a small inconsistency that confuses people once each).
9. **Load it on a real device**, probe `model.functionNames`, assert shapes and scalar types (§2.8),
   and run one inference.
10. **Profile with the Core AI Instruments template** and confirm which compute unit actually ran it
    (§3.1). Do not skip this step. It is the whole point.
11. **Compare against your Core ML baseline** on the same device with the same inputs — latency,
    memory, and output similarity. §8.3 says how to do that without fooling yourself.

---

## 7. A decision table for "don't migrate yet"

Most migration guides are written as if the migration is a given. This one is not, because for a
large fraction of shipping apps the correct 2026 decision is **stay**, and it is much easier to
defend that decision in a planning meeting if someone has written the reasons down.

Work down the table. **Any single row that applies is sufficient.** You do not need all five.

| # | If… | Then don't migrate, because… | Revisit when… |
|---|---|---|---|
| 1 | You ship **non-neural model types** — decision trees, tabular pipelines, GLMs, SVMs, Create ML classifiers built on those | Apple routes these to Core ML **by name**, and Core AI's only on-ramp is PyTorch. There is nothing to convert them into | Never, for those models. This is a permanent split |
| 2 | Your Core ML model **works and you have no performance problem** | Migration buys you capability you are not using, and costs you a Beta framework, an unfamiliar error surface, and a re-validation cycle | You hit a wall §4 describes: quadratic decode, a repeated encoder, ANE eviction, or unexplained numeric drift |
| 3 | You need **OS support below 27** | Core AI is 27.0 across every symbol with **no back-deployment**. You would ship two paths, not one | Your minimum deployment target reaches 27.0 — or you accept dual paths deliberately (§8) |
| 4 | You depend on **Core ML features with no Core AI equivalent** | Generated typed wrappers, non-neural composition inside a single asset, and any Objective-C/C++ call site have no documented counterpart | Apple documents one, or you have budgeted the adapter layer |
| 5 | You **cannot absorb the specialization / first-launch cost** | A `.aimodel` is not executable until the device compiles it. Apple's own guidance is to keep that out of interactive flows, which means a first-run experience, which means design and product work | You have a place to put it — an onboarding flow, an explicit opt-in, a feature-introduction screen |

And the row that is not a reason:

| ✗ | "It's the new framework" / "Core ML is legacy now" | **Not a reason.** No deprecation has been announced, no timeline exists, and your working Core ML asset is currently the *lower*-risk component of your app. Novelty is a cost, not a benefit |

### 7.1 The counter-case: five reasons the answer is yes

For symmetry, because a table that only says "no" is not a decision aid:

1. **Your model is autoregressive.** States (§4.1) are a first-class solution to a problem you are
   currently solving by hand or not at all. Community measurement puts prefix reuse at up to 101× on
   turn-2 TTFT. This is the strongest single reason in the list.
2. **You are re-authoring anyway.** If a model is being rebuilt for other reasons, rebuilding it into
   Core AI costs marginally more than rebuilding it into Core ML and leaves you on the framework
   receiving investment.
3. **You have an expensive encoder and a cheap head.** Multi-function assets (§4.2) let you re-run
   only what changed. If you also adopt `coreai-models.PreparedModel`, recognized static structures
   receive that helper's Neural Engine preference.[^sample-routing-policy]
4. **You cannot explain a numeric regression.** The Debugger's operation-level PSNR comparison
   against a PyTorch reference (§4.3) is a capability with no Core ML analogue, and "quantization
   broke something and I cannot find where" is a very common reason a model never ships.
5. **You need an op the converter has to be taught.** Core AI's authoring story — composite ops,
   custom lowerings, inline Metal kernels embedded in the asset — is the escape hatch. See
   [Part 8 reference 02](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md)
   and [reference 03](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md).

### 7.2 A note on "we'll do it for the ANE"

This appears in planning documents constantly and deserves a specific caution, because it is the one
motivation most likely to be *disappointed*.

Moving a model to Core AI does not, by itself, put it on the Neural Engine. §3.1 shows that the
optional `coreai-models.PreparedModel` classifier gives a single-`main` dynamic structure its
**GPU** preference and recognized static structures its ANE preference. That package rule does not
govern direct `AIModel` loads; those callers choose `SpecializationOptions`. Even with
`preferredComputeUnitKind: .neuralEngine`, fallback occurs *at fused-pattern granularity*, silently.
[^sample-routing-policy]

So "we'll migrate for the ANE" is really "we'll re-author for the ANE, and use Core AI because that
is where the re-authored model runs." That is a much larger project, and it is worth scoping it
honestly before it is committed to. [Part 10 reference 01](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md)
is the guide to what re-authoring involves.

---

## 8. The incremental strategy

If §7 said yes, this section is the plan. It has four steps and one rule.

**The rule: do not delete the Core ML path.** Not as a hedge — as a *requirement*, if you support any
OS below 27. Core AI has no back-deployment, so an app with a deployment target below iOS 27 must
carry both implementations regardless of how the migration goes. Once you accept that, keeping the
Core ML path as the fallback for a Core AI failure costs you nothing extra, and it converts your
riskiest change into a reversible one.

### 8.1 Step 1: put both behind one protocol

The unit of migration is a *capability* your app has, not a *file* in your bundle. Name the
capability, define a protocol for it in your app's own vocabulary, and give it two conformers.

```swift illustrative
import Foundation
import CoreVideo

/// The capability, in your app's terms. Note that nothing here mentions
/// Core ML, Core AI, tensors, or compute units.
protocol ImageTagger: Sendable {
    /// Returns confidence scores keyed by tag, highest first.
    func tags(for image: CVPixelBuffer) async throws -> [(tag: String, score: Float)]

    /// A stable identifier for logging and A/B analysis.
    var backendName: String { get }
}
```

Two conformers. The Core ML one is what you already ship 🟡:

```swift prelude:guide-context
import CoreML

/// 🟡 Illustrative. Core ML identifiers here are from general knowledge and are
/// NOT verified against the 2026 SDK — see the standing caveat above. Confirm
/// spellings in Xcode before adopting.
struct CoreMLImageTagger: ImageTagger {
    let backendName = "coreml"
    private let model: MLModel

    init(modelURL: URL, configuration: MLModelConfiguration) throws {
        self.model = try MLModel(contentsOf: modelURL, configuration: configuration)
    }

    func tags(for image: CVPixelBuffer) async throws -> [(tag: String, score: Float)] {
        // … build a feature provider, call prediction, read the output dictionary …
        fatalError("your existing, working implementation goes here")
    }
}
```

The Core AI one is new, and gated:

```swift prelude:guide-context
import CoreAI
import CoreVideo

@available(iOS 27.0, macOS 27.0, visionOS 27.0, tvOS 27.0, watchOS 27.0, *)
struct CoreAIImageTagger: ImageTagger {
    let backendName = "coreai"

    private let model: AIModel
    private let function: InferenceFunction
    private let labels: [String]

    init(model: AIModel, labels: [String]) throws {
        guard let function = try model.loadFunction(named: "main") else {
            throw TaggerError.missingFunction("main")
        }
        // Fail fast on a signature mismatch rather than producing garbage silently.
        let descriptor = function.descriptor
        guard let inputDescriptor = descriptor.inputDescriptor(of: "pixel_values"),
              case .ndArray(let arrayDescriptor) = inputDescriptor,
              arrayDescriptor.scalarType == .float32
        else {
            throw TaggerError.unexpectedSignature(descriptor.inputNames, descriptor.outputNames)
        }
        self.model = model
        self.function = function
        self.labels = labels
    }

    func tags(for image: CVPixelBuffer) async throws -> [(tag: String, score: Float)] {
        var input = NDArray(shape: [1, 3, 224, 224], scalarType: .float32)
        var view = input.mutableView(as: Float.self)
        guard let elements = view.contiguousElements else {
            throw TaggerError.nonContiguousLayout
        }
        try writePixels(image, into: elements)          // your preprocessing

        var outputs = try await function.run(inputs: ["pixel_values": input])
        guard let value = outputs.remove("scores"), let scores = value.ndArray else {
            throw TaggerError.missingOutput("scores")
        }

        // Read once, through a read-only view.
        var result: [(String, Float)] = []
        scores.view(as: Float.self).withUnsafePointer { ptr, shape, _ in
            let n = min(labels.count, shape[shape.indices.lowerBound + shape.count - 1])
            for i in 0..<n { result.append((labels[i], ptr[i])) }
        }
        return result.sorted { $0.1 > $1.1 }
    }
}

enum TaggerError: Error {
    case missingFunction(String)
    case missingOutput(String)
    case nonContiguousLayout
    case unexpectedSignature([String], [String])
}
```

> ✅ **VERIFIED API in the Core AI conformer:** `AIModel.loadFunction(named:)`,
> `InferenceFunction.descriptor`, `InferenceFunctionDescriptor.inputDescriptor(of:)` returning an
> `InferenceValue.Descriptor` with a `.ndArray(NDArrayDescriptor)` case,
> `NDArray.init(shape:scalarType:)`, `mutableView(as:)`, `MutableView.contiguousElements`,
> `run(inputs:)`, `Outputs.remove(_:)`, `InferenceValue.ndArray`, `NDArray.view(as:)`, and
> `View.withUnsafePointer { ptr, shape, strides in … }` with the `shape`/`strides` parameters typed as
> `Span<Int>`.
> 🟡 The names `"main"`, `"pixel_values"` and `"scores"`, the `[1, 3, 224, 224]` shape and
> `writePixels` are illustrative app code — your asset's real signature comes from the model viewer's
> Functions tab or `functionDescriptor(for:)`.
> ⚠️ Note the `Span<Int>` indexing in that last block: `Span` does not conform to `Sequence`, so
> `shape.count` and manual index arithmetic replace what would be `shape.last`.

### 8.2 Step 2: choose the backend once, at a seam you control

```swift prelude:guide-context
import CoreAI
import Foundation

enum TaggerFactory {

    /// A user-facing or remote-config switch, so you can turn the new path off
    /// without shipping a build.
    static var coreAIEnabled: Bool {
        RemoteConfig.bool("tagger.coreai.enabled", default: false)
    }

    static func make(coreMLURL: URL, coreAIURL: URL, labels: [String]) async -> any ImageTagger {
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, tvOS 27.0, watchOS 27.0, *), coreAIEnabled {
            do {
                // Only take the fast path if the specialization is ALREADY cached.
                // A cold cache means a multi-minute stall, which is not something to
                // discover at the call site.
                let options = SpecializationOptions.default
                if let model = try AIModelCache.default.model(for: coreAIURL, options: options) {
                    return try CoreAIImageTagger(model: model, labels: labels)
                }
                Diagnostics.record("tagger.coreai.not_specialized")
            } catch {
                Diagnostics.record("tagger.coreai.init_failed",
                                   domain: (error as NSError).domain,
                                   code: (error as NSError).code)
            }
        }
        return (try? CoreMLImageTagger(modelURL: coreMLURL, configuration: .init()))
            ?? NullTagger()
    }
}
```

> ✅ **VERIFIED** — `AIModelCache.default`,
> `model(for modelURL: URL, options: SpecializationOptions) throws -> AIModel?`, and Apple's
> discussion that it *"**never performs specialization**"* and returns `nil` when nothing is cached.
> Session 324 names exactly this use: *"If **nil is returned, it is not present and requires
> specialization**. You can use this to **gate features or inform the users that they may need to
> wait a bit while your app prepares the model**."*
> 🟡 `RemoteConfig`, `Diagnostics` and `NullTagger` are your app's own types.

Three properties of that factory worth stating explicitly, because they are what make the migration
reversible:

1. **The `#available` check and the feature flag are independent.** The first is a hard platform
   gate; the second is a decision you can change from the server. Do not conflate them.
2. **The cache probe is a *readiness* check, not a load.** If the specialization has not happened
   yet, this call path falls back to Core ML instead of stalling. The specialization itself belongs in
   a deliberate first-run flow — see
   [Part 15 reference 01 §2](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md).
3. **Every failure is recorded and none of them is fatal.** Given §5.2, you cannot yet distinguish
   Core AI failure *modes*, so record the domain and code and move on. The aggregate is what tells
   you whether the new path is healthy.

### 8.3 Step 3: measure, on a device, against your own baseline

The whole reason for keeping both paths is that it makes the comparison trivial and honest. Run the
same inputs through both conformers on the same device in the same session.

Four things to measure, in order of how often they are forgotten:

| Measure | Why it is not optional |
|---|---|
| **Which compute unit actually ran it** | §3.1. Use the Core AI Instruments template and look at the Neural Engine track. A latency number without this is uninterpretable |
| **First-load time, cold** | Specialization is a user-visible cost that a warm benchmark hides entirely. Measure it once per device model, from a cleared cache |
| **Steady-state latency and memory** | The number you thought you were measuring |
| **Output similarity to the Core ML baseline** | Not equality. Quantization and specialization both introduce drift (§3.2); decide the threshold in advance |

Rules for not fooling yourself, all of which have a verified basis:

- **Real device only.** ✅ **VERIFIED** — Apple's Instruments article says it twice: *"Profile on a
  **real device** for the most accurate performance data"* and *"For the most actionable results,
  **run your app on its own. Other apps competing for CPU, GPU, or Neural Engine resources can
  distort the trace.**"*
- **Separate the first inference from the rest.** ✅ **VERIFIED** — Instruments distinguishes
  **Specialization** (at most one per model, *"often the most time-intensive"*), **Load** (*"only at
  the start of runtime"*), **Setup** (*"A Setup event precedes each inference"*) and **Inference**.
  A mean over all four categories is a meaningless number.
- **Watch for repeated Load events.** ✅ **VERIFIED** — Apple: *"**If you see frequent Load events
  during runtime, check that your app doesn't reload models repeatedly.**"* This is the single most
  common self-inflicted performance bug in a fresh Core AI integration, and it comes directly from a
  Core ML habit of constructing the model where you use it.
- **Re-benchmark after any toolchain change.** [17.6](06-toolchain-and-asset-compatibility.md)
  documents a community-measured case where an identical recipe with identical wheels produced a
  **2.2× slower, 2× larger** artifact purely because the *host* OS changed. Artifacts are not pure
  functions of recipes this year.
- **Thermals and sustained load.** A three-inference benchmark tells you nothing about a camera loop.
  [Part 15 reference 02](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md)
  is the guide to doing this properly.

Write the threshold down before you measure. "Ship Core AI if p50 latency improves ≥ 25% at equal or
better PSNR against the Core ML baseline, on iPhone 16 and later, with no regression in peak memory"
is a decision rule. "It felt faster" is not.

### 8.4 Step 4: migrate exactly one model, and pick it deliberately

Pick the model that maximizes learning per unit of risk. In rough order of preference:

1. **A model with a clear §4 problem** — an autoregressive decoder, or a pipeline with an expensive
   encoder and a cheap head. You learn the parts of Core AI that justify the migration.
2. **A model whose PyTorch source you definitely have** and which exports cleanly. You are learning
   the framework, not fighting `torch.export`.
3. **A model behind a feature flag with a fallback** — which, if you followed §8.1, is all of them.
4. **Not your largest model.** A 3 GB asset makes every iteration slow and puts you straight into
   specialization-stall territory before you understand the basics.
5. **Not your most business-critical model.** Obvious, routinely ignored.

Then keep both in production, flagged, for at least one full release cycle. You get: real-device
telemetry across your actual hardware distribution, an instant rollback, and — because Core AI
invalidates every cached specialization on OS update (✅ verified) — an honest look at what a point
release does to your users' first launch. That last observation is only available with a fallback in
place, which is the argument for the rule at the top of this section.

### 8.5 Where the Core ML path stays permanently

Two of them, and neither is temporary:

- **Below iOS 27.** Until your deployment target reaches 27.0, the Core ML implementation is not a
  fallback, it is *the* implementation for a share of your users. Treat it accordingly — it gets
  tests, it gets model updates, it gets the same care as before.
- **Non-neural models.** §1. These are never coming across. If your app has both a tabular model and
  a transformer, your app links both frameworks, permanently, and that is the intended end state
  rather than an intermediate one.

The dual-SDK mechanics — `#if canImport` versus `@available` versus SDK-version checks, and which
symbols cannot be papered over with a runtime check — are
[17.4](04-dual-sdk-builds.md). The version-floor table (26.0 / 26.2 / 26.4 / 27.0) is
[17.1](01-what-changed-checklist.md) and
[Part 1 reference 02](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/references/02-platform-and-version-gating.md).

---

## 9. Quick reference

### 9.1 The translation table, condensed

Core AI column ✅ verified · Core ML column 🟡 unverified against a 2026 SDK.

```
MLModel                          →  AIModel  +  InferenceFunction        (two objects, not one)
MLModelAsset                     →  AIModelAsset                          (inspect without specializing)
MLMultiArray / MLShapedArray     →  NDArray                               (access through views)
  element access                 →  NDArray.View<T> / MutableView<T>      (non-escapable, compile-enforced)
MLFeatureProvider                →  [String: NDArray]  or Inputs          (no protocol to conform to)
  reading outputs                →  Outputs.remove(_:)                    (⚠️ destructive, take once)
CVPixelBuffer                    →  CVReadOnlyPixelBuffer / CVMutablePixelBuffer
MLModelConfiguration.computeUnits→  SpecializationOptions                 (⚠️ part of the cache key)
MLComputeUnits                   →  ComputeUnitKind {.cpu,.gpu,.neuralEngine}
model compilation → .mlmodelc    →  specialization → an AIModelCache entry (⚠️ invalidated on OS update)
  (no direct analogue)           →  xcrun coreai-build compile → .aimodelc (AOT, A17 Pro / M1 / M2 gate)
MLState                          →  states: InferenceFunction.MutableViews (⚠️ all states required)
multi-function models            →  functionNames + loadFunction(named:)
.mlmodel / .mlpackage            →  .aimodel                              (⚠️ a DIRECTORY)
.mlmodelc                        →  .aimodelc                             (⚠️ also a DIRECTORY)
Xcode-generated wrapper class    →  (nothing — hand-write the adapter)
coremltools                      →  coreai-torch  (TorchConverter class, no convert() function)
coremltools.optimize             →  coreai-optimization  (coreai_opt) — can also target Core ML
(no analogue)                    →  Core AI Debugger, .aimodelintermediates, PSNR sync points
```

### 9.2 The Core AI API you need on day one

```swift illustrative
import CoreAI

// Inspect without paying for specialization.
let asset = try AIModelAsset(contentsOf: url)
let summary = try asset.summary(includingStatistics: false)     // nil if no program bytecode
summary?.functions.forEach { print($0.name, $0.inputs.map(\.name), $0.states.map(\.name)) }

// Is it already specialized? Synchronous, cheap, never specializes.
let cached: AIModel? = try AIModelCache.default.model(for: url, options: .default)

// Specialize deliberately, behind explanatory UI.
try await AIModel.specialize(contentsOf: url, options: .default, cachePolicy: .persistent)

// Load, introspect, run.
let model = try await AIModel(contentsOf: url, options: .default)
print(model.functionNames)
guard let fn = try model.loadFunction(named: "main") else { throw … }
print(fn.descriptor.inputNames, fn.descriptor.outputNames, fn.descriptor.stateNames)

var x = NDArray(shape: [1, 3, 224, 224], scalarType: .float32)
var mv = x.mutableView(as: Float.self)
guard let elements = mv.contiguousElements else { throw … }     // may be nil — see §2.3

var outputs = try await fn.run(inputs: ["input": x])
guard let v = outputs.remove("output"), let y = v.ndArray else { throw … }
process(y.view(as: Float.self))
```

> ✅ **VERIFIED** — every signature above is quoted from Apple's Core AI reference pages. The
> `"main"` / `"input"` / `"output"` names and the shape are placeholders for your asset's real
> contract.

**And a module-layout fact the reference pages never state**, ✅ **SDK-verified** from the interface
dumps captured 2026-07-29, recaptured 2026-08-20 (Xcode 27.0 beta, `notes/sdk-interfaces/`): `import CoreAI` — the spelling
every snippet in this guide uses — is an **umbrella**. The `CoreAI` module's entire interface is one
line, `@_exported public import CoreAIDelegates` (`CoreAI-27.0-macos.swiftinterface:5`), and
`CoreAIDelegates` (a SubFramework in the SDK) in turn `@_export`s `CoreAIAsset`, `CoreAICommon`,
`CoreAICompiler` and `CoreAIRuntime` (`CoreAIDelegates-27.0-macos.swiftinterface:5-8`) — all built
with `-public-module-name CoreAI`, which is why every symbol presents as `CoreAI.*`. Three
placement details that matter when an error message or a stack trace names the real module:
**`AIModelCache` lives in `CoreAIDelegates`** (`CoreAIDelegates-27.0:29-45` — including
`model(for:options:)`, exactly the `throws -> AIModel?` non-async signature quoted above), not in
`CoreAICache`; the `CoreAICache`, `CoreAICommon` and `CoreAICompiler` modules have **empty public
Swift surfaces**; and `AIModel`'s bookmark and `specialize` conveniences are `CoreAIDelegates`
extensions on the `CoreAIRuntime` class (`CoreAIDelegates-27.0:14-27`). None of this changes what
you write — `import CoreAI` remains correct — but it explains why `CoreAIDelegates.AIModelError`
shows up in bridged `NSError` domains (§5.2) while your source never mentions that module.

### 9.3 Ten things that will surprise a Core ML migrant

1. `.aimodel` is a **directory**. So is `.aimodelc`.
2. `AIModel` does not run anything — `InferenceFunction` does, and it owns the weights.
3. `AIModel.init(contentsOf:)` is `async` because it may take **minutes** the first time.
4. Every OS update invalidates every cached specialization, regardless of policy.
5. `SpecializationOptions` is part of the **cache key** — two options structs mean two multi-GB entries.
6. `Outputs.remove(_:)` is destructive; `InferenceValue.ndArray` is a consuming read.
7. `contiguousElements` can be `nil`, and after specialization that is not hypothetical.
8. Every state must be supplied on every `run`; there is no `stateCount`, only `stateNames.count`.
9. `coreai-models.PreparedModel` gives a single-`main` dynamic structure its **GPU** preference;
   direct `AIModel` callers choose their own options.[^sample-routing-policy]
10. There is no generated wrapper class, no sample project, and — SDK-confirmed (§5.2) — no public
    runtime error type to catch.

### 9.4 The three sentences to take away

1. **Core AI is for neural networks; Core ML keeps everything else.** This is a partial migration by
   design, and for many apps the correct scope is "some models, not all."
2. **Nothing in this migration announces itself.** A converted model that loads and produces correct
   numbers can still be on the wrong compute unit, doubly cached, numerically drifted, or built by a
   converter pass with an open miscompile bug. Validate the artifact you ship, at the stage you ship
   it from.
3. **Keep the Core ML path.** You need it below iOS 27 anyway, and once you have it, the migration is
   a reversible experiment instead of a one-way door.

---

## 10. Sources and evidence ledger

### 10.1 What this guide is built from

**Apple documentation (Core AI) — ✅ strongest evidence in this guide.** A complete harvest of
`/documentation/coreai`, enumerated against Apple's own nav index at
`developer.apple.com/tutorials/data/index/coreai` (**312 symbol/page entries**, every path verified
present, every declaration read). The seven articles used most here:

- *Run AI models in your app on Apple silicon* — the framework overview, and the source of the single
  Core ML routing sentence this guide is built around.
- *Integrating on-device AI models in your app with Core AI* — the load/run code, the model viewer,
  the Metal Toolchain requirement.
- *Managing model specialization and caching* — specialization, the cache, policies, bookmarks,
  app groups.
- *Compiling Core AI models ahead of time* — `coreai-build`, `.aimodelc`, the A17 Pro / M1 / M2 gate.
- *Inspecting, debugging, and profiling Core AI models* — the three-tool topology.
- *Inspecting Core AI models with Core AI Debugger* — visualize / execute / validate, sync points.
- *Validating inference correctness against a reference run* — `.aimodelintermediates`, the five
  metrics, PSNR as default.

Plus `developer.apple.com/core-ai-debugger/` for the Debugger's host and paired-device requirements.

**Apple's shipped repositories — ✅ compiling first-party code.**

- `apple/coreai-models` — `CoreAIShared/Runtime/ModelStructure.swift` (the structure classifier and
  compute-unit mapping that anchors §3.1 and §4.2), `NDArray+Helpers.swift` (the `Span` extension),
  `export/compiler.py` (the swallowed quantization warning), `pipeline.py` (`shutil.rmtree` on the
  `.aimodel` directory).
- `apple/coreai-torch` — `TorchConverter` signatures, `tests/test_stateful.py` (the `register_buffer`
  → state mechanism and the resulting IR), the mandatory `run_decompositions` / `optimize()` rules,
  the `entrypoint_name` uniqueness constraint, the `pyproject.toml` dependency sets.
- `apple/coreai-optimization` — `Quantizer`, `KMeansPalettizer`, `MagnitudePruner`, the
  `ExportBackend.CoreAI` / `ExportBackend.CoreML` split, the destructive-`finalize` note, the silent
  granularity skip.

**WWDC26 transcripts — ✅ for narration, 🟡 for any code reconstructed from it.**
Session **324** *"Meet Core AI"* (specialization's two phases; states; the interactive-flows
recommendation; the non-escapable-view framing). Session **325** (the three-function SAM 3 split and
the 76% figure). Session **326** (the failing-demo specialization story and the first-run experience
recommendation).

**Issue trackers — ✅ that the issue was filed, 🔴 for current status.** `coreai-torch` #6, #9, #10,
#21, #49, #51; `coreai-models` #49, #55. Every one is reported here with its status marked unknown as
of the corpus snapshot.

**Community measurement — always attributed as such.** The 101× prefix-reuse figure and the
`@Generable`/logits constraint (`john-rocky-models`); the 194-second first-load figure and the
options-drift incident note (a shipping community iOS app), both relayed through
[Part 7 reference 02](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md)
and [Part 15](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/README.md).

### 10.2 What this guide does **not** rest on

- **Any Core ML documentation.** There is none in this corpus. Every Core ML identifier in this guide
  is marked 🟡 and is from general familiarity with a long-stable framework.
- **Any Apple sample-code project.** There are none for Core AI — that is itself a verified finding
  (§5.1), not an omission on our part.
- **Any `.mlmodel → .aimodel` converter.** None is documented; §6.1 declares this as a gap rather
  than filling it with a guess.

### 10.3 Declared gaps, collected

Every 🔴 in this guide, in one place, so a future pass can close them.

| § | Gap | What would resolve it | Safe default until then |
|---|---|---|---|
| Preamble | The entire Core ML column is unverified against a 2026 SDK | A doc pass over `/documentation/coreml` on the 27 doc set + a `CoreML` `.swiftinterface` dump | Treat Core ML cells as concept aids; confirm spellings in Xcode |
| §2.3 | How to read sub-byte and 8-bit-float `NDArray`s from Swift; `ScalarType.type` is referenced by a doc note but absent from the 312-symbol index | An SDK interface dump, or a device experiment on a palettized tensor | Keep public function I/O in `.float32` / `.float16`; treat sub-byte as storage-only |
| §2.5 | `expectFrequentReshapes` — no discussion, no stated default, no initializer | An Apple answer, or a controlled A/B on a dynamic-shape model | Leave it alone unless you ship a dynamic-shape decode loop |
| §2.9 | Whether a zero-copy `CVPixelBuffer` image path exists in practice — Apple's own vision packages do not use one | A converted image-input model run both ways under the Instruments template | Follow Apple's package: `CGImage` in, hand-built `Float32` `NDArray` out |
| §3.4 | Current status of `coreai-torch` #49 (`optimize()` dropping broadcasting-significant axis moves) | Check the issue before trusting a converted model with pairwise-distance or explicit-broadcast patterns | Run the parity check on the **optimized** program |
| §4.2 | The 76%-faster claim has no stated device, warmup protocol or comparison basis | A reproduction on named hardware with a stated protocol | Treat it as an existence proof, not a number to quote |
| §5.2 | ~~Whether a typed runtime error exists~~ **Narrowed 2026-07-29:** the interface dumps confirm no public error type outside `CoreAIAsset.AssetError` — throws are untyped. Still open: the runtime error *values* (domains/codes) that actually escape | Induced failures logged by domain and code on a device | Catch `AssetError` where relevant, then general `Error`; branch on observable state, not error identity |
| §5.4 | Whether the Core AI Swift package still fails to build for the iOS Simulator | A clean `xcodebuild` against a current Xcode 27 beta | Plan for device-only development and CI |
| §5.4 | Current status of every listed converter/runtime defect | Re-check each tracker | Numeric gate plus device test, not a green build |
| §5.5 | Whether a C header surface exists but is undocumented — **narrowed 2026-07-29:** the Swift interface dumps show no `@objc` exposure anywhere | The framework `Headers/` directory in the Xcode 27 SDK | Budget a Swift interop layer; assume no bridge for `~Copyable` types |
| §6.1 | Whether any `.mlmodel` → `.aimodel` path exists or is planned | An Apple statement, or a `coreai-torch` release note | Assume none; plan on going back to source |
| §6.3 | Current `coremltools` API for reading a model spec | The `coremltools` docs for the current release | Confirm before planning a weight-extraction project |

### 10.4 Where to go next

- **You decided to convert one model** →
  [Part 8 reference 01](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md),
  then [reference 02](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md)
  when an op will not lower.
- **You decided to re-author for the Neural Engine** →
  [Part 10 reference 01](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md).
- **You need to understand the first-launch cost before committing** →
  [Part 7 reference 02](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md).
- **Your model is autoregressive** →
  [Part 7 reference 03](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md).
- **You are re-converting an existing pipeline** → [17.6](06-toolchain-and-asset-compatibility.md)
  **before** you benchmark anything.
- **You must support both 26 and 27** → [17.4](04-dual-sdk-builds.md).
- **You are shipping the result** →
  [Part 15 reference 01](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md)
  for delivery and updates, and
  [reference 02](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md)
  for benchmarking that survives contact with a real device.
- **You are still deciding between backends at all** →
  [Part 1 reference 01](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/references/01-apple-ai-stack-2026-map.md),
  whose decision table covers Core AI, MLX and the Foundation Models conformers together, and whose
  §4 carries the Core ML boundary in its own words.

[^coreml-boundary]: Apple’s Core AI framework overview is the source of this routing guidance and
    links to the full Core ML documentation URL:
    [Run AI models in your app on Apple silicon](https://developer.apple.com/documentation/coreai).

[^sample-routing-policy]: The classifier and preferences are implemented in the optional
    `apple/coreai-models` package’s pinned
    [`ModelStructure.swift`](https://github.com/apple/coreai-models/blob/5ed9981303b38d5a44aa6b45509bc4f6945029f5/swift/Sources/CoreAIShared/Runtime/ModelStructure.swift#L12-L218).
    Core AI’s documented `.default` behavior is separate:
    [Managing model specialization and caching](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/docs/Managing%20model%20specialization%20and%20caching.md).
