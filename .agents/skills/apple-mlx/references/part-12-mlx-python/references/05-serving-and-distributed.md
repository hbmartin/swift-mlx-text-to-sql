# `mlx_lm.server`, local agents, and distributed inference over Thunderbolt

**Part 12 · MLX in Python · Reference 05**

**Version floor.** Two halves, two floors. **Serving on one machine** needs
**`mlx-lm` 0.31.3** on **`mlx` ≥ 0.31.2** (`setup.py`'s `MIN_MLX_VERSION`), Python **≥ 3.10 in
practice** despite a declared 3.8, and **macOS ≥ 15** if you want the model's memory wired.
Nothing on this half requires macOS 26 or 27 at all — `mlx_lm.server` has run on Apple silicon
for years and now also runs on **CUDA and CPU** via the `mlx-lm[cuda13]` / `[cuda12]` / `[cpu]`
extras. **Distributing across machines** is where the new gates are: **RDMA over Thunderbolt 5
requires macOS 26.2**, and the **JACCL** backend that uses it needs a Thunderbolt cable between
*every pair* of Macs. On the client side, **Xcode 27** is what added *Settings ▸ Intelligence ▸
Add Chat Provider ▸ Locally Hosted*, and **`ChatCompletionsLanguageModel`** — the Foundation
Models conformer that turns this server into a `LanguageModelSession` backend — is **iOS 27 /
macOS 27**. The M5 prompt-processing story needs **M5 silicon** and no flags.

---

## What this covers

Two halves. First one machine, then many.

**Serving one machine.** `mlx_lm.server` is an OpenAI chat-completions-compatible HTTP server
with structured tool calling and reasoning-model support. Apple's framing in WWDC26 session 232
is that it is *"a drop-in replacement for any cloud LLM API"* — which is close to true and worth
a careful read of where it deviates. You will get: every CLI flag with its verified default;
every endpoint; every request field the server actually parses; the response shape including the
two fields most clients get wrong (`message.reasoning` and
`usage.prompt_tokens_details.cached_tokens`); and **continuous batching**, which is the single
feature that decides whether a swarm of parallel subagents runs concurrently or queues.

**The local agent stack.** MLX → MLX-LM → MLX-LM Server → agent. The OpenCode configuration.
The **Xcode 27** click-path, which is the one most readers of this series will actually use. The
`ChatCompletionsLanguageModel` bridge that puts any Hugging Face checkpoint behind
`LanguageModelSession` today (Part 4). And the reason prompt processing, not decode, is the
number that matters for agents.

**Serving many machines.** `mlx.launch`, the JSON hostfile and its positional RDMA adjacency
matrix, `mlx.distributed_config`, the Thunderbolt-5 RDMA setup sequence, mesh vs ring, tensor vs
pipeline parallelism, distributed fine-tuning, and Apple's measured numbers on four M3 Ultras.
Plus the open bug cluster in the distributed backends, because this surface is weeks old and it
shows.

## What this does *not* cover

- **Loading, generating, sampling, and prompt caching in-process.** That is this part's
  generation guide; here we only cover the server's use of those primitives.
- **Quantization and fine-tuning mechanics.** `mlx_lm.convert`, `mlx_lm.lora`, DWQ/AWQ/GPTQ —
  other guides in Part 12. Distributed *launching* of `mlx_lm.lora` is covered here; the
  training itself is not.
- **Swift.** `mlx-swift-lm`, `MLXFoundationModels`, and `DistributedGroup` are
  [Part 13](../../part-13-mlx-swift/README.md).
- **Writing a `LanguageModel` conformer by hand.** [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md)
  guides 02 and 03. This guide only shows the wiring.
- **Metal kernels and NAX.** [Part 11](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-11-metal-and-tensorops/README.md).

## What you need

- **A Mac with Apple silicon** and `pip install mlx-lm`. For the agent half, that is genuinely
  all you need.
- **`rich` and `regex` installed separately** if you are going to touch `mlx_lm.chat`,
  `mlx_lm.lora`, or any tool parser. See §1.1 — they are imported at module scope but are *not*
  declared dependencies at this commit.
- For the distributed half: **two or more Macs**, **Thunderbolt 5 cables between every pair**,
  **macOS 26.2 or later on every node**, password-less SSH between them, and a willingness to
  reboot each machine at least once.
- For the Xcode half: **Xcode 27**.

---

## ⚠️ Read this before you trust a signature below

This guide's evidence is unusually good on one half and unusually thin on the other, and you
should know which is which.

**The serving half is class-1 evidence.** Everything about `mlx_lm.server` below was read out of
the checked-out repository at
`repos/ml-explore__mlx-lm` — `mlx_lm/server.py` (1,871 lines), `mlx_lm/SERVER.md`,
`mlx_lm/generate.py`, `mlx_lm/models/cache.py` — in this session. Flag names, defaults, HTTP
status codes and error strings are quoted, not remembered.

**The distributed half rests on three sources that mostly agree.** In precedence order: the MLX
repository's own Python (`python/mlx/_distributed_utils/{launch,config,common}.py`, read on disk),
the MLX documentation site crawl, and WWDC26 session **233** *"Explore distributed inference and
training with MLX"*. Where they disagree — and they disagree twice, on a flag name and on how you
turn RDMA on — this guide says so and tells you which to trust.

**MLX moves weekly and this surface is new.** The clone is `--depth 50`, so most `git log` output
bottoms out at the graft boundary and no date in it should be treated as authoritative. Three NAX
correctness fix PRs opened, none merged, in the three days before 2026-07-27. There is an open cluster of
distributed-backend crash and hang reports (§24). Treat everything in Part B as sharp-edged.

**Markers.** ✅ VERIFIED means quoted from a source read this session, with the citation attached.
🟡 RECONSTRUCTED means the concept is attested but the exact spelling is inferred. 🔴 GAP means we
could not verify it, and the box says what would resolve it and what to do meanwhile.

---

## Contents

**Part A — serving one machine**

- [1. The four-layer local agent stack](#1-the-four-layer-local-agent-stack)
- [2. Launching the server: every flag](#2-launching-the-server-every-flag)
- [3. The endpoints](#3-the-endpoints)
- [4. The request body](#4-the-request-body)
- [5. The response body](#5-the-response-body)
- [6. Structured tool calling](#6-structured-tool-calling)
- [7. Reasoning models](#7-reasoning-models)
- [8. Continuous batching — the feature that makes subagents work](#8-continuous-batching--the-feature-that-makes-subagents-work)
- [9. The prompt cache, and what `cached_tokens` is telling you](#9-the-prompt-cache-and-what-cached_tokens-is-telling-you)
- [10. Why prompt processing dominates agentic work](#10-why-prompt-processing-dominates-agentic-work)
- [11. Pointing agents at it](#11-pointing-agents-at-it)
- [12. Load testing and capacity planning](#12-load-testing-and-capacity-planning)
- [13. Operational reality: the open server defects](#13-operational-reality-the-open-server-defects)

**Part B — serving many machines**

- [14. The four-layer distributed stack](#14-the-four-layer-distributed-stack)
- [15. Topology: mesh is strictly better than ring](#15-topology-mesh-is-strictly-better-than-ring)
- [16. Turning RDMA on — the setup sequence](#16-turning-rdma-on--the-setup-sequence)
- [17. The hostfile](#17-the-hostfile)
- [18. `mlx.distributed_config`](#18-mlxdistributed_config)
- [19. `mlx.launch`](#19-mlxlaunch)
- [20. Running the server across machines](#20-running-the-server-across-machines)
- [21. Tensor vs pipeline parallelism](#21-tensor-vs-pipeline-parallelism)
- [22. Distributed fine-tuning, and the `--batch-size` trap](#22-distributed-fine-tuning-and-the---batch-size-trap)
- [23. Getting the weights onto the nodes: `mlx_lm.share`](#23-getting-the-weights-onto-the-nodes-mlx_lmshare)
- [24. Apple's measured numbers](#24-apples-measured-numbers)
- [25. The distributed bug cluster](#25-the-distributed-bug-cluster)
- [26. Running without `mlx.launch`](#26-running-without-mlxlaunch)

**Scope:** this reference intentionally ends at §26; operational checks and unresolved gaps are
declared in the sections they qualify. The CLI surface is pinned to the inspected mlx-lm revision.[^scope-source]

---

# Part A — serving one machine

## 1. The four-layer local agent stack

Session 232 opens with a distinction worth restating, because it is the reason this guide has a
server in it at all rather than just a Python API.

> ✅ **VERIFIED** — WWDC26 session 232, *"Run local agentic AI on the Mac using MLX"*
> (transcript lines 6–17): *"Here's the chat experience you're familiar with. You send a prompt to
> the language model. The model sends a response back. **If you need to act on that response, run a
> command, check a file, or fix an error, that's on you.** But now you're talking to an agent.
> **The agent talks to the model to decide what to do. Then it calls tools to actually do it:
> running commands, reading files, hitting APIs — It observes the results and goes back to the
> model to figure out the next step. User to agent. Agent to model. Agent to tools. This is the
> agentic loop. And it keeps cycling until your task is done.**"*

An agent is a process that owns a loop. It needs a *model endpoint*, not a model object. That is
why the local agentic stack is four layers and why the third one is an HTTP server:

| Layer | Component | Apple's description, verbatim (232:33–49) |
|---|---|---|
| 4 (top) | **The agent** | "any framework or tool that speaks the **OpenAI chat completions protocol**: **Xcode, OpenCode, Pi agent, a custom script**, or anything else." |
| 3 | **MLX-LM Server** | "an **OpenAI-compatible HTTP server** that exposes your local model through a standard API. It supports **structured tool calling** so the model can invoke functions reliably, and **reasoning models** that can analyze complex problems step-by-step before responding. **It's a drop-in replacement for any cloud LLM API.**" |
| 2 | **MLX-LM** | "provides everything you need to **load, run, quantize, and fine-tune** large language models. It supports **thousands of models from HuggingFace** and gives you both **CLI tools and a Python API**." |
| 1 (bottom) | **MLX** | "our **open-source array framework purpose-built for Apple silicon**. It handles all the **low-level computation, Metal acceleration, and memory management**." |

The payoff Apple states, and the reason a lot of readers are here:

> ✅ **VERIFIED** — 232:18–19: *"What makes this particularly exciting on Apple silicon is that
> **the entire loop can run locally. Your data stays on your machine; AI is available anywhere at
> any time and there are no usage costs.**"*

### 1.1 Three steps, and the two packages nobody tells you about

> ✅ **VERIFIED** — 232:56: *"**It only takes three steps to go from zero to a fully local agentic
> workflow.**"*

```bash
# 1. install
pip install mlx-lm

# 2. start the server with a model that supports tool calling
mlx_lm.server --model mlx-community/Qwen3-8B-4bit

# 3. point your agent's base URL at http://localhost:8080/v1
```

Apple's advice on step 2 is worth taking literally:

> ✅ **VERIFIED** — 232:61–62: run it *"with a model that supports tool calling. **Starting with a
> small model to test your set-up is always a good idea.**"*

⚠️ **Two undeclared runtime dependencies.** ✅ VERIFIED from `setup.py` and the module sources at
mlx-lm HEAD `e5baded`: `install_requires` is
`["mlx>=0.31.2; platform_system == 'Darwin'", "numpy", "transformers>=5.7.0", "sentencepiece",
"protobuf", "pyyaml", "jinja2"]` — and **`rich` and `regex` are not in it**, despite being imported
at module scope. `mlx_lm/cli_ui.py` does `from rich.console import Console` and is pulled in by
`chat.py`, `lora.py` and everything under `tuner/`. Every module in `mlx_lm/tool_parsers/` does
`import regex as re`. A bare `pip install mlx-lm` therefore gives you a server that can start but
a `mlx_lm.chat` that cannot import, and tool parsing that fails on the first tool-capable model.

```bash
pip install mlx-lm rich regex
```

🔴 **GAP — whether the published PyPI wheel declares them.** The `setup.py` in this checkout omits
both. Whether the wheel on PyPI for 0.31.3 carries them (e.g. via a different packaging path) was
not verified. **Safe default:** install them explicitly; it is idempotent if they are already
declared.

Also note the declared Python floor is stale. ✅ VERIFIED: `python_requires=">=3.8"`, but
`mlx_lm/quant/awq.py` and the tool parsers use PEP-604 `X | None` annotations and `cli_ui.py` uses
`list[tuple[str, str]]`. **Use Python 3.10 or newer.**

### 1.2 The ecosystem claim

> ✅ **VERIFIED** — 232:51–53: *"Several popular apps and tools build on MLX and MLX-LM.
> **Ollama, LM Studio, and vLLM** are just a few of the most popular ones. The ecosystem is broad
> and growing, and **if you're using one of these tools, chances are you're already running on
> MLX.**"*

That is Apple naming three downstream consumers by name. It is a useful fact for two reasons.
First, if your team already standardised on LM Studio or Ollama, the model files and quantization
formats in this guide are the same ones you are already using. Second — and this matters for
Part 4 — all three of them also speak OpenAI chat-completions, which means everything in §11
about pointing a client at `mlx_lm.server` applies unchanged to them.

🟡 **RECONSTRUCTED — the exact nature of the Ollama / LM Studio / vLLM dependency on MLX.** Apple
says these tools "build on MLX and MLX-LM". The precise integration (vendored, optional backend,
subprocess) is not stated in the session and was not verified against those projects. Treat
"they can be MLX-backed" as the claim, not "they are always MLX".

---

## 2. Launching the server: every flag

Every row below is ✅ **VERIFIED** from `mlx_lm/server.py`'s `main()` argparse block, read on disk
this session. Where the help text is quoted it is verbatim.

| Flag | Type | Default | Notes |
|---|---|---|---|
| `--model` | str | **`None`** | Optional. With no model the server starts empty and loads lazily per request. |
| `--adapter-path` | str | `None` | LoRA/DoRA adapter directory. |
| `--host` | str | `127.0.0.1` | Loopback only by default. |
| `--port` | int | **`8080`** | Not 8000, not 11434. |
| `--allowed-origins` | comma-split list | `"*"` | See the footgun below. |
| `--draft-model` | str | `None` | Speculative decoding. **Disables continuous batching** (§8.4). |
| `--num-draft-tokens` | int | `3` | |
| `--trust-remote-code` | flag | `False` | Gates *both* remote tokenizer code and the `model_file` architecture hook. See §2.2. |
| `--log-level` | str | `INFO` | `DEBUG`/`INFO`/`WARNING`/`ERROR`/`CRITICAL`. |
| `--chat-template` | str | `""` | Override the tokenizer's template. |
| `--use-default-chat-template` | flag | `False` | |
| `--temp` | float | `0.0` | Default sampling temperature. `0.0` ⇒ argmax. |
| `--top-p` | float | `1.0` | Inactive unless `0 < top_p < 1.0`. |
| `--top-k` | int | `0` | `0` disables. |
| `--min-p` | float | `0.0` | `0.0` disables. |
| `--max-tokens` | int | `512` | Per-response default. |
| `--chat-template-args` | JSON str | `"{}"` | Help text verbatim: `'{"enable_thinking":false}'`. |
| `--decode-concurrency` | int | **`32`** | "When a request is batchable then decode that many requests in parallel" |
| `--prompt-concurrency` | int | **`8`** | "When a request is batchable then process that many prompts in parallel" |
| `--prefill-step-size` | int | `2048` | "Step size for prefill processing" |
| `--prompt-cache-size` | int | `10` | "Maximum number of distinct KV caches to hold in the prompt cache" |
| `--prompt-cache-bytes` | size | `None` | "Maximum size in bytes of the KV caches". Parsed by `_parse_size`, so `8GB` works. |
| `--pipeline` | flag | `False` | "Use pipelining instead of tensor parallelism" — distributed only (§21). |

A representative agent-serving launch:

```bash
mlx_lm.server \
  --model mlx-community/Qwen3-8B-4bit \
  --host 127.0.0.1 --port 8080 \
  --decode-concurrency 32 \
  --prompt-concurrency 8 \
  --prefill-step-size 2048 \
  --prompt-cache-size 20 \
  --prompt-cache-bytes 8GB \
  --log-level INFO
```

### 2.1 What happens at startup

✅ VERIFIED, `server.py` `main()`, verbatim:

```python
args = parser.parse_args()
if mx.metal.is_available():
    wired_limit = mx.device_info()["max_recommended_working_set_size"]
    mx.set_wired_limit(wired_limit)
```

The server wires the maximum recommended working set on any Metal-capable machine, before it has
loaded anything. Memory wiring requires **macOS 15 or later**; below that the call has no effect
and large models page. The mlx-lm README's documented escape hatch when the model is close to the
machine's limit is `sudo sysctl iogpu.wired_limit_mb=N`, with `N` greater than the model size in
MB but less than physical RAM.

Then the warning that should shape every deployment decision you make with this server:

> ✅ **VERIFIED** — `mlx_lm/SERVER.md` lines 7–9, verbatim: *"The MLX LM server is not recommended
> for production as it only implements basic security checks."*

Take that at face value. There is no authentication, no rate limiting, no request-size cap beyond
`Content-Length`, and the CORS policy defaults to permissive. This is a developer tool for
`127.0.0.1` and a trusted LAN, not an edge service.

### ⚠️ SILENT FAILURE: `--allowed-origins` defaults to a *string*, and it works by accident

✅ VERIFIED from the argparse declaration:

```python
parser.add_argument(
    "--allowed-origins",
    type=lambda x: x.split(","),
    default="*",
    help="Allowed origins (default: *)",
)
```

`type=` is only applied to values the user actually passes. So when you *don't* pass the flag, the
value is the **string** `"*"`, not the list `["*"]`. The membership test downstream is
`origin in allowed_origins` — and `"*" in "*"` evaluates to `True` because Python's `in` on a
string is a substring test. The default therefore behaves like "allow everything", which is what
was intended, but for the wrong reason.

The failure mode is the interesting part. Pass the flag and you get a real list, and the check
becomes exact membership. Pass nothing and you get substring matching against `"*"` — which means
*every* origin matches, including ones you would never have listed. If you are hardening this
server, **always pass `--allowed-origins` explicitly**, even to set it to `"*"`, so you are on the
list code path rather than the substring code path. Nothing logs the difference.

### 2.2 `--trust-remote-code` is a security boundary, not a convenience flag

✅ VERIFIED — mlx-lm commit `bfa25a1`, *"Fix CVE-2026-5843: gate model_file execution behind
trust_remote_code (#1385)"*. Before that commit, a `model_file` key in a downloaded model's
`config.json` caused `load_model` to import and execute an arbitrary Python file **from the model
directory**, on a plain `load()`, with no opt-out. The fix, verbatim from `utils.load_model`:

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

`--trust-remote-code` is present on the **model-loading** mlx-lm commands, and it gates two different
things there: remote *tokenizer* code and the *architecture* file. It is intentionally absent from
`manage`, `upload`, and `share`, which do not load a model architecture or
tokenizer.[^trust-cli-source] The environment variable `MLX_LM_TRUST_REMOTE_CODE=1` works for the
CLI tools.

The CVE was reported against Docker Model Runner, which embeds mlx-lm. If you are running a server
that will load models chosen by a request body (`"model": "..."` is a per-request field — §4), you
are one flag away from remote code execution driven by an HTTP client. **Do not pass
`--trust-remote-code` on a server whose `model` field is client-controlled.**

---

## 3. The endpoints

✅ VERIFIED from `server.py`'s `do_POST` / `do_GET` / `do_OPTIONS` dispatch tables, read on disk.

**POST**

| Path | Handler | `object` in the response |
|---|---|---|
| `/v1/completions` | `handle_text_completions` | `"text_completion"`, id `cmpl-<uuid4>` |
| `/v1/chat/completions` | `handle_chat_completions` | `"chat.completion"` / `"chat.completion.chunk"`, id `chatcmpl-<uuid4>` |
| `/chat/completions` | `handle_chat_completions` | same as above |

Note that third row: **`/chat/completions` without the `/v1` prefix is a real, routed path.** That
is a deliberate compatibility affordance and it matters in §11.5, where a Foundation Models
conformer gets the prefixing wrong in the other direction.

**GET**

| Path | Behaviour |
|---|---|
| `/v1/models` | Lists locally cached models. |
| `/v1/models/<repo_id>` | Same list, filtered by the path suffix. |
| `/health` | `{"status": "ok"}` |

**OPTIONS** returns **204** with the CORS headers. Any unrecognised path on either verb returns
**404** with the literal body `Not Found`.

`/v1/models` does not enumerate everything in your Hugging Face cache. ✅ VERIFIED —
`handle_models_request` scans the HF cache and only reports repositories that contain all of
`["config.json", "model.safetensors.index.json", "tokenizer_config.json"]`. A single-shard model
saved without an index file will not appear in the listing even though it loads fine when named
explicitly. That is a discovery gap, not a loading failure — but agents that populate a model
picker from `/v1/models` will show the user an incomplete list.

The `system_fingerprint` field is built as:

```python
system_fingerprint = f"{mlx_lm_version}-{mx.__version__}-{platform.platform()}-{gpu_arch}"
```

which is unusually useful — unlike OpenAI's opaque fingerprint, this one tells you exactly which
mlx-lm, which mlx, which OS build and which GPU generation produced a response. Log it. When you
come back to a regression in three weeks it is the only thing that will let you reconstruct the
stack.

### 3.1 Health checks that lie

⚠️ Worth knowing before you wire `/health` into a supervisor: it is a **static** handler. It does
not touch the generation thread, the batch generator, or the model. Community bug report
**mlx-lm#1493** (open, 10 comments) documents a livelocked server where *"`GET /v1/models`
returned 200 throughout"* while every completion hung for more than 180 seconds. `/health` would
have behaved the same way. Community-reported; see §13.1 for the full diagnosis and the liveness
signal that actually works.

---

## 4. The request body

✅ VERIFIED — the field list below is exactly what `do_POST` parses out of the JSON body
(`server.py` lines 1110–1147 in the notes' line numbering), cross-checked against
`mlx_lm/SERVER.md`.

```
stream (False), stream_options, model ("default_model"), draft_model ("default_model"),
num_draft_tokens (CLI default 3), adapters (None),
max_completion_tokens | max_tokens (CLI default 512),
temperature, top_p, top_k, min_p,
repetition_penalty (0.0), repetition_context_size (20),
presence_penalty (0.0), presence_context_size (20),
frequency_penalty (0.0), frequency_context_size (20),
xtc_probability (0.0), xtc_threshold (0.1),
logit_bias (None), logprobs (False), top_logprobs (-1),
seed (None), chat_template_kwargs (None),
stop (str or list[str]), messages, tools, role_mapping, prompt
```

Four things in that list are not in the OpenAI API and are worth calling out:

- **`model` defaults to the magic string `"default_model"`**, which `ModelProvider` maps to
  whatever `--model` / `--adapter-path` / `--draft-model` you launched with. So a client that omits
  `model` entirely works. A client that sends a *different* repo id causes a model swap — and
  swapping models **drains the in-flight batch** (§8.5).
- **`adapters`** lets a request select a LoRA adapter path. `SERVER.md` states the constraint
  verbatim: *"The path must be relative to the directory the server was started in."*
- **`role_mapping`** customises the role prefixes used when rendering the prompt.
- **`xtc_probability` / `xtc_threshold`** expose XTC sampling per request.

### 4.1 Validation, and the status codes you will actually see

✅ VERIFIED from `validate_model_parameters` and `do_POST`:

- `max_tokens >= 0`; `temperature >= 0`; `0 <= top_p <= 1`; `top_k >= 0`; `0 <= min_p <= 1`;
  `num_draft_tokens >= 0`; all penalties and context sizes `>= 0`;
  `0 <= xtc_probability <= 1`; `0 <= xtc_threshold <= 1`; `logit_bias` must be a dict of
  int → float.
- `top_logprobs` must be an int in `[0, 11]` **or** the sentinel `-1` meaning "off". Note that
  `SERVER.md` documents the range as 1–10; the code accepts 0–11. Trust the code.

Status codes, verbatim from the handlers:

| Situation | Code | Body |
|---|---|---|
| Unrecognised path | 404 | `Not Found` |
| Missing `Content-Length` | **411** | `{"error": "Content-Length header is required"}` |
| `Content-Length` not an integer | 400 | JSON error |
| Body is not valid JSON, or not a dict | 400 | JSON error |
| **Any exception while creating the generator** | **404** | `{"error": "<str(e)>"}` |

That last row is the one that will cost you an afternoon.

### ⚠️ SILENT FAILURE: model-load and tokenization errors come back as **HTTP 404**

✅ VERIFIED — `server.py` `handle_completion`:

```python
try:
    ctx, response = self.response_generator.generate(
        request, args, progress_callback=keepalive_callback,
    )
except Exception as e:
    self._set_completion_headers(404)
    self.end_headers()
    self.wfile.write(json.dumps({"error": str(e)}).encode())
    return
```

Every failure inside generator construction — model not found, out of memory, an unsupported
architecture, a tokenizer that will not load, a malformed chat template — surfaces as **404 Not
Found**, the same status the server returns for a mistyped URL.

This is not merely ugly. Most OpenAI-compatible client libraries treat 404 as *"this endpoint does
not exist"* and either fail fast with a confusing message about the base URL, or fall back to a
different route. Agent frameworks that retry on 5xx and give up on 4xx will give up. And because
the body is a valid JSON object with an `error` key, a client that only inspects the status code
never sees the real message, which is right there.

**What to do.** Never diagnose an mlx-lm server failure from the status code. Always print the
response body. When configuring an agent, if you get a 404 that looks like the base URL is wrong,
`curl` the same request and read `.error` before you touch the URL:

```bash
curl -s localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"mlx-community/Qwen3-8B-4bit",
       "messages":[{"role":"user","content":"hi"}]}' | python3 -m json.tool
```

If the body is `{"error": "..."}`, the endpoint is fine and the *model* is the problem.

### 4.2 Streaming

`"stream": true` produces SSE. `"stream_options": {"include_usage": true}` emits a final
usage-only chunk before `data: [DONE]`.

✅ VERIFIED and genuinely clever: during long prefills the server emits **SSE comments** as
keepalives, formatted `": keepalive {processed}/{total}\n\n"`, driven from the prompt-progress
callback. SSE comments are ignored by conforming clients but keep the connection warm, so a
120-second prefill on a 200k-token agent context does not time out at the proxy. If you are
writing a client by hand, make sure your SSE parser tolerates comment lines — a naïve parser that
assumes every line starts with `data:` will choke.

---

## 5. The response body

✅ VERIFIED shape, assembled from the response-construction code:

```json
{
  "id": "chatcmpl-…",
  "system_fingerprint": "0.31.3-0.32.0-macOS-…-applegpu_gXX",
  "object": "chat.completion",
  "model": "mlx-community/Qwen3-8B-4bit",
  "created": 1699999999,
  "choices": [
    {
      "index": 0,
      "finish_reason": "stop",
      "message": {
        "role": "assistant",
        "content": "…",
        "reasoning": "…",
        "tool_calls": [ … ]
      }
    }
  ],
  "usage": {
    "prompt_tokens": 12043,
    "completion_tokens": 210,
    "total_tokens": 12253,
    "prompt_tokens_details": { "cached_tokens": 11890 }
  }
}
```

Three fields deviate from what a cloud-API client expects.

**`message.reasoning`, not `message.reasoning_content`.** ✅ VERIFIED at `server.py:1307`:

```python
if reasoning_text:
    choice[key_name]["reasoning"] = reasoning_text
```

and in the streaming path the delta key is `delta.reasoning`. Apple's own example
(`mlx_lm/examples/openai_reasoning_content.py`) reads it as `response.choices[0].message.reasoning`
and `chunk.choices[0].delta.reasoning`. Several other OpenAI-compatible servers standardised on
`reasoning_content`; clients written against those will silently show empty thinking panes. See §7.

**`finish_reason` becomes `"tool_calls"`.** ✅ VERIFIED at `server.py:1471` — when generation ends
with `stop` *and* a tool call was produced, the reason is rewritten. `SERVER.md` still documents
only `"stop"` and `"length"`; the code emits three values. Trust the code.

**`usage.prompt_tokens_details.cached_tokens`.** ✅ VERIFIED at `server.py:1294` and `1540` — the
server reports how many prompt tokens were served out of the KV cache rather than recomputed, but
only when the count is non-negative. This is the single most useful number the server gives you
and §9 is about reading it.

**`logprobs`** has two shapes. With `top_logprobs > 0` you get
`choices[0].logprobs.content = [dict(top[0], top_logprobs=top), …]`. With bare `"logprobs": true`
you get `[{"id": tok, "logprob": lp}, …]`.

---

## 6. Structured tool calling

Apple's claim is that the server *"supports **structured tool calling** so the model can invoke
functions reliably"* (232:33–49). That is true, and the mechanism is more interesting than the
claim, because it explains the one failure mode you will hit.

### 6.1 How a tool call actually gets out of a language model

Models do not emit JSON tool calls natively. They emit **text** containing family-specific
markers, and something downstream has to recognise those markers and parse what is between them.
mlx-lm ships **ten** parsers, one per marker convention. ✅ VERIFIED — `mlx_lm/tool_parsers/`, each
module exporting `tool_call_start`, `tool_call_end`, and
`parse_tool_call(text, tools=None) -> dict | list[dict]` with keys `name` and `arguments`:

| Module | `tool_call_start` / `tool_call_end` | Payload format |
|---|---|---|
| `json_tools` | `<tool_call>` / `</tool_call>` | plain JSON `{"name":…, "arguments":…}` |
| `qwen3_coder` | `<tool_call>` / `</tool_call>` | `<function=NAME><parameter=k>v</parameter></function>`, values coerced by the tool's JSON-schema type |
| `gemma4` | `<\|tool_call>` / `<tool_call\|>` | `call:name{key: …}`, recursive brace regex |
| `function_gemma` | — | `call:name{…}` variant |
| `mistral` | `[TOOL_CALLS]` / `""` (**empty**) | `name[ARGS]{json}` |
| `kimi_k2` | `<\|tool_calls_section_begin\|>` / `…_end\|>` | `functions.name:0<\|tool_call_argument_begin\|>{json}`; returns a **list**, with `id` |
| `pythonic` | `<\|tool_call_start\|>` / `<\|tool_call_end\|>` | `[name(a="x", b=2)]`, parsed with `ast.literal_eval` |
| `glm47` | `<arg_key>` / `<arg_value>` | three accepted forms |
| `longcat` | `<longcat_tool_call>` | `<longcat_arg_key>` / `<longcat_arg_value>` |
| `minimax_m2` | `<minimax:tool_call>` | `<invoke name="…"><parameter name="…">…</parameter></invoke>` |

Selection is automatic. ✅ VERIFIED — `_infer_tool_parser(chat_template)` matches literal
substrings **in this order**: `<minimax:tool_call>` → `minimax_m2`; `<|tool_call>` +
`<tool_call|>` → `gemma4`; `<start_function_call>` → `function_gemma`; `<longcat_tool_call>` →
`longcat`; `<arg_key>` → `glm47`; `<|tool_list_start|>` → `pythonic`;
`<tool_call>\n<function=` → `qwen3_coder`; `<|tool_calls_section_begin|>` → `kimi_k2`;
`[TOOL_CALLS]` → `mistral`; `<tool_call>` + `tool_call.name` → `json_tools`; otherwise `None`.
A `tool_parser_type` key in `tokenizer_config.json` overrides the inference.

Once parsed, `ToolCallFormatter` emits the OpenAI shape:
`{"function": {...}, "type": "function", "id": "<uuid4>", "index": i}`.

### 6.2 The text state machine, and why it replaced a token one

Marker detection used to run on token IDs. It was replaced in mlx-lm PR **#1501**, and the commit
message is the clearest available statement of a problem that bites every homebrew implementation:

> ✅ **VERIFIED** — mlx-lm PR #1501, verbatim: *"The token based `SequenceStateMachine` has a
> design flaw that makes it impossible to identify the state change because substrings can be
> encoded in different ways. This replaces it with `TextStateMachine` so we switch state on the
> actual string and not the tokens. It also introduces a `StopSequenceMatcher`."*

The `TextStateMachine` docstring says the same thing from the other side: *"Matching on text
rather than token ids is robust to tokenization differences (e.g. a marker's trailing `>` being
merged with the following byte)."* That single change closed five separate issues (#1373, #1447,
#1406, #1336, #1160). If you are writing your own streaming tool-call parser anywhere in this
stack, **match on decoded text, not on token IDs**, and buffer text you cannot yet rule out as a
partial marker.

The state machine's shape, ✅ VERIFIED from `mlx_lm/generate.py`:

```python
from mlx_lm.generate import TextStateMachine

sm = TextStateMachine(transitions={
    "normal":    [("<think>", "reasoning"), ("<tool_call>", "tool")],
    "reasoning": [("</think>", "normal")],
    "tool":      [("</tool_call>", "normal")],
})
state = sm.make_state(initial="normal")
state, emittable_text, current_state = TextStateMachine.step(state, chunk)
state, remaining, cur = TextStateMachine.flush(state)    # on finish_reason == "length"
state, cur = TextStateMachine.discard(state)             # on finish_reason == "stop"
```

Text is only emitted once it can no longer be part of a match. The runtime state is the tuple
`(state_name, trie_node, states, buffer)`.

### ⚠️ SILENT FAILURE: passing `tools` to a model that cannot call tools only *warns*

✅ VERIFIED — `server.py`, `_tokenize`, verbatim:

```python
if tools and not tokenizer.has_tool_calling:
    logging.warning(
        "Received tools but model does not support tool calling. "
        "If you think this is an error, file an issue here: "
        "https://github.com/ml-explore/mlx-lm/issues"
    )
```

The request is **not rejected**. It proceeds, the tools are dropped from the rendered prompt, the
model answers in prose, `finish_reason` comes back `"stop"` rather than `"tool_calls"`, and
`message.tool_calls` is absent.

From the agent's point of view this is indistinguishable from *"the model decided not to call a
tool this turn."* Most agent frameworks respond by feeding the prose back into the loop and
trying again, forever, or by declaring the task complete having done nothing. The only evidence
is a `WARNING` line on the server's stdout — which, if you launched with `--log-level ERROR` or
redirected the server to `/dev/null` in a launchd plist, does not exist.

**How to detect it before you waste an hour.** `has_tool_calling` is derived from the tokenizer's
chat template. Check it directly, in-process, before you commit to a model:

```python
from mlx_lm import load

_, tokenizer = load("mlx-community/Qwen3-8B-4bit")
print("tool calling:", tokenizer.has_tool_calling)
print("start marker :", tokenizer.tool_call_start)
print("end marker   :", tokenizer.tool_call_end)
print("parser       :", tokenizer.tool_parser)
print("thinking     :", tokenizer.has_thinking, tokenizer.think_start, tokenizer.think_end)
```

If `has_tool_calling` is `False`, no server flag will fix it. Pick a different checkpoint. This is
exactly what Apple means by *"a model that supports tool calling"* in step 2 of the three-step
setup, and it is the most common reason a local agent silently does nothing.

There is a second, related trap: parse failures are also swallowed. ✅ VERIFIED —
`ToolCallFormatter` logs *"Failed to parse tool call (…) — tool text was likely truncated
mid-generation."* and **drops** the call. A tool call that runs past `max_tokens` mid-JSON
therefore disappears rather than erroring. If your agent occasionally "forgets" to call a tool on
long turns, raise `max_tokens` before you rewrite the prompt.

### 6.3 A complete tool-use round trip

Apple ships this in `mlx_lm/examples/openai_tool_use.py`; the version below is expanded into a
runnable script with imports and the full second turn.

```python
# pip install openai
import json
from openai import OpenAI

MODEL = "mlx-community/Qwen3-8B-4bit"
client = OpenAI(base_url="http://localhost:8080/v1", api_key="not-needed")

def multiply(a: float, b: float) -> str:
    return str(a * b)

functions = {"multiply": multiply}

tools = [{
    "type": "function",
    "function": {
        "name": "multiply",
        "description": "Multiply two numbers.",
        "parameters": {
            "type": "object",
            "properties": {
                "a": {"type": "number", "description": "The first number."},
                "b": {"type": "number", "description": "The second number."},
            },
            "required": ["a", "b"],
        },
    },
}]

messages = [{"role": "user", "content": "What is 3.7 times 42?"}]

# --- turn 1: the model asks for a tool ---
response = client.chat.completions.create(model=MODEL, messages=messages, tools=tools)
choice = response.choices[0]
print("finish_reason:", choice.finish_reason)      # -> "tool_calls" on success

if choice.finish_reason != "tool_calls":
    raise SystemExit(
        "No tool call was produced. Check tokenizer.has_tool_calling for this model, "
        "and check the server log for the 'model does not support tool calling' warning."
    )

call = choice.message.tool_calls[0]
function = call.function
result = functions[function.name](**json.loads(function.arguments))

# --- turn 2: hand the result back ---
messages.append(choice.message)
messages.append({"role": "tool", "name": function.name, "content": result})
final = client.chat.completions.create(model=MODEL, messages=messages, tools=tools)
print(final.choices[0].message.content)
```

The `api_key="not-needed"` is required by the OpenAI SDK's client constructor, not by the server —
mlx-lm never inspects `Authorization`. Note the explicit `finish_reason` check: given §6.2's
silent-warning behaviour, an agent that does not assert on `finish_reason` will loop.

---

## 7. Reasoning models

The second capability Apple names for the server is *"reasoning models that can analyze complex
problems step-by-step before responding."* Mechanically this is the same state machine as tool
calls, with a different pair of markers.

✅ VERIFIED — `TokenizerWrapper._infer_thinking` in `mlx_lm/tokenizer_utils.py`:

```python
THINK_TOKENS = [("<think>", "</think>"), ("<longcat_think>", "</longcat_think>")]
# multi-token case: if "<|channel>" and "<channel|>" are in the vocab →
#   think_start = "<|channel>thought", think_end = "<channel|>"
```

The wrapper exposes `has_thinking`, `think_start`, `think_end`, `think_start_id`, `think_end_id`,
`think_start_tokens`, `think_end_tokens`, plus `find_think_start` / `rfind_think_start` /
`find_think_end` / `rfind_think_end`.

Text produced while the machine is in the `reasoning` state accumulates into `reasoning_text` and
is delivered on `message.reasoning` (non-streaming) or `delta.reasoning` (streaming) — **not**
`message.content`. So a client that renders only `content` shows the user a correct answer with
the reasoning invisible, which is usually what you want, and a client that expected
`reasoning_content` shows nothing at all in its thinking pane, which is not.

Apple's own client-side example, ✅ VERIFIED verbatim from
`mlx_lm/examples/openai_reasoning_content.py`:

```python
reasoning = response.choices[0].message.reasoning
...
if (reasoning := chunk.choices[0].delta.reasoning) is not None: ...
```

### 7.1 Turning thinking off

Most reasoning-capable chat templates take a Jinja flag. The server surfaces it two ways:

```bash
# server-wide default
mlx_lm.server --model mlx-community/Qwen3-8B-4bit \
              --chat-template-args '{"enable_thinking":false}'
```

```jsonc
// per request
{
  "model": "mlx-community/Qwen3-8B-4bit",
  "messages": [ … ],
  "chat_template_kwargs": {"enable_thinking": false}
}
```

✅ VERIFIED: `--chat-template-args` is `type=json.loads` with default `"{}"`, and its help text
uses exactly that example. `chat_template_kwargs` is in the parsed request-field list.

🟡 **RECONSTRUCTED — the flag name is per-template, not per-server.** `enable_thinking` is what
Qwen-family templates use and what Apple's help text shows. Other families use other keys, and
mlx-lm passes whatever you give it straight through to `apply_chat_template`. There is no
validation: a misspelled key is silently ignored by Jinja and thinking stays on. **Safe default:**
after setting it, send one request and assert that `message.reasoning` is absent.

### 7.2 Why this matters for agents specifically

Reasoning tokens are generated tokens. They cost decode time, they consume the context window,
and in an agentic loop they are regenerated on **every** step. For a coding agent doing twenty
tool round-trips, thinking can easily double wall-clock time for no improvement in tool-selection
accuracy. Measure it both ways on your own workload before deciding. The `usage.completion_tokens`
figure includes reasoning tokens, so an A/B is one field away.

---

## 8. Continuous batching — the feature that makes subagents work

This is the section to read if you only read one.

### 8.1 The problem

> ✅ **VERIFIED** — 232:85–88: *"In practice, **agents rarely work alone. A common pattern is for
> an agent to spawn several subagents, each tackling a different part of the problem in parallel.
> One might be reading documentation, another searching code, and a third writing tests; all at
> the same time. That means multiple requests hitting your local model simultaneously.**"*

A naïve server processes those serially. Subagent 2 waits for subagent 1's full generation, which
on a local 8B model at 60 tok/s and a 600-token answer is ten seconds of nothing. With five
subagents your "parallel" fan-out is a queue and your agent framework's timeouts start firing.

### 8.2 What Apple says the server does

> ✅ **VERIFIED** — 232:89–93: *"**MLX-LM Server handles this with continuous batching.** Instead
> of processing requests one at a time, **it dynamically groups incoming requests into batches and
> processes them together on the GPU. New requests can join a batch in progress without waiting for
> the current one to finish.** The result is that **your subagents don't stall waiting in a queue.
> They all get served concurrently**, which keeps the entire agentic workflow moving."*

That claim is accurate, and the source shows the mechanism.

### 8.3 The mechanism, verified

✅ VERIFIED — `server.py`, `ResponseGenerator._generate()`. A single background thread owns the
GPU. Requests arrive on a `queue.Queue` as `(response_queue, CompletionRequest,
GenerationArguments)`. The batched path constructs one `BatchGenerator`:

```python
batch_generator = BatchGenerator(
    model,
    completion_batch_size=self.cli_args.decode_concurrency,   # --decode-concurrency, default 32
    prefill_batch_size=self.cli_args.prompt_concurrency,      # --prompt-concurrency, default 8
    prefill_step_size=self.cli_args.prefill_step_size,        # --prefill-step-size, default 2048
    stream=generation_stream,
)
```

and every arriving request is *inserted into the live batch*, verbatim from the source:

```python
(uid,) = batch_generator.insert_segments(
    segments=[segments],
    max_tokens=[args.max_tokens],
    caches=[cache],
    all_tokens=[prompt[:prompt_cache_count]],
    samplers=[_make_sampler(args, tokenizer)],
    logits_processors=[_make_logits_processors(args)],
    stop_matchers=[stop_matcher],
)
```

Three things in that call are worth dwelling on, because together they are what "continuous"
means:

- **`insert_segments`, not `insert`.** The prompt is split into up to three segments — system
  prompt, user context, thinking tail — and the generator is guaranteed to stop at segment
  boundaries so each boundary's KV state can be checkpointed into the prompt cache separately
  (§9). ✅ VERIFIED from `_tokenize`'s docstring: *"Up to 3 segments that correspond to system
  prompt, context, thinking tail."*
- **`samplers=` and `logits_processors=` are per-request lists.** Temperature, top-p, penalties
  and logit bias are per-sequence inside one batched forward pass. Two subagents with different
  temperatures share a batch.
- **`max_tokens=` and `stop_matchers=` are per-request too.** Sequences finish independently and
  leave the batch; the rest keep going.

Under the hood `BatchGenerator` maps each regular cache class onto a batched one —
`KVCache → BatchKVCache`, `RotatingKVCache → BatchRotatingKVCache`, `CacheList` recursing — using
a left-padding convention documented verbatim in `BatchKVCache`'s docstring:

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

PR **#1072** added the asymmetry that makes mixed-length agent traffic efficient — ✅ VERIFIED,
verbatim: *"right padding for prefill, left padding for decode"* so finished sequences stop early:
*"Previously inserting a sequence of 100 tokens and 10,000 tokens would process ~20,000 tokens,
now we will process ~12,000."*

### 8.4 ⚠️ The two things that silently turn batching off

✅ VERIFIED — `server.py`, two separate gates:

```python
# ModelProvider.load(), server.py:352-356
# Compute batchability
is_batchable = draft_model is None
is_batchable = is_batchable and all(
    hasattr(c, "merge") for c in make_prompt_cache(model)
)
```

```python
# ResponseGenerator, server.py:621-622
def _is_batchable(self, args):
    return self.model_provider.is_batchable and args.seed is None
```

So there are **three** ways to lose continuous batching, and none of them produces an error:

1. **You launched with `--draft-model`.** Speculative decoding and continuous batching are
   mutually exclusive in this implementation. You get faster single-stream decode and serial
   handling of concurrent requests.
2. **The model's cache class has no `merge`.** This is architecture-determined. Models whose
   `make_cache()` returns `ArraysCache` — SSM / Mamba / gated-delta / linear-attention families
   and hybrids built on `CacheList` containing one — cannot batch. You cannot flag your way out.
3. **A request included `"seed"`.** Any single request with a seed forces the sequential path
   *and*, if a batch is already running, drains it first.

The third is the nastiest because it is client-controlled. Some agent frameworks set a seed by
default in the name of reproducibility. One such client on your server converts a batching server
into a serial one for every other client too, for the duration.

**Rules for agent workloads:** do not set `seed`, do not run a draft model, and check your model's
cache class before you commit to it:

```python
from mlx_lm import load
from mlx_lm.models.cache import make_prompt_cache

model, _ = load("mlx-community/Qwen3-8B-4bit")
caches = make_prompt_cache(model)
print({type(c).__name__ for c in caches})
print("batchable:", all(hasattr(c, "merge") for c in caches))
```

If that prints `False`, subagents will queue no matter what `--decode-concurrency` says.

### 8.5 The drain rule

✅ VERIFIED — `server.py`, verbatim comment and code:

```python
# We have a batch but this request cannot be added to the
# batch so drain it to process the request.
else:
    drain_batch = True
    unprocessed_requests.append((rqueue, request, args))
    continue
```

A request that cannot join the current batch — different model, an adapter change, a seed —
sets `drain_batch`. The generator then finishes every in-flight sequence, closes the
`BatchGenerator`, and starts fresh. Nothing is cancelled and nothing errors; it is a stall, not a
failure. The observable symptom is a latency cliff on unrelated requests that correlates with
nothing in their own parameters.

**Consequence for multi-model setups:** if you want two models served concurrently, run **two
servers on two ports**. One server alternating between two models will drain the batch on every
switch, and you will get the latency profile of a serial queue with the memory profile of two
models.

### 8.6 Tuning

`--decode-concurrency` (default 32) is the maximum number of sequences decoding simultaneously;
`--prompt-concurrency` (default 8) the maximum prefilling simultaneously. ✅ VERIFIED that
`BatchGenerator` enforces `completion_batch_size = max(completion_batch_size,
prefill_batch_size)` — setting prompt concurrency above decode concurrency silently raises the
latter rather than erroring.

Practical starting points, presented as reasoning rather than measurement because we have not
benchmarked them:

- **Decode is bandwidth-bound**, so raising `--decode-concurrency` costs little until KV memory
  runs out. The default 32 is generous for a laptop and cheap on a 512 GB Studio.
- **Prefill is compute-bound**, so `--prompt-concurrency` is where you trade agent-fan-out
  latency against per-request prefill latency. Eight concurrent prefills at
  `--prefill-step-size 2048` is a lot of simultaneous matmul.
- **`--prefill-step-size` is also a memory lever.** Lowering it reduces peak memory during prefill,
  which matters because quantized KV caches currently *raise* prefill peak memory (community
  finding, mlx-lm#1587, open, 11 comments).

🔴 **GAP — no published throughput/concurrency curve.** Neither Apple nor the repository publishes
a batch-size sweep for `mlx_lm.server`. `mlx_lm/BENCHMARKS.md` covers `mlx_lm.benchmark`, not the
server. **Safe default:** leave the defaults, measure with `benchmarks/server_benchmark.py` (§12)
at your real concurrency, and change one knob at a time.

---

## 9. The prompt cache, and what `cached_tokens` is telling you

Continuous batching decides whether requests run concurrently. The prompt cache decides how much
work each one has to do. For agents, the second matters more, because an agentic turn re-sends
the entire conversation plus every tool result so far.

### 9.1 The structure

✅ VERIFIED — `mlx_lm/models/cache.py`. The server holds one `LRUPromptCache`, sized by
`--prompt-cache-size` (default 10 distinct caches) and optionally capped by
`--prompt-cache-bytes`:

```python
class LRUPromptCache:
    def __init__(self, max_size: int = 10, max_bytes: int = 1 << 63)
    def fetch_nearest_cache(self, model, tokens) -> (cache_or_None, remaining_tokens)
    def insert_cache(self, model, tokens, prompt_cache, *, cache_type: str = "assistant")
    def trim_to(self, *, n_sequences=None, n_bytes=None)
    def stats_by_type(self) -> {cache_type: {"n_sequences": int, "n_bytes": int}}
    nbytes  # property
```

Underneath is a `PromptTrie` whose `search` returns:

```python
@dataclass
class PromptTrieResult:
    model: Any
    exact: Optional[List[int]]     # exact match found
    shorter: Optional[List[int]]   # longest prefix with a value
    longer: Optional[List[int]]    # shortest value extending beyond tokens
    common_prefix: int
```

The `longer` case is the clever one. If the cache holds a *longer* sequence that shares a prefix
with your request, the server can **rewind** it rather than recompute, ✅ VERIFIED verbatim:

```python
cache = copy.deepcopy(cache_entry.prompt_cache)
prefix = min(len(tokens) - 1, result.common_prefix)
trim_prompt_cache(cache, len(result.longer) - prefix)
return cache, tokens[prefix:]
```

Eviction is by *category*, not purely by recency. ✅ VERIFIED —
`CacheOrder(ordering=["assistant", "user", "system"])`: assistant caches are dropped before user
caches, and user before system. That ordering is exactly right for agents — the system prompt and
tool definitions are the expensive, stable prefix and should be the last thing evicted.

This is why `insert_segments` exists (§8.3). The three segments carry `segment_types`
`["system", "user", "assistant"]`, and each boundary's KV state is stored under the corresponding
`cache_type`.

### 9.2 Reading `cached_tokens`

```python
usage = response.usage
cached = usage.prompt_tokens_details.cached_tokens
print(f"{cached}/{usage.prompt_tokens} prompt tokens served from cache "
      f"({100*cached/max(usage.prompt_tokens,1):.1f}%)")
```

Interpretation for an agentic loop:

- **High and rising across turns** (say 95%+ by turn 3) — the cache is working. Each turn is
  paying for only the newly appended tool output.
- **Near zero on every turn** — something is invalidating the prefix. The usual causes are a
  changing system prompt (a timestamp in it will do it), tools being re-serialised in a different
  order, or an agent that rebuilds the message array with different whitespace.
- **Zero on a model you expected to cache** — check the architecture. Linear-attention and hybrid
  models cannot be rewound (see below).

The cross-stack version of this finding is in this series' Part 3 and Part 7: trimming a KV cache
is nearly free because attention is causal, and prefix reuse has been community-measured at large
multiples on the Core AI side. The same physics applies here.

### 9.3 ⚠️ The architectures that forfeit prefix reuse entirely

This is the same constraint that shows up in Core AI's `trimKVCache` and it is worth stating in
MLX's terms. ✅ VERIFIED from `mlx_lm/models/cache.py`'s class table:

| Cache class | `is_trimmable()` | Batchable (`merge`) |
|---|---|---|
| `KVCache` | ✅ | ✅ `BatchKVCache` |
| `ConcatenateKVCache` | ✅ | — |
| `QuantizedKVCache` | ✅ | — |
| `RotatingKVCache(max_size, keep)` | **only while `offset < max_size`** | ✅ `BatchRotatingKVCache` |
| `ChunkedKVCache(chunk_size)` | ✅ | — |
| **`ArraysCache`** (SSM / Mamba / linear attention) | ❌ | ✅ |
| `CacheList(*caches)` | `all(...)` | ✅ |

`ArraysCache` holds a *running scan state*, not positionally addressed keys and values. There is
nothing to rewind to. Hybrid models built from `CacheList` inherit the restriction from their
worst member. In practice: recurrent and hybrid architectures **re-prefill every turn**, which is
exactly the workload pattern agents are worst at affording.

Two knock-on effects, both ✅ VERIFIED:

- **`RotatingKVCache` becomes untrimmable once the window wraps** (`offset >= max_size`). So
  `--max-kv-size` buys you bounded memory at the cost of losing prefix reuse for any conversation
  long enough to actually need it.
- **`RotatingKVCache` cannot be quantized**: `NotImplementedError("RotatingKVCache Quantization
  NYI")`. Combining `--max-kv-size` with `--kv-bits` therefore fails once the rotating cache is in
  play. (These are `mlx_lm.generate` flags; the server does not expose `--kv-bits`, but the
  constraint governs any in-process serving you build yourself.)

### 9.4 Open correctness bugs in the server prompt cache

Community-reported (GitHub, read 2026-07-27), status **open**. These are not hypothetical and you
should know them before you trust `cached_tokens` on an unusual architecture.

**mlx-lm#1494 — reuse can return KV that does not match the key.** `fetch_nearest_cache` assumes
(a) a stored cache's KV corresponds exactly to its token key and (b) `is_trimmable() == True`
implies `trim(n)` removes exactly the suffix. `KVCache` satisfies both. **`ChunkedKVCache`
(llama4 chunked attention) and `ConcatenateKVCache` do not**, and nothing verifies at reuse time.
Three defects are catalogued: silently wrong output instead of falling back to recompute; the
server then checkpointing the mismatched state under the *new* key so later exact hits reuse the
bad entry; and a trim-contract problem in `trim_prompt_cache` itself. The issue ships a model-free
reproduction script.

**mlx-lm#1495 — the LRU is not an LRU, and one-token prefixes never match.** Two defects against
`main @ 2ed2231`. First, in `PromptTrie.search`:

```python
shorter = None
if last_index > 0:
    shorter = tokens[: last_index + 1]
```

`last_index` is an index where `-1` means "none", so a stored one-token key matches at
`last_index == 0` and the guard should be `>= 0`. For **non-trimmable (hybrid/recurrent) caches
the entry becomes unreachable** — a full recompute of a prefix that is sitting right there.
Second, `fetch_nearest_cache` never touches `self._lru`, and `CacheOrder` has no touch operation
at all (only `push` / `remove` / `pop`) — so **eviction is insertion-order, not
least-recently-used**, despite the class name.

**What to do about both.** Neither is fixed at the version we read. If you are on `KVCache`
models (the overwhelming majority of dense transformers) you are outside the blast radius of
#1494. For anything chunked, hybrid or recurrent, treat `cached_tokens` as advisory and validate
determinism yourself: send the same request twice with `"temperature": 0` and diff the outputs. If
they differ, the cache is lying to you; restart the server with `--prompt-cache-size 1` (which
does not disable caching but shrinks the window in which a stale entry can be reused) and re-test.

---

## 10. Why prompt processing dominates agentic work

This is the framing that should change how you benchmark.

> ✅ **VERIFIED** — 232:76–78: *"In an agentic workflow, **every time the model receives tool
> output, it has to process all that new context before it can reason about the next step. This
> happens over and over throughout the agentic loop, and it adds up fast.**"* … *"**Agentic sessions
> usually comprise hundreds of thousands of tokens and most of those are not generated.**"*

Read the second sentence twice. Hundreds of thousands of tokens, *most of them not generated*.
Every benchmark that reports "tokens per second" for a local model is reporting **decode**
throughput, and decode is the minority of the work. The number that governs how an agent feels is
prefill throughput — `prompt_tps` in mlx-lm's own reporting, and the thing
`usage.prompt_tokens_details.cached_tokens` is trying to reduce.

### 10.1 The M5 Neural Accelerators

> ✅ **VERIFIED** — 232:79–81: *"**The M5 chip introduces dedicated Neural Accelerators, and MLX
> can target them for exactly this kind of work. Specifically, Neural Accelerators make matrix
> multiplication four times faster on M5 compared to M4. And with the specialized multiplication
> and attention kernels in MLX this translates almost exactly to prompt processing speedup.**"*

> ✅ **VERIFIED** — 232:82: *"Reducing prompt processing time means **your agents can read your
> codebase or process tool results almost four times faster.**"*

> ✅ **VERIFIED** — 232:83: *"And the best part? **Taking advantage of Neural Accelerators requires
> no special arguments or code changes on your part, MLX selects the best kernel for the available
> hardware and it just works.**"*

**Attribution:** Apple-published, WWDC26 session 232, no hardware/OS/date qualifiers given beyond
"M5 compared to M4" and no benchmark methodology stated. The 4× is a *matmul* ratio; the
prompt-processing claim is "translates almost exactly", which is Apple's own hedge and you should
keep it.

The "no flags" claim is important and slightly unusual, so here is its scope precisely. It means
you do not opt in. It does **not** mean the accelerators are used for everything: the routing is
kernel-by-kernel and shape-by-shape. The corresponding Apple Tech Talk (111432, *"Accelerate your
machine learning workloads with the M5 and A19 GPUs"*) publishes the companion figure that the
session omits — the SIMD-group-matrix path shows **0% neural-accelerator utilisation** on M5, and
a 4K×4K matmul goes **2 s → 0.5 s → 0.33 s** across three kernel versions. So the accelerators
are reachable only through the newer kernel formulations, which is precisely why "MLX selects the
best kernel" is the operative clause.

⚠️ **Freshness caution.** The NAX (neural accelerator) code paths in MLX are new and moving. Three
correctness fix PRs opened in the three days before 2026-07-27, including a **missing `else` in
`tile_matmad_nax` that silently miscompiles odd tile shapes** (mlx #3912/#3922 still open, #3924
closed unmerged 2026-08-02, on a 2026-08-03 `gh` re-check). Separately,
mlx#3897 (closed 2026-08-09) reports that **batched vs single-sequence attention diverges numerically on M5**.
If you are on M5 and chasing a correctness difference, update MLX before you debug anything else,
and do not assert bit-equality between batched and unbatched paths.

🔴 **GAP — no M5 kernel-selection surface.** The M5 neural accelerator has **no API**. In MLX's
own kernels the gate is inferred from `get_architecture_gen() >= 17` (18 for the `'p'` variants).
There is no environment variable, no flag, and no runtime query that tells you whether a given
matmul used the accelerator. **Safe default:** treat it as invisible. If you need evidence that
you are on the fast path, benchmark prefill on the same model and prompt on M4 and M5 and compare
`prompt_tps` — that is the only handle anyone has.

### 10.2 What to measure instead of tokens/sec

For an agent workload, the four numbers that matter:

1. **`usage.prompt_tokens` per turn** — is the context growing linearly or quadratically? Agents
   that re-serialise the whole transcript every turn grow quadratically in total prefill work.
2. **`cached_tokens / prompt_tokens`** — the prefix-reuse rate (§9.2).
3. **TTFT at your real concurrency** — not at concurrency 1. Use §12's harness.
4. **`usage.completion_tokens` split by whether reasoning is on** — §7.2.

`mlx_lm.benchmark` reports `prompt_tps` and `generation_tps` separately and lets you set the
prompt length directly, which makes it the right tool for isolating the prefill side:

```bash
# 8k-token prompt, short generation: this is an agentic-shaped measurement
mlx_lm.benchmark --model mlx-community/Qwen3-8B-4bit \
                 --prompt-tokens 8192 --generation-tokens 64 \
                 --batch-size 8 --num-trials 5
```

✅ VERIFIED behaviour worth knowing: `mlx_lm.benchmark` generates **random token IDs** as the
prompt and blanks the EOS set (`tokenizer._eos_token_ids = {}`) so generation never stops early.
Do not reuse that tokenizer object for real generation afterwards.

---

## 11. Pointing agents at it

> ✅ **VERIFIED** — 232:64–66, step three: *"point your agent at the local server. **In most agent
> frameworks, you just set the base URL to your local server's address and you're done. The agent
> doesn't know or care that the model is running on your Mac rather than in the cloud.**"*

Five clients follow, in increasing order of how much this series cares about them.

### 11.1 `curl`

The smoke test. If this does not work, nothing above it will.

```bash
# health
curl -s localhost:8080/health
# {"status": "ok"}

# what's loadable
curl -s localhost:8080/v1/models -H "Content-Type: application/json" | python3 -m json.tool

# a completion
curl -s localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
     "messages": [{"role": "user", "content": "Say this is a test!"}],
     "temperature": 0.7
   }' | python3 -m json.tool
```

The first two commands are ✅ VERIFIED verbatim from `mlx_lm/SERVER.md`.

### 11.2 OpenCode

This is the agent Apple demoed. Session 232 describes the configuration but the JSON was on screen
and never read aloud.

> ✅ **VERIFIED** — 232:67–73, verbatim: *"Here's the configuration for OpenCode. **We define a
> local provider. In particular, we set the URL to local host and set the model name the server
> expects. We also tell OpenCode to use this local model for everything.** That's it. Now every
> interaction runs through your local model."*

Three requirements, each stated: **a local provider**, **the URL set to localhost**, **the model
name the server expects**, and **a directive to use it for everything**.

🟡 **RECONSTRUCTED — the config file's exact shape.** The structure below is the standard OpenCode
`opencode.json` provider shape and satisfies all four stated requirements, but it was **not** read
off Apple's slide. Treat the *shape* as right and the *key names* as provisional; check them
against OpenCode's own documentation, which is the authority here, not this guide.

```jsonc
// opencode.json
{
  "provider": {
    "mlx": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "MLX (local)",
      "options": { "baseURL": "http://localhost:8080/v1" },
      "models": {
        "mlx-community/Qwen3-8B-4bit": { "name": "Qwen3 8B (4-bit, local)" }
      }
    }
  },
  "model": "mlx/mlx-community/Qwen3-8B-4bit"
}
```

Two things that are *not* reconstructed, because they follow from §4:

- The model id you put in `models` must be **what the server expects** — either the exact
  Hugging Face repo id, or the magic string `"default_model"` to mean "whatever `--model` was".
  Session 232's phrasing, "the model name the server expects", is doing real work.
- The base URL should include `/v1`. `/chat/completions` without the prefix is also routed
  (§3), but `/v1` is the path everything else agrees on.

Apple's demo of what this buys you:

> ✅ **VERIFIED** — 232:21–26: *"on the left, **MLX running the model**, and on the right the
> **OpenCode agent** I am interacting with. I asked it to **fetch the recent pull requests from our
> MLX repository, summarize the changes, and identify anything that needs my attention.** The model
> reasons about the request, **calls the GitHub CLI** to fetch PR data, reads through the diffs, and
> produces a concise summary. **All of this is happening locally, the model runs on my hardware and
> only the git commands reach the network.**"*

### 11.3 Xcode 27 — the one most readers will use

Xcode 27 can be pointed at your local MLX server directly. This is not a plugin or an extension;
it is a first-class provider type in Settings.

> ✅ **VERIFIED** — WWDC26 session 232, transcript lines 134–141, verbatim: *"Let's connect Xcode
> to our already running MLX server. **We open the settings and navigate to the Intelligence tab.
> We click on Add Chat Provider... and select a Locally Hosted provider. We set the Port to 8080 or
> whichever port we selected when launching our MLX server and we're done. Now Xcode can talk to
> our local model.**"*

**The click path:**

```
Xcode 27  ▸  Settings…  ▸  Intelligence  ▸  Add Chat Provider…  ▸  Locally Hosted  ▸  Port: 8080
```

And the corresponding server, on the same machine:

```bash
mlx_lm.server --model mlx-community/Qwen3-8B-4bit --port 8080
```

Note what the UI asks for: **a port**, not a URL. The "Locally Hosted" provider type is
loopback-scoped by construction, which lines up with `mlx_lm.server`'s `--host` default of
`127.0.0.1`. If you have moved the server to another machine you will need to bridge it back to
localhost yourself (an SSH tunnel is the obvious move) rather than typing a remote address:

```bash
# server on the Studio, Xcode on the laptop
ssh -N -L 8080:127.0.0.1:8080 mac-studio.local
```

⚠️ If you do move the server off loopback with `--host 0.0.0.0`, re-read §2.1: there is no
authentication of any kind. On a shared network that is an open model endpoint and, because
`"model"` is a request field, an open *model loader*. Prefer the tunnel.

What Apple demonstrates with it:

> ✅ **VERIFIED** — 232:142–146: *"I have introduced a bug to our previously working app and now we
> can ask the model to fix it. **Within seconds, it identifies the bug and inspects the code around
> it. Finally, it writes a fix and we can now build and run our app.**"* … *"This shows how **a
> locally running agent can integrate with your existing development workflow in Xcode, reading
> project files, understanding build errors, and making targeted fixes. Local AI means your code
> never leaves your Mac.**"*

🔴 **GAP — the rest of the Locally Hosted provider sheet.** The session shows only the port field
being set. Whether the sheet also takes a model name, a display name, an API key, or a path
prefix; whether Xcode probes `/v1/models` to populate a picker; and what it does when the server
returns the 404-for-everything error shape from §4.1 — none of that is stated anywhere in our
corpus, and Xcode 27 was not available to us to check. **What would resolve it:** one screenshot
of the sheet, or `defaults read com.apple.dt.Xcode` after adding a provider. **Safe default:**
launch the server with an explicit `--model` so that requests omitting a model still work, and
watch the server's stdout while you add the provider — every request Xcode makes will be logged
at `INFO`.

### 11.4 The OpenAI Python SDK

Anything written against OpenAI's client works unchanged apart from the base URL.

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8080/v1", api_key="not-needed")

stream = client.chat.completions.create(
    model="mlx-community/Qwen3-8B-4bit",
    messages=[{"role": "user", "content": "Explain MoE routing in three sentences."}],
    temperature=0.7,
    max_tokens=256,
    stream=True,
    stream_options={"include_usage": True},
)

for chunk in stream:
    if not chunk.choices:
        continue                                  # the usage-only final chunk
    delta = chunk.choices[0].delta
    if (reasoning := getattr(delta, "reasoning", None)):
        print(f"\033[2m{reasoning}\033[0m", end="", flush=True)   # dimmed thinking
    if delta.content:
        print(delta.content, end="", flush=True)
```

The `getattr(delta, "reasoning", None)` rather than `delta.reasoning` is deliberate: the field is
mlx-lm-specific (§5), and typed SDK models may not expose it as an attribute on every version.

### 11.5 Foundation Models: `ChatCompletionsLanguageModel` — the cross-stack move

This is the payoff for Swift readers of this series and it deserves to be stated plainly:

**`mlx_lm.server` + `ChatCompletionsLanguageModel` puts any Hugging Face checkpoint behind
`LanguageModelSession` today.**

In the 2026 stack `LanguageModelSession` no longer implies Apple's on-device model. It sits on a
public `LanguageModel` / `LanguageModelExecutor` protocol pair with five conformers, one of which
speaks OpenAI chat-completions. Point that conformer at `localhost:8080` and every
`LanguageModelSession` API — instructions, transcript, streaming, tools — is running against a
model you chose, quantized how you chose, on your machine.

✅ **VERIFIED initializer**, from a developer's working code on Apple Developer Forums thread
838444 (the response was accepted by an Apple engineer in the same thread):

```swift prelude:guide-context
ChatCompletionsLanguageModel(name: String, url: URL, additionalHeaders: [String: String])
```

used as `LanguageModelSession(model: model)`.

🟡 **RECONSTRUCTED wiring** — the shape below follows from that initializer and from
`LanguageModelSession`'s documented form; the exact argument values for a local server were not
read from a compiling sample:

```swift illustrative
import FoundationModels
import FoundationModelsUtilities   // ChatCompletionsLanguageModel lives here

let local = ChatCompletionsLanguageModel(
    name: "mlx-community/Qwen3-8B-4bit",          // the `model` field in the request body
    url: URL(string: "http://127.0.0.1:8080/v1")!,
    additionalHeaders: [:]                         // mlx-lm ignores Authorization
)

let session = LanguageModelSession(model: local) {
    "You are a terse Swift code reviewer."
}
let response = try await session.respond(to: "Review this function for retain cycles: …")
```

### ⚠️ The `/v1` path bug you will hit within five minutes

✅ **VERIFIED** — the offending private method, quoted verbatim in forum thread 838444 from
`apple/foundation-models-utilities`,
`Sources/FoundationModelsUtilities/LanguageModels/ChatCompletionsLanguageModel.swift:634`:

```swift illustrative
private func buildURLRequest(for request: ChatCompletionRequest) throws -> URLRequest {
    let isVersioned = baseURL.pathComponents.contains("v1")
    let endpoint = isVersioned ? "/chat/completions" : "/v1/chat/completions"
    let url = baseURL.appendingPathComponent(endpoint)
    ...
}
```

The check is a literal string comparison against `"v1"`. Providers on any other version segment
get `/v1/chat/completions` appended *after* their own path, producing URLs like
`/api/v3/responses/v1/chat/completions`. The reporter's observed error, verbatim:

```
HTTP error with status code 404:
{"error":{"code":"InvalidAction","message":"The specified action is invalid: /api/v3/responses/v1/chat/completions …"}}
```

Apple's response in the thread was *"Fantastic suggestion, thanks! We're on it."* on the proposed
fix (a regex over `v\d+`), filed as **FB23837262**. Status as of 2026-07-27: acknowledged, not
known-shipped.

**Why you care even though mlx-lm is on `/v1`:** you care because of the *interaction with §4.1*.
If you give `ChatCompletionsLanguageModel` a base URL of `http://127.0.0.1:8080` (no `/v1`), it
appends `/v1/chat/completions` and everything works. If you give it `http://127.0.0.1:8080/v1`, it
appends `/chat/completions`, producing `/v1/chat/completions` — also correct. Both spellings work
against mlx-lm, which is lucky rather than designed. But when the request then fails for an
unrelated reason — model not loaded, out of memory — mlx-lm answers **404**, which looks exactly
like the path bug. You will spend an hour on the URL when the problem is the model.

**Rule:** when a `ChatCompletionsLanguageModel` request against mlx-lm returns 404, `curl` the
same body first (§4.1). If `curl` succeeds, it is the URL. If `curl` returns 404 with an `error`
key, it is the model, and the URL is fine.

Full treatment of `ChatCompletionsLanguageModel` — transcript mapping, tool bridging, streaming
semantics, and what it costs you — is
[Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md).

⚠️ **The constraint that goes with it, from Part 4:** grammar-constrained decoding needs engine
**logits**. An HTTP endpoint does not expose logits. So `@Generable` guided generation — Apple's
flagship structured-output feature — is **not available** on this path. You get tool calling and
free text; you do not get schema-guaranteed JSON from the framework. Plan for `tools` plus your
own validation, or use the server's own tool-calling machinery (§6) and parse the arguments
yourself.

### 11.6 The tools Apple names as already running on this

Ollama, LM Studio and vLLM (§1.2). All three speak OpenAI chat-completions, so the material in
§§4–8 transfers. Two practical notes:

- **Port collisions.** mlx-lm defaults to **8080**; Ollama's conventional port is 11434 and LM
  Studio's is 1234. Running more than one is fine and often useful — but §8.5's advice applies at
  the machine level too: two model servers on one Mac contend for the same unified memory and the
  same GPU. `mx.set_wired_limit` is called by mlx-lm at startup with the machine's maximum
  recommended working set, so a second large process will find memory already spoken for.
- **Model identity.** The `model` string in an OpenAI request means different things to each
  server (an Ollama tag, an LM Studio identifier, an HF repo id for mlx-lm). An agent config that
  works against one will not transfer verbatim.

---

## 12. Load testing and capacity planning

The repository ships a load generator, which is the correct way to answer "how many subagents can
this Mac serve".

✅ VERIFIED — `benchmarks/server_benchmark.py` (349 lines):

```bash
# terminal 1
mlx_lm.server --model mlx-community/Qwen3-8B-4bit

# terminal 2
python benchmarks/server_benchmark.py --concurrency 4
```

| Flag | Default |
|---|---|
| `--url` | `http://localhost:8080/v1/chat/completions` |
| `--api-key` | — |
| `--model` | `default_model` |
| `--max-tokens` | 100 |
| `--concurrency` | 1 |
| `--total-requests` | 10 |
| `--prompt-file` | — |
| `--output` | — |

It reports **TTFT min/max/avg/p95**, per-request tokens/sec, aggregate tokens/sec, and an ASCII
bar plot of tokens/sec over time. It requires **`aiohttp`**, which — like `rich` and `regex` — is
not a declared dependency (`pip install aiohttp`).

**How to use it well.** The default 100-token prompt tells you nothing about agent behaviour. Use
`--prompt-file` with a realistic agent context — a system prompt plus tool definitions plus a few
turns of tool output, in the tens of thousands of tokens — and sweep `--concurrency` over
1, 2, 4, 8, 16. What you are looking for is the concurrency at which **p95 TTFT** stops being flat.
That is your subagent budget. Aggregate tokens/sec will keep climbing past it; TTFT is what your
agent framework's timeouts see.

Then re-run the same sweep with one change at a time: `--prompt-concurrency`, then
`--prefill-step-size`, then `--prompt-cache-size`. One knob per run — §13 has three separate open
defects that produce latency anomalies, and you want to be able to tell a tuning effect from a bug.

**Record the `system_fingerprint`** from any response in the run (§3). It pins mlx-lm version, mlx
version, OS build and GPU generation, which is exactly the attribution this series asks for.

---

## 13. Operational reality: the open server defects

Community-reported on GitHub, all read 2026-07-27, all **open** at that date. None of these is a
reason not to use `mlx_lm.server`; all of them are reasons to supervise it.

### 13.1 mlx-lm#1493 — livelock, not deadlock

The server hangs immediately after prompt processing on ~22–26k-token **streaming** requests from
a real client (Obsidian Copilot: `stream:true, temperature:0.1, max_tokens:16000`, a system prompt
plus long mixed-language markdown). Synthetic prompts of the same size pass. Concurrency alone
passes. Streaming alone passes. The trigger appears to need **prompt-cache priming (two small
completions first) plus a >22k real prompt**.

Reporter's environment: `mlx-community/gemma-4-26b-a4b-it-8bit`, **M5 Max 128 GB**, mlx-lm 0.31.3,
`--decode-concurrency 32 --prompt-concurrency 8`. Community-measured; single reporter.

The diagnosis is the part worth internalising. `py-spy` plus `sample` over six minutes showed the
loop **alternating between the forward call and the eval sync**, with live compute-encoding frames
and real CPU time — *the batch keeps stepping and delivers zero chunks*. Fresh trivial completions
hung for more than 180 seconds parked in `response_queue.get()` with no timeout. `GET /v1/models`
returned 200 throughout. Only `launchctl kickstart` recovered it.

> Verbatim from the thread: *"This failure mode defeats both detection strategies discussed so
> far: `_generation_thread.is_alive()` — true the whole time; a naive per-iteration heartbeat —
> **would also tick**, because iterations are happening. The liveness signal has to be defined at
> the delivery level: *requests in flight + no tokens delivered to any consumer queue for N
> seconds* = stalled engine."*

Fix in flight: PR **#1598**, a delivery-staleness watchdog with `--generation-stall-timeout`
(proposed default 60 s), stacked on **#1513** (exception / dead-worker recovery).

**What to do today.** Do not health-check with `/health` or `/v1/models` — both stay green
(§3.1). Health-check by *sending a tiny completion with a client-side timeout* and restarting the
process if it does not return. A launchd `KeepAlive` plus an external prober is a five-line
solution and it is the difference between a two-second blip and an agent session that hangs
overnight.

### 13.2 mlx-lm#1500 — an idle server pins a core

`ResponseGenerator._generate()`'s worker thread busy-polls:

```python
def get_next_request():
    if unprocessed_requests:
        return unprocessed_requests.pop()
    else:
        try:
            return self.requests.get_nowait()   # returns immediately when empty
        except QueueEmpty:
            return None
```

`sample` / `py-spy` show the thread parked in `_PyEval_EvalFrameDefault`. It happens **even with
no `--model`** — a server that has never loaded anything burns a core. The proposed fix blocks
with `self.requests.get(timeout=1.0)` when no batch is in flight.

Practical impact: on a laptop this is a fan and a battery, not a correctness problem. On a
machine also running Xcode builds it is one fewer performance core. **Mitigation today:** stop the
server when you are not using it, or accept it. There is no flag.

### 13.3 The wedge family

- **mlx-lm#1505** — *"any uncaught exception in `_generate` leaves HTTP threads serving while every
  completion hangs forever."* Same external symptom as #1493, different cause.
- **mlx-lm#1472 (closed 2026-09-04; fix merged but unreleased)** — the generation thread dies with
  `TypeError ('NoneType' object is not iterable)` when a batch **mixes requests with and without
  logits processors**; the server then hangs forever. [PR #1826](https://github.com/ml-explore/mlx-lm/pull/1826)
  makes the invalid per-sequence state unrepresentable and adds a mixed-batch regression test.
  Affected releases still need the guard or a watchdog. This one is directly agent-relevant: a
  fan-out where some subagents set `repetition_penalty` and others do not is exactly that mix.
- **mlx-lm#1435** — a uniform **+55–77 ms TTFT regression** on 0.31.3 vs 0.27.1 on M3 Ultra, with
  decode flat (±1.5%) and the penalty **independent of model size** (Qwen3-0.6B and gpt-oss-20b
  both pay it) → constant per-call setup cost. Hypothesised cause: the `wired_limit` context
  manager and `mx.new_thread_local_stream(...)` now being entered on **every** generation call.
  Community-measured, single reporter, hypothesis not confirmed by a maintainer.
- **mlx-lm#1425** — Qwen3.5-35B-A3B-8bit decode −7.4% / −7.9% on 0.31.3 vs 0.31.0 (M3 Ultra
  256 GB). Sweeps of prefill step and completion batch did not recover it. Note that **0.31.0 was
  yanked in practice** for BatchKV cache cross-contamination, so it is not a version to go back to.

All five together add up to one operational rule: **run `mlx_lm.server` under a supervisor with an
external liveness prober, and pin your mlx-lm version.** The velocity on this repository is high
and, per mlx-lm#1475 (open), maintainer bandwidth has been uneven — commit velocity was ~50/month
through February 2026, dropped to 1 in May and ~13 in June, with 30+ open PRs at the time of
filing. Merges resumed in July. Plan for a pinned version and deliberate upgrades, not `latest`.

---

# Part B — serving many machines

Everything above assumed one Mac. This half is about what to do when one Mac is not enough — and
about the fact that, as of the 26.2 release, "not enough" has a much better answer than it used to.

Session 232 states the motivation before handing off:

> ✅ **VERIFIED** — 232:94–101: *"Sometimes a single machine, **even one with 512GB of RAM**, just
> isn't enough because the model is too large to fit in memory. **The most recent DeepSeek model for
> instance has a whopping 1.6 trillion parameters and requires more than 800GB of memory just for
> the weights.**"* … *"**MLX's distributed support lets you spread a model across multiple Macs
> connected over Thunderbolt or Ethernet.** For agents, this is powerful in two ways. **First, it
> lets you run much larger, more capable models that wouldn't fit on a single machine. Second, it
> parallelizes prompt processing across devices, which directly speeds up the agentic loop since the
> model can process tool results faster.**"*

Note the second reason. It is the same argument as §10: agents are prefill-dominated, and tensor
parallelism parallelises prefill.

---

## 14. The four-layer distributed stack

Session 233, *"Explore distributed inference and training with MLX"*, presents four layers. They
are worth learning as layers because each one has its own version gate, its own failure mode, and
its own diagnostic.

**Layer 1 — the interconnect.** Physical cable.

> ✅ **VERIFIED** — 233: *"machines need to be connected with a **physical link — an
> interconnect**."* Here: **Thunderbolt 5** cables.

**Layer 2 — the transport: RDMA over Thunderbolt 5.**

> ✅ **VERIFIED** — 233, verbatim: *"**Starting in macOS 26.2**, Remote Direct Memory Access
> protocol, shortly **RDMA**, is supported over **Thunderbolt 5**. **RDMA moves data directly from
> one machine's memory to another's, avoiding most CPU and operating system overhead.**"*

⚠️ **macOS 26.2 is a hard version gate**, and it is the only OS version number in the entire
session. Corroborated independently by the MLX documentation site: *"Starting from **macOS 26.2**,
RDMA over thunderbolt is available and enables low-latency communication between Macs with
**thunderbolt 5**."*

**Layer 3 — the collective communication backend: JACCL.**

> ✅ **VERIFIED** — 233, verbatim: *"**JACCL is an open-source collective communication library
> built by Apple.** It leverages RDMA over Thunderbolt and gives you **collective communication
> primitives for sending data between machines and combining results across the group** — without
> managing any of the low-level transport yourself. **And it's not limited to machine learning —
> any distributed workload on Apple Silicon can be built on top of it.**"*

The layering rationale, also verbatim: RDMA *"alone… gives us **raw data movement between two
machines only**. Thus, distributed programs need something higher-level."*

The MLX docs supply both the performance claim and, delightfully, the etymology:

> ✅ **VERIFIED** — MLX documentation site: *"MLX provides the JACCL backend that uses this
> functionality to achieve communication latency **an order of magnitude lower than the ring
> backend**."* … *"The name JACCL (pronounced Jackal) stands for **Jack and Angelos' Collective
> Communication Library** and it is an obvious pun to Nvidia's NCCL but also tribute to **Jack
> Beasley** who led the development of RDMA over Thunderbolt at Apple."*

**Layer 4 — the ML framework: MLX**, which *"leverages JACCL for low-latency distributed
communication and provides tools for orchestrating distributed jobs across the cluster."*

### 14.1 The four backends, and when each applies

✅ VERIFIED — the backend table, verbatim from the MLX documentation site:

| Backend | Apple's description |
|---|---|
| **MPI** | "A full featured and mature distributed communications library." |
| **RING** | "Ring all reduce and all gather over TCP sockets. Always available and usually faster than MPI." |
| **JACCL** | "Low latency communication with RDMA over thunderbolt. **Necessary for things like tensor parallelism.**" |
| **NCCL** | "The backend of choice for CUDA environments." |

The four-word clause in the JACCL row — *"Necessary for things like tensor parallelism"* — is the
decision rule. Tensor parallelism communicates **at every layer, for every token**. Ring-over-TCP
latency makes that a losing trade; RDMA latency makes it a winning one. If you want tensor
parallelism, you want JACCL, and therefore you want macOS 26.2, Thunderbolt 5, and a full mesh.

Selection strings for `mx.distributed.init(backend=…)` are
`{'any', 'ring', 'jaccl', 'mpi', 'nccl'}`. ⚠️ VERIFIED subtlety, verbatim from the docs:
*"After a distributed backend is successfully initialized `init()` will return **the same backend**
if called without arguments or with backend set to `any`."* So the first successful `init` in your
process wins forever:

```python
world_mpi  = mx.distributed.init(backend="mpi")
world_ring = mx.distributed.init(backend="ring")
world_any  = mx.distributed.init()   # same as MPI because it was initialized first!
```

### 14.2 The one property that removes all your `if` statements

✅ VERIFIED, verbatim from the MLX docs: *"**all operations in `mx.distributed` are noops when the
distributed group has a size of one.** This property allows us to avoid code that checks if we are
in a distributed setting."*

```python
import mlx.core as mx

world = mx.distributed.init()
x = mx.distributed.all_sum(mx.ones(10))     # correct on 1 node and on 8
print(world.rank(), x)
```

Write your program once. Run it with `python` and it is a single-process program. Run it with
`mlx.launch -n 4` and it is a four-process one. This is why the distributed entry points in mlx-lm
(`mlx_lm.chat`, `mlx_lm.server`, `mlx_lm.lora`, `mlx_lm.evaluate`) do not have separate
single-machine and multi-machine code paths.

The full primitive set, ✅ VERIFIED from the docs:

```python
mx.distributed.init(strict: bool = False, backend: str = 'any') -> Group
mx.distributed.is_available(backend: str = 'any') -> bool
Group.rank() -> int ; Group.size() -> int ; Group.split(color: int, key: int = -1) -> Group

mx.distributed.all_sum(x, *, group=None, stream=None)
mx.distributed.all_max(x, *, group=None, stream=None)
mx.distributed.all_min(x, *, group=None, stream=None)
mx.distributed.all_gather(x, *, group=None, stream=None)
mx.distributed.sum_scatter(x, *, group=None, stream=None)
mx.distributed.send(x, dst: int, *, group=None, stream=None)
mx.distributed.recv(shape, dtype, src: int, *, group=None, stream=None)
mx.distributed.recv_like(x, src: int, *, group=None, stream=None)
```

⚠️ Ring-backend restriction, verbatim: *"`send()` and `recv()` with arbitrary sender and receiver
are **not supported** in the ring backend"* — a ring node can only talk to its two neighbours.

---

## 15. Topology: mesh is strictly better than ring

Session 233 gives the cost model before the recommendation, which is the right order because the
recommendation follows from it.

> ✅ **VERIFIED** — 233, verbatim: *"communication time has two components: **latency and transfer
> time**. **Latency is the fixed cost paid for each communication operation, independent of the
> amount of data.** **Transfer time** … grows with message size and depends on the **bandwidth** of
> the link. **For small messages… latency dominates. For large messages, the trade off is
> opposite.**"*

| Topology | Property | Verbatim |
|---|---|---|
| **Mesh** | lowest latency | *"every machine connects directly to every other, thus **any group communication has the lowest possible latency**"* |
| **Ring** | fewer cables, higher per-link bandwidth | *"each node connects only to its two neighbors. Communication between nonadjacent nodes must **travel through intermediate machines which increases latency**. However, the ring requires **fewer cables and ports per machine, making it easier to scale to more nodes**."* |

The ring has one real advantage, and it is a bandwidth trick:

> ✅ **VERIFIED** — 233: *"because each node has only two connections, **we can use the extra
> Thunderbolt ports to run two or three cables per neighbor (depending on the Mac)** — thus
> **increasing the bandwidth per link and reducing transfer time**."*

That trick has a representation in the hostfile, which is a detail nobody states out loud but which
falls straight out of the type. ✅ VERIFIED from `python/mlx/_distributed_utils/common.py`:

```python
@dataclass
class Host:
    rank: int
    ssh_hostname: str
    ips: list[str]
    rdma: list[Optional[Union[str, list[str]]]]
```

`rdma` is a list whose entries may be `None`, **a string, or a list of strings** — the list form is
how you declare multiple cables to the same peer.

### 15.1 The operational finding: cable a mesh, let JACCL choose

> ✅ **VERIFIED** — 233, verbatim: *"When machines are connected into a mesh, we have the
> **flexibility to route each communication through either a mesh topology or a ring topology**.
> What's nice about JACCL, **it automatically picks the best topology depending on the message size
> and communication operation — mesh when latency matters, ring when bandwidth matters.**"*

That is the whole argument. A mesh is a superset: JACCL can route ring-style traffic over mesh
cabling when bandwidth is what matters, but ring cabling cannot synthesise a mesh's single-hop
latency. The presenter states their own choice as a recommendation: *"**For this flexibility, let's
connect all M3 Ultras into a mesh.**"*

Tensor parallelism reinforces it: *"This makes **low latency important, and that is why the mesh
topology is crucial for this case** — every machine can reach every other machine in a single
hop."*

**So: cable a mesh if your port count allows. Use ring cabling only for node counts a mesh cannot
reach.** The full-mesh requirement is not advisory, it is enforced — ✅ VERIFIED from the MLX docs:
*"The JACCL backend supports **only fully connected topologies**. Namely, there needs to be a
thunderbolt cable connecting **all pairs** of Macs directly."* And `mlx.launch` validates it
(§19.2).

Rough cable arithmetic, since it decides your hardware plan: a full mesh of *N* machines needs
*N(N−1)/2* cables and *N−1* Thunderbolt ports per machine. Two machines: 1 cable, 1 port each.
Three: 3 cables, 2 ports each. Four: 6 cables, 3 ports each. Five: 10 cables, 4 ports each. Port
count is what runs out first, which is exactly why the ring exists.

---

## 16. Turning RDMA on — the setup sequence

⚠️ **This is the one place where our two best sources give different procedures.** Both are quoted
below. Read both before you touch a machine.

### 16.1 Procedure A — the MLX documentation (macOS Recovery)

> ✅ **VERIFIED** — MLX documentation site, verbatim: *"Until the feature matures, enabling RDMA
> over thunderbolt is slightly more involved and **cannot be done remotely even with sudo**. In
> fact, it has to be done in **macOS recovery**:*
> - *Start your computer in recovery.*
> - *Open the Terminal by going to Utilities -> Terminal.*
> - *Run `rdma_ctl enable`.*
> - *Reboot."*

### 16.2 Procedure B — WWDC26 session 233 (System Settings)

> ✅ **VERIFIED** — 233, verbatim: *"Open **settings** on the machine, search for **"RDMA"**, click
> on **"Enable RDMA over Thunderbolt"**, **enable RDMA, and reboot**."*

### 16.3 Which one to follow

These are not the same procedure. One is a Recovery-mode CLI, the other a System Settings toggle.
Three readings are possible: the Settings toggle is newer and the docs are stale; the docs describe
a first-time enablement that the toggle then manages; or they are two paths to the same
`rdma_ctl` call.

**Precedence in this series puts repository sources above WWDC narration**, and the MLX docs are
unusually emphatic (*"cannot be done remotely even with sudo"*), which is a claim you would not
make casually. But the session is newer, and a Settings toggle appearing between the docs being
written and 26.2 shipping is entirely plausible.

🔴 **GAP — which procedure is current on macOS 26.2 and later.** Unresolved. **What would resolve
it:** one person on macOS 26.2 running `defaults`-free reconnaissance — search System Settings for
"RDMA" and report whether the toggle exists — or checking whether `rdma_ctl` is present and
functional outside Recovery.

**Safe default, and the order to try it in:**

1. **Look in System Settings first.** Search "RDMA". If *"Enable RDMA over Thunderbolt"* is there,
   toggle it and reboot. It is non-destructive and takes thirty seconds.
2. **If it is not there, use Recovery.** Boot to Recovery, Utilities ▸ Terminal, `rdma_ctl enable`,
   reboot.
3. **Verify either way with `ibv_devices`.** This is the authoritative check, and it also gives you
   the device names you need for the hostfile.

Both procedures agree on the one thing that is easiest to forget: **you must reboot**, and you must
do this on **every** node.

### 16.4 Verifying, and harvesting the device names

✅ VERIFIED — MLX documentation, verbatim output *"for an M3 Ultra"*:

```
~ % ibv_devices
    device                 node GUID
    ------              ----------------
    rdma_en2            8096a9d9edbaac05
    rdma_en3            8196a9d9edbaac05
    rdma_en5            8396a9d9edbaac05
    rdma_en4            8296a9d9edbaac05
    rdma_en6            8496a9d9edbaac05
    rdma_en7            8596a9d9edbaac05
```

If `ibv_devices` prints nothing, RDMA is not enabled and no amount of hostfile editing will help.
The device names are `rdma_en<N>` and they map onto Thunderbolt interfaces. Six devices on an M3
Ultra is what makes a four-way mesh (three peers) comfortable and a five-way (four peers) still
possible.

Run it on every node and keep the output — §17 is about turning it into an adjacency matrix.

### 16.5 The full setup sequence, start to finish

Consolidated from all three sources. Do these in order.

```text
 1. Confirm hardware: Thunderbolt 5 on every Mac, and enough ports for a full mesh
    (N-1 ports per machine for N machines).
 2. Update every node to macOS 26.2 or later.                                   [hard gate]
 3. Cable a full mesh: one Thunderbolt cable between every pair.
 4. Enable RDMA on EVERY node and reboot each one.                              [§16.1 / §16.2]
 5. Verify on every node: `ibv_devices` lists rdma_enN entries.
 6. Set up password-less SSH from the launcher to every node, using the exact
    hostnames you will put in the hostfile.
 7. Install MLX and mlx-lm on EVERY node, at the SAME versions, at a path that
    exists identically everywhere. `mlx.launch --print-python` prints the path
    it will use.
 8. Generate the hostfile:  mlx.distributed_config … --backend jaccl            [§18]
      - run WITHOUT --auto-setup first and read the commands it prints
      - it will disable the Thunderbolt Bridge; know that before it happens
 9. Sanity-check the cluster with a trivial all_sum before you load a model.    [§19.4]
10. Launch the real workload with mlx.launch --hostfile … --env MLX_METAL_FAST_SYNCH=1
```

Step 7 is the one that catches people. Step 8's destructiveness is the one that catches people
*badly*.

---

## 17. The hostfile

The hostfile is the single artefact that describes your cluster. Get it right and everything else
is one command. Get the `rdma` array wrong and you get a `ValueError` — which is, mercifully, one
of the few loud failures in this stack.

### 17.1 What it contains

> ✅ **VERIFIED** — 233, verbatim: *"It is a **JSON array — one entry per node**. **`"ssh"`** is the
> hostname used by `mlx.launch` to reach the machine. **`"ips"`** is the machine's IP on your
> **local network** used by **JACCL for initial coordination** between nodes. And **`"rdma"`** is a
> list of the **RDMA device names for each Thunderbolt peer connection**."*

The MLX documentation states the same three requirements slightly differently, and the difference
matters:

> ✅ **VERIFIED** — MLX docs, verbatim: *"The hostfile needs to contain*
> - *Hostnames to use for launching scripts via ssh*
> - ***An IP for rank 0 that is reachable by all nodes***
> - *A list of rdma devices that connect each node to each other node"*

**"An IP for rank 0"** — not an IP for every node. The code enforces exactly this. ✅ VERIFIED from
`python/mlx/_distributed_utils/launch.py`, `launch_jaccl`:

```python
if not hosts[0].ips:
    raise ValueError("Rank 0 should have an IP reachable from all other ranks")
```

which is why Apple's documentation example has `"ips": ["123.123.123.1"]` on the first node and
`"ips": []` on the other three. The session's example fills all four in, which is also fine and
arguably clearer.

### 17.2 A real two-node hostfile

The minimum viable cluster. Two machines, one cable, one port each.

```json
[
  {
    "ssh": "m3-ultra-0",
    "ips": ["192.168.1.10"],
    "rdma": [null, "rdma_en5"]
  },
  {
    "ssh": "m3-ultra-1",
    "ips": [],
    "rdma": ["rdma_en5", null]
  }
]
```

Read it as a matrix. Row *i* is node *i*. Entry `rdma[j]` in row *i* is **the device on node *i*
that faces node *j***. The diagonal is `null` because a node has no cable to itself.

Note that both entries here happen to be `rdma_en5`, which is common but not required — the device
name is whatever that machine's Thunderbolt port enumerated as, and the two ends of one cable can
easily be `rdma_en3` on one machine and `rdma_en5` on the other.

### 17.3 A real four-node hostfile

✅ **VERIFIED — Apple code sample, session 233 @ 8:31, verbatim:**

```json
[
  {
    "ssh": "m3-ultra-0",
    "ips": ["192.168.1.10"],
    "rdma": [null, "rdma_en5", "rdma_en4", "rdma_en3"]
  },
  {
    "ssh": "m3-ultra-1",
    "ips": ["192.168.1.11"],
    "rdma": ["rdma_en5", null, "rdma_en4", "rdma_en3"]
  },
  {
    "ssh": "m3-ultra-2",
    "ips": ["192.168.1.12"],
    "rdma": ["rdma_en5", "rdma_en4", null, "rdma_en3"]
  },
  {
    "ssh": "m3-ultra-3",
    "ips": ["192.168.1.13"],
    "rdma": ["rdma_en5", "rdma_en4", "rdma_en3", null]
  }
]
```

The MLX documentation ships a structurally identical four-node example with different device
assignments and `"ips": []` on nodes 1–3 — proof that the device names are per-machine facts, not
a convention:

```json
[
    {"ssh": "m3-ultra-1", "ips": ["123.123.123.1"], "rdma": [null, "rdma_en5", "rdma_en4", "rdma_en3"]},
    {"ssh": "m3-ultra-2", "ips": [],                "rdma": ["rdma_en5", null, "rdma_en3", "rdma_en4"]},
    {"ssh": "m3-ultra-3", "ips": [],                "rdma": ["rdma_en4", "rdma_en3", null, "rdma_en5"]},
    {"ssh": "m3-ultra-4", "ips": [],                "rdma": ["rdma_en3", "rdma_en4", "rdma_en5", null]}
]
```

### 17.4 The structural rules, and the error you get for breaking them

These are worth stating as rules because the example makes them implicit.

1. **`ssh` is a scalar string; `ips` is an array.** A machine can have several NICs.
2. **`rdma` is positional and self-indexed.** For node *i*, `rdma[j]` is the device on node *i*
   facing node *j*.
3. **`rdma[i]` must be `null`** for host *i* — the diagonal.
4. **Every node's `rdma` array must have length exactly equal to the cluster size.** Not the number
   of peers. The number of nodes, including itself.
5. **`ips` on rank 0 must be non-empty.**
6. **An entry may itself be a list of device names** — multiple cables to one peer (§15).

✅ VERIFIED — rules 3, 4 and 5 are enforced at launch, in `launch_jaccl`:

```python
if not hosts[0].ips:
    raise ValueError("Rank 0 should have an IP reachable from all other ranks")

jaccl_ring = args.backend == "jaccl-ring"
have_rdmas = all(len(h.rdma) == len(hosts) for h in hosts)
have_nulls = all(h.rdma[i] is None for i, h in enumerate(hosts))
if not have_rdmas or not have_nulls:
    raise ValueError("Malformed hostfile for jaccl backend")
```

So a wrong-length row or a missing diagonal `null` gives you the single message
**`Malformed hostfile for jaccl backend`** with no indication of *which* row. If you hit it, check
lengths first (rule 4 is the one people get wrong by writing three entries for a four-node cluster)
and diagonals second.

### 17.5 The second, undocumented hostfile form

Both Apple's session and Apple's documentation show a bare JSON **array**. The parser accepts a
JSON **object** as well, and that form carries two extra fields that make a hostfile
self-describing.

✅ **VERIFIED** — `python/mlx/_distributed_utils/common.py`, `Hostfile.from_file`, docstring
verbatim:

```python
@dataclass
class Hostfile:
    hosts: list[Host]
    backend: str = ""
    envs: list[str] = field(default_factory=list)
```

> *"Parse the json hostfile that contains both the hostnames to ssh into and the ips to communicate
> over when using the ring backend. It can also contain **the backend to be used and environment
> variables to set when launching a distributed job.**"*

with this example, verbatim from the docstring:

```json
{
    "backend": "jaccl",
    "envs": [
        "MLX_METAL_FAST_SYNCH=1"
    ],
    "hosts": [
        {"ssh": "hostname1", "ips": ["123.123.123.1"], "rdma": [null, "rdma_en2", "rdma_en3"]},
        {"ssh": "hostname2", "ips": ["123.123.123.2"], "rdma": ["rdma_en2", null, "rdma_en3"]},
        {"ssh": "hostnameN", "ips": ["123.123.123.N"], "rdma": ["rdma_en2", "rdma_en3", null]}
    ]
}
```

and the parser that accepts both:

```python
data = json.load(open(hostfile))
backend = ""
envs = []
hosts = []
if isinstance(data, dict):
    backend = data["backend"]
    envs = data["envs"]
    hosts = data["hosts"]
elif isinstance(data, list):
    hosts = data
```

**Prefer the object form.** It removes two entire classes of operator error: forgetting
`--backend jaccl` and forgetting `--env MLX_METAL_FAST_SYNCH=1`. The launcher reads both out of the
file, ✅ VERIFIED from `launch.py`:

```python
# Extract extra arguments from the hostfile
if hostfile.backend != "" and args.backend is None:
    args.backend = hostfile.backend
if args.backend is None:
    args.backend = "nccl" if mx.cuda.is_available() else "ring"
args.env = hostfile.envs + args.env
```

Two precedence facts fall out of those four lines: an **explicit `--backend` on the command line
wins** over the hostfile's, and **hostfile envs are placed before CLI envs** in the list.

⚠️ Note that when `data` is a dict, `backend` and `envs` are read with **`data["backend"]`**, not
`.get(...)`. An object-form hostfile that omits either key raises a `KeyError`, which
`from_file` re-wraps as `ValueError: Failed to parse hostfile … (…)`. If you use the object form,
include both keys even if `envs` is `[]`.

### 17.6 Generating the matrix rather than typing it

Six device names across four machines is twelve matrix entries plus four `null`s, and hand-editing
it is exactly the kind of task that produces a `Malformed hostfile` at 11pm. Use
`mlx.distributed_config` (§18). But if you need to build one by hand — a mixed cluster, an unusual
cabling, a machine the prober cannot reach — the following generates a well-formed skeleton you
then fill in from each node's `ibv_devices` output:

```python
#!/usr/bin/env python3
"""Emit a skeleton JACCL hostfile. Fill in the device names from `ibv_devices` on each node."""
import json, sys

hosts = sys.argv[1:]                      # e.g. m3-ultra-0 m3-ultra-1 m3-ultra-2 m3-ultra-3
if len(hosts) < 2:
    raise SystemExit("usage: make_hostfile.py host0 host1 [host2 ...]")

n = len(hosts)
doc = {
    "backend": "jaccl",
    "envs": ["MLX_METAL_FAST_SYNCH=1"],
    "hosts": [
        {
            "ssh": h,
            # rank 0 needs a reachable IP; the rest may be empty
            "ips": ["CHANGE-ME"] if i == 0 else [],
            # positional adjacency matrix; null on the diagonal
            "rdma": [None if i == j else "rdma_enX" for j in range(n)],
        }
        for i, h in enumerate(hosts)
    ],
}
print(json.dumps(doc, indent=2))
```

Then, on each node, `ibv_devices` tells you which `rdma_enN` corresponds to which physical port —
and `mlx.distributed_config --dot` (§18.3) draws you the graph so you can check the mapping
visually rather than by squinting at a matrix.

---

## 18. `mlx.distributed_config`

The tool that discovers your topology, configures the network, and writes the hostfile.

### 18.1 Apple's invocation, and the flag that is wrong in it

✅ **VERIFIED — Apple code sample, session 233 @ 8:56, verbatim:**

```bash
mlx.distributed_config \
    --hosts m3-ultra-0,m3-ultra-1,m3-ultra-2,m3-ultra-3 \
    --output "m3-ultra-jaccl.json" \
    --env MLX_METAL_FAST_SYNCH=1 \
    --auto-setup \
    --backend jaccl
```

The MLX documentation site shows the same `--output` spelling.

### ⚠️ `--output` does not exist. The flag is `--output-hostfile`.

✅ **VERIFIED** from the argparse block in
`python/mlx/_distributed_utils/config.py`, read on disk this session:

```python
parser.add_argument(
    "--output-hostfile", help="If provided, save the hostfile to this path"
)
```

and the only consumer:

```python
if args.output_hostfile:
    with open(args.output_hostfile, "w") as f:
        ...
```

There is no `--output` anywhere in the file. Apple's session slide and Apple's documentation site
**both** show `--output`; the shipping code says `--output-hostfile`. This series' precedence rule
is unambiguous here — code read on disk outranks a slide and outranks a docs page — so:

**Use `--output-hostfile`.** Copying Apple's command verbatim gets you
`error: unrecognized arguments: --output m3-ultra-jaccl.json`, which at least fails loudly, but it
will make you doubt your setup at the exact moment you have least confidence in it.

🔴 **GAP — whether `--output` was ever accepted.** The clone is shallow, so we cannot tell whether
`--output` is a removed alias or a documentation error that was never real. **Safe default:** use
`--output-hostfile`; if it errors, your MLX predates the rename and `--output` is correct.

### 18.2 The complete flag set

✅ VERIFIED from the argparse block:

```
mlx.distributed_config [--verbose]
                       [--hosts HOSTS]                    default 127.0.0.1, comma-separated
                       [--ignore-unreachable]
                       [--hostfile HOSTFILE]              read an existing one instead of --hosts
                       [--over {thunderbolt,ethernet}]    default thunderbolt
                       [--output-hostfile PATH]
                       [--auto-setup | --no-auto-setup]
                       [--dot]
                       [--backend {ring,jaccl,jaccl-ring}]
                       [--env KEY=VAL]                    repeatable
```

With the corrected flag name, Apple's command becomes:

```bash
mlx.distributed_config \
    --verbose \
    --hosts m3-ultra-0,m3-ultra-1,m3-ultra-2,m3-ultra-3 \
    --over thunderbolt \
    --backend jaccl \
    --env MLX_METAL_FAST_SYNCH=1 \
    --output-hostfile m3-ultra-jaccl.json \
    --auto-setup
```

Flag semantics, each with the session's verbatim explanation where one exists:

| Flag | Meaning |
|---|---|
| `--hosts` | comma-separated hostnames |
| `--output-hostfile` | hostfile path to write |
| `--env` | *"You can also **embed environment variables in the config. They will be set automatically on every node at launch time.**"* |
| `--auto-setup` | *"**configure the Thunderbolt network automatically**"* |
| `--backend` | *"defines whether it is a **mesh or ring**: for a mesh, `--backend` is set to **`jaccl`**… for a ring, we would change it to **`jaccl-ring`**."* |
| `--over` | `thunderbolt` (default) or `ethernet` |
| `--dot` | emit the discovered topology as GraphViz and exit |
| `--ignore-unreachable` | skip hosts that fail the SSH check |

Note that `--env` on this tool writes into the hostfile's `envs` array (§17.5), which is why the
object form of the hostfile exists. `--backend` likewise writes the `backend` field. So a hostfile
generated with the command above is fully self-describing and later launches need neither flag.

### ⚠️ `MLX_METAL_FAST_SYNCH=1` is not optional

> ✅ **VERIFIED** — 233, verbatim: *"Here we set **`MLX_METAL_FAST_SYNCH=1`**, which **enables
> faster GPU-to-CPU synchronization**. **It is critical for distributed tasks because computation
> runs on the GPU while communication runs on the CPU.**"*

> ✅ **VERIFIED** — MLX documentation, verbatim: *"Defining the environment variable
> `MLX_METAL_FAST_SYNCH=1` enables a different, faster way of synchronizing between the GPU and the
> CPU. It is not specific to the JACCL backend and can be used in all cases where the CPU and GPU
> need to collaborate for some computation and is **pretty critical for low-latency communication
> since the communication is done by the CPU**."*

Apple's own inline comment in the documented launch command is literally `# <--- important`. Two
independent sources call it critical. **Put it in the hostfile's `envs` and stop thinking about
it.**

⚠️ But know the counterweight. mlx#3830 (community-reported, closed 2026-08-04) documents a **Metal fence
handoff deadlock under `MLX_METAL_FAST_SYNCH=1`** — an orphaned `fence_wait` kernel that locks the
GPU until reboot — *and*, when the variable is unset, the same workload hitting the **~5 s GPU
watchdog** (`kIOGPUCommandBufferCallbackErrorTimeout`, at roughly 7,300 tokens). That is a
lose-lose report, single reporter, unresolved. If your cluster hangs the GPU hard enough to need a
reboot, this is the first thing to suspect and toggling the variable is the first experiment.

### 18.3 What `--auto-setup` actually does — and what it destroys

> ✅ **VERIFIED** — 233, verbatim: *"First, it **checks that all hosts are reachable over SSH**.
> Then it **probes each machine's Thunderbolt ports to discover which machines are physically
> connected to which — building a map of the topology**. Since we passed `--auto-setup`, it
> **disables the Thunderbolt Bridge on all machines** and **configures each Thunderbolt link for
> RDMA**. Finally, it **writes a JSON hostfile**."*

The MLX documentation gives a seven-step version of the same sequence: ssh to all nodes; extract
Thunderbolt connectivity; verify a valid mesh (JACCL) or ring; check RDMA is enabled; extract the
`en0` Ethernet IP; disable the Thunderbolt bridge and set up per-cable point-to-point networks;
write the hostfile.

⚠️ **It disables the Thunderbolt Bridge on every machine.** That is a destructive change to each
node's networking configuration, applied over SSH, to machines you may also be using for other
things. It requires **password-less sudo** on each node — ✅ VERIFIED from the docs: *"The
`--auto-setup` argument requires password-less sudo on each node."*

And it does this **even though the data path does not use TCP/IP at all**:

> ✅ **VERIFIED** — MLX documentation, verbatim: *"**Even though TCP/IP is not used when
> communicating with Thunderbolt RDMA, disabling the thunderbolt bridge is still required as well as
> setting up isolated local networks for each thunderbolt connection.**"*

**The escape hatch, and you should take it the first time:**

> ✅ **VERIFIED** — 233, verbatim: *"**without `--auto-setup` flag, script prints the configuration
> commands, so you can review them and run yourself.**"*

```bash
# dry run: prints the commands it WOULD run, and the hostfile it WOULD write
mlx.distributed_config --verbose \
    --hosts m3-ultra-0,m3-ultra-1,m3-ultra-2,m3-ultra-3 \
    --over thunderbolt --backend jaccl \
    --env MLX_METAL_FAST_SYNCH=1 \
    --output-hostfile m3-ultra-jaccl.json
```

Read what it prints. Then decide whether to re-run with `--auto-setup` or to apply the commands
yourself. On machines that do anything other than serve models, apply them yourself.

For a **ring** rather than a mesh the same tool works with `--backend ring`, and the docs describe
the manual equivalent verbatim: *"Disable the thunderbolt bridge interface"*; *"For the cable
connecting rank `i` to rank `i + 1` find the interfaces corresponding to that cable in nodes `i`
and `i + 1`"*; *"Set up a unique subnetwork connecting the two nodes for the corresponding
interfaces. For instance if the cable corresponds to `en2` on node `i` and `en2` also on node
`i + 1` then we may assign IPs `192.168.0.1` and `192.168.0.2` respectively to the two nodes."*

### 18.4 See the topology before you trust it

✅ VERIFIED — from the MLX documentation, verbatim:

```bash
mlx.distributed_config --verbose \
    --hosts m3-ultra-1,m3-ultra-2,m3-ultra-3,m3-ultra-4 \
    --over thunderbolt --dot | dot -Tpng | open -f -a Preview
```

This is the highest-value thirty seconds in the whole setup. It renders the discovered cabling as
a graph. A mesh looks like a complete graph; a missing cable is immediately obvious as a missing
edge, and a cable plugged into the wrong port shows up as an edge between the wrong pair. Doing
this *before* `--auto-setup` means you find your cabling mistakes while they are still cheap.

Requires GraphViz (`brew install graphviz`).

---

## 19. `mlx.launch`

### 19.1 What it is

> ✅ **VERIFIED** — 233, verbatim: *"MLX provides a **launch helper**… **You run `mlx.launch` on
> your MacBook and it orchestrates the cluster.** You give it **the executable you want to run** and
> a **JSON hostfile** describing your cluster. From there, it **SSHes into each node using hostnames
> from provided hostfile and starts the executable on every machine.**"*

Note who runs it: *"From **any machine with SSH access** to the cluster, for example **MacBook** in
my case…"* — **the launcher is not part of the cluster.** In Apple's demo a MacBook orchestrates
four M3 Ultras and is not one of the four. That is worth knowing because it means your laptop does
not need Thunderbolt, RDMA, macOS 26.2, or enough RAM for the model. It needs SSH.

### 19.2 The invocation

✅ **VERIFIED — Apple code sample, session 233 @ 11:04, verbatim:**

```bash
# Single-device LLM inference
mlx_lm.chat --model "Qwen/Qwen3.6-27B" --max-tokens 2048

# Distributed LLM inference across the cluster
mlx.launch --hostfile "m3-ultra-jaccl.json" -- \
    /remote/path/to/mlx_lm.chat --model "Qwen/Qwen3.6-27B" --max-tokens 2048
```

**Grammar: `mlx.launch [launcher flags] -- <remote-executable-path> [its args…]`.**

✅ VERIFIED on the `--` separator, from `launch.py`:

```python
args, rest = parser.parse_known_args()
...
if len(rest) == 0:
    parser.error("No script is provided")
if rest[0] == "--":
    rest.pop(0)
```

So `--` is **stripped if present and optional in principle** — but `parse_known_args` means any
token before it that looks like a launcher flag gets consumed by the launcher. If your remote
command has a `--verbose` or a `--hosts` of its own, omitting `--` silently hands it to
`mlx.launch` instead. **Always write the `--`.** It costs three characters and removes an entire
category of confusion.

### ⚠️ The path is the path *on the nodes*, not on the launcher

> ✅ **VERIFIED** — 233, verbatim: *"Keep in mind that **all necessary libraries like MLX must be
> installed on each Mac** and **the executable must be accessible on all machines**."*

That is why every one of Apple's samples says `/remote/path/to/mlx_lm.chat`. You are naming a path
that must resolve **on each node**, and the launcher does not check it for you before it starts
SSH-ing.

Three consequences:

- **Homebrew Python and system Python have different prefixes.** A venv at
  `/Users/you/venv/bin/mlx_lm.server` on your laptop is meaningless on a Studio whose user is
  someone else.
- **`mlx.launch --print-python`** exists precisely for this. ✅ VERIFIED as a flag; it prints the
  Python executable the launcher will use on the remote hosts (defaulting to `sys.executable`,
  overridable with `--python PATH`). Run it, then confirm that path exists on every node.
- **The safest invocation names the interpreter explicitly** and uses the module form, which is
  what the MLX documentation itself does:

```bash
mlx.launch --verbose --backend jaccl --hostfile m3-ultra-jaccl.json \
    --env MLX_METAL_FAST_SYNCH=1 -- \
    /path/to/remote/python -m mlx_lm chat --model mlx-community/DeepSeek-R1-0528-4bit
```

(✅ VERIFIED verbatim from the MLX documentation site, including the `# <--- important` comment on
the `--env` line in the original.)

Note `python -m mlx_lm chat`, not `python -m mlx_lm.chat`. ✅ VERIFIED: every mlx-lm module's
`__main__` block prints a deprecation banner — *"Calling `python -m mlx_lm.generate...` directly is
deprecated. Use `mlx_lm.generate...` or `python -m mlx_lm generate ...` instead."*

### 19.3 The full launcher flag set

✅ VERIFIED from `launch.py`'s argparse:

```
mlx.launch [--print-python] [--verbose]
           [--hosts HOSTS]                 default 127.0.0.1, comma-separated
           [--repeat-hosts N | -n N]       default 1, positive int
           [--hostfile HOSTFILE]
           [--backend BACKEND]             ring | mpi | nccl | jaccl | jaccl-ring
           [--env KEY=VAL]                 repeatable
           [--mpi-arg ARG]                 repeatable, passed to mpirun
           [--connections-per-ip N]        default 1 (ring)
           [--starting-port PORT | -p]     default 32323
           [--cwd DIR]
           [--nccl-port PORT]              default 12345
           [--python PATH]                 default sys.executable
           -- <script or command> [args...]
```

Backend resolution, ✅ VERIFIED: explicit `--backend` wins; else the hostfile's `backend` field;
else `"nccl" if mx.cuda.is_available() else "ring"`. **The default is never `jaccl`** — you must
ask for it, on the command line or in the hostfile. An invalid value gives
`"The backend should be one of {'ring', 'mpi', 'nccl', 'jaccl', 'jaccl-ring'}"`.

Two quality-of-life behaviours worth knowing: `mlx.launch` **broadcasts stdin to all processes and
gathers stdout/stderr**, which is why `pdb` works across ranks and why `mlx_lm.chat` is usable
interactively across a cluster; and **if one rank fails it kills the rest**, so you do not end up
with four orphaned processes holding 200 GB each. It also injects `COLUMNS`/`LINES` from the
terminal size.

⚠️ `--no-verify-script` appears in the MLX documentation's NCCL example but **is not in the
argparse list** we read. 🔴 GAP: either it is handled elsewhere or it is documentation drift.
**Safe default:** do not use it; if you need it and it errors, it does not exist on your version.

### 19.4 What `mlx.launch` does for JACCL, exactly

✅ VERIFIED — `launch_jaccl` in full, minus the process plumbing:

```python
coordinator = hosts[0].ips[0]
env = args.env
cwd = args.cwd
env.append(f"MLX_JACCL_COORDINATOR={coordinator}:{args.starting_port}")
if jaccl_ring:
    env.append("MLX_JACCL_RING=1")
files = {"MLX_IBV_DEVICES": json.dumps([h.rdma for h in hosts])}
```

Three facts you cannot get any other way:

- **The coordinator is rank 0's first IP, on `--starting-port` (default 32323).** That is the
  "initial coordination" the session mentions, and it is why rank 0 needs a reachable IP. If port
  32323 is firewalled between your nodes, JACCL never forms a group — and the symptom is a hang,
  not an error (see §25).
- **`jaccl-ring` is `jaccl` plus `MLX_JACCL_RING=1`.** Same launcher path, same hostfile
  validation, one environment variable. So a hostfile that works for `jaccl` works for
  `jaccl-ring` — which is another argument for cabling a mesh: you can switch strategies without
  re-cabling.
- **The adjacency matrix is shipped to the nodes as a file, referenced by `MLX_IBV_DEVICES`.** It
  is the `rdma` rows and nothing else — no hostnames, no IPs. §26 shows how to set the same
  variables by hand.

### 19.5 A pre-flight test that costs nothing

Before you launch a 600 GB model across four machines, launch four floats. This is the
`test.py` shape the MLX docs use, expanded with the checks that actually tell you something:

```python
#!/usr/bin/env python3
# cluster_smoke.py  — copy to the SAME PATH on every node
import os
import mlx.core as mx

# strict=True makes a failed backend init raise instead of silently
# degrading to a singleton group of size 1.
world = mx.distributed.init(strict=True, backend="jaccl")

rank, size = world.rank(), world.size()
print(f"[rank {rank}/{size}] host={os.uname().nodename} "
      f"fast_synch={os.environ.get('MLX_METAL_FAST_SYNCH')!r}", flush=True)

# every rank contributes its own rank; the sum must be 0+1+...+(size-1)
data = mx.full((4,), float(rank), dtype=mx.float32)
result = mx.distributed.all_sum(data, group=world)
mx.eval(result)

expected = size * (size - 1) / 2
ok = bool((result == expected).all().item())
print(f"[rank {rank}] all_sum -> {result.tolist()} expected {expected} :: "
      f"{'OK' if ok else 'MISMATCH'}", flush=True)
raise SystemExit(0 if ok else 1)
```

```bash
mlx.launch --verbose --hostfile m3-ultra-jaccl.json -- \
    /remote/path/to/python /remote/path/to/cluster_smoke.py
```

**`strict=True` is the important part.** ✅ VERIFIED from the signature
`mx.distributed.init(strict: bool = False, backend: str = 'any')`, and from the docs' description
of `any`: *"MLX will try all available backends. **If they all fail then a singleton group is
created.**"* With `strict=False` — the default — a cluster that fails to form does not error. Every
node runs happily as a group of size **1**, every collective is a no-op (§14.2), and your
"distributed" run is four independent single-machine runs producing four independent answers.
Apple's own sample code passes `strict=True` in every distributed snippet in session 233. Copy
that.

**What each failure tells you:**

| Symptom | Likely cause |
|---|---|
| `ValueError: Rank 0 should have an IP reachable from all other ranks` | `"ips": []` on the first host |
| `ValueError: Malformed hostfile for jaccl backend` | wrong `rdma` row length, or a missing diagonal `null` |
| SSH prompt / permission denied | password-less SSH not set up for that exact hostname |
| Only one rank prints, and it says `1/1` | `strict=False` and the backend failed — you are not distributed |
| Nothing prints, forever | coordinator port unreachable, or RDMA not actually enabled on a node |
| `MISMATCH` | genuine numerical or routing problem — stop and investigate before loading a model |

---

## 20. Running the server across machines

Session 232 hands this off in one sentence:

> ✅ **VERIFIED** — 232:102–105: *"Setting up distributed inference with MLX-LM Server is fairly
> straightforward. **You launch the server using `mlx.launch` and a hostfile that contains
> information about the nodes and the type of connection. The model is automatically sharded across
> all available devices and everything else just works.**"*

The command:

```bash
mlx.launch --backend jaccl --hostfile m3-ultra-jaccl.json \
    --env MLX_METAL_FAST_SYNCH=1 -- \
    /remote/path/to/mlx_lm.server \
        --model mlx-community/Llama-3.3-70B-Instruct-4bit \
        --host 127.0.0.1 --port 8080
```

### 20.1 Only rank 0 serves HTTP

✅ VERIFIED — `mlx_lm/server.py`, `run()`, verbatim:

```python
def run(host, port, model_provider, server_class=ThreadingHTTPServer, handler_class=APIHandler):
    group = mx.distributed.init()
    prompt_cache = LRUPromptCache(model_provider.cli_args.prompt_cache_size)
    response_generator = ResponseGenerator(model_provider, prompt_cache)
    if group.rank() == 0:
        _run_http_server(host, port, response_generator)
    else:
        response_generator.join()
```

Every node runs the same program. **Rank 0 binds the socket; every other rank joins the generator
loop and never listens.** So:

- **Point your agent at rank 0's host and port**, which is the first entry in your hostfile.
- If you launched with `--host 127.0.0.1` (the default), the endpoint is only reachable *on rank
  0's machine*. From your laptop, tunnel: `ssh -N -L 8080:127.0.0.1:8080 m3-ultra-0`.
- Do not expect a health endpoint on ranks 1..N−1. There is nothing listening there.

Seeds are synchronised across ranks at startup, ✅ VERIFIED:

```python
seed = mx.distributed.all_sum(mx.random.state[0]).view(mx.uint64).item()
mx.random.seed(seed)
```

so sampling is consistent across the group rather than each node rolling its own dice.

### 20.2 What the server refuses in distributed mode

✅ VERIFIED — `mlx_lm/server.py:311`, the exact string:

```
"Loading with adapters or draft models not supported in distributed mode"
```

**Adapters and draft models are both rejected.** For adapters that means you must `mlx_lm.fuse`
your LoRA into the base weights before serving a cluster; there is no per-request `adapters` field
that works here. For draft models it is doubly moot, since a draft model would disable continuous
batching anyway (§8.4).

`mlx_lm.chat` enforces the same adapter rule with a friendlier message —
`parser.error("Adapters not supported in distributed mode")`.

### 20.3 The time budget

One piece of distributed-specific machinery inside the server is worth knowing about because it
explains a latency characteristic. ✅ VERIFIED: `TimeBudget(budget=0.5, iterations=25,
sync_frequency=10)` bounds how long the generation thread spends stepping the batch before it
checks the request queue again. **In distributed mode it switches from a wall clock to an
iteration count**, periodically re-tuned via `mx.distributed.all_sum`.

The reason is that a wall clock is a per-node quantity and the nodes must step in lockstep; an
iteration count is a group quantity. The consequence is that request-pickup latency on a
distributed server is quantised to a number of decode iterations rather than to 0.5 s, and that
number is adaptive. If you see request admission latency that varies with model size on a cluster
but not on a single machine, this is why.

Distributed request fan-out uses `pickle.dumps` plus an `mx.distributed.all_sum` of a `uint8`
array — ✅ VERIFIED, the helper is `_share_object`. That is a genuinely cute trick (using the
collective as a broadcast channel) and it is the same technique `mlx_lm.share` uses for weights
(§23).

---

## 21. Tensor vs pipeline parallelism

Two ways to split a model. They are not interchangeable and only one of them makes inference
faster.

| Strategy | Splits by | Speeds up inference? | Communication |
|---|---|---|---|
| **Pipeline** | **depth** — *"each machine holds a **group of layers**, and data moves through the machines sequentially"* | **No** — *"**It does not speed up the inference**, because each token still has to pass through the layer groups one after another."* | *"**simple communication**: machines only exchange activations **at the boundaries between layer groups**."* |
| **Tensor** | **width** — *"each machine holds **part of every layer**, so **all machines process the same token at the same time**"* | **Yes** — *"It **improves inference speed** due to parallelized per-layer computation."* | *"**much more frequent communication, that happens at every layer and for every token**."* |

(All quotes ✅ VERIFIED verbatim from session 233.)

**The default:** *"**Tensor parallelism is the default sharding strategy in MLX LM.**"*
**Opt out:** *"append a flag **`--pipeline`** to the command."*
⚠️ *"**Note, that not all models support pipeline parallelism.**"*

✅ **VERIFIED — Apple code sample, session 233 @ 15:03, verbatim:**

```bash
# Tensor parallelism (default)
mlx.launch --hostfile "m3-ultra-jaccl.json" -- \
    /remote/path/to/mlx_lm.chat --model "moonshotai/Kimi-K2.6" \
                                 --max-tokens 2048

# Pipeline parallelism — append --pipeline flag
mlx.launch --hostfile "m3-ultra-jaccl.json" -- \
    /remote/path/to/mlx_lm.chat --model "moonshotai/Kimi-K2.6" \
                                 --max-tokens 2048 \
                                 --pipeline
```

### 21.1 How the choice is made in code

✅ VERIFIED — `mlx_lm/utils.py`:

```python
def sharded_load(repo, pipeline_group=None, tensor_group=None, return_config=False, *,
                 tokenizer_config=None, trust_remote_code=False)
def pipeline_load(repo, return_config=False)   # = sharded_load(repo, mx.distributed.init(), None, ...)
```

`sharded_load` lazily loads the model **without weights** to discover its capabilities —
`has_pipelining = hasattr(model, "model") and hasattr(model.model, "pipeline")`,
`has_tensor_parallel = hasattr(model, "shard")` — then either honours the group you passed or, if
you passed neither, **auto-picks tensor parallel when available and pipelining otherwise**. It
raises clearly when you ask for the impossible: *"The model does not support pipelining but a
pipeline_group was provided"*, *"The model does not support tensor parallelism but a tensor_group
was provided"*, *"The model does not support any sharding"*. It ends with a barrier:
`mx.eval(mx.distributed.all_sum(mx.array(1.0), stream=mx.cpu))`.

Which models support which, ✅ VERIFIED by grep over `mlx_lm/models/*.py` at this commit:

- **`shard(group)` — tensor parallel, 18 files:** `deepseek_v2`, `exaone_moe`, `deepseek_v32`,
  `iquestloopcoder`, `deepseek_v3`, `llama`, `longcat_flash`, `ministral3`, `minimax`, `glm4_moe`,
  `glm4_moe_lite`, `qwen2`, `gpt_oss`, `kimi_k25`, `qwen3`, `longcat_flash_ngram`, `qwen3_5`,
  `step3p5`.
- **`pipeline(group)` / `PipelineMixin` — 7 files:** `deepseek_v3`, `glm4_moe_lite`, `deepseek_v2`,
  `deepseek_v32`, `glm4_moe`, `qwen3_5`, `ministral3`.

Note how much smaller the pipeline list is — Apple's warning that "not all models support pipeline
parallelism" understates it. Tensor parallelism is the better-supported path *and* the faster one.

Two implementation details that explain observed behaviour:

- **Pipelining only downloads the shard's weight files**, using `model.safetensors.index.json`'s
  `weight_map`. If the index is missing it raises *"Pipeline loading is only supported for MLX
  converted models."* So pipelining has a real advantage: each node downloads only what it needs.
- **`PipelineMixin` splits `self.layers` in reverse**, so **rank 0 gets the *last* layers**.
  Non-local layers are set to `None` to keep numbering stable for weight loading. If you are
  debugging a pipeline shard and rank 0 has the head rather than the embedding, that is why.

Tensor-parallel sharding itself uses
`mlx.nn.layers.distributed.shard_linear(layer, "all-to-sharded" | "sharded-to-all", group=group)`
and divides `n_heads` / `n_kv_heads` by the group size. A representative model's `shard`:

```python
def shard(self, group: mx.distributed.Group):
    ...
    self.wq = nn.layers.distributed.shard_linear(self.wq, "all-to-sharded", group=group)
    self.wk = nn.layers.distributed.shard_linear(self.wk, "all-to-sharded", group=group)
    self.wv = nn.layers.distributed.shard_linear(self.wv, "all-to-sharded", group=group)
    self.wo = nn.layers.distributed.shard_linear(self.wo, "sharded-to-all", group=group)
```

`ShardedToAllLinear` is the row-parallel half and **does the `all_sum`** so every rank ends with
the same result; `AllToShardedLinear` is column-parallel and does not. That asymmetry is why the
last projection in a block is `sharded-to-all` and the first three are not.

### 21.2 The programmatic form

✅ **VERIFIED — Apple code sample, session 233 @ 19:01, verbatim:**

```python
import mlx.core as mx
from mlx_lm import stream_generate
from mlx_lm.utils import sharded_load

# Initialise distributed backend
group = mx.distributed.init(strict=True, backend="jaccl")
# Define parallelism
tensor_group, pipeline_group = group, None

# Shard the model
model, tokenizer = sharded_load("moonshotai/Kimi-K2.6", pipeline_group, tensor_group)
for response in stream_generate(model, tokenizer, prompt, max_tokens=1024):
    if group.rank() == 0:
        print(response.text, end="", flush=True)
```

Two things to copy: **`strict=True`** (§19.5), and **`if group.rank() == 0`** before any output.
Every node runs the same program, so unguarded `print` gives you *N* interleaved copies. mlx-lm's
own helper `cli_ui.rprint` does exactly this — prints on rank 0 only.

Also note the positional order: `sharded_load(repo, pipeline_group, tensor_group)`. **Pipeline
first, tensor second.** Passing `None` for pipeline gives pure tensor parallelism. Getting these
the wrong way round on a model that supports both gives you a working but slower cluster and no
error.

The corresponding low-level form, ✅ **VERIFIED — Apple code sample, session 233 @ 19:31:**

```python
import mlx.core as mx
import mlx.nn as nn

group = mx.distributed.init(strict=True, backend="jaccl")

layer = nn.Linear(1024, 1024)
sharded_layer = nn.layers.distributed.shard_linear(
    layer, strategy="all-to-sharded", group=group
)
data = mx.random.normal((1, 1, 1024))
output = sharded_layer(data)
mx.eval(output)
```

🟡 `"sharded-to-all"` is the obvious complement and appears in mlx-lm's model code, but only
`"all-to-sharded"` was shown as a `strategy=` keyword in the session. Both strings are attested in
`mlx.nn.layers.distributed`; other strategy strings are **UNVERIFIED**.

---

## 22. Distributed fine-tuning, and the `--batch-size` trap

Fine-tuning across a cluster is data-parallel, not model-parallel, and the command is almost
identical to the single-machine one. Which is exactly why the one difference is dangerous.

> ✅ **VERIFIED** — 233, on the mechanics: *"**We replicate the model on every Mac.** Each machine
> receives a **different batch of data** and **computes gradients locally**. Then we **average the
> gradients**, so the model's update uses information from all batches."*

And the pitch, which is a genuinely good one:

> ✅ **VERIFIED** — 233: *"Fast, efficient, and **fully private — your data never leaves your
> machines**."*

✅ **VERIFIED — Apple code sample, session 233 @ 17:18, verbatim:**

```bash
# Single-device fine-tuning
mlx_lm.lora --model "Qwen/Qwen3.5-9B" \
             --data "mlx-community/wikisql" \
             --train --batch-size 4

# Distributed fine-tuning (scale --batch-size by number of devices)
mlx.launch --hostfile "hostfile.json" -- \
    /remote/path/to/mlx_lm.lora --model "Qwen/Qwen3.5-9B" \
                                  --data "mlx-community/wikisql" \
                                  --train --batch-size 16
```

Four to sixteen. Four devices. That is the whole story, and it is the one thing in Part B that will
silently ruin an experiment.

### ⚠️ SILENT FAILURE: `--batch-size` is the **global** batch, and you must scale it by N

> ✅ **VERIFIED** — 233, verbatim: *"**Data sharding is handled by MLX LM** and the command is
> almost identical — **we scale `--batch-size` by the number of devices so each machine still
> processes the same number of samples per step as before.**"*

`--batch-size` is **not per-device**. It is the total number of samples consumed per optimizer
step across the whole cluster. mlx-lm slices the dataset by rank — ✅ VERIFIED from
`tuner/trainer.py`'s `iterate_batches`: `offset = comm_group.rank()`, `step = comm_group.size()`,
with the guard `ValueError("The batch size must be divisible by the number of workers")`.

So on four machines:

| You write | Per-device batch | Effective global batch | What you actually ran |
|---|---|---|---|
| `--batch-size 4` (unchanged) | **1** | **4** | a *different experiment*: 4× smaller per-device batch |
| `--batch-size 16` (scaled) | 4 | 16 | the intended experiment, 4× the throughput |

**Why this is silent.** The divisibility guard fires only when `batch_size % world_size != 0`.
`4 % 4 == 0`, so `--batch-size 4` on four machines runs cleanly. Nothing warns. The loss curve
looks plausible. Throughput looks great — because each device is doing a quarter of the work you
think it is. Gradient noise is four times higher than the single-machine run you are comparing
against, your effective learning rate is wrong for the batch size, and if you are comparing a
distributed run against a single-machine baseline you are comparing two different
hyperparameter settings and attributing the difference to the cluster.

**The rule, as a formula:** `--batch-size` on N devices should be `N ×` the value you would use on
one, to hold per-device batch constant. If instead you want to hold *global* batch constant and
just go faster, leave it — but then say so out loud in your notes, because it is a different
experiment and a defensible one.

**A guard you can actually run.** Print the arithmetic at the top of every distributed training
run:

```python
import mlx.core as mx

group = mx.distributed.init(strict=True, backend="jaccl")
n = group.size()
global_batch = args.batch_size            # whatever you passed to --batch-size
per_device   = global_batch // n

if group.rank() == 0:
    print(f"[dist] world_size={n} "
          f"global_batch={global_batch} per_device={per_device} "
          f"grad_accum={args.grad_accumulation_steps} "
          f"effective_batch={global_batch * args.grad_accumulation_steps}")
    if per_device != EXPECTED_PER_DEVICE:      # the number from your single-machine run
        raise SystemExit(
            f"[dist] per-device batch {per_device} != expected {EXPECTED_PER_DEVICE}; "
            f"pass --batch-size {EXPECTED_PER_DEVICE * n}"
        )
```

Three lines of output at the top of a log is the difference between reproducing your run in six
months and not.

Note that `--grad-accumulation-steps` multiplies on top of this and is **per-device**, so the true
effective batch is `global_batch × grad_accumulation_steps`. Two knobs, two different scopes,
adjacent on the command line. Write them both into your run notes.

### 22.1 The rest of distributed training

- **Gradient averaging** happens via `average_gradients` (from `mlx.nn.utils`) before
  `optimizer.update`. ✅ VERIFIED from `tuner/trainer.py`. Under the hood
  `sum_gradients` concatenates gradient groups until they exceed an `all_reduce_size` byte
  threshold, does **one `all_sum` per group**, then splits back — so you get a handful of large
  collectives per step rather than one per parameter.
- **Checkpointing is rank-0 only.** Every `steps_per_save` iterations and at the end, rank 0
  writes `adapters.safetensors` plus `{it:07d}_adapters.safetensors`.
- **Adapters cannot be used for distributed *inference*** (§20.2) even though you just trained
  them distributed. Fuse first: `mlx_lm.fuse --model <base> --adapter-path adapters
  --save-path fused_model`.
- **Other distributed-aware entry points:** `mlx_lm.evaluate` splits requests `requests[rank::size]`
  and gathers with `mx.distributed.all_gather`; `mlx_lm.awq` splits calibration data with
  `dist_split` and `all_sum`s the losses; `mlx_lm.dwq` takes `--pipeline`; `mlx_lm.benchmark` and
  `mlx_lm.chat` take `--pipeline`.

---

## 23. Getting the weights onto the nodes: `mlx_lm.share`

A four-node cluster downloading a 600 GB model four times from Hugging Face is a bad afternoon.
`mlx_lm.share` (new, © 2026 in the source header) copies a model directory from whichever node has
it to all the others, over the distributed backend itself.

✅ VERIFIED from `mlx_lm/share.py`:

```bash
mlx_lm.share --model mlx-community/Llama-3.3-70B-Instruct-4bit --hostfile hosts.json
```

Flags: `--path`, `--model`, `--hostfile`, `--dst`, `--tmpdir`.

Mechanics, all ✅ VERIFIED:

- If run with world size 1 it **re-launches itself** via
  `mlx._distributed_utils.launch.launch_ring` / `launch_jaccl` using the hostfile — so you run it
  once, on one machine, without `mlx.launch`.
- The backend must be one of `ring`, `jaccl`, `jaccl-ring`; the hostfile must have more than one
  host **and a `backend` field**. That is the object-form hostfile from §17.5, and this is a tool
  that requires it.
- Transfers happen in **100 MB chunks** (`CHUNK_SIZE = 100 * 1024 * 1024`) using
  `mx.distributed.all_sum` as the transport — the same trick as `_share_object` in the server.
  Directories and symlinks are preserved via a `DirectoryEntry` structure; files land in a
  `TemporaryDirectory` and are then `os.rename`d into place, so a failed transfer does not leave a
  half-written model.
- If nothing is found, the error text is helpful, verbatim: *"The `--path` needs to exist in at
  least one node. If it is a remote repository download it first with `hf download`"*.

So the intended flow is: `hf download` once, on one machine, then `mlx_lm.share` to fan it out.

🔴 **GAP — `mlx_lm.share`'s hostfile schema is not documented in mlx-lm.** It imports
`from mlx._distributed_utils.common import Hostfile`, so it inherits §17.5's schema, but mlx-lm's
own docs do not say so. **Safe default:** generate the hostfile with `mlx.distributed_config
--backend jaccl --env … --output-hostfile …`, which produces the object form with both required
fields.

---

## 24. Apple's measured numbers

**Attribution: Apple-published**, WWDC26 session 233. Hardware stated in the session: **4 × M3
Ultra, meshed over Thunderbolt 5, RDMA enabled**, orchestrated from a MacBook over SSH. No OS
build, no MLX version, no date, and no methodology beyond the model names are given. Present them
as Apple's numbers, not as reproducible benchmarks.

| Workload | Model | Single M3 Ultra | 4 × M3 Ultra | Apple's wording |
|---|---|---|---|---|
| **Inference (decode)** | Qwen 3.6, **27B** | baseline | ~3× | *"**The cluster generates tokens at nearly three times the rate of a single machine** for Qwen 3.6 model."* |
| **LoRA fine-tuning** | Qwen 3.5, **9B** | **~180 tok/s** | **~600 tok/s** | *"which gives us **more than 3 times speed up** for fine-tuning"* |
| **Capacity** | Kimi 2.6, **1 trillion** params | ❌ does not fit | ✅ fits | *"Even with **8-bit quantization**, the weights alone require **about one terabyte of memory**. **That does not fit on a single M3 Ultra, but it can fit across four.**"* |

⚠️ **Apple's own caveat, which must travel with the numbers:** *"**The exact speedup depends on the
model size and architecture.**"* The ~3× is not a law. A model with more communication per token —
more layers, smaller hidden dimension, more frequent all-reduces — will scale worse.

⚠️ **180 → 600 tok/s are the only absolute figures in the session.** Everything else is a ratio.
Cite them as *fine-tuning throughput on a 9B model with `mlx_lm.lora` on 4 × M3 Ultra*, never as a
general benchmark.

The theoretical ceiling Apple states for the data-parallel case is *"with N machines we can process
data up to N times faster."* Four machines yielding "more than 3×" is roughly 75–80% scaling
efficiency, which is a reasonable expectation to carry into your own planning.

Session 232 states the inference-side headline independently and slightly more conservatively:

> ✅ **VERIFIED** — 232:106–108: *"**Starting with macOS 26.2, we have support for Thunderbolt
> RDMA, which provides low-latency, high-bandwidth communication over Thunderbolt. As a result,
> distributed inference with MLX has seen significant speed-ups: up to three times with four
> nodes.**"*

Note "up to". Two sessions, same cluster size, one says "nearly three times" and the other "up to
three times". Treat 3× on four nodes as a ceiling, not a floor.

---

## 25. The distributed bug cluster

This is the newest surface in the entire 2026 stack and the issue tracker shows it. Everything
below is **community-reported on GitHub**, read 2026-07-27, **open** at that date unless noted.
None of it should stop you from using distributed MLX; all of it should shape how you debug it.

**mlx#3910 — JACCL `MeshImpl::recv` spins forever on peer loss.** A silent hang with no timeout. If
one node dies, sleeps, or loses a cable, the survivors do not error — they wait. Combined with
`mlx.launch`'s "kill the rest if one fails" behaviour this is mostly survivable, but a node that
goes *quiet* rather than *dying* produces an indefinite stall.

**mlx#3777 — JACCL segfaults in `ibv_reg_mr` (null protection domain) when RDMA is absent.** This
is the crash you get if you skipped §16 on one machine. It is a segfault, not a message, so the
diagnostic value is nil — which is why `ibv_devices` on every node before you launch is not
optional.

**mlx#3755 — ring and jaccl both fail to connect (errno 60/65) on a 4-node M3 Ultra cluster.**
errno 60 is `ETIMEDOUT`, errno 65 is `EHOSTUNREACH`. The shape of a coordinator or per-cable
subnet that is not reachable. Cross-check with §19.4: rank 0's IP plus `--starting-port` (32323)
must be reachable from every node.

**mlx#3862 — ring `SocketThread` dies silently on a transient connection reset**, after which all
ranks wedge in `Event::wait`. A single blip on the network is enough.

**mlx#3830 — `MLX_METAL_FAST_SYNCH=1` deadlock vs GPU watchdog.** Covered in §18.2. With the
variable set, an orphaned `fence_wait` kernel can lock the GPU until reboot; without it, the same
workload hits the ~5 s GPU watchdog (`kIOGPUCommandBufferCallbackErrorTimeout`) at around 7,300
tokens.

**mlx#3876 — CUDA distributed `all_sum` barrier hangs** in `cu::AtomicEvent::wait` on Blackwell.
Not Apple silicon, but it tells you the instability is in the distributed layer generally, not just
in JACCL.

**Open work in flight:** PR **#3933** *"Fix crashes in the ring and jaccl distributed backends"*;
and PRs **#3899 / #3900 / #3901** — JACCL optional coordinator, ring refactor with threads for
multiple rings, and scatter-reduce — authored by `angeloskath`, one of the two people JACCL is
named after. That is a maintainer actively reworking the backend, which is both reassuring and a
reason to expect behaviour to change.

### 25.1 The community RDMA port report

⚠️ **Community-reported, status unknown, no replies captured.** Apple Developer Forums thread
**836897**: *"RDMA issue in using the thunderbolt port next to ethernet on M3 ultra mac studio."*

That is the entire signal we have — a title from a forum topic capture. There is no captured body,
no Apple reply, and no confirmation from a second reporter. We include it because it is
specific, plausible, and cheap to work around:

- **Specific:** it names one machine (M3 Ultra Mac Studio) and one port (the Thunderbolt port
  physically adjacent to the Ethernet jack).
- **Plausible:** `mlx.distributed_config` disables the Thunderbolt Bridge and reconfigures
  interfaces (§18.3), and interface enumeration on a machine with both Thunderbolt and Ethernet is
  exactly where a port-to-`enN` mapping can go wrong.
- **Cheap to work around:** if you have spare ports, do not use that one.

**What to do:** build your mesh using the ports furthest from the Ethernet jack first. If you must
use it, verify explicitly — `ibv_devices` should list a device for it, and
`mlx.distributed_config --dot` (§18.4) should draw the edge. If either is missing, move the cable
before you spend an evening on the hostfile.

🔴 **GAP.** We could not read the thread body, any reply, or any reproduction. **What would resolve
it:** fetching forum thread 836897 and checking for an Apple or community reply, or a direct test
on an M3 Ultra Mac Studio using that specific port. Do not present this as a known hardware defect;
present it as one unreplied report.

### 25.2 A debugging order that works

When a distributed run misbehaves, work up the stack. Each step is cheap and eliminates a layer.

1. **`ibv_devices` on every node.** Empty output ⇒ RDMA is off on that node ⇒ §16.
2. **`mlx.distributed_config --dot`** and look at the graph. A missing edge is a cable.
3. **The smoke test from §19.5, with `strict=True`.** If it prints `1/1`, you never formed a group.
4. **Toggle `MLX_METAL_FAST_SYNCH`.** If a hang becomes a watchdog timeout or vice versa, you are
   in mlx#3830.
5. **Try `--backend jaccl-ring`.** Same hostfile, one env var (§19.4). If ring routing works and
   mesh does not, it is a JACCL mesh path problem, and that is a filable bug.
6. **Fall back to `--backend ring`.** Slower — an order of magnitude more latency per the docs —
   but it uses TCP and nothing else, so if ring works and jaccl does not, the problem is RDMA, not
   your program.
7. **Only then** suspect the model or your code.

Steps 5 and 6 are the useful ones because they bisect the stack at the transport layer, and both
reuse the hostfile you already have.

---

## 26. Running without `mlx.launch`

Sometimes you cannot use the launcher — you are inside a container, or a job scheduler owns
process placement, or you want the server under launchd on each node. Every backend is drivable
through environment variables.

✅ VERIFIED — MLX documentation site, verbatim per backend.

**JACCL:**

- `MLX_RANK` — a single 0-based integer, this process's rank.
- `MLX_JACCL_COORDINATOR` — *"the IP and port that rank 0 can listen to all the other ranks connect
  to in order to establish the RDMA connections."*
- `MLX_IBV_DEVICES` — *"the path to a json file that contains the ibverbs device names that connect
  each node to each other node"*:

```json
[
    [null, "rdma_en5", "rdma_en4", "rdma_en3"],
    ["rdma_en5", null, "rdma_en3", "rdma_en4"],
    ["rdma_en4", "rdma_en3", null, "rdma_en5"],
    ["rdma_en3", "rdma_en4", "rdma_en5", null]
]
```

That is the hostfile's `rdma` column, and nothing else — no hostnames, no IPs. It matches exactly
what `launch_jaccl` writes (§19.4): `files = {"MLX_IBV_DEVICES": json.dumps([h.rdma for h in hosts])}`.

**Ring:**

- `MLX_RANK` — as above.
- `MLX_HOSTFILE` — *"the path to a json file that contains IPs and ports for each rank to listen
  to"*:

```json
[
    ["123.123.1.1:5000", "123.123.1.2:5000"],
    ["123.123.2.1:5000", "123.123.2.2:5000"],
    ["123.123.3.1:5000", "123.123.3.2:5000"],
    ["123.123.4.1:5000", "123.123.4.2:5000"]
]
```

- `MLX_RING_VERBOSE=1` — optional, more logging from the backend.

**NCCL:** `MLX_RANK` plus `MLX_WORLD_SIZE`.

A launchd-style JACCL invocation for rank 2 of four, assembled from the above:

```bash
export MLX_RANK=2
export MLX_JACCL_COORDINATOR=192.168.1.10:32323
export MLX_IBV_DEVICES=/etc/mlx/ibv_devices.json
export MLX_METAL_FAST_SYNCH=1
exec /opt/mlx/bin/mlx_lm.server --model /models/Llama-3.3-70B-Instruct-4bit --port 8080
```

Remember §20.1: on ranks other than 0 the `--port` is inert, because only rank 0 binds.

🟡 **RECONSTRUCTED — the `jaccl-ring` env var.** `launch_jaccl` sets `MLX_JACCL_RING=1` for the
`jaccl-ring` backend (✅ VERIFIED from `launch.py`), so setting it by hand should select ring
routing over mesh cabling. It is not in the documentation's env-var list. **Safe default:** use
`mlx.launch --backend jaccl-ring` if you can; if you must set it manually, verify with a smoke
test rather than assuming.

[^scope-source]: Source snapshot: [`ml-explore/mlx-lm` at `e5baded`](https://github.com/ml-explore/mlx-lm/tree/e5baded8c1d286754edb479ffbde4655a68e2758).
[^trust-cli-source]: At the pinned revision, the dispatcher lists the commands in
    [`mlx_lm/cli.py`](https://github.com/ml-explore/mlx-lm/blob/e5baded8c1d286754edb479ffbde4655a68e2758/mlx_lm/cli.py),
    while [`manage.py`](https://github.com/ml-explore/mlx-lm/blob/e5baded8c1d286754edb479ffbde4655a68e2758/mlx_lm/manage.py),
    [`upload.py`](https://github.com/ml-explore/mlx-lm/blob/e5baded8c1d286754edb479ffbde4655a68e2758/mlx_lm/upload.py),
    and [`share.py`](https://github.com/ml-explore/mlx-lm/blob/e5baded8c1d286754edb479ffbde4655a68e2758/mlx_lm/share.py)
    define no `--trust-remote-code` argument.
