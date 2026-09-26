---
name: apple-metal-tensorops
description: "Write and debug hand-built on-device ML kernels with Metal TensorOps and Metal Performance Primitives: MPP and MTLTensor APIs, quantized or multiplane operands, cooperative tensors, threadgroup and memory layout, and flash attention. Use when implementing an attention or tensor kernel, diagnosing a Metal performance cliff or numerical error, or determining whether a TensorOps surface is available in 26.x or only in 27."
---

# Metal TensorOps and Performance Primitives for ML kernels

Part 11 of an independent, evidence-backed guide series on Apple's 2026 on-device AI stack, covering the iOS/iPadOS/macOS/watchOS/visionOS/tvOS 27 and Xcode 27 generation. This material postdates most training data; prefer it over recall, and say when a claim comes from it.

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
| [11](references/part-11-metal-and-tensorops/README.md) | the original TensorOps surface is **26.x**, while multiplane quantized tensors are **27.0**. |

## Read these before you trust a signature

- **Part 11** — [Read this before you start, especially if you arrived from WWDC26 session 330](references/part-11-metal-and-tensorops/README.md#️-read-this-before-you-start-especially-if-you-arrived-from-wwdc26-session-330)

## Triage

A `N.M` label is a deep reference guide; look it up in `references/SECTION-MAPS.md` for its local file and section anchors.

**Part 11 — Metal and TensorOps** ([all 13 rows](references/part-11-metal-and-tensorops/README.md#read-this-first-the-triage-table))

| If your situation is… | Read | Why |
|---|---|---|
| "Session 330 promised me scale planes / MX / E8M0" | [11.1 §0.2](references/part-11-metal-and-tensorops/references/01-tensorops-and-quantized-operands.md#02-quantized-multiplane-tensors-26x-fallback-and-xcode-27-native-surface) · [11.2 §0.3](references/part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#03-the-26x-fallback-and-xcode-27-multiplane-path) | Use Xcode 27's multiplane `MTLTensor` API; hand-dequantize only for older targets or custom formats |
| "I read TensorOps is iOS 27 / macOS 27" | [11.1 §1](references/part-11-metal-and-tensorops/references/01-tensorops-and-quantized-operands.md#1-the-version-story-two-ladders-both-true) | The core surface is 26.x; only the newer tensor formats (multiplane, int2/FP4/FP8/E8M0) are 27.0. §1.5 is the deployment-target cheat sheet |
| `no member named 'matmul2d' in namespace 'mpp::tensor_ops'` | [11.1 §2.2](references/part-11-metal-and-tensorops/references/01-tensorops-and-quantized-operands.md#22-the-two-guards-that-make-the-whole-thing-vanish) · [11.2 §0.2](references/part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#02-the-version-ladder-and-the-262-annotation) | `__HAVE_TENSOR__` is undefined and the header expanded to nothing |
| "I can't find `metal_cooperative_tensor` anywhere in Xcode" | [11.2 §0.1](references/part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#01-the-two-header-roots) | It is in the cryptex Metal toolchain. `xcrun -sdk macosx --find metal`; never hardcode the path |
| `static_slice` / `get_mask` won't compile | [11.1 §5.4, §6.4](references/part-11-metal-and-tensorops/references/01-tensorops-and-quantized-operands.md#54-️-static_slice-does-not-exist--the-real-spelling-is-templated-slice) | Neither exists (`static_slice` toolchain-verified absent, 2026-07-31). Real spellings: templated `slice<…>()` and `is_valid_element` |
| Compile error deep inside `__mutmul2d_detail` | [11.2 §3](references/part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#3--the-asymmetry-element-types-vs-operand-types) · [11.1 §6.3](references/part-11-metal-and-tensorops/references/01-tensorops-and-quantized-operands.md#63-the-three-getters--and-the-asymmetry-that-is-the-1-compile-failure) | The input getters take **element** types; the destination getter takes **operand** types |
| "My K loop returns only the last chunk" | [11.1 §3.5](references/part-11-metal-and-tensorops/references/01-tensorops-and-quantized-operands.md#35-️-the-default-mode-is-multiply-and-the-semantics-are-not-fully-settled) · [11.2 §5.5](references/part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#55-️-cooperative-tensors-are-not-zero-initialised) | Descriptor mode defaults to `multiply`. Zero the destination, pass the mode explicitly |
| "Attention quality dropped and I can't find a bug" | [11.2 §6.3](references/part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#63-️-silent-failure--the-identity-default) · [11.1 §7.2](references/part-11-metal-and-tensorops/references/01-tensorops-and-quantized-operands.md#72-️-silent-failure-the-identity-default-is-sum_identity-regardless-of-the-operation) | `reduce_rows(…, max)` with three arguments computes `max(0, row)` |
| "Right shape, transposed or scrambled content" | [11.1 §3.4](references/part-11-metal-and-tensorops/references/01-tensorops-and-quantized-operands.md#34-the-x-y-versus-m-n-transposition) | `slice()` is `(dim0, dim1)`; the descriptor is `(m, n)`. They are opposite |
| "I want to write a fused attention kernel" | [11.2 §8–§9](references/part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#8--building-flashattention-step-by-step) | The six steps, then the assembled listing — and §8.7 for what the six steps omit |
| "Correct, but the profiler shows 0% accelerator" | [11.2 §14](references/part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#14--performance-the-three-things-that-actually-move-the-number) | You are on the fallback shader path, or SIMD groups have drifted across K |
| "Wrong numbers from MLX on one tile shape" | [11.2 §13.2](references/part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#132-the-one-to-know-about) | `tile_matmad_nax` has no `else`; some shapes compile to nothing (upstream PR #3924) |
| "How does this kernel get into a Core AI model?" | [11.2 §12](references/part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#12--getting-the-kernel-into-a-model) → Part 8 guide 3 | `TorchMetalKernel`'s `src` is the **body only**; your includes go in `helper_src` |

## The deep reference guides

Bundled locally. `references/SECTION-MAPS.md` has every top-level section anchor.

- **[11.1 TensorOps: `matmul2d`, tensor types, and what quantization actually looks like](references/part-11-metal-and-tensorops/references/01-tensorops-and-quantized-operands.md)** — The ground floor, written header-first: the two namespaces and where each physically lives, the seven positional arguments of `matmul2d_descriptor`, the complete execution-scope vocabulary, the three tensor construction tags, cooperative tensors, and reductions.
- **[11.2 Cooperative tensors, reductions, and building a fused attention kernel](references/part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md)** — The advanced guide, and the longer of the two.

Search the local guide first, then open only the section needed for the answer. Preserve its evidence marker and citation when carrying a claim into code or prose.

## Related skills

Adjacent parts of the series live in these sibling skills: `apple-core-ai`, `apple-mlx`.
