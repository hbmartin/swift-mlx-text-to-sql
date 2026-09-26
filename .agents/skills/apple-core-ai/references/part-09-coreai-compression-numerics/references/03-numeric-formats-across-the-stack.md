# int4 to MX: which layer supports which numeric format

**Part 9 · Core AI: compression and numeric formats · Reference 03**

**Version floor.** Four independent version stories collide in this guide and confusing them is the
single most common way to lose a week. **Core AI** — `AIModel`, `NDArray`, `NDArray.ScalarType`,
`AIModelAsset.Summary` — is **27.0 and only 27.0** (iOS 27.0 / iPadOS 27.0 / tvOS 27.0 /
visionOS 27.0 / watchOS 27.0, plus macOS 27.0 which Apple's own symbol pages omit; see §3.1).
**`coreai-opt`** is host-side Python, verified here against **0.2.1, released 2026-07-02**, requiring
Python ≥ 3.11 < 3.14 and torch ≥ 2.8.0 ≤ 2.11.0. **Metal Performance Primitives TensorOps** is a
**26.x** feature with a per-point-release ladder — **26.0** introduction, **26.1** bfloat, **26.3**
cooperative tensors as matmul inputs, **26.4** int4/int8 tensors — while the shipped Xcode 26.6 SDK
annotates the deployment macro as **26.2**; both facts are true and they are about different things
(§5.2). **MLX** tracks its own release cadence and gates its accelerated kernels on macOS/iOS
**26.2** plus a GPU generation check. There is no "26.4 Core AI" and no "iOS 20 / macOS 17."

⚠️ **Core AI has zero Apple sample-code projects.** Verified: 0 `sampleCode` entries across all 312
indexed Core AI symbols, and `/documentation/updates/coreai` 404s. Unlike Parts 1–6, there is no
first-party compiling Xcode project to check a signature against. Evidence in this guide is ranked:
shipped repo source and SDK headers on disk first, then Apple's own agent skills vendored in
`apple/coreai-models`, then Apple documentation, then WWDC/Tech Talk transcripts, then attributed
community measurement. Every claim carries its marker.

---

## What this covers

This is a reference, not a tutorial. It answers one question in as many tables as it takes:

> **For a given numeric format — int4, int8, FP8 E4M3, FP4 E2M1, MXFP4, a 6-bit palette, E8M0 block
> scales — which layer of Apple's 2026 stack can produce it, which layer can store it, and which
> layer can actually do arithmetic on it?**

The answer is that these are **three different sets**, and that is the whole guide:

| | Question | Owner | Answered in |
|---|---|---|---|
| **Emit** | What can my compression tool *produce*? | `coreai-opt`, `mlx_lm.convert` | §2, §6 |
| **Store** | What can the runtime *represent in memory and on disk*? | `NDArray.ScalarType`, the `.aimodel` asset | §3 |
| **Compute** | What can the hardware *multiply*? | ANE, GPU/MPP TensorOps | §4, §5 |

The emit set is the **largest**. `coreai-opt` will happily produce int2 weights with FP8 E5M2 LUT
scales. The store set is **also large but differently shaped** — `NDArray.ScalarType` exposes
`int2` through `int7` and `uint1` through `uint7`, widths no compression tool in the corpus emits.
The compute set is **much smaller**: the Neural Engine does fp16, int8 and int16, full stop; Metal
TensorOps does fp32/fp16/bfloat16 plus 4- and 8-bit integers with **no scale mechanism of any kind**.

And the consequence that makes this guide worth writing:

> ⚠️ **A mismatch between the three sets does not throw. It silently reassigns your model to a
> slower compute unit.** Core AI's specialization documentation says this in as many words:
> *"Fallback to other kinds in `allowedComputeUnitKinds` may still occur for operations or operation
> patterns that are incompatible with the preferred kind."* You get a working model with correct
> outputs, several times slower than the one you thought you built, and no diagnostic anywhere
> except the Xcode model viewer and Instruments.

What follows:

- **§1** — the thesis in one master matrix, plus the mental model to hang the rest on.
- **§2** — everything `coreai-opt` can emit: nine quantization dtypes, six palette widths, four LUT
  dtypes, three granularity families, and the E8M0 scale type that turns FP4 into MXFP4. Plus the
  CoreML export restriction matrix, which is a strictly smaller set and rejects at `finalize()`.
- **§3** — `NDArray.ScalarType`, the runtime's full type zoo, grouped and annotated, with the
  🔴 GAP that means sub-byte data is unreadable from Swift except through `RawView`.
- **§4** — the Neural Engine: three dtypes, rank ≤ 5, 64-byte last-axis alignment, and the reason a
  bare Python float literal in your model code can move an entire op to the GPU.
- **§5** — Metal / MPP TensorOps: the 26.x baseline, the Xcode 27 int2/FP4/FP8/E8M0 additions,
  auxiliary scale planes and automatic dequantization, plus the cooperative-tensor fallback for
  26.x and custom formats.[^xcode27-scale-planes]
- **§6** — MLX: the widest format menu in the stack (affine 2/3/4/5/6/8 bits × three group sizes,
  mxfp4, mxfp8, nvfp4), implemented by its current kernels with MLX-owned software structs, and the
  four gates that decide whether you get the fast kernel. This implementation choice does not erase
  the separate OS 27 Metal FP4/FP8 types.[^xcode27-scale-planes]
- **§7** — the crossings that silently degrade, as a lookup table: *you emitted X, the runtime stored
  Y, the hardware wanted Z → here is what actually happens.*
- **§8** — how to check what you actually got: the Xcode model viewer's compute-vs-storage precision
  split and operation distribution, the same data programmatically via `AIModelAsset.Summary`, the
  Instruments Core AI template for residency, and the Metal System Trace counter for M5.
- **§9–§12** — decision tables, consolidated silent failures, attributed numbers, quick reference.

## What this does *not* cover

- **How to choose a compression configuration.** That is
  [`01-quantization.md`](01-quantization.md) (configs, GRAPH vs EAGER, calibration, QAT) and the
  palettization guide in this part. This guide tells you which formats *exist* at each layer; those
  guides tell you which one to pick and how to measure the trade.
- **Conversion mechanics** — `torch.export`, `TorchConverter`, `optimize()`, `save_asset()`. Part 8.
- **Writing TensorOps kernels.** Part 11. §5 here is the dtype surface only.
- **MLX as a framework.** Parts 12 and 13. §6 here is the quantization surface only.
- **Debugging a numerics regression** — the Core AI Debugger, PSNR workflows, `save_intermediates`.
  Part 10. §8 here covers only *format inspection*, which is a different question from *accuracy*.

## What you need

- **Xcode 27** with the **Metal Toolchain** installed, if you intend to open an `.aimodel` in the
  model viewer. It is not installed by default and its absence is a build failure, not a warning:
  *"If the Metal toolchain isn't included, builds that include `.aimodel` files fail with a missing
  Metal compiler error."* Install via **Xcode > Settings > Components > Other Components**, or
  `xcodebuild -downloadComponent MetalToolchain`.
- **A real device** for any residency claim. The compute-unit assignment you get in the simulator is
  not the one you get on hardware, and Apple's Instruments article says plainly: *"Profile on a real
  device for the most accurate performance data."*
- **A measurement you trust before you change a format.** Every row of every table below is a trade.
  Apple's own compression-exploration agent skill refuses to proceed without a quality metric.

---

## Contents

1. [The three sets, and the master matrix](#1-the-three-sets-and-the-master-matrix)
2. [`coreai-opt`: the emit set](#2-coreai-opt-the-emit-set)
3. [`NDArray.ScalarType`: the store set](#3-ndarrayscalartype-the-store-set)
4. [The Neural Engine: the narrowest compute set](#4-the-neural-engine-the-narrowest-compute-set)
5. [Metal and MPP TensorOps: the GPU compute set](#5-metal-and-mpp-tensorops-the-gpu-compute-set)
6. [MLX: the widest menu, implemented in software](#6-mlx-the-widest-menu-implemented-in-software)
7. [The crossings that silently degrade](#7-the-crossings-that-silently-degrade)
8. [How to check what you actually got](#8-how-to-check-what-you-actually-got)
9. [Decision tables by target](#9-decision-tables-by-target)
10. [⚠️ Silent failures, consolidated](#10-️-silent-failures-consolidated)
11. [Numbers, attributed](#11-numbers-attributed)
12. [Quick reference](#12-quick-reference)
13. [Sources and evidence ledger](#13-sources-and-evidence-ledger)

---

## 1. The three sets, and the master matrix

### 1.1 Why a format has three separate lives

A quantized weight tensor passes through four distinct representations on its way to a matmul, and
each transition can drop information or silently change where the work runs:

```
   PyTorch nn.Module (fp32 weights)
        │
        │  coreai-opt: Quantizer / KMeansPalettizer
        │  ── EMIT ─────────────────────────────────────────────
        │  int8 int4 int2 uint8 uint4 uint2 fp8_e4m3 fp8_e5m2 fp4_e2m1
        │  palettes at 1/2/3/4/6/8 bits with int8/uint8/fp8 LUTs
        ▼
   ExportedProgram with coreai.quantize / coreai.dequantize / lut_to_dense
        │
        │  coreai-torch: TorchConverter → AIProgram → save_asset()
        ▼
   .aimodel  (a DIRECTORY, not a file)
        │
        │  Core AI runtime: AIModel(contentsOf:) → specialization
        │  ── STORE ────────────────────────────────────────────
        │  NDArray.ScalarType: float16 … float8e8m0fn … int2…int7, uint1…uint7
        ▼
   Specialized executable, partitioned across compute units
        │
        │  ── COMPUTE ──────────────────────────────────────────
        │  ANE: fp16, int8, int16 only
        │  GPU (MPP TensorOps): fp32/fp16/bfloat16 + int4/uint4/int8/uint8, no scales
        │  CPU: everything (which is why it is the fallback of last resort)
        ▼
   Numbers
```

The **emit** stage is a Python library making a choice about your weights. The **store** stage is
the runtime's ability to hold those bits in an `NDArray` and hand them to a kernel. The **compute**
stage is what the silicon can multiply without an intervening dequantization step.

Nothing enforces agreement between them. Core AI's specialization is *designed* to paper over the
gap by moving work to a compute unit that can handle it. That is a feature — it is why an
over-compressed model still returns correct numbers — and it is exactly what makes the failure
mode invisible.

> ✅ **VERIFIED** — `SpecializationOptions.preferredComputeUnitKind`, Apple documentation:
> *"When set, the specialization process maximizes use of this compute unit kind. **Fallback to
> other kinds in `allowedComputeUnitKinds` may still occur for operations or operation patterns that
> are incompatible with the preferred kind. Operation patterns refer to groups of operations that
> are fused or transformed together during specialization; an operation that is individually
> compatible with the preferred unit kind may be part of a fused pattern that is not.**"*
>
> Read the last sentence twice. An op that is *individually* ANE-legal can be dragged off the ANE
> because of a neighbour it got fused with. That is why "check the op list" is not sufficient and
> §8's residency check is mandatory.

And the CPU-only escape hatch, which tells you the shape of the problem from the other direction:

> ✅ **VERIFIED** — `SpecializationOptions.cpuOnly`, Apple documentation: *"The resulting specialized
> model only uses the CPU during inference. **Because all operations support the CPU, no fallback to
> other compute units occurs.**"*

### 1.2 The master matrix

Legend: **✅** supported · **—** not supported / not present · **SW** supported but implemented in
software above the hardware primitive · **⚠️** supported with a caveat named in the referenced
section. Metal entries marked 27 require the OS 27 tensor datatypes and auxiliary-plane API.
[^xcode27-scale-planes]

| Format | `coreai-opt` weights | `coreai-opt` activations | `coreai-opt` palette LUT | CoreML export backend | `NDArray.ScalarType` | ANE compute | MPP TensorOps operand | MLX quantize |
|---|---|---|---|---|---|---|---|---|
| **fp32** | n/a (source) | n/a | — | n/a | `float32` ✅ | **—** (§4.1) | `float` ✅ ⚠️ TF32 | ✅ (unquantized) |
| **fp16** | n/a (cast, §2.6) | n/a | — | n/a | `float16` ✅ | ✅ | `half` ✅ | ✅ (unquantized) |
| **bfloat16** | n/a (cast) | n/a | — | n/a | `bfloat16` ✅ | 🔴 GAP (§4.1) | `bfloat` ✅ (26.1) | ✅ (unquantized) |
| **int16** | — | — | — | — | `int16` ✅ | ✅ | in enum, ⚠️ §5.1 | — |
| **int8** | ✅ | ✅ | ✅ | ✅ | `int8` ✅ | ✅ | `int8_t` ✅ (26.4) | ✅ affine 8-bit |
| **uint8** | ✅ | ✅ | ✅ | ✅ (act: ✅) | `uint8` ✅ | ⚠️ §4.1 | `uint8_t` ✅ (26.4) | ✅ (packed container) |
| **int4** | ✅ | ✅ | — | ✅ (weights only) | `int4` ✅ | **—** | `int4b_format` ✅ ⚠️ §5.3 | ✅ affine 4-bit |
| **uint4** | ✅ | ✅ | — | ✅ (weights only) | `uint4` ✅ | **—** | `uint4b_format` ✅ ⚠️ §5.3 | ✅ |
| **int2 / uint2** | ✅ | ✅ | — | **—** | `int2` / `uint2` ✅ | **—** | `metal::int2b_format` / `uint2b_format` ✅ (27) | ✅ affine 2-bit (SW) |
| **int3, int5, int6, int7** | — | — | — | — | ✅ all present | **—** | **—** | ✅ 3/5/6-bit affine (SW) |
| **uint1, uint3, uint5, uint6, uint7** | — | — | — | — | ✅ all present | **—** | **—** | — |
| **FP8 E4M3** | ✅ | ✅ | ✅ | **—** | `float8e4m3fn` ✅ | **—** | `metal::metal_fp8_e4m3_format` ✅ (27) | SW (`fp8_e4m3`, §6.4) |
| **FP8 E5M2** | ✅ | ✅ | ✅ | **—** | `float8e5m2` ✅ | **—** | `metal::metal_fp8_e5m2_format` ✅ (27) | — |
| **FP8 E8M0** (scales) | scale only (§2.3) | — | — | **—** | `float8e8m0fn` ✅ | **—** | `metal::metal_fp8_ue8m0_format` + scale plane ✅ (27) | SW (`fp8_e8m0`, §6.4) |
| **FP4 E2M1** | ✅ (`float4_e2m1fn_x2`) | ✅ | — | **—** | `float4e2m1fn` ✅ | **—** | `metal::metal_fp4_e2m1_format` ✅ (27) | SW (`fp4_e2m1`, §6.4) |
| **MXFP4** (fp4 + E8M0/32) | ✅ ⚠️ §2.3 | — | — | **—** | via the two above | **—** | data + E8M0 scale plane ✅ (27) | ✅ `mxfp4` (SW) |
| **MXFP8** (fp8 + E8M0/32) | 🟡 §2.3 | — | — | **—** | via the two above | **—** | data + E8M0 scale plane ✅ (27) | ✅ `mxfp8` (SW) |
| **NVFP4** (fp4 + E4M3/16) | **—** | — | — | **—** | via the two above | **—** | **—** | ✅ `nvfp4` (SW) |
| **k-means palette 1/2/3/4/6/8 bit** | ✅ (eager only) | n/a | see LUT rows | ⚠️ §2.5 | indices as sub-byte ints | via LUT dtype | **—** | — |
| **complex 16/32/64** | — | — | — | — | `cfloat16/32/64` ✅ | **—** | **—** | ⚠️ excluded from NAX |
| **int64 / uint64 / int128 / uint128** | — | — | — | — | ✅ all present | **—** | `int32`/`uint32` max | — |
| **bool** | — | — | — | — | `bool` ✅ | — | — | — |

Read that table column by column and the thesis falls out on its own. The `coreai-opt` column and
the `NDArray.ScalarType` column overlap but neither contains the other. The ANE column has **three
ticks**. The TensorOps column has **nine**, none of which carries a scale. And the MLX column is
almost entirely marked **SW** — because MLX, written by Apple against the same headers for the same
hardware, declined to use the 4-bit tensor operands at all and dequantizes in a shader instead.

### 1.3 The one-sentence rule for each layer

- **`coreai-opt`** will emit almost anything you ask for, and will *silently skip* a layer whose
  shape does not divide by your block size. §2.7.
- **The `.aimodel` asset** can store far more format variety than any accelerator can consume, which
  is a deliberate design choice — the asset is portable and the specialization is per-device.
- **The ANE** is the reason to care: it is dramatically the most efficient unit for the models it
  accepts, and its acceptance criteria are narrow, structural and undiagnosed at runtime.
- **The GPU** accepts nearly anything but reaches peak throughput only through TensorOps, which
  itself accepts only dense operands — every block-scaled format on Apple silicon in 2026 is a
  software construct sitting on top of a dense matmul.
- **MLX** gives you the widest format menu and the clearest error messages, because everything is
  checked at the Python boundary rather than at specialization time.

---

## 2. `coreai-opt`: the emit set

### 2.1 What Apple said on stage, and what the source actually supports

> ✅ **VERIFIED** — WWDC26 session 325, *"Dive into Core AI model authoring and optimization"*,
> 325:64–68: *"`coreai-opt` … supports **int4, int8, FP4 and FP8** weight compression with
> **flexible granularity**."*

That is four formats. The shipped source supports **nine**, and the two the transcript omits —
`int2` and `uint2` — are exactly the two the CoreML export backend rejects, which is probably why
they were left off the slide. Take the source, not the slide.

> ✅ **VERIFIED** — `apple/coreai-optimization`, `src/coreai_opt/quantization/spec/spec.py:376-390`,
> `QuantizationSpec.SUPPORTED_DTYPES`:
> ```python
> torch.int8,  torch.int4,  torch.int2,
> torch.uint8, torch.uint4, torch.uint2,
> torch.float8_e4m3fn, torch.float8_e5m2,
> torch.float4_e2m1fn_x2
> ```

Three string aliases exist, and one of them names a type that is **not** in `SUPPORTED_DTYPES` —
E8M0 is a *scale* type, not a *value* type, which is the first place the emit/store/compute
distinction shows up inside a single library:

> ✅ **VERIFIED** — `spec.py:394-398`:
> ```
> "float4_e2m1fn" → torch.float4_e2m1fn_x2
> "float8_e4m3"   → torch.float8_e4m3fn
> "float8_e8m0"   → torch.float8_e8m0fnu
> ```
> Any other string resolves via `getattr(torch, name)`.

### 2.2 Physical storage: sub-byte types live in a wider container

`coreai-opt` distinguishes the **logical** dtype (what the numbers mean) from the **target** dtype
(what bytes hold them). This matters when you go looking for your int4 weights in the asset and find
bytes.

> ✅ **VERIFIED** — `get_target_dtype`, `spec.py:606-635`: sub-byte integers map to `int8` / `uint8`;
> `float4_e2m1fn_x2` maps to `float8_e4m3fn`, with the stated reason *"All FP4 representable values
> are exactly representable in FP8."*

And on the converter side, sub-byte tensors travel as packed bytes plus a logical-dtype attribute:

> ✅ **VERIFIED** — `apple/coreai-torch`, `coreai_torch/converter.py` constant emission: *"Sub-byte
> tensor subclasses store bit-packed bytes in `.elem` (uint8) and the logical dtype in
> `future_dtype`."* And in `get_tensor_type`, the last dimension is **doubled** when
> `future_dtype == torch.float4_e2m1fn_x2` and the physical dtype is `uint8` — i.e. two FP4 values
> per byte, and the type system knows it.

The practical consequence: **a shape you read out of a converted program may not be the shape you
wrote**, if the tensor is FP4. Check `future_dtype` before you trust a last dimension.

### 2.3 Quantization ranges and the E8M0 scale rule — where MXFP4 comes from

The quantization range table is published in the class docstring and is worth keeping open:

> ✅ **VERIFIED** — `spec.py:653-662`:
> ```
> int8 symmetric            -> (-128, 127)
> int8 symmetric_with_clip  -> (-127, 127)
> int4 symmetric            -> (-8, 7)
> int4 symmetric_with_clip  -> (-7, 7)
> uint8                     -> (0, 255)
> uint8 symmetric_with_clip -> (0, 255)      # same as symmetric
> float4_e2m1fn_x2          -> (-6.0, 6.0)   # torch.finfo not implemented; hardcoded
> float8_e4m3fn             -> (-448.0, 448.0)
> float8_e5m2               -> (-57344.0, 57344.0)
> ```

`scale_dtype` is the field that turns a plain FP4 tensor into an OCP-microscaling one, and its rules
are unusually strict:

> ✅ **VERIFIED** — `QuantizationSpec` validators, `spec.py:486-500`:
> - `scale_dtype` may only be `None` or `torch.float8_e8m0fnu`.
> - `scale_dtype` **must** be `None` for integer dtypes.
> - **FP4 auto-resolves `scale_dtype=None` → `torch.float8_e8m0fnu`** in a `mode="before"` model
>   validator (`resolve_scale_dtype`).
>
> Scale formulas: with `scale_dtype=None` (FP8 only), `scale = max_abs / fp_max` (448.0 for E4M3,
> 57344.0 for E5M2). With `scale_dtype=float8_e8m0fnu` (available for FP4 and FP8), the scale is a
> **power of two per the OCP MX spec**: `scale = 2^(floor(log2(max_abs)) - target_max_pow2)`, with
> `target_max_pow2` = **2** for FP4 E2M1, **8** for FP8 E4M3, **15** for FP8 E5M2.

So: **FP4 in `coreai-opt` is always block-scaled with E8M0**, whether you asked for it or not. There
is no unscaled FP4 path. The MLIR-level API is even more explicit about it:

> ✅ **VERIFIED** — `coreai_opt/coreai_utils/passes/weight_quantization.py`, `quantize_weights`
> raises `ValueError` for **FP4 with granularity != `PER_BLOCK` or `block_size != 32`**, with the
> message *"FP4 weights must use per-block quantization with a block size of 32 to produce a valid
> MXFP4 encoding."*

That single validator is the clearest statement in the whole corpus that `coreai-opt` **emits
MXFP4** as a first-class format.

> 🟡 **RECONSTRUCTED — MXFP8.** FP8 E4M3 with `scale_dtype=torch.float8_e8m0fnu` and a block size of
> 32 is *structurally* MXFP8 — the validator permits E8M0 scales for FP8, and `target_max_pow2 = 8`
> is the FP8 E4M3 entry in the same power-of-two table. But **no validator in the source names
> "MXFP8"**, and there is no equivalent to the FP4 block-size-32 enforcement. Treat "coreai-opt can
> emit MXFP8" as an inference from the scale-type rules, not as a documented capability. If you need
> it, verify the emitted `coreai.blockwise_shift_scale` operands before shipping.
>
> **Safe default meanwhile:** if you want block-scaled FP8, use `granularity=PerBlockGranularity(
> axis=1, block_size=32)` and `scale_dtype=torch.float8_e8m0fnu` explicitly rather than relying on
> a default, and diff the resulting asset's storage types (§8.2) against an int8 build.

**NVFP4 — the FP4-with-E4M3-scales-at-block-16 format — is not emittable by `coreai-opt` at all**,
because `scale_dtype` admits only `None` and `float8_e8m0fnu`. It exists only in MLX (§6.2).

### 2.4 Granularity: the second axis of the emit set

A format is a dtype *and* a granularity, and the granularity determines both the compression ratio
and whether a layer gets compressed at all.

> ✅ **VERIFIED** — `coreai_opt/quantization/spec/granularity.py`, registry keys `"per_tensor"`,
> `"per_channel"`, `"per_block"`:
> ```python
> PerTensorGranularity()                              # axis: Literal[None] = None
> PerChannelGranularity(axis: int | None = None)      # negative axes allowed
> PerBlockGranularity(axis: int | None, block_size: int | tuple[int | -1, ...])
> ```
> `PerBlockGranularity.axis` is constrained to `ge=0, le=1` in single-axis mode. In multi-axis mode
> `axis` must be `None` and `block_size` is a tuple with one entry per tensor dim, where `-1` means
> "no blocking on this axis."

The docstring's own block-shape table, which answers most "what does axis mean here" questions:

> ✅ **VERIFIED** — `granularity.py` docstring:
>
> | weight shape | axis | block_size | resulting block shape |
> |---|---|---|---|
> | `[C_out, C_in]` | 1 | 32 | `[1, 32]` |
> | `[C_out, C_in]` | None | `(4, 8)` | `[4, 8]` |
> | `[C_out, C_in, KH, KW]` | 0 | 16 | `[16, 1, KH, KW]` |
> | `[C_out, C_in, KH, KW]` | None | `(4, 16, 3, -1)` | `[4, 16, 3, KW]` |

Two rules that catch people:

- **Activations get no axis defaults at all.** `validate_activation_axes()` raises:
  *"Activation fake-quantize modules with unresolved axis=None: … Activation quantization does not
  support axis=None. Provide an explicit axis value…"* ✅ VERIFIED, `_axis_defaults.py`.
- **Weights do get defaults, per module type**, and the per-channel and per-block defaults are
  *different axes*: ✅ VERIFIED, `_axis_defaults.py` `_WEIGHT_AXIS_SPECS` — `nn.Linear` is
  `(per_channel_axis=0, per_block_axis=1)`; `nn.ConvTranspose*d` inverts that to `(1, 0)`.

### 2.5 Palettization: a different vocabulary for a different mechanism

Palettization is not quantization with a small dtype. It is a codebook: `n_bits` selects the number
of centroids, and the stored per-weight value is an **index**, not a number.

> ✅ **VERIFIED** — `coreai_opt/palettization/spec/spec.py:86-93`:
> ```python
> n_bits: Literal[1, 2, 3, 4, 6, 8] = 4
> lut_qspec: QuantizationSpec | None = None
> granularity: PalettizationGranularity = PerTensorGranularity()
> cluster_dim: PositiveInt = 1
> enable_per_channel_scale: bool = False
> ```
> `_SUPPORTED_LUT_DTYPES = {torch.int8, torch.uint8, torch.float8_e4m3fn, torch.float8_e5m2}`.
> Granularity registry keys are `"per_tensor"` and `"per_grouped_channel"` — **there is no
> `per_channel` and no `per_block` in palettization.** `PerGroupedChannelGranularity` takes
> `axis: int | None` constrained to `ge=0, le=1` plus a `group_size: int`.

Note the widths: **1, 2, 3, 4, 6, 8** — no 5 and no 7. Compare with `NDArray.ScalarType`, which has
`int5` and `int7` cases (§3.1), and with MLX affine, which supports 5 and 6 but excludes 7 (§6.1).
Three layers, three different sub-byte width sets, none a superset of the others.

The LUT shape contract, which is the thing to reason about when a palettized model won't run on the
ANE (§4.4):

> ✅ **VERIFIED** — `palettization/spec/fake_palettize.py:139-151`:
> ```
> [NUM_LUT_AXIS_0, NUM_LUT_AXIS_1, NUM_PALETTES, VECTOR_SIZE]
> NUM_PALETTES == 2**n_bits ; VECTOR_SIZE == cluster_dim   (1 ⇒ scalar palettization)
> ```

**Vector palettization** divides the effective bit width by `cluster_dim`:

> ✅ **VERIFIED** — `docs/src/palettization/basics.md:16`: `n_bits=4, cluster_dim=2` runs k-means on
> 2-D data with 16 centroids, LUT `16×2`, giving **effective bpw = 4/2 = 2**.

And the op chain that finalize produces — worth knowing because it is what you will see in the model
viewer's operation distribution (§8.1):

> ✅ **VERIFIED** — `palettization/kmeans/_prepare_for_export.py:225-233`:
> 1. Palettization only → `lut_to_dense`
> 2. Quantized LUT → `lut_to_dense(int LUT)` + `constexpr_blockwise_shift_scale(lut_scale)`
> 3. Per-channel scale → `lut_to_dense` + `constexpr_blockwise_shift_scale(pcs)`
> 4. Both → `lut_to_dense(int LUT)` + `constexpr_blockwise_shift_scale(fused_scale)`, where
>    `fused_scale = lut_scale * per_channel_scale`

The reason to quantize the LUT is a pure format-matching argument, and Apple states it outright:

> ✅ **VERIFIED** — `docs/src/utils/joint_compression.md`: *"A floating-point LUT causes operations
> to execute in floating-point regardless of the activation quantization, whereas an `INT8` LUT
> allows the runtime to use the faster W_INT8-A_INT8 execution path where available."*

That is the thesis of this guide restated inside Apple's own documentation: the *storage* format of
a lookup table decides the *compute* format of the operation that consumes it.

### 2.6 The MLIR-level emit set is not the same as the PyTorch-level one

`coreai_opt.coreai_utils` compresses an **already-converted** `AIProgram` rather than an
`nn.Module`. It has its own dtype enum, and it is not identical to `SUPPORTED_DTYPES`:

> ✅ **VERIFIED** — `coreai_opt/coreai_utils/common.py`:
> ```python
> class DType(_StrEnum):
>     INT2, UINT2, INT4, UINT4, INT8, UINT8,
>     FP4_E2M1FN, FP8_E4M3FN, FP8_E5M2, FP8_E8M0FNU
> class QScheme(_StrEnum): SYMMETRIC, ASYMMETRIC
> class CompressionGranularity(_StrEnum):
>     PER_TENSOR, PER_CHANNEL, PER_BLOCK, PER_GROUPED_CHANNEL
> ```
> `quantize_weights` accepts `_VALID_WEIGHT_DTYPES = {FP4_E2M1FN, FP8_E4M3FN, FP8_E5M2, INT2, INT4,
> INT8, UINT2, UINT4, UINT8}`; `palettize_weights` accepts
> `_VALID_LUT_DTYPES = {INT8, UINT8, FP8_E4M3FN, FP8_E5M2}` with `_VALID_N_BITS = {1,2,3,4,6,8}`.

Three differences from the PyTorch-level API worth internalising:

1. **`FP8_E8M0FNU` is a `DType` case here**, usable as `scale_dtype` — the enum does not separate
   value types from scale types the way `SUPPORTED_DTYPES` does.
2. **`CompressionGranularity` merges both vocabularies** — `PER_BLOCK` (quantization) and
   `PER_GROUPED_CHANNEL` (palettization) are cases of one enum, even though the PyTorch-level APIs
   keep them in separate registries.
3. **Only constants feeding five ops are candidates.** ✅ VERIFIED,
   `coreai_utils/passes/__init__.py`:
   ```python
   _OPS_WEIGHT_NEED_COMPRESSION = frozenset({
       "coreai.batch_matmul", "coreai.conv2d",
       "coreai.decomposable.broadcasting_batch_matmul",
       "coreai.gather_nd", "coreai.transpose",
   })
   ```
   Plus a `weight_num_threshold` (default **1024**) below which a constant is left alone. A small
   tensor is not compressed and no message says so.

Apple's own docs mark this as the non-preferred path — use it when you have an `.aimodel` and no
PyTorch model, not as a default.

### 2.7 ⚠️ SILENT FAILURE — a block size your weight doesn't divide by leaves the layer at full precision

This is the highest-frequency silent failure in the whole compression stage, and it is worth
repeating in every guide that touches `coreai-opt`.

> ⚠️ **SILENT FAILURE.** ✅ VERIFIED — `coreai_opt` fake-quantize forward: when a tensor's shape is
> not divisible by the configured `block_size`, the module **logs a warning and permanently disables
> itself**:
> ```
> logger.warning("Tensor (target: %s) incompatible with block size configuration: %s. Skipping quantization.", ...)
> ```
> Graph mode then calls `_remove_disabled_fake_quant_nodes(prepared_model)` after the init forward
> pass (`_graph/quantizer.py:1004-1006, 1307-1317`). Palettization has the analogous
> `_remove_disabled_fake_palett_modules`.
>
> **Net effect: a mis-sized block config silently leaves layers uncompressed.** `finalize()`
> succeeds. The asset saves. The model is correct. It is simply bigger and slower than you believe,
> and the layers that got skipped are typically the *interesting* ones — the ones with unusual
> shapes, which are often the head or the embedding.

The same mechanism applies to palettization's `PerGroupedChannelGranularity`: an
`_IncompatibleGranularityError` is caught in `_FakePalettizeImplBase.forward`, producing a warning,
a permanently disabled module, and a removed parametrization.

Apple's own compression-exploration agent skill names this explicitly as a pitfall and prescribes
the countermeasure:

> ✅ **VERIFIED** — `apple/coreai-models`, `skills/model-compression-exploration`: *"per-block /
> per-grouped-channel **silently skip** layers whose weight dim isn't divisible (pre-check with
> `check_divisibility()`)."* The skill ships `scripts/compression_metrics.py` containing theoretical
> size, average bitwidth, divisibility and parametrize-walk helpers.

**Two checks that catch it:**

```python
# 1. Before compressing: does every target weight divide by the block size?
#    (Apple's skill ships check_divisibility(); this is the same test written out.)
import torch.nn as nn

def report_divisibility(model: nn.Module, block_size: int, axis: int = 1) -> None:
    for name, module in model.named_modules():
        weight = getattr(module, "weight", None)
        if weight is None or weight.ndim <= axis:
            continue
        dim = weight.shape[axis]
        status = "ok" if dim % block_size == 0 else "WILL BE SKIPPED"
        if status != "ok":
            print(f"{name:60s} dim[{axis}]={dim:6d} % {block_size} = {dim % block_size}  {status}")

report_divisibility(float_model, block_size=32, axis=1)
```

```python
# 2. After compressing: did the size actually move?
#    avg_bitwidth = sum(numel_i * bits_i) / sum(numel_i)
#    If it lands suspiciously close to 16, layers were skipped.
```

The size formula to compute that by hand is community-published and matches the source's behaviour:

> 🟠 **COMMUNITY-PUBLISHED** — `john-rocky/coreai-model-zoo`,
> `knowledge/compression-reference.md` (single-author community material with self-declared
> uncontrolled benchmarks; use the *formula*, which is arithmetic, not a measurement):
> ```
> weight/index bytes = numel * n_bits/8
> scale bytes        = n_groups * 2                 # fp16
> zero_point bytes   = n_groups * n_bits/8          # asymmetric only
> lut bytes          = 2^n_bits * n_luts * 2        # palettization
> avg_bitwidth       = Σ(numel_i * bits_i) / Σ numel_i
> ```
> The overhead this exposes is real and easy to underestimate: the same source reports scale and
> zero-point overhead running **5–15% at 2–4 bit fine granularity**, and notes that at
> `block_size=16` with int4 the *effective* width is about **5 bits**, not 4.

### 2.8 The CoreML export backend is a strictly smaller set — and it rejects at `finalize()`

If you target `ExportBackend.CoreML` instead of `ExportBackend.CoreAI`, four of the nine dtypes and
most of the interesting granularities disappear.

> ✅ **VERIFIED** — `src/coreai_opt/_utils/export_utils.py:17-47`:
> ```python
> COREML_SUPPORTED_WEIGHT_DTYPES     = {torch.int8, torch.uint8, torch.int4, torch.uint4}
> COREML_SUPPORTED_ACTIVATION_DTYPES = {torch.int8, torch.uint8}
> COREML_SUPPORTED_LUT_DTYPES        = {torch.int8, torch.uint8}
> COREML_SUPPORTED_ACTIVATION_GRANULARITIES = {PerTensorGranularity}
> ```

Consolidated, the CoreML backend has **no FP4, no FP8 anywhere, no int2/uint2 weights, no
per-channel or per-block activation quantization, and no `MINVAL` formulation**:

> ✅ **VERIFIED** — `spec.py:174-179`, verbatim: *"CoreML export only supports `ZP`. Specs with
> `qformulation=MINVAL` are rejected during finalize with CoreML Export-backend. **CoreAI export
> supports both `ZP` and `MINVAL`.**"*

Palettization has an extra combinatorial rule on CoreML:

> ✅ **VERIFIED** — `validate_coreml_palettization_compatibility`: **at most one of**
> `{cluster_dim > 1, lut_qspec, enable_per_channel_scale}`. Combining two raises
> `CoreMLExportError("CoreML export does not support cluster_dim + lut_qspec on <ctx>. Use
> backend=ExportBackend.CoreAI instead.")`, because the combination *"hits an unsupported CoreML/MIL
> op configuration (mismatched tensor ranks, or `lut_to_dense` divisibility errors)."*

**This one is loud, and that is the good news.** Unlike the divisibility skip, a CoreML-incompatible
spec raises during `finalize()`. If you are on the CoreAI backend you never see these errors — which
means a config developed against CoreAI will not necessarily port back.

One more CoreAI-only restriction, for completeness: **joint compression** (palettize weights, then
quantize activations on the palettized model) *"can currently only be finalized to the `Core AI`
backend."* ✅ VERIFIED, `docs/src/utils/joint_compression.md`.

### 2.9 Casting is not compression, and the order matters

`coreai_opt.casting` is the fp16/int16 helper. It changes the *container*, not the *encoding*, and
it runs on the `ExportedProgram` rather than the `nn.Module`.

> ✅ **VERIFIED** — `src/coreai_opt/casting/__init__.py`:
> ```python
> from coreai_opt.casting import (
>     cast_to_16_bit_precision,   # FP32→FP16 and INT32/INT64→INT16
>     cast_fp32_to_fp16,          # FP32→FP16 only
>     cast_int32_to_int16,        # INT32/INT64→INT16 only
> )
> ```
> All three mutate an `ExportedProgram` **in place**.

The two passes have deliberately different aggressiveness, and knowing which is which explains a lot
of "why is this op still fp32" confusion:

> ✅ **VERIFIED** — `docs/src/utils/casting.md:28-38`:
> - **FP pass is aggressive**: casts all float state and ops **except** tensors whose values exceed
>   the FP16 range (≈ ±65504).
> - **INT pass is conservative**: skips tensors that are constant-foldable, that feed an indexing op
>   (overflow risk), or that are not consumed by a computationally intensive op.

> ✅ **VERIFIED** — `docs/src/introduction/integration_coreai.md`, the ordering rule stated outright:
> **compress first, cast second.** *"Any quantized int8 buffers are left untouched; any remaining
> FP32 weights move to FP16."*

⚠️ And the wrinkle that bites callers rather than the model: *"These passes mutate the
`ExportedProgram` in place and may change the dtypes of user inputs and outputs. Calling code may
need to be updated so that input tensors are passed as `fp16`/`int16`."* ✅ VERIFIED, same file. If
your Swift `NDArray(shape:scalarType:)` still says `.float32` after you added a cast pass, you have
a shape-and-type mismatch waiting at `run()`.

### 2.10 The complete `coreai-opt` emit set, on one card

| Axis | Values | Where verified |
|---|---|---|
| Quantization dtype | `int8` `int4` `int2` `uint8` `uint4` `uint2` `float8_e4m3fn` `float8_e5m2` `float4_e2m1fn_x2` | `spec.py:376-390` |
| Scale dtype | `None` or `float8_e8m0fnu` (FP4 auto-resolves to E8M0) | `spec.py:486-500` |
| Quantization scheme | `symmetric` · `asymmetric` · `symmetric_with_clipping` (FP dtypes: symmetric only) | `spec/qscheme.py` |
| Quantization formulation | `ZP` · `MINVAL` (FP dtypes and CoreML: `ZP` only) | `spec/qformulation.py` |
| Quantization granularity | per-tensor · per-channel · per-block (single- or multi-axis) | `spec/granularity.py` |
| Palette width | 1, 2, 3, 4, 6, 8 bits — **no 5, no 7** | `palettization/spec/spec.py:86-93` |
| Palette LUT dtype | `int8` `uint8` `float8_e4m3fn` `float8_e5m2` | same |
| Palette granularity | per-tensor · per-grouped-channel — **no per-block** | same |
| Palette vector width | `cluster_dim ≥ 1`; effective bpw = `n_bits / cluster_dim` | `docs/palettization/basics.md:16` |
| Cast targets | fp32→fp16, int32/int64→int16 | `casting/__init__.py` |
| MLIR-level dtype | adds `FP8_E8M0FNU` as a first-class case | `coreai_utils/common.py` |

---

## 3. `NDArray.ScalarType`: the store set

### 3.1 The full enum, grouped

`NDArray.ScalarType` is the runtime's answer to "what kind of number is this." It is the type that
`NDArray(shape:scalarType:)` takes, that `NDArrayDescriptor` reports, and that `RawView` carries.

> ✅ **VERIFIED** — Apple documentation, `/documentation/coreai/ndarray/scalartype`.
> `enum ScalarType` conforming to `CaseIterable, Equatable, Hashable, Sendable, SendableMetatype`.
> Availability **iOS 27.0 / iPadOS 27.0 / tvOS 27.0 / visionOS 27.0 / watchOS 27.0**.

| Group | Cases | Apple's own wording |
|---|---|---|
| Floating-point | `float16` `float32` `float64` `bfloat16` | "A 16-bit brain floating-point type." |
| 8-bit float | `float8e4m3fn` `float8e5m2` | "An 8-bit floating-point type with 4 exponent bits and 3 mantissa bits, **without a sign bit**." / "…5 exponent bits and 2 mantissa bits." |
| MX element / scale | `float4e2m1fn` `float8e8m0fn` | "A 4-bit floating-point type with 2 exponent bits and 1 mantissa bit." / "An 8-bit floating-point type with 8 exponent bits and 0 mantissa bits, without a sign bit." |
| Complex | `cfloat16` `cfloat32` `cfloat64` | "A 16/32/64-bit complex floating-point type." |
| Signed integer | `int8` `int16` `int32` `int64` `int128` | |
| Unsigned integer | `uint8` `uint16` `uint32` `uint64` `uint128` | |
| Sub-byte signed | `int2` `int3` `int4` `int5` `int6` `int7` | `int4`: "Four-bit signed integers can represent values in the range **[-8, 7]**. Widely used in model quantization for efficient storage and computation." |
| Sub-byte unsigned | `uint1` `uint2` `uint3` `uint4` `uint5` `uint6` `uint7` | |
| Boolean | `bool` | "A Boolean scalar." |

The groups above enumerate **35 cases**, which matches the Xcode 27 SDK surface. Treat the stale
“33 cases” harvest label as a capture error, not an unresolved API question.[^scalar-type-count]

Four structural observations that matter more than the count:

1. **There is no `int1` — only `uint1`.** And no `uint0`. The asymmetry is real in the doc listing.
2. **Odd widths exist**: `int3`, `int5`, `int6`, `int7`, `uint3`, `uint5`, `uint6`, `uint7`. Nothing
   in `coreai-opt` emits any of them (§2.10). Nothing in MPP TensorOps consumes any of them (§5.1).
   MLX emits 3-, 5- and 6-bit *affine* weights (§6.1) but MLX does not produce `.aimodel` assets.
   **This is the clearest single piece of evidence for the emit ≠ store thesis**: the runtime's type
   system anticipates encodings no shipping tool in Apple's own stack produces.
3. **`float4e2m1fn` and `float8e8m0fn` are both present**, which is the MX pair — the element type
   and the block-scale type. Their presence is the runtime-side confirmation of §2.3: Core AI is
   built to store MXFP4-class data natively.
4. **`int128` / `uint128` exist**, which nothing else in this guide touches.

> ⚠️ **Availability quirk, verified and surprising.** The Core AI *framework* page lists seven
> platforms including macOS and Mac Catalyst, but **every individual symbol page's
> `metadata.platforms` array omits macOS and Mac Catalyst**:
> ```
> coreai          → iOS, iPadOS, Mac Catalyst, macOS, tvOS, visionOS, watchOS  (all 27.0 beta)
> coreai/ndarray  → iOS, iPadOS, tvOS, visionOS, watchOS                       (no macOS)
> ```
> This is almost certainly a docs-generation bug — Core AI Debugger requires macOS 27 hosts, the
> Instruments template runs on macOS, `coreai-build` runs on macOS. **Treat macOS 27 as supported
> and flag it as a doc inconsistency.** ✅ VERIFIED against the raw DocC JSON.
>
> A **real** narrowing, by contrast: the Metal-backed initializers drop watchOS —
> `NDArray.RawView.init(metalBuffer:…)`, `InferenceFunction.AsyncValue.init(unsafeBuffer:…)` and
> `ComputeStream.init(commandQueue:)` are declared for iOS / iPadOS / Mac Catalyst / tvOS / visionOS
> only, while `ComputeStream.init()` includes watchOS.

### 3.2 🔴 GAP — you cannot read sub-byte data from Swift except as raw bytes

This is the most consequential unresolved question in the store layer, and it is a genuine gap
rather than an unfound answer.

Every typed accessor on `NDArray` is constrained to `BitwiseCopyable`:

> ✅ **VERIFIED** — Apple documentation, `NDArray`:
> ```swift
> func view<T>(as type: T.Type = T.self) -> NDArray.View<T> where T : BitwiseCopyable
> mutating func mutableView<T>(as type: T.Type = T.self) -> NDArray.MutableView<T> where T : BitwiseCopyable
> func rawView() -> NDArray.RawView
> mutating func mutableRawView() -> NDArray.MutableRawView
> init<Scalar>(scalars: some Sequence, shape: [Int]) where Scalar : BitwiseCopyable
> ```
> The parameter documentation for `view(as:)` is explicit about the contract: *"The Swift type that
> corresponds to this array's `scalarType`. For example, pass `Int32.self` for an array with scalar
> type `.int32`."* And `RawView.view(as:)` carries the note *"`T` must match `self.scalarType.type`."*

> 🔴 **GAP — there is no Swift type to pass for `.int4`, `.uint1`, `.int3`, `.float8e4m3fn`,
> `.float4e2m1fn` or `.float8e8m0fn`.**
>
> **What is unknown:** whether Core AI vends its own `BitwiseCopyable` types for the sub-byte and
> 8-bit-float scalar types (an `Int4`, a `Float8E4M3FN`, or similar), or whether these scalar types
> are storage-and-transport-only and are never intended to be read element-wise from Swift. There is
> no `Int4` or `Float8` in the Swift standard library, and **no such type appears anywhere in the
> 312-symbol Core AI index.**
>
> **A second, related gap:** `NDArray.ScalarType.type` is referenced by `RawView.view(as:)`'s own
> documentation note but is **not present in the 312-symbol index** either. It is undocumented or
> internal.
>
> **What would resolve it:** an SDK interface dump — `swift-api-digester` or
> `xcrun --sdk iphoneos27.0 swiftc -print-module -module-name CoreAI` against an Xcode 27
> installation — or an Apple Developer Forums answer. Neither exists in this corpus.
>
> **Safe default meanwhile.** Use `RawView` / `MutableRawView`. They are type-erased, they carry the
> `scalarType` for you to inspect, and they give you `bytes: RawSpan` and
> `withUnsafeBytes { pointer, shape, strides in … }`. Unpack sub-byte values yourself, respecting the
> strides you are handed. Do **not** guess at a vended type name; do not write `view(as: Int4.self)`
> in code you intend to ship.

```swift compile:27
import CoreAI

/// Read a palettized index plane (uint4, two indices per byte) without guessing at a Swift type.
/// Uses only APIs verified on Apple's documentation pages.
func readNibbleIndices(from ndArray: borrowing NDArray) -> [UInt8] {
    let raw = ndArray.rawView()

    // Inspect rather than assume. `scalarType` is a documented property of RawView.
    guard raw.scalarType == .uint4 else {
        preconditionFailure("expected a uint4 index plane, got \(raw.scalarType)")
    }

    var out: [UInt8] = []
    raw.withUnsafeBytes { pointer, shape, strides in
        // NOTE: strides are in the array's own units and MUST be respected — Apple's own
        // documentation for withUnsafePointer says so explicitly: "You are responsible for
        // reading the strides passed in when indexing the backing data."
        let byteCount = raw.bytes.byteCount
        out.reserveCapacity(byteCount * 2)
        for i in 0..<byteCount {
            let b = pointer.load(fromByteOffset: i, as: UInt8.self)
            out.append(b & 0x0F)
            out.append(b >> 4)
        }
    }
    return out
}
```

⚠️ Two caveats on that snippet, both from Apple's own prose. First, the nibble **order** (low half
first vs high half first) is not documented anywhere in the Core AI corpus — the code above assumes
low-first because that is MLX's convention (`quantized_nax.h:486-530`, §6.4), and **that is an
assumption about a different framework**. Verify against a known tensor before trusting it. Second,
the flat byte walk above is only valid for a contiguous view; for anything else you must use the
`strides` argument, which is why they are passed to you.

### 3.3 Storage is not the only thing `NDArray` describes

Two properties adjacent to `scalarType` change how bytes are laid out without changing the format,
and both are easy to confuse with a numeric-format question.

**Strides.** ✅ VERIFIED — `init(shape:scalarType:)` produces "contiguous, row-major strides";
`init(descriptor:)` does not: *"The resulting array may not have a contiguous layout. The strides
match the values returned by the descriptor's preferred strides, so `contiguousElements` on a view
of this array may return `nil`."*

**`InterleaveLayout`.** ✅ VERIFIED — the most thoroughly documented type in the framework:

```swift illustrative
struct InterleaveLayout          // Equatable, Sendable, SendableMetatype
init(dimension: Int, factor: Int)
var dimension: Int { get }
var factor: Int { get }
```

> ✅ **VERIFIED** — Apple documentation, verbatim: *"An interleaved layout means that elements of the
> interleaved `dimension` are stored in physically contiguous blocks of `factor` elements (stride 1
> between adjacent elements within a block)."* The offset formula, also verbatim:
> ```swift
> // offset = (index[d] / f) * strides[d] + (index[d] % f)
> //        + Σ index[i] * strides[i]  for all i ≠ d
> ```
> And the stride semantics that trip people: *"The stride for the interleaved dimension (as reported
> by `NDArray.strides`) is a **block stride** — the distance in memory between adjacent blocks of
> `factor` elements, not between individual elements."*

Why this belongs in a numeric-formats guide: **an interleave factor looks exactly like a block size
and is not one.** `InterleaveLayout(dimension: 0, factor: 32)` is a memory layout for a dense
tensor. `PerBlockGranularity(axis: 1, block_size: 32)` is a quantization grouping. They will both
appear in a model's description, they both say 32, and they mean entirely different things. If you
find yourself reasoning about "the 32 in this tensor", determine which 32 it is first.

Apple also documents when interleave is *not* expressible any other way, which is the one case where
you cannot just reshape it away:

> ✅ **VERIFIED**: *"When `factor` does not divide the dimension size evenly, the shape/stride
> equivalence is not possible. In such case the interleaved representation is the only way to express
> the layout."*

### 3.4 Where each `coreai-opt` dtype lands in the store set

| `coreai-opt` emit | Physical container (`get_target_dtype`) | `NDArray.ScalarType` you should expect | Notes |
|---|---|---|---|
| `torch.int8` | `int8` | `.int8` | |
| `torch.uint8` | `uint8` | `.uint8` | |
| `torch.int4` | `int8` (packed) | `.int4` | Container ≠ scalar type. Two per byte. |
| `torch.uint4` | `uint8` (packed) | `.uint4` | |
| `torch.int2` / `uint2` | `int8` / `uint8` | `.int2` / `.uint2` | Not exportable to CoreML. |
| `torch.float8_e4m3fn` | `float8_e4m3fn` | `.float8e4m3fn` | |
| `torch.float8_e5m2` | `float8_e5m2` | `.float8e5m2` | |
| `torch.float4_e2m1fn_x2` | `float8_e4m3fn` in torch; **uint8-packed, last dim doubled** in the converter | `.float4e2m1fn` | Always accompanied by E8M0 scales. |
| `scale_dtype=float8_e8m0fnu` | — | `.float8e8m0fn` | The scale plane's *own* dtype. |
| Palette indices at `n_bits` ∈ {1,2,3,4,6,8} | packed bytes | `.uint1`/`.uint2`/`.uint3`/`.uint4`/`.uint6`/`.uint8` | 🟡 the index-plane scalar type is inferred from the width, not documented. |
| Palette LUT | `int8`/`uint8`/`float8_e4m3fn`/`float8_e5m2` | correspondingly | The LUT dtype is the one that decides the compute path (§2.5). |

> 🟡 **RECONSTRUCTED — the palette index-plane row.** The mapping from `n_bits` to a specific
> `NDArray.ScalarType` case is an inference: `coreai-opt` emits `lut_to_dense` with an index tensor
> of the configured width, and `NDArray.ScalarType` has exactly the unsigned sub-byte cases that
> would represent it. **No Apple document states this correspondence.** Resolve it by opening a
> palettized `.aimodel` in the Xcode model viewer and reading the **Storage types** list (§8.1) —
> that is a two-minute check and it is definitive for your model.

The `coreai-torch` type map corroborates the whole column, which is a useful independent check:

> ✅ **VERIFIED** — `apple/coreai-torch`, `coreai_torch/_type_mapping.py`, `TORCH_TO_COREAI_DTYPE`:
> ```python
> torch.bool          -> IntegerType.get_signless(1)
> torch.uint1/2/3/4/6 -> IntegerType.get_unsigned(1/2/3/4/6)
> torch.int8/uint8    -> IntegerType.get_signed(8) / get_unsigned(8)
> torch.int16/uint16  -> signed(16) / unsigned(16)
> torch.int32/uint32  -> signed(32) / unsigned(32)
> torch.int64         -> signed(64)
> torch.float32/64/16 -> F32Type / F64Type / F16Type
> torch.bfloat16      -> BF16Type
> torch.float8_e5m2 / e4m3fn / e8m0fnu -> Float8E5M2Type / Float8E4M3FNType / Float8E8M0FNUType
> torch.complex32/64  -> ComplexType(F16Type) / ComplexType(F32Type)
> # conditionally, if hasattr(torch, "int4"):            torch.int2/int4 -> signed(2)/signed(4)
> # conditionally, if hasattr(torch, "float4_e2m1fn_x2"): -> Float4E2M1FNType
> ```
> Note the `uint1/2/3/4/6` row — **the converter has an unsigned sub-byte path for exactly the
> palettization widths** (1, 2, 3, 4, 6), which is the strongest available corroboration for the
> 🟡 row above. It is not proof, because the mapping is dtype-to-MLIR-type rather than
> dtype-to-`ScalarType`, but it is the same set.

### 3.5 ⚠️ 64-bit types are narrowed on the way in

> ⚠️ **SILENT NARROWING.** ✅ VERIFIED — `coreai_torch/_utils.py:305`:
> ```python
> # Narrow int64/fp64 to int32/fp32 since coreai does not handle 64-bit types.
> _NARROW_TORCH_DTYPE: dict[torch.dtype, torch.dtype] = {
>     torch.int64: torch.int32,
>     torch.float64: torch.float32,
> }
> ```
> `check_result_type` then accepts either the wide or the narrowed dtype.
>
> `NDArray.ScalarType` *has* `int64`, `uint64`, `int128` and `uint128` cases — but the PyTorch
> converter will not produce them, and the comment says why in one line. If you have an int64 index
> tensor with values above `INT32_MAX`, conversion narrows it and the overflow is yours. The same
> file already carries an explicit clamp for one instance of this class of bug:
> ```python
> # INT32_MAX overflow to negative (e.g. INT64_MAX → -1), causing coreai.slice_ to compute a wrong
> # output shape. Clamp to INT32_MAX.
> return min(val, SLICE_INT32_MAX)
> ```
> Which tells you the failure is real, was hit, and was fixed in one place — not everywhere.

---

## 4. The Neural Engine: the narrowest compute set

### 4.1 Three dtypes

This is the single most load-bearing fact in the guide.

> ✅ **VERIFIED** — `apple/coreai-models`, Apple's own agent skill
> `skills/model-authoring/references/neural_engine_rules.md` (479 lines of empirical rules written by
> Apple engineers for machine consumption, which makes them unusually literal): *"Max tensor rank
> **5**; dtypes **fp16 / int8 / int16** (**fp32 falls back to GPU/CPU**); fully static shapes."*

Restated as a table, because the omissions are the point:

| Format | ANE | Consequence if present |
|---|---|---|
| **fp16** | ✅ the native compute precision | — |
| **int8** | ✅ | — |
| **int16** | ✅ | — |
| **fp32** | ❌ | The op falls back to **GPU or CPU** |
| **bfloat16** | 🔴 GAP — not listed either way | See below |
| **int4 / uint4** | ❌ not a compute dtype | Must be dequantized to fp16 before the matmul |
| **int2, FP8, FP4, E8M0** | ❌ | Same |
| **fp64, int32, int64, complex** | ❌ | Same |

The same skill's companion file for the other target draws the contrast explicitly, which is how you
know the fp16-only rule is about the ANE and not a general Core AI constraint:

> ✅ **VERIFIED** — `skills/model-authoring/references/gpu_rules.md` and the at-a-glance table in
> `skills/model-authoring/SKILL.md`:
>
> | Aspect | Neural Engine | GPU |
> |---|---|---|
> | Tensor layout | BC1S `(B, H*D, 1, S)` | Standard `(B, S, D)` |
> | Projections | `nn.Conv2d(kernel_size=1)` | `nn.Linear` (fused QKV) |
> | Embedding shape | `(V, 1, D)` — externalized | standard `nn.Embedding` |
> | Attention | Per-head sequential | Fused native SDPA |
> | **Float precision** | **fp16 only — no fp32 literals anywhere** | **fp16 weights, fp32 intermediates OK** |
> | Shapes | Fully static | Dynamic supported |
> | Weight conversion | `unsqueeze(-1).unsqueeze(-1)` | none |

> 🔴 **GAP — bfloat16 on the ANE.** Apple's rule file names fp16, int8 and int16 and does not mention
> bfloat16 in either direction. Separately, `coreai.llm.export` accepts
> `--compute-precision {float16,bfloat16,float32}` and **requires `bfloat16` for Gemma 3**
> (✅ VERIFIED, `apple/coreai-models` consolidated gotcha #14) — but Gemma 3 is a **macOS-only**
> export in that repo, and the iOS/ANE path is only wired for mistral / qwen2 / qwen3
> (✅ VERIFIED, gotcha #13). So the corpus contains no case of a bfloat16 model on the ANE.
>
> **What would resolve it:** exporting a small bfloat16 model with `--platform iOS` and reading the
> Neural Engine track in Instruments (§8.3). **Safe default meanwhile:** if you are targeting the
> ANE, cast to fp16. `cast_to_16_bit_precision` is the supported path and it is one line (§2.9).

### 4.2 ⚠️ SILENT FAILURE — a bare Python float literal can move an op to the GPU

Apple's rule is stated as an absolute: *"fp16 only — **no fp32 literals anywhere**."* Taken at face
value it sounds superstitious. The converter source explains exactly why it is not.

> ✅ **VERIFIED** — `apple/coreai-torch`, `TorchConverter.get_operand`: a Python `float` argument
> becomes an **fp16 constant** when **(a)** every float tensor operand of the node is fp16 **and**
> **(b)** the value round-trips losslessly through fp16. The two predicates are named in the source:
> `_all_float_operands_are_fp16` and `_is_float_in_float16_range`. `scalar_constant()` deliberately
> **bypasses** this promotion for Metal-kernel scalars.

Read the contrapositive, because that is the failure:

> ⚠️ **SILENT FAILURE.** If *either* predicate fails, your literal is materialised as an **fp32
> constant**. An fp32 constant makes the consuming op an fp32 op. An fp32 op is not ANE-eligible
> (§4.1). Specialization moves it — and, per the `preferredComputeUnitKind` documentation quoted in
> §1.1, possibly the whole *fused pattern* it belongs to — to the GPU or CPU. **Nothing warns you.**
> The model is numerically fine and materially slower.
>
> The two ways to trip it:
> - **Mixed operand precision.** One fp32 tensor anywhere in the node's float operands and predicate
>   (a) fails, so *every* scalar in that node goes to fp32 as well. Precision problems are
>   contagious across a node.
> - **A value fp16 cannot represent exactly.** `1e-6` is the classic: a common layer-norm/RMSNorm
>   epsilon, and **below fp16's smallest normal**. Predicate (b) fails and you get an fp32 constant
>   inside an otherwise-fp16 normalization.

Concrete instances of this class already documented in the corpus:

> ✅ **VERIFIED** — `apple/coreai-models`, `skills/model-authoring/references/common_issues.md`:
> `nn.functional.silu(x)` lowers to `mps.cast(→f32) + mps.swish(f32) + mps.cast(→f16)` — *"3 invalid
> ops on NE"* — and the prescribed fix is to write the activation out by hand:
> ```python
> # instead of: gate = torch.nn.functional.silu(gate_pre)
> gate = gate_pre * torch.sigmoid(gate_pre)
> ```
> Similarly `torch.tanh` is replaced with `2 * torch.sigmoid(2 * x) - 1` for AdaLN on the NE.

> ✅ **VERIFIED** — `apple/coreai-torch`, consolidated gotcha 16: *"`RMSNormImpl` deliberately
> computes the square/mean in fp32 (fp16 max is 65504)."* This is a **deliberate** fp32 island, not
> a bug — the sum of squares overflows fp16 for realistic hidden sizes. It is also, by §4.1, a
> guaranteed ANE exit for that op unless the runtime has a fused fp16-safe path.

And the one that is not about literals at all but about the same failure mode, from Apple's own
shipped model recipe:

> ✅ **VERIFIED** — `apple/coreai-models` SAM3 export, quoted in the research corpus: *"Both encoders
> **deliberately disable per-channel scale**: `enable_per_channel_scale=True` lowers to
> **`mps.dequantize_lut` ops with rank-6 LUTs, which ANE rejects (max tensor rank 5)**, forcing the
> runtime to **fall back to GPU**. Keeping it off keeps the asset **ANE-compatible** at the cost of a
> small PyTorch-side quality regression."*
>
> ⚠️ Note the trade Apple made: they took a **known quality regression** to avoid a **silent
> compute-unit fallback**. That is the ranking this guide is arguing for.

⚠️ One reading caution on that last item: WWDC26 session 325's narration says the encoders use
per-channel scales, while the shipped code sets `enable_per_channel_scale=False`. Either the talk
used the phrase loosely (perhaps meaning `PerGroupedChannelGranularity`), or the recipe changed after
recording. **Both readings are live; do not smooth it over.**

### 4.3 The structural constraints that are not about dtype but behave like it

The ANE has four non-dtype rules that produce identical symptoms — a working, slower model — and
they belong on the same checklist.

> ✅ **VERIFIED** — `references/neural_engine_rules.md`:
>
> | Constraint | Rule | Failure mode |
> |---|---|---|
> | **Rank** | Max tensor rank **5** | Rank-6 op → GPU (the LUT case above) |
> | **Last-axis alignment** | Last axis must be **contiguous and 64-byte aligned** | Padding / reshapes; see the singleton cost below |
> | **Singleton last axis** | Costs **32× memory at fp16, 64× at int8** | Silent memory blow-up |
> | **Minimum last-axis width** | Keep **≥ 32 fp16 elements**; prefer powers of two | Wasted lanes |
> | **Shapes** | Fully static | Dynamic dim → not ANE-eligible |
> | **Softmax masking** | Use **`-40000.0`**, never `-inf` — *"Neural Engine hardware does not handle IEEE `-inf` correctly in softmax"* | Wrong numbers, not a fallback |
> | **Conv stride** | Only prime factors 2 and 3 (4, 6, 8, 9, 12, 16, 24, 32); palettized kernels support **stride ≤ 2** | Unsupported stride → fallback |

The `-40000.0` rule is the one worth calling out separately, because it is the only entry in this
guide where a format mismatch produces **wrong numbers rather than a fallback**. Every other row in
every other table degrades performance and preserves correctness. That one does not.

### 4.4 ⚠️ Recognized functions select the sample loader’s ANE preference

WWDC26 session 325 presents splitting SAM3 into three entrypoints — `image_encode`, `text_encode`,
`detect` — as a **latency trick**: run each at a different cadence, 76% faster second inference.

Reading the optional `coreai-models` package shows a second consequence for callers using its loader:

> ✅ **VERIFIED** — `apple/coreai-models`, `ModelStructure.swift:71-80`: recognized structures select
> that helper’s Neural Engine preference. Direct `AIModel` callers choose their own
> `SpecializationOptions`, and Apple's specialization documentation describes no function-name
> routing in the framework itself — the name policy is that helper's code alone.
> [^sample-routing-policy]

The per-function compression recipe in the same repo is a small masterclass in matching format to
compute unit:

> ✅ **VERIFIED** — `apple/coreai-models` SAM3 pipeline:
>
> | Function | Compression | Inputs | Outputs |
> |---|---|---|---|
> | `image_encode` | 4-bit k-means palettization (group size 32) + fp16 | `pixel_values` | `backbone_features` |
> | `text_encode` | 6-bit k-means palettization (group size 8) + fp16 | `input_ids` | `text_features` |
> | `detect` | **fp16, no weight compression** | `backbone_features`, `text_features` | `pred_masks`, `pred_boxes`, `pred_logits`, `presence_logits` |
>
> Three functions, three different numeric configurations, in one asset. The detector — the smallest
> and most quality-sensitive part — is left uncompressed entirely.

⚠️ **But**: `CoreAISegmentationEngine` **re-runs `image_encode` on every call** and exposes no cache.
The 76% figure requires caller-side work that Apple's own package does not do for you. ✅ VERIFIED,
`coreai-models-nonllm` source review.

### 4.5 The iOS/ANE export recipe, as Apple ships it

Apple's own LLM export presets are the best available evidence of what an ANE-targeted numeric
configuration looks like in practice — and note that **the iOS path uses palettization while the
macOS path uses quantization**. They are not the same technique with different parameters.

> ✅ **VERIFIED** — `apple/coreai-models`, `python/src/coreai_models/export/presets.py`:
> ```python
> DEFAULT_MACOS_COMPRESSION_PRESET = "4bit"
> DEFAULT_IOS_COMPRESSION_PRESET   = "4bit_weight_palettized_group32"
> ```
> **macOS `"4bit"`** — a `torch_quantization_config`:
> ```python
> {"execution_mode": "eager",
>  "global_config": {"op_state_spec": {"weight": {"dtype": "int4",
>         "qscheme": "symmetric_with_clipping",
>         "granularity": {"type": "per_block", "block_size": 32, "axis": 1}}},
>    "op_input_spec": None, "op_output_spec": None}}
> ```
> with `SDPA`, `RoPE`, `RMSNorm` and `RMSNormPlusOne` mapped to `None` (skipped), and a MoE override
> for `SwitchLinear` using `block_size=[1, 1, 1, 32], axis=None` because the expert weight is 4-D
> `[num_weight_sets, num_experts, output_dims, input_dims]` and the global 2-D spec cannot express it.
>
> **iOS `"4bit_weight_palettized_group8"` / `"…_group32"`** — a `kmeans_palettization_config`:
> ```python
> {"n_bits": 4, "granularity": {"type": "per_grouped_channel", "axis": 0, "group_size": 8 or 32}}
> ```
> with `torch.nn.modules.sparse.Embedding` and `coreai_models.primitives.ios.embedding.LoadEmbeddings`
> excluded. And from `models/README.md:54`: *"All `iOS` palettization presets quantize the Embedding
> to 8-bit per tensor by default."* — via `quantize_per_tensor` in `primitives/ios/quantization.py`,
> symmetric, `nbits=8` only, `scale = max|x| / 127`, clamped min `1e-6`.

Four things to take from that:

1. **Normalization and positional-encoding modules are excluded from compression on both targets.**
   They are small and they are where fp16 range problems live.
2. **The embedding is handled separately from everything else** on iOS: excluded from palettization,
   then quantized 8-bit per-tensor. The head and embedding are the largest single tensors in an LLM
   and the most sensitive; §9.3 returns to this.
3. **`symmetric_with_clipping` at int4** — Apple gives up the −8 level (12.5% of the range) to get an
   exactly symmetric grid. At int8 the same choice costs 0.4%. The fact that Apple makes it at 4 bits
   tells you symmetry is worth more than the extra level at low widths.
4. **A YAML compression config's top-level key selects the platform.** ✅ VERIFIED,
   `export.py:163-237`: `kmeans_palettization_config` requires `--platform iOS`;
   `quantization_config` requires `--platform macOS`. Mixing them raises
   `RuntimeError("macOS quantization preset provided, but platform is iOS.")` and its mirror image.

---

## 5. Metal and MPP TensorOps: the GPU compute set

### 5.1 The 26.x baseline and the Xcode 27 extension

Metal Performance Primitives TensorOps is the floor that both Core AI's GPU path and MLX stand on.
The dtype surface is versioned: the following enum is the Xcode 26.6 baseline, not the OS 27 set.

> ✅ **VERIFIED** — `MetalPerformancePrimitives.framework/Headers/__impl/MPPTensorOpsTypes.h:36-57`,
> complete and unabridged, from the Xcode 26.6 SDK (Build 17F113):
> ```cpp
> enum __tensor_ops_datatype
> {
>   __tensor_ops_datatype_invalid = 0,
>
>   __tensor_ops_datatype_float_bit = 0x10000000,
>   __tensor_ops_datatype_float32 = __tensor_ops_datatype_float_bit | 32,
>   __tensor_ops_datatype_float16 = __tensor_ops_datatype_float_bit | 16,
>
>   __tensor_ops_datatype_signed_bit = 0x20000000,
>   __tensor_ops_datatype_int4 = __tensor_ops_datatype_signed_bit | 4,
>   __tensor_ops_datatype_int8 = __tensor_ops_datatype_signed_bit | 8,
>   __tensor_ops_datatype_int16 = __tensor_ops_datatype_signed_bit | 16,
>   __tensor_ops_datatype_int32 = __tensor_ops_datatype_signed_bit | 32,
>
>   __tensor_ops_datatype_uint4 = 4,
>   __tensor_ops_datatype_uint8 = 8,
>   __tensor_ops_datatype_uint16 = 16,
>   __tensor_ops_datatype_uint32 = 32,
>
>   __tensor_ops_datatype_alternate_encoding_bit = 0x80000000,
>   __tensor_ops_datatype_bfloat16 = __tensor_ops_datatype_alternate_encoding_bit | __tensor_ops_datatype_float16,
> };
> ```
> Fourteen entries besides `invalid`, of which **three are bit-mask constants**
> (`float_bit`, `signed_bit`, `alternate_encoding_bit`), leaving **eleven concrete element types**.

The encoding is "low 16 bits are the bit width", confirmed by the size helper — note that it returns
**bytes**, so 4-bit types report `0` and are special-cased elsewhere:

> ✅ **VERIFIED** — `MPPTensorOpsTypes.h:130-133`:
> ```cpp
> inline uint16_t __sizeof_tensorops_datatype(__tensor_ops_datatype dataType)
> {
>   return (dataType & 0xFFFF) >> 3;
> }
> ```

The following absences are therefore true **only of that Xcode 26.6 header**:

| Session 330 type | Xcode 26.6 | Xcode 27 |
|---|---|---|
| int2 | absent | `__tensor_ops_datatype_int2` / `uint2` |
| int4 | `__tensor_ops_datatype_int4` / `uint4` | retained |
| int8 | `__tensor_ops_datatype_int8` / `uint8` | retained |
| fp4 | absent | `__tensor_ops_datatype_fp4_e2m1` |
| fp8 | absent | `__tensor_ops_datatype_fp8_e4m3` / `fp8_e5m2` |
| `E8M0` scale factors | absent | `__tensor_ops_datatype_fp8_ue8m0` + auxiliary scale plane[^xcode27-scale-planes] |

> ✅ **VERIFIED — version-scoped negative result.** Case-insensitive searches for `scale`,
> `plane`, `block_factor`, `blockFactor`, `fp8`, `fp4`, `e8m0`, `e4m3`, `quant` and `aux` across
> **all ~14,300 lines of MPP headers** and **all 2,788 lines of `metal_tensor` +
> `metal_cooperative_tensor`** return **zero hits** in Xcode 26.6.

Xcode 27 extends both the host descriptor and the shader-side type map. `MTLTensorDataType` adds
int2/uint2, FP4 E2M1, FP8 E4M3/E5M2 and unsigned E8M0; `MPPTensorOpsTypes.h` maps the corresponding
`metal::*_format` types into TensorOps datatypes.[^xcode27-scale-planes]

| Xcode 27 type | TensorOps mapping |
|---|---|
| `metal::int2b_format` / `metal::uint2b_format` | `__tensor_ops_datatype_int2` / `uint2` |
| `metal::metal_fp4_e2m1_format` | `__tensor_ops_datatype_fp4_e2m1` |
| `metal::metal_fp8_e4m3_format` / `metal::metal_fp8_e5m2_format` | `__tensor_ops_datatype_fp8_e4m3` / `fp8_e5m2` |
| `metal::metal_fp8_ue8m0_format` | `__tensor_ops_datatype_fp8_ue8m0` |

### 5.2 The Metal-language types, and the int16 oddity

The enum is the *description*; the Metal shading-language types are what you actually write.

> ✅ **VERIFIED** — `MPPTensorOpsTypes.h:101-128` in Xcode 26.6, complete for that SDK:
> ```cpp
> template <typename ElementType>
> constexpr __tensor_ops_datatype __element_type_to_tensor_ops_datatype()
> {
>   if constexpr (__is_same_v<ElementType, float>)
>     return __tensor_ops_datatype_float32;
> #if __HAVE_BFLOAT__
>   else if constexpr (__is_same_v<ElementType, bfloat>)
>     return __tensor_ops_datatype_bfloat16;
> #endif
>   else if constexpr (__is_same_v<ElementType, half>)
>     return __tensor_ops_datatype_float16;
> #if __HAVE_INT4B_FORMAT_TYPE__
>   else if constexpr (__is_same_v<ElementType, metal::int4b_format>)
>     return __tensor_ops_datatype_int4;
>   else if constexpr (__is_same_v<ElementType, metal::uint4b_format>)
>     return __tensor_ops_datatype_uint4;
> #endif
>   else if constexpr (__is_same_v<ElementType, int8_t>)
>     return __tensor_ops_datatype_int8;
>   else if constexpr (__is_same_v<ElementType, uint8_t>)
>     return __tensor_ops_datatype_uint8;
>   else if constexpr (__is_same_v<ElementType, int32_t>)
>     return __tensor_ops_datatype_int32;
>   else if constexpr (__is_same_v<ElementType, uint32_t>)
>     return __tensor_ops_datatype_uint32;
>   else
>     static_assert(__assert_false_v<ElementType>, "unsupported data type");
> }
> ```
> The 4-bit element types are spelled **`metal::int4b_format`** and **`metal::uint4b_format`**, gated
> on the feature macro `__HAVE_INT4B_FORMAT_TYPE__`. `MPPTensorOpsUtility.h:66-77` carries the
> parallel trait specializations.

The Xcode 27 continuation adds feature-gated branches for int2/uint2, FP4, both FP8 value formats,
and unsigned E8M0. Do not use the 26.6 excerpt as a negative capability test for an OS 27 target.
[^xcode27-scale-planes]

> 🟡 **RECONSTRUCTED — `int16` / `uint16` have no Metal-type mapping in the quoted function.** The
> enum contains `__tensor_ops_datatype_int16` and `__tensor_ops_datatype_uint16`, but the function
> above — quoted in full — has **no `short` / `ushort` branch**, so a `metal::tensor<short, …>` would
> hit the `static_assert`. Two readings fit: the enum anticipates types the 26.x mapping does not yet
> expose, or the mapping lives elsewhere and our excerpt is the only path. **Do not plan a 16-bit
> integer TensorOps kernel on this evidence.** Resolving it takes one grep of
> `MPPTensorOpsUtility.h` for `short` on a machine with the SDK.
>
> **Safe default meanwhile:** use `int8_t` operands with an `int32_t` accumulator, which is an
> attested triple (below).

### 5.3 The 4-bit operand rows, verbatim — and the two structural facts they encode

The public header enumerates every legal `(left, right, destination)` combination in its opening
comment. Our corpus reproduces the 4-bit rows in full:

> ✅ **VERIFIED** — `MPPTensorOpsMatMul2d.h:52-61`, verbatim:
> ```
> //  half     int4b_format   half
> //  half     int4b_format   float
> //  half     uint4b_format  half
> //  half     uint4b_format  float
> //  int8_t   int4b_format   int32_t
> //  uint8_t  uint4b_format  int32_t
> //  bfloat   int4b_format   bfloat
> //  bfloat   uint4b_format  bfloat
> //  bfloat   int4b_format   float
> //  bfloat   uint4b_format  float
> ```
> Corroborated by the implementation dispatch chain (`MPPTensorOpsMatMul2dImpl.h:5801`) and the
> operand validity assert (`:2505-2528`), whose message names the legal element types:
> *"uint8_t/int8_t/uint4b_format/int4b_format/float/half/bfloat"*.

Two facts follow, and they constrain kernel design more than the dtype list does:

1. **4-bit is right-operand-only.** Every `int4b_format` / `uint4b_format` entry has the 4-bit type
   in the **right** position. There is no `int4b_format × half` row. This matches the
   weights-quantized inference case exactly — **your weights must be operand B** — and it means you
   cannot write a 4-bit-activation kernel this way.
2. **There is no separate scale argument in the `matmul2d` signature.** On 26.x and for custom
   encodings, apply scale/zero point yourself before or around the op. On OS 27, a supported
   block-scaled `MTLTensor` instead carries an E8M0 auxiliary scale plane, so TensorOps can
   dequantize it without a fourth explicit operand.[^xcode27-scale-planes]

> 🔴 **GAP — the non-4-bit rows.** The header comment at `MPPTensorOpsMatMul2d.h:13-61` enumerates
> roughly 50 operand triples in total; our corpus reproduces only the ten 4-bit rows. **The
> `int8_t × int8_t → int32_t` triple is not directly quoted anywhere in this corpus**, although it is
> strongly implied by the 26.4 "four bit and eight bit integer tensors" announcement and by the
> validity assert listing `int8_t` as a legal element type.
>
> **What would resolve it:** reading lines 13–61 of that header on any machine with Xcode 26.2+.
> That is a 30-second check and it is the single most useful reference artifact in the framework.
> **Safe default meanwhile:** verify your intended triple compiles with a two-line
> `static_assert(mpp::tensor_ops::matmul2d<…>::is_compatible_as_right_input<…>())`-style probe before
> building a kernel around it, rather than assuming.

### 5.4 The version ladder — and why two different numbers are both right

This is the correction that supersedes every earlier draft in this series.

> ✅ **VERIFIED** — Apple Tech Talk **111432**, *"Accelerate your machine learning workloads with the
> M5 and A19 GPUs"* (Zak, manager of the GPU Driver Performance team), verbatim:
> *"We introduced TensorOps at **[WWDC] 25** in the **combined metal for machine learning and
> graphics** session. … Since we introduced TensorOps, we've continued expanding the API **in iOS and
> Mac OS 26**. In **26.1**, we added **bfloat tensor support**, critical for modern ML models that
> use Bfloat16. In **26.3**, we added support for **cooperative tensors as inputs to matmul**. This
> lets you **build custom dequantization routines inside your kernel**, essential for running
> quantized models efficiently. And in **26.4**, we added **four bit and eight bit integer tensors**,
> so quantized models can fully leverage neural accelerators."*

| Version | Feature added |
|---|---|
| **26.0** (WWDC25 session 262, "Combine Metal 4 machine learning and graphics") | TensorOps introduced |
| **26.1** | **bfloat** tensor support |
| **26.2** | *(not mentioned in the ladder — see below)* |
| **26.3** | **cooperative tensors as *inputs* to matmul** → enables in-kernel custom dequantization |
| **26.4** | **4-bit and 8-bit integer tensors** |

And, separately and also true:

> ✅ **VERIFIED** — `MetalPerformancePrimitives.framework/Headers/__impl/MPPTensorOpsAvailability.h:10`,
> in the shipped Xcode 26.6 SDK:
> ```cpp
> #define __TENSOR_OPS_SUPPORT_DEPLOYMENT_TARGET_26_2 ((__ENVIRONMENT_OS_VERSION_MIN_REQUIRED__) >= 260200)
> ```

⚠️ **Report both. They are about different things.** The ladder is Apple describing *when each
capability was added*. The macro is the *deployment-target gate on the symbols in this particular
SDK*. A blanket "TensorOps availability is 26.2" is wrong; so is "int4 tensors arrived at 26.2."
The defensible sentence is: *"TensorOps ships across macOS/iOS 26 point releases — base at 26.0,
bfloat at 26.1, cooperative-tensor matmul inputs at 26.3, int4/int8 tensors at 26.4 — and the
shipped Xcode 26.6 SDK annotates the relevant symbols with a 26.2 deployment-target macro."*

The 26.x ladder remains correct for the original TensorOps, bfloat, cooperative-tensor inputs and
int4/int8 path. It does **not** refute session 330: OS 27 adds a separate tier comprising int2,
FP4/FP8/E8M0 tensor datatypes and auxiliary scale planes.[^xcode27-scale-planes]

Two more compile-time gates hide behind the availability macro, and their failure mode is a
confusing error rather than a clear one:

> ✅ **VERIFIED** — `MPPTensorOpsMatMul2d.h:328`:
> ```cpp
> #if defined(__METAL_VERSION__) && defined(__HAVE_TENSOR__)
> ```
> ⚠️ If `__HAVE_TENSOR__` is undefined the entire header expands to nothing — **no error, just an
> empty namespace** and a "no member named matmul2d" complaint hundreds of lines later. Related
> feature macros: `__HAVE_BFLOAT__`, `__HAVE_INT4B_FORMAT_TYPE__` (`MPPTensorOpsTypes.h:106,112`),
> `__HAVE_EXECUTION_UNIT__` (`__exec/units.h:9`).

### 5.5 ✅ Xcode 27 auxiliary scale planes and automatic dequantization

WWDC26 session 330 describes the OS 27 mechanism accurately: an `MTLTensor` can carry quantization
scales beside its data as an **auxiliary scale plane**. `MTLTensorAuxiliaryPlaneDescriptor` provides
the scale `dataType` and per-dimension `blockFactors`; the default and currently supported scale type
is unsigned FP8 E8M0, and the first block factor is 32. A populated
`MTLTensorAuxiliaryPlaneDescriptorMap` is attached through `MTLTensorDescriptor.auxiliaryPlanes`.
[^xcode27-scale-planes]

> ✅ **SDK-verified** — the macOS 27.0 beta SDK's `Metal.framework/Headers/MTLTensor.h` declares
> `MTLTensorAuxiliaryPlaneDescriptor` (`:164`), `MTLTensorAuxiliaryPlaneDescriptorMap` (`:191`),
> and `MTLTensorDescriptor.auxiliaryPlanes`, gated `API_AVAILABLE(macos(27.0), ios(27.0))` (`:288`).

That changes the execution rule by deployment target:

| Target / format | Correct path |
|---|---|
| OS 27, supported FP4/FP8/int2 data with E8M0 block scales | Attach the scale plane; TensorOps consumes both planes and handles dequantization |
| OS 26.x | No auxiliary-plane API; hand-dequantize into a cooperative tensor before `matmul2d` |
| OS 27, custom scale dtype or block geometry | Keep the cooperative-tensor hand-dequantization path |

The custom fallback is not evidence against the built-in path. Session 330 explicitly presents
both: pass a supported quantized tensor to TensorOps for automatic dequantization, or dequantize a
custom format into a cooperative tensor. MLX’s software kernels likewise remain relevant for its own
formats and for deployment targets that predate the OS 27 API.[^xcode27-scale-planes]

> ⚠️ **Descriptor constraints.** OS 27 multi-plane tensors require compute or render usage rather
> than `MTLTensorUsageMachineLearning`, reject data-plane elements larger than one byte and rank-zero
> tensors, and currently accept E8M0 for the scales plane. Preserve a tested software fallback instead
> of assuming that every block-quantized layout can be described by the built-in plane.

### 5.6 TensorOps is portable, not M5-only — and there is no capability query

Two facts that change how you gate code:

> ✅ **VERIFIED** — Tech Talk 111432: *"**The API is portable. The same code runs across Apple's
> entire GPU family from M1 to M5. On older GPUs without neural accelerators, TensorOps falls back to
> optimized shader implementations.**"*

So "can I even use this" is not an objection. But the *fast path* is gated on hardware you cannot
ask about:

> ✅ **VERIFIED** — Tech Talk 111432: *"Neural accelerators are **dedicated hardware in M5 purpose
> built for matrix multiplication**. **They're built into each shader core right alongside the other
> GPU pipelines.**"* And: *"neural accelerator capacity **scales directly with core count**."*
>
> ⚠️ **There is no API for it.** No `supportsFamily`, no feature flag. MLX infers it from the GPU
> architecture generation number and nothing else — ✅ VERIFIED, `mlx/backend/metal/device.cpp:944-963`:
> ```cpp
> bool is_nax_available() {
> #ifdef MLX_METAL_NO_NAX
>   return false;
> #else
>   auto _check_nax = []() {
>     bool can_use_nax = false;
>     if (__builtin_available(macOS 26.2, iOS 26.2, tvOS 26.2, visionOS 26.2, *)) {
>       can_use_nax = true;
>     }
>     auto& d = metal::device(mlx::core::Device::gpu);
>     auto arch = d.get_architecture().back();
>     auto gen = d.get_architecture_gen();
>     can_use_nax &= gen >= (arch == 'p' ? 18 : 17);
>     return can_use_nax;
>   };
>   static bool is_nax_available_ = _check_nax();
>   return is_nax_available_;
> #endif
> }
> ```
> `gen >= 18` when the architecture suffix is `'p'`, else `gen >= 17`. That is MLX's M5-class
> detection, and it is the only approach available. Readers will look for a capability query; tell
> them there isn't one.

> 🔴 **GAP — what "NAX" stands for.** The token appears ~60 times across MLX with no expansion
> anywhere in the tree; Apple's own assert strings in the same file say "MXU"
> (`steel/gemm/nax.h:834`). Presumably *Neural Accelerator* something. **Do not expand it in prose.**

### 5.7 The GPU compute set, summarised

| | Supported |
|---|---|
| Float element types | `float` (fp32) · `half` (fp16) · `bfloat` (26.1+) |
| Integer element types | 26.x: `int8_t` · `uint8_t` · `int32_t` · `uint32_t` · `metal::int4b_format` · `metal::uint4b_format`; 27 adds `metal::int2b_format` / `uint2b_format` |
| OS 27 low-bit floats | `metal::metal_fp4_e2m1_format` · `metal::metal_fp8_e4m3_format` · `metal::metal_fp8_e5m2_format` · `metal::metal_fp8_ue8m0_format`[^xcode27-scale-planes] |
| In the enum but unmapped in the quoted excerpt | `int16` · `uint16` (🟡 §5.2) |
| Scale / block-scale mechanism | OS 27 E8M0 auxiliary scale plane with `blockFactors`; hand-dequantize on 26.x/custom formats |
| 4-bit operand position | **right operand only** |
| Block-scaled formats | OS 27 built-in path for E8M0/32-compatible data; software for custom layouts such as E4M3-scaled NVFP4 |
| Deployment gate | baseline ladder 26.0/26.1/26.3/26.4; int2/FP4/FP8/E8M0 + scale planes at 27; feature macros must be defined |
| Hardware fast-path gate | GPU architecture generation ≥ 17 (≥ 18 for `'p'`); **no query API** |

---

## 6. MLX: the widest menu, implemented in software

MLX is in this guide for two reasons. First, it has the largest format menu of any layer in the
stack — and if you are choosing between Core AI and MLX as a backend, format availability is a real
input to that decision. Second, MLX's implementation is the **reference answer** to "how do you run
a block-scaled format on hardware that has no block-scale primitive," and reading it is how you
understand what the Core AI runtime must also be doing internally.

### 6.1 The modes table, verbatim

> ✅ **VERIFIED** — `ml-explore/mlx`, `python/src/ops.cpp:4649-4660`, the `mx.quantize` docstring,
> reproduced exactly:
> ```
> ======  ======================   ==========================  =============  =====
> mode    group size               bits                        scale type     bias
> ======  ======================   ==========================  =============  =====
> affine  32, 64*, 128             2, 3, 4*, 5, 6, 8           same as input  yes
> mxfp4   32*                      4*                          e8m0           no
> mxfp8   32*                      8*                          e8m0           no
> nvfp4   16*                      4*                          e4m3           no
> ======  ======================   ==========================  =============  =====
> ```
> `*` marks the default when unspecified. Mirrored in Python at
> `mlx.nn.layers.quantized._defaults_for_mode`:
> ```python
> mode_defaults = {"affine": (64, 4), "mxfp4": (32, 4), "nvfp4": (16, 4), "mxfp8": (32, 8)}
> ```

Note the affine bit list: **2, 3, 4, 5, 6, 8**. Seven is excluded and the error message says so:

> ✅ **VERIFIED** — `mlx/ops.cpp` validation messages:
> - `"[quantize] The requested group size <g> is not supported. The supported group sizes are 32, 64, and 128."`
> - `"[quantize] The requested number of bits <b> is not supported. The supported bits are 2, 3, 4, 5, 6 and 8."`
>   (the guard is literally `bits < 2 || bits > 8 || bits == 7`)
> - `"[quantize] <mode> quantization requires group size <16|32> but got <g>."` / `"… requires bits to be <4|8> but got <b>."`
> - `"[quantize] The matrix to be quantized must have at least 2 dimension"`
> - `"[quantize] The last dimension of the matrix needs to be divisible by <group_size>"`
> - `"[quantize] Global scale is not supported on the Metal backend."`
> - `"[dequantize] The matrix should be given as a uint32"`

Compare the three sub-byte width sets across the stack one more time, because they are all different:

| Layer | Widths available |
|---|---|
| `coreai-opt` quantization | 2, 4, 8 (signed and unsigned) |
| `coreai-opt` palettization | 1, 2, 3, 4, 6, 8 |
| `NDArray.ScalarType` | 1(u), 2, 3, 4, 5, 6, 7 (signed from 2; unsigned from 1) |
| MLX affine | 2, 3, 4, 5, 6, 8 |
| MPP TensorOps | 4, 8 |
| ANE | 8, 16 |

There is no width supported by all six. **4 and 8 are the only widths supported by five of them**,
and that is the whole reason 4-bit weights with 8-bit activations is the default recipe everywhere.

### 6.2 The affine formula and the packing convention

> ✅ **VERIFIED** — `mx.quantize` docstring, verbatim:
> ```
> alpha = max_i w_i ;  beta = min_i w_i ;  s = (alpha - beta) / (2^b - 1)
> w_hat_i = round((w_i - beta) / s)
> dequantize:  w_i = s * w_hat_i + beta
> ```
> Packing: *"`w_hat_i` fits in `b` bits and is packed in an unsigned 32-bit integer from the lower to
> upper bits. For instance, for 4-bit quantization we fit 8 elements in an unsigned 32 bit integer
> where the 1st element occupies the 4 least significant bits, the 2nd bits 4-7 etc."*
>
> FP modes: elements quantized to **E2M1** ("fp4") or **E4M3** ("fp8"), with a shared 8-bit scale per
> group — **E8M0** for the `mx*` modes, **E4M3** for `nvfp4`. **No bias.** The docstring links the
> OCP microscaling MX v1.0 specification.

Note MLX's affine is a **min/max asymmetric** formulation with a bias, where `coreai-opt`'s default
is **symmetric with a zero point**. They are not the same encoding at the same bit width, and a
checkpoint quantized by one is not readable by the other without a conversion. `mlx_lm` has a whole
translation layer for exactly this problem (§6.6).

The packing convention also explains a repr oddity you will hit immediately:

> ✅ **VERIFIED** — `QuantizedLinear._extra_repr` reconstructs the logical input dimension as
> `(in_dims * 32) // self.bits` — a reminder that the stored weight's last dimension is **packed
> uint32**, not logical elements.

### 6.3 Python signatures

> ✅ **VERIFIED** — `mlx/python/src/ops.cpp`, the `nb::sig` strings, verbatim:
> ```python
> def quantize(w: array, /, group_size: Optional[int] = None, bits: Optional[int] = None,
>              mode: str = 'affine', *, global_scale: Optional[array] = None,
>              stream=None) -> tuple[array, array, array]
>
> def dequantize(w: array, /, scales: array, biases: Optional[array] = None,
>                group_size: Optional[int] = None, bits: Optional[int] = None,
>                mode: str = 'affine', global_scale: Optional[array] = None,
>                dtype: Optional[Dtype] = None, *, stream=None) -> array
>
> def quantized_matmul(x: array, w: array, /, scales: array, biases: Optional[array] = None,
>                      transpose: bool = True, group_size: Optional[int] = None,
>                      bits: Optional[int] = None, mode: str = 'affine', *, stream=None) -> array
>
> def gather_qmm(x: array, w: array, /, scales: array, biases: Optional[array] = None,
>                lhs_indices: Optional[array] = None, rhs_indices: Optional[array] = None,
>                transpose: bool = True, group_size: Optional[int] = None,
>                bits: Optional[int] = None, mode: str = 'affine',
>                *, sorted_indices: bool = False, stream=None) -> array
>
> def qqmm(x: array, w: array, scales: Optional[array] = None, group_size: Optional[int] = None,
>          bits: Optional[int] = None, mode: str = 'nvfp4',
>          global_scale_x: Optional[array] = None, global_scale_w: Optional[array] = None,
>          *, stream=None) -> array
>
> def to_fp8(x: array, *, stream=None) -> array      # -> uint8 E4M3
> def from_fp8(x: array, dtype: Dtype = bfloat16, *, stream=None) -> array
> ```
> The C++ declarations at `mlx/ops.h:1547-1611` match.

`qqmm` — "quantize both sides" — is the only op in this guide that quantizes the **activation** as
well as the weight, and its mode set is deliberately narrower:

> ✅ **VERIFIED** — `qqmm` supports **only `nvfp4` and `mxfp8`**; anything else raises
> `"[qqmm] Only 'nvfp4' and 'mxfp8' quantization modes are supported but '<mode>'"`. Other documented
> constraints: `x` is quantized on the fly; `w` is used as-is if already quantized (then `scales` is
> required and `group_size`/`bits`/`mode` must match); *"If `w` is expected to receive gradients, it
> must be provided in non-quantized form"*; only 2-D inputs
> (`"[qqmm] Only 2D inputs are supported"`); nvfp4 requires **either both or neither** of
> `global_scale_x` / `global_scale_w`.

⚠️ And a numerical caveat MLX publishes about itself, which is the right way to talk about
low-precision arithmetic:

> ✅ **VERIFIED** — `examples/python/qqmm.py` header comment: *"In mxfp8 mode, the results do not
> match exactly: fewer than 1% of output elements differ. … The error can exceed 1 ULP for very small
> values, and is always below 1 ULP for larger values. **For nvfp4, the results match exactly.**"*

### 6.4 ⚠️ MLX uses its own FP4/FP8 structs even though OS 27 has Metal types

This is the fact that ties §5 and §6 together, and it is the single most important thing to
understand about block-scaled formats on Apple silicon in 2026.

> ✅ **VERIFIED** — `mlx/backend/metal/kernels/fp_quantized_nax.h:31-38`:
> ```cpp
> template <typename T, int group_size>
> static inline T dequantize_scale(uint8_t s) {
>   if constexpr (group_size == 16) {
>     // Use nv scale
>     return T(*(thread fp8_e4m3*)(&s));
>   } else {
>     return T(*(thread fp8_e8m0*)(&s));
>   }
> }
> ```
> `fp8_e8m0` and `fp8_e4m3` are defined in **`mlx/backend/metal/kernels/fp8.h`** (`fp8_e8m0` at
> `fp8.h:51-52`); `fp4_e2m1` is in **`fp4.h`**. They are **plain structs with hand-written bit
> manipulation**, loaded from a `uint8_t` by reinterpret-cast.
>
> **Scope this result to MLX’s implementation.** These identifiers are MLX-owned software structs,
> but Xcode 27 separately provides Metal FP4 E2M1, FP8 E4M3/E5M2 and unsigned E8M0 tensor datatypes
> and shader formats.[^xcode27-scale-planes]

The element dequantization is equally hand-rolled:

> ✅ **VERIFIED** — `fp_quantized_nax.h:50-67`:
> ```cpp
> template <int bits, typename U = float>
> struct Dequantize {
>   U operator()(uint8_t x) {
>     if constexpr (bits == 8) {
>       return U(*(thread fp8_e4m3*)(&x));
>     } else {
>       return U(*(thread fp4_e2m1*)(&x));
>     }
>   }
> };
>
> template <typename U, int bits>
> inline void dequantize(uint8_t w, U scale, threadgroup U* w_local) {
>   if constexpr (bits == 4) {
>     w_local[0] = scale * Dequantize<4, U>{}(w);
>     w_local[1] = scale * Dequantize<4, U>{}(w >> 4);
>   } else {
>     w_local[0] = scale * Dequantize<8, U>{}(w);
>   }
> }
> ```
> Destination is **`threadgroup U*`** — shared memory, in full precision.

And the loader that applies the block scales:

> ✅ **VERIFIED** — `fp_quantized_nax.h:130-145`:
> ```cpp
>   void load_unsafe() const {
>     if (BCOLS_PACKED * BROWS < tgp_size && bi >= BROWS) {
>       return;
>     }
>     int k = 0;
>     for (int i = 0; i < n_steps_per_read; i++) {
>       T scale = dequantize_scale<T, group_size>(scales[i]);
>       for (int j = 0; j < n_reads_per_scale; j++) {
>         dequantize<T, bits>(src[k * bytes_per_pack], scale, dst + k * pack_factor);
>         k++;
>       }
>     }
>   }
> ```
> `scales[i]` comes from a **separate `const device uint8_t*` buffer** (declared at
> `fp_quantized_nax.h:107`), decoded as E8M0 or E4M3 **in software**, multiplied **in software**.

**That loop is MLX's hand-written implementation of the scale-and-dequantize step.** It remains
necessary for this pinned MLX revision, for 26.x deployment, and for custom formats that OS 27's
E8M0/block-factor contract cannot represent. Its existence is not evidence against Xcode 27's
native auxiliary scale planes.[^xcode27-scale-planes]

The affine path is structurally identical:

> ✅ **VERIFIED** — `quantized_nax.h:486-530`, the classic affine unpack (4-bit case):
> ```cpp
> template <typename U, int N, int bits>
> inline void
> dequantize(const device uint8_t* w, U scale, U bias, threadgroup U* w_local) {
> ...
>   else if (bits == 4) {
>     U s[2] = {scale, scale / static_cast<U>(16.0f)};
>     for (int i = 0; i < (N / 2); i++) {
>       w_local[2 * i] = s[0] * (w[i] & 0x0f) + bias;
>       w_local[2 * i + 1] = s[1] * (w[i] & 0xf0) + bias;
>     }
>   }
> ```
> with `Ws` declared as full-precision threadgroup memory at `quantized_nax.h:1230`:
> `threadgroup T Ws[BN * BK_padded];`

The end-to-end pipeline, which is worth memorising:

```
device uint8_t (packed 2/3/4/5/6/8-bit weights)  +  device uint8_t/T (scales, biases)
        │
        │   QuantizedBlockLoader::load_unsafe()      ← dequantization happens HERE, in software
        ▼
threadgroup T (or threadgroup Wtype = bfloat)       ← full-precision tile in shared memory
        │
        │   NAXTile::load()
        ▼
thread registers (NAXTile fragments)
        │
        │   tile_matmad_nax → BaseNAXFrag::mma
        ▼
cooperative_tensor  →  mpp::tensor_ops::matmul2d::run()
```

> ✅ **VERIFIED — the census that proves it.** MLX's *entire* contact surface with MPP TensorOps is
> twelve tokens in four call sites:
> ```
> $ grep -rho 'mpp::[A-Za-z0-9_:]*' mlx/ | sort | uniq -c | sort -rn
>    4 mpp::tensor_ops::matmul2d_descriptor::mode::multiply_accumulate
>    4 mpp::tensor_ops::matmul2d_descriptor
>    4 mpp::tensor_ops::matmul2d
> ```
> Two in `steel/gemm/nax.h`, two in its byte-identical twin `steel/attn/nax.h`. **By the time MPP is
> involved, the weights are plain `half` / `bfloat` / `float`. The op is a dense matmul; it has no
> idea quantization ever happened.**
>
> Accumulation type for the FP path defaults to **bfloat** (`fp_quantized_nax.h:198-204`), so MX and
> NV weights are dequantized to bfloat in threadgroup memory and then matmul'd.

MLX had `int4b_format` available and chose not to use it. The reason is generality, and it is worth
stating because it is the argument for the whole software approach:

> MLX supports 2/3/4/5/6/8-bit affine plus mxfp4/mxfp8/nvfp4 across three block sizes.
> `int4b_format` covers **exactly one** of those eleven configurations, and even then would still
> need scales applied outside the op. The generality isn't there, so MLX skipped the feature.
>
> 🔴 **GAP:** whether `int4b_format` matmuls would actually be *faster* than MLX's
> dequantize-then-dense approach is **unmeasured** — no benchmark exists in this corpus and none was
> run. Do not assert a performance rationale for MLX's choice; assert the generality one, which is
> visible in the code.

### 6.5 The four gates on MLX's accelerated quantized path

Whether you get the NAX kernel or the ordinary one is decided in four independent places, and all
four must pass.

**Gate 1 — shape and layout.**

> ✅ **VERIFIED** — `mlx/backend/metal/quantized.cpp:787, :982, :1327` and
> `quantized_nax.h:952-995`:
>
> | Requirement | Where | Note |
> |---|---|---|
> | `K % 64 == 0` | `quantized.cpp:787`, `:982` | hard gate; otherwise falls back to the non-NAX kernel |
> | `transpose == true` | `quantized.cpp:787`, `:982`, `:1327` | **the NAX quantized path is transposed-B only** |
> | `BK >= SIMD_SIZE` | `quantized_nax.h:952` | `static_assert` |
> | `BK % SIMD_SIZE == 0` | `quantized_nax.h:953` | `static_assert` |
> | **`BK = 64` only for gather** | `quantized.cpp:689` | comment: *"The gather qmm NAX kernels are instantiated with BK = 64 only"* |
> | `BK_padded = BK + 16/sizeof(T)` | `quantized_nax.h:960` | bank-conflict padding |
> | tiles fixed at 64/64/64, `WM = WN = 2` | `quantized_nax.metal:61-81` | every instantiation |

**Gate 2 — build configuration.**

> ✅ **VERIFIED** — `mlx/backend/metal/kernels/CMakeLists.txt:158-182`: NAX kernels are built only
> when **`MLX_METAL_VERSION >= 400`** (Metal 4) **and** macOS SDK ≥ 26.2 **and**
> `CMAKE_OSX_DEPLOYMENT_TARGET >= 26.2`. Otherwise CMake emits a **warning** and defines
> `MLX_METAL_NO_NAX`.
>
> ⚠️ The deployment-target condition is the practical footgun: a default macOS build often targets
> something older and **silently loses every NAX kernel with only a CMake warning**. Upstream PRs
> #3622 ("NAX requires setting `MACOSX_DEPLOYMENT_TARGET=26.2`", merged) and #3824 ("Warn at
> configure time when NAX kernels are disabled", merged) both exist because people hit this.

**Gate 3 — runtime hardware.** `is_nax_available()`, quoted in §5.6.

**Gate 4 — dtype and TF32.**

> ✅ **VERIFIED** — `mlx/utils.h:195-197` and `matmul.cpp:916-918`:
> ```cpp
> inline bool enable_tf32() {
>   static bool enable_tf32_ = get_var("MLX_ENABLE_TF32", 1);   // default ON
>   return enable_tf32_;
> }
>
> bool use_nax = metal::is_nax_available() &&
>     !issubdtype(a.dtype(), complexfloating) &&
>     (env::enable_tf32() || a.dtype() != float32);
> ```
> Identically at `matmul.cpp:2858-2859`, `quantized.cpp:787-788`, `:982-983`, `:1327-1328`.
>
> Read it as: *"use NAX unless the input is float32 and the user has disabled TF32."* It exists
> because `nax.h` hardcodes `relaxed_precision = true`. **`MLX_ENABLE_TF32=0` opts float32 matmuls
> out of the whole NAX path** — the only precision control available, and it is all-or-nothing.
> Complex dtypes are excluded outright.
>
> ⚠️ Upstream PR #3883 ("Warn once when float32 ops silently run at TF32 precision") existed
> because users are being surprised by this — it was **closed unmerged 2026-08-03**, so as of that
> check no runtime warning exists. **This is the MLX analogue of the Core AI silent-fallback
> problem**: a precision reduction that produces correct-looking numbers and announces itself nowhere.

⚠️ NAX is also **not a drop-in accelerator** — it changes which *algorithm* is selected, not just
which kernel implements it. ✅ VERIFIED, `matmul.cpp:924`: the old split-K path is taken only when
NAX is *absent* (`if (!use_nax && batch_size_out == 1 && …)`), while NAX has its own split-K at
`:947`.

### 6.6 What `mlx_lm` layers on top

For completeness, since a lot of practical format choice happens at the `mlx_lm` level rather than
in `mlx.core`:

> ✅ **VERIFIED** — `ml-explore/mlx-lm`:
> - `utils.quantize_model(model, config, group_size, bits, mode="affine", quant_predicate=None)`.
>   The predicate wrapper **skips layers whose `weight.shape[-1] % group_size != 0`** — the same
>   silent-skip shape as `coreai-opt`'s divisibility rule (§2.7), reached by a different route.
> - Per-layer overrides land in `config["quantization"][path]`, and 22 model files ship their own
>   `quant_predicate` property. Example, `models/gpt_oss.py:328`: the `router` gets
>   `{"group_size": 64, "bits": 8}` while everything else takes the global setting.
> - Mixed-precision recipes: `QUANT_RECIPES = ["mixed_2_6", "mixed_3_4", "mixed_3_6", "mixed_4_6"]`,
>   mapping to `(low_bits, high_bits)` pairs. The predicate is llama.cpp-Q4_K_M-like: first and last
>   eighth of layers plus every third in between get high bits, as do `v_proj`-family and
>   `down_proj` in those layers, and `lm_head` **always**.
>   ⚠️ `--quant-predicate` only works with `--q-mode affine`, and requires the model to have
>   `down_proj` modules or it raises `ValueError("Model does not have expected keys for mixed quant.")`.
> - Externally-quantized checkpoints are translated on load: `quant_method == "mxfp4"` →
>   `{"group_size": 32, "bits": 4, "mode": "mxfp4"}`; `compressed-tensors` with
>   `format == "nvfp4-pack-quantized"` → `{"group_size": 16, "bits": 4, "mode": "nvfp4"}`;
>   AWQ/GPTQ 4-bit weights are unpacked, transposed and repacked into MLX layout.
>   ⚠️ Only `bits == 4` is supported for AWQ/GPTQ, and any `*.g_idx` key raises.
> - Activation quantization (`--quantize-activations` / `-qa`) swaps `nn.QuantizedLinear` for
>   `nn.QQLinear` and refuses any mode outside `("nvfp4", "mxfp8")` and any layer with a bias.
> - `mlx_lm.convert` prints `[INFO] Quantized model with {bpw:.3f} bits per weight.`, where
>   `compute_bits_per_weight = model_bytes * 8 / get_total_parameters(model)`. **That one line is the
>   fastest "did my format actually apply" check in the entire stack** (§8.5).

---

## 7. The crossings that silently degrade

This is the section the other five guides cite. Each row is: *you emitted X, the runtime stored Y,
the hardware wanted Z — here is what actually happens, and here is how you would know.*

### 7.1 The lookup table

| # | You did this | What actually happens | Loud or silent? | How you find out |
|---|---|---|---|---|
| 1 | `PerBlockGranularity(block_size=32)` on a weight whose axis isn't a multiple of 32 | The layer is **left uncompressed**; the fake-quant node is removed from the graph | ⚠️ **Silent** (one `logger.warning`) | Divisibility pre-check (§2.7); average bitwidth after |
| 2 | `enable_per_channel_scale=True` on a grouped-channel palette | Lowers to `mps.dequantize_lut` with **rank-6 LUTs**; ANE max rank is 5 → **whole op moves to GPU** | ⚠️ **Silent** | Instruments: empty Neural Engine track (§8.3) |
| 3 | Left an `fp32` tensor operand in an otherwise-fp16 node | Every Python float scalar in that node materialises as an **fp32 constant** → op is fp32 → **not ANE-eligible** | ⚠️ **Silent** | Model viewer: `float32` in **Compute types** (§8.1) |
| 4 | Used an epsilon like `1e-6` that fp16 cannot represent | Same as #3, via the *lossless round-trip* predicate rather than the operand predicate | ⚠️ **Silent** | Same |
| 5 | Called `torch.nn.functional.silu` in an ANE-targeted model | Lowers to `cast(→f32) + swish(f32) + cast(→f16)` — **three ANE-invalid ops** | ⚠️ **Silent** | Model viewer **Operation distribution**: unexpected `cast` count |
| 6 | Left a dynamic dimension in an ANE-targeted function | Fully-static-shape requirement violated → **not ANE-eligible** | ⚠️ **Silent** | Functions tab shows `?` in the shape (§8.1) |
| 7 | Emitted FP8 or FP4 weights and expected ANE execution | ANE has no fp8/fp4 compute path → **GPU or CPU** | ⚠️ **Silent** | Instruments track residency |
| 8 | Emitted int4 weights and expected int4 *arithmetic* | int4 is a **storage** format; the runtime dequantizes to fp16 (ANE) or to `half`/`bfloat` in threadgroup memory (GPU) | ⚠️ **Silent — and usually fine** | Nothing to fix; this is the design |
| 9 | Targeted `ExportBackend.CoreML` with FP8/FP4/int2/MINVAL/per-channel activations | `finalize()` **raises** | ✅ **Loud** | Exception at finalize |
| 10 | Combined two of `{cluster_dim>1, lut_qspec, enable_per_channel_scale}` on CoreML | `CoreMLExportError` | ✅ **Loud** | Exception at finalize |
| 11 | Built MLX with a deployment target below 26.2 | **Every NAX kernel is dropped**; you silently run the older `simdgroup_matrix` path | ⚠️ **Semi-silent** (CMake warning at configure time only) | `MLX_METAL_NO_NAX` in the build; performance |
| 12 | Ran an MLX float32 matmul with `MLX_ENABLE_TF32` at its default | Runs at **TF32 relaxed precision** on the NAX path | ⚠️ **Silent** | Set `MLX_ENABLE_TF32=0` and diff |
| 13 | Quantized an MLX layer whose last dim isn't a multiple of `group_size` | `mlx_lm`'s predicate wrapper **skips the layer** | ⚠️ **Silent** | The `bits per weight` line printed by `convert` |
| 14 | Passed a Python `float` to a Metal-kernel scalar parameter | `scalar_constant()` **bypasses** fp16 promotion deliberately | ✅ Intended behaviour | — |
| 15 | Left an int64 index tensor in the graph | Narrowed to int32 by the converter; values above `INT32_MAX` overflow | ⚠️ **Silent** except where a clamp exists | Range-check indices before export |
| 16 | Called `-inf` for a softmax mask on the ANE | **Wrong numbers** — the hardware does not handle IEEE `-inf` correctly in softmax. Use `-40000.0` | ⚠️ **Silent and incorrect** | Output comparison against the torch reference |
| 17 | Shipped a `.aimodel` whose diffusion components failed quantization | **Failures are swallowed with a warning** (`export/compiler.py:69-72`) | ⚠️ **Silent** | File size on disk vs expectation |
| 18 | Used `AIModel.load(path, None)` or copied `coreai_kit.run` defaults | ⚠️ **Community-measured:** `coreai_kit.run` *defaults to `cpu_only`*, so benchmarks that copy it run on CPU | ⚠️ **Silent** | Instruments; override the options |

Row 17 deserves its own callout because it is the same pathology in a different subsystem:

> ⚠️ **SILENT FAILURE** — ✅ VERIFIED, `apple/coreai-models`, `export/compiler.py:69-72`: **diffusion
> quantization failures are swallowed with a warning.** The export completes, the bundle is written,
> and the component you asked to be compressed is not. Cross-check the on-disk size of each
> `.aimodel` in the bundle against `numel × bits / 8` before you believe a diffusion compression run.

Row 18 is community material and is labelled as such:

> 🟠 **COMMUNITY-MEASURED** — `john-rocky/coreai-model-zoo`, `knowledge/conversion-guide.md`
> (single-author community material with self-declared uncontrolled benchmarks). The measurement:
> `cpu_only()` vs `default()` on a TripoSplat DiT — **24.2 s → 2.6 s per call, ~9.3×** — with
> *"cos vs cpu still 1.000000"*. The landmine, in the author's words: *"`coreai_kit.run` **defaults
> to `cpu_only`**, so apps/benchmarks that copy it silently run on CPU — override it."*
>
> Treat the 9.3× as indicative of the *shape* of the penalty on one unspecified machine, not as a
> reproducible figure. The *mechanism* — a default that pins you to CPU — is verifiable by reading
> the option you pass.

### 7.2 Why none of these throw

It is worth being explicit about the design, because once you see it the whole class of failure
becomes predictable rather than surprising.

The Core AI runtime's contract is: **given an asset, produce correct outputs on this device.** It is
not: *produce correct outputs on the compute unit you had in mind.* Specialization is a
cost-minimising partitioner over compute units, and its documented behaviour when it meets an
incompatible op is to move the op, not to fail.

That is unambiguously the right default for a framework that must run one portable `.aimodel` across
an iPhone, a Vision Pro and a Mac Studio. It also means:

- **There is no error to catch.** The `AssetError.Kind` cases are `corruptedMetadata`,
  `duplicateName`, `invalidFeatureType(String)`, `invalidName`, `unsupportedVersion(String)` —
  ✅ VERIFIED, and none of them is about compute-unit assignment.
- **The `.aimodel` is honest about what it contains**, which is why §8 works: the asset knows its
  storage types and its compute types, and it will tell you both.
- **The only way to know where your model ran is to watch it run.** Hence §8.3.

> 🔴 **GAP — the inference-time error taxonomy.** `AssetError` covers **asset** operations only. The
> errors thrown by `AIModel.init(contentsOf:)`, `loadFunction(named:)`, `run(...)`, `encode(...)` and
> the cache `delete*` methods are **not documented anywhere** across all 312 Core AI symbols. There
> may be a `CoreAIError` that is undocumented, or they may throw `NSError`/`CocoaError`.
>
> **What would resolve it:** an SDK interface dump, or a single `do { … } catch { print(type(of:
> error)) }` on a machine with Xcode 27. **Safe default meanwhile:** catch `AssetError` explicitly
> for asset work, and catch `is Error` generically around `init`/`loadFunction`/`run` — do not write
> a `catch let e as CoreAIError` clause against a type name nobody has seen.

---

## 8. How to check what you actually got

Four tools, in ascending order of effort. Use them in this order.

### 8.1 The Xcode model viewer — compute types vs storage types

Select any `.aimodel` in the Project Navigator. The **General** tab carries the answer to "which
formats are in this asset", split along exactly the axis this guide is about.

> ✅ **VERIFIED** — Apple documentation, *Integrating on-device AI models in your app with Core AI*,
> verbatim: *"The General tab also shows the model's **numeric precision, split into compute and
> storage categories**:
> - **Compute types** are the representations used during inference.
> - **Storage types** are the representations used for the model's weights on disk.
> - The **operation distribution** shows a breakdown of operations in the model's graph, sorted by
>   count."*
>
> The same tab shows size in parameters and bytes, plus editable metadata — *"You can edit metadata
> fields inline; Xcode saves your changes automatically."*

**How to read it.** These three panels answer three different questions, and conflating them is the
mistake:

| Panel | Question it answers | What "bad" looks like |
|---|---|---|
| **Storage types** | Did my compression actually apply? | `float16` where you expected `int4`/`uint4`; a large `float16` count next to a small `int4` count |
| **Compute types** | Will this run where I think? | **`float32` present at all** when you targeted the ANE (§4.1) |
| **Operation distribution** | What did the converter actually build? | Unexpected `cast` ops (§7.1 row 5); `dequantize_lut` where you expected a fused path |

⚠️ **The single most valuable check in this guide is one line long: if you targeted the Neural Engine
and `float32` appears in Compute types, you have a fallback.** It does not tell you *which* op, but
it tells you there is one, in about two seconds, before you ever open Instruments.

The **Functions** tab answers the shape half of the question:

> ✅ **VERIFIED**, verbatim: *"The Functions tab shows the exact function signature of each function
> in the model… **A question mark in an `NDArray` dimension means the dimension is dynamic and is
> supplied or determined at runtime.**"*
>
> So the viewer prints `?` where the API reports `-1`. For an ANE target, **every `?` is a problem**
> (§4.3, fully static shapes).

⚠️ **Prerequisite:** the model viewer requires the **Metal Toolchain**, which is not installed by
default, and its absence is a hard build failure rather than a degraded viewer. See *What you need*.

### 8.2 `AIModelAsset.Summary` — the same data, programmatically

Everything the viewer shows is reachable from code, and — importantly — **without specializing the
model**, so you can run it in CI on a machine that will never execute the model.

> ✅ **VERIFIED** — Apple documentation, `AIModelAsset`: *"Use a model asset to inspect a model's
> structure and metadata **without specializing it for a specific device**. This lets you query model
> information without performing specialization, which is an expensive operation."*
> ```swift
> struct AIModelAsset
> init(contentsOf url: URL) throws
> static func isValid(at url: URL) -> Bool
> var metadata: AIModelAsset.Metadata { get }
> var url: URL { get }
> func summary(includingStatistics: Bool) throws -> AIModelAsset.Summary?
> mutating func updateMetadata(_ updates: (inout AIModelAsset.Metadata) throws -> Void) throws
> mutating func removeDerivedArtifacts() throws
> ```
> ```swift
> struct Summary
> var computeTypes: [String] { get }
> var storageTypes: [AIModelAsset.Summary.StorageType] { get }
> var operationDistribution: [AIModelAsset.Summary.OperationCount] { get }
> var functions: [AIModelAsset.FunctionDescriptor] { get }
>
> struct StorageType    { var typeName: String { get }; var count: Int { get } }
> struct OperationCount { var operationName: String { get }; var count: Int { get } }
> ```

⚠️ **Note the asymmetry**: `storageTypes` and `operationDistribution` carry counts;
**`computeTypes` is a bare `[String]` with no count.** So you can ask *"is float32 present in the
compute set"* but not *"how much of the model computes in float32."* That is a real limitation of the
API and it is why §8.3 exists.

⚠️ Also note the cost switch: `includingStatistics: false` returns *"only version information and
function signatures"*, and *"Including model statistics is **considerably slower for large
models**."* ✅ VERIFIED, parameter documentation.

A CI-friendly gate built only from verified members:

```swift compile:27
import CoreAI
import Foundation

struct NumericFormatReport {
    let computeTypes: [String]
    let storageTypes: [(name: String, count: Int)]
    let topOperations: [(name: String, count: Int)]
    let dynamicDimensionCount: Int
}

enum FormatCheckError: Error {
    case noProgramBytecode
    case unexpectedComputeType(String)
}

/// Inspect an .aimodel WITHOUT specializing it. Safe to run on any machine, including CI.
func inspectFormats(at url: URL) throws -> NumericFormatReport {
    let asset = try AIModelAsset(contentsOf: url)

    // `summary` returns nil when no program bytecode exists.
    guard let summary = try asset.summary(includingStatistics: true) else {
        throw FormatCheckError.noProgramBytecode
    }

    // A dynamic dimension is reported as -1 by the API and as "?" in the Xcode viewer.
    // Count them: for an ANE target, any non-zero count is disqualifying.
    var dynamicCount = 0
    for function in summary.functions {
        for value in function.inputs + function.outputs + function.states {
            // ValueDescriptor exposes `name` and `typeName` (a String, not a typed enum),
            // so the shape check below is textual by necessity — see the GAP note under this listing.
            if value.typeName.contains("-1") { dynamicCount += 1 }
        }
    }

    return NumericFormatReport(
        computeTypes: summary.computeTypes,
        storageTypes: summary.storageTypes.map { ($0.typeName, $0.count) },
        topOperations: summary.operationDistribution
            .sorted { $0.count > $1.count }
            .prefix(10)
            .map { ($0.operationName, $0.count) },
        dynamicDimensionCount: dynamicCount
    )
}

/// The one-line ANE gate. Fails the build if the asset will fall back.
func assertNoFloat32Compute(at url: URL) throws {
    let report = try inspectFormats(at: url)
    if let offender = report.computeTypes.first(where: { $0.localizedCaseInsensitiveContains("float32") }) {
        throw FormatCheckError.unexpectedComputeType(offender)
    }
}
```

> 🔴 **GAP — the exact strings.** `Summary.computeTypes` is `[String]` and
> `Summary.StorageType.typeName` is `String`; **Apple documents neither the vocabulary nor the
> spelling** of those strings. `"float32"` above is the *plausible* spelling given
> `NDArray.ScalarType.float32`, but it could equally be `"Float32"`, `"f32"` or `"fp32"`.
> `AIModelAsset.ValueDescriptor.typeName` has the same problem and is explicitly noted in the docs as
> *"a String, not a strongly-typed enum"*.
>
> **What would resolve it:** printing `summary.computeTypes` for any one real asset. One line, one
> machine with Xcode 27. **Safe default meanwhile:** write the check with
> `localizedCaseInsensitiveContains` as above rather than `==`, print the arrays the first time you
> run it, and pin the literal to what you actually observe before relying on it. **Do not ship a
> `==` comparison against a string nobody has seen.**

### 8.3 Instruments — the residency check

The model viewer tells you what is *in* the asset. Instruments tells you where it *ran*. For the
silent-fallback class of failure, only the second one is conclusive.

> ✅ **VERIFIED** — Apple documentation, *Analyzing model runtime performance with Instruments*.
> Recording: **Product > Profile**, choose the **Core AI** template. Template description string:
> *"Core AI: Monitors an application's machine learning activity executed through Core AI."*
>
> The template contains **four instruments** (this list is a DocC `termList` that sosumi.ai drops;
> recovered from Apple's raw JSON):
> - **Core AI** — *"Captures timing information for activity in the Core AI framework across all four
>   event categories (Specialization, Load, Setup, and Inference)."*
> - **Neural Engine** — *"Captures activity on the Neural Engine, **so you can correlate Core AI
>   events with the hardware that runs them**."*
> - **GPU** — *"Captures and shows activity on the GPU during the trace."*
> - **Time Profiler** — *"Profiles running threads on all cores at regular intervals for all
>   processes."*
>
> Track hierarchy: *"The **top track shows all activity**. Expand it to reveal **a child track for
> each active model**, and expand a model's track to reveal **a child track for each of its active
> functions**."* Default function name: `main`. Naming convention: `model::function`.

**The residency check, in three steps:**

1. Record with the Core AI template on a **real device**.
2. Expand the Core AI track down to the function you care about, and note when its **Inference**
   events (blue) occur.
3. Look at the **Neural Engine** track over the same interval. If your function's inference window
   shows no Neural Engine activity, **your model is not running on the ANE**, whatever the asset says.

The four event categories, with their colours and their meaning — also a dropped `termList`,
recovered:

> ✅ **VERIFIED**, listed *"in the order they typically appear"*:
> - **Specialization** (green) — *"Runtime specialization of the model for the target device
>   architecture. **Only appears for models that aren't specialized ahead of time.**"*
> - **Load** (cyan) — *"Preparation of the model for loading into memory."*
> - **Setup** (magenta) — *"Preparation of the model before each inference."*
> - **Inference** (blue) — *"A single, complete inference from the model."*
>
> And three operational rules stated outright:
> *"**Specialization events are often the most time-intensive operations during model runtime. Each
> model produces at most one Specialization event — none if the model is fully specialized for the
> device or already cached.**"* · *"[Load events] occur **only at the start of runtime**… **If you
> see frequent Load events during runtime, check that your app doesn't reload models repeatedly.**"*
> · *"**A Setup event precedes each inference.**"*

Concrete labels you will see, useful for recognising the UI: `Compile Asset, Specialize` with a
nested `Compile segment`; `Load model::main (10.54 μs)`; `Setup for model::main (66.96 μs)` with a
nested `Context.alloc (22.83 μs)`; `Run main`; `Run streaming function func_19`. ✅ VERIFIED from the
screenshots in Apple's article — note that `func_19` implies specialized graphs get auto-generated
sub-function names.

Two profiling hygiene rules Apple states, both of which matter for format work specifically:

> ✅ **VERIFIED**: *"Profile on a **real device** for the most accurate performance data."* and
> *"For the most actionable results, **run your app on its own. Other apps competing for CPU, GPU, or
> Neural Engine resources can distort the trace.**"*

**The debug gauge** is the lighter-weight sibling and has one prerequisite worth knowing:

> ✅ **VERIFIED** — *Monitoring model performance with the debug gauge*: ⚠️ **the gauge requires a
> direct link to `CoreAI.framework`.** If your app reaches Core AI only transitively (through a
> package), the gauge does not appear.
>
> 🔴 **GAP:** the gauge surfaces **three** event types where Instruments has four — `Setup` is
> missing. Whether `Setup` is folded into the gauge's `Inference` measurement (which would inflate
> it) is undocumented. **Safe default:** use Instruments for any number you intend to quote.

### 8.4 Metal System Trace — the neural-accelerator utilisation counter

For GPU-path work specifically, there is a counter that answers "is the matrix hardware doing
anything at all", and it is the most direct format-efficiency signal available.

> ✅ **VERIFIED** — Tech Talk 111432, the recipe verbatim: build (⌘B) → launch Instruments (⌘I) →
> choose the **Metal System Trace** template → select the **performance limiters counter set** →
> record. Then expand the **M5 Metal Device events** track; use the **track filter** to find and pin
> the **neural accelerator utilization** counter.
>
> Division of labour between the two tools, in Apple's words: Metal System Trace gives *"a quick
> **system level** view… great for **rapid iteration and understanding the big picture**"*, while the
> Xcode Metal debugger *"**isolates just your GPU work and removes outside system activity**"* for
> deep dives.
>
> Practical tip from the same talk: capture *"a GPU trace of **a single K loop iteration**"* — it
> *"keeps the capture small while preserving the performance characteristics we care about."*

The instruction-mix reading is a good verification technique in its own right: *"in this **v1**
example, which uses SIMD group matrix, **the majority of our instruction types are math**. In this
**v3** example, **almost all of the instructions are being executed by neural accelerators**."*

### 8.5 The cheap checks

Not everything needs a profiler. In rough order of speed:

| Check | Cost | What it catches |
|---|---|---|
| **Bytes on disk.** Compare the `.aimodel` directory size against `Σ numel × bits / 8` plus scale overhead (§2.7 formula) | seconds | Silent skips (#1, #13, #17) |
| **`mlx_lm.convert`'s `bits per weight` line** | free | MLX silent skips, immediately |
| **`coreai_opt.inspection.ModelInspector`** — host-side, pre-export op/module tree with `get_matched_ops_for_op_type` / `_op_name` / `_module_name` (`re.fullmatch`) | seconds | Config scoping that matched nothing |
| **Model viewer Compute types** | seconds | fp32 anywhere (#3, #4, #5) |
| **Model viewer Functions tab for `?`** | seconds | Dynamic shapes on an ANE target (#6) |
| **`AIModelAsset.Summary` in CI** | seconds | Regressions in any of the above |
| **Instruments Core AI + Neural Engine tracks** | minutes, real device | Residency — the ground truth (#2, #7, #18) |
| **Metal System Trace, neural-accelerator counter** | minutes, M5 | GPU-path format efficiency |

And one CLI lever worth knowing when the model viewer looks right and the model still runs on CPU:

> ✅ **VERIFIED** — `apple/coreai-models`, `skills/model-authoring/references/common_issues.md`:
> ```
> xcrun coreai-build compile model.aimodel --preferred-compute neural-engine
> ```
> listed under *"when the model runs on CPU"*.
>
> ✅ **GAP — RESOLVED 2026-07-31:** `xcrun coreai-build compile --help` has now been run (the tool
> ships in the Metal Toolchain component, not Xcode-beta.app; capture in
> `notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`). The flag list: `--output`, `--platform`,
> `--min-deployment-version`, `--architecture` (repeatable; 24 valid codes enumerated by probing,
> `h18p` among them), `--expect-frequent-reshapes`, and **`--preferred-compute` takes
> `{gpu, neural-engine, none}` — hyphenated `neural-engine`, exactly as the line above spells it**
> (default `none`). **Safe default unchanged:** prefer `SpecializationOptions(
> preferredComputeUnitKind: .neuralEngine)` at runtime, where the enum spelling is documented
> (`ComputeUnitKind` = `.cpu`, `.gpu`, `.neuralEngine`), and treat the CLI flag as a build-time
> optimisation you verify by hand.

---

## 9. Decision tables by target

### 9.1 Pick a format by where you want it to run

| Target | Weights | Activations | Granularity | Cast pass | Why |
|---|---|---|---|---|---|
| **ANE, iOS LLM** | 4-bit k-means palette, `per_grouped_channel`, `axis=0`, `group_size` 8 or 32; embedding **8-bit per-tensor**, excluded from the palette | leave alone | grouped-channel | `cast_to_16_bit_precision` | Apple's own `4bit_weight_palettized_group32` preset (§4.5) |
| **ANE, vision / segmentation** | Per-function: heavy encoders palettized 4–6 bit, detector **uncompressed fp16** | leave alone | grouped-channel | fp16 | Apple's SAM3 recipe (§4.4) |
| **GPU, macOS LLM** | int4, `symmetric_with_clipping`, `per_block(block_size=32, axis=1)`; MoE expert weights `block_size=[1,1,1,32]` | leave alone | per-block | fp16 | Apple's `4bit` macOS preset (§4.5) |
| **GPU, weight+activation int8** | int8 per-channel | int8 per-tensor, calibrated | per-channel weights, per-tensor activations | fp16 | The W_INT8-A_INT8 execution path (§2.5) |
| **Palettized + activation-quantized** | palette with `lut_qspec=int8` | int8 | grouped-channel | fp16 | **A float LUT forces float ops** (§2.5); CoreAI backend only |
| **CoreML back-compat** | int8/uint8/int4/uint4 only, `ZP` only | int8/uint8, per-tensor only | as constrained | — | The CoreML restriction matrix (§2.8) |
| **MLX, general** | affine 4-bit, `group_size=64` | — | group | — | `mode_defaults["affine"] = (64, 4)` |
| **MLX, MX interop** | `mxfp4` (32, 4) for gpt-oss-class checkpoints | — | group 32 | — | `quant_method == "mxfp4"` translation (§6.6) |
| **MLX, activation-quantized** | `nvfp4` (16, 4) or `mxfp8` (32, 8) | quantized on the fly via `QQLinear` | group 16 / 32 | — | `qqmm` supports only these two (§6.3) |

### 9.2 Pick a compression *technique* by what you are compressing

| Situation | Technique | Reason |
|---|---|---|
| Weight-only, ≥ 8 bits, no time | Data-free PTQ quantization | Seconds; `presets.w8()` |
| Weight-only, 4–6 bits, ANE target | K-means palettization, per-grouped-channel | 🟠 community-measured: at per-channel, k-means beats quantization by **~15–19 dB** at both 8 and 4 bits (§11) |
| Weight+activation | Quantization in **GRAPH** mode with calibration | Palettization is eager-only and weight-only; activations need observers |
| ≤ 4 bits and quality matters | **QAT** | 🟠 community-measured and Apple-echoed: *"int4 is a cliff, not a slope"* |
| A model that won't `torch.export` | EAGER mode, weight-only | *"the fallback when a model is not exportable"* |
| An `.aimodel` and no PyTorch model | `coreai_opt.coreai_utils` | Apple's own docs call this the non-preferred path |
| Already-quantized HF checkpoint into MLX | Let `mlx_lm` translate it | `mxfp4` / `nvfp4-pack-quantized` / AWQ / GPTQ all have handlers (§6.6) |

### 9.3 The LM head and the embedding are their own decision

Every LLM decision table needs this row broken out, because the head is usually the single largest
tensor in the model and behaves unlike everything around it.

> 🟠 **COMMUNITY-PUBLISHED** — `john-rocky/coreai-model-zoo`,
> `knowledge/compression-reference.md` (single-author community material with self-declared
> uncontrolled benchmarks; the *reasoning* is checkable, the numbers are not replicated): the head is
> `vocab × hidden` — **262,144 × 1,536** for Gemma 4 — *"largest single tensor, high sensitivity,
> needs **per-row (per-output-channel)** scales for matmul efficiency."* And the closing implication,
> which is a format-availability argument: *"an int4 head needs a **kernel** path, not `coreai-opt`'s
> `F.linear` quantizer."*

Corroboration from Apple's own shipped presets, which is the part you should actually act on:
**the iOS presets exclude `Embedding` and `LoadEmbeddings` from palettization entirely and quantize
the embedding 8-bit per-tensor instead** (§4.5, ✅ VERIFIED). Whatever you conclude about the head,
Apple treats the embedding as a separate problem with a separate format — and so should you.

Related mechanical constraint, ✅ VERIFIED from the same community source's reading of the API:
k-means palettizes **`F.linear` / `F.conv` weights only**, so RMSNorm and RoPE parameters stay at
full precision whether you wanted that or not — which happens to be the right answer (§4.5, point 1)
but is a consequence of the op registry rather than a choice you made.

### 9.4 Ahead-of-time compilation does not change the format question

`coreai-build` moves compilation to your build machine. It does **not** change which formats run
where, and it introduces a hardware gate people miss.

> ✅ **VERIFIED** — Apple documentation, *Compiling Core AI models ahead of time*:
> ```shell
> % xcrun coreai-build compile MyModel.aimodel --platform iOS --min-deployment-version 27.0 --output compiled/
> ```
> ⚠️ **NOTE, verbatim:** *"Ahead-of-time compilation only compiles for devices that support Apple
> Intelligence, including **iPhone or iPad with the A17 Pro chipset or later, a Mac with the M1
> chipset or later, or Apple Vision Pro with the M2 chipset or later**."*
>
> Output naming: one `.aimodelc` per architecture, `MyModel.<arch>.aimodelc`, where `<arch>` is
> `AIModel.deviceArchitectureName`. ⚠️ And the caveat that keeps expectations honest: *"**Even with
> ahead-of-time compilation, the compiled asset still requires some specialization on the device.**
> The amount of compilation that remains depends on the model and the compute units it uses."*

So AOT reduces the green **Specialization** band in Instruments; it does not eliminate a fallback,
and it will not turn an fp32 op into an ANE op.

> 🔴 **GAP — the set of `deviceArchitectureName` values.** There is no documented enumeration.
> `h18p` (iPhone 17 Pro) is a third-party claim only. **What would resolve it:** printing
> `AIModel.deviceArchitectureName` on each device you support. **Safe default meanwhile:** read it at
> runtime and build the asset filename from it, exactly as Apple's own sample line does — never
> hardcode an architecture string.

---

## 10. ⚠️ Silent failures, consolidated

Everything in this guide that produces a working, wrong-in-some-way result without an error, in one
place. The **type** column matters: *slower* means correct numbers on the wrong compute unit;
*larger* means a compression step did nothing; *wrong* means the numbers are actually incorrect.

| # | Failure | Type | Layer | Detect with |
|---|---|---|---|---|
| S1 | Block size doesn't divide the weight dim → layer left uncompressed, FQ node removed | larger | `coreai-opt` | Divisibility pre-check; average bitwidth |
| S2 | Palettization granularity mismatch → module permanently disabled, parametrization removed | larger | `coreai-opt` | Same |
| S3 | `enable_per_channel_scale=True` → rank-6 LUT → ANE rejects (max rank 5) → GPU | slower | asset → ANE | Instruments Neural Engine track |
| S4 | An fp32 operand contaminates a node → every float scalar in it becomes an fp32 constant | slower | converter → ANE | Model viewer **Compute types** |
| S5 | An epsilon fp16 can't round-trip (e.g. `1e-6`) → fp32 constant | slower | converter → ANE | Same |
| S6 | `F.silu` lowering to `cast + swish(f32) + cast` — 3 ANE-invalid ops | slower | converter → ANE | **Operation distribution** |
| S7 | Any dynamic dimension on an ANE-targeted function | slower | asset → ANE | Functions tab shows `?` |
| S8 | Diffusion quantization failure **swallowed with a warning** (`export/compiler.py:69-72`) | larger | `coreai-models` export | On-disk size |
| S9 | int64 narrowed to int32; values above `INT32_MAX` overflow | **wrong** | converter | Range-check before export |
| S10 | `-inf` softmax mask on the ANE — hardware mishandles it; must be `-40000.0` | **wrong** | ANE | Output diff vs the torch reference |
| S11 | NE readonly KV caching *pre*-RoPE keys → *"PSNR collapses to ~20 dB"* | **wrong** | model authoring | PSNR gate |
| S12 | MLX built with deployment target < 26.2 → all NAX kernels dropped | slower | MLX build | CMake warning; `MLX_METAL_NO_NAX` |
| S13 | MLX float32 matmul silently running at TF32 | precision | MLX runtime | `MLX_ENABLE_TF32=0` and diff |
| S14 | `mlx_lm` quantize predicate skipping non-divisible layers | larger | `mlx_lm` | The `bits per weight` line |
| S15 | `coreai_kit.run` defaulting to `cpu_only` (🟠 community-reported) | slower | app code | Instruments; read the options you pass |
| S16 | `.chunked` KV cache strategy accepted but **silently falls back** to `StaticKVCache` | slower | `coreai-models` Swift | Read the source; no runtime signal |
| S17 | A `module_type_configs` key that isn't fully qualified matches nothing | larger | `coreai-opt` | `ModelInspector`; average bitwidth |
| S18 | `__HAVE_TENSOR__` undefined → the whole MPP header expands to nothing | build | Metal | "no member named matmul2d" 300 lines later |

S11 and S16 come from the shipped Swift and Python of `apple/coreai-models` and are ✅ VERIFIED
against that source; S15 is 🟠 community-reported and labelled as such throughout.

**The pattern, stated once.** Fifteen of these eighteen are *"the thing you asked for did not happen,
and the system continued."* That is not carelessness in the frameworks — it is the correct behaviour
for a portable-asset, per-device-specialization architecture, and for a compression library that must
not crash a six-hour QAT run because one layer had an awkward shape. But it means **the burden of
verification is entirely on you**, and it is why §8 is the longest section in this guide.

---

## 11. Numbers, attributed

Every number here carries its source class, its hardware and its date where known. Nothing in this
section is presented as an Apple figure unless Apple published it.

### 11.1 Apple-published

| Number | Context | Source |
|---|---|---|
| **0% neural-accelerator utilisation** for the SIMD-group-matrix path on M5 | 4K×4K matmul, "same hardware" | Tech Talk 111432 |
| **~2 s → ~0.5 s → ~0.33 s** across kernel v1 / v2 / v3 (SIMD-group matrix → TensorOps → TensorOps + Morton order) | Same 4K×4K matmul; *"almost seven times faster"* end to end | Tech Talk 111432 |
| **> 50%** then **close to 100%** neural-accelerator utilisation for v2 and v3 | Same | Tech Talk 111432 |
| **Matmul up to 4–8× faster, "depending on precision"** | M5; baseline unstated | Tech Talk 111432 |
| **Time to first token up to 4× faster** (prefill, *"thanks to the neural accelerators"*); **token generation up to 25% faster** (decode, from *"increased memory bandwidth and larger GPU caches"*) | M5; context M4→M5. Observed on Qwen3 and gpt-oss | Tech Talk 111432 |
| **~4× image generation** vs **M4**; **7.7× video enhancement** vs **M1** | Draw Things on iPad Pro M5; Topaz Video on 14" MacBook Pro M5 | Tech Talk 111432 |
| **76% faster second inference** from splitting SAM3 into three entrypoints | Session 325 | WWDC26 325 |
| PSNR acceptance bands: **float32 e2e > 70 dB** (investigate < 60); **fp16 on-device > 50 dB** (investigate < 40); **4-bit palettized ~40 dB** (investigate < 30) | Apple's own agent skill | `apple/coreai-models` |
| Verification gates: re-authored vs source **> 70 dB**; NE-layout vs GPU-layout **> 70 dB**; compiled vs torch **≥ 40 dB**; after 4-bit palettization **≥ 35 dB** | Same | `apple/coreai-models`, `model-authoring/SKILL.md:94-99` |
| Palettization sizing: 8-bit ≈ **2×** / **> 55 dB** (flag < 50); 4-bit ≈ **4×** / **~40 dB** (flag < 35); 2-bit ≈ **8×** / **25–35 dB**, *"usually unacceptable"* | Same | `apple/coreai-models`, `:149-153` |
| Singleton last axis on the ANE costs **32× memory at fp16, 64× at int8** | ANE layout rules | `apple/coreai-models`, `neural_engine_rules.md` |
| ResNet50 PTQ, 128 eval samples from imagenette: fp32 **78.12%**; W_INT8/A_INT8 with `moving_average` **74.22%**; same with `global_minmax` **75.78%**; **W_FP8_E4M3 / A_FP8_E4M3** with `global_minmax` **76.56%** | `coreai-opt` docs | `docs/src/examples/resnet50.md` |

⚠️ **The baselines differ per claim** in the M5 talk — M4 for images, M1 for video. Any citation of
those two numbers must carry its baseline or it is meaningless.

⚠️ The ResNet50 row is the most directly useful of these for format choice: on that model,
**FP8 E4M3 weights *and* activations beat int8 weights + int8 activations by ~0.8–2.3 points**. It is
one model, 128 eval samples, from a documentation example — not a general result. But it is the only
first-party FP8-vs-int8 comparison in the corpus, and it points the opposite way from the folk
wisdom that FP8 is only for training.

### 11.2 Community-measured — attribute, do not launder

All of the following are from `john-rocky/coreai-model-zoo`, **single-author community material with
self-declared uncontrolled benchmarks**. The numbers are frequently unique — nobody else has
published Core AI MoE decode rates — and they must never be presented as Apple figures.

| Number | Context | Caveats |
|---|---|---|
| **int8 39 tok/s (8.8 GB) → int4 170 tok/s (5.0 GB)** on LFM2.5-8B-A1B | *"the first direct Core-AI int4-vs-int8 MoE measurement"*; effective BW 345 → 848 GB/s, the latter **above physical bandwidth**, proving int4 is not full-reading | Superlinear in the byte ratio (~4× for a 1.76× size drop). Hardware not stated for this row |
| **int8 MoE 39 → 141 tok/s (3.6×)** with a custom `gather_qmm` Metal kernel; **int4km 162.7 tok/s at 4.7 GB**; **~32 tok/s** for int4km on **iPhone 17 Pro (A19 Pro) GPU** | M4 Max for the Mac rows, 2026-06-13 | Kernel is bit-exact vs "select-from-all"; quality is set by the *scheme*, not the gather |
| Flips per 41 tokens vs an fp32 oracle: `sym8` **+1**, k-means int8 **+5**, affine-block-32 int4 **+11**, k-means int4 **+12** | LFM2.5-8B-A1B | *"int4 is a WALL … non-QAT int4 can't reach clean (needs QAT weights)"* |
| **The rule reverses for top-1 routing.** `sym8` wins for top-k ≥ 4; for **top-1 of 16** (ZAYA1-8B) `sym8` collapses and **`km8` recovers fp16 quality** | 2026-06-22 | Mechanism given: expert-quant error averages as ~1/√k across k experts; at k=1 it doesn't |
| Quantization scheme deltas: at int8 sym-vs-asym gap **~1.5 dB**; at int4 asymmetric gains **+3–5 dB**, `symmetric_with_clipping` **+7 dB** | — | Consistent with Apple choosing `symmetric_with_clipping` at int4 (§4.5) |
| At per-channel granularity, **k-means beats quantization by ~15–19 dB** at both 8 and 4 bits; per-tensor palettization can be **worse** than per-channel quantization | — | Consistent with Apple using palettization for the iOS/ANE path and quantization for macOS/GPU |
| Skipping boundary (first/last) layers can add **up to +9 dB** | — | *"always ablate"* |
| Scale + zero-point overhead **5–15%** at 2–4 bit fine granularity; at `block_size=16` + int4 the **effective width is ~5 bits** | Arithmetic, not a benchmark | Safe to reuse |
| **Per-channel (axis-0) int8 Linear weights return garbage on the macOS-27-beta MPSGraph GPU delegate** — torch-level numerics clean, lowered matmul wrong. Minimal head-only repro 2026-06-11, multiple shapes, symmetric and clipping alike. Workaround: **use per-block-32 there** | macOS 27 beta | ⚠️ A **wrong-numbers** beta bug, not a fallback. If you are on a 27 beta and per-channel int8 looks broken, this is a known report |
| **On GPU, int8 is *not* faster** than fp16 — *"weights dequant to fp16 for compute"*; the win is memory | — | Exactly the §5/§6 mechanism, observed from the outside |
| Sizes: Gemma 4 E2B core **7.0 GB fp32 → 3.5 GB fp16 → 1.9 GB int8**; Qwen3.5-0.8B **969 MB**; Qwen3.5-2B **2.2 GB** (fp16 embedding + int8 transformer, single bundle) | — | Useful as sizing anchors only |

The two rows worth carrying into your own decisions, because they change what you would otherwise
conclude:

1. **"int8 is not faster than fp16 on the GPU"** is the practical statement of this guide's thesis.
   Low-bit storage buys you *bandwidth*, not *arithmetic*, unless something downstream can actually
   compute in that format. On the GPU, nothing can — every quantized weight is dequantized to
   `half`/`bfloat` before the matmul (§6.4). The exception in the same source is instructive: the
   custom `gather_qmm` kernel *is* faster at low bit width, *"precisely because the custom kernel
   avoids the dequant-everything"* path.
2. **The top-k reversal.** A quantization scheme that is measurably correct on a top-4 MoE can
   collapse on a top-1 MoE, because the error no longer averages across experts. Any "use scheme X"
   rule you inherit needs its routing width attached.

### 11.3 Explicitly not measured here

- No M5 hardware was available for any TensorOps claim in §5. **Every conclusion about NAX in this
  guide is static analysis of headers and source.** Nothing was compiled or run.
- No comparison exists anywhere in this corpus between `int4b_format` matmuls and MLX's
  dequantize-then-dense approach (§6.4). Do not assert one is faster.
- No latency or quality number is published for **any non-LLM model** in `apple/coreai-models`.
  ✅ VERIFIED — `Tools/benchmark` is actually `llm-benchmark` and imports `CoreAILanguageModels`;
  there is no non-LLM benchmark tool in the repo.

---

## 12. Quick reference

### 12.1 The one-page answer

```
EMIT  (coreai-opt)      int8 int4 int2 uint8 uint4 uint2 fp8_e4m3 fp8_e5m2 fp4_e2m1
                        + E8M0 scales (FP4 always; FP8 optionally)
                        + palettes at 1/2/3/4/6/8 bits, LUT in int8/uint8/fp8_e4m3/fp8_e5m2
                        - CoreML backend: int8/uint8/int4/uint4 only, ZP only, per-tensor activations

STORE (NDArray.ScalarType)
                        float16 float32 float64 bfloat16
                        float8e4m3fn float8e5m2 float4e2m1fn float8e8m0fn
                        cfloat16 cfloat32 cfloat64
                        int8 int16 int32 int64 int128 / uint8 uint16 uint32 uint64 uint128
                        int2 int3 int4 int5 int6 int7 / uint1 uint2 uint3 uint4 uint5 uint6 uint7
                        bool
                        -> sub-byte and 8-bit-float cases are readable from Swift ONLY via RawView

COMPUTE (ANE)           fp16, int8, int16.  Everything else -> GPU or CPU, silently.
                        + rank <= 5, static shapes, 64-byte-aligned contiguous last axis,
                          -40000.0 not -inf in softmax masks

COMPUTE (MPP TensorOps) float / half / bfloat + int8_t uint8_t int32_t uint32_t
                        + metal::int4b_format / metal::uint4b_format  (RIGHT OPERAND ONLY)
                        NO scale mechanism at any width.  MX/NV formats are software.
                        Ladder: 26.0 intro | 26.1 bfloat | 26.3 coop-tensor inputs | 26.4 int4/int8
                        SDK macro: __TENSOR_OPS_SUPPORT_DEPLOYMENT_TARGET_26_2

EMIT  (MLX)             affine 2/3/4/5/6/8 bits x group 32/64/128 (7 excluded)
                        mxfp4 (32,4,e8m0) | mxfp8 (32,8,e8m0) | nvfp4 (16,4,e4m3)
                        qqmm (activations too): nvfp4 and mxfp8 ONLY
                        Gates: K%64==0, transposed-B only, BK=64 for gather,
                               deployment target >= 26.2, arch gen >= 17 (18 for 'p'),
                               MLX_ENABLE_TF32 for float32
```

### 12.2 Verify-before-you-ship checklist

```
[ ] Divisibility: every target weight dim % block_size == 0        -> §2.7
[ ] Average bitwidth moved as expected                             -> §2.7 formula
[ ] Model viewer > General > Storage types matches your config     -> §8.1
[ ] Model viewer > General > Compute types has NO float32
    (if you are targeting the ANE)                                 -> §8.1
[ ] Model viewer > General > Operation distribution has no
    unexpected cast / dequantize_lut ops                           -> §8.1
[ ] Model viewer > Functions has no "?" dimensions
    (if you are targeting the ANE)                                 -> §8.1
[ ] AIModelAsset.Summary check wired into CI                       -> §8.2
[ ] Instruments Core AI template on a REAL DEVICE: the Neural
    Engine track is non-empty during your Inference events         -> §8.3
[ ] PSNR / task metric against the float reference, at the gates
    Apple publishes (>70 dB re-authored, >=40 dB compiled,
    >=35 dB after 4-bit palettization)                             -> §11.1
[ ] For MLX: the "bits per weight" line from convert is what
    you expected                                                   -> §6.6
```

### 12.3 Symbols named in this guide, with their homes

| Symbol | Where it lives | Marker |
|---|---|---|
| `QuantizationSpec` (`dtype`, `qscheme`, `qformulation`, `granularity`, `scale_dtype`, …) | `coreai_opt.quantization.spec` | ✅ |
| `PalettizationSpec` (`n_bits`, `lut_qspec`, `granularity`, `cluster_dim`, `enable_per_channel_scale`) | `coreai_opt.palettization.spec` | ✅ |
| `PerTensorGranularity` / `PerChannelGranularity` / `PerBlockGranularity` | `coreai_opt.quantization.spec.granularity` | ✅ |
| `PerGroupedChannelGranularity` | `coreai_opt.palettization.spec` | ✅ |
| `ExportBackend.CoreAI` / `.CoreML` | `coreai_opt.common` | ✅ |
| `cast_to_16_bit_precision` / `cast_fp32_to_fp16` / `cast_int32_to_int16` | `coreai_opt.casting` | ✅ |
| `DType` / `QScheme` / `CompressionGranularity`, `quantize_weights` / `palettize_weights` / `sparsify_weights` | `coreai_opt.coreai_utils` | ✅ |
| `ModelInspector` | `coreai_opt.inspection` | ✅ |
| `NDArray`, `NDArray.ScalarType`, `NDArray.View` / `MutableView` / `RawView` / `MutableRawView`, `NDArray.InterleaveLayout` | `CoreAI` (Swift), 27.0 | ✅ |
| `AIModelAsset`, `.Summary` (`computeTypes`, `storageTypes`, `operationDistribution`, `functions`) | `CoreAI`, 27.0 | ✅ |
| `SpecializationOptions` (`default`, `cpuOnly`, `preferredComputeUnitKind`, `allowedComputeUnitKinds`, `expectFrequentReshapes`) | `CoreAI`, 27.0 | ✅ |
| `ComputeUnitKind` = `.cpu` / `.gpu` / `.neuralEngine`, `availableKinds` | `CoreAI`, 27.0 | ✅ |
| `AssetError.Kind` = `corruptedMetadata` / `duplicateName` / `invalidFeatureType(String)` / `invalidName` / `unsupportedVersion(String)` | `CoreAI`, 27.0 | ✅ |
| `AIModel.deviceArchitectureName` | `CoreAI`, 27.0 | ✅ |
| `xcrun coreai-build compile … --platform --min-deployment-version --output --preferred-compute` | Xcode 27 + Metal Toolchain | ✅ (flag values ✅ 2026-07-31: `--preferred-compute {gpu, neural-engine, none}`) |
| `__tensor_ops_datatype`, `metal::int4b_format` / `uint4b_format`, `mpp::tensor_ops::matmul2d` | MetalPerformancePrimitives, 26.x | ✅ |
| int2/FP4/FP8/E8M0 `MTLTensorDataType` and `metal::*_format` operands | Metal / MPP, OS 27 | ✅[^xcode27-scale-planes] |
| `mx.quantize` / `dequantize` / `quantized_matmul` / `gather_qmm` / `qqmm` / `to_fp8` / `from_fp8` | `mlx.core` | ✅ |
| `nn.quantize`, `nn.QuantizedLinear`, `nn.QuantizedEmbedding`, `nn.QQLinear` | `mlx.nn` | ✅ |
| `fp8_e8m0` / `fp8_e4m3` / `fp4_e2m1` | **MLX's own compatibility structs** in `fp8.h` / `fp4.h`; OS 27 also has distinct Metal FP4/FP8 formats | ✅[^xcode27-scale-planes] |
| A vended Swift type for `.int4` / `.uint1` / `.float8e4m3fn` | **does not exist in the documented surface** | 🔴 |
| `NDArray.ScalarType.type` | referenced by `RawView.view(as:)`'s docs; absent from the symbol index | 🔴 |
| `.coreaimodel`, `.aiasset`, `coreai-torch convert`, an on-device LoRA training API | **fabricated — do not use** | ❌ |
| `MTLTensorAuxiliaryPlaneDescriptor`, `MTLTensorDescriptor.auxiliaryPlanes` | Metal, OS 27 | ✅[^xcode27-scale-planes] |

---

## 13. Sources and evidence ledger

### 13.1 Primary sources, ranked

**Tier 1 — source and headers on disk.** The strongest evidence available for this topic, and the
reason §5 and §6 can be stated flatly.

| Source | What it settles |
|---|---|
| `MetalPerformancePrimitives.framework/Headers/` in the **Xcode 26.6 SDK (Build 17F113)** — ~14,300 lines including ~320 lines of Apple prose. `MPPTensorOpsTypes.h`, `MPPTensorOpsMatMul2d.h`, `MPPTensorOpsAvailability.h`, `MPPTensorOpsUtility.h`, `MPPTensorOpsMatMul2dImpl.h` | The 26.x baseline dtype set (§5.1–5.3) and availability macro (§5.4); not evidence about OS 27 additions |
| Xcode 27 `Metal.framework/Headers/MTLTensor.h` and `MetalPerformancePrimitives.framework/Headers/__impl/MPPTensorOpsTypes.h` | int2/FP4/FP8/E8M0 datatypes, auxiliary scale-plane descriptors and shader-side TensorOps mappings (§5.1–5.5)[^xcode27-scale-planes] |
| The Metal toolchain's language headers (`metal_tensor`, `metal_cooperative_tensor`, `__exec/units.h`), cryptex-mounted — locate with `xcrun -sdk macosx --find metal`, **never hardcode the path** | `metal::int4b_format`, the tensor/cooperative-tensor types |
| `apple/coreai-optimization` (`coreai-opt` **0.2.1**, 2026-07-02, plus some behaviour from `main` at `cd95cb2`) | The whole of §2 |
| `apple/coreai-torch` (`_type_mapping.py`, `_utils.py`, converter constant emission) | §3.4, §3.5, §4.2 |
| `ml-explore/mlx` (shallow clone, HEAD `973e27f`): `quantized_nax.h`, `fp_quantized_nax.h`, `fp8.h`, `fp4.h`, `steel/gemm/nax.h`, `device.cpp`, `quantized.cpp`, `matmul.cpp`, `utils.h`, `kernels/CMakeLists.txt` | The whole of §6 |
| `ml-explore/mlx-lm` (`utils.py`, `convert.py`, `quant/`) | §6.6 |
| `apple/coreai-models` — the Swift and Python tree plus **Apple's own vendored agent skills** (`model-authoring`, `neural_engine_rules.md`, `gpu_rules.md`, `common_issues.md`, `model-compression-exploration`) | The whole of §4; the presets in §4.5 |

**Tier 2 — Apple documentation.** `/documentation/coreai/*`: the framework page, `NDArray`,
`NDArray.ScalarType`, `NDArray.InterleaveLayout`, `AIModelAsset` and `.Summary`,
`SpecializationOptions`, `ComputeUnitKind`, `AssetError`, and the five articles — *Integrating
on-device AI models*, *Managing model specialization and caching*, *Compiling Core AI models ahead of
time*, *Analyzing model runtime performance with Instruments*, *Monitoring model performance with the
debug gauge*.

⚠️ **Methodology note worth reusing.** Fetching `sosumi.ai` directly preserves verbatim signatures
that page-summarization tools may omit — but **sosumi silently drops DocC `termList` and `table` blocks**.
When a page ends a sentence with "…are:" followed by nothing, refetch
`https://developer.apple.com/tutorials/data/documentation/<path>.json` and parse it directly. Two of
the most valuable passages in §8 — the four Instruments instruments and the four event categories —
were recovered exactly that way and exist nowhere in the sosumi rendering.

**Tier 3 — Apple video.** WWDC26 session **325** (*Dive into Core AI model authoring and
optimization*) and Apple Tech Talk **111432** (*Accelerate your machine learning workloads with the
M5 and A19 GPUs*, presented by Zak of the GPU Driver Performance team). ⚠️ 111432 is a **Tech Talk,
not a WWDC26 session** — it predates WWDC26, it is what session 330 means by *"the M5 machine
learning talk"*, and it is not listed on the WWDC26 machine-learning guide page, which is why
searching WWDC26 for it fails. It has **no published code-sample block**; symbol names from it carry
transcription risk and are marked 🟡 wherever used.

**Tier 4 — community, always labelled.** `john-rocky/coreai-model-zoo`
(`knowledge/compression-reference.md`, `knowledge/conversion-guide.md`) — single-author community
material with self-declared uncontrolled benchmarks. Used in §7.1 row 18, §9.3 and §11.2, always
attributed inline. Upstream MLX pull requests #3622, #3824, #3853, #3883 are cited as evidence that a
behaviour surprises people, not as documentation.

### 13.2 Where sources disagree, and who wins

| Conflict | Resolution |
|---|---|
| Session 325 says `coreai-opt` supports *"int4, int8, FP4 and FP8"*; the source supports **nine** dtypes including int2/uint2 | **Source wins.** §2.1 |
| Session 330 describes `MTLTensor` **scale planes** with E8M0 `blockFactors` and an auxiliary plane map | **Xcode 27 headers corroborate it.** The earlier contradiction came from searching only Xcode 26.6 and only the older MPP surface (§5.5).[^xcode27-scale-planes] |
| Session 330 says int2, FP4 and FP8 tensor types are new in iOS/macOS 27 | **Xcode 27 corroborates it** through `MTLTensorDataType` and the feature-gated MPP type mappings (§5.1, §5.4). |
| Our own earlier register said "TensorOps availability is **26.2**"; the M5 talk's ladder is 26.0 → 26.1 → 26.3 → 26.4 and **never mentions 26.2** | **Report both, they are about different things** (§5.4). Do not print a single blanket version |
| Session 325 says the SAM3 encoders use per-channel scales; the shipped code sets `enable_per_channel_scale=False` because `True` produces rank-6 LUTs the ANE rejects | **Shipped code wins**, and both readings of the discrepancy are stated rather than smoothed over (§4.2) |
| Apple's framework page lists macOS for Core AI; every symbol page omits it | **Docs bug.** Treat macOS 27 as supported and flag the inconsistency (§3.1) |
| `coreai_opt.coreai_utils.__all__` omits `QScheme`, but the docs import it from the package root | **Unresolved.** Import it from `coreai_opt.coreai_utils.common` if the package-root import fails |

### 13.3 Open gaps declared in this guide

| § | Gap | What would resolve it |
|---|---|---|
| 3.2 | **No `BitwiseCopyable` Swift type for sub-byte or 8-bit-float scalar types**; `ScalarType.type` is referenced but absent from the symbol index | SDK interface dump (`swiftc -print-module -module-name CoreAI`) or an Apple forum answer |
| 3.4 | The palette **index-plane** `ScalarType` mapping is inferred, not documented | Open a palettized `.aimodel` in the model viewer and read Storage types |
| 4.1 | **bfloat16 on the ANE** — Apple's rule file names fp16/int8/int16 and is silent on bf16 | Export a bf16 model with `--platform iOS`; read the Instruments Neural Engine track |
| 5.2 | `int16`/`uint16` are in `__tensor_ops_datatype` but have **no Metal-type branch** in the quoted mapping function | `grep short MPPTensorOpsUtility.h` |
| 5.3 | Only the ten **4-bit** operand triples are reproduced; the `int8 × int8 → int32` row is implied, not quoted | Read `MPPTensorOpsMatMul2d.h:13-61` |
| 5.6 | What **"NAX"** stands for | — (do not expand it in prose) |
| 6.4 | Whether `int4b_format` matmuls are faster than MLX's dequantize-then-dense path | A benchmark on M5 hardware |
| 7.2 | The **inference-time error taxonomy** — nothing documents what `AIModel.init` / `loadFunction` / `run` throw | SDK dump, or one `catch { print(type(of: error)) }` |
| 8.2 | The **exact strings** in `Summary.computeTypes` / `StorageType.typeName` / `ValueDescriptor.typeName` | Print them once for a real asset |
| 8.3 | Why the debug gauge shows **three** event types where Instruments shows four (`Setup` missing) | — |
| 8.5 | ~~The full `coreai-build compile` flag list and the spelling of `--preferred-compute` values~~ **CLOSED 2026-07-31** — `--help` captured via the Metal Toolchain component; values `{gpu, neural-engine, none}` (`notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`) | — |
| 9.4 | The complete set of `deviceArchitectureName` mappings (compiler-accepted set: 24 codes, `h11p…h18p`; first project hardware anchor 2026-08-20: iPhone 15 Pro `iPhone16,1` / `D83AP` reports `h16p`) | Print it per device; never hardcode |
| 11.3 | No M5 hardware for any TensorOps claim; no non-LLM performance data anywhere in `apple/coreai-models` | Hardware |

### 13.4 Related guides

- [`01-quantization.md`](01-quantization.md) — the `coreai-opt` quantization API in depth: configs,
  GRAPH vs EAGER, calibration, QAT, the SAM3 story. This guide's §2 is the format surface only.
- The palettization guide in this part — k-means, `cluster_dim`, sensitivity-based clustering.
- **Part 8** — conversion: `torch.export`, `get_decomp_table()`, `TorchConverter`, `optimize()`,
  `save_asset()`. Everything between "compressed `nn.Module`" and "`.aimodel`".
- **Part 7** — the Core AI Swift runtime: `AIModel`, `InferenceFunction`, `NDArray` in anger,
  specialization and caching.
- **Part 10** — hardware authoring and debugging: the Core AI Debugger, PSNR workflows, custom Metal
  kernels, LLM deployment. §8 here is format inspection; Part 10 is numerics debugging.
- **Part 11** — Metal and TensorOps for kernel authors. §5 here is the dtype surface only.
- **Parts 12 and 13** — MLX in Python and Swift. §6 here is the quantization surface only.

---

*Last verified 2026-07-27 against: `coreai-opt` 0.2.1 · `apple/coreai-models` and `apple/coreai-torch`
at the commits recorded in the research corpus · `ml-explore/mlx` HEAD `973e27f` · the Xcode 26.6
baseline and Xcode 27 Metal/MPP headers · Apple's Core AI and Metal documentation pages · WWDC26
sessions 325 and 330 · Apple Tech Talk 111432.*

[^xcode27-scale-planes]: Apple’s OS 27 API reference documents the scale-plane descriptor, the tensor
    descriptor’s auxiliary-plane map, and the new tensor datatypes:
    [`MTLTensorAuxiliaryPlaneDescriptor`](https://developer.apple.com/documentation/metal/mtltensorauxiliaryplanedescriptor),
    [`MTLTensorDescriptor.auxiliaryPlanes`](https://developer.apple.com/documentation/metal/mtltensordescriptor/auxiliaryplanes), and
    [`MTLTensorDataType`](https://developer.apple.com/documentation/metal/mtltensordatatype).
    The automatic-dequantization and custom-format fallback are both stated in the authoritative
    [WWDC26 session 330 transcript](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/transcripts/wwdc2026-330.txt#L53-L78).

[^sample-routing-policy]: The classifier and preferences are implemented in the optional
    `apple/coreai-models` package’s pinned
    [`ModelStructure.swift`](https://github.com/apple/coreai-models/blob/5ed9981303b38d5a44aa6b45509bc4f6945029f5/swift/Sources/CoreAIShared/Runtime/ModelStructure.swift#L12-L218).
    Core AI’s `.default` behavior is documented separately in
    [Managing model specialization and caching](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/docs/Managing%20model%20specialization%20and%20caching.md).

[^scalar-type-count]: Apple’s current `NDArray.ScalarType` reference enumerates the 35 cases grouped
    in §3.1: [Apple Developer — `NDArray.ScalarType`](https://developer.apple.com/documentation/coreai/ndarray/scalartype-swift.enum).
