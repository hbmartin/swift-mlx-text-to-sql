# Part 4 — Beyond the built-in model

**Version floor:** everything here is **27.0 and only 27.0** — the `LanguageModel` /
`LanguageModelExecutor` pair, `PrivateCloudComputeLanguageModel`, `ContextOptions`,
`LanguageModelCapabilities`, the generation channel (and, until Xcode 27 beta 5 dropped it from the
interface, `Transcript.CustomSegment` — see reference 03 §13.2). **No tvOS anywhere in
this part**, and **nothing back-deploys to 26.x**: on a 26 SDK the symbols do not exist, which is why
every provider package gates with `#if canImport(FoundationModels, _version: 2)` rather than
`@available` alone. You need the **Xcode 27 SDK**, not Xcode 26 with a 27 deployment target. The three
backends have *narrower* floors and differ from each other: `ChatCompletionsLanguageModel` adds
**watchOS**; `MLXLanguageModel` is iOS/macOS/visionOS and **also** needs the 27 SDK to exist at all;
`CoreAILanguageModel` is **iOS and macOS only**. Meanwhile `@Generable`, `Tool` and `Transcript` are
**26.0** — two floors in one file is normal here.

**Who this is for:** app developers choosing what sits behind `LanguageModelSession`, and package
authors shipping a conformance for others to choose. Writing the feature rather than picking the engine
is [Part 2](../part-02-foundation-models-everyday-api/README.md).

---

## Why this part exists

The 2026 reframing is that **the model became a parameter**. Five conformers shipped in one cycle and
the session API did not change for any of them — `respond(to:)`, `streamResponse`, `Instructions`,
`Prompt`, `Tool`, `@Generable`, the transcript, dynamic profiles. Apple's pitch is that you swap one
line and everything downstream stays the same. That is true of the *call site* and false of almost
everything else, and this part is about the gap. Four things change under you when the model changes,
none of them visible in a diff:

1. **Capabilities.** A backend declares four flags and the framework *routes* on them — it refuses to
   forward a `reasoningLevel` to an executor that did not declare `.reasoning`, and throws
   `unsupportedCapability` on your behalf. Under-declaring is loud and safe; over-declaring is silent,
   and is where your bugs live.
2. **Options coverage.** `GenerationOptions` is one type with wildly non-uniform implementations. The
   same code compiles everywhere; the chat-completions backend *throws* on top-K and on a seed, Core
   AI honours only `temperature`, and nothing warns you at the call site.
3. **Error vocabulary.** Nine `LanguageModelError` cases exist and a backend is obliged to use none of
   them — Apple's own `ChatCompletionsLanguageModel` turns a 429 into a generic HTTP error. Your
   `catch` ladder looks portable and is not.
4. **Lifetime.** The framework caches one executor per unique `Configuration` — *the configuration is
   the lookup key, not the model*. Get that key wrong and you silently get somebody else's executor and
   KV cache, or a cold cache every turn.

Underneath all four sits the sharpest fact in the part, and it should change which backend you pick
rather than merely inform how you configure it: **grammar-constrained decoding needs engine logits, and
the fastest local engine never exposes them** — a GPU-pipelined Core AI bundle samples on-GPU, so
`@Generable` is *structurally* unavailable exactly where the throughput numbers came from. And a
quieter one for provider authors: you receive the **full transcript on every call**, and KV reuse
across turns is your job alone.

---

## Read this first: the triage table

| If your situation is… | Read | Why |
|---|---|---|
| "I want Apple's server model — 32K and reasoning" | [4.1](references/01-private-cloud-compute.md) | `PrivateCloudComputeLanguageModel` end to end. Start at §1: **three** eligibility conditions, one in no WWDC session, and the download threshold is **lifetime** across all your apps |
| "My PCC app crashes instead of throwing" | [4.1 §2.3](references/01-private-cloud-compute.md#23-️-silent-failure--the-missing-entitlement-does-not-throw) | A missing managed entitlement is a `fatalError`, not a catchable error |
| "`isAvailable` is `true` and every request fails" | [4.1 §5.4](references/01-private-cloud-compute.md#54-️-silent-failure--availability-is-not-a-health-check) | Quota is **orthogonal** to availability, in Apple's own words |
| "I need a quota progress bar" | [4.1 §7.6](references/01-private-cloud-compute.md#76-️-you-cannot-build-a-usage-meter) | You cannot build one. Three coarse states, no numbers, FB23378161 open |
| "I'm ineligible, or my six-month clock started" | [4.1 §12](references/01-private-cloud-compute.md#12-if-you-are-not-eligible) → [4.2](references/02-bring-your-own-model.md) | A different architecture, not a different flag |
| "I want a Hugging Face model in my real prompt flow today" | [4.2 §2](references/02-bring-your-own-model.md#2-path-1--any-openai-compatible-server-today) | A local server + `ChatCompletionsLanguageModel`; no conversion step, no 27-SDK model packages |
| "Where is `MLXFoundationModels`? There are no beta branches" | [4.2 §3.1](references/02-bring-your-own-model.md#31-the-answer-to-thread-836264) | The direct answer to forum thread 836264 |
| "`Cannot find MLXLanguageModel in scope`" | [4.2 §3.2](references/02-bring-your-own-model.md#32-️-the-double-gate-and-the-empty-library) | You built against the 26 SDK; the target compiled to an *empty library* |
| "`@Generable` throws `unsupportedCapability` on my own model" | [4.2 §5](references/02-bring-your-own-model.md#5-️-the-logits-constraint-why-the-fastest-backend-loses-generable) | The logits constraint. Not workaroundable at the call site |
| "Which of the three should I pick, and can I swap later?" | [4.2 §8–§9](references/02-bring-your-own-model.md#8-choosing-concretely) | The comparison that decides it; then one stored property, branching on capabilities not type |
| "I'm shipping a `LanguageModel` package for other people" | [4.3](references/03-authoring-a-languagemodel-provider.md) | Both protocols verbatim, all seven request fields, the whole channel |
| "`session.prewarm()` does nothing" | [4.3 §3.5](references/03-authoring-a-languagemodel-provider.md#35-prewarm--and-the-single-worst-footgun-in-the-protocol) · [4.4 §6.2](references/04-executor-lifecycle-and-kv-reuse.md#62-️-the-near-miss-signature-that-binds-the-default) | A near-miss signature binds the framework's no-op default. No diagnostic |
| "My package crashes at launch with an unbound symbol" | [4.3 §9.7](references/03-authoring-a-languagemodel-provider.md#97--the-updateusage-symbol-that-exists-in-the-interface-and-not-in-the-dylib) | A beta `.swiftinterface` advertising a symbol the dylib does not export |
| "My provider's second turn is 7× slower than its first" | [4.4 §7–§9](references/04-executor-lifecycle-and-kv-reuse.md#7-what-arrives-on-every-call-and-what-it-costs) | The re-prefill tax, transcript diffing, prefix reuse |
| "Changing the timeout had no effect" | [4.4 §3](references/04-executor-lifecycle-and-kv-reuse.md#3-️-the-urlsession-that-isnt-in-the-key) | The `URLSession` is not in the cache key — in Apple's own package |
| "I'm choosing between a hybrid/SSM model and a plain one" | [4.4 §9.4](references/04-executor-lifecycle-and-kv-reuse.md#94-️-linear-attention-forfeits-prefix-caching-entirely) | Linear attention forfeits prefix caching entirely. A model-selection fact |

---

## The guides in this part

### [4.1 — Private Cloud Compute: eligibility, reasoning, and quota UX](references/01-private-cloud-compute.md)

Apple's server model behind a one-line swap: 32K context, three reasoning levels, no API keys, no token
cost to you, and Foundation Models on watchOS for the first time *because* the inference is remote. The
guide leads with eligibility because **PCC is gated on your business, not your code** — three
conditions, one of which (App Store Small Business Program enrolment) is in no WWDC session. Then
reasoning, and the largest body of prescriptive Apple design guidance in the corpus: `quotaUsage`, the
four quota-UI rules, and the Xcode scheme option that simulates both states.

> ⚠️ **SILENT FAILURE (three, and they compound).** Reaching `PrivateCloudComputeLanguageModel`
> **without the managed entitlement produces a `fatalError`, not a catchable error** — your `do/catch`
> never runs. `availability == .available` is **not a health check**: quota is orthogonal to
> availability in Apple's own documentation. And reasoning tokens count against the 32K while appearing
> in nothing you render, so `contextSizeExceeded` arrives from a conversation that "obviously" fits.
> Also here: switching a profile from PCC back to `SystemLanguageModel` mid-conversation throws because
> the transcript is shared — the fix is a `historyTransform` on the *smaller*-model branch.
>
> ✅ **PCC supports image input.** Session 319 feeds “the text and images” into a PCC-backed
> `LanguageModelSession`, and Apple's multimodal prompting guidance recommends
> `PrivateCloudComputeLanguageModel` when image analysis needs additional reasoning or context.[^pcc-images]
> The support question is settled; image token accounting, size limits, quota interaction, and
> reasoning-token interaction remain undocumented. Also open: tvOS/Catalyst availability, the full
> `QuotaUsage.Status` case list, and how PCC's `Error` relates to `LanguageModelError`.

### [4.2 — Core AI, MLX, and any OpenAI-compatible server behind `LanguageModelSession`](references/02-bring-your-own-model.md)

The consumer side of bringing your own model, with real initializers rather than demo lines. Path 1 is
the under-advertised one: `ChatCompletionsLanguageModel` ships in `apple/foundation-models-utilities`,
and because `mlx_lm.server`, Ollama, vLLM and LM Studio all speak chat-completions, it is **any
Hugging Face checkpoint behind `LanguageModelSession` today**, with no conversion step. Path 2 answers
where `MLXFoundationModels` lives; path 3 is one line to a Core AI bundle. Then §5.

> ⚠️ **SILENT FAILURE — the logits constraint (§5).** `@Generable` is grammar-constrained decoding: the
> schema masks the next-token distribution, and masking requires *having* the distribution. Core AI's
> **GPU-pipelined** engine samples on-GPU and returns no logits, so guided generation is impossible
> there — and `variant: nil` means auto-detect, so **you do not know which engine you got unless you
> asked.** Every published Core AI throughput number came from the engine that has no `@Generable`.
>
> ⚠️ **SILENT FAILURE (four more, all live).** `supportsGuidedGeneration:` defaults to **`true`**,
> wrong for most local servers — over-declaring produces well-formed JSON with invented fields rather
> than an error. The SSE parser requires **exactly one space** after `data:`, so a spec-legal server
> produces a stream that completes having yielded nothing. A chunk carrying both `tool_calls` and
> `content` **drops the content**. And MLX deliberately sends no `updateUsage` on this SDK, so
> `response.usage` may be absent or zero. Separately, the **`v1` path defect**: `buildURLRequest` tests
> `pathComponents.contains("v1")` and otherwise injects `/v1`, breaking Gemini's OpenAI-compatible
> endpoint, every `/v2` or `/v3` API and every Azure deployment path — acknowledged (FB23837262) *after*
> the newest tag, so put a literal `v1` in your base URL.
>
> 🔴 **GAP — Linux.** The package is *structured* for it and the README claims it, but there is no CI,
> no Dockerfile and no build matrix anywhere, and exactly the three test suites using `@Generable` are
> Darwin-gated. Plan Linux deployments around plain text generation.

### [4.3 — Authoring a `LanguageModel` provider package](references/03-authoring-a-languagemodel-provider.md)

The best-evidenced deep topic in the series, because Apple ships an **815-line agent skill** on exactly
this question plus **two complete worked conformances you can read line by line**. Both protocols
verbatim, the 40-line minimum viable conformance from Apple's own test mock, all seven request fields
(including the three Apple's shipped executor ignores), `ContextOptions` versus `GenerationOptions`,
two transcript translators that disagree about prior reasoning, the whole generation channel,
authentication, and custom segments as the extension point for new modalities (a surface the
Xcode 27 beta 5 interface no longer declares — §13.2 there carries the status note and safe
default).

> ⚠️ **SILENT FAILURE — `prewarm` binds a no-op.** `prewarm(model:transcript:)` ships a default no-op
> extension, so a signature that is *almost* right compiles cleanly, becomes an ordinary method nothing
> calls, and lets the framework's default win. `some Collection<Transcript.Entry>` — idiomatic modern
> Swift, and `Transcript` really is a `Collection` — is exactly the near miss.
>
> ⚠️ **SILENT FAILURE (three more).** `updateMetadata` and `updateUsage` are **wholesale snapshots, not
> additive** — a later event with fewer keys *deletes* the ones you stopped sending. An unhandled
> transcript entry or segment is *silently dropped* by every catch-all in every shipped translator, and
> the model answers confidently from incomplete context. And the framework coalesces only
> **consecutive** same-type events, so thought/text/thought/text shatters into four transcript entries
> unless you mint three stable `entryID`s at the top of `respond`.
>
> 🚨 **The session's prescribed event order is contradicted by four of four shipping implementations.**
> Session 339 says metadata → usage → text deltas. On the 27.0 beta a `.response(updateUsage:)` on a
> turn that ends in tool calls **materialises an empty `Response` transcript entry**, because the three
> top-level events are peer *entry kinds*. Apple's Core AI adapter, Apple's mock and
> `ChatCompletionsLanguageModel` all send usage at the end; §10.3 keeps the intent without the bug.
>
> 🔴 **GAP — App Attest.** Session 339 tells cloud-backed provider authors to integrate device
> attestation and points at a session nobody captured; there is not one line of `DCAppAttestService`
> anywhere in the corpus, so the guide states *that* and *what for* and refuses to invent it. Also
> open: `GenerationSchema.name` for an anonymous schema, and `includeSchemaInPrompt`, unread by any
> conformance.

### [4.4 — Executor lifecycle, configuration identity, and preserving work across calls](references/04-executor-lifecycle-and-kv-reuse.md)

The mechanics that decide whether a provider is fast or slow and — more often than expected — whether
it is *correct*. The executor store keyed by `Configuration`; what belongs in that key and the manual
`==`/`hash` escape hatch every real provider reaches for; the teardown you do not write and the two
ways to opt out; then the payoff. You get the **full transcript on every `respond`**, so a provider
that does nothing re-prefills the whole conversation every turn — turn 1 = 0.41 s, turn 2 = 2.8 s on a
three-entry history. Diffing flattens that curve; rewinding the KV cache underneath it is, on a
pure-attention model, one integer assignment.

> ⚠️ **SILENT FAILURE — the `urlSession` that isn't in the key.** In Apple's own package at
> `1.0.0-beta3`, two `ChatCompletionsLanguageModel` values differing *only* in
> `urlSessionConfiguration` compare equal and hash the same, so the second silently inherits the
> first's transport: a 600-second reasoning timeout becomes 15 seconds. The lesson is the most
> transferable idea in the part — **every field you exclude from `==` is a promise that two
> configurations differing only in it are interchangeable, and the framework keeps that promise whether
> or not it is true.**
>
> ⚠️ **SILENT FAILURE — linear attention forfeits prefix caching entirely.** An SSM / GatedDeltaNet /
> Mamba2 state is a running scan, not positionally addressed, so it cannot be rewound — Qwen3.5,
> Qwen3.6, LFM2.5 and Granite 4 re-prefill in full every turn. Nothing errors, nothing logs, output is
> perfect, and turn-2 TTFT is an order of magnitude worse than a pure-attention model of the same size.
>
> ⚠️ **Read the §9 preamble before you use any of it.** `trimKVCache(to:)` and
> `prefixReuseFeedsFullSequence` are **not Apple APIs** — they are a community patch to a *fork* of the
> Core AI `InferenceEngine` protocol, and `trimPromptCache(_:numTokens:)` is MLX Swift, not Foundation
> Models. 🔴 Relatedly, **nobody has observed the `urlSession` bug fire**, and the framework's cache
> semantics (lifetime, eviction, which configuration wins on a hash hit) are documented nowhere.

---

## Reading order

**Everyone starts at [4.2](references/02-bring-your-own-model.md), including provider authors.** It is
the shortest path to a working non-Apple backend and it carries §5, the logits constraint — the one
thing here that should change a decision you have probably already made; guide 4.3 assumes you have
consumed one of these packages first. **Then branch by role:** PCC-eligible app developers to
[4.1](references/01-private-cloud-compute.md), reading §1 *before* designing anything because a third
of it is unusable if you fail a business condition; package authors to [4.3](references/03-authoring-a-languagemodel-provider.md).

**[4.4](references/04-executor-lifecycle-and-kv-reuse.md) is deferrable, and doing it first is a
mistake.** Its own ordering rule is: identity, then diffing, then rewinding — a perfect prefix-reuse
implementation behind a configuration that changes every turn buys nothing. Read §1–§6 once your
provider compiles and streams text; defer §7–§9 until you have a multi-turn conversation that is
measurably slow. **Two exceptions:** §9.4 is a *model-selection* fact, so read it before you pick a
checkpoint; and §3 is worth ten minutes if you already ship two models differing only in transport.

**Skippable outright.** [4.1](references/01-private-cloud-compute.md) if you fail the eligibility
checklist — read §1.5 and §12 and leave; [4.3 §12–§13](references/03-authoring-a-languagemodel-provider.md#12-step-3--authentication)
if your package fronts a local engine, not a service; [4.2 §2.9](references/02-bring-your-own-model.md#29-linux-and-the-streaming-you-do-not-get-there) unless you deploy Swift on Linux.

---

## What this part deliberately does not cover

- **Everything in front of the model** — `LanguageModelSession`, `@Generable`, the `Tool` protocol,
  streaming, `SpotlightSearchTool`, image attachments, the failure taxonomy:
  [Part 2](../part-02-foundation-models-everyday-api/README.md). This part changes what sits *behind* the session
  and assumes you know what a `Transcript` and a `Tool` are.
- **Dynamic profiles, `historyTransform`, `summarizeHistory` and context management as a discipline.**
  Part 4 says a profile switch is where a backend swap happens and that the smaller-model branch needs a
  history modifier; the strategy is [Part 3](../part-03-context-profiles-agentic/README.md). And **choosing a
  backend against product constraints** — [Part 1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/README.md) carries the
  decision table and the known-bad-claims reference; this part is *how*, not *which*.
- **Producing a Core AI bundle.** Conversion, compression, specialisation, `.aimodelc` and the
  device-class matrix are Parts [7](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/README.md),
  [8](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/README.md), [9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md) and
  [10](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-10-coreai-hardware-authoring-debugging/README.md); guide 4.2 §4.5 states only the two facts that
  change a *consumer's* decision. **MLX as a framework** rather than as a conformance:
  [Part 12](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/README.md) and [Part 13](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/README.md).
- **Measuring whether the backend you chose is actually better.** Apple's instruction is to start
  on-device and evaluate before adopting PCC — "data, not vibes" — and neither side has a model-pinning
  API: [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md). **`#Playground`, the Instrument, the `fm` CLI and the Python
  SDK**: [Part 5](../part-05-prototyping-profiling-non-swift/README.md). **Shipping and operating**, including
  Background Assets weight delivery: [Part 15](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/README.md). **Migrating a 26.x
  app**, including the adapter sunset that sends people here: [Part 17](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/README.md).

---

## Sources for this part

Strongest first. **Apple source read on disk:** `apple/foundation-models-utilities` at `376ca60` (tag
`1.0.0-beta3`, 2026-07-10) — its 815-line
`skills/foundation-models-language-model-protocol/SKILL.md`, the 953-line
`ChatCompletionsLanguageModel.swift`, the 40-line `MockModel.swift` conformance, the tests, and
`git show a047a50` for the deleted `AnyLanguageModel` type-eraser; `apple/coreai-models`
(`CoreAILanguageModel.swift` read in full, `ModelResources.swift`, the `InferenceEngine` protocol); and
`ml-explore/mlx-swift-lm` at HEAD `3cbf928` (`MLXLanguageModel.swift`, `TranscriptConverter.swift`,
`KVCache.swift`, the traits block, and commits `2a76e56`, `1c86cc1`, `3cbf928` — each chasing a
beta-era break). **Apple sample code**, top-tier evidence wherever it contradicts a transcript:
*Origami* (the PCC opt-in comment, `Profile { … }.model(_:)`, `.reasoningLevel(.deep)`,
`historyTransform`) and *Book Tracker* (a PCC-backed session driving a `@Generable` pipeline). **Apple
documentation:** the PCC article, `contextoptions`, `languagemodel`, `languagemodelcapabilities`,
`languagemodelerror`, `transcript`, `systemlanguagemodel/contextsize`, and
`developer.apple.com/private-cloud-compute/` for the three eligibility criteria verbatim, fetched
2026-07-27. **Developer Forums**, with Apple-staff answers: 835897, 833641, 834749, 829539, 831998
(no PCC in simulators, radar 177684296), 833626, 831404, 836264 and 838444 (the `v1` defect,
FB23837262); plus 835974 (FB23378161, quota granularity) with no Apple reply. **WWDC26 transcripts:**
339 — the provider session, and the source for the executor store, teardown, `prewarm`, diffing,
approximate-or-throw and custom segments — plus 319 (PCC), 326 (Core AI behind the session), 241 and
246. **Community sources** — `john-rocky`'s `coreai-model-zoo` and its `coreai-models` fork, and
`frozen Noema 3.5 snapshot` — supply every latency number here, attributed as community-measured at each
point of use with hardware and OS given where the source gave them. **Apple published no latency figure
for any of this.**

[^pcc-images]: [WWDC26 session 319 transcript, lines 74–76](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/transcripts/wwdc2026-319.txt#L74-L76), and Apple, [“Analyzing images with multimodal prompting”](https://developer.apple.com/documentation/foundationmodels/analyzing-images-with-multimodal-prompting), which identifies Private Cloud Compute as the model to use when an image task needs more reasoning or context.
