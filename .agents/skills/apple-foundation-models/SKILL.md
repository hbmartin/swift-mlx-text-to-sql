---
name: apple-foundation-models
description: "Build and debug apps using Apple's Foundation Models framework: LanguageModelSession, @Generable, @Guide, streaming, tools, the Instructions-versus-Prompt trust boundary, context and KV cache, DynamicProfile, custom LanguageModel backends, Playground, Instruments, and fm CLI. Use for import FoundationModels; unconstrained guided output; hung respond(to:); guardrail refusals; LanguageModelError or exceededContextWindowSize; prompt injection; tool loops; or non-Apple backends behind the same API."
---

# Foundation Models: the on-device LLM API

Part 2, Part 3, Part 4, Part 5 of an independent, evidence-backed guide series on Apple's 2026 on-device AI stack, covering the iOS/iPadOS/macOS/watchOS/visionOS/tvOS 27 and Xcode 27 generation. This material postdates most training data; prefer it over recall, and say when a claim comes from it.

## Evidence markers — never flatten these

Every non-obvious claim in `references/` carries one of these. Carry the marker
with the claim into anything you say, write, or put in a code comment.

- ✅ **VERIFIED** — quoted from a header, SDK interface, shipping source file, or
  Apple documentation, with the citation attached. Safe to rely on.
- 🟡 **RECONSTRUCTED** — the concept is attested, usually from a WWDC session, but
  the exact spelling is inferred. Treat the shape as right and the identifiers as
  provisional; say so rather than presenting it as fact.
- 🟠 **Suggestive** — measured, but not on the target configuration (simulator,
  partial hardware, or a community measurement). Directional only.
- 🔴 **GAP** — could not be verified. The callout names what is unknown and what
  would resolve it. Never guess past one.
- ⚠️ **SILENT FAILURE** — fails without throwing. Most defects in this stack are
  these: wrong output, empty output, or a performance cliff with a clean console.

## Find the answer in three moves

`references/` holds far more than fits in context. Route to the section you need:

1. **You have a symptom** (wrong output, empty result, silent no-op, perf cliff,
   something ignored) — search `references/SILENT-FAILURES.md` for words from what
   you actually observed. Entries are grouped by symptom and each links to the
   guide section that explains it.
2. **You have a symbol** (`LanguageModelSession`, `AIModel`, `mx.compile`, …) —
   search `references/API-INDEX.md`. The row shows whether the symbol appears in
   the captured 26.5 and 27.0 SDK interfaces; **blank in both columns means the
   spelling is not SDK-confirmed**, so treat it as provisional.
3. **You have a task** — use the triage table below, then the part README it
   points at.

The deep reference guides are bundled. `references/SECTION-MAPS.md` links every
guide and lists each top-level section anchor. Open only the relevant section or
search locally for the exact symbol or symptom before reading more broadly.

## Version floors

| Part | Floor |
|---|---|
| [2](references/part-02-foundation-models-everyday-api/README.md) | the framework itself is **26.0** on iOS, iPadOS, Mac Catalyst, macOS and visionOS — **no watchOS until 27.0**. |
| [3](references/part-03-context-profiles-agentic/README.md) | the conceptual material starts at **26.0** (`LanguageModelSession`, `Transcript`, `Tool` — watchOS only from 27.0), and the two introspection APIs it leans on, `SystemLanguageModel.contextSize` and `tokenCount(for:)`, are **26.4** — of which only `contextSize` back-deploys. |
| [4](references/part-04-beyond-the-built-in-model/README.md) | everything here is **27.0 and only 27.0** — the `LanguageModel` / `LanguageModelExecutor` pair, `PrivateCloudComputeLanguageModel`, `ContextOptions`, `LanguageModelCapabilities`, the generation channel (and, until Xcode 27 beta 5 dropped it from the interface, `Transcript.CustomSegment` — see reference 03 §13.2). |
| [5](references/part-05-prototyping-profiling-non-swift/README.md) | four different floors live in this part and confusing them wastes days. |

## Triage

A `N.M` label is a deep reference guide; look it up in `references/SECTION-MAPS.md` for its local file and section anchors.

**Part 2 — Foundation Models: the everyday API** ([all 17 rows](references/part-02-foundation-models-everyday-api/README.md#read-this-first-the-triage-table))

| If your situation is… | Read | Why |
|---|---|---|
| "I have never written a `LanguageModelSession`" | [2.1](references/part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md) | Every initializer, `respond`/`streamResponse`, `prewarm`, `isResponding`, `GenerationOptions`, `Transcript` |
| "I interpolate user input into `Instructions`" | [2.1 §3](references/part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md#3-instructions-vs-prompts-is-a-security-boundary) | **Stop.** That is the framework's only trust boundary and you are on the wrong side of it |
| "I want typed Swift values back, not strings" | [2.2](references/part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md) | `@Generable`, `@Guide`, `PartiallyGenerated`, snapshot streaming |
| "My `.anyOf` constraint isn't holding" | [2.2 §4](references/part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#4-️-anyof-does-not-constrain-generation) | Confirmed broken by Apple staff on 26.2. Validate at the boundary |

**Part 3 — Context, profiles, and agentic sessions** ([all 18 rows](references/part-03-context-profiles-agentic/README.md#read-this-first-the-triage-table))

| If your situation is… | Read | Why |
|---|---|---|
| "I keep hitting `contextSizeExceeded`" | [3.1 §6–§7](references/part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#6-overflow-contextsizeexceeded-and-the-pattern-people-hand-rolled) | The four levers, Apple's documented recovery, and the 26.0-only rebuild path |
| "I hardcoded 4096" | [3.1 §3](references/part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#3-reading-the-budget-contextsize-and-the-4096-token-window) | Read `contextSize` at runtime. Stable macOS 27 and both project-run physical-device baselines returned 4,096, while Simulator hosting has also returned 0. The retired 8,192 community comment never reproduced; treat every value as runtime observation, not a constant. |
| "Time-to-first-token climbs turn over turn, prompt size flat" | [3.1 §8](references/part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#8-the-kv-cache-is-a-prefix) | Something is invalidating your prefix. §8.10's expensive list is the checklist |
| "I need to know what a turn actually cost" | [3.1 §5](references/part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#5-counting-after-you-spend-usage-and-the-cache-hit-rate) | `Usage`, `cachedTokenCount`, and the cache-hit-rate formula |

**Part 4 — Beyond the built-in model** ([all 16 rows](references/part-04-beyond-the-built-in-model/README.md#read-this-first-the-triage-table))

| If your situation is… | Read | Why |
|---|---|---|
| "I want Apple's server model — 32K and reasoning" | [4.1](references/part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md) | `PrivateCloudComputeLanguageModel` end to end. Start at §1: **three** eligibility conditions, one in no WWDC session, and the download threshold is **lifetime** across all your apps |
| "My PCC app crashes instead of throwing" | [4.1 §2.3](references/part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md#23-️-silent-failure--the-missing-entitlement-does-not-throw) | A missing managed entitlement is a `fatalError`, not a catchable error |
| "`isAvailable` is `true` and every request fails" | [4.1 §5.4](references/part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md#54-️-silent-failure--availability-is-not-a-health-check) | Quota is **orthogonal** to availability, in Apple's own words |
| "I need a quota progress bar" | [4.1 §7.6](references/part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md#76-️-you-cannot-build-a-usage-meter) | You cannot build one. Three coarse states, no numbers, FB23378161 open |

**Part 5 — Prototyping, profiling, and non-Swift access** ([all 17 rows](references/part-05-prototyping-profiling-non-swift/README.md#read-this-first-the-triage-table))

| If your situation is… | Read | Why |
|---|---|---|
| "I want to iterate on a prompt without rebuilding the app" | [5.1 §2](references/part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md#2-playground-the-inner-loop) | `#Playground` sees your whole project without building it; blocks become tabs |
| "The model refused something benign / returned nonsense" | [5.1 §3](references/part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md#3-playground-is-also-the-bug-reporting-channel) | Reproduce in a playground, click the thumbs. This is Apple's own documented process, from a pinned DTS thread |
| "I need to collect model feedback from real users" | [5.1 §3.1](references/part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md#31-the-programmatic-path-languagemodelfeedback) | `logFeedbackAttachment(sentiment:issues:desiredOutput:)` — and it contains the whole transcript |
| "I need to test my 'Apple Intelligence is off' or 'quota exhausted' UI" | [5.1 §4](references/part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md#4-scheme-simulation-reaching-states-you-cannot-otherwise-reach) | The scheme option makes the framework lie to you; there is a test matrix worth pinning up |

## The deep reference guides

Bundled locally. `references/SECTION-MAPS.md` has every top-level section anchor.

- **[2.1 `LanguageModelSession` end to end](references/part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md)** — The foundational guide: every initializer form, `Instructions`/`Prompt` and their result builders, the 24-method `respond`/`streamResponse` matrix, `prewarm(promptPrefix:)`, `isResponding`, the now-mutable `transcript`, all of `GenerationOptions`, `Response.usage`, and the six-case `Transcript` data model.
- **[2.2 Guided generation and snapshot streaming](references/part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md)** — What the `@Generable` macro synthesises, every `@Guide` form with evidence, the guide-to-type compatibility matrix, runtime schemas, `GeneratedContent`, and why streaming gives you *snapshots* rather than deltas (you assign, never append).
- **[2.3 The `Tool` protocol, calling modes, and the required-mode loop](references/part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md)** — `Tool` member by member; the `@Generable` arguments struct as the contract between model and tool (and why Apple's own evaluation sample makes every argument optional); writing descriptions that say *when* rather than *what*; the six-entry anatomy of one tool-using turn; `toolCallingMode` in both places it can be set, with the precedence rule; transcript rollback on a thrown tool error and …
- **[2.4 Local RAG with `SpotlightSearchTool`, plus OCR and barcodes](references/part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md)** — Apple's answer to "RAG on device without a vector database": the model writes and executes queries against your own Core Spotlight index.
- **[2.5 Image input, and what the model cannot do with pixels](references/part-02-foundation-models-everyday-api/references/05-image-input-and-attachments.md)** — `Attachment` and every source it accepts, the `orientation:` parameter, labels and `ImageReference` for keying structured output back to specific images, the transcript types images become, and which backends accept images at all.
- **[2.6 The complete failure taxonomy: availability, errors, guardrails and refusals](references/part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md)** — The largest guide in the part, organised as symptom → cause → fix across five failure planes.
- **[3.1 Token budgeting, transcript anatomy, and KV-cache economics](references/part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md)** — The conceptual spine: the six `Transcript.Entry` cases and what each costs, `contextSize` and `tokenCount(for:)`, `Usage` and the cache-hit rate, overflow recovery in both the 26.0 and 27.0 idioms, and then the KV material — token layout, the blast-radius table, the ordering rule for `DynamicInstructions`, stateless shape-preserving transforms, and why you batch one big consolidation instead of …
- **[3.2 Dynamic Profiles, modifiers, and session state](references/part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md)** — The flagship 2026 API, built around the projection framing above.
- **[3.3 `foundation-models-utilities`: Skills and history transforms](references/part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md)** — An audit of Apple's separately-versioned experimental package — two commits, issues disabled, no CI — and the two feature areas that change how you think about a transcript.
- **[3.4 Baton-pass, phone-a-friend, model routing, and tool-calling control](references/part-03-context-profiles-agentic/references/04-agentic-orchestration.md)** — Apple named two orchestration patterns — collaboration versus consultation — and then shipped a sample that uses neither literally, so this guide separates the verified narration from the reconstructed code and says which is which at every listing.
- **[4.1 Private Cloud Compute: eligibility, reasoning, and quota UX](references/part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md)** — Apple's server model behind a one-line swap: 32K context, three reasoning levels, no API keys, no token cost to you, and Foundation Models on watchOS for the first time *because* the inference is remote.
- **[4.2 Core AI, MLX, and any OpenAI-compatible server behind `LanguageModelSession`](references/part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md)** — The consumer side of bringing your own model, with real initializers rather than demo lines.
- **[4.3 Authoring a `LanguageModel` provider package](references/part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md)** — The best-evidenced deep topic in the series, because Apple ships an **815-line agent skill** on exactly this question plus **two complete worked conformances you can read line by line**.
- **[4.4 Executor lifecycle, configuration identity, and preserving work across calls](references/part-04-beyond-the-built-in-model/references/04-executor-lifecycle-and-kv-reuse.md)** — The mechanics that decide whether a provider is fast or slow and — more often than expected — whether it is *correct*.
- **[5.1 `#Playground`, scheme simulation, and reading a Foundation Models trace](references/part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md)** — Three tools used in a fixed order.
- **[5.2 The `fm` CLI and the Foundation Models SDK for Python](references/part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md)** — Two products, two floors, and — unusually — two opposite evidence classes, which the guide flags in its own opening.

Search the local guide first, then open only the section needed for the answer. Preserve its evidence marker and citation when carrying a claim into code or prose.

## Related skills

Adjacent parts of the series live in these sibling skills: `apple-on-device-ai`, `apple-ai-evaluations`, `apple-app-intents`, `apple-ai-migration`.
