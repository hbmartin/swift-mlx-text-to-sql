---
name: apple-core-ai
description: "Build, convert, optimize, and debug Core AI 27 neural models using AIModel, NDArray, bundles, engines, guided decoding, specialization, caching, AOT compilation, coreai-torch conversion, custom Metal ops, quantization, palettization, pruning, and ANE/GPU profiling. Use for import CoreAI or .aimodel work; missing Metal compiler errors; unsupported conversion ops; Neural Engine fallback; slow compiled models; numeric drift; compression accuracy loss; or deciding what should remain in Core ML."
---

# Core AI: the 27-cycle inference runtime and its conversion pipeline

Part 7, Part 8, Part 9, Part 10 of an independent, evidence-backed guide series on Apple's 2026 on-device AI stack, covering the iOS/iPadOS/macOS/watchOS/visionOS/tvOS 27 and Xcode 27 generation. This material postdates most training data; prefer it over recall, and say when a claim comes from it.

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
| [7](references/part-07-coreai-swift-runtime/README.md) | everything here is **27.0 and only 27.0**. |
| [8](references/part-08-coreai-pytorch-conversion/README.md) | `coreai-torch` **0.4.1** (2026-07-06), which pins `coreai-core==1.0.0b2` *exactly*, requires **Python ≥ 3.11** and **torch ≥ 2.8.0** (validated to **2.13.0**; above that, a `UserWarning` and you are on your own). |
| [9](references/part-09-coreai-compression-numerics/README.md) | this part is almost entirely **host-side Python**. |
| [10](references/part-10-coreai-hardware-authoring-debugging/README.md) | everything here is **27.0 and only 27.0**. |

## Read these before you trust a signature

- **Part 7** — [Read this before you trust a signature in this part](references/part-07-coreai-swift-runtime/README.md#️-read-this-before-you-trust-a-signature-in-this-part)
- **Part 10** — [Read this before you trust a signature anywhere in this part](references/part-10-coreai-hardware-authoring-debugging/README.md#️-read-this-before-you-trust-a-signature-anywhere-in-this-part)

## Triage

A `N.M` label is a deep reference guide; look it up in `references/SECTION-MAPS.md` for its local file and section anchors.

**Part 7 — Core AI: the Swift runtime** ([all 12 rows](references/part-07-coreai-swift-runtime/README.md#read-this-first-the-triage-table))

| If your situation is… | Read | Why |
|---|---|---|
| "I have a `.aimodel` and want it running today" | [7.1 §0–§9](references/part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#0-orientation-the-pipeline-the-file-the-toolchain) | The whole object model; §14 is a runner you can paste |
| "What error type do I `catch`?" · "`contiguousElements` is `nil`" · "`shape.reduce` won't compile" | [7.1 §13, §7](references/part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md#13--the-error-type-answer-and-how-to-write-a-catch-block) | ✅ SDK-verified: untyped throws, `AssetError` only; preferred strides or interleave; `Span` is not a `Sequence` |
| "My first launch stalls for minutes" | [7.2 §1–§5](references/part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#1-what-specialization-actually-is) | Specialization. Gate on `model(for:options:)`, pre-specialize behind explanatory UI |
| "The stall came back after I was sure I'd paid it" | [7.2 §4, §6](references/part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#4-the-cache-key-and-how-to-double-your-disk-usage-by-accident) | The key is `(asset, options)` — or an OS update, which purges everything regardless of policy |

**Part 8 — Core AI: converting a model from PyTorch** ([all 14 rows](references/part-08-coreai-pytorch-conversion/README.md#read-this-first-the-triage-table))

| If your situation is… | Read | Why |
|---|---|---|
| "I have a working `nn.Module` and want an `.aimodel`" | [8.1 §1–§7](references/part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#1-the-five-lines-and-what-each-one-is-for) | The five lines, what each owns, and the IO contract that becomes your Swift call site |
| "My assets stopped loading on a newer beta" | [8.1 §2.3](references/part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#23-️-the-version-gate-that-invalidates-already-published-assets) | The 0.4.0 gate, plus the `strip_debug_info` recovery that does *not* need a reconvert |
| "My transformer converted fine and is slower than I expected" | [8.1 §4.4](references/part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#44-️-silent-failure--using-pytorchs-default-table-instead-of-apples) | You probably passed PyTorch's default decomposition table; SDPA decomposed into six supported ops and the fast path vanished |
| "The numbers are wrong and nothing threw" | [8.1 §6.4](references/part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#64-️-silent-failure--optimize-is-not-always-semantics-preserving) → [§11.4](references/part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md#114-️-the-optimizetrue--optimizefalse-gate) | The `optimize()` miscompile, then the A/B gate that catches it and its whole family |

**Part 9 — Core AI: compression and numeric formats** ([all 15 rows](references/part-09-coreai-compression-numerics/README.md#read-this-first-the-triage-table))

| If your situation is… | Read | Why |
|---|---|---|
| "I just need something smaller, today" | [9.1 §3](references/part-09-coreai-compression-numerics/references/01-quantization.md#3-presets-the-one-liners-and-what-they-expand-to) | `presets.w4()` / `w8()`, and the eleven fields each one silently sets |
| "My compressed model is bigger than the arithmetic says" | [9.1 §7.5](references/part-09-coreai-compression-numerics/references/01-quantization.md#75-️-silent-failure--a-block-size-your-weight-isnt-divisible-by-leaves-the-layer-uncompressed) · [9.3 §2.7](references/part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md#27-️-silent-failure--a-block-size-your-weight-doesnt-divide-by-leaves-the-layer-at-full-precision) | The block-divisibility silent skip. The single most common defect in this part |
| "My model won't `torch.export`" | [9.1 §8.4](references/part-09-coreai-compression-numerics/references/01-quantization.md#84-which-mode-actually) | EAGER mode — and the non-obvious externalization reason for choosing it |
| "I need to quantize activations, not just weights" | [9.1 §8–§9](references/part-09-coreai-compression-numerics/references/01-quantization.md#8-graph-vs-eager-a-structural-split-not-a-flag) | GRAPH mode, observers, calibration, and the six ops whose qscheme is overridden behind your back |

**Part 10 — Core AI: hardware authoring, debugging, and LLM deployment** ([all 12 rows](references/part-10-coreai-hardware-authoring-debugging/README.md#read-this-first-the-triage-table))

| If your situation is… | Read | Why |
|---|---|---|
| "I am about to re-author a model and don't know which compute unit to target" | [10.1 §1–§3](references/part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md#1-two-rulesets-not-two-styles) | The two rulesets side by side, plus Apple's own decision tables and memory budgets |
| "My ANE model runs correctly but the phone is hot" | [10.1 §4.16](references/part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md#416-residency-is-the-rule-the-other-rules-serve) | Residency. One fp32 literal in a norm is 56 accelerator transitions per forward pass |
| "Fine at token 1, degraded by token 64" | [10.1 §4.13](references/part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md#413-the-read-only-kv-cache) | You cached the pre-RoPE key. Apple marks this **CRITICAL**, and nowhere else |
| "I re-authored for the ANE and it still runs on the GPU" | [10.1 §8](references/part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md#8-how-the-optional-coreai-models-helper-chooses-a-compute-unit-preference) · [§4.1](references/part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md#41-max-tensor-rank-is-5) | Entrypoint names, or `enable_per_channel_scale=True` and its rank-6 LUTs |

## The deep reference guides

Bundled locally. `references/SECTION-MAPS.md` has every top-level section anchor.

- **[7.1 `AIModel`, `InferenceFunction`, `NDArray`, and the memory model](references/part-07-coreai-swift-runtime/references/01-runtime-and-ndarray.md)** — The object-model primer every other guide assumes, built around the structural fact that makes app architecture fall out: **`AIModel` owns nothing and pins a cache entry; `InferenceFunction` owns the weights**, so "when does this cost me a gigabyte?" is answered *at `loadFunction`, not at `init`*.
- **[7.2 Specialization, the model cache, and ahead-of-time compilation](references/part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md)** — The single largest source of first-launch stalls, wedged loads and mysterious disk growth.
- **[7.3 States as KV cache, and pipelined execution](references/part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md)** — A decode loop written the naive way gets slower every step, and in Instruments it is unmistakable: **inference intervals that visibly widen along the timeline**.
- **[7.4 Model bundles, the LLM engines, and grammar-constrained decoding](references/part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md)** — The layer above the runtime, where a raw `.aimodel` becomes something shippable and Apple's own Swift package turns "I have a converted Qwen3" into `LanguageModelSession(model:)`.
- **[7.5 Non-LLM engines: bundles, function structure, warmup, specialization, and caching](references/part-07-coreai-swift-runtime/references/05-non-llm-engines-bundles-warmup-and-caching.md)** — The runtime owner for `CoreAISegmentation`, `CoreAIObjectDetection`, and `CoreAIDiffusion`.
- **[8.1 `torch.export` to `.aimodel`, and the IO / state / dynamic-shape contract](references/part-08-coreai-pytorch-conversion/references/01-conversion-and-the-io-contract.md)** — The pipeline end to end as a series of contracts rather than a recipe: the decomposition table and exactly which twelve ops it preserves (Apple's README says three — a subset); the two input forms and why only `add_pytorch_module` can externalize; `to_coreai()` as pure conversion versus `optimize()` as where the passes run; the IO contract as your caller's API; `dynamic_shapes` and the SymInt …
- **[8.2 When an op will not convert: coverage, composite ops, custom lowerings, externalization](references/part-08-coreai-pytorch-conversion/references/02-op-coverage-composites-and-externalization.md)** — The debugging guide for conversion failures — and, more usefully, for **conversions that succeed and should not have**.
- **[8.3 `TorchMetalKernel`: writing and embedding a custom Metal kernel](references/part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md)** — The seam, not the shader: how a kernel you already know how to write gets into an `.aimodel`.
- **[9.1 `coreai-opt` quantization: configs, GRAPH vs EAGER, calibration and QAT](references/part-09-coreai-compression-numerics/references/01-quantization.md)** — The foundation guide, and the one everything else assumes.
- **[9.2 Palettization, pruning, joint compression, and mixed precision](references/part-09-coreai-compression-numerics/references/02-palettization-pruning-and-joint.md)** — The other three things `coreai-opt` does, plus the two ways of combining them.
- **[9.3 int4 to MX: which layer supports which numeric format](references/part-09-coreai-compression-numerics/references/03-numeric-formats-across-the-stack.md)** — A reference rather than a tutorial, answering one question in as many tables as it takes: for a given format — int4, FP8 E4M3, FP4 E2M1, MXFP4, a 6-bit palette, E8M0 block scales — which layer can **emit** it, which can **store** it, and which can actually **compute** on it.
- **[10.1 Authoring for the Neural Engine and for the GPU: two opposite rulesets](references/part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md)** — Apple's at-a-glance comparison table reproduced in full and unpacked row by row: on the ANE, rank ≤ 5, fp16 with **no Python float literals anywhere**, the 64-byte alignment rule, BC1S layout, `nn.Conv2d(kernel_size=1)` instead of `nn.Linear`, the transpose pair bracketing every projection, per-head attention with **no fused SDPA**, `-40000.0` instead of `-inf`, precomputed RoPE, the read-only KV …
- **[10.2 The debug gauge, the Core AI Instrument, and the Core AI Debugger](references/part-10-coreai-hardware-authoring-debugging/references/02-debugging-and-profiling.md)** — Three tools at three levels — *is anything happening* (gauge, free), *where is the time going and on which compute unit* (Instruments, one run), *which operation produces the wrong numbers and which Python line wrote it* (Debugger, a download plus a specialization) — built around the three diagnoses Apple demonstrated: widening inference intervals → no KV cache → Core AI **states**; a load event …
- **[10.3 From a Hugging Face checkpoint to a loadable LLM bundle](references/part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md)** — The capstone: one continuous path from `Qwen/Qwen3-0.6B` to `try await session.respond(to:)`, in ten stages, each with its gates and failure modes.

Search the local guide first, then open only the section needed for the answer. Preserve its evidence marker and citation when carrying a claim into code or prose.

## Related skills

Adjacent parts of the series live in these sibling skills: `apple-on-device-ai`, `apple-metal-tensorops`, `apple-ai-migration`, `apple-ai-shipping`.
