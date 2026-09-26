# Bridges into Core AI: `mlx2coreai`, `swift-lm`, and the community zoo

**Part 14 · Bridges between stacks · Reference 01**

**Version floor: macOS 27 / iOS 27 for anything that *executes*, and a set of Python wheel pins
that do not agree with each other.** `mlx2coreai` 0.1.1 pins **`coreai-core==1.0.0b1`** exactly;
`1amageek/swift-lm` 0.11.0-alpha.1 pins **`coreai-core==1.0.0b2`, `coreai-torch==0.4.1`,
`coreai-opt==0.2.1`, `coreai-models` at git tag `0.2.0`, `torch==2.9.0`**; and
`john-rocky/coreai-model-zoo`'s `CONTRIBUTING.md` requires **`coreai-core ≥ 1.0.0b2`** because
*"bundles exported with earlier wheels are rejected by the Xcode 27 beta 3+ SDK loader"*
(`Failed to convert to versioned IR`, tracked as **FB23666783**). Read that sentence twice: the
main subject of this guide pins the exact wheel that the community's own acceptance bar rejects.
§2.3 covers what to do about it. Both Swift packages here declare **`platforms: [.macOS("27.0"),
.iOS("27.0")]`** and Swift tools **6.4** — Xcode 27 beta or later. Python floor is **3.11** on both
bridges.

---

## ⚠️ Read this before you trust a signature in this guide

Everything below was read from **local clones of three third-party repositories** plus the Apple
repos they target, in this session. That is a weaker evidence class than most of this series, and
the weakness is specific rather than general:

**None of it was executed.** `coreai-core` is not installed in the environment these notes were
taken in, and there is no macOS 27 SDK on the machine to compile the Swift runners against. Every
signature, flag and error string here was *read from source*, and the source is honest about
being a beta-era moving target. Where a claim rests on reading a call site rather than a
declaration — for example the exact keyword arguments of `coreai.GraphOp(...)`, which appear only
as calls in `mlx2coreai` and never as a definition anywhere in our corpus — it is marked.

**And the central caveat of the whole guide, stated once here and again in §6:** `mlx2coreai`'s own
op-coverage report opens with the line

> *"Coverage type: CoreAI asset generation. This does not imply runtime numerical parity."*

✅ **VERIFIED** — `docs/op_coverage.md:3`, quoted verbatim from the repo. **Nothing in our corpus
verifies a converted MLX model end to end on a device.** The 156-op coverage table tells you what
will *convert*. It does not tell you what will be *correct*. §6 gives you a parity-testing recipe
and tells you to run it before you trust anything this guide describes.

---

## What this covers

This is the guide for the person who already has a model working in one stack and wants it in
another. Not "how do I export a model" — that is
[Part 10 guide 03](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md).
This is "I have an MLX model / a PyTorch checkpoint / a working bundle in some other shape, and I
want a `.aimodel`, and I want to know which of the community's bridges is worth my afternoon."

Three bridges, in descending order of how much of this guide they occupy:

- **§2–§8 — `lucasnewman/mlx2coreai`**, the main subject. The only tool in existence that goes
  **MLX → Core AI** without passing through PyTorch. It captures an MLX graph with MLX's export
  callback tracer, lowers what it can to **Core AI MLIR**, and writes either a bare `.aimodel` or a
  full `coreai-models`-style LLM bundle. Two facts are worth drawing out of that sentence and both
  get their own section: **Core AI's IR is MLIR-based** (§5.5), and **the `coreai-models` bundle
  layout is a de-facto interchange format that third parties target** (§4).
- **§9–§10 — `1amageek/swift-lm`**, a third-party Swift package that ships a **Core AI vision
  language model adapter**. This is one of very few *real, third-party* Core AI integrations you
  can read, and it exercises `CoreAI` (the OS framework), `CoreAILanguageModels` (the SPM package),
  `coreai-torch`, `coreai-opt` and `coreai-build`. It also carries a documented, reproducible
  rejection of `SpecializationOptions.expectFrequentReshapes` that **contradicts Apple's own code**
  — §10 puts all four sources on the table.
- **§11 — `john-rocky/coreai-model-zoo`**, a single-author community catalogue of ~70 Core AI
  repos, 238 bundles and 52 recipes, plus a *porting playbook* that is the best written-down
  process for this work anywhere. Attributed throughout as community material with self-declared
  uncontrolled benchmarks.

§12 closes with the decision table, including the case where the honest answer is **"re-author from
the checkpoint instead of converting."**

## What this does *not* cover

- **The PyTorch → Core AI path itself.** `coreai_torch.TorchConverter`, `get_decomp_table()`,
  `state_names`, `remove_functionalization` and the whole export pipeline are
  [Part 8](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/README.md) and
  [Part 10 guide 03](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md).
  This guide references them as the *destination* of a bridge, not the subject.
- **Running the resulting bundle.** `AIModel`, `InferenceFunction`, `NDArray`, `MutableViews`,
  states, pipelined decode — [Part 7 guides 01 and 03](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/README.md).
  §3.4's signature discussion cross-links there rather than repeating it.
- **Specialization and AOT.** `SpecializationOptions`, `AIModelCache`, `coreai-build compile`,
  and the `expectFrequentReshapes` flag in its own right —
  [Part 7 guide 02](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md).
  §10 here covers only the third-party *disagreement* about that flag.
- **MLX itself.** `mx.export_function`, the primitive `state()` tuples, mlx-lm's cache protocol —
  [Part 12](../../part-12-mlx-python/README.md). This guide assumes you can already produce a working MLX
  model.
- **Compression.** Neither bridge in this guide quantizes anything. `mlx2coreai` has **no
  palettization, no int4/int8 packing, and no `coreai-opt` integration at all** (§2.4).
  Compression is [Part 9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md).

## What you need

- **An Apple silicon Mac on macOS 27** and **Xcode 27 beta or later**. The zoo's `PORTING.md` puts
  it plainly: *"the runtime is OS-bound; betas count."* You can *convert* on an older machine —
  `mlx2coreai`'s test suite runs without a Core AI runtime — but you cannot *verify*, and §6 is
  going to tell you that an unverified conversion is worthless.
- **Python 3.11+.** Both bridges declare `requires-python = ">=3.11"`.
- **Two virtualenvs, not one.** From the zoo's setup section: keep a separate env if the model you
  are porting needs a newer `transformers` than the export stack tolerates — *"Don't
  cross-contaminate."* And: *"GPU work on the beta driver is happiest **serialized** — run one
  export/verify at a time."* (Community-sourced, `PORTING.md:43-61`.)
- **A reference implementation you can run.** Every gate in this guide compares against something.
  If you cannot run the original model and capture its outputs, stop here and go read §6 first.

---

## Contents

1. [Three bridges, one destination](#1-three-bridges-one-destination)
2. [`mlx2coreai`: what it is and what it pins](#2-mlx2coreai-what-it-is-and-what-it-pins)
3. [The stateful LLM path](#3-the-stateful-llm-path)
4. [The bundle layout is the interchange format](#4-the-bundle-layout-is-the-interchange-format)
5. [The generic path, and the pipeline by module name](#5-the-generic-path-and-the-pipeline-by-module-name)
6. [⚠️ Asset-generation coverage is not numerical parity](#6-️-asset-generation-coverage-is-not-numerical-parity)
7. [The specific numeric hazards to test for](#7-the-specific-numeric-hazards-to-test-for)
8. [The Swift runner, and what "Python bindings are incomplete" means](#8-the-swift-runner-and-what-python-bindings-are-incomplete-means)
9. [`swift-lm`: a real third-party Core AI integration](#9-swift-lm-a-real-third-party-core-ai-integration)
10. [`expectFrequentReshapes`: four sources, three verdicts](#10-expectfrequentreshapes-four-sources-three-verdicts)
11. [The community zoo](#11-the-community-zoo)
12. [Decision table: which bridge, and when to re-author instead](#12-decision-table-which-bridge-and-when-to-re-author-instead)
13. [Quick reference](#13-quick-reference)
14. [Sources and evidence ledger](#14-sources-and-evidence-ledger)

---

## 1. Three bridges, one destination

Every route into Core AI ends at the same artifact: a **`.aimodel`**, which is a *directory* — not
a file — containing serialized Core AI MLIR plus a hash and a metadata blob. Everything upstream of
that is a question of which producer you use.

> ✅ **VERIFIED** — `.aimodel` is a directory. `swift-lm`'s `bundle.py` requires
> `asset_path.suffix == ".aimodel" and asset_path.is_dir()`, and `mlx2coreai`'s smoke test pins the
> children as exactly `["main.hash", "main.mlirb", "metadata.json"]`
> (`tests/test_lower_to_coreai_smoke.py:25-29`). Two independent repos agree.

Here is the whole landscape on one diagram. Apple's own paths are on the left; the third-party
bridges are on the right.

```
   ┌─────────────────────────────────────────────────────────────────────────┐
   │  APPLE-OWNED                          │  THIRD-PARTY                    │
   ├───────────────────────────────────────┼─────────────────────────────────┤
   │                                       │                                 │
   │  HF checkpoint                        │  MLX nn.Module / callable       │
   │       │                               │       │                         │
   │       │ re-author in torch            │       │ mx.export_function(     │
   │       ▼                               │       │     callback, fn, ...)  │
   │  torch.export.export()                │       ▼                         │
   │       │                               │  mlx2coreai                     │
   │       │ .run_decompositions(          │   from_mlx → ir → passes →      │
   │       │     get_decomp_table())       │   op_registry → lower_to_coreai │
   │       ▼                               │       │                         │
   │  coreai_torch.TorchConverter          │       │                         │
   │       │  .add_exported_program(...)   │       │                         │
   │       │  .to_coreai()                 │       │                         │
   │       ▼                               │       ▼                         │
   │   ────────────────  coreai.authoring.AIProgram  ─────────────────       │
   │                            │                                           │
   │                            │ .optimize()                               │
   │                            │ .save_asset(Path)                         │
   │                            ▼                                           │
   │                    <name>.aimodel/                                     │
   │                      main.mlirb  main.hash  metadata.json              │
   │                            │                                           │
   │                            │ wrapped by                                │
   │                            ▼                                           │
   │                    bundle/  metadata.json (schema 0.2)                 │
   │                             tokenizer/                                 │
   │                             <name>.aimodel/                            │
   └────────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
                   AIModel → InferenceFunction → NDArray
                   (or CoreAILanguageModel / LanguageBundle)
```

The critical observation is where the two columns **merge**: at `AIProgram`. Both Apple's
`coreai_torch` and the community's `mlx2coreai` build the same in-memory object and call the same
two methods on it.

> ✅ **VERIFIED** — `mlx2coreai/lower_to_coreai.py:13-31` imports
> `from coreai.authoring import AIProgram, Context`, then calls
> `AIProgram._from_mlir_module(self.module)`, `program.optimize()`, `program.save_asset(path)`.
> `swift-lm`'s `python/src/swiftlm_coreai/program.py` calls `TorchConverter().to_coreai()` →
> `program.optimize()` → `program.save_asset(output_path)`. Same terminal API, two producers.

⚠️ **Note the leading underscore.** `AIProgram._from_mlir_module` is a **private** `coreai` API.
`mlx2coreai` depends on it for its entire existence. A wheel bump can break the converter without
breaking anything Apple documents. This is the single most fragile line in the bridge and it is why
the `coreai-core==1.0.0b1` pin is an `==` and not a `>=`.

### 1.1 What each bridge is actually for

| | `mlx2coreai` | `swift-lm` | zoo (`coreai-model-zoo`) |
|---|---|---|---|
| Input | An **MLX** callable or `nn.Module`, or an `mlx-lm` model id | A **Hugging Face `config.json`** (+ safetensors) | A HF checkpoint, re-authored by hand |
| Intermediate | Its own SSA graph IR → Core AI MLIR | A versioned **JSON contract** (`CoreAIExportDocument`, format 2) → generic torch module → `coreai-torch` | Plain torch, straight from `model.safetensors` |
| Output | `.aimodel`, or a `coreai-models`-style bundle | `.aimodel` + bundle + embedded contract | `.aimodel` bundle, published to Hugging Face |
| Model families | Whatever MLX can trace and the 156-op registry covers | A closed registry: transformer / gemma3 / gemma4 / qwen3.5 / lfm2 / cohere | ~52 carded models across LLM, vision, audio, diffusion |
| Verification story | **None shipped.** Asset-generation coverage only | Real-model logits comparison vs HF, with published numbers | Oracle + two gates, mandatory for acceptance |
| Author | Lucas Newman, MIT, 11 commits (June 2026) | 1amageek, 0.11.0-alpha.1 (July 2026) | john-rocky / mlboydaisuke |

> ✅ **VERIFIED** — `mlx2coreai/pyproject.toml:6-7,12-14`, `LICENSE:1-3`, `git log --oneline -50`
> (11 commits `cc9558e`…`059c9f3`, all June 2026); `swift-lm` `Package.swift`, `python/pyproject.toml`;
> zoo `CATALOG_PLAN.md:30-38` (counts measured 2026-07-25 by the repo's own
> `scripts/gen_inventory.py`).

### 1.2 The one thing they all agree on

All three target the same **bundle metadata schema, version `"0.2"`**, and all three write a
`metadata.json` whose shape is byte-for-byte comparable. That is not a coincidence and it is not a
standard anyone published — it is a de-facto interchange format that emerged because
`apple/coreai-models`'s Swift loader is strict about it. §4 covers this in full, because if you are
building your own bridge it is the thing to target.

---

## 2. `mlx2coreai`: what it is and what it pins

### 2.1 The self-description

The repo describes itself as:

> *"Experimental MLX to CoreAI conversion. Captures MLX graphs, lowers supported ops to CoreAI
> MLIR, and writes `.aimodel` assets or coreai-models-style LLM bundles."*

Take that at face value; every clause is load-bearing.

- **"Experimental"** — 11 commits, one author, version `0.1.1`, and a hard `==` pin on a beta
  wheel. Several workarounds in the source are explicitly commented as *"beta asset writer"* bugs.
- **"Captures MLX graphs"** — via `mx.export_function(callback, fn, **inputs)`, MLX's export
  *callback* tracer, not a re-implementation. §5.1.
- **"lowers supported ops to CoreAI MLIR"** — the destination IR is MLIR. §5.5.
- **"writes `.aimodel` assets **or** coreai-models-style LLM bundles"** — two output shapes, and
  the second one is the interesting one. §3 and §4.

> ✅ **VERIFIED** — repository description, and corroborated by the module structure
> (`lower_to_coreai.py` is 2,072 lines and imports `coreai._compiler.dialects.coreai` plus
> `coreai._compiler.ir`'s MLIR type classes).

### 2.2 Metadata, exactly

| Fact | Value | Source |
|---|---|---|
| Package / version | `mlx2coreai` **`0.1.1`** | `pyproject.toml:6-7` |
| License | MIT, *"Copyright (c) 2026 Lucas Newman"* | `LICENSE:1-3` |
| Python floor | `requires-python = ">=3.11"` | `pyproject.toml:10` |
| Size | 33 files, ~12.1k lines | `wc -l` |
| Commits | 11, `cc9558e`…`059c9f3`, all June 2026 | `git log` |
| Hard pin | **`coreai-core==1.0.0b1`** | `pyproject.toml:21-37` |
| Other deps | `ml-dtypes`, `mlx`, `mlx-lm`, `numpy` | same |

Three console scripts are installed:

```
mlx2coreai                        = mlx2coreai.cli:main
mlx2coreai-convert-mlx-lm         = mlx2coreai._convert_mlx_lm:main
mlx2coreai-convert-mlx-lm-stateful = mlx2coreai._convert_mlx_lm_stateful:main
```

> ✅ **VERIFIED** — `pyproject.toml:71-74` `[project.scripts]`.

`ml-dtypes` is not optional decoration: it is how **bfloat16 survives the trip through numpy**.
`ml_dtypes.bfloat16` is used as a numpy dtype in capture, in lowering, and in output comparison.
Without it, bf16 weights would be widened.

One file in the repo carries an Apple copyright header:

```python
# Copyright 2026 Apple Inc.
#
# Use of this source code is governed by a BSD-3-clause license that can
# be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause
```

> ✅ **VERIFIED** — `mlx2coreai/_composite_declaration.py:1-4`. This 202-line file is **copied out
> of Apple's Core AI Python tooling** into an MIT repo. It is what builds
> `#coreai.composite_declaration<…>` attributes (§5.6). If you are writing your own lowerer, this
> is the file to read: it is Apple's own, and it is the only place in our corpus where the
> composite-declaration attribute syntax appears in source you can copy.

### 2.3 ⚠️ The wheel-pin collision

Stated in the version floor and repeated here because it will bite you:

| Producer | Pinned `coreai-core` | Consequence |
|---|---|---|
| `mlx2coreai` 0.1.1 | **`==1.0.0b1`** | assets it writes are the pre-b2 generation |
| `swift-lm` 0.11.0-alpha.1 | `==1.0.0b2` | current |
| zoo acceptance bar | **`≥ 1.0.0b2`** | *"Bundles exported with earlier wheels are rejected by the Xcode 27 beta 3+ SDK loader (`Failed to convert to versioned IR` — tracked as **FB23666783**); the zoo's own pre-b2 artifacts are being migrated for the same reason."* |

> ✅ **VERIFIED** — `mlx2coreai/pyproject.toml:21-37`; `swift-lm/python/pyproject.toml`;
> zoo `CONTRIBUTING.md:24-28` (quoted verbatim; community-sourced, dated by the repo's own
> migration note).

**What this means concretely.** If you `pip install mlx2coreai` today with its pin honoured, you
get `coreai-core` **b1**, and the bundle you produce may fail to load in an Xcode 27 beta 3+ app
with an error about versioned IR — an error that says nothing about wheels and nothing about MLX.

🔴 **GAP — we have not tested whether `mlx2coreai` works against `coreai-core==1.0.0b2`.** Nobody in
our corpus has installed either wheel. The pin is an `==`, so pip will fight you. What is knowable
from source: `mlx2coreai` uses `AIProgram._from_mlir_module` (private), `GraphOp(...)` with seven
keyword arguments, `DenseResourceElementsAttr.get_from_buffer`, and
`CoreAITensorSpec._to_mlir_type()` (also private). Any of those could have moved between b1 and b2.

**SAFE DEFAULT:** install `mlx2coreai` with the pin relaxed *in a scratch venv*, convert a
three-line toy model (§5.2), and load the resulting `.aimodel` in the Swift runtime before you
convert anything real. If the toy loads, the API surface survived the wheel bump. If it does not,
you have learned that in ninety seconds instead of after a 4 GB conversion.

```bash
python3 -m venv .venv-bridge && . .venv-bridge/bin/activate
pip install "coreai-core==1.0.0b2" mlx mlx-lm ml-dtypes numpy
pip install --no-deps mlx2coreai        # --no-deps skips the ==1.0.0b1 pin
python - <<'PY'
import numpy as np, mlx.core as mx
from mlx2coreai import ConversionConfig, convert_mlx_to_coreai
converted = convert_mlx_to_coreai(
    lambda x, w: mx.tanh(mx.matmul(x, w)),
    {"x": np.ones((2, 3), dtype=np.float32), "w": np.ones((3, 4), dtype=np.float32)},
    config=ConversionConfig(optimize=True),
    output_path="probe.aimodel",
)
print(converted.asset_path)
PY
```

> 🟡 **RECONSTRUCTED** — the `--no-deps` install recipe is standard pip usage, not something the
> repo documents. The Python body is the repo's own README example (§5.2), verbatim except for the
> lambda. Treat the recipe as a suggestion and the payload as verified.

### 2.4 What it does *not* have

Worth stating up front so you do not go looking:

- **No quantization of any kind.** No palettization, no int4/int8 packing, no `coreai-opt`
  integration. bf16 checkpoints stay bf16; everything else lands as fp32 or fp16.
- **No `docs/ops_status.md`.** `op_registry._load_ops_statuses` parses that file to classify
  unsupported ops, and **the file does not exist in the repo**. Every unsupported op therefore
  reports status `unlisted` with the recommendation *"Classify this op in docs/ops_status.md and
  then implement or defer explicitly."* A dangling feature; the error message is still useful, the
  status field is noise.
- **No sliding-window attention.** The stateful path raises
  `NotImplementedError("stateful KV-cache export does not support sliding-window masks yet.")`
  — so Gemma-style and Mistral-SWA models cannot go through it.
- **No batch > 1** on the stateful path:
  `ValueError("stateful mlx-lm conversion currently supports batch_size=1 only.")`
- **No end-to-end runtime test.** §6.

> ✅ **VERIFIED** — all five read from source: absence of any `coreai_opt` import;
> `op_registry.py:377-408` plus a directory listing; `_convert_mlx_lm_stateful.py`
> `_ExportableLayeredKVCache.make_mask`; the `batch_size` guard; and `op_coverage.py:155-163`,
> whose "asset validation" is literally `(asset_path / "main.mlirb").exists()`.

---

## 3. The stateful LLM path

This is the path most readers want, and it is the most consequential file in the repo
(`_convert_mlx_lm_stateful.py`, 881 lines).

### 3.1 The command

```bash
mlx2coreai convert-mlx-lm-stateful mlx-community/Qwen3-0.6B-bf16 \
  --output qwen \
  --max-context-length 256
```

> ✅ **VERIFIED** — this is the canonical invocation from the repo's own `README.md:19-23`, quoted
> exactly. It is not an example someone constructed; it is the documented entry point.

The full flag set, from `cli.py` and `_convert_mlx_lm_stateful.parse_args`:

| Flag | Type | Default |
|---|---|---|
| `--output` | Path | **required**. *"A `.aimodel` suffix is treated as the nested asset name."* |
| `--max-context-length` | int | **256** |
| `--revision` | str | None |
| `--input-name` | str | `input_ids` |
| `--position-ids-name` | str | `position_ids` |
| `--key-cache-name` | str | `keyCache` |
| `--value-cache-name` | str | `valueCache` |
| `--compute-precision` | `auto\|fp32\|fp16\|bf16` | `auto` |
| `--cache-dtype` | `fp32\|fp16\|bf16` | None (follows compute precision) |
| `--entrypoint` | str | `main` |
| `--dynamic-sequence` / `--no-dynamic-sequence` | `BooleanOptionalAction` | **True** |
| `--dynamic-state` / `--no-dynamic-state` | `BooleanOptionalAction` | **True** |
| `--cast-bf16-logits-to-fp16` / `--no-…` | `BooleanOptionalAction` | **True** |
| `--externalize-weights` / `--no-…` | `BooleanOptionalAction` | True |
| `--external-weight-threshold` | int | 10 — **elements, not bytes**; `-1` keeps all constants inline |
| `--capture-is-training` / `--no-…` | `BooleanOptionalAction` | False |
| `--allow-unknown-sources` / `--no-…` | `BooleanOptionalAction` | True |
| `--no-optimize` | flag | off |

> ✅ **VERIFIED** — `mlx2coreai/cli.py` (the `mlx2coreai convert-mlx-lm-stateful` subparser) and
> `_convert_mlx_lm_stateful.py:814-842` (the standalone script's parser). ⚠️ The two parsers are
> *not* identical: the standalone `mlx2coreai-convert-mlx-lm-stateful` console script **omits
> `--batch-size`**, and the Python function accepts `batch_size` but raises for anything but 1.

On success it prints:

```
Wrote bundle …
Asset: …
Entrypoints: …
States: …
Compute precision: …
Cache dtype: …
Max context: …
```

> ✅ **VERIFIED** — `cli.py:194-200`.

### 3.2 What lands on disk

```
qwen/
├── metadata.json
├── tokenizer/            # HF tokenizer files (tokenizer.json, etc.)
└── qwen.aimodel/
    ├── main.mlirb        # serialized Core AI MLIR — weights live here as dense resources
    ├── main.hash
    └── metadata.json
```

Two `metadata.json` files, at two levels, meaning two different things. The outer one is the
**bundle** manifest (schema 0.2, §4). The inner one belongs to the `.aimodel` asset itself and is
written by `program.save_asset()` — Core AI's own, not the bridge's.

The `--output` argument does something slightly surprising:

| `--output` | bundle dir | nested asset |
|---|---|---|
| `qwen` | `qwen/` | `qwen/qwen.aimodel` |
| `qwen.aimodel` | `qwen/` | `qwen/qwen.aimodel` |

> ✅ **VERIFIED** — `_resolve_bundle_paths`, `_convert_mlx_lm_stateful.py:301-311`. Passing
> `--output qwen.aimodel` does **not** give you a bare asset; it gives you a bundle directory named
> `qwen/` whose nested asset is named `qwen.aimodel`. The flag help text says so, obliquely: *"A
> `.aimodel` suffix is treated as the nested asset name."*

⚠️ **Destructive re-run.** `_write_tokenizer` does `shutil.rmtree(dest)` on an existing
`bundle/tokenizer` directory before writing. If you have hand-edited a `chat_template.jinja` in
there — which, per §11.4, is exactly the kind of thing people hand-edit — a re-run deletes it
without asking.

### 3.3 The signature: `main`, two inputs, two mutable states

This is the concrete, verified signature convention for an LLM `.aimodel`, and it is the reason
this section exists. The docstring states the contract:

> ✅ **VERIFIED** — `_convert_mlx_lm_stateful.py:151-157`, verbatim:
>
> *"Convert an mlx-lm model into one stateful CoreAI asset. The generated `.aimodel` follows the
> **macOS LLM contract used by `coreai-models`**: a single dynamic `main` entrypoint with
> `input_ids`, `position_ids`, and two mutable KV-cache state tensors named **`keyCache`** and
> **`valueCache`** by default."*

Laid out:

```
graph @main(
    input_ids   : tensor<1 x ? x si32>        # dynamic token axis (axis 1)
    position_ids: tensor<1 x ? x si32>        # dynamic, and it is the FULL prefix — see §3.5
    keyCache    : tensor<L x B x Hkv x ? x D> # mutable state, dynamic axis 3
    valueCache  : tensor<L x B x Hkv x ? x D> # mutable state, dynamic axis 3
) -> (
    logits      : tensor<1 x ? x V>           # fp16 by default — see §3.6
    keyCache                                   # the mutated cache, exported under its plain name
    valueCache
)
```

The cache shape is exactly:

```python
shape = (layout.num_layers, int(batch_size), layout.num_key_value_heads,
         int(max_context_length), layout.head_dim)
return [StateSpec(key_cache_name, shape, cache_dtype),
        StateSpec(value_cache_name, shape, cache_dtype)]
```

> ✅ **VERIFIED** — `_make_state_specs`, `_convert_mlx_lm_stateful.py`. And byte-for-byte the same
> as Apple's: `apple/coreai-models`'s `primitives/macos/cache.py:52-53` is
> `torch.zeros(n_layers, 1, n_kv_heads, max_seq_len, head_dim)`, with `KVCache.seq_len_dim() == 3`
> — the same dynamic axis.

**How Core AI knows a graph argument is a state.** Not from a type. From an **argument attribute**
written onto the `GraphOp` after the block is built:

```python
if spec.name in output_by_state:
    attrs["MutableBuffers.buffer_mutation"] = StringAttr.get(output_by_state[spec.name])
...
graph_op.arg_attrs = ArrayAttr.get(arg_attrs)
```

> ✅ **VERIFIED** — `_mark_mutable_buffers`, `lower_to_coreai.py:658-682`. The contract: *graph
> argument `keyCache` carries `MutableBuffers.buffer_mutation = "<name of the graph output that is
> its new value>"`.* A test pins the literal MLIR text:
> `'MutableBuffers.buffer_mutation = "cache_out"' in str(lowered.program)`
> (`tests/test_op_coverage.py:300-313`).

This is the **same annotation `coreai-torch` emits** for a `register_buffer` mutated in place:

```
coreai.graph @main(
  %0: tensor<1x4xf32> {MutableBuffers.buffer_mutation = "b_state", coreai.name = "b_state"},
  %1: tensor<1x4xf32> {coreai.name = "x"}
) -> (tensor<1x4xf32> {coreai.name = "b_state"})
```

> ✅ **VERIFIED** — `coreai-torch` `docs/api/TorchConverter.md` §"IO naming". Two independent
> producers converging on the same MLIR attribute is strong evidence that this *is* the Core AI
> state contract, not a convention either one invented.

For what the consuming side does with this — `InferenceFunction.MutableViews`, `states:`,
`consume`, and the whole ownership dance — see
[Part 7 guide 03 §5](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md).

### 3.4 The trace constants deliberately mirror Apple's

```python
TRACE_QUERY_LENGTH = 16      # _convert_mlx_lm_stateful.py:34
TRACE_POSITION_OFFSET = 8    # _convert_mlx_lm_stateful.py:35
```

Against `apple/coreai-models`'s `python/src/coreai_models/export/_constants.py`:

```python
# KV cache names used by the Swift runner
KEY_CACHE_NAME = "keyCache"
VALUE_CACHE_NAME = "valueCache"
TRACE_KV_CACHE_SEQ_LEN = 2048
QUANT_TRACE_QUERY_LEN = 16
QUANT_TRACE_OFFSET = 8
```

> ✅ **VERIFIED** — both files read from source. Identical values (16 / 8), identical state names.
> `mlx2coreai` is not accidentally compatible with Apple's LLM export recipe; it is deliberately
> reproducing it from the MLX side.

At the default `--max-context-length 256`, the trace shapes work out as:
`trace_sequence_length = min(16, max_context_length) = 16`, `trace_offset = 8` (clamped so
`offset + seq <= max_context_length`), so `position_length = 24` and the traced
`position_ids = arange(24)[None, :]`.

### 3.5 `position_ids` is the **full** position vector

This is the single most misunderstood part of the contract, and it is derivable from four lines of
the source:

```python
def _offset_from_position_ids(input_ids, position_ids):
    query_indices = mx.arange(input_ids.shape[1], dtype=mx.int32)
    query_len = mx.max(query_indices) + mx.array(1, dtype=mx.int32)
    last_position = mx.max(position_ids)
    return last_position - query_len + mx.array(1, dtype=mx.int32)
```

> ✅ **VERIFIED** — `_convert_mlx_lm_stateful.py:558-564`, verbatim.

That is `offset = max(position_ids) - len(input_ids) + 1`. The KV write offset is computed
**inside the traced graph** from `position_ids`. So if you pass only the *new* positions, the
offset is wrong and the cache is written in the wrong place — with no error, because the arithmetic
is valid for any input.

Both of the repo's benchmark backends feed `arange(total_positions)`:

```python
# python backend, benchmark_aimodel_sampling.py:214-239
position_ids_name: NDArray(np.asarray(position_ids, dtype=np.int32)[None, :]),
```
```swift prelude:guide-context
// swift backend, benchmark_aimodel_sampling_coreai.swift:227-264
var positionIds = NDArray(descriptor: positionDesc.resolvingDynamicDimensions([1, totalPositions]))
fillInt32(&positionIds, values: (0..<totalPositions).map { Int32($0) })
```

> ✅ **VERIFIED** — both read from source.

Read the arithmetic carefully, because it is narrower than "pass the full vector":

**the only thing the graph reads out of `position_ids` is `max(position_ids)`.** Its length is
never used; `query_len` comes from `input_ids.shape[1]`. So the real invariant is:

> `max(position_ids)` **must equal the absolute position of the last token in `input_ids`.**

The full prefix range `[0 .. total_positions-1]` satisfies that invariant, which is why both
benchmark backends and `swift-lm` all pass it, and why the convention is worth following even
though a shorter vector with the right maximum would also work. Follow the convention; do not
optimise it.

⚠️ **SILENT FAILURE — a `position_ids` whose maximum is not the last query position writes the
cache at the wrong offset, and nothing reports it.** Three realistic ways to trip it, none of which
throw:

1. **Right-padding a batch or a fixed-length buffer** with a sentinel like `max_context_length - 1`
   or `0`. A pad value *above* the real last position inflates `max` and pushes the write past the
   end of the used region; a pad of `0` is harmless only because `max` ignores it.
2. **Passing positions in a non-monotonic order** — legal for the tensor, fatal for the assumption.
3. **Passing only the *new* positions during chunked prefill while also trimming from the left**,
   so the highest position you pass is no longer the last token you are feeding.

The consequence is that keys and values for this step land at the wrong slice of a 5-D cache. Later
attention reads a mixture of the current step and stale zeros. Logits stay finite and in range, the
sampler keeps producing tokens, and the text degrades gradually — the classic *"step 1 looks fine,
step 30 is nonsense"* shape that §6's per-step gate exists to catch. **Code review will not find
this; only a token-for-token comparison against the MLX original will.**

**The defence is §6's parity test, not code review.** Independently, `swift-lm` documents the
identical contract for its own stateful exports — *"`input_ids` has shape `1x1`, while
`position_ids` carries the **complete prefix range** for the current token"*
(`docs/design/core-ai.md:123-126`) — which is corroboration from a second, unrelated producer that
this is how Core AI stateful LLM graphs are meant to be driven.

### 3.6 Precision, and the flag that couples to the Swift runner

- `_resolve_compute_precision(model, "auto")` walks `model.parameters()` and returns the first
  `bf16 | fp16 | fp32` it sees, defaulting to `fp32`.
- `_apply_model_compute_precision` calls `model.set_dtype(mx.bfloat16 | float16 | float32)` when the
  model exposes it. ⚠️ **This mutates the loaded model in place.** If you are converting several
  variants in one process, reload between them.
- `cache_dtype` defaults to the resolved compute precision.
- `--cast-bf16-logits-to-fp16` is **on by default** and casts bf16 logits to fp16 *inside the traced
  graph*. The older README explained why: *"logits are cast to FP16 by default to match the public
  Qwen3 coreai-models recipe."*

⚠️ **The flag is load-bearing for the Swift benchmark.** `greedyToken` in
`benchmark_aimodel_sampling_coreai.swift` does `logits.view(as: Float16.self)` — hard-coded. Turn
`--no-cast-bf16-logits-to-fp16` on and the Swift runner reinterprets bf16 bytes as fp16 and reports
garbage argmax indices. No crash; a working benchmark that is measuring nonsense.

> ✅ **VERIFIED** — `_convert_mlx_lm_stateful.py` §11.7 of the source notes;
> `benchmark_aimodel_sampling_coreai.swift` `greedyToken`.

### 3.7 The exportable cache shim — the clever bit

MLX's tracer only sees operations that actually execute. mlx-lm's `KVCache` mutates Python state,
which the tracer cannot see. So the bridge substitutes a **duck-typed replacement** that records
slice-updates into a single stacked tensor:

```python
class _ExportableLayeredKVCache:
    def __init__(self, state, *, layer_idx, offset):
        self.state = state
        self.layer_idx = int(layer_idx)
        self.keys = state.keys[self.layer_idx]
        self.values = state.values[self.layer_idx]
        self.offset = offset

    def update_and_fetch(self, keys, values):
        import mlx.core as mx
        offset = mx.reshape(self.offset, (1,))
        layer = mx.array([self.layer_idx], dtype=mx.int32)
        start = mx.concatenate([
            layer,
            mx.array([0, 0], dtype=mx.int32),
            offset,
            mx.array([0], dtype=mx.int32),
        ])
        expanded_keys = mx.expand_dims(keys, 0)
        expanded_values = mx.expand_dims(values, 0)
        self.state.keys = mx.slice_update(self.state.keys, expanded_keys, start, [0, 1, 2, 3, 4])
        self.state.values = mx.slice_update(self.state.values, expanded_values, start, [0, 1, 2, 3, 4])
        self.keys = self.state.keys[self.layer_idx]
        self.values = self.state.values[self.layer_idx]
        return self.keys, self.values

    def make_mask(self, N, window_size=None, return_array=False):
        import mlx.core as mx
        if window_size is not None:
            raise NotImplementedError(
                "stateful KV-cache export does not support sliding-window masks yet."
            )
        query_positions = mx.arange(N) + self.offset
        key_positions = mx.arange(self.state.keys.shape[3])
        return (query_positions[:, None] >= key_positions[None, :])[None, None, :, :]

    def size(self) -> int: return self.state.keys.shape[3]
    def empty(self) -> bool: return False
```

> ✅ **VERIFIED** — `_convert_mlx_lm_stateful.py:67-128`, verbatim. The interface it emulates
> (`update_and_fetch`, `make_mask`, `size`, `empty`, `.offset`, `.keys`, `.values`) is **mlx-lm's
> cache protocol** — see [Part 12 guide 04](../../part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md).

`mx.slice_update(dst, src, start, axes)` becomes a `DynamicSliceUpdate` primitive →
`dynamic_slice_update` IR op → `coreai.slice_update`. That is the whole trick: **an in-place cache
write becomes a traced tensor operation**, which is what makes it lowerable.

The capture function that drives it:

```python
def capture(**kwargs):
    import mlx.core as mx
    input_ids = kwargs[input_name]
    position_ids = kwargs[position_ids_name]
    offset = _offset_from_position_ids(input_ids, position_ids)
    state = _LayeredKVCacheState(keys=kwargs[key_cache_name], values=kwargs[value_cache_name])
    caches = [_ExportableLayeredKVCache(state, layer_idx=i, offset=offset)
              for i in range(layout.num_layers)]
    logits = _select_primary_output(model(input_ids, cache=caches))
    if cast_bf16_logits_to_fp16 and "bfloat16" in str(getattr(logits, "dtype", "")).lower():
        logits = logits.astype(mx.float16)
    return logits, state.keys, state.values
```

> ✅ **VERIFIED** — `_convert_mlx_lm_stateful.py`, verbatim. The traced function returns a
> **3-tuple**; `_add_state_writes` then rewrites the two cache tensors into `write_state` nodes,
> and `_reorder_graph_inputs(graph, [input_name, position_ids_name, key_cache_name,
> value_cache_name])` forces the argument order — which is why the Swift runner can safely index
> `descriptor.stateNames[0]` as key and `[1]` as value.

Cache layout is inferred, with fallbacks:

```
_infer_cache_layout(model):
  depth       ← model.layers  or  model.model.layers
  kv heads    ← model.args.num_key_value_heads   → layers[0].self_attn.n_kv_heads
  head dim    ← model.args.head_dim              → hidden_size // num_attention_heads
```

failing with `"Could not infer mlx-lm transformer layers for stateful cache conversion."` or
`"Could not infer KV-cache head layout from mlx-lm model args."`

> ✅ **VERIFIED** — `_convert_mlx_lm_stateful.py:634-657`.

---

## 4. The bundle layout is the interchange format

Here is the fact that matters most if you are building your own bridge, and it is not written down
anywhere as a specification: **`apple/coreai-models`'s `metadata.json` schema `"0.2"` has become the
de-facto interchange format for on-device LLM bundles on this platform, and third parties target it
deliberately.**

Nobody published it as a standard. It became one because Apple's Swift loader is strict about it,
and because once you emit it, `CoreAILanguageModel(resourcesAt:)` and `LanguageBundle(at:)` just
work on your output.

### 4.1 Three producers, one schema

**Apple's own writer** (`coreai-models` `python/src/coreai_models/export/bundle.py:42-74`):

```python
METADATA_VERSION = "0.2"
metadata = {
    "metadata_version": "0.2",
    "kind": "llm",
    "name": name,
    "assets": {"main": f"{name}.aimodel"},
    "language": {
        "tokenizer": hf_model_id,
        "vocab_size": hf_config.vocab_size,
        "max_context_length": hf_config.max_position_embeddings,
        "embedded_tokenizer": True,
        "function_map": {"main": ["main"]},
    },
    "source": {"model_definition": "torch", "hf_model_id": hf_model_id},
    "compression": compression if compression != "none" else None,
    "compilation": {"date": datetime.now().astimezone().isoformat(), "targets": []},
}
```

**`mlx2coreai`'s writer** (`_write_coreai_models_bundle`):

```python
{
    "metadata_version": "0.2",
    "kind": "llm",
    "name": name,
    "assets": {"main": asset_name},
    "language": {
        "tokenizer": model_id,
        "vocab_size": _vocab_size(tokenizer, model),
        "max_context_length": int(max_context_length),
        "embedded_tokenizer": True,
        "function_map": {"main": [entrypoint_name]},
    },
    "source": {"model_definition": "mlx", "hf_model_id": model_id},
    "compression": None,
    "compilation": {"date": datetime.now().astimezone().isoformat(), "targets": []},
}
```

**`swift-lm`'s writer** (`python/src/swiftlm_coreai/bundle.py:44-66`):

```python
metadata: dict[str, Any] = {
    "metadata_version": METADATA_VERSION,          # "0.2"
    "kind": "llm",
    "name": name,
    "assets": {
        "main": resolved_asset_name,               # f"{name}.aimodel"
        "contract": contract_name,                 # "swiftlm-program.json"
        "contract_sha256": contract_sha256,
    },
    "language": {
        "tokenizer": "tokenizer",
        "vocab_size": vocab_size,
        "max_context_length": max_context_length,
        "embedded_tokenizer": True,
        "function_map": function_map or {"main": ["main"]},
    },
    "source": {
        "model_definition": "swift_lmir",
        "format_version": 2,
        "hf_model_id": model_id,
    },
    "compression": compression,                    # None by default
}
```

> ✅ **VERIFIED** — all three read from source in their respective repos. `mlx2coreai`'s test
> `test_convert_mlx_lm_stateful_live_mlx_smoke_saves_unified_asset`
> (`tests/test_convert_mlx_lm.py:196-257`) asserts every one of these fields, so the compatibility
> is *tested*, not aspirational.

The differences are exactly three, and they are all in `source`:

| field | Apple | `mlx2coreai` | `swift-lm` |
|---|---|---|---|
| `source.model_definition` | `"torch"` | **`"mlx"`** | **`"swift_lmir"`** |
| `source.format_version` | — | — | `2` |
| `compression` | a real string when compressed | always `None` | `None` by default |

Plus `swift-lm` adds two keys under `assets` — `contract` and `contract_sha256` — for its own
embedded JSON contract. Apple's reader ignores extra keys; `swift-lm`'s reader requires them.

### 4.2 What the reader enforces

`apple/coreai-models`'s `ModelBundle` (in `CoreAIShared`) is the strict side:

```swift prelude:guide-context
public struct ModelBundle: Sendable {
    public let metadataVersion: String
    public let kind: BundleKind
    public let name: String
    public let bundlePath: URL
    public let userData: [String: String]?
    public let assets: [String: String]      // role -> filename
    public let raw: Data                     // full metadata.json bytes, preserved
    public enum ComponentKey { static let main = "main"
                               static let vision = "vision"
                               static let embedding = "embedding" }
    public var componentKeys: [String] { assets.keys.sorted() }
    public func modelURL(for key: String) -> URL?
    public func requireModelURL(for key: String) throws -> URL
    public func verify() throws          // checks every declared asset exists on disk
    public init(at url: URL) throws
}
```

```swift compile:27
public enum BundleKind: String, Codable, Sendable, CaseIterable {
    case llm; case vlm; case diffusion; case segmenter
}
```

> ✅ **VERIFIED** — `swift/Sources/CoreAIShared/Bundle/ModelBundle.swift` and `BundleKind.swift`
> in `apple/coreai-models`.

Two footguns are encoded directly in that reader, and both are worth knowing if your bridge emits
bundles:

1. ⚠️ **`metadata_version` defaults to `"0.1"` when absent, and anything other than `"0.2"`
   throws** `.unsupportedVersion` with the text
   `"unsupported metadata_version '\(v)' (known: 0.2)"`. Omitting the key does not give you a
   permissive default; it gives you a confusing error.
2. ⚠️ **Passing a `.aimodel` / `.aimodelc` path where a bundle directory is expected throws
   `.pointedAtModelAsset` before any filesystem read.** The reason, from the source comment: *"a
   compiled `.aimodelc` is itself a directory holding its own unrelated metadata.json, which would
   otherwise parse as a bogus 0.1 bundle and surface a misleading 'unsupported metadata_version'
   error."* This is Apple pre-empting exactly the confusion §3.2's two-`metadata.json` layout
   creates.

And the error that tells you what to do after AOT compilation, verbatim from `.missingAsset`:

> *"If you compiled this model with `xcrun coreai-build compile`, update metadata.json "assets" to
> reference the compiled filename (e.g. modelName.architectureName.aimodelc). See
> models/README.md#compiled-models"*

> ✅ **VERIFIED** — `ModelBundle.swift`, error strings quoted from source.

### 4.3 The `language` block, and `function_map`

```swift prelude:guide-context
public struct LanguageConfig: Codable, Sendable, Equatable {
    public let tokenizer: String            // "tokenizer"
    public let vocabSize: Int               // "vocab_size"
    public let maxContextLength: Int        // "max_context_length"
    public let embeddedTokenizer: Bool      // "embedded_tokenizer", default true
    public let functionMap: FunctionMap?    // "function_map"
    public let vision: VisionConfig?        // "vision"
}
```

`FunctionMap` is `[String: [String]]` — a **role → physical function names** map, always
array-valued, with `name(for:)` returning the first. It exists for chunked-static (ANE) models that
expose several `extend_<N>` functions under one logical role.

> ✅ **VERIFIED** — `CoreAILanguageModels/Bundle/LanguageConfig.swift` and
> `CoreAIShared/Bundle/FunctionMap.swift`.

Note that `mlx2coreai` writes `"function_map": {"main": [entrypoint_name]}` — so if you pass
`--entrypoint decode`, the *role* stays `main` and the *physical function* becomes `decode`. That is
the correct use of the field and it is nice that the bridge gets it right.

🔴 **GAP — `function_map` semantics are not fully specified anywhere in our corpus.** Both
third-party writers emit `{"main": ["main"]}` and `swift-lm`'s reader calls
`bundle.language.functionMap?.name(for: "main")`, which implies role→function-name mapping and
first-wins. Whether a role may legitimately list several functions for a *non*-chunked model, and
what the other legal role names are, is unverified. **SAFE DEFAULT:** emit
`{"main": ["<your entrypoint>"]}` and nothing else unless you are building a chunked-static ANE
bundle, in which case follow `apple/coreai-models`'s iOS export path rather than inventing keys.

### 4.4 The VLM variant

For `kind: "vlm"` the `assets` dictionary grows to three entries and a `vision` block appears:

```json
{
  "metadata_version": "0.2",
  "kind": "vlm",
  "name": "test-vlm",
  "assets": {
    "main": "decoder.aimodel",
    "embedding": "embed.aimodel",
    "vision": "vision.aimodel"
  },
  "language": {
    "tokenizer": "test/tokenizer",
    "vocab_size": 152064,
    "max_context_length": 4096,
    "embedded_tokenizer": false
  },
  "vision": {
    "image_size": 448,
    "patch_size": 16,
    "image_token_count": 196,
    "image_token_id": 151655,
    "image_mean": [0.48145466, 0.4578275, 0.40821073],
    "image_std": [0.26862954, 0.26130258, 0.27577711],
    "rescale_factor": 0.00392156862745098
  }
}
```

> ✅ **VERIFIED** — this is `swift-lm`'s own test fixture
> (`Tests/SwiftLMFoundationModelsTests/SwiftLMFoundationModelBundleTests.swift:153-179`), verbatim.
> It is a *third-party* file describing *Apple's* format, which is the whole point of this section:
> the format is legible enough to reimplement.

The arithmetic checks out: 448/16 = 28 patches per side, 28² = 784, ÷4 for spatial merge = **196**
visual tokens; `image_token_id` 151655 is the Qwen-VL `<|image_pad|>` id.

Apple's own `VisionConfig` carries two fields this fixture omits, both with defaults:

```swift illustrative
public let imageStrategy: ImageStrategy // "image_strategy", default .stretch
public let includeImageInfo: Bool       // "include_image_info", default false
public static let clipMean = [0.48145466, 0.4578275, 0.40821073]
public static let clipStd  = [0.26862954, 0.26130258, 0.27577711]
```

> ✅ **VERIFIED** — `apple/coreai-models`, `VisionConfig`. Note the fixture's `image_mean` /
> `image_std` are exactly `clipMean` / `clipStd`, so it could have omitted them too.

⚠️ `mlx2coreai` writes **only `kind: "llm"`**. There is no VLM path in it. If you want a
`kind: "vlm"` bundle you are on Apple's exporter or `swift-lm`'s (§9).

### 4.5 Targeting the format yourself

If you are writing a third bridge, the checklist that both existing ones satisfy:

- [ ] `metadata_version` is the **string** `"0.2"`. Not a number, not absent.
- [ ] `kind` is one of `llm` / `vlm` / `diffusion` / `segmenter` — the `BundleKind` enum has no
      other cases, and notably **no case for speech or detection**.
- [ ] `assets.main` names a **directory** ending in `.aimodel` (or `.aimodelc` after AOT), relative
      to the bundle root, and it exists — `ModelBundle.verify()` checks every declared asset.
- [ ] Asset paths do not escape the bundle. `swift-lm`'s loader rejects that explicitly
      (*"asset path escapes the bundle"*), and it is a good idea regardless.
- [ ] `language.embedded_tokenizer` is `true` **and** `tokenizer/tokenizer.json` exists, or it is
      `false` and `language.tokenizer` is a resolvable HF id.
- [ ] `language.vocab_size` and `language.max_context_length` are positive and *true*. The Swift
      side sizes buffers from them.

🔴 **GAP — whether `metadata_version "0.2"` admits `kind` values beyond `llm` and `vlm` in
practice.** `BundleKind` declares four cases, but our corpus contains no `diffusion` or `segmenter`
`metadata.json` to read, and `apple/coreai-models`' `SpeechBundle` requires an
`encoder.aimodel` + `decoder.aimodel` split that **nothing in that repo produces** — with no
`BundleKind` case for speech at all. **SAFE DEFAULT:** if you are bridging a non-LLM model, emit
the bare `.aimodel` and load it with `AIModelAsset` / `AIModel` directly (Part 7 guide 01) rather
than trying to wrap it in a bundle whose reader may not exist.

---

## 5. The generic path, and the pipeline by module name

The stateful LLM path is a *specialisation* of a general MLX-graph converter. If your model is not
an `mlx-lm` causal LM — a vision encoder, an audio front-end, a hand-written attention block — this
is the API you use.

### 5.1 The minimal working example

```python
import mlx.core as mx
import numpy as np

from mlx2coreai import ConversionConfig, convert_mlx_to_coreai


def model(x, w):
    return mx.tanh(mx.matmul(x, w))


converted = convert_mlx_to_coreai(
    model,
    {
        "x": np.ones((2, 3), dtype=np.float32),
        "w": np.ones((3, 4), dtype=np.float32),
    },
    config=ConversionConfig(optimize=True),
    output_path="model.aimodel",
)

print(converted.asset_path)
```

> ✅ **VERIFIED** — verbatim from `README.md:40-64`. Note the input dict is `{name: np.ndarray}`,
> keyed by the function's *keyword argument names*; §5.3 explains why MLX needs a whole event type
> to make that work.

`convert_mlx_to_coreai` returns a `ConvertedCoreAIModel`:

```python
@dataclass(slots=True)
class ConvertedCoreAIModel:        # conversion.py:69-83
    prepared: PreparedMLXGraph
    lowered: LoweredCoreAIProgram
    asset: Any | None              # whatever program.save_asset() returned
    asset_path: Path | None
    metadata: dict[str, Any] = field(default_factory=dict)
    # properties: .program, .weight_manifest
```

> ✅ **VERIFIED** — `conversion.py:69-83`.

`metadata` carries exactly these keys: `entrypoint_name, min_runtime_target, capture_shapeless,
dynamic_axes, optimized, optimization_skip_reason, externalize_weights,
external_weight_threshold, extra_input_names, unresolved_extra_inputs, weight_manifest,
inference_summary`.

⚠️ **Read `metadata["unresolved_extra_inputs"]` every time.** `_public_inputs` appends to that list
any graph input that was not in `public_input_names` — but **still keeps it as a public graph
argument**. Meaning: a weight that MLX did *not* classify as a tape constant silently becomes a
**required runtime input**. Your `.aimodel` will demand a tensor your Swift caller does not know
about, and the only warning was a key in a metadata dict nobody printed.

### 5.2 `ConversionConfig`, every field

```python
@dataclass(slots=True)
class ConversionConfig:
    capture_mode: str = "callback"                          # "callback" | "dot"
    allow_unknown_sources: bool = True
    capture_shapeless: bool = False                         # → mx.export_function(shapeless=)
    dynamic_axes: DynamicAxes | None = None                 # {input_name: [axis,...] | "all"}
    dynamic_probe_inputs: Mapping[str, Any] | None = None
    capture_is_training: bool = False
    optimize: bool = True                                   # → AIProgram.optimize()
    entrypoint_name: str = "main"
    state_specs: list[StateSpec] | None = None
    externalize_weights: bool = True
    external_weight_threshold: int = 10                     # ELEMENTS, not bytes; -1 = never
    min_runtime_target: str = "macOS27"                     # metadata only, not enforced
    constant_inputs: Mapping[str, Any] | None = None
```

> ✅ **VERIFIED** — `conversion.py:23-37`, verbatim.

Three of these deserve a warning label:

- **`external_weight_threshold = 10` counts elements, not bytes** (`arr.size`,
  `lower_to_coreai.py:570-580`). A 3×4 matrix has 12 elements and therefore becomes an external
  dense resource; a scalar does not. If you were expecting a byte threshold you will externalize
  far more than you intended.
- **`min_runtime_target = "macOS27"` is recorded into metadata and nothing validates it**
  (`conversion.py:253`). It is documentation, not a gate.
- **`allow_unknown_sources = True` is the default and it is not safe.** ⚠️ **SILENT FAILURE:** for
  any tensor with no known spec, the parser invents `TensorSpec(name, shape=(), dtype="fp32")` — a
  **scalar fp32 stand-in** (`from_mlx.py:456-458`). That is a guess, it can be badly wrong, and it
  produces a converting asset. Set `allow_unknown_sources=False` on your first conversion of any
  model and only relax it once you know which tensor is unknown and why.

The four entry points:

```python
capture_mlx_graph(target, inputs, *, dot_output_path=None, capture_mode="callback",
                  capture_shapeless=False, allow_unknown_sources=True,
                  capture_is_training=False, capture_function=None) -> CapturedMLXGraph

prepare_mlx_conversion(target, inputs, *, config=None, dot_output_path=None,
                       capture_function=None) -> PreparedMLXGraph

lower_graph_to_coreai(graph, *, config=None, public_input_names=None) -> LoweredCoreAIProgram

convert_mlx_to_coreai(target, inputs, *, config=None, output_path=None,
                      dot_output_path=None, capture_function=None) -> ConvertedCoreAIModel
```

> ✅ **VERIFIED** — `conversion.py`, signatures read from source.

`target` must be callable unless `capture_function` is given. For an `nn.Module` you pass the
module as `target` (so `.train()` / `.eval()` toggling works) and a closure as `capture_function`.

### 5.3 The pipeline, module by module

The module names map the pipeline cleanly, which is unusual and worth exploiting when you are
debugging.

```
MLX callable / nn.Module
        │
        │  mx.export_function(callback, fn, shapeless=?, **mx_inputs)      ← from_mlx.py   (1303 L)
        ▼
  list[dict] "events"  (inputs / keyword_inputs / outputs / constants / primitive)
        │  parse_mlx_export_events_to_graph()
        ▼
   Graph  (TensorSpec / Node / StateSpec, plain SSA, string tensor names)  ← ir.py         ( 113 L)
        │  optional: dynamicize_graph_from_probe()                        ← dynamic_shapes.py (151 L)
        │  normalize_graph()                                              ← passes.py     (1032 L)
        │  infer_graph_specs()                                            ← passes.py
        │  ensure_supported()                                             ← op_registry.py ( 543 L)
        ▼
   CoreAILowerer.lower_many() → coreai.GraphOp per entrypoint             ← lower_to_coreai.py (2072 L)
        │       (+ #coreai.composite_declaration<…>                       ← _composite_declaration.py (202 L, Apple))
        │  AIProgram._from_mlir_module(module); program.optimize()
        ▼
   program.save_asset(path) → <name>.aimodel/{main.mlirb, main.hash, metadata.json}
        │                                                                  ← conversion.py ( 304 L)
        └─ stateful path also writes bundle/                              ← _convert_mlx_lm_stateful.py (881 L)
           stateless single-asset path                                    ← _convert_mlx_lm.py ( 341 L)

   side modules:  runtime.py (556) · cli.py (208) · op_coverage.py (310) · reporting.py (77)
```

| Module | Lines | Role |
|---|---:|---|
| `__init__.py` | 92 | Public exports + a lazy-import shim so `import mlx2coreai` does not pull in `mlx_lm` |
| `ir.py` | 113 | `TensorSpec`, `StateSpec`, `Node`, `Graph`, dynamic-dim refs |
| `from_mlx.py` | 1303 | MLX capture (callback + DOT), primitive-arg → attr extraction, IR replay |
| `passes.py` | 1032 | Normalization passes + shape/dtype inference |
| `op_registry.py` | 543 | MLX-name → lowering-key map, DOT aliases, unsupported-op reporting |
| `lower_to_coreai.py` | 2072 | The Core AI MLIR emitter — the heart |
| `conversion.py` | 304 | `ConversionConfig` + capture/prepare/lower/convert orchestration |
| `dynamic_shapes.py` | 151 | Probe-based dynamic-axis inference |
| `_composite_declaration.py` | 202 | **Vendored Apple file** — builds `#coreai.composite_declaration<…>` |
| `_convert_mlx_lm.py` | 341 | Stateless mlx-lm → single `.aimodel` |
| `_convert_mlx_lm_stateful.py` | 881 | Stateful KV-cache LLM → `coreai-models`-style bundle |
| `runtime.py` | 556 | Async/sync `.aimodel` execution + numeric validation |
| `op_coverage.py` | 310 | Coverage report generator (`docs/op_coverage.md` / `.json`) |
| `reporting.py` | 77 | Version collection + stage timing helpers — **unwired at HEAD** |
| `cli.py` | 208 | argparse CLI |

> ✅ **VERIFIED** — file list and line counts from the repo.

**Debugging tip that falls straight out of this layout.** Because `prepare_mlx_conversion` stops
before lowering, you can bisect any conversion failure in one call:

```python
from mlx2coreai import ConversionConfig, prepare_mlx_conversion

prepared = prepare_mlx_conversion(model, inputs,
                                  config=ConversionConfig(allow_unknown_sources=False))
print(prepared.inference_summary)        # {"total_tensors", "with_shape", "with_dtype"}
print(prepared.unsupported_details)      # per-op backlog rows
print(prepared.extra_input_names)        # graph inputs that were NOT user-supplied (= weights)
```

If `inference_summary["with_shape"]` is well below `total_tensors`, the shape inferencer did not
understand your graph and the lowering will be guessing. If `extra_input_names` is non-empty and
you did not expect it, see the `unresolved_extra_inputs` warning in §5.1.

> ✅ **VERIFIED** — `PreparedMLXGraph` fields, `conversion.py:47-67`; `summarize_inference` returns
> exactly those three keys.

### 5.4 Capture: MLX's callback event contract

The capture itself is five lines of real work:

```python
events: list[dict[str, Any]] = []

def _callback(payload: dict[str, Any]) -> None:
    events.append(payload)

mx.export_function(_callback, function, shapeless=bool(shapeless), **mx_inputs)
```

> ✅ **VERIFIED** — `from_mlx.py:754-808`.

MLX emits five event types, and this is verified against MLX's own C++ source
(`mlx/export.cpp:698-756`, `FunctionExporter::export_with_callback`):

```cpp
callback({{"type", "inputs"},         {"inputs",   to_vector_data(inputs)}});   // (name, shape, dtype)
callback({{"type", "keyword_inputs"}, {"keywords", keyword_inputs}});           // (kwarg_key, tensor_name)
callback({{"type", "outputs"},        {"outputs",  to_vector_data(outputs)}});
callback({{"type", "constants"},      {"constants", new_constants}});           // (name, array)
callback({{"type", "primitive"},
          {"inputs",  to_vector_data(arr.inputs())},
          {"outputs", to_vector_data(arr.outputs())},
          {"name", name},
          {"arguments", state}});
```

Three consequences the bridge exploits:

1. **Weights arrive as `constants`, not inputs.** MLX classifies `nn.Module` parameters as *tape
   constants*, so they become `const` IR nodes with a numpy `value` attr, and end up as MLIR dense
   resources inside `main.mlirb`. **There is no separate weight file.** A `.aimodel` from this
   bridge is self-contained.
2. **`keyword_inputs` is why your kwarg names survive.** MLX sorts kwargs into a `std::map` before
   appending them to the flat input list (`export.cpp:766-772`), so without this event the names
   would be scrambled. `alias_by_tensor_name` (`from_mlx.py:532-538`) undoes it.
3. **The primitive `name` is the canonical class name *after* `name_remap`, not the display name.**
   This is the source of several silent failures in §7. `Sum/Prod/Min/Max/And/Or` all report as
   **`Reduce`**; `BitwiseAnd/Or/Xor/LeftShift/RightShift` all report as **`BitwiseBinary`**;
   `Log2/Log10` both report as **`Log`**.

> ✅ **VERIFIED** — `mlx/export.cpp:406` (Reduce), `:340-346` (BitwiseBinary), `:381` (Log), and the
> MLX test `python/tests/test_export_import.py:501-537` which asserts
> `primitives == ["Subtract", "Abs", "Log", "AsType"]`.

⚠️ **The model runs twice per capture.** After `mx.export_function` returns, `from_mlx.py:781` does
`outputs = function(**mx_inputs)` again to obtain reference numpy outputs. Add a dynamic probe
(§5.7) and it is two traces and at least two more executions. For a large model this is not free,
and **any nondeterminism — dropout, RNG — diverges between the trace and the reference run** unless
`capture_is_training=False`.

There is also a legacy `capture_mode="dot"` path that regex-parses `mx.export_to_dot` output. It
**has no primitive arguments at all**, which is precisely why the callback mode exists. No test
exercises it end to end. Do not use it.

### 5.5 Lowering: Core AI's IR is MLIR

This is the fact worth internalising from the whole section. The imports at the top of
`lower_to_coreai.py` are a precise inventory of the Core AI Python compiler surface:

```python
from coreai._compiler.dialects import coreai
from coreai._compiler.ir import (
    ArrayAttr, BF16Type, DenseResourceElementsAttr, DictAttr, F16Type, F32Type,
    InsertionPoint, IntegerType, Location, Module, RankedTensorType, StringAttr, Type, Value,
)
from coreai.authoring import AIProgram, Context
from coreai._compiler.types import TensorSpec as CoreAITensorSpec
```

> ✅ **VERIFIED** — `lower_to_coreai.py:13-31`, verbatim.

`InsertionPoint`, `Location`, `Module`, `RankedTensorType`, `ArrayAttr`, `DictAttr`,
`DenseResourceElementsAttr` — those are **MLIR's Python bindings**, essentially unchanged from
upstream MLIR. Core AI is a **dialect** (`coreai.*`) inside an MLIR context, `.mlirb` is serialized
MLIR bytecode, and `str(program)` gives you MLIR text you can read.

Program construction, condensed from `CoreAILowerer.lower_many`:

```python
with self.context:
    self.location = Location.unknown(self.context._mlir_context)
    with self.location:
        self.module = Module.create()
        with InsertionPoint(self.module.body):
            for entry in entries:
                graph = normalize_graph(entry.graph); graph.validate(); ensure_supported(graph)
                self.env = {}; self.inferred = infer_graph_specs(graph)
                public_inputs = self._public_inputs(graph,
                                                    public_input_names=entry.public_input_names)
                graph_op = coreai.GraphOp(name=entry.entrypoint_name,
                                          input_types=[_tensor_type(s) for s in public_inputs],
                                          result_types=[],
                                          input_names=[s.name for s in public_inputs],
                                          loc=self.location)
                with graph_op.block:
                    self._seed_inputs(graph_op, public_inputs, graph)
                    for node in graph.nodes:
                        self.env[node.output] = self._lower_node(node)
                    outputs = OrderedDict((self._coreai_output_name(graph, name), self.env[name])
                                          for name in graph.outputs)
                    graph_op.set_outputs_spec_from_dict(outputs)
                self._mark_mutable_buffers(graph_op, public_inputs, graph)
...
program = AIProgram._from_mlir_module(self.module)
if optimized: program.optimize()
```

> ✅ **VERIFIED** — `lower_to_coreai.py:441-515`.
>
> 🟡 **RECONSTRUCTED** — the `coreai.GraphOp(...)` *signature* itself. Its keyword arguments
> (`name`, `input_types`, `result_types`, `input_names`, `private`, `no_inline`, `composite_decl`,
> `loc`) are inventoried from `mlx2coreai`'s call sites only. No declaration of `GraphOp` exists
> anywhere in our corpus, and `coreai._compiler.dialects` is not documented by Apple. Treat the
> shape as right and each spelling as provisional.

**Multi-entrypoint output is real.** `build_coreai_programs([CoreAIGraphEntry(...), ...])` emits
several `coreai.GraphOp`s into one MLIR module, and the test
`test_multi_entrypoint_asset_generation` (`tests/test_lower_to_coreai_smoke.py:32-56`) asserts
`"@prefill" in str(program)` and `"@decode" in str(program)` and that a single `.aimodel` saves.
The stateful LLM converter emits **only one** (`main`) today, but the plumbing for a prefill/decode
split exists.

That matters more than it looks when a caller adopts the optional `apple/coreai-models` loader:
**recognized multi-entrypoint structures select that helper’s Neural Engine preference.** Its
`ModelStructure` classifies a single-`main` graph as `.dynamic` and requests the GPU (§10.2 quotes
the code). Direct `AIModel` callers choose their own `SpecializationOptions`, so the names are not a
Core AI framework routing contract.[^sample-routing-policy]

### 5.6 Named composites: the fused-kernel hint

For `rms_norm`, `rope`, `scaled_dot_product_attention` and a `conv_transpose` fallback, the lowerer
does something more interesting than emitting primitives: it creates a **private, no-inline
`GraphOp`** carrying a `composite_decl` attribute, and `invoke`s it from the main graph.

```python
graph_name = f"__mlx2coreai_{composite_name}_{self._private_graph_counter}_{node.output}"
composite_decl = generate_composite_decl(self.module.context, composite_name,
                                         input_names, ["output"], dict(attrs))
private = coreai.GraphOp(name=graph_name, input_types=[v.type for v in input_values],
                         result_types=[], input_names=input_names,
                         private=True, no_inline=True, composite_decl=composite_decl,
                         loc=self.location)
with private.block:
    result = body(list(private.arguments))
    private.set_outputs_spec_from_dict(OrderedDict([("output", result)]))
with self.current_graph.block:
    [out] = coreai.invoke(results=[result_type or input_values[0].type],
                          callee=graph_name, operands=input_values, loc=self.location)
```

> ✅ **VERIFIED** — `_emit_private_composite`, `lower_to_coreai.py:691-737`.

The attribute's text form comes from the vendored Apple file:

```python
def to_coreai_attr(self, context: Context) -> Attribute:
    with Location.unknown(context):
        attrs = self._dict_to_dict_attr(self.attributes, context)
    return Attribute.parse(
        f'#coreai.composite_declaration<"{self.name}" = {attrs!s}>',
        context=context,
    )
```

> ✅ **VERIFIED** — `_composite_declaration.py:131-138`. This is **Apple's own code** (BSD-3 header,
> §2.2), so the `#coreai.composite_declaration<…>` syntax is first-party, not reverse-engineered.

The composites emitted, and their declared attributes:

| composite | `input_names` | `op_attrs` |
|---|---|---|
| `rms_norm` | `["input", "scale"]` | `{"axes": [...], "eps": float}` |
| `rope` | `["input"]` (+ `"offset"`, + `"freqs"`) | `{"scale", "base", "dims", "interleaved"}` |
| `scaled_dot_product_attention` | `["query","key","value"]` (+ `"attn_mask"`) | `{"is_causal": bool, "window_size": int, ["scale": float]}` |
| `mlx_conv_transpose` | `["input_0","input_1",…]` | `{"source_op": …, "fallback": "unsupported_coreai_beta_asset_writer"}` |

Tests assert the literal MLIR text — `'composite_declaration<"rms_norm"' in str(program)`
(`test_lower_to_coreai_smoke.py:131`) and `'composite_declaration<"rope"'`
(`test_op_coverage.py:415`).

**The composite body is a real, fully-lowered implementation**, not a stub. The declaration is a
*hint* for the Core AI compiler to pattern-match a fused kernel, with the generic decomposition
available as fallback. Which makes the fourth row an important exception, covered in §7.2.

⚠️ `generate_composite_decl` **mutates the caller's dict** — it does
`op_attributes["version"] = version` (`_composite_declaration.py:194`). Harmless here, surprising
if you reuse an attrs dict.

### 5.7 Dynamic shapes need a probe, and `shapeless=True` is not enough

The docstring is the clearest statement of the problem anywhere in the repo:

> *"Replace attrs that vary with requested input axes by dynamic-dim refs.*
>
> *MLX's callback export still reports concrete primitive shapes, even with shapeless export.
> Capturing one nearby probe shape lets us identify which reshape/broadcast/range/slice attributes
> are really input dimensions."*

> ✅ **VERIFIED** — `dynamic_shapes.py:68-73`, verbatim.

The algorithm:

1. Mark the requested input axes as `-1` in the `TensorSpec`s.
2. `_validate_probe_compatibility` — base and probe graphs must have **identical node counts,
   identical ops and identical input arities**, else
   `"dynamic shape probe produced a different graph structure: N nodes vs M nodes."`
3. Build candidate triples `(base_dim, probe_dim, ref)` for each dynamic axis where the two capture
   shapes differ.
4. Walk every attr of every node in lockstep with the probe graph; any **int** attr equal to
   `base_dim` in base and `probe_dim` in probe is replaced by a `dynamic_dim_ref`.

`bool` is explicitly excluded from step 4 so `True`/`1` is not mistaken for a dimension — a nice
detail that tells you the author hit that bug.

A `dynamic_dim_ref` is:

```python
_DYNAMIC_DIM_KEY = "__mlx2coreai_dynamic_dim__"

def dynamic_dim_ref(source: str, axis: int) -> dict[str, Any]:
    return {_DYNAMIC_DIM_KEY: True, "source": str(source), "axis": int(axis)}
```

> ✅ **VERIFIED** — `ir.py:9-17`.

Two levels of "dynamic" coexist and they mean different things: **`-1` in a `TensorSpec.shape`**
means dynamic *at the type level*, and lowers to `RankedTensorType.get_dynamic_size()`; a
**`dynamic_dim_ref` inside an attr** means *"at runtime, read dim `axis` of tensor `source`"*, and
lowers to a `coreai.get_shape` + `coreai.slice_` + `coreai.cast` chain.

⚠️ **The probe requirement is a real constraint on your model.** Any shape-dependent Python
branching — an `if seq_len > 512:` in a forward pass, a different code path for the first token —
produces two structurally different traces and raises. This is the same discipline the zoo's
`PORTING.md` demands for torch (*"no data-dependent branches"*), arriving from a different
direction.

For the stateful LLM path the dynamic axes are set for you:

```python
if dynamic_sequence:
    dynamic_axes_dict[input_name] = [1]
    dynamic_axes_dict[position_ids_name] = [1]
if dynamic_state:
    dynamic_axes_dict[key_cache_name] = [3]
    dynamic_axes_dict[value_cache_name] = [3]
```

> ✅ **VERIFIED** — `_convert_mlx_lm_stateful.py:448-489`. Probe shapes genuinely perturb both axes:
> `probe_length = base + 1` if `base < max_context_length` else `base - 1`, and
> `probe_state_context_length = max_context_length + 1`.

**Consequence worth knowing:** because cache axis 3 is dynamic, the *runtime* cache size is chosen
at allocation time, **independent of the `--max-context-length` you converted with**. Both
benchmark backends exploit this by over-allocating:

```python
state_capacity = context_length + (args.steps if args.grow_context else 1)     # python
```
```swift prelude:guide-context
let stateCapacity = contextLength + (runOptions.growContext ? runOptions.steps + 1 : 1)  // swift
```

⚠️ Note the two backends differ by one (`steps` vs `steps + 1`) under `--grow-context`. Harmless
here; a reminder that these are two hand-written implementations of one contract.

---

<a name="6--asset-generation-coverage-is-not-numerical-parity"></a>

## 6. ⚠️ Asset-generation coverage is not numerical parity

This is the most important section in the guide. Everything above tells you the bridge works.
This section tells you what "works" means, and it is narrower than you want.

### 6.1 What the coverage report actually claims

`mlx2coreai` ships an op-coverage report at `docs/op_coverage.md`, regenerable with
`mlx2coreai ops`. Its header, verbatim:

```
# mlx2coreai Op Coverage

Coverage type: CoreAI asset generation. This does not imply runtime numerical parity.

## Summary

- Supported source op names in registry: 156
- Distinct lowering keys in registry: 121
- Coverage modules: `tests.model_zoo, tests.coverage_zoo`
- Coverage graphs: 26
- Coverage graph nodes: 252
- Unique source ops exercised: 156
- Unique lowering keys exercised: 121
- Asset validation: passed
```

and its notes section, also verbatim:

> - *Coverage is asset-generation coverage, not runtime numerical parity.*
> - *Runtime parity requires the macOS / iOS 27+ CoreAI execution stack.*
> - *General transposed convolution uses a named composite fallback when the beta CoreAI asset
>   writer rejects native conv_transpose IR; the vendored 1x1 stride-1 case lowers without that
>   fallback.*

> ✅ **VERIFIED** — `docs/op_coverage.md:1-14` and `:212-216`, quoted exactly.

**"Asset validation: passed" means one thing:**

```python
lowered = lower_graph_to_coreai(spec.graph, config=ConversionConfig(optimize=False))
lowered.program.save_asset(...)
assert (asset_path / "main.mlirb").exists()
```

> ✅ **VERIFIED** — `op_coverage.py:155-163`. It is a **file-existence check**. Not an execution.
> Not a comparison. The asset was written; that is the entire claim.

To be fair to the project: the report says so, in its first line, in the summary, and again in the
notes. The failure mode is not that the author overclaims — it is that **156/156 op coverage reads
like a completeness statement** and a reader in a hurry will treat it as one.

### 6.2 What *is* tested, and what is not

| Layer | Tested in-repo? | How |
|---|---|---|
| Graph capture from live MLX | ✅ yes | two live captures in `test_op_coverage.py` — a toy transformer block, and `mx.fast.rms_norm` / `mx.fast.rope` |
| IR normalization + shape inference | ✅ yes | `passes.py` exercised by 26 zoo graphs |
| MLIR emission | ✅ yes | tests assert literal MLIR text, e.g. `"tensor<1x?xsi32>"`, `"tensor<1x1x4x64xf32>"`, `'composite_declaration<"rms_norm"'` |
| `.aimodel` writes to disk | ✅ yes | children pinned as `["main.hash","main.mlirb","metadata.json"]` |
| Bundle `metadata.json` contract | ✅ yes | `test_convert_mlx_lm.py:196-257` asserts every field |
| **Numeric agreement, converted vs MLX** | 🔴 **no** | — |
| **Execution of any asset on a device** | 🔴 **no** | — |
| **The stateful KV-cache path end to end** | 🔴 **no** | the packaged library cannot even run it (§8.1) |

> ✅ **VERIFIED** — test inventory read from `tests/`. The `run_aimodel` path is tested only against
> **fake `AIModelAsset` / `NDArray` / `StorageKind` doubles** in `test_runtime.py` — which is
> useful for pinning the protocol shape, and proves nothing about the runtime.

The repo *does* ship a numeric comparison helper, and it *does* carry tolerances:

```python
compare_coreai_outputs(actual, expected, *, rtol=1e-4, atol=1e-4, match_by_order=True)
    -> list[CoreAIOutputComparison]
```

with `ZooModelSpec` default tolerances `atol=2e-3, rtol=5e-3`, relaxed to `atol=5e-2, rtol=1e-2`
for the transformer block. But those tolerances are applied against **MLX-computed reference
outputs from the same capture**, not against a Core AI execution — because there is no Core AI to
execute against in CI.

⚠️ `match_by_order=True` is the default, which means a runtime output named `out_0` will be
compared against a captured output named `attn` **purely positionally**. If your graph's output
order shifts, you get a green comparison of the wrong pair.

### 6.3 The parity-testing recipe

Do not skip this. Run it before you trust a converted model, and run it again after every wheel
bump, OS beta and `--no-optimize` toggle.

**The principle**, borrowed from the community zoo's `PORTING.md` and stated better there than
anywhere else:

> *"Per-step matters: an AR loop can look fine at step 1 and drift by step 30."*

and its pass bar for autoregressive models:

> *"per-token cosine ≥ 0.999 on logits **AND** greedy argmax token-exact over the oracle's decode
> steps. Token-exact is the headline; per-token cosine tells you where it broke when it isn't."*

> ✅ **VERIFIED** — `PORTING.md:86-109` and `:184-211`. **Community-sourced**
> (john-rocky/coreai-model-zoo), not Apple guidance. Reproduced here because it is the only
> written-down gate for this failure class and because it is right.

**Step 1 — capture the oracle from the MLX original.** Fixed prompt, greedy sampling, no
temperature, no top-k, no seed dependence.

```python
# oracle_mlx.py
import json
import mlx.core as mx
import numpy as np
from mlx_lm import load

MODEL_ID = "mlx-community/Qwen3-0.6B-bf16"
PROMPT = "The capital of France is"
STEPS = 64

model, tokenizer = load(MODEL_ID)
prompt_ids = tokenizer.encode(PROMPT)

ids = list(prompt_ids)
records = []
cache = None
try:
    from mlx_lm.models.cache import make_prompt_cache
    cache = make_prompt_cache(model)
except Exception:
    cache = None

for step in range(STEPS):
    # Feed the whole sequence when there is no cache; feed one token when there is.
    feed = ids if cache is None else ids[-1:] if step else ids
    logits = model(mx.array([feed]), cache=cache) if cache is not None \
             else model(mx.array([feed]))
    if isinstance(logits, (tuple, list)):
        logits = logits[0]
    last = np.asarray(logits.astype(mx.float32))[0, -1, :]
    nxt = int(np.argmax(last))
    records.append({"step": step, "token": nxt,
                    "top5": np.argsort(last)[-5:][::-1].tolist()})
    np.save(f"oracle_logits_{step:03d}.npy", last)
    ids.append(nxt)

json.dump({"model": MODEL_ID, "prompt": PROMPT,
           "prompt_ids": prompt_ids, "records": records},
          open("oracle.json", "w"), indent=2)
print("oracle tokens:", [r["token"] for r in records])
print(tokenizer.decode([r["token"] for r in records]))
```

> 🟡 **RECONSTRUCTED** — this script is assembled from verified pieces (`mlx_lm.load` signature,
> the cache protocol, greedy argmax) but it is **not** copied from any repo. The `make_prompt_cache`
> import path in particular is mlx-lm's and is version-sensitive; see
> [Part 12 guide 04](../../part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md)
> for the current spelling. Treat the *structure* as the recipe and check the mlx-lm calls against
> your installed version.

**Step 2 — convert.**

```bash
mlx2coreai convert-mlx-lm-stateful mlx-community/Qwen3-0.6B-bf16 \
  --output qwen \
  --max-context-length 512
```

**Step 3 — replay the same prompt through the converted asset, greedily.** The only place in the
repo that shows how to drive a *stateful* Core AI function from Python is the benchmark script, and
this is its call shape:

```python
async def run_main(function, NDArray, token_ids, position_ids, state, *,
                   input_name, position_ids_name):
    return await function(
        inputs={
            input_name: NDArray(np.asarray(token_ids, dtype=np.int32)[None, :]),
            position_ids_name: NDArray(np.asarray(position_ids, dtype=np.int32)[None, :]),
        },
        state=state,
    )


def allocate_state(function, NDArray, *, state_capacity: int) -> dict[str, Any]:
    state = {}
    for name in function.desc.state_names:
        descriptor = function.desc.state_descriptor(name=name)
        shape = tuple(int(state_capacity) if int(dim) < 0 else int(dim)
                      for dim in descriptor.shape)
        state[name] = NDArray(np.zeros(shape, dtype=_runtime_dtype_to_numpy(descriptor.dtype)))
    return state
```

> ✅ **VERIFIED** — `scripts/benchmark_aimodel_sampling.py:214-239`, verbatim. The Python runtime
> surface it reveals: `AIModelAsset.load(path)` → `async with asset.executable() as model` →
> `model.load_function(name)` → `function.desc.{state_names, output_names,
> state_descriptor(name=)}` → `await function(inputs=…, state=…)` → dict of `NDArray` with
> `.numpy()`.
>
> 🔴 **GAP — whether `function(inputs=, state=)` mutates the passed `NDArray`s in place or returns
> new state is not observable from this repo.** The benchmark reuses the same `state` dict across
> steps, which *implies* in-place mutation, but the API contract is unstated. **SAFE DEFAULT:**
> assume in-place, never reuse a state dict across two different sequences without reallocating,
> and call `reset`-equivalent by rebuilding the dict.

Wire it into a comparison loop:

```python
# parity_coreai.py  (sketch — see the GAP note above before trusting the runtime calls)
import asyncio, json
import numpy as np

oracle = json.load(open("oracle.json"))
prompt_ids = oracle["prompt_ids"]
expected = [r["token"] for r in oracle["records"]]

async def main():
    from coreai.authoring import AIModelAsset
    from coreai.runtime import NDArray

    asset = AIModelAsset.load("qwen/qwen.aimodel")
    async with asset.executable() as model:
        fn = model.load_function("main")
        state = allocate_state(fn, NDArray, state_capacity=512)

        ids = list(prompt_ids)
        got = []
        for step in range(len(expected)):
            feed = ids if step == 0 else ids[-1:]
            positions = list(range(len(ids)))          # FULL prefix — see §3.5
            out = await run_main(fn, NDArray, feed, positions, state,
                                 input_name="input_ids",
                                 position_ids_name="position_ids")
            logits = next(iter(out.values())).numpy()
            last = logits[0, -1, :].astype(np.float32)

            ref = np.load(f"oracle_logits_{step:03d}.npy")
            cos = float(ref @ last / (np.linalg.norm(ref) * np.linalg.norm(last)))
            tok = int(np.argmax(last))
            got.append(tok)

            status = "OK " if tok == expected[step] else "MISMATCH"
            print(f"step {step:3d}  cos={cos:.6f}  got={tok:<7d} want={expected[step]:<7d} {status}")
            if tok != expected[step]:
                print(f"FAIL: first divergence at step {step}")
                break
            ids.append(tok)

        print("token-exact" if got == expected else "NOT token-exact")

asyncio.run(main())
```

> 🟡 **RECONSTRUCTED** — the loop structure is mine; the two helper functions it calls and the
> `AIModelAsset.load` / `executable()` / `load_function` / `await function(inputs=, state=)` chain
> are ✅ verified from the benchmark script. `AIModelAsset` is imported from `coreai.authoring` and
> the runtime types from `coreai.runtime` — ✅ verified in `runtime.py:_load_coreai_runtime`, which
> also gives you the error you get when the runtime is missing:
> `"coreai.runtime is not available. Install coreai-core with runtime support and run on a
> CoreAI-capable macOS/iOS runtime."`

**Step 4 — read the result correctly.**

| Outcome | Meaning | Action |
|---|---|---|
| Token-exact for all N steps, cos ≥ 0.999 | The conversion is numerically sound *for this prompt* | Widen: more prompts, longer rollouts, edge cases |
| Token-exact but cos dips to ~0.99 | Precision drift that has not yet crossed an argmax boundary | It **will** cross on a different prompt. Investigate §7 |
| Diverges at step 1 | A structural bug — wrong signature, wrong `position_ids`, wrong dtype view | §3.5, §3.6 |
| Diverges at step ~20–40 | **The classic KV/offset/mask bug.** Nothing is wrong with the first forward pass | §3.5, §7.1, §7.4 |
| cos ≈ 1.0 but text is garbage | You are reading logits with the wrong element type | §3.6 (`--cast-bf16-logits-to-fp16`) |

**Step 5 — do it on the device you ship to.** From the zoo, community-measured and worth repeating
verbatim because it is the one mistake in that document that *"costs a reboot instead of an
afternoon"*:

> ⚠️ **"Never execute an iOS-compiled bundle on a Mac. It can wedge the GPU/ANE stack and take the
> whole machine down (watchdog reboot). Mac bundles on Mac, iOS bundles on device."**

> ✅ **VERIFIED** — `PORTING.md:250-252`, quoted verbatim. Community-sourced.

### 6.4 Why a parity test is not optional here specifically

For a PyTorch → Core AI export, the failure surface is Apple's own converter, which is tested by
Apple, and the zoo has catalogued its sharp edges (§11.4). For an MLX → Core AI conversion the
failure surface is **a 2,072-line hand-written MLIR emitter with no runtime test in its own CI**,
lowering ops whose semantics were reconstructed from MLX primitive `state()` tuples.

§7 lists eight specific places where that reconstruction is known to be lossy. Each one produces a
**converting asset**. Several produce a *plausible* output. That combination — converts, runs,
plausibly wrong — is exactly what the zoo's `AGENTS.md` calls the most expensive failure mode:

> *"An agent that reaches for a one-shot converter produces a bundle that loads, runs, and emits
> plausible garbage — the most expensive failure mode here, because it looks like success."*

> ✅ **VERIFIED** — `AGENTS.md:13-17`, quoted verbatim. Community-sourced, and written about
> converters in general rather than about `mlx2coreai` specifically.

---

## 7. The specific numeric hazards to test for

§6 told you to run a parity test. This section tells you what it is going to catch. Every item here
was read from source, and every one of them **produces an asset that saves successfully**.

### 7.1 ⚠️ SILENT FAILURE: boolean attention masks are *added*, not selected

The SDPA lowering body:

```python
def body(args):
    bq, bk, bv = args[:3]
    bm = args[3] if len(args) > 3 else None
    if _rank(bq) >= 4 and _rank(bk) >= 4:
        target_heads = int(bq.type.shape[1])
        bk = _repeat_attention_heads(bk, target_heads)     # GQA expansion
        bv = _repeat_attention_heads(bv, target_heads)
    head_dim = int(bq.type.shape[-1])
    effective_scale = scale_f if scale_f is not None else 1.0 / math.sqrt(float(head_dim))
    scaled_q = _bmul(bq, effective_scale)
    kt = coreai.transpose(bk, np.asarray([0, 1, 3, 2], dtype=np.uint32))
    scores = coreai.broadcasting_batch_matmul(scaled_q, kt)
    if bm is not None:
        scores = _badd(scores, coreai.cast(bm, scores.type.element_type))
    if is_causal:
        scores = _badd(scores, _causal_mask_like(scores))
    weights = coreai.softmax(scores, _rank(scores) - 1)
    return coreai.broadcasting_batch_matmul(weights, bv)
```

> ✅ **VERIFIED** — `_lower_sdpa`, `lower_to_coreai.py:1301-1345`.

Look at the mask line: `scores = scores + cast(mask, score_dtype)`.

If you hand MLX a **boolean** mask where `True` means "attend here" — the ordinary convention — the
cast produces `1.0` for kept positions and `0.0` for masked ones, and adding it **increases** the
score of every visible position by exactly 1.0 while leaving masked positions completely
unmasked. Attention still runs. Softmax still normalises. The output is wrong in a way that is
smooth and prompt-dependent.

**Only additive float masks are correct.** The repo's own test fixture uses one:
`np.triu(np.full((1, 1, seqlen, seqlen), -1e9, np.float32), 1)`.

Worse: `canonicalize_sdpa_masks` in `passes.py` **computes a `mask_mode` attribute** — with values
`none` / `causal_plus_explicit` / `auto` / `bool` / `additive` — that would let the lowering do the
right thing, and **the lowering never reads it**. The analysis exists; the consumer does not.

> ✅ **VERIFIED** — `passes.py` (the pass), `lower_to_coreai.py` (grep for `mask_mode` in the
> lowering finds nothing).

**What to do:** convert your attention with an explicit additive float mask, or with
`do_causal=True` and no mask at all. Never with a bool mask. And gate it — a per-token cosine test
catches this immediately because the corruption is uniform across positions.

### 7.2 ⚠️ SILENT FAILURE: general transposed convolution lowers to **zeros**

```
| composite name       | op_attrs                                                          |
| mlx_conv_transpose   | {"source_op": …, "fallback": "unsupported_coreai_beta_asset_writer"} |
```

Unlike the other three composites, whose bodies are real implementations, this one's body is
literally `coreai.constant(np.zeros(spec.shape))`.

> ✅ **VERIFIED** — `lower_to_coreai.py`. The asset saves. The output is a zero tensor. The op
> coverage report counts it as covered.

Only the **1×1, stride-1, dilation-1, groups-1, no-padding** case gets a real lowering
(`_lower_pointwise_conv_transpose`, `lower_to_coreai.py:1667-1694` — a reshape→matmul→transpose).
Everything else is the zero placeholder.

**Detection is easy and you should automate it.** The composite is tagged, so one assertion on
the MLIR text catches it before the asset ever leaves your machine:

```python
from mlx2coreai import ConversionConfig, convert_mlx_to_coreai

converted = convert_mlx_to_coreai(model, inputs, config=ConversionConfig(optimize=False))
text = str(converted.program)
assert "unsupported_coreai_beta_asset_writer" not in text, (
    "graph contains a zero-filled conv_transpose placeholder"
)
```

> 🟡 **RECONSTRUCTED** — the grep string `"unsupported_coreai_beta_asset_writer"` is ✅ verified as
> the literal tag in the composite's `op_attrs`; wrapping it in an assertion is a suggestion.
> `str(program)` yielding MLIR text is ✅ verified (tests do exactly this).

### 7.3 ⚠️ SILENT FAILURE: `mx.log2` and `mx.log10` become natural log

MLX remaps `Log2` and `Log10` to the primitive name **`Log`** and carries the base in `state()`
(`Log::Base { two=0, ten=1, e=2 }`, `mlx/primitives.h:1316-1345`).
`_primitive_attrs_from_arguments` in `from_mlx.py` has **no `log` branch**, so the base is dropped
and the lowering emits `coreai.log`.

The registry *does* have `log2` and `log10` entries — synthesized as
`log(x) / math.log(2.0)` and `log(x) / math.log(10.0)` — but they only fire for hand-written IR or
the DOT path. Through the callback capture, which is the default and the only tested path, they are
unreachable.

> ✅ **VERIFIED** — MLX `name_remap` at `export.cpp:381`; `from_mlx.py` attribute table;
> `lower_to_coreai.py:1985-2048` dispatch tables. **Not covered by any test in the repo.** Worth an
> actual repro if your model uses log2/log10.

Same shape of bug for shifts: **`mx.left_shift` / `mx.right_shift` silently become bitwise AND.**
MLX remaps all five bitwise ops to `BitwiseBinary` with `Op { And=0, Or=1, Xor=2, LeftShift=3,
RightShift=4 }`, and `_lower_bitwise_binary` maps `{0:"and", 1:"or", 2:"xor"}` and **defaults
everything else to `"and"`** (`lower_to_coreai.py:989-1000`).

### 7.4 The numerics that are *approximately* right

These will not ruin your model but they will show up as cosine drift, and you should know which
line to blame.

| Behaviour | Where | Consequence |
|---|---|---|
| Causal mask uses **`-1e4`**, not `-inf` or `-1e9` | `_causal_mask_like`, `lower_to_coreai.py:1740-1770` | Fine in fp16. In **fp32** it leaves a small non-zero attention weight on masked positions |
| `reduce_log_sum_exp` = `log(reduce_sum(exp(x)))` with **no max subtraction** | `_REDUCE_OPS` | fp16 overflow hazard on any real logit range |
| `inverse` lowers to `1.0 / (x + eps)` | `lower_to_coreai.py:767-771` | a deliberate eps that is not in the source op |
| `negative` lowers to `mul(x, -1.0)` | `:786` | harmless; Core AI has no `negative` |
| `less` / `less_equal` / `greater_equal` synthesized from `greater` + `equal` + `or` | `_BINARY_OPS` | harmless; Core AI has no such primitives |
| **Asymmetric conv padding is summed and re-split evenly** | `from_mlx.py:275-280` | genuinely lossy: `(lo, hi)` → one per-axis total → symmetric halves |
| `fp64 → fp32` and `int64 → int32` forced everywhere | `_element_type`, `_array_to_coreai` | int64 constants outside int32 range **hard fail** with `"int64 constant cannot be safely downcast to int32."` |
| `Softmax::state()` carries **only `precise_`**, no axis | `mlx/primitives.h:2171-2173` | so `axis = -1` is assumed for every captured softmax. Correct for MLX; a trap for hand-written IR |

> ✅ **VERIFIED** — all rows read from the sources cited. The int64 narrowing carries its own
> comment: *"CoreAI can represent si64 in MLIR, but the runtime stack is generally <=32-bit
> oriented."*

Note the dtype promotion rank: `{"bool":0, "int32":1, "int64":2, "fp16":3, "bf16":4, "fp32":5,
"fp64":6}` — **bf16 ranks above fp16**, so mixing the two promotes to bf16, not to fp32.

### 7.5 The ops that simply refuse

Some things raise instead of silently degrading, which is the better failure. Know them so you can
recognise the message:

- **`mx.argmax` / `mx.argmin` through the callback path.** MLX emits the primitive name
  `ArgReduce` with no remap alias, which normalizes to `"argreduce"` — absent from
  `SUPPORTED_MLX_TO_COREAI_OPS`. Expect `UnsupportedOpsError`. *(Inferred from MLX's `name_remap`
  plus the registry table; not covered by any test.)*
- **`split`, `var`/`std` with `ddof`, `tensordot`, `kron`, `meshgrid`, `diag`/`diagonal`/`trace`,
  `array_equal`, and the triangular ops** all call `_static_shape()` and therefore **raise on
  dynamic dimensions**: `ValueError(f"Expected static shape, got {shape}.")`. This is the single
  most common reason a model that converts statically fails with `--dynamic-sequence`.
- **`gather` with `slice_shape`** requires a **unit slice on the gathered axis** and **full slices
  on all other axes**, otherwise it raises.
- **Static `slice_update`** materializes one index row per updated element into a baked constant
  (`np.ndindex(*update_shape)` → an `(N, rank)` int32 constant → `coreai.scatter_nd`). That is
  O(update-size) *conversion time* and O(update-size) asset bloat. It does not fail; it just gets
  very slow and very large. Avoid for big in-place updates.

`UnsupportedOpsError` carries `.first_op`, `.all_ops` and `.details`, and its message is a small
backlog report:

```
Unsupported MLX op encountered first: <op>
All unsupported ops: a, b, c
Recommendations:
- <op> (count=N, source=mlx_export:12:Foo, primitive=Foo) -> backlog status <status>; <recommendation>
  sample: output=..., inputs=[...], attrs={...}
Add mappings/lowerings in mlx2coreai/op_registry.py and mlx2coreai/lower_to_coreai.py.
```

> ✅ **VERIFIED** — `op_registry.py:345-374`. The `<status>` will always be `unlisted` because
> `docs/ops_status.md` does not exist (§2.4). Ignore that field; the rest of the message is
> genuinely actionable — it names the MLX primitive, the source line, and a sample node.

### 7.6 One historical claim you should *not* repeat

There is a caveat circulating that **"MLX BF16 constants are widened to FP32 during capture, so
expect small full-model logit drift."** That was in the README at commit `5e9c7de`. It was
superseded at `948a3bd` by *"BF16 MLX constants are preserved as BF16 weights when `ml_dtypes` is
available"*, and the whole Caveats section was deleted at `d032a95`.

At HEAD the code path preserves bf16: `_element_type("bf16")` → `BF16Type`, and
`_np_dtype_for_ir("bf16")` → `ml_dtypes.bfloat16`.

> ✅ **VERIFIED** — README history via `git show 5e9c7de:README.md` / `git show 948a3bd:README.md`,
> and the current `lower_to_coreai.py`. **Treat any "bf16 is widened" claim about this bridge as
> stale.** The residual truth in it: *"Some scalar literals and normalization constants may still
> be emitted in a higher precision when the CoreAI type system requires it."*

### 7.7 A dead hook that tells you something about the beta

`_optimization_skip_reason(graph)` at `lower_to_coreai.py:2067` unconditionally returns `None`
today. Commit `5e9c7de` ("Allow optimization on SDPA for macOS 27") deleted this body:

```python
    has_dynamic_input = any(any(int(dim) < 0 for dim in spec.shape) for spec in graph.inputs)
    if not has_dynamic_input:
        return None
    for node in graph.nodes:
        if node.op == "scaled_dot_product_attention" and bool(node.attrs.get("do_causal", ...)):
            return "coreai_optimize_dynamic_causal_sdpa_reshape_bug"
```

and the README caveat it enforced said:

> *"Dynamic causal `scaled_dot_product_attention` graphs currently skip `AIProgram.optimize()`
> because the beta optimizer rewrites the causal mask into an invalid runtime reshape for dynamic
> sequence shapes."*

> ✅ **VERIFIED** — `git show 5e9c7de`.

That is a **Core AI beta optimizer bug that was fixed between betas**, and the workaround was
removed one commit before HEAD. Two lessons: (a) `AIProgram.optimize()` is not a safe no-op on this
stack — see also the `AIProgram.optimize()` silent-axis-deletion class of defect covered in
[Part 8](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/README.md); (b) the dead hook remains, so if a future beta
regresses, re-adding a skip rule is a one-liner. If your dynamic causal SDPA model produces wrong
output, `--no-optimize` is the first thing to try.

---

## 8. The Swift runner, and what "Python bindings are incomplete" means

The most recent commit in `mlx2coreai` is:

```
059c9f3 Add a swift runner as python bindings are incomplete as of now.   (Tue Jun 9 06:43:06 2026 -0700)
```

> ✅ **VERIFIED** — `git log --oneline -50`, commit message verbatim.

That one sentence is a data point about the maturity of Core AI's **Python** runtime, and it is
worth unpacking because the commit does not say *which* bindings, and the answer is inferable from
the diff.

### 8.1 The library cannot run the assets it produces

Start with the most concrete fact. `mlx2coreai`'s own public runtime helper:

```python
async with asset.executable(specialization_options=specialization_options) as ai_model:
    function = ai_model.load_function(function_name)
    raw_outputs = await function(inputs=nd_inputs)
```

> ✅ **VERIFIED** — `runtime.py:67-98`. **There is no `state=` argument.**

So `mlx2coreai.run_aimodel` — the packaged, exported, `__all__`-listed API — **cannot execute the
stateful KV-cache asset that `convert-mlx-lm-stateful` produces.** Only
`scripts/benchmark_aimodel_sampling.py` can, by calling the raw `function` object with `state=`
directly (§6.3).

For a *stateless* asset it works fine:

```python
from mlx2coreai import run_aimodel_sync

result = run_aimodel_sync("model.aimodel", {"x": np.ones((2, 3), np.float32)})
```

> 🟡 **RECONSTRUCTED — read this before you copy it.** ✅ Verified: `run_aimodel`,
> `run_aimodel_sync`, and `CoreAIRuntimeOutputs` are all in `__all__`; the function body computes
> `outputs = {str(name): _output_to_numpy(value) for name, value in raw_outputs.items()}` and
> `NDArray` outputs are converted with `.numpy()`. 🟡 Inferred: that the **return value is a
> `CoreAIRuntimeOutputs` carrying a `.outputs` mapping**. Our source notes record the local variable
> and the exported type name but not the `return` statement, so the attribute spelling is not
> confirmed.
>
> **SAFE DEFAULT:** do not hard-code `result.outputs`. Write
> `outputs = getattr(result, "outputs", result)` and move on; it costs one line and survives either
> shape.

Two more Python-side constraints, both ✅ verified:

- **Sync helpers refuse to run inside an event loop:**
  `RuntimeError("Cannot use a sync CoreAI runtime helper from a running event loop; await the
  async helper instead.")` (`_run_sync`, `runtime.py:547-556`).
- **The runtime import is guarded**, and the error text tells you exactly what is missing:
  `"coreai.runtime is not available. Install coreai-core with runtime support and run on a
  CoreAI-capable macOS/iOS runtime."` — note the phrase *"with runtime support"*, implying the
  wheel can be installed *without* it.

### 8.2 The Swift counterpart, and the API delta

`scripts/benchmark_aimodel_sampling_coreai.swift` (351 lines) uses the **Swift `CoreAI` framework**
directly:

```swift illustrative
import CoreAI
import Darwin
import Foundation

@main
struct CoreAIBenchmarkBackend {
    static func main() async { ... }

    static func run() async throws {
        var options = SpecializationOptions(preferredComputeUnitKind: .gpu)
        options.expectFrequentReshapes = false
        let model = try await AIModel(contentsOf: modelURL, options: options)
        guard let descriptor = model.functionDescriptor(for: runOptions.functionName) else { ... }
        guard let function = try model.loadFunction(named: runOptions.functionName) else { ... }
        guard descriptor.inputNames.count == 2 else { ... }
        guard descriptor.stateNames.count == 2 else { ... }
        guard let outputName = runOptions.outputName ?? descriptor.outputNames.first else { ... }

        let keyName = descriptor.stateNames[0]
        let valueName = descriptor.stateNames[1]
        let inputDesc  = try ndArrayDescriptor(descriptor.inputDescriptor(of: inputName),  name: inputName)
        let keyDesc    = try ndArrayDescriptor(descriptor.stateDescriptor(of: keyName),    name: keyName)
        let logitsDesc = try ndArrayDescriptor(descriptor.outputDescriptor(of: outputName), name: outputName)
        let vocabSize  = logitsDesc.shape.last ?? 0
        ...
    }
}
```

and the per-step call:

```swift prelude:guide-context
var inputIds = NDArray(descriptor: inputDesc.resolvingDynamicDimensions([1, tokens.count]))
fillInt32(&inputIds, values: tokens)

var positionIds = NDArray(descriptor: positionDesc.resolvingDynamicDimensions([1, totalPositions]))
fillInt32(&positionIds, values: (0..<totalPositions).map { Int32($0) })

var logits = NDArray(descriptor: logitsDesc.resolvingDynamicDimensions([1, tokens.count, vocabSize]))

var states = InferenceFunction.MutableViews()
states.insert(&keyCache, for: keyName)
states.insert(&valueCache, for: valueName)

var outputs = InferenceFunction.MutableViews()
outputs.insert(&logits, for: outputName)

_ = try await function.run(
    inputs: [inputName: inputIds, positionName: positionIds],
    states: consume states,
    outputViews: consume outputs
)
```

> ✅ **VERIFIED** — `benchmark_aimodel_sampling_coreai.swift`, verbatim. This is one of very few
> concrete third-party samples of `InferenceFunction.MutableViews` /
> `NDArrayDescriptor.resolvingDynamicDimensions` usage in existence. For the semantics of
> `consume`, `MutableViews` and pre-allocated `outputViews:`, see
> [Part 7 guide 03 §5 and §9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/03-states-and-pipelined-execution.md).

**The delta, item by item — this is the answer to "which bindings are incomplete".**

| # | Swift has | Python has | Consequence |
|---|---|---|---|
| 1 | `outputViews:` — preallocate `logits`, runtime writes straight into it | only `raw_outputs = await function(inputs=…, state=…)` returning **fresh** `NDArray`s, then `.numpy()` copies | for a 0.6 B model with a large vocab that is a fresh multi-hundred-KB allocation **plus a copy** per decode step — exactly what wrecks a decode-throughput benchmark |
| 2 | `InferenceFunction.MutableViews` + `consume` (Swift ownership), guaranteeing zero-copy in-place KV mutation | a plain `dict[str, NDArray]` passed as `state=` | nothing in the binding expresses the aliasing/ownership contract — hence the GAP in §6.3 about whether mutation is in place |
| 3 | `SpecializationOptions(preferredComputeUnitKind: .gpu)` and `expectFrequentReshapes` set explicitly | bare `asset.executable()` with **no options** | commit `dab7096` had wired `SpecializationOptions` and `ComputeUnitKind` into `runtime.py` and given the benchmark `--compute-unit {auto,default,cpu,cpu-preferred,gpu,neural-engine}` and `--debug-specialization`; commit `d032a95` **removed both flags**. So compute-unit selection on the Python side is either gone or non-functional at this beta |
| 4 | `descriptor.resolvingDynamicDimensions(_:)` plus per-role descriptor accessors; arity validated up front | `function.desc.state_names` / `state_descriptor(name=)` / `output_names`, and the script must hand-substitute negative dims itself | weaker introspection; you write the `-1 → capacity` loop yourself |
| 5 | — | `run_aimodel` has **no `state=` at all** | the supported public Python API cannot execute a stateful asset (§8.1) |

> ✅ **VERIFIED** — items 1, 2, 4, 5 by direct comparison of the two backends; item 3 by
> `git show dab7096` and `git show --stat d032a95`.

**The honest reading:** Core AI's Python runtime at `1.0.0b1` is a *conversion and smoke-test*
surface, not an inference surface. It can load an asset and call a stateless function. It cannot
express pre-allocated outputs, cannot express mutable-state ownership, and lost its
specialization-option plumbing between two commits. If you need to measure or ship, you are on
Swift. This is not a criticism of the bridge; it is a fact about the beta that the bridge
discovered and worked around, and the commit message is the artifact.

### 8.3 The build recipe, and the auto-selection trap

Building the Swift runner is a single `swiftc` invocation, and it is copyable:

```bash
xcrun swiftc \
  -parse-as-library \
  -sdk "$SDKROOT" \
  -target arm64-apple-macos27.0 \
  -framework CoreAI \
  scripts/benchmark_aimodel_sampling_coreai.swift \
  -o .build/coreai_stateful_benchmark
```

> ✅ **VERIFIED** — `ensure_swift_backend`, `benchmark_aimodel_sampling.py:461-500`. SDK discovery
> tries `$SDKROOT`, then
> `/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk`,
> validated by the existence of `System/Library/Frameworks/CoreAI.framework`. If nothing is found:
> `RuntimeError("Could not find a macOS 27 SDK with CoreAI.framework. Set SDKROOT or install Xcode
> beta at /Applications/Xcode-beta.app.")` Rebuild is mtime-based.

The benchmark itself:

```bash
python scripts/benchmark_aimodel_sampling.py qwen \
  --contexts 16,32,64,128,256 \
  --steps 16 \
  --decode
```

> ✅ **VERIFIED** — `README.md:30-35`.

⚠️ **SILENT BACKEND SWAP.** `--runtime-backend {auto,python,swift}` exists but its help is
`argparse.SUPPRESS`-hidden, and `auto` picks **Swift** whenever `platform.system() == "Darwin"`
**and** an SDK with `CoreAI.framework` is found **and** none of the Python-only options are used.
The Swift backend explicitly rejects:

```python
def unsupported_swift_backend_options(args) -> list[str]:
    unsupported = []
    if args.prompt is not None:    unsupported.append("--prompt")
    if args.model_id is not None:  unsupported.append("--model-id")
    if args.revision is not None:  unsupported.append("--revision")
    if args.decode:                unsupported.append("--decode")
    if args.json_output is not None: unsupported.append("--json-output")
    if float(args.temperature) != 0.0: unsupported.append("--temperature != 0")
    return unsupported
```

with *"Swift CoreAI backend currently supports synthetic greedy benchmarking only; unsupported
options: …"*.

Read that list against the README command above: **`--decode` is on it.** So the documented
invocation silently keeps you on the **Python** backend — the slower one, the one without
`outputViews:`, the one whose numbers are dominated by allocation. Two people running "the
benchmark from the README" and "the benchmark" get different backends and neither is told.

> ✅ **VERIFIED** — `benchmark_aimodel_sampling.py:394-420` and the rejection function, verbatim.

**If you are benchmarking:** pass `--runtime-backend swift` explicitly and accept synthetic greedy
decoding, or pass `--runtime-backend python` explicitly and know that you are measuring the Python
binding's allocation overhead as much as the model. Do not let `auto` choose. And record which one
you used next to the number — see §11.3 on why unattributed numbers are worthless.

Both backends print the same table, which at least makes them comparable once you know which ran:

```
 context  steps  elapsed_s      tok/s     output     pos0     pos1
-------- ------ ---------- ---------- ---------- -------- --------
```

---

## 9. `swift-lm`: a real third-party Core AI integration

`1amageek/swift-lm` is a different kind of bridge and a different kind of artifact. `mlx2coreai` is
worth reading for its *converter*; `swift-lm` is worth reading for its *consumer* — it is one of the
very few third-party Swift packages that exercises the Core AI runtime seriously, including the
brand-new **vision language model** path.

**HEAD:** `db7a802 Add Core AI vision language model adapter` (2026-07-18), version line
`0.11.0-alpha.1` (Swift) / `swiftlm-coreai 0.11.0a1` (Python).

### 9.1 The design philosophy, and why it produces readable code

`PHILOSOPHY.md` is written in Japanese and enumerates ten convictions. Four of them explain the
shape of everything below:

1. **"swift-lm はコンパイラである"** — *swift-lm is a compiler.* PyTorch, MLX and llama.cpp are
   *interpreters*; swift-lm compiles a Hugging Face bundle. The justification is a measurement:
   *"Apple Silicon の実測値で、decode の GPU 時間の **~85% が barrier 同期** に消える"* — ~85 % of
   decode GPU time goes to barrier synchronisation, so the only real lever is reducing dispatch
   count through static analysis and fusion. *(Author-measured; no hardware or date given —
   attribute as an uncontrolled community claim.)*
2. **"モデルはコードではなくデータである"** — *a model is data, not code.* The consumer supplies
   **one Hugging Face repo id**; `config.json` + `safetensors` + `tokenizer.json` is the canonical
   input. An expressive model DSL was *deliberately given up* in exchange for distributability.
3. **"Fragment は自己記述的である。Compiler は無知である"** — *fragments are self-describing; the
   compiler is ignorant.* The compiler never writes `if fragment is XxxFragment`; adding a fragment
   must not change one line of compiler code. *"compiler が `if fragment is XxxFragment` と書いたら
   負け"* — if the compiler writes that, we lose.
4. **"Silent Fallback は禁止する"** — *silent fallback is forbidden.* An `OperationAttributes`
   without a `MetalCompilable` conformance is a `fatalError`; no `try?`; **missing required config
   fields are errors, never defaulted.**

> ✅ **VERIFIED** — `PHILOSOPHY.md:7-20`, `:22-32`, `:48-67`, `:101-118`, quoted from source with
> translation gloss.

And the one that matters most for anyone gating a port:

5. **"HuggingFace が唯一の正である"** — *Hugging Face is the only ground truth.* Correctness is
   established **only** against HF `modeling_*.py` intermediate values. Internal comparison is not
   proof: *"全層が壊れている場合、内部比較は壊れたものと壊れたものを比較して合格判定を出してしまう"*
   — if every layer is broken, an internal comparison compares broken against broken and passes.

That is the same insight as the zoo's *"the oracle comes first"* (§11.2) and the same insight as
§6.3, arrived at independently by two projects. When three unrelated sources converge on "compare
against the original, not against yourself," it is not a style preference.

Conviction 4 is why the code below is worth reading: **every failure in it is typed and explicit**.
There are no defaults, no `try?`, and no fallbacks. That is unusual in beta-era code and it makes
the package a good template.

### 9.2 The two Core AI module namespaces — get this wrong and nothing compiles

| Swift module | Where it comes from | Evidence |
|---|---|---|
| **`CoreAI`** | **OS framework in the macOS 27 / iOS 27 SDK.** `SwiftLMCoreAI` imports it while depending on *nothing* but its own `CoreAIExport` target | `Sources/SwiftLMCoreAI/*.swift:1` `import CoreAI`; `Package.swift:52-55` |
| **`CoreAILanguageModels`** | SPM package `apple/coreai-models`, **product name `CoreAILM`** — module name ≠ product name | `Sources/SwiftLMFoundationModels/*.swift:1` `import CoreAILanguageModels`; `Package.swift:57-62` |

> ✅ **VERIFIED** — both, from `Package.swift` and the import lines. This is the #2 gotcha in the
> repo's own catalogue: *"Getting this wrong produces 'no such module' errors."*

The package pin is a bare revision, no semver tag:

```swift illustrative
.package(
    url: "https://github.com/apple/coreai-models.git",
    revision: "938d0b8943b942ce66438b94ab017c5631d1aef4"
),
```

and it transitively pulls **`xgrammar`** (`github.com/mlc-ai/xgrammar`, branch `main`, revision
`257f870d…`) — which is how grammar-constrained decoding reaches the Core AI Swift stack. See
[Part 7 guide 04](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md).

### 9.3 The three-asset VLM contract

The newest and most valuable artifact in the repo. Apple's official VLM bundle is **three
`.aimodel` assets in one bundle**, wired in sequence:

```text
image -> vision.aimodel ----+
                            v
prompt -> embed.aimodel -> decoder.aimodel -> generated text
```

> ✅ **VERIFIED** — `README.md:132-138`, verbatim; and the same three roles appear in Apple's own
> `models/vlm/README.md:29-39` as `main` = text decoder (`inputs_embeds`, stateful KV),
> `embedding` = token-embedding lookup (`input_ids → embeds`), `vision` = encoder
> (`pixel_values → image_features`).

The design doc adds the contract's rules:

> *"`CoreAISequentialVLMEngine` executes Apple's official three-asset VLM contract: vision encoder,
> token embedding, and embedding-input decoder.*
>
> *The VLM adapter preserves that asset boundary and provides a state-owning Swift actor. Text
> input is rendered by the embedded tokenizer chat template and must produce one image placeholder
> before expansion. Pre-tokenized input must carry the exact declared placeholder count. Both
> contracts fail explicitly when the bundle metadata, template, or token layout disagrees with the
> exported model."*

> ✅ **VERIFIED** — `docs/design/core-ai.md:80-85`, verbatim, added in the HEAD commit.

### 9.4 The bundle loader, verbatim

This is the Core AI integration code, and it is the single densest inventory of Apple's
`CoreAILanguageModels` API available outside Apple's own repo:

```swift illustrative
import CoreAILanguageModels
import Foundation

/// Strict loader for Apple Core AI language-model bundles.
@available(macOS 27.0, iOS 27.0, *)
public struct SwiftLMFoundationModelBundle: Sendable {
    private let bundle: LanguageBundle

    public init(contentsOf url: URL) throws {
        bundle = try LanguageBundle(at: url)
    }

    public var name: String { bundle.name }
    public var tokenizer: String { bundle.tokenizer }
    public var vocabSize: Int { bundle.vocabSize }
    public var maxContextLength: Int { bundle.maxContextLength }
    public var bundleURL: URL { bundle.bundlePath }
    public var isVisionLanguageModel: Bool { bundle.visionConfig != nil }

    public var visionConfiguration: SwiftLMVisionConfiguration? {
        bundle.visionConfig.map(SwiftLMVisionConfiguration.init)
    }

    public func makeLanguageModel(
        variant: String? = nil,
        kvCacheStrategy: KVCacheStrategy = .auto
    ) async throws -> CoreAILanguageModel {
        guard !isVisionLanguageModel else {
            throw SwiftLMVisionLanguageModelError.visionLanguageModelRequiresVisionAPI
        }
        return try await CoreAILanguageModel(
            resourcesAt: bundle.bundlePath,
            variant: variant,
            kvCacheStrategy: kvCacheStrategy
        )
    }

    public func makeVisionLanguageModel(
        kvCacheStrategy: KVCacheStrategy = .auto
    ) async throws -> SwiftLMVisionLanguageModel {
        let visionConfig = try validatedVisionConfiguration()

        try bundle.bundle.verify()

        let visionURL = try bundle.requireModelURL(for: ModelBundle.ComponentKey.vision)
        let embeddingURL = try bundle.requireModelURL(for: ModelBundle.ComponentKey.embedding)
        let decoderURL = try bundle.requireModelURL(for: ModelBundle.ComponentKey.main)
        let functionName = bundle.language.functionMap?.name(for: "main") ?? "main"
        let baseConfig = ModelConfig(
            name: bundle.name,
            tokenizer: bundle.tokenizer,
            vocabSize: bundle.vocabSize,
            maxContextLength: bundle.maxContextLength,
            serializedModel: [decoderURL.path],
            function: functionName
        )
        let configuration = VLMModelConfig(base: baseConfig, visionConfig: visionConfig)

        let visionModel = try await PreparedModel.prepare(at: visionURL)
        let embeddingModel = try await PreparedModel.prepare(at: embeddingURL)
        let decoderModel = try await PreparedModel.prepare(at: decoderURL)
        let engine = try await CoreAISequentialVLMEngine(
            config: configuration,
            visionModel: visionModel,
            embedModel: embeddingModel,
            llmModel: decoderModel,
            options: EngineOptions(kvCacheStrategy: kvCacheStrategy)
        )
        let tokenizer = try await bundle.loadTokenizer()

        var stopTokenIDs = Set<Int32>()
        if let eosTokenID = tokenizer.eosTokenId {
            stopTokenIDs.insert(Int32(eosTokenID))
        }

        return SwiftLMVisionLanguageModel(
            engine: engine,
            tokenizer: tokenizer,
            configuration: SwiftLMVisionConfiguration(visionConfig),
            maxContextLength: bundle.maxContextLength,
            stopTokenIDs: stopTokenIDs
        )
    }
```

> ✅ **VERIFIED** — `Sources/SwiftLMFoundationModels/CoreAILanguageModelBundle.swift:1-83`,
> verbatim.

The Apple API surface this exercises, all verified *by use*:

- `LanguageBundle(at: URL) throws`, and `.name` / `.tokenizer` / `.vocabSize` /
  `.maxContextLength` / `.bundlePath`
- `LanguageBundle.visionConfig -> VisionConfig?` — **presence implies VLM**
- `LanguageBundle.bundle -> ModelBundle`, and `ModelBundle.verify() throws`
- `LanguageBundle.requireModelURL(for: ModelBundle.ComponentKey) throws -> URL`, with
  `.vision` / `.embedding` / `.main`
- `LanguageBundle.language.functionMap?.name(for: String) -> String?`
- `LanguageBundle.loadTokenizer() async throws -> any Tokenizer` (swift-transformers)
- `ModelConfig(name:tokenizer:vocabSize:maxContextLength:serializedModel:function:)` — note
  **`serializedModel: [String]` is an array of paths**
- `VLMModelConfig(base: ModelConfig, visionConfig: VisionConfig)`
- `PreparedModel.prepare(at: URL) async throws -> PreparedModel`
- `CoreAISequentialVLMEngine(config:visionModel:embedModel:llmModel:options:) async throws`
- `EngineOptions(kvCacheStrategy: KVCacheStrategy)`, `KVCacheStrategy.auto`
- `CoreAILanguageModel(resourcesAt: URL, variant: String?, kvCacheStrategy:) async throws`

⚠️ **Name-collision hazard.** `CoreAILanguageModels.ModelConfig` (a bundle config) is a *different
type* from `LMIR.ModelConfig` (HF-derived model dimensions) and from `SwiftLM.ModelConfiguration`.
In your own code, qualify.

### 9.5 Validate before you load — the pattern worth copying

Before a single asset is touched, the vision config is checked field by field:

```swift prelude:guide-context
private func validatedVisionConfiguration() throws -> VisionConfig {
    guard let configuration = bundle.visionConfig else {
        throw SwiftLMVisionLanguageModelError.languageModelDoesNotSupportVision
    }
    guard configuration.imageSize > 0 else {
        throw invalidVisionConfiguration(field: "image_size", reason: "must be greater than zero")
    }
    guard configuration.patchSize > 0 else {
        throw invalidVisionConfiguration(field: "patch_size", reason: "must be greater than zero")
    }
    guard configuration.imageSize.isMultiple(of: configuration.patchSize) else {
        throw invalidVisionConfiguration(
            field: "patch_size",
            reason: "must divide image_size exactly"
        )
    }
    guard configuration.imageTokenCount > 0 else {
        throw invalidVisionConfiguration(
            field: "image_token_count",
            reason: "must be greater than zero"
        )
    }
    guard configuration.imageTokenId >= 0 else {
        throw invalidVisionConfiguration(field: "image_token_id", reason: "must not be negative")
    }
    guard configuration.imageMean.count == 3 else {
        throw invalidVisionConfiguration(field: "image_mean", reason: "must contain three RGB values")
    }
    guard configuration.imageStd.count == 3 else {
        throw invalidVisionConfiguration(field: "image_std", reason: "must contain three RGB values")
    }
    guard configuration.imageMean.allSatisfy(\.isFinite) else {
        throw invalidVisionConfiguration(field: "image_mean", reason: "values must be finite")
    }
    guard configuration.imageStd.allSatisfy({ $0.isFinite && $0 != 0 }) else {
        throw invalidVisionConfiguration(
            field: "image_std",
            reason: "values must be finite and nonzero"
        )
    }
    guard configuration.rescaleFactor.isFinite else {
        throw invalidVisionConfiguration(field: "rescale_factor", reason: "must be finite")
    }
    return configuration
}
```

> ✅ **VERIFIED** — `CoreAILanguageModelBundle.swift:85-141`, verbatim.

Every one of those guards is a bundle-authoring mistake somebody made. `image_size` not divisible by
`patch_size`; a zero in `image_std`; a non-finite `rescale_factor` from a bad JSON round-trip. Each
would otherwise surface as a wrong-looking image deep inside the vision encoder, with no error. If
you write a bundle producer (§4.5), write this validator on the consuming side too.

### 9.6 The state-owning actor

```swift prelude:external-module
import CoreAILanguageModels
import Foundation
import Tokenizers

/// Stateful Swift interface over Apple's Core AI sequential VLM engine.
@available(macOS 27.0, iOS 27.0, *)
public actor SwiftLMVisionLanguageModel: SwiftLMVisionLanguageGenerating {
    public nonisolated let configuration: SwiftLMVisionConfiguration

    private let engine: CoreAISequentialVLMEngine
    private let tokenizer: any Tokenizer
    private let maxContextLength: Int
    private let stopTokenIDs: Set<Int32>

    public func generate(
        from input: SwiftLMVisionLanguageInput,
        options: SwiftLMVisionLanguageGenerationOptions = SwiftLMVisionLanguageGenerationOptions()
    ) async throws -> SwiftLMVisionLanguageOutput {
        guard options.maxTokens > 0 else {
            throw SwiftLMVisionLanguageModelError.invalidMaximumTokenCount(options.maxTokens)
        }

        let embeddedInput = try await engine.encodeImage(at: input.imageURL)
        guard embeddedInput.tokenCount == configuration.imageTokenCount else {
            throw SwiftLMVisionLanguageModelError.invalidImagePlaceholderCount(
                expected: configuration.imageTokenCount,
                actual: embeddedInput.tokenCount
            )
        }

        let promptTokenIDs = try makePromptTokenIDs(from: input.prompt)
        let requestedTokenCount = promptTokenIDs.count + options.maxTokens
        guard requestedTokenCount <= maxContextLength else {
            throw SwiftLMVisionLanguageModelError.contextLengthExceeded(
                maximum: maxContextLength,
                requested: requestedTokenCount
            )
        }

        let sequence = try await engine.generate(
            with: embeddedInput,
            tokens: promptTokenIDs,
            samplingConfiguration: options.samplingConfiguration,
            inferenceOptions: InferenceOptions(maxTokens: options.maxTokens)
        )

        var generatedTokenIDs: [Int32] = []
        for try await output in sequence {
            if stopTokenIDs.contains(output.tokenId)
                || options.additionalStopTokenIDs.contains(output.tokenId)
            {
                sequence.setStopReason(.eos)
                break
            }
            generatedTokenIDs.append(output.tokenId)
        }

        guard let stopReason = sequence.stopReason else {
            throw SwiftLMVisionLanguageModelError.generationEndedWithoutReason
        }
        return SwiftLMVisionLanguageOutput(
            text: tokenizer.decode(tokens: generatedTokenIDs.map(Int.init)),
            tokenIDs: generatedTokenIDs,
            stopReason: stopReason
        )
    }

    public func reset() async throws { try await engine.reset() }
    public func cancel() async throws { try await engine.cancel() }
}
```

> ✅ **VERIFIED** — `Sources/SwiftLMFoundationModels/SwiftLMVisionLanguageModel.swift:1-128`,
> abridged only by removing the initializer and two private helpers; every line shown is verbatim.

Three things to notice in that method, all of them transferable:

1. **`engine.generate(...)` returns an `AsyncSequence` that is itself stateful and mutable.** You
   `for try await` over it, and you also call `sequence.setStopReason(.eos)` on it and read
   `sequence.stopReason` afterwards. That is unusual API shape — the sequence carries the
   termination reason out-of-band — and the code guards against it being `nil`:
   `.generationEndedWithoutReason` → *"Core AI generation ended without reporting a stop reason."*
2. **The context check happens before generation, not during.** `promptTokenIDs.count +
   options.maxTokens <= maxContextLength` is a caller-side precondition. Core AI does not enforce
   it for you.
3. **The model owns mutable KV state.** From the README: *"The model owns mutable KV state, so call
   `reset()` before starting an unrelated request."* It is an `actor`, so ordering is serialised
   for you — **but state is not.** Two unrelated prompts without a `reset()` share a cache.

Apple's VLM-engine surface exercised, verified by use:

- `CoreAISequentialVLMEngine.encodeImage(at: URL) async throws -> <EmbeddedInput>` where the result
  exposes `.tokenCount: Int`
- `.generate(with:tokens:samplingConfiguration:inferenceOptions:) async throws -> <TokenSequence>`
  with `tokens: [Int32]`, elements exposing `.tokenId: Int32`
- `InferenceOptions(maxTokens: Int)`; `SamplingConfiguration` with a `.greedy` static member;
  `StopReason` with `.eos`
- `.reset() async throws`, `.cancel() async throws`
- `PromptUtils.maybeApplyTokenizerChatTemplate(_:tokenizer:) throws -> [Int]` with a `.prompt(String)` case

> 🔴 **GAP — several type *names* in that list are unverified.** The return type of `encodeImage`
> is used only through `.tokenCount`; the return type of `generate` is used only as an
> `AsyncSequence` with `setStopReason`/`stopReason`. The full case lists of `StopReason`,
> `SamplingConfiguration`, `KVCacheStrategy` and `ModelBundle.ComponentKey` are likewise unknown —
> only `.eos`, `.greedy`, `.auto`, and `{main, vision, embedding}` are observed.
> **What would resolve it:** an SDK interface dump of `CoreAILanguageModels`, or `swift build`
> output with `-emit-module-interface`. **SAFE DEFAULT:** bind these with `let x = try await …`
> and let type inference carry them; do not write the type name.

### 9.7 The image-placeholder contract — an asymmetry that will catch you

```swift prelude:guide-context
@available(macOS 27.0, iOS 27.0, *)
struct SwiftLMVisionPromptTokenExpander: Sendable {
    let imageTokenID: Int32
    let imageTokenCount: Int

    func expandTemplatedTokenIDs(_ tokenIDs: [Int32]) throws -> [Int32] {
        let placeholderCount = countPlaceholders(in: tokenIDs)
        guard placeholderCount == 1 else {
            throw SwiftLMVisionLanguageModelError.invalidImagePlaceholderCount(
                expected: 1,
                actual: placeholderCount
            )
        }

        var expandedTokenIDs: [Int32] = []
        expandedTokenIDs.reserveCapacity(tokenIDs.count + imageTokenCount - 1)
        for tokenID in tokenIDs {
            if tokenID == imageTokenID {
                expandedTokenIDs.append(
                    contentsOf: repeatElement(imageTokenID, count: imageTokenCount)
                )
            } else {
                expandedTokenIDs.append(tokenID)
            }
        }
        return expandedTokenIDs
    }

    func validatePretokenizedTokenIDs(_ tokenIDs: [Int32]) throws {
        let actualCount = countPlaceholders(in: tokenIDs)
        guard actualCount == imageTokenCount else {
            throw SwiftLMVisionLanguageModelError.invalidImagePlaceholderCount(
                expected: imageTokenCount,
                actual: actualCount
            )
        }
    }

    private func countPlaceholders(in tokenIDs: [Int32]) -> Int {
        tokenIDs.count(where: { $0 == imageTokenID })
    }
}
```

> ✅ **VERIFIED** — `SwiftLMVisionPromptTokenExpander.swift:1-44`, verbatim. Note
> `tokenIDs.count(where:)` — Swift 6's `count(where:)` on `Sequence`.

⚠️ **The two prompt paths have opposite requirements and the same error case.**

| Prompt case | Required placeholder count | Then |
|---|---|---|
| `.text(String)` | the chat template must render **exactly 1** image token | the adapter **expands** it to `imageTokenCount` (196 for a 448/16 ViT) |
| `.tokens([Int32])` | **exactly `imageTokenCount`** already present | validated, **never expanded** |

Both failures throw `invalidImagePlaceholderCount(expected:actual:)` — with a different `expected`.
If you are debugging one, read the `expected` value to know which path you are on.

Minimal end-to-end usage:

```swift prelude:guide-context
let bundle = try SwiftLMFoundationModelBundle(contentsOf: bundleURL)
let model = try await bundle.makeVisionLanguageModel()
let output = try await model.generate(
    from: SwiftLMVisionLanguageInput(
        imageURL: imageURL,
        prompt: .text(prompt)
    )
)
```

> ✅ **VERIFIED** — `README.md:143-152`, verbatim.

### 9.8 ⚠️ SILENT FAILURE: every Core AI test in this repo passes without running

This is the most transferable warning in the whole package, and the repo says it about itself.

```swift illustrative
@Test("Runs an official Core AI VLM bundle when test assets are provided")
func runsVisionLanguageBundle() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard
        let bundlePath = environment["SWIFTLM_COREAI_TEST_VLM_BUNDLE"],
        let imagePath = environment["SWIFTLM_COREAI_TEST_VLM_IMAGE"]
    else { return }
    ...
}
```

> ✅ **VERIFIED** — `Tests/SwiftLMFoundationModelsTests/SwiftLMFoundationModelBundleTests.swift:22-54`.

`else { return }` — the test **passes**. Not skipped, not marked, not reported. A green
`SwiftLMFoundationModelsTests` run proves nothing about the runtime at all.

The env vars that gate the Core AI tests across the repo:

| Env var | Gates |
|---|---|
| `SWIFTLM_COREAI_TEST_BUNDLE` | LLM bundle load, and the stateful bundle in `CoreAIModelAssetTests` |
| `SWIFTLM_COREAI_TEST_VLM_BUNDLE` | VLM bundle directory |
| `SWIFTLM_COREAI_TEST_VLM_IMAGE` | image file path |
| `SWIFTLM_COREAI_TEST_VLM_TOKEN_IDS` | comma-separated pre-tokenized prompt |
| `SWIFTLM_COREAI_TEST_STATELESS_BUNDLE` | stateless `.aimodel` bundle |
| `SWIFTLM_COREAI_TEST_STATELESS_EXPECTED_LAST_TOKEN` | expected argmax token id |

The repo's own production-readiness doc says it in bold:

> *"Apple-native VLM changes must also run `SwiftLMFoundationModelsTests`. Set
> `SWIFTLM_COREAI_TEST_VLM_BUNDLE`, `SWIFTLM_COREAI_TEST_VLM_IMAGE`, and, for a pre-tokenized
> fixture, `SWIFTLM_COREAI_TEST_VLM_TOKEN_IDS` to exercise vision encoding, embedding scatter,
> stateful decoding, and token generation. **Metadata-only tests are not sufficient for this
> runtime boundary.**"*

> ✅ **VERIFIED** — `docs/production-readiness.md:48-52`, verbatim.

Compare the zoo's four-state verdict model (§11.3), which exists precisely to prevent this:
`PASS` / `DIFF` / `FAIL` / **`skipped`** — *"Never report a skipped check as a pass."* If you are
building CI around Core AI assets, adopt the four-state model, not the `else { return }` pattern.

### 9.9 What `swift-lm` actually verified, with numbers

Unlike `mlx2coreai`, `swift-lm` publishes real-model results. Quoted verbatim because they are the
only concrete numeric Core AI results in that repo:

> - *Real `yujiepan/lfm2-tiny-random` stateless logits matched Hugging Face with `0.001220703125`
>   maximum absolute error and exact Top-5 token IDs.*
> - *The same Swift graph's stateful and stateless paths matched exactly across sequential tokens
>   in Python.*
> - *A generated stateless LFM2 `.aimodel` ran through `CoreAIModelBundle.makeStatelessSession()`
>   in Swift and returned the contract-declared logits shape.*
> - *A generated stateful LFM2 `.aimodel` passed asset inspection and the Swift runtime
>   state-persistence/reset regression test.*
> - *The local `yujiepan/lfm2-moe-tiny-random` bundle lowered from Swift LMIR with canonical
>   per-expert weights; stateless and stateful logits matched exactly across four decode steps, and
>   both Core AI 27 assets passed inspection.*
> - *The local `yujiepan/qwen3.5-tiny-random` text graph matched the Hugging Face float32 reference
>   with maximum logits error `1.52e-6`.*
>
> *"Larger production model bundles still require model-specific validation before publishing an
> application asset. **Core AI beta compiler warnings may appear on Apple Silicon during these smoke
> tests**; the process must still complete and the output must be compared with the reference
> model."*

> ✅ **VERIFIED** — `docs/releases/0.11.0-alpha.1.md:66-98`, quoted verbatim.
> **Attribution: author-measured, community source, 2026-07.** No hardware, OS build or Xcode
> version is given, and — read the model names — **every one is a `*-tiny-random` fixture**, not a
> production checkpoint. These are *correctness* results on toy models, which is exactly what they
> claim to be and no more. Do not cite them as production validation.

The Python harness behind them (`python/tests/test_real_lfm2.py`) is a good template regardless: it
compares the lowered module against `AutoModelForCausalLM.from_pretrained(..., dtype=torch.float32)`
with `rtol=2e-3, atol=2e-3` **and exact top-5 IDs**, then steps the stateful model one token at a
time against the stateless prefix with `rtol=1e-5, atol=1e-5`. Note the two different tolerances for
the two different questions — *"is my re-authoring right"* is a looser bar than *"is my stateful
path equal to my stateless path"*.

---

## 10. `expectFrequentReshapes`: four sources, three verdicts

`SpecializationOptions.expectFrequentReshapes` is a `Bool` you set at **load time**, and it is the
sharpest disagreement in this whole corner of the stack. Four independent sources touch it and they
do not agree. The full treatment of specialization is
[Part 7 guide 02 §11](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md);
this section is only about the disagreement, because a bridge author has to pick a value.

### 10.1 What Apple documents about it

Almost nothing.

> ✅ **VERIFIED** — from the Core AI documentation capture: `var expectFrequentReshapes: Bool` is
> *"the only non-get-only property"* on `SpecializationOptions`. Its abstract reads, in full:
> *"Setting to allow more optimal specialization if the model performs frequent reshapes based on
> usage"*. **There is no Discussion section, no documented default value, and no initializer that
> sets it** — it must be set by `var` mutation after constructing options.

That is the entire published surface. Everything below is inference from code and from device
measurements.

### 10.2 Apple's own code sets it `true` for dynamic-shape GPU LLMs

```swift prelude:guide-context
public enum ModelStructure { case chunkedStatic(batchSize: Int); case dynamic; case multiFunctionSegmenter }

public var specializationOptions: SpecializationOptions {
    switch self {
    case .chunkedStatic, .multiFunctionSegmenter:
        return SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
    case .dynamic:
        var opts = SpecializationOptions(preferredComputeUnitKind: .gpu)
        opts.expectFrequentReshapes = true
        return opts
    }
}
```

> ✅ **VERIFIED** — `apple/coreai-models`, `CoreAIShared/Runtime/ModelStructure.swift`. Structure
> detection: `extend*` + `load_embeddings` → `.chunkedStatic`; `image_encode` + `text_encode` +
> `detect` → `.multiFunctionSegmenter`; a single `main` → `.dynamic`.

So Apple's shipping Swift package sets `expectFrequentReshapes = true` **for exactly the shape of
model `mlx2coreai` produces** — a single dynamic `main` entrypoint on the GPU. Two independent
corroborations of the same pattern exist in our corpus: a WWDC26 Core AI session's own sample code
sets `opts.expectFrequentReshapes = true` after choosing `.gpu`, and a third-party iOS app does the
same for its dynamic-sequence path while explicitly setting `false` for fully static shapes.

(Notice the same code block also proves the narrower §5.5 point: under this helper, a single-`main`
graph is classified `.dynamic` and receives the **GPU preference**; a recognized multi-entrypoint
shape selects its ANE preference.)

### 10.3 `swift-lm` rejects it outright

```swift prelude:guide-context
public func specialize(
    options: SpecializationOptions = .default,
    cache: AIModelCache = .default,
    cachePolicy: AIModelCache.Policy = .default
) async throws -> AIModel {
    guard !options.expectFrequentReshapes else {
        throw CoreAIModelAssetError.unsupportedSpecializationOption(
            "expectFrequentReshapes is disabled until the current Core AI runtime is compatible"
        )
    }
    return try await AIModel.specialize(
        contentsOf: url,
        options: options,
        cache: cache,
        cachePolicy: cachePolicy
    )
}
```

> ✅ **VERIFIED** — `Sources/SwiftLMCoreAI/CoreAIModelAsset.swift:1-50`, verbatim.

And the design doc explains why:

> *"`CoreAIModelAsset` rejects unsupported specialization settings explicitly. The current beta has
> a **reproducible failure** when `expectFrequentReshapes` is enabled, so callers must resolve
> dynamic shapes before execution and use the default specialization policy."*

> ✅ **VERIFIED** — `docs/design/core-ai.md:87-90`, verbatim. The repo's own gotcha catalogue calls
> it *"a landmine."*

Note the *mitigation* in that sentence and not just the prohibition: **"resolve dynamic shapes
before execution."** `swift-lm`'s stateful contract does exactly that — `input_ids` is `[1,1]` and
state shapes are resolved at session creation — so it never *needs* reshape tolerance. That is a
design choice that makes the flag irrelevant, not merely a workaround for a bug.

### 10.4 `mlx2coreai`'s Swift runner sets it `false` — on a dynamic model

```swift prelude:guide-context
var options = SpecializationOptions(preferredComputeUnitKind: .gpu)
options.expectFrequentReshapes = false
let model = try await AIModel(contentsOf: modelURL, options: options)
```

> ✅ **VERIFIED** — `benchmark_aimodel_sampling_coreai.swift`.

This is the interesting one, because `mlx2coreai`'s own asset is `.dynamic` by Apple's own
classification — single `main`, `--dynamic-sequence` and `--dynamic-state` both defaulting to
`True`. By Apple's `ModelStructure` rule it *should* get `true`. The bridge's Swift runner sets
`false` anyway, silently, with no comment.

### 10.5 The community measured it, on hardware

The zoo has a device-validated incident report, and it reframes the whole flag:

> ⚠️ *"The hint is not free insurance — it is a request for a **reshape-tolerant** specialization."*

Ask for it at load time on an all-static graph and *"the runtime **stops using the AOT
specialization and compiles on device**"*, which on an iPhone 17 Pro segfaults inside the MPSGraph
AICode compiler:

```
EXC_BAD_ACCESS (SIGSEGV) … MPSGraphAICodeCompilerDelegate getInitializedAICodeBytecodeWithPayloadPrefix:
  → Compiler_coreAI.compile(moduleBytecode:to:with:) → libODIECompiler … CompileForDelegates
```

> *"No error string, no partial output — the app just dies at `AIModel(contentsOf:options:)`."*

**Community-measured**, `john-rocky/coreai-model-zoo`, `knowledge/aot-and-specialization.md:88-106`,
**device-validated 2026-07-23**, on **iPhone 17 Pro (iOS 27 beta)**, on VibeVoice (5 fixed-shape
graphs: `q=1` stateful decode plus a fixed-T decoder):

- `expectFrequentReshapes = true` → SIGSEGV on the first graph
- `expectFrequentReshapes = false` → **all 6 loads in 2.6 s, gate PASS**
- **Compiling with `--expect-frequent-reshapes` does NOT make the runtime hint safe** — both the
  plain and the reshape-hinted `.aimodelc` crash when the *runtime* asks for the hint. *"It is the
  load-time option that matters."*

And their rule:

> *"`expectFrequentReshapes = true` **only** where shapes really change (dynamic query length /
> bucketed prefill). Static decode (`S=1`) and fixed-T vocoders must load **without** it."*

### 10.6 Reconciling them

Put the four side by side and the contradiction mostly dissolves:

| Source | Model shape | Setting | Evidence class |
|---|---|---|---|
| `apple/coreai-models` `ModelStructure` | single `main`, **dynamic** shapes, GPU | **`true`** | Apple shipping source |
| `swift-lm` | stateful, `input_ids` `[1,1]`, **shapes resolved** at session creation | **rejected entirely** | third-party source + design doc |
| `mlx2coreai` Swift runner | single `main`, **dynamic** sequence and state | **`false`** | third-party source, no comment |
| zoo, device-measured | **fixed-shape** graphs, AOT `.aimodelc` | `true` → **SIGSEGV** | community, device-validated |

The zoo's rule — *only where shapes really change* — is consistent with Apple's code (Apple sets it
`true` precisely on the `.dynamic` branch and `false`-by-default on the static ANE branch) and
consistent with the zoo's own crash (a fixed-shape graph is not the `.dynamic` case). `swift-lm`'s
blanket rejection is stricter than the rule but not in conflict with it, because `swift-lm`'s
contract has no varying shapes to tolerate. **The genuine outlier is `mlx2coreai`'s `false` on a
dynamic graph** — which is either a bug, or an undocumented workaround for the same beta failure
`swift-lm` hit, and the commit history does not say which.

🔴 **GAP — the default value of `expectFrequentReshapes` is unpublished.** Apple's docs have no
Discussion and no stated default; `SpecializationOptions.default` and `.cpuOnly` are `let`s, so the
only way to observe it is to construct options and print the property on a macOS 27 machine. **What
would resolve it:** one line in a playground on macOS 27.

🔴 **GAP — nobody in our corpus has measured a `mlx2coreai`-produced asset with the flag `true`.**
The bridge sets `false`; nobody flipped it.

**SAFE DEFAULT for a bridge author, in priority order:**

1. **Do not set it at all** on your first working load. `SpecializationOptions.default` and see if
   it works.
2. If your graph genuinely has a **varying query length** — dynamic prefill, bucketed sequence
   lengths, `--dynamic-sequence` — try `true`, and A/B it against `false` on the device you ship
   to, measuring cold load time.
3. If your graph is **fixed-shape** (`S=1` decode, a fixed-T decoder, anything you AOT-compiled),
   set it **`false` explicitly** and never let a helper set it for you. The failure is a segfault
   with no error string.
4. **Never assume the AOT compile flag substitutes for the load-time option.** They are different
   things and the community measured that the load-time one is what decides.

---

## 11. The community zoo

> ⚠️ **Attribution, once, for the whole section.** `john-rocky/coreai-model-zoo` is
> **single-author community material**. Its benchmarks are **self-declared as uncontrolled**. Its
> process documents are opinionated. Nothing in it is Apple guidance, and where it complicates
> Apple's framing it says so itself. It is in this guide because its *process* is the best written
> record of how to do this work, and because several of its findings are device-validated in ways
> nothing else in our corpus is.

### 11.1 What it is

Self-description:

> *"Converted models + conversion recipes for Apple **Core AI** (`.aimodel`, iOS 27 / macOS 27):
> every model here is downloadable, device-verified, and carries the recipe that produced it in
> `models/<model>/recipe.toml`."*

> ✅ **VERIFIED** — `README.md:8-16`, verbatim. Explicit successor to the author's older
> `CoreML-Models` repo. Weights are published under `huggingface.co/mlboydaisuke`; a sibling Swift
> package **CoreAIKit** consumes them.

Scale, measured by the repo's own `scripts/gen_inventory.py` on **2026-07-25**:

| Layer | Count |
|---|---:|
| Published Hugging Face repos | **123** (122 owned + 1 contributor) |
| Of those, **Core AI** repos | **70** |
| Bundles inside them | **238** |
| Core AI repos with a card in `models/<model>/` | **52** |
| Repos with a recipe | **52** (was 6) |
| Bundles with an automated tier-1 check | **222** (was ~0) |
| Core AI repos with **no downloads in 30 days** | **55** |

> ✅ **VERIFIED** — `CATALOG_PLAN.md:30-38`. Community-measured, self-reported, dated.

The pitch line is *"the `from_pretrained` of Core AI"*, and the direct Foundation Models tie-in is
worth noting for [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md):

```swift prelude:guide-context
LanguageModelSession(model: try await KitLanguageModel(model: .qwen3_0_6B))
```

with the claim that *"every bundle loads with Apple's own `CoreAILanguageModel(resourcesAt:)`
as-is"* (`README.md:32-39`) — i.e. the zoo's bundles target the same §4 interchange format, and its
own provider only *adds* streaming tool calling on top.

### 11.2 The porting playbook

`PORTING.md` is 351 lines, ten numbered stages, each ending in a **falsifiable checkpoint**. Two
archetype tracks run through all of it:

| Track | Model | Archetype | Why it teaches |
|---|---|---|---|
| **V** (start here) | Depth Anything 3 | **Stateless single graph** — image in, depth out. No tokenizer, no state, no host loop | The full pipeline with the fewest moving parts |
| **L** (full course) | Qwen3.5 | **Stateful autoregressive LLM** — KV cache, prefill/decode, tokenizer, host sampling loop | *"Most of the zoo is this shape"* |

**§0 — what a port actually is.** Porting is **re-author → export → verify**, and the reason for
re-authoring is stated precisely:

> *"You do this instead of exporting the Hugging Face modeling file because HF code carries
> training-time baggage (dynamic control flow, complex-number RoPE, optional branches) that either
> fails to trace or lowers badly. Re-authoring sounds heavier than it is: for a ViT it is an
> afternoon."*

**§2 — should you port at all.** Two hard gates *before writing code*:

- **GAP** — Apple's stock stack does not already ship this capability. If it does, **stop.**
- **EDGE** — the port must be at least as good as the realistic alternative, *especially MLX*.
  *"this repo has shipped and then pulled two of those."* And, memorably:
  ***"'The user asked for it' is not an answer to EDGE."***

Then FIRST, **DEVICE** (*"it fits an iPhone (~6 GB practical ceiling) = top tier. Mac-only =
tier 2"*), QUALITY, License.

**§3 — the oracle comes first.**

```python
out = hf_model(**inputs)
np.savez("oracle.npz", **{k: v.float().cpu().numpy() for k, v in tensors.items()})
```

- Track V: one image plus edge cases (non-square, high-contrast). **Save the *preprocessed* tensor
  too**, because host preprocessing gets gated against it in §5.
- Track L: a fixed prompt → **per-step logits (or at minimum per-step argmax ids) for a few dozen
  greedy steps.** *"Per-step matters: an AR loop can look fine at step 1 and drift by step 30."*

**§5 — the two gates, in order.**

*Gate A — graph parity.*

```python
model = await rt.AIModel.load(Path(out), rt.SpecializationOptions.cpu_only())  # cpu_only for parity
fn = model.load_function("main")
res = await fn({"image": rt.NDArray(x)})
```

- **`cpu_only()` for parity** (fp16 GPU/ANE adds harmless but distracting noise); anything you
  **time** must use `SpecializationOptions.default()` — *"it is ~an order of magnitude faster and
  that is what ships."*
- Pass bar Track V: **cos ≥ 0.999** on every output tensor.
- Pass bar Track L: **per-token cosine ≥ 0.999 on logits AND greedy argmax token-exact.**

*Gate B — host processing parity.* Everything the app will compute — image resize/normalize, mel
spectrograms, detokenization, samplers — is implemented **in NumPy first**, gated end to end against
the oracle's preprocessed tensors, **and only then** translated to Swift. Rationale:
*"host-side mismatches are the #1 source of 'the graph is perfect but the output is garbage', and
they are unfindable once the only implementation is inside an app."*

Checkpoint 5 is the reviewable artifact: *"a `gate_*.py` script prints PASS from a clean run with
no manual steps. This script goes in your PR."*

**§6 — compress.** Four rules: ship fp16 under ~1.5 GB; **int8 linear** as the LLM default
(*"the reliably-safe LLM scheme on this stack"*); ***"int4 is a cliff, not a slope — the failure is
capacity, so no clever rounding rescues it"***; and re-run **Gate A on the compressed bundle**
because *"compression is part of the model, so it gates like the model."*

**§8 — iPhone.** AOT-compile large graphs (*"roughly ≥ 1 GB means AOT, ≤ ~50 MB JITs fine, in
between try it"*), and measure with a headless self-test entrypoint: *"Numbers measured through a
chat UI are not comparable to anything."*

> ✅ **VERIFIED** — all quotations from `PORTING.md` at the cited line ranges. Community-sourced.

**The traps that specifically catch automation** (`AGENTS.md:65-79`) are worth reproducing whole,
because every one of them is a real incident:

1. Trusting notes over the oracle — a handoff note said "no input normalization"; the oracle showed
   the feature extractor always normalizes.
2. Re-authoring from the HF `modeling_*.py` **instead of the weights** — *"The modeling file has
   branches that never run for this checkpoint, and hides ones that do."*
3. Believing int4 because the loss looks fine — *"int4 is a cliff, not a slope."*
4. Timing with `cpu_only()` — that is the **parity** option, not a performance option.
5. Benchmarking through a chat UI — *"Headless self-test entrypoint, or it did not happen."*
6. JIT-ing a ≥ 1 GB graph on device — AOT-compile it.
7. Running an iOS bundle on a Mac — *"Wedges the GPU stack; costs a reboot."*
8. **Naked `exp()` in a hand-written kernel** — *"Three separate sessions lost to this; subtract the
   max first."*
9. Comparing quality across runtimes without matching the generation budget — *"A 12-point 'quality
   gap' in this repo's history turned out to be a 600-vs-2048 token cap difference."*

### 11.3 Process engineering worth stealing

Three findings from `CATALOG_PLAN.md` (dated 2026-07-25) that generalise well beyond this repo.

**1. ⚠️ Core AI conversion is NOT byte-deterministic — measured.**

> *"Measured 2026-07-25: the same recipe run twice on the same machine, minutes apart, produces
> `.aimodel` bundles that differ from each other (**`main.mlirb` by 7 bytes, `main.hash`
> entirely**) — and the published bundle differs from both by **492 bytes out of 1.19 GB**.
> Conversion is not byte-deterministic, so 'did this recipe reproduce the published bundle?' can
> only be answered behaviourally."*

> ✅ **VERIFIED** — `CATALOG_PLAN.md:116-121`, echoed at `README.md:94-98`. **Community-measured,
> same machine, 2026-07-25.**

**Consequence: a stored hash is worthless as a reproducibility criterion for `.aimodel` bundles.**
If you are building CI around Core AI exports, do not diff artifacts — run the gate. Note that this
is precisely why `swift-lm` SHA-256s its **JSON contract** (which *is* deterministic:
`JSONEncoder` with `[.prettyPrinted, .sortedKeys]`, atomic write) rather than the asset.

**2. The three things that blocked reproduction** — a good "how on-device ML projects rot" list:

- *"Scripts hardcoded one machine's home directory"* — **47 files, 69 occurrences.** Fixed by
  routing everything through a `_paths.py` with `ZOO_WORK_ROOT` / `ZOO_EXPORTS` / `ZOO_CODE_ROOT` /
  `HF_HUB_CACHE`. Acceptance test: `grep -rln "/Users/<name>" conversion/` returns nothing.
- *"Prerequisites were prose."* A note field saying "runtime needs patch X" is invisible to a
  runner. Split into typed fields, and crucially **export-time vs run-time prerequisites separated**
  — because *"a bundle rebuilt without the runtime patch looks correct and then misbehaves in the
  app."*
- *"The shipped configuration was often unrecorded."* Where it could not be derived, the entry says
  so **instead of guessing**.

**3. The four-state verdict model.** `zoo_verify.py` checks four things per bundle — **eos/bos, chat
template, context length, declared precision** — and reads the expectations **from the source HF
repository at run time** rather than from transcribed local files: *"A transcription can be wrong
and goes stale; the source repo cannot."*

| Verdict | Meaning |
|---|---|
| `PASS` | agrees with source |
| `DIFF` | deviates with **no recorded reason** — *not automatically a bug*. *"swapping `eos_token` for the turn terminator is a real ship-time decision. It becomes correct by being recorded in `models/<family>/verify.toml`, after which an unexplained deviation fails."* |
| `FAIL` | wrong on its own terms |
| `skipped` | ***"Never report a skipped check as a pass."*** |

First full run over **222 bundles: 162 PASS, 8 DIFF, 10 FAIL, 42 SKIPPED**. After fixes:
**180 PASS, 0 DIFF, 0 FAIL, 42 SKIPPED**.

Compare §9.8's `else { return }`. The four-state model is the fix for that failure mode, and the
`DIFF` state in particular is the good idea — it distinguishes *"deviates"* from *"deviates for a
recorded reason"* without forcing you to encode every intentional deviation as an exception up
front.

**The defects that verification actually found** — all real, all shipped, all invisible to a
byte-comparison:

- **10 FAILs: Gemma 4 E2B/E4B bundles shipped NO chat template at all** while their source ships
  one — and *"E2B is the most-downloaded text model in the catalog."* Root cause: the export script
  copied `tokenizer.json`, `tokenizer_config.json` and `special_tokens_map.json` **but not
  `chat_template.jinja`**, while the 12B exporter did.
- **`eos` vs `eot`:** Gemma 4 E2B/E4B shipped `eos_token: "<eos>"`, which *"a host loop stops on
  only at end-of-sequence, never at end-of-turn."* The source's own `eot_token` is `<turn|>`.
  Workaround in the wild: **the chat app hardcodes `EOT = 106`.**
- **A metadata privacy leak, published:** one model's `hf_model_id` and `tokenizer` fields *"held an
  absolute path from this machine, published."* ⚠️ If you emit `metadata.json` (§4), check what you
  put in `source.hf_model_id`.
- **One "drift" was a verifier bug:** a bundle shipped its chat template both as a file and inside
  `tokenizer_config.json`; the two differed by **7 bytes**; the verifier compared the field while
  `transformers` reads the file.

And the meta-lesson the document states about itself, which is the right attitude toward every gate
in this guide:

> *"Verification earns its keep by contradicting the plan that asked for it."*

> ✅ **VERIFIED** — all of §11.3 from `CATALOG_PLAN.md`, quoted at the cited lines.
> Community-sourced.

### 11.4 The benchmark protocol — cite it as a protocol, not a dataset

`BENCHMARKS.md` is a **process artifact more than a data artifact** and should be cited as such.

- Data comes from the Bench tab of a TestFlight app on contributors' own devices, submitted as
  GitHub issues — *"the public audit log. The app measures and builds the result blob; no number in
  this table was typed by a human."*
- Explicitly labelled ***"NOT a controlled-environment benchmark — background load and heat show up
  here as real-world variance."***
- **Protocol `pb-random-v1`:** fixed 128-token random prompt (seed 0) → **256 greedy decode
  tokens**, S=1 prefill, **1 cold + 3 warm runs on a freshly created engine**. Cell = median across
  submissions of each submission's median warm decode tok/s. `n < 3` marked provisional.
- **Environment filter:** blobs with **Low Power Mode on** or a **serious/critical thermal state**
  before the run are excluded from medians, and the exclusion count is published.

As of `Last run: 2026-07-03 06:15 UTC` the crowd-sourced table holds **one accepted submission**
(qwen3.5-0.8b at **68.4 tok/s** on iPhone 17 Pro, `n=1`). ⚠️ **Do not cite `BENCHMARKS.md` as a
multi-device dataset.** The repo's own README headline gives the same model as **71.9** tok/s — ~5 %
apart, consistent with different prompts and thermal state, and a useful illustration of the
variance floor.

Two measurement facts from elsewhere in the same repo that belong in any benchmarking discussion:

- ⚠️ **Thermals move numbers by 2.3–4.1×.** *"A day of device use silently degrades a **25 ms**
  model to **58–103 ms** (thermal saturation, not your app)."* Benchmark only at
  `thermalState == .nominal`, record thermal and low-power state alongside every stat, and cool
  down between runs. **Community-measured, iOS 27 beta.**
- ⚠️ **`cpu_only()` is ~9–10× slower than `default()`** and it is the *parity* option, not a
  performance option. Measured on a TripoSplat DiT: **24.2 s → 2.6 s per call, ~9.3×**, with
  *"cos vs cpu still 1.000000."* The landmine attached: a community helper *"defaults to
  `cpu_only`, so apps/benchmarks that copy it silently run on CPU — override it."*

And one more from the same file, which belongs in every parity harness you write:

- ⚠️ **SILENT FAILURE: keep the `AIModel` reference alive.** In a persistent multi-call runner,
  *"storing only the `load_function` lets the model get GC'd and the function then returns
  **GARBAGE** (no crash, just wrong output → looks like a conversion bug). Hold
  `self.models[name] = m`."* If you write the §6.3 parity loop as a helper that returns only the
  function, you will spend a day debugging the converter for a Python lifetime bug. Two more from
  the same list: **`AIModel.load(path, None)` raises `RuntimeError: MPSGraph Unresolved symbol
  (prepare/initialize)`** on the GPU path — always pass an explicit `SpecializationOptions`, never
  `None`; and **`AIModel.load` is async, `load_function` is SYNC, and calling the function is
  async** — *"Mixing these up is the most common first error."*

  > ✅ **VERIFIED** — `knowledge/conversion-guide.md:21-25` and the precision/option traps section.
  > Community-sourced.

> ✅ **VERIFIED** — `BENCHMARKS.md:1-30`; `knowledge/conversion-guide.md`. Community-measured
> throughout; the hardware for the CPU/GPU ratio is not stated beyond "Apple silicon Mac."

### 11.5 The zoo and Apple's `model-authoring` skill are complementary

`apple/coreai-models` ships skills — `model-authoring` (153 lines), `working-with-coreai` (199),
`model-compression-exploration` (191), plus `references/{neural_engine_rules,gpu_rules,common_issues}.md`.
The zoo ships its own, and **explicitly tells you to install Apple's too**: *"Apple's own
`coreai-skills` covers the toolchain itself; install both."*

The division is clean and worth internalising, because it tells you which document to open when:

> **Apple is *inside* the module. The zoo is *around* it.**

| Axis | Apple `model-authoring` | Zoo `port-a-model-to-the-zoo` |
|---|---|---|
| Scope | **Inside** the PyTorch module: how to write ops so they lower well | **Around** the module: oracle, gates, device, publishing |
| Organizing frame | Compute unit (ANE vs GPU vs CPU) and tensor layout | Process stages with falsifiable checkpoints |
| Verification metric | **PSNR in dB** | **cosine ≥ 0.999 + token-exact argmax** |
| Verification bars | re-authored vs source **> 70 dB**; ANE-layout vs GPU-layout **> 70 dB**; compiled vs torch **≥ 40 dB**; after 4-bit palettization **≥ 35 dB** | Track V cos ≥ 0.999 per output; Track L per-token cos ≥ 0.999 **and** greedy token-exact |
| Compression guidance | palettization PSNR table: 8-bit ~2× / > 55 dB (flag < 50); 4-bit ~4× / ~40 dB (flag < 35); 2-bit ~8× / ~25–35 dB, *"Usually unacceptable"* | *"int4 is a cliff, not a slope"*; int8 linear default for LLMs; **read the generations** |
| Device / deploy | not covered | AOT per architecture, sideload, self-test entrypoint, thermals |
| Publishing | not covered | HF repo, card, `recipe.toml`, README row, `zoo_verify.py` |
| Authority | **Apple-official** | community |

> ✅ **VERIFIED** — Apple's bars from `skills/skills/model-authoring/SKILL.md:94-99` and `:149-153`;
> the zoo's from `PORTING.md:184-211`. The comparison table itself is the research pass's synthesis.

**Where they genuinely differ in advice, not just in scope** — three places, and you should know
about all three:

1. **The metric.** Apple is PSNR-in-dB throughout. The zoo uses cosine plus token-exactness for
   LLMs and is explicit that *"step 1 looking fine is not a gate; AR drift shows up late."* Apple's
   skill has **no per-token autoregressive-drift gate**. Neither is wrong, but note the
   consequence: **a "compiled vs torch ≥ 40 dB" pass can coexist with a non-token-exact LLM**,
   which is exactly the failure the zoo's gate is built to catch. *(That inference is this guide's
   reading of the two documents, not a claim either author makes.)*
2. **KV cache mechanism.** Apple's skill gives two canonical shapes and a hard rule: ANE
   `[n_layers, B, H_kv*D, 1, max_S]` with a **readonly functional I/O** pattern (no cache writes in
   the model); GPU `[n_layers, B, H_kv, max_S, D]` with a **stateful export wrapper**. Plus: *"Do
   not use stateful transforms for token generation — state resets between inference calls."* The
   zoo's `PORTING.md` instead prescribes in-graph mutable state via `slice_update` +
   `remove_functionalization(ep)`. 🔴 **These describe different mechanisms at different layers and
   this guide does not claim they are alternatives.** How `hoistToArg` and
   `remove_functionalization` relate was not established in our corpus. **SAFE DEFAULT:** follow
   Apple's skill for the *authoring* shape and the zoo's for the *export* incantation, and gate the
   result — which is what both documents would tell you anyway.
3. **`from_source_model`.** Apple mandates a `from_source_model` classmethod on every re-authored
   model — *"no hardcoded constants"*, config-driven construction plus `load_weights_from`. The zoo
   has no equivalent convention; its exporters load `model.safetensors` directly.

One more difference of tone, which matters if you are choosing a compute unit: Apple's skill maps
user vocabulary → compute unit (energy/battery/iPhone → ANE; throughput/macOS/large → GPU;
correctness → CPU) and instructs you to use **outcome-oriented language** (*"optimized for
energy-efficient inference on iPhone"* rather than *"targets Neural Engine"*). The zoo is bluntly
GPU-first: *"If you aren't explicitly targeting ANE, target GPU and move on."*

### 11.6 The one authority boundary worth copying

The zoo's `AGENTS.md` has a section called **"Not your call"** — things an automated contributor
must ask a human about, every time:

- publishing weights to Hugging Face
- posting publicly
- opening issues or PRs against `apple/*` repos
- marking a port `status = "verified"` **on numbers you did not produce**

and a companion: *"Do not report iPhone numbers you did not measure, and do not let an unmeasured
device claim reach a card."*

> ✅ **VERIFIED** — `AGENTS.md:104-111`, `:96-102`. Reproduced because it is a notably mature
> boundary set, and because the fourth item is the one this whole guide is about.

---

## 12. Decision table: which bridge, and when to re-author instead

### 12.1 By starting point

| You have… | You want… | Use | Why, and the catch |
|---|---|---|---|
| An **`mlx-lm` causal LM** (dense transformer, standard attention) | a Core AI LLM bundle | **`mlx2coreai convert-mlx-lm-stateful`** | The only tool that does it. Reproduces Apple's `keyCache`/`valueCache` contract exactly (§3.3). **Catch:** unverified end to end; run §6.3 |
| An **MLX vision/audio model**, stateless, one graph | a `.aimodel` | **`mlx2coreai` generic path** (§5.1) | The 156-op registry covers most of what a ViT needs. **Catch:** conv-transpose lowers to **zeros** (§7.2); bool masks are added not selected (§7.1) |
| An **MLX model with sliding-window attention** (Gemma-style, Mistral SWA) | anything | **not `mlx2coreai`** | `make_mask` raises `NotImplementedError`. Re-author in torch, or stay on MLX |
| An **MLX model with an SSM / linear-attention / hybrid block** | a Core AI bundle | **not `mlx2coreai`** | No `state_space` composite, no `GatedDeltaUpdate` lowering. `swift-lm`'s Python path *does* have one via `coreai_torch.composite_ops.GatedDeltaUpdate`, but it drives torch, not MLX |
| A **Hugging Face checkpoint** in a family `swift-lm` knows (llama/qwen2/qwen3/mistral/gemma/gemma3/gemma4/qwen3.5/lfm2/cohere/…) | a Core AI bundle with a checkable contract | **`swift-lm`** | Declare once in Swift, lower generically in Python, get a SHA-256'd JSON contract embedded in the bundle. **Catch:** stateful requires `--target macos`; `ios_static` throws |
| A **Hugging Face checkpoint** in *any* family | a Core AI bundle | **re-author + `coreai_torch`** ([Part 10 g3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-10-coreai-hardware-authoring-debugging/references/03-llm-export-end-to-end.md)) | The path Apple supports and the zoo documents. Slowest to start, only one with a real safety net |
| An **existing Core AI bundle** you did not build | to run it | `LanguageBundle` / `CoreAILanguageModel` ([Part 7 g4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md)) | Nothing in this guide is needed |
| A **VLM** (image + text) | a Core AI bundle | **Apple's exporter**, consumed via `swift-lm`'s adapter pattern (§9.3–§9.7) | `mlx2coreai` writes only `kind: "llm"`. 🔴 We have no read of how Apple's VLM exporter is invoked (§14) |
| A model you want on the **Neural Engine** | ANE execution | **not these bridges** | Apple's ANE LLM recipes use a multi-entrypoint or chunked-static structure plus palettized weights (§5.5, §10.2 — a `coreai-models` loader convention, not a framework routing contract). `mlx2coreai` emits a single dynamic `main` and does no compression at all |

### 12.2 When the honest answer is "re-author from the checkpoint"

Converting is seductive because it looks like one command. Here is when it is the wrong call, with
the reason each time.

**1. When the source model has data-dependent control flow.**
`mlx2coreai`'s probe-based dynamic-shape inference requires two traces with *identical* node counts,
ops and arities. Any `if seq_len > N:` in the forward pass raises
`"dynamic shape probe produced a different graph structure"`. And the same discipline applies on
the torch side. Re-authoring is how you *remove* the branches rather than fight them.

**2. When the model uses ops the bridge silently mistranslates.**
§7 lists them. If your model uses `log2`, bit shifts, boolean attention masks, asymmetric conv
padding or general transposed convolution, the conversion will *succeed* and be wrong. Re-authoring
lets you write the op the way the target lowers well — which is exactly what Apple's
`model-authoring` skill is *for*.

**3. When you need compression.**
Neither bridge in this guide quantizes. If you need int8 linear — the zoo's *"reliably-safe LLM
scheme on this stack"* — or palettization for the ANE, you need `coreai-opt` in the pipeline, which
means the torch path.

**4. When "it fails to trace or lowers badly" describes your model.**
The zoo says it best and it is worth re-reading:

> *"You do this instead of exporting the Hugging Face modeling file because HF code carries
> training-time baggage (dynamic control flow, complex-number RoPE, optional branches) that either
> fails to trace or lowers badly. **Re-authoring sounds heavier than it is: for a ViT it is an
> afternoon.**"*

The cost asymmetry is the whole argument. A conversion that produces plausible garbage costs you
days of bisection *and* you still have to re-author at the end. An afternoon spent re-authoring a
ViT front-loads the cost and gives you a graph you understand.

**5. When you cannot build an oracle for the converted artifact.**
This is the decisive one and it applies to every row above. If you cannot run the original and
compare token-for-token (§6.3), you do not have a port — you have a bundle. The zoo's framing:
*"A port without gates is a guess with extra steps."*

**Conversely, convert when:** the model is a standard dense transformer, you have an oracle, you
have a device to verify on, and you accept the wheel-pin risk in §2.3. That is a real and common
case, and `mlx2coreai` handles it in one command.

### 12.3 One more consideration: is Core AI even the right destination?

Worth asking before you spend the afternoon. The community's head-to-head, **community-measured,
same M4 Max, 512 prompt / 1024 generation / 5 trials, release build, MLX side `mlx-lm 0.31.3` with
`mlx-community` 4-bit vs Core AI int8** — note that this is a *ship-config* comparison, not
iso-precision, and the repo says so:

| Model class | Core AI vs MLX | Note |
|---|---|---|
| Dense transformers (qwen3-0.6b … gemma3-12b) | **tie to +12 % for Core AI** | *"The smaller / less BW-bound the model, the bigger Core AI's win; the bigger the model, the more MLX's 4-bit erases it"* |
| **MoE**, stock lowering | **0.5–0.78× — MLX wins** | the stock gather reads **all** experts per token |
| MoE + a custom `gather_qmm` Metal kernel | **parity** | *"you reach parity (the ceiling), not a win"* |
| **MLA / exotic attention** | Core AI loses | *"the structural kernel is unsolved"* |

and the one-line summary:

> *"The difference is operator/architecture coverage on the engine — NOT the core engine."*

> ✅ **VERIFIED** — `knowledge/coreai-vs-mlx-speed.md`. **Community-measured, M4 Max, protocol
> stated above.** Not an Apple figure.

Two reverse differentials that argue *for* staying on MLX, both community-sourced:

- ⚠️ **Guided generation needs logits, and the GPU-pipelined Core AI fast path does not expose
  them.** So `@Generable` structured generation is unavailable exactly when you pick the fastest
  Core AI backend. MLX exposes logits trivially. This is a first-class architectural constraint —
  see [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md).
- **No conversion step means new-architecture turnaround in days**, versus a port. If the model you
  care about ships monthly, that compounds.

And two that argue *for* Core AI: **ANE access** (measured as throughput *parity* with MLX-GPU on
iPhone, ~+8.5 % energy, with the robust win being **GPU exclusivity** — UI and rendering do not
contend) and **AOT first-launch control**. Note what is *not* on that list: the community audit
found that *"the LLM runtime — `EngineFactory`, the pipelined engine, `LanguageBundle`, on-GPU
sampling, KV growth — is Swift code from `coreai-models` that **you compile into the app**"*, so
"nothing to bundle" is half-false.

> ✅ **VERIFIED** — `knowledge/coreai-vs-mlx-speed.md` §5, self-described as a re-check of the
> author's own earlier claims against artifacts. **Community-sourced, and it complicates Apple's
> WWDC framing** — presented here with that caveat, as the source itself asks.

---

## 13. Quick reference

### 13.1 `mlx2coreai` commands

```bash
# stateful LLM → coreai-models-style bundle (the main path)
mlx2coreai convert-mlx-lm-stateful mlx-community/Qwen3-0.6B-bf16 \
  --output qwen --max-context-length 256

# stateless mlx-lm → a single .aimodel
mlx2coreai convert-mlx-lm <model_id> --output model.aimodel --prompt "hello"

# list the children of a saved .aimodel (NOT an MLIR dumper)
mlx2coreai inspect qwen/qwen.aimodel

# regenerate docs/op_coverage.{md,json}; --validate-assets actually lowers + saves every zoo graph
mlx2coreai ops --validate-assets

# decode-throughput benchmark — pass --runtime-backend explicitly, see §8.3
python scripts/benchmark_aimodel_sampling.py qwen \
  --contexts 16,32,64,128,256 --steps 16 --runtime-backend swift
```

### 13.2 `mlx2coreai` Python API

```python
from mlx2coreai import (
    ConversionConfig, convert_mlx_to_coreai, prepare_mlx_conversion,
    run_aimodel, run_aimodel_sync, compare_coreai_outputs,
)

converted = convert_mlx_to_coreai(fn, {"x": arr}, config=ConversionConfig(optimize=True),
                                  output_path="model.aimodel")
converted.asset_path          # Path to the .aimodel directory
converted.program             # the AIProgram; str() gives MLIR text
converted.weight_manifest     # list[WeightInfo]: name/shape/dtype/storage/nbytes/downcast
converted.metadata["unresolved_extra_inputs"]   # ⚠️ check this every time (§5.1)
```

### 13.3 The LLM `.aimodel` signature

```
@main( input_ids: 1×?×si32, position_ids: 1×?×si32,
       keyCache:  L×B×Hkv×?×D,  valueCache: L×B×Hkv×?×D )
    -> ( logits: 1×?×V,  keyCache,  valueCache )

keyCache carries: MutableBuffers.buffer_mutation = "<output name of its new value>"
position_ids:     max(position_ids) MUST equal the last query token's absolute position
cache dynamic axis: 3
```

### 13.4 Bundle `metadata.json` minimum (schema 0.2)

```json
{
  "metadata_version": "0.2",
  "kind": "llm",
  "name": "<name>",
  "assets": { "main": "<name>.aimodel" },
  "language": {
    "tokenizer": "<hf id or 'tokenizer'>",
    "vocab_size": 0,
    "max_context_length": 0,
    "embedded_tokenizer": true,
    "function_map": { "main": ["main"] }
  },
  "source": { "model_definition": "mlx|torch|swift_lmir", "hf_model_id": "<id>" },
  "compression": null
}
```

### 13.5 The silent failures in this guide, in one list

| # | Failure | Section |
|---|---|---|
| 1 | `position_ids` whose maximum is not the last query position → cache written at the wrong offset, text degrades ~20–40 tokens in | §3.5 |
| 2 | Boolean attention mask **added** (`+1.0`) instead of selected → attention subtly wrong | §7.1 |
| 3 | General `conv_transpose` lowers to a **zero constant** — asset saves, output is zeros | §7.2 |
| 4 | `mx.log2` / `mx.log10` become natural log; `left_shift` / `right_shift` become bitwise AND | §7.3 |
| 5 | `allow_unknown_sources=True` (the default) invents `TensorSpec(shape=(), dtype="fp32")` | §5.2 |
| 6 | `unresolved_extra_inputs` — a weight silently becomes a required runtime input | §5.1 |
| 7 | `--no-cast-bf16-logits-to-fp16` breaks the Swift runner's hard-coded `Float16` logits view | §3.6 |
| 8 | Benchmark backend auto-selection silently changes sampling semantics; `--decode` forces Python | §8.3 |
| 9 | `compare_coreai_outputs(match_by_order=True)` compares mismatched output names positionally | §6.2 |
| 10 | `swift-lm`'s Core AI tests `return` — and therefore **pass** — without their env vars | §9.8 |
| 11 | `expectFrequentReshapes = true` on a fixed-shape graph → SIGSEGV with no error string | §10.5 |
| 12 | `_write_tokenizer` `rmtree`s an existing `bundle/tokenizer` on re-run | §3.2 |
| 13 | Losing the `AIModel` reference lets it be GC'd; the retained function then returns **garbage**, no crash | §11.4 |
| 14 | Export scripts that copy `tokenizer.json` but not `chat_template.jinja` → a bundle with no chat template | §11.3 |

### 13.6 Gate bars, side by side

| Bar | Source | Value |
|---|---|---|
| Re-authored vs source | Apple `model-authoring` | PSNR **> 70 dB** |
| Compiled vs torch | Apple `model-authoring` | PSNR **≥ 40 dB** |
| After 4-bit palettization | Apple `model-authoring` | PSNR **≥ 35 dB** |
| Stateless graph, any output | zoo Track V | **cos ≥ 0.999** |
| Autoregressive LLM | zoo Track L | **per-token cos ≥ 0.999 AND greedy argmax token-exact** |
| Re-authored module vs HF | `swift-lm` harness | `rtol=2e-3, atol=2e-3` **+ exact top-5 IDs** |
| Stateful vs stateless, same graph | `swift-lm` harness | `rtol=1e-5, atol=1e-5` |
| Captured-vs-expected, in-repo | `mlx2coreai` zoo | `atol=2e-3, rtol=5e-3` (transformer block: `5e-2 / 1e-2`) |

---

## 14. Sources and evidence ledger

### 14.1 What was read

**`lucasnewman/mlx2coreai`** — local clone, git remote `https://github.com/lucasnewman/mlx2coreai`,
branch `main`, HEAD **`059c9f3`**. All line numbers in this guide refer to that commit.

- `README.md` at HEAD, plus historical versions via `git show 5e9c7de:README.md` and
  `git show 948a3bd:README.md`
- `pyproject.toml`, `LICENSE`, `.gitignore`
- `mlx2coreai/`: `__init__.py`, `__main__.py`, `ir.py`, `conversion.py`, `cli.py`, `from_mlx.py`,
  `op_registry.py`, `lower_to_coreai.py`, `passes.py`, `dynamic_shapes.py`,
  `_composite_declaration.py`, `_convert_mlx_lm.py`, `_convert_mlx_lm_stateful.py`, `runtime.py`,
  `op_coverage.py`, `reporting.py`
- `docs/op_coverage.md`
- `scripts/benchmark_aimodel_sampling.py`, `scripts/benchmark_aimodel_sampling_coreai.swift`
- `tests/`: `conftest.py`, `test_lower_to_coreai_smoke.py`, `test_convert_mlx_lm.py`,
  `test_runtime.py`, `test_op_coverage.py`, `test_op_coverage_report.py`,
  `test_mlx2coreml_zoo_assets.py`, `model_zoo.py`, `coverage_zoo.py`
- `git log --oneline -50`; `git show 059c9f3 / 5e9c7de / dab7096`; `git show --stat d032a95 948a3bd 94bd2b9`

**`1amageek/swift-lm`** — local clone (depth 50), HEAD **`db7a802` "Add Core AI vision language
model adapter"** (2026-07-18).

- `README.md`, `PHILOSOPHY.md`, `AGENTS.md`, `Package.swift`, `Package.resolved`
- `docs/design/core-ai.md`, `docs/releases/0.11.0-alpha.1.md`, `docs/production-readiness.md`
- `Sources/SwiftLMFoundationModels/*` (the VLM adapter, all files)
- `Sources/SwiftLMCoreAI/*` (`CoreAIModelAsset`, `CoreAIModelBundle`, `CoreAIStateSession`,
  `CoreAIStatelessSession`, `CoreAIExecutableSession`, `CoreAIModelAssetError`)
- `Sources/CoreAIExport/*`, `Sources/SwiftLMIR/SwiftLMIRCLI.swift`
- `python/pyproject.toml`, `python/src/swiftlm_coreai/*` (incl. `lowering.py`, 1207 lines)
- `Tests/SwiftLMFoundationModelsTests/`, `Tests/SwiftLMCoreAITests/`, `Tests/CoreAIExportTests/`

**`john-rocky/coreai-model-zoo`** and **`john-rocky/coreai-models`** (a fork of Apple's) — local
clones. `README.md`, `AGENTS.md`, `CONTRIBUTING.md`, `PORTING.md`, `BENCHMARKS.md`,
`CATALOG_PLAN.md`, the `knowledge/` tree (`coreai-overview.md`, `aot-and-specialization.md`,
`compute-units-and-authoring.md`, `conversion-guide.md`, `compression*.md`,
`coreai-vs-mlx-speed.md`, `apple-models-bench.md`, and the two incident reports), and the two
skills.

**Apple repositories, for the destination contracts:** `apple/coreai-models`
(`export/bundle.py`, `export/_constants.py`, `export/macos.py`, `primitives/macos/cache.py`,
`CoreAIShared/Bundle/ModelBundle.swift`, `BundleKind.swift`, `FunctionMap.swift`,
`CoreAILanguageModels/Bundle/LanguageConfig.swift`, `Runtime/ModelStructure.swift`, and
`skills/skills/model-authoring/SKILL.md`); `apple/coreai-torch` (`TorchConverter`,
`composite_ops`, the stateful/IO-naming docs); `ml-explore/mlx` (`mlx/export.cpp`,
`mlx/primitives.h`, `mlx/fast_primitives.h`, `mlx/fast.cpp`,
`python/tests/test_export_import.py`).

### 14.2 Evidence classes used

| Class | Used for | Strength here |
|---|---|---|
| **Apple shipping source** | the `.aimodel` / bundle contracts, `ModelStructure`, `_composite_declaration.py`, the `model-authoring` bars | strongest available; but it is a **beta** repo |
| **Third-party source** | everything about the two bridges | compiling code, but unexecuted in our environment |
| **Apple documentation** | `SpecializationOptions.expectFrequentReshapes`'s abstract | thin — one sentence, no Discussion |
| **Community measurement** | every number in §11 and §12.3, and the device-validated `expectFrequentReshapes` crash | attributed inline, hardware/date where given |
| **MLX C++ source** | the export callback contract, the primitive `name_remap` collapses in §7.3 | strong; cross-verified against MLX's own test |

⚠️ **No WWDC transcript is cited in this guide.** Nothing in the 2026 session corpus covers these
third-party bridges, and **`coreai` has zero Apple sample-code projects** — so the strongest
evidence class this series normally leans on (compiling first-party sample projects) is simply
absent for this topic. That absence is itself the reason §6 exists.

### 14.3 Open gaps, collected

| # | Gap | What would resolve it |
|---|---|---|
| G1 | **No end-to-end numeric verification of any `mlx2coreai`-converted model** exists in our corpus | run §6.3 on macOS 27 with `coreai-core` installed |
| G2 | Whether `mlx2coreai` works against `coreai-core==1.0.0b2` (§2.3) | the ninety-second probe in §2.3 |
| G3 | The exact `coreai-core` Python signatures — `GraphOp(...)` kwargs, `coreai.slice_` argument order, `NDArray(data=, backing=)`, `function(inputs=, state=)`, `function.desc.state_descriptor(name=)` — are inferred from **call sites only** | inspect the installed wheel |
| G4 | Whether Core AI's Python `function(inputs=, state=)` mutates the passed `NDArray`s **in place** or returns new state (§6.3) | one experiment on macOS 27 |
| G5 | The return type of `mlx2coreai.run_aimodel` — `.outputs` is inferred, not read (§8.1) | read `runtime.py`'s `return` statement, or `print(type(result))` |
| G6 | `function_map` semantics beyond `{"main": ["main"]}` (§4.3) | Apple documentation, or an ANE chunked-static bundle to read |
| G7 | Whether `metadata_version "0.2"` admits `kind` values beyond `llm` / `vlm` in practice (§4.5) | a `diffusion` or `segmenter` `metadata.json` |
| G8 | Type names in the VLM engine surface — `encodeImage`'s return, `generate`'s sequence type, full `StopReason` / `SamplingConfiguration` / `KVCacheStrategy` / `ComponentKey` case lists (§9.6) | an SDK interface dump of `CoreAILanguageModels` |
| G9 | `SpecializationOptions.expectFrequentReshapes`'s **default value** (§10.6) | one line in a macOS 27 playground |
| G10 | Why `mlx2coreai`'s Swift runner sets `expectFrequentReshapes = false` on a dynamic graph (§10.4) | ask the author; nothing in the commit history says |
| G11 | Whether `mx.argmax` / `mx.argmin` really fail through the callback path, and whether `log2` / shift really collapse — both are **inferred from MLX's `name_remap` plus the bridge's tables and covered by no test** (§7.3, §7.5) | a five-line repro each |
| G12 | How Apple's official **VLM exporter** produces the three assets. `swift-lm` says *"Official `coreai-models` exporter emits `vision`, `embedding`, and `main` assets"* but contains **no invocation of it** | read `coreai_models/vlm/export.py` end to end |
| G13 | How Apple's `hoistToArg` stateful-export wrapper relates to the zoo's `remove_functionalization(ep)` (§11.5) | the two appear in different files; find one document that covers both |
| G14 | `capture_mode="dot"` is reachable via `ConversionConfig(capture_mode="dot")` but **no test exercises it end to end** | do not use it |
| G15 | Multi-entrypoint lowering (`build_coreai_programs`) is tested but **unused by any converter** — is a prefill/decode split planned for the LLM path? | ask the author |

### 14.4 Freshness

Every repo in this guide is **weeks old and moving**. `mlx2coreai`'s 11 commits are all from June
2026 and the most recent one exists because a Python binding was incomplete *"as of now."*
`swift-lm`'s Core AI work is nine commits spanning 2026-07-12 to 2026-07-18, one of which
(`b2cf3b4`) deleted 535 lines of model-family-specific Python and replaced it with a generic
lowerer. The zoo's catalogue inventory is dated 2026-07-25 and its `expectFrequentReshapes` incident
is dated 2026-07-23.

**Treat every version number, flag name and pin in this guide as a snapshot of late July 2026.**
Re-read `pyproject.toml` and `git log` before you rely on any of it. The structural claims — that
Core AI's IR is MLIR, that schema 0.2 is the interchange format, that
`MutableBuffers.buffer_mutation` is the state contract, that coverage is not parity — are the parts
most likely to still be true in six months.

[^sample-routing-policy]: The classifier and preferences are implemented in the optional
    `apple/coreai-models` package’s pinned
    [`ModelStructure.swift`](https://github.com/apple/coreai-models/blob/5ed9981303b38d5a44aa6b45509bc4f6945029f5/swift/Sources/CoreAIShared/Runtime/ModelStructure.swift#L12-L218).
    Core AI’s `.default` behavior is documented separately in
    [Managing model specialization and caching](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/docs/Managing%20model%20specialization%20and%20caching.md).
