# Token budgeting, transcript anatomy, and KV-cache economics

**Part 3 · Context, profiles, agentic sessions · Reference 01**

**Version floor.** `LanguageModelSession` and `Transcript` are **iOS 26.0 / iPadOS 26.0 /
Mac Catalyst 26.0 / macOS 26.0 / visionOS 26.0**, and **watchOS 27.0** (they are among the iOS 26
symbols that gained watchOS in the 27 cycle). `SystemLanguageModel` is **26.0, no watchOS**. The two
introspection APIs this guide is built on arrived mid-cycle: **`SystemLanguageModel.contextSize` and
`SystemLanguageModel.tokenCount(for:)` are iOS 26.4**, and only the first is back-deployed.
Everything else here — `LanguageModelError.contextSizeExceeded`, `LanguageModelSession.Usage`,
`Transcript.history`, `Transcript.Entry.reasoning`, `historyTransform(_:)`,
`PrivateCloudComputeLanguageModel`, and the whole `LanguageModelSession.DynamicProfile` family — is
**27.0 only**. The iOS 26 spelling of the overflow error, `LanguageModelSession.GenerationError.exceededContextWindowSize(_:)`,
is **deprecated but still live for apps built with Xcode 26**. 26.0, 26.4 and 27.0 all matter in this
guide and they are routinely confused; every claim below is tagged.

---

## What this covers

This is the conceptual spine of Part 3. Four other guides in this part — dynamic profiles, history
management, agentic orchestration, and session persistence — are all applications of the two ideas
here:

1. **The transcript *is* the context window.** Not a log of it, not a view onto it. The token
   sequence the model sees on turn *N* is a rendering of the transcript, and every design decision
   about instructions, tools, schemas and images is a decision about how many of your ~4,096 tokens
   are gone before the user types anything.
2. **The KV cache is a prefix.** Appending preserves it. A change at position *N* invalidates
   everything from *N* onward. That single sentence explains why Apple made the 2025 API append-only,
   why the 2026 API is dangerous, why `historyTransform` beats mutating `history`, why conditional
   content goes at the *bottom* of a `DynamicInstructions` body, and why switching profiles is a
   deliberate reset rather than a cheap toggle.

Concretely:

- The **six `Transcript.Entry` cases** and what each one costs you — including the two that most
  budgets forget (tool *definitions*, which live inside the instructions entry, and `Generable`
  schemas, which are re-sent per request).
- **`contextSize`** on `SystemLanguageModel` and `PrivateCloudComputeLanguageModel`, and the
  Apple-published 4K / 32K split. **The on-device window is 4096 tokens per `LanguageModelSession`** —
  Apple's docs, the WWDC slide and **TN3193** all say so. Runtime probes measured 4096 on the
  macOS 26.5 host, the iOS 27 simulator, and — on 2026-08-20 — a physical iPhone 15 Pro running
  iOS 27 beta 5. The lone third-party claim of 8192 is now contradicted by the first project-run
  hardware measurement, but the rule is unchanged: **read `contextSize` at runtime, never
  hardcode.** (§3.3)
- **`tokenCount(for:)`** — the only pre-flight budget check that exists, its five overloads, and the
  OS floor that makes it unusable as your only strategy.
- **`Usage`** and `Usage.Input.cachedTokenCount` — the post-hoc accounting, and the cache-hit-rate
  formula Apple gives you.
- **Overflow**: `LanguageModelError.contextSizeExceeded`, its deprecated ancestor, the recovery
  pattern Apple documents, and the retry-and-compact pattern developers hand-rolled on the forums
  **before Apple shipped history modifiers**.
- **KV-cache economics in depth** — token layout, blast radius, the invalidation table, the "training
  wheels off" framing, and the six things that are cheap versus the six that are not.
- **What prefix reuse is actually worth**, community-measured: turn-2 time-to-first-token
  **23.28 s → 0.230 s (101×)** at 4k context, with byte-identical greedy output. And the mechanism,
  which is a *single integer assignment*.
- ⚠️ **The model-selection consequence.** Linear-attention and hybrid architectures — Qwen3.5,
  Qwen3.6, LFM2.5, Granite 4 — **cannot prefix-cache at all** and must re-prefill every turn. This
  belongs in your model-choice spreadsheet, not in a tuning appendix.
- **The accuracy hazard**: rewriting history does not just cost latency, it can make the model wrong
  in a way no test catches — it saw itself do a task without a tool, so it does that again after you
  add the tool.

## What you need

- **Xcode 27** for everything marked 27.0. Xcode 26.4 is enough for `contextSize` and
  `tokenCount(for:)`. Apps still built with Xcode 26 catch the *deprecated*
  `LanguageModelSession.GenerationError`, not `LanguageModelError` — a rebuild changes which error
  case your `catch` ladder matches, silently.
- **A real device.** The Simulator punches inference out to the host macOS, which produces
  version-skew errors that look like your bug, and timings that mean nothing for any latency claim in
  this guide.
- Read [`../../part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md`](../../part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md)
  first. This guide assumes you know what `Instructions`, `Prompt`, `Transcript` and `@Generable` are.
- If you are handling the overflow error, read
  [`../../part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md`](../../part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md)
  for the full catch-ladder ordering. §6 here only covers the context case.
- If you are *writing a provider* rather than consuming one, the KV material in §9–§10 has a much
  deeper treatment in
  [`../../part-04-beyond-the-built-in-model/references/04-executor-lifecycle-and-kv-reuse.md`](../../part-04-beyond-the-built-in-model/references/04-executor-lifecycle-and-kv-reuse.md).

---

## Contents

1. [The transcript *is* the context window](#1-the-transcript-is-the-context-window)
2. [Anatomy: six entry types and what each one costs](#2-anatomy-six-entry-types-and-what-each-one-costs)
3. [Reading the budget: `contextSize` and the 4096-token window](#3-reading-the-budget-contextsize-and-the-4096-token-window)
4. [Counting before you spend: `tokenCount(for:)`](#4-counting-before-you-spend-tokencountfor)
5. [Counting after you spend: `Usage` and the cache-hit rate](#5-counting-after-you-spend-usage-and-the-cache-hit-rate)
6. [Overflow: `.contextSizeExceeded` and the pattern people hand-rolled](#6-overflow-contextsizeexceeded-and-the-pattern-people-hand-rolled)
7. [Reclaiming context: four levers, and Apple's shipped modifiers](#7-reclaiming-context-four-levers-and-apples-shipped-modifiers)
8. [The KV cache is a prefix](#8-the-kv-cache-is-a-prefix)
9. [What prefix reuse is worth, measured](#9-what-prefix-reuse-is-worth-measured)
10. [⚠️ The model-selection consequence: architectures that cannot prefix-cache](#10-️-the-model-selection-consequence-architectures-that-cannot-prefix-cache)
11. [The accuracy hazard: rewriting history confuses the model](#11-the-accuracy-hazard-rewriting-history-confuses-the-model)
12. [Putting it together: a context budget you can defend](#12-putting-it-together-a-context-budget-you-can-defend)
13. [Quick reference](#13-quick-reference)
14. [Sources, and where they disagree](#14-sources-and-where-they-disagree)

---

## 1. The transcript *is* the context window

Most developers arrive at Foundation Models with a mental model borrowed from chat APIs: there is a
conversation somewhere, and separately there is a "context window" that the conversation has to fit
inside. That model will mislead you here, because in this framework the two are the same object.

> ✅ **VERIFIED** — WWDC26 session 242 (`242:69-72`): *"**The transcript is `LanguageModelSession`'s
> representation of the model's context.** `DynamicInstructions` offers one way to modify the
> transcript. More specifically, it allows modifying the instructions entry. For updating the
> remaining entries, we'll use a window into the transcript called 'history'."*

So the structure is:

```
transcript  =  [ the instructions entry ]  +  history (everything else)
                      ▲                            ▲
             DynamicInstructions          historyTransform(_:)  /  @SessionProperty(\.history)
```

> ✅ **VERIFIED** — `Transcript.history`, iOS 27.0; ✅ **SDK-verified**
> (`FoundationModels-27.0-macos.swiftinterface:2695-2700`, beta 5):
> ```swift
> var history: Transcript.HistoryView { get set }
> ```
> ⚠️ Retyped in Xcode 27 beta 5 (noted 2026-08-23): earlier 27.0 beta interfaces declared
> `ArraySlice<Transcript.Entry>`; beta 5 introduces the dedicated `Transcript.HistoryView`
> collection (`27.0:2667-2694`) — same element type, its own `SubSequence`, but an opaque `Index`
> that is **not `Int`**. What still compiles is worked through in
> [02 §12.3](02-dynamic-profiles-and-session-state.md).
>
> Apple's own description: *"The transcript entries **excluding the leading instructions entry**, if
> present."* … *"The history excludes instructions segments from `DynamicInstructions`."*
> (`/documentation/foundationmodels/transcript/history`)

And the whole `Transcript` is a mutable collection, not an opaque handle:

> ✅ **VERIFIED** — `struct Transcript` conforms to `BidirectionalCollection`, `Collection`,
> `Decodable`, `Encodable`, `Equatable`, **`MutableCollection`**, `RandomAccessCollection`,
> **`RangeReplaceableCollection`**, `Sendable`, `Sequence`
> (`/documentation/foundationmodels/transcript`). Apple's sample code actually exercises the
> `Encodable` conformance: Origami's `TranscriptRecorder.swift:57-67` does
> `try JSONEncoder().encode(transcript)` with `.prettyPrinted, .sortedKeys` and writes the result to
> disk behind a `UserDefaults` debug flag.

That has a direct practical consequence: **you can `map`, `filter`, `suffix`, `prefix` and index a
transcript with ordinary Swift**, which is exactly what every context-management technique in this
part turns out to be.

### 1.1 One session, one context, one budget

> ✅ **VERIFIED** — from the `LanguageModelSession` page: *"A session is a single context that you
> use to generate content with, and maintains state between requests."*

Every request re-sends the whole thing. There is no server-side conversation ID, no incremental
delta protocol, no automatic truncation. Apple states the budget rule with no hedging:

> ✅ **VERIFIED** — `GenerationOptions` overview: *"**All input to the model contributes tokens to
> the context window of the `LanguageModelSession`** — including the `Instructions`, `Prompt`, `Tool`,
> and `Generable` types, and the model's responses. If your session exceeds the available context
> size, it throws `LanguageModelError.contextSizeExceeded(_:)`."*

And, from the context-window article, the same list stated as an inventory:

> ✅ **VERIFIED** — `/documentation/foundationmodels/managing-the-context-window`: *"This includes
> all prompts, instructions, tool definitions and their input and output, generable type schemas, and
> all of the model's responses."*

Read that list again and count the things that are **not** in your prompt: tool definitions, tool
outputs, generable type schemas, and every past response. On a 4,096-token budget, a session with
five tools and a moderately nested `@Generable` result type can spend a quarter of its window before
the first user turn.

There is no automatic recovery, and Apple has said so directly:

> ✅ **VERIFIED** — Apple Frameworks Engineer, Developer Forums thread 833642 (the densest Apple
> answer in our forum corpus): **4K (4096) token context window. Overflow handling is
> developer-managed, not automatic.**

### 1.2 Why this is a *design* problem and not a *tuning* problem

The instinct on hitting overflow is to reach for a truncation knob. There isn't one, and the reason
is the second half of this guide: **any edit you make to the transcript has a latency price and an
accuracy price**, and both prices depend on *where* in the sequence you edited. A framework-supplied
"just drop the oldest turns" switch would be a framework-supplied cache invalidation on every turn.

Apple's own framing of the 2026 API change makes this explicit — the previous year's API was
deliberately crippled to prevent exactly this:

> ✅ **VERIFIED** — WWDC26 session 242 (`242:172-174`): *"Now, we didn't talk about this last year
> because we **intentionally shaped `LanguageModelSession` APIs to be append only**. By default, they
> ensured optimal use. But **this year, we're taking the training wheels off**, so to say."*

Everything in this guide is downstream of that sentence. You now have `session.transcript` as a
settable property, `Transcript.history` as a settable slice, `historyTransform(_:)`, and a package of
history modifiers. You also now own the consequences.

### 1.3 Instructions are the first entry, always

One structural fact that the rest of the guide leans on:

> ✅ **VERIFIED** — the Foundation Models code-along (`meet-with-apple-205`, `205:L1088`):
> *"**Also note that instructions are maintained throughout the session's life. Every interaction is
> recorded in the session's transcript, and the initial instructions are always the first entry.**"*

Position 0 is the most expensive position in the whole sequence to modify — §8 quantifies why. It is
also the position that holds your tool definitions. That pairing is not a coincidence; it is the
reason "add a tool mid-conversation" is a much bigger deal than it sounds.

---

## 2. Anatomy: six entry types and what each one costs

`Transcript.Entry` has **six cases**. Five are iOS 26; `.reasoning` is new in 27.

> ✅ **VERIFIED** — `/documentation/foundationmodels/transcript/entry`:
>
> | Case | Payload | Apple's description |
> |---|---|---|
> | `.instructions(_:)` | `Transcript.Instructions` | "Instructions, typically provided by you, the developer." |
> | `.prompt(_:)` | `Transcript.Prompt` | "A prompt, typically sourced from an end user." |
> | `.response(_:)` | `Transcript.Response` | "A response from the model." |
> | **`.reasoning(_:)`** | `Transcript.Reasoning` | "Reasoning from the model." **(NEW iOS 27)** |
> | `.toolCalls(_:)` | `Transcript.ToolCalls` | "A tool call containing a tool name and the arguments to invoke it with." |
> | `.toolOutput(_:)` | `Transcript.ToolOutput` | "An tool output provided back to the model." |
>
> Independently confirmed by two compiled sources: Apple's `foundation-models-utilities`
> renders exactly these six in `TranscriptRendering.swift:19-38`, and its `EntrySummary.swift:36-52`
> enumerates the same six.

> ⚠️ **Migration footgun.** Any exhaustive `switch` over `Transcript.Entry` written against iOS 26
> **fails to compile against the 27 SDK**, because `.reasoning` is new. The same is true of
> `Transcript.Segment`, which gained `.attachment`. This is one of the few places in this stack
> where the compiler actually helps you — take the hint and add a `@unknown default` while you are
> in there, because Apple's own utilities package writes `@unknown default: return nil`
> (`TranscriptRendering.swift:36`), which tells you the enum is resilient.

### 2.1 What each entry actually carries

The payload types matter for budgeting, because a `.instructions` entry is not just your prose.

> ✅ **VERIFIED** — entry payload initializers, from the `Transcript` symbol pages:
>
> ```swift
> // Transcript.Instructions
> init(id:segments:toolDefinitions:)
> var segments, toolDefinitions
>
> // Transcript.Prompt
> init(id:segments:options:responseFormat:)                         // iOS 26
> init(id:metadata:segments:options:responseFormat:contextOptions:) // iOS 27
>
> // Transcript.Reasoning  (iOS 27 only)
> init(id:metadata:segments:signature:)
>
> // Transcript.Response
> init(id:assetIDs:segments:)   // iOS 26
> init(id:metadata:segments:)   // iOS 27
>
> // Transcript.ToolCall
> init(id:toolName:arguments:)          // iOS 26
> init(id:metadata:toolName:arguments:) // iOS 27
>
> // Transcript.ToolCalls
> init(id:_:)
>
> // Transcript.ToolOutput
> init(id:toolName:segments:)
> ```
>
> Note the pattern: **every iOS 27 entry type gained a `metadata:` parameter.** That is how custom
> `LanguageModel` providers thread provider-specific data through the transcript.

The load-bearing line in that block is `Transcript.Instructions.toolDefinitions`. **Your tool
schemas live inside entry 0.** They are not appended alongside the tool call; they are declared up
front, in the most cache-sensitive position in the sequence. §8.3 is where that bill comes due.

### 2.2 The cost table

Here is every entry type against what it costs and when it is re-sent. Everything in the "cost"
column traces to Apple's own inventory line quoted in §1.1; the annotations are the operational
reading.

| Entry | Written by | Occupies budget | Re-sent every request? | Notes |
|---|---|---|---|---|
| `.instructions` | you | prose **+ every tool's name, description and parameter schema** | yes, at position 0 | Editing it invalidates *everything*. See §8.3. |
| `.prompt` | user (usually) | text, plus **image attachments** and `responseFormat` | yes | Attachments are billed in tokens, not bytes — §2.4. |
| `.response` | model | full generated text | yes | Every past answer keeps costing you on every future turn. |
| `.reasoning` | model (27.0) | intermediate reasoning tokens | yes | **Does not appear in `.content`.** Invisible in your UI, visible in your budget. |
| `.toolCalls` | model | tool name + generated arguments | yes | Cheap individually; they accumulate fast in agentic loops. |
| `.toolOutput` | your tool | whatever your `call(arguments:)` returned | yes | The single most common budget blowout. A tool that returns a JSON blob returns it *forever*. |

Two entries deserve their own paragraphs.

**`.reasoning` is the one that surprises people.** Apple is explicit that reasoning consumes window
and is not visible in the response:

> ✅ **VERIFIED** — from the PCC article: *"The more reasoning you apply causes the model to use more
> of the context window… **Reasoning segments reflect the model's intermediate reasoning and don't
> appear in the final response content.**"*

So `.deep` reasoning is not only slower, it is *quieter* about its cost. You will not see it in your
UI and you will not see it in `response.content`. You will see it in `Usage.Output.reasoningTokenCount`
(§5) and in the moment your session throws.

**`.toolOutput` is the one that kills sessions.** A tool that returns 800 tokens of search results is
a permanent 800-token tax on every subsequent turn of that session, whether or not the model ever
refers to it again. This is exactly why Apple's utilities package ships a modifier whose entire job
is to evict them (§7.3).

### 2.3 Segments: the second dimension

Each entry holds an ordered list of `Transcript.Segment`s.

> ✅ **VERIFIED** — `/documentation/foundationmodels/transcript/segment`:
>
> | Case | Description |
> |---|---|
> | `.text(_:)` | "A segment containing text." |
> | **`.attachment(_:)`** | "A segment containing an attachment." **(NEW iOS 27)** |
> | `.structure(_:)` | "A segment containing structured content." |
> | `.custom(_:)` | "A segment containing custom content." |
>
> Payload types: `Transcript.TextSegment(id:content:)`;
> `Transcript.StructuredSegment(id:source:content:)` (and an older `(id:schemaName:content:)`);
> `Transcript.AttachmentSegment(id:content:label:)` (iOS 27); `Transcript.CustomSegment` with an
> associated `Content` type.

> ⚠️ **Beta 5: `.custom` is not present in the SDK interface (noted 2026-08-23).** The docs table
> above still lists four cases, but the recaptured 27.0 beta 5 interface declares exactly **three**
> — `.text`, `.structure`, `.attachment`
> (`FoundationModels-27.0-macos.swiftinterface:2288-2297`) — and contains **zero occurrences of
> `CustomSegment`**. The case and its protocol were present in the 2026-07-29 beta capture; the
> removal happened between that capture and beta 5. Not a permanent claim — the surface may return —
> but code matching `.custom(_:)` does not compile against the beta 5 SDK.

`.structure` is what a `@Generable` tool output or a guided-generation response becomes.
`.attachment` is what an image becomes. `.custom` **was** the documented extension point for
third-party providers — see the note above and
[Part 4 §13.2](../../part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md)
for the provider-side status and safe default.

> ⚠️ **SILENT FAILURE — anything that is not `.text` disappears when you summarise.** Apple's own
> `foundation-models-utilities` renders a transcript to text before handing it to a summariser
> model, and that renderer drops structured content and attachments on the floor without comment:
>
> ✅ **VERIFIED** — `TranscriptRendering.swift:53-60`:
> ```swift
> extension Sequence where Element == Transcript.Segment {
>     var textContent: String {
>         compactMap { segment in
>             if case .text(let textSegment) = segment { return textSegment.content }
>             return nil                       // ← .structure, .attachment, .custom: gone
>         }
>         .joined(separator: " ")
>     }
> }
> ```
> And `.instructions` renders to `nil` outright (`TranscriptRendering.swift:35`), so
> **the summariser never sees your system prompt.** Nothing throws, nothing warns; you simply get a
> summary of a conversation with the structured parts and the instructions removed. If your session
> carries images or `@Generable` tool outputs that matter, `summarizeHistory` is not a safe default
> — write your own modifier (Apple's own designer says as much; see §7.4).

### 2.4 Images are tokens

> ✅ **VERIFIED** — WWDC26 session 241 (`241:L26-27`): *"The model supports **images in any size and
> aspect ratio, so you don't need to crop or pad to any particular shape**. Arbitrary image sizes are
> allowed, but bear in mind that **larger images will consume more tokens and incur more latency**."*

> ✅ **VERIFIED** — Apple Frameworks Engineer, forum thread 833642: **no set resolution restriction**
> (the framework may resize); **unlimited image count per prompt, bounded only by the context
> window**; image input **does not change which model services the request** — an on-device call
> stays on-device.

"Unlimited, bounded only by the context window" is a polite way of saying *you* are the bound. There
is no published token cost per image.

> 🔴 **GAP — the token cost of an image is unpublished.** Nobody in our corpus has a number for how
> many tokens a `CGImage` of a given size becomes. Forum thread 833783 asks and is unanswered; thread
> 838613 contains a developer's *inference* that the framework downsamples to **896 px on the longest
> dimension**, which we are recording as a hypothesis and explicitly **not** as a fact. What would
> resolve this: `SystemLanguageModel.tokenCount(for:)` applied to a `Prompt` containing exactly one
> attachment, at several resolutions, on a real device. Until someone runs that, **treat every image
> as an unknown large constant** and measure your own session with `Usage` (§5) rather than
> predicting it.
>
> That exact experiment now exists as `probes/` `fm.image-token-cost` and was run 2026-07-31 — but
> **the 27.0 sim runtime cannot answer it**: every attachment size from 128 px to 1792 px errored
> with `LanguageModelError -1` (image/attachment assets are among what the sim runtime lacks; only
> the no-attachment baseline measured, at 6 tokens). The gap stays open and is now known to require
> MAC-27 or DEVICE-27, not the Simulator.

### 2.5 Schemas are tokens too

Every `@Generable` type in a request is converted to a JSON schema and sent to the model.

> ✅ **VERIFIED** — from the `Generable` page: *"For every `Generable` type in a request, the
> framework converts its type and format information to a JSON schema and provides it to the model.
> This contributes to the available context window size… To reduce the size of your generable type:
> reduce the complexity … by evaluating whether properties are necessary; give your properties short
> and clear names; use `Guide(description:)` on properties only when it improves response quality;
> add a `Guide(description:_:)` with `maximumCount(_:)` to reduce token usage."*

Two of those four bullets are about *naming*, which tells you the schema is serialised with your
Swift identifiers in it. `veryDescriptivePropertyNameForClarity` is a real cost, paid on every
request, forever.

The most extreme documented case of schema-as-budget is Apple's own `SpotlightSearchTool`:

> ✅ **VERIFIED (community-measured)** — field testing recorded in our corpus
> (`spotlight-rag-third-party.md:87-92`): *"**Guidance level is a token gate.** `.complete` guidance
> injects **~13 k tokens** of tool instructions → instant `contextSizeExceeded` on any 4 k-context
> model (system or zoo). Ship `.focused(.items)` + `format: .compact` for local models."*
> This is a **community measurement**, not an Apple figure — hardware, OS build and date were not
> recorded. It corroborates WWDC26 session 246's own recommendation (`246:80`): *"On-device models
> have a more restricted model context size, so it's best to use **focused** guidance for simpler
> search capabilities."*

Thirteen thousand tokens of tool instructions against a four-thousand-token window is not a tuning
problem, it is an immediate hard failure. See
[`../../part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md`](../../part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md)
for the guidance-level API itself.

### 2.6 Apple's six recommendations — work these before anything in §7

Apple publishes exactly one canonical list of mitigations, in **TN3193** and its companion article.
It outranks every technique in §7, because §7's levers all cost you either fidelity or cache and these
six cost you neither. Work them top to bottom **before** you reach for a history modifier.

> ✅ **VERIFIED** — TN3193, *Managing the on-device foundation model's context window*
> (`/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window`,
> fetched 2026-07-27), in Apple's own order:
>
> | # | Recommendation | Concretely |
> |---|---|---|
> | 1 | **Split tasks across multiple sessions** | Break the job into smaller steps, give each step its own session, combine the results yourself. Each session gets its own 4096. |
> | 2 | **Request less content** | State the target length *in the prompt* ("In 3 sentences…"), and bound collections with `Guide(description:)` + **`maximumCount(_:)`**. The response shares the window with the input. |
> | 3 | **Reduce prompt size** | Concise language; **one to three paragraphs maximum**. |
> | 4 | **Use `Generable` types efficiently** | Minimise type complexity, prefer **short property names**, apply **`@Guide` sparingly** — the schema is re-sent per request (§2.5), so every guide string is a recurring cost. |
> | 5 | **Optimise tool calling** | Brief tool descriptions, **three to five tools per request**, and consider **running the tool *before* calling the model** and putting its output in the prompt. |
> | 6 | **Implement RAG** | Fetch the relevant snippets dynamically instead of passing a whole knowledge base into the window. |

Where the leverage actually is: **1 and 6 change the shape of the feature**; 2–5 shave the fixed costs
priced in §2.2. For 6, the framework ships you most of a retriever — see
[`../../part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md`](../../part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md)
for `SpotlightSearchTool`, and note that its `.complete` guidance level is itself a ~13,000-token
object — a RAG tool that overflows the window is not RAG. For 4, the schema-cost mechanics are in
[`../../part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md`](../../part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md).

The companion article says the same things at prose length, and its exact wording is worth having for
recommendations 3 and 5:

> ✅ **VERIFIED** — `/documentation/foundationmodels/managing-the-context-window`, verbatim:
>
> - *"Use imperative verbs that clearly state what you want the model to do: 'Generate a story
>   about…,' or 'List five reasons why…'."*
> - *"Provide only the information the model needs for the specific task."*
> - *"Avoid lengthy background information, policies, or unnecessary context."*
> - *"**Reduce prompts to no more than three paragraphs in length.**"*
> - *"Eliminate indirect language, excessive formality, and ambiguous jargon."*
>
> And for tools: *"Limit tool descriptions and `@Guide` annotations to short phrases."*
> *"**Provide no more than three to five tools per request.**"* *"Skip tool calling when you don't
> need the model to make decisions. If the model always needs specific information, retrieve it
> directly and include it in your prompt rather than relying on tool calling."*

That last one is the most under-used advice in the framework. A tool costs you its schema in entry 0
*plus* a whole extra model inference *plus* its output forever. If you already know you need the
data, put the data in the prompt.

There is a counter-intuitive empirical result that cuts against "write a really thorough prompt":

> ✅ **VERIFIED** — WWDC26 session 334 (`334:L148-152`), from an evaluation run over three prompt
> variants: *"First, by looking at the errors generated by setup, I can see that **the detailed
> prompt leads to a high percentage of generation errors. This can happen, for example, when we reach
> the model's max context window size.**"* … *"the two less detailed prompts tend to lead to excess
> items added to the cart, while the more detailed one has less excess items. However, with the more
> detailed prompts, **we tend to miss more items that were expected**."*

So longer, rule-heavier prompts trade recall for precision **and** raise your overflow rate. There is
no monotone "more prompt is better". This is the single best argument in the 2026 material for
[Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md) — you cannot reason your way to the right prompt length.

---

## 3. Reading the budget: `contextSize` and the 4096-token window

### 3.1 The API

> ✅ **VERIFIED** — `/documentation/foundationmodels/systemlanguagemodel/contextsize`:
> ```swift
> @backDeployed(before: iOS 26.4, macOS 26.4, visionOS 26.4)
> final var contextSize: Int { get }
> ```
> The same property exists on the server model:
> ```swift
> final class PrivateCloudComputeLanguageModel   // iOS 27.0+ Beta
> var contextSize: Int
> ```
> (`/documentation/foundationmodels/privatecloudcomputelanguagemodel`)

> ✅ **VERIFIED** — WWDC26 session 319 (`319:59-60`): *"Speaking of context size, we also added a
> convenient API to let you **programmatically get the context size for a model**. Just access the
> **`contextSize`** property on **either `SystemLanguageModel` or
> `PrivateCloudComputeLanguageModel`**."*

Note the `@backDeployed` attribute carefully, because it is the difference between "26.4 or bust" and
"works everywhere": the symbol was *introduced* in 26.4, but its implementation is emitted into your
binary, so **an app built with the 26.4-or-later SDK can call `contextSize` on a device running 26.0**.
That is corroborated by Apple's own Python SDK, which gates its token-counting bridges behind
`#available(macOS 26.4, …)` but **does not gate the context-size bridge at all**:

> ✅ **VERIFIED** — `apple/python-apple-fm-sdk`, from the C header and the Swift shim:
> `FMSystemLanguageModelGetContextSize` (bridging `model.contextSize`) **is not `#available`-gated —
> it is available on 26.0** — while every `tokenCount` bridge is wrapped in
> `guard #available(macOS 26.4, iOS 26.4, visionOS 26.4, *)`.

### 3.2 The Apple-published numbers

> ✅ **VERIFIED** — `/documentation/foundationmodels/managing-the-context-window`: *"Apple's on-device
> foundation model has a context window of **4096 tokens per session**, with a token representing each
> word, or partial word. In Latin alphabet languages such as English, **a token typically represents
> three to four characters**. For multibyte languages such as **Chinese, Japanese, Korean, and
> Vietnamese a token typically represents one character**."*

That last sentence is a localisation trap worth pausing on. A 300-character Japanese prompt costs
roughly **three to four times** what the same information costs in English. If your app ships in CJK
markets, your English-language budget testing is optimistic by a factor of three.

The on-device / PCC comparison is published in two places that agree exactly:

> ✅ **VERIFIED** — `/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute`,
> verbatim table:
>
> | Capability | `SystemLanguageModel` | `PrivateCloudComputeLanguageModel` |
> |---|---|---|
> | Preserves privacy | ✅ | ✅ |
> | Works offline | ✅ | 🚫 |
> | Usage limits | Unlimited | Limit per day |
> | Reasoning | Not supported | Multiple levels |
> | **Context size** | **4K** | **32K** |
>
> and WWDC26 session 319 (`319:38-45`) narrates the identical five-row table with the identical
> values. Session 241 (`241:L31`) states the PCC figure as **32,000 tokens**.

> ✅ **VERIFIED** — the PCC article again: *"The server-based model — accessed through Private Cloud
> Compute (PCC) — provides a larger **32K-token context size** and stronger reasoning for handling long
> documents or extended multiturn conversations."*

One historical note for anyone reading older forum threads: the 32K figure was *also* circulating as
a community claim (a non-Apple reply in thread 833642), and our earlier corpus flagged it as
"community-sourced, not Apple-confirmed." **That caveat is now retired** — the documentation table and
two WWDC sessions publish it. 32K is Apple-published.

### 3.3 ✅ The on-device figure is 4096 — settled by TN3193

Earlier drafts of this guide presented 4096-vs-8192 as an equal-weight conflict. **It is not one.**
Apple's technote states the documented platform value plainly; the single unverified 8192 comment
is retired historical provenance, not an active alternative.

> ✅ **VERIFIED** — Apple Technical Note **TN3193**, *Managing the on-device foundation model's
> context window*
> (`/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window`,
> fetched 2026-07-27): the on-device model has a context window of **4096 tokens per
> `LanguageModelSession`**, covering instructions, prompt, tools, schemas, transcript history *and*
> the response. Note the scoping word: **per session**, not per app and not per device.
>
> Corroborated by: the context-window article (*"a context window of 4096 tokens per session"*), the
> PCC comparison table (4K), WWDC26 session 319's spoken table (4K), and Apple's own DTS engineer on
> forum thread 790736 — *"You are correct that currently the token limit for Foundation Models
> framework is **around 4,000**."*
>
> ✅ **Fifth Apple channel, and the one that names iOS 27 explicitly (2026-08-02).** Apple's
> published Q&A summary for WWDC26 Group Lab **8121** records a question about the on-device
> context window in iOS 27 and whether input plus output share one budget. The written summary
> gives **4096 tokens as the on-device shared budget**, illustrates that a 4,000-token input leaves
> roughly 96 tokens for the response, and gives **32K as PCC's shared budget** (ch. `0:08:11`).[^ctx-grouplab-8121]
>
> Two things this adds that TN3193 does not. First, **it is scoped to iOS 27 by the question
> itself**, which is what the noema comment claims changed. That makes 4096 Apple's documented
> iOS 27 platform value and retires the alleged device-specific 8192 observation from active guidance.
> Second, it states the **shared input+output budget** as an arithmetic rule with a worked example,
> which is the framing §4 depends on.

[^ctx-grouplab-8121]: WWDC26 Group Lab **8121**, *"Coding Intelligence, Machine Learning & AI Group
    Lab"*, `https://developer.apple.com/videos/play/wwdc2026/8121/`. ⚠️ Apple publishes **no
    caption track** for group labs — only a chaptered Q&A index with Apple's own written summary
    per answer. Cite as Apple's paraphrase of the panel, never as an engineer's spoken words.
    Analysis: `notes/web/2026-08-02-harvest/wwdc2026-8121-ml-ai-group-lab.md`.

> 📎 **Retired community claim.** A frozen Noema 3.5 snapshot once carried an uninstrumented comment
> claiming 8K on iOS 27. The upstream is now unavailable, the claim had no device/build/date, and it
> has not reproduced in any project-run simulator, Mac, or physical-device lane. It remains historical
> provenance only, not a competing baseline. The useful lesson survives: read the dynamic property.

> ✅ **New SDK evidence (2026-07-29), and it cuts both ways.** The captured interfaces expose
> `contextSize`'s inlinable getter body. In the **26.5 SDK** it is a hardcoded
> `return 4096` — the back-deployed implementation returns the constant unconditionally
> (`FoundationModels-26.5-macos.swiftinterface:634-642`). In the **27.0 SDK** the same getter
> becomes `if #available(iOS 27.0, macOS 27.0, …) { return _contextSize }` — a call into the
> framework — `else { return 4096 }` (`FoundationModels-27.0-macos.swiftinterface:445-503`). Read
> what that does and does not establish: on any pre-27 runtime the answer is the compiled-in
> constant **4096, always**; on a 27 runtime the value is **dynamic**, so a device *could* report
> something else — the plumbing the noema comment would require genuinely exists — but the
> interface does not show what `_contextSize` returns, and no Apple source publishes a figure
> other than 4096. TN3193's number stands as the documented expectation; §3.4's read-don't-hardcode
> rule is now visibly what the SDK itself is built for.

> ✅ **Probe-verified on simulator, Mac, and hardware.** On 2026-07-31, `probes/` `fm.contextSize`
> measured **4096** on the macOS 26.5 host and iOS 27 simulator, where the dynamic `_contextSize`
> path is live. The simulator's context-overflow error independently reads *"…exceeds the maximum
> allowed context size of 4096"* (`fm.error-domain-context-overflow`). On **2026-08-20**, the same
> probe measured **4096 on a physical iPhone 15 Pro** (`iPhone16,1`, iOS 27.0 beta-5 build
> `24A5408d`, Xcode `27A5237l`). The project now has a real 27-hardware answer and it still does
> not corroborate the old 8192 source comment. On 2026-09-16, stable macOS 27 (`26A428`) and an
> iPhone 15 Pro on iOS 27 build `24A435` again returned **4096**. The phone build is not Apple's
> public-final `24A437`, so record it separately; the result still does not make 4096 safe to hardcode.

**Why this does not make the number safe to hardcode.** Apple's 26.4 announcement said the point of
these APIs is *"to adapt your app to the hardware it's running on"* (session 241, `241:L14-19`);
`PrivateCloudComputeLanguageModel` reports **32K** through the same property; and dynamic profiles can
put one transcript in front of models with an 8× window difference (§3.5). 4096 is what to *expect* on
device today, and what to fall back to when the runtime will not answer — not what to compile in.

### 3.4 The rule: read it, don't hardcode it

**Read `contextSize`. Never hardcode.** The defensive shape that the shipping app above uses is the
right one, and it generalises:

```swift compile:27
import FoundationModels

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
enum ContextBudget {

    /// The model's window in tokens, or a conservative floor when the value is
    /// unavailable or nonsensical.
    ///
    /// `contextSize` is `@backDeployed(before: iOS 26.4, …)`, so this compiles and runs
    /// on 26.0 as long as you build with the 26.4 SDK or later. Treat any value <= 0 as
    /// "the runtime didn't tell me" rather than as a real answer.
    static func onDevice(_ model: SystemLanguageModel = .default) -> Int {
        let reported = model.contextSize
        return reported > 0 ? reported : 4_096      // documented floor, not a guess
    }

    /// Reserve headroom so the *response* has somewhere to go. The window covers input
    /// AND output; a prompt that exactly fills it leaves the model nothing to say.
    static func inputBudget(of total: Int, reservingForResponse response: Int = 512) -> Int {
        max(0, total - response)
    }
}
```

Three things about that snippet are load-bearing:

- **`reported > 0` is not paranoia.** The shipping app that inspired it treats `<= 0` as "unknown",
  and the Python bridge returns a plain `Int32` with no error channel. A zero or negative reading is
  a real possibility on a device where the assets have not landed.
- **4,096 is Apple's published figure, used here only as a fallback** — the value you take when the
  runtime declines to answer. Whatever the model reports, you use; on PCC that is 32K through the same
  property.
- **The reserve.** Apple's own description of `contextSize` in the Python SDK is unambiguous that
  the number covers both directions: ✅ *"The context size is the total number of tokens (prompt,
  instructions, tools, and response combined) that the model can process in a single session."*
  (`apple/python-apple-fm-sdk`, `core.py` docstring). Budget your input against
  `contextSize − expected response`, not against `contextSize`.

> ⚠️ **SILENT FAILURE — a hardcoded 4096 that is smaller than the real window costs you context and
> nothing tells you.** The certain case is PCC and profile switching, where the same code path meets a
> **32K** window: budget it at 4096 and you compact eight times more often than you need to, summarise
> away context the model could have used, and answer slightly worse than the app that read the
> property. There is no warning, no log line, no Instruments flag. This is the cheapest bug in this
> guide to avoid and the hardest to notice.

### 3.5 The other reason to read it at runtime: profile switching

If you use dynamic profiles to move between models mid-session, the *same transcript* is presented to
models with a 8× difference in window size. Apple's guidance on this is explicit and comes from an
Apple engineer, in answer to exactly this question:

> ✅ **VERIFIED** — Apple Frameworks Engineer, Developer Forums thread 833626 (marked as the accepted
> answer), in response to *"When using Dynamic Profiles to switch between the on-device model and
> Private Cloud Compute mid-session, how is the context window reconciled?"*:
>
> *"By default, the same transcript is shared between each Profile. So if you move from a Profile
> using `PrivateCloudComputeLanguageModel` to one using `SystemLanguageModel` and the transcript is
> over `SystemLanguageModel`'s context size limit, **you'll hit a context limit exceeded error**. The
> recommended approach here is to apply the **`historyTransform`** modifier to your
> `SystemLanguageModel` Profile. There are also some other common strategies like using the
> 'phone-a-friend' pattern or session properties as well."*

That is the same advice session 242 gives (`242:64`: *"it's important to consider that **each model
may have different context size limits**"*), and it is why Apple's own Origami sample attaches
`.historyTransform(shortHistory(_:))` to precisely the on-device branches of its profile and to
nothing else (§7.2).

---

## 4. Counting before you spend: `tokenCount(for:)`

### 4.1 What shipped, and when

> ✅ **VERIFIED** — `/documentation/foundationmodels/systemlanguagemodel/tokencount(for:)`,
> availability `iOS 26.4+, iPadOS 26.4+, Mac Catalyst 26.4+, macOS 26.4+, visionOS 26.4+`:
> ```swift
> nonisolated(nonsending)
> final func tokenCount(for instructions: Instructions) async throws -> Int
> ```

> ✅ **VERIFIED** — Apple's February 2026 changelog entry for the framework
> (`/documentation/updates/foundationmodels`): *"Measure how many tokens your prompt, instructions, or
> entire session transcript uses with `tokenCount(for:)`."* and *"Use the `contextSize` property to get
> the maximum context size — in tokens — that the `SystemLanguageModel` supports."*

> ✅ **VERIFIED** — WWDC26 session 241 (`241:L14-16`): *"**In iOS 26.4, we released new APIs for
> inspecting the model's context size and counting the tokens in instructions, prompts, and
> transcripts. You'll want to use these going forward to adapt your app to the hardware it's running
> on.**"*

The doc page only shows the `Instructions` overload, but the changelog says "prompt, instructions, or
entire session transcript", and Apple's own Python SDK bridges **five** distinct call sites:

> ✅ **VERIFIED** — `apple/python-apple-fm-sdk`, C header + Swift shim call sites. The C entry
> points are:
> ```c
> FMSystemLanguageModelTokenCountForPrompt(...)
> FMSystemLanguageModelTokenCountForInstructions(...)
> FMSystemLanguageModelTokenCountForTools(...)
> FMSystemLanguageModelTokenCountForSchema(...)
> FMSystemLanguageModelTokenCountForTranscript(...)
> ```
> and the note in that repo records the underlying Swift calls being bridged as
> `model.tokenCount(for: prompt)`, `model.tokenCount(for: instructions)`,
> `model.tokenCount(for: [any Tool])`, `model.tokenCount(for: schema)`,
> `model.tokenCount(for: transcript)` on `SystemLanguageModel`.

> ✅ **VERIFIED — that all five *exist*.** TN3193 states that `tokenCount(for:)` covers
> **instructions, prompts, tools, schemas and transcript entries**, which independently corroborates
> the five call sites in Apple's Python bridge. The *existence* of the multi-overload family is no
> longer a reconstruction.

> ✅ **VERIFIED in the 26.5 SDK interface — the exact Swift declarations of all five overloads;
> stable into 27 unless noted.** Apple's compiler-emitted `FoundationModels.swiftinterface`
> (`MacOSX26.5.sdk`, module 1.5.2, lines 599–623) publishes the whole family. They shipped in 26.4
> (`@available(iOS 26.4, macOS 26.4, visionOS 26.4, *)`, with `tvOS`/`watchOS` unavailable) and every
> one is `final`, `nonisolated(nonsending)`, `async throws -> Int`:
> ```swift
> nonisolated(nonsending) final func tokenCount(for prompt: some PromptRepresentable) async throws -> Int
> nonisolated(nonsending) final func tokenCount(for instructions: Instructions) async throws -> Int
> nonisolated(nonsending) final func tokenCount(for tools: [any Tool]) async throws -> Int
> nonisolated(nonsending) final func tokenCount(for schema: GenerationSchema) async throws -> Int
> nonisolated(nonsending) final func tokenCount(for transcriptEntries: some Collection<Transcript.Entry>) async throws -> Int
> ```
> This closes the overload gap completely, and it corrects the earlier reconstruction on two points:
> the first overload takes **`some PromptRepresentable`, not `Prompt`**, and the last takes
> **`some Collection<Transcript.Entry>`, not a whole `Transcript`** — though a `Transcript` *is* such a
> collection (§1), so `tokenCount(for: session.transcript)` in §4.3 still resolves to it. The
> `nonisolated(nonsending)` / `async throws` shape is now confirmed from the interface, not inferred.

### 4.2 The version floor that makes this awkward

`contextSize` back-deploys. **`tokenCount(for:)` does not.**

> ✅ **VERIFIED** — the Swift shim in `apple/python-apple-fm-sdk` wraps **every** token-count binding
> in `guard #available(macOS 26.4, iOS 26.4, visionOS 26.4, *) else { throw … }`, and the error it
> throws says so verbatim: *"Token counting requires macOS 26.4, iOS 26.4, or visionOS 26.4 or
> later."* The context-size bridge has no such guard.

So if your deployment target is 26.0, you get to *know* how big the window is but not how much of it
you are using. That asymmetry is why §5 (`Usage`, iOS 27) and §6 (catch-and-recover, iOS 26) both
matter: pre-flight counting is a 26.4+ luxury, and **catching the overflow is the only strategy that
works everywhere**.

### 4.3 Using it

The honest use of `tokenCount(for:)` is as a *threshold trigger*, not as an exact ledger — you call it
on the transcript, compare against a fraction of `contextSize`, and compact when you cross the line.

```swift compile:27
import FoundationModels

@available(iOS 26.4, macOS 26.4, visionOS 26.4, *)
struct ContextMeter {
    let model: SystemLanguageModel

    /// Fraction of the window currently occupied by the session transcript.
    /// Returns nil if the model won't tell us how big the window is.
    func utilisation(of session: LanguageModelSession) async throws -> Double? {
        let capacity = model.contextSize
        guard capacity > 0 else { return nil }
        let used = try await model.tokenCount(for: session.transcript)
        return Double(used) / Double(capacity)
    }

    /// Compact only when we're genuinely close. See §8.8 — batching one big
    /// consolidation beats trimming a little after every turn.
    func shouldCompact(_ session: LanguageModelSession,
                       threshold: Double = 0.75) async throws -> Bool {
        guard let u = try await utilisation(of: session) else { return false }
        return u >= threshold
    }
}
```

Three notes on that:

- **`async throws`.** Token counting is not free and not synchronous; it dispatches. Do not call it in
  a SwiftUI `body`.
- **`0.75`, not `0.98`.** You need room for the *next* prompt plus the *next* response plus, on PCC,
  the reasoning tokens you cannot see. A threshold that leaves 25% headroom is defensible; one that
  leaves 2% is a bug waiting for a long user question.
- **Compact on a boundary, not on a timer.** §8.8 has the reason: frequent small edits force repeated
  cache invalidations, and Apple explicitly tells you to defer and consolidate.

### 4.4 What it will not tell you

`tokenCount(for:)` is a `SystemLanguageModel` method. It is not on the `LanguageModel` protocol.

> ✅ **CONFIRMED against the 27.0 beta interface (2026-07-29) — there is no way to count tokens for
> a non-system model.** All five `tokenCount(for:)` overloads are `final` methods on
> `SystemLanguageModel` (✅ **SDK-verified**, `FoundationModels-27.0-macos.swiftinterface:402-436`);
> the `LanguageModel` protocol's complete requirement set is `capabilities` +
> `executorConfiguration` + the `Executor` associated type (`:1483-1487`) — no `tokenCount`; and
> `PrivateCloudComputeLanguageModel`'s surface (`:45-256`) has `contextSize` (an `async throws`
> `Int` property, `:135-137`) but no `tokenCount` either. So on PCC or a bring-your-own-model
> backend, your only token accounting is `Usage` *after* the fact (§5), or a tokeniser you own.
> **Safe default:** meter with `SystemLanguageModel.tokenCount(for:)` even when you intend to run
> on PCC — the tokenisers differ, so the number is an estimate, but an estimate that is 32K-safe is
> also 4K-safe if you are budgeting for the smaller model, which is the direction that matters.

---

## 5. Counting after you spend: `Usage` and the cache-hit rate

`Usage` is new in 27 and is the only place the framework tells you what a request actually cost.

> ✅ **VERIFIED** — the `Usage` family, from `/documentation/foundationmodels/languagemodelsession/usage`
> and its children (all iOS 27.0+):
> ```swift
> struct Usage
> init(input:output:metadata:)
> var input: Usage.Input
> var output: Usage.Output
> var metadata
> var totalTokenCount
>
> struct Usage.Input
> init(totalTokenCount:cachedTokenCount:)
> var totalTokenCount
> var cachedTokenCount          // ← the cache-hit numerator
>
> struct Usage.Output
> init(totalTokenCount:reasoningTokenCount:)
> var totalTokenCount
> var reasoningTokenCount       // ← the invisible cost from §2.2
> ```
> `Usage.metadata` doc: *"Language models that provide other kinds of usage statistics may encode them
> in metadata."*

It is reachable from three places:

> ✅ **VERIFIED** — `Response.usage` (iOS 27), `ResponseStream.Snapshot.usage`, and
> `LanguageModelSession.usage` all exist (from the `LanguageModelSession` class page and the
> `Response` / `Snapshot` member lists).

WWDC26 session 241 gives the design intent, and it is worth reading because it explains why
`cachedTokenCount` exists at all:

> ✅ **VERIFIED** — `241:L54-56`: *"As a developer, you'll typically be **billed per-token** when
> using 3rd party models, so we've made [usage] available… **You can also check how many of the input
> tokens were read from cache, and how many of the response tokens were used for reasoning.**"*

### 5.1 The cache-hit rate

This is the single most useful derived number in this guide, and Apple publishes the formula:

> ✅ **VERIFIED** — the KV-caching article: *"determine your **cache hit rate** by dividing the
> **cached input tokens** by the **total input tokens**."*

```swift compile:27
import FoundationModels

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
extension LanguageModelSession.Usage {
    /// Fraction of this request's input tokens that were served from the KV prefix cache.
    /// 1.0 means "everything before the new prompt was reused"; 0.0 means a full re-prefill.
    var cacheHitRate: Double {
        let total = input.totalTokenCount
        guard total > 0 else { return 0 }
        return Double(input.cachedTokenCount) / Double(total)
    }
}

// Use it as a regression alarm, not a dashboard ornament.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
func logIfCacheCollapsed(_ response: LanguageModelSession.Response<String>) {
    let rate = response.usage.cacheHitRate
    if rate < 0.5 {
        // On turn 2+ of a steady conversation this should be high. A sudden
        // collapse means something changed the PREFIX — instructions, tools,
        // or an entry you edited. See §8.
        print("⚠️ KV cache hit rate \(String(format: "%.0f%%", rate * 100)) — prefix changed?")
    }
}
```

**What "good" looks like:** turn 1 is always ~0 (nothing to reuse). From turn 2 onward, an
append-only session should be close to 1.0, because everything except the newest prompt was already
processed. A hit rate that is high and then suddenly drops is the fingerprint of a prefix mutation,
and it is the signal §8 teaches you to read.

> ⚠️ **SOURCE CONFLICT worth knowing about.** WWDC26 session 242 (`242:176-177`) sends you to session
> 243 "for more about **detecting cache invalidations with Instruments**" — but **session 243 never
> mentions a cache metric at all.** It names exactly three metrics: Time to First Token, Tokens per
> Second, and Total Latency (`243:131-139`). The cache-hit-rate metric appears only in the written
> documentation (the KV-caching article and the runtime-performance article). If you go looking for a
> "cache" readout in the Instrument on the strength of 242's pointer, you may not find one; the number
> you can definitely compute is the one above, from `Usage`.

### 5.2 What the Instrument gives you instead

> ✅ **VERIFIED** — WWDC26 session 243 (`243:81-83`): *"**The Model Inference lane has two types of
> bars: yellow and orange. Yellow bars represent how long the system spent processing the input
> prompt. Orange bars represent how long it took to generate the response.**"*

That colour legend is the fastest read in the whole trace, and it maps directly onto this guide:

- 🟨 **Yellow = prefill.** This is the bar that KV-cache economics controls. A long yellow bar on
  turn 5 of a conversation means your prefix was invalidated.
- 🟧 **Orange = decode.** This is generation. Shorten it with `maximumResponseTokens` (carefully — see
  §13) or hide it with streaming.

> ✅ **VERIFIED** — `243:132-139`, the three metrics verbatim: Time to First Token *"measures how long
> it takes for the model to begin generating a response after receiving a prompt"* — *"A high Time to
> First Token means people are staring at a blank screen. To reduce it, shorten your prompt."*
> Tokens per Second *"measures overall generation speed."* Total Latency *"the complete time from
> sending the request to receiving the final response… **To reduce perceived Total Latency, utilize
> streaming to surface partial results sooner.**"*

Note the precision of that last one: streaming reduces **perceived** latency. Prefix reuse reduces
**actual** time-to-first-token, which is why §9's numbers are stated as TTFT.

The full Instruments workflow is out of scope here; it is covered in
[Part 5](../../part-05-prototyping-profiling-non-swift/README.md). The one operational warning worth repeating:

> ✅ **VERIFIED** — the privacy dialog, verbatim from `243:57-59`: *"**This instrument captures prompt
> and response data from your device, which can include sensitive information. Logging is off in
> production but it's on for the duration of your trace so keep your trace files somewhere safe.**"*
> Treat `.trace` files as sensitive artefacts: do not commit them, do not attach them to public bug
> reports unscrubbed.

---

## 6. Overflow: `.contextSizeExceeded` and the pattern people hand-rolled

### 6.1 The error, in both spellings

The 2026 release reshuffled the error types. For context overflow specifically:

> ✅ **VERIFIED** — `LanguageModelError` (iOS 27.0+), from
> `/documentation/foundationmodels/languagemodelerror`. The context case and its payload:
>
> | Case | Payload struct | Apple's description |
> |---|---|---|
> | `.contextSizeExceeded(_:)` | `LanguageModelError.ContextSizeExceeded` | *"The session's transcript exceeded the model's context size."* |
>
> `LanguageModelError.ContextSizeExceeded` has
> `init(contextSize:tokenCount:debugDescription:metadata:)`, i.e. **the error tells you both the
> budget and what you tried to spend.** Apple's `foundation-models-utilities` skill documentation
> lists the same two payload fields — `contextSize: Int`, `tokenCount: Int` — plus the
> `debugDescription: String` and `metadata: [String: any Sendable]` that every payload struct carries.

> ✅ **VERIFIED** — the deprecated ancestor, `LanguageModelSession.GenerationError` (iOS 26.0, no
> watchOS), frontmatter `deprecated: true`, cases including `.exceededContextWindowSize(_:)`.
> The deprecation notice, verbatim: *"Use `LanguageModelError`, `SystemLanguageModel.Error`, or
> `LanguageModelSession.Error` instead. **Apps built with Xcode 26 will continue to catch this error
> until you rebuild with Xcode 27. You must update to Xcode 27 to catch the new error types before
> submitting your app.**"*

> ⚠️ **The two names coexist in current Apple material, and that is the migration story.** **TN3193**
> — fetched 2026-07-27, i.e. not a stale page — names the overflow error as
> **`LanguageModelSession.GenerationError.exceededContextWindowSize(_:)`**, nested under
> `LanguageModelSession`, while Apple's 2026 sample code and the `LanguageModelError` symbol page use
> **`LanguageModelError.contextSizeExceeded`**. These are the *before* and *after* of the same error,
> not a contradiction: which one your code catches is decided by the Xcode you build with. Cite both
> spellings side by side until your minimum is 27. Full before→after mapping for the whole taxonomy:
> [`../../part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md).

> ⚠️ **Latency boundary, 2026-09-16.** A deliberately large overflow returned typed
> `contextSizeExceeded` on the Mac only after 92.7 seconds; the physical-device equivalent hit the
> probe's 120-second deadline instead. Catch the typed error **and** enforce an outer product deadline.

> ⚠️ **SILENT FAILURE — a rebuild changes which `catch` clause fires.** The mapping is
> `exceededContextWindowSize` → `contextSizeExceeded`, and the two are *different types*. A codebase
> that catches `LanguageModelSession.GenerationError.exceededContextWindowSize` keeps working under
> Xcode 26 and then, after an Xcode 27 rebuild, silently stops matching — the error becomes a
> `LanguageModelError` and falls through to your generic `catch`. Nothing warns you at the call site
> because both clauses still compile. During migration, **catch both**.

The rest of the taxonomy, for context (the full ladder is in
[Part 2 guide 6](../../part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md)):

> ✅ **VERIFIED** — `LanguageModelError`'s nine cases: `.contextSizeExceeded`, `.rateLimited`,
> `.refusal`, `.timeout`, `.guardrailViolation`, `.unsupportedCapability`,
> `.unsupportedTranscriptContent`, `.unsupportedGenerationGuide`, `.unsupportedLanguageOrLocale`
> (Apple docs). Five of those nine — `.timeout`, `.guardrailViolation`, `.refusal`,
> `.contextSizeExceeded`, `.unsupportedLanguageOrLocale` — are independently confirmed as compiling
> case names by Apple's Origami sample (`Origami/Models/Error+DisplayMessage.swift:12-36`), which also
> proves the enum is **non-frozen** by ending its switch with `default: break`.

### 6.2 The ordering that matters

Apple's own sample checks the types in a specific order, and it is not the order you would guess:

> ✅ **VERIFIED** — `Origami/Models/Error+DisplayMessage.swift:12-36`, verbatim:
>
> ```swift
> extension Error {
>     /// A short message describing the error, suitable for display in the UI.
>     var displayMessage: String {
>         if self is SystemLanguageModel.Error {
>             return "Apple Intelligence isn't available right now."
>         }
>         if let modelError = self as? LanguageModelError {
>             switch modelError {
>             case .timeout:
>                 return "This is taking longer than expected. Please try again."
>             case .guardrailViolation, .refusal:
>                 return "Origami can't work with that. Try a different photo or prompt."
>             case .contextSizeExceeded:
>                 return "There's too much in this conversation. Try regenerating to start fresh."
>             case .unsupportedLanguageOrLocale:
>                 return "Origami doesn't support this language."
>             default:
>                 break
>             }
>         }
>         if self is GeneratedContent.ParsingError {
>             return "Origami had trouble understanding the response. Please try again."
>         }
>         return "Something went wrong. Please try again."
>     }
> }
> ```
>
> **`SystemLanguageModel.Error` is checked first**, before `LanguageModelError` — availability
> failures are a *different type* from generation failures and do not appear as a `LanguageModelError`
> case. `GeneratedContent.ParsingError` is a third, separate type. Note also that the cases are
> matched **without binding their associated values**, which is legal for payload cases and is what
> you want when all you need is a display string.

Also worth noticing what Apple's 2026 sample does *not* do: it never calls
`SystemLanguageModel.default.availability` before starting. The 2026 samples moved from proactive
availability gating to **reactive error catching**. (The stale iOS 26 game sample still gates; see
[Part 1 guide 2](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/references/02-platform-and-version-gating.md).)

### 6.3 Apple's documented recovery

The pattern has three steps and Apple documents it in two places — the context-window article and
**TN3193**, which ships the same example: **catch the error → create a *new* session → optionally
preserve context**, either by *summarising* the old `transcript` or by *selecting the important
entries* from it to seed the replacement. The code below takes the second option, keeping the **first
and last** entries.

> ✅ **VERIFIED** — `/documentation/foundationmodels/managing-the-context-window` and TN3193, verbatim:
>
> ```swift
> do {
>     // Perform a request that exceeds the context window.
>     let response = try await session.respond(to: prompt)
> } catch LanguageModelError.contextSizeExceeded(let context) {
>     // Handle exceeding the context window size by creating a new session.
> } catch {
>     // Handle other errors that are thrown.
> }
> ```
>
> ```swift
> func newContextualSession(with originalSession: LanguageModelSession) -> LanguageModelSession {
>     let allEntries = originalSession.transcript
>     let condensedEntries = [allEntries.first, allEntries.last].compactMap { $0 }
>     let condensedTranscript = Transcript(entries: condensedEntries)
>     let newSession = LanguageModelSession(transcript: condensedTranscript)
>     newSession.prewarm()
>     return newSession
> }
> ```
>
> With Apple's rationale: *"The first transcript entry often contains important instructions and the
> last entry contains the most recent context. By preserving the first and last entry, you maintain
> continuity while dramatically reducing token usage."*

That is a genuinely aggressive strategy — it throws away everything between the instructions and the
most recent turn. It is the right *shape* of recovery (rebuild from a condensed transcript, then
`prewarm()`), and the wrong *policy* for most apps. The reason it is in the docs is that it is
correct and unambiguous, not that it is kind to your conversation. Apple's other sanctioned policy is
**summarise the old transcript** and seed the new session with the summary — more faithful, but it
costs you an extra model round trip at exactly the moment the user is already waiting. Pick the policy
deliberately; keep the shape either way.

Note the `prewarm()` call. That is not decoration:

> ✅ **VERIFIED** — the KV-caching article: *"The session starts **without a KV cache**, so the model
> reprocesses the full transcript on the first call to `respond(to:options:)` or
> `prewarm(promptPrefix:)`… **The reprocessing latency on the first call is proportional to the size of
> the restored transcript.**"* and *"Prewarm the model when you know usage is at least **one or two
> seconds** in the future."*

So: any time you rebuild a session from a transcript — after overflow, after app relaunch, after a
restore — you have paid for a cold cache, and `prewarm()` is how you pay it before the user is
waiting rather than while they are.

### 6.4 The pattern developers hand-rolled

Before Apple shipped history modifiers, developers built this themselves, and one of them published
it and asked Apple whether it was sane. This is a useful bit of history because it shows exactly
which primitives were missing.

> ✅ **VERIFIED (forum)** — Developer Forums thread **835927** (rickystone, 2026-06-24, *"Feedback on
> Foundation Models context management wrapper"*). The developer published
> `github.com/ricky-stone/FoundationContext`, which: **checks transcript token count via
> `tokenCount(for:)`, compacts at a threshold, retries once on `exceededContextWindowSize`, then
> rebuilds a session from the compacted `Transcript`.**

Reconstructed in the shape a 26-targeting app would actually write it — this verifies on the
26-generation target and does not require any 27 API:

```swift compile:26
import FoundationModels

/// The iOS 26 idiom: meter, compact, retry once, rebuild.
/// On iOS 27 you would use `historyTransform` or the utilities' history modifiers
/// instead of rebuilding — see §6.5 and §7.
@available(iOS 26.4, macOS 26.4, visionOS 26.4, *)
actor ContextManagedChat {
    private var session: LanguageModelSession
    private let model: SystemLanguageModel
    private let instructions: String
    private let compactAt: Double        // e.g. 0.75 of the window

    init(model: SystemLanguageModel = .default,
         instructions: String,
         compactAt: Double = 0.75) {
        self.model = model
        self.instructions = instructions
        self.compactAt = compactAt
        self.session = LanguageModelSession(model: model) { instructions }
    }

    func ask(_ prompt: String) async throws -> String {
        // 1. Pre-flight: compact BEFORE we overflow, not after.
        if try await utilisation() >= compactAt {
            session = rebuiltFromCondensedTranscript()
        }

        do {
            return try await session.respond(to: prompt).content
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            // 2. Retry exactly once. If a condensed transcript still overflows,
            //    the prompt itself is the problem and looping will not fix it.
            session = rebuiltFromCondensedTranscript()
            return try await session.respond(to: prompt).content
        }
    }

    private func utilisation() async throws -> Double {
        let capacity = model.contextSize
        guard capacity > 0 else { return 0 }
        let used = try await model.tokenCount(for: session.transcript)
        return Double(used) / Double(capacity)
    }

    private func rebuiltFromCondensedTranscript() -> LanguageModelSession {
        let all = session.transcript
        // Keep the instructions entry and the most recent turn — Apple's own
        // documented condensation. Adapt the policy; keep the shape.
        let condensed = [all.first, all.last].compactMap { $0 }
        let new = LanguageModelSession(transcript: Transcript(entries: condensed))
        new.prewarm()                       // cold cache; pay for it now, not later
        return new
    }
}
```

**Retry exactly once.** That is the load-bearing detail in the published wrapper and it is worth
defending: if a transcript condensed to two entries still exceeds the window, the overflow is coming
from the *prompt* (or its schema, or its attachments), and a retry loop will spin forever. One retry,
then surface the error.

The OP's complaint in that same thread is the honest critique of the 26-era approach, and it deserves
to be quoted because it names what the API actually cost people:

> ✅ **VERIFIED (forum thread 817502)** — the OP (ilkomiliev): once
> `exceededContextWindowSizeError` is caught, **all context is lost**, and the context window size is
> **not exposed by the API**. (The second half of that complaint was answered by 26.4 shipping
> `contextSize`; the first half is what dynamic profiles answer in 27.)

Apple's DTS guidance at the time was exactly this pattern:

> ✅ **VERIFIED (forum thread 790736, DTS Engineer, signed "-J")**: *"You are correct that currently
> the token limit for Foundation Models framework is around 4,000. There is no guarantee that this
> will stay the same forever or across devices, however, so we encourage developers to write their
> code in a way that is ready to handle the context window limit when it arises. … your app can catch
> the `exceededContextWindowSize` error and handle accordingly. One suggestion for this is to
> **summarize a session's transcript thus far, and create a new session with the condensed
> transcript**, but the exact implementation will depend on your use-case."*

Also referenced from that thread, and worth pulling if you are doing this work:

> ✅ **VERIFIED — TN3193: Managing the on-device foundation model's context window**,
> `https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window`
> (note the slug: `model-s`, not `models` — the plural spelling 404s). **Read 2026-07-27; this guide
> now reflects it.** What it settled: the **4096** figure (§3.3), the *existence* of the five
> `tokenCount(for:)` input kinds (§4.1), the **six recommendations** (§2.6), the recovery pattern
> (§6.3), and the surviving `GenerationError.exceededContextWindowSize` spelling (§6.1).
>
> 🔴 **GAP — TN3193 says nothing about the KV cache.** No cache-invalidation semantics, no
> transcript-trimming API. Everything in §8–§9 still rests on WWDC26 session 242, the KV-caching
> article and the `foundation-models-utilities` source. Reading the technote does **not** upgrade any
> marker in those sections.

### 6.5 What Apple replied — and what changed in 27

The Apple answer on thread 835927 is the cleanest single statement of the 26→27 migration for context
management:

> ✅ **VERIFIED** — Apple Frameworks Engineer, thread **835927**:
>
> *"The way you're doing compaction is generally correct, and recreating the session with the new
> transcript is correct **if you're targeting iOS 26**. In **iOS 27**, session's `transcript` property
> is now **mutable**, and transcript has a **`history` accessor** for updating everything except the
> instructions, so you can just use that instead of recreating the session. We've also introduced the
> notion of **`DynamicProfiles`** as a way to clip into the session lifecycle without having to wrap
> it, and **open sourced some context management utilities similar to your own!** You can use them
> as-is, or use them as inspiration to create your own context management modifiers to vend to
> others."*
>
> Linked from that reply:
> `https://github.com/apple/foundation-models-utilities/tree/main/Sources/FoundationModelsUtilities/History`

So the 27-era answer to overflow has three tiers, in increasing order of how much you write yourself:

| Tier | Mechanism | Version | Rebuilds the session? |
|---|---|---|---|
| 1 | `foundation-models-utilities` history modifiers | 27.0 | no |
| 2 | `historyTransform(_:)` on your own profile | 27.0 | no |
| 3 | Catch `.contextSizeExceeded`, condense, rebuild | 26.0 | **yes — cold cache** |

Tier 3 still exists and is still the only thing that works on 26. But note what it costs in the terms
of §8: rebuilding a session throws away the KV cache entirely. Tiers 1 and 2 do not.

One more mutability rule, because the framework gives this misuse a dedicated error:

> ✅ **VERIFIED** — WWDC26 session 242 (`242:165-167`): *"the `transcript` property on session is now
> mutable. Remember though, **you can only modify the transcript when the session's `isResponding`
> property is `false`. Attempting to mutate the transcript during a response is a programmer
> error.**"*
>
> The typed failure is `LanguageModelSession.Error.transcriptMutationWhileResponding`
> — *"The session's transcript was mutated while a request was in progress."*
> (`/documentation/foundationmodels/languagemodelsession/error`).[^transcript-mutation-error]
>
> “Programmer error” describes the caller bug; it does not establish a fatal process trap. The public
> API supplies a catchable session error for the condition. **Guard every mutation with
> `!session.isResponding`** so no in-flight response needs to surface it.

---

## 7. Reclaiming context: four levers, and Apple's shipped modifiers

Once you accept that you must manage the window yourself, there are exactly four levers. They differ
in what they cost you in *cache* and in *fidelity*, which is the axis nobody thinks about until §8.
**Exhaust Apple's six recommendations (§2.6) first** — those cost you neither.

| # | Lever | API | Version | Cache cost | Reversible? |
|---|---|---|---|---|---|
| 1 | **Send less to begin with** | prompt/schema/tool discipline (§2.6) | any | none — this is the free one | n/a |
| 2 | **Filter per-profile, non-destructively** | `historyTransform(_:)` | 27.0 | depends on the transform (§8.7) | **yes** |
| 3 | **Rewrite the session's history destructively** | `@SessionProperty(\.history)` / `session.transcript` | 27.0 | invalidates from the edit point | **no** |
| 4 | **Rebuild from a condensed transcript** | `LanguageModelSession(transcript:)` | 26.0 | total — cold cache | no |

### 7.1 The decision rule, from Apple

Session 242 gives the rule for choosing between levers 2 and 3, and it is worth quoting verbatim
because it is compact and load-bearing:

> ✅ **VERIFIED** — `242:102-103`: *"**Keep in mind that the `history` property is lossy and its
> changes will be reflected across all profiles in the session. For lossless transformations targeted
> to specific profiles, you should prefer `historyTransform`.**"*

And the property that makes `historyTransform` safe:

> ✅ **VERIFIED** — `242:78-80`: *"**Transforms don't permanently mutate the session's transcript.
> Instead, they're local transformations applied prior to prompting the model.** This means **you
> don't need to worry about losing context that may become relevant at a later point**."*

| | `historyTransform(_:)` | `@SessionProperty(\.history)` |
|---|---|---|
| Mutates the real transcript? | **No** — local, per-request | **Yes** — 242 calls it "lossy" |
| Scope | **This profile only** | **All profiles in the session** |
| Reversible | Yes — the original context is still there | No |
| Use for | focus, redaction, fitting a smaller model | consolidation at a lifecycle boundary |

### 7.2 `historyTransform(_:)` — the signature, from compiling Apple code

Our earlier notes had this marked UNVERIFIED. Apple's own sample settles it.

> ✅ **VERIFIED** — Apple's Origami sample, `Origami/Models/OrchestratorProfile.swift:11-75`,
> verbatim excerpt:
>
> ```swift
> struct OrchestratorProfile: LanguageModelSession.DynamicProfile {
>     var orchestrator: Orchestrator
>     var serverModel = SystemLanguageModel()
>
>     var body: some DynamicProfile {
>         switch orchestrator.mode {
>         case .brainstorm:
>             …
>         case .tutorial:
>             if !isOnDevice {
>                 Profile { TutorialInstructions(orchestrator: orchestrator) }
>                     .model(serverModel)
>                     .reasoningLevel(.deep)
>             } else {
>                 Profile { TutorialInstructions(orchestrator: orchestrator) }
>                     .model(SystemLanguageModel())
>                     .historyTransform(shortHistory(_:))
>             }
>         case .term:
>             Profile { TermInstructions(orchestrator: orchestrator) }
>                 .model(SystemLanguageModel())
>                 .historyTransform(shortHistory(_:))
>         }
>     }
>
>     /// Returns the most recent four entries so longer on-device sessions
>     /// stay within the smaller context window.
>     private func shortHistory(_ entries: [Transcript.Entry]) -> [Transcript.Entry] {
>         entries.suffix(4)
>     }
> }
> ```
>
> Four facts this pins down that our transcript-derived notes had wrong or open:
> 1. **`historyTransform(_:)` takes `([Transcript.Entry]) -> [Transcript.Entry]`.** It is handed the
>    *entry array*, not a `Transcript`. **A plain function reference works** — no closure required.
> 2. The `body` type is **`some DynamicProfile`** — the short spelling, inside a type that conforms to
>    the nested `LanguageModelSession.DynamicProfile`. Apple does not write the long name here.
> 3. **`Profile { … }.model(x)`**, a modifier — not `Profile(model:) { … }`, which is how the WWDC
>    narration was reconstructed.
> 4. `if / else` is legal inside the profile builder alongside `switch`.

And Apple's docs give the multi-model framing that makes this the *right* lever for profile
switching:

> ✅ **VERIFIED** — the dynamic-profiles article: *"When a `DynamicProfile` coordinates multiple
> profiles, `historyTransform(_:)` allows each profile to manage its own view of the history. **One
> profile compresses the history for a small on-device model, and a profile that uses a server model —
> with a much larger context size — gets the full history.**"*

That is exactly what Origami does: the PCC branches get everything, the on-device branches get
`suffix(4)`. Four entries. Apple's own sample budget for a 4K window is *four transcript entries*.

There is a second, less obvious use for the same modifier — the privacy hop:

> ✅ **VERIFIED** — `242:66-68`: *"When moving between models, you may need to trim unnecessary entries
> to stay within the context size. But that's not the only reason for adjusting the model's context.
> You can also improve the model's focus by removing irrelevant entries, or **redact private
> information from existing entries when moving to a less private model**."*

On-device → PCC is a privacy boundary, and 242 explicitly recommends redacting on the way out. As a
bonus, redaction is a *shape-preserving* transform, which §8.7 shows is the cache-friendly kind.

### 7.3 The shipped history modifiers

Apple's `foundation-models-utilities` package is where the reusable versions live. Three modifiers
ship today.

> ✅ **VERIFIED** — exact signatures from the package source:
> ```swift
> // DropCompletedToolCalls.swift:38
> extension LanguageModelSession.DynamicProfile {
>   public func droppingCompletedToolCalls() -> some DynamicProfile
> }
>
> // RollingWindow.swift:36 / :64
> extension LanguageModelSession.DynamicProfile {
>   public func rollingWindow(entries: Int) -> some DynamicProfile
>   public func rollingWindow(size: RollingWindowSize) -> some DynamicProfile
> }
>
> // RollingWindow.swift:86
> public enum RollingWindowSize: Sendable {
>   case entries(Int)          // the only case today
> }
>
> // SummarizeHistory.swift:53
> extension LanguageModelSession.DynamicProfile {
>   public func summarizeHistory<Model: LanguageModel>(
>     entryThreshold: Int,                  // no default
>     model: Model,                         // no default
>     instructions: Instructions? = nil,
>     summaryPostamble: String? = nil
>   ) -> some DynamicProfile
> }
> ```
> All three are implemented the same way: a private struct conforming to
> `LanguageModelSession.DynamicProfileModifier`, holding `@SessionProperty(\.history)`, whose
> `body(content:)` returns `content.onPrompt { … }` (`DropCompletedToolCalls.swift:43-48`).
> **They are lever 3, not lever 2** — they assign to `history`, which is the destructive path.

Important framing before you adopt any of them:

> ✅ **VERIFIED** — the package declares `.macOS("27.0") .iOS("27.0") .visionOS("27.0")
> .watchOS("27.0")` in `Package.swift:19-22` — **no tvOS**. And WWDC26 session 242 (`242:12-14`)
> describes it as *"an open source Swift package that houses components helpful for building agentic
> experiences. It will be **updated in between OS releases** and give you access to **emerging or
> experimental patterns**."*

"Emerging or experimental" is not marketing softening. The next three subsections are why.

### 7.4 `summarizeHistory` — read this before you ship it

> ✅ **VERIFIED** — semantics, from `SummarizeHistory.swift:99-158`:
> ```swift
> content.onPrompt {
>   guard history.count > entryThreshold else { return }           // :99  ← strict >, ENTRY count
>   guard case .prompt(let prompt) = history.last else { return }   // :103 ← last entry MUST be a prompt
>   …
>   history = [                                                    // :153
>     .prompt(Transcript.Prompt(id: UUID().uuidString,
>                               segments: [.text(summarySegment)] + prompt.segments,
>                               options: prompt.options,
>                               responseFormat: prompt.responseFormat))
>   ]
> }
> ```
> **The entire history collapses to exactly one `.prompt` entry.** Instructions, all prior
> prompts/responses, every tool exchange: gone.

Three things about that will bite you.

**(a) The threshold is an entry count, not a token count.**

> ✅ **VERIFIED** — *"There is no token counting anywhere in this file, or anywhere in the package."*
> The package's README says *"Summarization runs only if the rolling window of 10 entries **exceeds
> 5000 tokens**"* (`README.md:78`) — and that sentence is **stale prose from a deleted, pre-beta-1
> token-based API**. `grep -rn "5000" Sources/ Tests/` returns **zero hits**; commit `376ca60`
> changed the sample from `.summarizeHistory(threshold: 5000, …)` to
> `.summarizeHistory(entryThreshold: 10, …)` and **never updated the prose**. Apple's own skill
> documentation flags it as *"aspirational"*.

So a session with ten enormous entries never summarises, and a session with eleven tiny ones does.
If your entries vary wildly in size — and if you have tools, they do — entry count is a poor proxy
for tokens. Meter with `tokenCount(for:)` (§4) and drive your own modifier if that matters.

**(b) It destroys tool-call structure**, and Apple has confirmed this on the record:

> ✅ **VERIFIED** — Apple Frameworks Engineer, forum thread **833706**: *"The `summarizeHistory`
> modifier allows customization of the `instructions` which are used to produce the conversation
> summary. However, **it will condense all entries into a `.prompt` entry.** If you're looking to
> preserve `.toolCalls` entries during summarization, you should be able to implement your own
> modifier using **`DynamicProfileModifier`** and either **`historyTransform`** or lifecycle
> modifiers (like **`onPrompt`**) to define your own summarize operation."*
>
> And an Apple Designer in the same thread: *"'Summarize History' modifier currently doesn't support
> preserving metadata like tool call IDs. However, [it] is implemented by combining a few primitives
> — it asks a language model to summarize `transcript` when there's a prompt event (`onPrompt`), and
> overwrite the session history using summarization results. **You can also create your own modifier
> to preserve metadata while summarizing events.**"*

**(c) ⚠️ SILENT FAILURE — it is a no-op on tool-output continuations.** The second guard requires
`history.last` to be a `.prompt`. During a tool-calling loop the last entry is a `.toolOutput`, so
the hook fires and does nothing.

> ✅ **VERIFIED** — the package's own test comment, `SummarizeHistoryTests.swift:178-184`, verbatim:
> *"The single respond produces: prompt -> tool call -> tool output -> response. **By the time
> summarization's hook runs on the tool-output continuation, the history count (3) already exceeds the
> threshold (2), but the most recent entry is a tool output rather than a prompt. Because
> summarization only acts when the last entry is a prompt, it is skipped.**"*
>
> The consequence for an agentic session: **the more tool calls a turn makes, the less likely
> summarisation is to fire on it** — which is precisely backwards, because those are the turns that
> generate the most tokens. Nothing throws. You simply overflow later and wonder why the modifier
> "didn't work."

### 7.5 `rollingWindow` — Apple ships it with a test that pins the bug

> ✅ **VERIFIED** — `RollingWindow.swift:79`, the entire implementation:
> ```swift
> content.onPrompt {
>   switch size {
>   case .entries(let numberOfEntries):
>     history = history.suffix(numberOfEntries)
>   }
> }
> ```
> A naive `suffix(n)`. **It is not transcript-aware**: it will cut between a prompt and its response.
> The package's own test says so, verbatim (`RollingWindowTests.swift:71-73`):
>
> *"The naive suffix(2) trim repeatedly cuts between a prompt and its response, so the window starts
> with an orphaned response. **This documents the (buggy) naive outcome; in practice it crashes
> partway through.**"*
>
> The asserted expectation (`:74-80`) is an orphaned `.response("OK")` with no preceding prompt.

Read that as it is meant: Apple shipped a modifier, wrote a test that asserts the broken behaviour,
and left a comment saying it crashes in practice. That is a legitimate thing to do for an
explicitly-experimental package. It is not a legitimate thing to put in your shipping app without
reading the test first.

> 🔴 **GAP — why `.instructions` survives a `suffix(2)`.** The same test shows `.instructions` still
> at index 0 after a two-entry window, even though the modifier has no logic to preserve it. The
> mechanism — presumably the framework re-materialising the instructions entry after modifiers run —
> is **unverified**. Do not build on it. **Safe default:** if you write your own window, preserve the
> instructions entry explicitly rather than trusting that something else will.

### 7.6 ⚠️ SILENT FAILURE — the composed example in Apple's README can never fire

Modifier order is real and it is inverted from what reading the code suggests.

> ✅ **VERIFIED** — three independent statements in the package agree. `README.md:78`: *"Modifiers
> apply in **outside-in** order: first, the profile drops completed tool calls, then applies a rolling
> window."* `DropCompletedToolCalls.swift:23-25`: *"applying it **outermost** ensures tool-call
> entries are cleaned up **before** a rolling window or summarization step runs."*
> `SummarizeHistory.swift:26-28`: *"Because summarization is the most aggressive form of compression,
> it is typically placed **innermost** (applied last) so that lighter-weight modifiers … **run
> first**."*

So in this stack:

```swift prelude:guide-context
Profile {
  Instructions("A conversation between a user and a helpful assistant.")
  ToggleDarkModeTool()
}
.summarizeHistory(entryThreshold: 10, model: status.summarizerModel)   // written FIRST  = INNERMOST = runs LAST
.rollingWindow(entries: 10)                                            // middle
.droppingCompletedToolCalls()                                          // written LAST   = OUTERMOST = runs FIRST
```

runtime order is **drop tool calls → rolling window → summarise**.

Now do the arithmetic. `rollingWindow(entries: 10)` truncates the history to at most 10 entries.
`summarizeHistory(entryThreshold: 10)` gates on `history.count > entryThreshold` — **strictly greater
than 10**. After the window has run, the count is at most 10. **Summarisation can never fire.**

> ✅ **VERIFIED** — this is the composition in Apple's own `README.md:88-92`, and it is inert. So is
> every other composed example shipped in the repo: `DropCompletedToolCalls.swift:31-33`,
> `SummarizeHistory.swift:34-36`, and the utilities skill at `SKILL.md:210-212` and `:271-273` all
> pair `entryThreshold: 50` with `rollingWindow(entries: 10)` or `(entries: 20)` — and 10 is never
> greater than 50 either. **All four shipped call sites are no-ops.**

Nothing throws. Nothing warns. You compose three modifiers, the expensive one never runs, and you
discover it when a long session throws `.contextSizeExceeded` at a user.

**The rule: `entryThreshold` must be strictly less than your rolling-window size**, or summarisation
is dead code. If you want summarisation at 10 entries, the window has to be larger than 10 — or you
drop the window entirely and let summarisation own the policy.

### 7.7 `droppingCompletedToolCalls()` — the one that is straightforwardly good

> ✅ **VERIFIED** — `DropCompletedToolCalls.swift:51-65`:
> ```swift
> content.onPrompt {
>   let lastOutputIndex = history.lastIndex(where: { entry in
>     if case .response  = entry { return true }
>     if case .toolCalls = entry { return true }
>     return false
>   }) ?? history.startIndex
>
>   let prefix = history.prefix(upTo: lastOutputIndex).filter { entry in
>     if case .toolCalls  = entry { return false }
>     if case .toolOutput = entry { return false }
>     return true
>   }
>   let suffix = history.suffix(from: lastOutputIndex)
>   history = prefix + suffix
> }
> ```
> Semantics: find the **last** `.response` or `.toolCalls`; strip every `.toolCalls` and `.toolOutput`
> from everything *before* it; keep everything from it onward verbatim. The most recent tool exchange
> survives; earlier ones are evicted. Instructions, prompts and responses are always preserved.
> Pinned by tests at `DroppingCompletedToolCallsTests.swift:30-46` (nothing dropped after one turn)
> and `:48-68` (the first turn's tool pair gone after two turns).

This maps directly onto session 242's advice — ✅ `242:73`: *"**Dropping tool calls is one easy way to
trim history.**"* — and onto the §2.2 observation that `.toolOutput` is the entry that kills sessions.

It also has a caveat that only appears when you read §11: Apple's own documentation warns that
**removing a tool's output while the tool definition stays** is safer than the reverse, but that any
removal is a lie to the model about what happened. Use it, and read §11.

If you want the same effect without the destructive write, this is the `historyTransform` equivalent
— lever 2 instead of lever 3, per-profile and reversible:

```swift prelude:guide-context
/// Non-destructive equivalent of `droppingCompletedToolCalls()`.
/// Scoped to one profile; the real transcript keeps every entry.
private func withoutToolTraffic(_ entries: [Transcript.Entry]) -> [Transcript.Entry] {
    entries.filter { entry in
        switch entry {
        case .toolCalls, .toolOutput: return false
        default:                      return true
        }
    }
}

// use site
Profile { ReviewInstructions() }
    .model(SystemLanguageModel())
    .historyTransform(withoutToolTraffic(_:))
```

That is the shape session 242 narrated for its "reviewing" profile (`242:73-77`), written with the
signature Apple's sample proved (§7.2).

---

## 8. The KV cache is a prefix

This is the core of the guide, and the one idea that makes every other decision in Part 3 follow
mechanically.

### 8.1 What a KV cache is, in the terms this framework uses

When a transformer processes a token sequence, each layer computes a **key** and a **value** vector
for every position. Those vectors depend only on the token at that position and the tokens before
it — never on tokens that come after. So once you have processed positions `0..<n`, those K/V pairs
are permanently correct for that exact token sequence, and processing position `n` costs you one
step instead of `n+1`.

That is the whole optimisation: **the cache is a prefix of the token sequence, and it is valid
exactly as long as the prefix is unchanged.**

Apple states the framework-level version of this carefully, because it is a *provider* concern:

> ✅ **VERIFIED** — `/documentation/foundationmodels/optimizing-key-value-caching-in-language-model-sessions`:
> *"When using a language model session for multi-turn conversations, model providers **might**
> maintain a key-value (KV) cache of previously processed tokens… **it's up to the model provider to
> determine how they manage the cache. How you structure and manage your session determines whether
> the provider preserves or invalidates that cache.**"*

Two things follow from that sentence and both matter:

1. **You never call a cache API.** There is no `session.invalidateCache()`, no
   `GenerationOptions(cache:)`. Your only lever is the *shape of the token sequence you hand over*.
2. **Behaviour is per-model.** Session 242 says this outright:
   ✅ `242:175` — *"It's important to understand that **different models have different caching
   behavior and the only way to be certain is by measuring.**"*

§10 is what "different models have different caching behaviour" turns into when you push it — some
architectures cannot do this at all.

### 8.2 The token layout

> ✅ **VERIFIED** — the KV-caching article, verbatim: *"A session typically arranges its content into
> a token sequence with a specific order, like **instructions appearing at the top, tool definitions
> coming next, and then transcript entries follow at the end**. **Each cached value in the sequence
> depends on every token that precedes it. When a token changes at any position, the system recomputes
> the cached values from that point forward.**"*

Draw it, because the picture is the entire mental model:

```
position 0 ─────────────────────────────────────────────────────────────► position N
┌──────────────────┬───────────────────┬─────────────────────────────────────────┐
│  INSTRUCTIONS    │ TOOL DEFINITIONS  │  TRANSCRIPT ENTRIES (oldest → newest)   │
│  (your prose)    │ (name, desc,      │  prompt, response, toolCalls,           │
│                  │  parameter schema)│  toolOutput, reasoning, …               │
└──────────────────┴───────────────────┴─────────────────────────────────────────┘
     ▲ most expensive to change                        least expensive to change ▲
```

A change at position *k* invalidates `[k, N]`. Nothing before *k* is affected. That is the only rule.
Everything below is an application of it.

### 8.3 The blast-radius table

> ✅ **VERIFIED** — the KV-caching article, verbatim: *"Appending new content at the end of the
> sequence — through calls to respond or stream methods — is a cache-friendly operation… **A change to
> the instructions, for example, invalidates the cache for the tool definitions and the entire
> transcript.** A change deep in the transcript, by contrast, only invalidates the values that follow
> it."*

> ✅ **VERIFIED** — WWDC26 session 242 (`242:170-171`), the same rule in the presenter's words:
> *"Generally, **appending to the transcript preserves the KV cache, and minimizes the
> time-to-first-token**. If you **rewrite history by removing entries, changing the attached tools, or
> updating the instructions**, that will **typically trigger a cache invalidation, and can increase
> latency**."*

| What you do | Position touched | Invalidates | Verdict |
|---|---|---|---|
| `respond(to:)` / `streamResponse(to:)` | append at N | nothing | **free** |
| Add or remove a **tool** | tool-definition block | **tool defs + entire transcript** | expensive + accuracy hazard (§11) |
| Change your **`Instructions`** text | position 0 | **everything** | most expensive edit possible |
| A `DynamicInstructions` conditional that flips | wherever it sits in the flattened body | from that point on | depends entirely on §8.6 |
| Drop the **oldest** transcript entries | early transcript | almost everything | expensive |
| Drop the **most recent** entries | late transcript | a little | **cheapest trim** |
| Replace text **in place**, same token count | wherever | ideally nothing | **the good trick** (§8.7) |
| Switch **profile** | usually the whole prefix | everything | treat as a reset (§8.9) |
| Rebuild the session from a transcript | n/a — new session | everything | cold cache, `prewarm()` |

> ✅ **VERIFIED** — the cheapest-trim rule, verbatim from the article: *"When you do trim, **removing
> only the most recent entries is cheaper than modifying earlier ones**."*

That last row of the table is the counter-intuitive one and it is worth internalising: from a *cache*
point of view, dropping the newest turn is cheap and dropping the oldest turn is nearly as expensive
as starting over. From a *usefulness* point of view the priorities are exactly reversed. That tension
is what makes context engineering hard, and it is why §8.8's "batch it" advice exists.

### 8.4 "Taking the training wheels off"

The 2025 API had none of this exposed, and that was deliberate:

> ✅ **VERIFIED** — WWDC26 session 242 (`242:168-174`), the full passage: *"we need to talk about the
> implications of **mutating the transcript on performance and accuracy**. **Key-value, or KV caches
> are an important optimization mechanism in large language models and they can be invalidated by
> transcript mutations.** … Generally, appending to the transcript preserves the KV cache… Now, we
> **didn't talk about this last year** because we **intentionally shaped `LanguageModelSession` APIs
> to be append only**. By default, they ensured optimal use. But **this year, we're taking the
> training wheels off**, so to say."*

Read that as an admission of the trade the 2026 API makes. In 2025 you *could not* write a slow
session, because you could not modify the transcript. In 2026 you can do everything — mutate
`session.transcript`, reassign `history`, transform per-profile, swap models mid-conversation — and
every one of those powers is a way to make your app slower without an error, a warning, or a compiler
diagnostic.

> ⚠️ **SILENT FAILURE — cache invalidation never throws.** This is the defining property of the whole
> subject. A cache invalidation produces exactly one observable symptom: **a longer yellow bar in
> Instruments and a longer wait for the user.** There is no `LanguageModelError.cacheInvalidated`.
> There is no log line. A `historyTransform` that reorders entries, a `DynamicInstructions` body whose
> conditional sits above the static content, an instructions string that interpolates the current
> time — each of these silently converts an O(1) turn into an O(N) turn, and your unit tests pass.
> **The only detection mechanisms are `Usage.Input.cachedTokenCount` (§5.1) and the Foundation Models
> Instrument (§5.2).**

### 8.5 Why `historyTransform` is the safer lever, mechanically

§7.1 gave Apple's stated rule (lossless and per-profile beats lossy and global). Here is the cache
reason underneath it.

`historyTransform` is applied *before rendering the prompt* and does not write back. So the global
transcript keeps growing append-only — which means the *underlying* sequence the provider has cached
against never gets rewritten. Whether a given transform preserves the cache depends on the transform
(§8.7), but the transcript itself stays clean, and the moment you switch back to a profile with no
transform, the full cached prefix is still the truth.

Assigning to `@SessionProperty(\.history)`, by contrast, rewrites the sequence for everyone, forever.

> ✅ **VERIFIED** — the article's summary of the difference: *"**Prefer stateless transforms over
> stateful ones** because they don't modify the global transcript."*

A security-oriented third-party note in our corpus adds a timing detail that matters if you are using
transforms for redaction rather than trimming:

> 🟡 **RECONSTRUCTED / secondary** — attributed to WWDC26 session 347 *"Secure your app: mitigate
> risks to agentic features"*, a session **not** in our transcript corpus, via
> `john-rocky/coreai-model-zoo`'s `agentic-security-checklist.md:112-116`: *"`.historyTransform` fires
> before the transcript is rendered to the model, on every new user request **and every loop
> iteration**. … **Transforms are scoped to the current inference only** — not visible to the next
> call, so re-apply every iteration."* The "every loop iteration" claim is **not** in 242 or 243 and
> we have not verified it. If your transform is expensive, measure before assuming it runs once per
> turn.

### 8.6 The ordering rule for `DynamicInstructions` — the most actionable item in this section

This is the piece of advice with the best effort-to-payoff ratio in the entire guide, and it is
purely about where you put your `if`.

> ✅ **VERIFIED** — the KV-caching article, verbatim: *"Place instructions and tools that remain
> **constant at the top** of your `DynamicInstructions` body, and group **conditional content at the
> bottom**. **The framework flattens the resolved instructions and tool definitions in the order you
> declare them**, so content that appears first in the body occupies earlier positions in the token
> sequence."*
>
> **NOTE**, verbatim: *"**Placing the conditional content before the static instructions and tools
> invalidates the cached values and leads to unnecessary recomputation.**"*

Because the body is re-evaluated before every request, a conditional inside it is a *potential* prefix
edit on every turn. Put it at position 0 and every flip costs you the entire sequence. Put it at the
end of the instructions block and a flip costs you only the tokens after it.

```swift prelude:guide-context
import FoundationModels

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
struct CraftAssistant: DynamicInstructions {
    var craftKind: CraftKind          // changes as the user navigates

    var body: some DynamicInstructions {
        // ── STATIC: identical on every single turn. Cached once, reused forever. ──
        Instructions {
            "Help the person brainstorm craft project ideas from the photos they share."
            "Offer a short list of distinct concepts."
        }
        GenerateTitleTool()

        // ── CONDITIONAL: goes LAST, so flipping it invalidates only what follows. ──
        if craftKind == .origami {
            OrigamiExpert()
        }
    }
}
```

Invert those two blocks and you have written a correct program that is slower on every turn where the
condition changes, with no diagnostic of any kind.

> ✅ **VERIFIED** — nesting is how you compose these: `242:42` — *"DynamicInstructions are also
> **composable** so **nesting `OrigamiExpert` inside another `DynamicInstructions` body will
> concatenate the instructions and tools together**."* Which is also why the ordering rule is
> transitive: a nested component's contents land wherever the nesting site lands.

Two more facts about the body that bear on this:

> ✅ **VERIFIED** — `242:59`: *"Note that **the body of a `DynamicProfile` is re-evaluated each time
> the model is prompted**, so as the app moves between each mode, the persona of the
> `LanguageModelSession` changes."* And `243:8-9` for `DynamicInstructions`: *"It **re-evaluates
> before every request**, so the model always has the right context for the task at hand."*

> ⚠️ **A third-party measurement says "each time" understates it.** `john-rocky/coreai-model-zoo`,
> `dynamic-profiles-local-models.md:48-51` (**community-measured**, against a custom local-model
> provider, hardware and OS not stated): *"**The `body` is re-evaluated multiple times per turn** (7
> evaluations for 3 turns). The framework reads it more than once to gather instructions and resolve
> the model. **Keep the body pure** — read your route variable there, never mutate state. Imperative
> work goes in lifecycle modifiers (`onResponse`, …), which fire once at their boundary."*
>
> Whether that count holds for Apple's own models is unverified. The rule it implies is safe
> regardless: **`body` must be pure.** Anything that mutates belongs in `onPrompt` / `onResponse` /
> `onToolCall` / `onToolOutput`.

### 8.7 Stateless, shape-preserving transforms are the trick

> ✅ **VERIFIED** — the KV-caching article, verbatim: *"A **stateless** transform that **drops**
> entries, like truncating to recent history, **invalidates parts of the cache** for the entries it
> removes. However, **a transform that replaces content in-place, like removing debug metadata, can
> preserve cache consistency** because the model sees the same token sequence each time."*
>
> Apple's own example, verbatim:
> ```swift
> Profile {
>    // The instructions and tools for the profile.
> }
> .historyTransform { history in
>     // Remove debug text from the history. The model sees the same number of
>     // entries in the same order so previously cached tokens remain valid.
>     clearDebugFromHistory(history)
> }
> ```

The phrase to hold onto is **"the model sees the same token sequence each time."** A transform is
cache-safe when it is *deterministic and idempotent with respect to the rendered tokens*. Two
transforms that look similar are not equally safe:

| Transform | Same tokens every turn? | Cache |
|---|---|---|
| Strip a debug prefix that is always present | yes | **preserved** |
| Redact PII to a fixed placeholder | yes | **preserved** |
| `entries.suffix(4)` | **no** — the window slides every turn | invalidated at the window's leading edge |
| Sort entries by relevance | **no** — order changes with content | invalidated from the first reordered entry |
| Interpolate `Date()` into instructions | **no** — changes every second | **everything**, every turn |

That last row is a real bug that people write. An instructions string containing "The current time is
\(Date())" invalidates position 0 on literally every request. If you need the time in context, put it
in the *prompt* (position N, free) — never in the instructions (position 0, catastrophic).

Note also the honest limit of Apple's own sample: `entries.suffix(4)` — the transform in the Origami
sample (§7.2) — is in the *invalidating* category. It is still the right call there, because fitting
a 4K window at all beats fitting it fast. Cache economics is a tie-breaker, not an override.

### 8.8 Batch your trimming

> ✅ **VERIFIED** — the KV-caching article, verbatim: *"**Defer removing entries from the transcript
> until the context window is nearly full, then consolidate the context in a single operation rather
> than trimming incrementally after each turn.** Frequent small edits to the middle of the transcript
> force repeated cache invalidations that increase latency, while a single consolidation step incurs
> the recomputation cost only once."*

This is why §4.3's meter uses a threshold of 0.75 rather than trimming a little every turn. Ten
small trims cost ten invalidations; one consolidation costs one.

It also explains the shape of Apple's own lifecycle advice:

> ✅ **VERIFIED** — `242:91-92`: *"At certain points in the session, you may need to **summarize
> earlier entries from the existing transcript to reclaim context**. **Doing this after each model's
> response provides a clear boundary in the session's lifecycle.**"*

The `onResponse` boundary is the right place because it is *after* the expensive part of the turn and
*before* the next prefill — so the invalidation you cause is paid at a moment when the user is
already reading, not staring at a spinner. Apple's documented pattern for it:

> ✅ **VERIFIED** — the dynamic-profiles article, verbatim:
> ```swift
> // Get a reference to the session history.
> @SessionProperty(\.history)
> var history
>
> var body: some LanguageModelSession.DynamicProfile {
>     Profile {
>         Instructions("You are a helpful assistant.")
>         TodoWriteTool()
>     }
>     .onResponse {
>         // When the entries exceed `100`, perform a stateful update to the
>         // history so it only includes the last `50` entries.
>         if history.count > 100 {
>             history = history.suffix(50)
>         }
>     }
> }
> ```
> Note the ratio: consolidate at 100, cut to 50. **Half the window reclaimed in one operation**, then
> fifty turns of append-only cheapness before the next invalidation. That is the batching rule made
> concrete.
>
> Also verbatim from the same page, and easy to miss: *"**Because model output influences the
> evaluation of `DynamicInstructions` and `Tool`, the session history is read-only in these
> contexts.**"* You can *read* `\.history` from a tool; you can only *write* it from a profile
> lifecycle callback.

### 8.9 Profile switching is a deliberate reset

> ✅ **VERIFIED** — the KV-caching article, verbatim: *"Design your dynamic profiles so transitions
> between your profiles occur at **natural boundaries in the conversation rather than on every turn**.
> **Switching from one profile to another typically changes the entire prefix — which invalidates the
> cache for the full transcript — so treat it as a deliberate reset.**"*

This is stronger than anything session 242 says, and it is the single most important constraint on
agentic architecture in Part 3. A profile carries its own instructions and its own tool set — both of
which live at the front of the sequence. Changing profile changes position 0. There is no cheap
profile switch.

Practical consequences:

- **Baton-pass costs a full re-prefill.** The pattern where a tool flips a mode variable and the next
  turn runs under a different profile (✅ `242:122-128`) is architecturally clean and is *not* free.
  Design your handoffs to happen once or twice per conversation, not once per turn.
- **Ping-ponging between two profiles is the worst case.** Alternating profiles on every turn means
  every single turn pays a cold prefill. If your routing logic can flip back and forth, put a
  hysteresis on it.
- **Phone-a-friend is a different trade.** Spawning a short-lived child session (✅ `242:130-135` —
  *"the tool spawns a new session with an independent transcript, prompts it, and then delivers the
  response back as tool output. The child session disappears"*) means the **parent's cache is never
  touched** — the parent just gains one appended `.toolOutput`. The child pays a cold start, but the
  child's transcript is tiny. For a frequently-invoked specialist, phone-a-friend is often the
  cache-cheaper pattern even though it looks more expensive.

There is a community measurement of what a switch actually costs, for a two-local-model setup. It is
**not** an Apple number and it is **not** measured against Apple's models:

> ⚠️ **Community-measured, custom provider.** `john-rocky/coreai-model-zoo`,
> `dynamic-profiles-local-models.md:56-68`: *"**Switching models re-prefills the shared transcript on
> the newly active engine.** … Measured (0.6B↔4B): switch-in first-delta **2.35 s** … switch-back
> **0.94 s**. Append-only KV reuse only helps across consecutive *same-model* turns."* Plus: *"**Two
> resident models cost two footprints** … **~920 MB `phys_footprint` after the turns run**."*
> Hardware, OS build and date are **not stated in the source** — treat the magnitudes as indicative
> only. The *shape* (a switch costs a full re-prefill on the newly active engine; two resident models
> cost two memory footprints) is what transfers.

### 8.10 The six cheap things and the six expensive things

Consolidated, because this is the list worth pinning above your desk:

**Cheap (cache-preserving):**
1. `respond(to:)` / `streamResponse(to:)` — appending is always free.
2. `prewarm()` / `prewarm(promptPrefix:)` before a known-imminent request.
3. Static instructions and a fixed tool set declared up front.
4. Conditional content at the **bottom** of a `DynamicInstructions` body.
5. In-place, shape-preserving `historyTransform`s (redaction, debug-stripping).
6. One large consolidation at a threshold, rather than many small trims.

**Expensive (cache-invalidating):**
1. Editing `Instructions` — including any interpolated value that changes.
2. Adding or removing a `Tool` mid-session.
3. Conditional content near the **top** of a `DynamicInstructions` body.
4. Dropping or editing *early* transcript entries.
5. Switching profiles.
6. Rebuilding the session from a transcript (total loss; `prewarm()` afterwards).

### 8.11 Restoring a session

> ✅ **VERIFIED** — the two rehydration initialisers:
> ```swift
> // iOS 26.0+ (no watchOS) — "Start a session by rehydrating from a transcript."
> convenience init(model: SystemLanguageModel = .default,
>                  tools: [any Tool] = [],
>                  transcript: Transcript)
>
> // iOS 27.0+ Beta — "Create a session with a profile."
> convenience init(profile: sending some LanguageModelSession.DynamicProfile,
>                  history: some Collection<Transcript.Entry> = [])
> ```
> The `history:` label on the profile initialiser is confirmed by Apple's Origami sample, which
> passes a `Transcript`:
> ✅ *"the shape is `LanguageModelSession(profile:history:)`"* — sample code, with
> `history: Transcript(entries: startHistory)`.

> ⚠️ **Two labels coexist and their relationship is unresolved.** Origami (iOS 27) uses `history:`;
> the older sample uses `transcript:`. Whether `transcript:` is deprecated in 27 is **unverified**.
> Safe default: on 27, use `init(profile:history:)`; on 26, `init(model:tools:transcript:)` is the
> only option.

Either way, the cache story is the same: **a restored session starts cold.** Apple's own restoration
snippet ends with `session.prewarm()` for exactly that reason (§6.3), and the prewarm timing advice —
*"at least one to two seconds in the future"* — is the difference between paying the reprocessing
cost in the background and paying it while the user watches.

There is a genuinely nice pattern here that Apple's sample demonstrates and nothing else in the
corpus does: **hand-authoring a transcript to seed a session**, rather than replaying a real one.

> ✅ **VERIFIED** — Origami, `Orchestrator.swift:103-139`, builds a `[Transcript.Entry]` of
> synthesised `.response` entries and passes it as `history:`. Confirmed spellings:
> `Transcript.Entry.response(_:)`, `Transcript.Response(assetIDs:segments:)` — **`assetIDs` is a
> required `[String]` and the sample passes `[""]`** — `Transcript.Segment.text(_:)`,
> `Transcript.TextSegment(content:)`.

Used deliberately, that is a *cache-friendly few-shot mechanism*: your examples live in the prefix,
get cached once at `prewarm()`, and cost nothing on subsequent turns — unlike few-shot examples
pasted into every prompt.

---

## 9. What prefix reuse is worth, measured

Everything in §8 is a rule of thumb until someone attaches a number to it. One community engineer did,
and the numbers are large enough to change architecture decisions.

> ⚠️ **Scope, stated up front.** The measurements and the API in this section come from a
> **community fork of `apple/coreai-models`** (`john-rocky/coreai-models`, commit `0fdf710`,
> 2026-07-03). `trimKVCache(to:)` is **not a Foundation Models API** and you cannot call it from
> `LanguageModelSession`. It is a primitive on the Core AI `InferenceEngine` protocol, added by a
> third party. It is in this guide because it is the clearest available demonstration of *what
> Apple's prefix rule is actually worth*, and because if you write a `LanguageModelExecutor` you
> will be implementing this yourself. The provider-authoring treatment is in
> [`../../part-04-beyond-the-built-in-model/references/04-executor-lifecycle-and-kv-reuse.md`](../../part-04-beyond-the-built-in-model/references/04-executor-lifecycle-and-kv-reuse.md).

### 9.1 The problem it solves

> ✅ **VERIFIED (community source)** — `knowledge/prefix-cache-kv-reuse.md:12-18`: *"`ChatEngine.swift`
> was doing exactly the worst thing: `engine.reset()` + `applyChatTemplate(full history)` + **full
> re-prefill on EVERY turn** … For a 4k-token RAG context that is **seconds of dead time before the
> first new token, every turn**."*

That is the naive chat loop, and it is what you get by default from any engine that exposes only
"reset and run". Turn *N* reprocesses turns 1..*N*−1 from scratch: system prompt, retrieved
documents, every past turn — before emitting a single new token.

### 9.2 The mechanism: a single integer assignment

The insight is that **nothing needs to be cleared**. The engines already preserved KV across
generate calls and already prefilled only the unprocessed suffix. The missing primitive was a
*rewind*, and a rewind is free.

> ✅ **VERIFIED (community source)** — `knowledge/prefix-cache-kv-reuse.md:22-25`, crediting the
> upstream `reset()` implementation's own comment: *"`reset()`'s own comment gave the key: **'the KV
> pair needs no clearing — attention only reads positions below the new offset.'** So a partial trim =
> just set `processedTokenCount = length`; positions ≥ length are overwritten before they're ever
> read."*

Here is the actual implementation. It is six lines.

> ✅ **VERIFIED (community source)** — `CoreAISequentialEngine.swift:437-443`:
> ```swift
> public func trimKVCache(to length: Int) async -> Int {
>     drain()
>     guard length >= 0 else { return -1 }
>     let retained = min(length, processedTokenCount)
>     processedTokenCount = retained
>     return retained
> }
> ```
> and its doc comment at `:432-436`: *"KV-only (no recurrent state) — **always safe; no clearing
> needed since causal attention never reads positions ≥ the retained offset before they're
> rewritten**."*

**Trimming a KV cache is one integer assignment.** No buffer zeroing, no `memmove`, no reallocation.
The KV tensor is left byte-for-byte untouched; only the engine's notion of "how many tokens are
committed" moves backwards.

The safety argument is worth stating precisely because it is the reason the whole thing works:

- Retained rows `[0 ..< retained]` were written at exactly those positions for exactly those tokens.
  They are still correct.
- Rows `≥ retained` are stale garbage — but **a query at position *p* attends only to keys at
  positions ≤ *p***, and every position `≥ retained` is rewritten by the next prefill before any
  query reaches it. Causality means no read ever observes the garbage.

The `drain()` on the first line is not optional: it ensures no in-flight generation is still writing
KV when you move the cursor.

### 9.3 The contract, and the detail that will bite you

> ✅ **VERIFIED (community source)** — `InferenceEngine.swift:111-123`:
> ```swift
> func trimKVCache(to length: Int) async -> Int
> ```
> The doc comment specifies three things:
> 1. It rewinds toward `length`, keeping the leading cached tokens valid and dropping everything after,
>    *"so the next `generate(with:)` prefills only the un-cached suffix instead of the whole prompt."*
> 2. **It returns the ACTUAL retained prefix length** (0…`length`), *"which may be less than requested
>    because **the last generated token's KV can lag one step behind** — the caller must prefill from
>    the returned offset, not from `length`."*
> 3. It returns a **negative value** if the engine cannot safely rewind, in which case the caller must
>    `reset()` and re-feed the whole prompt.

⚠️ **Point 2 is the correctness trap.** You ask to retain 4,096 tokens; you may get 4,095. If you
then prefill from 4,096, you have **skipped a token** — and the model's state diverges from the
tokens you believe it has seen, silently, with no error and often with output that still looks
plausible. **Always prefill from the returned value, never from the requested one.**

There is a companion property that changes what you feed next, and it differs per engine:

> ✅ **VERIFIED (community source)** — `InferenceEngine.swift:138`:
> ```swift
> var prefixReuseFeedsFullSequence: Bool { get }
> ```
> - `true` (the default) — `generate(with:)` takes the **full running sequence** and the engine slices
>   `input[retained...]` internally. This is `CoreAISequentialEngine`.
> - `false` — the caller passes **only the un-cached suffix**, because the pipelined engine prefills
>   exactly the tokens it is handed, at the current offset.
>
> Protocol-extension defaults (`InferenceEngine.swift:185`, `:188`):
> ```swift
> public func trimKVCache(to length: Int) async -> Int { -1 }
> public var prefixReuseFeedsFullSequence: Bool { true }
> ```
> i.e. **opt-in and fail-safe** — an engine that does not implement it reports "unsupported" and the
> caller degrades to full re-prefill. No existing engine changes behaviour.

Getting the feed contract wrong is the second silent failure here: feed the full sequence to an
engine that wanted only the suffix and you double-prefill the prefix; feed only the suffix to an
engine that wanted the whole thing and you truncate the context.

### 9.4 The caller-side algorithm

> ✅ **VERIFIED (community source)** — `knowledge/prefix-cache-kv-reuse.md:40-46`, the per-turn loop:
>
> 1. `full = applyChatTemplate(history)` — unchanged.
> 2. `want = min(commonPrefixLength(full, kvTokens), full.count - 1)`, where `kvTokens` is the **exact
>    token sequence the engine's KV currently holds** (prompt **plus** streamed generation), tracked by
>    the caller across turns. The `full.count - 1` clamp guarantees at least one token is fed, so the
>    graph always has something to run.
> 3. `reused = await engine.trimKVCache(to: want)`; on `< 0` → `reset()` and `reused = 0`.
> 4. `feed = engine.prefixReuseFeedsFullSequence ? full : full[reused...]` → `engine.generate(with: feed)`.
> 5. **Break at the stop sequence (no drain)** so the KV ends at prompt + real answer.

Step 2 is the whole policy: **longest common prefix between what you are about to send and what the
cache already holds.** It degrades gracefully — reuse the common part, re-prefill the tail.

Step 5 has a dependency that is easy to miss and is a genuine bug class:

> ✅ **VERIFIED (community source)** — commit `627fec7`, the "D1 fix". A consumer that `break`s the
> token stream at EOS — *"every executor"* — left the generator running to `maxTokens` **in the
> background**, and those post-EOS tokens were **consumed into the KV cache**. Consequence: the next
> turn's `reset()`/`drain()` blocked on leftover generation, producing a multi-turn latency tax.
> Community-measured through Apple's own `CoreAILanguageModel` adapter (qwen3.5-0.8B, two-turn chat):
> second-turn latency **2.74 s → 0.40 s**, same output. **Hardware and OS not stated — UNVERIFIED
> which device.**

Prefix reuse is only *correct* if the KV ends at a known token boundary, which requires the engine to
actually stop at EOS rather than run on. The two commits compose; neither is sufficient alone.

### 9.5 Losslessness

> ✅ **VERIFIED (community source)** — `prefix-cache-kv-reuse.md:48-49` claims losslessness by
> construction: `KV[0..reused]` holds identical tokens at identical positions whether reused or
> recomputed. And empirically at `:60-62`: with greedy sampling (`CHATMAC_GREEDY=1`, temperature 0),
> **turn-2 output is byte-identical with prefix caching ON versus OFF**.

That is the claim that makes the numbers in §9.6 meaningful. A 101× speedup that changed the output
would be a different feature. This one does not.

### 9.6 The numbers

> ⚠️ **COMMUNITY-MEASURED — attribute accordingly.** Source: `john-rocky/coreai-models`,
> `knowledge/prefix-cache-kv-reuse.md:52-58`, dated **2026-07-03**. Model **qwen3-0.6b**, the
> **sequential** engine, via the `CoreAIChatMac` harness, **on a Mac**. **The exact Mac model and
> macOS build are NOT stated in the source — UNVERIFIED.** These are not Apple figures and they are
> not measurements of `SystemLanguageModel`.
>
> | Turn | Prompt tokens | Reused | TTFT, cache ON | TTFT, cache OFF | Speedup |
> |---|---|---|---|---|---|
> | 1 (cold) | 81–3820 | 0 | = OFF | initial prefill, unavoidable | 1× |
> | 2 | 357 | 336 | **0.126 s** | **1.915 s** | **15.2×** |
> | 2 | 4103 | **4075 (99.3 %)** | **0.230 s** | **23.282 s** | **101×** |
>
> Multi-turn robustness, three turns, greedy (`:66-70`):
>
> | Turn | Tokens | Reused | TTFT |
> |---|---|---|---|
> | 1 (cold) | 826 | 0 | 4.40 s |
> | 2 | — | 826 | **0.122 s** |
> | 3 | — | 849 | **0.151 s** |

Three readings of that table matter more than the headline number.

**(a) The scaling shape is the point, not the multiplier.** Re-prefill cost grows with context;
reuse cost stays roughly flat. 15× at 357 tokens becomes 101× at 4k, and would be larger still for a
real RAG or agent context. **The bigger your prefix, the more prefix caching is worth** — which is
precisely the regime where you were tempted to trim it.

**(b) Turn 3 reuses turn 2's answer, not just turn 2's prompt.** 849 tokens reused on turn 3, versus
826 on turn 2 — the extra tokens are the assistant's previous reply. Prior assistant turns are
reusable for models whose raw generation round-trips through the chat template unchanged.

> ✅ **VERIFIED (community source)** — `prefix-cache-kv-reuse.md:72-76`: the **system prompt and prior
> user turns always match**, because the chat template is append-only there — so *"the dominant cost
> in long RAG/agent contexts is always reused."* Prior **assistant** turns reuse only when the model's
> raw generation matches the template's re-render; thinking-stripping or retokenisation can diverge.

**(c) Turn 1 is unimproved, and the author says so.** ✅ `prefix-cache-kv-reuse.md:63-64`: turn 1 still
pays the full prefill — 3,820 tokens ≈ **22 s** on this small model's single-token-at-a-time
sequential prefill — which the author flags as a separate **chunked-prefill** lever, not something
prefix caching addresses. Prefix caching is a long-context, multi-turn lever. **Short single-turn
chats see nothing from it.**

### 9.7 The author's own list of limits

Reproduced because it is unusually honest and prevents you from over-reading the table:

> ✅ **VERIFIED (community source)** — `prefix-cache-kv-reuse.md:78-105`:
> - **The pipelined path is UNVERIFIED.** Implemented and symmetric with the sequential one, but it
>   could not be exercised: the harness forces `variant: "coreai-sequential"` because the pipelined
>   variant **SIGTRAPs in `GrowingLogitsBuffer`** for these bundles, and the iOS pipelined app is
>   single-turn.
> - **The iOS app is single-turn**, so prefix caching has nothing to reuse there.
> - **Assistant re-anchoring** (deeper reuse when generated content is stripped, e.g. gpt-oss harmony
>   formatting) was assessed and **deliberately not implemented** — it needs a *prefill-only* engine
>   call, and `generate()` always decodes.
> - The doc was written the same day as the commit, and notes *"All changes uncommitted"* at the time
>   of writing.

### 9.8 What this means for a Foundation Models app developer

You cannot call `trimKVCache`. What you can do is arrange for the provider's equivalent to succeed:

1. **Keep your prefix byte-stable.** Every rule in §8 is, mechanically, "make the longest common
   prefix as long as possible."
2. **Prefer appending to editing**, especially early in the sequence.
3. **Measure the hit rate** (§5.1). `Usage.Input.cachedTokenCount / Usage.Input.totalTokenCount` is
   your window into whether the provider's LCP is finding anything.
4. **Expect turn 1 to be slow and design around it** — `prewarm()` one to two seconds ahead, and
   stream so the user sees something.
5. **If you are choosing a model or a provider, ask whether it can do this at all.** Which is §10.

---

## 10. ⚠️ The model-selection consequence: architectures that cannot prefix-cache

This is the finding in this guide most likely to change a decision you have already made.

### 10.1 The guard

> ✅ **VERIFIED (community source)** — `CoreAIPipelinedEngine.swift:1406-1415`, the pipelined
> implementation in full:
> ```swift
> mutating func trimKVCache(to length: Int) -> Int {
>     guard extraStates.isEmpty else { return -1 }
>     let retained = max(0, min(length, processedTokenCount))
>     processedTokenCount = retained
>     step = retained
>     lastSampledToken = nil
>     return retained
> }
> ```
> The first line is the crux. Its doc comment (`CoreAIPipelinedEngine.swift:1401-1405`) explains why,
> verbatim: *"Rejected when the graph carries recurrent `extraStates` (GDN/SSM): those hold a
> **running scan** that can't be reconstructed at position `length` from the retained KV, so a partial
> rewind would corrupt them. Pure attention KV needs no clearing (causal reads never see positions ≥
> `length`)."*

### 10.2 Why the asymmetry is fundamental, not an implementation gap

This is not a missing feature that a future patch adds. It is a property of the architecture.

- **An attention KV cache is positionally addressed.** Row *i* corresponds to token *i* and is
  self-contained. You can truncate at any *i* because nothing after *i* contributed to anything at or
  before *i*.
- **An SSM / GatedDeltaNet / Mamba2 state is a running scan.** It is a single fixed-size tensor that
  is a **lossy fold of every token seen so far**. There is no row to drop. To obtain the state as of
  token *k*, you must re-run the scan from token 0.

So the trade that linear attention offers — O(1) decode memory instead of O(N) — is paid for by
**forfeiting prefix caching entirely**.

> ✅ **VERIFIED (community source)** — `prefix-cache-kv-reuse.md:101-102`: Qwen3.5 / Qwen3.6
> linear-attention hybrids return `-1` and fall back to full re-prefill; *"**Pure-attention models get
> the win.**"*

### 10.3 The named list

> ✅ **VERIFIED (community source)** — the affected architectures, named in
> `john-rocky/coreai-models` (`:131-132`, `:177`, `:390`):
>
> | Model family | Architecture | Prefix caching |
> |---|---|---|
> | **Qwen3.5** | GatedDeltaNet hybrid | ❌ `trimKVCache` returns `-1` |
> | **Qwen3.6** | GatedDeltaNet hybrid | ❌ `-1` |
> | **LFM2.5** | hybrid / state-space | ❌ `-1` |
> | **Granite 4** | Mamba2 | ❌ `-1` |
> | Pure-attention models (qwen3-0.6b, llama-family, mistral, …) | attention KV only | ✅ reuse works |

The same note records that these models were, at one point, not even *loadable* on the upstream
engine — *"e.g. Qwen3.5/3.6 (GatedDeltaNet), LFM2.5, and Granite 4 (Mamba2) fail at load with
`Expected 2 states, got 4`"* — which the fork fixed by generalising the engine to carry extra states.
So "supports these models" and "can prefix-cache these models" are two different capabilities, and
the second is the one that determines multi-turn latency.

> ⚠️ **Attribution, stated plainly.** This is a **community-derived conclusion from one
> implementation**, not an Apple statement. Apple has published nothing about prefix caching for
> third-party model architectures. What generalises is the *reasoning* — a running scan cannot be
> rewound — which is architecture, not implementation. What does not automatically generalise is that
> every engine will refuse; another implementation might choose to snapshot recurrent state
> periodically and rewind to a checkpoint. Nobody in our corpus has built that.

### 10.4 How this should change your decision table

The conventional on-device wisdom is that state-space and hybrid models are *better* on device: they
decode with constant memory instead of a KV cache that grows with context. That argument is correct
about **memory** and, on this evidence, **backwards about latency in multi-turn use**.

| If your feature is… | The trade |
|---|---|
| Single-turn (summarise this, classify that) | Hybrids are fine. There is no prefix to reuse. |
| Short chats, small contexts | Marginal. §9.6's own note: *"Short single-turn chats see nothing."* |
| **Multi-turn chat over a long system prompt** | Pure attention. Every turn on a hybrid re-prefills the whole prompt. |
| **RAG — retrieved documents in the prefix** | Pure attention, emphatically. This is the 101× case. |
| **Agentic loops** — many inferences per user request | Pure attention. Each loop iteration is another prefill. |
| Memory-constrained, very long single generation | Hybrids win. Constant-size state is the whole point. |

The user-felt metric on device is time-to-first-token on turn *N*, not peak RSS. If you are choosing
between a hybrid model and a pure-attention model of similar quality for a conversational feature,
**this consideration probably outranks the parameter count.**

Two related constraints belong in the same decision, both from the same community corpus and both
about bring-your-own-model paths:

> ⚠️ **Community-measured** — grammar-constrained decoding (`@Generable` / guided generation)
> requires access to engine **logits**, and GPU-pipelined Core AI bundles never expose them. An app
> that brings its own model on the fastest backend **loses Apple's flagship structured-generation
> feature**. Full treatment in [Part 4](../../part-04-beyond-the-built-in-model/README.md).

> ⚠️ **Community-measured** — tool-call reliability differs sharply by model on third-party
> providers: *"small/thinking models emit tool-call JSON the framework rejects with
> `GenerationError.decodingFailure`… The reliable 'the model decides' channel is **guided
> generation**."* (`dynamic-profiles-local-models.md:70-77`.) Explicitly noted as applying to
> third-party `LanguageModel` providers, **not** to Apple's own models.

Taken together: on a BYO-model path you may be choosing between prefix caching, guided generation and
reliable tool calling. Apple's own `SystemLanguageModel` gives you all three; that is worth
remembering before you replace it.

---

## 11. The accuracy hazard: rewriting history confuses the model

Everything so far has been about latency. There is a second cost to transcript surgery that is worse,
because it produces wrong answers rather than slow ones.

> ✅ **VERIFIED** — WWDC26 session 242 (`242:178`): *"In addition to performance implications, the
> other thing you have to be careful about when rewriting history is **accuracy**, because **it's
> possible to confuse the model**."*

### 11.1 The worked example

> ✅ **VERIFIED** — `242:179-184`, verbatim: *"Let's say I have a session where I asked the model to
> **think of fun origami project names**. And then let's say I **add a generate title tool to the
> session**, and prompt it for more ideas. What do you expect will happen next? If we're lucky, the
> model will use the tool like we want. But **it's also possible that the model will notice it
> previously generated titles without the tool, and may think it's supposed to do that again. That's
> not what we want. Our history modification confused the model.**"*

Sit with the failure mode. You added a tool. The tool is correctly registered. The instructions
mention it. Nothing throws. And the model ignores it — not because it misunderstood the tool, but
because **the transcript contains three examples of the model successfully doing this task without
the tool**, and few-shot examples in the context beat a sentence in the instructions.

The transcript is not a log. It is the strongest prompt in the session.

### 11.2 The underlying principle

Apple's documentation states it more sharply than the session does, and this is the sentence to
remember:

> ✅ **VERIFIED** — the KV-caching article, verbatim: *"Modifying the transcript impacts model
> accuracy because **there's no reliable way for the model to distinguish between information that
> never existed and information that did exist but was removed from the context**. A model treats
> whatever's in the context as the complete picture and **reasons confidently from incomplete
> evidence**."*

"Reasons confidently from incomplete evidence" is the whole risk in five words. A trimmed transcript
does not produce hedged answers; it produces assured answers built on a partial record.

### 11.3 The three tool-mutation hazards, named

> ✅ **VERIFIED** — the KV-caching article, verbatim, all three:
>
> 1. *"Adding or removing tools midsession changes the token sequence at the beginning of the
>    transcript, which invalidates the cached values for all of the entries after that point. When you
>    use `DynamicInstructions`, **define the tools you need up front and keep that set unchanged.**"*
> 2. *"**Removing a tool the model previously used can cause the model to produce unexpected results
>    because it sees references in the transcript for a tool that no longer exists in its tool
>    definitions.** If you do remove any tools, **also remove any associated output that refers to
>    them.**"*
> 3. *"**Adding a new tool late in a conversation can produce unexpected behavior.** The model follows
>    patterns established in earlier turns and might not incorporate a newly available tool into its
>    responses."*

Hazard 2 has a concrete instruction buried in it that is easy to skim past: **if you remove a tool,
remove its `.toolCalls` and `.toolOutput` entries too.** A transcript containing a call to a tool that
no longer exists is a transcript that describes an impossible world.

That, incidentally, is a point in favour of `droppingCompletedToolCalls()` (§7.7) over hand-rolled
filtering: it removes calls and outputs together, and it keeps the most recent exchange so the model
still knows what just happened.

### 11.4 ⚠️ SILENT FAILURE — the tool named in prose but absent from the toolset

The dual of hazard 3, and the bug WWDC26's entire Instruments session is built around:

> ✅ **VERIFIED** — WWDC26 session 243 (`243:98-99`): *"**The prompt references the
> `switchToTutorialMode` tool but that tool isn't actually configured with this instruction.** Without
> it, the app has no way to switch from brainstorm mode to tutorial mode, so the crafter gets stuck in
> a loop."*
>
> And the diagnosis, verbatim (`243:100-103`): *"Looking at the subsequent nodes in the tree, **this
> was a silent failure. The model kept accepting input and making tool calls but never threw an error.
> There was no clear signal that anything had gone wrong. That makes it a hard bug to catch.**"*

Instructions prose is text; the tool list is code; **nothing cross-checks them**. Both are in the same
`DynamicInstructions` body, three lines apart, and they can disagree forever without a diagnostic.

The generalisation for this guide: **every context-engineering change you make is a change to a
prompt**, and the prompt is not type-checked. Renaming a tool, dropping an entry, summarising a turn,
redacting a name — all of these are edits to the most important string in your app, made by code that
the compiler cannot help you with.

### 11.5 The only real answer is measurement

Session 242 ends its own KV/accuracy discussion by handing the problem to a different framework, and
it is right to:

> ✅ **VERIFIED** — `242:185-187`, verbatim: *"When you start to get into **nuanced transcript
> modifications** like this, it becomes **even more important to use the Evaluations framework to
> create eval sets and quantify the effect of context engineering strategies. Data driven optimization
> is the only way to be confident.**"*

> ✅ **VERIFIED** — session 243 closes the same way (`243:143-145`): *"Once you've ironed out the bugs,
> **the next thing to explore is evaluation.** … see how you can **measure and improve the quality of
> your prompts by using structured evaluation.**"*

Concretely, what you want from [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md) for this guide's material:

| Question from this guide | What to build in Evaluations |
|---|---|
| Does `historyTransform(suffix(4))` hurt answer quality? | Same eval set, two implementations (with and without the transform), compare. |
| Does `summarizeHistory` lose facts the model needed? | Judge on fact-retention across a long multi-turn set. |
| Did adding a tool mid-session actually change behaviour? | Tool-call trajectory evaluation over `session.transcript.structuredTranscript`. |
| Did an OS update change the answer? | Re-run the same set — this is the *only* mitigation for the absence of model version pinning. |

That last row is not optional advice. Apple confirmed on the forums that **there is no model version
pinning API and no version-retrieval API**, and named the Evaluations framework as the recommended
mitigation for catching regressions between OS updates (Apple Frameworks Engineer, thread 833642).
There are three shipped on-device model versions already:

> ✅ **VERIFIED** — the `SystemLanguageModel` page, verbatim: *"Apple periodically updates
> `SystemLanguageModel` in routine OS updates… Currently there are **3 model versions** that align
> with: iOS, iPadOS, macOS, and visionOS **26.0 – 26.3**; iOS, iPadOS, macOS, and visionOS **26.4**;
> iOS, iPadOS, macOS, visionOS, **and watchOS 27.0**."*

Any latency or quality number you measure is measured against one of those three. A context strategy
tuned on 26.3 is not automatically the right strategy on 27.0 — Apple explicitly says the 26.4 model
improved *"instruction-following and tool-calling abilities"*, which is exactly the axis your
transcript surgery interacts with.

---

## 12. Putting it together: a context budget you can defend

Here is the whole guide as a procedure. Nothing in it is novel; it is §2–§11 in the order you would
actually do them.

### 12.1 Step 1 — Establish the ceiling at runtime

```swift compile:27 imports:FoundationModels
let capacity = SystemLanguageModel.default.contextSize     // 26.4 API, back-deployed to 26.0
let ceiling  = capacity > 0 ? capacity : 4_096             // documented floor as fallback
let inputBudget = ceiling - 512                            // leave room for the answer
```

Never a literal. See §3.4 for why, and §3.3 for the disagreement that makes it necessary.

### 12.2 Step 2 — Price the fixed costs once

These are paid on every request forever, so measure them once at development time and treat them as
constants in your head:

```swift compile:27 imports:FoundationModels
@available(iOS 26.4, macOS 26.4, visionOS 26.4, *)
func auditFixedCosts(model: SystemLanguageModel = .default,
                     instructions: Instructions,
                     tools: [any Tool]) async throws {
    let i = try await model.tokenCount(for: instructions)
    let t = try await model.tokenCount(for: tools)          // ✅ [any Tool] overload, verified 26.5 SDK — §4.1
    let capacity = model.contextSize

    print("instructions: \(i) tokens")
    print("tools:        \(t) tokens")
    print("fixed cost:   \(i + t) of \(capacity) (\(100 * (i + t) / max(capacity, 1))%)")
}
```

If the fixed cost is over ~25% of the window, you have a design problem, not a trimming problem.
Apple's own limits — three paragraphs of instructions, three to five tools (§2.6) — exist because of
this arithmetic.

⚠️ Do not forget the `@Generable` schemas. They are not in the instructions entry, but they are sent
with the request that uses them, and Apple lists them explicitly in the budget inventory (§1.1).

### 12.3 Step 3 — Choose a compaction policy *before* you need one

Pick one row, deliberately:

| Policy | Fidelity | Cache | Version |
|---|---|---|---|
| `historyTransform` with an in-place, shape-preserving edit | full | **preserved** | 27.0 |
| `historyTransform` with `suffix(n)` | recent only, **reversible** | invalidated at the sliding edge | 27.0 |
| `droppingCompletedToolCalls()` | keeps prose, drops tool traffic | invalidated from the first drop | 27.0 |
| `rollingWindow(entries:)` | ⚠️ known-buggy, can orphan a response | invalidated | 27.0 |
| `summarizeHistory(entryThreshold:model:)` | ⚠️ collapses to one entry, loses tool structure | invalidated (total) | 27.0 |
| Catch `.contextSizeExceeded`, condense, rebuild | whatever you kept | **cold cache** | 26.0 |

The 26.0 row is the only one available if you deploy below 27. It is also the only one that works
when the overflow is caused by a single enormous prompt rather than by accumulated history.

### 12.4 Step 4 — Compact at a boundary, not on a timer

Meter with `tokenCount(for:)` (§4.3), trigger at ~0.75, do one large consolidation, and do it in
`onResponse` — after the user has an answer, before the next prefill. §8.8 has Apple's own 100→50
example.

### 12.5 Step 5 — Wire the alarms

Two numbers, both cheap:

```swift illustrative
// Alarm 1: are we near the ceiling?
if try await meter.shouldCompact(session, threshold: 0.75) { … }

// Alarm 2: did the cache collapse? (27.0)
let rate = response.usage.cacheHitRate
```

Plus one Instruments run per release: profile the feature, look at the Model Inference lane, and check
that yellow (prefill) bars are short on turns 2+. A yellow bar that stays long across a conversation
means your prefix is being invalidated somewhere, and §8.10's expensive list is your checklist.

### 12.6 Step 6 — Prove it did not get worse

Run the eval set from §11.5 before and after every context-engineering change. This is the step people
skip, and it is the only one that catches the failure mode in §11.1 — where the change is fast,
correct-looking, and quietly makes the model do the wrong thing.

### 12.7 The five sentences worth memorising

1. **The transcript is the context window.** There is nothing else.
2. **`contextSize` is a runtime property, not a constant** — Apple documents 4096 for iOS 27; the
   unreproduced 8192 comment is retired historical provenance. Read the property instead of
   hardcoding a figure.
3. **Appending is free; editing costs everything after the edit point.**
4. **Static content at the top, conditional content at the bottom, always.**
5. **Trimming is a lie to the model** — the model cannot tell absent from removed, and it will reason
   confidently from what is left.

---

## 13. Quick reference

### 13.1 API index, with version floors

| Symbol | Declaration | Floor |
|---|---|---|
| `Transcript` | `struct Transcript` — Bidirectional/Mutable/RangeReplaceable Collection, `Codable` | 26.0 · watchOS 27.0 |
| `Transcript.Entry` | 6 cases: `.instructions` `.prompt` `.response` `.reasoning` `.toolCalls` `.toolOutput` | 26.0; `.reasoning` **27.0** |
| `Transcript.Segment` | `.text` `.attachment` `.structure` (beta 5, `27.0:2288-2297` — the fourth case, `.custom`, is not present in the beta 5 interface; §2.3) | 26.0; `.attachment` **27.0** |
| `Transcript.history` | `var history: Transcript.HistoryView { get set }` (`27.0:2695-2700`; `ArraySlice<Transcript.Entry>` before beta 5) | **27.0** |
| `Transcript.structuredTranscript` | `var structuredTranscript: StructuredTranscript { get }` — ✅ SDK-verified: declared by the **Evaluations** framework (Xcode-shipped), which extends `Transcript`; exists only where Evaluations is linked (`Evaluations-27.0-macos.swiftinterface:278-292`) | **27.0** (no Mac Catalyst) |
| `SystemLanguageModel.contextSize` | `@backDeployed(before: iOS 26.4, macOS 26.4, visionOS 26.4) final var contextSize: Int` | **26.4**, back-deploys to 26.0 |
| `SystemLanguageModel.tokenCount(for:)` | five overloads — `some PromptRepresentable` / `Instructions` / `[any Tool]` / `GenerationSchema` / `some Collection<Transcript.Entry>`, all `nonisolated(nonsending) … async throws -> Int` (✅ `FoundationModels-27.0-macos.swiftinterface:402-436`) | **26.4**, no back-deploy |
| `PrivateCloudComputeLanguageModel.contextSize` | `var contextSize: Int { get async throws }` | **27.0**[^pcc-context-size] |
| `LanguageModelSession.transcript` | `final var transcript: Transcript { get set }` — settable in 27 | 26.0 (get) · **27.0** (set) |
| `LanguageModelSession.isResponding` | `final var isResponding: Bool { get }` | 26.0 |
| `LanguageModelSession.usage` | `LanguageModelSession.Usage` | **27.0** |
| `Usage.Input.cachedTokenCount` | `init(totalTokenCount:cachedTokenCount:)` | **27.0** |
| `Usage.Output.reasoningTokenCount` | `init(totalTokenCount:reasoningTokenCount:)` | **27.0** |
| `prewarm(promptPrefix:)` | `final func prewarm(promptPrefix: Prompt? = nil)` | 26.0 (see gap below) |
| `LanguageModelError.contextSizeExceeded(_:)` | payload `ContextSizeExceeded(contextSize:tokenCount:debugDescription:metadata:)` | **27.0** |
| `GenerationError.exceededContextWindowSize(_:)` | **deprecated** | 26.0 |
| `LanguageModelSession.Error.transcriptMutationWhileResponding` | no payload | **27.0** |
| `historyTransform(_:)` | `([Transcript.Entry]) -> [Transcript.Entry]` | **27.0** |
| `@SessionProperty(\.history)` | read/write in a profile; **read-only in `Tool` / `DynamicInstructions`** | **27.0** |
| `droppingCompletedToolCalls()` | `-> some DynamicProfile` | **27.0** (utilities package) |
| `rollingWindow(entries:)` / `(size:)` | `RollingWindowSize.entries(Int)` only case | **27.0** (utilities package) |
| `summarizeHistory(entryThreshold:model:instructions:summaryPostamble:)` | first two have **no defaults** | **27.0** (utilities package) |

> ✅ **RESOLVED (2026-07-29) — `promptPrefix:` is a 26-era label, not a 27 addition.** There is no
> bare `prewarm()`/`prewarm(promptPrefix:)` pair — it is **one** declaration with a defaulted
> parameter, `final public func prewarm(promptPrefix: Prompt? = nil)`, and it sits in the plain
> iOS 26.0/macOS 26.0 extension of `LanguageModelSession` in **both** captured interfaces —
> ✅ **SDK-verified** (`FoundationModels-26.5-macos.swiftinterface:342`;
> `FoundationModels-27.0-macos.swiftinterface:1958-1962`, where the extension is
> `@available(iOS 26.0, macOS 26.0, visionOS 26.0, watchOS 27.0)`). No availability gate needed on
> the label when building with a 26.4+ SDK. (Caveat kept honest: a 26.5 interface proves the
> *26.5-SDK* view; whether the label was present in the original 26.0 SDK is not answerable from
> these captures, but the declared floor is 26.0 and there is no back-deploy shim to suggest
> otherwise.)

### 13.2 Numbers, with attribution

| Number | Value | Source class | Caveats |
|---|---|---|---|
| On-device context | **4,096 tokens per session** | **Apple-published** — **TN3193**, context-window article, PCC table, WWDC26 319, forum 790736 (DTS) | settled; read `contextSize` anyway |
| PCC context | **32K / 32,000 tokens** | **Apple-published** — PCC article + WWDC26 241 (`241:L31`) + 319 | — |
| Token ≈ characters (Latin) | **3–4 chars** | **Apple-published** — context-window article | — |
| Token ≈ characters (CJK/Vietnamese) | **1 char** | **Apple-published** — same | budget 3–4× for these locales |
| Max prompt length advice | **≤ 3 paragraphs** | **Apple-published** — same | — |
| Tools per request advice | **3–5** | **Apple-published** — same | — |
| `.complete` Spotlight guidance | **~13,000 tokens** | **community-measured** | instant overflow on a 4K model; no hardware/date |
| Prefix reuse, turn 2 @ 4,103 tok | **23.282 s → 0.230 s (101×)** | **community-measured** | qwen3-0.6b, sequential engine, a Mac, 2026-07-03; **Mac model and macOS build not stated** |
| Prefix reuse, turn 2 @ 357 tok | **1.915 s → 0.126 s (15.2×)** | **community-measured** | same harness, same caveats |
| Reuse fraction @ 4,103 tok | **4,075 / 4,103 = 99.3 %** | **community-measured** | same |
| EOS-break fix, turn 2 | **2.74 s → 0.40 s** | **community-measured** | qwen3.5-0.8B via `CoreAILanguageModel`; **device not stated** |
| Model switch, 0.6B↔4B | **2.35 s in / 0.94 s back**; **~920 MB** resident | **community-measured** | custom local provider; **hardware/OS not stated** |
| Origami's on-device history budget | **4 entries** (`entries.suffix(4)`) | **Apple sample code** | `OrchestratorProfile.swift` |
| Apple's documented consolidation ratio | trim at **100** entries → keep **50** | **Apple-published** — dynamic-profiles article | — |

### 13.3 The cache decision card

```
APPENDING                                   → free
prewarm() 1–2 s ahead                       → free (and hides turn-1 cost)
static instructions, fixed tools            → free
conditional content at the BOTTOM           → cheap
in-place, same-shape historyTransform       → cheap
one big consolidation at a threshold        → one invalidation

edit Instructions (incl. interpolated time) → EVERYTHING
add/remove a Tool                           → tool defs + whole transcript  (+ accuracy hazard)
conditional content at the TOP              → EVERYTHING
drop OLD transcript entries                 → nearly everything
drop NEW transcript entries                 → a little   ← the cheap trim
switch profile                              → EVERYTHING — deliberate reset only
rebuild session from transcript             → cold cache — prewarm()
```

### 13.4 Overflow catch ladder (27.0)

```swift illustrative
do {
    let response = try await session.respond(to: prompt)
    …
} catch let error as SystemLanguageModel.Error {
    // FIRST — availability, not generation. A different type entirely.
} catch LanguageModelError.contextSizeExceeded(let context) {
    // context.contextSize and context.tokenCount tell you the budget and the overage.
    // Condense → rebuild → prewarm(). Retry ONCE.
} catch let error as LanguageModelError {
    // .timeout / .guardrailViolation / .refusal / .unsupportedLanguageOrLocale / …
    // Non-frozen: always have a default.
} catch let error as GeneratedContent.ParsingError {
    // Separate type. Not a LanguageModelError case.
} catch {
    …
}
```

Ordering follows Apple's own Origami sample (§6.2). If you still build with Xcode 26, add a
`catch LanguageModelSession.GenerationError.exceededContextWindowSize` clause as well until you
rebuild — see the silent-failure box in §6.1.

---

## 14. Sources, and where they disagree

### 14.1 What this guide is built on

**Apple sample code (strongest evidence class — compiling first-party Swift):**
- **Origami: Crafting a dynamic tutorial for Apple Intelligence** (iOS 27, 61 Swift files) —
  `Models/OrchestratorProfile.swift:11-75` (the real `DynamicProfile`, `historyTransform` signature,
  `.model(_:)` modifier form, `entries.suffix(4)`), `Models/Error+DisplayMessage.swift:12-36` (the
  error ladder and its ordering), `Orchestrator.swift:103-139` (hand-authored transcript seeding),
  `TranscriptRecorder.swift:57-67` (`Transcript` is `Encodable`).

**Apple documentation pages (harvested 2026-07-27):**
- **`/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window`**
  (**TN3193**) — the 4096-tokens-per-session statement, the `tokenCount(for:)` input inventory
  (instructions, prompts, tools, schemas, transcript entries), the **six recommendations** that
  structure §2.6, the catch-and-rebuild recovery pattern with the first/last-entry example, and the
  `LanguageModelSession.GenerationError.exceededContextWindowSize(_:)` spelling. **Silent on the KV
  cache and on transcript-trimming APIs.**
- `/documentation/foundationmodels/managing-the-context-window` — the 4,096 figure, the token↔character
  ratios, the budget inventory, prompt-shortening rules, tool-count advice, the recovery snippet.
- `/documentation/foundationmodels/optimizing-key-value-caching-in-language-model-sessions` — the token
  layout, the invalidation rule, the ordering rule, stateless-vs-stateful transforms, the batching
  rule, the cheapest-trim rule, prewarm guidance, rehydration, profile-switch-as-reset, the
  cache-hit-rate formula, and all three tool-mutation accuracy hazards.
- `/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute` — the
  5-row capability table, 4K vs 32K.
- `/documentation/foundationmodels/systemlanguagemodel` (+ `/contextsize`, `/tokencount(for:)`),
  `/languagemodelsession` (+ `/usage`, `/error`), `/languagemodelerror`, `/transcript` (+ entry,
  segment and payload pages), `/generationoptions`, `/generable`,
  `/composing-dynamic-sessions-with-instructions-and-profiles`, `/updates/foundationmodels`.

**Apple open-source (`apple/foundation-models-utilities`, `apple/python-apple-fm-sdk`):**
- `History/DropCompletedToolCalls.swift`, `History/RollingWindow.swift`, `History/SummarizeHistory.swift`,
  `History/TranscriptRendering.swift`, and the matching test files — every modifier signature and
  semantic in §7, and the three defects in §7.4–§7.6.
- The C header and Swift shim in `python-apple-fm-sdk` — the five `tokenCount` bridges, and the
  availability asymmetry between `contextSize` (ungated) and token counting (26.4-gated).

**Apple Developer Forums (Apple-staff answers):**
- **833642** (Frameworks Engineer) — 4K, developer-managed overflow, `usage`, image bounds, no model
  version pinning.
- **790736** (DTS, "-J") — "around 4,000", catch-and-summarise guidance.
- **817502** (DTS, Ziqiao Chen) — `tokenCount(for:)` shipped in 26.4; the OP's "all context is lost"
  complaint; the TN3193 pointer (technote since fetched — see above).
- **835927** (Frameworks Engineer) — the 26→27 migration statement, and the hand-rolled
  `FoundationContext` wrapper it was answering.
- **833626** (Frameworks Engineer, accepted) — profile switching and context reconciliation;
  `historyTransform` as the recommended remedy.
- **833706** (Frameworks Engineer + Apple Designer) — `summarizeHistory` condenses everything into a
  `.prompt` entry and does not preserve tool-call IDs.

**WWDC26 sessions:**
- **242** *Build agentic app experiences with the Foundation Models framework* — the transcript-as-context
  framing, `historyTransform` semantics, the `history` decision rule, KV-cache rules, "training wheels
  off", the accuracy example, transcript mutability.
- **243** *Debugging and profiling Foundation Models features with Instruments* — lane colours, the three
  metrics, the silent-failure worked bug.
- **241** *What's new in the Foundation Models framework* — 26.4 context/token APIs, PCC 32K, image
  token cost.
- **319** — the on-device/PCC comparison table, `contextSize` announcement.
- **334** — the empirical prompt-length result (longer prompts → more overflow errors).
- **246** — focused vs complete Spotlight guidance for small context windows.
- **meet-with-apple-205** — instructions are always the first entry.

**Community repositories (always attributed as community-measured):**
- `john-rocky/coreai-models` fork, commits `0fdf710` and `627fec7`, plus
  `knowledge/prefix-cache-kv-reuse.md` — all of §9 and §10.
- `john-rocky/coreai-model-zoo`, `knowledge/dynamic-profiles-local-models.md` and
  `knowledge/agentic-security-checklist.md` — body re-evaluation count, model-switch costs,
  `historyTransform` timing.
- Frozen Noema 3.5 snapshot, `Noema/AFMLLMClient.swift:133-146` — the retired 8192 claim (§3.3
  historical footnote, not a rival to Apple's 4096) and the defensive
  `contextSize` reader.

### 14.2 Conflicts, and how this guide ruled

| # | Conflict | Ruling |
|---|---|---|
| 1 | **On-device context: documented 4,096 vs alleged device-specific 8192 (retired shipping-app source comment, iOS 27)** | **Apple-documented value: 4,096.** TN3193 states 4096 tokens per `LanguageModelSession`, and Apple's Group Lab 8121 written Q&A summary explicitly applies that platform value to iOS 27. The third-party 8192 comment has no device/build/date, never reproduced, and is retained only as historical provenance. Unchanged: **read `contextSize` at runtime** — PCC reports 32K through the same property and profile switching moves one transcript between both. §3.3. |
| 2 | **PCC 32K: previously flagged in our corpus as "community-claimed, not Apple-confirmed"** | **Retired the caveat.** The PCC documentation table, session 241 (`241:L31`) and session 319 all publish it. 32K is Apple-published. §3.2. |
| 3 | **`Profile(model:) { … }` (WWDC 242 reconstruction) vs `Profile { … }.model(x)` (Apple sample)** | **Sample wins.** Compiling first-party code outranks a reconstruction from spoken narration. Guide uses `.model(_:)`. Whether an `init(model:)` also exists is unverified and unused here. §7.2. |
| 4 | **`some LanguageModelSession.DynamicProfile` (our earlier working conclusion) vs `some DynamicProfile` (Apple sample)** | **Sample wins.** Conformance uses the nested name; the `body` type uses the short one, SwiftUI-style. §7.2. |
| 5 | **`historyTransform` signature — previously UNVERIFIED** | **Resolved by sample code:** `([Transcript.Entry]) -> [Transcript.Entry]`, and a plain function reference is accepted. Not a `Transcript`, not `async`, not `throws` in Apple's usage. §7.2. |
| 6 | **Session 242 points to 243 "for detecting cache invalidations with Instruments"; 243 never names a cache metric** | **Flagged in-guide.** 243 names only TTFT, tok/s and total latency. The cache-hit-rate metric exists only in the written docs. Compute it from `Usage` instead of hunting for it in the Instrument. §5.1. |
| 7 | **Utilities README: "Summarization runs only if the rolling window of 10 entries exceeds 5000 tokens"** | **Stale prose.** Zero hits for `5000` in `Sources/` or `Tests/`; commit `376ca60` replaced `threshold: 5000` with `entryThreshold: 10` and never updated the sentence. The package has **no token awareness at all**. §7.4. |
| 8 | **`contextSize` availability: docs say 26.4; Apple's Python bridge says it works on 26.0** | **Both true.** `@backDeployed(before: iOS 26.4, …)` means introduced-in-26.4, implementation-emitted-into-the-client. Build with the 26.4 SDK and it runs on 26.0. §3.1. |
| 9 | **Transcript mutation while responding: 242 calls it “programmer error”; the API defines `LanguageModelSession.Error.transcriptMutationWhileResponding`.** | **Resolved as a typed session failure, not evidence of a process trap.** Gate every mutation on `!session.isResponding`. §6.5.[^transcript-mutation-error] |
| 10 | **`init(profile:history:)` vs `init(model:tools:transcript:)`** | Both exist; Origami (27) uses `history:`, the older sample uses `transcript:`. Deprecation status of `transcript:` is **unverified**. Use `history:` on 27. §8.11. |
| 11 | **Body re-evaluation: 242 says "each time the model is prompted" (implies once); a community measurement says 7 evaluations for 3 turns** | **Reported both.** The community figure is from a custom provider with no stated hardware. The rule that follows is safe under either reading: **keep `body` pure.** §8.6. |

### 14.3 Declared gaps

| Gap | What is unknown | What would resolve it | Safe default meanwhile |
|---|---|---|---|
| Image token cost | How many tokens an attachment of a given resolution becomes. Forum 833783 asks and is unanswered; the "896 px longest dimension" figure in thread 838613 is a **developer inference**, not a fact. | `tokenCount(for:)` on a `Prompt` with one attachment, at several resolutions, on device. | Treat each image as an unknown large constant; measure the session with `Usage`, don't predict it. |
| KV-cache behaviour in Apple's technote | **TN3193 has now been read (2026-07-27) and says nothing about the KV cache** — no invalidation semantics, no transcript-trimming API. §8–§9 therefore still rest entirely on session 242, the KV-caching article and the `foundation-models-utilities` source. | An Apple technote or symbol page that documents cache invalidation directly. | Keep §8's markers as they are; do **not** treat TN3193 as corroboration for anything cache-related. |
| `tokenCount` overload *signatures* — **RESOLVED 2026-07-28** | Was: only the `Instructions` overload had a published declaration; the other four's exact spellings and attributes were inferred. Now: Apple's 26.5 `.swiftinterface` (module 1.5.2, lines 599–623) publishes all five verbatim — see §4.1. Two inferences were wrong: `some PromptRepresentable` (not `Prompt`) and `some Collection<Transcript.Entry>` (not `Transcript`). | Resolved by the 26.5 SDK interface on this machine. | Use the verified signatures in §4.1; treat them as stable into 27. |
| Token counting off `SystemLanguageModel` | There is no documented `tokenCount` on `PrivateCloudComputeLanguageModel` or on the `LanguageModel` protocol. | The PCC symbol index; a `LanguageModel` protocol header. | Meter with `SystemLanguageModel.tokenCount(for:)` even when targeting PCC; budgeting for the smaller model is the safe direction. |
| `prewarm(promptPrefix:)` floor | Whether the `promptPrefix:` label is 26.0 or 27.0. | The symbol page. | Bare `prewarm()` below 27; gate the prefix form. |
| `rollingWindow` and `.instructions` | Why the instructions entry survives a `suffix(2)` when the modifier has no logic to preserve it. | Framework source or a device experiment. | Preserve instructions explicitly in any window you write yourself. |
| Instruments lanes 3–6 | Session 243 says the Foundation Models Instrument has **6 lanes**; only *Instructions* and *Model Inference* are named. | A screenshot or the written Instruments doc. | Use the two named lanes; do not build a workflow on lanes nobody has enumerated. |
| Whether hybrid architectures could ever prefix-cache | The `-1` refusal is one implementation's choice. A checkpointing scheme for recurrent state is theoretically possible. | Any engine that implements recurrent-state snapshots. | Assume no. The architectural argument (a running scan cannot be rewound) is sound; only the possibility of a workaround is open. |

### 14.4 Cross-links

- **Sessions, prompts, instructions** →
  [`../../part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md`](../../part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md)
- **`@Generable` schemas as a token cost** →
  [`../../part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md`](../../part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md)
- **Tool definitions, `toolCallingMode`, the `.required` loop** →
  [`../../part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md`](../../part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md)
- **`SpotlightSearchTool` guidance levels (the ~13k-token gate)** →
  [`../../part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md`](../../part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md)
- **Image attachments** →
  [`../../part-02-foundation-models-everyday-api/references/05-image-input-and-attachments.md`](../../part-02-foundation-models-everyday-api/references/05-image-input-and-attachments.md)
- **The full error taxonomy and catch ordering** →
  [`../../part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md`](../../part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md)
- **`exceededContextWindowSize` → `contextSizeExceeded`, and the rest of the 26→27 rename** →
  [`../../part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md)
- **PCC quota, reasoning levels, the 32K window** →
  [`../../part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md`](../../part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md)
- **Writing an executor that actually reuses its cache** →
  [`../../part-04-beyond-the-built-in-model/references/04-executor-lifecycle-and-kv-reuse.md`](../../part-04-beyond-the-built-in-model/references/04-executor-lifecycle-and-kv-reuse.md)
- **Quantifying a context-engineering change** → [Part 6, Evaluations](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md)
- **The Foundation Models Instrument end to end** →
  [Part 5, Prototyping and profiling](../../part-05-prototyping-profiling-non-swift/README.md)
- **Version gating and the 26.0 / 26.4 / 27.0 split** →
  [`../../part-01-orientation-and-gating/references/02-platform-and-version-gating.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/references/02-platform-and-version-gating.md)

[^transcript-mutation-error]: Apple, [`LanguageModelSession.Error.transcriptMutationWhileResponding`](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/error/transcriptmutationwhileresponding), the typed error for mutating a session transcript while a request is in progress.
[^pcc-context-size]: Apple, [`PrivateCloudComputeLanguageModel.contextSize`](https://developer.apple.com/documentation/foundationmodels/privatecloudcomputelanguagemodel/contextsize), whose declaration is an asynchronous, throwing getter.
