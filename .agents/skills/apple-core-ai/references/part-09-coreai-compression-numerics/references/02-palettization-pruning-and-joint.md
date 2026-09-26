# Palettization, pruning, joint compression, and mixed precision

**Part 9 · Core AI: compression and numeric formats · Reference 02**

**Version floor.** Everything here is host-side Python in **`coreai-opt`** (import `coreai_opt`),
verified against **0.2.1, released 2026-07-02**, plus a small number of behaviours from `main` at
commit `cd95cb2`, which is **newer than 0.2.1 and in no release** — those are marked inline. `0.2.0`
was the initial release, **2026-06-08**. Host floor is hard: **Python ≥ 3.11, < 3.14**; **torch
≥ 2.8.0, ≤ 2.11.0**; **torchao ≥ 0.15.0, ≤ 0.17.0**; macOS or Linux; and — for palettization
specifically — **a C++ toolchain present on the host at runtime**, not just at install time.
Within the package there is one API-level version gate that matters: **`ConvTranspose1d/2d/3d`
palettization was added in 0.2.1** and is absent from 0.2.0. The artefacts you produce deploy to
**Core AI on iOS 27.0 / macOS 27.0**; Core AI does not exist before 27.0 on any platform. The
optional `coreml` export path targets **`ct.target.iOS26`** and is a strictly smaller feature set
that rejects most of what this guide teaches.

⚠️ **Core AI has zero Apple sample-code projects.** Verified: 0 `sampleCode` entries across all 312
indexed Core AI symbols, and `/documentation/updates/coreai` 404s. There is no first-party compiling
Xcode project to check a signature against. The evidence ladder for this guide, strongest first:
**the shipped source of `apple/coreai-optimization`**; **Apple's own agent skills** vendored in
`apple/coreai-models` (written by Apple engineers for machine consumption, and therefore unusually
literal and unusually rule-shaped); **the shipped export recipes in `apple/coreai-models`**; the
**`coreai-opt` documentation site**; and **WWDC26 session 325**. Community measurements appear in
§17 and are labelled as such every single time.

Two of this guide's four topics — **pruning** and **mixed precision** — got **zero seconds of stage
time** in any WWDC26 session. They are fully implemented and fully documented in the repo. That
asymmetry is the reason this guide exists.

---

## What this covers

Guide 01 in this part covered quantization: an affine map from float to a small integer grid,
`scale` and `zero_point`, per-tensor / per-channel / per-block. This guide covers the other three
things `coreai-opt` does, and the two ways of combining them.

- **Palettization** — lookup-table compression. Instead of a formula that maps floats onto a
  uniform grid, you fit **k-means centroids** to the weights you actually have and store an *index*
  per weight plus a small **palette** (the LUT). Three documented schemes: **scalar per-tensor**,
  **scalar per-grouped-channel**, and **vector** (`cluster_dim > 1`, which gets you *fractional*
  bits per weight). The API deliberately mirrors quantization — `KMeansPalettizer(model, config)` →
  `prepare()` → `finalize()` — so if you read guide 01 you already know the shape.
- **Why Apple points iOS at palettization specifically.** Session 325's exact words are
  *"well-suited for power efficiency on iOS"*, and the shipped iOS export presets in
  `apple/coreai-models` are palettization presets while the macOS ones are quantization presets.
  §1.2 explains the hardware reason.
- **⚠️ The ANE rank-5 ceiling**, and the fact that one palettization option — `enable_per_channel_
  scale=True` — pushes the lowered LUT to **rank 6**, which the Neural Engine **rejects**, silently
  moving your model to the GPU. This is documented in a docstring inside Apple's own SAM3 export
  pipeline and appears nowhere in any session. It is the single highest-value footgun in this guide.
- **Pruning** — `MagnitudePruner`, unstructured and channel-structured **schemes**, constant and
  polynomial-decay **schedules**, and the mask arithmetic. Also the honest answer to "should I?",
  which Apple's own documentation gives more bluntly than most vendors would.
- **Joint compression** — palettize weights, then quantize activations on the palettized model.
  A first-class documented workflow with a **mandatory ordering**, a **mandatory LUT quantization**
  if you want the fast execution path, and a hard restriction: **it finalizes only to Core AI.**
- **Mixed precision** — different bit-widths for different layers, driven by a per-layer sensitivity
  sweep. This is the direct answer to the problem guide 01's SAM3 story ends on: *which layers
  tolerate compression?* Apple ships mixed-precision YAML configs for Qwen3 on iOS, publishes
  perplexity for them, and ships an agent skill that automates the sweep.
- **Apple's PSNR acceptance gates** — four numbers from the `model-authoring` skill that function as
  the de-facto standard for "did my compression work". Reproduced in §16 and used throughout.
- **The worked examples the repo ships** — `edsr`, `resnet50`, the toy models, and **four MNIST
  notebooks** (quantization / palettization / pruning / palettization + activation quantization).
  These are the fastest route to intuition and most readers should start there.

## What this does *not* cover

- **Quantization itself.** `QuantizerConfig`, `QuantizationSpec`, GRAPH vs EAGER, observers,
  calibration, QAT, KV-cache quantization: all in
  [guide 01](01-quantization.md). This guide assumes it. Where the two interact — joint compression,
  `lut_qspec`, mixed precision — the interaction is spelled out here.
- **The Core AI Debugger.** Sync points, the PSNR metric, `save_intermediates`, the comparison
  workspace — Part 10. §15.5 hands off to it explicitly, because the Debugger is how you *find* the
  layer that needs a different bit-width.
- **Conversion.** `torch.export`, `get_decomp_table()`, `TorchConverter`, `optimize()`,
  `save_asset()` — Part 8. This guide starts with an `nn.Module` and hands back an `nn.Module`.
- **The Swift runtime.** Loading and running the resulting `.aimodel` — Part 7.

## What you need

```bash
pip install coreai-opt                     # or: uv pip install coreai-opt
pip install 'coreai-opt[coreai]'           # adds coreai-core==1.0.0b2, coreai-torch==0.4.1, scikit-learn
```

- **A C++ compiler on the host, at runtime.** This is not optional for palettization and it is not
  a build-time-only dependency. `coremltools` was dropped as a runtime dependency in commit
  `edd4720`; the 1-D k-means it used to provide is now a **vendored C++ core JIT-compiled by
  `torch.utils.cpp_extension.load()` on first use**. §2.3 covers what that means in practice.
- **A representative sample of your real inputs**, if you are doing anything with activations. For
  weight-only palettization and pruning the `example_inputs` tuple only needs to be *shape*-correct,
  because both are data-free. For joint compression it must be real data.
- **An evaluation metric you trust, wired up before you start.** Every decision in this guide is a
  trade. Apple's own compression-exploration agent skill refuses to run without one, and it is
  right to.
- **Patience for k-means on a large model.** Clustering a 600 M-parameter encoder is not instant.
  §7.2 covers `num_workers`, which is the one lever that matters and which session 325 never
  mentions.

---

## Contents

1. [Lookup tables are a different idea, and the ANE is why](#1-lookup-tables-are-a-different-idea-and-the-ane-is-why)
2. [The palettizer in eight lines](#2-the-palettizer-in-eight-lines)
3. [`PalettizationSpec`: five fields, and what each one costs](#3-palettizationspec-five-fields-and-what-each-one-costs)
4. [The three schemes, with diagrams](#4-the-three-schemes-with-diagrams)
5. [⚠️ The ANE rank-5 ceiling](#5-️-the-ane-rank-5-ceiling)
6. [Sizing: what a bit-width actually buys](#6-sizing-what-a-bit-width-actually-buys)
7. [Determinism, workers, and fast k-means mode](#7-determinism-workers-and-fast-k-means-mode)
8. [Sensitivity-weighted k-means (SqueezeLLM)](#8-sensitivity-weighted-k-means-squeezellm)
9. [`lut_qspec`: quantizing the palette itself](#9-lut_qspec-quantizing-the-palette-itself)
10. [What `finalize()` emits](#10-what-finalize-emits)
11. [Pruning: the technique nobody presented](#11-pruning-the-technique-nobody-presented)
12. [Program-level compression: `palettize_weights` and `sparsify_weights`](#12-program-level-compression-palettize_weights-and-sparsify_weights)
13. [Joint compression](#13-joint-compression)
14. [Mixed precision](#14-mixed-precision)
15. [Choosing per layer: the sweep, the Debugger, and SAM3](#15-choosing-per-layer-the-sweep-the-debugger-and-sam3)
16. [Apple's PSNR acceptance gates](#16-apples-psnr-acceptance-gates)
17. [Community-measured findings, labelled](#17-community-measured-findings-labelled)
18. [The worked examples the repo ships](#18-the-worked-examples-the-repo-ships)
19. [⚠️ Silent failures, consolidated](#19-️-silent-failures-consolidated)
20. [Numbers, attributed](#20-numbers-attributed)
21. [Quick reference](#21-quick-reference)
22. [Sources and evidence ledger](#22-sources-and-evidence-ledger)

---

## 1. Lookup tables are a different idea, and the ANE is why

### 1.1 Two families, one API

`coreai-opt` ships three compression techniques, and the package's own enum is the cleanest
statement of the taxonomy:

> ✅ **VERIFIED** — `src/coreai_opt/common.py:110-134`:
> ```python
> _COREML_COMPRESSION_CODES = {"quantization": 3, "palettization": 2, "pruning": 1}
>
> class CompressionType(_StrEnum):
>     QUANTIZATION = auto(); PALETTIZATION = auto(); PRUNING = auto()
>     def to_coreml_code(self) -> int: ...
> ```

Those three are not variations on a theme. They throw away different information:

| | What is stored | What is thrown away | Reconstruction |
|---|---|---|---|
| **Quantization** | integer codes + `scale` (+ `zero_point`) | precision, uniformly across the value range | `x ≈ (q − zp) · scale` — an *arithmetic formula* |
| **Palettization** | integer **indices** + a **palette** of `2^n_bits` centroids | everything except which cluster a weight belongs to | `x ≈ LUT[index]` — a **table lookup** |
| **Pruning** | a binary **mask** + the surviving weights | entire weights, set exactly to zero | `x' = x · mask` — nothing to reconstruct |

The crucial difference between the first two is *where the compression error comes from*.
Quantization imposes a **uniform grid** whether or not your weights are uniformly distributed —
and neural-network weights are famously not; they are heavy-tailed and clustered near zero. Every
grid point in the tails is a grid point wasted. Palettization runs **k-means** on the weights you
actually have and puts its centroids where the mass is.

This is why, at the same nominal bit-width, the two techniques do not produce the same error. See
§17.1 for a community measurement of exactly how large that gap is at per-channel granularity.

The API surface is deliberately parallel, which session 325 says out loud:

> ✅ **VERIFIED** — WWDC26 session 325, *"Dive into Core AI model authoring and optimization"*,
> 325:243–244:
> *"As before, I **construct a `KMeansPalettizer` similar to the `Quantizer`**, and pass it the
> **model and config**. Then, I **prepare and finalize**."*

That parallel is real and it is enforced by a shared base class:

> ✅ **VERIFIED** — `src/coreai_opt/base_model_compressor.py`. `Quantizer`, `KMeansPalettizer` and
> `MagnitudePruner` all derive from `_BaseModelCompressor` and all implement
> `__init__(model, config)` → `prepare(...)` → `finalize(...)`. `calibration_mode()` and
> `training_mode()` are optional and raise `NotImplementedError` on compressors that do not support
> them, with the message
> `"{cls} does not implement training_mode(). This compressor doesn't support training time compression."`

The capability matrix is where they stop being parallel:

| | `Quantizer` | `KMeansPalettizer` | `MagnitudePruner` |
|---|---|---|---|
| Execution modes | **GRAPH** (default) and EAGER | **EAGER only** | **EAGER only** |
| Weights | ✅ | ✅ | ✅ |
| Activations | ✅ | ✗ (weight-only, enforced) | ✗ (weight-only, enforced) |
| `calibration_mode()` | ✅ (activation ranges) | ✅ (**different meaning** — sensitivities, §8) | ✗ |
| `training_mode()` / QAT | ✅ | ✗ | ✗ (but see §11.5) |
| `step()` | ✅ (QAT schedule) | ✗ | ✅ (**sparsity** schedule) |
| `mmap_dir` on `finalize` | ✅ (EAGER + CoreAI only) | ✅ (CoreAI only) | ✗ |
| Presets | `w8` `w4` `w4_per_block` | `w4` `w6` `w8` | **none** |

> ✅ **VERIFIED** — the eager-only constraint for palettization is stated in the docs
> (`docs/src/palettization/config.md:119`): *"Palettization supports eager mode only."* It is not a
> soft preference; there is no `_graph/` directory under `palettization/` or `pruning/`, only
> `quantization/_graph/`.

The practical consequence of "eager only" is that palettization uses PyTorch's
`__torch_function__` protocol to intercept ops rather than `torch.export` + torchao PT2E. That
means it **tolerates dynamic control flow** that would break graph mode, but it also means it gets
none of graph mode's conveniences: no Conv+BN folding, no shared-observer logic, and op names in
your config are **module-qualified call sites** (`linear1.linear`) rather than global aten node
names (`linear_1`). If you inspect a model to find names for a config, inspect it in the mode you
will compress in. Guide 01 §13 covers `ModelInspector`.

### 1.2 Why lookup tables suit the Neural Engine

Session 325's justification is one sentence, and it names iOS specifically:

> ✅ **VERIFIED** — WWDC26 session 325, 325:241–242:
> *"For compression, I apply **4-bit palettization with per-channel scales** to the two encoders.
> **There is a preset available for this, but I use the lower-level representation here to showcase
> the APIs.** This **lookup-table-based compression, is well-suited for power efficiency on iOS**."*

(The "with per-channel scales" clause in that quote is contradicted by the shipped code. §5 is
about that contradiction, which turns out to be the most useful thing in this guide.)

Apple does not explain *why* on stage. The reason is legible from the Neural Engine's documented
constraints, which are written down in Apple's own `model-authoring` agent skill:

> ✅ **VERIFIED** — `skills/skills/model-authoring/references/neural_engine_rules.md`, vendored in
> `apple/coreai-models`: the Neural Engine's supported dtypes are **fp16 / int8 / int16**, and
> **fp32 falls back to GPU/CPU**. Max tensor rank is **5**. Shapes must be **fully static**. The
> last axis must be contiguous and **64-byte aligned**.

Put those together and the argument writes itself:

1. **The ANE is a fixed-function engine.** It runs a closed set of hardware ops — convolution,
   normalisation, pooling, elementwise — and cannot execute arbitrary code. Any weight format it
   supports has to be one the hardware knows how to expand.
2. **The ANE runs fp16 compute.** Whatever format your weights are stored in, they arrive at the
   MAC arrays as fp16. So the question is never "can the engine do 4-bit arithmetic" — it is
   "how cheaply can the engine turn 4 stored bits into an fp16 value".
3. **A table lookup is the cheapest possible answer.** `LUT[index]` is an indexed read from a tiny
   table that fits in local memory. There is no multiply, no add, no zero-point subtraction. A
   blockwise-affine dequantisation needs a multiply and (if asymmetric) a subtract per weight, plus
   a scale tensor streamed alongside the weights.
4. **Inference at this scale is memory-bandwidth-bound, not compute-bound.** Session 330 says so
   directly: ✅ **VERIFIED** — WWDC26 session 330, 330:21–23: *"state-of-the-art machine learning
   models are getting larger. **The inference stage is typically memory bandwidth bound**, so
   compressing the weights becomes necessary **both to better fit models into memory and to save
   memory bandwidth**."* Fewer bytes read is less DRAM traffic is less energy. That is what "power
   efficiency" means here — it is not a figure of speech.

There is corroborating evidence from a source that is not Apple's marketing: the community
model zoo's own rule of thumb.

> 🟢 **COMMUNITY-MEASURED** — `notes/repos/john-rocky-models.md`, single-author archive with
> self-declared uncontrolled benchmarks; treat as a strong hint, not a specification:
> *"statically-compiled ANE execution requires palettized (LUT) weights — blockwise-linear int4 is a
> GPU-only format there. If you aren't explicitly targeting ANE, target GPU and move on."*

If that is right — and it is consistent with everything Apple ships — then the choice between
quantization and palettization is **not primarily a quality choice. It is a compute-unit choice.**
Which is exactly how Apple's own export tooling treats it.

### 1.3 The strongest evidence: Apple's shipped presets split by platform

The `apple/coreai-models` LLM exporter has two preset families, and they do not overlap.

> ✅ **VERIFIED** — `python/src/coreai_models/export/presets.py`:
> ```python
> DEFAULT_MACOS_COMPRESSION_PRESET = "4bit"
> DEFAULT_IOS_COMPRESSION_PRESET   = "4bit_weight_palettized_group32"
> ```
> **macOS** `MACOS_PRESETS`: `"none"`, `"4bit"` — where `4bit` is a **quantization** config
> (`int4`, `symmetric_with_clipping`, `per_block` `block_size=32` `axis=1`).
> **iOS** `IOS_PRESETS`: `"none"`, `"4bit_weight_palettized_group8"`,
> `"4bit_weight_palettized_group32"` — both **palettization** configs
> (`{"n_bits": 4, "granularity": {"type": "per_grouped_channel", "axis": 0, "group_size": 8 or 32}}`).

And the CLI enforces the split rather than merely defaulting to it:

> ✅ **VERIFIED** — `python/src/coreai_models/llm/export.py`, `_resolve_export_config`
> (export.py:263-368). Passing the wrong family raises:
> `RuntimeError("macOS quantization preset provided, but platform is iOS.")` and
> `RuntimeError("iOS palettization preset provided, but platform is macOS.")`.
> The YAML loader (`_load_compression_config_object`, export.py:163-237) applies the same rule to
> hand-written configs: a file whose top-level key is **`kmeans_palettization_config` requires
> `--platform iOS`**; one whose top key is **`quantization_config` requires `--platform macOS`**.

That is not a style guide. That is Apple's production LLM exporter refusing to build a palettized
macOS bundle or a quantized iOS bundle. Take the hint.

### 1.4 Where palettization sits in the pipeline

Identical to quantization — it is an optional stage that consumes an `nn.Module` and produces an
`nn.Module`, inserted before conversion:

```
                     ┌──────────────────────── you are here ────────────────────────┐
nn.Module ──►  re-author  ──►  KMeansPalettizer(model, config)                       │
              (Part 10)         .prepare(example_inputs)      ← k-means runs HERE     │
                                .finalize(backend=CoreAI)     ← weights freed HERE    │
                     └─────────────────────────────────────────────────────────────┘
          ──►  torch.export(...).run_decompositions(coreai_torch.get_decomp_table())
          ──►  cast_to_16_bit_precision(exported_program)      ← compress FIRST, cast SECOND
          ──►  coreai_torch.TorchConverter().add_exported_program(...).to_coreai()
          ──►  ai_program.optimize()  ──►  ai_program.save_asset("model.aimodel")   (Part 8)
```

The property that makes this workable is that **every compressor output is itself a PyTorch
model**. You can score a palettized model in PyTorch, on your own eval harness, before you have
converted anything. Apple's docs make the stronger point that for evaluation you should not
finalize at all:

> ✅ **VERIFIED** — `KMeansPalettizer.finalize` docstring: *"**Only call `finalize` when exporting to
> a target backend.** For torch-based evaluation, **use the model returned by `prepare()` directly**
> rather than calling `finalize`."*
> Apple's compression-exploration agent skill repeats this as an operational rule: *"Do **not** call
> `finalize()`"* during a sweep, *"Calibration is not needed for weight-only compression."*
> (`skills/skills/model-compression-exploration/SKILL.md`.)

That is not a stylistic preference either — see §10.2 for what `finalize()` does to your weights.

---

## 2. The palettizer in eight lines

### 2.1 The minimum viable palettization

```python
import copy
import torch
import torch.nn as nn

from coreai_opt import ExportBackend
from coreai_opt.palettization import KMeansPalettizer, KMeansPalettizerConfig

model = MyModel().eval()
float_model = copy.deepcopy(model)                 # prepare() mutates in place — see §2.4
example_inputs = (torch.randn(1, 3, 224, 224),)    # MUST be a tuple; shape-correct is enough

config = KMeansPalettizerConfig.presets.w4()       # 4-bit, per-grouped-channel, axis 0, group 16
palettizer = KMeansPalettizer(model, config)

prepared = palettizer.prepare(example_inputs, num_workers=8)   # k-means runs here
score(prepared)                                                # evaluate in PyTorch, before export

finalized = palettizer.finalize(backend=ExportBackend.CoreAI)  # default backend; destructive
```

> ✅ **VERIFIED** — exact signatures, `src/coreai_opt/palettization/kmeans/palettizer.py`:
> ```python
> class KMeansPalettizer(_BasePalettizer, _EagerCompressionComponentBuilderMixin):
>     def __init__(self, model: nn.Module, config: KMeansPalettizerConfig | None = None)
>
>     def prepare(self,
>                 example_inputs: tuple[torch.Tensor],
>                 sensitivity_path: str | None = None,
>                 num_workers: int = 1) -> nn.Module
>
>     @contextmanager
>     def calibration_mode(self, model=None, *, loss_fn: Callable,
>                          sensitivity_path: str | None = None)
>
>     def finalize(self, model: nn.Module | None = None,
>                  backend: ExportBackend = ExportBackend.CoreAI,
>                  *, mmap_dir: str | PathLike[str] | None = None) -> nn.Module
>
>     def save_sensitivities(self, path: str) -> None
>
>     @classmethod
>     def get_op_type_resolver(cls) -> Callable[[Callable], str | None]
> ```

Three things about that signature list are worth pausing on, because they differ from `Quantizer`:

1. **`num_workers` is a `prepare()` parameter, not a config field.** It is the single biggest
   wall-clock lever in the whole palettization workflow and session 325 never mentions it. §7.2.
2. **`sensitivity_path` appears in `prepare()` *and* `calibration_mode()`.** These are the two ends
   of the same feature: `calibration_mode()` writes the file, `prepare()` reads it. §8.
3. **There is no `training_mode()` and no `step()`.** Palettization is a post-training technique in
   this package, full stop. If your 4-bit palettized model has lost too much quality, your options
   are a coarser bit-width, a finer group size, sensitivity weighting, mixed precision, or moving to
   QAT-based **quantization** instead — not palettization-aware training.

> 🔴 **GAP — palettization-aware fine-tuning.** `_BasePalettizer` does not implement
> `training_mode()`, so a call raises `NotImplementedError` with the base-class message. Whether
> Apple intends to add differentiable palettization (the `coremltools.optimize.torch` lineage had a
> `DKMPalettizer`) is **not stated anywhere in the repo, the changelog, or any session**. What would
> resolve it: a `training_mode()` implementation under `palettization/`, or a changelog entry.
> **Safe default meanwhile:** if you need trained low-bit weights, use `Quantizer` + `QATSchedule`
> (guide 01 §11) and accept the affine format, or keep palettization at ≥ 6 bits where PTQ is
> comfortable.

### 2.2 The preset roster, and what `w4()` expands to

> ✅ **VERIFIED** — `src/coreai_opt/palettization/config/_presets/kmeans_palettizer_config.py` and
> `module_kmeans_palettizer_config.py`. The same three presets exist on both
> `KMeansPalettizerConfig.presets` and `ModuleKMeansPalettizerConfig.presets`:

| Preset | Signature | Resulting `PalettizationSpec` |
|---|---|---|
| `w4` | `w4(*, axis: int = 0, group_size: int = 16)` | `n_bits=4`, `PerGroupedChannelGranularity(axis=axis, group_size=group_size)` |
| `w6` | `w6(*, axis: int = 0, group_size: int = 16)` | `n_bits=6`, `PerGroupedChannelGranularity(axis=axis, group_size=group_size)` |
| `w8` | `w8()` | `n_bits=8`, `PerTensorGranularity()` |

Applied to **both** the `"weight"` and `"in_proj_weight"` state keys (see §2.5).

Note what is *not* here. There is no `w2`, no `w1`, no `w3`, no vector-palettization preset, and no
preset that sets `lut_qspec` or `enable_per_channel_scale`. Everything below 4 bits, everything
involving `cluster_dim`, and everything involving joint compression, you build by hand.

Note also the asymmetry between `w4`/`w6` and `w8`: the two low-bit presets default to
**per-grouped-channel** granularity, while `w8` is **per-tensor**. That is a considered choice —
at 8 bits a single 256-entry palette for a whole tensor is usually fine and the LUT overhead of
per-channel palettes would be significant; at 4 bits a single 16-entry palette for a whole tensor
is usually not fine. §6 has the arithmetic.

`presets.w4()` expanded by hand, so you can see every field it sets:

```python
from coreai_opt.palettization import (
    KMeansPalettizerConfig, ModuleKMeansPalettizerConfig, PalettizationSpec,
)
from coreai_opt.palettization.spec import PerGroupedChannelGranularity

spec = PalettizationSpec(
    n_bits=4,                                                       # palette = 2**4 = 16 entries
    lut_qspec=None,                                                 # fp LUT (default)
    granularity=PerGroupedChannelGranularity(axis=0, group_size=16),
    cluster_dim=1,                                                  # scalar k-means
    enable_per_channel_scale=False,                                 # ← see §5 before changing this
)

config = KMeansPalettizerConfig(
    global_config=ModuleKMeansPalettizerConfig(
        op_state_spec={"weight": spec, "in_proj_weight": spec},
        enable_fast_kmeans_mode=True,                               # default; §7.3
        rounding_precision=4,                                       # default; §7.3
    ),
)
```

That is *equivalent to* `KMeansPalettizerConfig.presets.w4()` in effect. Whether the preset
literally constructs it this way is an implementation detail; the spec fields and the two state
keys are ✅ verified from the preset source and from `OpKMeansPalettizerConfig.get_default_state_spec`.

### 2.3 The vendored `_kmeans1d` dependency, and why your build box needs a compiler

This is the part of the install that surprises people, so it gets its own section.

> ✅ **VERIFIED** — changelog fragment `changelog.d/31.changed`, landed in commit `edd4720`:
> *"Replace the coremltools-based 1D k-means used by palettization with a vendored C++ core that is
> JIT-compiled at runtime via `torch.utils.cpp_extension`. `coremltools` is no longer a runtime
> dependency (it is now an optional dependency, installable via the `coreml` extra). **This requires
> a C++ compiler to be available on the host at runtime.**"*

> ✅ **VERIFIED** — `src/coreai_opt/deps/_kmeans1d/` contains `core.py` + `_core.cpp`. The JIT load
> happens at `core.py:30-55` via `torch.utils.cpp_extension.load()` with flags
> `["-std=c++11", "-O2", "-DNDEBUG"]`, plus `-stdlib=libc++` on darwin. `ninja>=1.11` and
> `setuptools>=42` are declared as **runtime** dependencies in `pyproject.toml:51-62` precisely
> because of this.

The vendored library is MIT-licensed `kmeans1d`. The reason a *specialised* 1-D k-means exists at
all is worth knowing: clustering scalars is not the general k-means problem. In one dimension the
optimal clustering can be computed exactly by dynamic programming rather than approximated by
Lloyd's algorithm, which is both faster and **deterministic**. That determinism is a property you
inherit — and lose the moment you set `cluster_dim > 1` and move to genuine multi-dimensional
k-means (§7.1).

Practical consequences:

- **First palettization in a fresh environment pays a compile.** It is a one-time cost per
  environment, cached by `torch.utils.cpp_extension`. In CI, expect the first palettization job to
  be slower than the rest and do not mistake it for a hang.
- **A container without build-essential / Xcode CLT will fail at `prepare()`**, not at
  `pip install`. If you are baking a Docker image for a compression pipeline, install a compiler.
- **Quantization-only workflows never hit this**, which is why teams that quantize for months and
  then try palettization once get a confusing failure on a box they thought was working.

```bash
# macOS
xcode-select --install
# Debian/Ubuntu
apt-get install -y build-essential
```

### 2.4 `prepare()` mutates in place, and eager mode makes that worse

Shared with quantization, but sharper here.

> ✅ **VERIFIED** — the compressor lifecycle doc (`docs/src/introduction/how_to_use_coreaiopt.md`)
> and `_BaseModelCompressor`: `prepare()` "may modify in place — use the returned model". Re-preparing
> raises `RuntimeError("Model has already been prepared. Cannot re-prepare a prepared model.")`.

In **eager** mode — which is the only mode palettization has — compression is implemented with
**PyTorch parametrizations** registered on the module in place. The consequence is blunt: after
`prepare()`, reading `.weight` on **either** the original object **or** the returned object gives
you the fake-palettized value, because they are the same object. If you want the float weights for
a comparison, `copy.deepcopy` the model **before** `prepare()`, or save the tensors you care about.

```python
float_model = copy.deepcopy(model)          # do this FIRST
prepared = KMeansPalettizer(model, config).prepare(example_inputs)
# model is prepared is True (same object). float_model still has dense weights.
```

`prepare()` also handles train/eval mode for you on the way in and not on the way out:

> ✅ **VERIFIED** — `docs/src/introduction/how_to_use_coreaiopt.md:39,79`: *"You don't need to put the
> model in `.eval()` or `.train()` before calling `prepare()` — the API runs the trace internally in
> eval mode and restores the original mode when it returns."* and *"The finalized model inherits the
> current training mode, so **call `.eval()` on it** before running inference or downstream
> conversion."*

### 2.5 The two default state keys, and the weight-only enforcement

> ✅ **VERIFIED** — `src/coreai_opt/palettization/config/palettization_config.py`:
> ```python
> class OpKMeansPalettizerConfig(WeightOnlyOpValidationMixin, OpCompressionConfig[PalettizationSpec]):
>     @classmethod
>     def get_default_state_spec(cls):
>         spec = default_weight_palettization_spec()
>         return {"weight": spec, "in_proj_weight": spec}
> ```

`"in_proj_weight"` is `nn.MultiheadAttention`'s fused QKV parameter. If you write your own
`op_state_spec` and only list `"weight"`, you will silently leave every `nn.MultiheadAttention` in
your model uncompressed — a large omission in a transformer. Copy both keys.

The weight-only nature is enforced by validation, not by convention:

> ✅ **VERIFIED** — `WeightOnlyModuleValidationMixin` / `WeightOnlyOpValidationMixin` raise
> `ValueError` if you set `op_input_spec`, `op_output_spec`, `module_input_spec` or
> `module_output_spec`:
> *"{cls} does not support {key}. This is a weight-only compression type that only supports
> `op_state_spec` and `module_state_spec`."*

So the *only* way to combine palettized weights with quantized activations is joint compression
(§13). There is no single config that expresses both.

### 2.6 Which ops are palettizable

> ✅ **VERIFIED** — `src/coreai_opt/palettization/kmeans/supported_ops_registry.py`
> (`_KMeansPalettizerSupportedOpsRegistry`), registry key → torch function:
>
> | key | function |
> |---|---|
> | `conv1d` / `conv2d` / `conv3d` | `F.conv1d` / `F.conv2d` / `F.conv3d` |
> | `conv_transpose1d` / `conv_transpose2d` / `conv_transpose3d` | `F.conv_transpose1d` / `2d` / `3d` |
> | `linear` | `F.linear` |
> | `multi_head_attention_forward` | `F.multi_head_attention_forward` |
>
> **`ConvTranspose1d/2d/3d` support was added in 0.2.1** (CHANGELOG). The registry's `register`
> decorator validates at runtime that the registered class subclasses `_PalettizationSupportMixin`,
> raising `TypeError` otherwise.

Read that list for what it excludes: **`F.embedding` is not on it.** Neither is any gather, any
normalisation parameter, any bias, and nothing you wrote by hand as raw tensor arithmetic.

This has two important consequences.

**One: your norm and RoPE parameters stay full precision automatically.** That is usually what you
want, and it means you do not need `.without(nn.LayerNorm, nn.RMSNorm)`-style exclusions the way you
do with quantization. A community formulation of the same observation:

> 🟢 **COMMUNITY-MEASURED** — `notes/repos/john-rocky-models.md`: *"k-means palettizes
> `F.linear`/`F.conv` weights only, so RMSNorm/RoPE params stay full precision automatically."*

**Two: embedding tables are your problem.** In a modern LLM the embedding / `lm_head` matrix is
frequently the single largest tensor in the model, and palettization cannot touch it. Apple's own
iOS exporter handles this by explicitly excluding embeddings from the palettization config and
quantizing them separately:

> ✅ **VERIFIED** — `python/src/coreai_models/export/presets.py`: both iOS palettization presets
> exclude `torch.nn.modules.sparse.Embedding` and
> `coreai_models.primitives.ios.embedding.LoadEmbeddings`. And from `models/README.md:54`:
> **"All `iOS` palettization presets quantize the Embedding to 8-bit per tensor by default."** The
> implementation is `quantize_per_tensor` in `primitives/ios/quantization.py` — symmetric,
> **`nbits=8` only**, `scale = max|x| / 127`, with the scale clamped to a minimum of `1e-6`. The
> exporter exposes `--disable-embedding-quantization-ios` to keep the embedding in float32.

That is the pattern to copy: **palettize the projections, quantize the embedding, and account for
the embedding separately in your bits-per-weight arithmetic.** Note that the published BPW figures
for Apple's iOS models carry an asterisk for exactly this reason — see §20.


---

## 3. `PalettizationSpec`: five fields, and what each one costs

`QuantizationSpec` has nine fields. `PalettizationSpec` has five, and every one of them changes the
shape of the artefact you ship.

> ✅ **VERIFIED** — `src/coreai_opt/palettization/spec/spec.py:86-93`:
> ```python
> class PalettizationSpec(CompressionSpec):     # pydantic BaseModel, frozen=True, extra="forbid"
>     n_bits: Literal[1, 2, 3, 4, 6, 8] = 4
>     lut_qspec: QuantizationSpec | None = None
>     granularity: PalettizationGranularity = PerTensorGranularity()
>     cluster_dim: PositiveInt = 1
>     enable_per_channel_scale: bool = False
> ```
> And the factory (`default_weight_palettization_spec()`) returns exactly those defaults:
> `n_bits=4, lut_qspec=None, PerTensorGranularity(), cluster_dim=1, enable_per_channel_scale=False`.

Note `frozen=True, extra="forbid"`, inherited from `CompressionSpec`. You cannot mutate a spec after
construction and you cannot typo a field name — `PalettizationSpec(nbits=4)` raises rather than
silently doing nothing. To vary one field, use pydantic's `model_copy`:

```python
base = PalettizationSpec(n_bits=4, granularity=PerGroupedChannelGranularity(axis=0, group_size=32))
six_bit = base.model_copy(update={"n_bits": 6})
```

### 3.1 `n_bits` — six legal values, and two conspicuous absences

> ✅ **VERIFIED** — `Literal[1, 2, 3, 4, 6, 8]`. Docstring: *"Number of bits used for palette
> indices. Determines palette size (2^n_bits entries). **Must be one of {1, 2, 3, 4, 6, 8}**."*

**There is no 5 and no 7.** This trips people building sweep scripts who assume `range(1, 9)`. The
same set appears at the program level (`_VALID_N_BITS = {1,2,3,4,6,8}` in
`coreai_utils/passes/weight_palettization.py`) and in `sparsify_weights`' `palettize_nbits`
argument, so it is a format-level constraint, not a validation quirk of one entry point.

The palette size is `2**n_bits`:

| `n_bits` | palette entries | index storage | typical use |
|---|---|---|---|
| 1 | 2 | 1 bit/weight | research / binary nets. Expect catastrophic quality. |
| 2 | 4 | 2 bits/weight | ~8× compression. Apple's skill calls the quality *"usually unacceptable"* — §16. |
| 3 | 8 | 3 bits/weight | rare; useful only as a mixed-precision floor for insensitive layers |
| **4** | **16** | **4 bits/weight** | **the default and the one Apple ships on iOS** |
| 6 | 64 | 6 bits/weight | the safety valve when 4 is not enough. SAM3's text encoder uses this. |
| 8 | 256 | 8 bits/weight | ~2× compression, near-lossless for most vision models |

### 3.2 `granularity` — two classes, not three

Quantization has three granularity classes. Palettization has two.

> ✅ **VERIFIED** — `coreai_opt.palettization.spec.__all__` =
> `PalettizationGranularity, PalettizationSpec, PerGroupedChannelGranularity, PerTensorGranularity,
> default_weight_palettization_spec`. Registry keys (used in YAML): `"per_tensor"`,
> `"per_grouped_channel"`.
> ```python
> class PerGroupedChannelGranularity(PalettizationGranularity):
>     axis: int | None = Field(default=None, ge=0, le=1)
>     group_size: int
> ```
> `num_blocks_to_cluster = weight.shape[axis] // group_size`. Raises the internal
> `_IncompatibleGranularityError` if `axis` is `None` or out of range, or if the shape is not
> divisible by `group_size`.

Two things to notice.

**`axis` is constrained to 0 or 1.** `Field(ge=0, le=1)`. You cannot palettize per-group along a
spatial axis of a conv kernel. Axis 0 is the output-channel axis for `Conv*` and `Linear`; axis 1 is
the input-channel axis. Apple's shipped iOS presets and Apple's SAM3 recipe both use **`axis=0`**.

**There is no `PerChannelGranularity`** — but you can express it. `group_size=1` gives
`shape[0] // 1 == shape[0]` groups, i.e. one palette per channel. That is arithmetic from the
verified formula, not a separate API. And it is what the community found works best:

> 🟢 **COMMUNITY-MEASURED** — `notes/repos/john-rocky-models.md`, single-author archive,
> uncontrolled benchmarks: *"**Per-channel (group_size=1) basically always wins**; at per-channel,
> k-means beats quantization by **~15–19 dB** at both 8-bit and 4-bit. Per-tensor palettization can
> be **worse** than per-channel quantization."*
> ⚠️ Note the cost side, which that quote omits: one LUT per output channel is a lot of LUT. §6.3
> does the arithmetic, and it is why Apple's own presets use `group_size=8` / `16` / `32` rather than
> `1`.

⚠️ **Import hazard.** `PerTensorGranularity` exists **twice** with the same spelling:
`coreai_opt.quantization.spec.PerTensorGranularity` and
`coreai_opt.palettization.spec.PerTensorGranularity`. They are different classes and they are not
interchangeable. If you import the wrong one into a `PalettizationSpec`, pydantic will reject it;
if you import the wrong one into `lut_qspec` (which takes a *quantization* spec), validation raises
`ValueError`. Prefer qualified imports in any file that touches both:

```python
from coreai_opt.palettization.spec import PerTensorGranularity as PalettPerTensor
from coreai_opt.quantization.spec import PerTensorGranularity as QuantPerTensor
```

### 3.3 `cluster_dim` — the fractional-bit lever

> ✅ **VERIFIED** — docstring: *"The dimension of centroids for each lookup table... When
> `cluster_dim > 1`, it indicates **2-D clustering**, and each `cluster_dim` length of weight vectors
> along the output channel are palettized using the same 2-D centroid."*
> Arithmetic from `docs/src/palettization/basics.md:16`: `n_bits=4, cluster_dim=2` ⇒ k-means on
> 2-D data with 16 centroids, LUT shape `16×2`, **effective bits per weight = 4/2 = 2**.

This is the only way to get below 1 bit per stored index without going to `n_bits=1`, and it is
covered in detail in §4.3. Two hard constraints:

> ✅ **VERIFIED** — `enable_fast_kmeans_mode=True` (the default) with `cluster_dim > 1` raises
> `ValueError("enable_fast_kmeans_mode is not supported when cluster_dim > 1. ...")`. You must set
> `enable_fast_kmeans_mode=False`.
> ✅ **VERIFIED** — at the program level, `palettize_weights(..., enable_per_channel_scale=True,
> cluster_dim>1)` raises `ValueError`. The two features do not compose.

### 3.4 `enable_per_channel_scale` — the field with the trap

> ✅ **VERIFIED** — docstring: *"When set to True, **weights are normalized along the output channels
> using per-channel scales before being palettized**."*

The idea is sound and standard: if channel A's weights span ±0.01 and channel B's span ±3.0, a
single shared palette wastes almost all its entries. Normalise each channel to a common range first,
palettize the normalised weights, and store one fp16 scale per channel to undo it at runtime.

The default is `False`. **Leave it `False` if you are targeting the Neural Engine.** §5 is entirely
about why, and it is the most important section in this guide.

### 3.5 `lut_qspec` — quantizing the palette

> ✅ **VERIFIED** — `_SUPPORTED_LUT_DTYPES = {torch.int8, torch.uint8, torch.float8_e4m3fn,
> torch.float8_e5m2}`. `validate_lut_qspec` raises `ValueError` if the LUT dtype is not in that set,
> if `lut_qspec.granularity` is not the **quantization** `PerTensorGranularity`, or if
> `lut_qspec.qformulation == MINVAL` (*"Use `lut_qspec.qformulation=ZP` instead."*). FP8 dtypes
> additionally require symmetric quantization.

Covered in §9. Short version: quantizing the LUT is what unlocks the integer execution path, and it
is mandatory for joint compression to be worth doing.

### 3.6 The two module-level fields that are not on the spec

Two knobs live on `ModuleKMeansPalettizerConfig` rather than on `PalettizationSpec`, because they
control the *clustering process* rather than the *format*:

> ✅ **VERIFIED** — `src/coreai_opt/palettization/config/palettization_config.py`:
> ```python
> class ModuleKMeansPalettizerConfig(WeightOnlyModuleValidationMixin,
>                                    ModuleCompressionConfig[OpKMeansPalettizerConfig, PalettizationSpec]):  # @final
>     enable_fast_kmeans_mode: bool = True
>     rounding_precision: PositiveInt = 4
> ```
> `enable_fast_kmeans_mode` docstring: *"enables optimizations for faster K-means clustering by
> **rounding the weights before clustering** if data is in float16 range. If weight dtype is float32,
> weights are **cast to float16 and then rounded**."* `rounding_precision` is the number of decimal
> places, default 4.

§7.3 covers when to turn that off.

### 3.7 The config hierarchy is the same one you already know

`KMeansPalettizerConfig` uses the identical three-level machinery as `QuantizerConfig` — because
it is literally the same generic base class, `CompressionConfig[...]`.

> ✅ **VERIFIED** — `src/coreai_opt/palettization/config/palettization_config.py`:
> ```python
> class KMeansPalettizerConfig(CompressionConfig[ModuleKMeansPalettizerConfig]):   # @final
>     _CONFIG_KEY = "kmeans_palettization_config"
>     _SPEC_KEY   = "palettization_spec"
> ```

Everything guide 01 §4–§5 says applies unchanged:

- Precedence: **`module_name_configs` > `module_type_configs` > `global_config`**.
- `module_name_configs` keys are regexes matched with **`re.fullmatch`**. `"detector"` does not
  match `"detector.decoder.linear"`; `"detector.*"` does.
- `module_type_configs` keys must be **fully-qualified** class names
  (`"torch.nn.modules.linear.Linear"`), or the class object itself. `"torch.nn.Linear"` raises
  `ValueError(f"Expected fully-qualified name, got {module_type}")`.
- **`None` means "leave this alone."** Omitting a field applies defaults; explicitly passing `None`
  disables compression for that scope. This is the mechanism for "compress everything except X".
- `only_for(...)` / `without(...)` chainable helpers exist and return `Self`. `only_for` cannot be
  called twice.
- `KMeansPalettizerConfig` and `ModuleKMeansPalettizerConfig` are `@final` and raise `TypeError` on
  subclassing.
- YAML: `KMeansPalettizerConfig.from_yaml(path)` / `.from_dict({...})`, top-level key
  **`kmeans_palettization_config`**, with `palettization_spec` available as an anchor host.

The two mechanisms you will actually reach for:

```python
# Compress everything EXCEPT the detector subtree (the SAM3 move — guide 01 §13)
config = KMeansPalettizerConfig.presets.w4(group_size=32)
config.set_module_name("detector.*", None)

# Or: compress ONLY the two encoders, nothing else
config = (KMeansPalettizerConfig.presets.w4(group_size=32)
          .only_for("image_encoder.*", "text_encoder.*"))
```

> ✅ **VERIFIED** — `only_for` semantics (`config/compression_config.py`): it disables
> `global_config` and deep-copies it onto each target. Calling it twice raises
> `ValueError("only_for requires a non-disabled global_config to redistribute as per-module
> overrides. If you've already called only_for or set_global(None), pass all targets in one
> only_for(...) call instead of chaining.")`

---

## 4. The three schemes, with diagrams

The `coreai-opt` docs give each scheme a diagram. Here they are as ASCII, with the tensor shapes
made explicit, because the shapes are what determine whether the ANE will take your model.

Throughout: a `Linear` weight `W` of shape `[C_out, C_in] = [512, 1024]`, so 524,288 weights, and
`n_bits = 4` (palette size 16).

### 4.1 Scheme 1 — scalar palettization, per tensor

`PerTensorGranularity()`, `cluster_dim=1`.

```
        W  [512, 1024]  fp16                        ONE palette for the whole tensor
   ┌──────────────────────────────┐
   │ 0.31 -0.02  0.88  ...        │      k-means(k=16) over all 524 288 scalars
   │ 0.29  0.44 -0.51  ...        │   ─────────────────────────────────────────►
   │  ...                         │
   └──────────────────────────────┘
                                          LUT [1, 1, 16, 1]      indices [512, 1024] × 4 bits
                                          ┌─────────────────┐    ┌──────────────────────┐
                                          │ c0  -0.83       │    │  9  4 14  ...        │
                                          │ c1  -0.61       │    │  9 11  2  ...        │
                                          │ ...             │    │  ...                 │
                                          │ c15  0.79       │    └──────────────────────┘
                                          └─────────────────┘
   reconstruct:  W'[i,j] = LUT[ indices[i,j] ]
```

Storage: `524288 × 4 / 8 = 262,144 B` of indices, plus `16 × 2 = 32 B` of LUT. Against 1,048,576 B
of fp16, that is **3.999× compression**. The LUT is free, numerically speaking.

And that is the problem. Sixteen numbers have to represent every weight in the layer. If the
distribution is bimodal, or if a handful of channels have a very different dynamic range from the
rest, those sixteen centroids get pulled apart and everything suffers.

This is the `presets.w8()` scheme (with 256 entries, where it works well) and the scheme you should
**not** use at 4 bits without measuring.

### 4.2 Scheme 2 — scalar palettization, per grouped channel

`PerGroupedChannelGranularity(axis=0, group_size=G)`, `cluster_dim=1`. This is `presets.w4()` and
`presets.w6()`, and it is what Apple ships for iOS.

With `axis=0, group_size=128` on our `[512, 1024]` weight: `512 // 128 = 4` groups, so **four
independent palettes**, each fitted to a 128-row slab.

```
        W  [512, 1024]                                 FOUR palettes, one per row-group
   ┌──────────────────────────────┐
   │ rows   0..127   (group 0)    │ ──► k-means(k=16) ──► LUT[0] : 16 centroids
   ├──────────────────────────────┤
   │ rows 128..255   (group 1)    │ ──► k-means(k=16) ──► LUT[1] : 16 centroids
   ├──────────────────────────────┤
   │ rows 256..383   (group 2)    │ ──► k-means(k=16) ──► LUT[2] : 16 centroids
   ├──────────────────────────────┤
   │ rows 384..511   (group 3)    │ ──► k-means(k=16) ──► LUT[3] : 16 centroids
   └──────────────────────────────┘

   LUT tensor  [4, 1, 16, 1]        indices [512, 1024] × 4 bits
   reconstruct: W'[i,j] = LUT[ i // 128, 0, indices[i,j], 0 ]
```

Storage: 262,144 B of indices + `4 × 16 × 2 = 128 B` of LUT. Still ~3.998× — the LUT overhead is
noise at this group size.

Now push it: `group_size=16` gives `512 // 16 = 32` palettes → `32 × 16 × 2 = 1,024 B`. Still noise.
`group_size=1` gives 512 palettes → `512 × 16 × 2 = 16,384 B`, which is 6.25% on top of the indices.
That is the point at which "per-channel always wins" starts costing you real bytes — and at 8 bits
it gets much worse, because each palette is 256 entries:

> ✅ **VERIFIED** — Apple's compression-exploration skill states this as a pitfall verbatim:
> *"8-bit per-channel LUT stores 256 × fp16 entries per output channel"* and *"scale/ZP overhead
> 5-15% at 2-4 bit fine granularity"*, and *"at `block_size=16` + int4 the effective width is
> ~5 bits."* (`skills/skills/model-compression-exploration/SKILL.md`.)

⚠️ **The divisibility rule bites here.** `shape[axis] % group_size` must be `0`. `512 % 128 == 0` is
fine; `1000 % 16 != 0` is not, and the failure mode is not an exception — see §19.1.

### 4.3 Scheme 3 — vector palettization

`cluster_dim = D > 1`. This is the scheme that gets you fractional bits per weight, and it is the
one nobody presented.

Instead of clustering scalars, you cluster **contiguous D-length vectors along the output-channel
axis**, and each cluster centroid is itself a D-vector. One index now addresses D weights.

With `n_bits=4, cluster_dim=2` on our `[512, 1024]` weight:

```
   W [512, 1024]           pair up along the output-channel axis
   ┌───────────────────┐
   │ row 0  ─┐         │        each 2-vector  (W[0,j], W[1,j])  is one data point
   │ row 1  ─┘ pair    │   ───► k-means in ℝ²  with k = 2**4 = 16 centroids
   │ row 2  ─┐         │
   │ row 3  ─┘ pair    │        LUT is 16 × 2   (16 centroids, each a 2-vector)
   │  ...              │
   └───────────────────┘

   indices: 512·1024 / 2 = 262 144 indices × 4 bits   = 131 072 B
   LUT    : 16 × 2 × 2 B                              =      64 B
   effective bits per weight = n_bits / cluster_dim = 4 / 2 = 2.0
```

**~8× compression at a nominal 4-bit setting.** That is the pitch: vector quantization exploits
*correlation between adjacent weights*, which scalar k-means throws away entirely. If neighbouring
output channels are correlated — and in a well-trained network they often are — a 2-D codebook can
represent the joint distribution far more efficiently than two independent 1-D codebooks.

The price list is long, and it is why this scheme is rare in production:

| Cost | Detail |
|---|---|
| **Non-deterministic** | ✅ vector k-means uses `numpy.random` + `torch.randint` for centroid init. §7.1. |
| **Fast mode unavailable** | ✅ `enable_fast_kmeans_mode` must be `False` — a `ValueError` otherwise. |
| **No per-channel scale** | ✅ `cluster_dim > 1` + `enable_per_channel_scale=True` → `ValueError` at the program level. |
| **CoreML backend restricted** | ✅ at most one of `{cluster_dim>1, lut_qspec, enable_per_channel_scale}`; two raises `CoreMLExportError`. |
| **Slower to fit** | multi-dimensional Lloyd's iterations, not the exact 1-D DP. |
| 🔴 **Runtime support unquantified** | see the GAP box below. |

> 🔴 **GAP — is vector palettization fast on device?** The `.aimodel` format supports it (the LUT
> shape contract has a dedicated `VECTOR_SIZE` axis, ✅ verified below), and `finalize()` emits
> `lut_to_dense` for it. But **no Apple benchmark, no Apple sample, and no community measurement in
> our corpus reports device latency or compute-unit placement for `cluster_dim > 1`.** It is
> plausible that the wider LUT interacts badly with the ANE's rank and alignment rules (§5), and it
> is plausible that it is fine. We do not know.
> **What would resolve it:** running a `cluster_dim=2` and a `cluster_dim=1` artefact through
> `llm-benchmark`-style timing with `SpecializationOptions.from_preferred_compute_unit_kind(...)`
> and comparing placement, or an Apple doc page on `lut_to_dense` lowering.
> **Safe default meanwhile: use `cluster_dim=1`.** Reach for vector palettization only when scalar
> palettization at your target bit-width has already failed your quality gate, and always measure
> device latency before shipping it — a size win that halves your throughput is not a win.

### 4.4 The LUT tensor shape contract

All three schemes produce a LUT with the same rank. This is the single most useful fact in the
palettization implementation, because it is what §5 is about.

> ✅ **VERIFIED** — `src/coreai_opt/palettization/spec/fake_palettize.py:139-151`:
> ```
> LUT shape: [NUM_LUT_AXIS_0, NUM_LUT_AXIS_1, NUM_PALETTES, VECTOR_SIZE]
>            NUM_PALETTES == 2**n_bits
>            VECTOR_SIZE  == cluster_dim        (1 ⇒ scalar palettization)
> ```

So:

| Scheme | `NUM_LUT_AXIS_0` | `NUM_LUT_AXIS_1` | `NUM_PALETTES` | `VECTOR_SIZE` | rank |
|---|---|---|---|---|---|
| per-tensor, scalar | 1 | 1 | `2**n_bits` | 1 | **4** |
| per-grouped-channel axis 0, scalar | `shape[0] // group_size` | 1 | `2**n_bits` | 1 | **4** |
| per-grouped-channel axis 1, scalar | 1 | `shape[1] // group_size` | `2**n_bits` | 1 | **4** |
| any granularity, vector | as above | as above | `2**n_bits` | `cluster_dim` | **4** |

**The LUT is always rank 4 at the PyTorch level.** Hold onto that number.

The other buffers the fake-palettize module carries, for completeness:

> ✅ **VERIFIED** — buffers on `_FakePalettizeImplBase`: `lut`, `indices`, `per_channel_scale`,
> `quantized_lut`, `lut_quantization_scale`, `lut_quantization_zero_point`, plus `fake_palett_enabled`
> and `observer_enabled` (both `uint8` tensors). A custom `_load_from_state_dict` re-registers these
> dynamically-created buffers on load — so a palettized model does round-trip through
> `state_dict()` / `load_state_dict()`.


---

## 5. ⚠️ The ANE rank-5 ceiling

This section exists because of a single docstring inside Apple's own SAM3 export pipeline that
contradicts what Apple said on stage. It is the highest-value finding in this guide, and it
generalises well beyond palettization.

### 5.1 The rule

> ✅ **VERIFIED** — `skills/skills/model-authoring/references/neural_engine_rules.md` (479 lines),
> vendored in `apple/coreai-models` and written by Apple:
> **Max tensor rank is 5.** Supported dtypes are **fp16 / int8 / int16** (fp32 falls back to
> GPU/CPU). Shapes must be **fully static**. The last axis must be **contiguous and 64-byte
> aligned**; a singleton last axis costs **32× memory at fp16 and 64× at int8**, so keep the last
> axis at ≥ 32 fp16 elements and prefer powers of two.

Five is not a soft target. A rank-6 intermediate is **rejected** — the graph does not run on the
Neural Engine. It does not fail; it moves.

### 5.2 The contradiction

Session 325, describing the SAM3 encoders:

> ✅ **VERIFIED** — WWDC26 session 325, 325:241:
> *"For compression, I apply **4-bit palettization with per-channel scales** to the two encoders."*

The shipped code that reproduces that demo does the opposite, and says why in a docstring:

> ✅ **VERIFIED** — `apple/coreai-models`, `models/sam3/pipeline.py:136-142`,
> `SegmentationExportConfig` docstring, verbatim:
> > *"Both encoders **deliberately disable per-channel scale**: `enable_per_channel_scale=True`
> > lowers to **`mps.dequantize_lut` ops with rank-6 LUTs, which ANE rejects (max tensor rank 5)**,
> > forcing the runtime to **fall back to GPU**. Keeping it off keeps the asset **ANE-compatible** at
> > the cost of a small PyTorch-side quality regression."*

And the code:

> ✅ **VERIFIED** — `models/sam3/pipeline.py:208-245`:
> ```python
> from coreai_opt import ExportBackend
> from coreai_opt.palettization import (
>     KMeansPalettizer, KMeansPalettizerConfig,
>     ModuleKMeansPalettizerConfig, PalettizationSpec,
> )
> from coreai_opt.palettization.spec import PerGroupedChannelGranularity
>
> def _make_pal_config(n_bits: int, group_size: int) -> KMeansPalettizerConfig:
>     spec = PalettizationSpec(
>         n_bits=n_bits,
>         granularity=PerGroupedChannelGranularity(axis=0, group_size=group_size),
>     )
>     return KMeansPalettizerConfig(
>         global_config=ModuleKMeansPalettizerConfig(op_state_spec={"weight": spec}),
>     )
>
> img_pal_config = _make_pal_config(config.image_n_bits, config.image_group_size)   # 4, 32
> txt_pal_config = _make_pal_config(config.text_n_bits,  config.text_group_size)    # 6, 8
>
> img_enc = ImageEncoderModule(sam3_lite.image_encoder); img_enc.eval()
> img_palettizer = KMeansPalettizer(img_enc, img_pal_config)
> img_enc = img_palettizer.prepare(example_inputs=(pixel_ref,))
> img_enc = img_palettizer.finalize(backend=ExportBackend.CoreAI)
> ```
> `enable_per_channel_scale` is never set — it takes its default of `False`.

There are two readings of the discrepancy and the guide will not pretend to know which:

1. **The talk used "per-channel scales" loosely** to mean the per-grouped-channel *granularity*
   (`PerGroupedChannelGranularity(axis=0, ...)`), which is a per-channel-ish thing and is what the
   code does.
2. **The recipe changed after the talk was recorded**, and the docstring is the post-mortem.

Either way, **the shipped code and its docstring win over spoken narration**, per the series'
precedence rules. Write `enable_per_channel_scale=False` — which is also the default, so write
nothing.

> ⚠️ **SILENT FAILURE — per-channel scale moves your model off the Neural Engine, and nothing tells
> you.** Turning on `enable_per_channel_scale` does not raise, does not warn, does not fail
> conversion, and does not change your PyTorch numerics in any alarming way. In fact it makes them
> *slightly better* — that is the whole point of the feature. What changes is where the model runs:
> the ANE rejects the rank-6 LUT and the runtime falls back to the GPU. On a Mac you may not even
> notice; the GPU is fast. On an iPhone you have just traded the energy-efficient engine for the
> power-hungry one, in exchange for a fractional dB. Your battery-life regression will show up in
> field telemetry weeks later.
> **How to detect it:** run the artefact under
> `SpecializationOptions.from_preferred_compute_unit_kind(ComputeUnitKind.ane())` and check where
> ops actually land, or use the Core AI Debugger's compute-unit comparison (Part 10). "Preferred"
> means preferred — the runtime silently relocates ops it cannot place.

### 5.3 The rank arithmetic, and why you cannot reshape your way out

The observed fact is rank 6. The exact derivation is not published, but the budget is easy to see
and worth reasoning through, because the same arithmetic governs every ANE decision you make.

Recall the verified PyTorch-side LUT shape from §4.4:

```
[NUM_LUT_AXIS_0, NUM_LUT_AXIS_1, NUM_PALETTES, VECTOR_SIZE]        rank 4
```

Rank 4 is comfortably inside the budget. But the LUT operand that reaches
`mps.dequantize_lut` is not that tensor — it is a tensor the *lowering* constructs, and it has to
carry enough structure to be broadcast against the weight it reconstructs. On the ANE the weight is
already living in a 4-D `Conv2d` layout (`[C_out, C_in, 1, 1]`) or a BC1S activation layout
(`[B, C, 1, S]`). Add the grouped-LUT axes and you are at 5. Add another axis for a per-channel
scale plane and you are at 6.

> 🔴 **GAP — the precise axis accounting for the rank-6 LUT.** Apple states the *outcome* (rank 6,
> ANE rejects) but not the derivation, and `mps.dequantize_lut` is an MPSGraph-dialect op with no
> published operand spec in our corpus. We do not know which axis is added, whether it is the scale
> plane itself or a broadcast axis introduced to align it, or whether the same thing happens with
> `PerTensorGranularity` + per-channel scale.
> **What would resolve it:** an MLIR dump of the lowered program (`ai_program` inspection, Part 8) or
> an Apple doc page for `mps.dequantize_lut`.
> **Safe default meanwhile:** `enable_per_channel_scale=False` for any ANE target, regardless of
> granularity. It is the default and Apple's own shipped recipe agrees.

**The workaround you know does not apply here.** The standard ANE rank remedy is to reshape — drop
singleton dimensions, fold axes together, and get back under 5. Apple's skill gives the canonical
conversions:

> ✅ **VERIFIED** — `references/neural_engine_rules.md`, BC1S conversion helpers:
> ```python
> x = x.permute(0, 2, 1).unsqueeze(2)        # (B, S, D) → (B, D, 1, S)
> x = x.squeeze(2).permute(0, 2, 1)          # back
>
> def gpu_to_bc1s(x):
>     B, H, S, D = x.shape
>     return x.permute(0, 1, 3, 2).reshape(B, H * D, 1, S)
>
> def bc1s_to_gpu(x, n_heads, head_dim):
>     B, _, _, S = x.shape
>     return x.reshape(B, n_heads, head_dim, S).permute(0, 1, 3, 2)
> ```
> Note the `reshape(B, H*D, 1, S)` in `gpu_to_bc1s`: folding the head and head-dim axes together is
> exactly a rank reduction, from 4 to 4 but with the seq axis freed — and the same technique takes a
> rank-5 tensor to rank 4 when you have a spare singleton.

That technique works for **tensors your graph creates**. It is useless for the LUT, because:

- The rank-6 tensor is **synthesised by the lowering**, not by any line of your PyTorch. There is no
  `reshape` you can insert, because the tensor does not exist until after `torch.export` and
  `TorchConverter` have run.
- `AIProgram.optimize()` will not save you either. It is a peephole optimiser, and — as Part 8
  documents — it is quite capable of *deleting* semantically-significant reshapes rather than adding
  helpful ones.

So the rank-6 LUT has exactly one remedy: **do not create it.** Leave `enable_per_channel_scale`
off.

Where the reshape trick *does* earn its keep is everywhere else in an ANE model, and the interaction
with palettization is real: if you have already spent your rank budget on a 5-D KV cache
(`[n_layers, B, H_kv*D, 1, max_S]` — ✅ verified from the skill's KV-cache table), you have **zero**
headroom left for anything the compression lowering wants to add. Rank is a budget shared across
your authoring choices and your compression choices, and most people only account for the first.

**Practical rank checklist for an ANE-targeted, palettized model:**

```
rank 4  activations in BC1S                       (B, C, 1, S)
rank 4  Conv2d weights                            (C_out, C_in, 1, 1)
rank 4  palettization LUT, PyTorch side           (G0, G1, 2**n_bits, cluster_dim)
rank 5  KV cache, if you have one                 (n_layers, B, H_kv*D, 1, max_S)
─────
rank 5  HARD CEILING — anything above is rejected and the graph moves to GPU
rank 6  what enable_per_channel_scale produces    ← the trap
```

### 5.4 The other lever the SAM3 recipe used instead

Having given up per-channel scale, Apple recovered the quality a different way: **asymmetric
bit-widths per component.**

> ✅ **VERIFIED** — `apple/coreai-models`, `models/sam3/README.md`, the three-function split with
> per-function compression:
>
> | Function | Compression | Inputs | Outputs |
> |---|---|---|---|
> | `image_encode` | **4-bit** k-means palettization (**gs=32**) + fp16 | `pixel_values` | `backbone_features` |
> | `text_encode` | **6-bit** k-means palettization (**gs=8**) + fp16 | `input_ids` | `text_features` |
> | `detect` | **fp16, no weight compression** | `backbone_features`, `text_features` | `pred_masks`, `pred_boxes`, `pred_logits`, `presence_logits` |

The transcript describes this as *"I apply 4-bit palettization ... to the two encoders"* — a
simplification. The shipped recipe uses **three different compression levels for three components**,
chosen by where the parameters and the sensitivity are:

- Image + text encoders together are **96% of parameters** (✅ session 325, 325:60). They get the
  aggressive treatment.
- The detector is **4% of parameters** (✅ 325:158) and is compression-sensitive. It gets nothing.
  Session 325, 325:248: *"**The detector stays uncompressed. I know that it's sensitive to
  compression from our previous exercise.**"*
- Within the encoders, the *text* encoder — much smaller, and feeding a cross-attention that the
  whole detection depends on — gets 6 bits and a **4× finer group size** (8 vs 32).

That is mixed precision (§14) applied by hand, and it is the pattern the rest of this guide teaches
how to derive rather than guess.

> ⚠️ **The CLI flag that undoes it.** ✅ **VERIFIED** — `models/sam3/README.md`: the export script's
> `--n-bits` and `--group-size` flags apply *uniformly to **both** encoders*, overriding the
> asymmetric defaults. So `uv run models/sam3/export.py --n-bits 4` does not "keep the defaults and
> set the image encoder to 4" — it silently drags the text encoder from 6/gs8 down to 4/gs32-or-
> whatever-you-passed. If you are reproducing the demo, pass neither flag.

The runnable commands, for reference:

```sh
uv run models/sam3/export.py                       # lite (iOS) export — the WWDC26 325 demo
uv run models/sam3/export.py --help
uv run models/sam3/export.py --full                # plain HF Sam3Model, float32, 1008×1008
uv run models/sam3/export.py --full --dtype float16
```

> ✅ **VERIFIED** — `models/sam3/README.md`. Note `--image-size` defaults to **336** for the lite
> path (*"the resolution we recommend for iOS deployment"*) and **1008** for `--full`; session 325
> flags the change at 325:247: *"I **changed the input image size from 1008 pixels to 336** to run on
> an iPhone."* Note also that `--dtype` (`float16` | `float32`, default **`float32`**) only exists on
> the `--full` path. §17.3 is about that default.

---

## 6. Sizing: what a bit-width actually buys

Every compression decision is a size/quality trade, and you cannot evaluate the trade if you are
guessing at the size. This section is arithmetic.

### 6.1 The formula

> 🟢 **COMMUNITY-MEASURED / derived** — `notes/repos/john-rocky-models.md` records this as the
> working formula used across that archive's exports. The individual terms are consistent with the
> verified `coreai-opt` storage layout (§4.4), but the formula itself is a community synthesis, not
> an Apple-published API:
> ```
> weight/index bytes = numel * n_bits / 8
> scale bytes        = n_groups * 2                  # fp16 scales
> zero_point bytes   = n_groups * n_bits / 8         # asymmetric quantization only
> lut bytes          = 2**n_bits * n_luts * 2        # palettization; fp16 LUT entries
> avg_bitwidth       = Σ(numel_i * bits_i) / Σ numel_i
> ```

Apple's compression-exploration skill ships a script that computes the same things:

> 🟡 **RECONSTRUCTED** — `skills/skills/model-compression-exploration/scripts/compression_metrics.py`
> is documented in `SKILL.md` as providing *"theoretical size, average bitwidth, divisibility,
> parametrize walk"*, and the skill text names a helper **`check_divisibility()`** used to pre-check
> group/block compatibility. The **exact signatures of `compute_average_bitwidth`,
> `check_divisibility`, `extract_layer_specs` were not read** — only the SKILL.md prose that names
> them. Treat the names as attested and the call shapes as unverified. The output record shape *is*
> verified — see §15.3.

### 6.2 Worked: a `[512, 1024]` Linear at every setting

fp16 baseline: `524,288 × 2 = 1,048,576 B` = 1.000 MiB.

| Scheme | index/weight bytes | LUT / scale bytes | total | ratio | effective bpw |
|---|---:|---:|---:|---:|---:|
| fp16 | 1,048,576 | — | 1,048,576 | 1.00× | 16.00 |
| **P8**, per-tensor (`presets.w8()`) | 524,288 | 512 | 524,800 | 2.00× | 8.01 |
| **P4**, per-tensor | 262,144 | 32 | 262,176 | 4.00× | 4.00 |
| **P4**, grouped axis 0, **gs 32** (16 LUTs) | 262,144 | 512 | 262,656 | 3.99× | 4.01 |
| **P4**, grouped axis 0, **gs 8** (64 LUTs) | 262,144 | 2,048 | 264,192 | 3.97× | 4.03 |
| **P4**, grouped axis 0, **gs 1** (512 LUTs) | 262,144 | 16,384 | 278,528 | 3.76× | 4.25 |
| **P6**, grouped axis 0, gs 8 (64 LUTs) | 393,216 | 8,192 | 401,408 | 2.61× | 6.13 |
| **P8**, grouped axis 0, gs 8 (64 LUTs) | 524,288 | 32,768 | 557,056 | 1.88× | 8.50 |
| **P8**, grouped axis 0, **gs 1** (512 LUTs) | 524,288 | 262,144 | 786,432 | **1.33×** | 12.00 |
| **P4**, `cluster_dim=2`, per-tensor | 131,072 | 64 | 131,136 | 8.00× | 2.00 |
| int8 per-channel quant (for contrast) | 524,288 | 1,024 | 525,312 | 2.00× | 8.02 |
| int4 per-block-32 quant (for contrast) | 262,144 | 32,768 | 294,912 | 3.56× | 4.50 |

Read the last three rows of the palettization block. **8-bit per-channel palettization is a 1.33×
compression, not a 2×** — three quarters of the "savings" go straight back into 512 palettes of 256
fp16 entries each. That is the concrete form of the skill's warning, and it is the reason
`presets.w8()` is per-*tensor* while `presets.w4()` is per-grouped-channel.

Also read the int4-per-block row: **4.50 effective bits**, because a per-block-32 int4 quantization
stores an fp16 scale per 32 weights (`16 bits / 32 weights = 0.5 bits/weight`). Palettization's LUT
overhead amortises over the whole group rather than per block, which is why 4-bit palettization at
`gs=32` lands at 4.01 bpw and 4-bit block quantization at 4.50. That difference is real and it is in
palettization's favour.

### 6.3 The group-size decision, stated as a rule

```
LUT overhead per weight (bits) = (2**n_bits * 16) / (group_size * C_in)
```

For our `C_in = 1024`:

| `n_bits` | gs=1 | gs=8 | gs=16 | gs=32 | gs=128 |
|---|---:|---:|---:|---:|---:|
| 4 | 0.250 | 0.031 | 0.016 | 0.008 | 0.002 |
| 6 | 1.000 | 0.125 | 0.062 | 0.031 | 0.008 |
| 8 | **4.000** | 0.500 | 0.250 | 0.125 | 0.031 |

The rule that falls out: **the finer the group, the more the palette costs, and the cost grows
exponentially with `n_bits`.** At 4 bits you can afford almost any group size. At 8 bits, per-channel
palettization is a bad deal in bytes even though it is a good deal in dB.

Which is exactly why Apple ships `group_size=8` and `group_size=32` variants at 4 bits and nothing
finer, and why the community's "per-channel always wins" finding (§17.1) needs the size column
attached to it before you act on it.

### 6.4 The embedding asterisk

Apple's published BPW figures for the iOS LLM models carry a footnote, and it matters:

> ✅ **VERIFIED** — `apple/coreai-models`, quality tables collected from `models/*/README.md`:
> *"'BPW' marked `*` includes the INT8-per-tensor embedding."*

So `5.71*` for a "mixed 4-bit/8-bit palettized" Qwen3 0.6B is **not** the bit-width of the
transformer weights — it is the whole-model average including a large int8 embedding table that
palettization never touched (§2.6). When you compute your own BPW, decide which convention you are
using and say so, because the two numbers can differ by more than a bit.


---

## 7. Determinism, workers, and fast k-means mode

### 7.1 ⚠️ Scalar palettization is reproducible. Vector palettization is not.

> ✅ **VERIFIED** — `docs/src/palettization/config.md:43-72`. With `cluster_dim > 1`, vector k-means
> uses `numpy.random` + `torch.randint` for centroid initialisation and is **non-deterministic**.
> Seeding works **only with `num_workers=1`**, because *"k-means runs in spawned worker processes
> that do not inherit the parent's RNG state."* Scalar palettization (`cluster_dim == 1`) is
> deterministic.

The documented reproducibility recipe:

```python
import numpy as np, torch

seed = 42
np.random.seed(seed); torch.manual_seed(seed)
model_1 = KMeansPalettizer(copy.deepcopy(model), config).prepare(example_inputs)   # num_workers=1

np.random.seed(seed); torch.manual_seed(seed)
model_2 = KMeansPalettizer(copy.deepcopy(model), config).prepare(example_inputs)   # identical
```

> ⚠️ **SILENT FAILURE — a vector-palettized model is a different model every time you build it.**
> Nothing warns you. `prepare()` succeeds, the model scores fine, you ship. Then a rebuild from the
> identical commit produces a different artefact with different numerics, your regression test that
> compares against a golden hash fails, and you spend a day looking for a dependency change that
> is not there. Worse: if your CI evaluates the artefact and your release build is a *different*
> artefact, the quality number you shipped against was never measured on the bytes you shipped.
> **Rule: if `cluster_dim > 1`, pin `num_workers=1` and seed both RNGs, or do not use it.** The
> underlying reason scalar palettization escapes this is §2.3 — 1-D k-means is solved exactly by
> dynamic programming, with no random initialisation to seed.

### 7.2 `num_workers` — the wall-clock lever session 325 never mentions

> ✅ **VERIFIED** — `KMeansPalettizer.prepare(..., num_workers: int = 1)`, and the docstring:
> *"`1` runs clustering sequentially. Values greater than `1` use `torch.multiprocessing` to
> parallelize clustering across layers. **It is recommended to use more than one worker process to
> parallelize the clustering, especially when multiple CPUs are available.**"*
> Implementation (`kmeans/palettizer.py`):
> - `num_workers < 1` → `ValueError(f"num_workers must be >= 1, got {num_workers}")`
> - `== 1` → `_calculate_centroids_sequential`: one forward pass, tqdm bar
>   `"Palettizing layers (num_workers=1)"`, hooks tick per fake-palettize module
> - `> 1` → `_calculate_centroids_parallel`: `torch.multiprocessing.get_context("spawn").Pool(...)`,
>   worker count **capped at the number of layers**, tqdm `"Palettizing layers (num_workers=N)"`.
>   Source comment: *"spawn (not fork) so workers don't inherit the parent's CUDA context or other
>   process-global state."* Each worker returns the mutated `_KMeansFakePalettize` and the parent
>   swaps it back into `module.parametrizations[attr][idx]`.

Practical notes:

- **The unit of parallelism is a layer.** A model with 8 palettizable layers gets no benefit from
  `num_workers=32`; the pool is capped.
- **`spawn` means real process startup and real pickling.** For a tiny model, `num_workers=1` will
  be faster. For SAM3's 600 M-parameter image encoder it is not close.
- **`spawn` is also why seeding does not propagate** (§7.1). The two facts are the same fact.
- A sensible default is `min(os.cpu_count(), number_of_palettizable_layers)`, and for anything
  bigger than a toy model you should pass it explicitly:

```python
import os
prepared = palettizer.prepare(example_inputs, num_workers=max(1, os.cpu_count() // 2))
```

### 7.3 `enable_fast_kmeans_mode` rounds your weights, by default

> ✅ **VERIFIED** — `ModuleKMeansPalettizerConfig.enable_fast_kmeans_mode: bool = True`, docstring:
> *"enables optimizations for faster K-means clustering by **rounding the weights before clustering**
> if data is in float16 range. If weight dtype is float32, weights are **cast to float16 and then
> rounded**."* `rounding_precision: PositiveInt = 4` is the number of decimal places.

The mechanism is a deduplication trick: rounding to 4 decimal places collapses a large float32
tensor into far fewer distinct values, and 1-D k-means over a small set of distinct values with
multiplicities is dramatically cheaper than over millions of unique floats.

The cost is that you have quietly perturbed the data your centroids are fitted to. For most models
at 4 bits this is invisible — a 4-decimal rounding is far below the resolution of a 16-entry
palette. It becomes relevant when:

- your weights are unusually small in magnitude (rounding to 4 decimals is a large relative error
  on values around `1e-4`);
- you are at `n_bits=8` and per-channel, where centroids are close together and the rounding is no
  longer negligible;
- you are chasing the last dB before a gate.

Turn it off, or raise the precision:

```python
ModuleKMeansPalettizerConfig(
    op_state_spec={"weight": spec, "in_proj_weight": spec},
    enable_fast_kmeans_mode=False,      # exact clustering; slower
)
# ...or keep it on but round less aggressively:
ModuleKMeansPalettizerConfig(
    op_state_spec={"weight": spec, "in_proj_weight": spec},
    rounding_precision=6,
)
```

And remember it is **mandatory** to disable for `cluster_dim > 1` (§3.3).

A related historical signal worth knowing: **bfloat16 support was patched three separate times** in
this package.

> ✅ **VERIFIED** — commits `4df45c0` *"fix(palettization): cast bfloat16 sensitivities to float32"*,
> `859d7c9` *"fix(palettization): cluster bfloat16 weights as float32"*, and (on the quantization
> side) `f6baedf` *"fix(quantization): match the float_range bound dtype to the input"*.

Three fixes to one dtype path in a repo with roughly 35 commits total is a strong signal that the
bf16 path is newer and less exercised than fp32/fp16. If your model is bf16 and something numerically
strange happens, converting to fp32 before palettizing is a legitimate first diagnostic step.

---

## 8. Sensitivity-weighted k-means (SqueezeLLM)

Plain k-means minimises squared error in *weight space*. But not all weights matter equally: an
error in a weight the network is highly sensitive to costs you far more output error than the same
magnitude of error somewhere flat. Sensitivity-weighted k-means fixes the objective by weighting
each weight by its importance.

> ✅ **VERIFIED** — `docs/src/palettization/` and `kmeans/palettizer.py`. Based on
> **SqueezeLLM: Dense-and-Sparse Quantization** (<https://arxiv.org/pdf/2306.07629>). Squared
> gradients are used as per-element importance weights for weighted k-means. From the `prepare()`
> docstring: *"sensitivity values indicate the importance of each weight element... **k-means
> clustering will place centroids closer to more sensitive weight values**"*, computed via
> `calibration_mode(loss_fn=...)` which *"uses the loss function to compute gradients via
> backpropagation, and the squared gradients are collected as sensitivity values"*.

### 8.1 The API

```python
import torch.nn.functional as F
from coreai_opt.palettization import KMeansPalettizer, KMeansPalettizerConfig

palettizer = KMeansPalettizer(model, KMeansPalettizerConfig.presets.w4(group_size=32))
prepared_model = palettizer.prepare(example_inputs, num_workers=8)

# Collect sensitivities and RE-CLUSTER using them.
with palettizer.calibration_mode(loss_fn=F.cross_entropy,
                                 sensitivity_path="sensitivities.pt") as skm:
    for batch, target in calibration_dataloader:
        output = prepared_model(batch)
        skm.step(output, target)          # computes loss + loss.backward() internally
```

Reuse on a later run, skipping the calibration pass entirely:

```python
prepared_model = palettizer.prepare(example_inputs, sensitivity_path="sensitivities.pt")
```

Or save them after the fact:

```python
palettizer.save_sensitivities("sensitivities.pt")
```

### 8.2 What `calibration_mode()` actually does — and it is a lot

This context manager is doing considerably more than "collect some statistics", and knowing the
sequence saves you from several surprises.

> ✅ **VERIFIED** — `src/coreai_opt/palettization/kmeans/palettizer.py`:
> 1. Saves a **full `state_dict` checkpoint to a temporary file**
>    (`tempfile.NamedTemporaryFile(prefix="palettizer_calibration_", suffix=".pt")`) and calls
>    `zero_grad()`.
> 2. **Disables observers and fake palettization** for the duration of sensitivity collection — so
>    gradients are measured on the *uncompressed* weights.
> 3. Registers `param.register_hook(lambda grad: torch.square(grad))` on every `requires_grad`
>    parameter.
> 4. On exit: `_construct_sensitivities` takes `-param.grad.cpu()` per parameter;
>    `_normalize_sensitivities` computes `val = 100 * -val`, normalises by the max into `[0, 1]`,
>    then sets `val[val == 0] = min(val[val != 0])` and clips values below
>    `_SENSITIVITY_CLIP_THR = 1e-12`. Source comment: *"Clipping very small or zero sensitivity
>    values stabilizes k-means, they can lead to divergence otherwise."*
> 5. **Restores the checkpoint**, attaches the sensitivities to each `_KMeansFakePalettize`,
>    re-enables observers, **recomputes all centroids** with the same `num_workers` chosen at
>    `prepare()` time, then restores fake-palettization on / observers off.
> 6. If `step()` was never called: `RuntimeError("calibration_mode requires at least one call to
>    step(). No calibration data was processed.")`

Consequences you should plan around:

- **Exiting the context manager re-runs the entire clustering pass.** If clustering took twenty
  minutes at `prepare()`, budget another twenty on exit. This is not a bug; it is the whole point.
- **It writes a full model checkpoint to your temp directory.** For a multi-gigabyte model, make
  sure `$TMPDIR` has room. A `No space left on device` here is confusing because nothing in your
  code wrote a file.
- **`num_workers` is inherited from `prepare()`**, not passed again. Choose it correctly the first
  time.
- **Gradients are taken on uncompressed weights**, which is the right thing (you want the
  sensitivity of the original function) but means memory peaks at full precision.

### 8.3 The sensitivity file format

> ✅ **VERIFIED** — sensitivity dict keys are
> `f"{module_name}.parametrizations.{attr_name}.original"`, and shapes must match the parameter
> exactly (asserted). Loading uses `torch.load(path, weights_only=True)`, hardened in commit
> `367dfd5` (*"Use weights_only=True when loading sensitivities"*).

Two implications. First, the key format is tied to the *parametrization* naming, so a sensitivity
file is only valid for a model with the same module structure — rename a submodule and the file
silently applies to nothing. Second, `weights_only=True` means you cannot stuff arbitrary metadata
into the file; keep provenance in a sidecar JSON.

### 8.4 When it is worth it

Sensitivity weighting costs you a calibration dataset, a backward pass over it, and a second full
clustering pass. Spend that when:

- you are at **4 bits or below** and short of your quality gate by a few dB;
- the model has **known-sensitive layers** you would rather not exclude outright (excluding them
  costs size; weighting them costs nothing at runtime);
- you have already tried the cheap levers — finer `group_size`, one bit-width up — and want the
  quality without the bytes.

Skip it when you are at 6 or 8 bits and already passing, because you are spending an hour for
tenths of a dB you do not need.

> 🔴 **GAP — no published quality delta for sensitivity weighting in `coreai-opt`.** The SqueezeLLM
> paper reports large gains for LLM weight quantization, but **neither Apple nor any measurement in
> our corpus reports a before/after PSNR or accuracy number for `coreai-opt`'s implementation on any
> model.** The `edsr` and `resnet50` example pages do not use it.
> **What would resolve it:** an ablation on one of the shipped examples, or an Apple example page.
> **Safe default meanwhile:** treat it as a tool to try when you are close to a gate, measure it on
> your own model, and do not build a schedule around an assumed gain.

---

## 9. `lut_qspec`: quantizing the palette itself

### 9.1 The idea

The LUT is small — 16 or 64 or 256 fp16 values per group. Compressing it saves almost nothing
(§6.2). So why does the API let you quantize it?

Because it is not about size. It is about **which execution path the runtime can take**.

> ✅ **VERIFIED** — `docs/src/utils/joint_compression.md`, verbatim: *"A floating-point LUT causes
> operations to execute in floating-point regardless of the activation quantization, whereas an
> `INT8` LUT allows the runtime to use the faster **W_INT8-A_INT8** execution path where available."*

An fp16 palette means the reconstructed weight is an fp16 value, which means the matmul is an fp16
matmul, which means quantizing your activations to int8 bought you nothing but a pair of extra
casts. An int8 palette means the reconstructed weight is an int8 value and the whole matmul can run
on the integer path.

So: **`lut_qspec` is not a palettization feature. It is the thing that makes joint compression
worth doing.** If you are not quantizing activations, leave it `None`.

### 9.2 The constraints

> ✅ **VERIFIED** — `validate_lut_qspec` in `palettization/spec/spec.py`:
> - `_SUPPORTED_LUT_DTYPES = {torch.int8, torch.uint8, torch.float8_e4m3fn, torch.float8_e5m2}` —
>   note **no int4, no int2, no FP4**. The palette is not where you save bits.
> - `lut_qspec.granularity` **must be the quantization `PerTensorGranularity`**. Anything else raises
>   `ValueError`. (This is the import hazard from §3.2 — you need the class from
>   `coreai_opt.quantization.spec`, not the identically-named one from `palettization.spec`.)
> - `lut_qspec.qformulation` must be `ZP`; `MINVAL` raises with *"Use `lut_qspec.qformulation=ZP`
>   instead."*
> - FP8 dtypes additionally require **symmetric** quantization (inherited from `QuantizationSpec`'s
>   own `validate_qscheme_for_fp_quant`).

```python
import torch
from coreai_opt.palettization import PalettizationSpec
from coreai_opt.quantization.spec import QuantizationSpec, QuantizationScheme
from coreai_opt.quantization.spec import PerTensorGranularity as QuantPerTensor

lut_qspec = QuantizationSpec(
    dtype=torch.int8,
    qscheme=QuantizationScheme.SYMMETRIC,
    granularity=QuantPerTensor(),          # the ONLY legal granularity here
)

spec = PalettizationSpec(
    n_bits=4,
    lut_qspec=lut_qspec,
    granularity=PerGroupedChannelGranularity(axis=0, group_size=32),
)
```

### 9.3 The CoreML restriction

> ✅ **VERIFIED** — `validate_coreml_palettization_compatibility` in `_utils/export_utils.py`: on the
> **CoreML** backend, **at most one of** `{cluster_dim > 1, lut_qspec, enable_per_channel_scale}` may
> be set. Two of them raises
> `CoreMLExportError("CoreML export does not support cluster_dim + lut_qspec on <ctx>. Use
> backend=ExportBackend.CoreAI instead.")`, because the combination *"hits an unsupported CoreML/MIL
> op configuration (mismatched tensor ranks, or `lut_to_dense` divisibility errors)"*. Expanded in
> commits `56c4a36` and `012f399`.

Note the parenthetical: **mismatched tensor ranks**. The same class of problem as §5, showing up in
a different backend. Rank is the recurring constraint in this whole subsystem.

The full CoreML restriction matrix, for reference:

> ✅ **VERIFIED** — `src/coreai_opt/_utils/export_utils.py:17-47`:
> ```python
> COREML_SUPPORTED_WEIGHT_DTYPES            = {torch.int8, torch.uint8, torch.int4, torch.uint4}
> COREML_SUPPORTED_ACTIVATION_DTYPES        = {torch.int8, torch.uint8}
> COREML_SUPPORTED_LUT_DTYPES               = {torch.int8, torch.uint8}
> COREML_SUPPORTED_ACTIVATION_GRANULARITIES = {PerTensorGranularity}
> ```
> So on CoreML: **no FP4/FP8 anywhere, no int2/uint2 weights, no per-channel or per-block activation
> quantization, no MINVAL formulation**, and the palettization at-most-one rule above. Every
> `CoreMLExportError` message ends with the string *"Use backend=ExportBackend.CoreAI instead."*
> (`common.py:163-177`).

---

## 10. What `finalize()` emits

### 10.1 The op-chaining table

`finalize(backend=ExportBackend.CoreAI)` replaces the fake-palettize parametrization with real
custom layers from `coreai-torch`, and which ops you get depends on which features you enabled.

> ✅ **VERIFIED** — `src/coreai_opt/palettization/kmeans/_prepare_for_export.py:225-233`.
> `_prepare_for_mlir_export(model, mmap_dir=...)` swaps in
> `coreai_torch._compression.custom_layers.PalettizeModule` / `ScaledPalettizeModule`, wrapped by
> `coreai_torch._compression.utils.wrap_for_parametrization`. The op chains:
>
> | Configuration | Emitted ops |
> |---|---|
> | 1. Palettization only | `lut_to_dense` |
> | 2. Quantized LUT (`lut_qspec`) | `lut_to_dense(int LUT)` + `constexpr_blockwise_shift_scale(lut_scale)` |
> | 3. Per-channel scale | `lut_to_dense` + `constexpr_blockwise_shift_scale(pcs)` |
> | 4. Both | `lut_to_dense(int LUT)` + `constexpr_blockwise_shift_scale(fused_scale)` where `fused_scale = lut_scale * per_channel_scale` |

Row 3 is the one §5 is about — the extra `constexpr_blockwise_shift_scale` is where the additional
rank comes from. Row 4 is worth noticing for a different reason: the two scales are **fused into
one tensor**, so combining quantized-LUT and per-channel-scale does not cost you two scale planes.
It still costs you the rank.

> ✅ **VERIFIED** — `coreai_torch` is **lazy-imported** (`lazy_import_coreai_torch`), so `coreai-opt`
> is usable without it installed. If it is missing at `finalize(backend=CoreAI)` you get an
> `ImportError` from that helper and nothing earlier.

### 10.2 ⚠️ Eager-only `KMeansPalettizer.finalize(CoreAI)` frees dense weights

> ✅ **VERIFIED** — `kmeans/_prepare_for_export.py`, verbatim: *"The dense pre-palettization weight
> stored on the parametrization list is always replaced with a **zero-size placeholder** so its
> storage can be released."* And from the `finalize` docstring: *"When `backend=ExportBackend.CoreAI`,
> finalize **frees the original dense weights in place**: on each parametrized weight,
> `parametrizations[...].original` is replaced with a zero-size placeholder so its storage can be
> released."*
> This is the eager-only k-means palettizer’s Core AI backend behavior, not a universal rule for
> every compressor, execution mode or backend.[^destructive-finalize-scope]

> ⚠️ **SILENT FAILURE — you cannot undo `finalize()`, and there is no warning.** The call returns a
> working model, so nothing looks wrong. But the float weights are gone from the process, and if
> the object you finalized was your only copy (remember `prepare()` mutates in place, §2.4), your
> float model is gone too. The failure surfaces later, when you want to re-palettize at a different
> bit-width and discover you have to reload the checkpoint from disk — or, worse, when your sweep
> script finalizes in a loop and every iteration after the first is clustering *already-palettized*
> weights.
> **Two rules that make this a non-event:** (1) `copy.deepcopy` before `prepare()`, always;
> (2) **do not call `finalize()` during a sweep at all** — Apple's own compression-exploration skill
> says exactly this, because `prepare()` alone gives you a scoreable model (§1.4).

The quantizer has the same behaviour in eager mode (guide 01 §2.5), so this is a property of the
package, not of palettization.

### 10.3 `mmap_dir`

> ✅ **VERIFIED** — `finalize(..., mmap_dir=...)` is **CoreAI-only** (`ValueError` otherwise), and
> *"the files in `mmap_dir` must remain in place for the lifetime of the returned model; removing
> them invalidates the mmap-backed weights."* On the quantizer side the same option additionally
> requires all tensors on CPU and an empty target directory; `_validate_mmap_dir_constraints` runs
> before anything else in `finalize()`.

> 🔴 **GAP — the on-disk layout under `mmap_dir`.** No example exists in the docs, and the
> filenames/safetensors layout were not read. **Safe default:** treat the directory as opaque, keep
> it alive as long as the model, and do not try to hand-assemble it.

### 10.4 The full export chain, end to end

Putting §1.4's diagram into code, with the ordering rule that matters:

```python
from pathlib import Path
import torch
import coreai_torch
from coreai_opt import ExportBackend
from coreai_opt.casting import cast_to_16_bit_precision
from coreai_opt.palettization import KMeansPalettizer, KMeansPalettizerConfig

# 1. Compress (PyTorch level)
palettizer = KMeansPalettizer(model, KMeansPalettizerConfig.presets.w4(group_size=32))
palettizer.prepare(example_inputs, num_workers=8)
finalized = palettizer.finalize(backend=ExportBackend.CoreAI).eval()   # .eval() — §2.4

# 2. Export
exported_program = torch.export.export(finalized, example_inputs).run_decompositions(
    coreai_torch.get_decomp_table()
)

# 3. Cast — COMPRESS FIRST, CAST SECOND
cast_to_16_bit_precision(exported_program)          # mutates in place

# 4. Convert
converter = coreai_torch.TorchConverter()
converter.add_exported_program(exported_program)
ai_program = converter.to_coreai()
ai_program.optimize()
ai_program.save_asset(Path("model.aimodel"))
```

> ✅ **VERIFIED** — `docs/src/introduction/integration_coreai.md` is the source of this sequence, and
> it explains why the compressed model survives conversion: *"Under the hood, `finalize()` replaces
> coreai-opt's internal fake-quantize/fake-palettize ops with PyTorch custom ops whose definitions
> match the corresponding compression ops in the Core AI dialect. This allows `coreai-torch` to
> recognize the ops and map them correctly in the Core AI representation."*
> ✅ **VERIFIED** — the ordering rule, `docs/src/utils/casting.md`: *"**compress first, cast
> second**. Any quantized int8 buffers are left untouched; any remaining FP32 weights move to FP16."*

Guide 01 §14 covers `cast_to_16_bit_precision` in detail. The one-line version: it rewrites the
`ExportedProgram` graph in place, the FP pass is aggressive (everything except tensors exceeding the
fp16 range, ≈ ±65504) and the INT pass is conservative (skips constant-foldables, indexing feeds, and
anything not consumed by a compute-intensive op). It may change the dtypes of your model's inputs and
outputs, so your calling code may need updating.


---

## 11. Pruning: the technique nobody presented

Pruning received **zero seconds of stage time** across WWDC26. Session 325 does not name it. The
`coreai-opt` README does — *"quantization, palettization (codebook-based compression), and
pruning"* — and the repository ships a complete implementation with its own config hierarchy, two
schemes, two schedules, a supported-ops registry, export tests and a tutorial notebook.

That gap is worth taking seriously in both directions. Pruning is real and supported. It is also,
for most readers, the wrong tool, and Apple says so more bluntly than vendors usually do.

### 11.1 The verdict, first

> ✅ **VERIFIED** — `docs/src/pruning/overview.md:7`, verbatim:
> > *"Unless the original PyTorch model already has a large fraction of weights close to zero across
> > all of its weight parameters, **post-training pruning will almost always degrade accuracy**. It
> > is most useful as a **quick way to evaluate the impact of sparsity on model size and inference
> > latency before committing to a fine-tuning workflow**."*

Read that carefully, because it is doing two things. It tells you post-training pruning does not
work — and it tells you what pruning *is* for in this package: **a measurement instrument.** You
prune to find out what sparsity would buy you, so you can decide whether to spend the training
budget to get there properly.

Compare that with quantization, where data-free post-training weight quantization to 8 bits is
routinely near-lossless and takes seconds:

> ✅ **VERIFIED** — `docs/src/landing_page.md:43-47`: **data-free** workflows are *"typically seconds
> to minutes even for large models. Often works well for reducing the model down to 8 bits, or even
> 6 or 4 bits, with only a slight decrease in accuracy."* **Fine-tuning-based** is *"the most
> time-intensive workflow, but typically the only way to recover accuracy at the most aggressive
> compression ratios for weights (4 bits and below)."*

So the honest decision rule is:

```
Do you have a training loop, a dataset, and time?
├── No  ──►  Do not prune. Quantize or palettize. You will get more size reduction,
│            more reliably, in less time, with a runtime that definitely exploits it.
└── Yes ──►  Is your model already known to be over-parameterised for its task,
             or is structured sparsity a hardware requirement you have verified?
             ├── No  ──►  Spend the training budget on QAT instead. Guide 01 §11.
             └── Yes ──►  Prune with a PolynomialDecaySchedule while fine-tuning. §11.6.
```

And there is a second, sharper reason for that ordering, which is the gap box in §11.8.

### 11.2 The API

> ✅ **VERIFIED** — `coreai_opt.pruning.__all__` = `MagnitudePruner, MagnitudePrunerConfig,
> ModuleMagnitudePrunerConfig, PruningSpec`;
> `coreai_opt.pruning.spec.__all__` = `ChannelStructured, PruneImplBase, PruningScheme, PruningSpec,
> Unstructured, default_weight_pruning_spec`;
> `coreai_opt.pruning.config.__all__` = `ConstantSparsitySchedule, MagnitudePrunerConfig,
> ModuleMagnitudePrunerConfig, OpMagnitudePrunerConfig, PolynomialDecaySchedule,
> SparsityScheduleBase`.
>
> ```python
> class MagnitudePruner(_BasePruner, _EagerCompressionComponentBuilderMixin):
>     def __init__(self, model: nn.Module, config: MagnitudePrunerConfig | None = None)
>     def prepare(self, example_inputs: tuple[torch.Tensor]) -> nn.Module
>     def step(self) -> None
>     def finalize(self, model: nn.Module | None = None,
>                  backend: ExportBackend = ExportBackend.CoreAI) -> nn.Module
> ```

Note the absences, and note that they are *different* absences from palettization's:

- **No `mmap_dir`** on `finalize`. Quantization and palettization both have it; pruning does not.
- **No `calibration_mode()`.** Magnitude pruning is data-free by construction — it ranks weights by
  `|w|`, and no forward pass is needed to do that.
- **No `training_mode()`.** But there *is* a `step()`, and pruning is explicitly designed to be used
  inside your own training loop. §11.6.
- **No presets.** `MagnitudePrunerConfig.presets` does not exist. Every pruning config is
  hand-written.
- **Eager only**, like palettization.

### 11.3 `PruningSpec` and the two schemes

> ✅ **VERIFIED** — `src/coreai_opt/pruning/spec/spec.py`:
> ```python
> class PruningSpec(CompressionSpec):
>     target_sparsity: float = Field(default=0.5, ge=0.0, le=1.0)
>     pruning_scheme: PruningScheme = Unstructured()
>     pruning_algo: type[PruneImplBase] = "default"        # → _MagnitudePruneImpl
> ```
> Scheme registry keys `"unstructured"` / `"channel_structured"`:
> ```python
> class Unstructured(PruningScheme):        axis: Literal[None] = None
> class ChannelStructured(PruningScheme):   axis: int = 0
> ```

Three fields. `pruning_algo` is an extension point — `PruneImplBase` is exported publicly, so you
can register your own ranking criterion — but only one implementation ships.

**Unstructured pruning** zeroes individual weights, anywhere, chosen by magnitude:

```
   W [4, 6], target_sparsity = 0.5                mask
   ┌────────────────────────────────┐      ┌────────────────────────┐
   │  0.81  -0.02   0.44   0.01 ... │      │  1  0  1  0  ...       │
   │ -0.03   0.67  -0.55   0.02 ... │  ──► │  0  1  1  0  ...       │
   │  0.05  -0.71   0.02   0.63 ... │      │  0  1  0  1  ...       │
   │  0.90   0.01  -0.48   0.03 ... │      │  1  0  1  0  ...       │
   └────────────────────────────────┘      └────────────────────────┘
   keep the 12 largest |w| out of 24; zero the rest.  W' = W * mask
```

**Channel-structured pruning** removes entire channels, ranked by L1 norm:

```
   W [C_out=8, C_in, ...], axis=0, target_sparsity = 0.5

   channel importance = |W|.sum(over every dim except axis)
      c0: 41.2   c1: 3.8    c2: 27.9   c3: 5.1
      c4: 33.6   c5: 2.2    c6: 19.4   c7: 8.7

   prune floor(8 * 0.5) = 4 lowest → c5, c1, c3, c7 zeroed ENTIRELY
   mask broadcast to the full weight shape.
```

> ✅ **VERIFIED** — mask arithmetic in `pruning/spec/prune.py`:
> - **unstructured**: `num_keep = numel - floor(numel * sparsity)`, then
>   `topk(|w|.flatten(), num_keep)`; mask is `1.0` at kept indices.
> - **channel-structured**: `num_prune = floor(num_channels * sparsity)`; channel importance is the
>   **L1 norm**, `weight.abs().sum(dim=all_dims_except_axis)`; keeps the top
>   `num_channels - num_prune`; the mask is broadcast/expanded to the full weight shape.
> - `sparsity == 0.0` → `ones_like`; `sparsity >= 1.0` → `zeros_like`.
> - The mask is a buffer named `mask`. `forward` recomputes it only when `_dirty`, casts/resizes as
>   needed, then returns `weight * self.mask`. **Mask dtype matches the weight** — fixed in commit
>   `3b8d61a`, the very first bug-fix commit in the repository.

Which to choose, in one line each:

- **`Unstructured`** gives you the best quality at a given sparsity, because it is free to keep any
  weight. It gives you **no dense speedup** — a zero in the middle of a dense matmul still gets
  multiplied. Its value is entirely in *compressed storage* (if the format encodes sparsity) and in
  any hardware that exploits fine-grained sparsity.
- **`ChannelStructured`** removes whole output (or input) channels, which is genuinely *structural*
  — a pruned model can in principle be rebuilt smaller and run faster on any hardware. It costs far
  more quality at the same sparsity, because you are forced to throw away large weights that happen
  to live in a weak channel.

### 11.4 ⚠️ Realized sparsity rounds *down*, and it can round to zero

> ✅ **VERIFIED** — `docs/src/pruning/config.md:34-38`: for `ChannelStructured`, realized sparsity
> rounds *down* to a multiple of `1/num_channels`. Worked example from the docs:
> `num_channels=7, target_sparsity=0.5` ⇒ `floor(7 * 0.5) = 3` channels pruned ⇒ **3/7 ≈ 43%**,
> not 50%.

> ⚠️ **SILENT FAILURE — a channel-structured target you cannot reach produces a smaller sparsity and
> no warning.** With `num_channels = 8` and `target_sparsity = 0.1`, `floor(8 * 0.1) = 0`: **not one
> channel is pruned**, the layer is completely untouched, and the API reports nothing. Your
> "10% sparse" model is 0% sparse in every narrow layer and your size estimate is wrong by exactly
> the amount you were counting on. This compounds with the divisibility silent skip in §19.1 —
> `coreai-opt` has a consistent house style of degrading quietly rather than raising.
> **Detection:** after `prepare()`, compute realized sparsity yourself:
> ```python
> for name, module in prepared.named_modules():
>     for attr, plist in getattr(module, "parametrizations", {}).items():
>         w = getattr(module, attr)
>         zeros = (w == 0).sum().item()
>         print(f"{name}.{attr}: realized sparsity {zeros / w.numel():.3f}")
> ```
> Do not trust `target_sparsity` as a description of what you got. It is a request.

### 11.5 Schedules

Pruning is the only compressor whose `step()` advances a *sparsity* schedule rather than a QAT
schedule. Two implementations ship.

> ✅ **VERIFIED** — `src/coreai_opt/pruning/config/sparsity_schedule.py`:
> ```python
> @SparsityScheduleBase.register("constant")
> class ConstantSparsitySchedule(SparsityScheduleBase):
>     begin_step: NonNegativeInt = 0
>     # sparsity(s) = target_sparsity if s >= begin_step else 0.0
>
> @SparsityScheduleBase.register("polynomial_decay")
> class PolynomialDecaySchedule(SparsityScheduleBase):
>     begin_step: int = Field(default=0, ge=0)
>     total_iters: PositiveInt                     # REQUIRED — no default
>     power: PositiveFloat = 3.0
>     initial_sparsity: float = Field(default=0.0, ge=0.0, le=1.0)
>     update_frequency: PositiveInt = 1
> ```
> Formula:
> ```
> n_updates = max((total_iters - 1) // update_frequency + 1, 1)
> i         = offset // update_frequency
> t         = i / max(n_updates - 1, 1)
> sparsity  = target + (initial - target) * (1 - t) ** power
> ```
> Behaviour: below `begin_step` → `initial_sparsity`; at or beyond `begin_step + total_iters` →
> `target_sparsity`; on an off-boundary step it returns `prev_sparsity` — and **raises `ValueError`
> if `prev_sparsity is None` when `update_frequency > 1`.**

The polynomial-decay curve with `power=3.0` (the default) is the standard "prune fast early, slow
down near the target" shape from the sparsity literature. Sketched, for `initial=0.0`,
`target=0.7`, `total_iters=30`:

```
 sparsity
   0.70 ┤                              ╭──────────────────────
        │                        ╭─────╯
   0.60 ┤                  ╭─────╯
        │             ╭────╯
   0.50 ┤        ╭────╯
        │    ╭───╯
   0.40 ┤  ╭─╯
        │ ╭╯
   0.20 ┤╭╯
        ││
   0.00 ┼╯──────┬──────┬──────┬──────┬──────┬──────►  step
        0       5     10     15     20     25    30
```

Most of the damage is done in the first third, leaving two thirds of the fine-tuning budget to
recover from it. That is the entire point of the shape: a network can re-route around gradually
removed weights, but not around a sudden 70% amputation.

Use `ConstantSparsitySchedule` when you want the measurement Apple describes in §11.1 — set
`begin_step=0`, prune immediately, evaluate, and learn what sparsity costs you before you commit.

### 11.6 The fine-tuning loop

> ✅ **VERIFIED** — `docs/src/pruning/overview.md:56-89`:
> ```python
> from coreai_opt.pruning import MagnitudePruner, MagnitudePrunerConfig, ModuleMagnitudePrunerConfig, PruningSpec
> from coreai_opt.pruning.config import PolynomialDecaySchedule
>
> config = MagnitudePrunerConfig(
>     global_config=ModuleMagnitudePrunerConfig(
>         op_state_spec={"weight": PruningSpec(target_sparsity=0.7)},
>         sparsity_schedule=PolynomialDecaySchedule(begin_step=0, total_iters=num_epochs, power=3.0),
>     ),
> )
> pruner = MagnitudePruner(model, config)
> prepared_model = pruner.prepare(example_inputs)
>
> for epoch in range(num_epochs):
>     prepared_model.train()
>     for batch, target in train_dataloader:
>         optimizer.zero_grad()
>         criterion(prepared_model(batch), target).backward()
>         optimizer.step()
>     pruner.step()        # advance schedule + recompute masks
> ```
> `step()` is a **no-op when nothing has a schedule**. `_build_scheduled_modules()` runs at
> `prepare()` time and applies the step-0 state before the initialisation forward pass.

The critical detail is **where `pruner.step()` sits**. In this example it is once per **epoch**,
because `total_iters=num_epochs`. In the QAT example in guide 01 §11, `quantizer.step()` is once per
**mini-batch**, because the schedule integers are in mini-batches. The unit is whatever cadence you
call `step()` at, and the schedule's `total_iters` must be in the same unit. Mismatch them and your
schedule completes in the first epoch or never completes at all — with no error either way.

Also note: the masked weights are still *parameters*. They receive gradients and the optimizer
updates them; the mask is re-applied on the next forward. That is what lets a weight come back if
the schedule has not yet reached its target — and it is also why you must not naively compute
"non-zero parameters" from the optimizer's state.

### 11.7 Configuration

> ✅ **VERIFIED** — `src/coreai_opt/pruning/config/magnitude_pruner_config.py`:
> ```python
> class ModuleMagnitudePrunerConfig(WeightOnlyModuleValidationMixin, ModuleCompressionConfig[...]):
>     sparsity_schedule: SparsityScheduleBase | None = None
>
> class MagnitudePrunerConfig(CompressionConfig[ModuleMagnitudePrunerConfig]):
>     _CONFIG_KEY = "magnitude_pruning_config"     # YAML top-level key
>     _SPEC_KEY   = "pruning_spec"
> ```
> Defaults target `{"weight", "in_proj_weight"}` at **50% unstructured**. There are **no presets**.
> Supported ops (`pruning/supported_ops_registry.py`): `linear`, `conv1d/2d/3d`,
> `conv_transpose1d/2d/3d`, `multi_head_attention` — all `F.*` functions.

The same three-level hierarchy, the same `None`-means-skip semantics, the same regex module-name
matching, and the same fully-qualified-type-name requirement as everything else in this package. The
YAML top-level key is `magnitude_pruning_config`.

A per-layer example — prune the deep layers harder than the shallow ones, and leave the first and
last alone entirely:

```python
from coreai_opt.pruning import MagnitudePrunerConfig, ModuleMagnitudePrunerConfig, PruningSpec
from coreai_opt.pruning.spec import Unstructured
from coreai_opt.pruning.config import PolynomialDecaySchedule

schedule = PolynomialDecaySchedule(begin_step=0, total_iters=40, power=3.0)

config = MagnitudePrunerConfig(
    global_config=ModuleMagnitudePrunerConfig(
        op_state_spec={"weight": PruningSpec(target_sparsity=0.5, pruning_scheme=Unstructured()),
                       "in_proj_weight": PruningSpec(target_sparsity=0.5)},
        sparsity_schedule=schedule,
    ),
)
# Deep blocks tolerate more.
config.set_module_name(r"backbone\.blocks\.(1[0-9]|2[0-9])\..*", ModuleMagnitudePrunerConfig(
    op_state_spec={"weight": PruningSpec(target_sparsity=0.7)},
    sparsity_schedule=schedule,
))
# Boundary layers: leave alone. (See §17.2 for why this is not superstition.)
config.set_module_name(r"stem\..*", None)
config.set_module_name(r"head\..*", None)
```

### 11.8 🔴 The gap that should govern your decision

> 🔴 **GAP — we cannot verify that Core AI's runtime does anything with unstructured sparsity.**
> `MagnitudePruner.finalize(backend=CoreAI)` exists and `tests/export/` contains a pruning-export
> test, so a pruned model **converts**. But: what op the masked weight lowers to, whether the
> `.aimodel` stores a sparse encoding or a dense tensor full of zeros, and whether the ANE or the
> GPU exploits sparsity for either **size** or **latency**, are stated **nowhere** — not in the
> `coreai-opt` docs, not in the `coreai-models` skills, not in any session, and not in any community
> measurement in our corpus. The program-level `sparsify_weights` pass (§12.2) does name a
> `weight_num_threshold` and offers `n:m` ratios, which is the kind of thing you build for hardware
> that exploits structured sparsity — but that is inference, not evidence.
> **What would resolve it:** an `.aimodel` size comparison between a 0%-sparse and a 70%-sparse
> version of the same model (does the file shrink?), plus a latency comparison on device. Both are
> a half-day of work and would be the most valuable single measurement anyone could contribute to
> this topic.
> **Safe default meanwhile: assume unstructured pruning buys you nothing at runtime.** Use it as
> Apple's docs describe it — a measurement instrument — and if you need size, use palettization or
> quantization, whose runtime benefit *is* documented. If you need structural speedup, use
> `ChannelStructured` and physically rebuild the smaller model yourself, which is a technique this
> package does not automate.


---

## 12. Program-level compression: `palettize_weights` and `sparsify_weights`

Everything so far operates on a PyTorch `nn.Module`. There is a second, entirely separate entry
point that operates on an **already-converted Core AI program** — no PyTorch model required, no
`prepare()`/`finalize()` lifecycle, just a function that takes an `AIProgram` and returns a
compressed one.

> ✅ **VERIFIED** — `src/coreai_opt/coreai_utils/__init__.py`, `__all__` =
> `CompressionGranularity, DType, palettize_weights, quantize_weights, sparsify_weights`.
> ```python
> from coreai_opt.coreai_utils import CompressionGranularity, DType
> from coreai_opt.coreai_utils import quantize_weights, palettize_weights, sparsify_weights
> ```
> ```python
> class DType(_StrEnum):
>     INT2, UINT2, INT4, UINT4, INT8, UINT8, FP4_E2M1FN, FP8_E4M3FN, FP8_E5M2, FP8_E8M0FNU
>     def is_int(self) -> bool
> class QScheme(_StrEnum): SYMMETRIC, ASYMMETRIC
> class CompressionGranularity(_StrEnum): PER_TENSOR, PER_CHANNEL, PER_BLOCK, PER_GROUPED_CHANNEL
> ```

> 🟡 **RECONSTRUCTED — `QScheme`'s import path.** `coreai_utils.__init__.__all__` does **not** list
> `QScheme`, but `docs/src/utils/coreai_compression.md:92-97` writes
> `from coreai_opt.coreai_utils import (..., QScheme, ...)`. Either the docs are stale or the
> package re-exports it implicitly. **Safe default:** import it from
> `coreai_opt.coreai_utils.common`, which is where it is defined, and which works either way.

Only constants consumed by a specific op set are candidates:

> ✅ **VERIFIED** — `coreai_utils/passes/__init__.py`:
> ```python
> _OPS_WEIGHT_NEED_COMPRESSION = frozenset({
>     "coreai.batch_matmul", "coreai.conv2d",
>     "coreai.decomposable.broadcasting_batch_matmul",
>     "coreai.gather_nd", "coreai.transpose",
> })
> ```

Note `coreai.gather_nd` on that list — **the program-level path can compress a gather**, which is
exactly what the PyTorch-level palettizer cannot do (§2.6). That is a genuinely useful asymmetry if
your problem is an embedding table.

### 12.1 `palettize_weights`

> ✅ **VERIFIED** — `coreai_utils/passes/weight_palettization.py:63-76`:
> ```python
> def palettize_weights(
>     coreai_program: AIProgram,
>     lut_dtype: DType | None,
>     n_bits: int = 4,
>     granularity: CompressionGranularity = CompressionGranularity.PER_TENSOR,
>     group_size: int = 32,
>     cluster_dim: int = 1,
>     enable_per_channel_scale: bool = False,
>     weight_num_threshold: int = 1024,
>     num_kmeans_workers: int = 4,
>     enable_fast_kmeans_mode: bool = True,
>     rounding_precision: int = 4,
>     in_place: bool = False,
> ) -> AIProgram
> ```
> `_VALID_LUT_DTYPES = {INT8, UINT8, FP8_E4M3FN, FP8_E5M2}`; `_VALID_N_BITS = {1,2,3,4,6,8}`;
> `granularity ∈ {PER_TENSOR, PER_CHANNEL, PER_GROUPED_CHANNEL}`.
> `enable_per_channel_scale=True` + `cluster_dim > 1` → `ValueError`.
> ⚠️ **`lut_dtype` is positional argument #2 and has no default.** The docs example passes it as a
> keyword; if you pass positionally you will silently put your `n_bits` in the `lut_dtype` slot.

Differences from the PyTorch path worth knowing:

| | `KMeansPalettizer` | `palettize_weights` |
|---|---|---|
| Input | `nn.Module` | `AIProgram` |
| Granularity vocabulary | per-tensor, per-grouped-channel | per-tensor, **per-channel**, per-grouped-channel |
| Worker default | `num_workers=1` | `num_kmeans_workers=4` |
| Size floor | none | `weight_num_threshold=1024` — smaller tensors skipped |
| Compresses embeddings | ✗ | ✓ (via `coreai.gather_nd`) |
| Sensitivity weighting | ✓ | ✗ |
| Evaluate before committing | ✓ (still a torch model) | ✗ (you must run the program) |

Entry point:

```python
from pathlib import Path
from coreai.authoring import AIModelAsset
from coreai_opt.coreai_utils import DType, palettize_weights

ai_asset = AIModelAsset.load(Path("model.aimodel"))
compressed = palettize_weights(
    coreai_program=ai_asset.program,
    lut_dtype=None,                                        # keyword — see the warning above
    n_bits=4,
    granularity=CompressionGranularity.PER_GROUPED_CHANNEL,
    group_size=32,
    in_place=False,
)
compressed.optimize()
compressed.save_asset(Path("model_palettized.aimodel"))
```

> ✅ **VERIFIED** — the shape of this entry point is from `docs/src/utils/coreai_compression.md:11-31`
> (which shows `quantize_weights`; the palettization call is the same pattern).
> Note the docs use `weight_num_threshold=2048` in their "advanced" examples although the **code
> default is `1024`** — a small inconsistency, but if you are reproducing a documented result, pass
> the value explicitly.

**When to use this path.** Rarely, and deliberately. You lose the ability to score the compressed
model in PyTorch, you lose sensitivity weighting, and you are compressing a program that has already
been through `optimize()` — so op fusion decisions were made against uncompressed weights. Use it
when you have an `.aimodel` and no PyTorch source, or when you need to compress an op the PyTorch
palettizer cannot reach.

### 12.2 `sparsify_weights` — the pruning features the PyTorch path does not have

> ✅ **VERIFIED** — `coreai_utils/passes/weight_sparsification.py:55-64`:
> ```python
> def sparsify_weights(
>     coreai_program: AIProgram,
>     target_sparsity: float | None = 0.5,
>     block_size: int | None = None,
>     n_m_ratio: tuple[int, int] | None = None,
>     quantize_dtype: DType | None = None,
>     palettize_nbits: int | None = None,
>     weight_num_threshold: int = 1024,
>     in_place: bool = False,
> ) -> AIProgram
> ```
> Rules:
> - `target_sparsity` **XOR** `n_m_ratio` — setting both, or neither, raises `ValueError`.
> - `quantize_dtype` **XOR** `palettize_nbits` — joint sparse+quant or sparse+palettized, never both.
> - `quantize_dtype ∈ {INT8, UINT8, FP8_E4M3FN, FP8_E5M2}`; `palettize_nbits ∈ {1,2,3,4,6,8}`.
> - `block_size` must be `> 1`; block sparsity runs along the **output-channel** dimension, and only
>   for linear/conv.
> - `n_m_ratio=(n, m)`: *"Out of every `m` elements, the `n` with lowest magnitude are set to zero"*,
>   along the **input-channel** axis, linear/conv only.

This is a strictly larger feature set than `MagnitudePruner`:

| Feature | `MagnitudePruner` (PyTorch) | `sparsify_weights` (program) |
|---|---|---|
| Unstructured | ✓ | ✓ (`target_sparsity`) |
| Channel-structured | ✓ (`ChannelStructured`) | — |
| **Block sparsity** (output-channel dim) | ✗ | ✓ (`block_size`) |
| **N:M sparsity** (input-channel axis) | ✗ | ✓ (`n_m_ratio`) |
| **Sparse + quantized in one pass** | ✗ | ✓ (`quantize_dtype`) |
| **Sparse + palettized in one pass** | ✗ | ✓ (`palettize_nbits`) |
| Schedules / fine-tuning | ✓ | ✗ |
| Size floor | none | `weight_num_threshold=1024` |

`n_m_ratio=(2, 4)` — two zeros in every four consecutive input-channel weights — is the canonical
structured-sparsity pattern that GPU tensor cores exploit on other vendors' hardware. Its presence
here is suggestive.

> 🔴 **GAP — nothing tells us whether Apple silicon exploits `n:m` or block sparsity.** The API
> accepts these patterns; no Apple documentation, session, skill or community measurement in our
> corpus says the ANE or the Apple GPU reads them any faster than dense weights, or that the
> `.aimodel` stores them any smaller. This is the same gap as §11.8, restated at the program level.
> **What would resolve it:** a size + latency comparison of `sparsify_weights(n_m_ratio=(2,4))`
> against dense, on device.
> **Safe default meanwhile:** do not plan a schedule around `n:m` sparsity. If you try it, measure
> the artefact size first — that costs five minutes and answers half the question.

Note the genuinely useful capability in the last two rows of that table: `sparsify_weights` will do
**sparse + palettized in a single pass**, which the PyTorch path cannot express at all (you would
have to prune, finalize, then palettize the result, and `MagnitudePruner.finalize()` produces a
model whose parametrizations the palettizer would then have to survive — untested territory).


---

## 13. Joint compression

**Joint compression** means palettized weights *and* quantized activations in one model. It is a
first-class documented workflow with its own doc page, its own test, and three hard rules.

### 13.1 The three rules

> ✅ **VERIFIED** — `docs/src/utils/joint_compression.md`:
>
> **Rule 1 — the order is mandatory:** *palettize weights → `palettizer.finalize()` → quantize
> activations → calibrate → `quantizer.finalize()`.*
>
> **Rule 2 — you must finalize the palettizer in between**, and the reason is structural:
> *"`quantizer.prepare` uses `torch.export`, which **cannot trace through the parametrizations**."*
>
> **Rule 3 — quantize the LUT, or you have wasted your time:** *"A floating-point LUT causes
> operations to execute in floating-point regardless of the activation quantization, whereas an
> `INT8` LUT allows the runtime to use the faster **W_INT8-A_INT8** execution path where available."*
>
> And the restriction that governs everything else: *"Models compressed via the joint compression
> flow can currently **only be finalized to the `Core AI` backend**."*

Rule 2 deserves a moment. Palettization is eager-only and implemented with parametrizations.
Activation quantization needs graph mode, which needs `torch.export`, which chokes on
parametrizations. So the *only* way to stack them is to collapse the palettization into real ops
first. That is why the flow has an apparently redundant `finalize()` in the middle, and why the
ordering cannot be reversed: quantizing activations first would leave a `GraphModule` that the
eager palettizer's `__torch_function__` interception is not built to walk.

There is a small piece of plumbing that makes rule 2 work at all, and it is worth knowing about
because it explains an otherwise puzzling line in the source:

> ✅ **VERIFIED** — `base_model_compressor.py:21,57-69` registers a non-persistent marker buffer
> `_COREAI_OPT_PREPARED_ATTR = "_coreai_opt_prepared"` so that re-preparing a prepared model raises.
> `KMeansPalettizer.finalize()` **deletes that marker** (`palettization/kmeans/palettizer.py:420-423`)
> *"so the palettized model can be handed to `Quantizer` for joint compression."* Without that one
> line, step 3 of the flow would raise `RuntimeError("Model has already been prepared.")`.

### 13.2 The complete flow

```python
import copy
import torch
import torch.nn as nn

import coreai_opt as opt
from coreai_opt import ExportBackend
from coreai_opt.palettization import (
    KMeansPalettizer, KMeansPalettizerConfig, ModuleKMeansPalettizerConfig, PalettizationSpec,
)
from coreai_opt.palettization.spec import PerGroupedChannelGranularity
from coreai_opt.quantization import Quantizer, QuantizerConfig, ModuleQuantizerConfig
from coreai_opt.quantization.spec import QuantizationSpec, QuantizationScheme
from coreai_opt.quantization.spec import PerTensorGranularity as QuantPerTensor

model = MyModel().eval()
float_model = copy.deepcopy(model)
example_inputs = (torch.randn(1, 3, 224, 224),)     # REPRESENTATIVE data — this seeds qparams

# ── STEP 1: palettize the weights, with an INT8 LUT ────────────────────────────
lut_qspec = QuantizationSpec(
    dtype=torch.int8,
    qscheme=QuantizationScheme.SYMMETRIC,
    granularity=QuantPerTensor(),                   # the only legal LUT granularity
)
palett_config = KMeansPalettizerConfig(
    global_config=ModuleKMeansPalettizerConfig(
        op_state_spec={
            "weight":         PalettizationSpec(n_bits=4, lut_qspec=lut_qspec),
            "in_proj_weight": PalettizationSpec(n_bits=4, lut_qspec=lut_qspec),
        },
    ),
)
palettizer = KMeansPalettizer(model, palett_config)
palettizer.prepare(example_inputs, num_workers=8)

# ── STEP 2: finalize the palettizer — MANDATORY, not optional ─────────────────
palettized_model = palettizer.finalize(backend=ExportBackend.CoreAI)

# ── STEP 3: quantize activations ONLY, on the palettized model ────────────────
act_spec = QuantizationSpec(dtype=torch.int8, qscheme=QuantizationScheme.SYMMETRIC)
quant_config = QuantizerConfig(
    global_config=ModuleQuantizerConfig(
        op_state_spec=None,               # ← weights are ALREADY compressed. None == "leave alone".
        op_input_spec={"*": act_spec},
        op_output_spec={"*": act_spec},
    ),
)
quantizer = Quantizer(palettized_model, quant_config)
prepared_model = quantizer.prepare(example_inputs)

# ── STEP 4: calibrate the activation ranges ───────────────────────────────────
with quantizer.calibration_mode():
    for batch in calibration_dataloader:      # ~128 representative samples
        prepared_model(batch)

# ── STEP 5: finalize to Core AI. This is the ONLY legal backend here. ─────────
final_model = quantizer.finalize(backend=ExportBackend.CoreAI)
```

> ✅ **VERIFIED** — this is `docs/src/utils/joint_compression.md`'s flow, with the config shapes
> checked against the class definitions. The critical line is `op_state_spec=None` in step 3: that
> is the `None`-means-disable semantics from guide 01 §4.3, and getting it wrong means you
> **quantize weights that are already palettized** — a second lossy pass over data that has already
> been through k-means.

### 13.3 What it costs, measured by Apple

> ✅ **APPLE-PUBLISHED** — `docs/src/examples/edsr.md`. Model: `edsr_r16f64` super-resolution,
> 1.5 M parameters; evaluated on **B100**, with **20 calibration** and **80 evaluation** samples:
>
> | Configuration | PSNR | Weight storage |
> |---|---|---|
> | FP32 baseline | **30.68 dB** | ~5.5 MB |
> | W_INT8 _ A_INT8 | 30.33 dB (−0.35) | ~1.4 MB (**4×**) |
> | **W_P4(INT8) _ A_INT8 joint** | 29.86 dB (−0.47 more) | **~0.7 MB (8×)** |

Read the deltas. Going from fp32 to int8-weight/int8-activation costs **0.35 dB** and buys 4×.
Going from there to 4-bit palettized weights with an int8 LUT costs **another 0.47 dB** and buys a
further 2×. Both are cheap by the standards of §16's gates, and the second step is the one that
takes you from "fits comfortably" to "fits on a phone".

> ✅ **APPLE-PUBLISHED** — the reference tests, which double as acceptance thresholds:
> `tests/test_joint_compression.py::test_p4a8_compression_mnist_accuracy` (marked
> `@pytest.mark.slow`, skipped without `coreai`) asserts an MNIST baseline of **> 97.0%** and joint
> P4-A8 after calibration of **> 90.0%**, and asserts `post_calib_acc == finalized_acc` for
> `ExportBackend._TORCH` — i.e. **finalize must be numerically exact for the torch backend**. The
> MNIST model has 6 weight-bearing layers (`conv1`, `conv2`, `conv_transpose1`, `conv_transpose2`,
> `dense1`, `dense2`), `batch_size=128`, `num_calibration_batches=17`.
> There is a matching export test: `tests/export/test_pt2e_mlir_export.py::test_mnist_p4a8_compression_export`.

That MNIST assertion is a useful sanity target for your own pipeline. If your joint-compressed
toy model does not land within a few points of its float baseline, something is misconfigured
rather than fundamentally lossy.

### 13.4 Things that go wrong

- **You forgot `lut_qspec`.** Everything runs; the model is smaller; the activation quantization
  bought you nothing because the fp LUT forces floating-point ops. Nothing warns you. Symptom: your
  measured latency does not improve at all.
- **You left `op_state_spec` at its default in step 3.** Weights get quantized on top of being
  palettized. Symptom: quality drops far more than the EDSR numbers suggest it should.
- **You used `torch.randn` for `example_inputs` or for calibration.** The initialisation forward
  pass in `prepare()` seeds the activation qparams, and `calibration_mode()` refines them. Random
  data gives you ranges that have nothing to do with your model's real activations. Apple's docs
  say this three separate times, which is a strong hint about how often it happens.
- **You tried `finalize(backend=ExportBackend.CoreML)`.** Not supported for joint compression, by
  documented restriction.
- **You expected `ExportBackend.CoreML` to accept the int8 LUT anyway.** It does accept int8 LUTs
  (`COREML_SUPPORTED_LUT_DTYPES = {int8, uint8}`) — but the joint *flow* is Core-AI-only regardless,
  and the palettization at-most-one rule (§9.3) will catch you if you also wanted per-channel scale.


---

## 14. Mixed precision

Uniform compression is a simplifying assumption, and it is almost always the wrong one. Layers
differ enormously in how much error they tolerate — by orders of magnitude, not percentages — and a
single global bit-width is therefore either too aggressive for the sensitive layers or too timid for
the rest. Usually both at once.

`coreai-opt` treats mixed precision as a first-class documented workflow with its own doc page
(`docs/src/utils/mixed_precision.md`) and its own worked example
(`docs/src/examples/mixed_precision_palettization.md`). Neither appears in any session.

### 14.1 The result that makes the case

> ✅ **APPLE-PUBLISHED** — `docs/src/examples/mixed_precision_palettization.md`. ResNet50 palettized,
> evaluated on the **full ImageNet validation set (50,000 images)** on the **mps** backend:
>
> | Configuration | BPW | Size | Top-1 |
> |---|---:|---:|---:|
> | FP16 baseline | 16 | 48.64 MB | **75.02%** |
> | Uniform 4-bit per-tensor | 4 | 12.16 MB | 65.87% |
> | **Greedy mixed precision (target 4)** | **3.95** | **12.03 MB** | **70.27%** |

Read those three rows carefully, because the comparison is not the one people expect.

The mixed-precision model is **smaller** than the uniform 4-bit model — 12.03 MB against 12.16 MB,
3.95 BPW against 4.00 — and it recovers **4.4 percentage points** of top-1 accuracy. It is not
trading size for quality. It is spending the *same* budget more intelligently.

The recipe it found:

> ✅ **APPLE-PUBLISHED** — same page. Distribution across 54 configured layers:
> **2 layers at 6-bit** (`conv1`, `layer1.0.downsample.0`), **50 layers at 4-bit**, **2 layers at
> 2-bit** (`layer1.1.conv1`, `layer3.4.conv2`).

Two layers get *more* bits, two get *fewer*, fifty stay put. That is the entire delta, and it is
worth 4.4 points. Note which two got more: `conv1` is the **stem** — the very first convolution,
seeing raw pixels — and `layer1.0.downsample.0` is a **projection shortcut**. Both are boundary
layers in the sense §17.2 describes.

And the shape of the curve:

> ✅ **APPLE-PUBLISHED** — same page, verbatim: the curve has an inflection at **≈ 4.0 realized
> BPW**: *"below it, every additional 0.5 BPW buys us **15-35 percentage points** of accuracy; above
> it, gains drop to **1-2 points** per 0.5 BPW."*

```
  top-1
   75% ┤                                       ╭──────────────●  fp16 (16 bpw)
       │                            ╭──────────╯
   70% ┤                     ● 3.95 ╯  ← mixed precision
       │                   ╭╯
   65% ┤            ● 4.00 ╯           ← uniform 4-bit per-tensor
       │          ╭╯
   60% ┤        ╭╯
       │      ╭╯                 ▲
   40% ┤   ╭─╯                   │  inflection ≈ 4.0 BPW
       │ ╭─╯                     │  below: 15-35 pts per 0.5 BPW
   20% ┤╯                        │  above:  1-2  pts per 0.5 BPW
       ┼────┬────┬────┬────┬────┬────┬────►  realized BPW
       2   2.5   3   3.5   4   4.5   5
```

That inflection is the single most actionable fact in this section. It says:

- **Above ~4 BPW, buying more bits is a bad deal.** You are paying 12.5% more storage for one
  accuracy point.
- **Below ~4 BPW, giving up bits is catastrophic.** A layer pushed from 4 to 3.5 effective bits can
  cost you tens of points.
- Therefore the *right* mixed-precision strategy is not "shave everything a bit" — it is
  **"keep almost everything at the inflection, and move a handful of layers in each direction."**
  Which is exactly the recipe Apple found.

### 14.2 The workflow

> ✅ **VERIFIED (shape)** — the method is described consistently in
> `docs/src/utils/mixed_precision.md` and in the community's reading of the same material:
> per-layer bit-widths come from a **layer-sensitivity sweep** — compress one layer at a time,
> score by PSNR — then walk **least-loss-first** toward a target average bit-width.

The algorithm in words:

1. **Baseline.** Score the uncompressed model on your metric. Record it.
2. **Sensitivity sweep.** For each compressible layer *L*, and for each candidate bit-width *b*:
   compress **only** *L* to *b*, leave everything else uncompressed, score. You now have a
   `(layer, bits) → quality_loss` table. This is `n_layers × n_bit_widths` evaluations, and it
   parallelises perfectly.
3. **Greedy assignment.** Start with every layer at its highest candidate bit-width. Repeatedly pick
   the `(layer, next-lower-bits)` move with the **smallest quality loss per bit saved**, apply it,
   and recompute the average bit-width. Stop when you hit your target.
4. **Verify jointly.** The sweep measured layers *in isolation*; errors compound. Score the final
   configuration end-to-end and expect it to be somewhat worse than the sum of the parts.

Step 4 is not optional and is the step people skip. A per-layer sensitivity table is a *heuristic
ranking*, not an additive error model.

> 🔴 **GAP — no verified helper API for the greedy search.** `docs/src/utils/mixed_precision.md`
> documents the workflow and `docs/src/examples/mixed_precision_palettization.md` reports its
> results, but **we did not read the page's code listings**, and no function name for the sweep or
> the greedy walk appears in `coreai_opt.__all__`, `coreai_opt.palettization.__all__`, or any
> package `__init__` we verified. The top-level public surface is
> `{CoreMLExportError, ExportBackend, __version__}` plus the three technique subpackages — there is
> no `mixed_precision` module in the package tree listing.
> **What would resolve it:** `make api-list` output, or reading
> `docs/src/utils/mixed_precision.md` end to end.
> **Safe default meanwhile:** write the twenty lines yourself (§14.3). Everything the loop needs —
> per-module config overrides, `prepare()` without `finalize()`, a scoreable torch model — is
> verified API. **Do not invent a `coreai_opt.mixed_precision.*` import; if you see one in
> circulation, it is not from this corpus.**

### 14.3 Writing the sweep yourself

Every primitive this needs is verified. The only thing you supply is a scoring function.

```python
"""Per-layer sensitivity sweep + greedy bit assignment for palettization.

Uses only verified coreai-opt APIs:
  - KMeansPalettizerConfig / ModuleKMeansPalettizerConfig / PalettizationSpec
  - config.set_global(None) + config.set_module_name(name, cfg)
  - KMeansPalettizer(...).prepare(...)   [NO finalize() — Apple's skill says don't]
"""
from __future__ import annotations

import copy
import itertools
from dataclasses import dataclass

import torch
import torch.nn as nn

from coreai_opt.palettization import (
    KMeansPalettizer, KMeansPalettizerConfig, ModuleKMeansPalettizerConfig, PalettizationSpec,
)
from coreai_opt.palettization.spec import PerGroupedChannelGranularity

CANDIDATE_BITS = (8, 6, 4, 2)          # legal values are {1,2,3,4,6,8} — no 5, no 7
GROUP_SIZE = 32


def _spec(n_bits: int) -> PalettizationSpec:
    return PalettizationSpec(
        n_bits=n_bits,
        granularity=PerGroupedChannelGranularity(axis=0, group_size=GROUP_SIZE),
        # enable_per_channel_scale left False — see §5. Do not turn this on for ANE targets.
    )


def _module_cfg(n_bits: int) -> ModuleKMeansPalettizerConfig:
    s = _spec(n_bits)
    return ModuleKMeansPalettizerConfig(op_state_spec={"weight": s, "in_proj_weight": s})


def _config_for(assignment: dict[str, int]) -> KMeansPalettizerConfig:
    """Build a config that palettizes ONLY the named modules, each at its own bit-width."""
    cfg = KMeansPalettizerConfig(global_config=None)      # None == compress nothing by default
    for module_name, n_bits in assignment.items():
        # module_name_configs keys are regexes matched with re.fullmatch — escape dots.
        cfg.set_module_name(module_name.replace(".", r"\."), _module_cfg(n_bits))
    return cfg


def palettizable_modules(model: nn.Module) -> list[str]:
    """Modules whose forward reaches a palettizable op (§2.6)."""
    kinds = (nn.Linear, nn.Conv1d, nn.Conv2d, nn.Conv3d,
             nn.ConvTranspose1d, nn.ConvTranspose2d, nn.ConvTranspose3d,
             nn.MultiheadAttention)
    return [n for n, m in model.named_modules() if isinstance(m, kinds)]


def check_divisibility(model: nn.Module, names: list[str], group_size: int) -> list[str]:
    """Pre-flight the SILENT SKIP in §19.1: axis-0 size must be divisible by group_size."""
    bad = []
    for n in names:
        mod = model.get_submodule(n)
        w = getattr(mod, "weight", None)
        if w is None:
            w = getattr(mod, "in_proj_weight", None)
        if w is not None and w.shape[0] % group_size != 0:
            bad.append(f"{n}: shape[0]={w.shape[0]} not divisible by {group_size}")
    return bad


@dataclass
class Cell:
    module: str
    n_bits: int
    loss: float          # baseline_score - score, higher is worse
    numel: int


def sweep(model: nn.Module, example_inputs: tuple, score, baseline: float,
          names: list[str], num_workers: int = 8) -> list[Cell]:
    """One layer at a time, one bit-width at a time. Embarrassingly parallel across cells."""
    cells: list[Cell] = []
    for name, n_bits in itertools.product(names, CANDIDATE_BITS):
        work = copy.deepcopy(model)                     # prepare() mutates in place — §2.4
        palettizer = KMeansPalettizer(work, _config_for({name: n_bits}))
        prepared = palettizer.prepare(example_inputs, num_workers=num_workers)
        # NOTE: no finalize(). The prepared model is scoreable and finalize() is destructive (§10.2).
        numel = model.get_submodule(name).weight.numel()
        cells.append(Cell(name, n_bits, baseline - score(prepared), numel))
        del work, prepared, palettizer
    return cells


def greedy_assign(cells: list[Cell], names: list[str], target_bpw: float) -> dict[str, int]:
    """Start everyone at the top bit-width; take the cheapest bit-per-loss move until at target."""
    by_cell = {(c.module, c.n_bits): c for c in cells}
    numel = {c.module: c.numel for c in cells}
    total = sum(numel[n] for n in names)

    assignment = {n: max(CANDIDATE_BITS) for n in names}
    ladder = sorted(CANDIDATE_BITS, reverse=True)

    def bpw(a: dict[str, int]) -> float:
        return sum(numel[n] * b for n, b in a.items()) / total

    while bpw(assignment) > target_bpw:
        best, best_cost = None, float("inf")
        for n, cur in assignment.items():
            i = ladder.index(cur)
            if i + 1 >= len(ladder):
                continue
            nxt = ladder[i + 1]
            bits_saved = (cur - nxt) * numel[n]
            delta_loss = by_cell[(n, nxt)].loss - by_cell[(n, cur)].loss
            cost = delta_loss / max(bits_saved, 1)      # loss per bit saved
            if cost < best_cost:
                best, best_cost = (n, nxt), cost
        if best is None:
            break                                        # everyone is at the floor
        assignment[best[0]] = best[1]
    return assignment
```

Driving it:

```python
baseline_score = score(model)
names = palettizable_modules(model)

problems = check_divisibility(model, names, GROUP_SIZE)
if problems:
    raise SystemExit("These layers would be SILENTLY SKIPPED:\n  " + "\n  ".join(problems))

cells = sweep(model, example_inputs, score, baseline_score, names, num_workers=8)
assignment = greedy_assign(cells, names, target_bpw=4.0)

# STEP 4 — verify jointly. Isolated sensitivity is a ranking, not an error model.
final = copy.deepcopy(model)
final_prepared = KMeansPalettizer(final, _config_for(assignment)).prepare(example_inputs, num_workers=8)
print("joint score:", score(final_prepared), "target bpw:", 4.0)
```

The `check_divisibility` pre-flight is not decoration — it is the difference between a sweep whose
size numbers mean something and one whose "compressed" layers were quietly left dense.

### 14.4 Apple's shipped mixed-precision configs

The clearest evidence that Apple treats this as production practice rather than a demo: the LLM
export registry references **hand-written mixed-precision YAML** for two Qwen3 models on iOS.

> ✅ **VERIFIED** — `apple/coreai-models`, `python/src/coreai_models/llm/model_registry.py`, iOS
> variants:
>
> | short_name | hf_id | compression |
> |---|---|---|
> | `qwen3-0.6b` | `Qwen/Qwen3-0.6B` | `none` + `compression_config="models/qwen3/qwen3_0_6b_mixed_4bit_8bit.yaml"` |
> | `qwen2.5-1.5b-instruct` | `Qwen/Qwen2.5-1.5B-Instruct` | `4bit_weight_palettized_group8` |
> | `qwen3-4b` | `Qwen/Qwen3-4B` | `none` + `compression_config="models/qwen3/qwen3_4b_mixed_4bit_8bit.yaml"` |

And the quality it buys, published:

> ✅ **APPLE-PUBLISHED** — WikiText-2 perplexity via lm-evaluation-harness, from `models/*/README.md`.
> BPW marked `*` includes the INT8-per-tensor embedding (§6.4):
>
> | Model | Compression | BPW | Platform | Perplexity |
> |---|---|---:|---|---:|
> | Qwen3 0.6B | none (float16) | 16.00 | iOS | 26.16 |
> | Qwen3 0.6B | **Mixed 4-bit/8-bit palettized (YAML)** | **5.71\*** | iOS | 30.90 |
> | Qwen3 4B | none (float16) | 16.00 | iOS | 16.41 |
> | Qwen3 4B | **Mixed 4-bit/8-bit palettized (YAML)** | **4.89\*** | iOS | 18.80 |
> | Qwen3 4B | none (float16) | 16.00 | macOS | 16.41 |
> | Qwen3 4B | 4-bit **quantized** | 4.50 | macOS | 18.33 |
> | Qwen2.5 1.5B Instruct | none | 16.00 | iOS | 12.21 |
> | Qwen2.5 1.5B Instruct | 4-bit palettized (gs 8) | 4.63\* | iOS | 14.64 |

Two observations that are easy to miss:

- **The 0.6B model pays much more than the 4B model.** 26.16 → 30.90 is a **+18%** perplexity
  regression at 5.71 BPW; 16.41 → 18.80 is **+15%** at a *lower* 4.89 BPW. Small models have less
  redundancy to give up. If your model is under a billion parameters, budget for a worse
  compression curve than the papers promise.
- **Apple did not use uniform palettization for these two.** The registry entry is literally
  `compression="none"` plus a YAML file, meaning the preset system was insufficient and someone
  hand-wrote per-module bit-widths. That is the strongest possible signal about how well uniform
  4-bit works on a small transformer.

### 14.5 Writing the YAML

Mixed precision is where YAML earns its place, because the file is the artefact you version and
review rather than a Python function that produces one.

> ✅ **VERIFIED** — `KMeansPalettizerConfig._CONFIG_KEY = "kmeans_palettization_config"`,
> `_SPEC_KEY = "palettization_spec"`. Loading: `KMeansPalettizerConfig.from_yaml(path)` uses
> `yaml.safe_load`; an **empty** file emits `warnings.warn("Empty YAML content detected, returning
> None …")` and **returns `None`**; a non-mapping raises `ValueError`; unexpected top-level keys
> raise `RuntimeError`. The only allowed top-level keys are `_CONFIG_KEY` and `_SPEC_KEY` — the
> latter exists *purely to host YAML anchors*.
> ✅ **VERIFIED** — the exporter's loader (`coreai_models/llm/export.py:163-237`) additionally
> requires **exactly one** coreai-opt top-level key after popping an optional `coreai_models:` block,
> which may contain only `{"calibrate_activations"}`; and `kmeans_palettization_config` **requires
> `--platform iOS`**.

```yaml
# mixed_4bit_8bit.yaml — anchors live under palettization_spec, config under kmeans_palettization_config
palettization_spec:
  p8: &p8
    n_bits: 8
    granularity: {type: per_grouped_channel, axis: 0, group_size: 32}
  p4: &p4
    n_bits: 4
    granularity: {type: per_grouped_channel, axis: 0, group_size: 32}

kmeans_palettization_config:
  global_config:
    op_state_spec:
      weight: *p4
      in_proj_weight: *p4
  module_name_configs:
    # Boundary layers keep more bits (§17.2).
    'model\.layers\.0\..*':
      op_state_spec: {weight: *p8, in_proj_weight: *p8}
    'model\.layers\.(2[0-9])\..*':
      op_state_spec: {weight: *p8, in_proj_weight: *p8}
    # Leave the head alone entirely. null == "do not compress this scope".
    'lm_head': null
```

```python
from coreai_opt.palettization import KMeansPalettizerConfig
config = KMeansPalettizerConfig.from_yaml("mixed_4bit_8bit.yaml")
```

Three YAML-specific reminders, all verified in guide 01 §5.4 and unchanged here: keys under
`module_name_configs` are **`re.fullmatch` regexes** (so escape your dots, and remember that
`model\.layers\.1\..*` matches layer 1 but not layer 10 — `model\.layers\.1[0-9]\..*` does);
`module_type_configs` keys must be **fully-qualified** class paths; and `null` means *disable*,
which is not the same as omitting the entry.

> ⚠️ **The registry YAMLs are source-tree-only.** ✅ **VERIFIED** —
> `_resolve_registry_compression_config` raises `SystemExit` when running from a wheel:
> *"Registry preset references &lt;path&gt;, but the YAML lives in the source tree which is
> unavailable in this install."* If you want to read Apple's actual mixed-precision recipes, clone
> `apple/coreai-models`; `pip install` will not give them to you.


---

## 15. Choosing per layer: the sweep, the Debugger, and SAM3

Three different mechanisms in this stack answer the same question — *which layers tolerate
compression?* — and they answer it at three different points in the workflow. Most people know
about one of them.

| Mechanism | Where it runs | What it tells you | Cost |
|---|---|---|---|
| **Layer-sensitivity sweep** (§14) | PyTorch, before conversion | which layer × bit-width cells are cheap | `n_layers × n_bits` evaluations |
| **Apple's `model-compression-exploration` skill** | PyTorch, agent-driven | ~60 configs across the Pareto frontier | hours, parallelised |
| **Core AI Debugger** (Part 10) | after conversion, per-op | which *op* diverged, with PSNR per sync point | one comparison run |

They compose. The sweep tells you what to try; the Debugger tells you what actually broke.

### 15.1 The SAM3 diagnosis, and why it belongs here

Guide 01 §13 tells the SAM3 story from the quantization side: `presets.w4()` applied uniformly to an
850 M-parameter model, 3 GB → ~430 MB, and an occluded flower that stops being detected. The
diagnosis is worth repeating here because the *fix* is a mixed-precision fix.

> ✅ **VERIFIED** — WWDC26 session 325, 325:156–162, verbatim:
> > *"I'm noticing that **the vast majority of low-PSNR sync points are actually coming from the
> > detector decoder**. This tells me that the quantization scheme applied earlier has **mildly
> > corrupted the detector results**. Since we previously identified that **the detector block only
> > accounts for 4% of model parameters, we're not getting much benefit from compressing it
> > anyway**. So, I'll return to the Jupyter notebook, and try **changing the quantization scheme to
> > ignore the detector**."*
> > *"Great! I can see that we have **once again reached baseline quality** where all flowers are
> > detected and the model is only a fraction of the size! Core AI Debugger turned hours of manual
> > tensor comparison into a visual diagnosis. I started with missing detections and reached a
> > revised quantization scheme in minutes."*

The mechanism is the one this guide has used repeatedly:

```python
# The SAM3 move: compress everything, leave one subtree alone.
config = KMeansPalettizerConfig.presets.w4(group_size=32)
config.set_module_name(r"detector\..*", None)     # None == "leave this alone"
```

Two lessons generalise beyond SAM3:

1. **Parameter share and sensitivity are usually anti-correlated.** The detector is 4% of the
   parameters and 100% of the problem. Compressing it saves nothing measurable and costs
   everything. Before you compress a block, ask what fraction of your bytes it actually is — if the
   answer is under 5%, skip it and stop thinking about it.
2. **The final layers of a network are where errors become visible.** Every upstream error has
   already been absorbed or amplified by the time it reaches the decoder, and the decoder's job is
   to make discrete decisions (is this a detection?) where small numeric shifts flip outcomes.

### 15.2 The three-function split also selects `coreai-models`’ ANE preference

Session 325 presents the three-entrypoint split (`image_encode` / `text_encode` / `detect`) as a
**latency trick** — run each at a different cadence, and get a 76%-faster second inference when only
the prompt changes.

> ✅ **VERIFIED** — WWDC26 session 325, 325:255–256: *"here's the payoff of the three-function split.
> **I swapped the prompt to butterfly and only re-ran the text encoder and the detector.** As a
> result, the **second inference is 76% faster, even after warmup.**"*

Reading the optional `coreai-models` Swift package shows the split also selects **that loader’s
Neural Engine preference**. This is package policy, not a Core AI framework naming contract; direct
`AIModel` callers choose their own `SpecializationOptions`.[^sample-routing-policy] It still bears
directly on compression when you adopt that loader because intended ANE residency affects the
appropriate format (§1.2). Part 10 covers the policy; the compression-side consequence is simply this:
**if you split a model into per-cadence functions, you can and should give each function its own
compression config**, which is precisely what the SAM3 recipe does (§5.4).

> ⚠️ **The 76% number requires caller-side work Apple's own package does not do.**
> `CoreAISegmentationEngine` **re-runs `image_encode` on every call** and exposes no cache. If you
> want the figure, you cache the backbone features yourself. Part 7 covers this.

### 15.3 Apple's `model-compression-exploration` skill

Apple ships an agent skill that automates the sweep. Even if you never run it, its contents are the
closest thing to an Apple-endorsed compression methodology that exists, and it is worth mining.

> ✅ **VERIFIED** — `skills/skills/model-compression-exploration/SKILL.md` in `apple/coreai-models`.
> It drives roughly **30 main-sweep + 30 refinement** `coreai_opt` configurations.
>
> **Step 3 timing probe:** start with `QuantizerConfig.presets.w8()` (graph mode default); if
> `Quantizer.prepare` fails, fall back to
> `QuantizerConfig.presets.w8(execution_mode=ExecutionMode.EAGER)` **for the whole sweep**.
> `KMeansPalettizerConfig.presets.w6()` = 6-bit, per-grouped-channel, `group_size=16`;
> **palettization is eager-only**.
>
> **The three config groups:**
> - **1a — channel-structured quantization** (6 configs): `{int8, int4} × {symmetric, asymmetric,
>   symmetric_with_clipping}`
> - **1b — block-structured quantization** (9 configs): int4 per-block ×
>   `{block_size 16, 32, 128} × {3 qschemes}`
> - **2 — palettization** (15 configs): `{(8-bit per-tensor), (6-bit per-tensor),
>   (6-bit gs 4/8/16), (4-bit gs 4/8/16)} × {enable_per_channel_scale True/False}`
>
> **Preset anchors:** `presets.w8()` / `w4()` (per-channel symmetric),
> `presets.w4_per_block(block_size=32)`, `KMeansPalettizerConfig.presets.w8()/w6()/w4()`.
>
> **Refinement pass:** filter out configs with **PSNR < 10 dB** or **IoU < 0.1**, pick the 95th and
> 75th percentile survivors as seeds, and generate **5 layer-skip variants each** via
> `set_module_name` overrides.
>
> **Operational rules:** *"Do **not** call `finalize()`"*; *"Calibration is not needed for
> weight-only compression."*
>
> **Pitfalls it names:** per-block / per-grouped-channel **silently skip** layers whose weight
> dimension is not divisible (pre-check with `check_divisibility()`); scale/ZP overhead is **5-15%**
> at 2-4 bit fine granularity; an **8-bit per-channel LUT stores 256 × fp16 entries per output
> channel**; at `block_size=16` + int4 the effective width is **~5 bits**.
>
> **Output record shape, verbatim:**
> ```json
> {"group":"2",
>  "config":{"name":"palette_grouped_gs4_6bit_pcs0_skip-Embedding","path":"path/to/config"},
>  "time_taken":1000,
>  "output_quality_metrics":[{"name":"bbox","metric":"iou","value":0.7},
>                            {"name":"logits","metric":"psnr","value":16}],
>  "compression_metrics":{"average_bitwidth":5,"compression_ratio":1.7,"theoretical_model_size":402}}
> ```
>
> **Report format:** exactly **5 configs per group** spanning the Pareto frontier; columns
> `Config | PSNR (dB) | Avg Bitwidth | Compression Ratio`; a scatter plot saved as
> `compression_exploration.png`.
>
> **Parallelisation:** one subagent per group appending to a shared `results.jsonl`; the main agent
> polls with `/loop 5m`. Bundled scripts: `scripts/compression_metrics.py` (theoretical size, average
> bitwidth, divisibility, parametrize walk) and `scripts/quality_metrics.py` (PSNR / SNR / IoU plus a
> dispatcher).

Five things in that specification are worth stealing whether or not you use an agent:

1. **The config-name convention** — `palette_grouped_gs4_6bit_pcs0_skip-Embedding` encodes scheme,
   group size, bit-width, per-channel-scale flag and skip-list in one string. Adopt something like it;
   sweep results are useless if you cannot tell what produced them six weeks later.
2. **Two metrics, not one.** The record carries both a task metric (`iou` on `bbox`) and a numeric
   metric (`psnr` on `logits`). PSNR alone will happily tell you a model is fine when its detections
   have collapsed.
3. **The PSNR < 10 dB / IoU < 0.1 filter.** Below those, a config is not "worse" — it is broken, and
   including it distorts every percentile you compute.
4. **Pareto framing.** "Five configs spanning the frontier" is the right deliverable. A single
   "best" config is a decision you have taken away from whoever ships the model.
5. **The `enable_per_channel_scale True/False` axis in group 2.** Note that the skill *does* sweep
   it — meaning it is a legitimate quality lever. Just re-read §5 before you let a sweep pick
   `pcs1` for an ANE target: the sweep is scoring **PyTorch quality**, and it has no idea it just
   moved your model to the GPU.

That last point is the most important interaction in this guide. **An automated sweep optimising
PSNR will choose `enable_per_channel_scale=True` every time, because it improves PSNR, and it will
never tell you what it cost.** If you run this skill against an iOS target, constrain the search
space to `pcs0` before you start.

### 15.4 The `.aimodel` is a build artefact, not a pure function of the recipe

One more caution before you treat any sweep result as durable.

> 🟢 **COMMUNITY-MEASURED** — `notes/repos/john-rocky-models.md`, single-author, uncontrolled:
> *"**An `.aimodel` is a build artefact, not a pure function of the recipe**"* — the same
> `coreai.llm.export qwen3-0.6b` invocation produced a **2.2× faster artefact on macOS 26 than on
> the 27 beta**, attributed to loss of native quantized-Linear lowering (same code, same wheels).
> *"**Version-stamp and keep your artifacts.**"*
> ⚠️ Beta-era measurement; the mechanism is identified but not Apple-confirmed. Treat it as a reason
> to record your toolchain version alongside every sweep result, not as a claim about any shipping
> OS.

### 15.5 Hand-off to the Debugger

The sweep gives you a ranking. The Debugger gives you a diagnosis. Use the second when the first
does not explain what you are seeing — specifically, when a configuration the sweep predicted would
be fine is not fine.

What Part 10 covers, and why it matters here:

> ✅ **VERIFIED** — WWDC26 session 325, 325:139–152. The Debugger builds a **comparison session**
> between a specialized Core AI model and a PyTorch reference loaded from an **Intermediates File**.
> The navigator fills with **operation pairs** — *"These pairs are called **sync points**, places
> where the specialized model's output is **expected to match** the original PyTorch result. The
> debugger automatically identifies these points throughout the model."* Each carries a similarity
> metric; **"The default metric is a peak signal-to-noise ratio or PSNR, but this can be changed to
> whichever similarity indicator suits your model best."** Green = similar, yellow = moderately
> diverged, red = significantly different. The workflow is *"sort by similarity"* then use the
> **up-arrow key** to walk the low-PSNR sync points *"one-by-one to see if a pattern emerges"*, with
> the source viewer showing each op's **PyTorch module hierarchy**.

The reason that last detail matters for compression: the source viewer maps a diverging *op* back to
a PyTorch *module path* — which is exactly the string you need for `set_module_name(...)`. The
Debugger's output is directly actionable as a config change, and that round trip is the whole
workflow:

```
   sweep  ──►  a config that looks good on paper
       │
       ▼
   convert + run  ──►  quality is not what the sweep predicted
       │
       ▼
   Debugger: sort sync points by PSNR, walk the reds
       │
       ▼
   source viewer gives you  "detector.decoder.layers.3.self_attn"
       │
       ▼
   config.set_module_name(r"detector\.decoder\..*", None)   ──►  re-measure
```

> 🔴 **GAP — the Debugger's available similarity metrics are not enumerated.** Session 325 says the
> metric *"can be changed to whichever similarity indicator suits your model best"* but never lists
> the options, and no doc page in our corpus does either. **What would resolve it:** the Debugger's
> metric picker in Xcode 27, or an Apple doc page. **Safe default meanwhile:** PSNR is the default
> and is what every Apple acceptance gate in §16 is expressed in; use it, and carry a task metric
> alongside it as §15.3's record format does.


---

## 16. Apple's PSNR acceptance gates

There is no Apple documentation page titled "how good does my compressed model have to be". There
is something better: Apple wrote acceptance thresholds into an agent skill, because an agent needs a
number to decide against. Those numbers are the closest thing to an official standard that exists,
and this guide treats them as one.

### 16.1 The authoring gates

> ✅ **VERIFIED** — `skills/skills/model-authoring/SKILL.md:94-99`, vendored in `apple/coreai-models`:
>
> | Comparison | Gate |
> |---|---|
> | **Re-authored model vs source model** (both PyTorch) | **> 70 dB** |
> | **ANE-layout vs GPU-layout** (both PyTorch) | **> 70 dB** |
> | **Compiled Core AI model vs torch** | **≥ 40 dB** |
> | **After 4-bit palettization** | **≥ 35 dB** |

Four numbers, and the *structure* of the ladder is as informative as the values.

**The first two gates are about work you did, and they are strict.** Re-authoring a model for the
Neural Engine — swapping `nn.Linear` for `nn.Conv2d(1×1)`, converting to BC1S layout, splitting
attention per head — must be **numerically transparent**. 70 dB is essentially "the same tensor with
fp16 rounding noise". If your re-authored model scores 55 dB against the original, you did not
re-author it; you changed it, and you have a bug. Same for ANE-layout vs GPU-layout: two layouts of
the same math must agree.

**The third gate is about the toolchain, and it is much looser.** 40 dB accepts real fp16 numerical
drift through compilation, fusion and `optimize()`. That is a 30 dB relaxation from the authoring
gates, and it tells you Apple expects conversion to cost you real precision.

**The fourth gate is about compression, and it is looser still.** 35 dB after 4-bit palettization
is the floor below which Apple's own skill says investigate.

The ladder in one line: **your code must be exact, the toolchain may drift, compression may cost.**

### 16.2 The sizing table that goes with them

> ✅ **VERIFIED** — same skill, palettization sizing guidance:
>
> | Bit-width | Expected compression | Expected PSNR | Flag for investigation below |
> |---|---|---|---|
> | 8-bit | ≈ 2× | **> 55 dB** | < 50 dB |
> | 4-bit | ≈ 4× | **~ 40 dB** | < 35 dB |
> | 2-bit | ≈ 8× | 25–35 dB | — *"Usually unacceptable"* |

And a second, differently-scoped table from the deployment side of the same skills tree:

> ✅ **VERIFIED** — `skills/skills/model-deployment` (PSNR acceptance table):
>
> | Scenario | Expected PSNR | Investigate if below |
> |---|---|---|
> | float32 end-to-end | > 70 dB | 60 dB |
> | fp16 on-device | > 50 dB | 40 dB |
> | 4-bit palettized | ~40 dB | 30 dB |

The two tables agree on the shape and differ slightly on the thresholds (35 vs 30 for 4-bit; 40 vs
50 for the compiled/fp16 tier). They are scoped differently — one is an authoring gate, one is a
deployment expectation — and the difference is small enough not to matter in practice. Use the
**stricter** number as your CI gate and the looser one as your "do not ship below this" floor.

### 16.3 Using them

```python
import torch

def psnr(reference: torch.Tensor, candidate: torch.Tensor) -> float:
    """Peak signal-to-noise ratio in dB, using the reference's dynamic range as peak."""
    reference = reference.detach().float()
    candidate = candidate.detach().float()
    mse = torch.mean((reference - candidate) ** 2)
    if mse == 0:
        return float("inf")
    peak = reference.abs().max()
    return float(20 * torch.log10(peak / torch.sqrt(mse)))


GATES = {
    "reauthored_vs_source":   70.0,   # strict: your code must be transparent
    "ane_layout_vs_gpu":      70.0,   # strict: two layouts, same math
    "compiled_vs_torch":      40.0,   # loose: toolchain drift is expected
    "palettized_4bit":        35.0,   # loosest: compression costs
}

def gate(name: str, value: float) -> None:
    threshold = GATES[name]
    verdict = "PASS" if value >= threshold else "INVESTIGATE"
    print(f"{name:<24} {value:6.2f} dB   (gate {threshold:.0f} dB)   {verdict}")
```

Three practical notes on applying them:

- **PSNR is peak-relative, so it is scale-sensitive.** Comparing logits (unbounded, occasionally
  enormous) against comparing a normalised feature map will give you very different dB for the same
  relative error. Fix a convention and keep it.
- **Gate per output, not on a mean.** A model with four outputs where three score 80 dB and one
  scores 12 dB has an average of 63 dB and a broken output.
- **Carry a task metric alongside.** §15.3's record format does exactly this — `psnr` on `logits`
  *and* `iou` on `bbox`. For an autoregressive model, the equivalent of a task metric is
  **greedy-token agreement over a real generation**, not a single-step logit comparison; see §17.1.

### 16.4 The gate that is not a PSNR gate

For LLM decoders, dB is a poor proxy, and the community archive is emphatic about why:

> 🟢 **COMMUNITY-MEASURED** — `notes/repos/john-rocky-models.md`, single-author, uncontrolled
> benchmarks. Its pass bar for a language model is *"per-token cosine ≥ 0.999 on logits **AND**
> greedy argmax token-exact"* across a real generation, with the reasoning: *"Per-step matters: an
> AR loop can look fine at step 1 and drift by step 30."* It also records the hardest-won lesson of
> that whole archive as **"read the generations"** — a model that passes every numeric gate can
> still emit broken grammar.

That is a community bar, not Apple's. But the logic is sound and generalises: for any model whose
output feeds an iterative process, single-step numeric similarity understates compounding error.

---

## 17. Community-measured findings, labelled

Everything in this section comes from `notes/repos/john-rocky-models.md`, a **single-author
community archive with self-declared uncontrolled benchmarks**. Its numbers are frequently unique —
nobody else has published Core AI compression measurements at this scale — and they are frequently
useful. They are **not Apple figures**, they were not produced under a controlled protocol, and
several of them are internally in tension. Every one is labelled.

### 17.1 Dense int4 k-means: what the archive actually found

**Finding 1 — palettization beats quantization by a lot, at fine granularity.**

> 🟢 **COMMUNITY-MEASURED**: *"**Per-channel (group_size=1) basically always wins**; at per-channel,
> k-means beats quantization by **~15–19 dB** at both 8-bit and 4-bit. Per-tensor palettization can
> be **worse** than per-channel quantization."*
> Mechanism the author gives: *"k-means fits a per-group lookup table to the actual weight clusters
> → tracks non-uniform weight distributions far better than symmetric per-block int4 at the same bit
> width."*

15–19 dB is a very large gap — more than the entire margin between Apple's 4-bit gate (35 dB) and
its 8-bit expectation (55 dB). Treat it as a strong hint that if you are quantizing weights per-
channel and struggling, palettization at the same nominal width is the first thing to try. Then read
§6.3 and price the LUTs before you commit to `group_size=1`.

**Finding 2 — int4 is a cliff, not a slope.**

> 🟢 **COMMUNITY-MEASURED**, stated repeatedly across the archive: *"**int4 is a cliff, not a
> slope**"* — *"the failure is capacity, so no clever rounding rescues"*. And: *"Across **Gemma 4
> E2B and Qwen3.5**, linear int4 and k-means int4 **both** flip next-token argmax vs the HF
> reference; **int8 k-means palettization reproduces HF top-1 exactly** at ~half the fp16 size."*
> *"**Finer groups are the main int4 lever** (group32 → group8 helps), but still don't reach exact.
> Per-channel scale is marginal or harmful."*

Note the last clause independently corroborates §5 from a completely different direction: per-channel
scale was measured to be *"marginal or harmful"* on quality, which means the ANE cost it imposes
buys nothing even before you count the compute-unit fallback.

**Finding 3 — selective 4-bit works where uniform 4-bit does not.**

> 🟢 **COMMUNITY-MEASURED**, the archive's summary stance for LLM decoders:
> *"**int8 k-means palettization is the floor that stays exact when applied across the whole
> transformer; whole-model int4 degrades. SELECTIVE 4-bit works: k-means int4 on the FFN + lm_head
> only** (attention/embeddings kept ≥ int8/fp16) measured top-1 exact."*
> Specifically for Gemma 4: *"the gate/up MLP projections **must** be int8 for exactness — keeping
> them at 4-bit caps accuracy regardless of other layers."*
> Recommended recipe: *"int8 k-means, group 32, all projections; keep tied `lm_head` + 1-D conv
> (SSM) full precision."*

This is mixed precision (§14) arrived at empirically, and it agrees structurally with Apple's own
mixed 4/8-bit Qwen3 YAMLs (§14.4): neither party found uniform 4-bit acceptable on a transformer.

**Finding 4 — but which int8, and the archive contradicts itself, on purpose.**

> 🟢 **COMMUNITY-MEASURED**, and flagged by the archive itself as a tension:
> a separate measurement on MoE experts (ZAYA / LFM) found **`sym8`** — symmetric *linear* int8 with
> per-K-block-32 scales — **clean**, and **k-means int8 lossier**, for top-k ≥ 4 routing. The same
> note records the **reverse for top-1 routing**, where `km8` (k-means int8, 256-entry codebook)
> *"recovers fp16 quality"* while sym8 fails.
> The archive's own synthesis: *"int8 is the safe floor everywhere; **which** int8 (k-means vs
> symmetric-linear-block32) is **tensor-role- and routing-dependent** and must be gated per model."*

⚠️ **Do not flatten those two into one rule.** Both were measured, at different dates, on different
tensor roles. The defensible takeaway is the archive's own: int8 is the floor, and the choice of
*which* int8 is a per-model measurement, not a default.

**Finding 5 — dense-path int4 k-means is a speed lever with a known quality cost.**

> 🟢 **COMMUNITY-MEASURED** — `dense-int4km-flagship-session-findings.md`, dated 2026-07-01. All
> numbers from that author's own microbenchmarks:
>
> | Measurement | Number | Hardware |
> |---|---|---|
> | `lm_head` int4km per-op vs fp16, vocab 248 K | **2.77×** | M4 Max |
> | Qwen3.6-35B decode, int4km dense path vs baseline | **2.18× ratio** | M4 Max GPU |
> | LFM-8B on-device decode | 1.23× sustained / 1.43× avg | iPhone 17 Pro (A19) |
> | `lm_head` FP4-E2M1 vs fp16, vocab 248 K | 1.72× (and **1.01× vs int4km**) | M4 Max |
>
> ⚠️ **The author's own caveats, which matter more than the numbers:** *"Absolute tok/s from the
> quick Mac driver are ~10× too slow"* — **only the ratio is valid**, not the throughput.
> On quality: *"The dense-int4km lever itself is quality-safe (LFM-8B coherent). **Flagship int4
> degrades quality** … the 2.18× is a **speed win at a known int4 quality cost.**"*

And one structural constraint from the same archive that bears directly on §2.6:

> 🟢 **COMMUNITY-MEASURED**: *"k-means palettization is **`F.linear`-only**"*, so an int4 head
> *"needs a **kernel** path, not coreai-opt's `F.linear` quantizer."* The `lm_head` is *"the largest
> single tensor, high sensitivity, needs **per-row (per-output-channel)** scales for matmul
> efficiency"* — e.g. **262,144 × 1536** for Gemma 4.

### 17.2 Boundary layers

> 🟢 **COMMUNITY-MEASURED**: *"**Boundary layers** (first/last) are high-error — skipping them can
> add up to **+9 dB**; always ablate."*

Independently corroborated by Apple's own mixed-precision result (§14.1), where the two layers
promoted to 6 bits were `conv1` (the stem) and `layer1.0.downsample.0` (a projection shortcut). Two
sources, two model families, same conclusion. **Ablate your first and last compressible layers before
anything else; it is one experiment and it is frequently the largest single win.**

### 17.3 The free 1.7× that everyone leaves on the table

This one is not about compression at all, and it is the cheapest win in this guide.

> 🟢 **COMMUNITY-MEASURED** — vision models, **M4 Max**, Python runtime, method stated by the author:
> load each **official** `.aimodel` with
> `SpecializationOptions.from_preferred_compute_unit_kind(<unit>)`, synthetic inputs from the
> function descriptors, **3 warmup + 20 timed runs, median single-inference latency**. Caveat the
> author attaches: *"'Preferred' means the runtime may still place unsupported ops elsewhere."*
>
> | Model | Recipe | Artefact | GPU | ANE | CPU | Winner |
> |---|---|---:|---:|---:|---:|---|
> | clip-vit-base-patch32 | fp32 static | 577 MB | 6.54 ms | **5.43 ms** | 18.76 ms | ANE |
> | clip-vit-base-patch32 | **fp16** (`--dtype float16`) | **289 MB** | 6.31 ms | **3.68 ms** | — | **ANE, 1.7× over GPU** |
> | yolos-base | fp32 static | 488 MB | **444.8 ms** | 456.7 ms | 733.7 ms | GPU (≈ tie) |
> | sam3 | fp32 static | 3.1 GB | **559.9 ms** | 565.7 ms | 2789.7 ms | GPU (≈ tie) |
> | depth-anything-3 (small) | fp32 static | 101 MB | 7.30 ms | **6.84 ms** | 34.58 ms | ANE |
>
> The author's conclusion, verbatim: *"**every official CV recipe DEFAULTS to float32**, and at fp32
> the big ViTs land in a GPU/ANE tie on M4 Max. But the scripts expose `--dtype float16`, and fp16
> is what the ANE runs natively: CLIP at fp16 drops to **3.68 ms on ANE (1.7× faster than GPU, 1.5×
> faster than fp32-ANE) at half the artifact size**. If you're deploying these recipes to ANE,
> **pass `--dtype float16`**."* (First ANE load of a new variant pays a ~5 s one-time specialization
> for CLIP.)

The mechanism is the one from §5.1: **fp32 is not an ANE dtype.** Apple's own authoring skill says
so — *"fp16 only — no fp32 literals anywhere"*, and fp32 *"falls back to GPU/CPU"*. Shipping an fp32
recipe to an ANE target is asking for the fallback by construction.

So before you spend a week on a palettization sweep:

```sh
# The one-flag experiment. Do this first.
uv run models/<model>/export.py --full --dtype float16
```

> ✅ **VERIFIED** — the `--dtype {float16,float32}` flag with default **`float32`** exists on the
> SAM3 export script's `--full` path (`models/sam3/README.md`). Whether every utility export script
> exposes it identically is 🔴 **unverified** — check `--help` for yours.

⚠️ Two honest caveats before you take this as a universal rule. First, **it is one author's
measurement on one machine**, and the two large models in that table (`yolos-base`, `sam3`) show
essentially no ANE advantage at all — so "ANE wins" is not general. Second, the archive separately
records that on **iOS 27 beta**, *"CV graphs silently fall back to GPU even with an ANE preference
and a pure-ViT split backbone (fingerprint-identical outputs, zero ANE-compile wait)"*. Measure on
your target, not on a Mac.

### 17.4 Palettization composes with stateful export, with an ordering rule

> 🟢 **COMMUNITY-MEASURED**: *"read the export spec (reference inputs / dynamic shapes / state names)
> from the **ORIGINAL** model first (**the finalized palettized model loses that method**),
> palettize, then drive `export_to_coreai` with that spec."* Verified by the author as top-1-exact
> for Gemma 4 (dual-KV) and Qwen3.5 (hybrid 4-state).

That is the same failure mode as §10.2 in a different costume: `finalize()` returns a model that has
lost something you needed, and the loss is silent. Read what you need off the float model first.

### 17.5 A beta bug worth knowing about

> 🟢 **COMMUNITY-MEASURED**, beta-era, reproduction dated 2026-06-11: *"per-channel (axis-0) int8
> Linear weights are **broken on the macOS-27-beta MPSGraph GPU delegate** — torch-level numerics
> are clean but the lowered matmul returns **garbage** (minimal head-only repro, multiple shapes,
> sym and clipping alike); **use per-block-32 there**."*

This is a **quantization** bug, not a palettization one, and it is beta-specific. It is included here
for one reason: it is a case where **your PyTorch score is clean and the device output is garbage**,
which is exactly the failure class the Debugger exists for and exactly why §16's *compiled vs torch*
gate is a separate gate from the authoring gates. Do not assume a passing torch-level PSNR means
your artefact works.


---

## 18. The worked examples the repo ships

If you read one thing after this guide, read these. `coreai-optimization` ships four example pages
and **four Jupyter notebooks**, and the notebooks are the only place in the entire Core AI ecosystem
where you can watch a complete compression workflow run end to end on a model small enough to
iterate on. Remember the warning at the top of this guide: **Core AI has zero Apple sample-code
Xcode projects.**
These notebooks are the closest thing that exists to a first-party sample.

### 18.1 The four MNIST notebooks

> ✅ **VERIFIED** — `docs/src/tutorials/`:
> ```
> mnist_quantization.ipynb
> mnist_palettization.ipynb
> mnist_palettization_and_activation_quantization.ipynb      ← joint compression
> mnist_pruning.ipynb                                        ← added in commit b1535b4
> ```
> They are executed in CI: `make test-tutorials` runs `docs/tests/test_tutorials.py` via **papermill**
> (`Makefile`), on `ubuntu-latest`, as part of stage 1 of `.github/workflows/ci.yaml`. So they are
> kept working, not merely kept.
>
> ✅ **VERIFIED** — the model they use, from `tests/test_joint_compression.py` and
> `tests/models/mnist.py`: **6 weight-bearing layers** — `conv1`, `conv2`, `conv_transpose1`,
> `conv_transpose2`, `dense1`, `dense2` — with `batch_size = 128` and
> `num_calibration_batches = 17`. Checked-in artefacts:
> `tests/_test_artifacts/mnist/mnist_pretrained_1epoch_09032025.pt` and
> `mnist_example_input_11122025.pt`. Acceptance: baseline **> 97.0%**, joint P4-A8 after calibration
> **> 90.0%**.

Suggested order, and what each one is actually for:

| # | Notebook | Read it to learn |
|---|---|---|
| 1 | `mnist_quantization` | the lifecycle, GRAPH mode, calibration. Guide 01's material, runnable. |
| 2 | `mnist_palettization` | this guide's §2–§7 with real numbers, in about five minutes of compute. |
| 3 | `mnist_pruning` | the *only* runnable pruning example anywhere, including `step()` cadence. |
| 4 | `mnist_palettization_and_activation_quantization` | §13's five-step flow, with the `op_state_spec=None` line in context. |

Notebook 3 deserves particular attention precisely because pruning got no stage time — it is the
only place you can see the schedule/`step()` interaction working rather than reasoning about it
from a docstring.

Note that the presence of `conv_transpose1` / `conv_transpose2` in the MNIST model is not
incidental: `ConvTranspose*` palettization was **added in 0.2.1**, and this model is how it is
tested.

To run them:

```bash
git clone https://github.com/apple/coreai-optimization
cd coreai-optimization
make env-tutorial          # creates .venv-tutorial with the tutorial dependency group
source .venv-tutorial/bin/activate
jupyter lab docs/src/tutorials/
```

> ✅ **VERIFIED** — `Makefile`: `make env-tutorial` builds `.venv-tutorial` with `--with-tutorial`.
> Also useful: `make env` (dev + coreai + coreml groups), `make test-fast` (`--marker 'not slow'`),
> `make api-list [MODULE=coreai_opt.palettization.spec.spec]` to print the public surface of any
> module.
> ⚠️ **A `uv` rule from Apple's own `AGENTS.md`** (which is literally titled `# CLAUDE.md`): *"Always
> pass `--no-sync` to `uv run`: `uv run --no-sync --active …`. `uv run` implicitly syncs the active
> project to its default-groups before running, which re-resolves dependencies and can clobber a
> venv's group-pinned packages."* If you are working across the torch-version venvs, this will save
> you an afternoon.

### 18.2 The four example pages

> ✅ **VERIFIED** — `docs/src/examples/`: `toy_models.md`, `resnet50.md`, `edsr.md`,
> `mixed_precision_palettization.md`.

**`toy_models.md`** — a `Conv2d → ReLU → Linear` stack, used to demonstrate the per-tensor SNR
comparison utility. Its output table is the single best illustration of how error accumulates
through a network:

> ✅ **APPLE-PUBLISHED** — `docs/src/utils/activation_comparison.md:286-295`, default INT8, graph
> mode:
> ```
> conv_weight   -> activation_post_process_1  SNR = 47.17 dB
> conv_bias     -> conv_bias                  SNR = inf   dB
> linear_weight -> activation_post_process_4  SNR = 48.13 dB
> x             -> activation_post_process_0  SNR = 43.20 dB
> conv2d        -> conv2d                     SNR = 42.40 dB
> relu          -> activation_post_process_2  SNR = 38.94 dB
> flatten       -> activation_post_process_3  SNR = 38.94 dB
> linear        -> activation_post_process_5  SNR = 35.74 dB
> ```

Read it top to bottom: **48 dB at the weights, 35.7 dB by the output.** Twelve dB of accumulated
loss across three operations, monotonically decreasing. `flatten` costs exactly nothing (identical
to `relu` — it is a pure reshape), and the final `linear` costs 3.2 dB on its own. This is why §16's
gates get looser as you move down the stack, and why gating on a final-output PSNR alone hides where
the damage happened.

**`resnet50.md`** — quantization PTQ, and the clearest available demonstration that the choice of
qparams calculator matters:

> ✅ **APPLE-PUBLISHED** — 128 evaluation samples from imagenette:
>
> | Config | Accuracy |
> |---|---|
> | FP32 baseline | 78.12% |
> | W_INT8(per-channel) _ A_INT8(per-tensor), `moving_average`, 896 calibration samples | 74.22% |
> | same but `global_minmax` activations | 75.78% |
> | W_FP8_E4M3 _ A_FP8_E4M3, `global_minmax` | **76.56%** |
>
> ⚠️ Note the small evaluation set — **128 samples**. A 1.5-point difference on 128 images is inside
> the noise. Treat the *ordering* as informative and the *magnitudes* as indicative.

**`edsr.md`** — the joint-compression example, reproduced in §13.3. Super-resolution is an
unusually good compression testbed because PSNR is the *task* metric, not just a proxy.

**`mixed_precision_palettization.md`** — §14.1. The only place Apple publishes a full-ImageNet
(50,000 image) evaluation of a compression recipe.

### 18.3 The test suite as documentation

> ✅ **VERIFIED** — `tests/` layout:
> ```
> tests/
>   test_smoke.py                     # minimal quant (eager+graph) + palettization smoke
>   test_joint_compression.py         # P4-A8 MNIST accuracy (slow; needs coreai)
>   test_palettization_preset.py      # what each preset expands to
>   palettization/                    # kmeans palettizer (+mnist), kmeans_fake_palettize,
>                                     # kmeans1d, kmeans_parallel, support mixins, config, spec
>   pruning/                          # magnitude pruner (+mnist), config/spec, sparsity schedule
>   export/                           # eager & graph MIL/MLIR export, kmeans export, pruning export
>   coreai_utils/                     # quantize/palettize/sparsify weights, sparse utils
>   models/                           # resnet.py, simple.py, mnist.py
>   fixtures/                         # quantization.py, palettization.py, pruning.py, fp4.py, fp8.py
> ```

`tests/palettization/test_kmeans_parallel.py` is the reference for `num_workers` behaviour,
`tests/pruning/test_sparsity_schedule.py` for the schedule formula, and `tests/fixtures/` for
minimal working config objects you can copy. When a docstring and your intuition disagree, the test
is the tiebreaker.

---

## 19. ⚠️ Silent failures, consolidated

`coreai-opt` has a consistent house style: **when compression cannot be applied, it is skipped with
a log line rather than raised.** That is a defensible design for a sweep tool and a dangerous one
for a build pipeline. Here is everything in this guide's scope that fails quietly.

### 19.1 A group size your weight is not divisible by leaves the layer uncompressed

The big one.

> ✅ **VERIFIED** — `PerGroupedChannelGranularity` raises the internal `_IncompatibleGranularityError`
> when `shape[axis] % group_size != 0`. That error is **caught** inside
> `_FakePalettizeImplBase.forward`, which logs a warning, **permanently disables the module**, and
> **removes the parametrization**. Palettization has a `_remove_disabled_fake_palett_modules` pass
> analogous to quantization's `_remove_disabled_fake_quant_nodes`. The log line, from the transcript
> corpus's reading of the source: `"Tensor incompatible with granularity: ... Skipping
> palettization."`

> ⚠️ **SILENT FAILURE.** `prepare()` returns successfully. The model scores *better* than you
> expected, because some layers were never compressed. Your size estimate — computed from the config
> — is wrong. You ship a model that is bigger than your release notes say, and possibly bigger than
> the memory budget you sized the feature against. There is no exception, no non-zero exit, and the
> warning is one line in a `tqdm`-heavy log you were not reading.
>
> **The same hazard exists for `cluster_dim`** (a shape not divisible by the vector size) and, on
> the quantization side, for `PerBlockGranularity` block sizes.
>
> Apple's own compression-exploration skill names this as a pitfall and prescribes the fix:
> *"per-block / per-grouped-channel **silently skip** layers whose weight dim isn't divisible
> (pre-check with `check_divisibility()`)"*. The community archive independently names it:
> *"**Check divisibility before trusting a size.**"*
>
> **Pre-flight it** — the `check_divisibility` implementation in §14.3 is 12 lines and catches every
> instance. Or verify after the fact:
> ```python
> prepared = palettizer.prepare(example_inputs, num_workers=8)
> n_palettized = sum(
>     1 for _, m in prepared.named_modules()
>     if getattr(m, "parametrizations", None)
> )
> print(f"{n_palettized} modules carry parametrizations; expected {len(expected_names)}")
> ```
> A count mismatch is your signal.

### 19.2 `enable_per_channel_scale=True` moves your model off the Neural Engine

§5.2. Rank-6 LUT, ANE rejects, runtime falls back to GPU. No warning, no error, marginally *better*
PyTorch numerics. Detected only by inspecting compute-unit placement on device.

### 19.3 Eager-only `KMeansPalettizer.finalize(CoreAI)` frees dense weights irreversibly

§10.2. The dense pre-palettization weight is replaced with a zero-size placeholder. Combined with
`prepare()`'s in-place mutation (§2.4), a careless script can leave you with no float model in the
process at all. `copy.deepcopy` before `prepare()`; do not `finalize()` during a sweep.
[^destructive-finalize-scope]

### 19.4 Vector palettization produces a different model every run

§7.1. Non-deterministic centroid initialisation, and seeding does not reach spawned workers. A
golden-hash regression test will fail for reasons unrelated to your change, and — worse — the
artefact you evaluated is not the artefact you shipped.

### 19.5 Channel-structured pruning can silently prune zero channels

§11.4. `floor(num_channels × target_sparsity)`. With 8 channels and a 10% target, nothing is pruned
and nothing says so.

### 19.6 Joint compression without `lut_qspec` buys you no speed

§13.4. A floating-point LUT forces floating-point ops regardless of how thoroughly you quantized the
activations. Everything runs; the latency does not move; nothing explains why.

### 19.7 Joint compression with the default `op_state_spec` double-compresses weights

§13.4. Forgetting `op_state_spec=None` in the quantization config means the already-palettized
weights get quantized on top. Quality drops far more than the published EDSR deltas suggest, and the
cause is a missing three-character value.

### 19.8 `--n-bits` on the SAM3 export script overrides *both* encoders

§5.4. The shipped defaults are deliberately asymmetric (image 4/gs32, text 6/gs8); the CLI flag
applies uniformly and silently discards the asymmetry.

### 19.9 A sweep optimising PSNR will pick the setting that costs you the ANE

§15.3. `enable_per_channel_scale` is one of the axes Apple's own exploration skill sweeps, and it
improves PyTorch PSNR. The sweep has no visibility into compute-unit placement. Constrain the search
space before you run it against an iOS target.

### 19.10 Inherited from quantization, and still true here

From guide 01 §17, because they apply to every compressor in the package:

- `example_inputs` must be a **tuple**; a bare tensor raises, but an empty tuple raises differently.
- Re-preparing a prepared model raises — except after `KMeansPalettizer.finalize()`, which deliberately
  clears the marker so joint compression can work (§13.1). That asymmetry is intentional and easy to
  misread as a bug.
- Configs are `@final`; specs are frozen. Mutate with `model_copy(update={...})`.
- `module_type_configs` keys must be **fully-qualified**; `"torch.nn.Linear"` matches nothing and
  raises only if it has no dot — `"torch.nn.Linear"` *does* have dots, so it passes the syntactic
  check and then matches nothing. ⚠️ That one is genuinely silent.
- `only_for` cannot be chained.


---

## 20. Numbers, attributed

Every number in this guide, with its source and its caveats. Nothing here is "measured by us".

### 20.1 Apple-published

| Number | Context | Source | Caveats |
|---|---|---|---|
| **75.02% → 65.87% → 70.27%** top-1 | ResNet50 fp16 / uniform 4-bit per-tensor / greedy mixed precision | `docs/src/examples/mixed_precision_palettization.md` | full ImageNet val (50 k), **mps** backend |
| **48.64 / 12.16 / 12.03 MB**, BPW **16 / 4 / 3.95** | same three ResNet50 configs | same | theoretical weight storage |
| **2 layers @ 6-bit, 50 @ 4-bit, 2 @ 2-bit** | the greedy recipe (`conv1`, `layer1.0.downsample.0` up; `layer1.1.conv1`, `layer3.4.conv2` down) | same | 54 configured layers |
| **inflection at ≈ 4.0 BPW**; below it 15–35 pts per 0.5 BPW, above it 1–2 | ResNet50 palettization curve | same | ResNet50 only; do not assume it transfers |
| **30.68 / 30.33 / 29.86 dB** PSNR | EDSR fp32 / W_INT8-A_INT8 / W_P4(INT8)-A_INT8 joint | `docs/src/examples/edsr.md` | `edsr_r16f64`, 1.5 M params, **B100**, 20 calib / 80 eval |
| **~5.5 / ~1.4 / ~0.7 MB** (1× / 4× / 8×) | same three EDSR configs | same | weight storage |
| **78.12 / 74.22 / 75.78 / 76.56%** | ResNet50 PTQ: fp32 / int8 `moving_average` / int8 `global_minmax` / FP8-E4M3 `global_minmax` | `docs/src/examples/resnet50.md` | ⚠️ **only 128 eval samples**; 896 calibration samples |
| **47.17 → 35.74 dB** SNR down the stack | toy `Conv2d→ReLU→Linear`, default INT8, graph mode | `docs/src/utils/activation_comparison.md:286-295` | illustrative toy model |
| MNIST baseline **> 97.0%**, joint P4-A8 **> 90.0%** | test assertions | `tests/test_joint_compression.py` | acceptance thresholds, not measurements |
| Qwen3 0.6B iOS: **26.16 → 30.90** perplexity at **5.71\*** BPW | mixed 4/8-bit palettized YAML | `apple/coreai-models`, `models/*/README.md` | WikiText-2 via lm-evaluation-harness; `*` includes int8 embedding |
| Qwen3 4B iOS: **16.41 → 18.80** at **4.89\*** BPW | mixed 4/8-bit palettized YAML | same | same |
| Qwen3 4B macOS: **16.41 → 18.33** at **4.50** BPW | 4-bit **quantized** (not palettized) | same | different technique, different platform |
| Qwen2.5 1.5B iOS: **12.21 → 14.64** at **4.63\*** BPW | 4-bit palettized gs 8 | same | |
| **8-bit ≈ 2× / > 55 dB**, **4-bit ≈ 4× / ~40 dB**, **2-bit ≈ 8× / 25–35 dB** | palettization sizing guidance | `skills/skills/model-authoring/SKILL.md` | 2-bit annotated *"Usually unacceptable"* |
| **70 / 70 / 40 / 35 dB** | the four acceptance gates | `model-authoring/SKILL.md:94-99` | §16.1 |
| **> 70 / > 50 / ~40 dB** | deployment-side PSNR expectations | `model-deployment` skill | §16.2; slightly different scoping |
| **96%** of SAM3 params in the two encoders; **4%** in the detector | SAM3 structure | WWDC26 session 325, 325:60 and 325:158 | 848 M params per `models/sam3/README.md`; talk says "850-million" |
| **76% faster** second inference | SAM3 three-function split, prompt-only change | session 325, 325:255-256 | ⚠️ requires caller-side caching Apple's package does not do |
| **5-15%** scale/ZP overhead at 2-4 bit fine granularity | sizing guidance | `model-compression-exploration/SKILL.md` | |
| **~5 bits** effective at `block_size=16` + int4 | same | same | quantization, included for contrast |

### 20.2 Community-measured — `notes/repos/john-rocky-models.md`

⚠️ **Single-author archive with self-declared uncontrolled benchmarks. Not Apple figures.** Several
entries are internally in tension (§17.1, finding 4) and the archive says so itself.

| Number | Context | Hardware / date | Caveats |
|---|---|---|---|
| **~15–19 dB** k-means over quantization | per-channel, at both 8-bit and 4-bit | not stated | the largest single claim in this table; unreplicated |
| **+9 dB** from skipping boundary layers | first/last compressible layers | not stated | corroborated in shape by Apple's ResNet50 recipe |
| **3.68 ms ANE vs 6.31 ms GPU** (1.7×) | clip-vit-base-patch32, fp16, 289 MB | **M4 Max**, 3 warmup + 20 timed, median | fp32 variant: 5.43 ANE / 6.54 GPU, 577 MB |
| 444.8 GPU / 456.7 ANE ms | yolos-base fp32, 488 MB | M4 Max, same protocol | ≈ tie — ANE advantage is **not** general |
| 559.9 GPU / 565.7 ANE ms | sam3 fp32, 3.1 GB | M4 Max, same protocol | ≈ tie |
| **2.77×** per-op | `lm_head` int4km vs fp16, vocab 248 K | M4 Max microbenchmark | per-op, not end-to-end |
| **2.18× ratio** | Qwen3.6-35B decode, dense int4km path | M4 Max GPU, 2026-07-01 | ⚠️ author: *"absolute tok/s ~10× too slow; only the RATIO is valid"* |
| **1.23× sustained / 1.43× avg** | LFM-8B decode, dense int4km | iPhone 17 Pro (A19), thermally matched | |
| **1.72×** fp4-E2M1 vs fp16; **1.01×** vs int4km | `lm_head`, vocab 248 K | M4 Max | fp4 ≈ int4km on speed |
| **2.2×** artefact speed difference | same export recipe, macOS 26 vs 27 beta | beta-era | *"an `.aimodel` is a build artefact, not a pure function of the recipe"* |
| 7.0 GB fp32 → 3.5 GB fp16 → 1.9 GB int8 | Gemma 4 E2B core | — | sizes, not quality |

### 20.3 What is *not* measured anywhere

Stated plainly, because absence of a number is information:

- **No latency or size number for `cluster_dim > 1`** on any hardware (§4.3).
- **No before/after quality delta for sensitivity-weighted k-means** in `coreai-opt` (§8.4).
- **No evidence that any Apple compute unit exploits unstructured, block or `n:m` sparsity** for
  either size or speed (§11.8, §12.2).
- **No quality or latency number for any non-LLM model in `apple/coreai-models`.** ✅ Verified:
  `Tools/benchmark` is actually **`llm-benchmark`** and imports `CoreAILanguageModels`; there is **no
  non-LLM benchmark tool** in that repository.
- **No enumeration of the Core AI Debugger's available similarity metrics** (§15.5).

---

## 21. Quick reference

### 21.1 Imports

```python
# Palettization
from coreai_opt.palettization import (
    KMeansPalettizer, KMeansPalettizerConfig, ModuleKMeansPalettizerConfig, PalettizationSpec,
)
from coreai_opt.palettization.spec import (
    PalettizationGranularity, PerGroupedChannelGranularity,
    PerTensorGranularity,                    # ⚠️ NOT the quantization one
    default_weight_palettization_spec,
)

# Pruning
from coreai_opt.pruning import (
    MagnitudePruner, MagnitudePrunerConfig, ModuleMagnitudePrunerConfig, PruningSpec,
)
from coreai_opt.pruning.spec import (
    ChannelStructured, PruneImplBase, PruningScheme, Unstructured, default_weight_pruning_spec,
)
from coreai_opt.pruning.config import (
    ConstantSparsitySchedule, OpMagnitudePrunerConfig, PolynomialDecaySchedule, SparsityScheduleBase,
)

# Program level (no PyTorch model needed)
from coreai_opt.coreai_utils import (
    CompressionGranularity, DType, palettize_weights, quantize_weights, sparsify_weights,
)
from coreai_opt.coreai_utils.common import QScheme     # not in the package __all__; §12

# Shared
from coreai_opt import ExportBackend, CoreMLExportError
from coreai_opt.casting import cast_to_16_bit_precision
```

### 21.2 The decision table

| Situation | Reach for |
|---|---|
| Targeting **iOS / Neural Engine** | **Palettization.** `presets.w4(group_size=32)`. `enable_per_channel_scale=False`. |
| Targeting **macOS / GPU** | **Quantization.** Guide 01. Apple's own exporter agrees. |
| First experiment on any model | `presets.w8()` (per-tensor, 2×) — establishes the ceiling cheaply |
| 4-bit is not good enough | ↑ to `w6`, or ↓ `group_size`, or mixed precision, or sensitivity weighting |
| Need weight **and** activation compression | **Joint compression** (§13). Palettize with `lut_qspec` first. |
| Need < 4 effective bits | `cluster_dim=2` — but read §4.3's GAP box first |
| Model is small (< 1 B params) | Expect a worse curve than the papers. See §14.4. |
| Want speed on device | **Try `--dtype float16` before compressing anything** (§17.3) |
| Want to know which layers to skip | Sensitivity sweep (§14.3), then the Debugger (§15.5) |
| Considering pruning | Read §11.1 and §11.8. Probably don't. |
| Need to compress an embedding table | Not palettization (§2.6). int8 per-tensor, or `palettize_weights` at the program level. |

### 21.3 Field cheat-sheet

```python
PalettizationSpec(
    n_bits=4,                    # {1, 2, 3, 4, 6, 8} — NO 5, NO 7
    lut_qspec=None,              # int8/uint8/fp8_e4m3fn/fp8_e5m2; per-tensor; ZP only
    granularity=PerTensorGranularity(),   # or PerGroupedChannelGranularity(axis={0,1}, group_size=N)
    cluster_dim=1,               # >1 ⇒ vector; requires enable_fast_kmeans_mode=False
    enable_per_channel_scale=False,       # ⚠️ True ⇒ rank-6 LUT ⇒ ANE rejects ⇒ GPU fallback
)

ModuleKMeansPalettizerConfig(
    op_state_spec={"weight": spec, "in_proj_weight": spec},   # BOTH keys
    enable_fast_kmeans_mode=True,        # rounds weights to `rounding_precision` decimals first
    rounding_precision=4,
)

PruningSpec(
    target_sparsity=0.5,                 # a REQUEST, not a guarantee (§11.4)
    pruning_scheme=Unstructured(),       # or ChannelStructured(axis=0)
    pruning_algo="default",              # → _MagnitudePruneImpl
)

PolynomialDecaySchedule(
    begin_step=0, total_iters=N,         # REQUIRED; units = your step() cadence
    power=3.0, initial_sparsity=0.0, update_frequency=1,
)
```

### 21.4 Legal-value quick check

| Thing | Legal values |
|---|---|
| `n_bits` | 1, 2, 3, 4, 6, 8 |
| LUT dtype | `int8`, `uint8`, `float8_e4m3fn`, `float8_e5m2` |
| LUT granularity | quantization `PerTensorGranularity` **only** |
| LUT formulation | `ZP` only (`MINVAL` rejected) |
| Palettization granularity axis | 0 or 1 |
| Palettization ops | conv1d/2d/3d, conv_transpose1d/2d/3d, linear, multi_head_attention_forward |
| Pruning ops | linear, conv1d/2d/3d, conv_transpose1d/2d/3d, multi_head_attention |
| Program-level palettization granularity | `PER_TENSOR`, `PER_CHANNEL`, `PER_GROUPED_CHANNEL` |
| `sparsify_weights` | `target_sparsity` XOR `n_m_ratio`; `quantize_dtype` XOR `palettize_nbits` |
| Joint compression backend | `ExportBackend.CoreAI` **only** |
| CoreML palettization | at most **one** of `{cluster_dim>1, lut_qspec, enable_per_channel_scale}` |

### 21.5 Pre-flight checklist

```
□ copy.deepcopy(model) before prepare()
□ example_inputs is a TUPLE
□ shape[axis] % group_size == 0 for every target layer      ← §19.1, the big one
□ enable_per_channel_scale is False (unless GPU-only)       ← §5
□ op_state_spec lists BOTH "weight" and "in_proj_weight"    ← §2.5
□ num_workers > 1 for anything bigger than a toy            ← §7.2
□ cluster_dim == 1, or seeded with num_workers=1            ← §7.1
□ no finalize() during a sweep                              ← §10.2
□ embeddings accounted for separately                       ← §2.6, §6.4
□ a task metric alongside PSNR                              ← §15.3
□ the toolchain version recorded next to every result       ← §15.4
```

---

## 22. Sources and evidence ledger

### 22.1 Primary — shipped source

- **`apple/coreai-optimization`** at `main`, HEAD `cd95cb2`, package `coreai-opt` **0.2.1**. Files
  read for this guide: `palettization/{__init__,base_palettizer}.py`,
  `palettization/spec/{__init__,spec,granularity,fake_palettize}.py`,
  `palettization/config/{__init__,palettization_config}.py`,
  `palettization/config/_presets/{kmeans_palettizer_config,module_kmeans_palettizer_config}.py`,
  `palettization/kmeans/{palettizer,kmeans_fake_palettize,supported_ops_registry,_prepare_for_export}.py`,
  `pruning/{__init__,magnitude_pruner,supported_ops_registry}.py`,
  `pruning/spec/{__init__,spec,scheme,prune}.py`,
  `pruning/config/{__init__,sparsity_schedule,magnitude_pruner_config}.py`,
  `coreai_utils/{__init__,common}.py`,
  `coreai_utils/passes/{__init__,weight_quantization,weight_palettization,weight_sparsification}.py`,
  `base_model_compressor.py`, `common.py`, `config/compression_config.py`,
  `_utils/export_utils.py`, `deps/_kmeans1d/core.py`, `casting/__init__.py`,
  `pyproject.toml`, `Makefile`, `CHANGELOG.md`, `AGENTS.md`, `.github/workflows/ci.yaml`,
  `changelog.d/{31.changed,42.fixed,52.fixed}`.
- **Docs in that repo:** `docs/src/palettization/{basics,overview,config}.md`,
  `docs/src/pruning/{basics,overview,config}.md`,
  `docs/src/utils/{joint_compression,mixed_precision,casting,coreai_compression,activation_comparison}.md`,
  `docs/src/examples/{toy_models,resnet50,edsr,mixed_precision_palettization}.md`,
  `docs/src/introduction/{installation,how_to_use_coreaiopt,integration_coreai}.md`,
  `docs/src/landing_page.md`, `docs/src/tutorials/*.ipynb` (listing only).
- **`apple/coreai-models`:** `models/sam3/{pipeline.py,README.md,export.py}`,
  `python/src/coreai_models/llm/{export.py,model_registry.py}`,
  `python/src/coreai_models/export/presets.py`, `models/README.md`, `models/*/README.md`.
- **Tests:** `tests/test_joint_compression.py`, `tests/test_smoke.py`, `tests/models/mnist.py`,
  directory listings for `tests/{palettization,pruning,export,coreai_utils,fixtures}`.

### 22.2 Primary — Apple's agent skills (vendored in `apple/coreai-models`)

These are Apple engineers' empirical rules, written for machine consumption. In this guide they are
treated as **stronger** than session transcripts and weaker than source.

- `skills/skills/model-authoring/SKILL.md` — the four PSNR gates (`:94-99`), the palettization
  sizing table (`:149-153`), the ANE/GPU at-a-glance table, the KV-cache conventions table.
- `skills/skills/model-authoring/references/neural_engine_rules.md` (479 lines) — **max tensor rank
  5**, fp16/int8/int16 dtypes, 64-byte last-axis alignment, BC1S conversions, causal mask
  conventions, conv stride factorisation.
- `skills/skills/model-authoring/references/gpu_rules.md` (297 lines) — the contrast case.
- `skills/skills/model-authoring/references/common_issues.md` (176 lines).
- `skills/skills/model-compression-exploration/SKILL.md` — the ~60-config sweep, the three groups,
  the refinement pass, the output record shape, the pitfalls list.
- `skills/skills/model-deployment` — the deployment-side PSNR acceptance table.

### 22.3 Primary — WWDC26

- **Session 325**, *"Dive into Core AI model authoring and optimization"*. Cited at 325:60 (96%
  encoders), 325:64–68 (`coreai-opt` capability claims), 325:139–152 (Debugger sync points and PSNR),
  325:156–162 (the detector diagnosis), 325:158 (4% detector), 325:241–248 (the palettization
  passage), 325:249–262 (export and the 76% figure), 325:263–267 (closing recommendations).
- **Session 330**, *"…Metal tensors and TensorOps"*. Cited at 330:21–26 for the
  memory-bandwidth-bound framing only. Everything else about session 330 belongs to Part 11.

### 22.4 Community

- `notes/repos/john-rocky-models.md` — a **single-author community archive with self-declared
  uncontrolled benchmarks**. Every citation in this guide is labelled 🟢 **COMMUNITY-MEASURED** with
  hardware and caveats where the archive states them. Its `compression.md`,
  `compression-reference.md`, `compute-units-and-authoring.md`, `apple-models-bench.md` and
  `dense-int4km-flagship-session-findings.md` sections were used.

### 22.5 What this guide deliberately does not claim

For the record, and so that a future editor does not "fix" an absence into an invention:

- **No `coreai_opt.mixed_precision` module.** The package tree has `quantization/`, `palettization/`,
  `pruning/`, `casting/`, `inspection/`, `coreai_utils/`, `config/`, `deps/`, `_utils/`. There is no
  mixed-precision subpackage in it. §14's sweep is code you write.
- **No `KMeansPalettizer.training_mode()`**, no palettization-aware training, no `DKMPalettizer`.
- **No pruning presets.** `MagnitudePrunerConfig.presets` does not exist.
- **No `n_bits=5` or `n_bits=7`.**
- **No claim that the Core AI runtime exploits sparsity.** §11.8 is a declared gap, not an omission.
- **No `.coreaimodel` or `.aiasset` file extension**, no `coreai-torch convert` CLI, no
  "iOS 20 / macOS 17", and no on-device LoRA training API. All four are in circulation and all four
  are fabricated. Part 1 carries the known-bad-claims reference.

### 22.6 Open questions, collected

Every 🔴 GAP in this guide, in one place, so they can be closed by someone with a device:

| § | Unknown | What would resolve it |
|---|---|---|
| 2.1 | Whether palettization-aware training is planned | a `training_mode()` under `palettization/`, or a changelog entry |
| 4.3 | Device latency and compute-unit placement for `cluster_dim > 1` | timing two artefacts under `from_preferred_compute_unit_kind` |
| 5.3 | The precise axis accounting behind the rank-6 LUT | an MLIR dump of the lowered program, or an `mps.dequantize_lut` doc page |
| 8.4 | The quality delta from sensitivity-weighted k-means in `coreai-opt` | an ablation on `edsr` or `resnet50` |
| 10.3 | The on-disk layout under `mmap_dir` | reading the directory after a `finalize(mmap_dir=...)` |
| 11.8 | Whether Core AI exploits unstructured sparsity for size or speed | `.aimodel` size + on-device latency, 0% vs 70% sparse |
| 12.2 | Whether Apple silicon exploits `n:m` or block sparsity | same measurement, with `n_m_ratio=(2,4)` |
| 14.2 | Whether a helper API exists for the greedy mixed-precision search | `make api-list`, or reading `docs/src/utils/mixed_precision.md` |
| 15.5 | The Debugger's full list of similarity metrics | the metric picker in Xcode 27 |
| 17.3 | Whether every utility export script exposes `--dtype` | `--help` on each script in `apple/coreai-models` |

---

*Part 9 · Reference 02. Previous: [01 — `coreai-opt` quantization](01-quantization.md). Part 10
covers the Core AI Debugger, hardware-specific authoring, and the rank/layout rules this guide's §5
depends on.*

[^sample-routing-policy]: The classifier and preferences are implemented in the optional
    `apple/coreai-models` package’s pinned
    [`ModelStructure.swift`](https://github.com/apple/coreai-models/blob/5ed9981303b38d5a44aa6b45509bc4f6945029f5/swift/Sources/CoreAIShared/Runtime/ModelStructure.swift#L12-L218).
    Core AI’s `.default` behavior is documented separately in
    [Managing model specialization and caching](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/docs/Managing%20model%20specialization%20and%20caching.md).

[^destructive-finalize-scope]: The pinned k-means palettizer docstring limits this behavior to its
    Core AI backend:
    [`KMeansPalettizer.finalize`](https://github.com/apple/coreai-optimization/blob/cd95cb2545a586dbc14c85f5efd16b4635e5786c/src/coreai_opt/palettization/kmeans/palettizer.py#L357-L425).
