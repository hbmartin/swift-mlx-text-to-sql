# From a Hugging Face checkpoint to a loadable LLM bundle

**Part 10 · Core AI: hardware authoring, debugging, LLM deployment · Reference 03**

**Version floor.** Everything in this guide is **27.0 and only 27.0**: `apple/coreai-models`
declares `platforms: [.macOS("27.0"), .iOS("27.0")]` and its README requires **macOS and iOS
27.0+** with **Xcode 27.0+**. There is no back-deployment story — a `.aimodel` produced here
carries a **minimum deployment target of iOS 27.0 / macOS 27.0**, which Xcode's model viewer shows
you on the asset itself. The Python side pins **`coreai-core==1.0.0b2`** (a *beta* wheel),
**`coreai-torch==0.4.1`**, **`coreai-opt==0.2.1`**, **`torch==2.9.0`**, Python **3.11**, and a
**`uv` ≥ 0.9.0** workspace. The Swift side is **swift-tools-version 6.0**, Swift language mode 6.
The compiled artifact extension is **`.aimodelc`**, produced by **`xcrun coreai-build compile`**;
the portable one is **`.aimodel`**. Both are *directories*.

> ✅ **VERIFIED** — `apple/coreai-models` `README.md:32-42` (requirements), `Package.swift`
> (`swift-tools-version: 6.0`, `platforms: [.macOS("27.0"), .iOS("27.0")]`, `swiftLanguageModes:
> [.v6]`), `python/pyproject.toml:28-43` (the four pins), `.python-version` = `3.11`, root
> `pyproject.toml` `[tool.uv] required-version = ">=0.9.0"`. Read from a local clone at HEAD
> `5ed9981` (2026-07-23). Deployment-target display in Xcode: WWDC26 session 326, lines 78-93.

---

## ⚠️ Read this before you trust a signature in this guide

**Core AI has zero Apple sample-code projects.** A crawl of Apple's tutorials index found **0
`sampleCode` entries across all 312 indexed Core AI symbols**, and `/documentation/updates/coreai`
returns 404. Unlike Parts 1–6 of this series — which are backed by compiling Apple sample projects
— there is **no first-party Xcode project you can open and diff this guide against**.

So the evidence ladder here is different, and it is stated explicitly at every claim:

1. **Shipping repo source on disk** — `apple/coreai-models`, `apple/coreai-torch`,
   `apple/coreai-optimization`, read file-by-file with line numbers. Strongest evidence available.
2. **Apple's own agent skills** inside `apple/coreai-models/skills/` — `working-with-coreai`,
   `model-authoring`, `model-compression-exploration`. These are Apple engineers' *empirical* rules
   (layouts, forbidden ops, PSNR gates) written for coding agents, and they are unusually specific.
3. **Apple documentation pages and articles.**
4. **WWDC26 session transcripts** — 324 (*Meet Core AI*), 325 (*Dive into Core AI model authoring
   and optimization*), 326 (*Integrate on-device AI models in your app*), 330 (*Optimize custom ML
   operations with Metal tensors*). Spoken narration; several claims here are already superseded by
   the shipped code, and each such conflict is flagged.
5. **Community repositories** — always labelled as such, never as Apple-official.

Two names are worth stating plainly because they recur: **`john-rocky` / `coreai-model-zoo`** is a
single-author community project (Daisuke Majima). Its measurements are frequently the *only* public
numbers for a given path, and they are genuinely valuable — but the repo self-declares that its
benchmark table is *"NOT a controlled-environment benchmark — background load and heat show up here
as real-world variance."* Every number sourced from it below is marked **community-measured** with
hardware and date. **`lucasnewman/mlx2coreai`** is a separate MIT-licensed community bridge, covered
in §15.

Anything this guide could not verify appears as a 🔴 **GAP** box that names what is unknown, what
would resolve it, and what to do meanwhile. There are no guesses inside GAP boxes.

---

## What this covers

The capstone of the Core AI parts: **one continuous path from `Qwen/Qwen3-0.6B` on Hugging Face to
`try await session.respond(to:)` in a Swift app**, with every stage's inputs, outputs, gates and
failure modes.

The path has nine stages, and the guide walks them in order:

```
acquire weights → re-author (or use a repo primitive) → verify against an oracle
    → compress → export with state_names → convert → optimize
    → save bundle (tokenizer/ + metadata.json) → AOT-compile per architecture
    → load in Swift → LanguageModelSession
```

Specifically:

- **The easy road first.** `apple/coreai-models` ships a **22-model catalog** with per-model export
  recipes and a discovery CLI. For ten LLM presets you type one command and skip stages 2–8
  entirely. §2 is that command, its full flag list, and the six ways it exits non-zero.
- **The hard road, as two divergent targets.** The same checkpoint produces **two different
  artifacts**: macOS/GPU (dynamic shapes, `nn.Linear`, fused SDPA, stateful KV) and iOS/ANE (static
  shapes, `Conv2d` projections, BC1S layout, fp16-only, externalised embeddings, four entrypoints).
  This is not a build flag — it is a different PyTorch implementation. §3–§9.
- **The gates.** Apple's PSNR ladder and the community's cosine-plus-token-exactness ladder measure
  different failures, and a model can pass one while failing the other. §6.
- **The community porting playbook**, reproduced as a runnable checklist and positioned against
  Apple's `model-authoring` skill — they are complementary, not competing. §12.
- **The hybrid/SSM wall.** Qwen3.5 GatedDeltaNet, LFM2.5 and Granite 4 Mamba2 bundles **fail at
  load** on the stock pipelined engine, and forfeit prefix caching even when patched. §13.
- **Performance context**, community-measured and clearly attributed, including the
  `COREAI_CHUNK_THRESHOLD` dial where Apple's own CLI hint is backwards on a big-RAM Mac. §14.
- **The alternative bridge**: `mlx2coreai`'s `convert-mlx-lm-stateful`, which reaches the same
  bundle shape from an MLX checkpoint without touching PyTorch. §15.

## What this does *not* cover

- **The Swift runtime in depth** — `AIModel`, `InferenceFunction`, `NDArray`, states,
  `SpecializationOptions`, `AIModelCache`. See Part 7.
- **PyTorch → Core AI conversion mechanics in general** (non-LLM graphs, custom lowerings,
  `TorchMetalKernel`). See Part 8 and Part 11.
- **Compression theory and the full `coreai-opt` config surface.** See Part 9. This guide uses
  compression as a pipeline stage and states only the LLM-specific rules.
- **MLX itself.** See Parts 12–13; the MLX→Core AI bridge in §15 cross-links Part 14.

## What you need

- **An Apple silicon Mac on macOS 27.** The runtime is OS-bound; betas count. You can do the entire
  convert / run / numerically-verify loop on the Mac alone — an iPhone is needed only for the device
  tier (AOT load, thermals, sustained tok/s, the memory ceiling).
- **Xcode 27, plus the Metal Toolchain component** (`xcodebuild -downloadComponent
  MetalToolchain`) — `aimodelc` lives inside Xcode itself, but `xcrun coreai-build` resolves from
  the component, not the app bundle (verified 2026-07-31; §10.2).
- **`uv` ≥ 0.9.0**, and a clone of `apple/coreai-models` (the compression-config YAMLs referenced by
  the registry live in the source tree and are **not** resolvable from a pip wheel).
- **Disk.** More than you think: see §4. A 7B export can transiently need 40 GB.
- Read Part 8 (conversion) and Part 9 (compression) first if you have never run
  `TorchConverter().to_coreai()`. This guide assumes you know what an `ExportedProgram` is.

---

## Contents

1. [The pipeline, end to end](#1-the-pipeline-end-to-end)
2. [The easy road: the catalog and the export CLI](#2-the-easy-road-the-catalog-and-the-export-cli)
3. [Two targets, one checkpoint](#3-two-targets-one-checkpoint)
4. [Stage 1 — acquire the weights](#4-stage-1--acquire-the-weights)
5. [Stage 2 — re-author, or use a repo primitive](#5-stage-2--re-author-or-use-a-repo-primitive)
6. [Stage 3 — the oracle and the gates](#6-stage-3--the-oracle-and-the-gates)
7. [Stage 4 — compress](#7-stage-4--compress)
8. [Stage 5 — export with `state_names`](#8-stage-5--export-with-state_names)
9. [Stages 6–8 — convert, optimize, save the bundle](#9-stages-68--convert-optimize-save-the-bundle)
10. [Stage 9 — AOT-compile per architecture](#10-stage-9--aot-compile-per-architecture)
11. [Stage 10 — load it in Swift](#11-stage-10--load-it-in-swift)
12. [The community porting playbook, as a checklist](#12-the-community-porting-playbook-as-a-checklist)
13. [The hybrid / SSM wall](#13-the-hybrid--ssm-wall)
14. [Performance context, attributed](#14-performance-context-attributed)
15. [The alternative bridge: `mlx2coreai`](#15-the-alternative-bridge-mlx2coreai)
16. [Failure catalogue](#16-failure-catalogue)
17. [Quick reference](#17-quick-reference)
18. [Sources and evidence ledger](#18-sources-and-evidence-ledger)

---

## 1. The pipeline, end to end

### 1.1 The canonical five steps, and where the real work hides

Apple's own agent skill states the pipeline in five steps, and it is worth quoting because the
numbering is what Apple's tooling and documentation assume you know:

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
> compression. Start with export, then add authoring or compression if needed (poor accuracy, poor
> performance, too large)."*

For a **vision model** that advice is right: export first, add authoring later. For an
**autoregressive LLM** it is misleading, and the reason is structural. An LLM needs a KV cache;
a KV cache is *mutable state inside the graph*; mutable state has to be declared at export time via
`state_names`; and the two supported layouts for that state differ between the GPU and the Neural
Engine. So "step 1 is optional" is only true for LLMs in the narrow sense that **someone already did
step 1 for you** — which, for the ten catalog presets, they have.

The full picture, with the stages this guide actually walks:

```
┌── stage 1 ─────────────────────────────────────────────────────────────┐
│ acquire weights            HF snapshot → local safetensors             │
└────────────────────────────────────────────────────────────────────────┘
              │
┌── stage 2 ──▼─────────────────────────────────────────────────────────┐
│ re-author                  plain-torch model built FROM safetensors,   │
│  (or use a repo primitive)  targeting GPU **or** ANE — not both        │
└────────────────────────────────────────────────────────────────────────┘
              │
┌── stage 3 ──▼─────────────────────────────────────────────────────────┐
│ oracle + Gate A(pre)       re-authored vs HF reference                 │
│                            Apple: PSNR > 70 dB · community: cos ≥.999  │
└────────────────────────────────────────────────────────────────────────┘
              │
┌── stage 4 ──▼─────────────────────────────────────────────────────────┐
│ compress                   macOS: coreai-opt Quantizer (int4/block32)  │
│                            iOS:   coreai-opt KMeansPalettizer (LUT)    │
└────────────────────────────────────────────────────────────────────────┘
              │
┌── stage 5 ──▼─────────────────────────────────────────────────────────┐
│ torch.export + decomp      run_decompositions(get_decomp_table())      │
│  + remove_functionalization  ⚠️ omit this and KV writes vanish silently │
│  + dynamic_shapes / static_shape_config                                │
└────────────────────────────────────────────────────────────────────────┘
              │
┌── stage 6 ──▼─────────────────────────────────────────────────────────┐
│ convert                    TorchConverter(...).to_coreai() → AIProgram │
│                            input_names / output_names / state_names    │
└────────────────────────────────────────────────────────────────────────┘
              │
┌── stage 7 ──▼─────────────────────────────────────────────────────────┐
│ optimize                   program.optimize()   (in place)             │
└────────────────────────────────────────────────────────────────────────┘
              │
┌── stage 8 ──▼─────────────────────────────────────────────────────────┐
│ save bundle                <name>/                                     │
│                              metadata.json   (schema "0.2")            │
│                              tokenizer/                                │
│                              <name>.aimodel/                           │
└────────────────────────────────────────────────────────────────────────┘
              │
┌── stage 9 ──▼─────────────────────────────────────────────────────────┐
│ AOT compile (device)       xcrun coreai-build compile … --architecture │
│                            → <name>.<arch>.aimodelc                    │
│                            ⚠️ then hand-edit metadata.json "assets"     │
└────────────────────────────────────────────────────────────────────────┘
              │
┌── stage 10 ─▼─────────────────────────────────────────────────────────┐
│ load in Swift              CoreAILanguageModel(resourcesAt:)           │
│                            → LanguageModelSession(model:)              │
└────────────────────────────────────────────────────────────────────────┘
```

### 1.2 What a bundle actually is

Three nested concepts, routinely confused:

| Thing | What it is | Extension |
|---|---|---|
| **Asset** | The portable, device-agnostic Core AI program: MLIR bytecode + a manifest. **A directory**, containing `main.mlirb`, `main.hash` and its own `metadata.json`. | `.aimodel` |
| **Compiled asset** | The same program with per-architecture executable artifacts baked in. **Also a directory**, holding its own unrelated `metadata.json`. | `.aimodelc` |
| **Bundle** | The *deployment unit* an LLM needs: one or more assets **plus** `tokenizer/` **plus** a top-level `metadata.json` describing them. A plain directory with no extension. | *(none)* |

> ✅ **VERIFIED** — `apple/coreai-models/README.md:30-31`: models are exported as standalone
> `.aimodel` files, *"Models needing extra resources (tokenizer, multi-component pipelines) are
> shipped as a bundle directory containing one or more `.aimodel` plus `tokenizer/` plus
> `metadata.json`."* That `.aimodel` is a directory is confirmed three independent ways in the code:
> `PreparedModel.resolveCoreAIModelURL`, `FileSize.recursiveFileSizeInBytes()`, and
> `shutil.rmtree(aimodel_path)` on overwrite in `python/src/coreai_models/export/pipeline.py`.
> `.aimodelc` being a directory with its own `metadata.json` is stated verbatim in
> `swift/Sources/CoreAIShared/Bundle/ModelBundle.swift:122-131`.

The `.aimodel` internals — `main.mlirb` (serialized MLIR, weights inline as dense resources) and
`main.hash` — are attested by two independent community sources rather than by Apple docs, so:

> 🟡 **RECONSTRUCTED** — the three-file `.aimodel` interior (`metadata.json`, `main.mlirb`,
> `main.hash`) is described identically by the community `coreai-overview.md` notes and pinned by
> `mlx2coreai`'s own test `test_smoke_asset_generation`
> (`tests/test_lower_to_coreai_smoke.py:25-29`), which asserts exactly those three children. Apple
> does not document the interior. Treat the *names* as reliable and the *format* as opaque — never
> hand-edit `main.mlirb`.

⚠️ **The single most common first mistake**: pointing a runner at the `.aimodel` when it wants the
**bundle directory**. `ModelBundle` throws `.pointedAtModelAsset` for exactly this, *before any
filesystem read*, and the code comment explains why the check has to be so early:

> ✅ **VERIFIED** — `ModelBundle.swift:122-131`: *"a compiled `.aimodelc` is itself a directory
> holding its own unrelated metadata.json, which would otherwise parse as a bogus 0.1 bundle and
> surface a misleading 'unsupported metadata_version' error."*

### 1.3 `metadata.json`, schema 0.2 — the contract between Python and Swift

This file is the seam. Python writes it; Swift reads it; if it is wrong, everything downstream is
wrong in a way that looks like a model bug.

> ✅ **VERIFIED** — writer: `python/src/coreai_models/export/bundle.py:42-74`. Emitted verbatim for
> LLM bundles:
>
> ```python
> METADATA_VERSION = "0.2"
> metadata = {
>     "metadata_version": "0.2",
>     "kind": "llm",
>     "name": name,
>     "assets": {"main": f"{name}.aimodel"},
>     "language": {
>         "tokenizer": hf_model_id,
>         "vocab_size": hf_config.vocab_size,
>         "max_context_length": hf_config.max_position_embeddings,
>         "embedded_tokenizer": True,
>         "function_map": {"main": ["main"]},
>     },
>     "source": {"model_definition": "torch", "hf_model_id": hf_model_id},
>     "compression": compression if compression != "none" else None,
>     "compilation": {"date": datetime.now().astimezone().isoformat(), "targets": []},
> }
> ```

Reader side, the parts you can trip over:

| Field | Rule | Consequence of getting it wrong |
|---|---|---|
| `metadata_version` | Must be **exactly `"0.2"`**. Absent ⇒ defaults to `"0.1"`. | `BundleError.unsupportedVersion("unsupported metadata_version '\(v)' (known: 0.2)")` |
| `kind` | `llm` \| `vlm` \| `diffusion` \| `segmenter`. **No case for speech or object detection.** | `.kindMismatch(expected:got:)` |
| `assets.main` | Filename **inside the bundle dir**. After AOT compilation you must change it to the `.aimodelc` name yourself. | `.missingAsset(key:path:)` |
| `language.tokenizer` | HF model id — used as the *fallback* when `tokenizer/` is absent. | Silent network fetch, or failure offline |
| `language.function_map` | role → **array** of physical function names. `name(for:)` returns the first. | Chunked-static (ANE) models won't resolve their `extend_*` graphs |
| `language.max_context_length` | Drives KV-cache sizing and the static-shape selector. | `StaticShapeEngine` throws `invalidState("Failed to find an extend function with the max context length of N")` |

> ✅ **VERIFIED** — `swift/Sources/CoreAIShared/Bundle/ModelBundle.swift:158-161` (version gate),
> `BundleKind.swift` (the four cases), `swift/Sources/CoreAILanguageModels/Bundle/LanguageConfig.swift`
> (the `language` block's Swift mirror), `CoreAIShared/Bundle/FunctionMap.swift` (`[String: [String]]`,
> `name(for:)` returns the first).

⚠️ **The `.missingAsset` error text is also the fix instructions**, which is a nice touch and tells
you Apple expects you to hit it:

> ✅ **VERIFIED** — `ModelBundle.swift:103-109`: *"If you compiled this model with `xcrun
> coreai-build compile`, update metadata.json "assets" to reference the compiled filename (e.g.
> modelName.architectureName.aimodelc). See models/README.md#compiled-models"*

🔴 **GAP — the `.aimodel`'s own inner `metadata.json` is undocumented.** We know it carries at least
`assetVersion` and, from `coreai-torch` 0.4.1 onward, a `producer` string
(community-observed: `{"producer": "coreai-core 1.0.0b2", "assetVersion": "2.0", "creationDate": …}`).
We do not have Apple's schema for it, and nothing in the shipped Swift reads it directly. **Resolving
this needs an Apple doc page or a `coreai-build inspect` output dump on a real asset** — the
`inspect` subcommand is now confirmed to exist, with `--metadata` on by default and `--json` output
(2026-07-31, `notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`); what remains is running it
against an actual `.aimodel`. Meanwhile:
treat the inner file as read-only diagnostic metadata, and use the **outer** bundle `metadata.json`
for anything your code depends on.

---

## 2. The easy road: the catalog and the export CLI

Before you write a line of PyTorch, check whether someone already did. For a meaningful slice of
the popular open-weight models, Apple ships the recipe.

### 2.1 What is in the catalog

The `models/` directory is the catalog — one subdirectory per model family, each with a `README.md`
and an export recipe (either a preset in the shared LLM/VLM/diffusion pipeline, or a standalone
`export.py`). **22 families**:

| Family | Kind | How it exports |
|---|---|---|
| `gpt_oss` | LLM (MoE) | `coreai.llm.export` preset |
| `mixtral` | LLM (MoE) | `coreai.llm.export` preset |
| `qwen3_moe` | LLM (MoE) | `coreai.llm.export` preset |
| `gemma3` | LLM | `coreai.llm.export` preset |
| `qwen2` | LLM | `coreai.llm.export` preset (macOS **and** iOS) |
| `qwen3` | LLM | `coreai.llm.export` preset (macOS **and** iOS) |
| `mistral` | LLM | `coreai.llm.export` preset (macOS **and** iOS) |
| `vlm` | VLM | `coreai.vlm.export` (Qwen3-VL-2B only) |
| `stable-diffusion` | Diffusion | `coreai.diffusion.export` |
| `flux2` | Diffusion | `coreai.diffusion.export` |
| `t5` · `roberta` | Encoder | standalone `models/<name>/export.py` |
| `clip` · `clap` | Embedding | standalone `export.py` |
| `whisper` · `wav2vec2` | ASR | standalone `export.py` |
| `yolo` | Detection | standalone `export.py` |
| `sam3` · `efficient-sam` | Segmentation | standalone `export.py` |
| `depth-anything` | Depth | standalone `export.py` (**macOS only**) |
| `edsr` | Super-resolution | standalone `export.py` |
| `pvt` | Classification | standalone `export.py` |

> ✅ **VERIFIED** — every row is attested by `python/src/coreai_models/model_registry.py`: the LLM
> and diffusion presets at `:73-167` and `:173-215`, and the `UtilityModel.export_script` paths at
> `:221-343` (`models/clip/export.py`, `models/clap/export.py`, `models/whisper/export.py`,
> `models/wav2vec2/export.py`, `models/yolo/export.py`, `models/efficient-sam/export.py`,
> `models/sam3/export.py`, `models/depth-anything/export.py`, `models/edsr/export.py`,
> `models/roberta/export.py`, `models/t5/export.py`, `models/pvt/export.py`). `depth-anything`
> carries `platforms=("macOS",)`. VLM: `python/src/coreai_models/vlm/export.py:76-90`.

> ⚠️ **Minor count discrepancy, flagged rather than smoothed.** A community audit of the same repo
> (john-rocky, 2026-07) describes it as *"21 export recipes"*. The most likely explanation is
> timing — SAM3's iOS re-authored recipe landed in commit `d967fa3` and the VLM path in `de896bf`,
> both recent — but we did not verify which family the community count omitted. Use the table above,
> and run `--list-models` yourself; the registry is the authority, not any prose count.

### 2.2 Discovery

```bash
# from the repo root
uv run coreai.model.registry --list-models
uv run coreai.model.registry --list-models --type llm --platform macOS
uv run coreai.model.registry --list-models --type llm --platform iOS
uv run coreai.model.registry --list-models --type utility
uv run coreai.model.registry --list-families --type llm
uv run coreai.model.registry --list-variants qwen3-0.6b --type llm
uv run coreai.model.registry --model-info qwen3-0.6b --platform iOS --json
uv run coreai.model.registry --model-info qwen3-0.6b --platform iOS --as-export-args
uv run coreai.model.registry --model-info qwen3-0.6b --platform iOS --as-output-name
```

> ✅ **VERIFIED** — `python/src/coreai_models/model_registry.py` (1051 lines, read in full). Filters:
> `--type {llm,diffusion,utility}`, `--platform {macOS,iOS}`, `--family`, `--task`,
> `--experimental`. Actions are mutually exclusive: `--list-families | --list-models |
> --list-variants SHORT_NAME | --model-info SHORT_NAME`. Formats are mutually exclusive:
> `--text` (default) `| --json | --tsv | --as-export-args | --as-output-name`.

Three behaviours worth knowing:

- `--as-export-args` **prints the exact command to run.** For a utility model it prints
  `uv run <script> --model <hf_id>`; for an LLM preset it prints the `coreai.llm.export` invocation
  with all the flags the preset implies. This is the fastest way to see what a preset *means*.
- `--as-export-args` / `--as-output-name` **require exactly one matching preset**. If a short name
  exists for both platforms and you did not pass `--platform`, the tool exits **2**.
- `--list-families`, `--model-info` and `--list-variants` all **require `--type`** (`_require_type`
  exits 2 otherwise). Only `--list-models` works without it.

### 2.3 The ten LLM presets

**macOS variants** — all `compression="4bit"` unless noted:

| short_name | HF id | precision | max ctx |
|---|---|---|---|
| `qwen2.5-1.5b-instruct` | `Qwen/Qwen2.5-1.5B-Instruct` | float16 | 32768 |
| `qwen3-0.6b` | `Qwen/Qwen3-0.6B` | float16 | 8192 |
| `qwen3-4b` | `Qwen/Qwen3-4B` | float16 | 40960 |
| `qwen3-8b` | `Qwen/Qwen3-8B` | float16 | 40960 |
| `qwen3-coder-30b-a3b-instruct` | `Qwen/Qwen3-Coder-30B-A3B-Instruct` | float16 | 262144 |
| `gemma3-4b-it` | `google/gemma-3-4b-it` | **bfloat16** | 131072 |
| `gemma3-12b-it` | `google/gemma-3-12b-it` | **bfloat16** | 131072 |
| `mistral-7b-instruct-v0.3` | `mistralai/Mistral-7B-Instruct-v0.3` | float16 | 8192 |
| `mixtral-8x7b-instruct-v0.1` | `mistralai/Mixtral-8x7B-Instruct-v0.1` | float16 | 32768 |
| `gpt-oss-20b` | `openai/gpt-oss-20b` | **bfloat16**, compression **`none`** | 32768 |

**iOS variants** — only three exist, and all default to `IOS_DEFAULT_MAX_CONTEXT_LENGTH = 4096`:

| short_name | compression | note |
|---|---|---|
| `qwen3-0.6b` | `none` + `compression_config="models/qwen3/qwen3_0_6b_mixed_4bit_8bit.yaml"` | float16, ctx 4096 |
| `qwen2.5-1.5b-instruct` | `4bit_weight_palettized_group8` | float16, ctx 4096 |
| `qwen3-4b` | `none` + `compression_config="models/qwen3/qwen3_4b_mixed_4bit_8bit.yaml"` | float16, ctx 4096 |

> ✅ **VERIFIED** — `model_registry.py:73-167`;
> `python/src/coreai_models/export/_constants.py`: `IOS_DEFAULT_MAX_CONTEXT_LENGTH = 4096`.

**iOS support is wired for exactly three architectures.** The PyTorch model-class registry maps HF
`model_type` → macOS class and (optionally) an iOS class:

| HF `model_type` | macOS class | iOS class |
|---|---|---|
| `qwen2` | `Qwen2ForCausalLM` | `Qwen2ForCausalLMForiOS` |
| `qwen3` | `Qwen3ForCausalLM` | `Qwen3ForCausalLMForiOS` |
| `mistral` | `MistralForCausalLM` | `MistralForCausalLMForiOS` |
| `gemma3_text` | `Gemma3ForCausalLM` | — |
| `gpt_oss` | `GptOssForCausalLM` | — |
| `mixtral` | `MixtralForCausalLM` | — |
| `qwen3_moe` | `Qwen3MoeForCausalLM` | — |
| `qwen3_vl` | `Qwen3VLForCausalLM` | — |

Ask for an iOS export of anything else and you get
`ValueError(f"Model '{model_type}' does not support iOS variant")`.

> ✅ **VERIFIED** — `python/src/coreai_models/models/registry.py` (the `ModelEntry` table, including
> `hf_config_attr="text_config"` + `hf_state_dict_prefix="language_model."` for Gemma-3 and
> `MODEL_TYPE_REMAPPING = {"gemma3": "gemma3_text", "qwen2_5": "qwen2"}`), and the raise at
> `python/src/coreai_models/export/pipeline.py:149-150`.

### 2.4 The export command, complete

```bash
# macOS default (4-bit, dynamic shapes)
uv run coreai.llm.export Qwen/Qwen3-0.6B

# full precision
uv run coreai.llm.export Qwen/Qwen3-0.6B --compression none

# iOS variant (static shapes, palettized, ctx 4096)
uv run coreai.llm.export Qwen/Qwen3-0.6B --platform iOS

# iOS with a different palettization group size
uv run coreai.llm.export Qwen/Qwen3-0.6B --platform iOS \
    --compression 4bit_weight_palettized_group8

# iOS with your own coreai-opt YAML
uv run coreai.llm.export Qwen/Qwen3-0.6B --platform iOS \
    --compression-config my_custom_recipe.yaml

# Gemma 3 REQUIRES bfloat16
uv run coreai.llm.export google/gemma-3-4b-it --compression none \
    --compute-precision bfloat16

# a model with no preset at all
uv run coreai.llm.export org/NewModel --experimental \
    --compute-precision float16 --compression 4bit --max-context-length 4096

# one-layer smoke build (seconds, not minutes)
uv run coreai.llm.export Qwen/Qwen3-0.6B --num-layers 1 --compression none

# see the resolved config without exporting anything
uv run coreai.llm.export Qwen/Qwen3-0.6B --dry-run
```

The full flag list:

```
model                                  registry short-name OR HuggingFace id (org/model)
--platform {macOS,iOS}                 default: macOS (or the preset's variant)
--compression NAME                     mutually exclusive with --compression-config
--compression-config PATH              coreai-opt YAML
--max-context-length INT
--compute-precision {float16,bfloat16,float32}   REQUIRED for raw HF ids
--output-dir DIR                       default <repo-root>/exports/
--output-name NAME                     without extension
--num-layers INT                       truncate to N layers (debugging)
--list-presets
--list-models
--dry-run
--verbose / -v
--overwrite
--experimental                         allow HF ids with no preset; needs --compute-precision
--disable-embedding-quantization-ios   iOS only; keeps the embedding in float32
```

> ✅ **VERIFIED** — `python/src/coreai_models/llm/export.py`, `build_parser()`, read in full.

**The six ways it exits non-zero**, all from `_resolve_export_config` (`export.py:263-368`):

1. A non-HF-id (no `/`) that isn't in the registry → `SystemExit`. If it exists for the *other*
   platform you get the helpful form: *"Error: '\<m>' is not available for \<platform>. Run
   --list-models to see options."*
2. An HF id with no preset and no `--experimental` → `SystemExit` with a hint. With
   `--platform iOS` it adds *"This model may not be suitable for iOS application due to its memory
   requirements."*
3. `--compute-precision` omitted for a model with no preset.
4. `--disable-embedding-quantization-ios` on a non-iOS platform.
5. Preset/platform mismatch → `RuntimeError("macOS quantization preset provided, but platform is
   iOS.")` or the mirror image.
6. `--max-context-length` above the checkpoint's own limit: *"--max-context-length (X) exceeds the
   model's max_position_embeddings (Y). Choose a value <= Y."*

### 2.5 Reading the output name

The output directory name encodes the recipe, and you should let it:

> ✅ **VERIFIED** — `_generate_output_name` in `export/pipeline.py`:
> `re.sub(r"[^a-z0-9]+", "_", hf_tail.lower()).strip("_")` + `_<compression>` (omitted when
> `none`) + **`_dynamic`** for macOS / **`_static`** for iOS. With a YAML config, the YAML *stem*
> replaces the compression segment.

So `qwen3_0_6b_4bit_dynamic` is unambiguous: Qwen3-0.6B, the `4bit` macOS preset, dynamic shapes.
`qwen3_0_6b_mixed_4bit_8bit_static` came from the iOS mixed-precision YAML. Keep these names. §14
contains a community finding that makes this advice load-bearing: **the same recipe on two OS
versions produced artifacts that differed by 2× in decode throughput**, so the recipe alone does not
identify an artifact.

### 2.6 Three gotchas in the easy road

⚠️ **`coreai.llm.eval` is a stub that always errors.** It is declared in `[project.scripts]`, takes
`--model` and `--tasks`, and `main()` unconditionally calls
`parser.error("Evaluation support is coming soon. See models/README.md for current capabilities.")`.
Do not build a workflow on it.

> ✅ **VERIFIED** — `python/src/coreai_models/llm/eval.py:26-31`.

⚠️ **Registry compression-config YAMLs are source-tree-only.** `_resolve_registry_compression_config`
raises `SystemExit` when you run from a wheel: *"Registry preset references \<path>, but the YAML
lives in the source tree which is unavailable in this install."* The two iOS mixed-precision presets
(`qwen3-0.6b`, `qwen3-4b`) are exactly these. **Clone the repo; don't `pip install` it.**

⚠️ **Calibration needs packages that are not installed.** `get_c4()` — the C4 calibration-data
loader used for activation quantization — imports `datasets` and `tqdm`, neither of which is in
`[project.dependencies]`. It raises `ImportError` with an install hint. Weight-only compression (the
default for every LLM preset) does not need it.

> ✅ **VERIFIED** — `python/src/coreai_models/export/compression.py`, `get_c4(tokenizer,
> max_sequence_length=2048, num_calibration_samples=16)`, which loads `allenai/c4`
> `en/c4-train.00000-of-01024.json.gz`.

---

## 3. Two targets, one checkpoint

This is the section to read twice. **The same Hugging Face checkpoint produces two different
artifacts, from two different PyTorch implementations, with two different graph contracts.** This is
expected, it is designed, and trying to unify them is the single most common wasted week.

### 3.1 The divergence, in one table

> ✅ **VERIFIED** — Apple's `model-authoring` skill,
> `apple/coreai-models/skills/skills/model-authoring/SKILL.md`, "at a glance" table, plus
> `references/neural_engine_rules.md` (479 lines) and `references/gpu_rules.md` (297 lines).

| Aspect | Neural Engine (iOS) | GPU (macOS) |
|---|---|---|
| Tensor layout | **BC1S** — `(B, H*D, 1, S)` | Standard `(B, S, D)` / `(B, H, S, D)` |
| Projections | **`nn.Conv2d(kernel_size=1)`** | `nn.Linear`, **fused QKV** |
| Embedding | `(V, 1, D)`, **externalised** out of the decode graph | standard `nn.Embedding` |
| Attention | **per-head, sequential** | **fused native SDPA** |
| Float precision | **fp16 only — no fp32 literals anywhere** | fp16 weights, fp32 intermediates OK |
| Shapes | **fully static** | dynamic supported |
| Weight conversion | `unsqueeze(-1).unsqueeze(-1)` | none |
| KV cache shape | `[n_layers, B, H_kv*D, 1, max_S]`, **seq dim 4** | `[n_layers, B, H_kv, max_S, D]`, **seq dim 3** |
| KV cache mechanism | **readonly functional I/O** — the model performs no cache writes and returns new K/V as outputs | **stateful** — `register_buffer` + in-place `slice_update`, hoisted to an argument |
| Custom Metal kernels | **no** | **yes** (`TorchMetalKernel`) |
| Compression scheme | **k-means palettization** (LUT) | **linear quantization**, int4 per-block 32 |

Two entries deserve immediate emphasis because they are the ones people get wrong:

**Precision.** *"A single Python float literal (`1.0`) creates an f32 buffer and breaks ANE
residency. Use `torch.ones(1, dtype=x.dtype)`."* And, devastatingly: ***"`.float()` is a no-op on
the ANE"*** — MPSGraph drops the cast. To get fp32 accumulation on the ANE you must use an op the
*hardware* accumulates in fp32 (the conv engine, the LayerNorm kernel), which is precisely why the
ANE path uses `Conv2d` for projections rather than `Linear`.

**The causal mask.** On the ANE it is shaped `(1, key_seq, 1, query_seq)` — **transposed relative to
the GPU** — and the masked value is **`-40000.0`, never `-inf`**, because *"Neural Engine hardware
does not handle IEEE `-inf` correctly in softmax."* The ANE also computes `K @ Q` rather than
`Q @ K^T`.

> ✅ **VERIFIED** — both quotes from `skills/skills/model-authoring/references/neural_engine_rules.md`.

### 3.2 The macOS/GPU graph contract

```
inputs:   input_ids      int32   (1, seq)        dynamic dim 1
          position_ids   int32   (1, seq+off)    dynamic dim 1
states:   keyCache               (n_layers, 1, n_kv_heads, max_seq, head_dim)   dynamic dim 3
          valueCache             (same)
outputs:  logits         float16 (1, seq, vocab)
function: "main"
```

> ✅ **VERIFIED** — `python/src/coreai_models/export/macos.py`:
> `input_names = ("input_ids", "position_ids")`, `output_names = ("logits",)`,
> `state_names = ("keyCache", "valueCache")`. The names come from
> `export/_constants.py`: `KEY_CACHE_NAME = "keyCache"`, `VALUE_CACHE_NAME = "valueCache"`.
> Cache shape and `seq_len_dim() == 3` from `primitives/macos/cache.py`.

The Swift side validates this contract *positionally*, which is a sharp edge:

> ✅ **VERIFIED** — `CoreAISequentialEngine.swift:24-32` doc comment and its init:
>
> > Expects a `.aimodel` with:
> > - **2 inputs**: `input_ids` (Int32), `position_ids` (Int32)
> > - **1 output**: `logits` (LogitsScalarType)
> > - **2 states**: `keyCache`, `valueCache` — persistent across steps, updated in-place
>
> Init asserts `descriptor.inputNames.count == 2`, `outputNames.count >= 1`,
> `stateNames.count == 2`, and `logitsDesc.scalarType == .float16` — then takes the names
> **positionally**: `inputs[0]` = input_ids, `inputs[1]` = position_ids, `states[0]` = key,
> `states[1]` = value, `outputs[0]` = logits.

⚠️ **So the *order* of your `input_names` / `state_names` tuples is load-bearing, and a swap is
invisible at export time.** Swap key and value and you get a model that loads, runs, and produces
fluent nonsense. Two guards: keep the names exactly `keyCache`/`valueCache` (Swift logs them), and
gate token-exactness (§6), which is the only thing that catches this class of defect.

### 3.3 The iOS/ANE graph contract — four entrypoints

The iOS export is not one graph. It is **four named functions in one asset**:

> ✅ **VERIFIED** — `python/src/coreai_models/export/ios.py`:
>
> ```python
> LOAD_EMBEDDINGS_FUNCTION_NAME   = "load_embeddings"     # () -> embedding_table
> GATHER_EMBEDDINGS_FUNCTION_NAME = "gather_embeddings"   # (in_new_token_ids, embedding_table) -> gathered
> EXTEND_FUNCTION_NAME            = "extend"              # decode
> PROMPT_OPT_FUNCTION_NAME        = "prompt_opt"          # prefill (set_prefill_mode(True))
> KV_CACHE_INTERLEAVE_FACTOR = 8
> ```

with these I/O names, which **must** match the Swift runner exactly:

```
inputs:        transformer_input, position_ids, in_step, causal_mask, embedding_table
states:        key_cache, value_cache
state outputs: new_k_cache, new_v_cache
output:        out_logits
```

Note the dtype details that differ from macOS and that nothing will warn you about:

- `position_ids` is **uint16** on iOS (int32 on macOS).
- `in_step` is `int32`, shape `(1,)`.
- `causal_mask` is `(1, max_context_length, 1, query_len)` **fp16**.
- KV cache is `(num_hidden_layers, 1, num_key_value_heads*head_dim, 1, max_context_length)` fp16 —
  the **BC1S** flattening of heads into the channel axis.

> ✅ **VERIFIED** — `export/ios.py`, and the Swift side's name contract in
> `CoreAIStaticShapeEngine.swift`:
> ```swift
> // MARK: I/O name contracts — models must use these exact names
> private static let logitsOutputName = "out_logits"
> private static let keyCacheName     = "key_cache"
> private static let valueCacheName   = "value_cache"
> ```

⚠️ **The two contracts use different KV-cache names.** macOS: `keyCache`/`valueCache` (camelCase).
iOS: `key_cache`/`value_cache` (snake_case). This is not a typo in this guide; it is in the shipped
source on both sides. Copying a name across targets produces a load failure, which at least is loud.

### 3.4 Static shape specialization — how four functions become dozens

The iOS export declares **one** dynamic `torch.export`, then asks Core AI to specialize it into a
grid of fixed shapes:

> ✅ **VERIFIED** — `export/ios.py`:
>
> ```python
> query_lengths = [8, 16, 64]
> cache_len = 256
> while cache_len <= max_context_length:
>     for q_len in query_lengths:
>         forward_static_cfg[f'"{cache_len}_{q_len}"'] = {
>             transformer_input: (1, q_len, 1, hidden_size),
>             position_ids:      (1, q_len),
>             causal_mask:       (1, cache_len, 1, q_len),
>             key_cache:   (num_layers, 1, kv_cached_embed_size, 1, cache_len),
>             value_cache: (num_layers, 1, kv_cached_embed_size, 1, cache_len),
>         }
>     cache_len *= 2
> coreai_program.set_static_shape_config(GATHER_EMBEDDINGS_FUNCTION_NAME, gather_static_cfg)
> coreai_program.set_static_shape_config(EXTEND_FUNCTION_NAME, forward_static_cfg)
> coreai_program.set_static_shape_config(PROMPT_OPT_FUNCTION_NAME, forward_static_cfg)
> ```

At `max_context_length = 4096` that is cache lengths {256, 512, 1024, 2048, 4096} × query lengths
{8, 16, 64} = **15 specializations each** of `extend` and `prompt_opt`, plus 3 of
`gather_embeddings`. The resulting physical function names are `extend_<cacheLen>_<qLen>`,
`prompt_opt_<cacheLen>_<qLen>`, `gather_embeddings_<qLen>` — and *those names are the API*. Apple's
own Neural-Engine rules state the design principle plainly: *"All functions compile from **one
dynamic `torch.export`** via Core AI shape specialization."*

The Swift runtime parses those names back out:

> ✅ **VERIFIED** — `CoreAIShared/Runtime/ModelStructure.swift`. Detection order: `extend*` **plus**
> `load_embeddings` → `.chunkedStatic(batchSize:)` with the batch parsed from
> `extend_<context>_<batch>` at index 2; `image_encode`+`text_encode`+`detect` →
> `.multiFunctionSegmenter`; `main` → `.dynamic`; otherwise `.dynamic` with a warning.

### 3.5 The optional sample loader maps structure to a compute-unit preference

The folk model "iOS means Neural Engine" is wrong in an important way. In Apple’s optional
`coreai-models` loader, **the Swift runtime probes the asset's function names and derives a
compute-unit *preference* from the structure**. This is that package’s policy, not a Core AI
framework naming contract; direct `AIModel` callers supply their own options.[^sample-routing-policy]

> ✅ **VERIFIED** — `ModelStructure.swift`:
>
> ```swift
> case .chunkedStatic, .multiFunctionSegmenter:
>     SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
> case .dynamic:
>     var opts = SpecializationOptions(preferredComputeUnitKind: .gpu)
>     opts.expectFrequentReshapes = true
> ```

Consequences:

- A **chunked-static** asset gets the ANE preference *wherever it runs*, including on a Mac.
- A **dynamic** asset gets the GPU preference *even on an iPhone* — which is exactly how the
  community runs 4B-class models on device (§10).
- `preferredComputeUnitKind` is a **preference**, not a lock. Unsupported ops are placed elsewhere,
  silently. Apple's own guidance in the `working-with-coreai` skill is to *"use `.default`
  specialization options unless you deliberately pin a compute unit."*

> ✅ **SDK-verified (upgraded from 🟡 on 2026-07-29)** — the full public surface of
> `SpecializationOptions` is now read from the macOS 27.0 beta interface
> (`CoreAIDelegates-27.0-macos.swiftinterface:89-106`): statics `.default` and `.cpuOnly`, exactly
> one initializer `init(preferredComputeUnitKind: ComputeUnitKind)`, get-only
> `allowedComputeUnitKinds: Set<ComputeUnitKind>` and `preferredComputeUnitKind: ComputeUnitKind?`,
> and the settable `expectFrequentReshapes: Bool`. `ComputeUnitKind` is `.cpu`/`.gpu`/
> `.neuralEngine` plus static `availableKinds` (`:72-88`). The Python mirror exposes `cpu_only()`,
> `default()` and `from_preferred_compute_unit_kind(ComputeUnitKind.gpu()/.ane()/…)`. See Part 7
> for the runtime treatment.

⚠️ **SILENT FAILURE — a segmenter or speech asset crashes the auto-detect path rather than throwing.**
`EngineFactory.autoDetectVariant` calls `preconditionFailure` for any structure other than
`.chunkedStatic` / `.dynamic`. The *compatibility-check* path throws a clean error; the *auto* path
crashes. If you are writing generic loading code, pass an explicit `variant:` rather than relying on
auto-detection.

> ✅ **VERIFIED** — `swift/Sources/CoreAILanguageModels/InferenceEngines/EngineFactory.swift`;
> the valid variant strings are `auto`, `coreai-sequential`, `coreai-pipelined`, `static-shape`, and
> an unknown string throws *"Unknown variant '\<x>'. Valid: auto, coreai-sequential,
> coreai-pipelined, static-shape"*.

### 3.6 So: which target do you build?

| If you need… | Build | Because |
|---|---|---|
| A Mac app, any size model, best throughput | **macOS / GPU / dynamic** | Fused SDPA, dynamic KV growth, custom Metal kernels available, no shape grid |
| An iPhone app, small model, best energy | **iOS / ANE / chunked-static** | The ANE is the energy-efficient lane and cannot be reached any other way |
| An iPhone app, 4B-class model | **macOS-style dynamic graph, AOT-compiled for the iOS GPU** | Community-verified: the ANE path fails at this size (§10.4) |
| Guided generation / `@Generable` | **anything but the GPU-pipelined engine** | The pipelined engine samples on-GPU and never surfaces logits (§11.4) |
| Both platforms | **Two exports.** | There is no single artifact. Ship two. |

The third row is the one that surprises people, and it is community-derived rather than
Apple-stated. It is treated in full in §10.4.

---

## 4. Stage 1 — acquire the weights

The least interesting stage, and the one that most often ends an afternoon.

### 4.1 Disk, and the transient peak

Two effects compound:

- **Some HF repos ship the weights twice.** `mistralai/Mistral-7B-Instruct-v0.3` downloads **27 GB,
  not 15**: the repo carries `transformers` shards *and* a redundant `consolidated.safetensors`
  (14 GB), and the export fetches everything.
- **The exporter needs scratch space of roughly one extra copy of the fp16 weights** while
  serializing.

> **Community-measured** — john-rocky, `apple-models-bench.md`, M4 Max 128 GB / macOS 27 beta, 2026-07.
> *"On a tight disk this ENOSPCs mid-export."* Attribute as community observation; the underlying
> facts (what the HF repo contains, that serialization needs scratch) are checkable yourself with
> `hf download --dry-run` and `du`.

Budget **~4× the final artifact size** in free disk for a first export of a 7B-class model.

### 4.2 Gated models

`google/gemma-3-*`, `stabilityai/stable-diffusion-3.5-medium` and `facebook/sam3` are gated. Accept
the license on the Hub, then:

```bash
brew install hf
hf auth login --token <YOUR_TOKEN>
```

> ✅ **VERIFIED** — stated in `models/sam3/README.md` and the gemma3/SD3 model READMEs in
> `apple/coreai-models`.

### 4.3 Hugging Face transfer pathologies

Two community reports **contradict each other**, and both are reproducible-looking, so this guide
gives you both rather than picking:

| Source | Claim |
|---|---|
| `conversion-guide.md` (john-rocky, 2026-07) | **`HF_HUB_DISABLE_XET=1` does NOT bypass Xet** — `resolve/main/<file>` still 302-redirects to `cas-bridge.xethub.hf.co`. **`curl -C -` (resume) HANGS the Xet bridge** (the `Range:` header stalls it). Best remedy: `HF_XET_HIGH_PERFORMANCE=1 hf download <repo>` — parallel chunks, resume at chunk granularity. |
| `cross-runtime-quality-benchmarking.md` and `dense-int4km-…md` (same author, different dates) | HF python downloads stall (esp. near 99 %); **fix = `HF_HUB_DISABLE_XET=1`**, or `curl -C -` against `resolve/main/<file>` checking `x-linked-size`. Cited to `xet-core #789` / `huggingface_hub #3580`. |

> 🔴 **GAP — we cannot resolve which is right.** The two documents are by the same community author,
> at different dates, and disagree about whether `HF_HUB_DISABLE_XET=1` works and whether `curl -C -`
> hangs. Nothing Apple publishes touches this. **Resolving it needs a controlled repro against the
> current Hub.** Meanwhile, the safe default that both documents agree on: **let one
> `hf download` run finish** — *"Restarting `snapshot_download` repeatedly LOSES `.incomplete`
> progress"* — and **never mix Xet and non-Xet attempts for the same file**, because the cache
> snapshot symlink can end up pointing at a **sparse, incomplete blob** whose apparent size is right
> while `du` shows it is not. That last one is a genuine silent failure: you get a file that looks
> complete and is not.

### 4.4 Two loading paths, and why they differ

Once the weights are local, the export pipeline loads them differently per target:

> ✅ **VERIFIED** — `export/pipeline.py`, `_async_export_model` step 4: **macOS uses
> `model_class.from_hf_memory_efficient(...)`** with a `tempfile.TemporaryDirectory(prefix=
> "coreai_export_")` mmap directory; **iOS uses `from_hf(...)`** (full RAM). The code comment gives
> the reason: *"the iOS variant keeps the legacy full-RAM path since its palettization flow has not
> been validated against streaming weight loading."*

Practical consequence: **an iOS export of a large model needs the whole checkpoint resident.** That
is one more reason the iOS presets stop at 4B.

The streaming loader itself is worth knowing about if you write your own model class — it is a
per-layer safetensors reader built on meta-device init:

> ✅ **VERIFIED** — `python/src/coreai_models/models/base.py` module-level helpers:
> `move_model_to_disk`, `_save_and_mmap_safetensors`, `_resolve_safetensors_files`,
> `_build_safetensors_key_index`, `_load_tensors_for_keys`. Apple's `gpu_rules.md` describes the
> pattern as *meta-device init + `load_state_dict(..., assign=True)` + per-layer safetensors
> streaming*.

---

## 5. Stage 2 — re-author, or use a repo primitive

### 5.1 Why re-authoring exists at all

WWDC26 session 325 defines it:

> ✅ **VERIFIED** — session 325, lines 206-212 (verbatim): *"for more advanced optimizations,
> especially for iOS, you need to go further and **rewrite the entire model with a specific target in
> mind. We refer to this process, as model re-authoring.** Re-authoring typically involves replacing
> many aspects of this computational graph. This may imply using **different operations, novel tensor
> layouts, and even modifying the interfaces of the model**. Essentially, this is a **completely
> different implementation of the source code**."*

The community porting doc gives the sharper operational reason:

> **Community practice** — `john-rocky/coreai-model-zoo`, `PORTING.md:23-39`: *"You do this instead
> of exporting the Hugging Face modeling file because HF code carries training-time baggage (dynamic
> control flow, complex-number RoPE, optional branches) that either fails to trace or lowers badly.
> Re-authoring sounds heavier than it is: for a ViT it is an afternoon."*

And the rule that follows from it, which is the single most transferable idea in the community
material:

> **Community practice** — `AGENTS.md:65-79`, trap #2: ***"Re-authoring from the HF `modeling_*.py`
> instead of the weights.** The modeling file has branches that never run for this checkpoint, and
> hides ones that do."*

Re-author **from `model.safetensors`**, using the modeling file only as a reading aid. The weights
are ground truth; the Python is a superset of what your checkpoint uses.

### 5.2 Don't write it if Apple already did

Before writing anything, check `python/src/coreai_models/primitives/`. There are two parallel
libraries, one per target:

> ✅ **VERIFIED** — `primitives/macos/__init__.py` `__all__`: `KVCache`, `SSMState`, `MLP`,
> `RMSNorm`, `RMSNormGated`, `RMSNormPlusOne`, `RoPE`, `YarnRoPE`, `initialize_rope`, `SDPA`,
> `SwitchGLU`, `SwitchLinear`, `SwiGLU` (+ `cache_scatter.py` for VLM embedding scatter).
>
> `primitives/ios/__init__.py` `__all__`: `BidirectionalSDPA`, `GELUReauthored`, `gelu_ane`,
> `GatherEmbeddings`, `LoadEmbeddings`, `KVCacheHandler`, `LayerNormReauthored`, `MLP`, `RMSNorm`,
> `RoPECache`, `SDPA`, `quantize_per_tensor`, `dequantize_per_tensor`.

Note the shape of that list: the iOS side has `LayerNormReauthored`, `GELUReauthored` and
`gelu_ane` because **the ANE needs different implementations of the same maths**, not because
someone was being tidy.

The macOS `KVCache` is the one you will actually touch:

```python
class KVCache:
    HF_K_BUFFER_NAME = "_full_cached_k"
    HF_V_BUFFER_NAME = "_full_cached_v"

    @classmethod
    def seq_len_dim(cls) -> int: return 3

    @classmethod
    def create_cache_tensors(cls, config, dtype=torch.float32):  # -> (k, v)
        ...  # shape (n_layers, 1, n_kv_heads, max_seq_len, head_dim)

    @classmethod
    def from_dimensions(cls, n_layers, n_kv_heads, max_seq_len, head_dim): ...

    def update_and_fetch(self, layer_idx, offset, k, v, seq_len=None, query_len=None):
        ...  # -> (k_out, v_out)
```

> ✅ **VERIFIED** — `python/src/coreai_models/primitives/macos/cache.py`, read in full.
> `update_and_fetch` uses `mutable_slice_update` with explicit `torch._check` /
> `torch._check_is_size` guards so `torch.export` can trace it, and it supports cross-device use by
> round-tripping when `k.device != cache.device`.

`SSMState` is the equivalent for Mamba-style running state, with `update_states(layer_idx,
new_state)`. Its existence in Apple's own primitives is important context for §13: Apple ships the
*authoring* primitive for state-space models while the *Swift engine* rejects the resulting bundles.

### 5.3 Apple's convention: `from_source_model`

Apple's `model-authoring` skill mandates a specific constructor convention on every re-authored
model — config-driven construction with **no hardcoded constants**, plus an explicit
`load_weights_from`:

> ✅ **VERIFIED** — `skills/skills/model-authoring/SKILL.md:103-119`. The base class in the repo
> matches: `BaseForCausalLM(torch.nn.Module)` exposes `_init_model`, `_mutate_state_dict`,
> `_get_reauthored_config`, `from_hf`, `from_hf_memory_efficient`, `from_pretrained`,
> `_reassign_cache`, `half/bfloat16/float/to`, and a `cast_logits_bfloat16_to_float16` decorator.
> `BaseForCausalLMForiOS(BaseForCausalLM)` adds `__init__(config, model_device,
> disable_embedding_quantization=False)` and **`set_prefill_mode(prefill_mode: bool)`**.

That `set_prefill_mode` is the mechanism behind the iOS `prompt_opt` entrypoint: the *same* module,
exported twice, once with prefill mode on (returns updated KV, no logits) and once off (returns
logits + updated KV).

### 5.4 GPU authoring rules that change the output, not just the style

From Apple's `gpu_rules.md`, the ones with measurable consequences:

- **Fused QKV**: `nn.Linear(dim, n_heads*hd + 2*n_kv_heads*hd, bias=False)`, with Q/K norm and RoPE
  applied *before* splitting.
- **MLP computes `up_proj` before `gate_proj`** — Apple's own note: *"reversed from many reference
  implementations but yields better GPU utilization."*
- **`mutable_arg_action="hoistToArg"`** in `LegalizeToCoreOptions` is how the stateful buffer becomes
  a graph argument.
- **MoE** goes through `SwitchLinear` / `SwitchGLU` / `GatherMM`, with expert weights stacked to
  `(1, num_experts, out, in)`.

> ✅ **VERIFIED** — `skills/skills/model-authoring/references/gpu_rules.md` (297 lines).

> 🔴 **GAP — how `hoistToArg` and `remove_functionalization` relate is unverified.** Apple's skill
> prescribes a stateful export wrapper using `register_buffer` + `hoistToArg`; the community porting
> doc prescribes in-graph mutable state via `slice_update` + `remove_functionalization(ep)`. These
> are plausibly two layers of one mechanism rather than alternatives, but **we did not find both
> named in the same file this session**, and we will not guess. **Resolving it needs the
> `coreai-torch` `LegalizeToCoreOptions` documentation or source.** Meanwhile the safe default is
> the one that is *demonstrably shipping*: use `apple/coreai-models`' `KVCache.update_and_fetch` +
> `remove_functionalization(ep)` as in `export/macos.py`, which is the code path that produced every
> published Apple LLM bundle.

### 5.5 ANE authoring rules that change correctness

From `neural_engine_rules.md`, the high-leverage set. These are not style preferences; each one has a
documented failure attached.

| Rule | Failure if ignored |
|---|---|
| Max tensor **rank 5** | Rank-6 tensors are rejected; the runtime falls back to GPU |
| Last axis contiguous and **64-byte aligned**; keep ≥ 32 fp16 elements | A singleton last axis costs **32× memory at fp16, 64× at int8** |
| **`Conv2d(1×1)` not `nn.Linear`** | Linear falls off the ANE; you also lose fp32 accumulation |
| Causal mask `(1, key, 1, query)` with **`-40000.0`** | ANE softmax mishandles IEEE `-inf` |
| Precompute RoPE cos/sin **outside** the graph, pass as `(1, head_dim, 1, S)` | Indexing a 2-D table with `position_ids` produces `gather_nd` with rank-3 output, which the ANE rejects |
| **Cache the post-RoPE key** (`key_rope`), not raw `new_k` | *"the next call attends to stale non-RoPE-encoded keys → **PSNR collapses to ~20 dB**"* |
| Conv stride factors of 2 and 3 only (4, 6, 8, 9, 12, 16, 24, 32); palettized kernels ≤ 2 | Falls back off the conv engine |
| Chunked prefill with `CHUNK = 64`; seam offset = `chunk_start`, not `chunk_end` | fp16 drift; Apple's note: *"For prefill > ~50 tokens, use chunked prefill (S_q=64) or fp32 KV cache tensors in Python"* |

> ✅ **VERIFIED** — all rows from
> `skills/skills/model-authoring/references/neural_engine_rules.md` (479 lines).

The BC1S conversions, verbatim from the same file, because getting these transposes wrong is the
most common cause of a "works in torch, garbage on device" report:

```python
# (B, S, D) → (B, D, 1, S)
x = x.permute(0, 2, 1).unsqueeze(2)
# and back
x = x.squeeze(2).permute(0, 2, 1)

def gpu_to_bc1s(x):
    B, H, S, D = x.shape
    return x.permute(0, 1, 3, 2).reshape(B, H * D, 1, S)

def bc1s_to_gpu(x, n_heads, head_dim):
    B, _, _, S = x.shape
    return x.reshape(B, n_heads, head_dim, S).permute(0, 1, 3, 2)
```

Per-head attention on the ANE is expressed as two einsums — note the operand order, which is `K @ Q`
not `Q @ K^T`:

```python
attn = torch.einsum("bchq,bkhc->bkhq", q_h, k_kv)
out  = torch.einsum("bkhq,bkhc->bchq", attn, v_kv)
```

And the `Linear` → `Conv2d` weight surgery, from Apple's shipped SAM3 iOS re-author (the same
transformation applies to an LLM's projections):

> ✅ **VERIFIED** — `python/src/coreai_models/models/ios/sam3/image_encoder.py`:
>
> ```python
> def _linear_to_conv2d(linear: nn.Linear) -> nn.Conv2d:
>     """Convert ``nn.Linear`` to ``nn.Conv2d(1x1)`` for BC1S layout."""
>     in_features, out_features = linear.in_features, linear.out_features
>     has_bias = linear.bias is not None
>     conv = nn.Conv2d(in_features, out_features, 1, bias=has_bias)
>     conv.weight.data = linear.weight.data.reshape(out_features, in_features, 1, 1)
>     if has_bias:
>         conv.bias.data = linear.bias.data
>     return conv
> ```

### 5.6 ⚠️ SILENT FAILURE — `nn.functional.silu` on the ANE

This one is worth its own box because it is the archetype: **the model converts, loads, and runs, on
the wrong compute unit, with no diagnostic.**

> ✅ **VERIFIED** — `skills/skills/model-authoring/references/common_issues.md` (176 lines):
> `nn.functional.silu(x)` lowers to **`mps.cast(→f32) + mps.swish(f32) + mps.cast(→f16)`** — three
> ops the Neural Engine cannot execute. The prescribed fix is to write the activation out by hand:
>
> ```python
> # NOT: torch.nn.functional.silu(gate_pre)
> gate = gate_pre * torch.sigmoid(gate_pre)
> ```

Nothing throws. The three ops are simply placed on the GPU or CPU, the graph is partitioned around
them, and your "ANE model" is now a mostly-GPU model with extra transfer overhead. The only way to
see it is a compute-unit profile (Core AI Instruments) or a suspiciously small speedup.

The same file carries a companion for `torch.tanh` (used in AdaLN):
`2 * torch.sigmoid(2 * x) - 1`.

### 5.7 More from `common_issues.md`, the debugging cookbook

Apple's own catalogue of traps, all ✅ **VERIFIED** from
`skills/skills/model-authoring/references/common_issues.md`:

- **`si32`, not `i32`**, for input JSON descriptors.
- Filter `torch.export` input specs to `{InputKind.USER_INPUT, InputKind.BUFFER}` before naming
  them — otherwise your `input_names` list is off by the number of parameters.
- **At the `coreai-models` Python/PyTorch bridge, call `.contiguous()` before wrapping a tensor in
  `NDArray`** — that wrapper reads raw backing memory as contiguous. Swift `NDArray` separately
  supports explicit strides, so this is a bridge rule rather than a framework-wide one.
  [^stride-scope]
- **Output dict key order is non-deterministic** — identify outputs by shape, not by index.
- `InferenceFunction.__call__` uses `**kwargs`: `await runner(**inputs)`, not `runner(inputs_dict)`.
- If HF's `post_init()` fails on a missing `rope_parameters`, patch `ROPE_INIT_FUNCTIONS["default"]`.
- If the model compiles but runs on CPU:
  `xcrun coreai-build compile model.aimodel --preferred-compute neural-engine`.

---

## 6. Stage 3 — the oracle and the gates

### 6.1 Why this stage exists

The defining property of this pipeline is that **most defects do not throw**. A conversion that
loses a KV write, a palettizer that skips a layer, a transposed mask, a stale cache: all of these
produce an artifact that loads, runs at full speed, and emits fluent text that is subtly or
catastrophically wrong. The community porting contract names this directly:

> **Community practice** — `john-rocky/coreai-model-zoo`, `AGENTS.md:13-21`: *"Porting is not format
> conversion. There is no `convert(model)` that works. … An agent that reaches for a one-shot
> converter produces a bundle that loads, runs, and emits plausible garbage — **the most expensive
> failure mode here, because it looks like success**."* And the single rule: *"the oracle comes
> first, and every stage gates against it … **A port without gates is a guess with extra steps.**"*

### 6.2 Build the oracle first

Before you write any Core AI code, capture what correct looks like — from the **unmodified HF
model**, in fp32, to a file:

```python
# oracle.py — run this against the stock HF model, before touching Core AI.
import numpy as np, torch
from transformers import AutoModelForCausalLM, AutoTokenizer

MODEL_ID = "Qwen/Qwen3-0.6B"
PROMPT   = "The capital of France is"   # deterministic; see §6.7
N_STEPS  = 32

tok   = AutoTokenizer.from_pretrained(MODEL_ID)
model = AutoModelForCausalLM.from_pretrained(MODEL_ID, torch_dtype=torch.float32).eval()

ids = tok(PROMPT, return_tensors="pt").input_ids          # (1, P)
per_step_logits, per_step_argmax = [], []

with torch.no_grad():
    cur = ids
    past = None
    for step in range(N_STEPS):
        out = model(input_ids=cur, past_key_values=past, use_cache=True)
        past = out.past_key_values
        last = out.logits[:, -1, :]                        # (1, V)
        per_step_logits.append(last.float().cpu().numpy())
        nxt = int(last.argmax(-1))
        per_step_argmax.append(nxt)
        if nxt == tok.eos_token_id:
            break
        cur = torch.tensor([[nxt]])

np.savez(
    "oracle.npz",
    prompt_ids=ids.cpu().numpy(),
    logits=np.concatenate(per_step_logits, axis=0),        # (N, V)
    argmax=np.array(per_step_argmax, dtype=np.int64),
)
print("oracle:", tok.decode(per_step_argmax))
```

Two details the community doc insists on, and both are the difference between a gate that catches
things and one that doesn't:

> **Community practice** — `PORTING.md:86-109`: *"Track L: a fixed prompt → **per-step logits (or at
> minimum per-step argmax ids) for a few dozen greedy steps.** **Per-step matters: an AR loop can
> look fine at step 1 and drift by step 30.**"* And, for anything with host preprocessing: *"Save
> the **preprocessed tensor** too"*, because host processing gets gated against it separately.

For an LLM the "preprocessed tensor" is the **token ids**. Save them. Tokenizer divergence between
your Python harness and the Swift app's `swift-transformers` is a real and common failure, and if you
only stored the prompt *string* you cannot tell it apart from a model bug.

### 6.3 Two gate ladders, and why you need both

Apple and the community measure different things. Neither is wrong; they catch different bugs.

| | Apple `model-authoring` skill | Community `PORTING.md` |
|---|---|---|
| Metric | **PSNR (dB)** | **cosine similarity + greedy token-exactness** |
| Re-authored vs source | **> 70 dB** (investigate < 60) | Track V: **cos ≥ 0.999** per output tensor |
| ANE-layout vs GPU-layout | **> 70 dB** | — |
| Compiled vs torch | **≥ 40 dB** (fp16 on-device: > 50 dB, investigate < 40) | Track L: **per-token cos ≥ 0.999 on logits AND greedy argmax token-exact** |
| After 4-bit palettization | **≥ 35 dB** (~40 dB typical, investigate < 30) | *"read the generations"* |
| float32 end-to-end | **> 70 dB** (investigate < 60) | — |

> ✅ **VERIFIED (Apple side)** — `skills/skills/model-authoring/SKILL.md:94-99` and the PSNR
> acceptance table in `skills/skills/working-with-coreai/SKILL.md`.
>
> **Community practice (right column)** — `PORTING.md:184-211`.

**The gap between them matters.** A PSNR ≥ 40 dB "compiled vs torch" pass can coexist with a
non-token-exact LLM — high average fidelity across a 151,936-wide logit vector says nothing about
whether the *argmax* moved, and the argmax is what your user reads. Apple's skill has no per-token
autoregressive-drift gate; the community's is built specifically to catch it. Conversely, the
community's cosine gate on the final logits will not tell you *which layer* broke, and Apple's
layer-wise PSNR (via the debugger, §6.6) will.

*(That reading of the two documents is this guide's synthesis, not a claim either author makes. It
is flagged as such.)*

Run both. They cost minutes.

### 6.4 Gate A — graph parity

Load the converted asset in Python and compare it to the oracle, **on the CPU**:

```python
# gate_a.py
import asyncio, numpy as np
from pathlib import Path
import coreai.runtime as rt

BUNDLE = Path("exports/qwen3_0_6b_4bit_dynamic/qwen3_0_6b_4bit_dynamic.aimodel")

async def main():
    oracle = np.load("oracle.npz")
    prompt_ids = oracle["prompt_ids"].astype(np.int32)
    ref_logits = oracle["logits"]
    ref_argmax = oracle["argmax"]

    # cpu_only() is the PARITY option. See the warning below.
    model = await rt.AIModel.load(BUNDLE, rt.SpecializationOptions.cpu_only())
    fn = model.load_function("main")

    n_prompt = prompt_ids.shape[1]
    cur = prompt_ids
    pos = np.arange(n_prompt, dtype=np.int32)[None, :]
    got_argmax, cos_per_step = [], []

    for step in range(len(ref_argmax)):
        outs = await fn({
            "input_ids":    rt.NDArray(np.ascontiguousarray(cur)),
            "position_ids": rt.NDArray(np.ascontiguousarray(pos)),
        })
        logits = outs["logits"].numpy()[:, -1, :].astype(np.float64)   # (1, V)
        ref = ref_logits[step].astype(np.float64)[None, :]
        cos = float((logits * ref).sum() / (np.linalg.norm(logits) * np.linalg.norm(ref)))
        cos_per_step.append(cos)
        tok = int(logits.argmax(-1))
        got_argmax.append(tok)
        if tok == int(ref_argmax[step]) and step + 1 < len(ref_argmax):
            cur = np.array([[tok]], dtype=np.int32)
            pos = np.array([[n_prompt + step]], dtype=np.int32)
        else:
            break

    exact = got_argmax == list(ref_argmax[:len(got_argmax)])
    print(f"token-exact: {sum(a == b for a, b in zip(got_argmax, ref_argmax))}/{len(ref_argmax)}")
    print(f"min per-step cosine: {min(cos_per_step):.6f}")
    assert min(cos_per_step) >= 0.999, "GATE A FAILED (cosine)"
    assert exact, "GATE A FAILED (token divergence)"
    print("GATE A PASS")

asyncio.run(main())
```

Four API facts that this snippet depends on, each verified:

> ✅ **VERIFIED** — `apple/coreai-torch` `docs/coreai-core/tutorials/run-an-aimodel.ipynb`:
> **`AIModel.load` is `async`; `load_function` is *sync*; calling the function is `async`.** There
> are two loading forms — `AIModelAsset.load(path)` + `async with asset.executable() as model:`
> (resource-managed), and the one-shot `await AIModel.load(path)` used above *"when you want a
> long-lived model handle without the `async with` block."*
>
> ⚠️ **FOOTGUN, verbatim from the same notebook**: *"Materialize the result inside the block — **the
> model's backing buffers are only guaranteed valid until the context exits**."* Call `.numpy()`
> before leaving `async with`.
>
> Default entrypoint name is **`"main"`**. Outputs come back keyed by **output name**.
> `NDArray` *"accepts a NumPy array, a PyTorch tensor, or a Python list, wrapping the data without a
> copy where possible"* — which is exactly why `.contiguous()` / `np.ascontiguousarray` matters.

⚠️ **`cpu_only()` is a parity option, never a performance option.** Two independent statements:

> **Community practice** — `PORTING.md:184-211`: *"`cpu_only()` for **parity** (fp16 GPU/ANE adds
> harmless but distracting noise); anything you **time** must use `SpecializationOptions.default()`
> — it is ~an order of magnitude faster and that is what ships."* And `AGENTS.md` trap #4: *"Timing
> with `cpu_only()` — that is the parity option, not a performance option."*
>
> **Community-measured**, `conversion-guide.md`: TripoSplat DiT, **24.2 s → 2.6 s per call
> (~9.3×)** switching `cpu_only()` → `default()`, *"and cos vs cpu still 1.000000"*. Mac; exact
> model/OS not stated.

⚠️ **SILENT FAILURE — passing `None` where an options object is expected.** Two related community
findings, both worth guarding against:

> **Community-measured** — `conversion-guide.md`: *"`AIModel.load(path, None)` trips `RuntimeError:
> MPSGraph Unresolved symbol (prepare/initialize)` on the GPU path"* — pass an **explicit**
> `SpecializationOptions.default()` or `.cpu_only()`, never `None`. That one at least throws. The
> next one does not: *"**Keep the `AIModel` reference alive** in a persistent multi-call runner —
> storing only the `load_function` lets the model get GC'd and the function then returns **GARBAGE**
> (no crash, just wrong output → looks like a conversion bug). Hold `self.models[name] = m`."*

That is the purest example of this stack's failure mode in the whole corpus: a Python garbage
collection producing what reads as a numerical bug in your model.

### 6.5 Gate B — host processing, in NumPy, before Swift

The second gate is the one people skip and then spend a week on.

> **Community practice** — `PORTING.md:184-211`: everything the app will compute — *"image
> resize/normalize, mel spectrograms, detokenization, samplers"* — is implemented **in NumPy first**,
> as the exact algorithm the Swift will use, gated end-to-end against the oracle's preprocessed
> tensors, **and only then** translated to Swift. The rationale, verbatim: *"host-side mismatches are
> the #1 source of 'the graph is perfect but the output is garbage', and they are unfindable once
> the only implementation is inside an app."*

For an LLM, Gate B is:

1. **Tokenization**: your NumPy harness's ids vs the oracle's `prompt_ids`. Exact match required.
2. **Chat templating**: the rendered prompt string, byte-for-byte. See §6.8 — this is where a whole
   category of published bundles was broken.
3. **Sampling**: greedy is trivially checkable; temperature/top-p need a seeded RNG comparison.
4. **Detokenization**, including the incremental case — see §11.5 for why this is harder than it
   looks.

The checkpoint the community doc sets: *"a `gate_*.py` script prints PASS from a clean run with no
manual steps — **This script goes in your PR; it is the reviewable artifact.**"*

### 6.6 Apple's tooling: `save_intermediates` and the Core AI Debugger

Apple's answer to "which layer broke" is a standalone macOS app plus a Python capture API.

> ✅ **VERIFIED** — `coreai_torch/debugging/torch_utils.py:905-913`, exact signature:
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
> - `coreai_program` — *"Optional `AIProgram` to extract source info from. If provided, variable
>   information from source locations will be added to the metadata."* ← this is what links
>   intermediates back to Python source lines in the debugger.
> - `enable_autocast` — *"Set to True to handle mixed precision models and avoid dtype mismatch
>   errors."*
> - `model_name` — creates `{model_name}.aimodelintermediates` inside `output_dir`.
> - **Returns** the path to the generated metadata JSON.

Usage, with the companion loader:

```python
from pathlib import Path
from coreai_torch.debugging.torch_utils import save_intermediates, load_intermediates

metadata_path = save_intermediates(
    program=exported_program,
    inputs=example_input,
    output_dir=Path("./debug_output"),
    coreai_program=coreai_program,      # links intermediates to source lines
)

trace = load_intermediates(Path("./debug_output/main.aimodelintermediates"))
print(f"Inputs: {list(trace.inputs.keys())}")
print(f"Outputs: {list(trace.outputs.keys())}")
print(f"Intermediates: {len(trace.intermediates)} operations")
```

Filter it down when the graph is large:

```python
def custom_filter(node, result):
    return any(op in str(node.target).lower() for op in ["conv", "linear", "matmul"])

save_intermediates(program=exported_program, inputs=example_input,
                   output_dir=Path("./debug_output"), node_filter=custom_filter)
```

⚠️ **Two environment variables gate the debug metadata**, and without them the debugger's navigator
and source viewer come up empty:

> ✅ **VERIFIED** — `coreai-torch` `docs/api/debugging.md:5-13`: *"During the current preview, set
> the following environment variables to ensure operation-level debug metadata is preserved and
> available to these tools."*
>
> ```bash
> export USE_LOCAL_COREAI=1
> export ENABLE_DEBUG_INFO=1
> ```

The debugger app itself (`https://developer.apple.com/core-ai-debugger/`) is a separate download.
Its central concept is the **sync point**:

> ✅ **VERIFIED** — WWDC26 session 325, line 145 (verbatim): *"These pairs are called **sync
> points**, places where the specialized model's output is **expected to match** the original
> PyTorch result. **The debugger automatically identifies these points throughout the model** to make
> the comparison process easy."* Default metric is **PSNR**, changeable (325:148); nodes are colour
> coded green / yellow / red (325:150); the workflow is *"sort by similarity, and investigate the
> most dissimilar sync points"*, then arrow-key through the low-PSNR ones *"one-by-one to see if a
> pattern emerges."*

That workflow produced the session's headline diagnosis: after uniform `w4` quantization broke SAM3's
detection of an occluded flower, *"the vast majority of low-PSNR sync points are actually coming from
the detector decoder"* — and since the detector is 4 % of parameters, excluding it from compression
restored baseline quality at almost no size cost (325:156-162). **That is the canonical Core AI
debugging loop, and it transfers directly to an LLM: compress uniformly, find the sensitive block,
exclude it, re-gate.**

Other tools in the same module, none of which appeared on stage:

```python
# NaN / Inf bisection
from coreai_torch.debugging.validator import (
    create_validator_for_exported_program, create_validator_for_coreai_program)
validator = create_validator_for_exported_program(exported)
nan_result = await validator.check_for_nans(inputs=example_input)
print(nan_result.failed_nodes[0])          # first failing op

# Cross-framework comparison, PyTorch vs Core AI
from coreai_torch.debugging.comparator import create_comparator_for_programs
comparator = await create_comparator_for_programs(
    source_program=exported_program, target_program=coreai_program,
    target_entry_point="main")
result = await comparator.compare_with_tolerance(
    inputs={"input_ids": ids}, rtol=1e-5, atol=1e-8)
for source_op, target_op in result.failed_nodes:
    print(f"Mismatch: {source_op} vs {target_op}")

# Structural graph diff (isomorphism)
from coreai_torch.debugging.graph_diff import compute_coreai_program_diff, write_diff

# Op-level benchmarking
from coreai_torch.debugging.benchmarker import benchmark_coreai_program
result = await benchmark_coreai_program(
    coreai_program=coreai_program, inputs={"input_ids": ids}, num_runs=50)
for name, module in result.get_module_timings().items():
    print(f"{name}: {module.aggregated_op_stats.average:.3f}ms avg")
```

> ✅ **VERIFIED** — `coreai-torch` `docs/api/debugging.md`. **Nearly everything in this module is
> `async`.** Search strategies for the bisection: `LevelOrderStrategy.bisection(graph,
> batch_size=10)` (default, fastest to first issue), `.top_down(graph)`, `.auto(graph)`.

⚠️ Minor but real: `load_intermediates` validates the directory suffix and raises *"Expected a
`.aimodelintermediates` directory, but got: …"*. And the docstring examples inside the source still
call the function `dump_intermediates` — a stale name. The exported symbol is `save_intermediates`.

### 6.7 Choosing the gate prompt

> **Community practice** — `coreai-torch-041-ir-incident.md`, describing `conversion/coreai_gate.py`:
> use a **deterministic** prompt — *"The capital of France is"* — because *"open-ended prompts hit
> ties everywhere and aren't gate material."* PASS is defined as token-for-token match **or** a first
> divergence only at a **top-2 margin < 0.1** (*"a knife-edge tie, fp16 class"*).

Four non-obvious things that same gate encodes, all of which will bite you if you write your own:

> **Community practice**, verbatim from `coreai-torch-041-ir-incident.md:73-84`:
> - *"The fp32 oracle steps `S=1` but **`position_ids` carries the full `0..t` range each step**
>   (dynamic full-length positions); a single position yields plausible-looking garbage."*
> - *"The oracle must stop at EOS and step only after the prompt is consumed (`t >= len(prompt)-1`),
>   else it emits prompt-position predictions."*
> - Engine launch for a static-`S=1` decode graph needs **`COREAI_CHUNK_THRESHOLD=1` +
>   `--inference-engine-variant coreai-pipelined` + `--warmup off`**, because *"the default warmup
>   does a synthetic 256-token prefill that a static-`S=1` decode graph can't serve (`Shape at
>   dimension 1 of 256 is not a valid substitution for source shape 1`)."*
> - *"`llm-runner --inference-engine-variant` help text is **STALE**; the real values are
>   `auto / coreai-sequential / coreai-pipelined / static-shape`."* (That set matches Apple's
>   `EngineFactory` source, so the *values* are ✅ VERIFIED even though the staleness report is
>   community.)

And for very large models:

> **Community practice**: use `--oracle-dtype fp16` above ~27B. *"The fp32 oracle materialises all
> weights in fp32 — a 35B is ~140 GB and won't fit (**27B at ~108 GB was the largest that fit 137 GB
> RAM**). fp16 is the export's own trace dtype, so an fp16 oracle is still a valid conversion check."*

### 6.8 ⚠️ SILENT FAILURE — the missing chat template

This is the best-documented silent failure in the whole Core AI corpus, and it is a *bundle* defect,
not a model defect — which is exactly why gates have to cover the bundle.

> **Community-measured** — `john-rocky/coreai-model-zoo`, `CATALOG_PLAN.md`, first full run of
> `zoo_verify.py` over **222 published bundles: 162 PASS, 8 DIFF, 10 FAIL, 42 SKIPPED**.
>
> The 10 FAILs: **Gemma 4 E2B/E4B bundles shipped no chat template at all** while their source ships
> one — and E2B was *"the most-downloaded text model in the catalog."* Root cause: the exporter
> copied `tokenizer.json`, `tokenizer_config.json` and `special_tokens_map.json` **but not
> `chat_template.jinja`**, while the 12B exporter did.
>
> The consequence, from the same author's `cross-runtime-quality-benchmarking.md`: *"A bundle with no
> `chat_template` anywhere **silently falls back to raw completion**. `--apply-chat-template`
> defaults to true and does **not** warn when there is nothing to apply."*

So: an exporter drops one file, the runner degrades to raw completion, quality collapses, and
**nothing anywhere warns**. The model is fine. Every layer is fine. The bundle is broken.

The defence is a bundle-level check that reads the **source HF repo at verification time** rather
than trusting a transcribed local copy:

> **Community practice** — `zoo_verify.py` checks four things per bundle: **eos/bos, chat template,
> context length, declared precision**, reading the expectations *"from the source HF repository at
> run time"* because *"A transcription can be wrong and goes stale; the source repo cannot."*

Two adjacent findings from the same audit that generalise:

- **`eos` vs `eot`.** Gemma 4 E2B/E4B shipped `eos_token: "<eos>"`, which *"a host loop stops on
  only at end-of-sequence, never at end-of-turn."* The source's own end-of-turn token is different.
  Apple's runtime has a mitigation for this class — see `LanguageConfig.additionalStopTokenIds` in
  §11.6 — but it depends on the tokenizer config being right in the first place.
- **A metadata privacy leak, published.** One bundle's `hf_model_id` and `tokenizer` fields *"held
  an absolute path from this machine, published."* Check your `metadata.json` before you upload it.

### 6.9 Re-gate after every stage

The rule, stated by both camps:

> **Community practice** — `PORTING.md:217-234`: re-run **Gate A on the compressed bundle** —
> *"compression is part of the model, so it gates like the model."*
>
> ✅ **Apple's own equivalent** — the PSNR ladder in `model-authoring/SKILL.md` has a separate,
> looser bar *after* 4-bit palettization (**≥ 35 dB**), which only means anything if you measure it
> at that point.

Concretely: gate after re-authoring, after compression, after conversion, and after AOT compilation.
Four measurements, each cheap, each isolating a different tool.

---

## 7. Stage 4 — compress

Part 9 covers `coreai-opt` in depth. This section covers only what is specific to an LLM export, and
it is organised around the fact that **the two targets use two entirely different compression
families**.

### 7.1 The split

| Target | Family | Preset default | Applied |
|---|---|---|---|
| **macOS** | **Linear quantization** (`coreai_opt.quantization.Quantizer`, torchao PT2E) | `"4bit"` | pre-`torch.export`, on the `nn.Module` |
| **iOS** | **K-means palettization** (`coreai_opt.palettization.KMeansPalettizer`) | `"4bit_weight_palettized_group32"` | pre-`torch.export`, on the `nn.Module` |

> ✅ **VERIFIED** — `python/src/coreai_models/export/presets.py`:
> `DEFAULT_MACOS_COMPRESSION_PRESET = "4bit"`, `DEFAULT_IOS_COMPRESSION_PRESET =
> "4bit_weight_palettized_group32"`. `MACOS_PRESETS` = `{"none", "4bit"}`; `IOS_PRESETS` =
> `{"none", "4bit_weight_palettized_group8", "4bit_weight_palettized_group32"}`. The pipeline
> asserts the two are never set simultaneously (`export/pipeline.py` step 5), and
> `pipeline.py:295-296` carries `assert config.variant == "iOS", "palettization is only supported
> for iOS variant."`

The reason is the hardware, and it is stated bluntly in the community material:

> **Community practice** — `PORTING.md:217-234`: *"**The ANE rule**: statically-compiled ANE
> execution requires palettized (LUT) weights — blockwise-linear int4 is a GPU-only format there. If
> you aren't explicitly targeting ANE, target GPU and move on."*

### 7.2 The macOS `4bit` preset, expanded

```python
{"execution_mode": "eager",
 "global_config": {
     "op_state_spec": {"weight": {
         "dtype": "int4",
         "qscheme": "symmetric_with_clipping",
         "granularity": {"type": "per_block", "block_size": 32, "axis": 1}}},
     "op_input_spec": None,
     "op_output_spec": None},
 "module_type_configs": _TORCH_MODULE_CONFIGS_4BIT}
```

> ✅ **VERIFIED** — `export/presets.py`. `op_input_spec=None, op_output_spec=None` is what makes it
> **weight-only** — no activation quantization, therefore no calibration data required.

**Four module types are excluded** — mapped to `None`, which is `coreai-opt`'s "leave alone":

```
coreai_models.primitives.macos.sdpa.SDPA
coreai_models.primitives.macos.rope.RoPE
coreai_models.primitives.macos.rms_norm.RMSNorm
coreai_models.primitives.macos.rms_norm.RMSNormPlusOne
```

with Apple's stated reason: these *"should not be quantized because they use specialized ops."*
Quantizing a composite op destroys the composite, and the composite is the whole point — it is what
lets the runtime substitute a fused kernel.

**MoE gets an override**, because the global 2-D spec cannot describe a 4-D expert tensor:

```python
_TORCH_MOE_SWITCH_LINEAR_4BIT = {
    "module_state_spec": {"weight": {
        "dtype": "int4",
        "qscheme": "symmetric_with_clipping",
        "granularity": {"type": "per_block", "block_size": [1, 1, 1, 32], "axis": None}}},
    "op_input_spec": None, "op_output_spec": None}
```

> ✅ **VERIFIED** — `export/presets.py`, applied to
> `coreai_models.primitives.macos.switch.SwitchLinear`. Apple's comment: expert weight is 4-D
> `[num_weight_sets, num_experts, output_dims, input_dims]`, which the global `per_block/32/axis=1`
> spec can't express. It is a **no-op on non-MoE models** (no `SwitchLinear` instances), so it can
> live in the default preset safely.

⚠️ **Fully-qualified class names only.** `module_type_configs` keys must be the exact internal module
path — *"Short-form names like `"torch.nn.Linear"` are not supported."*

> ✅ **VERIFIED** — `coreai-optimization` `docs/src/quantization/config.md`.

### 7.3 The iOS palettization presets

Both `4bit_weight_palettized_group8` and `…_group32` are:

```python
{"n_bits": 4, "granularity": {"type": "per_grouped_channel", "axis": 0, "group_size": 8 or 32}}
```

with **embeddings excluded**:

```
torch.nn.modules.sparse.Embedding
coreai_models.primitives.ios.embedding.LoadEmbeddings
```

…and then handled separately:

> ✅ **VERIFIED** — `apple/coreai-models` `models/README.md:54`: *"All `iOS` palettization presets
> quantize the Embedding to 8-bit per tensor by default."* Implementation:
> `primitives/ios/quantization.py`, `quantize_per_tensor` — symmetric, `nbits=8` only,
> `scale = max|x| / 127`, clamped to a minimum of `1e-6`.
> Override with `--disable-embedding-quantization-ios` (iOS only), which keeps it in float32.

### 7.4 Mixed-precision via YAML

The two most interesting iOS presets in the registry don't use a named preset at all — they point at
a YAML file:

```
qwen3-0.6b  →  compression="none" + compression_config="models/qwen3/qwen3_0_6b_mixed_4bit_8bit.yaml"
qwen3-4b    →  compression="none" + compression_config="models/qwen3/qwen3_4b_mixed_4bit_8bit.yaml"
```

The loader is strict, and worth knowing before you write your own:

> ✅ **VERIFIED** — `_load_compression_config_object`, `llm/export.py:163-237`:
> - The YAML must be a mapping with **exactly one** `coreai-opt` top-level key, after popping an
>   optional `coreai_models:` block.
> - That `coreai_models:` block allows only `{"calibrate_activations"}`; unknown keys → `SystemExit`.
> - Top key **`kmeans_palettization_config`** ⇒ requires `--platform iOS`, does **not** support the
>   `coreai_models` block, parsed via `KMeansPalettizerConfig.from_dict({top_key: inner})`.
> - Top key **`quantization_config`** ⇒ requires `--platform macOS`, validated with
>   `QuantizerConfig.from_dict(...)`, then `calibrate_activations` is re-inlined into the result.

A minimal iOS mixed-precision YAML has this shape:

```yaml
# my_recipe.yaml — iOS: k-means palettization, 4-bit body, 8-bit on the sensitive projections
kmeans_palettization_config:
  global_config:
    op_state_spec:
      weight:
        n_bits: 4
        granularity: { type: per_grouped_channel, axis: 0, group_size: 32 }
  module_name_configs:
    "model.layers.*.mlp.gate_proj":
      op_state_spec:
        weight:
          n_bits: 8
          granularity: { type: per_grouped_channel, axis: 0, group_size: 32 }
```

> 🟡 **RECONSTRUCTED** — the *outer* structure (`kmeans_palettization_config` as the single top-level
> key, `global_config` / `module_name_configs` precedence, `op_state_spec: {weight: …}`) is verified
> from `llm/export.py` and `coreai-optimization`'s config docs; Apple's own two shipped YAMLs are in
> the repo under `models/qwen3/` but **we did not read their contents this session**, so the exact
> layer patterns Apple chose are not reproduced here. **Read
> `models/qwen3/qwen3_0_6b_mixed_4bit_8bit.yaml` before writing your own** — it is the reference
> implementation and it is right there.

The precedence rule that makes this work:

> ✅ **VERIFIED** — `QuantizerConfig` docstring, `coreai-optimization`
> `src/coreai_opt/quantization/config/quantization_config.py:576-582`: *"The configuration lookup
> follows a hierarchical precedence (most to least specific): 1. `module_name_configs` — Applies to
> module instances matching a name pattern (**supports regex**) 2. `module_type_configs` — Applies to
> all modules of a specific type 3. `global_config`."* And: *"Setting a config to `None` explicitly
> disables quantization for that scope."*

### 7.5 ⚠️ SILENT FAILURE — compression that skips layers and tells you nothing

**This is the callout to remember from this section.** Two mechanisms, both silent, both producing
an artifact that is *larger and better* than you think, which is the direction of error nobody
checks for.

**(1) Non-divisible dimensions are skipped, not failed.**

> ✅ **VERIFIED** — `coreai-optimization`, `_FakePalettizeImplBase.forward` logs *"Tensor incompatible
> with granularity: … Skipping palettization."* and **disables palettization for that layer** rather
> than raising.
>
> **Corroborated by Apple's own skill** — `model-compression-exploration/SKILL.md` pitfalls:
> *"per-block/per-grouped-channel **silently skip** layers whose weight dim isn't divisible
> (pre-check with `check_divisibility()`)"*.

So a `group_size=32` palettization on a model with a 1536-wide projection quietly leaves any
non-divisible tensor at full precision. Your bundle is bigger, your PSNR is better, and your size
budget is blown — and the only signal is a log line you weren't tailing.

**Guard:** compute the achieved average bit-width from the artifact rather than assuming the config.
Apple ships the helper: `skills/skills/model-compression-exploration/scripts/compression_metrics.py`
provides theoretical size, average bit-width and a divisibility check.

**(2) `finalize()` frees the original weights in place.**

> ✅ **VERIFIED** — `KMeansPalettizer.finalize` docstring: *"When `backend=ExportBackend.CoreAI`,
> finalize **frees the original dense weights in place**: on each parametrized weight,
> `parametrizations[...].original` is replaced with a zero-size placeholder so its storage can be
> released."* Also: *"**Only call `finalize` when exporting to a target backend.** For torch-based
> evaluation, use the model returned by `prepare()` directly."*

Two consequences. First, **you cannot re-run the fp16 oracle from the same Python process after
finalizing** — the weights are gone. Second, and this is the ordering rule that catches people:

> **Community practice** — `compression.md`: *"read the export spec (reference inputs / dynamic
> shapes / state names) from the ORIGINAL model first (**the finalized palettized model loses that
> method**), palettize, then drive `export_to_coreai` with that spec."* Verified by that author to
> be top-1-exact for Gemma 4 (dual-KV) and Qwen3.5 (hybrid 4-state).

**(3) And for completeness, a third, from an adjacent modality.** The diffusion path applies
quantization *after* MLIR lowering, and **swallows failures with a warning**:

> ✅ **VERIFIED** — `python/src/coreai_models/diffusion/export/compiler.py:69-72`: a failed
> `apply_mlir_quantization` logs a warning and continues, so *a "quantized" diffusion export can
> silently ship full precision.* Not an LLM path, but the same authors and the same failure shape —
> if you export diffusion components alongside your LLM, check the artifact size.

### 7.6 The compression rules that are LLM-specific

Apple's published numbers first — these are perplexity on WikiText-2 via lm-evaluation-harness,
measured by Apple on Apple's own recipes and printed in the model READMEs.

**Apple-published** (`apple/coreai-models` `models/*/README.md`). "BPW" marked `*` includes the
INT8-per-tensor embedding.

| Model | Compression | BPW | Platform | Perplexity |
|---|---|---|---|---|
| Qwen3 0.6B | none (float16) | 16.00 | iOS | 26.16 |
| Qwen3 0.6B | mixed 4/8-bit palettized (YAML) | 5.71* | iOS | 30.90 |
| Qwen3 4B | none (float16) | 16.00 | macOS | 16.41 |
| Qwen3 4B | 4-bit quantized | 4.50 | macOS | 18.33 |
| Qwen3 4B | mixed 4/8-bit palettized (YAML) | 4.89* | iOS | 18.80 |
| Qwen3 8B | none | 16.00 | macOS | 12.19 |
| Qwen3 8B | 4-bit quantized | 4.50 | macOS | 12.90 |
| Qwen2.5 1.5B Instruct | none | 16.00 | macOS | 12.21 |
| Qwen2.5 1.5B Instruct | 4-bit quantized | 4.50 | macOS | 14.79 |
| Qwen2.5 1.5B Instruct | 4-bit palettized (gs 8) | 4.63* | iOS | 14.64 |
| Gemma 3 4B | none / 4-bit quantized | 16.00 / 4.50 | macOS | 17.90 / 19.28 |
| Gemma 3 12B | none / 4-bit quantized | 16.00 / 4.50 | macOS | 11.24 / 11.75 |
| Mistral 7B Instruct | none / 4-bit quantized | 16.00 / 4.50 | macOS | 8.29 / 8.41 |
| Mixtral 8x7B | none / 4-bit quantized | 16.00 / 4.50 | macOS | 5.72 / 6.19 |
| Qwen3 Coder 30B-A3B | none / 4-bit quantized | 16.00 / 4.50 | macOS | 11.06 / 11.90 |

Read the shape rather than the absolute numbers: **the perplexity cost of 4-bit falls as the model
grows.** Qwen3 0.6B pays +4.7 points; Qwen3 8B pays +0.7; Gemma 3 12B pays +0.5; Mistral 7B pays
+0.12. This is the standard capacity story, and it is the strongest argument for *"if you must go to
4 bits, go to 4 bits on a bigger model."*

Now the community position, which is more conservative and worth taking seriously because it is
based on token-exactness rather than perplexity:

> **Community practice** — `compression.md` TL;DR: *"For LLM decoders: **int8 k-means palettization
> is the floor that stays exact** when applied across the whole transformer; whole-model int4
> degrades. **SELECTIVE 4-bit works**: k-means int4 on the **FFN + lm_head only**
> (attention/embeddings kept ≥ int8/fp16) measured top-1 exact."*
>
> Supporting detail: across Gemma 4 E2B and Qwen3.5, *"linear int4 and k-means int4 **both** flip
> next-token argmax vs the HF reference; **int8 k-means palettization reproduces HF top-1 exactly**
> at ~half the fp16 size."* And *"**Finer groups are the main int4 lever** (group32 → group8 helps),
> but still don't reach exact."* And, on `PORTING.md`'s blunter phrasing: ***"int4 is a cliff, not a
> slope"*** — *"the failure is capacity, so no clever rounding rescues it."*

⚠️ **These two positions are not in conflict; they measure different things.** Apple reports
perplexity deltas that are small and monotone. The community reports **greedy top-1 flips against
the HF reference**, which is a far stricter criterion. A model can be 0.7 perplexity worse and still
produce a different first token — and if your product is structured extraction or agentic tool
calling, the flipped token is the failure.

**Do not flatten the community's own findings either.** The same corpus contains a result that
*reverses* its default rule:

> **Community-measured** — `compute-units-and-authoring.md`, 2026-06-22, ZAYA1-8B on M4 Max:
> *"'sym8 not k-means' holds for top-k ≥ 4, **REVERSES for top-1**."* On top-4 (LFM) and top-8
> (Qwen3.6) MoE, each token's FFN output is a weighted sum of k experts, so expert-quant error
> averages (~/√k) and even crude linear int8 survives. **ZAYA is top-1 of 16**: one token → one
> expert, error not averaged → symmetric-linear int8 collapses (skips the reasoning block, emits
> `<pad>`, diverges from fp16 at token 1), while **k-means int8 recovers fp16 quality** (29 tokens
> token-exact).
>
> Defensible synthesis from this corpus: **int8 is the safe floor everywhere; *which* int8 (k-means
> vs symmetric-linear per-block-32) is tensor-role- and routing-dependent and must be gated per
> model.**

Two more compression facts specific to LLMs:

- **The LM head is the largest single tensor and the most sensitive.** For a 262,144-vocab model at
  hidden 1536 that is one 400M-parameter matrix. The community note: it *"needs per-row
  (per-output-channel) scales for matmul efficiency"*, and *"an int4 head needs a **kernel** path,
  not `coreai-opt`'s `F.linear` quantizer."*
- **k-means palettizes `F.linear` / `F.conv` weights only** — so RMSNorm and RoPE parameters stay
  full precision automatically, which is convenient and also why the macOS *quantization* preset has
  to exclude them explicitly.

### 7.7 The exploration loop, if you need one

Apple ships a whole agent skill for sweeping compression configs, and its structure is reusable even
if you drive it by hand:

> ✅ **VERIFIED** — `skills/skills/model-compression-exploration/SKILL.md`. ~30 main-sweep + ~30
> refinement configs, in three groups:
> - **1a** channel-structured quantization: `{int8, int4} × {symmetric, asymmetric,
>   symmetric_with_clipping}` (6)
> - **1b** block-structured: `{block_size 16, 32, 128} × {3 qschemes}`, int4 per-block (9)
> - **2** palettization: `{8-bit per-tensor, 6-bit per-tensor, 6-bit gs 4/8/16, 4-bit gs 4/8/16} ×
>   {enable_per_channel_scale True/False}` (15)
>
> Preset anchors: `QuantizerConfig.presets.w8()` / `.w4()` (per-channel symmetric),
> `.w4_per_block(block_size=32)`; `KMeansPalettizerConfig.presets.w8()` / `.w6()` / `.w4()`.
> Refinement: drop anything under 10 dB PSNR, take the 95th and 75th percentile seeds, generate 5
> layer-skip variants each via `set_module_name` overrides.
>
> And the instruction that saves the most time: **do not call `finalize()`** — *"Calibration is not
> needed for weight-only compression."*

Its own pitfall list, all ✅ VERIFIED from the same file, and all worth internalising:

- Scale / zero-point overhead is **5–15 % at 2–4 bit fine granularity** — a 4-bit model with
  `group_size=4` is not a 4× saving.
- **8-bit per-channel LUT stores 256 × fp16 entries per output channel.**
- **At `block_size=16` + int4 the effective width is ~5 bits**, not 4.
- **Boundary layers (first / last) are high-error** — a community measurement puts skipping them at
  up to **+9 dB**; *"always ablate."*
- **Vector k-means is non-deterministic** — seed numpy *and* torch before each `prepare()`, and use
  `num_workers=1`, or you cannot reproduce your own result.
- `enable_per_channel_scale` is *"marginal or harmful"* on LLMs — and on the ANE it is worse than
  that; see the next box.

⚠️ **`enable_per_channel_scale=True` can push a model off the Neural Engine.** From Apple's own
shipped SAM3 recipe:

> ✅ **VERIFIED** — `python/src/coreai_models/segmentation/pipeline.py:136-142`, verbatim: *"Both
> encoders **deliberately disable per-channel scale**: `enable_per_channel_scale=True` lowers to
> `mps.dequantize_lut` ops with **rank-6 LUTs, which ANE rejects (max tensor rank 5)**, forcing the
> runtime to **fall back to GPU**. Keeping it off keeps the asset ANE-compatible at the cost of a
> small PyTorch-side quality regression."*
>
> ⚠️ Note this **contradicts WWDC26 session 325 line 241**, where the presenter says *"I apply 4-bit
> palettization **with per-channel scales**"*. Either the phrase was used loosely for
> "per-grouped-channel granularity", or the recipe changed after the talk was recorded. **The
> shipped code wins**; the talk is the weaker source. This guide reports both readings rather than
> quietly picking one.

Finally, `QuantizerConfig` has an LLM-specific field the talk never mentions:

> ✅ **VERIFIED** — `kv_cache_quant_configs` on `QuantizerConfig`: *"Each entry enables storing the
> corresponding KV-cache buffer in a quantized dtype… **Graph mode only; rejected for eager mode.**"*
> Raises `ValueError: kv_cache_quant_configs is only supported with ExecutionMode.GRAPH (got …)`.
>
> ⚠️ Note the tension: `apple/coreai-models`' own macOS LLM preset sets `execution_mode: "eager"`, so
> **the shipped LLM recipe cannot use KV-cache quantization.** If you want it, you need a graph-mode
> config and an exportable model.

---

## 8. Stage 5 — export with `state_names`

This is where the KV cache becomes real, and it is the stage with the most dangerous silent failure
in the pipeline.

### 8.1 The macOS export, verbatim from the shipped recipe

```python
def export_fn(module):
    with torch.no_grad():
        ep = torch.export.export(
            module, args=(), kwargs=reference_inputs, dynamic_shapes=dynamic_shapes)
    ep = ep.run_decompositions(coreai_torch.get_decomp_table())
    remove_functionalization(ep)              # ⚠️ see §8.4
    return ep

converter = coreai_torch.TorchConverter()
converter.add_pytorch_module(
    model,
    export_fn=export_fn,
    externalize_modules=_EXTERNALIZE_SPECS,
    input_names=("input_ids", "position_ids"),
    output_names=("logits",),
    state_names=("keyCache", "valueCache"),
)
register_custom_torch_lowering(converter)
program = converter.to_coreai()
program.optimize()
```

> ✅ **VERIFIED** — `python/src/coreai_models/export/macos.py`, `export_to_coreai`. This is Apple's
> code, not a reconstruction.

The reference inputs and dynamic shapes that go with it:

```python
input_ids    = torch.randint(1, vocab_size, (1, 16), dtype=torch.int32)   # QUANT_TRACE_QUERY_LEN
position_ids = torch.arange(16 + 8, dtype=torch.int32).unsqueeze(0)       # + QUANT_TRACE_OFFSET
k_cache, v_cache = KVCache.create_cache_tensors(config, dtype=target_dtype)
# ^ traced with max_position_embeddings temporarily clamped to 2048

dynamic_shapes = {
    "input_ids":    {1: Dim("seq_ids", max=max_context_length - 2)},
    "position_ids": {1: Dim("seq_pos", min=16, max=max_context_length - 1)},
    "k_cache": {KVCache.seq_len_dim(): Dim("k_seq_len", min=2048, max=max_context_length)},
    "v_cache": {KVCache.seq_len_dim(): Dim("v_seq_len", min=2048, max=max_context_length)},
}
```

> ✅ **VERIFIED** — `export/macos.py` and `export/_constants.py`:
> `TRACE_KV_CACHE_SEQ_LEN = 2048` (*trace-time only; runtime cache size is dynamic*),
> `QUANT_TRACE_QUERY_LEN = 16`, `QUANT_TRACE_OFFSET = 8`. `KVCache.seq_len_dim() == 3`.

Three things in there are non-obvious and each has a reason:

- **The trace uses a 16-token query at offset 8.** Not 1, not 512. Those two constants also bound
  what the *calibration* path will accept: `max_calib_query_len = cache_seq_len -
  QUANT_TRACE_OFFSET - 1` and `min_calib_query_len = QUANT_TRACE_QUERY_LEN - QUANT_TRACE_OFFSET`
  (= 8), and a calibration set with only short samples raises `ValueError("No calibration samples
  have length >= 8 tokens")`.
- **The cache dim is declared with `min=2048`**, matching the trace-time clamp. That is a floor on
  the dynamic dimension, not a runtime allocation.
- **`position_ids` gets `min=16`.** A graph traced this way expects the *full* position vector, not
  a single position — which is exactly the trap the community gate documentation calls out
  (§6.7): *"a single position yields plausible-looking garbage."*

### 8.2 `_EXTERNALIZE_SPECS` — keeping the semantics the compiler needs

```
| target_class                            | composite_op_name              | composite_attrs                          |
|-----------------------------------------|--------------------------------|------------------------------------------|
| coreai_torch.composite_ops.GatherMM     | gather_mm                      | ["num_batch_axes"]                       |
| RMSNormImpl                             | rms_norm                       | ["axes", "eps"]                          |
| RoPE                                    | rope                           | ["scale", "base", "dims", "interleaved"] |
| SDPA                                    | scaled_dot_product_attention   | ["scale", "is_causal", "window_size"]    |
| GatedDeltaUpdate                        | gated_delta_update             | []                                       |
```

> ✅ **VERIFIED** — `export/macos.py`. Note `gated_delta_update` is present in **Apple's own**
> externalize specs — Apple ships the authoring support for GatedDeltaNet even though the Swift
> engine rejects the resulting bundles (§13).

Why this matters, in Apple's words:

> ✅ **VERIFIED** — `coreai-torch` `docs/guides/conversion-workflows.ipynb`: *"Externalizing a
> submodule **preserves its operation boundary** during conversion… When you mark a well-known
> building block — such as attention, RoPE, or RMSNorm — as a composite op, the compiler recognizes
> that operation and can apply an optimized implementation tailored to it, producing a faster
> model."*

Two traps in `ExternalizeSpec`, both verified:

- **`target_class` must be the *inner* implementation class.** `coreai_torch.composite_ops` ships
  convenience wrappers like `RMSNorm`, but *"`target_class` in the `ExternalizeSpec` must still be
  `RMSNormImpl`"*.
- **Passing a bare module class instead of an `ExternalizeSpec`** performs "simple externalization":
  the submodule is extracted into its own standalone graph *"with no composite-op metadata and no
  optimization benefit. **This is experimental** — prefer composite-op externalization."*

And one more from the community, which is the failure you actually hit:

> **Community-measured** — `conversion-guide.md`: *"**`ExternalizeSpec` marks ops by *class***; if
> the export unit holds submodules of that class that are NOT in the traced graph (e.g. a front-end
> norm kept as an attribute), externalizing fails with *'custom op not found'*. Opt out with
> `coreai_externalize_specs = ()` on the module."*

### 8.3 `get_decomp_table()` is mandatory, not optional

> ✅ **VERIFIED** — `coreai-torch` `docs/api/TorchConverter.md:53-55`, a `warning` block: *"The caller
> **must** call `run_decompositions()` on the program before passing it here — use
> `get_decomp_table()` to preserve known composite ops in the lowered IR."* And the quickstart:
> *"This call is required when using `add_exported_program()`. **Skipping it will leave ops in the
> graph that have no lowering rule.**"*
>
> What the table *is*: *"the default PyTorch ATen decomposition table **minus** the operations that
> `TorchConverter` lowers as composite ops, so those operations are preserved in the exported graph
> rather than being decomposed into lower-level primitives."* Named trio in the README:
> `instance_norm`, `pixel_shuffle`, `scaled_dot_product_attention`. Each call returns a **fresh
> copy**.

Missing it does throw — eventually, at `add_exported_program` validate time, not at runtime. Which
leads to a genuinely useful debugging fact:

> **Community-measured** — `conversion-guide.md`: *"**Unsupported ATen ops surface at
> `add_exported_program` validate time**, not runtime."* e.g. `aten.remainder.Scalar` (tensor
> modulo) is unsupported.

### 8.4 ⚠️ SILENT FAILURE — omit `remove_functionalization` and your KV writes disappear

**This is the one.** If you take a single warning from this guide, take this one.

> **Community practice** — `PORTING.md:158-170`, Track L, systems 1 of 3: *"**KV cache lives in the
> graph as mutable state** — in-place writes via `slice_update`, which **requires
> `remove_functionalization(ep)` after `run_decompositions` or the mutation is silently dropped.**"*
> The doc's own parenthetical: *"(Silently! This is the single most dangerous export gotcha in the
> doc.)"* Restated in `conversion-guide.md`: *"**In-place state writes need
> `remove_functionalization(ep)`** after `run_decompositions` — Without it the mutation is dropped."*
>
> ✅ **Corroborated by Apple's shipped code** — `export/macos.py` calls `remove_functionalization(ep)`
> on every export, immediately after `run_decompositions`, in `export_fn`. It is not optional in
> Apple's own recipe either.

What you observe when you get this wrong: the model converts. The asset loads. Inference runs at
full speed. **The KV cache never updates**, so every decode step attends only to the tokens in that
step's `input_ids` — which means generation is locally fluent and globally incoherent, drifting
after a handful of tokens, and it looks *exactly* like a bad quantization recipe.

The gate that catches it is **per-step token exactness over ≥ 30 steps** (§6.2). Step 1 is fine.
Step 2 is often fine. It falls apart around the point where the prompt's information should still be
influencing the output.

What `remove_functionalization` actually does:

> ✅ **VERIFIED** — `python/src/coreai_models/export/mlir_ops.py`: it *"replaces
> `AutoFunctionalized`/`AutoFunctionalizedV2` HOP nodes with immutable variants."* The same module
> registers `coreai::immutable_slice_update` (a `@torch.library.custom_op(..., mutates_args=[])`
> non-mutating twin used during graph transformation, hardcoded to 5-D slicing), re-exports
> `mutable_slice_update` from `coreai_models.primitives._ops`, and provides
> `register_custom_torch_lowering(converter)` which registers the slice-update, composite-op and
> dequantization lowerings.

⚠️ **That module imports private API.** `coreai._compiler.dialects.{coreai, coreaix}`,
`coreai._compiler.ir.{Location, OpResultList, Value}`, `coreai_torch._utils.generate_composite_decl`.
Apple's own doc says so about `register_torch_lowering`: *"The leading underscore on `_compiler`
marks this as private upstream API — **it may move or change without notice** across `coreai-core`
releases."* If you copy Apple's LLM export machinery into your own project, you have taken on that
version risk. Pin your wheels.

### 8.5 What the converter treats as state — and the opt-out that doesn't exist

> ✅ **VERIFIED** — `coreai-torch` `docs/api/TorchConverter.md:409-418`, verbatim: **"What counts as
> state (no opt-out)."** The converter treats two things as state:
> 1. **Mutable buffers** registered via `self.register_buffer(...)` and mutated in place inside
>    `forward()` (e.g. `self.buf.add_(x)`).
> 2. **User inputs mutated in place** inside `forward()` (e.g. `x.mul_(2)` on a `forward()` arg).
>
> *"Both are detected from the exported program's graph signature. **There is no flag** to opt a
> mutated user input out of state… If you don't want a `forward()` argument treated as state,
> eliminate the in-place mutation from your model — clone first (`x_local = x.clone();
> x_local.mul_(2)`) or use the out-of-place form (`x_scaled = x * 2`)."*

And the ordering hazard, which is exactly the class of bug that produces a swapped key/value cache:

> ✅ **VERIFIED** — same doc: *"The ordering of `state_names` (buffers first, then mutated user
> inputs) is based on observed FX graph behavior… The converter asserts that the number of state
> inputs matches state outputs, but **cannot detect silent reordering**. **Always verify state
> ordering when upgrading PyTorch versions.**"*

⚠️ Also flagged there as a **breaking change** relative to pre-release code: `input_names` now covers
*"non-stateful user inputs only. Mutated inputs (buffers and user-input mutations) are renamed via
`state_names`."* Previously it covered all graph inputs. If you are porting an early script, this is
where it silently mis-names things.

Default names, when you omit the parameters, are FX-derived and explicitly **not a stable contract**:

| Category | FX source | Example |
|---|---|---|
| Input | placeholder `node.name` | `def forward(self, x, z)` → `"x"`, `"z"` |
| Output | output node's input `node.name` | `return a + b, c * d` → `"add"`, `"mul"` |
| State (buffer) | placeholder `node.name` | `register_buffer("kv_cache", …)` → `"b_kv_cache"` |
| State (mutated input) | placeholder `node.name` | `def forward(self, y): y.mul_(2)` → `"y"` |

> ✅ **VERIFIED** — same doc: *"These naming conventions are observed behavior from the FX graph, not
> a stable contract from PyTorch. **Always provide explicit names for production use.**"*

Given that `CoreAISequentialEngine` reads its inputs, states and outputs **positionally** (§3.2),
"always provide explicit names" is not style advice. It is the only thing standing between you and a
model that runs with key and value swapped.

### 8.6 The iOS export's extra machinery

Beyond the static-shape grid (§3.4), the iOS path adds two things.

**A modified decomposition table that keeps SiLU intact:**

```python
decomp_table = torch.export.default_decompositions()
decomp_table.pop(torch.ops.aten.silu.default)
decomp_table.pop(torch.ops.aten.silu.out)
```

> ✅ **VERIFIED** — `export/ios.py`. This is the *other* half of the SiLU story from §5.6: Apple
> keeps `silu` un-decomposed here so it can be lowered as a unit, rather than exploding into the
> `cast/swish/cast` triple.

**Explicit hardware constraints on the allocations:**

```python
emb_table_constraints = HardwareConstraints(
    AllocationType.IOSurface, interleave=[8, 1, 1], alignments=[1, 1, 1, 1])
cache_constraints = HardwareConstraints(
    AllocationType.IOSurface,
    interleave=[1, 1, 8, 1, 1],
    alignments=[1, 1, 1, 1, 8 * max_context_length, 1])
```

applied to `load_embeddings`, `gather_embeddings`, `extend` and `prompt_opt`.

> ✅ **VERIFIED** — `export/ios.py`; `KV_CACHE_INTERLEAVE_FACTOR = 8` in the same file explains the
> `8`s. The Swift side allocates the caches as IOSurface-backed `NDArray`s from the max-context
> descriptor (`CoreAIStaticShapeEngine.swift`).
>
> 🟡 **RECONSTRUCTED** — `HardwareConstraints(AllocationType.IOSurface, interleave=…,
> alignments=…)` and `AllocationType` are read from Apple's calling code, so the *usage* is
> verified; the types themselves live in `coreai-core` and we have not seen their definitions. Do
> not invent other `AllocationType` cases.

**And the reason those `8`s exist**: Apple's ANE rules require the last axis to be contiguous and
64-byte aligned, with a warning that *"a singleton last axis costs 32× memory at fp16, 64× at
int8."* The interleave factor is how a `(…, 1, max_context_length)` cache avoids paying that.

---

## 9. Stages 6–8 — convert, optimize, save the bundle

### 9.1 The `TorchConverter` surface, complete

```python
TorchConverter()                                    # no loaded programs, no custom lowerings

def add_exported_program(
    self,
    exported_program: ExportedProgram,
    input_names: Sequence[str] | None = None,
    output_names: Sequence[str] | None = None,
    state_names: Sequence[str] | None = None,
    entrypoint_name: str = "main",
) -> TorchConverter                                  # returns self, chainable

def add_pytorch_module(
    self,
    module: nn.Module,
    export_fn: Callable[[nn.Module], ExportedProgram],
    externalize_modules: list | None = None,
    input_names: Sequence[str] | None = None,
    output_names: Sequence[str] | None = None,
    state_names: Sequence[str] | None = None,
    entrypoint_name: str = "main",
) -> TorchConverter

def to_coreai(self, *, entrypoints: Sequence[str] | None = None) -> AIProgram
def clear(self, *, entrypoints: Sequence[str] | None = None) -> None
def register_torch_lowering(self, qualified_name: str, allow_override: bool = False) -> Callable
def register_custom_kernels(self, kernels: Sequence[TorchMetalKernel]) -> TorchConverter

# standalone
def get_decomp_table() -> dict
```

> ✅ **VERIFIED** — `apple/coreai-torch` `docs/api/TorchConverter.md`, read in full.
> `entrypoint_name` *"must be unique across all staged programs."*
> `clear()`: *"Custom lowerings registered via `register_torch_lowering()` are always preserved."*
> `register_torch_lowering` raises `ValueError` if the name is not `"namespace::op_name"` form, if
> the namespace is reserved (`aten`, `higher_order`, `coreai`, `coreaix`), or if a lowering exists
> and `allow_override is False`.

**Multiple entrypoints in one asset** is the mechanism behind both the SAM3 three-function split and
the iOS LLM's four functions. Apple's shipped segmentation code shows the pattern directly:

> ✅ **VERIFIED** — `python/src/coreai_models/segmentation/pipeline.py:265-286`:
>
> ```python
> converter = coreai_torch.TorchConverter()
> converter.add_exported_program(img_program, entrypoint_name="image_encode",
>                                input_names=["pixel_values"], output_names=["backbone_features"])
> converter.add_exported_program(txt_program, entrypoint_name="text_encode",
>                                input_names=["input_ids"], output_names=["text_features"])
> converter.add_exported_program(det_program, entrypoint_name="detect",
>                                input_names=["backbone_features", "text_features"],
>                                output_names=["pred_masks", "pred_boxes", "pred_logits",
>                                              "presence_logits", "semantic_seg"])
> coreai_program = converter.to_coreai()
> coreai_program.optimize()
>
> metadata = build_aimodel_metadata(config.hf_model_id)
> coreai_program.save_asset(asset_path, metadata)
> ```

Session 325 sells this split as a **latency** technique — run each function at its own cadence,
*"the second inference is 76% faster, even after warmup"* (325:249-262) when only the text encoder
and detector re-run. That is true and Apple-published. But there is a second, stronger reason that
only shows up in the shipped Swift:

> ✅ **VERIFIED** — `CoreAIShared/Runtime/ModelStructure.swift`: a multi-function structure
> (`.chunkedStatic` or `.multiFunctionSegmenter`) is what makes the optional sample runtime request
> `preferredComputeUnitKind: .neuralEngine`. A single `main` graph gets `.gpu`.

**Within `coreai-models`, splitting a model into recognized functions selects the Neural Engine
preference.** For an LLM this is not a choice you make separately—it *is* the iOS export—but the
framework itself does not impose this naming policy.

### 9.2 `optimize()` is in place, and it can hurt you

```python
coreai_program = converter.to_coreai()
coreai_program.optimize()          # in-place; every doc example ignores the return value
asset = coreai_program.save_asset(Path("model.aimodel"))
```

> ✅ **VERIFIED** — every example in `apple/coreai-torch`'s docs and every call site in
> `apple/coreai-models` calls `optimize()` as a bare statement after `to_coreai()`, never assigning
> the result. Session 325:48 describes it as *"The converted model is then optimized and saved as an
> aimodel asset."*

Two costs to know about.

⚠️ **`optimize()` deletes ops it believes are dead** — that is its job, and it is why Apple's own
Track-V guidance says *"let dead code die: export only the outputs you need; `optimize()` DCEs the
branches that don't feed them."* The flip side is that anything semantically significant but not
dataflow-visible can go with it. For an LLM the practical instance is **broadcasting-significant
axis moves**: a `squeeze`/`unsqueeze` pair that exists to make a broadcast work can be eliminated if
the optimizer decides the shapes agree without it. Gate after optimizing, not before.

⚠️ **`optimize()` can hang on very large attention graphs.**

> **Community-measured** — `conversion-guide.md`: TripoSplat DiT (24 blocks × ~12 k-token attention)
> took **> 90 minutes and ~64 GB RAM** in `optimize()` while the conversion itself was ~7 s. The
> escape hatch is to skip it (`optimize=False` in that project's wrapper) and gate with a manual
> `run()` — *"note `verify()` **forces** `optimize=True`"* — accepting that *"On-device AOT
> `coreai-build` optimizes anyway."* Mac; model/OS not stated.

### 9.3 `save_asset` — two traps in one call

```python
import shutil
from pathlib import Path
import coreai.runtime as rt

out = Path("exports/my_model/my_model.aimodel")
shutil.rmtree(out, ignore_errors=True)      # save_asset will NOT overwrite
prog.save_asset(out, rt.AIModelAssetMetadata())
```

> ✅ **VERIFIED (behaviour)** — Apple's own pipeline does the same thing:
> `python/src/coreai_models/export/pipeline.py` calls `shutil.rmtree(aimodel_path)` on the overwrite
> path. The `save_asset(path, metadata)` two-argument form is verified from
> `segmentation/pipeline.py:265-286`.
>
> **Community practice** — `PORTING.md:121-134` bakes the same into its canonical skeleton with the
> comment `# save_asset will NOT overwrite`, and `conversion-guide.md:21-25` adds: **`save_asset`
> takes a `Path`, not a `str`**, and **`minimum_os` defaults to v27**.

Metadata is worth filling in. Apple's LLM path builds it from a hardcoded table keyed by HF id:

> ✅ **VERIFIED** — `python/src/coreai_models/export/metadata.py`:
> `build_aimodel_metadata(hf_model_id, component=None) -> coreai.runtime.AIModelAssetMetadata`
> fills `author`, `license`, `model_description`, `creation_date = int(time.time())`. Known ids
> include Qwen2.5-1.5B, Qwen3-0.6B/4B/8B, Qwen3-Coder-30B-A3B, gemma-3-4b/12b-it,
> Mistral-7B-Instruct-v0.3, Mixtral-8x7B, gpt-oss-20b, Qwen3-VL-2B-Instruct, the three Stable
> Diffusion checkpoints, FLUX.2-klein-4B and `facebook/sam3`.
>
> ⚠️ **An unknown id logs an 80-`!` banner warning and ships an asset with only `creation_date`.** So
> a custom model gets an asset with no author, no license and no description unless you supply them
> — and the warning is easy to scroll past in a long export log.

### 9.4 Wrapping it into a bundle

The asset alone is not loadable by `CoreAILanguageModel`. You need the bundle:

```python
from transformers import AutoTokenizer

bundle = Path("exports/my_model")
(bundle / "tokenizer").mkdir(parents=True, exist_ok=True)
AutoTokenizer.from_pretrained(HF_ID).save_pretrained(bundle / "tokenizer")

metadata = {
    "metadata_version": "0.2",
    "kind": "llm",
    "name": "my_model",
    "assets": {"main": "my_model.aimodel"},
    "language": {
        "tokenizer": HF_ID,
        "vocab_size": hf_config.vocab_size,
        "max_context_length": hf_config.max_position_embeddings,
        "embedded_tokenizer": True,
        "function_map": {"main": ["main"]},
    },
    "source": {"model_definition": "torch", "hf_model_id": HF_ID},
    "compression": "4bit",
    "compilation": {"date": datetime.now().astimezone().isoformat(), "targets": []},
}
(bundle / "metadata.json").write_text(json.dumps(metadata, indent=2))
```

> ✅ **VERIFIED** — this is `bundle_llm_asset()` in
> `python/src/coreai_models/export/bundle.py:42-74` written out; the tokenizer line is verbatim what
> it does (`AutoTokenizer.from_pretrained(hf_model_id).save_pretrained(bundle_path/"tokenizer")`).

⚠️ **Do not skip `chat_template.jinja`.** `save_pretrained` on a modern `transformers` writes it, but
if you assemble `tokenizer/` by copying selected files — as the broken Gemma 4 bundles in §6.8 did —
it is exactly the file people forget. **Check for it explicitly** before you call the bundle done:

```bash
ls exports/my_model/tokenizer/
# expect: tokenizer.json  tokenizer_config.json  special_tokens_map.json  chat_template.jinja
```

One more publishing-time trap, if you intend to distribute the bundle:

> **Community practice** — `PORTING.md:298-300`: *"`swift-transformers` rejects unregistered
> `tokenizer_class` values — retag the bundle's `tokenizer_config.json` to a registered class (e.g.
> `PreTrainedTokenizer` → `BPETokenizer`) in your upload script; decode stays exact because it is
> driven by `tokenizer.json`."*
>
> ✅ **Consistent with Apple's dependency graph** — `apple/coreai-models` `Package.swift` depends on
> `huggingface/swift-transformers` (pinned 1.2.0), and `LanguageBundle.loadTokenizer()` calls
> `AutoTokenizer.from(modelFolder:)`.

### 9.5 The producer fingerprint, and the incident that made it matter

An unusually concrete reproducibility lesson, and one you should build into your own tooling.

> **Community incident, cross-referenced to Apple** — `coreai-torch-041-ir-incident.md`, dated
> 2026-07-18. Every `.aimodel` converted with **`coreai-torch` 0.4.0** stopped loading on **iOS/macOS
> 27 beta 2 and later**; it ran on beta 1. Both `AIModel.load` and `coreai-build compile` abort with:
>
> ```
> error: expected AICode versioned location, got: loc(fused<...>)
> error: Failed to convert to versioned IR
> LLVM ERROR: cannot unwrap empty `odiec_module_t`
> ```
>
> **Root cause, per Apple** (`apple/coreai-torch` issue #37, v0.4.1 release notes): *"0.4.0 baked
> PyTorch stack traces into the IR as MLIR `fused` locations; the beta-2 compiler no longer parses
> that nested form. It fires on deep module hierarchies."*

The reason this belongs in an export guide rather than a changelog is the **detection method** — a
one-field audit that works on any tree of assets:

```
0.4.1 (good):  {"producer": "coreai-core 1.0.0b2", "assetVersion": "2.0", "creationDate": ...}
0.4.0 (dead):  {"assetVersion": "2.0"}
```

> **Community practice**: *"Audit any tree by that field alone — no dates, no guessing."* Caveat from
> the same doc: *"`.aimodelc` bundles **always** carry a `producer` (the `coreai-build-<ver>`
> string), so for those use the **source** `.aimodel`'s producer, not the compiled one."*

And the negative list, which is the valuable part:

> **Community-verified negatives** — none of these recover a 0.4.0 asset:
> - `coreai-build package` — *"re-emits the asset (producer bumps) but leaves IR locations
>   untouched; compile fails identically."*
> - Pinning `coreai-core` back to `1.0.0b1` — *"the gate is OS-side, not in the wheel."*
> - Re-AOT with the beta-3 toolchain — *"dies at the same op."*
> - ⚠️ *"`coreai-build inspect` still reads the asset fine — **which makes it look recoverable. It
>   isn't.**"*

Apple later shipped an in-place repair (`apple/coreai-torch` issue #44):

```python
from coreai_torch.debugging.debug_info import strip_debug_info
from coreai.authoring import AIModelAsset

asset = AIModelAsset.load(path)
strip_debug_info(asset.program)
asset.program.save_asset(out_path)
```

> 🟡 **RECONSTRUCTED** — `strip_debug_info` is real: `coreai_torch/debugging/debug_info.py` exists in
> the module map we verified, and the community reports it *"Verified on 40 zoo bundles: weights
> byte-identical, minutes per model, stripped assets load clean on beta 3."* The exact snippet above
> is the community's, not Apple's published example. There is a **chicken-and-egg caveat**: on a
> beta-2+ machine *"the snippet above cannot even load the asset (the authoring bytecode reader in
> `coreai-core` 1.0.0b2 wheels runs the same versioned-IR conversion and aborts)"*, so the working
> recipe needs an isolated venv with **coreai-torch 0.4.0 + coreai-core 1.0.0b1** to parse, then a
> re-load/re-save with the b2 wheel to get a proper producer fingerprint.
>
> ⚠️ **Two gates that look like one.** The same document self-corrects: *"The earlier 'pinning
> `coreai-core` back to 1.0.0b1 does not help, the gate is OS-side' finding in this doc was about the
> **RUNTIME load** path; for the **AUTHORING parse** the gate is in the wheel, not the OS."* That
> distinction — OS-side load gate vs wheel-side parse gate — is worth carrying into any debugging of
> "it won't open" on this stack.
>
> *"`.aimodelc` (compiled) artifacts **cannot** be stripped — those need re-export + AOT recompile."*

⚠️ **SILENT FAILURE, packaging edition.** From the same incident write-up, and this one costs days:

> **Community practice**: *"**Never run python with the `coreai-torch` clone as cwd**: its
> `coreai_torch.egg-info` (0.4.0) shadows the installed 0.4.1 via `sys.path[0]`, so **exports
> silently use 0.4.0**."*

Nothing errors. You get assets that appear fine on your machine and die on a colleague's. Combine
this with the producer-field audit and you have a real check: after every export, assert the
producer.

### 9.6 Conversion is not byte-deterministic

Build this into your expectations before you build CI around it.

> **Community-measured** — `CATALOG_PLAN.md:116-121`, dated 2026-07-25: *"the same recipe run twice
> on the same machine, minutes apart, produces `.aimodel` bundles that differ from each other
> (**`main.mlirb` by 7 bytes, `main.hash` entirely**) — and the published bundle differs from both by
> **492 bytes out of 1.19 GB**. Conversion is not byte-deterministic, so 'did this recipe reproduce
> the published bundle?' can only be answered behaviourally."*

**Consequence: a stored hash is worthless as a reproducibility criterion for a `.aimodel`.** If you
want CI to answer "did this recipe still work", the answer has to be a **gate script** (§6), not a
checksum. Same conclusion Apple's own tooling implies — nothing in `apple/coreai-models` compares
asset hashes either.

---

## 10. Stage 9 — AOT-compile per architecture

### 10.1 What specialization is, and why you would pay it in advance

A shipped `.aimodel` is device-agnostic. The OS turns it into something executable through
**specialization**, which happens in two phases:

> ✅ **VERIFIED** — WWDC26 session 324, 141-147, as captured in the community's transcript notes:
> (1) *"a core set of compilation steps that segment, plan, and optimize compute — **this is where
> most of the latency is**"*; (2) *"executable-artifact generation for the compute units used — these
> artifacts are **tied to the device + OS version**."* The result is cached. Apple's guidance,
> verbatim: *"This process can take a significant amount of time for very large models… **avoid
> having model specialization occur within user-interactive flows.**"*

Three levers, in increasing order of control:

1. **Do nothing** — first load pays specialization, the OS caches it, subsequent loads are fast.
2. **Specialize ahead of first use** at runtime, from your app.
3. **AOT-compile** with `xcrun coreai-build compile` and ship `.aimodelc` per architecture.

> ✅ **SDK-verified (upgraded from 🟡 on 2026-07-29)** — the runtime cache/specialize API quoted in
> the community notes as WWDC 324 verbatim:
>
> ```swift
> let cache = AIModelCache.default
> guard let model = try cache.model(for: modelURL, options: .default) else {
>     informUser("Preparing AI features. This may take a while…"); return
> }
> // or, ahead of first use:
> try await AIModel.specialize(contentsOf: modelURL)
> ```
>
> now checks out against the macOS 27.0 beta interface
> (`CoreAIDelegates-27.0-macos.swiftinterface`): `AIModelCache.default` and
> `init?(appGroup:)` (`:27-32` — the app-group sharing is real API, not narration),
> `model(for:options:) throws -> AIModel?` (`:33-36`), the four `delete*` methods (`:37-43`),
> `Policy`/`PurgeConditions` retention control (`:44-71`), and
> `AIModel.specialize(contentsOf:options:cache:cachePolicy:) async throws -> AIModel` — all
> arguments after the URL defaulted, so the one-argument spelling above compiles (`:22-26`).
> Part 7 is the guide that owns these types.

### 10.2 The compile command

```bash
xcrun coreai-build compile model.aimodel \
    --output out/ \
    --platform iOS \
    --architecture h18p \
    --preferred-compute gpu \
    --min-deployment-version 27.0
```

Full CLI surface:

```
coreai-build compile <input.aimodel> [--output <dir>]
    [--platform iOS|macOS|watchOS|visionOS|tvOS ...]
    [--min-deployment-version 27.0]
    [--preferred-compute gpu|neural-engine|none]
    [--architecture <arch> ...]
    [--expect-frequent-reshapes]
```

> ✅ **VERIFIED (the verb and the two flags Apple documents)** — `apple/coreai-models`
> `models/README.md` and `skills/skills/model-authoring/references/common_issues.md` show
> `xcrun coreai-build compile model.aimodel --platform iOS` and
> `… --preferred-compute neural-engine`.
>
> ✅ **Tool-verified (the full flag list) — 2026-07-31.** The synopsis above is now confirmed
> flag-for-flag against `coreai-build compile --help` run on this machine (`coreai-build
> 3600.79.1`; full capture in `notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`), including
> the defaults: `--platform` defaults to **macOS**, `--min-deployment-version` to **27.0**,
> `--preferred-compute` to **none**. The 2026-06-10 community capture
> (`aot-and-specialization.md:73-77`) was accurate. Subcommands beyond `compile`: `package`,
> `inspect`, `metadata`.
>
> ⚠️ **Where the tool lives — resolved 2026-07-31, and it matters for CI:** `coreai-build` is
> **not in Xcode-beta.app at all**; it ships in the optional **Metal Toolchain component**
> (`xcodebuild -downloadComponent MetalToolchain`) and resolves via `xcrun --no-cache --find
> coreai-build` to `~/Library/Developer/DVTDownloads/MetalToolchain/mounts/<hash>/
> Metal.xctoolchain/usr/bin/coreai-build`. A 2026-07-29 check of Xcode beta `27A5228h` without that
> optional component had found `xcrun --find coreai-build` failing and only
> `Contents/Developer/usr/bin/aimodelc` present (command types `package`/`compile`, `--output`
> required, no `--help`, binary embedding *"'aimodelc' is a tool used by the Xcode compiler"* and
> *"Please use 'xcrun coreai-build' instead"*) — an accurate observation of an install without
> the component. Naming resolved: **`xcrun coreai-build compile` is the verb; `aimodelc` is the
> Xcode-internal stub *and* the compiled extension**. Output is
> `modelName.architectureName.aimodelc`, matching the filename `ModelBundle.swift:103` tells you
> to write into `metadata.json`.

Output is **one `.aimodelc` per requested architecture**, each roughly **2× the `.aimodel` size**
(it embeds the precompiled graph). Ship them as Background Assets; the app detects its architecture
and requests the matching one.

> **Community-measured** — `aot-and-specialization.md`, verified 2026-06-10 on Xcode `27A5194q`,
> Metal Toolchain `v27.1.5194.15`, macOS 27.0 `26A5353q`: `--platform macOS` produced **20 per-arch
> `.aimodelc`** (`h13c`…`h17s`); `--platform iOS --preferred-compute neural-engine` produced **8**
> (`h13g h14g h15g h16g h16p h17g h17p h18p`).

### 10.3 ⚠️ Architecture names track the device identifier, not the marketing name

> **Community-measured, device-validated 2026-06-10** — `aot-and-specialization.md:108-121`:
> - **iPhone 17 Pro = `iPhone18,1` → `h18p`.** An `h17p` `.aimodelc` pushed to it *"fails to load
>   with `invalidCompiledModel`"*; the same model compiled `--architecture h18p` loads and runs.
> - **M4 Max Mac = `Mac16,x` → `h16c`.** *"Of all 20 macOS archs, only `h16c` loads in the Python
>   runtime on an M4 Max; h17\*/h16g/h16s all raise RuntimeError."*
> - ⚠️ **`coreai-build compile` exits 0 for ANY requested architecture** — *"a successful compile does
>   NOT validate the arch choice; only a device load does."*
>
> That document explicitly corrects its own earlier note (which had guessed `h17p` for iPhone 17 Pro
> by name-matching), which is a good sign about its method. Still: **community-measured, single
> author, single device of each kind.** Verify on your own hardware; the check is cheap.

⚠️ **A compile that exits 0 and an asset that loads are different claims.** This is the same shape as
every other silent failure in this stack. Build a device-load smoke test into your release process,
not just a build step.

🔴 **GAP — Apple publishes no architecture-name table. Narrowed 2026-07-31: the valid-code *set*
is now enumerated; the code→device mapping is still unpublished.** Probing the shipped
`coreai-build` 3600.79.1's own `--architecture` validation (it validates the code before touching
the input file, with distinct errors for unknown code / valid-but-wrong-platform / accepted)
enumerated **24 valid codes**: `h11p h11g h12p h13p h13s h13c h13g h14p h14s h14c h14g h15p h15s
h15c h15g h16p h16s h16c h16g h17p h17s h17c h17g h18p` — grammar `h<generation><variant>` with
`p` = phone-class, `s`/`c` = Mac-class, `g` from `h13g` up; `h17p` is the one code accepted for
both macOS and iOS at the 27.0 default target; **`h18p` (this section's device-validated iPhone 17
Pro code) is confirmed valid**, and no `h19*`/`h20*` exists in this toolchain. Method and full
per-platform matrix: `notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`, final section.
`compile --help` itself does *not* list the codes, and we still have no Apple documentation mapping
device identifiers to them — that half stays open. Meanwhile:
**compile for every architecture the tool offers for your platform** (omit `--architecture`; it is
cheap and produces one directory per arch), ship the set, and select at runtime — rather than
guessing a single name from a marketing model number. On device, `AIModel.deviceArchitectureName`
is the authority
(✅ **SDK-verified** — `CoreAIDelegates-27.0-macos.swiftinterface:107-112` — it exists and returns
`String`; the SDK does not enumerate the values either).

### 10.4 When you must AOT-compile

> **Community practice** — `PORTING.md:260-286`: *"On-device JIT specialization of a big static graph
> stalls or gets killed; roughly **≥ 1 GB means AOT**, ≤ ~50 MB JITs fine, in between try it."*

The device-verified case behind that rule is worth the space, because it is the clearest evidence in
the corpus for the "4B-class means GPU + AOT" conclusion in §3.6:

> **Community-measured, device-verified** — `aot-and-specialization.md:48-60`, FastContext-1.0-4B
> (a Qwen3-4B derivative) on **iPhone 17 Pro / iOS 27 beta**:
>
> | Attempt | Failure |
> |---|---|
> | **macOS**-tagged IR on iOS | no iOS delegates to load → `NSPOSIXErrorDomain Code=2` |
> | **iOS**-tagged palettized IR, on-device GPU specialization | *"exhausts the device's scratch disk mid-compile → `LLVM ERROR: No space left on device`"* |
> | **iOS ANE** bundle | static-loads (**31 ANE regions, ~518 s cold**) but warmup inference dies: `com.apple.appleneuralengine` / `ANECompilerService` **`Code=4097`** |
> | **GPU AOT `.aimodelc`** (`--preferred-compute gpu --architecture h18p`) | ✅ the only working on-device path |
>
> Conclusion, verbatim: 4B-class GPU bundles *"**must** be AOT-compiled per device class and shipped
> as `.aimodelc`. **ANE is worse at this size.**"*

Corroborating measurement from Apple's *own* recipes, same author, same protocol:

> **Community-measured** — `apple-models-bench.md`, iPhone 17 Pro / iOS 27 beta, Apple's official
> iOS presets, 512-token prompt / 1024-token generation / 5 trials, release build:
> **qwen3-4b ANE `.aimodelc` (3 GB): cold load 194 s, warm 0.46 s, 13.2 tok/s.** qwen3-0.6b ANE:
> cold 2.85 s, warm **0.045 s**, 69.6 tok/s on run 1 and 54.1 on run 2 — *"the drop on run 2 is
> **thermal**, not cache state."*

**194 seconds of cold load** is the specialization tax made concrete, and it is exactly what AOT
exists to remove. The measured AOT win on a comparable artifact:

> **Community-measured**, `aot-and-specialization.md:148-150`: `.aimodelc` **4.9 s** vs `.aimodel`
> **19.2 s** true-cold specialize (~4×, measured after a cache wipe); warm **0.0 s both** — the OS
> cache serves `.aimodelc` too. iPhone; int8-kernel monolith.

⚠️ **AOT is not a cure for memory.** Same source: a 1.8 GB 35-layer monolith compiled for the iOS ANE
**loads** on iPhone 17 Pro in 6.5–8.1 s with no jetsam — and then *"the first inference step is
jetsam-SIGKILLed — load ✅ / run ❌."* The ANE load left ~2.8 GB headroom where the GPU path left
~6.0 GB for the same-size core, and the first-step working set blew through it.

Practical device ceilings from the same corpus, **community-measured on iPhone 17 Pro (~12 GB RAM)**:
about **5–6 GB of int4 weights** is the runnable range (an 8B int4 at 5 GB runs; a 35B int4 at 18 GB
gets `signal 9` during a ~26-minute cold compile). Apple's own guidance is more conservative and
platform-level: *"Keep models under 2 GB"* on iOS and *"Leave at least 6 GB of RAM headroom"* on
macOS, checking `os_proc_available_memory()` at runtime.

> ✅ **VERIFIED (Apple side)** — `skills/skills/working-with-coreai/references/guidance.md`.

### 10.5 ⚠️ SILENT-ish FAILURE — `expectFrequentReshapes` on a fixed-shape graph

A subtle one, and it kills the app rather than degrading it — but with no error string, which is
what makes it feel silent.

> **Community-measured, device-validated 2026-07-23** — `aot-and-specialization.md:88-106`. **The
> hint is not free insurance — it is a request for a *reshape-tolerant* specialization.** Ask for it
> at load time on an all-static graph and the runtime **stops using the AOT specialization and
> compiles on device**, which on iPhone 17 Pro segfaults inside the MPSGraph AICode compiler:
>
> ```
> EXC_BAD_ACCESS (SIGSEGV) … MPSGraphAICodeCompilerDelegate getInitializedAICodeBytecodeWithPayloadPrefix:
>   → Compiler_coreAI.compile(moduleBytecode:to:with:) → libODIECompiler … CompileForDelegates
> ```
>
> *"No error string, no partial output — the app just dies at `AIModel(contentsOf:options:)`."*
> Found on a 5-fixed-shape-graph model; `expectFrequentReshapes = true` → SIGSEGV on the first graph;
> `= false` → **all 6 loads in 2.6 s, gate PASS**.
>
> ⚠️ *"Compiling with `--expect-frequent-reshapes` does NOT make the runtime hint safe"* — both the
> plain and the reshape-hinted `.aimodelc` crash when the *runtime* asks for the hint. **It is the
> load-time option that matters.**

Rule: set `expectFrequentReshapes = true` **only** where shapes really do change — dynamic query
length, bucketed prefill. **Static decode (`S=1`) and fixed-shape graphs must load without it.**

Note the interaction with §3.5: Apple's own `ModelStructure` sets `expectFrequentReshapes = true`
for `.dynamic` models and leaves it off for `.chunkedStatic`. That default is correct for the two
shapes Apple ships. If you hand-build a fixed-shape asset that the probe classifies as `.dynamic`
(one `main` function, static shapes), **you get the hint you must not have** — pass explicit
specialization options rather than relying on the probe.

### 10.6 After compiling: edit `metadata.json`

The step everybody forgets, called out in Apple's own docs and error strings:

> ✅ **VERIFIED** — `apple/coreai-models` `models/README.md:173`: *"If you compile a model, replace
> the corresponding asset in the bundle directory and update `metadata.json` to reference the new
> filename."*

```jsonc
{
  "metadata_version": "0.2",
  "kind": "llm",
  "name": "qwen3_0_6b_mixed_4bit_8bit_static",
  "assets": {
    // was: "qwen3_0_6b_mixed_4bit_8bit_static.aimodel"
    "main": "qwen3_0_6b_mixed_4bit_8bit_static.h18p.aimodelc"
  },
  "...": "..."
}
```

If you don't, you get `BundleError.missingAsset` — which, to Apple's credit, prints the fix.

⚠️ **And an uncompiled `.aimodel` will not run on iOS at all.**

> **Community-measured** — `apple-models-bench.md:31-42`: iOS execution *"requires AOT (`--platform
> iOS --preferred-compute <unit> --architecture h18p`), then point `metadata.json` `assets.main` at
> the `.aimodelc` — an uncompiled `.aimodel` fails at engine load with `NSPOSIXErrorDomain Code=2`."*
>
> 🔴 **GAP — is AOT *strictly required* on iOS, or only for large models?** The community report is
> unambiguous for the models it tested, but Apple's own `models/README.md` frames compilation as
> optional ("if you compile a model…"), and the ~50 MB-JITs-fine claim in `PORTING.md` implies small
> models do load uncompiled. **Resolving this needs an Apple statement or a controlled test with a
> tiny iOS asset.** Meanwhile, the safe default: **AOT-compile everything you ship to iOS.** It costs
> a build step and removes an entire failure class.

### 10.7 Two device-integration traps that have nothing to do with ML

Both community-reported, both cost a day:

> **Community practice** — `conversion-guide.md:173-186`:
> - ⚠️ **`.aimodel` directories cannot be embedded in an app bundle** — *"the installer misreads the
>   extension-suffixed root dir as a nested bundle → 'invalid bundle'."* Ship via download
>   (Background Assets) or sideload into `Documents/`.
> - ⚠️ **Never name a folder `Resources/` at the iOS bundle root** — CodeSign fails with *"code
>   object is not signed at all (embedded.mobileprovision)"*.

And the loudest warning in the entire community corpus, which belongs in any guide that mentions
building two artifacts:

> ⚠️ **Community practice** — `PORTING.md:250-252`, verbatim: ***"Never execute an iOS-compiled
> bundle on a Mac. It can wedge the GPU/ANE stack and take the whole machine down (watchdog reboot).
> Mac bundles on Mac, iOS bundles on device. This is the one mistake in this document that costs a
> reboot instead of an afternoon."***

Not Apple-stated. But the cost of heeding it is zero and the cost of testing it yourself is a
reboot, so heed it.

---

## 11. Stage 10 — load it in Swift

### 11.1 The whole integration

```swift prelude:external-module
import FoundationModels
import CoreAILanguageModels

let modelURL = URL(fileURLWithPath: "/path/to/exports/qwen3_0_6b_4bit_dynamic")

let model = try await CoreAILanguageModel(resourcesAt: modelURL)
let session = LanguageModelSession(model: model)
let response = try await session.respond(to: "What is quantum computing?")
print(response)
```

> ✅ **VERIFIED** — this exact snippet is the canonical app example repeated in every model README in
> `apple/coreai-models` (e.g. `models/qwen3/README.md`), and
> `swift/Tests/LanguageModelsTests/PublicInterfaceTests.swift` asserts that `response.content` also
> type-checks. Session 326:103-118 narrates it: *"To load, it's just one line… Notice we're importing
> FoundationModels here. This is the same framework you may already be familiar with… **Same
> `session.respond(to:)` call, same streaming support, same structured output capabilities.**"*

Add the package:

```swift illustrative
// Package.swift
.package(url: "https://github.com/apple/coreai-models", branch: "main"),
// then, per target:
.product(name: "CoreAILM", package: "coreai-models")
```

> ✅ **VERIFIED** — `Package.swift` product/target map: `CoreAILM` → target
> `CoreAILanguageModels`. (Also `CoreAIDiffusion`, `CoreAISegmentation`, `CoreAISpeech`,
> `CoreAIObjectDetection`.) Session 326:94-99 shows the same in Xcode: *"we can select the
> **CoreAILM** and **CoreAISegmentation** to my app target."*
>
> ⚠️ The package pins `mlc-ai/xgrammar` on **branch `main`**, not a version — a reproducibility
> footgun you inherit. `Package.resolved` in the repo pins a specific revision; resolve your own and
> commit it.

### 11.2 The full initializer

```swift illustrative
public struct CoreAILanguageModel: LanguageModel {
    public enum LoadMode: Sendable { case lazy; case eager }
    public typealias Executor = CoreAIExecutor

    public init(
        resourcesAt url: URL,
        mode: LoadMode = .lazy,
        variant: String? = nil,                    // "coreai-sequential", "coreai-pipelined", …
        kvCacheStrategy: KVCacheStrategy = .auto
    ) async throws

    public var capabilities: LanguageModelCapabilities
    public var executorConfiguration: CoreAIExecutor.Configuration
    public var estimatedSizeOnDiskBytes: Int? { get }
    public func load() async throws
    public func unload()
}
```

> ✅ **VERIFIED** — `swift/Sources/CoreAILanguageModels/LanguageModel/CoreAILanguageModel.swift:78-104`
> (the initializer, with its full doc comment) and `:12-32` (the usage block). Lifecycle:
>
> ```swift
> let model = try await CoreAILanguageModel(resourcesAt: url)  // .lazy by default
> print(model.estimatedSizeOnDiskBytes ?? 0)
> try await model.load()                                       // optional; respond auto-loads
> let session = LanguageModelSession(model: model)
> // ... generate ...
> model.unload()
> ```

What `init` does: builds a `LanguageBundle`, constructs a `CoreAIExecutor.Configuration`, obtains a
**process-shared** `ModelResources` for that configuration, then loads the tokenizer and (if
`.eager`) the engine **concurrently** with `async let`.

The `ModelResources` layer is worth knowing about because it determines what happens under
concurrency:

> ✅ **VERIFIED** — `LanguageModel/ModelResources.swift`:
> - `engine()` — a **single in-flight load shared by concurrent callers**; failures are **not
>   cached** (the task is dropped so the next caller retries).
> - `withEngine { … }` increments `activeBorrows`; a concurrent `unloadResources()` sets
>   `unloadPending` and defers teardown *"so the engine is never freed mid-generation."*
> - `static func shared(for: Configuration)` — a **process-wide registry keyed by the Hashable
>   Configuration**, values held in a `WeakBox` so releasing the model releases the engine.

So two `CoreAILanguageModel`s built from the same URL, variant and cache strategy **share one
engine**. Change any field of the configuration and you get a second engine — and a second copy of
the weights in memory.

### 11.3 Choosing the engine

Three engines, selected by `variant:` or auto-detected from the asset's structure:

| Variant string | Engine | Compute | `supportsLogits` | Required structure |
|---|---|---|---|---|
| `"coreai-sequential"` | `CoreAISequentialEngine` | CPU-side sampling, dynamic model | **true** | `.dynamic` |
| `"coreai-pipelined"` | `CoreAIPipelinedEngine` | GPU, on-device sampling | **false** | `.dynamic` (auto default) |
| `"static-shape"` | `StaticShapeEngine` | Neural Engine, chunked static | **true** | `.chunkedStatic` (auto default) |
| `nil` / `"auto"` / `"default"` | auto-detect | — | — | — |

> ✅ **VERIFIED** — `swift/Sources/CoreAILanguageModels/InferenceEngines/EngineFactory.swift`.
> Compatibility errors are explicit: staticShape × dynamic → *"Static-shape variant requires chunked
> static model (extend_\* functions)"*; pipelined × chunkedStatic → *"Core AI pipelined variant
> requires dynamic model"*; sequential × chunkedStatic → *"Sequential variant requires dynamic
> model"*.

The KV-cache strategy is the other knob:

```swift illustrative
public enum KVCacheStrategy: String, Codable, Sendable, CaseIterable {
    case auto      = "auto"
    case fixedSize = "fixed_size"
    case growing   = "growing"
    case chunked   = "chunked"     // NOT IMPLEMENTED — falls back to StaticKVCache
    public func defaultSize(maxContextLength: Int) -> Int? { … }
}
```

> ✅ **VERIFIED** — `KVCacheStrategy` in `apple/coreai-models`. `.auto` resolves in
> `KVCacheFactory.make` to `growing` when the model's key-cache seq dim is `-1` (dynamic), else
> `fixedSize`. Documented behaviour of `.growing`: *"Start small, grow exponentially (2×) … ~20 ms
> stall on growth (amortized O(log₂ N))"*, initial size **256**.

⚠️ **SILENT FAILURE — `.chunked` is accepted and does nothing.** The enum case exists, the
`defaultSize` switch handles it, and the factory falls back to `StaticKVCache`. You get `fixedSize`
behaviour under a different name, including its memory profile.

⚠️ **`.fixedSize` pre-allocates at the full `maxContextLength`.** Apple's own doc warning: *"Avoid
`.fixedSize` unless you need a known upper bound. It pre-allocates the cache at the full
`maxContextLength`, which can consume **several gigabytes** on long-context models and **slows each
decoding step** because every iteration operates on the full-size KV."* On a 262,144-context preset
that is not a rounding error.

One more error string worth recognising, because it points at a flag that does not exist here:

> ⚠️ **UNVERIFIED reference in shipped code.** `KVCache+CoreAI.swift` / `KVCacheShared.swift` throw
> *"Strategy 'growing' requires dynamic KV cache support. Model has fixed seqDim. **Re-export with
> `--dynamic-sized-kvcache-gpu` flag.**"* — but **no such flag exists in this repo's Python export
> CLIs.** It presumably belongs to an internal or earlier exporter, or was renamed. Do not go looking
> for it in `coreai.llm.export`; it is not there. If you hit this error, the fix is to export with
> the macOS dynamic path (§8.1), which gives the cache a dynamic seq dim by construction.

### 11.4 ⚠️ The GPU-pipelined engine cannot do guided generation

This is a first-class architectural constraint, not a footnote, and it is the single most
consequential thing to know before you pick an engine.

> ✅ **VERIFIED** — `CoreAIPipelinedEngine.swift` throws on `includeLogits == true`:
> *"CoreAI pipelined engine does not support logits (GPU-side sampling). Use a sequential engine for
> constrained generation or evaluation."* And on `forcedContinuation != nil`: *"…does not support
> forcedContinuation (GPU-side sampling). Use a sequential engine for evaluation."*
>
> The FM adapter surfaces it as a capability: `isGuidedGenerationSupported` = the loaded engine's
> `supportsLogits` if known, else `variant != "coreai-pipelined"`. When it isn't supported,
> `CoreAIExecutor.respondConstrained` throws
> `LanguageModelError.unsupportedCapability(.init(capability: .guidedGeneration, debugDescription:
> "This model's inference engine does not support guided generation (constrained decoding requires
> per-step logits)."))`.
>
> **Community framing, corroborating** — `coreai-vs-mlx-speed.md` §5.3: *"FM guided generation
> (`@Generable`) needs engine logits, and the GPU-pipelined fast path does not expose logits."* The
> author files this under *"reverse differential — logits / guided generation favour MLX."*

**So: an app that brings its own Core AI model loses Apple's flagship structured-generation feature
exactly when it selects the fastest backend.** Your options:

| Want | Do |
|---|---|
| `@Generable` on a Core AI bundle | Pass `variant: "coreai-sequential"` (or ship a chunked-static/ANE bundle, which also has logits) and accept the throughput cost |
| Maximum decode speed | Pipelined, and do structured output by prompting + parsing, not by grammar constraints |
| Both | Two sessions, or a two-pass design: fast free-form generation, then a small constrained pass |

⚠️ And note this also removes **`forcedContinuation`**, which is how you compute
`P(continuation | context)` — so **MMLU-style evaluation is impossible on the pipelined path too.**

### 11.5 What the FM adapter does and does not forward

> ✅ **VERIFIED** — `CoreAILanguageModel.swift` / `CoreAIExecutor`:
> - `maxTokens = request.generationOptions.maximumResponseTokens ?? (model.supportsReasoning ? 2048 : 512)`
> - **Only `options.temperature` is honoured.** `makeSamplingConfig` returns
>   `SamplingConfiguration(temperature:)` when set, else the model's base config (`.greedy`).
>   **`topK` / `topP` / `minP` are not reachable through the FM path** — they exist on
>   `SamplingConfiguration` and on the CLI, but the adapter does not forward them.
> - `.reasoning` transcript entries are **skipped** when re-templating: *"Don't echo the model's
>   prior reasoning back into the prompt."*

Capability detection at init is heuristic and worth knowing:

> ✅ **VERIFIED** — `supportsReasoning` = the tokenizer has `<think>` **or**
> `<|reasoning_start|>`. `supportsToolCalling` = `detectToolCallMarkers(using:) != nil`, which tries
> `("<tool_call>", "</tool_call>")`, then `("<function_calls>", "</function_calls>")`, then a Mistral
> special case `("[TOOL_CALLS]", "\n")` — a **synthetic close marker**, because the JSON array is
> single-line. ⚠️ A multi-line Mistral tool call would break that parser.

And the detokenization detail that explains why you should not roll your own:

> ✅ **VERIFIED** — `respondVanilla` in `CoreAIExecutor`: on U+FFFD **in the full decoded text** (not
> just the delta) it holds the token and emits `.appendText("", tokenCount: 1)`, because *"Some
> tokenizers emit one U+FFFD per attempted decode of an incomplete multi-byte sequence … making
> `delta` empty and hiding the still-incomplete state."* After a clean emit it retains **exactly one**
> trailing token as context: *"SentencePiece needs at least one prior token to infer the leading ▁
> (space) on the following token; clearing to empty decodes each new token in isolation and drops
> inter-word spaces."*

That is two real bugs — mojibake on multi-byte characters, and missing spaces — that Apple already
fixed for you in ~40 lines. It is a good argument for using `CoreAILM` rather than driving
`InferenceEngine` directly.

### 11.6 Stop tokens

> ✅ **VERIFIED** — `LanguageConfig.additionalStopTokenIds(from:tokenizer:)` parses
> `tokenizer_config.json` best-effort (returns `[]` on any failure) and collects:
> 1. `additional_special_tokens` (strings or `{"content": …}` dicts)
> 2. an array-valued `eos_token`
> 3. `added_tokens_decoder` entries with `special == true` whose lowercase content contains one of
>    `["end_of_turn", "im_end", "eot_id", "endoftext"]`
>
> Two commits explain the list: `cba2c84` added `"endoftext"` because *"Qwen3 declares `eos_token` as
> `<|im_end|>` (151645) but xgrammar can also produce `<|endoftext|>` (151643) as a valid grammar
> terminal"*; `02a8edd` ("Fix Gemma stop tokens") because Gemma's `<end_of_turn>` is token 106.

This is the mitigation for the eos-vs-eot problem in §6.8 — **but it only works if your bundle's
`tokenizer_config.json` is correct**. Another reason Gate B (§6.5) covers the tokenizer directory.

### 11.7 The CLI tools, for testing before you write app code

```bash
swift run -c release llm-runner    --model exports/qwen3_0_6b_4bit_dynamic --prompt "Hello"
swift run -c release llm-benchmark --model exports/qwen3_0_6b_4bit_dynamic     # -p 512 -g 1024 -n 5
```

⚠️ **`swift run` defaults to Debug.** `llm-benchmark` prints a warning when built that way, and the
docs always say `-c release`. A Debug measurement is not a measurement.

`llm-runner`'s options that matter for export debugging:

```
--model PATH                       model bundle DIRECTORY (required)
--prompt TEXT | --prompt-file PATH | --raw-tokens PATH     (mutually exclusive)
--max-tokens INT                   default 50
--sampling-strategy {temperature,greedy}   default "temperature"
--temperature DOUBLE               default 0.7
--top-k / --top-p / --min-p        (error if combined with greedy)
--json-schema STRING|PATH          constrained generation
--inference-engine-variant STR     auto|default|coreai-sequential|coreai-pipelined|static-shape
--kv-cache-strategy {auto,growing,chunked,fixed_size}
--kv-cache-initial-capacity INT
--stop-tokens STR                  repeatable
--save-logits PATH · --save-logits-length {1..20|full}
--print-logits
--apply-chat-template BOOL         default true
--continuation TEXT                requires --apply-chat-template=false AND (--print-logits|--save-logits)
--warmup {default,off,none,exact} · --warmup-length INT   (hidden; only with --warmup exact)
--bucket-size INT                  hidden; sets env COREAI_QUERY_BUCKET_SIZE (0 disables, default 64)
--chunk-size INT                   hidden; sets env COREAI_CHUNK_THRESHOLD (default 1024, "use 128 for MoE")
--verbose / --verbose-level INT
```

> ✅ **VERIFIED** — `swift/Sources/Tools/llm-runner/LLMRunnerMain.swift:67-205`, read in full.
>
> **Model search order** (`Assets/ModelPaths.swift`): `--model` (explicit; absolute paths must
> exist) → env `COREAI_MODEL_PATH` (colon-separated) → defaults `[".", "./exports",
> "~/.coreai-models"]`. Error: *"Model '\<x>' not found. Searched: \<expanded paths>"*.
>
> Asset extension guard: only `aimodel` ("source") and `aimodelc` ("compiled") are accepted; anything
> else prints *"Unsupported model file: only .aimodel or .aimodelc"*.

`--save-logits` + `--print-logits` are the bridge back to your Gate A harness: you can run the exact
Swift path and diff its logits against the Python oracle, which isolates "the Swift runtime does
something different" from "the asset is wrong".

`llm-benchmark`:

```
--model PATH (required)
-p/--prompt-tokens INT      default 512
-g/--generation-tokens INT  default 1024
-n/--num-trials INT         default 5
--seed UInt64               default 0
--output-json PATH
```

> ✅ **VERIFIED** — `swift/Sources/Tools/benchmark/BenchmarkMain.swift`. *"Based on mlx-lm
> benchmark."* Uses greedy `SamplingConfiguration(temperature: 0)` and a synthetic splitmix64 random
> prompt. **The generation tok/s denominator is `count - 1`** — the prefill-produced first token is
> excluded. JSON keys are snake_cased (`prompt_tps`, `gen_tps`, `averages.prompt_tps`,
> `averages.generation_tps`).
>
> ⚠️ The executable target is named **`llm-benchmark`** and it imports `CoreAILanguageModels`.
> **There is no non-LLM benchmark tool in the repo**, and no quality or latency number is published
> for any non-LLM model there.

⚠️ One asymmetry to know: **`ModelBundle.verify()` — which checks that every declared asset exists on
disk — is only called by `llm-runner`, not by `CoreAILanguageModel.init`.** So the CLI catches a
broken `assets` map that your app will hit later, at a worse time. Run the CLI once against every
bundle you ship.

---

## 12. The community porting playbook, as a checklist

Everything in this section is **community practice** from `john-rocky/coreai-model-zoo`
(`PORTING.md`, 351 lines, plus `AGENTS.md` and two agent skills). It is reproduced because it is the
only end-to-end porting process document that exists for this stack, and because it is *complementary
to*, not competing with, Apple's `model-authoring` skill.

### 12.1 How it relates to Apple's skill

| Axis | Apple `model-authoring` | Community `port-a-model-to-the-zoo` |
|---|---|---|
| Scope | **Inside** the PyTorch module: how to write ops so they lower well | **Around** the module: oracle, gates, device, publishing |
| Organising frame | Compute unit (ANE / GPU / CPU) and tensor layout | Process stages with falsifiable checkpoints |
| Verification metric | **PSNR in dB** | **cosine ≥ 0.999 + token-exact argmax** |
| Compression guidance | Palettization PSNR table (8-bit ~2× / > 55 dB; 4-bit ~4× / ~40 dB; 2-bit ~8× / 25–35 dB, *"usually unacceptable"*) | *"int4 is a cliff, not a slope"*; int8 default for LLMs; **read the generations** |
| Device / deploy | not covered | AOT (`h18p`), sideload, self-test entrypoint, thermals |
| Publishing | not covered | HF repo, model card, `recipe.toml`, bundle verifier |
| Authority | **Apple-official** | **Community** |

The community repo says so itself: *"Apple's own `coreai-skills` covers the toolchain itself;
**install both**."* That is the right advice. Apple tells you how to write the module; the playbook
tells you how to know it works and how to get it onto a phone.

Three places where they *actually differ in advice*, not just in scope, and where you should know
both positions:

1. **Metric.** Apple is PSNR throughout, including a compression PSNR table. The community uses
   cosine + token-exactness for LLMs and is explicit that *"Step 1 looking fine is not a gate; AR
   drift shows up late."* Apple's skill has no per-token autoregressive-drift gate. See §6.3.
2. **KV cache mechanism.** Apple prescribes a stateful export wrapper (`register_buffer` +
   `hoistToArg`) for GPU and a **readonly functional I/O** pattern for the ANE, with the rule *"Do
   not use stateful transforms for token generation — state resets between inference calls."* The
   community prescribes in-graph mutable state via `slice_update` + `remove_functionalization(ep)`.
   **These are probably different layers rather than alternatives** — see the 🔴 GAP in §5.4.
3. **Discovery.** Apple's `model-authoring` phase 1 is *"run code, don't read code"* using
   `register_forward_hook` to capture intermediates — discovery only. The community turns the same
   instinct into a **persisted artifact** (`oracle.npz`) that gates every later stage.

One convention Apple has and the community does not: **a `from_source_model` classmethod on every
re-authored model**, config-driven, *"no hardcoded constants"*, plus `load_weights_from`. Adopt it;
it is what makes a re-authored model reusable across checkpoint sizes.

### 12.2 The checklist

**Stage 0 — gate the port before writing code.**

- [ ] **GAP** — does Apple's stock stack already ship this capability? If yes, **stop**.
- [ ] **EDGE** — will the port be at least as good as the realistic alternative, **especially MLX**?
      The repo's own note: *"this repo has shipped and then pulled two of those [worse-than-MLX
      ports]."* And: *"'The user asked for it' is not an answer to EDGE."*
- [ ] **DEVICE** — does it fit an iPhone (**~6 GB practical ceiling**)? Top tier. Mac-only = tier 2.
- [ ] **LICENSE** — does it permit redistributing converted weights?
- [ ] For a *first* port: stateless, single graph, < 1 GB fp16.

**Stage 1 — setup.**

- [ ] Apple silicon Mac on **macOS 27** (*"the runtime is OS-bound; betas count"*), **Xcode 27**,
      Python 3.11+.
- [ ] Keep **two venvs** if the target model needs a newer `transformers` than the export stack
      likes. *"Don't cross-contaminate."*
- [ ] *"GPU work on the beta driver is happiest **serialized** — run one export/verify at a time."*
- [ ] Checkpoint: `python -c "import torch, coreai_torch, coreai.runtime"` runs clean.

**Stage 2 — the oracle comes first.**

- [ ] `oracle.npz` from the **unmodified HF model in fp32**.
- [ ] For an LLM: **per-step logits (or at minimum per-step argmax) for a few dozen greedy steps.**
- [ ] Save the **preprocessed tensor** too (for an LLM: the token ids).
- [ ] Deterministic prompt. *"The capital of France is."*

**Stage 3 — re-author and export.**

- [ ] Re-author in plain torch **from `model.safetensors`**, not from `modeling_*.py`.
- [ ] *"Keep it boring: explicit cos/sin RoPE (no complex ops), explicit RMS/L2 norms with the eps
      inside (**`F.normalize` silently drops it**), no data-dependent branches."*
- [ ] **Fix the input contract** — decide the static shapes, push variable-length logic to the host.
- [ ] **Fold what you can into the graph** — normalization baked in means *"one class of host bugs
      disappears."*
- [ ] **Let dead code die** — export only the outputs you need; `optimize()` DCEs the rest.
- [ ] LLM adds three systems: **KV cache as in-graph mutable state** (⚠️ `remove_functionalization`),
      **prefill and decode as different shapes of the same weights**, **tokenizer and sampler on the
      host**.

**Stage 4 — Gate A, graph parity.**

- [ ] Load with `SpecializationOptions.cpu_only()`. Parity only, never timing.
- [ ] Bar: **per-token cosine ≥ 0.999 on logits AND greedy argmax token-exact** over the oracle's
      steps. *"Token-exact is the headline; per-token cosine tells you where it broke when it isn't."*

**Stage 5 — Gate B, host processing in NumPy.**

- [ ] Every host-side algorithm implemented in NumPy **before** Swift, gated against the oracle.
- [ ] Checkpoint: a `gate_*.py` prints PASS from a clean run with no manual steps. *"This script goes
      in your PR; it is the reviewable artifact."*

**Stage 6 — compress, then re-gate.**

- [ ] Small models (< ~1.5 GB fp16): **ship fp16**.
- [ ] LLM default: **int8**. *"the reliably-safe LLM scheme on this stack."*
- [ ] **Re-run Gate A on the compressed bundle.** *"compression is part of the model, so it gates
      like the model."*

**Stage 7 — Mac timing.**

- [ ] Time with `SpecializationOptions.default()`, never `cpu_only()`.
- [ ] **Report load time and steady-state throughput separately** — the first call includes
      specialization.
- [ ] ⚠️ **Never execute an iOS-compiled bundle on a Mac.**

**Stage 8 — device.**

- [ ] **AOT-compile** anything ≥ ~1 GB.
- [ ] Sideload into `Documents/Models/<X>/`; *"Push many files individually rather than one giant
      transfer, and **verify a copy by reading it back — wired-tunnel transfers can report success
      falsely**."*
- [ ] Measure with an **env-gated headless self-test** (`<X>_SELFTEST=1`), 1 cold + N warm.
      *"Numbers measured through a chat UI are not comparable to anything."*
- [ ] Record `thermalState` and low-power mode alongside every number.

**Stage 9 — publish.**

- [ ] Weights under your own account; export **and gate** scripts in the repo; a model card; a
      `recipe.toml`; a README row.
- [ ] Review bar: *"Gate A numbers as claimed and **re-runnable** · host processing NumPy-gated ·
      license clean · card complete with measured, device-attributed numbers · **no weights/binaries
      in the git PR itself**."*

### 12.3 The traps that specifically catch agents

Reproduced nearly verbatim from `AGENTS.md:65-79`, because every one of them is a real incident:

1. **Trusting notes over the oracle.** *"a handoff note said 'no input normalization'; the oracle
   showed the feature extractor always normalizes."*
2. **Re-authoring from the HF `modeling_*.py` instead of the weights.** *"The modeling file has
   branches that never run for this checkpoint, and hides ones that do."*
3. **Believing int4 because the loss looks fine.** *"int4 is a cliff, not a slope."*
4. **Timing with `cpu_only()`.** That is the parity option.
5. **Benchmarking through a chat UI.** *"Headless self-test entrypoint, or it did not happen."*
6. **JIT-ing a ≥ 1 GB graph on device.** AOT-compile it.
7. **Running an iOS bundle on a Mac.** *"Wedges the GPU stack; costs a reboot."*
8. **Naked `exp()` in a hand-written kernel.** *"Three separate sessions lost to this; subtract the
   max first."*
9. **Comparing quality across runtimes without matching the generation budget.** *"A 12-point
   'quality gap' in this repo's history turned out to be a 600-vs-2048 token cap difference."*

And an authority boundary that is worth adopting wholesale if you let agents near an ML repo — the
repo's *"not your call"* list: publishing weights, posting publicly, opening issues or PRs against
`apple/*`, and **marking a port `verified` on numbers you did not produce.** Plus, from
`CATALOG_PLAN.md`: *"Verification tiers that cannot run report `skipped`. **Never `pass` for a tier
that did not execute.**"* and *"If the test's premise turns out to be wrong, **report that rather
than adjusting the result to match**."*

### 12.4 The cross-runtime measurement checklist

If you ever compare your bundle against MLX, llama.cpp or LiteRT, use this. It exists because a
published-looking result — *"Core AI 80 % vs MLX ~20 %"* on GSM8K — turned out to be **entirely a
harness artifact**:

> **Community incident** — `cross-runtime-quality-benchmarking.md`, 2026-07-17. Two defects that hid
> each other:
> 1. *"**HF's `apply_chat_template` defaults to thinking ON. The same template rendered by
>    swift-transformers (what `llm-runner` uses) comes out thinking OFF**, and `llm-runner` exposes
>    no flag to turn it on."* One arm did chain-of-thought; the other answered directly.
> 2. The thinking arm needed 419–479 tokens per item and the budget was **512** — right at the cliff.
>    *"A truncated reasoning arm is indistinguishable from a bad model. Nothing in the log says
>    'truncated' — you get a confident wrong number."*
> 3. *"the arm we had **handicapped** was the one that **scored well** … **The harness manufactured
>    the result we would have liked.**"*

The checklist, verbatim in substance:

- [ ] **Same checkpoint.** *"Not 'both int4' — the same file."*
- [ ] **Same mode.** Thinking/reasoning defaults differ **per template renderer**, not just per
      model. Verify by grepping the raw generations for the thinking marker — *"do not trust the
      template source."*
- [ ] **Budget ≥ 2× the observed worst case.** Measure the worst case first. *"Never set the budget
      from the typical length."*
- [ ] **Check the truncation rate explicitly.** Count generations that hit `max_tokens` without
      emitting the answer marker. *"If it is not ~0, the score is a budget artifact."*
- [ ] **Probe-item parity before the full run** — one item through every arm; compare prompt token
      count, output token count, and answer.
- [ ] **Store a report per run** with `n`, `max_tokens`, mode, checkpoint, per-item predictions.
- [ ] *"**Inherited numbers are not measurements. If you cannot re-run it, do not cite it.**"*

One more from the same document, which is a genuinely good technique: **use a hardware ceiling to
falsify an assumption.** *"Gemma-4 gathers its PLE, so model size ≠ bytes/token (**MLX at 181.9 tok/s
× 3.3 GB = 600 GB/s would exceed the M4 Max's 546 GB/s peak** — proof that no arm reads its whole
file per token)."*

---

## 13. The hybrid / SSM wall

If you are considering porting a linear-attention, hybrid or state-space model — **Qwen3.5 /
Qwen3.6 (GatedDeltaNet), LFM2.5, Granite 4 (Mamba2)** — read this before you spend a week.

### 13.1 The bundles fail at load

> **Community-reported, with a precise mechanism** — `john-rocky/coreai-models` (a fork of
> `apple/coreai-models`), `README.md:9-14`, verbatim: *"**Why this fork exists.** The upstream Swift
> pipelined inference engine **validates exactly two model states** (the KV cache pair) and only
> `input_ids`/`position_ids` inputs, so it **cannot load hybrid-attention or state-space language
> bundles** — e.g. Qwen3.5/3.6 (GatedDeltaNet), LFM2.5, and Granite 4 (Mamba2) **fail at load with
> `Expected 2 states, got 4`**."*
>
> ✅ **Corroborated by Apple's own source** — `CoreAISequentialEngine`'s init asserts
> `stateNames.count == 2` (§3.2), and `CoreAIPipelinedEngine` has the equivalent guard. The
> two-state assumption is real and is in the shipped code; the fork's claim is a fair description of
> it.

This is a *Swift engine* limitation, not a conversion limitation. Note the asymmetry:

- **Apple's Python side supports these architectures.** `_EXTERNALIZE_SPECS` in `export/macos.py`
  includes `GatedDeltaUpdate → gated_delta_update`, and `primitives/macos/__init__.py` exports
  `SSMState` with `update_states(layer_idx, new_state)`.
- **Apple's Swift side rejects the resulting bundle**, because both engines validate exactly two
  states.

So you can convert one. You cannot load one with the stock `CoreAILM`.

### 13.2 The community patch, and its status

> **Community fork** — commit `9e5b605` in `john-rocky/coreai-models`, +609/−32 across 4 files, the
> bulk in `CoreAIPipelinedEngine.swift`. The guard becomes:
>
> ```swift
> guard descriptor.stateNames.count >= 2 else {
>     throw InferenceRuntimeError.invalidOutputType(
>         "Expected at least 2 states (KV cache), got \(descriptor.stateNames.count): \(descriptor.stateNames)")
> }
> guard descriptor.stateNames.count - 2 <= Self.maxExtraStates else { … }
> ```
>
> with a load-bearing constraint on the extras:
>
> ```swift
> guard !desc.shape.contains(where: { $0 < 0 }) else {
>     throw InferenceRuntimeError.invalidOutputType(
>         "Extra state '\(name)' has dynamic dims \(desc.shape) — only the first two "
>             + "states (KV cache) may be dynamic in the pipelined engine")
> }
> ```
>
> Each extra state gets one owned, zero-filled `.storageModeShared` Metal buffer, allocated at load,
> persisting across steps and re-zeroed on `reset()`. Binding is a hand-unrolled `switch
> extraStates.count` at both encode sites (0/1/2 extras, no loop) to keep the hot path
> allocation-free.

> 🔴 **GAP — upstream status is unverified as of 2026-07-27.** We do not know whether Apple has
> accepted, rejected or is considering multi-state support in `apple/coreai-models`. What we *do*
> know: **the repo does not accept code contributions** — `README.md:129-135`: *"We are not accepting
> code contributions at this time … If you open a pull request, it will be closed."* Issues are open
> (bug report / model request / workflow feedback templates). **Resolving this needs a check of
> `apple/coreai-models` issues and releases at the time you read this.**
>
> **Safe default meanwhile:** if you need a hybrid/SSM model on-device today, either (a) ship the
> patched engine in your own app — the LLM runtime is app-compiled Swift, not OS code, so this is
> legitimate (see §14.4) — or (b) **choose a pure-attention model**, which costs you nothing on the
> supported path and buys you §13.3.

### 13.3 They forfeit prefix caching — permanently, and for a good reason

Even with the patch, hybrids lose the largest multi-turn optimisation available on this stack. This
is the more important half of the story, because it is *architectural* rather than a bug.

The optimisation first. Trimming a KV cache is **a single integer assignment**:

> **Community fork** — commit `0fdf710`, 3 files, **+69/−0**. The insight, credited to a comment in
> Apple's own `reset()`: *"the KV pair needs no clearing — attention only reads positions below the
> new offset."* So a partial trim is just `processedTokenCount = length`; positions ≥ length are
> overwritten before any causal read can reach them.
>
> ```swift
> public func trimKVCache(to length: Int) async -> Int {
>     drain()
>     guard length >= 0 else { return -1 }
>     let retained = min(length, processedTokenCount)
>     processedTokenCount = retained
>     return retained
> }
> ```
>
> Contract details that matter: it returns the **actual retained prefix length**, *"which may be less
> than requested because the last generated token's KV can lag one step behind — **the caller must
> prefill from the returned offset, not from `length`**"*; and a **negative return means the engine
> cannot safely rewind**, in which case you `reset()` and re-feed everything.

What it buys, **community-measured** (qwen3-0.6b, sequential engine, on a Mac; *exact Mac model and
macOS build not stated in the source*):

| Turn | Prompt tokens | Reused | TTFT ON | TTFT OFF | Speedup |
|---|---|---|---|---|---|
| 2 | 357 | 336 | **0.126 s** | 1.915 s | **15.2×** |
| 2 | 4103 | **4075 (99.3 %)** | **0.230 s** | 23.282 s | **101×** |

with byte-identical greedy output ON vs OFF. The scaling shape is the headline: **re-prefill cost
grows with context while reuse cost stays roughly flat.**

And now the wall:

> **Community fork**, `CoreAIPipelinedEngine.swift:1401-1405`, verbatim: *"Rejected when the graph
> carries recurrent `extraStates` (GDN/SSM): those hold a running scan that can't be reconstructed at
> position `length` from the retained KV, so a partial rewind would corrupt them. Pure attention KV
> needs no clearing (causal reads never see positions ≥ `length`)."* Implementation:
> `guard extraStates.isEmpty else { return -1 }`.

The reason is not fixable by better engineering. **An attention KV cache is positionally
addressed** — row *i* is self-contained, so you can truncate at any *i*. **An SSM / GatedDeltaNet /
Mamba2 state is a running scan** — one fixed-size tensor that is a lossy fold of every token seen so
far. There is no row to drop. To get the state as of token *k* you must re-run the scan from 0.

> **Guide-worthy framing, and this guide's synthesis of the community result:** linear attention buys
> O(1) decode memory and pays for it by **forfeiting prefix caching**. On a device where *multi-turn
> TTFT* is the metric a user actually feels, that trade can invert the usual "SSMs are better
> on-device" story. Community-derived from one implementation; not an Apple claim.

### 13.4 The related multi-turn bug worth knowing about regardless

While you are in this area: there is a second community-reported engine defect that only appears on
turn ≥ 2, and it compounds with prefix caching because prefix reuse is only correct if the KV ends at
a **known token boundary**.

> **Community fork** — commit `627fec7`. Symptom: a consumer that `break`s the returned token stream
> at EOS — *"every executor"* — leaves the pipelined engine generating to `maxTokens` **in the
> background**. Those post-EOS tokens are **consumed into the KV cache**, so the next turn's
> `reset()`/`drain()` blocks on the leftover generation. Two consequences: a multi-turn latency tax,
> and on a slow model a risk of tripping `drain()`'s `fatalError`.
>
> **Community-measured**, through Apple's own `CoreAILanguageModel` adapter (qwen3.5-0.8B, two-turn
> chat): second-turn latency **2.74 s → 0.40 s**, same output. *Hardware/OS not stated.*
>
> ✅ **Partly corroborated by Apple's source**: `drain()` on both the sequential and pipelined engines
> busy-waits with 1 ms sleeps and **`fatalError`s after 5000 attempts** — *"Sequential engine drain()
> timeout — generation Task stuck?"* So the failure mode the fork describes has a real crash at the
> end of it.
>
> ⚠️ Note also that `apple/coreai-models` HEAD contains commit `04a3fd6` *"Stop pipelined generation
> when consumer drops the stream (#113)"*, which appears to address the same class of problem
> upstream. **The fork is a snapshot of an older upstream**, so treat "upstream has this bug" as a
> claim about a specific past commit, not about current `main`.

---

## 14. Performance context, attributed

Everything in this section except where marked is **community-measured by a single author** on his
own hardware, on **iOS 27 / macOS 27 betas**, and will move. It is included because it is the only
public dataset of its kind and because it changes real decisions. It is not Apple data.

### 14.1 The protocol, so the numbers mean something

> **Community-stated protocol** — `coreai-vs-mlx-speed.md:4-7`: *"All LLM rows are **same M4 Max,
> same protocol** as `mlx-lm benchmark` (Apple's `llm-benchmark` is explicitly modeled on it):
> **512 prompt / 1024 generation / 5 trials, release build**. MLX side = **`mlx-lm 0.31.3`,
> `mlx-community` 4-bit**."*
>
> The asymmetry the author himself calls out: **Core AI ships int8/int4-per-block-32 and MLX ships
> 4-bit affine group-64** — *"this is not an iso-precision comparison, it is a ship-config
> comparison."*

And a caveat that applies to every tok/s number you will ever read:

> **Community-measured**, `apple-models-bench.md:51-54`: the same artifact measures **115 tok/s at
> 512p/1024g and ~184 tok/s at 128p/128g**. *"Protocols matter."* A **1.6× swing from protocol
> alone.** A headline tok/s without a stated protocol is not a measurement.

### 14.2 Core AI vs MLX, dense and MoE

**Community-measured**, M4 Max 128 GB, macOS 27 beta, 512p/1024g/5 trials, release build:

| Model | Class | Core AI decode (prefill) | MLX 0.31.3 decode (prefill) | Verdict |
|---|---|---|---|---|
| qwen3-0.6b | dense | **484** (9396) | 432 (9366) | **CA +12 %** |
| qwen3-4b | dense | 145.4 (**1635**) | 145.8 (1495) | tie |
| qwen3-8b | dense | **94.1** (912) | 90.0 (825) | **CA +5 %** |
| gemma3-4b-it | dense | **141.5** (1669) | 136.3 (1631) | **CA +4 %** |
| gemma3-12b-it | dense | 55.0 (**578**) | 55.1 (528) | tie |
| mistral-7b-v0.3 | dense | **101.7** (976) | 97.5 (918) | **CA +4 %** |
| gpt-oss-20b | **MoE** | 78.1 (1252) | **100.2** (1528) | **MLX +28 %** |

> **Community-measured** — `apple-models-bench.md` and `coreai-vs-mlx-speed.md`. Memory caveat from
> the same source: *"gpt-oss memory: MLX Metal peak 14.6 GB vs Core AI 33.9 GB RSS — **not directly
> comparable**; RSS includes the mmap'd 13 GB weight file."*

The one-line reading, in the author's words: *"**The difference is operator/architecture coverage on
the engine — NOT the core engine.** On standard dense transformers Core AI's pipelined engine ties or
beats MLX. Core AI only loses where the model uses an op-class the stock engine lowers *naively*."*
For MoE that op class is `GatherMM`, which *"gathers then runs a DENSE matmul — it does **NOT** read
only the routed experts, so MoE decode is over-read-bound, not active-param-bound."*

Two decision rules that follow, both community-derived:

- **Dense** → expect tie-or-win vs MLX for free on the pipelined engine. The smaller the model, the
  bigger Core AI's win (dispatch-bound regime); the bigger the model, the more MLX's 4-bit erases it.
- **MoE** → budget a custom Metal gather kernel up front, or ship at ~0.5–0.78× MLX. With the kernel
  you reach **parity, not a win** — *"MLX's sparse dispatch is already good."* (Part 11 covers custom
  kernels; `TorchMetalKernel` is GPU-only by construction, since the ANE runs only fixed hardware
  ops.)

There is also a **historical correction** worth carrying, because the folklore it corrects is still
in circulation:

> **Community-measured** — `coreai-vs-mlx-speed.md:47-50`: *"The historical 'MLX is ~2× faster,
> structural' verdict was measured on a **hand-rolled per-token `fn.run()` loop** (~11 % of BW peak,
> ~1000 Metal dispatches/token). That was the **loop's** ceiling, not Core AI's. Apple's
> `coreai-pipelined` engine runs the same weights **~3.5× faster (58.5 → 204 tok/s)** with zero
> custom kernels."*

**If you drive `InferenceFunction` yourself in a per-token loop, you are measuring your loop.** Use
`CoreAILM`'s engines.

### 14.3 ⚠️ `COREAI_CHUNK_THRESHOLD` is a memory dial, and Apple's hint is backwards on a big Mac

`llm-runner --help` carries the hint *"use 128 for MoE"* (✅ verified in
`LLMRunnerMain.swift`, the hidden `--chunk-size` flag, which sets `COREAI_CHUNK_THRESHOLD`; default
1024). On a 128 GB Mac the opposite is true.

**Community-measured**, gpt-oss-20b, M4 Max 128 GB / macOS 27 beta, 4096-token prefill, 3 trials:

| `COREAI_CHUNK_THRESHOLD` | Prefill tok/s | Peak dirty footprint |
|---|---|---|
| **128** (the MoE hint) | 766 | **1.7 GB** |
| **1024** (default) | 1237 | *(not measured)* |
| **8192** (no chunking) | **1439** | **18.0 GB** |

> **Community-measured** — `apple-models-bench.md:124-141`, with the repro command:
> `COREAI_CHUNK_THRESHOLD=8192 swift run -c release llm-benchmark --model exports/gpt_oss_20b_dynamic -p 4096 -g 128 -n 3`.
> *"Unchunked MoE prefill allocates huge expert activations (~18 GB dirty for 4096 tokens on top of
> the mmap'd weights). On a 16–32 GB Mac that would swap or jetsam — chunk 128 caps it at 1.7 GB for
> a **1.9× prefill cost**. On a big-RAM Mac, RAISE the threshold: **+16 % prefill over the default
> for free**. **Decode is unaffected** (~76–78 tok/s everywhere)."*

**So the hint is not wrong; it is under-specified.** `COREAI_CHUNK_THRESHOLD` trades prefill
throughput against peak memory, and MoE models sit at the extreme end of that trade because expert
activations are enormous. On a memory-constrained device 128 is right. On a 128 GB Mac it costs you
half your prefill.

Apple's own reasoning about *why* chunking exists is in the runtime doc comment, and it makes the
memory story concrete:

> ✅ **VERIFIED** — `InferenceEngine.swift`, `InferenceConfiguration` doc comment. Defaults
> `prefillChunkSize = 512`, `chunkThreshold = 1024`. Logits buffer = batch × seqLen × vocabSize ×
> `sizeof(Float16)`. With Qwen3 (vocab 151,936): **a 32K prompt without chunking is
> 1 × 32,768 × 151,936 × 2 = 9.6 GB**; a 512-token chunk is **155 MB — a 98 % reduction**.
>
> Implementation: `ModelConfig.chunkThreshold` reads env `COREAI_CHUNK_THRESHOLD` when > 0, else
> 1024; `prefillChunkSize` is `min(512, chunkThreshold)`. Strategy selection:
> `.chunked(chunkSize:)` when `newTokenCount > config.chunkThreshold`, else `.wholeBatch`.

⚠️ There is a second hidden knob, `--bucket-size` → `COREAI_QUERY_BUCKET_SIZE` (0 disables, default
64). **We could not find anything in `apple/coreai-models` that reads it** — it is presumably
consumed by the closed `CoreAI.framework` or an unread engine path.

> 🔴 **GAP — `COREAI_QUERY_BUCKET_SIZE`'s runtime effect is unknown.** It is set by a hidden CLI flag
> and never read in the open source. **Resolving this needs Apple documentation or a controlled A/B
> on a shipping build.** Meanwhile: **leave it at the default (64)** and do not put it in a shipping
> configuration.

### 14.4 The honest counterweights

Three findings that complicate the marketing story, all community-audited, all worth knowing before
you commit an architecture:

**(1) The LLM runtime is *your app's* code, not the OS's.**

> **Community audit** — `coreai-vs-mlx-speed.md` §5.1: *"Only the **graph compiler + executor**
> (`CoreAI.framework`) is OS-resident. The LLM runtime — `EngineFactory`, the `coreai-pipelined`
> engine, `LanguageBundle`, on-GPU sampling, KV growth — is Swift code from `coreai-models` that
> **you compile into the app** (proof: we patch it — you can't patch an OS framework)."*
>
> ✅ **Structurally verified** — `apple/coreai-models` is a SwiftPM package you add to your target.
> That is not in dispute; the *framing* ("Core AI is OS-resident, nothing to bundle") is what the
> audit complicates.

Consequences the same audit names: beta seed-to-seed ABI churn can break TestFlight launches
(*"`FoundationModels` must be weak-linked"*), and *"the ~O(p²) prefill scratch lives in the closed
compiler and cannot be fixed app-side."* The upside is the one §13.2 depends on: **you can patch the
engine**, because it is your code.

**(2) The `.aimodel` is a build artifact, not a pure function of the recipe.**

> **Community-measured** — `apple-models-bench.md:196-200`, on the same iPhone 17 Pro: *"the same
> `coreai.llm.export qwen3-0.6b` produced a **2.2× faster artifact on macOS 26 than on the 27 beta**
> (native quantized-Linear lowering vs explicit dequant ops; same code, same wheels)."* Measured:
> the macOS-26 artifact does **115.1 / 90.4** tok/s (run 1 / run 2) versus the macOS-27β artifact's
> **57.2 / 52.5**, with prefill 5807 vs 1519 and footprint 0.22 GB vs 0.47 GB.
>
> **Version-stamp and keep your artifacts.** This is a beta-toolchain regression with an identified
> mechanism, community-measured, on a moving target. It may well be gone by the time you read this —
> but the *lesson* (recipe ≠ artifact) is permanent, and it is why §9.6's "gate, don't hash" advice
> matters.

**(3) Cold specialization is Core AI's own cost.**

> **Community-measured** — same audit: *"Cold GPU specialization is Core AI's own cost (**0.8B ≈
> 4.8 s, 2.3 GB ≈ 29 s on iPhone**); AOT / `AIModelCache` gives *control over* that first-run cost;
> MLX's runtime kernel JIT is light enough that it never had the problem. Deterministic first-launch
> is a genuine product knob, but don't sell it as an advantage over MLX."*

### 14.5 What Core AI genuinely keeps

The same audit's "what each side keeps" list is the fairest summary available, and it is worth
reproducing because it is written by someone who ships on both:

**Core AI**: **ANE access** — the one structural fact MLX cannot reach — with throughput parity and,
in one matched-bytes measurement, **~+8.5 % energy vs MLX-GPU** plus **GPU exclusivity** (UI and
rendering don't contend); AOT first-launch control; the official zero-code Foundation Models adapter;
a closed compiler that improves with OS updates (double-edged).

**MLX**: a fully open stack (every layer fixable); **no conversion step**, so new-architecture
turnaround is days; mature 4-bit affine quantization; **free logits** (hence easier structured
generation and sampler experiments); no O(p²) prefill-scratch wall.

The matched-bytes iPhone measurement behind the energy claim:

> **Community-measured** — iPhone 17 Pro, DeepSeek-R1-1.5B, matched 4-bit bytes (ANE 0.97 / GPU 0.95
> / MLX 0.95 GB), cold short-chat, median of 3:
>
> | Path | Decode tok/s | Tokens per 1 % battery |
> |---|---:|---:|
> | Core AI **ANE** | **83.3** | **6144** |
> | MLX (GPU, mlx-swift) | 73.0 | 5662 |
> | Core AI **GPU** | 75.9 | 4506 |
>
> The author's own interpretation: *"The ANE-vs-GPU delta **sign-flips across sibling models** →
> **throughput parity**, not an ANE speed win. And the ANE *energy* edge over MLX-GPU is only ~+8.5 %
> … the robust ANE win is **GPU exclusivity**."* Source cited to a report not present in the repo we
> read — **UNVERIFIED at source**; treat as indicative, not as a benchmark you can re-run.

⚠️ **And one correction the same author published about his own earlier claim**, which is worth
repeating because the wrong version circulates: **MLX *does* run on iPhone** (GPU, via `mlx-swift`).
Only the ANE is closed to MLX. Also: *"Foundation Models integration is **NOT** an exclusive: the
`LanguageModel` protocol is public and MLX plugs in via `MLXLanguageModel`."*

---

## 15. The alternative bridge: `mlx2coreai`

There is a second route to the same bundle shape that never touches PyTorch: capture an **MLX**
model's graph and emit Core AI MLIR directly.

> ⚠️ **Community project, not Apple.** `lucasnewman/mlx2coreai`, MIT licensed, *"Copyright (c) 2026
> Lucas Newman"*, version **0.1.1**, 11 commits (all June 2026), HEAD `059c9f3`. Read from a local
> clone. It vendors one Apple file — `_composite_declaration.py`, BSD-3, `Copyright 2026 Apple Inc.`
> — copied out of Apple's Core AI Python tooling.

### 15.1 What it does

```
MLX callable / nn.Module
    → mx.export_function(callback, fn, **inputs)     # MLX's export callback tracer
    → list[dict] events → a small SSA graph IR
    → normalize / shape-infer / check op support
    → CoreAILowerer → coreai.GraphOp inside an AIProgram
    → program.optimize() → save_asset()
    → <name>.aimodel/{main.mlirb, main.hash, metadata.json}
       (+ for the stateful path: bundle/{metadata.json, tokenizer/, <name>.aimodel})
```

> ✅ **VERIFIED (from the repo)** — module map: `from_mlx.py` (1303 lines, capture),
> `passes.py` (1032, normalization + shape inference), `lower_to_coreai.py` (2072, the MLIR emitter),
> `_convert_mlx_lm_stateful.py` (881, the LLM path), `runtime.py` (556), `cli.py` (208).

### 15.2 The command that matters

```bash
mlx2coreai convert-mlx-lm-stateful mlx-community/Qwen3-0.6B-bf16 \
  --output qwen \
  --max-context-length 256
```

Its full flag list:

| Flag | Type | Default |
|---|---|---|
| `--output` | Path | **required**. *"A `.aimodel` suffix is treated as the nested asset name."* |
| `--max-context-length` | int | 256 |
| `--revision` | str | None |
| `--input-name` | str | `input_ids` |
| `--position-ids-name` | str | `position_ids` |
| `--key-cache-name` | str | `keyCache` |
| `--value-cache-name` | str | `valueCache` |
| `--compute-precision` | `auto\|fp32\|fp16\|bf16` | `auto` |
| `--cache-dtype` | `fp32\|fp16\|bf16` | follows compute precision |
| `--entrypoint` | str | `main` |
| `--dynamic-sequence` / `--no-…` | flag | **True** |
| `--dynamic-state` / `--no-…` | flag | **True** |
| `--cast-bf16-logits-to-fp16` / `--no-…` | flag | **True** |
| `--externalize-weights` / `--no-…` | flag | True |
| `--external-weight-threshold` | int | 10 (**elements**, not bytes; −1 = never) |
| `--no-optimize` | flag | off |

> ✅ **VERIFIED** — `mlx2coreai/cli.py` and `_convert_mlx_lm_stateful.py:814-842`. Note the
> standalone console script `mlx2coreai-convert-mlx-lm-stateful` omits `--batch-size`; the Python
> function accepts `batch_size` but raises for anything but 1.

### 15.3 It reproduces Apple's contract deliberately

This is the interesting part. The docstring says so:

> ✅ **VERIFIED** — `_convert_mlx_lm_stateful.py:151-157`: *"Convert an mlx-lm model into one
> stateful CoreAI asset. The generated `.aimodel` follows the **macOS LLM contract used by
> `coreai-models`**: a single dynamic `main` entrypoint with `input_ids`, `position_ids`, and two
> mutable KV-cache state tensors named **`keyCache`** and **`valueCache`** by default."*

And the constants match Apple's exactly:

| | `mlx2coreai` | `apple/coreai-models` |
|---|---|---|
| Trace query length | `TRACE_QUERY_LENGTH = 16` | `QUANT_TRACE_QUERY_LEN = 16` |
| Trace position offset | `TRACE_POSITION_OFFSET = 8` | `QUANT_TRACE_OFFSET = 8` |
| State names | `keyCache` / `valueCache` | `KEY_CACHE_NAME` / `VALUE_CACHE_NAME` |
| Cache shape | `(n_layers, batch, n_kv_heads, max_ctx, head_dim)` | identical |
| Dynamic cache axis | **3** | `KVCache.seq_len_dim() == 3` |

> ✅ **VERIFIED** — both sides read from source. This is not a coincidence; the bridge is
> deliberately reproducing Apple's LLM export recipe from the MLX side.

The output bundle is likewise the same shape:

```
qwen/
├── metadata.json          # metadata_version "0.2", kind "llm", assets.main, language{...}
├── tokenizer/             # HF tokenizer files
└── qwen.aimodel/
    ├── main.mlirb
    ├── main.hash
    └── metadata.json
```

> ✅ **VERIFIED** — `_write_coreai_models_bundle` emits a `metadata.json` identical in shape to
> Apple's `bundle.py`, differing only in `"source": {"model_definition": "mlx", …}` (Apple writes
> `"torch"`), a `compression` of `None`, and `max_context_length` taken from the CLI rather than from
> `hf_config.max_position_embeddings`. The repo's own test
> `test_convert_mlx_lm_stateful_live_mlx_smoke_saves_unified_asset` asserts every field.

**So a `mlx2coreai` bundle loads with `CoreAILanguageModel(resourcesAt:)` unchanged.** That is the
point of the project.

### 15.4 The KV-cache trick, and the `position_ids` contract it implies

The bridge cannot use Apple's PyTorch `KVCache`, so it substitutes a duck-typed replacement for
mlx-lm's cache that records slice-updates into one stacked tensor where MLX's tracer can see them:

```python
class _ExportableLayeredKVCache:
    def update_and_fetch(self, keys, values):
        import mlx.core as mx
        offset = mx.reshape(self.offset, (1,))
        layer  = mx.array([self.layer_idx], dtype=mx.int32)
        start  = mx.concatenate([layer, mx.array([0, 0], dtype=mx.int32),
                                 offset, mx.array([0], dtype=mx.int32)])
        self.state.keys   = mx.slice_update(self.state.keys,
                                            mx.expand_dims(keys, 0),   start, [0,1,2,3,4])
        self.state.values = mx.slice_update(self.state.values,
                                            mx.expand_dims(values, 0), start, [0,1,2,3,4])
        self.keys   = self.state.keys[self.layer_idx]
        self.values = self.state.values[self.layer_idx]
        return self.keys, self.values
```

> ✅ **VERIFIED** — `_convert_mlx_lm_stateful.py:67-128`. `mx.slice_update(dst, src, start, axes)`
> becomes a `DynamicSliceUpdate` primitive → `dynamic_slice_update` IR op → `coreai.slice_update`.

And the write offset is derived from `position_ids` **inside the traced function**:

```python
def _offset_from_position_ids(input_ids, position_ids):
    query_indices = mx.arange(input_ids.shape[1], dtype=mx.int32)
    query_len     = mx.max(query_indices) + mx.array(1, dtype=mx.int32)
    last_position = mx.max(position_ids)
    return last_position - query_len + mx.array(1, dtype=mx.int32)
```

⚠️ **That is why `position_ids` must be the *full* position vector `[0 … total-1]`, not just the new
positions.** Feed a single position and the offset computes to something wrong, the cache writes to
the wrong row, and you get plausible-looking garbage. Note this is **exactly the same contract** the
community gate documentation reports for Apple's own bundles (§6.7) — it is a property of the
recipe, not of this bridge.

> ✅ **VERIFIED** — `_convert_mlx_lm_stateful.py:558-564`, and the repo's own benchmark backends
> both feed `arange(total_positions)`.

Also note: `make_mask` raises `NotImplementedError("stateful KV-cache export does not support
sliding-window masks yet.")` — so sliding-window-attention models are out on this path.

### 15.5 Where it is rough

| Issue | Detail |
|---|---|
| **Wheel pin** | `coreai-core==1.0.0b1` — **b1, not b2**. `apple/coreai-models` pins **b2**, and the community reports b1-era assets being rejected by the Xcode 27 beta 3+ SDK loader. |
| **`min_runtime_target`** | `"macOS27"` by default and **recorded into metadata only** — *nothing validates it*. |
| **`external_weight_threshold`** | counts **elements**, not bytes. A default of 10 externalizes almost everything. |
| **Output matching** | `compare_coreai_outputs(..., match_by_order=True)` compares **positionally**, so a runtime output named `out_0` will be compared against a captured output named `attn`. Fine for a smoke test, dangerous as a gate. |
| **Swift runner** | The repo ships one because *"python bindings are incomplete as of now"* (commit `059c9f3`), and its benchmark hard-codes `logits.view(as: Float16.self)` — so `--no-cast-bf16-logits-to-fp16` breaks it. |
| **Model mutation** | `_apply_model_compute_precision` calls `model.set_dtype(...)`, which **mutates the loaded model in place**. |

> ✅ **VERIFIED** — all rows from the repo's own source and `pyproject.toml`. The b1-vs-b2 rejection
> claim is **community**: `CONTRIBUTING.md:24-28` in `coreai-model-zoo` states *"Export with
> **coreai-core ≥ 1.0.0b2**. Bundles exported with earlier wheels are rejected by the **Xcode 27 beta
> 3+ SDK loader** (`Failed to convert to versioned IR` — tracked as **FB23666783**)."*

> 🔴 **GAP — whether a `coreai-core` 1.0.0b1 asset loads on a 27.0 GM is unverified.** The community
> report is specific and cites a Feedback number, but it is about a *beta* SDK. **Resolving this
> needs a test on shipping 27.0.** Meanwhile the safe default: **install `coreai-core==1.0.0b2` (or
> later) into the `mlx2coreai` environment yourself**, overriding its pin, and verify the produced
> asset's `producer` field says `coreai-core 1.0.0b2` (§9.5) before you ship it.

### 15.6 When to reach for it

Use `mlx2coreai` when your model already exists as an mlx-lm checkpoint and re-authoring it in
PyTorch would be the expensive part — MLX's own conversion turnaround for new architectures is days,
and this lets that work carry over. Do **not** use it when you need the iOS/ANE path: it targets the
macOS dynamic contract only, and nothing in it produces the four-entrypoint chunked-static shape.

**Part 14 (Bridges between stacks)** treats this project, the reverse direction, and the
`ChatCompletionsLanguageModel` route in full. This section covers only what an LLM export needs.

---

## 16. Failure catalogue

Sorted by how hard they are to notice, worst first. Every row links back to the section that
explains it.

### 16.1 Silent — no error, wrong output

| Symptom | Cause | Fix | § |
|---|---|---|---|
| Generation is locally fluent, globally incoherent, drifts after ~10 tokens | **`remove_functionalization(ep)` omitted** — KV writes silently dropped | Call it after `run_decompositions` | §8.4 |
| Bundle is bigger than the config predicts; PSNR suspiciously good | Per-block / per-grouped-channel compression **silently skipped** non-divisible layers | `check_divisibility()`; compute achieved bit-width from the artifact | §7.5 |
| Model quality collapses vs. the HF reference, tokenizer looks fine | `chat_template.jinja` missing → runner **silently falls back to raw completion** | Verify `tokenizer/` contents; check the source repo at gate time | §6.8 |
| Correct-looking model produces garbage from a persistent runner | The `AIModel` was garbage-collected; only `load_function` was retained | Hold the model reference | §6.4 |
| Non-contiguous PyTorch tensor produces plausible garbage through the sample wrapper | Python bridge reads raw backing memory as contiguous | `.contiguous()` at that bridge; preserve explicit strides in Swift `NDArray`[^stride-scope] | §5.7 |
| "ANE model" is slower than expected, ANE utilisation ~0 | `nn.functional.silu` lowered to `cast/swish/cast` — 3 ops the ANE can't run | `gate_pre * torch.sigmoid(gate_pre)` | §5.6 |
| Exports behave like an old wheel on your machine only | `coreai_torch.egg-info` in cwd shadows the installed version via `sys.path[0]` | Never run python with the clone as cwd; assert the `producer` field | §9.5 |
| Key/value cache swapped; output is fluent nonsense | `state_names` ordering — the converter *"cannot detect silent reordering"* | Always pass explicit names; gate token-exactness | §8.5 |
| `kvCacheStrategy: .chunked` behaves like `.fixedSize` | Case accepted, **falls back to `StaticKVCache`** | Use `.growing` or `.auto` | §11.3 |
| PSNR ≥ 40 dB but the model says something different | PSNR averages over 150k logits; the argmax moved | Add a token-exactness gate | §6.3 |
| "Quantized" diffusion component ships full precision | `apply_mlir_quantization` failure **swallowed with a warning** | Check the artifact size | §7.5 |

### 16.2 Loud but misleading

| Message | Real cause | § |
|---|---|---|
| `unsupported metadata_version '0.1' (known: 0.2)` | You pointed at a `.aimodel`/`.aimodelc`, not the bundle directory — or a genuinely old bundle | §1.2 |
| `BundleError.missingAsset` | You AOT-compiled and didn't update `metadata.json` `assets.main` | §10.6 |
| `NSPOSIXErrorDomain Code=2` at engine load on iOS | Uncompiled `.aimodel` (or macOS-tagged IR) on a device | §10.6 |
| `invalidCompiledModel` | Wrong `--architecture` — compile exits 0 for any arch | §10.3 |
| `error: Failed to convert to versioned IR` | Asset produced by `coreai-torch` 0.4.0 | §9.5 |
| `Shape at dimension 1 of 256 is not a valid substitution for source shape 1` | Default warmup prefills 256 into a static `S=1` graph | §6.7 |
| `Strategy 'growing' requires dynamic KV cache support … Re-export with --dynamic-sized-kvcache-gpu` | That flag **does not exist** in the shipped exporters; you have a fixed-seq-dim model | §11.3 |
| `"CoreAI pipelined engine does not support logits"` | Guided generation / `forcedContinuation` on the GPU path | §11.4 |
| `Expected 2 states, got 4` | Hybrid / SSM bundle on the stock engine | §13.1 |
| `EXC_BAD_ACCESS` in `MPSGraphAICodeCompilerDelegate`, no error string | `expectFrequentReshapes = true` on a fixed-shape graph | §10.5 |
| `LLVM ERROR: No space left on device` | On-device specialization of a large graph exhausted scratch | §10.4 |
| `signal 9` during a long cold compile | Jetsam — the model is above the device ceiling | §10.4 |
| `fatalError: Sequential engine drain() timeout` | 5 s of busy-wait; often a stream the consumer dropped | §13.4 |

### 16.3 Environment and process

| Symptom | Cause | § |
|---|---|---|
| Export ENOSPCs mid-run | HF repo ships duplicate weights (Mistral: 27 GB not 15) + serialization scratch | §4.1 |
| Download stalls near 99 %, or a "complete" file is sparse | Xet transfer pathologies; mixing Xet and non-Xet attempts | §4.3 |
| `optimize()` runs for 90 minutes | Large attention graph | §9.2 |
| `save_asset` fails | It will not overwrite; `rmtree` first | §9.3 |
| Same recipe, different performance | The artifact is a build artifact, not a function of the recipe | §14.4 |
| Two identical exports don't hash-match | **Conversion is not byte-deterministic** | §9.6 |
| CI can't tell if an export regressed | Use a gate script, not a checksum | §9.6 |
| iOS export of a big model OOMs the *host* | iOS path uses the full-RAM loader, not the streaming one | §4.4 |
| Whole Mac needs a reboot | An iOS-compiled bundle was executed on the Mac | §10.7 |

---

## 17. Quick reference

### 17.1 The commands

```bash
# discover
uv run coreai.model.registry --list-models
uv run coreai.model.registry --model-info qwen3-0.6b --platform iOS --as-export-args

# export (macOS / GPU / dynamic)
uv run coreai.llm.export Qwen/Qwen3-0.6B

# export (iOS / ANE / chunked-static)
uv run coreai.llm.export Qwen/Qwen3-0.6B --platform iOS

# AOT compile for a device
xcrun coreai-build compile exports/<name>/<name>.aimodel \
    --output out/ --platform iOS --architecture h18p \
    --preferred-compute gpu --min-deployment-version 27.0
# then edit exports/<name>/metadata.json → assets.main = "<name>.h18p.aimodelc"

# run / measure
swift run -c release llm-runner    --model exports/<name> --prompt "Hello"
swift run -c release llm-benchmark --model exports/<name> -p 512 -g 1024 -n 5
```

### 17.2 The two graph contracts

```
macOS / GPU / dynamic                     iOS / ANE / chunked-static
────────────────────────                  ─────────────────────────────
function:  main                           functions: load_embeddings
inputs:    input_ids   (int32)                       gather_embeddings_<q>
           position_ids(int32)                       prompt_opt_<ctx>_<q>
states:    keyCache                                  extend_<ctx>_<q>
           valueCache                     inputs:    transformer_input
outputs:   logits      (float16)                     position_ids (uint16)
                                                     in_step      (int32)
cache:  [L, B, H_kv, max_S, D]                       causal_mask  (fp16)
        seq dim 3, dynamic                           embedding_table
                                          states:    key_cache / value_cache
engine: coreai-pipelined (default)        outputs:   new_k_cache / new_v_cache
        coreai-sequential (logits)                   out_logits
                                          cache:  [L, B, H_kv*D, 1, max_S], seq dim 4
                                          engine: static-shape
```

### 17.3 The gate bars

| Check | Apple bar | Community bar |
|---|---|---|
| float32 end-to-end | PSNR > 70 dB (investigate < 60) | — |
| re-authored vs source | PSNR > 70 dB | cos ≥ 0.999 |
| ANE layout vs GPU layout | PSNR > 70 dB | — |
| fp16 on device | PSNR > 50 dB (investigate < 40) | — |
| compiled vs torch | PSNR ≥ 40 dB | per-token cos ≥ 0.999 **and** greedy token-exact |
| after 4-bit palettization | PSNR ≥ 35 dB (~40 typical) | read the generations |

### 17.4 Compression at a glance

| | macOS | iOS |
|---|---|---|
| Family | linear quantization | k-means palettization |
| Default | int4, `symmetric_with_clipping`, per-block 32, axis 1 | 4-bit, per-grouped-channel, axis 0, group 32 |
| Alternatives | `none` | `none`, group 8 |
| Excluded | SDPA, RoPE, RMSNorm, RMSNormPlusOne | `nn.Embedding`, `LoadEmbeddings` (→ int8 per-tensor) |
| MoE override | `SwitchLinear`, block `[1,1,1,32]` | n/a |
| Sizing rules | 8-bit ≈ 2×, 4-bit ≈ 4×, 2-bit ≈ 8× (Apple, palettization) | same table |
| Community floor | int8 everywhere; selective int4 on FFN + lm_head only | same |

### 17.5 Things that do not exist

Stated explicitly because all of them are in circulation:

- **`.coreaimodel`** and **`.aiasset`** — invented extensions. The real ones are `.aimodel` and
  `.aimodelc`.
- **A `coreai-torch convert` CLI** — there is no such command. Conversion is a Python API
  (`TorchConverter`); the only CLI in the toolchain is `xcrun coreai-build`.
- **"iOS 20" / "macOS 17"** — the platforms are **iOS 27 / macOS 27**.
- **An on-device LoRA / fine-tuning API** — none shipped. QAT exists in `coreai-opt`, on your Mac,
  before export.
- **`--dynamic-sized-kvcache-gpu`** — referenced in a shipped Swift error string, but **no such flag
  exists** in `coreai.llm.export` (§11.3).
- **A non-LLM benchmark tool** in `apple/coreai-models` — `Tools/benchmark` builds `llm-benchmark`
  and imports `CoreAILanguageModels`.
- **A working `coreai.llm.eval`** — the console script exists and always errors (§2.6).

---

## 18. Sources and evidence ledger

### 18.1 Primary — shipping source read this session

| Source | What it grounded |
|---|---|
| `apple/coreai-models` @ `5ed9981` (2026-07-23), local clone | Everything in §§1–3, 5, 7–9, 11. `python/src/coreai_models/{model_registry,llm/export,llm/eval,export/*,models/registry,models/base,primitives/*}.py`; `swift/Sources/{CoreAIShared,CoreAILanguageModels,Tools}/**`; `Package.swift`; `pyproject.toml`; `models/*/README.md` |

> ⚠️ **Upstream drift, checked 2026-08-02 — the pin above is a snapshot, and upstream has moved
> six commits past it to `49becc6` (2026-07-31).** Every `file:line` citation in this guide remains
> correct *for `5ed9981`*, which is what the pin means. Three of the six commits land on files this
> guide reads, so re-verify before you trust a line number against a fresh clone:
>
> | Commit | Date | Touches |
> |---|---|---|
> | `86b4c04` "Remove Deprecated LLMAsset Terminology" | 07-28 | ⚠️ **Breaking path change** — VLM export now writes `<name>/`, **not `<name>.llmasset/`** (`python/src/coreai_models/vlm/export.py`, `models/README.md`, `models/vlm/README.md`). Any script that globs `*.llmasset` breaks. |
> | `367ad52` "New custom op for KV cache update" | 07-29 | `export/mlir_ops.py` (+337/−…), `primitives/_ops.py`, **`primitives/ios/cache.py`**, **`primitives/macos/cache.py`** — i.e. the exact files behind §627, §939 and §2011 here, and Part 7.3's cache-shape claims. |
> | `f3e8689` "Fix compiler warnings from macOS 27 Beta 4 SDKs" | 07-31 | Swift sources; cosmetic, but confirms upstream is tracking beta 4. |
>
> The other three (`49becc6` guided-decoding extensions, `aa3bbf6` `--clear-coreai-cache`,
> `c7421ba` flux2 quantization cast) are folded into
> [Part 7.4 §7.3.1](../../part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md#731-three-additions-at-49becc6--and-what-they-tell-you-about-where-this-is-going)
> and [Part 7.2 §7.1](../../part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md#71-how-apples-own-tools-clear-the-cache--and-the-measurement-pattern-worth-stealing).
> 🔴 **Not yet re-read: what `367ad52` changed about the KV-cache primitive.** That is the
> highest-value follow-up in this file — it may invalidate the cache-shape and `seq_len_dim()`
> claims at §627/§939.
| `apple/coreai-models/skills/**` | §3.1, §5.4–5.7, §6.3, §7.7 — `model-authoring` + `references/{neural_engine_rules,gpu_rules,common_issues}.md`, `working-with-coreai` + `references/guidance.md`, `model-compression-exploration` |
| `apple/coreai-torch` docs + module map | §6.6, §8.3, §8.5, §9.1 — `docs/api/{TorchConverter,TorchMetalKernel,debugging}.md`, `docs/getting-started/quickstart.ipynb`, `docs/coreai-core/tutorials/run-an-aimodel.ipynb`, `docs/guides/conversion-workflows.ipynb` |
| `apple/coreai-optimization` source + docs | §7 — `quantization/config/quantization_config.py`, `_presets/quantizer_config.py`, `palettization/{spec,kmeans}`, `casting/`, `docs/src/quantization/config.md` |

### 18.2 Apple, spoken

| Session | Used for | Caveat |
|---|---|---|
| WWDC26 **325** *Dive into Core AI model authoring and optimization* | §5.1 (re-authoring definition), §6.6 (debugger, sync points), §9.1 (three-function split, 76 %), §7.7 | ⚠️ Line 241's *"per-channel scales"* conflicts with the shipped recipe (§7.7). The shipped code wins. |
| WWDC26 **326** *Integrate on-device AI models in your app* | §2 (two paths), §11.1 (the FM bridge) | Verified against repo READMEs at every point |
| WWDC26 **324** *Meet Core AI* | §10.1 (specialization) | Runtime cache/specialize API is 🟡 RECONSTRUCTED from spoken narration |
| WWDC26 **330** *Optimize custom ML operations with Metal tensors* | Referenced only; Part 11 owns it | Its scale-plane material matches the OS 27 API; Part 11 distinguishes that surface from the 26.x fallback[^xcode27-scale-planes] |

### 18.3 Community — attributed, never presented as Apple

| Source | Used for | Weight |
|---|---|---|
| `john-rocky/coreai-model-zoo` (`PORTING.md`, `AGENTS.md`, `CATALOG_PLAN.md`, `CONTRIBUTING.md`, `knowledge/**`) | §4.1, §4.3, §6.1–6.9, §7.6, §9.2–9.6, §10.3–10.7, §12, §14 | Single author; self-declared uncontrolled benchmarks; **unique primary source** for most device numbers |
| `john-rocky/coreai-models` fork (4 commits) | §13 — the two-state limit, the patch, `trimKVCache` | Snapshot of an older upstream; do not read "upstream has this bug" as a claim about current `main` |
| `lucasnewman/mlx2coreai` @ `059c9f3` | §15 | MIT, 11 commits, pins `coreai-core==1.0.0b1` |

### 18.4 Declared gaps in this guide

| # | Gap | What would resolve it | Safe default meanwhile |
|---|---|---|---|
| 1 | The `.aimodel`'s **inner** `metadata.json` schema | An Apple doc page or `coreai-build inspect` output on a real asset (`inspect` confirmed to exist 2026-07-31, `--metadata`/`--json` flags) | Treat as read-only; depend only on the outer bundle metadata (§1.3) |
| 2 | Hugging Face Xet behaviour — two community reports contradict | A controlled repro against the current Hub | Let one `hf download` finish; never mix Xet and non-Xet for one file (§4.3) |
| 3 | How `hoistToArg` relates to `remove_functionalization` | `coreai-torch` `LegalizeToCoreOptions` docs/source | Use Apple's shipped `export/macos.py` path verbatim (§5.4) |
| 4 | Contents of Apple's two mixed-precision YAMLs | Reading `models/qwen3/qwen3_*_mixed_4bit_8bit.yaml` | Read them before writing your own (§7.4) |
| 5 | The `--architecture` name table (narrowed 2026-07-31: the valid-code set — 24 codes, `h11p…h18p` — is enumerated in §10.3; the code→device mapping is still unpublished) | An Apple doc mapping device identifiers to codes | Compile for every offered arch and select at runtime (§10.3) |
| 6 | Whether AOT is *strictly required* on iOS or only for large models | An Apple statement, or a controlled test with a tiny iOS asset | AOT-compile everything you ship to iOS (§10.6) |
| 7 | Upstream status of multi-state (hybrid/SSM) engine support | Check `apple/coreai-models` issues/releases when you read this | Ship the patched engine in your app, or choose a pure-attention model (§13.2) |
| 8 | What `COREAI_QUERY_BUCKET_SIZE` does | Apple docs or a controlled A/B | Leave it at the default (64) (§14.3) |
| 9 | Whether a `coreai-core` 1.0.0b1 asset loads on 27.0 GM | A test on shipping 27.0 | Install b2+ into the `mlx2coreai` env; assert the `producer` field (§15.5) |

### 18.5 Where the notes contradicted the outline, and the notes won

Recorded for the reader's benefit, because both versions circulate:

1. **The catalog size.** The brief for this guide said "22 models"; a community audit of the same
   repo says "21 export recipes". The registry is the authority — enumerate it yourself (§2.1).
2. **`coreai-build compile` flags.** Apple documents only `--platform` and `--preferred-compute`.
   The full flag list in §10.2, originally community-verified from `--help`, was confirmed
   flag-for-flag on 2026-07-31 against the shipped tool (Metal Toolchain component).
3. **`.aimodelc` is "the compiled model file".** It is a **directory** containing its own
   `metadata.json`, which is why pointing a bundle loader at it produces a misleading version error
   (§1.2).
4. **"iOS means Neural Engine."** The optional `coreai-models` runtime derives its compute-unit
   *preference* from asset **structure**, not platform; direct Core AI callers choose their own
   options (§3.5, §10.4).[^sample-routing-policy]
5. **`COREAI_CHUNK_THRESHOLD` "use 128 for MoE".** True as a memory guard, backwards as a throughput
   guide on a large-RAM Mac (§14.3).

---

*Part 10 · Reference 03. Cross-links: Part 7 (Core AI Swift runtime · `AIModel`, states,
specialization), Part 8 (PyTorch conversion), Part 9 (compression and numerics), Part 11 (Metal and
TensorOps · custom kernels), Part 14 (bridges between stacks · `mlx2coreai`), Part 15 (shipping and
operating on device).*

[^sample-routing-policy]: The structure classifier and preferences live in the optional
    `apple/coreai-models` package’s pinned
    [`ModelStructure.swift`](https://github.com/apple/coreai-models/blob/5ed9981303b38d5a44aa6b45509bc4f6945029f5/swift/Sources/CoreAIShared/Runtime/ModelStructure.swift#L12-L218),
    whereas Core AI separately documents `.default` as selecting the compute-unit combination that
    minimizes latency: [Managing model specialization and caching](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/docs/Managing%20model%20specialization%20and%20caching.md).

[^xcode27-scale-planes]: Apple’s OS 27 references document the scale-plane descriptor and the
    tensor descriptor’s auxiliary-plane map:
    [`MTLTensorAuxiliaryPlaneDescriptor`](https://developer.apple.com/documentation/metal/mtltensorauxiliaryplanedescriptor) and
    [`MTLTensorDescriptor.auxiliaryPlanes`](https://developer.apple.com/documentation/metal/mtltensordescriptor/auxiliaryplanes).
    The authoritative [WWDC26 session 330 transcript](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/transcripts/wwdc2026-330.txt#L53-L78)
    describes E8M0 block scales, automatic dequantization, and the custom-format fallback.

[^stride-scope]: The `.contiguous()` warning is specific to the Python authoring path documented in
    the pinned `coreai-models`
    [`common_issues.md`](https://github.com/apple/coreai-models/blob/5ed9981303b38d5a44aa6b45509bc4f6945029f5/skills/skills/model-authoring/references/common_issues.md#L95-L98).
    The Core AI API itself exposes explicit strides and specialization-selected layouts:
    [Apple Developer — `NDArray`](https://developer.apple.com/documentation/coreai/ndarray).
