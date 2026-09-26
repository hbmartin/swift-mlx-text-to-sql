# `torch.export` to `.aimodel`, and the IO / state / dynamic-shape contract

**Part 8 · Core AI: converting from PyTorch · Reference 01**

**Version floor.** The Core AI *runtime* you are producing an artifact for is **27.0 and only 27.0** —
`AIModel`, `AIModelAsset`, `InferenceFunction`, `NDArray`, `SpecializationOptions` and
`ComputeUnitKind` are all documented as *"Available on: iOS 27.0+ Beta, iPadOS 27.0+ Beta,
Mac Catalyst 27.0+ Beta, macOS 27.0+ Beta, tvOS 27.0+ Beta, visionOS 27.0+ Beta, watchOS 27.0+ Beta."*
Nothing here back-deploys to 26.x. On the Python side the floor is **Python 3.11**, **PyTorch 2.8.0**
(validated up to 2.13.0), **`coreai-torch` 0.4.1** and its exact pin **`coreai-core==1.0.0b2`**;
`apple/coreai-models` additionally requires **macOS/iOS 27.0+ and Xcode 27.0+**. And one hard gate you
must read before anything else: **`.aimodel` assets converted with `coreai-torch` v0.4.0 fail to
load or specialize on device from OS 27 beta 2 onward** — §2.3 covers both the reconvert and the
no-reconvert recovery.

> ⚠️ **Core AI has zero Apple sample-code projects.** Verified: 0 `sampleCode` entries across all 312
> indexed Core AI symbols, and `/documentation/updates/coreai` 404s. Unlike Parts 1–6, there is no
> first-party compiling reference project to check a signature against. The strongest evidence in
> this guide is, in order: source files in the shipped repos (`apple/coreai-torch`,
> `apple/coreai-models`, `apple/coreai-optimization`), **Apple's own agent skills** vendored in
> `apple/coreai-models/skills/`, the package documentation, Apple-staff answers on the repos' issue
> trackers, and WWDC26 session 325. Every signature below carries its evidence marker and its file.

---

## What this covers

Five lines of Python turn a `torch.nn.Module` into an on-device artifact:

```python
ep = torch.export.export(model, args=(torch.randn(1, 3, 224, 224),))
ep = ep.run_decompositions(get_decomp_table())
converter = TorchConverter().add_exported_program(ep)
program = converter.to_coreai()
program.optimize()
```

Those five lines are strictly sequential, each one has a failure mode, and **three of the five fail
silently** — they produce an artifact that loads, runs, returns tensors of the right shape, and is
wrong or slow. This guide is about the contract each line establishes.

- **§3–§4** — `torch.export` and the decomposition table. Why `get_decomp_table()` exists, exactly
  which twelve ops it preserves (the README's "three" is a subset — §4.2), and the precise boundary
  between the loud failure (skipping decomposition entirely) and the silent one (using PyTorch's
  default table and quietly losing the fast attention path).
- **§5** — the two input forms. `add_exported_program()` for a decomposed `ExportedProgram`, versus
  `add_pytorch_module()` — which is the *only* door to externalization and composite-op marking, and
  which session 325 never mentions.
- **§6** — `to_coreai()` is a pure conversion; `optimize()` is where the passes run. What it folds,
  with before/after IR. And the currently-open bug where it deletes a broadcasting-significant axis
  move and silently miscompiles an entire class of expression.
- **§7** — **the IO contract.** `input_names` / `output_names` are the dictionary keys your Swift or
  Python caller types. Omit them and you inherit FX placeholder names, which Apple's own
  documentation says are *not a stable PyTorch contract*.
- **§8** — `dynamic_shapes=` on `torch.export`, so a traced sequence length does not get baked into
  the asset, plus the SymInt sharp edges that are specific to this converter.
- **§9** — `state_names=`: mutable buffers and in-place-mutated inputs become Core AI *states*, with
  no opt-out, in an order that is itself an observed-behaviour assumption.
- **§10** — multi-function assets: one `TorchConverter`, N exported programs, N entrypoint names.
  Session 325 sells this as a latency trick. Apple's optional `coreai-models` Swift loader also uses
  recognized entrypoint sets to select **that package's** Neural Engine preference; direct Core AI
  callers choose their own specialization options.[^sample-routing-policy]
- **§11** — the Python-side verification gate: load both models, run the same input, assert a small
  delta. Core AI specializes and runs natively from Python via a `name -> numpy` dict, so this costs
  you nothing and catches every silent failure in this guide.
- **§12** — why the converter preserves source locations and PyTorch module stacks, and the causal
  link from that metadata to the Core AI Debugger's source viewer and group-by-module navigator.

## What this does *not* cover

- **Compression.** `coreai-opt` (`Quantizer`, `KMeansPalettizer`, presets, calibration, QAT) is Part 9.
  This guide converts an already-compressed-or-not module; it never quantizes one.
- **Custom lowerings, `TorchMetalKernel`, and model re-authoring for the ANE.** Part 10.
- **The Swift side of the artifact** — `AIModel`, `InferenceFunction.run`, states, `MutableViews`,
  `ComputeStream`. Part 7.
- **`coreai-build`**, the ahead-of-time compiler that turns `.aimodel` into `.aimodelc`. Part 15.

## What you need

```bash
pip install coreai-torch          # installs BOTH `coreai` and `coreai-torch`
# or, from a checkout of apple/coreai-torch:
uv sync
```

> ✅ **VERIFIED** — `apple/coreai-torch/README.md:20–28`, and WWDC26 session 325 line 31:
> *"Installation is simple with `pip install coreai-torch`, this installs both the `coreai` package
> and the `coreai-torch` library building on top of it."*

A Mac with Apple silicon if you want to *run* what you convert from Python (`SpecializationOptions`
is documented **macOS only**). Conversion itself is portable, but `coreai-core` publishes **macOS
wheels only** — cp311/cp312 at first, cp313 added in `1.0.0b2` — and there are **no linux/arm64
wheels**, so Linux containers must run `--platform linux/amd64`.

---

## Contents

1. [The five lines, and what each one is for](#1-the-five-lines-and-what-each-one-is-for)
2. [Install, versions, and the 0.4.0 artifact gate](#2-install-versions-and-the-040-artifact-gate)
3. [`torch.export` — the part that is not Apple's](#3-torchexport--the-part-that-is-not-apples)
4. [`run_decompositions(get_decomp_table())` — the most consequential line](#4-run_decompositionsget_decomp_table--the-most-consequential-line)
5. [Two input forms: `add_exported_program` vs `add_pytorch_module`](#5-two-input-forms-add_exported_program-vs-add_pytorch_module)
6. [`to_coreai()` and `optimize()`](#6-to_coreai-and-optimize)
7. [The IO contract: names are your caller's API](#7-the-io-contract-names-are-your-callers-api)
8. [Dynamic shapes: keeping the traced length out of the asset](#8-dynamic-shapes-keeping-the-traced-length-out-of-the-asset)
9. [State: mutable buffers become Core AI states](#9-state-mutable-buffers-become-core-ai-states)
10. [Multi-function assets, and the finding that reframes them](#10-multi-function-assets-and-the-finding-that-reframes-them)
11. [Verifying from Python: the gate you must not skip](#11-verifying-from-python-the-gate-you-must-not-skip)
12. [Locations, module stacks, and the Debugger](#12-locations-module-stacks-and-the-debugger)
13. [Failure taxonomy and quick reference](#13-failure-taxonomy-and-quick-reference)
14. [Sources and evidence ledger](#14-sources-and-evidence-ledger)

---

## 1. The five lines, and what each one is for

Here is the canonical pipeline, verbatim from Apple's README:

> ✅ **VERIFIED** — `apple/coreai-torch/README.md:45–60`:
>
> ```python
> import torch
> from coreai_torch import TorchConverter, get_decomp_table
>
> model = ...  # your nn.Module
> model.eval()
>
> # Export and decompose — this is your responsibility
> ep = torch.export.export(model, args=(torch.randn(1, 3, 224, 224),))
> ep = ep.run_decompositions(get_decomp_table())
>
> # Convert to Core AI IR
> converter = TorchConverter().add_exported_program(ep)
> coreai_program = converter.to_coreai()
> coreai_program.optimize()
> ```

Read the comment on line 3 of that snippet again: **"this is your responsibility."** That is not
boilerplate politeness. `coreai-torch` does not call `torch.export` for you in this form, does not
call `run_decompositions` for you, and does not optimize for you. Each of those is a separate
decision with a separate contract, and the package's own validator exists precisely because
developers were arriving with programs that had skipped one.

There is a **sixth** line every real pipeline has, which the README snippet omits because it belongs
to a different package:

```python
asset = coreai_program.save_asset(Path("MyModel.aimodel"))
```

> ✅ **VERIFIED** — `docs/coreai-core/tutorials/construct-a-graph.ipynb`:
> *"`AIProgram.save_asset(path)` writes the program out as an `.aimodel` directory — a small bundle
> containing the program bytecode plus a `metadata.json` file."*
>
> Note **directory**. An `.aimodel` is a bundle, not a single file; Finder and Xcode present it as
> one. `save_asset` lives on `AIProgram`, which comes from `coreai.authoring` — **not** from
> `coreai-torch`. As of `coreai-core 1.0.0b2` it also *"records the producer in asset metadata,
> overwrites an existing serialized model instead of failing, and **validates that the destination
> has a `.aimodel` extension**."* (`coreai-core 1.0.0b2` changelog, bundled in the `coreai-torch`
> v0.4.1 release page.)

### 1.1 What each stage owns

| Stage | Owned by | Fails how | Section |
|---|---|---|---|
| `torch.export.export(...)` | PyTorch | Loudly — `torch.export` raises on unsupported constructs | §3 |
| `.run_decompositions(get_decomp_table())` | You, using Apple's table | **Loudly if skipped, silently if you use the wrong table** | §4 |
| `TorchConverter().add_*(...)` | `coreai-torch` | Loudly — eager validation with actionable messages | §5 |
| `.to_coreai()` | `coreai-torch` | Loudly — `ValueError` on unsupported ATen ops | §6.1 |
| `.optimize()` | `coreai-core` | **Silently, in one known open case** | §6.4 |
| `.save_asset(path)` | `coreai-core` | Loudly — extension validation, overwrite is fine | §1 |

Three of the six are silent-capable. That ratio is the reason this part of the series exists.

### 1.2 There is no `convert()` function, and no conversion CLI

> ✅ **VERIFIED** — there is **no** `convert()` function in `coreai-torch`. The entry point is the
> `TorchConverter` **class**. Its full public surface, from `coreai_torch/__init__.py`:
>
> ```python
> __all__ = [
>     "__version__",
>     "ExternalizeSpec",
>     "MetalParameter",
>     "TorchConverter",
>     "TorchMetalKernel",
>     "get_decomp_table",
>     "generate_composite_decl",
> ]
> ```
>
> Seven names. That is the whole documented top-level API.

> 🔴 **KNOWN-BAD CLAIM — there is no `coreai-torch convert` command-line tool.** The package ships
> **no `[project.scripts]` entry points at all**. The two CLI-ish things in the repo, `tools/graphdiff`
> and `tools/freqop`, are plain scripts you invoke as `python tools/graphdiff/graphdiff.py …`, and
> both *consume* `.aimodel` assets rather than producing them. Conversion is a Python API, full stop.
> The only Apple-shipped Core AI command-line tool is `xcrun coreai-build`, which is an
> **ahead-of-time compiler** (`.aimodel` → `.aimodelc`), not a converter. If a blog post or an agent
> hands you `coreai-torch convert model.pt`, it is fabricated.
>
> Two more spellings in circulation that do not exist anywhere in this stack: **`.coreaimodel`** and
> **`.aiasset`**. The extension is `.aimodel` (source asset) or `.aimodelc` (AOT-compiled).

### 1.3 The mental model Apple's own agent skill teaches

Apple vendors three agent skills in `apple/coreai-models/skills/`. The top-level one,
`working-with-coreai`, states the pipeline as five steps — and this is worth internalising because it
tells you which of your problems belong to which guide:

> ✅ **VERIFIED** — `apple/coreai-models/skills/skills/working-with-coreai/SKILL.md`:
>
> ```text
> 1. AUTHOR        Re-structure model for target platform
>                   → Skill("coreai-skills:model-authoring")
> 2. COMPRESS      Explore quantization/palettization tradeoffs
>                   → Skill("coreai-skills:model-compression-exploration")
> 3. EXPORT        Convert PyTorch → AIProgram via TorchConverter
>                   → coreai-torch docs
> 4. COMPILE       Ahead-of-time compilation for target platform
>                   → coreai-build CLI
> 5. RUN           Load and run on device (Swift or Python)
>                   → CoreAI framework / coreai Python API
> ```
>
> with the note: *"Steps 1 and 2 are optional — many models export directly without re-authoring or
> compression. **Start with export**, then add authoring or compression if needed (poor accuracy,
> poor performance, too large)."*

This guide is step 3, plus the parts of step 5 you do from Python to prove step 3 worked. Apple's own
advice — start at export, add the other steps only when a measurement tells you to — is good advice,
and it is the reason §11's verification gate comes before any tuning.

---

## 2. Install, versions, and the 0.4.0 artifact gate

### 2.1 The two packages, three import names

| Distribution | Import name | What it is |
|---|---|---|
| `coreai-torch` | `coreai_torch` | The PyTorch → Core AI IR converter. This guide. |
| `coreai-core` | `coreai` | Runtime + authoring + the private compiler. Pulled in automatically. |
| `coreai-opt` | `coreai_opt` | Compression: quantization, palettization, pruning, fp16 casting. Part 9. |

> ✅ **VERIFIED** — `pyproject.toml` of `coreai-torch` 0.4.1:
>
> ```toml
> [project]
> name = "coreai-torch"
> requires-python = ">=3.11"
> dependencies = [
>     "coreai-core==1.0.0b2",
>     "ml-dtypes", "networkx", "numpy", "packaging", "scipy", "sympy",
>     "torch>=2.8.0",
>     "typing-extensions", "strenum", "rich>=13.0,<16.0",
> ]
> ```
>
> Note `coreai-core==1.0.0b2` is an **exact pin to a beta**. `deptry` in the same file maps the
> distribution to its import name explicitly:
> `package_module_name_map = { "coreai-core" = "coreai" }`.

### 2.2 The PyTorch version window

There is no upper bound on `torch` in the dependency list, but there is a runtime warning:

> ✅ **VERIFIED** — `coreai_torch/__init__.py:32–39`:
>
> ```python
> _TORCH_MAX_VERSION = "2.13.0"
>
> if _Version(_torch_version) > _Version(_TORCH_MAX_VERSION):
>     _warnings.warn(
>         f"coreai-torch has only been validated with torch<={_TORCH_MAX_VERSION}; "
>         f"found torch {_torch_version}. Some functionality may not work as expected.",
>         stacklevel=2,
>     )
> ```
>
> Introduced by commit `ef1181b` *"Allow newer versions of PyTorch than we have verified."* — the pin
> used to be hard. The test extra pins `torch==2.13.0`, `torchvision==0.28.0`, `torchaudio==2.11.0`,
> `transformers==4.57.3`.

**Practical window:** 2.8.0 ≤ torch ≤ 2.13.0 is validated; above 2.13.0 you get a warning and are on
your own. Real bug reports in the tracker run on torch 2.9.0 and 2.11.0, Python 3.11.15 and 3.12.13.

The `coreai-opt` CI (a sibling repo, so a decent proxy for what Apple actually exercises) tests
**PyTorch 2.8, 2.9, 2.10 and 2.11**.

### 2.3 ⚠️ The version gate that invalidates already-published assets

This is the single highest-consequence version fact in Part 8, and it is easy to hit if you started
during an earlier beta.

> ✅ **VERIFIED** — `coreai-torch` v0.4.1 release notes, verbatim:
>
> > **".aimodel artifacts converted with coreai-torch v0.4.0 will fail to load/specialize on-device
> > starting with OS 27 second beta onwards. Reconvert your model using coreai-torch v0.4.1 or later
> > to produce a compatible artifact."**
>
> Corroborated by maintainer **@gokulkrishna98** on `coreai-torch#37` (resolved: closed as
> completed 2026-07-13):
> *"Hi @zli96, from macOS beta 2 the assets generated via coreai-torch 0.4.0 will fail to compile.
> Please use coreai-torch 0.4.1 for conversion."*

The failure is in the asset's **location metadata**, not its payload — which is why the diagnosis is
confusing. A community report (`coreai-torch#44`, author `john-rocky`, who maintains a ~60-model
zoo) established the following, all confirmed by the maintainer thread:

- `xcrun coreai-build package` re-emits the asset and updates the producer stamp, **but leaves IR
  locations untouched** — the repacked asset still fails to compile identically.
- `xcrun coreai-build inspect` reads the same asset fine, printing function signatures, inputs,
  outputs and states correctly. **`inspect` succeeding is not evidence the model will compile.**
- Pinning `coreai-core` back to `1.0.0b1` does not help: the gate is OS-side from beta 2.

**The recovery, if you cannot reconvert** (Apple maintainer @cymbalrush, `coreai-torch#44`):

```python
from pathlib import Path

from coreai.authoring import AIModelAsset
from coreai_torch.debugging.debug_info import strip_debug_info

asset = AIModelAsset.load(Path("model.aimodel"))
coreai_program = asset.program

strip_debug_info(coreai_program)                       # in-place
coreai_program.save_asset(Path("model_stripped.aimodel"))
```

> ✅ **VERIFIED** — maintainer's answer verbatim: *"Could you try using `strip_debug_info` to remove
> debugging metadata? This should prevent the compiler failure. After stripping the debug
> information, make sure to save the updated asset."* Implementation pointer given in-thread:
> `coreai_torch/debugging/debug_info.py`. Issue resolved: closed as completed 2026-07-24.
>
> Note the call shape: the maintainer's snippet calls `strip_debug_info(program)` as a **statement**
> and then saves the same object. The function is documented as operating in place — *"replaces every
> op location with an unknown-file location plus a fresh sequential `coreai` op ID"*. Do not rely on
> a return value.

The cost of stripping is real: you lose exactly the metadata §12 is about — the Debugger's source
viewer and the group-by-PyTorch-module navigator stop working for that asset. Reconvert with 0.4.1+
if you possibly can; strip only to unblock an already-published artifact.

### 2.4 Version-floor cheat sheet

| Component | Version as of 2026-07-27 | Notes |
|---|---|---|
| `coreai-torch` | **0.4.1** (released 2026-07-06) | 0.4.0 assets are OS-rejected — §2.3 |
| `coreai-core` | **1.0.0b2** (exact pin) | Beta. Private `coreai._compiler.*` may move without notice |
| `coreai-opt` | 0.2.1 (2026-07-02) | Part 9 |
| `coreai-models` | 0.2.0 pre-release (2026-07-08) | Requires macOS/iOS 27.0+, Xcode 27.0+ |
| Python | ≥ 3.11 | Wheels: cp311, cp312; **cp313 added in `coreai-core` 1.0.0b2** |
| PyTorch | ≥ 2.8.0, validated ≤ 2.13.0 | Warning above the ceiling |
| Runtime OS | iOS/iPadOS/macOS/tvOS/visionOS/watchOS **27.0+ Beta** | No 26.x back-deployment |

> 🔴 **GAP — `coreai-torch` states no minimum OS anywhere in its own tree.** Nothing in the converter
> repo declares a deployment target for the artifacts it produces; CI runs on self-hosted
> `[self-hosted, macos, tahoe, ARM64]` runners and that is the only platform signal in the package.
> The 27.0 floor above comes from the **Core AI framework documentation** and from
> `apple/coreai-models`' README, not from the converter. **What would resolve it:** an explicit
> statement in `coreai-core`'s docs of the minimum OS an `.aimodel` produced by a given
> `coreai-torch` version can target. **Safe default meanwhile:** treat every asset you produce today
> as **27.0-only**, and gate the Swift code that loads it with `@available(iOS 27.0, macOS 27.0, *)`.
> This is also the conservative reading of §2.3 — asset compatibility has already moved once
> *within* the 27 beta cycle, so do not assume forward or backward tolerance.

---

## 3. `torch.export` — the part that is not Apple's

`torch.export.export` is upstream PyTorch. Core AI does not fork it, wrap it, or replace it. What it
produces — an `ExportedProgram` — is the only thing `TorchConverter` accepts.

> ✅ **VERIFIED** — WWDC26 session 325, lines 41–44: *"Then, I run `torch.export`, I pass the model
> and an `example_input`, which gives me an `exported_program`. This `exported_program` is the
> starting point for Core AI conversion. **It captures the full computational graph: weights,
> operations and shapes** in a format that `coreai-torch` can work with."*

### 3.1 `.eval()` first — a rule the talk skips

```python
import torch
import torch.nn as nn


class SimpleModel(nn.Module):
    def __init__(self):
        super().__init__()
        self.linear1 = nn.Linear(10, 20)
        self.relu = nn.ReLU()
        self.linear2 = nn.Linear(20, 5)

    def forward(self, x):
        x = self.linear1(x)
        x = self.relu(x)
        x = self.linear2(x)
        return x


model = SimpleModel()
model.eval()                       # <- not optional
```

> ✅ **VERIFIED** — `docs/getting-started/quickstart.ipynb`, cell 3, verbatim: *"**Always call
> `.eval()` before exporting.** Layers such as `BatchNorm` and `Dropout` behave differently in
> training mode and produce a different graph."*

This is a genuinely silent one at the framework level: a model exported in training mode converts
cleanly, produces an asset, and runs. It is just running dropout at inference time and using batch
statistics instead of running statistics. Nothing throws. The supported-op table even confirms the
converter only has an inference lowering for batch norm:

> ✅ **VERIFIED** — `docs/api/supported-aten-ops.md`:
> `_native_batch_norm_legit_no_training.default` — *"Inference path only"*.
>
> The `_no_training` suffix is doing the work. If your exported graph contains the *training* variant,
> you will not find a lowering for it; see §4.3 for the exact error, which is the loud half of this
> failure mode.

### 3.2 The example input determines what gets baked in

```python
example_input = (torch.randn(1, 10),)
exported = torch.export.export(model, args=example_input)
```

Every dimension of every tensor in `args` becomes a **static** dimension in the exported program
unless you say otherwise. That is the correct default — static shapes are what let the compiler plan
buffers and, on iOS, what the Neural Engine requires — but it means a batch size of 1 and a sequence
length of 128 are now facts about your artifact. §8 is how you opt specific axes out.

`args` is a **tuple**. `torch.export.export(model, args=torch.randn(1, 10))` is a common early
mistake; it must be `args=(torch.randn(1, 10),)` with the trailing comma.

### 3.3 What "exportable" means in practice

`torch.export` is a full graph capture with no fallback to Python. Data-dependent control flow, calls
into arbitrary C extensions, and mutation patterns it cannot trace all raise. This matters here for
one reason worth naming early: **if your model is not exportable, `add_pytorch_module` will tell you
so with a wrapped error, and `coreai-opt`'s graph-mode quantization will not work either**.

> ✅ **VERIFIED** — `coreai_torch/converter.py`, inside `add_pytorch_module`:
>
> ```python
> raise RuntimeError(
>     f"Your model failed to export: {e}\n"
>     f"Ensure the model is exportable via torch.export before "
>     f"passing it to TorchConverter.add_pytorch_module."
> ) from e
> ```

The `coreai-opt` escape hatch for non-exportable models is `ExecutionMode.EAGER`, whose docstring
says it *"Supports dynamic control flow (if/else, loops) and is the fallback when a model is not
exportable."* That is Part 9's problem, but it is useful to know the ladder exists.

For control flow you *do* want in the graph, `coreai-torch` supports two higher-order ops:

> ✅ **VERIFIED** — `docs/api/supported-aten-ops.md`, higher-order table:
>
> | Op | Notes |
> |---|---|
> | `cond` | `torch.cond` — emitted as a Core AI conditional with two branch subgraphs |
> | `while_loop` | `torch._higher_order_ops.while_loop` |

> ⚠️ **But they only run on one compute unit.** `tests/conftest.py` auto-skips every test marked
> `control_flow` whenever `--compute-unit-kind != interpreter`, with the comment: *"Higher-order ops
> like `torch.cond` / `while_loop` are **not yet supported by the cpu/gpu/neural_engine compute unit
> runtimes**."* If your model needs `torch.cond` at inference time on device, that is a blocker
> today, not a tuning problem. This is verified from Apple's own test configuration, and it is the
> kind of constraint that never appears in a session.

---

## 4. `run_decompositions(get_decomp_table())` — the most consequential line

This is the line to understand if you read nothing else.

```python
from coreai_torch import get_decomp_table

ep = ep.run_decompositions(get_decomp_table())
```

### 4.1 Why decomposition happens at all

`torch.export` produces a graph at whatever level of abstraction your model was written at.
`aten.linear`, `aten.scaled_dot_product_attention`, `aten.instance_norm` are all *composite* ATen ops
— PyTorch knows how to expand each into primitives. `run_decompositions(table)` performs that
expansion for every op in `table`.

`coreai-torch` requires a decomposed program because its lowering table is written against the
primitive level. But it does **not** want *everything* decomposed, because Core AI has fast native
implementations of certain high-level operations, and once an op has been shredded into matmuls and
softmaxes the compiler can no longer recognise it.

> ✅ **VERIFIED** — WWDC26 session 325, lines 78–79, on the SAM3 conversion helper:
> *"**First**, it runs decompositions in the PyTorch `exported_program` with **Core AI's custom
> table**. This ensures that **high-level semantics that Core AI supports, like attention, are
> preserved in the graph**."*

`get_decomp_table()` is exactly "PyTorch's default table, minus the ops Core AI wants to keep."

> ✅ **VERIFIED** — the entire body of `coreai_torch/_decomp.py`:
>
> ```python
> _COMPOSITE_OPS: list = [
>     torch.ops.aten.hardsigmoid.default,
>     torch.ops.aten.hardswish.default,
>     torch.ops.aten.instance_norm.default,
>     torch.ops.aten.pixel_shuffle.default,
>     torch.ops.aten.reflection_pad1d.default,
>     torch.ops.aten.reflection_pad2d.default,
>     torch.ops.aten.reflection_pad3d.default,
>     torch.ops.aten.replication_pad1d.default,
>     torch.ops.aten.replication_pad2d.default,
>     torch.ops.aten.replication_pad3d.default,
>     torch.ops.aten.scaled_dot_product_attention.default,
>     torch.ops.aten.silu.default,
> ]
>
> def get_decomp_table() -> dict:
>     table = torch.export.default_decompositions()
>     for op in _COMPOSITE_OPS:
>         table.pop(op, None)
>     return table
> ```
>
> Twelve ops. Each call returns a **fresh copy** — mutating the returned dict does not affect other
> callers (`tests/test_converter.py::test_returns_independent_copy`).

### 4.2 ⚠️ Correction to the "three preserved ops" claim

Apple's own README says:

> ✅ **VERIFIED** — `apple/coreai-torch/README.md`: *"Use `get_decomp_table()` so that composite ops
> (`instance_norm`, `pixel_shuffle`, `scaled_dot_product_attention`) are preserved for optimal
> runtime performance."*

Three ops. That sentence is in wide circulation, and it is **incomplete**. The source list has
twelve entries and `_decomp.py`'s own docstring splits them into two categories:

| Category | Ops | Why preserved |
|---|---|---|
| **Composite ops** | `hardsigmoid`, `instance_norm`, `pixel_shuffle`, `scaled_dot_product_attention` | Core AI emits a recognisable composite the compiler can pattern-match to a fast implementation |
| **Direct lowerings** | `hardswish`, `reflection_pad{1,2,3}d`, `replication_pad{1,2,3}d`, `silu` | `coreai-torch` has a single-op lowering that is better than the decomposition |

So: **four composites, eight direct lowerings, twelve total.** The README's three are the subset with
the most performance riding on them. The pad family was added late — commit `45a231f`,
*"do not decompose pad op (#29)"* — which is why an issue filed in June 2026 (`coreai-torch#21`)
described the list as *"only 6 ops (`hardsigmoid`, `hardswish`, `instance_norm`, `pixel_shuffle`,
`scaled_dot_product_attention`, `silu`)"* and was accurate at the time. **The list is a moving target;
read `_decomp.py` for the version you have installed rather than trusting any prose, including this
guide's.**

Confirmation that these names really do land in the emitted IR, from the op-frequency tool:

> ✅ **VERIFIED** — `tools/freqop/README.md`: composite ops (graphs carrying a `composite_decl`) are
> counted as `composite.<name>`, *"e.g. `composite.layer_norm`,
> `composite.scaled_dot_product_attention`"*. Running `python tools/freqop/freqop.py my.aimodel` is
> the cheapest possible check that your attention survived as a composite. §11.5 uses this.

### 4.3 What happens if you skip decomposition entirely — LOUD

Good news first. `add_exported_program` and `add_pytorch_module` both validate eagerly, and the
message tells you exactly what to do:

> ✅ **VERIFIED** — `coreai_torch/_validate.py`:
>
> ```python
> raise ValueError(
>     f"The exported program contains non-decomposed ops: {ops_list}. "
>     f"Please call run_decompositions() on your ExportedProgram before "
>     f"passing it to TorchConverter. Example:\n"
>     f"  ep = ep.run_decompositions(coreai_torch.get_decomp_table())"
> )
> ```
>
> Even a bare `nn.Linear` trips this (`tests/test_validate.py::test_error_message_lists_ops`) —
> `aten.linear` is itself a composite. You cannot accidentally skip this step and get an asset.

The second validator shape, for ops that *are* decomposed but have no lowering:

> ✅ **VERIFIED** — same file:
>
> ```python
> raise ValueError(
>     f"The exported program contains unsupported ATen ops: {ops_list}. "
>     f"Use register_torch_lowering() to provide a custom lowering for "
>     f"these ops."
> )
> ```
>
> Ops the validator deliberately skips: everything in `_COMPOSITE_OPS`; the assertion ops that
> `preprocess_graph()` strips (`aten._assert_async.msg`, `aten._assert_scalar.default`,
> `aten.sym_constrain_range_for_size.default`, `aten.sym_constrain_range.default`,
> `aten._assert_tensor_metadata.default`); and any non-`aten.` target, so custom ops pass through
> untouched. A registered user lowering suppresses the "unsupported" error
> (`test_user_lowering_bypasses_unsupported_check`).

### 4.4 ⚠️ SILENT FAILURE — using PyTorch's default table instead of Apple's

This is the real trap, and it is not "skipping the line." It is writing the line with the wrong
argument:

```python
ep = ep.run_decompositions(torch.export.default_decompositions())   # ← WRONG
ep = ep.run_decompositions()                                        # ← also wrong (same default)
```

The outcome **depends on which preserved op your model contains**, and the two halves behave
completely differently:

**The loud half.** `instance_norm` under the full table decomposes into `_native_batch_norm_legit`,
for which there is no lowering, so you get the "unsupported ATen ops" `ValueError`.

> ✅ **VERIFIED** — `tests/test_converter.py::test_add_pytorch_module_full_table_decomposes_instance_norm`
> asserts exactly `pytest.raises(ValueError, match="unsupported ATen ops")`.

**The silent half — and this is the one that matters.** `scaled_dot_product_attention` under the full
table decomposes into `mul`, `transpose`, `matmul`, `add`, `softmax`, `matmul` — **every one of which
has a perfectly good lowering.** So:

- conversion succeeds,
- `optimize()` succeeds,
- `save_asset()` succeeds,
- the model loads on device,
- the numerics are correct,
- and the fused-attention composite is **gone**. The compiler sees six generic tensor ops where it
  should have seen one `composite.scaled_dot_product_attention`, and cannot substitute its fast
  attention kernel.

Nothing warns. Your transformer is slower and you have no diagnostic pointing at why. The same logic
applies to `silu` (decomposes to `sigmoid` + `mul`), `hardswish`, and the six pad ops (each
decomposes to a slice/concat construction instead of the single `coreai.pad`).

> ⚠️ **SILENT FAILURE — how to detect it.** There is no error to catch, so use a structural check.
> Two options, both cheap:
>
> ```bash
> # 1. Count ops in the saved asset. A transformer with a preserved SDPA shows
> #    `composite.scaled_dot_product_attention`; one without shows extra matmul/softmax.
> python tools/freqop/freqop.py good.aimodel bad.aimodel      # two-file mode prints a Delta column
> ```
>
> ```python
> # 2. Assert on the IR text directly, before you ever save.
> ir = str(coreai_program)
> assert "scaled_dot_product_attention" in ir, "SDPA was decomposed — wrong decomp table?"
> ```
>
> `str(AIProgram)` prints the MLIR module. This one-line assertion in your conversion script is the
> single highest-value defensive check in Part 8.

There is a further, nastier consequence of the same design. Ops **not** on the preserve list get
PyTorch's naïve decomposition, and some of those decompositions are numerically unsafe at fp16:

> ✅ **VERIFIED** — `coreai-torch#21` (OPEN as of 2026-07-29), which names the mechanism precisely:
> *"In `_decomp.py`, the decomposition table preserves only 6 ops … When `softplus` is not in this
> list, PyTorch decomposes it to `log(1 + exp(x))`, where `exp(x)` overflows fp16 (max 65,504) for
> `x > ~11.09`. **On the ANE specifically, the overflow occurs even earlier at `x ≈ 10.4` due to an
> internal 2^15-bounded representation.**"*
>
> | Operation | Naïve decomposition | Failure threshold | Failure mode |
> |---|---|---|---|
> | `softplus` | `log(1 + exp(x))` | `x ≈ 10.4` | Output → 0 |
> | `mish` | `x * tanh(log(1 + exp(x)))` | `x ≈ 10.4` | Output → 0 |
> | `logsumexp` | `log(sum(exp(x_i)))` | `x ≈ 7.63` | Output → 0 |
> | `logcumsumexp` | `log(cumsum(exp(x_i)))` | `x ≈ 11.09` | Output → ∞/NaN |
>
> `log_softmax` is **not** affected — it already has a stable max-shift lowering named
> `replace_log_softmax` in `_aten_to_core.py`.
>
> **Status:** PR #22 proposes stable forms (`max(x,0) + log(1+exp(-|x|))` etc.) and adds the three ops
> to `_COMPOSITE_OPS`. **Not merged as of 2026-08-03.** On shipped `coreai-torch 0.4.1`, softplus,
> mish, logsumexp and logcumsumexp are fp16-unsafe on the ANE.
>
> **Safe default meanwhile:** substitute in your PyTorch source before export —
> `F.softplus(x)` → `torch.clamp(x, min=0) + torch.log1p(torch.exp(-x.abs()))` — and verify with §11's
> numerics gate at the *actual* activation range your model produces, not at random normal inputs.

### 4.5 The correct line, and the one variation worth knowing

```python
from coreai_torch import get_decomp_table

ep = torch.export.export(model, args=example_input)
ep = ep.run_decompositions(get_decomp_table())
```

The one variation you will see in Apple's test suite is `remove_decomps` — a test-harness parameter
that pops *additional* entries from the table so a specific op survives to the converter. It is not
public API, but it tells you the shape of the escape hatch: `get_decomp_table()` returns a plain
`dict`, you own the copy, and you can `.pop()` more ops out of it if you have a lowering for them.
Adding entries back in is the more common need and works the same way.

> 🔴 **GAP — there is no documented list of "ops it is safe to additionally preserve."** The preserve
> list is hand-curated by Apple against what the Core AI compiler recognises; popping an arbitrary op
> out of the table will produce the "unsupported ATen ops" `ValueError` unless a lowering exists.
> **What would resolve it:** a published mapping from ATen op → recognised Core AI composite.
> **Safe default meanwhile:** use `get_decomp_table()` unmodified. If you need an op preserved,
> the supported path is a **custom lowering** (`register_torch_lowering`) or **composite-op
> externalization** (§5.3), both of which are Part 10.

---

## 5. Two input forms: `add_exported_program` vs `add_pytorch_module`

WWDC26 session 325 shows exactly one door into the converter. There are two, they take different
things, and only one of them can do composite-op externalization. This is the single largest gap
between the session narrative and the shipped API.

### 5.1 `add_exported_program` — you own the export

> ✅ **VERIFIED** — `coreai_torch/converter.py`, real signature:
>
> ```python
> def add_exported_program(
>     self,
>     exported_program: ExportedProgram,
>     *,
>     input_names: Sequence[str] | None = None,
>     output_names: Sequence[str] | None = None,
>     state_names: Sequence[str] | None = None,
>     entrypoint_name: str = "main",
> ) -> Self:
> ```
>
> ⚠️ **Note the bare `*`.** Every naming parameter is **keyword-only** in the source, even though
> `docs/api/TorchConverter.md` renders them positionally. Guide code — and your code — must use
> keywords. Passing `input_names` positionally is a `TypeError`.

What it does, in source order:

1. Raises `ValueError` if `entrypoint_name` is already staged:
   *"A program with entrypoint_name={…!r} is already staged. Each staged program must have a unique
   entrypoint_name."*
2. Calls `inject_subbyte_tensors(exported_program)` — promotes uint8 compression constants to
   sub-byte tensors. This is why a `coreai-opt`-compressed model does not need any extra call here.
3. Calls `validate_exported_program(...)` — the §4.3 checks.
4. Appends a staged entry and **returns `self`**, so the API chains.

```python
from coreai_torch import TorchConverter, get_decomp_table

ep = torch.export.export(model, args=(torch.randn(1, 3, 224, 224),))
ep = ep.run_decompositions(get_decomp_table())

coreai_program = (
    TorchConverter()
    .add_exported_program(ep, input_names=["image"], output_names=["logits"])
    .to_coreai()
)
coreai_program.optimize()
```

> ✅ **VERIFIED** — this exact shape is `docs/getting-started/quickstart.ipynb` cell 14 (MobileNetV2)
> and is also what Apple's `working-with-coreai` agent skill ships as its minimal export snippet.

### 5.2 `add_pytorch_module` — the converter owns the export

> ✅ **VERIFIED** — `coreai_torch/converter.py`, real signature:
>
> ```python
> def add_pytorch_module(
>     self,
>     model: torch.nn.Module,
>     *,
>     export_fn: Callable[[torch.nn.Module], ExportedProgram],
>     externalize_modules: list[type | ExternalizeSpec] | None = None,
>     input_names: Sequence[str] | None = None,
>     output_names: Sequence[str] | None = None,
>     state_names: Sequence[str] | None = None,
>     entrypoint_name: str = "main",
> ) -> Self:
> ```
>
> ⚠️ **`export_fn` is keyword-only *and required*.** `docs/api/TorchConverter.md` shows it
> positionally; the source has `*` before it. There is no default — you must supply the callable that
> exports and decomposes.

```python
import coreai_torch
from coreai_torch import TorchConverter

model = ...  # your nn.Module
model.eval()
sample = (torch.randn(1, 3, 224, 224),)

converter = TorchConverter().add_pytorch_module(
    model,
    export_fn=lambda m: torch.export.export(m, args=sample).run_decompositions(
        coreai_torch.get_decomp_table()
    ),
)
coreai_program = converter.to_coreai()
coreai_program.optimize()
```

> ✅ **VERIFIED** — `apple/coreai-torch/README.md:66–82`, verbatim.

Note what the lambda contains: **the same two lines from §3 and §4**. `add_pytorch_module` does not
relieve you of choosing the decomposition table; it just moves the choice inside a callable the
converter can invoke more than once. That "more than once" is the whole point — see §5.3.

`export_fn` runs **eagerly**, inside `add_pytorch_module`, not lazily at `to_coreai()` time. Failures
surface at the call site with the wrapper message from §3.3.

### 5.3 Why the second form exists: externalization

Everything in `coreai_torch.composite_ops` — `SDPA`, `RoPE`, `RMSNorm`/`RMSNormImpl`, `GatherMM`,
`GatedDeltaUpdate` — is reachable **only** through `add_pytorch_module`.

> ✅ **VERIFIED** — `docs/api/composite-ops.md`, the three-step pattern: *"1. Use the provided class
> as a **named submodule** in your model — not as the root module. 2. Convert via
> **`add_pytorch_module`** — required entrypoint for composite op externalization. 3. Pass an
> `ExternalizeSpec` with `composite_op_name` and `composite_attrs`."*
>
> **`add_exported_program` has no externalization.** There is no `externalize_modules` parameter on
> it, and no way to add one after staging.

```python
import coreai_torch
from coreai_torch import ExternalizeSpec, TorchConverter
from coreai_torch.composite_ops import RMSNormImpl

converter = TorchConverter().add_pytorch_module(
    model,
    export_fn=lambda m: torch.export.export(m, args=sample).run_decompositions(
        coreai_torch.get_decomp_table()
    ),
    externalize_modules=[
        ExternalizeSpec(
            target_class=RMSNormImpl,
            composite_op_name="rms_norm",
            composite_attrs=["axes", "eps"],
        )
    ],
)
coreai_program = converter.to_coreai()
coreai_program.optimize()
```

> ✅ **VERIFIED** — `docs/guides/conversion-workflows.ipynb`, cell 8, verbatim, with Apple's own
> rationale: *"Externalizing a submodule **preserves its operation boundary** during conversion…
> When you mark a well-known building block — such as attention, RoPE, or RMSNorm — as a **composite
> op**, the compiler recognizes that operation and can apply an optimized implementation tailored to
> it, producing a faster model."*

The mechanism, in one sentence: the converter temporarily patches each matching submodule's `forward`
to call a generated `torch.library.custom_op`, **re-exports the whole model** (this is why it needs
`export_fn` rather than a finished program), lifts each call site into its own `noinline` graph
carrying a `composite_decl` attribute, and restores your model untouched in a `finally`.

The emitted IR is worth seeing once, because it is what the compiler pattern-matches on:

> ✅ **VERIFIED** — `docs/guides/externalization.ipynb`:
>
> ```llvm
> module {
>   coreai.graph private noinline @norm.rms_norm(
>       %arg0: tensor<1x10xf32> {coreai.name = "input"},
>       %arg1: tensor<10xf32> {coreai.name = "scale"}
>   ) -> tensor<1x10xf32> attributes {
>       composite_decl = #coreai.composite_declaration<"rms_norm" = {
>           input_names = ["input", "scale"],
>           op_attrs = {axes = -1 : si64, eps = 9.99999974E-6 : f32, version = 1 : si64},
>           output_names = ["output"]}>
>   } {
>     // ... rms-norm body ...
>     coreai.output %15 : tensor<1x10xf32>
>   }
>   coreai.graph @main(%arg0: tensor<1x10xf32>) -> tensor<1x5xf32> {
>     %3 = coreai.invoke @norm.rms_norm(%arg0, %0)
>         : (tensor<1x10xf32>, tensor<10xf32>) -> tensor<1x10xf32>
>     coreai.output %7 : tensor<1x5xf32>
>   }
> }
> ```
>
> with the caveat, verbatim: *"Symbol names and constants above are illustrative (the converter
> appends a hash suffix to each externalized graph name)."*

Three externalization footguns, all verified, all silent or nearly so:

> ⚠️ **`target_class` must be `RMSNormImpl`, never `RMSNorm`.** `RMSNorm` is a convenience wrapper
> that owns the weight and delegates to `RMSNormImpl`. The docs are explicit: *"`target_class` in the
> `ExternalizeSpec` must still be `RMSNormImpl` (the inner module the converter recognizes as the
> `rms_norm` composite op)."* Pointing at the wrapper matches nothing.

> ⚠️ **A target class that matches no submodule only warns.** Verbatim from `externalize.py`:
> *"externalize_modules: the following target class(es) did not match any submodule in the model:
> {…}. No externalization will happen for these classes. If intentional (e.g. passing a superset
> across model variants), this warning is safe to ignore. Otherwise, check for typos or stale class
> references."* A typo in a class reference costs you the composite and produces a `UserWarning` you
> will not see in a notebook that already prints a progress bar. **Grep your logs, or assert on
> `composite_decl` appearing in `str(program)`.**

> ⚠️ **Passing a bare class instead of an `ExternalizeSpec` is "simple externalization"** — documented
> as **experimental**, *"with no composite-op metadata and no optimization benefit."* It looks like it
> worked (you get a separate `noinline` graph) and buys nothing.

### 5.4 One more asymmetry: sub-byte injection

> ✅ **VERIFIED** — `converter.py`, inside `add_pytorch_module`:
>
> ```python
> if not externalize_modules:
>     inject_subbyte_tensors(ep)
> ```
>
> When you externalize, injection is deferred and happens later on the **re-exported** whole program
> inside `_run_externalize_pipeline`. There is a historical bug behind that: the re-export used to
> discard sub-byte injection, silently degrading int4 weights to int8. The regression tests that
> guard it are currently `@pytest.mark.skip`ped for an unrelated reason
> (*"transform_with_custom_compression_ops has been deprecated"*), so if you combine 4-bit
> compression with composite-op externalization, **check the emitted weight dtypes yourself** — §11.5
> shows how with `coreai-build inspect`.

### 5.5 Choosing between them

| You want to… | Use |
|---|---|
| Convert a plain model, shapes and names under your control | `add_exported_program` |
| Mark `SDPA` / `RoPE` / `RMSNorm` / `GatherMM` / `GatedDeltaUpdate` as composites | `add_pytorch_module` + `ExternalizeSpec` |
| Reuse one exported program across several converter configurations | `add_exported_program` |
| Convert several models into one asset | Either — they mix on one converter (§10) |
| Apply per-call-site dynamic shapes to an externalized submodule | `add_pytorch_module` (it reconstructs them; see §8.4) |

> ✅ **VERIFIED** — `tests/test_converter.py::test_chaining_exported_program_and_pytorch_module`
> confirms the two forms can be staged on the **same** `TorchConverter` instance.

---

## 6. `to_coreai()` and `optimize()`

### 6.1 `to_coreai()` converts and nothing else

> ✅ **VERIFIED** — `coreai_torch/converter.py`:
>
> ```python
> def to_coreai(self, *, entrypoints: Sequence[str] | None = None) -> AIProgram
> ```
>
> - `entrypoints` is **keyword-only**; when given, only the matching staged programs are converted.
> - Raises `RuntimeError("No programs to convert. Call add_exported_program() or
>   add_pytorch_module() first.")` if nothing matches.
> - An unknown entrypoint name raises (`test_selective_conversion_unknown_entrypoint_raises`).
> - **Staged programs persist after conversion.** Call `converter.clear()` to drop them;
>   `clear(entrypoints=[…])` drops a subset. *"Custom lowerings registered via
>   `register_torch_lowering()` are always preserved."*
> - It prints a `rich` banner: `coreai-torch 0.4.1: converting N program(s) to Core AI`. The progress
>   bar is auto-disabled when stdout is not a TTY (`disable=not sys.stdout.isatty()`), so CI logs stay
>   clean.

The critical property, which Apple has a dedicated test class for:

> ✅ **VERIFIED** — `tests/test_converter.py::TestConvertToCoreaiNoOptimization`. `to_coreai()` runs
> **no optimization passes at all**. The IR you get back is a direct transliteration of the FX graph.

### 6.2 `optimize()` is where the passes run

Every documented example calls it, always as a bare statement, never assigning the result:

```python
coreai_program = converter.to_coreai()
coreai_program.optimize()                      # in-place; return value unused everywhere
asset = coreai_program.save_asset(Path("MyModel.aimodel"))
```

> ✅ **VERIFIED** — the return value of `optimize()` is not used in a single example, test or doc in
> the `coreai-torch` tree. Treat it as `-> None` and mutating in place.

Here is the before/after that shows what "optimize" means concretely — a cast chain:

> ✅ **VERIFIED** — `tests/test_converter.py::test_cast_chain_preserved_until_optimize`, using
> `filecheck` assertions on the printed MLIR:
>
> ```python
> coreai_program = TorchConverter().add_exported_program(program).to_coreai()
> # BEFORE optimize — two casts, exactly as the graph was written:
> #   coreai.cast %{{.*}} : tensor<3x4xsi32> to tensor<3x4xf32>
> #   coreai.cast %{{.*}} : tensor<3x4xf32>  to tensor<3x4xf16>
>
> coreai_program.optimize()
> # AFTER optimize — the intermediate f32 hop is gone:
> #   CHECK-NOT: coreai.cast %{{.*}} : tensor<3x4xsi32> to tensor<3x4xf32>
> #   CHECK:     coreai.cast %{{.*}} : tensor<3x4xsi32> to tensor<3x4xf16>
> ```

That is cast folding. The same pass family does constant folding and inlines graphs that are not
marked `noinline` — which is exactly why composite externalization marks its graphs `noinline`
(§5.3): so `optimize()` cannot dissolve the boundary it just created.

### 6.3 What `optimize()` actually wraps

The HEAD commit of `coreai-torch` is `4529671`, *"Remove run_transforms helper in favor of
result.optimize() (#50)"*, merged 2026-07-23. **The API changed very recently.** Before it, the test
suite drove the compiler through a private pass list; the deleted helper is therefore the best
available enumeration of what `optimize()` now wraps:

> ✅ **VERIFIED** — code deleted by commit `4529671` (`git show 4529671`, `tests/utils.py`):
>
> ```python
> from coreai._compiler._transforms import GlobalOptions, PassEntry, apply_passes
> from coreai._compiler._transforms.passes import CorePasses
> from coreai.authoring import AIProgram
>
> async def run_transforms(coreai_program: AIProgram) -> None:
>     """Run essential transformation passes."""
>     await apply_passes(
>         coreai_program._mlir_module,
>         passes=[
>             PassEntry.get(CorePasses._CORE_OPTIMIZE),
>             PassEntry.get(CorePasses._UPDATE_SIGNATURE_TO_HANDLES),
>             PassEntry.get(CorePasses._PROPAGATE_HANDLE_UPDATES),
>         ],
>         options=GlobalOptions(Path()),
>     )
> ```
>
> The migration in the same commit was `await run_transforms(result)` → `result.optimize()` —
> **note the loss of `await`. `optimize()` is synchronous.**

| Pass | What it appears to do |
|---|---|
| `CorePasses._CORE_OPTIMIZE` | Core dialect optimization — constant folding, cast folding, inlining of non-`noinline` graphs |
| `CorePasses._UPDATE_SIGNATURE_TO_HANDLES` | Rewrites a stateful graph's signature to handle-based state; mutation outputs become tokens |
| `CorePasses._PROPAGATE_HANDLE_UPDATES` | Propagates those handle updates through the module |

Two more pass names are attested from a crash report rather than from source:

> ✅ **VERIFIED** — `coreai-torch#33` (*"Segfault: TorchConverter derived program segfaults on
> `.optimize()`"*, CLOSED, fixed by macOS 27 beta 3) names **`legalize-to-core`** and
> **`core-to-odix`**, with the crash site in `apply_passes_sync`. `apply_passes_sync` independently
> corroborates that `optimize()` is the synchronous driver.

> 🔴 **GAP — the full `CorePasses` catalog and `optimize()`'s signature are unverified.** Five pass
> names are attested; there are certainly more. No in-tree call site passes any argument to
> `optimize()`, so whether it accepts a pass list, an optimization level, or options at all is
> unknown. **What would resolve it:** `dir(coreai._compiler._transforms.passes.CorePasses)` on an
> installed `coreai-core 1.0.0b2`, plus `help(AIProgram.optimize)`. **Safe default meanwhile:** call
> it with no arguments, exactly as every Apple example does, and treat the escape hatch in §6.5 as
> your only knob.

### 6.4 ⚠️ SILENT FAILURE — `optimize()` is not always semantics-preserving

This is the most important callout in Part 8. It is an **open bug**, it produces an artifact that
loads and runs, and the wrongness is large.

> ✅ **VERIFIED** — `coreai-torch#49`, *"`AIProgram.optimize()` removes broadcasting-significant axis
> moves and silently miscompiles N×N distance expressions"*. **OPEN, 0 comments, as of 2026-07-29.**
> Reported 2026-07-23 by `dkomoroske`. Environment: macOS 27.0 builds `26A5378j` and `26A5388g`,
> `coreai-torch 0.4.1`, `coreai-core 1.0.0b2`, torch 2.11.0, Python 3.12.13. Also filed as Feedback
> Assistant **FB23695952**.

The trigger is the classic expanded squared-distance form `D[i,j] = ‖xᵢ‖² − 2·xᵢ·yⱼ + ‖yⱼ‖²`:

```python
# Minimal reproducer from the issue — no matmul needed; z is a graph input.
s1 = torch.sum(x ** 2, dim=-1).unsqueeze(-1)   # (1, N, 1)
s2 = torch.sum(y ** 2, dim=-1).unsqueeze(-2)   # (1, 1, N)
out = (s1 - 2 * z + s2).clamp(min=0.0)
```

`optimize()` deletes the `expand_dims` that moves `s2` onto the *other* axis — an op that is
semantically load-bearing precisely because it changes which axis broadcasts:

> ✅ **VERIFIED** — IR before `optimize()`, verbatim from the issue:
>
> ```text
> %y_norm       = coreai.reduce_sum ...                          -> tensor<1x32x1xf32>
> %y_norm_moved = coreai.expand_dims ...                         -> tensor<1x1x32xf32>
> %tmp = ...broadcasting_sub ... : (tensor<1x32x1xf32>, tensor<1x32x32xf32>) -> tensor<1x32x32xf32>
> %out = ...broadcasting_add %tmp, %y_norm_moved
>                            : (tensor<1x32x32xf32>, tensor<1x1x32xf32>)   -> tensor<1x32x32xf32>
> ```
>
> IR **after** `optimize()` — the axis move is gone and the wrong operand broadcasts:
>
> ```text
> %x_norm = coreai.reduce_sum ... %arg0 ...                      -> tensor<1x32x1xf32>
> %y_norm = coreai.reduce_sum ... %arg1 ...                      -> tensor<1x32x1xf32>
> %tmp = ...broadcasting_sub ... : (tensor<1x32x1xf32>, tensor<1x32x32xf32>) -> tensor<1x32x32xf32>
> %out = ...broadcasting_add %tmp, %y_norm
>                            : (tensor<1x32x32xf32>, tensor<1x32x1xf32>)   -> tensor<1x32x32xf32>
> ```

The measured harness output, verbatim:

```text
Chain           optimize=False: max|d| = 1.907e-06  OK
Chain           optimize=True : max|d| = 1.022e+01  MISCOMPILED
ChainKeepdim    optimize=False: max|d| = 1.907e-06  OK
ChainKeepdim    optimize=True : max|d| = 1.022e+01  MISCOMPILED
ChainReordered  optimize=False: max|d| = 3.815e-06  OK
ChainReordered  optimize=True : max|d| = 3.815e-06  OK
```

**Why it is silent.** The output shape still validates. `1x32x32` is `1x32x32` either way, because the
inputs are square. The reporter's control table makes the shape-dependence explicit:

> ✅ **VERIFIED** — controls, verbatim rows:
> - `SpecializationOptions.cpu_only()` → **same miscompile**, so this is a compiler/optimizer bug, not
>   a compute-unit delegate bug.
> - A real `x @ y.transpose(-1, -2)` with distinct equal-length inputs → miscompiled.
> - `s1 + s2` alone → correct.
> - **Unequal input lengths (17 × 23) → correct** — the wrong operand cannot broadcast, so the bug
>   cannot hide.
> - Reordered `(s1 + s2) - 2*z` → correct.

Impact at model scale, verbatim from the reporter:

> *"In a larger GeoTransformer conversion, this appeared as approximately **17 dB PSNR** versus eager
> PyTorch and scrambled nearest-neighbor relationships. **Disabling `optimize()` restored
> approximately 78–85 dB parity.**"*

For calibration, Apple's own agent skill sets these acceptance thresholds:

> ✅ **VERIFIED** — `working-with-coreai/SKILL.md` PSNR acceptance table:
>
> | Scenario | Expected PSNR | Investigate below |
> |---|---|---|
> | float32 end-to-end | > 70 dB | 60 dB |
> | fp16 on-device | > 50 dB | 40 dB |
> | 4-bit palettized | ~40 dB | 30 dB |
>
> 17 dB is far below the floor for *2-bit palettization*. This is not a numerics wobble; it is a
> different computation.

**Two verified workarounds, from the issue:**

1. **Do not call `optimize()`.** *"Conversion, `save_asset`, specialization, loading, and inference
   work correctly without it."* — with the caveat in §6.6 about stateful models.
2. **Reorder the algebra** to `(‖xᵢ‖² + ‖yⱼ‖²) − 2·xᵢ·yⱼ`, which the control table shows converts
   correctly.

> ⚠️ **SILENT FAILURE — make this a standing gate, not a one-off check.** Any distance matrix,
> attention-score construction, kernel/Gram matrix, contrastive loss at inference, or nearest-neighbour
> search built from the expanded square form is exposed. **Every conversion pipeline should A/B
> `optimize=True` against `optimize=False` on real inputs and fail the build on a divergence.** §11.4
> is that gate, written out.
>
> **Status: unresolved as of 2026-07-29.** Zero comments on the issue. Re-check `coreai-torch#49`
> before shipping.

This is not an isolated case, which is why the gate matters more than the specific bug. The same
issue tracker documents a family of `optimize()`-reachable and converter-reachable
semantics-changing simplifications, all producing plausible output with correct shapes and no
diagnostic:

> ✅ **VERIFIED** — from the issue corpus, all OPEN unless noted:
>
> | Issue | Silent behaviour |
> |---|---|
> | `coreai-torch#49` | `optimize()` drops a broadcast-significant axis move — 17 dB PSNR |
> | `coreai-torch#9` | float→int→float cast round-trips folded away, dropping truncation: `(x + 64.0).long().float() - 64.0` returns the identity instead of `floor` |
> | `coreai-torch#10` | GPU delegate executes `floor`/`trunc`/`ceil` as identity; `round` uses away-from-zero ties |
> | `coreai-torch#11` | an int64-comparison bool-mask chain clobbers an unrelated live tensor; in a full RF-DETR decoder the output cosine was **~0.65 with no error raised** |
> | `coreai-torch` PR#43 (MERGED) | `aten.min.dim` returned correct `values` but **silently wrong `indices`** at dtype-extremal minima |
>
> Issue #49 explicitly cross-references #9 as *"also … a silent semantics-changing simplification
> reached through `prog.optimize()`."* Between #9 and #10, **both natural in-graph `floor`
> workarounds are removed on GPU** — worth knowing if your model quantizes coordinates.

### 6.5 The const-folding escape hatch

If you need to stop the optimizer touching a specific op class, there is a hook. It reaches into
private API, so treat it as a debugging tool rather than a production dependency:

> ✅ **VERIFIED** — `tests/test_converter.py::test_const_folding_hook_prevents_cast_folding`:
>
> ```python
> from coreai._compiler._mlir_libs._coreaiIR._bindings.mlir.dialects.coreai import (
>     register_should_const_folding_hook,
> )
>
> coreai_program = TorchConverter().add_exported_program(program).to_coreai()
> register_should_const_folding_hook(
>     callable=lambda op: op.name != "coreai.cast",
>     context=coreai_program._mlir_module.context,
> )
> coreai_program.optimize()
> # Both now survive:
> #   coreai.constant dense<7> : tensor<1xsi32>
> #   coreai.cast %{{.*}} : tensor<1xsi32> to tensor<1xf32>
> ```
>
> The predicate returns `True` for ops that *may* be folded. Note the import path depth — this is
> as private as an API gets, and `coreai-core`'s own docs warn that *"a few graph-building primitives
> … currently live under `coreai._compiler` while the public authoring surface is finalized."*

### 6.6 When `optimize()` is mandatory

"Just skip `optimize()`" is not universally available advice. Apple's test harness runs it
conditionally, and the condition is instructive:

> ✅ **VERIFIED** — `tests/utils.py::_export_and_convert` runs optimize when
> `run_optimize_passes or state_names or has_state`, where
> `has_state = bool(sig.buffers_to_mutate) or bool(sig.user_inputs_to_mutate)`.
>
> And the reason, from a comment in `_compare_by_name`: *"state mutation outputs become tokens after
> optimize and won't appear here."*

So: **a stateful model must be optimized.** `_UPDATE_SIGNATURE_TO_HANDLES` and
`_PROPAGATE_HANDLE_UPDATES` are what convert the exported program's "mutated buffer comes back as an
extra output" convention into Core AI's handle-based state protocol. Without them the runtime's
state binding (§9.4) has nothing to bind to.

| Model shape | Can you skip `optimize()`? |
|---|---|
| Stateless (no mutable buffers, no in-place input mutation) | Yes — with a measured size/latency cost, and it is the documented workaround for #49 |
| Stateful (KV cache, running counters, in-place mutated inputs) | **No.** State does not work without it |

If you have a stateful model *and* an expanded-square-distance expression, workaround 2 (reorder the
algebra) is your only option.

---

## 7. The IO contract: names are your caller's API

Here is the thing to internalise before you write a single `input_names=`:

**The strings you pass to the converter are the strings your Swift code types.** They are not
documentation. They are not debug labels. They are the dictionary keys in the calling convention of
the artifact you are shipping, and they cross a language boundary where nothing checks them at
compile time.

### 7.1 The round trip, in both languages

Python, from Apple's quickstart:

```python
coreai_program = (
    TorchConverter()
    .add_exported_program(exported, input_names=["image"], output_names=["logits"])
    .to_coreai()
)
coreai_program.optimize()
```

```python
# ...and at inference, in Python:
outputs = await function({"image": NDArray(arr)})
logits = outputs["logits"].numpy()
```

Swift, from Apple's own agent skill:

> ✅ **VERIFIED** — `working-with-coreai/SKILL.md` run snippet:
>
> ```swift
> import CoreAI
> let model = try await AIModel(contentsOf: modelURL)
> guard let fn = try model.loadFunction(named: "main") else { return }
> var input = NDArray(shape: [1, 3, 224, 224], scalarType: .float32)
> var view = input.mutableView(as: Float32.self)
> var outputs = try await fn.run(inputs: ["image": input])
> let result = outputs.remove("logits")?.ndArray
> ```

`"image"` and `"logits"` appear in the conversion script and again in the Swift call site, with a
`.aimodel` bundle in between. Change one without the other and you get a runtime failure at best.

Note the two API asymmetries between the languages, both verified, both easy to trip over:

| | Python | Swift |
|---|---|---|
| Missing function name | `load_function("nope")` **raises `KeyError`** | `loadFunction(named:)` **returns `nil`** |
| Calling convention | `await function({"image": nd})` — a dict | `try await fn.run(inputs: ["image": input])` |

> ⚠️ **A third calling convention exists in the wild.** Apple's `common_issues.md` skill reference
> says: *"`InferenceFunction.__call__` uses `**kwargs` — `await runner(**inputs)`, not
> `runner(inputs_dict)`."* But every `coreai-torch` doc, notebook and test calls it with a **single
> positional dict**: `await function({"x": NDArray(...)})`. Both spellings appear in Apple material.
> **Safe default:** use the positional dict, which is what the `coreai-torch` quickstart, the
> `run-an-aimodel` tutorial and the debugging docs all use, and what the `coreai-torch` test suite
> exercises. If it raises a `TypeError`, try the `**kwargs` form — the discrepancy is real and
> unresolved.

### 7.2 The parameters, and the breaking change

> ✅ **VERIFIED** — `docs/api/TorchConverter.md`, semantics verbatim from the docstring:
>
> - **`input_names`** — *"Non-stateful `forward()` arg names only."*
> - **`output_names`** — *"Return value names only (not mutation outputs)."*
> - **`state_names`** — *"One name per state, applied to both input and mutation output. Order:
>   buffers (registration order), then mutated user inputs (signature order). Defaults to FX
>   placeholder names when not provided."*
> - **`entrypoint_name`** — *"Must be unique across all staged programs."*
>
> ⚠️ **Breaking change flagged in the doc itself**, for both `input_names` and `output_names`:
> *"previously this covered all graph inputs / all graph outputs."* If you have pre-release
> conversion scripts that listed buffers in `input_names`, they are now wrong: state is named
> separately, and the count check will reject the list.

The count check is strict and its message tells you what it saw:

> ✅ **VERIFIED** — `_utils.py::_resolve_io_names`:
> `f"Graph has {n} live inputs ({names}), but input_names has {m} entries ({...})."`
> and the analogous "live outputs" message.

That is a good error. It means a mismatched list is a **loud** failure — the danger is not
miscounting, it is not passing names at all.

### 7.3 ⚠️ What you get if you omit the names — and why it is not a contract

If you leave `input_names` and `output_names` off, the converter falls back to names read out of the
FX graph. Apple documents exactly what that produces:

> ✅ **VERIFIED** — `docs/api/TorchConverter.md`, "IO naming" section:
>
> | Category | FX graph source | Relates to | Example |
> |---|---|---|---|
> | Input | placeholder `node.name` | `forward()` arg name | `def forward(self, x, z)` → `"x"`, `"z"` |
> | Output | output node's input `node.name` | **internal op name** | `return a + b, c * d` → `"add"`, `"mul"` |
> | State (buffer) | placeholder `node.name` | `"b_"` + `register_buffer` attr | `register_buffer("kv_cache", …)` → `"b_kv_cache"` |
> | State (mutated user input) | placeholder `node.name` | `forward()` arg name | `def forward(self, y): y.mul_(2)` → `"y"` |

Look at the **Output** row. Your model's public output name defaults to the name of the *last
operation that produced it*. A model that ends with `return self.head(x) + bias` ships an output
called `"add"`. Refactor to `return torch.add(self.head(x), bias)` and it might be called something
else. Insert a `.contiguous()` and it changes again. The buffer row is barely better: you get
`"b_kv_cache"`, not `"kv_cache"`, because that is the FX placeholder spelling.

Apple's warning about this is unusually direct, and it is worth quoting in full because it is the
justification for the entire section:

> ✅ **VERIFIED** — `docs/api/TorchConverter.md`, verbatim:
>
> > *"These naming conventions are **observed behavior from the FX graph, not a stable contract from
> > PyTorch**. They may change across PyTorch versions. **Always provide explicit names for production
> > use.**"*
>
> and, on ordering:
>
> > *"The ordering of `state_names` (buffers first, then mutated user inputs) is based on observed FX
> > graph behavior, not a stable PyTorch contract. The converter asserts that the number of state
> > inputs matches state outputs, but **cannot detect silent reordering**. Always verify state
> > ordering when upgrading PyTorch versions."*

> ⚠️ **SILENT FAILURE — the shape of this one.** Upgrading PyTorch is the trigger. Your model is
> unchanged, your conversion script is unchanged, the conversion succeeds, and the asset now has
> different key names — or, worse for stateful models, the *same* names bound to different tensors
> (see §9.3). Nothing in the pipeline compares the new asset's descriptor to the old one. The fix is
> free: **pass explicit names, and assert on them.** §11.3 shows the two-line assertion.

### 7.4 Naming rules that are actually enforced

The names land in the IR as `coreai.name` attributes:

> ✅ **VERIFIED** — `tests/test_converter.py::TestMultiGraphChaining`, resulting IR:
>
> ```text
> coreai.graph @add(... {coreai.name = "x"} ... {coreai.name = "y"}) -> (... {coreai.name = "added"})
> coreai.graph @mul(... {coreai.name = "a"} ... {coreai.name = "b"}) -> (... {coreai.name = "muled"})
> ```

and they come back out through the runtime descriptor:

> ✅ **VERIFIED** — `docs/coreai-core/tutorials/run-an-aimodel.ipynb`:
>
> ```python
> async with asset.executable() as model:
>     print(f"functions: {model.function_names}")
>     function: InferenceFunction = model.load_function("main")
>     desc = function.desc
>     print(f"name:    {desc.name}")
>     print(f"inputs:  {desc.input_names}")
>     print(f"outputs: {desc.output_names}")
> ```
>
> `desc.state_names` exists too (`tests/utils.py` iterates it to build the state dict).

> 🔴 **GAP — there is no documented character set or length limit for these names.** Every example
> uses lowercase snake_case ASCII identifiers. Whether Unicode, spaces, leading digits or very long
> names are accepted, rejected, or silently mangled by the MLIR attribute round-trip is unverified.
> **What would resolve it:** a validation rule in `_resolve_io_names`, or a documented constraint.
> **Safe default meanwhile:** stick to `[a-z][a-z0-9_]*`, which is what every Apple asset in the
> corpus uses — `pixel_values`, `input_ids`, `backbone_features`, `text_features`, `pred_masks`,
> `attention_mask`, `logits`, `image`.

### 7.5 Name your outputs the way your consumer wants to read them

Two facts from the runtime side make output naming a design decision rather than a formality.

**Output dict key order is not deterministic.**

> ✅ **VERIFIED** — Apple's `common_issues.md` agent-skill reference: *"Output dict key order is
> non-deterministic → identify outputs by shape, not index."*

That is the fallback advice for when you *don't* have good names. With good names you address
outputs by name and the ordering never matters. This is a concrete reason to name every output even
on a single-output model.

**Consumers duck-type on your names.** Apple's own Swift packages do substring matching over the
descriptor rather than hardcoding:

> ✅ **VERIFIED** — `ImageSegmentationEngine.swift:1193–1270`:
>
> ```swift
> static func findImageInputName(in names: [String]) -> String? {
>     names.first { let l = $0.lowercased(); return l.contains("pixel") || l.contains("image") }
> }
> ```
>
> So an input named `"img"` would not be found by Apple's own segmentation engine, while
> `"pixel_values"` or `"input_image"` would. If you are producing an asset for one of the
> `coreai-models` Swift products, **match its vocabulary**: `pixel_values`, `input_ids`,
> `attention_mask`, `backbone_features`, `text_features`, `logits`, `keyCache`, `valueCache`.

For the LLM engines the contract is even tighter — positional, not by name:

> ✅ **VERIFIED** — `CoreAISequentialEngine.swift:24–32` documents its expected model as *"2 inputs:
> `input_ids` (Int32), `position_ids` (Int32); 1 output: `logits`; 2 states: `keyCache`,
> `valueCache`"*, and the initializer validates `descriptor.inputNames.count == 2`,
> `outputNames.count >= 1`, `stateNames.count == 2`, then reads them **positionally**
> (`inputs[0]` = input_ids, `inputs[1]` = position_ids, `states[0]` = key, `states[1]` = value,
> `outputs[0]` = logits). **Order matters as much as spelling** on that path.

### 7.6 A worked example: naming for a Swift consumer

```python
"""Convert a small image classifier with an explicit, stable IO contract."""

from pathlib import Path

import torch
import torchvision.models as tv_models
from coreai_torch import TorchConverter, get_decomp_table

model = tv_models.mobilenet_v2(weights=None).eval()
example_input = (torch.randn(1, 3, 224, 224),)

exported = torch.export.export(model, args=example_input)
exported = exported.run_decompositions(get_decomp_table())

coreai_program = (
    TorchConverter()
    .add_exported_program(
        exported,
        input_names=["image"],      # <- Swift: fn.run(inputs: ["image": nd])
        output_names=["logits"],    # <- Swift: outputs.remove("logits")
    )
    .to_coreai()
)
coreai_program.optimize()

# Assert the contract before anything downstream can depend on it.
ir = str(coreai_program)
assert 'coreai.name = "image"' in ir
assert 'coreai.name = "logits"' in ir

asset = coreai_program.save_asset(Path("MobileNetV2.aimodel"))
```

> ✅ **VERIFIED** — the conversion body is `docs/getting-started/quickstart.ipynb` cell 14 verbatim
> (note: `torchvision` is **not** a `coreai-torch` dependency; the quickstart says
> `pip install torchvision`). The `filecheck`-style assertions mirror what Apple's own tests do:
> `filecheck_pattern(str(coreai_program), check_file='// CHECK: coreai.name = "image"')` in
> `tests/utils.py`. Plain `in` checks need no extra dependency.

---

## 8. Dynamic shapes: keeping the traced length out of the asset

Every dimension of your example input is static by default (§3.2). For a sequence model that is
usually wrong: you traced with 128 tokens and now the asset only accepts 128 tokens.

### 8.1 The mechanism is upstream, not Apple's

There is **no `dynamic_shapes` parameter on `TorchConverter`.** Dynamic dimensions are declared on
`torch.export.export`, and the converter reads them out of the exported program.

```python
import torch
from coreai_torch import TorchConverter, get_decomp_table

batch = torch.export.Dim("batch", min=1, max=16)
seq   = torch.export.Dim("seq",   min=1, max=2048)

ep = torch.export.export(
    model,
    args=(torch.randint(0, 32000, (1, 128)),),
    dynamic_shapes={"input_ids": {0: batch, 1: seq}},
)
ep = ep.run_decompositions(get_decomp_table())

program = (
    TorchConverter()
    .add_exported_program(ep, input_names=["input_ids"], output_names=["logits"])
    .to_coreai()
)
program.optimize()
```

> ✅ **VERIFIED** — the mechanism is the standard `torch.export` one:
> `torch.export.export(model, args=..., dynamic_shapes={...})` with
> `torch.export.Dim("batch", min=1, max=10)`. `coreai-torch` does not extend or replace it.

What arrives in the Core AI IR:

> ✅ **VERIFIED** — `get_tensor_type` in `coreai_torch/_utils.py`:
> `dim = ShapedType.get_dynamic_size() if isinstance(s, torch.SymInt) else s` — a dynamic dimension
> prints as `?` in the tensor type. Externalized subgraphs propagate it:
> `coreai.graph noinline @inner_<hash>(%arg0: tensor<?x4xf32>) -> tensor<?x4xf32>`.

And at the far end of the pipeline, the same `?` is what Xcode's model viewer shows:

> ✅ **VERIFIED** — the Core AI documentation and WWDC26 session 324 agree: *"A question mark in an
> `NDArray` dimension means the dimension is dynamic and is supplied or determined at runtime."*
> So the `?` you see in Xcode's `.aimodel` viewer is a direct rendering of the `Dim` you declared in
> Python. That round trip is the cheapest possible confirmation you got dynamic shapes right.

### 8.2 Apple's own test helper, which is worth stealing

Declaring `Dim` objects by hand gets verbose the moment two tensors must share a symbol. Apple's
test suite has a helper whose *docstring* is the documentation for the semantics:

> ✅ **VERIFIED** — `tests/utils.py:81`:
>
> ```python
> def make_dynamic_shapes(**arg_specs) -> dict[str, dict[int, torch.export.Dim]]:
>     """Pass each model argument as a keyword, mapped to either a list of dim names
>     (index = position) or a dict of {dim_index: dim_name}. Using the same string name for two
>     positions in different tensors produces the *same* Dim object. Use None to leave a dim static."""
>
> # make_dynamic_shapes(x=["batch", "seq", "feat"])
> # make_dynamic_shapes(mat1=["batch", "M", "K"], mat2=["batch", "K", "N"])
> # make_dynamic_shapes(x={0: "batch"}, y={0: "batch"})
> # make_dynamic_shapes(x=["batch", None, "h", "w"])
> ```

The rule that matters: **the same string name in two tensors produces the same `Dim` object**, which
is how you tell the exporter that `mat1`'s K and `mat2`'s K are the same runtime value. Get that
wrong and you either over-constrain (two independent dims forced equal) or under-constrain (a matmul
whose contraction dim the compiler cannot prove matches).

Since it lives in `tests/`, it is not importable from an installed wheel. Reproduce it in your own
conversion package — it is ~15 lines — or write the `Dim` objects out longhand as in §8.1.

### 8.3 The SymInt sharp edges specific to this converter

Dynamic shapes turn concrete Python `int`s into `torch.SymInt`s that flow through the graph as real
graph nodes. `coreai-torch` has had a run of fixes in exactly this area, and the resulting behaviours
are things you can trip over.

**Slice ends silently clamp.** This is a genuine correctness carve-out and Apple annotates it as one:

> ✅ **VERIFIED** — `resolve_slice_arg` in `_aten_to_core.py`, verbatim:
>
> ```python
> SLICE_INT32_MAX: int = 2**31 - 1
> # ATen uses INT64_MAX (~9.2e18) to mean "slice to end". Core AI indices are si32, so values above
> # INT32_MAX overflow to negative (e.g. INT64_MAX -> -1), causing coreai.slice_ to compute a wrong
> # output shape. Clamp to INT32_MAX.
> return min(val, SLICE_INT32_MAX)
> ```
>
> Symbolic slice arguments are rejected outright rather than clamped:
> `ValueError("Symbolic SymInt slice argument is not supported: … Use fx.Node references (e.g.
> results of aten.sym_size.int).")`

**64-bit dtypes are narrowed everywhere.**

> ✅ **VERIFIED** — `_utils.py:305`:
>
> ```python
> # Narrow int64/fp64 to int32/fp32 since coreai does not handle 64-bit types.
> _NARROW_TORCH_DTYPE: dict[torch.dtype, torch.dtype] = {
>     torch.int64: torch.int32,
>     torch.float64: torch.float32,
> }
> ```
>
> `check_result_type` accepts either the wide or the narrowed dtype, so nothing complains. **Values
> beyond the int32 range will be wrong**, silently. Token IDs, positional indices and hash-like
> integers are the realistic exposure; anything above ~2.1 billion is not representable. A related
> open report (PR#45, closed without merge) covers int64→int32 **accumulator** narrowing in
> `sum`/`prod`, which is the same hazard one level deeper.

**Six related SymInt hardening fixes landed in one commit**, and reading the list tells you where the
remaining risk is concentrated:

> ✅ **VERIFIED** — commit `53d6bdd`, *"harden mixed-source SymInt lowerings under dynamic shapes"*:
>
> 1. a bare `'pow'` resolver entry, because *"torch.export rewrites leave `aten.pow` as the
>    OpOverloadPacket target with no overload suffix"* → previously `Unsupported ATen op: pow`;
> 2. a bare `'round'` for the same reason;
> 3. `upsample_build_output_shape_dynamic`: force each `(out_h, out_w)` operand to rank-1 int32
>    before the concat — *"the dialect verifier rejects mixed-rank / mixed-element-type concat
>    inputs"*;
> 4. `get_operand`'s mixed-list path (SymInt `fx.Node`s plus plain ints): normalise every element to
>    canonical rank-1 si32. **Affects `view`, `expand`, `reshape`, `repeat`** — i.e. the most common
>    shape-manipulation ops in any dynamic model;
> 5. `replace_cat`: when one input has a dynamic non-concat axis and a sibling is static on that
>    axis, reshape the dynamic side first;
> 6. `replace_arange_start_step`: unify start/end/step element types before `coreai.range_`.
>
> Two ops reject dynamic values outright rather than mis-lowering, which is the behaviour you want:
> `max_pool2d` raises `ValueError(f"Encountered dynamic stride at maxpool2d: node: {node}, name: {node.name}")`,
> and transposed conv3d raises `ValueError("Transposed conv3d is not yet supported…")`.

### 8.4 Externalization + dynamic shapes: a known open bug

If you combine composite-op externalization (§5.3) with a *mixed* static/dynamic shape policy, there
is an open bug with a precise trigger:

> ✅ **VERIFIED** — `coreai-torch#1` (OPEN), *"externalize: SDPA submodule re-export drops the upper
> bound on the key-length dim with a static query + dynamic KV context"*:
>
> ```text
> RuntimeError: Internal error: failed to export submodule 'sdpa_061e31ac': Constraints violated (d_20)!
>   - Not all values of d_20 = L['key'].size()[2] in the specified range satisfy the generated guard
>     12 <= L['key'].size()[2] and L['key'].size()[2] <= IntInfinity()
> Suggested fixes:
>   d_20 = Dim('d_20', min=12)
> This is a coreai-torch bug. Please report it.
> ```
>
> Why Apple's shipped models don't hit it, verbatim from the report: *"The shipped models keep the
> **query** dynamic as well, so query and key share a single bounded symbol. The bug only surfaces
> when `query_len` is static (a fixed prefill chunk / single decode step) while the context is
> dynamic — which is what you need for hybrid linear-attention models (e.g. Qwen3.5 / Qwen3-Next
> Gated DeltaNet), where the query must be a static chunk so the recurrence's `scf.while` lowers."*
>
> Internals named: `_dim_for_sym` in `_utils.py` reads `var_to_range` when reconstructing the `Dim`
> for the submodule re-export; a `torch._check(key.size(-2) <= cap)` in the **parent** forward does
> **not** propagate into that re-export. PR `coreai-torch#7` targeted it; closed unmerged 2026-07-29.
>
> **Workaround:** drop `SDPA` from the externalize list so it decomposes to primitive ops — you lose
> the composite (and its fast path) but the conversion completes.

At least this one is loud. The failure is a `RuntimeError` at conversion time with the phrase *"This
is a coreai-torch bug. Please report it."* in it.

### 8.5 The shape policy table

Assembled from Apple's shipped exports and from reproducers in the issue tracker. **Every row is a
verified observation, and the middle rows are why "just make everything dynamic" is not obviously
wrong advice:**

| Query shape | Context shape | Consequence |
|---|---|---|
| dynamic | dynamic (shared symbol) | What Apple's shipped models do; works |
| **static** | dynamic | SDPA externalize re-export fails (`coreai-torch#1`); 2+ `GatedDeltaUpdate` layers crash MPSGraph (`coreai-torch#2`) |
| static | static, **runtime-value** `slice_update` begin/end | `ANECompiler` `addOpToNetwork` `EXC_BAD_ACCESS` at `AIModel.load` (`coreai-torch#6`); maintainer says fixed in beta 4 |
| static | static, **constant** `slice_update` begin/end | Works — the sliding-window workaround |
| dynamic monolithic stateful | prefill chunk > 16 tokens | Nondeterministic (`coreai-models#84`, not reproduced by Apple) |

> ✅ **VERIFIED** — rows assembled from the named issues in `apple/coreai-torch` and
> `apple/coreai-models`. Statuses as of 2026-07-29.

### 8.6 The iOS counter-current

One caution before you make everything dynamic. Apple's own `model-authoring` agent skill treats
**fully static shapes as a hard Neural Engine requirement**:

> ✅ **VERIFIED** — `apple/coreai-models/skills/skills/model-authoring/`, at-a-glance table:
>
> | Aspect | Neural Engine | GPU |
> |---|---|---|
> | Shapes | **Fully static** | Dynamic supported |
> | Tensor layout | BC1S `(B, H*D, 1, S)` | Standard `(B, S, D)` |
> | Projections | `nn.Conv2d(kernel_size=1)` | `nn.Linear` (fused QKV) |
> | Attention | Per-head sequential | Fused native SDPA |
> | Float precision | fp16 only — no fp32 literals anywhere | fp16 weights, fp32 intermediates OK |
>
> corroborated by WWDC26 session 325 lines 216–217: *"especially when targeting iOS, is the usage of
> **static tensor shapes, channels-first tensor layouts and convolutional op patterns**. These enable
> Core AI to leverage powerful underlying primitives."*

So dynamic shapes are a GPU/macOS affordance, and the iOS answer is *many static specializations*
rather than one dynamic graph:

> ✅ **VERIFIED** — `neural_engine_rules.md`: the NE entrypoint set is `extend_{ctx}_{len}`,
> `prompt_opt_{ctx}_{len}`, `gather_embeddings_{N}`, with the note *"All functions compile from **one
> dynamic `torch.export`** via Core AI shape specialization."* Static iOS LLM exports in the wild
> contain **~34 functions**. One export, many specializations — which is a different technique from
> the multi-function split in §10, and belongs to Part 10.

**Decision rule.** Declare a dim dynamic when the runtime value genuinely varies and you are
targeting the GPU. Declare it static when you are targeting the Neural Engine, or when the variation
is over a small known set (then produce a specialization per value). Never leave a dim static *by
accident* because you forgot `dynamic_shapes=` — that is the failure this section exists to prevent.

---

## 9. State: mutable buffers become Core AI states

A Core AI function has three kinds of tensor in its signature: **inputs**, **outputs**, and
**states**. States are the third thing, they are how a KV cache lives across calls, and they are
created implicitly by patterns in your PyTorch code.

### 9.1 What counts as state — and there is no opt-out

> ✅ **VERIFIED** — `docs/api/TorchConverter.md`, verbatim:
>
> > **What counts as state (no opt-out).** The converter treats two things as state:
> > 1. **Mutable buffers** registered via `self.register_buffer(...)` and mutated in-place inside
> >    `forward()` (e.g., `self.buf.add_(x)`).
> > 2. **User inputs mutated in-place** inside `forward()` (e.g., `x.mul_(2)` on a `forward()` arg).
> >
> > Both are detected from the exported program's graph signature. There is **no flag** to opt a
> > mutated user input out of state. … If you don't want a `forward()` argument treated as state,
> > eliminate the in-place mutation from your model — clone first
> > (`x_local = x.clone(); x_local.mul_(2)`) or use the out-of-place form (`x_scaled = x * 2`).

Read case 2 again. **An in-place mutation of an argument silently changes your function's calling
convention.** A single `x.mul_(2)` inside `forward` moves `x` out of `input_names` and into
`state_names`, which means the Swift caller must now bind it as a state rather than pass it as an
input, and the count check will reject an `input_names` list that still mentions it. This is the sort
of edit that looks like a micro-optimization ("avoid an allocation") and is actually an API change.

The only remedy is source-level: clone, or go out-of-place.

### 9.2 The full worked example

> ✅ **VERIFIED** — `docs/api/TorchConverter.md`, verbatim:
>
> ```python
> class KVCache(nn.Module):
>     def __init__(self):
>         super().__init__()
>         self.register_buffer("kv_cache", torch.zeros(1, 4))   # state[0]
>         self.register_buffer("pos_idx", torch.zeros(1))       # state[1]
>
>     def forward(self, x, y, z):
>         self.kv_cache.add_(x)       # buffer mutation
>         self.pos_idx.add_(1)        # buffer mutation
>         y.mul_(2)                   # state[2]: mutated user input
>         # non-mutated: x -> input[0], z -> input[1]
>         return self.kv_cache + y, z * 3
>
> ep = torch.export.export(KVCache().eval(),
>                          args=(torch.randn(1, 4), torch.randn(1, 4), torch.randn(1, 4)))
> ep = ep.run_decompositions(get_decomp_table())
>
> TorchConverter().add_exported_program(
>     ep,
>     state_names=["kv_cache", "pos_idx", "y_state"],
>     input_names=["query", "context"],
>     output_names=["attn_out", "scaled"],
> ).to_coreai().optimize()
> ```

Trace the counts, because they are the whole lesson:

- `forward` has **three** parameters, but `input_names` has **two**. `y` is a state.
- There are **two** buffers, but **three** state names. `y` is the third.
- `state_names` order is **buffers in registration order, then mutated user inputs in signature
  order** — hence `["kv_cache", "pos_idx", "y_state"]`.
- The names you give states apply to **both** the input side and the mutation-output side. One name,
  two roles.

The realistic version, from Apple's test suite:

> ✅ **VERIFIED** — `tests/test_stateful.py::test_kv_cache_pattern`:
>
> ```python
> class KVCacheModel(nn.Module):
>     def __init__(self):
>         super().__init__()
>         self.register_buffer("k_cache", torch.zeros(1, 4, 8))
>         self.register_buffer("v_cache", torch.zeros(1, 4, 8))
>
>     def forward(self, q, k, v):
>         self.k_cache.copy_(k)
>         self.v_cache.copy_(v)
>         attn = torch.matmul(q, self.k_cache.transpose(-2, -1))
>         return torch.matmul(attn, self.v_cache)
> ```

WWDC26 session 325 names this pattern explicitly as one of the three re-authoring mechanisms:

> ✅ **VERIFIED** — session 325, lines 213–215: *"using predefined patterns in the PyTorch code that
> tell Core AI about a specific concept. This allows the framework to **map these semantics to an
> optimized implementation at runtime**. An example of this, is **in-place updates of the Key-Value
> cache** commonly used in Large Language models."*

So the in-place buffer mutation is not a workaround the converter tolerates — it is the **intended
signalling channel** for "this is a cache."

### 9.3 ⚠️ SILENT FAILURE — state ordering is an assumption, not a guarantee

The converter checks that the number of state inputs equals the number of state outputs, and it
asserts the buffers-then-inputs ordering invariant:

> ✅ **VERIFIED** — `_utils.py::_resolve_io_names`:
>
> ```text
> assert len(state_in_idx) == len(state_out_idx)
>   -> "State input/output count mismatch: … This may indicate an unsupported graph signature layout."
>
> "FX placeholder order violates the 'mutable buffers first, then mutated user inputs' invariant.
>  … This breaks the documented state_names ordering — pass state_names explicitly matched to your
>  buffer/arg names, or check PyTorch version compatibility."
> ```

But the documentation is explicit about the limit of those checks:

> ✅ **VERIFIED**, verbatim: *"The converter asserts that the number of state inputs matches state
> outputs, but **cannot detect silent reordering**."*

> ⚠️ **SILENT FAILURE.** Two buffers of the same shape and dtype — say `k_cache` and `v_cache`, which
> is the overwhelmingly common case — can swap positions across a PyTorch upgrade and every check in
> the pipeline still passes. Count matches. Ordering invariant holds. Shapes match. Dtypes match. You
> ship an asset where the Swift caller binds its key cache to the slot the graph uses for values.
> Output is plausible garbage.
>
> **Defence, and it is cheap.** Never let `state_names` default. Assert on the descriptor after
> conversion, and assert on the *content*, not just the names:
>
> ```python
> # Ordering canary: give the two caches distinguishable initial values and check
> # which one comes back changed.
> desc = function.desc
> assert desc.state_names == ["k_cache", "v_cache"], desc.state_names
> ```
>
> A name assertion catches a rename. To catch a *reorder* you need §11's numerics gate with
> asymmetric state contents — identical zeros will not distinguish them.

### 9.4 The runtime state protocol, and its own footgun

Binding states from Python looks like this:

> ✅ **VERIFIED** — `tests/utils.py`:
>
> ```python
> state: dict[str, NDArray] = {}
> for name in desc.state_names:
>     d = desc.state_descriptor(name=name)
>     shape = tuple(s if s is not None else 1 for s in d.shape)
>     state[name] = NDArray(np.zeros(shape, dtype=np.dtype(d.dtype)))
> ...
> rt_outputs = await rt_func(inputs=inputs, state=state)
> ```
>
> Note the two-argument call form: `await fn(inputs={...}, state={...})` for stateful functions,
> versus the single positional dict for stateless ones.
>
> ⚠️ **Footgun, from the source comment:** `NDArray.from_descriptor` **only sizes** the buffer. On
> Linux the backing storage is not zeroed, so buffer-state reads return **garbage on the first
> call**. Allocate a zero-filled numpy array and wrap that, exactly as the snippet does. Do not use
> `from_descriptor` for state you intend to read before writing.
>
> Note also the `s if s is not None else 1` — a state descriptor can carry a dynamic dimension, and
> the harness materialises it as 1.

The IR annotation that carries all this:

> ✅ **VERIFIED** — each stateful input gains a `MutableBuffers.buffer_mutation` attribute alongside
> its `coreai.name`:
>
> ```text
> coreai.graph @main(
>   %0: tensor<1x4xf32> {MutableBuffers.buffer_mutation = "b_state", coreai.name = "b_state"},
>   %1: tensor<1x4xf32> {coreai.name = "x"}
> ) -> (tensor<1x4xf32> {coreai.name = "b_state"})
> ```
>
> and a regression worth knowing about, from `tests/test_stateful.py`: before a fix, the annotation
> loop looked up `inputs_to_buffers` using the **renamed** graph input names, while that map is keyed
> by **original FX placeholder** names — so passing custom `input_names` **silently dropped
> `MutableBuffers.buffer_mutation` entirely**. The test exists because the failure was invisible.

### 9.5 State requires `optimize()`

Restating §6.6 because this is where it bites: mutation outputs become handle tokens only after
`_UPDATE_SIGNATURE_TO_HANDLES` and `_PROPAGATE_HANDLE_UPDATES` run. **A stateful model that skips
`optimize()` has no working state protocol**, and Apple's own comparison helper says so in a comment:
*"state mutation outputs become tokens after optimize and won't appear here."*

### 9.6 What the Swift side expects

For LLM assets specifically, `apple/coreai-models` bakes in state conventions you should match:

> ✅ **VERIFIED** — `CoreAISequentialEngine.swift:24–32`: *"2 states: `keyCache`, `valueCache` —
> persistent across steps, updated in-place. KV cache `NDArray`s start small (256 tokens) and grow
> dynamically with 2× expansion."*
>
> and the compute-unit-specific cache layouts, from `model-authoring`'s reference:
>
> | Compute unit | Cache shape | Seq dim | Pattern |
> |---|---|---|---|
> | Neural Engine | `[n_layers, B, H_kv*D, 1, max_S]` | 4 | **Readonly functional I/O** — the model has no cache writes; it returns new K/V as *outputs* |
> | GPU | `[n_layers, B, H_kv, max_S, D]` | 3 | Stateful export wrapper — `register_buffer` + `hoistToArg` |
>
> ⚠️ Note that the Neural Engine path **does not use Core AI state at all**. It returns new K/V as
> ordinary outputs and the caller threads them back in as inputs. So "use `register_buffer` for your
> KV cache" is GPU advice, not universal advice. Choosing wrong here is a re-authoring decision, not
> a converter flag — Part 10.
>
> One more from the same reference, because it is a 20 dB-class silent failure: *"**return
> `key_rope`, not raw `new_k`** — if you cache pre-RoPE K, the next call attends to stale
> non-RoPE-encoded keys → PSNR collapses to ~20 dB."*

---

## 10. Multi-function assets, and the finding that reframes them

One `.aimodel` can contain many callable functions. The API for that is three lines long and the
consequences are much larger than the API suggests.

### 10.1 One converter, N exported programs, N entrypoint names

> ✅ **VERIFIED** — `tests/test_converter.py::TestMultiGraphChaining`:
>
> ```python
> coreai_program = (
>     TorchConverter()
>     .add_exported_program(add_model, input_names=["x", "y"],
>                           output_names=["added"], entrypoint_name="add")
>     .add_exported_program(mul_model, input_names=["a", "b"],
>                           output_names=["muled"], entrypoint_name="mul")
>     .to_coreai()
> )
> ```
>
> producing two graphs in one module:
>
> ```text
> coreai.graph @add(... {coreai.name = "x"} ... {coreai.name = "y"}) -> (... {coreai.name = "added"})
> coreai.graph @mul(... {coreai.name = "a"} ... {coreai.name = "b"}) -> (... {coreai.name = "muled"})
> ```

Rules, all verified:

- `entrypoint_name` defaults to **`"main"`**, and must be **unique** across staged programs; a
  duplicate raises at `add_*` time.
- You may mix `add_exported_program` and `add_pytorch_module` on one converter.
- `to_coreai(entrypoints=["encoder"])` converts a subset; an unknown name raises.
- Each program brings its **own** `input_names` / `output_names` / `state_names`.

The Swift caller then addresses functions by name:

```swift prelude:guide-context
let model = try await AIModel(contentsOf: modelURL)
guard let encode = try model.loadFunction(named: "image_encode") else { return }
```

and in Python, `model.function_names` lists them and `load_function(name)` binds one.

### 10.2 SAM3: Apple's shipped three-function split

> ✅ **VERIFIED** — this is real, shipping code:
> `apple/coreai-models/python/src/coreai_models/segmentation/pipeline.py:265–286`:
>
> ```python
> logger.info("Converting to Core AI...")
> converter = coreai_torch.TorchConverter()
> converter.add_exported_program(
>     img_program,
>     entrypoint_name="image_encode",
>     input_names=["pixel_values"],
>     output_names=["backbone_features"],
> )
> converter.add_exported_program(
>     txt_program,
>     entrypoint_name="text_encode",
>     input_names=["input_ids"],
>     output_names=["text_features"],
> )
> converter.add_exported_program(
>     det_program,
>     entrypoint_name="detect",
>     input_names=["backbone_features", "text_features"],
>     output_names=["pred_masks", "pred_boxes", "pred_logits", "presence_logits", "semantic_seg"],
> )
> coreai_program = converter.to_coreai()
> coreai_program.optimize()
>
> metadata = build_aimodel_metadata(config.hf_model_id)
> coreai_program.save_asset(asset_path, metadata)
> ```

Two details in that snippet that appear nowhere in the session:

1. **`save_asset` takes an optional second positional argument**, an asset-metadata object. The
   quickstart's `save_asset(path)` is the one-argument form.
2. **`detect`'s inputs are the other two functions' outputs, by name.** `backbone_features` and
   `text_features` are output names on one function and input names on another. That naming
   discipline is what makes the three functions composable at the call site.

The three exported programs are each built the same way — export, decompose with Apple's table, cast
to fp16 — before any of them reaches the converter:

> ✅ **VERIFIED** — `pipeline.py:250–263`:
>
> ```python
> img_program = torch.export.export(img_enc, args=(pixel_ref,))
> img_program = img_program.run_decompositions(coreai_torch.get_decomp_table())
> img_program = cast_to_16_bit_precision(img_program)
> # ...same for txt_program and det_program
> ```
>
> `cast_to_16_bit_precision` is from `coreai_opt.casting` and operates on the **`ExportedProgram`** —
> after export and decomposition, not on the `nn.Module`. Part 9.

And the reference tensors, which reveal the interfaces:

> ✅ **VERIFIED** — `pipeline.py`:
>
> ```python
> pixel_ref     = torch.randn(1, 3, image_size, image_size)                      # 336 for iOS
> ids_ref       = torch.randint(0, 49408, (1, config.max_text_seq_len), dtype=torch.int32)
> backbone_ref  = torch.randn(1, 1024, 1, grid * grid)          # grid = 336 // 14 = 24 -> 576
> text_feat_ref = torch.randn(1, 256, 1, config.max_text_seq_len)
> ```
>
> The `(B, C, 1, S)` shapes are **BC1S** — the channels-first Neural Engine layout. `336` is
> deliberate: *"`image-size=336` is the resolution we recommend for iOS deployment."*

### 10.3 What session 325 says the split buys you

> ✅ **VERIFIED** — session 325, lines 224–230: *"The biggest change I make is to have **three
> separate functions in the Core AI Model instead of one. `coreai-torch` has APIs that lets you do
> this.** … **Splitting the work this way allows me to run each bit at a different cadence.** For
> example, I may want to process a single prompt once and use it across a variety of images. It also
> gives each function a **clean interface**, and lets me **compress and author each one
> independently**."*
>
> and the payoff, lines 249–262: *"I swapped the prompt to butterfly and only re-ran the text encoder
> and the detector. As a result, the **second inference is 76% faster, even after warmup**."*

**Attribution: Apple-published**, WWDC26 session 325, demoed on a Mac, no hardware model, OS build or
methodology given. Treat 76% as an existence proof of the *shape* of the win, not as a number you can
plan against.

The "compress each one independently" claim is the most concretely useful part, and the shipped
recipe is more nuanced than the talk:

> ✅ **VERIFIED** — `apple/coreai-models/models/sam3/README.md`:
>
> | Function | Compression | Inputs | Outputs |
> |---|---|---|---|
> | `image_encode` | **4-bit** k-means palettization (gs=32) + fp16 | `pixel_values` | `backbone_features` |
> | `text_encode` | **6-bit** k-means palettization (gs=8) + fp16 | `input_ids` | `text_features` |
> | `detect` | fp16 only, **no weight compression** | `backbone_features`, `text_features` | `pred_masks`, `pred_boxes`, `pred_logits`, `presence_logits` |
>
> ⚠️ **Discrepancy worth carrying:** the transcript (325:241) says *"I apply 4-bit palettization … to
> the two encoders."* The shipped recipe is **asymmetric** — image w4/gs32, text **w6/gs8**. The talk
> simplified. Independent per-function compression is exactly why the split is worth having, and the
> shipped numbers are the honest illustration of it.

That asymmetry is downstream of a diagnosis, not a guess: uniform 4-bit quantization across the whole
model lost an occluded flower in the demo, and the Debugger traced the low-PSNR sync points to the
detector — which holds only **4% of the parameters** (the two encoders are 96%), so compressing it
bought almost nothing and cost quality. §12 is about the metadata that made that traceable.

### 10.4 The sample-runtime finding: the split selects `coreai-models`’ ANE policy

Reading the shipped Swift runtime shows the split is doing something the session never mentions.

> ✅ **VERIFIED** — `apple/coreai-models`, `swift/Sources/CoreAIShared/Runtime/ModelStructure.swift`.
> Well-known function names (`:12–20`):
>
> ```swift
> public enum GraphNames {
>     public static let main = "main"
>     public static let loadEmbeddings = "load_embeddings"
>     public static let extendPrefix = "extend"
>     // Multi-function segmenter (lite SAM3 export for iOS).
>     public static let imageEncode = "image_encode"
>     public static let textEncode  = "text_encode"
>     public static let detect      = "detect"
> }
> ```
>
> Three structures (`:29–39`):
>
> ```swift
> public enum ModelStructure: Equatable, Sendable, CustomStringConvertible {
>     case chunkedStatic(batchSize: Int)   // has extend_* AND load_embeddings
>     case dynamic                          // has main
>     case multiFunctionSegmenter           // has image_encode AND text_encode AND detect
> }
> ```
>
> and the compute-unit mapping (`:57–80`) — **this is the causal link**:
>
> ```swift
> public var preferredDevice: String {
>     switch self {
>     case .chunkedStatic, .multiFunctionSegmenter: return "NeuralEngine"
>     case .dynamic:                                 return "GPU"
>     }
> }
>
> public var specializationOptions: SpecializationOptions {
>     switch self {
>     case .chunkedStatic, .multiFunctionSegmenter:
>         return SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
>     case .dynamic:
>         var opts = SpecializationOptions(preferredComputeUnitKind: .gpu)
>         opts.expectFrequentReshapes = true
>         return opts
>     }
> }
> ```

**Inside the optional `coreai-models` loader, the three-function SAM3 split is not merely a latency
trick — it selects that package’s Neural Engine preference.** A single-`main` SAM3 export loaded
through the same helper is classified `.dynamic` and receives its GPU preference. This is package
policy, not a Core AI framework rule: direct `AIModel` callers choose their own
`SpecializationOptions`, and `.default` asks Core AI to minimize latency across available compute
units.[^sample-routing-policy]

The detection is name-based, cheap, and happens **before** specialization:

> ✅ **VERIFIED** — `ModelStructure.swift`, detection order (`:190–218`):
>
> 1. `extend*` + `load_embeddings` → `.chunkedStatic(batchSize:)`, batch parsed from
>    `extend_<context>_<batch>` by splitting on `_` and taking index 2;
> 2. `image_encode` ∧ `text_encode` ∧ `detect` → `.multiFunctionSegmenter` — checked **before** the
>    `main` fallback, with the comment *"checked before the `main` fallback because some asset
>    variants ship a thin `main` graph alongside the trio"*;
> 3. `main` → `.dynamic`;
> 4. otherwise → `.dynamic` with a warning log.
>
> and the two-phase load (`:145–165`):
>
> ```swift
> public static func prepare(at url: URL) async throws -> PreparedModel {
>     // Probe structure before specializing so we can pick the right compute-unit preference.
>     let probedStructure = probeStructure(at: url)
>     let options = probedStructure.specializationOptions
>     let model = try await AIModel(contentsOf: url, options: options)
>     // Re-detect from compiled library — source of truth, should match the probe.
>     let structure = detectStructure(from: model.functionNames)
>     return PreparedModel(model: model, structure: structure)
> }
> ```
>
> `probeStructure` reads function names via `AIModelAsset.summary(includingStatistics: false)`
> **without triggering specialization** — a cheap metadata read. On any failure it silently falls
> back to `.dynamic`.

> ⚠️ **Consequences you must design for.**
>
> 1. **Your entrypoint names are a routing decision when you adopt the `coreai-models` loader.** Name
>    your segmentation functions `encode_img` / `encode_txt` / `run_detect` and that helper classifies
>    the asset `.dynamic` and requests the GPU. Match `image_encode`, `text_encode`, `detect` when you
>    rely on this package policy; direct Core AI loaders may instead pass explicit or default options.
> 2. **The fallback is silent by design.** A probe failure defaults to `.dynamic` with a log line, not
>    an error.
> 3. **This is `coreai-models`' policy, not the Core AI framework's.** If you write your own loader,
>    you choose your own `SpecializationOptions` and none of this applies — but then you also have to
>    make the ANE-versus-GPU decision yourself. Reusing Apple's naming buys you Apple's policy.

### 10.5 ⚠️ And the 76% requires work Apple's own package does not do

The latency claim depends on *reusing* the image encoding across calls. Apple's shipped segmentation
engine does not.

> ✅ **VERIFIED** — `ImageSegmentationEngine.swift:871–920`, the multi-function run loop:
>
> ```swift
> private func runMultiFunctionInference(
>     state: MultiFunctionContext, imageArray: NDArray, textArray: NDArray
> ) async throws -> SegmentationOutput {
>     var imageOutputs = try await state.imageEncode.run(inputs: [state.imageInputName: imageArray])
>     guard let backboneFeatures = imageOutputs.remove(state.backboneFeaturesOutputName)?.ndArray
>     else { throw ... }
>
>     var textOutputs = try await state.textEncode.run(inputs: [state.textInputName: textArray])
>     guard let textFeatures = textOutputs.remove(state.textFeaturesOutputName)?.ndArray
>     else { throw ... }
>
>     var detectOutputs = try await state.detect.run(inputs: [
>         state.backboneFeaturesInputName: backboneFeatures,
>         state.textFeaturesInputName:      textFeatures,
>     ])
>     ...
> }
> ```
>
> > ⚠️ **The engine does not cache `backboneFeatures` across calls. Every `segment()` re-runs
> > `image_encode`.** The session-325 "76% faster second inference" story is about reusing the image
> > encoding when only the text prompt changes — but `CoreAISegmentationEngine` as written re-encodes
> > the image every time, and **exposes no API to hold the features**. To get the speedup you must
> > hold the `image_encode` output yourself.
> >
> > This is a genuine gap between the session narrative and the shipped code.

Note the one thing the engine *does* get right, which you should copy: `detect`'s inputs are the
**unmodified `NDArray` outputs** of the two encoders. No round trip through Swift arrays, no copy.
The doc comment says so: *"Outputs are pulled out of each `function.run` return dict — never
pre-allocated."*

**What to build instead.** If you are consuming a multi-function asset and want the cadence benefit,
own the orchestration:

```text
cache key = (image identity, image_encode function identity)
  on cache miss  -> run image_encode, store the returned NDArray
  on every call  -> run text_encode(prompt), then detect(cached_features, text_features)
```

That is caller-side work in your app, in Swift, and it is Part 7's territory. The point for *this*
guide is that **the split is a precondition for the optimization, not the optimization itself** — and
that if you convert with three entrypoints and then measure no improvement, the missing piece is
almost certainly the cache, not the conversion.

### 10.6 Two more multi-function facts worth having

**Selective conversion.** `to_coreai(entrypoints=[...])` lets one script produce several assets from
one staged set — e.g. a Mac asset with all three functions and an iOS asset with a subset. Staged
programs persist across `to_coreai()` calls; `clear()` drops them.

**The `.multiFunctionSegmenter` path has real limits.** Apple's engine rejects embedding queries on
it outright:

> ✅ **VERIFIED** — `ImageSegmentationEngine.swift:855–859`:
>
> ```swift
> case .embeddings:
>     throw SegmentationRuntimeError.unsupportedEngine(
>         "Multi-function segmentation assets accept token IDs only — "
>             + "the text_encode graph already projects them internally.")
> ```
>
> and the resulting capability matrix:
>
> | Asset | Structure | Compute unit | Text query | Point query | Embeddings query |
> |---|---|---|---|---|---|
> | SAM3 baseline (`main`) | `.dynamic` | GPU | ✅ | ❌ | ✅ if an `embed`/`text_feat` input exists |
> | SAM3 lite (3 functions) | `.multiFunctionSegmenter` | **Neural Engine** | ✅ | ❌ | ❌ (throws) |
> | EfficientSAM (`main`) | `.dynamic` | GPU | ❌ | ✅ | ❌ |
>
> Splitting a model changes what its callers can ask of it. That is a design consequence of the IO
> contract you chose, not a bug — but it should be a deliberate choice.

---

## 11. Verifying from Python: the gate you must not skip

Everything in §4, §6, §7 and §9 fails silently. There is exactly one mitigation that catches all of
them, and it is cheap: **run both models on the same input and compare.**

The reason this is cheap is a capability the session states plainly:

> ✅ **VERIFIED** — WWDC26 session 325, lines 49–51: *"Once I have the specialized asset, I can
> **load a function from the program** and perform inference right from Python. You can also **pass
> specialization options** at this point to customize the process. To actually run inference, all you
> need to do is provide **a dictionary mapping input names to corresponding numpy tensors**!"*
>
> and line 168: *"you can **specialize models into optimized assets, and run them natively on Apple
> Silicon entirely from Python**."*

You do not need a Swift app, a device, or a test harness to prove your conversion is right.

### 11.1 The reference implementation, verbatim

> ✅ **VERIFIED** — `docs/getting-started/quickstart.ipynb`, cell 12, verbatim:
>
> ```python
> import tempfile
> from pathlib import Path
>
> import numpy as np
> import torch
> from coreai.runtime import NDArray
>
>
> async def compile_and_run(coreai_program, example_input, model):
>     with tempfile.TemporaryDirectory() as tmpdir:
>         # Compile: save the AIProgram to an .aimodel directory on disk.
>         asset = coreai_program.save_asset(Path(tmpdir) / "quick_start_example.aimodel")
>
>         # Load: open the executable and bind the `main` function.
>         async with asset.executable() as ai_model:
>             function = ai_model.load_function("main")
>
>             # Run: invoke the function on the example input.
>             coreai_outputs = await function({"x": NDArray(example_input[0])})
>
>             # Compare with PyTorch: run the same input through the original model.
>             with torch.no_grad():
>                 pytorch_output = model(example_input[0])
>
>             coreai_output = coreai_outputs["out"].numpy()
>             pytorch_numpy = pytorch_output.numpy()
>
>             print(f"PyTorch output shape: {pytorch_numpy.shape}")
>             print(f"Core AI output shape: {coreai_output.shape}")
>             print(
>                 f"Outputs match: {np.allclose(pytorch_numpy, coreai_output, atol=1e-4)}"
>             )
>
>
> await compile_and_run(coreai_program, example_input, model)
> ```

Five facts this pins down that the transcript only gestures at:

- `save_asset()` returns an **`AIModelAsset`**; the `.aimodel` is a **directory**.
- Inference is **`async`**: `async with asset.executable() as ai_model`, then `await function(...)`.
- The default entrypoint name is **`"main"`**.
- Outputs come back **keyed by output name**; `.numpy()` materialises them.
- `NDArray(...)` *"accepts a NumPy array, a PyTorch tensor, or a Python list, wrapping the data
  without a copy where possible."*

> ⚠️ **Two lifecycle rules, both verbatim from `docs/coreai-core/tutorials/run-an-aimodel.ipynb`:**
>
> 1. *"`AIModelAsset.load` reads the `.aimodel` directory header from disk so you can inspect it;
>    **it does not yet compile the program for inference. That work happens lazily inside the
>    `executable()` async context manager**."* So the cost of specialization lands at the `async with`,
>    not at `load`.
> 2. *"**Materialize the result inside the block — the model's backing buffers are only guaranteed
>    valid until the context exits.**"* Call `.numpy()` before leaving the `async with`. Returning an
>    `NDArray` out of the block and reading it later is undefined.
>
> There is also a one-shot form: `await AIModel.load(path)` (optionally with
> `specialization_options=`), *"when you want a long-lived model handle without the `async with`
> block."*

One more gotcha that has bitten people, from Apple's own `common_issues.md`:

> ✅ **VERIFIED** — *"Call `.contiguous()` on all tensors before wrapping in `NDArray` — the runtime
> reads raw memory as if contiguous, ignoring tensor strides."* A non-contiguous PyTorch tensor (the
> result of a `.transpose()` or `.permute()`, very common in a test harness) will be read as garbage
> with no error. `NDArray(x.contiguous())`, always.

### 11.2 Tolerances: what "match" means

`atol=1e-4` is the quickstart's fp32 figure. Apple's own test harness is looser, and says why:

> ✅ **VERIFIED** — `tests/utils.py::validate_numerical_output` defaults to **`atol=1e-2`** because
> *"FP16 accuracy is flaky."*

For a whole-model judgement, prefer PSNR over `allclose` — it is the metric the Debugger uses by
default and the one Apple's acceptance table is written in:

> ✅ **VERIFIED** — session 325 line 148: *"The default metric is a **peak signal-to-noise ratio or
> PSNR**, but this can be changed to whichever similarity indicator suits your model best."*
> Acceptance thresholds from `working-with-coreai/SKILL.md`: **>70 dB** float32 end-to-end, **>50 dB**
> fp16 on device, **~40 dB** 4-bit palettized; investigate below 60/40/30 respectively.
>
> The `model-authoring` skill adds re-authoring gates: re-authored vs source **>70 dB**; NE-layout vs
> GPU-layout **>70 dB**; compiled vs torch **≥40 dB**; after 4-bit palettization **≥35 dB**.

```python
import numpy as np


def psnr(reference: np.ndarray, candidate: np.ndarray) -> float:
    """Peak signal-to-noise ratio in dB. Higher is better; inf means bit-identical."""
    reference = reference.astype(np.float64)
    candidate = candidate.astype(np.float64)
    mse = np.mean((reference - candidate) ** 2)
    if mse == 0.0:
        return float("inf")
    peak = np.max(np.abs(reference))
    return 20.0 * np.log10(peak) - 10.0 * np.log10(mse)
```

> 🟡 **RECONSTRUCTED** — Apple ships `scripts/quality_metrics.py` in the
> `model-compression-exploration` skill with *"PSNR/SNR/IoU + dispatcher"*, but its exact formula
> (peak definition, per-channel vs global) is unread in our corpus. The function above is the standard
> definition and will agree with Apple's to within the choice of peak. **If you are comparing your
> numbers to Apple's thresholds, use Apple's script when you have it.**

### 11.3 The IO-contract assertion

Before comparing numbers, assert on the descriptor. This is what catches §7.3 and §9.3:

```python
from pathlib import Path

from coreai.authoring import AIModelAsset

EXPECTED_INPUTS  = ["pixel_values"]
EXPECTED_OUTPUTS = ["backbone_features"]
EXPECTED_STATES: list[str] = []


async def assert_io_contract(asset_path: Path, entrypoint: str = "main") -> None:
    asset = AIModelAsset.load(asset_path)
    async with asset.executable() as model:
        assert entrypoint in model.function_names, model.function_names
        desc = model.load_function(entrypoint).desc
        assert list(desc.input_names)  == EXPECTED_INPUTS,  desc.input_names
        assert list(desc.output_names) == EXPECTED_OUTPUTS, desc.output_names
        assert list(desc.state_names)  == EXPECTED_STATES,  desc.state_names
```

> ✅ **VERIFIED** — the descriptor fields are `desc.name`, `desc.input_names`, `desc.output_names`,
> `desc.state_names` (`run-an-aimodel.ipynb` and `tests/utils.py`). `model.function_names` lists
> entrypoints. `load_function` raises `KeyError` on a missing name in Python.

Commit this as a test. It costs milliseconds and it is the only thing standing between a PyTorch
upgrade and a renamed public interface.

### 11.4 ⚠️ The `optimize=True` / `optimize=False` gate

This is the specific defence against §6.4, and the issue reporter's own recommendation:

> ✅ **VERIFIED** — `coreai-torch#49`'s guide takeaway, verbatim: *"`optimize()` is **not**
> semantics-preserving in all cases as of 0.4.1/1.0.0b2. Any pipeline guide should recommend an
> `optimize=True` vs `optimize=False` numerics gate as a standard step."*

```python
"""Convert twice — with and without optimize() — and fail loudly if they disagree."""

import asyncio
import tempfile
from pathlib import Path

import numpy as np
import torch
from coreai.authoring import AIModelAsset
from coreai.runtime import NDArray
from coreai_torch import TorchConverter, get_decomp_table


def build_program(ep, *, optimize: bool):
    program = (
        TorchConverter()
        .add_exported_program(ep, input_names=["x"], output_names=["y"])
        .to_coreai()
    )
    if optimize:
        program.optimize()
    return program


async def run_program(program, inputs: dict[str, np.ndarray]) -> dict[str, np.ndarray]:
    with tempfile.TemporaryDirectory() as tmpdir:
        asset = program.save_asset(Path(tmpdir) / "gate.aimodel")
        async with asset.executable() as model:
            fn = model.load_function("main")
            out = await fn({k: NDArray(np.ascontiguousarray(v)) for k, v in inputs.items()})
            # Materialize INSIDE the block — buffers are only valid until it exits.
            return {k: v.numpy().copy() for k, v in out.items()}


async def optimize_gate(model: torch.nn.Module, example: tuple[torch.Tensor, ...],
                        *, atol: float = 1e-3) -> None:
    ep = torch.export.export(model.eval(), args=example)
    ep = ep.run_decompositions(get_decomp_table())

    inputs = {"x": example[0].contiguous().numpy()}

    plain = await run_program(build_program(ep, optimize=False), inputs)
    tuned = await run_program(build_program(ep, optimize=True), inputs)

    with torch.no_grad():
        eager = model(*example)

    for name in plain:
        d_opt = float(np.max(np.abs(plain[name] - tuned[name])))
        d_ref = float(np.max(np.abs(eager.numpy() - tuned[name])))
        print(f"{name}: |unopt - opt| = {d_opt:.3e}   |eager - opt| = {d_ref:.3e}")
        assert d_opt < atol, (
            f"optimize() changed the semantics of output {name!r} "
            f"(max abs delta {d_opt:.3e}). See coreai-torch#49."
        )
        assert d_ref < atol, f"Core AI diverges from eager PyTorch on {name!r}: {d_ref:.3e}"


asyncio.run(optimize_gate(MyModel(), (torch.randn(1, 32, 8),)))
```

The `#49` reproducer's own numbers show what a hit looks like: `1.907e-06` unoptimized versus
`1.022e+01` optimized, on the same graph. A threshold of `1e-3` separates those by seven orders of
magnitude — you will not get a marginal call.

> ⚠️ **Use realistic inputs.** `#49`'s control table shows the bug **does not reproduce with unequal
> input lengths (17 × 23)** because the wrong operand cannot broadcast. A gate run on rectangular
> toy tensors would pass while the square production case is broken. Run the gate at your real
> shapes.

### 11.5 Structural checks that need no inference

Three cheap assertions that catch the §4.4 class of silent failure before you have run anything:

```python
ir = str(coreai_program)                       # AIProgram prints its MLIR module

# 1. The fast attention path survived decomposition.
assert "scaled_dot_product_attention" in ir

# 2. Externalized composites really were emitted.
assert "composite_decl" in ir

# 3. The IO contract landed in the IR.
assert 'coreai.name = "pixel_values"' in ir
```

Plus two command-line checks on the saved asset:

```bash
# Op histogram; two-file mode prints a Delta column and marks differences with '*'.
python tools/freqop/freqop.py before.aimodel after.aimodel

# Structural graph diff. Exit 0 = isomorphic, 1 = structural differences, 2 = input error.
python tools/graphdiff/graphdiff.py source.aimodel target.aimodel --output diff.html
```

> ✅ **VERIFIED** — `tools/freqop/README.md` and `tools/graphdiff/README.md`. `graphdiff` is
> **composite-aware by default**: it diffs `main` vs `main` and matches composite sub-graphs via
> paired `coreai.invoke` callees (e.g. `@sdpa_abc123` ↔ `@sdpa_def456`), diffing each and reporting
> unmatched ones. Both are plain scripts, not installed console entry points. `freqop --plot`
> requires matplotlib, which is not a declared dependency.

And for weights, the AOT compiler's inspector:

```bash
xcrun coreai-build inspect model.aimodel   # function signatures, inputs/outputs, states, weight ops/dtypes
```

> ✅ **VERIFIED** — observed CLI surface from `coreai-models#55`, `#27` and `coreai-torch#44`. Weight
> op names visible in the IR distinguish the two compression families: **`lut_to_dense`** (palettized)
> versus **`blockwise_shift_scale`** (linear blockwise int). That is how you confirm §5.4's sub-byte
> injection actually happened.
>
> ⚠️ **`inspect` succeeding is not evidence the model will compile** — §2.3.

### 11.6 The three-way compute-unit A/B

The last gate, and the one that catches delegate-specific bugs (the ANE fp16 issues in §4.4, the
GPU `floor` identity in §6.4):

```python
import coreai.runtime as rt

spec_cpu = rt.SpecializationOptions.cpu_only()
spec_gpu = rt.SpecializationOptions.from_preferred_compute_unit_kind(rt.ComputeUnitKind.gpu())
spec_ane = rt.SpecializationOptions.from_preferred_compute_unit_kind(
    rt.ComputeUnitKind.neural_engine()
)

model_gpu = await rt.AIModel.load(asset_path, specialization_options=spec_gpu)
model_ane = await rt.AIModel.load(asset_path, specialization_options=spec_ane)

nd_in = rt.NDArray(np.ascontiguousarray(x))
out_gpu = (await model_gpu.load_function("main")({"image": nd_in}))["logits"].numpy()
out_ane = (await model_ane.load_function("main")({"image": nd_in}))["logits"].numpy()
```

> ✅ **VERIFIED** — this exact API surface is confirmed by the reproducer in `coreai-torch#51`:
> `SpecializationOptions.cpu_only()`, `.from_preferred_compute_unit_kind(...)`,
> `ComputeUnitKind.gpu()` / `.neural_engine()`, `await AIModel.load(path, specialization_options=...)`
> (also accepted positionally), and `load_function("main")` returning an awaitable that takes a
> `dict[str, NDArray]`. **`SpecializationOptions` is documented macOS-only.**
>
> The finding that motivated it, **community-measured** by `zli96` on macOS 27 beta 3 with
> `coreai-torch` v0.4.1, comparing FP16 NPU against GPU on the *same asset*:
>
> | Test case | Max abs diff | Rel L2 diff |
> |---|---|---|
> | MobileNetV2 (Linear + ReLU/Identity classifier) | `0.002686` | `0.001025` |
> | MobileNetV3 Small (Linear + **Hardswish** classifier) | `0.199219` | `0.039235` |
>
> Author's own isolation and workaround: *"Transforming the 2D matrix into a 4D matrix
> (1 x 1 x m x n) avoids the issue on the NPU."* Status: `coreai-torch#51` **OPEN**, 0 comments, as
> of 2026-07-29. Attribute these numbers as community-measured, not Apple-published.

### 11.7 The four A/Bs, as a checklist

Every silent failure documented in this guide was found by one of these four comparisons. Run all
four in CI:

| # | Comparison | Catches |
|---|---|---|
| 1 | eager PyTorch vs Core AI | decomposition-table mistakes, lowering bugs, dtype narrowing |
| 2 | `optimize=True` vs `optimize=False` | `#49`-class optimizer miscompiles, cast-fold semantics loss |
| 3 | CPU vs GPU vs ANE, same asset | delegate-specific bugs, fp16 overflow, `floor`-as-identity |
| 4 | descriptor assertion (names + order) | renamed IO, reordered states, missing entrypoints |

For LLMs, add a fifth: a **token-exact greedy oracle** — generate N tokens greedily from both the
reference and the converted model and require byte-identical output. Nothing else catches a KV-cache
state mix-up.

---

## 12. Locations, module stacks, and the Debugger

There is a design decision inside `TorchConverter` that most conversion tools do not make: **it
carries your Python source locations and your PyTorch module hierarchy all the way into the
`.aimodel` asset.** Every tooling capability in the Core AI story downstream of conversion is
downstream of that decision. This section makes the causal chain explicit, because knowing it changes
how you configure the converter.

### 12.1 The switch: `TorchConverter.Mode`

> ✅ **VERIFIED** — `coreai_torch/converter.py`:
>
> ```python
> class TorchConverter:
>     class Mode(Enum):
>         """Controls the level of debug information embedded in the converted asset.
>
>         Attributes:
>             RELEASE: Lightweight mode that records only operation IDs without
>                 stack traces.
>             DEBUG: Includes full torch stack traces for comprehensive source
>                 mapping and debugging.
>         """
>         DEBUG = "debug"
>         RELEASE = "release"
>
>     def __init__(self, *, mode: "TorchConverter.Mode" = Mode.DEBUG) -> None:
> ```
>
> **`mode` is keyword-only and defaults to `Mode.DEBUG`.** Full torch stack traces are embedded
> unless you ask otherwise.
>
> ⚠️ **`docs/api/TorchConverter.md` documents the constructor as a bare `TorchConverter()` and does
> not mention `mode` at all.** It is a real, undocumented parameter. The class docstring also names
> the after-the-fact escape: *"Call `coreai_torch.debugging.debug_info.strip_debug_info` to remove
> debug metadata from an already-converted program."*

```python
from coreai_torch import TorchConverter

converter = TorchConverter()                                   # DEBUG: stack traces embedded
converter = TorchConverter(mode=TorchConverter.Mode.RELEASE)    # op IDs only, smaller asset
```

### 12.2 What gets carried

Two distinct kinds of metadata, both preserved:

**Source locations.** Each emitted Core AI op carries an MLIR `Location` derived from the torch
stack trace of the FX node that produced it. `coreai_torch/_debug_locations.py` is 1,388 lines of
exactly this. `strip_debug_info` is its inverse: it *"replaces every op location with an unknown-file
location plus a fresh sequential `coreai` op ID"* and is documented as *"useful for reducing asset
size when full debug traces are no longer needed."*

**Module hierarchy.** The converter records which `nn.Module` instance each op came from, with
instance disambiguation:

> ✅ **VERIFIED** — `_get_module_hierarchy(node, registry)` returns entries of the form
> `"<ClassName>$<per-type instance count>"` — `"Linear$1"`, `"Block$2"` — outermost-first. Repeated
> calls into the *same* submodule instance reuse the same count.
> `tests/test_get_module_hierarchy.py` asserts ≥2 distinct `Block$n` and ≥3 distinct `Linear$n` for a
> model whose `forward` calls `self.block(x)` twice — i.e. the counter identifies *instances*, not
> call sites.

Plus a parser for reading it back:

> ✅ **VERIFIED** — `parse_debug_infos(debug_infos_bytes: bytes) -> list[DebugInfoRecord]`, with
> `DebugInfoRecord.find_by_odix_id(id)` and `.find_by_torch_op_id(id)`. Two ID spaces — the compiled
> ("odix") op and the torch op — and an explicit mapping between them. That mapping is the thing.

### 12.3 The causal link to the Debugger

Now the payoff. The Core AI Debugger is a standalone macOS app distributed from
`developer.apple.com/core-ai-debugger/`. Its four panes:

> ✅ **VERIFIED** — WWDC26 session 325, lines 110–119:
>
> | Pane | What it shows |
> |---|---|
> | **Navigator** (left) | *"a structured list of operations in the model"*, **grouped by their PyTorch module** |
> | **Structure viewer** (top) | graph view — *"operation connectivity, execution order, and data dependencies"* |
> | **Source viewer** (bottom) | *"I'm always grounded in my model's original Python code **down to the specific line**"* |
> | **Inspector** (right) | per-op description and details on inputs and outputs |
>
> and, verbatim: *"These operations are **grouped by their PyTorch module**, which is especially
> powerful for larger models like SAM3… Selecting a PyTorch module in the navigator, like the
> **detector decoder**, will **highlight all of the corresponding nodes** in the structure viewer."*
> *"Together, these views allow you to move fluidly between graph structure, source code, and
> execution details, which dramatically reduces the cognitive overhead of debugging complex models."*

Line them up:

| Debugger capability | The converter metadata that makes it possible |
|---|---|
| Source viewer showing your Python line | MLIR `Location`s from torch stack traces (`_debug_locations.py`) |
| Navigator grouped by PyTorch module | `_get_module_hierarchy` → `"Block$2"` records |
| Clicking a module highlights its ops | the torch-op-ID ↔ compiled-op-ID mapping in `DebugInfoRecord` |
| Sync points pairing PyTorch ops to Core AI ops | the same mapping, consumed by `save_intermediates` |

The framework documentation states the link from the other end:

> ✅ **VERIFIED** — Apple's *"Run AI models in your app on Apple silicon"* article: *"The Core AI
> Debugger app supports visualization and numeric debugging, letting you **trace tensor values
> directly back to your Python source code**."*

**This is why `Mode.DEBUG` is the default.** Apple chose "debuggable by default, opt out for size"
rather than the reverse. If you convert with `Mode.RELEASE` and then open the asset in the Debugger,
the source viewer and the module navigator have nothing to show — and nothing tells you why.

### 12.4 The reference-comparison workflow this enables

The metadata is also what makes cross-framework numeric comparison automatic rather than manual.

> ✅ **VERIFIED** — session 325, lines 134–137: *"I'll return to my notebook and use the **NEW save
> intermediates API**. This API **executes a PyTorch model and captures intermediate tensor values at
> each operation**. I want to compare my quantized results with the baseline… so I'll pass in the int4
> model alongside the original SAM3."*
>
> Real signature, `coreai_torch/debugging/torch_utils.py:905–913`:
>
> ```python
> def save_intermediates(
>     program: ExportedProgram,
>     inputs: Union[tuple[Any, ...], list[Any]],
>     output_dir: Union[str, Path],
>     node_filter: Callable[[torch.fx.Node, Any], bool] = _default_node_filter,
>     coreai_program: AIProgram | None = None,
>     enable_autocast: bool = False,
>     model_name: str = "main",
> ) -> str:
> ```
>
> The parameter that closes the loop, verbatim from the docstring: `coreai_program` — *"Optional
> `AIProgram` to extract source info from. If provided, **variable information from source locations
> will be added to the metadata**."* That is the converter's location metadata being read back out
> and attached to a tensor dump.
>
> Other semantics: `node_filter` takes `(node, result)` and returns whether to dump;
> `enable_autocast` — *"Set to True to handle mixed precision models and avoid dtype mismatch
> errors"*; `model_name` creates `{model_name}.aimodelintermediates` under `output_dir`; the return
> value is the path to `metadata.json`.

```python
from pathlib import Path

from coreai_torch.debugging.torch_utils import load_intermediates, save_intermediates

metadata_path = save_intermediates(
    program=exported_program,
    inputs=example_input,
    output_dir=Path("./debug_output"),
    coreai_program=coreai_program,       # <- attaches source-location info
)

trace = load_intermediates(Path("./debug_output/main.aimodelintermediates"))
print(f"Inputs: {list(trace.inputs.keys())}")
print(f"Outputs: {list(trace.outputs.keys())}")
print(f"Intermediates: {len(trace.intermediates)} operations")
for node_name, tensor in trace.intermediates.items():
    print(f"{node_name}: shape {tensor.shape}, mean {tensor.mean():.3f}")
```

> ✅ **VERIFIED** — `docs/api/debugging.md:250–283`. On-disk layout is numpy files plus a
> `metadata.json` with keys `"inputs"`, `"outputs"`, `"intermediates"` and, when `coreai_program` was
> supplied, `"mappings"`.
>
> ⚠️ **`load_intermediates` validates the directory suffix.** A path not ending in
> `.aimodelintermediates` raises *"Expected a `.aimodelintermediates` directory, but got: …"*. Also:
> the docstring examples in the source still call the function **`dump_intermediates`** — a stale
> name. The exported symbol is `save_intermediates`.

The Debugger then loads that file as the right-hand side of a comparison session:

> ✅ **VERIFIED** — session 325, lines 139–152. *"The navigator is now populated with **operation
> pairs** which combine an operation from the specialized model and PyTorch model. These pairs are
> called **sync points**, places where the specialized model's output is **expected to match** the
> original PyTorch result. **The debugger automatically identifies these points throughout the
> model.**"* Each pair carries a similarity metric (PSNR by default), colour-coded green / yellow /
> red, sortable by similarity; clicking one updates the source viewer to show *"the operation's
> PyTorch module hierarchy."*
>
> "Automatically identifies" is the converter's ID mapping doing the work. Without embedded locations
> there are no sync points.

And the diagnosis it produced, which is the §10.3 asymmetric compression recipe:

> ✅ **VERIFIED** — session 325, lines 156–162: *"I'm noticing that **the vast majority of low-PSNR
> sync points are actually coming from the detector decoder**… Since we previously identified that
> the detector block only accounts for **4% of model parameters, we're not getting much benefit from
> compressing it anyway**. So, I'll return to the Jupyter notebook, and try changing the quantization
> scheme to **ignore the detector**."* … *"Core AI Debugger turned hours of manual tensor comparison
> into a visual diagnosis."*

### 12.5 ⚠️ Preview-only environment variables

There is a gate on all of this in the current preview, and it is easy to miss:

> ✅ **VERIFIED** — `docs/api/debugging.md:5–13`, verbatim: *"During the current preview, set the
> following environment variables to ensure **operation-level debug metadata is preserved** and
> available to these tools."*
>
> ```bash
> export USE_LOCAL_COREAI=1
> export ENABLE_DEBUG_INFO=1
> ```
>
> A third, read by `_get_verify_debuginfo_locations_enabled()`, accepts `true|1|yes|on` and is off by
> default *"for performance reasons"*:
>
> ```bash
> export VERIFY_DEBUGINFO_LOCATIONS=1
> ```

> ⚠️ **SILENT FAILURE.** Without `ENABLE_DEBUG_INFO=1`, module-stack and source-location metadata
> *may be missing* from the asset — and the only symptom is that the Debugger's navigator and source
> viewer are empty. Conversion succeeds. Inference is identical. You lose the tooling and get no
> diagnostic.
>
> 🔴 **GAP:** `ENABLE_DEBUG_INFO` and `USE_LOCAL_COREAI` are **never read anywhere in
> `coreai-torch`'s own Python** — they must be consumed by `coreai-core`, whose source is not
> available. Their exact semantics, and whether `ENABLE_DEBUG_INFO=0` actively strips or merely
> declines to add, are unverified. `USE_LOCAL_COREAI` is set/unset by `tests/conftest.py` to select
> the bundled interpreter runtime versus the OS runtime, which suggests it is about *which* runtime
> loads rather than about metadata — but the debugging docs list both together.
> **What would resolve it:** `coreai-core` source or documentation for these variables.
> **Safe default meanwhile:** export both before any conversion you intend to debug, and verify by
> opening the asset in the Debugger and checking the source viewer is populated — that is the only
> observable signal available today.

### 12.6 The size/debuggability trade, made explicit

| Configuration | Asset carries | Use when |
|---|---|---|
| `TorchConverter()` (DEBUG, the default) + `ENABLE_DEBUG_INFO=1` | full torch stack traces, module stacks, locations | development, any conversion you might have to diagnose |
| `TorchConverter(mode=TorchConverter.Mode.RELEASE)` | op IDs only | shipping, once the asset is proven |
| Post-hoc `strip_debug_info(program)` then `save_asset` | nothing | shipping an *already converted* asset; also the §2.3 recovery |

The pragmatic recipe: **convert twice.** Keep the DEBUG asset next to the RELEASE one, ship the
RELEASE one, and diagnose against the DEBUG one when a field report arrives. They are the same
computation — verify that with §11.4's harness comparing the two assets, which costs one extra run
and rules out the (unlikely, unverified) possibility that mode affects codegen.

> 🔴 **GAP — whether `Mode.RELEASE` affects the emitted computation at all is unverified.** The
> docstring describes it purely as a debug-information level, and nothing in the source suggests
> otherwise, but no test in the corpus asserts numeric equality between a DEBUG-converted and a
> RELEASE-converted asset. **What would resolve it:** such a test, or a statement in the docs.
> **Safe default meanwhile:** run §11.4's comparison across the two modes once per model. If they
> differ, that is a bug report.

---

## 13. Failure taxonomy and quick reference

### 13.1 The loud failures, with their messages

Every one of these raises at conversion time with an actionable message. They are the easy half.

| Message (abbreviated) | Cause | Fix |
|---|---|---|
| *"contains non-decomposed ops: … Please call `run_decompositions()`"* | skipped §4 entirely | `ep.run_decompositions(get_decomp_table())` |
| *"contains unsupported ATen ops: … Use `register_torch_lowering()`"* | an op with no lowering; also what a full decomp table produces for `instance_norm` | use `get_decomp_table()`; or write a lowering (Part 10) |
| *"A program with entrypoint_name=… is already staged"* | duplicate `entrypoint_name` | give each program a unique name |
| *"No programs to convert. Call `add_exported_program()` … first."* | `to_coreai()` on an empty or over-filtered converter | stage something; check the `entrypoints=` filter |
| *"Graph has N live inputs (…), but `input_names` has M entries"* | name-count mismatch; often a state you forgot is a state | move it to `state_names`, or de-mutate it |
| *"State input/output count mismatch"* | unsupported graph signature layout | simplify the mutation pattern |
| *"FX placeholder order violates the 'mutable buffers first…' invariant"* | PyTorch version drift | pass `state_names` explicitly |
| *"Your model failed to export: … Ensure the model is exportable via `torch.export`"* | `add_pytorch_module`'s eager export failed | fix exportability, or use `add_exported_program` with your own export |
| *"Unsupported ATen op: {target}"* at lowering time | resolver miss | `register_torch_lowering` (Part 10) |
| *"Encountered dynamic stride at maxpool2d"* / *"Transposed conv3d is not yet supported"* | unsupported dynamic/op combination | make the stride static; restructure |
| *"Symbolic SymInt slice argument is not supported"* | a `SymInt` used directly as a slice bound | use `aten.sym_size.int` results as `fx.Node` references |
| *"failed to export submodule '…': Constraints violated"* | `coreai-torch#1`, static query + dynamic KV | drop `SDPA` from `externalize_modules` |
| *"Kernel `coreai.metal4_kernel` invoked with invalid parameters"* at `load_function` | bad MSL body — converts fine, fails at load | Part 10 |

### 13.2 The silent failures — the actual subject of this guide

| # | What you do | What happens | Detect with |
|---|---|---|---|
| 1 | export without `.eval()` | dropout active, batch stats wrong at inference | §11.1 eager-vs-Core-AI |
| 2 | `run_decompositions(default_decompositions())` | SDPA/silu/pad decompose → **fast paths silently lost** | §11.5 `"scaled_dot_product_attention" in ir` |
| 3 | rely on a non-preserved op (`softplus`, `mish`, `logsumexp`) at fp16 | overflow → 0 or NaN, earlier still on ANE | §11.6 CPU/GPU/ANE A/B at real activation ranges |
| 4 | call `optimize()` on an expanded-square-distance graph | broadcast axis move deleted → **17 dB PSNR** | §11.4 optimize on/off gate |
| 5 | omit `input_names` / `output_names` | outputs named after internal ops; renamed by a PyTorch upgrade | §11.3 descriptor assertion |
| 6 | omit `state_names` with two same-shape buffers | states may silently reorder | §11.3 + asymmetric state contents |
| 7 | mutate a `forward` argument in place | it silently becomes a **state**, changing the calling convention | count mismatch (loud) or §11.3 |
| 8 | skip `optimize()` on a stateful model | mutation outputs never become handle tokens; state does not work | §11.3 `desc.state_names` |
| 9 | typo an `ExternalizeSpec` target class | `UserWarning` only; composite never emitted | §11.5 `"composite_decl" in ir` |
| 10 | pass a bare class instead of an `ExternalizeSpec` | "simple externalization" — no metadata, **no benefit** | §11.5 + `freqop` |
| 11 | let an int64 value exceed int32 | silently narrowed and wrong | §11.1 with realistic magnitudes |
| 12 | use `coreai-models.PreparedModel` with segmenter names other than the trio | helper classifies `.dynamic` → requests **GPU, not ANE** | assert `model.function_names`; inspect chosen options |
| 13 | ship a three-function asset and expect the 76% | Apple's engine re-runs `image_encode` every call | measure; build your own cache |
| 14 | convert with `Mode.RELEASE` or without `ENABLE_DEBUG_INFO` | Debugger source viewer and module navigator are empty | open the asset in the Debugger |
| 15 | pass a non-contiguous PyTorch tensor through the `coreai-models` Python wrapping path | that bridge reads the raw backing memory as contiguous | call `.contiguous()` at this bridge boundary; do not generalize this to Swift `NDArray`, which supports explicit strides[^stride-scope] |
| 16 | read an `NDArray` after the `async with` exits | backing buffers no longer guaranteed valid | `.numpy()` inside the block |
| 17 | build state with `NDArray.from_descriptor` | buffer sized but not zeroed on Linux → garbage first call | allocate `np.zeros` |
| 18 | convert with `coreai-torch` 0.4.0 | asset rejected on device from OS 27 beta 2 | reconvert on 0.4.1+, or `strip_debug_info` |

### 13.3 The complete pipeline, in one block

```python
"""End-to-end conversion with every contract made explicit.

Requires: pip install coreai-torch   (coreai-torch 0.4.1 / coreai-core 1.0.0b2)
Environment, for a debuggable asset:
    export USE_LOCAL_COREAI=1
    export ENABLE_DEBUG_INFO=1
"""

import asyncio
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
from coreai.runtime import NDArray
from coreai_torch import TorchConverter, get_decomp_table

INPUT_NAMES = ["input_ids"]
OUTPUT_NAMES = ["logits"]
STATE_NAMES = ["k_cache", "v_cache"]
ENTRYPOINT = "main"
ASSET = Path("MyModel.aimodel")


class MyModel(nn.Module):
    def __init__(self, vocab: int = 32000, dim: int = 64, ctx: int = 128):
        super().__init__()
        self.embed = nn.Embedding(vocab, dim)
        self.proj = nn.Linear(dim, vocab, bias=False)
        # Mutable buffers -> Core AI states. Order here IS state order.
        self.register_buffer("k_cache", torch.zeros(1, ctx, dim))
        self.register_buffer("v_cache", torch.zeros(1, ctx, dim))

    def forward(self, input_ids: torch.Tensor) -> torch.Tensor:
        h = self.embed(input_ids)
        self.k_cache.copy_(h)                       # in-place -> state
        self.v_cache.copy_(h)                       # in-place -> state
        attn = torch.matmul(h, self.k_cache.transpose(-2, -1))
        ctx_vec = torch.matmul(torch.softmax(attn, dim=-1), self.v_cache)
        return self.proj(ctx_vec)


def convert(model: nn.Module, example: tuple[torch.Tensor, ...], *, optimize: bool = True):
    model.eval()                                     # 1. never export in training mode

    seq = torch.export.Dim("seq", min=1, max=128)
    ep = torch.export.export(                        # 2. export, with dims you chose
        model, args=example, dynamic_shapes={"input_ids": {1: seq}}
    )
    ep = ep.run_decompositions(get_decomp_table())   # 3. Apple's table, never PyTorch's default

    program = (                                      # 4. stage with explicit names
        TorchConverter()                             #    (DEBUG mode: keeps source locations)
        .add_exported_program(
            ep,
            input_names=INPUT_NAMES,
            output_names=OUTPUT_NAMES,
            state_names=STATE_NAMES,
            entrypoint_name=ENTRYPOINT,
        )
        .to_coreai()                                 # 5. pure conversion, no passes
    )
    if optimize:
        program.optimize()                           # 6. passes. Mandatory for stateful models.

    ir = str(program)                                # 7. structural assertions before saving
    for name in INPUT_NAMES + OUTPUT_NAMES:
        assert f'coreai.name = "{name}"' in ir, f"missing IO name {name!r}"

    return program


async def verify(program, example: tuple[torch.Tensor, ...], model: nn.Module) -> None:
    asset = program.save_asset(ASSET)                # 8. .aimodel is a DIRECTORY
    async with asset.executable() as ai_model:
        assert ENTRYPOINT in ai_model.function_names, ai_model.function_names
        fn = ai_model.load_function(ENTRYPOINT)

        desc = fn.desc                               # 9. assert the contract
        assert list(desc.input_names) == INPUT_NAMES, desc.input_names
        assert list(desc.output_names) == OUTPUT_NAMES, desc.output_names
        assert list(desc.state_names) == STATE_NAMES, desc.state_names

        state = {}                                   # 10. zero-fill state yourself
        for name in desc.state_names:
            d = desc.state_descriptor(name=name)
            shape = tuple(s if s is not None else 1 for s in d.shape)
            state[name] = NDArray(np.zeros(shape, dtype=np.dtype(d.dtype)))

        inputs = {"input_ids": NDArray(np.ascontiguousarray(example[0].numpy()))}
        outputs = await fn(inputs=inputs, state=state)
        got = outputs["logits"].numpy().copy()       # 11. materialize INSIDE the block

    with torch.no_grad():                            # 12. compare against eager
        expected = model(*example).numpy()

    delta = float(np.max(np.abs(expected - got)))
    print(f"max |eager - coreai| = {delta:.3e}")
    assert delta < 1e-2, f"numeric divergence: {delta:.3e}"


if __name__ == "__main__":
    m = MyModel()
    ex = (torch.randint(0, 32000, (1, 128)),)
    asyncio.run(verify(convert(m, ex), ex, MyModel().eval()))
```

> ⚠️ Two notes on that listing. The model is a **toy** whose only job is to exercise every contract
> — buffers, dynamic dims, explicit names, state binding — not to be a good attention
> implementation. And it deliberately does **not** run the §11.4 optimize gate inline; run that
> separately, at your real shapes, because §6.4's bug is shape-sensitive.

### 13.4 API quick reference

```python
# ---- top-level exports (the complete public surface) ----
from coreai_torch import (
    TorchConverter, ExternalizeSpec, TorchMetalKernel, MetalParameter,
    get_decomp_table, generate_composite_decl, __version__,
)

# ---- staging (naming params are KEYWORD-ONLY) ----
converter.add_exported_program(ep, *, input_names=None, output_names=None,
                               state_names=None, entrypoint_name="main") -> Self
converter.add_pytorch_module(model, *, export_fn, externalize_modules=None,
                             input_names=None, output_names=None,
                             state_names=None, entrypoint_name="main") -> Self

# ---- conversion ----
converter.to_coreai(*, entrypoints=None) -> AIProgram
converter.clear(*, entrypoints=None) -> None          # custom lowerings always preserved
TorchConverter(mode=TorchConverter.Mode.DEBUG)        # or .RELEASE

# ---- program (from coreai.authoring) ----
program.optimize()                                    # synchronous, in place
program.save_asset(path)                              # -> AIModelAsset; path must end .aimodel
program.save_asset(path, metadata)                    # optional second positional
str(program)                                          # prints MLIR

# ---- runtime (from coreai.runtime / coreai.authoring) ----
asset = AIModelAsset.load(path)                       # header only; no compilation
async with asset.executable() as model:               # specialization happens HERE
    model.function_names
    fn = model.load_function("main")                  # KeyError if missing (Swift returns nil)
    fn.desc.input_names / .output_names / .state_names
    out = await fn({"x": NDArray(arr)})               # stateless
    out = await fn(inputs={...}, state={...})         # stateful
    arr = out["y"].numpy()                            # materialize INSIDE the block

model = await AIModel.load(path, specialization_options=opts)   # one-shot alternative
SpecializationOptions.cpu_only()                                     # macOS only
SpecializationOptions.from_preferred_compute_unit_kind(ComputeUnitKind.gpu())
SpecializationOptions.from_preferred_compute_unit_kind(ComputeUnitKind.neural_engine())
NDArray(data, backing=StorageKind.BYTES)              # default; also IOSurface / Metal backings
```

### 13.5 A pre-flight checklist

Before you consider a conversion done:

- [ ] `.eval()` called on the module
- [ ] `run_decompositions(get_decomp_table())` — Apple's table, not PyTorch's default
- [ ] every dimension that varies at runtime declared via `dynamic_shapes=`
- [ ] `input_names`, `output_names` and (if stateful) `state_names` passed explicitly
- [ ] `entrypoint_name` chosen deliberately, matching the consumer's expectations (§10.4)
- [ ] `optimize()` called — and A/B'd against not calling it, at real shapes (§11.4)
- [ ] IR structural assertions: composites present, IO names present (§11.5)
- [ ] descriptor assertion committed as a test (§11.3)
- [ ] eager-vs-Core-AI numerics inside Apple's PSNR bands (§11.2)
- [ ] CPU / GPU / ANE A/B on the same asset (§11.6)
- [ ] converted with `coreai-torch` ≥ 0.4.1 (§2.3)
- [ ] `USE_LOCAL_COREAI=1` and `ENABLE_DEBUG_INFO=1` set if you want the Debugger to work (§12.5)

---

## 14. Sources and evidence ledger

### 14.1 What this guide is built on

| Class | Source | Weight |
|---|---|---|
| Shipping source | `apple/coreai-torch` @ `main`, HEAD `4529671`, package version **0.4.1** — `converter.py` (1,082 lines), `_decomp.py`, `_validate.py`, `_utils.py`, `_type_mapping.py`, `externalize.py`, `_debug_locations.py`, `debugging/*`, `tests/*`, `docs/*` | Strongest |
| Shipping source | `apple/coreai-models` — `python/src/coreai_models/segmentation/pipeline.py`, `swift/Sources/CoreAIShared/Runtime/ModelStructure.swift`, `CoreAIImageSegmenter/ImageSegmentationEngine.swift`, `CoreAILanguageModels/CoreAISequentialEngine.swift` | Strongest |
| **Apple's agent skills** | `apple/coreai-models/skills/skills/{working-with-coreai,model-authoring,model-compression-exploration}/` — Apple's own empirical rules and acceptance thresholds | Very strong |
| Package docs | `docs/api/TorchConverter.md`, `docs/api/supported-aten-ops.md`, `docs/api/composite-ops.md`, `docs/api/debugging.md`, `docs/getting-started/quickstart.ipynb`, `docs/guides/*.ipynb`, `docs/coreai-core/tutorials/*.ipynb` | Strong |
| Apple-staff answers | `coreai-torch` issues #33, #37, #44 (maintainers @cymbalrush, @gokulkrishna98, @DawerG) | Strong |
| Release notes | `coreai-torch` v0.4.1 + bundled `coreai-core` 1.0.0b2 changelog | Strong |
| WWDC26 | Session 325, *"Dive into Core AI model authoring and optimization"* (Sachin, Nicole) | Medium — spoken |
| Community | `coreai-torch` issues #1, #2, #5, #6, #9, #10, #11, #21, #49, #51; PRs #22, #45 — reproducers and measurements by external developers | **Community-measured; always labelled as such** |

### 14.2 Numbers used in this guide, with attribution

| Number | Attribution | Conditions |
|---|---|---|
| 76% faster second inference (SAM3 3-way split) | **Apple-published**, WWDC26 session 325:256 | Demo machine unspecified; no OS build, no methodology; requires caller-side caching Apple's own engine does not do (§10.5) |
| 3 GB → ~430 MB (SAM3 fp32 → int4) | **Apple-published**, session 325:96–102 | Same caveats; came with a visible quality regression |
| SAM3 = 848M params, encoders 96% / detector 4% | **Apple-published**, `models/sam3/README.md` + session 325:60, 325:158 | Transcript rounds 848M to "850-million" |
| PSNR bands >70 / >50 / ~40 dB | **Apple-published**, `working-with-coreai/SKILL.md` | float32 / fp16-on-device / 4-bit palettized |
| 17 dB PSNR from `optimize()`; 78–85 dB without | **Community-measured**, `coreai-torch#49` | GeoTransformer; macOS 27.0 `26A5378j`/`26A5388g`, coreai-torch 0.4.1, torch 2.11.0, Python 3.12.13 |
| `max\|d\|` 1.907e-06 → 1.022e+01[^optimize-regression] | **Community-measured**, `coreai-torch#49` | 32×32 square case; unequal 17×23 does **not** reproduce |
| MobileNetV3 ANE-vs-GPU max abs diff 0.199 | **Community-measured**, `coreai-torch#51` (`zli96`) | macOS 27 beta 3, coreai-torch 0.4.1, fp16 |
| fp16 overflow thresholds (softplus 10.4, logsumexp 7.63…) | **Community-measured**, `coreai-torch#21` | ANE-specific earlier thresholds attributed to a 2^15-bounded internal representation |
| RF-DETR output cosine ~0.65 with no error | **Community-measured**, `coreai-torch#11` (`john-rocky`) | macOS 27.0 `26A5353q`, M4 Max, coreai-torch 0.4.0 |

### 14.3 Where the brief and the sources disagreed

Three places, resolved in favour of the sources and reported here so the next reader can re-check.

**1. "`get_decomp_table()` preserves exactly three ops."** The README says three
(`instance_norm`, `pixel_shuffle`, `scaled_dot_product_attention`). `_decomp.py`'s `_COMPOSITE_OPS`
has **twelve** entries, which its own docstring splits into four composites and eight direct
lowerings (§4.2). An issue filed in June 2026 described the list as six, and was correct at the
time — the pad family was added by commit `45a231f`. **The list is version-dependent; read
`_decomp.py`.**

**2. "The decomposition step is silent if skipped."** It is not. Skipping `run_decompositions`
entirely raises a `ValueError` naming the offending ops and the exact fix — even a bare `nn.Linear`
trips it. **The silent failure is one step subtler:** using `torch.export.default_decompositions()`
instead of Apple's table. `instance_norm` then errors *loudly* (its decomposition yields an
unsupported op), while `scaled_dot_product_attention` decomposes into six perfectly supported
primitives, so conversion succeeds and the fast attention path is silently gone (§4.4). That
distinction is the difference between a five-minute fix and an unexplained performance regression.

**3. `ModelStructure.swift` line numbers.** The compute-unit mapping cited here is at **`:57–80`**,
not `:71–80`; detection is at `:190–218`, the two-phase load at `:145–165`, `GraphNames` at `:12–20`.
The substance is unchanged and is quoted verbatim in §10.4.

### 14.4 Open gaps declared in this guide

| § | Gap | What would resolve it |
|---|---|---|
| 2.4 | `coreai-torch` states no minimum OS for the artifacts it produces | An explicit statement in `coreai-core` docs mapping converter version → minimum OS |
| 4.5 | No documented list of ops it is safe to *additionally* preserve | A published ATen-op → Core AI composite mapping |
| 6.3 | Full `CorePasses` catalog and `optimize()`'s signature | `dir(CorePasses)` and `help(AIProgram.optimize)` on an installed `coreai-core 1.0.0b2` |
| 7.4 | No documented character set or length limit for IO names | A validation rule or documented constraint |
| 11.2 | Apple's exact PSNR formula in `quality_metrics.py` | Reading that script |
| 12.5 | Semantics of `ENABLE_DEBUG_INFO` / `USE_LOCAL_COREAI` — never read by `coreai-torch` itself | `coreai-core` source or docs |
| 12.6 | Whether `Mode.RELEASE` affects the emitted computation | A numeric-equality test across modes, or a doc statement |

Two more, inherited from the corpus and worth carrying:

- **`.aimodel` internal layout** beyond *"program bytecode plus a `metadata.json`"* is unverified.
  `_save_bytecode` writes `main.AICode.bc` in a test dump path, which suggests `*.AICode.bc`, but no
  documented layout exists. Do not write code that depends on the internal file names.
- **Image inputs.** There is **no image-specific API in `coreai-torch`** — no `ImageType`, no
  colour-space handling of the kind `coremltools` has. Image models are plain `(N, C, H, W)` float
  tensors (the MobileNetV2 example). `coreai-core 1.0.0b2` did add *"image type support to
  `InferenceValue.Kind`"* on the **runtime** side, so a runtime image path exists; whether the
  converter can declare one is unverified. **Safe default:** convert with a plain float tensor input
  and do your own preprocessing, exactly as Apple's `ImagePreprocessor` does in `CoreAIShared`.

### 14.5 Related guides

- **Part 7 — Core AI: the Swift runtime.** The other side of every contract in §7, §9 and §10:
  `AIModel`, `InferenceFunction.run`, `MutableViews`, state binding, and the caller-side cache §10.5
  says you must write yourself.
- **Part 9 — compression and numeric formats.** `coreai-opt`: `Quantizer`, `KMeansPalettizer`,
  presets, `cast_to_16_bit_precision`, the `ExecutionMode.GRAPH`/`EAGER` split, and the
  ANE-rank-5-vs-per-channel-scale trap behind SAM3's asymmetric recipe.
- **Part 10 — hardware authoring, debugging, LLM deployment.** `register_torch_lowering`,
  `TorchMetalKernel`, BC1S re-authoring, the Neural Engine rule set, the Debugger in depth, and the
  many-static-specializations technique that §8.6 points at.
- **Part 15 — shipping and operating.** `xcrun coreai-build`, `.aimodelc`, bundle layout and
  `metadata.json` schema 0.2.

---

*Guide last verified 2026-07-27 against `coreai-torch` 0.4.1 (`main`, HEAD `4529671`),
`coreai-core` 1.0.0b2, `coreai-models` 0.2.0-pre, macOS 27.0 beta builds `26A5378j` / `26A5388g`.
Issue and PR states were re-checked 2026-07-29. `coreai-torch#49` — the `optimize()`
miscompile — was still **unresolved with zero comments**; re-check it before you ship.*

[^sample-routing-policy]: The name classifier and preferences are implemented by the optional
    `apple/coreai-models` package in its pinned
    [`ModelStructure.swift`](https://github.com/apple/coreai-models/blob/5ed9981303b38d5a44aa6b45509bc4f6945029f5/swift/Sources/CoreAIShared/Runtime/ModelStructure.swift#L12-L218).
    Core AI itself documents `.default` as choosing the CPU/GPU/Neural Engine combination that minimizes
    latency: [Managing model specialization and caching](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/docs/Managing%20model%20specialization%20and%20caching.md).

[^stride-scope]: Apple’s `coreai-models` authoring note gives `.contiguous()` as the fix for its
    PyTorch-to-`NDArray` wrapping path, while the Core AI API exposes explicit `strides` and
    specialization-selected preferred layouts:
    [`common_issues.md`](https://github.com/apple/coreai-models/blob/5ed9981303b38d5a44aa6b45509bc4f6945029f5/skills/skills/model-authoring/references/common_issues.md#L95-L98) and
    [Apple Developer — `NDArray`](https://developer.apple.com/documentation/coreai/ndarray).

[^optimize-regression]: The values and square-versus-rectangular reproducer come from
    [`apple/coreai-torch` issue #49](https://github.com/apple/coreai-torch/issues/49).
