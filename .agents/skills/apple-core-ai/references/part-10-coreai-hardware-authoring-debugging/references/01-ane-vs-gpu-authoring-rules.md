# Authoring for the Neural Engine and for the GPU: two opposite rulesets

**Part 10 · Core AI: hardware authoring, debugging, LLM deployment · Reference 01**

**Version floor:** everything in this guide targets **iOS 27.0 and macOS 27.0**, built with
**Xcode 27.0**. That is not a recommendation, it is the floor declared by the toolchain itself:
`apple/coreai-models` `Package.swift` pins `platforms: [.macOS("27.0"), .iOS("27.0")]` and the
repository README states *"macOS and iOS 27.0+ / Xcode 27.0+"* (✅ **VERIFIED** — local clone at
commit `5ed9981`, 2026-07-23). The Python side is equally specific and equally young:
`coreai-core==1.0.0b2` — a **beta** — plus `coreai-torch==0.4.1`, `coreai-opt==0.2.1`,
`torch==2.9.0`, Python `>=3.11` (✅ **VERIFIED** — `python/pyproject.toml:28-43`, corroborated by
`uv.lock`). There is no back-deployment story here. None of this exists on iOS 26 or macOS 26, and
anything you read describing "iOS 20" or "macOS 17" in a Core AI context is fabricated.

---

## What this covers

Most guides about on-device model conversion tell you how to make a model *run*. This one is about
the decision you make **before** you write the first `nn.Module`: which compute unit the model is
for. Because the authoring rules for Apple's Neural Engine and the authoring rules for Apple's GPU
are not two dialects of one style. They are, in a surprising number of places, **exact opposites** —
opposite tensor layouts, opposite projection layers, opposite attention implementations, opposite
positions in the shape/dynamism trade-off, opposite tolerances for float32. A model authored for one
does not "run a bit slower" on the other. It usually falls off it entirely and lands on the CPU,
where it is ten to a hundred times slower than either.

What follows:

- **Apple's own at-a-glance comparison table**, reproduced in full, then unpacked row by row.
- **The Neural Engine rules in detail** — rank ≤ 5, fp16-only, the 64-byte alignment rule that
  costs 32× memory when you get it wrong, BC1S layout, `nn.Conv2d(kernel_size=1)` in place of
  `nn.Linear`, the transpose bookkeeping that surrounds every projection, per-head attention,
  `-40000.0` instead of `-inf`, the read-only KV cache, and the residency constraint that governs
  all of it.
- **The GPU rules** — standard layouts, fused QKV, native fused SDPA, the stateful KV cache export
  wrapper, MoE via `GatherMM`/`SwitchLinear`, memory-efficient weight loading.
- **Apple's prescribed workflow and its numeric acceptance gates** — architecture discovery by
  running code rather than reading it, bottom-up authoring order, and the four PSNR thresholds
  (>70 dB, >70 dB, ≥40 dB, ≥35 dB) that decide whether your re-authored model is correct.
- **The optional `coreai-models` helper's compute-unit policy** — its loader derives a preference
  from the *shape of the function table inside the asset*. Direct `AIModel` callers instead choose
  their own `SpecializationOptions`.[^sample-routing-policy]
- **The SAM3 case study**: three functions, asymmetric palettisation, and 1008 → 336 pixels.
- **A consolidated silent-failure catalogue.** Nearly every defect in this domain compiles cleanly,
  converts cleanly, produces plausible-looking output, and is 30 dB worse than it should be.

## What this does *not* cover

- **How to convert and compile** — `torch.export`, `TorchConverter`, `coreai-build`, specialisation
  and the `.aimodel` format are Part 8.
- **How to choose a compression recipe** — quantisation vs palettisation, group sizes, calibration
  and QAT are Part 9. This guide only tells you which compression *shapes* survive on which compute
  unit, because that is an authoring constraint.
- **The Swift runtime** — `AIModel`, `InferenceFunction`, `NDArray`, states — is Part 7.
- **Writing custom Metal kernels** is Part 11. Note in advance that this is a GPU-only lever: there
  is no mechanism for injecting a hand-written kernel into a Neural Engine graph.

## What you need

- A local clone of **`apple/coreai-models`**. Not optional. It is the reference implementation, and
  it carries Apple's agent skills, which are the primary source for this guide:
  `git clone https://github.com/apple/coreai-models`.
- **`uv`** (`brew install uv`) — every command in Apple's own docs is `uv run …`.
- A Mac on macOS 27 with Xcode 27 for anything you intend to measure. Numbers taken on a
  simulator or on 26.x are not evidence.

---

## ⚠️ A word about evidence, because this framework has none of the usual kind

Every other part of this series can lean on a compiling Apple sample project. Core AI cannot.

> 🔴 **GAP — Core AI ships zero Apple sample-code projects.**
> Verified this session: **0 `sampleCode` entries across all 312 indexed Core AI symbols**, and
> `developer.apple.com/documentation/updates/coreai` returns 404. There is no first-party
> downloadable Xcode project for Core AI, unlike Foundation Models (three), Evaluations (one) or
> App Intents. **What would resolve it:** Apple publishing a sample under
> `/documentation/coreai`, discoverable via `developer.apple.com/tutorials/data/index/coreai`
> filtered on `type == "sampleCode"`.
> **Safe default meanwhile:** treat the `apple/coreai-models` repository as the sample project. It
> is BSD-3-Clause, it is complete, it is written by the Core AI team, and every model in it is
> exercised by the repo's own test suite. That is what this guide does.

So the evidence ladder for *this* guide, strongest first:

1. **Source files in the shipped Apple repos on disk** (`apple/coreai-models`,
   `apple/coreai-torch`, `apple/coreai-optimization`). Cited as `path:line`.
2. **Apple's own agent skills inside `apple/coreai-models`.** These are unusual and unusually
   valuable: 952 lines of empirical, hard-won rules written by Apple's engineers *for coding agents*,
   with no marketing register and no hedging. `skills/skills/model-authoring/references/`
   contains `neural_engine_rules.md` (479 lines), `gpu_rules.md` (297) and `common_issues.md` (176).
   Almost every rule in this guide traces to one of those three files. They are quoted, not
   paraphrased, wherever the exact wording is load-bearing.
3. **Apple documentation articles** on `developer.apple.com/documentation/coreai`.
4. **WWDC26 session 325**, *"Dive into Core AI model authoring and optimization"* — the only session
   that covers re-authoring. Spoken narration; treated as weaker than the code, and it **disagrees
   with the shipped code in two places** which are flagged where they occur.
5. **Community repositories** — principally `john-rocky/coreai-model-zoo`. Genuinely valuable and
   frequently unique, but single-author with self-declared uncontrolled benchmarks. Always labelled
   *community-measured*, never presented as an Apple figure.

Signatures marked 🟡 **RECONSTRUCTED** are concepts that are attested but whose exact spelling
could not be confirmed against a file on disk. There are fewer of those here than in most guides in
this series, precisely because the repos are on disk — but there are some, and they are marked.

---

## Contents

1. [Two rulesets, not two styles](#1-two-rulesets-not-two-styles)
2. [Apple's own at-a-glance table](#2-apples-own-at-a-glance-table)
3. [Choosing the compute unit — before you write the model](#3-choosing-the-compute-unit--before-you-write-the-model)
4. [The Neural Engine rules](#4-the-neural-engine-rules)
   - [4.1 Max tensor rank is 5](#41-max-tensor-rank-is-5)
   - [4.2 fp16, int8, int16 — and nothing else](#42-fp16-int8-int16--and-nothing-else)
   - [4.3 The alignment rule: the last axis is width](#43-the-alignment-rule-the-last-axis-is-width)
   - [4.4 BC1S: the layout everything else follows from](#44-bc1s-the-layout-everything-else-follows-from)
   - [4.5 `nn.Conv2d(kernel_size=1)` instead of `nn.Linear`](#45-nnconv2dkernel_size1-instead-of-nnlinear)
   - [4.6 Transpose bookkeeping at every projection site](#46-transpose-bookkeeping-at-every-projection-site)
   - [4.7 Prefer high-level ops](#47-prefer-high-level-ops)
   - [4.8 Softmax on the channel dimension](#48-softmax-on-the-channel-dimension)
   - [4.9 Convolution geometry: strides, kernels, dilation, pooling](#49-convolution-geometry-strides-kernels-dilation-pooling)
   - [4.10 Per-head attention: there is no fused SDPA](#410-per-head-attention-there-is-no-fused-sdpa)
   - [4.11 The causal mask is transposed, and `-inf` is wrong](#411-the-causal-mask-is-transposed-and--inf-is-wrong)
   - [4.12 RoPE must be precomputed outside the graph](#412-rope-must-be-precomputed-outside-the-graph)
   - [4.13 The read-only KV cache](#413-the-read-only-kv-cache)
   - [4.14 Chunked prefill and fp16 drift](#414-chunked-prefill-and-fp16-drift)
   - [4.15 Embedding decomposition and the `(V, 1, D)` table](#415-embedding-decomposition-and-the-v-1-d-table)
   - [4.16 Residency is the rule the other rules serve](#416-residency-is-the-rule-the-other-rules-serve)
5. [The GPU rules](#5-the-gpu-rules)
   - [5.1 Standard layout, `nn.Linear`, fp32 where you need it](#51-standard-layout-nnlinear-fp32-where-you-need-it)
   - [5.2 Fused QKV, and fused QK-norm + RoPE](#52-fused-qkv-and-fused-qk-norm--rope)
   - [5.3 Native fused SDPA](#53-native-fused-sdpa)
   - [5.4 MLP operation ordering: up before gate](#54-mlp-operation-ordering-up-before-gate)
   - [5.5 RMSNorm variants](#55-rmsnorm-variants)
   - [5.6 The stateful KV cache export wrapper](#56-the-stateful-kv-cache-export-wrapper)
   - [5.7 MoE via `SwitchLinear` and `GatherMM`](#57-moe-via-switchlinear-and-gathermm)
   - [5.8 Memory-efficient weight loading](#58-memory-efficient-weight-loading)
   - [5.9 Masks and precomputed buffers](#59-masks-and-precomputed-buffers)
6. [Apple's authoring workflow](#6-apples-authoring-workflow)
7. [The verification gates](#7-the-verification-gates)
8. [How the optional `coreai-models` helper chooses a compute-unit preference](#8-how-the-optional-coreai-models-helper-chooses-a-compute-unit-preference)
9. [Case study: SAM3 re-authored for iPhone](#9-case-study-sam3-re-authored-for-iphone)
10. [The silent-failure catalogue](#10-the-silent-failure-catalogue)
11. [Quick reference](#11-quick-reference)
12. [Sources and evidence ledger](#12-sources-and-evidence-ledger)

---

## 1. Two rulesets, not two styles

Here is the same attention projection, written twice.

For the GPU:

```python
import torch.nn as nn

self.qkv_proj = nn.Linear(
    dim,
    n_heads * head_dim + 2 * n_kv_heads * head_dim,   # Q + K + V fused
    bias=False,
)
```

For the Neural Engine:

```python
import torch.nn as nn

self.q_proj = nn.Conv2d(dim, n_heads * head_dim, kernel_size=1, bias=False)
self.k_proj = nn.Conv2d(dim, n_kv_heads * head_dim, kernel_size=1, bias=False)
self.v_proj = nn.Conv2d(dim, n_kv_heads * head_dim, kernel_size=1, bias=False)
```

Both are ✅ **VERIFIED** verbatim from Apple: the first from
`skills/skills/model-authoring/references/gpu_rules.md:137-143`, the second from the shipped
iOS Qwen3 model at
`python/src/coreai_models/models/ios/qwen3.py:38-40`.

Look at what changed. The layer type changed. The number of layers changed — three separate
projections on the Neural Engine, one fused projection on the GPU. And because the layer type
changed, the *weights* changed shape, the *input tensor* changed layout, the *mask* changed
orientation, and the attention implementation underneath changed from one fused kernel call to a
Python `for` loop over heads.

This is the thesis of the guide, and it is worth stating bluntly before any of the details:

> **Choosing your target compute unit is an architectural decision, made before you write the model,
> and it propagates into every layer.** It is not a compiler flag you set at the end. A model
> authored for one compute unit and pointed at the other does not degrade gracefully; it segments,
> falls back, and loses more than it ever gained.

Apple's own framing of the same point, from the model-authoring skill
(✅ **VERIFIED** — `skills/skills/model-authoring/SKILL.md:33`):

> *"The plan uses 'optimize for energy efficiency' (BC1S, Conv2d, static shapes, fp16) and
> 'optimize for scalable performance' (standard layout, `nn.Linear`, dynamic shapes supported)."*

Note the vocabulary. Apple's guidance to its own agents is to talk about **outcomes** — energy
efficiency, scalable performance — and to name the accelerator only if the developer names it
first (`SKILL.md:42`: *"use outcome-oriented language in your responses — say 'optimized for
energy-efficient inference on iPhone' rather than 'targets Neural Engine'"*). That is good advice
for a product conversation and bad advice for a technical guide, so this guide names the hardware
throughout. Where Apple's files say "Neural Engine" this guide uses "Neural Engine" or the
long-standing abbreviation **ANE**; they are the same thing. (Apple's own skill files consistently
spell it out; `ANE` appears in the shipped Python as function suffixes like `gelu_ane` and
`window_partition_ane`, so both spellings are Apple's.)

### Why the rules diverge this hard

The short version: the Neural Engine is a fixed-function convolution machine with a rigid memory
model, and the GPU is a programmable SIMD machine with a flexible one.

- The Neural Engine's fundamental operation is **convolution**, so every matrix multiply is
  expressed as a 1×1 convolution and every tensor is laid out the way a convolution engine wants:
  channels-first, spatial dims explicit, width innermost.
- It reads and writes memory in **fixed-size blocks along the innermost axis**, so that axis's
  length is a first-class performance parameter — not a detail.
- It is a **fp16 machine**. There is no fp32 path; a float32 buffer anywhere in the graph is a
  reason to hand that subgraph to somebody else.
- It executes a **statically scheduled** graph, so shapes must be known at compile time.

The GPU has none of those constraints and a completely different bottleneck: it is bandwidth- and
occupancy-bound, so the wins come from *fusing* work (one big `nn.Linear` instead of three, one
fused SDPA kernel instead of a loop) and from keeping the shader cores busy with large tiles.

Every rule below is downstream of one of those two facts.

---

## 2. Apple's own at-a-glance table

This table is reproduced **verbatim** from Apple's model-authoring skill
(✅ **VERIFIED** — `skills/skills/model-authoring/SKILL.md:60-68`). It is the single most useful
artifact in the Core AI corpus, and the rest of section 4 and section 5 are an expansion of it.

| Aspect | Neural Engine | GPU |
| --- | --- | --- |
| Tensor layout | BC1S `(B, H*D, 1, S)` | Standard `(B, S, D)` |
| Projections | `nn.Conv2d(kernel_size=1)` | `nn.Linear` (fused QKV on GPU) |
| Embedding shape | `(V, 1, D)` — externalized | Standard `nn.Embedding` |
| Attention | Per-head sequential | Fused native SDPA |
| Float precision | fp16 only — no fp32 literals anywhere | fp16 weights, fp32 intermediates OK |
| Shapes | Fully static | Dynamic shapes supported |
| Weight conversion | `unsqueeze(-1).unsqueeze(-1)` for Conv2d | No reshape needed |

And the companion table of compute-unit characteristics
(✅ **VERIFIED** — `SKILL.md:48-52`):

| Compute unit | Strengths | Key authoring constraint |
| --- | --- | --- |
| **Neural Engine** | Energy-efficient, battery-friendly, static workloads | BC1S layout, fp16 only, static shapes, limited op set |
| **GPU** | High throughput, large models, flexible ops | Standard PyTorch layout, supports fp32 |
| **CPU** | Small models, low overhead, low latency, correctness testing, fallback | Runs all ops, good for validation |

Two things about the CPU row that matter more than they look. First, the CPU is not a
consolation prize in this workflow — it is the **reference implementation**. `gpu_rules.md` opens
by saying so (✅ **VERIFIED** — `gpu_rules.md:3`): *"The same authoring principles apply to both GPU
and CPU. GPU uses standard PyTorch tensor layouts; CPU is used for correctness testing before
compilation."* So there are really two rulesets, not three: **standard-layout** (GPU and CPU) and
**BC1S** (Neural Engine). Second, "runs all ops" is why an ANE-authored model that violates one of
the rules below does not crash. It silently ends up somewhere else. See §4.16.

### The KV cache split, verbatim

The third of Apple's own comparison tables, and the one people get wrong most often
(✅ **VERIFIED** — `SKILL.md:127-132`):

| Compute unit | Cache shape | Sequence dim | Pattern |
| --- | --- | --- | --- |
| **Neural Engine** | `[n_layers, B, H_kv*D, 1, max_S]` | dim 4 | Read-only functional I/O — model has no cache writes, returns new K/V tokens as outputs |
| **GPU** | `[n_layers, B, H_kv, max_S, D]` | dim 3 | Stateful export wrapper — `register_buffer` for KV, `hoistToArg` at compile |

Followed by a rule stated in bold in Apple's own file:

> **Key rule**: *"Do not use stateful transforms for token generation — state resets between
> inference calls. Use the readonly KV I/O pattern (Neural Engine) or the stateful export wrapper
> (GPU) instead."* (✅ **VERIFIED** — `SKILL.md:132`)

Notice that the two cache shapes are not merely different orderings. On the Neural Engine the
heads and the head dimension are **fused into one channel axis** (`H_kv*D`) and the sequence is
**last**; on the GPU they are separate axes and the sequence is second-to-last. That is BC1S again,
applied to the cache. §4.13 and §5.6 give the full patterns.

### Where Apple's shipped code refines the table

The at-a-glance table says the Neural Engine layout is BC1S `(B, H*D, 1, S)`. That is true inside
attention. It is **not** true everywhere in the shipped LLM models, and the difference will confuse
you the first time you read `qwen3.py`.

In `python/src/coreai_models/models/ios/qwen3.py` the tensor flowing *between* blocks is
`(B, S, 1, D)` — sequence second, hidden dimension **last**. Attention transposes into BC1S,
projects, and transposes back. You can read it in the shapes the primitives declare
(✅ **VERIFIED**):

- `primitives/ios/mlp.py:35` — `batch_size, query_len, _, dim = x.shape` → the MLP consumes
  `(B, S, 1, D)`.
- `primitives/ios/rms_norm.py:36` — docstring: *"Input tensor of shape (batch_size, seq_len, 1,
  dim)"*, and the reduction is `square.mean(-1, keepdim=True)` — over the **last** axis.
- `primitives/ios/sdpa.py:50-53` — docstring: query is
  `(batch_size, n_heads*head_dim, 1, seq_len)` → attention consumes **BC1S**.

Meanwhile the vision path is pure BC1S the whole way through:
`models/ios/sam3/image_encoder.py:6-11` says *"All intermediates in BC1S (B, C, 1, S) format"*, and
`primitives/ios/layer_norm.py:29` normalises over `dim=1` with affine parameters shaped
`(1, C, 1, 1)` — exactly what `neural_engine_rules.md:281` prescribes for RMSNorm.

So the accurate statement is:

> **BC1S is the layout for anything that looks like a convolution or an attention score matrix.
> Around it, the LLM path carries `(B, S, 1, D)` so that the hidden dimension — the big, nicely
> aligned one — sits on the innermost axis where the alignment rule (§4.3) wants it.**
> `x.transpose(-3, -1)` moves between the two forms and is its own inverse for 4-D tensors.

This is not a contradiction in Apple's material; it is the alignment rule and the convolution rule
pulling in different directions and being resolved per-tensor. But you have to know it, or the
`transpose(-3, -1)` calls scattered through `qwen3.py` look arbitrary.

---

## 3. Choosing the compute unit — before you write the model

Apple's skill gives its agents an explicit inference table for reading a developer's intent
(✅ **VERIFIED** — `SKILL.md:36-40`):

| User talks about… | Likely compute unit | Why |
| --- | --- | --- |
| Energy efficiency, battery life, iOS, iPhone, iPad, always-on | **Neural Engine** | Most energy-efficient compute unit |
| Max performance, throughput, macOS, large batches, flexibility | **GPU** | GPU excels at throughput and flexible workloads |
| Correctness testing, debugging, reference implementation | **CPU** | CPU runs everything, good for validation |

That is a decent first cut, but it encodes a folk model — "iOS ⇒ Neural Engine" — that the shipped
runtime does not actually implement. §8 covers the real mechanism. For now, here is the honest
version of the decision, drawn from the platform guidance Apple ships in the
`working-with-coreai` skill (✅ **VERIFIED** — `references/guidance.md:47-58`):

**iOS — optimise for energy efficiency:**

> - *"Static shaped inputs, outputs, and intermediate tensors wherever possible"*
> - *"Limited or no control flow or branching"*
> - *"Int8/Int4 linear quantized with per-channel granularity or 2/4/6/8 bit palettized weights with
>   per-tensor or per-group-channel granularity"*
> - *"Models with variable sequence lengths can be transformed and chunked into a collection of
>   multiple static shaped functions. In some cases a fixed max shape is required — for example,
>   picking a maximum context length and using it to set a fixed-size KV cache."*

**macOS — optimise for scale with available compute and memory:**

> - *"Models need not be restricted to static shapes and can have data dependencies and control flow"*
> - *"Int4 linear per-block quantization is recommended for weight compression"*

And the memory budgets, which are hard constraints rather than style advice
(✅ **VERIFIED** — `guidance.md:40-44`):

| Platform | Recommendation |
| --- | --- |
| iOS | *"Keep models under 2 GB"* |
| macOS | *"Leave at least 6 GB of RAM headroom for the system and other processes"* |

with the reason stated plainly (`guidance.md:25`): *"A model that consumes too much memory can
degrade system performance or be terminated by the OS. Choose model sizes that leave a reasonable
buffer for your app and the broader system. Use `os_proc_available_memory()` at runtime to query
available memory and make informed loading decisions."*

> ✅ **VERIFIED** — `os_proc_available_memory()` is the C function from `<os/proc.h>`, available
> since iOS 13, not a Core AI API. Apple's Core AI guidance simply reaches for it. It is the right
> call: on iOS the jetsam limit, not the physical RAM, is what kills you.

### The last row of the decision table

There is one more axis that neither of Apple's tables mentions and that decides the question
outright for some projects:

| Capability | Neural Engine | GPU |
| --- | --- | --- |
| Custom Metal kernels (`TorchMetalKernel`) | **No mechanism exists** | ✅ Part 11 |
| Dynamic / data-dependent shapes | ❌ | ✅ |
| fp32 accumulation you control | ❌ (only where the hardware does it for you) | ✅ |
| Energy per token | Best on Apple silicon | Higher |
| Peak throughput on a large model | Lower | Best |

The custom-kernel row is the sharpest. If your model needs an operation Core AI does not lower —
a novel attention variant, a fused MoE gather-matmul, an exotic quantisation scheme — then on the
GPU you can write it in Metal and inline it into the asset, and on the Neural Engine you cannot.
Community practice reflects this: the `coreai-model-zoo` maintainer's stated stance is
*"GPU now (custom kernels, beta-robust) + ANE later"* (**community-measured / community opinion** —
`knowledge/compute-units-and-authoring.md:138-143`, single-author repo, 2026-07).

### A note on what "re-authoring" actually means

WWDC26 session 325 is blunt about the size of the undertaking (**Apple, spoken narration**,
325:206-222):

> *"For more advanced optimizations, especially for iOS, you need to go further and **rewrite the
> entire model with a specific target in mind. We refer to this process as model re-authoring.**"*
>
> *"Re-authoring typically involves replacing many aspects of this computational graph. This may
> imply using **different operations, novel tensor layouts, and even modifying the interfaces of the
> model**. Essentially, this is a **completely different implementation of the source code**."*

"A completely different implementation of the source code" is the right expectation to set. The
re-authored SAM3 image encoder in `apple/coreai-models` is 410 lines of new PyTorch; the DETR
encoder/decoder is 670; the whole re-authored SAM3 is 2,124 lines
(✅ **VERIFIED** — `wc -l python/src/coreai_models/models/ios/sam3/**`). This is not a port. It is a
rewrite whose only contract with the original is *the same weights and the same outputs to within
70 dB*.

---

## 4. The Neural Engine rules

Everything in this section comes from
`skills/skills/model-authoring/references/neural_engine_rules.md` (479 lines) unless another source
is named, cross-checked against the shipped primitives in
`python/src/coreai_models/primitives/ios/` and the shipped models in
`python/src/coreai_models/models/ios/`.

The three headline constraints, stated by Apple at the top of the file
(✅ **VERIFIED** — `neural_engine_rules.md:7-9`):

> - ***Max tensor rank: 5.** Rank-6+ intermediates are rejected. If rank > 5, reshape to remove
>   unused dimensions (e.g., singleton dims of size 1) to bring rank to ≤ 5.*
> - ***Supported dtypes**: fp16, int8, int16. fp32 falls back to GPU/CPU.*
> - ***Fully static shapes**: Export one function per static shape config.*

### 4.1 Max tensor rank is 5

Rank-6 and above are **rejected**. Not slow — rejected. Any op whose output would be rank 6 causes
the graph to segment at that point.

This bites in exactly the places you would expect: window partitioning in a ViT, patch shuffling,
grouped/blocked reshapes, and anything that reshapes `(B, H, W, C)` into
`(B, H//ws, ws, W//ws, ws, C)`. The standard Hugging Face implementations of all of these use rank-6
intermediates because on a GPU they cost nothing.

Apple's re-authored SAM3 shows the fix in one file. The module docstring is the whole lesson
(✅ **VERIFIED** — `models/ios/sam3/primitives/window.py:6-12`):

```
"""Window partition / unpartition for SAM3 image-encoder window attention.

The HF reference reshapes through rank-6 intermediates
``(B, H//ws, ws, W//ws, ws, C)``, which the on-device compiler rejects.
This pair of helpers stays strictly at rank 4 by working in
channels-last format and folding ``ws*C`` together — two passes (H then
W), each rank 4. Both operate on BC1S tensors.
"""
```

And the implementation (✅ **VERIFIED** — `window.py:18-51`, complete and unmodified):

```python
import torch


def window_partition_ane(
    x: torch.Tensor,
    H: int,
    W: int,
    window_size: int,
) -> torch.Tensor:
    """Partition spatial tokens into non-overlapping windows (BC1S).

    Requires ``H`` and ``W`` divisible by ``window_size``.
    Returns ``(B * num_windows, C, 1, ws*ws)``.
    """
    assert H % window_size == 0, f"H={H} not divisible by window_size={window_size}"
    assert W % window_size == 0, f"W={W} not divisible by window_size={window_size}"

    B, C, one, S = x.shape
    assert one == 1, f"Expected dim 2 to be 1, got {one}"
    assert S == H * W, f"S={S} != H*W={H * W}"

    ws = window_size
    nH = H // ws
    nW = W // ws

    t = x.squeeze(2).permute(0, 2, 1)      # (B, H*W, C)
    t = t.reshape(B, H, W, C)              # rank 4

    t = t.reshape(B * nH, ws, W, C)        # rank 4 — fold nH into batch

    t = t.reshape(B * nH, ws, nW, ws * C)  # rank 4 — fold ws into channels
    t = t.permute(0, 2, 1, 3)
    t = t.reshape(B * nH * nW, ws, ws, C)  # rank 4

    t = t.reshape(B * nH * nW, ws * ws, C)
    t = t.permute(0, 2, 1).unsqueeze(2)    # back to BC1S
    return t
```

The two techniques generalise, and they are the ones to reach for whenever a reshape overflows
rank 5:

1. **Fold leading axes into the batch.** `(B, nH, ws, W, C)` → `(B*nH, ws, W, C)`. The batch axis is
   free real estate; anything that does not interact across it can be folded in.
2. **Fold trailing axes into the channel.** `(B*nH, ws, nW, ws, C)` → `(B*nH, ws, nW, ws*C)`, then
   permute, then unfold. Correct as long as the two folded axes stay adjacent and in order.

> ⚠️ **SILENT FAILURE — the rank-6 palettisation trap.**
> This one is worth its own callout because it does not come from your model code at all, it comes
> from your *compression config*, and it produces a model that runs perfectly and burns your battery.
>
> `coreai-opt`'s `PalettizationSpec` has a field `enable_per_channel_scale: bool = False`. Turning
> it on looks like a free quality win — it normalises weights along output channels before
> clustering. Apple's own SAM3 recipe deliberately leaves it off, and the reason is in the
> config's docstring (✅ **VERIFIED** — `python/src/coreai_models/segmentation/pipeline.py:136-142`,
> verbatim):
>
> > *"Both encoders deliberately disable per-channel scale: `enable_per_channel_scale=True` lowers
> > to `mps.dequantize_lut` ops with rank-6 LUTs, which ANE rejects (max tensor rank 5), forcing
> > the runtime to fall back to GPU. Keeping it off keeps the asset ANE-compatible at the cost of a
> > small PyTorch-side quality regression."*
>
> **Nothing throws.** The export succeeds, the asset loads, inference produces correct numbers —
> on the GPU, at GPU power draw, having discarded the entire reason you authored in BC1S. The only
> symptom is energy and thermals.
>
> **Detection:** compile with `xcrun coreai-build compile` and inspect residency (§4.16), or watch
> for the model being much hotter than expected on device.
> **Safe default:** leave `enable_per_channel_scale` at its default `False` and get your
> per-channel behaviour from `PerGroupedChannelGranularity(axis=0, group_size=…)` instead, exactly
> as Apple's shipped recipe does.
>
> Note this is also a place where WWDC26 session 325 and the shipped code **disagree**: the talk
> says (325:241) *"I apply 4-bit palettization **with per-channel scales** to the two encoders."*
> The code sets the flag to `False` on purpose. Either the presenter was speaking loosely about
> `PerGroupedChannelGranularity`, or the recipe changed after the talk was recorded. Follow the
> code.

### 4.2 fp16, int8, int16 — and nothing else

> *"**Supported dtypes**: fp16, int8, int16. fp32 falls back to GPU/CPU."*
> (✅ **VERIFIED** — `neural_engine_rules.md:8`)

The consequence is more aggressive than it sounds, because **a Python float literal is a float32
constant**. Apple states this twice in the same file — once in the general section and once again
in the MLP section, which tells you how often they have watched people hit it
(✅ **VERIFIED** — `neural_engine_rules.md:123-134` and `316-327`, identical text both times):

> *"Any Python float literal or fp32 op creates an f32 buffer that Neural Engine cannot execute —
> it falls back to GPU/CPU"*

```python
# BAD
x = hidden * (1.0 + scale)      # 1.0 is f32
h = torch.exp(self.conv(x))     # exp upcasts to f32

# GOOD
one = torch.ones(1, dtype=hidden.dtype, device=hidden.device)
x = hidden * (one + scale)
h = torch.exp(self.conv(x)).to(torch.float16)
```

`common_issues.md:5` restates it as a general rule: *"**Float32 constants**: Any Python float
literal (e.g., `x * 2.0`) creates an f32 constant Neural Engine rejects. Cast to float16."*

Apple's shipped primitives follow this obsessively, and reading them is the fastest way to
internalise the style. Three examples, all ✅ **VERIFIED**:

```python
# primitives/ios/gelu.py:21-33
# "2 * sqrt(2/pi) ~ 1.5957691; stored as f16 to avoid f32 constants in the graph."
_GELU_COEFF = torch.tensor(2.0 * math.sqrt(2.0 / math.pi), dtype=torch.float16)
_CUBIC_COEFF = torch.tensor(0.044715, dtype=torch.float16)


class GELUReauthored(nn.Module):
    """GELU(x) ~ x * sigmoid(2 * sqrt(2/pi) * (x + 0.044715 * x**3))."""

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        coeff = _GELU_COEFF.to(dtype=x.dtype, device=x.device)
        cubic = _CUBIC_COEFF.to(dtype=x.dtype, device=x.device)
        inner = coeff * (x + cubic * x * x * x)
        return x * torch.sigmoid(inner)
```

```python
# primitives/ios/layer_norm.py:20-33 — eps is a tensor, not a float
def __init__(self, dim: int, eps: float = 1e-5) -> None:
    super().__init__()
    with torch.device("cpu"):
        self.weight = nn.Parameter(torch.ones(1, dim, 1, 1))
        self.bias = nn.Parameter(torch.zeros(1, dim, 1, 1))
    self._eps = eps

def forward(self, x: torch.Tensor) -> torch.Tensor:
    eps = torch.tensor(self._eps, dtype=x.dtype, device=x.device)   # <- materialised in x's dtype
    mean = x.mean(dim=1, keepdim=True)
    ...
```

```python
# primitives/ios/bidirectional_sdpa.py:35-36
# "Scale as f16 buffer to avoid f32 constants in the graph."
self.register_buffer("_scale", torch.tensor(head_dim**-0.5, dtype=torch.float16))
```

Note the pattern in `GELUReauthored`: the constants are module-level `torch.tensor`s in fp16, and
then `.to(dtype=x.dtype, device=x.device)` at use. That gives you a graph free of f32 constants
*and* a module that still works if you run it in fp32 on CPU for a reference comparison. Copy it.

Also note *why* `GELUReauthored` exists at all rather than `nn.GELU`. Its docstring
(✅ **VERIFIED** — `gelu.py:6-14`):

> *"Uses the identity: `0.5 * x * (1 + tanh(z)) = x * sigmoid(2 * z)` where
> `z = sqrt(2/pi) * (x + 0.044715 * x**3)`. **PSNR ~92 dB vs exact GELU** (compared to ~57 dB for
> the simpler `x * sigmoid(1.702 * x)` approximation). Only sigmoid is used so the op is safe for
> on-device execution."*

That "~92 dB vs ~57 dB" is an **Apple-published** number, from an Apple source file, with no
hardware attached because it is a pure numerical statement about the approximation, not a
measurement. It is also a template for how to justify an op substitution: pick the
hardware-friendly identity, then report the PSNR against the exact op.

The same pattern appears for `tanh` (✅ **VERIFIED** — `common_issues.md:134`):

> *"For `torch.tanh`: replace with `2 * torch.sigmoid(2 * x) - 1`."*

and for SiLU, where the reason is spelled out precisely
(✅ **VERIFIED** — `common_issues.md:49-53`):

> **Neural Engine MLP — 3 invalid ops from `mps.swish`**
> *"**Cause**: `nn.functional.silu(x)` lowers to `mps.cast(→f32) + mps.swish(f32) + mps.cast(→f16)`.*
> *"**Fix**: `gate_pre * torch.sigmoid(gate_pre)` instead of `silu()`."*

> 🟡 **RECONSTRUCTED — the SiLU story is not fully consistent in Apple's own tree.**
> `common_issues.md` says to avoid `nn.functional.silu`. But the shipped iOS MLP
> (`primitives/ios/mlp.py:41`) *uses* `nn.functional.silu(self.gate_proj(x))`, and the iOS export
> path deliberately removes SiLU from the decomposition table so it survives as a single op
> (✅ **VERIFIED** — `export/ios.py`: `decomp_table.pop(torch.ops.aten.silu.default)` and
> `decomp_table.pop(torch.ops.aten.silu.out)`).
> **Reading:** the `mps.swish` problem is what happens when SiLU is *decomposed* on the way in;
> keeping it intact through the decomposition table avoids it. The `common_issues` entry is the
> fix for when you cannot control the decomposition table.
> **Safe default:** if you are exporting through `coreai_models.export.ios`, use
> `nn.functional.silu` as the shipped MLP does. If you are writing your own export and you see
> three ops where you expected one, substitute `gate_pre * torch.sigmoid(gate_pre)`.

Finally, a community-sourced refinement that is worth knowing and is **not** in Apple's files:

> **Community-measured** (`john-rocky/coreai-model-zoo`, `knowledge/compute-units-and-authoring.md`,
> single-author, 2026-06/07): *"`.float()` is a no-op on the ANE (MPSGraph drops the cast). To get
> fp32 accumulation you must use an op the hardware accumulates in fp32 (Conv engine, LayerNorm
> kernel)."* The same source reports an RMSNorm overflow trap — computing `mean(x²)` in fp16
> overflows on large activations — with the fix being the identity `LayerNorm([x, -x]) == RMSNorm`,
> because the Neural Engine's LayerNorm kernel accumulates in fp32.
>
> Treat both as hypotheses to test on your model, not as Apple guidance. They are consistent with
> Apple's material (which does say to prefer high-level ops, §4.7, and does say Conv2d maps to the
> convolution engine, §4.5) but Apple does not state either claim.

### 4.3 The alignment rule: the last axis is width

This is the most surprising rule in the set, the one with the largest penalty, and the one that
almost nobody applies because it looks like a micro-optimisation. It is not. It is a 32× memory
multiplier.

Apple's text, verbatim and in full
(✅ **VERIFIED** — `neural_engine_rules.md:21-31`):

> ### Tensor memory alignment
>
> *"Neural Engine processes data in fixed-size blocks along the last tensor dimension (which Neural
> Engine treats as width). The last axis must be contiguous and aligned to 64 bytes for the model's
> inputs and outputs. When this dimension is not well-aligned, it gets padded — and the penalty is
> severe. **A singleton last axis (dimension = 1) gets padded to 64 bytes, resulting in 32x memory
> cost at fp16 and 64x at int8.** Intermediate tensors that reside in L2 cache may tolerate smaller
> widths, but at authoring time you cannot predict which tensors will be L2-resident, so design for
> the worst case."*
>
> **Rules:**
>
> - *"Use power-of-2 sizes for the last dimension whenever possible — they align well with Neural
>   Engine processing granularities."*
> - *"Ensure the last dimension contains at least 32 FP16 elements (64 bytes)."*
> - *"Never use the last axis as a singleton dimension — this is the worst case for padding waste."*
> - *"Reshape or transpose tensors to move larger dimensions to the last position."*
> - *"Design layer dimensions with this alignment in mind from the start."*

with Apple's own example:

```python
# BAD: last dimension is 7 — maps to width on Neural Engine, heavy padding overhead
bad_tensor = torch.randn(1, 16, 32, 224, 7)     # NDCHW layout

# GOOD: last dimension is 64 — well-aligned on Neural Engine
good_tensor = torch.randn(1, 16, 32, 224, 64)   # NDCHW layout
```

The arithmetic behind "32×": at fp16, 64 bytes is 32 elements. A tensor whose last axis is 1 still
occupies a full 64-byte block per row, so you pay 32 elements' worth of bandwidth to move 1
element's worth of data. At int8, 64 bytes is 64 elements, hence 64×.

Three practical consequences.

**One: this is why BC1S puts the sequence last.** In `(B, C, 1, S)` the innermost axis is the
sequence, which for a prefill chunk is 8, 16, 64 or 256 — powers of two, comfortably above 32. If
you had chosen `(B, S, 1, C)` for attention scores you would have been fine too (`C` is large), but
`(B, C, S, 1)` would be catastrophic.

**Two: this is why the LLM inter-block layout is `(B, S, 1, D)` and not `(B, S, D, 1)`.** `D` is the
hidden size — 1024, 2048, 4096 — a power of two well over 32. Putting the singleton in position 2
rather than position 3 is the entire design.

**Three: the model's I/O boundary is where this is enforced hardest.** Apple's sentence is precise:
*"for the model's inputs and outputs."* Look at the iOS LLM export's declared shapes and you can see
the rule being applied at the boundary (✅ **VERIFIED** — `export/ios.py`, as captured in the
corpus):

```
transformer_input : (1, q_len, 1, hidden_size)          # last axis = hidden_size
position_ids      : (1, q_len)             uint16
causal_mask       : (1, cache_len, 1, q_len)            # last axis = q_len ∈ {8, 16, 64}
key_cache         : (n_layers, 1, kv_embed, 1, cache_len)   # last axis = cache_len ≥ 256
value_cache       : (n_layers, 1, kv_embed, 1, cache_len)
in_step           : (1,)                   int32
```

Every one of those has a large power-of-two innermost axis, and every one has its singleton in
position −2, never −1. That is not an accident of the model architecture; it is this rule.

> **The nuance Apple's own code takes advantage of.** The shipped iOS MLP reshapes to
> `(batch_size * query_len, dim, 1, 1)` before its 1×1 convolutions
> (✅ **VERIFIED** — `primitives/ios/mlp.py:38`) — a singleton *last* axis, apparently in direct
> violation. This is the "intermediates that reside in L2 may tolerate smaller widths" escape
> hatch: a 1×1 conv's spatial extent genuinely is 1×1, the tensor is an intermediate, and folding
> `B*S` into the batch is what makes the convolution engine efficient. Apple is taking the L2 bet
> deliberately at a site where the alternative is worse. **Do not read this as licence to ignore
> the rule.** Read it as: at the model's I/O boundary the rule is absolute; inside, Apple's own
> primitives are the guide to where the exceptions are.

**Hardware constraint objects.** The iOS export path does not leave alignment to chance for the
biggest tensors; it declares it. From the corpus's reading of `export/ios.py`
(✅ **VERIFIED**):

```python
emb_table_constraints = HardwareConstraints(
    AllocationType.IOSurface,
    interleave=[8, 1, 1],
    alignments=[1, 1, 1, 1],
)
cache_constraints = HardwareConstraints(
    AllocationType.IOSurface,
    interleave=[1, 1, 8, 1, 1],
    alignments=[1, 1, 1, 1, 8 * max_context_length, 1],
)
```

applied to `load_embeddings`, `gather_embeddings`, `extend` and `prompt_opt`, with
`KV_CACHE_INTERLEAVE_FACTOR = 8`.

> 🟡 **RECONSTRUCTED — `HardwareConstraints` / `AllocationType`.**
> These names appear in `coreai_models/export/ios.py` and are therefore real, but they are a
> `coreai` runtime API whose full signature, the meaning of `interleave` versus `alignments`, and
> the set of `AllocationType` cases are **not documented anywhere in the corpus** — there is no
> `HardwareConstraints` page in the `coreai-torch` docs and no forum answer.
> **What would resolve it:** the `coreai` Python API reference at
> `apple.github.io/coreai-torch/main/coreai-core`, or an `inspect.signature` dump against
> `coreai-core 1.0.0b2`.
> **Safe default meanwhile:** do not hand-author `HardwareConstraints`. If you are exporting an
> LLM for iOS, go through `coreai_models.export.ios`, which applies Apple's constraints for you.
> If you are exporting something else, omit them; the rule-following layout in §4.3 is what
> actually matters, and the constraints are a refinement on top of it.

### 4.4 BC1S: the layout everything else follows from

Apple's definition (✅ **VERIFIED** — `neural_engine_rules.md:43-45`):

> ### BC1S format
>
> *"The Neural Engine operates on tensors in `(Batch, Channels, 1, Sequence)` format. Matrix
> multiplications are implemented as 1x1 Conv2d."*

and the four conversion helpers, verbatim (`neural_engine_rules.md:47-65`):

```python
# Standard to Neural Engine: (B, S, D) → (B, D, 1, S)
x = x.permute(0, 2, 1).unsqueeze(2)

# Neural Engine to standard: (B, D, 1, S) → (B, S, D)
x = x.squeeze(2).permute(0, 2, 1)


# Multi-head GPU to Neural Engine: (B, H, S, D) → (B, H*D, 1, S)
def gpu_to_bc1s(x):
    B, H, S, D = x.shape
    return x.permute(0, 1, 3, 2).reshape(B, H * D, 1, S)


# Neural Engine to multi-head GPU: (B, H*D, 1, S) → (B, H, S, D)
def bc1s_to_gpu(x, n_heads, head_dim):
    B, _, _, S = x.shape
    return x.reshape(B, n_heads, head_dim, S).permute(0, 1, 3, 2)
```

Keep those four functions in a `layout.py` in every re-authoring project. You will use them in
your PSNR harness constantly, and `common_issues.md:7` warns about exactly the mistake you will
otherwise make: *"**Layout mismatch in comparisons**: Apply the appropriate transform before PSNR.
**Never compare raw tensors across layouts.**"* A layout-mismatched PSNR comparison produces a
number in the 5–15 dB range and sends you hunting for a numerical bug that does not exist.

**The memory-copy corollary.** Apple immediately follows the layout section with a warning
(✅ **VERIFIED** — `neural_engine_rules.md:71`):

> *"Unnecessary casts, reshapes, and transposes may introduce memory copies in the compiled graph.
> **Reshapes and transposes that touch the width (innermost) dimension are especially expensive
> because they force a full data rewrite in memory.** While the compiler cancels out some redundant
> operations during optimization, **it does not catch all patterns**. Minimize these operations at
> the source level — the fewer you have, the fewer survive to the compiled binary."*

Two things to take from this. First, "the compiler cancels out *some* redundant operations" is an
explicit instruction not to rely on `AIProgram.optimize()` to clean up after you. Second, the
expensive transposes are specifically the ones that touch the last axis — which is every
`transpose(-3, -1)` in the BC1S↔`(B,S,1,D)` dance. That is the cost you are paying for the
convolution engine, and it is why Apple's own attention block batches its transposes rather than
sprinkling them.

### 4.5 `nn.Conv2d(kernel_size=1)` instead of `nn.Linear`

Apple's rule (✅ **VERIFIED** — `neural_engine_rules.md:92-99`):

> ### Conv2d instead of Linear
>
> *"Neural Engine hardware natively accelerates Conv2d — `nn.Linear` gets decomposed into less
> efficient ops that may fall back to CPU. Using 1x1 Conv2d maps directly to the Neural Engine's
> convolution engine, keeping everything on-chip."*
>
> ```python
> # GPU: nn.Linear(in_features, out_features)
> # Neural Engine: nn.Conv2d(in_features, out_features, kernel_size=1)
> ```

and the weight surgery that goes with it (`neural_engine_rules.md:101-109`):

> **State dict weight conversion** — *"when loading weights from a source model that uses
> `nn.Linear`, reshape for Conv2d:"*
>
> ```python
> # Linear weight [O, I] → Conv2d weight [O, I, 1, 1]
> conv.weight.data = linear.weight.unsqueeze(-1).unsqueeze(-1)
>
> # Norm weight: (D,) → (1, D, 1, 1)
> norm.weight.data = source_norm.weight.reshape(1, -1, 1, 1)
> ```

Both forms appear in the shipped code, and it is worth seeing both because they suit different
situations.

**Form 1 — state-dict mutation**, used when you are re-keying a whole checkpoint. From the shipped
iOS Qwen3 (✅ **VERIFIED** — `models/ios/qwen3.py:279-288`):

```python
for i in range(max_layer + 1):
    # Reshape attention weights for Conv2d
    for proj in ["q_proj", "k_proj", "v_proj", "o_proj"]:
        weight_key = f"model.layers.{i}.self_attn.{proj}.weight"
        state_dict[weight_key] = state_dict[weight_key].unsqueeze(-1).unsqueeze(-1)

    # Reshape MLP weights for Conv2d
    for proj in ["up_proj", "gate_proj", "down_proj"]:
        weight_key = f"model.layers.{i}.mlp.{proj}.weight"
        state_dict[weight_key] = state_dict[weight_key].unsqueeze(-1).unsqueeze(-1)
```

**Form 2 — a module-level converter**, used when you are assembling a re-authored model out of
Hugging Face submodules. This function appears twice in Apple's SAM3 tree, once in
`sam3_reauthored.py` and once in `image_encoder.py`
(✅ **VERIFIED** — `models/ios/sam3/sam3_reauthored.py:34-42`, complete):

```python
def _linear_to_conv2d(linear: nn.Linear) -> nn.Conv2d:
    in_f = linear.in_features
    out_f = linear.out_features
    has_bias = linear.bias is not None
    conv = nn.Conv2d(in_f, out_f, 1, bias=has_bias)
    conv.weight.data = linear.weight.data.reshape(out_f, in_f, 1, 1)
    if has_bias:
        conv.bias.data = linear.bias.data
    return conv
```

Note that the SAM3 version uses `.reshape(out_f, in_f, 1, 1)` where the skill's snippet uses
`.unsqueeze(-1).unsqueeze(-1)`. They are equivalent for a contiguous 2-D weight. Use whichever
reads better; `reshape` is more legible when the shape is being asserted, `unsqueeze` is more
legible in a loop over key names.

**Bias needs no reshape.** `nn.Conv2d`'s bias is `(O,)`, same as `nn.Linear`'s. Only the weight
changes rank.

> ⚠️ **SILENT FAILURE — the `nn.Linear` that survives.**
> Apple's phrasing is *"`nn.Linear` gets decomposed into less efficient ops that **may** fall back
> to CPU."* "May" is doing real work there. A stray `nn.Linear` in an otherwise BC1S model does not
> fail to convert and does not produce wrong numbers. It produces a **segmentation point**: the
> compiler runs everything up to it on the Neural Engine, transfers the tensor, runs the Linear
> elsewhere, and transfers back. For a small model those two transfers can cost more than the whole
> rest of the forward pass (§4.16).
>
> The shipped iOS Qwen3 has exactly one surviving `nn.Linear` — the LM head
> (`models/ios/qwen3.py:185`, `self.lm_head = nn.Linear(config.hidden_size, config.vocab_size,
> bias=False)`) — and only in the untied-embedding case; in the tied case Apple replaces it with an
> explicit `embedding_table @ out` matmul (`qwen3.py:231-236`). One deliberate exception at the very
> end of the graph, where the transfer is going to happen anyway. That is the standard to hold
> yourself to.
>
> **Detection:** grep your re-authored model for `nn.Linear` before you export. Every hit needs a
> one-line comment justifying it.

### 4.6 Transpose bookkeeping at every projection site

`nn.Conv2d` expects NCHW. Your data is in BC1S — which *is* NCHW with `H=1` — or in `(B, S, 1, D)`,
which is not. So every projection site is surrounded by a matched pair of transposes.

Apple's rule (✅ **VERIFIED** — `neural_engine_rules.md:75-86`):

> ### Transpose bookkeeping around Conv2d
>
> *"Conv2d expects data with channels in the right position. When your data flows in BC1S format,
> transpose into and out of Conv2d projection calls:"*
>
> ```python
> # BC1S data → transpose for Conv2d → project → transpose back
> x = x.transpose(-3, -1)
> projected = self.proj(x)
> projected = projected.transpose(-3, -1)
> ```
>
> *"This transpose pair appears at every projection site. Keep it consistent — **mismatched
> transposes are a common source of silent correctness bugs.**"*

That last sentence is Apple's own ⚠️ silent-failure warning and it deserves amplifying. A mismatched
transpose does not throw. `torch.export` traces it happily. The conversion succeeds. What you get is
a model whose activations have been shuffled in a structured way, which produces output that is
*wrong but not obviously wrong* — plausible token distributions, plausible-looking masks — and a
PSNR somewhere in the teens.

Here is the complete, shipped attention block that shows every transpose in context. This is the
single most useful listing in the guide; read it slowly. ✅ **VERIFIED** verbatim —
`python/src/coreai_models/models/ios/qwen3.py:28-109`:

```python
import torch
import torch.nn as nn
from transformers.models.qwen3.modeling_qwen3 import Qwen3Config

from coreai_models.primitives.ios.cache import KVCacheHandler
from coreai_models.primitives.ios.rms_norm import RMSNorm
from coreai_models.primitives.ios.rope import apply_rope
from coreai_models.primitives.ios.sdpa import SDPA


class Attention(nn.Module):
    def __init__(self, config: Qwen3Config, layer_idx: int) -> None:
        super().__init__()
        self.layer_idx = layer_idx

        dim = config.hidden_size
        self.n_heads = n_heads = config.num_attention_heads
        self.n_kv_heads = n_kv_heads = config.num_key_value_heads
        self.head_dim = head_dim = getattr(config, "head_dim", dim // n_heads)

        self.q_proj = nn.Conv2d(dim, n_heads * head_dim, kernel_size=1, bias=False)
        self.k_proj = nn.Conv2d(dim, n_kv_heads * head_dim, kernel_size=1, bias=False)
        self.v_proj = nn.Conv2d(dim, n_kv_heads * head_dim, kernel_size=1, bias=False)

        self.o_proj = nn.Conv2d(n_heads * head_dim, dim, kernel_size=1, bias=False)

        self.q_norm = RMSNorm(head_dim, eps=config.rms_norm_eps)
        self.k_norm = RMSNorm(head_dim, eps=config.rms_norm_eps)

        self.sdpa = SDPA(head_dim=self.head_dim)

    def forward(
        self,
        x: torch.Tensor,
        rope_cos: torch.Tensor,
        rope_sin: torch.Tensor,
        in_step: torch.IntTensor,
        causal_mask: torch.Tensor,
        cache: KVCacheHandler | None = None,
    ) -> torch.Tensor:
        batch_size, query_len, _, hidden_size = x.shape
        n_heads, n_kv_heads = self.n_heads, self.n_kv_heads

        x = x.transpose(-3, -1)
        query = self.q_proj(x)
        key = self.k_proj(x)
        value = self.v_proj(x)

        query = (
            query.transpose(-3, -1)
            .reshape(batch_size, query_len, n_heads, self.head_dim)
            .transpose(-2, -3)
        )
        key = (
            key.transpose(-3, -1)
            .reshape(batch_size, query_len, n_kv_heads, self.head_dim)
            .transpose(-2, -3)
        )

        query = self.q_norm(query)
        key = self.k_norm(key)

        seq_len = rope_cos.shape[1]
        torch._check_is_size(query_len)
        torch._check_is_size(seq_len)

        query = apply_rope(query, rope_cos, rope_sin)
        key = apply_rope(key, rope_cos, rope_sin)

        query = (
            query.transpose(-2, -3)
            .reshape(batch_size, query_len, 1, n_heads * self.head_dim)
            .transpose(-3, -1)
        )
        key = (
            key.transpose(-3, -2)
            .reshape(batch_size, query_len, 1, n_kv_heads * self.head_dim)
            .transpose(-3, -1)
        )

        if cache is not None:
            key, value = cache.update_and_fetch(
                self.layer_idx,
                in_step,
                key,
                value,
                query_len,
            )

        output = self.sdpa(query, key, value, causal_mask)
        output = self.o_proj(output)
        return output.transpose(-3, -1)
```

Trace the shapes, because this is the part that is impossible to reconstruct from prose:

| Line | Shape after |
| --- | --- |
| entry `x` | `(B, S, 1, D)` |
| `x.transpose(-3, -1)` | `(B, D, 1, S)` — **BC1S**, and NCHW for Conv2d with `H=1` |
| `self.q_proj(x)` | `(B, H·hd, 1, S)` |
| `.transpose(-3, -1)` | `(B, S, 1, H·hd)` |
| `.reshape(B, S, H, hd)` | `(B, S, H, hd)` — heads split out |
| `.transpose(-2, -3)` | `(B, H, S, hd)` — head-major, so RMSNorm's `mean(-1)` normalises over `hd` |
| `apply_rope(...)` | `(B, H, S, hd)` — `cos`/`sin` arrive `(B, S, hd)`, `unsqueeze(1)` broadcasts |
| `.transpose(-2, -3)` | `(B, S, H, hd)` |
| `.reshape(B, S, 1, H·hd)` | `(B, S, 1, H·hd)` |
| `.transpose(-3, -1)` | `(B, H·hd, 1, S)` — **BC1S** again, for SDPA and for the cache |
| `self.sdpa(...)` | `(B, H·hd, 1, S)` |
| `self.o_proj(output)` | `(B, D, 1, S)` |
| `.transpose(-3, -1)` | `(B, S, 1, D)` — matches entry |

Four observations you will not get anywhere else:

1. **`transpose(-3, -1)` is its own inverse on a 4-D tensor.** It swaps dims 1 and 3. Every entry
   and exit of the block uses it; the block is layout-neutral from the outside.
2. **`q` uses `.transpose(-2, -3)` and `k` uses `.transpose(-3, -2)`.** These are identical
   operations written two ways. It is stylistic inconsistency in Apple's own file, not a subtlety —
   but if you are diffing your implementation against theirs, do not go hunting for a difference.
3. **The norm sits in head-major layout, not BC1S.** `RMSNorm(head_dim)` reduces over the last axis,
   so Q/K norm has to happen while `hd` is last. That is why the transposes bracket the
   norm-and-RoPE pair rather than wrapping each op.
4. **`torch._check_is_size(query_len)` and `torch._check_is_size(seq_len)`** are export hints, not
   runtime assertions. They tell `torch.export`'s symbolic shape machinery that these values are
   non-negative sizes so the traced graph can be specialised. Omit them and you get shape-guard
   failures during export that read like unrelated errors.

**A test that catches mismatched transposes before conversion does.** Since the block is
layout-neutral, you can assert it:

```python
import torch


def assert_layout_neutral(block, batch=1, seq=8, dim=1024, **fwd_kwargs):
    """A BC1S-bracketed block must return the same layout it was given."""
    x = torch.randn(batch, seq, 1, dim, dtype=torch.float16)
    y = block(x, **fwd_kwargs)
    assert y.shape == x.shape, f"layout leak: in {tuple(x.shape)} out {tuple(y.shape)}"
```

This catches the class of bug where a transpose is dropped entirely. It does **not** catch the
class where two transposes are both present but one is wrong — for that you need the PSNR gate in
§7, run per-primitive.

### 4.7 Prefer high-level ops

✅ **VERIFIED** — `neural_engine_rules.md:113-117`:

> ### Prefer high-level ops
>
> *"The compiler maps high-level ops (e.g., `nn.LayerNorm`, `nn.RMSNorm`) more efficiently than
> their manually decomposed equivalents (reduce → multiply → add). Using the high-level op gives the
> compiler better visibility into intent and more optimization opportunities."*
>
> *"**If you manually decompose an op and export it, the compiler may or may not reassemble it — do
> not rely on this.** Use the highest-level PyTorch op available when an Neural Engine-supported
> lowering exists."*

"May or may not reassemble it — do not rely on this" is as close as Apple gets to saying *we have
a fusion pass and it is best-effort*. Plan accordingly: express intent at the highest level the
hardware supports, and only decompose when you have a specific reason (as with GELU in §4.2, where
the reason is that the exact op does not lower).

There is a tension here with §4.2's advice to hand-write approximations, and the resolution is:

- **If a high-level op has an ANE lowering, use it.** `nn.LayerNorm`, `nn.RMSNorm`.
- **If it does not, hand-write the cheapest mathematically-equivalent form, and record the PSNR of
  the substitution.** GELU → sigmoid identity (92 dB), tanh → `2·sigmoid(2x) − 1`.
- **Never hand-decompose something that has a lowering** on the theory that you can beat the
  compiler. You cannot, and you have destroyed its ability to recognise the pattern.

The macOS side takes the same idea considerably further: `coreai_torch.composite_ops` is a library
of *pre-blessed* high-level ops — `RMSNorm`, `RoPE`, `SDPA`, `GatherMM`, `GatedDeltaUpdate` — that
survive `torch.export` as named composites and get mapped to hand-written kernels
(✅ **VERIFIED** — `coreai_torch/composite_ops/` contains `_gated_delta_update.py`, `_gather_mm.py`,
`_rms_norm.py`, `_rope.py`, `_sdpa.py`). The macOS primitives are thin subclasses of these:
`primitives/macos/rms_norm.py:12` is `class RMSNorm(coreai_torch.composite_ops.RMSNorm)` and
`primitives/macos/sdpa.py:13` is `class SDPA(coreai_torch.composite_ops.SDPA)`. The iOS primitives
are not — they are hand-written PyTorch — which is itself a statement about which composites have
ANE lowerings.

### 4.8 Softmax on the channel dimension

✅ **VERIFIED** — `neural_engine_rules.md:140`:

> ### Softmax placement
>
> *"Softmax on a spatial dimension (height, width) limits the compiler's ability to split work
> across spatial dimensions. This matters when input + output tensor size is large. If you need
> softmax and want efficient spatial processing, apply softmax on the **channel** dimension
> instead."*

This is why the shipped attention implementations call `.softmax(1)` — dim 1, the channel axis —
rather than `.softmax(-1)`. From the iOS SDPA (✅ **VERIFIED** — `primitives/ios/sdpa.py:123-125`):

```python
full_scores = torch.cat(scores, dim=2)
masked_scores = full_scores + torch.cat([causal_mask] * n_heads, dim=2)
full_scores = masked_scores.softmax(1)
```

and identically in the bidirectional variant (`primitives/ios/bidirectional_sdpa.py:100`):
`full_scores = full_scores.softmax(dim=1)`.

The reason this is *correct* and not just fast is the transposed score layout: the per-head
attention path builds scores as `(B, key_seq, n_heads, query_seq)`, so the axis you must normalise
over — keys — **is** dim 1. Softmax placement and mask orientation (§4.11) are the same design
decision seen from two sides.

If you are porting an attention implementation and you find yourself writing `.softmax(-1)` on the
Neural Engine, stop and check your score layout. One of the two is wrong.

### 4.9 Convolution geometry: strides, kernels, dilation, pooling

This subsection is different in kind from the rest. Apple flags it explicitly
(✅ **VERIFIED** — `neural_engine_rules.md:146`):

> ## Layer Design Guidelines
>
> *"Architecture choices that improve energy efficiency on Apple silicon. **These change the model
> structure, so retraining is required.** The trade-off is between mathematical equivalence and
> computational efficiency — these recommendations prioritize Neural Engine efficiency while
> maintaining comparable model quality through retraining."*

So this is advice for people **designing** a model, not people porting one. If you are converting
someone else's checkpoint, you cannot apply most of it. Read it anyway: it tells you what the
hardware likes, and therefore why a particular third-party architecture is slow on it.

**Convolution strides** (✅ **VERIFIED** — `neural_engine_rules.md:150-168`):

> *"Stride values that factor cleanly into 2s and 3s map efficiently to Neural Engine. Other values
> introduce overhead."*
>
> - *"For equal strides > 2: use 4, 6, 8, 9, 12, 16, 24, or 32 (prime factors of 2 and 3 only)."*
> - *"For mixed strides where one is 2: set the other to 3, 4, 8, or 9."*
> - *"Avoid unequal large strides — make them equal or set one to 2."*
> - *"**With palettized kernels, stride support is very limited — use up to 2.**"*
> - *"Avoid large kernel sizes especially along the width dimension. Substitute with mathematically
>   equivalent layers that use Neural Engine-compatible strides — use pixel shuffle or transpose
>   insertion tricks if necessary."*

```python
# BAD: stride 11 has prime factor 11; unequal large strides
self.conv1 = nn.Conv2d(64, 128, kernel_size=3, stride=11)
self.conv2 = nn.Conv2d(256, 512, kernel_size=3, stride=(7, 5))

# GOOD: prime factors of 2 and 3 only
self.conv1 = nn.Conv2d(64, 128, kernel_size=3, stride=12)         # 12 = 2² x 3
self.conv2 = nn.Conv2d(256, 512, kernel_size=3, stride=(8, 8))    # equal strides
self.conv3 = nn.Conv2d(128, 256, kernel_size=3, stride=(2, 4))    # mixed
```

The palettisation bullet is the one that will surprise you: **compressing your weights narrows the
set of strides the hardware can execute.** If you designed a stride-4 downsample and then palettised
it, you may have just moved that layer off the Neural Engine. This is a genuine
compression × authoring interaction and it is the reason Apple's own guidance
(`SKILL.md:138`) is *"Apply compression **after** authoring and verifying the float16 model,
**before** Core AI export"* — you need the uncompressed model to be correct before you can attribute
a regression to the compression.

**Large kernel decomposition** (✅ **VERIFIED** — `neural_engine_rules.md:175-186`):

> *"Large convolution kernels are expensive on Neural Engine. Replace a single large kernel with
> consecutive smaller kernels that produce the same receptive field."*
>
> **Formula:** `k_fused = k1 + k2 - 1`

```python
# BAD: single 9x9 kernel
self.conv = nn.Conv2d(in_ch, out_ch, kernel_size=9, padding=4)

# GOOD: two 5x5 kernels (5 + 5 - 1 = 9)
self.conv1 = nn.Conv2d(in_ch, out_ch, kernel_size=5, padding=2)
self.conv2 = nn.Conv2d(out_ch, out_ch, kernel_size=5, padding=2)
```

**Convolution fusion — the same formula run backwards**
(✅ **VERIFIED** — `neural_engine_rules.md:192-203`):

> *"Consecutive small convolutions **without activation between them** can be fused into a single
> larger convolution. This reduces overhead at the cost of increased per-op computation."*

```python
# BEFORE: two consecutive 3x3 convs, no activation between them
self.conv1 = nn.Conv2d(6, 7, kernel_size=3, padding=1)
self.conv2 = nn.Conv2d(7, 8, kernel_size=3, padding=1)

# AFTER: fused into one 5x5 conv (3 + 3 - 1 = 5)
self.conv_fused = nn.Conv2d(6, 8, kernel_size=5, padding=2)
```

> *"**Only fuse when there is no nonlinearity between the convolutions.** Activation functions
> between convolutions break the linear algebra that makes fusion valid."*

Note that decomposition and fusion are the *same* rule pointing in opposite directions, and Apple
gives no threshold for when to prefer which. The trade is stated — *"reduces overhead at the cost of
increased per-op computation"* — so the answer is empirical: measure both. The op-level benchmarker
in `coreai_torch.debugging.benchmarker` is the tool (Part 10 reference on debugging covers it).

**Dilated convolution factorization** (✅ **VERIFIED** — `neural_engine_rules.md:209-223`):

```python
# BAD: single dilation 8
self.conv = nn.Conv2d(ch, ch, 3, dilation=8, padding=8)

# GOOD: three dilation-2 convolutions (8 = 2 x 2 x 2)
self.conv1 = nn.Conv2d(ch, ch, 3, dilation=2, padding=2)
self.conv2 = nn.Conv2d(ch, ch, 3, dilation=2, padding=2)
self.conv3 = nn.Conv2d(ch, ch, 3, dilation=2, padding=2)

# Another example: dilation 6 = 2 x 3
self.conv_a = nn.Conv2d(ch, ch, 3, dilation=2, padding=2)
self.conv_b = nn.Conv2d(ch, ch, 3, dilation=3, padding=3)
```

**Pooling stride** (✅ **VERIFIED** — `neural_engine_rules.md:229-238`):

> *"Use stride 2 or 4 for pooling layers. Other stride values (3, 5, etc.) introduce overhead."*

```python
# GOOD
pool = nn.MaxPool2d(kernel_size=3, stride=2, padding=1)
pool = nn.MaxPool2d(kernel_size=3, stride=4, padding=1)

# AVOID
pool = nn.MaxPool2d(kernel_size=3, stride=3, padding=1)
pool = nn.MaxPool2d(kernel_size=3, stride=5, padding=1)
```

The common thread across all four: **2 and 3 are the hardware's factors.** Strides, dilations and
pooling strides that factor into 2s and 3s are cheap; 5, 7, 11 are not. If you are choosing an
architecture to port and two candidates are otherwise equal, this is a real tie-breaker.

### 4.10 Per-head attention: there is no fused SDPA

✅ **VERIFIED** — `neural_engine_rules.md:333-353`:

> ### Per-head attention
>
> *"Neural Engine cannot fuse multi-head attention into a single operation. Split Q/K/V into
> explicit per-head tensors and compute each head individually. Beyond correctness, this chunking
> produces smaller intermediate tensors that are more likely to stay in L2 cache, improving both
> throughput and multicore utilization."*
>
> *"Use the `bchq,bkhc->bkhq` einsum pattern for the Q@K matmul — it maps directly to hardware
> without intermediate transpose or reshape operations. This avoids memory copies that would
> otherwise be triggered by reshaping the attention dimensions."*
>
> ```python
> queries = query.split(head_dim, dim=1)
> keys = key.split(head_dim, dim=1)
> values = value.split(head_dim, dim=1)
>
> outputs = []
> for h in range(n_heads):
>     kv_idx = h // kv_group_size  # For GQA
>     # bchq,bkhc->bkhq: no transpose/reshape needed
>     attn = torch.einsum("bchq,bkhc->bkhq", queries[h], keys[kv_idx])
>     attn = attn * scale
>     attn = attn + mask
>     attn = torch.softmax(attn, dim=-1)
>     outputs.append(torch.einsum("bkhq,bkhc->bchq", attn, values[kv_idx]))
> ```
>
> *"**This is fundamental to Neural Engine hardware — there is no fused SDPA path.**"*

And `gpu_rules.md:65` states the mirror image: *"This is the opposite of Neural Engine, where each
head must be computed individually. On GPU, fused SDPA is both simpler to author and faster to
execute."*

> ⚠️ **Discrepancy between the skill and the shipped code — the shipped code does not use einsum.**
> `neural_engine_rules.md` recommends `torch.einsum("bchq,bkhc->bkhq", ...)`. Apple's own shipped
> iOS SDPA does **not** use einsum; it uses explicit `permute` + `@`
> (✅ **VERIFIED** — `primitives/ios/sdpa.py:100-145` and
> `primitives/ios/bidirectional_sdpa.py:67-111`). Both are per-head loops, both are `-40000.0`-mask
> compatible, both softmax on dim 1. They are alternative spellings of the same computation.
> **Safe default:** use the shipped `SDPA` / `BidirectionalSDPA` primitives from
> `coreai_models.primitives.ios`. They are tested by Apple's CI (`python-test` job runs
> `python/tests/test_model_units`). Reach for the einsum form only if you are writing an attention
> variant the primitives do not cover, and PSNR-check it against a torch reference either way.

Here is the shipped decode-path SDPA in full, because the head-splitting mechanics are where people
go wrong (✅ **VERIFIED** — `primitives/ios/sdpa.py:100-145`; the CUDA/HF fast path at lines 64–98
is omitted, it is a training-time convenience and is explicitly prefill-only):

```python
# Apply the scale factor before QK^T for numerical stability
key = key.transpose(-3, -1) * self._scale_factor
queries = query.split(self.head_dim, dim=1)
keys = list(key.split(self.head_dim, dim=-1))

n_heads = len(queries)

# permute key heads in advance
for kv_idx in range(len(keys)):
    keys[kv_idx] = keys[kv_idx].permute(0, 2, 3, 1)

kv_group_size = len(queries) // len(keys)

scores = []

for head_idx in range(n_heads):
    kv_idx = head_idx // kv_group_size
    q = queries[head_idx].permute(0, 2, 3, 1)
    k = keys[kv_idx]
    attn_score = q @ k
    attn_score = attn_score.permute(0, 3, 1, 2)
    scores.append(attn_score)

full_scores = torch.cat(scores, dim=2)
masked_scores = full_scores + torch.cat([causal_mask] * n_heads, dim=2)
full_scores = masked_scores.softmax(1)

scores = full_scores.split(1, dim=2)

values = list(value.split(self.head_dim, dim=1))

# transpose values in advance
for kv_idx in range(len(values)):
    values[kv_idx] = values[kv_idx].permute(0, 2, 3, 1).squeeze(1)

weights = []
for head_idx in range(n_heads):
    kv_idx = head_idx // kv_group_size
    s = scores[head_idx].permute(0, 2, 3, 1).squeeze(1)
    v = values[kv_idx]
    weight = (s @ v).unsqueeze(1)
    weight = weight.permute(0, 3, 1, 2)
    weights.append(weight)

final_score = torch.cat(weights, dim=1)
return final_score
```

Five details that matter:

1. **The scale is applied to `key`, before the matmul** — `key.transpose(-3, -1) * self._scale_factor`.
   The comment says why: *"Apply the scale factor before QK^T for numerical stability."* In fp16,
   scaling after the matmul risks overflowing the score matrix; scaling K first keeps the products
   in range. Do not "simplify" this to a post-multiply.
2. **GQA falls out of `kv_group_size = len(queries) // len(keys)`.** No special-casing; if
   `n_kv_heads == n_heads` the group size is 1 and it degenerates to MHA.
3. **The permutes are hoisted out of the loop** for keys and values. The scores loop does one
   permute per head, on the small tensor. This matters because `permute` on the innermost axis is a
   memory copy (§4.4).
4. **The mask is broadcast by `torch.cat([causal_mask] * n_heads, dim=2)`** rather than by
   `expand`. A literal concatenation, not a stride trick. On a hardware target that reads real
   memory blocks, the materialised tensor is what the compiler wants to see.
5. **The loop is a Python loop over a static `n_heads`.** `torch.export` unrolls it into
   `n_heads` copies of the body. For a 16-head model that is 16 matmuls in the graph, which is
   exactly what Apple means by *"chunking produces smaller intermediate tensors that are more likely
   to stay in L2."* It also means your graph gets large; a 32-layer, 16-head model has 512 attention
   matmuls in it. This is normal.

The `BidirectionalSDPA` used by the SAM3 vision encoder adds one more idea worth stealing — **query
chunking** (✅ **VERIFIED** — `primitives/ios/bidirectional_sdpa.py:29, 45-65`):

```python
def __init__(self, num_heads: int, head_dim: int, query_chunk_size: int = 576) -> None:
    ...

def forward(self, query, key, value, attention_mask=None):
    query_seq = query.shape[3]
    if query_seq > self.query_chunk_size:
        return self._chunked_forward(query, key, value, attention_mask)
    return self._standard_forward(query, key, value, attention_mask)
```

576 is `24 × 24` — the SAM3 window size squared, and also `(336/14)²`, the full token count at the
iOS image size. So the chunk threshold is set so that the *whole* iOS-resolution sequence fits in
one chunk and only the 1008-pixel variant chunks. That is what a well-chosen constant looks like:
derived from the model's geometry, not a round number.

### 4.11 The causal mask is transposed, and `-inf` is wrong

Two independent facts, both of which will silently ruin your attention.

✅ **VERIFIED** — `neural_engine_rules.md:359-372`:

> ### Causal mask
>
> *"Neural Engine mask shape is `(1, key_seq, 1, query_seq)` — **transposed from GPU**."*
>
> ```python
> def create_ane_causal_mask(seq_len):
>     key_idx = torch.arange(seq_len).unsqueeze(1)
>     query_idx = torch.arange(seq_len).unsqueeze(0)
>     mask = key_idx > query_idx
>     mask = mask.float().masked_fill(mask, -40000.0)  # NOT float('-inf')
>     return mask.unsqueeze(0).unsqueeze(2)  # (1, key_seq, 1, query_seq)
> ```
>
> > *"**Why -40000.0**: Neural Engine hardware does not handle IEEE `-inf` correctly in softmax.
> > `-40000.0` is representable in fp16 and drives `exp(-40000)` to zero."*
>
> *"Neural Engine also uses `K @ Q` (transposed from GPU's `Q @ K^T`) together with this transposed
> mask."*

Compare the GPU form (✅ **VERIFIED** — `gpu_rules.md:201-206`):

```python
mask = torch.triu(torch.ones(seq_len, seq_len), diagonal=1).bool()
mask = mask.masked_fill(mask, float("-inf"))     # GPU handles -inf correctly
```

Two opposite rules for the same tensor. Shape transposed, sentinel value different.

> ⚠️ **SILENT FAILURE #1 — mask orientation.**
> `common_issues.md:12-15` names this as its **first** entry, which tells you how often Apple has
> seen it:
>
> > **Neural Engine SDPA PSNR very low (~15-30 dB)**
> > *"**Cause**: Causal mask orientation is `(1, query, 1, key)` instead of `(1, key, 1, query)`."*
> > *"**Fix**: Transpose mask or use `create_ane_causal_mask()`."*
>
> Note the failure mode: **not a crash, not a shape error.** For square prefill chunks the two
> orientations have the *same shape*, so nothing catches it. The model runs, produces text, and is
> 15–30 dB worse than it should be — which for an LLM means subtly degraded, plausible-looking
> output. The only detector is a PSNR gate against a torch reference (§7).

> ⚠️ **SILENT FAILURE #2 — `float('-inf')`.**
> `common_issues.md:102-105`:
> > **Neural Engine causal mask with `float('-inf')`**
> > *"**Cause**: Neural Engine does not handle IEEE `-inf` correctly in softmax."*
> > *"**Fix**: Use `-40000.0` — representable in fp16, `exp(-40000)` is zero."*
>
> A GPU-authored mask ported unchanged will contain `-inf`. It converts fine. What happens on device
> is unspecified — Apple says only "does not handle correctly" — and the symptom is NaNs or
> uniform attention, depending. **Grep for `-inf` and `float("-inf")` in any ANE model before
> export.** It is a one-line grep and it catches a class of bug that costs a day.

Why `-40000.0` specifically? fp16's maximum finite magnitude is 65504, so −40000 is comfortably
representable with room for the score it is added to. `exp(-40000)` underflows to exactly 0 in any
precision. And it is far enough below any realistic pre-softmax score (which after the K-scaling of
§4.10 lives in single or double digits) that the masked entries are annihilated. Apple's own
read-only-cache helper uses `-1e4` (= −10000) for the same purpose
(`neural_engine_rules.md:411-414`), so the exact constant is not sacred — any large negative fp16
value works. `-40000.0` is the documented default; use it unless you have a reason.

The corresponding **read-only-pattern** mask, which is the one you actually need for chunked
prefill, is more involved (✅ **VERIFIED** — `neural_engine_rules.md:406-418`):

```python
# Causal mask for readonly pattern (offset `t`, query len `S_q`)
past_key_idx = torch.arange(max_S).view(max_S, 1, 1)
query_j = torch.arange(S_q).view(1, 1, S_q)
past_mask = (past_key_idx >= t + query_j).float() * -1e4

new_key_j = torch.arange(S_q).view(S_q, 1, 1)
new_mask = (new_key_j > query_j).float() * -1e4

# Combined: (1, max_S+S_q, 1, S_q)
mask = torch.cat([past_mask, new_mask], dim=0).unsqueeze(0)
```

Read the two predicates carefully, because they differ by one character and both are correct:

- **Past keys:** `past_key_idx >= t + query_j` → mask out. Strict: a query at absolute position
  `t + j` may attend to cached keys at positions `< t + j`, so anything at or beyond is masked.
- **New keys:** `new_key_j > query_j` → mask out. Non-strict: within the current chunk, a query may
  attend to itself, so only strictly-later keys are masked.

Apple's own checklist for the pattern (`neural_engine_rules.md:420-426`) puts it as
*"Mask: strict `k < t+j` for past; causal `m <= j` for new."* Get one of these wrong and you either
leak future information (model looks great in eval, is broken in generation) or over-mask
(model degrades smoothly with context length). Both are silent.

### 4.12 RoPE must be precomputed outside the graph

✅ **VERIFIED** — `neural_engine_rules.md:378`:

> ### RoPE
>
> *"Precompute cos/sin outside the exported model; pass as `(1, head_dim, 1, S)` 4D inputs. Do not
> index a 2D table inside the graph with `position_ids` — `gather_nd` produces 3D output."*

and the failure in `common_issues.md:56-59`:

> **Neural Engine RoPE — `gather_nd` produces 3D output**
> *"**Cause**: Indexing a 2D cos/sin table with `position_ids: [B, S]` produces 3D output Neural
> Engine rejects."*
> *"**Fix**: Compute cos/sin outside the model, pass as 4D `(1, head_dim, 1, S)` BC1S inputs."*

The shipped iOS implementation takes a middle path that is worth understanding, because it looks
like it violates the rule and does not. `RoPECache` keeps the table as a **buffer** and gathers from
it through a **custom op** (✅ **VERIFIED** — `primitives/ios/rope.py:22-39, 114-116`):

```python
@torch.library.custom_op("coreai::rope_gather_cached_cos_sin", mutates_args=[])
def rope_gather_cached_cos_sin(
    position_ids: torch.Tensor, cos_cached: torch.Tensor, sin_cached: torch.Tensor
) -> list[torch.Tensor]:
    position_ids = position_ids.to(torch.int32)
    rope_cos = cos_cached[position_ids]
    rope_sin = sin_cached[position_ids]
    return rope_cos, rope_sin


@rope_gather_cached_cos_sin.register_fake
def _fake(position_ids, cos_cached, sin_cached):
    position_ids = position_ids.to(torch.int32)
    rope_cos = cos_cached[position_ids]
    rope_sin = sin_cached[position_ids]
    return rope_cos, rope_sin
```

Wrapping the gather in a `torch.library.custom_op` with a registered fake means `torch.export` sees
one opaque node with a known output shape instead of a `gather_nd` it has to lower. The gather is
then given its own Core AI lowering. That is the general escape hatch for "PyTorch expresses this
in a way the hardware hates": **name it, give it a fake, lower it yourself.**

The application is a plain broadcast multiply-add
(✅ **VERIFIED** — `primitives/ios/rope.py:42-50`):

```python
def apply_rope(x: torch.Tensor, rope_cos: torch.Tensor, rope_sin: torch.Tensor) -> torch.Tensor:
    rope_cos = rope_cos.unsqueeze(1)
    rope_sin = rope_sin.unsqueeze(1)

    torch._check(len(rope_cos.shape) == 4)
    torch._check(len(rope_sin.shape) == 4)

    # Apply rotary position embedding
    return (x * rope_cos) + (rotate_half(x) * rope_sin)
```

Two further notes on `RoPECache`:

- **`_apply` is overridden** so that `.to(dtype)` *recomputes* the tables in the new dtype rather
  than casting them (`rope.py:74-86`). The comment: *"The `.to()` function implicitly calls into
  this function, and we should recompute the cos / sin rather than just do a simple cast."*
  Casting fp32 tables to fp16 loses precision that recomputing in fp16 does not. This is a real
  numerical difference and it is the kind of detail that separates a 70 dB port from a 45 dB one.
- **The default `base` is `500_000`**, not the 10 000 you may expect (`rope.py:65`). Llama-3-era
  models use large theta. Always read it from the source config —
  `models/ios/qwen3.py:192` calls `resolve_rope_theta(config)` rather than hardcoding.

> ⚠️ **SILENT FAILURE — M-RoPE reproduced approximately.**
> `common_issues.md:63-66`:
> > **Neural Engine M-RoPE PSNR very low (~18 dB)**
> > *"**Cause**: GPU M-RoPE pattern not reproduced exactly."*
> > *"**Fix**: Match `torch.cat([cos, cos], dim=-1)` then index with `::2`."*
>
> Multimodal RoPE variants have interleaving conventions that differ between implementations
> (GPT-NeoX-style half-rotation vs true interleaved). The two produce *statistically similar*
> outputs — same magnitudes, same distributions — and about 18 dB of agreement. Read the source
> implementation, do not assume. `rotate_half` in `primitives/ios/rope.py:11-19` documents which
> convention it implements: *"GPT NeoX style: rotates [repeat] half the hidden dims of the input."*

### 4.13 The read-only KV cache

This is the largest structural difference between the two targets, and Apple states the ANE side
as a hard rule (✅ **VERIFIED** — `neural_engine_rules.md:384-386`):

> ### KV cache — readonly pattern
>
> *"Neural Engine KV cache shape: `[n_layers, B, H_kv*D, 1, max_S]`, sequence on **dim 4**.
> Functional I/O (not buffer)."*
>
> *"**The model contains no KV writes.** Each call receives the full past cache, concatenates
> current K/V for attention, and returns new K/V tokens as outputs. Python updates the cache
> externally."*

Per-layer forward (`neural_engine_rules.md:390-395`):

```python
k_full = torch.cat([k_cache_layer, key_rope], dim=-1)
v_full = torch.cat([v_cache_layer, value], dim=-1)
# Attention uses k_full/v_full with causal mask
# Return key_rope and value as new_k/new_v outputs
```

Host-side update (`neural_engine_rules.md:400-404`):

```python
k_cache[layer_idx, :, :, :, t : t + S_q] = outputs["new_k"]
v_cache[layer_idx, :, :, :, t : t + S_q] = outputs["new_v"]
```

And Apple's own checklist, verbatim (`neural_engine_rules.md:420-426`):

> - [ ] *No `mutable_slice_update` / cache writes inside the model*
> - [ ] *`k_full = cat([k_cache, key_rope], dim=-1)`*
> - [ ] *Model returns `key_rope`/`value` as `new_k`/`new_v` outputs*
> - [ ] *Mask: strict `k < t+j` for past; causal `m <= j` for new*
> - [ ] *Python writes `new_k`/`new_v` → cache slots `[t : t+S_q]`*

> ⚠️ **SILENT FAILURE — caching the pre-RoPE key.**
> Apple marks this one **CRITICAL** in their own file, which they do nowhere else
> (✅ **VERIFIED** — `neural_engine_rules.md:397`):
>
> > *"**CRITICAL: return `key_rope`, not raw `new_k`.** If you cache pre-RoPE K, the next call
> > attends to stale non-RoPE-encoded keys → **PSNR collapses to ~20 dB**."*
>
> Why it is silent: the shapes are identical. `key` before RoPE and `key` after RoPE are the same
> tensor shape, same dtype, same magnitude range. Nothing anywhere will tell you which one you
> stored. The model generates fluent text with degraded long-range coherence. **This is arguably
> the single most expensive bug in this domain** because it only manifests at position > 1, so a
> single-token smoke test passes.
>
> **Detection:** generate ≥ 64 tokens and PSNR-compare against a torch reference that uses the same
> sampling seed. A model with pre-RoPE keys cached will track for a few tokens and then diverge.

> ⚠️ **SILENT FAILURE — stateful transforms silently reset.**
> `common_issues.md:146-148` and `gpu_rules.md:259`:
> > **Stateful transforms — KV cache resets between Python calls**
> > *"**Cause**: Stateful transform APIs mark buffers stateful within one invocation, but state
> > resets between inference calls."*
> > *"**Fix**: Use readonly KV I/O pattern. Pass caches as explicit inputs/outputs."*
>
> The symptom is a model that generates the same token forever, or that behaves as if every step
> were the first. It looks like a sampling bug. It is a state-lifetime bug.

**The other ANE cache pattern.** The shipped LLM path does *not* use the read-only pattern as
described; it uses `KVCacheHandler`, which does write in-place via `mutable_slice_update` and
receives the caches as `torch.export` **state**. ✅ **VERIFIED** —
`primitives/ios/cache.py:13-20, 156-174`:

```python
class KVCacheHandler:
    """
    KV Cache for iOS.

    For iOS, the layout of the KV cache is required to be different than on macOS.
    On iOS we must update on dim 4, whereas on macOS we use dim 3.
    The cache shape is: [n_layers, batch_size, n_kv_heads*head_dim, 1, max_seq_len]
    """
    ...
    begin, end = self.gen_slice_args(layer_idx, offset, num_token_updates)

    # update k - note that iOS updates on dimension 4 (the last dimension)
    mutable_slice_update(x=self._k_cache, update=k.unsqueeze(0), begin=begin, end=end)
    # update v - note that iOS updates on dimension 4 (the last dimension)
    mutable_slice_update(x=self._v_cache, update=v.unsqueeze(0), begin=begin, end=end)

    return self._k_cache[layer_idx], self._v_cache[layer_idx]
```

So there are **two** ANE cache patterns in Apple's material:

| | Read-only functional I/O | `KVCacheHandler` (state) |
| --- | --- | --- |
| Source | `neural_engine_rules.md:382-426` | `primitives/ios/cache.py`, used by `models/ios/{qwen2,qwen3,mistral}.py` |
| Cache writes in model | none | `mutable_slice_update`, in-place |
| Cache reaches the model as | explicit inputs, explicit `new_k`/`new_v` outputs | `key_cache`/`value_cache` arguments threaded to `register_kv_cache` |
| Host does | writes the returned tokens into its own arrays | nothing; the runtime owns the state |
| Shape | `[n_layers, B, H_kv*D, 1, max_S]` | identical |
| Sequence dim | 4 | 4 |

They agree on the shape and the sequence dim, and disagree on who owns the write.

> 🟡 **RECONSTRUCTED — when to use which.** Apple does not say. The observable facts: the shipped
> LLM export declares `key_cache`/`value_cache` as inputs and `new_k_cache`/`new_v_cache` as state
> outputs, so the exported iOS LLM is closer to the state pattern; the read-only pattern is what the
> skill teaches for hand-rolled models. **Safe default:** if you are exporting an LLM through
> `coreai_models.export.ios`, use `KVCacheHandler` — it is what the shipped `extend`/`prompt_opt`
> entrypoints expect. If you are hand-rolling a model and its Python driver, use the read-only
> pattern, because it is the one Apple's checklist covers and it has no state-lifetime failure mode
> at all.

### 4.14 Chunked prefill and fp16 drift

✅ **VERIFIED** — `neural_engine_rules.md:453-465`:

```python
CHUNK = 64
for chunk_start in range(0, prefill_len, CHUNK):
    S_q = min(CHUNK, prefill_len - chunk_start)
    mask = create_ane_causal_mask_readonly(S_q, max_seq_len, offset=chunk_start)
    # run model with chunk_embeds, mask, k_cache, v_cache
    k_cache[:, :, :, :, chunk_start : chunk_start + S_q] = new_k
    v_cache[:, :, :, :, chunk_start : chunk_start + S_q] = new_v
```

> ***Seam rule**: offset = `chunk_start`, not `chunk_end`.*
>
> ***fp16 drift warning**: Sequential per-token prefill (S_q=1 per call) accumulates fp16 rounding
> errors across many steps x many layers. For prefill > ~50 tokens, use chunked prefill (S_q=64) or
> fp32 KV cache tensors in Python.*

`common_issues.md:123-126` restates it as a diagnosis:

> **Neural Engine sequential q=1 decode diverges for long prefill**
> *"**Cause**: fp16 rounding errors compound across many sequential per-token passes."*
> *"**Fix**: Use chunked prefill (S_q=64) or fp32 KV cache tensors in Python."*

Two things to extract.

**The seam rule is a real off-by-one.** `offset = chunk_start` because the mask must describe where
this chunk's queries sit in absolute position space. Using `chunk_end` shifts every query by the
chunk length, which for chunk 0 (`chunk_start == 0`) is *invisible* — the first chunk is correct
either way — and then corrupts every subsequent chunk. A smoke test with a 32-token prompt and
`CHUNK=64` passes. A 200-token prompt does not. Classic.

**The fp32-KV-in-Python escape hatch is available because the cache lives outside the model.** This
is a genuine advantage of the read-only pattern that Apple does not spell out: since the host owns
the buffers, the host can hold them in fp32 and downcast only at the call boundary. You get fp32
accumulation across the sequence dimension without needing any fp32 support on the accelerator.

> **Community-measured, for calibration only** (`john-rocky/coreai-model-zoo`,
> `knowledge/compute-units-and-authoring.md`, single-author, uncontrolled): *"fp16 per-token decode
> drifts ~5–10 dB / 50 tokens."* No hardware or OS build attached. Consistent with Apple's
> "> ~50 tokens" threshold, which is presumably where they saw the same thing. Use it as an order of
> magnitude, not a specification.

**Why 64.** The iOS export path specialises on `query_lengths = [8, 16, 64]`
(✅ **VERIFIED** — `export/ios.py`, as captured in the corpus), so 64 is the largest prefill chunk
the shipped exporter compiles a function for. It is also a power of two ≥ 32, satisfying §4.3 for
the mask's innermost axis. If you build your own static-shape configuration, keep the chunk a power
of two and keep it ≥ 32.

### 4.15 Embedding decomposition and the `(V, 1, D)` table

✅ **VERIFIED** — `neural_engine_rules.md:263-275`:

> ### Embedding shape
>
> *"Neural Engine embeddings use shape `(vocab_size, 1, hidden_size)` to maintain BC1S-compatible
> output"*
>
> ```python
> class Embedding(nn.Module):
>     def __init__(self, vocab_size, hidden_size):
>         super().__init__()
>         self.weight = nn.Parameter(torch.zeros(vocab_size, 1, hidden_size))
>
>     def forward(self, input_ids: torch.Tensor) -> torch.Tensor:
>         return self.weight[input_ids]  # Returns (batch, 1, hidden_size)
> ```
>
> *"When loading from a source model: `embedding_weight = source_weight.unsqueeze(1)  # (V, D) → (V, 1, D)`"*

and the reason it is a *separate export* (`neural_engine_rules.md:432-447`):

> ### Model decomposition
>
> *"Neural Engine models typically separate the embedding table from the transformer body. **The
> embedding is exported separately because Neural Engine quantizes it independently and passes the
> table as an explicit input.**"*
>
> ```python
> class ModelForCausalLM(nn.Module):
>     def __init__(self, config):
>         self.embed_tokens = Embedding(config)   # Exported separately
>         self.extend = ModelExtend(config)       # Main export target
> ```

The shipped implementation confirms `(V, 1, D)` exactly, and adds the quantisation machinery
(✅ **VERIFIED** — `primitives/ios/embedding.py:30-54`, complete):

```python
class LoadEmbeddings(torch.nn.Module):
    def __init__(self, config, embedding_table_dtype=torch.int8):
        super().__init__()
        self.embedding_table = torch.nn.Parameter(
            torch.zeros(config.vocab_size, 1, config.hidden_size, dtype=embedding_table_dtype),
            requires_grad=False,
        )

    def forward(self):
        return self.embedding_table


class GatherEmbeddings(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.zero_point = nn.Parameter(torch.zeros([], dtype=torch.int8), requires_grad=False)
        self.scale = nn.Parameter(torch.ones([], dtype=torch.float16), requires_grad=False)

    def forward(self, input_ids: torch.Tensor, embedding_table: torch.Tensor) -> torch.Tensor:
        in_id_shape = input_ids.size()
        emb_shp = embedding_table.size()[1:]
        final_shape = in_id_shape + emb_shp
        if not embedding_table.is_floating_point():
            return fused_dequant_gather_reshape(embedding_table, input_ids, self.scale, final_shape)
        return embedding_table[input_ids]
```

with the fused op that makes it one node instead of three
(✅ **VERIFIED** — `primitives/ios/embedding.py:10-27`):

```python
@torch.library.custom_op("coreai::fused_dequant_gather_reshape", mutates_args=[])
def fused_dequant_gather_reshape(
    embedding_table: torch.Tensor,
    input_ids: torch.Tensor,
    scale: torch.Tensor,
    final_shape: list[int],
) -> torch.Tensor:
    return (embedding_table[input_ids].to(scale.dtype) * scale).reshape(final_shape)


@fused_dequant_gather_reshape.register_fake
def fused_dequant_gather_reshape_fake(embedding_table, input_ids, scale, final_shape):
    return torch.zeros(final_shape, dtype=scale.dtype)
```

Note what `LoadEmbeddings.forward()` does: it takes **no arguments** and returns the table. That is
because it becomes its own entrypoint in the compiled asset —
`LOAD_EMBEDDINGS_FUNCTION_NAME = "load_embeddings"` with signature `() -> embedding_table`
(✅ **VERIFIED** — `export/ios.py`). The four iOS entrypoints are:

| Constant | Name | Signature |
| --- | --- | --- |
| `LOAD_EMBEDDINGS_FUNCTION_NAME` | `load_embeddings` | `() -> embedding_table` |
| `GATHER_EMBEDDINGS_FUNCTION_NAME` | `gather_embeddings` | `(in_new_token_ids, embedding_table) -> gathered_embeddings` |
| `EXTEND_FUNCTION_NAME` | `extend` | decode: logits + updated KV |
| `PROMPT_OPT_FUNCTION_NAME` | `prompt_opt` | prefill: KV only, no logits |

(✅ **VERIFIED** — `export/ios.py`.) After static-shape specialisation these become
`extend_{ctx}_{len}`, `prompt_opt_{ctx}_{len}` and `gather_embeddings_{N}`, and
`neural_engine_rules.md:471-479` documents the same table with the note *"All functions compile from
**one dynamic `torch.export`** via Core AI shape specialization."* That last sentence is important:
you write one dynamic export and Core AI produces the whole matrix of static functions. You do not
write 30 models.

**Embedding quantisation is separate and coarser than everything else.** The shipped iOS models
quantise the embedding table to **int8 per-tensor, symmetric**
(✅ **VERIFIED** — `models/ios/qwen3.py:291-304` calling `quantize_per_tensor(..., nbits=8,
symmetric=True)` from `primitives/ios/quantization.py`, whose assert is
`assert nbits == 8, "Currently only supports quantizing to 8 bits"`), while the *weights* get 4-bit
palettisation. And the iOS palettisation presets explicitly **exclude** embedding modules
(✅ **VERIFIED** — `export/presets.py` excludes `torch.nn.modules.sparse.Embedding` and
`coreai_models.primitives.ios.embedding.LoadEmbeddings`).

`models/README.md:54` states the resulting behaviour: *"All `iOS` palettization presets quantize the
Embedding to 8-bit per tensor by default."* There is a CLI escape hatch —
`--disable-embedding-quantization-ios` — which the export tool rejects if you pass it with
`--platform macOS` (✅ **VERIFIED** — `llm/export.py`).

The `prefill_mode` trick is worth noting because it looks like dead code and is not
(✅ **VERIFIED** — `models/ios/qwen3.py:217-218`):

```python
if self.prefill_mode:
    return self.kv_cache.k_cache[0, 0, 0, 0, 0] + self.kv_cache.v_cache[0, 0, 0, 0, 0]
```

During prefill you need the KV cache populated but you do not need logits, and computing the LM head
over a 64-token chunk × 150 000-token vocabulary is enormous. So `prompt_opt` returns a **scalar** —
one element of each cache, summed — purely to give the graph an output and keep the cache writes
from being dead-code-eliminated. That is a real technique: when you need a side effect but not a
value, return something cheap that depends on the side effect.

### 4.16 Residency is the rule the other rules serve

Everything above exists to satisfy this one paragraph
(✅ **VERIFIED** — `neural_engine_rules.md:15`):

> ### Neural Engine residency
>
> *"For best inference performance, keep the entire model on Neural Engine. **Switching between
> accelerators (Neural Engine <-> GPU <-> CPU) introduces overhead that dominates small-model
> inference.** If an op cannot run on Neural Engine, the compiler segments the graph and inserts
> transfers. Use the `working-with-coreai` skill to compile and check residency, then re-author
> those ops using Neural Engine-compatible alternatives."*

Read "dominates small-model inference" precisely. It does not say the transfers are expensive
relative to the op — it says they are expensive relative to **the whole model**. For a 600M-parameter
model doing single-token decode, the compute per layer is small enough that two accelerator
transitions can cost more than the entire forward pass. Which means:

> **A single unsupported op in the middle of an otherwise perfect ANE model can be worse than not
> targeting the ANE at all.** You pay the BC1S authoring cost, the per-head attention cost, the
> static-shape cost — and then hand the tensor to the GPU twice per layer anyway.

This is the reason the fp32-literal rule (§4.2) is not pedantry. `x * (1.0 + scale)` in one
normalisation layer, repeated across 28 layers, is 56 accelerator transitions per forward pass.

**Checking residency.** The mechanism Apple points at is AOT compilation
(✅ **VERIFIED** — `common_issues.md:109-112`):

> **Neural Engine model compiles but runs on CPU**
> *"**Cause**: Model was compiled without Neural Engine preference (e.g., using default compute
> selection which routed to CPU/GPU)."*
> *"**Fix**: Compile with `xcrun coreai-build compile model.aimodel --preferred-compute neural-engine`."*

and the base invocation (✅ **VERIFIED** — `working-with-coreai/SKILL.md:99`):

```bash
xcrun coreai-build compile model.aimodel --platform iOS
```

> 🔴 **GAP — `coreai-build`'s residency report. Narrowed 2026-07-31.**
> Apple's skill says *"compile and check residency"* but **no source in this corpus shows what the
> residency output looks like on a real asset** — not the format, not whether it is per-op or
> per-segment. Session 325 does not cover `coreai-build` at all. The `--help` run this box used to
> ask for has now happened: the wrapper turned out to ship in the optional **Metal Toolchain
> component** (`xcodebuild -downloadComponent MetalToolchain`), not Xcode-beta.app — which is what
> the 2026-07-29 "absent from the beta toolchain" check was actually seeing — and the full surface
> is captured in `notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`. The residency-shaped
> surface it reveals: **`coreai-build inspect --compute`** (*"Show compute types"*, off by
> default) and `inspect --ops` (operation distribution), with `--json` output. **What would still
> resolve it:** that inspect output captured on a real compiled asset, or the Apple doc page
> *"Compiling Core AI models ahead of time"* at
> `developer.apple.com/documentation/coreai/compiling-core-ai-models-ahead-of-time`.
> **Safe default meanwhile:** use the **Core AI Debugger** instead. It is a standalone app
> (`developer.apple.com/core-ai-debugger/`) that, per session 325, *"executes your model on specific
> hardware for true runtime results"* and *"the structure viewer has updated to show me the model,
> exactly as it would run on my Mac."* A model that has been segmented shows up there as a changed
> graph. Failing that, `coreai_torch.debugging.benchmarker.benchmark_coreai_program` gives per-module
> timings, and a segmentation point shows up as an implausibly expensive layer.

**The `--preferred-compute` default is `none`.** Now ✅ **tool-verified** (2026-07-31,
`coreai-build compile --help`, `notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`): values
`{gpu, neural-engine, none}`, default `none`. The community report had it right
(`john-rocky/coreai-model-zoo`, `knowledge/compute-units-and-authoring.md:115-127`): AOT
`--preferred-compute` *"defaults to `none`(compiler decides), and a 'compiles but runs on CPU' case
needs an explicit `--preferred-compute neural-engine`."* Apple's own `common_issues.md:109-112`
entry says the same thing from the symptom end. Treat the default as "the compiler will choose, and
it may choose wrong."

**The other lever is runtime specialisation**, and it is the one the Swift runtime actually uses.
See §8 — it turns out to be driven by the *names of the functions in your asset*, which is not
where anybody looks first.

---

## 5. The GPU rules

`gpu_rules.md` is 297 lines to `neural_engine_rules.md`'s 479, and that ratio is the point: the GPU
ruleset is smaller because the GPU accepts standard PyTorch. Most of what is in the file is not
"you must" but "here is how to go faster."

Apple's opening line sets the scope
(✅ **VERIFIED** — `gpu_rules.md:3`):

> # GPU / CPU Rules
>
> *"The same authoring principles apply to both GPU and CPU. GPU uses standard PyTorch tensor
> layouts; CPU is used for correctness testing before compilation."*

### 5.1 Standard layout, `nn.Linear`, fp32 where you need it

✅ **VERIFIED** — `gpu_rules.md:11-18`:

| Tensor | Shape |
| --- | --- |
| Hidden states | `(B, S, D)` or `(B, D)` |
| Multi-head | `(B, H, S, D)` |

> *"Use `nn.Linear` for all projections. No weight reshape needed."*

and on precision (`gpu_rules.md:40-48`):

> ### Float16
>
> *"Use float16 weights for models that may run on GPU/CPU on-device"*
>
> ```python
> model = model.half().eval()
> inputs = {k: v.astype(np.float16) for k, v in inputs.items()}
> ```
>
> *"**Use fp32 intermediates selectively for numerical stability in sensitive operations
> (normalization, attention scores).**"*

That last sentence is the exact inversion of §4.2. On the ANE an fp32 intermediate is a residency
bug; on the GPU it is a numerical-stability tool that you deploy deliberately at the two places
fp16 is weakest — variance accumulation in normalisation, and pre-softmax attention scores.

The shipped macOS `RMSNormGated` does exactly this
(✅ **VERIFIED** — `primitives/macos/rms_norm.py:48-55`):

```python
def forward(self, x: torch.Tensor, gate: torch.Tensor | None = None) -> torch.Tensor:
    """Apply RMSNorm, optionally with SiLU gating."""
    input_dtype = x.dtype
    x = self._rmsnorm_impl(x, self.weight)
    if gate is not None:
        x = x * torch.nn.functional.silu(gate.to(torch.float32))
        x = x.to(input_dtype)
    return x
```

`gate.to(torch.float32)` inside the forward. On the ANE that single line would break residency for
the whole block. On the GPU it is the correct thing to do.

**Activation functions.** Apple's warning here is not about the hardware, it is about you
(✅ **VERIFIED** — `gpu_rules.md:24-34`):

> *"Always verify the source activation type before re-authoring"*
>
> ```python
> for name, mod in source_model.named_modules():
>     if hasattr(mod, "act") or "activation" in name.lower():
>         print(name, type(mod))
> ```
>
> *"Common types: `nn.SiLU`, `nn.GELU`, `QuickGELU`, `SwiGLU`. They are **not interchangeable** —
> wrong activation gives PSNR ~20-30 dB."*
>
> *"GPU supports all standard PyTorch activation functions natively."*

⚠️ Another silent one: substituting GELU for SiLU produces a model that trains-like, looks-like and
runs-like the original and is 20–30 dB off. `common_issues.md:166-169` lists it as its own entry.
Run the loop above. It takes four seconds.

### 5.2 Fused QKV, and fused QK-norm + RoPE

✅ **VERIFIED** — `gpu_rules.md:133-154`:

> ### Fused QKV projection
>
> *"Combine separate Q, K, V projections into a single `nn.Linear` for reduced memory bandwidth"*
>
> ```python
> self.qkv_proj = nn.Linear(
>     dim,
>     n_heads * head_dim + 2 * n_kv_heads * head_dim,  # Q + K + V
>     bias=False,
> )
> ```
>
> *"State dict mutation concatenates the three weight tensors"*
>
> ```python
> q_weight = state_dict[f"layers.{i}.self_attn.q_proj.weight"]
> k_weight = state_dict[f"layers.{i}.self_attn.k_proj.weight"]
> v_weight = state_dict[f"layers.{i}.self_attn.v_proj.weight"]
> state_dict[f"layers.{i}.self_attn.qkv_proj.weight"] = torch.cat(
>     [q_weight, k_weight, v_weight], dim=0
> )
> ```

Concatenation on `dim=0` — the output-feature axis — so the fused weight is
`[(H + 2·H_kv)·hd, D]`. The ordering Q, K, V is a contract between this mutation and the `narrow`
calls that split it back apart; get them out of sync and you have silently permuted your heads.

And the step beyond (✅ **VERIFIED** — `gpu_rules.md:158-170`):

> ### Fused Q/K normalization + RoPE
>
> *"After the fused QKV projection, apply normalization and RoPE to the combined Q+K slice before
> splitting — this reduces kernel launches"*
>
> ```python
> qkv = self.qkv_proj(x)
> query_key = qkv.narrow(-1, 0, (n_heads + n_kv_heads) * head_dim)
> query_key = self.qk_norm(query_key)
> query_key = self.rope(query_key, position_ids=position_ids)
> query = query_key.narrow(-1, 0, n_heads * head_dim)
> key = query_key.narrow(-1, n_heads * head_dim, n_kv_heads * head_dim)
> value = qkv.narrow(-1, (n_heads + n_kv_heads) * head_dim, n_kv_heads * head_dim)
> ```

This is the clearest single illustration of the two philosophies. The ANE version of the same block
(§4.6) is three separate `Conv2d`s, two separate `RMSNorm`s, two separate `apply_rope` calls and
eight transposes. The GPU version is one `Linear`, one norm, one RoPE and three `narrow`s — where
`narrow` is a **view**, not a copy.

The reason the ANE cannot do this: `qk_norm` normalises over `head_dim`, and in the fused layout
`head_dim` is a stride within a larger last axis. On the GPU that is a cheap reshape-and-reduce. On
the ANE it would be a reshape touching the innermost axis — the expensive kind (§4.4) — repeated
per layer.

### 5.3 Native fused SDPA

✅ **VERIFIED** — `gpu_rules.md:53-65`:

> ### Native SDPA
>
> *"GPU uses fused scaled dot-product attention — a single call processes all heads in parallel"*
>
> ```python
> attn_output = F.scaled_dot_product_attention(
>     query,
>     key,
>     value,
>     attn_mask=mask,
>     is_causal=is_causal,
> )
> ```
>
> *"This is the opposite of Neural Engine, where each head must be computed individually. On GPU,
> fused SDPA is both simpler to author and faster to execute."*

Two supporting facts from elsewhere in the toolchain:

- **`scaled_dot_product_attention.default` is one of exactly three ops that `get_decomp_table()`
  deliberately preserves** (✅ **VERIFIED** — `coreai-torch` `docs/api/supported-aten-ops.md`; the
  others are `instance_norm.default` and `pixel_shuffle.default`). So the fused call survives
  `run_decompositions` as a named composite rather than being shredded into matmuls and a softmax.
- **The macOS `SDPA` primitive is a `coreai_torch.composite_ops.SDPA` subclass**
  (✅ **VERIFIED** — `primitives/macos/sdpa.py:13`) carrying `scale`, `is_causal` and `window_size`,
  and the macOS export lists it in `_EXTERNALIZE_SPECS` with composite name
  `scaled_dot_product_attention` and attributes `["scale", "is_causal", "window_size"]`
  (✅ **VERIFIED** — `export/macos.py`). That is what makes the composite reach the compiler intact.

> ⚠️ **SILENT FAILURE — fused SDPA falling back without a warning.**
> If your attention call does not match the pattern the composite expects — an unusual mask dtype,
> a mask shape the kernel does not accept, an unsupported `enable_gqa` combination — PyTorch's own
> dispatcher silently selects the math backend, which then decomposes into matmul + softmax, which
> then converts as matmul + softmax. You lose the fused kernel and nothing tells you. **Detection:**
> after conversion, inspect the Core AI program for a `scaled_dot_product_attention` composite node.
> If it is not there, the fusion did not survive.

### 5.4 MLP operation ordering: up before gate

✅ **VERIFIED** — `gpu_rules.md:174-185`:

> ### MLP operation ordering
>
> *"Compute `up_proj` before `gate_proj` for better GPU throughput"*
>
> ```python
> def forward(self, x: torch.Tensor) -> torch.Tensor:
>     up_tensor = self.up_proj(x)                 # up first
>     gate_tensor = F.silu(self.gate_proj(x))     # gate second
>     return self.down_proj(up_tensor * gate_tensor)
> ```
>
> *"**This ordering is reversed from many reference implementations** but yields better GPU
> utilization."*

The shipped macOS MLP does exactly this, with the rationale in a comment
(✅ **VERIFIED** — `primitives/macos/mlp.py:35-39`):

```python
def forward(self, x: torch.Tensor) -> torch.Tensor:
    # Note: we compute the up projection before the gate projection
    # in order to get better performance on macOS
    up_tensor = self.up_proj(x)
    gate_tensor = nn.functional.silu(self.gate_proj(x))
    return self.down_proj(up_tensor * gate_tensor)
```

And so does the iOS one (`primitives/ios/mlp.py:40-42`) — the ordering is target-independent, it is
just less consequential on the ANE.

This is mathematically a no-op (the product is commutative) and a real scheduling difference: issuing
the un-activated projection first lets it start while the activation of the other is still in flight.
It costs nothing to adopt. Note Apple's own warning that it is *reversed from many reference
implementations* — if you are diffing against Hugging Face, this line will differ and that is
correct.

### 5.5 RMSNorm variants

✅ **VERIFIED** — `gpu_rules.md:69-76`:

> *"GPU supports standard RMSNorm and also richer variants that may not map cleanly to Neural
> Engine:"*
>
> - ***RMSNormPlusOne**: `weight + 1.0` offset (used by Gemma3, some Qwen variants)*
> - ***RMSNormGated**: Applies SiLU gating after normalization*
>
> *"On GPU, implement these directly as the source model defines them."*

The shipped `RMSNormPlusOne` (✅ **VERIFIED** — `primitives/macos/rms_norm.py:24-34`):

```python
class RMSNormPlusOne(RMSNorm):
    """
    RMSNorm variant where 1.0 is added to the scaling weight during the forward pass.
    Used by Gemma3.
    """

    def forward(self: Self, x: torch.Tensor) -> torch.Tensor:
        """Apply RMSNorm with +1.0 offset to the weight."""
        # .float() matches HuggingFace transformers numerics for parity testing
        weight_plus_one = self.weight.float() + 1.0
        return self.rmsnorm_impl(x, weight_plus_one)
```

Look at that `.float()` and its comment. On the GPU, matching HuggingFace's fp32 promotion is worth
doing *because it makes your parity test meaningful*. On the ANE the same line is a residency
break — and community reporting says it would be a **no-op** there anyway
(**community-measured**, `john-rocky/coreai-model-zoo`: *"`.float()` is a no-op on the ANE (MPSGraph
drops the cast)"*). Same three characters; useful on one target, harmful-or-inert on the other. This
is the guide's thesis in miniature.

`RMSNormPlusOne` and `RMSNorm` are also both in the macOS compression **exclusion** list —
`_TORCH_MODULE_EXCLUSIONS` maps
`coreai_models.primitives.macos.rms_norm.RMSNorm`,
`…rms_norm.RMSNormPlusOne`, `…sdpa.SDPA` and `…rope.RoPE` to `None`, meaning "do not quantise"
(✅ **VERIFIED** — `export/presets.py`). Norms, RoPE and attention are never weight-compressed. Worth
knowing before you write a custom compression config that catches them.

### 5.6 The stateful KV cache export wrapper

✅ **VERIFIED** — `gpu_rules.md:189-195`:

> ### KV cache
>
> *"Shape `[n_layers, B, H_kv, max_S, D]`, sequence on **dim 3**. Module buffer."*
>
> *"For `torch.export`, wrap in a model class that registers KV cache buffers as explicit module
> inputs/outputs so they appear in the exported graph signature."*
>
> *"**Cache mutation via `mutable_slice_update`**: The macOS KV cache uses a custom op
> (`coreai::mutable_slice_update`) to thread in-place mutation through `torch.export`. Its eager
> implementation mutates the cache tensor in-place; its meta/fake implementation returns a new
> tensor of the same shape, making it compatible with export's functional semantics."*

That last sentence describes the whole trick. `torch.export` is functional; a cache is not. The
resolution is a custom op whose *real* implementation mutates and whose *fake* implementation
pretends to be pure. The exporter traces the fake, so the graph is functional; the runtime executes
the real one, so the cache actually updates.

The wrapper Apple prescribes (✅ **VERIFIED** — `gpu_rules.md:231-255`):

```python
import torch
import torch.nn as nn


class ExportableDecoderModel(nn.Module):
    def __init__(self, decoder, n_layers, n_kv_heads, max_seq_len, head_dim):
        super().__init__()
        self.decoder = decoder
        self.register_buffer(
            "_full_cached_k",
            torch.zeros(
                n_layers, 1, n_kv_heads, max_seq_len, head_dim, dtype=torch.float16
            ),
            persistent=False,
        )
        self.register_buffer(
            "_full_cached_v",
            torch.zeros(
                n_layers, 1, n_kv_heads, max_seq_len, head_dim, dtype=torch.float16
            ),
            persistent=False,
        )

    def forward(self, inputs_embeds, position_ids):
        return self.decoder(
            inputs_embeds, position_ids, self._full_cached_k, self._full_cached_v
        )
```

Those buffer names are not decorative: the shipped `KVCache` class declares them as constants
(✅ **VERIFIED** — `primitives/macos/cache.py`): `HF_K_BUFFER_NAME = "_full_cached_k"`,
`HF_V_BUFFER_NAME = "_full_cached_v"`, alongside `seq_len_dim() -> 3` and a
`create_cache_tensors(config, dtype)` classmethod producing
`(n_layers, 1, n_kv_heads, max_seq_len, head_dim)`. And the macOS export declares
`state_names = ("keyCache", "valueCache")` (✅ **VERIFIED** — `export/macos.py`), which is what the
Swift runtime looks for.

> 🔴 **GAP — `LegalizeToCoreOptions(mutable_arg_action="hoistToArg")`.**
> `gpu_rules.md:82` and `gpu_rules.md:257` both say: *"For GPU, use `mutable_arg_action="hoistToArg"`
> in `LegalizeToCoreOptions`. This converts mutable weights to function arguments with defaults,
> appropriate for GPU/CPU."* `SKILL.md:130` repeats it.
>
> **This symbol appears nowhere else.** Grepped across `apple/coreai-torch` (source, docs and all
> notebooks) and `apple/coreai-models` (all Python): zero hits outside the three skill mentions. It
> is not in `docs/api/TorchConverter.md` (504 lines). Apple's own shipped macOS export path does not
> call it — it uses `add_pytorch_module(..., state_names=("keyCache", "valueCache"))` instead.
>
> **What would resolve it:** the `coreai` Python API reference at
> `apple.github.io/coreai-torch/main/coreai-core`, or `dir(coreai.authoring)` against
> `coreai-core 1.0.0b2`.
> **Safe default meanwhile:** follow the shipped path, not the skill. Use
> `TorchConverter().add_pytorch_module(model, export_fn=…, state_names=("keyCache", "valueCache"))`
> as `export/macos.py` does. Do not write `LegalizeToCoreOptions` into your code on the strength of
> a skill file; if the option exists, the shipped exporter demonstrably does not need it.

### 5.7 MoE via `SwitchLinear` and `GatherMM`

✅ **VERIFIED** — `gpu_rules.md:265-275`:

> ### Mixture of Experts (MoE)
>
> - ***`SwitchLinear`**: A single weight tensor of shape
>   `(num_weight_sets, num_experts, output_dims, input_dims)` holding all experts. At inference time,
>   takes indices of selected experts and performs batched gather + matmul in one operation via
>   `coreai_torch.composite_ops.GatherMM`.*
> - ***`SwitchGLU`**: Combines three `SwitchLinear` layers (gate, up, down) with SwiGLU activation
>   for MoE MLP blocks.*
> - ***Routing**: Standard `nn.Linear` gate + softmax + top-k selection to choose active experts per
>   token. **Expert indices are typically cast to `uint16`** before passing to GatherMM.*
> - ***State dict mutation for MoE**: HuggingFace stores per-expert weights separately (e.g.,
>   `experts.0.gate_proj.weight`). At load time, stack them into the `(1, num_experts, out, in)`
>   shape expected by `SwitchLinear`.*

All four confirmed in the shipped code (✅ **VERIFIED**):

```python
# primitives/macos/switch.py:12-31
class SwitchLinear(torch.nn.Module):
    def __init__(self, input_dims, output_dims, num_weight_sets, num_experts, bias=True):
        super().__init__()
        self.gather_mm = coreai_torch.composite_ops.GatherMM(num_batch_axes=1)
        rand_weight = torch.rand(*(num_weight_sets, num_experts, output_dims, input_dims))
        self.weight = torch.nn.Parameter(rand_weight)
        ...
```

```python
# models/macos/qwen3_moe.py:130-142 — routing, and the uint16 cast
if self.norm_topk_prob:
    top_logits, active_experts_indices = torch.topk(
        router_logits, self.top_k, dim=-1, largest=True
    )
    active_experts_scores = torch.softmax(top_logits, dim=-1)
else:
    gates = torch.softmax(router_logits, dim=-1)
    active_experts_scores, active_experts_indices = torch.topk(
        gates, self.top_k, dim=-1, largest=True
    )
active_experts_indices = active_experts_indices.to(torch.uint16)

y_active_experts = self.switch_mlp(x, active_experts_indices)
```

Two shipped details the skill omits, both worth having.

**The 4-D expert weight needs its own compression config.** The macOS 4-bit preset's global spec is
`per_block` with `block_size=32, axis=1`, which cannot express a 4-D
`[num_weight_sets, num_experts, output_dims, input_dims]` tensor. So `export/presets.py` carries a
`SwitchLinear`-specific override with `block_size=[1, 1, 1, 32], axis=None`, and a comment saying
precisely that (✅ **VERIFIED** — `export/presets.py`). It also notes the override is *"safe on
non-MoE models (no `SwitchLinear` instances → no-op)"*. If you write your own compression config for
an MoE model and forget this, you will get a shape error or, worse, a silently mis-blocked
quantisation.

**`eager_chunk_size` is export-hostile on purpose.** `SwitchGLU` has an optional token-chunking path,
guarded by a comment that is a good lesson in itself
(✅ **VERIFIED** — `primitives/macos/switch.py:81-85`):

> *"Eager-only optimization. When set, tokens are processed in chunks of this size to bound the peak
> GatherMM intermediate. **Left None for export/production so the traced graph carries no
> data-dependent control flow on the token dimension.**"*

Data-dependent control flow is fine in eager PyTorch and poison for `torch.export`. Keeping the
optimisation opt-in and off-by-default is the right shape for that trade.

> **Community-measured, and genuinely surprising** (`john-rocky/coreai-model-zoo`,
> `knowledge/compute-units-and-authoring.md`, single-author, uncontrolled, 2026-06): *"`GatherMM`
> gathers then runs a DENSE matmul — it does NOT read only the routed experts, so MoE decode is
> over-read-bound, not active-param-bound."* Measured consequence on LFM2.5-8B-A1B, M4 Max: int8
> 39 tok/s at 8.8 GB versus int4 **170 tok/s** at 5.0 GB — a ~4× speedup from a 2× byte reduction,
> which the same source reads as evidence that the int4 path is *not* full-reading. The same author
> reports a hand-written `gather_qmm` Metal kernel reaching 141 tok/s at int8.
>
> **Attribute this carefully.** It is one person's benchmark on one machine with no published
> harness. But the *architectural* claim — that `GatherMM` is a gather followed by a dense matmul —
> is checkable against `coreai_torch.composite_ops._gather_mm` and matters for capacity planning.
> And it is a GPU-only escape hatch: writing your own gather-matmul kernel is exactly the lever that
> does not exist on the Neural Engine.

### 5.8 Memory-efficient weight loading

✅ **VERIFIED** — `gpu_rules.md:279-297`:

> *"For large models (7B+), avoid holding both the source HuggingFace model and the re-authored model
> in RAM simultaneously"*
>
> **Meta-device initialization** — *"Allocate the model structure without any memory"*:
> ```python
> model = MyReauthoredModel(config, device="meta")
> ```
>
> **Assign-mode loading** — *"Load weights directly into the model without copying"*:
> ```python
> model.load_state_dict(mutated_state_dict, assign=True)
> ```
>
> **Streaming one layer at a time** — *"open safetensors files directly, process one layer's weights
> (mutate state dict keys, reshape for Conv2d or fuse QKV), load that layer, then move to the next.
> **Peak RAM is roughly one layer rather than the full model.**"*

The shipped implementation is `BaseForCausalLM.from_hf_memory_efficient`, with helpers
`move_model_to_disk`, `_save_and_mmap_safetensors`, `_resolve_safetensors_files`,
`_build_safetensors_key_index` and `_load_tensors_for_keys`
(✅ **VERIFIED** — `models/base.py`).

And here is the asymmetry that tells you the state of the toolchain
(✅ **VERIFIED** — `export/pipeline.py`, with Apple's own comment):

- **macOS export** uses `model_class.from_hf_memory_efficient(...)` with a
  `tempfile.TemporaryDirectory(prefix="coreai_export_")` mmap directory.
- **iOS export** uses plain `from_hf(...)` — full RAM — because, in the comment's words,
  *"the iOS variant keeps the legacy full-RAM path since its palettization flow has not been
  validated against streaming weight loading."*

So exporting a large model for iOS currently needs enough host RAM to hold the whole thing twice.
That is a **host-side** constraint, not a device one, and it is a temporary implementation gap, but
plan for it: a 4B model in fp16 plus its re-authored copy is roughly 16 GB before you start
palettising.

### 5.9 Masks and precomputed buffers

✅ **VERIFIED** — `gpu_rules.md:210-223`:

> ### Positional embeddings
>
> *"Precompute everything that does not depend on input values as a model buffer"*
>
> ```python
> # BAD — recomputes trig per token
> rotary = MRoPEEmbedding(config).eval()
> gpu_cos, gpu_sin = rotary(embed_t.float(), pos_ids)
>
> # GOOD — single buffer slice, no compute
> cos, sin = model.get_cos_sin(pos, seq_len=1, dtype=torch.float16)
> ```
>
> *"Register as `register_buffer("cos_table", ..., persistent=True)` in `__init__`. Slice at
> runtime."*

This is one rule the two targets agree on, for different reasons: on the GPU it saves kernel
launches, on the ANE it is mandatory because in-graph gather produces the wrong rank (§4.12). When
two opposite rulesets agree, adopt the rule unconditionally.

Note `persistent=True` here versus `persistent=False` on the KV cache buffers in §5.6. Positional
tables are derived from config and are cheap to recompute but should travel with a checkpoint; KV
caches are runtime scratch and must not be serialised. Get this backwards and your checkpoints
gain a `max_seq_len × n_layers × …` tensor of zeros.

### 5.10 A note on directory layout and state-dict discipline

Small, and it will save you an afternoon. ✅ **VERIFIED** — `gpu_rules.md:108-126`:

```plaintext
model_dir/
├── primitives.py      ← RMSNorm, RoPE, Attention, MLP
├── decoder_layer.py   ← DecoderLayer = primitives + KV cache wiring
└── full_model.py      ← embed + all layers + lm_head
```

> *"Print source keys before writing any remap — **do not guess**"*
>
> ```python
> sd = source_model.state_dict()
> for k in sorted(sd.keys()):
>     print(k, sd[k].shape)
> ```

`common_issues.md:173-176` has the matching failure entry: *"**State dict key mismatch during weight
loading** — Cause: Re-authored model uses different attribute names. Fix: Print source state dict
keys before writing remap."*

Guessing key names is the most common way to lose an hour, and PyTorch will not always tell you:
`load_state_dict(..., strict=False)` swallows the mismatch and leaves your layer at its random
initialisation. Which is, of course, another silent failure — a model that converts, runs and
produces noise from one layer onward.

---

## 6. Apple's authoring workflow

The rules tell you what to write. This section tells you in what order, and how to know you got it
right. It is short and it is the highest-value part of the skill.

### 6.1 Phase 1 — architecture discovery: run code, don't read code

✅ **VERIFIED** — `SKILL.md:74-80`:

> ### Phase 1: Architecture discovery
>
> ***Run code, don't read code. Running gives ground truth instantly.***
>
> 1. *Print model structure and state dict keys with shapes*
> 2. *Trace forward pass with `register_forward_hook` — capture intermediates*
> 3. *Document target hardware, IO boundary, module hierarchy, activation type, KV cache layout*

"Run code, don't read code" is the correct instinct and worth defending. Modern Hugging Face model
files are 2,000 lines of configurable branches; the branch that executes for *your* checkpoint's
config is a small fraction of it, and reading the file will teach you about six variants you do not
have. Instantiating the model and printing what actually happens is faster and cannot be wrong.

Here is a complete discovery harness implementing all three steps. This is not quoted from Apple —
Apple gives the three bullets and the `named_modules` snippet — but every piece of it is assembled
from techniques Apple's files prescribe:

```python
"""Architecture discovery for a model you are about to re-author.

Run this FIRST. Paste the output into your notes. Do not start writing
primitives until every line of the summary is filled in.
"""

from __future__ import annotations

import torch
from transformers import AutoConfig, AutoModelForCausalLM

MODEL_ID = "Qwen/Qwen3-0.6B"

config = AutoConfig.from_pretrained(MODEL_ID)
model = AutoModelForCausalLM.from_pretrained(MODEL_ID, dtype=torch.float32).eval()

# --- 1. Structure and state dict -------------------------------------------
print("=== module tree ===")
print(model)

print("\n=== state dict ===")
sd = model.state_dict()
for k in sorted(sd):
    print(f"{k:60s} {tuple(sd[k].shape)}  {sd[k].dtype}")

# --- 1b. Activation types (gpu_rules.md:26-30) -----------------------------
print("\n=== activations ===")
for name, mod in model.named_modules():
    if hasattr(mod, "act") or "activation" in name.lower() or "act_fn" in name.lower():
        print(f"{name:60s} {type(mod)}")

# --- 2. Intermediates via forward hooks ------------------------------------
captured: dict[str, tuple] = {}


def _hook(name: str):
    def fn(_module, _inputs, output):
        t = output[0] if isinstance(output, tuple) else output
        if isinstance(t, torch.Tensor):
            captured[name] = (tuple(t.shape), t.dtype, float(t.abs().max()))
    return fn


handles = [m.register_forward_hook(_hook(n)) for n, m in model.named_modules() if n]

with torch.no_grad():
    model(input_ids=torch.randint(0, config.vocab_size, (1, 8)))

for h in handles:
    h.remove()

print("\n=== intermediates (shape, dtype, max|x|) ===")
for name, info in captured.items():
    print(f"{name:60s} {info}")

# --- 3. The summary you must be able to fill in ----------------------------
print(f"""
=== summary to record ===
target hardware      : <Neural Engine | GPU | CPU>
IO boundary          : inputs {{...}} -> outputs {{...}}
module hierarchy     : <depth, repeated block name, layer count>
activation type      : <SiLU | GELU | QuickGELU | SwiGLU>  (from the section above)
KV cache layout      : <shape, seq dim, who writes>
n_layers             : {config.num_hidden_layers}
hidden_size          : {config.hidden_size}
n_heads / n_kv_heads : {config.num_attention_heads} / {getattr(config, "num_key_value_heads", "?")}
head_dim             : {getattr(config, "head_dim", None) or config.hidden_size // config.num_attention_heads}
rope_theta           : {getattr(config, "rope_theta", "?")}
tie_word_embeddings  : {getattr(config, "tie_word_embeddings", "?")}
""")
```

The `max|x|` column is not decorative. It is your fp16 overflow early-warning system: any
intermediate whose maximum magnitude approaches 65 504 will overflow when you cast to fp16, and
you want to know that before you spend a day on PSNR archaeology.

One config trap worth pre-empting, since it will bite during discovery rather than authoring
(✅ **VERIFIED** — `common_issues.md:70-91`):

> **HF model fails during `post_init()` — missing `rope_parameters`**
> *"**Fix**: Patch `ROPE_INIT_FUNCTIONS` before instantiation"*

```python
from transformers.modeling_rope_utils import ROPE_INIT_FUNCTIONS

if "default" not in ROPE_INIT_FUNCTIONS:

    def _default_rope(config=None, device=None, seq_len=None, **kwargs):
        head_dim = (
            getattr(config, "head_dim", None)
            or config.hidden_size // config.num_attention_heads
        )
        base = getattr(config, "rope_theta", 10000.0)
        inv_freq = 1.0 / (
            base ** (torch.arange(0, head_dim, 2, dtype=torch.float) / head_dim)
        )
        return inv_freq, 1.0

    ROPE_INIT_FUNCTIONS["default"] = _default_rope
```

Note also `head_dim` specifically: Apple's `KVCacheHandler` has a comment about it that is a
generally useful piece of `transformers` lore (✅ **VERIFIED** — `primitives/ios/cache.py:28-32`):

> *"Some HF configs (e.g. recent `MistralConfig`) declare `head_dim` but leave it as None when not
> explicitly set. `getattr`'s default only fires when the attribute is missing, not when it
> exists-but-is-None, so we use `or` to fall back in both cases."*

```python
head_dim = getattr(config, "head_dim", None) or (dim // n_heads)
```

Use the `or` form everywhere. `getattr(config, "head_dim", dim // n_heads)` returns `None` on those
configs and you get a `TypeError` three files away.

### 6.2 Phase 2 — bottom-up authoring

✅ **VERIFIED** — `SKILL.md:82-90`:

> ### Phase 2: Primitive implementation (bottom-up)
>
> *"Author in this order — each depends on the previous:"*
>
> 1. ***Norm** — layout and weight shape depend on target*
> 2. ***Linear projections** — Conv2d(in, out, 1) for Neural Engine; nn.Linear for GPU*
> 3. ***Attention** — layout, K@Q convention, causal mask depend on target*
> 4. ***MLP / FFN** — activation must match source exactly*
> 5. ***Full decoder block** — compose primitives with KV cache wiring*

and the discipline that makes the order pay off (`SKILL.md:101`):

> *"**Verify each primitive individually before composing the full model.** Also compare the full
> re-authored model's outputs against a baseline export (direct from HuggingFace without
> re-authoring) — both in Python and after compilation on device — to confirm end-to-end parity."*

Why this order and not any other: each step's *failure* is diagnosable in isolation, and each
step's output is the next step's input. Norm first because it is the smallest thing with a
layout-dependent weight shape, so it is where you discover you got the layout wrong while the fix
costs three lines. Attention third because it depends on both the projections and the norm.
The full block last because by then every failure you see is a wiring failure.

The inverse — writing the whole decoder block and then PSNR-ing it — gives you one number, in the
teens, with 40 candidate causes.

### 6.3 The factory classmethod convention

✅ **VERIFIED** — `SKILL.md:105-119` and `gpu_rules.md:90-106`:

> ### The `from_source_model` classmethod
>
> *"Every re-authored model gets a factory classmethod — **no hardcoded constants**"*
>
> ```python
> @classmethod
> def from_source_model(cls, source_model) -> "GPUDecoder":
>     cfg = source_model.config
>     model = cls(
>         n_layers=cfg.num_hidden_layers,
>         hidden=cfg.hidden_size,
>         n_heads=cfg.num_attention_heads,
>         n_kv_heads=cfg.num_key_value_heads,
>         head_dim=getattr(cfg, "head_dim", cfg.hidden_size // cfg.num_attention_heads),
>         intermediate=cfg.intermediate_size,
>         max_seq_len=cfg.max_position_embeddings,
>         vocab_size=cfg.vocab_size,
>     )
>     model.load_weights_from(source_model.state_dict())
>     return model
> ```

The principle — **every dimension comes from the source model's config, nothing is a literal** — is
the load-bearing part, and it is worth more than it looks. A re-authored model with hardcoded
constants works for exactly one checkpoint and fails silently for the next one in the family
(different `head_dim`, different `rope_theta`, tied vs untied embeddings).

> ⚠️ **The name `from_source_model` does not appear in Apple's shipped code.** Grepped across all of
> `apple/coreai-models`: zero hits outside the two skill files. What the shipped code actually uses
> is a family of task-specific factories (all ✅ **VERIFIED**):
>
> | Shipped factory | Where |
> | --- | --- |
> | `BaseForCausalLM.from_hf(...)` / `.from_hf_memory_efficient(...)` | `models/base.py:336` |
> | `Sam3Lite.from_pretrained(model_id, image_size)` | `models/ios/sam3/sam3_reauthored.py:134` |
> | `ImageEncoderBackbone.from_hf_backbone(hf_backbone, image_size)` | `sam3_reauthored.py:147` |
> | `TextEncoderReauthored.from_hf_text_encoder(hf_text_encoder)` | `sam3_reauthored.py:156` |
> | `DETREncoderReauthored.from_hf_encoder(hf_encoder)` | `models/ios/sam3/detr.py:288` |
> | `LayerNormReauthored.from_torch_layer_norm(layer_norm, eps=None)` | `primitives/ios/layer_norm.py:35` |
>
> **Follow the convention, not the name.** If you are writing something Apple's tooling will consume,
> match the shipped names (`from_hf`, `from_pretrained`). If you are writing a standalone
> re-authoring, `from_source_model` is fine and matches what an agent using Apple's skill will
> expect to find.

The `LayerNormReauthored.from_torch_layer_norm` factory is the best miniature example of the whole
pattern, because it does the config extraction *and* the layout surgery in nine lines
(✅ **VERIFIED** — `primitives/ios/layer_norm.py:35-45`):

```python
@classmethod
def from_torch_layer_norm(
    cls, layer_norm: nn.LayerNorm, eps: float | None = None
) -> "LayerNormReauthored":
    dim = layer_norm.normalized_shape[0]
    actual_eps = eps if eps is not None else layer_norm.eps
    ane_norm = cls(dim, eps=actual_eps)
    ane_norm.weight.data = layer_norm.weight.data.reshape(1, dim, 1, 1)
    if layer_norm.bias is not None:
        ane_norm.bias.data = layer_norm.bias.data.reshape(1, dim, 1, 1)
    return ane_norm
```

`dim` from `normalized_shape[0]`, `eps` from the source module, weights reshaped `(D,) → (1,D,1,1)`
per §4.5. Nothing hardcoded, nothing guessed. Copy this shape for every primitive you write.

---

## 7. The verification gates

Apple publishes numeric acceptance thresholds. They are the most useful thing in the skill after the
rules themselves, because they convert "does my port work?" from a judgement call into a test.

✅ **VERIFIED** — `SKILL.md:94-99`, verbatim:

| Comparison | Threshold | Meaning |
| --- | --- | --- |
| Re-authored vs source (torch) | **> 70 dB** | Implementation correct |
| Neural Engine layout vs GPU layout (torch) | **> 70 dB** | Layout transformation correct |
| Compiled vs torch | **≥ 40 dB** | Compilation precision (fp16 + optimizations) |
| After 4-bit palettization | **≥ 35 dB** | Compression acceptable |

The `working-with-coreai` skill gives a second, differently-sliced table
(✅ **VERIFIED** — `working-with-coreai/SKILL.md:148-152`):

| Scenario | Expected PSNR | Investigate if below |
| --- | --- | --- |
| float32 end-to-end | > 70 dB | 60 dB |
| fp16 on-device | > 50 dB | 40 dB |
| 4-bit palettized | ~40 dB | 30 dB |

and the model-authoring skill a third, for compression specifically
(✅ **VERIFIED** — `SKILL.md:149-153`):

| Bits | Size reduction | Typical PSNR | Flag if below |
| --- | --- | --- | --- |
| 8-bit | ~2× | > 55 dB | 50 dB |
| 4-bit | ~4× | ~40 dB | 35 dB |
| 2-bit | ~8× | ~25–35 dB | Usually unacceptable |

**These are Apple-published figures with no hardware attached**, because they are properties of the
numerics rather than of a device. Treat them as acceptance criteria, not as benchmarks.

### 7.1 Reading the ladder

The four gates in the first table are not four measurements of the same thing; they are a **ladder**,
and each rung isolates one source of error:

1. **Re-authored vs source, both in torch, both fp32 → > 70 dB.** This tests *your code* and nothing
   else. Same precision, same device, same framework. Anything below 70 dB here is a bug in your
   implementation — a wrong activation, a mis-transposed weight, a dropped bias. Do not proceed.
2. **ANE layout vs GPU layout, both in torch → > 70 dB.** This tests *the layout transform*. Run the
   same weights through your BC1S model and a standard-layout model, convert one output to the
   other's layout, compare. Below 70 dB means a `permute`/`reshape` is wrong.
3. **Compiled vs torch → ≥ 40 dB.** Now you have added fp16 and the compiler's optimisations. The
   30 dB you lose between gate 2 and gate 3 is the *expected* cost of half precision. Below 40 dB
   means something about the conversion — a fallback, a fused op behaving differently, an fp32
   intermediate you lost.
4. **After 4-bit palettisation → ≥ 35 dB.** The last 5 dB is the compression. Below 35 dB, the
   compression is too aggressive for this model or for particular layers of it.

The discipline this buys you is **attribution**. If your final number is 28 dB, walking the ladder
tells you in four runs whether it is your code, your layout, your conversion or your compression.
Without the ladder you have one number and no hypothesis.

### 7.2 A PSNR harness

Apple does not ship one in the skill, so here is a complete one. The layout-transform argument is the
part people leave out and then get 12 dB from a correct model:

```python
"""PSNR harness for re-authoring verification.

Gate thresholds from Apple's model-authoring skill:
  re-authored vs source (torch) > 70 dB
  ANE layout vs GPU layout      > 70 dB
  compiled vs torch            >= 40 dB
  after 4-bit palettization    >= 35 dB
"""

from __future__ import annotations

from collections.abc import Callable

import numpy as np
import torch


def psnr(reference: torch.Tensor, candidate: torch.Tensor) -> float:
    """Peak signal-to-noise ratio in dB, computed in float64.

    `reference` defines the peak. Both tensors must already be in the SAME
    layout — see `common_issues.md`: "Never compare raw tensors across layouts."
    """
    if reference.shape != candidate.shape:
        raise ValueError(
            f"shape mismatch {tuple(reference.shape)} vs {tuple(candidate.shape)} — "
            "apply the layout transform before comparing"
        )
    ref = reference.detach().to(torch.float64).cpu().numpy()
    cand = candidate.detach().to(torch.float64).cpu().numpy()

    mse = float(np.mean((ref - cand) ** 2))
    if mse == 0.0:
        return float("inf")
    peak = float(np.max(np.abs(ref)))
    if peak == 0.0:
        return float("inf") if mse == 0.0 else float("-inf")
    return 20.0 * float(np.log10(peak)) - 10.0 * float(np.log10(mse))


def bc1s_to_standard(x: torch.Tensor) -> torch.Tensor:
    """(B, D, 1, S) -> (B, S, D).  neural_engine_rules.md:51-52"""
    return x.squeeze(2).permute(0, 2, 1)


def standard_to_bc1s(x: torch.Tensor) -> torch.Tensor:
    """(B, S, D) -> (B, D, 1, S).  neural_engine_rules.md:48-49"""
    return x.permute(0, 2, 1).unsqueeze(2)


def gate(
    name: str,
    reference: torch.Tensor,
    candidate: torch.Tensor,
    threshold: float,
    transform: Callable[[torch.Tensor], torch.Tensor] | None = None,
) -> float:
    """Run one gate. Raises on failure so a test suite catches it."""
    if transform is not None:
        candidate = transform(candidate)
    value = psnr(reference, candidate)
    status = "PASS" if value >= threshold else "FAIL"
    print(f"[{status}] {name:44s} {value:7.2f} dB  (need >= {threshold})")
    if value < threshold:
        raise AssertionError(f"{name}: {value:.2f} dB < {threshold} dB")
    return value


# --- usage ------------------------------------------------------------------
# ref  = source_block(x_std)                      # (B, S, D), fp32, torch
# cand = reauthored_block(standard_to_bc1s(x_std).half())   # (B, D, 1, S), fp16
# gate("attention block, ANE vs source", ref, cand.float(), 70.0,
#      transform=bc1s_to_standard)
```

Three notes on the implementation:

- **Compute in float64.** PSNR of two fp16 tensors computed in fp16 is meaningless above about
  30 dB — you are measuring the accumulator, not the model.
- **The peak comes from the reference, not from the pair.** Different conventions exist; this one
  makes the number stable when the candidate has an outlier.
- **The transform is a parameter, not an assumption.** Making it explicit at every call site is what
  stops you from silently comparing across layouts.

### 7.3 What to do when a gate fails

`common_issues.md` is, in effect, a lookup table from PSNR band to cause. Consolidated
(all ✅ **VERIFIED** from `common_issues.md`):

| Observed | Likely cause | Fix |
| --- | --- | --- |
| ~15–30 dB, attention only | Causal mask is `(1, query, 1, key)` instead of `(1, key, 1, query)` | Transpose the mask (§4.11) |
| ~20 dB after a few tokens | Cached pre-RoPE K instead of `key_rope` | Cache the post-RoPE key (§4.13) |
| ~18 dB, multimodal RoPE | M-RoPE pattern not reproduced exactly | `torch.cat([cos, cos], dim=-1)` then index `::2` |
| ~20–30 dB, uniform | Wrong activation (SiLU vs GELU vs QuickGELU vs SwiGLU) | Print `type()` from the source model |
| 5–15 dB, nonsensical | Comparing across layouts | Apply the layout transform first |
| Garbage logits, not a PSNR band | Non-contiguous tensors handed through the `coreai-models` Python wrapper | `.contiguous()` at that bridge boundary; Swift `NDArray` supports explicit strides[^stride-scope] |
| Diverges only for long prefill | fp16 rounding compounding over per-token passes | Chunked prefill `S_q=64`, or fp32 KV in Python |
| k and v swapped | Output dict key order is non-deterministic | Identify outputs by **shape**, not index |

That penultimate row is a runtime failure rather than a numerical one and it is brutal
(✅ **VERIFIED** — `common_issues.md:95-98`):

> **Neural Engine wrong logits — non-contiguous tensors**
> *"**Cause**: The runtime reads raw memory as if contiguous, **ignoring tensor strides**."*
> *"**Fix**: Call `.contiguous()` on ALL tensors before wrapping in `NDArray`."*

⚠️ Through this Python/PyTorch wrapper, a non-contiguous tensor can produce *wrong numbers,
silently* because the bridge reads its backing memory as contiguous. Any `permute`, `transpose`,
`narrow` or slice can create that input. Call `.contiguous()` at this bridge boundary. Do not
generalize the warning to Core AI's Swift `NDArray`, whose public API supports explicit strides.
[^stride-scope]

And the last row is a genuine oddity worth internalising
(✅ **VERIFIED** — `common_issues.md:159-162`):

> **Output dict key order non-deterministic — k/v swapped**
> *"**Cause**: Output dicts have non-deterministic key ordering."*
> *"**Fix**: Identify outputs by shape, not index. Distinguish k vs v by MSE against known-zero
> input."*

If your K and V caches have identical shapes — which they do — you cannot even distinguish them by
shape. Apple's suggested trick (MSE against a known-zero input) works because V passes zeros through
while K does not, after RoPE. Better: **name your outputs explicitly** in `output_names=[...]` at
conversion time and index the dict by name. `export/macos.py` and `segmentation/pipeline.py` both do.

Two more from `common_issues.md` that are not numerical at all but will stop you cold:

- ✅ **VERIFIED** `common_issues.md:19-23` — *"Input data type mismatch — 'Data type int32 does not
  match'. **Cause**: Input JSON descriptor uses wrong type specifier. **Fix**: Use `"si32"` (signed
  int32), not `"i32"`."*
- ✅ **VERIFIED** `common_issues.md:26-38` — *"Core AI import error about input counts. **Cause**:
  Input names include PARAMETER and CONSTANT_TENSOR entries folded away after `run_decompositions()`.
  **Fix**: Filter to only USER_INPUT and BUFFER kinds"*:

```python
from torch.export.graph_signature import InputKind

live_kinds = {InputKind.USER_INPUT, InputKind.BUFFER}
input_names = [
    s.arg.name for s in ep.graph_signature.input_specs if s.kind in live_kinds
]
```

- ✅ **VERIFIED** `common_issues.md:153-155` — *"`runner(**inputs)` fails — wrong call signature.
  **Cause**: `InferenceFunction.__call__` uses `**kwargs`, not a positional dict. **Fix**: Use
  `await runner(**inputs)` with keyword arguments, not `runner(inputs_dict)`."*

> 🟡 **RECONSTRUCTED — the `**kwargs` call convention conflicts with Apple's own quickstart.**
> `common_issues.md:155` says `await runner(**inputs)`. But `working-with-coreai/SKILL.md:132-137`
> shows the Python runtime being called with a **positional dict**:
> `outputs = await fn({"image": NDArray(...)})`. Both are Apple, both are in the same repository.
> **Reading:** most likely an API change between versions, with one file not updated.
> **Safe default:** try the keyword form first (`common_issues.md` is the more specific, more
> recently-maintained debugging file), fall back to the dict form, and pin your `coreai-core`
> version once you know which your build accepts. This is a two-minute experiment, not a design
> decision.

And two rules that are just hygiene, from the same file's general section
(✅ **VERIFIED** — `common_issues.md:5-8`):

> - ***Float32 constants**: Any Python float literal (e.g., `x * 2.0`) creates an f32 constant Neural
>   Engine rejects. Cast to float16.*
> - ***Always use float16 weights**.*
> - ***Layout mismatch in comparisons**: Apply the appropriate transform before PSNR. Never compare
>   raw tensors across layouts.*
> - ***Non-contiguous tensors**: Call `.contiguous()` on ALL tensors before wrapping in `NDArray`.*

---

## 8. How the optional `coreai-models` helper chooses a compute-unit preference

Everything so far assumed you know which compute unit your model will land on. This section explains
the policy in Apple’s optional `coreai-models` helper—not a Core AI framework naming contract.

In that helper, the preference is **not** inferred from the export platform or a bundle flag. Its
Swift loader derives a `SpecializationOptions` preference from **the names of the functions inside
the asset**. A direct `AIModel` caller chooses its own options; Core AI’s `.default` instead lets the
framework select the CPU/GPU/Neural Engine combination that minimizes latency.[^sample-routing-policy]

✅ **VERIFIED** — `swift/Sources/CoreAIShared/Runtime/ModelStructure.swift:12-20`:

```swift compile:27
/// Well-known graph function names used for structure detection.
public enum GraphNames {
    public static let main = "main"
    public static let loadEmbeddings = "load_embeddings"
    public static let extendPrefix = "extend"
    // Multi-function segmenter (lite SAM3 export for iOS).
    public static let imageEncode = "image_encode"
    public static let textEncode = "text_encode"
    public static let detect = "detect"
}
```

and the detection itself (✅ **VERIFIED** — `ModelStructure.swift:190-218`):

```swift prelude:guide-context
private static func detectStructure(from graphNames: [String]) -> ModelStructure {
    let graphSet = Set(graphNames)

    // Static-shape model (chunked/static)
    let extendFunctions = graphNames.filter { $0.hasPrefix(GraphNames.extendPrefix) }
    if !extendFunctions.isEmpty && graphSet.contains(GraphNames.loadEmbeddings) {
        let batchSize = extractBatchSize(from: extendFunctions.first!) ?? 1
        return .chunkedStatic(batchSize: batchSize)
    }

    // Multi-function segmenter (e.g. optimized SAM3 — image_encode / text_encode / detect).
    // Targets neuralEngine; checked before the `main` fallback because some asset variants ship
    // a thin `main` graph alongside the trio.
    if graphSet.contains(GraphNames.imageEncode)
        && graphSet.contains(GraphNames.textEncode)
        && graphSet.contains(GraphNames.detect)
    {
        return .multiFunctionSegmenter
    }

    // GPU model (dynamic)
    if graphSet.contains(GraphNames.main) {
        return .dynamic
    }

    // Unknown - default to GPU dynamic
    CLILogger.log("  - Warning: Unknown model structure, defaulting to GPU dynamic")
    return .dynamic
}
```

which feeds directly into the specialisation options
(✅ **VERIFIED** — `ModelStructure.swift:66-80`):

```swift prelude:guide-context
/// Returns `SpecializationOptions` derived from the model structure.
///
/// - `chunkedStatic` → prefer `.neuralEngine`
/// - `dynamic` → prefer `.gpu` + `expectFrequentReshapes`
/// - `multiFunctionSegmenter` → prefer `.neuralEngine`
public var specializationOptions: SpecializationOptions {
    switch self {
    case .chunkedStatic, .multiFunctionSegmenter:
        return SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
    case .dynamic:
        var opts = SpecializationOptions(preferredComputeUnitKind: .gpu)
        opts.expectFrequentReshapes = true
        return opts
    }
}
```

and is applied *before* the model is loaded, so specialisation happens with the right preference
(✅ **VERIFIED** — `ModelStructure.swift:150-159`):

```swift prelude:guide-context
// Probe structure before specializing so we can pick the right compute-unit preference.
let probedStructure = probeStructure(at: url)
CLILogger.log("  - Probed structure: \(probedStructure.description)")

let options = probedStructure.specializationOptions
let model = try await AIModel(contentsOf: url, options: options)
CLILogger.log("  - Loaded \(model.functionNames.count) graphs")

// Re-detect from compiled library — source of truth, should match the probe.
let structure = detectStructure(from: model.functionNames)
```

The probe uses `AIModelAsset(contentsOf:).summary(includingStatistics: false)` to read the function
names **without triggering specialisation** — a nice detail, since specialisation is the expensive
step you are trying to configure.

### 8.1 What this means in practice

**The helper recognizes three structures and maps everything else to its `.dynamic` → GPU policy:**

| Function set in the asset | `ModelStructure` | Preferred compute unit |
| --- | --- | --- |
| any `extend*` **and** `load_embeddings` | `.chunkedStatic(batchSize:)` | **Neural Engine** |
| `image_encode` **and** `text_encode` **and** `detect` | `.multiFunctionSegmenter` | **Neural Engine** |
| `main` | `.dynamic` | GPU, `expectFrequentReshapes = true` |
| anything else | `.dynamic` (with a warning log) | GPU |

> ⚠️ **SILENT FAILURE — your entrypoint names are load-bearing when using this helper.**
> If you re-author a segmentation model for the Neural Engine — BC1S, Conv2d, fp16, static shapes,
> the works — and then name your three entrypoints `encode_image`, `encode_text` and `predict`,
> `coreai-models` classifies it as `.dynamic` and requests the **GPU**. It works. It
> produces correct output. It ignores everything you spent a week on.
>
> The only trace is one line in `CLILogger`:
> `"  - Warning: Unknown model structure, defaulting to GPU dynamic"` — and only if you have logging
> on, and only if you had *no* `main` graph (if you have a `main`, you get `.dynamic` with **no**
> warning at all).
>
> **Detection:** log `PreparedModel.structure` after `prepare(at:)`, or check
> `model.functionNames` against the table above.
> **Safe default:** name your entrypoints exactly as Apple's constants say — `image_encode`,
> `text_encode`, `detect` for a segmenter; `load_embeddings` + `extend_*` for an LLM — or supply your
> own `SpecializationOptions` rather than relying on the derived ones.

**This reframes the three-function split for users of the sample helper.** WWDC26 session 325 presents splitting SAM3 into three
entrypoints as a *latency* technique — run each at a different cadence, get a 76% faster second
inference. That is true. Reading `ModelStructure.swift` shows that the split also selects the
helper’s Neural Engine preference. A single-`main` SAM3 export is `.dynamic` under this classifier;
the three-function export is `.multiFunctionSegmenter`. Those consequences do not apply to a
different loader unless it adopts the same policy.

**`expectFrequentReshapes`.** The `.dynamic` branch sets it. It is the runtime's hint that shapes
will change between calls, which is exactly what a dynamic-shape GPU model does and exactly what a
chunked-static ANE model must never do.

> ✅ **SDK-verified (upgraded from 🟡 on 2026-07-29) — `SpecializationOptions` is available on iOS,
> and on every other platform.**
> The framework's Swift interface — the exact artifact the old gap box asked for — was captured
> from the Xcode 27.0 beta SDK: `SpecializationOptions` is declared
> `@available(macOS 27.0, iOS 27.0, watchOS 27.0, tvOS 27.0, visionOS 27.0, *)`
> (`CoreAIDelegates-27.0-macos.swiftinterface:89-106`), with `init(preferredComputeUnitKind:)` and
> the settable `expectFrequentReshapes: Bool` exactly as `ModelStructure.swift` uses them. The
> macOS-only restriction the corpus recorded is a property of the `coreai.runtime` **Python** API
> only, not of the Swift type.
> **Still-good advice regardless:** Apple's own `working-with-coreai` guidance (`guidance.md:62`)
> says *"Use `.default` specialization options at runtime for each platform — this gives Core AI
> the most flexibility to optimize execution on device."* Take that unless you have measured a
> reason not to, and get your compute unit from your model's *structure*, which is portable.

### 8.2 The corollary about compression, from Apple's own guidance

If you *do* override the default and pin a compute unit, Apple says the model representation must
match (✅ **VERIFIED** — `working-with-coreai/references/guidance.md:64-70`):

| Preferred compute unit | Recommended model representation |
| --- | --- |
| Neural Engine | *"Static shapes, palettized weights, optimized for energy efficiency"* |
| GPU | *"Linear quantization, no chunked dynamic shapes, optimized to scale with available compute"* |

Note the compression split that falls out of this: **palettisation for the Neural Engine, linear
quantisation for the GPU.** That is not arbitrary — `neural_engine_rules.md:249` says
*"Palettization and quantization are the primary compression schemes supported on Neural Engine"*
with lookup tables being the natural fit, while the macOS presets in `export/presets.py` are
`torch_quantization_config` with `int4` `symmetric_with_clipping` `per_block/32`. The iOS presets are
`KMeansPalettizerConfig` with `per_grouped_channel`. Two different compression families, chosen by
compute unit, shipped in the same file.

`neural_engine_rules.md:245-253` adds the caveat that stops you over-compressing:

> *"Compression reduces model size but **does not always improve performance** — the benefit depends
> on whether the layer is bottlenecked by weight loading rather than computation."*
> *"Compression is most effective for layers where weight transfer time dominates computation time.
> **Layers that are already compute-bound will not see performance gains from compression alone.**"*
> *"Lookup tables can cover multiple output channels rather than one per kernel, which may improve
> accuracy since the model experiences less compression."*
> *"Newer hardware generations support **vector-valued lookup table entries** rather than scalar
> values."*

That last bullet is `PalettizationSpec.cluster_dim > 1` — 2-D clustering — and it is the only place
in Apple's material that ties a compression feature to a hardware generation. Which generation is
not stated.

---

## 9. Case study: SAM3 re-authored for iPhone

SAM3 is the worked example that ties every rule in this guide together. It is Meta's 848M-parameter
promptable segmentation model, and Apple re-authored it for iOS as the driving demo of WWDC26
session 325. Unusually for this framework, **the entire re-authoring is on GitHub and compiles**, so
you can read every decision.

### 9.1 What changed

WWDC26 session 325, on the attention block (**Apple, spoken narration**, 325:232-237):

> *"Here's the attention block from the Image Encoder transformer, **rewritten for power-efficient
> execution on iOS**. Instead of standard **Linear layers, I use convolutional projections**. This is
> one of the patterns that lets Core AI **leverage native hardware primitives on the right compute
> unit**. The text encoder gets a similar treatment. **The smaller decoder stays mostly unchanged.
> It's a small fraction of the compute, so the payoff from re-authoring it is minimal.**"*

The shipped code, ✅ **VERIFIED** — `models/ios/sam3/image_encoder.py:6-15` (module docstring):

```
"""Re-authored SAM3 image encoder backbone in BC1S layout.

32 transformer layers: 28 window attention (24x24 windows) + 4 global
attention at indices [7, 15, 23, 31]. All intermediates in BC1S
(B, C, 1, S) format. Linear projections replaced with Conv2d(1x1).
GELU approximated with sigmoid.

HF reference: ``Sam3ViTModel`` in
``transformers/models/sam3/modeling_sam3.py``.
"""
```

and the attention block itself (✅ **VERIFIED** — `image_encoder.py:56-80`):

```python
class ImageEncoderAttention(nn.Module):
    """Self-attention with 2D axial RoPE in BC1S layout."""

    def __init__(
        self,
        hidden_size: int = _HIDDEN_SIZE,
        num_heads: int = _NUM_HEADS,
        head_dim: int = _HEAD_DIM,
        grid_h: int = _WINDOW_SIZE,
        grid_w: int = _WINDOW_SIZE,
        rope_theta: float = _ROPE_THETA,
        rope_scale: float = 1.0,
    ) -> None:
        super().__init__()
        self.hidden_size = hidden_size
        self.num_heads = num_heads
        self.head_dim = head_dim

        self.q_proj = nn.Conv2d(hidden_size, hidden_size, 1, bias=True)
        self.k_proj = nn.Conv2d(hidden_size, hidden_size, 1, bias=True)
        self.v_proj = nn.Conv2d(hidden_size, hidden_size, 1, bias=True)
        self.o_proj = nn.Conv2d(hidden_size, hidden_size, 1, bias=True)

        self.sdpa = BidirectionalSDPA(num_heads=num_heads, head_dim=head_dim)
        self.rope = AxialRoPE2DReauthored(...)
```

Constants, all ✅ **VERIFIED** from `image_encoder.py:29-41`: `_HIDDEN_SIZE = 1024`,
`_NUM_HEADS = 16`, `_HEAD_DIM = 64`, `_MLP_DIM = 4736`, `_WINDOW_SIZE = 24`,
`_GLOBAL_ATTN_INDICES = [7, 15, 23, 31]`, `_PATCH_SIZE = 14`, `_IMAGE_SIZE = 1008`,
`_LAYER_NORM_EPS = 1e-6`, `_ROPE_THETA = 10000.0`.

Every rule in §4 is visible in that one file: BC1S (§4.4), Conv2d projections (§4.5), per-head
attention via `BidirectionalSDPA` (§4.10), GELU-by-sigmoid (§4.2), rank-4 window partition (§4.1),
and `LayerNormReauthored` with `(1, C, 1, 1)` affine parameters (§4.5).

### 9.2 The three-function split

**Apple, spoken narration**, 325:224-230:

> *"Instead of converting the model as-is, I can **author a new PyTorch implementation that's
> hand-crafted for my goals**. The biggest change I make is to have **three separate functions in the
> Core AI Model instead of one.** `image_encode` handles the image, `text_encode` processes the
> prompt, and `detect` wraps the final post-processing to generate the output."*
>
> *"**Splitting the work this way allows me to run each bit at a different cadence.** For example, I
> may want to **process a single prompt once and use it across a variety of images.** It also gives
> each function a **clean interface**, and lets me **compress and author each one independently**."*

The mechanism, ✅ **VERIFIED** — `python/src/coreai_models/segmentation/pipeline.py:265-289`:

```python
logger.info("Converting to Core AI...")
converter = coreai_torch.TorchConverter()
converter.add_exported_program(
    img_program,
    entrypoint_name="image_encode",
    input_names=["pixel_values"],
    output_names=["backbone_features"],
)
converter.add_exported_program(
    txt_program,
    entrypoint_name="text_encode",
    input_names=["input_ids"],
    output_names=["text_features"],
)
converter.add_exported_program(
    det_program,
    entrypoint_name="detect",
    input_names=["backbone_features", "text_features"],
    output_names=["pred_masks", "pred_boxes", "pred_logits", "presence_logits", "semantic_seg"],
)
coreai_program = converter.to_coreai()
coreai_program.optimize()

metadata = build_aimodel_metadata(config.hf_model_id)
coreai_program.save_asset(asset_path, metadata)
```

`entrypoint_name=` on `add_exported_program` is the whole API. One `TorchConverter`, three exported
programs, three names, one asset. And — per §8 — those three specific names are what make the
runtime specialise the asset for the Neural Engine.

### 9.3 The compression recipe is asymmetric

The brief version circulating about this demo is "4-bit palettisation on the two encoders." That is
**not what the shipped recipe does**, and the difference matters.

✅ **VERIFIED** — `models/sam3/README.md:7-11`:

| Function | Compression | Inputs | Outputs |
| --- | --- | --- | --- |
| `image_encode` | **4-bit** k-means palettization (gs=32) + fp16 | `pixel_values` | `backbone_features` |
| `text_encode` | **6-bit** k-means palettization (gs=8) + fp16 | `input_ids` | `text_features` |
| `detect` | fp16 (**no** weight compression) | `backbone_features`, `text_features` | `pred_masks`, `pred_boxes`, `pred_logits`, `presence_logits` |

and the config docstring says why (✅ **VERIFIED** — `segmentation/pipeline.py:135-138`):

> *"The palettization defaults are asymmetric — `image_encode` is more aggressive (w4 / gs32) while
> `text_encode` trades a bit of size for quality (w6 / gs8)."*

with the defaults as code (`pipeline.py:147-150`):

```python
image_n_bits: int = 4
image_group_size: int = 32
text_n_bits: int = 6
text_group_size: int = 8
```

The recipe itself, using the low-level API rather than a preset — which the presenter says is
deliberate, *"There is a preset available for this, but I use the lower-level representation here to
showcase the APIs"* (325:243) — ✅ **VERIFIED** `pipeline.py:208-245`:

```python
from coreai_opt import ExportBackend
from coreai_opt.palettization import (
    KMeansPalettizer,
    KMeansPalettizerConfig,
    ModuleKMeansPalettizerConfig,
    PalettizationSpec,
)
from coreai_opt.palettization.spec import PerGroupedChannelGranularity


def _make_pal_config(n_bits: int, group_size: int) -> KMeansPalettizerConfig:
    spec = PalettizationSpec(
        n_bits=n_bits,
        granularity=PerGroupedChannelGranularity(axis=0, group_size=group_size),
    )
    return KMeansPalettizerConfig(
        global_config=ModuleKMeansPalettizerConfig(op_state_spec={"weight": spec}),
    )


img_pal_config = _make_pal_config(config.image_n_bits, config.image_group_size)   # 4, 32
txt_pal_config = _make_pal_config(config.text_n_bits, config.text_group_size)     # 6, 8

img_enc = ImageEncoderModule(sam3_lite.image_encoder)
img_enc.eval()
img_palettizer = KMeansPalettizer(img_enc, img_pal_config)
img_enc = img_palettizer.prepare(example_inputs=(pixel_ref,))
img_enc = img_palettizer.finalize(backend=ExportBackend.CoreAI)
```

`DetectorModule` gets no palettizer at all — only the fp16 cast that all three receive
(`cast_to_16_bit_precision`, `pipeline.py:250-263`).

**Why the detector is uncompressed** is the best story in the session, because it is a debugging
story rather than a design one (**Apple, spoken narration**, 325:96-102 and 325:156-162):

> *"The model is now around **430 megabytes** … Look at the result. **One of the occluded flowers is
> no longer detected.** I applied the same aggressive compression to every single layer, and it's
> likely that **not every layer handles this equally well**. The question is — **which layers are
> causing this?**"*
>
> *"I'm noticing that **the vast majority of low-PSNR sync points are actually coming from the
> detector decoder** … Since we previously identified that **the detector block only accounts for 4%
> of model parameters, we're not getting much benefit from compressing it anyway.** So I'll … try
> **changing the quantization scheme to ignore the detector**."*

**Apple-published numbers**, from the session, with no hardware attached because they are size and
relative-latency figures: **~3 GB → ~430 MB**; the detector is **4% of parameters**; the second
inference is **76% faster** after the split.

That "4% of parameters" is the whole argument. Compressing a block that is 4% of the weights buys
you 4% of the savings and, in this case, cost you a detection. The general rule: **compress where
the bytes are, and leave quality-sensitive small blocks alone.** The same principle appears in the
diffusion presets, where a comment says *"The VAE encoder/decoder is small and quality-sensitive, so
it is never quantized"* (✅ **VERIFIED** — `diffusion/presets.py`), and in the LLM presets, where
SDPA, RoPE and both RMSNorm variants are mapped to `None` (§5.5).

### 9.4 The resolution change

**Apple, spoken narration**, 325:246:

> *"Also note, that I **changed the input image size from 1008 pixels to 336** to run on an iPhone."*

✅ **VERIFIED** in the code: `Sam3Lite.__init__(self, image_size: int = 336)`
(`sam3_reauthored.py:59`), and `models/sam3/README.md:55`: *"`image-size=336` is the resolution we
recommend for iOS deployment."*

The consequences ripple further than "fewer pixels":

- `grid_size = image_size // 14` → 336/14 = **24**, versus 1008/14 = 72.
- Token count `24² = 576` versus `72² = 5184` — a **9× reduction in sequence length**, and therefore
  roughly 81× less attention score memory in the global-attention layers.
- 24 is exactly `_WINDOW_SIZE`, so at 336 the "window" attention layers see the whole image and the
  distinction between windowed and global layers collapses.
- 576 is exactly `BidirectionalSDPA.query_chunk_size`, so the whole sequence fits in one chunk
  (§4.10).
- The reference tensors follow: `backbone_ref = torch.randn(1, 1024, 1, grid * grid)` → `(1, 1024, 1,
  576)` (✅ **VERIFIED** — `pipeline.py:222`). BC1S, innermost axis 576 — a comfortable multiple of
  32, satisfying §4.3.

That is what "designing layer dimensions with alignment in mind" looks like in a real port. The
resolution was not chosen because 336 is a round number; it was chosen because it makes the grid 24,
which makes the sequence 576, which makes every downstream constant fall into place.

### 9.5 ⚠️ The gap between the session and the shipped runtime

The 76% figure is real and it is also **not what you get for free**.

✅ **VERIFIED** — `swift/Sources/CoreAIImageSegmenter/ImageSegmentationEngine.swift:871-920`, the
multi-function run loop:

```swift illustrative
private func runMultiFunctionInference(
    state: MultiFunctionContext, imageArray: NDArray, textArray: NDArray
) async throws -> SegmentationOutput {
    var imageOutputs = try await state.imageEncode.run(inputs: [state.imageInputName: imageArray])
    guard let backboneFeatures = imageOutputs.remove(state.backboneFeaturesOutputName)?.ndArray
    else { throw ... }

    var textOutputs = try await state.textEncode.run(inputs: [state.textInputName: textArray])
    guard let textFeatures = textOutputs.remove(state.textFeaturesOutputName)?.ndArray
    else { throw ... }

    var detectOutputs = try await state.detect.run(inputs: [
        state.backboneFeaturesInputName: backboneFeatures,
        state.textFeaturesInputName:      textFeatures,
    ])
    ...
}
```

> ⚠️ **SILENT FAILURE — `CoreAISegmentationEngine` re-runs `image_encode` on every call.**
> The engine holds no cache for `backboneFeatures` and exposes no API to supply one. Every
> `segment(image:prompt:)` runs all three functions. The session's *"I swapped the prompt to
> butterfly and only re-ran the text encoder and the detector — the second inference is 76% faster"*
> describes caller-side orchestration that **Apple's own shipped package does not do for you**.
>
> Nothing warns you. You get correct segmentations at the un-split latency, having paid the entire
> authoring cost of the split. **To realise the 76%, hold the `image_encode` output yourself and
> call the three functions directly through `AIModel` / `InferenceFunction`**, as the loop above
> does — the code is fifteen lines and it is right there to copy.
>
> One good detail to copy while you are there: `detect`'s inputs are the **unmodified `NDArray`
> outputs** of the two encoders. No round-trip through Swift arrays, no re-wrapping. That is the
> whole point of putting three functions in one asset.

Two more shipped-vs-narrative notes on this model:

- The multi-function path is **text-only**. `supportsPointQuery` returns `false` for
  `.multiFunctionSegmenter` (✅ **VERIFIED** — `ImageSegmentationEngine.swift:28-40`), and passing
  embeddings throws: *"Multi-function segmentation assets accept token IDs only — the `text_encode`
  graph already projects them internally."* The single-`main` baseline export supports point prompts;
  the re-authored one does not. That is a **capability regression** you accept in exchange for the
  Neural Engine.
- `facebook/sam3` is **gated on Hugging Face** (`hf auth login --token …`) and the export script is a
  PEP 723 `uv` inline script with `override-dependencies` because SAM3 needs
  `transformers>=5.5.4` while the `coreai-models` workspace pins `<5.0`
  (✅ **VERIFIED** — `models/sam3/export.py:6-33`). If you are reproducing this, that dependency
  conflict is the first thing you will hit.

The reproduction commands, ✅ **VERIFIED** — `models/sam3/README.md`:

```bash
uv run models/sam3/export.py                      # lite (iOS) export — the WWDC26 325 demo
uv run models/sam3/export.py --help
uv run models/sam3/export.py --full               # plain HF Sam3Model, float32, 1008x1008
uv run models/sam3/export.py --full --dtype float16
```

⚠️ Note that `--n-bits` and `--group-size` apply to **both** encoders uniformly, overriding the
asymmetric default. Passing `--n-bits 4` does not "keep the defaults and change the image encoder";
it drops the text encoder from 6 bits to 4.

---

## 10. The silent-failure catalogue

Every failure in this table produces a model that **converts, loads and runs**. None of them throw.
Sources are cited so you can check any of them; every row is ✅ **VERIFIED** against a file on disk
unless marked otherwise.

| # | What you wrote | What happens | Symptom | Detection | Source |
| --- | --- | --- | --- | --- | --- |
| 1 | `x * (1.0 + scale)` | fp32 constant → graph segments at that op | Correct output, high power draw, poor latency | Residency check; count `float` literals | `neural_engine_rules.md:126` |
| 2 | Mask `(1, query, 1, key)` | Attention attends to the wrong axis | PSNR 15–30 dB; plausible but degraded output | Per-primitive PSNR gate | `common_issues.md:12-15` |
| 3 | `float("-inf")` in an ANE mask | ANE softmax mishandles IEEE −inf | NaNs *or* uniform attention, model-dependent | `grep -n "inf" model/*.py` | `common_issues.md:102-105` |
| 4 | Cached pre-RoPE `K` | Next call attends to un-rotated keys | PSNR ~20 dB, **only after token 1** | Generate ≥ 64 tokens, compare to torch | `neural_engine_rules.md:397` |
| 5 | Mismatched `transpose(-3,-1)` pair | Activations structurally shuffled | Wrong-but-plausible output | Layout-neutrality assert (§4.6) + PSNR | `neural_engine_rules.md:86` |
| 6 | `enable_per_channel_scale=True` | rank-6 LUTs → ANE rejects → GPU fallback | Correct output, ANE never used | Residency check | `pipeline.py:136-142` |
| 7 | `coreai-models.PreparedModel` with entrypoints named `encode_image`/… | Helper’s `ModelStructure` → `.dynamic` → GPU preference | Correct output on an unintended accelerator | Log `PreparedModel.structure` | `ModelStructure.swift:190-218` |
| 8 | Non-contiguous PyTorch tensor through the `coreai-models` Python wrapper | Bridge reads raw backing memory as contiguous | Wrong logits, no error | `.contiguous()` at this bridge boundary; Swift `NDArray` may use explicit strides[^stride-scope] | `common_issues.md:95-98` |
| 9 | Stateful transform for decode | State resets between inference calls | Same token forever; looks like a sampler bug | Read `processedTokenCount`-equivalent across calls | `common_issues.md:146-148` |
| 10 | `load_state_dict(..., strict=False)` | Renamed key silently unloaded | One layer at random init | Print source keys before remapping | `common_issues.md:173-176` |
| 11 | GELU where source uses SiLU | Different nonlinearity, similar statistics | PSNR 20–30 dB, uniform across the model | `named_modules()` activation dump | `gpu_rules.md:32` |
| 12 | `offset = chunk_end` in chunked prefill | Every chunk after the first is misaligned | Fine at ≤ 1 chunk, broken beyond | Test with prompt > `CHUNK` tokens | `neural_engine_rules.md:463` |
| 13 | Per-token prefill for a long prompt | fp16 error compounds over steps × layers | Gradual divergence past ~50 tokens | Compare 200-token prefill to chunked | `neural_engine_rules.md:465` |
| 14 | Palettised conv with stride > 2 | Stride unsupported under palettisation | Layer falls off the ANE | Residency check after compression | `neural_engine_rules.md:157` |
| 15 | Palettisation config incompatible with a tensor | Palettisation **disables itself for that layer**, warning only | Model larger than expected, quality better than expected | Read the export log for *"Skipping palettization"* | `coreai_opt` `_FakePalettizeImplBase` |
| 16 | Fused SDPA with an unexpected mask shape | PyTorch silently picks the math backend | Composite absent from the converted graph | Inspect the program for an SDPA composite node | §5.3 |
| 17 | Splitting SAM3 and using `ImageSegmenter` | Engine re-runs `image_encode` every call | Correct masks at un-split latency | Time two `segment()` calls with the same image | `ImageSegmentationEngine.swift:871-920` |
| 18 | Indexing K/V outputs by dict position | Output dict key order is non-deterministic | K and V swapped, intermittently | Index by explicit `output_names` | `common_issues.md:159-162` |

If you adopt only one habit from this guide, make it **the per-primitive PSNR gate**. It catches
rows 2, 4, 5, 11 and 12 outright, and narrows 1, 6 and 16 to a layer.

---

## 11. Quick reference

### 11.1 The two rulesets, side by side

| | **Neural Engine** | **GPU** |
| --- | --- | --- |
| Inter-block layout | `(B, S, 1, D)` (LLM) / BC1S `(B, C, 1, S)` (vision) | `(B, S, D)` |
| Attention layout | BC1S `(B, H·D, 1, S)` | `(B, H, S, D)` |
| Projections | `nn.Conv2d(in, out, kernel_size=1)` | `nn.Linear`, fused QKV |
| Weight surgery | `w.unsqueeze(-1).unsqueeze(-1)`; norms `(D,) → (1,D,1,1)` | none |
| Attention | Per-head Python loop; no fused SDPA | `F.scaled_dot_product_attention` |
| Score softmax axis | `dim=1` (channel) | `dim=-1` |
| Causal mask shape | `(1, key, 1, query)` | `(1, 1, S, S)` |
| Masked value | `-40000.0` (or `-1e4`) | `float("-inf")` |
| Precision | fp16 only; **no** Python float literals | fp16 weights, fp32 intermediates where useful |
| Shapes | Fully static; one function per shape config | Dynamic supported |
| Max tensor rank | **5** | unconstrained in practice |
| Innermost axis | Contiguous, 64-byte aligned, power of 2, ≥ 32 fp16 elements, never 1 | unconstrained |
| Embedding | `(V, 1, D)`, separate entrypoint, int8 per-tensor | `nn.Embedding` |
| KV cache shape | `[n_layers, B, H_kv·D, 1, max_S]`, seq dim **4** | `[n_layers, B, H_kv, max_S, D]`, seq dim **3** |
| KV pattern | Read-only functional I/O, or `KVCacheHandler` state | `register_buffer` + `mutable_slice_update` |
| MLP order | up before gate | up before gate |
| MoE | not covered by Apple's ANE material | `SwitchGLU` / `SwitchLinear` / `GatherMM`, indices `uint16` |
| Compression family | palettisation (k-means, per-grouped-channel) | linear quantisation (int4, per-block/32) |
| Custom Metal kernels | ✗ | ✓ `TorchMetalKernel` |
| Runtime preference derived from | `extend*` + `load_embeddings`, or the `image_encode`/`text_encode`/`detect` trio | presence of `main` |

### 11.2 Pre-export checklist — Neural Engine

Run through this before you spend an hour on conversion:

- [ ] `grep -n "nn.Linear" ` → every hit justified in a comment
- [ ] `grep -nE "[^a-zA-Z_](-?[0-9]+\.[0-9]+)"` → no bare float literals in `forward()`
- [ ] `grep -n "inf"` → no `float("-inf")` anywhere
- [ ] `grep -n "\.float()"` → none (it is a residency break and, per community reports, a no-op)
- [ ] Every projection bracketed by a matched `transpose(-3, -1)` pair
- [ ] Layout-neutrality assert passes on every block (§4.6)
- [ ] No reshape produces rank > 5 — check window/patch helpers specifically
- [ ] Every model input and output has a non-singleton, power-of-2, ≥ 32-element innermost axis
- [ ] Causal mask is `(1, key, 1, query)` with `-40000.0`
- [ ] cos/sin precomputed outside the graph, passed in 4-D
- [ ] `key_rope` — post-RoPE — is what reaches the cache
- [ ] Softmax on `dim=1`
- [ ] Python/PyTorch tensors `.contiguous()` before the `coreai-models` wrapper; preserve explicit Swift `NDArray` strides[^stride-scope]
- [ ] If using `coreai-models.PreparedModel`, entrypoints match its recognized structures; direct loaders choose their own options[^sample-routing-policy]
- [ ] `enable_per_channel_scale` is `False` in every palettisation spec
- [ ] Per-primitive PSNR ≥ 70 dB **before** you compose the model

### 11.3 Pre-export checklist — GPU

- [ ] Source activation type printed and matched exactly
- [ ] Source state-dict keys printed before any remap was written
- [ ] Q/K/V fused into one `nn.Linear`, and the `narrow` offsets match the `cat` order
- [ ] `F.scaled_dot_product_attention` used, and the composite survives conversion
- [ ] `up_proj` computed before `gate_proj`
- [ ] KV buffers registered with `persistent=False`; positional tables with `persistent=True`
- [ ] `state_names=("keyCache", "valueCache")` at conversion
- [ ] MoE expert indices cast to `uint16`; `SwitchLinear` has its own 4-D compression spec
- [ ] `eager_chunk_size` left `None` for export
- [ ] `.eval()` called before `torch.export`
- [ ] `run_decompositions(get_decomp_table())` called before `add_exported_program`
- [ ] Norms, RoPE and SDPA excluded from weight compression

### 11.4 The gates, one more time

| Gate | Threshold | If it fails |
| --- | --- | --- |
| Re-authored vs source (torch, fp32) | > 70 dB | Your implementation. Do not proceed. |
| ANE layout vs GPU layout (torch) | > 70 dB | A `permute`/`reshape`. |
| Compiled vs torch | ≥ 40 dB | Conversion: a fallback, a lost fp32 intermediate, a fused op behaving differently. |
| After 4-bit palettisation | ≥ 35 dB | Compression too aggressive — find the sensitive layers and exclude them. |

### 11.5 The commands

```bash
# Discover what is already supported
uv run coreai.model.registry --list-models
uv run coreai.model.registry --model-info qwen3-0.6b --platform iOS --as-export-args

# Export an LLM, iOS variant (static shapes, palettised, Neural Engine structure)
uv run coreai.llm.export Qwen/Qwen3-0.6B --platform iOS

# Export an LLM, macOS variant (dynamic shapes, int4 per-block, GPU structure)
uv run coreai.llm.export Qwen/Qwen3-0.6B --compression 4bit

# Truncate to one layer while you are debugging the authoring
uv run coreai.llm.export Qwen/Qwen3-0.6B --num-layers 1 --compression none

# Reproduce the SAM3 re-authoring
uv run models/sam3/export.py

# AOT compile, pinning the compute unit when the compiler chooses wrong
xcrun coreai-build compile model.aimodel --platform iOS
xcrun coreai-build compile model.aimodel --preferred-compute neural-engine
```

(All ✅ **VERIFIED** — `models/README.md`, `models/sam3/README.md`,
`working-with-coreai/SKILL.md:99`, `common_issues.md:112`. `--num-layers` is from
`llm/export.py`'s `build_parser()`.)

### 11.6 Installing Apple's skills into your own agent

Since these rules were written for coding agents, the highest-leverage thing you can do is give your
agent the same file. ✅ **VERIFIED** — `apple/coreai-models` ships
`.claude-plugin/` declaring a plugin named `coreai-skills` sourced from `./skills`, plus a
`skills/gemini-extension.json`, so the bundle targets more than one assistant. The three skills are
`working-with-coreai`, `model-authoring` and `model-compression-exploration`.

WWDC26 session 325 on why (**Apple, spoken narration**, 325:24-28):

> *"AI skills give your coding agent access to the best practices and domain knowledge from our
> engineers … In fact, **most of the code you will see throughout this talk was co-developed with an
> agent actively leveraging these skills.**"*

Which is also the correct way to read this guide: it is a human-readable rendering of the same
material, with the places where the skill and the shipped code disagree marked.

---

## 12. Sources and evidence ledger

### 12.1 Primary — files read on disk this session

All paths relative to a clone of **`apple/coreai-models`** at commit `5ed9981` (2026-07-23),
BSD-3-Clause, `Copyright 2026 Apple Inc.`

**Apple's agent skills** — the backbone of this guide:

| File | Lines | Used for |
| --- | --- | --- |
| `skills/skills/model-authoring/references/neural_engine_rules.md` | 479 | all of §4 |
| `skills/skills/model-authoring/references/gpu_rules.md` | 297 | all of §5 |
| `skills/skills/model-authoring/references/common_issues.md` | 176 | §7.3, §10 |
| `skills/skills/model-authoring/SKILL.md` | 154 | §2, §6, §7 |
| `skills/skills/working-with-coreai/SKILL.md` | 200 | §3, §4.16, §7 |
| `skills/skills/working-with-coreai/references/guidance.md` | 70 | §3, §8.2 |

**Shipped Python primitives and models:**

`python/src/coreai_models/primitives/ios/{sdpa,bidirectional_sdpa,mlp,rms_norm,layer_norm,gelu,rope,cache,embedding,quantization}.py` ·
`python/src/coreai_models/primitives/macos/{sdpa,mlp,rms_norm,switch}.py` ·
`python/src/coreai_models/models/ios/qwen3.py` ·
`python/src/coreai_models/models/macos/qwen3_moe.py` ·
`python/src/coreai_models/models/ios/sam3/{sam3_reauthored,image_encoder}.py` and
`models/ios/sam3/primitives/window.py` ·
`python/src/coreai_models/segmentation/pipeline.py` · `models/sam3/{export.py,README.md}` ·
`python/pyproject.toml`

**Shipped Swift:**

`swift/Sources/CoreAIShared/Runtime/ModelStructure.swift` (the optional package’s function-name →
preference policy[^sample-routing-policy]) ·
`swift/Sources/CoreAIImageSegmenter/ImageSegmentationEngine.swift` (multi-function run loop) ·
`Package.swift` (platform floor)

**Negative results — checked and absent:**

- `LegalizeToCoreOptions` / `mutable_arg_action`: zero hits in `apple/coreai-torch` (source, docs,
  notebooks) and zero in `apple/coreai-models` Python. Only the three skill mentions. → 🔴 GAP, §5.6.
- `from_source_model`: zero hits outside the two skill files. → noted in §6.3.
- Core AI sample-code projects: **zero**, and `/documentation/updates/coreai` 404s. → 🔴 GAP, front
  matter.

### 12.2 Secondary — research notes in this corpus

- `notes/repos/apple-coreai-models.md` — export-pipeline constants, presets, entrypoint names,
  bundle schema, `HardwareConstraints` block, iOS/macOS export path differences.
- `notes/transcripts/coreai-python-metal.md` — WWDC26 sessions 325 and 330, with the transcript
  quotations used in §3, §9 and §4.1's palettisation callout, and the transcript-vs-code
  discrepancy register.
- `notes/repos/coreai-models-nonllm.md` — `CoreAISegmentationEngine` backends, the
  no-`backboneFeatures`-cache finding, capability matrix.
- `notes/01-lead-agent-repo-spotchecks.md` — independent verification of the skill file inventory
  and line counts.
- `notes/repos/john-rocky-models.md` — **community**, single-author, self-declared uncontrolled
  benchmarks. Everything drawn from it is labelled inline.

### 12.3 Attribution of every number in this guide

| Number | Attribution | Hardware / conditions |
| --- | --- | --- |
| 32× memory at fp16, 64× at int8 for a singleton last axis | **Apple-published** (`neural_engine_rules.md:23`) | none stated — it is arithmetic on the 64-byte block |
| PSNR gates: 70 / 70 / 40 / 35 dB | **Apple-published** (`SKILL.md:94-99`) | none stated — acceptance criteria |
| 8-bit ~2× / >55 dB · 4-bit ~4× / ~40 dB · 2-bit ~8× / 25–35 dB | **Apple-published** (`SKILL.md:149-153`) | none stated |
| GELU-by-sigmoid ~92 dB vs exact; simpler `1.702x` form ~57 dB | **Apple-published** (`primitives/ios/gelu.py:11-12`) | numerical property, no hardware |
| Wrong activation → PSNR ~20–30 dB | **Apple-published** (`gpu_rules.md:32`) | none stated |
| Pre-RoPE K cached → PSNR ~20 dB | **Apple-published** (`neural_engine_rules.md:397`) | none stated |
| Mask orientation wrong → PSNR ~15–30 dB | **Apple-published** (`common_issues.md:13`) | none stated |
| M-RoPE mismatch → PSNR ~18 dB | **Apple-published** (`common_issues.md:64`) | none stated |
| SAM3 848M parameters | **Apple-published** (`models/sam3/README.md:96`) | — |
| SAM3 ~3 GB → ~430 MB after w4 | **Apple-published**, WWDC26 325:96 (spoken) | device not stated; unclear whether disk or specialised artifact |
| Detector = 4% of parameters | **Apple-published**, WWDC26 325:158 (spoken) | — |
| Second inference 76% faster after the 3-way split | **Apple-published**, WWDC26 325:261 (spoken) | ⚠️ device, warm-up protocol and exactly what was compared are **not stated**; and see §9.5 — the shipped engine does not do the caching this figure assumes |
| fp16 decode drift ~5–10 dB / 50 tokens | **Community-measured** (`john-rocky/coreai-model-zoo`) | no hardware, no OS build, single author, uncontrolled |
| MoE int8 39 tok/s vs int4 170 tok/s (LFM2.5-8B-A1B) | **Community-measured** (same) | M4 Max, no OS build, no published harness |
| `gather_qmm` custom kernel 141 tok/s int8 / 162.7 tok/s int4km | **Community-measured** (same) | M4 Max; ~32 tok/s reported on iPhone 17 Pro |
| `.float()` is a no-op on the ANE | **Community-claimed** (same) | mechanism plausible, not independently confirmed |
| `LayerNorm([x, -x]) == RMSNorm` as an fp32-accumulation trick | **Community-claimed** (same) | identity is mathematically true; the ANE-kernel claim is unverified |

### 12.4 Conflicts between sources, and how this guide resolved them

| Conflict | Resolution |
| --- | --- |
| Session 325 says SAM3 encoders use *"4-bit palettization with per-channel scales"*; the shipped recipe is **image w4/gs32, text w6/gs8** with `enable_per_channel_scale=False` | **Code wins.** §9.3 gives the shipped numbers; §4.1 explains why the flag is off (rank-6 LUTs). |
| The brief for this guide said "4-bit palettisation on the two encoders" | Corrected to the asymmetric w4/w6 recipe per `models/sam3/README.md` and `pipeline.py:147-150`. |
| `neural_engine_rules.md` recommends the `bchq,bkhc->bkhq` einsum; shipped `SDPA` uses `permute` + `@` | Both presented; shipped primitives recommended as the default (§4.10). |
| `common_issues.md` says avoid `nn.functional.silu`; the shipped iOS MLP uses it | Reconciled via the decomposition table — `export/ios.py` pops `aten.silu` so it survives intact (§4.2). |
| `SKILL.md` prescribes `from_source_model`; shipped code uses `from_hf` / `from_pretrained` / `from_hf_*` | Convention adopted, name flagged as skill-only (§6.3). |
| `gpu_rules.md` prescribes `LegalizeToCoreOptions(mutable_arg_action="hoistToArg")`; the symbol exists nowhere else | Declared a 🔴 GAP; the shipped `state_names=` path recommended instead (§5.6). |
| `common_issues.md` says `await runner(**inputs)`; `working-with-coreai/SKILL.md` shows `await fn({...})` | Both reported; keyword form recommended first, version-pinning advised (§7.3). |
| `neural_engine_rules.md` says BC1S everywhere; shipped LLM primitives use `(B, S, 1, D)` between blocks | Both true at different sites; resolved and explained in §2. |
| `SKILL.md` implies "iOS ⇒ Neural Engine"; the optional package's `ModelStructure.swift` derives its preference from function names | **Package code wins for `coreai-models.PreparedModel`; direct `AIModel` callers remain governed by their own options.** §8.[^sample-routing-policy] |

### 12.5 Open gaps, restated

| Gap | What is unknown | What would resolve it | Safe default |
| --- | --- | --- | --- |
| Core AI sample code | There is none | An Apple sample under `/documentation/coreai` | Use `apple/coreai-models` as the sample |
| `coreai-build` residency output | The output format, whether it is per-op — **narrowed 2026-07-31**: the wrapper ships in the Metal Toolchain component, not Xcode-beta.app; the 2026-07-29 check lacked that component. Its captured `--help` names the likely surface, `inspect --compute` / `--ops` / `--json` (§4; `notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`) | That inspect output on a real compiled asset; the AOT-compilation doc page | Use the Core AI Debugger, or `benchmark_coreai_program` per-module timings |
| `HardwareConstraints` / `AllocationType` | Full signature; `interleave` vs `alignments` semantics; the enum cases | The `coreai` Python API reference | Do not hand-author them; go through `coreai_models.export.ios` |
| `LegalizeToCoreOptions` | Whether it exists at all | The `coreai` Python API reference | Use `state_names=` as `export/macos.py` does |
| ~~`SpecializationOptions` on iOS~~ | **CLOSED 2026-07-29** — the captured beta Swift interface declares it `iOS 27.0`-available (§8.1) | — | Still use `.default` per Apple's guidance; function-name policy remains specific to `coreai-models.PreparedModel`[^sample-routing-policy] |
| Which ANE KV pattern to prefer | Apple ships two and recommends neither over the other | An Apple doc page on ANE KV caching | `KVCacheHandler` for the shipped LLM export path; read-only for hand-rolled models |
| "Newer hardware generations support vector-valued LUT entries" | *Which* generations | `PalettizationSpec.cluster_dim` docs with availability | Leave `cluster_dim=1` unless you have measured a win on your target device |
| The 76% figure's conditions | Device, warm-up, what was compared | Apple restating it with a methodology | Measure it yourself; the shipped engine will not give it to you (§9.5) |

---

## Related guides

- **Part 8 — Core AI: converting from PyTorch.** `torch.export`, `TorchConverter`, decomposition
  tables, externalization, composite ops, `coreai-build`.
- **Part 9 — Core AI: compression and numeric formats.** `coreai-opt`, `Quantizer` vs
  `KMeansPalettizer`, calibration, QAT, mixed precision. The compression *shapes* referenced here in
  §8.2 and §9.3 are unpacked there.
- **Part 10 reference 02 — the Core AI Debugger.** Sync points, `save_intermediates`, comparison
  sessions, and the workflow that turned "one flower is missing" into "exclude the detector."
- **Part 11 — Metal and TensorOps.** The custom-kernel lever that exists only on the GPU side of
  this guide's table.
- **Part 7 — Core AI: the Swift runtime.** `AIModel`, `InferenceFunction`, `NDArray`, states, and
  the bundle format the assets in §9 are packaged into.

[^sample-routing-policy]: The classifier and preferences described here are source code in the
    optional `apple/coreai-models` package’s pinned
    [`ModelStructure.swift`](https://github.com/apple/coreai-models/blob/5ed9981303b38d5a44aa6b45509bc4f6945029f5/swift/Sources/CoreAIShared/Runtime/ModelStructure.swift#L12-L218).
    Core AI documents `.default` separately as selecting the compute-unit combination that minimizes
    latency: [Managing model specialization and caching](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/docs/Managing%20model%20specialization%20and%20caching.md).

[^stride-scope]: The `.contiguous()` warning is specific to the Python authoring path documented in
    the pinned `coreai-models`
    [`common_issues.md`](https://github.com/apple/coreai-models/blob/5ed9981303b38d5a44aa6b45509bc4f6945029f5/skills/skills/model-authoring/references/common_issues.md#L95-L98).
    The Core AI API itself exposes explicit strides and specialization-selected layouts:
    [Apple Developer — `NDArray`](https://developer.apple.com/documentation/coreai/ndarray).
