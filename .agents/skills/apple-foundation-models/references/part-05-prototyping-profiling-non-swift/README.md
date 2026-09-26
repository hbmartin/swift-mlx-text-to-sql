# Part 5 — Prototyping, profiling, and non-Swift access

**Version floor:** four different floors live in this part and confusing them wastes days. `#Playground`
and the scheme's availability simulation are **Xcode 26.0**. The playground canvas's Input/Response token
counts, `tokenCount(for:)` and `contextSize` are **26.4**. The Foundation Models instrument in its 2026
shape — six lanes, a tree detail view, an Info column — plus the scheme's **quota** cases and
`LanguageModelSession.usage` are **Xcode 27.0 and a physical device on 27**. The `fm` CLI is
**macOS 27.0 only**, preinstalled, with no back-deployment. And `apple-fm-sdk` runs on **macOS 26.0+**
but needs **full Xcode 26.0+** (not Command Line Tools), **Python 3.10–3.13**, Apple silicon, and Apple
Intelligence on — with token counting gated at **26.4** and image attachments gated on the **macOS 27
SDK at build time *and* macOS 27 at runtime**.

**Who this is for:** everyone, but in three different moods. Swift app developers iterating on a prompt
or hunting a latency problem read guide 5.1. Anyone who needs the model from a terminal, a shell script,
or a Jupyter notebook reads 5.2. Anyone about to attach a `.trace` file or a transcript export to a bug
report should read the privacy callouts in both before they click send.

---

## Why this part exists

Parts 2–4 tell you what to write. Part 5 exists because of what happens next: **you cannot assert on the
output, and almost nothing fails loudly.** There is no useful `XCTAssertEqual` against a non-deterministic
runtime, and the framework will run a broken feature forever and report success at every layer. The
canonical case — a whole WWDC26 session was built around it — is a tool named in your instructions prose
but absent from the toolset. The compiler cannot read English, the builder does not parse prose, the
framework sees a valid toolset, and the model quietly invents a coping strategy that looks like a feature.
Four separate layers behave correctly and nobody notices.

So the organising claim is: **observability here is a discipline, not a debugger.** The tools form a
cost-ordered ladder — `#Playground` (seconds, no build), scheme simulation (one menu, one relaunch),
Instruments (a build, a trace, and a privacy decision), Evaluations ([Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md)) —
and most mistakes in this area are people reaching for the instrument to answer a question a playground
would have answered in ten seconds, or the reverse.

The second half of the part is a different story with the same root. In 2026 Apple opened two non-Swift
doors onto the same `SystemLanguageModel`: the `fm` CLI and a Python SDK. Same model, same 4,096-token
window, same guardrails — but the doors are not peers. The CLI is a 27-generation tool whose beta
surface exposed PCC; stable macOS 27 advertises only the system model. The Python SDK is a
**26-generation** binding that cannot instantiate a single 27-era feature and whose stated purpose
is evaluating your *Swift* app.

One editorial warning, because this part carries more of them than any other in Parts 1–6. **This is where
the guides most often stop and say "we do not know."** Nobody on this project has run Xcode 27's
Instruments or `fm` on a macOS 27 machine. Apple's current written documentation now names all six
instrument lanes and all four token metrics; UI details it does not establish remain marked as gaps.
Not one `fm` flag spelling is verified. The Python half is the opposite — a cloned Apple repository
read file by file, with bugs cited down to the assignment that causes them. Read the evidence markers;
they are doing real work here.

---

## Read this first: the triage table

| If your situation is… | Read | Why |
|---|---|---|
| "I want to iterate on a prompt without rebuilding the app" | [5.1 §2](references/01-playground-and-instruments.md#2-playground-the-inner-loop) | `#Playground` sees your whole project without building it; blocks become tabs |
| "The model refused something benign / returned nonsense" | [5.1 §3](references/01-playground-and-instruments.md#3-playground-is-also-the-bug-reporting-channel) | Reproduce in a playground, click the thumbs. This is Apple's own documented process, from a pinned DTS thread |
| "I need to collect model feedback from real users" | [5.1 §3.1](references/01-playground-and-instruments.md#31-the-programmatic-path-languagemodelfeedback) | `logFeedbackAttachment(sentiment:issues:desiredOutput:)` — and it contains the whole transcript |
| "I need to test my 'Apple Intelligence is off' or 'quota exhausted' UI" | [5.1 §4](references/01-playground-and-instruments.md#4-scheme-simulation-reaching-states-you-cannot-otherwise-reach) | The scheme option makes the framework lie to you; there is a test matrix worth pinning up |
| "My feature is slow and I do not know where the time went" | [5.1 §6.2, §9](references/01-playground-and-instruments.md#62-the-model-inference-lane--yellow-is-prefill-orange-is-decode) | Yellow is prefill, orange is decode. The bar shape names your problem before you read a number |
| "The model loops, keeps offering the same thing, nothing throws" | [5.1 §8](references/01-playground-and-instruments.md#8-️-the-canonical-worked-bug-a-tool-named-in-prose-missing-from-the-toolset) | The canonical bug, diagnosed in four clicks and no code read |
| "Every turn of the conversation has a long prefill" | [5.1 §10](references/01-playground-and-instruments.md#10-detecting-kv-cache-invalidation) | KV-cache invalidation, with a blast-radius table and a measurement loop |
| "I am about to attach a `.trace` to a Feedback Assistant report" | [5.1 §5.2](references/01-playground-and-instruments.md#52-️-the-record-anyway-dialog--read-this-before-you-click) | **Stop.** It stores prompts and responses unencrypted |
| "I want the model in a shell script or a cron job" | [5.2 §4](references/02-fm-cli-and-python-sdk.md#4-the-shell-automation-pattern-attested-with-unverified-flags-marked) | The pattern is verified; read the [captured beta-5 surface](references/02-fm-cli-and-python-sdk.md#3--the-fm-help-surface-captured-on-macos-27) first. |
| "I need PCC from something that is not Swift" | [5.2 §2.6](references/02-fm-cli-and-python-sdk.md#26-fm-serve--the-one-written-sentence-and-why-it-matters-most) | No stable CLI route is currently advertised; use Swift or verify a later `fm` surface |
| "I want to batch-compare prompts in pandas" | [5.2 §15](references/02-fm-cli-and-python-sdk.md#15-the-evaluation-pipeline-session-334s-case-study) | Apple's own case study, including the counter-intuitive result |
| "My Swift feature uses dynamic profiles, PCC, or a BYO backend" | [5.2 §5.2](references/02-fm-cli-and-python-sdk.md#52-️-the-version-discrepancy-this-is-a-26-generation-sdk) | The Python SDK **cannot represent it.** Evaluate in Swift — [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md) |
| "My seeded Python runs will not reproduce" | [5.2 §8.3, §8.6](references/02-fm-cli-and-python-sdk.md#83-respond--five-paths-through-one-method) | Two bugs that compose. Use `schema=` plus `greedy()` |
| "`pip install apple-fm-sdk` fails on my CI runner" | [5.2 §6.2](references/02-fm-cli-and-python-sdk.md#62-the-preflight-ladder-and-the-two-error-strings-that-identify-it) | Command Line Tools are rejected; you need full Xcode, opened once |
| "Image prompts raise on a machine that supports images" | [5.2 §6.4](references/02-fm-cli-and-python-sdk.md#64-️-the-build-machine-silently-decides-whether-images-work) | Your *build* machine's SDK decided it, permanently |
| "A batch image job dies around 250 items" | [5.2 §13.2](references/02-fm-cli-and-python-sdk.md#132-the-fd-leak-and-why-the-fix-is-not-in-any-release) | An FD leak, measured, fixed on `main`, in no release |
| "I have transcripts from a shipping Swift app" | [5.2 §12](references/02-fm-cli-and-python-sdk.md#12-the-cross-language-workflow-swift-transcripts-into-python) | Analysis needs no SDK, no Apple silicon, no Apple Intelligence — they are JSON |

---

## The guides in this part

### [5.1 — `#Playground`, scheme simulation, and reading a Foundation Models trace](references/01-playground-and-instruments.md)

Three tools used in a fixed order. `#Playground` as the prompt bench — the refresh button re-runs the
*entire* block, multiple blocks become tabs, and Apple's Book Tracker ships one calling the real service
with deliberately unruly fixtures. The scheme's *Simulated Apple Foundation Models Availability* menu,
which is the only way to reach `.appleIntelligenceNotEnabled` and *Quota Usage Limit Reached* without
four devices and a burned daily quota. Then the Xcode 27 instrument: the Instructions lane as a picture
of your app's state machine, the Model Inference lane's yellow-prefill/orange-decode split, the tree
(sessions ▸ requests ▸ model inferences ▸ instructions / prompts / responses / tool calls), the Info
column as a linter, and the three latency metrics plus the four token metrics only Apple's *written*
documentation names — **Total, Consumed, Generated, and Cached** — plus the KV-caching page's cache-hit
formula. Session 243 never names that metric, so the guide keeps the written-documentation attribution
explicit. Section 3 is the least-known thing in the part: `#Playground` is Apple's official
bug-reporting channel for the model itself.

> ⚠️ **SILENT FAILURE — the Simulator trap.** Xcode ships the SDK; the *model* ships with the OS. Against
> a Simulator, inference is executed by the **host Mac**, and an Xcode 27 SDK on a macOS 26 host
> manufactures errors that look exactly like your bug — often a bare `LanguageModelError error -1`. An
> Apple Designer's accepted forum answer calls this "punching out to macOS". **A Foundation Models bug is
> not a bug until you have reproduced it on a physical device on the matching OS**, and this is the
> single largest source of phantom bug reports in the forums.
>
> ⚠️ **The trace file is a personal-data artefact.** Foundation Models logging is off in production and
> **on for the duration of your recording**; Instruments makes you click "Record Anyway" for a reason.
> Apple's written version is blunter than the dialog: recordings capture prompts and responses **in an
> unencrypted form**. Add `*.trace` to `.gitignore` now, profile with fixtures rather than your own
> content, and read a trace before you attach it to anything. The same applies with the same force to
> `logFeedbackAttachment` JSON (§3.1) and to Origami's `TranscriptRecorder` snapshots (§13.1).
>
> ✅ **VERIFIED — the current written documentation names all six lanes:** Session, Request,
> Instructions, Model Inference, Tool, and Model Loading. The direct Apple Markdown response and its
> SHA-256 are preserved in the
> [2026-09-22 evidence note](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/notes/web/apple-foundation-models-runtime-performance-2026-09-22.md).
> The remaining declared gaps are collected in §15, including where a `#Playground` block actually
> executes, whether the Foundation Models template works against a Simulator, the member names inside
> `LanguageModelSession.Usage`, and whether third-party `LanguageModel` backends populate every metric.

### [5.2 — The `fm` CLI and the Foundation Models SDK for Python](references/02-fm-cli-and-python-sdk.md)

Two products, two floors, and — unusually — two opposite evidence classes, which the guide flags in its
own opening. The `fm` half covers what is genuinely attested: preinstalled on macOS 27, `respond` /
`chat` / `schema` / `schema object` "and more", historical `/model` and `/save` inside beta `fm chat`, and
`fm serve` — which no WWDC session mentions and which an Apple engineer described in a GitHub issue
as serving the model "as a Chat Completions endpoint". Stable macOS 27 no longer advertises the beta
PCC model choice, so Swift is the documented PCC route until a later CLI says otherwise. The Python half is the strongest evidence
in Parts 1–6: `apple/python-apple-fm-sdk` cloned and read at HEAD, a three-layer ctypes/C/Swift sandwich
over the real framework, covering installation, availability as a `(bool, reason)` tuple, `respond()`'s
five dispatch paths, snapshot streaming, `@fm.generable`, the raw JSON-Schema path that consumes a schema
your Swift app exported verbatim, tools, images, memory, and the session-334 evaluation pipeline.

> ✅ **MEASURED — including stable drift.** The project captured every beta-5 help page and compared
> it with stable macOS 27 build `26A428` on 2026-09-16. The canonical command-by-command comparison
> is [5.2 §3](references/02-fm-cli-and-python-sdk.md#3--the-fm-help-surface-captured-on-macos-27). The schema grammar and public
> flags are known. Exit codes, stderr discipline, interactive slash commands, and streaming behavior
> remain runtime gaps. The guide therefore separates stable recommendations from historical beta syntax.
>
> ⚠️ **SILENT FAILURE — a shell pipeline cannot tell "the model declined" from "the model answered in
> prose".** If a schema flag does not apply — wrong spelling, malformed schema, an OS that ignored it —
> you still get text on stdout and an exit status you did not check. `jq` then fails thirty lines later
> blaming the wrong thing, or worse, succeeds against something structurally valid and semantically
> empty. Validate **shape and count**, not parseability, before touching a file.
>
> ⚠️ **SILENT FAILURE (Python, and two of them compose).** `respond(prompt, generating=X, options=…)`
> passes two arguments where every sibling branch passes three, so **your `options` are dropped on the
> flagship typed path** — temperature, sampling and token caps have no effect. Separately, random-sampling
> parameters *including the seed* are serialised as strings that the Swift side cannot cast to numbers,
> so `options.sampling` is never assigned. Together they mean the most natural way to write a reproducible
> typed evaluation is reproducible in neither respect. Use `schema=` plus `greedy()`. The third edge in
> the same family: optionality is detected by substring-matching `str(type)`, so `int | None` is never
> optional and on **Python 3.14 even `Optional[int]` stops matching** — pin ≤3.13.
>
> ⚠️ **The Python SDK is a 26-generation product, and that is a scope decision rather than a lag.** No
> PCC (an Apple member: "we do not currently plan to add support"), no `LanguageModel` protocol and
> therefore no BYO backends, no dynamic profiles, no mutable transcript, no `toolCallingMode`, no
> `prewarm()`, no feedback API. Also: the file-descriptor leak that kills image batches at ~240–250 calls
> is fixed on `main` and **in no tagged release**, so `pip install apple-fm-sdk` today gives you the bug.

---

## Reading order

**Everyone reads [5.1 §1–§2](references/01-playground-and-instruments.md#1-three-properties-that-break-normal-debugging) first**, including the
Simulator trap in §2.6. It is ten minutes, it establishes which of the three tools answers which
question, and it prevents the most commonly wasted afternoon in this stack.

**Then navigate 5.1 by symptom, not by number.** Something is wrong and nothing threw → §8. Something is
slow → §6.2 then §9. A conversation gets slower turn by turn → §10. A trace looks structurally strange →
§7.2's one-sentence invariant. The quick reference in §14 is built for exactly this and is worth reading
on its own.

**Do [5.1 §4](references/01-playground-and-instruments.md#4-scheme-simulation-reaching-states-you-cannot-otherwise-reach) as a pass before you ship**, not while you
build. The test matrix in §4.5 is a twenty-minute exercise and it covers branches your users will
otherwise meet first.

**Read [5.2 §5.2](references/02-fm-cli-and-python-sdk.md#52-️-the-version-discrepancy-this-is-a-26-generation-sdk) before writing a line of Python.** It decides
whether the SDK can represent your feature at all, and if it cannot, the correct move is
[Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md) in Swift rather than a workaround.

**Defer or skip:**
- **All of 5.2** is skippable if you work only in Swift and only in Xcode — with one exception worth a
  single paragraph: [§2.6](references/02-fm-cli-and-python-sdk.md#26-fm-serve--the-one-written-sentence-and-why-it-matters-most) is the answer to "how does anything
  that is not Swift reach Apple's models."
- **[5.1 §11](references/01-playground-and-instruments.md#11-what-changed-between-the-2025-and-2026-instrument)** (the 2025 vs 2026 instrument) matters only
  if your mental model came from last year's code-along and you are hunting a UI that moved.
- **[5.1 §3.1](references/01-playground-and-instruments.md#31-the-programmatic-path-languagemodelfeedback)** (`LanguageModelFeedback`) can wait until
  you actually have users producing feedback to collect.
- **[5.2 §6](references/02-fm-cli-and-python-sdk.md#6-installing-it-and-why-pip-install-compiles-swift)** (build-backend internals) is unread until
  `pip install` fails — at which point it is the entire answer, error string by error string.
- **[5.2 §13](references/02-fm-cli-and-python-sdk.md#13-️-memory-across-the-boundary)** (memory across the boundary) is deferrable until
  you cross a few hundred iterations — but read it *before* you write that loop, not after it dies.

---

## What this part deliberately does not cover

- **Measuring whether the output is any good.** Instruments measures the run; Evaluations measures the
  result, and a feature can be fast, cheap, structurally perfect in the tree view and produce garbage.
  Evaluators, model judges, κ-calibration and diffable CI runs are [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md) —
  which is also where §15's hand-rolled pandas pipeline goes when it grows up.
- **The APIs being profiled.** Sessions, guided generation, the `Tool` protocol, images, the error
  taxonomy and guardrails: [Part 2](../part-02-foundation-models-everyday-api/README.md).
- **Context strategy.** The 4K budget, KV-cache economics, dynamic profiles, `historyTransform`:
  [Part 3](../part-03-context-profiles-agentic/README.md). Guide 5.1 §10 is the *measuring instrument* for that
  part, not a substitute for its argument.
- **PCC and bring-your-own backends.** The quota model in full, `CoreAILanguageModel`, `MLXLanguageModel`
  and `ChatCompletionsLanguageModel`: [Part 4](../part-04-beyond-the-built-in-model/README.md). Part 5 only shows
  you how to *simulate* the quota branches and preserves the now-historical beta `fm` PCC route.
- **Device eligibility, entitlements, and the Siri-enablement availability defect in full:**
  [Part 1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/README.md).
- **A local OpenAI-compatible server you can use today**, while `fm serve` remains undocumented:
  `mlx_lm.server` in [Part 12](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/README.md), plugged back into Foundation Models from Swift
  via Part 4.
- **Anything below `LanguageModelSession`.** Core AI's model debugger and MLIR inspection are
  [Part 7](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/README.md) and
  [Part 10](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-10-coreai-hardware-authoring-debugging/README.md); Metal-level profiling is
  [Part 11](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-11-metal-and-tensorops/README.md).
- **Migrating a shipping 26.x app:** [Part 17](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/README.md).

---

## Sources for this part

WWDC26 session **243** (*Debug and profile agentic app experiences with Instruments*), read in full and
the primary source for the whole trace anatomy, plus sessions **241**, **242**, **298**, **319** and
**334** (*Foundation Models on macOS*), and Meet-with-Apple **205**, the Xcode 26 code-along that supplies
the 2025 instrument baseline and the 1,044 → 700 token result. All are **spoken** transcripts, which is
why narrated command lines appear here as 🔴 unknown rather than as flags. Apple documentation:
*Analyzing the runtime performance of your Foundation Models app* and *Optimizing key-value caching in
language model sessions* — captured directly as Apple Markdown on 2026-09-22, with hashes and targeted
excerpts preserved in the
[evidence note](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/notes/web/apple-foundation-models-runtime-performance-2026-09-22.md) — plus
*Managing the context window*, *Using Private Cloud Compute*, *Foundation Models updates*, and the
FoundationModels symbol index. Apple sample code from
downloaded archives, treated as top-tier evidence: **Origami** (`OrigamiInstructions.swift`,
`CraftTools.swift`, `CoachInstructions.swift`, `TranscriptRecorder.swift`, `CoachModel.swift`) and **Book
Tracker**, whose shipped `#Playground` block is quoted whole. For the Python half,
`github.com/apple/python-apple-fm-sdk` **cloned and read on disk at HEAD `e868e60`** — fifteen Python
modules, the 146-line C header, all 1,831 lines of the Swift shim, seventeen test files, the Sphinx docs,
the Swift/Python parity fixtures, and the complete issue and PR history, of which issue **#13** (the Apple
member's beta-era "no PCC in Python; use `fm` / `fm serve`" guidance, now superseded on stable macOS)
and issue **#17** / PR **#18** (the measured FD leak
and its unreleased fix) appear nowhere else in the corpus. Apple Developer Forums: **791250** (the pinned
and locked DTS thread defining the feedback process), **831404** and **831998** (the Simulator punch-out
and PCC-in-simulators known issue 177684296), **836285**, **836760**/**835211** (the Siri-enablement
defect, acknowledged by an Apple Frameworks Engineer), **833642**, **790736**, **817502** and **838613**.
Community material — the prefix-reuse measurements against a non-Apple executor, the `contextSize > 0`
defensive read, the 896 px image inference — is attributed as community-measured at every point of use and
never presented as an Apple figure. One number is ours: `str(typing.Optional[int])` measured across
Python 3.11, 3.12, 3.13 and 3.14.
