# mlx-lm: the CLI surface, the generation API, and KV caching

**Part 12 · MLX in Python · Reference 04**

**Version floor: mlx-lm `0.31.3` on PyPI, plus main at commit `e5baded` (2026-07-26).** mlx-lm is a
Python package, not an OS framework, so its version axis is the *package* version, not an iOS or
macOS release — nothing in this guide is gated on iOS 27 or macOS 27. Where an OS floor does bite,
it is called out inline: **memory wiring requires macOS 15 or later**, and **Thunderbolt RDMA for
distributed runs requires macOS 26.2**. The package's own declared floors, read from `setup.py`
this session: **`mlx >= 0.31.2`** (pinned only on Darwin), **`transformers >= 5.7.0`**,
`numpy`, `sentencepiece`, `protobuf`, `pyyaml`, `jinja2`. The declared `python_requires=">=3.8"`
is **stale** — the shipped source uses PEP-604 `X | None` unions and `list[tuple[str, str]]`
annotations, so **Python 3.10 is the real floor**.

⚠️ **The single most important version fact in this guide:** mlx-lm **0.31.0 was pulled from
practical use for a `BatchKVCache` cross-contamination bug**, 0.31.3 (2026-04-22) is the newest
PyPI release, and **`main` has moved substantially past it** — PRs merged through late July 2026
that this guide describes are *not* in any release you can `pip install` today. Every claim below
is tagged with which of the two it came from.

---

## What this covers

mlx-lm is the layer where MLX stops being an array framework and starts being an LLM runtime. WWDC26
session 232 describes it as the thing that *"provides everything you need to load, run, quantize,
and fine-tune large language models… and gives you both CLI tools and a Python API."* That is
accurate but undersells it: mlx-lm ships **18 command-line entry points**, a generation API with
five public functions, and a **cache module with nine concrete KV-cache classes** whose differences
decide whether your workload is fast, correct, or silently broken.

This guide covers three things in depth and two in passing:

- **§2 — The CLI surface.** All 18 entry points enumerated from `setup.py`'s `console_scripts`,
  with the flags that matter and real invocations. Not placeholders: commands you can paste.
- **§3 — The Python generation API.** `load`, `generate`, `stream_generate`, and the
  `generate_step` generator underneath them; how samplers and logits processors compose, in what
  order, and where the defaults disagree with each other. One complete, runnable script.
- **§4–§6 — KV caching, the deepest section.** The nine concrete cache classes and what each one
  is for; the trimmability contract that everything else depends on; prompt caching to disk and why
  it changes the economics of long shared prefixes; quantized KV and the counter-intuitive fact
  that it can *increase* peak memory.
- **§7 — Speculative decoding.** How to run it, what makes a good draft model, and the
  acceptance-rate arithmetic that decides whether it helps at all.
- **§8 — Batch generation.** `batch_generate`, `BatchGenerator`, and how continuous batching
  interacts with — and constrains — every cache decision from §4.

## What this does *not* cover

- **Quantization: `convert`, AWQ, DWQ, GPTQ, dynamic quant.** §2 lists the commands and their
  headline flags so you can find them; the algorithms, the bit-width tradeoffs and the recipes are
  [Part 12 guide 03](03-quantization.md).
- **Fine-tuning: `mlx_lm.lora`, `mlx_lm.fuse`, datasets, adapters.** Same treatment — enumerated
  here, taught in [Part 12 guide 06](06-finetuning-and-porting-models.md).
- **Putting `mlx_lm.server` behind `LanguageModelSession`.** The server is described here as a CLI
  entry point and as a consumer of the prompt cache; wiring it to Foundation Models via
  `ChatCompletionsLanguageModel` is [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md).
- **Distributed inference.** `mlx.launch`, hostfiles and RDMA are their own guide in this part.
- **MLX Swift.** [Part 13](../../part-13-mlx-swift/README.md) — and note that the Swift port has
  *different* cache bugs, several of which are worse (§9.6).

## What you need

- **Apple silicon and macOS 15 or later** if you want memory wiring to work at all; macOS 26.2 or
  later if you want Thunderbolt RDMA. Everything else in this guide runs on any macOS that MLX
  supports. mlx-lm also targets **CUDA and CPU** now — `pip install "mlx-lm[cuda13]"`,
  `"[cuda12]"`, `"[cpu]"` — because the `mlx` requirement is pinned only under
  `platform_system == 'Darwin'`.
- **Python 3.10+** despite what `setup.py` claims.
- **`pip install mlx-lm`** or `conda install -c conda-forge mlx-lm`. Add `[train]` if you intend to
  fine-tune or run any learned-quantization CLI, `[evaluate]` for `mlx_lm.evaluate`.
- ⚠️ **Two undeclared runtime dependencies.** `rich` and `regex` are imported at *module level* by
  shipped code but are absent from `install_requires`. A bare `pip install mlx-lm` followed by
  `mlx_lm.chat` or `mlx_lm.lora` can fail with `ModuleNotFoundError: No module named 'rich'`;
  tool-call parsing fails without `regex`. Install them explicitly. (Gap G7, §10.4.)

---

## ⚠️ Read this before you trust a flag name below

Three things about the evidence in this guide.

**First: the strongest evidence class here is the repository itself.** Unlike the Core AI parts of
this series, where the best available evidence was Apple documentation, mlx-lm is open source and
the clone is on disk. Every signature, flag, default and error string in this guide was read out of
`ml-explore/mlx-lm` at commit `e5baded8c1d286754edb479ffbde4655a68e2758` ("Support for Poolside
LagunaXS open source coding model in nvfp4", 2026-07-26) in this session. That is evidence class 1.

**Second: MLX moves weekly, and this clone is shallow.** It was cloned `--depth 50`, so `git log`
on most paths returns only the graft boundary. **Do not treat any date in this guide as
authoritative** beyond the HEAD commit date. Three NAX correctness fix PRs opened against mlx core
in the three days before 2026-07-27 alone (#3912/#3922 still open, #3924 closed unmerged, on a
2026-08-03 `gh` re-check). Anything described here as "new" should be re-read against
`main` before you build on it.

**Third: the docs disagree with the code in several documented places, and the code wins.** mlx-lm
ships five Markdown files inside the package (`LORA.md`, `SERVER.md`, `LEARNED_QUANTS.md`,
`MANAGE.md`, `BENCHMARKS.md`). At least four of them are stale in ways that will waste your
afternoon — `LORA.md` documents an `mlx_lm.fuse --hf-path` flag that does not exist,
`LEARNED_QUANTS.md`'s defaults disagree with the argparse defaults, `SERVER.md` documents a
`top_logprobs` range the server does not enforce. Each is flagged where it appears.

Markers used throughout:

> ✅ **VERIFIED** — read from the repository, a header, or an Apple documentation page this
> session. Citation attached: file and line, or an issue number.
>
> 🟡 **RECONSTRUCTED** — the concept is attested but the exact spelling or number is inferred.
>
> 🔴 **GAP** — could not verify. The box says what is unknown, what would resolve it, and what to
> ship in the meantime.
>
> ⚠️ **SILENT FAILURE** — it does not throw. This guide has six.

---

## Contents

1. [Where mlx-lm sits, and the two versions you are running](#1-where-mlx-lm-sits)
2. [The CLI surface: all 18 entry points](#2-the-cli-surface)
3. [The Python generation API](#3-the-python-generation-api)
4. [KV caching: the nine cache classes](#4-kv-caching-the-nine-cache-classes)
5. [Prompt caching to disk](#5-prompt-caching-to-disk)
6. [Quantized KV: capacity, not throughput](#6-quantized-kv-capacity-not-throughput)
7. [Speculative decoding](#7-speculative-decoding)
8. [Batch generation and continuous batching](#8-batch-generation-and-continuous-batching)
9. [The silent-failure register](#9-the-silent-failure-register)
10. [Decision tables, cross-links, and the gap register](#10-decision-tables-cross-links-and-the-gap-register)

---

## 1. Where mlx-lm sits

### 1.1 The four-layer picture

WWDC26 session 232 ("Agentic AI workflows on Mac with MLX") lays out a stack that is worth
internalising because it explains why mlx-lm's API is shaped the way it is:

| Layer | Component | Apple's description (verbatim, session 232) |
|---|---|---|
| 4 | **The agent** | "any framework or tool that speaks the **OpenAI chat completions protocol**: Xcode, OpenCode, Pi agent, a custom script, or anything else." |
| 3 | **MLX-LM Server** | "an **OpenAI-compatible HTTP server** that exposes your local model through a standard API… **It's a drop-in replacement for any cloud LLM API.**" |
| 2 | **MLX-LM** | "provides everything you need to **load, run, quantize, and fine-tune** large language models. It supports **thousands of models from HuggingFace** and gives you both **CLI tools and a Python API**." |
| 1 | **MLX** | "our **open-source array framework purpose-built for Apple silicon**." |

> ✅ **VERIFIED** — quoted from the session 232 transcript, lines 33–49, via
> `notes/transcripts/evals-mlx.md:1272-1279`.

Apple also says out loud that this is already the substrate under other people's products:

> "Several popular apps and tools build on MLX and MLX-LM. **Ollama, LM Studio, and vLLM** are just
> a few of the most popular ones… **if you're using one of these tools, chances are you're already
> running on MLX.**" — session 232:51–53

That matters for this series specifically, because [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md)
shows `ChatCompletionsLanguageModel` turning any OpenAI-protocol endpoint into a Foundation Models
backend. `mlx_lm.server` is the shortest path from a Hugging Face checkpoint to a
`LanguageModelSession`, and §2.6 is where you learn to run it.

### 1.2 The two versions you are running, and why you must know which

There is a release-versus-`main` split in mlx-lm right now that is wide enough to change advice.

> ✅ **VERIFIED** — `mlx_lm/_version.py` → `__version__ = "0.31.3"`. Release history from
> `notes/repos/issues-mlx-stack.md:17-23`: latest PyPI release **0.31.3**, dated **2026-04-22**;
> prior releases 0.31.2, 0.31.0, 0.30.7.

Two facts about that history:

- **0.31.0 was yanked in practice for "BatchKV cache cross-contamination."** The phrasing is the
  reporter's, in mlx-lm#1425: *"I realize `0.31.0` was yanked for BatchKV cache cross-contamination,
  so this is **not** a request to recommend 0.31.0."* If you have 0.31.0 pinned anywhere, unpin it.
- **Multiple open issues explicitly distinguish "0.31.3 release" behaviour from "current main"
  behaviour.** Several of the cache fixes described in §4 and §6 exist only as merged-to-`main` or
  in-flight PRs.

Check both versions at the top of any bug report you file or read:

```bash
python -m mlx --version
python -m mlx_lm --version
```

> ✅ **VERIFIED** — `mlx_lm/cli.py` handles `--version` and prints `__version__`; `mlx_lm -h`
> lists subcommands only.

If you need `main`:

```bash
pip install "mlx-lm @ git+https://github.com/ml-explore/mlx-lm@main"
```

…and pin the commit hash in your lockfile, because "main" is not a version.

### 1.3 The deprecation banner you will see

Every CLI module still has an `if __name__ == "__main__":` block, and every one of them prints a
deprecation notice:

> ✅ **VERIFIED** — verbatim from the shipped modules:
> *"Calling `python -m mlx_lm.generate...` directly is deprecated. Use `mlx_lm.generate...` or
> `python -m mlx_lm generate ...` instead."*

So there are three spellings and only two are supported:

```bash
mlx_lm.generate --prompt "hi"          # supported (console script)
python -m mlx_lm generate --prompt "hi" # supported (dispatcher subcommand)
python -m mlx_lm.generate --prompt "hi" # deprecated — prints a banner
```

Scripts and CI in the wild are full of the third form. Fix them; the banner goes to stdout and will
eventually contaminate output you are parsing.

---

## 2. The CLI surface

### 2.1 All 18 entry points

> ✅ **VERIFIED** — read verbatim from `setup.py`'s `entry_points["console_scripts"]`. The list has
> exactly **18 entries**: one dispatcher plus **17 tools**.

| Entry point | Module | What it is for |
|---|---|---|
| `mlx_lm` | `mlx_lm.cli:main` | Dispatcher. `mlx_lm --version`, `mlx_lm -h`, `python -m mlx_lm <sub>` |
| `mlx_lm.generate` | `mlx_lm.generate:main` | One-shot text generation. The workhorse. §2.2 |
| `mlx_lm.chat` | `mlx_lm.chat:main` | Interactive REPL with a persistent KV cache. §2.3 |
| `mlx_lm.server` | `mlx_lm.server:main` | OpenAI-compatible HTTP server, continuous batching. §2.6 |
| `mlx_lm.convert` | `mlx_lm.convert:main` | HF checkpoint → MLX format, optionally quantized. §2.4 |
| `mlx_lm.cache_prompt` | `mlx_lm.cache_prompt:main` | Precompute a prompt's KV cache to a file. §5 |
| `mlx_lm.lora` | `mlx_lm.lora:main` | LoRA / DoRA / full fine-tuning. §2.7 |
| `mlx_lm.fuse` | `mlx_lm.fuse:main` | Fold adapters back into base weights; GGUF export. §2.7 |
| `mlx_lm.evaluate` | `mlx_lm.evaluate:main` | lm-evaluation-harness bridge. §2.8 |
| `mlx_lm.perplexity` | `mlx_lm.perplexity:main` | Perplexity on a dataset, with a standard error. §2.8 |
| `mlx_lm.benchmark` | `mlx_lm.benchmark:main` | Synthetic prefill/decode throughput. §2.8 |
| `mlx_lm.awq` | `mlx_lm.quant.awq:main` | Activation-aware weight quantization. §2.5 |
| `mlx_lm.dwq` | `mlx_lm.quant.dwq:main` | Distilled weight quantization. §2.5 |
| `mlx_lm.gptq` | `mlx_lm.quant.gptq:main` | GPTQ. §2.5 |
| `mlx_lm.dynamic_quant` | `mlx_lm.quant.dynamic_quant:main` | Sensitivity-driven mixed precision. §2.5 |
| `mlx_lm.manage` | `mlx_lm.manage:main` | Scan and delete models in the HF cache. §2.9 |
| `mlx_lm.upload` | `mlx_lm.upload:main` | Push a converted model to the Hub. §2.9 |
| `mlx_lm.share` | `mlx_lm.share:main` | Distribute a model directory across nodes. §2.9 |

The dispatcher's own subcommand tuple, read from `mlx_lm/cli.py`, has **17 names** and knows that
four of them live in the `quant` subpackage:

```python
subcommands = ("benchmark","cache_prompt","chat","convert","evaluate","fuse","generate",
               "lora","manage","perplexity","awq","dwq","dynamic_quant","gptq","server",
               "upload","share")
subpackages = {"awq":"quant","dwq":"quant","dynamic_quant":"quant","gptq":"quant"}
```

> ✅ **VERIFIED** — `mlx_lm/cli.py`, read this session.

**Every model-loading command has `--trust-remote-code`; `manage`, `upload`, and `share` do not.**
Those three utilities do not load a model architecture or tokenizer. On commands that do load a
model, the flag is the remediation for **CVE-2026-5843** (commit `bfa25a1`, "Fix CVE-2026-5843:
gate model_file execution behind trust_remote_code").[^trust-cli-source] Before that commit, a `model_file` key in a downloaded repo's
`config.json` caused mlx-lm to `exec` an arbitrary Python file from that repo. Now:

```python
if (model_file := config.get("model_file")) is not None:
    if not trust_remote_code:
        raise ValueError(
            f"The model at {model_path} requires importing and running a "
            f"custom module ({model_file!r}) to build its architecture. This "
            "is disabled by default. Pass trust_remote_code=True if you "
            "trust this model."
        )
```

> ✅ **VERIFIED** — quoted from `mlx_lm/utils.py::load_model`, via commit `bfa25a1`.
> `tests/test_utils.py::TestTrustRemoteCode` is a regression test asserting the side-effect file is
> **not** written by default.

The flag now gates **two** things that used to be one: the tokenizer's remote code *and* the model
architecture file. Treat `--trust-remote-code` on an untrusted repo as equivalent to
`curl … | sh`.

### 2.2 `mlx_lm.generate` — the workhorse

The single most-used command in the package. Its module constants are the defaults you will
inherit everywhere unless you override them:

```python
DEFAULT_PROMPT = "hello"
DEFAULT_MAX_TOKENS = 100
DEFAULT_TEMP = 0.0
DEFAULT_TOP_P = 1.0
DEFAULT_MIN_P = 0.0
DEFAULT_TOP_K = 0
DEFAULT_XTC_PROBABILITY = 0.0
DEFAULT_XTC_THRESHOLD = 0.0
DEFAULT_MIN_TOKENS_TO_KEEP = 1
DEFAULT_SEED = None
DEFAULT_MODEL = "mlx-community/Llama-3.2-3B-Instruct-4bit"
DEFAULT_QUANTIZED_KV_START = 5000
```

> ✅ **VERIFIED** — `mlx_lm/generate.py:36-47`.
>
> ⚠️ Note `DEFAULT_XTC_THRESHOLD = 0.0` here but **the argparse default for `--xtc-threshold` is
> `0.1`**. The constant is not what the CLI uses. This is one of four places where XTC defaults
> disagree across the package (§9.3).

The full flag set:

| Flag | Type | Default | Notes |
|---|---|---|---|
| `--model` | str | `mlx-community/Llama-3.2-3B-Instruct-4bit` | local dir or HF repo id |
| `--trust-remote-code` | flag | off | gates tokenizer code **and** custom `model_file` |
| `--adapter-path` | str | none | LoRA/DoRA adapter directory |
| `--extra-eos-token` | str, `nargs="+"` | `()` | extra stop tokens |
| `--system-prompt` | str | none | prepended as `{"role":"system"}` |
| `--prompt` / `-p` | str | `"hello"` | `-` reads stdin; `\n` and `\t` escapes are expanded |
| `--prefill-response` | str | none | appends an assistant message + `continue_final_message=True` |
| `--max-tokens` / `-m` | int | 100 | |
| `--temp` | float | 0.0 | **0 ⇒ argmax, and disables every other sampler filter** |
| `--top-p` | float | 1.0 | active only when `0 < top_p < 1.0` |
| `--min-p` | float | 0.0 | |
| `--top-k` | int | 0 | must satisfy `0 < top_k < vocab_size` when enabled |
| `--xtc-probability` | float | 0.0 | |
| `--xtc-threshold` | float | **0.1** | must be in `[0, 0.5]` |
| `--min-tokens-to-keep` | int | 1 | floor for min-p |
| `--seed` | int | none | `mx.random.seed` |
| `--ignore-chat-template` | flag | off | use the raw prompt |
| `--use-default-chat-template` | flag | off | ⚠️ **no-op in this command — see §9.1** |
| `--chat-template-config` | JSON str | none | kwargs forwarded to `apply_chat_template` |
| `--verbose` | `str2bool` | True | `"false"`/`"f"` ⇒ False, case-insensitive |
| `--max-kv-size` | int | none | switches to a rotating (sliding-window) cache |
| `--prompt-cache-file` | str | none | a `.safetensors` prompt cache, §5 |
| `--quantize-activations` / `-qa` | flag | off | requires nvfp4 or mxfp8 weights |
| `--kv-bits` | int | none | KV-cache quantization bit width |
| `--kv-group-size` | int | 64 | |
| `--quantized-kv-start` | int | 5000 | step at which to switch to a quantized cache |
| `--draft-model` | str | none | speculative decoding, §7 |
| `--num-draft-tokens` | int | 3 | |

> ✅ **VERIFIED** — read from `mlx_lm/generate.py`'s `setup_arg_parser()` this session.

Real invocations:

```bash
# The absolute minimum. Downloads the default 3B 4-bit Llama if you have nothing.
mlx_lm.generate --prompt "How tall is Mt Everest?"

# A named model, sampled, with a longer budget.
mlx_lm.generate --model mlx-community/Qwen3-8B-4bit \
                --prompt "Explain MoE routing in three sentences." \
                -m 512 --temp 0.7 --top-p 0.9

# Long document from stdin, bounded cache, quantized KV past the first 2048 tokens.
mlx_lm.generate --model mlx-community/Qwen3-8B-4bit \
                --prompt - < long.txt \
                --max-kv-size 4096 --kv-bits 4 --quantized-kv-start 2048

# Prefill the assistant turn so the model continues rather than starts.
mlx_lm.generate --model mlx-community/Qwen3-8B-4bit \
                --prompt "Write a haiku about Metal." \
                --prefill-response "Threadgroups align"

# Machine-readable: silence the stats banner.
mlx_lm.generate --model mlx-community/Qwen3-8B-4bit -p "one word answer: capital of France" \
                --verbose false
```

Two behaviours worth knowing before you script against this:

**`-` means stdin, and the escapes are expanded first.** The order in `main()` is: expand `\n` and
`\t`, *then* check whether the result equals `"-"`. So `--prompt -` reads stdin;
`--prompt "\nSummarize the above."` gets a real leading newline, which matters for the prompt-cache
workflow in §5.

**`--verbose` is a `str2bool`, not a `store_true`.** `--verbose false` and `--verbose f` both work
and are case-insensitive. `--verbose` alone is an error, because it wants a value. This trips
people who assume the usual argparse idiom.

### 2.3 `mlx_lm.chat` — a REPL with a live cache

`mlx_lm.chat` is the smallest correct demonstration of multi-turn KV reuse in the package, and
that is the reason to read it even if you never use it interactively.

Defaults differ from `generate`: `DEFAULT_MAX_TOKENS = 256`, `DEFAULT_SEED = 0` (not `None`),
`DEFAULT_XTC_THRESHOLD = 0.0` (not 0.1).

> ✅ **VERIFIED** — `mlx_lm/chat.py` module constants, read this session.

Flags: `--model --trust-remote-code --adapter-path --temp --top-p --xtc-probability
--xtc-threshold --seed --max-kv-size --max-tokens/-m --system-prompt --pipeline`.

```bash
mlx_lm.chat --model mlx-community/Llama-3.2-3B-Instruct-4bit --system-prompt "Be terse."
mlx_lm.chat --model mlx-community/Qwen3-8B-4bit --max-kv-size 8192 -m 1024
```

REPL commands, from `cli_ui.print_chat_help` and `chat.main`:

| Key | Effect |
|---|---|
| `q` | exit |
| `r` | **reset context** — rebuilds the prompt cache from scratch |
| `h` | help |

> ✅ **VERIFIED** — read from `mlx_lm/chat.py` and `mlx_lm/cli_ui.py`.

The whole multi-turn mechanism is one line: a single
`make_prompt_cache(model, args.max_kv_size)` is created once and **shared across every turn**.
That is the entire trick, and §4 explains why it works and when it stops working.

Distributed: if `mx.distributed.init().size() > 1`, chat uses `sharded_load` with a
`pipeline_group` when `--pipeline` is given and a `tensor_group` otherwise. **Adapters are rejected
in distributed mode** — `parser.error("Adapters not supported in distributed mode")`.

### 2.4 `mlx_lm.convert` — Hugging Face to MLX

| Flag | Default | Notes |
|---|---|---|
| `--hf-path` / `--model` | — | two spellings, same destination (`hf_path`) |
| `--mlx-path` | `mlx_model` | **must not already exist** |
| `-q` / `--quantize` | off | |
| `--q-group-size` | none → mode default | |
| `--q-bits` | none → mode default | |
| `--q-mode` | `affine` | choices: `affine`, `mxfp4`, `nvfp4`, `mxfp8` |
| `--quant-predicate` | none | `mixed_2_6`, `mixed_3_4`, `mixed_3_6`, `mixed_4_6` |
| `--dtype` | none | `float16`, `bfloat16`, `float32`; else taken from config `torch_dtype` |
| `--upload-repo` | none | |
| `-d` / `--dequantize` | off | mutually exclusive with `-q` |
| `--trust-remote-code` | off | |

> ✅ **VERIFIED** — `mlx_lm/convert.py`, read this session. Mode defaults from
> `utils.quantize_model`: `{"affine": (64, 4), "mxfp4": (32, 4), "nvfp4": (16, 4), "mxfp8": (32, 8)}`.

```bash
mlx_lm.convert --model mistralai/Mistral-7B-Instruct-v0.3 -q          # affine 4-bit, group 64
mlx_lm.convert --model Qwen/Qwen3-8B -q --q-mode nvfp4                # 4-bit, group 16
mlx_lm.convert --model meta-llama/Llama-3.1-8B -q --q-bits 3 --quant-predicate mixed_3_6
mlx_lm.convert --model org/Model -d --mlx-path model_bf16             # dequantize
mlx_lm.convert --model mistralai/Mistral-7B-Instruct-v0.3 -q \
               --upload-repo mlx-community/my-4bit-mistral
```

Three hard errors it will give you, verbatim:

- `ValueError(f"Cannot save to the path {mlx_path} as it already exists...")` — **there is no
  `--force` and no overwrite flag.** Delete the directory yourself.
- `ValueError("Choose either quantize or dequantize, not both.")`
- Quant predicates work only with `--q-mode affine`.

The bit-width and recipe reasoning belongs to [guide 03](03-quantization.md).

### 2.5 The four learned-quantization CLIs

All four need `pip install "mlx-lm[train]"`. All four download and cache the same calibration
corpus at `~/.cache/mlx-lm/calibration_v5.txt` on first run.

```bash
mlx_lm.awq  --model Qwen/Qwen3-0.6B --bits 4 --group-size 64 --num-samples 128 --n-grid 20
mlx_lm.dwq  --model Qwen/Qwen3-8B  --bits 3 --group-size 32 --batch-size 1 --max-seq-length 512
mlx_lm.gptq --model Qwen/Qwen3-0.6B --bits 4 --group-size 64 --fallback-bits 6
mlx_lm.dynamic_quant --model Qwen/Qwen3-0.6B --target-bpw 4.8 --low-bits 4 --high-bits 5
```

> ✅ **VERIFIED** — argparse defaults read from `mlx_lm/quant/{awq,dwq,gptq,dynamic_quant}.py`.
>
> ⚠️ **`LEARNED_QUANTS.md` disagrees with the code.** The doc says DWQ defaults to
> `--num-samples 1024` and `--batch-size 8`; the code says **2048** and **4**, with
> `--max-seq-length 1025`. The doc says AWQ `--num-samples 32`, `--n-grid 10`; the code says
> **128** and **20**. Trust `--help`, not the Markdown.

Two constraints that will stop you cold, so know them before you plan a run:

- **AWQ supports exactly seven model types**: `llama`, `mistral`, `qwen2`, `qwen3`, `gemma3_text`,
  `gemma3`, `deepseek_v2`. Anything else raises
  `NotImplementedError(f"AWQ support for {model_type} models NYI.")`.
- **GPTQ asserts `bits in {2, 4, 8}`**, and anything that is not `nn.Linear`/`SwitchLinear` falls
  back to `--fallback-bits` (default **6**), which raises your effective bits-per-weight above what
  you asked for.

Everything else about these four — what they actually do, when each wins — is
[guide 03](03-quantization.md).

### 2.6 `mlx_lm.server` — the OpenAI-compatible endpoint

This is the entry point that turns everything else in the package into infrastructure. It is also
the one with the most tunables, most of which are cache tunables.

| Flag | Default | What it does |
|---|---|---|
| `--model` | none | **lazy** — a model can be selected per request instead |
| `--adapter-path` | none | |
| `--host` | `127.0.0.1` | |
| `--port` | `8080` | |
| `--allowed-origins` | `"*"` | comma-split into a list **only when explicitly given** |
| `--draft-model` | none | ⚠️ **disables continuous batching**, §8.4 |
| `--num-draft-tokens` | 3 | |
| `--trust-remote-code` | off | |
| `--log-level` | `INFO` | `DEBUG/INFO/WARNING/ERROR/CRITICAL` |
| `--chat-template` | `""` | |
| `--use-default-chat-template` | off | **this one does work here**, unlike in `generate` (§9.1) |
| `--temp` | 0.0 | |
| `--top-p` | 1.0 | |
| `--top-k` | 0 | |
| `--min-p` | 0.0 | |
| `--max-tokens` | 512 | |
| `--chat-template-args` | `{}` | JSON, e.g. `'{"enable_thinking":false}'` |
| `--decode-concurrency` | 32 | sequences decoding in parallel |
| `--prompt-concurrency` | 8 | prompts prefilling in parallel |
| `--prefill-step-size` | 2048 | ⚠️ **also the quantized-KV memory knob**, §6.2 |
| `--prompt-cache-size` | 10 | maximum number of distinct KV caches held |
| `--prompt-cache-bytes` | none | accepts `8GB`, `512MB`, bare bytes |
| `--pipeline` | off | pipelining instead of tensor parallelism |

> ✅ **VERIFIED** — `mlx_lm/server.py:1717-1862`, read this session; the concurrency and cache
> defaults are independently corroborated at `server.py:1819-1852` via
> `notes/transcripts/evals-mlx.md:1346-1351`.

```bash
# The three-step setup Apple demonstrates in session 232.
pip install mlx-lm
mlx_lm.server --model mlx-community/Qwen3-8B-4bit
# …then point any OpenAI-protocol client at http://localhost:8080/v1

# A tuned agentic configuration: many subagents, a big prompt cache, thinking off.
mlx_lm.server --model mlx-community/Qwen3-8B-4bit --port 8080 \
              --decode-concurrency 32 --prompt-concurrency 8 \
              --prompt-cache-size 20 --prompt-cache-bytes 8GB \
              --chat-template-args '{"enable_thinking":false}'

curl localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Say this is a test!"}],"temperature":0.7}'

curl localhost:8080/health          # → {"status": "ok"}
curl localhost:8080/v1/models
```

On startup, if Metal is available, the server wires memory to the device's recommended working set:

```python
if mx.metal.is_available():
    mx.set_wired_limit(mx.device_info()["max_recommended_working_set_size"])
```

and prints a warning that deserves to be taken at face value:

> *"mlx_lm.server is not recommended for production as it only implements basic security checks."*

> ✅ **VERIFIED** — `mlx_lm/server.py`; the same sentence appears in `SERVER.md:8-9`.

Five behaviours that will surprise you, all read from source:

1. **Errors come back as HTTP 404.** Any exception raised while constructing the generator —
   including a model that fails to load, or a tokenization failure — is returned as
   `404` with `{"error": str(e)}` from `handle_completion`, not `400` or `500`. Clients that
   retry on 404 as "wrong URL" will do the wrong thing.
2. **Reasoning is exposed as `message.reasoning`, not `reasoning_content`.** Streaming uses
   `delta.reasoning`. Clients written against other OpenAI-compatible servers frequently look for
   `reasoning_content` and will silently show nothing.
3. **`usage.prompt_tokens_details.cached_tokens` reports your prompt-cache hit length.** This is
   the observability hook for everything in §5. Log it.
4. **`top_logprobs` uses `-1` as the "off" sentinel** and accepts `0..11`, even though `SERVER.md`
   documents 1–10.
5. **Streaming keepalives are SSE comments** of the form `": keepalive {processed}/{total}"`,
   emitted from the prompt-progress callback so a long prefill does not time out the connection.
   A strict SSE client that chokes on comment lines will break here.

### 2.7 `mlx_lm.lora` and `mlx_lm.fuse`

Enumerated for completeness; taught in [guide 06](06-finetuning-and-porting-models.md).

```bash
pip install "mlx-lm[train]"

mlx_lm.lora --model mistralai/Mistral-7B-v0.1 --train --data ./data --iters 600 \
            --fine-tune-type lora --num-layers 16 --batch-size 4 \
            --grad-accumulation-steps 4 --grad-checkpoint --mask-prompt
mlx_lm.lora --config mlx_lm/examples/lora_config.yaml
mlx_lm.lora --model org/Model --adapter-path adapters --data ./data --test
mlx_lm.generate --model org/Model --adapter-path adapters -p "..."
mlx_lm.fuse --model org/Model --adapter-path adapters --save-path fused_model
```

`--fine-tune-type` takes `{lora, dora, full}`; `--optimizer` takes
`{adam, adamw, muon, sgd, adafactor}`. `--num-layers -1` means all layers. `--report-to` accepts
`wandb`, `swanlab`, or `wandb,swanlab`.

> ✅ **VERIFIED** — `CONFIG_DEFAULTS` in `mlx_lm/lora.py:44-81`; flag list from its argparse.
>
> ⚠️ **`mlx_lm.fuse` has no `--hf-path` flag** at this commit, despite `LORA.md` instructing you to
> pass one. Its actual flags are `--model` (default `mlx_model`), `--save-path` (default
> `fused_model`), `--adapter-path` (default `adapters`), `--upload-repo`, `--dequantize`,
> `--export-gguf`, `--gguf-path`, `--trust-remote-code`.
>
> ⚠️ **GGUF export is restricted to three model types** — `llama`, `mixtral`, `mistral`, fp16 only:
> `ValueError(f"Model type {model_type} not supported for GGUF conversion.")`.

### 2.8 `mlx_lm.evaluate`, `.perplexity`, `.benchmark` — the measurement three

**`mlx_lm.evaluate`** registers an lm-evaluation-harness model —
`@register_model("mlxlm") class MLXLM(LM)` — implementing `loglikelihood`,
`loglikelihood_rolling` and `generate_until`, with `generate_until` routing through
`batch_generate`.

```bash
mlx_lm.evaluate --model mlx_model \
  --tasks winogrande boolq arc_challenge arc_easy hellaswag openbookqa piqa social_iqa
mlx_lm.evaluate --model mlx_model --tasks mmlu_pro --batch-size 16 --limit 200
```

Flags: `--model` (**required**), `--tasks` (`nargs="+"`, **required**), `--output-dir` (`.`),
`--batch-size` (16), `--num-shots`, `--max-tokens` (none → `DEFAULT_MAX_TOKENS = 8192`),
`--limit`, `--seed` (123), `--fewshot-as-multiturn`, `--apply-chat-template`
(a `BooleanOptionalAction`, so `--no-apply-chat-template` works), `--chat-template-args`,
`--confirm-run-unsafe-code`, `--trust-remote-code`, `--temp` (0.0), `--top-p` (1.0), `--top-k` (0).
It is distributed-aware: requests are split `requests[rank::size]` and gathered with
`mx.distributed.all_gather`.

> 🔴 **GAP — a latent `NameError` in `evaluate.py::loglikelihood`.** The `prefix_l == 0` branch
> calls `all_scores.extend(...)` and `all_is_greedy.extend(...)`, but those names do not exist in
> that scope — the locals are `scores` and `is_greedy`. **What is unknown:** whether this has been
> fixed on `main` since our read. **What would resolve it:** re-grep `evaluate.py` for
> `all_scores`. **Safe default:** the branch only triggers when a completion is longer than the
> context budget, so cap `--max-tokens` below your model's context and you will not reach it.

**`mlx_lm.perplexity`** reports `Perplexity: {ppl:.3f} ± {se:.3f}`, where the standard error uses a
delta approximation `ppl * (std / sqrt(n_tokens))` — a real uncertainty band, which most perplexity
tools do not give you. Use it.

```bash
mlx_lm.perplexity --model mlx_model --num-samples 512 --sequence-length 1024
```

Flags: `--model` (required), `--trust-remote-code`, `--batch-size` (8), `--sequence-length` (512),
`--num-samples` (256; `-1` = all), `--data-path` (`allenai/tulu-3-sft-mixture`), `--seed` (123).

**`mlx_lm.benchmark`** measures throughput on *synthetic* input — random token IDs — and blanks the
EOS set so generation never stops early.

```bash
mlx_lm.benchmark --model mlx_model -p 2048 -g 128 -b 8 -n 5
```

Flags: `--model`, `--prompt-tokens/-p` (512), `--generation-tokens/-g` (1024), `--batch-size/-b`
(1), `--num-trials/-n` (5), `--pipeline`, `--quantize-activations/-qa`, `--prefill-step-size`
(2048), `--delay` (0 s), `--trust-remote-code`. `batch_size == 1` uses `stream_generate`;
anything larger uses `batch_generate`. It reports `prompt_tps`, `generation_tps` and `peak_memory`
per trial plus averages.

> ⚠️ **`mlx_lm.benchmark` zeroes the EOS set** — literally `tokenizer._eos_token_ids = {}`. That is
> correct for a benchmark and catastrophic for anything else. **Never reuse that tokenizer object
> for real generation in the same process.** It will not stop.

Apple-adjacent numbers you can cite: `mlx_lm/BENCHMARKS.md` publishes a results table measured on a
**64 GB M4 Max, mlx 0.29.2.dev, mlx-lm 0.28.2, macOS 26.1**. For Qwen3-4B-Instruct-2507: bf16
scores MMLU-Pro **64.05** at **52.47** generation tok/s using **9.02 GB**; the 4-bit quantization
scores **60.72** at **134.52** tok/s using **3.35 GB**.

> ✅ **VERIFIED** — `mlx_lm/BENCHMARKS.md`. **Attribution: project-published, not Apple-published**
> — mlx-lm is an Apple-employee-maintained open-source project, but this table is a repo artifact,
> not an Apple marketing claim. Hardware, framework versions and OS as stated above.

### 2.9 `mlx_lm.manage`, `.upload`, `.share`

```bash
mlx_lm.manage --scan --pattern mlx-community
mlx_lm.manage --delete --pattern mlx-community/Old-Model     # prompts y/n
mlx_lm.upload --path mlx_model --upload-repo mlx-community/Model-4bit-DWQ
mlx_lm.share --model mlx-community/Llama-3.3-70B-Instruct-4bit --hostfile hosts.json
```

`manage` scans and deletes via `huggingface_hub.scan_cache_dir()`; `--pattern` defaults to
`"mlx"`. `upload` is a thin wrapper on `utils.upload_to_hub`, which uses
`HfApi().upload_large_folder(...)`, sets `library_name="mlx"` and `pipeline_tag="text-generation"`,
and writes a model card containing the provenance line *"…was converted to MLX format from … using
mlx-lm version {\_\_version\_\_}."*

**`mlx_lm.share` is new in the 2026 tree** (© 2026 header) and solves a real distributed problem:
getting one copy of a 400 GB model onto four machines without downloading it four times. It
transfers a model directory over `mx.distributed` in 100 MB chunks
(`CHUNK_SIZE = 100 * 1024 * 1024`), using `mx.distributed.all_sum` as the transport, preserving
directories and symlinks, writing into a `TemporaryDirectory` and then `os.rename`-ing into place.
If launched with world size 1 it **re-launches itself** through
`mlx._distributed_utils.launch.launch_ring` or `launch_jaccl` using your hostfile. Backend must be
one of `ring`, `jaccl`, `jaccl-ring`.

Its error message when it cannot find the source is unusually helpful:

> *"The --path needs to exist in at least one node. If it is a remote repository download it first
> with `hf download`"*

> 🔴 **GAP — the `share` hostfile schema.** `mlx_lm.share` reads it through
> `mlx._distributed_utils.common.Hostfile`, which lives in **mlx core, not mlx-lm**, and is not
> documented in this repo. C10.4 in our corrections register gives the shape from a WWDC session —
> a JSON array of `{ssh, ips[], rdma[]}` where `rdma` is a positional adjacency matrix with `null`
> on the diagonal — but that was recovered from a session, not read from the `Hostfile` parser.
> **What would resolve it:** reading `mlx/_distributed_utils/common.py`. **Safe default:** generate
> the hostfile with `mlx.distributed_config --hosts … --output hosts.json --auto-setup` rather than
> writing one by hand.

---

## 3. The Python generation API

### 3.1 What the package actually exports

```python
# mlx_lm/__init__.py
os.environ["TRANSFORMERS_NO_ADVISORY_WARNINGS"] = "1"
from .convert import convert
from .generate import batch_generate, generate, stream_generate
from .utils import load
__all__ = ["__version__", "convert", "batch_generate", "generate", "stream_generate", "load"]
```

> ✅ **VERIFIED** — `mlx_lm/__init__.py`, read verbatim.

Five public names. Everything else — `generate_step`, `speculative_generate_step`,
`BatchGenerator`, `make_sampler`, `make_logits_processors`, the entire `models.cache` module — is
reachable but not re-exported, so you import it from its module. That import path is a stability
signal: the five exported names are the API contract; the rest is *public but not promised*.

### 3.2 `load`

```python
def load(
    path_or_hf_repo: str,
    tokenizer_config: Optional[Dict[str, Any]] = None,
    model_config: Optional[Dict[str, Any]] = None,
    adapter_path: Optional[str] = None,
    lazy: bool = False,
    return_config: bool = False,
    revision: Optional[str] = None,
    trust_remote_code: bool = False,
) -> Union[Tuple[nn.Module, TokenizerWrapper],
           Tuple[nn.Module, TokenizerWrapper, Dict[str, Any]]]
```

> ✅ **VERIFIED** — `mlx_lm/utils.py:482`.

```python
from mlx_lm import load

model, tokenizer = load("mlx-community/Qwen3-8B-4bit")

# Override tokenizer behaviour:
model, tokenizer = load(
    "qwen/Qwen-7B",
    tokenizer_config={"eos_token": "<|endoftext|>", "trust_remote_code": True},
)

# Get the config back too:
model, tokenizer, config = load("mlx-community/Qwen3-8B-4bit", return_config=True)
```

Four things about `load` that matter operationally:

**`lazy=False` is the default and it is expensive on MoE models.** A non-lazy load calls
`mx.eval(model.parameters())`, which materialises the full stacked `(num_experts, …)` expert table
at load time.

> ✅ **VERIFIED** — community-measured, reported in mlx-lm#1438: an **18.2 GB spike on
> Qwen3.6-35B-A3B-4bit before a single token is generated**. The recommendation from that thread is
> `load(lazy=True)` plus dropping references to the full table before anything forces its eval.
> Attribute as community-measured; hardware not stated for that specific figure.

**The download filter is narrow, and deliberately so.**

```python
DEFAULT_ALLOW_PATTERNS = [
    "*.json", "model*.safetensors", "*.py", "tokenizer.model", "*.tiktoken",
    "tiktoken.model", "*.txt", "*.jsonl", "*.jinja",
]
```

> ✅ **VERIFIED** — `mlx_lm/utils.py:219`. `hf_repo_to_path(hf_repo)` calls
> `snapshot_download(..., local_files_only=True, allow_patterns=DEFAULT_ALLOW_PATTERNS)`; the
> `allow_patterns` argument was added specifically to fix `IncompleteSnapshotError`
> (commit `4128c00`). Note `*.py` is in the list — that is how a `model_file` architecture arrives,
> which is why `--trust-remote-code` exists.

**ModelScope is supported as an alternative hub.** Set `MLXLM_USE_MODELSCOPE=true` and
`pip install modelscope`, and `snapshot_download` comes from modelscope instead of
`huggingface_hub` (`utils.py:27-33`).

**Importing `mlx_lm.utils` mutates your process.** At import time it raises the file-descriptor
limit: `resource.setrlimit(resource.RLIMIT_NOFILE, (2048, 4096))`. Harmless in a CLI, surprising in
a long-lived host process that manages its own limits.

### 3.3 `generate` and `stream_generate`

```python
def generate(
    model: nn.Module,
    tokenizer: Union[PreTrainedTokenizer, TokenizerWrapper],
    prompt: Union[str, List[int]],
    verbose: bool = False,
    **kwargs,
) -> str

def stream_generate(
    model: nn.Module,
    tokenizer: Union[PreTrainedTokenizer, TokenizerWrapper],
    prompt: Union[str, mx.array, List[int]],
    max_tokens: int = 256,
    draft_model: Optional[nn.Module] = None,
    **kwargs,
) -> Generator[GenerationResponse, None, None]
```

> ✅ **VERIFIED** — `mlx_lm/generate.py:747` and `:648`, read this session. In both, `**kwargs` is
> forwarded to `generate_step` — or to `speculative_generate_step` when `draft_model` is not None.

`generate` is `stream_generate` with the chunks concatenated and, under `verbose=True`, a stats
banner printed between `==========` fences: prompt tokens and tok/s, generation tokens and tok/s,
peak memory.

> ⚠️ **`generate()` returns `None`, not `""`, when the model emits no text.** The implementation is
> literally `if len(text) == 0: print("No text generated for this prompt"); return`. Any caller
> doing `generate(...).strip()` crashes with `AttributeError: 'NoneType' object has no attribute
> 'strip'` on exactly the inputs where you least want a crash. Guard it, or use `stream_generate`.

`GenerationResponse` is the streaming payload and it carries far more than text:

```python
@dataclass
class GenerationResponse:
    text: str
    token: int
    logprobs: mx.array          # the full log-prob vector for this step
    from_draft: bool            # True if the draft model produced it (§7)
    prompt_tokens: int
    prompt_tps: float
    generation_tokens: int
    generation_tps: float
    peak_memory: float          # GB
    finish_reason: Optional[str] = None    # "stop" | "length" | None
```

> ✅ **VERIFIED** — `mlx_lm/generate.py:260-287`.

Four behaviours of the streaming loop, all read from source:

- **The EOS token is never emitted.** The loop `break`s *before* `detokenizer.add_token(token)`
  when `token in tokenizer.eos_token_ids`. You will not see it in `.text` and you will not see it
  in `.token`.
- **A final `GenerationResponse` is always yielded** after `detokenizer.finalize()`, carrying the
  `finish_reason`. Do not `break` out of the loop when you see your last visible text or you will
  never learn *why* it stopped.
- **The whole loop runs inside `with wired_limit(model, [generation_stream])`.**
- **When `draft_model` is provided, `max_kv_size` and `prompt_progress_callback` are silently
  dropped from kwargs**; when it is `None`, `num_draft_tokens` is dropped. This is a `kwargs.pop`,
  not a warning. See §9.4.

### 3.4 `generate_step` — the generator everything sits on

```python
def generate_step(
    prompt: mx.array,
    model: nn.Module,
    *,
    max_tokens: int = 256,                 # -1 ⇒ infinite
    sampler: Optional[Callable[[mx.array], mx.array]] = None,
    logits_processors: Optional[List[Callable[[mx.array, mx.array], mx.array]]] = None,
    max_kv_size: Optional[int] = None,
    prompt_cache: Optional[Any] = None,    # UPDATED IN PLACE
    prefill_step_size: int = 2048,
    kv_bits: Optional[int] = None,
    kv_group_size: int = 64,
    quantized_kv_start: int = 0,           # ← note: 0, not 5000
    prompt_progress_callback: Optional[Callable[[int, int], None]] = None,
    input_embeddings: Optional[mx.array] = None,
) -> Generator[Tuple[mx.array, mx.array], None, None]
```

> ✅ **VERIFIED** — `mlx_lm/generate.py:298-312`, read verbatim this session. Every keyword after
> `model` is keyword-only.

Behaviour worth knowing:

- **The default sampler is `lambda x: mx.argmax(x, axis=-1)`** — greedy. Not temperature 1.
- **Log-probs are `logits - mx.logsumexp(logits, keepdims=True)`.** They are true log-probs, so
  `exp()` them if you want probabilities; do not softmax them again.
- **Prefill processes `min(prefill_step_size, remaining - 1)` tokens per step**, calling
  `mx.eval([c.state for c in prompt_cache])` and `mx.clear_cache()` after each chunk. Note the
  `- 1`: prefill always leaves exactly one token for the first decode step.
- **During decode, `mx.clear_cache()` fires every 256 tokens** (`if n % 256 == 0`).
- **`mx.async_eval(next_y, next_logprobs)` gives one-step lookahead pipelining** — the next token
  is being computed while you consume the current one. This is why consuming the generator slowly
  costs you nothing but why holding a reference to every `logprobs` array costs you a lot.
- **`input_embeddings`** requires `does_model_support_input_embeddings(model)` — which inspects
  `model.__call__`'s signature for an `input_embeddings` parameter — and either an empty prompt or
  `len(prompt) == len(input_embeddings)`.

The generation stream is thread-local:

```python
generation_stream = mx.new_thread_local_stream(mx.default_device())
```

> ✅ **VERIFIED** — commit `ed1fca4` "Thread local generation stream" (#1090). This exists because
> of mlx#3727, a 0.31.1→0.31.2 regression where *"stream created in main thread is unusable from a
> worker thread — `There is no Stream(gpu, 0) in current thread`"*, which broke the threaded
> server. If you build your own threaded host around `generate_step`, do not hoist a stream out of
> `__init__`.

### 3.5 `wired_limit` — and the warning that means "you are about to be slow"

```python
model_bytes = tree_reduce(
    lambda acc, x: acc + x.nbytes if isinstance(x, mx.array) else acc, model, 0)
max_rec_size = mx.device_info()["max_recommended_working_set_size"]
if model_bytes > 0.9 * max_rec_size:
    print("[WARNING] Generating with a model that requires {model_mb} MB which is close to the "
          "maximum recommended size of {max_rec_mb} MB. This can be slow. ...")
old_limit = mx.set_wired_limit(max_rec_size)
```

> ✅ **VERIFIED** — `mlx_lm/generate.py:220-257`.

If you see that warning, the documented fix is to raise the wired limit at the OS level:

```bash
sudo sysctl iogpu.wired_limit_mb=N     # N > model MB, but < machine RAM
```

> ✅ **VERIFIED** — mlx-lm's `README.md`: *"Models which are large relative to the total RAM …
> `mlx-lm` will attempt to make them faster by wiring the memory occupied by the model and cache.
> **This requires macOS 15 or higher to work.**"* This is the one genuine OS floor in the
> generation path.

Pick `N` with care. Setting it above your physical RAM invites the kernel to wire pages it needs
for everything else.

### 3.6 Samplers: `make_sampler` and the order that decides your output

```python
def make_sampler(
    temp: float = 0.0,
    top_p: float = 0.0,
    min_p: float = 0.0,
    min_tokens_to_keep: int = 1,
    top_k: int = 0,
    xtc_probability: float = 0.0,
    xtc_threshold: float = 0.1,
    xtc_special_tokens: List[int] = [],
) -> Callable[[mx.array], mx.array]
```

> ✅ **VERIFIED** — `mlx_lm/sample_utils.py`, 369 lines, read this session.

The filters are chained **in a fixed order**, and only the enabled ones are included:

1. `apply_top_p` — **only if `0 < top_p < 1.0`**
2. `apply_min_p` — if `min_p != 0.0`
3. `apply_xtc` — if `xtc_probability > 0.0`
4. `apply_top_k` — if `top_k > 0`
5. `categorical_sampling(logprobs, temp)` = `mx.random.categorical(logits * (1 / temp))`

Note that **top-k runs last, after XTC**. If you are porting a sampler configuration from another
runtime that applies top-k first, you will get different text from identical parameters. That is
not a bug in either runtime; it is an ordering convention, and mlx-lm's is the one above.

**`temp == 0` short-circuits the entire chain to `lambda x: mx.argmax(x, axis=-1)`.** Every other
parameter you passed is discarded. This is the most common sampler mistake in the ecosystem: people
set `--top-k 50 --xtc-probability 0.2` alongside the default `--temp 0.0` and conclude the flags do
not work. They work; you disabled them.

All four filters are compiled with random state threaded through:

```python
@partial(mx.compile, inputs=mx.random.state, outputs=mx.random.state)
```

Validation errors, verbatim, so you can grep for them:

- `apply_top_k`: `` f"`top_k` has to be an integer in the (0, {vocab_size}) interval, but is {top_k}." ``
  — note the bounds are **exclusive** on both ends, corrected in commit `df48987`.
- `apply_min_p`: `` f"`min_p` has to be a float in the [0, 1] interval, but is {min_p}" ``, and
  `min_tokens_to_keep` must be a positive int.
- `apply_xtc`: threshold in `[0, 0.5]`, probability in `[0, 1]`.

Two implementation details that change how you should set the values:

**`apply_top_p` sorts ascending and keeps `cumulative_probs > 1 - top_p`.** Same semantics as
everywhere else, different arithmetic; nothing to do.

**`apply_min_p` works in log space**: `scaled_min_p = max_logprob + math.log(min_p)`. That is why
`min_p` is numerically stable at tiny values where a probability-space implementation would
underflow.

**XTC needs its special-token list or it will eat your newlines.** The implementation:

```python
probs = mx.softmax(logits, -1)
mask = probs > mx.where(probs > xtc_threshold, probs, mx.inf).min(axis=-1, keepdims=True)
if xtc_special_tokens:
    mask[..., xtc_special_tokens] = False
return mx.where(mx.random.uniform(0, 1) > xtc_probability,
                logits, mx.where(mask, -mx.inf, logits))
```

> ✅ **VERIFIED** — `mlx_lm/sample_utils.py`; the per-row minimum was a fix, commit `7661de1`
> ("Fix XTC threshold to be per-row for batched logits", #1575) — before it, batched logits shared
> one global threshold.

Every caller inside mlx-lm passes the same guard list:

```python
xtc_special_tokens = tokenizer.encode("\n") + list(tokenizer.eos_token_ids)
```

> ✅ **VERIFIED** — identical at `generate.py:2168`, `server.py:389` and `chat.py:152`. **If you
> build a sampler by hand and omit this, XTC can suppress newlines and EOS**, giving you a model
> that produces one enormous unstructured paragraph and never stops. Copy the line.

### 3.7 Logits processors: `make_logits_processors`

```python
def make_logits_processors(
    logit_bias: Optional[Dict[int, float]] = None,
    repetition_penalty: Optional[float] = None,
    repetition_context_size: Optional[int] = 20,
    presence_penalty: Optional[float] = None,
    presence_context_size: Optional[int] = 20,
    frequency_penalty: Optional[float] = None,
    frequency_context_size: Optional[int] = 20,
) -> List[Callable[[mx.array, mx.array], mx.array]]
```

> ✅ **VERIFIED** — `mlx_lm/sample_utils.py`.

The individual factories are also public: `make_repetition_penalty(penalty, context_size=20)`
(sign-aware and *multiplicative*, following arXiv:1909.05858), `make_presence_penalty` (additive,
subtracted once per distinct token), `make_frequency_penalty` (additive per occurrence, implemented
as `logits.at[:, tokens].subtract(penalty)`). `logit_bias` is `logits.at[:, indices].add(values)`.

**The processor contract is the part people get wrong.** A processor is:

```python
processor(tokens: mx.array, logits: mx.array) -> mx.array
```

where `logits` has shape `(batch, vocab)` — **always two-dimensional, even for a single
sequence** — and `tokens` is the token history.

> ✅ **VERIFIED** — the test
> `test_batch_generate_processor_tokens_match_prompt_on_first_step` asserts that the **first call
> receives the whole prompt** as an `mx.array`. So `tokens` is not "the tokens generated so far";
> on step one it is the prompt. Write processors that handle both.

Sampler and processors compose like this — the processors run first, on raw logits; the sampler
runs last, on log-probs:

```python
def _process_and_sample(tokens, logits):
    if logits_processors:
        for processor in logits_processors:
            logits = processor(tokens, logits)
    logprobs = logits - mx.logsumexp(logits, axis=-1, keepdims=True)
    y = sampler(logprobs)
    return y, logprobs
```

> ✅ **VERIFIED** — quoted from `mlx_lm/generate.py`'s `speculative_generate_step`; the
> non-speculative path is structurally identical. **Your processor sees logits. Your sampler sees
> log-probs.** Getting that backwards produces plausible-looking but wrong distributions.

### 3.8 A complete script

Everything above, in one runnable file. This is the shape most production callers should start
from: streaming, an explicit sampler, explicit processors, a progress callback for the prefill, and
a cache you own.

```python
#!/usr/bin/env python3
"""Streaming generation with an explicit sampler, processors, and a reusable cache.

Requires: mlx-lm >= 0.31.3 (tested against main @ e5baded), Python >= 3.10.
"""
from __future__ import annotations

import sys

import mlx.core as mx
from mlx_lm import load, stream_generate
from mlx_lm.models.cache import make_prompt_cache
from mlx_lm.sample_utils import make_logits_processors, make_sampler

MODEL = "mlx-community/Qwen3-8B-4bit"


def main() -> int:
    model, tokenizer = load(MODEL)

    # Own the cache explicitly so it survives across turns (see §4).
    prompt_cache = make_prompt_cache(model)

    sampler = make_sampler(
        temp=0.7,
        top_p=0.95,
        min_p=0.02,
        top_k=50,
        xtc_probability=0.1,
        xtc_threshold=0.15,
        # Never let XTC suppress newlines or EOS. Copy this line verbatim.
        xtc_special_tokens=tokenizer.encode("\n") + list(tokenizer.eos_token_ids),
    )

    processors = make_logits_processors(
        repetition_penalty=1.1,
        repetition_context_size=64,
    )

    def on_prefill(processed: int, total: int) -> None:
        print(f"\rprefill {processed}/{total}", end="", file=sys.stderr, flush=True)

    turns = [
        "In two sentences, what is a KV cache?",
        "Now explain why a sliding-window cache breaks prefix reuse.",
    ]

    for turn in turns:
        prompt = tokenizer.apply_chat_template(
            [{"role": "user", "content": turn}],
            add_generation_prompt=True,
        )

        last = None
        for response in stream_generate(
            model,
            tokenizer,
            prompt,
            max_tokens=512,
            sampler=sampler,
            logits_processors=processors,
            prompt_cache=prompt_cache,          # reused across turns
            prefill_step_size=2048,
            prompt_progress_callback=on_prefill,
        ):
            print(response.text, end="", flush=True)
            last = response

        # `last` is the final response; it is the only one carrying finish_reason.
        assert last is not None
        print(
            f"\n[{last.finish_reason}] "
            f"prompt {last.prompt_tokens} tok @ {last.prompt_tps:.1f} tok/s · "
            f"gen {last.generation_tokens} tok @ {last.generation_tps:.1f} tok/s · "
            f"peak {last.peak_memory:.2f} GB\n",
            file=sys.stderr,
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

Three things this script demonstrates that a three-line example cannot:

**The cache is passed in and reused across turns.** Turn two does not re-prefill turn one. That is
the whole subject of §4 and §5, and it is one keyword argument.

**`last` is captured, not the loop variable at exit.** In Python the loop variable does survive the
loop, so `response` would also work — but naming it `last` documents the intent, and it will not
silently become `None` if you later wrap the loop in a function that returns early.

**The prefill callback goes to `stderr`.** `stdout` is the model's output. Mixing them is how you
end up with progress bars in your evaluation corpus.

> ⚠️ **`stream_generate(..., max_tokens=0)` raises `UnboundLocalError`.** `generate_step` breaks
> before yielding anything, so `token`, `n` and `prompt_tps` are never bound when the final
> `yield GenerationResponse(...)` executes. If you want prefill *only* — to warm a cache and
> generate nothing — call `generate_step` directly and drain the empty generator, exactly as
> `mlx_lm/cache_prompt.py` does. §5.2 shows the pattern.

---

## 4. KV caching: the nine cache classes

This is the section the rest of the guide exists to support. Every performance decision, every
"why is this model refusing speculative decoding", every silent-corruption bug in the tracker
traces back to *which cache class got constructed and what contract it honours*.

### 4.1 Why there are nine of them

A KV cache is conceptually trivial: keep the keys and values you already computed so the next token
does not recompute them. The reason mlx-lm has nine concrete implementations is that four
independent axes cut across that idea:

1. **Growth strategy.** Concatenate every step (simple, quadratic allocation churn) versus
   preallocate in blocks (fast, more code).
2. **Boundedness.** Unbounded (memory grows with context) versus a ring buffer with a fixed window
   (memory capped, but old tokens are gone forever).
3. **Numeric format.** Full precision versus block-quantized keys and values.
4. **Batching.** One sequence versus many left-padded sequences sharing one tensor.

Cross those and you get most of the class list. The rest exist because **not every model has a KV
cache at all** — state-space and linear-attention layers carry a *running state*, not a positional
history — and because **hybrid models have both kinds of layer in the same stack**.

Here is the complete inventory, read from `mlx_lm/models/cache.py` (1,764 lines) this session.

> ✅ **VERIFIED** — class list and line numbers from `mlx_lm/models/cache.py` at commit `e5baded`.

| # | Class | Lines | What it is for | `is_trimmable()` | `to_quantized()` | batch `merge` |
|---|---|---|---|---|---|---|
| — | `_BaseCache` | 127–177 | ABC: `state`, `meta_state`, `size()`, `nbytes`, `empty()`, `from_state` | **`False`** (the default!) | — | — |
| 1 | `ConcatenateKVCache` | 178–231 | Simplest possible: `mx.concatenate` on every step | `True` | — | — |
| 2 | `QuantizedKVCache` | 232–324 | Packed `uint32` data + scales + biases. `group_size=64, bits=8` | `True` | — | — |
| 3 | `KVCache` | 325–409 | **The default.** Growable buffer, `step = 256` | `True` | ✅ `(group_size=64, bits=4)` | ✅ → `BatchKVCache` |
| 4 | `RotatingKVCache` | 410–593 | Ring buffer with `max_size` and `keep` sink tokens | **`offset < max_size` only** | ❌ raises | ✅ → `BatchRotatingKVCache` |
| 5 | `ArraysCache` | 594–730 | Generic slot list for SSM / Mamba / linear-attention state | **`False`** (inherited) | — | ✅ |
| 6 | `ChunkedKVCache` | 731–813 | Keeps only the last `chunk_size`, tracks `start_position` | `True` | — | — |
| 7 | `CacheList` | 814–911 | Composite for hybrid stacks (attention + SSM layers) | `all(...)` | — | ✅ |
| 8 | `BatchKVCache` | 912–1132 | Left-padded batched KV | `True` | — | classmethod `merge` |
| 9 | `BatchRotatingKVCache` | 1133–1486 | Batched sliding window | **`_offset < max_size`** | ❌ raises | classmethod `merge` |
| — | `TokenBuffer` | 1487–1523 | Append-efficient int32 token buffer for logits processors — **not a KV cache** | — | — | — |

Nine concrete caches, one abstract base, one buffer that is filed here because logits processors
need it.

### 4.2 The trimmability contract, and why it is the load-bearing property

Almost everything interesting depends on one question: **can this cache be rewound?**

```python
def can_trim_prompt_cache(cache: List[Any]) -> bool:
    """Check if model's cache can be trimmed."""
    return all(c.is_trimmable() for c in cache)


def trim_prompt_cache(cache: List[Any], num_tokens: int) -> List[Any]:
    """
    Trim the model's cache by the given number of tokens.

    This function will trim the cache if possible (in-place) and return the
    number of tokens that were trimmed.
    """
    if not can_trim_prompt_cache(cache) or len(cache) == 0:
        return 0
    return [c.trim(num_tokens) for c in cache][0]
```

> ✅ **VERIFIED** — `mlx_lm/models/cache.py:88-111`, quoted verbatim.

Read that carefully, because three things in eleven lines matter:

**The return annotation is wrong.** It says `-> List[Any]`; the docstring and the code both return
an `int`. Do not write `for n in trim_prompt_cache(...)`. This is a cosmetic bug, but it will
mislead a type checker and any reader who trusts annotations over docstrings.

**It returns `0` — not an error — when the cache is not trimmable.** `trim_prompt_cache` on an
`ArraysCache`-bearing model silently does nothing and reports zero. Callers that ignore the return
value proceed as if the rewind happened. This is exactly the bug class that bit MLX Swift (§9.6).

**It reports only the *first* layer's trim count.** `[c.trim(num_tokens) for c in cache][0]` trims
every layer and returns layer zero's answer. For a homogeneous stack that is fine. For a hybrid
model where different layers can trim different amounts, it is an assumption — and
`CacheList.trim` compounds it by returning the **last** sub-cache's count:

```python
def trim(self, n):
    for c in self.caches:
        m = c.trim(n)
    return m
```

> ✅ **VERIFIED** — `cache.py:824-827`.

Now the per-class trim semantics, all read from source:

| Class | `is_trimmable()` | `trim(n)` clamps to |
|---|---|---|
| `_BaseCache` (default) | `return False` | — |
| `ConcatenateKVCache` | `True` | `min(self.offset, n)` |
| `QuantizedKVCache` | `True` | `min(self.offset, n)` |
| `KVCache` | `True` | `min(self.offset, n)` |
| `RotatingKVCache` | `self.offset < self.max_size` | `min(self.offset, n)`, also decrements `_idx` |
| `ChunkedKVCache` | `True` | `min(self.offset - self.start_position, n)` |
| `ArraysCache` | inherits `False` | n/a |
| `CacheList` | `all(c.is_trimmable() …)` | delegates; returns the **last** result |
| `BatchKVCache` | `True` | `min(self.offset, n)` |
| `BatchRotatingKVCache` | `self._offset < self.max_size` | delegated |

Two consequences worth stating loudly.

**`RotatingKVCache` stops being trimmable the moment the window wraps.** `is_trimmable()` is
`self.offset < self.max_size`, and `offset` only ever grows. So a sliding-window model is
trimmable right up until it is not, and the transition happens silently in the middle of a long
conversation. Everything that needs trimming — speculative decoding, server prefix reuse — quietly
changes behaviour at that boundary.

**Anything built on `ArraysCache` is never trimmable.** `ArraysCache` does not override
`is_trimmable`, so it inherits `_BaseCache`'s `return False`. That covers Mamba, SSM, RWKV and
gated-delta / linear-attention layers, which means the entire class of hybrid 2026 architectures —
Qwen3.5, Qwen3.6, LFM2, Granite hybrids, Kimi Linear, Nemotron-H — cannot rewind their state. This
is the same structural fact that C5 in our corrections register records on the Core AI side, where
`trimKVCache` returns `-1` whenever `extraStates` is non-empty. **It is not an MLX limitation; it is
a property of running a recurrent scan instead of storing positional history.** A scan cannot be
un-run.

### 4.3 `make_prompt_cache` — where the class actually gets chosen

You almost never construct a cache class by name. You call this:

```python
def make_prompt_cache(
    model: nn.Module,
    max_kv_size: Optional[int] = None,
) -> List[Any]:
    """
    Construct the model's cache for use in generation.

    This function will defer the cache construction to the model if it has a
    ``make_cache`` method, otherwise it will make a default KV cache.
    """
    if hasattr(model, "make_cache"):
        return model.make_cache()

    num_layers = len(model.layers)
    if max_kv_size is not None:
        return [
            RotatingKVCache(max_size=max_kv_size, keep=4) for _ in range(num_layers)
        ]
    else:
        return [KVCache() for _ in range(num_layers)]
```

> ✅ **VERIFIED** — `mlx_lm/models/cache.py:15-40`, quoted verbatim including the docstring.

Three branches, and the first one dominates:

**If the model defines `make_cache()`, `max_kv_size` is ignored entirely.** Read that line again:
`if hasattr(model, "make_cache"): return model.make_cache()` — the `max_kv_size` argument is never
consulted. **41 of the 121 model files in `mlx_lm/models/` define `make_cache`**, and they are
exactly the interesting ones: everything with sliding-window attention, everything with SSM or
gated-delta layers, everything hybrid. So on a modern architecture, `--max-kv-size 4096` may do
nothing at all, and nothing tells you.

> ✅ **VERIFIED** — the `hasattr` early return is in the source above; the count of 41 files
> defining `make_cache` is from a grep over all 121 `mlx_lm/models/*.py` recorded in
> `notes/repos/mlx-lm.md`.

**If it does not, and you passed `max_kv_size`, you get `RotatingKVCache(max_size=…, keep=4)`.**
Note `keep=4`: the first four tokens are pinned as attention sinks and never overwritten. That
default is load-bearing in a bad way — see §6.4, where `keep > 0` is precisely what blocks KV
quantization, and §8.3, where it is precisely what blocks batching.

**Otherwise you get a plain `KVCache()` per layer.** Unbounded, `step = 256`, quantizable,
batchable, trimmable. The easy case.

### 4.4 `KVCache` — the default, and why `step = 256` matters

`KVCache` preallocates its buffer in 256-token blocks and writes into it with `slice_update`,
rather than concatenating a new array every step.

That is not a micro-optimisation. It is a workaround for an allocator behaviour that bites
everything else:

> ✅ **VERIFIED** — from `notes/repos/issues-mlx-stack.md:129`, summarising mlx#3896:
> *"mlx-lm's Python `KVCache` avoids this by preallocating in 256-step chunks with `slice_update`.
> **C++/Swift/custom cache authors must do the same.** Nothing in the docs warns about this."*
> The failure it avoids is unbounded memory-pool growth under jittered allocation sizes — every
> step allocating a slightly larger buffer fragments the pool.

If you write a custom cache class — and §4.9 explains when you might — **copy the block-growth
strategy**. `ConcatenateKVCache` exists in the tree as the simplest correct implementation, not as
the one you should use.

There is a second, subtler memory issue that block growth does *not* fix:

> ✅ **VERIFIED** — mlx-lm#1332 (closed 2026-08-27 and consolidated into #1662; not established fixed), via `notes/repos/issues-mlx-stack.md:131-139`: unbounded
> live-buffer growth from **lazy graph retention** in caches. `RotatingKVCache._update_in_place`
> and the `Batch*` variants chain identically via sliced functional assignment. The practical
> consequence is that the cache's arrays can retain a graph of every update until something forces
> an eval — which is exactly why `generate_step` calls `mx.eval([c.state for c in prompt_cache])`
> after each prefill chunk. **If you drive `generate_step`'s internals yourself, keep those evals.**

### 4.5 `RotatingKVCache` — bounded memory, and everything it costs you

A ring buffer of `max_size` positions with `keep` pinned sink tokens at the front, plus a
`_temporal_order()` reordering so that attention sees positions in the right sequence after the
buffer wraps.

You reach for it when memory is the binding constraint and you can accept losing old context:

```bash
mlx_lm.generate --model mlx-community/Qwen3-8B-4bit --prompt - < book.txt --max-kv-size 4096
```

What it costs:

| Capability | With `KVCache` | With `RotatingKVCache` |
|---|---|---|
| Memory | grows with context | capped at `max_size` |
| Old context | retained | **overwritten, unrecoverably** |
| Trimmable | always | **only while `offset < max_size`** |
| KV quantization | ✅ | ❌ `NotImplementedError` |
| Speculative decoding | ✅ | ❌ once the window wraps |
| Batching | ✅ | ✅ **only if `keep == 0`** |
| Prefix reuse in the server | ✅ | degraded — see §5.5 |

That table is the single best argument for reading this section before you reach for
`--max-kv-size`. It looks like a memory flag. It is a capability flag.

### 4.6 `ChunkedKVCache` — and a correctness caveat

`ChunkedKVCache(chunk_size)` keeps only the last `chunk_size` positions and tracks a
`start_position`, which is why its trim clamps to `min(self.offset - self.start_position, n)`
rather than `min(self.offset, n)`. It exists for chunked-attention architectures — Llama 4 is the
canonical consumer.

> ⚠️ **`ChunkedKVCache` and `ConcatenateKVCache` violate an assumption the server's prompt cache
> makes.** From mlx-lm#1494 (administratively closed without a fix 2026-08-21): `LRUPromptCache.fetch_nearest_cache` assumes (1) a stored
> cache's KV corresponds exactly to its token key and (2) `is_trimmable() == True` implies
> `trim(n)` removes exactly the suffix. **`KVCache` satisfies both; `ChunkedKVCache` and
> `ConcatenateKVCache` do not**, and nothing verifies it at reuse time. See §9.5 — this is a
> full silent-failure callout.

### 4.7 `ArraysCache` and `CacheList` — the hybrid-model story

`ArraysCache(size, left_padding=None)` is not a KV cache. It is a list of `size` slots holding
whatever recurrent state a layer needs: an SSM state matrix, a convolution window, a gated-delta
accumulator. It has no notion of position, which is why it is not trimmable.

`CacheList(*caches)` composes: a hybrid model's `make_cache()` returns a mixture, and `CacheList`
lets a single layer hold several sub-caches (say, a conv state and an SSM state).

The practical shape of a 2026 hybrid stack, from a real bug report:

> ✅ **VERIFIED** — mlx-lm#1480 (OPEN), community-measured: Qwen3.6-35B-A3B-4bit on a 128 GB Mac,
> **only 10 of 40 layers have a full KV cache**; the other 30 are `ArraysCache(size=2)`
> GatedDeltaNet layers. (That issue is about a Metal OOM at ~176K tokens during prefill, which the
> reporter attributes to transient prefill workspace rather than KV size — see §6.2 for why that is
> a plausible mechanism.)

So: 75% of that model's layers are non-trimmable. `can_trim_prompt_cache` returns `False` for the
whole stack. That single fact removes speculative decoding (§7.3), removes server-side prefix
rewinding (§5.5), and is *why* the 2026 hybrids feel different to operate than a 2024 dense Llama.

Read `mlx_lm/models/laguna.py` — the newest architecture in the tree, added at HEAD — if you want a
template for how these stacks are declared: per-layer `layer_types` of `full_attention` or
`sliding_attention`, per-layer `mlp_layer_types` of `dense` or `sparse`, and a nested
`rope_parameters` schema keyed by layer type.

### 4.8 The decision rule: which cache for which workload

This is the table to keep.

| Your workload | Cache you want | How to get it | Watch out for |
|---|---|---|---|
| One-shot generation, short prompt | `KVCache` | default; do nothing | — |
| Multi-turn chat, context fits in RAM | `KVCache`, **reused across turns** | `make_prompt_cache(model)` once, pass every turn | the cache is mutated in place |
| Long document, memory-bound | `RotatingKVCache` | `--max-kv-size N` | loses old context; kills quantized KV, spec decoding, and batching-with-`keep` |
| Long *shared* prefix, many queries | `KVCache` + **disk prompt cache** | §5 | model and `--kv-bits` must match the saved file exactly |
| Context capacity is the constraint | `QuantizedKVCache` | `--kv-bits 8 --quantized-kv-start N` | **peak memory can go up**, §6.2; not for sliding-window models; not for attention-sink models |
| Many concurrent requests | `BatchKVCache` / `BatchRotatingKVCache` | `batch_generate` / server | `RotatingKVCache(keep>0)` is rejected |
| Speculative decoding | `KVCache` only | §7 | anything non-trimmable is refused with a `ValueError` |
| SSM / hybrid / linear-attention model | whatever `model.make_cache()` gives you | automatic | not trimmable — plan around it |
| Writing your own | subclass with block growth | §4.9 | must live in `cache.py` to round-trip through a file |

And the negative rule, stated once so it is easy to find: **`--max-kv-size` and `--kv-bits`
together will fail on any model that ends up with a `RotatingKVCache`.** §6.4.

### 4.9 Writing a custom cache — and the one thing that will break it

The contract is `_BaseCache`: implement `state` (a getter and a setter), `meta_state` (a tuple of
strings), `size()`, `nbytes`, `empty()`, the classmethod `from_state`, `is_trimmable()`, `trim(n)`,
and `make_mask(...)`. Add `to_quantized(group_size, bits)` if it can be quantized, and a `merge`
classmethod if it can be batched — the server literally probes for batchability with
`all(hasattr(c, "merge") for c in make_prompt_cache(model))`.

> ⚠️ **A custom cache class cannot round-trip through `save_prompt_cache` / `load_prompt_cache`.**
> The loader reconstructs by name out of the *module's* globals:
>
> ```python
> cache = [
>     globals()[c].from_state(state, meta_state)
>     for c, state, meta_state in zip(classes, arrays, info)
> ]
> ```
>
> ✅ **VERIFIED** — `mlx_lm/models/cache.py:62-86`. `globals()` there is `mlx_lm.models.cache`'s
> namespace. **Only classes defined in that file can be loaded back.** Your class saves fine and
> fails on load with a `KeyError` on its own name. **Safe default:** if you need persistence,
> either subclass one of the shipped classes and save it *as* the parent's `state`/`meta_state`
> shape, or persist your state yourself in a separate file.

---

## 5. Prompt caching to disk

### 5.1 Why this is transformative and not merely convenient

Prefill is quadratic-ish in prompt length and linear in nothing you control. If you are asking
fifty questions about the same 30,000-token document, the naive loop pays for that document fifty
times. Prompt caching pays for it once.

The magnitude is worth being concrete about, and there is a directly measured figure in our corpus
from the Core AI side of the house — the same mechanism, a different runtime:

> ✅ **VERIFIED, community-measured** (`notes/repos/john-rocky-models.md`, recorded in C5 of our
> corrections register): turn-2 time-to-first-token **23.28 s → 0.230 s, a 101× improvement**, at
> 4K context with **byte-identical greedy output**; 15.2× at 357 tokens on qwen3-0.6b, on a Mac.
> Attribute as community-measured; exact hardware and OS build not stated in the source.
>
> The mechanism there is that trimming a KV cache is *a single integer assignment* — nothing is
> cleared, only the processed-token count rewinds — and it is free because attention is causal, so
> rows at or beyond the retained position get overwritten before any query can read them.

mlx-lm's `KVCache.trim` is exactly that:

```python
def trim(self, n):
    n = min(self.offset, n)
    self.offset -= n
    return n
```

> ✅ **VERIFIED** — `mlx_lm/models/cache.py:378-381`. One subtraction. That is the whole rewind.

Two orders of magnitude on repeated long prefixes, for one flag. That is why this section exists.

### 5.2 `mlx_lm.cache_prompt` — build the cache file

```bash
cat book.txt | mlx_lm.cache_prompt \
  --model mistralai/Mistral-7B-Instruct-v0.3 \
  --prompt - \
  --prompt-cache-file book.safetensors
```

Flags: `--model` (default `mlx_model`), `--adapter-path`, `--trust-remote-code`, `--eos-token`,
`--max-kv-size`, **`--prompt-cache-file` (required)**, **`--prompt` (required; `-` = stdin)**,
`--kv-bits`, `--kv-group-size` (64), `--quantized-kv-start` (5000).

> ✅ **VERIFIED** — argparse read from `mlx_lm/cache_prompt.py` this session.

Internally it does the thing §3.8 warned you about — it drives `generate_step` directly with
`max_tokens=0` and drains the empty generator, then saves:

```python
save_prompt_cache(file, cache, metadata)
# metadata = {"model": args.model, "tokenizer_config": json.dumps(tokenizer_config)}
```

and it applies the chat template with `add_generation_prompt=False, continue_final_message=True`,
so the cached prefix ends *inside* the user turn rather than at a generation boundary. That detail
is what makes the `--prompt "\nSummarize…"` continuation in §5.3 work.

### 5.3 `--prompt-cache-file` — use it

```bash
mlx_lm.generate --prompt-cache-file book.safetensors \
                --prompt "\nSummarize chapter 3."
mlx_lm.generate --prompt-cache-file book.safetensors \
                --prompt "\nList every character introduced after chapter 5."
```

Note there is **no `--model`** on those commands. The model is read from the cache metadata. If you
pass one and it disagrees, you get a hard error, verbatim:

```
ValueError: Providing a different model ({model_path}) than that used to create
the prompt cache ({metadata['model']}) is an error.
```

> ✅ **VERIFIED** — `mlx_lm/generate.py:2093-2103`, read this session.

The same applies to KV quantization settings: **`--kv-bits` and `--kv-group-size` must match the
saved cache exactly** or you get an error. That strictness is a feature. A prompt cache is a
snapshot of a specific model's internal state at a specific numeric format; there is no meaningful
way to reinterpret it.

### 5.4 The `<query>` trick — how the suffix gets isolated

Here is the part that is genuinely clever and that nobody documents. When you use a prompt cache
*together with* a chat template, mlx-lm has to work out which part of the newly rendered prompt is
"new" — because the template wraps your text in role markers that are already in the cache.

It solves this by rendering the template twice:

```python
# Treat the prompt as a suffix assuming that the prefix is in the
# stored kv cache.
if using_cache:
    messages[-1]["content"] = "<query>"
    test_prompt = tokenizer.apply_chat_template(
        messages,
        tokenize=False,
        continue_final_message=has_prefill,
        add_generation_prompt=not has_prefill,
    )
    prompt = prompt[test_prompt.index("<query>") :]
prompt = tokenizer.encode(prompt, add_special_tokens=False)
```

> ✅ **VERIFIED** — `mlx_lm/generate.py:2138-2149`, quoted verbatim including the comment.

Render once with the real content; render again with the content replaced by the literal string
`"<query>"`; find where `<query>` lands in the second rendering; slice the first rendering from
that index. The result is the suffix and only the suffix, and it is then encoded with
`add_special_tokens=False` so no BOS gets re-inserted mid-sequence.

It is a string-index trick and it works, but it has a sharp edge worth knowing: **it depends on the
template rendering deterministically.** A template that injects a timestamp, a random ID, or a
tool list that differs between the two renderings will produce a `test_prompt` whose prefix does
not match `prompt`'s prefix, and the slice will be wrong — silently, because
`str.index("<query>")` will still succeed.

> 🔴 **GAP — how mlx-lm behaves with a non-deterministic chat template plus a prompt cache.** We
> read the code path but did not execute it. **What is unknown:** whether any shipped template
> actually is non-deterministic, and what the failure looks like in practice. **What would resolve
> it:** running `mlx_lm.generate --prompt-cache-file …` against a template that injects
> `strftime`, and diffing the sliced prompt against the expected suffix. **Safe default:** for
> cached workflows, prefer templates without dynamic content, and pass tool lists identically on
> every call.

### 5.5 The server's prompt cache: `PromptTrie` and `LRUPromptCache`

`mlx_lm.server` does the same thing automatically and in memory, keyed by token prefix.

```python
@dataclass
class PromptTrieResult:
    model: Any
    exact: Optional[List[int]]      # an exact match
    shorter: Optional[List[int]]    # longest stored prefix of these tokens
    longer: Optional[List[int]]     # shortest stored sequence extending beyond these tokens
    common_prefix: int
```

> ✅ **VERIFIED** — `mlx_lm/models/cache.py:1524-1531`. `PromptTrie` exposes `add(model, tokens,
> value)`, `get`, `pop`, `pop_prefixes`, `search`.

```python
class LRUPromptCache:
    def __init__(self, max_size: int = 10, max_bytes: int = 1 << 63)
    def fetch_nearest_cache(self, model, tokens) -> (cache_or_None, remaining_tokens)
    def insert_cache(self, model, tokens, prompt_cache, *, cache_type: str = "assistant")
    def trim_to(self, *, n_sequences=None, n_bytes=None)
    def stats_by_type(self) -> {cache_type: {"n_sequences": int, "n_bytes": int}}
    nbytes  # property
```

> ✅ **VERIFIED** — `mlx_lm/models/cache.py:1623-1764`; the `__init__` signature is at line 1659.
> `--prompt-cache-size` maps to `max_size`, `--prompt-cache-bytes` to `max_bytes`.

The clever part is that a *longer* stored sequence can serve a *shorter* request, by rewinding:

```python
cache = copy.deepcopy(cache_entry.prompt_cache)
prefix = min(len(tokens) - 1, result.common_prefix)
trim_prompt_cache(cache, len(result.longer) - prefix)
return cache, tokens[prefix:]
```

> ✅ **VERIFIED** — `LRUPromptCache.fetch_nearest_cache`. This only works when the cache is
> trimmable, which is §4.2's contract doing real work in production.

Eviction is ordered by *cache type*, not purely by recency:

```python
CacheOrder(ordering=["assistant", "user", "system"])
```

> ✅ **VERIFIED** — `cache.py:1631`. `pop()` evicts from the earlier category while it holds at
> least as many entries as the next — so assistant caches are dropped before user caches, and user
> before system. That is the right priority: system prompts are the longest-lived shared prefix.

The server splits each chat prompt into up to **three segments** — system prompt, user context, and
a thinking tail (it looks back up to 11 tokens for a `think_start`) — with `segment_types`
`["system", "user", "assistant"]`, and stores each boundary's KV under the corresponding
`cache_type`. That is what makes the type-ordered eviction meaningful.

Three open defects and one administratively closed defect, all community-reported, are worth knowing before you tune
`--prompt-cache-size` upward:

| Issue | Symptom | Status |
|---|---|---|
| mlx-lm#1494 | Reuse can return KV that does not match the keyed prefix, for `ChunkedKVCache` / `ConcatenateKVCache`. Silently wrong output, and the bad state gets re-stored under the new key. | Administratively closed without a fix 2026-08-21; repro script in-thread |
| mlx-lm#1495 | `PromptTrie.search` has an off-by-one (`if last_index > 0` should be `>= 0`), so **one-token prefixes never match**; and `fetch_nearest_cache` never touches `self._lru`, so **eviction is FIFO, not LRU** | OPEN |
| mlx-lm#1395 | `fetch_nearest_cache` **deep-copies** the cached KV, doubling peak memory exactly when a cached conversation is reused | OPEN |
| mlx-lm#1390 | Server aborts with a Metal `Insufficient Memory` command-buffer failure after the prompt cache grew to **23.35 GB / 26.28 GB** | OPEN |

> ✅ **VERIFIED** — issue numbers, quoted symptoms and status from
> `notes/repos/issues-mlx-stack.md:631-650` and `:145-146`. Reported configuration for #1390:
> Qwen3.5-4B-8bit on 48 GB, macOS 27.0 (build 26A5353q), Python 3.14.6, mlx-lm 0.31.3,
> huggingface_hub 1.18.0. Community-measured.

**Practical guidance that falls out of those four:** set `--prompt-cache-bytes` explicitly. The
default `max_bytes` is `1 << 63` — effectively unbounded — and `--prompt-cache-size 10` bounds the
*number* of caches, not their size. Ten caches of a 100K-token conversation is not ten small
things. `--prompt-cache-bytes 8GB` is a much better guardrail than `--prompt-cache-size 20`.

### 5.6 Multi-turn caching in Python, without files

The in-process version — this is `mlx_lm/examples/chat.py`, verbatim from the repo:

```python
from mlx_lm import generate, load
from mlx_lm.models.cache import load_prompt_cache, make_prompt_cache, save_prompt_cache

model, tokenizer = load("mlx-community/Mistral-7B-Instruct-v0.3-4bit")
prompt_cache = make_prompt_cache(model)

prompt = tokenizer.apply_chat_template(
    [{"role": "user", "content": "Hi my name is <Name>."}],
    add_generation_prompt=True,
)
response = generate(model, tokenizer, prompt=prompt, verbose=True, prompt_cache=prompt_cache)

prompt = tokenizer.apply_chat_template(
    [{"role": "user", "content": "What's my name?"}],
    add_generation_prompt=True,
)
response = generate(model, tokenizer, prompt=prompt, verbose=True, prompt_cache=prompt_cache)

save_prompt_cache("mistral_prompt.safetensors", prompt_cache)
prompt_cache = load_prompt_cache("mistral_prompt.safetensors")
```

> ✅ **VERIFIED** — `mlx_lm/examples/chat.py`, reproduced verbatim.

The mechanism: `prompt_cache` is **updated in place** by `generate_step`. Turn two's
`apply_chat_template` renders only the new user message, and because the cache already holds turn
one, the model sees a continuation. The second turn answers "What's my name?" correctly, which
only works because the cache carried the first turn's KV.

**The in-place mutation is the API contract and the footgun.** `generate_step`'s docstring says
*"Note, if provided, the cache will be updated in place."* If you want a checkpoint, you must
`copy.deepcopy` it, and §5.5's mlx-lm#1395 tells you what that costs.

### 5.7 The serialization format

```python
def save_prompt_cache(file_name: str, cache: List[Any], metadata: Dict[str, str] = {}):
    cache_data = [c.state for c in cache]
    cache_info = [c.meta_state for c in cache]
    cache_data = dict(tree_flatten(cache_data))
    cache_classes = [type(c).__name__ for c in cache]
    cache_metadata = [cache_info, metadata, cache_classes]
    cache_metadata = dict(tree_flatten(cache_metadata))
    mx.save_safetensors(file_name, cache_data, cache_metadata)
```

> ✅ **VERIFIED** — `mlx_lm/models/cache.py:43-60`, quoted verbatim.

A prompt cache file is a plain **`.safetensors`** whose tensors are the flattened per-layer states
and whose metadata carries three flattened structures: the per-layer `meta_state`, your
user metadata, and the list of **class names**. Loading reverses it via
`globals()[class_name].from_state(...)` — hence §4.9's constraint.

Practical consequences:

- **A prompt cache file is roughly the size of the KV it holds.** For a 30K-token prompt on an 8B
  model that is gigabytes. Budget disk accordingly, and consider `--kv-bits 8` at cache-build time
  (which halves it, at the cost of pinning the reader to the same setting).
- **It is inspectable.** `mx.load(path, return_metadata=True)` will show you the class names and
  offsets without a model. Useful when debugging a mismatch.
- **`--kv-bits` is baked in.** A cache built with `--kv-bits 8` contains `QuantizedKVCache`
  instances; reading it with different settings errors.

---

## 6. Quantized KV: capacity, not throughput

### 6.1 What it is and how to turn it on

`QuantizedKVCache` stores keys and values as packed `uint32` data plus per-group scales and biases.
Defaults are `group_size=64, bits=8`. `KVCache.to_quantized`'s own defaults are
`group_size=64, bits=4`.

```bash
mlx_lm.generate --model mlx-community/Qwen3-8B-4bit --prompt - < long.txt \
                --kv-bits 8 --kv-group-size 64 --quantized-kv-start 2048
```

```python
for r in stream_generate(model, tokenizer, prompt, max_tokens=512,
                         kv_bits=8, kv_group_size=64, quantized_kv_start=2048):
    ...
```

The switch happens lazily, per layer, when that layer's cache passes the threshold:

```python
def maybe_quantize_kv_cache(prompt_cache, quantized_kv_start, kv_group_size, kv_bits):
    if kv_bits is None:
        return
    for e, c in enumerate(prompt_cache):
        if hasattr(c, "to_quantized") and c.offset >= quantized_kv_start:
            prompt_cache[e] = c.to_quantized(group_size=kv_group_size, bits=kv_bits)
```

> ✅ **VERIFIED** — `mlx_lm/generate.py:290-295`, quoted verbatim. Note it **replaces the list
> element** rather than mutating the object. That is fine here because `prompt_cache` is the same
> list object throughout — but it is precisely the pattern that produced a serious silent bug in
> the Swift port (§9.6).

### 6.2 The counter-intuitive part: peak memory can go *up*

This is the finding that changes how you should use the flag, and it is one of the best-documented
investigations in the mlx-lm tracker.

> ✅ **VERIFIED, community-measured** — mlx-lm#1587 (OPEN, 11 comments), via
> `notes/repos/issues-mlx-stack.md:496-541`. Reported on **Llama-3.2-3B-Instruct-4bit, M4 Max
> 128 GB, macOS 27.0**:

| Context | Case | Peak MLX memory | Decode speed |
|---|---|---|---|
| 8,000 tok | fp16 | 3.46 GB | 3.2 tok/s |
| 8,000 tok | q8 | **4.87 GB (+1.41 GB)** | 2.6 tok/s |
| 32,000 tok | fp16 | 4.72 GB | 1.0 tok/s |
| 32,000 tok | q8 | **7.10 GB (+2.38 GB)** | 0.7 tok/s |
| 32,000 tok | q4 | **6.53 GB (+1.81 GB)** | 0.6 tok/s |

Independently reproduced on an **M5 128 GB with Qwen3-0.6B bf16**: 32,768 context → fp16 5.53 GB,
kv8 **9.56 GB (+73%)**, kv4 9.09 GB.

The thread then did what almost no bug report does: it pre-registered a discriminator between two
hypotheses and ran it on two rigs.

**It is not cache resize churn.** Presizing the cache — `c.step = <prompt + decode, rounded to
256>`, since `step` is a *class attribute* on `QuantizedKVCache` — eliminated every resize and
closed only **1.5% (M1)** / **3.8% (M5 Max)** of the gap.

**It is the unfused quantized-attention path.** The chunk-size sweep at 8,192 context:

| `prefill_step_size` | quantized peak | fp16 peak (control) |
|---|---|---|
| 512 | **3.072 GB** | 3.175 GB |
| 1024 | 3.821 GB | 3.290 GB |
| 2048 (default) | 4.288 GB | 3.284 GB |

with a quantitative prediction that landed:

> *"The predicted size of one layer's scores tensor (`n_kv_heads × n_repeats × L_chunk × context ×
> 4 bytes`, 8×3×128 head config) gives a predicted delta between chunk 2048 and 512 of 1.208 GB;
> measured delta is 1.216 GB. That's the mechanism, not just consistent with it."*

**So the actionable mitigation is `--prefill-step-size`, not `--kv-bits`.** At chunk 512 the
inversion disappears entirely. You trade prefill latency for a much lower quantized-attention peak.

```bash
# If --kv-bits made your memory worse, this is the fix.
mlx_lm.generate --model M --prompt - < long.txt \
                --kv-bits 8 --quantized-kv-start 2048 --prefill-step-size 512
```

A negative finding from the same thread that will save you a weekend: **a naive blockwise /
online-softmax quantized attention written in Python is worse, not better**, because MLX's lazy
evaluation keeps every block's intermediates alive until the final eval. Forcing `mx.eval` per
block fixes the memory (5.620 GB → 2.856 GB at block size 256) but costs roughly 2× prefill
latency. The real fix is a fused quantized-SDPA Metal kernel.

> 🔴 **GAP — whether fused quantized SDPA will help prefill.** mlx PR #3026 is stalled, and it was
> verified in-thread that `QuantizedScaledDotProductAttention::use_fallback()` returns true when
> **`query_sequence_length > 8`** (plus a `query_sequence_length * gqa_factor > 32` cap and
> head-dim gates). Chunked prefill passes query lengths in the hundreds to thousands. **So as
> written, #3026 changes nothing about prefill memory** — it engages only for single-token decode
> and small-batch speculative verify. **What would resolve it:** the PR landing with a relaxed
> fallback gate. **Safe default:** use `--prefill-step-size 512` today and do not wait for the
> kernel.

### 6.3 Quality and speed: what `--kv-bits` actually buys

> ✅ **VERIFIED, community-measured** — mlx-lm#1573, cross-posted to mlx#3026 and mlx-lm#1587.
> **Qwen3-32B-4bit, group_size 64, int8 KV versus fp16, paired runs:**

| Context | Greedy-argmax agreement | Perplexity ratio | Decode Δ vs fp16 |
|---|---|---|---|
| 0.5K | 0.9804 | 0.9965 | **−7.4%** |
| 4K | 0.9968 | 0.9966 | −3.1% |
| 16K | 0.9990 | 0.9991 | −2.7% |

Two readings of that table.

**Quality is genuinely fine, and it *improves* with context.** 99.9% argmax agreement at 16K, and a
perplexity ratio within 0.1%. This is not a lossy-compression-you-will-regret situation.

**Speed is a small loss, not a gain.** The maintainer-side explanation is the one to internalise:

> *"on a 4-bit dense model KV is only ~19% of decode-step bytes — weights dominate, so halving KV
> bandwidth cannot pay for the compose/dequant overhead. So `--kv-bits 8` is a **capacity** tool
> (roughly half the KV bytes → longer context or more cache slots in the same RAM), bought at a few
> percent of decode speed. **It is not a throughput lever.**"*

Use it when you are out of room, not when you want to go faster.

### 6.4 Four ways `--kv-bits` fails, three of them badly

**(a) The library default and the CLI default disagree, and the library's is worse.**

> ✅ **VERIFIED** — mlx-lm#1566 (closed 2026-08-03; no fix merged, defaults unchanged at HEAD).
> `generate_step()` and `speculative_generate_step()` both default `quantized_kv_start=0`. The
> CLIs default `--quantized-kv-start` to `DEFAULT_QUANTIZED_KV_START = 5000`. **A library caller
> who passes `kv_bits=` without `quantized_kv_start=` quantizes from token 0 and eats the full overhead.**

Measured (community, **M4 Pro 24 GB, mlx 0.32.0**), 512-token prompt / 64 generated, decode tok/s:

| Model | fp16 | quantized, start=0 | quantized, start=5000 |
|---|---|---|---|
| Qwen2.5-0.5B-Instruct-4bit | 424.6 | 352.2 (**−17.1%**) | 425.8 (parity) |
| Llama-3.2-1B-Instruct-4bit | 256.6 | 260.0 | 265.1 |

Past the threshold, at a 5,120-token prompt, it flips positive: Qwen2.5-0.5B 296.4 → 307.4
(**+3.7%**), Llama-3.2-1B 177.6 → 210.1 (**+18.3%**).

**Always pass `quantized_kv_start` explicitly when you pass `kv_bits` from Python.** There is no
good reason to quantize a 500-token cache.

**(b) `RotatingKVCache` has a `to_quantized` that only raises.**

```python
def to_quantized(self, group_size: int = 64, bits: int = 4) -> QuantizedKVCache:
    raise NotImplementedError("RotatingKVCache Quantization NYI")
```

> ✅ **VERIFIED** — `mlx_lm/models/cache.py:551-552`, quoted verbatim.

And `maybe_quantize_kv_cache` guards with `hasattr(c, "to_quantized")` — which is **true**. The
method is defined. It just raises.

> ⚠️ **SILENT FAILURE-adjacent, and worse than silent: it is deferred.** The symptom, from
> mlx-lm#1573 and #1583, is that `mlx_lm.server --kv-bits N` **starts cleanly, answers `/health`
> with 200, and then crashes on the first inference request** for any model with sliding-window
> layers. On Gemma 4 26B-A4B that is **35 of 42 layers** in the reporter's configuration. Your
> health check says the service is up. It is not.

The in-flight fix is mlx-lm PR **#1584**, which adds `RotatingQuantizedKVCache` and
`BatchRotatingQuantizedKVCache`. Validated in-thread on Gemma 4: layer census goes from
`{'RotatingKVCache': 25, 'KVCache': 5}` to
`{'RotatingQuantizedKVCache': 25, 'QuantizedKVCache': 5}`, `max_size=1024` preserved, and with a
3,592-token prompt (3.5× the window) fp16 and kv8 produced **character-identical 60 tokens across
the rotation boundary**.

**But #1584 does not close the generic case.** `keep > 0` remains unimplemented:

```python
if self.keep > 0:
    raise NotImplementedError(
        "Quantizing a RotatingKVCache with keep tokens is not supported.")
```

and `make_prompt_cache`'s generic fallback is `RotatingKVCache(max_size=max_kv_size, keep=4)`
(`cache.py:37`). **So every model that does *not* define its own `make_cache`, run with
`--max-kv-size N --kv-bits 8`, still raises even after #1584.** Gemma 4 escapes only because
`gemma4_text.py:683` passes `keep=0`.

The author's reason for declining to fix `keep > 0` is worth recording because it explains a
design constraint: `BatchRotatingKVCache` has **no `keep` concept at all** — not even a constructor
argument — and `merge()` validates `max_size` while ignoring `keep`, so *"merging
`RotatingKVCache(keep=4)` instances into a batch already drops the sink tokens today, quantized or
not."* Related work: PR **#1618** "Fail early for unsupported KV-cache quantization" and **#1619**
"Fix rotated flag round-trip in `BatchRotatingKVCache.meta_state`".

**(c) Attention-sink models cannot use quantized KV at all — and it presents as a network
timeout.**

> ⚠️ **SILENT FAILURE.** From mlx-lm#1438, verbatim: *"gpt-oss uses attention sinks, and a
> quantized KV cache raises `'Quantized SDPA does not support attention sinks'` from the generation
> thread. **The thread dies, the request never returns, and the client sits until its own timeout,
> so it presents as a network timeout during prefill rather than as an error.** KV quantization has
> to be off for this family."*

The underlying guard is in `mlx_lm/models/base.py`:
`scaled_dot_product_attention` dispatches to `quantized_scaled_dot_product_attention` when the
cache has a `bits` attribute, and that path raises
`ValueError("Quantized SDPA does not support attention sinks.")`.

**How to tell it apart from a slow prefill:** a real slow prefill emits SSE keepalive comments
(`": keepalive {processed}/{total}"`, §2.6). A dead generation thread emits nothing at all. If your
client hangs with zero keepalives, the thread is gone — check the server log for the `ValueError`,
which *is* logged even though nothing is returned to the client.

**(d) A monkeypatch that "fixes" (b) makes things worse.** A workaround in production use returns a
plain `QuantizedKVCache` for *every* layer. That **silently drops the `max_kv_size` bound**, so a
configuration that was bounded-and-fp16 becomes unbounded-and-int8, and memory crosses over as soon
as a conversation runs past roughly twice the window. Do not do this.

### 6.5 The quantized-KV decision rule

```
Do you have an attention-sink model (gpt-oss family)?
  → yes: --kv-bits is unusable. Stop.
Does your model produce RotatingKVCache layers (sliding window, or you passed --max-kv-size)?
  → yes, and you are on a release: --kv-bits will crash on first request. Stop.
  → yes, on main with #1584, and keep == 0: proceed.
  → yes, keep > 0: still raises. Stop.
Are you memory-constrained on CONTEXT (not on weights)?
  → no: skip --kv-bits. It costs 2-7% decode and buys you nothing.
  → yes: --kv-bits 8, and set --quantized-kv-start explicitly (5000 is a sane floor).
Did peak memory go UP?
  → yes: --prefill-step-size 512. This is the actual fix.
```

---

## 7. Speculative decoding

### 7.1 The idea, and the one number that decides everything

Decode is memory-bandwidth bound: generating one token reads the entire weight set once. If a small
"draft" model proposes *k* tokens and the big "target" model verifies all *k+1* in a single forward
pass, you paid one big-model weight read for up to *k+1* tokens. When the draft is usually right,
that is close to a free multiplier. When it is usually wrong, you paid for the draft *and* got one
token.

So the whole technique reduces to one quantity: **the acceptance rate**, the fraction of drafted
tokens the target accepts.

The arithmetic, roughly, ignoring second-order effects. Let *α* be the per-token acceptance
probability, *k* the draft depth, *c* the cost of one draft-model forward relative to one
target-model forward, and *v(k)* the cost of a *k+1*-wide target verify relative to a width-1
target step.

- Expected tokens per round: `E[n] = (1 - α^(k+1)) / (1 - α)`
- Cost per round, in target-forward units: `k·c + v(k)`
- Speedup: `E[n] / (k·c + v(k))`

Three things fall out that match every measurement in our corpus:

1. **`c` must be small.** A draft model that is 1/10 the target's cost gives you room; one that is
   1/3 does not. This is why published draft models are 0.5B–0.8B against 8B–80B targets.
2. **`v(k)` is not 1.** A wider verify costs more than a single-token step, and *how much* more is
   hardware- and shape-dependent. This is the term people forget.
3. **`k` has an optimum and it is small.** Because `E[n]` saturates at `1/(1-α)` while `k·c` grows
   linearly, pushing draft depth past 4–6 loses.

Community measurement that shows term 2 biting hard:

> ✅ **VERIFIED, community-measured** — `notes/repos/issues-mlx-stack.md:480`: at verify width
> **M=3**, 2-bit and 8-bit weights cost the *same absolute time* (0.221 vs 0.224 ms). **This kills
> 2-bit's speculative-decoding value**, because verify width is `num_draft_tokens + 1` = 2–6. The
> same source reports a measured speculative speedup of **1.2× on a 2-bit 27B versus 1.6–2.1× on
> 8-bit models, same machine.** Hardware for that specific comparison is not stated beyond "same
> machine"; treat the ratio, not the absolute times, as the transferable finding.

The counter-intuitive conclusion: **aggressive weight quantization on the target model can destroy
speculative decoding's benefit**, because at small verify widths the kernel is not
bandwidth-limited any more and the quantization no longer buys time.

### 7.2 Running it

```bash
# CLI
mlx_lm.generate --model mlx-community/Qwen3-32B-4bit \
                --draft-model mlx-community/Qwen3-0.6B-4bit \
                --num-draft-tokens 4 \
                --prompt "Refactor this function for clarity." -m 512

# Server
mlx_lm.server --model mlx-community/Qwen3-32B-4bit \
              --draft-model mlx-community/Qwen3-0.6B-4bit \
              --num-draft-tokens 3
```

```python
from mlx_lm import load, stream_generate

model, tokenizer = load("mlx-community/Qwen3-32B-4bit")
draft_model, draft_tokenizer = load("mlx-community/Qwen3-0.6B-4bit")

assert draft_tokenizer.vocab_size == tokenizer.vocab_size, "tokenizers must match"

accepted = total = 0
for r in stream_generate(model, tokenizer, prompt, max_tokens=512,
                         draft_model=draft_model, num_draft_tokens=4):
    print(r.text, end="", flush=True)
    total += 1
    accepted += r.from_draft          # ← this is your acceptance-rate instrument
print(f"\ndraft-accepted {accepted}/{total} = {accepted/max(total,1):.1%}")
```

**`GenerationResponse.from_draft` is the acceptance-rate instrument and almost nobody uses it.**
It is `True` exactly when the draft model produced that token. Count it. If your accepted fraction
is below roughly 50%, speculative decoding is probably costing you time, and the fix is a better
draft model — not a larger `num_draft_tokens`.

### 7.3 The signature, and the constraints it enforces

```python
def speculative_generate_step(
    prompt: mx.array,
    model: nn.Module,
    draft_model: nn.Module,
    *,
    num_draft_tokens: int = 2,          # ← 2 here; the CLI and server default to 3
    max_tokens: int = 256,
    sampler: Optional[Callable[[mx.array], mx.array]] = None,
    logits_processors: Optional[List[Callable[[mx.array, mx.array], mx.array]]] = None,
    prompt_cache: Optional[Any] = None,
    prefill_step_size: int = 512,       # ← 512 here; generate_step uses 2048
    kv_bits: Optional[int] = None,
    kv_group_size: int = 64,
    quantized_kv_start: int = 0,
) -> Generator[Tuple[mx.array, mx.array, bool], None, None]
```

> ✅ **VERIFIED** — `mlx_lm/generate.py:464-478`, read verbatim. Note the two defaults that differ
> from `generate_step`: `num_draft_tokens=2` (CLI says 3) and `prefill_step_size=512` (vs 2048).
> Yields `(token, logprobs, from_draft)` — three values, not two.

**Constraint 1: the prompt cache must be trimmable.**

```python
if not cache.can_trim_prompt_cache(model_cache):
    types = {type(c).__name__ for c in model_cache if not c.is_trimmable()}
    raise ValueError(
        f"Speculative decoding requires a trimmable prompt cache " f"(got {types})."
    )
```

> ✅ **VERIFIED** — `mlx_lm/generate.py:520-524`, quoted verbatim. This is a *loud* failure, and
> that is a deliberate mercy. What you see in practice:
>
> ```
> ValueError: Speculative decoding requires a trimmable prompt cache (got {'ArraysCache'}).
> ```
>
> — reported as mlx-lm#1446 (OPEN) on Qwen3.6-35B-A3B (`qwen3_5_moe`) with a Qwen3.5-0.8B draft.

So: **speculative decoding is unavailable for every hybrid or recurrent architecture**, and
unavailable for sliding-window models once the window wraps. That is §4.2's contract again.

Two competing answers are in flight for that issue, and they are worth knowing because one of them
changes what is possible:

- **PR #1455** — validate at load time and fail fast with a clearer startup error. Conservative.
- A branch implementing **exact rollback for `ArraysCache`**: during the verify forward, gated-delta
  layers record the per-token tensors the recurrent kernel consumed; on partial acceptance the
  state is rebuilt by replaying the recurrence over the accepted prefix — *"bit-exact by causality
  — no deepcopy, no re-forward, no weight restreaming"*. It also rewinds the *draft's* recurrent
  cache, since 2026-era drafts are hybrids too. **Measured 0.77×–1.93× across M2/M3/M5 on a 9B
  target + 0.8B draft; ~1.4× on 80B + 0.6B.** Community-measured; note that the low end is *below
  1.0*, i.e. a slowdown.
- Also in flight: PR **#1596**, "Prompt cache trimming for recurrent/hybrid and sliding-window
  models via prefill-boundary state checkpoints."

**Constraint 2: a shared prompt cache is split positionally.**

```python
if prompt_cache is None:
    model_cache = cache.make_prompt_cache(model)
    draft_cache = cache.make_prompt_cache(draft_model)
else:
    model_cache = prompt_cache[: len(model.layers)]
    draft_cache = prompt_cache[len(model.layers) :]
```

> ✅ **VERIFIED** — `mlx_lm/generate.py:512-518`. If you pass a `prompt_cache`, **you are expected
> to have concatenated the target's and the draft's caches, target first.** That is exactly what
> `server._serve_single` does. Pass a target-only cache and the draft slice will be empty, and the
> failure will not be obvious.

**Constraint 3: tokenizers must match — but only one caller enforces it.**

> ⚠️ `mlx_lm.generate` raises
> `ValueError("Draft model tokenizer does not match model tokenizer.")` when
> `draft_tokenizer.vocab_size != tokenizer.vocab_size`. **The server only logs a warning** —
> *"Draft model tokenizer does not match model tokenizer. Speculative decoding may not work as
> expected."* — and proceeds. ✅ **VERIFIED**, `generate.py:2154-2157` and `server.py:346-350`.
>
> Note also that `vocab_size` equality is a *weak* check. Two tokenizers can share a vocab size and
> disagree on token IDs. If they do, the acceptance test compares meaningless integers and you get
> near-zero acceptance with no error — just a slow model.

### 7.4 The accept/reject loop, and why the cache stays consistent

The verification is a plain greedy argmax-equality test:

```python
n = 0
while n < num_draft:
    tn, dtn, lpn = tokens[n], draft_tokens[n], logprobs[n]
    if tn != dtn:
        break
    n += 1
    ntoks += 1
    yield tn, lpn, True
    if ntoks == max_tokens:
        break
if ntoks < max_tokens:
    ntoks += 1
    yield tokens[n], logprobs[n], False
```

> ✅ **VERIFIED** — `mlx_lm/generate.py:613-626`, quoted verbatim.

Note that after the loop, **one more token is always yielded with `from_draft=False`** — the
target's own next token, which is free because it came out of the same verify forward. So a round
that accepts zero drafts still produces one token. Speculative decoding never goes backwards in
token count; it only goes backwards in *time*.

The rewind:

```python
def _rewind_cache(num_draft, num_accept):
    cache.trim_prompt_cache(model_cache, num_draft - num_accept)
    cache.trim_prompt_cache(draft_cache, max(num_draft - num_accept - 1, 0))
```

> ✅ **VERIFIED** — `mlx_lm/generate.py:589-591`. The draft cache trims one *less*, because the
> draft model has not yet processed the token the target just chose.

And it is called from a `finally:` block as well as inside the loop. That is not defensive
programming for its own sake: when the consumer stops early — `stream_generate` breaking on EOS,
or your code breaking out of the `for` — Python raises `GeneratorExit` at the `yield`, and the
`finally` runs the rewind that the loop body had not reached yet. **The cache is left consistent
when you abandon a generation mid-round.** If you write your own speculative loop, replicate that.

There is one more subtlety worth reproducing, because it is easy to get wrong:

```python
# If we accepted all the draft tokens, include the last
# draft token in the next draft step since it hasn't been
# processed yet by the draft model
if n == num_draft:
    draft_y = mx.concatenate([mx.array(draft_tokens[-1:], mx.uint32), draft_y])
```

> ✅ **VERIFIED** — `mlx_lm/generate.py:632-637`, quoted verbatim including the comment.

### 7.5 "Lossless" is true up to floating-point tie-breaks

A recurring bug report: speculative decoding at `temp=0` produces different text from plain greedy
decoding. Three independent reproductions on three model families found the same signature.

> ✅ **VERIFIED** — mlx-lm#1470 (OPEN, 7 comments) → PR #1592, via
> `notes/repos/issues-mlx-stack.md:693-704`:
> - Qwen3-4B / 0.6B: `mx.eval(l1376 == l1887)` → `True` — **tokens 1376 and 1887 are an exact
>   bit-level tie at 38.0 in bfloat16.**
> - Qwen3-32B-4bit + 0.6B-4bit: both candidates logit `33.75`, softmax `0.3828`, `logit_gap` exactly
>   `0.0`, ranks 1 and 2, byte-identical across three repeats.
> - Qwen3-8B-6bit + 0.6B-6bit: index 99, both logprob `-1.000000`, gap 0.0, adjacent ranks.
>
> Maintainer-side explanation, verbatim: *"`speculative_generate_step` verifies in a batched target
> forward (`num_draft+1` wide) while plain `generate_step` runs sequential single-token forwards —
> same math, different reduction order, so the tie-break can flip between tied ids while staying
> quality-equivalent. **'Lossless' holds up to floating-point tie-break behavior.**"*
>
> The accept/reject code was audited and found correct. The resolution is **documentation**
> (PR #1592 adds a `Note:` to the docstring), not a code change.
> PR #1592 closed unmerged 2026-08-21, so do not assume that note ships.

**The falsifier recipe, if you suspect a real bug rather than a tie.** At the divergence index,
replay through the plain sequential path and print both candidates' raw logits, probabilities and
ranks:

- **Gap ≈ 0.0, both top-ranked** ⟹ benign tie. Move on.
- **Materially nonzero gap with a dominant baseline token** ⟹ real accept/verify bug. File it.

This is a good habit generally: an equality failure between two numerically-different execution
paths is not evidence of a logic bug until you have measured the gap.

### 7.6 What a good draft model looks like

Pulling the threads together into a checklist:

| Property | Target | Why |
|---|---|---|
| **Same tokenizer** | identical vocab **and identical IDs** | the accept test compares token IDs; `vocab_size` equality is necessary, not sufficient |
| **Same family** | strongly preferred | agreement in the easy regions is what acceptance rate measures |
| **Size ratio** | ~1/10 the target's cost or better | this is `c` in §7.1; 0.6B against 8B–80B is the shipped pattern |
| **Weight precision** | **do not go below 4-bit on the target** | at verify width 3, 2-bit and 8-bit cost the same; 1.2× vs 1.6–2.1× measured |
| **Cache class** | trimmable, i.e. plain `KVCache` | hybrids and wrapped sliding windows are refused outright |
| **Draft depth** | 3–4 to start; measure | `num_draft_tokens=2` in the library, 3 in the CLI, and the optimum is workload-dependent |

Where do drafts come from? Two sources in the 2026 ecosystem:

**Small siblings.** A 0.6B or 0.8B instruct model from the same family, same tokenizer. This is the
mainstream path and what the mlx-lm CLI expects.

**Published MTP drafters.** Gemma 4 ships purpose-built drafter checkpoints —
`mlx-community/gemma-4-E2B-it-assistant-bf16` (78 MB), `-E4B-` (78.8 MB), `-26B-A4B-` (~400 MB),
`-31B-` (~500 MB), with `"model_type": "gemma4_assistant"`.

> ✅ **VERIFIED** — sizes and config keys from `notes/repos/issues-mlx-stack.md:988`, tracking
> mlx-swift-lm#279. **Measured ~62% draft acceptance** on predictable text with a 12B target plus
> the assistant drafter — community-measured.
>
> ⚠️ **On the Swift side, the failure mode when a drafter is not registered is silent:** *"the
> `mtpEmitFlagKey` opt-in is discarded by the protocol-extension default and the target never emits
> drafter state — the MTP iterator **silently falls back to single-token passthrough** (no error,
> just no speedup)."* If you enable MTP speculation and see exactly zero change in throughput,
> that is what happened. Check `from_draft`.

### 7.7 Two techniques that were measured and found not worth it

Recording negative results, because they save you from re-deriving them.

**MTP self-speculation on disk-offloaded MoE: dead.**

> ✅ **VERIFIED, community-measured** — from mlx-lm#1438's consolidated summary, verbatim:
> *"MTP self-speculation at small disk fractions (**≤+3% at its best draft depth despite 85.7%
> acceptance** — the resident MTP head costs ~a full extra layer per draft, cancelling the
> batched-verify amortization; measured independently dead by iliria as well)."*
>
> Read that number twice: **85.7% acceptance and it still did not pay.** Acceptance rate is
> necessary, not sufficient. The `c` term ate it.

**N-gram / prompt-lookup self-speculation: positive but narrow.** mlx-lm#1497 proposes a CPU-side
trigram→bigram→unigram draft table for hybrid GDN/SA models, with `--ngram-spec` / `--ngram-n`
flags (default n=3).

> ✅ **VERIFIED, community-measured** — Qwen3.6-27B (48 GDN + 16 SA layers), **M2 Ultra 137 GB**:

| Mode | Speed | Notes |
|---|---|---|
| Baseline (S=1) | 44.6 tok/s | bandwidth-bound |
| N-gram spec, 1 draft | **52.1 tok/s** | +17%, 44% draft hit rate |
| N-gram spec, 2 drafts | 34.4 tok/s | **0.77×** — S=3 overhead exceeds the gain |

That third row is §7.1's `v(k)` term, measured. Going from one draft to two turned a 17% win into a
23% loss. **Draft depth is not a "more is better" knob.**

This technique matters specifically because it needs no draft model *and* — unlike model-based
speculation — has a proposed path through `ArraysCache`, since the proposal includes
`ArraysCache.checkpoint()/rollback()/trim()` (about 18 lines; `trim` is a no-op because the state
is state-based, not offset-based). A Swift sibling is open as mlx-swift-lm#425 with PR #426.

> 🔴 **GAP — n-gram speculation is not merged.** mlx-lm#1497 was open on the 2026-07-29 live
> check and closed unmerged 2026-08-26; verify whether a replacement implementation lands.
> **What would resolve it:** checking whether `--ngram-spec` appears in `mlx_lm.generate --help` on
> `main`. **Safe default:** for hybrid models today, there is no speculative decoding. Plan
> throughput around single-token decode.

---

## 8. Batch generation and continuous batching

### 8.1 `batch_generate` — the easy door

```python
def batch_generate(
    model,
    tokenizer,
    prompts: List[List[int]],                       # token id lists, NOT strings
    prompt_caches: Optional[List[List[Any]]] = None,
    max_tokens: Union[int, List[int]] = 128,
    verbose: bool = False,
    return_prompt_caches: bool = False,
    return_token_ids: bool = False,
    return_logprobs: bool = False,
    **kwargs,                                       # → BatchGenerator
) -> BatchResponse
```

> ✅ **VERIFIED** — `mlx_lm/generate.py:1971-1982`, read verbatim.

**`prompts` is a list of token-ID lists, not a list of strings.** Unlike `generate` and
`stream_generate`, there is no string convenience path. Tokenize first.

```python
@dataclass
class BatchResponse:
    texts: List[str]
    stats: BatchStats
    caches: Optional[List[List[Any]]]
    token_ids: Optional[List[List[int]]] = None
    logprobs: Optional[List[List[float]]] = None    # logprob of the SAMPLED token
```

`BatchStats` carries `prompt_tokens`, `prompt_tps`, `prompt_time`, `generation_tokens`,
`generation_tps`, `generation_time`, `peak_memory`.

`return_logprobs` and `return_token_ids` arrived in commit `2c008fd`, and the docstring names the
use case explicitly: *"Useful for reinforcement learning (e.g. RLOO, PPO) where behavior
log-probabilities are needed for importance weighting."* If you are building an on-device RL loop,
that is your hook.

The working example, verbatim from `mlx_lm/examples/batch_generate_response.py`, and note what the
second half does:

```python
from mlx_lm import batch_generate, load

checkpoint = "mlx-community/Llama-3.2-3B-Instruct-4bit"
model, tokenizer = load(path_or_hf_repo=checkpoint)

prompts = ["Write a story about Einstein.", "Why is the sky blue?",
           "What time is it?", "How tall is Mt Everest?"]
prompts = [tokenizer.apply_chat_template([{"role": "user", "content": p}],
                                         add_generation_prompt=True) for p in prompts]

result = batch_generate(model, tokenizer, prompts, verbose=False,
                        return_prompt_caches=True, max_tokens=2048)
print(result.texts[-1])

prompts = ["Could you summarize that?", "And what about the sea?", "Try again?", "And Mt Olympus?"]
prompts = [tokenizer.apply_chat_template([{"role": "user", "content": p}],
                                         add_generation_prompt=True) for p in prompts]
result = batch_generate(model, tokenizer, prompts, verbose=False, prompt_caches=result.caches)
print(result.texts[-1])
```

> ✅ **VERIFIED** — reproduced verbatim from the repository.

**That is four independent multi-turn conversations sharing one batch.** `return_prompt_caches=True`
hands you a per-sequence cache list; feeding it back as `prompt_caches=` on the next call continues
each conversation without re-prefilling. This is the batched analogue of §5.6, and it is the single
most useful thing `batch_generate` does.

One important asymmetry with the single-sequence API:

> ✅ **VERIFIED** — `batch_generate`'s docstring: *"Note, **unlike `generate_step`, the caches won't
> be updated in-place**."* So for batches you must round-trip them through the return value. Passing
> `prompt_caches=` and then reusing your original list gives you stale caches, with no error.

### 8.2 `BatchGenerator` — continuous batching directly

```python
BatchGenerator(
    model, *,
    max_tokens: int = 128,
    stop_tokens: Optional[Sequence[Sequence[int]]] = None,
    sampler=None,
    logits_processors=None,
    completion_batch_size: int = 32,     # max sequences decoding at once
    prefill_batch_size: int = 8,         # max sequences prefilling at once
    prefill_step_size: int = 2048,
    max_kv_size: Optional[int] = None,
    stream=None,
)
```

> ✅ **VERIFIED** — `mlx_lm/generate.py:1576-1591`, read verbatim. Internally,
> `completion_batch_size = max(completion_batch_size, prefill_batch_size)` — you cannot decode
> fewer sequences than you prefill. It sets the wired limit in `__init__` and restores it in
> `close()` / `__del__`, so **use it as a context-managed resource or call `close()` explicitly.**

Public surface:

| Method | Purpose |
|---|---|
| `insert(prompts, max_tokens=None, caches=None, all_tokens=None, samplers=None, logits_processors=None, stop_matchers=None) -> List[int]` | add sequences; returns uids |
| `insert_segments(segments: List[List[List[int]]], ...)` | segmented prefill; **guaranteed to stop at segment boundaries** |
| `next() -> (prompt_responses, generation_responses)` | one step |
| `next_generated() -> List[GenerationBatch.Response]` | loop until generation output exists |
| `extract_cache(uids) -> {uid: (cache, tokens)}` | pull a sequence's cache out |
| `remove(uids, return_prompt_caches=False)` | drop sequences |
| `prompt_cache_nbytes` | property |
| `stats(stats=None)` | context manager returning a `BatchStats` |
| `close()` | release the wired limit |

`GenerationBatch.Response` carries `uid, token, logprobs, finish_reason, prompt_cache, all_tokens`
— the last two only on the final response for a uid.
`PromptProcessingBatch.Response` carries `uid, progress: tuple, end_of_segment: bool,
end_of_prompt: bool`.

**`insert_segments` is how the server gets per-segment caching.** It splits a chat prompt into up
to three segments — system prompt, user context, thinking tail — and because the generator is
*guaranteed* to stop at segment boundaries, each boundary's KV state can be checkpointed into the
`LRUPromptCache` under its own `cache_type`. That is the mechanism behind §5.5's type-ordered
eviction.

Per-request settings, which is what makes this a server primitive rather than a batch API:

```python
from mlx_lm.generate import BatchGenerator, StopSequenceMatcher
from mlx_lm.sample_utils import make_sampler

gen = BatchGenerator(model, stop_tokens=[[t] for t in tokenizer.eos_token_ids],
                     max_tokens=256, completion_batch_size=32, prefill_batch_size=8,
                     prefill_step_size=2048, max_kv_size=None)
uids = gen.insert(
    [tokenizer.encode(p) for p in prompts],
    max_tokens=[128, 256, 512],
    samplers=[make_sampler(temp=t) for t in (0.0, 0.7, 1.0)],
    stop_matchers=[StopSequenceMatcher([tokenizer.encode("\n\n", add_special_tokens=False)])] * 3,
)
out = {u: [] for u in uids}
while responses := gen.next_generated():
    for r in responses:
        if r.finish_reason != "stop":
            out[r.uid].append(r.token)
gen.close()
print([tokenizer.decode(out[u]) for u in uids])
```

> ⚠️ **`BatchGenerator.insert` mutates the `caches` list you pass it** — it writes
> `caches[i] = <new cache>` where the entry was `None`. And `batch_generate` reuses the same local
> name for input and output caches. If you keep a reference to the list you passed in, expect it to
> have changed under you.

### 8.3 How batching constrains your cache choices

Every regular cache must be convertible to a batch-aware one, and the mapping is explicit:

```python
def to_batch_cache(c):
    if type(c) is KVCache:
        return BatchKVCache(left_padding)
    elif isinstance(c, ArraysCache):
        c.left_padding = mx.array(left_padding)
        return c
    elif isinstance(c, RotatingKVCache):
        if c.keep > 0:
            raise ValueError("RotatingKVCache with keep tokens is not supported.")
        return BatchRotatingKVCache(c.max_size, left_padding)
    elif isinstance(c, CacheList):
        return CacheList(*(to_batch_cache(sub_c) for sub_c in c.caches))
    else:
        raise ValueError(f"{type(c)} does not yet support batching")
```

> ✅ **VERIFIED** — `mlx_lm/generate.py:829-848`, quoted verbatim.

Three readings:

**`type(c) is KVCache` is an exact type check, not `isinstance`.** A subclass of `KVCache` falls
through to the final `else` and raises `does not yet support batching`. If you subclass, subclass
carefully.

**`RotatingKVCache(keep > 0)` is rejected outright** — and `make_prompt_cache`'s generic fallback
creates `keep=4`. So `--max-kv-size N` on a model without its own `make_cache` produces caches that
`batch_generate` refuses. `BatchGenerator`'s own `_make_new_cache` creates `RotatingKVCache` with
`keep=0`, which is why the internal path works and the round-trip does not.

**`QuantizedKVCache` and `ChunkedKVCache` are not in the list.** They fall through to the raise.
That is the same constraint the server enforces up front with
`all(hasattr(c, "merge") for c in make_prompt_cache(model))`.

Left padding, from `BatchKVCache`'s own docstring:

```
E.g. the following prompts:
    [1, 3, 5]
    [7]
    [2, 6, 8, 9]
Should be padded like so:
    [0, 1, 3, 5]
    [0, 0, 0, 7]
    [2, 6, 8, 9]
And ``left_padding`` specifies the amount of padding for each.
In this case, ``left_padding = [1, 3, 0]``.
```

> ✅ **VERIFIED** — quoted verbatim from `mlx_lm/models/cache.py`.

Batch caches also expose `prepare(left_padding=, lengths=, right_padding=)`, `finalize()`,
`filter(batch_indices)`, `extend(other)` and `extract(idx)` — the last returning a *single-sequence*
`KVCache` or `RotatingKVCache`, which is how `extract_cache` gives you back something you can use
with `stream_generate`.

### 8.4 The server's batchability gate — two ways to lose continuous batching

```python
# mlx_lm/server.py:352-356
is_batchable = draft_model is None
is_batchable = is_batchable and all(
    hasattr(c, "merge") for c in make_prompt_cache(model)
)
```
```python
# mlx_lm/server.py:621-622
def _is_batchable(self, args):
    return self.model_provider.is_batchable and args.seed is None
```

> ✅ **VERIFIED** — quoted from `mlx_lm/server.py` via `notes/transcripts/evals-mlx.md:1355-1369`,
> which cross-checked them against the session 232 narration.

So:

1. **`--draft-model` disables continuous batching entirely.** Speculative decoding and continuous
   batching are mutually exclusive in this server. You pick one.
2. **Any request that sets `seed` is un-batchable**, and it forces the current batch to *drain*
   before it runs — the source comment is *"We have a batch but this request cannot be added to the
   batch so drain it to process the request."*

The operational advice that follows, for agentic and subagent workloads: **do not set `seed`, and
do not use a draft model.** A single client setting `seed` for reproducibility will serialise your
whole server, and nothing in the response tells them so.

> ⚠️ Note the interaction with WWDC26 session 232's pitch. Apple's narration is *"your subagents
> don't stall waiting in a queue. They all get served concurrently."* That is true **only when the
> batchability gate passes**. Two configuration choices that look unrelated — a draft model for
> speed, a seed for reproducibility — silently turn the concurrent server into a sequential one.

### 8.5 Batch-generation defects worth knowing

| Issue | Symptom |
|---|---|
| mlx-lm 0.31.0 | **yanked in practice** for `BatchKVCache` cross-contamination — output from one sequence leaking into another |
| mlx-lm#1472 (MERGED-UNRELEASED 2026-09-04) | Generation thread dies with `TypeError: 'NoneType' object is not iterable` when a batch mixes requests **with and without** logits processors; [PR #1826](https://github.com/ml-explore/mlx-lm/pull/1826) fixes the wedge by normalizing per-sequence samplers and processors, but affected releases still need the guard or a watchdog |
| mlx-lm#1493 (OPEN) | Server **livelock**: the batch keeps stepping and delivers zero chunks. `is_alive()` stays true; a naive per-iteration heartbeat would also tick |
| mlx-lm#1500 (OPEN) | Idle server pins a core at 100% — the worker thread busy-polls with `get_nowait()` |

> ✅ **VERIFIED** — release history at `notes/repos/issues-mlx-stack.md:22`; issue numbers,
> symptoms, and #1472 resolution at `notes/repos/issues-mlx-stack.md:652-684`.

The livelock one deserves a paragraph because the diagnosis is instructive. py-spy plus `sample`
over six minutes showed the loop alternating between the forward call and the eval sync with live
compute-encoding frames and **real CPU time** — the engine was working and producing nothing.
Meanwhile fresh trivial completions hung for over 180 seconds in `response_queue.get()` with no
timeout, and `GET /v1/models` returned 200 throughout. Only a hard restart recovered it.

> *"This failure mode defeats both detection strategies discussed so far… The liveness signal has
> to be defined at the delivery level: **requests in flight + no tokens delivered to any consumer
> queue for N seconds = stalled engine.**"*

That is a good rule for any inference service you operate, not just this one. **Health-check what
you deliver, not what you execute.** The fix in flight is PR #1598, a delivery-staleness watchdog
with `--generation-stall-timeout` (default 60 s).

> 🔴 **GAP — `--generation-stall-timeout` is not merged.** As of our read, PR #1598 is open and
> stacked on #1513. **What would resolve it:** checking `mlx_lm.server --help` on `main`.
> **Safe default:** put your own watchdog in front of the server — track time since the last SSE
> byte per request, and restart the process if it exceeds your timeout with requests in flight.

---

## 9. The silent-failure register

Six failures that produce no exception and no log line you would notice. Ordered by how likely you
are to hit them.

### 9.1 ⚠️ SILENT FAILURE — the chat template you are using is not the one you think

This is the one the brief for this guide asked for, and it is the most consequential defect in the
package for output *quality*, because there is no error at any layer.

**The mechanism.** `TokenizerWrapper.apply_chat_template` will apply *a* template in several
situations where you might expect it to apply *yours*, or none:

```python
self.has_chat_template = (
    tokenizer.chat_template is not None or chat_template is not None
)

def apply_chat_template(self, *args, tokenize=True, **kwargs):
    ...
    if self._chat_template is not None:
        out = self._chat_template(*args, **kwargs)
    ...
    return self._tokenizer.apply_chat_template(*args, tokenize=tokenize, **kwargs)
```

> ✅ **VERIFIED** — `mlx_lm/tokenizer_utils.py:296-343`, read this session.

And `mlx_lm.generate` gates on exactly that flag:

```python
if not args.ignore_chat_template and tokenizer.has_chat_template:
```

> ✅ **VERIFIED** — `mlx_lm/generate.py:2121`.

**Failure mode A — `--use-default-chat-template` is a no-op in `mlx_lm.generate`.** The flag is
declared:

```python
parser.add_argument(
    "--use-default-chat-template",
    action="store_true",
    help="Use the default chat template",
)
```

> ✅ **VERIFIED** — `mlx_lm/generate.py:147-151`. And then: **`grep -c use_default_chat_template
> mlx_lm/generate.py` returns `0`.** The parsed attribute is never read anywhere in that module.
> The only consumer in the package is `mlx_lm/server.py:338`. Verified by grep across `mlx_lm/`
> this session: three hits total — the two argparse declarations and the one server use site.
>
> **Consequence: `mlx_lm.generate --use-default-chat-template` runs a model with no template at
> all** (if the tokenizer has none) or with the tokenizer's own template (if it has one). Argparse
> accepts the flag. Nothing warns. The model produces fluent, plausible, *wrong-format* output —
> and on an instruct-tuned model, wrong format means degraded instruction-following, not gibberish,
> which is why it survives casual inspection.

**Failure mode B — a base model silently gets no template.** If `tokenizer.chat_template is None`,
`has_chat_template` is `False`, and `mlx_lm.generate` falls through to
`prompt = tokenizer.encode(prompt)` — raw. Your `--system-prompt` is **discarded entirely**,
because the system message is only constructed inside the templated branch. No warning.

**Failure mode C — thinking mode flips on or off without you asking.** `TokenizerWrapper`
defaults `enable_thinking=self.has_thinking`, inferred from the vocabulary:

```python
THINK_TOKENS = [("<think>", "</think>"), ("<longcat_think>", "</longcat_think>")]
# multi-token: if "<|channel>" and "<channel|>" are in the vocab →
#   think_start = "<|channel>thought", think_end = "<channel|>"
```

> ✅ **VERIFIED** — `_infer_thinking` in `mlx_lm/tokenizer_utils.py`. A model whose vocabulary
> happens to contain `<think>` gets `enable_thinking=True` by default, which changes the rendered
> prompt and can consume your entire token budget on reasoning you never see.

**Failure mode D — the tool parser is chosen by substring matching on the template text.**
`_infer_tool_parser(chat_template)` tests literal substrings in a fixed order:
`<minimax:tool_call>` → minimax_m2; `<|tool_call>` + `<tool_call|>` → gemma4;
`<start_function_call>` → function_gemma; `<longcat_tool_call>` → longcat; `<arg_key>` → glm47;
`<|tool_list_start|>` → pythonic; `<tool_call>\n<function=` → qwen3_coder;
`<|tool_calls_section_begin|>` → kimi_k2; `[TOOL_CALLS]` → mistral;
`<tool_call>` + `tool_call.name` → json_tools; else `None`.

> ✅ **VERIFIED** — `mlx_lm/tokenizer_utils.py:546-571`, read this session. **Order matters:** a
> template containing both `<tool_call>` and `<function=` gets `qwen3_coder`, not `json_tools`. If
> you edit a template and change which substrings appear, you can silently change which *parser*
> runs, and tool calls will come back mis-parsed rather than unparsed. The escape hatch is an
> explicit `tool_parser_type` key in `tokenizer_config.json`, which overrides the inference.

**How to detect all four in ten seconds.** Render the template and look at it, before you generate:

```python
from mlx_lm import load

model, tokenizer = load("mlx-community/Qwen3-8B-4bit")

print("has_chat_template:", tokenizer.has_chat_template)
print("has_thinking     :", tokenizer.has_thinking)
print("has_tool_calling :", tokenizer.has_tool_calling)
print("tool_parser      :", tokenizer.tool_parser)

rendered = tokenizer.apply_chat_template(
    [{"role": "system", "content": "SYS"}, {"role": "user", "content": "USR"}],
    add_generation_prompt=True,
    tokenize=False,
)
print("---")
print(rendered)
print("---")
```

**If `SYS` does not appear in the rendered string, your system prompt is being thrown away.** If
`has_chat_template` is `False`, you are sending raw text to an instruct model. If a `<think>` tag
appears and you did not want reasoning, pass
`--chat-template-config '{"enable_thinking": false}'` (or `--chat-template-args` on the server).

**Safe default: always render and eyeball the template once per model.** It costs one print and it
catches every variant of this failure.

> 🔴 **GAP — `--use-default-chat-template` on the server under transformers 5.x.** `server.py:338`
> does `tokenizer.chat_template = tokenizer.default_chat_template`, and `TokenizerWrapper` forwards
> unknown attributes to the wrapped Hugging Face tokenizer. **What is unknown:** whether
> `default_chat_template` still exists as an attribute in `transformers >= 5.7.0`, which mlx-lm now
> requires. If it does not, this raises `AttributeError` at model-load time rather than doing
> anything useful. **What would resolve it:** `python -c "import transformers, inspect;
> print(hasattr(transformers.AutoTokenizer.from_pretrained('gpt2'), 'default_chat_template'))"`.
> **Safe default:** do not use the flag. Pass an explicit template with `--chat-template`, or set
> `chat_template` in `tokenizer_config.json`.

### 9.2 ⚠️ SILENT FAILURE — quantized-KV settings silently change output quality

The second failure the brief asked for, and it has three independent mechanisms.

**(a) The library quantizes from token 0 unless you say otherwise.** §6.4(a). `generate_step`
defaults `quantized_kv_start=0` while every CLI defaults to `5000`. A Python caller who passes only
`kv_bits=8` gets quantized keys and values for the *entire* prompt, including the first token,
where the quality cost is highest relative to the cache size. Measured **−17.1% decode** on a
512-token prompt, and the argmax agreement figures in §6.3 are worst at short context
(**0.9804 at 0.5K**, versus 0.9990 at 16K). Short prompts are exactly where you are least likely to
notice, and most likely to be running an eval.

**(b) The cache file records the setting; a mismatch is an error, but a *matching* setting you
forgot about is not.** A prompt cache built with `--kv-bits 4` will silently keep every future
generation at 4-bit KV, forever, because loading it reconstructs `QuantizedKVCache` instances. The
error only fires if you pass a *different* `--kv-bits`. Passing none at all inherits whatever the
file has. **Name your cache files after their settings** — `book.kv4.safetensors`.

**(c) The switch happens mid-generation, per layer, at different times.**
`maybe_quantize_kv_cache` fires when `c.offset >= quantized_kv_start` — evaluated independently for
each layer. On a model with mixed layer types (some sliding, some full), different layers cross the
threshold at different absolute step counts, so your model's numeric behaviour changes gradually
across a window of tokens rather than at one point. There is no log line. If you are bisecting a
quality regression against generation length, this is a candidate mechanism.

**Safe default:** for anything you will measure, pin `quantized_kv_start` explicitly and record it
alongside the result. `--kv-bits 8 --quantized-kv-start 5000` is a defensible default; `kv_bits=8`
alone from Python is not.

### 9.3 ⚠️ SILENT FAILURE — sampler parameters that do nothing

Four of them, all reading as configured when they are not.

**`temp=0` disables everything.** `make_sampler` short-circuits to
`lambda x: mx.argmax(x, axis=-1)` before it looks at `top_p`, `min_p`, `top_k` or XTC. The CLI
default is `--temp 0.0`. So `mlx_lm.generate --top-k 50 --xtc-probability 0.2` with no `--temp`
does exactly nothing beyond greedy decoding.

**`top_p` is a no-op outside `(0, 1)` exclusive.** `apply_top_p` is only chained when
`0 < top_p < 1.0`. `make_sampler`'s own default is `0.0` (disabled) while every CLI passes `1.0`
(also disabled). Both spellings mean off; neither errors.

**`xtc_threshold` has four different defaults in one package.** `generate.py`'s module constant is
`0.0`, its argparse default is `0.1`, `chat.py` uses `0.0` for both, `make_sampler` defaults to
`0.1`, and the server's request-body default is `0.1`. Commit `cf10f96` ("change xtc_threshold
default from 0.0 to 0.1 everywhere") was supposed to unify them and did not reach the module
constant. **Setting `xtc_threshold=0` with `xtc_probability > 0` makes the XTC mask trivially true
for everything above zero probability** — an aggressive truncation you did not ask for.

**XTC without `xtc_special_tokens` eats newlines and EOS.** §3.6. Every in-package caller passes
`tokenizer.encode("\n") + list(tokenizer.eos_token_ids)`. A hand-built sampler that omits it can
produce a model that never emits a paragraph break and never stops.

**Safe default:** set `temp` first and validate the configuration deterministically. Do not call a
stochastic sampler twice and assert the tokens differ: two valid random draws can match, making
that test flaky.[^sampler-source]

```python
temperature = 0.7
assert temperature > 0.0  # temp == 0 selects the greedy branch
sampler = make_sampler(temp=temperature, top_p=0.95, top_k=50)
```

### 9.4 ⚠️ SILENT FAILURE — kwargs dropped by `stream_generate`

```python
if draft_model is None:
    kwargs.pop("num_draft_tokens", None)
    ...
else:
    kwargs.pop("max_kv_size", None)
    kwargs.pop("prompt_progress_callback", None)
```

> ✅ **VERIFIED** — `mlx_lm/generate.py:688-700`, the structure read this session.

**With a draft model, `max_kv_size` and `prompt_progress_callback` are silently discarded.** Not
warned about. Not errored. So:

- Your memory bound disappears when you enable speculative decoding. A configuration that fit in
  RAM without a draft model may not fit with one.
- Your prefill progress UI goes dead. If you built a progress bar on
  `prompt_progress_callback` and it stops updating the day someone adds `--draft-model`, this is
  why.

**Safe default:** if you pass a draft model, bound memory some other way — a smaller prompt, or a
model whose `make_cache()` already returns bounded caches — and drive your progress UI from
`GenerationResponse.prompt_tokens` on the first yielded response instead.

### 9.5 ⚠️ SILENT FAILURE — server prompt-cache reuse returning mismatched KV

> ✅ **VERIFIED** — mlx-lm#1494 (administratively closed without a fix 2026-08-21), via `notes/repos/issues-mlx-stack.md:631-635`.

`LRUPromptCache.fetch_nearest_cache` rests on two assumptions:

1. a stored cache's KV corresponds **exactly** to the token key it is filed under, and
2. `is_trimmable() == True` implies `trim(n)` removes **exactly** the suffix.

`KVCache` satisfies both. **`ChunkedKVCache` and `ConcatenateKVCache` do not**, and nothing verifies
it at reuse time. Three distinct defects come out of that:

- **A:** silently wrong output, instead of falling back to a recompute.
- **B:** the server's segment checkpointing then stores the *mismatched* state under the new key, so
  subsequent exact hits reuse the bad entry. The corruption propagates.
- **C:** a trim-contract problem in `trim_prompt_cache` itself.

A model-free reproduction script (`repro_prompt_cache_reuse.py`, exits 1 while the bugs are
present) is attached to the issue.

**Who is affected:** anyone serving a chunked-attention model — Llama 4 is the canonical
`ChunkedKVCache` consumer — through `mlx_lm.server` with the prompt cache enabled, which is the
default.

**Safe default until this lands:** for `ChunkedKVCache` architectures, run the server with
`--prompt-cache-size 1`, which cannot produce a prefix rewind because there is nothing to rewind
from. You lose the caching benefit and keep correctness. Verify the effect by watching
`usage.prompt_tokens_details.cached_tokens` go to zero.

### 9.6 ⚠️ SILENT FAILURE — the Swift port's cache bugs, because you will hit them from a Mac app

Included here rather than in [Part 13](../../part-13-mlx-swift/README.md) because the mechanism is the
Python one seen through a value-type lens, and understanding it in Python is how you recognise it in
Swift.

**`maybeQuantizeKVCache` silently corrupts context mid-generation.**

> ✅ **VERIFIED** — mlx-swift-lm#312 (OPEN, 6 comments), quoted verbatim:
> *"`maybeQuantizeKVCache` is called on every step inside `TokenIterator`'s generation loop. When
> the `quantizedKVStart` threshold is crossed mid-generation, it replaces elements in
> `TokenIterator`'s local copy of the cache array with new `QuantizedKVCache` instances. Because the
> function takes `cache: inout [KVCache]`, it **replaces array elements rather than mutating the
> cache objects in place**. The caller's array (in `ChatSession`) still holds the original
> `KVCacheSimple` references … **The model loses all context generated after the quantization
> threshold.**"*
>
> Fix landed: PR #453 merged 2026-08-05 (supersedes #358, closed unmerged); the reference-wrapper approach shipped as `KVCacheStorage`, a class boxing `[KVCache]`. #312 stays open as of 2026-08-07, and no release carries the fix (latest 3.31.4) — check your pin.

Compare with §6.1: mlx-lm's Python `maybe_quantize_kv_cache` does *the same element replacement* —
`prompt_cache[e] = c.to_quantized(...)` — and it is safe **only because Python lists are reference
types and everyone shares the same list object.** Port that line to a value-semantics language
without thinking and you get exactly this bug.

**`trimPromptCache`'s return value discarded during speculative rewind.**

> ✅ **VERIFIED** — mlx-swift-lm, via `notes/repos/issues-mlx-stack.md:947`:
> `SpeculativeTokenIterator.speculateRound()` rewinds rejected drafts with
> `trimPromptCache(mainCache, numTokens: numDraft - accepted)` **and discards the result**.
> `trimPromptCache` guards on `canTrimPromptCache`, so **once one sliding layer wraps, the whole
> rollback returns 0 silently** and generation continues on a transcript containing tokens that were
> never emitted. On Gemma-family models the sliding window is small (e.g. 512), so a single long
> reply is enough to trigger it.

This is §4.2's "returns `0`, not an error" made concrete. **Check the return value of
`trim_prompt_cache`.** Every time. In both languages.

---

## 10. Decision tables, cross-links, and the gap register

### 10.1 Which entry point do I want?

| I want to… | Command |
|---|---|
| Get one answer from a model | `mlx_lm.generate --model M -p "…"` |
| Iterate interactively with context | `mlx_lm.chat --model M` |
| Serve an OpenAI-compatible API | `mlx_lm.server --model M` |
| Put a local model behind `LanguageModelSession` | `mlx_lm.server`, then [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md) |
| Convert a HF checkpoint to MLX | `mlx_lm.convert --model org/M -q` |
| Make a repeated long prefix cheap | `mlx_lm.cache_prompt` then `--prompt-cache-file` |
| Fine-tune | `mlx_lm.lora --train`, then `mlx_lm.fuse` |
| Improve a quantization | `mlx_lm.awq` / `.dwq` / `.gptq` / `.dynamic_quant` |
| Score a model on standard tasks | `mlx_lm.evaluate --tasks …` |
| Get a perplexity with error bars | `mlx_lm.perplexity` |
| Measure throughput reproducibly | `mlx_lm.benchmark` |
| Free disk from the HF cache | `mlx_lm.manage --scan` / `--delete` |
| Publish a converted model | `mlx_lm.upload` |
| Copy a model to other nodes | `mlx_lm.share --hostfile hosts.json` |

### 10.2 The four flags most likely to hurt you

| Flag | Looks like | Actually |
|---|---|---|
| `--max-kv-size N` | a memory knob | a **capability** knob: kills quantized KV, spec decoding, and batching-with-`keep`. **Ignored entirely** on the 41 models that define `make_cache()` |
| `--kv-bits N` | a speed knob | a **capacity** knob costing 2–7% decode; can *raise* peak memory; crashes at request time on sliding-window models; hangs the thread on attention-sink models |
| `--draft-model M` | free speedup | **disables continuous batching**; silently drops `max_kv_size` and the prefill callback; refused outright on hybrid models |
| `--use-default-chat-template` | applies a default template | **a no-op in `mlx_lm.generate`.** Works only on the server, where it may `AttributeError` under transformers 5.x |

### 10.3 Cross-links

- **[Part 4 — Beyond the built-in model](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md).**
  `ChatCompletionsLanguageModel` turns `mlx_lm.server` into a Foundation Models backend. Read §2.6
  here for the server flags, then Part 4 for the session wiring. **Carry §8.4 with you**: a
  `LanguageModelSession` that sets a seed will serialise your server.
- **[Part 12 guide 03 — Quantization and conversion](03-quantization.md).**
  `mlx_lm.convert`, the four learned-quantization CLIs, `--q-mode` and the mixed-precision recipes.
  §2.4 and §2.5 here are the index; guide 03 is the content. **Carry §7.1 with you**: aggressive
  weight quantization on the target model can eliminate speculative decoding's benefit.
- **[Part 12 guide 06 — Fine-tuning](06-finetuning-and-porting-models.md).** `mlx_lm.lora`,
  `mlx_lm.fuse`, dataset formats, adapters. §2.7 is the index. **Carry §2.2 with you**:
  `--adapter-path` on `mlx_lm.generate` is how you test an adapter without fusing.
- **[Part 3 — Context, profiles, agentic sessions](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/README.md).**
  Its KV-cache guide covers the same mechanism on Apple's runtime, including the 101× prefix-reuse
  figure quoted in §5.1 and the constraint that hybrid architectures forfeit prefix caching.
- **[Part 13 — MLX in Swift](../../part-13-mlx-swift/README.md).** §9.6 is a preview of why the Swift cache
  layer needs its own guide.

### 10.4 Open gaps, collected

| # | Gap | What would resolve it | Safe default |
|---|---|---|---|
| G1 | `mlx_lm.share`'s hostfile schema lives in mlx core and is undocumented here | read `mlx/_distributed_utils/common.py` | generate it with `mlx.distributed_config --auto-setup` |
| G2 | Latent `NameError` in `evaluate.py::loglikelihood`'s `prefix_l == 0` branch | re-grep `evaluate.py` for `all_scores` on `main` | cap `--max-tokens` below the model's context |
| G3 | Prompt-cache `<query>` slicing with a non-deterministic chat template | run it against a template that injects `strftime` | avoid dynamic template content in cached workflows |
| G4 | Whether fused quantized SDPA (mlx#3026) will ever help prefill | the PR landing with a relaxed `use_fallback` gate | `--prefill-step-size 512` today |
| G5 | Whether `tokenizer.default_chat_template` exists under transformers ≥ 5.7 | one-line `hasattr` check | do not use `--use-default-chat-template`; pass `--chat-template` |
| G6 | N-gram speculation PR (#1497) closed unmerged 2026-08-26; verify whether another implementation landed. `--generation-stall-timeout` (#1598) remains separately tracked | check `--help` on `main` | do not assume spec decoding for hybrids; run your own delivery watchdog |
| G7 | Whether `rich` and `regex` ship in the published PyPI wheel despite being absent from `setup.py` | `pip download mlx-lm && unzip -l` the wheel | install them explicitly |

### 10.5 Copy-paste reference

```bash
# --- Inference ---
mlx_lm.generate --model mlx-community/Qwen3-8B-4bit -p "Explain MoE routing" -m 512 --temp 0.7
mlx_lm.generate --model M --prompt - < long.txt --max-kv-size 4096 --kv-bits 4 \
                --quantized-kv-start 2048 --prefill-step-size 512
mlx_lm.chat --model mlx-community/Llama-3.2-3B-Instruct-4bit --system-prompt "Be terse."
mlx_lm.server --model M --port 8080 --decode-concurrency 32 --prompt-concurrency 8 \
              --prompt-cache-size 20 --prompt-cache-bytes 8GB \
              --chat-template-args '{"enable_thinking":false}'

# --- Prompt caching to disk ---
cat book.txt | mlx_lm.cache_prompt --model M --prompt - --prompt-cache-file book.safetensors
mlx_lm.generate --prompt-cache-file book.safetensors --prompt "\nSummarize chapter 3."

# --- Speculative decoding ---
mlx_lm.generate --model mlx-community/Qwen3-32B-4bit \
                --draft-model mlx-community/Qwen3-0.6B-4bit --num-draft-tokens 4 -p "…"

# --- Measurement ---
mlx_lm.benchmark --model M -p 2048 -g 128 -b 8 -n 5
mlx_lm.perplexity --model M --num-samples 512 --sequence-length 1024
mlx_lm.evaluate  --model M --tasks mmlu_pro --batch-size 16 --limit 200

# --- Housekeeping ---
python -m mlx --version && python -m mlx_lm --version
mlx_lm.manage --scan --pattern mlx-community
```

```python
# --- Streaming with an owned cache, an explicit sampler, and processors ---
from mlx_lm import load, stream_generate
from mlx_lm.models.cache import make_prompt_cache
from mlx_lm.sample_utils import make_logits_processors, make_sampler

model, tokenizer = load("mlx-community/Qwen3-8B-4bit")
cache = make_prompt_cache(model)                 # reuse across turns

sampler = make_sampler(
    temp=0.7, top_p=0.95, min_p=0.02, top_k=50,
    xtc_probability=0.1, xtc_threshold=0.15,
    xtc_special_tokens=tokenizer.encode("\n") + list(tokenizer.eos_token_ids),
)
processors = make_logits_processors(repetition_penalty=1.1, repetition_context_size=64)

prompt = tokenizer.apply_chat_template(
    [{"role": "user", "content": "hi"}], add_generation_prompt=True)

for r in stream_generate(model, tokenizer, prompt, max_tokens=512,
                         sampler=sampler, logits_processors=processors,
                         prompt_cache=cache,
                         kv_bits=8, kv_group_size=64, quantized_kv_start=5000,
                         prefill_step_size=2048):
    print(r.text, end="", flush=True)
print(f"\n{r.finish_reason} · {r.generation_tps:.1f} tok/s · peak {r.peak_memory:.2f} GB")
```

```python
# --- Batched multi-turn: four conversations, one batch, caches round-tripped ---
from mlx_lm import batch_generate, load

model, tokenizer = load("mlx-community/Llama-3.2-3B-Instruct-4bit")

def render(texts):
    return [tokenizer.apply_chat_template([{"role": "user", "content": t}],
                                          add_generation_prompt=True) for t in texts]

r1 = batch_generate(model, tokenizer, render([...]), max_tokens=2048,
                    return_prompt_caches=True)
# NOTE: batch caches are NOT updated in place — you must pass r1.caches forward.
r2 = batch_generate(model, tokenizer, render([...]), prompt_caches=r1.caches)
```

---

## Sources

Everything in this guide traces to one of the following, all read in the session that produced it
(2026-07-27).

**Evidence class 1 — repository source read on disk.**
`ml-explore/mlx-lm` at `e5baded8c1d286754edb479ffbde4655a68e2758` (2026-07-26), package version
`0.31.3`. Files read directly for this guide: `setup.py`, `mlx_lm/__init__.py`, `mlx_lm/cli.py`,
`mlx_lm/_version.py`, `mlx_lm/generate.py` (2,195 lines), `mlx_lm/models/cache.py` (1,764 lines),
`mlx_lm/sample_utils.py`, `mlx_lm/tokenizer_utils.py`, `mlx_lm/utils.py`, `mlx_lm/server.py`,
`mlx_lm/cache_prompt.py`, `mlx_lm/chat.py`, `mlx_lm/convert.py`, `mlx_lm/fuse.py`,
`mlx_lm/examples/chat.py`, `mlx_lm/examples/batch_generate_response.py`.

**Evidence class 2 — the research corpus.**
`notes/repos/mlx-lm.md` (2,081 lines) — the full repository deep-dive.
`notes/repos/issues-mlx-stack.md` (1,183 lines) — GitHub issue and PR mining across `mlx`,
`mlx-lm`, `mlx-swift-lm`, `mlx-swift-examples`; source of every issue number and every
community-measured figure in §5.5, §6, §7 and §9.
`notes/transcripts/evals-mlx.md` (1,738 lines) — WWDC26 session 232 transcript plus repository
cross-checks; source of the four-layer stack, the batchability gate cross-check, and the server
concurrency defaults.
`notes/web/mlx-docs-site.md` (5,465 lines) — the MLX documentation crawl; consulted for
`mlx.launch` invocation forms.
`notes/CORRECTIONS-PENDING.md` — C5 (prefix reuse and hybrid architectures) and C10.4 (distributed
hostfile shape) are applied in §5.1 and §2.9.

**Evidence class 3 — project-published measurements.** `mlx_lm/BENCHMARKS.md`, measured on a 64 GB
M4 Max with mlx 0.29.2.dev, mlx-lm 0.28.2, macOS 26.1. Attributed as project-published, not
Apple-published.

**Evidence class 5 — community measurement.** Every table in §6.2, §6.3, §6.4, §7.1, §7.6 and §7.7
is community-measured and labelled as such at the point of use, with hardware where the source
states it.

**Not used:** no figure in this guide was recalled from memory, and no API name, flag, default or
error string appears here without a file, line, or issue number behind it. Where we could not
verify, §10.4 says so.

[^trust-cli-source]: At the pinned revision, [`mlx_lm/cli.py`](https://github.com/ml-explore/mlx-lm/blob/e5baded8c1d286754edb479ffbde4655a68e2758/mlx_lm/cli.py)
    lists all 17 commands. [`manage.py`](https://github.com/ml-explore/mlx-lm/blob/e5baded8c1d286754edb479ffbde4655a68e2758/mlx_lm/manage.py),
    [`upload.py`](https://github.com/ml-explore/mlx-lm/blob/e5baded8c1d286754edb479ffbde4655a68e2758/mlx_lm/upload.py),
    and [`share.py`](https://github.com/ml-explore/mlx-lm/blob/e5baded8c1d286754edb479ffbde4655a68e2758/mlx_lm/share.py)
    have no `--trust-remote-code` argument; the model-loading commands define it.
[^sampler-source]: [`make_sampler` at the pinned mlx-lm revision](https://github.com/ml-explore/mlx-lm/blob/e5baded8c1d286754edb479ffbde4655a68e2758/mlx_lm/sample_utils.py#L10-L69)
    returns `argmax` only for `temp == 0`; otherwise it constructs the sampling chain.
