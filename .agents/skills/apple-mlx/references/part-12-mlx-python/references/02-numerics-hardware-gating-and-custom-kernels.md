# Numerics, hardware gating, and writing custom Metal kernels from Python

**Part 12 · MLX in Python · Reference 02**

**Version floor.** This guide targets **MLX 0.32.x** — `v0.32.0` was tagged **2026-07-07** and the dev
line carries `MLX_VERSION_MAJOR 0 / MINOR 32 / PATCH 1` → **0.32.1**
(✅ **VERIFIED**, `mlx/version.h`, read in `notes/repos/mlx-core.md` §0). MLX itself has a *much*
lower OS floor than the rest of this series: the macOS wheels require **Apple silicon, native Python
≥ 3.10, macOS ≥ 14.0** (✅ `docs/src/install.rst`). **Nothing in this guide requires iOS 27 or
macOS 27.** The one place where the OS version becomes load-bearing is the **neural-accelerator
(NAX) path**, which needs **macOS / iOS / tvOS / visionOS 26.2 or later at runtime** *and* a GPU
architecture generation ≥ 17 (≥ 18 on phone-class parts) — see §4. Metal TensorOps, the layer
underneath that path, shipped across the **26** point releases on Apple's own narrated ladder
(26.0 base · 26.1 bfloat · 26.3 cooperative tensors as matmul inputs · 26.4 int4/int8 tensors), while
the shipped **Xcode 26.6 SDK headers annotate the relevant symbols as 26.2**. Both statements are
true and they are about different things — §4.2 gives the full story. Build from source with
**CMake ≥ 3.25, Clang ≥ 15 (C++20), Xcode ≥ 15.0, macOS SDK ≥ 14.0** (✅ `docs/src/install.rst`).

---

[^scope-source]: Source snapshot: [`ml-explore/mlx` at `973e27f`](https://github.com/ml-explore/mlx/tree/973e27f82ffe68dbd626cda31ba34997045d1eb7),
    including the Metal kernels and Python bindings this reference documents.
[^metal27-formats]: Apple's current [`MTLTensorDataType`](https://developer.apple.com/documentation/metal/mtltensordatatype)
    documentation lists Int2, UInt2, Float4E2M1, Float8E4M3, Float8E5M2, and Float8UE8M0. Apple
    documents scale planes through
    [`MTLTensorAuxiliaryPlaneDescriptor`](https://developer.apple.com/documentation/metal/mtltensorauxiliaryplanedescriptor)
    and [`MTLTensorDescriptor.auxiliaryPlanes`](https://developer.apple.com/documentation/metal/mtltensordescriptor/auxiliaryplanes).

## What this covers

This is the guide about **where MLX stops being a portable array library and starts being a program
running on one specific piece of Apple silicon.** Three themes, tightly coupled:

1. **Numeric types** — `float32` / `float16` / `bfloat16` and which one is right when; the integer
   family; what "complex support" actually means in MLX; and the one dtype that is CPU-only.
2. **The hardware gate** — the single most consequential and least visible thing in MLX 0.32 on
   M5-class hardware. `relaxed_precision = true` is **hardcoded** in MLX's NAX matmul kernel, and
   the *host* compensates by gating `float32` through the `MLX_ENABLE_TF32` environment variable.
   These are **one feature in two halves**, and if you only learn one of them you will draw wrong
   conclusions. The consequence is stark: whether your `float32` matmul runs at reduced internal
   precision depends on an environment variable that almost nobody sets, on hardware you may not
   have tested on, **and there is no runtime signal at all.**
3. **Custom Metal kernels from Python** — `mx.fast.metal_kernel`, the complete API, a complete
   working example, and an honest account of when writing one is the right call versus composing
   existing ops or reaching for `mx.compile`.

Threaded through all three is the property this series exists to document: **almost none of these
failures throw.** A `float32` matmul at TF32 precision returns a plausible array. A fused attention
kernel that falls back to the unfused path returns the *correct* answer, just slower and with a
gigabyte of transient allocation. A custom kernel with `ensure_row_contiguous=False` and no
`elem_to_loc` call reads whatever memory the strides happen to land on. You find these with a
profiler, a differential test, or a bug report from a user on different hardware.

## What this does *not* cover

- **The MLX array model, lazy evaluation, `mx.compile`, transforms, `mlx.nn`, optimizers.** Those are
  the other guides in [Part 12](../README.md). `mx.compile` appears here only where it explains *why*
  `mx.fast`'s fused primitives exist (§6.1).
- **Quantization as a modelling decision** — `mx.quantize`, `nn.QuantizedLinear`, the affine /
  mxfp4 / mxfp8 / nvfp4 mode table. That is Part 12's quantization guide. Quantized dtypes appear
  here only as consumers of the same NAX gate (§4.4).
- **Writing Metal shaders in the TensorOps / cooperative-tensor style**, `mpp::tensor_ops::matmul2d`,
  `metal::cooperative_tensor`, execution scopes. That is
  [Part 11](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-11-metal-and-tensorops/README.md). §7 covers what you *can* reach from a
  Python-authored kernel; the C++ extension path is out of scope for this reference.
- **Distributed MLX**, `mlx.launch`, JACCL/RDMA. Part 12's distributed guide.
- **MLX in Swift.** [Part 13](../../part-13-mlx-swift/README.md). Note in passing that fixes propagate
  **mlx → mlx-c → mlx-swift → mlx-swift-lm / mlx-swift-examples**, four tag bumps, so Swift lags
  everything here (community-observed, mlx-swift-examples#462).

## What you need

- **An Apple silicon Mac** with MLX 0.32.x installed (`pip install mlx`). Check you are on a native
  interpreter: `python -c "import platform; print(platform.processor())"` must print `arm`
  (✅ `docs/src/install.rst` troubleshooting).
- For §4 and §5 to be more than theory, **hardware on both sides of the gate** — one M5-class
  (architecture generation 17) machine and one earlier one. If you only have one, §4.5's probe
  script tells you which side you are on, and `MLX_METAL_GPU_ARCH` lets you *simulate* the far
  side (§4.5).
- For §7–§9, nothing beyond MLX itself. Custom Metal kernels are JIT-compiled from a Python string;
  **you do not need Xcode, a `.metal` file, or a build step.** That is the whole point of the API.
- Willingness to read a number and ask "on what hardware, at what OS, measured by whom." Every
  figure in this guide carries that attribution, and several of the most-quoted MLX numbers in
  circulation do not.

---

## ⚠️ Read this before you trust a signature below

MLX moves weekly. The clone this guide was written against is **shallow (50 commits)** and its HEAD
is `973e27f`. That has two consequences you must hold onto:

> 🔴 **GAP — dates from git history are UNVERIFIED.** `git log` on most MLX paths returns the
> **graft boundary** (`ca60290`, "Fix docstring nits (#3758)"), not the introducing commit —
> `git log --diff-filter=A` returns the same artificial root for every NAX file. Anywhere this guide
> mentions when something landed, the *pull-request record* is the source, not the commit date.
> To resolve: `git -C <mlx-repo> fetch --unshallow` and re-run.
> Source: `notes/repos/mlx-tensorops-kernels.md` §13.

> ⚠️ **The NAX path is new and actively being fixed.** Three NAX correctness pull requests opened in
> the three days before **2026-07-27** — on a **2026-08-03 `gh` re-check** #3912/#3922 were still
> open and #3924 was **closed unmerged 2026-08-02**: **#3912** (fp quantized matmul corruption
> when the quantized dim is not a multiple of 32), **#3922** (sorted `gather_qmm` NAX boundary
> handling), **#3924** (a tile-shape `static_assert` for `tile_matmad_nax` — proposed because the
> function has **no `else` branch**, so odd tile shapes compile to *nothing* and the GEMM produces
> garbage). Treat every M5-specific behaviour in this guide as sharp-edged and version-sensitive.
> Source: `notes/repos/mlx-tensorops-kernels.md` §13; `notes/repos/issues-mlx-stack.md` §11.

The evidence ladder used throughout, strongest first:

1. **MLX repository source read on disk** — headers, kernels, Python bindings, tests, CMake. For
   MLX this outranks everything, including MLX's own documentation site, because the docs lag.
2. **The MLX documentation site** (a 5,465-line crawl of `ml-explore.github.io/mlx`, serving the
   0.32.0 build). Authoritative for prose and worked examples; occasionally behind the source.
3. **Apple documentation, WWDC sessions and Tech Talks.** Tech Talk 111432 ("Accelerate your machine
   learning workloads with the M5 and A19 GPUs") is the source for every Apple-published M5 number
   here.
4. **GitHub issues and pull requests with maintainer answers** (`angeloskath`, `zcbenz`,
   `davidkoski`, `awni`). Quoted and attributed.
5. **Community measurements** — always labelled as such, with hardware and OS.

Every non-obvious claim carries ✅ **VERIFIED** (quoted from a source read this session, with the
citation), 🟡 **RECONSTRUCTED** (concept attested, exact spelling or usage inferred), or 🔴 **GAP**
(could not verify — the box says what is unknown, what would resolve it, and a safe default).

---

## Contents

- [0. Orientation: the three questions](#0-orientation-the-three-questions)
- [1. The numeric types](#1-the-numeric-types)
  - [1.1 The complete dtype table](#11-the-complete-dtype-table)
  - [1.2 Defaults, promotion, and the category lattice](#12-defaults-promotion-and-the-category-lattice)
  - [1.3 float32 — the default, and what it costs](#13-float32--the-default-and-what-it-costs)
  - [1.4 float16 vs bfloat16 — the decision that actually matters](#14-float16-vs-bfloat16--the-decision-that-actually-matters)
  - [1.5 float64: CPU only, and why](#15-float64-cpu-only-and-why)
  - [1.6 The integer family](#16-the-integer-family)
  - [1.7 Complex support: exactly one dtype](#17-complex-support-exactly-one-dtype)
  - [1.8 fp8 and fp4 are ops and storage formats, not dtypes](#18-fp8-and-fp4-are-ops-and-storage-formats-not-dtypes)
  - [1.9 Reinterpreting bits: `mx.view` vs `astype`](#19-reinterpreting-bits-mxview-vs-astype)
- [2. Choosing a dtype in practice](#2-choosing-a-dtype-in-practice)
- [3. TF32 and the hardware gate — one feature, two halves](#3-tf32-and-the-hardware-gate--one-feature-two-halves)
  - [3.1 Half one: `relaxed_precision = true`, hardcoded](#31-half-one-relaxed_precision--true-hardcoded)
  - [3.2 Half two: the host gates float32 on `MLX_ENABLE_TF32`](#32-half-two-the-host-gates-float32-on-mlx_enable_tf32)
  - [3.3 ⚠️ SILENT FAILURE: precision you did not choose, with no runtime signal](#33-️-silent-failure-precision-you-did-not-choose-with-no-runtime-signal)
  - [3.4 What it measures out at](#34-what-it-measures-out-at)
  - [3.5 Three mechanics that cost people days](#35-three-mechanics-that-cost-people-days)
  - [3.6 The blast radius, downstream](#36-the-blast-radius-downstream)
  - [3.7 What to actually do](#37-what-to-actually-do)
- [4. NAX, the M5 neural accelerator, and how to tell whether you are on the fast path](#4-nax-the-m5-neural-accelerator-and-how-to-tell-whether-you-are-on-the-fast-path)
  - [4.1 What the hardware is, per Apple](#41-what-the-hardware-is-per-apple)
  - [4.2 The version story, stated carefully](#42-the-version-story-stated-carefully)
  - [4.3 Three gates, all of which must pass](#43-three-gates-all-of-which-must-pass)
  - [4.4 There is no capability query — here is the heuristic MLX uses](#44-there-is-no-capability-query--here-is-the-heuristic-mlx-uses)
  - [4.5 A probe you can run, and an A/B switch](#45-a-probe-you-can-run-and-an-ab-switch)
  - [4.6 Apple's own numbers, with their baselines](#46-apples-own-numbers-with-their-baselines)
  - [4.7 NAX changes the algorithm, not just the kernel](#47-nax-changes-the-algorithm-not-just-the-kernel)
- [5. ⚠️ The silent SDPA fallback](#5-️-the-silent-sdpa-fallback)
  - [5.1 The API, and the four notes that matter](#51-the-api-and-the-four-notes-that-matter)
  - [5.2 The complete fallback table](#52-the-complete-fallback-table)
  - [5.3 What the fallback actually does](#53-what-the-fallback-actually-does)
  - [5.4 What it costs, measured](#54-what-it-costs-measured)
  - [5.5 Detecting the fallback — four techniques](#55-detecting-the-fallback--four-techniques)
  - [5.6 Fixing it: pad the head dimension](#56-fixing-it-pad-the-head-dimension)
  - [5.7 Two adjacent SDPA traps](#57-two-adjacent-sdpa-traps)
- [6. The rest of `mx.fast`, and why fused beats hand-composed](#6-the-rest-of-mxfast-and-why-fused-beats-hand-composed)
  - [6.1 The mechanical reason: `mx.compile` does not fuse reductions](#61-the-mechanical-reason-mxcompile-does-not-fuse-reductions)
  - [6.2 `rms_norm` and `layer_norm`](#62-rms_norm-and-layer_norm)
  - [6.3 `rope`](#63-rope)
  - [6.4 When *not* to use the fused primitive](#64-when-not-to-use-the-fused-primitive)
- [7. `mx.fast.metal_kernel`: the complete API](#7-mxfastmetal_kernel-the-complete-api)
  - [7.1 Constructor](#71-constructor)
  - [7.2 The returned callable](#72-the-returned-callable)
  - [7.3 How the function signature is generated](#73-how-the-function-signature-is-generated)
  - [7.4 `grid` and `threadgroup` are in THREADS](#74-grid-and-threadgroup-are-in-threads)
  - [7.5 Math mode](#75-math-mode)
- [8. A complete worked example](#8-a-complete-worked-example)
- [9. The advanced options](#9-the-advanced-options)
  - [9.1 Strides and non-contiguous inputs](#91-strides-and-non-contiguous-inputs)
  - [9.2 Template parameters](#92-template-parameters)
  - [9.3 `header=` for helpers and includes](#93-header-for-helpers-and-includes)
  - [9.4 Atomic outputs and `init_value` — the VJP pattern](#94-atomic-outputs-and-init_value--the-vjp-pattern)
  - [9.5 Debugging: `verbose=True`, Metal logging, GPU capture](#95-debugging-verbosetrue-metal-logging-gpu-capture)

**Scope:** this reference intentionally ends at §9.5; the contents list includes only sections
present in this file. API spellings and kernel gates are pinned to the inspected MLX revision.[^scope-source]

---

## 0. Orientation: the three questions

Every performance or precision question in MLX resolves into three separate questions that people
routinely collapse into one. Keeping them apart is most of the skill.

```
   Question 1: what dtype did you ASK for?
        mx.float32 / mx.float16 / mx.bfloat16 / mx.int8 / ...
        ↓  you control this; it is in your source code
   Question 2: which KERNEL did MLX pick?
        steel GEMM · steel GEMM (NAX) · gemv · gemv_wide · split-K · fused SDPA · unfused SDPA
        ↓  MLX controls this; it depends on shape, dtype, mask, training-ness, and hardware
   Question 3: what PRECISION does that kernel compute at internally?
        IEEE fp32 · TF32-class (relaxed_precision) · fp32 accumulate over fp16 operands · ...
        ↓  the kernel controls this; on the NAX path it is HARDCODED
```

The dtype you asked for constrains but does not determine the answer to questions 2 and 3.
Specifically, on MLX 0.32.x:

- The **same dtype and the same op** give you different internal precision depending on **operand
  shape** — a matvec (`M == 1` or `N == 1`) does not take the NAX route and stays exact `float32`,
  while the matmul next to it does not (community-established, mlx#3860; §3.5).
- The **same code on two Macs** gives you different numbers, because the kernel selection depends on
  the GPU architecture generation (§4).
- The **fused attention primitive** silently becomes three unfused ops when your head dimension is
  not in a small allow-list (§5).

None of these produce a warning, an exception, a log line, or a queryable flag. Question 2 and
question 3 are answerable today only by reading MLX's source, running a differential test against a
CPU-stream or `float64` reference, or capturing a Metal trace. §4.5 and §5.5 give you the tooling.

The rest of this guide is: §1–§2 answer question 1 properly, §3–§4 answer question 3, §5 answers
question 2 for the one op where it hurts most, and §6–§9 are about deliberately taking control of
question 2 yourself by writing the kernel.

---

## 1. The numeric types

### 1.1 The complete dtype table

✅ **VERIFIED** — from `docs/src/python/data_types.rst`, transcribed in `notes/repos/mlx-core.md`
§12 and corroborated by the documentation-site crawl.

| `mx.` name | Bytes | Description | GPU? |
|---|---:|---|---|
| `bool_` | 1 | Boolean | yes |
| `uint8` | 1 | 8-bit unsigned integer | yes |
| `uint16` | 2 | 16-bit unsigned integer | yes |
| `uint32` | 4 | 32-bit unsigned integer | yes |
| `uint64` | 8 | 64-bit unsigned integer | yes |
| `int8` | 1 | 8-bit signed integer | yes |
| `int16` | 2 | 16-bit signed integer | yes |
| `int32` | 4 | 32-bit signed integer | yes |
| `int64` | 8 | 64-bit signed integer | yes |
| `bfloat16` | 2 | 16-bit brain float — **8 exponent bits, 7 mantissa bits** | yes |
| `float16` | 2 | IEEE half — **5 exponent bits, 10 mantissa bits** | yes |
| `float32` | 4 | IEEE single | yes |
| `float64` | 8 | IEEE double | ❌ **CPU only** |
| `complex64` | 8 | 64-bit complex (two `float32`s) | yes |

That is the entire list. There is **no** `float8` dtype, **no** `float4` dtype, **no** `int4` dtype,
**no** `complex128`, and **no** `bool` packed bit type. §1.8 explains where the low-precision
floating formats actually live, because a lot of MLX material implies dtypes that do not exist.

### 1.2 Defaults, promotion, and the category lattice

✅ **VERIFIED** — `docs/src/python/data_types.rst`; `mlx/dtype.h:42-49`.

**Defaults:** MLX defaults to **`float32` for floating-point literals and `int32` for integer
literals.** This differs from PyTorch (also `float32`, but `int64` for integers) and from NumPy on
64-bit platforms (`float64` / `int64`). If you are porting code, the integer default is the one that
bites — an index array that was `int64` in NumPy arrives as `int32` in MLX.

The category lattice, used by `mx.issubdtype`:

```
generic
├── number
│   ├── integer
│   │   ├── signedinteger        (int8, int16, int32, int64)
│   │   └── unsignedinteger      (uint8, uint16, uint32, uint64)
│   └── inexact
│       ├── floating             (float16, bfloat16, float32, float64)
│       └── complexfloating      (complex64)
└── (bool_ is `generic` but not `number`)
```

✅ **VERIFIED** — the seven category names are quoted from `mlx/dtype.h:42-49`:
`complexfloating, floating, inexact, signedinteger, unsignedinteger, integer, number, generic`.

🟡 **RECONSTRUCTED** — the *tree shape* above (which category nests inside which) is inferred from
the names and from standard NumPy semantics. The names are exact; the parent-child edges are not
individually quoted from source. Safe default: use `mx.issubdtype(x.dtype, mx.floating)` and
`mx.issubdtype(x.dtype, mx.integer)`, which are the two edges everything actually depends on, and
verify with a one-liner on your machine before relying on a subtler one.

Introspection surface, all ✅ VERIFIED as exported symbols
(`python/src/mlx.cpp` / `docs/src/python/data_types.rst`):

```python
import mlx.core as mx

mx.Dtype            # the dtype type itself
mx.DtypeCategory    # the category type
mx.issubdtype(a, b) # dtype-or-category subsumption test
mx.isdtype(x, kind) # Array-API style predicate
mx.can_cast(a, b)   # is a -> b a safe cast?
mx.result_type(*xs) # promotion result for a set of dtypes/arrays
mx.finfo(dtype)     # machine limits for a float dtype
```

A worked promotion check you can run:

```python
import mlx.core as mx

print(mx.array([1.0]).dtype)                 # float32   (float literal default)
print(mx.array([1]).dtype)                   # int32     (int literal default)
print(mx.result_type(mx.float16, mx.int32))  # dtype promotion for a mixed expression
print(mx.issubdtype(mx.bfloat16, mx.floating))
print(mx.finfo(mx.float16).max, mx.finfo(mx.bfloat16).max)
```

> 🔴 **GAP — the exact `finfo` field set is unverified.** `mx.finfo` is confirmed to exist as an
> exported symbol (`docs/src/python/data_types.rst`), but its attribute names (`.max`, `.min`,
> `.eps`, `.tiny`, `.resolution`, …) were not read from the binding source this session. The line
> above assumes `.max` by analogy with NumPy. **To resolve:** `print(dir(mx.finfo(mx.float16)))` on
> your machine, or read `python/src/` for the `finfo` binding. **Safe default:** print the object
> and read what it has rather than assuming a NumPy-identical surface.

### 1.3 `float32` — the default, and what it costs

`float32` is MLX's default float and the right choice for: anything you are treating as ground truth,
numerical code that is not a neural network (linear algebra, signal processing, optimisation),
loss accumulation, and — critically — **any reference implementation you are diffing another
implementation against.**

Two things about `float32` in MLX 0.32 that are not obvious:

1. **It is not necessarily computed at `float32` precision.** This is §3, and it is the single most
   important section of this guide. On architecture-generation-17 hardware (M5 class) with
   macOS ≥ 26.2, a `float32` matmul routes through a kernel with `relaxed_precision = true`
   hardcoded, unless you set `MLX_ENABLE_TF32=0` before the first matmul.
2. **It is not portable across Apple silicon generations at the bit level.** Community-measured
   (mlx-lm#1280): the same model, same prompt, `temperature: 0`, same seed, same `max_tokens`
   produced different *generated-token counts* on an M5 Max versus an M3 Ultra —
   e.g. **7857 vs 6145 tokens** on one AIME25 case, both reaching the correct answer. **Cross-device
   bit reproducibility is not a property MLX offers.** Design your tests accordingly (§3.7).

A separate, older instance of the same class: `mx.random.normal` produces different `float32` output
on an M1 Max versus an M3 Ultra / M5, traced to the FMA chain in the Metal `erfinv` kernel
(community-reported, mlx#3568, referenced from mlx#3702's thread; unverified beyond that reference).

### 1.4 `float16` vs `bfloat16` — the decision that actually matters

Both are 2 bytes. They differ in how they spend those 16 bits, and this is the whole decision:

| | exponent bits | mantissa bits | dynamic range | relative precision |
|---|---:|---:|---|---|
| `float16` | 5 | 10 | narrow (~6e-5 … 65504) | **~11 significant bits** |
| `bfloat16` | 8 | 7 | **same as `float32`** | ~8 significant bits |

✅ **VERIFIED** — the bit splits are quoted from `docs/src/python/data_types.rst`, which describes
`bfloat16` as "brain float (e8, m7)" and `float16` as "IEEE half (e5, m10)".

**The practical rule.** `bfloat16` has `float32`'s exponent field. That means **anything that fits
in `float32` fits in `bfloat16` without overflowing or flushing to zero** — you just lose mantissa.
`float16` will overflow to `inf` at 65504 and underflow to zero around 6e-5, which is exactly the
regime that attention logits, un-normalised activations, and gradient accumulation live in.

Consequences:

- **For transformer inference and training, prefer `bfloat16`.** This is why every modern checkpoint
  ships in it and why MLX's own quantized kernels dequantise the MX/NV floating-point formats into
  **`bfloat`** in threadgroup memory (✅ VERIFIED, `fp_quantized_nax.h:198-204`: the default
  `Wtype = bfloat`).
- **For anything where you need the extra ~3 bits of mantissa and you know your dynamic range is
  bounded, `float16` is genuinely more accurate.** Image pixel data in [0, 1], normalised feature
  maps, and post-softmax probabilities are the classic cases.
- **Do not use `float16` for a running sum over many terms.** With 10 mantissa bits, adding a small
  value to a large accumulator stops changing the accumulator far sooner than you expect.
  Accumulate in `float32`.

A concrete example of MLX making this decision for you: **`mx.fast.scaled_dot_product_attention`
performs the softmax in `float32` regardless of the input precision** (✅ VERIFIED, quoted verbatim
from `docs/src/python/fast.rst`: *"The softmax operation is performed in `float32` regardless of the
input precision."*). That is a deliberate defence against exactly the `float16` range problem, and it
is one of several reasons the fused primitive is better than your hand-composed version (§6).

**A `float16`-specific hardware trap**, community-measured and worth knowing before you assume a
2-byte dtype is uniformly cheap: on **M5-class hardware** the divergence between batched and
single-sequence attention in `float16` / `bfloat16` traces to the **NAX attention kernel's masked
reduction at 64-aligned head dims** — and `MLX_ENABLE_TF32=0` does **nothing** about it, because the
TF32 gate's third clause (`dtype != float32`) is satisfied regardless. The only lever that moves it
is forcing a different architecture string. Source: mlx#3897 (closed 2026-08-09; 7 comments at
the research snapshot), M5 base
`applegpu_g17g`, 32 GB, macOS 26.5.2 / build 25F84, reproduced on both mlx 0.31.2 and 0.32.0; M3 Max
clean. Max |Δ logprob| ≈ **0.031–0.039**, argmax always matched.

### 1.5 `float64`: CPU only, and why

✅ **VERIFIED**, `docs/src/python/data_types.rst`, verbatim:
*"Using `float64` arrays on the GPU will result in an exception."*

This is one of the very few MLX failures that **does** throw, which makes it pleasant by comparison
with everything else in this guide. Apple GPUs do not implement double precision; MLX does not
emulate it.

The practical use for `float64` is as a **reference**. When you need to know whether a `float32`
result is right, compute the same thing in `float64` on the CPU stream and measure the relative
error. That is exactly the methodology behind the numbers in §3.4.

```python
import mlx.core as mx

def fp64_reference_matmul(a32, b32):
    """Ground-truth matmul, CPU stream, float64. Slow; for testing only."""
    with mx.stream(mx.cpu):
        a64 = a32.astype(mx.float64)
        b64 = b32.astype(mx.float64)
        return (a64 @ b64)

def rel_frobenius_error(approx, exact64):
    with mx.stream(mx.cpu):
        d = (approx.astype(mx.float64) - exact64)
        return (mx.sqrt((d * d).sum()) / mx.sqrt((exact64 * exact64).sum())).item()
```

🟡 **RECONSTRUCTED** — the `with mx.stream(mx.cpu):` context manager is ✅ VERIFIED as
`mx.StreamContext` / `mx.stream` (`python/src/stream.cpp`), and `float64`-on-CPU is ✅ VERIFIED. The
composition above is idiomatic but was not copied from a source file; test it on a small case before
trusting it as a harness.

### 1.6 The integer family

Eight integer types (`int8`…`int64`, `uint8`…`uint64`) plus `bool_`. Things worth knowing:

**Indexing is not bounds-checked.** ✅ VERIFIED, `docs/src/usage/indexing.rst`, verbatim:

> *"Indexing does not perform bounds checking. Indexing out of bounds is undefined behavior."*

with the stated reason: *"exceptions cannot propagate from the GPU. Performing bounds checking for
array indices before launching the kernel would be extremely inefficient."* An out-of-range `int32`
index does not raise; it reads whatever memory the offset lands on. This is the integer-type failure
mode you are most likely to hit in practice.

**Duplicate-index scatter is nondeterministic.** ✅ VERIFIED, `docs/src/usage/indexing.rst`:
`a[[0, 0]] = mx.array([4, 5])` may leave either 4 or 5. Use the `.at` API instead, which correctly
applies all updates:

```python
a = mx.array([0, 0]); idx = mx.array([0, 1, 0, 1])
a[idx] += 1          # -> array([1, 1], dtype=int32)   WRONG if you meant "count"
a = mx.array([0, 0])
a = a.at[idx].add(1) # -> array([2, 2], dtype=int32)   correct
```

✅ VERIFIED verbatim from `python/src/array.cpp:430`'s docstring: *"Regular in-place updates map to
assignment. For instance `x[idx] += y` maps to `x[idx] = x[idx] + y`. As a result, assigning to the
same index ignores all but one update."* The `.at` methods are `add, subtract, multiply, divide,
maximum, minimum`.

**`mx.empty` is `mx.zeros`.** ✅ VERIFIED, `python/src/ops.cpp` Array-API alias block:
`mx.empty = mx.zeros`, `mx.empty_like = mx.zeros_like`. Unlike NumPy, MLX's `empty` allocates
*zeroed* memory. If you were relying on `empty` for a cheap uninitialised buffer, you are paying for
a fill. (In a custom Metal kernel, output arrays are a different story — see §9.4.)

**Bit manipulation** is available: `mx.bitwise_and / _or / _xor / _invert`, `mx.left_shift`,
`mx.right_shift`, with Array-API aliases `mx.bitwise_left_shift` / `mx.bitwise_right_shift`
(✅ VERIFIED, `docs/src/python/ops.rst` + the alias block).

**`uint32` is the packing type for quantized weights.** MLX's affine quantization packs `b`-bit
values into unsigned 32-bit integers from the low bits upward — for 4-bit, eight elements per
`uint32` with the first in bits 0–3 (✅ VERIFIED, `python/src/ops.cpp:4649-4660` `quantize`
docstring). `mx.dequantize` will reject anything else: `"[dequantize] The matrix should be given as a
uint32"`. If you ever inspect a quantized checkpoint and wonder why the last dimension is 1/8 of what
you expected, this is why.

### 1.7 Complex support: exactly one dtype

`complex64` — two `float32`s, 8 bytes — is the entire complex story. There is no `complex128`
(which follows from §1.5: no `float64` on the GPU).

What works, ✅ VERIFIED from `docs/src/python/ops.rst` and `mlx/compile.cpp:77`:

- `mx.real`, `mx.imag`, `mx.conj` / `mx.conjugate`; `array.real` / `array.imag` / `array.conj` as
  methods.
- The whole `mx.fft` module (`fft, ifft, fft2, ifft2, fftn, ifftn, rfft, irfft, rfft2, irfft2,
  rfftn, irfftn, fftfreq, rfftfreq, fftshift, ifftshift`) — this is the main reason `complex64`
  exists.
- `Conjugate`, `Real` and `Imag` are in `mx.compile`'s **fusable unary** primitive list, so complex
  element-wise chains do fuse.
- `mx.linalg.eig` / `eigvals` (non-symmetric eigendecomposition) are present in 0.32's `linalg`
  surface, which is newer than many MLX releases.

Two cautions:

> ⚠️ **Complex is excluded from the NAX matmul path outright.** The Metal gate reads
> `!issubdtype(a.dtype(), complexfloating)` — ✅ VERIFIED, `mlx/backend/metal/matmul.cpp:916-918`.
> So a `complex64` matmul on M5 does **not** get the neural accelerator. On CUDA the situation is
> the opposite: `dtype_to_compute_type()` in `mlx/backend/cuda/gemms/cublas_gemm.cpp` selects
> `CUBLAS_COMPUTE_32F_FAST_TF32` for **`float32` *and* `complex64`** — so on NVIDIA hardware your
> complex matmul is TF32-reduced by default and on Apple silicon it is not. Source:
> mlx#3860, contributor reading source, corroborated by the same file path in `notes/repos/mlx-core.md`.

> ⚠️ **Complex autodiff was recently buggy.** Commit `af55406` is titled *"Fix complex vjps for
> several unary ops (#3766)"*. **UNVERIFIED which ops and which MLX version** — the shallow clone
> cannot date it, and the PR body was not read. **Safe default:** if you differentiate through
> complex unary ops, pin an MLX version, write a finite-difference check, and re-run it after every
> upgrade.

### 1.8 fp8 and fp4 are ops and storage formats, not dtypes

This trips people up constantly, because MLX's quantization surface mentions `e8m0`, `e4m3` and
`e2m1`, and it is natural to assume those are dtypes you can create arrays in. They are not.

✅ **VERIFIED** — the quantization mode table, quoted verbatim from `python/src/ops.cpp:4649-4660`
(the `quantize` docstring); `*` marks the default when unspecified:

| mode | group size | bits | scale type | bias |
|---|---|---|---|---|
| `affine` | 32, 64\*, 128 | 2, 3, 4\*, 5, 6, 8 | same as input | yes |
| `mxfp4` | 32\* | 4\* | `e8m0` | no |
| `mxfp8` | 32\* | 8\* | `e8m0` | no |
| `nvfp4` | 16\* | 4\* | `e4m3` | no |

Those scale types are **encodings inside a `uint8` buffer**, decoded in software. ✅ VERIFIED from
`notes/repos/mlx-tensorops-kernels.md` §10: `fp8_e8m0`, `fp8_e4m3` and `fp4_e2m1` are **plain structs
with hand-written bit manipulation** in MLX's own `mlx/backend/metal/kernels/fp8.h` and `fp4.h`,
loaded from a `uint8_t` by reinterpret-cast:

```cpp
// fp_quantized_nax.h:31-38 — MLX's own software scale decode
template <typename T, int group_size>
static inline T dequantize_scale(uint8_t s) {
  if constexpr (group_size == 16) {
    return T(*(thread fp8_e4m3*)(&s));   // nv scale
  } else {
    return T(*(thread fp8_e8m0*)(&s));
  }
}
```

**At the pinned MLX revision, these are software codecs rather than MLX dtypes.** The negative
header search behind the earlier wording was performed against Xcode 26.6. Xcode 27 now documents
native `MTLTensorDataType` cases for int2, FP4, FP8, and E8M0 plus auxiliary scale planes; that does
not change how this MLX snapshot implements its own `to_fp8`, `from_fp8`, MX, and NV paths.[^metal27-formats]

The two ops that do exist:

```python
def to_fp8(x: array, *, stream=None) -> array               # -> uint8, E4M3 encoded
def from_fp8(x: array, dtype: Dtype = bfloat16, *, stream=None) -> array
```

✅ **VERIFIED** — exact `nb::sig` strings from `python/src/ops.cpp`. Note the asymmetry: `to_fp8`
produces a **`uint8`** array (the bit pattern), and `from_fp8` defaults its output to **`bfloat16`**,
not `float32`. If you round-trip without passing `dtype=`, you silently change precision class.

### 1.9 Reinterpreting bits: `mx.view` vs `astype`

Two operations that look similar and are completely different:

```python
def astype(dtype, stream=None) -> array   # CONVERT the value
def view(a, dtype: Dtype, stream=None)    # REINTERPRET the bits
```

✅ **VERIFIED**, `python/src/ops.cpp`, `view` docstring, verbatim:

> *"the view op does not imply that the input and output arrays share their underlying data. The
> view only guarantees that the binary representation of each element (or group of elements) is the
> same."*

So `mx.view` is a bit-cast, **not** a NumPy-style memory view — MLX may copy. The output shape
changes along the last axis when item sizes differ. Use it to inspect float bit patterns:

```python
import mlx.core as mx

x = mx.array([1.0, -0.0, float("inf")], dtype=mx.float32)
bits = mx.view(x, mx.uint32)
print([hex(int(b)) for b in bits])   # forces evaluation
```

Related trap in the same family: **slicing copies in MLX**, unlike NumPy. `b = a[:]` then `b[2] = 0`
leaves `a` unchanged; but plain aliasing `b = a` does share (✅ VERIFIED,
`docs/src/usage/indexing.rst`). And `mx.as_strided` carries a documented warning that it
*"can lead to the resulting array pointing to invalid memory locations which can result into
crashes."*

Finally, the NumPy bridge and `bfloat16`:

> ⚠️ **NumPy has no `bfloat16`.** Converting a `bfloat16` MLX array with `np.array(a)` raises
> `Item size 2 for PEP 3118 buffer format string does not match the dtype V item size 0.`
> ✅ VERIFIED, `docs/src/usage/numpy.rst`. Cast first: `np.array(a.astype(mx.float32))`.
> In the other direction, **NumPy `float64` silently becomes MLX `float32`** — which is usually what
> you want, and is occasionally the reason your "reference" implementation is not one.

---

## 2. Choosing a dtype in practice

A decision table, with the reason attached to each row. Everything here follows from §1 plus the
gating in §3–§5.

| You are… | Use | Because |
|---|---|---|
| Running a transformer for inference | **`bfloat16`** | Matches how checkpoints ship; full `float32` exponent range; the fused SDPA kernel and the NAX GEMM both accept it |
| Training / fine-tuning a transformer | **`bfloat16`** activations, `float32` optimizer state | Gradient magnitudes span decades; `float16` flushes the small tail to zero |
| Writing a numerical reference to diff against | **`float32`**, plus a `float64` CPU-stream oracle (§1.5) | `float64` is the only thing on the machine that is unambiguously right |
| Doing signal processing / FFTs | **`float32` → `complex64`** | Only complex dtype; `float64` is CPU-only and the FFT kernels are GPU |
| Storing image data in [0, 1] | **`float16`** | Bounded range, and 10 mantissa bits beats bfloat16's 7 |
| Accumulating a long sum | **`float32`** (or `float64` on CPU) | 2-byte accumulators stall |
| Indexing / gather indices | **`int32`** (the default) | Matches MLX's default; `int64` costs bandwidth and buys nothing under 2^31 elements |
| Shipping a memory-constrained model | quantized weights (Part 12's quantization guide) + `bfloat16` activations | The quantized kernels dequantise to `bfloat`/`half` anyway |
| Needing bit-identical results across two Macs | **you cannot have this** | §1.3, §3.4, §4 — kernel selection is hardware-dependent |

Two rules that are worth internalising because they cut across all of the above:

**Rule 1 — the dtype of the *accumulator* is not the dtype of the *operands*.** MLX's kernels
generally accumulate in a wider type than they load. The fused SDPA does its softmax in `float32`
(✅ VERIFIED, §1.4). MLX's quantized NAX kernels dequantise into `bfloat` threadgroup memory before
the matmul (✅ VERIFIED, `fp_quantized_nax.h:198-204`). Asking "what dtype is my model" is not the
same as asking "what precision is my model computed at", and §3 is where that distinction becomes
expensive.

**Rule 2 — a dtype change can change which kernel runs.** This is not a hypothetical. The NAX gate
is literally written as a dtype test:

```cpp
bool use_nax = metal::is_nax_available() &&
    !issubdtype(a.dtype(), complexfloating) &&
    (env::enable_tf32() || a.dtype() != float32);
```

✅ **VERIFIED** — `mlx/backend/metal/matmul.cpp:916-918`, quoted verbatim. Casting a matmul's inputs
from `float32` to `bfloat16` does not just halve the bytes; on gen-17 hardware with
`MLX_ENABLE_TF32=0` it moves you from a non-NAX kernel to a NAX kernel. Benchmarks that vary dtype
are therefore also varying algorithm, and you should say so when you publish them.

---

## 3. TF32 and the hardware gate — one feature, two halves

This is the section to read if you read nothing else.

There is a feature in MLX 0.32 with **no name in the API, no runtime query, no log line and no
documentation page**, which decides whether your `float32` matrix multiplication is computed at
`float32` precision. It is implemented in two places that never mention each other: a hardcoded
`true` inside a Metal kernel, and an environment variable read on the host. Understanding either
half alone produces a wrong mental model. Here are both.

### 3.1 Half one: `relaxed_precision = true`, hardcoded

MLX's entire contact surface with Apple's Metal Performance Primitives TensorOps is **one function**,
`mma`, written twice with mirrored operand shapes. Here is the descriptor it builds, quoted verbatim
from `mlx/backend/metal/kernels/steel/gemm/nax.h` (the `mma` function spans lines 387–456; the
descriptor construction is at lines ~401–409):

```cpp
constexpr auto desc = mpp::tensor_ops::matmul2d_descriptor(
    16,                     // m
    32,                     // n
    16,                     // k
    transpose_a,            // transpose_left
    transpose_b,            // transpose_right
    true,                   // relaxed_precision   <-- THIS
    mpp::tensor_ops::matmul2d_descriptor::mode::multiply_accumulate);
```

✅ **VERIFIED** — `notes/repos/mlx-tensorops-kernels.md` §9, quoting
`mlx/backend/metal/kernels/steel/gemm/nax.h`. The twin file
`mlx/backend/metal/kernels/steel/attn/nax.h` is **byte-identical** (verified by `diff`), so the
attention path carries the same descriptor.

What does that sixth argument mean? Apple's header says so in its own words. From
`MPPTensorOpsMatMul2d.h:98-99` (shipped in the Xcode 26.6 SDK, Build 17F113), with Apple's own typo
preserved:

```
//   false); // relaxed_precision = false, set it to true to allow implementation
//           // to sacrifice accurancy for performance.
```

✅ **VERIFIED** — quoted from the SDK header at
`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/MetalPerformancePrimitives.framework/Headers/MPPTensorOpsMatMul2d.h`.

Note the default in Apple's declaration is **`false`** (argument 6 of 7, and the `matmul2d_descriptor`
constructor takes all seven positionally — there are no named parameters). MLX passes `true`
**unconditionally**. There is no `#if`, no template parameter, no runtime branch. Every operation
that reaches MLX's NAX GEMM or NAX attention kernel is computed with the implementation permitted to
sacrifice accuracy for performance.

That is half one. Taken alone it reads as "MLX always uses reduced precision on M5", which is not
quite true, because of half two.

### 3.2 Half two: the host gates `float32` on `MLX_ENABLE_TF32`

The host side compensates. `mlx/utils.h:195-197`, verbatim:

```cpp
inline bool enable_tf32() {
  static bool enable_tf32_ = get_var("MLX_ENABLE_TF32", 1);
  return enable_tf32_;
}
```

✅ **VERIFIED**. Three things to read out of those three lines:

1. **The default is `1`** — on.
2. **`static`** — the environment variable is read **once**, lazily, on the first call. §3.5 is about
   what that costs you.
3. It returns a plain `bool` with no way to observe it from Python.

And the gate it feeds, `mlx/backend/metal/matmul.cpp:916-918`:

```cpp
bool use_nax = metal::is_nax_available() &&
    !issubdtype(a.dtype(), complexfloating) &&
    (env::enable_tf32() || a.dtype() != float32);
```

✅ **VERIFIED**, with the identical pattern at `matmul.cpp:2858-2859` and at
`quantized.cpp:787-788`, `:982-983`, `:1327-1328` — e.g.:

```cpp
if (metal::is_nax_available() && transpose && (K % 64 == 0) &&
    (env::enable_tf32() || x.dtype() != float32)) {
```

Read the third clause as: **"use NAX unless the input is `float32` and the user has disabled TF32."**

So the two halves compose into this:

```
                        MLX_ENABLE_TF32=1 (default)     MLX_ENABLE_TF32=0
  float32, gen ≥ 17     NAX kernel, relaxed_precision   non-NAX kernel, IEEE fp32
  float32, gen < 17     non-NAX kernel, IEEE fp32       non-NAX kernel, IEEE fp32
  bf16/fp16, gen ≥ 17   NAX kernel                      NAX kernel  ← flag has NO effect
  complex64             never NAX                       never NAX
```

The bottom two rows are the ones people get wrong. **`MLX_ENABLE_TF32=0` does nothing for
`bfloat16` or `float16`** — the gate's third clause is satisfied by `dtype != float32` regardless of
the flag, so half-precision work keeps running through the `relaxed_precision = true` kernel. And on
pre-gen-17 hardware the flag is **completely inert**, because `is_nax_available()` short-circuits
the whole conjunction. A contributor reading the source put it exactly this way on mlx#3860:

> "on Metal every TF32 gate is `is_nax_available() && (env::enable_tf32() || dtype != float32)` — the
> steel and gather GEMM paths in `matmul.cpp`, `quantized.cpp`, and the SDPA gate — and
> `is_nax_available()` requires macOS ≥ 26.2 and `arch_gen >= 17` (18 on `'p'` parts). So the flag is
> inert before gen-17 on Metal. **On CUDA it isn't gated at all.**"

Community-attributed (issue thread, contributor `katlun-lgtm`, 2026-07, quoted in
`notes/repos/issues-mlx-stack.md` §3.1), consistent with the source quoted above.

**Scope summary to memorise: CUDA → always; Metal → gen-17 (M5 / A19 class) and up, on macOS ≥ 26.2.**

### 3.3 ⚠️ SILENT FAILURE: precision you did not choose, with no runtime signal

> ⚠️ **SILENT FAILURE — `float32` matmul at TF32-class precision.**
>
> **What happens.** On an M5-class Mac running macOS ≥ 26.2, `a @ b` with `a` and `b` of dtype
> `float32` computes at reduced internal precision by default. The result is a `float32` array of
> the right shape with plausible values. Relative error against a `float64` reference is roughly
> **three orders of magnitude worse** than a real `float32` matmul (§3.4).
>
> **What you see.** Nothing. No exception, no warning, no `stderr` line, no flag on the array, no
> field in `mx.device_info()`. `x.dtype` still says `float32`, because it *is* `float32` — the
> storage is fp32 and only the multiply-accumulate is relaxed.
>
> **How you find out.** A test that was green on your M3 goes red on an M5; or an
> `mx.allclose(..., rtol=1e-5)` assertion starts failing; or an `argmax` over near-ties flips; or a
> user files a bug you cannot reproduce.
>
> **Why it is like this.** The kernel-side `relaxed_precision = true` (§3.1) is unconditional, so the
> host-side flag is the *only* precision control, and upstream has now settled on keeping it that way.
> Docs PR **mlx#3894 merged 2026-08-04** (`docs/src/usage/precision.rst`) — but reduced to what "holds
> independently of backend and hardware generation", so it names no generation, no gate and no numbers;
> §3.2 and §3.4 remain your only source for scope and magnitude. On the strength of it **mlx#3860 was
> closed as completed** the same day, `zcbenz` declining a runtime opt-out — *"having a programmable
> switch would be nice … there is no necessarility"*. Warn-once **#3883** stays **closed unmerged**.
>
> **Safe default.** In any test suite, set `MLX_ENABLE_TF32=0` **before importing mlx**. That is
> exactly what MLX's own test harness does — `python/tests/mlx_tests.py` sets
> `os.environ["MLX_ENABLE_TF32"] = "0"` with the comment *"Use regular fp32 precision for tests"*
> (✅ VERIFIED). In production, leave it on if you want the speed, but write your numerical
> tolerances against measured gen-17 behaviour, not against IEEE fp32.

### 3.4 What it measures out at

All of the following are **community-measured**, from the mlx#3860 thread (**closed as completed
2026-08-04**, 9 comments), by `pierre427` and `mabaeyens`. Not Apple figures. Attribution is per row.

**Metal — plain `float32` 512×512×512 matmul, GPU versus CPU, expressed as the error exponent:**

| Device | Architecture string | Native (default) | `MLX_ENABLE_TF32=0` | Forced `MLX_METAL_GPU_ARCH=applegpu_g16s` |
|---|---|---|---|---|
| M5 base | `applegpu_g17g` | **2^-10.4** | 2^-19.8 | 2^-19.8 |
| M5 Max | `applegpu_g17s` | **2^-10.4** | 2^-20.9 | 2^-20.9 |
| M3 Max | `applegpu_g15s` | 2^-21.7 | 2^-21.7 (**bit-identical**, max&#124;Δ&#124; = 0) | — |

Read the M5 rows: the default is losing roughly **nine to ten bits** of mantissa relative to the
same machine with the flag off. The M3 row is the control — the flag is inert there, and the two
columns are bit-identical, which is exactly what §3.2's table predicts.

**CUDA — relative Frobenius error, 512×512 `float32` GEMM against a `float64` reference:**

| Backend | Relative error |
|---|---|
| NumPy `float32` | 2.9e-07 |
| MLX CPU stream | 4.1e-07 |
| MLX Metal, M-series pre-gen-17 | fp32-class |
| **MLX CUDA, default (`MLX_ENABLE_TF32=1`)** | **2.9e-04** |
| MLX CUDA + `MLX_ENABLE_TF32=0` | 2.1e-07 |
| MLX CUDA + `NVIDIA_TF32_OVERRIDE=0` | 2.1e-07 |

A ~1000× error increase, on by default, on both backends, with different gating rules on each. Note
the last row: NVIDIA's own override variable also works on the CUDA backend, which is a useful
independent confirmation that MLX is genuinely selecting `CUBLAS_COMPUTE_32F_FAST_TF32` and not
doing something of its own.

### 3.5 Three mechanics that cost people days

These are the parts that make bisection hard. All three are community-established on mlx#3860 and
consistent with the source quoted in §3.1–§3.2.

**(a) It is shape-dependent.** Matvec shapes (`M == 1` or `N == 1`) do not take the NAX route and
stay exact `float32`. So *the same dtype, the same operator, the same machine* gives different
precision depending on operand shape. The concrete symptom reported: `mlx-lm`'s `test_ssm` **passes**
on the gemv-shaped output comparison and **fails** on the outer-product state comparison, in the same
test.

**(b) It is first-use latched.** `enable_tf32()` uses a function-level `static`, so the environment
variable is read exactly once, on the first call.

```python
# WORKS — set before anything touches a matmul
import os
os.environ["MLX_ENABLE_TF32"] = "0"
import mlx.core as mx
# ...

# SILENTLY DOES NOTHING — the flag was already latched
import mlx.core as mx
_ = mx.random.normal((512, 512)) @ mx.random.normal((512, 512))
mx.eval(_)
os.environ["MLX_ENABLE_TF32"] = "0"   # too late; no error, no effect
```

This is a real diagnostic hazard, not a theoretical one. On mlx#3702 — a report of corrupted audio
on an A19 iPhone — MLX collaborator **zcbenz** wrote:

> "They should have the same output whether correct or corrupted, it is possible that
> `MLX_ENABLE_TF32=0` **is set too late**. But I think the neutral accelerator is not relevant here
> since with or without it the results are still corrupted. To know what is happening I think the
> only way is to isolate the op that is outputting wrong results on A19…"

If you are testing whether TF32 explains a discrepancy, set the variable in the *shell*, or as the
very first lines of the entry-point module, and prove it took effect by measuring §3.4-style error
rather than by trusting `os.environ`.

**(c) It is not limited to things that look like matmuls.** From the same thread:

> "On gen-17 it also moves attention paths that compose from ordinary GEMMs rather than a fused
> kernel. We hit this at **head_dim 96**, which fails `sdpa_full_supported_head_dim` (`{64, 80,
> 128}`) and so never enters the fused path, yet still responds to `MLX_ENABLE_TF32`."

That sentence is the hinge between §3 and §5: an attention layer whose head dimension is outside the
fused allow-list falls back to `matmul → softmax → matmul` (§5.3), and **those matmuls are then
subject to the TF32 gate**. So the two silent failures in this guide compose.

### 3.6 The blast radius, downstream

Community-measured consequences, each attributed:

- **Signal processing, CUDA sm_120** (mlx#3860): a fitting workload flipped near-tie `argmax` results
  on **1.4–2.5 % of spectra**, costing roughly **9 dB PSNR** — *"while every op-level parity test
  passed."* That last clause is the lesson: op-level tolerance tests did not catch a
  decision-boundary failure.
- **`mlx-lm/tests/test_generate.py`** (mlx#3860, mlx#3897): **8 of 28 tests fail on gen-17** —
  `test_batch_matches_single`, `test_batch_sliding_window`, `test_batch_continued_generation*`,
  `test_stream_generate_input_embeddings*` — all of them batch-versus-single equivalence assertions
  on models pinned to `set_dtype(mx.float32)`. All pass with the flag off.
- **`mlx-lm/tests/test_models.py::test_ssm`** fails out of the box on any M5 with mlx ≥ 0.32.
- **mlx-lm PR #1595** pins `MLX_ENABLE_TF32=0` in `tests/test_models.py` — but **not** in
  `test_generate.py`.
- **mlx-swift-lm #357 (closed as completed 2026-07-31; re-checked 2026-08-01)** — *"[BUG] tests
  fail due to TF32"*, the Swift-side manifestation of the same thing. The closing diagnosis is
  narrower than the original title: maintainers agreed that the failure is in the **test oracle**,
  not the cache or chunking implementation. Float16 execution plus different-shaped matmuls moves
  logits by roughly `2e-2`; the proposed repair is deterministic initialization and a direct
  max-absolute-difference check while retaining the exact cache-offset assertions. Closure does
  **not** retract the TF32 numerical warning above. (Previously miscited here as `mlx-swift` #357,
  which is an unrelated merged PR; the TF32 issue lives in `ml-explore/mlx-swift-lm`.)

And the methodological quote from mlx#3897 that deserves to be pinned above every benchmark you
write:

> "Your per-seed table shows the medians were hiding a 27-of-32 disagreement with a ten-seed tail up
> to 2^-13 … **The median was the wrong statistic** and I should not have leaned on it for a claim
> about a *mechanism*."

### 3.7 What to actually do

A short, opinionated policy:

1. **In tests: `MLX_ENABLE_TF32=0`, set before `import mlx`.** Copy MLX's own harness. If you cannot
   control import order (pytest plugins, notebooks), set it in `conftest.py` at module scope or in
   the shell, and assert it with a §4.5-style probe.
2. **In production: leave it on, and stop asserting bit equality.** A strict `rtol=1e-5`
   batch-equivalence assertion **cannot hold on gen-17, in any dtype** (community conclusion,
   mlx#3897). Decide what your product actually needs — usually "the argmax is stable and the
   loss curve matches within noise", not "the bits match."
3. **Never compare numbers across two different Macs and call the difference a regression** without
   first pinning `MLX_ENABLE_TF32` on both and re-measuring.
4. **If you need reference precision for one specific op**, put that op on the CPU stream. MLX's
   unified memory makes this cheap to try: `with mx.stream(mx.cpu): ...`. The CPU stream measured
   4.1e-07 relative error in §3.4's table — fp32-class, as expected.
5. **Log the environment.** A single line in your run banner — MLX version, architecture string,
   `MLX_ENABLE_TF32` as your process saw it — turns a week of bisection into a diff. §4.5's
   `mx.device_info()` probe supplies the version and architecture fields.

---

## 4. NAX, the M5 neural accelerator, and how to tell whether you are on the fast path

### 4.1 What the hardware is, per Apple

Everything in this subsection is **Apple-published**, from Tech Talk **111432**, *"Accelerate your
machine learning workloads with the M5 and A19 GPUs"*, presented by Zak, manager of Apple's GPU
Driver Performance team. ⚠️ It is a **Tech Talk, not a WWDC26 session** — it is the M5 launch talk,
predates WWDC26, and is not listed in `developer.apple.com/wwdc26/guides/machine-learning/`, which is
why searching WWDC26 for it fails. It is what WWDC26 session 330 means by *"the M5 machine learning
talk"*.

> *"Neural accelerators are **dedicated hardware in M5 purpose built for matrix multiplication**.
> **They're built into each shader core right alongside the other GPU pipelines** such as ALU,
> raytracing, and so on."*

Two consequences Apple draws from that placement, both of which are real architectural arguments and
both of which matter for how you write code:

1. *"**This physical locality enables fast, seamless interoperation with code running on other GPU
   pipelines.**"* — you can interleave matrix work and ALU work in one kernel with no handoff. This
   is the argument for doing matmul *inside* your shader instead of calling out to a framework.
2. *"**Neural accelerator capacity scales directly with core count.** So workloads that use them
   efficiently **will scale well as you move up the M5 family.**"*

Apple's own framework-stack picture, top to bottom, is worth reproducing because it tells you where
MLX sits:

| Tier | Contents (verbatim) |
|---|---|
| Domain frameworks | **MetalFX** — *"You get the benefit of neural accelerators automatically"* |
| Host-side frameworks | **Metal Performance Shaders, MPSGraph, Core ML** |
| Training / research | **MLX, llama.cpp, PyTorch** — *"already leverage neural accelerators under the hood"* |
| Lowest level | **Metal Performance Primitives and TensorOps** — *"direct access to neural accelerators from your metal shaders"* |

So: **using MLX at all puts you on the third tier, where neural accelerators are used on your
behalf.** §3 is the fine print on that sentence, and §7–§9 are about deliberately dropping to the
fourth.

### 4.2 The version story, stated carefully

This is a place where a single confident number would be wrong, so here is the whole thing.

**Apple's narrated feature ladder** for Metal TensorOps, verbatim from Tech Talk 111432:

> *"We introduced TensorOps at **[WWDC] 25** in the **combined metal for machine learning and
> graphics** session. … Since we introduced TensorOps, we've continued expanding the API **in iOS and
> Mac OS 26**. In **26.1**, we added **bfloat tensor support**… In **26.3**, we added support for
> **cooperative tensors as inputs to matmul**… And in **26.4**, we added **four bit and eight bit
> integer tensors**, so quantized models can fully leverage neural accelerators."*

| Version | Feature added |
|---|---|
| **26.0** (WWDC25 session 262) | TensorOps introduced |
| **26.1** | `bfloat` tensor support |
| **26.2** | *(never mentioned in the talk)* |
| **26.3** | cooperative tensors as **inputs** to matmul → custom in-kernel dequantisation |
| **26.4** | 4-bit and 8-bit **integer** tensors |

**The shipped SDK header**, meanwhile, says 26.2. ✅ VERIFIED, `MPPTensorOpsAvailability.h:10`:

```cpp
#define __TENSOR_OPS_SUPPORT_DEPLOYMENT_TARGET_26_2 ((__ENVIRONMENT_OS_VERSION_MIN_REQUIRED__) >= 260200)
```

**And MLX gates on 26.2 in two independent places** — its CMake build gate and its runtime
`__builtin_available` check (§4.3), both ✅ VERIFIED.

How to hold all three at once:

- ✅ **"Not 27" is settled decisively.** Every capability described in the M5 talk lands in a **26**
  point release. Nothing about TensorOps or neural accelerators is gated on iOS 27 / macOS 27.
  Anything you read that says otherwise is wrong.
- ⚠️ **Do not write a blanket "26.2".** Apple's narrated ladder skips 26.2 entirely. The most
  defensible sentence is: *TensorOps ships across the macOS/iOS 26 point releases — base at 26.0,
  bfloat at 26.1, cooperative-tensor matmul inputs at 26.3, int4/int8 tensors at 26.4 — and the
  shipped Xcode 26.6 SDK annotates the relevant symbols with a 26.2 deployment-target macro.* Both
  facts are true; they are about different things (a feature ladder versus a symbol availability
  macro).
- ✅ **For MLX specifically, 26.2 is the number that matters**, because 26.2 is what MLX's own build
  and runtime gates test. That is the practical floor for the NAX path.

One more Apple claim worth carrying, because it removes an objection people raise:

> *"**The API is portable. The same code runs across Apple's entire GPU family from M1 to M5. On
> older GPUs without neural accelerators, TensorOps falls back to optimized shader
> implementations.**"*

TensorOps is not M5-only; it is a portable API with a hardware fast path. MLX, however, does **not**
rely on that fallback — it ships a complete non-NAX twin of every NAX kernel and selects between
them on the host (§4.7).

### 4.3 Three gates, all of which must pass

MLX gates the NAX path in three independent places.

**Gate 1 — Apple's compile-time availability macro.** Both public MPP headers are hard-gated on two
compiler feature macros, `MPPTensorOpsMatMul2d.h:328`:

```cpp
#if defined(__METAL_VERSION__) && defined(__HAVE_TENSOR__)
```

✅ VERIFIED. If `__HAVE_TENSOR__` is undefined the **entire header expands to nothing** — no error,
just an empty namespace and a confusing "no member named `matmul2d`" much later. Related macros seen
in the headers: `__HAVE_BFLOAT__`, `__HAVE_INT4B_FORMAT_TYPE__`, `__HAVE_EXECUTION_UNIT__`.

**Gate 2 — MLX's CMake gate**, `mlx/backend/metal/kernels/CMakeLists.txt:158-182`, ✅ VERIFIED
verbatim:

```cmake
if(MLX_METAL_VERSION GREATER_EQUAL 400
   AND MACOS_SDK_VERSION VERSION_GREATER_EQUAL 26.2
   AND CMAKE_OSX_DEPLOYMENT_TARGET VERSION_GREATER_EQUAL 26.2)

  build_kernel(steel/gemm/kernels/steel_gemm_fused_nax     ${STEEL_NAX_HEADERS})
  build_kernel(steel/gemm/kernels/steel_gemm_gather_nax    ${STEEL_NAX_HEADERS})
  build_kernel(steel/gemm/kernels/steel_gemm_splitk_nax    ${STEEL_NAX_HEADERS})
  build_kernel(steel/gemm/kernels/steel_gemm_segmented_nax ${STEEL_NAX_HEADERS})
  build_kernel(quantized_nax quantized_nax.h ${STEEL_NAX_HEADERS})
  build_kernel(fp_quantized_nax fp4.h fp8.h fp_quantized_nax.h ${STEEL_NAX_HEADERS})
  build_kernel(steel/attn/kernels/steel_attention_nax ${STEEL_NAX_ATTN_HEADERS})

else()
  message(WARNING "NAX kernels require Metal 4, macOS SDK >= 26.2, and "
                  "MACOSX_DEPLOYMENT_TARGET >= 26.2 (...). Building without NAX kernels.")
  target_compile_definitions(mlx PRIVATE MLX_METAL_NO_NAX)
endif()
```

That list is also the complete inventory of what NAX covers: **fused GEMM, gather GEMM, split-K GEMM,
segmented GEMM, affine-quantized matmul, floating-point-quantized matmul, and attention.**

> ⚠️ **SILENT FAILURE — building MLX from source silently loses every NAX kernel.** The
> deployment-target condition is the practical trap: a default macOS build often targets something
> older than 26.2, the `else()` branch fires, `MLX_METAL_NO_NAX` is defined, and you get a
> *CMake warning* and a fully working MLX that is simply never fast on M5. Nothing at runtime tells
> you. This has cost enough people enough time that there are two merged upstream PRs about it —
> **#3622** *"NAX requires setting `MACOSX_DEPLOYMENT_TARGET=26.2`"* and **#3824** *"Warn at
> configure time when NAX kernels are disabled"*.
> **Safe default:** if you build MLX yourself and care about M5 performance, set
> `CMAKE_OSX_DEPLOYMENT_TARGET=26.2` explicitly and **read the configure output**. If you install
> from PyPI wheels this does not apply to you.

**Gate 3 — MLX's runtime check**, `mlx/backend/metal/device.cpp:944-963`, ✅ VERIFIED verbatim:

```cpp
bool is_nax_available() {
#ifdef MLX_METAL_NO_NAX
  return false;
#else
  auto _check_nax = []() {
    bool can_use_nax = false;
    if (__builtin_available(macOS 26.2, iOS 26.2, tvOS 26.2, visionOS 26.2, *)) {
      can_use_nax = true;
    }
    auto& d = metal::device(mlx::core::Device::gpu);
    auto arch = d.get_architecture().back();
    auto gen  = d.get_architecture_gen();
    can_use_nax &= gen >= (arch == 'p' ? 18 : 17);
    return can_use_nax;
  };
  static bool is_nax_available_ = _check_nax();
  return is_nax_available_;
#endif
}
```

Two runtime conditions: **OS ≥ 26.2**, and **GPU architecture generation ≥ 17** — or ≥ 18 if the
architecture-string suffix is `'p'`. Note the `static` again: like `enable_tf32()`, this is computed
once per process.

### 4.4 There is no capability query — here is the heuristic MLX uses

This is the part readers hunt for and do not find, so it is worth stating plainly:

> **The M5 neural accelerator has no API.** There is no `MTLDevice.supportsFamily(...)` value for it,
> no feature flag, no `mx.*` predicate. MLX infers its presence **from the GPU architecture
> generation number alone**, exactly as in the code above.
> ✅ VERIFIED — `notes/repos/mlx-tensorops-kernels.md` §11.3 and §12 row 32; corroborated by the
> absence of any such symbol in the MPP headers.

The architecture string is a name like `applegpu_g17s`. MLX parses it as: **two digits = generation,
final character = device class.** MLX's own class table, `mlx/backend/metal/device.cpp:592-627`:

| Suffix | MLX's internal class | `max_ops_per_buffer` | `max_mb_per_buffer` |
|---|---|---:|---:|
| `p` | phone | 20 | 40 |
| `g` | base / pro | 40 | 40 |
| `s` | max | 50 | 50 |
| `d` | ultra | 50 | 50 |
| other | default (medium) | 40 | 40 |

✅ VERIFIED as MLX's internal buffer-sizing table. **But be careful with the marketing-name column.**
A community thread on mlx#3885 catalogued observed values and reached a different mapping:

| Architecture string | Device (community-observed) |
|---|---|
| `applegpu_g13s` | M1 Max |
| `applegpu_g15s` | M3 Max |
| `applegpu_g16s` | M4 Max **and** M4 Pro |
| `applegpu_g16g` | M4 iPad Pro |
| `applegpu_g17g` | **M5 base** |
| `applegpu_g17s` | **M5 Max** |

with the explicit conclusion that the suffix **cannot distinguish Pro from Max** (`g16s` covers both
M4 Pro and M4 Max), and that `'g'` covers base chips *and* iPads/iPhones.

> ⚠️ **The two tables disagree** about what `'g'` and `'s'` mean in marketing terms. MLX's source
> comment says `g` = "base / pro" and `s` = "max"; the community observation says `g16s` is both M4
> Pro and M4 Max. **Both cannot be right.** The MLX table is ✅ VERIFIED as *what MLX uses for
> buffer sizing*; the marketing mapping is 🟡 community-observed. **Do not use the suffix to
> identify a product.** Use it for exactly what MLX uses it for: the `'p'` test in
> `is_nax_available()`, and nothing else.

For **A19 / phone-class** parts, note the `+1`: NAX requires **gen ≥ 18** when the suffix is `'p'`.
MLX PR **#3083** is titled as enabling the NAX matmul path for `gen >= 18` phone architectures
(referenced from mlx#3702's thread; **UNVERIFIED** beyond that reference).

### 4.5 A probe you can run, and an A/B switch

Python does not expose `is_nax_available()` or `get_architecture_gen()`. What it *does* expose is
the architecture string, via `mx.device_info()`:

```python
import mlx.core as mx

info = mx.device_info()
print(info)                      # dict; keys include 'device_name', 'architecture', ...
print(info["architecture"])      # e.g. 'applegpu_g17s'
```

✅ **VERIFIED** that `mx.device_info(d=None)` exists and that its documented keys include
`device_name` (str), `architecture` (str) and `total_memory` / `memory_size` (size_t) — from the
comment on `mlx/device.h` and the binding in `python/src/device.cpp`. On Metal it additionally
exposes `max_recommended_working_set_size`, and `mx.device_info()["resource_limit"]` is used
elsewhere in the community to read MLX's live-buffer cap.

> ⚠️ Do **not** use `mx.metal.device_info()`. The whole `mx.metal.*` memory/device family is
> **deprecated** and prints a deprecation notice to stderr on first call
> (✅ VERIFIED, `python/src/metal.cpp:20-26`); it forwards to the top-level `mx.*` equivalents.
> `mx.metal.is_available`, `start_capture` and `stop_capture` are the survivors.

Reimplementing MLX's gate in Python:

```python
import mlx.core as mx

def nax_likely_available() -> bool:
    """Mirror of MLX's C++ is_nax_available() gate, minus the OS check.

    RECONSTRUCTED: MLX does not expose is_nax_available() to Python. This
    reproduces the architecture-generation half of the C++ logic at
    mlx/backend/metal/device.cpp:944-963. It CANNOT see the __builtin_available
    OS >= 26.2 check, nor whether MLX was built with MLX_METAL_NO_NAX.
    Treat a True as "the hardware qualifies", not as "NAX is running".
    """
    if not mx.metal.is_available():
        return False
    arch = mx.device_info()["architecture"]        # e.g. 'applegpu_g17s'
    suffix = arch[-1]
    digits = "".join(ch for ch in arch if ch.isdigit())
    if len(digits) < 2:
        return False
    gen = int(digits[-2:])
    return gen >= (18 if suffix == "p" else 17)
```

🟡 **RECONSTRUCTED.** The gate logic and the `'p'`/18 special case are ✅ VERIFIED from
`device.cpp:944-963`. The *string parsing* — taking the last two digits of the architecture name as
the generation — is inferred from MLX's own description of `arch_gen_` being "parsed from the two
digits before the [class] suffix" (`device.cpp:592-627`). It has not been executed against a real
`applegpu_*` string in this session. **Safe default:** print the raw string as well as the verdict,
and never branch on this in shipping code — branch on measured behaviour instead.

**The A/B switch.** `MLX_METAL_GPU_ARCH` overrides the architecture string MLX reports
(✅ VERIFIED, `notes/repos/mlx-core.md` §19 environment table). Community researchers used exactly
this to isolate NAX effects, forcing an M5 to present as `applegpu_g16s` — a generation-16 string —
which fails the `gen >= 17` test and takes the whole non-NAX path:

```bash
# Force the non-NAX path on an M5 without touching your code
MLX_METAL_GPU_ARCH=applegpu_g16s python my_script.py

# Compare with the fp32-precision lever, which only moves float32
MLX_ENABLE_TF32=0 python my_script.py
```

This pair is the single most useful diagnostic in this guide. Their **difference** is diagnostic:

- If `MLX_ENABLE_TF32=0` fixes it → it is the fp32 TF32 path (§3).
- If only `MLX_METAL_GPU_ARCH=applegpu_g16s` fixes it → it is a NAX kernel behaviour affecting
  `bfloat16`/`float16`, which the TF32 flag cannot reach (§3.2's bottom rows). This is exactly how
  mlx#3897 separated its two mechanisms.
- If **neither** fixes it → it is not NAX. On mlx#3702, neither did, and even forcing
  `can_use_nax = false` in the backend left the output corrupted — which is what redirected that
  investigation toward a shape-dependent GEMM dispatch bug instead.

### 4.6 Apple's own numbers, with their baselines

**Apple-published**, Tech Talk 111432. ⚠️ The baselines differ per claim, and a number without its
baseline is meaningless — carry them.

| Claim | Baseline | Verbatim |
|---|---|---|
| Image generation ~**4×** | vs **M4** | *"on the new iPad Pro with M5, AI image generation, apps like Draw Things can produce images up to four times faster over M4"* |
| Video enhancement **7.7×** | vs **M1** | *"on the new 14 inch MacBook Pro with M5, AI video enhancement and Topaz video is up to 7.7 times faster than on M1"* |
| Time to first token up to **4×** | context is M4→M5 | *"Time to first token is up to four times faster and token generation is up to 25% faster"* |
| Matmul **4–8×** | unstated | *"Matrix multiplication operations, often called gems, are up to 4 to 8 times faster, depending on precision"* |

The attribution of *where* the gain comes from is the genuinely useful part:

> *"the time to first token performance in the **prefill** phase is up to four times faster, **thanks
> to the neural accelerators**, and in the **decode** phase, **the increased memory bandwidth and
> larger GPU caches** in M5 speed up token generation by up to 25%."*

That maps onto the compute-bound / bandwidth-bound split Apple sets up earlier in the talk: prefill
is large-matrix, compute-bound, and scales with math rates; decode is tall-skinny, bandwidth-bound,
and scales with how fast you move data. **The neural accelerator helps prefill. It does not help
decode.** If your workload is decode-dominated, gen-17 buys you the memory subsystem, not the matrix
hardware — and §5's attention discussion becomes the thing that matters.

**The headline benchmark**, and the most citable number in the talk. Workload: **one 4K × 4K matrix
multiplication**, three implementations, same hardware:

| Variant | Implementation | Wall time (Metal System Trace) | Neural-accelerator utilisation |
|---|---|---|---|
| **v1** | classic **SIMD-group matrix** API | *"over **two seconds**"* | **0 %** |
| **v2** | **TensorOps** | *"over just a **half second**"* | *"well above 50 %"* |
| **v3** | TensorOps + **Morton-ordered** threadgroup dispatch | *"around **a third of a second**"* | *"close to 100 %"* |

> *"It's the **same 4K by 4K matrix multiplication running on the exact same hardware**. The
> difference is **almost seven times faster execution** just by understanding how to use and feed
> neural accelerators efficiently."*

⚠️ **The 0 % figure is the headline.** Apple's gloss: *"All of this compute work is happening on the
ALU, which means **the dedicated matrix hardware is sitting completely idle**."* That converts
"you should migrate off `simdgroup_matrix`" from advice into arithmetic — and it pairs with Apple's
direct instruction in the same talk: *"**if you're already writing your own custom kernels in metal
using SIMD Group matrix API, you should move your workloads over to adopt TensorOps instead.**"*

Note also the diagnosis of v2, which is why v3 exists: *"the utilization percentage tells us that the
neural accelerators could be doing more. **They're waiting for data.**"* v2 was **data-starved**, not
compute-limited. Traversal order fixed the *feeding*, not the math. If you take one design lesson
from this section into §10, it is that one.

⚠️ Every figure in this subsection is **Apple-published, hardware and OS unstated beyond "M5"**, from
a launch talk. No independent reproduction of the three-variant benchmark exists in our corpus.

### 4.7 NAX changes the algorithm, not just the kernel

A structural point that surprises people: **NAX is not a drop-in accelerator.** MLX ships a complete
non-NAX twin of every NAX kernel and picks between them on the host —
`steel_matmul_regular_axpby_nax` versus `steel_matmul_regular_axpby`, `steel_gemm_splitk_axpby_nax`,
`gather_mm_rhs_nax`, `qmm_nax`, `gather_qmm_nax`, `gather_qmm_rhs_nax`, and a segmented path that
merely appends `"nax_"` to the kernel name (✅ VERIFIED, `matmul.cpp:984-985`, `:2883`).

But look at this inversion, `matmul.cpp:924`:

```cpp
if (!use_nax && batch_size_out == 1 && (_tm * _tn) <= min_tmn_threshold &&
```

✅ VERIFIED. The **old split-K path is taken only when NAX is absent**; NAX has its own split-K at
`matmul.cpp:947`. So enabling NAX does not merely swap the inner loop — **it changes which algorithm
is selected.** Two consequences:

1. Numerical differences between a gen-16 and a gen-17 machine are not only "relaxed precision"; they
   can also be "a different reduction order in a different split-K decomposition". Do not assume
   `MLX_ENABLE_TF32=0` restores gen-16 behaviour exactly. (In §3.4's Metal table it did restore the
   *error magnitude*, but that is not the same as bit equality across machines.)
2. The non-NAX kernels use `simdgroup_matrix` (`<metal_simdgroup_matrix>`) — which is precisely the
   API Apple's 4K×4K benchmark measured at **0 % neural-accelerator utilisation**. On a gen-17
   machine with NAX disabled you are running the v1-class path.

The threshold in that line is itself architecture-dependent, `matmul.cpp:919-920`:

```cpp
char devc = d.get_architecture().back();
int min_tmn_threshold = (devc == 's' || devc == 'd') ? 2048 : 1024;
```

✅ VERIFIED. Another reminder that MLX's dispatch reads the architecture string in several places for
several unrelated reasons.

---

## 5. ⚠️ The silent SDPA fallback

If §3 is the numerics footgun, this is the performance footgun — and it is the canonical MLX one. A
single call, `mx.fast.scaled_dot_product_attention`, either runs a hand-written fused kernel or
silently decomposes into three ordinary ops that allocate an enormous transient. Same API, same
result, order-of-magnitude different memory and time.

### 5.1 The API, and the four notes that matter

✅ **VERIFIED** — signature from `python/src/fast.cpp`, prose from `docs/src/python/fast.rst`:

```python
def scaled_dot_product_attention(
    q: array, k: array, v: array, *,
    scale: float,
    mask: Union[None, str, array] = None,
    sinks: Optional[array] = None,
    stream=None,
) -> array
```

with the C++ form (`mlx/fast.h`) carrying the mask as two separate parameters:

```cpp
array scaled_dot_product_attention(
    const array& queries, const array& keys, const array& values,
    const float scale,
    const std::string& mask_mode = "",
    std::optional<array> mask_arr = {},
    const std::optional<array>& sinks = {},
    StreamOrDevice s = {});
```

Shapes: `q` is `[B, N_q, T_q, D]`, `k` and `v` are `[B, N_kv, T_kv, D]`.

Four documented notes, each of which is a mistake people make:

1. **The softmax is always `float32`.** Verbatim: *"The softmax operation is performed in `float32`
   regardless of the input precision."* You do not need to upcast for numerical safety, and doing so
   costs you (§5.2: the dtype is not itself a gate, but the extra copy is real).
2. **Do not pre-tile `k` and `v` for GQA/MQA.** Verbatim: *"For Grouped Query Attention and
   Multi-Query Attention, the `k` and `v` inputs should not be pre-tiled to match `q`."* If you
   `mx.repeat` your KV heads up to `N_q` before calling — as most hand-rolled attention
   implementations do — you have quadrupled your KV bandwidth *and* changed the shape enough to
   affect kernel selection. `n_heads` must be a multiple of `n_kv_heads`.
3. **`mask` accepts exactly one string: `"causal"`.** Anything else raises
   `"[scaled_dot_product_attention] invalid mask option '<x>'. Must be 'causal', or an array."`
   ✅ VERIFIED. Array masks may be boolean or additive, at most 4 dimensions, broadcast-compatible
   with `[B, N, T_q, T_kv]`; an additive mask's dtype must promote to `result_type(q, k, v)`.
4. **`"causal"` uses lower-right alignment** — *"the last query aligns with the last key."* If you
   are used to upper-left alignment this silently changes which positions are masked when
   `T_q != T_kv`, which is every decode step with a KV cache.

`sinks` is an optional attention-sink array (shape-validated). ⚠️ Community-reported interaction:
**gpt-oss with a quantized KV cache produces a silent client timeout** because attention sinks are
unsupported on that path (`notes/repos/issues-mlx-stack.md` §12 item 20; mlx-lm, community-reported).

### 5.2 The complete fallback table

✅ **VERIFIED** — `ScaledDotProductAttention::use_fallback` in
`mlx/backend/metal/scaled_dot_product_attention.cpp:593-644`, read on disk. Independently
corroborated by mlx#3885, which quotes the routing at L621–633 of commit `0c537a41`, and which notes
that the same head-dimension sets appear as far back as v0.29.3 (L395–400).

**MLX takes the unfused path when ANY of these is true:**

| Condition | Meaning |
|---|---|
| `is_training` | you are inside gradient tracing |
| `output_logsumexp` | logsumexp output was requested |
| `s.device == Device::cpu` | you are on the CPU stream |
| head dims unsupported | see the two tables below |

**Vector kernel — the decode path, `T_q <= 8`:**

| Requirement | Value |
|---|---|
| `D_q == D_v` and in | **{64, 96, 128, 256}** |
| …or the asymmetric combo | **`(D_q=192, D_v=128)`** |
| also | `T_q <= T_kv` |
| also | `T_q * gqa_factor <= 32` |

**Full kernel — the prefill path, `T_q > 8`:**

| Requirement | Value |
|---|---|
| `D_q == D_v` and in | **{64, 80, 128}** |
| mask | absent, an array, or `"causal"` with `T_q <= T_kv` |

Read those two allow-lists side by side and note what is *not* in them.

- **No 512** in either. Gemma 4's global layers are `head_dim = 512` — *"at prefill no layer of this
  model fuses at all"* (mlx#3885).
- **No 192 or 256 in the full/prefill kernel** — so a `d = 256` model fuses at decode and falls back
  at prefill. Tracked in mlx#3658 and PRs #3293 / #3660.
- **No 96 in the full kernel**, though 96 *is* in the vector kernel. Same model, fused at decode,
  unfused at prefill.
- **No 72**, which is Qwen3-VL's vision tower (1152 / 16 heads).
- **No 80 in the vector kernel**, though 80 *is* in the full kernel. The two lists are not nested.

> ⚠️ **The `is_training` row is the one that surprises MLX users most.** The comment in MLX's source
> is explicit: *"It's faster for training on Metal to use the unfused SDPA for both forward and
> backward."* ✅ VERIFIED. **So the fused SDPA kernel is inference-only on Metal.** Every
> attention benchmark you have seen quoted for MLX training is measuring the unfused path, by design.
> If you are profiling a fine-tune and wondering why attention looks slow relative to inference
> numbers, this is why, and it is not a bug.

### 5.3 What the fallback actually does

It composes `matmul → softmax → matmul` from ordinary ops — and, critically, **materialises the full
score tensor**:

```
transient scores ≈ [B, n_kv, n_rep, qL, kL]
```

which for `float32` accumulation is approximately

```
n_q_heads × chunk_len × kv_len × 4 bytes
```

per full-attention layer, per prefill chunk (community-derived, mlx#3658). That is the entire cost
model, and it explains every number in §5.4. The fused kernel never forms this tensor; the unfused
path forms all of it, at once, in GPU memory.

Two consequences that look like completely unrelated bugs:

- **Out-of-memory during long-context prefill.** At `kv_len = 130K`, *"even a 32-token chunk
  allocates ~665 MB for scores alone"* (mlx#3658). A memory guard that responds by shrinking the
  chunk size makes it worse per token, not better.
- **A "long-context decode collapse"** that is really an allocator problem — see §5.7.

And the honest statement from the issue thread about visibility:

> "today the only ways to notice the composite path are a **Metal System Trace** or **reading
> `use_fallback`**."

An `MLX_FAST_LOG_FALLBACK=1` environment variable and a queryable
`mx.fast.sdpa_is_fused(q_shape, k_shape, ...)` predicate were both **requested and have not landed**
(mlx#3885). Until one does, §5.5 is what you have.

> ⚠️ **SILENT FAILURE — fused attention silently becomes unfused.**
>
> **What happens.** `mx.fast.scaled_dot_product_attention` returns the mathematically correct answer
> via `matmul → softmax → matmul`, materialising a `[B, n_kv, n_rep, qL, kL]` score tensor.
>
> **What you see.** Nothing. No warning, no exception, no attribute on the output. The only symptoms
> are **throughput and peak memory**.
>
> **How you find out.** Your model is unexpectedly slow at prefill; or peak memory scales with
> `qL × kL` instead of with the KV cache; or you OOM at a context length that arithmetic said should
> fit; or the model runs fine at `head_dim=128` and badly at `head_dim=96`.
>
> **Safe default.** Assert your head dimension against the allow-lists in §5.2 **at model-load time**
> and either pad (§5.6) or log loudly. Do not wait for a profiler.

### 5.4 What it costs, measured

All **community-measured**, from the issue threads, with hardware stated per block. None of these are
Apple figures.

**Decode, `head_dim = 512` versus a fused shape.** M4 Max 128 GB, `bfloat16`, `qL = 1`, additive
mask (mlx#3885):

| Shape | seqK = 1024 | seqK = 4096 |
|---|---:|---:|
| `d=512`, 32 q / 4 kv (**fallback**) | 168 µs | 260 µs |
| `d=256`, 32 q / 8 kv (same KV bytes, **vector kernel**) | 146 µs | 184 µs |

At decode, the penalty is modest — 15 % at 1K, 41 % at 4K. **Prefill is where it becomes structural.**
Same issue: at `L = 4096`, a single `d = 512` global layer runs **84 ms and materialises ~1 GB of
transient scores.**

**Prefill peak memory, fused versus unfused.** M4 Max 36 GB, `n_q = 16 / n_kv = 8` GQA, `d = 256`,
`float16`, measured on a rebased PR #3293 branch (mlx#3658). "Peak" includes inputs:

| qL | kL | inputs | fused peak | unfused peak | max abs err |
|---:|---:|---:|---:|---:|---:|
| 1024 | 32768 | 264 M | **272 M** | 1,824 M | 0.0 |
| 2048 | 65536 | 528 M | **544 M** | 5,696 M | 0.0 |
| 2048 | 131072 | 1,040 M | **1,056 M** | 11,328 M | 0.0 |

Note the `max abs err` column: **0.0**. The fallback is not less accurate. It is a 10× memory
multiplier that returns identical numbers, which is precisely why nobody notices it.

**And an honesty note that the thread itself makes**, which you should carry when you argue for
fusing: above the `kL > 16384` routing threshold the **fused kernel measured 0.74–0.79× of unfused on
M4 Max** — i.e. *slower* when the transient happens to fit. **The value of fusing here is memory, not
speed.** Do not promise both.

**Real-world scenario table.** Mac Studio 36 GB, Gemma 4 26B-A4B 3-bit (`head_dim = 256`, 30 layers,
only 5 full-attention) — mlx#3658:

| Scenario | Result |
|---|---|
| Cold prefill ~130K tokens, 1024-token chunks | 226 s — completes, transient-bound |
| Default 2048-token chunks at long context | Metal OOM abort (`kIOGPUCommandBufferCallbackErrorOutOfMemory`) |
| Multi-turn past ~133K with a memory ceiling active | guard shrinks chunks to 32–512 tokens → **a single turn's prefill takes 26+ minutes** |

⚠️ **A correction from that same thread, worth repeating because the wrong version circulates:** be
very careful attributing Gemma 4's attention behaviour to `head_dim = 256`. The original poster
issued a correction that **Gemma 4's large-context global layers are `head_dim = 512, n_kv = 2`**, so
the `d=256` work does not activate for them. And a clean `python -m mlx_lm.benchmark` A/B showed **no
change** for Gemma 4 26B 8-bit at 32K/64K (prompt tok/s 896.2 → 892.6; peak 31.078 GB both). MLX
maintainer **zcbenz** asked for exactly that clean A/B:

> *"Would it be possible to measure with the mlx-lm instead of oMLX? We are not familiar with oMLX's
> code so it is hard for us to check if this is something that we could fix without sacrificing the
> performance."*

That is the right standard for any performance claim you bring to MLX: reproduce it in `mlx-lm` or
in plain `mlx`, not in a downstream runtime.

### 5.5 Detecting the fallback — four techniques

There is no API. Here are four things that work today, cheapest first.

**Technique 1 — a static shape assertion.** Encode §5.2's tables and check at model construction.
This costs nothing and catches the common case:

```python
import mlx.core as mx

SDPA_VECTOR_HEAD_DIMS = {64, 96, 128, 256}          # T_q <= 8   (decode)
SDPA_FULL_HEAD_DIMS   = {64, 80, 128}               # T_q >  8   (prefill)
SDPA_VECTOR_ASYMMETRIC = {(192, 128)}               # (D_q, D_v)

def sdpa_fusion_report(d_q: int, d_v: int, n_q: int, n_kv: int) -> dict:
    """Static check of MLX 0.32.x's Metal SDPA head-dim gates.

    VERIFIED against mlx/backend/metal/scaled_dot_product_attention.cpp:593-644.
    Does NOT model: is_training, output_logsumexp, CPU stream, mask-shape gates,
    or the T_q*gqa_factor <= 32 vector-kernel limit (which is call-site dependent).
    """
    gqa = n_q // n_kv if n_kv else 0
    vector_ok = (d_q == d_v and d_q in SDPA_VECTOR_HEAD_DIMS) or (d_q, d_v) in SDPA_VECTOR_ASYMMETRIC
    full_ok = (d_q == d_v and d_q in SDPA_FULL_HEAD_DIMS)
    return {
        "head_dims": (d_q, d_v),
        "gqa_factor": gqa,
        "decode_fused_possible": vector_ok,
        "prefill_fused": full_ok,
        "note": "decode also requires T_q <= T_kv and T_q * gqa_factor <= 32",
    }

# Qwen3-VL vision tower: 1152 / 16 heads
print(sdpa_fusion_report(72, 72, 16, 16))
# {'head_dims': (72, 72), ..., 'decode_fused_possible': False, 'prefill_fused': False, ...}
```

🟡 **RECONSTRUCTED** as a helper; the *sets* it encodes are ✅ VERIFIED. It deliberately does not try
to model `is_training` or mask shapes, because those depend on the call site and a helper that
pretends to know them would be worse than one that says it does not.

**Technique 2 — the peak-memory differential.** The fallback materialises the score tensor, so it
shows up in memory accounting. Reset the peak, run one attention call, read the peak, and compare
against the analytic score-tensor size:

```python
import mlx.core as mx

def probe_sdpa_transient(B, n_q, n_kv, T_q, T_kv, D, dtype=mx.bfloat16):
    q = mx.random.normal((B, n_q,  T_q,  D)).astype(dtype)
    k = mx.random.normal((B, n_kv, T_kv, D)).astype(dtype)
    v = mx.random.normal((B, n_kv, T_kv, D)).astype(dtype)
    scale = D ** -0.5

    mx.eval(q, k, v)
    mx.clear_cache()
    mx.reset_peak_memory()
    base = mx.get_active_memory()

    out = mx.fast.scaled_dot_product_attention(q, k, v, scale=scale, mask="causal")
    mx.eval(out)

    peak_delta = mx.get_peak_memory() - base
    scores_bytes = B * n_q * T_q * T_kv * 4          # fp32 scores, the fallback's tell
    return {
        "peak_delta_MB": peak_delta / 1e6,
        "predicted_scores_MB": scores_bytes / 1e6,
        "verdict": "LIKELY UNFUSED" if peak_delta > 0.5 * scores_bytes else "likely fused",
    }
```

✅ The memory APIs are VERIFIED (`mx.get_peak_memory`, `mx.reset_peak_memory`,
`mx.get_active_memory`, `mx.clear_cache`, `mx.get_cache_memory` — `mlx/memory.h` /
`python/src/memory.cpp`). 🟡 The *heuristic* is reconstructed.

> ⚠️ **Two caveats on the memory probe, both community-established (mlx#3896).**
> First, **`mx.get_peak_memory()` is a high-water mark of *active* memory only and excludes the
> buffer pool.** One reporter (M5 Max 128 GB, mlx 0.32.0, Darwin 25.4.0) saw `get_peak_memory()`
> report **~46 GB** while the OS reported **~110 GB**. For absolute footprint, use
> **`mx.get_active_memory() + mx.get_cache_memory()`** — that sum matched the OS footprint to 0.2 %
> in their churn test, and it is what MLX's *own* limit enforcement uses.
> Second, `mx.clear_cache()` genuinely returns memory, but `phys_footprint` **trails the call by a
> few seconds** — do not sample immediately and conclude there is a leak.
> Closure context (mlx#3896 closed 2026-08-08; checked 2026-08-23): the maintainer confirmed the
> scoping when closing — `get_peak_memory()` is meant for measuring a single model's
> inference/training run with near-100% cache hits, and `active + cache` is his own recommendation
> for the real footprint. A short single-workload probe like this one sits inside that intended
> scope; a long-lived or multi-model process does not.

**Technique 3 — the A/B against a known-fused shape.** Pad your head dim up to the nearest allowed
value (§5.6) and measure. If padding *up* — strictly more arithmetic — makes it **faster**, you were
on the fallback. This is the technique that requires no tooling and produces an unarguable result.

**Technique 4 — Metal System Trace or a GPU capture.** The authoritative answer, and the one the
issue thread names. Apple's recipe from Tech Talk 111432: build (⌘B) → Instruments (⌘I) → **Metal
System Trace** template → select the **performance limiters** counter set → record; then expand the
**M5 Metal Device events** track and use the track filter to pin the **neural accelerator
utilization** counter. For MLX specifically:

```bash
CMAKE_ARGS="-DMLX_METAL_DEBUG=ON" pip install -e .
MTL_CAPTURE_ENABLED=1 python my_script.py
```

```python
mx.metal.start_capture("mlx_trace.gputrace")   # path must NOT already exist
for _ in range(10):
    mx.eval(my_attention_step())
mx.metal.stop_capture()
```

✅ VERIFIED, `docs/src/dev/metal_debugger.rst`. In the capture, the fused path is one kernel with
`sdpa` in its name; the fallback is a recognisable `matmul`/`softmax`/`matmul` triple with a large
intermediate. Apple's practical tip from 111432 is worth copying: capture **a single K-loop
iteration**, which *"keeps the capture small while preserving the performance characteristics we care
about."*

### 5.6 Fixing it: pad the head dimension

The community fix is **zero-padding the head dimension up to the nearest supported value**, and it is
exact:

> *"the same trick as `gemma4EnsureFusedSDPA` in this repo (and mlx-vlm's `ensure_fused_sdpa`).
> **Padding is exact: the padded dims contribute nothing to the dot products and `scale` is passed
> explicitly.**"*

Community-attributed (mlx-swift-lm thread on the Qwen3-VL vision tower, `notes/repos/issues-mlx-stack.md`
§9; the same technique appears in `mlx_vlm` as `ensure_fused_sdpa`). The argument is simple: `Q·K` over
zero-padded channels adds zero to every dot product, and because `scale` is an explicit parameter
rather than derived from `D`, padding does not perturb it.

```python
import mlx.core as mx

def pad_head_dim(x, target_d: int):
    """Zero-pad the last (head) dimension up to target_d. Exact for SDPA."""
    d = x.shape[-1]
    if d == target_d:
        return x
    if d > target_d:
        raise ValueError(f"cannot pad {d} down to {target_d}")
    pad = [(0, 0)] * (x.ndim - 1) + [(0, target_d - d)]
    return mx.pad(x, pad)

def fused_sdpa(q, k, v, *, scale, mask=None, target_d=None):
    """SDPA with optional head-dim padding so the fused Metal kernel dispatches.

    scale is passed through UNCHANGED — it must stay 1/sqrt(original_d).
    """
    d = q.shape[-1]
    if target_d is None:
        return mx.fast.scaled_dot_product_attention(q, k, v, scale=scale, mask=mask)
    q = pad_head_dim(q, target_d)
    k = pad_head_dim(k, target_d)
    v = pad_head_dim(v, target_d)
    out = mx.fast.scaled_dot_product_attention(q, k, v, scale=scale, mask=mask)
    return out[..., :d]          # trim V's padded channels back off

# Qwen3-VL vision tower: 72 -> 80 puts you in the full/prefill allow-list {64, 80, 128}
# out = fused_sdpa(q, k, v, scale=72 ** -0.5, target_d=80)
```

🟡 **RECONSTRUCTED.** The *technique* is ✅ community-verified with a stated correctness argument, and
72→80 is the exact case reported. The code above is written for this guide, not copied from a
shipping repo. Two things to be careful about, both of which the snippet handles explicitly:

- **`scale` must remain `1/sqrt(original_d)`.** If you recompute it from the padded shape you have
  changed the model. This is the mistake to look for in a code review.
- **Pad `v` too, then trim the output.** `v`'s padded channels produce zero output channels, so
  slicing them off is exact — but if you pad only `q` and `k`, `D_q != D_v` and you land in the
  *asymmetric* case, which is only supported for exactly `(192, 128)`.
- **Pick your target from the right list.** 96 is in the *vector* set but not the *full* set. If your
  workload is prefill-dominant, target `{64, 80, 128}`; if decode-dominant, `{64, 96, 128, 256}`.
  There is no single value that is optimal for both unless it is 64 or 128.

Padding costs bandwidth proportional to the padding ratio. 72→80 is +11 %; 96→128 is +33 %. Measure.

### 5.7 Two adjacent SDPA traps

**Trap A — `MLX_SDPA_BLOCKS` must be a multiple of 32.**

`MLX_SDPA_BLOCKS` is a new-in-0.32.0 override for the Metal SDPA block size (✅ VERIFIED,
`mlx/backend/metal/scaled_dot_product_attention.cpp:477`). It was added validated only for `> 0`,
but pass 2 in `sdpa_vector.h` iterates `blocks / BN` with `BN = 32` and **integer division**:

```cpp
for (int b = 0; b < blocks / BN; ++b) {
  max_score = max(max_score, maxs[simd_lid + BN * b]);
}
```

> ⚠️ **SILENT FAILURE — a non-multiple-of-32 `MLX_SDPA_BLOCKS` silently corrupts attention.**
> Quoting the PR: *"Any other value silently corrupts the attention output on every decode step —
> **no error, no clamp**."* Fixed by **mlx PR #3875 (MERGED 2026-07-22)**, which rounds the override
> up to the next multiple of 32. **On mlx ≤ 0.32.0, if you set this variable, use a multiple of 32.**
> The built-in choices are 32–1024, all multiples of 32. **Safe default: do not set it at all** —
> one sweep on M1 Ultra (mlx#3837) found MLX's default selection was already optimal for that shape.

**Trap B — the `L = 8 → L = 12` routing cliff.**

Community-measured on **M5 Max**, GQA 32 q / 8 kv, `head_dim = 128`, `float16`, no mask (mlx#3826):

| S (KV length) | L=8 | L=12 | L=16 | L=32 | L=48 | L=64 |
|---|---|---|---|---|---|---|
| 16384 | 0.813 ms | 1.906 ms | 1.903 ms | 1.904 ms | 1.904 ms | 1.588 ms |
| 32768 | 1.319 ms | 3.633 ms | 3.646 ms | 3.643 ms | 3.630 ms | 2.992 ms |

`L = 8 → 12` is a **2.34× (16K) / 2.75× (32K)** jump for 1.5× the work, then a **flat plateau from
L=12 to L=48**, recovering at `L ≥ 64`. The mechanism: the vector kernel's small-L path caps at
`T_q ≤ 8`, so at 12 everything falls to a path tuned for much larger L.

This lands squarely on **speculative decoding** — MTP, prompt-lookup and draft-model verify steps
live at L ≈ 4–16, and batched short continuations at 12–48. A surprising corollary from the same
thread: *"the decomposed **quantized** attention (`qmm → softmax → qmm`) **beats** fp16 SDPA at L=16
at these S (0.35–0.48× its latency)"* — i.e. in that specific window, the "slow" decomposed path
wins. Measure your actual `L`.

---

## 6. The rest of `mx.fast`, and why fused beats hand-composed

`mx.fast` is a small module with an outsized effect. ✅ **VERIFIED** — the complete surface, from
`docs/src/python/fast.rst`:

```
mx.fast.rms_norm
mx.fast.layer_norm
mx.fast.rope
mx.fast.scaled_dot_product_attention     # §5
mx.fast.metal_kernel                     # §7-§9
mx.fast.cuda_kernel
mx.fast.precompiled_cuda_kernel
```

The first four are **hand-written fused kernels for the four operations that dominate transformer
runtime**. The last three are the escape hatch. This section is about the first three; §5 covered
attention.

### 6.1 The mechanical reason: `mx.compile` does not fuse reductions

The obvious question is "why can't I just write RMS norm out of primitives and let `mx.compile` fuse
it?" The answer is in MLX's compiler, and it is decisive.

✅ **VERIFIED** — `mlx/compile.cpp:77`. Only these primitives are fusable:

```cpp
is_fusable = is_unary || is_binary || is_ternary || is_broadcast
```

- **unary:** `Abs, ArcCos, ArcCosh, ArcSin, ArcSinh, ArcTan, ArcTanh, AsType, Ceil, Cos, Conjugate,
  Cosh, Remainder, Erf, ErfInv, Exp, Floor, Log, Log1p, LogicalNot, Negative, Round, Sigmoid, Sign,
  Sin, Sinh, Square, Sqrt, Tan, Tanh, Expm1, Real, Imag, BitwiseInvert`
- **binary:** `Add, Divide, Equal, Greater, GreaterEqual, Less, LessEqual, LogicalNot, LogicalAnd,
  LogicalOr, LogAddExp, Maximum, Minimum, Multiply, NotEqual, Power, Subtract, BitwiseBinary,
  ArcTan2`
- **ternary:** `Select`
- **broadcast:** `Broadcast`

And, in the same file: `is_reduction = Reduce, ArgReduce` — **explicitly not fused into element-wise
kernels.** Matmuls and gathers are likewise absent from the fusable set.

Now look at what RMS norm needs:

```
x -> square -> MEAN OVER LAST AXIS -> add eps -> rsqrt -> broadcast-multiply x -> multiply weight
                  ^^^^ a reduction
```

The reduction sits in the middle. `mx.compile` can fuse the element-wise work *before* it and the
element-wise work *after* it, but it cannot fuse **across** it. So the compiled version is at least:
one element-wise kernel, one reduction kernel, one more element-wise kernel — **three kernel
launches and two round-trips of the full activation tensor through memory.** The fused
`mx.fast.rms_norm` is one launch that reads `x` once, reduces in registers/threadgroup memory, and
writes once.

The same argument applies to `layer_norm` (two reductions: mean and variance) and, for different
reasons, to `rope` (a gather-like index pattern plus trig) and SDPA (two matmuls around a softmax
reduction — §5.3 is literally the cost of *not* fusing it).

**This is the general rule and it is worth carrying beyond MLX:** `mx.compile` is an element-wise
fuser. Anything whose shape requires a reduction, a matmul or a gather in the middle is a candidate
for a hand-written kernel — either one MLX already ships (`mx.fast.*`) or one you write (§7).

MLX ships benchmarks for exactly these, which is where you should start if you want your own numbers:
`benchmarks/python/rms_norm_bench.py`, `layer_norm_bench.py`, `rope_bench.py`, `sdpa_bench.py`,
`sdpa_vector_bench.py` (✅ VERIFIED, `notes/repos/mlx-core.md` §25). The canonical harness in
`benchmarks/python/time_utils.py` — **note the warm-up and that `mx.eval` is inside the loop**:

```python
import time
import mlx.core as mx

def time_fn(fn, *args, **kwargs):
    for _ in range(5):                                  # warm up: JIT + kernel cache
        mx.eval(fn(*args, **kwargs))
    num_iters = 100
    tic = time.perf_counter()
    for _ in range(num_iters):
        x = mx.eval(fn(*args, **kwargs))
    toc = time.perf_counter()
    print(f"{1e3 * (toc - tic) / num_iters:.5f} msec")
```

✅ VERIFIED verbatim from `benchmarks/python/time_utils.py`. Timing MLX without a warm-up loop and
without `mx.eval` inside the timed region measures graph construction, not computation — MLX is
lazy, and nothing runs until you evaluate.

### 6.2 `rms_norm` and `layer_norm`

✅ **VERIFIED** — signatures from `python/src/fast.cpp`; prose from `docs/src/python/fast.rst`:

```python
def rms_norm(x: array, weight: Optional[array], eps: float, *, stream=None) -> array
def layer_norm(x: array, weight: Optional[array], bias: Optional[array], eps: float,
               *, stream=None) -> array
```

with the C++ forms (`mlx/fast.h`) matching, taking `std::optional<array>`.

Documented semantics:

- **Normalisation is with respect to the last axis of `x`.** Not an arbitrary axis, not a set of
  axes. If your normalisation axis is not last, you must move it.
- **`weight` must be one-dimensional with the same size as the last axis.**
- **`weight=None` means no scaling happens** — a genuinely useful case, because it gives you a bare
  normalisation without allocating an all-ones weight.
- `layer_norm`'s `bias` is likewise optional.

Practical shape:

```python
import mlx.core as mx

B, T, D = 2, 512, 4096
x = mx.random.normal((B, T, D)).astype(mx.bfloat16)
w = mx.ones((D,), dtype=mx.bfloat16)

y = mx.fast.rms_norm(x, w, 1e-5)                  # fused, one kernel
y_none = mx.fast.rms_norm(x, None, 1e-5)          # normalise only

# LayerNorm with weight and bias
b = mx.zeros((D,), dtype=mx.bfloat16)
z = mx.fast.layer_norm(x, w, b, 1e-5)
```

🟡 **The `mlx.nn` layers.** `nn.RMSNorm`, `nn.LayerNorm` and `nn.GroupNorm` are exported by
`mlx.nn` (✅ VERIFIED from `python/mlx/nn/layers/__init__.py`). That `nn.RMSNorm` / `nn.LayerNorm`
**delegate to `mx.fast.*`** is 🟡 RECONSTRUCTED — the delegation is confirmed in our notes only for
`nn.RoPE`, whose `__call__(x, offset=0)` explicitly delegates to `mx.fast.rope` (✅ VERIFIED,
`python/mlx/nn/layers/positional_encoding.py`). **To resolve:** read
`python/mlx/nn/layers/normalization.py`. **Safe default:** if you care, call `mx.fast.rms_norm`
directly — the fused path is then not in question.

> 🔴 **GAP — custom VJPs for `rms_norm` / `layer_norm` are unverified.** `mlx/fast_primitives.h`
> exists in the tree, and the file map lists `fast.cpp` as containing `rms_norm, layer_norm, rope,
> SDPA, metal_kernel, cuda_kernel`, but whether these primitives implement hand-written backward
> passes (as opposed to being differentiated through their decomposition) was **not** read this
> session. What *is* known is the analogous SDPA behaviour: on Metal, SDPA deliberately falls back
> to the unfused path *for both forward and backward* during training (§5.2). **To resolve:** read
> `mlx/fast.cpp` and `mlx/fast_primitives.h` for `vjp`/`jvp` overrides.
> **Safe default:** do not assume training-time speedups from `mx.fast.*` without measuring;
> assume inference-time speedups are real.

### 6.3 `rope`

✅ **VERIFIED** — `python/src/fast.cpp`:

```python
def rope(a: array, dims: int, *, traditional: bool, base: Optional[float], scale: float,
         offset: Union[int, array], freqs: Optional[array] = None, stream=None) -> array
```

Note that `traditional`, `base`, `scale` and `offset` are **keyword-only and have no published
defaults** — you must pass all four. The C++ side has two overloads, one taking an `int` offset and
one taking an `array` offset for per-batch positions (`mlx/fast.h`).

The documented rules, each of which is a real constraint:

- **Input must be at least 3-D**, shape `(B, *, T, D)`.
- **"Exactly one of `base` and `freqs` must be `None`."** Verbatim. Pass a `base` for standard RoPE;
  pass `freqs` and `base=None` for a custom frequency schedule (YaRN, NTK-aware scaling, partial
  RoPE tables). Passing both, or neither, is an error.
- **`offset` may be an `int`, or an `array`** — scalar, or a **vector of `B` per-example offsets.**
  That array form is what makes batched generation with ragged KV caches expressible in one call
  instead of a Python loop.
- **`traditional=True` rotates *consecutive* dimensions**; the default (`False`) uses the
  split-halves convention that most Hugging Face checkpoints use. Getting this backwards produces a
  model that generates fluent nonsense — no error, degraded output. Check it against the reference
  implementation for your checkpoint.
- **`dims` may be smaller than `D`; the remainder is left unchanged.** This is how partial RoPE (e.g.
  25 % rotary, as in some Gemma 4 layers) is expressed.

```python
import mlx.core as mx

B, H, T, D = 1, 32, 128, 128
x = mx.random.normal((B, H, T, D)).astype(mx.bfloat16)

# Standard RoPE at position offset 0
y = mx.fast.rope(x, dims=D, traditional=False, base=10000.0, scale=1.0, offset=0)

# Decode step: one new token at position 512
x1 = mx.random.normal((B, H, 1, D)).astype(mx.bfloat16)
y1 = mx.fast.rope(x1, dims=D, traditional=False, base=10000.0, scale=1.0, offset=512)

# Partial RoPE: rotate only the first 32 dims, leave the rest alone
y2 = mx.fast.rope(x, dims=32, traditional=False, base=10000.0, scale=1.0, offset=0)

# Custom frequencies: base MUST be None
freqs = mx.arange(D // 2).astype(mx.float32)   # placeholder schedule
y3 = mx.fast.rope(x, dims=D, traditional=False, base=None, scale=1.0, offset=0, freqs=freqs)
```

The `mlx.nn` wrapper, ✅ VERIFIED from `python/mlx/nn/layers/positional_encoding.py`:
`nn.RoPE(dims, traditional=False, base=10000, scale=1.0)` with `__call__(x, offset: int = 0)`
delegating to `mx.fast.rope`. Note that the layer's `__call__` takes only an `int` offset, so the
per-batch-offset array form requires calling `mx.fast.rope` directly.

### 6.4 When *not* to use the fused primitive

Three honest cases:

1. **When you need something the primitive does not express.** A norm over a non-last axis; a mask
   shape SDPA rejects; a rotary scheme that is not `base`-or-`freqs`. Composing ops is correct and
   slow; writing a kernel (§7) is fast and yours to maintain. Do not contort your model into the
   primitive's shape and then wonder why the numbers moved.
2. **When you are training on Metal and the primitive falls back anyway.** For SDPA this is
   documented and unconditional (§5.2). Measure before assuming a fused call is buying you anything
   in a training loop.
3. **When the fused kernel is the thing that is wrong.** On M5, the NAX attention kernel is
   implicated in `bfloat16`/`float16` batch-versus-single divergence (mlx#3897, §1.4) and the
   affine-quantized gather path had a silent-corruption bug (§13's checklist). Being able to switch
   to the composed path — by disabling NAX with `MLX_METAL_GPU_ARCH`, or by writing the composition
   out explicitly — is a debugging capability, not just a fallback.

---

## 7. `mx.fast.metal_kernel`: the complete API

This is the part of MLX that has no equivalent in most array frameworks: **you write Metal Shading
Language in a Python string, and MLX generates the function signature, JIT-compiles it, and wires it
into the lazy graph as a first-class op.** No Xcode project, no `.metal` file, no build step, no
`ctypes`. It is the fastest path from "the fused kernel I need does not exist" to "the fused kernel I
need exists."

### 7.1 Constructor

✅ **VERIFIED** — `python/src/fast.cpp:391-398`, corroborated by the autosummary block on
`docs/src/python/fast.html`:

```python
mx.fast.metal_kernel(
    name: str,
    input_names: List[str],
    output_names: List[str],
    source: str,
    header: str = "",
    ensure_row_contiguous: bool = True,
    atomic_outputs: bool = False,
    compile_options: Optional[dict] = None,   # {"math_mode": "safe"|"relaxed"|"fast"}
)
```

Parameter by parameter, with the documentation's own words where they are load-bearing:

| Parameter | Meaning |
|---|---|
| `name` | Name for the kernel. Becomes part of the generated Metal function name (§7.3). |
| `input_names` | *"The parameter names of the inputs in the function signature."* These are the identifiers you use in `source`. |
| `output_names` | *"The parameter names of the outputs in the function signature."* Likewise. |
| `source` | *"Source code. This is the **body** of a function in Metal, the function signature will be automatically generated."* |
| `header` | *"Header source code to include **before** the main function. Useful for helper functions or includes that should live outside of the main function body."* |
| `ensure_row_contiguous` | *"Whether to ensure the inputs are row contiguous before the kernel runs."* Default `True` — **this can copy** (§9.1). |
| `atomic_outputs` | *"Whether to use atomic outputs in the function signature e.g. `device atomic<float>`."* Default `False` (§9.4). |
| `compile_options` | Currently only `{"math_mode": ...}` (§7.5). |

**The single most important operational note**, ✅ VERIFIED verbatim from
`docs/src/dev/custom_metal_kernels.rst`:

> **"Every time you make a kernel, a new Metal library is created and possibly JIT compiled. To
> reduce the overhead from that, build the kernel once with `fast.metal_kernel()` and then use it
> many times."**

Construct at module scope or in a cached factory. Constructing inside your forward pass compiles a
new Metal library **per call**. (MLX has been optimising the cheaper half of this: commit `7c92ce1`,
*"[Metal] Avoid regex in custom kernel name generation (#3869)"* — but the library creation itself
is the expensive part and hoisting is the fix.)

```python
import mlx.core as mx

# RIGHT: build once, at import time.
_EXP_KERNEL = mx.fast.metal_kernel(
    name="myexp",
    input_names=["inp"],
    output_names=["out"],
    source="""
        uint elem = thread_position_in_grid.x;
        T tmp = inp[elem];
        out[elem] = metal::exp(tmp);
    """,
)

def exp_elementwise(a):
    return _EXP_KERNEL(
        inputs=[a],
        template=[("T", mx.float32)],
        grid=(a.size, 1, 1),
        threadgroup=(256, 1, 1),
        output_shapes=[a.shape],
        output_dtypes=[a.dtype],
    )[0]

# WRONG: recompiles a Metal library on every call.
def exp_elementwise_slow(a):
    k = mx.fast.metal_kernel(name="myexp", input_names=["inp"], output_names=["out"], source="...")
    ...
```

### 7.2 The returned callable

`mx.fast.metal_kernel(...)` returns a **callable object**, not an array. Calling it runs the kernel
and returns a **list of arrays**, one per `output_names` entry.

✅ **VERIFIED** — from `python/src/fast.cpp` (the binding source), read in
`notes/repos/mlx-core.md` §9.4:

```python
def __call__(self, *,
             inputs: List[Union[scalar, array]],
             output_shapes: List[Sequence[int]],
             output_dtypes: List[Dtype],
             grid: tuple[int, int, int],
             threadgroup: tuple[int, int, int],
             template: Optional[List[Tuple[str, Union[bool, int, Dtype]]]] = None,
             init_value: Optional[float] = None,
             verbose: bool = False,
             stream: Union[None, Stream, Device] = None)
```

> **A source conflict, resolved.** The MLX documentation site **never publishes this signature**; the
> crawl's own note says so and marks the kwarg list as *"inferred from every example on the site"*,
> with `stream=` explicitly listed as unknown. The binding source above is the stronger evidence and
> it **confirms `stream=` exists**. Where the docs and the source disagree, the source wins. If you
> need to be certain on your install: `help(mx.fast.metal_kernel(...))` or
> `inspect.signature` on the returned object.

Notes on the call arguments:

- **All keyword-only.** There are no positional forms.
- **`inputs` may contain scalars as well as arrays.** A Python `int`/`float` passed here becomes a
  scalar kernel argument rather than a buffer. (🟡 The scalar handling is stated in the binding's
  type annotation `Union[scalar, array]`; no worked example of the scalar form exists in our corpus.
  **Safe default:** if in doubt, bake constants into `template=` as `int`/`bool` template parameters,
  which *is* documented, or pass a 1-element array.)
- **`output_shapes` and `output_dtypes` are mandatory and parallel to `output_names`.** MLX does not
  infer output shape from your kernel; you declare it.
- **`template` is how you get a `template <typename T>`** on the generated function (§9.2).
- **`init_value` pre-fills every output element** before the kernel runs (§9.4).
- **`verbose=True` prints the full generated Metal source.** Use it the first time you write any
  kernel (§9.5).
- **`stream=`** places the launch on a specific stream or device, like every other MLX op.

### 7.3 How the function signature is generated

You write the **body**. MLX writes the signature. The rules are worth memorising because a mismatch
between what you assume and what MLX generates is the most common compile failure.

✅ **VERIFIED** — verbatim from `docs/src/dev/custom_metal_kernels.rst`:

> The full function signature will be generated using:
>
> - **The shapes/dtypes of `inputs`** — … `a` is an `mx.array` of type `mx.float16` and we pass it
>   with the key `inp` so we will add `const device float16_t* inp` to the signature.
>   **`inp_shape`, `inp_strides` and `inp_ndim` are also added for convenience if they are present in
>   `source`.**
> - **The list of `output_dtypes`** — … `out` is an `mx.array` of type `mx.float16` so we add
>   `device float16_t* out`.
> - **Template parameters passed using `template`** — … `template=[("T", mx.float32)]` adds a
>   template of `template <typename T>` to the function and instantiates the template. **Template
>   parameters can be `mx.core.Dtype`, `int` or `bool`.**
> - **Metal attributes used in `source` such as `[[thread_position_in_grid]]`** — These will be added
>   as function arguments. **All the attributes defined in Table 5.8 of the Metal Shading Language
>   Specification are supported.**

Four consequences:

1. **Input and output identifiers come from `input_names` / `output_names`.** In the example, `inp`
   and `out` are not magic — they are the strings you passed.
2. **Shape/stride helpers appear only if you mention them.** Writing `inp_strides` anywhere in
   `source` causes `inp_shape`, `inp_strides` and `inp_ndim` to be added to the signature. Not
   mentioning them keeps the signature lean. This is a **textual** trigger, so a mention inside a
   comment also counts.
3. **Metal attribute variables appear only if you mention them.** `thread_position_in_grid`,
   `threads_per_threadgroup`, `thread_index_in_simdgroup`, `threads_per_simdgroup`,
   `threadgroup_position_in_grid` and the rest of MSL Table 5.8 are injected on demand, by name.
4. **You do not write `[[kernel]]`, the parameter list, or the braces.** Only statements.

Here is what MLX actually generates for the `myexp` example — ✅ VERIFIED verbatim from the docs:

```cpp
template <typename T>
[[kernel]] void custom_kernel_myexp_float_float16_t_float16_t(
        const device float16_t* inp [[buffer(0)]],
        device float16_t* out [[buffer(1)]],
        uint3 thread_position_in_grid [[thread_position_in_grid]]) {

        uint elem = thread_position_in_grid.x;
        T tmp = inp[elem];
        out[elem] = metal::exp(tmp);

}

template [[host_name("custom_kernel_myexp_float_float16_t_float16_t")]] [[kernel]]
decltype(custom_kernel_myexp_float_float16_t_float16_t<float>)
custom_kernel_myexp_float_float16_t_float16_t<float>;
```

Read the generated name: `custom_kernel_<name>_<template args>_<input dtypes>_<output dtypes>`. Note
that the **input array is `float16_t` while the template parameter `T` is `float`** — that is the
example deliberately computing in `float` over `half` storage, which is exactly the accumulator-width
control §2's Rule 1 talked about. The buffer type comes from the array you pass; `T` comes from
`template=`; they are independent.

Two more automatic conveniences, ✅ VERIFIED from the same page:

- **`mlx/backend/metal/kernels/utils.h` is automatically included**, so `elem_to_loc` and `ceildiv`
  are available with no work from you.
- **"Output arrays are always row contiguous."** You index outputs with the raw linear index. Only
  *inputs* can be strided (§9.1).

### 7.4 `grid` and `threadgroup` are in THREADS

The single most common mistake for anyone arriving from CUDA. ✅ VERIFIED verbatim:

> **Note**: `grid` and `threadgroup` are parameters to the Metal **`dispatchThreads`** function. This
> means we will launch **`mx.prod(grid)` threads**, subdivided into `threadgroup` size threadgroups.
> For optimal performance, each thread group dimension should be less than or equal to the
> corresponding grid dimension.

So for an element-wise kernel over `a`:

```python
grid=(a.size, 1, 1),          # TOTAL THREADS, not blocks
threadgroup=(256, 1, 1),      # threads per threadgroup
```

In CUDA you would write `blocks = ceil(n / 256)`. Here you write `n`. Getting this wrong by writing
the CUDA form launches 256× too few threads and quietly computes only the first `n/256` elements —
the rest of the output holds whatever `init_value` left there, or uninitialised memory.

Note the API-compatibility decision MLX made for the CUDA backend: `mx.fast.cuda_kernel` and
`mx.fast.precompiled_cuda_kernel` **also take the grid in threads**, explicitly *"For compatibility
with `metal_kernel()` the grid is in threads and not in threadblocks."* (✅ VERIFIED). So a kernel
written for one backend ports without recomputing the launch geometry.

🔴 **GAP — the maximum threadgroup size is not a constant you can assume.** MLX does not surface a
per-pipeline `maxTotalThreadsPerThreadgroup` query from Python. Community measurement on mlx#3885
found that on **M1 Max (`applegpu_g13s`)** the Metal compiler register-limits some `d=512` SDPA
pipelines to **832 threads/threadgroup** while every other head dim gets 1024 — and that the 1-pass
kernel dispatched a flat 1024 with **no size check at all**, so *"the launch is invalid, the GPU drops
it, and the kernel returns all zeros."* **To resolve:** probe `maxTotalThreadsPerThreadgroup` on the
built pipeline (which requires the Metal API, not MLX's Python surface).
**Safe default: use 256.** It is what every MLX example uses, it is comfortably under every
register-limited ceiling observed, and if you go higher, verify your output is not all zeros before
believing your speedup.

### 7.5 Math mode

`compile_options={"math_mode": ...}` is a newer option — added by commit `51bef6f`,
*"Add math mode option for custom Metal kernels (#3728)"*, which closes issue #3592. ✅ VERIFIED.

> **Default is `"safe"`.** Verbatim from the docs: *"By default `fast.metal_kernel()` compiles kernels
> with `compile_options={"math_mode": "safe"}` so special values follow IEEE behavior, for example
> `exp(-inf) == 0`. **This is important for kernels such as masked softmax where causal or
> sliding-window masks depend on exponentiating `-inf`.**"*

The three values are `"safe"`, `"relaxed"`, `"fast"`. Error strings, ✅ VERIFIED:

- `"[metal_kernel] Expected math_mode to be 'safe', 'relaxed', or 'fast'."`
- `"[metal_kernel] Unknown compile option \`<key>\`."`

Both surface as `ValueError` in Python (test `test_custom_metal_kernel_math_mode` in
`python/tests/test_fast.py`). Internally parsed by `parse_metal_math_mode` →
`mx::MathMode::{Safe, Relaxed, Fast}` (`python/src/fast.cpp:78-88`).

> ⚠️ **SILENT FAILURE — `math_mode` "relaxed"/"fast" breaks masked softmax.** If you write a masked
> attention or masked reduction kernel and set `math_mode` to anything but `"safe"`, `exp(-inf)` is
> no longer guaranteed to be `0`. Masked positions then contribute a non-zero (or NaN) weight to your
> softmax denominator. **The kernel compiles, runs, and returns plausible numbers with wrong
> attention.** This is not hypothetical — it is precisely the case Apple's own MLX documentation
> calls out as the reason `"safe"` is the default.
> **Safe default: leave `math_mode` alone.** Only opt into `relaxed`/`fast` for a kernel you have
> proven has no special-value dependence, and diff it against the `"safe"` build before shipping.

```python
kernel = mx.fast.metal_kernel(
    name="my_kernel",
    input_names=["x"],
    output_names=["y"],
    source=source,
    compile_options={"math_mode": "relaxed"},   # only if you have proven you can
)
```

🔴 **GAP — whether `compile_options` will accept other keys.** Today `math_mode` is the only
recognised key and anything else raises. Issue #3592, which #3728 closed, *also* asked for
`-fmetal-math-mode`, **integer template parameters**, and **Metal 4 Tensor types** — only the math
mode landed. §11 draws the consequence.

---

## 8. A complete worked example

Three examples, in increasing order of realism. The first two are **✅ VERIFIED verbatim from MLX's
own documentation** and are the ones to copy. The third is written for this guide and marked
accordingly.

### 8.1 The minimal kernel, end to end

✅ **VERIFIED verbatim** — `docs/src/dev/custom_metal_kernels.rst:15-43`, complete and runnable:

```python
import mlx.core as mx

source = """
    uint elem = thread_position_in_grid.x;
    T tmp = inp[elem];
    out[elem] = metal::exp(tmp);
"""

kernel = mx.fast.metal_kernel(
    name="myexp",
    input_names=["inp"],
    output_names=["out"],
    source=source,
)

def exp_elementwise(a: mx.array):
    outputs = kernel(
        inputs=[a],
        template=[("T", mx.float32)],
        grid=(a.size, 1, 1),
        threadgroup=(256, 1, 1),
        output_shapes=[a.shape],
        output_dtypes=[a.dtype],
    )
    return outputs[0]

a = mx.random.normal(shape=(4, 16)).astype(mx.float16)
b = exp_elementwise(a)
assert mx.allclose(b, mx.exp(a))
```

Twelve lines of Python and three lines of Metal, and you have a new op that participates in MLX's
lazy graph like any other. Note the shape of the pattern, which every kernel in this section repeats:

1. `source` is a **body** — statements only.
2. The kernel object is built **once**, at module scope.
3. The call site supplies `inputs`, `template`, `grid`, `threadgroup`, `output_shapes`,
   `output_dtypes`, and unpacks `outputs[0]`.
4. **There is an assertion against the reference implementation.** Keep that habit. Custom kernels do
   not throw when they are wrong.

### 8.2 The realistic one: fused bilinear `grid_sample`

This is MLX's own worked example, and it is worth studying because it shows what "fusing" actually
buys. The reference implementation in ordinary MLX ops does **four separate gathers**, four boolean
mask computations, four masked multiplies and a four-term weighted sum — every one of which
materialises a full-size intermediate.

✅ **VERIFIED verbatim** — `docs/src/dev/custom_metal_kernels.rst`. Reference implementation first:

```python
import mlx.core as mx
import numpy as np

def grid_sample_ref(x, grid):
    N, H_in, W_in, _ = x.shape
    ix = ((grid[..., 0] + 1) * W_in - 1) / 2
    iy = ((grid[..., 1] + 1) * H_in - 1) / 2

    ix_nw = mx.floor(ix).astype(mx.int32)
    iy_nw = mx.floor(iy).astype(mx.int32)

    ix_ne = ix_nw + 1
    iy_ne = iy_nw

    ix_sw = ix_nw
    iy_sw = iy_nw + 1

    ix_se = ix_nw + 1
    iy_se = iy_nw + 1

    nw = (ix_se - ix)    * (iy_se - iy)
    ne = (ix    - ix_sw) * (iy_sw - iy)
    sw = (ix_ne - ix)    * (iy    - iy_ne)
    se = (ix    - ix_nw) * (iy    - iy_nw)

    I_nw = x[mx.arange(N)[:, None, None], iy_nw, ix_nw, :]
    I_ne = x[mx.arange(N)[:, None, None], iy_ne, ix_ne, :]
    I_sw = x[mx.arange(N)[:, None, None], iy_sw, ix_sw, :]
    I_se = x[mx.arange(N)[:, None, None], iy_se, ix_se, :]

    mask_nw = (iy_nw >= 0) & (iy_nw <= H_in - 1) & (ix_nw >= 0) & (ix_nw <= W_in - 1)
    mask_ne = (iy_ne >= 0) & (iy_ne <= H_in - 1) & (ix_ne >= 0) & (ix_ne <= W_in - 1)
    mask_sw = (iy_sw >= 0) & (iy_sw <= H_in - 1) & (ix_sw >= 0) & (ix_sw <= W_in - 1)
    mask_se = (iy_se >= 0) & (iy_se <= H_in - 1) & (ix_se >= 0) & (ix_se <= W_in - 1)

    I_nw *= mask_nw[..., None]
    I_ne *= mask_ne[..., None]
    I_sw *= mask_sw[..., None]
    I_se *= mask_se[..., None]

    output = nw[..., None] * I_nw + ne[..., None] * I_ne + sw[..., None] * I_sw + se[..., None] * I_se

    return output
```

And the fused kernel that replaces all of it:

```python
source = """
    uint elem = thread_position_in_grid.x;
    int H = x_shape[1];
    int W = x_shape[2];
    int C = x_shape[3];
    int gH = grid_shape[1];
    int gW = grid_shape[2];

    int w_stride = C;
    int h_stride = W * w_stride;
    int b_stride = H * h_stride;

    uint grid_idx = elem / C * 2;
    float ix = ((grid[grid_idx] + 1) * W - 1) / 2;
    float iy = ((grid[grid_idx + 1] + 1) * H - 1) / 2;

    int ix_nw = floor(ix);
    int iy_nw = floor(iy);

    int ix_ne = ix_nw + 1;
    int iy_ne = iy_nw;

    int ix_sw = ix_nw;
    int iy_sw = iy_nw + 1;

    int ix_se = ix_nw + 1;
    int iy_se = iy_nw + 1;

    T nw = (ix_se - ix)    * (iy_se - iy);
    T ne = (ix    - ix_sw) * (iy_sw - iy);
    T sw = (ix_ne - ix)    * (iy    - iy_ne);
    T se = (ix    - ix_nw) * (iy    - iy_nw);

    int batch_idx = elem / C / gH / gW * b_stride;
    int channel_idx = elem % C;
    int base_idx = batch_idx + channel_idx;

    T I_nw = x[base_idx + iy_nw * h_stride + ix_nw * w_stride];
    T I_ne = x[base_idx + iy_ne * h_stride + ix_ne * w_stride];
    T I_sw = x[base_idx + iy_sw * h_stride + ix_sw * w_stride];
    T I_se = x[base_idx + iy_se * h_stride + ix_se * w_stride];

    I_nw = iy_nw >= 0 && iy_nw <= H - 1 && ix_nw >= 0 && ix_nw <= W - 1 ? I_nw : 0;
    I_ne = iy_ne >= 0 && iy_ne <= H - 1 && ix_ne >= 0 && ix_ne <= W - 1 ? I_ne : 0;
    I_sw = iy_sw >= 0 && iy_sw <= H - 1 && ix_sw >= 0 && ix_sw <= W - 1 ? I_sw : 0;
    I_se = iy_se >= 0 && iy_se <= H - 1 && ix_se >= 0 && ix_se <= W - 1 ? I_se : 0;

    out[elem] = nw * I_nw + ne * I_ne + sw * I_sw + se * I_se;
"""

kernel = mx.fast.metal_kernel(
    name="grid_sample",
    input_names=["x", "grid"],
    output_names=["out"],
    source=source,
)

@mx.custom_function
def grid_sample(x, grid):

    assert x.ndim == 4, "`x` must be 4D."
    assert grid.ndim == 4, "`grid` must be 4D."

    B, _, _, C = x.shape
    _, gN, gM, D = grid.shape
    out_shape = (B, gN, gM, C)

    assert D == 2, "Last dim of `grid` must be size 2."

    outputs = kernel(
        inputs=[x, grid],
        template=[("T", x.dtype)],
        output_shapes=[out_shape],
        output_dtypes=[x.dtype],
        grid=(np.prod(out_shape), 1, 1),
        threadgroup=(256, 1, 1),
    )
    return outputs[0]
```

**MLX-project-published measurement**, quoted verbatim from the same page: for
`x.shape = (8, 1024, 1024, 64)` and `grid.shape = (8, 256, 256, 2)`, **on an M1 Max**:

> **`55.7ms -> 6.7ms => 8x speed up`**

⚠️ Attribution: this is a number published by the MLX project in its own documentation. **Hardware:
M1 Max. OS, MLX version and date: unstated.** No independent reproduction exists in our corpus.

Four techniques in that listing worth naming explicitly, because you will reuse all four:

1. **`x_shape[i]` and `grid_shape[i]` are used to derive strides in-kernel.** Mentioning them in
   `source` is what causes MLX to inject them (§7.3).
2. **`template=[("T", x.dtype)]` propagates the caller's dtype** into the kernel, so one kernel
   object serves `float32`, `float16` and `bfloat16` — MLX instantiates per dtype and caches.
3. **Bounds checks are `? :` selects, not branches around the load.** The loads happen
   unconditionally and out-of-bounds contributions are zeroed afterwards. That is deliberate: it is
   the same pattern MLX's own quantized kernels use, and it avoids divergence. It also means the
   loads themselves must be in-bounds *as addresses*, which the surrounding math guarantees here.
4. **`@mx.custom_function` wraps the whole thing**, which is what lets you attach a VJP (§9.4) and
   makes the op differentiable.

### 8.3 A fused row normaliser, written from scratch

This one is written **for this guide**. It is the shape of kernel you will most often want: a
**row-wise reduction followed by a row-wise scale** — precisely the pattern `mx.compile` cannot fuse
(§6.1).

Design: **one simdgroup (32 threads) per row.** Each lane strides across the row accumulating squares,
`simd_sum` reduces across the lane, every lane recomputes the same scale, and a second strided loop
writes the output. `eps` arrives as a one-element array because template parameters may only be
`Dtype`, `int` or `bool` — not `float` (§7.3).

> 🟡 **RECONSTRUCTED — this listing was written for this guide and has NOT been executed.** Every
> Metal construct in it is attested in MLX's own documented examples (`thread_position_in_grid`,
> `thread_index_in_simdgroup`, `threads_per_simdgroup`, `simd_sum`, `metal::rsqrt`, `x_shape` /
> `x_ndim` injection) and every Python argument is ✅ VERIFIED in §7. But the composition is mine.
> **The assertion at the bottom is not decoration — run it before you trust this.** If it fails, the
> most likely culprits are the lane/row decomposition and the `threadgroup` size relative to
> `threads_per_simdgroup`.

```python
import mlx.core as mx

_ROWNORM_SRC = """
    // One simdgroup per row. grid.x = n_rows * threads_per_simdgroup.
    uint gid  = thread_position_in_grid.x;
    uint lane = thread_index_in_simdgroup;
    uint simd = threads_per_simdgroup;
    uint row  = gid / simd;

    int D = x_shape[x_ndim - 1];

    // Pass 1: sum of squares across the row, strided by simd width.
    float acc = 0.0f;
    for (int i = int(lane); i < D; i += int(simd)) {
        float v = float(x[row * uint(D) + uint(i)]);
        acc += v * v;
    }
    float ss = simd_sum(acc);

    // Every lane computes the same scale; no broadcast needed.
    float scale = metal::rsqrt(ss / float(D) + float(eps[0]));

    // Pass 2: scale and apply the per-feature weight.
    for (int i = int(lane); i < D; i += int(simd)) {
        uint idx = row * uint(D) + uint(i);
        out[idx] = T(float(x[idx]) * scale * float(w[i]));
    }
"""

_ROWNORM = mx.fast.metal_kernel(
    name="rownorm",
    input_names=["x", "w", "eps"],
    output_names=["out"],
    source=_ROWNORM_SRC,
    # default ensure_row_contiguous=True: inputs are made contiguous for us,
    # so raw linear indexing above is valid.
    # default math_mode="safe": keep it (§7.5).
)

SIMD_WIDTH = 32   # see the GAP note below

def rownorm(x: mx.array, w: mx.array, eps: float = 1e-5) -> mx.array:
    """RMS-style row normalisation, fused into one kernel launch."""
    assert x.ndim >= 2, "x must be at least 2D"
    assert w.ndim == 1 and w.shape[0] == x.shape[-1], "w must match the last axis of x"
    n_rows = x.size // x.shape[-1]
    eps_arr = mx.array([eps], dtype=mx.float32)
    (out,) = _ROWNORM(
        inputs=[x, w, eps_arr],
        template=[("T", x.dtype)],
        grid=(n_rows * SIMD_WIDTH, 1, 1),
        threadgroup=(256, 1, 1),
        output_shapes=[x.shape],
        output_dtypes=[x.dtype],
    )
    return out

# ---- the assertion that makes this trustworthy -----------------------------
if __name__ == "__main__":
    mx.random.seed(0)
    B, T, D = 2, 17, 512                 # deliberately not a round row count
    x = mx.random.normal((B, T, D)).astype(mx.float32)
    w = mx.random.normal((D,)).astype(mx.float32)

    got = rownorm(x, w, 1e-5)
    ref = mx.fast.rms_norm(x, w, 1e-5)   # MLX's own fused kernel as ground truth
    mx.eval(got, ref)

    err = (mx.abs(got - ref).max()).item()
    print("max abs err vs mx.fast.rms_norm:", err)
    assert err < 1e-4, f"kernel disagrees with mx.fast.rms_norm by {err}"
    print("OK")
```

Three things to notice about that script, all of which generalise:

- **The reference is `mx.fast.rms_norm`, not a hand-composed formula.** Diffing a new kernel against
  a *different* implementation of the same maths is a much stronger test than diffing it against
  your own arithmetic, because it catches your misunderstanding of the maths as well as your bug.
- **`D = 512` and `T = 17`.** Pick a row count that is not a multiple of your threadgroup size and a
  row width that is a multiple of the simd width; then re-run with the opposite. Boundary handling is
  where custom kernels break, and it breaks silently.
- **`float` accumulation over a `T`-typed load.** `acc` is `float` regardless of `T`. This is §2's
  Rule 1 applied deliberately: you control the accumulator width in a custom kernel, and for a
  sum-of-squares over 512 terms in `bfloat16` you very much want to.

> 🔴 **GAP — `SIMD_WIDTH = 32` is a hardcoded host-side assumption.** The kernel reads the true value
> from `threads_per_simdgroup`, but the *host* needs the same number to size the grid and has no way
> to ask MLX for it. 32 is the value used throughout MLX's own kernels and its documented VJP example
> (`simdgroup_size = 32` appears verbatim in `grid_sample_vjp`), and it is correct for every Apple
> GPU in the corpus — but it is an assumption, not a query. **To resolve:** read
> `MTLComputePipelineState.threadExecutionWidth` (Metal API, not reachable from MLX's Python
> surface). **Safe default:** keep 32, and add an in-kernel guard that writes a sentinel if
> `threads_per_simdgroup != 32` so the assumption fails loudly rather than silently.

---

## 9. The advanced options

### 9.1 Strides and non-contiguous inputs

By default, `ensure_row_contiguous=True`. ✅ VERIFIED verbatim:

> `fast.metal_kernel()` supports an argument `ensure_row_contiguous` which is **`True` by default**.
> This will **copy the array inputs if needed** before the kernel is launched to ensure that the
> memory layout is row contiguous.

That default is a convenience with a cost: **a transposed or sliced input is silently copied on every
call.** For a large activation tensor in a hot loop, that copy can dominate your kernel.

To avoid it, set `ensure_row_contiguous=False` and index through the injected stride metadata using
`elem_to_loc`, which comes from `mlx/backend/metal/kernels/utils.h` and is **automatically included**:

✅ **VERIFIED verbatim** — `docs/src/dev/custom_metal_kernels.rst`:

```python
source = """
    uint elem = thread_position_in_grid.x;
    // Utils from `mlx/backend/metal/kernels/utils.h` are automatically included
    uint loc = elem_to_loc(elem, inp_shape, inp_strides, inp_ndim);
    T tmp = inp[loc];
    // Output arrays are always row contiguous
    out[elem] = metal::exp(tmp);
"""

kernel = mx.fast.metal_kernel(
    name="myexp_strided",
    input_names=["inp"],
    output_names=["out"],
    source=source,
    ensure_row_contiguous=False,
)

def exp_elementwise(a: mx.array):
    outputs = kernel(
        inputs=[a],
        template=[("T", mx.float32)],
        grid=(a.size, 1, 1),
        threadgroup=(256, 1, 1),
        output_shapes=[a.shape],
        output_dtypes=[a.dtype],
    )
    return outputs[0]

a = mx.random.normal(shape=(4, 16)).astype(mx.float16)
# make non-contiguous
a = a[::2]
b = exp_elementwise(a)
assert mx.allclose(b, mx.exp(a))
```

> ⚠️ **SILENT FAILURE — `ensure_row_contiguous=False` without `elem_to_loc`.** Turning the flag off
> does not change your indexing for you. If you set `ensure_row_contiguous=False` and keep indexing
> with the raw linear `elem`, MLX hands you the array's actual buffer, strides and all, and your
> kernel reads the wrong elements. **It compiles. It runs. It returns an array of the right shape
> with wrong contents.** For a strided view whose strides happen to be contiguous, it even returns
> the *right* contents — until the day a caller passes a transposed tensor.
> **Safe default: leave `ensure_row_contiguous=True`** until you have measured that the copy matters,
> and when you turn it off, change every input index to `elem_to_loc` in the same commit.

Two asymmetries to remember:

- **Only inputs can be strided. "Output arrays are always row contiguous."** ✅ VERIFIED. Index
  outputs linearly, always.
- **`mx.fast.precompiled_cuda_kernel` defaults `ensure_row_contiguous` to `False`** — the opposite of
  `metal_kernel` and `cuda_kernel` (✅ VERIFIED). If you port a kernel between them, check this.

### 9.2 Template parameters

`template=[(name, value), ...]` where **values may be `mx.core.Dtype`, `int`, or `bool`**
(✅ VERIFIED). This is how you get compile-time specialisation:

```python
outputs = kernel(
    inputs=[x],
    template=[("T", x.dtype), ("BLOCK", 128), ("USE_MASK", True)],
    ...
)
```

The `Dtype` case is the one MLX's own examples show, and the generated code for it is quoted in
§7.3: `template <typename T>` plus an explicit instantiation, with the instantiated name baked into
the `host_name`.

> 🟡 **RECONSTRUCTED — how `int` and `bool` template parameters render.** The docs state plainly that
> those types are accepted, but **no example on the site or in our corpus shows the generated code
> for a non-`Dtype` template parameter.** The natural rendering is `template <typename T, int BLOCK,
> bool USE_MASK>`, but that is inference. Relevant context: issue #3592 asked for *"integer template
> params"* among other things and was closed by the math-mode PR #3728, which suggests the integer
> case is newer than the dtype case.
> **To resolve:** pass one and call with `verbose=True` (§9.5) — MLX prints the generated source, and
> that settles it in one run. **Safe default:** start with `verbose=True` on any kernel using a
> non-`Dtype` template parameter, read the generated declaration, and only then remove it.

Each distinct template instantiation is a distinct compiled kernel. If your `BLOCK` value varies per
call you are compiling per call, which is the §7.1 problem in a different disguise. Quantise your
template values to a small set.

### 9.3 `header=` for helpers and includes

The `header` string is emitted **before** the generated function, so it is where helper functions,
`using` declarations and `#include`s go. ✅ VERIFIED verbatim example:

```python
header = """
template <typename T>
T do_exp(T x) { return metal::precise::exp(x); }
"""

kernel = mx.fast.metal_kernel(
    name="myexp_precise",
    input_names=["inp"],
    output_names=["out"],
    source="""
        uint elem = thread_position_in_grid.x;
        out[elem] = do_exp(inp[elem]);
    """,
    header=header,
)
```

Note `metal::precise::exp` in that snippet — Metal's `precise::` namespace is the per-call-site
alternative to changing `math_mode` globally, and it is a much narrower instrument. If one function
in your kernel needs IEEE behaviour and the rest does not, prefer `precise::` over relaxing the whole
compilation unit.

`header` is also the only place a `#include` can go, which is what §11 is about.

### 9.4 Atomic outputs and `init_value` — the VJP pattern

Scatter-style kernels — anything where multiple threads accumulate into the same output element —
need two options together. ✅ VERIFIED verbatim from the docs:

> - **`init_value=0`** — Initialize all of the kernel's outputs to this value before it runs. This
>   allows us to update only part of the output arrays with the kernel.
> - **`atomic_outputs=True`** — Designate all of the kernel outputs as `atomic` in the function
>   signature. This means we can use Metal's `atomic` features to simultaneously update the `x_grad`
>   and `grid_grad` arrays from multiple threadgroups. **See section 6.15 of the Metal Shading
>   Language Specification for more details.**

> ⚠️ **SILENT FAILURE — outputs are not zeroed for you.** `init_value` is optional and MLX documents
> for `precompiled_cuda_kernel` that *"By default, output arrays are uninitialized."*
> 🟡 The same is strongly implied for `metal_kernel` — `init_value` exists precisely so that you can
> *"update only part of the output arrays"* — but it is stated explicitly only for the CUDA variant.
> Either way, the failure mode is the same and it is nasty: if your kernel does not write every
> output element, the unwritten elements hold **whatever the recycled Metal buffer last contained**.
> A community regression note on a related MLX bug puts it perfectly: *"unwritten rows hold whatever
> the recycled `MTLBuffer` last contained, which is sometimes coincidentally plausible. A regression
> test should **poison the output buffer** (or compare two runs) rather than trust one lucky read."*
> **Safe default: pass `init_value` whenever your kernel does not provably write every element**, and
> test by running the same kernel twice on different inputs in the same process.

MLX's own VJP example is the canonical demonstration. ✅ VERIFIED verbatim — note `simd_sum` before
the atomic, `C_padded` to keep simdgroups from overlapping, and the `thread_index_in_simdgroup == 0`
guard:

```python
source = """
    uint elem = thread_position_in_grid.x;
    int H = x_shape[1];
    int W = x_shape[2];
    int C = x_shape[3];
    // Pad C to the nearest larger simdgroup size multiple
    int C_padded = ceildiv(C, threads_per_simdgroup) * threads_per_simdgroup;

    int gH = grid_shape[1];
    int gW = grid_shape[2];

    int w_stride = C;
    int h_stride = W * w_stride;
    int b_stride = H * h_stride;

    uint grid_idx = elem / C_padded * 2;
    float ix = ((grid[grid_idx] + 1) * W - 1) / 2;
    float iy = ((grid[grid_idx + 1] + 1) * H - 1) / 2;

    int ix_nw = floor(ix);
    int iy_nw = floor(iy);

    int ix_ne = ix_nw + 1;
    int iy_ne = iy_nw;

    int ix_sw = ix_nw;
    int iy_sw = iy_nw + 1;

    int ix_se = ix_nw + 1;
    int iy_se = iy_nw + 1;

    T nw = (ix_se - ix)    * (iy_se - iy);
    T ne = (ix    - ix_sw) * (iy_sw - iy);
    T sw = (ix_ne - ix)    * (iy    - iy_ne);
    T se = (ix    - ix_nw) * (iy    - iy_nw);

    int batch_idx = elem / C_padded / gH / gW * b_stride;
    int channel_idx = elem % C_padded;
    int base_idx = batch_idx + channel_idx;

    T gix = T(0);
    T giy = T(0);
    if (channel_idx < C) {
        int cot_index = elem / C_padded * C + channel_idx;
        T cot = cotangent[cot_index];
        if (iy_nw >= 0 && iy_nw <= H - 1 && ix_nw >= 0 && ix_nw <= W - 1) {
            int offset = base_idx + iy_nw * h_stride + ix_nw * w_stride;
            atomic_fetch_add_explicit(&x_grad[offset], nw * cot, memory_order_relaxed);

            T I_nw = x[offset];
            gix -= I_nw * (iy_se - iy) * cot;
            giy -= I_nw * (ix_se - ix) * cot;
        }
        if (iy_ne >= 0 && iy_ne <= H - 1 && ix_ne >= 0 && ix_ne <= W - 1) {
            int offset = base_idx + iy_ne * h_stride + ix_ne * w_stride;
            atomic_fetch_add_explicit(&x_grad[offset], ne * cot, memory_order_relaxed);

            T I_ne = x[offset];
            gix += I_ne * (iy_sw - iy) * cot;
            giy -= I_ne * (ix - ix_sw) * cot;
        }
        if (iy_sw >= 0 && iy_sw <= H - 1 && ix_sw >= 0 && ix_sw <= W - 1) {
            int offset = base_idx + iy_sw * h_stride + ix_sw * w_stride;
            atomic_fetch_add_explicit(&x_grad[offset], sw * cot, memory_order_relaxed);

            T I_sw = x[offset];
            gix -= I_sw * (iy - iy_ne) * cot;
            giy += I_sw * (ix_ne - ix) * cot;
        }
        if (iy_se >= 0 && iy_se <= H - 1 && ix_se >= 0 && ix_se <= W - 1) {
            int offset = base_idx + iy_se * h_stride + ix_se * w_stride;
            atomic_fetch_add_explicit(&x_grad[offset], se * cot, memory_order_relaxed);

            T I_se = x[offset];
            gix += I_se * (iy - iy_nw) * cot;
            giy += I_se * (ix - ix_nw) * cot;
        }
    }

    T gix_mult = W / 2;
    T giy_mult = H / 2;

    // Reduce across each simdgroup first.
    // This is much faster than relying purely on atomics.
    gix = simd_sum(gix);
    giy = simd_sum(giy);

    if (thread_index_in_simdgroup == 0) {
        atomic_fetch_add_explicit(&grid_grad[grid_idx], gix * gix_mult, memory_order_relaxed);
        atomic_fetch_add_explicit(&grid_grad[grid_idx + 1], giy * giy_mult, memory_order_relaxed);
    }
"""
kernel = mx.fast.metal_kernel(
    name="grid_sample_grad",
    input_names=["x", "grid", "cotangent"],
    output_names=["x_grad", "grid_grad"],
    source=source,
    atomic_outputs=True,
)

@grid_sample.vjp
def grid_sample_vjp(primals, cotangent, _):
    x, grid = primals
    B, _, _, C = x.shape
    _, gN, gM, D = grid.shape

    assert D == 2, "Last dim of `grid` must be size 2."

    # pad the output channels to simd group size
    # so that our `simd_sum`s don't overlap.
    simdgroup_size = 32
    C_padded = (C + simdgroup_size - 1) // simdgroup_size * simdgroup_size
    grid_size = B * gN * gM * C_padded
    outputs = kernel(
        inputs=[x, grid, cotangent],
        template=[("T", x.dtype)],
        output_shapes=[x.shape, grid.shape],
        output_dtypes=[x.dtype, x.dtype],
        grid=(grid_size, 1, 1),
        threadgroup=(256, 1, 1),
        init_value=0,
    )
    return outputs[0], outputs[1]
```

**MLX-project-published measurement**, same conditions as §8.2 (M1 Max, `x.shape=(8,1024,1024,64)`,
`grid.shape=(8,256,256,2)`, other details unstated):

> **`676.4ms -> 16.7ms => 40x speed up`**

The 40× on the backward versus 8× on the forward is not an accident, and the reason is stated in the
listing's own comment: **`simd_sum` first, atomics second.** Reducing within the simdgroup turns 32
atomic contentions into one. The docs say it outright — *"This is much faster than relying purely on
atomics."* If you write a scatter kernel and it is slow, this is the first thing to check.

Also note the interaction between `atomic_outputs=True` and `mx.custom_function` from §8.2: the
forward is registered with `@mx.custom_function` and the backward is attached with `@grid_sample.vjp`,
taking `(primals, cotangent, output)`. The whole thing then composes with `mx.grad`,
`mx.value_and_grad` and `mx.vmap` like any built-in op.

> ⚠️ **The `custom_function` purity rule applies.** Verbatim from `mx.custom_function`'s docstring:
> *"All `custom_function` instances behave as pure functions. Namely, any variables captured will be
> treated as constants and **no gradients will be computed with respect to the captured arrays**."*
> ✅ VERIFIED. If your kernel's weight tensor is captured from an enclosing scope rather than passed
> as an argument, `mx.grad` returns zero for it — silently.

### 9.5 Debugging: `verbose=True`, Metal logging, GPU capture

**Step 1 — read the generated source.** `verbose=True` on the call prints the complete generated
Metal function, signature and all. ✅ VERIFIED. Do this the first time you write any kernel; it
answers every "did MLX inject `x_strides`?" and "what did my template render as?" question instantly.

```python
outputs = kernel(inputs=[a], template=[("T", mx.float32)],
                 grid=(a.size, 1, 1), threadgroup=(256, 1, 1),
                 output_shapes=[a.shape], output_dtypes=[a.dtype],
                 verbose=True)
```

(The docs page contains a typo here, calling it `ast.metal_kernel.__call__()`; it means
`mx.fast.metal_kernel`.)

**Step 2 — log from inside the kernel.** MLX supports Metal shader logging, which **requires Metal
3.2 (macOS 15+ / iOS 18+)** and a debug build. ✅ VERIFIED, `docs/src/dev/metal_logging.rst`:

```bash
DEBUG=1 python -m pip install -e .
```

```cpp
#include "mlx/backend/metal/kernels/logging.h"
constant mlx::os_log logger("mlx", "my_kernel");
kernel void my_kernel(/* ... */) {
  logger.log_debug("unexpected state: idx=%u", idx);
}
```

```bash
MTL_LOG_LEVEL=MTLLogLevelDebug MTL_LOG_TO_STDERR=1 python script.py
```

🟡 That listing is the documented pattern for MLX's *own* `.metal` sources. Whether the same
`#include` works from a `mx.fast.metal_kernel` `header=` string is **UNVERIFIED** — see §11 for the
general form of that question.

**Step 3 — capture a GPU trace.** ✅ VERIFIED, `docs/src/dev/metal_debugger.rst`:

```bash
CMAKE_ARGS="-DMLX_METAL_DEBUG=ON" pip install -e .
MTL_CAPTURE_ENABLED=1 python my_script.py
```

```python
mx.metal.start_capture("mlx_trace.gputrace")   # the path must NOT already exist
for _ in range(10):
    mx.eval(mx.add(a, b))
mx.metal.stop_capture()
```

Or drive it from Xcode: `cmake .. -DMLX_METAL_DEBUG=ON -G Xcode && open mlx.xcodeproj`, then run the
`metal_capture` scheme.

**Step 4 — read the counters.** Apple's Metal debugger surfaces, per Tech Talk 111432: a **cost graph
view** inline with your Metal source, **runtime statistics** (register usage, divergence,
instruction-type breakdown) and **per-shader performance counters**. The instruction-mix breakdown is
the verification technique for §4: Apple's own example notes that in the `simdgroup_matrix` variant
*"the majority of our instruction types are math"* while in the TensorOps variant *"almost all of the
instructions are being executed by neural accelerators."* That is how you prove, rather than assume,
which hardware your kernel is running on.

---
