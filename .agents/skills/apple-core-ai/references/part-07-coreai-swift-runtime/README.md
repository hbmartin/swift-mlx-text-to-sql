# Part 7 — Core AI: the Swift runtime

**Version floor:** everything here is **27.0 and only 27.0**. `import CoreAI` requires **iOS · iPadOS ·
macOS · Mac Catalyst · tvOS · visionOS · watchOS 27.0**, and **every symbol is Beta**. Core AI is a *new
framework* in the 27 cycle, not a rename of Core ML: nothing back-deploys, no `@available(iOS 26, *)`
fallback buys you anything, and there is no release-notes page to diff against —
`/documentation/updates/coreai` returns **404**. You need **Xcode 27** and the **Metal Toolchain**, a
separate download (`xcodebuild -downloadComponent MetalToolchain`); without it any target containing a
`.aimodel` fails to build with a *missing Metal compiler* error that never mentions Core AI.
Metal-interop APIs **omit watchOS from their doc-page availability lists**, while the captured macOS
27.0 beta SDK interface declares them `watchOS 27.0` (see 7.1 §16.3); treat the interface as the
stronger signature evidence and verify on device. `apple/coreai-models` is **macOS 27 and iOS 27 only**.

**Who this is for:** Swift developers who have a converted model and must make it load, run and stay fast
on a device. Producing the `.aimodel` is [Part 8](../part-08-coreai-pytorch-conversion/README.md); choosing Core AI
over another backend is [Part 1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/README.md).

---

## ⚠️ Read this before you trust a signature in this part

**Core AI ships with zero Apple sample-code projects.** Verified, not assumed: Apple's own documentation
index enumerates **312 Core AI symbol and page entries**, and filtering it for `sampleCode` returns
**zero**. For Parts 1–6 the strongest evidence class was a *compiling Apple sample project*; here there
is none, so these guides stand on a different ladder, strongest first: **shipped Apple source read on
disk** (`apple/coreai-models`, `apple/coreai-torch` — Apple-authored code calling these APIs for real);
**Apple's own agent skills** in those repos, written for coding agents and unusually blunt; **Apple's
documentation pages** including raw DocC JSON, unusually complete for Core AI; then **WWDC26 transcripts**
(324, 325, 326), useful for *intent* and weak for *spelling*.

Two consequences. **Signatures are more often 🟡 RECONSTRUCTED here than in Parts 1–6** — individual
declarations are usually ✅ VERIFIED from a doc page or a shipped file, but every *assembled, runnable
example* is a composition, because there is no first-party project to copy one from; each guide marks
that seam. And **four of Apple's own documentation samples do not compile**; where a guide reproduces
one, it says so and gives the corrected form.

---

## Why this part exists

The three-line version — `try await AIModel(contentsOf:)`, `loadFunction(named: "main")`,
`try await fn.run(inputs:)` — works, and hides all four of these.

1. **The `await` hides a compiler, not a disk read.** A `.aimodel` is portable *source*, closer to LLVM
   IR than to a `.dylib`, and must be **specialized** for this device *and this OS version* before a
   valid `AIModel` exists. Apple's own session says to *"avoid having model specialization occur within
   user interactive flows."* A 3 GB model was community-measured at **194 seconds** on that first load —
   on an iPhone, on an already AOT-compiled asset.
2. **`nil` and `throws` mean different things, everywhere.** `loadFunction` returns `nil` for a wrong
   name and throws for a failed load; `init?(resolvingBookmark:)` returns `nil` for a stale entry and
   throws for malformed data; `Outputs.remove` returns `nil` benignly on a second take while
   `NamedMutableViews.take` **traps**. `try?` collapses all of it.
3. **Most defects do not throw.** A contiguous `NDArray` gets copied into the hardware's preferred layout
   on *every* run, forever, with no diagnostic. A KV cache gets copy-on-written in full every decode
   step. Options differing by one flag between two call sites miss the cache permanently.
4. **The fastest engine cannot do structured output.** Grammar-constrained decoding needs per-step
   logits; the GPU-pipelined engine samples on-GPU and never surfaces them — and it is auto-selected for
   every macOS dynamic export, so `@Generable` and the default fast path are mutually exclusive.

---

## Read this first: the triage table

| If your situation is… | Read | Why |
|---|---|---|
| "I have a `.aimodel` and want it running today" | [7.1 §0–§9](references/01-runtime-and-ndarray.md#0-orientation-the-pipeline-the-file-the-toolchain) | The whole object model; §14 is a runner you can paste |
| "What error type do I `catch`?" · "`contiguousElements` is `nil`" · "`shape.reduce` won't compile" | [7.1 §13, §7](references/01-runtime-and-ndarray.md#13--the-error-type-answer-and-how-to-write-a-catch-block) | ✅ SDK-verified: untyped throws, `AssetError` only; preferred strides or interleave; `Span` is not a `Sequence` |
| "My first launch stalls for minutes" | [7.2 §1–§5](references/02-specialization-caching-and-aot.md#1-what-specialization-actually-is) | Specialization. Gate on `model(for:options:)`, pre-specialize behind explanatory UI |
| "The stall came back after I was sure I'd paid it" | [7.2 §4, §6](references/02-specialization-caching-and-aot.md#4-the-cache-key-and-how-to-double-your-disk-usage-by-accident) | The key is `(asset, options)` — or an OS update, which purges everything regardless of policy |
| "Inference intervals grow along the Instruments timeline" | [7.3 §1–§5](references/03-states-and-pipelined-execution.md#1-the-symptom-intervals-that-grow) | No states. The one bug here that announces itself visually |
| "Output is right, throughput is a flat multiple too low" · "SIGTRAP at the first execute" | [7.3 §8.1, §13](references/03-states-and-pipelined-execution.md#81-️-silent-failure--copy-on-write-copies-your-entire-kv-cache-every-step) | Copy-on-write on the state, invisible in the Core AI instrument; or the MPSGraph in-graph KV-write bug |
| "Turn 2 of my chat is as slow as turn 1" · "hybrid/SSM or plain?" | [7.3 §14](references/03-states-and-pipelined-execution.md#14-prefix-reuse-one-integer-assignment-101) · [7.4 §6](references/04-bundles-engines-and-guided-decoding.md#6-kv-cache-strategy-and-prefix-reuse) | Prefix reuse: ~101× on turn-2 TTFT, one integer assignment — and linear attention forfeits it entirely |
| "`@Generable` throws `unsupportedCapability`" · "I want topK/topP" | [7.4 §7.8, §9](references/04-bundles-engines-and-guided-decoding.md#78-️-the-architectural-constraint-guided-generation-and-the-fastest-engine-are-mutually-exclusive) | You are on the pipelined engine; and sampling knobs live on `TextGenerator`, not `GenerationOptions` |
| "`unsupported metadata_version '0.1'`" · "works on my Mac, not on device" | [7.4 §2.3, §2.7](references/04-bundles-engines-and-guided-decoding.md#23-️-aimodel-and-aimodelc-are-directories) | You pointed at the `.aimodel`, not the bundle dir; or a missing `tokenizer/` is fetching from the Hub |
| "Should my vision pipeline be one function or three?" · "Why is SAM3 on a different compute unit?" | [7.5 §3–§4, §9](references/05-non-llm-engines-bundles-warmup-and-caching.md#3-preparedmodel-inspect-before-specializing) | Inspect before specializing; distinguish the package's loader policy from a framework routing rule |
| "What does warmup actually warm?" · "Why is my detector cold at a new shape?" | [7.5 §5, §7–§8](references/05-non-llm-engines-bundles-warmup-and-caching.md#5-object-detection-one-raw-asset-one-real-warmup) | Load, function load, dummy forward, specialization cache, and semantic feature cache are separate states |
| "How should a diffusion bundle own its components?" · "Should I use lazy loading?" | [7.5 §6, §8–§9](references/05-non-llm-engines-bundles-warmup-and-caching.md#6-diffusion-a-bundle-of-independently-owned-models) | Multi-asset GPU components have independent residency; unload is not specialization-cache deletion |

---

## The guides in this part

### [7.1 — `AIModel`, `InferenceFunction`, `NDArray`, and the memory model](references/01-runtime-and-ndarray.md)

The object-model primer every other guide assumes, built around the structural fact that makes app
architecture fall out: **`AIModel` owns nothing and pins a cache entry; `InferenceFunction` owns the
weights**, so "when does this cost me a gigabyte?" is answered *at `loadFunction`, not at `init`*. Then
the part readers find hardest — Core AI is one of the SDK's heaviest adopters of Swift's non-escapable
machinery (`Span`, `InlineArray`, value generics, `consuming`/`borrowing`, typed throws), and §7 teaches
what that buys you rather than leaving you to fight the compiler. Also descriptor-driven code so your app
survives a model re-export, the three low-level performance APIs session 324 names and never explains.

> ⚠️ **SILENT FAILURE — the layout-conversion copy (§11.1), and five siblings.** Allocate with Apple's
> own hello-world `NDArray(shape:scalarType:)` and specialization may have decided the hardware wants
> padded or interleaved strides: your call succeeds, the numbers are right, and the framework copies your
> tensor into a different layout **on every inference, forever**, with no diagnostic anywhere in the API,
> the docs or the tooling. Also: `outputViews:` for a name **removes it from the returned `Outputs`**
> (§9.4); concurrent `run` calls silently allocate more scratch, so an unbounded `TaskGroup` works on an
> M4 Max and gets jetsammed on a phone (§5.2); `AsyncValue.ndArray` returns a **copy** for an
> `MTLBuffer`-backed value (§11.3); a dtype flag cached from the *input* descriptor and used on an
> *output* reinterprets bits into numeric garbage (§7.10); and EXIF orientation is nobody's job — Apple's
> own repo applies it on one path and not the other, so the same JPEG yields two orientations (§12.4).
>
> ✅ **ANSWERED (was the part's biggest GAP) — the error you catch is `AssetError`, or nothing (§13).**
> The macOS 27.0 beta SDK interface, captured 2026-07-29, recaptured 2026-08-20, settles it: `AIModel.init`, `loadFunction`,
> `run`, `encode` and the cache `delete*` methods all throw **untyped** errors, and the only public
> error type in the entire Core AI surface is `CoreAIAsset.AssetError` — five `Kind` cases, all about
> the asset file (`unsupportedVersion`, `invalidFeatureType`, `corruptedMetadata`, `invalidName`,
> `duplicateName`). No public inference/specialization/cache error enum exists in this beta; the
> community-sighted `AIModelError` is internal to `CoreAIDelegates`. §13.2's catch-`AssetError`-then-
> catch-broadly, degrade-don't-retry ladder is therefore not a workaround but the correct shape.

### [7.2 — Specialization, the model cache, and ahead-of-time compilation](references/02-specialization-caching-and-aot.md)

The single largest source of first-launch stalls, wedged loads and mysterious disk growth. Specialization
is two phases — compilation (*"the one which incurs most of the latency"*) then per-device artifact
generation — and every lever follows from that split: `coreai-build compile` moves phase 1 to your Mac,
`AIModel.specialize` moves its *timing* without reducing it, and `AIModelCache.model(for:options:)` is a
synchronous probe that **never specializes**, the gating primitive for a "Preparing…" screen. Also
retention policy, app-group caches, bookmarks that let you delete the source and keep running, and a
five-rung recovery ladder for wedged loads.

> ⚠️ **SILENT FAILURE — three of them.** The cache key is `(asset, SpecializationOptions)`, and the
> options are a `struct` with a mutable property, so two code paths can construct *almost* the same
> value: each combination gets its own **multi-gigabyte** entry and its own three-minute stall, with no
> error and no warning (§4). `expectFrequentReshapes` — the only settable property, documented with a
> one-line abstract and no stated default — was device-measured to make the runtime **discard your AOT
> specialization and compile on device** when requested on an all-static graph, observed case a
> `SIGSEGV` inside the Metal compiler with no message (§11). And **`coreai-build compile` exits 0 for
> architectures the device will reject**; only a device load validates the choice (§13).
>
> ✅ **REVERIFIED 2026-09-16 — the reference pages describe the tested runtime (§7).** On the
> beta-5 device, stable macOS 27, and iPhone 15 Pro running iOS 27 build `24A435`, deleting an entry retained by a live `AIModel`
> threw, left the entry findable, and succeeded after release; the article's silent-deferral wording
> did not match this run. The guide retains release-delete-verify code and notes that the observed
> error type is non-public. The full `coreai-build` CLI surface, open
> when this was written, **closed 2026-07-31**: the tool ships in the optional **Metal Toolchain
> component** (`xcodebuild -downloadComponent MetalToolchain`), not Xcode-beta.app itself — which is
> why the 2026-07-29 check found it absent — and its full `--help` is captured in
> `notes/sdk-interfaces/coreai-build-help-27.0-beta.txt` (§13). Still open: cancellation semantics
> for a specialization large enough to remain in flight when cancellation arrives; the current
> Mac/device fixture completed after about 10 seconds and left a cache entry, so it remains inconclusive.

### [7.3 — States as KV cache, and pipelined execution](references/03-states-and-pipelined-execution.md)

A decode loop written the naive way gets slower every step, and in Instruments it is unmistakable:
**inference intervals that visibly widen along the timeline**. The fix is *states* — arguments the model
both reads and writes in place — taught across all three layers they touch, because a mistake at any one
converts cleanly and then misbehaves: `register_buffer` plus in-place mutation in PyTorch, `state_names`
plus a **mandatory** `optimize()` at conversion, `InferenceFunction.MutableViews` at runtime. Then the
tier above `run`: `encode(…, to: ComputeStream)` is `throws`, not `async throws`, so the CPU can encode
step *n+1* while the GPU computes step *n*, with the framework inserting the dependency edges itself.

> ⚠️ **SILENT FAILURE — copy-on-write on the state (§8.1), plus three more.** `NDArray` is a value type
> with COW storage, so holding your states in a dictionary you also read during the step leaves the
> buffer non-uniquely referenced and the in-place update **copies the entire KV cache — tens of
> megabytes — every decode token**. Output is perfect, the Core AI instrument looks healthy (the copy is
> CPU work outside the inference event), and your tok/s is a flat multiple too low. Also: an in-place
> mutation of a `forward()` argument **silently promotes it from an input to a state** (§8.2);
> `state_names` ordering is *observed FX behaviour, not a PyTorch contract* while every consumer indexes
> `stateNames` positionally, so a swap yields a model that attends keys to values with a clean bill of
> health from every tool (§4); and nothing resets a state between conversations (§8.4).
>
> 🔴 **GAP + incident — the fixed-shape/ANE decode recipe crashes on the betas (§13).** Community
> isolation (FB23024751, `apple/coreai-models` #5) narrowed it to one variable: deriving the KV write
> index **in-graph from runtime data**. Conversion succeeds; load and execute die — SIGTRAP on Mac GPU,
> SIGSEGV on iPhone GPU, SIGABRT on the ANE, where it also **corrupts the ANE compile cache**. Two
> workarounds are documented; status unknown, so check the Feedback first. Also 🔴: the widely-repeated
> **3.5× pipelining figure measures against a naive hand-rolled `fn.run()` loop, not against the
> sequential engine**, and no controlled comparison of the two exists (§12).

### [7.4 — Model bundles, the LLM engines, and grammar-constrained decoding](references/04-bundles-engines-and-guided-decoding.md)

The layer above the runtime, where a raw `.aimodel` becomes something shippable and Apple's own Swift
package turns "I have a converted Qwen3" into `LanguageModelSession(model:)`. **The bundle format** —
schema `0.2`, a role→filename `assets` map, sidecars — which Apple's documentation never specifies,
reconstructed here from its four Python writers and two Swift readers with the disagreements called out.
**The engines** — three LLM engines plus a VLM engine, selected for you by *the function names inside
your model*, which is also what decides whether you land on the GPU or the Neural Engine. And
**grammar-constrained decoding**: `@Generable` on a non-Apple model is a JSON schema compiled into a
formal grammar masking the logits to `-inf`, and Apple, MLX and (by source-level evidence) the `CoreAI`
framework itself all reach for **`mlc-ai/xgrammar`** to do it — documented nowhere.

> ⚠️ **The architectural constraint (§7.8).** Constrained decoding needs per-step logits; the
> GPU-pipelined engine samples on-GPU, reports `supportsLogits == false`, and **is auto-selected for
> every macOS dynamic export** — so on the default path, on macOS, with a stock Apple export,
> `@Generable` throws `unsupportedCapability` at generation time on a session you already built. The
> nuance most retellings drop: *three of the four engines can do it*; the GPU path cannot, and on iPhone
> the ANE static-shape engine is auto-selected and it works out of the box. Worse, the check you would
> write lies: with the default `mode: .lazy`, **`capabilities` reports `.guidedGeneration` before the
> engine loads**. Use `mode: .eager` whenever you branch on it.
>
> ⚠️ **SILENT FAILURE (four more).** `metadata.json`'s `compression` records the **request, not the
> result** — a quantization that raised is caught, logged as one `WARNING` mid-export, and ships a
> float16 artifact ~4× too big with exit code 0 (§2.11). A missing `tokenizer/tokenizer.json` falls back
> to a **HuggingFace Hub fetch**, instant from your Mac's cache and broken on a user's device (§2.7).
> `ConstrainedGenerationSession` accepts a `stopTokenIds` array, documents it as what prevents EOS
> mid-object, **logs it, and discards it** (§7.4). And `vocabType` defaults differ between initializers,
> where the wrong one over-constrains the grammar into producing nothing (§7.5).
>
> 🔴 **GAP — `CoreAISpeech` has no exporter.** `SpeechBundle` requires `encoder.aimodel` +
> `decoder.aimodel` and **nothing in the repository produces that split**; treat it as pre-release
> (§2.9). Also open: whether a multi-name `function_map` is honoured anywhere, and whether
> `SystemLanguageModel`'s own structured output is this same xgrammar mechanism.

### [7.5 — Non-LLM engines: bundles, function structure, warmup, specialization, and caching](references/05-non-llm-engines-bundles-warmup-and-caching.md)

The runtime owner for `CoreAISegmentation`, `CoreAIObjectDetection`, and `CoreAIDiffusion`. It compares
the three shapes Apple's package actually ships: a single `main`; one asset with
`image_encode` / `text_encode` / `detect`; and a diffusion directory containing independently loaded
component assets. The guide follows each choice through structure probing, specialization options,
function residency, dummy-forward warmup, lazy unloading, and Core AI versus application-level caches.

> ⚠️ **Two performance traps look like successful inference.** The public segmentation facade runs
> `image_encode` again for every prompt, so it does not realize the advertised same-image reuse unless
> the app owns and caches the intermediate feature NDArray. Diffusion's lazy mode correctly releases
> each component after its stage, but repeated requests then reload those components; the specialization
> cache may survive while resident model/function state does not. Also: detector postprocessing turns
> malformed output shapes into an empty detection array, indistinguishable from a genuinely empty scene
> unless the app validates the asset ABI.

---

## Reading order

**Everyone starts at [7.1](references/01-runtime-and-ndarray.md)** — §1–§9 plus §13, the vocabulary the
other four assume; §13's error-handling ladder is a day-one need, not a post-mortem one. Skip §11–§12.

**Then branch by what you ship.** *Segmentation, object detection, or diffusion:* read
[7.5](references/05-non-llm-engines-bundles-warmup-and-caching.md) after 7.1, then use
[7.2](references/02-specialization-caching-and-aot.md) for the cache and AOT mechanics its engines do
not expose. *A one-function tensor model with no product facade:* go to 7.2 directly; §1–§7 and §17,
plus §13–§14 if the model is large enough to want AOT. *A language model you drive yourself:*
[7.3](references/03-states-and-pipelined-execution.md) next, in order — §1–§5 make it correct,
§6–§9 stop it wasting memory, §10–§12 make it fast — then
[7.2](references/02-specialization-caching-and-aot.md) when the stall shows up. *A language model behind
`LanguageModelSession`:* go **[7.4](references/04-bundles-engines-and-guided-decoding.md) directly after
7.1**, because `apple/coreai-models` implements most of 7.3 for you and the thing you must actually
decide — which engine, and therefore whether `@Generable` works — is §5.8 and §7.8.

**Read two out of order** — [7.3 §14](references/03-states-and-pipelined-execution.md#14-prefix-reuse-one-integer-assignment-101), because hybrid
architectures cannot do prefix reuse and that should reach you before you pick a checkpoint, and
[7.2 §14.1](references/02-specialization-caching-and-aot.md#141-️-aot-only-compiles-for-apple-intelligence-capable-devices), because AOT only produces artifacts for
Apple-Intelligence-capable devices. **Skippable:** [7.1 §11.3](references/01-runtime-and-ndarray.md#113-asynchronous-values-and-computestream) and
[7.3 §10–§13](references/03-states-and-pipelined-execution.md#10-pipelined-execution-encode-computestream-async-values) unless you hand-write a pipelined decode
loop; [7.4 §2.8](references/04-bundles-engines-and-guided-decoding.md#28-the-diffusion-bundle-three-resolution-mechanisms-in-one-directory) is superseded by 7.5 for anyone
who actually ships diffusion.

---

## What this part deliberately does not cover

- **Making the `.aimodel`.** `coreai-torch`, `torch.export`, op coverage, `dynamic_shapes`, the
  ANE-vs-GPU authoring rules: [Part 8](../part-08-coreai-pytorch-conversion/README.md) and
  [Part 10](../part-10-coreai-hardware-authoring-debugging/README.md). This part covers only the slice of authoring
  that produces a *state* (7.3 §3–§4), which you cannot debug from the Swift side alone.
- **Why `NDArray.ScalarType` has 35 cases** [^scalar-type-count] — compression, palettization, and whether your 4-bit export
  is any good: [Part 9](../part-09-coreai-compression-numerics/README.md). **The Debugger, the gauge and the
  Instruments template in depth:** [Part 10](../part-10-coreai-hardware-authoring-debugging/README.md); they
  appear here only as how you *see* a specialization event or a growing inference interval.
- **Authoring a `LanguageModel` conformance and choosing among the five conformers:**
  [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md) — `CoreAILanguageModel` is dissected in 7.4 §8 only
  where it differs from the worked examples there. Everything *in front of* the session — `@Generable`,
  `Tool`, streaming, the failure taxonomy — is [Part 2](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/README.md), and
  context management as a discipline is [Part 3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/README.md).
- **Background Assets delivery, first-run UX and OS-update re-specialization as operations** —
  [Part 15](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/README.md). **Measuring whether what you shipped is any good**, for
  which Apple's repo has no vision/audio/diffusion benchmark and no published quality number:
  [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md). **Migrating image preprocessing and box conventions from Core ML:**
  [Part 17 reference 05](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md); 7.5 owns
  the new runtime engine and lifecycle. **MLX**, which exposes logits
  trivially where Core AI's fast path does not: [Part 13](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/README.md). **Coming from Core ML
  or `coreai-torch` 0.4.x:** [Part 17](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/README.md).

---

## Sources for this part

Strongest first. **SDK module interfaces, read on disk** (captured 2026-07-29 from Xcode build `27A5228h`;
recaptured 2026-08-20 from beta 5 build `27A5237l`, macOS 27.0 SDK; stored in `notes/sdk-interfaces/`): `CoreAI` (umbrella),
`CoreAIDelegates` (the loading/caching/options surface and the re-exports), `CoreAIRuntime`
(1,428 lines), `CoreAIAsset`, and the empty-in-this-beta `CoreAICache`/`CoreAICommon`/
`CoreAICompiler` — the evidence class that finally closed the error-type gap and confirmed every
runtime signature in 7.1/7.2. **Apple source read on disk:** `apple/coreai-models` at commit `5ed9981` (2026-07-23) —
the three LLM engines and the VLM engine, `ModelStructure.swift` (the structure→compute-unit mapping, the
strongest guidance on `SpecializationOptions` anywhere), the bundle readers, `NDArray+Helpers.swift`,
`ImagePreprocessor.swift`, the two xgrammar wrappers, `CoreAILanguageModel.swift`, the four Python bundle
writers, `Package.swift`/`Package.resolved` and the agent skills in `skills/` — plus merged PRs **#62,
\#74, #89**, PR **#85** (**closed unmerged 2026-08-23**), issue **#5** (**closed completed
2026-09-02**), issue **#55** (**closed completed 2026-08-27; silent GPU fallback remained**), **#58, #112**,
each documenting a real failure; and
`apple/coreai-torch` v0.4.1 (`converter.py`, `_utils.py`, `tests/test_stateful.py`, the notebooks, and
the release note that gates 0.4.0 assets). **Apple documentation**, harvested 2026-07-27 via `sosumi.ai`
plus Apple's raw DocC JSON API (which preserves term lists and tables the Markdown mirrors drop): the
full **312-entry** symbol index, ~70 member pages beneath `aimodel`, `aimodelcache`,
`inferencefunction`, `ndarray`, `computestream` and `asseterror`, and the eight articles on integrating,
AOT-compiling, debugging, gauging and profiling. **WWDC26 transcripts:** 324 *"Meet Core AI"* and 326
*"Core AI app features"*, with 325 referenced once. **Community sources**, labelled as such at every
point of use and never presented as Apple figures: `john-rocky`'s Core AI model zoo and fork (the
194-second cold load, the AOT A/B, the `expectFrequentReshapes` SIGSEGV, the MPSGraph KV-write isolation,
the prefix-reuse speedups — single-author, beta-era, self-declared uncontrolled conditions),
`frozen Noema 3.5 snapshot` (the copy-on-write trap, shape bucketing, host-cache detection),
`1amageek/swift-lm` and `lucasnewman/mlx2coreai` (two independent integrations corroborating the LLM
state contract), and `ml-explore/mlx-swift-lm` for the xgrammar namespace-collision comment. **Apple
published no latency figure for anything in this part** beyond one ~800 ms screenshot.

[^scalar-type-count]: Apple’s current `NDArray.ScalarType` reference enumerates the 35 cases summarized
    by this series: [Apple Developer — `NDArray.ScalarType`](https://developer.apple.com/documentation/coreai/ndarray/scalartype-swift.enum).
