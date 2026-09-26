# Part 9 — Core AI: compression and numeric formats

**Version floor:** this part is almost entirely **host-side Python**. The package is **`coreai-opt`**
(import `coreai_opt`), verified against **0.2.1, released 2026-07-02**, with a handful of behaviours
taken from `main` at commit `cd95cb2` — newer than 0.2.1 and in no release — marked inline wherever
used. Host requirements are hard and non-negotiable: **Python ≥ 3.11, < 3.14**; **torch ≥ 2.8.0,
≤ 2.11.0**; **torchao ≥ 0.15.0, ≤ 0.17.0**; macOS or Linux; and a **C++ toolchain present at runtime**,
not merely at install time. What you produce deploys to **Core AI on iOS 27.0 / macOS 27.0** — Core AI
does not exist before 27.0 on any platform, and there is no "26.4 Core AI." The optional `coreml`
export backend targets **`ct.target.iOS26`** and is a strictly smaller feature set. Reference 03
additionally spans two *other* version stories routinely confused with Core AI's: **MPP TensorOps is a
26.x feature** with a per-point-release ladder (26.0 introduction · 26.1 bfloat · 26.3 cooperative
tensors as matmul inputs · 26.4 int4/int8 tensors) while the shipped Xcode 26.6 SDK annotates the
deployment macro as **26.2**; and **MLX** gates its accelerated kernels on **26.2** plus a
GPU-generation check.

**Who this is for:** Python ML engineers who have a working PyTorch model and now have to make it
small enough, fast enough, and still good enough. Getting it *converted* is
[Part 8](../part-08-coreai-pytorch-conversion/README.md); *running* it is [Part 7](../part-07-coreai-swift-runtime/README.md).

> ⚠️ **Core AI ships with zero Apple sample-code projects.** Verified: **0 `sampleCode` entries across
> all 312 indexed Core AI symbols**, and `/documentation/updates/coreai` returns 404. Unlike Parts 1–6,
> where a first-party compiling Xcode project settles a signature argument in thirty seconds, there is
> nothing here to check against. The evidence ladder for this part is, strongest first: the **shipped
> source of `apple/coreai-optimization` and `apple/coreai-models`** read on disk; **Apple's own agent
> skills** vendored in `apple/coreai-models` (written by Apple engineers for machine consumption, and
> therefore unusually literal and rule-shaped); the **`coreai-opt` documentation site**; the **GitHub
> issue and PR threads** where Apple maintainers answer; and **WWDC26 session 325**. The practical
> consequence: **signatures in this part carry 🟡 RECONSTRUCTED more often than anywhere in Parts 1–6**,
> and the 🔴 GAP boxes are correspondingly denser. Where session 325 and the shipped source disagree —
> and they do, repeatedly — the source wins and the guide says so.

---

## Why this part exists

This is the only stage of the pipeline where you **deliberately throw information away**. Everything
upstream (re-authoring, conversion) changes *what* runs; everything downstream (specialization,
compilation) changes *where* it runs. Compression is the one place you trade quality for size and
speed on purpose, which means it is also the one place where "it worked" and "it did what I asked"
come apart.

Four things make that gap wider here than it looks:

1. **The library's house style is to skip, not to raise.** When compression cannot be applied —
   a block size your weight dimension doesn't divide by, a granularity a module can't take — the
   layer is logged at `WARNING`, permanently disabled, its fake-quant node **deleted from the
   graph**, and `prepare()` returns successfully. That is defensible for a sweep tool and dangerous
   for a build pipeline. Your model then scores *better* than you predicted, and is larger.
2. **Emit, store and compute are three different sets.** `coreai-opt` will happily produce int2
   weights with FP8 E5M2 LUT scales; `NDArray.ScalarType` stores `int2`–`int7` and `uint1`–`uint7`,
   widths no tool in the corpus emits; the Neural Engine computes **fp16, int8, int16 — full stop**,
   and Metal TensorOps offers 4- and 8-bit integer operands with **no scale mechanism of any kind**.
   A mismatch does not throw; it silently reassigns your model to a slower compute unit.
3. **Uniform compression is almost never right.** Apple's own SAM3 demo is the proof: `presets.w4()`
   applied everywhere takes 3 GB to ~430 MB and stops detecting an occluded flower, and the culprit is
   a subtree holding **4% of the parameters**. The fix is one config entry; finding it is not.
4. **A meaningful part of the surface got zero seconds of stage time.** Pruning, mixed precision and
   KV-cache quantization are fully implemented and documented in-repo, and appear in no WWDC26
   session. If you learned this stack from the talk, you do not know they exist.

---

## Read this first: the triage table

| If your situation is… | Read | Why |
|---|---|---|
| "I just need something smaller, today" | [9.1 §3](references/01-quantization.md#3-presets-the-one-liners-and-what-they-expand-to) | `presets.w4()` / `w8()`, and the eleven fields each one silently sets |
| "My compressed model is bigger than the arithmetic says" | [9.1 §7.5](references/01-quantization.md#75-️-silent-failure--a-block-size-your-weight-isnt-divisible-by-leaves-the-layer-uncompressed) · [9.3 §2.7](references/03-numeric-formats-across-the-stack.md#27-️-silent-failure--a-block-size-your-weight-doesnt-divide-by-leaves-the-layer-at-full-precision) | The block-divisibility silent skip. The single most common defect in this part |
| "My model won't `torch.export`" | [9.1 §8.4](references/01-quantization.md#84-which-mode-actually) | EAGER mode — and the non-obvious externalization reason for choosing it |
| "I need to quantize activations, not just weights" | [9.1 §8–§9](references/01-quantization.md#8-graph-vs-eager-a-structural-split-not-a-flag) | GRAPH mode, observers, calibration, and the six ops whose qscheme is overridden behind your back |
| "Quality fell off a cliff below 8 bits" | [9.1 §10.2, §11, §13](references/01-quantization.md#102-the-bit-width-ladder-and-where-it-breaks) → [9.2 §14–§15](references/02-palettization-pruning-and-joint.md#14-mixed-precision) | The bit-width ladder, then QAT; then the SAM3 diagnosis and the sensitivity sweep that automates it |
| "I'm targeting iOS / the Neural Engine" | [9.2 §1.3, §5](references/02-palettization-pruning-and-joint.md#13-the-strongest-evidence-apples-shipped-presets-split-by-platform) | Apple's exporter **refuses** to build a quantized iOS bundle. Palettization, grouped-channel, and the rank-5 ceiling |
| "I'm targeting the macOS GPU" | [9.3 §9.1](references/03-numeric-formats-across-the-stack.md#91-pick-a-format-by-where-you-want-it-to-run) | int4 `symmetric_with_clipping`, per-block 32 — Apple's own preset, and why int8 buys bandwidth not arithmetic |
| "Should I prune?" | [9.2 §11.1, §11.8](references/02-palettization-pruning-and-joint.md#111-the-verdict-first) | Apple's own answer is "probably not", and the 🔴 GAP under it should decide it for you |
| "I want palettized weights *and* quantized activations" | [9.2 §13](references/02-palettization-pruning-and-joint.md#13-joint-compression) | Joint compression: mandatory ordering, mandatory `lut_qspec`, CoreAI backend only |
| "Which format can the hardware actually multiply?" | [9.3 §1.2](references/03-numeric-formats-across-the-stack.md#12-the-master-matrix) | The master matrix. Emit vs store vs compute, on one page |
| "Numbers are right; it's just slower than it should be" | [9.3 §7.1](references/03-numeric-formats-across-the-stack.md#71-the-lookup-table) | Eighteen crossings that silently degrade, with a detection method each |
| "How do I verify what I actually shipped?" | [9.3 §8](references/03-numeric-formats-across-the-stack.md#8-how-to-check-what-you-actually-got) · [9.2 §16](references/02-palettization-pruning-and-joint.md#16-apples-psnr-acceptance-gates) | Model viewer, `AIModelAsset.Summary`, Instruments — then Apple's PSNR acceptance gates |
| "I only have an `.aimodel`, no PyTorch model" | [9.1 §15](references/01-quantization.md#15-coreai_optcoreai_utils-compressing-an-already-converted-program) · [9.2 §12](references/02-palettization-pruning-and-joint.md#12-program-level-compression-palettize_weights-and-sparsify_weights) | Program-level passes. Apple's own docs call this the non-preferred path |
| "I have to ship to `ct.target.iOS26`" | [9.1 §16.2](references/01-quantization.md#162-what-coreml-cannot-do) · [9.3 §2.8](references/03-numeric-formats-across-the-stack.md#28-the-coreml-export-backend-is-a-strictly-smaller-set--and-it-rejects-at-finalize) | The CoreML restriction matrix. It rejects loudly at `finalize()`, which is the good news |
| "I'm deploying an LLM and the KV cache is the budget" | [9.1 §12](references/01-quantization.md#12-kv-cache-quantization-graph-mode-only) | KV-cache quantization: graph mode only, in no session, with a correctness precondition nothing checks |

---

## The guides in this part

### [9.1 — `coreai-opt` quantization: configs, GRAPH vs EAGER, calibration and QAT](references/01-quantization.md)

The foundation guide, and the one everything else assumes. The four-method compressor lifecycle
(`__init__` → `prepare` → `calibration_mode`/`training_mode` → `finalize`) that quantization,
palettization and pruning all share; the presets and what they expand to; the three-level config
hierarchy; `QuantizationSpec` field by field with nine dtypes and three qschemes; granularity and the
default-axis table; PTQ and QAT with the `QATSchedule` three-integer state machine; KV-cache
quantization; the `casting` and `coreai_utils` helpers; and the SAM3 story, the best teaching
narrative in the part.

> ⚠️ **GRAPH vs EAGER is a structural split, not a flag.** `_graph/` (PT2E/torchao on `torch.export`)
> and `_eager/` (`__torch_function__`) are separate implementations with different capabilities,
> different config vocabularies — graph keys on aten op names, eager on call sites — and different
> bugs. Apple's own source says it plainly: the two modes are ***"not guaranteed to produce equivalent
> quantized models."*** So **never compare a graph-mode result to an eager-mode result**, and inspect
> in the mode you will compress in.
>
> ⚠️ **SILENT FAILURE (the headline one).** A **block size your weight dimension isn't divisible by
> leaves the layer at full precision** — warning only, and the fake-quant node is then *deleted* from
> the prepared graph. Also live: **diffusion quantization failures are swallowed with a warning**
> (`export/compiler.py:69-72`), so a `--compression 4bit` FLUX-class export whose quantization pass
> throws produces a successful export of an **fp16 model** — *file size is the only signal*. A
> **shared/tied weight can take its dtype from one config and its schedule from another** (issue #41,
> OPEN), and the warning mentions only the schedule. **fp16 casting can zero an activation** (issue
> #7, OPEN). For eager-mode quantization and eager-only k-means palettization, finalizing with the
> Core AI backend **frees the original dense weights in place**; this is not a universal behavior of
> every `finalize()` backend or graph mode. Preserve a float reference with `deepcopy` before
> `prepare()`.[^destructive-finalize-scope]
>
> 🔴 **GAP — fourteen, tabulated in §20.3, and nothing is guessed inside any of them.** The sharpest:
> whether diffusion `metadata.json` records the **attempted** or the **achieved** compression. If it
> records the attempted setting, your bundle metadata actively confirms a compression that did not
> happen. Safe default until someone runs the experiment: **do not trust metadata as evidence of
> compression** — verify by size.

### [9.2 — Palettization, pruning, joint compression, and mixed precision](references/02-palettization-pruning-and-joint.md)

The other three things `coreai-opt` does, plus the two ways of combining them. Lookup-table
compression via k-means with its three schemes (scalar per-tensor, scalar per-grouped-channel, and
vector `cluster_dim > 1` for *fractional* bits per weight); `MagnitudePruner`; joint compression; and
mixed precision, whose ResNet50 result is the best argument in the part — **12.03 MB at 3.95 BPW
beating uniform 4-bit's 12.16 MB by 4.4 points of top-1**, by moving two layers up, two down and
leaving fifty alone. Two of its four topics — pruning and mixed precision — got **zero seconds of
stage time** in any session, which is why the guide exists. It also carries Apple's PSNR acceptance
gates, the closest thing to an official "did my compression work" standard, lifted from an agent skill
because an agent needs a number.

> ⚠️ **SILENT FAILURE — `enable_per_channel_scale=True` moves your model off the Neural Engine.**
> It lowers to `mps.dequantize_lut` with **rank-6 LUTs, and the ANE's maximum tensor rank is 5**, so
> the runtime falls back to the GPU. Nothing raises, nothing warns, conversion succeeds, and your
> PyTorch numerics get *slightly better* — that is the whole point of the feature. On a Mac you may
> never notice. On an iPhone you have traded the efficient engine for the power-hungry one and your
> battery regression surfaces in field telemetry weeks later. Session 325 says the SAM3 encoders use
> per-channel scales; the shipped pipeline sets it to `False` **and explains why in a docstring**.
> The source wins.
>
> ⚠️ **SILENT FAILURE (five more).** A **group size your weight isn't divisible by** disables the
> module permanently and removes the parametrization. **Vector palettization is non-deterministic** —
> seeding does not reach spawned workers, so the artefact you evaluated is not the artefact you
> shipped. **Channel-structured pruning rounds sparsity down** and can prune zero channels. **Joint
> compression without `lut_qspec` buys you no speed at all** (a float LUT forces float ops), and
> **with the default `op_state_spec` it double-compresses your weights** — a missing three-character
> value. And **a sweep optimising PSNR will pick the setting that costs you the ANE**, because
> `enable_per_channel_scale` is one of the axes Apple's own exploration skill sweeps and it improves
> PSNR.
>
> 🔴 **GAP — nobody can show that Core AI's runtime does anything with unstructured sparsity.**
> A pruned model converts, and there is an export test. What op the masked weight lowers to, whether
> the `.aimodel` stores a sparse encoding or a dense tensor of zeros, and whether any compute unit
> exploits it for size or latency, are stated **nowhere** — not the docs, not the skills, not a
> session, not a community measurement. **Safe default: assume unstructured pruning buys you nothing
> at runtime**, and use it as Apple's docs describe it — a measurement instrument.

### [9.3 — int4 to MX: which layer supports which numeric format](references/03-numeric-formats-across-the-stack.md)

A reference rather than a tutorial, answering one question in as many tables as it takes: for a given
format — int4, FP8 E4M3, FP4 E2M1, MXFP4, a 6-bit palette, E8M0 block scales — which layer can
**emit** it, which can **store** it, and which can actually **compute** on it. Those are three
different sets and that is the whole guide: the full `NDArray.ScalarType` zoo, the Neural Engine's
three dtypes and structural constraints, the complete MPP TensorOps enum with the 4-bit operand rows
verbatim, MLX's widest-in-the-stack menu implemented **entirely in software**, and — the section the
other guides cite — the eighteen-row table of crossings that silently degrade.

> ⚠️ **SILENT FAILURE — this is the guide about them.** Core AI's own specialization documentation
> states the mechanism: *"Fallback to other kinds in `allowedComputeUnitKinds` may still occur for
> operations or operation patterns that are incompatible with the preferred kind."* You get correct
> outputs, several times slower, with no diagnostic anywhere except the Xcode model viewer and
> Instruments. Fifteen of the eighteen consolidated failures are *"the thing you asked for did not
> happen, and the system continued."* Two produce **wrong numbers** rather than slow ones: **int64
> narrowed to int32 overflows above `INT32_MAX`**, and **`-inf` as a softmax mask is mishandled by the
> ANE hardware — use `-40000.0`**. A bare Python float literal that fp16 can't round-trip (`1e-6`)
> is enough to move an entire op to the GPU.
>
> 🔴 **GAP — the inference-time error taxonomy is undocumented across all 312 Core AI symbols.**
> `AssetError` covers asset operations only; nothing documents what `AIModel.init(contentsOf:)`,
> `loadFunction(named:)`, `run(...)` or `encode(...)` throw. **Do not write a `catch let e as
> CoreAIError` clause against a type name nobody has seen.** Also open: no `BitwiseCopyable` Swift type
> exists for sub-byte or 8-bit-float scalars, so **sub-byte data is unreadable from Swift except as raw
> bytes**; bfloat16 on the ANE is unattested; and **§5 is static analysis of headers — nothing was run**.

---

## Reading order

**Everyone starts at [9.1](references/01-quantization.md), including readers who only care about
palettization.** It carries the lifecycle, the config hierarchy and the scoping rules that guides 02
and 03 assume without restating — and the single most load-bearing rule in the package, that **`None`
means "leave this alone" and is not the same as omitting the field**. Read §1–§7 and §13 first; the
SAM3 story is the shortest route to understanding *why* the config hierarchy has the shape it does.
Defer §9 (observers, calibration) until you need activation quantization, and §11 (QAT) until PTQ has
demonstrably failed you.

**Then branch by target.** iOS or Neural Engine → [9.2](references/02-palettization-pruning-and-joint.md),
reading §1.3 and §5 before you write any config, because Apple's exporter enforces the
palettization/quantization platform split and §5 is the highest-value footgun in the part. macOS GPU
or a format question → [9.3](references/03-numeric-formats-across-the-stack.md) §1.2 and §9.1, which
between them are a ten-minute read that will save you a week.

**[9.3](references/03-numeric-formats-across-the-stack.md) §7.1 and §8 are worth reading *before* you
compress anything, not after.** The eighteen silent crossings change which configurations you try, and
the four inspection tools mean you find out on day one rather than in field telemetry. Pair them with
[9.2 §16](references/02-palettization-pruning-and-joint.md#16-apples-psnr-acceptance-gates), Apple's PSNR gates, and wire a metric up
before your first `prepare()` — Apple's own compression skill refuses to run without one.

**Skippable outright.** [9.2 §11](references/02-palettization-pruning-and-joint.md#11-pruning-the-technique-nobody-presented) (pruning) unless
you have a training loop, a dataset and a verified hardware requirement — read §11.1 and §11.8 and
leave. [9.1 §16](references/01-quantization.md#16-export-backends-and-the-coreml-restriction-matrix) and [9.3 §2.8](references/03-numeric-formats-across-the-stack.md#28-the-coreml-export-backend-is-a-strictly-smaller-set--and-it-rejects-at-finalize)
unless you ship to `ct.target.iOS26`; [9.3 §6](references/03-numeric-formats-across-the-stack.md#6-mlx-the-widest-menu-implemented-in-software)
unless you also use MLX; [9.1 §12](references/01-quantization.md#12-kv-cache-quantization-graph-mode-only) unless you deploy an LLM.

---

## What this part deliberately does not cover

- **Conversion.** `torch.export`, `get_decomp_table()`, `TorchConverter`, `optimize()`, `save_asset()`,
  and how a compressed `nn.Module` becomes an `.aimodel` — [Part 8](../part-08-coreai-pytorch-conversion/README.md).
  Every guide here starts with an `nn.Module` and hands back an `nn.Module`.
- **The Core AI Debugger** — sync points, the PSNR metric, `save_intermediates` / `load_intermediates`,
  the comparison workspace, and the Neural Engine authoring rules that make the rank-5 ceiling make
  sense: [Part 10](../part-10-coreai-hardware-authoring-debugging/README.md). This part *uses* the Debugger's
  output in the SAM3 story; actually *finding* the layer that needs a different bit-width is Part 10.
- **Running the result.** `AIModel`, `InferenceFunction`, `NDArray` in anger, `SpecializationOptions`,
  specialization caching — [Part 7](../part-07-coreai-swift-runtime/README.md).
- **Writing kernels**, and **MLX as a framework.** Guide 03 §5 and §6 are dtype and quantization
  *surfaces* only; authoring TensorOps matmuls is [Part 11](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-11-metal-and-tensorops/README.md), and MLX
  proper is [Part 12](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/README.md) and [Part 13](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/README.md).
- **Size budgets and the measurement discipline that makes these trades decidable** —
  [Part 15](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/README.md). **Choosing Core AI over Core ML or MLX at all** —
  [Part 1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/README.md), which also carries the known-bad-claims reference
  (`.coreaimodel`, `.aiasset`, a `coreai-torch convert` CLI, "iOS 20 / macOS 17" — all fabricated).

---

## Sources for this part

Strongest first. **Shipped source read on disk:** `apple/coreai-optimization` at `main` HEAD
`cd95cb2` — 29,337 Python LOC under `src/`, with the quantization, palettization, pruning, casting,
inspection and `coreai_utils` subtrees read file by file, plus `pyproject.toml`, `Makefile`,
`AGENTS.md`, `CHANGELOG.md`, the unreleased `changelog.d/` fragments and the CI workflow;
`apple/coreai-models` for the shipping recipes (`models/sam3/pipeline.py`, `export/presets.py`,
`export/compiler.py`, `diffusion/presets.py`, `llm/export.py`); `apple/coreai-torch`;
`ml-explore/mlx` at HEAD `973e27f` and `ml-explore/mlx-lm`; and the
**MetalPerformancePrimitives headers shipped in the Xcode 26.6 SDK (Build 17F113)** — ~14,300 lines,
which establish the 26.x baseline; guide 03 separately uses Xcode 27 `MTLTensor.h` and MPP headers
for int2/FP4/FP8/E8M0 types and auxiliary scale planes.[^xcode27-scale-planes] **Apple's own agent
skills**, vendored in `apple/coreai-models` and treated throughout as *stronger than session
transcripts*: `model-authoring/SKILL.md` (the four PSNR gates at `:94-99`, the sizing table at
`:149-153`), its 479-line `neural_engine_rules.md`, `gpu_rules.md`, `common_issues.md`,
`model-compression-exploration/SKILL.md` and `model-deployment`. **`coreai-opt` documentation** — the
quantization, palettization, pruning, utils, debugging and examples trees, source of every
Apple-published number here. **GitHub issues and PRs** on both Apple repos, several with maintainer
answers (#3, #7, #16, #38, #40, #41, #42/#44, #45, #52, #56), states re-checked
2026-08-17; `apple/coreai-models#56` remains open.
**WWDC26 session 325**, *"Dive into Core AI model authoring and optimization"* — used for narration,
framing and the SAM3 story, and **never alone for a signature**; plus **Apple Tech Talk 111432** for
the M5 numbers, which is a Tech Talk and not a WWDC26 session, has no published code block, and whose
symbol names are therefore marked 🟡 wherever used. **Community measurement** comes from one source,
`john-rocky/coreai-model-zoo` and its `coreai-models` fork — single-author, self-declared uncontrolled
benchmarks, frequently the only numbers in existence for what they measure, labelled
🟠 COMMUNITY-MEASURED at every point of use. **Apple published no latency figure for any non-LLM model
in `apple/coreai-models`**, and no M5 hardware backed any TensorOps claim in this part.

[^destructive-finalize-scope]: The pinned `coreai-optimization` sources limit dense-weight freeing to
    `ExportBackend.CoreAI` in eager quantization and document the same Core AI-specific behavior for
    k-means palettization: [`Quantizer.finalize`](https://github.com/apple/coreai-optimization/blob/cd95cb2545a586dbc14c85f5efd16b4635e5786c/src/coreai_opt/quantization/quantizer.py#L435-L482) and
    [`KMeansPalettizer.finalize`](https://github.com/apple/coreai-optimization/blob/cd95cb2545a586dbc14c85f5efd16b4635e5786c/src/coreai_opt/palettization/kmeans/palettizer.py#L357-L425).

[^xcode27-scale-planes]: Apple documents the OS 27 API in
    [`MTLTensorAuxiliaryPlaneDescriptor`](https://developer.apple.com/documentation/metal/mtltensorauxiliaryplanedescriptor),
    [`MTLTensorDescriptor.auxiliaryPlanes`](https://developer.apple.com/documentation/metal/mtltensordescriptor/auxiliaryplanes), and
    [`MTLTensorDataType`](https://developer.apple.com/documentation/metal/mtltensordatatype); the
    authoritative [WWDC26 session 330 transcript](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/transcripts/wwdc2026-330.txt#L53-L78)
    describes automatic dequantization and the custom-format cooperative-tensor fallback.
