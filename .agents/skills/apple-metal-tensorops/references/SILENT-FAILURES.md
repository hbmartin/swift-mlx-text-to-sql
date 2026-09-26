# Silent-failure index — Metal TensorOps and Performance Primitives for ML kernels

**42 ⚠️ callouts from the guide parts this skill covers, sorted by the symptom you would observe.** Most defects in this stack do not throw, so the symptom is what you start from.

> Sliced from the series index on 2026-09-22. The full index across all 17 parts is at https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/SILENT-FAILURES.md. Generated — regenerate with `./scripts/build-skills.sh` rather than editing by hand.

| Symptom | Entries |
|---|---:|
| [Wrong output](#wrong-output) | 20 |
| [Performance cliffs](#performance-cliffs) | 2 |
| [Version drift](#version-drift) | 2 |
| [Docs vs reality](#docs-vs-reality) | 5 |
| [API footguns](#api-footguns) | 5 |
| [General cautions](#general-cautions) | 8 |

## Wrong output

**Part 11**

- [set() on a masked cooperative-tensor element does nothing and get() returns 0 - the wrong identity for max reductions.](part-11-metal-and-tensorops/README.md#111--tensorops-matmul2d-tensor-types-and-what-quantization-actually-looks-like) — 11.README 🔇
- [A K loop left in the default multiply mode overwrites instead of accumulating, keeping only the last tile's product.](part-11-metal-and-tensorops/references/01-tensorops-and-quantized-operands.md#35-️-the-default-mode-is-multiply-and-the-semantics-are-not-fully-settled) — 11.1
- [execution_simdgroups<N>, simdGroupsPerTG and descriptor (m,n) must agree; mismatch corrupts tiles like a numerics bug.](part-11-metal-and-tensorops/references/01-tensorops-and-quantized-operands.md#45-matching-the-host-dispatch) — 11.1
- [Masked-element set/get silently no-op or return zero, and a widely cited guard method name does not exist.](part-11-metal-and-tensorops/references/01-tensorops-and-quantized-operands.md#64-️-silent-failure-masked-elements-and-the-method-name-that-does-not-exist) — 11.1
- [Verified: set() on a masked element is a no-op and get() returns zero; operator[] is entirely unchecked.](part-11-metal-and-tensorops/references/01-tensorops-and-quantized-operands.md#64-️-silent-failure-masked-elements-and-the-method-name-that-does-not-exist) — 11.1 🔇
- [reduce_rows' identity defaults to sum_identity (zero) regardless of the operation you pass.](part-11-metal-and-tensorops/references/01-tensorops-and-quantized-operands.md#72-️-silent-failure-the-identity-default-is-sum_identity-regardless-of-the-operation) — 11.1
- [Naked exp() in a hand-written softmax overflows above ~88 fp32 / ~11 fp16; subtract the running max first.](part-11-metal-and-tensorops/references/01-tensorops-and-quantized-operands.md#73-map_iterator-and-is_iterator_compatible) — 11.1
- [The guide's central trap: the default reduction identity silently clamps every negative row max to zero.](part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#what-this-covers) — 11.2
- [TOC: cooperative tensors are not zero-initialised; they hold undefined register data.](part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#contents) — 11.2
- [TOC: the reduce_rows identity default silently computes max(0,row).](part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#contents) — 11.2
- [Skip the is_compatible_as_left_input check and an incompatible layout converts undiagnosed - wrong data, no error.](part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#43-is_compatible_as_left_input--a-runtime-bool-you-must-branch-on) — 11.2 🔇
- [Cooperative tensors are not zero-initialised; accumulate into one unwritten and you add register garbage.](part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#55-️-cooperative-tensors-are-not-zero-initialised) — 11.2
- [Uninitialised cooperative tensors often read 0 on a fresh pipeline and garbage on the next launch; it ships, then fails.](part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#55-️-cooperative-tensors-are-not-zero-initialised) — 11.2 🔇
- [The reduce_rows identity default is zero for every operation, including max.](part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#63-️-silent-failure--the-identity-default) — 11.2
- [reduce_rows(S,rowMax,max) compiles and computes max(0,row); every all-negative row silently becomes zero.](part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#63-️-silent-failure--the-identity-default) — 11.2 🔇
- [The per-simdgroup if must not make run() non-uniform; divergent execution of the op is undefined behaviour.](part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#82-step-2--slice-input-tiles-by-simdgroup-id) — 11.2
- [Code comment: reduce_rows takes four arguments here - the identity is not optional in practice.](part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#84-step-4--the-row-max-reduction) — 11.2
- [The three-argument reduce_rows in flash attention computes max(0,row); attention logits are frequently all-negative.](part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#84-step-4--the-row-max-reduction) — 11.2 🔇
- [Code comment: four arguments; three would silently compute max(0,row).](part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#9--the-assembled-kernel) — 11.2
- [Dispatch fewer threads than the execution scope declares and the op reads non-participating lanes; no validation exists.](part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#101-threads-per-threadgroup-must-match-your-execution-scope) — 11.2 🔇

## Performance cliffs

**Part 11**

- [A macOS deployment target below 26.2 makes MLX drop every accelerated kernel behind only a CMake warning.](part-11-metal-and-tensorops/README.md#112--cooperative-tensors-reductions-and-building-a-fused-attention-kernel) — 11.README 🔇
- [Default macOS builds target below 26.2, so MLX drops all NAX kernels with just a CMake warning (PRs #3622, #3824).](part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#02-the-version-ladder-and-the-262-annotation) — 11.2 🔇

## Version drift

**Part 11**

- [MLX hardcodes an undocumented fragment linearisation (kElemsPerFrag); a toolchain change could silently break it.](part-11-metal-and-tensorops/references/01-tensorops-and-quantized-operands.md#67-mlxs-cooperative-tensor-usage-annotated) — 11.1
- [coreai.authoring Metal-kernel APIs are experimental and subject to change; pin your coreai-torch version.](part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#123-the-kernel-ships-inside-the-asset) — 11.2

## Docs vs reality

**Part 11**

- [Circulating material calls tensor_offset a descriptor; in the header it is a Tag.](part-11-metal-and-tensorops/references/01-tensorops-and-quantized-operands.md#52-️-correction-tensor_offset-is-a-tag-not-a-descriptor) — 11.1
- [static_slice does not exist in the SDK; the real spelling is a templated slice.](part-11-metal-and-tensorops/references/01-tensorops-and-quantized-operands.md#54-️-static_slice-does-not-exist--the-real-spelling-is-templated-slice) — 11.1
- [The shipping header's example loop writes a comma where a semicolon belongs; pasted verbatim it will not compile.](part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#52-get_capacity--get_mask-the-idiomatic-loop) — 11.2
- [Apple's map_iterator example passes the tensor where an iterator is required and drops a semicolon; do not paste it.](part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#74-is_iterator_compatible-and-apples-buggy-example) — 11.2
- [execution_threadgroup does not exist; the header admits only execution_threads<1> and execution_simdgroups<N>.](part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#81-step-1--a-custom-simdgroup-mapping) — 11.2

## API footguns

**Part 11**

- [matmul_mode defaults to mode::multiply, not accumulate - see the 3.5 K-loop trap.](part-11-metal-and-tensorops/references/01-tensorops-and-quantized-operands.md#32-the-argument-list--memorise-this-order) — 11.1
- [matmul2d's default mode is multiply and its exact semantics are not fully settled in the docs.](part-11-metal-and-tensorops/references/01-tensorops-and-quantized-operands.md#35-️-the-default-mode-is-multiply-and-the-semantics-are-not-fully-settled) — 11.1
- [get_destination_cooperative_tensor has a single no-argument overload; no predicate, no conversion, unlike inputs.](part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#33-wrong-and-why-the-compiler-will-not-help-you) — 11.2
- [slice(a,b) takes (column,row) while matmul2d_descriptor takes (rows,columns); mixed conventions slice the wrong tiles.](part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#82-step-2--slice-input-tiles-by-simdgroup-id) — 11.2
- [Custom-kernel src is the body only; includes, using-declarations and descriptor constexprs must go in helper_src.](part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#121-the-kernel-body-becomes-a-python-string) — 11.2

## General cautions

**Part 11**

- [Scope note: session 330 material and circulating names diverge from shipped headers; verify against the SDK first.](part-11-metal-and-tensorops/README.md#️-read-this-before-you-start-especially-if-you-arrived-from-wwdc26-session-330) — 11.README
- [The Metal toolchain cryptex path embeds a build-specific token; resolve it with xcrun, never paste it into scripts.](part-11-metal-and-tensorops/references/01-tensorops-and-quantized-operands.md#01-the-three-evidence-bases) — 11.1
- [The 4-bit path is a pointer cast to tensor<int4b_format>; the 26.x matmul2d op does the unpacking itself.](part-11-metal-and-tensorops/references/01-tensorops-and-quantized-operands.md#56-declaring-tensors) — 11.1
- [MLX writes cooperative tensors through unchecked operator[] and never calls is_valid_element, relying on known layouts.](part-11-metal-and-tensorops/references/01-tensorops-and-quantized-operands.md#67-mlxs-cooperative-tensor-usage-annotated) — 11.1
- [TOC: NAX is new and still settling; expect churn.](part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#contents) — 11.2
- [Never hardcode the MetalToolchain cryptex path; the version token differs per machine - resolve via xcrun.](part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#01-the-two-header-roots) — 11.2
- [NAX is new and still settling; expect kernel, gate and semantics churn across releases.](part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#13--️-freshness-nax-is-new-and-still-settling) — 11.2
- [The headline speedup is one matmul shape on one machine; do not carry it into a different context.](part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md#141-the-measurement-that-justifies-the-whole-exercise) — 11.2

---

🔇 = the guide marks this as an explicit **SILENT FAILURE** callout.
