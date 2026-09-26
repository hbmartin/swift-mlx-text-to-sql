# Part 12 — MLX in Python

**Version floor:** MLX **0.32.x** (the tree declares `MLX_VERSION 0.32.1` at commit `973e27f`; the docs site
served the 0.32.0 build) and **mlx-lm 0.31.3**, plus `main` at `e5baded` (2026-07-26). MLX is a **pip package,
not an OS framework**, and its floor sits far below the rest of this series: **Apple silicon, a native `arm`
Python ≥ 3.10, macOS ≥ 14.0**. If you arrived from Parts 7–11, unlearn the 27.0 floor. The exceptions are
precise and load-bearing: `mx.set_wired_limit` and mlx-lm's memory wiring need **macOS 15**; the M5
neural-accelerator (NAX) kernels need **macOS/iOS/tvOS/visionOS 26.2** *and* GPU architecture generation
**≥ 17** (≥ 18 on `'p'` parts); Thunderbolt-5 RDMA and the JACCL backend need **macOS 26.2**; and only the
*consumer* side — Xcode 27's *Settings ▸ Intelligence ▸ Add Chat Provider ▸ Locally Hosted*, and
`ChatCompletionsLanguageModel` — is iOS 27 / macOS 27.

**Who this is for:** Python ML engineers who want a Hugging Face checkpoint running, quantized, fine-tuned,
served, or spread across four Macs. Swift is [Part 13](../part-13-mlx-swift/README.md); Core AI conversion is
[Part 14](../part-14-bridges-between-stacks/README.md).

---

## ⚠️ Pin your versions. Every date in this part is suspect.

**MLX moves weekly, and the clone behind these guides was shallow (`--depth 50`)** — `git log` on most paths
returns the graft boundary (`ca60290`), not the introducing commit.

> 🔴 **GAP — version-introduction dates are UNVERIFIED.** These guides can tell you an API **exists at 0.32.1**,
> because it was read out of the source or the shipped docs. They **cannot** tell you which release introduced
> it. Where a guide says "recent" or "new", it means *new relative to the 0.31 → 0.32 window we could see* — not
> a dated claim. Only dates attached to a PR number are sourced. Resolve with `git fetch --unshallow`.

**So: pin `mlx==0.32.*` and `mlx-lm==0.31.3`, read the shipped `mlx/version.h` rather than trusting any date
including these guides', and re-run your own numerics after every bump.** Not boilerplate — **three NAX
correctness fix PRs opened in the 72 hours before 2026-07-27** (on the 2026-08-03 re-check, #3912/#3922
were open and #3924 was closed unmerged; #3922 later merged **2026-08-26**, but none is in MLX checkout
`973e27f`), one a *missing
`else`* in `tile_matmad_nax` that compiles odd tile shapes to nothing and produces garbage. Second version axis:
**PyPI mlx-lm 0.31.3 is dated 2026-04-22 and `main` has moved substantially past it**, so several fixes here are
unreleased — and **0.31.0 was pulled from practical use** for a `BatchKVCache` cross-contamination bug.

---

## Why this part exists

MLX looks like NumPy, and the resemblance is close enough that **you can be productive in ten minutes and wrong
in twenty.** Four reasons this is six long guides rather than a quickstart.

1. **The execution model is not the one you are typing.** Arrays are lazy, so your traceback points at the
   `eval` and not at the bug; memory is unified, so a 60 GB spike has no `.to(device)` to blame; and
   `mx.compile` is a cache lookup whose real key includes things the documentation does not list.
2. **The hardware gate is invisible.** On an M5-class Mac, `float32` matmul runs at TF32-class precision by
   default — nine to ten bits of mantissa gone, with no exception, no warning, no field in `mx.device_info()`.
3. **The newest surfaces fail numerically, not loudly.** Fused attention falls back and returns the *correct*
   answer, slower and with a gigabyte of transient scores; a quantized MoE matmul on an M5 leaves output rows
   **unwritten**, exposing recycled allocator memory that is sometimes coincidentally plausible.
4. **It is now the sanctioned adaptation path.** Custom Foundation Models LoRA adapters are **discontinued in
   OS 27**. To get a model that knows your domain in 2026, you ship one and adapt it yourself.

---

## Read this first: the triage table

| If your situation is… | Read | Why |
|---|---|---|
| "I know NumPy; what breaks first?" · "why is my program using 60 GB?" | [12.1 §1–§4](references/01-core-fundamentals.md#1-unified-memory-the-defining-design-decision) | Unified memory, laziness, the transforms — nothing computes until forced |
| "`mx.compile` made my code *slower*" · "my gradient is zero and nothing threw" | [12.1 §8.4, §5.3, §7.1](references/01-core-fundamentals.md#84-️-silent-failure-python-scalars-are-baked-into-the-cache-key) | A varying Python `int` is in the cache key; captured arrays are frozen constants |
| "Green on my M3, red on the M5" · "`allclose(rtol=1e-5)` started failing" | [12.2 §3](references/02-numerics-hardware-gating-and-custom-kernels.md#3-tf32-and-the-hardware-gate--one-feature-two-halves) | TF32 by default; `MLX_ENABLE_TF32` is the only control |
| "Prefill is slow" · "OOM at a context length the arithmetic said fits" | [12.2 §5](references/02-numerics-hardware-gating-and-custom-kernels.md#5-️-the-silent-sdpa-fallback) | Silent SDPA fallback — check `head_dim` against the allow-list |
| "MLX has no op for this" | [12.2 §7–§9](references/02-numerics-hardware-gating-and-custom-kernels.md#7-mxfastmetal_kernel-the-complete-api) | `mx.fast.metal_kernel`: a JIT'd string, no Xcode, no build step |
| "Which bits, group size and mode?" · "3-bit is unusable" | [12.3 §2–§3, §8, §12](references/03-quantization.md#2-the-mode-inventory) | Mode inventory, sizing arithmetic, selection table; AWQ/GPTQ/DWQ/dynamic |
| **"I run a quantized MoE model on an M5"** | **[12.3 §9](references/03-quantization.md#9-️-the-corruption-bugs) — before you trust its output** | Unwritten rows, OPEN as of 2026-07-29 |
| "Which KV cache class?" · "output quality changed and I cannot explain it" | [12.4 §4–§6, §9](references/04-mlx-lm-cli-generation-and-caching.md#4-kv-caching-the-nine-cache-classes) | Nine cache classes and the trimmability contract; the chat template is not the one you think |
| "I want an OpenAI endpoint / an agent in Xcode 27" · "the server 404s and my URL is fine" | [12.5 Part A](references/05-serving-and-distributed.md) | Every flag and endpoint; *every* load failure surfaces as 404 |
| "The model does not fit on one Mac" | [12.5 Part B](references/05-serving-and-distributed.md) | `mlx.launch`, hostfiles, Thunderbolt-5 RDMA, mesh vs ring |
| "My adapter broke on OS 27" · "I need domain knowledge in the model" | [12.6 §0, §3–§6](references/06-finetuning-and-porting-models.md#0-the-frame-custom-adapters-are-gone-in-os-27) | Adapters are gone; MLX LoRA/DoRA is what is left |

---

## The guides in this part

### [12.1 — MLX fundamentals: unified memory, lazy evaluation, transforms, and `compile`](references/01-core-fundamentals.md)

The conceptual primer the other five assume, built on five ideas: unified memory (you never move arrays, you
choose per-op *which device runs it*), lazy evaluation, the composable function transforms (`grad`, `vjp`,
`jvp`, `vmap`, `checkpoint`, `custom_function`, `compile` — each returns something the others can transform
again), what `mx.compile` fuses and what makes it recompile, and `nn.Module` as a plain parameter tree that is a
`dict` subclass, not a PyTorch module respelled. Closes on streams, saving and loading, and interop. Several
🔴 small gaps are declared with safe defaults; the one to remember is `.mlxfn` forward compatibility, which
Apple's own warning makes **a build artefact, not an archive**.

> ⚠️ **SILENT FAILURE — six, all of the form "your numbers are wrong and nothing said so."** `mx.compile`'s
> cache key was read out of `CompilerCache::find` and `PyCompiledFun::call_impl`: an `mx.array` contributes a
> *placeholder*, but an `int`, `float`, `str` or `None` contributes **its value**, so a varying scalar
> recompiles every call and presents as *"compile made my code slower"* (§8.4). An array captured by closure
> becomes a compile-time constant and updating it does nothing (§7.1); the same capture inside
> `custom_function` silently zeroes its gradient (§5.3). Under `shapeless=True`, Python arithmetic on `x.shape`
> is baked in at first call (§9.3); writing through a NumPy view is invisible to autodiff (§12.4); and the
> DLPack handoff to PyTorch passes a pointer without waiting for queued work.

### [12.2 — Numerics, hardware gating, and writing custom Metal kernels from Python](references/02-numerics-hardware-gating-and-custom-kernels.md)

Where MLX stops being a portable array library and becomes a program on one specific piece of Apple silicon.
Three coupled themes: the dtype inventory (including the CPU-only one, and why fp8/fp4 are ops and storage
formats rather than dtypes); the hardware gate, **one feature in two halves** — `relaxed_precision = true` is
hardcoded in MLX's NAX matmul kernel while the host gates `float32` on `MLX_ENABLE_TF32`; and
`mx.fast.metal_kernel` end to end, JIT-compiled from a Python string with no Xcode and no build step.

> ⚠️ **SILENT FAILURE — TF32 you did not choose (§3.3).** Community measurements in mlx#3860 put M5 `float32`
> matmul error at **2^-10.4** versus **2^-19.8** with `MLX_ENABLE_TF32=0`; `x.dtype` still says `float32`,
> because it is — only the multiply-accumulate is relaxed. **Set `MLX_ENABLE_TF32=0` before importing mlx in any
> test suite**, which is exactly what MLX's own harness does. Docs PR #3894 merged 2026-08-04 and #3860 closed
> with it; the warn-once PR (#3883) stayed closed unmerged and a programmable switch was declined — no runtime signal.
>
> ⚠️ **SILENT FAILURE — fused attention silently becomes unfused (§5).**
> `mx.fast.scaled_dot_product_attention` returns the mathematically correct answer via `matmul → softmax →
> matmul`, materialising a full score tensor; the only symptoms are throughput and peak memory. Community
> measured, one `d=512` global layer at `L=4096` runs **84 ms and materialises ~1 GB of transient scores**.
> There is no query for it — `MLX_FAST_LOG_FALLBACK` and an `sdpa_is_fused()` predicate were requested
> (mlx#3885) and have not landed — so assert your head dimension against §5.2's allow-list **at model-load
> time**. Neighbour: building MLX below `MACOSX_DEPLOYMENT_TARGET=26.2` drops **every NAX kernel**, behind
> nothing but a CMake warning.

### [12.3 — MLX quantization: modes, group sizes, gates, and the corruption bugs](references/03-quantization.md)

Quantization in MLX is four things wearing one name: a numeric format (affine at 2/3/4/5/6/8 bits, or
`mxfp4`/`mxfp8`/`nvfp4`), a memory layout (**three arrays** — packed `uint32` weights, scales, and for affine a
biases array), a kernel-dispatch problem (`K % 64 == 0`, `transpose=True`, a gather tile constant of `BK = 64`),
and a calibration procedure. Covers the full array and module API, `gather_qmm` and why routed-only expert reads
are worth multiples rather than percentages, the four learned-quantization pipelines with their real argparse
defaults, and a pre-ship verification recipe.

> ⚠️ **SILENT FAILURE — §9 is why this guide exists.** Seven quantized-matmul defects with status as of
> 2026-07-29; **five are M5-generation-only**. The worst (mlx#3856, closed completed after fix PR
> mlx#3922 merged 2026-08-26) is an `int16`
> overflow in affine `gather_qmm`: when the flattened gathered row count exceeds 32768 and is not a multiple of
> 64, output rows are **never written** and read back whatever the recycled `MTLBuffer` last held — *"sometimes
> coincidentally plausible."* No exception, no NaN, no suspicious magnitude; the model just generates fluent
> text that is subtly wrong, and **a single-run comparison against a reference can pass by luck** (§10's
> buffer-poisoning recipe fixes that). Also silent: `nn.quantize` **skips** layers whose dimensions do not
> divide the group size, and DWQ does nothing to an `mxfp4`/`mxfp8`/`nvfp4` or 8-bit-affine model.
>
> 🔴 **GAP — seven, registered in §13** (an eighth, PR #3912's trigger and scope, was resolved by a live read
> of the PR on 2026-07-29). The one that bites: **MLX exposes no API to ask which quantized kernel
> a given call dispatched to**, so §6's gates are the only way to reason about the fast path.

### [12.4 — mlx-lm: the CLI surface, the generation API, and KV caching](references/04-mlx-lm-cli-generation-and-caching.md)

The layer where MLX becomes an LLM runtime: **18 command-line entry points** enumerated from `setup.py`; the
Python generation API (`load`, `generate`, `stream_generate`, and the `generate_step` generator underneath, with
how samplers and logits processors compose and where their defaults disagree); and the deepest treatment in this
part — **nine concrete KV-cache classes**, the trimmability contract everything else rests on, prompt caching to
disk, quantized KV (which can *increase* peak memory), speculative decoding and continuous batching. Install
**`rich` and `regex`** by hand; both are imported at module scope and missing from `install_requires`.

> ⚠️ **SILENT FAILURE — a register of six (§9).** The costliest is **the chat template you are using is not the
> one you think**: `TokenizerWrapper.apply_chat_template` applies *a* template in several situations where you
> expect yours or none, and `--use-default-chat-template` is a no-op in `mlx_lm.generate`. Then: quantized-KV
> settings change quality by three mechanisms, including `generate_step` defaulting `quantized_kv_start=0` while
> every CLI defaults to `5000`; four sampler parameters that read as configured and do nothing; kwargs dropped
> by `stream_generate`; server prompt-cache reuse returning **mismatched KV** for `ChunkedKVCache` models and
> propagating it (mlx-lm#1494, administratively closed without a fix 2026-08-21; retain `--prompt-cache-size 1` on affected
> releases); and §9.6, the
> Swift port's worse variants.

### [12.5 — `mlx_lm.server`, local agents, and distributed inference over Thunderbolt](references/05-serving-and-distributed.md)

Two halves. **Part A (§1–§13), one machine:** every server flag with its verified default, every endpoint, every
request field actually parsed, the two response fields clients get wrong (`message.reasoning`,
`usage.prompt_tokens_details.cached_tokens`), structured tool calling, reasoning models, continuous batching —
which decides whether a swarm of subagents runs concurrently or queues — and why *prompt processing*, not
decode, is the number that matters for agents. **Part B (§14–§26), many machines:** `mlx.launch`, the JSON
hostfile with its positional RDMA adjacency matrix, `mlx.distributed_config`, the Thunderbolt-5 setup sequence,
mesh versus ring, tensor versus pipeline parallelism, `mlx_lm.share`, and Apple's four-M3-Ultra figures —
**~180 → ~600 tok/s** LoRA on a 9B and ~3× decode on a 27B, carrying Apple's own caveat that the exact speedup
depends on model size and architecture.

> ⚠️ **SILENT FAILURE — four, all operational.** Model-load, OOM, unsupported-architecture and tokenizer
> failures all come back as **HTTP 404**, the same status as a mistyped URL — agent frameworks that give up on
> 4xx give up, and the real message sits unread in the body. Passing `tools` to a model that cannot call tools
> only **warns** and proceeds, indistinguishable from "the model chose not to call a tool" and productive of
> retry loops. Omitting `--allowed-origins` leaves it a *string*, degrading the membership check to a substring
> test that matches everything. And in distributed fine-tuning `--batch-size` is the **global** batch.
>
> 🔴 **GAP + an open bug cluster (§25).** The distributed backends are the newest surface in the stack and the
> tracker shows it: JACCL `MeshImpl::recv` spins forever on peer loss (mlx#3910); JACCL segfaults in
> `ibv_reg_mr` when RDMA is absent (mlx#3777); ring `SocketThread` dies silently on a transient reset and all
> ranks wedge (mlx#3862). Unresolved: **which RDMA-enablement procedure is current on macOS 26.2+**, and
> `mlx_lm.share`'s hostfile schema. Run `ibv_devices` on every node before you launch.

### [12.6 — LoRA and DoRA fine-tuning, and adding a new architecture](references/06-finetuning-and-porting-models.md)

Opens with the frame (§0): **custom Foundation Models adapters are discontinued in OS 27**, per two independent
Apple-staff forum statements, with the Adapter Training Toolkit stopping at 26.0.0 — which leaves MLX's
LoRA/DoRA as the surviving adaptation path. Then the mechanics: the four data formats and their detection order;
the complete flag surface of `mlx_lm.lora` including the ten flags that exist only in YAML; what LoRA, DoRA and
`--fine-tune-type full` actually compute, read from module source; QLoRA; rank, scale and target modules; memory
as the binding constraint (honest floor 32 GB); `mlx_lm.fuse`; and a complete worked run.

> ⚠️ **SILENT FAILURE — four.** **The chat template that trained your adapter is not the one serving it**
> (§2.5): on a thinking-capable model `apply_chat_template` defaults `enable_thinking` from the vocabulary, so
> training data is rendered with thinking on whether your completions contain reasoning or not — then
> `--ignore-chat-template`, a `transformers` upgrade, or fusing into a different base revision desynchronises
> it, with nothing detecting the mismatch. Also: `--clear-cache-threshold` parses and is **never passed to the
> trainer** (§3.5); `run()` overwrites your `training_callback` on the line after accepting it (§3.7); and
> length-based batching does not actually sort by length (§8.8).
>
> 🔴 **GAP — no ablations exist in this corpus.** mlx-lm publishes no LoRA-vs-DoRA-vs-full quality comparison,
> no rank sweep, no target-module ablation and no checkpointing overhead. The guide says so rather than
> inventing numbers; if you need the answer, you run it.

---

## Reading order, and what you can defer

**Everyone starts at [12.1](references/01-core-fundamentals.md) §1–§4 and §8.** Laziness, unified memory, the
transforms and the `mx.compile` cache key are the vocabulary the other five assume, and §8 is a day-one need
rather than a post-mortem one. **Defer** §5 (`custom_function`), §10 (streams) and §12 (interop, `.mlxfn`).

**Then branch.** *Running a model:* [12.4](references/04-mlx-lm-cli-generation-and-caching.md) §2–§3, then §4
once your workload has shared prefixes. *Shrinking one:* [12.3](references/03-quantization.md) §1–§3 and §12 to
pick a format, §10 to verify it — **§9 first on M5-class hardware**. *Serving or agent work:*
[12.5](references/05-serving-and-distributed.md) Part A end to end; Part B is a separate project, not a next
step. *Adapting one:* [12.6](references/06-finetuning-and-porting-models.md) §0–§3, then §12's worked run,
then §8 when you hit the memory wall.

**Read two out of order:** [12.2 §3](references/02-numerics-hardware-gating-and-custom-kernels.md#3-tf32-and-the-hardware-gate--one-feature-two-halves), because
`MLX_ENABLE_TF32=0` belongs in your harness before you write the tests, and
[12.4 §9.1](references/04-mlx-lm-cli-generation-and-caching.md#91-️-silent-failure--the-chat-template-you-are-using-is-not-the-one-you-think), because chat-template drift is otherwise
diagnosed as a modelling problem. **Skippable unless it is your job:**
[12.2 §7–§9](references/02-numerics-hardware-gating-and-custom-kernels.md#7-mxfastmetal_kernel-the-complete-api) — compose ops and `mx.compile` first
— and [12.5 Part B](references/05-serving-and-distributed.md), which needs two or more Macs, Thunderbolt-5
cables between *every pair*, macOS 26.2 everywhere, and a reboot per machine.

**Scope note.** The six references are complete for their declared scope. Guides 12.1, 12.2, 12.5,
and 12.6 intentionally end at §12, §9.5, §26, and §12 respectively, and their contents lists now
match those boundaries; guides 12.3 and 12.4 retain their longer end-to-end treatments.[^part12-scope]

---

## What this part deliberately does not cover

- **MLX in Swift** — `mlx-swift`, `mlx-swift-lm`, `MLXFoundationModels`, `DistributedGroup`:
  [Part 13](../part-13-mlx-swift/README.md). Concepts transfer; spellings and several footguns do not, and fixes
  propagate `mlx → mlx-c → mlx-swift → mlx-swift-lm` across four tag bumps, so Swift lags everything here.
  12.4 §9.6 is the deliberate exception — the Python bug is how you recognise the Swift one.
- **Getting an MLX model into Core AI or Foundation Models** — [Part 14](../part-14-bridges-between-stacks/README.md) for
  conversion, [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md) for `ChatCompletionsLanguageModel` and for writing
  a conformer by hand. This part shows only the wiring: point it at `http://localhost:8080/v1`.
- **Metal shaders in the TensorOps / cooperative-tensor style** — `mpp::tensor_ops::matmul2d`,
  `metal::cooperative_tensor`, execution scopes: [Part 11](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-11-metal-and-tensorops/README.md). Guide 12.2
  intentionally stops after the Python-authored kernel options in §9.5; use Part 11 for TensorOps.
  **Core AI's compression
  story** — palettization, `.aimodel` numeric formats: [Part 9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md).
- **Evaluation as a discipline** ([Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md)); **delivery and operations**
  ([Part 15](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/README.md)); **migrating off `.fmadapter`**, of which 12.6 §0 is only the
  framing ([Part 17](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/README.md)).
- **Out of scope entirely, not deferred:** vision-language fine-tuning — `mlx_lm` is text-only and
  `save_config` deletes `vision_config` from any config it writes; that is `mlx-vlm`'s job. And **RLHF / DPO /
  GRPO**: mlx-lm ships `batch_generate(return_logprobs=…)` for RL importance weighting but has **no RL trainer
  and no preference-optimization command** at this commit.

---

## Sources for this part

Strongest first. **Source read on disk:** `ml-explore/mlx` at `973e27f` (`MLX_VERSION 0.32.1`) —
`python/src/*.cpp` including the literal `nb::sig(...)` strings that *become* the published Python signatures,
`mlx/compile.cpp`, the kernels under `mlx/backend/metal/kernels/`, the CMake NAX gating, `mlx_tests.py`; and
`ml-explore/mlx-lm` at `e5baded` (2026-07-26) — `server.py` (1,871 lines), `generate.py`, `models/cache.py`,
`tokenizer_utils.py`, `lora.py`, `trainer.py`, `datasets.py`, `setup.py`, plus the five in-package Markdown
files, **at least four of which disagree with the code, where the code wins**. **The MLX documentation site**,
a 5,465-line crawl of the 0.32.0 build harvested 2026-07-27. **Apple material:** WWDC26 sessions **232**/**233**,
Tech Talk **111432** for every Apple-published M5 number, and Developer Forums threads **829108** / **831314**
(the Apple-staff adapter-sunset statements) and **836897**. **GitHub issues and PRs with maintainer answers**
from `angeloskath`, `zcbenz`, `davidkoski` and `awni`, cited by number throughout — mlx #3777, #3830, #3856,
#3860, #3862, #3875, #3883, #3885, #3887, #3910, #3912, #3922, #3924 and mlx-lm #1425, #1438, #1494, #1598 among
them. **Community measurements** are labelled as such at every point of use, with hardware and OS named inline,
and never presented as Apple figures.

[^part12-scope]: See the declared contents and terminal sections in
    [12.1](references/01-core-fundamentals.md),
    [12.2](references/02-numerics-hardware-gating-and-custom-kernels.md),
    [12.5](references/05-serving-and-distributed.md), and
    [12.6](references/06-finetuning-and-porting-models.md). API evidence is pinned to
    [`ml-explore/mlx@973e27f`](https://github.com/ml-explore/mlx/tree/973e27f82ffe68dbd626cda31ba34997045d1eb7)
    and [`ml-explore/mlx-lm@e5baded`](https://github.com/ml-explore/mlx-lm/tree/e5baded8c1d286754edb479ffbde4655a68e2758).
