# Part 10 — Core AI: hardware authoring, debugging, and LLM deployment

**Version floor:** everything here is **27.0 and only 27.0**. `apple/coreai-models` pins
`platforms: [.macOS("27.0"), .iOS("27.0")]` and requires **Xcode 27.0+**; the Python side is
`coreai-core==1.0.0b2` (a *beta* wheel), `coreai-torch==0.4.1`, `coreai-opt==0.2.1`, a pinned
`torch==2.9.0` and Python 3.11 in a `uv` ≥ 0.9.0 workspace. **Core AI Debugger is a separate download**
with its own floor — host **macOS 27+**, paired devices iOS/iPadOS/macOS 27+ (no visionOS, tvOS or
watchOS). Nothing back-deploys, and anything describing "iOS 20", "macOS 17", `.coreaimodel` or a
`coreai-torch convert` CLI is fabricated.

**Who this is for:** Python ML engineers *producing* a Core AI asset rather than consuming one —
re-authoring a model for a specific compute unit, diagnosing why the converted one is wrong or slow,
and shipping an LLM bundle a Swift app can load. If you only want to *call* a Core AI model behind
`LanguageModelSession`, that is [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md) and
[Part 7](../part-07-coreai-swift-runtime/README.md) — this part is upstream of both.

---

## ⚠️ Read this before you trust a signature anywhere in this part

**Core AI ships with zero Apple sample-code projects.** Verified this cycle: **0 `sampleCode` entries
across all 312 indexed Core AI symbols**, and `developer.apple.com/documentation/updates/coreai`
returns **404**. Unlike Parts 1–6 — each backed by a compiling first-party Xcode project you can diff
against — there is no such artifact here, for any of it.

So these guides rest on a different evidence ladder, stated at every claim: **shipped repo source read
on disk**, cited `path:line`; **Apple's own agent skills** inside those repos — 952 lines of empirical,
unhedged rules written by Apple engineers *for coding agents* (`neural_engine_rules.md` 479 lines,
`gpu_rules.md` 297, `common_issues.md` 176); **Apple documentation articles**; and **WWDC26 transcripts
324, 325, 326** — spoken narration, **contradicted by the shipped code in eight recorded places**. The
consequence: signatures here are **🟡 RECONSTRUCTED more often than in Parts 1–6**, and where they are,
the box says what is unknown, what would resolve it, and what to do meanwhile. Nothing is guessed
inside a 🔴 GAP.

---

## Why this part exists

Parts 8 and 9 teach you to convert and to compress. This part is the three things that decide whether
the result is any good, none of them conversion problems:

1. **The compute unit is an architectural decision made before you write the first `nn.Module`.**
   The Neural Engine ruleset and the GPU ruleset are not two dialects of one style — they are, in a
   surprising number of places, *exact opposites*: opposite tensor layouts, projection layers,
   attention implementations, mask orientations, sentinel values, tolerance for float32. A model
   authored for one does not run "a bit slower" on the other; it segments, falls back, and loses more
   than it ever gained.
2. **Almost every defect here converts cleanly and produces plausible output.** A transposed causal
   mask is 15–30 dB worse and still generates fluent text. A pre-RoPE key in the cache passes a
   single-token smoke test and collapses at position 2. A dropped `remove_functionalization` runs at
   full speed with a KV cache that never updates. No exception path for any of it.
3. **If you adopt Apple's optional `coreai-models` loader, function names select that helper's
   compute-unit preference.** It recognizes `extend*` + `load_embeddings`, the
   `image_encode`/`text_encode`/`detect` trio, and a lone `main`. This is package policy, not Core AI
   framework routing: direct `AIModel` callers provide their own `SpecializationOptions`, and
   `.default` lets Core AI choose the compute-unit combination that minimizes latency.
   [^sample-routing-policy]

Underneath all three: **the fastest local engine never exposes logits.** A GPU-pipelined bundle
samples on-GPU, so `@Generable` and `forcedContinuation` are *structurally* unavailable exactly where
the throughput numbers came from.

---

## Read this first: the triage table

| If your situation is… | Read | Why |
|---|---|---|
| "I am about to re-author a model and don't know which compute unit to target" | [10.1 §1–§3](references/01-ane-vs-gpu-authoring-rules.md#1-two-rulesets-not-two-styles) | The two rulesets side by side, plus Apple's own decision tables and memory budgets |
| "My ANE model runs correctly but the phone is hot" | [10.1 §4.16](references/01-ane-vs-gpu-authoring-rules.md#416-residency-is-the-rule-the-other-rules-serve) | Residency. One fp32 literal in a norm is 56 accelerator transitions per forward pass |
| "Fine at token 1, degraded by token 64" | [10.1 §4.13](references/01-ane-vs-gpu-authoring-rules.md#413-the-read-only-kv-cache) | You cached the pre-RoPE key. Apple marks this **CRITICAL**, and nowhere else |
| "I re-authored for the ANE and it still runs on the GPU" | [10.1 §8](references/01-ane-vs-gpu-authoring-rules.md#8-how-the-optional-coreai-models-helper-chooses-a-compute-unit-preference) · [§4.1](references/01-ane-vs-gpu-authoring-rules.md#41-max-tensor-rank-is-5) | Entrypoint names, or `enable_per_channel_scale=True` and its rank-6 LUTs |
| "Each inference is slower than the last" | [10.2 §4](references/02-debugging-and-profiling.md#4-worked-trace-1--inference-intervals-that-grow) | The canonical before/after trace: no KV cache, fixed with Core AI states |
| "It runs, and the answer is wrong" | [10.2 §9–§11](references/02-debugging-and-profiling.md#9-save_intermediates-and-the-reference-run) | `save_intermediates`, sync points, and the SAM3 missing-flower diagnosis end to end |
| "It got worse after I compressed it" | [10.2 §11.5](references/02-debugging-and-profiling.md#115-the-diagnosis) · [§12.1](references/02-debugging-and-profiling.md#121-modelinspector--what-will-actually-be-compressed) | Sort by similarity, find a *module* pattern — then prove your exclusion regex matches anything |
| "It won't load at all, with an MLIR error" | [10.2 §15](references/02-debugging-and-profiling.md#15-️-provenance-the-coreai-torch-040-ir-location-incident) | Not numerics, not timing — asset **provenance**. Audit by the `producer` field |
| "I just want Qwen3 running today" | [10.3 §2](references/03-llm-export-end-to-end.md#2-the-easy-road-the-catalog-and-the-export-cli) | The catalog, the ten presets, and one `uv run coreai.llm.export` command |
| "Fluent locally, incoherent globally, drifts after ~10 tokens" | [10.3 §8.4](references/03-llm-export-end-to-end.md#84-️-silent-failure--omit-remove_functionalization-and-your-kv-writes-disappear) | The single most dangerous omission in the pipeline |
| "`@Generable` throws on my own Core AI model" | [10.3 §11.4](references/03-llm-export-end-to-end.md#114-️-the-gpu-pipelined-engine-cannot-do-guided-generation) | The pipelined engine has no logits. Not workaroundable at the call site |
| "`Expected 2 states, got 4`" | [10.3 §13](references/03-llm-export-end-to-end.md#13-the-hybrid--ssm-wall) | The hybrid/SSM wall — and why those models forfeit prefix caching permanently |

---

## The guides in this part

### [10.1 — Authoring for the Neural Engine and for the GPU: two opposite rulesets](references/01-ane-vs-gpu-authoring-rules.md)

Apple's at-a-glance comparison table reproduced in full and unpacked row by row: on the ANE, rank ≤ 5,
fp16 with **no Python float literals anywhere**, the 64-byte alignment rule, BC1S layout,
`nn.Conv2d(kernel_size=1)` instead of `nn.Linear`, the transpose pair bracketing every projection,
per-head attention with **no fused SDPA**, `-40000.0` instead of `-inf`, precomputed RoPE, the
read-only KV cache; on the GPU, standard layout, fused QKV, native fused SDPA, `up_proj` before
`gate_proj`, the stateful export wrapper, MoE via `SwitchLinear` / `GatherMM`. Then Apple's workflow
("run code, don't read code"), the four PSNR gates (**> 70 / > 70 / ≥ 40 / ≥ 35 dB**) read as a
*ladder* that attributes a failure to your code, your layout, your conversion or your compression, and
the SAM3 case study, whose shipped recipe is **asymmetric** (image w4/gs32, text w6/gs8, detector
uncompressed).

> ⚠️ **SILENT FAILURE — entrypoint names are load-bearing when you use the optional
> `coreai-models` loader (§8).** Its `ModelStructure.swift` derives `SpecializationOptions` from the
> function names in the asset. Name a re-authored segmenter’s three entrypoints `encode_image` /
> `encode_text` / `predict` and that helper classifies it `.dynamic` and requests the **GPU**. Direct
> `AIModel` callers are not subject to this naming policy and may use `.default` or explicit
> options.[^sample-routing-policy]
>
> ⚠️ **SILENT FAILURE (three more).** `enable_per_channel_scale=True` lowers to `mps.dequantize_lut`
> with **rank-6 LUTs the ANE rejects**, so the model falls back to the GPU at GPU power draw with
> correct numbers — Apple's SAM3 recipe disables it on purpose and WWDC 325 says the opposite. Caching
> the **pre-RoPE** key is marked *CRITICAL* by Apple and collapses PSNR to ~20 dB, only after token 1.
> In the `coreai-models` Python bridge, handing a non-contiguous PyTorch tensor to its `NDArray`
> wrapper can produce wrong logits because that bridge reads the backing memory as contiguous. This
> is not a universal Core AI rule: Swift `NDArray` exposes explicit strides and preferred layouts.
> §10 catalogues eighteen failures with detection recipes.[^stride-scope]
>
> 🔴 **GAP — `coreai-build`'s residency report. Narrowed 2026-07-31.** Apple's skill says "compile
> and check residency" and no source shows what that output looks like — not the format, not whether
> it is per-op. It **can** now be checked: `coreai-build` turned out to ship in the optional **Metal
> Toolchain component** (`xcodebuild -downloadComponent MetalToolchain`), not Xcode-beta.app — the
> 2026-07-29 "absent" finding was a bare-install artifact — and its captured `--help`
> (`notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`) shows the likely surface:
> **`coreai-build inspect --compute`** (*"Show compute types"*, off by default), plus `--ops` for
> operation distribution. What that output looks like on a real asset is still uncaptured. Also
> open: `HardwareConstraints` / `AllocationType`, and `LegalizeToCoreOptions(mutable_arg_action:)`
> — prescribed by a skill file, present in **zero** other files across three Apple repos.

### [10.2 — The debug gauge, the Core AI Instrument, and the Core AI Debugger](references/02-debugging-and-profiling.md)

Three tools at three levels — *is anything happening* (gauge, free), *where is the time going and on
which compute unit* (Instruments, one run), *which operation produces the wrong numbers and which
Python line wrote it* (Debugger, a download plus a specialization) — built around the three diagnoses
Apple demonstrated: widening inference intervals → no KV cache → Core AI **states**; a load event with
a large specialization sub-event inside an interactive flow → a first-run experience and AOT
compilation; SAM3's missing occluded flower → sort sync points by similarity, notice they all belong to
the **detector decoder**, cross that with "the detector is 4 % of parameters", exclude it with `None`.
Also `coreai-opt`'s pre-conversion surface (`ModelInspector`, per-tensor activation SNR) and
`coreai_torch.debugging`, which runs the same jobs in CI with no GUI and no paired device.

> ⚠️ **SILENT FAILURE — the gauge you never see.** It only appears in projects that **directly link**
> `CoreAI.framework`, and almost every real adoption links it transitively through a Swift package: the
> Debug navigator simply has no row, nothing is logged, and the absence reads identically to "my model
> never ran". Equally invisible: the **More** menu's hand-off items are *not retroactive* — open the
> report page as step one of a session, before you reproduce anything.
>
> ⚠️ **SILENT FAILURE — colour intuition does not transfer between the two tools.** The gauge has
> three event types; the Instruments template has four (it adds **Setup**) — and two of the shared
> three have **swapped colours**: Load is green in the gauge and **cyan** in Instruments;
> Specialization is orange in the gauge and **green** in Instruments. Both mappings are quoted verbatim
> from Apple's own articles. Read the category name in the event label, never the colour.
>
> ⚠️ **SILENT FAILURE (three more).** An all-green sync-point board can coexist with a model that
> generates **different text** (§10.6) — sync points are one forward pass, a decoder is a loop, and an
> error inside the "≥ 40 dB" bar can flip one `argmax` at step 12; add a greedy token-exact gate. A
> `RELEASE`-mode conversion silently loses the **Source Viewer** while three of four panes keep
> working. And `ModelInspector` op names differ between graph and eager mode, so an exclusion regex
> tuned in the wrong mode matches zero ops.
>
> 🔴 **GAP — nobody in this corpus has run Xcode 27's Instruments or the Debugger by hand.** What
> exists (four instruments, four event categories, a three-level track hierarchy, five similarity
> metrics with PSNR the default) is documented and verified; what the strings look like on screen is
> not. §15 closes with the `coreai-torch` **0.4.0 IR-location incident** — a whole generation of assets
> stopped loading on beta 2+, wheel-pinning could not help because the gate was OS-side, and
> `coreai-build inspect` read the broken assets perfectly, *which made it look recoverable. It wasn't.*

### [10.3 — From a Hugging Face checkpoint to a loadable LLM bundle](references/03-llm-export-end-to-end.md)

The capstone: one continuous path from `Qwen/Qwen3-0.6B` to `try await session.respond(to:)`, in ten
stages, each with its gates and failure modes. It opens with the **easy road** — a 22-family catalog, a
discovery CLI, ten LLM presets, one `uv run coreai.llm.export` command that skips stages 2–8 — then
walks the hard road as **two divergent targets from one checkpoint**: macOS/GPU (dynamic shapes, one
`main`, `keyCache`/`valueCache`) and iOS/ANE (four entrypoints, static-shape grids,
`key_cache`/`value_cache`, uint16 positions). Then the oracle-first discipline and the two gate ladders
that measure different failures (Apple's PSNR vs the community's per-token cosine and greedy
token-exactness), the compression split, `state_names`, AOT per architecture with the `metadata.json`
edit everyone forgets, the three Swift engines, the hybrid/SSM wall, and the `mlx2coreai` bridge.

> ⚠️ **SILENT FAILURE — omit `remove_functionalization(ep)` and your KV writes disappear (§8.4).** If
> you take one warning from this part, take this one. The model converts, the asset loads, inference
> runs at full speed and the cache never updates — generation is locally fluent, globally incoherent,
> and looks *exactly* like a bad quantisation recipe. Only per-step token exactness catches it.
>
> ⚠️ **SILENT FAILURE (four more).** `CoreAISequentialEngine` reads inputs, states and outputs
> **positionally** and the converter "cannot detect silent reordering", so a swapped `state_names`
> tuple gives you fluent nonsense. Per-block and per-grouped-channel compression **silently skip**
> layers whose dimension isn't divisible, leaving an artifact *larger and better* than configured — the
> direction of error nobody checks. A bundle missing `chat_template.jinja` makes the runner **fall back
> to raw completion with no warning**. And `kvCacheStrategy: .chunked` is accepted, falls back to
> `StaticKVCache`, and gives you `.fixedSize` under a different name.
>
> ⚠️ **The GPU-pipelined engine cannot do guided generation (§11.4).** It throws on `includeLogits` and
> `forcedContinuation`, so `@Generable` *and* MMLU-style evaluation are unavailable on the fastest local
> path. Pick `variant: "coreai-sequential"` (or a chunked-static ANE bundle) and pay the throughput.
>
> 🔴 **GAP — nine declared, each with a safe default.** The set of valid `--architecture` codes is
> now **enumerated** — 24 codes, `h11p…h18p`, probed 2026-07-31 against the shipped `coreai-build`
> 3600.79.1 (`notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`; the code→device mapping, e.g.
> `h18p` = iPhone 17 Pro, `h16c` = M4 Max, is still community-measured only) — and **`coreai-build
> compile` exits 0 for any accepted architecture**, so only a device load validates the choice. The
> wrapper itself turned out to ship in the **Metal Toolchain component**, not Xcode-beta.app
> (resolved 2026-07-31; 10.3 §10.2 has the details). Whether AOT is strictly required on iOS is unresolved —
> compile everything you ship. Also open: the `.aimodel`'s inner `metadata.json` schema, and what
> `COREAI_QUERY_BUCKET_SIZE` does. Two former gaps closed against the captured macOS 27.0 beta SDK
> interface: `SpecializationOptions` is available on iOS (10.1 §8.1), and the runtime
> cache/specialize API narrated in WWDC 324 is spelled exactly as transcribed (10.3 §10.1).

---

## Reading order

**Authoring anything starts at [10.1](references/01-ane-vs-gpu-authoring-rules.md), §3 and §8 before
you write code** — §3 because the compute unit is an architectural decision, §8 because the mechanism
that delivers it is the function names in your asset, which is not where anyone looks. §4 and §5 are
per-primitive references; §7 (the gate ladder) and §11.2–§11.3 (the checklists) are what you return
to.

**Exporting an LLM: go to [10.3](references/03-llm-export-end-to-end.md) and read §2 first** — for ten
popular checkpoints the whole hard road is one command. Otherwise read §3 (the two contracts) and §6
(the oracle and the gates) *before* stage 1, because a port without gates is a guess with extra steps;
then §8.4 before your first export and §10 before your first device build.

**[10.2](references/02-debugging-and-profiling.md) is the one to read *ahead of need*, not when you
are stuck.** Three of its silent failures are things you must have done *before* the bug appears: link
`CoreAI.framework` directly, convert a DEBUG asset alongside the RELEASE one, and export
`USE_LOCAL_COREAI=1` / `ENABLE_DEBUG_INFO=1` in the shell you convert from. Its §14 playbook ("it is
slow" / "it is wrong") is the fastest entry point once something *is* wrong; §13 is worth a pass early
if you own CI. **Skippable:** §12 unless you are compressing; §15 unless you inherited assets of
unknown provenance.

---

## What this part deliberately does not cover

- **Conversion mechanics** — `torch.export`, `TorchConverter`, decomposition tables, externalisation,
  composite ops, the `.aimodel` format: [Part 8](../part-08-coreai-pytorch-conversion/README.md). **Choosing a
  compression recipe** — `Quantizer` vs `KMeansPalettizer`, granularities, calibration, QAT:
  [Part 9](../part-09-coreai-compression-numerics/README.md). Guide 10.1 states only which compression *shapes*
  survive on which compute unit, because that is an authoring constraint.
- **The Swift runtime** — `AIModel`, `InferenceFunction`, `NDArray`, states, `SpecializationOptions`,
  `AIModelCache`: [Part 7](../part-07-coreai-swift-runtime/README.md); guide 10.3 §11 shows only the integration
  surface an exporter needs. **Custom Metal kernels:** [Part 11](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-11-metal-and-tensorops/README.md) —
  note that this is a **GPU-only lever**, which is why it is a row in guide 10.1's decision table
  rather than a technique in it.
- **Consuming a Core AI model behind `LanguageModelSession`**, including the capability and options
  mismatches you inherit: [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md). **MLX as a framework**
  rather than as a source checkpoint: [Parts 12](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/README.md) and
  [13](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/README.md); the `mlx2coreai` bridge in full and the reverse direction:
  [Part 14](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-14-bridges-between-stacks/README.md).
- **Foundation Models' own Instruments template:** [Part 5](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-05-prototyping-profiling-non-swift/README.md).
  **Whether the model you shipped is any good:** [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md). **Background Assets
  delivery and operating a shipped model:** [Part 15](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/README.md). **Moving a
  26-era project forward,** including the 0.4.0 producer audit:
  [Part 17](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/README.md).

---

## Sources for this part

Strongest first, and unusually skewed toward source because there is no alternative. **Apple repo
source read on disk:** `apple/coreai-models` at `5ed9981` (2026-07-23, BSD-3-Clause) — the
`primitives/ios/` and `primitives/macos/` libraries file by file, `models/ios/qwen3.py`,
`models/macos/qwen3_moe.py`, the re-authored SAM3 tree (2,124 lines), `export/*.py`,
`model_registry.py` (1,051 lines, in full), and the Swift side:
`CoreAIShared/Runtime/ModelStructure.swift` (the optional package’s function-name → preference
policy[^sample-routing-policy]), the four
`InferenceEngines/`, `Bundle/ModelBundle.swift`, `Tools/llm-runner`, `Tools/benchmark`;
`apple/coreai-torch` (`converter.py`, the whole `debugging/` module, `docs/api/*`,
`tests/test_stateful.py`, `tools/graphdiff`); `apple/coreai-optimization` (the `w4` preset verbatim,
the config-precedence docstring, `inspection/`, the GRAPH/EAGER table). **Apple's agent skills** —
`model-authoring/SKILL.md` plus its three reference files, `working-with-coreai` +
`references/guidance.md`, `model-compression-exploration`.
**Apple documentation, fetched 2026-07-27:** the seven `/documentation/coreai/` pages on inspecting,
the gauge, Instruments, the Debugger, reference-run validation, AOT compilation and specialization
caching, plus `developer.apple.com/core-ai-debugger/` — two of them carrying `termList` blocks the
standard mirror drops, recovered from raw DocC JSON and load-bearing here. **WWDC26 transcripts** 324,
325 and 326, the weakest Apple class: the guides record eight places where a transcript and the shipped
code disagree, and **the code wins every time**. **Community sources**, always labelled:
`john-rocky/coreai-model-zoo` and its `coreai-models` fork (single author, self-declared uncontrolled
benchmarks) supply nearly every device number, the AOT architecture names, the 0.4.0 incident
forensics, the hybrid/SSM patch and the `trimKVCache` measurements; `lucasnewman/mlx2coreai` (MIT) is
guide 10.3 §15. **Apple published no latency figure for any Core AI LLM path, and ships no benchmark
tool for any non-LLM model.**

[^sample-routing-policy]: The name classifier and preferences are implemented by the optional
    `apple/coreai-models` package in its pinned
    [`ModelStructure.swift`](https://github.com/apple/coreai-models/blob/5ed9981303b38d5a44aa6b45509bc4f6945029f5/swift/Sources/CoreAIShared/Runtime/ModelStructure.swift#L12-L218).
    Core AI’s `.default` behavior is documented separately in
    [Managing model specialization and caching](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/docs/Managing%20model%20specialization%20and%20caching.md).

[^stride-scope]: The bridge-specific warning comes from the pinned `coreai-models`
    [`common_issues.md`](https://github.com/apple/coreai-models/blob/5ed9981303b38d5a44aa6b45509bc4f6945029f5/skills/skills/model-authoring/references/common_issues.md#L95-L98);
    Core AI’s Swift API separately documents strided arrays:
    [Apple Developer — `NDArray`](https://developer.apple.com/documentation/coreai/ndarray).
