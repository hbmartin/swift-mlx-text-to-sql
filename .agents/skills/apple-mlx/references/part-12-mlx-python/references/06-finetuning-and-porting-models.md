# LoRA and DoRA fine-tuning, and adding a new architecture

**Part 12 · MLX in Python · Reference 06**

**Version floor.** This guide is about a Python package, not an OS framework, so the floor has two
halves. **Software:** `mlx-lm` **0.31.3** (`mlx_lm/_version.py`) against `mlx` **>= 0.31.2**
(`setup.py`, `MIN_MLX_VERSION`), with `transformers >= 5.7.0`. Every signature below was read from
a clone of `ml-explore/mlx-lm` at commit `e5baded` (2026-07-26) and `ml-explore/mlx` at
`MLX_VERSION 0.32.1`. **Hardware/OS:** MLX from PyPI needs Apple silicon, a *native* Python
>= 3.10, and **macOS >= 14.0**; memory wiring — which `mlx_lm.lora` turns on unconditionally —
needs **macOS >= 15.0**. Nothing in this guide requires macOS 27 or iOS 27, and nothing in it runs
on a phone: see §8.6. The consumer-side stories that *do* need OS 27 are
[Part 13](../../part-13-mlx-swift/README.md) (running your adapter from Swift) and
[Part 14](../../part-14-bridges-between-stacks/README.md) (converting the result to Core AI).

**A caution about freshness that applies to this whole part.** The clone is `--depth 50`, so `git
log` on most paths returns only the graft boundary; treat no date here as authoritative except the
two commit dates named above. PyPI's newest `mlx-lm` is 0.31.3 from **April 2026** while `main` has
months of merged fixes on top of it, so a reader on `pip install mlx-lm` is running older code than
this guide describes. Where that matters, the text says so.

---

## What this covers

Two jobs that look unrelated and are not. **Adapting a model you already have** (LoRA, DoRA, full
fine-tuning, fusing) and **teaching mlx-lm about a model it has never seen** (the `models/` file
convention, weight mapping, parity checking). They belong in one guide because the second one is
what you end up doing when the first one fails with `Model type <x> not supported.`

- **Why this guide exists at all now.** Foundation Models' custom LoRA adapters are **discontinued
  in OS 27** — two independent Apple-staff statements, §0. That removes the sanctioned on-device
  adaptation path for the system model and leaves MLX's LoRA/DoRA as the surviving one.
- **The data format**, all four of it, and the exact detection order that decides which one you got.
- **The complete flag surface of `mlx_lm.lora`**, including the ten flags that only exist in YAML.
- **What LoRA, DoRA and `--fine-tune-type full` actually compute**, from the module source, because
  the difference between them is three lines of arithmetic and a large difference in cost.
- **QLoRA** — training against a quantized base — and the one-line trick (`input_dims * 32 //
  bits`) that makes it work.
- **Rank, scale (mlx-lm's "alpha"), and target-module selection**, with the parameter-count
  arithmetic the test suite asserts.
- **Learning rate, warmup, schedules, and the five optimizers.**
- **Memory, at length**, because it is the binding constraint: the three levers, gradient
  checkpointing's real mechanism (and its process-wide side effect), and what OOM looks like.
- **Checkpointing, resuming, and exactly what lands in `adapters/`.**
- **Evaluating**: test perplexity, `mlx_lm.perplexity`, `mlx_lm.evaluate`, and generation A/B.
- **`mlx_lm.fuse`**, and the capability you give up by running it.
- **One complete worked run**: prepare → train → evaluate → fuse → convert → serve.
- **Porting a new architecture**: the file-naming rule, the `Model` contract, `sanitize()`, RoPE and
  norm variants, cache interaction, and how to verify parity against the reference implementation.

## What this does *not* cover

- **Learned quantization** (`mlx_lm.dwq`, `awq`, `gptq`, `dynamic_quant`). Those are quantization
  algorithms that happen to use gradients; they are covered in this part's quantization guide.
- **`mlx_lm.server`, batching, prompt caching, distributed serving.** This part's serving guide.
- **RLHF/DPO/GRPO — in `mlx_lm` itself.** mlx-lm ships
  `batch_generate(return_logprobs=..., return_token_ids=...)`
  explicitly for "reinforcement learning (e.g. RLOO, PPO) where behavior log-probabilities are
  needed for importance weighting" (docstring, `generate.py`) — but no RL trainer. There is no
  preference-optimization command in this package at this commit. **That remains true and is the
  reason this guide stops at SFT.** It is *not* the same as saying preference optimisation is
  unavailable on Apple silicon: a third-party layer built on top of mlx-lm provides it, and
  **§13 now maps that layer** so the boundary is a deliberate scope choice rather than an
  apparent hole.
- **Vision-language fine-tuning.** `mlx_lm` is text-only; `save_config` even deletes
  `vision_config` from any config it writes (§9.4). VLM work lives in `mlx-vlm`, out of scope.
- **Running the adapter from Swift** — [Part 13](../../part-13-mlx-swift/README.md) — or converting the fused
  model to Core AI — [Part 14](../../part-14-bridges-between-stacks/README.md).

## What you need

- A Mac with Apple silicon, macOS >= 15, and enough unified memory. The honest floor for anything
  useful is 32 GB; 16 GB works for models at or under ~3B in 4-bit with `--batch-size 1
  --num-layers 4`.
- `pip install "mlx-lm[train]"` — **not** plain `pip install mlx-lm`. The `train` extra pulls
  `datasets` and `tqdm`.
- ⚠️ Two more packages that `mlx_lm.lora` imports at module scope but `setup.py` does **not**
  declare: `rich` (via `mlx_lm/cli_ui.py`) and `regex` (via the tool parsers). On a bare install,
  `mlx_lm.lora` dies with `ModuleNotFoundError: No module named 'rich'` before printing a single
  line. `pip install rich regex` alongside. This is a packaging defect at this commit, not a
  documented requirement.
- A dataset. Three or four hundred examples is enough to see movement; a thousand is enough to
  believe it.

---

## Evidence ladder used in this guide

Ranked strongest first, and every claim below carries a marker.

1. **Source read on disk this session** — the `ml-explore/mlx-lm` and `ml-explore/mlx` clones. For
   MLX this outranks everything, including MLX's own documentation site, because the package moves
   weekly and the docs lag it. Citations are `path:line`, valid at commit `e5baded`.
2. **The MLX documentation site crawl**, for `mlx.core` / `mlx.optimizers` surface that mlx-lm only
   *calls*.
3. **Apple documentation, WWDC26 transcripts, and Apple-staff Developer Forums answers** — used
   here only for §0, the adapter sunset.
4. **GitHub issues/PRs with maintainer replies**, always cited by number.
5. **Community measurements**, always labelled as such.

> ✅ **VERIFIED** — quoted from a file read this session, citation attached.
> 🟡 **RECONSTRUCTED** — the mechanism is attested but the exact spelling or number is inferred.
> 🔴 **GAP** — not verified. The box says what is unknown, what would resolve it, and what to do
> in the meantime.

⚠️ **Line numbers drift.** Every `file:line` below is from commit `e5baded`. If you are on a
different checkout, grep for the symbol, not the line.

---

## Contents

| § | Section |
|---|---|
| [0](#0-the-frame-custom-adapters-are-gone-in-os-27) | The frame: custom adapters are gone in OS 27 |
| [1](#1-install-and-the-version-matrix) | Install and the version matrix |
| [2](#2-the-data-format-all-four-of-it) | The data format, all four of it |
| [3](#3-the-complete-flag-surface-of-mlx_lmlora) | The complete flag surface of `mlx_lm.lora` |
| [4](#4-what-lora-dora-and-full-actually-compute) | What LoRA, DoRA and `full` actually compute |
| [5](#5-qlora-training-against-a-quantized-base) | QLoRA: training against a quantized base |
| [6](#6-rank-scale-and-target-modules) | Rank, scale, and target modules |
| [7](#7-learning-rate-schedules-and-optimizers) | Learning rate, schedules and optimizers |
| [8](#8-memory-is-the-binding-constraint) | Memory is the binding constraint |
| [9](#9-checkpointing-resuming-and-what-lands-on-disk) | Checkpointing, resuming, and what lands on disk |
| [10](#10-evaluating-the-result) | Evaluating the result |
| [11](#11-mlx_lmfuse-and-what-it-costs-you) | `mlx_lm.fuse`, and what it costs you |
| [12](#12-the-complete-worked-run) | The complete worked run |
| [13](#13-beyond-mlx_lmlora-the-third-party-training-layer) | Beyond `mlx_lm.lora`: the third-party training layer |

---

**Scope:** this reference intentionally ends at §13; architecture porting and parity verification
belong to a separate guide. API spellings and CLI flags are pinned to the inspected mlx-lm revision.[^scope-source]

## 0. The frame: custom adapters are gone in OS 27

Read this before anything else, because it changed the answer to "how do I adapt a model on Apple
hardware" in the 2026 cycle, and a lot of material written for iOS 26 is now actively misleading.

### 0.1 What Apple said

> ✅ **VERIFIED** — two independent Apple-staff statements on the Apple Developer Forums, captured
> in `notes/forums/forum-pain-points.md` §3.1.
>
> **Thread 829108, "Adapter Problem — compatibleAdapterNotFound", Frameworks Engineer (Apple):**
> *"as we announced at WWDC26, custom adapters are unfortunately no longer supported as of OS 27.
> Instead, you can use the base machine-learning models that are available on people's devices or
> provide your own custom models using Core ML or Core AI. Background Assets remains a great way
> to deliver custom models to your users."*
>
> **Thread 831314, "Adapter Training Toolkit: updated version for OS 27?", Apple Designer
> (Apple):** *"Sorry, we're no longer supporting adapters as of OS 27. I'll update the page."*
>
> Corroborating detail from the OP of 831314: the Adapter Training Toolkit version page listed
> **26.0.0** as its latest release, *"noted as the last release for the OS 26 line."*

Two Apple employees, two threads, one answer, plus a toolkit that stops shipping. This is as
settled as anything in this corpus gets. It supersedes any WWDC25/iOS 26 material describing
`SystemLanguageModel.Adapter(name:)` as a forward-looking extensibility story.

### 0.2 What that leaves standing

Apple named the replacement path itself: **Core ML or Core AI for the model, Background Assets for
delivery.** Notice what is *not* in that sentence — any first-party way to nudge the system model
toward your domain. If you want a model that knows your product taxonomy, your tone, or your
schema, in 2026 you ship a model, and you adapt it yourself.

That is what this guide is. The chain is:

```
HF checkpoint ──mlx_lm.convert──▶ quantized MLX model
                                        │
                          mlx_lm.lora ──┤ (LoRA / DoRA / full)
                                        ▼
                                   adapters/        ← swappable, ~10–100 MB
                                        │
                             mlx_lm.fuse│           ← one-way
                                        ▼
                                  fused_model/      ← a normal MLX model again
                                        │
             ┌──────────────────────────┼─────────────────────────────┐
             ▼                          ▼                             ▼
      mlx_lm.server              MLX Swift (Part 13)          Core AI (Part 14)
   (an OpenAI-compatible          on-device inference,        .aimodel, ANE routing,
    backend that Foundation       adapters load directly       Background Assets
    Models can drive — see        from adapters/
    Part 4)
```

Two things on that diagram are worth stopping on.

**The adapter directory crosses the language boundary unchanged.** mlx-swift-lm's `LoRAContainer`
reads exactly the `adapter_config.json` + `adapters.safetensors` pair that `mlx_lm.lora` writes.

> ✅ **VERIFIED** — `notes/repos/mlx-swift-lm.md` §15.2, from
> `Libraries/MLXLMCommon/Adapters/LoRA/LoRAContainer.swift`:
> `public static func from(directory: URL) throws -> LoRAContainer   // adapter_config.json + adapters.safetensors`
> with `LoRAConfiguration` decoding `fine_tune_type`, `num_layers` and
> `lora_parameters { rank, scale, keys }`.

So an adapter you train in Python on a Mac is loadable, unloadable and fusable from Swift on a
device, through `LanguageModel.load(adapter:)` / `unload(adapter:)` / `fuse(with:)`. That is the
practical replacement for the swappable-`.fmadapter` model that OS 27 withdrew — with the large
caveat that it applies to *your* model, not to Apple's system model.

⚠️ **One cross-stack default mismatch to watch.** Python's `LoRALinear` defaults `scale=20.0`
(`mlx_lm/tuner/lora.py:17`, ✅ verified); Swift's `LoRAConfiguration.LoRAParameters.scale` defaults
to **10.0** (`notes/repos/mlx-swift-lm.md` §15.2, ✅ verified). If your `adapter_config.json` is
present this never bites, because the Swift side reads `scale` from the file. If you hand-build a
`LoRAConfiguration` in Swift and forget to set it, your adapter is applied at **half strength** and
nothing warns you.

**Foundation Models can still be the front door.** `ChatCompletionsLanguageModel` turns an
OpenAI-compatible endpoint — including `mlx_lm.server` — into a `LanguageModel` conformer. So
"fine-tune with MLX, serve with `mlx_lm.server`, call it through `LanguageModelSession`" is a
supported 2026 shape on macOS. See [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md) for the
session-level story and its constraints (notably: guided generation needs logits, and not every
backend exposes them).

### 0.3 Two claims about on-device fine-tuning that are false

The community corpus around this is polluted, and one specific fabrication circulates widely.

> 🔴 **KNOWN-BAD CLAIM.** A widely-syndicated builder guide asserts an on-device Foundation Models
> training API shaped like `LanguageModelAdapter.train(...)` / `FineTuningExample(prompt:completion:)`
> / `LanguageModelSession(adapter:)`, with specifics such as "training times under 10 minutes on
> A17 Pro and later", "training is paused when battery is below 20%", and "adapter size is capped
> at 50 MB". **None of it is attested by any other source in this corpus**, the article
> self-declares AI authorship, and no WWDC26 session mentions on-device LoRA training in
> Foundation Models. Source of this assessment: `notes/web/community-blogs.md` §9.2 and its
> top-level finding list, which classifies the piece grade **D** and says it "invents a
> fine-tuning API". Treat every identifier in that snippet as fabricated.

The second false claim is subtler and is *this guide's* to correct: "MLX means I can fine-tune on
an iPhone." You can train **with MLX Swift** on a device — mlx-swift-examples ships a
`LoRATrainingExample` app target — but you cannot run `mlx_lm.lora`, or any of Python MLX, on iOS.
See §8.6 for the details and the two open issues behind it.

---

## 1. Install and the version matrix

### 1.1 The install line

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install "mlx-lm[train]"
pip install rich regex          # ⚠️ undeclared but imported at module scope — see below
```

> ✅ **VERIFIED** — `setup.py`, read this session:
> ```python
> MIN_MLX_VERSION = "0.31.2"
> install_requires=[
>     f"mlx>={MIN_MLX_VERSION}; platform_system == 'Darwin'",
>     "numpy", "transformers>=5.7.0", "sentencepiece", "protobuf", "pyyaml", "jinja2",
> ],
> extras_require={
>     "test": ["datasets", "lm-eval"],
>     "train": ["datasets", "tqdm"],
>     "evaluate": ["lm-eval", "tqdm"],
>     "cuda13": [...], "cuda12": [...], "cpu": [...],
> },
> python_requires=">=3.8",
> ```

Four observations that matter for a training box:

1. **`mlx` is only pinned on Darwin.** `platform_system == 'Darwin'` guards it. On Linux you get
   MLX through `pip install "mlx-lm[cuda13]"` / `[cuda12]` / `[cpu]`. mlx-lm is no longer an
   Apple-silicon-only package — but everything about *memory behaviour* in this guide is written
   for unified memory on Apple silicon, and the CUDA path has its own failure modes.
2. **`transformers >= 5.7.0`.** That is a major-version step past the 4.x era that most fine-tuning
   tutorials were written against; tokenizer and chat-template APIs differ. Commit `c89c93c`
   ("transformers>=5.7 (#1356)") made the bump.
3. **`python_requires=">=3.8"` is wrong.** ✅ VERIFIED: `mlx_lm/quant/awq.py` and the tool parsers
   use PEP-604 `X | None` annotations and `cli_ui.py` uses `list[tuple[str, str]]`, all of which
   need **3.10** at runtime. MLX's own docs also state a **native Python >= 3.10** requirement.
   Use 3.11 or 3.12.
4. **The `train` extra gives you `datasets` and `tqdm` — and nothing else.** `rich` and `regex` are
   imported at module scope by code `mlx_lm.lora` reaches on line one.

> ⚠️ **The first thing that will go wrong.** On a bare `pip install mlx-lm`:
> ```
> $ mlx_lm.lora --model ... --train --data ./data
> ModuleNotFoundError: No module named 'rich'
> ```
> ✅ VERIFIED by import chain: `mlx_lm/lora.py:16` does
> `from .cli_ui import make_console, print_lora_run_header, rprint`, and `mlx_lm/cli_ui.py` imports
> `rich.console`, `rich.progress`, `rich.panel`, `rich.theme` at module scope. `rich` appears
> nowhere in `install_requires`. Same story for `regex` in `mlx_lm/tool_parsers/*.py`
> (`import regex as re`). Whether the published PyPI wheel adds them is 🔴 **UNVERIFIED** from this
> clone — the `setup.py` on disk does not.

### 1.2 Versions on disk, and the PyPI gap

| Component | Value | Source |
|---|---|---|
| `mlx-lm` | **0.31.3** | `mlx_lm/_version.py` (✅ read) |
| `mlx` (this clone) | **0.32.1** | `mlx/version.h` `MLX_VERSION_{MAJOR,MINOR,PATCH} = 0,32,1` (✅ read) |
| `mlx` minimum for mlx-lm | **0.31.2** | `setup.py` (✅ read) |
| newest `mlx-lm` on PyPI | **0.31.3**, released **2026-04-22** | `notes/repos/issues-mlx-stack.md` §0, `gh release list` |
| newest `mlx` release | **v0.32.0**, 2026-07-07 (dev line patched to 0.32.1) | same |

> ⚠️ **The PyPI gap is the single most common cause of "the guide is wrong".** mlx-lm 0.31.3 is
> from April; `main` has months of merged fixes on top of it. `notes/repos/issues-mlx-stack.md`
> records that several issues *explicitly distinguish* "0.31.3 release" vs "current main". Also
> noted there: **mlx-lm 0.31.0 was yanked** for "BatchKV cache cross-contamination". If you are
> reproducing this guide exactly, install from the repo:
> ```bash
> git clone https://github.com/ml-explore/mlx-lm && cd mlx-lm && pip install -e ".[train]"
> ```
> and record the commit hash in your run notes. Every number you produce is meaningless without it.

### 1.3 Sanity check before you spend an hour on a training run

```bash
python -c "import platform; print(platform.processor())"     # must print: arm
python -c "import mlx.core as mx; print(mx.__version__, mx.metal.is_available())"
python -m mlx_lm --version
sysctl hw.memsize | awk '{print $2/1e9 \" GB\"}'
```

> ✅ **VERIFIED** — the `platform.processor()` check is MLX's own documented troubleshooting step:
> *"should be `arm`. If it is `i386` (and you have M series machine) then you are using a
> non-native Python."* (`notes/web/mlx-docs-site.md` §1.4, verbatim from the docs site.)
> `python -m mlx_lm --version` prints `__version__`; note that running
> `python -m mlx_lm.lora` directly prints a deprecation banner — the supported spellings are
> `mlx_lm.lora ...` and `python -m mlx_lm lora ...` (✅ `mlx_lm/lora.py:394-398`).

---

## 2. The data format, all four of it

Everything about your fine-tune's quality is decided here, and this is also where the most
expensive silent failure in the whole workflow lives (§2.5).

### 2.1 The four formats

> ✅ **VERIFIED** — `mlx_lm/LORA.md` §Data, and the loader classes in `mlx_lm/tuner/datasets.py`.

**`chat`** — one message list per line.

```jsonl
{"messages": [{"role": "system", "content": "You are a helpful assistant."}, {"role": "user", "content": "Hello."}, {"role": "assistant", "content": "How can I assistant you today."}]}
```

**`tools`** — a `chat` line that additionally carries a `tools` array. Same loader
(`ChatDataset`), which picks `tools` up with `d.get("tools", None)` and forwards it to
`apply_chat_template`.

```jsonl
{"messages":[{"role":"user","content":"What is the weather in San Francisco?"},{"role":"assistant","tool_calls":[{"id":"call_id","type":"function","function":{"name":"get_current_weather","arguments":"{\"location\": \"San Francisco, USA\", \"format\": \"celsius\"}"}}]}],"tools":[{"type":"function","function":{"name":"get_current_weather","description":"Get the current weather","parameters":{"type":"object","properties":{"location":{"type":"string"},"format":{"type":"string","enum":["celsius","fahrenheit"]}},"required":["location","format"]}}}]}
```

LORA.md is explicit that the `arguments` encoding is model-specific: *"The format for the
`arguments` field in a function varies for different models. Common formats include JSON strings
and dictionaries."* OpenAI and Mistral use a JSON *string*; Hugging Face chat templates often want
a *dict*. Match the model you are training, not the example.

**`completions`** — the format most people want.

```jsonl
{"prompt": "What is the capital of France?", "completion": "Paris."}
```

**`text`** — raw continuation training, no template applied.

```jsonl
{"text": "This is an example for the model."}
```

> [!NOTE] from LORA.md, verbatim: *"Each example in the datasets must be on a single line. Do not
> put more than one example per line and do not split an example across multiple lines."*

### 2.2 Detection order — and it only looks at line 1

```python
# mlx_lm/tuner/datasets.py:177-204  (✅ verbatim)
def create_dataset(data, tokenizer, config):
    mask_prompt        = getattr(config, "mask_prompt", False)
    prompt_feature     = getattr(config, "prompt_feature", "prompt")
    text_feature       = getattr(config, "text_feature", "text")
    completion_feature = getattr(config, "completion_feature", "completion")
    chat_feature       = getattr(config, "chat_feature", "messages")
    sample = data[0]
    if prompt_feature in sample and completion_feature in sample:
        return CompletionsDataset(data, tokenizer, prompt_feature, completion_feature, mask_prompt)
    elif chat_feature in sample:
        return ChatDataset(data, tokenizer, chat_key=chat_feature, mask_prompt=mask_prompt)
    elif text_feature in sample:
        if mask_prompt:
            raise ValueError("Prompt masking not supported for text dataset.")
        return TextDataset(data, tokenizer, text_key=text_feature)
    else:
        raise ValueError("Unsupported data format, check the supported formats here:\n"
                         "https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/LORA.md#Data.")
```

Three consequences, all ✅ verified from that function:

1. **`sample = data[0]`.** The format is decided by the *first line of the file*, for the whole
   file. Mixed files do not error at load; they error later with a `KeyError` in `process()`, or —
   if the stray records happen to carry the winning key — they train on the wrong field.
2. **Precedence is `completions` → `chat` → `text`.** A record carrying both `prompt`/`completion`
   *and* `messages` is read as completions and `messages` is ignored.
3. **`--mask-prompt` is illegal for `text`** and raises. It is fine for `chat` and `completions`.

Key names are configurable **only from YAML** (`prompt_feature`, `completion_feature`,
`text_feature`, `chat_feature`) — there are no CLI flags for them.

### 2.3 What each loader actually feeds the model

```python
# ChatDataset.process        (datasets.py:59-79, ✅ verbatim)
tokens = self.tokenizer.apply_chat_template(messages, tools=tools, return_dict=False)
if self.mask_prompt:
    add_generation_prompt = messages[-1].get("role") == "assistant"
    offset = len(self.tokenizer.apply_chat_template(
        messages[:-1], tools=tools,
        add_generation_prompt=add_generation_prompt, return_dict=False))
    return (tokens, offset)
return (tokens, 0)

# CompletionsDataset.process (datasets.py:109-129, ✅ verbatim)
messages = [{"role": "user",      "content": d[self.prompt_key]},
            {"role": "assistant", "content": d[self.completion_key]}]
tokens = self.tokenizer.apply_chat_template(messages, tools=tools, return_dict=False)
# mask_prompt offset = len(apply_chat_template(messages[:-1], add_generation_prompt=True, ...))

# TextDataset.process        (datasets.py:28-32, ✅ verbatim)
d = self.tokenizer.encode(d[self.text_key])
if d[-1] != self.tokenizer.eos_token_id:
    d.append(self.tokenizer.eos_token_id)
return (d, 0)
```

Read that carefully, because it settles four questions people ask constantly:

- **`completions` is not raw concatenation.** It is silently promoted into a two-turn chat and run
  through `apply_chat_template`. Your `prompt` becomes a *user* message and your `completion`
  becomes an *assistant* message. If you were expecting `prompt + completion` verbatim, use `text`.
- **`text` is the only format that does not apply the chat template**, and it is the only one that
  appends EOS explicitly. The template-driven formats rely on the template to emit its own
  end-of-turn token.
- **The second element of the tuple is the prompt offset**, in tokens, and it is `0` unless
  `--mask-prompt`.
- **Both offsets are computed by re-rendering the template on `messages[:-1]` and taking its
  length.** That is a *string-length-in-tokens* subtraction, not an alignment. It is exact when the
  template is prefix-stable — the rendering of the first *n* turns is a prefix of the rendering of
  *n+1* turns — and every mainstream template is. It is not guaranteed by anything.

### 2.4 What `--mask-prompt` does to the loss

```python
# mlx_lm/tuner/trainer.py:86-99  (✅ verbatim)
def default_loss(model, batch, lengths):
    inputs  = batch[:, :-1]
    targets = batch[:,  1:]
    logits  = model(inputs)
    steps = mx.arange(1, targets.shape[1] + 1)
    mask  = mx.logical_and(steps >= lengths[:, 0:1], steps <= lengths[:, 1:])
    ce = nn.losses.cross_entropy(logits, targets) * mask
    ntoks = mask.sum()
    ce = ce.astype(mx.float32).sum() / ntoks
    return ce, ntoks
```

`lengths` is `mx.array(list(zip(offsets, lengths)))` — column 0 is the prompt offset, column 1 is
the true (post-truncation) sequence length. The mask is **two-sided**: it excludes padding on the
right *and*, when `--mask-prompt` is on, the prompt on the left. Loss is normalised by the number
of *unmasked* tokens, so switching masking on and off changes the loss *scale*, not just its value
— do not compare loss curves across that switch.

**When to use it.** Turn `--mask-prompt` on when your prompts are long, formulaic and identical
across examples (a fixed instruction block, a schema, a retrieved document). Otherwise you are
spending most of your gradient budget teaching the model to reproduce its own input. Leave it off
when the prompt distribution is itself something you want the model to learn, or for `text`
datasets, where it is not available.

### 2.5 ⚠️ SILENT FAILURE — the chat template that trained your adapter is not the one serving it

This is the failure that wastes the most time in practice, and nothing in mlx-lm detects it.

**The mechanism.** Training renders every example through
`tokenizer.apply_chat_template(...)`. `TokenizerWrapper.apply_chat_template` is not a passthrough:

> ✅ **VERIFIED** — `mlx_lm/tokenizer_utils.py`, `TokenizerWrapper.apply_chat_template(*args,
> tokenize=True, **kwargs)` defaults **`enable_thinking=self.has_thinking`** and forces
> `return_dict=False`. `has_thinking` is inferred from the vocabulary by `_infer_thinking`, which
> looks for the pairs in `THINK_TOKENS = [("<think>", "</think>"), ("<longcat_think>",
> "</longcat_think>")]` plus a multi-token `<|channel>thought` / `<channel|>` case.

So on a thinking-capable model, your training data is rendered **with thinking enabled by
default**, whether or not your `completion` strings contain any reasoning. Then at inference time
one of these happens:

- you call `mlx_lm.generate --ignore-chat-template`, or
- you serve with `--chat-template-args '{"enable_thinking":false}'`, or
- you upgraded `transformers` and the model's bundled `chat_template.jinja` changed, or
- you fused into a base repo whose `tokenizer_config.json` is a different revision than the one you
  trained against.

The adapter now sees a token sequence it never saw during training. **Nothing raises.** LoRA is an
additive perturbation on top of a competent base model, so the output stays fluent — it just
carries none of your fine-tuning. The usual reading of that symptom is "my dataset was too small",
and people go and collect more data.

**How to detect it in ten seconds.** Render one training example both ways and diff the *token
ids*, not the strings:

```python
# save as check_template.py — run BEFORE training and again before shipping
import json, sys
from mlx_lm import load

model_path, jsonl_path = sys.argv[1], sys.argv[2]
_, tokenizer = load(model_path)

rec = json.loads(open(jsonl_path).readline())
if "messages" in rec:
    messages = rec["messages"]
else:                                        # completions -> what CompletionsDataset builds
    messages = [{"role": "user",      "content": rec["prompt"]},
                {"role": "assistant", "content": rec["completion"]}]

train_ids = tokenizer.apply_chat_template(messages, return_dict=False)
print("train render :", tokenizer.decode(train_ids)[:400].replace("\n", "\\n"))
print("train tokens :", len(train_ids), train_ids[:16], "...")

# what mlx_lm.generate will build at inference time
infer_ids = tokenizer.apply_chat_template(messages[:-1], add_generation_prompt=True,
                                          return_dict=False)
print("infer prefix :", tokenizer.decode(infer_ids)[:400].replace("\n", "\\n"))
print("prefix match :", train_ids[:len(infer_ids)] == list(infer_ids))
print("has_thinking :", tokenizer.has_thinking)
```

`prefix match: True` is the invariant. If it is `False`, your inference prompt is not a prefix of
your training sequence and the adapter is being asked to extrapolate. Fix it before training, not
after.

**Pin the template.** The durable fix is to stop depending on whatever `transformers` resolves:

1. Convert the base model once with `mlx_lm.convert`, which copies the tokenizer into the output
   directory (`save()` calls `tokenizer.save_pretrained(dst_path)`, ✅ `mlx_lm/utils.py`).
2. Train against **that local directory**, never against the HF repo id.
3. Record `sha256` of `tokenizer_config.json` and `chat_template.jinja` in your run notes.
4. Serve from the fused output of the same directory.

A second, cheaper benefit: MLX's own docstring warns *"to use a fast streaming tokenizer, pass a
local file path rather than a Hugging Face repo ID"* (✅ `tokenizer_utils.py`), because the
detokenizer class is selected by inspecting the local `tokenizer.json`.

### 2.6 Local files vs Hugging Face datasets

**Local.** `--data DIR` where `DIR` contains `train.jsonl`, optionally `valid.jsonl`, and
`test.jsonl` for `--test`.

```python
# datasets.py:207-221  (✅ verbatim)
names = ("train", "valid", "test")
train, valid, test = [load_subset(data_path / f"{n}.jsonl") for n in names]
```

A missing file yields `[]`, not an error, and the consequences are asymmetric:

```python
# datasets.py:322-333  (✅ verbatim)
if args.train and len(train) == 0:
    raise ValueError("Training set not found or empty. Must provide training set for fine-tuning.")
if args.train and len(valid) == 0:
    rprint("Warning: Validation set not found or empty. Training will proceed without validation.")
if args.test and len(test) == 0:
    raise ValueError("Test set not found or empty. Must provide test set for evaluation.")
```

⚠️ **A missing `valid.jsonl` is a warning, not an error.** You get a full training run with no
validation curve, no early signal of overfitting, and a single line of yellow text scrolled off the
top of your terminal. Always ship a `valid.jsonl`.

**Hugging Face.** `--data <repo_id>` if the dataset already has the right column names; otherwise
map them in YAML:

```yaml
hf_dataset:
  path: "billsum"
  prompt_feature: "text"
  completion_feature: "summary"
  train_split: "train[:1000]"
  valid_split: "train[-100:]"
  config: {}          # kwargs forwarded to datasets.load_dataset
```

Defaults when the splits are omitted: `train_split: "train[:80%]"`, `valid_split: "train[-10%:]"`
(✅ `datasets.py:274-275`). A **list** of `hf_dataset` records is also accepted and produces a
`ConcatenatedDataset` — useful for mixing a task set with a general-instruction set to limit
forgetting:

```yaml
hf_dataset:
  - path: "Open-Orca/OpenOrca"
    train_split: "train[:90%]"
    valid_split: "train[-10%:]"
    prompt_feature: "question"
    completion_feature: "response"
  - path: "trl-lib/ultrafeedback_binarized"
    train_split: "train[:90%]"
    valid_split: "train[-10%:]"
    chat_feature: "chosen"
```

⚠️ `ConcatenatedDataset.__getitem__` **mutates the record** it returns, writing a `"_dataset"` key
into it so `process()` can dispatch (✅ `datasets.py:143-154`). Harmless in practice; startling if
you are holding a reference to the same dicts.

### 2.7 A dataset builder you can actually reuse

Three or four hundred well-formed examples beat three thousand sloppy ones. This script enforces
the invariants that the loader does not.

```python
#!/usr/bin/env python3
"""build_dataset.py — turn records into mlx-lm's completions format, with checks.

  python build_dataset.py raw.jsonl ./data --valid-frac 0.1 --test-frac 0.1
"""
import argparse, json, random, sys
from pathlib import Path

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("out_dir")
    ap.add_argument("--valid-frac", type=float, default=0.1)
    ap.add_argument("--test-frac", type=float, default=0.1)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--prompt-key", default="prompt")
    ap.add_argument("--completion-key", default="completion")
    args = ap.parse_args()

    records, seen, dropped = [], set(), 0
    for n, line in enumerate(Path(args.source).read_text().splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except json.JSONDecodeError as e:
            sys.exit(f"line {n}: not valid JSON ({e}). Every example must be on ONE line.")
        p, c = d.get(args.prompt_key), d.get(args.completion_key)
        if not isinstance(p, str) or not isinstance(c, str) or not p.strip() or not c.strip():
            dropped += 1
            continue
        key = (p.strip(), c.strip())
        if key in seen:                    # exact dupes inflate your apparent dataset size
            dropped += 1
            continue
        seen.add(key)
        records.append({"prompt": p.strip(), "completion": c.strip()})

    if not records:
        sys.exit("no usable records")

    random.Random(args.seed).shuffle(records)
    n = len(records)
    n_valid = max(1, int(n * args.valid_frac))
    n_test  = max(1, int(n * args.test_frac))
    splits = {
        "valid": records[:n_valid],
        "test":  records[n_valid:n_valid + n_test],
        "train": records[n_valid + n_test:],
    }

    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    for name, rows in splits.items():
        with open(out / f"{name}.jsonl", "w") as fid:
            for r in rows:
                fid.write(json.dumps(r, ensure_ascii=False) + "\n")
        print(f"{name:5s} {len(rows):6d}  -> {out / (name + '.jsonl')}")
    print(f"dropped {dropped} (blank / non-string / duplicate)")

    # The loader needs at least batch_size examples in every split it touches.
    if len(splits["train"]) < 4:
        print("WARNING: train split < default batch_size=4; iterate_batches will raise.")

if __name__ == "__main__":
    main()
```

That last warning is real: `iterate_batches` raises
`ValueError(f"Dataset must have at least batch_size={batch_size} examples but only has
{len(dataset)}.")` (✅ `trainer.py:116-120`), and it raises for the *validation* set too, which is
how a run dies at iteration 1 after a clean start.

---

## 3. The complete flag surface of `mlx_lm.lora`

### 3.1 The defaults table

Every default lives in one dict, and it doubles as the YAML schema.

```python
# mlx_lm/lora.py:44-81  (✅ verbatim, complete)
CONFIG_DEFAULTS = {
    "model": "Qwen/Qwen3-0.6b",
    "train": False,
    "fine_tune_type": "lora",
    "optimizer": "adam",
    "optimizer_config": {"adam": {}, "adamw": {}, "muon": {}, "sgd": {}, "adafactor": {}},
    "data": "mlx-community/WikiSQL",
    "seed": 0,
    "num_layers": 16,
    "batch_size": 4,
    "iters": 1000,
    "val_batches": 25,
    "learning_rate": 1e-5,
    "steps_per_report": 10,
    "steps_per_eval": 200,
    "resume_adapter_file": None,
    "adapter_path": "adapters",
    "save_every": 100,
    "test": False,
    "test_batches": 500,
    "max_seq_length": 2048,
    "config": None,
    "grad_checkpoint": False,
    "grad_accumulation_steps": 1,
    "clear_cache_threshold": 0,
    "lr_schedule": None,
    "lora_parameters": {"rank": 8, "dropout": 0.0, "scale": 20.0},
    "mask_prompt": False,
    "report_to": None,
    "project_name": None,
    "trust_remote_code": False,
}
```

### 3.2 Flags, grouped by what they control

| Flag | Type | Default | Notes |
|---|---|---|---|
| `--model` | str | `Qwen/Qwen3-0.6b` | HF repo id or local dir. A **quantized** dir ⇒ QLoRA (§5). |
| `--train` | flag | off | Must pass this or `--test`, else `ValueError("Must provide at least one of --train or --test")` |
| `--data` | str | `mlx-community/WikiSQL` | dir with `{train,valid,test}.jsonl`, or an HF repo id |
| `--fine-tune-type` | `lora`\|`dora`\|`full` | `lora` | §4 |
| `--optimizer` | `adam`\|`adamw`\|`muon`\|`sgd`\|`adafactor` | `adam` | §7.3 |
| `--mask-prompt` | flag | off | §2.4. Not valid for `text` datasets |
| `--num-layers` | int | `16` | **`-1` = all**; counted from the *end* |
| `--batch-size` | int | `4` | in distributed mode this is the **global** batch |
| `--iters` | int | `1000` | optimizer *steps* × `grad_accumulation_steps` micro-steps |
| `--learning-rate` | float | `1e-5` | ignored if `lr_schedule` is set |
| `--max-seq-length` | int | `2048` | longer examples are **truncated**, with a warning |
| `--grad-accumulation-steps` | int | `1` | §8.3 |
| `--grad-checkpoint` | flag | off | §8.4 |
| `--clear-cache-threshold` | size | `0` | ⚠️ **silently ignored** — §3.5 |
| `--val-batches` | int | `25` | `-1` = the whole validation set |
| `--steps-per-report` | int | `10` | |
| `--steps-per-eval` | int | `200` | |
| `--save-every` | int | `100` | writes both `adapters.safetensors` and a numbered checkpoint |
| `--adapter-path` | str | `adapters` | created with `mkdir(parents=True, exist_ok=True)` |
| `--resume-adapter-file` | path | `None` | ⚠️ loaded with `strict=False` — §9.3 |
| `--test` | flag | off | test-set perplexity |
| `--test-batches` | int | `500` | `-1` = the whole test set |
| `--seed` | int | `0` | seeds `np.random` in `run()` and `mx.random` in `train_model()` |
| `--report-to` | str | `None` | `wandb`, `swanlab`, or `wandb,swanlab` |
| `--project-name` | str | `None` | |
| `-c` / `--config` | path | `None` | YAML; CLI flags win |
| `--trust-remote-code` | flag | off | gates **both** tokenizer remote code and custom architectures[^trust-source] |

> ✅ All of the above read from `build_parser()` (`mlx_lm/lora.py:84-221`) and `CONFIG_DEFAULTS`.

**`--num-layers -1` means all layers**, via `model.layers[-max(num_layers, 0):]` — `max(-1, 0)` is
`0`, and `layers[-0:]` is `layers[0:]` (✅ `tuner/utils.py:103`). Asking for more layers than exist
is a clean error:

```python
# lora.py:233-237  (✅ verbatim)
if args.num_layers > len(model.layers):
    raise ValueError(f"Requested to train {args.num_layers} layers "
                     f"but the model only has {len(model.layers)} layers.")
```

**`--clear-cache-threshold` accepts human sizes** (`4GB`, `512MB`, bare bytes) via `_parse_size`.
It also does nothing; see §3.5.

### 3.3 The flags that exist *only* in YAML

Four settings have no command-line equivalent at all. If you need them, you need a config file.

| YAML key | Why it matters |
|---|---|
| `lora_parameters:` `{rank, scale, dropout, keys}` | **rank and scale are unreachable from the CLI.** §6 |
| `lr_schedule:` `{name, warmup, warmup_init, arguments}` | warmup and decay. §7.2 |
| `optimizer_config:` `{<name>: {...}}` | betas, eps, weight decay, `bias_correction`. §7.3 |
| `hf_dataset:` (+ `*_feature`, `*_split`) | column mapping and split slicing. §2.6 |

This is the single biggest reason to use a config file: **you cannot set the LoRA rank from the
command line.** Every `mlx_lm.lora --model ... --train` invocation you have ever seen trains at
rank 8, scale 20.0, dropout 0.0, targeting every linear and embedding module in the last 16 layers.

The shipped example, complete:

```yaml
# mlx_lm/examples/lora_config.yaml  (✅ verbatim, trimmed comments)
model: "mlx-community/Llama-3.2-1B-Instruct-bf16"
train: true
fine_tune_type: lora
optimizer: adamw
# optimizer_config:
#   adamw:
#     betas: [0.9, 0.98]
#     eps: 1e-6
#     weight_decay: 0.05
#     bias_correction: true
data: "mlx-community/WikiSQL"
seed: 0
num_layers: 16
batch_size: 4
iters: 1000
val_batches: 25
learning_rate: 1e-5
steps_per_report: 10
steps_per_eval: 200
grad_accumulation_steps: 1
resume_adapter_file: null
adapter_path: "adapters"
save_every: 100
test: false
test_batches: 100
max_seq_length: 2048
grad_checkpoint: false

# LoRA parameters can only be specified in a config file
lora_parameters:
  # The layer keys to apply LoRA to. These will be applied for the last lora_layers
  keys: ["self_attn.q_proj", "self_attn.v_proj"]
  rank: 8
  scale: 20.0
  dropout: 0.0

#lr_schedule:
#  name: cosine_decay
#  warmup: 100
#  warmup_init: 1e-7
#  arguments: [1e-5, 1000, 1e-7]
```

⚠️ Note the discrepancy between this file and `CONFIG_DEFAULTS`: the example **sets
`keys: ["self_attn.q_proj", "self_attn.v_proj"]`**, but the code default is `keys` *absent*, which
means **every** eligible module gets an adapter. The example is more conservative than the default.
Both are ✅ verified; they simply disagree, and which one you get depends on whether you pass
`-c`.

### 3.4 Precedence: CLI beats YAML beats defaults

```python
# lora.py:376-391  (✅ verbatim)
config = args.config
args = vars(args)
if config:
    with open(config, "r") as file:
        config = yaml.load(file, yaml_loader)
    for k, v in config.items():          # prefer command-line arguments
        if args.get(k, None) is None:
            args[k] = v
for k, v in CONFIG_DEFAULTS.items():
    if args.get(k, None) is None:
        args[k] = v
```

The mechanism is "fill in `None`". That is why every store-true flag in `build_parser` is declared
with `default=None` rather than `False` — `--train`, `--test`, `--mask-prompt`, `--grad-checkpoint`
— so that *not passing them* leaves the YAML value intact. Consequence: **there is no way to turn a
YAML `true` back off from the command line.** `--grad-checkpoint` can only ever set it.

`--clear-cache-threshold` is the exception with a real `default=0` in argparse (✅ `lora.py:197-202`),
so a YAML `clear_cache_threshold` is **always overridden by the argparse default of 0** — the
`args.get(k) is None` test never fires for it. Another reason it does nothing.

**The YAML float trick.** `lora.py` re-registers PyYAML's implicit float resolver at import
(`lora.py:28-42`, ✅ read) specifically so `learning_rate: 1e-5` parses as a float. PyYAML 1.1
would otherwise hand you the *string* `"1e-5"`, and your optimizer would fail obscurely. If you
load these configs with your own `yaml.safe_load`, you do not get that fix — quote-free scientific
notation will come back as a string.

### 3.5 ⚠️ SILENT FAILURE — `--clear-cache-threshold` never reaches the trainer

`TrainingArgs` declares the field, `train()` reads it, argparse parses it, and `train_model()`
forgets to pass it.

```python
# lora.py:271-282  (✅ verbatim, complete — count the arguments)
training_args = TrainingArgs(
    batch_size=args.batch_size,
    iters=args.iters,
    val_batches=args.val_batches,
    steps_per_report=args.steps_per_report,
    steps_per_eval=args.steps_per_eval,
    steps_per_save=args.save_every,
    adapter_file=adapter_file,
    max_seq_length=args.max_seq_length,
    grad_checkpoint=args.grad_checkpoint,
    grad_accumulation_steps=args.grad_accumulation_steps,
)
```

```python
# trainer.py:20-22, 78-83, 331  (✅ verbatim)
def _clear_cache(threshold: int):
    if mx.get_cache_memory() > threshold:
        mx.clear_cache()

clear_cache_threshold: int = field(default=0, metadata={...})
...
    _clear_cache(args.clear_cache_threshold)
```

`grep -rn clear_cache_threshold mlx_lm/` returns exactly five hits and **none of them connects the
parsed argument to the dataclass** (✅ run this session).

**What this means in practice.** The threshold is always `0`, so `mx.get_cache_memory() > 0` is
true on essentially every step, so **MLX's allocator recycle pool is flushed after every single
training iteration**. That is the *conservative* behaviour — it keeps the buffer pool from growing
— but it also throws away exactly the reuse that makes allocation cheap, and there is no way to
turn it off. Passing `--clear-cache-threshold 8GB` produces no error, no warning, and no change.

The failure is silent in the worst way: it presents as *"training is slower than the numbers in the
README"*, which everyone attributes to their hardware.

> **Safe default:** do not spend time tuning this flag. If you need the behaviour, drive the
> trainer from Python and construct `TrainingArgs` yourself (§3.6), where the field works.
> **What would resolve it:** a one-line fix upstream. Check whether your checkout passes
> `clear_cache_threshold=args.clear_cache_threshold` before concluding this section still applies.

### 3.6 Driving the trainer from Python instead

Everything the CLI does is available as a library, and the library does not have the two defects
above. This is also the escape hatch for custom losses and real callbacks.

```python
# train_lora.py — the CLI's job, done by hand, with the flags that actually work
import mlx.core as mx
import mlx.optimizers as optim
from mlx_lm import load
from mlx_lm.tuner.datasets import CacheDataset, load_dataset
from mlx_lm.tuner.trainer import TrainingArgs, TrainingCallback, train
from mlx_lm.tuner.utils import build_schedule, linear_to_lora_layers, print_trainable_parameters
from types import SimpleNamespace

MODEL = "./qwen3-4b-4bit"
mx.random.seed(0)

model, tokenizer = load(MODEL)

# load_dataset reads attributes off a namespace, not a dict
data_cfg = SimpleNamespace(
    data="./data", train=True, test=False,
    mask_prompt=True,
    prompt_feature="prompt", completion_feature="completion",
    text_feature="text", chat_feature="messages",
)
train_set, valid_set, _ = load_dataset(data_cfg, tokenizer)

model.freeze()
lora_parameters = {"rank": 16, "scale": 20.0, "dropout": 0.05,
                   "keys": ["self_attn.q_proj", "self_attn.k_proj",
                            "self_attn.v_proj", "self_attn.o_proj"]}
linear_to_lora_layers(model, num_layers=16, config=lora_parameters, use_dora=False)
print_trainable_parameters(model)

lr = build_schedule({"name": "cosine_decay", "warmup": 50, "warmup_init": 1e-7,
                     "arguments": [1e-4, 600, 1e-6]})
optimizer = optim.AdamW(learning_rate=lr, weight_decay=0.01, bias_correction=True)

class Recorder(TrainingCallback):
    def __init__(self): self.train_log, self.val_log = [], []
    def on_train_loss_report(self, info): self.train_log.append(info); print(info)
    def on_val_loss_report(self, info):   self.val_log.append(info);   print(info)

cb = Recorder()

train(
    model=model,
    optimizer=optimizer,
    train_dataset=CacheDataset(train_set),
    val_dataset=CacheDataset(valid_set),
    args=TrainingArgs(
        batch_size=2,
        iters=600,
        val_batches=25,
        steps_per_report=10,
        steps_per_eval=100,
        steps_per_save=100,
        max_seq_length=1024,
        adapter_file="adapters/adapters.safetensors",
        grad_checkpoint=True,
        grad_accumulation_steps=4,
        clear_cache_threshold=4_000_000_000,     # ← works here, unlike the CLI flag
    ),
    training_callback=cb,
)
```

⚠️ **You must write `adapter_config.json` yourself on this path.** `train()` only writes weights.
Without that file, `load_adapters()` raises `FileNotFoundError` and *nothing else in the toolchain
can consume your adapter* — not `mlx_lm.generate --adapter-path`, not `mlx_lm.fuse`, not Swift's
`LoRAContainer.from(directory:)`. Add:

```python
import json, pathlib
pathlib.Path("adapters").mkdir(exist_ok=True)
json.dump({"fine_tune_type": "lora",
           "num_layers": 16,
           "lora_parameters": lora_parameters},
          open("adapters/adapter_config.json", "w"), indent=4)
```

(The CLI writes it via `save_config(vars(args), adapter_path / "adapter_config.json")`, ✅
`lora.py:268` — see §9.4 for what that call quietly does to the contents.)

### 3.7 ⚠️ SILENT FAILURE — `run()` throws away your `training_callback`

If you call `mlx_lm.lora.run(args, training_callback=my_cb)` rather than `train()` directly:

```python
# lora.py:337-344  (✅ verbatim — note that the parameter is overwritten on the next line)
def run(args, training_callback: TrainingCallback = None):
    np.random.seed(args.seed)
    training_callback = get_reporting_callbacks(
        args.report_to, project_name=args.project_name,
        log_dir=args.adapter_path, config=vars(args),
    )
```

Your callback is discarded before it is used, and if `--report-to` is unset the replacement is
`None`. Symptom: a programmatic integration that logs nothing, with no error. **Use `train()`
directly** (§3.6) whenever you need a callback.

---

## 4. What LoRA, DoRA and `full` actually compute

Three paths, one dispatch point.

```python
# lora.py:239-253  (✅ verbatim)
if args.fine_tune_type == "full":
    for l in model.layers[-max(args.num_layers, 0):]:
        l.unfreeze()
    args.lora_parameters = None
elif args.fine_tune_type in ["lora", "dora"]:
    linear_to_lora_layers(model, args.num_layers, args.lora_parameters,
                          use_dora=(args.fine_tune_type == "dora"))
else:
    raise ValueError(f"Received unknown fine-tune-type {args.fine_tune_type}")
```

Note the ordering in `train_model`: `model.freeze()` happens **first** (`lora.py:232`), then either
the last *N* layers are unfrozen wholesale, or LoRA/DoRA modules are inserted — and the insertion
is what unfreezes, because the new `lora_a` / `lora_b` arrays are created fresh and are trainable by
construction while `self.linear` stays frozen.

### 4.1 LoRA

```python
# mlx_lm/tuner/lora.py:67-98  (✅ verbatim, complete)
class LoRALinear(nn.Module):
    def __init__(self, input_dims, output_dims, r=8, dropout=0.0, scale=20.0, bias=False):
        super().__init__()
        self.linear = nn.Linear(input_dims, output_dims, bias=bias)
        self.dropout = nn.Dropout(p=dropout)
        self.scale = scale
        scale = 1 / math.sqrt(input_dims)
        self.lora_a = mx.random.uniform(low=-scale, high=scale, shape=(input_dims, r))
        self.lora_b = mx.zeros(shape=(r, output_dims))

    def __call__(self, x):
        y = self.linear(x)
        z = (self.dropout(x) @ self.lora_a) @ self.lora_b
        return y + (self.scale * z).astype(x.dtype)
```

Four details that matter and are easy to get wrong from memory:

1. **`lora_b` is initialised to exactly zero.** So at step 0 the adapted model is *bit-identical*
   to the base model. This is the property that makes §15.1's silent failure invisible.
2. **`self.scale` is applied at *inference*, not folded into initialisation.** It is mlx-lm's
   equivalent of "alpha", but it is **not** `alpha / r` — there is no division by rank anywhere in
   this file. A rank-8 and a rank-64 adapter at `scale: 20.0` are *not* normalised to comparable
   update magnitudes. If you are porting hyperparameters from a PEFT recipe that specifies
   `lora_alpha`, you want `scale = lora_alpha / r`. 🟡 **RECONSTRUCTED** — the equivalence is
   inferred from the two formulations; the absence of `/ r` in mlx-lm is ✅ verified.
3. **`lora_a` is uniform on `±1/sqrt(input_dims)`**, not Kaiming.
4. **Dropout is applied to `x` before the down-projection**, so it perturbs the adapter path only;
   the frozen base path sees the clean input.

There are two siblings. `LoRAEmbedding` adapts `nn.Embedding` / `nn.QuantizedEmbedding` and carries
an `as_linear(x)` so it works for tied output heads (✅ `tuner/lora.py:282-285`). `LoRASwitchLinear`
adapts MoE expert stacks, with per-expert `lora_a: (num_experts, r, in)` and
`lora_b: (num_experts, out, r)`, applied through two `mx.gather_mm` calls that respect the router's
`indices` and `sorted_indices` (✅ `tuner/lora.py:181-195`).

### 4.2 DoRA

DoRA (weight-**D**ecomposed L**oRA**) splits the weight into a direction and a per-output-row
magnitude, learns the direction with LoRA, and learns the magnitude separately.

```python
# mlx_lm/tuner/dora.py:85-128  (✅ verbatim, the parts that matter)
def set_linear(self, linear):
    self.linear = linear
    self.m = mx.linalg.norm(self._dequantized_weight().astype(mx.float32), axis=1)

def __call__(self, x):
    w = self._dequantized_weight()
    y = x @ w.T
    z = (self.dropout(x) @ self.lora_a) @ self.lora_b
    out = y + (self.scale * z).astype(x.dtype)

    adapted = w + (self.scale * self.lora_b.T) @ self.lora_a.T
    denom = mx.stop_gradient(mx.linalg.norm(adapted, axis=1))

    out = (self.m / denom).astype(x.dtype) * out
    if "bias" in self.linear:
        out = out + self.linear.bias
    return out
```

`self.m` — the magnitude vector, one scalar per output row — is a *trainable parameter*, seeded
from the base weight's row norms. `denom` is the row norm of the *adapted* weight, and it is
wrapped in `mx.stop_gradient`, which is the standard DoRA trick: the normalisation must not
contribute to the gradient or the decomposition collapses.

> ⚠️ **DoRA dequantises the full base weight on every forward pass.** `_dequantized_weight()` is
> called twice per call, and `adapted = w + (scale * lora_b.T) @ lora_a.T` **materialises a
> dense matrix the size of the entire layer weight** on every step, plus a full `mx.linalg.norm`
> over it. On a quantized base this is dramatically heavier than LoRA in both time and peak memory,
> and it defeats the entire point of QLoRA — you pay 4-bit storage *and* 16-bit working set.
> ✅ VERIFIED from the source above.

**Two hard limits, both ✅ verified:**

```python
# tuner/utils.py:67-70
elif isinstance(layer, (SwitchLinear, QuantizedSwitchLinear)):
    if use_dora:
        raise ValueError(f"{type(layer).__name__} doesn't support DoRA yet.")
```

```python
# tuner/dora.py:141-142
if isinstance(embedding, nn.QuantizedLinear):
    raise ValueError("DoRAEmbedding does not yet support quantization.")
```

⚠️ Look closely at the second one. It is in `DoRAEmbedding.from_base`, and it tests
`isinstance(embedding, nn.QuantizedLinear)` — but the thing being passed in is an **embedding**.
`nn.QuantizedEmbedding` is not a subclass of `nn.QuantizedLinear`, so **the guard never fires for
the case it was written for.** A quantized embedding sails past it into
`num_embeddings, dims = embedding.weight.shape`, which for a packed 4-bit weight reports `dims`
**eight times too small**, and you get a `lora_b` of the wrong shape. That is at least a loud
failure downstream (a shape error in the matmul), not a silent one — but it means the intended
error message never appears and the actual error is unrelated to the cause. ✅ VERIFIED by reading
`dora.py:131-151`; 🟡 the downstream symptom is inferred, not run.

> **Safe default for DoRA:** use it on a **bf16 base**, on **dense** (non-MoE) models, without
> LoRA'ing the embedding or `lm_head`, i.e.
> `keys: ["self_attn.q_proj", "self_attn.k_proj", "self_attn.v_proj", "self_attn.o_proj"]`.
> Everything else in the DoRA path has a sharp edge.

### 4.3 Full fine-tuning

`--fine-tune-type full` unfreezes the last `--num-layers` transformer blocks in their entirety and
sets `lora_parameters = None`. There is no `linear_to_lora_layers` call, no `fuse` step, and the
saved `adapters.safetensors` contains **whole layer weights**, not low-rank factors — because the
trainer always saves `model.trainable_parameters()` (✅ `trainer.py:368`, `378`).

Consequences worth stating plainly:

- Your "adapter" file is now hundreds of megabytes to gigabytes.
- `load_adapters` handles it: `if fine_tune_type != "full": linear_to_lora_layers(...)` — the full
  path skips the rebuild and goes straight to `load_weights(..., strict=False)` (✅
  `tuner/utils.py:129-137`). So `--adapter-path` still works for inference.
- `mlx_lm.fuse` is a **no-op** for it. `fuse.py` collects
  `[(n, m.fuse(...)) for n, m in model.named_modules() if hasattr(m, "fuse")]`, and a plain
  `nn.Linear` has no `fuse`. The command still runs and still writes `fused_model/`, because
  `load(adapter_path=...)` already applied the weights — but nothing is "merged", and `--dequantize`
  / `--export-gguf` behave as ordinary conversions. ✅ VERIFIED from `fuse.py:76-83`.
- You cannot full-fine-tune a **quantized** base usefully. `l.unfreeze()` on a `QuantizedLinear`
  exposes packed `uint32` weights plus `scales`/`biases`; gradients do not flow through the packing.
  🔴 **GAP:** the exact failure mode was not run this session — mlx-lm neither warns nor blocks it.
  **Safe default:** for `--fine-tune-type full`, always point `--model` at a bf16/fp16 directory.

### 4.4 Choosing between them

| | LoRA | DoRA | full |
|---|---|---|---|
| trainable params (16 layers, r=8, all-linear, 4B model) | ~0.1–0.5% | same + one vector per adapted row | 100% of the chosen layers |
| works on a quantized base | ✅ (this is QLoRA) | ⚠️ works, but dequantises every step | ❌ don't |
| MoE (`SwitchLinear`) support | ✅ | ❌ raises | ✅ |
| adapter file size | MB | MB | GB |
| swappable at runtime | ✅ | ✅ | ❌ (it *is* the model) |
| `mlx_lm.fuse` merges it | ✅ | ✅ | no-op |
| memory during training | lowest | high | highest |

**Decision rule.** Start with LoRA. It is the only option that is cheap, quantization-friendly,
MoE-capable and swappable — and every published comparison of LoRA against DoRA is a matter of
small deltas, while the cost difference here is not small. Reach for DoRA only when you have a
bf16 base, memory headroom, and a measured LoRA baseline that you are trying to beat. Reach for
`full` only when you are changing what the model *is* (a new language, a new modality of format,
heavy domain shift) and you have both the data and the RAM.

> 🔴 **GAP — no quality comparison exists in this corpus.** mlx-lm ships no LoRA-vs-DoRA-vs-full
> benchmark, and `mlx_lm/BENCHMARKS.md` covers quantization only. The published LoRA/DoRA/QLoRA
> claims in this space come from the original papers (`arXiv:2106.09685`, `arXiv:2305.14314`,
> cited by LORA.md's footnotes), which were not measured on Apple silicon or on these
> implementations. **Do not quote a "DoRA is N% better" number.** Resolving this needs a controlled
> run on your own data; §10 gives you the harness.
>
> **Searched again 2026-08-02, with the negative scoped to the material surveyed.** The project
> documentation for `mlx-lm-lora`, `mlx-tune`, `MLX-GRPO`, and `SiLLM`, plus the ~140-project
> `awesome-mlx` index (§13), contains no LoRA-vs-DoRA-vs-full quality ablation. The named projects
> publish *throughput and memory* numbers, not quality. This widens the corpus beyond mlx-lm, but it
> is not an exhaustive claim about every repository, issue, paper, or unpublished experiment.

---

## 5. QLoRA: training against a quantized base

### 5.1 There is no `--qlora` flag

> ✅ **VERIFIED** — `mlx_lm/LORA.md`, verbatim: *"If `--model` points to a quantized model, then
> the training will use QLoRA, otherwise it will use regular LoRA."*

That is the whole interface. QLoRA is not a mode; it is a property of the directory you point at.

```bash
# 1. make a quantized base once
mlx_lm.convert --model Qwen/Qwen3-4B-Instruct --mlx-path ./qwen3-4b-4bit -q

# 2. train — this is now QLoRA, with no additional flags
mlx_lm.lora --model ./qwen3-4b-4bit --train --data ./data -c lora.yaml
```

`mlx_lm.convert`'s quantization surface, for reference (✅ from `convert.py`, cross-checked against
`notes/repos/mlx-lm.md` §2.3):

| Flag | Default | Notes |
|---|---|---|
| `--hf-path` / `--model` | — | same destination |
| `--mlx-path` | `mlx_model` | ⚠️ **must not already exist** — there is no `--force` |
| `-q` / `--quantize` | off | |
| `--q-mode` | `affine` | `affine` \| `mxfp4` \| `nvfp4` \| `mxfp8` |
| `--q-group-size` / `--q-bits` | mode default | `affine (64,4)`, `mxfp4 (32,4)`, `nvfp4 (16,4)`, `mxfp8 (32,8)` |
| `--quant-predicate` | None | `mixed_2_6` \| `mixed_3_4` \| `mixed_3_6` \| `mixed_4_6`; **`affine` only** |
| `--dtype` | from config | `float16` \| `bfloat16` \| `float32` |
| `-d` / `--dequantize` | off | mutually exclusive with `-q` |

**For a fine-tuning base, prefer plain 4-bit affine.** The mixed recipes and the FP formats are
inference optimisations; mixing bit widths across layers gives you a base whose per-layer numerical
quality varies, which is not what you want underneath a gradient signal. If you are memory-bound
enough to consider `mixed_3_6`, you are better off reducing `--num-layers`.

### 5.2 The one line that makes it work

Attaching a LoRA to a `QuantizedLinear` requires knowing the *logical* input dimension, but the
stored weight is packed — 4-bit weights live eight-to-a-`uint32`.

```python
# tuner/lora.py:21-23  (✅ verbatim)
output_dims, input_dims = linear.weight.shape
if isinstance(linear, nn.QuantizedLinear):
    input_dims = input_dims * 32 // linear.bits
```

`32 // bits` is the packing factor: 8 for 4-bit, 4 for 8-bit, 16 for 2-bit. The same line appears in
`DoRALinear.from_base` (`dora.py:20-21`) and, with `dims` instead of `input_dims`, in
`LoRAEmbedding.from_base` (`lora.py:207-208`). Get it wrong and you build a `lora_a` with 1/8th the
rows it needs.

**What is and is not trained.** The packed base weight, its `scales` and its `biases` are all
frozen; only `lora_a` and `lora_b` move. Gradients flow *through* the dequantized matmul to the
adapter, not into the quantization parameters. (Training the quantization parameters themselves is
a different technique — that is DWQ, `mlx_lm.dwq`, covered in this part's quantization guide, and
it explicitly unfreezes `keys=["scales", "biases"]`.)

### 5.3 What QLoRA costs you

Three effects, in decreasing order of how often they bite:

1. **Memory: a large win.** The base weights are ~4× smaller, and they dominate the resident set
   for any model you would actually fine-tune. This is the single most effective memory lever
   available and it is free.
2. **Speed: usually a win, occasionally not.** Quantized matmul is bandwidth-bound and the smaller
   weights help; but the backward pass through a quantized layer is not the same kernel path as the
   forward, and on some shapes it is slower than bf16. Measure, do not assume.
3. **Quality: a real but usually small loss**, and it is *the base model* that degrades, not your
   adapter. If your evaluation shows the fine-tune is worse than expected, re-run the *baseline*
   evaluation on the quantized base before blaming the adapter.

> ⚠️ **A quantization correctness caveat you must know about if you are on M5 or A19.**
> `notes/repos/issues-mlx-stack.md` §4.1 documents **mlx#3856** (closed completed 2026-08-26;
> open at research time): affine
> `gather_qmm` silently corrupts MoE output when gathered rows are `> 32768 && % 64 != 0`, and
> separately when `K % 64 != 0` (which also hits `mxfp4`). It **cannot be reproduced on M1–M4**.
> Fix PRs `mlx#3922` and `mlx-lm#1585` ("pad sorted gather rows to 64") were open — `mlx#3922`
> still open on a 2026-07-31 `gh` re-check, as were issue `mlx#3856` and its sibling `mlx#3887`.
> On 2026-08-26 `mlx#3922` merged and `mlx#3856` closed completed; `mlx-lm#1585` had closed
> unmerged on 2026-08-21. `mlx#3887` closed completed on 2026-09-07 after maintainers confirmed
> #3922 covers its reported affine and MXFP ragged-K cases. Also
> **mlx#3912**, "fp quantized matmul corruption when the quantized dim isn't a multiple of 32".
> If you are fine-tuning an MoE in 4-bit on M5-generation silicon, verify your checkout includes
> those fixes before trusting a single loss curve. These are community-reported and
> maintainer-triaged; presented as such.

### 5.4 The NAX caveat, stated sharply

Three NAX (neural-accelerator) correctness fix PRs opened against `ml-explore/mlx` in the **three
days** before 2026-07-27 — `#3912`, `#3922`, `#3924`; the first two **still open**, #3924 **closed
unmerged 2026-08-02**, on a 2026-08-03 `gh` re-check — including a **missing `else` in `tile_matmad_nax` that silently
miscompiles odd tile shapes**. NAX is the newest code path in the stack and it is sharp-edged.

> **Safe default while this settles.** If your fine-tune produces a loss curve that looks *fine*
> but generations that look wrong, and you are on M5-generation hardware, re-run a handful of
> training steps with `MLX_ENABLE_TF32=0` and on the largest tile-friendly shapes you can arrange
> (hidden dims and batch dims that are multiples of 64), and compare. `MLX_ENABLE_TF32` defaults to
> **1** (`notes/repos/issues-mlx-stack.md` §3.1, mlx#3860), it is read **once at first use**, so it
> must be set before any matmul, and mlx-lm PR `#1595` proposes pinning `MLX_ENABLE_TF32=0` in the
> test suite — which tells you how much the maintainers trust it under test conditions.

---

## 6. Rank, scale, and target modules

### 6.1 Which modules get an adapter

```python
# tuner/utils.py:85-110  (✅ verbatim, complete)
if (keys := config.get("keys", None)) is None:
    keys = set()

    def get_keys_for_lora(p, m):
        types = (nn.Linear, nn.QuantizedLinear, SwitchLinear, QuantizedSwitchLinear,
                 nn.Embedding, nn.QuantizedEmbedding)
        if hasattr(m, "to_lora") or isinstance(m, types):
            keys.add(p)

    for l in model.layers:
        l.apply_to_modules(get_keys_for_lora)

for l in model.layers[-max(num_layers, 0):]:
    lora_layers = [(k, to_lora(m)) for k, m in l.named_modules() if k in keys]
    if lora_layers:
        l.update_modules(tree_unflatten(lora_layers))

lora_modules = [(k, to_lora(m)) for k, m in model.named_modules() if k in keys]
if lora_modules:
    model.update_modules(tree_unflatten(lora_modules))
```

Three things follow, all ✅ verified:

**With no `keys`, everything eligible inside a layer is adapted.** Every `Linear`,
`QuantizedLinear`, `SwitchLinear`, `QuantizedSwitchLinear`, `Embedding`, `QuantizedEmbedding` —
that is `q_proj`, `k_proj`, `v_proj`, `o_proj`, `gate_proj`, `up_proj`, `down_proj`, and on an MoE,
the router and every expert stack. This is a **much** broader default than the classic
"q_proj and v_proj only" LoRA recipe, and it is why mlx-lm LoRA runs cost more memory than people
expect from other frameworks.

**Keys are matched against paths *within* a transformer block**, which is why they read
`self_attn.q_proj` and not `model.layers.20.self_attn.q_proj`.

**The second loop is how you reach `lm_head` and `model.embed_tokens`.** They are not inside
`model.layers`, so they are only adapted if you name them explicitly — and then they are matched
against `model.named_modules()`, i.e. **full paths from the root**. The shipped test asserts both
spellings:

```python
# tests/test_finetune.py  (✅ verbatim)
params["keys"] = ["lm_head"]
check_config(params, expected_trainable_parameters=params["rank"] * (args.hidden_size + args.vocab_size))

params["keys"] = ["model.embed_tokens"]
check_config(params, expected_trainable_parameters=params["rank"] * (args.hidden_size + args.vocab_size))
```

⚠️ **`keys` is a plain set-membership test — `if k in keys` — not a glob, not a regex, not a
substring match.** `"q_proj"` alone matches nothing; it must be `"self_attn.q_proj"`. A typo in a
key silently adapts *fewer* modules than you intended, and the only visible consequence is a lower
number in the `Trainable parameters:` line, which nobody reads. **Always read that line.**

**Contrast with mlx-examples' standalone `lora/`,** which is a useful sanity anchor for what a
minimal LoRA looks like:

```python
# mlx-examples/lora/lora.py:342-348  (✅ from notes/repos/mlx-examples.md §6.2)
model.freeze()
for l in model.model.layers[len(model.model.layers) - args.lora_layers:]:
    l.self_attn.q_proj = LoRALinear.from_linear(l.self_attn.q_proj)
    l.self_attn.v_proj = LoRALinear.from_linear(l.self_attn.v_proj)
    if hasattr(l, "block_sparse_moe"):
        l.block_sparse_moe.gate = LoRALinear.from_linear(l.block_sparse_moe.gate)
```

Hard-coded to `q_proj` and `v_proj`. That repo is a teaching example; note also that
`mlx-examples`' HEAD is **2026-04-06** and its `llms/mlx_lm` directory was *deleted* in March 2025
("remove mlx lm (#1353)") — do not take API details from it. It is still the best place to read a
50-line LoRA implementation you can hold in your head, and its `flux/flux/lora.py` (76 lines,
complete) is the smallest complete worked case in the ecosystem.

### 6.2 The parameter-count arithmetic

For a dense Llama-shaped block with hidden size *H*, intermediate size *I* and rank *r*, adapting
every linear:

```
attention: (H·r + r·H) × 4     for q, k, v, o          = 8·H·r
MLP:       (H·r + r·I)         gate                     ┐
         + (I·r + r·H)         down                     ├ = 2r(2H + I)...
         + (H·r + r·I)         up                       ┘
```

which is exactly what the test asserts, per layer:

```python
# tests/test_finetune.py  (✅ verbatim)
nparams = (args.hidden_size * 2 * 4 + (args.intermediate_size + args.hidden_size) * 3) * lora_layers
check_config(params, expected_trainable_parameters=nparams * params["rank"])
```

Read `hidden_size * 2 * 4` as "four attention projections, each contributing `H` rows in and `H`
columns out", and `(I + H) * 3` as "three MLP projections, each contributing `I + H`". Multiply by
`rank`, multiply by the number of adapted layers.

Concrete: `H = 4096`, `I = 14336`, `r = 8`, 16 layers →
`(4096·8 + (14336 + 4096)·3) · 16 · 8 = (32768 + 55296) · 128 ≈ 11.3 M` trainable parameters, or
about 22 MB of bf16 adapter. Adapting `lm_head` on a 128k vocab adds `8 · (4096 + 128000) ≈ 1.06 M`
by itself.

`print_trainable_parameters` reports this for you:

```python
# tuner/utils.py:160-168  (✅ verbatim)
def print_trainable_parameters(model):
    total_p = get_total_parameters(model) / 1e6
    trainable_p = sum(v.size for _, v in tree_flatten(model.trainable_parameters())) / 1e6
    rprint(f"Trainable parameters: {(trainable_p * 100 / total_p):.3f}% "
           f"({trainable_p:.3f}M/{total_p:.3f}M)")
```

⚠️ `get_total_parameters` **un-packs quantized weights** for the denominator
(`m.weight.size * 32 // m.bits`, ✅ `utils.py:197-206`), so the percentage is against the logical
parameter count, not the byte count. That is the right thing, but it means the percentage does not
predict the memory ratio.

### 6.3 Choosing rank

There is no measured rank sweep anywhere in this corpus, so the guidance below is stated as
engineering judgement, not as a result.

| Rank | When |
|---|---|
| **4** | style/tone only; you are nudging register, not adding knowledge |
| **8** (default) | a bounded task with a consistent output shape — classification, extraction, a fixed response format |
| **16** | the honest general-purpose default for a domain fine-tune with a few thousand examples |
| **32–64** | genuine new knowledge, a new output language, or heavy format shift; expect to need more data and more iterations |
| **> 64** | you are approximating full fine-tuning at LoRA's overhead; consider `--fine-tune-type full` on fewer layers instead |

**Rank interacts with target breadth, and you usually want to trade them.** Rank 8 across *all*
linear modules and rank 32 across attention-only cost roughly the same and are not equivalent:
the first spreads a small correction everywhere, the second makes a large correction to routing and
mixing. For instruction-following and format compliance, attention-only at higher rank is the
better bet; for domain vocabulary and factual content, the MLP projections (`gate_proj`, `up_proj`,
`down_proj`) are where the knowledge lives, so breadth wins.

> 🔴 **GAP — no rank/target ablation exists in this corpus.** mlx-lm publishes no rank sweep, no
> target-module comparison, and no adapter-quality benchmark of any kind. The only fine-tuning
> quality number anywhere in the two example repos is mlx-examples' `lora/README.md` claim of
> **Llama 7B on WikiSQL, initial validation loss 2.66 → 1.23 after 1000 iterations** (project
> documentation, undated, hardware unstated for the loss figure). Attribute it as such and do not
> generalise from it. **Safe default: rank 16, attention-only, and run §10's evaluation before you
> touch anything else.**
>
> **Ecosystem sweep 2026-08-02: still none.** The third-party training projects surveyed in §13
> expose `--lora-parameters '{"rank": …}'` and per-layer targeting the same way mlx-lm does, and
> their inspected documentation publishes no sweep over either. Treat this as a negative for the
> named material surveyed on that date, not as proof of an ecosystem-wide absence.

### 6.4 `scale` — mlx-lm's alpha, and the trap in it

`scale` multiplies the adapter output at every forward pass. Default **20.0**.

The trap: the widely-known PEFT convention is `alpha / r`, so an `alpha` of 16 at rank 8 gives an
effective multiplier of **2.0**. mlx-lm's `scale` is the multiplier *directly*, with no rank
division. If you copy `lora_alpha: 32` out of a PEFT config into mlx-lm's `scale`, you have just
applied a 32× — not a 4× — update, and your loss will diverge in the first few dozen steps.

```
mlx-lm scale  =  PEFT lora_alpha / PEFT r
```

🟡 **RECONSTRUCTED.** The absence of a `/ r` in mlx-lm is ✅ verified from `tuner/lora.py`; the
mapping to PEFT's convention is inferred from the two formulations and is not stated anywhere in
this repo.

Practical consequence: **if you change `rank`, you should think about `scale`.** Holding `scale` at
20.0 while raising rank from 8 to 32 quadruples the effective magnitude of the update at equal
weight norms. Either scale it down proportionally (20 → 5) or lower the learning rate.

Also remember §0.2: Swift's default is **10.0**, not 20.0. As long as `adapter_config.json`
travels with the weights this never matters. Ship them together, always.

### 6.5 `dropout`

Default `0.0`. `nn.Dropout(p=dropout)` applied to `x` on the adapter path only.

Raise it (0.05–0.1) when your dataset is small — under ~1,000 examples — and validation loss turns
up while training loss keeps falling. Leave it at zero for large datasets; it costs a little speed
and buys nothing.

⚠️ Dropout is only active in training mode. `train()` calls `model.train()` and `evaluate()` calls
`model.eval()` (✅ `trainer.py:187`, `262`, `306`), so validation loss is computed with dropout
**off** — which is correct, and also means validation loss is not directly comparable to training
loss when dropout is high.

---

## 7. Learning rate, schedules and optimizers

### 7.1 The default is deliberately small

`learning_rate: 1e-5`, with `adam`. That is a *full-fine-tuning*-shaped learning rate, and it is
conservative for LoRA — LoRA's trainable parameters start at zero and have far fewer of them, so
they tolerate, and generally need, more.

Starting points, stated as judgement:

| Setup | Suggested LR |
|---|---|
| `full` | `1e-5` (the shipped default) |
| LoRA / DoRA, rank ≤ 8 | `1e-4` |
| LoRA / DoRA, rank 16–32 | `5e-5` to `1e-4` |
| LoRA on a small model (< 1B) | up to `2e-4` |

The diagnostic loop is short: run 50 iterations with `--steps-per-report 10`. Loss falling steadily
means keep going. Loss flat means the LR is too low or the adapter is too narrow. Loss spiking, or
`nan`, means the LR is too high — halve it. This costs a minute or two and saves an hour.

### 7.2 Schedules and warmup

```python
# tuner/utils.py:18-35  (✅ verbatim, complete)
def build_schedule(schedule_config: Dict):
    schedule_fn = getattr(opt.schedulers, schedule_config["name"])
    arguments = schedule_config["arguments"]
    initial_lr = arguments[0]
    bound_schedule_fn = schedule_fn(*arguments)
    if warmup_steps := schedule_config.get("warmup", 0):
        warmup_init = schedule_config.get("warmup_init", 0.0)
        warmup_fn = opt.schedulers.linear_schedule(warmup_init, initial_lr, warmup_steps)
        return opt.schedulers.join_schedules([warmup_fn, bound_schedule_fn], [warmup_steps + 1])
    else:
        return bound_schedule_fn
```

Four facts you need to use this correctly:

1. **`name` is looked up with `getattr` on `mlx.optimizers.schedulers`.** Any attribute of that
   module works. The published set is `cosine_decay(init, decay_steps[, end])`,
   `exponential_decay(init, decay_rate)`, `linear_schedule(init, end, steps)`,
   `step_decay(init, decay_rate, step_size)`, `join_schedules(schedules, boundaries)`
   (✅ `notes/web/mlx-docs-site.md` §19.5). A misspelled name is an `AttributeError`, not a
   validation message.
2. **`arguments` is positional.** There is no keyword form. For `cosine_decay` that means
   `[init, decay_steps, end]`.
3. **`arguments[0]` is treated as the peak LR** and is what warmup ramps *to*.
4. **`--learning-rate` is ignored entirely when `lr_schedule` is set**
   (`lr = build_schedule(args.lr_schedule) if args.lr_schedule else args.learning_rate`, ✅
   `lora.py:285`). Setting both is not an error; the flag simply does nothing.

A schedule that works for a 600-iteration LoRA run:

```yaml
lr_schedule:
  name: cosine_decay
  warmup: 50            # ~8% of the run
  warmup_init: 1e-7
  arguments: [1e-4, 600, 1e-6]   # peak 1e-4, decay over 600 steps, floor 1e-6
```

⚠️ `decay_steps` should match `iters`. If `decay_steps` is smaller, the LR bottoms out and the tail
of your run trains at the floor; if larger, the schedule is truncated mid-decay and you never reach
the annealed regime the schedule was designed for. Nothing checks this.

⚠️ **The boundary is `warmup_steps + 1`, not `warmup_steps`**, and the cosine schedule restarts its
own step count at the boundary. So the LR trace is: linear ramp for `warmup` steps, then the full
cosine from its own step 0. That is the intended shape; it just means the first cosine step is at
peak, immediately after warmup ended at peak. Fine — but do not be surprised by the plateau.

**Warmup earns its keep here.** LoRA's `lora_b` starts at exactly zero, so the first few gradient
steps see a degenerate parameterisation (the product `a @ b` is zero regardless of `a`). Ramping in
avoids a large, badly-conditioned first step. 50 steps is plenty.

### 7.3 The five optimizers

```python
# lora.py:287-302  (✅ verbatim)
optimizer_name = args.optimizer.lower()
optimizer_config = args.optimizer_config.get(optimizer_name, {})
if   optimizer_name == "adam":      opt_class = optim.Adam
elif optimizer_name == "adamw":     opt_class = optim.AdamW
elif optimizer_name == "muon":      opt_class = optim.Muon
elif optimizer_name == "sgd":       opt_class = optim.SGD
elif optimizer_name == "adafactor": opt_class = optim.Adafactor
else: raise ValueError(f"Unsupported optimizer: {optimizer_name}")
opt = opt_class(learning_rate=lr, **optimizer_config)
```

`optimizer_config` is keyed by optimizer name, so a single YAML can carry settings for several and
only the selected one is used.

Signatures, ✅ verbatim from `notes/web/mlx-docs-site.md` §19.4 (the MLX docs site):

```
class AdamW(learning_rate, betas=[0.9, 0.999], eps=1e-08,
            weight_decay=0.01, bias_correction=False)

class SGD(learning_rate, momentum=0.0, weight_decay=0.0,
          dampening=0.0, nesterov=False)

class Muon(learning_rate, momentum=0.95, weight_decay=0.01,
           nesterov=True, ns_steps=5)
```

**Recommendation: `adamw`, not the default `adam`.** Weight decay on a LoRA adapter is a genuinely
useful regulariser — the adapter is a small perturbation and decay keeps it small — and `adam` in
MLX has no decay. Note also that **`bias_correction` defaults to `False`** in MLX's AdamW, which is
unusual; with warmup you generally want it on:

```yaml
optimizer: adamw
optimizer_config:
  adamw:
    betas: [0.9, 0.98]
    eps: 1e-6
    weight_decay: 0.05
    bias_correction: true
```

**About `muon`.** MLX's own documentation carries an explicit warning:

> ✅ **VERIFIED**, verbatim from the MLX docs: *"Muon may be sub-optimal for the embedding layer,
> the final fully connected layer, or any 0D/1D parameters. Those should be optimized by a
> different method (e.g. `AdamW`)."*

The canonical remedy is `MultiOptimizer` — *"Wraps a list of optimizers with corresponding weight
predicates/filters"*, with `filters` **one shorter** than `optimizers` because the last is the
fallback. `mlx_lm.lora` does not expose it: the CLI builds exactly one optimizer. So if you select
`muon`, it is applied to *everything*, including exactly the parameters MLX tells you not to apply
it to. On a LoRA run that is `lora_a` / `lora_b` (2-D, fine) plus, if you adapted them,
`LoRAEmbedding`'s factors and DoRA's `m` vector (**1-D**, exactly the case warned against).

> ⚠️ **Safe default: do not use `--optimizer muon` from the CLI.** If you want Muon, drive the
> trainer from Python (§3.6) and construct a `MultiOptimizer` yourself. Also note that
> `mlx.optimizers.Muon`'s doc page **404s on the MLX docs site**
> (`notes/web/mlx-docs-site.md:107`, ✅ verified) — the class exists and is exported, but its
> rendered documentation does not.

**`adafactor`** exists and is memory-frugal, but on a LoRA run the optimizer state is a rounding
error next to activations — you are optimising the wrong thing. It is meaningful only for
`--fine-tune-type full`.

---

## 8. Memory is the binding constraint

Everything else in this guide is a preference. This section is the one that decides whether your
run finishes.

### 8.1 Where the memory actually goes

Four consumers, in the order they matter for a LoRA run:

1. **Activations retained for the backward pass.** Scales as
   `batch_size × sequence_length × hidden_size × num_adapted_layers × dtype_bytes`, times a
   per-layer constant that depends on how many tensors the block keeps alive. This is almost always
   the dominant term, and it is the only one with three independent knobs.
2. **Base weights.** Fixed. Quantization is the only lever (§5), and it is a 4× lever.
3. **Optimizer state.** For LoRA this is negligible — two moments over ~10 M parameters. For
   `--fine-tune-type full` it is 2× the trainable weights for Adam, and it becomes co-dominant.
4. **The allocator's recycle pool.** Not "your" memory in any intuitive sense, but it *is* in your
   process footprint. See §8.5, because it is measured wrong by the obvious API.

Note what is *absent* from that list: the KV cache. Training runs a single forward pass over a
padded batch with no cache at all — `default_loss` calls `model(inputs)` with no `cache` argument
(✅ `trainer.py:90`). Every KV-cache tuning instinct from the inference side is irrelevant here.

### 8.2 mlx-lm's own list, verbatim

> ✅ **VERIFIED** — `mlx_lm/LORA.md` §"Memory Issues", the five numbered tips, paraphrased in order:
> **(1)** QLoRA via a `-q` converted base. **(2)** smaller `--batch-size` — *"The default is `4` so
> setting this to `2` or `1` will reduce memory consumption"* — plus `--grad-accumulation-steps N`
> to *"increase the effective batch size without increasing the memory use"*. **(3)** fewer
> `--num-layers` — *"The default is `16`, so you can try `8` or `4`. This reduces the amount of
> memory needed for back propagation. It may also reduce the quality of the fine-tuned model if you
> are fine-tuning with a lot of data."* **(4)** *"Longer examples require more memory"* — split
> them at dataset-build time. **(5)** `--grad-checkpoint`, which *"will be more helpful for larger
> batch sizes or sequence lengths with smaller or quantized models."*

And its reference configuration:

```bash
# ✅ verbatim from LORA.md — "for a machine with 32 GB the following should run reasonably fast"
mlx_lm.lora \
    --model mistralai/Mistral-7B-v0.1 \
    --train \
    --batch-size 1 \
    --num-layers 4 \
    --data  mlx-community/wikisql
```

> *"The above command on an M1 Max with 32 GB runs at about 250 tokens-per-second."*
> **Attribution: mlx-lm project documentation, undated, M1 Max 32 GB, WikiSQL, Mistral-7B bf16.**
> Not an Apple figure, not measured by us, and the MLX and mlx-lm versions it was written against
> are unknown. Treat it as an order of magnitude, not a target.

For contrast, the only other fine-tuning throughput figure in this corpus:
**~475 tokens/sec on an M2 Ultra** for Llama 7B on WikiSQL (mlx-examples `lora/README.md`, project
documentation, undated) — same task, bigger machine, ~1.9×. Both numbers predate this commit by an
unknown margin.

### 8.3 The three levers, and how they interact

| Lever | Effect on peak memory | Effect on quality | Effect on time |
|---|---|---|---|
| `--batch-size` | ~linear | none *if* you compensate with accumulation | linear (fewer, bigger steps are faster per token) |
| `--max-seq-length` | ~linear, and it truncates data | **destroys** examples longer than it | linear |
| `--num-layers` | ~linear in adapted layers | fewer adapted layers = less capacity | sublinear (the frozen forward still runs) |

**Use them in this order:**

1. **Quantize the base** (§5). Free 4×.
2. **`--batch-size 1` + `--grad-accumulation-steps N`.** This is the free lunch. The gradient is
   accumulated across `N` micro-batches and divided before the update:
   ```python
   # trainer.py:246-260  (✅ verbatim)
   @partial(mx.compile, inputs=state, outputs=state)
   def step(batch, prev_grad, do_update):
       (lvalue, toks), grad = loss_value_and_grad(model, *batch)
       if prev_grad is not None:
           grad = tree_map(lambda x, y: x + y, grad, prev_grad)
       if do_update:
           grad = average_gradients(grad)
           if grad_accum_steps > 1:
               grad = tree_map(lambda x: x / grad_accum_steps, grad)
           optimizer.update(model, grad)
           grad = None
       return lvalue, toks, grad
   ```
   ⚠️ Two things this tells you. **`--iters` counts micro-steps, not optimizer updates.** With
   `--grad-accumulation-steps 4`, `--iters 600` performs 150 parameter updates. Scale `iters` up by
   the accumulation factor when you turn this on, or your run is 4× shorter than you think. And
   **the accumulated gradient is held live across micro-steps** (`prev_grad`), so accumulation costs
   you one extra full copy of the gradient tree — negligible for LoRA, not negligible for `full`.
3. **`--max-seq-length`.** Look at your data first (§8.7). Setting it below your P99 example length
   silently truncates:
   ```python
   # trainer.py:149-154, 164-165  (✅ verbatim)
   if max(lengths) > max_seq_length:
       rprint(f"[WARNING] Some sequences are longer than {max_seq_length} tokens. "
              f"The longest sentence {max(lengths)} will be truncated to {max_seq_length}. "
              "Consider pre-splitting your data to save memory.")
   ...
   truncated_length = min(lengths[j], max_seq_length)
   batch_arr[j, :truncated_length] = batch[j][:truncated_length]
   ```
   A truncated `completions` example loses the *end* of its completion — which is exactly the part
   you want the model to learn to produce, including its stop token. This warning fires per batch
   and scrolls past. Fix the data, not the flag.
4. **`--num-layers`.** Last, because it is the one that costs capacity.

**Padding is a fifth, hidden lever.** Batches are padded to
`min(1 + 32·ceil(max_len/32), max_seq_length)` (✅ `trainer.py:156-159`), so a batch containing one
2,000-token example pays 2,017 tokens for *every* row. The trainer is supposed to mitigate this by
sorting the dataset by length so that batches are length-homogeneous — but see §8.8, where that
sorting does not work.

### 8.4 Gradient checkpointing: the mechanism and its side effect

```python
# trainer.py:25-38  (✅ verbatim, complete)
def grad_checkpoint(layer):
    """Update all instances of type(layer) to use gradient checkpointing."""
    fn = type(layer).__call__

    def checkpointed_fn(model, *args, **kwargs):
        def inner_fn(params, *args, **kwargs):
            model.update(params)
            return fn(model, *args, **kwargs)
        return mx.checkpoint(inner_fn)(model.trainable_parameters(), *args, **kwargs)

    type(layer).__call__ = checkpointed_fn
```

```python
# trainer.py:235-236  (✅ verbatim)
if args.grad_checkpoint:
    grad_checkpoint(model.layers[0])
```

The underlying primitive:

> ✅ **VERIFIED**, verbatim from the MLX docs (`notes/web/mlx-docs-site.md`):
> `checkpoint(fun: Callable[P, R]) -> Callable[P, R]` — *"Transform the passed callable to one that
> performs gradient checkpointing with respect to the inputs of the callable. **Use this to reduce
> memory use for gradient computations at the expense of increased computation.**"*

Three consequences that are not obvious from the flag name:

**It patches the class, not the instance.** `type(layer).__call__ = checkpointed_fn`. Passing
`model.layers[0]` therefore checkpoints **every transformer block in the model** — which is the
intent — but it also means the patch is a **process-wide, permanent side effect on that class
object**. Load a second model of the same architecture in the same process after enabling gradient
checkpointing and it is checkpointed too, silently, including during pure inference. In a notebook
this is a real trap: you enable it once, and every subsequent generate call in that kernel is
slower for no visible reason. There is no un-patch function.

**It checkpoints against `model.trainable_parameters()`**, not against the block's input activation.
For a LoRA run the trainable set is the adapter factors, so the recomputation boundary is drawn
where you want it.

**It trades time for memory, and the ratio depends on your shapes.** LORA.md's own guidance —
*"more helpful for larger batch sizes or sequence lengths with smaller or quantized models"* — is
the right heuristic: checkpointing recomputes the forward pass, so it pays off when activations are
large relative to compute, and hurts when the opposite is true.

> 🔴 **GAP — no measured checkpointing overhead.** Neither mlx-lm nor this corpus publishes a
> memory-saved / time-cost figure for `--grad-checkpoint` on any model or shape. **Safe default:**
> turn it on when you are otherwise about to reduce `--num-layers` below 8, and measure both
> `peak_memory` (reported every `--steps-per-report` iterations) and `iterations_per_second` for
> 50 steps with and without. That A/B costs two minutes.
>
> **Ecosystem sweep 2026-08-02: still none** — `mlx-lm-lora` exposes the same `--grad-checkpoint`
> flag and recommends it for 13B+ models (§13) without measuring it either. Given the two-minute
> cost of the A/B above, **this gap is better closed by running it than by more searching**, and
> it is a good candidate for a committed benchmark in this repo rather than a citation.

### 8.5 ⚠️ The peak-memory number the trainer prints is not your memory footprint

The trainer reports `peak_mem = mx.get_peak_memory() / 1e9` (✅ `trainer.py:345`), which lands in
the callback payload as `"peak_memory"`. That number **excludes the allocator's buffer pool.**

> ✅ **VERIFIED** via `notes/repos/issues-mlx-stack.md` §1.1, quoting mlx#3896 (closed 2026-08-08) and a
> contributor's read of `mlx/backend/metal/allocator.cpp` at v0.32.0:
> ```cpp
> active_memory_ += buf->length();
> peak_memory_ = std::max(peak_memory_, active_memory_);   // peak tracks ACTIVE only
> ...
> active_memory_ -= buf->length();                          // on free...
> if (get_cache_memory() < max_pool_size_) { /* buffer RETAINED in the pool */ }
> size_t mem_required = get_active_memory() + get_cache_memory() + size;  // mlx's own check
> ```
> *"`peak_memory_` is a high-water mark of `active_memory_`, so it can never include the buffer
> pool… Note line 132: mlx's own memory-limit enforcement uses `active + cache`. So the library
> already knows the true number; `get_peak_memory()` just isn't it."*
>
> The reporter's measured churn loop (community-measured; M5 Max 128 GB, mlx 0.32.0, Darwin 25.4.0):
>
> | | `get_peak_memory` | `active` | `cache` | `active+cache` | OS footprint |
> |---|---|---|---|---|---|
> | after churn | **1.00 GB** | 0.00 | 60.06 | **60.06** | **60.19** |
> | same churn, `cache_limit=0` | 1.00 | 1.00 | 0.00 | 1.00 | 1.14 |

**What to do about it.** Gate any memory-pressure logic on
`mx.get_active_memory() + mx.get_cache_memory()`. In the same thread that sum matched the OS
footprint to 0.2%. A drop-in callback:

```python
import mlx.core as mx
from mlx_lm.tuner.trainer import TrainingCallback

GB = 1e9

class HonestMemory(TrainingCallback):
    """Report the number that matches `footprint <pid>`, not get_peak_memory()."""
    def __init__(self, ceiling_gb=None):
        self.ceiling = ceiling_gb
        self.worst = 0.0

    def _sample(self, tag, it):
        active = mx.get_active_memory() / GB
        cache  = mx.get_cache_memory() / GB
        total  = active + cache
        self.worst = max(self.worst, total)
        print(f"[{tag} {it:>6}] active {active:6.2f} GB  pool {cache:6.2f} GB  "
              f"total {total:6.2f} GB  (worst {self.worst:6.2f})")
        if self.ceiling and total > self.ceiling:
            print(f"  !! over {self.ceiling} GB — clearing pool")
            mx.clear_cache()

    def on_train_loss_report(self, info): self._sample("train", info["iteration"])
    def on_val_loss_report(self, info):   self._sample("valid", info["iteration"])
```

Two further cautions from the same source, both ✅ verified there:

- **`mx.clear_cache()` genuinely returns the memory, but `phys_footprint` trails the call by a few
  seconds.** Don't sample immediately after and conclude you have a leak.
- **`mx.set_cache_limit(0)`** bounds the pool at the cost of reallocation. In the churn test it
  ended at 1.14 GB footprint instead of 60.19 GB. It is the blunt instrument that works when
  nothing else does.

**Closure context (mlx#3896 closed 2026-08-08; checked 2026-08-23):** the maintainer closed it by
scoping the counter, not changing it — *"`get_peak_memory()` is mostly useful for measuring the
memory consumption when ineferencing/training a single model, where cache hit rate would be close
to 100%. For longtime and parallel model serving it is not going to accurately report the actual
footprint, and I suggest doing manual checking with `get_active_memory() + get_cache_memory()`
instead."* (typo in original). For this section that cuts both ways: a plain single-model
`mlx_lm.lora` run sits inside the counter's intended scope, but the moment the process also serves,
embeds, or churns shapes, the trainer's printed `peak_memory` stops tracking your footprint — gate
on `active + cache` as above. No code or docs change landed at closure.

### 8.6 What OOM looks like — on a Mac, and why not on a phone

**On a Mac, there are four distinct failures and they mean different things.**

| Symptom | What it is | First thing to try |
|---|---|---|
| `[WARNING] Generating with a model that requires N MB which is close to the maximum recommended size…` | the wired-limit warning; you are near the working-set ceiling | `sudo sysctl iogpu.wired_limit_mb=N` (N > model MB, < machine RAM) |
| `libc++abi: terminating due to uncaught exception of type std::runtime_error: [METAL] Command buffer execution failed: Insufficient Memory (…kIOGPUCommandBufferCallbackErrorOutOfMemory)` | a real allocation failure inside a command buffer | reduce batch / seq length; this is a hard stop |
| `RuntimeError: [metal::malloc] Resource limit (499000) exceeded` | **not bytes** — you exhausted the *count* of live Metal buffers | see below |
| `[METAL] Command buffer execution failed: … Timeout Error`, or the whole machine hangs / reboots | the GPU watchdog, usually after over-committing | reduce the working set; do not trust `get_peak_memory` (§8.5) |

The third one deserves special attention because it looks like an OOM and is not.

> ✅ **VERIFIED** — `notes/repos/issues-mlx-stack.md` §1.2 (mlx#3849) and §1.4 (mlx-lm#1332):
> `resource_limit` is a **count of live resident Metal buffers**, read once at init from sysctl
> `iogpu.rsrc_limit`, with a **hardcoded `499000` fallback** in `device_info.cpp`. On macOS 26/27
> the sysctl OID is gone, so the fallback is *always* what is used. Read it back with
> `mx.device_info()["resource_limit"]`. **There is no setter** — a contributor's summary:
> *"We expose `set_memory_limit`, `set_cache_limit` and `set_wired_limit`, but `resource_limit` is
> the odd one out: it's read once at init and never settable."* No byte budget affects it.
>
> **The training-specific cause, verbatim from that thread:** *"compiled training with a fixed
> shape plateaus; compiled training with new sequence shapes grows when each new shape is
> introduced; … the same variable-shape schedule in eager mode remains flat; calling
> `mx.clear_cache()` after every step does not stop the growth."* … *"`mx.compile` keeps a cache
> entry per distinct input signature (shape + dtype + constants), and it's unbounded."*

That is *exactly* the mlx-lm training loop's shape: `step` is `mx.compile`d (`trainer.py:246`) and
batches are padded to `1 + 32·ceil(max_len/32)` — **a new compiled variant for every distinct
padded length in your dataset**. A dataset with 40 distinct padded lengths produces 40 compiled
variants, each retaining buffers. This is the mechanism by which a long training run dies with
"Resource limit exceeded" while `get_peak_memory()` reports something modest.

Mitigations, in order:
- **Narrow the length distribution at dataset-build time.** Fewer distinct padded lengths, fewer
  variants. This is the fix with no downside.
- `mx.compile(..., shapeless=True)` compiles one variant with symbolic leading dims. mlx-lm's
  trainer does **not** pass `shapeless`, so this needs a local patch or a Python-driven loop.
  Caveats from the same thread: shapeless gives up shape specialisation, and *constants* that vary
  across calls still make distinct entries.
- There is **no public API to clear the compile cache**. `disable_compile()` turns compilation off
  rather than reclaiming; an internal `detail::compile_clear_cache` exists but is wired to
  interpreter exit.

**Closure context (mlx#3849 closed 2026-08-05; checked 2026-08-23):** the maintainer's closing
comment concedes the guard itself is broken — *"The code reading resource limit is bugged and we
should probably fix it or just remove it"* — but keeps it, because exceeding it *"clearly indicates
some fatal mistakes"* like the compile-variant accumulation above: *"So at the moment I think it is
fine keep it be."* So as of closure there is no setter, no fix scheduled, and the `499000` ceiling
stays; the mitigations above are the whole toolbox.

**On a phone: you cannot hit any of this, because you cannot get there.**

> ✅ **VERIFIED** — `notes/repos/issues-mlx-stack.md` §10:
> **mlx#3665 (OPEN)** — *"MLX doesn't publish iOS-compatible wheels."* Filed by a CPython core
> developer who authored PEP 730 (iOS support) and maintains Briefcase; as of Python 3.14, Python
> supports iOS, but mlx publishes macOS wheels only.
> **mlx#3915 (OPEN)** — *"CMake cannot build Metal kernels for iOS."* PR #3617 fixed the
> configure-level gate, but *"the Metal kernel custom commands still explicitly use `xcrun -sdk
> macosx metal …`"* and the final `mlx.metallib` is linked with the macOS SDK. `mlx-swift`
> sidesteps this by having Xcode build and bundle the shaders separately.

So: **there is no `mlx_lm.lora` on iOS, iPadOS, visionOS or watchOS.** Python MLX is a Mac tool.

On-device training *does* exist, on the Swift side, and it is a different codebase:

> ✅ **VERIFIED** — `notes/repos/mlx-swift-lm.md` §15.3 and `notes/repos/mlx-swift-examples.md`:
> `LoRATrain` (`Libraries/MLXLLM/LoraTrain.swift`) with
> `LoRATrain.Parameters { batchSize = 4, iterations = 1000, stepsPerReport = 10, stepsPerEval = 100,
> validationBatches = 10, saveEvery = 100, adapterURL }`, plus a shipping
> **`LoRATrainingExample`** app target whose iOS deployment target is **17.2**.

⚠️ Two constraints on that path: its data loader accepts **only** `.jsonl` with a `"text"` field or
`.txt` one-sample-per-line (`loadLoRAData`, ✅ same source) — so a `prompt`/`completion` or
`messages` dataset built for Python will not load — and `LoRATrainingExample` sets
`Memory.cacheLimit` to **32 MB** (✅ `notes/repos/mlx-swift-examples.md`), which tells you exactly
how tight the device budget is. Device OOM is also categorically different: iOS **jetsams** the
process. You do not get an exception; the app disappears. Budget for a fraction of physical RAM,
not for "as much as fits". Part 13 covers this properly.

### 8.7 Size the run before you start it

Two minutes of arithmetic beats an hour of failed runs.

```python
# plan_run.py — token statistics for your dataset, using the real tokenizer + template
import json, sys
import numpy as np
from mlx_lm import load

model_path, jsonl = sys.argv[1], sys.argv[2]
_, tokenizer = load(model_path)

lengths = []
for line in open(jsonl):
    rec = json.loads(line)
    if "messages" in rec:
        msgs = rec["messages"]
    elif "prompt" in rec and "completion" in rec:
        msgs = [{"role": "user", "content": rec["prompt"]},
                {"role": "assistant", "content": rec["completion"]}]
    else:                                          # text dataset
        lengths.append(len(tokenizer.encode(rec["text"])) + 1)
        continue
    lengths.append(len(tokenizer.apply_chat_template(msgs, return_dict=False)))

a = np.array(lengths)
for q in (50, 90, 95, 99, 100):
    print(f"p{q:<3d} {int(np.percentile(a, q)):6d} tokens")
print(f"mean {a.mean():.0f}  n={len(a)}")

PAD = 32
for bs in (1, 2, 4, 8):
    p99 = int(np.percentile(a, 99))
    padded = 1 + PAD * ((p99 + PAD - 1) // PAD)
    print(f"batch_size={bs:2d}  padded p99 seq={padded:5d}  "
          f"tokens/step={bs * padded:7d}")
```

Set `--max-seq-length` at or just above **p99**, not at p100 — one 8,000-token outlier should not
size your whole run. Anything above it should be split in `build_dataset.py`, not truncated by the
trainer.

### 8.8 ⚠️ SILENT FAILURE — length-based batching does not work

The trainer intends to sort examples by length so each batch is length-homogeneous and padding
waste is minimal. Follow the call chain:

```python
# trainer.py:110-115  (✅ verbatim)
if isinstance(dataset, CacheDataset):
    len_fn = lambda idx: dataset.itemlen(idx)
else:
    len_fn = lambda idx: len(dataset[idx][0])
idx = sorted(range(len(dataset)), key=len_fn)
```

```python
# datasets.py:160-174  (✅ verbatim)
class CacheDataset:
    def __init__(self, data): self._data = data; self._proc_data = [None] * len(data)
    def itemlen(self, idx): return len(self._data[idx])
    def __getitem__(self, idx):
        if self._proc_data[idx] is None:
            self._proc_data[idx] = self._data.process(self._data[idx])
        return self._proc_data[idx]
```

```python
# datasets.py:131-132 (CompletionsDataset; ChatDataset and TextDataset are identical)  (✅ verbatim)
def __getitem__(self, idx: int):
    return self._data[idx]        # ← the raw JSON dict, straight off the file
```

`lora.py` always wraps the dataset: `train_dataset=CacheDataset(train_set)` (✅ `lora.py:309-310`),
so the `isinstance(dataset, CacheDataset)` branch is the one that runs, always.

Now trace `itemlen(idx)` — `len(self._data[idx])` where `self._data` is the
`CompletionsDataset` / `ChatDataset` / `TextDataset`, whose `__getitem__` returns **the raw record
dict**. `len()` of a dict is **its number of keys**: 2 for `{"prompt", "completion"}`, 1 for
`{"text"}`, 1 or 2 for `messages` ± `tools`.

**So `sorted(...)` is sorting by a value that is constant across the dataset.** Python's sort is
stable, so the "sorted" order is the original file order, unchanged.

**What that costs you.** Batches are formed from contiguous slices of that order, so a batch can
contain a 20-token example and a 2,000-token example. Padding is
`1 + 32·ceil(max_len/32)` **for the whole batch**, so that batch costs 2,017 tokens per row instead
of the ~60 the short rows need. Consequences, in order of how much they hurt:

- **Peak memory is set by your longest example, not your typical one**, and it varies randomly
  between runs because batch order is permuted each epoch (`np.random.permutation(len(batch_idx))`,
  ✅ `trainer.py:141`). This is why a run can survive 400 iterations and then OOM.
- **Throughput is well below what the shape arithmetic predicts**, because most of the padded
  positions are masked out of the loss anyway.
- **`mx.compile` variant count is higher** than it needs to be — §8.6 — because padded lengths are
  drawn from the whole distribution rather than clustering.

🟡 **The consequences above are a reading, not a measurement.** The code chain is ✅ VERIFIED — all
four snippets were read from disk this session and `lora.py:309` confirms `CacheDataset` is always
used. Whether the practical impact is 10% or 3× depends entirely on your length distribution. What
is certain is that the sort does nothing.

> **Safe default — sort your data yourself.** This costs nothing and removes the variable:
> ```bash
> # sort train.jsonl by character length as a proxy for token length, before training
> python - <<'PY'
> import json
> rows = [json.loads(l) for l in open("data/train.jsonl")]
> rows.sort(key=lambda d: len(json.dumps(d, ensure_ascii=False)))
> with open("data/train.jsonl", "w") as f:
>     for r in rows: f.write(json.dumps(r, ensure_ascii=False) + "\n")
> PY
> ```
> With the file pre-sorted, the trainer's stable no-op sort preserves your order, batches become
> length-homogeneous, and peak memory becomes predictable. If you want the exact behaviour the code
> intended, the character-length proxy is close enough; for precision, sort by the token counts that
> `plan_run.py` computes.
>
> **What would resolve this upstream:** `CacheDataset.itemlen` returning `len(self[idx][0])` — the
> processed token list — rather than `len(self._data[idx])`. Check whether your checkout has that
> before assuming this section still applies.

---

## 9. Checkpointing, resuming, and what lands on disk

### 9.1 What gets written, and when

```python
# trainer.py:366-379  (✅ verbatim, complete)
# Save adapter weights
if it % args.steps_per_save == 0 and rank == 0:
    adapter_weights = dict(tree_flatten(model.trainable_parameters()))
    mx.save_safetensors(str(args.adapter_file), adapter_weights)
    checkpoint = Path(args.adapter_file).parent / f"{it:07d}_adapters.safetensors"
    mx.save_safetensors(str(checkpoint), adapter_weights)
    ui.report_save(checkpoint)

# Save final weights
if rank == 0:
    adapter_weights = dict(tree_flatten(model.trainable_parameters()))
    mx.save_safetensors(str(args.adapter_file), adapter_weights)
```

Every `--save-every` iterations you get **two** files: `adapters.safetensors` overwritten in place,
and an immutable `{iters:07d}_adapters.safetensors` snapshot beside it. So after a 600-iteration run
with the default `--save-every 100`:

```
adapters/
├── adapter_config.json          written once, before training starts
├── adapters.safetensors         the LATEST weights (overwritten 7×)
├── 0000100_adapters.safetensors
├── 0000200_adapters.safetensors
├── 0000300_adapters.safetensors
├── 0000400_adapters.safetensors
├── 0000500_adapters.safetensors
└── 0000600_adapters.safetensors
```

Three notes:

- **`adapters.safetensors` is always the *last* checkpoint, never the best.** There is no
  best-checkpoint tracking, no early stopping, and no "restore best at end". If your validation
  loss bottomed at iteration 300 and rose after, the file the rest of the toolchain reads is the
  overfitted one. **Read your validation curve and copy the right numbered snapshot over
  `adapters.safetensors` by hand.**
- **The numbered snapshots are never pruned.** A `full` fine-tune at `--save-every 100` over 1,000
  iterations writes ten multi-gigabyte files.
- **Only rank 0 writes**, in distributed runs.

### 9.2 What the weights contain

`tree_flatten(model.trainable_parameters())` — for LoRA that is `lora_a` / `lora_b` per adapted
module (plus DoRA's `m`, or whole layer tensors for `full`), keyed by their **full module path in
the adapted model**, e.g. `model.layers.20.self_attn.q_proj.lora_a`. Those key names encode:

- the layer indices you adapted (so `--num-layers` must match at load time),
- the module paths you targeted (so `keys` must match),
- and, structurally, whether the modules are `LoRALinear` or `DoRALinear` (so `fine_tune_type` must
  match).

All three of those come from `adapter_config.json`, which is why that file is not optional.

### 9.3 Loading them back, and the `strict=False` at the heart of it

```python
# tuner/utils.py:113-138  (✅ verbatim, complete)
def load_adapters(model: nn.Module, adapter_path: str) -> nn.Module:
    adapter_path = Path(adapter_path)
    if not adapter_path.exists():
        raise FileNotFoundError(f"The adapter path does not exist: {adapter_path}")
    with open(adapter_path / "adapter_config.json", "r") as fid:
        config = types.SimpleNamespace(**json.load(fid))
    fine_tune_type = getattr(config, "fine_tune_type", "lora")
    if fine_tune_type != "full":
        linear_to_lora_layers(model, config.num_layers, config.lora_parameters,
                              use_dora=(fine_tune_type == "dora"))
    model.load_weights(str(adapter_path / "adapters.safetensors"), strict=False)
    return model
```

The rebuild reads `num_layers`, `lora_parameters` and `fine_tune_type` out of the JSON, reconstructs
identically-shaped empty LoRA modules, and then loads the weights **non-strictly**. §15.1 explains
in full why that last word is the most consequential in this file.

`--resume-adapter-file` takes the same shortcut:

```python
# lora.py:255-258  (✅ verbatim)
if args.resume_adapter_file is not None:
    rprint(f"Loading fine-tuned weights from {args.resume_adapter_file}")
    model.load_weights(args.resume_adapter_file, strict=False)
```

⚠️ **Resuming does not restore optimizer state.** Only weights are saved; the Adam moments, the
learning-rate schedule position and the iteration counter all restart. A "resume" is therefore a
fresh run initialised from your adapter, and if you are using a decaying schedule it will restart
at peak LR — which, on a partly-converged adapter, can undo progress. **Safe default:** when
resuming, set `learning_rate` to roughly what the schedule had decayed to, and do not re-warm-up.

### 9.4 What `adapter_config.json` actually contains

```python
# lora.py:268  (✅ verbatim)
save_config(vars(args), adapter_path / "adapter_config.json")
```

`save_config` is the **model** config writer, reused here:

```python
# utils.py:942-965  (✅ verbatim)
def save_config(config: dict, config_path) -> None:
    config.pop("_name_or_path", None)
    config.pop("vision_config", None)
    if "quantization" in config:
        config["quantization_config"] = config["quantization"]
    config = dict(sorted(config.items()))
    with open(config_path, "w") as fid:
        json.dump(config, fid, indent=4)
```

So your adapter config is **every parsed argument**, sorted, with two keys deleted and one mirrored:

- It contains `model`, `data`, `iters`, `batch_size`, `learning_rate`, `optimizer`, `seed`,
  `max_seq_length`, `mask_prompt`, `grad_checkpoint`, `lr_schedule`, … — a full record of the run.
  That is genuinely useful provenance; treat the file as your run log and check it into version
  control.
- It **deletes `vision_config`** if you somehow had one, and **mirrors `quantization` into
  `quantization_config`**. Harmless for adapters, surprising if you are diffing files.
- `vars(args)` includes `config` (the path to your YAML) and `adapter_path` — so the file
  self-describes where it came from.

⚠️ **`lora_parameters` is `None` for `--fine-tune-type full`** (set at `lora.py:243`), and
`load_adapters` never reads it on that path. Consistent, but it means a `full` adapter config is
not interchangeable with a LoRA one even if you edit `fine_tune_type`.

### 9.5 Experiment tracking

```python
# tuner/callbacks.py  (✅ per notes/repos/mlx-lm.md §8.7, cross-checked against trainer.py call sites)
class TrainingCallback:
    def on_train_loss_report(self, train_info: dict): ...
    def on_val_loss_report(self, val_info: dict): ...
```

Payloads, ✅ verbatim from `trainer.py:348-359` and `310-317`:

```python
train_info = {"iteration", "train_loss", "learning_rate", "iterations_per_second",
              "tokens_per_second", "trained_tokens", "peak_memory"}
val_info   = {"iteration", "val_loss", "val_time"}
```

⚠️ **`val_info["iteration"]` is `it - 1`**, while `train_info["iteration"]` is `it`. Off by one
between the two streams. If you plot them on the same axis, they are misaligned by one step. ✅
verified at `trainer.py:314`.

Built-ins are `WandBCallback` and `SwanLabCallback`, registered as
`SUPPORT_CALLBACK = {"wandb": ..., "swanlab": ...}` and composed by
`get_reporting_callbacks(report_to, project_name, log_dir, config)`; comma-separated names are
**nested**, each wrapping the previous. Enable with `--report-to wandb`, `--report-to swanlab`, or
`--report-to wandb,swanlab`, plus `pip install wandb` / `pip install swanlab` (✅ LORA.md §Logging).

And remember §3.7: on the `run()` path your own callback is discarded.

### 9.6 Distributed fine-tuning, in one paragraph

`mlx_lm.lora` is distributed-aware without any flag of its own: `iterate_batches` takes a
`comm_group`, strides the dataset by rank (`idx[i + offset : i + offset + batch_size : step]`), and
`step()` calls `average_gradients(grad)` before the optimizer update (✅ `trainer.py:134-137`,
`254`). Launch it under `mlx.launch`.

> ✅ **VERIFIED** — `notes/CORRECTIONS-PENDING.md` C10.4, from a WWDC26 session:
> `mlx.launch --hostfile <f> -- /remote/path/to/<exe> <args>`; the hostfile is a **JSON array of
> `{ssh, ips[], rdma[]}`** where `rdma` is a positional adjacency matrix with `null` on the
> diagonal; configured via
> `mlx.distributed_config --hosts --output --env MLX_METAL_FAST_SYNCH=1 --auto-setup
> --backend jaccl|jaccl-ring`. **RDMA over Thunderbolt 5 requires macOS 26.2**, a System Settings
> toggle, and a reboot. Mesh beats ring; JACCL routes ring-over-mesh automatically.
> **Apple-published, measured on 4× M3 Ultra: fine-tuning 180 → 600 tok/s on Qwen 3.5 9B.**

⚠️ **`--batch-size` is GLOBAL and must be scaled by N.** ✅ Corroborated by the code:
`batch_arr = np.zeros((batch_size // step, ...))` and
`ValueError("The batch size must be divisible by the number of workers")` (`trainer.py:130-131`,
`161`). Four machines at `--batch-size 4` gives each machine a micro-batch of **one**, not four.
This is easy to get silently wrong — you scale out and your effective batch does not change.

⚠️ Also from the distributed cluster of open issues (`notes/repos/issues-mlx-stack.md` §11): JACCL
`MeshImpl::recv` spins forever on peer loss with **no timeout** (#3910), the ring backend's
`SocketThread` dies silently on transient connection reset leaving all ranks wedged (#3862), and
`MLX_METAL_FAST_SYNCH=1` can deadlock on a Metal fence handoff (#3830). PR #3933 "Fix crashes in
the ring and jaccl distributed backends" was open at research time. Multi-machine training on this
stack is not yet boring.

---

## 10. Evaluating the result

Do all four of these. Each catches something the others miss.

### 10.1 Test-set perplexity — the cheapest signal

```bash
mlx_lm.lora \
    --model ./qwen3-4b-4bit \
    --adapter-path ./adapters \
    --data ./data \
    --test
```

```python
# lora.py:315-334  (✅ verbatim)
def evaluate_model(args, model, test_set):
    n_batches = len(test_set) // args.batch_size
    if args.test_batches != -1:
        n_batches = min(n_batches, args.test_batches)
    ...
    test_loss = evaluate(model=model, dataset=CacheDataset(test_set),
                         batch_size=args.batch_size, num_batches=args.test_batches,
                         max_seq_length=args.max_seq_length, progress_callback=...)
    test_ppl = math.exp(test_loss)
    rprint(f"Test loss {test_loss:.3f}, Test ppl {test_ppl:.3f}.")
```

Run it **twice** — once with `--adapter-path` and once without — and compare. Without adapters, the
CLI still needs a value: *"Allow testing without LoRA layers by providing empty path"*
(`lora.py:356-359`, ✅ verbatim), so pass `--adapter-path ""`.

```bash
mlx_lm.lora --model ./qwen3-4b-4bit --adapter-path "" --data ./data --test   # baseline
mlx_lm.lora --model ./qwen3-4b-4bit --adapter-path ./adapters --data ./data --test   # tuned
```

⚠️ Three ways this comparison lies. **(1)** Perplexity on a *tuned* distribution always improves;
it measures fit, not usefulness. **(2)** With `--mask-prompt`, the loss is normalised over a
different token count than without, so a masked-trained adapter's test loss is not comparable to an
unmasked baseline unless you evaluate both the same way. **(3)** `evaluate()` calls `model.eval()`,
so dropout is off — as it should be, but it means your training curve and this number are on
different footings.

### 10.2 Perplexity on held-out general text — the forgetting check

Perplexity on your task going down while perplexity on general text goes *up* is catastrophic
forgetting, and it is the most common way a fine-tune that "works" ships a worse product.

```bash
mlx_lm.perplexity --model ./qwen3-4b-4bit --num-samples 512 --sequence-length 1024
# then the same against the FUSED model (mlx_lm.perplexity takes no --adapter-path)
mlx_lm.perplexity --model ./fused_model --num-samples 512 --sequence-length 1024
```

Flags (✅ `notes/repos/mlx-lm.md` §2.9): `--model` (required), `--batch-size` (8),
`--sequence-length` (512), `--num-samples` (256, `-1` = all), `--data-path`
(`allenai/tulu-3-sft-mixture`), `--seed` (123). Output is
`Perplexity: {ppl:.3f} ± {se:.3f}`, where the standard error is a delta approximation
`ppl * (std / sqrt(n_tokens))`.

⚠️ `mlx_lm.perplexity` has **no `--adapter-path`**. To measure a LoRA adapter this way you must fuse
first (§11) — which is one of the few genuine reasons to fuse before you are otherwise ready.

**Read the ± band.** A change smaller than the sum of the two standard errors is not a change.

### 10.3 Benchmarks — the capability check

```bash
mlx_lm.evaluate --model ./fused_model \
  --tasks winogrande boolq arc_challenge arc_easy hellaswag openbookqa piqa social_iqa \
  --batch-size 16 --limit 200
```

`mlx_lm.evaluate` bridges to `lm-evaluation-harness` by registering
`@register_model("mlxlm") class MLXLM(LM)` implementing `loglikelihood`, `loglikelihood_rolling`
and `generate_until` (✅ `notes/repos/mlx-lm.md` §2.8). Flags include `--num-shots`, `--limit`,
`--apply-chat-template` (a `BooleanOptionalAction`, so `--no-apply-chat-template` works),
`--chat-template-args`, `--fewshot-as-multiturn`, `--temp`/`--top-p`/`--top-k`. Needs
`pip install "mlx-lm[evaluate]"`.

⚠️ Two caveats. **`--limit 200` on eight tasks is a smoke test, not a benchmark** — use it to check
for a *collapse*, not to publish a number. And `notes/repos/mlx-lm.md` §15 flags a latent
`NameError` in `evaluate.py::loglikelihood`: the `prefix_l == 0` branch calls
`all_scores.extend(...)` / `all_is_greedy.extend(...)` where the locals are `scores` / `is_greedy`.
It triggers only when a completion exceeds the context budget. If you hit an unexplained
`NameError` deep in evaluation, that is it, and it is a bug, not your data.

For calibration, mlx-lm's own published table:

> ✅ `mlx_lm/BENCHMARKS.md`, **project-published, measured on a 64 GB M4 Max, mlx 0.29.2.dev,
> mlx-lm 0.28.2, macOS 26.1.** Qwen3-4B-Instruct-2507: **bf16** MMLU-Pro **64.05** @ 52.47 gen tok/s
> / 9.02 GB; **q4** MMLU-Pro **60.72** @ 134.52 tok/s / 3.35 GB. Not an Apple figure; the versions
> are older than this guide's floor.

That q4 row is the number to hold onto when reading §5.3: 4-bit costs a few points of MMLU-Pro on
this model, *before* your adapter does anything. If your fine-tune's evaluation is 3 points below
a bf16 reference, quantization may be the whole story.

### 10.4 Generation A/B — the check that actually decides

Perplexity cannot tell you whether the model learned your output format. Generate.

```bash
# base
mlx_lm.generate --model ./qwen3-4b-4bit \
  --prompt "Summarise this ticket as JSON with keys severity, component, summary: ..." \
  --temp 0.0 -m 256

# adapted — same prompt, same seed, same sampler
mlx_lm.generate --model ./qwen3-4b-4bit --adapter-path ./adapters \
  --prompt "Summarise this ticket as JSON with keys severity, component, summary: ..." \
  --temp 0.0 -m 256
```

`--adapter-path` is a first-class flag on `mlx_lm.generate` and `mlx_lm.chat` (✅
`notes/repos/mlx-lm.md` §2.1, §2.2). `--temp 0.0` short-circuits the sampler to `mx.argmax`
(✅ `sample_utils.py`), which is what you want for an A/B.

A harness for a whole prompt set:

```python
# ab_eval.py — base vs adapted, same prompts, greedy, plus a format check
import json, sys
from mlx_lm import load, generate
from mlx_lm.tuner.utils import load_adapters

MODEL, ADAPTERS, PROMPTS = sys.argv[1], sys.argv[2], sys.argv[3]
prompts = [json.loads(l)["prompt"] for l in open(PROMPTS)]

def run(adapter_path):
    model, tokenizer = load(MODEL)
    if adapter_path:
        load_adapters(model, adapter_path)
    outs = []
    for p in prompts:
        text = tokenizer.apply_chat_template(
            [{"role": "user", "content": p}], add_generation_prompt=True)
        outs.append(generate(model, tokenizer, prompt=text, max_tokens=256, verbose=False))
    return outs

base = run(None)
tuned = run(ADAPTERS)

def parses(s):
    try:
        json.loads(s.strip()); return True
    except Exception:
        return False

identical = sum(b == t for b, t in zip(base, tuned))
print(f"identical outputs : {identical}/{len(prompts)}")
print(f"base  valid JSON  : {sum(map(parses, base))}/{len(prompts)}")
print(f"tuned valid JSON  : {sum(map(parses, tuned))}/{len(prompts)}")
for i, (b, t) in enumerate(zip(base, tuned)):
    if b != t:
        print(f"\n--- prompt {i} ---\nBASE : {b[:200]}\nTUNED: {t[:200]}")
        break
```

> ⚠️ **`identical outputs: N/N` is the alarm bell for §15.1.** If every greedy output is
> byte-identical to the base model's, your adapter is not loaded. That is not "the fine-tune was
> too subtle" — LoRA's `lora_b` starts at exactly zero, so an unloaded adapter is a mathematical
> no-op and produces *exactly* the base model. Any adapter that trained for even fifty steps
> perturbs greedy decoding somewhere. Run §15.1's diagnostic before you conclude anything else.

⚠️ Two `generate()` quirks worth knowing before you write your own harness (✅
`notes/repos/mlx-lm.md` §15): `generate()` returns **`None`, not `""`**, when the model emits no
text; and `stream_generate(..., max_tokens=0)` raises `UnboundLocalError`.

### 10.5 Which numbers you are allowed to report

Every fine-tuning number you publish needs: **model + quantization**, **adapter type/rank/target
keys**, **dataset and its size**, **mlx and mlx-lm commit hashes**, **hardware**, **macOS build**,
and **date**. Without the commits it is not reproducible, because — as §1.2 says — PyPI's mlx-lm is
months behind `main` and behaves differently.

---

## 11. `mlx_lm.fuse`, and what it costs you

### 11.1 What it does

```python
# mlx_lm/fuse.py:65-99  (✅ verbatim, the whole substantive body)
model, tokenizer, config = load(args.model, adapter_path=args.adapter_path,
                                return_config=True, trust_remote_code=args.trust_remote_code)

fused_linears = [(n, m.fuse(dequantize=args.dequantize))
                 for n, m in model.named_modules() if hasattr(m, "fuse")]
if fused_linears:
    model.update_modules(tree_unflatten(fused_linears))

if args.dequantize:
    print("Dequantizing model")
    model = dequantize_model(model)
    config.pop("quantization", None)
    config.pop("quantization_config", None)

save_path = Path(args.save_path)
save(save_path, args.model, model, tokenizer, config, donate_model=False)
```

The fusion itself is one line of arithmetic per module:

```python
# tuner/lora.py:34-65  (✅ verbatim)
def fuse(self, dequantize: bool = False):
    linear = self.linear
    bias = "bias" in linear
    weight = linear.weight
    is_quantized = isinstance(linear, nn.QuantizedLinear)
    if is_quantized:
        weight = mx.dequantize(weight, linear.scales, linear.biases,
                               group_size=linear.group_size, bits=linear.bits, mode=linear.mode)
    output_dims, input_dims = weight.shape
    fused_linear = nn.Linear(input_dims, output_dims, bias=bias)
    delta = ((self.scale * self.lora_b.T) @ self.lora_a.T).astype(weight.dtype)
    fused_linear.weight = weight + delta
    if bias:
        fused_linear.bias = linear.bias
    if is_quantized and not dequantize:
        fused_linear = nn.QuantizedLinear.from_linear(fused_linear, linear.group_size,
                                                      linear.bits, mode=linear.mode)
    return fused_linear
```

`W' = W + scale · (Bᵀ Aᵀ)`, then **re-quantized at the original `group_size`, `bits` and `mode`**
unless you pass `--dequantize`. DoRA's `fuse` additionally folds the magnitude:
`norm_scale = self.m / mx.linalg.norm(weight, axis=1); fused.weight = norm_scale[:, None] * weight`
(✅ `tuner/dora.py:32-56`).

Note the duck-typing: `if hasattr(m, "fuse")`. Anything exposing a `fuse` participates —
`LoRALinear`, `LoRASwitchLinear`, `LoRAEmbedding`, `DoRALinear`, `DoRAEmbedding`, and AFM 7's
`FusedLoRALinear`. Anything not exposing it (a plain `nn.Linear` from `--fine-tune-type
full`) does not, which is why fusing a full fine-tune is a no-op (§4.3).

### 11.2 The flags

```
--model         (default: mlx_model)
--save-path     (default: fused_model)
--adapter-path  (default: adapters)
--upload-repo   (default: None)
--dequantize
--export-gguf
--gguf-path     (default: ggml-model-f16.gguf)
--trust-remote-code
```

> ⚠️ ✅ **VERIFIED DOC BUG — `mlx_lm.fuse` has no `--hf-path`.** `LORA.md` instructs:
> *"To upload a fused model, supply the `--upload-repo` and `--hf-path` arguments to
> `mlx_lm.fuse`. The latter is the repo name of the original model…"* and gives a worked example
> using it. `parse_arguments()` in `fuse.py:15-62` — read in full this session — declares exactly
> the eight flags above and **no `--hf-path`**. The documented command fails with
> `error: unrecognized arguments: --hf-path`. The LORA.md model-family list ("Mistral, Llama, Phi2,
> Mixtral, Qwen2, Gemma, OLMo, MiniCPM, InternLM2") is stale in the other direction:
> `linear_to_lora_layers` is generic and works with any model whose layers contain the module types
> in §6.1.

### 11.3 What fusing costs you

**You lose the ability to swap adapters.** That is the headline and it is not recoverable — the
delta is added into the weight and, on a quantized base, immediately re-quantized, which is lossy
and not invertible. There is no "unfuse".

Concretely, what you give up:

| Capability | Adapter directory | Fused model |
|---|---|---|
| Multiple adapters over one base on disk | ✅ N × ~20 MB + one base | ❌ N full copies of the model |
| Swap at runtime (Swift: `load(adapter:)` / `unload(adapter:)`) | ✅ | ❌ |
| A/B the base against the adapted model | ✅ one process, `--adapter-path ""` | ❌ two models |
| Ship an adapter update as a small download | ✅ tens of MB | ❌ gigabytes |
| Continue training (`--resume-adapter-file`) | ✅ | ❌ |
| `mlx_lm.perplexity` | ❌ (no `--adapter-path`) | ✅ |
| `mlx_lm.evaluate` | ❌ | ✅ |
| GGUF export | ❌ | ✅ (3 architectures) |
| Conversion to Core AI (Part 14) | ❌ | ✅ |
| Inference speed | a second matmul per adapted module | one matmul |

**When to fuse anyway:**

- You are shipping exactly one variant and never swapping.
- You need `mlx_lm.perplexity` or `mlx_lm.evaluate`, which have no adapter path.
- You are handing the model to a converter — Core AI (Part 14), GGUF, ONNX — that has no concept of
  adapters.
- You measured the adapter overhead and it matters. On a memory-bandwidth-bound decode the extra
  rank-*r* matmuls are usually noise, but "usually" is not "measured".

**When not to:**

- Multi-tenant or per-customer adaptation. Keep the base shared.
- You are still iterating. Fusing is a publishing step, not a development step.
- You want to ship adapter updates through Background Assets without re-downloading a model.

> **Safe default: keep the adapter directory as your source of truth, and treat `fused_model/` as a
> build artefact you can regenerate.** Check `adapter_config.json` and `adapters.safetensors` into
> storage you trust; regenerate the fused model from them.

### 11.4 `--dequantize`, and the round-trip you should think about

Fusing onto a quantized base does `dequantize → add delta → re-quantize`. The re-quantization is a
**second** lossy pass over weights that were already quantized once, now perturbed. Whether that
compounds meaningfully is exactly what §10.2's perplexity comparison is for — measure the fused
model against the adapter-loaded model, on the same data, and check whether the difference exceeds
the ± band.

`--dequantize` skips the re-quantization and writes a full-precision model, dropping `quantization`
and `quantization_config` from the config. That gives you a clean bf16/fp16 artefact — the right
input for a converter, and the right thing to keep if you plan to re-quantize with a *better*
method later (AWQ, DWQ, GPTQ; this part's quantization guide). It is also 4× the disk.

**The recommended publishing chain when quality matters:**

```bash
mlx_lm.fuse --model ./qwen3-4b-4bit --adapter-path ./adapters \
            --save-path ./fused-bf16 --dequantize        # 1. clean full-precision merge
mlx_lm.dwq  --model ./fused-bf16 --mlx-path ./ship-4bit --bits 4 --group-size 64
                                                        # 2. learned re-quantization
mlx_lm.perplexity --model ./ship-4bit                   # 3. verify
```

### 11.5 GGUF export

```python
# fuse.py:101-108  (✅ verbatim)
if args.export_gguf:
    model_type = config["model_type"]
    if model_type not in ["llama", "mixtral", "mistral"]:
        raise ValueError(f"Model type {model_type} not supported for GGUF conversion.")
```

**Three architectures, fp16 only.** `mlx_lm/gguf.py` provides `convert_to_gguf(model_path, weights,
config, output_file_path)` plus `translate_weight_names`, `permute_weights(weights, n_head,
n_head_kv=None)` and `prepare_metadata` (✅ `notes/repos/mlx-lm.md` §12). Anything else — Qwen,
Gemma, Phi, an MoE, your new port — raises. Do not plan a llama.cpp handoff around this without
checking your `model_type` first.

### 11.6 Uploading

```bash
mlx_lm.fuse --model ./qwen3-4b-4bit --adapter-path ./adapters \
            --save-path ./fused_model --upload-repo mlx-community/my-domain-qwen3-4b
```

`upload_to_hub` uses `HfApi().upload_large_folder(...)`, sets `library_name="mlx"`,
`pipeline_tag="text-generation"`, tags the repo `mlx`, and writes a model card containing a
ready-to-run snippet plus the provenance line *"…was converted to MLX format from … using mlx-lm
version {\_\_version\_\_}."* (✅ `notes/repos/mlx-lm.md` §12). Shards are
`model-{i:05d}-of-{n:05d}.safetensors`, capped at 5 GB, with an index carrying `total_size` and
`total_parameters`.

⚠️ **Publish the adapter too, not only the fused model.** It is two orders of magnitude smaller,
it is what anyone reproducing your work needs, and — per §0.2 — it is directly consumable from
Swift. The fused model is a convenience; the adapter is the artefact.

---

## 12. The complete worked run

End to end, with the checks in the right places. Substitute your own model and data; the shape is
the point.

### Step 0 — pin everything

```bash
python3 -m venv .venv && source .venv/bin/activate
git clone https://github.com/ml-explore/mlx-lm && cd mlx-lm
git rev-parse HEAD | tee ../RUN-mlx-lm-commit.txt      # record it
pip install -e ".[train]" rich regex
cd ..

python - <<'PY' | tee RUN-env.txt
import platform, mlx.core as mx, mlx_lm, transformers, sys
print("python      ", sys.version.split()[0], platform.processor())
print("macOS       ", platform.mac_ver()[0])
print("mlx         ", mx.__version__)
print("mlx-lm      ", mlx_lm.__version__)
print("transformers", transformers.__version__)
print("metal       ", mx.metal.is_available())
print("resource_lim", mx.device_info().get("resource_limit"))
PY
```

### Step 1 — build the data, and look at it

```bash
python build_dataset.py raw.jsonl ./data --valid-frac 0.1 --test-frac 0.1
python plan_run.py Qwen/Qwen3-4B-Instruct ./data/train.jsonl
```

Read the percentile table. Pick `max_seq_length` at p99, rounded up to a multiple of 32 plus one.
Then pre-sort, per §8.8:

```bash
python - <<'PY'
import json
for name in ("train", "valid", "test"):
    p = f"data/{name}.jsonl"
    rows = [json.loads(l) for l in open(p)]
    rows.sort(key=lambda d: len(json.dumps(d, ensure_ascii=False)))
    with open(p, "w") as f:
        for r in rows: f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(name, len(rows))
PY
```

### Step 2 — convert and pin the base

```bash
mlx_lm.convert --model Qwen/Qwen3-4B-Instruct --mlx-path ./base-4bit -q
shasum -a 256 base-4bit/tokenizer_config.json base-4bit/config.json | tee RUN-base-hashes.txt
```

Everything downstream points at `./base-4bit`, never at the HF repo id. That pins the tokenizer and
chat template (§2.5) and gives you the fast streaming detokenizer.

### Step 3 — check the template before you spend an hour

```bash
python check_template.py ./base-4bit ./data/train.jsonl
```

`prefix match: True`. If not, stop and fix the data.

### Step 4 — write the config

```yaml
# lora.yaml
model: "./base-4bit"
train: true
fine_tune_type: lora
optimizer: adamw
optimizer_config:
  adamw:
    betas: [0.9, 0.98]
    eps: 1e-6
    weight_decay: 0.05
    bias_correction: true

data: "./data"
seed: 0

num_layers: 16
batch_size: 1
grad_accumulation_steps: 8        # effective batch 8; --iters counts MICRO-steps
iters: 4800                       # = 600 optimizer updates
max_seq_length: 1024              # from plan_run.py's p99
grad_checkpoint: true

val_batches: 25
steps_per_report: 10
steps_per_eval: 200
save_every: 400
adapter_path: "adapters"
mask_prompt: true

lr_schedule:
  name: cosine_decay
  warmup: 400                     # micro-steps
  warmup_init: 1e-7
  arguments: [1e-4, 4800, 1e-6]   # decay_steps must equal iters

lora_parameters:
  keys: ["self_attn.q_proj", "self_attn.k_proj", "self_attn.v_proj", "self_attn.o_proj"]
  rank: 16
  scale: 20.0
  dropout: 0.05
```

### Step 5 — a 50-iteration smoke test

```bash
mlx_lm.lora -c lora.yaml --iters 50 --adapter-path ./adapters-smoke 2>&1 | tee RUN-smoke.log
```

Check three things in the output, in this order:

1. `Trainable parameters: X% (Y M/Z M)` — does `Y` match the §6.2 arithmetic? If it is far lower,
   your `keys` are wrong.
2. Loss over 50 steps — falling, flat, or `nan`? Adjust the LR per §7.1 and repeat.
3. `peak_memory` in the report — and independently, the honest number from §8.5. If you are within
   a few GB of the machine, cut `batch_size` or `max_seq_length` now, not at iteration 3,000.

### Step 6 — the real run

```bash
mlx_lm.lora -c lora.yaml 2>&1 | tee RUN-train.log
```

Watch the validation line every 200 steps. When `val_loss` turns up and stays up, the run is done
regardless of `iters` — note the iteration.

### Step 7 — pick the right checkpoint

```bash
ls -la adapters/
grep -E "val" RUN-train.log
# suppose validation bottomed at 3200:
cp adapters/0003200_adapters.safetensors adapters/adapters.safetensors
```

This step is manual because mlx-lm has no best-checkpoint tracking (§9.1). Skipping it is how a
run "works" and ships the overfitted weights.

### Step 8 — evaluate, four ways

```bash
# 8a. test perplexity, baseline vs adapted
mlx_lm.lora --model ./base-4bit --adapter-path ""         --data ./data --test
mlx_lm.lora --model ./base-4bit --adapter-path ./adapters --data ./data --test

# 8b. generation A/B — and the §15.1 alarm bell
python ab_eval.py ./base-4bit ./adapters ./data/test.jsonl

# 8c. eyeball the chat behaviour
mlx_lm.chat --model ./base-4bit --adapter-path ./adapters
```

```bash
# 8d. after fusing: forgetting + capability
mlx_lm.fuse --model ./base-4bit --adapter-path ./adapters --save-path ./fused-4bit
mlx_lm.perplexity --model ./base-4bit  --num-samples 512 --sequence-length 1024
mlx_lm.perplexity --model ./fused-4bit --num-samples 512 --sequence-length 1024
mlx_lm.evaluate   --model ./fused-4bit --tasks arc_easy hellaswag piqa --limit 400
```

Gate: task perplexity down, general perplexity within the ± band, benchmark scores not collapsed.

### Step 9 — fuse for publication

```bash
# clean merge, then a learned re-quantization (§11.4)
mlx_lm.fuse --model ./base-4bit --adapter-path ./adapters \
            --save-path ./fused-bf16 --dequantize
mlx_lm.dwq  --model ./fused-bf16 --mlx-path ./ship-4bit --bits 4 --group-size 64 \
            --batch-size 1 --max-seq-length 512
mlx_lm.perplexity --model ./ship-4bit --num-samples 512 --sequence-length 1024
```

### Step 10 — serve, and hand off

```bash
# local OpenAI-compatible endpoint
mlx_lm.server --model ./ship-4bit --port 8080 \
              --prompt-cache-size 20 --prompt-cache-bytes 8GB

curl localhost:8080/v1/chat/completions -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Summarise this ticket as JSON: ..."}],
       "temperature":0.0}'
```

You can also serve the **unfused** model with the adapter, which is the better shape while you are
still iterating:

```bash
mlx_lm.server --model ./base-4bit --adapter-path ./adapters --port 8080
```

⚠️ From `mlx_lm.server`'s own startup message: *"mlx_lm.server is not recommended for production as
it only implements basic security checks."* (✅ `notes/repos/mlx-lm.md` §2.6.) Also, adapters are
**rejected in distributed mode** — `ModelProvider` refuses them, and `mlx_lm.chat` errors with
`"Adapters not supported in distributed mode"`.

**Then the handoff:**

- **To Swift on device** — ship `./base-4bit` plus the `adapters/` directory and load with
  `LoRAContainer.from(directory:)`, or ship `./ship-4bit` fused. [Part 13](../../part-13-mlx-swift/README.md).
- **To Core AI** — `./fused-bf16` is the input a converter wants.
  [Part 14](../../part-14-bridges-between-stacks/README.md).
- **Behind a `LanguageModelSession`** — point `ChatCompletionsLanguageModel` at
  `http://localhost:8080/v1`. [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md), and note C4:
  guided generation needs logits, which not every backend exposes.

---

## 13. Beyond `mlx_lm.lora`: the third-party training layer

Everything above is `mlx_lm`, read from source. This section is different in kind and is marked
accordingly.

> ⚠️ **Evidence tier for this whole section: 🟡 project READMEs, not source reads, not runs.**
> Nothing here was cloned, executed or measured by this project. It exists because the scope note
> at the top of this guide — *"there is no preference-optimization command in this package"* — is
> true of `mlx_lm` and false of the ecosystem, and a reader who stops at the scope note will
> conclude that DPO and GRPO are simply unavailable on Apple silicon. They are not. **Treat every
> flag name below as a pointer to check, not as an attested spelling.** Harvest notes:
> `notes/web/2026-08-02-harvest/mlx-training-and-ecosystem.md`.

### 13.1 Why this matters for the boundary this guide draws

`mlx_lm.lora` gives you **SFT** in three flavours (LoRA / DoRA / `full`), with QLoRA arriving
automatically when the base is quantized (§5). That is the whole of Apple's first-party training
surface in this package. Post-training alignment — preference optimisation, reward models,
group-relative RL — has **no first-party MLX command at all**.

The gap is filled by projects that import `mlx_lm` and add trainers on top. Two are worth naming.

### 13.2 `mlx-lm-lora` — the training superset

`https://github.com/Goekdeniz-Guelmez/mlx-lm-lora` · `pip install -U mlx-lm-lora`

Claims **12 training algorithms**, grouped by what they need:

| Family | Methods | Needs |
|---|---|---|
| Supervised | SFT | prompt/completion or chat data |
| Offline preference | DPO, CPO, ORPO | `{prompt, chosen, rejected}` triples |
| Group-relative RL | GRPO, GSPO, Dr. GRPO, DAPO | a prompt set + reward functions |
| Online / judge-in-loop | Online DPO, XPO, RLHF Reinforce, PPO | a judge or reward model |

The entry point mirrors `mlx_lm.lora` closely enough to be legible from §3:

```bash
# 🟡 UNVERIFIED — README grammar, not run by this project.
mlx_lm_lora.train --model <model_path> --data <data_path> --train \
  --train-type lora --train-mode dpo --beta 0.1
```

`--train-type {lora,dora,full}` is the axis this guide's §4 covers; `--train-mode` is the new one.
The memory and optimisation flags are recognisably the same family (`--grad-checkpoint`,
`--gradient-accumulation-steps`, `--num-layers`, `--lora-parameters '{"rank": …}'`), which is what
you would expect from a layer built on mlx-lm's trainer.

Two things in it have no counterpart anywhere else in this part:

- **QAT (quantization-aware training)** — `--qat-enable`, `--qat-bits` (default 8),
  `--qat-group-size` (default 64, `0` = per-tensor), `--qat-mode` (default `affine`),
  `--qat-start-step`, `--qat-interval`. Described as projecting weights onto quantized grids
  *during* training, and offered for SFT, DPO and ORPO. This part's quantization guide covers
  **post-training** quantization thoroughly; QAT is the missing sibling, and this is the only MLX
  implementation of it the 2026-08-02 sweep found.
- **Custom reward functions**, registered in Python and selected by name — the piece GRPO needs:

  ```python
  # 🟡 UNVERIFIED — README example.
  from mlx_lm_lora.reward_functions import register_reward_function

  @register_reward_function()
  def my_reward(prompt, completion, reference_answer, **kwargs):
      return score  # float 0-1
  ```

  invoked as `--reward-functions-file ./my_rewards.py --reward-functions "my_reward"`.

There is also a separate judge-training entry point
(`python -m mlx_lm_lora.train_judge --model <model> --train-type full --data <data>`), which is the
local, MLX-native counterpart to the model-judge material in
[Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/references/02-model-judges-and-alignment.md). If you are
calibrating a judge there, this is where you would train one here.

> 🚩 **About its benchmark table — read the batch size before you read the numbers.** The project
> publishes a comparison against Unsloth on an A100 and against `mlx-tune`, at **batch size 1,
> context 4096, 100 steps**, and reports (for example) Qwen3-8B SFT 4-bit at ~4.1 it/s on an
> M4 Pro versus ~1.3 it/s for Unsloth on an A100.
>
> **Batch size 1 is the configuration that most disadvantages a datacentre GPU**, so this is a
> latency result, not a throughput result, and it does not tell you what an A100 does at the batch
> sizes anyone would actually run. Do not cite it as "Apple silicon beats an A100". The
> **memory-envelope** half of the same table is the defensible half, and the structural claim under
> it — unified memory up to 512 GB on an Ultra versus 24–80 GB of VRAM — does not depend on the
> benchmark at all. See [Part 15](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md)
> for why this shape of comparison is the one to distrust.

Its stated memory guidance, which is at least internally consistent with §8's arithmetic:
1–3B → `--batch-size 4 --num-layers 16`; 7B → `--batch-size 2 --num-layers 8 --load-in-8bits`;
13B+ → `--batch-size 1 --num-layers 4 --load-in-4bits --grad-checkpoint`.

### 13.3 `mlx-tune` — the Unsloth-source-compatible path

`https://github.com/ARahim3/mlx-tune`. Methods: SFT, DPO, ORPO, GRPO, **KTO**, **SimPO**, plus
dedicated trainers for **vision, TTS, STT, embeddings and OCR** — note that last group, since
`mlx_lm` is text-only by construction (§"What this does not cover"). Requirements as stated:
Apple silicon M1–M5, macOS 13.0+, 8 GB+ unified RAM (16 GB+ recommended), Python 3.9+,
**MLX 0.20+**.

Its distinguishing claim is a **"100% compatible" Unsloth API** — `FastLanguageModel` and
`SFTTrainer` — so that "training scripts written once work identically whether training on Mac or
CUDA GPUs".

> **If that claim holds, it is the most interesting thing in this section**, because it makes the
> Mac a drop-in target for an existing CUDA training script rather than a port. That is a
> cross-stack bridge in the sense [Part 14](../../part-14-bridges-between-stacks/README.md) uses the word,
> and it points the opposite way from the rest of that part (which moves *models* between stacks,
> not *training code*).
>
> 🔴 **GAP — the compatibility claim is unverified.** "100% compatible" is the project's own
> wording; no source in this corpus tests it, and API-compatibility claims of this shape usually
> hold for the documented happy path and not for callbacks, custom collators, or anything touching
> device placement. **Before you plan a migration around it, port one real script and diff the
> results.**

### 13.4 The rest of the ecosystem, as a pointer list

`awesome-mlx` (`https://github.com/raullenchai/awesome-mlx`) indexes ~140 projects. The ones
adjacent to this guide, so you can name an existing implementation instead of building one:

- **Training:** `MLX-GRPO` (pure-MLX GRPO pipeline), `SiLLM`, `TransformerLab` (training +
  evaluation environment), `rlx`, `mlx-lm-gui` and `MLX-LoRA-Studio` (native macOS fine-tuning
  GUIs), `nanoGPT_mlx`, `mlx-gpt2` (both educational).
- **Guided generation in the MLX world**, which Part 13.3 currently reasons about from first
  principles: `outlinesmlx`, `Toolio` (JSON-schema steering plus tool calling),
  `mlx-swift-structured`.
- **Benchmarking:** `mlx-benchmark` (MLX ops vs MPS vs CUDA) — a candidate cross-check for
  Part 15's numbers.
- **Speech**, adjacent to [Part 16.1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md):
  `speech-swift` (ASR/TTS/VAD/diarization over MLX **and** Core ML), `mlx-audio`, `parakeet-mlx`,
  `lightning-whisper-mlx`.

> **How to use this list:** as a search index, not as a recommendation. None of these projects has
> been read or run by this project, none carries Apple's support, and the churn rate in this corner
> of the ecosystem is high. The value is that "does this exist for MLX?" now has a place to look.

[^scope-source]: Source snapshot: [`ml-explore/mlx-lm` at `e5baded`](https://github.com/ml-explore/mlx-lm/tree/e5baded8c1d286754edb479ffbde4655a68e2758).
[^trust-source]: The pinned [`lora.py` parser](https://github.com/ml-explore/mlx-lm/blob/e5baded8c1d286754edb479ffbde4655a68e2758/mlx_lm/lora.py#L210-L221)
    defines the flag, and [`utils.py`](https://github.com/ml-explore/mlx-lm/blob/e5baded8c1d286754edb479ffbde4655a68e2758/mlx_lm/utils.py#L301-L355)
    gates custom architecture loading behind `trust_remote_code`.

---
