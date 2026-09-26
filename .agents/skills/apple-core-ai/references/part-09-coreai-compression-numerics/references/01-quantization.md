# `coreai-opt` quantization: configs, GRAPH vs EAGER, calibration and QAT

**Part 9 · Core AI: compression and numeric formats · Reference 01**

**Version floor.** Everything in this guide is host-side Python. The package is **`coreai-opt`**
(import `coreai_opt`), and the version this guide is verified against is **0.2.1, released
2026-07-02** — with a handful of behaviours taken from `main` at commit `cd95cb2`, which is
**newer than 0.2.1 and not in any release**; those are marked inline. `0.2.0` was the initial
release, **2026-06-08**. Host requirements are hard: **Python ≥ 3.11, < 3.14**; **torch ≥ 2.8.0,
≤ 2.11.0**; **torchao ≥ 0.15.0, ≤ 0.17.0**; macOS or Linux; and a **C++ toolchain present at
runtime**. The artefacts you produce deploy to **Core AI on iOS 27.0 / macOS 27.0** — Core AI does
not exist before 27.0, on any platform. The optional `coreml` path targets **`ct.target.iOS26`**
and is a strictly smaller feature set. There is no "26.4 Core AI"; if you read that anywhere, it is
wrong.

⚠️ **Core AI has zero Apple sample-code projects.** Verified: 0 `sampleCode` entries across all 312
indexed Core AI symbols, and `/documentation/updates/coreai` 404s. Unlike Parts 1–6, there is no
first-party compiling Xcode project to check a signature against. The strongest evidence available
for this guide is, in order: the **shipped source of `apple/coreai-optimization`**, **Apple's own
agent skills** vendored in `apple/coreai-models` (Apple engineers' empirical rules, written for
machine consumption and therefore unusually literal), the **`coreai-opt` documentation site**, the
**GitHub issue and PR threads** where Apple maintainers answer, and **WWDC26 session 325**. Every
signature below carries its source. Where the session transcript and the shipped source disagree —
and they do, three times — the source wins and the guide says so.

---

## What this covers

`coreai-opt` is where size, quality and latency are actually traded. Everything upstream of it
(re-authoring, conversion) changes *what* runs; everything downstream (specialization, compilation)
changes *where* it runs. This is the only stage where you deliberately throw information away.

The framing Apple gave it on stage is worth holding onto, because the whole API follows from it:

> ✅ **VERIFIED** — WWDC26 session 325, *"Dive into Core AI model authoring and optimization"*
> (Sachin, Core AI), 325:64–68:
> *"`coreai-opt` enables **config-driven model compression**, you describe **what to compress and
> what to leave alone**. It supports **various optimization schemes**, from which you can choose one
> to **optimize differently for macOS versus iOS**, as an example. It also supports **int4, int8, FP4
> and FP8** weight compression with **flexible granularity**. `coreai-opt` includes quantization APIs
> that you can either use with a **small amount of calibration data**, or perform **quantization
> aware training on larger data sets**."*

Four claims, four sections of this guide. All four are verifiable in the shipped source, and this
guide verifies each one rather than repeating it.

What follows:

- **The compressor lifecycle** — `__init__` → `prepare` → (`calibration_mode` | `training_mode`) →
  `finalize`, the four-method contract that quantization, palettization and pruning all share, and
  the two places it mutates your model irreversibly.
- **Presets**, and exactly what each one expands to. `presets.w4()` is one line; knowing which
  eleven fields it sets is the difference between using it and debugging it.
- **The config hierarchy** — three levels of scope (name → type → global), three groups of tensors
  (`op_input_spec` / `op_output_spec` / `op_state_spec`), and the single most load-bearing rule in
  the whole package: **`None` means "leave this alone", and it is not the same as omitting the
  field.**
- **The scoping mechanisms** — `module_name_configs` is matched with `re.fullmatch`,
  `module_type_configs` requires **fully-qualified** class names, and there are chainable
  `only_for` / `without` helpers with one sharp edge each.
- **`QuantizationSpec`, field by field** — nine fields, nine supported dtypes, three qschemes, two
  formulations, and the scale/zero-point formula for each combination, straight from the class
  docstring.
- **Granularity** — per-tensor, per-channel, per-block; the per-module-type default axis table; and
  ⚠️ the fact that a block size your weight isn't divisible by produces a **warning and an
  uncompressed layer**, not an error.
- **GRAPH vs EAGER** — a real structural split, not a flag. The source tree has separate `_graph/`
  and `_eager/` implementations with different capabilities, different config vocabularies and
  different failure modes. This section tells you which one to reach for and why the transcript's
  advice and the repo's default disagree.
- **Activation quantization** — why it needs GRAPH mode, what `calibration_mode()` actually toggles
  (it is not what you would guess), the six ops whose qscheme the framework overrides behind your
  back, and the shared-observer correctness constraint that landed as a fix three days before this
  guide was written.
- **PTQ vs QAT** — data-free, calibration-based and fine-tuning-based workflows, with Apple's own
  cost and accuracy guidance for each, and the **`QATSchedule`** three-integer state machine with
  its validation rules and its two conflict-resolution policies.
- **The SAM3 story** — the best teaching narrative available for this material: 3 GB → ~430 MB with
  `presets.w4()` applied uniformly, an occluded flower that stops being detected, a diagnosis that
  lands in a block holding **4% of the parameters**, and the config change that recovers baseline
  quality at a fraction of the size.
- **`coreai_opt.casting`** — the fp16/int16 helper, why it runs on the `ExportedProgram` and not the
  `nn.Module`, the compress-then-cast ordering rule, and the open overflow hazard its maintainer has
  acknowledged.
- **`coreai_opt.coreai_utils`** — compressing an **already-converted** Core AI program instead of a
  PyTorch one, when that is the right call, and Apple's own "this is not the recommended path"
  caveat.

## What this does *not* cover

- **Palettization** (`KMeansPalettizer`) beyond the comparisons needed here. Palettization is
  eager-only, weight-only, and has its own granularity vocabulary; it gets its own guide in this
  part. It appears below only in the SAM3 story and the joint-compression ordering rule.
- **Pruning** (`MagnitudePruner`) — same reason.
- **The Core AI Debugger** — the tool that produced the SAM3 diagnosis. Its workspace, sync points,
  PSNR metric and `save_intermediates` reference-capture API are Part 10's material. §13 uses its
  *output* and cross-links.
- **Conversion** — `torch.export`, `get_decomp_table()`, `TorchConverter`, `optimize()`,
  `save_asset()`. That is Part 8. This guide starts with an `nn.Module` and hands back an `nn.Module`.

## What you need

```bash
pip install coreai-opt                    # or: uv pip install coreai-opt
pip install 'coreai-opt[coreai]'          # adds coreai-core==1.0.0b2, coreai-torch==0.4.1, scikit-learn
```

- **A C++ compiler on the host at runtime.** Not just at install time. The vendored `kmeans1d` core
  is JIT-compiled by `torch.utils.cpp_extension.load()` on first palettization use. If you only
  quantize you will not hit this, but the dependency is declared for everyone.
- **A representative sample of your real inputs.** Not `torch.randn`. This matters enormously for
  activation quantization and is stated three separate times in Apple's docs; §10.2 explains why.
- **A working evaluation metric before you start.** Every decision below is a trade, and you cannot
  evaluate a trade you cannot measure. Apple's own agent skill refuses to proceed without one.

---

## Contents

1. [Where compression sits, and what it actually costs](#1-where-compression-sits-and-what-it-actually-costs)
2. [The compressor lifecycle: four methods, one contract](#2-the-compressor-lifecycle-four-methods-one-contract)
3. [Presets: the one-liners, and what they expand to](#3-presets-the-one-liners-and-what-they-expand-to)
4. [The config hierarchy: three levels, three tensor groups, and `None`](#4-the-config-hierarchy-three-levels-three-tensor-groups-and-none)
5. [Scoping: regex names, fully-qualified types, `only_for` and `without`](#5-scoping-regex-names-fully-qualified-types-only_for-and-without)
6. [`QuantizationSpec`: every field](#6-quantizationspec-every-field)
7. [Granularity, default axes, and the silent skip](#7-granularity-default-axes-and-the-silent-skip)
8. [GRAPH vs EAGER: a structural split, not a flag](#8-graph-vs-eager-a-structural-split-not-a-flag)
9. [Activation quantization: observers, calibration, shared observers](#9-activation-quantization-observers-calibration-shared-observers)
10. [PTQ: data-free and calibration-based](#10-ptq-data-free-and-calibration-based)
11. [QAT: the schedule, `step()`, and the two conflict rules](#11-qat-the-schedule-step-and-the-two-conflict-rules)
12. [KV-cache quantization (graph mode only)](#12-kv-cache-quantization-graph-mode-only)
13. [The SAM3 story: uniform compression is almost never right](#13-the-sam3-story-uniform-compression-is-almost-never-right)
14. [`coreai_opt.casting`: the fp16 helper and the ordering rule](#14-coreai_optcasting-the-fp16-helper-and-the-ordering-rule)
15. [`coreai_opt.coreai_utils`: compressing an already-converted program](#15-coreai_optcoreai_utils-compressing-an-already-converted-program)
16. [Export backends, and the CoreML restriction matrix](#16-export-backends-and-the-coreml-restriction-matrix)
17. [⚠️ Silent failures, consolidated](#17-️-silent-failures-consolidated)
18. [Numbers, attributed](#18-numbers-attributed)
19. [Quick reference](#19-quick-reference)
20. [Sources and evidence ledger](#20-sources-and-evidence-ledger)

---

## 1. Where compression sits, and what it actually costs

### 1.1 The pipeline position

Compression is an **optional step inserted before conversion**, and it operates on a PyTorch
`nn.Module`, handing back another PyTorch `nn.Module`. That property — compressor output is itself a
PyTorch model — is what lets you evaluate the compressed model in PyTorch before you commit to an
export.

> ✅ **VERIFIED** — session 325:69–72: *"This is the simple pipeline I had previously. Now I am
> adding a step. **Before conversion**, I run the model through `coreai-opt` with a compression
> config or I can use one of their convenient **presets**. This gives me a smaller model that still
> goes through the same export pipeline."*

```
nn.Module
   │
   ├─(coreai-opt)  Quantizer / KMeansPalettizer / MagnitudePruner
   │                  __init__(model, config)
   │                  .prepare(example_inputs)         ← compression happens here
   │                  [.calibration_mode() | .training_mode()]
   │                  .finalize(backend=ExportBackend.CoreAI)
   ▼
compressed nn.Module
   │
   ├─ torch.export.export(...)                          ┐
   ├─ .run_decompositions(coreai_torch.get_decomp_table())│  Part 8
   ├─ [coreai_opt.casting.cast_to_16_bit_precision(...)] │  ← §14, and it lives here, not earlier
   ├─ TorchConverter().add_exported_program(...).to_coreai()
   ├─ AIProgram.optimize()                              │
   └─ AIProgram.save_asset(Path("model.aimodel"))       ┘
```

Apple's own agent skill states the pipeline as five steps and explicitly marks two of them optional:

> ✅ **VERIFIED** — `apple/coreai-models`,
> `skills/skills/working-with-coreai/SKILL.md`:
> ```text
> 1. AUTHOR    Re-structure model for target platform
> 2. COMPRESS  Explore quantization/palettization tradeoffs
> 3. EXPORT    Convert PyTorch → AIProgram via TorchConverter
> 4. COMPILE   Ahead-of-time compilation for target platform
> 5. RUN       Load and run on device (Swift or Python)
> ```
> *"Steps 1 and 2 are optional — many models export directly without re-authoring or compression.
> **Start with export, then add authoring or compression if needed** (poor accuracy, poor
> performance, too large)."*

Take that seriously. Compression is a response to a measured problem — the model does not fit, or it
does not hit your latency budget — not a default step. A model that already fits and already meets
its budget gets nothing from being compressed except risk.

### 1.2 What each workflow costs

Apple publishes cost guidance per workflow. This is the most useful planning table in the
documentation and it is worth internalising before you write a single config.

> ✅ **VERIFIED** — `coreai-opt` docs, `docs/src/landing_page.md:43-47`:
>
> | Workflow | Data needed | Time | Where it works |
> |---|---|---|---|
> | **Data-free** | none | *"typically seconds to minutes even for large models"* | *"Often works well for reducing the model down to 8 bits, or even 6 or 4 bits, with only a slight decrease in accuracy."* |
> | **Calibration-based** | *"A small amount of representative data (e.g. ~128 samples)"* | minutes | required for activation quantization |
> | **Fine-tuning-based (QAT)** | full training set | *"the most time-intensive workflow"* | *"typically the only way to recover accuracy at the most aggressive compression ratios for weights (4 bits and below)"* |
>
> Supported precisions, same page: **weights INT2 / INT4 / INT8 + FP4 / FP8; activations INT8 and
> FP8; palettization N ∈ {1,2,3,4,6,8} bits.**

Two consequences most people get wrong:

1. **Weight-only 8-bit needs no data at all.** If your only problem is size and 2× is enough, you are
   done in one line and one minute. Do not build a calibration harness for that.
2. **Activation quantization always needs data.** There is no data-free path to activation ranges;
   an observer has to *see* activations. If you are quantizing activations you are, by definition,
   in the calibration workflow at minimum.

### 1.3 The three techniques, and why this guide is only about one

`coreai-opt` ships three compressors, all sharing one lifecycle:

> ✅ **VERIFIED** — `README.md:3`: *"`coreai-opt` provides implementations of popular model
> optimizations such as **quantization, palettization (codebook-based compression), and pruning**,
> for PyTorch models, customized for deployment on Apple Silicon via Core AI."*

| Compressor | Config | Modes | Weights | Activations | `training_mode()` |
|---|---|---|---|---|---|
| `Quantizer` | `QuantizerConfig` | GRAPH + EAGER | ✓ | ✓ | ✓ |
| `KMeansPalettizer` | `KMeansPalettizerConfig` | **EAGER only** | ✓ | ✗ | ✗ |
| `MagnitudePruner` | `MagnitudePrunerConfig` | **EAGER only** | ✓ | ✗ | ✗ (uses `step()` + your own loop) |

`Quantizer` is the only one with an activation story, the only one with QAT, and the only one with a
graph-mode implementation. It is also the only one that can quantize a KV cache. That is why it gets
its own guide.

> ✅ **VERIFIED** — `docs/src/palettization/config.md:119`: *"Palettization supports eager mode
> only."* And `_BaseModelCompressor.training_mode()` raises
> `NotImplementedError("{cls} does not implement training_mode(). This compressor doesn't support
> training time compression.")` for everything except `Quantizer`.

### 1.4 The relationship to `coremltools.optimize`

If you have shipped a Core ML model before, `coreai-opt` will read as the successor to
`coremltools.optimize` — because it is. It targets `.aimodel` first and keeps a compatibility path.

> ✅ **VERIFIED** — `coreai_opt/common.py:137-160`:
> ```python
> class ExportBackend(_StrEnum, metaclass=_DeprecatedMemberEnumMeta):
>     _TORCH = auto()
>     CoreML = auto()
>     CoreAI = auto()
>
>     __deprecated_aliases__: ClassVar[dict[str, str]] = {"MIL": "CoreML", "MLIR": "CoreAI"}
> ```

Three things to note. `ExportBackend.MIL` and `ExportBackend.MLIR` still resolve but emit
`DeprecationWarning` — on attribute access *and* on value lookup, case-insensitively. `_TORCH` is a
real member, not a private accident: it is the "keep this as a fake-quantized PyTorch model for
evaluation" escape hatch, and it is the **only** backend that accepts dynamic quantization (§6.5).
And `coremltools` is no longer a runtime dependency at all:

> ✅ **VERIFIED** — changelog fragment `changelog.d/31.changed` (merged as PR #31): *"Replace the
> coremltools-based 1D k-means used by palettization with a vendored C++ core that is JIT-compiled at
> runtime via `torch.utils.cpp_extension`. `coremltools` is no longer a runtime dependency (it is now
> an optional dependency, installable via the `coreml` extra). **This requires a C++ compiler to be
> available on the host at runtime.**"*

---

## 2. The compressor lifecycle: four methods, one contract

Every compressor in `coreai-opt` derives from `_BaseModelCompressor`
(`src/coreai_opt/base_model_compressor.py`) and exposes the same five-member surface.

> ✅ **VERIFIED** — `base_model_compressor.py` plus
> `docs/src/introduction/how_to_use_coreaiopt.md`:
>
> | Method | Semantics |
> |---|---|
> | `__init__(model, config)` | The compressor is built from an `nn.Module` plus a config object. |
> | `prepare(...) -> nn.Module` | Compresses weights and inserts fake-quantize / fake-palettize / mask ops. A forward pass on the result reflects compression. **Data-free PTQ happens here.** May modify in place — use the returned model. |
> | `calibration_mode(...)` | Context manager. Enables observers / sensitivity collection during forwards. |
> | `training_mode(...)` | Context manager. QAT: train mode + observers + fake quant. **Only `Quantizer` implements it.** |
> | `finalize(model=None, backend=ExportBackend.CoreAI, *, mmap_dir=None)` | Freezes qparams, swaps fake ops for backend ops/metadata. |

### 2.1 The minimum viable quantization

```python
import torch
from coreai_opt.quantization import Quantizer, QuantizerConfig

model = MyModel().eval()
example_inputs = (torch.randn(1, 3, 224, 224),)      # MUST be a tuple

config = QuantizerConfig.presets.w8()                 # int8 weight-only, per-channel symmetric
quantizer = Quantizer(model, config)

prepared_model = quantizer.prepare(example_inputs)    # weights are compressed HERE
quantized_model = quantizer.finalize()                # backend defaults to ExportBackend.CoreAI
```

Five lines, no data, no calibration loop. For weight-only 8-bit this is genuinely the whole thing.

> ✅ **VERIFIED** — `src/coreai_opt/quantization/quantizer.py`, exact signatures:
> ```python
> class Quantizer(_BaseQuantizer):
>     def __init__(self, model: nn.Module, config: QuantizerConfig | None = None)
>
>     def prepare(
>         self,
>         example_inputs: tuple[Any, ...],
>         dynamic_shapes: dict[str, Any] | tuple[Any] | list[Any] | None = None,
>         export_with_no_grad: bool = True,
>     ) -> nn.Module | fx.GraphModule
>
>     def finalize(
>         self,
>         model: nn.Module | fx.GraphModule | None = None,
>         backend: ExportBackend = ExportBackend.CoreAI,
>         *,
>         mmap_dir: str | PathLike[str] | None = None,
>     ) -> nn.Module | fx.GraphModule
>
>     @contextmanager
>     def calibration_mode(self, model=None)
>     @contextmanager
>     def training_mode(self, model=None)
>
>     def step(self) -> None                       # advances the QAT schedule
>     def enable_observer(self, module: nn.Module | None = None) -> None
>     def disable_observer(self, module: nn.Module | None = None) -> None
>     def enable_fake_quant(self, module: nn.Module | None = None) -> None
>     def disable_fake_quant(self, module: nn.Module | None = None) -> None
> ```

`Quantizer(model, config=None)` with no config is legal, and it is not a no-op:

> ✅ **VERIFIED** — `Quantizer.__init__` docstring: *"If None, a default configuration with int8
> weight and activation quantization is created."*

A bare `QuantizerConfig()` is **W_INT8(per-channel) A_INT8(per-tensor)** — weights *and*
activations. That is almost never what someone typing `Quantizer(model)` expects, and it will
produce a model whose activation qparams were seeded from your `example_inputs` and never refined.
Be explicit.

### 2.2 `example_inputs` must be a tuple, and must be representative

Two rules, both enforced, both regularly violated.

> ✅ **VERIFIED** — `prepare()` asserts a **non-empty tuple**: `TypeError("example_inputs must be a
> tuple")` for a non-tuple, `ValueError` for an empty one.

```python
quantizer.prepare(torch.randn(1, 3, 224, 224))       # TypeError
quantizer.prepare([torch.randn(1, 3, 224, 224)])     # TypeError — a list is not a tuple
quantizer.prepare((torch.randn(1, 3, 224, 224),))    # correct; note the trailing comma
```

The second rule is not enforced and cannot be:

> ✅ **VERIFIED** — the `coreai-opt` docs state this three separate times: for **activation
> quantization**, `example_inputs` must be **representative** data, not `torch.randn`. The initial
> forward pass inside `prepare()` seeds the activation qparams.

For weight-only quantization the values in `example_inputs` are irrelevant — only shapes and dtypes
matter, because no observer is looking at activations. For anything touching activations, random
noise gives you an activation range calibrated to noise. Nothing will warn you.

### 2.3 `prepare()` mutates in place — take a copy first

> ✅ **VERIFIED** — consolidated from the source and docs: *"`prepare()` mutates in place."* In
> **eager** mode, `.weight` on **both** the original and the returned model returns the
> fake-quantized value after `prepare()`, because parametrizations are registered in place.

```python
import copy

float_model = copy.deepcopy(model)            # do this BEFORE prepare()
prepared_model = quantizer.prepare(example_inputs)

# float_model still has dense fp32 weights; model does not.
```

Re-preparing is rejected outright:

> ✅ **VERIFIED** — `RuntimeError("Model has already been prepared. Cannot re-prepare a prepared
> model.")`

The prepared state is tracked with a deliberately-designed marker:

> ✅ **VERIFIED** — `base_model_compressor.py:21,57-69`:
> ```python
> _COREAI_OPT_PREPARED_ATTR = "_coreai_opt_prepared"
> model.register_buffer(_COREAI_OPT_PREPARED_ATTR, torch.tensor(True), persistent=False)
> ```
> A **non-persistent buffer**, so it survives `deepcopy` of an `fx.GraphModule` but stays out of
> `state_dict()`. `KMeansPalettizer.finalize()` deletes it, which is what lets a palettized model be
> handed to `Quantizer` for joint compression.

### 2.4 Train/eval mode is handled for you on the way in, and not on the way out

> ✅ **VERIFIED** — `docs/src/introduction/how_to_use_coreaiopt.md:39,79`:
> - *"You don't need to put the model in `.eval()` or `.train()` before calling `prepare()` — the API
>   runs the trace internally in eval mode and restores the original mode when it returns."*
> - *"**The finalized model inherits the current training mode, so call `.eval()` on it** before
>   running inference or downstream conversion."*

The asymmetry is easy to miss and produces a class of bug where dropout is silently active during
your post-quantization evaluation:

```python
quantized_model = quantizer.finalize()
quantized_model.eval()                        # <- do not skip this
```

There is a second trap layered on top, specific to graph mode:

> ✅ **VERIFIED** — `fx.GraphModule.train()` / `.eval()` after prepare or finalize is enabled via
> torchao's `allow_exported_model_train_eval`, but *"**only dropout and batchnorm ops are affected
> via FX graph rewriting.** User code branching on the `training` flag and other ops with
> mode-dependent behavior are not affected."*

So `.eval()` on a graph-mode model handles dropout and BN and nothing else. If your module's
`forward` contains `if self.training:`, that branch was resolved at export time and `.eval()` will
not change it.

### 2.5 `finalize()` is destructive, and validates first

`finalize()` runs two validations before it does anything:

> ✅ **VERIFIED** — `quantizer.py`: `finalize()` runs `_validate_mmap_dir_constraints` and
> `_validate_no_persistent_observer_calculators` first.

And in eager mode with the CoreAI backend it **frees the original dense weights**:

> ✅ **VERIFIED** — `quantizer.py:478-480` docstring: `finalize(backend=CoreAI)` in eager mode
> *"frees the original dense weights"*. The palettization path is even more explicit
> (`kmeans/_prepare_for_export.py`): *"The dense pre-palettization weight stored on the
> parametrization list is always replaced with a zero-size placeholder so its storage can be
> released."*

This is not reversible. If you want to compare against the float model afterwards, you needed the
`deepcopy` from §2.3.

There is a corresponding piece of advice that is easy to overlook and saves real time:

> ✅ **VERIFIED** — `KMeansPalettizer.finalize()` docstring, and the same logic applies to
> `Quantizer`: *"**Only call `finalize` when exporting to a target backend.** For torch-based
> evaluation, **use the model returned by `prepare()` directly** rather than calling `finalize`."*

Apple's own compression-exploration agent skill follows this to the letter:

> ✅ **VERIFIED** — `apple/coreai-models`,
> `skills/skills/model-compression-exploration/SKILL.md`: *"Do **not** call `finalize()`"* during the
> sweep — *"Calibration is not needed for weight-only compression."*

A sweep of sixty configs that calls `finalize()` sixty times is doing sixty irreversible weight
frees and sixty backend lowerings for no reason. `prepare()` alone gives you a numerically faithful
model to score.

### 2.6 `mmap_dir` — eager + CoreAI only

`finalize(mmap_dir=...)` backs the finalized weights with memory-mapped files instead of resident
tensors. It is the mechanism behind `coreai-models`' `from_hf_memory_efficient` export path for
large LLMs on macOS. It has three hard constraints:

> ✅ **VERIFIED** — `_graph/quantizer.py:1051-1054`:
> `ValueError("mmap_dir is only supported in eager execution mode, got execution_mode=graph.")`
>
> ✅ **VERIFIED** — `_utils/export_utils.py:validate_mmap_backend_and_device`: *"`mmap_dir` requires
> the prepared model to be on CPU; found tensor(s) on device(s) …. Call `model.cpu()` before
> `finalize(mmap_dir=…)`. mmap is a CPU-only mechanism."*
>
> ✅ **VERIFIED** — the directory must be empty (`FileExistsError` otherwise) and *"the files in
> `mmap_dir` must remain in place for the lifetime of the returned model; removing them invalidates
> the mmap-backed weights."*

🔴 **GAP — the on-disk layout under `mmap_dir` is unverified.** No end-to-end `mmap_dir` example
exists in the `coreai-opt` docs, and the safetensors filenames and sharding scheme were not read.
What would resolve it: running `finalize(mmap_dir=d)` on any model and listing `d`, or reading
`_utils/export_utils.py` in full. **Safe default meanwhile:** treat the directory as opaque, create
it fresh per export with `tempfile.TemporaryDirectory()`, and keep it alive exactly as long as the
returned model — which is what Apple's own LLM export pipeline does
(`tempfile.TemporaryDirectory(prefix="coreai_export_")`, `coreai-models` `export/pipeline.py`).

---

## 3. Presets: the one-liners, and what they expand to

### 3.1 The complete roster

There are exactly **three** quantization presets. Not four, not a family.

> ✅ **VERIFIED** — `src/coreai_opt/quantization/config/_presets/quantizer_config.py`:
>
> | Preset | Signature | Expands to |
> |---|---|---|
> | `w8` | `w8(*, axis: int \| None = None, execution_mode: ExecutionMode = ExecutionMode.GRAPH)` | `int8`, SYMMETRIC, `PerChannelGranularity(axis)`, **weight-only** |
> | `w4` | `w4(*, axis: int \| None = None, execution_mode: ExecutionMode = ExecutionMode.GRAPH)` | `int4`, SYMMETRIC, `PerChannelGranularity(axis)`, **weight-only** |
> | `w4_per_block` | `w4_per_block(*, block_size: int = 32, axis: int \| None = None, execution_mode=GRAPH)` | `int4`, SYMMETRIC, `PerBlockGranularity(axis, block_size)`, **weight-only** |
>
> **There is no `w2`, no `w6`, no `fp8`, and no activation preset for quantization.** (Palettization
> has its own `w4` / `w6` / `w8` presets with entirely different meanings — see §13.4.)

They exist on two classes with identical spellings:

> ✅ **VERIFIED** — `QuantizerConfig.presets` returns a whole `QuantizerConfig`;
> `ModuleQuantizerConfig.presets` returns a `ModuleQuantizerConfig` for use as one entry in a larger
> config. The `ModuleQuantizerConfig` variants take the same kwargs **minus `execution_mode`**, which
> only exists at the top level.

### 3.2 `presets.w4()`, expanded

This is the preset the SAM3 demo uses, and the one whose consequences §13 is about. Here is exactly
what it is:

> ✅ **VERIFIED** — `_presets/quantizer_config.py`, quoted in full:
> ```python
> def w4(
>     self,
>     *,
>     axis: int | None = None,
>     execution_mode: ExecutionMode = ExecutionMode.GRAPH,
> ) -> QuantizerConfig:
>     """int4 weight-only quantization, per-channel symmetric."""
>     weight_spec = QuantizationSpec(
>         dtype=torch.int4,
>         qscheme=QuantizationScheme.SYMMETRIC,
>         granularity=PerChannelGranularity(axis=axis),
>     )
>     global_config = ModuleQuantizerConfig(
>         op_input_spec=None,
>         op_output_spec=None,
>         op_state_spec={"weight": weight_spec},
>     )
>     return self._owner_cls(global_config=global_config, execution_mode=execution_mode)
> ```

Read the three `op_*` lines carefully, because they are the template for every hand-written config
you will ever produce:

- `op_input_spec=None` — **do not quantize op inputs.** `None` here is the disable signal (§4.3).
- `op_output_spec=None` — **do not quantize op outputs.**
- `op_state_spec={"weight": weight_spec}` — **quantize the tensor literally named `weight`**, and
  nothing else. Note what this excludes: `bias` is untouched, and so is every other entry in the
  module's state.

"Weight-only quantization" is not a mode or a flag anywhere in this API. It is precisely the
three-line pattern above.

The `axis=None` default is resolved per module type at prepare time (§7.3), which is why the preset
can be one line and still do the right thing for a `Conv2d` and a `Linear` and an `Embedding` in the
same model.

> ✅ **VERIFIED** — preset docstring: *"`axis`… When `None` (default), the axis is **auto-resolved
> based on the module type** during quantization."*

### 3.3 The transcript's one-liner, and the correction

> ✅ **VERIFIED** — session 325:90–92: *"`coreai-opt` ships with **preset configurations**.
> `presets.w4` gives me **4-bit per-channel, symmetric quantization in one line**. I set
> **`ExecutionMode` to `EAGER`, which works great for weight compression. For activations, I would use
> the `GRAPH` mode.**"*

Both statements check out against the source. Two spellings are available and both are real:

```python
from coreai_opt.quantization import Quantizer, QuantizerConfig, ExecutionMode

# Option A — pass it to the preset (preferred; one expression)
config = QuantizerConfig.presets.w4(execution_mode=ExecutionMode.EAGER)

# Option B — set it afterwards (chainable, returns Self)
config = QuantizerConfig.presets.w4()
config.set_execution_mode(ExecutionMode.EAGER)
```

> 🟡 **RECONSTRUCTED** — the exact lines shown on screen in session 325 were not published as a code
> sample. Both spellings above are verified against `_presets/quantizer_config.py` and
> `quantization_config.py`; which one the demo used is unknown and does not matter.

⚠️ **A discrepancy worth knowing about.** The transcript says EAGER "works great for weight
compression". The repository says **GRAPH is the recommended default**, and
`QuantizerConfig.execution_mode` defaults to `ExecutionMode.GRAPH`. Both are true, and §8 reconciles
them properly. The short version: for weight-only work the two modes converge numerically, and EAGER
sidesteps the `torch.export` requirement — which for a model as structurally awkward as SAM3 is a
real win, not a stylistic preference.

### 3.4 A preset is a starting point, not an answer

Presets set a **global** config. That means they apply to *every* supported op in the model. §13 is
an extended argument that this is almost never what you want at 4 bits — but it is exactly what you
want for a first data point, because it tells you the size floor and the quality floor in one run.

The workflow Apple's own agent skill encodes is: anchor on presets, then refine.

> ✅ **VERIFIED** — `apple/coreai-models`,
> `skills/skills/model-compression-exploration/SKILL.md`. The sweep it drives is roughly **30
> main-sweep configs plus 30 refinement configs**. Preset anchors named explicitly:
> `presets.w8()`, `presets.w4()`, `presets.w4_per_block(block_size=32)`, and on the palettization
> side `KMeansPalettizerConfig.presets.w8()/w6()/w4()`.
> The sweep groups:
> - **1a** channel-structured quantization: `{int8, int4} × {symmetric, asymmetric, symmetric_with_clipping}` = 6 configs
> - **1b** block-structured: `{block_size 16, 32, 128} × {3 qschemes}` at int4 = 9 configs
> - **2** palettization: `{8-bit per-tensor, 6-bit per-tensor, 6-bit gs 4/8/16, 4-bit gs 4/8/16} × {enable_per_channel_scale True/False}` = 15 configs
>
> Refinement: *"filter PSNR < 10 dB / IoU < 0.1, pick 95th & 75th percentile seeds, 5 layer-skip
> variants each via `set_module_name` overrides."*

That last clause is the important one. Apple's own automated exploration ends by generating
**layer-skip variants** — which is to say, its refinement phase is entirely about finding what to
*exclude*. §13 is the human version of the same conclusion.

One operational detail from the same skill, worth copying:

> ✅ **VERIFIED** — same file: the timing probe uses `QuantizerConfig.presets.w8()` in the default
> graph mode; **on `Quantizer.prepare` failure it falls back to
> `QuantizerConfig.presets.w8(execution_mode=ExecutionMode.EAGER)` for the whole sweep.**

Not per-config — for the whole sweep. Mixing modes across a comparison table would make the results
incomparable, because the two modes are explicitly not guaranteed to produce equivalent models
(§8.3).

---

## 4. The config hierarchy: three levels, three tensor groups, and `None`

This is the section to read twice. Everything else in the guide is a consequence of it.

### 4.1 Three levels of scope

> ✅ **VERIFIED** — `QuantizerConfig` docstring,
> `src/coreai_opt/quantization/config/quantization_config.py:576-582`:
> *"The configuration lookup follows a hierarchical precedence (most to least specific):
> 1. **`module_name_configs`** — Applies to module instances matching a name pattern (**supports
>    regex**)
> 2. **`module_type_configs`** — Applies to all modules of a specific type
> 3. **`global_config`** — Default configuration applied to all modules not otherwise configured"*
>
> *"**Setting a config to `None` explicitly disables quantization for that scope.**"*

```python
class QuantizerConfig(CompressionConfig[ModuleQuantizerConfig]):   # @final
    global_config: ModuleQuantizerConfig | None
    module_type_configs: dict[str | type[nn.Module], ModuleQuantizerConfig | None] = {}
    module_name_configs: dict[str, ModuleQuantizerConfig | None] = {}
    preserved_attributes: list[str] | None = None
    execution_mode: ExecutionMode = ExecutionMode.GRAPH
    kv_cache_quant_configs: dict[str, KVCacheQuantConfig] | None = None
```

> ✅ **VERIFIED** — `quantization_config.py`. `_CONFIG_KEY = "quantization_config"`,
> `_SPEC_KEY = "quantization_spec"` (the YAML top-level keys, §5.4).

### 4.2 Three groups of tensors

Inside a `ModuleQuantizerConfig`, the same precedence idea repeats one level down —
`op_name_config > op_type_config > op_input/output/state_spec` — and the leaf-level vocabulary is
three dictionaries.

> ✅ **VERIFIED** — `ModuleQuantizerConfig`, verbatim field list:
> ```python
> class ModuleQuantizerConfig(ModuleCompressionConfig[OpQuantizerConfig, QuantizationSpec]):  # @final
>     op_input_spec:    dict[str|int, QuantizationSpec|None] | None
>     op_output_spec:   dict[str|int, QuantizationSpec|None] | None
>     op_state_spec:    dict[str,     QuantizationSpec|None] | None
>     op_type_config:   dict[str, OpQuantizerConfig|None] = {}
>     op_name_config:   dict[str, OpQuantizerConfig|None] = {}
>     module_input_spec:  dict[str|int, QuantizationSpec|None] = {}
>     module_output_spec: dict[str|int, QuantizationSpec|None] = {}
>     module_state_spec:  dict[str,     QuantizationSpec|None] = {}
>     qat_schedule: QATSchedule | None = None
> ```

| Field | Targets |
|---|---|
| `op_input_spec` | **input activations** to ops. `{"*": spec}` quantizes all supported inputs; `None` disables. |
| `op_output_spec` | **output activations** from ops. |
| `op_state_spec` | **weights and other `state_dict` tensors.** `{"weight": spec}` targets weights only — it excludes `bias`. |

The `op_*` versions apply to every op in the module *and recursively to its children*; the
`module_*` versions apply only at the module's own boundary and are **not** inherited by children.

> ✅ **VERIFIED** — `config/compression_config.py`, `_prepare_config_for_child`: *"Child modules
> inherit op-level settings recursively but **not** `module_*_spec`."*
>
> ✅ **VERIFIED** — and `global_config` may not contain them at all:
> `ValueError("global_config cannot have module_input_spec, module_output_spec, or
> module_state_spec. These are only allowed in module_type_configs and module_name_configs.")`

The defaults, when you omit a field:

> ✅ **VERIFIED** — `OpQuantizerConfig.get_default_*`:
> ```python
> op_input_spec  = {"*": default_activation_quantization_spec()}
> op_output_spec = {"*": default_activation_quantization_spec()}
> op_state_spec  = {"weight": default_weight_quantization_spec()}
> ```
> Hence: a bare `QuantizerConfig()` is **W_INT8(per-channel) A_INT8(per-tensor)**.

### 4.3 ⚠️ `None` is not the same as omitting the field

This is the mechanism behind the entire "exclude the detector from quantization" story, and it is
the rule people get wrong most often.

> ✅ **VERIFIED** — `config/compression_config.py`:
> - *"`None` in a dict value means **'disable compression for this scope'**"*; a `mode="after"`
>   validator normalises it into a real config object with empty specs (`_normalize_none_op_configs`,
>   `_normalize_none_module_configs`).
> - *"**Omitting** a field applies defaults; **explicitly passing `None`** converts to `{}` via
>   `BeforeValidator(_convert_none_to_empty_dict)`."*
>
> The source comment calls this distinction **load-bearing**, and it is.

Three configs that look similar and mean completely different things:

```python
from coreai_opt.quantization import ModuleQuantizerConfig, QuantizerConfig, QuantizationSpec
import torch

wspec = QuantizationSpec(dtype=torch.int8)

# (a) Quantize weights AND activations. Both activation specs defaulted in.
ModuleQuantizerConfig(op_state_spec={"weight": wspec})

# (b) Quantize weights ONLY. Activations explicitly disabled.
ModuleQuantizerConfig(op_state_spec={"weight": wspec},
                      op_input_spec=None, op_output_spec=None)

# (c) Quantize activations ONLY — weights are already compressed by something else.
ModuleQuantizerConfig(op_state_spec=None,
                      op_input_spec={"*": aspec}, op_output_spec={"*": aspec})
```

(a) is a trap. It is the single most common way to accidentally ship an activation-quantized model:
you wrote a weight spec, you thought you were doing weight-only quantization, and the framework
filled in `{"*": default_activation_quantization_spec()}` on both sides because you did not say
otherwise. The presets exist partly to stop you doing this.

(c) is the joint-compression pattern (§16.4) and the only place `op_state_spec=None` is correct.

At the outer level, `None` scopes off entire modules:

```python
# Skip everything under `detector`, whatever it contains.
config.module_name_configs = {"detector.*": None}

# Skip a module type wherever it appears.
config = QuantizerConfig(module_type_configs={"my_pkg.sam3.DetectorDecoder": None})
```

> ✅ **VERIFIED** — the `None`-disables semantics is stated in the `QuantizerConfig` docstring
> (quoted in §4.1) and implemented by `_normalize_none_module_configs`.
>
> 🟡 **RECONSTRUCTED** — the exact regex and type name in the SAM3 demo. Session 325 says only
> *"changing the quantization scheme to ignore the detector"*; no code was published. The
> *mechanism* is verified; the specific pattern string above is illustrative.

### 4.4 Everything is `@final` and everything is frozen

Two design decisions you will run into if you try to be clever:

> ✅ **VERIFIED** — `ModuleQuantizerConfig`, `QuantizerConfig`, `KMeansPalettizerConfig` and
> `ModuleKMeansPalettizerConfig` are all `@final` **and** define `__init_subclass__` raising
> `TypeError(f"{cls.__name__} cannot subclass … (marked final).")`. The stated reason: *"Prohibit
> subclassing due to preset limitation: presets remain bound to the base class."*
>
> ✅ **VERIFIED** — specs are pydantic models with `ConfigDict(frozen=True, extra="forbid")`.

So you cannot subclass a config, and you cannot mutate a spec. To vary a spec, copy it:

```python
base = QuantizationSpec(dtype=torch.int8, granularity=PerChannelGranularity(axis=0))
int4_variant = base.model_copy(update={"dtype": torch.int4})
```

`extra="forbid"` means a typo in a field name is a `ValidationError`, not a silently-ignored kwarg.
That is a genuinely good property and it is why hand-written specs are safer here than in most
frameworks.

### 4.5 Digit keys and module aliases — two conveniences that surprise people

> ✅ **VERIFIED** — `_convert_digit_str_keys_to_int`: digit-string dict keys are coerced to ints;
> collisions raise `ValueError("Key collision detected: keys 'x' and 'y' both convert to …")`. This
> exists so YAML (where keys are strings) can express integer op-input indices.
>
> ✅ **VERIFIED** — `_build_module_alias_map`: when the same module object is registered under two
> attribute paths — common with Hugging Face wrapper classes — canonical↔alias maps are built so a
> regex targeting an alias still applies under the canonical name.

The alias handling is genuinely helpful and genuinely invisible. If you are targeting a module by
name in a HF model and it seems to match "too much", the alias map is why.

---

## 5. Scoping: regex names, fully-qualified types, `only_for` and `without`

### 5.1 `module_name_configs` — regex, matched with `fullmatch`

> ✅ **VERIFIED** — `config/compression_config.py`: *"`module_name_configs` keys are matched with
> `re.fullmatch` (regex)."*

`re.fullmatch`, not `re.match` and not `re.search`. The pattern must cover the **entire** module
name. This trips up everybody once:

```python
# WRONG — matches nothing. "detector" is not the full name of any submodule.
config.module_name_configs = {"detector": None}

# RIGHT — the module itself
config.module_name_configs = {"detector": None, "detector\\..*": None}

# RIGHT — one pattern covering the module and its whole subtree
config.module_name_configs = {"detector(\\..*)?": None}
```

Module names are the dotted attribute paths you get from `model.named_modules()`. Print them before
you write a pattern:

```python
for name, mod in model.named_modules():
    if name:
        print(f"{name:60s} {type(mod).__module__}.{type(mod).__qualname__}")
```

That loop also gives you the strings you need for §5.2, which is the other half of the problem.

### 5.2 `module_type_configs` — **fully-qualified** class names only

> ✅ **VERIFIED** — `config/compression_config.py`: keys must be fully-qualified strings
> (`"torch.nn.modules.linear.Linear"`) or `nn.Module` subclasses. A string without a `.` raises
> `ValueError(f"Expected fully-qualified name, got {module_type}")`.
>
> ✅ **VERIFIED** — docs, verbatim: *"Keys must be the **fully-qualified Python class name** (e.g.
> `"torch.nn.modules.linear.Linear"`). **Short-form names like `"torch.nn.Linear"` are not
> supported** — the key must match the internal module path exactly."*

Note the failure mode: `"torch.nn.Linear"` **does** contain a dot, so it passes the syntactic check
and then matches nothing. You get no error and no compression change. This is a quiet one.

```python
import torch.nn as nn

# Safest: pass the class object. No spelling to get wrong.
config = QuantizerConfig(module_type_configs={nn.Linear: my_module_cfg})

# Equivalent, and what YAML has to use:
config = QuantizerConfig(
    module_type_configs={"torch.nn.modules.linear.Linear": my_module_cfg}
)

# Silently matches nothing:
config = QuantizerConfig(module_type_configs={"torch.nn.Linear": my_module_cfg})   # ⚠️
```

To get the right string for a class you already have:

```python
def fqn(cls: type) -> str:
    return f"{cls.__module__}.{cls.__qualname__}"

fqn(nn.Linear)        # 'torch.nn.modules.linear.Linear'
fqn(MyDetectorHead)   # 'my_pkg.sam3.MyDetectorHead'
```

This is exactly the mechanism Apple's own LLM export uses to keep specialised primitives out of the
quantizer:

> ✅ **VERIFIED** — `apple/coreai-models`, `export/presets.py` `_TORCH_MODULE_EXCLUSIONS`, each
> mapped to `None`:
> ```
> coreai_models.primitives.macos.sdpa.SDPA
> coreai_models.primitives.macos.rope.RoPE
> coreai_models.primitives.macos.rms_norm.RMSNorm
> coreai_models.primitives.macos.rms_norm.RMSNormPlusOne
> ```
> Source comment: these *"should not be quantized because they use specialized ops."*

Four fully-qualified names, four `None`s. That is the whole exclusion mechanism in Apple's shipping
LLM pipeline, and it is the same one §13 arrives at from a different direction.

### 5.3 The chainable helpers: `only_for` and `without`

Every setter returns `Self`, so configs compose.

> ✅ **VERIFIED** — `config/compression_config.py`:
> ```python
> config.set_global(cfg_or_None)
> config.set_module_type(nn.Linear | "torch.nn.modules.linear.Linear", cfg_or_None)
> config.set_module_name("model.lm_head", cfg_or_None)
> config.only_for(nn.Linear, nn.Conv2d)            # or only_for([nn.Linear, "lm_head"])
> config.without(nn.LayerNorm, nn.Embedding, "model.lm_head")
> config.set_execution_mode(ExecutionMode.EAGER)   # QuantizerConfig only
> ```

`without(...)` is the readable way to say "everything except these":

```python
config = QuantizerConfig.presets.w4().without(nn.LayerNorm, nn.Embedding, "model.lm_head")
```

`only_for(...)` is its inverse, and it has one sharp edge:

> ✅ **VERIFIED** — `only_for` disables `global_config` and deep-copies it onto each target. Calling
> it twice raises:
> `ValueError("only_for requires a non-disabled global_config to redistribute as per-module
> overrides. If you've already called only_for or set_global(None), pass all targets in one
> only_for(...) call instead of chaining.")`
>
> ✅ **VERIFIED** — doc caveat: the guard uses a **private attribute excluded from `model_dump` /
> `to_yaml`**, so a config that has been round-tripped through YAML **accepts `only_for` again**.

That second bullet is the interesting one. Serialise a config and reload it and the guard is gone —
so a YAML-driven pipeline can construct a state the Python API refuses to construct. Rule of thumb:
**call `only_for` exactly once, with all targets, on a config you built in this process.**

### 5.4 YAML, and why anchors are a first-class feature

> ✅ **VERIFIED** — loading:
> ```python
> config = QuantizerConfig.from_yaml("config.yaml")          # top-level key: quantization_config
> config = QuantizerConfig.from_dict({"quantization_config": {...}})
> config.to_dict()                                            # {"quantization_config": model_dump()}
> ```
> `from_yaml` uses `yaml.safe_load`. Empty YAML → `warnings.warn("Empty YAML content detected,
> returning None …")` and returns `None`; non-dict YAML → `ValueError`; unexpected top-level keys →
> `RuntimeError`. **Allowed top-level keys are only `_CONFIG_KEY` and `_SPEC_KEY`** — i.e.
> `quantization_config` plus `quantization_spec`, where the `*_spec` key exists *purely to host YAML
> anchors*.

That last design touch matters more than it sounds. Because specs repeat constantly across a config,
the schema reserves a whole top-level key so you can define them once as anchors:

> ✅ **VERIFIED** — `docs/src/quantization/config.md`, the `W_MXFP4_A_FP8` example, verbatim:
> ```yaml
> quantization_spec:
>   spec1: &fp8_activation
>     dtype: float8_e4m3fn
>   spec2: &mxfp4_weight
>     dtype: float4_e2m1fn_x2
>     granularity: { type: per_block, block_size: 32 }
>     scale_dtype: float8_e8m0fnu
> quantization_config:
>   global_config:
>     op_input_spec: { "*": *fp8_activation }
>     op_output_spec: { "*": *fp8_activation }
>     op_state_spec: { weight: *mxfp4_weight }
> ```
> and its Python equivalent:
> ```python
> fp8_activation = QuantizationSpec(dtype=torch.float8_e4m3fn)
> mxfp4_weight = QuantizationSpec(
>     dtype=torch.float4_e2m1fn_x2,
>     granularity=PerBlockGranularity(block_size=32),
>     scale_dtype=torch.float8_e8m0fnu,
> )
> config = QuantizerConfig(
>     global_config=ModuleQuantizerConfig(
>         op_input_spec={"*": fp8_activation},
>         op_output_spec={"*": fp8_activation},
>         op_state_spec={"weight": mxfp4_weight},
>     )
> )
> ```

YAML is not a second-class path here. Apple's own LLM export CLI takes a `--compression-config`
YAML file and validates it with exactly these entry points:

> ✅ **VERIFIED** — `apple/coreai-models`, `llm/export.py`: the YAML *"must be a mapping with
> **exactly one** coreai-opt top-level key"*; `quantization_config` ⇒ requires `--platform macOS`,
> validated with `QuantizerConfig.from_dict(...)`; `kmeans_palettization_config` ⇒ requires
> `--platform iOS`, parsed with `KMeansPalettizerConfig.from_dict(...)`. Mismatches raise
> `RuntimeError("macOS quantization preset provided, but platform is iOS.")` and the converse.

That is the "optimize differently for macOS versus iOS" claim from the keynote, made concrete: the
same tool, two YAML dialects, a hard guard between them. Apple's own defaults split the same way —
**macOS LLMs are quantized, iOS LLMs are palettized**:

> ✅ **VERIFIED** — `apple/coreai-models`, `export/presets.py`:
> ```python
> DEFAULT_MACOS_COMPRESSION_PRESET = "4bit"
> DEFAULT_IOS_COMPRESSION_PRESET   = "4bit_weight_palettized_group32"
> ```
> and the macOS `"4bit"` preset in full:
> ```python
> {"execution_mode": "eager",
>  "global_config": {"op_state_spec": {"weight": {"dtype": "int4",
>         "qscheme": "symmetric_with_clipping",
>         "granularity": {"type": "per_block", "block_size": 32, "axis": 1}}},
>    "op_input_spec": None, "op_output_spec": None},
>  "module_type_configs": _TORCH_MODULE_EXCLUSIONS}
> ```

Note what Apple's own shipping LLM preset is: **not** `presets.w4()`. It is int4
**`symmetric_with_clipping`**, **per-block 32 on axis 1**, in **eager** mode, with four module types
excluded. Every one of those four choices is a deviation from the preset, and §6 and §7 explain
each.

---

## 6. `QuantizationSpec`: every field

`QuantizationSpec` is the leaf of the whole config system — the thing that actually describes a
number format. Nine fields.

> ✅ **VERIFIED** — `src/coreai_opt/quantization/spec/spec.py:357-370`:
> ```python
> class QuantizationSpec(CompressionSpec):          # pydantic BaseModel, frozen=True, extra="forbid"
>     dtype: torch.dtype = torch.int8
>     qscheme: QuantizationScheme = QuantizationScheme.SYMMETRIC
>     qformulation: QuantizationFormulation = QuantizationFormulation.ZP
>     granularity: QuantizationGranularity = PerTensorGranularity()
>     fake_quantize_cls: type[FakeQuantizeImplBase] = "default"
>     qparam_calculator_cls: type[QParamsCalculatorBase] = "default"
>     range_calculator_cls: type[RangeCalculatorBase] = "minmax"
>     float_range: list[float | int | None] = [None, None]
>     scale_dtype: torch.dtype | None = None
> ```
> Computed (cached) fields: `n_bits`, `target_dtype`, `_quant_range`, `quant_min`, `quant_max`.

### 6.1 `dtype` — nine supported, and what they lower to

> ✅ **VERIFIED** — `spec.py:376-390`, `SUPPORTED_DTYPES`:
> ```
> torch.int8,  torch.int4,  torch.int2,
> torch.uint8, torch.uint4, torch.uint2,
> torch.float8_e4m3fn, torch.float8_e5m2,
> torch.float4_e2m1fn_x2
> ```
> String aliases (`spec.py:394-398`): `"float4_e2m1fn"` → `torch.float4_e2m1fn_x2`,
> `"float8_e4m3"` → `torch.float8_e4m3fn`, `"float8_e8m0"` → `torch.float8_e8m0fnu`. Any other string
> resolves via `getattr(torch, name)`.

Sub-byte types are stored in a wider container:

> ✅ **VERIFIED** — `get_target_dtype`, `spec.py:606-635`: sub-byte ints → `int8` / `uint8`;
> `float4_e2m1fn_x2` → `float8_e4m3fn`, with the stated reason *"All FP4 representable values are
> exactly representable in FP8."*

Quantization ranges, straight from the docstring:

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

### 6.2 `qscheme` — three cases, and where the third earns its keep

> ✅ **VERIFIED** — `spec/qscheme.py`:
> ```python
> class QuantizationScheme(Enum):
>     SYMMETRIC = "symmetric"
>     ASYMMETRIC = "asymmetric"
>     SYMMETRIC_WITH_CLIPPING = "symmetric_with_clipping"
> ```
> `_maybe_clip_bounds` sets `min_val = -max_val` **only** for `SYMMETRIC_WITH_CLIPPING` and **only**
> for signed dtypes.

`SYMMETRIC_WITH_CLIPPING` sacrifices the most-negative representable level (−128 → −127 at int8) to
make the grid exactly symmetric about zero. At 8 bits that is a 0.4% loss of range for a cleaner
scale. At 4 bits it is −8 → −7, a 12.5% loss — and it is nonetheless what Apple's own LLM preset
uses, which tells you the symmetry is worth more than the level at low bit-widths.

There is a community measurement of exactly this trade:

> 🟠 **COMMUNITY-MEASURED** — `john-rocky/coreai-model-zoo`, `knowledge/compression-reference.md`
> (single-author community material with self-declared uncontrolled benchmarks; hardware and OS not
> stated for this particular measurement): *"At int8 the gap [symmetric vs asymmetric] is small
> (~1.5 dB); at int4 asymmetric gains **+3–5 dB**, and `symmetric_with_clipping` can add **+7 dB**."*
>
> Treat the sign and rough magnitude as informative and the exact numbers as unreplicated. They are
> consistent with Apple's own choice of `symmetric_with_clipping` at int4, which is the strongest
> corroboration available.

Two validators constrain the FP dtypes:

> ✅ **VERIFIED** — FP dtype ⇒ `qscheme` **must** be `SYMMETRIC` (`validate_qscheme_for_fp_quant`),
> and FP dtype ⇒ `qformulation` **must** be `ZP` (`validate_qformulation_for_fp_quant`). Both raise
> `ValueError`.

### 6.3 `qformulation` — ZP vs MINVAL

> ✅ **VERIFIED** — `spec/qformulation.py`:
> ```python
> class QuantizationFormulation(_StrEnum):
>     MINVAL = auto()   # "minval"
>     ZP = auto()       # "zp"
> ```
> - **ZP**: `q = clamp(round(x/scale) + zero_point, qmin, qmax)`, `x' = (q - zero_point) * scale`
> - **MINVAL**: `q = clamp(round((x - minval)/scale) + quant_min, qmin, qmax)`,
>   `x' = (q - quant_min) * scale + minval`

The two are algebraically equivalent parameterisations of an affine grid; they differ in what gets
stored alongside the weights (a zero point, or a floating minimum). The constraint that matters:

> ✅ **VERIFIED** — `spec.py:174-179`, verbatim: *"CoreML export only supports `ZP`. Specs with
> `qformulation=MINVAL` are rejected during finalize with CoreML Export-backend. **CoreAI export
> supports both `ZP` and `MINVAL`.**"*

MINVAL is also **not allowed with FP4/FP8** (`spec.py:157-172`). Leave `qformulation` at its `ZP`
default unless you have a measured reason and a CoreAI-only target.

### 6.4 Scale and zero-point formulas

These are published in the class docstring, and they are worth having in front of you when a
compressed model behaves oddly — most "why is my scale like that" questions answer themselves here.

> ✅ **VERIFIED** — `spec.py:126-156`:
>
> | dtype | qscheme | quant range | scale | zero_point |
> |---|---|---|---|---|
> | INT8 | SYMMETRIC | [-128,127] | `max_abs / 127.5` | 0 |
> | INT8 | SYM_W_CLIP | [-127,127] | `max_abs / 127` | 0 |
> | INT8 | ASYMMETRIC | [-128,127] | `range / 255` | `clip(-128 - round(min_val_neg/scale), -128, 127)` |
> | UINT8 | SYMMETRIC | [0,255] | `max_abs / 127.5` | 128 |
> | UINT8 | SYM_W_CLIP | [0,255] | `max_abs / 127.5` | 128 |
> | UINT8 | ASYMMETRIC | [0,255] | `range / 255` | `clip(-round(min_val_neg/scale), 0, 255)` |
>
> FP dtypes: zero-point is always 0.
> - `scale_dtype=None` (FP8 only): `scale = max_abs / fp_max` — 448.0 for E4M3, 57344.0 for E5M2.
> - `scale_dtype=float8_e8m0fnu` (FP4 and FP8): power-of-two scales per the **OCP MX spec**,
>   `scale = 2^(floor(log2(max_abs)) - target_max_pow2)` with `target_max_pow2` =
>   **2 (FP4 E2M1), 8 (FP8 E4M3), 15 (FP8 E5M2)**.

And the `scale_dtype` field has exactly one legal non-`None` value, plus an auto-resolution rule:

> ✅ **VERIFIED** — `resolve_scale_dtype`, `spec.py:486-500`: `scale_dtype` may only be `None` or
> `torch.float8_e8m0fnu`; it **must** be `None` for integer dtypes; and **FP4 auto-resolves
> `scale_dtype=None` → `torch.float8_e8m0fnu`** in a `mode="before"` model validator.

So `QuantizationSpec(dtype=torch.float4_e2m1fn_x2)` is silently MXFP4 whether you asked for E8M0
scales or not. That is the correct behaviour — FP4 without a shared power-of-two exponent is not a
usable format — but it is a field that changes value between what you wrote and what you get, and
worth knowing.

### 6.5 The three pluggable classes, and the one that cannot be exported

`fake_quantize_cls`, `qparam_calculator_cls` and `range_calculator_cls` are registry keys, resolved
by string.

> ✅ **VERIFIED** — `spec/qparams_calculator.py`, the registered calculators:
>
> | Key | Class | Behaviour |
> |---|---|---|
> | `"default"` | `_DefaultQParamsCalculator` | A marker. Resolved by the factory: **weights/LUT → `StaticQParamsCalculator`, activations → `MovingAverageQParamsCalculator`**. Its `__init__` raises `RuntimeError` if ever constructed directly. |
> | `"static"` | `StaticQParamsCalculator` | min/max of the current tensor only, no history. |
> | `"moving_average"` | `MovingAverageQParamsCalculator` | EMA, `averaging_constant: float = 1e-2`. |
> | `"global_minmax"` | `GlobalMinMaxQParamsCalculator` | element-wise running min/max. |
> | `"dynamic"` | `DynamicQParamsCalculator` | recompute per forward; **activations only** — the factory raises `ValueError` for weight/LUT. |
>
> ✅ **VERIFIED** — only one range calculator is registered:
> `@RangeCalculatorBase.register("minmax") class MinMaxRangeCalculator`. Only one fake-quantize impl
> is registered: `@FakeQuantizeImplBase.register("default") class _DefaultFakeQuantizeImpl`.

⚠️ **The `"dynamic"` calculator cannot be exported.**

> ✅ **VERIFIED** — `_validate_no_persistent_observer_calculators` (`quantizer.py:410-433`) raises
> `NotImplementedError` at `finalize()` naming every affected FakeQuantize module and telling you to
> *"Use `backend=ExportBackend._TORCH` for torch-only inference."*
>
> ✅ **VERIFIED** — `StatelessQParamsCalculatorBase.set_export_mode(True)` raises
> `NotImplementedError("Stateless quantization (e.g. dynamic) does not support export mode; qparams
> are input-dependent and cannot be frozen for export.")`

Dynamic activation quantization is a PyTorch-evaluation feature in this package, not a deployment
feature. If you were planning to ship it, plan again.

The choice between `"moving_average"` and `"global_minmax"` for activations is a real accuracy
lever, and Apple publishes a measurement of it — see §18.1.

### 6.6 Writing your own calculator

The registries are public extension points and the docs ship a worked example.

> ✅ **VERIFIED** — `docs/src/quantization/advanced.md:312-341`, checked against `RunningRangeMixin`:
> ```python
> import torch
> from coreai_opt.quantization.spec import QParamsCalculatorBase, RunningRangeMixin
>
> @QParamsCalculatorBase.register("max_range")
> class MaxRangeQParamsCalculator(RunningRangeMixin, QParamsCalculatorBase):
>     """Track the widest observed min/max range across all calibration batches."""
>     def update_running_range(self, min_val: torch.Tensor, max_val: torch.Tensor):
>         return torch.minimum(self.running_min, min_val), torch.maximum(self.running_max, max_val)
>
> spec = QuantizationSpec(dtype=torch.int8, qparam_calculator_cls="max_range")
> ```
>
> ✅ **VERIFIED** — the MRO gotcha the source states explicitly: `RunningRangeMixin` *"must appear
> before `StatefulQParamsCalculatorBase` in the MRO so that its `compute_qparams` and
> `_initialize_state` take precedence."*

Two constraints on any calculator you write:

> ✅ **VERIFIED** — the `granularity` setter raises `RuntimeError("Cannot change granularity after
> observer has been initialized. Granularity must be set before the first forward pass.")`
>
> ✅ **VERIFIED** — `StatefulQParamsCalculatorBase` registers buffers `scale`, `zero_point` (int32;
> `None` for FP) and `minval` (`None` for FP). Buffer shapes are allocated on the first forward and
> **must stay stable** thereafter, because updates go through `copy_`. That shape-stability
> requirement is exactly why dynamic quantization needs a *stateless* base class.

---

## 7. Granularity, default axes, and the silent skip

Granularity decides **how many scales you store**, which is the actual size/quality dial. Bit-width
gets the headlines; granularity does most of the work.

### 7.1 Three classes

> ✅ **VERIFIED** — `spec/granularity.py`. Registry keys `"per_tensor"`, `"per_channel"`,
> `"per_block"` (these are the strings YAML uses in `granularity: {type: per_block, block_size: 32}`).
>
> - `PerTensorGranularity()` — `axis: Literal[None] = None`. One scale for the whole tensor.
> - `PerChannelGranularity(axis: int | None = None)` — negative axes allowed
>   (`-ndim <= axis < ndim`); `axis=None` is resolved at `prepare()` **for weights only**.
> - `PerBlockGranularity(axis: Annotated[int, ge=0, le=1] | None = None, block_size: int | tuple[int|-1, ...])`

`PerBlockGranularity` has two distinct modes and the validation differs between them:

> ✅ **VERIFIED** — same file:
> - **single-axis mode**: `axis ∈ {0, 1}` plus an int `block_size`. `axis=None` is allowed only for
>   weights (resolved at prepare); otherwise `_handle_single_axis_block_size` raises
>   `ValueError("axis must be specified when block_size is an int")`.
> - **multi-axis mode**: `axis` must be `None` and `block_size` a tuple with one entry per tensor
>   dimension; **`-1` means "no blocking on this axis"**.
>
> Worked table from the docstring:
>
> | weight shape | axis | block_size | resulting block shape |
> |---|---|---|---|
> | `[C_out, C_in]` | 1 | 32 | `[1, 32]` |
> | `[C_out, C_in]` | None | `(4, 8)` | `[4, 8]` |
> | `[C_out, C_in, KH, KW]` | 0 | 16 | `[16, 1, KH, KW]` |
> | `[C_out, C_in, KH, KW]` | None | `(4, 16, 3, -1)` | `[4, 16, 3, KW]` |

The multi-axis form exists for tensors the 2-D vocabulary cannot describe. Apple's own MoE override
is the canonical example:

> ✅ **VERIFIED** — `apple/coreai-models`, `export/presets.py`, `_TORCH_MOE_SWITCH_LINEAR_4BIT` for
> `coreai_models.primitives.macos.switch.SwitchLinear`:
> ```python
> {"module_state_spec": {"weight": {"dtype": "int4",
>     "qscheme": "symmetric_with_clipping",
>     "granularity": {"type": "per_block", "block_size": [1, 1, 1, 32], "axis": None}}},
>  "op_input_spec": None, "op_output_spec": None}
> ```
> Source comment: the expert weight is 4-D `[num_weight_sets, num_experts, output_dims, input_dims]`,
> which *"the global 2-D `per_block/32/axis=1` spec can't express."* Note it is harmless on non-MoE
> models — no `SwitchLinear` instances means no-op.

That is the pattern to copy whenever your model has one oddly-shaped weight: leave the global config
alone, add a `module_type_configs` entry with a multi-axis `block_size` for that one type.

### 7.2 The size arithmetic

Granularity is not free. Every block gets a scale (and, if asymmetric, a zero point), and at low
bit-widths that overhead becomes a meaningful fraction of the artefact.

> 🟠 **COMMUNITY-MEASURED** — `john-rocky/coreai-model-zoo`,
> `knowledge/compression-reference.md:72-79`, the sizing formula:
> ```
> weight/index bytes = numel * n_bits/8
> scale bytes        = n_groups * 2                # fp16
> zero_point bytes   = n_groups * n_bits/8         # asymmetric only
> lut bytes          = 2^n_bits * n_luts * 2       # palettization
> avg_bitwidth       = Σ(numel_i * bits_i) / Σ numel_i
> ```
> Community-authored, but it is straightforward arithmetic and it agrees with Apple's own numbers.

Apple's agent skill states the resulting overhead band directly:

> ✅ **VERIFIED** — `apple/coreai-models`,
> `skills/skills/model-compression-exploration/SKILL.md`: *"scale/ZP overhead **5–15%** at 2–4 bit
> fine granularity"*; and, sharply, *"at `block_size=16` + int4 the **effective width is ~5 bits**."*

Which is the single most useful sentence in that file. An "int4, block 16" config is not a 4-bit
model. If you are size-constrained and reaching for finer blocks to recover quality, plot *realised*
average bit-width, not nominal.

### 7.3 The default weight axis table

`axis=None` works because the framework has a per-module-type table.

> ✅ **VERIFIED** — `src/coreai_opt/quantization/_axis_defaults.py`:
> ```python
> _WEIGHT_AXIS_SPECS: dict[type[nn.Module], _WeightAxisSpec] = {
>     nn.Conv1d: _WeightAxisSpec(0, 1),
>     nn.Conv2d: _WeightAxisSpec(0, 1),
>     nn.Conv3d: _WeightAxisSpec(0, 1),
>     nn.ConvTranspose1d: _WeightAxisSpec(1, 0),
>     nn.ConvTranspose2d: _WeightAxisSpec(1, 0),
>     nn.ConvTranspose3d: _WeightAxisSpec(1, 0),
>     nn.Linear: _WeightAxisSpec(0, 1),
>     nn.Embedding: _WeightAxisSpec(0, 1),
> }   # (per_channel_axis, per_block_axis)
> ```
> Eight module types. Note `ConvTranspose*` is **transposed** relative to `Conv*` — that is not a
> typo, it is the weight layout.

> ✅ **VERIFIED** — the resulting scale shapes, `docs/src/quantization/config.md:72-88`:
>
> | | per-channel | per-block |
> |---|---|---|
> | `Conv*` | axis 0, scale `(C_out, 1, …, 1)` | axis 1, scale `(C_out, C_in/B, 1, …, 1)` |
> | `ConvTranspose*` | axis 1, scale `(1, C_out, 1, …, 1)` | axis 0, scale `(C_in/B, C_out, 1, …, 1)` |
> | `Linear` | axis 0, scale `(C_out, 1)` | axis 1, scale `(C_out, C_in/B)` |
> | `Embedding` | axis 0, scale `(V, 1)` | axis 1, scale `(V, D/B)` |

Graph mode reaches the table through the aten op rather than the module:

> ✅ **VERIFIED** — `_utils/torch_utils.py:38-47`, `ATEN_OP_TO_MODULE_TYPE`:
> `aten.conv1d.default→Conv1d`, `aten.conv2d.default→Conv2d`, `aten.conv3d.default→Conv3d`,
> `aten.conv_transpose1d.default→ConvTranspose1d`, `aten.conv_transpose2d.input→ConvTranspose2d`,
> `aten.conv_transpose3d.input→ConvTranspose3d`, `aten.linear.default→Linear`,
> `aten.embedding.default→Embedding`.

### 7.4 Three ways the axis default fails, and what each message means

> ✅ **VERIFIED** — all three, from `_axis_defaults.py` / `validate_activation_axes()`:
>
> 1. **Unresolvable weight axis** →
>    `ValueError: Weight fake-quantize modules with unresolved axis=None remain after applying
>    defaults: … Provide an explicit axis value in the granularity configuration (e.g.
>    PerChannelGranularity(axis=0)).`
> 2. **Shared weight whose consumers disagree** →
>    `ValueError: Conflicting default axes for shared weight fake-quantize modules: … All consumers
>    of a shared weight must resolve to the same default axis. Provide an explicit axis.`
> 3. **Activations get no axis defaults at all** →
>    `ValueError: Activation fake-quantize modules with unresolved axis=None: … Activation
>    quantization does not support axis=None. Provide an explicit axis value…`

Case 1 is what you hit with a **custom `nn.Linear` subclass in eager mode**, and it is deliberate:

> ✅ **VERIFIED** — coreai-opt PR #3, closed as intentional, @pkmandke (Apple, MEMBER): *"Applying
> the default axis for user-defined subclasses such as `class MyLinear(nn.Linear)` could be
> **misleading and is intentionally unsupported in eager mode**. Specifically because a custom
> subclass may use the weight in a way such that the default axis may no longer apply. Could you
> please try specifying an explicit axis for such custom modules using the config?"*
>
> The contributor's own summary, which is the clearest statement of the eager/graph difference
> anywhere: *"The graph path can default the axis because it resolves through the consuming op, but
> inferring one through an eager subclass is a guess the framework shouldn't make."*

Case 3 is the one that catches people moving from weight-only to activation quantization: **there is
no default activation axis, ever.** If you want per-channel activations you must write the axis
yourself — and then read §9.5, because it may be overridden anyway.

### 7.5 ⚠️ SILENT FAILURE — a block size your weight isn't divisible by leaves the layer uncompressed

This is the defining footgun of `coreai-opt` and it deserves its own callout.

> ⚠️ **SILENT FAILURE — mis-sized blocks disable quantization for that layer, with only a log line.**
>
> ✅ **VERIFIED** — `spec/fake_quantize.py:138-170` plus `_graph/quantizer.py:1004-1006,1307-1317`.
> When a tensor's shape is not divisible by the configured `block_size`, the granularity validator
> raises the *internal* `_BlockSizeMismatchError` (`spec/errors.py`). The fake-quantize forward
> **catches it**, calls `_warn_and_disable()`, and passes the tensor through untouched:
> ```python
> logger.warning(
>     "Tensor (target: %s) incompatible with block size configuration: %s. Skipping quantization.",
>     ...
> )
> ```
> Graph mode then runs `_remove_disabled_fake_quant_nodes(prepared_model)` after the init forward
> pass, so the fake-quant node is **deleted from the prepared graph entirely**. Palettization has the
> exact analogue, `_remove_disabled_fake_palett_modules`.
>
> **Net effect: a mis-sized block config silently leaves layers uncompressed.** `prepare()` returns
> successfully, `finalize()` succeeds, the export succeeds, and the model you ship has full-precision
> weights in the layers you thought you compressed. The only signals are a `logging.WARNING` you were
> probably not capturing and a file size that is larger than you predicted.

Both Apple and the community flag this independently, which is unusual and tells you how often it
bites:

> ✅ **VERIFIED** — `apple/coreai-models`,
> `skills/skills/model-compression-exploration/SKILL.md`: *"per-block/per-grouped-channel **silently
> skip** layers whose weight dim isn't divisible (pre-check with `check_divisibility()`)."*
>
> 🟠 **COMMUNITY-MEASURED** — `john-rocky/coreai-model-zoo`,
> `knowledge/compression-reference.md:65-69`: *"**Silent skips**: per-block quant /
> per-grouped-channel palettization silently skip layers whose dim isn't divisible by the
> block/group → those layers stay uncompressed. **Check divisibility before trusting a size.**"*

**Three defences, in order of how much you should trust them.**

**1. Turn the warning into an exception during development.** `logging` gives you this for free:

```python
import logging

class _RaiseOnCompressionSkip(logging.Handler):
    """Fail loudly on the block-size skip instead of logging it."""
    def emit(self, record: logging.LogRecord) -> None:
        msg = record.getMessage()
        if "Skipping quantization" in msg or "Skipping palettization" in msg:
            raise RuntimeError(f"coreai-opt silently skipped a layer: {msg}")

logging.getLogger("coreai_opt").addHandler(_RaiseOnCompressionSkip())
logging.getLogger("coreai_opt").setLevel(logging.WARNING)
```

> 🟡 **RECONSTRUCTED** — the logger *name* is inferred from the package name; the source uses a
> module-level `logger` obtained in the usual way but the exact logger string was not read. If the
> handler never fires, attach it to the **root** logger instead, which is guaranteed to see the
> record:
> ```python
> logging.getLogger().addHandler(_RaiseOnCompressionSkip())
> ```
> The message substrings (`"Skipping quantization"`, `"Skipping palettization"`) **are** verified,
> quoted from `fake_quantize.py` and the palettization analogue.

**2. Pre-check divisibility yourself**, before you ever call `prepare()`:

```python
import torch.nn as nn

def check_divisibility(model: nn.Module, block_size: int, axis: int) -> list[str]:
    """Return the names of weights that a per-block config would silently skip."""
    bad = []
    for name, mod in model.named_modules():
        w = getattr(mod, "weight", None)
        if w is None or not isinstance(w, torch.Tensor) or w.ndim <= axis:
            continue
        if w.shape[axis] % block_size:
            bad.append(f"{name}.weight  shape={tuple(w.shape)}  "
                       f"dim{axis}={w.shape[axis]} not divisible by {block_size}")
    return bad

for line in check_divisibility(model, block_size=32, axis=1):
    print("WILL BE SKIPPED:", line)
```

> 🟡 **RECONSTRUCTED** — `check_divisibility()` is named in Apple's compression-exploration skill
> and ships in `scripts/compression_metrics.py` in `apple/coreai-models`, but **its signature was not
> read**. The function above is an independent reimplementation of the stated behaviour, written from
> the documented rule (`shape[axis] % block_size`) and the verified per-module-type axis table in
> §7.3. Use Apple's if you have the repo; the semantics are the same.

**3. Assert on the size you expected.** Compute the theoretical compressed size from the formula in
§7.2 and compare it to the artefact. A layer that silently stayed fp32 shows up as a several-percent
size miss, and it is the only end-to-end check that catches *every* variant of this failure —
including the ones in §17 that have nothing to do with block sizes.

---

## 8. GRAPH vs EAGER: a structural split, not a flag

`execution_mode` looks like a boolean knob. It is not. The two modes are **separate
implementations** living in separate subpackages, with different tracing mechanisms, different
config vocabularies, different capability sets and different bugs.

> ✅ **VERIFIED** — the source tree, `find src -type d`:
> ```
> coreai_opt/quantization/{_graph, config, spec, _eager}
> ```
> `_graph/` is a PT2E/torchao implementation built on `torch.export`. `_eager/` is built on the
> `__torch_function__` protocol (`_utils/insertion/torch_function/*`: `handler.py`, `modes.py`,
> `module_boundary_tracker.py`, `state_spec_resolver.py`, `preregistration_tracker.py`,
> `registered_optimizers_tracker.py`).

### 8.1 The enum

> ✅ **VERIFIED** — `quantization_config.py:134-158`:
> ```python
> class ExecutionMode(_StrEnum, metaclass=_DeprecatedMemberEnumMeta):
>     GRAPH = auto()      # "graph"  — the default
>     EAGER = auto()      # "eager"
>     __deprecated_aliases__ = {"PT2E": "GRAPH"}
> ```
> `ExecutionMode.PT2E` is deprecated → `GRAPH`. Unknown modes raise
> `InvalidExecutionModeError("Unknown execution_mode {x}. Expected 'graph' or 'eager'.")`
> (added in PR #38).
>
> Docstrings, verbatim:
> - **GRAPH**: *"Graph-based quantization using `torch.export` to capture the model as an FX graph,
>   then applying quantization on top. Built on `torchao`'s PT2E implementation. **Requires the model
>   to be exportable via `torch.export.export`. Recommended default.**"*
> - **EAGER**: *"Eager-mode quantization that works directly on `nn.Module` without graph capture.
>   **Supports dynamic control flow (if/else, loops) and is the fallback when a model is not
>   exportable.**"*

### 8.2 The capability table

> ✅ **VERIFIED** — `docs/src/quantization/overview.md:215-223` plus the `Quantizer` class docstring:
>
> | Feature | GRAPH (default) | EAGER |
> |---|---|---|
> | Input → output | `nn.Module` → **`fx.GraphModule`** | `nn.Module` → `nn.Module` |
> | Dynamic control flow | limited to what `torch.export` supports | **supported** |
> | Conv+BN weight quantization | **BN folded into the preceding Conv weight first** | Conv weight unfused |
> | Consecutive fake-quant dedup | dedups (`out→fq→fq→inp` ⇒ `out→fq→inp`) | duplication persists |
> | Pattern fusion (Conv-BN-ReLU as one block) | **supported** | not supported |
> | Shared quantizer for value-preserving ops (maxpool / avgpool / flatten / concat) | **supported** | not supported |
> | Config op names | **aten op names** (`linear`, `linear_1`) | `__torch_function__` call sites (`linear1.linear`) |
> | `mmap_dir` in `finalize` | ✗ `ValueError` | **✓** (CoreAI only) |
> | Palettization / pruning | n/a | **the only supported mode** |
> | KV-cache quantization | **✓** | ✗ `ValueError` |
>
> And the shared-observer row spelled out, verbatim from `quantizer.py`:
> - GRAPH: *"ops like MaxPool that share the same observer across inputs and outputs are detected and
>   deduplicated on the graph"*
> - EAGER: *"Not supported; ops like MaxPool have independent observers for input vs output, **which
>   can cause incorrect quantization**"*

### 8.3 ⚠️ The two modes do not produce equivalent models

> ✅ **VERIFIED** — `quantizer.py:83-87`, verbatim: *"As a result of above mentioned differences, the
> total number of fake-quantize nodes inserted by graph and eager mode can differ for the same
> `QuantizerConfig`. This means the two modes are **not guaranteed to produce equivalent quantized
> models**, and final model performance (accuracy and latency) may differ between modes even when
> using identical configurations."*

Consequences for how you work:

- **Never compare a graph-mode result to an eager-mode result.** Pick a mode for a sweep and keep it
  (this is why Apple's own skill falls back to eager *for the whole sweep*, §3.4).
- **A config is not portable between modes**, because op names differ. `op_name_config` keyed on
  `"linear_1"` (graph) means nothing in eager, and `"linear1.linear"` (eager) means nothing in graph.
- **Inspect in the mode you will compress in.** `ModelInspector` takes an `execution_mode` for
  exactly this reason:
  > ✅ **VERIFIED** — `docs/src/debugging/model_inspection.md`: graph-mode op names are global
  > (`linear`, `linear_1`); eager op names are module-qualified (`linear1.linear`). **"Use the mode
  > you plan to compress with."**

### 8.4 Which mode, actually

Reconciling the transcript ("EAGER works great for weight compression") with the repo ("GRAPH is the
recommended default") gives a clean decision rule:

| Situation | Mode | Why |
|---|---|---|
| **Weight-only, model exports cleanly** | GRAPH | The default; nothing lost. Fusion and dedup are irrelevant when no activations are quantized, so the two modes converge numerically. |
| **Weight-only, model is awkward to export** | **EAGER** | No `torch.export` requirement. This is the SAM3 case, and Apple's own LLM preset case. |
| **Weight + activation** | **GRAPH, strongly** | Fusion, FQ dedup, shared-observer handling and the known-range overrides (§9.5) all live in `_graph/`. The docs say eager *"may yield models with sub-optimal runtime performance"*, and the source says shared observers in eager *"can cause incorrect quantization"*. |
| **Palettization or pruning** | **EAGER** | It is the only mode that exists. |
| **You need `mmap_dir`** | **EAGER** | Graph mode raises. |
| **You need KV-cache quantization** | **GRAPH** | Eager raises. |
| **Model has data-dependent control flow** | **EAGER** | `torch.export` cannot capture it. |
| **You need to feed an `nn.Module` (not an `ExportedProgram`) to `coreai-torch`** | **EAGER** | See below. |

That last row is a real and non-obvious reason, and it comes from the integration doc rather than
the quantization doc:

> ✅ **VERIFIED** — `docs/src/introduction/integration_coreai.md`: use eager *"When
> `torch.nn.Module` needs to be provided as an input, instead of `ExportedProgram`, to the conversion
> API of `coreai-torch`. This happens when the `coreai-torch` conversion needs to **'externalize'
> certain sub-modules** to map them to *composite ops* for better runtime performance."*

Externalization is how large embedding tables and similar sub-modules get lifted out of the graph
(Part 8 covers it). If your conversion needs it, your compression has to be eager. There is no
workaround.

### 8.5 Graph-mode `prepare()`, step by step

Worth reading once, because several of the guide's other sections are explained by the ordering here.

> ✅ **VERIFIED** — `_graph/quantizer.py:878-1021`:
> 1. Reject re-prepare; assert `example_inputs` is a non-empty tuple.
> 2. Record `original_train_mode` — *"After export, `GraphModule.training` is always True."*
> 3. Build `module_config_dict`, `module_name_to_state_names_map`, alias map; build an
>    `_AnnotationHandler` (a subclass of torchao's `pt2e.quantizer.Quantizer`).
> 4. Collect `preserved_attributes` (missing ones → warning + skip).
> 5. `export_model(...)` → `torch.export.export`.
> 6. `_validate_kv_cache_quant_ops(exported_model)`.
> 7. If `torchao < 0.16.0`: `strip_non_aten_metadata_kwargs(graph)`, because *"torchao < 0.16.0
>    asserts that annotated nodes have empty kwargs"*; restored afterwards with `restore_kwargs`.
> 8. `prepare_qat_pt2e(exported_model, quantizer)` — wrapped so any exception is re-raised as
>    `type(e)(f"prepare_qat_pt2e call failed, with error: {e}")`.
> 9. `_postprocess_prepared_model()` = `remove_conv_bn_zeros_like_dtype` →
>    `force_per_tensor_for_channel_altering_ops` → `apply_weight_axis_defaults_graph` →
>    `validate_activation_axes`.
> 10. `allow_exported_model_train_eval(prepared_model)`.
> 11. `apply(disable_fake_quant)`, `apply(enable_observer)`, **one `torch.no_grad()` forward in eval
>     mode** to initialise qparams.
> 12. `_remove_disabled_fake_quant_nodes`.
> 13. `apply(enable_fake_quant)`, `apply(disable_observer)` → **the prepared state is: fake quant ON,
>     observers OFF.**
> 14. Mark prepared, re-attach preserved attributes.

Three things fall out of that list.

**Step 11 is where `example_inputs` becomes load-bearing.** A single forward pass, in eval mode, with
observers on, seeds every qparam in the model. If those inputs are noise, that is your starting
point.

**Step 13 is why a freshly prepared model does not learn.** Observers are *off* after `prepare()`.
Nothing further refines the qparams unless you enter `calibration_mode()` or `training_mode()`. If
you prepare, run 10,000 samples through the model, and finalize, you have exactly the qparams from
step 11 — the 10,000 samples changed nothing.

**Step 12 is the silent-skip deletion from §7.5**, and note that it runs *after* the init forward —
which is the only way the framework could know the shapes did not divide.

`finalize()` is the mirror image:

> ✅ **VERIFIED** — `_graph/quantizer.py`:
> 1. `convert_pt2e(model)` (failure → `RuntimeError("Failed to convert model with convert_pt2e, with
>    error: …")`).
> 2. `_post_conversion_process` → `fold_conv_bn_weights`.
> 3. Backend switch: `_TORCH` no-op · `CoreML` raises `NotImplementedError` if
>    `kv_cache_quant_configs` is set, else `prepare_for_mil_export` · `CoreAI` `prepare_for_mlir_export`
>    then `_move_cache_dequant_to_output` per configured cache op.
> 4. `allow_exported_model_train_eval(finalized_model)` again — *"`convert_pt2e()` re-applies
>    `_disallow_eval_train`."*

And what CoreAI export actually emits:

> ✅ **VERIFIED** — `_graph/_prepare_for_export.py:403-430`:
> ```python
> # coreai.quantize(input, scale, output_dtype, zero_point=, minval=, axis=)
> # coreai.dequantize(input, scale, zero_point=, minval=, axis=, input_dtype=, output_dtype=)
> ```
> `input_dtype` is passed for integer dtypes because it is *"needed for determining n_bits for
> subbyte (e.g. int4) quantization and for deriving q_min in the MINVAL formulation"*. `output_dtype`
> is set explicitly when `scale_dtype == torch.float8_e8m0fnu`. `coreai_torch` is **lazy-imported**
> (`lazy_import_coreai_torch`) so the package works without it installed.

⚠️ These two ops have had an axis bug that is worth knowing about even though it is fixed:

> ⚠️ **SILENT FAILURE (fixed 2026-07-08, `coreai-torch` PR #24)** — `coreai::quantize` /
> `coreai::dequantize` normalised a negative axis as **`axis + rank - 1`**, off by one from the eager
> op which uses **`axis + rank`**. A per-channel `axis=-1` therefore landed one dimension early —
> *"when the channel and its neighbour share a size there is **no shape error**; the model silently
> picks the wrong channel."* File: `coreai_torch/_custom_to_core.py`.
>
> **Safe default regardless of version:** write **non-negative axes** in your specs. `axis=0` and
> `axis=1` are the only values the default table ever produces (§7.3), and they are immune to this
> whole class of bug.

### 8.6 Graph mode rejects some config shapes outright

> ✅ **VERIFIED** — `_validate_config`, `_graph/quantizer.py:679-731`:
> - String keys other than `"*"` in any op/module input or output spec →
>   `NotImplementedError("Only integer indices or '*' are supported for op and module input and
>   output specs currently…")`
> - `op_output_spec` keys other than `"*"` or `0` →
>   `NotImplementedError("op_output_qspec currently supports setting for '*' or 0 tensor only…")`

So in graph mode, activation specs are keyed by `"*"` or by integer position. Named-input specs are
an eager-mode-only expressiveness.

### 8.7 How graph mode decides what to annotate

Graph mode matches **patterns**, not modules. The registry is public enough to extend.

> ✅ **VERIFIED** — `_graph/_annotation_pattern_registry.py`, the registered keys:
> ```
> conv_bn_act, conv_transpose_bn_act, conv_act, conv_transpose_act, conv_bn, conv_transpose_bn,
> conv, conv_transpose, linear_bn_act, linear_act, linear_bn, linear, embedding,
> matmul, matmul_act, add, add_act, mul, mul_act, sub, flatten, maxpool, avgpool, concat
> ```
> Three base classes:
> - **`WeightedModulePattern`** — the conv / linear / embedding families.
> - **`NAryActPattern`** — elementwise and matmul families; `use_act=True` expands to every supported
>   activation appended to the base op. ⚠️ *"chains longer than 2 are not supported"* — the
>   annotation function raises — and *"sequential partition matching requires each op type in the
>   chain to be unique (e.g. `mul -> sub` works but `mul -> mul -> sub` does not)."*
> - **`SharedObserverModulePattern`** — `flatten`; `maxpool` (`max_pool1d/2d/3d`); `avgpool`
>   (`avg_pool1d/2d/3d`, `adaptive_avg_pool1d/2d/3d`, `mean`); `concat` (`cat`, `concat`). **Input and
>   output share the same `FakeQuantize` object.** That sharing is the subject of §9.6.
>
> ✅ **VERIFIED** — registering with an existing key overwrites **with a warning**, and there is
> **no `unregister`** — you delete from `_AnnotationPatternRegistry.REGISTRY["key"]` directly.

Annotation order is deterministic and documented, which matters when two configs could both claim a
node:

> ✅ **VERIFIED** — `_sort_nodes_in_annotation_order`, priority decreasing:
> 1. config level (`module_name` > `module_type` > `global`)
> 2. pattern length (longer pattern wins)
> 3. config index within a level (**later-listed config wins** → smaller index)
> 4. topological order in the graph

And there is a public helper to find out what a config *will* touch, before it touches it:

> ✅ **VERIFIED** — `GraphQuantizer.get_compressible_op_names(model) -> set[str]`, a public
> classmethod returning every node name that any registered annotation pattern matches.

Adding your own pattern is a documented three-liner:

> ✅ **VERIFIED** — `docs/src/quantization/advanced.md:202-217`, verbatim:
> ```python
> from coreai_opt.quantization._graph._annotation_pattern_registry import (
>     NAryActPattern, _AnnotationPatternRegistry, _get_all_patterns_from_base_ops,
> )
>
> @_AnnotationPatternRegistry.register("div_act")
> class DivActPattern(NAryActPattern):
>     @classmethod
>     def generate_patterns(cls):
>         return _get_all_patterns_from_base_ops({torch.div, operator.truediv}, use_act=True)
> ```
> Note the leading underscores: this is a documented use of private module paths. Apple's docs ship it
> anyway, so it is sanctioned — but it is explicitly not covered by the `__all__` API-visibility
> tests, and it can move between releases.

### 8.8 Eager mode's supported ops

Eager mode's registry is much smaller, and knowing its contents saves a lot of confusion about why
some op was left alone.

> ✅ **VERIFIED** — `_eager/supported_ops_registry.py` keys:
> ```
> conv1d, conv2d, conv3d, conv_transpose1d, conv_transpose2d, conv_transpose3d,
> linear, embedding, max_pool2d, adaptive_avg_pool2d, add, matmul, mul, sub
> ```

Fourteen entries versus graph mode's twenty-four patterns, with no fused forms at all. Everything
else in your model is, by construction, left in floating point in eager mode.

---

## 9. Activation quantization: observers, calibration, shared observers

Weight quantization is a pure function of the weights. Activation quantization is a function of your
**data**, and that difference produces every complication in this section.

### 9.1 The two default specs

> ✅ **VERIFIED** — `spec.py:716-735`, both factory functions in full:
> ```python
> def default_weight_quantization_spec() -> QuantizationSpec:
>     return QuantizationSpec(dtype=torch.int8, qscheme="symmetric",
>                             granularity=PerChannelGranularity(axis=0),
>                             fake_quantize_cls="default", qparam_calculator_cls="static",
>                             range_calculator_cls="minmax")
>
> def default_activation_quantization_spec() -> QuantizationSpec:
>     return QuantizationSpec(dtype=torch.int8, qscheme="symmetric",
>                             granularity=PerTensorGranularity(),
>                             fake_quantize_cls="default", qparam_calculator_cls="moving_average",
>                             range_calculator_cls="minmax")
> ```

Three deliberate differences: weights are **per-channel**, activations are **per-tensor**; weights
use **`static`** (this tensor, right now), activations use **`moving_average`** (an EMA across
batches); and the weight default has an axis while the activation default cannot have one (§7.4).

### 9.2 What `calibration_mode()` actually toggles

This is not what most people assume, and the reason is good.

> ✅ **VERIFIED** — `_graph/quantizer.py:1160-1173`, the whole body:
> ```python
> self._model.apply(enable_observer)
> self._model.apply(enable_weight_fake_quant)       # weight FQ stays ON
> self._model.apply(disable_activation_fake_quant)  # activation FQ OFF
> with move_model_to_eval(self._model): yield
> # finally:
> self._model.apply(disable_observer)
> self._model.apply(enable_fake_quant)
> ```

Inside `calibration_mode()`: **observers on, weight fake-quant on, activation fake-quant off.**

> ✅ **VERIFIED** — the rationale, `docs/src/quantization/overview.md:113-117`: activation observers
> must see **undistorted** activations — but produced with **quantized weights** upstream, *"matching
> what the deployed model will actually see."*

Both halves matter. Leaving activation fake-quant on during calibration would mean each observer
sees activations already rounded by the previous layer's (not yet converged) qparams — a feedback
loop. Turning weight fake-quant *off* would mean the observers calibrate against a model that will
never exist.

That second half is recent:

> ✅ **VERIFIED** — coreai-opt PR #25, merged: *"`Quantizer.calibration_mode()` previously disabled
> fake quant on **both** weights and activations; now only activations, 'so activation observers see
> the effect of quantized weights when computing activation ranges.'"* New helpers
> `enable_weight_fake_quant` / `disable_activation_fake_quant` in `_fake_quant_utils.py`. Commit
> `519f21c`.

If you are reading numbers produced before that commit, they are from a different algorithm.

### 9.3 The calibration loop

```python
import torch
from coreai_opt.quantization import Quantizer, QuantizerConfig

config = QuantizerConfig()                                   # W_INT8 A_INT8, graph mode
quantizer = Quantizer(model, config)

prepared_model = quantizer.prepare((example_input,))         # representative! see §2.2

with quantizer.calibration_mode():
    for batch in calibration_loader:                         # ~128 samples is Apple's guidance
        prepared_model(batch)                                # forward only — no loss, no backward

quantized_model = quantizer.finalize()                       # backend=CoreAI
quantized_model.eval()
```

> ✅ **VERIFIED** — this is the `Quantizer` class docstring's own PTQ example, restructured only for
> commentary.

No gradients, no optimizer, no targets. Calibration is *observation*. The only thing the loop does
is push tensors through so the observers see them.

**How much data?** Apple says ~128 samples (§1.2). Their published ResNet-50 numbers used 896
(§18.1) and their MNIST joint-compression test uses 17 batches of 128 = 2,176. The honest reading is
that 128 is a floor that usually works, more helps a little, and the *distribution* matters far more
than the count.

### 9.4 Prepared vs finalized are not bit-identical

> ✅ **VERIFIED** — `docs/src/quantization/overview.md:123-125`: *"For models with a **Conv +
> BatchNorm** pattern in the default graph execution mode, [prepared vs finalized] can differ slightly
> more: BatchNorm folding is handled with ops that are different between the prepared and finalized
> models (though algebraically equivalent). **Weight quantization is matched closely … but activation
> quantization can still show a small numerical divergence.**"*

So the score you get from `prepared_model` is a very good estimate and not a guarantee. For a sweep
that is exactly the right trade (§2.5). For a final acceptance gate, score the finalized model — and
ideally the converted `.aimodel`, since conversion is another lossy-in-practice step (Part 8).

The one case where they *must* match:

> ✅ **VERIFIED** — `tests/test_joint_compression.py` asserts `post_calib_acc == finalized_acc` for
> `ExportBackend._TORCH`. Finalize must be numerically exact for the torch backend.

### 9.5 The six ops whose qscheme the framework overrides

Graph mode knows the analytic output range of several activation functions and **overrides your
config** for them. This is correct behaviour and it is invisible unless you read the docs.

> ✅ **VERIFIED** — `docs/src/quantization/advanced.md:167-192`. At prepare time the quantizer
> overrides the user's `qscheme` and `float_range` for ops with analytically known output ranges.
> **The dtype is always preserved.**
>
> | Op | Output range | qscheme | float_range | Scale (int8) | Zero point (int8) |
> |---|---|---|---|---|---|
> | `hardsigmoid` | [0,1] | asymmetric | (0,1) | 1/255 | −128 |
> | `hardtanh` | from node args | depends | depends | depends | depends |
> | `relu` | [0,∞) | asymmetric | (0, None) | dynamic | −128 |
> | `relu6` | [0,6] | asymmetric | (0,6) | 6/255 | −128 |
> | `sigmoid` | [0,1] | asymmetric | (0,1) | 1/255 | −128 |
> | `tanh` | [−1,1] | symmetric | (−1,1) | 2/255 | 0 |
>
> `hardtanh` reads its bounds from the node args and is symmetric iff `min_val == -max_val`; `relu6`
> is handled as `hardtanh(0,6)`. Implemented by `adjust_output_qspec_for_qscheme_and_propagate`
> (`_graph/_annotation_utils.py`).
>
> ⚠️ **Eager mode does not perform these adjustments.**

That last line is one of the concrete reasons "eager is fine for activations" is wrong. In eager
mode a `sigmoid` output gets a symmetric int8 grid spanning `[-max, max]` when the tensor can only
occupy `[0, 1]` — you throw away a bit for nothing.

This machinery was broken until recently, which is a useful calibration on how new all of this is:

> ✅ **VERIFIED** — coreai-opt PR #22 / commit `0eabc57`, merged: *"relu/relu6/sigmoid/tanh etc. —
> 'Qscheme was not being set correctly, and **no fixed ranges were ever in place**.'"* The fix removed
> fake-quantize's independent `qscheme` attribute in favour of `qparams_calculator.qscheme`. The
> project's own **MNIST test accuracy expectation moved from <88% to <94%** as a direct result.

A six-point accuracy swing on MNIST from one qscheme fix. If you have int8 activation numbers from
before `0eabc57`, re-measure them.

There is a larger rewrite of this area in flight:

> ✅ **VERIFIED** — coreai-opt PR #40, **OPEN**, +2326/−523: a full rewrite of graph-mode annotation
> as a constraint-queue reconciler. Motivating bug: a **YOLO** subgraph
> `concat(conv(...), sigmoid(...), sigmoid(...))` — sigmoid has a fixed (0,1) qspec and conv a
> floating one, and the old order-dependent propagation **crashed**. The new model builds a
> `NodeSlot → ProvisionalQSpec` map and processes a constraint queue that can relax
> (sigmoid (0,1) + hardtanh → (−1,1)), force a winning field by priority, merge into a shared qspec,
> or error.
>
> Practical reading: **if your model concatenates a fixed-range activation with a floating-range one,
> graph-mode annotation is a known-sharp area as of 2026-07.** Test it, and if it crashes, that is a
> known bug and not your config.

### 9.6 ⚠️ Shared observers and the per-channel activation constraint

This is the newest correctness rule in the package — merged **2026-07-24**, three days before this
guide's evidence cut-off, and **not in release 0.2.1**.

The setup: `SharedObserverModulePattern` ops (maxpool, avgpool, flatten, concat) tie their input and
output to the **same `FakeQuantize` object** (§8.7). One observer, one scale, two tensors. If those
two tensors do not agree about what the quantization axis *means*, a per-channel scale is applied to
the wrong data.

> ✅ **VERIFIED** — `main` @ `cd95cb2` (PR #52), `src/coreai_opt/quantization/_graph/_utils.py`. Three
> op sets:
> ```python
> _AXIS_RESIZING_ATEN_OPS = {
>     aten.max_pool1d.default, aten.max_pool2d.default, aten.max_pool3d.default,
>     aten.avg_pool1d.default, aten.avg_pool2d.default, aten.avg_pool3d.default,
>     aten.adaptive_avg_pool1d.default, aten.adaptive_avg_pool2d.default,
>     aten.adaptive_avg_pool3d.default,
>     aten.mean.dim,
> }
> _AXIS_REORDERING_ATEN_OPS = {aten.transpose.int, aten.t.default, aten.permute.default}
> _CHANNEL_ALTERING_ATEN_OPS = (
>     _AXIS_RESIZING_ATEN_OPS | _AXIS_REORDERING_ATEN_OPS
>     | {aten.flatten.using_ints, aten.reshape.default, aten.view.default, aten.unsqueeze.default}
> )
> ```
> `force_per_tensor_for_channel_altering_ops(model)` runs **after** `prepare_qat_pt2e` (step 9 of
> §8.5). For every channel-altering node it finds the FQ modules on inputs and users; if the **same
> object** appears on both sides, it calls `_shared_granularity_axis_is_safe(...)` and downgrades to
> `PerTensorGranularity()` when the answer is no.
>
> The decision tree — **fail-safe: unproven ⇒ unsafe**:
> - `PerTensorGranularity` → safe.
> - **not `PerChannelGranularity`** (e.g. `PerBlockGranularity`) → **unsafe, unconditional downgrade**.
> - rank changed between input and output → unsafe.
> - unresolved axis → unsafe.
> - op in `_AXIS_RESIZING_ATEN_OPS` → safe **iff** `input_shape[axis] == output_shape[axis]`.
> - op in `_AXIS_REORDERING_ATEN_OPS` → safe **iff** `_op_preserves_axis_identity(op_node, axis)`:
>   - `transpose.int` → `axis not in (dim0, dim1)` (negatives normalised with ndim)
>   - `t.default` → `axis not in (0, 1)`
>   - `permute.default` → `dims[axis] == axis`
>   - fallback → `False`
> - flatten / reshape / view / unsqueeze, or an unknown op → unsafe.

What it replaced, and what the bug was:

> ✅ **VERIFIED** — changelog fragment `changelog.d/52.fixed`: *"Fix per-channel activation
> quantization crashing with a shape-mismatch `RuntimeError` on MaxPool/AvgPool/AdaptiveAvgPool layers
> whose shared observer spans an axis the pool shrinks (e.g. a spatial axis under a stride>1 pool).
> Axes pooling never touches (batch, channel) keep working as per-channel; **only the specific unsafe
> axis falls back to per-tensor**…"*
>
> Before #52, the code **always** forced per-tensor for channel-altering ops. So the change is in both
> directions: some configs that used to be silently downgraded now stay per-channel, and some that
> used to crash now downgrade gracefully.

The subtlest part of the commit is worth quoting, because it explains why a size check is not enough:

> ✅ **VERIFIED** — PR #52 commit message: **concat pulls transpose/permute into shared-observer
> territory** — *"concat (a `SharedObserverModulePattern`, like MaxPool) ties both of its inputs to
> the same observer object, so a transpose/permute branch feeding concat alongside its own
> untransposed source gets its input and output tied together the same way MaxPool's are."* And the
> punchline: a `transpose(2,3)` **on a square tensor passes a size-only check but silently applies
> row-3's scale to column-3's data** — which is why `_op_preserves_axis_identity` exists.

The downgrade is now logged, and the message tells you what to do:

> ✅ **VERIFIED** — `_graph/_utils.py`, verbatim:
> ```
> "Forcing per-tensor granularity for the shared observer around '%s' (was %s): this op either
>  changes the size of the quantization axis between its input and output, or moves it to a different
>  physical dimension (e.g. via transpose/permute), so a per-channel scale can't safely apply to both
>  sides. To keep per-channel activation quantization here, choose a different axis that this op
>  leaves untouched."
> ```

**What this means for you, practically:**

- **Per-channel activation quantization has correctness constraints**, and the framework enforces
  them by silently reducing your granularity. Your model stays correct; your compression ratio and
  your accuracy both move. Watch for that warning.
- **Per-block activation granularity around a shared observer is *always* downgraded** — the check
  is per-channel-only. If you configured per-block activations and got per-tensor behaviour, this is
  why.
- **On 0.2.1** (the current release at the time of writing) the old behaviour applies: channel-altering
  ops **always** force per-tensor. Do not expect the shape-aware logic until the next release.
- **Batch and channel axes on pooling ops are the safe ones.** They are exactly the axes pools never
  touch, which is the practical version of the whole decision tree.

There is one more open item in this area:

> ✅ **VERIFIED** — coreai-opt PR **#56**, **OPEN**: *"Enable **block activation quantization**
> support (limited to pre-finalize stages)."* Files: `_eager/_prepare_for_export.py`,
> `_graph/_prepare_for_export.py`, `spec/granularity.py`.
>
> 🔴 **GAP — block-granularity activation quantization is not shippable today.** "Limited to
> pre-finalize stages" means you can simulate it in PyTorch but not export it. What would resolve
> this: PR #56 merging and appearing in a release. **Safe default meanwhile:** per-tensor activations,
> which is the documented default and the only granularity CoreML accepts anyway (§16.2).

### 9.7 The fake-quantize forward, and where the gradient comes from

For QAT (§11) you need to know how the gradient flows. The implementation is a fused straight-through
estimator.

> ✅ **VERIFIED** — `spec/fake_quantize.py:138-170`, the forward logic:
> 1. If `self._disabled` → passthrough.
> 2. If `observer_enabled[0] == 1` → run `qparams_calculator(tensor)` under `torch.no_grad()`
>    (*"Gradients should be computed through the actual QDQ path only"*); a `_BlockSizeMismatchError`
>    here triggers `_warn_and_disable()` and passthrough (§7.5).
> 3. Else → `qparams_calculator.get_qparams()`.
> 4. If `fake_quant_enabled[0] == 1` → cast to fp32, run `_fused_fake_quant_dequant`, cast back.
>
> ✅ **VERIFIED** — the math kernels, module-level:
> ```python
> def _quantize_int(tensor, scale, quant_offset, float_offset, quant_min, quant_max):
>     result = (tensor - float_offset) / scale
>     result.round_(); result.add_(quant_offset)
>     mask = (result >= quant_min) & (result <= quant_max)
>     result.clamp_(quant_min, quant_max)
>     return result, mask
>
> def _dequantize_int(tensor, scale, quant_offset, float_offset):
>     return (tensor - quant_offset) * scale + float_offset
> ```
> Offset selection (`_select_int_offsets`): **ZP → `(zero_point, 0)`; MINVAL → `(quant_min, minval)`**.
> The FP path is `_quantize_float` = `clamp(tensor/scale, qmin, qmax)` then a cast-decast round trip:
> FP8 via `.to(dtype).to(torch.float32)`, FP4 via
> `torchao.prototype.mx_formats.kernels.f32_to_f4_unpacked` / `f4_unpacked_to_f32`.
>
> ✅ **VERIFIED** — STE autograd: `_FusedFakeQuantizeIntSTE` / `_FusedFakeQuantizeFloatSTE`, both
> `torch.autograd.Function`. **Backward = `grad_output * mask`** — clamped positions get zero
> gradient. Documented rationale: *"Fusing into one node reduces QAT memory: intermediate tensors
> (scaled, rounded, clamped) are local to forward and freed immediately instead of being retained by
> the autograd graph. Only a boolean mask (1 byte/element) is saved for backward, replacing multiple
> float32 intermediates (4 bytes/element each)."*

Two behavioural consequences worth holding onto for §11: **weights that saturate the quantization
range receive no gradient**, and **the qparams themselves are not learned** — they are observed under
`no_grad`. This is observer-based QAT, not learned-step-size QAT.

One more override that catches people writing custom fake-quantize classes:

> ✅ **VERIFIED** — `_DefaultFakeQuantizeImpl.convert(self, model, observer_node)` is a **deliberate
> no-op**: *"keep fake quant nodes intact during `convert_pt2e`. If this method is not present,
> torchao's convert method will try to replace fake quant nodes with its standard quantize/dequantize
> ops and fails in the process."*
>
> ✅ **VERIFIED** — and `disable_observer()` is a **no-op for stateless calculators**, *"applies to
> **any** caller (direct, `apply(disable_observer)`, `convert_pt2e`, QAT scheduling)"*.

---

## 10. PTQ: data-free and calibration-based

### 10.1 Data-free weight-only PTQ is the default and the right starting point

Everything happens inside `prepare()`:

> ✅ **VERIFIED** — `prepare()` *"compresses weights + inserts fake-quantize / fake-palettize / mask
> ops; a forward on the result reflects compression. **Data-free PTQ happens here.**"*

```python
import copy, torch
from coreai_opt.quantization import Quantizer, QuantizerConfig

float_model = copy.deepcopy(model).eval()
example_inputs = (torch.randn(1, 3, 224, 224),)     # shapes only; values irrelevant here

quantizer = Quantizer(model, QuantizerConfig.presets.w8())
prepared = quantizer.prepare(example_inputs)
prepared.eval()

# Score it in PyTorch before deciding anything.
score_float = evaluate(float_model, val_loader)
score_w8    = evaluate(prepared,    val_loader)
print(f"fp32 {score_float:.4f}  →  w8 {score_w8:.4f}")
```

Note `prepared`, not a finalized model — §2.5. This loop takes seconds to minutes and gives you the
two numbers that determine whether you need anything more complicated.

Apple's expectation for this path:

> ✅ **VERIFIED** — `docs/src/landing_page.md`: data-free *"often works well for reducing the model
> down to 8 bits, or even 6 or 4 bits, with only a slight decrease in accuracy."*

### 10.2 The bit-width ladder, and where it breaks

Apple publishes acceptance bands for palettized weights, which are the closest thing to a
first-party bit-width ladder in the corpus. They are stated as PSNR against the uncompressed model:

> ✅ **VERIFIED** — `apple/coreai-models`, `skills/skills/model-authoring/SKILL.md:149-153`:
>
> | Bit width | Expected size | Expected PSNR | Flag if below |
> |---|---|---|---|
> | 8-bit | ~2× smaller | > 55 dB | 50 dB |
> | 4-bit | ~4× smaller | ~40 dB | 35 dB |
> | 2-bit | ~8× smaller | 25–35 dB | *"usually unacceptable"* |
>
> And the general verification gates from the same file: re-authored vs source **> 70 dB**;
> NE-layout vs GPU-layout **> 70 dB**; compiled vs torch **≥ 40 dB**; after 4-bit palettization
> **≥ 35 dB**.

These are palettization bands, not quantization bands, and the guide should not pretend otherwise.
But the shape is the same for both techniques and it is the shape that matters: 8-bit is nearly free,
4-bit is a real decision, 2-bit is a research project.

The community corpus has a much sharper way of putting the 4-bit point for LLMs specifically:

> 🟠 **COMMUNITY-MEASURED** — `john-rocky/coreai-model-zoo`. *Single-author community material with
> self-declared uncontrolled benchmarks; attribute accordingly.* Across **Gemma 4 E2B and Qwen3.5**:
> *"linear int4 and k-means int4 **both** flip next-token argmax vs the HF reference; **int8 k-means
> palettization reproduces HF top-1 exactly** at ~half the fp16 size."* And, elsewhere in the same
> corpus: *"**int4 is a cliff, not a slope**"* — *"the failure is capacity, so no clever rounding
> rescues it."*
>
> ⚠️ The same corpus contains a result that **complicates** this one: for MoE experts at top-k ≥ 4,
> **symmetric linear int8 per-K-block-32 was clean and k-means int8 was lossier** — the opposite
> ordering. Both results are in the archive, at different dates, for different tensor roles. **Do not
> flatten them into one rule.** The defensible synthesis: *int8 is the safe floor everywhere; **which**
> int8 is tensor-role- and routing-dependent and must be gated per model.*

Note the interesting tension with Apple's own shipping choice: Apple's macOS LLM default **is** int4
(`symmetric_with_clipping`, per-block 32). The community measurement says int4 flips tokens; Apple
ships int4 anyway. Both can be true — "flips greedy argmax vs the HF reference" and "produces a good
assistant" are different bars, and Apple is optimising for a size budget the community measurement is
not. The lesson is that **the acceptance metric decides the answer**, which is why §1 insisted you
have one before you start.

### 10.3 Calibration-based PTQ

The moment activations enter the picture, you need data (§9.3). Full recipe, with the pieces that
usually get forgotten:

```python
import copy, torch
from coreai_opt.quantization import (
    Quantizer, QuantizerConfig, ModuleQuantizerConfig, QuantizationSpec,
)
from coreai_opt.quantization.spec import PerChannelGranularity, PerTensorGranularity
from coreai_opt import ExportBackend

float_model = copy.deepcopy(model).eval()

weight_spec = QuantizationSpec(
    dtype=torch.int8,
    qscheme="symmetric",
    granularity=PerChannelGranularity(axis=0),
)
act_spec = QuantizationSpec(
    dtype=torch.int8,
    qscheme="symmetric",
    granularity=PerTensorGranularity(),
    qparam_calculator_cls="global_minmax",     # see §18.1 for why, not moving_average
)

config = QuantizerConfig(
    global_config=ModuleQuantizerConfig(
        op_state_spec={"weight": weight_spec},
        op_input_spec={"*": act_spec},
        op_output_spec={"*": act_spec},
    ),
    # graph mode is the default and is what you want for activations
).without(torch.nn.LayerNorm, torch.nn.Embedding)

quantizer = Quantizer(model, config)

# REPRESENTATIVE example inputs — this forward seeds every qparam (§8.5 step 11)
example_inputs = (next(iter(calibration_loader))[0][:1],)
prepared = quantizer.prepare(example_inputs)

with quantizer.calibration_mode():
    for i, (batch, _) in enumerate(calibration_loader):
        prepared(batch)
        if i >= 6:            # ~128 samples at batch 20; Apple's stated guidance
            break

prepared.eval()
print("post-calibration:", evaluate(prepared, val_loader))

finalized = quantizer.finalize(backend=ExportBackend.CoreAI)
finalized.eval()
```

Four things in that listing are load-bearing and none of them are obvious:

1. **`example_inputs` comes from the calibration loader**, not from `torch.randn`.
2. **`qparam_calculator_cls="global_minmax"`** rather than the default `moving_average`. Apple's own
   ResNet-50 numbers show this is worth +1.5 points of top-1 (§18.1). It is a one-token change.
3. **`.without(LayerNorm, Embedding)`** — normalisation layers and embeddings are the classic
   boundary-sensitive layers. The community corpus measures the boundary effect at *"up to +9 dB"*
   from skipping first/last layers (community-measured, uncontrolled); Apple's own LLM preset
   excludes RMSNorm, RoPE and SDPA by type for the same reason.
4. **`prepared.eval()` before evaluating and `finalized.eval()` after finalize** — §2.4.

### 10.4 Joint compression: palettize first, then quantize activations

If you want both a lookup-table weight format *and* int8 activations, the order is mandatory.

> ✅ **VERIFIED** — `docs/src/utils/joint_compression.md`: **"Order is mandatory: palettize weights →
> `palettizer.finalize()` → quantize activations → calibrate → `quantizer.finalize()`."**
>
> Why finalize in between: *"`quantizer.prepare` uses `torch.export`, which **cannot trace through the
> parametrizations**."*
>
> Why quantize the LUT: *"A floating-point LUT causes operations to execute in floating-point
> regardless of the activation quantization, whereas an `INT8` LUT allows the runtime to use the
> **faster W_INT8-A_INT8 execution path** where available."*
>
> **Restriction:** *"Models compressed via the joint compression flow can currently only be finalized
> to the `Core AI` backend."*

> ✅ **VERIFIED** — the worked recipe, `docs/src/utils/joint_compression.md`:
> ```python
> lut_qspec = QuantizationSpec(dtype=torch.int8, qscheme=QuantizationScheme.SYMMETRIC)
> palett_config = KMeansPalettizerConfig(
>     global_config=ModuleKMeansPalettizerConfig(
>         op_state_spec={"weight": PalettizationSpec(n_bits=4, lut_qspec=lut_qspec)},
>     ),
> )
> palettizer = KMeansPalettizer(model, palett_config)
> palettizer.prepare(example_inputs)
> palettized_model = palettizer.finalize(backend=opt.ExportBackend.CoreAI)
>
> act_spec = QuantizationSpec(dtype=torch.int8, qscheme=QuantizationScheme.SYMMETRIC)
> quant_config = QuantizerConfig(
>     global_config=ModuleQuantizerConfig(
>         op_state_spec=None,                    # weights already compressed
>         op_input_spec={"*": act_spec},
>         op_output_spec={"*": act_spec},
>     ),
> )
> quantizer = Quantizer(palettized_model, quant_config)
> prepared_model = quantizer.prepare(example_inputs)
> with quantizer.calibration_mode():
>     for batch in calibration_dataloader:
>         prepared_model(batch)
> final_model = quantizer.finalize(backend=opt.ExportBackend.CoreAI)
> ```
> Note `op_state_spec=None` — §4.3's rule doing exactly the job it exists for.
>
> ✅ **VERIFIED** — reference tests: `tests/test_joint_compression.py::test_p4a8_compression_mnist_accuracy`
> (marked `@pytest.mark.slow`, skipped without coreai) and
> `tests/export/test_pt2e_mlir_export.py::test_mnist_p4a8_compression_export`. The MNIST assertions:
> baseline **> 97.0%**, joint P4-A8 after calibration **> 90.0%**.

This flow is also why `KMeansPalettizer.finalize()` deletes the prepared-marker buffer (§2.3) — so
the palettized model can be handed straight to `Quantizer`.

---

## 11. QAT: the schedule, `step()`, and the two conflict rules

QAT is the answer to "4 bits and below" (§1.2). It is also the only workflow in this guide that needs
your training loop, your optimizer and your full dataset.

### 11.1 The simplest form: no schedule at all

> ✅ **VERIFIED** — the `Quantizer` docstring's own example:
> ```python
> prepared_model = quantizer.prepare((example_input,))
> with quantizer.training_mode():
>     for epoch in range(num_epochs):
>         for data, target in train_loader:
>             optimizer.zero_grad()
>             output = prepared_model(data)
>             loss = criterion(output, target)
>             loss.backward()
>             optimizer.step()
> quantized_model = quantizer.finalize()
> ```
> The docstring calls this *"the default schedule — observers and fake_quant enabled throughout."*

Observers on and fake quant on from step 0 for the whole run. That is a legitimate configuration and
it is what you get if you never mention `QATSchedule`. It is rarely the *best* configuration, for
reasons §11.2 makes concrete.

### 11.2 `QATSchedule`: three integers

> ✅ **VERIFIED** — `quantization/config/`:
> ```python
> class QATSchedule(BaseModel):                        # frozen=True
>     enable_observer: int = Field(default=0, ge=0)
>     enable_fake_quant: int = Field(default=0, ge=0)
>     disable_observer: int | None = Field(default=None, gt=0)
> ```
> Validation, all three enforced:
> - `enable_fake_quant >= enable_observer`
> - `disable_observer > enable_observer`
> - `disable_observer >= enable_fake_quant`
>
> State at step `s`:
> - `obs_on = enable_observer <= s < (disable_observer or ∞)`
> - `fq_on  = s >= enable_fake_quant`

Read as a story, the three integers are:

1. **`enable_observer` — start watching.** Almost always `0`. There is no reason not to be collecting
   ranges from the beginning; observation is free and does not change the forward pass.
2. **`enable_fake_quant` — start rounding.** This is the interesting one. Before this step the model
   trains in full precision while the observers converge on sensible ranges. After it, the
   straight-through estimator kicks in and the model starts adapting to the rounding it will actually
   experience. Turning it on at step 0 means the first rounding happens against ranges seeded from a
   single `example_inputs` forward.
3. **`disable_observer` — freeze the ranges.** After this step, scales and zero points stop moving and
   only the *weights* adapt. This is what lets the final phase of training converge against a fixed
   grid rather than a moving one.

Apple's documented example, verbatim:

> ✅ **VERIFIED** — `docs/src/quantization/advanced.md:49-77`:
> ```python
> config = QuantizerConfig(
>     global_config=ModuleQuantizerConfig(
>         qat_schedule=QATSchedule(enable_observer=0, enable_fake_quant=150, disable_observer=2000)
>     )
> )
> quantizer = Quantizer(model, config)
> prepared_model = quantizer.prepare(example_inputs)
>
> optimizer = torch.optim.Adam(prepared_model.parameters(), lr=0.01)
> scheduler = torch.optim.lr_scheduler.StepLR(optimizer, step_size=5, gamma=0.5)
>
> for epoch in range(30):
>     with quantizer.training_mode():
>         for batch, target in train_dataloader:
>             optimizer.zero_grad()
>             loss = criterion(prepared_model(batch), target)
>             loss.backward()
>             optimizer.step()
>             quantizer.step()          # advance QAT schedule (per mini-batch)
>         scheduler.step()
>     val_metric = validate(prepared_model, val_dataloader)   # obs off, fq on
> ```
> and the YAML equivalent:
> ```yaml
> quantization_config:
>   global_config:
>     qat_schedule:
>       enable_observer: 0
>       enable_fake_quant: 150
>       disable_observer: 2000
> ```

The class docstring shows a smaller variant with the same shape — *"Enable observers from the start,
enable fake quant at the 100th step, and disable observers at the 500th step"* — so `0 / N / M` with
`0 < N < M` is the canonical form and the two published examples differ only in scale.

Two details in that loop that are easy to miss:

**The units are whatever cadence you call `step()` at.** Above it is called per mini-batch, so 150
and 2000 are mini-batches. Call it once per epoch and they are epochs. Nothing in the API knows or
cares — which means a schedule copied from a different repo may be off by the size of your dataset.

**`validate()` sits outside `training_mode()`**, and the comment says why: observers off, fake quant
on. That is exactly the deployment-time configuration, so validation measures what you will ship.

### 11.3 `step()` and its three failure modes

> ✅ **VERIFIED** — `Quantizer.step()`:
> - Raises `RuntimeError("step() must be called inside a training_mode() context.")` outside the
>   context manager.
> - Increments `_step_count` **monotonically — never reset between training loops.**
> - Emits a `UserWarning` if no schedule is configured anywhere (*"step() has no effect…"*).
>
> ✅ **VERIFIED** — `training_mode()` is **not re-entrant**:
> `RuntimeError("Cannot enter training_mode() while already inside a training_mode() context. Nested
> training_mode() calls are not supported.")`

The never-reset counter is the one that bites. If you exit `training_mode()` between epochs — as the
documented example does, to run validation — the step count keeps climbing across all of them. That
is the intended behaviour and it is what makes `disable_observer=2000` mean "2000 total steps" rather
than "2000 steps into whichever epoch". But it also means **a second training run on the same
`Quantizer` object starts wherever the first one ended**, with every schedule milestone already in
the past. Build a fresh `Quantizer` per run.

### 11.4 The manual API, and why it is mutually exclusive

```python
quantizer.enable_observer(module=None)
quantizer.disable_observer(module=None)
quantizer.enable_fake_quant(module=None)
quantizer.disable_fake_quant(module=None)
```

> ✅ **VERIFIED** — each takes an optional `module: nn.Module` to scope to a subtree; an unknown
> module raises `ValueError(f"Module {module} is not a submodule of the prepared model.")`.
>
> ✅ **VERIFIED** — and they are **mutually exclusive with schedules**:
> ```
> RuntimeError: Enable/disable APIs for observers or fake quantization cannot be used with a
> qat_schedule configured. To use these APIs, make sure there are no global or module-level
> qat_schedule configured. For using the QAT schedule, refer to the step() API.
> ```

Two ways to drive the same state machine, and the framework refuses to let you use both. Use the
schedule for anything reproducible; use the manual API for interactive experiments and for
subtree-scoped control, which the schedule expresses differently (§11.5).

Written manually, the documented schedule is:

```python
prepared = quantizer.prepare(example_inputs)

with quantizer.training_mode():
    quantizer.enable_observer()          # step 0: watch
    quantizer.disable_fake_quant()       #         but don't round yet

    for step, (batch, target) in enumerate(train_loader):
        if step == 150:
            quantizer.enable_fake_quant()    # start rounding
        if step == 2000:
            quantizer.disable_observer()     # freeze the ranges

        optimizer.zero_grad()
        criterion(prepared(batch), target).backward()
        optimizer.step()
        # note: NO quantizer.step() here — schedules and manual control cannot mix
```

> 🟡 **RECONSTRUCTED** — this manual form is assembled from the four verified method signatures and
> the verified schedule semantics. It is not quoted from Apple's docs, which only show the `step()`
> form. It should behave identically; prefer the schedule form for anything you intend to keep.

### 11.5 Per-module schedules, and the two conflict rules

`qat_schedule` is a field on **`ModuleQuantizerConfig`**, not on `QuantizerConfig`. That is
deliberate: different parts of the model can be on different schedules.

```python
config = QuantizerConfig(
    global_config=ModuleQuantizerConfig(
        op_state_spec={"weight": w4_spec},
        qat_schedule=QATSchedule(enable_observer=0, enable_fake_quant=150, disable_observer=2000),
    ),
    module_name_configs={
        # The head is the most sensitive layer: let it train in float much longer.
        "model.lm_head": ModuleQuantizerConfig(
            op_state_spec={"weight": w8_spec},
            qat_schedule=QATSchedule(enable_observer=0, enable_fake_quant=1000,
                                     disable_observer=3000),
        ),
    },
)
```

Which raises the obvious question of what happens when two configs claim the same fake-quantize
object. There are two documented rules and one open bug.

> ✅ **VERIFIED** — `QATSchedule` docstring, both rules verbatim:
> - **Graph-mode dedup:** *"The schedule of the **consuming module** is always applied to the
>   deduplicated node, irrespective of the choice of deduplication made by the graph preparation."*
> - **Shared weights:** *"the schedule of the **first module encountered in the module tree** is
>   applied. A warning is emitted for the conflict if there is no fake-quantize node deduplication
>   happening (in Eager execution mode)."*

⚠️ And now the bug, which is open as of 2026-07 and is a genuine silent failure:

> ⚠️ **SILENT FAILURE — a shared weight can take its *dtype* from one config and its *QAT schedule*
> from a different one.**
>
> ✅ **VERIFIED** — coreai-opt **issue #41, OPEN**. Repro: two `nn.Linear` modules sharing one weight;
> `l1` configured int8 with `enable_fake_quant=1`, `l2` configured int4 with `enable_fake_quant=5`.
> Observed:
> ```
> distinct weight FQ objects: 1
> weight FQ dtype quant_min/quant_max: -8 / 7   -> int4    # l2, declared last
> weight FQ governing schedule enable_fake_quant step: 1   # l1, first in graph
> step=1 fake_quant_enabled=1     # fires at step 1, not l2's step 5
> ```
> Root cause — **two independent owner-resolution paths**:
> - **Schedule owner** ← `_get_fake_quantize_modules` (`_graph/quantizer.py`) walks the FX graph and
>   maps each shared FQ to the **first consumer with `nn_module_stack`** → graph order picks `l1`.
> - **Dtype owner** ← `_get_state_node_shared_spec` (`_graph/_annotation_utils.py`) keeps the spec of
>   the user annotated **first in priority order**, and priority follows **config declaration order**
>   → `l2` wins.
>
> *"Eager mode has the same split. It warns about the schedule conflict, but **the warning only
> mentions the schedule, not the dtype**."*
>
> Test gap noted in the issue: `tests/quantization/test_qat_schedule.py::test_shared_weight_keeps_first_schedule`
> gives both modules the same dtype, so the conflict is never covered.

**Safe default:** for any weight shared between modules — tied embeddings and `lm_head`, Siamese
towers, weight-tied autoencoders — **give every consumer the identical spec and the identical
schedule.** Do not rely on precedence to pick for you. This is also the advice in the v0.2.0 release
notes' known-issues list:

> ✅ **VERIFIED** — coreai-opt v0.2.0 release notes, known issues, verbatim:
> - *"Tying model weights (e.g. `layer1.weight = layer2.weight`) after quantizer finalize in eager
>   execution mode will fail"*
> - *"For models with shared weights, in Eager mode, **MODULE_NAME > MODULE_TYPE precedence is only
>   honored if you express the override via `module_state_spec`. With `op_state_spec` alone, it depends
>   on forward-pass execution order.**"*
> - *"For models with shared weights using **different local names** (last part of the name after the
>   rightmost '.'), in graph mode quantization, only one particular local name is matched. To know
>   which name, users must examine the torch exported graph or view ModelInspector summary for modules
>   sharing the weights. **Alternatively, users can configure the same weight spec for each distinct
>   local name to be safe.**"*

Three separate known issues, all about shared weights, all with the same workaround: be explicit and
be redundant.

### 11.6 QAT does not rescue everything

The honest framing, from the corpus:

> 🟠 **COMMUNITY-MEASURED** — `john-rocky/coreai-model-zoo`. *Single-author, uncontrolled.* On a
> quality ladder measured in "structural token flips" against an HF reference:
>
> | Configuration | Regressions vs reference | Verdict |
> |---|---|---|
> | k-means int4 | +12 | *"wall"* |
> | affine-block-32 int4 | +11 | *"wall"* |
>
> *"int4 is a WALL … **non-QAT int4 can't reach clean (needs QAT weights)**."*

That is a community claim about a community metric, and it points the same way as Apple's own
guidance: at 4 bits and below, PTQ gets you close and QAT is what closes the gap. If you have not
budgeted for a training run, do not budget for 4 bits either — budget for **selective** 4 bits, which
is what §13 is about and what actually ships.

---

## 12. KV-cache quantization (graph mode only)

Not mentioned on stage, but present in the API and directly relevant to anyone deploying an LLM: you
can keep the KV cache buffer itself in a quantized dtype.

> ✅ **VERIFIED** — `QuantizerConfig.kv_cache_quant_configs`, and:
> ```python
> class KVCacheQuantConfig(BaseModel):   # frozen
>     op_quantizer_config: OpQuantizerConfig
>     @property
>     def quant_input_idx(self) -> int   # the single int key of op_input_spec
> ```
>
> ✅ **VERIFIED** — usage, from `tests/quantization/test_kv_cache_quantization.py:161-169` and the
> class docstring:
> ```python
> QuantizerConfig(
>     execution_mode="graph",
>     global_config=ModuleQuantizerConfig(...),
>     kv_cache_quant_configs={
>         "mutable_cache_update_and_fetch": KVCacheQuantConfig(
>             op_quantizer_config=OpQuantizerConfig(
>                 op_input_spec={1: default_activation_quantization_spec()},
>                 op_output_spec=None,
>                 op_state_spec=None,
>             ),
>         ),
>     },
> )
> ```

The dictionary key is the **name of the cache op node** in your exported graph. Note the integer key
`1` in `op_input_spec` — that is the positional index of the tensor being written into the cache, and
it is required to be exactly one unambiguous index.

> ✅ **VERIFIED** — the enforced rules:
> - `op_input_spec` must have **exactly one non-negative int key** mapped to a non-`None` spec (no
>   `"*"`, no multi-key) — *"the finalize-side relocation needs a single, unambiguous input edge to act
>   on."*
> - `op_output_spec` must be empty/`None` — *"the finalize pass inserts the output dequantize."*
> - `op_state_spec` must be empty/`None` — *"cache-update ops have no learnable state."*
> - **`ExecutionMode.GRAPH` only**, else `ValueError`.
> - A duplicate `op_type_config[op]` entry anywhere → `logger.warning` that the
>   `kv_cache_quant_configs` entry wins at prepare time.
> - After export, `_validate_kv_cache_quant_ops` raises `ValueError` if the key matches no node, or if
>   `quant_input_idx >= len(node.all_input_nodes)`.

What `finalize(backend=CoreAI)` actually does is move the dequantize past the cache op:

> ✅ **VERIFIED** — `_move_cache_dequant_to_output`, `_graph/_prepare_for_export.py:691-786`. It
> rewrites
> ```
> update -> coreai.quantize -> coreai.dequantize -> cache_op(x, dq, ...) -> consumer
> ```
> into
> ```
> update -> coreai.quantize -> cache_op(x, q, ...) -> coreai.dequantize -> consumer
> ```
> so **the cache buffer stays in the quantized dtype**. The CoreML backend raises
> `NotImplementedError`.

⚠️ **And the precondition, which the docstring states as a correctness requirement rather than a
suggestion:**

> ✅ **VERIFIED** — `KVCacheQuantConfig` docstring: *"the cache op **must commute with
> quantize/dequantize** — i.e. a pure data-movement op (slicing, narrowing, copy). **Arithmetic on
> cached values would silently produce a numerically wrong model.**"*

There is no check for this. If you point `kv_cache_quant_configs` at an op that does arithmetic, the
rewrite happens, the export succeeds, and the model is wrong. Only name ops you have read.

---

## 13. The SAM3 story: uniform compression is almost never right

This is the best teaching narrative available for this material, and it is worth walking end to end
because every step of it is a decision you will face.

### 13.1 The model

> ✅ **VERIFIED** — session 325:54–63. SAM3 = Segment Anything Model 3, *"an 850-million parameter
> model that performs prompt-based image segmentation."* Structure as presented:
>
> | Component | Role | Share of parameters |
> |---|---|---|
> | Image encoder | processes the image | *(with text encoder)* **96%** |
> | Text encoder | handles the user's prompt | *(with image encoder)* **96%** |
> | Detector (DETR + mask decoder) | produces the segmentation mask | **4%** (325:158) |
>
> 325:60 — *"These two components combined make up **96% of the model's parameters** so **getting
> these right is key**."*
>
> ✅ **VERIFIED — cross-check** — `apple/coreai-models`, `models/sam3/README.md` gives **848M**
> parameters for `facebook/sam3`; the transcript rounds to 850M.

Hold onto the 96/4 split. It is the whole argument.

### 13.2 The baseline

> ✅ **VERIFIED** — session 325:81–88:
> *"The full conversion **takes a few minutes**, so I have pre-computed the baseline asset."*
> *"What I do here is load the baseline **32-bit** converted model and run it. As you can see, it's
> **over 3 gigs** in size."*
> *"In this image, I ask for a segmentation mask over **all the flowers**. All are successfully
> detected based on the default threshold, running on-device. **This is what I need to preserve after
> compression.**"*

Note the last sentence. The acceptance criterion was stated before the compression was attempted. It
is a behavioural criterion — *all the flowers are detected* — not a PSNR threshold. That turns out to
matter in §13.5.

### 13.3 The one-line experiment

```python
from coreai_opt.quantization import Quantizer, QuantizerConfig, ExecutionMode

config = QuantizerConfig.presets.w4(execution_mode=ExecutionMode.EAGER)
quantizer = Quantizer(sam3_wrapper, config)
prepared = quantizer.prepare(example_inputs)     # example_inputs is a tuple
quantized = quantizer.finalize()
```

> 🟡 **RECONSTRUCTED** — session 325:90–95 describes exactly this sequence — *"`presets.w4` gives me
> 4-bit per-channel, symmetric quantization in one line… I set `ExecutionMode` to `EAGER`… Then I
> initialize `coreai-opt`'s `Quantizer` with the config, **pass example inputs** and **finalize** — the
> model is then compressed"* — but no code was published. Every identifier above is verified against
> the shipped source (§3.2, §8.1); only the exact arrangement is inferred.

Result:

> ✅ **VERIFIED** — session 325:96–102:
> *"As before, I load the model and run it on-device. The model is now **around 430 megabytes**."*
> *"Look at the result. **One of the occluded flowers is no longer detected.**"*
> *"**I applied the same aggressive compression to every single layer, and it's likely that not every
> layer handles this equally well.** The question is — **which layers are causing this?** This is the
> kind of problem that's **hard to diagnose from the output alone. I need to see inside the model.**"*

**3 GB → ~430 MB**, roughly **7×** — and a visible regression on an occluded object.
*(Apple-published, WWDC26 session 325, hardware not stated beyond "on-device", 2026-06.)*

Two observations before moving on. First, 7× is more than the ~8× a naive fp32→int4 ratio would
suggest is available *minus* scale overhead, which is a plausible-looking number and exactly why it
is not evidence of anything by itself. Second — and this is the general lesson — **the failure was
visible in the output but not localisable from it.** One missing flower tells you the model changed;
it tells you nothing about where.

### 13.4 The diagnosis

The Core AI Debugger is Part 10's subject. What matters here is the *shape* of the evidence it
produced.

> ✅ **VERIFIED** — session 325:145: *"These pairs are called **sync points**, places where the
> specialized model's output is **expected to match** the original PyTorch result. The debugger
> automatically identifies these points throughout the model."*
> 325:148: *"The default metric is a **peak signal-to-noise ratio or PSNR**, but this **can be changed
> to whichever similarity indicator suits your model best**."*
> 325:150: *"**green nodes indicate similar tensors, red nodes would indicate significant
> differences**"*, with yellow for moderate divergence.
> The workflow: *"I'll **sort by similarity**, and investigate the most dissimilar sync points… I'll
> use the **up arrow key** to navigate through the low-PSNR sync points **one-by-one to see if a
> pattern emerges**."*

And the finding:

> ✅ **VERIFIED** — session 325:156–162, verbatim:
> *"I'm noticing that **the vast majority of low-PSNR sync points are actually coming from the
> detector decoder**. This tells me that the quantization scheme applied earlier has **mildly corrupted
> the detector results**. Since we previously identified that **the detector block only accounts for 4%
> of model parameters, we're not getting much benefit from compressing it anyway**. So, I'll return to
> the Jupyter notebook, and try **changing the quantization scheme to ignore the detector**."*
>
> *"Great! I can see that we have **once again reached baseline quality** where all flowers are
> detected and the model is only a fraction of the size! **Core AI Debugger turned hours of manual
> tensor comparison into a visual diagnosis. I started with missing detections and reached a revised
> quantization scheme in minutes.**"*

The reasoning in that paragraph is the point of this whole guide, and it has two independent halves:

1. **Where is the damage?** Answered by per-block evidence — low-PSNR sync points clustering in one
   named PyTorch module.
2. **What is the damage buying us?** Answered by parameter share — 4%.

Neither half is sufficient. A block that is 4% of parameters and *not* damaged should stay
compressed. A block that is damaged and holds 60% of parameters is a genuine trade you have to think
about. It is the **conjunction** — high damage, negligible size benefit — that makes the decision
free.

### 13.5 The fix

```python
config = QuantizerConfig.presets.w4(execution_mode=ExecutionMode.EAGER)

# name-pattern scope (regex, re.fullmatch); None == "leave this alone"
config.module_name_configs = {"detector(\\..*)?": None}

# ...or by type, if the decoder is a class you can name:
# config = QuantizerConfig(module_type_configs={"my_pkg.sam3.DetectorDecoder": None})
```

> 🟡 **RECONSTRUCTED** — the session says only *"changing the quantization scheme to ignore the
> detector"*. The `None`-disables mechanism, the `re.fullmatch` semantics and the fully-qualified-name
> requirement are all ✅ **VERIFIED** (§4.3, §5.1, §5.2); the specific pattern string is illustrative.
> Print `model.named_modules()` and write a pattern that matches what is actually there — and note
> that a bare `"detector"` will match only the module itself, not its children (§5.1).

### 13.6 What Apple actually shipped, which is not what the talk showed

The re-authored iOS version of SAM3 in `apple/coreai-models` is a **three-entrypoint** model with
**per-function** compression, and it does not use quantization at all.

> ✅ **VERIFIED** — `apple/coreai-models`, `models/sam3/README.md`:
>
> | Function | Compression | Inputs | Outputs |
> |---|---|---|---|
> | `image_encode` | **4-bit k-means palettization (gs=32)** + fp16 | `pixel_values` | `backbone_features` |
> | `text_encode` | **6-bit k-means palettization (gs=8)** + fp16 | `input_ids` | `text_features` |
> | `detect` | **fp16, no weight compression** | `backbone_features`, `text_features` | `pred_masks`, `pred_boxes`, `pred_logits`, `presence_logits` |

Four differences from the talk, all worth absorbing:

**1. Palettization, not quantization.** The stage demo used `presets.w4()`; the shipped recipe uses
k-means. The transcript explains the reason: *"This **lookup-table-based compression is well-suited
for power efficiency on iOS**"* (325:241–248).

**2. The two encoders are compressed *differently*.**

> ⚠️ **DISCREPANCY, flagged.** The transcript (325:241) says *"I apply **4-bit** palettization… to
> **the two encoders**."* The shipped recipe is **asymmetric**: image encoder w4/gs32, text encoder
> **w6/gs8**. The talk simplified. ✅ Both readings are verified — the transcript quote and the
> README table.

That asymmetry is itself the lesson repeated at a finer grain. The text encoder is smaller and its
output feeds the detector directly; it gets more bits and finer groups.

**3. The detector stays uncompressed, for exactly the reason §13.4 established.**

> ✅ **VERIFIED** — session 325:241–248: *"**The detector stays uncompressed. I know that it's
> sensitive to compression from our previous exercise.**"*

The narrative arc is complete: the debugger's finding in the macOS demo became a design constraint in
the shipped iOS model.

**4. A second discrepancy, and this one is a hardware constraint worth its own callout.**

> ⚠️ **MAJOR CROSS-CHECK FINDING.** The transcript says *"4-bit palettization **with per-channel
> scales**"*. The shipping recipe **deliberately sets `enable_per_channel_scale=False`** and gets its
> per-channel behaviour from `PerGroupedChannelGranularity` instead.
>
> ✅ **VERIFIED** — `apple/coreai-models`, `segmentation/pipeline.py:136-142`,
> `SegmentationExportConfig` docstring, verbatim: *"Both encoders **deliberately disable per-channel
> scale**: `enable_per_channel_scale=True` lowers to **`mps.dequantize_lut` ops with rank-6 LUTs,
> which ANE rejects (max tensor rank 5)**, forcing the runtime to **fall back to GPU**. Keeping it off
> keeps the asset **ANE-compatible** at the cost of a small PyTorch-side quality regression."*
>
> **ANE max tensor rank is 5.** Per-channel scale layered on top of grouped-channel palettization
> produces rank-6 LUTs. The compression option that looks strictly better in PyTorch silently costs
> you the Neural Engine.

That is the single most valuable footgun in this entire area, and note its shape: **nothing fails.**
The model converts, runs and produces good numbers. It just runs on the wrong processor. Compression
choices and hardware placement are coupled, and the coupling is invisible from the Python side.

The shipped palettization code, for completeness:

> ✅ **VERIFIED** — `apple/coreai-models`, `segmentation/pipeline.py:208-245`:
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
> Note the transcript's own framing of why the lower-level form is used: *"**There is a preset
> available for this, but I use the lower-level representation here to showcase the APIs.**"*
> (`KMeansPalettizerConfig.presets.w4(axis=0, group_size=16)` is the preset in question — different
> default group size, hence the manual spec.)

And the reproduction is runnable:

> ✅ **VERIFIED** — `apple/coreai-models`, `models/sam3/README.md`:
> ```sh
> uv run models/sam3/export.py                       # lite (iOS) export — the WWDC26 325 demo
> uv run models/sam3/export.py --full                # plain HF Sam3Model, float32, 1008x1008
> ```
> ⚠️ `--n-bits` and `--group-size` are **uniform overrides applied to BOTH encoders**, replacing the
> asymmetric default. Passing `--n-bits 4` silently downgrades the text encoder from 6 bits.
> SAM3 is a gated HF model (`hf auth login`), and the export script pins
> `transformers>=5.5.4,<5.10.1`.

### 13.7 The generalisable procedure

Strip the specifics and you get a method that applies to any model:

1. **Establish a behavioural acceptance criterion first**, on real inputs. Not a PSNR number — a
   thing you can look at and say yes or no to. PSNR is how you *localise*; behaviour is how you
   *accept*.
2. **Apply a preset uniformly.** One line, minutes. This is your size floor and your quality floor.
3. **If quality holds, stop.** This does happen, especially at 8 bits.
4. **If it does not, get per-block evidence.** Sync points and PSNR (Part 10), or `save_intermediates`
   plus your own comparison, or a layer-at-a-time ablation sweep. Anything that maps error back to
   named PyTorch modules.
5. **Cross the error map with the parameter map.** You are looking for blocks that are high-error and
   low-share. Those are free to exclude.

   ```python
   total = sum(p.numel() for p in model.parameters())
   for name, mod in model.named_modules():
       n = sum(p.numel() for p in mod.parameters(recurse=False))
       if n:
           print(f"{100*n/total:6.2f}%  {n:>12,}  {name}")
   ```

   Run this once, at the start. It takes a second and it is the denominator for every subsequent
   decision.
6. **Exclude with `None`** — `module_name_configs` for instances, `module_type_configs` for types
   (§4.3, §5.2).
7. **Re-measure both size and behaviour.** Excluding a block always costs size; you need to confirm it
   bought back the quality.
8. **Consider going *further* on what remains.** Once the sensitive block is out, the insensitive 96%
   may tolerate more aggression than the uniform sweep suggested.

Apple's own automated exploration converges on the same shape: sweep presets, then generate
**layer-skip variants** from the best seeds (§3.4). The refinement phase is entirely about exclusion.

---

## 14. `coreai_opt.casting`: the fp16 helper and the ordering rule

Compression and *precision reduction* are different operations and they happen at different points in
the pipeline. `coreai_opt.casting` is the second one.

### 14.1 Three functions, one recommendation

> ✅ **VERIFIED** — `src/coreai_opt/casting/__init__.py`:
> ```python
> from coreai_opt.casting import (
>     cast_fp32_to_fp16,          # FP32 → FP16 only
>     cast_int32_to_int16,        # INT32/INT64 → INT16 only
>     cast_to_16_bit_precision,   # both — the recommended top-level entry point
> )
> ```

They operate on a **`torch.export.ExportedProgram`**, not on an `nn.Module`. That is the whole reason
this section sits *after* conversion starts:

> ✅ **VERIFIED** — module docstring: *"FP32→FP16: Convert parameters/inputs upfront, walk nodes
> topologically **inserting casts only when ops should run in higher precision**, let cleanup collapse
> roundtrips between consecutive casted ops. INT32→INT16: Convert inputs where all uses are safe args,
> walk nodes topologically inserting int16 casts at designated ops with cast-backs after…"*

Selection criteria differ sharply between the two passes:

> ✅ **VERIFIED** — `docs/src/utils/casting.md:28-38`:
> - **The FP pass is aggressive**: it casts all float state and ops **except** tensors whose values
>   exceed the FP16 range (≈ ±65504).
> - **The INT pass is conservative**: it skips tensors that are constant-foldable, that feed an
>   indexing op (overflow risk), or that are not consumed by a computationally intensive op.

And why this is not `model.half()`:

> ✅ **VERIFIED** — `docs/src/utils/casting.md:128-143`: `model.half()` only touches parameters and
> buffers — creation ops like `torch.zeros` / `torch.arange` stay FP32. `torch.autocast` wraps each op
> at runtime and produces no 16-bit artefact at all. `cast_to_16_bit_precision` **rewrites the exported
> graph** so *"downstream converters see a 16-bit graph and do not need to insert per-op cast
> wrappers."*

### 14.2 ⚠️ Return value vs in-place mutation — a documented conflict

This is a real disagreement between two sources in the corpus and you should code defensively around
it.

> ⚠️ **CONFLICT.**
> - One reading (the `coreai-opt` API notes): *"All three **mutate** a `torch.export.ExportedProgram`
>   in place and return nothing meaningful."* And Apple's own integration doc calls it as a statement:
>   ```python
>   cast_to_16_bit_precision(exported_program)     # in-place graph rewrite
>   ```
> - The other reading (the signature listing and the shipping call site): the functions are typed
>   `-> ExportedProgram`, and `apple/coreai-models`, `segmentation/pipeline.py:250-263` **assigns the
>   result**:
>   ```python
>   img_program = torch.export.export(img_enc, args=(pixel_ref,))
>   img_program = img_program.run_decompositions(coreai_torch.get_decomp_table())
>   img_program = cast_to_16_bit_precision(img_program)
>   ```
>
> Both call styles appear in Apple's own material and both are presented as correct. The likely
> reconciliation is that the pass mutates in place **and** returns the same object, which makes both
> spellings work.
>
> 🔴 **GAP — which is authoritative is unverified.** `casting/casting.py` was not read at the code
> level; the pass names, node-level heuristics and the FP16 threshold constant are unconfirmed beyond
> the docs' *"approximately ±65504"*.
> **What would resolve it:** reading `src/coreai_opt/casting/casting.py`, or one line —
> `ep2 = cast_to_16_bit_precision(ep); print(ep2 is ep)`.
> **Safe default meanwhile:** **assign the result and never touch the input again.**
> ```python
> ep = cast_to_16_bit_precision(ep)     # works under both readings
> ```
> This is what Apple's shipping pipeline does, and it is correct whether the function returns a new
> program or the same one.

### 14.3 The ordering rule: compress first, cast second

> ✅ **VERIFIED** — `docs/src/utils/casting.md`: **"Ordering rule: compress first, cast second."**
> *"Any quantized int8 buffers are left untouched; any remaining FP32 weights move to FP16."*

The full canonical pipeline, which is the shape every `coreai-opt` example follows:

> ✅ **VERIFIED** — `docs/src/introduction/integration_coreai.md`, the canonical end-to-end:
> ```python
> from pathlib import Path
> from coreai_opt.casting import cast_to_16_bit_precision
> import coreai_torch, torch
>
> finalized_model = quantizer.finalize(backend=opt.ExportBackend.CoreAI)  # CoreAI is the default
>
> exported_program = torch.export.export(finalized_model, example_inputs).run_decompositions(
>     coreai_torch.get_decomp_table()
> )
> cast_to_16_bit_precision(exported_program)     # in-place graph rewrite
>
> converter = coreai_torch.TorchConverter()
> converter.add_exported_program(exported_program)
> ai_program = converter.to_coreai()
> ai_program.optimize()
> ai_program.save_asset(Path("model.aimodel"))
> ```
> and the explanation of why `finalize()` is what makes conversion work: *"Under the hood, `finalize()`
> replaces coreai-opt's internal fake-quantize/fake-palettize ops with **PyTorch custom ops whose
> definitions match the corresponding compression ops in the Core AI dialect**. This allows
> `coreai-torch` to recognize the ops and map them correctly in the Core AI representation."*

⚠️ One consequence of the casting pass that will break your calling code if you ignore it:

> ✅ **VERIFIED** — `docs/src/utils/casting.md`, verbatim note: *"These passes mutate the
> `ExportedProgram` in place and **may change the dtypes of user inputs and outputs**. Calling code may
> need to be updated so that input tensors are passed as `fp16`/`int16` …"*

Your model's *interface* changes. If you feed the resulting `.aimodel` an fp32 `NDArray` because that
is what the PyTorch model wanted, you have a bug that will present as garbage rather than as a type
error.

### 14.4 ⚠️ SILENT FAILURE — fp16 casting does not guard activation overflow, and compression makes it worse

> ⚠️ **SILENT FAILURE — an fp16-cast model can produce zeros where a stable op should produce a large
> finite value, and compression increases the chance of it.**
>
> ✅ **VERIFIED** — coreai-opt **issue #7, OPEN**, with a maintainer answer. The pass *"correctly
> guards against **static tensor overflow** (weights/constants > FP16_MAX = 65504), but **does not
> account for activation-level overflow**."*
>
> Worked numbers from the issue:
> ```
> exp(10.4) ≈ 32,900   (fits fp16)
> exp(11.0) ≈ 59,874   (barely fits fp16)
> exp(11.1) ≈ 66,686   → OVERFLOW → output collapses to 0
> ```
> Thresholds given: `softplus` at x ≈ 10.4, `logsumexp` at x ≈ 7.63, `logcumsumexp` at x ≈ 11.09.
>
> **The compound effect, verbatim from the issue:** *"When `coreai-optimization` applies weight
> compression (palettization, quantization) AND fp16 casting together: 1. Quantization introduces
> rounding errors in weights 2. These errors can shift activation distributions 3. **Values that were
> safely below the overflow threshold may now exceed it** 4. The casting pass has no mechanism to
> detect or prevent this."*
>
> ✅ **MAINTAINER ANSWER** (@crowbat, CONTRIBUTOR), verbatim: *"You're right that the casting utility
> currently only considers statically available tensors when choosing whether or not to cast parts of
> the model to lower precision. … Marking this as a feature request issue. **Before such handling is in
> place, a workaround could be to manually edit the original Pytorch model definition to substitute
> stable versions of ops like `Softplus`**, avoiding the need for changes in either `coreai-opt` or
> `coreai-torch`."*

**Read that answer carefully.** As of 2026-07 the sanctioned fix for fp16 activation overflow is to
**rewrite the PyTorch module**. There is no flag, no `ignore_ops` list, no calibration-aware casting.
Two proposed enhancements are open feature requests, not shipped behaviour: calibration-based
activation-range analysis, and a user-specified op-exclusion list.

**Safe default:** if your model contains `softplus`, `logsumexp`, `logcumsumexp` or any `exp` on
unbounded activations, either substitute a numerically stable formulation before export, or skip
`cast_to_16_bit_precision` and let the converter handle precision. And **re-check for zeros after you
change a compression config**, not just after you change the casting — the two interact, and the
interaction is one-directional (more compression, more risk).

The pattern of substituting a stable formulation is well-established in this stack; Apple's own
Neural Engine authoring rules use it for a different reason:

> ✅ **VERIFIED** — `apple/coreai-models`,
> `skills/skills/model-authoring/references/common_issues.md`: `nn.functional.silu(x)` lowers to
> `mps.cast(→f32) + mps.swish(f32) + mps.cast(→f16)` — three invalid ops on the Neural Engine — so use
> `gate_pre * torch.sigmoid(gate_pre)` instead. Similarly `torch.tanh` →
> `2 * torch.sigmoid(2 * x) - 1`.

---

## 15. `coreai_opt.coreai_utils`: compressing an already-converted program

Everything so far compresses a **PyTorch** model. `coreai_utils` compresses an **`AIProgram`** — a
model that has already been converted — with a graph pass, no PyTorch involved.

### 15.1 The API

> ✅ **VERIFIED** — `src/coreai_opt/coreai_utils/`:
> ```python
> from coreai_opt.coreai_utils import CompressionGranularity, DType
> from coreai_opt.coreai_utils import quantize_weights, palettize_weights, sparsify_weights
>
> class DType(_StrEnum):
>     INT2, UINT2, INT4, UINT4, INT8, UINT8, FP4_E2M1FN, FP8_E4M3FN, FP8_E5M2, FP8_E8M0FNU
>     def is_int(self) -> bool
> class QScheme(_StrEnum): SYMMETRIC, ASYMMETRIC
> class CompressionGranularity(_StrEnum): PER_TENSOR, PER_CHANNEL, PER_BLOCK, PER_GROUPED_CHANNEL
> ```
>
> 🔴 **GAP — `QScheme`'s import path.** The package `__all__` is
> `CompressionGranularity, DType, palettize_weights, quantize_weights, sparsify_weights` — **`QScheme`
> is not in it** — yet `docs/src/utils/coreai_compression.md:92-97` does
> `from coreai_opt.coreai_utils import (…, QScheme, …)`. Either the docs are stale or `__init__`
> re-exports it implicitly. **What would resolve it:** one import statement in a REPL.
> **Safe default meanwhile:** `from coreai_opt.coreai_utils.common import QScheme`, which is where it
> is defined and is correct under both readings.

`quantize_weights` in full:

> ✅ **VERIFIED** — `passes/weight_quantization.py:151-160`:
> ```python
> def quantize_weights(
>     coreai_program: AIProgram,
>     dtype: DType,
>     qscheme: QScheme = QScheme.SYMMETRIC,
>     granularity: CompressionGranularity = CompressionGranularity.PER_CHANNEL,
>     block_size: int = 32,
>     weight_num_threshold: int = 1024,
>     scale_dtype: DType | None = None,
>     in_place: bool = False,
> ) -> AIProgram
> ```
> `_VALID_WEIGHT_DTYPES = {FP4_E2M1FN, FP8_E4M3FN, FP8_E5M2, INT2, INT4, INT8, UINT2, UINT4, UINT8}`.
>
> Block sizes derived per granularity: a 2-D linear `[C_out, C_in]` gives PER_TENSOR `[0,0]`,
> PER_CHANNEL `[1,0]`, PER_BLOCK(32) `[1,32]`; a 4-D conv gives `[0,0,0,0]` / `[1,0,0,0]` /
> `[1,32,0,0]`.
>
> Raises `ValueError` when: the dtype is unsupported; an FP dtype is paired with ASYMMETRIC;
> `scale_dtype != None` with an integer dtype; `scale_dtype != None` with FP4; or **FP4 with
> granularity != PER_BLOCK or block_size != 32** — *"FP4 weights must use per-block quantization with a
> block size of 32 to produce a valid MXFP4 encoding."*
>
> Emits `coreai.blockwise_shift_scale(data, scale, offset1=zero_point, offset2=zeros)`.

The two siblings, for completeness:

> ✅ **VERIFIED** — `passes/weight_palettization.py:63-76` and `passes/weight_sparsification.py:55-64`:
> ```python
> def palettize_weights(coreai_program, lut_dtype, n_bits=4,
>                       granularity=CompressionGranularity.PER_TENSOR, group_size=32,
>                       cluster_dim=1, enable_per_channel_scale=False,
>                       weight_num_threshold=1024, num_kmeans_workers=4,
>                       enable_fast_kmeans_mode=True, rounding_precision=4,
>                       in_place=False) -> AIProgram
>
> def sparsify_weights(coreai_program, target_sparsity=0.5, block_size=None, n_m_ratio=None,
>                      quantize_dtype=None, palettize_nbits=None,
>                      weight_num_threshold=1024, in_place=False) -> AIProgram
> ```
> ⚠️ Note `lut_dtype` is **positional #2 with no default** on `palettize_weights` — the docs example
> passes it as a keyword, which hides that. `sparsify_weights` enforces two XOR rules:
> `target_sparsity` XOR `n_m_ratio`, and `quantize_dtype` XOR `palettize_nbits`.

### 15.2 What it can reach, and the size threshold

Only constants feeding a small set of ops are candidates:

> ✅ **VERIFIED** — `coreai_utils/passes/__init__.py`:
> ```python
> _OPS_WEIGHT_NEED_COMPRESSION = frozenset({
>     "coreai.batch_matmul", "coreai.conv2d",
>     "coreai.decomposable.broadcasting_batch_matmul",
>     "coreai.gather_nd", "coreai.transpose",
> })
> ```

Five ops. If your weight is consumed by anything else, this pass will not see it — which is a much
narrower reach than the PyTorch-side quantizer's twenty-four annotation patterns.

`weight_num_threshold` is the second filter: constants with fewer elements than the threshold are
left alone, because compressing a tiny tensor costs more in scale metadata than it saves.

> ✅ **VERIFIED** — the code default is **1024**; the docs' "advanced" examples use **2048**; and
> Apple's own diffusion export uses **32768** (§17.2). All three are deliberate — the right value
> depends on how many small constants your graph has.

### 15.3 The worked example, and Apple's caveat

> ✅ **VERIFIED** — `docs/src/utils/coreai_compression.md:11-31`:
> ```python
> from coreai.authoring import AIModelAsset
> from coreai_opt.coreai_utils import DType, quantize_weights
> from pathlib import Path
>
> ai_asset = AIModelAsset.load(Path("model.aimodel"))
> compressed_program = quantize_weights(
>     coreai_program=ai_asset.program, dtype=DType.INT8, in_place=False
> )
> compressed_program.optimize()
> compressed_program.save_asset(Path("model_compressed.aimodel"))
> ```

And the caveat, which you should not skip past:

> ✅ **VERIFIED** — coreai-opt v0.2.0 release notes, verbatim: `coreai_opt.coreai_utils.*` is *"a few
> methods to apply a graph pass to a given `AIProgram` to compress weights. **While compressing a
> PyTorch model is the recommended path**, this maybe useful for testing and debugging."*

Apple is telling you this is the secondary path, and the reason is structural: the PyTorch-side
quantizer has module names, module types, a config hierarchy, calibration, QAT and per-block scoping.
The MLIR-side pass has a dtype, a granularity and a size threshold — it is uniform by construction.
Everything §13 argues for is unavailable here.

**When it is nonetheless the right tool:**

- **You do not have the PyTorch model.** Someone handed you an `.aimodel`.
- **You are measuring the size/quality frontier quickly** on a converted artefact without
  re-running conversion, which for a large model is minutes per iteration.
- **The compression must happen after a graph transformation** that the PyTorch-side pass would
  interfere with. This is exactly Apple's diffusion case, which is also §17.2's silent failure.

---

## 16. Export backends, and the CoreML restriction matrix

### 16.1 Three backends

> ✅ **VERIFIED** — §1.4's enum, with what each is for:
>
> | Backend | Purpose | Notes |
> |---|---|---|
> | `ExportBackend.CoreAI` | **the default**; produces the custom ops `coreai-torch` recognises | full dtype and granularity support |
> | `ExportBackend.CoreML` | `coremltools` compatibility | strictly smaller feature set — §16.2 |
> | `ExportBackend._TORCH` | keep it as a fake-quantized PyTorch model | the **only** backend that accepts dynamic quantization; finalize must be numerically exact here |

Every CoreML rejection carries the same closing sentence, which tells you Apple expects you to move:

> ✅ **VERIFIED** — `common.py:163-177`:
> ```python
> class CoreMLExportError(ValueError):
>     def __init__(self, message: str) -> None:
>         super().__init__(f"{message} Use backend=ExportBackend.CoreAI instead.")
> ```

### 16.2 What CoreML cannot do

> ✅ **VERIFIED** — `src/coreai_opt/_utils/export_utils.py:17-47`:
> ```python
> COREML_SUPPORTED_WEIGHT_DTYPES     = {torch.int8, torch.uint8, torch.int4, torch.uint4}
> COREML_SUPPORTED_ACTIVATION_DTYPES = {torch.int8, torch.uint8}
> COREML_SUPPORTED_LUT_DTYPES        = {torch.int8, torch.uint8}
> COREML_SUPPORTED_ACTIVATION_GRANULARITIES = {PerTensorGranularity}
> ```
> So on CoreML: **no FP4/FP8 anywhere, no int2/uint2 weights, no per-channel or per-block activation
> quantization, and no MINVAL formulation.** Palettization has an extra rule
> (`validate_coreml_palettization_compatibility`): **at most one of**
> `{cluster_dim > 1, lut_qspec, enable_per_channel_scale}` — combining two raises
> `CoreMLExportError("CoreML export does not support cluster_dim + lut_qspec on <ctx>. Use
> backend=ExportBackend.CoreAI instead.")`, because it *"hits an unsupported CoreML/MIL op configuration
> (mismatched tensor ranks, or `lut_to_dense` divisibility errors)."*
>
> ✅ **VERIFIED** — these checks were expanded in PRs #42 and #44; changelog fragment
> `changelog.d/42.fixed` = *"Reject per-channel activation quantization on CoreML export"*, with the
> maintainer note **"I verified that CoreML doesn't support per-channel activations"** (@guru-desh).
>
> ✅ **VERIFIED** — the CoreML pipeline shape, `docs/src/quantization/overview.md:54-69`:
> ```python
> finalized_model = quantizer.finalize(backend=opt.ExportBackend.CoreML)
> traced_model = torch.jit.trace(finalized_model, example_inputs)
> mlmodel = ct.convert(traced_model, convert_to="mlprogram",
>                      minimum_deployment_target=ct.target.iOS26)
> mlmodel.save("model.mlpackage")
> ```
> Note **`ct.target.iOS26`** — the CoreML path is the *back-deployment* path, and it is the reason
> `coreai-opt` still has one.

Practical reading: **choose your backend before you choose your numerics.** An FP8 activation config
is a CoreAI-only decision, and finding that out at `finalize()` after a QAT run is an expensive way
to learn it.

Two more CoreAI-only restrictions, gathered here so they are in one place:

> ✅ **VERIFIED** — **joint compression finalizes only to CoreAI** (§10.4). **KV-cache quantization is
> CoreAI-only** (§12); the CoreML branch raises `NotImplementedError`. And **`mmap_dir` is CoreAI +
> eager only** (§2.6).

### 16.3 One open CoreML bug worth knowing

> ✅ **VERIFIED** — coreai-opt **issue/PR #15, OPEN**: `Quantizer.finalize(backend=ExportBackend.CoreML)`
> crashes on a bare `nn.Linear` model. `_get_weight_input_names` splits the `get_attr` target on the
> last dot; a **root-module parameter has a dot-less target** (`weight`) →
> `ValueError: Invalid weight target path: weight`. The proposed fix returns `""` as the module name,
> since `named_modules()` has a `""` key.

If your minimal reproduction is a single `nn.Linear` and it fails on the CoreML backend, that is this
bug, not your config. Wrap the layer in a container module and it goes away.

---

## 17. ⚠️ Silent failures, consolidated

The defining property of this stack is that most defects do not throw. Here is every one this guide
has established, in the order you are likely to meet them.

### 17.1 Mis-sized blocks leave layers uncompressed

Covered in full at §7.5. Warning-only; the fake-quant node is then **deleted** from the prepared
graph. The only signals are a `logging.WARNING` and an artefact larger than you predicted.
**Detect:** pre-check divisibility, or promote the warning to an exception. **Never** trust a size
you did not compute.

### 17.2 Diffusion quantization failures are swallowed with a warning

> ⚠️ **SILENT FAILURE — you can ship a full-precision diffusion model believing it was compressed.**
>
> ✅ **VERIFIED** — `apple/coreai-models`, `export/compiler.py`. Unlike the LLM path (which compresses
> the PyTorch model *before* export), **diffusion quantizes after MLIR lowering**:
> `export/compiler.py:29`
> ```python
> async def apply_mlir_quantization(coreai_program, quantize_config) -> AIProgram
> ```
> which calls `coreai_opt.coreai_utils.quantize_weights(..., weight_num_threshold=32768,
> in_place=True)` (`:59-67`) — i.e. the §15 path.
>
> **And `:69-72` swallows the failure with a warning rather than raising it.** A `--compression 4bit`
> FLUX-class export whose quantization pass throws produces a successful export of an **fp16 model**.
>
> The research note that found it puts the consequence plainly: *"How would a user notice that a
> `--compression 4bit` export actually shipped fp16? **File size is the only signal.**"*
>
> 🔴 **GAP:** whether `metadata.json`'s `compression` block records the **attempted** or the
> **achieved** setting is **unverified**. If it records the attempted setting, then the bundle metadata
> actively confirms a compression that did not happen. **What would resolve it:** exporting a diffusion
> model with a deliberately invalid quantization config and reading the emitted `metadata.json`.
> **Safe default meanwhile:** **do not trust `metadata.json` as evidence of compression.** Verify by
> file size against the theoretical size from §7.2, and capture warnings during export:
> ```python
> import logging, warnings
> logging.basicConfig(level=logging.WARNING)
> with warnings.catch_warnings(record=True) as caught:
>     warnings.simplefilter("always")
>     path = export_model(config)
> for w in caught:
>     print("EXPORT WARNING:", w.message)
> ```

This is the same structural hazard as §17.1 wearing different clothes: a failure path that degrades
to "did nothing" instead of "raised".

Two related notes on the diffusion path, both verified, both worth knowing before you copy its
approach:

> ✅ **VERIFIED** — `apple/coreai-models`, `diffusion/presets.py`: `DEFAULT_COMPRESSION_PRESET =
> "none"` — Apple's own default is **no compression**. The `"4bit"` preset is
> `{"type": "int4", "symmetric": True, "granularity": "per_block", "block_size": 32}`.
> And: *"The VAE encoder/decoder is small and quality-sensitive, so it is **never quantized**"*,
> enforced by `ComponentSpec.quantizable: bool = False`.

"Small and quality-sensitive, so never compressed" — the same reasoning as the SAM3 detector, arrived
at independently, in a different modality, by the same team. That is about as strong a corroboration
of §13's method as this corpus can offer.

### 17.3 A shared weight can take its dtype from one config and its schedule from another

Covered at §11.5 (coreai-opt issue #41, OPEN). The eager-mode warning **mentions only the schedule,
not the dtype**. **Detect:** for any tied weight, assert that the resolved quant range matches what
you configured. **Avoid:** give every consumer of a shared weight identical specs and schedules.

### 17.4 fp16 casting can zero an activation, and compression makes it likelier

Covered at §14.4 (`apple/coreai-optimization#7`, OPEN, with maintainer answer). **Detect:** check for
unexpected zeros in outputs after *any* change to either the compression config or the casting step.
**Avoid:** substitute numerically stable op formulations in the PyTorch module — the sanctioned fix.

### 17.5 Per-channel activation granularity is silently downgraded around shared observers

Covered at §9.6. On 0.2.1 the downgrade is unconditional for channel-altering ops; on `main` it is
shape- and identity-aware and **logs at warning level**. Per-block activation granularity is
downgraded unconditionally in both. **Detect:** read the warnings; compare the realised bit-width to
the configured one.

### 17.6 A negative `axis` used to land on the wrong dimension

Covered at §8.5 (`coreai-torch` PR #24, MERGED 2026-07-08). The failure had **no shape error** when
the channel and its neighbour shared a size. **Avoid permanently:** write non-negative axes.

A second, still-open instance of the same class:

> ⚠️ **SILENT FAILURE (open).** ✅ **VERIFIED** — coreai-opt PR #45, **OPEN**:
> **`ChannelStructured(axis=-1)` prunes the wrong channels.** `_compute_channel_mask` compares each
> dim index against the raw axis; a negative axis never matches, so the per-channel L1 norms collapse
> to a scalar. With more than one channel kept it fails loudly with
> `RuntimeError: selected index k out of range` — but the failure mode with one channel is silent.
> (`PerChannelGranularity` already documents and resolves negative indexing, which is why the
> inconsistency is a bug.)

And a third, in the converter:

> ⚠️ **SILENT FAILURE (open).** ✅ **VERIFIED** — `coreai-torch` **PR #41, OPEN (fix unmerged as of
> 2026-07-29)**:
> `SubbyteTensor.__torch_dispatch__`'s `aten.cat` branch reads `dim` via `fill_defaults` but **never
> passes it**, so **every `cat` on a packed intx/uintx tensor runs on dim 0**. Two `(2,4)` tensors with
> `dim=1` give `(4,4)` instead of `(2,8)`, **silently**. Affects both `IntxTensor` and `UintxTensor`.
> File: `coreai_torch/_compression/_intx.py`.
>
> **Safe default:** avoid `torch.cat` on packed sub-byte tensors until this closes; concatenate before
> packing, or in the dense domain.

### 17.7 Eager-mode `finalize(CoreAI)` frees your float weights

Not silent, but irreversible and easy to walk into in eager mode with the Core AI backend (§2.5).
It is not the behavior of every backend or graph mode. `deepcopy` before `prepare()`.
[^destructive-finalize-scope]

### 17.8 A round-tripped config accepts `only_for` twice

Covered at §5.3. The guard lives in a private attribute excluded from serialisation. **Avoid:** one
`only_for` call, all targets, on a config built in-process.

### 17.9 The bar for shipping

Every one of these failures survives a successful export. Which means the only reliable acceptance
gate is **numerical comparison of the final artefact against the float reference on real inputs**:

> ✅ **VERIFIED** — `apple/coreai-models`, `skills/skills/working-with-coreai/references/guidance.md`,
> the PSNR acceptance table:
>
> | Scenario | Expected PSNR | Investigate below |
> |---|---|---|
> | float32 end-to-end | > 70 dB | 60 dB |
> | fp16 on-device | > 50 dB | 40 dB |
> | 4-bit palettized | ~40 dB | 30 dB |

Note what these compare: the *deployed artefact* against the *PyTorch reference*, not the prepared
model against the float model. Everything in §17 lives in the gap between those two comparisons.

There is a caveat on PSNR itself worth carrying, because it is the metric Apple's whole toolchain
defaults to:

> 🟠 **COMMUNITY-MEASURED** — `john-rocky/coreai-model-zoo` uses a different bar for LLMs — *"per-token
> cosine ≥ 0.999 **and** greedy token-exact"* — and observes that a **PSNR ≥ 40 dB "compiled vs torch"
> pass can coexist with flipped next-token argmax**. Single-author, uncontrolled; but the underlying
> point is arithmetic, not opinion: **PSNR is an average and argmax is a decision.** For any model
> whose output is a discrete choice, add a decision-level metric alongside PSNR.

---

## 18. Numbers, attributed

Every number here carries its source class. Nothing in this section is "known"; it is all measured by
someone, somewhere, on something.

### 18.1 ResNet-50, weight + activation PTQ — Apple-published

> ✅ **APPLE-PUBLISHED** — `coreai-opt` docs, `docs/src/examples/resnet50.md`. Evaluated on **128
> samples from imagenette**; **896 calibration samples**. Hardware, OS and package version not stated
> in the doc; the repo state is 0.2.x, 2026-06/07.
>
> | Config | Accuracy |
> |---|---|
> | FP32 baseline | 78.12% |
> | W_INT8(per-channel) A_INT8(per-tensor), `moving_average` | 74.22% |
> | same, but `global_minmax` activations | 75.78% |
> | W_FP8_E4M3 A_FP8_E4M3, `global_minmax` | **76.56%** |

Two readings, both actionable:

**`global_minmax` beat `moving_average` by 1.56 points**, on the same everything else. That is a
one-token config change (`qparam_calculator_cls="global_minmax"`) worth more than most architectural
fiddling. The mechanism is intuitive: the EMA's `averaging_constant=1e-2` default decays old
observations, so a rare large activation seen early gets forgotten; element-wise running min/max does
not forget.

**FP8 beat INT8 by 0.78 points at the same bit-width.** Same 8 bits, better accuracy, because the
exponent field handles a wide dynamic range that a uniform integer grid spends resolution on. If your
target is CoreAI (FP8 is unavailable on CoreML, §16.2) and your model has heavy-tailed activations,
FP8 is worth a run.

### 18.2 EDSR super-resolution — Apple-published

> ✅ **APPLE-PUBLISHED** — same docs, `docs/src/examples/edsr.md`. `edsr_r16f64`, 1.5M parameters,
> B100 benchmark, **20 calibration / 80 evaluation** samples.
>
> | Configuration | PSNR | Weight storage |
> |---|---|---|
> | FP32 baseline | 30.68 dB | ~5.5 MB |
> | W_INT8 A_INT8 | 30.33 dB (−0.35) | ~1.4 MB (4×) |
> | W_P4(INT8) A_INT8 joint | 29.86 dB (−0.47 more) | ~0.7 MB (8×) |

The shape of that table is the general shape of the trade: the **first** 4× is nearly free (−0.35 dB),
the **second** 2× costs more than the first 4× did (−0.47 dB for half the reduction).

### 18.3 ResNet-50 mixed-precision palettization — Apple-published

> ✅ **APPLE-PUBLISHED** — `docs/src/examples/mixed_precision_palettization.md`. ImageNet val (50k),
> `mps` backend.
>
> | Configuration | BPW | Size | Top-1 |
> |---|---|---|---|
> | FP16 baseline | 16 | 48.64 MB | 75.02% |
> | uniform 4-bit per-tensor | 4 | 12.16 MB | 65.87% |
> | greedy mixed precision (target 4) | **3.95** | 12.03 MB | **70.27%** |
>
> Recipe distribution: **2 layers at 6-bit** (`conv1`, `layer1.0.downsample.0`), **50 at 4-bit**,
> **2 at 2-bit** (`layer1.1.conv1`, `layer3.4.conv2`).
>
> And the observation about the curve: an inflection at ≈ **4.0 realised BPW** — *"below it, every
> additional 0.5 BPW buys us 15-35 percentage points of accuracy; above it, gains drop to 1-2 points per
> 0.5 BPW."*

**This is §13's argument in a published table.** A model at 3.95 average bits — *smaller* than the
uniform 4-bit model — scores **4.4 points higher**, because four layers out of fifty-four got
different treatment. Uniform compression was not just suboptimal; it was strictly dominated.

The inflection at 4.0 BPW is the most quotable number in the corpus for planning purposes. Above 4
bits you are spending size for very little; below 4 bits you are spending accuracy very fast. If you
have a size budget, target realised BPW just above 4 and buy the quality back with per-layer
exclusions.

### 18.4 SAM3 — Apple-published, WWDC26 session 325

> ✅ **APPLE-PUBLISHED** — session 325. Hardware stated only as "on-device" (a Mac for the notebook
> demo). 2026-06.
>
> | Configuration | Size | Quality |
> |---|---|---|
> | fp32 baseline | *"over 3 gigs"* | all flowers detected |
> | `presets.w4()` applied uniformly | *"around 430 megabytes"* (~7×) | **one occluded flower lost** |
> | detector excluded | *"a fraction of the size"* | *"once again reached baseline quality"* |

⚠️ Note the third row has **no number**. The talk says "a fraction of the size" and does not quantify
it. Do not repeat a figure for that configuration — there isn't one. What can be said: excluding a
block holding 4% of parameters can move the artefact by at most that block's share of the savings, so
the compressed size necessarily sits between 430 MB and roughly 430 MB + (4% of 3 GB × the fraction
of that 4% that was in compressible layers). That is a bound, not a measurement, and it should be
presented as such.

The companion latency number, for context, belongs to the *re-authoring* work rather than the
compression:

> ✅ **APPLE-PUBLISHED** — session 325:256: after splitting into three entrypoints and swapping only
> the text prompt, *"the **second inference is 76% faster, even after warmup**."* That is a
> consequence of the function split, not of compression — and see Part 10's note that Apple's own
> `CoreAISegmentationEngine` re-runs `image_encode` on every call and exposes no cache, so the figure
> requires caller-side work the shipped package does not do for you.

### 18.5 Toy model activation SNR — Apple-published

> ✅ **APPLE-PUBLISHED** — `docs/src/utils/activation_comparison.md:286-295`. A
> `Conv2d → ReLU → Linear` toy at default INT8, graph mode:
> ```
> conv_weight   -> activation_post_process_1  SNR = 47.17 dB
> conv_bias     -> conv_bias                  SNR = inf dB
> linear_weight -> activation_post_process_4  SNR = 48.13 dB
> x             -> activation_post_process_0  SNR = 43.20 dB
> conv2d        -> conv2d                     SNR = 42.40 dB
> relu          -> activation_post_process_2  SNR = 38.94 dB
> flatten       -> activation_post_process_3  SNR = 38.94 dB
> linear        -> activation_post_process_5  SNR = 35.74 dB
> ```

Read down the column: SNR **decreases monotonically with depth**, from 47 dB at the first weight to
35.7 dB at the output. Error accumulates. `conv_bias` at `inf` is the giveaway that biases are not
quantized (§4.2 — `op_state_spec={"weight": ...}` targets exactly one name).

`flatten` matching `relu` exactly at 38.94 dB is the shared-observer mechanism from §8.7 visible in
data: `flatten` is a `SharedObserverModulePattern`, so its input and output are the same
`FakeQuantize` object and therefore the same numbers.

🔴 **GAP — the API that produces this table is unverified.** `docs/src/utils/activation_comparison.md`
exists and the output above is quoted from it, but the function name and signature that generate it
were not read. **What would resolve it:** reading that doc page's code block, or
`make api-list MODULE=coreai_opt.inspection`. **Safe default meanwhile:** use
`coreai_torch.debugging.torch_utils.save_intermediates(...)` plus `load_intermediates(...)` — a
✅ **VERIFIED** pair with a published signature — and compute SNR yourself. That path is Part 10's
subject and it is what the Core AI Debugger consumes.

### 18.6 Community measurements — attributed, and to be treated as such

All of the following are from `john-rocky/coreai-model-zoo` and the associated fork of
`apple/coreai-models`. 🟠 **COMMUNITY-MEASURED.** This is single-author community work by GitHub user
`john-rocky` (Daisuke Majima), partly agent-generated, with **self-declared uncontrolled benchmark
conditions**. The measurements are often the only public numbers for these paths and they are
genuinely valuable — but they are **not Apple figures** and several of them internally disagree.

| Claim | Detail | Caveat |
|---|---|---|
| int8 k-means palettization reproduces HF top-1 **exactly** for Gemma 4 E2B and Qwen3.5 | *"at ~half the fp16 size"* | contradicted for MoE experts by the same corpus (§10.2) |
| linear int4 **and** k-means int4 both flip next-token argmax | *"int4 is a cliff, not a slope"* | Apple ships int4 for macOS LLMs anyway; different acceptance bar |
| Per-channel palettization beats per-channel quantization by **~15–19 dB** at 8- and 4-bit | *"Per-tensor palettization can be worse than per-channel quantization"* | no hardware/OS stated |
| `symmetric_with_clipping` adds **+7 dB** at int4; asymmetric adds **+3–5 dB** | at int8 the sym/asym gap is ~1.5 dB | corroborated in direction by Apple's own preset choice |
| Skipping boundary (first/last) layers can add **up to +9 dB** | *"always ablate"* | matches Apple's own type exclusions |
| ⚠️ **Per-channel (axis-0) int8 Linear weights are broken on the macOS-27-beta MPSGraph GPU delegate** | *"torch-level numerics are clean but the lowered matmul returns garbage"*; minimal head-only repro **2026-06-11**, multiple shapes, sym and clipping alike | **use per-block-32 there** — beta-era; re-test before relying on the workaround |

That last row is the one to act on. It is dated, reproducible per its author, and it has a concrete
workaround that costs almost nothing. It also explains a config choice you might otherwise find
strange: **Apple's own macOS LLM preset uses per-block-32, not per-channel** (§5.4). Whether that is
the reason is unverified — but the two facts sit together.

🔴 **GAP — none of these community numbers has been independently replicated in this corpus.** What
would resolve it: re-running the stated configurations on named hardware and OS builds. **Safe default
meanwhile:** use them to decide **what to test**, never to decide **what to ship**.

---

## 19. Quick reference

### 19.1 The five-line recipe

```python
from coreai_opt.quantization import Quantizer, QuantizerConfig
config = QuantizerConfig.presets.w8()            # or .w4(), or .w4_per_block(block_size=32)
q = Quantizer(model, config)
prepared = q.prepare((example_input,))           # tuple! representative if activations!
final = q.finalize()                             # backend=ExportBackend.CoreAI by default
final.eval()
```

### 19.2 API surface

```python
coreai_opt.__all__                       = CoreMLExportError, ExportBackend, __version__
coreai_opt.quantization.__all__          = ExecutionMode, InvalidExecutionModeError,
                                           ModuleQuantizerConfig, QuantizationSpec,
                                           Quantizer, QuantizerConfig
coreai_opt.quantization.config.__all__   = ExecutionMode, InvalidExecutionModeError,
                                           KVCacheQuantConfig, ModuleQuantizerConfig,
                                           OpQuantizerConfig, QATSchedule, QuantizerConfig
coreai_opt.quantization.spec.__all__     = DynamicQParamsCalculator, GlobalMinMaxQParamsCalculator,
                                           MinMaxRangeCalculator, MovingAverageQParamsCalculator,
                                           PerBlockGranularity, PerChannelGranularity,
                                           PerTensorGranularity, QParamsCalculatorBase,
                                           QuantizationComponentFactory, QuantizationFormulation,
                                           QuantizationGranularity, QuantizationScheme,
                                           QuantizationSpec, RangeCalculatorBase, RunningRangeMixin,
                                           StatefulQParamsCalculatorBase,
                                           StatelessQParamsCalculatorBase, StaticQParamsCalculator,
                                           default_activation_quantization_spec,
                                           default_weight_quantization_spec
coreai_opt.casting                       = cast_fp32_to_fp16, cast_int32_to_int16,
                                           cast_to_16_bit_precision
coreai_opt.coreai_utils.__all__          = CompressionGranularity, DType, palettize_weights,
                                           quantize_weights, sparsify_weights
```

> ✅ **VERIFIED** — all of the above, from the package `__init__` files. The project enforces this:
> `tests/test_api_visibility.py` asserts every public package declares `__all__`, that `__all__`
> contains no submodule names, and that every public symbol defined in a public module is re-exported
> by some package `__init__`. `make api-list [MODULE=…]` prints the whole public surface.

### 19.3 Decision table

| Question | Answer |
|---|---|
| Weight-only, exportable model? | `presets.w8()` / `w4()`, GRAPH (default) |
| Weight-only, awkward model? | same presets, `execution_mode=ExecutionMode.EAGER` |
| Activations too? | GRAPH, **must** calibrate, use representative `example_inputs` |
| Palettization or pruning? | EAGER — the only mode |
| Need `mmap_dir`? | EAGER + CoreAI |
| Need KV-cache quantization? | GRAPH + CoreAI |
| Need FP4/FP8? | CoreAI only |
| Need per-channel activations? | CoreAI only, and read §9.6 |
| Targeting `ct.target.iOS26`? | CoreML backend; check §16.2 first |
| Below 8 bits and quality slipped? | per-block evidence → exclude, then QAT (§13, §11) |
| Only have an `.aimodel`? | `coreai_utils.quantize_weights` (§15) |

### 19.4 The rules that prevent the failures

1. `example_inputs` is a **tuple**, and **representative** if any activation is quantized.
2. For eager Core AI export, `deepcopy` the float model before `prepare()`—that scoped
   `finalize()` path frees the originals.[^destructive-finalize-scope]
3. `None` disables; **omitting** applies defaults. They are not the same (§4.3).
4. `module_type_configs` keys are **fully qualified**, or pass the class object.
5. `module_name_configs` uses `re.fullmatch` — the pattern must cover the whole name.
6. Write **non-negative** axes.
7. Check block-size divisibility **before** trusting a size (§7.5).
8. Give shared/tied weights **identical** specs and schedules in every consumer (§11.5).
9. Compress first, cast to fp16 second (§14.3).
10. `.eval()` the finalized model (§2.4).
11. Score the **artefact** against the float reference on **real inputs**, not the prepared model
    against itself (§17.9).
12. Never compare a graph-mode result to an eager-mode result (§8.3).

### 19.5 Consolidated footguns

| # | Footgun | § |
|---|---|---|
| 1 | `example_inputs` must be a tuple; empty raises | 2.2 |
| 2 | Activation quantization needs representative data, not `randn` | 2.2 |
| 3 | `prepare()` mutates in place; re-preparing raises | 2.3 |
| 4 | Block-size mismatch **silently disables** the layer | 7.5 |
| 5 | `None` vs omitted in configs | 4.3 |
| 6 | `module_type_configs` needs fully-qualified names; `torch.nn.Linear` matches nothing | 5.2 |
| 7 | `only_for` cannot be chained (but survives a YAML round trip) | 5.3 |
| 8 | Configs are `@final`; specs are frozen — use `model_copy(update=…)` | 4.4 |
| 9 | Activation per-channel/per-block needs an explicit axis, and may be downgraded anyway | 7.4, 9.6 |
| 10 | Per-block activation granularity around a shared observer is **always** downgraded | 9.6 |
| 11 | CoreML: no FP4/FP8, no int2, no per-channel activations, no MINVAL | 16.2 |
| 12 | Joint compression finalizes only to CoreAI | 10.4 |
| 13 | Eager-mode `finalize(CoreAI)` frees dense weights, irreversibly[^destructive-finalize-scope] | 2.5 |
| 14 | `mmap_dir`: eager + CoreAI + CPU + empty dir, files must outlive the model | 2.6 |
| 15 | Dynamic quantization cannot be exported — `_TORCH` only | 6.5 |
| 16 | `step()` outside `training_mode()` raises; `_step_count` never resets | 11.3 |
| 17 | QAT schedules and the manual enable/disable APIs are mutually exclusive | 11.4 |
| 18 | `training_mode()` is not re-entrant | 11.3 |
| 19 | Prepared and finalized are not bit-identical for Conv+BN in graph mode | 9.4 |
| 20 | `fx.GraphModule.train()/.eval()` only affects dropout and batchnorm | 2.4 |
| 21 | `NAryActPattern` chains longer than 2 are unsupported; op types must be unique | 8.7 |
| 22 | Graph mode rejects non-`"*"` string keys and non-`{"*", 0}` output keys | 8.6 |
| 23 | Deprecated names still work with warnings: `ExportBackend.MIL/MLIR`, `ExecutionMode.PT2E` | 1.4, 8.1 |
| 24 | torchao < 0.16.0 needs kwargs stripped around `prepare_qat_pt2e` (handled internally) | 8.5 |
| 25 | A C++ toolchain is a **runtime** requirement (palettization's JIT kmeans1d) | 1.4 |
| 26 | `palettize_weights`' `lut_dtype` is positional #2 with no default | 15.1 |
| 27 | bfloat16 paths were patched three separate times — newer, less battle-tested | 20 |

### 19.6 Dev commands

> ✅ **VERIFIED** — `Makefile`:
> ```bash
> make env                        # .venv with dev + coreai + coreml groups
> make env-lowest-torch           # torch 2.8 ;  make env-highest-torch → torch 2.11
> make check                      # pre-commit: ruff, mypy, license headers, mdformat, …
> make test-fast                  # marker 'not slow' ;  make test-slow ;  make test-smoke
> make api-list MODULE=coreai_opt.quantization.spec.spec
> make docs / docs-open
> ```
> Two exported environment variables worth knowing:
> - **`USE_LOCAL_COREAI ?= 1`** — *"Tell coreai's runtime to skip the symbol-version check against the
>   host's installed `/System/Library/Frameworks/CoreAI.framework`. Required when the precompiled coreai
>   wheel was built against a newer SDK than what's on the host — without this, importing `coreai_torch`
>   aborts at dlopen time with a Swift `Symbol not found` error."*
> - **`TORCH_GROUP ?= $(HIGHEST_TORCH_GROUP)`**
>
> ✅ **VERIFIED** — and the uv rule from the repo's own `AGENTS.md`: *"Always pass `--no-sync` to
> `uv run`: `uv run --no-sync --active …`. `uv run` implicitly syncs the active project to its
> default-groups before running, which re-resolves dependencies and **can clobber a venv's
> group-pinned packages**."*

---

## 20. Sources and evidence ledger

### 20.1 What was read, and how strongly it counts

**Class 1 — shipped source on disk (strongest evidence available for this topic).**

`apple/coreai-optimization`, local clone, branch `main`, HEAD **`cd95cb2`** *("fix: try per-channel
act quant for shared observers but fall back to per-tensor if unsafe (#52)")*. 29,337 Python LOC
under `src/`. Files read in-session and cited above:

- `src/coreai_opt/{__init__,_about,common,base_model_compressor}.py`
- `config/compression_config.py`, `config/spec/{base,compression_simulator,factory}.py`
- `quantization/{quantizer,base_quantizer,_axis_defaults}.py`
- `quantization/config/quantization_config.py`, `config/_presets/*`
- `quantization/spec/{spec,granularity,qscheme,qformulation,qparams_calculator,range_calculator,fake_quantize,errors}.py`
- `quantization/_graph/{quantizer,_utils,_annotation_pattern_registry,_prepare_for_export}.py`
- `quantization/_eager/{quantizer,supported_ops_registry}.py`
- `palettization/**`, `pruning/**` (for the comparisons in §1.3 and §10.4)
- `casting/__init__.py`, `inspection/model_inspector.py`
- `coreai_utils/{__init__,common}.py`, `coreai_utils/passes/{weight_quantization,weight_palettization,weight_sparsification}.py`
- `_utils/{export_utils,torch_utils}.py`
- `pyproject.toml`, `Makefile`, `AGENTS.md`, `CHANGELOG.md`, `changelog.d/*`, `.github/workflows/ci.yaml`
- `tests/{test_smoke,test_joint_compression,test_api_visibility}.py`,
  `tests/quantization/test_kv_cache_quantization.py`
- `git log --oneline -50`, `git show cd95cb2`

`apple/coreai-models`, local clone — for the shipping recipes, the presets and the SAM3 pipeline:
`export/presets.py`, `export/pipeline.py`, `export/compiler.py`, `diffusion/presets.py`,
`segmentation/pipeline.py`, `models/sam3/README.md`, `llm/export.py`.

**Class 2 — Apple's own agent skills** (`apple/coreai-models/skills/skills/`). Apple engineers'
empirical rules, written for machine consumption. Three skills: `working-with-coreai`,
`model-authoring`, `model-compression-exploration`. The compression skill's sweep design, the PSNR
acceptance tables, the bit-width sizing bands and the `check_divisibility` guidance all come from
here.

**Class 3 — `coreai-opt` documentation** (`docs/src/`): `landing_page.md`,
`introduction/{installation,how_to_use_coreaiopt,integration_coreai}.md`,
`quantization/{index,basics,overview,config,advanced}.md`,
`utils/{joint_compression,mixed_precision,casting,coreai_compression,activation_comparison}.md`,
`debugging/{model_inspection,graph_mode_troubleshooting}.md`,
`examples/{toy_models,resnet50,edsr,mixed_precision_palettization}.md`.

**Class 4 — GitHub issues and PRs** on `apple/coreai-optimization` and `apple/coreai-torch`, including
several with Apple-maintainer answers (#3, #7, #16, #42/#44). Issue numbers, states and dates as of
2026-07-29.

**Class 5 — WWDC26 session 325**, *"Dive into Core AI model authoring and optimization"* (Sachin,
Core AI; Nicole, Core AI Debugger). Every `325:NN` citation is a transcript line reference. Used for
narration, framing and the SAM3 story; **never** used alone for a signature.

**Class 6 — community, always labelled.** `john-rocky/coreai-model-zoo` and the associated fork of
`apple/coreai-models`, by GitHub user `john-rocky` (Daisuke Majima). Partly agent-generated,
**self-declared uncontrolled benchmarks**. Unique primary measurements; never presented as Apple
figures. Every appearance in this guide is marked 🟠 **COMMUNITY-MEASURED**.

**Not used as evidence:** anything from model memory. There is no Apple sample-code project for Core
AI to check against — verified: **0 `sampleCode` entries across 312 indexed Core AI symbols**, and
`/documentation/updates/coreai` 404s.

### 20.2 Where sources disagreed, and how this guide ruled

| Conflict | Ruling |
|---|---|
| Session 325: *"EAGER works great for weight compression"* vs the repo: GRAPH is the *"recommended default"* and the actual default | **Both true, different scopes.** For weight-only the modes converge and EAGER avoids `torch.export`; for activations GRAPH's machinery is load-bearing. §8.4 gives the decision table. |
| Session 325: *"4-bit palettization to **the two encoders**"* vs shipped SAM3: image **w4/gs32**, text **w6/gs8** | **Shipped source wins.** The talk simplified. Both quoted, §13.6. |
| Session 325: *"4-bit palettization **with per-channel scales**"* vs shipped SAM3: `enable_per_channel_scale=False` deliberately | **Shipped source wins**, and the reason is a hardware limit worth its own callout: rank-6 LUTs, ANE max rank 5, silent GPU fallback. §13.6. |
| `cast_to_16_bit_precision`: *"mutates in place, returns nothing meaningful"* (API notes, and Apple's docs call it as a statement) vs `-> ExportedProgram` and Apple's shipping pipeline **assigning** the result | **Unresolved; declared as a 🔴 GAP.** Safe default given: **assign the result**, which is correct under both readings and is what Apple's own pipeline does. §14.2. |
| `coreai_utils.QScheme`: absent from package `__all__` but imported from the package in Apple's docs | **Unresolved; declared as a 🔴 GAP.** Safe default: import from `coreai_opt.coreai_utils.common`. §15.1. |
| Community: *"int4 flips next-token argmax; int8 is the floor"* vs Apple shipping **int4** as the macOS LLM default | **Both stand.** Different acceptance bars — "matches HF greedy argmax" is not "is a good assistant". §10.2 states both and refuses to pick. |
| Community: int8 **k-means** is exact for dense projections vs the same corpus: **symmetric linear int8** is clean and k-means lossier for MoE experts at top-k ≥ 4 | **Both stand, do not flatten.** Synthesis given: int8 is the safe floor; *which* int8 is tensor-role- and routing-dependent. §10.2. |
| Apple docs use `weight_num_threshold=2048` in "advanced" examples; the code default is **1024**; Apple's diffusion export uses **32768** | No conflict — all three are deliberate. Stated as such. §15.2. |

### 20.3 Declared gaps — nothing is guessed inside any of these

| # | Unknown | What would resolve it | Safe default meanwhile |
|---|---|---|---|
| 1 | `mmap_dir` on-disk layout, safetensors filenames, sharding | `finalize(mmap_dir=d)` then `ls d`; or read `_utils/export_utils.py` in full | Treat as opaque; fresh `TemporaryDirectory` per export, kept alive exactly as long as the model (§2.6) |
| 2 | Whether `cast_*` returns a new program or mutates and returns the same one | Read `casting/casting.py`, or `print(cast_to_16_bit_precision(ep) is ep)` | **Assign the result and never touch the input again** (§14.2) |
| 3 | The exact FP16 threshold constant and node-level heuristics in the casting pass | Read `casting/casting.py` | Trust the docs' *"approximately ±65504"* only as an order of magnitude; test for zeros (§14.4) |
| 4 | Whether `QScheme` is importable from `coreai_opt.coreai_utils` | One import in a REPL | `from coreai_opt.coreai_utils.common import QScheme` (§15.1) |
| 5 | The API that produces the activation-comparison SNR table | Read that doc page's code block; `make api-list MODULE=coreai_opt.inspection` | `coreai_torch.debugging.torch_utils.save_intermediates` / `load_intermediates` — verified signatures, Part 10 (§18.5) |
| 6 | `ModelInspector.format_summary(colorize=…)` — the kwarg name | Read `inspection/model_inspector.py` | Call `format_summary()` with no arguments |
| 7 | Whether diffusion `metadata.json` records the **attempted** or **achieved** compression | Export with a deliberately invalid quantization config and read the emitted metadata | **Do not trust metadata as evidence of compression**; verify by size (§17.2) |
| 8 | The exact logger name `coreai_opt` emits skip warnings on | `logging.getLogger("coreai_opt")` and check for records | Attach the handler to the **root** logger (§7.5) |
| 9 | `check_divisibility()`'s real signature in Apple's `compression_metrics.py` | Read that file | The reimplementation in §7.5, written from the documented rule |
| 10 | Whether `coreai-torch 0.4.1` / `coreai-core 1.0.0b2` map to specific Xcode or macOS builds | Apple release notes, or a version probe on a known build | Pin exactly what `coreai-opt[coreai]` pins; the only OS hint in the repo is the CI runner label `tahoe` |
| 11 | k-means initialisation and convergence criteria (max iters, tolerance) | Read `_efficient_kmeans.py` and `deps/_kmeans1d/_core.cpp` | Seed numpy and torch, and use `num_workers=1`, if you need determinism |
| 12 | How int4/int2 weights are physically packed on disk | Lives in `coreai-torch` / Core AI, not here — Part 8 | Compute expected size from the §7.2 formula and compare |
| 13 | The size of the detector-excluded SAM3 asset | Apple did not publish it | Quote the bound, not a number (§18.4) |
| 14 | Whether block-granularity **activation** quantization will ship | PR #56 merging and appearing in a release | Per-tensor activations (§9.6) |

### 20.4 Freshness caution

This is young code and it is moving.

> ✅ **VERIFIED** — the repository has roughly **35 commits** since `e27b3d0 chore: initial commit`.
> Version 0.2.1 is dated **2026-07-02**; the HEAD read for this guide is **2026-07-24**. The project
> classifier is `Development Status :: 3 - Alpha`.

Signals worth carrying:

- **bfloat16 was patched three separate times** (`4df45c0`, `859d7c9`, `f6baedf`) — bf16 paths are the
  newest and least battle-tested in the package.
- **CoreML export tests were previously skipped due to a segfault** (`61d7084`) and an eager
  int8-activation failure (`1001e57`). Both now pass, which means both once did not.
- **Four unreleased changelog fragments** sat in `changelog.d/` at HEAD: `52.fixed` (shared-observer
  per-channel activation), `42.fixed` (reject per-channel activations on CoreML), `31.changed`
  (coremltools removed), `180525445.fixed` (fixed-range op qscheme). None of them are in 0.2.1.
- **PR #40**, an open +2326/−523 rewrite of graph-mode annotation, will change how config conflicts
  resolve. If your model concatenates fixed-range and floating-range activations, that area is sharp
  today (§9.5).
- Full-suite scale as of June 2026: **4529 passed, 1417 skipped, 567 xfailed, 7 xpassed** in ~30
  minutes. The skip and xfail counts are large, and several of the gaps in §20.3 correspond to them.

**Before you rely on anything in this guide, check `__version__`:**

```python
import coreai_opt
print(coreai_opt.__version__)     # this guide: 0.2.1, plus main @ cd95cb2 where marked
```

### 20.5 Cross-links

- **Part 8 — Core AI: converting from PyTorch.** `torch.export`, `get_decomp_table()`,
  `TorchConverter`, `optimize()`, `save_asset()`. Everything downstream of `finalize()`.
- **Part 9, other references.** Palettization (`KMeansPalettizer`, sensitive k-means, the LUT
  formats), pruning, and the numeric-format reference (int2/4/8, FP4/FP8, MXFP4 and the E8M0 scale
  story).
- **Part 10 — hardware authoring, debugging, LLM deployment.** The Core AI Debugger, sync points,
  `save_intermediates` / `load_intermediates`, the NaN/Inf validator, and the Neural Engine authoring
  rules that make §13.6's rank-5 constraint make sense.
- **Part 11 — Metal and TensorOps.** Where low-bit operands execute; OS 27’s native E8M0 auxiliary
  scale-plane path; and the cooperative-tensor hand-dequantization fallback for 26.x or custom
  formats.[^xcode27-scale-planes]
- **Part 15 — shipping and operating.** Size budgets (iOS: keep models under 2 GB; macOS: leave at
  least 6 GB of RAM headroom — both ✅ **VERIFIED** from Apple's `working-with-coreai` skill), and the
  measurement discipline that makes the compression trades in this guide decidable.

[^xcode27-scale-planes]: Apple documents the OS 27 API in
    [`MTLTensorAuxiliaryPlaneDescriptor`](https://developer.apple.com/documentation/metal/mtltensorauxiliaryplanedescriptor),
    [`MTLTensorDescriptor.auxiliaryPlanes`](https://developer.apple.com/documentation/metal/mtltensordescriptor/auxiliaryplanes), and
    [`MTLTensorDataType`](https://developer.apple.com/documentation/metal/mtltensordatatype); the
    authoritative [WWDC26 session 330 transcript](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/transcripts/wwdc2026-330.txt#L53-L78)
    distinguishes automatic dequantization from the custom-format cooperative-tensor fallback.

[^destructive-finalize-scope]: The pinned `coreai-optimization` source limits dense-weight freeing
    to `ExportBackend.CoreAI` in eager quantization:
    [`Quantizer.finalize`](https://github.com/apple/coreai-optimization/blob/cd95cb2545a586dbc14c85f5efd16b4635e5786c/src/coreai_opt/quantization/quantizer.py#L435-L482).
