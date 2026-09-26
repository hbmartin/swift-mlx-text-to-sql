# TensorOps: `matmul2d`, tensor types, and what quantization actually looks like

**Part 11 · Metal and TensorOps · Reference 01**

**Version floor — and there are two of them, about two different things.** Apple's own feature
ladder for TensorOps, narrated in Tech Talk 111432, is: **26.0** introduces it (WWDC25 session 262),
**26.1** adds bfloat, **26.3** adds cooperative tensors as matmul *inputs*, **26.4** adds 4-bit and
8-bit integer tensors. **26.2 is never mentioned in that ladder.** Separately, the
`MetalPerformancePrimitives` headers shipped in the **Xcode 26.6 SDK** gate a large block of the
implementation on a macro spelled `__TENSOR_OPS_SUPPORT_DEPLOYMENT_TARGET_26_2`, i.e. **deployment
target ≥ 26.2**. Both statements are true and they are not the same statement. §1 reconciles them
and tells you which number to put in your build settings. The original TensorOps surface is 26.x;
Xcode 27 adds host-side multiplane tensors and the int2, FP4, FP8, and E8M0 data types described in
session 330 — and, as of the **macOS 27.0 beta SDK** (checked 2026-07-29), the same formats land
*shader-side* in the MPP headers themselves, together with a blockwise ue8m0 scale-plane path and a
second deployment gate, `…_DEPLOYMENT_TARGET_27_0`. §0.2 and §1.2 carry the
citations.[^metal27-multiplane]

This guide is written **against the headers**, which are on your disk right now. Where a WWDC
session and a header disagree, the header wins and the guide says so.

---

## What this covers

TensorOps is the Metal Shading Language layer that both Core AI and MLX stand on. It is two
libraries stacked:

```
mpp::tensor_ops::         matmul2d · matmul2d_descriptor · convolution2d
  (MetalPerformancePrimitives.framework, in the SDK)
        │  built on
        ▼
metal::                   tensor · cooperative_tensor · execution_simdgroups<N>
  (the Metal *language* headers, in the Metal toolchain — a different place entirely)
```

You are here because you want to write a matmul kernel by hand, or because you want to know what
Apple's 4-bit and 8-bit tensor support actually buys you. Both answers are more specific — and more
constrained — than the marketing.

Read this guide for:

- **`matmul2d_descriptor`'s seven positional arguments**, in order, with the default that will
  silently ruin a K-loop (§3).
- **The complete execution-scope vocabulary** — four names, one of which everybody writes and which
  **does not exist** (§4).
- **The three tensor construction paths** — `tensor_handle`, `tensor_offset`, `tensor_inline` —
  and a structural correction to how they are usually described (§5).
- **Cooperative tensors**: owning, thread-private, implementation-defined layout; the three getters
  whose template parameters differ *in kind*; and the masked-element API, whose real spelling is
  **not** what Apple's own doc comment says (§6).
- **The Xcode 26.6 element types.** Thirteen shader-side types, including `int8_t`, `uint8_t`,
  `metal::int4b_format`, and `metal::uint4b_format` (the complete `__tensor_ops_datatype` enum is
  transcribed in `notes/repos/mlx-tensorops-kernels.md` §8). Xcode 27's host-side `MTLTensorDataType`
  separately adds int2, FP4, FP8, and E8M0 formats — and the macOS 27.0 beta SDK's MPP headers add
  the matching *shader-side* element types: `metal::int2b_format` / `uint2b_format`,
  `metal::metal_fp4_e2m1_format`, `metal::metal_fp8_e4m3_format` / `…_e5m2_format` as operands, and
  `metal::metal_fp8_ue8m0_format` as a scale dtype (§0.2).[^metal27-dtypes]

## What this does *not* cover

- **`convolution2d`.** `MPPTensorOpsConvolution2d.h` (177 lines) and its 4,914-line implementation
  ship in the same framework. MLX does not use them and this guide does not either.
- **Host-side `MTLTensor` / `MTL4MachineLearningCommandEncoder`.** Covered by this part's Metal-4
  guide. This guide is about the *shader-side* API. The two are different types with confusingly
  similar names — see §2.
- **MLX's public Python/Swift quantization API** (`mx.quantize`, `QuantizedLinear`, the `mode=`
  argument). [Part 12](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/README.md) and [Part 13](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/README.md). This
  guide reads MLX's *kernels*, not its user-facing API.
- **Core AI compression** — `coreai-opt`, palettization, `QuantizationSpec`.
  [Part 9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md).
- **How to register a Metal kernel with a Core AI model.**
  [Part 8, guide 3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md).
  This guide establishes only the shader-side building blocks; the Part 8 guide is the tutorial.

## What you need

- **Xcode 26.6 or later** for the 26.x shader surface (this guide was verified against Build
  `17F113`), or **Xcode 27** for multiplane tensors, and a **deployment
  target of 26.2 or higher** — see §1 and [guide 11.2 §0.2](02-cooperative-tensors-and-flash-attention.md#02-the-version-ladder-and-the-262-annotation),
  where a wrong deployment target silently deletes every accelerated kernel from your build.
- **The Metal toolchain**, which is *not* inside `Xcode.app`. It is a cryptex mount. Find it with
  `xcrun -sdk macosx --find metal` and **never hardcode the path** — it contains a build-specific
  token that differs on every machine.
- **Metal 4.** MLX gates its accelerated kernels on `MLX_METAL_VERSION >= 400`.
- Comfort with C++ templates. `matmul2d` takes a **non-type template parameter of class type**, and
  every operand type is deduced. If `decltype` and SFINAE are unfamiliar, the compile errors in this
  API will be hostile.
- An **M5-class device** if you want the hardware fast path. Not required for correctness —
  TensorOps runs everywhere from M1 up and falls back to shader implementations
  ([guide 11.2 §14](02-cooperative-tensors-and-flash-attention.md#14--performance-the-three-things-that-actually-move-the-number)).

---

## Contents

- [0. How this guide was verified — and why sources must be version-scoped](#0-how-this-guide-was-verified--and-why-sources-must-be-version-scoped)
- [1. The version story: two ladders, both true](#1-the-version-story-two-ladders-both-true)
- [2. Two namespaces, two headers, two `tensor` types](#2-two-namespaces-two-headers-two-tensor-types)
- [3. `matmul2d_descriptor` — seven positional arguments](#3-matmul2d_descriptor--seven-positional-arguments)
- [4. Execution scopes — the complete vocabulary](#4-execution-scopes--the-complete-vocabulary)
- [5. Tensors: `tensor_handle`, `tensor_offset`, `tensor_inline`](#5-tensors-tensor_handle-tensor_offset-tensor_inline)
- [6. Cooperative tensors](#6-cooperative-tensors)
- [7. Reductions and iterator mapping](#7-reductions-and-iterator-mapping)

---

## 0. How this guide was verified — and why sources must be version-scoped

WWDC26 session 330 describes the Xcode 27 multiplane tensor surface accurately, while much of this
guide was originally verified against Xcode 26.6 headers. The apparent contradiction came from
comparing different SDK generations. This section keeps every negative header result scoped to the
version actually inspected and uses Apple's current API reference for the 27.0 additions.[^metal27-multiplane]

### 0.1 The three evidence bases

Everything in this guide comes from one of three places, in this order of authority.

**1. Apple's shipping headers, read on disk.** The complete, commented, normative TensorOps
declarations ship inside Xcode:

```
/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/
  MacOSX.sdk/System/Library/Frameworks/MetalPerformancePrimitives.framework/Headers/
```

| File | Lines | Role |
|---|---:|---|
| `MetalPerformancePrimitives.h` | 12 | umbrella; includes the two op headers |
| `MPPTensorOpsMatMul2d.h` | 642 | **the public API**, including ~320 lines of Apple prose and four worked examples |
| `MPPTensorOpsConvolution2d.h` | 177 | public API for `convolution2d` |
| `__impl/MPPTensorOpsAvailability.h` | 12 | the deployment-target macro |
| `__impl/MPPTensorOpsTypes.h` | 150 | `__tensor_ops_datatype`, address-space enum, descriptor-type enum |
| `__impl/MPPTensorOpsTraits.h` | 135 | type traits and the include list that reveals the language dependencies |
| `__impl/MPPTensorOpsUtility.h` | 106 | element-type → datatype mapping |
| `__impl/MPPTensorOpsMatMul2dImpl.h` | 8,963 | implementation; the exhaustive dtype dispatch and every `static_assert` that will bite you |
| `__impl/MPPTensorOpsConvolution2dImpl.h` | 4,914 | implementation |

> ✅ **VERIFIED** — enumerated by listing that directory on Xcode 26.6 (Build 17F113), 2026-07-27.
> The same framework is present under `iPhoneOS.sdk`, `iPhoneSimulator.sdk`,
> `AppleTVSimulator.sdk`, and `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`.

> ✅ **27.0-BETA DELTA** — the same directory in the **macOS 27.0 beta SDK** (Xcode 27 beta, checked
> 2026-07-29) keeps the identical file set but grows exactly where the new formats land:
> `MPPTensorOpsMatMul2d.h` 642 → **664** lines — the growth is 22 new rows in the dtype
> support-matrix comment, and the only compiled change in the file is a SFINAE substitution on the
> cooperative-tensor getters, `__is_thread_addrspace_v<…>` → `__is_unqualified_v<…>` (seven
> clauses; noted where §6.3 quotes the 26.6 spelling) — plus
> `__impl/MPPTensorOpsMatMul2dImpl.h` 8,963 → **16,754** lines, `MPPTensorOpsTypes.h` 150 → 180,
> `MPPTensorOpsTraits.h` 135 → 198, `MPPTensorOpsAvailability.h` 12 → 13 (one new macro — §1.2).
> `MPPTensorOpsConvolution2d.h` and `MPPTensorOpsConvolution2dImpl.h` are unchanged apart from a
> one-token diff. §0.2 and §1 read the contents of that delta.

If you searched for this framework and failed, you probably looked under `Toolchains/`. It is not
there. It is under `Platforms/…/SDKs/…/System/Library/Frameworks/`, like any other SDK framework.

**2. The Metal *language* headers**, which are in a completely different place — a cryptex-mounted
Metal toolchain that is not inside `Xcode.app` at all:

```bash
xcrun -sdk macosx --find metal
# → /var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v17.6.109.0.iAeIa2/
#      Metal.xctoolchain/usr/bin/metal
```

The headers sit under `…/Metal.xctoolchain/usr/metal/<ver>/lib/clang/<ver>/include/metal/`:

| File | Lines | Role |
|---|---:|---|
| `metal_tensor` | 2,204 | `metal::tensor`, the three descriptor/tag structs, `slice`, the `is_*_v` traits |
| `metal_cooperative_tensor` | 584 | `metal::cooperative_tensor`, iterators, `map_iterator`, `is_valid_element`, `get_capacity` |
| `metal_packed_numeric` | 119 | **`int4b_format`, `uint4b_format`, `packed_numeric_type<Format,N>`** |
| `__exec/units.h` | ~190 | `execution_threads<N>`, `execution_simdgroups<N>`, and the aliases |

> ⚠️ **The cryptex path contains a build-specific token** (`MetalToolchain-v17.6.109.0.iAeIa2`).
> It **will** differ on your machine. Resolve it with `xcrun`; never paste it into a script.

> ✅ **27-ERA TOOLCHAIN DELTA (2026-07-31)** — the Metal Toolchain component for Xcode 27.0 beta
> (27A5228h; component build 27A5228f, `Apple metal version 32023.921`) was installed and probed
> for this guide. Two changes of note. First, the mount moved: `xcrun -sdk macosx --find metal` now
> resolves under `~/Library/Developer/DVTDownloads/MetalToolchain/mounts/<hash>/Metal.xctoolchain/…`
> rather than a `com.apple.security.cryptexd` path — the never-hardcode rule above pays for itself.
> Second, the language headers grow: the include tree is now 71 files, `metal_tensor` 2,204 →
> **6,264** lines (the templated `slice` overloads move to `:4875-5001`), `metal_packed_numeric`
> 119 → **314**, and `metal_tensor:325-379` gains the multiplane machinery — `tensor_plane_scales`
> and `tensor_blockwise<PlaneTag, ElementType, BlockSizes...>`, all inside
> `#if defined(__HAVE_TENSOR_MULTIPLANE__)`. §2.2 and §5.4 carry this toolchain's compile-probe
> results. One installation trap: the first `xcrun … metal` after installing the component can
> still fail with *"cannot execute tool 'metal' due to missing Metal Toolchain"* from a stale xcrun
> cache — run it once with `xcrun --no-cache` and the cache refreshes.

**3. MLX's shipping kernels**, in `ml-explore/mlx` — a real, compiling, in-production call site
written by Apple against the same headers. When a header says something is possible and MLX does it,
that is as close to proof as static analysis gets.

Below those three: WWDC/Tech-Talk transcripts (narration, subject to ASR error and sometimes
describing a newer SDK generation than the local headers), then community repositories, always
attributed as such.

### 0.2 Quantized multiplane tensors: 26.x fallback and Xcode 27 native surface

Session 330 described, in speech, a mechanism in which a single `MTLTensor` carries its quantized
data *and* a **scale plane** of FP8 `E8M0` block scale factors, declared through a plane descriptor
with a `dataType` and `blockFactors`, attached via an auxiliary plane map — so that you "pass in
your quantized tensors and TensorOps will handle dequantization for you."

That mechanism is absent from the Xcode 26.6 headers inspected for the original guide, but it is
present in Xcode 27. `MTLTensorAuxiliaryPlaneDescriptor` configures an auxiliary plane's `dataType`
and `blockFactors`; `MTLTensorDescriptor.auxiliaryPlanes` attaches the plane map; and an allocated
`MTLTensor` exposes its auxiliary planes.[^metal27-multiplane]

> ✅ **VERIFIED (version-scoped negative result)** — case-insensitive searches for `scale`, `plane`, `blockFactor`,
> `block_factor`, `fp8`, `fp4`, `e8m0`, `e4m3`, `quant`, `aux` and `multiplane` across **all ~14,300
> lines** of the `MetalPerformancePrimitives` headers listed above returned **zero hits** on
> 2026-07-27 against Xcode 26.6:
>
> ```bash
> H="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/MetalPerformancePrimitives.framework/Headers"
> grep -rn -i "blockwise\|multiplane\|scale\|plane\|fp8\|fp4\|e8m0" "$H"
> # (no output)
> ```
>
> The same searches over that 26.6 `metal_tensor` + `metal_cooperative_tensor` snapshot (2,788 lines)
> also returned zero. This result must not be generalized to Xcode 27 — the 27.0-beta positive
> result is in the ✅ block at the end of this section.

For a 26.x target, three sources support the custom-dequantization fallback:

1. **The 26.6 headers** — the symbols are absent from that inspected snapshot, as above.
2. **MLX's 26.x kernels** — Apple's own array framework hand-dequantizes in software
   ([guide 11.2 §11](02-cooperative-tensors-and-flash-attention.md#11--the-expert-escape-hatch-what-mlx-does-instead)).
   That is the compatible fallback; it does not negate the newer native surface.
3. **Tech Talk 111432**, the M5 launch talk, which spends a whole segment on quantization and
   **never mentions a scale plane, a plane descriptor, `blockFactors`, FP8 or E8M0.** What it
   announces instead, as the 26.3 feature, is *"support for cooperative tensors as inputs to
   matmul. **This lets you build custom dequantization routines inside your kernel**, essential for
   running quantized models efficiently."*

That third source does better than absence for 26.x. It names the fallback that shipped before the
27.0 multiplane surface:
**in-kernel custom dequantization into a cooperative tensor.** Which is precisely the pattern MLX
implements. So this guide is not merely reporting a void; it can teach the real technique.

Session 330 is itself consistent with this on a close read — it says both *"pass your quantized
tensors and TensorOps will handle dequantization for you"* **and** *"if you need to dequantize a
custom format… dequantizing the data into a cooperative tensor, which can now be passed as an input
to the `matmul2d` op."* The second half is the 26.3 feature and it is real. The first half describes
something with no shading-language surface in the 26.x SDK.

> ✅ **VERIFIED (Xcode 27 update).** Apple's current documentation and feature-set tables close the old gap:
> multiplane tensors are a host-side `MTLTensor` facility, and int2, FP4, FP8, and E8M0 formats are
> valid tensor data types. Use the 27.0 surface when that is your deployment floor; keep in-kernel
> dequantization for 26.x targets and custom formats.[^metal27-dtypes]

> ✅ **VERIFIED — the macOS 27.0 beta SDK puts the scale-plane mechanism in the *shader-side* MPP
> headers too** (Xcode 27 beta, checked 2026-07-29). This is no longer only a host-side `MTLTensor`
> story:
>
> - **The matmul dtype matrix grows by 22 rows.** `MPPTensorOpsMatMul2d.h:62-83` (27.0 SDK) adds
>   `int2b_format` / `uint2b_format` as right-hand operands against `int8_t`/`uint8_t`/`half`/`bfloat`
>   (accumulating to `int32_t`/`half`/`bfloat`/`float`), and the floating quantized rows:
>   `half × metal_fp4_e2m1_format`, `half × metal_fp8_e4m3_format`, `half × metal_fp8_e5m2_format`,
>   plus same-format pairs `fp4×fp4`, `e4m3×e4m3`, `e5m2×e5m2` — each accumulating to `half` or
>   `float`. Note **e5m2 is included** (`:76-77`, `:82-83`); coverage is wider than session 330's
>   "FP8" shorthand. The 26.6 matrix's 47 rows are unchanged above them.
> - **Blockwise scale factors are real, with exact constraints.**
>   `__impl/MPPTensorOpsMatMul2dImpl.h:6241-6316` (27.0 SDK) reads a scale plane off an input tensor
>   through a `metal::tensor_blockwise<metal::tensor_plane_scales, …>` tag (all of it inside
>   `#if defined(__HAVE_TENSOR_MULTIPLANE__)`) and `static_assert`s the contract, verbatim messages:
>   scale dtype **must be `metal_fp8_ue8m0_format`**; scale factors are **rank 1 or 2**; **"Scale
>   block size 0 must be 32"** and, for rank 2, **"Scale block size 1 must be 1"**; **"Left tensor
>   must not be transposed if it has scale factors"**; **"Right tensor must be transposed if it has
>   scale factors"**; and **"Destination tensor cannot have scale factors"** (`:6315`). That is
>   MX-style block-32 scaling, matching the Feature Set Tables' reservation of ue8m0 for scale planes.
> - **The compiling scaled-matmul descriptor is `(false, true)`, not the `(false, false)` shown in
>   Apple's WWDC26 code listing.** Session 330 declares both `matrixA` and `matrixB` with the same
>   `tensor_blockwise<tensor_plane_scales, …>` tag, then publishes a descriptor with both transpose
>   flags false. Compiling that listing against Xcode 27.0 beta `27A5228h` fails at the right-scale
>   assertion above; left-not-transposed/right-transposed compiles to AIR:
>
>   ```cpp
>   constexpr auto descriptor = matmul2d_descriptor(
>       TILEM, TILEN, dynamic_length_v<int>,
>       false,  // scaled left operand: must not be transposed
>       true);  // scaled right operand: must be transposed
>   ```
>
>   Store and slice the logical right matrix in the matching transposed layout; the flag is matrix
>   semantics, not a switch to flip after packing. This is a docs-versus-compiler conflict, not
>   evidence that the header's assertion is merely an internal orientation trait.[^wwdc330-transpose-conflict]
> - **The supporting traits and datatypes ship alongside.** `MPPTensorOpsTraits.h:135-187` adds
>   `is_tensor_blockwise` / `has_tensor_blockwise_v` / `tensor_blockwise_tag` over
>   `metal::tensor_blockwise`; `MPPTensorOpsTypes.h:45-64` adds `__tensor_ops_datatype_int2`,
>   `_uint2`, `_fp4_e2m1`, `_fp8_e4m3`, `_fp8_e5m2` and `_fp8_ue8m0`, and `:120-155` maps the
>   corresponding `metal::` element types behind new feature macros: `__HAVE_INT2B_FORMAT_TYPE__`,
>   `__HAVE_METAL_FP4_E2M1_FORMAT_TYPE__`, `__HAVE_METAL_FP8_E4M3_FORMAT_TYPE__`,
>   `__HAVE_METAL_FP8_E5M2_FORMAT_TYPE__`, `__HAVE_METAL_FP8_UE8M0_FORMAT_TYPE__`.
> - **ue8m0 is a scale dtype, not an operand dtype.** It appears in the datatype enum and the
>   scale-plane asserts and **nowhere in the matmul support matrix** — you cannot multiply ue8m0
>   tensors; you scale with them.
> - **`convolution2d` gets none of this.** The 27.0 conv headers are unchanged from 26.6 apart from
>   one token, and a grep for the new formats over `MPPTensorOpsConvolution2dImpl.h` returns zero
>   hits. Quantized-format matmul is a `matmul2d`-only feature in this SDK.
>
> Deployment consequence: the new ABI is gated on a new macro, deployment target **≥ 27.0** — §1.2.
> The shader-side dequantization path in this guide remains the technique for 26.x targets and for
> formats outside this list.

There is a matching community claim worth recording rather than repeating:

> 🟡 **RECONSTRUCTED / community-cited.** A community research note in `john-rocky/coreai-model-zoo`
> records as an open question whether `coreai-torch` can compile embedded MSL at `-std=metal4.1`,
> saying *"blockwise scale plane `metal::tensor_blockwise` needs `__HAVE_TENSOR_MULTIPLANE__` = 4.1;
> matmul2d + uniform int4 = 4.0."* Neither `tensor_blockwise` nor `__HAVE_TENSOR_MULTIPLANE__`
> appeared in the Xcode 26.6 Metal toolchain inspected on 2026-07-27. Treat the spelling as unverified
> for that snapshot; do not use it to deny Xcode 27's documented host-side multiplane API.
> **Update (2026-07-29): both spellings are confirmed** — the macOS 27.0 beta SDK's
> `MPPTensorOpsTraits.h:135-187` and `MPPTensorOpsMatMul2dImpl.h:6241-6316` use exactly
> `metal::tensor_blockwise` and `__HAVE_TENSOR_MULTIPLANE__` (✅ block above).
> ✅ **Toolchain-verified, 2026-07-31** (Metal compiler from Xcode 27.0 beta 27A5228h,
> `metal 32023.921`): the "= 4.1" half is now measured fact — `__HAVE_TENSOR_MULTIPLANE__` is
> defined at `-std=metal4.1` only, `__HAVE_TENSOR__` at `metal4.0` and `metal4.1` (probe table in
> §2.2), and a `matmul2d` whose right operand is a
> `tensor_blockwise<tensor_plane_scales, device metal_fp8_ue8m0_format, 32, 1>`-tagged
> `metal_fp8_e4m3_format` tensor (right-transposed, per the asserts above) **compiles to AIR at
> `-std=metal4.1`** and fails at `metal4.0` with `use of undeclared identifier
> 'tensor_plane_scales'` — the scale-plane types themselves are 4.1-gated.
> Same author's conclusion after building it: *"you can get block-32 scaling at Metal 4.0 by staging
> the dequant in threadgroup memory"* — which is this guide's thesis, arrived at independently.
> Attribute as **community-measured**, not Apple.

### 0.3 The doc comments are not trustworthy either

The four worked examples in `MPPTensorOpsMatMul2d.h` are genuinely valuable — they are the best
introduction to the API that exists — but they are **not compiled**, and it shows. Verified defects
in Apple's shipping comment text:

| Where | Defect |
|---|---|
| `MPPTensorOpsMatMul2d.h:96-97` | `transpse_left` / `transpse_right` — typo, twice |
| `MPPTensorOpsMatMul2d.h:99` | `accurancy` |
| `MPPTensorOpsMatMul2d.h:116` | `// execute the operation. Assumes C is is initialized to zero.` — doubled `is` |
| `:117`, `:146`, and every later example | declares `matmul2d<…> matmulOp;` then calls **`op.run(...)`** — `op` is never declared |
| `:143-145`, `:183`, `:187-188`, `:193-194` | calls **`A.static_slice<…>(…)`** — see §5.4, **there is no such member function** |
| `:259-263` | `for (uint16_t i = 0, i < cT.get_capacity(); ++i)` — a comma where a semicolon belongs |
| `:261`, `:280` | calls **`cT.get_mask(i)`** — see §6.4, **there is no such member function** |
| `:881` | `destCT.map_iterator(sourceCT)` — passes a tensor where an iterator belongs, and drops a semicolon |
| WWDC26 session 330, 7:19 code listing | gives two scale-plane operands to `(false,false)`; Xcode 27 beta rejects the right operand — use a correspondingly stored `(false,true)` right-hand matrix (§0.2) |
| internal namespace | spelled `__mutmul2d_detail` throughout — a typo for `__matmul2d_detail`, shipping as-is |

Two of those — `static_slice` and `get_mask` — are not cosmetic. They are **API names that appear
nowhere outside the comment**, and a reader who copies them gets a compile error with no hint about
the real spelling. Both are corrected in place below, with the real names.

None of this means the header is unreliable about *declarations*. Declarations are compiled; comments
are not. Trust the code in the header, read the prose for intent, and verify any identifier that
appears only inside a `//`.

---

## 1. The version story: two ladders, both true

This is the single most-confused fact about TensorOps, and the confusion has three separate causes.
Take them one at a time.

### 1.1 Apple's narrated feature ladder

> ✅ **VERIFIED (Apple, Tech Talk 111432, "Accelerate your machine learning workloads with the M5
> and A19 GPUs")** — verbatim:
>
> *"We introduced TensorOps at [WWDC] 25 in the combined metal for machine learning and graphics
> session. … Since we introduced TensorOps, we've continued expanding the API **in iOS and Mac OS
> 26**. In **26.1**, we added **bfloat tensor support**, critical for modern ML models that use
> Bfloat16. In **26.3**, we added support for **cooperative tensors as inputs to matmul**. This lets
> you build custom dequantization routines inside your kernel, essential for running quantized
> models efficiently. And in **26.4**, we added **four bit and eight bit integer tensors**, so
> quantized models can fully leverage neural accelerators."*

| Version | Feature added | Consequence for your code |
|---|---|---|
| **26.0** | TensorOps introduced (WWDC25 session 262, "Combine Metal 4 machine learning and graphics") | `matmul2d`, `convolution2d`, tensors, cooperative tensors as *destinations* |
| **26.1** | **bfloat** tensor support | `bfloat` becomes a legal element type (§1.5) |
| **26.2** | *nothing named in the ladder* | but see §1.2 — the headers say otherwise |
| **26.3** | **cooperative tensors as matmul *inputs*** | `get_left_input_cooperative_tensor(src)`, `get_right_input_cooperative_tensor(src)`, `is_compatible_as_left_input` — the in-register dequantization path (§6.6) |
| **26.4** | **4-bit and 8-bit integer tensors** | `int8_t`, `uint8_t`, `metal::int4b_format`, `metal::uint4b_format` as tensor element types (§1.5) |

Two things this table settles for the original 26.x surface:

- **Base TensorOps does not require 27.** The capabilities in this table land in 26.x; do not gate
  `matmul2d` itself on iOS 27 or macOS 27.
- **The Xcode 26.6 dtype set stops at 4-bit and 8-bit integers.** Xcode 27 extends the host-side
  tensor formats with int2, FP4, FP8, and E8M0 — and the macOS 27.0 beta SDK extends the
  *shader-side* `matmul2d` operand matrix with the same formats (§0.2); those additions do not
  rewrite the 26.x history.[^metal27-dtypes]

The host-side `MTLTensor` enum corroborates the 26.4 date from a third angle:

> ✅ **VERIFIED** — `Metal.framework/Headers/MTLTensor.h` (Xcode 26.6 SDK):
> `MTLTensorDataTypeInt4 API_AVAILABLE(macos(26.4), ios(26.4)) = 143`,
> `MTLTensorDataTypeUInt4 … = 144`, on an enum otherwise annotated `API_AVAILABLE(macos(26.0),
> ios(26.0))`. `Int8`/`UInt8` are in the 26.0 baseline. No FP4, FP8 or E8M0 case exists **in that
> Xcode 26.6 header**; Apple documents those cases for the Xcode 27 surface.[^metal27-dtypes]

### 1.2 What the shipped headers actually gate

Now the other number.

> ✅ **VERIFIED** — `__impl/MPPTensorOpsAvailability.h:10`, the file's only substantive line:
>
> ```c
> #define __TENSOR_OPS_SUPPORT_DEPLOYMENT_TARGET_26_2 ((__ENVIRONMENT_OS_VERSION_MIN_REQUIRED__) >= 260200)
> ```

That macro is used **20 times** in `__impl/MPPTensorOpsMatMul2dImpl.h`. And here is the part nobody
has written down before: **what it switches is not "TensorOps on/off." It switches the runtime ABI
between a destination-only form and a general-operand form.**

> ✅ **VERIFIED** — `__impl/MPPTensorOpsMatMul2dImpl.h:30-34` and `:47-63`, quoted:
>
> ```cpp
> enum class __matmul2d_cooperative_operand_index
> {
>   left,
>   right,
>   destination,
> };
> …
> #if !__TENSOR_OPS_SUPPORT_DEPLOYMENT_TARGET_26_2
> extern "C" EXTERNALLY_DEFINED_ATTR size_t
> __tensorops_impl_matmul2d_op_cooperative_destination_data_size(
>     __matmul2d_descriptor descriptor,
>     __tensor_ops_detail::__tensor_ops_datatype,
>     __tensor_ops_detail::__tensor_ops_datatype,
>     __tensor_ops_detail::__tensor_ops_datatype,
>     int);
> #else
> extern "C" EXTERNALLY_DEFINED_ATTR size_t
> __tensorops_impl_matmul2d_op_cooperative_tensor_data_size(
>     __matmul2d_cooperative_operand_index,
>     __matmul2d_descriptor descriptor,
>     __tensor_ops_detail::__tensor_ops_datatype,
>     __tensor_ops_detail::__tensor_ops_datatype,
>     __tensor_ops_detail::__tensor_ops_datatype,
>     int);
> #endif
> ```

Read the two symbol names side by side:

- **Below 26.2**: `…_cooperative_**destination**_data_size(descriptor, …)` — the entry points are
  spelled *destination*, and they take no operand index. There is only one kind of cooperative
  tensor: the output.
- **At 26.2 and above**: `…_cooperative_**tensor**_data_size(**operand_index**, descriptor, …)` —
  a generalized entry point that takes `{left, right, destination}`.

The same split repeats for `num_elements`, `get_element_pointer`, `get_element_index`,
`get_coordinate`, `load`, `store` and the rest — twenty times.

**So the 26.2 macro is the deployment-target switch that makes left- and right-operand cooperative
tensors representable at all.** That is the same capability the Tech Talk assigns to 26.3.

The 27.0 beta SDK adds a second gate directly below the first — ✅ **VERIFIED**,
`__impl/MPPTensorOpsAvailability.h:11` (macOS 27.0 beta SDK, checked 2026-07-29):

```c
#define __TENSOR_OPS_SUPPORT_DEPLOYMENT_TARGET_27_0 ((__ENVIRONMENT_OS_VERSION_MIN_REQUIRED__) >= 270000)
```

The 26.2 macro keeps its 20 uses unchanged in the 27.0 `MPPTensorOpsMatMul2dImpl.h`; the new macro
appears **12 times**, and what it gates is again an ABI, not a feature flag: `_v2` run entry points
whose signatures carry `leftScaleDataType` / `rightScaleDataType` and per-dimension scale block
sizes (e.g. `__tensorops_impl_matmul2d_op_run_dv_f16_dv_f16_dv_f16_v2`,
`MPPTensorOpsMatMul2dImpl.h:1059` ff.), plus real copy/move-construct and copy/move-assign entry
points for cooperative tensors (`…_op_cooperative_tensor_copy_construct`, `:218` ff. — below the
macro these fall back to an element-by-element loop). The pattern from §1.2 repeats one major
version later: **the scale-plane and quantized-format ABI is representable only at deployment
target ≥ 27.0.**

### 1.3 Reconciling the two

Two facts, both verified, one apparent conflict:

| Source | Says | About |
|---|---|---|
| Tech Talk 111432 (Apple, narrated) | **26.3** | *cooperative tensors as matmul inputs* — the user-visible feature |
| Xcode 26.6 SDK headers (Apple, compiled) | **26.2** | the *runtime ABI* that carries an operand index |

The honest reading, and the one this guide adopts: **the ABI landed at 26.2 and the feature was
announced at 26.3.** That is an entirely ordinary sequence — the symbols ship in a point release,
the marketing lands in the next one — and it explains why the 26.6 header already contains
`get_left_input_cooperative_tensor(src)`, `is_compatible_as_left_input`, `reduce_rows`,
`reduce_columns`, `is_iterator_compatible` and the row/column reduction destination factories, all
with no per-symbol `@available` annotation.

> 🔴 **GAP.** We cannot prove that reading. What would resolve it: per-symbol availability
> annotations (there are none in the header), or Apple documentation for
> `get_left_input_cooperative_tensor`. Neither exists in the corpus. The macOS 27.0 beta SDK
> headers were checked on 2026-07-29: **still no per-symbol annotations** — only the two
> framework-wide macros (26.2, and the new 27.0 gate of §1.2).
> **Safe default, and it costs you nothing:** set your deployment target to **26.3**. It satisfies
> the header's 26.2 macro *and* the narrated feature date, and it is below the 26.4 you need for
> 4-bit/8-bit tensor element types anyway. If you use int4/int8 operands, **26.4** is your real
> floor. Do not write a blanket single version number in your own docs — write the ladder.

### 1.4 What belongs to 26.x and what belongs to 27.0

Session 330 says two things about version, in the same recap:

> *"Metal tensors natively support a wide range of quantized data types, including the new MX
> scaling formats and E8M0 scale factors **coming in iOS and macOS 27**."*

and earlier

> *"We added support for 4- and 8-bit integer types in **an update to macOS and iOS 26**."*

Both are right. The core `matmul2d` API and its 4-bit/8-bit integer expansion are 26.x; the native
MX/E8M0 multiplane representation belongs to Xcode 27 — and is now visible in the 27.0 beta SDK's
own MPP headers, behind the 27.0 deployment gate (§0.2, §1.2). The mistake is not recognizing 27.0
support; it is applying that floor to all of TensorOps instead of only to the newer tensor formats
and auxiliary-plane surface.[^metal27-multiplane]

### 1.5 The version cheat sheet

Put this in your build settings and move on.

| If you use… | Minimum deployment target | Why |
|---|---|---|
| `matmul2d`, `convolution2d`, tensors, cooperative **destination** tensors | **26.0** | base feature |
| `bfloat` element type | **26.1** | narrated ladder |
| cooperative tensors as matmul **inputs** (`get_left/right_input_cooperative_tensor`) | **26.2** by the header ABI, **26.3** by Apple's ladder — **use 26.3** | §1.3 |
| `int8_t` / `uint8_t` / `int4b_format` / `uint4b_format` element types | **26.4** | `MTLTensorDataTypeInt4 API_AVAILABLE(macos(26.4))` |
| int2 / FP4 / FP8 operand formats, ue8m0 blockwise scale planes | **27.0** | `__TENSOR_OPS_SUPPORT_DEPLOYMENT_TARGET_27_0` (`MPPTensorOpsAvailability.h:11`, 27.0 beta SDK) gates the scale-aware `_v2` ABI — §0.2, §1.2 |
| MLX's accelerated ("NAX") kernels at all | **26.2** *and* Metal 4 *and* SDK ≥ 26.2 | [Guide 11.2 §0.2](02-cooperative-tensors-and-flash-attention.md#02-the-version-ladder-and-the-262-annotation) — all three, or they silently vanish |

---

## 2. Two namespaces, two headers, two `tensor` types

Readers flounder here more than anywhere else, so it is worth being pedantic.

### 2.1 The two libraries

```cpp
#include <metal_tensor>                    // language: metal::tensor, metal::cooperative_tensor
#include <metal_cooperative_tensor>
#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>   // framework: mpp::tensor_ops
```

| | `metal::` | `mpp::tensor_ops::` |
|---|---|---|
| What it is | the **Metal Shading Language** itself | a **framework** shipped in the SDK |
| Where it lives | the cryptex Metal toolchain (`xcrun --find metal`) | `MetalPerformancePrimitives.framework` in the SDK |
| Gives you | `tensor`, `cooperative_tensor`, `execution_simdgroups<N>`, `int4b_format` | `matmul2d`, `matmul2d_descriptor`, `convolution2d`, `reduce_rows`, `reduce_columns`, `is_iterator_compatible` |
| Analogy | the type system | the operations over it |

Getting the namespace wrong is the most common first compile error. `execution_simdgroup` is
`metal::`, not `mpp::tensor_ops::`. `reduce_rows` is `mpp::tensor_ops::`, not a member of anything.

> ✅ **VERIFIED** — the umbrella header at `MetalPerformancePrimitives.h` includes exactly the two op
> headers, and the module map is minimal:
>
> ```
> framework module MetalPerformancePrimitives {
>     umbrella header "MetalPerformancePrimitives.h"
>     export *
>     module * { export * }
> }
> ```

### 2.2 The two guards that make the whole thing vanish

> ✅ **VERIFIED** — `MPPTensorOpsMatMul2d.h:328`:
>
> ```cpp
> #if defined(__METAL_VERSION__) && defined(__HAVE_TENSOR__)
> ```

If `__HAVE_TENSOR__` is not defined for your target, **the entire header expands to nothing.** Not
an `#error`. An empty namespace, and then a confusing `no member named 'matmul2d' in namespace
'mpp::tensor_ops'` several hundred lines later, at a call site that looks fine.

The related feature macros, all verified present in the headers:

| Macro | Gates |
|---|---|
| `__HAVE_TENSOR__` | the whole MPP TensorOps surface (`MPPTensorOpsMatMul2d.h:328`) |
| `__HAVE_BFLOAT__` | `bfloat` as an element type (`MPPTensorOpsTypes.h:106`) |
| `__HAVE_INT4B_FORMAT_TYPE__` | `int4b_format` / `uint4b_format` (`MPPTensorOpsTypes.h:112`; `metal_packed_numeric:14`) |
| `__HAVE_PACKED_NUMERIC__` | the whole `metal_packed_numeric` header (`metal_packed_numeric:9`) |
| `__HAVE_PACKED_NUMERIC_TYPE__` | `packed_numeric_type<Format, N>` (`metal_packed_numeric:38`) |
| `__HAVE_EXECUTION_UNIT__` | the execution-scope types (`__exec/units.h:9`) |

> ✅ **Toolchain-verified, 2026-07-31** — Metal compiler from Xcode 27.0 beta (27A5228h), Metal
> Toolchain component 27A5228f, `Apple metal version 32023.921`. An `#error` probe compiled after
> `#include <metal_stdlib>` at every modern `-std` level the driver accepts (`-std=bogus` makes it
> enumerate them: `ios-`/`macos-metal1.0`–`2.4`, then unified `metal3.0`, `metal3.1`, `metal3.2`,
> `metal4.0`, `metal4.1`) answers both halves of the question:
>
> | `-std=` | `__HAVE_TENSOR__` | `__HAVE_TENSOR_MULTIPLANE__` |
> |---|---|---|
> | `metal3.0` / `metal3.1` / `metal3.2` | undefined | undefined |
> | `metal4.0` | **defined** | undefined |
> | `metal4.1` | **defined** | **defined** |
>
> The defining site is the **language version alone**. The toolchain's `metal_config` carries one
> feature block per version, compared with `==` — each block enumerates its full feature set:
>
> ```cpp
> #if __METAL_VERSION__ == 400        // metal_config:1669 (metal 32023.921)
> #define __HAVE_TENSOR__ 1           // :1839
> #define __HAVE_TENSOR_VECTOR_ACCESSOR__ 1
> // …
> #if __METAL_VERSION__ == 410        // metal_config:1880
> #define __HAVE_TENSOR__ 1           // :2063
> #define __HAVE_TENSOR_GET_STRIDE_BYTES__ 1
> #define __HAVE_TENSOR_MULTIPLANE__ 1
> #define __HAVE_TENSOR_VECTOR_ACCESSOR__ 1
> ```
>
> The same two blocks split the rest of the table above: `metal4.0` defines
> `__HAVE_INT4B_FORMAT_TYPE__`, `__HAVE_PACKED_NUMERIC__` / `__HAVE_PACKED_NUMERIC_TYPE__` and
> `__HAVE_EXECUTION_UNIT__`; `metal4.1` adds `__HAVE_INT2B_FORMAT_TYPE__`,
> `__HAVE_INT8B_FORMAT_TYPE__`, all four `__HAVE_METAL_FP4_E2M1` / `FP8_E4M3` / `FP8_E5M2` /
> `FP8_UE8M0` `_FORMAT_TYPE__` macros, and `__HAVE_PACKED_NUMERIC_TYPE_PACK_UNPACK__`
> (`metal_config:1930-1984`; every macro named here was also confirmed by an `#error` probe at both
> levels, not just read from the header).
>
> **The deployment target plays no part in the macros.** The probe results are identical with
> `-mmacosx-version-min=15.0`, `26.0` and `27.0` — min-OS feeds
> `__ENVIRONMENT_OS_VERSION_MIN_REQUIRED__`, which §1.2's availability macros use to *select ABI
> entry points*, never to hide the API. And the failure mode is exactly as described above: a
> minimal `matmul2d` kernel (Apple's first worked example, corrected per §0.3) compiles cleanly at
> `-std=metal4.0` and `metal4.1`, while at `-std=metal3.2` the first diagnostic is
> `error: expected namespace name` on `using namespace mpp;` — the header expanded to nothing.
>
> The `#error` probe is still worth keeping in your build, with the message now exact:
>
> ```cpp
> #if !defined(__HAVE_TENSOR__)
> #  error "TensorOps unavailable: compile with -std=metal4.0 or metal4.1"
> #endif
> ```
>
> Twelve characters of `#error` will save you an afternoon. (MLX's practical proxy —
> `MLX_METAL_VERSION >= 400` plus deployment ≥ 26.2 — agrees with the measurement; the deployment
> half of its condition governs the runtime ABI, §1.2, not compilation.)

### 2.3 `MTLTensor` is not `metal::tensor`

They are different types in different languages and they are not interchangeable.

| | `MTLTensor` | `metal::tensor<…>` |
|---|---|---|
| Language | Objective-C / Swift | Metal Shading Language |
| Where | `Metal.framework` (host) | `<metal_tensor>` (device) |
| Created by | `[device newTensorWithDescriptor:…]` / `makeTensor(descriptor:)` | a kernel parameter declaration, or `tensor_inline` construction in the kernel body |
| Carries | a data type, dimensions, strides, usage flags | element type, extents, descriptor tag, address space |

You bind an `MTLTensor` on the host and the kernel receives it as a `metal::tensor<…>` parameter.
Writing `MTLTensor` inside a `.metal` file compiles to nothing useful; writing `metal::tensor` in
Swift is a syntax error. Session 330's narration is spoken, so "metal tensor" is ambiguous by ear —
in every case where the distinction matters, the host type is `MTLTensor` and the shader type is
`metal::tensor`.

> 🟡 **RECONSTRUCTED — the host-side alignment rule, which you will need if you bind sub-byte
> tensors.** From `MTLTensor.h`'s `strides` documentation (Xcode 26.6 SDK): the first element of
> `strides` is 1; if `usage` contains `MTLTensorUsageMachineLearning`, the second element is aligned
> to **64 bytes**; and *"if `dataType` is a sub-byte `MTLTensorDataType`, for any `i >= 1`,
> `strides[i]` is aligned to **128 bytes**."* That is the concrete content of session 330's
> *"these new data types have additional alignment requirements… be sure to check the Metal
> documentation for details."* Marked 🟡 because it is quoted from a doc comment rather than from a
> compiled declaration, and because the guide's Metal-4 host-side coverage lives elsewhere.

---

## 3. `matmul2d_descriptor` — seven positional arguments

The descriptor is where you tell the op what shape of tile you want and how you want it computed.
It has **no named parameters, no builder, and no designated initializers.** Seven positional
arguments, four with defaults, and one of those defaults is a trap.

### 3.1 The declaration, verbatim

> ✅ **VERIFIED** — `MPPTensorOpsMatMul2d.h:349-377`, quoted exactly as it ships:
>
> ```cpp
> struct matmul2d_descriptor
> {
>   enum class mode
>   {
>     multiply,
>     multiply_accumulate,
>   };
>
>   int m, n, k;
>   bool transpose_left, transpose_right;
>   bool relaxed_precision;
>   mode matmul_mode;
>
> public:
>   constexpr matmul2d_descriptor(int __m, int __n, int __k = static_cast<int>(metal::dynamic_extent),
>                                 bool __transpose_left = false,
>                                 bool __transpose_right = false,
>                                 bool __relaxed_precision = false,
>                                 mode __matmul_mode = mode::multiply) thread
>       : m(__m),
>         n(__n),
>         k(__k),
>         transpose_left(__transpose_left),
>         transpose_right(__transpose_right),
>         relaxed_precision(__relaxed_precision),
>         matmul_mode(__matmul_mode)
>   {
>   }
> };
> ```

### 3.2 The argument list — memorise this order

| # | Name | Type | Default | Meaning |
|---:|---|---|---|---|
| 1 | `m` | `int` | *(required)* | M extent of the **local tile** — not of the whole matrix |
| 2 | `n` | `int` | *(required)* | N extent of the local tile |
| 3 | `k` | `int` | `static_cast<int>(metal::dynamic_extent)` | K, or the K **tile** size. `dynamic_extent` ⇒ the op reads K from the tensor extents and loops internally |
| 4 | `transpose_left` | `bool` | `false` | |
| 5 | `transpose_right` | `bool` | `false` | |
| 6 | `relaxed_precision` | `bool` | `false` | trade accuracy for speed — see [guide 11.2 §11.2](02-cooperative-tensors-and-flash-attention.md#112-what-it-does-instead) |
| 7 | `matmul_mode` | `mode` | **`mode::multiply`** | ⚠️ see §3.5 |

The transpose convention, from Apple's own comment (`MPPTensorOpsMatMul2d.h:96-97`, typos included):

```
//                             false,  // transpse_left = false for NN and NT and true for TN and TT
//                             false,  // transpse_right = false for NN and TN and true for NT and TT
```

So: **NN** = `(false,false)`, **NT** = `(false,true)`, **TN** = `(true,false)`, **TT** =
`(true,true)`.

And `relaxed_precision`, `MPPTensorOpsMatMul2d.h:98-99`:

```
//                             false); // relaxed_precision = false, set it to true to allow implementation
//                                     // to sacrifice accurancy for performance.
```

### 3.3 `k = dynamic_extent` vs an explicit tile-K

This is a real design decision, not a formality.

> ✅ **VERIFIED** — `MPPTensorOpsMatMul2d.h:92-95`:
>
> ```
> //   static_cast<int>(dynamic_extent), // k inner dimension. dynamic_extent means operation will read K from input tensor
> //                                     // K = A.extents().extent(0) or B.extents().extent(1) for NN
> //                                     // K = A.extents().extent(0) or B.extents().extent(0) for NT
> //                                     // and so on..
> ```
>
> and `:174-176`, for the explicit form:
>
> ```
> //   16); // tilek = 16, we loop over K in chunks of 16 rather than
> //        // letting matmul op run method looping over K
> //        // internally choose tileK
> ```

| `k` | What happens | When you want it |
|---|---|---|
| `dynamic_extent` | the op loops over the full K itself | prototypes; correctness first; when you have no reason to interfere |
| a concrete integer (e.g. `16`) | **you** write the K loop and call `run()` once per chunk | when you need to insert barriers, fuse work into the loop, or control cache behaviour |

Apple's M5 talk makes the case for taking control explicitly, and it is the least obvious
performance advice in the whole talk:

> ✅ **VERIFIED (Apple, Tech Talk 111432)** — *"when processing the k dimension, TensorOps will tile
> and loop over it for you automatically, but there's a subtlety… **SIMD groups within a thread
> group can start to diverge in their progress through those K tiles.** … they start out
> synchronized, but over time they drift apart. **When SIMD groups drift apart, you end up with
> larger, more scattered cache usage patterns. This hurts your cache hit rates and overall
> performance.**"*
>
> And the fix: *"**The fix is to manually synchronize your SIMD groups using threadgroup barrier. To
> do this, you will want to tile the k dimension explicitly in your code so that you can insert
> barriers every few iterations.**"*

So the convenience of `dynamic_extent` and the performance of explicit tiling are directly opposed,
and the mechanism is SIMD-group drift, not instruction count. Barrier frequency is a tunable; Apple
points at the Programming Guide PDF for values; profile rather than copying a universal interval.

There is a **separate** dynamic sentinel that is easy to confuse with this one:

> ✅ **VERIFIED** — `MPPTensorOpsTypes.h:137-144`:
>
> ```cpp
> template <typename T, typename U = …__enable_if_t<…__is_integral_v<T>>>
> struct dynamic_length
> {
>     static constexpr constant T value = metal::numeric_limits<T>::max();
> };
>
> template <typename T, typename U = …>
> constexpr constant T dynamic_length_v = dynamic_length<T>::value;
> ```

`dynamic_length_v<int>` is `numeric_limits<int>::max()`. `metal::dynamic_extent` is a different
constant used for extents. Both mean "dynamic" in different subsystems. Do not substitute one for
the other; the `static_assert` in §6.6 checks against **both**, which tells you Apple expects the
confusion.

### 3.4 The `(x, y)` versus `(m, n)` transposition

This will cost you a day if nobody warns you, so here is the warning.

`slice()` takes coordinates in **(dim0, dim1)** order, where **dim0 is the inner/contiguous
dimension** — which for a row-major host matrix is the *column*. The descriptor's `(m, n)` is
**(rows, cols)**. They are opposite.

Apple's own example demonstrates it without commenting on it: a 64×32 output tile is declared
`matmul2d_descriptor(64, 32, …)` and sliced as `C.slice<32, 64>(tgid.x*32, tgid.y*64)`. Note the
**32, 64** against the descriptor's **64, 32**.

A community implementation hit this independently and wrote it down:

> **Community-measured** (`john-rocky/coreai-model-zoo`, `knowledge/_tensorops_proto/m0_half_x_half.py:21-24`,
> a code comment in a script that validates against a torch reference):
>
> ```
> # Metal tensor coords are TRANSPOSED vs numpy: torch[M,K] -> tensor extents [K,M]
> # (dim0 = inner/contiguous). Verified with probe_dispatch: out[a,b] lands at numpy[b,a].
> # So header-verbatim slicing is correct: tgid.x -> N tiles (step 32, tensor dim0),
> #                                        tgid.y -> M tiles (step 64, tensor dim1).
> ```
>
> The same author records that this axis reversal produced a NaN bug in an unrelated model port —
> it is a recurring footgun, not a one-off. Attribute as community-measured (Apple silicon Mac,
> Xcode 27 beta era, mid-2026); no Apple statement corroborates it, but Apple's own example is
> consistent with it.

**The cheapest defence is a 30-line probe kernel** that writes `out[tgid.x, tgid.y] = 100 + 10*x + y`
into a known-good output and prints the result. The community repo ships exactly that
(`probe_dispatch.py`, 61 lines) and calls it *"the script that established the axis-reversal fact"*.
Write it before you write your matmul, not after.

### 3.5 ⚠️ The default mode is `multiply`, and the semantics are not fully settled

Two facts, then an honest gap.

**Fact one, verified:** the seventh argument defaults to `mode::multiply`, not
`mode::multiply_accumulate`. MLX passes the accumulate mode **explicitly**, every time:

> ✅ **VERIFIED** — `mlx/backend/metal/kernels/steel/gemm/nax.h:401-408`:
>
> ```cpp
>     constexpr auto desc = mpp::tensor_ops::matmul2d_descriptor(
>         16,
>         32,
>         16,
>         transpose_a,
>         transpose_b,
>         true,
>         mpp::tensor_ops::matmul2d_descriptor::mode::multiply_accumulate);
> ```

**Fact two, verified:** there are exactly **two** enumerators. No `accumulate_only`, no
`multiply_add`, no `mode::none`.

**The gap:** the header contains three statements about accumulation that do not obviously agree.

| Where | Says |
|---|---|
| `MPPTensorOpsMatMul2d.h:7` (the file's opening line) | *"This API performs generalized matrix multiplication operation **C = A\*B + C;**"* |
| `:116` (first example, default mode) | *"execute the operation. Assumes C is is initialized to zero."* |
| `:170-200` (third example, default mode) | writes a K loop calling `op.run(tA, tB, tC)` repeatedly into the **same** `tC` |

If `mode::multiply` overwrote the destination, the third example would return only the last K chunk.
If `mode::multiply` accumulated, `mode::multiply_accumulate` would be redundant. Both readings have
a problem, and the actual behaviour lives inside `__tensorops_impl_matmul2d_op_run_*`, which are
`extern "C" EXTERNALLY_DEFINED_ATTR` — declared in the header, implemented in the driver. **Static
analysis cannot settle it.**

The tie-breaker is a numerically validated implementation:

> **Community-measured** — `john-rocky/coreai-model-zoo`,
> `knowledge/_tensorops_proto/m2_int4_block32_scaled.py` (120 lines) accumulates a block-scaled int4
> matmul across `K/32` blocks by running `mode::multiply` on the **first** block and
> `mode::multiply_accumulate` on **every block thereafter**, and validates the result against a
> torch blockwise-dequant reference. That only produces a correct answer if
> `multiply` = `C := A*B` and `multiply_accumulate` = `C := A*B + C`.

> 🔴 **GAP — the exact semantics of `mode::multiply`.** Enum names plus one numerically-validated
> community implementation say *overwrite*; two lines of Apple prose and one Apple example imply
> *accumulate*. Nobody in this project has run both modes on hardware and diffed the output.
> **What would resolve it:** a ten-line kernel that fills C with 1.0, runs each mode once, and reads
> C back. Do it before you trust either reading.
> **SAFE DEFAULT — costs nothing and is correct under both readings:**
> 1. **Always pass the seventh argument explicitly.** Never rely on the default.
> 2. **Zero your destination before the first `run()`** — with a cooperative destination, loop to
>    `get_capacity()` and assign `0` (§6.5).
> 3. Use `multiply_accumulate` for every iteration of a K loop, including the first, after zeroing.
>    This is MLX's pattern and it is unambiguous under either reading.

⚠️ The failure mode if you get this wrong is the reason it belongs in a callout: **a K loop that
silently returns only the last chunk.** No error, no warning, no NaN. Your matmul produces
plausible, wrongly-scaled numbers — exactly the class of defect that survives a smoke test and dies
in production. Gate every new tile shape against a CPU reference, once, and keep the check.

### 3.6 The descriptor is a template parameter, not a runtime value

> ✅ **VERIFIED** — `MPPTensorOpsMatMul2d.h:391-392`:
>
> ```cpp
> template <matmul2d_descriptor Descriptor, typename Scope, class... Args>
> class matmul2d : __tensor_ops_detail::op
> ```

`Descriptor` is a **non-type template parameter of class type** (a C++20 feature). Consequences:

- the descriptor must be `constexpr`;
- every distinct tile shape instantiates a distinct `matmul2d` type and generates distinct code;
- you cannot select a tile shape at runtime without templating your whole kernel — which is exactly
  what Apple recommends anyway:

> ✅ **VERIFIED (Apple, Tech Talk 111432)** — *"A fixed tile size won't be optimal for all input
> shapes. … **Increasing the tile size in the M and N directions allow better data reuse among SIMD
> groups within the Threadgroup** … On the other hand, **increasing the SIMD group tile size can
> reduce traffic between cache levels, but be careful — if you go too large, you may start spilling
> registers, which hurts performance.** **Templating your kernel so you can easily adjust tile sizes
> for different workloads is a good idea.**"*

Two knobs, opposing risks: threadgroup-level M/N tile up = better reuse; SIMD-group tile up = less
cache traffic **but register spill**. There is no published formula; the Programming Guide PDF is
where Apple says the numbers live.

The canonical declaration form, which MLX uses:

```cpp
constexpr auto desc = mpp::tensor_ops::matmul2d_descriptor(/* … seven args … */);
mpp::tensor_ops::matmul2d<desc, metal::execution_simdgroup> gemm_op;
```

Also worth knowing: the class exposes its own descriptor and scope, which is occasionally useful in
generic code.

> ✅ **VERIFIED** — `MPPTensorOpsMatMul2d.h:399-400`:
>
> ```cpp
>   static constexpr constant matmul2d_descriptor descriptor = Descriptor;
>   using scope = Scope;
> ```

---

## 4. Execution scopes — the complete vocabulary

The second template parameter of `matmul2d` says **how many threads cooperate on one operation.**
It is the most commonly mis-stated part of the API, so here is the whole truth, with the four names
that exist and the one that does not.

### 4.1 The primitives

> ✅ **VERIFIED** — `__exec/units.h:15-18`:
>
> ```cpp
> template <size_t>
> struct execution_threads;
> template <size_t>
> struct execution_simdgroups;
> ```
>
> and `:88-104`:
>
> ```cpp
> template <size_t Size>
> class execution_simdgroups
> {
>   static_assert(Size != 0, "execution_simgroups<0> is not supported");
>
>   using size_type = uint;
>
> public:
>   static constexpr constant size_t static_size = Size;
>
> public:
>   METAL_FUNC constexpr size_type size() thread const
>   {
>     return static_size;
>   }
> };
> ```
>
> (`execution_simgroups` in the assert message is Apple's typo, shipping.)

And the restriction on the thread form, `__exec/units.h:131-134`:

```cpp
template <size_t Size>
class execution_threads
{
  static_assert(Size == 1, "Only execution_thread<1> is supported");
```

### 4.2 The aliases — this is the bit everyone gets wrong

> ✅ **VERIFIED** — `__exec/units.h:128-129` and `:185`:
>
> ```cpp
> using execution_dsimdgroups = execution_simdgroups<__execution_detail::dynamic_size>;
> using execution_simdgroup   = execution_simdgroups<1>;
> ```
>
> ```cpp
> using execution_dthreads = execution_threads<__execution_detail::dynamic_size>;
> using execution_thread   = execution_threads<1>;
> ```

**`execution_simdgroup` (singular) is not a different concept from `execution_simdgroups<N>`. It is
literally `execution_simdgroups<1>`.** Likewise `execution_thread` is `execution_threads<1>`.

### 4.3 The complete list

| Spelling | Meaning | Real? |
|---|---|---|
| `metal::execution_thread` | one thread; `= execution_threads<1>` | ✅ |
| `metal::execution_threads<1>` | the same type | ✅ (only `1` compiles) |
| `metal::execution_simdgroup` | one SIMD group; `= execution_simdgroups<1>` | ✅ |
| `metal::execution_simdgroups<N>` | N SIMD groups | ✅ |
| `metal::execution_dsimdgroups` | runtime-sized SIMD-group count | ✅ |
| `metal::execution_dthreads` | runtime-sized thread count | ✅ |
| **`metal::execution_threadgroup`** | — | ❌ **DOES NOT EXIST** |

There is no threadgroup scope. If you want "all the threads in my threadgroup," you write
`execution_simdgroups<N>` where N is your threadgroup's SIMD-group count. The compile-time
validation is explicit about the permitted set:

> ✅ **VERIFIED** — `MPPTensorOpsTraits.h:120-122`:
>
> ```cpp
> template <typename T>
> constexpr constant bool __is_tensorops_execution_scope_v =
>     metal::is_execution_thread_v<__remove_cv_t<__remove_ref_ptr_t<T>>> ||
>     metal::is_execution_simdgroups_v<__remove_cv_t<__remove_ref_ptr_t<T>>>;
> ```
>
> and the `static_assert` that fires, `MPPTensorOpsMatMul2d.h:393-394`:
> *"Scope template argument should be of op_scope type"*.

### 4.4 What each scope is *for*, in Apple's words

> ✅ **VERIFIED** — `MPPTensorOpsMatMul2d.h:305-315`, quoted:
>
> ```
> //     metal::execution_thread: The operation will be run on a single thread.
> //                              Fragment shaders only support this execution scope.
> //     metal::execution_simdgroup: The operation will be run cooperatively by all
> //                                 threads in the SIMD group. May be used for finer
> //                                 control over tiling by slicing tensors with SIMD IDs.
> //     metal::execution_simdgroups<N>: The operation will be executed cooperatively by N
> //                                     SIMD groups. Must be used when all threads in a
> //                                     threadgroup are cooperatively performing the operation.
> //
> // It is undefined behavior if the number of SIMD groups dispatched does not
> // match the number of SIMD groups that the operation was configured with.
> ```

Three load-bearing sentences there:

1. **Fragment shaders get `execution_thread` and nothing else.**
2. **`execution_simdgroup` is the "I'll do my own tiling" scope** — you slice by SIMD ID and each
   SIMD group runs an independent matmul. This is precisely the FlashAttention pattern (each SIMD
   group owns complete rows of the score matrix, so softmax needs no cross-group exchange) and it is
   what MLX uses.
3. **Mismatched dispatch is undefined behaviour.** Not an error. Not a fallback. UB.

Plus the uniformity requirement, `MPPTensorOpsMatMul2d.h:300-303`:

```
// an execution scope provided as template argument. All the threads in this
// execution scope must enter the run method i.e. call to run methods must be
// "execution scope" uniform.
```

**Every thread in the scope must reach `run()`.** An early `return` for out-of-range threads before
a `run()` call is a correctness bug. Handle edge tiles by *branching between two `run()` calls*
(Apple's second example does exactly this — a `static`-extent slice in the interior branch, a
dynamic slice in the edge branch), not by skipping the call for some lanes.

### 4.5 Matching the host dispatch

> ✅ **VERIFIED** — `MPPTensorOpsMatMul2d.h:73-79`:
>
> ```
> //    id<MTLComputePipelineState> state = [device newComputePipelineState:...];
> //    NSUInteger simdgroupWidth = [state threadExecutionWidth];
> //    ...
> //    [encoder dispatchThreadgroups:threadgroups
> //    threadPerThreadgroups:MTLSizeMake(simdgroupWidth*4, 1, 1)];
> ```
>
> paired with `execution_simdgroups<4>` in the kernel, and
> `MTLSize threadgroups = MTLSizeMake((M + 63)/64, (N + 31)/32, 1);` for a 64×32 output tile.

The rule in one line: **`execution_simdgroups<N>` ⟺ `threadExecutionWidth * N` threads per
threadgroup.** Read `threadExecutionWidth` from the pipeline state; do not assume 32.

Swift form of the same dispatch:

```swift prelude:guide-context
// Host side. `state` is your MTLComputePipelineState.
let simdWidth = state.threadExecutionWidth          // do NOT hardcode 32
let simdGroupsPerTG = 4                             // must equal N in execution_simdgroups<N>

let threadgroups = MTLSize(width:  (M + 63) / 64,   // 64 = descriptor m
                           height: (N + 31) / 32,   // 32 = descriptor n
                           depth:  1)

encoder.setComputePipelineState(state)
encoder.dispatchThreadgroups(
    threadgroups,
    threadsPerThreadgroup: MTLSize(width: simdWidth * simdGroupsPerTG, height: 1, depth: 1))
```

> ⚠️ Three numbers must agree and **nothing checks them for you**: the `N` in
> `execution_simdgroups<N>`, the `simdGroupsPerTG` multiplier on the host, and the `(m, n)` in the
> descriptor versus the grid divisors. Disagreement is UB — in practice, wrong results on some tiles
> and correct results on others, which reads like a numerics problem rather than a dispatch problem.
> Bake all three into one Swift `struct` and one `#define` if you can.

### 4.6 MLX picks the other strategy — and there is a header-level reason

MLX uses `metal::execution_simdgroup` — i.e. `<1>` — **everywhere**, and does its own tiling across
SIMD groups above the op.

> ✅ **VERIFIED** — `mlx/backend/metal/kernels/steel/gemm/nax.h:411`:
> `mpp::tensor_ops::matmul2d<desc, metal::execution_simdgroup> gemm_op;`
> MLX then runs `WM * WN` SIMD groups per threadgroup — typically 2×2 = 4 — and tiles across them in
> its own `NAXTile` layer rather than asking for `execution_simdgroups<4>`.

At first reading that looks like a stylistic choice. It is not. **If you want cooperative tensors as
matmul inputs, `execution_simdgroup` is the only legal scope:**

> ✅ **VERIFIED** — `__impl/MPPTensorOpsMatMul2dImpl.h:3294-3295` (and the identical assert in the
> right-input getter at `:3395-3396`):
>
> ```cpp
>     static_assert(__tensor_ops_detail::__is_same_v<scope, metal::execution_simdgroup>,
>                   "Input cooperative tensors require a single SIMD group");
> ```

So the API partitions cleanly:

| If you want… | Scope |
|---|---|
| a big threadgroup-wide tile, tensors in and out of memory | `execution_simdgroups<N>` |
| cooperative tensors as matmul **inputs** (fusion, in-register dequant, FlashAttention) | **`execution_simdgroup` only** |
| a fragment shader | `execution_thread` only |

That single `static_assert` explains MLX's entire architecture. It is not in any transcript.

---

## 5. Tensors: `tensor_handle`, `tensor_offset`, `tensor_inline`

Session 330 named two ways to make a tensor. There are three, and the third — the one nobody
mentions — is the one you get from `.slice()`, which means you use it constantly whether you name it
or not.

### 5.1 The three tags

> ✅ **VERIFIED** — `metal_tensor:224-235`:
>
> ```cpp
> struct tensor_inline
> {
> };
> struct tensor_handle
> {
> };
> struct tensor_offset
> {
> };
>
> template <class ElementType, class Extents, class Descriptor, class... Tags>
> struct tensor;
> ```

| Tag | What it is | How you get one |
|---|---|---|
| `tensor_handle` | a host-allocated tensor bound as a kernel argument | declare a kernel parameter: `tensor<device half, dextents<int32_t, 2>> A` |
| `tensor_offset` | the same tensor with a shifted origin | `A.slice(x, y)` |
| `tensor_inline` | a tensor constructed **on the shader stack** over a pointer you already hold | construct it in the kernel body |

### 5.2 ⚠️ Correction: `tensor_offset` is a **Tag**, not a Descriptor

This is worth stating loudly because Apple's own doc comment gets it wrong, and every second-hand
description repeats the error.

> ✅ **VERIFIED** — `metal_tensor:323-331`, the primary template:
>
> ```cpp
> template <class ElementType,
>           class Extents,
>           class Descriptor = tensor_handle,
>           class... Tags>
> struct tensor
> {
>   static_assert(__tensor_detail::__is_tensor_descriptor_v<Descriptor>,
>                 "tensor: Descriptor template parameter must be one of tensor_handle or tensor_inline");
> };
> ```
>
> and `:250-254`:
>
> ```cpp
> template <typename T>
> struct __is_tensor_descriptor : bool_constant<
>   is_same_v<T, tensor_handle> || is_same_v<T, tensor_inline>>
> {
> };
> ```
>
> and the tag validity table, `:334-341`:
>
> ```cpp
> template <class Descriptor, class Tag>
> struct __is_tag : false_type
> {
> };
> template<>
> struct __is_tag<tensor_handle, tensor_offset> : true_type
> {
> };
> ```

So the real shape is:

```
tensor<ElementType, Extents, Descriptor, Tags...>
                             ^^^^^^^^^^  ^^^^^^^
                   tensor_handle |       tensor_offset is a TAG,
                   tensor_inline         and ONLY valid on tensor_handle
```

`A.slice(...)` on a `tensor<device half, dextents<int32_t,2>, tensor_handle>` returns
`tensor<device half, …, tensor_handle, tensor_offset>` — same descriptor, extra tag. Apple's comment
at `MPPTensorOpsMatMul2d.h:108` writes it as `tensor<device half, dextents<int32_t, 2>,
tensor_offset>`, putting the tag in the descriptor slot. That spelling **will not compile** — it
trips the `static_assert` above.

You almost never write the type out; `auto` handles it. But when a compile error prints the full
type, you now know why it has four template arguments instead of three.

Consistent with all of this, the detection traits are asymmetric — and now the asymmetry makes
sense:

> ✅ **VERIFIED** — `metal_tensor:468-486`:
>
> ```cpp
> constexpr constant bool is_tensor_handle_v = is_tensor_handle<T>::value;
> constexpr constant bool is_tensor_inline_v = is_tensor_inline<T>::value;
> constexpr constant bool has_tensor_offset_v = has_tensor_offset<T>::value;
> ```

`is_` for the two descriptors; **`has_`** for the tag. MPP wraps all three and defines "is a tensor
type" as the union:

> ✅ **VERIFIED** — `MPPTensorOpsTraits.h:108-118`:
>
> ```cpp
> template <typename T>
> constant bool __is_tensor_handle_v = metal::is_tensor_handle_v<__remove_cv_t<__remove_ref_ptr_t<T>>>;
>
> template <typename T>
> constant bool __is_tensor_offset_v = metal::has_tensor_offset_v<__remove_cv_t<__remove_ref_ptr_t<T>>>;
>
> template <typename T>
> constant bool __is_tensor_inline_v = metal::is_tensor_inline_v<__remove_cv_t<__remove_ref_ptr_t<T>>>;
>
> template <typename T>
> constant bool __is_tensor_type_v = __is_tensor_handle_v<T> || __is_tensor_offset_v<T> || __is_tensor_inline_v<T>;
> ```

That last line is exactly what `run()`'s SFINAE means by "is a tensor type" (§6.1).

One ordering detail with a real consequence:

> ✅ **VERIFIED** — `MPPTensorOpsTypes.h:88-99`:
>
> ```cpp
> template <typename TensorType>
> constexpr __tensor_ops_tensor_descriptor_type __tensor_type_to_tensor_descriptor_type()
> {
>   if constexpr (__is_tensor_offset_v<TensorType>)
>     return __tensor_ops_tensor_descriptor_type_offset;
>   else if constexpr (__is_tensor_handle_v<TensorType>)
>     return __tensor_ops_tensor_descriptor_type_handle;
>   else if constexpr (__is_tensor_inline_v<TensorType>)
>     return __tensor_ops_tensor_descriptor_type_inline;
>   else
>     static_assert(__assert_false_v<TensorType>, "unsupported tensor descriptor");
> }
> ```

The **offset check comes first**, because a sliced handle satisfies *both* `has_tensor_offset_v` and
`is_tensor_handle_v`. It classifies as `offset`. The ABI enum has four cases:

> ✅ **VERIFIED** — `MPPTensorOpsTypes.h:67-73`:
>
> ```cpp
> enum __tensor_ops_tensor_descriptor_type
> {
>   __tensor_ops_tensor_descriptor_type_handle,
>   __tensor_ops_tensor_descriptor_type_offset,
>   __tensor_ops_tensor_descriptor_type_inline,
>   __tensor_ops_tensor_descriptor_type_none,
> };
> ```

`_none` is a raw `thread*` with no descriptor — internal, not something you construct.

### 5.3 Address spaces: which tag can live where

This is a genuine constraint, not a formality, and it is the reason threadgroup-staged dequantization
([guide 11.2 §11](02-cooperative-tensors-and-flash-attention.md#11--the-expert-escape-hatch-what-mlx-does-instead))
needs `tensor_inline`.

> ✅ **VERIFIED** — `metal_tensor:258-280`:
>
> ```cpp
> template <class ElementType>
> struct __is_tensor_addrspace<tensor_handle, ElementType>
>   : disjunction<
>       __tensor_detail::__is_device_addrspace<ElementType>,
>       __tensor_detail::__is_constant_addrspace<ElementType>
>   >
> { };
>
> template <class ElementType>
> struct __is_tensor_addrspace<tensor_inline, ElementType>
>   : disjunction<
>       __tensor_detail::__is_thread_addrspace<ElementType>,
>       __tensor_detail::__is_device_addrspace<ElementType>,
>       __tensor_detail::__is_constant_addrspace<ElementType>,
>       __tensor_detail::__is_threadgroup_addrspace<ElementType>
>   >
> { };
> ```

| Descriptor | Legal address spaces |
|---|---|
| `tensor_handle` | `device`, `constant` |
| `tensor_inline` | `thread`, `device`, `constant`, **`threadgroup`** |

**`tensor_inline` is the only way to wrap threadgroup memory as a tensor.** That single row is why
the "dequantize into threadgroup memory, then hand the tile to `matmul2d`" pattern is expressible at
all.

Note a mismatch worth knowing about: MPP's own address-space enum has no `constant` case —

> ✅ **VERIFIED** — `MPPTensorOpsTypes.h:59-65`:
>
> ```cpp
> enum __tensor_ops_address_space
> {
>   __tensor_ops_address_space_invalid,
>   __tensor_ops_address_space_device,
>   __tensor_ops_address_space_threadgroup,
>   __tensor_ops_address_space_thread_private,
> };
> ```
>
> — even though `MPPTensorOpsTraits.h:81-82` defines `__is_constant_addrspace_v`. So the *language*
> permits a `constant`-space tensor and the *op ABI* has no enumerator for one.

> 🔴 **GAP.** Whether a `constant`-space tensor is accepted as a `matmul2d` operand is unverified —
> the language allows the type, the op's address-space enum has no case for it, and no example uses
> one. **What would resolve it:** compile a kernel taking `tensor<constant half, …>` and pass it to
> `run()`. **Safe default:** put operands in `device` or `threadgroup` space. Nothing in Apple's or
> MLX's code uses `constant`-space tensors.

### 5.4 ⚠️ `static_slice` does not exist — the real spelling is templated `slice`

Apple's doc comments call `static_slice<E0, E1>(i, j)` **eight times** across three of the four
worked examples. It is presented as the bounds-check-free fast path, and it is genuinely the right
technique. But:

> ✅ **VERIFIED (negative result)** — `grep -rn "static_slice"` over the entire Metal toolchain
> include directory (`…/Metal.xctoolchain/usr/metal/32023/lib/clang/32023.883/include/metal/`,
> all 40 headers) returns **zero hits**, on Metal toolchain `v17.6.109.0` shipped with Xcode 26.6
> (2026-07-27). The only occurrences anywhere on this machine are inside `//` comments in
> `MPPTensorOpsMatMul2d.h` (lines 143, 144, 145, 183, 187, 188, 193, 194).

The real member function is `slice`, and the compile-time-extent form is the **template-argument**
overload:

> ✅ **VERIFIED** — `metal_tensor:1609-1623`, the templated slice:
>
> ```cpp
>   template <size_t... OtherExtents, class... OtherIndexTypes>
>   METAL_FUNC enable_if_t<
>     ((is_convertible_v<OtherIndexTypes, index_type> && ...) &&
>      (sizeof...(OtherExtents) == tensor::get_rank()) && (sizeof...(OtherIndexTypes) == tensor::get_rank()) &&
>      __tensor_detail::__is_slice_extents_compatible_v<extents_type, OtherExtents...>),
>   __tensor_detail::__tensor_with_extents_t<
>       extents<index_type, OtherExtents...>, __tensor_detail::__tensor_with_tag_t<tensor_offset, tensor>>>
>   slice(OtherIndexTypes... index) thread  const
> ```
>
> and `:1625-1637`, the all-dynamic form that forwards to it:
>
> ```cpp
>   template <class... OtherIndexTypes>
>   METAL_FUNC enable_if_t<…>
>   slice(OtherIndexTypes... index) thread  const
>   {
>     return [&]<size_t... SliceExtents>(extents<index_type, SliceExtents...>) {
>       return slice<SliceExtents...>(index...);
>     }(dextents<index_type, tensor::get_rank()>());
>   }
> ```
>
> There are eight overloads in total, one per address space and constness (`thread`, `device`,
> `device coherent(device)`, `constant`), each in a dynamic and a templated form.

**Translation table for Apple's examples:**

| Apple's comment | What compiles |
|---|---|
| `A.static_slice<dynamic_extent, 64>(0, tgid.y*64)` | `A.slice<dynamic_extent, 64>(0, tgid.y*64)` |
| `B.static_slice<32, dynamic_extent>(tgid.x*32, 0)` | `B.slice<32, dynamic_extent>(tgid.x*32, 0)` |
| `C.static_slice<32, 64>(tgid.x*32, tgid.y*64)` | `C.slice<32, 64>(tgid.x*32, tgid.y*64)` |

> ✅ **Toolchain-verified, 2026-07-31 — `static_slice` does not exist in the 27-era toolchain
> either.** Metal compiler from Xcode 27.0 beta (27A5228h), Metal Toolchain component 27A5228f,
> `Apple metal version 32023.921`: `grep -rn "static_slice"` over its language-header tree
> (`…/Metal.xctoolchain/usr/metal/32023/lib/clang/32023/include/metal/`, all 71 files) returns
> **zero hits**, and compiling Apple's interior-tile example verbatim fails at both `-std=metal4.0`
> and `-std=metal4.1` with
>
> ```
> error: no member named 'static_slice' in 'metal::tensor<device half,
>        metal::extents<int, 18446744073709551615, 18446744073709551615>>'
> ```
>
> while the same kernel spelled `slice<dynamic_extent, 64>` / `slice<32, dynamic_extent>` /
> `slice<32, 64>` compiles cleanly at `-std=metal4.0`. The templated overloads (now at
> `metal_tensor:4875-5001` in this toolchain) are SFINAE-constrained exactly as declared above — a
> wrong-arity call such as `slice<64>(0)` on a rank-2 tensor is rejected with `no matching member
> function for call to 'slice'`. The macOS 27.0 beta SDK's `MPPTensorOpsMatMul2d.h` still spells
> `static_slice` only inside `//` comments (`:165-167`, `:205-216`) — eight occurrences, none
> compiled. **Write `slice<Extents...>(indices...)`:** it compiles, has the semantics the comments
> describe, and if Apple ever adds `static_slice` as an alias your code keeps working.

### 5.5 Why bother with compile-time extents

> ✅ **VERIFIED** — `MPPTensorOpsMatMul2d.h:120-127`, Apple's own rationale:
>
> ```
> // Above matrix multiplication implementation will do edge checking for all
> // thread groups against extents of original tensor although for large enough
> // matrices most of thread groups will be working on "inside" tiles, requiring no
> // bounds check. In high performance code we can avoid edge checking for inside
> // thread groups and get better performance
> ```

The pattern, corrected to the real spelling:

```cpp
// Interior tiles: extents are compile-time constants, so no bounds checks are emitted.
if (tgid.x * 64 + 63 < M && tgid.y * 32 + 31 < N) {
    auto tA = A.slice<metal::dynamic_extent, 64>(0,            tgid.y * 64);
    auto tB = B.slice<32, metal::dynamic_extent>(tgid.x * 32,  0);
    auto tC = C.slice<32, 64>(                   tgid.x * 32,  tgid.y * 64);
    matmulOp.run(tA, tB, tC);
} else {
    // Edge tiles: dynamic extents, bounds-checked.
    auto tA = A.slice(0,           tgid.y * 64);
    auto tB = B.slice(tgid.x * 32, 0);
    auto tC = C.slice(tgid.x * 32, tgid.y * 64);
    matmulOp.run(tA, tB, tC);
}
```

Note the structure: **both branches call `run()`.** That is not stylistic — §4.4's uniformity rule
requires every thread in the scope to enter `run()`. An `if` that calls `run()` in one branch and
returns in the other is a correctness bug.

(Apple's version of this snippet declares `matmul2d<…> matmulOp;` and then calls `op.run(...)`.
There is no `op`. Corrected above.)

### 5.6 Declaring tensors

**Host-allocated — a kernel parameter.** The third template argument is omitted because
`tensor_handle` is the default.

> ✅ **VERIFIED** — `MPPTensorOpsMatMul2d.h:81-86`:
>
> ```cpp
> // kernel void simpleMatMul(tensor<device half,  dextents<int32_t, 2>> A,
> //                          tensor<device half,  dextents<int32_t, 2>> B,
> //                          tensor<device float, dextents<int32_t, 2>> C,
> //                          constant uint& M, constant uint& N, constant uint& K,
> //                          uint2 tgid [[threadgroup_position_in_grid]])
> ```

`dextents<int32_t, 2>` = rank 2, all extents dynamic, `int32_t` index type. Maximum rank is 16
(`__is_tensor_rank(size_t Rank) { return Rank <= 16; }`, `metal_tensor:221`), matching the host-side
`MTL_TENSOR_MAX_RANK 16`.

**Stack-constructed — `tensor_inline`.** This is how you wrap a pointer you already have, including
threadgroup memory.

> 🟡 **RECONSTRUCTED — the constructor argument list.** The `tensor_inline` specialization begins at
> `metal_tensor:1806` and its constructors were not read line by line; the transcript describes it
> as *"pass your buffer pointers and other metadata to the tensor constructor."* A community
> implementation that validates numerically against torch uses this form:
>
> ```cpp
> // Community-measured: john-rocky/coreai-model-zoo, _tensorops_proto/m1b_half_x_int4_uniform.py
> device uchar* wptr = &Wp[0, 0];
> metal::dextents<int, 2> wext(N, K);
> metal::tensor<device metal::int4b_format, metal::dextents<int, 2>, metal::tensor_inline> Wi(wptr, wext);
> ```
>
> i.e. `(pointer, extents)`. Treat the **two-argument** form as attested-and-working for the packed
> case and the general strided form as unverified.
> **What would resolve it:** reading `metal_tensor:1806-1950`.
> **Safe default:** if a two-argument construction compiles for your shape, use it; otherwise
> `static_assert` on the resulting type with `is_tensor_inline_v` before you pass it anywhere.

⚠️ Note what that community snippet actually does — it takes a `device uchar*` of **packed** 4-bit
weights and reinterprets it as a `tensor<device int4b_format, …>`. That is the *whole* mechanism for
getting 4-bit data into `matmul2d`: **a pointer cast and an element-type declaration.** There is no
unpacking API, because the 26.x op does the unpacking.

### 5.7 MLX does not use `metal::tensor` at all

> ✅ **VERIFIED (negative result)** — searching the MLX tree for `tensor_handle`, `tensor_inline`,
> `tensor_offset`, `dextents` and `.slice(` returns **zero hits**.

MLX's kernels take raw `const device T*` and `threadgroup T*` pointers, do their own indexing, and
feed `matmul2d` **exclusively through cooperative tensors**. It never constructs a `metal::tensor`
of any kind.

That is a legitimate expert choice and a bad default. `metal::tensor` gives you bounds checking,
stride handling and the `slice` machinery for free; MLX gives all of that up in exchange for exact
control of its fragment layout (§6.7). Start with tensors. Move to raw pointers when you have a
measured reason.

---

## 6. Cooperative tensors

A cooperative tensor is the API's most distinctive idea, and the one that makes fused kernels
possible. It is also the one with the most compile-time landmines.

### 6.1 What it is

> ✅ **VERIFIED** — `MPPTensorOpsMatMul2d.h:212-225`, Apple's own definition:
>
> ```
> // output is computed using cooperative_tensor. Unlike tensor_handle,
> // tensor_offset and tensor_inline which are non-owning meaning these are
> // wrappers around resource in device, threadgroup or thread address space,
> // cooperative_tensor owns thread private data and divides the data for entire
> // tensor among threads (participating in the scope of operation) in implementation
> // defined manner. This thread private memory is allocated at construction of
> // cooperative_tensor and deallocated when this cooperative_tensor goes out of
> // scope. The layout of cooperative_tensor depends on operation, data type,
> // number of threads in opscope with which op was created. Note that
> // cooperative_tensor created from an op is only valid for threads that are part
> // of execution scope on which op was created.
> ```

Three consequences to internalise:

1. **It is owning register storage, not a view.** Constructing one allocates thread-private memory;
   it is freed at scope exit. This is why it is fast and why you cannot keep one around.
2. **Its element-to-lane mapping is implementation-defined.** `ct[i]` is *some* element of the tile;
   you may not assume which. If you need coordinates, call `get_multidimensional_index(i)`.
3. **It is bound to the op and the scope that produced it.** You cannot construct one standalone and
   hand it to a differently-configured op.

Apple's motivation, from the M5 talk, is a memory round trip:

> ✅ **VERIFIED (Apple, Tech Talk 111432)** — *"With the basic approach… you would need to **write
> the output tensor to device memory** after the Matmul completes. Then **read it back in** to apply
> the activation function and **finally write it out again**. **This double trip to memory is
> costly.**"* … *"With cooperative tensors, the output of your matrix multiplication **stays in fast
> on chip memory distributed across the threads** which are participating in your operation. You can
> then **modify these elements in place**… **Only after you've finished your modifications do you
> write the final result to device memory.**"*

The type:

> ✅ **VERIFIED** — `MPPTensorOpsTraits.h:100-106` pins the shape:
>
> ```cpp
> template <class ElementType, class Extents, class Layout>
> struct __is_cooperative_tensor_type<metal::cooperative_tensor<ElementType, Extents, Layout>> : __true_type
> {
> };
> ```

**`metal::cooperative_tensor<ElementType, Extents, Layout>`** — three parameters, in namespace
`metal` (not `mpp`), declared in `<metal_cooperative_tensor>`.

### 6.2 Cooperative tensors can be *any* operand — confirmed two ways

> ✅ **VERIFIED** — `MPPTensorOpsMatMul2d.h:404-418`, the `run()` SFINAE:
>
> ```cpp
>   template <
>       typename LeftOperandType, typename RightOperandType,
>       typename DestinationOperandType,
>       typename V = __tensor_ops_detail::__enable_if_t<
>           ((__tensor_ops_detail::__is_tensor_type_v<LeftOperandType> || __tensor_ops_detail::__is_cooperative_tensor_type_v<LeftOperandType>) &&
>            (__tensor_ops_detail::__is_tensor_type_v<RightOperandType> || __tensor_ops_detail::__is_cooperative_tensor_type_v<RightOperandType>) &&
>            (__tensor_ops_detail::__is_tensor_type_v<DestinationOperandType> || __tensor_ops_detail::__is_cooperative_tensor_type_v<DestinationOperandType>))>,
>       typename... RunArgs>
>   INLINE void run(thread LeftOperandType &left, thread RightOperandType &right,
>                   thread DestinationOperandType &destination) thread const
> ```

Each of the three operands is **independently** constrained to "tensor type **or** cooperative
tensor type." All three may be cooperative tensors simultaneously — which is exactly what MLX does,
in shipping code, so this is proven and not merely permitted.

Two mechanical details from that signature:

- All three operands are taken by **non-const `thread` reference**. There is no `const` overload.
  You cannot pass a `const` operand, even the inputs.
- The internal namespace is `__mutmul2d_detail` — a shipping typo for `__matmul2d_detail`. It will
  appear in your compile errors. It is not your fault.

Note the header's own opening comment is narrower than the SFINAE:

> `MPPTensorOpsMatMul2d.h:9-10` — *"A and B can be `tensor_handle`, `tensor_offset`, and
> `tensor_inline`. C can be `tensor_handle`, `tensor_offset`, `tensor_inline` or
> `cooperative_tensor`."*

That comment describes the **26.0** state of the world (cooperative destinations only) and was not
updated when input cooperative tensors landed. The `#if` split in §1.2 is the mechanical trace of
that change. Trust the SFINAE and the MLX call site, not the comment.

### 6.3 The three getters — and the asymmetry that is the #1 compile failure

You do not construct a cooperative tensor directly. You **ask the op for one**, so that it can pick
the layout.

> ✅ **VERIFIED** — `MPPTensorOpsMatMul2d.h:425-438` (left input, no-arg form):
>
> ```cpp
>   template <typename LeftElementType, typename RightElementType,
>             typename ElementType, typename CoordType = int,
>             typename U = __tensor_ops_detail::__enable_if_t<
>                 __tensor_ops_detail::__is_thread_addrspace_v<LeftElementType> &&
>                 __tensor_ops_detail::__is_thread_addrspace_v<RightElementType> &&
>                 __tensor_ops_detail::__is_thread_addrspace_v<ElementType> &&
>                 __tensor_ops_detail::__is_integral_v<CoordType>>,
>             typename... CoopArgs>
>   INLINE cooperative_tensor_left_input_t<LeftElementType, RightElementType, ElementType, CoordType, CoopArgs...>
>   get_left_input_cooperative_tensor() thread const
> ```
>
> and `:531-546` (destination):
>
> ```cpp
>   template <typename LeftOperandType, typename RightOperandType,
>             typename ElementType, typename CoordType = int,
>             typename U = __tensor_ops_detail::__enable_if_t<
>                 (__tensor_ops_detail::__is_tensor_type_v<LeftOperandType> || __tensor_ops_detail::__is_cooperative_tensor_type_v<LeftOperandType>) &&
>                 (__tensor_ops_detail::__is_tensor_type_v<RightOperandType> || __tensor_ops_detail::__is_cooperative_tensor_type_v<RightOperandType>) &&
>                 __tensor_ops_detail::__is_thread_addrspace_v<ElementType> &&
>                 __tensor_ops_detail::__is_integral_v<CoordType>>,
>             typename... CoopArgs>
>   INLINE cooperative_tensor_destination_t<LeftOperandType, RightOperandType, ElementType, CoordType, CoopArgs...>
>   get_destination_cooperative_tensor() thread const
> ```

(Those are the 26.6 spellings. In the macOS 27.0 beta SDK — checked 2026-07-29 — the element-type
clauses on all of these getters read `__is_unqualified_v<…>` instead of
`__is_thread_addrspace_v<…>`: same intent, pass unqualified element types like `half` or `float`.
In the same header Apple's fourth worked example now writes the destination getter's operand types
as `__remove_addrspace_t<decltype(mA)>` rather than bare `decltype(mA)`
(`MPPTensorOpsMatMul2d.h:274,293`, 27.0 SDK) — worth copying if you target 27, since a
kernel-parameter tensor's `decltype` carries its address space.)

**Read those two SFINAE clauses side by side.** They are not the same kind of thing:

| Getter | TP1 | TP2 | TP3 | TP4 |
|---|---|---|---|---|
| `get_left_input_cooperative_tensor` | `LeftElementType` | `RightElementType` | `ElementType` | `CoordType = int` |
| `get_right_input_cooperative_tensor` | `LeftElementType` | `RightElementType` | `ElementType` | `CoordType = int` |
| `get_destination_cooperative_tensor` | **`LeftOperandType`** | **`RightOperandType`** | `ElementType` | `CoordType = int` |

The **input** getters want *element* types (`half`, `bfloat`, `float`). The **destination** getter
wants *operand* (tensor) types — the actual types of the two inputs.

This is why MLX writes it the way it does:

> ✅ **VERIFIED** — `mlx/backend/metal/kernels/steel/gemm/nax.h:414-425`:
>
> ```cpp
>     auto ct_a =
>         gemm_op
>             .template get_left_input_cooperative_tensor<AType, BType, CType>();
>     auto ct_b =
>         gemm_op
>             .template get_right_input_cooperative_tensor<AType, BType, CType>();
>
>     // Create matmul output in register
>     auto ct_c = gemm_op.template get_destination_cooperative_tensor<
>         decltype(ct_a),
>         decltype(ct_b),
>         CType>();
> ```

`<AType, BType, CType>` for the inputs — three element types. `<decltype(ct_a), decltype(ct_b),
CType>` for the destination — two **operand** types and one element type. Get this backwards and
nothing compiles, with an error message pointing deep inside `__mutmul2d_detail`.

The `.template` keyword is required because `gemm_op` is a dependent type inside a template
function. Omit it and you get an unrelated parse error about `<`.

Each getter has a matching public type alias, so you can name the type without `decltype`:

> ✅ **VERIFIED** — `MPPTensorOpsMatMul2d.h:421`, `:474`, `:527`:
> `cooperative_tensor_left_input_t`, `cooperative_tensor_right_input_t`,
> `cooperative_tensor_destination_t`.

And note two absences:

> ✅ **VERIFIED** — there is **no** `is_compatible_as_destination`, and **no**
> `get_destination_cooperative_tensor(src)` conversion overload. The asymmetry is real: you can
> convert a destination into an input, never the reverse.

### 6.4 ⚠️ SILENT FAILURE: masked elements, and the method name that does not exist

Not every slot in a cooperative tensor is live. Apple says so plainly:

> ✅ **VERIFIED** — `MPPTensorOpsMatMul2d.h:247-250`:
>
> ```
> //    // cooperative tensor will divide data among the threads in these
> //    // 4 SIMD-Groups. The layout of data among lanes is implementation defined
> //    // and not all threads and even all elements within a thread need
> //    // be valid. Use the valid element check shown below to guard
> ```

And then the "check shown below" is spelled **`cT.get_mask(i)`** — twice, at `:261` and `:280`.

> ✅ **VERIFIED (negative result)** — `grep -rn "get_mask"` over the entire Metal toolchain include
> directory returns **zero hits**. It is not a member of `cooperative_tensor`, it is not in the
> Layout concept, it is not anywhere. The only occurrences on this machine are those two Apple
> comments. (Re-checked 2026-07-31 against the 27-era toolchain shipped for Xcode 27.0 beta
> 27A5228h, `metal 32023.921`: still zero hits across all 71 language headers.)

**The real name is `is_valid_element`,** and there are three overloads on the cooperative tensor
plus one on the iterator:

> ✅ **VERIFIED** — `metal_cooperative_tensor:418-430`:
>
> ```cpp
>   METAL_FUNC bool is_valid_element(thread_index_type idx) thread const
>   {
>     return static_cast<bool>(Layout::is_valid_element(static_cast<const thread void *>(this), idx));
>   }
>   METAL_FUNC bool is_valid_element(const_iterator it) thread const
>   {
>     return is_valid_element(it._idx);
>   }
>   METAL_FUNC bool is_valid_element(const thread element_type *ptr) thread const
>   {
>     return is_valid_element(get_iterator(ptr));
>   }
> ```
>
> plus, on the iterator, `metal_cooperative_tensor:144-146`:
>
> ```cpp
>   METAL_FUNC bool is_valid_element() thread const {
>     return _ct.is_valid_element(_idx);
>   }
> ```
>
> and the Layout requirement that makes it mandatory, `:342-343`:
> *"cooperative_tensor: Layout needs to implement 'is_valid_element' interface"*.

Now the part that deserves the callout box.

> ⚠️ **SILENT FAILURE — `set()` on a masked element is a no-op, and `get()` returns zero.**
>
> ✅ **VERIFIED** — `metal_cooperative_tensor:448-481`:
>
> ```cpp
>   METAL_FUNC reference operator[](thread_index_type idx) thread
>   { … }                                    // UNCHECKED
>   METAL_FUNC const_reference operator[](thread_index_type idx) thread const
>   { … }                                    // UNCHECKED
>
>   METAL_FUNC value_type get(thread_index_type idx) thread const
>   {
>     return is_valid_element(idx) ? (*this)[idx] : value_type();   // <-- returns 0 if masked
>   }
>
>   METAL_FUNC void set(thread_index_type idx, value_type v) thread
>   {
>     if (is_valid_element(idx))                                     // <-- silently skips if masked
>       (*this)[idx] = v;
>   }
> ```
>
> There are three access styles and they fail in three different ways:
>
> | Style | On a masked element | Failure mode |
> |---|---|---|
> | `ct[i] = v` / `x = ct[i]` | writes / reads thread-private storage with no validity check | may corrupt layout metadata or read garbage |
> | `ct.set(i, v)` | **does nothing** | your write vanishes; no error |
> | `ct.get(i)` | **returns `value_type()`**, i.e. zero | your read yields a plausible 0.0 |
>
> The `set`/`get` pair is the *safe* API and that is exactly what makes it dangerous: a masked write
> that silently disappears looks identical to a correct write, and a masked read that yields 0.0
> looks identical to a real zero. If you build a reduction on top of `get()` without checking
> validity, masked lanes contribute zeros — which is the correct identity for `sum` and the **wrong**
> identity for `max` and `min` (compare §7.2, where the same bug appears in a different disguise).
>
> **Defence:** guard explicitly rather than relying on `set`/`get` to do it invisibly.
>
> ```cpp
> #pragma unroll full
> for (uint16_t i = 0; i < cT.get_capacity(); ++i) {
>     if (cT.is_valid_element(i)) {      // NOT get_mask(i) — that does not exist
>         cT[i] = 0;                     // unchecked access, now provably safe
>     }
> }
> ```
>
> The explicit `if` documents the intent and lets you use the fast unchecked `operator[]` inside it.

The `#pragma unroll full` is not decorative:

> ✅ **VERIFIED** — Apple's example comment, `MPPTensorOpsMatMul2d.h:259`: *"It is imperative for
> performance to include 'unroll pragma'"*. Without it the compiler cannot see through the
> capacity loop and the register file becomes an addressed array.

### 6.5 Capacity, coordinates, load and store

> ✅ **VERIFIED** — `metal_cooperative_tensor`:
>
> | Member | Line | Signature / note |
> |---|---:|---|
> | `get_rank()` | 376 | `static constexpr rank_type` |
> | `get_capacity()` | 413 | `thread_size_type get_capacity() thread const` — elements owned **by this thread** |
> | `is_valid_element(idx / it / ptr)` | 418, 423, 427 | `bool` |
> | `get_multidimensional_index(idx / it / ptr)` | 432, 437, 442 | `array<index_type, get_rank()>` |
> | `operator[](idx)` | 448, 452 | mutable / const `reference` |
> | `get(idx)` / `set(idx, v)` | 457, 470 | validity-checked (§6.4) |
> | `load(tensor)` | 487, 495 | see below |
> | `store(tensor)` | 504, 512 | see below |
> | `get_iterator(...)` | ~525-536 | |
> | `map_iterator(OtherIterator)` | 543, 553 | §7.3 |
> | `begin()` / `end()` | 559-577 | `end()` is `get_iterator(get_capacity())` |

`load` and `store` — the notes on this API previously listed these as unverified; they are not:

> ✅ **VERIFIED** — `metal_cooperative_tensor:485-514`, both take a `metal::tensor`, and there are
> two overloads apiece, one per descriptor kind:
>
> ```cpp
>   METAL_FUNC enable_if_t<(is_same_v<element_type, typename tensor<T, E, tensor_handle, Tags...>::value_type> && …)>
>   load(tensor<T, E, tensor_handle, Tags...> t) thread          // by value
>   { Layout::load(static_cast<thread void *>(this), t); }
>
>   METAL_FUNC enable_if_t<…>
>   load(const thread tensor<T, E, tensor_inline, Tags...> &t) thread   // by const ref
>   { Layout::load(static_cast<thread void *>(this), t); }
>
>   METAL_FUNC enable_if_t<…>
>   store(tensor<T, E, tensor_handle, Tags...> t) thread const
>   { Layout::store(static_cast<const thread void *>(this), t); }
>
>   METAL_FUNC enable_if_t<…>
>   store(const thread tensor<T, E, tensor_inline, Tags...> &t) thread const
>   { Layout::store(static_cast<const thread void *>(this), t); }
> ```
>
> Note the SFINAE requires `element_type` to equal the tensor's `value_type` — **no conversion
> happens on load or store.** A `float` cooperative tensor cannot store into a `half` tensor.

Putting it together — the canonical fused-epilogue shape, which is the reason cooperative tensors
exist. This is Apple's fourth worked example, corrected for the two doc-comment defects:

```cpp
// C = A*B, then add a bias tensor and apply a coordinate-dependent function,
// all without a round trip to device memory.
auto cT = matmulOp.template get_destination_cooperative_tensor<
              decltype(mA), decltype(mB), float>();

#pragma unroll full
for (uint16_t i = 0; i < cT.get_capacity(); ++i) {   // ';' not ',' — Apple's comment has a typo
    if (cT.is_valid_element(i))                      // NOT get_mask
        cT[i] = 0;                                   // zero before accumulating (see §3.5)
}

matmulOp.run(mA, mB, cT);

auto biasT = matmulOp.template get_destination_cooperative_tensor<
                 decltype(mA), decltype(mB), float>();
biasT.load(bias);                                    // bias is a tensor_handle

#pragma unroll full
for (uint16_t i = 0; i < cT.get_capacity(); ++i) {
    if (cT.is_valid_element(i)) {
        cT[i] += biasT[i];
        auto ids = cT.get_multidimensional_index(i); // 2-D coordinate within the tile
        cT[i] = activation(cT[i], ids);
    }
}

cT.store(mC);                                        // one write to device memory, at the end
```

> ✅ **VERIFIED** — Apple's stated motivation for this shape, `MPPTensorOpsMatMul2d.h:206-211`:
> *"we need to do some post processing on computed results before storing… One can do GEMM as above
> which writes the result to device memory, read the value back, call post processing function and
> write again. **This results in wasted bandwidth, performance and power.** User can apply post
> processing **in-register**."*

Note that `biasT` is created with the **destination** getter, then `load`ed. That is deliberate: it
guarantees `biasT` has the same implementation-defined layout as `cT`, so `biasT[i]` and `cT[i]`
refer to the same matrix element. Creating it any other way and assuming index correspondence is a
bug — see §7.3 for the general mechanism when the layouts genuinely differ.

### 6.6 The conversion overloads — the fusion primitive, and its five hard constraints

This is the 26.3 feature: turn the **destination** of one matmul into the **left or right input** of
the next, without going through memory.

> ✅ **VERIFIED** — `MPPTensorOpsMatMul2d.h:440-456`:
>
> ```cpp
>   template <typename LeftElementType, typename RightElementType,
>             typename ElementType, typename CoordType = int,
>             typename SrcElemType, typename SrcExtents, typename SrcLayout,
>             …>
>   INLINE cooperative_tensor_left_input_t<LeftElementType, RightElementType, ElementType, CoordType, CoopArgs...>
>   get_left_input_cooperative_tensor(const thread metal::cooperative_tensor<SrcElemType, SrcExtents, SrcLayout> & src) thread const
> ```
>
> Right-hand mirror at `:493-509`.

And the compatibility guard you are supposed to call first:

> ✅ **VERIFIED** — `MPPTensorOpsMatMul2d.h:458-471`:
>
> ```cpp
>   template <typename LeftElementType, typename RightElementType, typename ElementType,
>             typename SrcElemType, typename SrcExtents, typename SrcLayout,
>             typename U = __tensor_ops_detail::__enable_if_t<…>>
>   INLINE bool
>   is_compatible_as_left_input(const thread metal::cooperative_tensor<SrcElemType, SrcExtents, SrcLayout> & src) thread const
> ```
>
> Right mirror at `:511-524`. Both return a **runtime `bool`** (not `constexpr`), take exactly one
> runtime argument, and — unlike the getters — have **no `CoordType` template parameter**.

Session 330 describes the intended usage precisely:

> ✅ **VERIFIED (Apple, session 330)** — *"**One thing to watch out for: not every cooperative tensor
> can be reused as an input. The layouts may differ depending on the data types and other factors.
> So before you do this, call the `is_compatible_as_left` or `right _input` method to check for
> compatibility.**"* … *"If it returns true, you're good to go. **If not, you'll need to store and
> reload the data through threadgroup memory to convert it to the correct layout. Either way, the
> call to `op.run` is the same.**"*
>
> ("`is_compatible_as_left` or `right _input`" is an ASR artifact; the real names are
> `is_compatible_as_left_input` and `is_compatible_as_right_input`.)

But the runtime check is only half the story. **The implementation carries a wall of
`static_assert`s that will reject your code at compile time**, and they are not documented anywhere
else:

> ✅ **VERIFIED** — `__impl/MPPTensorOpsMatMul2dImpl.h:3308-3341`, the constraints on
> `__get_left_input_cooperative_tensor(src)`, with their exact messages:
>
> ```cpp
>     static_assert(…__is_same_v<typename src_layout::scope_t, metal::execution_simdgroup>,
>                   "Input cooperative tensors require a single SIMD group");
>     static_assert(src_layout::__is_matmul2d_cooperative_tensor_layout,
>                   "Source must be matmul2d cooperative destination tensor");
>     static_assert(src_layout::__operand_index == __matmul2d_cooperative_operand_index::destination,
>                   "Source must be matmul2d cooperative destination tensor");
>     static_assert(…__is_same_v<scope, metal::execution_simdgroup>,
>                   "Input cooperative tensors require a single SIMD group");
>     static_assert(src_extents::rank() == 2, "Source rank must be 2");
>     static_assert(…__is_same_v<typename src_extents::index_type, int>, "src_extents::index_type must be int");
>     static_assert(…__is_same_v<coord_type, int>, "coord_type must be int");
>     static_assert(…__is_same_v<src_elem_type, left_element_type>,
>                   "Source cooperative tensor element type must match matmul2d left input element type");
>
>     constexpr __matmul2d_descriptor dstDesc = descriptor;
>     constexpr __matmul2d_descriptor srcDesc = src_layout::matmul2d_desc;
>
>     static_assert(dstDesc.k != static_cast<int>(metal::dynamic_extent) && dstDesc.k != dynamic_length_v<int>,
>                   "Inner dimension cannot be dynamic with input cooperative tensors");
>     static_assert(dstDesc.transpose_left ? (srcDesc.n == dstDesc.m) : (srcDesc.m == dstDesc.m),
>                   "Source height must match matmul2d op height");
>     static_assert(dstDesc.transpose_left ? (srcDesc.m == dstDesc.k) : (srcDesc.n == dstDesc.k),
>                   "Source width must match matmul2d op inner dimension");
>     static_assert(!dstDesc.transpose_left, "Input cooperative tensor cannot be transposed");
> ```

Distilled into a checklist — **all** of these must hold before a cooperative tensor can be a matmul
input:

1. **Scope is `execution_simdgroup`** on both the source op and the consuming op. Not
   `execution_simdgroups<2>`. Not `<4>`. One.
2. **The source must be a matmul2d *destination* cooperative tensor.** Not an input tensor, not
   something you built another way.
3. **Rank 2, `int` index type, `int` coord type.**
4. **`dstDesc.k` must be a concrete integer** — `dynamic_extent` is rejected outright, and so is
   `dynamic_length_v<int>`. Feeding a cooperative tensor into a matmul means **you own the K loop**.
5. **`transpose_left` (or `transpose_right`) must be `false`** on the consuming descriptor, and the
   source's shape must match on both axes.

Point 4 has a design consequence people miss: the convenience of `k = dynamic_extent` and the
fusion capability of cooperative-tensor inputs are **mutually exclusive**. Pick one.

The two-tier check — `static_assert` at compile time for shape and scope, `is_compatible_as_*_input`
at run time for layout — means a green compile does **not** mean the conversion will succeed. Write
both:

```cpp
if (pv_op.template is_compatible_as_left_input<float, half, float>(S)) {
    auto lhs = pv_op.template get_left_input_cooperative_tensor<float, half, float>(S);
    pv_op.run(lhs, vTile, O);                      // registers only
} else {
    // Documented fallback: round-trip through threadgroup memory to fix the layout.
    S.store(tgScratchTensor);                      // tensor_inline over threadgroup memory
    threadgroup_barrier(metal::mem_flags::mem_threadgroup);
    pv_op.run(tgScratchTensor, vTile, O);          // "Either way, the call to op.run is the same."
}
```

> 🟡 **RECONSTRUCTED** — the code block above follows Apple's narrated shape and the verified
> signatures, but no compiled example of the fallback branch exists in the corpus. The **branch
> structure** and the **`is_compatible` → `get_…(src)` → `run`** sequence are verified from the
> header and the transcript; the exact threadgroup-scratch construction is yours to write.

### 6.7 MLX's cooperative-tensor usage, annotated

MLX's entire contact surface with MPP TensorOps is one function, written twice with mirrored
operand shapes. Here it is, and it repays close reading:

> ✅ **VERIFIED** — `mlx/backend/metal/kernels/steel/gemm/nax.h:387-456`, complete:
>
> ```cpp
>   template <
>       typename CType,
>       typename AType,
>       typename BType,
>       bool transpose_a = false,
>       bool transpose_b = false>
>   METAL_FUNC static constexpr void mma(
>       thread dtype_frag_t<CType>& Cn0,
>       thread dtype_frag_t<CType>& Cn1,
>       const thread dtype_frag_t<AType>& A,
>       metal::bool_constant<transpose_a>,
>       const thread dtype_frag_t<BType>& Bn0,
>       const thread dtype_frag_t<BType>& Bn1,
>       metal::bool_constant<transpose_b>) {
>     constexpr auto desc = mpp::tensor_ops::matmul2d_descriptor(
>         16,
>         32,
>         16,
>         transpose_a,
>         transpose_b,
>         true,
>         mpp::tensor_ops::matmul2d_descriptor::mode::multiply_accumulate);
>
>     // Create matmul op
>     mpp::tensor_ops::matmul2d<desc, metal::execution_simdgroup> gemm_op;
>
>     // Create matmul operands in registers
>     auto ct_a =
>         gemm_op
>             .template get_left_input_cooperative_tensor<AType, BType, CType>();
>     auto ct_b =
>         gemm_op
>             .template get_right_input_cooperative_tensor<AType, BType, CType>();
>
>     // Create matmul output in register
>     auto ct_c = gemm_op.template get_destination_cooperative_tensor<
>         decltype(ct_a),
>         decltype(ct_b),
>         CType>();
>
>     // Load A in to left operand registers
>     STEEL_PRAGMA_UNROLL
>     for (short i = 0; i < kElemsPerFrag; i++) {
>       ct_a[i] = A[i];
>     }
>
>     // Load B into right operand registers
>     STEEL_PRAGMA_UNROLL
>     for (short i = 0; i < kElemsPerFrag; i++) {
>       ct_b[i] = Bn0[i];
>       ct_b[kElemsPerFrag + i] = Bn1[i];
>     }
>
>     // Load C into output registers (op handles accumulation)
>     STEEL_PRAGMA_UNROLL
>     for (short i = 0; i < kElemsPerFrag; i++) {
>       ct_c[i] = Cn0[i];
>       ct_c[kElemsPerFrag + i] = Cn1[i];
>     }
>
>     // Do matmul
>     gemm_op.run(ct_a, ct_b, ct_c);
>
>     // Copy out results
>     STEEL_PRAGMA_UNROLL
>     for (short i = 0; i < kElemsPerFrag; i++) {
>       Cn0[i] = ct_c[i];
>       Cn1[i] = ct_c[kElemsPerFrag + i];
>     }
>   }
> ```

Six things to take from it, three of which are deviations you should **not** copy blindly:

1. **All seven descriptor arguments, positional.** `m=16, n=32, k=16` — a tiny per-SIMD-group
   micro-tile. MLX is not letting MPP tile for it. The 16×16 fragment is MLX's own
   `BaseNAXFrag::kFragRows/kFragCols`; `n=32` because the op consumes two adjacent 16-wide B
   fragments at once.
2. **`mode::multiply_accumulate` passed explicitly**, and C pre-loaded into `ct_c` first — the
   comment *"op handles accumulation"* says the intent out loud. This is the §3.5 safe default in
   production.
3. **`relaxed_precision = true`, unconditionally.** This is one half of a two-part feature; see
   [guide 11.2 §11.2](02-cooperative-tensors-and-flash-attention.md#112-what-it-does-instead).
4. ⚠️ **MLX never calls `is_valid_element`.** It writes `ct_a[i] = A[i]` straight through the
   unchecked `operator[]`. It gets away with this because its descriptor exactly matches its own
   fragment size, so every slot is live. **Copy this into a kernel with a different tile shape and
   you have a latent correctness bug.** Use the guard (§6.4) as your default and drop it only when
   you can prove capacity equals your fragment size.
5. ⚠️ **MLX relies on an undocumented linearisation.** `kElemsPerFrag = (kFragRows * kFragCols) / 32`
   = `(16*16)/32` = 8, and the two-fragment operands occupy indices `[0,8)` and `[8,16)`. That
   assumes a specific ordering of the cooperative tensor's lane-private storage, which Apple's own
   text calls implementation-defined. It works; it is **not contractual**.
6. **`execution_simdgroup`** — which, per §4.6, is not a preference. It is the only scope that
   permits input cooperative tensors.

The layers MLX builds above this:

> ✅ **VERIFIED** — `mlx/backend/metal/kernels/steel/gemm/nax.h`:
>
> | Layer | Lines | Role |
> |---|---|---|
> | `BaseNAXFrag` | 27-529 | 16×16 fragment: `get_coord()`, load/store variants, `row_reduce`, `row_bin_op`, and the two `mma` overloads |
> | `NAXTile<T, R, C>` | 531-817 | a grid of fragments in registers: `load`/`store`/`load_safe`/`store_safe`/`load_rows`/`store_rows`/`store_slice` |
> | `tile_matmad_nax(...)` | 825-884 | drives `mma` across the tile; static-asserts M/N/K agreement |
> | `gemm_loop(...)` | `gemm_nax.h:26-129` | the K loop, with aligned and unaligned specialisations |
>
> `mlx/backend/metal/kernels/steel/attn/nax.h` is **byte-identical** to `steel/gemm/nax.h` (verified
> by `diff`) — MLX's attention kernels use exactly the same `mma`.

---

## 7. Reductions and iterator mapping

Reductions exist because of softmax. If you are building FlashAttention, you need a row max and a
row sum over an intermediate that lives in registers, and you need it without a memory round trip.

### 7.1 `reduce_rows` is a **free function**, not a member

Session 330 describes `reduce_rows` in a way that sounds like a method on the cooperative tensor. It
is not.

> ✅ **VERIFIED** — `MPPTensorOpsMatMul2d.h:587-597`:
>
> ```cpp
> template <class ElementType, class SrcExtents, class DstExtents, class SrcLayout, class DstLayout>
> inline void reduce_rows(
>     thread metal::cooperative_tensor<ElementType, SrcExtents, SrcLayout> &source,
>     thread metal::cooperative_tensor<ElementType, DstExtents, DstLayout> &destination,
>     reduction_operation op = reduction_operation::sum,
>     ElementType identity =
>         reduction_operation_identity<ElementType>::sum_identity)
> {
>   __mutmul2d_detail::__reduce_rows<ElementType, SrcExtents, DstExtents, SrcLayout, DstLayout>(
>       source, destination, identity, op);
> }
> ```
>
> and its unmentioned twin at `:599-609`, `reduce_columns`, with the identical shape.

Facts to get right:

- Both live at **namespace scope in `mpp::tensor_ops`**. Call them unqualified inside that namespace
  or as `mpp::tensor_ops::reduce_rows(...)`.
- **Source and destination must share `ElementType`.** There is one `ElementType` parameter serving
  both. You **cannot** reduce a `half` tile into a `float` accumulator with this call. If you need
  wider accumulation, make the source `float`.
- **Both operands must be cooperative tensors.** You cannot reduce into a plain `tensor`.
- The public argument order is `(source, destination, op, identity)`. (The internal `__reduce_rows`
  swaps the last two; irrelevant to you, but it will look odd in a stack trace.)

The operations:

> ✅ **VERIFIED** — `MPPTensorOpsMatMul2d.h:342-347`:
>
> ```cpp
> enum class reduction_operation
> {
>   sum,
>   max,
>   min,
> };
> ```

**Exactly three.** No `prod`, no `mean`, no `any`/`all`. If you need a product or a mean, build it
from these or write it yourself.

And rather than shaping a destination by hand, ask the op:

> ✅ **VERIFIED** — `MPPTensorOpsMatMul2d.h:554-565` and `:574-584`:
> `get_row_reduction_destination_cooperative_tensor<LeftOperandType, RightOperandType, ElementType,
> CoordType = int>()` and the column mirror. Their template parameters follow the **destination**
> convention (operand types, then element type), like `get_destination_cooperative_tensor`.

### 7.2 ⚠️ SILENT FAILURE: the identity default is `sum_identity` regardless of the operation

> ✅ **VERIFIED** — `MPPTensorOpsMatMul2d.h:379-387`:
>
> ```cpp
> template <typename ElementType>
> struct reduction_operation_identity
> {
>   static const constant ElementType sum_identity = (ElementType)0;
>   static const constant ElementType max_identity =
>       metal::numeric_limits<ElementType>::lowest();
>   static const constant ElementType min_identity =
>       metal::numeric_limits<ElementType>::max();
> };
> ```

Three identities exist and are correct. But look again at `reduce_rows`' default argument:

```cpp
    ElementType identity = reduction_operation_identity<ElementType>::sum_identity
```

**It is `sum_identity` — zero — no matter what you pass for `op`.** So:

```cpp
reduce_rows(src, dst, reduction_operation::max);       // identity silently defaults to 0
```

computes `max(0, row)` and **clamps every negative row maximum to zero.** No warning, no NaN, no
crash. In a softmax that means every row whose scores are all negative gets the wrong maximum, and
the subsequent `exp(x - m)` underflows differently than it should — the output is still a valid
probability distribution, just the wrong one. This is the defining shape of a silent failure in
this stack: the answer is plausible.

The correct calls:

```cpp
using namespace mpp::tensor_ops;

reduce_rows(src, dst, reduction_operation::sum,
            reduction_operation_identity<float>::sum_identity);   // 0.0f

reduce_rows(src, dst, reduction_operation::max,
            reduction_operation_identity<float>::max_identity);   // numeric_limits<float>::lowest()

reduce_rows(src, dst, reduction_operation::min,
            reduction_operation_identity<float>::min_identity);   // numeric_limits<float>::max()
```

**Rule: never call `reduce_rows` or `reduce_columns` with three arguments.** Always pass the
identity, even for `sum` where it is redundant — the redundancy is the point, because it makes the
`max` case impossible to forget.

Two numeric details:

- `max_identity` is `lowest()`, **not** `-numeric_limits<T>::max()` and **not** `-INFINITY`. For
  floats those first two coincide in value; for integer element types `lowest()` is correct and
  `-max()` is off by one.
- Session 330 narrates *"the `max` `reduction_operation` with an initial value of negative
  INFINITY."* `-INFINITY` works for floats and is arguably more correct for an online softmax, but
  it is **not** what `max_identity` is. If you want `-INFINITY`, pass it literally.

### 7.3 `map_iterator` and `is_iterator_compatible`

After a row reduction you have two cooperative tensors of **different shapes** — an M×N score tile
and an M×1 row-max — with independent, implementation-defined lane layouts. To combine them
elementwise you need to translate a position in one into the corresponding position in the other.

> ✅ **VERIFIED** — `metal_cooperative_tensor:538-557`:
>
> ```cpp
>   template <class OtherIterator>
>   METAL_FUNC enable_if_t<__cooperative_tensor_detail::is_detected<
>                              __cooperative_tensor_detail::has_interface_map_index,
>                              layout, OtherIterator, iterator>::value,
>                          iterator>
>   map_iterator(OtherIterator it) thread
>   { … }
>
>   template <class OtherIterator>
>   METAL_FUNC enable_if_t<…, const_iterator>
>   map_iterator(OtherIterator it) thread const
> ```

Precisely:

- **Argument:** an `OtherIterator` — an iterator obtained from a *different* cooperative tensor.
  Not an index. Not a coordinate.
- **Returns:** an `iterator` (non-const overload) or `const_iterator` (const overload) into
  **`*this`**, positioned at the corresponding element.
- **SFINAE-gated** on the layout implementing a `map_index` interface. If the two layouts are
  incompatible, the overload does not exist and you get a hard compile error rather than a wrong
  answer. That is the good failure mode.
- It is a member of **`metal::cooperative_tensor`**, not of `mpp::tensor_ops`.

The runtime guard, which session 330 never mentions:

> ✅ **VERIFIED** — `MPPTensorOpsMatMul2d.h:611-633`, including Apple's own usage comment:
>
> ```cpp
> // Returns whether the iterators are compatible between a source and destination cooperative tensor.
> //
> // Use this to check whether map_iterator will be return a valid iterator. For example:
> //
> //     if (is_iterator_compatible(sourceCT, destCT)) {
> //         for (auto it = sourceCT.begin(); it != sourceCT.end(); it++) {
> //             auto dst_it = destCT.map_iterator(sourceCT)
> //
> //             *it += *dst_it;
> //         }
> //     }
> //     else {
> //          // Fall back to storing sourceCT to threadgroup memory and access via
> //          // destCT's multidimensional indices
> //     }
> template <class SrcElementType, class DstElementType, class SrcExtents, class DstExtents, class SrcLayout, class DstLayout>
> inline bool is_iterator_compatible(
>     const thread metal::cooperative_tensor<SrcElementType, SrcExtents, SrcLayout> &source,
>     const thread metal::cooperative_tensor<DstElementType, DstExtents, DstLayout> &destination)
> ```

Two observations:

- `is_iterator_compatible` allows **differing element types** (`SrcElementType`, `DstElementType`),
  unlike `reduce_rows`, which forces them equal. So you can check compatibility between a `half`
  tile and a `float` reduction, even though you could not have produced that pair with `reduce_rows`.
- Apple's example snippet is itself defective: it passes `sourceCT` where `it` belongs and drops a
  semicolon. Corrected:

```cpp
using namespace mpp::tensor_ops;

if (is_iterator_compatible(S, rowMax)) {
    for (auto it = S.begin(); it != S.end(); ++it) {
        auto m_it = rowMax.map_iterator(it);   // iterator in, iterator out
        *it = metal::exp(*it - *m_it);         // subtract the max first — always
    }
} else {
    // Documented fallback: store S to threadgroup memory and address it via
    // rowMax's multidimensional indices.
}
```

The documented fallback — *"storing sourceCT to threadgroup memory and access via destCT's
multidimensional indices"* — is worth writing even if you never expect to hit it, because it is the
only portable path when the layouts differ and there is no way to test it without a device that
produces incompatible layouts.

> ⚠️ **Subtract the max first.** `metal::exp(*it)` without the running-max subtraction overflows for
> scores above ~88 in fp32 and ~11 in fp16. A community repo's agent-instruction file lists this
> under traps that repeatedly catch implementers: *"Naked `exp()` in a hand-written kernel. **Three
> separate sessions lost to this; subtract the max first.**"* (community-measured, `john-rocky`
> `AGENTS.md:65-79`). The same source notes that for cross-compiler determinism you may want
> `metal::precise::exp` rather than the default.

### 7.4 What MLX does instead, and why

> ✅ **VERIFIED (negative result)** — MLX uses **none** of `reduce_rows`, `reduce_columns`,
> `map_iterator` or `is_iterator_compatible`. Zero hits across the tree.

Its attention kernel rolls its own row reduction over its own fragment layout with `simd_shuffle_xor`:

> ✅ **VERIFIED** — `mlx/backend/metal/kernels/steel/gemm/nax.h:353-371`:
>
> ```cpp
>   template <typename Op, typename T>
>   METAL_FUNC static constexpr void row_reduce(
>       thread const dtype_frag_t<T>& inp_vals,
>       thread T* reduced_vals) {
>     STEEL_PRAGMA_UNROLL
>     for (short i = 0; i < kElemRows; i++) {
>       T thr_reduce = Op::apply(
>           Op::apply(inp_vals[i * kElemCols + 0], inp_vals[i * kElemCols + 1]),
>           Op::apply(inp_vals[i * kElemCols + 2], inp_vals[i * kElemCols + 3]));
>
>       T qgr_reduce = simd_shuffle_xor(thr_reduce, ushort(1));
>       qgr_reduce = Op::apply(thr_reduce, qgr_reduce);
>
>       T sgr_reduce = simd_shuffle_xor(qgr_reduce, ushort(8));
>       sgr_reduce = Op::apply(qgr_reduce, sgr_reduce);
>
>       reduced_vals[i] = Op::apply(reduced_vals[i], sgr_reduce);
>     }
>   }
> ```
>
> and calls it from the online softmax,
> `mlx/backend/metal/kernels/steel/attn/kernels/steel_attention_nax.h:395,398,413,416`:
>
> ```cpp
>     Stile.template row_reduce<MaxOp>(new_max);
>     Stile.template row_bin_op<ExpSubOp>(new_max);
>     Stile.template row_reduce<SumOp>(sum_score);
>     Otile.template row_bin_op<MulOp>(factor);
> ```

This is only possible because MLX knows its own fragment layout exactly (`get_coord()`,
`steel/gemm/nax.h:45-51`) rather than treating it as implementation-defined. It is a deliberate
trade: MLX gives up MPP's layout abstraction to get an in-register online softmax it fully controls,
including the running-max rescale that `reduce_rows` cannot express in one call.

**Teach `reduce_rows` as the portable API and MLX's approach as the expert escape hatch.** If you
are writing your first TensorOps kernel, use `reduce_rows` with an explicit identity. If you are
writing FlashAttention with a streaming softmax and you know your fragment layout, roll your own.

[^metal27-multiplane]: Apple documents
    [`MTLTensorAuxiliaryPlaneDescriptor`](https://developer.apple.com/documentation/metal/mtltensorauxiliaryplanedescriptor),
    [`MTLTensorDescriptor.auxiliaryPlanes`](https://developer.apple.com/documentation/metal/mtltensordescriptor/auxiliaryplanes),
    and [`MTLTensor.auxiliaryPlanes`](https://developer.apple.com/documentation/metal/mtltensor/auxiliaryplanes)
    for configuring and accessing multiplane tensors. The repository's
    [WWDC26 session 330 transcript](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/transcripts/wwdc2026-330.txt#L27-L78) describes the
    data plane, E8M0 scale plane, and `blockFactors` relationship.
[^metal27-dtypes]: Apple's current
    [`MTLTensorDataType`](https://developer.apple.com/documentation/metal/mtltensordatatype)
    documentation lists Int2, UInt2, Float4E2M1, Float8E4M3, Float8E5M2, and Float8UE8M0. Apple's
    [Metal Feature Set Tables](https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf)
    identify the format types that support block scaling and reserve Float8UE8M0 for scale planes.
[^wwdc330-transpose-conflict]: Apple's
    [WWDC26 session 330 code listing](https://developer.apple.com/videos/play/wwdc2026/330/?time=439)
    declares scale-plane types for both operands and passes `false, false` to
    `matmul2d_descriptor`; the repository's authoritative
    [transcript](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/transcripts/wwdc2026-330.txt#L51-L68) describes the same quantized matmul
    and says setup is otherwise identical to an ordinary tensor. The compiled contract is in Xcode
    27 beta's `MPPTensorOpsMatMul2dImpl.h:6241-6303`: `!descriptor.transpose_left` for a scaled
    left tensor and `descriptor.transpose_right` for a scaled right tensor. A 2026-07-31 Metal 4.1
    probe against build `27A5228h` reproduced the published listing's static-assert failure and
    compiled the corresponding `false, true` form to AIR.

---
