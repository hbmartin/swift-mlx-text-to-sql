# Part 11 — Metal and TensorOps

**Version floor:** the original TensorOps surface is **26.x**, while multiplane quantized tensors are
**27.0**. TensorOps shipped in **26.0**; `bfloat` element types in **26.1**;
cooperative tensors as `matmul2d` **inputs** in **26.3** (the header's own gate macro says **26.2** —
both are true, and guide 11.1 §1 reconciles them); 4-bit and 8-bit integer tensor element types in
**26.4**. Xcode 27 adds int2, FP4, FP8, the E8M0 scale datatype, and `MTLTensor` auxiliary scale
planes — and the macOS 27.0 beta SDK carries the shader-side half: the `matmul2d` support matrix
gains int2b/uint2b, FP4 (e2m1) and FP8 (e4m3 *and* e5m2) operand rows, blockwise ue8m0 scale planes
land in the implementation headers, and a new deployment gate
`__TENSOR_OPS_SUPPORT_DEPLOYMENT_TARGET_27_0` appears (checked 2026-07-29; guide 11.1 §0.2,
§1.2).[^metal27-multiplane] You need **Metal 4** (`__METAL_VERSION__ ≥ 400`) and a toolchain that
defines `__HAVE_TENSOR__` — toolchain-verified 2026-07-31: `-std=metal4.0` defines it, and
`-std=metal4.1` additionally defines `__HAVE_TENSOR_MULTIPLANE__` and the FP4/FP8 format types the
27.0 scale planes need (guide 11.1 §2.2). The 26.x surface runs on **every Apple GPU from M1 onward** — Apple states
the API is portable and falls back to optimised shader implementations where there is no neural
accelerator. M5-class hardware is a fast path, not a requirement.

**Who this is for:** kernel authors. People writing `.metal` by hand — a fused GEMM, a FlashAttention
kernel, a custom dequantisation routine — either to feed [Part 8's](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/README.md)
`TorchMetalKernel` or to understand the floor that Core AI and MLX both stand on. If you are choosing
a backend rather than writing a shader, you are in the wrong part: start at
[Part 1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/README.md).

---

## ⚠️ Read this before you start, especially if you arrived from WWDC26 session 330

**This part distinguishes the older 26.x TensorOps surface from the quantized multiplane additions in
Xcode 27.** Session 330 accurately describes a single `MTLTensor` carrying quantized data plus an E8M0
scale plane whose `blockFactors` define blockwise dequantization.[^wwdc330] Xcode 27's shipped
`MTLTensor.h` provides `MTLTensorPlaneTypeScales`, `MTLTensorAuxiliaryPlaneDescriptor`, an auxiliary
plane descriptor map, and `MTLTensorDescriptor.auxiliaryPlanes`; its MPP type mapping accepts int2,
FP4, FP8, and E8M0 operands. The macOS 27.0 beta SDK's MPP headers confirm the shader-side half on
disk: `MPPTensorOpsMatMul2d.h:62-83` lists the new operand rows, and
`__impl/MPPTensorOpsMatMul2dImpl.h:6241-6316` enforces the scale-plane contract — ue8m0 only, block
size 32, left untransposed / right transposed, never on the destination (checked 2026-07-29; guide
11.1 §0.2 has the full matrix and constraints).[^metal27-multiplane]

The older cooperative-tensor technique remains useful for custom formats and deployment targets that
cannot use the 27.0 multiplane surface: dequantize inside the kernel and feed the dense cooperative
tensor to `matmul2d`. It is a fallback and customization path, not evidence that native scale planes
do not exist.

One smaller consequence of the header-first rule remains: **Apple's own doc comments are not
compiled**. Guide 11.1 §0.3 tabulates nine verified
defects in the shipping header's prose, two of which are API names — `static_slice` and `get_mask` —
**that appear nowhere outside a `//`**.

---

## Why this part exists

Three-quarters of the circulating material about this API was written from a spoken session, and it
shows. The headers are on your disk — 642 public lines of `MPPTensorOpsMatMul2d.h` with ~320 lines of
Apple prose and four worked examples, on top of an 8,963-line implementation carrying every
`static_assert` that will bite you. Nobody had read them against the narration until these guides did.

What falls out is a surface with an unusual failure profile:

1. **Two of the three gates fail silently.** `__HAVE_TENSOR__` undefined makes the entire header expand
   to nothing — no `#error`, just `no member named 'matmul2d'` hundreds of lines later, which reads
   like a typo. A deployment target below 26.2 makes MLX's whole accelerated kernel set vanish from the
   build with a CMake warning and a working, slower library.
2. **The defaults are traps.** `matmul2d_descriptor`'s seventh argument defaults to `mode::multiply`,
   and `reduce_rows`' identity defaults to `sum_identity` — **zero** — *regardless of the operation you
   pass*. Both produce plausible, wrongly-scaled numbers rather than errors.
3. **The two halves live in two places.** `mpp::tensor_ops::` ships in the SDK framework;
   `metal::tensor` / `metal::cooperative_tensor` ship in a cryptex-mounted Metal toolchain that is not
   inside `Xcode.app` at all. Looking in `Toolchains/` and finding nothing is the single most common
   reason a developer concludes cooperative tensors are missing from their SDK.
4. **The payoff justifies the pain.** Apple-published, one 4K×4K matmul on M5-class hardware: a
   hand-written `simdgroup_matrix` kernel takes *"over two seconds"* at **0% neural accelerator
   utilisation**; the same maths in TensorOps, *"over just a half second"*; with Morton-ordered
   traversal, *"around a third of a second."* Roughly **7×**, matrix hardware idle to near-saturated.

---

## Read this first: the triage table

| If your situation is… | Read | Why |
|---|---|---|
| "Session 330 promised me scale planes / MX / E8M0" | [11.1 §0.2](references/01-tensorops-and-quantized-operands.md#02-quantized-multiplane-tensors-26x-fallback-and-xcode-27-native-surface) · [11.2 §0.3](references/02-cooperative-tensors-and-flash-attention.md#03-the-26x-fallback-and-xcode-27-multiplane-path) | Use Xcode 27's multiplane `MTLTensor` API; hand-dequantize only for older targets or custom formats |
| "I read TensorOps is iOS 27 / macOS 27" | [11.1 §1](references/01-tensorops-and-quantized-operands.md#1-the-version-story-two-ladders-both-true) | The core surface is 26.x; only the newer tensor formats (multiplane, int2/FP4/FP8/E8M0) are 27.0. §1.5 is the deployment-target cheat sheet |
| `no member named 'matmul2d' in namespace 'mpp::tensor_ops'` | [11.1 §2.2](references/01-tensorops-and-quantized-operands.md#22-the-two-guards-that-make-the-whole-thing-vanish) · [11.2 §0.2](references/02-cooperative-tensors-and-flash-attention.md#02-the-version-ladder-and-the-262-annotation) | `__HAVE_TENSOR__` is undefined and the header expanded to nothing |
| "I can't find `metal_cooperative_tensor` anywhere in Xcode" | [11.2 §0.1](references/02-cooperative-tensors-and-flash-attention.md#01-the-two-header-roots) | It is in the cryptex Metal toolchain. `xcrun -sdk macosx --find metal`; never hardcode the path |
| `static_slice` / `get_mask` won't compile | [11.1 §5.4, §6.4](references/01-tensorops-and-quantized-operands.md#54-️-static_slice-does-not-exist--the-real-spelling-is-templated-slice) | Neither exists (`static_slice` toolchain-verified absent, 2026-07-31). Real spellings: templated `slice<…>()` and `is_valid_element` |
| Compile error deep inside `__mutmul2d_detail` | [11.2 §3](references/02-cooperative-tensors-and-flash-attention.md#3--the-asymmetry-element-types-vs-operand-types) · [11.1 §6.3](references/01-tensorops-and-quantized-operands.md#63-the-three-getters--and-the-asymmetry-that-is-the-1-compile-failure) | The input getters take **element** types; the destination getter takes **operand** types |
| "My K loop returns only the last chunk" | [11.1 §3.5](references/01-tensorops-and-quantized-operands.md#35-️-the-default-mode-is-multiply-and-the-semantics-are-not-fully-settled) · [11.2 §5.5](references/02-cooperative-tensors-and-flash-attention.md#55-️-cooperative-tensors-are-not-zero-initialised) | Descriptor mode defaults to `multiply`. Zero the destination, pass the mode explicitly |
| "Attention quality dropped and I can't find a bug" | [11.2 §6.3](references/02-cooperative-tensors-and-flash-attention.md#63-️-silent-failure--the-identity-default) · [11.1 §7.2](references/01-tensorops-and-quantized-operands.md#72-️-silent-failure-the-identity-default-is-sum_identity-regardless-of-the-operation) | `reduce_rows(…, max)` with three arguments computes `max(0, row)` |
| "Right shape, transposed or scrambled content" | [11.1 §3.4](references/01-tensorops-and-quantized-operands.md#34-the-x-y-versus-m-n-transposition) | `slice()` is `(dim0, dim1)`; the descriptor is `(m, n)`. They are opposite |
| "I want to write a fused attention kernel" | [11.2 §8–§9](references/02-cooperative-tensors-and-flash-attention.md#8--building-flashattention-step-by-step) | The six steps, then the assembled listing — and §8.7 for what the six steps omit |
| "Correct, but the profiler shows 0% accelerator" | [11.2 §14](references/02-cooperative-tensors-and-flash-attention.md#14--performance-the-three-things-that-actually-move-the-number) | You are on the fallback shader path, or SIMD groups have drifted across K |
| "Wrong numbers from MLX on one tile shape" | [11.2 §13.2](references/02-cooperative-tensors-and-flash-attention.md#132-the-one-to-know-about) | `tile_matmad_nax` has no `else`; some shapes compile to nothing (upstream PR #3924) |
| "How does this kernel get into a Core AI model?" | [11.2 §12](references/02-cooperative-tensors-and-flash-attention.md#12--getting-the-kernel-into-a-model) → [Part 8 guide 3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md) | `TorchMetalKernel`'s `src` is the **body only**; your includes go in `helper_src` |

---

## The guides in this part

### [11.1 — TensorOps: `matmul2d`, tensor types, and what quantization actually looks like](references/01-tensorops-and-quantized-operands.md)

The ground floor, written header-first: the two namespaces and where each physically lives, the seven
positional arguments of `matmul2d_descriptor`, the complete execution-scope vocabulary, the three
tensor construction tags, cooperative tensors, and reductions. It is also where the session-330
correction is established and where the version story is untangled — Apple's narrated ladder
(26.0/26.1/26.3/26.4) versus the shipped `__TENSOR_OPS_SUPPORT_DEPLOYMENT_TARGET_26_2` macro, which
§1.2 shows is not an on/off switch but the ABI split between a destination-only and a general-operand
cooperative-tensor form. Two structural corrections you will not find elsewhere: `tensor_offset` is a
**Tag**, not a Descriptor (§5.2), and `metal::execution_threadgroup` **does not exist** (§4.3) — for
"all the threads in my threadgroup" you write `execution_simdgroups<N>`, and a dispatch that does not
match is documented **undefined behaviour**, not an error.

> ⚠️ **SILENT FAILURE — masked elements (§6.4).** Not every slot in a cooperative tensor is live.
> `ct.set(i, v)` on a masked element **does nothing**; `ct.get(i)` **returns zero**. The safe-looking
> API is the dangerous one: a vanished write is indistinguishable from a correct write, and a masked
> read of 0.0 is the right identity for `sum` and the wrong one for `max`. Guard with
> `is_valid_element(i)` — **not** `get_mask(i)`, which a `grep` over the whole Metal toolchain shows
> does not exist despite appearing twice in Apple's own example comment.
>
> ⚠️ **SILENT FAILURE — the reduction identity (§7.2).** `reduce_rows`' `identity` parameter defaults
> to `sum_identity`, i.e. **0**, whatever `reduction_operation` you pass. `reduce_rows(S, m, max)`
> computes `max(0, row)` and clamps every negative row maximum to zero. Rule: never call `reduce_rows`
> or `reduce_columns` with three arguments.
>
> 🔴 **GAP — the semantics of `mode::multiply` (§3.5).** The enum names and one numerically-validated
> community implementation say *overwrite*; the header's own opening line (*"C = A\*B + C"*) and one of
> its examples imply *accumulate*. The real behaviour lives in `extern "C" EXTERNALLY_DEFINED_ATTR`
> entry points implemented in the driver, so static analysis cannot settle it. The safe default costs
> nothing: always pass the seventh argument, always zero the destination, always use
> `multiply_accumulate` in a K loop.

**Scope note.** This guide intentionally runs §0–§7 and covers the descriptor, execution scopes,
tensor construction, cooperative tensors, reductions, and the 26.x-versus-27.0 quantization split.
Guide 11.2 carries the complete fused-attention kernel, M5 gating, performance material, and Core AI
handoff. The obsolete §8–§18 promises have been removed from guide 11.1's contents.

### [11.2 — Cooperative tensors, reductions, and building a fused attention kernel](references/02-cooperative-tensors-and-flash-attention.md)

The advanced guide, and the longer of the two. It starts from *why* cooperative tensors exist — a
`64×256` float32 score tile is 64 KB of intermediate that exists only to be consumed, and the only
place to keep it that is neither device nor threadgroup memory is the participating threads' registers
— then walks session 330's six FlashAttention steps in order, assembles them into a full kernel (§9),
and closes with the host side, the MLX counter-example, the `TorchMetalKernel` hand-off, a freshness
warning and Apple's published performance guidance. §9.1's symptom→suspect table is the fastest way in
when a kernel you already wrote produces wrong numbers.

> ⚠️ **SILENT FAILURE — the deployment-target trap (§0.2).** A default macOS build often targets
> below 26.2. When it does, MLX emits a **CMake warning** and drops every accelerated kernel from the
> build. Nothing fails; the library is simply slower on a code path you never chose. Two upstream PRs
> (#3622, #3824) exist because people hit this.
>
> ⚠️ **SILENT FAILURE — uninitialised cooperative tensors (§5.5), and mismatched dispatch (§10.1).**
> Cooperative tensors are not zero-initialised, and uninitialised GPU register storage frequently reads
> as zero on a fresh pipeline and as garbage on the second launch — it works, you ship it, it fails for
> a user. Separately, `execution_simdgroups<N>` requires exactly `threadExecutionWidth * N` threads per
> threadgroup; the mismatch is UB with no Metal validation check and no runtime assertion, because it
> is a compile-time template parameter on one side of the process boundary and a runtime `MTLSize` on
> the other.
>
> ⚠️ **Before you paste any code from §5, §6.3's defensive form, or §9: substitute
> `is_valid_element(i)` for `get_mask(i)`.** This guide uses `get_mask` throughout, following Apple's
> header comment, and files a 🔴 GAP at §5.2 saying its signature was not located and that grepping
> `<metal_cooperative_tensor>` would resolve it. **Guide 11.1 §6.4 ran that grep: zero hits.** The two
> guides disagree and 11.1 has the stronger evidence. Everything else about the idiom — per-thread
> `get_capacity()` as the loop bound, the mandatory `#pragma unroll full` — is unaffected.
>
> 🔴 **GAP — the layout-compatibility question you cannot answer statically (§4.3).**
> `is_compatible_as_left_input` returns a **runtime `bool`**, not a `constexpr` one, and the guide
> could not verify what happens if you convert without checking — trap, garbage, or a defensive
> predicate that always returns true. Always branch; the documented fallback is a store/reload through
> threadgroup memory, after which *"the call to `op.run` is the same."* Also open: `get_mask` and
> `load`/`store` signatures, the return type of `get_multidimensional_index`, the meaning of MLX's
> GPU architecture strings, and the **MPP Programming Guide PDF** — referenced four times by Tech Talk
> 111432 as the source for tile sizes, barrier frequency and traversal order, and read by nobody in
> this project.
>
> ⚠️ **Nothing in this part was compiled or executed.** §9's kernel is explicitly 🟡 RECONSTRUCTED
> assembly over verified identifiers, no M5-class hardware was available, and §13 documents that four
> NAX correctness fixes landed or opened upstream in the three days before the guide was written.
> Treat §9 as a skeleton to type against with the headers open, and validate against a CPU reference.

**Scope note.** This guide runs §0–§14; gaps and validation checks are declared inline in the sections
they qualify. Obsolete contents entries for unwritten standalone gap/checklist sections were removed.

---

## Reading order

**Read [11.1](references/01-tensorops-and-quantized-operands.md) §0–§4 first, in order, whoever you
are.** §0 is the bibliography that tells you which claims to trust; §1 stops you putting the wrong
number in your build settings; §2 stops the two most common first compile errors; §3 and §4 are the
descriptor and the scope, which every later line assumes. That is roughly an hour and it is not
optional.

**Then branch.** *Writing a plain GEMM or a fused epilogue:* finish 11.1 (§5 tensors, §6 cooperative
tensors, §7 reductions) and stop — you need nothing in 11.2 except §10.1's dispatch rule and §14's
performance guidance. *Writing FlashAttention or anything with an in-register softmax:* read
[11.2](references/02-cooperative-tensors-and-flash-attention.md) §1–§7 next for the element/operand
asymmetry, the compatibility predicates and `map_iterator`, then §8 and §9 together; §8.7 (the online
softmax rescale across key blocks) is the part session 330's six steps leave out and the part a real
kernel actually needs.

**Read one thing out of order:** [11.1 §4.6](references/01-tensorops-and-quantized-operands.md#46-mlx-picks-the-other-strategy--and-there-is-a-header-level-reason). A
single `static_assert` — *"Input cooperative tensors require a single SIMD group"* — means cooperative
tensors as matmul **inputs** are legal only under `execution_simdgroup`, which explains MLX's entire
architecture and constrains your decomposition before you write a line. The paired constraint in
[11.1 §6.6](references/01-tensorops-and-quantized-operands.md#66-the-conversion-overloads--the-fusion-primitive-and-its-five-hard-constraints) belongs with it: `k = dynamic_extent`
and cooperative-tensor inputs are **mutually exclusive**, so fusion means you own the K loop.

**Deferrable.** [11.2 §11](references/02-cooperative-tensors-and-flash-attention.md#11--the-expert-escape-hatch-what-mlx-does-instead) (what MLX does
instead) is an expert escape hatch, not a starting point — its whole contact surface with TensorOps is
twelve tokens in four sites, and it declines nearly every portable API these guides teach. §12
(`TorchMetalKernel`) waits until your kernel is correct; §13 (freshness) and §14.4 (Morton order) are
read-before-shipping, not read-before-writing.

---

## What this part deliberately does not cover

- **`convolution2d`.** `MPPTensorOpsConvolution2d.h` (177 public lines, 4,914 of implementation) ships
  in the same framework. MLX does not use it and neither guide read it. Declared, not omitted silently.
- **Host-side Metal 4.** `MTLTensorDescriptor`, `newTensorWithDescriptor:`, residency sets and
  `MTL4MachineLearningCommandEncoder`. 11.2 §10 covers only the one host fact that will corrupt your
  kernel — threads-per-threadgroup versus execution scope — plus the stride-alignment rule (64 bytes
  for ML usage, 128 for sub-byte dtypes) that 11.1 §2.3 quotes from `MTLTensor.h`.
- **Registering a Metal kernel with a converted model.**
  [Part 8, guide 3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md) is the
  full `TorchMetalKernel` treatment; 11.2 §12 is only the hand-off and the one constraint it puts on
  how you write the shader.
- **Quantisation as a model-level decision** — `coreai-opt`, palettisation, `QuantizationSpec`, and
  whether your 4-bit export is any good: [Part 9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md). This part
  answers only what the *shading language* can and cannot represent.
- **MLX's user-facing API** — `mx.quantize`, `QuantizedLinear`, the `mode=` argument:
  [Part 12](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/README.md) and [Part 13](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/README.md). These guides read MLX's
  kernels as evidence, not its API as a product.
- **The Swift runtime that consumes what you build** — `AIModel`, specialization, states:
  [Part 7](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/README.md). **ANE-versus-GPU authoring rules and the Metal debugger
  in depth:** [Part 10](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-10-coreai-hardware-authoring-debugging/README.md).

---

## Sources for this part

Strongest first, and the ordering is the whole point of this part. **Apple's shipped headers and
current API reference:** the `MetalPerformancePrimitives.framework` headers read from Xcode 26.6 —
`MPPTensorOpsMatMul2d.h`, the three `__impl/` support headers, and the
8,963-line `MPPTensorOpsMatMul2dImpl.h` whose `static_assert`s supply several claims that appear in no
transcript — plus the same framework's **macOS 27.0 beta SDK** headers (Xcode 27 beta, read
2026-07-29; `MPPTensorOpsMatMul2dImpl.h` grows to 16,754 lines there), which supply the 27.0
quantized-format and scale-plane facts — plus the Metal *language* headers from the cryptex
toolchain (`metal_tensor`, `metal_cooperative_tensor`, `metal_packed_numeric`, `__exec/units.h`), and
`Metal.framework/Headers/MTLTensor.h` for the 26.x host surface — plus Apple's Xcode 27 API pages
for host-side dtype and auxiliary-plane availability.[^metal27-multiplane]
**MLX's shipping
kernels** in `ml-explore/mlx` — `steel/gemm/nax.h`, `steel/attn/kernels/steel_attention_nax.h`,
`backend/metal/device.cpp`, the kernels `CMakeLists.txt`, and the NAX pull-request record through
2026-07-27 — as a real, compiling, Apple-authored call site, and as the counter-implementation that
settles the quantisation question. **Apple narration**, useful for intent and weak for spelling: Tech
Talk 111432 *"Accelerate your machine learning workloads with the M5 and A19 GPUs"* (the source of
every performance figure here, all Apple-published, all from one unspecified machine) and WWDC26
session 330 *"Optimize custom machine learning operations with Metal tensors"*, whose sample code was
not obtained. **Community sources**, labelled as such at every point of use:
`john-rocky/coreai-model-zoo`'s TensorOps prototypes and agent notes, for the axis-reversal probe, the
block-scaled int4 accumulation that tie-breaks `mode::multiply`, and the naked-`exp()` warning. **The
MPP Programming Guide PDF has not been read**, and it is where Apple says the tile-size,
barrier-frequency and traversal-order numbers live.

[^metal27-multiplane]: Apple, [`MTLTensorAuxiliaryPlaneDescriptor`](https://developer.apple.com/documentation/metal/mtltensorauxiliaryplanedescriptor),
    [`MTLTensor.auxiliaryPlanes`](https://developer.apple.com/documentation/metal/mtltensor/auxiliaryplanes),
    and [`MTLTensorDataType`](https://developer.apple.com/documentation/metal/mtltensordatatype?language=objc)
    (Xcode 27 additions for scale planes and sub-byte/FP8 formats).
[^wwdc330]: Apple, [WWDC26 session 330 transcript](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/transcripts/wwdc2026-330.txt#L27-L78),
    describing E8M0 block scales, `blockFactors`, auxiliary planes, and automatic dequantization.
