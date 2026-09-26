# The `fm` CLI and the Foundation Models SDK for Python

**Part 5 · Prototyping, profiling, non-Swift access · Reference 02**

**Version floor.** Two products with two different floors, and confusing them is the first mistake:

- **The `fm` command-line tool is macOS 27.0 and nothing else.** It ships **preinstalled** with
  macOS 27 — there is no download, no `brew install`, and no back-deployment to macOS 26.
- **The Foundation Models SDK for Python (`apple-fm-sdk`) runs on macOS 26.0+.** Its own README
  requires **macOS 26.0+, full Xcode 26.0+ (not Command Line Tools), Python 3.10+, Apple silicon,
  and Apple Intelligence enabled**. Two features inside it have their own, later floors:
  **token counting and `context_size` need macOS 26.4+ at runtime**, and **image attachments need
  the macOS 27 SDK at *build* time and macOS 27 at *runtime*.** The build-time half of that is a
  genuine silent capability change and it gets its own callout in §6.4.

That gap is the single most useful fact in this guide: the Python SDK is a **26-generation**
product. It does not expose the 27-era Foundation Models additions — no Private Cloud Compute, no
`LanguageModel` protocol, no dynamic profiles. WWDC26 session 334 presents the CLI and the SDK
together as this year's news, and for the CLI that is true; for the SDK it is a framing artefact.
§5.2 works through the discrepancy in detail, because it decides whether this SDK is useful to you
at all.

---

## ⚠️ Read this before you read anything else: the evidence here is the weakest in Parts 1–6

Every other guide in Parts 1–6 rests on at least one of: a shipping Apple sample project, an SDK
header on disk, or an Apple documentation page. This guide's two halves sit at opposite ends of the
corpus:

| Half of the guide | Evidence class | Grade |
|---|---|---|
| **Python SDK** | The **actual Apple-authored repository, cloned and read file by file** — 15 Python modules, an 1,831-line Swift shim, a 146-line C header, 17 test files, the Sphinx docs, plus the full GitHub issue and PR history. | **Strong.** Comparable to reading a header. Better than a transcript. |
| **`fm` CLI** | Apple narration and engineer statements, a full project-run beta-5 help capture, and a second project-run comparison against stable macOS 27 (`26A428`, 2026-09-16). | **Strong for beta-versus-stable command grammar.** Runtime semantics still need focused calls. |

So the two halves are written differently on purpose. The Python sections carry file-and-line
citations and describe bugs down to the assignment that causes them. The `fm` sections tell you
what the tool *does*, tell you what third parties report typing — marked 🟠, never ✅ — and hand
you an exact procedure for finding out in ninety seconds on a real Mac.

If you take one instruction from this guide: **match scripts to the running OS's help surface.**
The canonical file `notes/sdk-interfaces/fm-help-27.0.txt` is a beta-5 capture, not a stable
contract. The canonical beta-versus-stable command comparison is [§3](#3--the-fm-help-surface-captured-on-macos-27);
stable macOS 27 advertises only `system`, so no current non-Swift PCC route is established.

---

## What this covers

- **The `fm` CLI** — what ships, the three subcommands anyone has named, the beta-era `fm chat`
  slash commands, `fm respond`'s options *as semantic concepts*, `fm serve`, historical PCC support,
  and a prominent, unhedged 🔴 GAP box listing exactly what is unknown and what resolves it.
- **The shell-automation pattern**, which *is* attested even though the flags are not: model output
  constrained to a schema, emitted as JSON on stdout, parsed by `jq`, driving real file operations.
  Plus the defensive scaffolding such a script needs, which the session did not show.
- **The Python SDK end to end** — the three-layer ctypes/C/Swift sandwich; installation and the
  preflight ladder that rejects Command Line Tools; `fm.SystemLanguageModel()` and the
  `(bool, reason)` tuple that replaces Swift's availability enum; `context_size` and `token_count`;
  `LanguageModelSession`; `respond()` and its five dispatch paths; streaming snapshots;
  `@fm.generable` and `fm.guide()`; the raw JSON-Schema path that consumes a schema exported from
  your Swift app; tools; image attachments.
- **The cross-language workflow** the session underplayed and the README states outright:
  **export a `Transcript` from your Swift app, analyse it in Python.** Round trip, resumption
  caveat, and the 350-line example Apple ships for it.
- **Memory management across the Python/Swift boundary** — a documented, measured hazard with a
  merged fix that is *not in any released version*, a file-descriptor exhaustion at ~240–250 image
  calls, and a way to "clean up" that crashes the interpreter.
- **The evaluation-pipeline pattern** from session 334 — pandas, matplotlib, a judge model, three
  prompt variants — and its genuinely counter-intuitive result.
- **Every known bug, in one place**, separated into "will throw" and "will not throw".

## What you need

- **For `fm`:** a Mac running macOS 27. That is the whole list, and it is also the thing this guide
  cannot substitute for.
- **For the Python SDK:** macOS 26.0+ on Apple silicon, **full Xcode 26.0+ installed and opened at
  least once** to accept the SDK agreement, `xcode-select` pointed at `Xcode.app`, Python 3.10–3.13
  (**not 3.14** — see §9.3), and Apple Intelligence turned on. `pip install` compiles Swift on your
  machine; budget for that.
- Familiarity with the Swift side. This guide is written as a translation layer and constantly says
  "the Swift equivalent is…". If `@Generable`, `@Guide`, `Instructions` and `Transcript` are new to
  you, read [`../../part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md`](../../part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md)
  and [`02-guided-generation-and-streaming.md`](../../part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md)
  first.

---

## Contents

1. [Why these two tools exist at all](#1-why-these-two-tools-exist-at-all)
2. [The `fm` CLI: everything that is actually attested](#2-the-fm-cli-everything-that-is-actually-attested)
3. [✅ The `fm` help surface, captured on macOS 27](#3--the-fm-help-surface-captured-on-macos-27)
4. [The shell-automation pattern (attested) with unverified flags (marked)](#4-the-shell-automation-pattern-attested-with-unverified-flags-marked)
5. [The Python SDK: what it is, and the version discrepancy](#5-the-python-sdk-what-it-is-and-the-version-discrepancy)
6. [Installing it, and why `pip install` compiles Swift](#6-installing-it-and-why-pip-install-compiles-swift)
7. [The model object: availability, context size, token counting](#7-the-model-object-availability-context-size-token-counting)
8. [Sessions, `respond()`, and streaming](#8-sessions-respond-and-streaming)
9. [Guided generation: `@fm.generable`, `fm.guide`, and raw JSON Schema](#9-guided-generation-fmgenerable-fmguide-and-raw-json-schema)
10. [Tools in Python](#10-tools-in-python)
11. [Image attachments](#11-image-attachments)
12. [The cross-language workflow: Swift transcripts into Python](#12-the-cross-language-workflow-swift-transcripts-into-python)
13. [⚠️ Memory across the boundary](#13-️-memory-across-the-boundary)
14. [What the Python SDK cannot do](#14-what-the-python-sdk-cannot-do)
15. [The evaluation pipeline (session 334's case study)](#15-the-evaluation-pipeline-session-334s-case-study)
16. [Failure-mode index](#16-failure-mode-index)
17. [Quick reference](#17-quick-reference)
18. [Sources, and how to close the gaps yourself](#18-sources-and-how-to-close-the-gaps-yourself)

---

## 1. Why these two tools exist at all

Until 2026, Apple's on-device language model had exactly one door: Swift. Apple's own framing is
blunt about it.

> ✅ **VERIFIED** — WWDC26 session 334, *Foundation Models on macOS*, Eric Gourlaouen of the
> Foundation Models Framework team (`transcripts/wwdc2026-334.txt:11-12`): *"…it's easy to set up,
> **with no API key needed and no cloud API costs**. But **until now, those models were only
> available from Swift code**."*

That single sentence is the thesis of both products. They are not new models, not new capabilities,
and not a new inference path. They are two new *doors* onto the same `SystemLanguageModel` that
`LanguageModelSession` reaches from Swift:

```
                    ┌──────────────────────────────┐
   Swift app  ─────►│                              │
                    │   SystemLanguageModel        │
   fm CLI     ─────►│   (the OS's on-device model) │
                    │                              │
   Python SDK ─────►│                              │
                    └──────────────────────────────┘
```

The consequences of "same model, different door" run through everything below. The model's context
window is the same 4,096 tokens on all three doors. Guardrails behave identically. A prompt that
trips a refusal in Swift trips it in Python. And — the one that catches people — **the on-device
model is part of the OS, not part of the SDK you built against**, so a Python program's behaviour
changes when the user updates macOS, exactly as a Swift app's does.

> ✅ **VERIFIED** — an Apple Designer's accepted answer on Developer Forums thread 831404, given
> about the Simulator but true of every non-Swift door too: *"Xcode 27.0 contains the latest SDK,
> but the on-device `SystemLanguageModel` is **actually built into the OS**."*

### Which door to use

| You want to… | Use | Why |
|---|---|---|
| Try a prompt in ten seconds, no project | `fm respond` | No build step at all. macOS 27 only. |
| Feel out the system model's behaviour conversationally | `fm chat` | Interactive. Beta sessions showed a model switch; stable macOS 27 advertises only `system`. |
| Glue a model into a shell script, cron job, Makefile | `fm respond` + a schema | Structured JSON on stdout. macOS 27 only. |
| Reach **Private Cloud Compute** from a non-Swift program | No stable macOS 27 CLI path is currently advertised | Beta-5 `fm` exposed PCC, but stable build `26A428` exposes only `system`. Use Swift's PCC surface or verify a later `fm --help` before designing around non-Swift PCC. |
| Batch-evaluate a Swift feature's prompts over a dataset | Python SDK | pandas, notebooks, no rebuild loop. |
| Analyse transcripts your shipping Swift app produced | Python SDK | §12. This is its stated purpose. |
| Ship a production Python service | **Neither** | Both are alpha/preinstalled developer tooling; the SDK's own classifier says `Development Status :: 3 - Alpha`. |

The last row deserves its emphasis. Apple's positioning of the Python SDK is explicit and narrow.

> ✅ **VERIFIED** — `docs/source/index.rst:13-16` in the repo: *"You can use this Python SDK to
> **evaluate** your Swift app's Foundation Models features … so you can be confident that your
> evaluations reflect real on-device performance and behavior."*

Not "build Python apps". *Evaluate Swift apps.* Everything odd about the SDK — the missing PCC
support, the text-only streaming, the absent feedback API — follows from that scope decision, and
none of it reads as an oversight once you accept the scope.

---

## 2. The `fm` CLI: everything that is actually attested

This section is short because the evidence is short. Every claim in it is traceable to spoken
narration in one of two WWDC26 sessions, or to one Apple engineer's comment on a GitHub issue.
Nothing here was read from a man page, a `--help` dump, or a screenshot.

### 2.1 It ships preinstalled with macOS 27

> ✅ **VERIFIED** (spoken, session 334, `334:15` and `334:35`): *"The `fm` command line tool **comes
> pre-installed with macOS 27**. It's a fantastic tool to **quickly test prompts, right from a
> terminal, or to incorporate it in automation**. It makes it really easy to test the model with
> some prompts **without rebuilding your project in Xcode**."* And: *"Starting from **macOS 27**,
> this command line tool comes pre-installed on your Mac. It's available right from your **Terminal
> app**."*

> ✅ **VERIFIED** (session 241, *What's new in Foundation Models*, `241:111-121`): *"In **macOS 27**,
> the models are coming to the command line. The `fm` CLI is a brand new way to use Apple Foundation
> Models for everyday productivity. You can access **the on-device model and PCC** from the terminal,
> just by using the `fm` command."*

Two independent sessions agree on the platform and the preinstalled status. Take those as solid.

> 🟠 **Suggestive, 2026-08-02 — the installed path is reported as `/usr/bin/fm`** (a 🔴 GAP until
> this date). Agarwal reports the binary as a **system binary at `/usr/bin/fm`** on macOS 27.0
> build `26A5378n`, needing no download or Xcode component.[^fm-agarwal] Crosley's independent
> write-up repeats that path but is derived from the WWDC transcript rather than a machine run, so
> it is secondary corroboration rather than a second real-machine observation.[^fm-crosley] The
> reported path is the **first** of the three guesses this box used to list and is consistent with
> the repo's own negative finding below.
> **Still 🔴:** whether the tool is present when Apple Intelligence is *disabled*. Neither source
> says, and it is the one third of the original gap that a `which fm` does not answer.
> **One elimination, checked 2026-07-29:** on a macOS 26.5.2 host with the Xcode 27.0 beta
> (27A5228h) installed, `xcrun --find fm` fails and no `fm` binary exists anywhere in
> `Xcode-beta.app` — so `fm` is **not an Xcode-27-beta toolchain tool**. That is consistent with
> Apple's claim that it ships with **macOS 27 itself** (which this host does not run; the
> preinstall claim remains untested by us until someone on this project checks on a 27.0 machine).
> **Safe default meanwhile:** in any script, test for the tool before using it —
> `command -v fm >/dev/null || { echo "fm not found (needs macOS 27)" >&2; exit 127; }`.

[^fm-agarwal]: Shobhit Agarwal, "Apple's Foundation Models CLI: Running Apple Intelligence From
    Your Terminal", 2026-07-16, `https://iamshobhitagarwal.medium.com/apples-foundation-models-cli-running-apple-intelligence-from-your-terminal-c0ee287c5eb2`.
    States the test platform as **macOS 27.0, build `26A5378n`**, and is the only source that
    pastes `fm --help`. Archived analysis: `notes/web/2026-08-02-harvest/fm-cli-real-machine-evidence.md`.

[^fm-crosley]: Blake Crosley, "Foundation Models from Python: the fm CLI", 2026-06-09,
    `https://blakecrosley.com/blog/foundation-models-python-fm-cli`. **Derived from the WWDC
    transcript, not from a machine** — it corroborates the path claim but is not independent
    evidence of having run the tool.

### 2.2 The subcommands anyone has named

> ✅ **VERIFIED** (spoken, `334:37-39`): running `fm` bare prints the list of available commands, and
> the three named on the way past are *"`respond`, to prompt the model and return a response;
> `chat`, to start an interactive interface; `schema`, to create a schema"* — followed by
> **"and more"**.

| Subcommand | What it does, in Apple's words | Evidence |
|---|---|---|
| `fm respond` | *"prompt the model and return a response"* | ✅ spoken, `334:39` |
| `fm chat` | *"start an interactive interface"* | ✅ spoken, `334:39` |
| `fm schema` | *"create a schema"* | ✅ spoken, `334:39` |
| `fm schema object` | *"Using the command `fm schema object`, I can create a schema"* | ✅ spoken, `334:53` |
| `fm serve` | serves the model *"as a Chat Completions endpoint"* | ✅ written, Apple member on GitHub — §2.6 |
| `fm available` | *"Check model availability"* | 🟠 third-party `--help` paste |
| `fm quota-usage` | *"Check model quota usage"* | 🟠 third-party `--help` paste |
| `fm token-count` | *"Count tokens in a…"* (the paste truncates mid-line) | 🟠 third-party `--help` paste |

**"And more" has a candidate answer as of 2026-08-02.**

> 🟠 **Suggestive, 2026-08-02 — the subcommand list is reported as seven** (a 🔴 GAP until this
> date). [Agarwal][^fm-agarwal] pastes the top-level help from macOS 27.0 build `26A5378n`:
>
> ```text
> % fm --help
>
> USAGE
>     % fm <command> [options]
>
> COMMANDS
>     available     Check model availability
>     chat          Start an interactive chat session
>     quota-usage   Check model quota usage
>     respond       Generate a response to a prompt
>     schema        Generate a structured output generation schema
>     serve         Start a Chat Completions API server
>     token-count   Count tokens in a…          ← the source page truncates here
> ```
>
> Three of the seven — `available`, `quota-usage`, `token-count` — were **never mentioned by
> Apple in any session**, and each maps cleanly onto a Swift API this series already documents
> (`SystemLanguageModel.Availability`, `QuotaUsage`, the five `tokenCount(for:)` overloads). That
> correspondence is corroborating structure, not proof.
>
> **Why this is 🟠 and not ✅:** it is one screenshot-equivalent from one stranger. Nobody on this
> project has run it. **And the paste is cut mid-line on `token-count`** — the list *looks*
> alphabetical and therefore complete at seven, but a subcommand sorting after `token-count`
> (`transcript`? `version`?) cannot be excluded.

`fm schema object` being a *sub*-subcommand of `fm schema` implies there are sibling schema kinds —
an array form, an enum form, something. That inference is mine and is **not** evidence. Do not write
`fm schema array` into a script because this paragraph made it sound plausible. (Note that the
`--help` paste above lists `schema` with no visible sub-structure, which neither confirms nor
refutes the sibling-kinds guess — top-level help would not show sub-subcommands anyway.)

### 2.3 `fm chat` and its two known slash commands

> ✅ **VERIFIED** (spoken, `334:43-45`): *"`fm chat` comes with a number of commands. For example,
> with **`/model`**, I can **switch the conversation to use the Private Cloud Compute model**. Or,
> with **`/save`**, I can **save the current conversation to resume later**."*

This is verified beta-era session behavior. Stable `fm chat` was not exercised interactively and
stable help advertises only `system`, so `/model` and `/save` remain unverified on that surface.

| Slash command | Effect | Evidence |
|---|---|---|
| `/model` | switch the live conversation to another model — PCC is the named example | ✅ beta-era session |
| `/save` | save the current conversation so it can be resumed | ✅ beta-era session |
| *(unknown)* | *"a number of commands"* — only two were demonstrated | 🔴 GAP |

Note what `/model` implies architecturally: **the transcript survives the model switch.** That is
the same mid-session backend swap that dynamic profiles perform in Swift, and it carries the same
warning — see [`../../part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md`](../../part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md).
Switching from PCC's larger window down to the on-device model with a long transcript in hand is
the classic way to walk into a context-window error, and `/save` implies conversations persist
somewhere on disk that you have not audited.

> ✅ **VERIFIED** (spoken, `334:46-47`): *"Interactive sessions with `fm chat` are great for
> **getting a first pulse of the model**. So if you're exploring a new idea, you can pry the model
> and see how it performs with your prompts."*

That is the honest use case: `fm chat` is for *forming a hypothesis*, not for measuring anything.
Measuring is Evaluations' job (Part 6) or the Python SDK's (§15).

### 2.4 `fm respond` and its options — semantic names only

> ✅ **VERIFIED** (spoken, `334:48-49`): *"When you'd rather have **inline responses, like in
> scripts**, use the command `fm respond` instead. Run `fm respond` with a prompt in a terminal, and
> you'll receive the response from the model as output."*

Four options were then described. **Every one of them was named semantically — "the model option",
"the image option" — and none was ever spelled out on screen or in the transcript.**

| Spoken as | Purpose (Apple's words) | Flag spelling |
|---|---|---|
| *"the **model** option"* | *"lets you prompt the Private Cloud Compute model"* (`334:50`) | 🟠 `--model pcc` |
| *"the **image** option"* | *"to include an image in your prompt"* (`334:51`) | 🟠 `--image <path>` |
| *"the **schema** option"* | use a schema built by `fm schema object` for structured output (`334:53`, `334:82`) | 🟠 `--schema <file>` |
| *"the **help** option"* | *"To check out all the options, use the help option"* (`334:55`) | 🟠 `--help` |
| *(instructions)* | *"passing my **instructions** and my prompt"* (`334:79`) — described as a thing passed, never as an option | 🔴 **UNKNOWN** — see below |

> 🟠 **Suggestive, 2026-08-02 — three spellings have two-source command evidence, and one has
> a single help artifact** (all five were 🔴 **UNKNOWN** until this date). Nuthalapati
> (English, macOS 27 developer beta)[^fm-nuthalapati] and Hack-Log (Japanese, macOS 27)[^fm-hacklog]
> independently demonstrate `--model`, `--image`, and `--schema` with values. Agarwal's pasted
> top-level help separately establishes the conventional `--help` spelling:
>
> ```bash
> fm respond "prompt text"
> fm respond "prompt" --schema schema.json
> fm respond "prompt" --model pcc
> fm respond "prompt" --image screenshot.png --model pcc
> ```
>
> **`--model` takes a value, and the attested value is `pcc`** — it is *not* the boolean switch
> this box previously allowed for. **`--image` takes a file path**; neither source demonstrates
> repeating it, so treat multi-image as unattested. **`--schema` takes a path to a JSON file**
> produced by `fm schema object` (§2.5).
>
> **`--instructions` stays 🔴.** Nuthalapati lists it as existing but **does not demonstrate it**,
> and no source shows whether it is an option, a second positional, or a file path. Do not write
> it into a script.
>
> **Why 🟠 and not ✅:** the three value-taking flags come from two blog posts, `--help` comes
> from one third-party paste, there is no first-party option reference, and nobody on this project
> ran the commands. Nuthalapati also flags the tool as beta software whose flags may change before
> release.

The conventional guesses were `--model`, `--image`, `--schema`, `--help`, `--instructions`, and
this guide's own research index records them in that form. **Four of the five spellings now have
positive evidence**, but only the first three have two-source command examples; `--help` has one
help artifact, and none of that is retroactive evidence for `--instructions`. One Apple-adjacent
data point is still worth showing precisely because of who said it:

[^fm-nuthalapati]: Varun Nuthalapati, "Local AI in Your Terminal: Scripting with Apple's New fm CLI
    and MLX", 2026-06, `https://nuthalapativarun.github.io/mlx-whisper-article/terminal-fm-mlx.html`
    (a non-paywalled GitHub Pages mirror of a Medium post). States "macOS 27 developer beta".

[^fm-hacklog]: Hack-Log, "Local AI becomes standard with the `fm` command in macOS 27", 2026-06-09,
    `https://note.com/hacklog_stealth/n/ne3c55b94af3f`. Japanese; the shell commands are
    reproduced verbatim in the archived analysis and are independent of [^fm-nuthalapati].

> 🟡 **Historical evidence note.** On `apple/python-apple-fm-sdk` issue #13, the *reporter* (not
> Apple) proposed
> `subprocess.check_output(["fm", "respond", query, "--model", "pcc"], text=True)`, and Apple did not
> answer that follow-up. The issue was not evidence by itself; the two independent command examples
> above are what now corroborate the spelling and value.

### 2.5 The beta default was on-device, and PCC was metered

> ✅ **VERIFIED** (spoken, `334:56-59`): *"the `fm` command line tool lets you use **either the
> on-device model, or the Apple Foundation Model on Private Cloud Compute**. **By default, it uses
> the on-device model that comes with macOS, and that's always available.** You can also use the
> Apple Foundation Model on Private Cloud Compute, **which has usage limits**. It's a much bigger
> model than the on-device model, so it will **perform better on complex problems**."*

This describes the beta-era CLI shown in the session. The default was local, while PCC was opt-in
and **quota-limited**. Stable macOS 27 no longer advertises the PCC model, so do not turn that
historical behavior into current automation. The quota API in Swift is coarse (see
[`../../part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md`](../../part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md)).
The session's claim that PCC is *better at hard problems* is a quality argument, not a latency one.

### 2.6 `fm serve` — the one written sentence, and why it matters most

This is the highest-grade evidence about `fm` in the entire corpus, and it did not come from a WWDC
session. It came from an Apple engineer closing a GitHub issue.

> ✅ **VERIFIED — written, by an Apple member.** `apple/python-apple-fm-sdk` issue #13, *"Plans for
> Server models?"*, closed 2026-07-12. Reply from **@rxwei (MEMBER)**, verbatim:
>
> *"Hi @Cactys12, we do not currently plan to add support for Private Cloud Compute in this Python
> SDK. You can access Private Cloud Compute via the `fm` CLI in macOS Golden Gate, and **`fm serve`
> lets you serve it easily as a Chat Completions endpoint**."*

Four separate facts fall out of one sentence:

1. **`fm serve` exists** — none of the sessions mention it.
   **Independently corroborated 2026-08-02:** it appears in the `fm --help` paste in §2.2 as
   `serve   Start a Chat Completions API server`, which matches @rxwei's description almost word
   for word. See the box below for a source that disputes this.
2. It exposes an **OpenAI-compatible Chat Completions endpoint**. That is a very large deal: any
   Chat Completions client — the `openai` Python package, LangChain, a `curl` one-liner, your own
   HTTP code — can in principle talk to Apple's models through it. It is also the exact protocol
   that Foundation Models' own `ChatCompletionsLanguageModel` speaks in the other direction
   (Part 4), so the ecosystem closes a loop here.
3. **PCC was reachable through it on the beta-era surface described by the Apple member.** Stable
   macOS 27 advertises only `system`, so this is historical evidence, not a current Python route.
4. **PCC in the Python SDK is not a "not yet" — it is a "not planned."** "We do not currently plan
   to add support" is as clear as Apple gets. Do not architect around it arriving.

> 🔴 **GAP — everything else about `fm serve`.** Port, bind address, authentication (if any), which
> Chat Completions fields are honoured (`temperature`? `tools`? `response_format`? streaming via
> SSE?), how the model is selected per-request versus per-process, whether it daemonises, and what
> happens when the PCC quota runs out mid-request. **All unknown, and unchanged by the 2026-08-02
> harvest** — the third-party sources that corroborate the subcommand's *existence* attest none of
> its behaviour. Resolving this needs `fm serve --help` and one `curl` against a running instance
> on macOS 27.
>
> **Safe default meanwhile:** if you need a serving endpoint *today* from Python, use `mlx_lm.server`
> or another local OpenAI-compatible server (Part 12), and keep the client code protocol-generic so
> that pointing it at `fm serve` later is a base-URL change.
>
> ⚠️ **One source claims `fm serve` does not exist. It is wrong, and the way it is wrong is
> instructive.** A community write-up[^fm-chatforest] prints a self-correction retracting its own
> earlier `fm serve` claim, and argues the subcommand does not exist on the grounds that *"That
> claim does not appear in Apple's own WWDC26 session"*.
>
> **That is an argument from absence in a transcript, which proves nothing** — it is the same
> reasoning this series refuses everywhere else (absence from a beta SDK means "not present in that
> interface", never "does not exist"). Against it stand two positive artefacts: an Apple engineer
> naming the subcommand in writing (above), and a `--help` paste from a named macOS 27.0 build
> (§2.2). The post has also already been wrong once on this exact point, by its own admission.
>
> **Treat `fm serve` as existing.** Keep the 🔴 above for everything about *how* it behaves.

[^fm-chatforest]: ChatForest builders-log,
    `https://chatforest.com/builders-log/apple-fm-cli-python-sdk-fm-serve-openai-compatible-psotu-wwdc-2026/`.
    Logged as an unreliable source in `notes/web/2026-08-02-harvest/gap-closures-and-corrections.md`
    §8. Its Python-SDK claims may still be usable but are outranked by the cloned repository read
    in §5 onward.

One incidental find in that quote: **"macOS Golden Gate"** is Apple's internal codename for the
macOS release that ships `fm`. It corresponds to macOS 27. You will occasionally see it in Apple
staff replies; it is not a separate product.

### 2.7 What `fm` is *for*, in Apple's framing

> ✅ **VERIFIED** (spoken, `241:119-121`): *"I can even **plug `fm` into shell scripts to summarize
> documents, extract information, or generate content.** For example, I have some pictures with
> random names like this one, `IMG_1234`. Let me just ask `fm` to **generate a file name based on the
> content inside the image**."*

That is a nice, small, honest example — and it independently confirms the image option, since a
filename cannot be generated from an image the tool never received. §4 builds the larger automation
case study.

---

## 3. ✅ The `fm` help surface, captured on macOS 27

> ⚠️ **STABLE DRIFT, verified 2026-09-16.** The capture below remains valuable beta evidence, but
> stable macOS 27 build `26A428` has **seven**, not eight, top-level commands: `available`, `chat`,
> `count-tokens`, `license`, `respond`, `schema`, and `serve`. Stable help removed
> `quota-usage`, advertises only the `system` model, and no longer accepts the beta-documented
> `--model pcc` choice. Do not copy beta PCC commands into stable automation. This describes the
> public CLI surface only; it does not claim the Foundation Models PCC API was removed.

> ✅ **RESOLVED 2026-08-17 on macOS 27 beta 5 (`26A5406e`).** `/usr/bin/fm` was run by this
> project. `fm --help` plus every revealed help page is captured in
> `notes/sdk-interfaces/fm-help-27.0.txt` under the SDK evidence manifest. The eight top-level
> commands are `available`, `chat`, `count-tokens`, `license`, `quota-usage`, `respond`, `schema`,
> and `serve`. The earlier third-party `token-count` spelling is wrong for this seed.
>
> The capture also resolves the flag and schema grammar: `respond` supports instructions, model,
> schema, text/image/label attachments, built-in OCR/barcode tools, transcript resume/save,
> streaming control, greedy sampling, verbose output, use cases, and guardrail levels;
> `schema object` supports boolean/double/integer/string properties, nested objects, `anyOf`,
> arrays, descriptions, and optionality; and `serve` exposes `/health`, `/v1/models`, and
> `/v1/chat/completions` over TCP or a Unix socket. `fm --version` is not supported.

The historical gap analysis below is retained to show which claims were previously third-party,
but its command-spelling questions are superseded by the managed beta-5 capture.

This box is the most important thing in the first half of this guide. It is deliberately not
softened, and it deliberately contains no guesses.

> ✅ **HISTORICAL GAP — closed 2026-08-17 by the beta-5 capture above.**
>
> **This box was written when the corpus had only Apple's narration. On 2026-08-02 three
> third-party write-ups by people who did run it were found, and items 1–3 below are now
> substantially narrowed (🟠, see §2.1–2.4). The headline sentence is unchanged and remains the
> point: reported-by-strangers is not run-by-us, and the residue below is still real.**
>
> **What we have:** spoken narration from two WWDC26 sessions, in which the presenter names four
> options *semantically* ("the model option", "the image option", "the schema option", "the help
> option"), names three subcommands plus "and more", and demonstrates two `fm chat` slash commands
> out of "a number of commands". Plus one written sentence from an Apple engineer establishing that
> `fm serve` exists and speaks Chat Completions. Plus, since 2026-08-02, one `fm --help` paste from
> macOS 27.0 build `26A5378n` and two independent sets of worked `fm respond` invocations.
>
> **What we do not have, and will not invent:**
>
> 1. **~~The full subcommand list.~~** 🟠 **Narrowed 2026-08-02** — reported as seven
>    (`available`, `chat`, `quota-usage`, `respond`, `schema`, `serve`, `token-count`; §2.2).
>    **Residue:** the paste is truncated mid-line on `token-count`, so a subcommand sorting after
>    it cannot be excluded, and no sub-subcommand list exists for any of the seven.
> 2. **~~Any flag spelling.~~** 🟠 **Narrowed 2026-08-02** — `--model pcc`, `--image <path>`,
>    `--schema <file>`, `--help` (§2.4). **Residue:** `--instructions` is still 🔴 unattested;
>    no short forms are known; whether `--image` repeats for multiple images is unknown; and no
>    source shows the flag set for any subcommand other than `respond`.
> 3. **`fm schema object`'s argument grammar.** Still the biggest single hole, but 🟠 **narrowed
>    2026-08-02**. Two independent sources show the same shape — a **flag-per-property builder**,
>    not a DSL, with output redirected to a file:
>
>    ```bash
>    fm schema object --name AppsIdentified --string app_names --array > schema.json
>    fm schema object --name ActionItems   --string items      --array > schema.json
>    fm respond "…" --image Screenshot.png --model pcc --schema schema.json
>    ```
>
>    So: `--name <TypeName>`, then `--<type> <propertyName>`, with `--array` modifying the property
>    immediately before it; **the schema goes to stdout** (both examples redirect it), and
>    `fm respond --schema` takes the resulting *file path*. That answers "JSON on stdout vs. a file
>    vs. a handle" — it is JSON on stdout.
>    **Residue, all still 🔴:** only `--string` is attested — `--int`/`--float`/`--bool` are
>    presumed by symmetry and are **not** evidence; nesting, optionality, descriptions, and any
>    constraint syntax (an `.anyOf` equivalent, a numeric range) are entirely unknown; and neither
>    source builds the two-field schema the session narrates, so multi-property ordering is
>    inferred from the flag order alone.
> 4. **`fm chat` slash commands beyond `/model` and `/save`.** Presumably `/load` or similar exists
>    to complement `/save`, and presumably there is a `/quit` and a `/help`. **Presumably is not
>    evidence and none of those are written into this guide.**
>
>    ⚠️ **A contamination hazard worth naming.** `manjunathshiva/fmx` is a third-party **macOS 26**
>    CLI that deliberately imitates the not-yet-shipped `fm`, and its README says it "will
>    eventually defer to the native `fm` command coming in macOS 27". It documents a full slash-command
>    set (`/help`, `/save <path>`, `/load <path>`, `/clear`, `/system <text>`, `/model`, `/exit`)
>    and flags (`-i`, `--stream`, repeatable `--image`, `-t`, `--max-tokens`). **That is `fmx`'s own
>    design, not Apple's.** Because `/save` and `/model` appear in both, it is easy to absorb the
>    whole set as attested `fm` surface. It is not. Its README explicitly does not document Apple's
>    grammar.
> 5. **Everything about serving.** Port, auth, protocol coverage, lifecycle. See §2.6.
> 6. **Exit codes, stdout/stderr discipline, and streaming behaviour.** Whether `fm respond` streams
>    tokens to a TTY, whether it buffers when piped, what exit code a guardrail refusal produces, and
>    whether errors land on stderr — all unknown, and all load-bearing for scripting.
> 7. **Whether `fm` is affected by the Apple Intelligence enablement gate**, including the
>    Siri-enablement defect Apple has acknowledged (Part 1).
>
> **What would resolve it:** a Mac running macOS 27 and roughly ninety seconds:
>
> ```bash
> fm --help
> fm respond --help
> fm chat --help
> fm schema --help
> fm schema object --help
> fm serve --help
> which fm && fm --version
> ```
>
> That is the entire remediation. There is no substitute for it — not the documentation (no `fm`
> documentation page exists in this corpus), not the session (it showed the screen and described it
> in prose), not the forums.
>
> **Status check, 2026-07-29:** the shortcut everyone hopes for — that `fm` might ride along with
> the Xcode 27 beta on a macOS 26 machine — is now **eliminated**. On a macOS 26.5.2 host with
> Xcode 27.0 beta (27A5228h) installed, `xcrun --find fm` fails and an exhaustive search of
> `Xcode-beta.app` finds no `fm` binary. `fm` is not part of the Xcode 27.0 beta toolchain;
> per Apple's sessions it ships with **macOS 27 itself**, so the ninety-second run above genuinely
> requires a machine on the OS beta. Every flag table in §2 keeps its attested-only status.
>
> **Safe default until then:** treat `fm` as an *interactive exploration tool* and keep it out of
> automation you cannot babysit. If you must automate now, write the wrapper described in §4.3 —
> one function, one place to fix when you learn the real flags — and pin the behaviour with a smoke
> test that runs before the rest of the script.

### 3.1 Why this gap is worse than it looks

A missing flag name in a guide is normally a small thing; you look it up. Two properties of this
particular situation make it worth a full section.

**Plausible-looking CLI flags are the easiest thing in the world to hallucinate.** `--model`,
`--image`, `--schema`, `--temperature`, `--max-tokens`, `--json`, `--system` — every one of those
reads as obviously correct, six of them were never mentioned by anyone, and a coding assistant asked
to "write an fm script" will emit them without hesitation. An earlier batch of guides in this series
was audited against Apple's real sample code and the audit found a **completely fabricated code
listing** that had looked entirely plausible. CLI flags are that failure mode's natural habitat.

**A wrong flag may not fail loudly.** Many argument parsers treat an unrecognised trailing token as a
positional argument. If `--schema` is really `--response-schema`, a command like
`fm respond --schema "$SCHEMA" "$FILES"` might not error — it might quietly send the *schema text
itself* to the model as part of the prompt and return unconstrained prose, which your `jq` then
fails to parse, thirty lines later, with a message about the wrong thing. Which brings us to the
callout that governs the entire automation pattern.

> ⚠️ **SILENT FAILURE — a shell pipeline cannot tell "the model declined" from "the model answered
> in prose".** `fm respond` writes to stdout. If a schema is not applied — wrong flag, malformed
> schema, an OS that silently ignored it — you still get *text on stdout and an exit status you have
> not checked*. `jq` then either errors on the next line (best case, and it names the wrong culprit)
> or, worse, succeeds against something structurally valid but semantically empty. **Every script in
> §4 therefore validates the JSON's shape before acting on it, not just its parseability.** This is
> the shell equivalent of the framework-level lesson from
> [`../../part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md`](../../part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md):
> structured output that is not enforced degrades to prose, silently.

---

## 4. The shell-automation pattern (attested) with unverified flags (marked)

The *pattern* is well attested even though the flags are not, and the pattern is the part worth
learning. Apple built a real case study around it.

### 4.1 The case study, as narrated

> ✅ **VERIFIED** (spoken, `334:66-67`): the scenario is an asset folder full of drafts and finals
> with messy names. *"Using `fm` here lets me call into a language model that can **sort draft versus
> final files in my script. So that the script works even if the names are messy and are difficult to
> sort predictably.**"*

That sentence is the whole argument for putting a language model in a shell script. Not "the model
writes my script" — **the model does the one step that resists being written as a rule.** `ls | grep`
handles `v2_final.psd`; it does not handle `logo (use this one).psd`, `logo_FINAL_ACTUAL.psd` and
`logo_final_old.psd` in the same directory. The deterministic parts of the job stay deterministic;
exactly one fuzzy classification is delegated.

The narrated structure, step by step (`334:77-84`):

1. Load a list of the files in the working directory.
2. **Define a schema further up in the script** with `fm schema object` — *"The structured output
   will have **two fields, a list of final files, and a list of draft files**."*
3. Prompt with `fm respond`, *"passing my **instructions** and my **prompt**"*, plus the schema
   option.
4. *"**The output of `fm respond` contains a result in a JSON that's generated by the model.**"*
5. Use the JSON to copy the final files to a backup and move the drafts to an archive.

Step 4 is the load-bearing one: **structured output arrives on stdout as JSON**, which is what makes
the whole thing composable with `jq` and every other Unix tool.

### 4.2 The shape of such a script

Here is that script written out. **Read the banner.** Every `fm` invocation in it is marked, and the
scaffolding around them — validation, dry-run, error handling — is mine, not Apple's; the session
showed none of it and a real script needs all of it.

```bash
#!/bin/zsh
# ---------------------------------------------------------------------------
# 🟡 RECONSTRUCTED SHAPE / 🔴 UNVERIFIED FLAGS.
#
# The PATTERN below (schema -> constrained respond -> JSON on stdout -> jq ->
# file operations) is ✅ VERIFIED from WWDC26 session 334, 334:77-84.
#
# The FLAG SPELLINGS are NOT. `fm schema object`'s argument grammar was never
# shown; `--schema`, `--instructions` and `--model` are conventional guesses.
# Run `fm respond --help` and `fm schema object --help` on macOS 27 and fix
# the two wrapper functions at the top. Nothing below them needs to change.
# ---------------------------------------------------------------------------
set -euo pipefail

WORKDIR="${1:?usage: sort-assets <dir>}"
BACKUP="$HOME/Backups/assets"
ARCHIVE="/Volumes/Archive/assets"
DRY_RUN="${DRY_RUN:-1}"          # default to dry-run; set DRY_RUN=0 to act

# --- the only two places that know fm's actual command line ----------------

fm_build_schema() {
  # 🔴 UNVERIFIED GRAMMAR. Expected to emit a schema (JSON? handle?) on stdout.
  fm schema object \
    finalFiles:"[string]" \
    draftFiles:"[string]"
}

fm_classify() {
  local schema="$1" file_list="$2"
  # 🔴 UNVERIFIED FLAGS.
  fm respond \
    --instructions "Sort the given file names into final versions and draft versions. Every input file name must appear in exactly one of the two output lists." \
    --schema "$schema" \
    "$file_list"
}

# --- everything below here is ordinary, verifiable shell -------------------

command -v fm >/dev/null || { print -u2 "fm not found — needs macOS 27"; exit 127; }
command -v jq >/dev/null || { print -u2 "jq not found"; exit 127; }
[[ -d "$WORKDIR" ]] || { print -u2 "no such directory: $WORKDIR"; exit 2; }

FILES=$(ls -1 "$WORKDIR")
[[ -n "$FILES" ]] || { print "nothing to do"; exit 0; }
INPUT_COUNT=$(print -r -- "$FILES" | wc -l | tr -d ' ')

SCHEMA=$(fm_build_schema)
RESULT=$(fm_classify "$SCHEMA" "$FILES")

# --- validate BEFORE touching a single file --------------------------------
# See the SILENT FAILURE callout in §3.1: unconstrained prose can arrive here
# with exit status 0, and "it parsed" is not the same as "it is the right shape".

print -r -- "$RESULT" | jq -e . >/dev/null 2>&1 \
  || { print -u2 "fm did not return JSON. Raw output follows:"; print -u2 -- "$RESULT"; exit 3; }

print -r -- "$RESULT" | jq -e 'has("finalFiles") and has("draftFiles")
                               and (.finalFiles | type == "array")
                               and (.draftFiles | type == "array")' >/dev/null \
  || { print -u2 "JSON did not match the expected schema shape:"; print -u2 -- "$RESULT"; exit 4; }

OUT_COUNT=$(print -r -- "$RESULT" | jq '(.finalFiles | length) + (.draftFiles | length)')
if (( OUT_COUNT != INPUT_COUNT )); then
  print -u2 "model accounted for $OUT_COUNT of $INPUT_COUNT files — refusing to act"
  exit 5
fi

# --- act -------------------------------------------------------------------
mkdir -p "$BACKUP" "$ARCHIVE"

print -r -- "$RESULT" | jq -r '.finalFiles[]' | while IFS= read -r f; do
  [[ -e "$WORKDIR/$f" ]] || { print -u2 "hallucinated file name, skipping: $f"; continue; }
  if (( DRY_RUN )); then print "cp $f -> $BACKUP"; else cp -- "$WORKDIR/$f" "$BACKUP/"; fi
done

print -r -- "$RESULT" | jq -r '.draftFiles[]' | while IFS= read -r f; do
  [[ -e "$WORKDIR/$f" ]] || { print -u2 "hallucinated file name, skipping: $f"; continue; }
  if (( DRY_RUN )); then print "mv $f -> $ARCHIVE"; else mv -- "$WORKDIR/$f" "$ARCHIVE/"; fi
done
```

### 4.3 The four rules that survive whatever the real flags turn out to be

**1. Put every `fm` invocation behind a function.** Two functions in the script above know what
`fm`'s command line looks like. When you run `fm respond --help` and discover the truth, you edit
two functions and the other sixty lines are untouched. This is not a style preference; it is the
only way to write `fm` automation responsibly given §3.

**2. Validate shape, not just parseability.** `jq -e .` proves you got JSON. It does not prove you
got *your* JSON. The two checks in the script — required keys with the right types, then a count
reconciliation — are what convert a silent failure into a loud one. The count check is the sharper
of the two: a model that drops three files from a list of forty produces perfectly valid JSON.

**3. Never trust a model-emitted string as a filesystem path.** Every loop above re-checks
`[[ -e ... ]]` before acting. The model is echoing names back to you and it can misspell one, invent
one, or normalise Unicode. `mv -- "$f"` with a hallucinated `$f` is at best a no-op and at worst
something you have to explain. The `--` is there for names beginning with a dash.

**4. Dry-run by default.** `DRY_RUN=${DRY_RUN:-1}`. The first execution of a model-driven file
mover should print what it would do. This costs one line and it is the difference between a bad
classification being a chuckle and being a restore-from-backup.

### 4.4 When *not* to reach for `fm`

`fm` starts a process, loads or contacts a model, and produces non-deterministic output. That is a
poor fit for a surprising number of things people reach for it for:

| Task | Better tool | Why |
|---|---|---|
| Extracting a field from well-formed JSON/XML | `jq` / `xmllint` | Deterministic, instant, free. |
| Matching a fixed set of filename patterns | `case` / `grep -E` | If a regex can express it, a regex should. |
| Anything inside a tight loop over thousands of items | The Python SDK, or a real batch runner | Per-invocation process startup plus model load, N times. |
| Anything that must be reproducible across machines | Neither, without pinning | The model is part of the OS and changes with it. |
| Anything where a wrong answer is expensive and unreviewed | Neither | Add a human, or add a deterministic verifier like the count check above. |

The honest niche is exactly Apple's example: **one fuzzy step, in a script that is otherwise
deterministic, whose output you can cheaply verify.**

### 4.5 The reproducibility problem, and the one mitigation

The on-device model ships with the OS. macOS 26.4 shipped a model refresh that Apple describes as
improving instruction-following and tool-calling. A script that classified forty files correctly in
May may classify thirty-eight correctly after a point release, with no change to your code and no
notification. There is no model-version pinning API anywhere in the stack.

> ✅ **VERIFIED** — Apple staff on Developer Forums thread 833642 confirm there is **no model version
> pinning and no version-retrieval API**.

The mitigation is the same one Part 6 argues for at length: **keep a small golden set and a check
script.** Ten inputs whose correct classification you know, run through the same pipeline, compared
against expected output. Run it after every OS update. It takes a minute to write and it is the only
early warning available. That is also the natural bridge into the Python half of this guide, because
once your golden set has more than a dozen rows you want a DataFrame, not a shell loop.

---

## 5. The Python SDK: what it is, and the version discrepancy

From here on the evidence grade changes completely. Everything below was read from
`github.com/apple/python-apple-fm-sdk` at commit `e868e60` — the repository's HEAD as of
2026-07-27 — cloned to disk and read file by file, plus its complete GitHub issue and PR history.
Line numbers refer to that commit.

### 5.1 It is not a Python implementation of anything

> ✅ **VERIFIED** — repository structure, read on disk. The package is a **three-layer sandwich**:
>
> ```
> Python   src/apple_fm_sdk/*.py            pure Python + ctypes, 15 modules
>    │
>    │  ctypes, via a ctypesgen-generated module `_ctypes_bindings.py`
>    │  (NOT in git — generated at build time from the C header)
>    ▼
> C ABI    foundation-models-c/Sources/FoundationModelsCBindings/include/FoundationModels.h
>    │      146 lines, 9 opaque pointer types, 3 callback typedefs, ~40 functions
>    │  @_cdecl Swift functions
>    ▼
> Swift    foundation-models-c/Sources/FoundationModelsCBindings/FoundationModelsCBindings.swift
>          1,831 lines  →  import FoundationModels   (the real Apple framework)
> ```

There is no reimplementation, no reverse-engineered protocol, and no separate model. Your Python
call reaches the same `LanguageModelSession` a Swift app would, through a hand-written C shim. That
is why the behaviour is identical to Swift's, why the failure modes are pointer-shaped rather than
Pythonic, and why installing it needs a Swift compiler.

Package facts, all ✅ verified from the repo:

| | |
|---|---|
| Install | `pip install apple-fm-sdk` |
| Import | `import apple_fm_sdk as fm` |
| Version at HEAD | `0.2.1` (`pyproject.toml:8`) |
| License | Apache-2.0; every file carries `Copyright (C) 2026 Apple Inc.` |
| Maturity classifier | `Development Status :: 3 - Alpha` (`pyproject.toml:17`) |
| Runtime dependencies | `build`, `setuptools>=75.3.2`. **No numpy, no pydantic.** Everything else is stdlib. |
| Docs | `https://apple.github.io/python-apple-fm-sdk/` (Sphinx, published from `docs/`) |
| Repo history | **10 commits total**, first on 2026-02-25 |
| Contributions | README: **"This project is not yet taking contributions. Stay tuned!"** |

That last line deserves a note, because it is stale in a useful direction:

> ✅ **VERIFIED** — the README says contributions are not being taken, yet
> **`apple/python-apple-fm-sdk` PRs #7 through #18 were
> merged**, several from non-Apple contributors. The FD-leak fix in §13 came from an outside
> contributor. So: file issues, and a well-argued PR may well land — but do not build a plan around
> a feature you intend to contribute, and read the "alpha" classifier as sincere.

> ⚠️ **`apple_fm_sdk.__version__` lies.** ✅ Verified: `pyproject.toml:8` says `0.2.1`,
> `src/apple_fm_sdk/__init__.py:62` says `__version__ = "0.1.0"`, and `docs/source/conf.py:21` says
> `release = "1.0.0"`. Three different strings. **Use
> `importlib.metadata.version("apple-fm-sdk")`.** Any capability check keyed on `fm.__version__`
> silently tests a constant that has not moved since March.

### 5.2 ⚠️ The version discrepancy: this is a 26-generation SDK

This is the fact that decides whether the SDK is useful to you, and it is easy to miss because two
sources describe the same product at two different points in its life.

> ✅ **VERIFIED — the repository's own requirements** (`README.md:25-30`, and identically
> `docs/source/index.rst:23-30`):
>
> ```
> ## Requirements
>
> - macOS 26.0+
> - Download Xcode 26.0+ and agree to the Xcode and Apple SDKs agreement in the Xcode app.
> - Python 3.10+
> - Apple Intelligence turned on for a compatible Mac
> ```
>
> And the Swift package's own floor (`foundation-models-c/Package.swift:13`):
>
> ```swift
> platforms: [.macOS(.v26), .iOS(.v26), .visionOS(.v26)],
> ```

> ✅ **VERIFIED — how WWDC26 session 334 describes it** (`334:88-90`): *"You can install it on a
> Python environment on your Mac, provided that: the **Python version is at least Python 3.10**,
> that you have **Xcode installed**, and that you're using an **Apple Silicon Mac**. It's installed
> through **pip**, or any other package manager of your choice."*

Session 334 is a WWDC26 session about macOS 27, and it presents the `fm` CLI and the Python SDK
side by side as this year's news. **For the CLI that is accurate. For the SDK it is not.**

| Claim | Session 334 | Repository | Ruling |
|---|---|---|---|
| Python version | "at least Python 3.10" | `Python 3.10+` | ✅ agree |
| Xcode | "you have Xcode installed" | **Xcode 26.0+**, *and* you must open it once to accept the SDK agreement | **Repo is stricter.** The agreement step is a real footgun the session omits — §6.2. |
| Hardware | "Apple Silicon Mac" | "Apple Intelligence turned on for a compatible Mac" | Compatible; the repo adds the enablement requirement. |
| **OS** | *(the session is about macOS 27 throughout)* | **macOS 26.0+** | ⚠️ **Discrepancy.** The SDK runs on macOS 26. The `fm` CLI does not exist there. |

**Precedence rule applied:** the repository is shipping source read on disk; the session is spoken
narration. Per this series' evidence ladder, **the repository wins**, and the practical consequence
is bigger than "you can install it on an older Mac":

> ⚠️ **The Python SDK does not expose any of the 27-era Foundation Models surface.** Verified by
> reading `src/apple_fm_sdk/__init__.py`'s complete 41-name `__all__` and the entire 146-line C
> header. **Absent:**
>
> - **`PrivateCloudComputeLanguageModel`** — and this one is not an oversight; an Apple member
>   states there is no plan to add it (§2.6, issue #13). Beta-era `fm` exposed PCC, but stable
>   macOS 27 does not; use Swift's PCC surface unless a later CLI advertises the model again.
> - **The `LanguageModel` / `LanguageModelExecutor` protocol pair**, and therefore
>   `CoreAILanguageModel`, `MLXLanguageModel`, `ChatCompletionsLanguageModel`. There is exactly one
>   model type in Python: `SystemLanguageModel`.
> - **Dynamic profiles**, `DynamicProfileModifier`, `onPrompt` / `onToolCall` / `historyTransform`,
>   `summarizeHistory`.
> - **Mutable `session.transcript` and `transcript.history`** — the iOS 27 context-compaction
>   idiom. Python transcripts are opaque dicts.
> - **`toolCallingMode`** in any form.
> - **`session.prewarm()`**, adapters, and `LanguageModelFeedback` / `logFeedbackAttachment`.
>
> What it *does* have from the 27 generation is **image attachments**, added for WWDC26 in `v0.2.0`
> — and those are conditionally compiled, which is §6.4's problem.

So the accurate one-line summary is: **`apple-fm-sdk` is a well-built, narrow, 26-generation
binding to `SystemLanguageModel`, with 27-era image support bolted on, aimed at evaluating Swift
apps.** If your Swift app uses dynamic profiles, PCC or a BYO model, the Python SDK **cannot
reproduce the thing you are trying to evaluate**, and you should evaluate in Swift with the
Evaluations framework (Part 6) instead. If your feature is a prompt plus a `@Generable` type
against the on-device model, the Python SDK reproduces it faithfully — down to the schema, which
§9.7 shows you can hand across verbatim.

### 5.3 The complete public surface

> ✅ **VERIFIED — verbatim `__all__` from `src/apple_fm_sdk/__init__.py`** (41 names):
>
> ```python
> __all__ = [
>     "SystemLanguageModel", "LanguageModelSession",
>     "Attachment", "ImageAttachment", "PromptComponent", "Prompt",
>     "PromptError", "ImagePromptError",
>     "Transcript",
>     "SystemLanguageModelUseCase", "SystemLanguageModelGuardrails",
>     "SystemLanguageModelUnavailableReason",
>     "Tool",
>     "FoundationModelsError", "GenerationError", "ExceededContextWindowSizeError",
>     "AssetsUnavailableError", "GuardrailViolationError", "UnsupportedGuideError",
>     "UnsupportedLanguageOrLocaleError", "InvalidGenerationSchemaError",
>     "DecodingFailureError", "RateLimitedError", "ConcurrentRequestsError",
>     "RefusalError", "ToolCallError", "GenerationErrorCode",
>     "generable", "guide",
>     "GenerationSchema", "GeneratedContent",
>     "GenerationGuide", "GuideType",
>     "GenerationOptions", "SamplingMode", "SamplingModeType",
>     "GenerationID", "ConvertibleFromGeneratedContent", "ConvertibleToGeneratedContent",
>     "Generable",
> ]
> ```

That is the whole API. If a name is not in that list it is not public, and two names people reach
for are conspicuously absent: `Property` (documented in a docstring as
`from apple_fm_sdk import Property`, but **not exported** — ✅ verified) and any notion of a
`Response` wrapper.

### 5.4 The Swift → Python translation table

Keep this next to you; it is the fastest way to read the rest of the guide if Swift is your home
language.

| Swift | Python | Note |
|---|---|---|
| `SystemLanguageModel.default` | `fm.SystemLanguageModel()` | A **constructor**, not a static. |
| `model.availability` → enum | `model.is_available()` → **`(bool, reason)` tuple** | §7.1. Flatter, and it changes your control flow. |
| `model.contextSize` | `model.context_size` | Sync property. |
| `try await model.tokenCount(for:)` | `await model.token_count(...)` | **macOS 26.4+.** §7.3. |
| `LanguageModelSession(instructions:)` | `fm.LanguageModelSession("…")` | Instructions is the **first positional** arg. |
| `LanguageModelSession(transcript:)` | `fm.LanguageModelSession.from_transcript(t)` | Sync classmethod. §12. |
| `try await session.respond(to:)` | `await session.respond(prompt)` | Returns a bare `str`, not a `Response`. |
| `try await session.respond(to:generating:)` | `await session.respond(prompt, generating=Cat)` | §9. |
| `session.streamResponse(to:)` | `session.stream_response(prompt)` | **Text only.** §8.5. |
| `@Generable struct Cat { }` | `@fm.generable` on a **class** with annotated fields | §9.1. |
| `@Guide(description:, .range(0...20))` | `age: int = fm.guide("…", range=(0, 20))` | A **default value**, not a decorator. §9.2. |
| `GenerationOptions(sampling: .greedy)` | `fm.GenerationOptions(sampling=fm.SamplingMode.greedy())` | §8.6 — and read the random-sampling bug. |
| `struct MyTool: Tool` | `class MyTool(fm.Tool)` with class attrs + `async def call` | §10. |
| `Attachment(imageURL:).label(_:)` | `fm.ImageAttachment(path=Path(...), label="…")` | §11. |
| `session.transcript` | `await session.transcript.to_dict()` → `dict` | Opaque dict; no entry model. §12. |
| `session.prewarm()` | — | **Not exposed.** |
| `SystemLanguageModel(adapter:)` | — | **Not exposed.** |
| `PrivateCloudComputeLanguageModel()` | — | **Not planned.** §2.6. |

Two structural differences are worth internalising before you write anything:

**Everything is `async`.** `respond`, `stream_response`, `token_count`, `Transcript.to_dict` and
`Transcript.from_dict` are all coroutines. The last two await nothing internally — ✅ verified,
they are synchronous native calls wearing an `async def` — but you must still `await` them. The
single most common new-user error, and the subject of the repo's issue #2, is calling `respond`
without `await` and printing a coroutine object.

**There is no `Response` wrapper.** Swift's `Response<Content>` carries `.content`, `.rawContent`
and `.transcriptEntries`. Python hands you the bare value. If you want the entries, re-read
`session.transcript` afterwards.

---

## 6. Installing it, and why `pip install` compiles Swift

`pip install apple-fm-sdk` does not download a wheel and unpack it. It downloads a source
distribution and **builds a Swift package on your machine**. Understanding that turns three
confusing error messages into obvious ones.

### 6.1 The custom build backend

> ✅ **VERIFIED** — `pyproject.toml:1-4`:
>
> ```toml
> [build-system]
> requires = ["setuptools"]
> build-backend = "build_backend"
> backend-path = ["."]
> ```
>
> So `build_backend.py` at the repository root **is** the PEP 517 backend. It wraps
> `setuptools.build_meta` and inserts a `_build_c_bindings()` step in front of `build_wheel` and
> `build_editable`. `build_sdist` explicitly **does not** compile — its docstring says *"Build source
> distribution without compiling Swift/C code."*

What that step actually runs (✅ verified, `build_backend.py:146-204`):

```python
swift build -c release                     # in foundation-models-c/
swift build -c release --show-bin-path     # find the output
# copy the whole bin dir into src/apple_fm_sdk/lib/
ctypesgen foundation-models-c/Sources/FoundationModelsCBindings/include/FoundationModels.h \
    -L lib -l FoundationModels \
    -o ./src/apple_fm_sdk/_ctypes_bindings.py
```

then rewrites the generated bindings so the dylib is found relative to the package directory rather
than the working directory (`build_backend.py:20-40, 206-226`).

Two undocumented knobs exist, readable from the backend and mentioned nowhere else:

> ✅ **VERIFIED** — `build_wheel` / `build_editable` read three `config_settings` keys
> (`build_backend.py:13, 148-204`): **`swift-build-config`** (passed to `swift build -c <value>`,
> default `release`), **`override-library-name`** and **`override-library-search-path`** (extra
> `-l` / `-L` for ctypesgen). Invocation syntax follows normal PEP 517 conventions —
> `pip install . --config-settings swift-build-config=debug` — though the repository never shows a
> command line, so the exact invocation is 🟡 **RECONSTRUCTED**.

A debug build is worth knowing about: when you are chasing a crash inside the shim (§13), a
`swift-build-config=debug` install gives you a symbolicated Swift stack instead of an optimised one.

### 6.2 The preflight ladder, and the two error strings that identify it

Before compiling anything the backend runs five checks, each raising `SwiftToolingError`:

> ✅ **VERIFIED** — `build_backend.py:65-134`, in this order:
>
> 1. **macOS ≥ 26.0** via `platform.mac_ver()`, else *"macOS version {v} found, but version 26.0 or
>    higher is required. This package requires macOS 26.0+ to build the Swift bindings."*
> 2. **`swift` on `PATH`**, else *"No `swift` executable found in PATH. Is `swift` set up on your
>    system?"*
> 3. **`xcode-select -p` must NOT contain `CommandLineTools`**, else *"The active developer directory
>    is set to Command Line Tools (…), but a full Xcode installation is required. Please install
>    Xcode. Then open Xcode at least once to accept the license agreement and install the Swift
>    SDKs."*
> 4. **`xcodebuild` on `PATH`.**
> 5. **`xcodebuild -version` major ≥ 26**, parsed with `re.search(r"Xcode\s+(\d+)\.(\d+)", …)`.

Check 3 is the one everyone hits, and it is an **open issue in Apple's repository**:

> ✅ **VERIFIED** — `apple/python-apple-fm-sdk` issue #6, *"Build fails with Command Line Tools only —
> Xcode.app should not be required"*, **open since 2026-03-07**, still open as of 2026-07-29 (two
> comments, no merge).
> Reporter's environment: macOS 26.3, M3 Max, Swift 6.2.3 from CLT, no Xcode.app. Their argument is
> correct on the facts — **the build only ever calls `swift build`, never `xcodebuild`** — and they
> report a local patch (require `swift --version >= 6.2` instead) that builds and passes *"text
> generation, streaming, guided generation, tool calling all verified."* Apple has not merged it.
>
> **Consequence for CI:** a runner image with Command Line Tools only **cannot install this
> package**. You need full Xcode, `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`,
> and Xcode opened once interactively to accept the agreement.

A diagnostic gift, and it is genuinely useful:

> ✅ **VERIFIED** — `apple/python-apple-fm-sdk#16` (open): `build_backend.py:99-100` concatenates two Python string
> literals without a space and emits **`"…Then open Xcodeat least once…"`**. Cosmetic — but
> `Xcodeat` is a perfect **fingerprint**. If that string is in a stack trace, you are looking at
> `apple-fm-sdk` ≤ 0.2.1's build backend, and you know exactly which check failed.

### 6.3 There is no wheel

> ✅ **VERIFIED** — `MANIFEST.in` prunes `src/apple_fm_sdk/lib` and globally excludes
> `_ctypes_bindings.py`, so the **sdist contains Swift sources and no binaries**. The repo has no CI
> configuration in the clone.
>
> 🔴 **GAP:** whether PyPI currently serves a prebuilt wheel for any platform could not be checked
> (no network access during the research pass). `pyproject.toml`'s `package-data` entry
> (`apple_fm_sdk = ["lib/*.a", "lib/*.dylib"]`) makes wheels *possible*, and
> `apple/python-apple-fm-sdk#6`'s second
> commenter explicitly asks for *"distributing a pre-compiled binary version like psycopg"*, which
> implies none existed then. **Assume you are compiling.** Resolving needs one
> `pip download apple-fm-sdk --no-deps -d /tmp/x && ls /tmp/x`.

### 6.4 ⚠️ The build machine silently decides whether images work

This is the callout the version-floor block promised, and it is the cleanest example in the SDK of a
capability being decided somewhere you are not looking.

> ⚠️ **SILENT FAILURE — image support is compiled in or out based on the *build* machine's SDK, and
> nothing at runtime tells you which you got until an image prompt fails.**
>
> ✅ **VERIFIED** — `build_backend.py:43-54` and `:148-152`:
>
> ```python
> def _macos_sdk_major_version() -> Optional[int]:
>     """Major version of the active macOS SDK (e.g. 26, 27), or None if undetectable."""
>     sdk_version = subprocess.run(
>         ["xcrun", "--sdk", "macosx", "--show-sdk-version"], check=True,
>         capture_output=True, text=True,
>     ).stdout.strip()
>     return int(sdk_version.split(".")[0])
> ```
>
> ```python
>     # `Attachment` (image support) only exists in the macOS 27+ SDK
>     extra_swift_args = []
>     sdk_major = _macos_sdk_major_version()
>     if sdk_major is not None and sdk_major >= 27:
>         extra_swift_args += ["-Xswiftc", "-DFM_HAS_MACOS_27_SDK"]
> ```
>
> And on the Swift side (`FoundationModelsCBindings.swift:31-48`):
>
> ```swift
> public func add(attachmentFromPath imagePath: String, label: String?) throws {
>     // `Attachment` only exists in the macOS 27+ SDK
>     #if FM_HAS_MACOS_27_SDK
>     if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) {
>       let url = URL(fileURLWithPath: imagePath)
>       var attachment = Attachment(imageURL: url)
>       if let label { attachment = attachment.label(label) }
>       self.components.append(attachment)
>       return
>     } else { throw ComposedPromptError.unsupportedOS }
>     #else
>     throw ComposedPromptError.unsupportedSDK
>     #endif
> }
> ```
>
> Note the `_macos_sdk_major_version()` failure path: it returns `None` when the SDK version cannot
> be detected, and `None` takes the *else* branch — **undetectable silently means "no image
> support."**
>
> **Why it bites:** the flag is baked into the installed artefact. A wheel built on an Xcode 26
> machine **permanently lacks image support** even if you later upgrade to macOS 27; nothing
> revalidates at import. There is no `fm.supports_images()` to query. You find out when
> `session.respond([text, image])` raises.
>
> **How to tell the two failures apart** — this is the diagnostic, and it is precise, because PR #14
> deliberately split one error into two (✅ verified, `prompt.py:152-179`):
>
> | Message tail | Meaning | Fix |
> |---|---|---|
> | `…the Xcode version used to build this package doesn't include macOS 27 SDKs` | **Build-time.** Compiled without `FM_HAS_MACOS_27_SDK`. | Upgrade Xcode, then **reinstall from source** — `pip install --force-reinstall --no-binary :all: apple-fm-sdk`. |
> | `…the current OS does not support attachment prompts` | **Runtime.** Built with the 27 SDK, running on macOS 26. | Upgrade macOS. |
>
> **Safe pattern:** probe once at startup rather than discovering it mid-batch.
>
> ```python
> from pathlib import Path
> import apple_fm_sdk as fm
>
> async def images_supported(probe: Path) -> bool:
>     """True if this install can send image attachments. Probe is any small real image."""
>     session = fm.LanguageModelSession()
>     try:
>         await session.respond([ "Reply with the single word: ok.",
>                                 fm.ImageAttachment(path=probe) ])
>         return True
>     except fm.ImagePromptError as e:
>         print(f"image attachments unavailable: {e}")
>         return False
> ```
>
> Apple's own test suite does exactly this, at every image test:
> ✅ verified, every test in `tests/test_image_prompts.py` is wrapped in
> `try/except fm.ImagePromptError: pytest.skip(...)`.

### 6.5 Development install

> ✅ **VERIFIED** — `README.md:107-132`:
>
> ```bash
> git clone https://github.com/apple/python-apple-fm-sdk
> cd python-apple-fm-sdk
> uv venv
> source .venv/bin/activate
> uv sync
> uv pip install -e .      # after any change
> pytest
> ```

Two notes from the issue history. `uv sync` alone builds the Swift/C backend since PR #7 removed a
pinned setuptools version — ✅ verified from that PR: *"It turns out `uv sync` was not correctly
building our Swift-C backend, which is why we needed the `uv pip install -e .` previously."* The
README still lists the extra step. And **you almost certainly want the development install rather
than the released one**, for the reason in §13.2: the most important bug fix in the repository is on
`main` and is not in any tag.

Running the tests is worth doing once — they are the best executable documentation of the SDK:

```bash
pytest                          # everything (needs a working model)
pytest tests/test_guides.py -v  # the full guide/type compatibility matrix
pytest -s                       # the tests are chatty; -s shows it
```

> ⚠️ **Run pytest from the repository root.** ✅ Verified: many tests open fixtures by
> repo-root-relative path (`"tests/tester_schemas/test_transcript.json"`). From anywhere else they
> fail on `FileNotFoundError`, which reads like a broken install and is not.

One detail in the test harness is itself a finding about the SDK:

> ✅ **VERIFIED** — `tests/conftest.py`'s `pytest_runtest_makereport` hookwrapper **converts
> `fm.ExceededContextWindowSizeError` failures into `UserWarning`s and marks the test passed**:
>
> ```python
> if exc_type is fm.ExceededContextWindowSizeError:
>     warnings.warn(f"ExceededContextWindowSizeError in {item.nodeid}: {exc_value}",
>                   UserWarning, stacklevel=2)
>     report.outcome = "passed"
> ```
>
> Apple's own test suite treats context overflow as **expected flakiness** against a 4K window. Read
> that as a design signal for your own batch runs: budget tokens (§7.3) and handle the error;
> do not assume a prompt that fits today fits every time.

---

## 7. The model object: availability, context size, token counting

### 7.1 `is_available()` returns a tuple, and that changes your code

Swift gives you an enum with associated values and you `switch` on it. Python gives you a 2-tuple.

> ✅ **VERIFIED** — `core.py`:
>
> ```python
> def is_available(self) -> tuple[bool, Optional[SystemLanguageModelUnavailableReason]]
> ```
>
> Returns `(True, None)` when available, `(False, reason)` otherwise. Implementation passes an
> out-parameter down to C:
>
> ```python
> reason = c_int()
> is_available = lib.FMSystemLanguageModelIsAvailable(self._ptr, ctypes.byref(reason))
> ```

The canonical usage is Apple's own, from the README:

> ✅ **VERIFIED — verbatim, `README.md:55-72`:**
>
> ```python
> import apple_fm_sdk as fm
> import asyncio
>
> async def main():
>     # Get the default system foundation model
>     model = fm.SystemLanguageModel()
>
>     # Check if the model is available
>     is_available, reason = model.is_available()
>     if is_available:
>         # Create a session
>         session = fm.LanguageModelSession()
>
>         # Generate a response
>         response = await session.respond("Hello, how are you?")
>         print(f"Model response: {response}")
>     else:
>         print(f"Foundation Models not available: {reason}")
>
> # Run async function
> asyncio.run(main())
> ```

The reasons:

> ✅ **VERIFIED** — `core.py`, values matching the C enum exactly:
>
> ```python
> class SystemLanguageModelUnavailableReason(IntEnum):
>     APPLE_INTELLIGENCE_NOT_ENABLED = 0
>     DEVICE_NOT_ELIGIBLE            = 1
>     MODEL_NOT_READY                = 2
>     UNKNOWN                        = 0xFF
> ```

Three practical consequences of the tuple shape:

**Print `reason.name`, not `reason`.** It is an `IntEnum`, so a bare f-string interpolation gives you
something like `SystemLanguageModelUnavailableReason.MODEL_NOT_READY` at best and an integer in some
contexts. `reason.name` gives `MODEL_NOT_READY`.

**`MODEL_NOT_READY` is retryable and the other two are not.** It means the assets are still
downloading. In a long batch job, treat it as "sleep and retry"; treat `DEVICE_NOT_ELIGIBLE` as
fatal.

**`APPLE_INTELLIGENCE_NOT_ENABLED` may be lying to you.** Forum threads 835211 and 836760 report
that on 27 betas the availability check returns not-enabled unless the user has switched on Siri —
and **an Apple Frameworks Engineer confirmed on thread 836760 that this is a bug**, unresolved as of
2026-07-27. If you get that reason on a machine where Apple Intelligence is visibly on, check the
Siri toggle before you debug your code. Do not build a permanent workflow around requiring Siri; it
is a defect with an acknowledgement, not a documented gate. Full treatment in
[`../../part-01-orientation-and-gating/references/02-platform-and-version-gating.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/references/02-platform-and-version-gating.md).

### 7.2 The constructor: use case and guardrails

> ✅ **VERIFIED** — `core.py`:
>
> ```python
> SystemLanguageModel(
>     use_case: SystemLanguageModelUseCase = SystemLanguageModelUseCase.GENERAL,
>     guardrails: SystemLanguageModelGuardrails = SystemLanguageModelGuardrails.DEFAULT,
> )
> ```
>
> ```python
> class SystemLanguageModelUseCase(IntEnum):
>     GENERAL         = 0
>     CONTENT_TAGGING = 1
>
> class SystemLanguageModelGuardrails(IntEnum):
>     DEFAULT                            = 0
>     PERMISSIVE_CONTENT_TRANSFORMATIONS = 1
> ```
>
> These map to Swift's `.general` / `.contentTagging` and `.default` /
> `.permissiveContentTransformations` (`FoundationModelsCBindings.swift:107-137`). An out-of-range
> use case prints *"Warning: Unknown SystemLanguageModel use case \(c), defaulting to .general"* and
> falls back — tested by `tests/test_system_model.py::test_invalid_use_case`.

Two caveats carried over from the Swift side, both of which people hit:

`.permissiveContentTransformations` **does not apply to structured output.** That is a Swift-side
property reported by developers on the forums, and a Python user has already reported it in this
repository:

> ✅ **VERIFIED** — `apple/python-apple-fm-sdk#5` (open), @andrewgleave: *"I have a suite of test cases running against FM,
> many of which are triggering **erroneous guardrail violations even when configured with
> `PERMISSIVE_CONTENT_TRANSFORMATIONS`**."* That issue is primarily about the missing feedback API
> (§14), but the observation stands on its own.

> ⚠️ **`SystemLanguageModel` has no `temperature` or `top_p`.** ✅ Verified: `session.py:87-90`'s
> docstring shows `fm.SystemLanguageModel(temperature=0.7, top_p=0.9)` and **that call raises
> `TypeError`** — the parameters do not exist. A community member reported exactly this on issue #3:
> *"but it's not possible to pass them."* Sampling lives on `GenerationOptions` (§8.6). This is a
> documentation bug in the shipping SDK; do not copy that docstring.

### 7.3 `context_size` and `token_count` — the 26.4 gate

Added in `v0.2.1` (commit `db7afde`, PR #15), these bridge Swift's `model.contextSize` and
`model.tokenCount(for:)`.

> ✅ **VERIFIED** — `core.py`:
>
> ```python
> @property
> def context_size(self) -> int:
>     """The model's maximum context window size, measured in tokens."""
>     return int(lib.FMSystemLanguageModelGetContextSize(self._ptr))
>
> async def token_count(
>     self,
>     value: "Optional[Union[Prompt, GenerationSchema, Transcript, list[Tool]]]" = None,
>     *,
>     instructions: Optional[str] = None,
> ) -> int:
> ```
>
> `context_size` is a **sync property**; `token_count` is **async**.

**The version gate is on `token_count` only.** ✅ Verified in the shim: every token-count entry point
is wrapped in `guard #available(macOS 26.4, iOS 26.4, visionOS 26.4, *)`, and the failure is an
`NSError` whose localized description is, verbatim:

```
Token counting requires macOS 26.4, iOS 26.4, or visionOS 26.4 or later.
```

`FMSystemLanguageModelGetContextSize` is **not** gated — `context_size` works on 26.0. That
asymmetry is easy to get wrong in a capability check: testing `context_size` proves nothing about
`token_count`.

Everything `token_count` accepts, straight from Apple's tests:

> ✅ **VERIFIED** — `tests/test_token_count.py`:
>
> ```python
> context_size = model.context_size                                       # int, >= 1
> await model.token_count("Hello")                                        # a str prompt
> await model.token_count(["First line of text", "Second line of text"])  # a list prompt
> await model.token_count("こんにちは世界")                                  # unicode
> await model.token_count(instructions="You are a helpful assistant")     # instructions
> await model.token_count([SimpleCalculatorTool()])                       # tool definitions
> await model.token_count(tester_schemas.Cat.generation_schema())         # a schema
> await model.token_count(session.transcript)                             # a transcript
> ```
>
> Determinism is asserted: the same prompt yields the same count
> (`test_token_count_is_deterministic`), and a longer prompt yields a strictly larger one.

The dispatch order matters, because one branch has a trap:

> ✅ **VERIFIED** — `core.py:346-399`, in this order: `instructions=` given → instructions path
> (and `ValueError("Provide either a value or instructions to token_count(), not both")` if you pass
> both); `value is None` → `ValueError("token_count() requires either a value or instructions")`;
> `GenerationSchema` → schema path; `Transcript` → transcript path;
> **`isinstance(value, list) and all(isinstance(t, Tool) for t in value)`** → tools path; otherwise
> treat as a prompt.
>
> ⚠️ **`await model.token_count([])` goes down the *tools* path**, not the prompt path, because
> `all(...)` over an empty list is vacuously true. It returns the token count of an empty toolset,
> which is not what a caller passing an empty prompt list expects. Guard your empties.

Why bother counting at all: the on-device window is small and everything competes for it.

> ✅ **VERIFIED** — a DTS engineer on forum thread 790736: *"the token limit for Foundation Models
> framework is around 4,000. There is no guarantee that this will stay the same forever or across
> devices."* And `generation_options.py:166-174` documents what consumes it: *"All input to the model
> contributes tokens to the context window, including the Instructions, Prompt, Tool definitions, and
> Generable types, as well as the model's responses."*

The budgeting pattern, adapted from the SDK's own docstring:

```python
import apple_fm_sdk as fm

async def budget_report(instructions: str, prompt: str, tools: list, schema_owner) -> None:
    model = fm.SystemLanguageModel()
    budget = model.context_size                      # sync, available on 26.0

    try:
        used  = await model.token_count(instructions=instructions)
        used += await model.token_count(prompt)
        if tools:
            used += await model.token_count(tools)
        used += await model.token_count(schema_owner.generation_schema())
    except fm.GenerationError as e:
        # macOS < 26.4 lands here with "Token counting requires macOS 26.4…"
        print(f"token counting unavailable: {e}")
        return

    print(f"input uses {used} of {budget} tokens "
          f"({budget - used} left for the response)")
```

Note what the report gives you that a naive `len(prompt.split())` never could: the **schema** and the
**tool definitions** are counted. In a guided-generation feature with three tools, those two
frequently outweigh the prompt, and they are invisible in the source.

---

## 8. Sessions, `respond()`, and streaming

### 8.1 Creating a session

> ✅ **VERIFIED** — `session.py`:
>
> ```python
> LanguageModelSession(
>     instructions: Optional[str] = None,
>     model: Optional[SystemLanguageModel] = None,
>     tools: Optional[list[Tool]] = None,
> )
> ```
>
> **`instructions` is the first positional parameter** — `fm.LanguageModelSession("You are a helpful
> assistant.", model=model)` is the dominant form in Apple's tests. Instructions are a plain `str`;
> there is no `@InstructionsBuilder` equivalent.

Two quiet behaviours:

> ✅ **VERIFIED** — `session.py:135-169`: falsy instructions are passed as `NULL`, so
> **`LanguageModelSession(instructions="")` is identical to passing nothing.** And the model is
> retained on the Swift side — the source comment reads *"model object will be retained by
> LanguageModelSession in Swift so here we don't need to retain model"* — so you may let your Python
> `SystemLanguageModel` reference drop while the session lives.

### 8.2 One request at a time, per session

> ✅ **VERIFIED** — `session.py:56-59`, verbatim: *"Sessions use an internal lock to prevent
> concurrent requests. If you need to handle multiple requests simultaneously, create multiple
> session instances."* The lock is a real `asyncio.Lock` created in `__init__`, and
> `tests/test_memory.py::test_concurrent_requests_queued` asserts that two overlapping calls complete
> in submission order.

Cross-session concurrency is allowed — Apple's tests run three sessions under `asyncio.gather` — but
read this before you build a thread pool around it:

> ✅ **VERIFIED** — `docs/source/evaluation.rst:76-78`, verbatim: *"Note that each inference call will
> be processed **one at a time (not in parallel) at the macOS hardware level**, so consider the time
> implications of large batches."*

So parallelism buys you overlapped *Python* work, not overlapped inference. For a 500-row evaluation
run, plan the wall-clock as `500 × per-call latency` and do not be surprised when four workers do not
make it four times faster.

### 8.3 `respond()` — five paths through one method

> ✅ **VERIFIED** — the runtime signature (`session.py:340-348`):
>
> ```python
> async def respond(
>     self,
>     prompt: Prompt,
>     generating: Optional[Union[Type[Generable], Generable]] = None,
>     *,
>     schema: Optional[GenerationSchema] = None,
>     json_schema: Optional[dict] = None,
>     options: Optional[GenerationOptions] = None,
> ) -> Union[str, Any, GeneratedContent]:
> ```
>
> The typing overloads declare `generating` as keyword-only; **the implementation accepts it
> positionally too.** Use the keyword form — it is what every example and the README use.

> ✅ **VERIFIED** — the dispatch body, `session.py:458-489`, in exactly this order:
>
> ```python
> if generating is not None and schema is not None:
>     raise ValueError("Cannot specify both 'generating' and 'schema' arguments")
>
> if generating is not None:
>     if not isinstance(generating, Generable):
>         raise ValueError(f"{generating.__name__} is not a Generable type. Use @generable decorator.")
>     gen_schema = generating.generation_schema()
>     generated_content = await self._respond_with_schema(prompt, gen_schema)   # <-- options NOT passed
>     return generating._from_generated_content(generated_content)
>
> if schema is not None:
>     return await self._respond_with_schema(prompt, schema, options)
>
> if json_schema is not None:
>     return await self._respond_with_schema_from_json(prompt, json_schema, options)
>
> return await self._respond_basic(prompt, options)
> ```

| You pass | You get back | Notes |
|---|---|---|
| nothing extra | **`str`** | Not a `Response`. |
| `generating=Cat` | an instance of **`Cat`** | ⚠️ **`options` is dropped** — see below. |
| `schema=<GenerationSchema>` | **`GeneratedContent`** | `options` honoured. |
| `json_schema=<dict>` | **`GeneratedContent`** | `options` honoured. §9.7. |
| both `generating` and `schema` | `ValueError` | Loud, at least. |

And now the bug hiding in plain sight in that listing:

> ⚠️ **SILENT FAILURE — `respond(..., generating=X, options=...)` throws your `options` away.**
>
> ✅ **VERIFIED by reading** — `session.py:473`. The `generating` branch calls
> `self._respond_with_schema(prompt, gen_schema)` with **two** arguments; the method's third
> parameter, `options`, defaults to `None`. Every other branch passes it. Nothing warns, nothing
> raises, and the call succeeds.
>
> **What that costs you:** on the *typed* guided-generation path — the flagship, the one the README
> demonstrates, the one you will use most — `temperature`, `sampling` and
> `maximum_response_tokens` **have no effect at all**. If you set `sampling=greedy` to make an
> evaluation reproducible and used `generating=`, your run was never greedy. Your numbers moved
> between runs for a reason you would have spent a day chasing.
>
> **Status:** read from source at commit `e868e60`; **not executed**. It is a two-argument call where
> every sibling makes a three-argument call, so the reading is not ambiguous, but it has not been
> confirmed on a machine.
>
> **The workaround** — go through the schema path and convert yourself. `generation_schema()` and
> `_from_generated_content()` are exactly what the `generating` branch calls internally:
>
> ```python
> import apple_fm_sdk as fm
>
> async def respond_typed(session, prompt, cls, options=None):
>     """respond(generating=cls) but with options actually applied."""
>     content = await session.respond(prompt,
>                                     schema=cls.generation_schema(),
>                                     options=options)
>     return cls._from_generated_content(content)
>
> # reproducible typed generation:
> cat = await respond_typed(
>     session, "Generate an adorable rescue cat", Cat,
>     options=fm.GenerationOptions(sampling=fm.SamplingMode.greedy()),
> )
> ```
>
> `_from_generated_content` is a private name (leading underscore) attached to your class by the
> decorator. Using it is the pragmatic choice; pin your `apple-fm-sdk` version if you rely on it.

### 8.4 Cancellation, and the cleanup you must do yourself

All three `_respond_*` methods share one structure worth seeing, because it explains the cancellation
etiquette:

> ✅ **VERIFIED** — `session.py:491-714`, condensed:
>
> ```python
> async with self._request_lock:
>     future = asyncio.get_running_loop().create_future()
>     composed_prompt = self._composed_prompt_from_prompt(prompt=prompt)
>     options_json = json.dumps(options.to_dict()).encode("utf-8") if options else None
>     future_handle = _register_handle(future)
>     task = lib.FMLanguageModelSessionRespond(self._ptr, composed_prompt, options_json,
>                                             future_handle, _session_callback)
>     try:
>         await future
>     except asyncio.CancelledError:
>         lib.FMTaskCancel(task)
>         future.cancel()
>         while self.is_responding and elapsed < 1.0:      # poll at 10 ms
>             await asyncio.sleep(0.01)
>         self._reset_task_state()
>         raise
>     finally:
>         _unregister_handle(future_handle)
>         lib.FMRelease(task)
>         if composed_prompt:
>             try: lib.FMRelease(composed_prompt)
>             except Exception: pass
>     return future.result()
> ```

Three things follow.

**Cancellation is asynchronous on the native side.** The SDK polls `is_responding` for up to one
second after cancelling. Apple's own tests then wait *again*:

> ✅ **VERIFIED** — `tests/test_memory.py::test_timeout_handling`:
>
> ```python
> task = asyncio.create_task(session.respond("Write a very long essay ..."))
> await asyncio.sleep(0.1)
> task.cancel()
> with pytest.raises(asyncio.CancelledError):
>     await task
> # then WAIT for the native side:
> while session.is_responding:
>     await asyncio.sleep(0.5)
> await asyncio.sleep(0.2)     # "Additional delay for native cleanup"
> ```
>
> **Reusing a session immediately after cancelling it is a race.** Poll `session.is_responding`
> first.

**A late native cancellation surfaces as a generic error, not `CancelledError`.** ✅ Verified: the
Swift `catch is CancellationError` branches call back with status **255** and the message
`"Operation cancelled"` / `"Stream cancelled"`, which the Python layer maps to a plain
`GenerationError`. Usually the Python-side `asyncio.CancelledError` wins the race. Not always. Catch
both in a batch runner.

**`_reset_task_state()` does nothing.** ✅ Verified — `FMLanguageModelSessionReset` is a no-op on the
Swift side, with a comment saying so: *"For now, this is a no-op as the Swift `LanguageModelSession`
should handle task cleanup internally. This function exists to provide a hook for future
improvements."* Do not count on it to recover a wedged session; make a new one.

One asymmetry to be aware of: ✅ verified, `_respond_basic` has **no** generic `except Exception`
clause (only `CancelledError`), while the two schema paths do and call `_reset_task_state()` on any
error. Practically minor since the reset is a no-op, but it explains why error paths differ subtly
between plain and structured calls.

### 8.5 Streaming yields snapshots, and only text

> ✅ **VERIFIED** — `session.py:722-735, 802-807`, verbatim from the docstring:
>
> - *"Yields complete text **snapshots (not deltas)** as generation progresses"*
> - *"The final yield contains the complete response"*
> - *"Automatically updates the session transcript after completion"*
> - *"**Does not support guided generation (text responses only)**"*
> - *"Can be cancelled mid-stream using asyncio cancellation"*
> - *"The session transcript is updated only after streaming completes"*
> - *"Breaking out of the async for loop early will properly clean up resources"*

```python
async for snapshot in session.stream_response("Tell me a short story"):
    print(snapshot, end="", flush=True)   # WRONG-ish: each snapshot is the FULL text so far
```

That line is how the SDK's own example writes it, and it is worth pausing on: because snapshots are
cumulative, printing each one with `end=""` re-prints the whole story every time. For a terminal you
want to clear and redraw, or diff against the previous snapshot:

```python
prev = ""
async for snapshot in session.stream_response("Tell me a short story"):
    print(snapshot[len(prev):], end="", flush=True)   # print only what is new
    prev = snapshot
```

This is the same snapshot-not-delta semantics Swift has, and the same trap. Apple's tests confirm
`chunks[-1]` is the complete response (`tests/test_streaming.py:33`).

Why it is text-only, structurally:

> ✅ **VERIFIED** — the Swift shim instantiates `UnsafeSendableResponseStreamBox<String>`; the box
> holds the `LanguageModelSession.ResponseStream<Content>` **and a strong reference to the session**,
> with `deinit { iterationTask?.cancel() }`. The generic parameter is hard-coded to `String`. There
> is no path for `Response.Partial<T>`.
>
> Correspondingly: ✅ verified, `create_partially_generated(cls)` builds a
> `<Name>PartiallyGenerated` companion dataclass for **every** `@fm.generable` type — all fields
> `Optional`, plus a `GenerationID` — and **nothing in the SDK ever constructs one.** The Python
> analogue of Swift's partial-streaming plumbing exists and is unwired. If you want progressive
> structured output, you are in Swift.

And two implementation facts with real consequences:

> ⚠️ **`stream_response` does not take the session's request lock.** ✅ Verified by reading:
> `_respond_basic`, `_respond_with_schema` and `_respond_with_schema_from_json` all do
> `async with self._request_lock:`; `_stream_response_basic` does not. **A stream and a `respond()`
> on the same session can therefore run concurrently, unserialised.** The framework's own
> concurrency guard does not cover the streaming path. Use separate sessions, or serialise yourself.

The mechanism underneath is a daemon thread plus a queue: ✅ verified, `_stream_response_basic`
spawns a `threading.Thread` that calls the blocking
`FMLanguageModelSessionResponseStreamIterate`, while the coroutine drains a `queue.Queue` with a
100 ms timeout and `None` as the end-of-stream sentinel. The `finally:` block joins the thread
(`timeout=2.0`) **before** releasing the stream pointer, with the comment *"This must happen after
the thread completes to prevent segfaults"*. That is the machinery that makes early `break` safe —
and the reason not to reach into it.

### 8.6 `GenerationOptions`, and the random-sampling bug

> ✅ **VERIFIED** — `generation_options.py`:
>
> ```python
> class SamplingModeType(str, Enum):
>     GREEDY = "greedy"
>     RANDOM = "random"
>
> @dataclass
> class SamplingMode:
>     mode_type: SamplingModeType
>     top: Optional[int] = None
>     probability_threshold: Optional[float] = None
>     seed: Optional[int] = None
>
>     @classmethod
>     def greedy(cls) -> "SamplingMode": ...
>     @classmethod
>     def random(cls, top=None, probability_threshold=None, seed=None) -> "SamplingMode": ...
>
> @dataclass
> class GenerationOptions:
>     sampling: Optional[SamplingMode] = None
>     temperature: Optional[float] = None
>     maximum_response_tokens: Optional[int] = None
> ```
>
> Three fields. No penalties, no stop sequences, no `top_p` *and* `top_k` together. Client-side
> validation raises `ValueError` with messages the tests match verbatim, including *"Cannot specify
> both 'top' and 'probability_threshold'. Choose one sampling constraint."*

Now the defect, which matters enormously for anyone doing evaluation work:

> ⚠️ **SILENT FAILURE — random-sampling parameters, including the seed, are dropped on the floor.**
>
> ✅ **VERIFIED by reading both sides.** Python serialises them as **strings**
> (`generation_options.py:275-294`):
>
> ```python
> if self.sampling.top is not None:
>     sampling_dict["top_k"] = str(self.sampling.top)                    # <-- str()
> if self.sampling.probability_threshold is not None:
>     sampling_dict["top_p"] = str(self.sampling.probability_threshold)  # <-- str()
> if self.sampling.seed is not None:
>     sampling_dict["seed"] = str(self.sampling.seed)                    # <-- str()
> ```
>
> Swift parses them as **numbers** (`FoundationModelsCBindings.swift:516-563`):
>
> ```swift
> let seed = samplingDict["seed"] as? UInt64
> if let topK = samplingDict["top_k"] as? Int {
>   options.sampling = .random(top: topK, seed: seed)
> } else if let probabilityThreshold = samplingDict["top_p"] as? Double {
>   options.sampling = .random(probabilityThreshold: probabilityThreshold, seed: seed)
> }
> ```
>
> An `NSString` does not cast to `Int`. Both branches fail, `options.sampling` is **never assigned**
> for `mode == "random"`, and generation proceeds with the framework default. No error, no warning.
> The SDK's own `to_dict` docstring contradicts the code — it shows `{'top_k': 50}` as an integer.
>
> **What survives:** `greedy`, `temperature` and `maximum_response_tokens` are unaffected —
> `greedy` because the mode string alone determines it, the other two because Swift casts them from
> the correct JSON types.
>
> **What this means:** `fm.SamplingMode.random(top=50, seed=42)` **does not give you reproducible
> output today.** If you are A/B-testing prompts and relying on a fixed seed to hold generation
> constant, you are measuring noise.
>
> **Status:** read from both sides; **not executed** — confirming it needs two runs with a fixed
> seed on a working install and a diff. The check is one line and is the highest-value thing an
> owner of a macOS 26.4+ Mac could contribute to this guide:
>
> ```python
> opts = fm.GenerationOptions(sampling=fm.SamplingMode.random(top=1, seed=1))
> a = await session.respond("Name one animal.", options=opts)
> b = await fm.LanguageModelSession().respond("Name one animal.", options=opts)
> print(a == b)   # False ⇒ the seed is dead, as the source reading predicts
> ```
>
> **Safe default meanwhile: use `fm.SamplingMode.greedy()` for anything you intend to compare
> across runs.** Greedy works, it is the right choice for evaluation regardless, and it sidesteps
> the bug entirely. Combine it with the §8.3 workaround, since `generating=` drops options too —
> **the two bugs compose**, and together they mean the most natural way to write a reproducible
> typed evaluation is reproducible in neither respect.

One documented warning worth repeating, because `maximum_response_tokens` looks safer than it is:

> ✅ **VERIFIED** — `generation_options.py:166-174`: *"Only use `maximum_response_tokens` when you
> need to protect against unexpectedly verbose responses. **Enforcing a strict token response limit
> can lead to the model producing malformed results or grammatically incorrect responses.**"*
> A truncated structured response is a *decoding failure*, not a short answer.

---

## 9. Guided generation: `@fm.generable`, `fm.guide`, and raw JSON Schema

Guided generation is the SDK's best-developed area and the one that maps most cleanly onto Swift.
There are two independent paths into it: **decorate a Python class**, or **hand over a JSON Schema
your Swift app exported**. The second is under-advertised and is the more interesting one for
evaluation work.

### 9.1 The decorator

> ✅ **VERIFIED — verbatim, `README.md:78-101`:**
>
> ```python
> import apple_fm_sdk as fm
>
> @fm.generable # This decorator signals this type be generated by a model
> class Cat:
>     name: str
>     age:int = fm.guide("Age in years", range=(0, 20))
>
> async def generate_cat():
>     # Get the default system foundation model
>     model = fm.SystemLanguageModel()
>
>     # Check if the model is available
>     is_available, reason = model.is_available()
>     if is_available:
>         # Create a session
>         session = fm.LanguageModelSession()
>
>         # Generate a response of the type Cat
>         cat = await session.respond("Generate an adorable rescue cat", generating=Cat)
>         print(f"Model response: {cat}")
>     else:
>         print(f"Foundation Models not available: {reason}")
> ```

Note the shape: **`fm.guide(...)` is a default value, not a decorator or an annotation.** It returns
a `dataclasses.field(metadata=...)`. That is the single biggest syntactic difference from Swift,
where `@Guide` is an attribute attached above the property.

All three decorator call forms work:

> ✅ **VERIFIED** — overloads at `generable_utils.py:36-52`; detection is
> `if isinstance(arg, type): return _apply_generable_decorator(arg, description=None)`:
>
> ```python
> @fm.generable                    # bare
> @fm.generable()                  # empty parens
> @fm.generable("description")     # with a type-level description
> ```

This was not always true, and the history is instructive:

> ✅ **VERIFIED** — issue #4 (2026-03-01) reported three "non-obvious behaviors", verbatim:
> *"1. `@generable()` is a factory, not a direct decorator — parentheses with description string
> required. 2. `@dataclass` must NOT be applied — `generable()` internally applies it.
> 3. Response parameter is `generating=`, not `response_type=`."*
> `apple/python-apple-fm-sdk#10` (merged 2026-03-08) fixed **1 and 2** — the bare form now works and explicit `@dataclass`
> no longer breaks it, in either order:
>
> ```python
> @dataclass
> @fm.generable("A description of my generable")
> class ValidGenerableDataClass: ...
>
> @fm.generable
> @dataclass
> class ValidGenerableDataClassAlt: ...
> ```
>
> **Point 3 was never "fixed" because it was never a bug: the keyword is `generating=`.** If you see
> `response_type=` anywhere, it is from a pre-March-2026 attempt and it raises.

What the decorator does, in order (✅ verified, `generable_utils.py:147-251`): rejects non-classes;
rejects classes with no annotated fields; **applies `@dataclass` if it is not already one**;
validates that type hints resolve; sets `_generable` and `_generable_description`; then attaches
`generation_schema()`, `_from_generated_content()`, a `generated_content` property, and the
`PartiallyGenerated` companion.

Its error type is worth knowing for `except` clauses:

> ✅ **VERIFIED** — `GenerableDecoratorError` subclasses `InvalidGenerationSchemaError`, which
> subclasses `FoundationModelsError`. It is **not exported**, so catch it as
> `fm.InvalidGenerationSchemaError`. Directly subclassing `fm.Generable` is forbidden and raises:
> *"Subclassing Protocol Generable is not allowed. Use the `@fm.generable()` decorator instead."*
> (`generable.py:342-347`).

And one subtlety that explains the `respond()` validation: ✅ verified,
`isinstance(MyClass, fm.Generable)` is **True for the class object itself**, because `Generable` is a
`@runtime_checkable` Protocol whose members are class attributes. That is exactly the check
`respond()` performs.

### 9.2 `fm.guide()`

> ✅ **VERIFIED** — `generation_guide.py`:
>
> ```python
> def guide(
>     description: Optional[str] = None,
>     *,
>     anyOf: Optional[List[str]] = None,
>     constant: Optional[str] = None,
>     count: Optional[int] = None,
>     element: Optional["GenerationGuide"] = None,
>     max_items: Optional[int] = None,
>     maximum: Optional[Union[int, float]] = None,
>     min_items: Optional[int] = None,
>     minimum: Optional[Union[int, float]] = None,
>     range: Optional[tuple] = None,
>     regex: Optional[str] = None,
> ) -> Any:                       # actually returns dataclasses.field(metadata={...})
> ```
>
> `description` is positional-or-keyword; every constraint is keyword-only. Multiple constraints in
> one call are allowed and are appended in the order listed above. Client-side validation raises
> `ValueError` for: `anyOf` not a list of `str`; `constant` not a `str`; `count` not a **positive**
> int; `element` not a `GenerationGuide`; `max_items`/`min_items` not **non-negative** ints;
> `maximum`/`minimum` not numbers; `range` not a 2-tuple; `regex` not a `str`.

The standalone factories exist too, and are needed for `element=`:

> ✅ **VERIFIED** — `fm.GenerationGuide.anyOf(list)`, `.constant(str)`, `.count(int)`,
> `.element(guide)`, `.max_items(int)`, `.maximum(num)`, `.min_items(int)`, `.minimum(num)`,
> **`.range(range_tuple)`** — note it takes a *tuple*, `fm.GenerationGuide.range((0, 120))` —
> and `.regex(pattern)`.
>
> ⚠️ Naming asymmetry to expect from autocomplete: the `GuideType` enum members are `maxItems` /
> `minItems` (camelCase, matching the JSON Schema keywords) while the factory methods are
> `max_items` / `min_items` (snake_case).

Per-element constraints on arrays:

```python
from typing import List
import apple_fm_sdk as fm

@fm.generable("A product")
class Product:
    ratings:    List[int]   = fm.guide("Product ratings",
                                       element=fm.GenerationGuide.range((1, 5)))
    prices:     List[float] = fm.guide("Historical prices",
                                       element=fm.GenerationGuide.minimum(0.01))
    categories: List[str]   = fm.guide("Product categories",
                                       element=fm.GenerationGuide.anyOf(["tech", "home", "sports"]))
```

All three are ✅ verified as passing tests in `tests/test_guides.py`.

### 9.3 ⚠️ The `Optional` detection trap — the sharpest edge in the SDK

This one deserves its own section because it is silent, it is version-dependent, and the correct
modern Python spelling is the wrong one.

> ⚠️ **SILENT FAILURE — optionality is detected by substring-matching the *string form* of the type
> annotation.**
>
> ✅ **VERIFIED** — `generation_property.py:91-137`:
>
> ```python
> type_name   = _python_type_to_string(self.type_class)
> is_optional = "Optional" in str(self.type_class)        # <-- string sniffing
> prop_ptr    = lib.FMGenerationSchemaPropertyCreate(name_cstr, desc_cstr, type_cstr, is_optional)
> ```
>
> And `str()` of a type does not say what you think across Python versions
> (**measured** during the research pass with `python3.11/3.12/3.13/3.14 -c "from typing import
> Optional; print(str(Optional[int]))"`):
>
> | Python | `str(typing.Optional[int])` | `str(int \| None)` |
> |---|---|---|
> | 3.11 / 3.12 / 3.13 | `'typing.Optional[int]'` ✅ detected | `'int \| None'` ❌ not detected |
> | **3.14** | `'int \| None'` ❌ **not detected** | `'int \| None'` ❌ not detected |
>
> **Two distinct failures fall out.**
>
> **(a) Never write `x: str | None` in an `@fm.generable` class.** On Python ≤3.13 it is not detected
> as optional *and* `_python_type_to_string` mishandles it — a `types.UnionType` has no `__origin__`
> and no `__name__`, so the fallback returns the literal string `'int | None'`, which Swift then
> interprets as **a reference to a schema type named `int | None`**. The schema build fails. Always
> write `typing.Optional[X]`.
>
> **(b) On Python 3.14, even `Optional[X]` stops being marked optional** — every property silently
> becomes required. Python 3.14 is not in the package's classifier list but **is** permitted by
> `requires-python = ">=3.10"`, so `pip` will happily install it there. The string comparison is
> unambiguous; the end-to-end consequence is **UNVERIFIED** because it needs a built SDK on 3.14.
>
> **Safe default: pin Python ≤3.13, and use `typing.Optional[X]` exclusively.**
>
> ```python
> from typing import List, Optional
> import apple_fm_sdk as fm
>
> @fm.generable("A person")
> class Person:
>     name:     str                 = fm.guide("The person's name")
>     age:      Optional[int]       = fm.guide(range=(18, 100))     # ✅ correct
>     # age:    int | None                                          # ❌ never — silently required,
>     #                                                             #    then a bogus schema reference
>     children: List["Person"]      = fm.guide("The person's children", max_items=3)
> ```
>
> (That forward reference works: ✅ verified, `generation_schema` passes
> `localns={cls_inner.__name__: cls_inner}` to `get_type_hints`.)

### 9.4 The type map, and what Swift does with it

The Python annotation is converted to a **string**, sent across C, and re-interpreted on the Swift
side. Knowing the intermediate representation explains most schema errors.

> ✅ **VERIFIED** — `type_conversion.py`:
>
> ```
> str    -> "string"
> int    -> "integer"
> float  -> "number"
> bool   -> "boolean"
> list                      -> TypeError("Generic list types must specify an element type, for example, List[str]")
> List[T] / list[T]         -> f"array<{_python_type_to_string(T)}>"
> Optional[T]               -> _python_type_to_string(T)      # when exactly one non-None arg
> anything else             -> getattr(t, "__name__", str(t)) # i.e. a schema reference BY NAME
> ```

> ✅ **VERIFIED** — the Swift side maps the string back
> (`FoundationModelsCBindings.swift:1586-1734`):
>
> | Type string | Swift `DynamicGenerationSchema.Property` |
> |---|---|
> | `"string"` | `.init(type: String.self, guides: [GenerationGuide<String>])` |
> | `"number"` / `"float"` / `"double"` | `.init(type: Double.self, guides: …)` |
> | `"integer"` / `"int"` | `.init(type: Int.self, guides: …)` |
> | `"boolean"` / `"bool"` | `.init(type: Bool.self)` — **no guides at all** |
> | `"array<string>"`, `"array<integer>"`, `"array<number>"` | `.init(type: [T].self, guides: …)` |
> | `array<Foo>` (regex `\w+`) | `.init(arrayOf: DynamicGenerationSchema(referenceTo: "Foo"), minimumElements:, maximumElements:)` — **only `count` / `min_items` / `max_items` allowed; anything else throws `unsupportedGuide`** |
> | any other non-empty name | `.init(referenceTo: typeName)` |

Two traps live in that table. **`bool` ignores every guide you attach** — Swift constructs it with no
guides at all, so `fm.guide("Whether it is done", anyOf=["yes","no"])` on a `bool` field is not an
error and not an effect. And **`array<Foo>` is matched with `\w+`**, so a nested generic like
`List[List[str]]` produces `array<array<string>>`, does not match, and falls back to *"array of
strings"* — a silent shape change.

### 9.5 The guide/type compatibility matrix

Constraints are validated **on the Swift side at `respond()` time**, not at decoration time. A bad
pairing decorates cleanly, imports cleanly, and raises `fm.UnsupportedGuideError` the first time you
actually run inference — potentially deep into a batch job.

> ✅ **VERIFIED** — extracted from `tests/test_guides.py:560-811`, where each of these is asserted to
> raise `fm.UnsupportedGuideError`:
>
> | Property type | Guides that FAIL |
> |---|---|
> | `str` | `minimum`, `maximum`, `range`, `count`, `min_items`, `max_items` |
> | `int` | `anyOf`, `regex`, `count`, `min_items`, `max_items` |
> | `float` | `anyOf`, `regex`, `count`, `min_items`, `max_items` |
> | `List[int]`, `List[float]` | `anyOf`, `regex`, `minimum`, `maximum`, `range` |
> | `List[str]` | `regex`, `minimum`, `maximum`, `range` — **but `anyOf` works** (the test file says so explicitly: *"anyOf *does* work on array&lt;string&gt;, so it's not included here"*) |
> | `bool` | all of them — silently ignored, not raised |
> | `List[Foo]` (a referenced generable) | anything except `count` / `min_items` / `max_items` → *"Unsupported guide for array of a referenced Generable type"* |
>
> Guides that **work**: `str` → `anyOf`, `constant`, `regex`. `int`/`float` → `minimum`, `maximum`,
> `range`. `List[str]`/`List[int]`/`List[float]` → `count`, `min_items`, `max_items`,
> `element=<inner guide>`. `List[str]` → `anyOf` (which becomes `GenerationGuide.element(.anyOf(…))`
> in Swift).

**Validate your schemas before the batch, not during it.** Every `@fm.generable` type can be
round-tripped to JSON without touching the model, which forces the Swift-side schema build:

```python
import apple_fm_sdk as fm

def validate_schemas(*types) -> None:
    """Force each schema through the Swift builder now, not in row 4,000 of a batch."""
    for t in types:
        try:
            t.generation_schema().to_dict()
        except fm.FoundationModelsError as e:
            raise SystemExit(f"schema for {t.__name__} is invalid: {e}") from e

validate_schemas(Person, Product, Habitat)
```

`to_dict()` calls `FMGenerationSchemaGetJSONString`, which on the Swift side is literally
`try builder.buildSchema().debugDescription` — ✅ verified. So a schema that survives `to_dict()` is a
schema Swift could build. Anything with a bad guide pairing or an unrepresentable field type fails
here instead of at inference time. (✅ Verified: `datetime.date` and other non-JSON-Schema types fail
exactly this way, per `tests/test_error_handling.py::test_error_on_invalid_generation_schema`.)

Two more constraints worth knowing at authoring time:

> ✅ **VERIFIED** — `element=` wrapping is **dropped** for `min_items`/`max_items`. The C functions
> `FMGenerationSchemaPropertyAddMinItemsGuide` / `…AddMaxItemsGuide` take only
> `(property, count)` — no `wrapped` parameter — while `generation_guide.py:290-293` passes three
> arguments. On arm64 the extra argument lands in an ignored register, so it is harmless *and* the
> wrapping flag never arrives. A silent no-op.

> ✅ **VERIFIED** — `resolve_referenced_generables` follows only the **first** `get_args(...)` entry
> (`generable_utils.py:257-292`), so for `Union[A, B]` only `A` is inspected. Fine for `Optional[X]`
> and `List[X]`; do not expect a union of two generables to resolve both.

### 9.6 ⚠️ The type-level description is silently discarded

> ⚠️ **SILENT FAILURE — `@fm.generable("A description")` stores the description and never uses it.**
>
> ✅ **VERIFIED by reading** — `generation_schema(cls_inner, description=None)` takes its description
> as a parameter defaulting to `None`, and **nothing passes `cls._generable_description` into it**
> (`generable_utils.py:295-360`). A `grep -rn "_generable_description" src tests docs examples`
> returns exactly two hits: the Protocol declaration at `generable.py:340` and the assignment at
> `generable_utils.py:227`. It is written and never read.
>
> **The proof it matters:** the Swift-exported fixture `tests/tester_schemas/cat.json` **does** carry
> `"description": "A description of a cute cat"` at the root. So a schema built in Swift with
> `@Generable(description:)` reaches the model with a type-level description, and the "equivalent"
> Python schema does not. Field-level descriptions from `fm.guide("…")` **do** flow through
> correctly.
>
> **Why you care:** the type description is prompt surface. It is one of the few places to tell the
> model what the object *is*. If you are comparing a Swift implementation against a Python
> reimplementation and getting different quality, this is a live suspect — the two are not sending
> the same schema.
>
> **Workaround:** put the information in a field description, in the instructions, or use the raw
> JSON-Schema path (§9.7), which preserves whatever your Swift app exported.

### 9.7 The other path: raw JSON Schema from your Swift app

This is the feature that makes the SDK genuinely useful for evaluation, and it gets one line in the
session. Instead of re-declaring your type in Python and hoping the two agree, **export the schema
from Swift and feed the exact bytes to Python.**

> ✅ **VERIFIED** — the Swift export side (`docs/source/guided_generation.rst:246-248`):
>
> ```swift
> let schema = ProductReview.generationSchema
> let jsonData = try JSONEncoder().encode(schema)
> try jsonData.write(to: URL(fileURLWithPath: "schema.json"))
> ```
>
> And the Python consumption side:
>
> ```python
> import json, apple_fm_sdk as fm
>
> with open("schema.json") as f:
>     swift_schema = json.load(f)
>
> session = fm.LanguageModelSession(instructions="Generate a product review.")
> content = await session.respond(
>     "This laptop is amazing! Great performance and battery life.",
>     json_schema=swift_schema)                  # -> fm.GeneratedContent
> print(content.to_json())
> print(content.value(str, for_property="sentiment"))
> ```
>
> Swift decodes it with
> `JSONDecoder().decode(GenerationSchema.self, from: Data(jsonSchemaString.utf8))` — the same
> decoder your app would use.

**This eliminates an entire class of evaluation error.** A hand-ported Python schema can drift from
the Swift original — a missing `Optional`, a lost type description (§9.6), a differently-ordered
enum — and then your evaluation measures a schema your app does not ship. Passing the exported JSON
removes the porting step entirely.

The dialect is worth recognising, because it is JSON Schema with Apple extensions:

> ✅ **VERIFIED** — `tests/tester_schemas/person.json`, a Swift-exported fixture, verbatim:
>
> ```json
> {
>   "additionalProperties": false,
>   "properties": {
>     "age":      { "description": "The person's age", "maximum": 100, "minimum": 18, "type": "integer" },
>     "children": { "description": "The person's children", "items": { "$ref": "#" },
>                   "maxItems": 3, "type": "array" },
>     "name":     { "description": "The person's name", "type": "string" }
>   },
>   "required": ["children", "name"],
>   "title": "Person",
>   "type": "object",
>   "x-order": ["age", "children", "name"]
> }
> ```
>
> - **`"title"`** is the type name; **`"x-order"`** is the declaration order of properties — a
>   **custom extension**, and a meaningful one, since generation order affects results.
> - `"additionalProperties": false` always.
> - Optional properties are simply **absent from `required`** (`age` here).
> - Nested types live under `"$defs"` and are referenced as `"$ref": "#/$defs/Age"`; root
>   self-reference is `"$ref": "#"`.
> - Guides serialise as ordinary JSON Schema keywords: `enum` (for both `anyOf` and `constant`),
>   `minimum`/`maximum`, `minItems`/`maxItems`, `pattern` (for `regex`).

And a result from Apple's own tests that is worth knowing before you write a prompt:

> ✅ **VERIFIED** — `tests/test_json_guided_generation.py`: with `person.json`'s `maxItems: 3` and a
> prompt asking for **five** children, `len(children) == 3`. **Schema constraints beat the prompt.**

Failure modes on this path are pleasantly loud: a non-JSON-serialisable dict raises `TypeError` from
`json.dumps` *before* any native call (the test asserts the word `"serializable"` appears), and a
structurally wrong schema comes back as a `fm.GenerationError` whose message contains `"format"`.

### 9.8 Reading a `GeneratedContent`

Both schema paths return `GeneratedContent` rather than a typed object.

> ✅ **VERIFIED** — `generable.py`:
>
> ```python
> content.value()                                  # the whole dict
> content.value(str, for_property="sentiment")     # one property
> content.value(List[str], for_property="colors")
> content.to_json()                                # str
> content.is_complete                              # bool
> content.id                                       # GenerationID (uuid4 wrapper)
> ```
>
> Both call styles appear in the tests: `args.value(str, for_property="operation")` and
> `contents.value(int, "invalid_key")`.

Three behaviours that surprise people:

> ⚠️ **`value()` does not coerce types.** ✅ Verified: the `type_class` argument drives *Generable
> unpacking only* — if the property holds a raw value it is returned untouched. There is a
> `_convert_value` helper with string→int/float/bool coercion at `generable.py:175-226` and **it is
> never called.** Dead code. `content.value(int, for_property="age")` on a JSON string gives you the
> string.

> ⚠️ **A missing property returns `None`, not `KeyError`.** ✅ Verified and asserted:
> `contents.value(int, "invalid_key") is None` (`tests/test_error_handling.py:67-68`). A typo in a
> property name is indistinguishable from a field the model omitted.

> ⚠️ **`GeneratedContent()` built from a dict has no native pointer**, so `.to_json()` and
> `.is_complete` raise `AttributeError` on it. ✅ Verified. Dict-built content is for *feeding* tools
> in tests (§10.2), not for round-tripping.

### 9.9 The parity fixtures: the best translation reference that exists

If you are porting `@Generable` types to Python, do not start from this guide — start from Apple's
own side-by-side fixtures.

> ✅ **VERIFIED** — `tests/tester_schemas/schemas.swift` and `tests/tester_schemas/schemas.py` are
> **the same seven types expressed in both languages**. Header comment (`schemas.py:7-9`): *"These
> are the exact same schemas as in `tests/tester_schemas/schemas.swift`, but expressed in Python
> syntax. They are used to test schema generation and parsing and ensure parity between the Swift and
> Python schemas."*
>
> Side by side (Hedgehog):
>
> ```swift
> @Generable
> struct Hedgehog {
>   @Guide(description: "A cute old-timey name")             var name: String
>   @Guide(description: "The hedgehog's age", .range(0...8)) var age: Int
>   @Guide(description: "The hedgehog's favorite food", .anyOf(["carrot", "turnip", "leek"]))
>   var favoriteFood: String
>   @Guide(.constant("a hedge"))                             var home: String
>   @Guide(description: "The hedgehog's hobbies", .count(3)) var hobbies: [String]
> }
> ```
>
> ```python
> @fm.generable()
> class Hedgehog:
>     name: str = fm.guide(description="A cute old-timey name")
>     age: Age = fm.guide(description="The hedgehog's age, at most 8 years")
>     favoriteFood: str = fm.guide(description="The hedgehog's favorite food",
>                                  anyOf=["carrot", "turnip", "leek"])
>     home: str = fm.guide(constant="a hedge")
>     hobbies: list[str] = fm.guide(description="The hedgehog's hobbies", count=3)
> ```
>
> ⚠️ **The two fixtures are not byte-identical**, and the difference is instructive: Swift's `age` is
> an `Int` with `.range(0...8)`; Python's is a nested `Age` generable with the bound expressed **in
> prose**. Treat "parity" as *schema-level equivalence*, not a mechanical transliteration.

The seven JSON fixtures each exercise a different corner, which makes them a checklist for your own
schemas: `age.json` (basic integers), `cat.json` (`$defs`/`$ref`), `hedgehog.json` (min/max, enum,
sized arrays), `person.json` (recursive `$ref: "#"`, optionals, `maxItems`), `shelter.json` (arrays
of complex objects, multi-level `$defs`), `petClub.json` (multiple entity types), `newsletter.json`
(optional complex objects and arrays).

---

## 10. Tools in Python

Tool calling works, despite the README's feature list not mentioning it. That omission caused real
confusion and was answered directly.

> ✅ **VERIFIED** — session 334 claims tool calling (`334:95`: *"you can use **tool calling** to
> enable the model to interact with code"*), while `README.md:10-18`'s feature list does **not**
> mention it. Resolution, from PR #9's body by @mkery: *"**Tool calling support:** we already support
> tool calling so there's no additional work to do at the moment."* Plus `tests/test_tool.py` is 626
> lines of it. **The session is right; the README is incomplete.**

### 10.1 The contract

> ✅ **VERIFIED** — `tool.py`:
>
> ```python
> class Tool(_ManagedObject, ABC):
>     name: str            # class attribute, required
>     description: str     # class attribute, required
>
>     @property
>     @abstractmethod
>     def arguments_schema(self) -> GenerationSchema: ...
>
>     @abstractmethod
>     async def call(self, args: GeneratedContent) -> str: ...
> ```
>
> Note the differences from Swift: **`name` is required here** (in Swift 27 it is optional with a
> derived default), the arguments arrive as an untyped `GeneratedContent` rather than a typed
> `Arguments` struct, `call` **must** be `async`, and the return **must** be a `str`.

The canonical shape, from the SDK's own docs:

> ✅ **VERIFIED** — `docs/source/tools.rst`:
>
> ```python
> import apple_fm_sdk as fm
>
> class WeatherTool(fm.Tool):
>     name = "WeatherTool"
>     description = "Provides weather information for a given location and units."
>
>     @fm.generable("Weather query parameters")
>     class Arguments:
>         location: str = fm.guide("City name")
>         units: str = fm.guide("Temperature units", anyOf=["celsius", "fahrenheit"])
>
>     @property
>     def arguments_schema(self) -> fm.GenerationSchema:
>         return self.Arguments.generation_schema()
>
>     async def call(self, args: fm.GeneratedContent) -> str:
>         location = args.value(str, for_property="location")
>         units    = args.value(str, for_property="units")
>         temp = 72 if units == "fahrenheit" else 22
>         return f"The weather in {location} is {temp}°{units[0].upper()}"
>
> session = fm.LanguageModelSession(
>     instructions="You are a helpful assistant with access to tools.",
>     tools=[WeatherTool()])
> response = await session.respond("What's the weather like in Taipei?")
> ```

Apple's own test tools use a module-level params class instead of a nested one, which reads better
and avoids `self.Arguments` lookups:

> ✅ **VERIFIED** — `tests/tester_tools/tester_tools.py`:
>
> ```python
> @fm.generable("Calculator parameters")
> class CalculatorParams:
>     operation: str = fm.guide("The operation to perform",
>                               anyOf=["add", "subtract", "multiply", "divide"])
>     a: float = fm.guide("First number")
>     b: float = fm.guide("Second number")
>
> class SimpleCalculatorTool(fm.Tool):
>     name = "simple_calculator"
>     description = "Perform basic arithmetic operations"
>
>     @property
>     def arguments_schema(self) -> fm.GenerationSchema:
>         return CalculatorParams.generation_schema()
>
>     async def call(self, args: fm.GeneratedContent) -> str:
>         operation = args.value(str, for_property="operation")
>         a = args.value(float, for_property="a")
>         b = args.value(float, for_property="b")
>         ...
>         return f"The result of {a} {operation} {b} is {result}"
> ```

One efficiency detail that also documents a real constraint:

> ✅ **VERIFIED** — `Tool.__init__` stores the schema (`self._arguments_schema = self.arguments_schema`)
> with the comment *"This is necessary because `arguments_schema` is a property that returns a new
> object each time"*. **Every call to `MyType.generation_schema()` allocates a fresh native
> `GenerationSchemaBuilder`** — there is no caching. Do not call `generation_schema()` inside a loop.

### 10.2 Testing a tool without a model

Because the arguments are just a `GeneratedContent`, you can invoke a tool directly — the fastest
unit test in the SDK, and it needs no Apple Intelligence at all:

> ✅ **VERIFIED** — `tests/test_tool.py`:
>
> ```python
> calc_tool = SimpleCalculatorTool()
> args = fm.GeneratedContent(content_dict={"operation": "add", "a": 5.0, "b": 3.0})
> result = await calc_tool.call(args)      # "The result of 5.0 add 3.0 is 8.0"
> ```

Write these first. Everything about tool behaviour that does not involve the model — argument
handling, error paths, side effects — is testable this way in milliseconds.

### 10.3 ⚠️ Tool exceptions never reach your `except` block

> ⚠️ **SILENT FAILURE — an exception raised inside `call()` is stringified and handed to the *model*,
> not raised to the caller of `respond()`.**
>
> ✅ **VERIFIED** — `tool.py:245-354`, the C callback body:
>
> ```python
> async def _run_async_callable():
>     try:
>         result = await self._async_callable(generated_content)
>         if not isinstance(result, str):
>             result = str(result)
>         lib.FMBridgedToolFinishCall(self._ptr, call_id, result.encode("utf-8"))
>     except Exception as e:
>         error_msg = f"Tool error: {str(e)}"
>         lib.FMBridgedToolFinishCall(self._ptr, call_id, error_msg.encode("utf-8"))
> ```
>
> Your `KeyError` becomes the string `"Tool error: 'location'"`, which is returned to the model as
> the tool's **output**. The model then writes prose about it. `tests/test_tool.py:150-161` confirms
> exactly this behaviour.
>
> Worse for anyone writing an `except` clause: **`fm.ToolCallError` is exported but the Python layer
> never raises it.** ✅ Verified by grep — the only mentions are `errors.py` and `__init__.py`. The
> `docs/source/tools.rst` example showing `except fm.ToolCallError` is **aspirational**.
>
> **What to do instead — instrument the tool itself:**
>
> ```python
> import logging, traceback
> import apple_fm_sdk as fm
>
> class InstrumentedTool(fm.Tool):
>     """Base class: record failures where you can actually see them."""
>     def __init__(self):
>         super().__init__()
>         self.failures: list[dict] = []
>
>     async def call(self, args: fm.GeneratedContent) -> str:
>         try:
>             return await self.run(args)
>         except Exception as e:
>             self.failures.append({"args": args.value(), "error": repr(e),
>                                   "traceback": traceback.format_exc()})
>             logging.exception("tool %s failed", self.name)
>             # Return a string the model can act on rather than one it will narrate:
>             return f"The tool could not complete the request: {e}"
>
>     async def run(self, args: fm.GeneratedContent) -> str:
>         raise NotImplementedError
> ```
>
> After a batch run, `sum(len(t.failures) for t in tools)` is the number you actually needed and
> would otherwise never have seen. Note also that the return value is **`str()`-ed if it is not
> already a string** — returning a `dict` gives the model a Python repr, which is rarely what you
> want; serialise it deliberately with `json.dumps`.

### 10.4 ⚠️ A tool that never returns hangs the session forever

> ✅ **VERIFIED** — the Swift side blocks on a `withCheckedThrowingContinuation` keyed by an atomic
> `callId` (`BridgedTool.call`, `FoundationModelsCBindings.swift:1766-1775`), resolved only by
> `FMBridgedToolFinishCall`. If your `call()` never returns — an unbounded network wait, a deadlock,
> a thread that dies — **the continuation is never resumed and the session hangs with no timeout.**
>
> Apple's own tests defend against it: the parallel-tool test is wrapped in
> `asyncio.wait_for(..., timeout=30.0)` and fails with *"Session response timed out - possible
> infinite tool calling loop or model issue"*.

Do the same in production code. Two layers, because they catch different things:

```python
import asyncio
import apple_fm_sdk as fm

class NetworkTool(fm.Tool):
    name = "fetch_price"
    description = "Fetches the current price for a product ID."

    async def call(self, args: fm.GeneratedContent) -> str:
        pid = args.value(str, for_property="product_id")
        try:
            # inner bound: never let one tool call hang the continuation
            return await asyncio.wait_for(self._fetch(pid), timeout=5.0)
        except asyncio.TimeoutError:
            return "The price service did not respond in time."

# outer bound: the whole turn, including the tool-calling loop
try:
    answer = await asyncio.wait_for(session.respond("What does SKU-42 cost?"), timeout=60.0)
except asyncio.TimeoutError:
    print("turn timed out")
    while session.is_responding:          # §8.4 — wait for the native side
        await asyncio.sleep(0.5)
```

### 10.5 Two more sharp edges

> ⚠️ **Tool validation uses bare `assert`s, so `python -O` disables it.** ✅ Verified,
> `tool.py:356-374`: `assert hasattr(self, "name")`, `assert hasattr(self, "description")`, and so
> on. Under `-O` a tool missing `description` gets past `__init__` and fails later, deeper, and
> less legibly. Do not run evaluation harnesses with `-O`.

> ⚠️ **You cannot intercept or approve a tool call.** ✅ Verified — issue #3's community answer:
> *"Currently, it doesn't seem possible to manually handle the tool calls."* Swift's 27-era
> `onToolCall` interception (and therefore the tool-as-consent-request pattern from Apple's Origami
> sample) has **no Python equivalent**. If your Swift feature gates a tool behind a user
> confirmation, the Python SDK cannot reproduce that half of it — only the unattended path.

Finally, a detail for anyone debugging why a tool did or did not fire: tool definitions are counted
against the context window (`await model.token_count([tool_a, tool_b])`, §7.3) and they appear in the
transcript's `instructions` entry under `"tools"`, in an OpenAI-ish
`{"type": "function", "function": {"name", "description", "parameters"}}` shape — ✅ verified in
`tests/tester_schemas/test_transcript_full.json`. That is where to look when the model ignores a
tool: check the definition actually made it in, and read the description it was given.

### 10.6 One threading detail, honestly labelled

> ✅ **VERIFIED** — `tool.py`'s C callback tries `asyncio.get_running_loop()` and, on `RuntimeError`,
> falls back to spawning a daemon thread with a **new event loop** to run your `call()`.
>
> 🔴 **GAP — which branch actually runs.** The Swift callback fires from a `Task.detached`, not the
> Python main thread, which makes the new-thread branch the likely path — but that was **not
> observed**. It matters if your tool touches loop-affine state (an `aiohttp` session bound to the
> main loop, a `contextvar`, an asyncio primitive created elsewhere). **Resolving it needs one
> `print(threading.current_thread().name, id(asyncio.get_running_loop()))` inside a real tool call on
> a working install.** **Safe default meanwhile:** make tools self-contained — create clients inside
> `call()`, avoid sharing asyncio primitives across the boundary, and treat the tool body as if it
> were on an unknown thread.

---

## 11. Image attachments

Images arrived in `v0.2.0` (2026-06-08, commit `3ff9c60`), described in the release notes as *"This
update for WWDC 2026 adds the new Attachment API from the Foundation Models Swift framework to the
Python SDK."* Read §6.4 first — whether they work at all is decided at install time.

### 11.1 The prompt model

> ✅ **VERIFIED** — `prompt.py`:
>
> ```python
> PromptComponent = Union[str, Attachment]
> Prompt          = Union[PromptComponent, list[PromptComponent]]
> ```
>
> So a prompt is a string, a single attachment, or a **list mixing both** — and ordering is
> preserved, which is how you interleave text and images.

> ✅ **VERIFIED** — `ImageAttachment`:
>
> ```python
> class ImageAttachment(Attachment):
>     def __init__(self, path: Path, label: Optional[str] = None):
>         if not path.is_file():
>             raise ImagePromptError(
>                 f"Failed to add attachment to prompt: file does not exist at {path}")
> ```
>
> ⚠️ **`path` must be a `pathlib.Path`.** It calls `path.is_file()`; a plain `str` raises
> `AttributeError`, not a friendly error. `fm.ImageAttachment(path=Path("photo.jpg"))`.

Every usage form, straight from Apple's tests:

> ✅ **VERIFIED** — `tests/test_image_prompts.py`:
>
> ```python
> from pathlib import Path
> import apple_fm_sdk as fm
>
> # text + image
> image = fm.ImageAttachment(path=SIMPLE_IMAGE)
> response = await session.respond(["What do you see in this image? Describe it briefly.", image])
>
> # image only (a single component, not a list)
> response = await session.respond(fm.ImageAttachment(path=SIMPLE_IMAGE))
>
> # labelled attachments, referenced by name in the text
> image1 = fm.ImageAttachment(path=SIMPLE_IMAGE,     label="image-a")
> image2 = fm.ImageAttachment(path=TEXT_DENSE_IMAGE, label="image-b")
> response = await session.respond([
>     "I'm going to show you two labeled images.", image1, image2,
>     "What do you see in image-a and image-b?"])
>
> # guided generation with an image
> result = await session.respond(["Analyze this image:", image], generating=ImageAnalysis)
>
> # raw schema with an image
> generated_content = await session.respond(["Analyze this image:", image], schema=schema)
> ```
>
> Test resource formats present in the repo: `.jpeg` and `.png`.

The labelled form is the same mechanism as Swift's `Attachment(image).label(id)` — ✅ verified, the
shim calls `Attachment(imageURL: url)` then `.label(_:)`. In Swift, that label is the stable handle
for `ImageReference`-dependent output and tools. A 2026-08-20 device probe showed generic tool calls
can still run unlabeled, while the transcript records `label:nil` (see
[`../../part-02-foundation-models-everyday-api/references/05-image-input-and-attachments.md`](../../part-02-foundation-models-everyday-api/references/05-image-input-and-attachments.md)).
Python has no tool-call image path to trip over, but the same discipline applies: **if your text or
result must identify an image, label it and refer to the label.**

### 11.2 The iterable trap

> ⚠️ **`_composed_prompt_from_prompt` expands *any* non-string iterable.** ✅ Verified,
> `prompt.py`:
>
> ```python
> from collections.abc import Iterable
> if isinstance(prompt, Iterable) and not isinstance(prompt, str):
>     for element in prompt:
>         add_component(element)
> else:
>     add_component(prompt)
> ```
>
> A tuple works. A **generator** works — and is consumed, so a retry sends an empty prompt. A
> **`dict` iterates its keys**, silently sending only the keys. Pass a `list`.
>
> The error message for a bad component is also stale — it names `Image` and `IdentifiedImage`,
> classes removed in commit `da32e98` that no longer exist in the Python API:
> *"Unsupported prompt component type {type}, only str, Image, IdentifiedImage, and Attachment are
> supported"*. If you see that message, the types it lists are not the answer; `str` and `Attachment`
> are.

### 11.3 Image guidance carried over from the Swift side

Nothing about image *behaviour* differs between Python and Swift — same model, same door. Three
findings from the forums transfer directly:

- ✅ **Apple staff, thread 833642:** there is **no image-count limit per prompt** beyond the context
  window, **no resolution limit** (the framework may resize), and image input **does not change
  which model services the request**.
- ✅ **Session 241 (`241:26-27`):** larger images cost **more tokens and more latency**, even though
  any size and aspect ratio is accepted.
- ⚠️ **Community-reported, thread 838613:** image input is **unreliable for spatial localisation** —
  bounding boxes and coordinates. Use Vision for geometry and Foundation Models for semantics. One
  developer *infers* an 896 px longest-dimension downsample; that figure is **unverified** and is not
  an Apple statement.

### 11.4 And the reason images have their own memory section

Batch image work is where this SDK's memory model bites hardest, because an attachment holds a file
descriptor. That is §13, and if you plan to run more than a couple of hundred image prompts, read it
before you write the loop.

---

## 12. The cross-language workflow: Swift transcripts into Python

This is the feature that justifies the SDK's existence and the session barely mentions it. The
README does not bury it.

> ✅ **VERIFIED — `README.md:10-18`, the feature list, verbatim:**
>
> ```
> - Evaluate Swift Foundation Models app features by running batch inference and analyzing results from Python
> - Perform on-device inference with the system foundation model
> - Stream real-time text generation responses
> - Use guided generation with structured output schemas and constraints
> - Get type-safe responses using Python decorators for guided generation
> - Configure custom model settings for different model options
> - Process transcripts exported from Swift apps for quality analysis
> ```

The first and last bullets describe a genuine two-language pipeline: **your Swift app produces
transcripts; Python analyses them, replays them, and scores them.** Neither line appears in session
334.

### 12.1 Export from Swift

> ✅ **VERIFIED** — `docs/source/evaluation.rst:21-33`:
>
> ```swift
> import FoundationModels
>
> let transcript = session.transcript
> if let jsonData = try? JSONEncoder().encode(transcript),
>    let jsonString = String(data: jsonData, encoding: .utf8) {
>     try? jsonString.write(to: transcriptURL, atomically: true, encoding: .utf8)
> }
> ```

`Transcript` is `Encodable`, so this is three lines in a debug build, behind a developer setting, or
in a TestFlight diagnostics path. What you get out is a complete record of a real session on a real
device: instructions, prompts, responses, tool calls, tool outputs, and the model asset IDs that
served it.

### 12.2 The format

> ✅ **VERIFIED** — documented at `transcript.py:27-56` and confirmed by the fixtures:
>
> ```
> {
>   "version": 1,
>   "type": "FoundationModels.Transcript",
>   "transcript": { "entries": [ ... ] }
> }
> ```
>
> Each entry has an `id` (UUID string), a `role` ∈ `{"instructions", "user", "response", "tool"}`,
> and `contents` (an array of `{type, id, …}`). Role-specific fields:
>
> | Role | Carries |
> |---|---|
> | `instructions` | `tools` (array of function definitions), `contents` |
> | `user` | `contents`, `options`, `responseFormat` (e.g. `{"type": "jsonSchema", "jsonSchema": {"schema": {…}, "name": "Recipe"}}`) |
> | `response` | `toolCalls` (`[{name, arguments (a JSON *string*), id}]`), `contents`, `assets` |
> | `tool` | `toolName`, `toolCallID`, `contents` |
>
> Content objects are `{"type":"text","text":…}` or
> `{"type":"structure","structure":{"source":"Recipe","content":{…}}}`.

One field is a gift for anyone tracking model changes:

> ✅ **VERIFIED** — the `assets` array in fixture data carries real asset identifiers:
>
> ```
> "com.apple.fm.language.instruct_3b.fm_api_generic"
> "com.apple.fm.language.instruct_3b.fm_api_generic.draft"
> "com.apple.fm.language.instruct_3b.tokenizer"
> ```
>
> So the on-device model is a **3B instruct** model with a **draft** model — i.e. speculative
> decoding — and a tokenizer asset. This is observed in fixture data, **not documented prose**, and
> it is not a version-pinning API. But since there is no version-pinning API at all (Apple staff,
> thread 833642), **recording the `assets` array alongside your evaluation results is the closest
> thing available to knowing which model produced a number.** Do it. When a metric moves after an OS
> update, that column is your first check.

### 12.3 Analysing in Python — no SDK required

> ✅ **VERIFIED** — `examples/transcript_processing.py` (350 lines) is **pure Python and imports the
> SDK not at all.** Its useful shapes:
>
> ```python
> def extract_text_from_contents(contents):
>     for content in contents:
>         if content.get("type") == "text":
>             text_parts.append(content.get("text", ""))
>         elif content.get("type") == "structure":
>             text_parts.append(json.dumps(content.get("structure", {}).get("content", {})))
>
> entries              = transcript.get("transcript", {}).get("entries", [])
> instructions_entries = [e for e in entries if e.get("role") == "instructions"]
> tool_calls           = [tc for e in response_entries if "toolCalls" in e for tc in e["toolCalls"]]
> has_structured_output = any("responseFormat" in e for e in user_entries)
> ```
>
> It reads `tests/tester_schemas/test_transcript_full.json` and writes `transcript_analyses.jsonl`.

That "no SDK required" property is worth pausing on: **transcript analysis needs neither Apple
Intelligence, nor Apple silicon, nor macOS 26.** Transcripts are JSON. You can ship them off a
tester's device and analyse them on a Linux CI box with pandas. Only *replay* needs the SDK.

A practical starting point, extending Apple's shapes into a DataFrame:

```python
import json, glob
from pathlib import Path
import pandas as pd

def transcript_rows(path: Path) -> list[dict]:
    doc = json.loads(path.read_text())
    entries = doc.get("transcript", {}).get("entries", [])
    rows, pending_prompt = [], None
    for e in entries:
        role = e.get("role")
        text = " ".join(c.get("text", "") for c in e.get("contents", [])
                        if c.get("type") == "text")
        if role == "user":
            pending_prompt = text
        elif role == "response":
            rows.append({
                "file":       path.name,
                "prompt":     pending_prompt,
                "response":   text,
                "tool_calls": [tc.get("name") for tc in e.get("toolCalls", [])],
                "assets":     e.get("assets", []),      # §12.2 — which model answered
                "structured": any(c.get("type") == "structure" for c in e.get("contents", [])),
            })
            pending_prompt = None
    return rows

df = pd.DataFrame([r for p in map(Path, glob.glob("transcripts/*.json"))
                     for r in transcript_rows(p)])

print(df.groupby(df["tool_calls"].str.len() > 0)["response"].count())
print(df["response"].str.len().describe())
```

That gives you, from field data: how often tools fired, response-length distribution, how often the
structured path was taken, and which model asset served each turn. None of it requires a model call.

### 12.4 Replaying a transcript

> ✅ **VERIFIED** — `transcript.py` and `session.py`:
>
> ```python
> import json, apple_fm_sdk as fm
>
> with open("transcript.json") as f:
>     transcript_dict = json.load(f)
>
> transcript = await fm.Transcript.from_dict(transcript_dict)          # async
> session    = fm.LanguageModelSession.from_transcript(transcript,     # sync
>                                                      tools=[CalculatorTool(), WeatherTool()])
> response   = await session.respond("Calculate 15 * 24")
> ```
>
> Asymmetry worth memorising: **`Transcript.from_dict` is `async`** (it round-trips through the Swift
> decoder) while **`LanguageModelSession.from_transcript` is sync.**

> ⚠️ **You must re-pass your tools, and the documentation says so in two places.** ✅ Verified,
> `session.py:191-194` and `transcript.py:244-255`: *"Tool mentions loaded from a Transcript are
> **historical only**. You must **also** pass tool instances here if you want to allow the model to
> make new tool calls in this session."* A replayed session whose tools you forgot will read *about*
> past tool calls in its history and be unable to make new ones — and it will not tell you. The
> model simply answers without calling anything.

Also note: `from_transcript` has **no `instructions` parameter at all** — the transcript already
carries the instructions entry, so re-passing them is neither possible nor needed.

Decode failures are clean: ✅ verified, a bad transcript sets status code 6 and raises
`fm.DecodingFailureError`.

### 12.5 What this workflow is good for

Three concrete uses, in increasing order of value:

1. **Field triage.** A tester reports "it gave a weird answer". You have the exact prompt,
   instructions, tool calls and asset IDs. No reproduction needed to see what happened.
2. **Regression corpora.** Harvest N real transcripts, extract the prompts, and replay them through
   a modified prompt or schema. Now your evaluation set is *real user input*, not invented examples
   — the single biggest quality difference between a useful eval set and a decorative one.
3. **Cross-checking a Python reimplementation.** Extract the `responseFormat.jsonSchema.schema` from
   a `user` entry and feed those exact bytes to `json_schema=` (§9.7). Now the Python side is
   provably using the schema your app shipped, not a hand-port of it.

Point 3 closes the loop between §9.7 and this section, and it is the strongest argument for the raw
JSON-Schema path over `@fm.generable`.

> ⚠️ **A privacy note, because transcripts are the user's words.** A transcript contains the full
> text of everything the user typed and everything the model said, plus any tool inputs. Exporting
> them off-device is a data-collection decision, not a debugging convenience. Gate it behind explicit
> consent, redact before it leaves the device if you can, and apply the same retention policy you
> would to any user content. The `Transcript` type makes this *easy*, which is exactly why it needs a
> deliberate decision.

---

<a name="13--memory-across-the-boundary"></a>

## 13. ⚠️ Memory across the boundary

This is the section to read if you intend to run anything at batch scale. The Python/Swift boundary
has a hand-written ownership contract, and the repository's own artefacts tell you it is the area
Apple is most actively fixing: **a C shim, a custom build backend, two dedicated memory test files,
a `test_composed_prompt_cleanup.py` regression suite, and a HEAD commit titled "Release
composed_prompt pointer in all respond() paths."**[^python-sdk-memory]

### 13.1 The ownership contract

> ✅ **VERIFIED — documented verbatim in `c_helpers.py:33-36, 206-240`:**
>
> *"All C pointers passed from Swift to Python are assumed to be **retained** (ownership
> transferred). Python is responsible for releasing them **exactly once** when the object is
> deallocated."*
>
> *"When Swift passes a pointer via `passRetained`, it transfers ownership to Python with +1
> reference count. Python must release it exactly once in `__del__`. **Subclasses should NOT call
> `_retain()` in their `__init__` methods**, as this would create +2 references but only -1 release,
> causing memory leaks."*
>
> ```python
> class _ManagedObject:
>     def __init__(self, ptr):
>         if not ptr:
>             raise FoundationModelsError("Failed to create object")
>         self._ptr = ptr
>     def _retain(self):  lib.FMRetain(self._ptr)
>     def _release(self):
>         if hasattr(self, "_ptr") and self._ptr:
>             lib.FMRelease(self._ptr)
>     def __del__(self): self._release()
> ```
>
> Subclasses: `SystemLanguageModel`, `LanguageModelSession`, `GenerationSchema`, `GeneratedContent`,
> `Tool`. **Not** subclasses: `Transcript` (it borrows a session pointer) and `Property` (it releases
> its own pointer immediately after use).

So object lifetime is Python's refcounting driving Swift's. That works — right up until the moment
something is created on the native side and no Python object owns it.

### 13.2 The FD leak, and why the fix is not in any release

This is the best bug report in the corpus, and it comes with measurements.

> ✅ **VERIFIED** — `apple/python-apple-fm-sdk` issue **#17** (2026-07-03, @dmkharlamov), fixed by PR
> **#18** (merged 2026-07-07, commit `e868e60` — **the repository's HEAD**).
>
> **The mechanism:** `_respond_with_schema_from_json` released its `FMComposedPrompt`;
> `_respond_basic` and `_respond_with_schema` did not. One native `FMComposedPrompt` leaked **per
> call**, and because a composed prompt retains its `ImageAttachment`, **the image's file descriptor
> leaked with it.**
>
> **The reporter's measured failure, verbatim:** *"Under macOS, even though the soft file descriptor
> limit can be high (e.g., `1,048,575`), sequential predictions consistently fail after exactly
> **240–250 sequential calls with image attachments**. The system starts throwing a fatal
> `OSError: [Errno 9] Bad file descriptor` on any subsequent file system opens (including standard
> Python `open()`, `PIL.Image.open()`, or system plist reads)."*
>
> Their four-mode reproducer: only `--patched-recreate` (the fix **plus** a fresh session per
> iteration) held FDs flat at 7; every other mode grew 7 → 17 over ten iterations.
>
> (The reporter's three candidate explanations for the ~250 ceiling — an XPC concurrency cap, a
> `CFRunLoop` CFSocket cap, internal 256-slot arrays — are **their speculation**, unverified, and
> Apple never answered in-thread. The *symptom* is measured; the *cause* of the specific number is
> not.)

The fix itself is three identical seven-line inserts:

> ✅ **VERIFIED** — the complete diff of commit `e868e60` in `src/`:
>
> ```python
>                 if composed_prompt:
>                     try:
>                         lib.FMRelease(composed_prompt)
>                     except Exception:
>                         pass
> ```
>
> added to the `finally:` block of each of the three respond paths, plus
> `tests/test_composed_prompt_cleanup.py` (236 lines).

> ⚠️ **The fix is on `main` and in no tagged release.** ✅ Verified: `v0.2.1` was published
> 2026-06-29; the fix landed 2026-07-07. **`pip install apple-fm-sdk` today gives you the leak.**
>
> **If you are doing batch image work, install from git:**
>
> ```bash
> pip install "git+https://github.com/apple/python-apple-fm-sdk@main"
> ```
>
> and verify you got it — the marker is the `finally:` release above:
>
> ```bash
> python - <<'PY'
> import inspect, apple_fm_sdk.session as s
> src = inspect.getsource(s.LanguageModelSession._respond_basic)
> print("composed_prompt released:", "FMRelease(composed_prompt)" in src)
> PY
> ```

### 13.3 The second leak channel the fix does not close

> ✅ **VERIFIED** — the same reporter, and it is structural rather than a bug: *"The native
> `LanguageModelSession` transcript history **automatically retains previous prompts and
> attachments**. Therefore, in a single persistent session run, **previous attachment file
> descriptors are kept open throughout the session's lifetime**."*

That is not something a `finally:` block can fix — the session legitimately holds its history.
Which produces the rule:

**In an image batch loop, create a fresh session per item (or per small chunk).** You lose
conversational context, which for evaluation work you did not want anyway.

```python
from pathlib import Path
import apple_fm_sdk as fm

async def classify_images(paths: list[Path], instructions: str) -> list[str]:
    out = []
    for p in paths:
        session = fm.LanguageModelSession(instructions)   # fresh per item: see §13.3
        try:
            out.append(await session.respond(
                ["Describe this image in one sentence.", fm.ImageAttachment(path=p)]))
        except fm.ImagePromptError as e:
            out.append(f"<image unsupported: {e}>")       # §6.4
        except fm.GenerationError as e:
            out.append(f"<error: {e}>")
        finally:
            del session                                    # drop the ref; let __del__ run
    return out
```

### 13.4 ⚠️ The cleanup that crashes the interpreter

> ⚠️ **Never call `session._release()`.** ✅ **VERIFIED** — the same issue, verbatim: *"attempting to
> clear these channels by manually forcing the release of the native session resources (by calling
> the internal `session._release()` method in a loop) leads to **duplicate deallocation and
> double-free crashes (`EXC_BREAKPOINT / SIGTRAP` in `libswiftCore.dylib`)** because Python's garbage
> collector automatically runs the session destructor `__del__` which tries to release the raw
> `_ptr` again."*
>
> This is the obvious thing to try when you learn there is a leak, and it takes down the process. The
> supported lever is **dropping the Python reference** (`del session`, or letting it go out of
> scope) and, if you must be sure, `gc.collect()`. Apple's own test harness does exactly that: ✅
> verified, `conftest.py`'s autouse `cleanup_between_tests` fixture calls `gc.collect()` twice and
> then sleeps 0.1 s *"to allow native resources to be released."*

### 13.5 The leaks that remain

Read from the source at HEAD; **UNVERIFIED at runtime, but structurally unambiguous**:

| Leak | Where | Consequence |
|---|---|---|
| `stream_response` never releases its `composed_prompt` | `session.py:832-844` creates it; `:897-908` releases only the stream pointer | One `FMComposedPrompt` (and any image FDs) **per stream call**. The `e868e60` fix covered only the three `respond` paths. |
| `token_count(<prompt>)` never releases its `composed_prompt` | `core.py:394-399` | Same class. Bites hardest in a token-budgeting loop over a dataset. |
| `Transcript.from_dict` leaks an entire native session | `FMTranscriptCreateFromJSONString` returns a `passRetained` session; `Transcript` is not a `_ManagedObject` and has no `__del__` | **One leaked `LanguageModelSession` per transcript loaded.** Matters when you load thousands. |
| `from_transcript` drops the previous holder pointer | `transcript._update_session_ptr(ptr)` overwrites without releasing | Same class, compounding with the above. |

Practical shape of the mitigation, until these are fixed upstream: **process long jobs in chunks in a
subprocess.** It is inelegant and it is bulletproof — process exit releases everything, including
whatever the shim forgot.

```python
# driver.py — run N rows per worker process, so leaks cannot accumulate past a chunk
import subprocess, sys, json

def run_chunk(rows: list[dict]) -> list[dict]:
    proc = subprocess.run([sys.executable, "worker.py"],
                          input=json.dumps(rows), capture_output=True, text=True, check=True)
    return json.loads(proc.stdout)

CHUNK = 100            # well under the ~240-250 image ceiling of §13.2
results = [r for i in range(0, len(all_rows), CHUNK)
             for r in run_chunk(all_rows[i:i + CHUNK])]
```

### 13.6 How to know whether you are leaking

Apple ships a stress test. It is not a pytest test and will not run under `pytest`.

> ✅ **VERIFIED** — `tests/test_memory_stress.py` (152 lines) is a **standalone script**
> (`if __name__ == "__main__": sys.exit(asyncio.run(main()))`). It creates **1,000** model+session
> pairs, runs `await session.respond("What is 2+2?")` on each with `PAUSE_BETWEEN_REQUESTS = 0.1`,
> calls `gc.collect()` every 10 iterations, and **fails if RSS grows more than
> `MEMORY_LEAK_THRESHOLD_MB = 50`.** It needs `psutil`.
>
> ⚠️ Because `pyproject.toml` sets `python_files = ["test_*.py"]`, pytest **collects the file and
> runs nothing** — it defines no `test_*` functions. Invoke it directly:
>
> ```bash
> python tests/test_memory_stress.py
> ```

For your own workload, watch **both** RSS and file descriptors — the image case shows FDs
exhausting long before memory does:

```python
import os, psutil

def resource_snapshot(tag: str) -> None:
    p = psutil.Process(os.getpid())
    print(f"[{tag}] rss={p.memory_info().rss / 1e6:.1f} MB  fds={p.num_fds()}")

resource_snapshot("start")
# ... 100 iterations ...
resource_snapshot("after 100")     # fds should be flat, not climbing
```

A flat FD count across chunks is the signal that your session-recreation strategy is working. A
climbing one predicts `OSError: [Errno 9] Bad file descriptor` a few hundred iterations later — and
by then the error will surface in some unrelated `open()` call and look like a bug in your code.

One last honesty note about the fix's own test file:

> ⚠️ **`test_composed_prompt_cleanup.py`'s docstring describes a test that is not in the file.** ✅
> Verified: the docstring claims *"An integration regression test that drives real sequential
> structured generation requests with image attachments and asserts the process's open file
> descriptor count stays flat"*, and the file contains only four mocked unit tests. It imports `gc`
> and `os` for that test and never uses them. **So the FD behaviour is not covered by an automated
> test in the repository.** If FDs matter to you, measure them yourself.

That file is, however, the best example anywhere of **mocking the native layer** — useful if you want
to unit-test code that wraps the SDK without needing Apple Intelligence:

> ✅ **VERIFIED** — `tests/test_composed_prompt_cleanup.py`:
>
> ```python
> @pytest.fixture
> def mocked_session(monkeypatch):
>     release_calls = []
>     monkeypatch.setattr(session_module.lib, "FMRelease", lambda ptr: release_calls.append(ptr))
>     monkeypatch.setattr(session_module.lib,
>         "FMLanguageModelSessionCreateFromSystemLanguageModel", lambda *a, **k: ctypes.c_void_p(1))
>     monkeypatch.setattr(session_module, "Transcript", lambda ptr: None)
>     session = fm.LanguageModelSession()
>     composed_prompt_ptr = ctypes.c_void_p(0x1234)
>     monkeypatch.setattr(session, "_composed_prompt_from_prompt", lambda prompt: composed_prompt_ptr)
>     yield session, composed_prompt_ptr, release_calls
>     # The session wraps a fake pointer that was never really allocated by the native framework.
>     # Neutralize it before monkeypatch restores the real FMRelease, otherwise a later GC pass would
>     # call into native code with a bogus pointer and crash the process.
>     session._ptr = None
> ```
>
> Read that teardown comment twice. **A mocked session must have `_ptr` cleared before the mock is
> torn down**, or `__del__` hands a fake pointer to the real `FMRelease` and the interpreter dies at
> some unrelated later moment. It is the same hazard as §13.4 wearing a different hat, and it is the
> single most useful line in the file for anyone writing their own tests.

---

## 14. What the Python SDK cannot do

Consolidated so you can check feasibility before writing code. Every ❌ below was established by
reading `__all__` and the C header, not by failing to find something in the docs.

| Capability | Python | Evidence / note |
|---|---|---|
| On-device `SystemLanguageModel` inference | ✅ | README |
| Streaming (text) | ✅ | `examples/streaming_example.py`, `tests/test_streaming.py` |
| **Structured / partial streaming** | ❌ | Swift shim hard-codes `ResponseStream<String>`; `PartiallyGenerated` classes exist unwired. §8.5 |
| Guided generation via decorator | ✅ | §9.1 |
| Guided generation via raw JSON Schema | ✅ | §9.7 — the underrated one |
| Tool calling | ✅ | PR #9: *"we already support tool calling"* |
| **Intercepting / approving a tool call** | ❌ | issue #3: *"it doesn't seem possible to manually handle the tool calls"* |
| `GenerationOptions` | ✅ (v0.1.1+), **random sampling broken** | §8.6 |
| Transcript export / load / resume | ✅ (v0.1.1+) | §12 |
| Image attachments | ✅ (v0.2.0+), **SDK-27 + OS-27 gated** | §6.4, §11 |
| `context_size` / `token_count` | ✅ (v0.2.1+), **OS 26.4+ gated** | §7.3 |
| **Private Cloud Compute** | ❌ **not planned** | Apple member, issue #13: *"we do not currently plan to add support"*. Beta-era `fm` exposed PCC; stable macOS 27 does not. Use Swift unless a later CLI restores it. §2.6 |
| **`LanguageModel` protocol, BYO backends** | ❌ | One model type exists in `__all__`. |
| **Dynamic profiles, `historyTransform`, `summarizeHistory`** | ❌ | 27-era; SDK is 26-generation. §5.2 |
| **Mutable `session.transcript` / `transcript.history`** | ❌ | Transcripts are opaque dicts. |
| **`toolCallingMode`** | ❌ | Absent from `GenerationOptions`. |
| **`session.prewarm()`** | ❌ | Not in `__all__`. So the first call pays full model-load latency, every process. |
| **Adapters** | ❌ | Not present. (Also: custom adapters are dead in the 27 generation — Part 1.) |
| **`LanguageModelFeedback` / `logFeedbackAttachment`** | ❌ | `apple/python-apple-fm-sdk#5`, **open** |
| `Response` wrapper (`.rawContent`, `.transcriptEntries`, `.usage`) | ❌ | Bare values only. §5.4 |
| `Instructions` / `@PromptBuilder` builders | ❌ | Instructions are a plain `str`. |
| Rich `Tool.Output` | ❌ | Tools must return `str`; anything else is `str()`-ed. |
| `DynamicGenerationSchema(anyOf:)` / union schemas | ❌ | Only the `Property`+guide set the C shim exposes. |
| `SystemLanguageModel.UseCase` beyond `general` / `contentTagging` | ❌ | Only two cases bridged. |
| In-memory image data, non-image attachments | ❌ | `Attachment(imageURL:)`, file paths only. |

The missing feedback API deserves its own note because of *who* is asking for it:

> ✅ **VERIFIED** — issue #5, **still open**, verbatim: *"I have a suite of test cases running against
> FM, many of which are triggering erroneous guardrail violations even when configured with
> `PERMISSIVE_CONTENT_TRANSFORMATIONS`. I'd like to submit these to help improve the models, but
> **not having a Python API I can call from the notebook** means I probably won't, and if I cannot
> find a workaround, I will need to switch to using MLX and a different model."*

That is precisely the SDK's target user — someone running an evaluation suite in a notebook — hitting
the wall where the SDK's purpose (find quality problems) and its surface (no way to report them)
diverge. Apple's remedy for guardrail false positives is `LanguageModelFeedback`, which is Swift-only.
If you find one from Python, you have to reproduce it in Swift to report it.

Two error-hierarchy facts that catch people writing `except` clauses:

> ⚠️ **`PromptError` and `ImagePromptError` are NOT `FoundationModelsError` subclasses.** ✅ Verified,
> `prompt.py` — they inherit from plain `Exception`. So `except fm.FoundationModelsError` **does not
> catch an image failure.** Apple's own tests hedge with
> `pytest.raises((fm.ImagePromptError, fm.FoundationModelsError))`. Catch both explicitly.

> ⚠️ **Native cancellation arrives as status 255**, i.e. a generic `fm.GenerationError` with the
> message `"Operation cancelled"` / `"Stream cancelled"` — **not** `asyncio.CancelledError`. ✅
> Verified from the shim's `catch is CancellationError` branches. The Python-side handling usually
> wins the race; a batch runner should catch both anyway.

The full hierarchy, for reference:

> ✅ **VERIFIED** — `errors.py`:
>
> ```
> Exception
> └── FoundationModelsError
>     ├── GenerationError
>     │   ├── ExceededContextWindowSizeError      (code 1)
>     │   ├── AssetsUnavailableError              (2)
>     │   ├── GuardrailViolationError             (3)
>     │   ├── UnsupportedGuideError               (4)
>     │   ├── UnsupportedLanguageOrLocaleError    (5)
>     │   ├── DecodingFailureError                (6)
>     │   ├── RateLimitedError                    (7)
>     │   ├── ConcurrentRequestsError             (8)
>     │   └── RefusalError(message, debug_description=None, explanation_entries=None)   (9)
>     ├── InvalidGenerationSchemaError            (10)
>     │   └── GenerableDecoratorError             (not exported)
>     └── ToolCallError(tool_name, underlying_error)   (never raised — §10.3)
>
> Exception
> └── PromptError                                  (NOT a FoundationModelsError)
>     └── ImagePromptError
> ```
>
> Two of those you should not expect to see, per `docs/source/api/errors.rst`: *"**RateLimitedError**
> — Rate limits do not apply to the on-device `SystemLanguageModel` on macOS so you should not
> encounter this error."* and *"**ConcurrentRequestsError** — The python SDK does not enforce
> concurrency limits so you should not encounter this error."* Also useful: *"**RefusalError** —
> Raised when the model refuses to generate a response **specifically for safety reasons on a
> generable output**"*, and *"**InvalidGenerationSchemaError** is unique to the Python SDK and does
> not have a direct Swift equivalent since it means a schema failed to compile in the underlying
> Swift."*

The idiomatic catch ladder, from the SDK's own docs — **specific first, general last**:

```python
try:
    response = await session.respond("Your prompt here")
except fm.ExceededContextWindowSizeError:
    print("Prompt is too long")
except fm.GuardrailViolationError as e:
    print(f"Caught GuardrailViolationError: {e}")
except fm.GenerationError as e:
    print(f"Generation error: {e}")
```

(✅ verbatim from `docs/source/basic_usage.rst`. Add `except fm.ImagePromptError` alongside it if you
send images — it will not be caught by any of the three above.)

---

## 15. The evaluation pipeline (session 334's case study)

This is what the Python SDK is *for*, and Apple built a full case study around it. The scenario:

> ✅ **VERIFIED** (spoken, `334:115-117`): a grocery-ordering app that predicts *"what users would
> like to add to their cart based on their previous orders"*, with two correctness requirements —
> *"the output **reliably works off of the previous orders**"* and *"the prediction **accounts for
> any items already in the cart**"*.

### 15.1 The pipeline, as described

> ✅ **VERIFIED** (spoken, `334:124-144`), seven steps:
>
> 1. *"First, I used **a large server model to generate evaluation data**. I now have some **inputs**,
>    and for each of those, **data on what I expect in the output**."*
> 2. *"I'll write **a number of implementations that use different prompts**."*
> 3. *"for each of my evaluation inputs, I'll **generate outputs using each of those different
>    implementations**."*
> 4. *"I'll then save this data as **rows in a Pandas DataFrame**."*
> 5. *"I've designed some **judge functions that rely on a server model**. They will **score each
>    output on the criteria of my choice**."*
> 6. *"I'll then save those **metrics in the Pandas DataFrame**."*
> 7. *"I can now **generate some charts** to see them visually."* (matplotlib)

Note step 1 and step 5: **the eval data and the judge both come from a large server model, not from
the on-device model.** The on-device model is the *subject* under test, never the examiner. That
separation is the load-bearing design decision — and it is the same one Apple's Book Tracker sample
makes on the Swift side with a model judge (Part 6).

Also note what the SDK does *not* provide here: no `Evaluator`, no metric types, no dataset
abstraction. **The pipeline is ordinary Python.** The SDK contributes exactly one thing — faithful
on-device inference — and pandas, matplotlib and your judge do the rest.

### 15.2 The findings, which are the actually valuable part

> ✅ **VERIFIED** (spoken, `334:148-152`):
>
> *"First, by looking at the **errors generated by setup**, I can see that **the detailed prompt
> leads to a high percentage of generation errors**. **This can happen, for example, when we reach
> the model's max context window size.**"*
>
> *"Next, we can see that **the two less detailed prompts tend to lead to excess items added to the
> cart**, while **the more detailed one has less excess items**. However, **with the more detailed
> prompts, we tend to miss more items that were expected**."*
>
> *"The **first prompt also tends to lead to more hallucinated items** added to the cart."*

Three prompt variants were compared (`334:135-139`): *"a **very minimal** prompt"*, *"a **more
descriptive** prompt"*, and *"the **most comprehensive** prompt … a list of rules"*.

**The lesson is counter-intuitive and it is Apple's own data: more prompt is not monotonically
better.** Going from minimal to comprehensive:

| Metric | Direction |
|---|---|
| Hallucinated items | **improves** (fewer) |
| Excess items | **improves** (fewer) |
| **Missed expected items** | **gets worse** — precision bought at the cost of recall |
| **Generation errors** | **gets much worse** — the prompt eats the 4K context window |

That last row is the one people do not anticipate. On a 4,096-token window, prompt engineering is
**not free**: every rule you add is tokens taken from the input and the response. A prompt that
tests well on short inputs starts throwing `ExceededContextWindowSizeError` on long ones, and the
error rate is a *quality* metric, not an infrastructure one. Measure it as one.

> ✅ **VERIFIED** (`334:153-157`) — the velocity argument for doing this in Python at all: *"With
> Python, I can make those iterations quickly **right from my notebook without having to rebuild the
> whole project**."*

### 15.3 A working skeleton

Everything below is ordinary Python plus the SDK calls established earlier in this guide. It
incorporates the workarounds from §8.3 and §8.6, because a reproducibility study built on broken
sampling measures nothing.

```python
"""Compare prompt variants on the on-device model. Python 3.10-3.13, apple-fm-sdk from main."""
import asyncio, json, time
from typing import Optional
import pandas as pd
import apple_fm_sdk as fm


# ---- 1. the subject under test: N implementations differing only in instructions ----

VARIANTS = {
    "minimal":       "Suggest grocery items.",
    "descriptive":   ("Suggest grocery items the user is likely to want, based on their previous "
                      "orders. Do not suggest items already in the cart."),
    "comprehensive": ("You suggest grocery items.\n"
                      "Rules:\n"
                      "1. Base every suggestion on an item in the user's previous orders.\n"
                      "2. Never suggest an item already in the cart.\n"
                      "3. Never invent products that do not appear in the order history.\n"
                      "4. Suggest at most five items.\n"
                      "5. Prefer items ordered more than once.\n"),
}

@fm.generable("Suggested grocery items")
class Suggestions:
    items: list[str] = fm.guide("Suggested grocery item names", max_items=5)


GREEDY = fm.GenerationOptions(sampling=fm.SamplingMode.greedy())   # §8.6: greedy actually works


async def respond_typed(session, prompt, cls, options=None):
    """§8.3 workaround: respond(generating=) silently drops options."""
    content = await session.respond(prompt, schema=cls.generation_schema(), options=options)
    return cls._from_generated_content(content)


async def run_one(variant: str, row: dict) -> dict:
    session = fm.LanguageModelSession(VARIANTS[variant])           # §13.3: fresh session per row
    prompt = json.dumps({"previous_orders": row["previous_orders"], "cart": row["cart"]})
    t0 = time.perf_counter()
    try:
        result = await respond_typed(session, prompt, Suggestions, options=GREEDY)
        return {"variant": variant, "case_id": row["id"], "output": result.items,
                "error": None, "latency_s": time.perf_counter() - t0}
    except fm.ExceededContextWindowSizeError as e:
        # §15.2 — this is a QUALITY metric, not an infrastructure hiccup. Count it.
        return {"variant": variant, "case_id": row["id"], "output": None,
                "error": "context_window", "detail": str(e),
                "latency_s": time.perf_counter() - t0}
    except fm.GenerationError as e:
        return {"variant": variant, "case_id": row["id"], "output": None,
                "error": type(e).__name__, "detail": str(e),
                "latency_s": time.perf_counter() - t0}


# ---- 2. deterministic metrics: cheap, exact, and no judge required ----

def score_row(row: dict, expected: list[str], catalogue: set[str]) -> dict:
    if row["output"] is None:
        return {"missed": None, "excess": None, "hallucinated": None}
    got, want = set(row["output"]), set(expected)
    return {
        "missed":       len(want - got),
        "excess":       len(got - want),
        "hallucinated": len([i for i in got if i not in catalogue]),   # not in the catalogue at all
    }


# ---- 3. drive it ----

async def main(cases: list[dict], catalogue: set[str]) -> pd.DataFrame:
    rows = []
    for case in cases:
        for variant in VARIANTS:                  # sequential: §8.2, inference does not parallelise
            r = await run_one(variant, case)
            r.update(score_row(r, case["expected"], catalogue))
            rows.append(r)
    return pd.DataFrame(rows)


if __name__ == "__main__":
    cases = json.load(open("eval_cases.json"))
    catalogue = set(json.load(open("catalogue.json")))
    df = asyncio.run(main(cases, catalogue))
    df.to_parquet("results.parquet")

    summary = df.groupby("variant").agg(
        error_rate   = ("error",        lambda s: s.notna().mean()),
        missed       = ("missed",       "mean"),
        excess       = ("excess",       "mean"),
        hallucinated = ("hallucinated", "mean"),
        p50_latency  = ("latency_s",    "median"),
    )
    print(summary)
```

Four decisions in that skeleton are worth naming, because each is a lesson from earlier sections:

**Greedy sampling, via the schema path.** `generating=` drops options (§8.3) and random sampling is
broken (§8.6). Greedy through `schema=` is the only combination that is actually reproducible today.

**Errors are a metric column, not an exception to swallow.** `error_rate` sits alongside quality
metrics because Apple's own finding is that the best-sounding prompt had the worst error rate.

**Deterministic metrics before a judge.** Set arithmetic against a known catalogue catches
hallucinations exactly and for free. Bring in a judge model only for the criteria arithmetic cannot
express ("is this suggestion *sensible*?"). Judges are themselves fallible and need calibration —
which is Part 6's subject, and where Apple's Book Tracker sample hand-rolls Cohen's κ to measure
judge–human agreement.

**A fresh session per row.** §13.3. It also removes cross-row contamination, which you did not want
in an evaluation anyway.

### 15.4 Where this hands off to Part 6

The Python pipeline and the Evaluations framework are the same activity in two languages, and Apple
says which audience each is for:

> ✅ **VERIFIED** (spoken, `334:120-123`): *"To evaluate their prompt and iterate, Swift developers
> can leverage the **Evaluations framework**. It's **available with Xcode 27**, and it makes it easy
> to create evaluations, and **track the accuracy of your features across multiple iterations**. But
> many **data scientists might be more familiar with Python than with Swift**. If you fall under this
> scenario, let me show you how I can perform this analysis in Python by **using the Python SDK from
> a Jupyter Notebook**."*

| | Python SDK pipeline | Evaluations framework |
|---|---|---|
| Requires | macOS 26.0+, Python 3.10–3.13 | **Xcode 27** |
| Language | Python | Swift |
| Provides | inference only — you build everything else | evaluators, metrics, judges, diffable runs |
| Model coverage | **on-device only** | whatever your app uses, incl. PCC and BYO backends |
| Reproducible sampling | ⚠️ greedy only, per §8.6 | full `GenerationOptions` |
| Judge calibration | roll your own | Apple's sample demonstrates κ-calibration |
| Best when | your team lives in notebooks; you are comparing prompts against the on-device model | you are shipping a Swift feature and want CI-integrated, diffable quality tracking |

**Choose Python when the analysis is the hard part and the model is simple. Choose Evaluations when
the model configuration is the thing you are evaluating.** If your Swift feature uses dynamic
profiles, PCC or a BYO model, the Python SDK cannot even instantiate it (§5.2) — the choice is made
for you.

Continue in [`../../part-06-evaluations/`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md) for the Swift side: the
`Evaluator` two-argument closure, `ModelSubject<T>`, `ModelJudgePrompt`, `ToolCallEvaluator`, and the
full ladder from `#Playground` through heuristics and a model judge to a κ-calibrated, diffable
evaluation run.

---

## 16. Failure-mode index

Sorted by what you actually see. The split that matters is the second table: **defects that do not
throw** are the ones that cost days.

### 16.1 It throws, and the message names the cause

| Symptom | Cause | § |
|---|---|---|
| `SwiftToolingError: The active developer directory is set to Command Line Tools …` | `pip install` with CLT only; needs full Xcode.app. **Open issue `apple/python-apple-fm-sdk#6`.** | §6.2 |
| `…Then open Xcodeat least once…` (note the missing space) | Fingerprint of `apple-fm-sdk` ≤ 0.2.1's build backend | §6.2 |
| `macOS version {v} found, but version 26.0 or higher is required` | Build preflight, check 1 | §6.2 |
| `ImportError: Foundation Models C bindings not found. Please ensure _foundationmodels_ctypes.py is available.` | `_ctypes_bindings.py` missing — the build did not complete. **The filename in the message is stale**; the real file is `_ctypes_bindings.py`. | §6.1 |
| `Failed to add attachment to prompt: the Xcode version used to build this package doesn't include macOS 27 SDKs` | Built without `FM_HAS_MACOS_27_SDK`. Rebuild on Xcode 27. | §6.4 |
| `Failed to add attachment to prompt: the current OS does not support attachment prompts` | Built with the 27 SDK, running on macOS 26 | §6.4 |
| `Failed to add attachment to prompt: file does not exist at …` | `ImageAttachment` path check | §11.1 |
| `AttributeError: 'str' object has no attribute 'is_file'` | You passed a `str` to `ImageAttachment(path=)`; it needs a `pathlib.Path` | §11.1 |
| `Token counting requires macOS 26.4, iOS 26.4, or visionOS 26.4 or later.` | `token_count()` below 26.4. `context_size` still works. | §7.3 |
| `TypeError: Generic list types must specify an element type, for example, List[str]` | A bare `list` annotation in a `@fm.generable` class | §9.4 |
| `fm.UnsupportedGuideError` at `respond()` time | A guide/type mismatch — validated on the Swift side, not at decoration | §9.5 |
| `fm.InvalidGenerationSchemaError` | Schema failed to compile in Swift. Unique to the Python SDK. | §9.5 |
| `ValueError: … is not a Generable type. Use @generable decorator.` | Missing `@fm.generable` | §9.1 |
| `ValueError: Cannot specify both 'generating' and 'schema' arguments` | Pick one | §8.3 |
| `ValueError: Provide either a value or instructions to token_count(), not both` | `token_count` dispatch | §7.3 |
| `fm.ExceededContextWindowSizeError` | 4K window; instructions + prompt + tools + schema + response all count | §7.3, §15.2 |
| `fm.DecodingFailureError` | Malformed transcript JSON, or a truncated structured response | §12.4, §8.6 |
| `OSError: [Errno 9] Bad file descriptor` after ~240–250 image calls | The composed-prompt FD leak. Install from `main` **and** recreate sessions. | §13.2 |
| `EXC_BREAKPOINT / SIGTRAP in libswiftCore.dylib` | You called `session._release()` manually. Never do that. | §13.4 |
| `TypeError` from `fm.SystemLanguageModel(temperature=…)` | Those parameters do not exist; the docstring is wrong | §7.2 |
| Coroutine printed instead of text | Missing `await`. Everything is async. | §5.4 |
| `FileNotFoundError` on `tests/tester_schemas/…` | pytest run from somewhere other than the repository root | §6.5 |

### 16.2 ⚠️ It does **not** throw — the expensive ones

| Symptom | Actual cause | § |
|---|---|---|
| **Temperature / sampling / max-tokens have no effect** on typed generation | `respond(generating=…)` **drops `options`** (`session.py:473`) | §8.3 |
| **A fixed seed does not reproduce output** | `top_k`/`top_p`/`seed` are serialised as **strings**; Swift casts them as numbers; the cast fails and sampling is never assigned | §8.6 |
| **A field you declared optional is required** | `is_optional` is `"Optional" in str(type)`. `int \| None` never matches; on **Python 3.14** even `Optional[int]` stops matching | §9.3 |
| **A schema type description never reaches the model** | `@fm.generable("…")` stores `_generable_description` and nothing reads it | §9.6 |
| **A guide on a `bool` field does nothing** | Swift builds bools with `.init(type: Bool.self)` — no guides | §9.4 |
| **`List[List[str]]` behaves like `List[str]`** | The `array<(\w+)>` regex does not match nested generics; falls back | §9.4 |
| **`element=` wrapping on `min_items`/`max_items` is ignored** | Those C functions have no `wrapped` parameter; Python passes one anyway | §9.5 |
| **A tool raised and nothing propagated** | Exceptions are stringified to `"Tool error: …"` and returned **to the model** | §10.3 |
| **`except fm.ToolCallError` never fires** | The Python layer never raises it | §10.3 |
| **A tool's validation is skipped** | Bare `assert`s, disabled under `python -O` | §10.5 |
| **A session hangs with no error** | A tool `call()` that never returns leaves the Swift continuation unresumed | §10.4 |
| **A replayed session never calls tools** | Tools in a loaded transcript are **historical only**; pass instances to `from_transcript` | §12.4 |
| **`await model.token_count([])` returns a strange number** | Empty list takes the **tools** path, not the prompt path | §7.3 |
| **A `dict` prompt sends only the keys** | Any non-`str` iterable is expanded component-wise | §11.2 |
| **A generator prompt is empty on retry** | Same expansion — the generator was consumed | §11.2 |
| **A missing property reads as `None`** | `value(T, for_property=…)` returns `None`, never `KeyError` — a typo looks like an omission | §9.8 |
| **`value(int, …)` returns a string** | `value()` does not coerce; the coercion helper is dead code | §9.8 |
| **`fm.__version__` never changes** | Hard-coded `"0.1.0"` at `0.2.1`. Use `importlib.metadata`. | §5.1 |
| **Image support silently absent** | Decided by the build machine's SDK; `None` from SDK detection means "off" | §6.4 |
| **A stream and a `respond()` interleave** | `stream_response` does not take the session lock | §8.5 |
| **FDs climb across a batch** | The transcript retains attachments for the session's lifetime | §13.3 |
| **Availability says Apple Intelligence is off when it is on** | The Siri-enablement defect, **acknowledged by Apple as a bug** on thread 836760 | §7.1 |
| **Yesterday's results do not reproduce today** | The on-device model ships with the OS; no version pinning exists | §4.5, §12.2 |
| **`fm respond` output is prose, not JSON** | A schema flag that did not apply. Validate shape, not just parseability. | §3.1 |

---

## 17. Quick reference

### 17.1 Version gates

| Thing | Floor | Note |
|---|---|---|
| `fm` CLI | **macOS 27.0** | Preinstalled. Does not exist on 26. |
| `apple-fm-sdk` runtime | **macOS 26.0**, Python 3.10+, Apple silicon, Apple Intelligence on | Pin Python **≤3.13** (§9.3) |
| `apple-fm-sdk` build | **macOS 26.0 + full Xcode.app ≥ 26.0** | CLT rejected — open issue #6 |
| Python SDK image attachments | **macOS 27 SDK at build time + macOS 27 at runtime** | Both halves required |
| Python SDK `token_count()` | **macOS / iOS / visionOS 26.4** | `context_size` is **not** gated |
| Swift `SystemLanguageModel` | iOS / macOS / visionOS 26.0 | The thing being bridged |
| Evaluations framework | **Xcode 27** | The Swift alternative to §15 |
| PCC from Python | **not available in the SDK; no stable CLI route currently advertised** | Use Swift's PCC surface; beta-era `fm` evidence is historical |

### 17.2 The thirty-second Python program

```python
import asyncio
import apple_fm_sdk as fm

async def main():
    model = fm.SystemLanguageModel()
    ok, reason = model.is_available()
    if not ok:
        print(f"unavailable: {reason.name}")     # .name, not the enum repr
        return
    session = fm.LanguageModelSession("You are a helpful assistant.")
    print(await session.respond("What is the capital of France?"))
    print(await session.respond("What is its population?"))   # context carries over

asyncio.run(main())
```

### 17.3 Typed output, done correctly

```python
from typing import List, Optional
import apple_fm_sdk as fm

@fm.generable("Habitat information")
class Habitat:
    location: str   = fm.guide("Geographic location")
    climate: str    = fm.guide("Climate type", anyOf=["temperate", "tropical", "arid", "polar"])

@fm.generable("Hedgehog profile")
class Hedgehog:
    name: str            = fm.guide("Hedgehog name")
    age: int             = fm.guide("Age in years", range=(0, 10))
    weight: float        = fm.guide("Weight in grams", range=(200.0, 1200.0))
    habitat: Habitat     = fm.guide("Natural habitat")
    nicknames: Optional[List[str]] = fm.guide("Known nicknames", max_items=3)   # Optional[...], never `| None`

session = fm.LanguageModelSession("Extract hedgehog information from the prompt")

# §8.3: go through schema= so options actually apply.
content  = await session.respond(
    "Spike is a 3-year-old hedgehog weighing 800 grams, living in temperate European woodlands.",
    schema=Hedgehog.generation_schema(),
    options=fm.GenerationOptions(sampling=fm.SamplingMode.greedy()),
)
hedgehog = Hedgehog._from_generated_content(content)
print(hedgehog.name, hedgehog.habitat.climate)
```

### 17.4 Batch-safe loop skeleton

```python
import gc
import apple_fm_sdk as fm

async def batch(prompts, instructions, chunk=100):
    out = []
    for i, p in enumerate(prompts):
        session = fm.LanguageModelSession(instructions)   # fresh per item — §13.3
        try:
            out.append(await session.respond(p))
        except fm.ExceededContextWindowSizeError:
            out.append(None)                              # a metric, not a crash — §15.2
        except fm.GenerationError as e:
            out.append(f"<error: {e}>")
        finally:
            del session                                   # never session._release() — §13.4
        if i % chunk == chunk - 1:
            gc.collect()
    return out
```

### 17.5 `fm` CLI — what is known, in one table

| | Status |
|---|---|
| Ships preinstalled with macOS 27 | ✅ verified (two sessions) |
| Installed at `/usr/bin/fm` | ✅ project-verified 2026-08-17 on macOS 27 beta 5 |
| `fm respond`, `fm chat`, `fm schema`, `fm schema object` | ✅ verified (spoken names) |
| `fm serve` → Chat Completions endpoint | ✅ verified (Apple member, GitHub); subcommand corroborated in a `--help` paste |
| Full subcommand list | ✅ stable project verification: **seven**; beta 5 had eight |
| `available`, `count-tokens`, `license` exist | ✅ stable project-verified 2026-09-16; beta-only `quota-usage` is absent |
| `respond` flags and short forms | ✅ fully captured, including `-m`, `-i`, `-g`, `-v`, `-h` |
| `fm schema object` grammar | ✅ fully captured for this seed: scalar, nested object, `anyOf`, array, description, optional |
| `/model`, `/save` in `fm chat` | ✅ beta-era session evidence; stable interactive surface remains untested |
| Other slash commands | 🔴 **unknown** (and do not borrow `fmx`'s — §3 item 4) |
| Default model = on-device | ✅ stable help advertises only `system`; PCC was a beta-5 CLI option and is absent on stable build `26A428` |
| Structured output arrives as JSON on stdout | ✅ verified |
| `fm serve` transport and advertised endpoints | ✅ TCP host/port or Unix socket; health, models, chat completions. Authentication and field-level compatibility remain untested. |
| Exit codes, stderr discipline, streaming | 🔴 **unknown** |
| Behaviour when Apple Intelligence is disabled | 🔴 **unknown** |
| **Resolution** | Managed beta-5 capture: `notes/sdk-interfaces/fm-help-27.0.txt`; stable drift: `notes/PLATFORM-UPGRADE-VALIDATION-2026-09-16.md`. |

### 17.6 Five rules that prevent most of the pain

1. **`await` everything**, and pin Python to 3.10–3.13.
2. **Use `Optional[X]`, never `X | None`**, in any `@fm.generable` class.
3. **Use `schema=` + `greedy()`**, not `generating=`, whenever options must apply or results must
   reproduce.
4. **Fresh session per batch item**; `del` it; never `_release()`.
5. **Install from `main`** for anything image-heavy, and check the composed-prompt fix is present.

---

## 18. Sources, and how to close the gaps yourself

### 18.1 What this guide is built on

**The repository, cloned and read on disk** — `github.com/apple/python-apple-fm-sdk`, branch `main`,
**HEAD = `e868e60`**, read 2026-07-27. This is the strongest evidence in the guide: shipping,
compiling, Apple-authored source.

Read in full: `README.md`, `pyproject.toml`, `MANIFEST.in`, `build_backend.py`; all fifteen modules
under `src/apple_fm_sdk/` (`__init__`, `core`, `session`, `prompt`, `transcript`, `tool`,
`generable`, `generable_utils`, `generation_schema`, `generation_property`, `generation_guide`,
`generation_options`, `errors`, `type_conversion`, `c_helpers`);
`foundation-models-c/Package.swift`; the 146-line C header
`FoundationModelsCBindings/include/FoundationModels.h`; all 1,831 lines of
`FoundationModelsCBindings.swift`; `Sources/fm-c-example/main.c`;
`Tests/FoundationModelsCBindingsTests/BasicSystemModelTests.swift`; the three files in `examples/`;
the eight `docs/source/*.rst` pages and eight `docs/source/api/*.rst` pages; the `bin/` scripts;
`tests/conftest.py` and thirteen test files; the Swift/Python parity fixtures
`tests/tester_schemas/schemas.{swift,py}` and six JSON schema fixtures.

**The repository's GitHub history** — releases `v0.1.0-beta.1` → `v0.2.1`, all ten commits, and the
issue/PR bodies and comments for **issues #1–#6, #11–#13, #16, #17** and **PRs #7–#10, #14, #15,
#18**, with diffs read for #9, #14, #15 and #18. Two items here are load-bearing and appear nowhere
else in the corpus: **issue #13** (the Apple member's beta-era "no PCC in Python; use `fm` / `fm serve`"
guidance, superseded on stable macOS) and
**issue #17 / PR #18** (the FD leak, its measurement, and the fix that is not in a release).

**WWDC26 transcripts** — session **334** *Foundation Models on macOS* (`fm` CLI + Python SDK), Eric
Gourlaouen, and session **241** *What's new in Foundation Models*. These are **spoken-word**
transcripts. Code and command lines shown on screen were *described*, not dictated. That is the
entire reason §2 and §3 look the way they do.

**Apple Developer Forums** — thread 831404 (the Simulator "punches out to macOS" answer, Apple
Designer), 790736 (~4,000-token window, DTS), 817502 (`tokenCount(for:)` shipped in 26.4, DTS),
833642 (no model version pinning; image limits; schema limits — Apple staff), 836760 (the
Siri-availability defect, **acknowledged as a bug by an Apple Frameworks Engineer**), 838613
(community-reported image localisation unreliability).

**Measured during the research pass, not quoted from anywhere:** the `str(Optional[int])` behaviour
across Python 3.11 / 3.12 / 3.13 / 3.14 (§9.3), via
`python3.N -c "from typing import Optional; print(str(Optional[int]))"`.

### 18.2 Precedence, and where sources disagree

The ladder used throughout: **shipping source read on disk > Apple documentation > Apple-staff forum
and GitHub answers > WWDC transcripts > community reports.** Three conflicts were resolved by it,
and each is called out where it occurs:

1. **The SDK's OS floor.** Session 334 frames the SDK as new for macOS 27; the repository requires
   macOS 26.0+ and its Swift package declares `.macOS(.v26)`. **The repository wins** (§5.2), and
   the consequence — no 27-era API surface — is the guide's central Python claim.
2. **Tool calling.** Session 334 says the SDK supports it; the README's feature list does not
   mention it. **The session is right**: PR #9's author states *"we already support tool calling"*
   and there are 626 lines of tests. The README is incomplete (§10).
3. **`fm.respond` vs `session.respond`.** The presenter says *"I pass it to `fm.respond` as the
   generating argument"* (`334:110-111`); the README shows `session.respond(..., generating=Cat)`.
   **The README wins** — `respond` is a session method. Read the presenter's phrasing as shorthand.

Two internal contradictions inside the SDK itself are also flagged rather than smoothed over: the
`SystemLanguageModel(temperature=…)` docstring that cannot work (§7.2), and
`test_composed_prompt_cleanup.py`'s docstring describing a test that is not in the file (§13.6).

### 18.3 The open questions, and exactly what closes each

Ranked by how much they would improve this guide.

| # | Open question | What resolves it |
|---|---|---|
| 1 | ~~The entire `fm` command line~~ ✅ **RESOLVED 2026-08-17** for beta 5; runtime-only residue: interactive slash commands, refusal/error exits, and field-level `serve` compatibility | Focused live calls against later macOS 27 seeds |
| 2 | Is the **random-sampling seed** genuinely dead? | Two `respond()` calls with `SamplingMode.random(top=1, seed=1)` on a working install; diff the output (§8.6) |
| 3 | Does `respond(generating=…, options=…)` really drop options? | Same install: one greedy call via `generating=` and one via `schema=`, repeated; compare variance (§8.3) |
| 4 | Does **Python 3.14** actually make every property required? | Build the SDK on 3.14 and dump `MyType.generation_schema().to_dict()["required"]` (§9.3) |
| 5 | Does PyPI ship a **prebuilt wheel** for any platform? | `pip download apple-fm-sdk --no-deps -d /tmp/x && ls /tmp/x` (§6.3) |
| 6 | Which **thread** does a tool callback land on? | One `print(threading.current_thread().name, ...)` inside a live tool call (§10.6) |
| 7 | Is `fm` gated on Apple Intelligence enablement, and does the Siri defect affect it? | Run `fm respond` on a macOS 27 machine with Apple Intelligence off (§2.1, §7.1) |
| 8 | Does `fm serve` expose tools, streaming or `response_format`? | `curl` a running `fm serve` with a Chat Completions tools payload (§2.6) |

None of those is answerable from the corpus. All eight are answerable in an afternoon by someone
with a macOS 27 machine and a working install — and items 2, 3 and 4 change advice this guide
currently gives with a "read from source, not executed" hedge.

### 18.4 Where to go next

- **The Swift side of everything here:**
  [`../../part-02-foundation-models-everyday-api/`](../../part-02-foundation-models-everyday-api/README.md)
  — sessions, guided generation, tools, images, availability and errors, all with the 27-era surface
  the Python SDK lacks.
- **What the Python SDK cannot reach:**
  [`../../part-03-context-profiles-agentic/`](../../part-03-context-profiles-agentic/README.md) (dynamic
  profiles, transcript history) and
  [`../../part-04-beyond-the-built-in-model/`](../../part-04-beyond-the-built-in-model/README.md) (PCC, BYO
  models, the `LanguageModel` protocol). If your feature lives in either, evaluate it in Swift.
- **The evaluation story proper:** [`../../part-06-evaluations/`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md) —
  where §15's hand-rolled pandas pipeline becomes `Evaluator`, `ModelSubject`, model judges and
  κ-calibration, and where the "no model version pinning" problem is confronted head-on.
- **Gating and the availability defect:**
  [`../../part-01-orientation-and-gating/references/02-platform-and-version-gating.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/references/02-platform-and-version-gating.md).
- **The other non-Swift door:** if what you actually want is a local OpenAI-compatible server today
  rather than whenever `fm serve` is documented, [`../../part-12-mlx-python/`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/README.md)
  covers `mlx_lm.server` — and Part 4 covers plugging that back into Foundation Models from Swift via
  `ChatCompletionsLanguageModel`, which closes the circle this guide opened in §2.6.

[^python-sdk-memory]: The pinned first-party source includes the cleanup regression in
    [`test_composed_prompt_cleanup.py`](https://github.com/apple/python-apple-fm-sdk/blob/e868e60811aa0706feb2ccb33cfe7e27626287b7/tests/test_composed_prompt_cleanup.py)
    and commit [`e868e60`](https://github.com/apple/python-apple-fm-sdk/commit/e868e60811aa0706feb2ccb33cfe7e27626287b7),
    which releases the composed-prompt pointer across response paths.
