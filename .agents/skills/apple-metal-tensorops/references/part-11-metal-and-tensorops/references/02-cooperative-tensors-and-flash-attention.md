# Cooperative tensors, reductions, and building a fused attention kernel

**Part 11 · Metal and TensorOps · Reference 02**

**Version floor.** The cooperative-tensor kernel API in this guide is **macOS 26 / iOS 26 point
releases and later**. TensorOps shipped in **26.0**; **bfloat** tensor element types arrived in **26.1**; **cooperative
tensors as `matmul2d` *inputs*** — the single capability this whole guide is built on — arrived in
**26.3**; **4-bit and 8-bit integer tensors** arrived in **26.4**. That ladder is Apple's own, spoken
in Tech Talk 111432. Separately, the `MetalPerformancePrimitives` headers shipped in the **Xcode 26.6**
SDK annotate their deployment gate as **26.2**. Both facts are true and they describe different
things; §0.2 reconciles them. Xcode 27 separately adds native multiplane quantized tensors and int2,
FP4, FP8, and E8M0 formats — present shader-side in the macOS 27.0 beta SDK's MPP headers, behind a
new 27.0 deployment gate (§0.2, §0.3).[^metal27-multiplane] You also need **Metal 4** (`__METAL_VERSION__` ≥ 400) and a toolchain
that defines `__HAVE_TENSOR__`, or the entire header expands to nothing and you get a baffling
"no member named `matmul2d`" instead of a missing-feature error.

Everything below runs on **every Apple GPU from M1 onward** — Apple states the API is portable and
falls back to optimised shader implementations on GPUs without neural accelerators. The M5-class
hardware path is a fast path, not a requirement.

---

## What this covers

This is the advanced kernel-authoring guide for Metal TensorOps. Guide 01 in this part covers the
ground floor — `metal::tensor`, the three descriptor tags, `matmul2d_descriptor`, execution scopes,
the dtype table, and the quantisation story. This guide picks up where that stops and covers the
three things you need in order to write a *fused* kernel rather than a sequence of separate ones:

- **Cooperative tensors** — what it means for a tensor's storage to be "distributed across the
  private memory of the participating threads," why that is the difference between a kernel that
  round-trips an intermediate through threadgroup memory and one that never leaves registers, and
  the three lifetime rules that will bite you.
- **The template-parameter asymmetry that is the #1 compile failure.**
  `get_left_input_cooperative_tensor` and `get_right_input_cooperative_tensor` take **element**
  types. `get_destination_cooperative_tensor` takes **operand** types. The error message will not
  tell you this. §3 gives correct and incorrect side by side.
- **Runtime layout compatibility.** `is_compatible_as_left_input` / `is_compatible_as_right_input`
  return a **runtime `bool`**, not a `constexpr` one, and you are expected to branch on them. The
  documented fallback when they return false is a store/reload through threadgroup memory.
- **Reductions.** `reduce_rows` is a **free function**, not a member. `reduction_operation` has
  **exactly three cases**. And its `identity` parameter defaults to `sum_identity` — **zero** —
  *regardless of the operation you pass*, which means `reduction_operation::max` silently clamps
  every negative value to zero. That is the ⚠️ **SILENT FAILURE** of this guide and it lands
  squarely on softmax.
- **`map_iterator`** — the mechanism for pairing an element of a 2-D cooperative tensor with the
  corresponding element of a differently-shaped reduction destination, and its guard
  `is_iterator_compatible`.
- **A step-by-step FlashAttention walkthrough**, assembled in the order WWDC26 session 330 assembles
  it: custom simdgroup mapping → slice by simdgroup ID → Q@Kᵀ into registers → row-max reduction →
  `map_iterator` softmax in place → feed the result straight into the second matmul against V.
- **The integration story** — how session 330 got exactly this kernel into a SAM3 segmentation model
  from Python, via a `TorchMetalKernel` and a monkey-patched Hugging Face attention implementation.
- **What MLX does instead**, and why an expert would reasonably decline every portable API in this
  guide.

## What this does *not* cover

- **The basics.** `metal::tensor<ElementType, Extents, Descriptor, Tags...>`, `tensor_handle` /
  `tensor_offset` / `tensor_inline`, `.slice()` / `.static_slice()`, the full `matmul2d_descriptor`
  positional argument list, the 13-entry dtype enum (transcribed in full in
  `notes/repos/mlx-tensorops-kernels.md` §8) and the ~50 legal operand triples (69 in the
  macOS 27.0 beta SDK — guide 01 §0.2): guide 01 in
  this part. This guide assumes them and cites them where it leans on them.
- **Quantised matmul in depth.** Xcode 27 has a documented host-side scale-plane mechanism, and the
  macOS 27.0 beta SDK carries its shader-side half in the MPP headers (guide 01 §0.2); in-kernel
  custom dequantisation remains the fallback for 26.x targets and custom formats. Guide 01 and §0.3
  distinguish the two paths.[^metal27-multiplane]
- **`convolution2d`.** `MPPTensorOpsConvolution2d.h` exists (177 lines public + 4,914 lines of
  implementation) and was not read for this series.
- **Host-side Metal 4 encoding.** `MTL4MachineLearningCommandEncoder`, `MTLTensor` allocation,
  residency sets. §10 covers only the one host-side fact you cannot write a correct kernel without:
  how threads-per-threadgroup must agree with your execution scope.
- **Getting a Metal kernel into a Core AI asset.** §12 sketches the hand-off;
  [Part 8 guide 3 — *Custom Metal kernels*](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md)
  is the full treatment of `TorchMetalKernel`.

## What you need

- **Xcode 26.6 or later**, and a deployment target that satisfies whichever rung of the feature
  ladder you are standing on (§0.2). If you use cooperative tensors as matmul *inputs* — which is
  the entire point of this guide — that rung is **26.3**.
- **The headers, open in a second window.** They are the normative source, they ship on your
  machine, and they contain roughly 320 lines of Apple-authored prose with four complete worked
  examples. Paths in §0.1. Any disagreement between this guide and those files: the files win.
- **A device to test on.** Every claim in this guide is static analysis against headers and shipping
  source. Nothing here was compiled or executed for this series, and no M5-class hardware was
  available. Treat reconstructed snippets as skeletons and validate them against a CPU reference.
- **Guide 01 of this part**, read first.

---

## Contents

- [§0 — Evidence, versions, and where the files are](#0--evidence-versions-and-where-the-files-are)
  - [0.1 The two header roots](#01-the-two-header-roots)
  - [0.2 The version ladder, and the 26.2 annotation](#02-the-version-ladder-and-the-262-annotation)
  - [0.3 The 26.x fallback and Xcode 27 multiplane path](#03-the-26x-fallback-and-xcode-27-multiplane-path)
  - [0.4 How to read the evidence markers in this guide](#04-how-to-read-the-evidence-markers-in-this-guide)
- [§1 — Why cooperative tensors exist](#1--why-cooperative-tensors-exist)
- [§2 — What a cooperative tensor actually is](#2--what-a-cooperative-tensor-actually-is)
  - [2.1 The type](#21-the-type)
  - [2.2 Apple's own definition, and the three rules it implies](#22-apples-own-definition-and-the-three-rules-it-implies)
  - [2.3 Where it lives in the namespace hierarchy](#23-where-it-lives-in-the-namespace-hierarchy)
- [§3 — The asymmetry: element types vs operand types](#3--the-asymmetry-element-types-vs-operand-types)
  - [3.1 The three getters, quoted](#31-the-three-getters-quoted)
  - [3.2 The table you should tape to your monitor](#32-the-table-you-should-tape-to-your-monitor)
  - [3.3 Wrong, and why the compiler will not help you](#33-wrong-and-why-the-compiler-will-not-help-you)
  - [3.4 Right — MLX's shipping call site](#34-right--mlxs-shipping-call-site)
  - [3.5 The named type aliases, if you dislike `decltype`](#35-the-named-type-aliases-if-you-dislike-decltype)
- [§4 — Feeding a cooperative tensor into a matmul](#4--feeding-a-cooperative-tensor-into-a-matmul)
  - [4.1 The SFINAE clause that settles it](#41-the-sfinae-clause-that-settles-it)
  - [4.2 The conversion overloads](#42-the-conversion-overloads)
  - [4.3 `is_compatible_as_left_input` — a runtime bool you must branch on](#43-is_compatible_as_left_input--a-runtime-bool-you-must-branch-on)
  - [4.4 The documented fallback](#44-the-documented-fallback)
- [§5 — Reading and writing elements](#5--reading-and-writing-elements)
  - [5.1 The public member surface](#51-the-public-member-surface)
  - [5.2 `get_capacity` + `get_mask`: the idiomatic loop](#52-get_capacity--get_mask-the-idiomatic-loop)
  - [5.3 `get_multidimensional_index`](#53-get_multidimensional_index)
  - [5.4 `load` / `store`](#54-load--store)
  - [5.5 ⚠️ Cooperative tensors are not zero-initialised](#55-️-cooperative-tensors-are-not-zero-initialised)
- [§6 — Reductions](#6--reductions)
  - [6.1 `reduce_rows` is a free function](#61-reduce_rows-is-a-free-function)
  - [6.2 `reduction_operation` has exactly three cases](#62-reduction_operation-has-exactly-three-cases)
  - [6.3 ⚠️ SILENT FAILURE — the identity default](#63-️-silent-failure--the-identity-default)
  - [6.4 Pre-shaped reduction destinations](#64-pre-shaped-reduction-destinations)
  - [6.5 The shared-`ElementType` constraint](#65-the-shared-elementtype-constraint)
  - [6.6 `reduce_columns`](#66-reduce_columns)
- [§7 — `map_iterator` and `is_iterator_compatible`](#7--map_iterator-and-is_iterator_compatible)
  - [7.1 What problem it solves](#71-what-problem-it-solves)
  - [7.2 The declaration](#72-the-declaration)
  - [7.3 Which object you call it on](#73-which-object-you-call-it-on)
  - [7.4 `is_iterator_compatible`, and Apple's buggy example](#74-is_iterator_compatible-and-apples-buggy-example)
- [§8 — Building FlashAttention, step by step](#8--building-flashattention-step-by-step)
  - [8.0 The shape of the problem](#80-the-shape-of-the-problem)
  - [8.1 Step 1 — a custom simdgroup mapping](#81-step-1--a-custom-simdgroup-mapping)
  - [8.2 Step 2 — slice input tiles by simdgroup ID](#82-step-2--slice-input-tiles-by-simdgroup-id)
  - [8.3 Step 3 — QK transpose into a cooperative tensor](#83-step-3--qk-transpose-into-a-cooperative-tensor)
  - [8.4 Step 4 — the row-max reduction](#84-step-4--the-row-max-reduction)
  - [8.5 Step 5 — `map_iterator` and softmax in place](#85-step-5--map_iterator-and-softmax-in-place)
  - [8.6 Step 6 — the second matmul, against V](#86-step-6--the-second-matmul-against-v)
  - [8.7 What the six steps leave out](#87-what-the-six-steps-leave-out)
- [§9 — The assembled kernel](#9--the-assembled-kernel)
- [§10 — The host side you cannot skip](#10--the-host-side-you-cannot-skip)
- [§11 — The expert escape hatch: what MLX does instead](#11--the-expert-escape-hatch-what-mlx-does-instead)
- [§12 — Getting the kernel into a model](#12--getting-the-kernel-into-a-model)
- [§13 — ⚠️ Freshness: NAX is new and still settling](#13--️-freshness-nax-is-new-and-still-settling)
- [§14 — Performance: the three things that actually move the number](#14--performance-the-three-things-that-actually-move-the-number)

---

## §0 — Evidence, versions, and where the files are

There is a specific reason this guide opens with a bibliography rather than with code. WWDC26
session 330 — *"Optimize custom machine learning operations with Metal tensors"* — described this
API **in speech only**. There is no published code-sample block on that session's page for the
FlashAttention material. A guide written from the narration alone will contain plausible-looking
identifiers that do not exist, and a set of them was in circulation before the headers were located.

The headers are on your machine. They are the normative source. Read them.

### 0.1 The two header roots

TensorOps is **two layers in two different places**, and readers who miss that flounder immediately,
because the symbols they need are split across two namespaces from two shipping locations.

**Layer 1 — the framework** (`namespace mpp::tensor_ops`). Ships inside Xcode:

```
/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/
  MacOSX.sdk/System/Library/Frameworks/MetalPerformancePrimitives.framework/Headers/
```

| File | Lines | What is in it |
|---|---:|---|
| `MetalPerformancePrimitives.h` | 12 | umbrella; includes the two op headers |
| `MPPTensorOpsMatMul2d.h` | 642 | **the public API**: `matmul2d_descriptor`, `matmul2d`, `reduce_rows`, `reduce_columns`, `reduction_operation`, `reduction_operation_identity`, `is_iterator_compatible` — plus ~320 lines of Apple prose and four worked examples |
| `MPPTensorOpsConvolution2d.h` | 177 | `convolution2d` |
| `__impl/MPPTensorOpsAvailability.h` | 12 | the deployment-target macro |
| `__impl/MPPTensorOpsTypes.h` | 150 | `__tensor_ops_datatype`, address-space enum, descriptor-type enum |
| `__impl/MPPTensorOpsTraits.h` | 135 | the type traits `run()`'s SFINAE is written against |
| `__impl/MPPTensorOpsMatMul2dImpl.h` | 8,963 | implementation and the exhaustive dtype dispatch |

**Layer 2 — the language** (`namespace metal`). Does **not** ship inside `Xcode.app`. It lives in a
cryptex-mounted Metal toolchain:

```
/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v17.6.109.0.iAeIa2/
  Metal.xctoolchain/usr/metal/32023/lib/clang/32023.883/include/metal/
```

| File | Lines | What is in it |
|---|---:|---|
| `metal_tensor` | 2,204 | `metal::tensor`, the three descriptor tags, the `is_*_v` traits |
| `metal_cooperative_tensor` | 584 | **`metal::cooperative_tensor`**, its iterators, `map_iterator`, `get_capacity`, `get_multidimensional_index` |
| `__exec/units.h` | ~190 | `execution_threads<N>`, `execution_simdgroups<N>`, and the aliases |

> ⚠️ **Never hardcode that second path.** The component `MetalToolchain-v17.6.109.0.iAeIa2` is
> build-specific and **will differ on every machine**. Resolve it:
>
> ```bash
> xcrun -sdk macosx --find metal
> # then walk up to .../Metal.xctoolchain/usr/metal/<ver>/lib/clang/<ver>/include/metal/
> ```
>
> Searching `Xcode.app/Contents/Developer/Toolchains/` for these files finds nothing — that
> directory contains only `XcodeDefault.xctoolchain`. This is the single most common reason a
> developer concludes "cooperative tensors aren't in my SDK."

The practical consequence for your source file: **two includes, two namespaces.**

```cpp
// ✅ VERIFIED — this is the include MLX uses, at
// mlx/backend/metal/kernels/steel/gemm/nax.h:12
#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>

// the language half comes in transitively, but be explicit if you touch
// metal::cooperative_tensor members directly:
#include <metal_tensor>
#include <metal_cooperative_tensor>
```

> 🟡 **RECONSTRUCTED — defensive include.** MLX includes the MPP umbrella header unconditionally,
> and upstream PR **#3853** ("Guard NAX MetalPerformancePrimitives include behind `__has_include`",
> open as of 2026-07-16) exists precisely because a bare include is a hard build break on toolchains
> without the framework. If your kernel source might be compiled by a toolchain you do not control —
> and if you are embedding MSL into a Core AI asset (§12), it might — guard it:
>
> ```cpp
> #if __has_include(<MetalPerformancePrimitives/MetalPerformancePrimitives.h>)
> #  include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>
> #  define MY_KERNEL_HAVE_TENSOROPS 1
> #endif
> ```
>
> The `__has_include` spelling is standard C++; what is reconstructed here is only the
> recommendation to apply it, which comes from an open MLX PR rather than from Apple.

### 0.2 The version ladder, and the 26.2 annotation

This is the part most often written wrong, in both directions. There are **two independent facts**
and they get collapsed into one number.

**Fact one — Apple's narrated feature ladder.** ✅ **VERIFIED**, quoted from Tech Talk 111432,
*"Accelerate your machine learning workloads with the M5 and A19 GPUs"* (presenter: Zak, GPU Driver
Performance):

> *"We introduced TensorOps at [WWDC] 25 in the combined metal for machine learning and graphics
> session. … Since we introduced TensorOps, we've continued expanding the API in iOS and Mac OS 26.
> In **26.1**, we added **bfloat tensor support**, critical for modern ML models that use Bfloat16.
> In **26.3**, we added support for **cooperative tensors as inputs to matmul**. This lets you build
> custom dequantization routines inside your kernel, essential for running quantized models
> efficiently. And in **26.4**, we added **four bit and eight bit integer tensors**, so quantized
> models can fully leverage neural accelerators."*

| Version | What it added | Relevance to this guide |
|---|---|---|
| **26.0** (WWDC25 session 262) | TensorOps introduced | `matmul2d`, cooperative tensors as *destinations* |
| **26.1** | `bfloat` tensor element types | dtype availability only |
| **26.2** | *nothing named in the ladder* | — |
| **26.3** | **cooperative tensors as `matmul2d` *inputs*** | **§4 and §8.6 do not exist below this** |
| **26.4** | 4-bit and 8-bit integer tensor element types | guide 01's territory |

**Fact two — the shipped header's gate.** ✅ **VERIFIED**, `__impl/MPPTensorOpsAvailability.h:10`,
quoted verbatim from the Xcode 26.6 SDK:

```c
#define __TENSOR_OPS_SUPPORT_DEPLOYMENT_TARGET_26_2 ((__ENVIRONMENT_OS_VERSION_MIN_REQUIRED__) >= 260200)
```

So the header names **26.2** while the ladder skips it. Both are true. They are answering different
questions: the macro is a per-symbol deployment gate inside the shipped SDK, and the ladder is
Apple's public description of which OS release added which capability. Do not print a single blanket
number and do not claim the two contradict each other.

**What to write in your own build settings.** The load-bearing rung for this guide is **26.3**,
because §4, §8.6 and §9 all pass a cooperative tensor into `run()` as an *input*. Below 26.3 you can
still write everything through §3 — cooperative tensors as matmul *destinations* have been there
since 26.0 — but the fusion in §8.6 becomes a store-and-reload through threadgroup memory, which is
exactly the fallback §4.4 documents.

> 🔴 **GAP — per-symbol availability annotations.** We have the framework-wide macro
> (`…_DEPLOYMENT_TARGET_26_2`) and we have Apple's spoken ladder. What we do **not** have is a
> per-symbol `@available`-style annotation on
> `get_left_input_cooperative_tensor(src)` / `is_compatible_as_left_input` that would let you assert
> "this exact overload is 26.3." The Xcode 26.6 SDK ships all of them together behind one macro.
> The macOS 27.0 beta SDK was checked on 2026-07-29: still no per-symbol annotations — it *adds* a
> second framework-wide macro, `__TENSOR_OPS_SUPPORT_DEPLOYMENT_TARGET_27_0`
> (`MPPTensorOpsAvailability.h:11`), gating the new scale-aware ABI (guide 01 §1.2), and leaves the
> 26.2 gate untouched.
> **What would resolve it:** a diff of `MPPTensorOpsMatMul2d.h` across the 26.0, 26.1, 26.3 and 26.4
> SDKs, or an Apple documentation page carrying per-symbol availability.
> **Safe default:** set `MACOSX_DEPLOYMENT_TARGET` / `IPHONEOS_DEPLOYMENT_TARGET` to **26.3** if you
> use cooperative tensors as matmul inputs, and gate at runtime with `__builtin_available` before
> selecting the pipeline — see §10.3 for the pattern MLX uses.

**The compiler feature macros are a separate gate, and they fail silently.** ✅ **VERIFIED**,
`MPPTensorOpsMatMul2d.h:328`:

```cpp
#if defined(__METAL_VERSION__) && defined(__HAVE_TENSOR__)
```

If `__HAVE_TENSOR__` is not defined, **the entire header expands to nothing**. There is no `#error`.
You get an empty `mpp::tensor_ops` namespace and a downstream diagnostic that reads "no member named
`matmul2d` in namespace `mpp::tensor_ops`" — which reads like a typo, not like a missing feature.
Related macros seen in the same headers: `__HAVE_BFLOAT__`, `__HAVE_INT4B_FORMAT_TYPE__`
(`MPPTensorOpsTypes.h:106,112`), `__HAVE_EXECUTION_UNIT__` (`__exec/units.h:9`).

MLX's build system encodes the same three conditions in CMake — ✅ **VERIFIED**,
`mlx/backend/metal/kernels/CMakeLists.txt:158-182`:

```cmake
  if(MLX_METAL_VERSION GREATER_EQUAL 400
     AND MACOS_SDK_VERSION VERSION_GREATER_EQUAL 26.2
     AND CMAKE_OSX_DEPLOYMENT_TARGET VERSION_GREATER_EQUAL 26.2)
    build_kernel(steel/attn/kernels/steel_attention_nax ${STEEL_NAX_ATTN_HEADERS})
    # ... and the gemm / quantized kernels
  else()
    message(WARNING "NAX kernels require Metal 4, macOS SDK >= 26.2, and "
                    "MACOSX_DEPLOYMENT_TARGET >= 26.2 ...")
    target_compile_definitions(mlx PRIVATE MLX_METAL_NO_NAX)
  endif()
```

> ⚠️ **SILENT FAILURE — the deployment-target trap.** A default macOS build often targets something
> older than 26.2. When it does, MLX emits a **CMake warning** and drops every accelerated kernel
> from the build. Nothing fails. The library still works; it is simply slower, on a code path you
> never asked for. Two upstream PRs exist because people hit this — **#3622** ("NAX requires setting
> `MACOSX_DEPLOYMENT_TARGET=26.2`", merged 2026-06-04) and **#3824** ("Warn at configure time when
> NAX kernels are disabled", merged 2026-07-09). If you build a Metal 4 kernel into your own
> project, add an explicit configure-time check rather than assuming the default is right.

### 0.3 The 26.x fallback and Xcode 27 multiplane path

Read this before choosing a representation, because the answer depends on the SDK and deployment
floor.

**Xcode 27 has a native scale-plane mechanism, host-side and — as of the 27.0 beta SDK —
shader-side.** `MTLTensorAuxiliaryPlaneDescriptor` configures a plane's data type and
`blockFactors`, `MTLTensorDescriptor.auxiliaryPlanes` attaches the plane map, and the current
data-type enum includes int2, FP4, FP8, and E8M0.[^metal27-dtypes] On the shader side, the macOS
27.0 beta SDK's MPP headers (checked 2026-07-29) extend the `matmul2d` support matrix with
`int2b`/`uint2b`, `metal_fp4_e2m1_format`, `metal_fp8_e4m3_format` and `metal_fp8_e5m2_format`
operands (`MPPTensorOpsMatMul2d.h:62-83`, 27.0 SDK) and accept a blockwise
`metal::tensor_plane_scales` plane of `metal_fp8_ue8m0_format` scale factors — block size 32, left
operand untransposed, right operand transposed, never on the destination
(`__impl/MPPTensorOpsMatMul2dImpl.h:6241-6316`, 27.0 SDK; the full contract is in guide 01 §0.2).
The Xcode 26.6 shader-side snapshot inspected for this guide did not contain that surface:

1. ✅ **VERIFIED, version-scoped absence** — case-insensitive searches for `scale`, `plane`, `block_factor`,
   `blockFactor`, `fp8`, `fp4`, `e8m0`, `e4m3`, `quant` and `aux` across all ~14,300 lines of MPP
   headers and all 2,788 lines of that 26.6 `metal_tensor` + `metal_cooperative_tensor` snapshot
   returned **zero hits**. This does not describe Xcode 27.
2. ✅ **VERIFIED by counter-implementation** — MLX, written by Apple, against the same headers, for
   the same hardware, hand-dequantises in software (`QuantizedBlockLoader::load_unsafe` →
   `threadgroup T* dst`) and never passes a sub-byte tensor to `matmul2d`. Its `fp8_e8m0`,
   `fp8_e4m3` and `fp4_e2m1` are **MLX's own structs** in `fp8.h` / `fp4.h`, not Metal types.
3. ✅ **VERIFIED fallback** — Tech Talk 111432 devotes a segment to the 26.x quantisation path. When
   it reaches "how do you run quantized models," it names the 26.3
   cooperative-tensor-as-input feature and says it *"lets you build custom dequantization routines
   inside your kernel."* In that fallback, you dequantise into registers yourself.

This matters here and not only in guide 01, because it reframes what cooperative tensors are *for*.
They are not only a convenience for post-processing a GEMM result. They are the 26.x/custom-format
dequantisation mechanism and exactly what a fused attention kernel needs. On a 27.0 floor, prefer
the native multiplane representation for its supported formats; keep this cooperative-tensor path
when you need older deployment or custom layout/control.[^metal27-multiplane]

### 0.4 How to read the evidence markers in this guide

- ✅ **VERIFIED** — quoted from a header, an SDK file, or a shipping source file, with a
  `path:LINE` citation. Where the quotation includes one of Apple's own typos (`transpse_left`,
  `__mutmul2d_detail`, `execution_simgroups`) it is reproduced as-is and flagged; those typos are a
  useful authenticity marker.
- 🟡 **RECONSTRUCTED** — the concept is attested, usually from session 330's narration, and the
  surrounding code has been assembled from verified pieces. Every symbol inside a reconstructed
  block is individually verified unless it carries its own marker; what is reconstructed is the
  *assembly*, not the vocabulary.
- 🔴 **GAP** — not verified, said so, with the resolution path and a safe default.

Where session 330's narration and the headers disagree, **the headers win** and the guide says so.
There are four such disagreements and they are all called out inline.

---

## §1 — Why cooperative tensors exist

Start with the problem, because the API is unintelligible without it.

A matrix multiply on the GPU produces a tile of results. In the classic Metal formulation those
results live in a `tensor` — a **non-owning wrapper** around memory you allocated, in the `device`,
`threadgroup` or `thread` address space. If the next thing you want to do is *anything other than
finish*, you now have a data-movement problem.

Apple's own framing of the cost, ✅ **VERIFIED**, quoted from Tech Talk 111432:

> *"With the basic approach… you would need to **write the output tensor to device memory** after
> the Matmul completes. Then **read it back in** to apply the activation function and **finally
> write it out again**. **This double trip to memory is costly.**"*

and the header says the same thing in its own words — ✅ **VERIFIED**, `MPPTensorOpsMatMul2d.h`
doc comment:

> *"we need to do some post processing on computed results before storing… One can do GEMM as above
> which writes the result to device memory, read the value back, call post processing function and
> write again. **This results in wasted bandwidth, performance and power.** User can apply post
> processing **in-register**."*

For a ReLU after a GEMM that is annoying. For attention it is fatal.

Attention is three operations with two intermediates:

```
S = Q @ Kᵀ            ← intermediate 1: [rows × keys]
P = softmax_rows(S)   ← intermediate 2: same shape
O = P @ V             ← the output you actually wanted
```

`S` is the big one. For a tile of 64 query rows against 256 keys at float32, that is 64 KB of
intermediate that exists only to be immediately consumed. Writing it to device memory and reading it
back is not a rounding error on the kernel's runtime; on a bandwidth-bound decode step it *is* the
kernel's runtime. The entire point of the FlashAttention algorithm — ✅ **VERIFIED**, session 330's
own summary at 330:81-85 — is that it *"fuses all of these operations together into a single
kernel"* so that the intermediates never become memory traffic.

To fuse them you need somewhere to keep `S` that is neither device memory nor threadgroup memory.
The only thing left is **registers** — and a matmul tile is far too big for one thread's registers.
It has to be spread across the threads doing the work.

That is what a cooperative tensor is. ✅ **VERIFIED**, session 330 at 330:73, verbatim:

> *"**Cooperative tensors distribute their storage across the thread private memory of the threads
> participating in the matmul operation.** So if you can't use quantized tensors directly, you can
> still **skip the round trip through threadgroup memory**."*

and Tech Talk 111432, on the same object:

> *"With cooperative tensors, the output of your matrix multiplication **stays in fast on chip
> memory distributed across the threads** which are participating in your operation. You can then
> **modify these elements in place**… **Only after you've finished your modifications do you write
> the final result to device memory.**"*

> *"It behaves just like a regular tensor, but with one key difference. **The data is distributed
> across multiple threads in the threadgroup. Each thread owns a subset of the tensor elements.**"*
> … *"**Thread zero holds the first two elements**… **thread one holds the next two elements**… The
> data is **interleaved across threads**."*

The three-tier ranking session 330 gives for how to get data into a matmul, best to worst, is worth
memorising because it is the decision you make every time you write one of these kernels —
✅ **VERIFIED**, 330:69-77:

| Tier | Mechanism | Cost |
|---|---|---|
| 1 | Native tensor operands straight into `matmul2d` | zero extra movement; hardware handles it |
| 2 | **Produce/convert into a `cooperative_tensor`, pass that in** | registers only; **this is the 26.3 feature** |
| 3 | Materialise into threadgroup memory, wrap as an inline threadgroup tensor | *"requires extra loads and stores through threadgroup memory"* |

Tier 3 is not wrong. It is the documented fallback (§4.4) and sometimes the only option. But if you
are reading this guide, you are here for tier 2.

> **The framing that unlocks the rest of this guide.** A cooperative tensor is not a fourth kind of
> tensor sitting alongside `tensor_handle`, `tensor_offset` and `tensor_inline`. Those three are
> *views onto memory you own*. A cooperative tensor **owns register storage that the op laid out for
> you**, in a layout you did not choose and cannot inspect portably. Everything awkward about the
> API — the compatibility predicates, the iterators, the mask — falls out of that one difference.

---

## §2 — What a cooperative tensor actually is

### 2.1 The type

✅ **VERIFIED** — the shape of the type is pinned by the trait specialisation at
`MPPTensorOpsTraits.h:100-106`:

```cpp
template <class ElementType, class Extents, class Layout>
struct __is_cooperative_tensor_type<metal::cooperative_tensor<ElementType, Extents, Layout>> : __true_type
{
};

template <class T>
constant auto __is_cooperative_tensor_type_v = __is_cooperative_tensor_type<__remove_cv_t<__remove_ref_ptr_t<T>>>::value;
```

So:

```cpp
metal::cooperative_tensor<ElementType, Extents, Layout>
```

Three template parameters. In **`namespace metal`**, not `mpp` — it is a *language* type, declared
in `<metal_cooperative_tensor>`, and the framework merely knows how to make them for you.

You will essentially never write that type name out. The `Layout` parameter is produced inside
`__mutmul2d_detail` (Apple's typo for `__matmul2d_detail`, shipping as-is in
`MPPTensorOpsMatMul2d.h:359`) and depends on the descriptor, the scope, and the element types. You
get cooperative tensors from **the op**, via the getters in §3, and you name their types with
`decltype` or with the op's own type aliases (§3.5).

### 2.2 Apple's own definition, and the three rules it implies

✅ **VERIFIED**, `MPPTensorOpsMatMul2d.h:212-225`, quoted complete because every clause is
load-bearing:

```
// output is computed using cooperative_tensor. Unlike tensor_handle,
// tensor_offset and tensor_inline which are non-owning meaning these are
// wrappers around resource in device, threadgroup or thread address space,
// cooperative_tensor owns thread private data and divides the data for entire
// tensor among threads (participating in the scope of operation) in implementation
// defined manner. This thread private memory is allocated at construction of
// cooperative_tensor and deallocated when this cooperative_tensor goes out of
// scope. The layout of cooperative_tensor depends on operation, data type,
// number of threads in opscope with which op was created. Note that
// cooperative_tensor created from an op is only valid for threads that are part
// of execution scope on which op was created.
```

Three rules follow, and each one is a bug class if you break it.

**Rule 1 — it is owning register storage with a scope-based lifetime.** *"allocated at construction
… deallocated when this cooperative_tensor goes out of scope."* You cannot return one from a
function that outlives the block, you cannot store a pointer to its elements anywhere durable, and
you should size your kernel's cooperative tensors with register pressure in mind. Tech Talk 111432
is explicit that this is the failure mode of over-large tiles: *"if you go too large, you may start
spilling registers, which hurts performance."*

**Rule 2 — the element-to-lane mapping is implementation defined.** *"divides the data … in
implementation defined manner"* and *"The layout … depends on operation, data type, number of
threads in opscope."* You may **not** assume `ct[i]` is any particular matrix element. If you need
coordinates, ask: `get_multidimensional_index(i)` (§5.3). If you need to pair elements across two
cooperative tensors, ask: `map_iterator` (§7). Every time you are tempted to compute an index
arithmetically from `simd_lane_id`, you are writing code that is correct for exactly one dtype
combination on exactly one GPU generation.

**Rule 3 — it is bound to the op *and* the scope that produced it.** *"only valid for threads that
are part of execution scope on which op was created."* You cannot construct a cooperative tensor
from op A and hand it to op B with a different descriptor or a different `Scope` and expect
anything. §4 is precisely the sanctioned way to move register data between two differently
configured ops, and it exists *because* rule 3 forbids the naive thing.

There is a fourth property, stated separately and easy to miss —
✅ **VERIFIED**, `MPPTensorOpsMatMul2d.h:247-250`:

```
//    // cooperative tensor will divide data among the threads in these
//    // 4 SIMD-Groups. The layout of data among lanes is implementation defined
//    // and not all threads and even all elements within a thread need
//    // be valid. Use the valid element check shown below to guard
```

**Not every slot a thread owns is a live matrix element.** A thread's capacity is an upper bound,
not a count of real data. §5.2 covers the guard.

### 2.3 Where it lives in the namespace hierarchy

The single most useful orientation fact in TensorOps, and the reason readers get lost: **there are
two layers in two namespaces from two headers**, and the members you want are split across them.

```
mpp::tensor_ops                     ← the framework  (MetalPerformancePrimitives/…)
  matmul2d<Descriptor, Scope>       ← the op
    .get_left_input_cooperative_tensor<…>()      ← makes them
    .get_right_input_cooperative_tensor<…>()
    .get_destination_cooperative_tensor<…>()
    .get_row_reduction_destination_cooperative_tensor<…>()
    .get_column_reduction_destination_cooperative_tensor<…>()
    .is_compatible_as_left_input<…>(src)         ← checks them
    .is_compatible_as_right_input<…>(src)
    .run(left, right, destination)               ← consumes them
  reduce_rows(src, dst, op, identity)            ← FREE FUNCTIONS, not members
  reduce_columns(src, dst, op, identity)
  is_iterator_compatible(src, dst)
  reduction_operation { sum, max, min }
  reduction_operation_identity<T>::{sum,max,min}_identity

metal                               ← the language  (<metal_cooperative_tensor>)
  cooperative_tensor<Element, Extents, Layout>
    .get_capacity()
    .get_mask(i)
    operator[](i)
    .get_multidimensional_index(i)
    .get_iterator(...)  .begin()  .end()
    .map_iterator(otherIterator)                 ← MEMBER, and it is here, not in mpp
    .load(tensor)  .store(tensor)
  execution_thread / execution_threads<1>
  execution_simdgroup / execution_simdgroups<N> / execution_dsimdgroups
```

Two placements in that map are the ones people get wrong, both attested as errors in session 330's
narration:

- **`reduce_rows` is a free function in `mpp::tensor_ops`, not a member of anything.** Session 330
  describes it as though it hangs off the cooperative tensor. It does not. §6.1.
- **`map_iterator` is a member of `metal::cooperative_tensor`, not of `mpp::tensor_ops`.** §7.

---

## §3 — The asymmetry: element types vs operand types

This section exists because of one fact:

> ✅ **VERIFIED, and this is the #1 compile failure in TensorOps.**
> `get_left_input_cooperative_tensor` and `get_right_input_cooperative_tensor` take **ELEMENT**
> types in their first two template parameters.
> `get_destination_cooperative_tensor` takes **OPERAND** types in its first two template parameters.

The two getters look like siblings. They are spelled like siblings. They are called on the same
object, one line apart, in every kernel you will write. And they take different kinds of type.

The compiler's diagnostic for getting this wrong is a SFINAE substitution failure inside
`__tensor_ops_detail::__enable_if_t<…>`, several template instantiations deep, naming
`__is_thread_addrspace_v` or `__is_tensor_type_v` — traits you have never heard of, in a namespace
you are not supposed to know about. It will not say "you passed an element type where an operand
type was expected." Learn the rule instead.

### 3.1 The three getters, quoted

**Left input** — ✅ **VERIFIED**, `MPPTensorOpsMatMul2d.h:425-438`:

```cpp
  template <typename LeftElementType, typename RightElementType,
            typename ElementType, typename CoordType = int,
            typename U = __tensor_ops_detail::__enable_if_t<
                __tensor_ops_detail::__is_thread_addrspace_v<LeftElementType> &&
                __tensor_ops_detail::__is_thread_addrspace_v<RightElementType> &&
                __tensor_ops_detail::__is_thread_addrspace_v<ElementType> &&
                __tensor_ops_detail::__is_integral_v<CoordType>>,
            typename... CoopArgs>
  INLINE cooperative_tensor_left_input_t<LeftElementType, RightElementType, ElementType, CoordType, CoopArgs...>
  get_left_input_cooperative_tensor() thread const
  {
    return __mutmul2d_detail::__get_left_input_cooperative_tensor<
        Descriptor, Scope, LeftElementType, RightElementType, ElementType, CoordType, CoopArgs...>();
  }
```

Read the constraint: `__is_thread_addrspace_v<LeftElementType>`. It is asking "is this a plain
value type you can hold in a register" — i.e. `half`, `float`, `bfloat`, `int8_t`. It is **not**
asking "is this a tensor."

**Right input** — ✅ **VERIFIED**, `MPPTensorOpsMatMul2d.h:478-491`. Exact mirror, same four
template parameters, same constraint.

**Destination** — ✅ **VERIFIED**, `MPPTensorOpsMatMul2d.h:531-546`, and look at what changed:

```cpp
  template <typename LeftOperandType, typename RightOperandType,
            typename ElementType, typename CoordType = int,
            typename U = __tensor_ops_detail::__enable_if_t<
                (__tensor_ops_detail::__is_tensor_type_v<LeftOperandType> || __tensor_ops_detail::__is_cooperative_tensor_type_v<LeftOperandType>) &&
                (__tensor_ops_detail::__is_tensor_type_v<RightOperandType> || __tensor_ops_detail::__is_cooperative_tensor_type_v<RightOperandType>) &&
                __tensor_ops_detail::__is_thread_addrspace_v<ElementType> &&
                __tensor_ops_detail::__is_integral_v<CoordType>>,
            typename... CoopArgs>
  INLINE cooperative_tensor_destination_t<LeftOperandType, RightOperandType, ElementType, CoordType, CoopArgs...>
  get_destination_cooperative_tensor() thread const
  {

    return __mutmul2d_detail::__get_destination_cooperative_tensor<
        Descriptor, Scope, LeftOperandType, RightOperandType, ElementType,
        CoordType, CoopArgs...>();
  }
```

The parameters are even *named* differently — `LeftOperandType` rather than `LeftElementType` — and
the constraint is `__is_tensor_type_v<T> || __is_cooperative_tensor_type_v<T>`: "is this a tensor,
of any of the three descriptor kinds, **or** a cooperative tensor."

The third parameter, `ElementType`, is an element type in **all three** getters. Only the first two
differ.

### 3.2 The table you should tape to your monitor

| Getter | TP1 | TP2 | TP3 | TP4 |
|---|---|---|---|---|
| `get_left_input_cooperative_tensor` | `LeftElementType` | `RightElementType` | `ElementType` | `CoordType = int` |
| `get_right_input_cooperative_tensor` | `LeftElementType` | `RightElementType` | `ElementType` | `CoordType = int` |
| `get_destination_cooperative_tensor` | **`LeftOperandType`** | **`RightOperandType`** | `ElementType` | `CoordType = int` |
| `get_row_reduction_destination_cooperative_tensor` | **`LeftOperandType`** | **`RightOperandType`** | `ElementType` | `CoordType = int` |
| `get_column_reduction_destination_cooperative_tensor` | **`LeftOperandType`** | **`RightOperandType`** | `ElementType` | `CoordType = int` |

The mnemonic: **inputs describe the *numbers*; destinations describe the *things holding the
numbers*.** A destination has to know the concrete layouts of both inputs in order to lay itself out
compatibly, and a layout is a property of the operand type, not of the element type.

Note also that the two reduction-destination getters (§6.4) follow the **destination** convention,
not the input one. They are destinations. ✅ **VERIFIED**, `MPPTensorOpsMatMul2d.h:554-565` and
`:574-584`.

> A small, real inconsistency worth knowing so it does not confuse you: the reduction-destination
> getters' `enable_if` clause checks **only** `__is_integral_v<CoordType>` — it does not repeat the
> tensor-type checks that `get_destination_cooperative_tensor` applies to TP1/TP2. ✅ **VERIFIED**,
> `MPPTensorOpsMatMul2d.h:554-559`. The parameters are still *named* `LeftOperandType` /
> `RightOperandType` and the implementation still consumes them as such, so pass operand types. A
> looser constraint is not permission to pass the wrong thing; it just means the diagnostic will
> arrive one layer deeper.

### 3.3 Wrong, and why the compiler will not help you

Here is the mistake, in the exact form it gets made:

```cpp
// ❌ WRONG — element types passed to the destination getter.
//    This is the natural thing to write, because it is what you just
//    wrote two lines above for the inputs.

auto ct_a = gemm_op.template get_left_input_cooperative_tensor <half, half, float>();
auto ct_b = gemm_op.template get_right_input_cooperative_tensor<half, half, float>();
auto ct_c = gemm_op.template get_destination_cooperative_tensor<half, half, float>();
//                                                              ^^^^  ^^^^
//              `half` is an element type. The destination getter wants the
//              OPERAND types — i.e. the types of ct_a and ct_b themselves.
```

`half` satisfies `__is_thread_addrspace_v` but fails
`__is_tensor_type_v<half> || __is_cooperative_tensor_type_v<half>`, so the `enable_if` disables the
overload and you get "no matching member function for call to
`get_destination_cooperative_tensor`" with a wall of substitution-failure notes.

The symmetric error is rarer but nastier:

```cpp
// ❌ WRONG the other way — operand types passed to an input getter.
auto ct_a = gemm_op.template get_left_input_cooperative_tensor<
                decltype(someTensorA), decltype(someTensorB), float>();
//              ^ a tensor type. Fails __is_thread_addrspace_v.
```

And the one that *nearly* works, which is the worst kind:

```cpp
// ❌ WRONG — right idea, wrong order. The destination getter's first two
//    parameters are (left, right), in that order, matching run()'s operand
//    order — not (right, left) and not (destination, source).
auto ct_c = gemm_op.template get_destination_cooperative_tensor<
                decltype(ct_b), decltype(ct_a), float>();
```

For a symmetric descriptor with identical dtypes this may compile and produce a differently-shaped
destination than you intended. There is no runtime assertion for it.

> ⚠️ **There is no `is_compatible_as_destination`, and no conversion overload for the destination.**
> ✅ **VERIFIED** by enumeration of the class's entire public surface,
> `MPPTensorOpsMatMul2d.h:399-580`: `get_destination_cooperative_tensor` has **one** overload, the
> no-argument one. The asymmetry between inputs (two overloads + a compatibility predicate each) and
> the destination (one overload, no predicate) is real and deliberate. Destinations are always
> freshly constructed by the op that will write them.

### 3.4 Right — MLX's shipping call site

The authoritative worked example is not in Apple's headers; it is in MLX, which is real, compiling,
in-production code against the same headers. ✅ **VERIFIED**, quoted from
`mlx/backend/metal/kernels/steel/gemm/nax.h:387-456` (the same function appears byte-identically in
`steel/attn/nax.h`, which is how MLX's *attention* kernels get their matmuls):

```cpp
  template <
      typename CType,
      typename AType,
      typename BType,
      bool transpose_a = false,
      bool transpose_b = false>
  METAL_FUNC static constexpr void mma(
      thread dtype_frag_t<CType>& Cn0,
      thread dtype_frag_t<CType>& Cn1,
      const thread dtype_frag_t<AType>& A,
      metal::bool_constant<transpose_a>,
      const thread dtype_frag_t<BType>& Bn0,
      const thread dtype_frag_t<BType>& Bn1,
      metal::bool_constant<transpose_b>) {
    constexpr auto desc = mpp::tensor_ops::matmul2d_descriptor(
        16,
        32,
        16,
        transpose_a,
        transpose_b,
        true,
        mpp::tensor_ops::matmul2d_descriptor::mode::multiply_accumulate);

    // Create matmul op
    mpp::tensor_ops::matmul2d<desc, metal::execution_simdgroup> gemm_op;

    // Create matmul operands in registers
    auto ct_a =
        gemm_op
            .template get_left_input_cooperative_tensor<AType, BType, CType>();
    auto ct_b =
        gemm_op
            .template get_right_input_cooperative_tensor<AType, BType, CType>();

    // Create matmul output in register
    auto ct_c = gemm_op.template get_destination_cooperative_tensor<
        decltype(ct_a),
        decltype(ct_b),
        CType>();
```

There it is, in three consecutive statements:

- inputs: `<AType, BType, CType>` — **element** types of left, right, destination.
- destination: `<decltype(ct_a), decltype(ct_b), CType>` — **operand** types of left and right, then
  the destination's **element** type.

`decltype(ct_a)` is the idiom. You do not need to be able to *name* the cooperative tensor's type;
you only need to hand it back to the op.

Three more things in that snippet that a reader should not skate past, all ✅ **VERIFIED** from the
same lines:

1. **`.template` is mandatory.** `gemm_op` is a dependent object in a template context, and the
   getters are member templates. Omit `.template` and you get an unhelpful parse error about `<`.
   MLX writes `.template get_left_input_cooperative_tensor<…>()` every single time.
2. **The descriptor is a non-type template parameter of class type.** That is why MLX writes
   `constexpr auto desc = …` and then `matmul2d<desc, …>`. You cannot inline the constructor call
   into the template argument list in older Metal dialects; keep the `constexpr auto` line.
3. **`mode::multiply_accumulate` is passed explicitly** — because the default is `mode::multiply`.
   ✅ **VERIFIED**, `MPPTensorOpsMatMul2d.h:245`. Any K-loop that omits the seventh positional
   argument silently gets *overwrite* semantics on every iteration and produces only the last tile's
   contribution. Guide 01 covers the descriptor in full; it is repeated here because it is the
   second-most-common way a fused kernel comes out numerically wrong.

### 3.5 The named type aliases, if you dislike `decltype`

You are not obliged to use `decltype`. The op exposes a public alias template for each getter —
✅ **VERIFIED**, `MPPTensorOpsMatMul2d.h:421`, `:474`, `:527`, `:550`, `:570`:

| Alias template | Line | Parameters mirror |
|---|---:|---|
| `cooperative_tensor_left_input_t<…>` | 421 | the left-input getter |
| `cooperative_tensor_right_input_t<…>` | 474 | the right-input getter |
| `cooperative_tensor_destination_t<…>` | 527 | the destination getter |
| `cooperative_tensor_row_reduction_destination_t<…>` | 550 | the row-reduction getter |
| `cooperative_tensor_column_reduction_destination_t<…>` | 570 | the column-reduction getter |

🟡 **RECONSTRUCTED — assembly only; every symbol is verified.** Written out, a named-type version of
the MLX pattern looks like this:

```cpp
using gemm_t = mpp::tensor_ops::matmul2d<desc, metal::execution_simdgroup>;

using lhs_t  = gemm_t::cooperative_tensor_left_input_t <half, half, float>;
using rhs_t  = gemm_t::cooperative_tensor_right_input_t<half, half, float>;
using dst_t  = gemm_t::cooperative_tensor_destination_t<lhs_t, rhs_t, float>;

gemm_t gemm_op;
lhs_t ct_a = gemm_op.template get_left_input_cooperative_tensor <half, half, float>();
rhs_t ct_b = gemm_op.template get_right_input_cooperative_tensor<half, half, float>();
dst_t ct_c = gemm_op.template get_destination_cooperative_tensor<lhs_t, rhs_t, float>();
```

Notice the aliases carry the **same** asymmetry — `lhs_t`/`rhs_t` are parameterised on element
types, `dst_t` on the alias types themselves. Writing it this way makes the asymmetry visible in
your own source, which is a real argument for preferring it over `decltype` in code other people
will read. It is also more verbose, which is why MLX does not.

---

## §4 — Feeding a cooperative tensor into a matmul

This is the 26.3 capability, and it is what makes a fused attention kernel possible at all.

The claim, stated by Apple twice. ✅ **VERIFIED**, session 330 at 330:106-107:

> *"Now we're ready to multiply this cooperative tensor by V. **In macOS 26, you would have had to
> first store it to threadgroup memory. But it's now possible to use cooperative tensors directly as
> inputs to matmul operations.**"*

✅ **VERIFIED**, Tech Talk 111432, dating it:

> *"In **26.3**, we added support for **cooperative tensors as inputs to matmul**."*

Reconciling the two: session 330's "in macOS 26" means **26.0**. The capability landed in a point
release. That is §0.2's ladder, and it is why the version floor for this guide is 26.3 rather than
26.0.

### 4.1 The SFINAE clause that settles it

You do not have to take the narration's word for it. ✅ **VERIFIED**,
`MPPTensorOpsMatMul2d.h:404-418`, quoted complete:

```cpp
  template <
      typename LeftOperandType, typename RightOperandType,
      typename DestinationOperandType,
      typename V = __tensor_ops_detail::__enable_if_t<
          ((__tensor_ops_detail::__is_tensor_type_v<LeftOperandType> || __tensor_ops_detail::__is_cooperative_tensor_type_v<LeftOperandType>) &&
           (__tensor_ops_detail::__is_tensor_type_v<RightOperandType> || __tensor_ops_detail::__is_cooperative_tensor_type_v<RightOperandType>) &&
           (__tensor_ops_detail::__is_tensor_type_v<DestinationOperandType> || __tensor_ops_detail::__is_cooperative_tensor_type_v<DestinationOperandType>))>,
      typename... RunArgs>
  INLINE void run(thread LeftOperandType &left, thread RightOperandType &right,
                  thread DestinationOperandType &destination) thread const
  {
    __mutmul2d_detail::__run<Descriptor, Scope, LeftOperandType,
                             RightOperandType, DestinationOperandType,
                             RunArgs...>(left, right, destination);
  }
```

Each of the three operands is **independently** constrained to
`__is_tensor_type_v<T> || __is_cooperative_tensor_type_v<T>`. So:

> ✅ **CONFIRMED.** A cooperative tensor is a legal operand in the **left**, **right** and
> **destination** positions of `run()` — including all three simultaneously.

And that is not just a reading of a template. MLX does exactly that, in production, at
`steel/gemm/nax.h:448`:

```cpp
    gemm_op.run(ct_a, ct_b, ct_c);   // all three are cooperative tensors
```

Two mechanical details from the same declaration, both easy to trip over:

- **All three operands are non-`const` `thread` references.** There is no `const` overload of
  `run()`. You cannot pass a `const` cooperative tensor, and you cannot pass a temporary. Name your
  operands.
- ✅ **VERIFIED**, `MPPTensorOpsMatMul2d.h:300-303` — the uniformity requirement:
  > *"an execution scope provided as template argument. All the threads in this execution scope must
  > enter the run method i.e. call to run methods must be **'execution scope' uniform**."*

  Every thread of the scope must reach the `run()` call. A `return` in a bounds-check, an early-out
  for a masked row, a `break` in a K-loop that some lanes take and others do not — any of these
  makes the call non-uniform and the behaviour is not defined. This is the constraint that shapes
  §8's kernel structure more than any other.

> **A historical note that will save you an afternoon.** ✅ **VERIFIED**,
> `MPPTensorOpsMatMul2d.h:9-10`, the header's own opening summary still reads:
>
> *"A and B can be `tensor_handle`, `tensor_offset`, and `tensor_inline`. C can be `tensor_handle`,
> `tensor_offset`, `tensor_inline` **or `cooperative_tensor`**."*
>
> That sentence describes the **26.0** situation — cooperative tensors as destinations only. The
> `run()` declaration 400 lines below it, in the same shipped file, permits them in all three
> slots. **The declaration is normative; the prose is stale.** If you were relying on that summary
> to conclude that inputs are impossible, this is your correction.

### 4.2 The conversion overloads

A cooperative tensor produced by op A is bound to op A's descriptor, scope and dtypes (§2.2, rule
3). To use it as an input to op B, you ask **op B** to build one of its own inputs *from* it.

✅ **VERIFIED**, `MPPTensorOpsMatMul2d.h:440-456`:

```cpp
  template <typename LeftElementType, typename RightElementType,
            typename ElementType, typename CoordType = int,
            typename SrcElemType, typename SrcExtents, typename SrcLayout,
            ...>
  INLINE cooperative_tensor_left_input_t<LeftElementType, RightElementType, ElementType, CoordType, CoopArgs...>
  get_left_input_cooperative_tensor(const thread metal::cooperative_tensor<SrcElemType, SrcExtents, SrcLayout> & src) thread const
```

Right-hand mirror at `:493-509`.

Read the template parameter list carefully, because it explains the call syntax:

- TP1-TP3 are the **same element types** as the no-argument overload — left element, right element,
  destination element, for **op B**.
- TP4 is `CoordType`, defaulted to `int`.
- TP5-TP7 (`SrcElemType`, `SrcExtents`, `SrcLayout`) are **deduced** from the argument.

So you write three explicit template arguments and let the rest deduce:

```cpp
auto lhs = pv_op.template get_left_input_cooperative_tensor<float, half, float>(S);
//                                                          ^^^^^  ^^^^  ^^^^^  ^
//        element type of pv_op's left operand ─────────────┘      │      │     │
//        element type of pv_op's right operand ───────────────────┘      │     │
//        element type of pv_op's destination ────────────────────────────┘     │
//        the source cooperative tensor (its type is deduced) ──────────────────┘
```

This is **the fusion primitive**. It is the reason a two-matmul kernel can keep its intermediate in
registers end to end.

> 🟡 **RECONSTRUCTED — cost model.** Neither the header nor either talk states what this conversion
> *costs*. Mechanically it must be a lane-to-lane data movement (a shuffle or a small permutation
> network) whenever the two layouts differ, and free when they coincide. We have no measurement.
> **Do not tell readers it is free.** What we can say from the API's shape is that Apple expected it
> to sometimes be *impossible*, which is why §4.3 exists.

### 4.3 `is_compatible_as_left_input` — a runtime bool you must branch on

✅ **VERIFIED**, session 330 at 330:108-109, and this is the part of the narration most worth
reproducing verbatim because it is a behavioural contract, not an API name:

> *"**One thing to watch out for: not every cooperative tensor can be reused as an input. The layouts
> may differ depending on the data types and other factors. So before you do this, call the
> `is_compatible_as_left` or `right _input` method to check for compatibility.**"*
>
> *"If it returns true, you're good to go. **If not, you'll need to store and reload the data through
> threadgroup memory to convert it to the correct layout. Either way, the call to `op.run` is the
> same.**"*

(The mangled `"is_compatible_as_left` or `right _input"` is an automatic-transcription artefact. The
real method names, ✅ **VERIFIED** in the header, are `is_compatible_as_left_input` and
`is_compatible_as_right_input`.)

The declaration — ✅ **VERIFIED**, `MPPTensorOpsMatMul2d.h:458-471`:

```cpp
  template <typename LeftElementType, typename RightElementType, typename ElementType,
            typename SrcElemType, typename SrcExtents, typename SrcLayout,
            typename U = __tensor_ops_detail::__enable_if_t<
                __tensor_ops_detail::__is_thread_addrspace_v<LeftElementType> &&
                __tensor_ops_detail::__is_thread_addrspace_v<RightElementType> &&
                __tensor_ops_detail::__is_thread_addrspace_v<ElementType> &&
                __tensor_ops_detail::__is_thread_addrspace_v<SrcElemType>>>
  INLINE bool
  is_compatible_as_left_input(const thread metal::cooperative_tensor<SrcElemType, SrcExtents, SrcLayout> & src) thread const
  {
      return __mutmul2d_detail::__is_compatible_as_left_input<
          LeftElementType, RightElementType, ElementType, Descriptor, Scope,
          SrcElemType, SrcExtents, SrcLayout>(src);
  }
```

Right mirror at `:511-524`. Four facts that determine how you use it:

1. **It returns `bool`, not `constexpr bool`.** ✅ **VERIFIED** — the return type in the declaration
   is a plain `bool` and the function is not `constexpr`. You cannot use it in `if constexpr`, and
   you cannot use it in a `static_assert`. It is a runtime branch. Whether the underlying answer is
   in practice a compile-time constant that the optimiser folds is **unverified**; write the code as
   if it is not.
2. **It takes exactly one runtime argument**: a `const thread` reference to a `cooperative_tensor`.
3. **It has no `CoordType` template parameter** — unlike the getters. So
   `is_compatible_as_left_input<A, B, C>(S)` and `get_left_input_cooperative_tensor<A, B, C>(S)`
   happen to take the same three explicit arguments, but for structurally different reasons. Keep
   them in sync manually; nothing checks that you did.
4. **It is a member of the *consuming* op.** You ask "op B, can you take this?" — not "op A, can you
   give this away?"

> ⚠️ **SILENT FAILURE — skipping the check.** There is no evidence in the header that calling the
> conversion overload on an incompatible source produces a diagnostic. The overload's `enable_if`
> constrains **types**, not **layouts**, and layout compatibility is exactly the thing that is a
> runtime property. Apple documents a runtime predicate and a fallback path; the natural reading is
> that the unchecked path is not defined to fail loudly. **Call the predicate.** The branch costs
> you a few instructions and buys you the difference between a correct kernel and a silently wrong
> one on some future dtype combination.
>
> 🔴 **GAP:** we could not verify what actually happens if you convert without checking — whether it
> traps, produces garbage, or in fact always works and the predicate is defensive. **What would
> resolve it:** running a kernel that deliberately mismatches layouts, on device, and comparing
> against a CPU reference. **Safe default:** always branch.

### 4.4 The documented fallback

Apple documents the fallback in prose, in a comment about a *different* predicate
(`is_iterator_compatible`, §7.4), but it is the same recipe — ✅ **VERIFIED**,
`MPPTensorOpsMatMul2d.h:611-633`:

```
//     else {
//          // Fall back to storing sourceCT to threadgroup memory and access via
//          // destCT's multidimensional indices
//     }
```

and session 330 states it for the matmul-input case directly: *"you'll need to store and reload the
data through threadgroup memory to convert it to the correct layout."*

The shape of that fallback, and the important closing observation:

🟡 **RECONSTRUCTED — assembly; `store`, the barrier and `run` are all verified individually.**

```cpp
    // scratch must be big enough for one tile of S, per simdgroup if each
    // simdgroup owns its own rows (see §8.1)
    threadgroup float scratch[SG_COUNT][TILE_M * TILE_N];

    decltype(pv_op.template get_left_input_cooperative_tensor<float, half, float>()) lhs;

    if (pv_op.template is_compatible_as_left_input<float, half, float>(S)) {
        // fast path — register-to-register
        lhs = pv_op.template get_left_input_cooperative_tensor<float, half, float>(S);
    } else {
        // slow path — round-trip through threadgroup memory
        auto tgTile = /* an inline tensor over scratch[sgid], see guide 01 */;
        S.store(tgTile);
        metal::threadgroup_barrier(metal::mem_flags::mem_threadgroup);
        lhs = pv_op.template get_left_input_cooperative_tensor<float, half, float>();
        lhs.load(tgTile);
    }

    pv_op.run(lhs, vTile, O);      // identical in both branches
```

> **"Either way, the call to `op.run` is the same."** That sentence from session 330 is the design
> hint. Structure your kernel so the branch is *only* about how `lhs` gets filled, never about what
> happens afterwards. That keeps `run()` execution-scope uniform (§4.1) without effort — both
> branches reach it, unconditionally.

Two cautions on the slow path:

- **The barrier is not optional and the fallback is not free of it.** Storing to threadgroup memory
  from a cooperative tensor writes lanes' private data into shared storage; reading it back in a
  different layout means some lanes read what other lanes wrote. That is a cross-lane dependency and
  it needs `threadgroup_barrier(mem_flags::mem_threadgroup)` between the store and the load.
- **If each simdgroup owns its own rows (§8.1), give each simdgroup its own scratch.** Otherwise the
  barrier does not save you — a threadgroup barrier synchronises the whole threadgroup, and two
  simdgroups writing the same scratch region will still race with each other's *next* iteration.
  Index the scratch by `sgid`.

> 🔴 **GAP — `load` and `store` signatures.** `cooperative_tensor::load(...)` and `store(...)` appear
> in Apple's worked example at `MPPTensorOpsMatMul2d.h:275` and `:293`, and in Tech Talk 111432's
> narration (*"we write the results back to device memory by calling the STORE function on the
> cooperative tensor with our output slice as the parameter"*). Their **declarations were not read**
> in `<metal_cooperative_tensor>`. Whether they accept all three tensor descriptor kinds, whether
> there is a strided or masked overload, and what they return are **unverified**.
> **What would resolve it:** reading `<metal_cooperative_tensor>` for the `load`/`store` member
> declarations. **Safe default:** use them exactly as Apple's example does — one argument, a tensor
> whose extents match the cooperative tensor's — and do not assume any other overload exists.

---

## §5 — Reading and writing elements

Everything interesting in a fused kernel happens between `run()` calls, in a loop over the elements
one thread owns. This section is that loop.

### 5.1 The public member surface

✅ **VERIFIED** — enumerated from `<metal_cooperative_tensor>` (cryptex Metal toolchain; resolve the
path with `xcrun -sdk macosx --find metal`):

| Member | Line | Notes |
|---|---:|---|
| `get_capacity()` | 413 | how many element slots **this thread** owns |
| `get_multidimensional_index(thread_index_type)` | 433 | slot index → local 2-D coordinate |
| `get_multidimensional_index(const_iterator)` | 438 | iterator overload |
| `get_multidimensional_index(const thread element_type*)` | 443 | pointer overload |
| `get_iterator(...)` | ~525-536 | |
| `map_iterator(OtherIterator)` — mutable | 543 | §7 |
| `map_iterator(OtherIterator)` — const | 553 | returns `const_iterator` |
| `begin()` / `end()` | 559-577 | |

plus `operator[](i)`, `get_mask(i)`, `load(tensor)` and `store(tensor)`, which appear in Apple's
worked example in `MPPTensorOpsMatMul2d.h` but whose declarations were not read — see the GAP boxes
in this section and in §4.4.

Three of these have overload sets worth noticing. `get_multidimensional_index` accepts **three**
different things — a raw slot index, an iterator, or a pointer to an element — which tells you that
the three ways of addressing a cooperative tensor are meant to be interchangeable and that Apple
expected you to mix loop styles. `map_iterator` is doubled for const-correctness and the const
overload returns a `const_iterator`, so a `const thread` cooperative tensor gives you read-only
mapped access rather than nothing.

### 5.2 `get_capacity` + `get_mask`: the idiomatic loop

Apple's own example, ✅ **VERIFIED**, `MPPTensorOpsMatMul2d.h:259-263`, reproduced with its bug
intact so you can recognise it:

```cpp
//    #pragma unroll full
//    for (uint16_t i = 0, i < cT.get_capacity(); ++i) {
//      if(cT.get_mask(i))
//        cT[i] = 0;
//    }
```

> ⚠️ **Do not copy that verbatim.** `for (uint16_t i = 0,` — the comma should be a semicolon. It is a
> typo in the shipping header's comment, not valid Metal. (This series has been burned by
> transcribed-from-narration code before; here the fault is upstream, and the fix is obvious, but a
> reader pasting from the SDK will hit it.)

Corrected, and this is the loop you should actually write:

```cpp
    #pragma unroll full
    for (uint16_t i = 0; i < cT.get_capacity(); ++i) {
        if (cT.get_mask(i)) {
            cT[i] = 0;
        }
    }
```

Three things to internalise:

**`get_capacity()` is per thread, not per tensor.** It answers "how many slots does the calling
thread hold," and it is the loop bound Tech Talk 111432 names: *"we use GET_CAPACITY to find out how
many elements this thread owns."*

**`get_mask(i)` is the validity predicate, and skipping it is a latent correctness bug.** Apple's
own text (§2.2) says *"not all threads and even all elements within a thread need be valid."* A
capacity slot exists in the layout; whether it corresponds to a real element of the logical tile
depends on the tile shape, the dtype and the thread count.

**The unroll pragma is not decoration.** ✅ **VERIFIED**, `MPPTensorOpsMatMul2d.h`, Apple's own
comment in the same example: *"It is imperative for performance to include 'unroll pragma'."* The
loop bound is a compile-time property of the layout, and without full unrolling the indexed accesses
do not resolve to register operands.

> **What MLX does, and why you should not copy it.** MLX indexes cooperative tensors directly —
> `ct_a[i] = A[i]` — in a `STEEL_PRAGMA_UNROLL` loop over `kElemsPerFrag`, and **never calls
> `get_mask`**. ✅ **VERIFIED**, `steel/gemm/nax.h:387-456`. It gets away with this because its
> descriptor (`m=16, n=32, k=16`) exactly matches its own 16×16 fragment size, so
> `kElemsPerFrag = (16*16)/32 = 8` and every slot is live by construction. Copy that pattern into a
> kernel with a different tile shape and you will read and write slots that are not yours. **Use
> `get_mask` as the default; treat MLX's omission as a shape-specific optimisation that its authors
> proved for their exact shapes.**

> 🔴 **GAP — `get_mask`'s exact signature.** It appears only in Apple's doc-comment example
> (`MPPTensorOpsMatMul2d.h:261`, `:280`) and was **not located in a declaration** in
> `<metal_cooperative_tensor>`. The usage `if (cT.get_mask(i))` implies `bool get_mask(index_type)`,
> but the return type and parameter type are **unverified**. **What would resolve it:** grepping
> `<metal_cooperative_tensor>` for `get_mask`. **Safe default:** use it exactly as in the example —
> as a boolean guard on the same index you pass to `operator[]` — and do not store or manipulate the
> result.

### 5.3 `get_multidimensional_index`

When you need to know *where in the logical tile* a slot lives — for a causal mask, a bias term, a
position-dependent scale — this is the only portable answer.

✅ **VERIFIED**, Apple's example at `MPPTensorOpsMatMul2d.h:287`, in context:

```cpp
//    #pragma unroll full
//    for (uint16_t i = 0; i < cT.get_capacity(); ++i) {
//      if (cT.get_mask(i)) {
//        cT[i] += biasT[i];
//        auto ids = cT.get_multidimensional_index(i);
//        cT[i] = foo(cT[i], ids);
//      }
//    }
```

`ids` is *"the 2-D local coordinate"* within the tile — local, meaning relative to the tile the op
was configured for, not global to the matrix. To get a global coordinate you add the tile origin you
computed when you sliced (§8.2). That composition is yours to do and nothing checks it.

🟡 **RECONSTRUCTED — a causal mask, assembled from verified pieces:**

```cpp
    // rowOffset / colOffset are the global origin of this simdgroup's tile,
    // computed the same way you computed the slice in §8.2.
    #pragma unroll full
    for (uint16_t i = 0; i < S.get_capacity(); ++i) {
        if (!S.get_mask(i)) { continue; }
        auto ids = S.get_multidimensional_index(i);
        // ids gives the tile-local (row, col); add the tile origin for global
        if (colOffset + ids[1] > rowOffset + ids[0]) {
            S[i] = -INFINITY;            // future key — mask it out
        }
    }
```

> 🔴 **GAP — the return type of `get_multidimensional_index`.** Apple's example binds it with `auto`
> and indexes nothing; Tech Talk 111432 does not name it. Whether it is a `vec<CoordType, 2>`, an
> array-like, or a struct with named members is **unverified**, and therefore whether `ids[0]` is the
> row or the column is **unverified**. **What would resolve it:** reading the declaration at
> `<metal_cooperative_tensor>:433`. **Safe default:** bind with `auto`, and determine the component
> order empirically on device with a debug kernel that writes `ids` out for a known tile, before you
> ship anything that depends on it. The snippet above assumes `[0] = row, [1] = column` and is
> marked reconstructed for exactly that reason.

### 5.4 `load` / `store`

The two bulk transfer operations between a cooperative tensor and a regular tensor. ✅ **VERIFIED**
as *usage*, `MPPTensorOpsMatMul2d.h:275` and `:293`:

```cpp
//    biasT.load(bias);      // fill a cooperative tensor from a tensor handle
//    ...
//    cT.store(mC);          // write a cooperative tensor out to a tensor
```

Tech Talk 111432 confirms the store direction and its argument: *"we write the results back to
device memory by calling the STORE function on the cooperative tensor with our output slice as the
parameter."* Note **"output slice"** — the argument is the sliced tensor for this threadgroup, not
the whole tensor.

These are how a fused kernel begins and ends: `load` a bias or a previously computed tile into
registers, `store` the final output once. Every `store` in the middle of a kernel is a fusion
opportunity you did not take.

The signature gap is declared in §4.4 and applies here too.

### 5.5 ⚠️ Cooperative tensors are not zero-initialised

This is the subtlest of the correctness traps in this section, and it interacts with the descriptor.

Apple's first worked example zeroes the destination explicitly before running the matmul (§5.2's
loop, whose body is `cT[i] = 0;`), and the header's example comment says outright — ✅ **VERIFIED** —
*"execute the operation. Assumes C is initialized to zero."*

Two independent reasons that matters:

1. **`matmul2d_descriptor`'s default mode is `mode::multiply`, not `multiply_accumulate`.**
   ✅ **VERIFIED**, `MPPTensorOpsMatMul2d.h:245`. In `multiply` mode the destination is overwritten,
   so an uninitialised destination is harmless for a single op — but a K-loop that forgets to pass
   `multiply_accumulate` will *also* be overwritten on every iteration and produce only the last
   chunk's contribution. Silent, plausible-looking, wrong by a factor that depends on your K.
2. **In `multiply_accumulate` mode the destination's prior contents are part of the result.** MLX
   relies on exactly this — ✅ **VERIFIED**, `steel/gemm/nax.h`, with Apple's-style comment
   `// Load C into output registers (op handles accumulation)` above a loop that copies the running
   accumulator into `ct_c` before `run()`. If you use that mode and do **not** initialise, you
   accumulate onto whatever was in those registers.

> ⚠️ **SILENT FAILURE.** Neither mistake throws, traps, or produces a NaN reliably. Uninitialised
> register storage on a GPU frequently reads as zero on the first launch of a fresh pipeline and as
> garbage on the second, which is the worst possible debugging experience: it works, you ship it, it
> fails for a user. **Always initialise the destination, and always pass the mode explicitly.**

The safe pattern, which costs one unrolled loop:

```cpp
    auto ct_c = op.template get_destination_cooperative_tensor<
                    decltype(ct_a), decltype(ct_b), float>();

    #pragma unroll full
    for (uint16_t i = 0; i < ct_c.get_capacity(); ++i) {
        if (ct_c.get_mask(i)) { ct_c[i] = 0.0f; }
    }

    op.run(ct_a, ct_b, ct_c);
```

---

## §6 — Reductions

Softmax needs two row-wise reductions: a max (for numerical stability) and a sum (to normalise).
TensorOps gives you both through one function. The function is simple. Its **default argument is a
trap**, and it is the single most dangerous thing in this guide.

### 6.1 `reduce_rows` is a free function

Session 330 describes `reduce_rows` in a way that reads as though it hangs off the op or off the
cooperative tensor — ✅ **VERIFIED**, 330:93-95:

> *"To do this, we'll need to compute a couple of reductions on the cooperative tensor. **TensorOps
> includes a `reduce_rows` function to help with this.** **Threads will exchange data amongst
> themselves to calculate the max for each row. The result is returned in another cooperative
> tensor.**"*

The narration is right about the semantics and unclear about the placement. The header settles it —
✅ **VERIFIED**, `MPPTensorOpsMatMul2d.h:587-597`, quoted complete:

```cpp
template <class ElementType, class SrcExtents, class DstExtents, class SrcLayout, class DstLayout>
inline void reduce_rows(
    thread metal::cooperative_tensor<ElementType, SrcExtents, SrcLayout> &source,
    thread metal::cooperative_tensor<ElementType, DstExtents, DstLayout> &destination,
    reduction_operation op = reduction_operation::sum,
    ElementType identity =
        reduction_operation_identity<ElementType>::sum_identity)
{
  __mutmul2d_detail::__reduce_rows<ElementType, SrcExtents, DstExtents, SrcLayout, DstLayout>(
      source, destination, identity, op);
}
```

> ✅ **`reduce_rows` is a FREE FUNCTION at namespace scope in `mpp::tensor_ops`.** Not a member of
> `matmul2d`. Not a member of `cooperative_tensor`. Call it as
> `mpp::tensor_ops::reduce_rows(...)`, or unqualified from inside a
> `using namespace mpp::tensor_ops;`.

The signature, in the order you must type it:

```
reduce_rows(source, destination, op, identity)
```

**Four positional parameters. The identity is LAST.** Note that the internal implementation call
swaps the last two — `__reduce_rows(source, destination, identity, op)` — which is visible in the
quotation above and is a nice reminder that only the *public* order matters to you. If you ever read
the impl header and think the order is different, that is why.

Both operands are **cooperative tensors**. You cannot reduce into a plain `metal::tensor`, and you
cannot reduce a plain tensor. If your data is in threadgroup memory, it has to become a cooperative
tensor first.

The semantics: `source` is a 2-D cooperative tensor; `destination` holds one value per row. Threads
exchange data internally — that is what "cooperative" buys you — so a row can span lanes and you
never write the shuffle yourself.

### 6.2 `reduction_operation` has exactly three cases

✅ **VERIFIED**, `MPPTensorOpsMatMul2d.h:342-347`, quoted complete:

```cpp
enum class reduction_operation
{
  sum,
  max,
  min,
};
```

That is the whole enum. **No `prod`. No `mean`. No `any` / `all`. No `argmax`.** If you need a mean,
reduce with `sum` and divide. If you need an argmax, you are writing it yourself with
`get_multidimensional_index` (§5.3) and a manual comparison, because the reduction API returns
values, not positions.

### 6.3 ⚠️ SILENT FAILURE — the identity default

Read the default argument in §6.1 again:

```cpp
    ElementType identity = reduction_operation_identity<ElementType>::sum_identity
```

and then read what `sum_identity` is — ✅ **VERIFIED**, `MPPTensorOpsMatMul2d.h:379-387`, complete:

```cpp
template <typename ElementType>
struct reduction_operation_identity
{
  static const constant ElementType sum_identity = (ElementType)0;
  static const constant ElementType max_identity =
      metal::numeric_limits<ElementType>::lowest();
  static const constant ElementType min_identity =
      metal::numeric_limits<ElementType>::max();
};
```

> ## ⚠️ SILENT FAILURE
>
> **`reduce_rows`' `identity` parameter defaults to `sum_identity` — which is ZERO — *regardless of
> the operation you pass*.**
>
> ```cpp
> // ❌ WRONG. Compiles. Runs. Returns wrong numbers.
> mpp::tensor_ops::reduce_rows(S, rowMax, mpp::tensor_ops::reduction_operation::max);
> ```
>
> That call computes **`max(0, row)`**. Every row whose true maximum is negative gets `0` instead.
>
> There is **no** warning, **no** static assertion, **no** runtime check, and **no** NaN to alert
> you. The result is a plausible-looking tensor of plausible-looking numbers.
>
> **Why this lands exactly on softmax.** Attention logits are routinely negative — that is the
> normal case, not an edge case, especially after a causal mask sets masked positions to a large
> negative value. Softmax computes `exp(x - rowmax)`. With a correct row max, the largest exponent
> argument is `0` and everything is in `[0, 1]`: that is the entire point of subtracting the max.
> With a row max wrongly clamped to `0`, every logit in a negative row is left unshifted, the
> subsequent `sum` is computed over a differently-scaled set of exponentials, and the normalised
> attention weights come out **wrong but finite, wrong but smooth, and wrong in a way that looks
> like a slightly worse model rather than a bug.** You will chase it in your training data before
> you find it in your kernel.
>
> **The correct call, two ways:**
>
> ```cpp
> // (a) using the header's own identity constant — portable across element types
> mpp::tensor_ops::reduce_rows(
>     S, rowMax,
>     mpp::tensor_ops::reduction_operation::max,
>     mpp::tensor_ops::reduction_operation_identity<float>::max_identity);
>
> // (b) using -INFINITY, which is what session 330 narrates for this exact step
> mpp::tensor_ops::reduce_rows(
>     S, rowMax,
>     mpp::tensor_ops::reduction_operation::max,
>     -INFINITY);
> ```
>
> ✅ **VERIFIED** that session 330 specifies the second form for the softmax row max, 330:100:
> *"Here we'll use the `max` `reduction_operation` with **an initial value of negative INFINITY**."*
>
> **Rule to adopt: never call `reduce_rows` or `reduce_columns` with three arguments.** Pass the
> identity every time, even for `sum` where the default is correct. A four-argument call is
> self-documenting; a three-argument call is indistinguishable from a bug.

**`max_identity` vs `-INFINITY` — which should you pass?** They are not the same value and the
difference matters in two directions.

| | `reduction_operation_identity<T>::max_identity` | `-INFINITY` |
|---|---|---|
| Value for `float` | `numeric_limits<float>::lowest()` = `-FLT_MAX` | `-inf` |
| Works for integer element types | **yes** — `lowest()` is correct for `int8_t`, `int32_t` | **no** — not representable |
| Fully-masked row (all entries `-INFINITY`) | row max = `-FLT_MAX`; `exp(-inf − (−FLT_MAX))` → `exp(-inf)` → `0` | row max = `-inf`; `exp(-inf − (−inf))` = `exp(NaN)` = **NaN** |

The second row is why `max_identity` uses `lowest()` and not `-numeric_limits<T>::max()`: for
integer element types those differ by one, and `lowest()` is the correct choice. ✅ **VERIFIED** from
the struct definition above.

The third row is arithmetic, not an API claim, and this guide flags it as such: **if an entire row
of your logits is `-INFINITY` — which happens with a causal mask on a padded or fully-masked query
row — then `-INFINITY` as the identity produces a `NaN` row and `max_identity` does not.** This is
the classic FlashAttention masked-row hazard and it is worth handling explicitly rather than relying
on the identity to save you.

🟡 **RECONSTRUCTED — the defensive form.** Use `max_identity` for the reduction, and clamp after:

```cpp
    mpp::tensor_ops::reduce_rows(
        S, rowMax, mpp::tensor_ops::reduction_operation::max,
        mpp::tensor_ops::reduction_operation_identity<float>::max_identity);

    // guard fully-masked rows before the exponential
    #pragma unroll full
    for (uint16_t i = 0; i < rowMax.get_capacity(); ++i) {
        if (rowMax.get_mask(i) && !metal::isfinite(rowMax[i])) {
            rowMax[i] = 0.0f;      // a fully-masked row contributes nothing downstream
        }
    }
```

Session 330 narrates `-INFINITY`; the header offers `max_identity`; the masked-row consequence
follows from IEEE arithmetic. All three statements are compatible, and the defensive form above is
this guide's recommendation rather than Apple's.

### 6.4 Pre-shaped reduction destinations

You do not have to work out what shape the reduction destination should be. Ask the op —
✅ **VERIFIED**, `MPPTensorOpsMatMul2d.h:554-565`:

```cpp
  template <typename LeftOperandType, typename RightOperandType, typename ElementType,
            typename CoordType = int,
            typename U = __tensor_ops_detail::__enable_if_t<
                __tensor_ops_detail::__is_integral_v<CoordType>>,
            typename... CoopArgs>
  INLINE cooperative_tensor_row_reduction_destination_t<LeftOperandType, RightOperandType,
                                                        ElementType, CoordType, CoopArgs...>
  get_row_reduction_destination_cooperative_tensor() thread const
```

Column mirror at `:574-584`. These are the intended inputs to `reduce_rows` / `reduce_columns` —
they come out with the right extents and, importantly, a layout the op knows how to map to (§7).

Session 330 corroborates the workflow, ✅ **VERIFIED**, 330:99: *"First, **create a cooperative
tensor to store the reduction output**. Then pass the source and destination to the `reduce_rows`
function."*

Remember the template-parameter convention from §3.2: these are **destination**-style getters, so
TP1/TP2 are **operand** types.

```cpp
auto rowMax = qk_op.template get_row_reduction_destination_cooperative_tensor<
                  decltype(qTile), decltype(kTile), float>();
```

> **Neither talk mentions these two getters.** They are in the header, they exist to remove a
> guessing step, and they are the difference between a reduction that maps cleanly (§7) and one that
> makes `is_iterator_compatible` return false. Prefer them over hand-constructing a destination.

### 6.5 The shared-`ElementType` constraint

Look at `reduce_rows`' template parameter list again: **one** `ElementType`, used for both `source`
and `destination`.

```cpp
template <class ElementType, class SrcExtents, class DstExtents, class SrcLayout, class DstLayout>
inline void reduce_rows(
    thread metal::cooperative_tensor<ElementType, SrcExtents, SrcLayout> &source,
    thread metal::cooperative_tensor<ElementType, DstExtents, DstLayout> &destination, ...)
```

> ✅ **VERIFIED constraint: source and destination must share the same `ElementType`.** You cannot
> reduce a `half` tile into a `float` accumulator with this call. The extents and the layouts may
> differ — that is the whole point — but the element type may not.

The practical consequence for attention: **decide your softmax precision at the matmul, not at the
reduction.** If you want the row max and the running sum in `float` — and you generally do, because
that is where the numerical stability lives — then the destination element type of your Q@Kᵀ matmul
must be `float`, so that `S` is a `float` cooperative tensor. That is the third template argument to
`get_destination_cooperative_tensor`, decided several lines before you get anywhere near a
reduction.

If you have already produced `S` in `half` and now want a `float` reduction, your options are: run
the matmul again with a `float` destination; or convert element-by-element into a second, `float`
cooperative tensor before reducing — which costs you the registers you were trying to save.

Contrast this with `is_iterator_compatible` (§7.4), which **does** take separate `SrcElementType`
and `DstElementType` parameters. The two functions genuinely differ here, and it is not a
transcription error on our part.

### 6.6 `reduce_columns`

✅ **VERIFIED**, `MPPTensorOpsMatMul2d.h:599-609` — the exact mirror, same four parameters, same
defaults, same `ElementType` constraint:

```cpp
template <class ElementType, class SrcExtents, class DstExtents, class SrcLayout, class DstLayout>
inline void reduce_columns(
    thread metal::cooperative_tensor<ElementType, SrcExtents, SrcLayout> &source,
    thread metal::cooperative_tensor<ElementType, DstExtents, DstLayout> &destination,
    reduction_operation op = reduction_operation::sum,
    ElementType identity =
        reduction_operation_identity<ElementType>::sum_identity)
```

Session 330 does not mention it. **The identity footgun applies identically.** Everything in §6.3 is
true of `reduce_columns` word for word.

For attention you want rows, because softmax is row-wise over keys. `reduce_columns` is there for
the transposed layouts and for other operations — layer-norm statistics over a feature axis, for
instance — and it is worth knowing it exists before you transpose a whole tile to get the reduction
axis you wanted.

---

## §7 — `map_iterator` and `is_iterator_compatible`

### 7.1 What problem it solves

After §6 you have two cooperative tensors:

- `S` — the 2-D intermediate, shape `[rows × keys]`, distributed across lanes in some
  implementation-defined layout.
- `rowMax` — one value per row, shape `[rows × 1]` (or whatever the row-reduction destination's
  extents actually are), distributed across lanes in some *different* implementation-defined layout.

Softmax needs `S[r][c] - rowMax[r]`. You know which slot of `S` you are looking at — you are in a
loop over `get_capacity()`. You do **not** know which slot of `rowMax`, in which lane, holds the max
for that same row, and §2.2 rule 2 forbids you from computing it.

Session 330 states the problem and the answer exactly — ✅ **VERIFIED**, 330:101-102:

> *"**These two cooperative tensors have different shapes**, so to help map between them, TensorOps
> also includes a `map_iterator` function. **Given an iterator pointing to an element in the 2D
> tensor, it returns an iterator pointing to the corresponding element in the reduction
> destination.**"*

> *"First, **set up a loop over the 2D cooperative tensor using iterators**. Then **call
> `map_iterator` to map each element to its corresponding row max**. Finally, **dereference these
> iterators to compute SoftMax and store the result back into the cooperative tensor**."*

### 7.2 The declaration

✅ **VERIFIED**, `<metal_cooperative_tensor>:538-557`, quoted complete:

```cpp
  template <class OtherIterator>
  METAL_FUNC enable_if_t<__cooperative_tensor_detail::is_detected<
                             __cooperative_tensor_detail::has_interface_map_index,
                             layout, OtherIterator, iterator>::value,
                         iterator>
  map_iterator(OtherIterator it) thread
  {
    return iterator(*this, layout::template map_index<OtherIterator, iterator>(
        static_cast<const thread void *>(&it._ct), it._idx, static_cast<const thread void *>(this)));
  }
  template <class OtherIterator>
  METAL_FUNC enable_if_t<__cooperative_tensor_detail::is_detected<
                             __cooperative_tensor_detail::has_interface_map_index,
                             layout, OtherIterator, iterator>::value,
                         const_iterator>
  map_iterator(OtherIterator it) thread const
```

Four facts, all ✅ **VERIFIED** from that quotation:

1. **It is a member of `metal::cooperative_tensor`**, declared in `<metal_cooperative_tensor>` — the
   *language* header. It is **not** in `mpp::tensor_ops`. Session 330 calls it "a `map_iterator`
   function" alongside `reduce_rows`, which invites exactly the wrong conclusion.
2. **The argument is an iterator**, of type `OtherIterator` — an iterator obtained from a
   **different** cooperative tensor. Not an index. Not a coordinate. Not the other tensor itself.
3. **The return type is `iterator`** on the non-const overload and `const_iterator` on the const one
   — in both cases an iterator into **`*this`**, positioned at the element corresponding to `it`.
   You can see this in the body: it constructs `iterator(*this, …)`.
4. **It is SFINAE-gated** on the layout implementing a `map_index` interface
   (`has_interface_map_index`). If the two layouts cannot be mapped **at the type level**, the
   overload does not exist and you get a hard compile error — not a wrong answer. That is a good
   property and it is worth knowing that a *compile* failure here means "these layouts are
   structurally unmappable," a different thing from the runtime check in §7.4.

### 7.3 Which object you call it on

This is the detail that decides whether your code compiles, and it follows from fact 3 above.

> **You call `map_iterator` on the tensor you want an iterator INTO, passing an iterator FROM the
> other tensor.**

For softmax that means: iterate `S`, and call `rowMax.map_iterator(it)`.

```cpp
// ✅ correct
for (auto it = S.begin(); it != S.end(); ++it) {
    auto m_it = rowMax.map_iterator(it);     // iterator INTO rowMax
    *it = metal::exp(*it - *m_it);
}
```

```cpp
// ❌ backwards — this asks S for an iterator into S corresponding to a
//    position in S, which is not what you want and may not even compile.
for (auto it = S.begin(); it != S.end(); ++it) {
    auto m_it = S.map_iterator(it);
    ...
}
```

The mnemonic that matches the declaration: `map_iterator` returns `iterator(*this, …)`. `*this` is
the receiver. **The receiver is the destination of the mapping.**

Session 330's phrasing agrees — *"Given an iterator pointing to an element in the 2D tensor, it
returns an iterator pointing to the corresponding element in the reduction destination"* — the
argument is the 2-D tensor's iterator, the result belongs to the reduction destination, so the
reduction destination is the receiver.

### 7.4 `is_iterator_compatible`, and Apple's buggy example

There is a second compatibility predicate, distinct from `is_compatible_as_left_input` (§4.3), and
**session 330 never mentions it.** ✅ **VERIFIED**, `MPPTensorOpsMatMul2d.h:611-633`, quoted complete
including Apple's own usage comment:

```cpp
// Returns whether the iterators are compatible between a source and destination cooperative tensor.
//
// Use this to check whether map_iterator will be return a valid iterator. For example:
//
//     if (is_iterator_compatible(sourceCT, destCT)) {
//         for (auto it = sourceCT.begin(); it != sourceCT.end(); it++) {
//             auto dst_it = destCT.map_iterator(sourceCT)
//
//             *it += *dst_it;
//         }
//     }
//     else {
//          // Fall back to storing sourceCT to threadgroup memory and access via
//          // destCT's multidimensional indices
//     }
template <class SrcElementType, class DstElementType, class SrcExtents, class DstExtents, class SrcLayout, class DstLayout>
inline bool is_iterator_compatible(
    const thread metal::cooperative_tensor<SrcElementType, SrcExtents, SrcLayout> &source,
    const thread metal::cooperative_tensor<DstElementType, DstExtents, DstLayout> &destination)
```

> ⚠️ **Apple's example snippet is itself buggy. Do not paste it.** Two defects, both visible above:
> `destCT.map_iterator(sourceCT)` passes the **tensor** where the declaration requires an
> **iterator** (it should be `destCT.map_iterator(it)`), and the line is missing its semicolon. The
> surrounding structure — the `if`, the loop, the documented `else` fallback — is the part worth
> copying. This series has been audited for exactly this class of error; the fault here is upstream,
> and it is called out so a reader who trusts the SDK does not inherit it.

What the predicate gives you that the SFINAE gate does not:

- It is a **free function** in `mpp::tensor_ops`, taking both tensors by `const thread` reference.
- It returns a **runtime `bool`**, like `is_compatible_as_left_input`.
- ✅ **VERIFIED and worth noting: it permits differing element types.** Its template parameter list
  has both `SrcElementType` and `DstElementType`. That is a real difference from `reduce_rows`
  (§6.5), which forces one shared `ElementType`. So you can map between a `half` source and a
  `float` destination even though you could not have *reduced* between them.
- The documented `else` branch is the same threadgroup-memory fallback as §4.4, with one variation:
  *"access via destCT's multidimensional indices"* — i.e. once the data is in shared memory you
  address it by coordinate (§5.3) rather than by mapped iterator.

**Which check do you need, and when?** They are different questions about different operations and
you may need both in one kernel:

| Predicate | Question it answers | Where it lives | Used before |
|---|---|---|---|
| `is_iterator_compatible(src, dst)` | can I pair elements of these two cooperative tensors positionally? | free fn in `mpp::tensor_ops` | `map_iterator` (§7.3) |
| `op.is_compatible_as_left_input<…>(src)` | can this cooperative tensor become op's left matmul operand? | member of `matmul2d` | `get_left_input_cooperative_tensor(src)` (§4.2) |

In the FlashAttention kernel of §8 you touch both: the first before the softmax loop, the second
before the second matmul.

> **A note on cost, and on when you can hoist the check.** Both predicates are runtime `bool`s but
> their answers depend only on types, descriptors and scope — all compile-time properties of your
> kernel. In a kernel with fixed tile shapes and fixed dtypes the answer cannot change between
> iterations, so hoist the branch out of any loop. Do **not** conclude from that reasoning that you
> can skip the call: "cannot change at runtime" and "you may assume the value" are different
> claims, and only the first is supported by anything we read.

---

## §8 — Building FlashAttention, step by step

### 8.0 The shape of the problem

Session 330's own recap of attention — ✅ **VERIFIED**, 330:81-85:

> *"**Attention is at the core of every transformer network, including LLMs.** To compute attention,
> you first **multiply two matrices together called Q and K**. Next, you **compute SoftMax using
> reductions on the rows of the intermediate matrix**. Finally, you **multiply by a third matrix
> called V**. **The popular FlashAttention algorithm fuses all of these operations together into a
> single kernel.**"*

Six steps follow. They map one-to-one onto §§3-7 of this guide, which is not a coincidence — the
session presents these APIs in the order you need them to build this one kernel.

| Step | What it does | API | Section |
|---:|---|---|---|
| 1 | custom simdgroup mapping so each simdgroup owns complete rows | `execution_simdgroup` scope | §8.1 |
| 2 | slice input tiles by simdgroup ID | `.slice()` | §8.2 |
| 3 | Q@Kᵀ into a cooperative tensor, no memory round-trip | `get_destination_cooperative_tensor` + `run` | §8.3 |
| 4 | row max, with an explicit `-INFINITY`-class identity | `reduce_rows` | §8.4 |
| 5 | pair each element with its row max; softmax in place | `map_iterator` | §8.5 |
| 6 | feed the cooperative tensor straight into the second matmul | `get_left_input_cooperative_tensor(src)` | §8.6 |

> **Evidence status for this whole section.** The **API surface** is ✅ VERIFIED against the headers
> — every identifier below is quoted in §§3-7 with a `path:LINE` citation. The **assembly** —
> variable names, tile constants, loop nesting, the exact slice arguments — is 🟡 **RECONSTRUCTED**
> from session 330's narration plus Apple's own worked examples in `MPPTensorOpsMatMul2d.h`. There
> is **no published code-sample block** for this kernel on session 330's page, and the sample code
> the presenter refers to (*"download the TensorOps sample code"*, 330:137) was not obtained for this
> series. Treat every constant as yours to choose and every structural decision as reasoned rather
> than quoted.

### 8.1 Step 1 — a custom simdgroup mapping

✅ **VERIFIED**, session 330 at 330:86-89:

> *"To implement this with TensorOps, you'll first need to **set up a custom simd group mapping so
> that each simd group owns complete rows of the intermediate matrix. This allows you to compute the
> SoftMax without exchanging data between simd groups.** You can do this using the
> **`execution_simdgroup` operation scope**. This means that **each simd group will perform an
> independent matrix multiplication in parallel.** You can use the **simd group ID to slice your
> input tiles**."*

**Why this is step one, and not an optimisation.** Softmax is row-wise. If a row of `S` is split
across two simdgroups, computing its maximum requires those two simdgroups to exchange data — which
on Apple GPUs means threadgroup memory and a barrier, i.e. exactly the round-trip the whole kernel
exists to avoid. Give each simdgroup **complete rows** and the reduction is internal to a simdgroup,
which `reduce_rows` handles for you with lane shuffles.

This is a **decomposition decision that determines whether the rest of the kernel is possible.** It
is not a tuning knob.

The mechanism is the second template parameter of `matmul2d`. ✅ **VERIFIED**,
`MPPTensorOpsMatMul2d.h:391-402`:

```cpp
template <matmul2d_descriptor Descriptor, typename Scope, class... Args>
class matmul2d : __tensor_ops_detail::op
{
  static_assert(__tensor_ops_detail::__is_tensorops_execution_scope_v<Scope>,
                "Scope template argument should be of op_scope type");
```

And the scope vocabulary, ✅ **VERIFIED** from `__exec/units.h:128-129` and `:185`:

```cpp
using execution_dsimdgroups = execution_simdgroups<__execution_detail::dynamic_size>;
using execution_simdgroup   = execution_simdgroups<1>;
```
```cpp
using execution_thread = execution_threads<1>;
```

| Spelling | Meaning | Real? |
|---|---|---|
| `metal::execution_thread` | one thread; **alias** for `execution_threads<1>` | yes |
| `metal::execution_threads<1>` | same; ✅ only `1` compiles (`static_assert(Size == 1, …)`, `__exec/units.h:131-134`) | yes |
| `metal::execution_simdgroup` | one SIMD group; **alias** for `execution_simdgroups<1>` | yes |
| `metal::execution_simdgroups<N>` | N SIMD groups cooperating on one op | yes |
| `metal::execution_dsimdgroups` | runtime-sized SIMD group count | yes |
| `metal::execution_threadgroup` | — | **NO. Does not exist.** |

> ⚠️ **`execution_threadgroup` is not a thing.** It appears in circulating material and in a natural
> reading of "run this across the whole threadgroup." ✅ **VERIFIED by absence** — zero hits in
> `__exec/units.h`, and the compile-time scope trait at `MPPTensorOpsTraits.h:120-122` admits only
> `execution_threads<1>` and `execution_simdgroups<N>`:
>
> ```cpp
> template <typename T>
> constexpr constant bool __is_tensorops_execution_scope_v = metal::is_execution_thread_v<__remove_cv_t<__remove_ref_ptr_t<T>>> ||
>                                                            metal::is_execution_simdgroups_v<__remove_cv_t<__remove_ref_ptr_t<T>>>;
> ```
>
> If you want the whole threadgroup on one op, that is `execution_simdgroups<N>` with `N` = your
> simdgroup count.

Apple's own guidance on picking between them — ✅ **VERIFIED**, `MPPTensorOpsMatMul2d.h:305-315`:

```
//     metal::execution_thread: The operation will be run on a single thread.
//                              Fragment shaders only support this execution scope.
//     metal::execution_simdgroup: The operation will be run cooperatively by all
//                                 threads in the SIMD group. May be used for finer
//                                 control over tiling by slicing tensors with SIMD IDs.
//     metal::execution_simdgroups<N>: The operation will be executed cooperatively by N
//                                     SIMD groups. Must be used when all threads in a
//                                     threadgroup are cooperatively performing the operation.
//
// It is undefined behavior if the number of SIMD groups dispatched does not
// match the number of SIMD groups that the operation was configured with.
```

Note the middle entry: *"May be used for finer control over tiling by **slicing tensors with SIMD
IDs**."* That is session 330's step 1 and step 2, described by Apple in the header, one sentence
apart. This is not an exotic use of the API; it is the documented reason `execution_simdgroup`
exists as a distinct choice.

**Reading the undefined-behaviour sentence correctly.** Taken literally, *"if the number of SIMD
groups dispatched does not match the number the operation was configured with"* sounds like
`execution_simdgroup` restricts you to dispatching exactly one simdgroup per threadgroup. It does
not. The constraint is about the simdgroups **participating in a given op instance**, and with
`execution_simdgroups<1>` each simdgroup runs its own independent instance. The proof is
shipping code: ✅ **VERIFIED**, MLX uses `matmul2d<desc, metal::execution_simdgroup>` throughout
while dispatching `WM * WN` simdgroups per threadgroup (typically 2×2 = 4, `quantized_nax.metal:74`)
and tiling across them itself.

🟡 The interpretation above is this guide's reading of a terse sentence, corroborated by MLX's
behaviour. What is unambiguous and must be obeyed either way: **every thread of the scope must reach
`run()`** (§4.1), and if you configure `execution_simdgroups<4>` you must dispatch a threadgroup
whose thread count is exactly four simdgroups wide (§10).

The declaration, then:

```cpp
    // Q @ K^T — one op instance per simdgroup
    mpp::tensor_ops::matmul2d<qk_desc, metal::execution_simdgroup> qk_op;
```

and the simdgroup ID you will slice with comes from a kernel attribute:

```cpp
kernel void flash_attention(
    /* … tensors … */
    uint  sgid [[simdgroup_index_in_threadgroup]],
    uint2 tgid [[threadgroup_position_in_grid]])
```

### 8.2 Step 2 — slice input tiles by simdgroup ID

Slicing is guide 01's material; what is new here is *what you slice by*. Normally it is `tgid`; here
it is `tgid` **and** `sgid`, because each simdgroup owns a distinct band of query rows.

✅ **VERIFIED**, `MPPTensorOpsMatMul2d.h:106-114`, Apple's own example with its explanation:

```cpp
//    // Following three lines of code create appropriate slice for this thread
//    // group to work on. E.g. A.slice below creates a
//    // tensor<device half, dextents<int32_t, 2>, tensor_offset>
//    // which has same extents as original tensor A but origin shifted to
//    // (0,tgid.y*64) i.e. mA[x,y] == A[x,tgid.y*64+y]
      auto mA = A.slice(0, tgid.y*64);
      auto mB = B.slice(tgid.x*32, 0);
      auto mC = C.slice(tgid.x*32, tgid.y*64);
```

> ⚠️ **The coordinate-order trap, and it is a real one.** `slice(a, b)` takes **(x, y) = (column,
> row)**, while `matmul2d_descriptor(m, n, …)` takes **(rows, columns)**. In Apple's own example the
> output tile is 64 rows × 32 columns — `matmul2d_descriptor(64, 32, …)` — and the corresponding
> static slice is written `static_slice<32, 64>`, ✅ **VERIFIED** at `MPPTensorOpsMatMul2d.h:143-145`:
>
> ```cpp
> //      auto tA = A.static_slice<dynamic_extent, 64>(0,tgid.y*64);
> //      auto tB = B.static_slice<32, dynamic_extent>(tgid.x*32, 0);
> //      auto tC = C.static_slice<32, 64>(tgid.x*32, tgid.y*64);
> ```
>
> (That is Apple's comment spelling. The member that compiles is templated `slice<32, 64>` —
> `static_slice` does not exist in any toolchain, ✅ toolchain-verified 2026-07-31, guide 01 §5.4.)
> The M extent (64) appears **second** in the slice and **first** in the descriptor. Every kernel
> author transposes this at least once. If your kernel produces a correctly-shaped output full of
> wrong numbers, check this before anything else.

🟡 **RECONSTRUCTED — the attention slices.** Applying that verified pattern to attention: `Q` is
`[queries × head_dim]` with queries on the **y** axis, so the row band for this simdgroup is the
second slice argument.

```cpp
    // this threadgroup handles TILE_M * SG_COUNT query rows;
    // this simdgroup handles TILE_M of them
    const int qRowOrigin = tgid.y * (TILE_M * SG_COUNT) + sgid * TILE_M;

    auto qTile = Q.slice(0, qRowOrigin);   // (x=0 → all of head_dim, y=qRowOrigin)
    auto kTile = K.slice(0, kBlockOrigin); // the key block this iteration handles
    auto vTile = V.slice(0, kBlockOrigin);
    auto oTile = O.slice(0, qRowOrigin);   // same rows as qTile
```

**Every simdgroup gets a different `qRowOrigin` and the same `kBlockOrigin`.** That is the whole
mapping: disjoint query rows, shared key block. It gives each simdgroup complete rows of `S`, which
is what step 1 asked for.

Two practical notes:

- **Bounds.** `slice` produces a `tensor_offset` with the *same extents* as the original, origin
  shifted — so the op still bounds-checks against the full tensor. That is safe and slightly slow.
  Apple's own performance guidance, ✅ **VERIFIED** from the header's prose, is to detect interior
  tiles and use compile-time-extent slices for them (`static_slice` in Apple's comments; templated
  `slice<…>` in code that compiles — guide 01 §5.4): *"for large enough matrices most of thread
  groups will be working on 'inside' tiles, requiring no bounds check… In high performance code we
  can avoid edge checking for inside thread groups and get better performance."* The idiom is
  `if (tgid.x*64 + 63 < M && tgid.y*32 + 31 < N) { /* templated slice<…> path */ } else { /* slice path */ }`.
- ⚠️ **That `if` must not make `run()` non-uniform.** Both branches must be taken uniformly by the
  whole execution scope. Since the condition depends only on `tgid` and compile-time tile sizes, it
  is uniform across the threadgroup — fine. A condition that depended on `sgid` or on data would
  not be.

### 8.3 Step 3 — QK transpose into a cooperative tensor

✅ **VERIFIED**, session 330 at 330:91:

> *"We'll use a **cooperative tensor to store the intermediate matrix so that we can use it as an
> input to the next step without writing it to the memory**."*

That sentence is the thesis of the whole kernel. `S` is born in registers and dies in registers.

🟡 **RECONSTRUCTED — assembly; every symbol verified in §§3-5:**

```cpp
    // Q @ K^T  →  transpose_right = true
    constexpr auto qk_desc = mpp::tensor_ops::matmul2d_descriptor(
        TILE_M,                                   // m — query rows this simdgroup owns
        TILE_N,                                   // n — keys in this block
        HEAD_DIM,                                 // k — reduction over head_dim
        /* transpose_left  = */ false,
        /* transpose_right = */ true,             // K^T
        /* relaxed_precision = */ false,          // see the note below
        mpp::tensor_ops::matmul2d_descriptor::mode::multiply);

    mpp::tensor_ops::matmul2d<qk_desc, metal::execution_simdgroup> qk_op;

    // S lives in registers, distributed across this simdgroup's lanes.
    // Destination getter → OPERAND types (§3).
    auto S = qk_op.template get_destination_cooperative_tensor<
                 decltype(qTile), decltype(kTile), float>();

    // §5.5 — initialise before running. mode::multiply overwrites, but be
    // explicit: this is also the hook for a K-loop that accumulates.
    #pragma unroll full
    for (uint16_t i = 0; i < S.get_capacity(); ++i) {
        if (S.get_mask(i)) { S[i] = 0.0f; }
    }

    qk_op.run(qTile, kTile, S);
```

Four decisions in that block worth defending:

**`transpose_right = true`.** ✅ **VERIFIED** convention, quoted from the header's own comment
(`MPPTensorOpsMatMul2d.h:96-97`, Apple's typo intact):

```
//                             false,  // transpse_left = false for NN and NT and true for TN and TT
//                             false,  // transpse_right = false for NN and TN and true for TN and TT
```

Q@Kᵀ is the NT case: left untransposed, right transposed.

**`k = HEAD_DIM`, a concrete value rather than `dynamic_extent`.** Passing
`static_cast<int>(metal::dynamic_extent)` tells the op to read K from the tensor extents and loop
internally, ✅ **VERIFIED**, `MPPTensorOpsMatMul2d.h:92-95`. That is the convenient path. Tech Talk
111432 gives a concrete reason to prefer the explicit path for a performance kernel — see §14.2 on
simdgroup drift across K. For attention specifically, `head_dim` is small and known at compile time,
so pass it.

**`ElementType = float` for the destination.** Because §6.5: `reduce_rows` forces source and
destination to share an element type, and you want the softmax statistics in `float`. This decision
is made *here*, four steps before the reduction that depends on it.

**`relaxed_precision = false`.** Guide 01 covers this flag. The one thing to say here: MLX hardcodes
it to `true` — ✅ **VERIFIED**, `steel/gemm/nax.h`, the sixth positional argument of its descriptor
call, and noted in this series' correction register at `nax.h:406` — and that is why MLX's host side
gates the whole accelerated path on `MLX_ENABLE_TF32` for float32 inputs
(`mlx/utils.h:195-197`, `matmul.cpp:916-918`). One feature, two halves. If you set
`relaxed_precision = true` in your own kernel, you are opting into the same trade and you should
expose the same escape hatch to your callers. Upstream PR **#3883** ("Warn once when float32 ops
silently run at TF32 precision", closed unmerged 2026-08-03) was opened because MLX's users were
surprised by it — which is a good reason to make yours explicit.

---

### 8.4 Step 4 — the row-max reduction

✅ **VERIFIED**, session 330 at 330:93-100:

> *"To do this, we'll need to compute a couple of reductions on the cooperative tensor. TensorOps
> includes a `reduce_rows` function to help with this. **Threads will exchange data amongst
> themselves to calculate the max for each row. The result is returned in another cooperative
> tensor.**"*
>
> *"Let's set it up. **First, create a cooperative tensor to store the reduction output. Then pass
> the source and destination to the `reduce_rows` function. Here we'll use the `max`
> `reduction_operation` with an initial value of negative INFINITY.**"*

🟡 **RECONSTRUCTED — assembly; the API is §6:**

```cpp
    // A destination shaped for a row reduction of THIS op's output.
    // Reduction destinations follow the DESTINATION convention: operand types (§3.2).
    auto rowMax = qk_op.template get_row_reduction_destination_cooperative_tensor<
                      decltype(qTile), decltype(kTile), float>();

    // ⚠️ FOUR arguments. The identity is NOT optional in practice (§6.3).
    mpp::tensor_ops::reduce_rows(
        S, rowMax,
        mpp::tensor_ops::reduction_operation::max,
        mpp::tensor_ops::reduction_operation_identity<float>::max_identity);
```

> ## ⚠️ SILENT FAILURE — restated here because this is where it bites
>
> Writing that call with **three** arguments —
>
> ```cpp
> reduce_rows(S, rowMax, reduction_operation::max);   // ❌
> ```
>
> — compiles cleanly and computes `max(0, row)`, because the `identity` default is
> `sum_identity == 0` **regardless of the operation**. ✅ VERIFIED,
> `MPPTensorOpsMatMul2d.h:587-597` and `:379-387`.
>
> Attention logits are frequently negative. A row max clamped to zero does not crash, does not NaN,
> and does not produce an obviously broken image or an obviously broken token — it produces a
> **slightly wrong attention distribution**, uniformly, everywhere. You will not find it by looking
> at outputs. Full treatment in §6.3.

**Why `max_identity` rather than the narrated `-INFINITY`.** Session 330 says `-INFINITY` and that is
correct for the reduction itself. `max_identity` is `numeric_limits<float>::lowest()`, which behaves
identically for the reduction and *differently* for a fully-masked row: with `-INFINITY` as the row
max, `exp(-INFINITY - (-INFINITY))` is `exp(NaN)` and the row poisons everything downstream. §6.3
has the full comparison and a clamp. Both choices are defensible; pick one deliberately.

**A second reduction is coming.** Softmax needs the row sum too. It cannot be computed until after
the exponential, so it lives in step 5.

### 8.5 Step 5 — `map_iterator` and softmax in place

✅ **VERIFIED**, session 330 at 330:103-105:

> *"First, **set up a loop over the 2D cooperative tensor using iterators**. Then **call
> `map_iterator` to map each element to its corresponding row max**. Finally, **dereference these
> iterators to compute SoftMax and store the result back into the cooperative tensor**."*

Three things happen here and only the middle one is exotic: subtract the row max, exponentiate,
normalise. All of it in registers, all of it in place — `S` is overwritten with `P`.

🟡 **RECONSTRUCTED — assembly; the API is §7:**

```cpp
    // Guard first (§7.4). The answer depends only on types and descriptors,
    // so hoist this out of any surrounding K-block loop.
    if (mpp::tensor_ops::is_iterator_compatible(S, rowMax)) {

        // --- numerator: exp(s - rowmax), in place ---
        for (auto it = S.begin(); it != S.end(); ++it) {
            auto m_it = rowMax.map_iterator(it);   // receiver = destination (§7.3)
            *it = metal::exp(*it - *m_it);
        }

        // --- denominator: row sums of the exponentials ---
        auto rowSum = qk_op.template get_row_reduction_destination_cooperative_tensor<
                          decltype(qTile), decltype(kTile), float>();

        mpp::tensor_ops::reduce_rows(
            S, rowSum,
            mpp::tensor_ops::reduction_operation::sum,
            mpp::tensor_ops::reduction_operation_identity<float>::sum_identity);

        // --- normalise, in place ---
        for (auto it = S.begin(); it != S.end(); ++it) {
            auto s_it = rowSum.map_iterator(it);
            *it = *it / *s_it;
        }

    } else {
        // Documented fallback (§7.4): store S to threadgroup memory and index
        // it by destCT's multidimensional indices instead of by mapped iterator.
        // Structure this branch so it rejoins before step 6 — see §4.4.
    }
```

Six notes on that block, in descending order of how likely you are to get it wrong:

**1. The iterator loop and the `get_capacity()` loop are two styles for the same thing.** §5.2's
`for (uint16_t i = 0; i < ct.get_capacity(); ++i)` with `get_mask(i)` and `ct[i]`, versus
`for (auto it = ct.begin(); it != ct.end(); ++it)` with `*it`. Use the iterator form here, because
`map_iterator` takes an iterator. 🔴 **GAP:** whether `begin()`/`end()` already skip invalid slots —
i.e. whether an iterator loop needs a `get_mask` equivalent — is **unverified**. Apple's iterator
example (§7.4) contains no mask check while Apple's index example (§5.2) does. **What would resolve
it:** reading the `iterator` class in `<metal_cooperative_tensor>:559-577`. **Safe default:** if you
can express your work with the index form, prefer it and mask; if you need `map_iterator`, use the
iterator form and verify against a CPU reference before shipping.

**2. `is_iterator_compatible` takes (source, destination) in that order** — ✅ VERIFIED from its
declaration — while `map_iterator` is called on the *destination*. The two read backwards from each
other. It is correct as written above.

**3. The sum's identity is genuinely `sum_identity`**, so the default would be right — and it is
still written out. §6.3's rule: never a three-argument reduction call. A reader scanning your kernel
should not have to remember which of your two reductions needed the identity.

**4. `metal::exp` versus `exp`.** With `using namespace metal;` in scope, `exp` resolves. Without
it, qualify. This series prefers qualified calls in guide code because kernel sources get pasted
into `TorchMetalKernel` string literals (§12) where you do not control the surrounding namespace
declarations.

**5. Two passes over `S`, not one.** You cannot fuse the exponential and the normalisation, because
the row sum is not known until every element has been exponentiated. That is inherent to softmax,
not an API limitation. Both passes are over registers, so the cost is arithmetic, not memory.

**6. The `else` branch must rejoin.** Whatever the fallback does, both branches must arrive at
step 6 with a usable `S`, and every thread of the execution scope must reach step 6's `run()`
(§4.1). Structure the branch as "how `S` gets its values," never as "whether we continue."

### 8.6 Step 6 — the second matmul, against V

This is the payoff, and the capability that dates the whole guide to 26.3.

✅ **VERIFIED**, session 330 at 330:106-109 — quoted again because it contains the API contract:

> *"Now we're ready to multiply this cooperative tensor by V. **In macOS 26, you would have had to
> first store it to threadgroup memory. But it's now possible to use cooperative tensors directly as
> inputs to matmul operations.**"*
>
> *"To do this, call **`get_left_input_cooperative_tensor` method, passing the source cooperative
> tensor as an argument**. You can then pass the result as an input to the second matmul operation."*
>
> *"**One thing to watch out for: not every cooperative tensor can be reused as an input…** So before
> you do this, call the `is_compatible_as_left_input` or `is_compatible_as_right_input` method to
> check for compatibility."*
>
> *"If it returns true, you're good to go. **If not, you'll need to store and reload the data through
> threadgroup memory to convert it to the correct layout. Either way, the call to `op.run` is the
> same.**"*

🟡 **RECONSTRUCTED — assembly; the API is §4:**

```cpp
    // P @ V — both untransposed
    constexpr auto pv_desc = mpp::tensor_ops::matmul2d_descriptor(
        TILE_M,                                   // m — same query rows
        HEAD_DIM,                                 // n — output feature width
        TILE_N,                                   // k — reduce over this key block
        /* transpose_left  = */ false,
        /* transpose_right = */ false,
        /* relaxed_precision = */ false,
        // accumulate across key blocks if you loop (§8.7)
        mpp::tensor_ops::matmul2d_descriptor::mode::multiply_accumulate);

    mpp::tensor_ops::matmul2d<pv_desc, metal::execution_simdgroup> pv_op;

    auto O = pv_op.template get_destination_cooperative_tensor<
                 /* left  operand type → filled in below */ decltype(S),
                 decltype(vTile),
                 float>();

    #pragma unroll full
    for (uint16_t i = 0; i < O.get_capacity(); ++i) {
        if (O.get_mask(i)) { O[i] = 0.0f; }
    }

    // --- the fusion, guarded ---
    if (pv_op.template is_compatible_as_left_input<float, half, float>(S)) {

        // register-to-register: S becomes pv_op's left operand with no memory traffic
        auto lhs = pv_op.template get_left_input_cooperative_tensor<float, half, float>(S);
        pv_op.run(lhs, vTile, O);

    } else {
        // §4.4 — store/reload through threadgroup memory to convert the layout
        auto tgTile = /* inline threadgroup tensor over scratch[sgid] */;
        S.store(tgTile);
        metal::threadgroup_barrier(metal::mem_flags::mem_threadgroup);

        auto lhs = pv_op.template get_left_input_cooperative_tensor<float, half, float>();
        lhs.load(tgTile);
        pv_op.run(lhs, vTile, O);      // "Either way, the call to op.run is the same."
    }

    O.store(oTile);   // the ONLY write to memory in the whole kernel
```

Read the template arguments in the two calls, because they are the §3 asymmetry doing its job in a
single block:

- `is_compatible_as_left_input<float, half, float>(S)` — **element** types: `pv_op`'s left element
  type (`float`, matching `S`), right element type (`half`, matching `V`), destination element type
  (`float`). Plus the source, deduced.
- `get_left_input_cooperative_tensor<float, half, float>(S)` — the same three explicit element
  types, plus `CoordType` defaulted, plus the source deduced.
- `get_destination_cooperative_tensor<decltype(S), decltype(vTile), float>()` — **operand** types,
  then the element type.

Three getters, two conventions, one block. If you take one thing from this guide, take that.

> **A subtlety in the destination's left-operand type.** `O`'s destination getter above is
> parameterised on `decltype(S)` — the *original* cooperative tensor — while `run()` is called with
> `lhs`, the converted one, whose type is `cooperative_tensor_left_input_t<…>` and is **not**
> `decltype(S)`.
>
> 🔴 **GAP.** We could not verify from the headers whether the destination must be parameterised on
> the *converted* left-operand type (`decltype(lhs)`) rather than the source type. The
> `enable_if` on `get_destination_cooperative_tensor` accepts either — both are cooperative tensor
> types — so it will compile either way, and a mismatched destination layout is exactly the class of
> defect that produces wrong numbers rather than errors. **What would resolve it:** compiling both
> forms and comparing against a CPU reference on device; or an Apple sample that performs a
> two-matmul fusion. **Safe default: parameterise the destination on `decltype(lhs)`, constructing
> it *inside* each branch after `lhs` exists.** That is the form the assembled kernel in §9 uses,
> and it is strictly more likely to be right, at the cost of duplicating the zero-init loop.

### 8.7 What the six steps leave out

Session 330's six steps produce a correct fused attention kernel for **one key block**. A production
FlashAttention loops over key blocks, and that loop is where the remaining difficulty lives. This
subsection is 🟡 **RECONSTRUCTED reasoning**, corroborated by MLX's shipping implementation, not
narrated by Apple.

The problem: `rowMax` is computed from the key block you have seen so far. When the next block
arrives with a larger max, every partially accumulated output is scaled wrong. The standard fix —
the "online softmax" — is to rescale the running accumulator whenever the running max changes:

```
for each key block:
    S      = Q @ Kᵀ(block)
    m_new  = max(m_old, rowmax(S))
    factor = exp(m_old - m_new)
    P      = exp(S - m_new)
    l      = l * factor + rowsum(P)          // running denominator
    O      = O * factor + P @ V(block)       // rescale, then accumulate
    m_old  = m_new
normalise: O = O / l
```

✅ **VERIFIED** that MLX implements exactly this, in exactly this order —
`steel/attn/kernels/steel_attention_nax.h:395,398,413,416`:

```cpp
    Stile.template row_reduce<MaxOp>(new_max);
    ...
    Stile.template row_bin_op<ExpSubOp>(new_max);
    ...
    Stile.template row_reduce<SumOp>(sum_score);
    ...
    Otile.template row_bin_op<MulOp>(factor);
```

`row_reduce<MaxOp>` → running max. `row_bin_op<ExpSubOp>` → `exp(S − m_new)`. `row_reduce<SumOp>` →
the running denominator. `row_bin_op<MulOp>(factor)` on the **output** tile → the rescale. Those are
MLX's own fragment-level primitives, not MPP's (§11), but the algorithm is the one above.

What that costs you in the portable API:

- **You need the running `m`, `l` and `O` to survive across loop iterations.** All three are
  cooperative tensors, and §2.2 rule 1 says their lifetime is their enclosing scope — so declare
  them **outside** the key-block loop and never let them go out of scope inside it.
- **`O`'s descriptor must be `mode::multiply_accumulate`**, and you must apply the rescale to `O`
  *before* the next `run()` accumulates into it. There is no combined "scale-and-accumulate" mode;
  `mode` has exactly two cases (guide 01).
- **The rescale is an element loop over `O` paired with `m`**, so it needs `map_iterator` between
  `O` and the row-shaped `m` — i.e. a *second* `is_iterator_compatible` pair, between different
  tensors than the one in §8.5. Check both.
- **Two of these loops per key block plus two reductions is real ALU work.** Tech Talk 111432's
  argument for the neural accelerator's physical placement — *"This physical locality enables fast,
  seamless interoperation with code running on other GPU pipelines"* — is exactly the property this
  loop exercises: alternating matrix work and elementwise ALU work with no hand-off.

Also missing from the six steps, and needed by any real kernel:

- **Causal / padding masking.** §5.3 has the `get_multidimensional_index` recipe. Apply it to `S`
  after the Q@Kᵀ and before the row max, and remember that a fully-masked row is the NaN hazard
  §6.3 describes.
- **The `1/sqrt(head_dim)` scale.** Fold it into `Q` on the host, or apply it in the element loop
  before the exponential. Folding it into `Q` is free.
- **Multiple heads and batches.** These are grid dimensions, not kernel structure — `tgid.z` or an
  explicit index — and they do not change anything above.
- **Dropout.** Not addressed here at all.

---

## §9 — The assembled kernel

Everything above, in one file.

> 🟡 **RECONSTRUCTED — read this before you copy it.**
>
> **What is verified:** every identifier, every template-parameter *kind*, every argument order,
> every default value, and the two compatibility branches. Each is quoted with a `path:LINE`
> citation in §§3-7 above.
>
> **What is not:** the assembly. Tile constants, variable names, the loop nesting, the exact slice
> arguments, the threadgroup-memory scratch sizing, and the choice to construct `O` inside each
> branch (§8.6's GAP) are this guide's reasoning, not Apple's code. **This listing has not been
> compiled.** No M5-class hardware was available and nothing in this series was built or run.
>
> **Use it as a skeleton to type against with the headers open**, not as a drop-in. Validate against
> a CPU reference before you trust a single number out of it.

```cpp
// ─────────────────────────────────────────────────────────────────────────────
//  Fused attention with Metal TensorOps
//
//  Requires: Metal 4 toolchain, __HAVE_TENSOR__, deployment target >= 26.3
//            (cooperative tensors as matmul INPUTS — see §0.2)
//
//  Layout decision (§8.1): each simdgroup owns TILE_M complete query rows, so
//  the softmax reduction never crosses a simdgroup boundary.
// ─────────────────────────────────────────────────────────────────────────────

#if __has_include(<MetalPerformancePrimitives/MetalPerformancePrimitives.h>)
#  include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>
#else
#  error "TensorOps requires MetalPerformancePrimitives; check your Metal toolchain."
#endif

#include <metal_stdlib>
#include <metal_tensor>
#include <metal_cooperative_tensor>

using namespace metal;
namespace tops = mpp::tensor_ops;

// ── tunables ────────────────────────────────────────────────────────────────
//  TILE_M   query rows per simdgroup
//  TILE_N   keys per block
//  HEAD_DIM attention head width
//  SG_COUNT simdgroups per threadgroup — MUST match the host dispatch (§10)
constant constexpr int TILE_M   = 16;
constant constexpr int TILE_N   = 32;
constant constexpr int HEAD_DIM = 64;
constant constexpr int SG_COUNT = 4;

// ── descriptors ─────────────────────────────────────────────────────────────
//  Seven positional arguments, no named parameters. The 7th defaults to
//  mode::multiply — pass it explicitly, always (§5.5, guide 01).
constexpr constant auto kQKDesc = tops::matmul2d_descriptor(
    /* m                 */ TILE_M,
    /* n                 */ TILE_N,
    /* k                 */ HEAD_DIM,
    /* transpose_left    */ false,
    /* transpose_right   */ true,          // Q @ K^T  → NT
    /* relaxed_precision */ false,
    /* matmul_mode       */ tops::matmul2d_descriptor::mode::multiply);

constexpr constant auto kPVDesc = tops::matmul2d_descriptor(
    /* m                 */ TILE_M,
    /* n                 */ HEAD_DIM,
    /* k                 */ TILE_N,
    /* transpose_left    */ false,
    /* transpose_right   */ false,         // P @ V    → NN
    /* relaxed_precision */ false,
    /* matmul_mode       */ tops::matmul2d_descriptor::mode::multiply_accumulate);

using qk_op_t = tops::matmul2d<kQKDesc, execution_simdgroup>;
using pv_op_t = tops::matmul2d<kPVDesc, execution_simdgroup>;

// ─────────────────────────────────────────────────────────────────────────────
kernel void flash_attention(
    tensor<device half,  dextents<int32_t, 2>>  Q      [[buffer(0)]],
    tensor<device half,  dextents<int32_t, 2>>  K      [[buffer(1)]],
    tensor<device half,  dextents<int32_t, 2>>  V      [[buffer(2)]],
    tensor<device float, dextents<int32_t, 2>>  Out    [[buffer(3)]],
    constant uint&                              nKeys  [[buffer(4)]],
    uint2 tgid [[threadgroup_position_in_grid]],
    uint  sgid [[simdgroup_index_in_threadgroup]])
{
    // Per-simdgroup scratch for the §4.4 / §7.4 fallback paths. Indexed by sgid
    // because each simdgroup owns different rows and would otherwise race.
    threadgroup float scratch[SG_COUNT][TILE_M * TILE_N];

    qk_op_t qk_op;
    pv_op_t pv_op;

    // ── Step 1 + 2 — mapping and slicing ────────────────────────────────────
    // Disjoint query rows per simdgroup; shared key blocks.
    // NOTE the (x, y) = (column, row) order of slice() — §8.2.
    const int qRowOrigin = int(tgid.y) * (TILE_M * SG_COUNT) + int(sgid) * TILE_M;

    auto qTile = Q.slice(0, qRowOrigin);
    auto oTile = Out.slice(0, qRowOrigin);

    // ── running online-softmax state, declared OUTSIDE the loop (§8.7) ──────
    // Their lifetime is this scope; letting them fall out of scope inside the
    // loop would deallocate the registers they own (§2.2 rule 1).
    auto runMax = qk_op.template get_row_reduction_destination_cooperative_tensor<
                      decltype(qTile), decltype(Q), float>();
    auto runSum = qk_op.template get_row_reduction_destination_cooperative_tensor<
                      decltype(qTile), decltype(Q), float>();

    #pragma unroll full
    for (uint16_t i = 0; i < runMax.get_capacity(); ++i) {
        if (runMax.get_mask(i)) {
            runMax[i] = numeric_limits<float>::lowest();   // NOT -INFINITY (§6.3)
            runSum[i] = 0.0f;
        }
    }

    // The output accumulator also survives the loop.
    auto accO = pv_op.template get_destination_cooperative_tensor<
                    decltype(qTile), decltype(V), float>();
    #pragma unroll full
    for (uint16_t i = 0; i < accO.get_capacity(); ++i) {
        if (accO.get_mask(i)) { accO[i] = 0.0f; }
    }

    // ── the key-block loop ──────────────────────────────────────────────────
    for (uint kBlock = 0; kBlock < nKeys; kBlock += TILE_N) {

        auto kTile = K.slice(0, int(kBlock));
        auto vTile = V.slice(0, int(kBlock));

        // ── Step 3 — Q @ K^T, straight into registers ───────────────────────
        auto S = qk_op.template get_destination_cooperative_tensor<
                     decltype(qTile), decltype(kTile), float>();

        #pragma unroll full
        for (uint16_t i = 0; i < S.get_capacity(); ++i) {
            if (S.get_mask(i)) { S[i] = 0.0f; }
        }

        qk_op.run(qTile, kTile, S);

        // ── optional: causal mask, in registers (§5.3) ──────────────────────
        #pragma unroll full
        for (uint16_t i = 0; i < S.get_capacity(); ++i) {
            if (!S.get_mask(i)) { continue; }
            auto ids = S.get_multidimensional_index(i);
            // 🔴 component order is UNVERIFIED — see §5.3's GAP box
            if (int(kBlock) + int(ids[1]) > qRowOrigin + int(ids[0])) {
                S[i] = numeric_limits<float>::lowest();
            }
        }

        // ── Step 4 — block row max, then the running max ────────────────────
        auto blkMax = qk_op.template get_row_reduction_destination_cooperative_tensor<
                          decltype(qTile), decltype(kTile), float>();

        // ⚠️ FOUR arguments. Three would silently compute max(0, row) (§6.3).
        tops::reduce_rows(
            S, blkMax,
            tops::reduction_operation::max,
            tops::reduction_operation_identity<float>::max_identity);

        // ── Step 5 — softmax in place, plus the online rescale (§8.7) ───────
        if (tops::is_iterator_compatible(S, blkMax)) {

            // new running max, and the rescale factor for what we already have
            #pragma unroll full
            for (uint16_t i = 0; i < runMax.get_capacity(); ++i) {
                if (!runMax.get_mask(i)) { continue; }
                const float m_old = runMax[i];
                const float m_new = metal::max(m_old, blkMax[i]);
                blkMax[i] = metal::isfinite(m_old) ? metal::exp(m_old - m_new) : 0.0f;
                runMax[i] = m_new;    // blkMax now carries the RESCALE FACTOR
            }

            // exponentiate against the NEW running max
            for (auto it = S.begin(); it != S.end(); ++it) {
                auto m_it = runMax.map_iterator(it);       // receiver = destination (§7.3)
                *it = metal::exp(*it - *m_it);
            }

            // block row sums
            auto blkSum = qk_op.template get_row_reduction_destination_cooperative_tensor<
                              decltype(qTile), decltype(kTile), float>();
            tops::reduce_rows(
                S, blkSum,
                tops::reduction_operation::sum,
                tops::reduction_operation_identity<float>::sum_identity);

            // fold into the running denominator
            #pragma unroll full
            for (uint16_t i = 0; i < runSum.get_capacity(); ++i) {
                if (runSum.get_mask(i)) {
                    runSum[i] = runSum[i] * blkMax[i] + blkSum[i];
                }
            }

            // rescale the accumulated output by the same factor
            if (tops::is_iterator_compatible(accO, blkMax)) {
                for (auto it = accO.begin(); it != accO.end(); ++it) {
                    auto f_it = blkMax.map_iterator(it);
                    *it = *it * (*f_it);
                }
            } else {
                // fallback: coordinate-indexed rescale via threadgroup memory
                // (§7.4's documented else-branch)
            }

        } else {
            // fallback: store S to scratch[sgid], reload by coordinate (§7.4)
        }

        // ── Step 6 — P @ V, fused ───────────────────────────────────────────
        if (pv_op.template is_compatible_as_left_input<float, half, float>(S)) {

            auto lhs = pv_op.template get_left_input_cooperative_tensor<float, half, float>(S);
            pv_op.run(lhs, vTile, accO);            // multiply_accumulate

        } else {
            // §4.4 — layout conversion via threadgroup memory
            auto tgTile = /* inline tensor over scratch[sgid]; see guide 01 */;
            S.store(tgTile);
            threadgroup_barrier(mem_flags::mem_threadgroup);

            auto lhs = pv_op.template get_left_input_cooperative_tensor<float, half, float>();
            lhs.load(tgTile);
            pv_op.run(lhs, vTile, accO);            // identical call (§4.4)

            threadgroup_barrier(mem_flags::mem_threadgroup);   // before scratch is reused
        }
    }

    // ── final normalisation, still in registers ─────────────────────────────
    if (tops::is_iterator_compatible(accO, runSum)) {
        for (auto it = accO.begin(); it != accO.end(); ++it) {
            auto l_it = runSum.map_iterator(it);
            *it = *it / metal::max(*l_it, 1e-30f);   // guard a fully-masked row
        }
    }

    // ── the ONLY write to memory in the whole kernel ────────────────────────
    accO.store(oTile);
}
```

### 9.1 What to check first when it produces wrong numbers

In the order these actually go wrong:

| Symptom | First suspect | Section |
|---|---|---|
| Output correctly shaped, uniformly a bit wrong | `reduce_rows` called with three arguments | §6.3 |
| Only the last key block appears in the output | descriptor mode left at `multiply` | §5.5 |
| Output transposed, or right shape / wrong content | `slice`'s `(x, y)` vs descriptor's `(m, n)` | §8.2 |
| NaNs in rows near the start of a causal mask | fully-masked row + `-INFINITY` identity | §6.3 |
| Garbage that changes between runs | destination not zero-initialised | §5.5 |
| Compile error deep in `__tensor_ops_detail` | element vs operand types | §3.3 |
| "no member named `matmul2d`" | `__HAVE_TENSOR__` undefined | §0.2 |
| Correct but slow; profiler shows 0% accelerator | you are on the fallback shader path | §14.4 |

### 9.2 What to validate before shipping

1. **Against a CPU reference**, elementwise, with a tolerance you chose deliberately rather than
   inherited. `relaxed_precision` and accumulation order both move the last few bits.
2. **With a fully-masked row** in the input. This is the case that separates `-INFINITY` from
   `max_identity` and it will not appear in random test data.
3. **With `nKeys` not a multiple of `TILE_N`**, to exercise the edge tile.
4. **With both branches of both compatibility checks forced.** If `is_compatible_as_left_input`
   returns true on your hardware and dtypes, the `else` branch is dead code that has never executed
   — and it is the branch that will run on the next dtype or the next GPU. Temporarily invert the
   condition and run the whole suite through the fallback.
5. **On device, not in the simulator**, and on each GPU generation you support. The cooperative
   tensor layout is *"implementation defined"* and depends on *"operation, data type, number of
   threads in opscope"* — three things that can differ across generations.

---

## §10 — The host side you cannot skip

This guide is about the shader. There is exactly one host-side fact that will silently corrupt your
kernel if you get it wrong, and one runtime gate worth copying.

### 10.1 Threads per threadgroup must match your execution scope

✅ **VERIFIED**, `MPPTensorOpsMatMul2d.h:75-79` — Apple's own host-side snippet, quoted:

```objc
//    id<MTLComputePipelineState> state = [device newComputePipelineState:...];
//    NSUInteger simdgroupWidth = [state threadExecutionWidth];
//    ...
//    [encoder dispatchThreadgroups:threadgroups
//    threadPerThreadgroups:MTLSizeMake(simdgroupWidth*4, 1, 1)];
```

The `*4` is not arbitrary: that example's kernel uses `execution_simdgroups<4>`. The rule:

> **`execution_simdgroups<N>` ⟺ `threadExecutionWidth * N` threads per threadgroup.**

And the consequence of getting it wrong, ✅ **VERIFIED**, `MPPTensorOpsMatMul2d.h:314-315`:

```
// It is undefined behavior if the number of SIMD groups dispatched does not
// match the number of SIMD groups that the operation was configured with.
```

> ⚠️ **SILENT FAILURE.** Undefined behaviour here does not mean a validation-layer error. It means
> the op reads lane data that belongs to threads which are not participating. There is no Metal
> validation check for this and no runtime assertion — it is a compile-time template parameter on
> one side of the process boundary and a runtime `MTLSize` on the other, with nothing connecting
> them.
>
> **Mitigation:** never hardcode `32`. Read `threadExecutionWidth` from the pipeline state and
> multiply. Better, put your simdgroup count in one header shared between the Metal source and the
> host source, and derive both sides from it.

For the §9 kernel, which uses `execution_simdgroup` (= `<1>`) per op with `SG_COUNT` simdgroups per
threadgroup tiling above the ops:

🟡 **RECONSTRUCTED — host dispatch, in Swift:**

```swift prelude:guide-context
let state = try device.makeComputePipelineState(function: fn)
let simdWidth = state.threadExecutionWidth          // do NOT assume 32

// SG_COUNT must equal the constant in the Metal source.
let sgCount = 4
let threadsPerThreadgroup = MTLSize(width: simdWidth * sgCount, height: 1, depth: 1)

// each threadgroup covers TILE_M * SG_COUNT query rows
let rowsPerThreadgroup = 16 * sgCount
let threadgroups = MTLSize(
    width:  1,
    height: (queryCount + rowsPerThreadgroup - 1) / rowsPerThreadgroup,
    depth:  1)

encoder.dispatchThreadgroups(threadgroups,
                             threadsPerThreadgroup: threadsPerThreadgroup)
```

Note the asymmetry with the `execution_simdgroups<N>` case: here `sgCount` is *your* tiling
parameter, not the op's scope, so the op does not constrain it — but your kernel's
`simdgroup_index_in_threadgroup` arithmetic and your scratch array sizing both do. Keep them in one
place.

### 10.2 The remaining host-side surface, and where it lives

Not covered here, deliberately: `MTLTensorDescriptor` and `newTensorWithDescriptor:`, tensor stride
alignment (ML usage requires 64-byte stride alignment; sub-byte dtypes require 128-byte),
`MTLTensorUsage.machineLearning`, and `MTL4MachineLearningCommandEncoder`. All of it is guide 01's
territory and none of it changes anything in this guide.

One thing worth repeating from guide 01 because it catches people who write shader code first: in
Metal Shading Language the type is **`metal::tensor<…>`**. `MTLTensor` is the **host-side**
Objective-C/Swift protocol name and does not exist in a shader. ✅ **VERIFIED** — `metal_tensor:326`
declares `metal::tensor`; the `MTLTensor` spelling appears only in `MTLTensor.h` on the host side.
Mixing the two produces a confusing diagnostic and is a reliable tell that a code sample was written
from a talk rather than from a compiler.

### 10.3 Runtime gating

Neither Metal nor MPP exposes a "does this GPU have a neural accelerator" query. This surprises
everyone, so it is worth stating plainly:

> ✅ **VERIFIED: there is no capability query for the M5 neural accelerator.** No `supportsFamily`
> case, no feature flag, no `MTLDevice` property. The only shipping approach is to infer it from the
> GPU family generation.

MLX's inference, ✅ **VERIFIED**, `mlx/backend/metal/device.cpp:944-963`, quoted complete:

```cpp
bool is_nax_available() {
#ifdef MLX_METAL_NO_NAX
  return false;
#else
  auto _check_nax = []() {
    bool can_use_nax = false;
    if (__builtin_available(
            macOS 26.2, iOS 26.2, tvOS 26.2, visionOS 26.2, *)) {
      can_use_nax = true;
    }
    auto& d = metal::device(mlx::core::Device::gpu);
    auto arch = d.get_architecture().back();
    auto gen = d.get_architecture_gen();
    can_use_nax &= gen >= (arch == 'p' ? 18 : 17);
    return can_use_nax;
  };
  static bool is_nax_available_ = _check_nax();
  return is_nax_available_;
#endif
}
```

Two conditions: an OS check via `__builtin_available`, and **`get_architecture_gen() >= 17`, or
`>= 18` when the architecture string's last character is `'p'`**. That last line is MLX's M5-class
detection. Corroboration that generation 17 corresponds to the M5 generation: upstream PR **#3791**
is titled *"Raise qmv batch limit for large matrices on **M5-class GPUs**"* and gates on the same
value.

**But do not build your correctness on this.** Two reasons:

1. **You almost certainly do not need it.** ✅ **VERIFIED**, Tech Talk 111432: *"**The API is
   portable. The same code runs across Apple's entire GPU family from M1 to M5. On older GPUs
   without neural accelerators, TensorOps falls back to optimized shader implementations.**"* A
   TensorOps kernel is correct everywhere. The generation check is a *performance* decision —
   whether to select this kernel over a different algorithm — not a correctness gate.
2. **The heuristic is undocumented.** `get_architecture_gen()` is MLX's own helper
   (`mlx/backend/metal/device.h:159`) parsing an architecture string. Nothing in Apple's headers
   promises that generation numbers mean this.

🔴 **GAP — architecture-string semantics.** What `get_architecture()` returns on each device, what
the `'p'` / `'s'` / `'d'` suffixes mean, and whether generation numbering is a stable contract are
all **unverified**. MLX branches on `'s'` and `'d'` elsewhere for an unrelated threshold
(`matmul.cpp:919-920`). **What would resolve it:** Apple documentation for the architecture string,
or an empirical survey across devices. **Safe default:** gate on `__builtin_available` for the OS,
write one TensorOps kernel, and let Apple's fallback handle older GPUs. Add a generation check only
if you have measured that a *different algorithm* wins on pre-M5 hardware.

---

## §11 — The expert escape hatch: what MLX does instead

MLX is the most instructive counter-example available: it is written by Apple, against these
headers, for this hardware, and it **declines almost every portable API in this guide.**

Understanding why is the difference between following a recipe and knowing when to leave it.

### 11.1 MLX's entire contact surface with TensorOps

✅ **VERIFIED** by exhaustive grep over the MLX tree:

```
$ grep -rho 'mpp::[A-Za-z0-9_:]*' mlx/ | sort | uniq -c | sort -rn
   4 mpp::tensor_ops::matmul2d_descriptor::mode::multiply_accumulate
   4 mpp::tensor_ops::matmul2d_descriptor
   4 mpp::tensor_ops::matmul2d
```

**Twelve tokens, in four sites** — two in `steel/gemm/nax.h` and two in its byte-identical twin
`steel/attn/nax.h`. That is all of it. Everything else in MLX called "NAX" is MLX's own tiling code
layered on top.

And by negative search, ✅ **VERIFIED** — MLX contains **zero occurrences** of:

`reduce_rows` · `reduce_columns` · `map_iterator` · `is_iterator_compatible` ·
`is_compatible_as_left_input` · `is_compatible_as_right_input` · `tensor_handle` · `tensor_inline` ·
`tensor_offset` · `dextents` · `.slice(`

Read that list against this guide's table of contents. MLX uses §3 and §4.1. It uses **none** of
§4.2, §4.3, §5.3, §6, §7 or §8.2.

### 11.2 What it does instead

**It rolls its own row reduction over its own fragment layout.** ✅ **VERIFIED**,
`steel/gemm/nax.h:353-371`, quoted complete:

```cpp
  template <typename Op, typename T>
  METAL_FUNC static constexpr void row_reduce(
      thread const dtype_frag_t<T>& inp_vals,
      thread T* reduced_vals) {
    STEEL_PRAGMA_UNROLL
    for (short i = 0; i < kElemRows; i++) {
      T thr_reduce = Op::apply(
          Op::apply(inp_vals[i * kElemCols + 0], inp_vals[i * kElemCols + 1]),
          Op::apply(inp_vals[i * kElemCols + 2], inp_vals[i * kElemCols + 3]));

      T qgr_reduce = simd_shuffle_xor(thr_reduce, ushort(1));
      qgr_reduce = Op::apply(thr_reduce, qgr_reduce);

      T sgr_reduce = simd_shuffle_xor(qgr_reduce, ushort(8));
      sgr_reduce = Op::apply(qgr_reduce, sgr_reduce);

      reduced_vals[i] = Op::apply(reduced_vals[i], sgr_reduce);
    }
  }
```

Four values combined within a thread, then two `simd_shuffle_xor` steps with strides 1 and 8. Those
constants are only correct because MLX knows exactly how its 16×16 fragment maps to a 32-lane
simdgroup: `kFragRows = kFragCols = 16`, `kElemsPerFrag = (16*16)/32 = 8`, `kElemRows = 2`,
`kElemCols = 4`, and a `get_coord()` helper at `steel/gemm/nax.h:45-51` that makes the mapping
explicit. ✅ VERIFIED.

**It never calls `get_mask`.** ✅ VERIFIED (§5.2). Its descriptor exactly matches its fragment size,
so every slot is live.

**It bypasses `metal::tensor` entirely.** Its kernels take raw `const device T*` and
`threadgroup T*` pointers and reach the matmul only through cooperative tensors.

**It hardcodes `relaxed_precision = true`** and pairs it with a host-side `MLX_ENABLE_TF32` opt-out
(§8.3).

**It uses `execution_simdgroup` everywhere** and hand-tiles across `WM * WN` simdgroups rather than
using `execution_simdgroups<N>`.

### 11.3 The trade, stated honestly

MLX gives up MPP's layout abstraction to get an in-register online softmax it fully controls,
including the fused rescale (§8.7). That is a defensible expert choice made by people who can prove
their layout assumptions and who benchmark every change.

It is also a **bad default**, for four reasons, each of which is a real cost MLX has already paid:

1. **`simd_shuffle_xor` with literal strides is layout-specific.** Change the fragment shape, the
   dtype, or the simdgroup width and the constants `1` and `8` are wrong — silently, with no
   diagnostic.
2. **Omitting `get_mask` is only safe for shapes you have proved.** §5.2.
3. **Bypassing `.slice()` means bounds checking is yours**, including the aligned/unaligned
   specialisations MLX maintains by hand in `gemm_nax.h`.
4. **It is where the bugs are.** ✅ VERIFIED, `steel/gemm/nax.h:847,865` — `tile_matmad_nax` selects
   between two `mma` overloads:

   ```cpp
     if constexpr (TN == 1 && TM % 2 == 0) {
   ```
   ```cpp
     } else if constexpr (TN % 2 == 0) {
   ```

   **There is no `else`.** For a tile shape that satisfies neither condition, `tile_matmad_nax`
   compiles to nothing and the GEMM produces garbage. §13 covers this.

> **The framing for your own code.** Use the portable APIs — `reduce_rows`, `map_iterator`,
> `is_iterator_compatible`, `.slice()`, `get_mask`. They cost you some performance you can measure
> and they buy you correctness across dtypes, tile shapes and GPU generations that you cannot
> otherwise verify. Reach for MLX's approach only when you have a profile that says the abstraction
> is the bottleneck, and only for shapes you have proved. Apple's own guidance points the same way:
> the header's example uses `get_mask`, and Tech Talk 111432 tells SIMD-group-matrix authors to
> *"move your workloads over to adopt TensorOps instead."*

---

## §12 — Getting the kernel into a model

A kernel that only exists in a `.metal` file is a kernel nobody uses. Session 330 closes by putting
exactly the kernel above into a real model, and the mechanism is worth understanding even if you
never use it, because it constrains how you should write the shader.

✅ **VERIFIED**, session 330 at 330:121-127:

> *"Core AI provides tools for Python developers to convert PyTorch models to Core AI models,
> **including support for custom Metal kernels**."*
>
> *"I've followed the steps outlined in that session to integrate our custom FlashAttention kernel
> into a **Sam3 image segmentation model**. **We define the body of our custom attention kernel as a
> string in Python and register the `TorchMetalKernel` object**, shown here."*
>
> *"Then, **we replace the default huggingface attention implementation with one that calls our
> kernel**, shown here."*
>
> *"Finally, **we load the model from huggingface and export it from PyTorch as an optimized Core AI
> asset**."*
>
> *"**Sam3 performs promptable concept segmentation**, so we provide the model with an image and
> text… Here, I'm **prompting the model to label all pixels containing a car** in this image."*
> … *"**The car is highlighted in blue, so our attention kernel is fully integrated into the model as
> expected.**"*

Three moves, in order.

### 12.1 The kernel body becomes a Python string

`TorchMetalKernel`'s constructor is ✅ **VERIFIED** from `coreai-torch`'s own API documentation
(`docs/api/TorchMetalKernel.md`):

```python
from coreai_torch import TorchMetalKernel, MetalParameter

TorchMetalKernel(
    name: str,
    input_names: list[str],
    result_names: list[str],
    src: str,
    torch_defn: Callable[..., Any],
    metal_params: list[MetalParameter] | None = None,
    helper_src: str | None = None,
    template_dtypes: dict[str, str] | None = None,
)
```

The three parameters that matter for a TensorOps kernel, quoted from that doc:

| Parameter | Verbatim |
|---|---|
| `src` | *"**Body** of the Metal `[[kernel]]` function. The signature, buffer bindings, and `#include <metal_stdlib>` are **generated automatically** from `input_names`, `result_names`, and `metal_params`."* |
| `helper_src` | *"Additional Metal source **pasted before the kernel definition** (helper functions, type aliases, etc.)."* |
| `torch_defn` | *"Reference PyTorch implementation used for **shape inference during `torch.export`**."* |

> ⚠️ **This changes how you must write the §9 kernel.** `src` is the **body only** — the framework
> generates the `kernel void …(…)` signature for you from `input_names` / `result_names` /
> `metal_params`. So:
>
> - **Your `#include <MetalPerformancePrimitives/…>` lines, your `using namespace`, your descriptor
>   `constexpr`s and your `using qk_op_t = …` aliases go in `helper_src`, not `src`.** They must
>   precede the generated kernel definition, and `helper_src` is documented as *"pasted before the
>   kernel definition."*
> - **You do not control the kernel signature**, so the `[[simdgroup_index_in_threadgroup]]` and
>   `[[threadgroup_position_in_grid]]` attributes that §9 depends on must be requested through
>   `metal_params`.
>
> 🔴 **GAP:** whether `MetalParameter` accepts `"simdgroup_index_in_threadgroup"` as an attribute
> string is **unverified** — the documented examples show `"thread_position_in_grid"` only. **What
> would resolve it:** the `MetalParameter` implementation in `coreai.authoring`, or one working
> example. **Safe default:** if it does not, derive the simdgroup index inside the body from a
> thread-position parameter and the known simdgroup width, and assert your assumption in a comment.

Also verified from the same documentation, and both are ordering constraints that produce confusing
failures:

- **`result_shapes` must be passed at every call site**, not at construction. ✅ VERIFIED — it is a
  parameter of `__call__`, alongside `threads_per_grid` and `threads_per_thread_group`. Session 325
  explains why: *"This allows Core AI to bake in the computation of the output shapes of the kernel
  from the input shapes, if your model has dynamic shaped inputs."*
- **`register_custom_kernels()` must be called BEFORE `add_exported_program()`.** ✅ VERIFIED,
  verbatim from the doc: *"`TorchMetalKernel` instances must be registered with the converter via
  `register_custom_kernels()` **before** `add_exported_program()`."*

### 12.2 The monkey-patch

Session 330's second move is to *"replace the default huggingface attention implementation with one
that calls our kernel."* The talk shows this on screen without reading it out.

> 🔴 **GAP — the patch target.** The exact class and attribute being replaced were **not stated
> aloud and no code sample was published**. Any concrete `transformers.models.…` path in circulation
> for this is a guess. **What would resolve it:** the TensorOps sample code the presenter references
> at 330:137, or the SAM3 recipe in `apple/coreai-models`. **Safe default:** use Hugging Face's own
> supported extension point for attention implementations rather than reaching into a module's
> internals — it is stable across `transformers` versions in a way that a patched class attribute is
> not.

The *shape* of the move is clear and is the part worth teaching:

🟡 **RECONSTRUCTED — structure only; the `TorchMetalKernel` API is verified, the patch target is not:**

```python
FLASH_ATTENTION_HELPERS = """
#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>
#include <metal_tensor>
#include <metal_cooperative_tensor>
using namespace metal;
namespace tops = mpp::tensor_ops;

constant constexpr int TILE_M   = 16;
// ... descriptors, op aliases, helper functions — everything from §9 that is
//     not inside the kernel body ...
"""

FLASH_ATTENTION_BODY = """
    // ... the body of §9's kernel ...
"""

def torch_flash_attention(q: torch.Tensor,
                          k: torch.Tensor,
                          v: torch.Tensor) -> torch.Tensor:
    """Reference implementation. This is what torch.export sees."""
    return torch.nn.functional.scaled_dot_product_attention(q, k, v)

flash_attn = TorchMetalKernel(
    "flash_attention",
    input_names=["q", "k", "v"],
    result_names=["o"],
    src=FLASH_ATTENTION_BODY,
    helper_src=FLASH_ATTENTION_HELPERS,
    torch_defn=torch_flash_attention,
    metal_params=[...],          # see the GAP above
)

# ... then swap the model's attention implementation for one that calls
#     flash_attn(q, k, v, threads_per_grid=..., threads_per_thread_group=...,
#                result_shapes=[list(q.shape)]) ...
```

Two constraints on `torch_defn` that are enforced **at construction time**, ✅ VERIFIED from the
documentation:

> *"**Inputs** — every parameter must be annotated as `torch.Tensor`, `int`, `float`, or `bool`. The
> parameter count must match `len(input_names)`."*
> *"**Return** — the return annotation must be `torch.Tensor`, `list[torch.Tensor]`, or
> `tuple[torch.Tensor, ...]` (with a **concrete** number of tuple members)."*
> *"Violations raise **`TypeError`** (input/return annotations) or **`ValueError`** (parameter count
> mismatch) at construction time."*

Type annotations on the reference function are load-bearing. Omit them and you get an exception
before you ever reach the GPU — which is, for once, a *good* failure mode.

### 12.3 The kernel ships inside the asset

✅ **VERIFIED**, session 325 at 325:178-184 and 325:204, describing the same mechanism from the
Python side:

> *"The converter takes both my PyTorch model and my custom kernel, and **bundles them together into
> a single asset. The MSL is embedded right inside. It ships with the model.**"*
> *"The Metal source gets embedded directly in the asset — **a single artifact. The kernel travels
> with the model.**"*

Two consequences for how you write the shader:

1. **The compilation environment is not yours.** Your MSL is compiled by whatever toolchain
   specialises the asset on the target device. This is exactly why the `__has_include` guard in
   §0.1 is worth having, and why hardcoding the cryptex toolchain path is fatal.
2. **A build-time TensorOps availability failure becomes a deployment-time one.** §0.2's
   `__HAVE_TENSOR__` trap — the header expanding to nothing with no error — is much worse when it
   happens on a user's device during specialisation than when it happens in your build. Keep a
   non-TensorOps reference path, and test the asset on the oldest OS you claim to support.

> **Cross-reference.** The full `TorchMetalKernel` treatment — dtype templating via
> `template_dtypes`, multiple outputs, `MetalParameter`, the experimental-API warnings on
> `coreai.authoring`, and where custom kernels sit relative to composite ops and
> `register_torch_lowering` — is
> [Part 8 guide 3 — *Custom Metal kernels*](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md).
> This section covers only what constrains the *shader*.

> ⚠️ **Experimental-API warning, ✅ VERIFIED verbatim from `coreai-torch`'s documentation:**
> *"Authoring Metal kernels uses APIs from `coreai-core` (such as `coreai.authoring`). **These APIs
> are experimental and subject to change in future releases.**"* Pin your `coreai-torch` version.

---

## §13 — ⚠️ Freshness: NAX is new and still settling

Everything in this guide describes an API surface that is **months old and actively being fixed.**
Present it to yourself accordingly.

### 13.1 The evidence

✅ **VERIFIED** — `gh pr list -R ml-explore/mlx --search nax --state all`, run 2026-07-27. The
NAX-related PRs, in date order:

| PR | Date | State | Title |
|---:|---|---|---|
| 3470 | 2026-05-01 | closed | nax-g16 perf baseline: `MLX_DISABLE_NAX` gate + bench harness |
| 3593 | 2026-05-27 | closed | Add `MLX_DISABLE_NAX` option to skip Metal-4 nax kernels at build time |
| 3622 | 2026-06-04 | **merged** | NAX requires setting `MACOSX_DEPLOYMENT_TARGET=26.2` |
| 3631 | 2026-06-05 | **merged** | Fix int16 overflow in NAX qmm edge-tile bounds |
| 3632 | 2026-06-05 | **merged** | Fix `gather_qmm` NAX kernel name mismatch |
| 3810 | 2026-07-07 | **merged** | Fix wrong type parameter passed to `gemm_splitk_nax` |
| 3824 | 2026-07-09 | **merged** | Warn at configure time when NAX kernels are disabled |
| 3843 | 2026-07-13 | **merged** | Use `unroll_count(4)` for the NAX attention Q@K.T loop |
| 3842 | 2026-07-13 | open | Add a fused full-attention path for `head_dim` 256 on NAX devices |
| 3791 | 2026-07-02 | open | Raise qmv batch limit for large matrices on M5-class GPUs |
| 3853 | 2026-07-16 | open | Guard NAX `MetalPerformancePrimitives` include behind `__has_include` |
| 3883 | 2026-07-21 | open | Warn once when float32 ops silently run at TF32 precision |
| **3912** | **2026-07-24** | open | Fix fp quantized matmul corruption when the quantized dim is not a multiple of 32 |
| **3922** | **2026-07-26** | open | Fix sorted `gather_qmm` NAX boundary handling |
| **3924** | **2026-07-26** | open | Add a tile-shape `static_assert` to `tile_matmad_nax` |

> **Four correctness fixes landed or opened in the three days before 2026-07-27.** Three of them —
> #3912, #3922, #3924 — are *"produces wrong numbers"* bugs, not build or ergonomics issues.

### 13.2 The one to know about

**#3924** is the sharpest, because the defect it fixes is the exact failure mode this whole series
exists to document. ✅ **VERIFIED**, `steel/gemm/nax.h:847` and `:865`:

```cpp
  if constexpr (TN == 1 && TM % 2 == 0) {
```
```cpp
  } else if constexpr (TN % 2 == 0) {
```

**There is no `else`.** If `TN` is odd and not 1, or `TN == 1` with odd `TM`, `tile_matmad_nax`
selects neither `mma` overload, **compiles to nothing**, and the GEMM silently produces garbage.
No error, no assertion, no NaN — just wrong output for certain tile shapes. The static asserts that
*are* present check only that the M, N and K dimensions agree between operands
(`steel/gemm/nax.h:834,838,842`), not that the shape is one the dispatch handles.

PR #3924's title — *"Add a tile-shape `static_assert` to `tile_matmad_nax`"* — acknowledged a
real defect. It was closed unmerged 2026-08-02 (maintainer declined); the hazard remains at HEAD.

### 13.3 What to do about it

1. **Pin your MLX version if you depend on MLX.** A NAX correctness fix landing between your test
   run and your release is a real scenario in this window.
2. **Do not use tile shapes you have not tested**, in MLX or in your own kernel. #3924's lesson
   generalises: a compile-time dispatch over tile shapes with an incomplete case set is invisible
   until it produces wrong numbers. Add your own `static_assert` for the shapes your dispatch
   handles.
3. **Assume the same class of gap exists in code you write from this guide.** The §9 kernel has
   fixed `TILE_M` / `TILE_N` / `HEAD_DIM` for exactly this reason; if you template them, add the
   assert #3924 proposed.
4. **Check the PR list yourself before writing.** The table above is a snapshot dated 2026-07-27 and
   will be stale by the time you read it.

### 13.4 A dating caveat, stated because the temptation is real

🔴 **GAP — the MLX clone used for this series is shallow** (50 commits). `git log` over the NAX files
returns a single commit — `ca60290 2026-06-27 "Fix docstring nits (#3758)"` — which is the **graft
boundary**, not the introducing commit. `git log --diff-filter=A` returns the same commit for every
NAX file, for the same reason. **The true introduction dates of these kernels are unverified.**
**What would resolve it:** `git -C <repo> fetch --unshallow`, then re-run.
**Safe default:** treat the PR dates in §13.1 as the only reliable timeline; do not present file
dates as authoritative. What the PR record does support: NAX work was underway by **2026-05-01**
(PR 3470 benchmarks it), and copyright headers on `steel/gemm/nax.h`, `gemm_nax.h` and
`fp_quantized_nax.h` all read `// Copyright © 2025 Apple Inc.`

---

## §14 — Performance: the three things that actually move the number

This guide is about correctness first, because a fused kernel that is wrong is worthless. But there
is no point writing one unless it is fast, and Apple has published a small amount of unusually
concrete guidance. All of it comes from Tech Talk 111432.

### 14.1 The measurement that justifies the whole exercise

**Attribution: Apple-published**, Tech Talk 111432, presenter Zak (GPU Driver Performance). The
workload is *"a single 4K by 4K matrix multiplication"*, three implementations, *"running on the
exact same hardware"* — M5-class. Measured with Metal System Trace. Apple did not publish the
machine model, the OS build, or the date.

| Variant | Implementation | Wall time | Neural accelerator utilisation |
|---|---|---|---|
| **v1** | classic **SIMD-group matrix** API | *"over two seconds"* | **0%** |
| **v2** | **TensorOps** | *"over just a half second"* | *"well above 50%"* |
| **v3** | TensorOps + Morton-ordered threadgroup dispatch | *"around a third of a second"* | *"close to 100%"* |

> ✅ **VERIFIED**, verbatim: *"It's the **same 4K by 4K matrix multiplication running on the exact
> same hardware**. The difference is **almost seven times faster execution** just by understanding
> **how to use and feed neural accelerators efficiently**."*

The **0%** figure is the headline. On M5, a hand-written `simdgroup_matrix` kernel leaves the matrix
hardware **entirely idle** — *"All of this compute work is happening on the ALU, which means the
dedicated matrix hardware is sitting completely idle."* That converts Apple's migration advice from
a suggestion into arithmetic, and Apple states it as a directive:

> ✅ **VERIFIED**, verbatim: *"**And if you're already writing your own custom kernels in metal using
> SIMD Group matrix API, you should move your workloads over to adopt TensorOps instead.**"*

Equally important is Apple's diagnosis of v2, because it is the reason v3 exists: *"the utilization
percentage tells us that the neural accelerators **could be doing more. They're waiting for data.**"*
v2 was **data-starved, not compute-limited.** Traversal order fixed the feeding, not the maths.

⚠️ **Do not carry these numbers into a different context.** They are one matmul shape, on one
machine, with no published configuration. They justify *adopting TensorOps*; they do not predict
your kernel's speedup.

### 14.2 SIMD-group drift across K — the non-obvious one

This is the most useful thing in the talk and it is not in any header.

> ✅ **VERIFIED**, verbatim: *"when processing the k dimension, **TensorOps will tile and loop over it
> for you automatically**, but there's a subtlety… **SIMD groups within a thread group can start to
> diverge in their progress through those K tiles.** … **they start out synchronized, but over time
> they drift apart.** **When SIMD groups drift apart, you end up with larger, more scattered cache
> usage patterns. This hurts your cache hit rates and overall performance.**"*
>
> *"**The fix is to manually synchronize your SIMD groups using threadgroup barrier. To do this, you
> will want to tile the k dimension explicitly in your code so that you can insert barriers every
> few iterations.**"*

This is a **direct trade-off against the convenience of `dynamic_extent`.** Passing
`static_cast<int>(metal::dynamic_extent)` as the descriptor's `k` tells TensorOps to read K from the
tensor extents and loop internally (✅ VERIFIED, `MPPTensorOpsMatMul2d.h:92-95`) — the easy path.
Passing a concrete tile-K and looping yourself is the fast path, because only then do you have
somewhere to put a `threadgroup_barrier`.

That is why §8.3's descriptor passes `HEAD_DIM` explicitly rather than `dynamic_extent`, and why §9
loops over key blocks by hand.

Barrier frequency is a tunable, and Apple's answer to "how often" is a document, not a number:
*"Refer to the programming guide for examples of how to tune the barrier frequency."*

🔴 **GAP — the MPP Programming Guide has not been read for this series.** It is referenced **four
separate times** in Tech Talk 111432, as the source for optimal tile sizes, barrier-frequency
tuning, traversal-order implementation, and general TensorOps depth. It is a PDF at
`https://developer.apple.com/download/files/Metal-Performance-Primitives-Programming-Guide.pdf`.
**What would resolve every performance gap in this section:** reading it.
**Safe default:** start with a barrier every 4-8 K tiles and measure; the correct answer depends on
your tile size and cache footprint, and nothing in this guide can substitute for a profile.

### 14.3 Tile sizes, and the two opposing risks

> ✅ **VERIFIED**, verbatim: *"**A fixed tile size won't be optimal for all input shapes.** …
> **Increasing the tile size in the M and N directions allow better data reuse among SIMD groups
> within the Threadgroup** … On the other hand, **increasing the SIMD group tile size can reduce
> traffic between cache levels, but be careful — if you go too large, you may start spilling
> registers, which hurts performance.** **Templating your kernel so you can easily adjust tile sizes
> for different workloads is a good idea.**"*

Two knobs, two directions, one hazard:

| Knob | Increasing it helps because | Increasing it hurts because |
|---|---|---|
| **Threadgroup** M/N tile | better data reuse among simdgroups in the threadgroup | more threadgroup memory, fewer threadgroups resident |
| **Simdgroup** tile | less traffic between cache levels | **register spill** |

Register spill is the one to watch, and it is directly a cooperative-tensor concern: a cooperative
tensor *is* register storage (§2.2 rule 1), so every tile-size increase is a register-pressure
increase. A fused attention kernel holds `S`, `accO`, `runMax`, `runSum` and a converted `lhs`
simultaneously; that is a lot of live register state, and it is why §9's `TILE_M = 16` is
deliberately small.

Apple's advice to template the tile sizes is good and comes with §13.2's caveat: **if you template
them, `static_assert` the shapes your dispatch actually handles.** That is the whole content of
MLX PR #3924.

### 14.4 Threadgroup traversal order

> ✅ **VERIFIED**, verbatim: *"The default approach is a **linear raster order** traversal… Simple and
> intuitive. But from the perspective of your **last level cache**, **this doesn't give you great data
> reuse in the Y dimension.** A better approach is to use a **space filling curve like Morton Order
> or Hilbert order**. These traversal patterns **keep thread groups that are close in time also close
> in space**, which significantly improves **cache locality and hit rates in the last level cache**."*

This is a **host-side and index-arithmetic change**, not a TensorOps change — you remap `tgid` to a
Morton-ordered tile coordinate at the top of the kernel and everything downstream is unchanged. It
is the v2 → v3 step in §14.1: *"over just a half second"* to *"around a third of a second"* with the
maths untouched.

🔴 **GAP:** neither Apple talk publishes the remapping code, and the implementation is deferred to
the programming guide. **Safe default:** implement Morton order as a standalone `tgid` → `(x, y)`
helper, verify it against a linear traversal for identical output, then measure. Do not attempt it
before the kernel is correct.

### 14.5 Profiling: which tool, and the one trick

✅ **VERIFIED**, Tech Talk 111432, with Apple's own division of labour:

| Tool | For | Verbatim |
|---|---|---|
| **Metal System Trace** (Instruments) | quick system-level view | *"You can see your workload **in the context of everything else running on the system**. It's great for **rapid iteration and understanding the big picture**."* |
| **Xcode Metal debugger** | deep dives | *"**This isolates just your GPU work and removes outside system activity.**"* |

The Metal System Trace recipe, as narrated: build (⌘B) → launch Instruments (⌘I) → **Metal System
Trace** template → select the **performance limiters** counter set → record. Then expand the **M5
Metal Device events** track and use the track filter to find and pin the **neural accelerator
utilisation** counter. That counter is the number that told Apple v1 was at 0% and v3 near 100%; it
is the single most informative measurement for a TensorOps kernel.

And the trick worth stealing, verbatim: *"I've captured a GPU trace of **a single K loop iteration**
for each variant. **This keeps the capture small while preserving the performance characteristics we
care about.**"*

One verification technique falls out of the instruction-mix view: *"in this **v1** example, which
uses SIMD group matrix, **the majority of our instruction types are math**. In this **v3** example,
**almost all of the instructions are being executed by neural accelerators**."* If your instruction
mix is mostly ALU, your `matmul2d` is not reaching the hardware you think it is — check §0.2's
feature macros and §10.3's OS gate before you tune anything else.

[^metal27-multiplane]: Apple documents
    [`MTLTensorAuxiliaryPlaneDescriptor`](https://developer.apple.com/documentation/metal/mtltensorauxiliaryplanedescriptor),
    [`MTLTensorDescriptor.auxiliaryPlanes`](https://developer.apple.com/documentation/metal/mtltensordescriptor/auxiliaryplanes),
    and [`MTLTensor.auxiliaryPlanes`](https://developer.apple.com/documentation/metal/mtltensor/auxiliaryplanes).
    The repository's [WWDC26 session 330 transcript](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/transcripts/wwdc2026-330.txt#L27-L78)
    describes the data and E8M0 scale planes and the role of `blockFactors`.
[^metal27-dtypes]: Apple's current
    [`MTLTensorDataType`](https://developer.apple.com/documentation/metal/mtltensordatatype)
    documentation lists Int2, UInt2, Float4E2M1, Float8E4M3, Float8E5M2, and Float8UE8M0. Apple's
    [Metal Feature Set Tables](https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf)
    identify block-scaling support and the E8M0 scale-plane format.

---
