# Part 8 — Core AI: converting a model from PyTorch

**Version floor:** `coreai-torch` **0.4.1** (2026-07-06), which pins `coreai-core==1.0.0b2` *exactly*,
requires **Python ≥ 3.11** and **torch ≥ 2.8.0** (validated to **2.13.0**; above that, a `UserWarning` and
you are on your own). `coreai-core==1.0.0b2` publishes cp311/cp312/cp313 wheels for **macOS arm64** and
**Linux x86_64** (`manylinux_2_34_x86_64`), but **not Linux arm64**; arm64 hosts therefore use a
`--platform linux/amd64` container when they need the Linux wheel.
The `.aimodel` you produce runs on **iOS / iPadOS / macOS / tvOS / visionOS / watchOS 27.0+ only**, built
with **Xcode 27**; nothing back-deploys to 26.x, because the Core AI framework does not exist there. One hard
gate before anything else: **assets converted with `coreai-torch` v0.4.0 fail to load or specialize on device
from OS 27 beta 2 onward.**

**Who this is for:** Python ML engineers turning a `torch.nn.Module` into an `.aimodel`. The Swift side of
every contract you define here — `AIModel`, `InferenceFunction.run`, state binding — is
[Part 7](../part-07-coreai-swift-runtime/README.md).

> ⚠️ **Core AI ships with zero Apple sample-code projects.** Verified: **0 `sampleCode` entries across all
> 312 indexed Core AI symbols**, and `/documentation/updates/coreai` returns 404. Unlike Parts 1–6, there is
> no first-party compiling reference project to check a signature against. These guides rest instead on, in
> order: **shipped repo source read off disk** (`apple/coreai-torch` at HEAD `4529671`, `apple/coreai-models`,
> `apple/coreai-optimization`), **Apple's own agent skills** vendored in `coreai-models/skills/`, the package
> docs and notebooks, Apple-staff answers on the repos' issue trackers, and WWDC26 sessions 325 and 330. That
> is unusually good for the Python surface, which is open-source — but **`coreai-core` ships as a wheel, not
> as source**, so everything behind `coreai.authoring` / `coreai._compiler` is inferred from call sites and
> tests, and signatures here are **more often 🟡 RECONSTRUCTED than in Parts 1–6**. Each one says which it is.

---

## Why this part exists

Apple's own README makes conversion look like five lines — `torch.export.export`, `run_decompositions`,
`TorchConverter().add_exported_program`, `to_coreai()`, `optimize()`, then `save_asset`. Those lines are
strictly sequential, each has a failure mode, and **three of them fail silently**: they produce an artifact
that loads, runs, returns tensors of the right shape, and is wrong or slow. That ratio is why this part is
three long guides rather than a quickstart. Four things underpin it:

1. **The dominant failure class produces no diagnostic.** The issue corpus across `apple/coreai-torch`,
   `apple/coreai-optimization` and `apple/coreai-models` contains **seventeen distinct defects that yield
   plausible output with the correct shape and no error**, four of them live in the version `pip` gives you
   today. A conversion that "worked" is not evidence of anything until a numerics gate says so.
2. **Names are the API, and nothing checks them.** `input_names` / `output_names` / `state_names` /
   `entrypoint_name` are the dictionary keys your Swift caller types, across a language boundary with no
   compile-time check. Omit them and you inherit FX placeholder names — which Apple's own docs say are
   *"observed behavior from the FX graph, not a stable contract from PyTorch."*
3. **Entrypoint names are routing policy in Apple’s optional `coreai-models` helper, not a Core AI
   framework contract.** That package’s `PreparedModel` classifies an asset by its *function names* and
   supplies a corresponding compute-unit preference. If—and only if—you load through that helper, naming a
   segmenter’s functions anything but `image_encode` / `text_encode` / `detect` selects its dynamic/GPU
   policy. A direct `AIModel` load uses your `SpecializationOptions`; `.default` lets Core AI choose the
   CPU/GPU/Neural Engine combination that minimizes latency.[^sample-routing-policy]
4. **Coverage is per-overload, not per-op** — a rule Apple states once, in a subordinate clause in a "how to
   read this page" preamble. The error says *unsupported*, the doc says *supported*, both are telling the
   truth about different things.

Underneath all four sits the sharpest single fact in the part: **`AIProgram.optimize()` is not always
semantics-preserving**, it is an open bug with zero comments as of 2026-07-29, and its measured impact on a
real model was **17 dB PSNR** against eager PyTorch — below the floor for *2-bit palettization*. It is
shape-sensitive, so a parity test on toy tensors passes while production is broken.

---

## Read this first: the triage table

| If your situation is… | Read | Why |
|---|---|---|
| "I have a working `nn.Module` and want an `.aimodel`" | [8.1 §1–§7](references/01-conversion-and-the-io-contract.md#1-the-five-lines-and-what-each-one-is-for) | The five lines, what each owns, and the IO contract that becomes your Swift call site |
| "My assets stopped loading on a newer beta" | [8.1 §2.3](references/01-conversion-and-the-io-contract.md#23-️-the-version-gate-that-invalidates-already-published-assets) | The 0.4.0 gate, plus the `strip_debug_info` recovery that does *not* need a reconvert |
| "My transformer converted fine and is slower than I expected" | [8.1 §4.4](references/01-conversion-and-the-io-contract.md#44-️-silent-failure--using-pytorchs-default-table-instead-of-apples) | You probably passed PyTorch's default decomposition table; SDPA decomposed into six supported ops and the fast path vanished |
| "The numbers are wrong and nothing threw" | [8.1 §6.4](references/01-conversion-and-the-io-contract.md#64-️-silent-failure--optimize-is-not-always-semantics-preserving) → [§11.4](references/01-conversion-and-the-io-contract.md#114-️-the-optimizetrue--optimizefalse-gate) | The `optimize()` miscompile, then the A/B gate that catches it and its whole family |
| "My model has a KV cache" | [8.1 §9](references/01-conversion-and-the-io-contract.md#9-state-mutable-buffers-become-core-ai-states) | Mutable buffers become states, with **no opt-out**, in an order that is an observed-behaviour assumption |
| "Which names should my inputs and outputs have?" | [8.1 §7.5](references/01-conversion-and-the-io-contract.md#75-name-your-outputs-the-way-your-consumer-wants-to-read-them) | Apple's own engines duck-type on substrings, and the LLM path reads states **positionally** |
| "Should I split my model into several functions?" | [8.1 §10](references/01-conversion-and-the-io-contract.md#10-multi-function-assets-and-the-finding-that-reframes-them) | Split when stages run at different cadences; preserve Apple’s names if you also adopt `coreai-models`’ sample routing policy |
| "`unsupported ATen ops` — but the docs list that op", or the error appears only with `dynamic_shapes=` | [8.2 §2](references/02-op-coverage-composites-and-externalization.md#2-the-coverage-table-and-the-overload-rule) → [§4](references/02-op-coverage-composites-and-externalization.md#4-diagnosing-an-overload-mismatch) | The overload rule, and a two-minute diagnosis that queries the registry instead of the docs |
| "I need an op Core AI has never heard of" | [8.2 §7](references/02-op-coverage-composites-and-externalization.md#7-custom-lowerings) | `register_torch_lowering`, `allow_override`, the six-way dispatch ladder, Apple's own shipping call site |
| "I want attention / RoPE / RMSNorm to hit a fast kernel" | [8.2 §5](references/02-op-coverage-composites-and-externalization.md#5-composite-ops-a-library-you-author-models-from), [§8](references/02-op-coverage-composites-and-externalization.md#8-externalization) | Composite ops and `ExternalizeSpec` — including Apple's verbatim shipping spec list |
| "I'm converting a MoE or a Qwen3-Next-class hybrid" | [8.2 §6](references/02-op-coverage-composites-and-externalization.md#6-the-unadvertised-capability-first-class-moe-and-ssm) | Both have first-class composites. **MoE is a shipped path; SSM is IR-complete and runtime-incomplete** |
| "Integer division, `mask.sum()`, `cat` on quantized weights, or partial-rotary RoPE is wrong" | [8.2 §9](references/02-op-coverage-composites-and-externalization.md#9-four-live-silent-miscompile-defects-on-041), [§5.7](references/02-op-coverage-composites-and-externalization.md#57-️-rope-fp32-is-mandatory-and-the-partial-rotary-pairing-is-a-trap) | Live miscompiles on 0.4.1, each with a one-line workaround |
| "Profiling says one op dominates and no built-in fits" | [8.3 §2](references/03-custom-metal-kernels.md#2-when-to-do-this-at-all) | The escalation ladder, and whether the kernel can reach the Neural Engine at all (it cannot) |
| "My kernel dies at `load_function`", or "CPU reference passes and device output is NaN" | [8.3 §12.4](references/03-custom-metal-kernels.md#124-️-the-one-that-gets-everybody-a-bad-kernel-body-is-not-a-conversion-error), [§5.2](references/03-custom-metal-kernels.md#52-️-the-axis-reversal) | Every MSL mistake gives the same one-line message with no diagnostic; and the axis reversal, which the reference cannot catch |

---

## The guides in this part

### [8.1 — `torch.export` to `.aimodel`, and the IO / state / dynamic-shape contract](references/01-conversion-and-the-io-contract.md)

The pipeline end to end as a series of contracts rather than a recipe: the decomposition table and exactly
which twelve ops it preserves (Apple's README says three — a subset); the two input forms and why only
`add_pytorch_module` can externalize; `to_coreai()` as pure conversion versus `optimize()` as where the
passes run; the IO contract as your caller's API; `dynamic_shapes` and the SymInt sharp edges; state; the
multi-function split; and the Python-side verification gate that catches everything above for free.

> ⚠️ **SILENT FAILURE — `optimize()` can change your model's semantics.** `coreai-torch#49`, **open with
> zero comments** as of 2026-07-29 (FB23695952): the optimizer deletes a broadcasting-significant
> `expand_dims` in the expanded squared-distance form, and the output shape still validates because the
> inputs are square. **17 dB PSNR** at model scale; **78–85 dB** with `optimize()` off. Reproduces under
> `cpu_only()`, so it is the compiler, not a delegate. Unequal input lengths do **not** reproduce it, so a
> gate on rectangular toy tensors passes while your square production case is broken. And you often cannot
> simply skip it: **a stateful model requires `optimize()`**, because mutation outputs only become handle
> tokens after `_UPDATE_SIGNATURE_TO_HANDLES` runs.
>
> ⚠️ **SILENT FAILURE (four more).** `run_decompositions(torch.export.default_decompositions())` compiles,
> converts, saves, loads and is numerically fine — with your fused attention composite gone. An in-place
> mutation of a `forward` argument silently moves it from an input to a **state**, changing the calling
> convention. Two same-shape buffers can reorder across a PyTorch upgrade and every check still passes. And
> loading a differently named segmenter through `coreai-models.PreparedModel` selects that helper’s dynamic
> **GPU preference** instead of its Neural Engine preference, with a log line rather than an error. Direct
> Core AI callers are unaffected unless they reproduce the helper’s policy.[^sample-routing-policy]
>
> 🔴 **GAP — `coreai-torch` declares no minimum OS for the artifacts it produces**, anywhere in its own tree;
> the 27.0 floor comes from the framework docs. Also open: the full `CorePasses` catalog and whether
> `optimize()` takes arguments at all; the character set allowed in IO names; the semantics of
> `ENABLE_DEBUG_INFO` / `USE_LOCAL_COREAI`, which `coreai-torch` never reads.

### [8.2 — When an op will not convert: coverage, composite ops, custom lowerings, externalization](references/02-op-coverage-composites-and-externalization.md)

The debugging guide for conversion failures — and, more usefully, for **conversions that succeed and should
not have**. Four failure classes with different fixes; the overload rule and a registry query that settles
any docs-versus-error argument in two minutes; all fifteen documented composites with their attribute
schemas; `register_torch_lowering` including Apple's only non-toy call site; the five-phase externalization
pipeline; a register of nine live defects. It also names a capability nobody said out loud: **`gather_mm` is
Mixture-of-Experts expert dispatch and `gated_delta_update` is a Qwen3-Next-class linear-attention
recurrence** — Core AI's IR has first-class MoE and SSM support.

> ⚠️ **SILENT FAILURE — an unmatched `ExternalizeSpec` warns; it does not raise.** And the superset pattern
> (passing specs for model variants you may not have) is the *recommended* usage, so you cannot fix this by
> promoting warnings to errors. A typo or a stale class reference ships a slower model with no signal —
> assert on `composite_declaration<"…">` in `str(program)` instead. Same shape for `composite_attrs` typos,
> for `target_class=RMSNorm` where only `RMSNormImpl` matches, and for `instance_norm` without
> `use_input_stats`.
>
> ⚠️ **SILENT FAILURE — `composite_ops.SDPA` is lower-right causal; `F.scaled_dot_product_attention` is
> upper-left.** They agree whenever `q_len == k_len` and disagree **on every decode step**, so a model that
> passes its parity test on a full-sequence forward pass can be wrong the moment you run it
> autoregressively. Alongside it: integer true-divide truncates on **every** backend (`7 / 2` → `3.0`),
> `cat` on packed sub-byte tensors ignores `dim`, and `sum`/`prod` narrow their int64 accumulator to int32.
> And an inverted trap worth naming: passing PyTorch's *default* decomposition table gives you a graph that
> **fails to convert** — you decomposed *more*, the error says *unsupported*, the fix is to decompose *less*.
>
> 🔴 **GAP — nobody has measured what externalizing a composite is worth.** The mechanism is documented in
> Apple's own words; the magnitude is published nowhere, by Apple or by the community. Externalize as Apple
> does — it costs a list literal — but do not promise a stakeholder a percentage. Also open: which
> `composite_attrs` the compiler's `gated_delta_update` pattern actually expects (the doc page and Apple's
> shipping export disagree), and `HardwareConstraints` semantics.

### [8.3 — `TorchMetalKernel`: writing and embedding a custom Metal kernel](references/03-custom-metal-kernels.md)

The seam, not the shader: how a kernel you already know how to write gets into an `.aimodel`. Three pieces —
a PyTorch reference that exists only for shape inference, an MSL *body*, and the registration binding them —
plus the constructor field by field, dispatch tuples, scalars baked as literals, dtype templating and the
kernel cache, and what you can actually reach in TensorOps. §2 is deliberately discouraging; §13 is the
honest performance picture, where the same author on the same machine measured a **3.6×** win on an MoE
`gather_qmm` kernel and a **regression** from kernelizing attention.

> ⚠️ **SILENT FAILURE — the axis reversal.** `MTLTensor` extents are stored in the **reverse** of the torch
> shape: for torch `(D0, D1, D2)` the kernel sees `(D2, D1, D0)`, and subscripts reverse too. Your
> `torch_defn` is written in torch coordinates, is correct, is traced, type-checks and converts — and only
> the Metal body has the wrong convention. The recorded community failure is a per-row scale buffer that
> *"passed on CPU either way"* and read out of bounds on the engine, producing NaN logits. Do the 30-line
> dispatch probe (§14.1) once per project.
>
> ⚠️ **SILENT FAILURE — a malformed MSL body converts, optimizes, saves and loads cleanly**, then fails at
> `load_function` with `RuntimeError: Kernel coreai.metal4_kernel invoked with invalid parameters` — no line
> number, no column, no compiler output. Apple's own test proves it with a body of `A[s] = sdfs`. Syntax
> errors, undeclared identifiers and a name that does not match `input_names` all present as that one
> sentence, so compile the body standalone with `xcrun metal -c` first, every time. Three more: a hardcoded
> `result_shapes` literal compiles into a dynamic-shaped graph without complaint; an under-dispatched grid
> leaves untouched tail elements rather than erroring; and a kernel is a **fusion barrier** whose boundary
> dtype casts materialize as full-size tensors, so replacing one cheap op with a kernel is usually a
> regression your kernel's own timing will never show.
>
> ✅ **VERIFIED (Xcode 27 correction) — scale planes are real.** Xcode 27 adds `MTLTensor` data types for int2,
> FP4, FP8 and unsigned E8M0 scales, plus `MTLTensorAuxiliaryPlaneDescriptor.blockFactors` and
> `MTLTensorDescriptor.auxiliaryPlanes`. For supported E8M0 block-scaled tensors, TensorOps can consume
> the data and scale planes together. Keep the cooperative-tensor hand-dequantization path for 26.x and
> custom formats whose scale type or block geometry the auxiliary-plane contract does not represent.
> [^xcode27-scale-planes] Still open: the MSL language version the embedded source compiles at, the
> accepted `MetalParameter` attribute strings, and the symbolic path through `result_shapes`.

---

## Reading order

**Everyone starts at [8.1](references/01-conversion-and-the-io-contract.md), and nobody should skip §4 or
§11.** §4 is the decomposition table — the single line most likely to cost you an unexplained performance
regression — and §11 is the verification gate that makes every other silent failure in the part detectable.
If you read nothing else, read those two and paste §11.7's four A/Bs into CI.

**Then branch by symptom, not by curiosity.** If your conversion *raises*,
[8.2 §1–§4](references/02-op-coverage-composites-and-externalization.md#1-four-ways-a-conversion-fails) classifies the error in two minutes
and three of the four classes are five-minute fixes. If it *succeeds and is wrong*:
[8.1 §11.4](references/01-conversion-and-the-io-contract.md#114-️-the-optimizetrue--optimizefalse-gate) → [8.2 §9](references/02-op-coverage-composites-and-externalization.md#9-four-live-silent-miscompile-defects-on-041).
If it succeeds and is *slow*: [8.2 §5](references/02-op-coverage-composites-and-externalization.md#5-composite-ops-a-library-you-author-models-from) and
[§8](references/02-op-coverage-composites-and-externalization.md#8-externalization) — composite ops before anything exotic.

**[8.3](references/03-custom-metal-kernels.md) is last on purpose, and most readers never need it** — its
§2.2 ladder has four rungs and MSL is the top one. Two exceptions worth reading out of order: **§2.4 is a
model-architecture fact** (a custom kernel makes its whole function GPU-resident, permanently, foreclosing
Neural Engine residency and — per [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md) — `@Generable`), and **§13
is a go/no-go** you want before you budget the work. **Skippable outright:**
[8.1 §12](references/01-conversion-and-the-io-contract.md#12-locations-module-stacks-and-the-debugger) unless you intend to use the Debugger;
[8.2 §6](references/02-op-coverage-composites-and-externalization.md#6-the-unadvertised-capability-first-class-moe-and-ssm) unless your model is MoE or
hybrid-attention; [8.2 §7](references/02-op-coverage-composites-and-externalization.md#7-custom-lowerings) unless you have
already hit a genuinely unsupported op.

---

## What this part deliberately does not cover

- **Compression and numeric formats.** `coreai-opt` — `Quantizer`, `KMeansPalettizer`, presets, calibration,
  QAT, `cast_to_16_bit_precision`, the `ExecutionMode.GRAPH`/`EAGER` split — is
  [Part 9](../part-09-coreai-compression-numerics/README.md). These guides convert an already-compressed-or-not module
  and never quantize one; where the two interact (sub-byte injection on the externalization path, the
  compound fp16 overflow case) they say so and hand off.
- **Re-authoring a model for the hardware, and the debugging tools in depth.** BC1S layouts, the Neural
  Engine rule set, the many-static-specializations technique, `coreai_torch.debugging` in full and the Core
  AI Debugger app are [Part 10](../part-10-coreai-hardware-authoring-debugging/README.md). **Writing a good Metal
  kernel** — `matmul2d`, cooperative tensors, `reduce_rows`, the M5 neural accelerator — is
  [Part 11](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-11-metal-and-tensorops/README.md); 8.3 marks that handoff precisely at its §11.
- **The Swift side of everything you define here.** `AIModel`, `InferenceFunction.run`, `MutableViews`,
  state binding, `ComputeStream`, and the caller-side feature cache that 8.1 §10.5 says you must write
  yourself: [Part 7](../part-07-coreai-swift-runtime/README.md). **Driving the finished bundle through
  `LanguageModelSession`**, including the logits constraint that makes `@Generable` structurally unavailable
  on GPU-pipelined bundles: [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md).
- **Shipping and migrating.** `xcrun coreai-build`, `.aimodelc`, bundle layout and Background Assets weight
  delivery are [Part 15](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/README.md); the macOS 26 → 27 export-lowering regression
  and Core ML → Core AI as a *partial* migration are [Part 17](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/README.md);
  whether the converted model is actually good is [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md); **MLX as an alternative
  path from a Hugging Face checkpoint**, often faster to something running, is
  [Part 12](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/README.md). The fabricated claims in circulation — a `coreai-torch convert` CLI,
  `.coreaimodel`, `.aiasset` — are catalogued in [Part 1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/README.md); none exists,
  and these guides say so where a reader would otherwise reach for them.

---

## Sources for this part

Strongest first. **Apple source read directly off disk this session:** `apple/coreai-torch` at `main`, HEAD
`4529671`, version **0.4.1** — `converter.py` (1,082 lines), `_decomp.py`, `_validate.py`, `_utils.py`,
`_aten_to_core.py`, `externalize.py`, `_composite_declaration.py`, `_compression/_intx.py`,
`_torch_metal_kernel.py` (read in full), `composite_ops/*`, all fourteen files of `tests/dsl/`,
`tests/utils.py`, `pyproject.toml`, `CONTRIBUTING.md`, `.github/workflows/ci.yml`, and the whole `docs/`
tree including `supported-aten-ops.md`, the fifteen `composite-ops/` pages, `TorchConverter.md`,
`TorchMetalKernel.md`, `debugging.md` and the quickstart / externalization / custom-op-lowering /
custom-metal-kernels notebooks; plus `apple/coreai-models` — `segmentation/pipeline.py` (the shipped
three-entrypoint SAM3 export), `export/macos.py` (`_EXTERNALIZE_SPECS` verbatim), `export/mlir_ops.py` (the
only non-toy `register_torch_lowering` call site in existence), `primitives/macos/switch.py` and the three
MoE recipes, `ModelStructure.swift`, `ImageSegmentationEngine.swift`, `CoreAISequentialEngine.swift`.
**Apple's own agent skills** — `skills/skills/{working-with-coreai,model-authoring,model-compression-exploration}/`
— carry empirical rules that appear in no session or doc page: the PSNR acceptance bands, the
Neural-Engine-versus-GPU at-a-glance table, `neural_engine_rules.md` and `gpu_rules.md`. **Apple-staff
answers** on the repos' trackers: `coreai-torch` #33, #37, #44 (@cymbalrush, @gokulkrishna98, @DawerG),
`coreai-optimization` #7 (@crowbat), `coreai-models` #66 and #118 (@stikves — the definitive statement that
hybrid/linear-attention models are deliberately rejected by the Swift runtime), plus the `coreai-torch`
v0.4.1 release notes and the bundled `coreai-core` 1.0.0b2 changelog. **WWDC26 transcripts**, used for
framing and cross-checked against source before any API-shaped claim: 325 (*Dive into Core AI model
authoring and optimization*) and 330 (*Optimize custom machine learning operations with Metal tensors*),
plus Apple Tech Talk 111432 for the TensorOps version ladder, the Xcode 26.6 SDK as the baseline,
and Xcode 27 `MTLTensor.h` / MPP headers for the int2/FP4/FP8/E8M0 and scale-plane additions.
[^xcode27-scale-planes] **Community sources** —
`coreai-torch` issues #1, #2, #5, #6, #9, #10, #11, #21, #49, #51 and PRs #7/#13/#18/#22/#29/#32/#40/#41/#45,
`coreai-models` #66/#118/PR #69, and `john-rocky`'s `coreai-model-zoo` knowledge files — supply every latency
and accuracy number that is not Apple's, each labelled **community-measured** at its point of use with
hardware, OS build and date where the source gave them. **Apple published no performance figure for any of
this except the SAM3 76% and the Qwen3-MoE tok/s deltas, both with hardware and methodology unstated.** All
three guides were last verified 2026-07-27 against `coreai-torch` 0.4.1, `coreai-core` 1.0.0b2,
`coreai-models` 0.2.0-pre and macOS 27.0 betas `26A5378j` / `26A5388g`; the state of every issue and PR
cited was re-checked 2026-07-29, and `coreai-torch#49` was still unresolved. `coreai-torch` PR #7 (the
SDPA submodule re-export fix) was **closed without being merged on 2026-07-29** (re-checked via `gh`
2026-07-31). The 0.4.0-artifact incident
issues are resolved: `coreai-torch#37` closed as completed 2026-07-13 and `#44` closed as completed
2026-07-24.

[^sample-routing-policy]: The name classifier and compute-unit preferences live in the optional
    `apple/coreai-models` package’s pinned
    [`ModelStructure.swift`](https://github.com/apple/coreai-models/blob/5ed9981303b38d5a44aa6b45509bc4f6945029f5/swift/Sources/CoreAIShared/Runtime/ModelStructure.swift#L12-L218),
    while Core AI’s documented default independently selects the compute-unit combination that minimizes
    inference latency: [Managing model specialization and caching](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/docs/Managing%20model%20specialization%20and%20caching.md).

[^xcode27-scale-planes]: Apple’s OS 27 API reference documents the scale-plane descriptor, the tensor
    descriptor’s auxiliary-plane map, and the new tensor datatypes:
    [`MTLTensorAuxiliaryPlaneDescriptor`](https://developer.apple.com/documentation/metal/mtltensorauxiliaryplanedescriptor),
    [`MTLTensorDescriptor.auxiliaryPlanes`](https://developer.apple.com/documentation/metal/mtltensordescriptor/auxiliaryplanes), and
    [`MTLTensorDataType`](https://developer.apple.com/documentation/metal/mtltensordatatype).
    The automatic-dequantization and custom-format fallback are also stated in the authoritative
    [WWDC26 session 330 transcript](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/transcripts/wwdc2026-330.txt#L53-L78).
