# `#Playground`, scheme simulation, and reading a Foundation Models trace

**Part 5 · Prototyping, profiling, non-Swift access · Reference 01**

**Version floor.** Three tools, three different floors, and confusing them wastes days:

| Tool | Earliest OS / Xcode | Evidence |
|---|---|---|
| `#Playground` macro + canvas | **Xcode 26.0** (`import Playgrounds`) | ✅ 2025 code-along; ✅ shipping 2026 sample |
| Thumbs-up/down model feedback in the canvas | **macOS / iOS 26 Beta 4** | ✅ Apple DTS, Developer Forums thread 791250 |
| Input/Response token counts in the canvas | **26.4** | ✅ Apple's *Foundation Models updates* page, "February 2026" |
| `session.logFeedbackAttachment(…)` / `LanguageModelFeedback` | **iOS 26.0**, watchOS 27.0 | ✅ FoundationModels symbol index |
| Scheme ▸ *Simulated Apple Foundation Models Availability* — availability cases | **Xcode 26.0** | ✅ 2025 code-along |
| …the same menu's **quota** cases | **Xcode 27.0** (needs `PrivateCloudComputeLanguageModel`, 27.0) | ✅ WWDC26 session 319 + Apple's PCC article |
| **Foundation Models instrument, 2025 shape** (Blank template ▸ `+`) | **Xcode 26.0** | ✅ 2025 code-along |
| **Foundation Models instrument, 2026 shape** (own template, 6 lanes, tree view) | **Xcode 27.0**, device on the latest OS | ✅ WWDC26 session 243 |
| `LanguageModelSession.usage` | **iOS 27.0** | ✅ FoundationModels symbol index |

Everything in §6–§10 of this guide requires **Xcode 27** and a device running **iOS / iPadOS / macOS /
visionOS 27**. Nothing here requires 26.2 — and note that the token-count readout in the playground
canvas is a **26.4** feature, so a reader on 26.0–26.3 will look for it and not find it.

---

## What this covers

Foundation Models is a non-deterministic runtime with no useful `XCTAssertEqual`, and — this is the part
that catches people — **most of its defects do not throw**. The framework will happily run a broken
feature forever and report success. This guide is the observability story for that: three tools, used in
a fixed order, that between them cover prototyping, unhappy paths, and production-shaped latency.

- **`#Playground`** — the fastest prompt-iteration loop there is (no build, no run, full access to your
  project's types), what its canvas shows you, and the one thing it is silently bad at.
- **`#Playground` as Apple's official bug channel.** The thumbs-up icon next to a response in the canvas
  is the documented way to report a bad model output, per Apple's own pinned (and locked) forum thread.
  The programmatic equivalent, `logFeedbackAttachment(sentiment:issues:desiredOutput:)`, for feedback
  you collect from real users.
- **Scheme simulation** — *Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Options ▸ "Simulated Apple Foundation
  Models Availability"*, which is how you reach `.unavailable(.appleIntelligenceNotEnabled)` and
  *Quota Usage Limit Reached* without owning four devices and burning a real PCC quota.
- **The Foundation Models instrument in Xcode 27** — how to launch it, ⚠️ **why the trace file is a
  sensitive artefact**, all six documented lanes, the tree detail view, and the Info column.
- **The canonical worked bug**, reproduced end to end: a tool referenced in the *instructions text* but
  absent from the *toolset*. The model loops, keeps calling tools, and never throws. This is the bug
  Apple built an entire WWDC session around, and it is the archetype for the whole class.
- **Three session metrics** — Time to First Token, Tokens per Second, Total Latency — plus the four
  current token metrics: Total, Consumed, Generated, and Cached. The KV-caching page supplies the
  cache-hit formula and the interpretation of a low rate between turns.

## What you need

- **Xcode 27** and a physical device on the matching OS. Not the Simulator — see §2.6; the Simulator
  punches inference out to the host macOS and manufactures errors that look like your bug and are not.
- A Foundation Models feature that already compiles. If you are still writing it, read
  [Part 2 guide 01](../../part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md)
  first.
- For §8 to mean anything, familiarity with `DynamicInstructions` and the tool-calling loop —
  [Part 2 guide 03](../../part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md)
  and [Part 3 guide 02](../../part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md).
- For §10, [Part 3 guide 01](../../part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md),
  which this guide is the measuring instrument for.

> ⚠️ **A word about what this guide does not claim.** Nobody on this project has run Xcode 27's
> Instruments. Statements about the instrument's UI below are traced to Apple's spoken narration in
> WWDC26 session 243 or to the direct Apple Markdown captures preserved in
> [the 2026-09-22 evidence note](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/notes/web/apple-foundation-models-runtime-performance-2026-09-22.md).
> Claims those sources still do not establish — such as a dedicated prewarm-completion indicator —
> remain explicitly marked 🟡 **RECONSTRUCTED**. The written documentation now names all six lanes and
> all four current token metrics; this guide does not infer UI fields beyond that evidence.

---

## Contents

1. [Three properties that break normal debugging](#1-three-properties-that-break-normal-debugging)
2. [`#Playground`: the inner loop](#2-playground-the-inner-loop)
3. [`#Playground` is also the bug-reporting channel](#3-playground-is-also-the-bug-reporting-channel)
4. [Scheme simulation: reaching states you cannot otherwise reach](#4-scheme-simulation-reaching-states-you-cannot-otherwise-reach)
5. [Launching the Foundation Models instrument](#5-launching-the-foundation-models-instrument)
6. [Anatomy of a trace, part 1: the lanes](#6-anatomy-of-a-trace-part-1-the-lanes)
7. [Anatomy of a trace, part 2: the tree detail view](#7-anatomy-of-a-trace-part-2-the-tree-detail-view)
8. [⚠️ The canonical worked bug: a tool named in prose, missing from the toolset](#8-️-the-canonical-worked-bug-a-tool-named-in-prose-missing-from-the-toolset)
9. [Duration and token metrics](#9-duration-and-token-metrics)
10. [Detecting KV-cache invalidation](#10-detecting-kv-cache-invalidation)
11. [What changed between the 2025 and 2026 instrument](#11-what-changed-between-the-2025-and-2026-instrument)
12. [The whole loop, in order](#12-the-whole-loop-in-order)
13. [Things the instrument does not replace](#13-things-the-instrument-does-not-replace)
14. [Quick reference](#14-quick-reference)
15. [Declared gaps](#15-declared-gaps)
16. [Sources](#16-sources)

---

## 1. Three properties that break normal debugging

Apple opens the Instruments session by naming why the ordinary toolchain does not work here, and the
framing is worth keeping because it tells you what each tool in this guide is *for*.

> ✅ **VERIFIED** — WWDC26 session 243, verbatim (`transcripts/wwdc2026-243.txt:11-14`): *"Building with
> Large Language Models or LLMs is different from traditional development. Traditional code is
> predictable. **LLMs are non-deterministic — the same input can produce different outputs.** When a
> feature loses context or responds too slowly, tracking down the cause isn't straightforward."*

Three specific challenges follow, and each one maps to a section of this guide.

**1. Probabilistic output.**

> ✅ **VERIFIED** — `243:21-26`: *"Give a traditional function the same input twice, and you get the same
> output. LLMs don't work that way. The same prompt can produce two completely different responses
> **which means standard unit testing breaks down. You can't assert that an output matches a hardcoded
> string. You have to evaluate the quality and intent of the response instead.**"*

That is the argument for `#Playground` (§2) as a *human-judgement* loop, and ultimately for the
Evaluations framework ([Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md)) as the automated one. It is also why
"it worked when I tried it" is not evidence of anything.

**2. Model-to-model communication.**

> ✅ **VERIFIED** — `243:27-30`: *"Powerful features often rely on multiple models working together. For
> example, in a recipe app, one model might identify ingredients in a photo, while a second generates a
> recipe from that result. **Getting data to flow reliably between those models, and recovering
> gracefully when something goes wrong, is where real complexity lives.**"*

Everything in Part 3 — dynamic profiles, baton-pass, phone-a-friend — creates this problem. §8 is what
it looks like when the handoff silently fails.

**3. Observability.**

> ✅ **VERIFIED** — `243:31-33`: *"When something breaks in a multi-model pipeline, it can be very hard
> to know where it went wrong. **You need visibility into each step: what the model received, what it
> decided, and why.**"*

That is the instrument (§5–§9).

### 1.1 The loop is the unit of analysis, not the call

The single structural fact that makes the trace readable is that **one call to `respond(to:)` is not one
model inference**.

> ✅ **VERIFIED** — `243:40-43`: *"The loop works like this: the person sends a prompt, the model reasons
> about it and calls a tool, that tool performs an action, the model takes the result and generates a
> final response, **which can kick off the loop again**. Each extra step adds latency. Each step is a new
> place for failure. **Understanding this loop is the basis for everything the Foundation Models
> Instrument shows you.**"*

Hold on to that. The tree view in §7 is literally a rendering of that loop, and the reason it has four
levels rather than two is that a single user-visible request fans out into N inferences plus the tool
executions between them.

### 1.2 The three tools, and when each one is the right one

| Tool | Answers | Costs you | Cannot tell you |
|---|---|---|---|
| **`#Playground`** | "Is this prompt any good?" | seconds; no build | anything about latency in your real app, or about your app's state machine |
| **Scheme simulation** | "What does my UI do when the model is unavailable / the quota is gone?" | one menu, one relaunch | whether the *real* unavailable path behaves the same (it is a simulation of the API's answer, not of the system state) |
| **The instrument** | "Where did the time go, and what did the model actually see?" | a build + a trace + a privacy decision | whether the output was *good* — that is Evaluations' job |

Use them in that order. Most of the mistakes in this area are people reaching for the instrument to
answer a question `#Playground` would have answered in ten seconds, or reaching for `#Playground` to
answer a question only a trace can answer.

---

## 2. `#Playground`: the inner loop

### 2.1 The macro, the canvas, and the refresh button

`#Playground` is a macro from the **`Playgrounds`** module — not from FoundationModels. You import both.

> ✅ **VERIFIED** — Apple's Book Tracker sample, `BookTracker/Services/BookTaggingService.swift:8-10`:
>
> ```swift
> import Foundation
> import FoundationModels
> import Playgrounds
> ```

The mechanics, from Apple's code-along:

> ✅ **VERIFIED** — Foundation Models framework code-along, verbatim
> (`transcripts/meet-with-apple-205.txt:149-151`): *"As soon as you use a playground macro to create a
> playground, **you'll see a canvas show up on the right**. If it doesn't, you can always click on
> **editor options and ensure that there's a check mark next to canvas**. You can click the **refresh
> button** and what that does is **run all the code contained within the playground block**."*
>
> ⚠️ Note the vintage: this code-along explicitly targets *"macOS Tahoe and Xcode 26"*
> (`205:55`), so it is the **26 baseline**. The `#Playground` mechanics it describes are unchanged in
> the 2026 samples, but treat any UI detail from it as "at least true in 26".

The important word in that quote is **all**. The refresh button re-runs the entire block, every time.
There is no incremental evaluation and no cell-by-cell execution: if your block makes three model calls,
refreshing makes three model calls. On-device that is cheap; against `PrivateCloudComputeLanguageModel`
it is three requests against a per-user daily quota. Keep PCC prototyping in a *separate* block from
your fast on-device iteration so you are not silently spending quota on every refresh.

The canvas is a live object inspector, not a console.

> ✅ **VERIFIED** — `205:154-163`: inspecting `session` in the canvas surfaces **`tools`** and
> **`transcript`** (*"which includes all the conversations that you have with the model"*); the
> `response` value surfaces **`prompt`** and **`content`**, and at that stage `content` is a `String`.

That is worth more than it sounds. The single most useful debugging artefact in this framework is the
`Transcript`, and the canvas gives it to you as a browsable tree with no code at all. When a prompt
misbehaves, expand `session.transcript` in the canvas before you do anything else — you will see the
instructions entry, the tool definitions folded inside it, and the exact prompt entry the model
received.

### 2.2 Multiple blocks become tabs

> ✅ **VERIFIED** — `205:211, 216`: *"a neat feature of playground is **you can add multiple of these in
> the same Swift file**"* … *"**The second playground will show up as a second tab** here on our canvas."*

This is the feature that makes `#Playground` a genuine test bench rather than a scratch pad. One block
per scenario, all in the same file next to the code under test:

```swift prelude:guide-context
import FoundationModels
import Playgrounds

// Tab 1 — the happy path.
#Playground {
    _ = try await TaggingService.generateTags(for: reviewFixtures.prideAndPrejudice)
}

// Tab 2 — the adversarial input you keep forgetting to retest.
#Playground {
    _ = try await TaggingService.generateTags(for: reviewFixtures.emptyString)
    _ = try await TaggingService.generateTags(for: reviewFixtures.wallOfEmoji)
}

// Tab 3 — the one that reproduces the bug you are about to file with Apple. See §3.
#Playground {
    let session = LanguageModelSession()
    _ = try await session.respond(to: "List all states of USA.")
}
```

They stay in your source tree, so the next person who touches the prompt inherits the scenarios. That
matters more than it looks: prompts have no type system, and this file is the closest thing to one.

### 2.3 The playground sees your whole project without building it

> ✅ **VERIFIED** — `205:764-766`, verbatim: *"a neat feature of playground is that **it has access to all
> the data structures in your Xcode project, without having to build the app**. So what I'm doing here
> is create a landmark variable that has access to the model data defined here under the models folder …
> So you have access to **the same list of landmarks that you get when you run the app**."*

So the loop is: change a prompt string, hit refresh, read the canvas. No build, no launch, no navigating
three screens deep into your own app to reach the feature. And because your real types are in scope, you
can exercise the *actual* function your app calls rather than a copy of it — which is exactly what
Apple's own sample does.

### 2.4 What Apple ships in a playground block

The Book Tracker sample keeps its playground **in the service file itself**, at the bottom, below the
type it tests. Here it is in full, because the shape is the lesson.

> ✅ **VERIFIED** — `BookTracker/Services/BookTaggingService.swift:76-101`, verbatim from the downloaded
> Apple sample archive:

```swift prelude:guide-context
#Playground {
    let prideAndPrejudice = """
        okay I am OBSESSED and I need everyone to read this RIGHT NOW.
        I picked this up thinking it would be stuffy and old-fashioned
        and instead I got the most satisfying slow-burn romance I have
        ever read in my entire life?? Darcy's first proposal where he
        basically says \"I love you but your family is embarrassing\"
        and she just absolutely destroys him?? I cheered out loud And
        the redemption arc!! Darcy secretly paying off Wickham to save
        Lydia, doing it purely out of love for Elizabeth even after
        she rejected him, is the kind of romantic gesture that modern
        book heroes can only dream of. This book invented romantic
        tension and I will not be taking questions.
        """

    let dracula = """
        Read this in one sitting between midnight and 4am and I cannot
        explain why I did that to myself. Genuinely unsettling. Had to
        turn the lights on twice. Mina Harker deserved better from
        every film adaptation that came after this book.
        """

    _ = try await BookTaggingService.generateTags(for: prideAndPrejudice)

    _ = try await BookTaggingService.generateTags(for: dracula)
}
```

Four things to steal from twenty-six lines:

**It calls the real service.** `BookTaggingService.generateTags(for:)` is the same static method the app
calls (`:37-45`). Nothing is duplicated, so the playground cannot drift away from production.

**`_ =` on the result.** The block discards the return values. You are not asserting on them; you are
*reading them in the canvas*. That discard is what silences the unused-result warning while leaving the
value inspectable.

**The inputs are deliberately unruly.** Double question marks, an unclosed thought, no punctuation
discipline, escaped quotes inside a multi-line literal. Real reviews look like this, and a prompt tuned
on clean prose falls over on them.

**Two samples, chosen for contrast.** One long and effusive, one short and terse — because the failure
mode being hunted (tag count, per session 298) is length-sensitive.

That block is also the first rung of the ladder Part 6 is built on:

> ✅ **VERIFIED** — WWDC26 session 298, verbatim (`298:50-55`): *"Okay, we've just completed our first
> evaluation of the service. **We created a list of expectations and used our human judgement to measure
> how the service performed.** Unfortunately **human judgement doesn't scale**. But we've created a way
> to automate and scale evaluations. All you have to do is add `import Evaluations`, and implement the
> `Evaluation` protocol."*

The expectations that fell out of running exactly that block became the spec: *"9 tags is more than I was
expecting"* (`298:42`), *"I don't want the book's name as a tag, either"* (`298:43`), *"Multi-word tags
are gonna be a problem in the UI"* (`298:44`). **Write those observations down while you are in the
playground.** They are the evaluation suite you will write next week, and they are much harder to
reconstruct later.

### 2.5 The token counter (26.4+)

> ✅ **VERIFIED** — Apple's *Foundation Models updates* page, **"February 2026"** entry (the 26.4 wave),
> verbatim: *"Use the `#Playground` macro in Xcode to view an estimate of the usage of 4,096 tokens in
> the available context window. When you run the canvas, the output displays **Input Token Count** and
> **Response Token Count** separately."*

Two things follow. First, this is a **26.4 feature** — if you are on 26.0–26.3 it is simply not there,
and a good deal of confused forum traffic is people looking for it. Second, the number is framed against
**4,096 tokens**, the on-device context window:

> ✅ **VERIFIED** — Apple's *Managing the context window* article: *"Apple's on-device foundation model
> has a context window of **4096 tokens per session**"*, and *"This includes all prompts, instructions,
> tool definitions and their input and output, generable type schemas, and all of the model's
> responses."*

So the canvas readout is the cheapest possible budget check: write the instructions, write the schema,
add the tools, refresh, and read Input Token Count before you have built anything. The related
programmatic APIs are `SystemLanguageModel.tokenCount(for:)` and `SystemLanguageModel.contextSize`, both
**26.4** (✅ symbol index; `contextSize` carries `@backDeployed(before: iOS 26.4, macOS 26.4,
visionOS 26.4)`).

For a worked sense of scale: the code-along's session — *one* tool, one `@Generable` output type, one
short instruction block — measured **1,044 max tokens** in the instrument's inference pane, and dropped
to **700** after excluding the schema from the prompt (✅ `205:897`, `205:985`; Apple-published,
Xcode 26 era, hardware unstated). A quarter of the window, before the user typed anything.

### 2.6 What `#Playground` will not tell you — and the trap under it

The playground is a prompt bench. It is not a performance bench and it is not an integration test.

**It does not measure your app's latency.** Every model call in a playground pays whatever cold-start
cost the OS charges at that moment, and there is no `prewarm()` in the loop.

> ✅ **VERIFIED** — `205:166-170`: *"When you make the very first call to `session.respond`, you might
> notice that there's a slight delay. **This is because the on-device language model needs to be loaded
> into memory before it can process your request.** Our first request triggers a system to load the
> model, which causes the initial latency."*

In the code-along's trace that asset load was **~700 ms** blocking first token (✅ `205:891`;
Apple-published, Xcode 26 era, device unstated). In your shipping app you will have moved it out of the
critical path with `prewarm(promptPrefix:)`. In a playground you cannot, so any number you read there is
a pessimistic upper bound, useful for nothing but shock value.

**It does not exercise your state machine.** A `DynamicProfile` whose `body` reads `orchestrator.mode`
resolves to whatever mode you construct by hand. The bug in §8 — the *handoff* between two instruction
sets — is invisible in a playground, because a playground has no app driving the transitions. That is
precisely why Apple's Instruments session exists.

**And it runs somewhere you may not expect.**

> ⚠️ **SILENT FAILURE — the Simulator trap.** Xcode ships the SDK; the *model* ships with the OS. When
> you run against the Simulator, inference is executed by the **host Mac's** OS, not by anything
> resembling your deployment target. Xcode 27 SDK on a macOS 26 host produces errors that are pure
> version skew, and they do not identify themselves as such — you get a bare
> `FoundationModels.LanguageModelError error -1`.
>
> ✅ **VERIFIED** — Apple Designer, Developer Forums thread 831404, accepted answer, verbatim: *"Xcode
> 27.0 contains the latest SDK, but the on-device `SystemLanguageModel` is actually built into the OS.
> **Meaning that when you run simulator from Xcode, the simulator is actually 'punching out' to macOS to
> run the model**, using the 26.5 model inference code in the OS. Whenever we see 'weird' errors like
> this, it's usually an underlying incompatibility between the Xcode SDK and OS for running the model.
> **Suggested Fix: Update a physical device to 27.0.**"*
>
> And the harder version:
>
> ✅ **VERIFIED** — Frameworks Engineer (Apple), thread 831998, accepted, quoting the iOS 27 release
> notes: *"**Private Cloud Compute might not work when you use simulators. (177684296)** Workaround: Use
> a physical device running OS 27.0."*
>
> **The practical rule: a Foundation Models bug is not a bug until you have reproduced it on a physical
> device on the matching OS.** This is, by a wide margin, the largest single source of phantom bug
> reports in the developer forums. Before you spend an afternoon on an error code, check what you are
> running on.
>
> ✅ **Probe-verified nuance, 2026-07-31** (`probes/` `fm.availability` and friends, iOS 27.0
> Simulator runtime 24A5390f on a macOS 26.5.2 host): the "punching out" picture needs one
> correction — **the 27.0 sim runtime resolves model availability and assets independently of the
> host's Apple Intelligence toggle.** With host Apple Intelligence OFF (the host's own `swift test`
> reports `.appleIntelligenceNotEnabled`), the sim still reported `available` and ran text
> inference, guided generation, streaming, and 8 concurrent sessions. What the sim runtime *lacks*:
> tool-calling assets (`ModelManagerError 1026` / `UnifiedAssetFramework 5000`) and image
> attachments (`LanguageModelError -1`). So the sim is more usable for plain/guided-generation
> prototyping than the folklore says — and still useless for tool calling, attachments, PCC, and
> any number you intend to quote.
>
> ✅ **Physical baseline, 2026-08-20:** the attached iPhone 15 Pro / iOS build `24A5408d` reported
> `available` and declared `.vision`, `.toolCalling`, and `.guidedGeneration` but not `.reasoning`.
> Text, guided generation, and tool invocation ran. Image `respond` calls also ran, while
> `tokenCount(for:)` with the same generated image threw code `-1` at every tested size. Treat
> `capabilities` as routing/declaration metadata, not proof that every auxiliary path is healthy.

One live example of how unhelpful the failure looks, so you recognise it:

> ✅ **VERIFIED** — Developer Forums thread 836285. This exact playground, on Xcode 27 beta 2:
>
> ```swift
> #Playground {
>     let session = LanguageModelSession()
>     let response = try await session.respond(to: "List all states of USA.")
>     print(response.content)
> }
> ```
>
> → `The operation couldn't be completed. (com.apple.SensitiveContentAnalysisML error 15.)`
>
> Toggling Apple Intelligence off and on did not help; Apple's replies were "file a bug" and "was it
> fixed in the latest beta?". **The error domain `com.apple.SensitiveContentAnalysisML`, code 15, is
> undocumented.** Nothing about the prompt is remarkable. If you hit this, you have not done anything
> wrong — check §3 and file it.

> 🔴 **GAP — where a `#Playground` block actually executes.** We could not establish whether a
> playground attached to an iOS target runs its Foundation Models calls on the host Mac, in a
> Simulator runtime, or on a connected device, nor whether it honours the scheme's run destination.
> The forum evidence above (macOS-hosted execution for the Simulator) makes host execution the likely
> answer for the Simulator destination, but nobody has confirmed it and no Apple source states it.
> **Resolving this needs someone with Xcode 27 to run a playground with a device selected and check
> whether the response reflects that device's OS version.** Safe default meanwhile: **use
> `#Playground` for prompt shape and structure, and confirm every behavioural claim on a device with
> the instrument or a real run.**

---

## 3. `#Playground` is also the bug-reporting channel

This is the part almost nobody knows, and it is Apple's own documented process rather than a community
workaround. The model is not something you can patch. When it refuses a benign prompt, ignores an
instruction, or returns nonsense, the only lever you have is a well-formed report — and Apple has told
you exactly what shape it should take.

> ✅ **VERIFIED** — Developer Forums thread **791250**, *"Provide actionable feedback for the Foundation
> Models framework and the on-device LLM"*, authored by a **DTS Engineer (Apple)**, posted 2025-07-01,
> **pinned and locked** (zero replies, by design). Two methods, paraphrased faithfully:
>
> **Method 1 — Xcode `#Playground` (macOS/iOS 26 Beta 4 and later):**
> 1. In Xcode, create a playground using `#Playground`.
> 2. Reproduce the issue by setting up a session and generating a response with your prompt.
> 3. In the canvas on the right, click the **thumbs-up icon** to the right of the response.
> 4. Follow the pop-up instructions and submit by clicking **"Share with Apple"**.
>
> **Method 2 — a Feedback Assistant report** (`https://developer.apple.com/bug-reporting/`), which must
> include:
> - **Language model feedback** — described as the *"essential component containing session transcript
>   (instructions, prompts, responses, etc.)"*
> - retrieved via **`logFeedbackAttachment(sentiment:issues:desiredOutput:)`**, written to a file and
>   attached;
> - plus a **sysdiagnose** if the problem looks system-configuration related.

Corroborated independently by the code-along, which shows the affordance without naming it:

> ✅ **VERIFIED** — `205:176-177`: *"We are always interested in improving the model, and if you want to
> provide feedback, **you can always use these buttons right here in Canvas to share your feedback with
> us.**"*

So the workflow is: **reproduce it in a playground first, then click the thumbs.** A minimal reproducing
`#Playground` block is both the fastest way to confirm the bug is in the model and the exact artefact
Apple's tooling wants. That is an unusually good alignment of incentives and you should use it.

### 3.1 The programmatic path: `LanguageModelFeedback`

Method 1 covers *your* observations. For feedback from real users — a thumbs-down in your own UI — you
need the API, because you cannot ask a user to open Xcode.

> ✅ **VERIFIED** — `LanguageModelFeedback` and the session method, from the FoundationModels symbol
> index (`iOS 26.0+, iPadOS 26.0+, Mac Catalyst 26.0+, macOS 26.0+, visionOS 26.0+, watchOS 27.0+ Beta`):
>
> ```swift
> struct LanguageModelFeedback
> struct LanguageModelFeedback.Issue        // init(category:explanation:) + Issue.Category
> enum   LanguageModelFeedback.Sentiment    // .negative, .neutral, .positive   (CaseIterable)
> ```
>
> ```swift
> @discardableResult
> final func logFeedbackAttachment(
>     sentiment: LanguageModelFeedback.Sentiment?,
>     issues: [LanguageModelFeedback.Issue] = [],
>     desiredOutput: Transcript.Entry? = nil
> ) -> Data
> ```

Apple's own usage examples:

> ✅ **VERIFIED** — from the `LanguageModelFeedback` documentation:
>
> ```swift
> let feedbackData = session.logFeedbackAttachment(sentiment: .positive)
>
> let feedbackData = session.logFeedbackAttachment(
>     sentiment: .negative,
>     issues: [
>         LanguageModelFeedback.Issue(
>             category: .incorrect,
>             explanation: "The model provided outdated information"
>         )
>     ],
>     desiredOutput: Transcript.Entry.response(...)
> )
> ```
>
> Building a `desiredOutput` by hand — this is the highest-value part of a report, because it tells Apple
> what *should* have happened:
>
> ```swift
> let text = Transcript.TextSegment(content: "The capital of France is Paris.")
> let segment = Transcript.Segment.text(text)
> let response = Transcript.Response(segments: [segment])
> let entry = Transcript.Entry.response(response)
> ```
>
> …or with a structured payload:
>
> ```swift
> let customType = MyCustomType(...) // A Generable type.
> let structure = Transcript.StructuredSegment(
>     schemaName: String(describing: Foo.self),
>     content: customType.generatedContent
> )
> let segment = Transcript.Segment.structure(structure)
> let response = Transcript.Response(segments: [segment])
> let entry = Transcript.Entry.response(response)
> ```
>
> The returned `Data` is JSON and the reports **concatenate**:
>
> ```swift
> let allFeedback = feedbackData + feedbackData2 + feedbackData3
> let url = URL(fileURLWithPath: "path/to/save/feedback.json")
> try allFeedback.write(to: url)
> ```

Wiring that into a real app is about fifteen lines:

```swift compile:27
import FoundationModels
import SwiftUI

@Observable
@MainActor
final class FeedbackCollector {
    private var pending = Data()

    /// Call from a thumbs-down button in your own UI.
    func record(
        session: LanguageModelSession,
        explanation: String,
        desired: String?
    ) {
        var desiredEntry: Transcript.Entry?
        if let desired {
            let segment = Transcript.Segment.text(Transcript.TextSegment(content: desired))
            desiredEntry = .response(Transcript.Response(segments: [segment]))
        }

        pending += session.logFeedbackAttachment(
            sentiment: .negative,
            issues: [
                LanguageModelFeedback.Issue(category: .incorrect, explanation: explanation)
            ],
            desiredOutput: desiredEntry
        )
    }

    /// Write out on demand, then attach the file to a Feedback Assistant report.
    func export() throws -> URL {
        let url = URL.documentsDirectory.appending(path: "language-model-feedback.json")
        try pending.write(to: url, options: .atomic)
        return url
    }
}
```

> ⚠️ **This payload contains the session transcript — instructions, prompts, responses, tool arguments.**
> Apple's own description of the attachment says so outright. Treat it exactly like the trace files in
> §5.2: get consent, do not auto-upload, do not log it to your own analytics, and scrub before sharing.

> 🔴 **GAP — the `LanguageModelFeedback.Issue.Category` case list.** Only **`.incorrect`** is attested,
> from Apple's example above. The other cases (there are certainly others — the type is a category enum)
> were never enumerated in any source we hold, and the symbol page was not fetched. Resolving this needs
> `/documentation/foundationmodels/languagemodelfeedback/issue/category` or a generated Swift interface
> from the 27.0 SDK. **Meanwhile: use `.incorrect` and put the real detail in `explanation`, which is
> free text and is what a human at Apple will actually read.**

> 🟡 **RECONSTRUCTED — two extra 27.0 overloads.** The symbol index also lists
> `logFeedbackAttachment(sentiment:issues:desiredResponseContent:)` and
> `logFeedbackAttachment(sentiment:issues:desiredResponseText:)` as iOS 27 additions. Those spellings
> come from an index listing rather than from a signature we read, so treat the labels as provisional —
> but note the intent, which is obvious and welcome: **`desiredResponseText:` almost certainly lets you
> pass a plain `String` instead of hand-assembling a `Transcript.Entry`.** If you are on 27, try it
> first; fall back to the `desiredOutput:` form above if it does not resolve.

### 3.2 The non-Swift hole

> ✅ **VERIFIED** — community-tracked, `python-apple-fm-sdk` issue **#5** (OPEN as of 2026-07-29,
> one comment, no activity since 2026-03-07):
> feedback submission — `LanguageModelFeedback` and `logFeedbackAttachment` — **is Swift-only and is not
> exposed by the Python SDK.** If you are prototyping in Python (see this part's `fm` CLI and Python SDK
> guide), you must reproduce the issue in Swift before you can report it.

---

## 4. Scheme simulation: reaching states you cannot otherwise reach

Two of the states your Foundation Models feature must handle are, on a working developer machine,
effectively unreachable. You cannot un-enable Apple Intelligence in the middle of a test run, and you
certainly cannot exhaust a PCC quota on demand — or rather you can, once, and then you have no quota for
the rest of the day. Xcode's answer is a scheme option that makes the framework lie to you.

### 4.1 The menu

⚠️ **The exact strings differ between Apple's spoken narration and Apple's written documentation.** Both
are quoted below; trust the docs for the labels and expect the transcript's wording on a beta build.

> ✅ **VERIFIED** — Apple's *Using Private Cloud Compute* article, verbatim:
>
> 1. Choose **Product > Scheme > Edit Scheme**.
> 2. Select the **Run** page and choose the **Options** tab.
> 3. Select either **"Approaching Quota Usage Limit"** or **"Quota Usage Limit Reached"** from the
>    **"Simulated Apple Foundation Models Availability"** drop-down menu.
> 4. Click Close and run your project.

> ✅ **VERIFIED** — WWDC26 session 319, verbatim (`transcripts/wwdc2026-319.txt:91-95`): *"In Xcode, we
> have a convenient debug option to simulate the usage limit status. In your scheme, select **Debug** and
> then **Options**. Here we have the **Simulate Apple Foundation Models Availability** option. We can
> select **Quota Usage Limit Reached**, to simulate the case we just handled in our UI. And we can also
> select **Nearing Usage Limit**, to simulate the case where the user is close to reaching their daily
> limit."*

| | Session 319 (spoken, beta build) | Apple's PCC article (written) |
|---|---|---|
| Scheme page | "Debug" → "Options" | **"Run"** page → "Options" tab |
| Menu title | "**Simulate** Apple Foundation Models Availability" | "**Simulated** Apple Foundation Models Availability" |
| Limit-reached option | "Quota Usage Limit Reached" | "Quota Usage Limit Reached" ✅ agree |
| Approaching option | "**Nearing Usage Limit**" | "**Approaching Quota Usage Limit**" |

**Ruling:** the documentation wins on labels — it is a later, edited artefact and the guides README puts
Apple docs above session transcripts. What both agree on is that **the menu exists in the scheme's run
options and carries at least those two quota states.** If you cannot find "Debug", you are looking for
"Run".

There is a third label in circulation, from the 2025 code-along, and it is worth knowing because it tells
you the feature predates the quota states by a year:

> ✅ **VERIFIED** — Foundation Models code-along, verbatim (`205:255-258`): *"we've added these
> availability checks … **but how do you test them? You may not have access to multiple test devices.
> Thankfully, there's an easy way.** … click **edit scheme**, and if you scroll down, you'll see an
> option that says **simulated foundation models availability**. If you click this, there are a few
> different options, and **these options should be familiar to you because these are the cases we covered
> in the playground.**"*
>
> The presenter selects **"Apple Intelligence Not Enabled"**, runs, and the app shows *"Trip Planner is
> unavailable because Apple Intelligence has not been turned on."* (`205:258`)

So: **the menu existed in Xcode 26 with the availability cases, and gained the quota cases in Xcode 27
alongside `PrivateCloudComputeLanguageModel`.** The Xcode 26 title omits the word "Apple" ("Simulated
Foundation Models availability"); the 27 title includes it. Trivial, but it is why searching the menu for
the wrong string fails.

### 4.2 The availability branches it lets you reach

The options mirror `SystemLanguageModel.Availability`:

> ✅ **VERIFIED** — the four-case switch, from the code-along (`205:208-228`), with Apple's own guidance
> for each case in the comments:

```swift compile:27
import FoundationModels

let model = SystemLanguageModel.default

switch model.availability {
case .available:
    // "you have a green light… the model is loaded and you're ready to make
    //  generation requests."
    break

case .unavailable(.deviceNotEligible):
    // "the model doesn't support Apple Intelligence. You should gracefully hide the
    //  generative UI and show an alternate experience."
    break

case .unavailable(.appleIntelligenceNotEnabled):
    // "the device is capable, but Apple Intelligence is turned off in settings.
    //  This is your chance to prompt the user to enable it."
    break

case .unavailable(.modelNotReady):
    // "this is a temporary state, likely because the model assets are still
    //  downloading. The best practice is to tell the user to try again."
    break

@unknown default:
    break
}
```

> 🟡 **RECONSTRUCTED** — the `@unknown default:` arm. The narration lists four cases and stops; the
> `@unknown default` is required by Swift for a non-frozen enum and is not something Apple said. Keep it
> anyway; without it your switch will stop compiling the first time Apple adds a reason.

⚠️ **One of these branches is contaminated by a known Apple bug, and you should not design around it.**

> ⚠️ **`.appleIntelligenceNotEnabled` when Siri is off is a DEFECT, not behaviour.** Developer Forums
> threads 835211 and 836760 report `SystemLanguageModel.default.availability` returning
> `.appleIntelligenceNotEnabled` unless the user has enabled "Siri" / "Press Side Button for Siri", even
> with Apple Intelligence on. An **Apple Frameworks Engineer confirmed on thread 836760 that this is a
> bug.** Status unresolved as of 2026-07-27.
>
> You will hit this on 27 betas, and the scheme simulator is a good way to check your UI copy for it. But
> **do not ship UX that instructs users to turn on Siri to use your feature.** Handle the state, keep the
> message generic ("Apple Intelligence isn't turned on"), and expect the trigger to change under you.
> Full treatment in
> [Part 1 guide 02](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/references/02-platform-and-version-gating.md).

### 4.3 The quota branches

The quota states are the ones the scheme option earns its keep on, because the real ones cost you a day.

> ✅ **VERIFIED** — Apple's *Using Private Cloud Compute* article, verbatim sample:
>
> ```swift
> let model = PrivateCloudComputeLanguageModel()
>
> // Depending on the quota state, display a label to keep a person aware
> // of the status of their daily limit.
> if model.quotaUsage.isLimitReached {
>     Text("Usage limit exceeded")
>         .foregroundStyle(Color.red)
> } else if case .belowLimit(let info) = model.quotaUsage.status {
>     if info.isApproachingLimit {
>         Text("Nearing usage limit")
>             .foregroundStyle(Color.orange)
>     }
> }
>
> // Display a button in your UI to present the available upgrade options.
> if let suggestion = model.quotaUsage.limitIncreaseSuggestion {
>     Button("Show options") {
>         suggestion.show()
>     }
> }
> ```

Note the two-level test: `isLimitReached` is a `Bool` on `quotaUsage`, while "approaching" lives one
level down, inside the `.belowLimit(Information)` case of `quotaUsage.status`. Setting the scheme to
*Quota Usage Limit Reached* exercises the first branch; *Approaching Quota Usage Limit* exercises the
second. Both are things your users will see and you will otherwise never look at.

Apple is unusually prescriptive about the UI, and the guidance is good:

> ✅ **VERIFIED** — session 319, verbatim (`319:84-88`): *"You should integrate this with your existing
> UI. **Avoid showing an alert for the usage limit. Because this UI should persist, and not be
> dismissed.** Instead, you can **update the state of your UI, like disabling the button that makes a
> request.** And under that button I'm showing a **subtle label**, with the button for letting the user
> get a higher limit, if they want."*

And the reason a quota is not a rate limit:

> ✅ **VERIFIED** — Apple's PCC article: *"**Unlike rate limiting, where a person waits for a period of
> time before trying again, exceeding the daily quota means a person either waits for their usage quota
> to refresh or they upgrade to a higher tier.**"*

So there is no "retry in 30 seconds" recovery to write. The only correct behaviours are: degrade to the
on-device model, or tell the user, or offer `limitIncreaseSuggestion.show()`. Test all three with the
scheme option before you ship, because the first time you see this branch should not be in a review
screenshot.

### 4.4 What the scheme option does *not* do

> 🔴 **GAP — the exact contents of the menu in Xcode 27, and its semantics.** We have three partial
> descriptions from three different Apple sources across two years, and no screenshot. Specifically
> unknown: (a) whether the availability cases and the quota cases appear in **one** drop-down or two;
> (b) whether the list still uses the Xcode 26 labels for the availability reasons ("Apple Intelligence
> Not Enabled", "Device Not Eligible", "Model Not Ready") alongside the two quota labels; (c) whether
> selecting a quota state also forces `PrivateCloudComputeLanguageModel.availability`, or only
> `quotaUsage`; and (d) whether the simulated state applies to `respond(to:)` — i.e. whether a request
> actually throws `PrivateCloudComputeLanguageModel.Error.quotaLimitReached(_:)` — or only to the
> *reported* `quotaUsage`. **Resolving this needs someone with Xcode 27 to open the menu and to run one
> request under each setting.** Safe default meanwhile: **write your UI off `quotaUsage` and also catch
> the thrown error**, since Apple's own narration says a request "throws an error" when a user hits the
> limit (`319:77-78`) and the property-based UI is described as the way to make that *actionable*, not
> as a replacement for the `catch`.

Three more things it does not give you:

- **It does not simulate a slow or flaky PCC connection.** Nothing in the menu produces a timeout.
- **It does not simulate the on-device model being mid-download** in any way you can distinguish from
  `.modelNotReady` being returned instantly — the timing dimension is absent.
- **It is not a substitute for a real device with Apple Intelligence off.** It changes what the API
  reports; it does not change what the system is doing. For anything involving asset download or Settings
  state, you still need the device.

### 4.5 A test matrix worth pinning to the wall

| Branch | How to reach it | What must happen |
|---|---|---|
| `.available` | default | feature works |
| `.unavailable(.deviceNotEligible)` | scheme option | generative UI **hidden**, alternate experience shown; no "turn on Apple Intelligence" copy — the device cannot |
| `.unavailable(.appleIntelligenceNotEnabled)` | scheme option | generic explanatory copy; **no instruction to enable Siri** (§4.2) |
| `.unavailable(.modelNotReady)` | scheme option | "try again shortly", and a retry that actually retries |
| PCC quota approaching | scheme option | persistent subtle label, request still allowed |
| PCC quota reached | scheme option | request path disabled, `limitIncreaseSuggestion.show()` offered, **no modal alert** |
| PCC request throws | code path only — force it | same UI as "quota reached"; do not surface a raw error string |
| Guardrail / refusal | prompt content, on device | see [Part 2 guide 06](../../part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md) |

One editorial note on the first four rows, because Apple changed its own advice:

> ✅ **VERIFIED** — Apple's **2026 samples dropped proactive `availability` gating** in favour of
> reactively catching `SystemLanguageModel.Error`; the stale iOS 26 game sample still gates. Both are
> legitimate. The scheme option is the only way to test the *proactive* branches at all, which is a
> decent argument for keeping at least a thin one.

---

## 5. Launching the Foundation Models instrument

### 5.1 The click path

> ✅ **VERIFIED** — WWDC26 session 243, verbatim (`243:53-56`): *"The project is already open in Xcode. To
> begin profiling, I'll **open the Product menu and select Profile**. **Xcode will build the app
> locally.** From the **template chooser**, I'll select the **Foundation Models template** and click
> **Record**."*

> ✅ **VERIFIED** — Apple's *Managing the context window* article gives the same four steps in writing:
>
> 1. Choose **Product > Profile** to launch Instruments.
> 2. Select the **Foundation Models** template, then click Choose.
> 3. Click the **Record** button and interact with your app's AI features.
> 4. Observe the token count as your app interacts with the model.

> ✅ **VERIFIED** — the current runtime-performance page independently gives the three launch steps
> (Product > Profile, select the Foundation Models template, click Choose) and then directs you to the
> **Record Trace** button or File > Record Trace. See the
> [direct-page capture](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/notes/web/apple-foundation-models-runtime-performance-2026-09-22.md).

**Requirements**, stated flatly at the end of the session:

> ✅ **VERIFIED** — `243:146-148`: *"To get started with the improved Foundation Models Instrument,
> **install Xcode 27**. Then, **on the device you'd like to run and profile your app on, update to the
> latest OS releases**. It's important to note that **this Instrument supports using any model you use
> with the Foundation Models framework.**"*

Read that last sentence twice. It is the most under-appreciated fact about the instrument.

### 5.2 ⚠️ The Record Anyway dialog — read this before you click

> ⚠️ **The trace file contains your prompts and your model's responses, in the clear.** Foundation Models
> logging is **off in production**. Starting a trace turns it **on for the duration of the recording**.
> Instruments tells you this and makes you confirm.
>
> ✅ **VERIFIED** — `243:57-59`, verbatim, the dialog text as narrated: *"**This instrument captures
> prompt and response data from your device, which can include sensitive information. Logging is off in
> production but it's on for the duration of your trace so keep your trace files somewhere safe. Select
> 'Record Anyway' to get started.**"*
>
> ✅ **VERIFIED** — Apple's written version is blunter: *"Because a recording **captures and stores all
> Foundation Models prompts and responses in an unencrypted form**, Instruments presents an alert when
> you begin recording. The captured data can include sensitive information, so **handle trace files
> accordingly**, and use this feature in a manner consistent with the Apple Developer Program License
> Agreement."*

The operational consequences are not subtle, and they are the sort of thing that gets discovered during
a security review rather than before one:

- **A `.trace` is a personal-data artefact.** If you profiled a journaling app, a health feature, a
  messaging client — the user's text is in that file, unencrypted.
- **Do not commit `.trace` files.** Add `*.trace` to `.gitignore` now, before someone attaches one to a
  bug ticket "for reference".
- **Do not attach a raw trace to a public Feedback Assistant report** without reading what is in it.
  Reproduce with synthetic data first (this is another argument for §2: a `#Playground` with fixture
  text is a clean-room reproduction).
- **Profile with fixtures, not with your own real content**, whenever the feature touches anything
  personal. Your own inbox counts as personal data.
- **Treat trace files like crash logs with the symbols left in**: fine on your machine, a disclosure
  everywhere else.

If your organisation has a data-handling policy, a Foundation Models trace almost certainly falls under
it. Decide where these files live before you make the first one.

> ✅ **Observed 2026-07-31 — the consent also gates *scripted* recordings.** During the probe-package
> runs (`probes/`, macOS 26.5 host), driving the Foundation Models template through `xctrace`'s CLI
> recording path surfaced the same privacy consent interactively on the terminal: *"Captured prompts
> and responses could include sensitive or personally identifying information… Press 'Enter' to
> 'Record Anyway'"* — and **`xctrace` blocks waiting for that keypress**. Piping a newline into
> stdin does **not** satisfy it (measured 2026-07-31 — the prompt reads the controlling TTY, and the
> recording sat blocked for 20+ minutes with a newline piped); the supported answer is the
> documented **`--no-prompt`** flag (*"Skip any prompts that would be otherwise presented (like
> privacy warnings)"*, `xctrace record --help`). Two things follow: unattended automation around
> this template needs `--no-prompt`, and the consent text is itself first-party confirmation that
> the instrument records prompt/response *content*, not just timings.

### 5.3 It works with *any* model, and that is the point

`243:148` says the instrument supports **any** model used through the framework. Because 2026 turned
`LanguageModelSession` into a front end over a `LanguageModel` protocol, that covers a lot of ground:

| Backend | Covered? | Notes |
|---|---|---|
| `SystemLanguageModel` (on-device) | ✅ per `243:148` | the default case |
| `PrivateCloudComputeLanguageModel` | ✅ per `243:148` | session 243's own demo runs both instruction sets on PCC (`243:51`) |
| `MLXLanguageModel`, `CoreAILanguageModel` | ✅ per `243:148` | third-party `LanguageModel` conformers reach the framework through the same session API |
| `ChatCompletionsLanguageModel` (Ollama, vLLM, LM Studio, `mlx_lm.server`) | ✅ per `243:148` | see [Part 4 guide 02](../../part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md) |

This makes the instrument the **only** cross-backend profiler in the stack. If you are choosing between
the on-device model and PCC, or between Apple's model and an MLX-hosted one, you can trace the same user
journey against each and compare the same three metrics. That is a much better basis for a decision than
the alternative:

> ✅ **VERIFIED** — WWDC26 session 319 (`319:61-64`), on exactly this choice: *"When deciding between the
> on-device and PCC model, or deciding the reasoning level to use, it's good to make that decision **based
> on data, not just vibes**. … **You may be surprised how well the on-device model performs at certain
> tasks, especially with the updated model this year. But the only way to know is by evaluating.**"*

Latency comes from the instrument; quality comes from Evaluations. You want both columns.

> 🔴 **GAP — what a third-party `LanguageModel` actually populates.** `243:148` asserts support in
> general terms, but the session demos only Apple's own models. Whether an `MLXLanguageModel` or a
> `ChatCompletionsLanguageModel` fills in every lane and every token metric — cached input tokens, for
> instance, presupposes a KV cache the provider may not expose — is **unverified**, and no provider
> documentation we hold describes an instrumentation hook. **Resolving this needs a trace against a
> non-Apple backend on Xcode 27.** Safe default: expect the **structural** lanes (sessions, requests,
> inferences, instructions) to populate for any backend, and verify **per-token metrics** before you
> quote them for a third-party model.

### 5.4 The five words of Instruments vocabulary you need

Instruments is a general tool and its nouns are not obvious. Apple defines them at the top of the
walkthrough, and getting them straight makes the rest of this guide read cleanly:

> ✅ **VERIFIED** — `243:68-73`, verbatim: *"**The top section holds the tracks.** **Tracks show activity
> on the timeline, and each track can contain multiple lanes with charts that show levels or regions.**
> Below the timeline is **the detail view. It shows summary information about the range you're currently
> inspecting.** If you **click a bar in the timeline or a row in the detail view**, **the inspector opens
> up on the right** giving you a closer look at what you've selected."*

```
┌───────────────────────────────────────────────────────────┬──────────────┐
│  TRACKS  (top)                                            │              │
│   ├── lane 1  ▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇   regions / levels          │  INSPECTOR   │
│   ├── lane 2  ▇▇  ▇▇▇   ▇▇▇▇▇                              │  (right)     │
│   └── … 6 lanes total                                     │              │
├───────────────────────────────────────────────────────────┤  opens when  │
│  DETAIL VIEW  (below the timeline)                        │  you click a │
│   • summary for the inspected range                       │  bar or a    │
│   • TREE view: sessions ▸ requests ▸ model inferences ▸ …  │  row         │
└───────────────────────────────────────────────────────────┴──────────────┘
```

Two halves, and they answer different questions. **The timeline answers "when and how long".** **The
tree answers "what and why".**

> ✅ **VERIFIED** — `243:74-77`: *"**The Foundation Models Instrument has 6 lanes in the timeline.** These
> give you a quick overview of **session structure and latencies**. Alongside the timeline, there's a
> **tree detail view. That's where you can really dig into the model's chain of thought.**"*

> ✅ **VERIFIED** — `243:84`: *"**The timeline gives you a quick overview but the real power is in the
> tree view.**"*

Practical order of operations, which is exactly the order §8 follows: **skim the lanes for a shape that
looks wrong, then drop into the tree to find out why.**

---

## 6. Anatomy of a trace, part 1: the lanes

Six lanes. Two of them have names in Apple's narration. Four do not, anywhere in this project's corpus,
and this guide will not invent them.

### 6.1 The Instructions lane — the profile-switch visualiser

> ✅ **VERIFIED** — `243:78-79`, verbatim: *"**The Instructions lane shows how long a given set of
> instructions and tools was active. One set can cover multiple requests.**"*

Two words in that sentence carry the whole diagnostic value. **"and tools"** — an instruction set is not
just prose, it is prose *plus the toolset bound to it*, which is why the lane can catch a toolset bug at
all. And **"one set can cover multiple requests"** — the lane's regions are not per-request; they are per
*resolved instruction set*. That is what makes them a picture of your app's state machine.

Recall what `DynamicInstructions` and `DynamicProfile` actually do:

> ✅ **VERIFIED** — `243:8-9`: *"`DynamicInstructions` lets you specify exactly which instructions and
> tools the model can access. **It re-evaluates before every request**, so the model always has the right
> context for the task at hand."*

So the Instructions lane is a direct rendering of how your `body` resolved over time. **One region per
contiguous run of the same resolved instruction set.** Count the regions and compare against the number
of modes your feature is supposed to pass through. That comparison — a count, read off a timeline in two
seconds — is the entire diagnosis in §8:

> ✅ **VERIFIED** — `243:80`, verbatim: *"Looking at this lane, it's clear **only one set of instructions
> was active for the entire session** but the feature was supposed to use two, **so something went wrong
> during the handoff**."*

And after the fix:

> ✅ **VERIFIED** — `243:117-119`: *"**The Instructions lane now shows two distinct instructions active
> during this experience.** The first is a **brainstorming** instruction and the second is a **tutorial
> generation** instruction. That lines up exactly with the brainstorm experience design we covered
> earlier."*

**The heuristic to carry away: if your dynamic profile is supposed to switch and the Instructions lane
shows one unbroken region, the switch never happened.** No error will tell you this. The lane is the only
signal.

The converse is worth watching for too. **Too many regions is also a bug** — a different one. Every
change to the instruction set changes the token prefix, and that has a cost:

> ✅ **VERIFIED** — Apple's KV-caching article: *"**Switching from one profile to another typically
> changes the entire prefix — which invalidates the cache for the full transcript — so treat it as a
> deliberate reset.** Design your dynamic profiles so transitions between your profiles occur at natural
> boundaries in the conversation rather than on every turn."*

So an Instructions lane that flickers — a new region on every single request — means your `body` is
resolving to a different profile each turn, and you are paying a full re-prefill each time. See §10.

### 6.2 The Model Inference lane — yellow is prefill, orange is decode

> ✅ **VERIFIED** — `243:81-83`, verbatim: *"**The Model Inference lane has two types of bars: yellow and
> orange.** **Yellow bars represent how long the system spent processing the input prompt.** **Orange
> bars represent how long it took to generate the response.**"*

This is the fastest read in the entire trace, so commit it:

| Colour | Phase | What it is proportional to | How you shrink it |
|---|---|---|---|
| 🟨 **Yellow** | **prefill** — processing the input prompt | the number of input tokens the model has to read *that are not already cached* | shorten instructions, shrink the schema, drop tools you do not need, and above all **preserve the KV cache** so the prefix is not reprocessed |
| 🟧 **Orange** | **decode** — generating the response | the number of output tokens, times the per-token cost | ask for less output, cap with `maximumResponseTokens`, and **stream** so the user sees tokens as they arrive |

> 🟡 **RECONSTRUCTED — the words "prefill" and "decode".** Apple's narration says "processing the input
> prompt" and "generating the response"; it does not use the standard LLM vocabulary. The mapping is
> unambiguous and the terms are used throughout this series, but if you are quoting Apple, quote Apple.

The shape of the bars tells you which problem you have, before you read a single number:

- **Long yellow, short orange** → you are paying for input. This is a prompt-size or cache problem. Go to
  §9's Time to First Token and §10.
- **Short yellow, long orange** → you are paying for output. This is a "the model is writing an essay"
  problem: constrain the output type, cap the tokens, and stream.
- **Long yellow on *every* turn of a conversation** → your KV cache is being invalidated. §10.
- **A yellow bar with no orange after it** → the turn produced no generated text. Often that is a
  tool-call-only turn, which is legitimate and has its own UI hazard (§7.4).

✅ **VERIFIED** — the current runtime-performance page says each component's timeline width indicates
latency. That visual relationship is documented, not reconstructed. See the
[direct-page capture](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/notes/web/apple-foundation-models-runtime-performance-2026-09-22.md).

### 6.3 The six documented lanes

The current written documentation names and defines all six lanes:

| Lane | What the current page says it represents |
|---|---|
| **Session** | the interval in which a session is active |
| **Request** | the time required to perform a request within a session |
| **Instructions** | the instructions associated with the request |
| **Model Inference** | processing the input prompt and computing the response |
| **Tool** | when a tool call occurs and how long its work takes |
| **Model Loading** | loading model data from storage before fulfilling a request |

✅ **VERIFIED** — all six names and meanings come from Apple's current runtime-performance page,
preserved with provenance in the
[2026-09-22 evidence note](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/notes/web/apple-foundation-models-runtime-performance-2026-09-22.md).
Session 243 only narrates Instructions and Model Inference, so use the written page — not guesses from
the tree hierarchy — for the other four names.

---

## 7. Anatomy of a trace, part 2: the tree detail view

### 7.1 The hierarchy

> ✅ **VERIFIED** — `243:85`, verbatim: *"It takes everything logged during this recording and
> **organizes it into a hierarchy: sessions, requests, model inferences, instructions, prompts, and
> responses.**"*

```
Session                                   ← "Session 1 had two requests"      (243:87)
└── Request                               ← one user-visible ask
    └── Model Inference                   ← MULTIPLE per request              (243:89)
        ├── Instructions                  ← the resolved instruction set + its tools (243:96)
        ├── Prompt                        ←                                    (243:95)
        ├── Response  |  Error            ← exactly one of these               (243:90)
        └── Tool Call(s)                  ← "and a few tool calls"             (243:89)
```

> 🟡 **RECONSTRUCTED — the indentation.** Apple lists the six node kinds in a sentence; the nesting above
> is inferred from the narration ("Session 1 had two requests"; "that request was made up of two model
> inferences and a few tool calls"; "every model inference should have instructions, a prompt, and either
> a response or an error"). The *levels* are Apple's; the *drawing* is ours. If you need certainty, open
> a trace and expand it.

### 7.2 The invariant to check first

> ✅ **VERIFIED** — `243:90`, verbatim: *"**Every model inference should have instructions, a prompt, and
> either a response or an error.**"*

That sentence is a checklist, and it is the first thing to run down when a trace looks strange. An
inference missing its instructions node, or carrying neither a response nor an error, is a structural
anomaly — and structural anomalies in this framework are usually your app's fault rather than the
instrument's.

### 7.3 One request is not one inference

> ✅ **VERIFIED** — `243:87-89`, verbatim: *"**Session 1 had two requests.** The first one was kicked off
> by the prompt starting with **'Please generate 3 craft ideas.'** That request was made up of **two model
> inferences and a few tool calls**."*

One `respond(to:)` → N inferences, where N is the number of trips round the tool-calling loop plus the
final answer. Three consequences you will feel:

**Latency multiplies.** Total Latency (§9) is the sum over the loop, including the wall-clock time your
own `call(arguments:)` implementations spend. A slow tool is a slow feature, and the instrument shows
tool execution duration explicitly (§9.2).

**Tokens multiply.** Each iteration re-sends the prefix. If the cache is working, most of that is cached;
if it is not, you are paying for the whole transcript N times per user request.

**"It hung" is usually "the loop did not stop".** With `toolCallingMode(.required)` the loop has no
natural exit — Apple's own words:

> ✅ **VERIFIED** — WWDC26 session 242 (`242:149-150`): *"Here's the most important thing to remember.
> **When tool calling is required, the model is essentially in a while loop — it is your job to ensure
> that there is an exit condition of some kind.**"*

In the tree, that failure has an unmistakable signature: **a single request with an implausible number of
model inference children, each with a tool call and no final response.** Count the children; that is your
loop counter.

### 7.4 The inspector

> ✅ **VERIFIED** — `243:91-93`, verbatim: *"**Click any node in the tree to pull it up in the
> inspector.** The model inference detail shows a **summary of the instructions, prompt, and response
> that made up this call.** **Scroll down and you'll find duration visualizations and token usage
> metrics.**"*

So a **Model Inference** node's inspector has three regions:

1. **Summary** — instructions, prompt, response as text. This is where "what did the model actually see"
   gets answered, and it is the reason the trace file is sensitive (§5.2).
2. **Duration visualisations.**
3. **Metrics** — token usage. *"The metrics and duration sections break down token usage for this
   inference. **These numbers are your starting point for understanding and improving the efficiency of
   an experience.**"* (✅ `243:129-130`.)

An **Instructions** node's inspector is different, and it is the one that catches §8's bug:

> ✅ **VERIFIED** — `243:96-97`, verbatim: *"Let's select the **Instructions node** to see how they're set
> up. **The inspector shows that this instruction only had one tool associated with it.**"*

**The Instructions inspector enumerates the tools bound to that instruction set.** That is the only place
in the entire toolchain where the instruction *prose* and the declared *toolset* are displayed side by
side. Nothing in the compiler, the framework, or the runtime cross-checks them. Instruments does, visually,
if you look.

✅ **VERIFIED** — the current runtime-performance page says the request inspector shows instructions,
prompt, response, duration, and token metrics. For custom tools, it documents where and how the model
invokes them, how long each invocation takes, and its output. It does **not** promise that tool-call
arguments are visible, so do not build a debugging procedure that depends on that field. See the
[2026-09-22 evidence note](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/notes/web/apple-foundation-models-runtime-performance-2026-09-22.md).

### 7.5 The Info column is your triage filter

> ✅ **VERIFIED** — `243:127`, verbatim: *"**The info column is a great way to quickly flag nodes worth a
> closer look: things like errors, long durations, and large token counts.**"*

Three flag categories, three different investigations:

| Flag | Likely cause | Where to go next |
|---|---|---|
| **Error** | a tool threw; a guardrail fired; context overflowed | [Part 2 guide 06](../../part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md); check whether the transcript rolled back (`transcriptErrorHandlingPolicy`) |
| **Long duration** | big prefill, slow tool, or cold assets | §9 — split it into TTFT vs decode using the lane colours |
| **Large token count** | instructions/schema/tool-definition bloat | §9.2, and Apple's prompt-shortening rules |

Work the Info column top-down before you read anything else in the tree. It is the closest thing this
instrument has to a linter, and it is how the presenter finds the slow inference: *"Request 1's first
model inference took a bit longer than I was expecting, so let's take a look."* (✅ `243:128`.)

---

## 8. ⚠️ The canonical worked bug: a tool named in prose, missing from the toolset

Apple built an entire WWDC session around one bug. It is worth understanding why *this* one: it is the
purest example in the whole framework of a defect that produces a completely wrong user experience while
every layer of the system reports success.

### 8.1 The feature

> ✅ **VERIFIED** — `243:45-51`, verbatim: *"I'm working on a **crafting companion app** where you can keep
> a **journal of your craft projects**. The app lets you record craft progress, ask questions about
> specific crafts, and generate tutorials. Recently, I had an idea for an **interactive brainstorming
> feature** that gives people suggestions on what to craft. The crafter can speak with the model to refine
> its ideas and **when they're ready to commit, the app generates a detailed tutorial for that craft**.
> **This feature uses two sets of instructions**: one for **brainstorming ideas**, and a second for
> **tutorial generation**. The brainstorming instructions include **two tools: a `GenerateCraftIdeaTool`
> and a `SwitchToTutorialModeTool`**. **Both sets of instructions use the server model on Private Cloud
> Compute**, one for quick idea generation and the other to generate more detailed tutorials."*

Architecturally this is a **baton-pass**: two profiles, a variable that selects between them, and a tool
the model calls to flip that variable. (Session 242's taxonomy; see
[Part 3 guide 04](../../part-03-context-profiles-agentic/references/04-agentic-orchestration.md).)

> ⚠️ **Naming caution.** The captions render the idea tool three ways — `GenerateCraftIdeaTool`
> (`243:50`), `GenerateCraftIdeasTool` (`243:106`), and `generateCraftIdea` (`243:121`). The switching
> tool is consistent: type `SwitchToTutorialModeTool`, tool name `switchToTutorialMode`. **The exact
> spelling of the idea tool is UNVERIFIED**, and it does not matter for the lesson — but do not copy it
> as gospel.

### 8.2 The symptom

> ✅ **VERIFIED** — `243:60-66`: the app suggests *Yarn PomPom, Fabric Pouch, Paper Butterfly*. The
> presenter picks Paper Butterfly. *"**Hm. That's not right. The model was supposed to kick off a tutorial
> but instead it just offered more ideas.** Something's off."*

Note what the symptom is **not**. There is no crash, no error alert, no spinner that never stops, no
console message. The app produces fluent, on-topic, entirely plausible output — of the wrong kind. If you
were not watching for the mode switch you might not notice for a week.

### 8.3 The diagnosis, in four clicks

**Click 1 — the Instructions lane.** One unbroken region where two were expected.

> ✅ **VERIFIED** — `243:80`: *"it's clear **only one set of instructions was active for the entire
> session** but the feature was supposed to use two, **so something went wrong during the handoff**."*

**Click 2 — the model inference node.** Confirms which prompt was bound to those instructions.

> ✅ **VERIFIED** — `243:95`: *"the timeline already told us the instruction set never changed, and here in
> the inspector for this model inference node, I can see the prompt tied to those instructions."*

**Click 3 — the Instructions node.** The tool list.

> ✅ **VERIFIED** — `243:96-97`: *"Let's select the Instructions node to see how they're set up. **The
> inspector shows that this instruction only had one tool associated with it.**"*

**Click 4 — the money quote.**

> ✅ **VERIFIED** — `243:98-99`, verbatim: *"**The prompt references the `switchToTutorialMode` tool but
> that tool isn't actually configured with this instruction.** **Without it, the app has no way to switch
> from brainstorm mode to tutorial mode, so the crafter gets stuck in a loop.**"*

Four clicks, no code read, no logging added. That is the case for the instrument in one paragraph.

### 8.4 ⚠️ Why this class of bug is the worst kind

> ⚠️ **SILENT FAILURE — the model kept working, and working, and nothing threw.**
>
> ✅ **VERIFIED** — `243:100-103`, verbatim: *"Looking at the subsequent nodes in the tree, **this was a
> silent failure. The model kept accepting input and making tool calls but never threw an error. There
> was no clear signal that anything had gone wrong. That makes it a hard bug to catch.**"*
>
> Trace the layers and note that **every one of them is behaving correctly**:
>
> | Layer | What it saw | What it did |
> |---|---|---|
> | Swift compiler | an `Instructions` string literal and a list of `Tool` values | compiled both. It cannot read English. |
> | `DynamicInstructions` builder | prose + one tool | assembled them. It does not parse the prose. |
> | Framework | a valid toolset, a valid prompt | ran the loop. Nothing invalid was requested. |
> | Model | instructions that mention a tool it was never offered | did the next best thing: generated more ideas. |
> | Your app | a well-formed response | rendered it. |
>
> **There is no layer whose job it is to notice.** The instruction text is data; the toolset is code;
> nothing in the toolchain relates them. This is the same structural hole as `Tool.name` drifting away
> from the name in your prompt (see
> [Part 2 guide 03 §8](../../part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md)),
> and the same hole as `Tool.parameters` being computed once at session init and never re-read. **The
> family resemblance is: two artefacts that must agree, and no mechanism that makes them.**

The user-facing failure is worse than a crash, because a crash is honest. Here the model *invents a
coping strategy* — it cannot switch modes, so it keeps brainstorming — and the coping strategy looks like
a feature.

### 8.5 The fix

> ✅ **VERIFIED** — `243:105-106`, verbatim: *"Based on what I found in Instruments, I'll look at the
> **`BrainstormDynamicInstructions`** definition. **In the `Instructions` block, the
> `SwitchToTutorialMode` tool is mentioned in the prompt but only the `GenerateCraftIdeasTool` is listed
> in the toolset, so let's add it.**"*

> 🟡 **RECONSTRUCTED — the before/after code below.** Apple describes the edit; no code was shown on
> screen in a form we could read, and the instruction prose was never dictated. **The structure is
> verified by Apple's shipping Origami sample** (quoted immediately after), which uses exactly this
> `Instructions(…)`-then-tool-instances layout. The *strings* are ours.

```swift prelude:guide-context
import Foundation
import FoundationModels

// ───────────────────────────── BEFORE (the bug) ─────────────────────────────
struct BrainstormDynamicInstructions: DynamicInstructions {
    var body: some DynamicInstructions {
        Instructions(
            """
            Help the person brainstorm craft ideas from what they tell you.
            When they choose one and are ready to start, call the \
            switchToTutorialMode tool with the craft they picked.
            """                                   // ← names the tool in PROSE …
        )

        GenerateCraftIdeasTool()                  // ← … but only ONE tool is bound.
    }                                             //    Compiles. Runs. Loops forever.
}

// ────────────────────────────── AFTER (the fix) ──────────────────────────────
struct BrainstormDynamicInstructions: DynamicInstructions {
    let orchestrator: Orchestrator

    var body: some DynamicInstructions {
        Instructions(
            """
            Help the person brainstorm craft ideas from what they tell you.
            When they choose one and are ready to start, call the \
            switchToTutorialMode tool with the craft they picked.
            """
        )

        GenerateCraftIdeasTool()
        SwitchToTutorialModeTool(orchestrator: orchestrator)   // ← the whole fix
    }
}
```

That the shape is right — an `Instructions` value and bare `Tool` instances side by side in one
`DynamicInstructions` body — is not a reconstruction. Apple ships it:

> ✅ **VERIFIED** — Origami sample, `Origami/Tutorial/Intelligence/OrigamiInstructions.swift:11-31`,
> verbatim from the downloaded archive:
>
> ```swift
> struct OrigamiInstructions: DynamicInstructions {
>     var body: some DynamicInstructions {
>         Instructions(
>             """
>             To generate an origami tutorial, always call the \
>             fetchOrigamiTemplate tool first and base your tutorial \
>             on the project template retrieved by that tool.
>
>             Next when generating a tutorial:
>             - Try to use standard Origami terminology
>             …
>             """
>         )
>
>         // Fetch the templates tool.
>         FetchOrigamiTemplate()
>     }
> }
> ```
>
> …and the tool it names declares that exact string
> (`Origami/Tutorial/Intelligence/CraftTools.swift:12-14`):
>
> ```swift
> struct FetchOrigamiTemplate: Tool {
>     let description = "Fetch a relevant starting origami template to adapt into a tutorial."
>     let name = "fetchOrigamiTemplate"
>     …
> ```

Look at what Apple's shipping code is doing there, because it is the discipline that prevents §8's bug:
**the prose says `fetchOrigamiTemplate`, the tool declares `let name = "fetchOrigamiTemplate"`, and the
tool instance sits eleven lines below the sentence that names it.** One screen, three facts, all three
visible at once.

The same pattern again, with three tools:

> ✅ **VERIFIED** — `Origami/Coach/CoachInstructions.swift:15-35`, verbatim (abbreviated in the middle):
>
> ```swift
> var body: some DynamicInstructions {
>     Instructions {
>         """
>         You are an expert craft tutorial coach.
>         …
>         To move a photo to the correct step. \
>         call the movePhotoToStep tool.
>         """
>     }
>
>     CalculatePaperSize()
>     ConvertMeasurement()
>     MovePhotoToStepTool(orchestrator: orchestrator)
> }
> ```
>
> Note the selection rule Apple follows, which is the same one that defuses this bug: **the tool named in
> the prose (`movePhotoToStep`) declares an explicit `name`; the two tools nobody mentions
> (`CalculatePaperSize`, `ConvertMeasurement`) omit `name` entirely and take the derived default.** If
> your instructions name a tool, declare the name explicitly — you cannot match a string you have never
> seen.

### 8.6 The re-trace: what "fixed" looks like

Do not stop at "it worked when I tried it". Apple re-records, and the verification is as precise as the
diagnosis:

> ✅ **VERIFIED** — `243:107-126`. After the fix the app switches to tutorial mode for a *necklace*, and
> the trace shows:
>
> - **`243:117-118`** — *"**The Instructions lane now shows two distinct instructions active during this
>   experience.** The first is a brainstorming instruction and the second is a tutorial generation
>   instruction."*
> - **`243:121-123`** — *"**The first set of instructions now includes both the `generateCraftIdea` and
>   `switchToTutorialMode` tools. That confirms the model had everything it needed to make the switch. The
>   fix worked.**"*
> - **`243:124-126`** — *"**The instruction change happened after the second model inference of Request
>   2.** That inference resulted in a **tool call to `switchToTutorialMode`, passing the selected craft as
>   an argument**. And **in the following request, the instructions correctly switched over to the tutorial
>   generator, with the selected craft passed along as context.**"*

That last bullet contains a timing fact that is easy to get wrong and expensive to get wrong:

> ✅ **The instruction switch takes effect on the *next request*, not mid-request.** The tool call
> happened in Request 2's second inference; the new instructions appear in Request 3. This is consistent
> with the documented re-evaluation point — *"the body of a `DynamicProfile` is re-evaluated **each time
> the model is prompted**"* (✅ WWDC26 session 242, `242:59`) — and it means **a baton-pass costs you a
> turn**. The receiving profile does not answer the prompt that triggered the switch; it answers the next
> one. Design your UI for that: the tool's return string is what the user sees in between, which is why
> session 242 calls a tool output *"a signal of a successful handoff"* (`242:127`).

So the three-part verification for any profile-switching feature:

1. **Region count** in the Instructions lane matches the number of modes you expected.
2. **The Instructions node inspector for each region lists exactly the tools you meant to bind.**
3. **The switch lands where you expect in the request sequence** — one request *after* the tool call.

### 8.7 Preventing it, since the compiler will not

The instrument catches this after the fact. Three things reduce how often you need it to.

**One source of truth for tool names.** The string in your prose and the string in `Tool.name` are two
independent pieces of text and nothing checks them:

```swift prelude:guide-context
enum ToolNames {
    static let switchToTutorialMode = "switchToTutorialMode"
    static let generateCraftIdeas   = "generateCraftIdeas"
}

struct SwitchToTutorialModeTool: Tool {
    let name = ToolNames.switchToTutorialMode
    let description = "Switch the app into tutorial mode for the craft the person picked."
    // …
}

struct BrainstormDynamicInstructions: DynamicInstructions {
    let orchestrator: Orchestrator

    var body: some DynamicInstructions {
        Instructions(
            """
            Help the person brainstorm craft ideas.
            When they pick one, call the \(ToolNames.switchToTutorialMode) tool.
            """
        )
        GenerateCraftIdeasTool()
        SwitchToTutorialModeTool(orchestrator: orchestrator)
    }
}
```

This stops the *name* drifting. It does **not** stop you forgetting to register the tool — interpolating
`ToolNames.switchToTutorialMode` into the prose compiles perfectly well with no `SwitchToTutorialModeTool()`
anywhere. That is the residual hole, and it is exactly the bug in §8.

**A test that closes the residual hole.** Because a session's tool definitions live inside the
`.instructions` transcript entry, you can assert on them. Build the session, ask it one trivial question
so the transcript materialises, and check that every name you interpolate into the prose appears in the
toolset:

```swift prelude:guide-context
import Testing
import FoundationModels

@Test
func everyToolNamedInInstructionsIsRegistered() async throws {
    let session = LanguageModelSession(profile: OrchestratorProfile(orchestrator: .init()))
    _ = try await session.respond(to: "hello")

    // Collect the tool names the model was actually offered.
    var registered = Set<String>()
    var prose = ""
    for entry in session.transcript {
        guard case let .instructions(instructions) = entry else { continue }
        for definition in instructions.toolDefinitions {
            registered.insert(definition.name)
        }
        for segment in instructions.segments {
            if case let .text(text) = segment { prose += text.content }
        }
    }

    for name in [ToolNames.switchToTutorialMode, ToolNames.generateCraftIdeas]
    where prose.contains(name) {
        #expect(registered.contains(name), "Instructions mention \(name) but it is not registered")
    }
}
```

> 🟡 **RECONSTRUCTED — the member accesses in that test.** `Transcript.Entry.instructions(_:)` and
> `Transcript.Instructions.init(id:segments:toolDefinitions:)` are ✅ verified from the FoundationModels
> documentation, as is `Transcript.ToolDefinition.name`; **`instructions.toolDefinitions` and
> `instructions.segments` as readable properties are inferred from those initialiser labels** and were
> not read from a signature. If they do not resolve, print one `.instructions` entry and adjust — the
> shape of the check is the point, and the fallback is trivial:
> `String(data: try JSONEncoder().encode(session.transcript), encoding: .utf8)!.contains(name)`,
> since `Transcript` is ✅ `Encodable`.

**Put the prose and the tools in the same `body`.** The strongest prevention is layout, and it is free.
Apple's samples never separate an instruction sentence from the tool it names by more than a few lines.
A `DynamicInstructions` type whose prose lives in one file and whose tools are appended somewhere else is
a bug waiting for a WWDC session.

---

## 9. Duration and token metrics

### 9.1 The three from the session

> ✅ **VERIFIED** — `243:131`: *"**You can measure performance using three key metrics.**"* All three
> definitions and fixes below are verbatim from `243:132-139`.

| Metric | Definition | Why it matters | The fix Apple names |
|---|---|---|---|
| **Time to First Token** | *"measures **how long it takes for the model to begin generating a response after receiving a prompt**"* | *"**A high Time to First Token means people are staring at a blank screen.**"* | *"**To reduce it, shorten your prompt.**"* |
| **Tokens per Second** | *"measures **overall generation speed of the response**"* | — | *"**Use it to benchmark performance across different prompt configurations and catch regressions after changes.**"* |
| **Total Latency** | *"**the complete time from sending the request to receiving the final response**"* | *"**This is the number people feel most directly.**"* | *"**To reduce perceived Total Latency, utilize streaming to surface partial results sooner.**"* |

Three notes on how to actually use them, because the definitions understate the differences.

**Time to First Token is the yellow bar.** It is prefill, and prefill is proportional to the number of
*uncached* input tokens. "Shorten your prompt" is Apple's headline advice and it is correct, but it is
the second-best lever — the best one is not re-sending the prefix at all. Apple's own written guidance on
shortening, verbatim from *Managing the context window*:

> ✅ **VERIFIED** —
> - *"Use imperative verbs that clearly state what you want the model to do: 'Generate a story about…,'
>   or 'List five reasons why…'."*
> - *"Provide only the information the model needs for the specific task."*
> - *"Avoid lengthy background information, policies, or unnecessary context."*
> - ***"Reduce prompts to no more than three paragraphs in length."***
> - *"Eliminate indirect language, excessive formality, and ambiguous jargon."*

Two more TTFT levers that are not "shorten the prompt" at all:

- **`prewarm(promptPrefix:)`**, which moves asset loading out of the critical path. In the code-along's
  trace this was worth roughly **700 ms** of dead time before the first token, moved to before the
  session even started (✅ `205:891`, `205:979-983`; Apple-published, Xcode 26 era, hardware unstated).
  A retired article summary said the instrument reveals whether prewarming completed before the
  first request. The captured current page does not establish a dedicated completion indicator, so
  that specific UI claim remains 🟡 **RECONSTRUCTED**.
- **`includeSchemaInPrompt: false`**, when — and only when — a fully-populated example of the `@Generable`
  type is already in your instructions. *"Excluding the schema removes redundant schema information and
  **can save hundreds of tokens per request**."* (✅ Apple's *Analyzing the runtime performance…*
  article, preserved in the
  [2026-09-22 evidence note](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/notes/web/apple-foundation-models-runtime-performance-2026-09-22.md).)
  In the code-along this took max token count from **1,044 → 700** (✅ `205:897`, `205:985`;
  Apple-published). ⚠️ Turning it off *without* a one-shot example in the instructions is a footgun —
  the model then has neither the schema nor an example to pattern-match against.

**Tokens per Second is a regression detector, not a target.** Apple's own framing is about *benchmarking
across configurations* and *catching regressions after changes*. That is the right use: record it for
your top three journeys, write the numbers down with the OS build and the device, and re-measure after
every prompt edit and every OS update. It is not a number you optimise directly — it is mostly the
device's property, not yours.

That matters more here than in most stacks, because **the model changes underneath you and there is no
pinning API**:

> ✅ **VERIFIED** — Apple's *Foundation Models updates* page, "February 2026": *"Use the latest on-device
> large language model that improves instruction-following and tool-calling abilities. **Because the model
> changes when a person updates to iOS 26.4** … test your prompts with the new model"*, and the same
> warning again for 27: *"**Because the model changes when a person updates to iOS 27** … test your
> prompts with the new model to verify your app's behavior."*

So a tokens-per-second baseline taken on 26.3 tells you nothing about 26.4, and a *quality* baseline
taken on 26.3 tells you even less. This is exactly why Part 6 exists.

**Total Latency is the only one users experience, and streaming does not reduce it.** Read Apple's wording
precisely: *"to reduce **perceived** Total Latency, utilize streaming."* The wall-clock number does not
move. What moves is the moment the user stops looking at nothing. Combine with:

> ⚠️ **SILENT FAILURE — a streamed turn can yield zero partials.** If the model's entire contribution to
> a turn is a tool call, `streamResponse(to:)` completes **without ever yielding a partial**. Nothing
> throws; the sequence simply ends. Any UI that keeps a spinner up until the first partial arrives hangs
> there forever — and in the tree view this turn looks perfectly healthy: an inference, a tool call, no
> response text.
>
> ✅ **VERIFIED** — Apple's Origami sample handles it explicitly (`Origami/Coach/CoachModel.swift:58-73`):
> it tracks `var didReceivePartial = false`, and if the stream ends without one, lands on
> `.responded("")` so the UI exits its loading state. **Drive loading state off stream *completion*,
> never off first-token arrival.** Full treatment in
> [Part 2 guide 02](../../part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md).

### 9.2 The four current token metrics

Session 243 says the inspector shows token-usage metrics without naming them. The current written
runtime-performance page does name the four metrics:

- **Total Tokens** — consumed input plus generated output tokens.
- **Consumed Tokens** — prompt, instructions, transcript, and other prompt metadata such as tool
  definitions.
- **Generated Tokens** — model output tokens.
- **Cached Tokens** — input tokens reused from a previous request.

✅ **VERIFIED** — these names and meanings come from Apple's direct Markdown response captured on
2026-09-22. The page describes cache hit rate as the percentage of input tokens served from the prefix
cache; the companion KV-caching page supplies the calculation: **cached input tokens ÷ total input
tokens**. A low rate between turns signals cache invalidation and full-prefix reprocessing. See the
[preserved evidence](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/notes/web/apple-foundation-models-runtime-performance-2026-09-22.md).

⚠️ **Keep the source distinction visible.** Session 242 points to session 243 for cache-invalidation
measurement (`242:177`), but session 243 never says "cache hit rate". That does not make the metric
unsupported: it lives in Apple's current written documentation. Reasoning-token usage is available in
the iOS 27 programmatic `Usage` API (§9.3), but it is **not** one of these four documented instrument
metrics.

The same current page verifies that the instrument shows where and how tools run, plus each tool's
duration and output. That duration is worth using: in a `.required`-mode agent, your own Swift code is
inside the latency budget N times per user request. A tool that does a 300 ms network round-trip and is
called four times contributes 1.2 seconds of latency that has nothing to do with model inference.

### 9.3 The programmatic equivalents

The instrument is for development. For production telemetry and for tests, the same numbers are available
in code — new in 27.

> ✅ **VERIFIED** — WWDC26 session 241, verbatim (`241:55-56`): *"**Sessions and responses now have a
> `usage` property that tells you precisely how many tokens were used.** You can also check **how many of
> the input tokens were read from cache**, and **how many of the response tokens were used for
> reasoning**."*

> ✅ **VERIFIED** — from the FoundationModels symbol index: `LanguageModelSession.Usage` is a struct with
> nested `Usage.Input` and `Usage.Output` types (all **iOS 27.0+ Beta**); `session.usage` exists, and
> `Response` and `ResponseStream.Snapshot` each carry a `.usage` property.

> 🔴 **GAP — the member names inside `Usage`, `Usage.Input` and `Usage.Output`.** We have the type names
> from an index listing and Apple's spoken description of what they contain ("how many of the input tokens
> were read from cache", "how many of the response tokens were used for reasoning"), but **no property
> spellings**. We will not guess at `cachedTokenCount` versus `cached` versus `fromCache`. Resolving this
> needs `/documentation/foundationmodels/languagemodelsession/usage` or a generated Swift interface from
> the 27.0 SDK. **Safe default meanwhile: read `session.usage` in the debugger or dump it with
> `String(describing:)` once, write down what you find, and code against that.** The cache-hit ratio you
> want is the cached-input count divided by the total-input count, whatever those two members turn out to
> be called.

For 26.4 and later, two cheaper measurements that need no 27 API at all:

> ✅ **VERIFIED** — both **26.4+**: `SystemLanguageModel.tokenCount(for:)` ("Measure how many tokens your
> prompt, instructions, or entire session transcript uses") and `SystemLanguageModel.contextSize` ("get
> the maximum context size — in tokens — that the `SystemLanguageModel` supports"), the latter carrying
> `@backDeployed(before: iOS 26.4, macOS 26.4, visionOS 26.4)`.

A defensive read, from shipping community code:

```swift compile:27 imports:FoundationModels
// contextSize is available in the 26.4+ SDK; treat <= 0 as "unknown".
let reported = SystemLanguageModel.default.contextSize
let contextSize = reported > 0 ? reported : 4096
```

> ✅ **VERIFIED** — community-measured pattern from a shipping third-party client
> (`AFMLLMClient.swift:134-135`), attributed as community practice, not Apple guidance. The `4096`
> fallback is Apple's documented on-device figure.

---

## 10. Detecting KV-cache invalidation

This is the connective tissue between this guide and
[Part 3 guide 01](../../part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md),
and Apple makes the connection explicitly.

> ✅ **VERIFIED** — WWDC26 session 242, verbatim (`242:170-177`): *"Generally, **appending to the
> transcript preserves the KV cache, and minimizes the time-to-first-token**. If you **rewrite history by
> removing entries, changing the attached tools, or updating the instructions**, that will **typically
> trigger a cache invalidation, and can increase latency**. … Now, we **didn't talk about this last year**
> because we **intentionally shaped `LanguageModelSession` APIs to be append only**. By default, they
> ensured optimal use. But **this year, we're taking the training wheels off**, so to say. **It's
> important to understand that different models have different caching behavior and the only way to be
> certain is by measuring. The best way to do that is the upgraded Foundation Models Instrument in Xcode.
> For more about detecting cache invalidations with Instruments, make sure to check out our video on
> debugging and profiling.**"*

That is 242 handing the problem to 243 — which, as noted in §9.2, does not pick it up by name. Apple's
current KV-caching page now supplies the numeric procedure directly.

### 10.1 The read

**In the timeline.** Yellow bars are prefill. In a healthy multi-turn conversation, turn 1 has a long
yellow bar and every subsequent turn has a **short** one, because the shared prefix is cached and only
the new tokens are processed. **A long yellow bar on every turn is the signature of an invalidated
cache.**

**In the inspector.** Open a model-inference node from turn *n* and compute
`cached input tokens ÷ total input tokens` (§9.2). Apple's current KV-caching page says a low rate
between turns signals cache invalidation and full-prefix reprocessing (✅
[direct-page capture](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/notes/web/apple-foundation-models-runtime-performance-2026-09-22.md)).
A near-zero rate on a turn that should have inherited a large prefix means something changed in the
prefix.

**In the Instructions lane.** A new region means a new instruction set means a new prefix. If regions
appear more often than your feature actually changes mode, you have found your invalidator without
reading a single number.

### 10.2 What invalidates it, in blast-radius order

> ✅ **VERIFIED** — Apple's *Optimizing key-value caching in language model sessions* article:
> *"A session typically arranges its content into a token sequence with a specific order, like
> **instructions appearing at the top, tool definitions coming next, and then transcript entries follow at
> the end**. Each cached value in the sequence depends on every token that precedes it… **A change to the
> instructions, for example, invalidates the cache for the tool definitions and the entire transcript.** A
> change **deep in the transcript**, by contrast, only invalidates the values that follow it."*

| Change | Blast radius | Shows up as |
|---|---|---|
| Instructions text edited | **everything** — tool definitions and the whole transcript | new Instructions-lane region + long yellow bar |
| Tool added or removed | tool definitions + whole transcript | new Instructions-lane region + long yellow bar |
| Profile switched | *"typically changes the entire prefix"* — treat as a full reset | new Instructions-lane region |
| Entry removed from the middle of history | everything after it | long yellow bar, same instruction region |
| Entry removed from the **end** of history | least expensive of the rewrites | modest yellow bar |
| Content replaced **in place**, same token count | can preserve the cache | no change — this is the goal |
| Appending a turn | nothing invalidated | short yellow bar |

> ✅ **VERIFIED** — the last three rows, from the same article: *"A **stateless** transform that **drops**
> entries, like truncating to recent history, **invalidates parts of the cache** for the entries it
> removes. However, a transform that **replaces content in-place**, like removing debug metadata, **can
> preserve cache consistency** because the model sees the same token sequence each time."* And:
> *"**Defer removing entries from the transcript until the context window is nearly full, then consolidate
> the context in a single operation rather than trimming incrementally after each turn.** Frequent small
> edits to the middle of the transcript force repeated cache invalidations."*

### 10.3 The measurement loop

1. Run the journey twice in one trace: turn 1, turn 2, turn 3 of the same conversation.
2. Compare the yellow bars. Expect turn 1 ≫ turns 2–3.
3. If they are all long, open turn 2's inference inspector and check the cached-input ratio.
4. If the ratio is near zero, look at the Instructions lane: did a region boundary land there?
   - **Yes** → your `body` resolved to a different profile. Move the transition to a natural boundary, or
     stop conditioning on something that changes every turn.
   - **No** → you are rewriting history. Look at your `historyTransform` (does it *drop* entries, or
     *replace* them in place?) and at anything assigning to `@SessionProperty(\.history)`.
5. Re-trace and confirm the ratio moved.

⚠️ **One structural caution before you invest in prefix reuse.** Community measurements on third-party
backends show prefix reuse is worth roughly **101×** on turn-2 TTFT at 4k context (**23.28 s → 0.230 s**,
byte-identical greedy output; 15.2× at 357 tokens; qwen3-0.6b on Mac — community-measured, not Apple, and
against a non-Apple executor). **But the same source finds that KV trimming is unsupported whenever a
model carries non-positional recurrent state** — linear-attention and hybrid architectures forfeit prefix
caching entirely and must re-prefill every turn. If you are profiling a bring-your-own-model backend and
the cache hit rate is stubbornly zero, the architecture may simply not support it. See
[Part 4 guide 04](../../part-04-beyond-the-built-in-model/references/04-executor-lifecycle-and-kv-reuse.md).

### 10.4 And the accuracy half, which no metric will show you

Cache invalidation costs latency. Rewriting history costs *correctness*, and the instrument cannot see
that at all.

> ✅ **VERIFIED** — Apple's KV-caching article: *"there's no reliable way for the model to distinguish
> between information that never existed and information that did exist but was removed from the context.
> A model treats whatever's in the context as the complete picture and **reasons confidently from
> incomplete evidence**."*

> ✅ **VERIFIED** — session 242's worked example (`242:179-184`): ask the model for project names, let it
> answer without a tool, *then* add a title-generating tool and ask again — *"it's also possible that the
> model will notice it previously generated titles without the tool, and may think it's supposed to do
> that again. That's not what we want. **Our history modification confused the model.**"*

Which is why 242 ends where it does:

> ✅ **VERIFIED** — `242:185-187`: *"When you start to get into **nuanced transcript modifications** like
> this, it becomes **even more important to use the Evaluations framework to create eval sets and quantify
> the effect of context engineering strategies**. **Data driven optimization is the only way to be
> confident.**"*

**The instrument tells you what it cost. Evaluations tell you what it broke.** You need both, and they
are not substitutes.

---

## 11. What changed between the 2025 and 2026 instrument

There was a Foundation Models instrument in Xcode 26. It was a different, much thinner thing, and if your
mental model came from last year's code-along you will be looking for the wrong UI.

> ✅ **VERIFIED** — the 2025 workflow, from the code-along (`205:869-875`): *"**If you long press on the run
> button** here, you'll see a few different options. You see run, test, profile and analyze. So I'm going
> to click **profile**. What this does is it'll build the app and then launch up Xcode instruments. …
> **We'll choose the blank template** and then once you have your instruments open, I'm going click on
> **this plus symbol here and search for foundation models.**"*

> ✅ **VERIFIED** — the 2025 tracks, verbatim (`205:886-891`):
> - **Response** — *"**The blue bar here represents entire session.** So this is ever since the user clicks
>   on generate itinerary, we create a session and the model takes in the instructions, prompts and
>   generates output."*
> - **Asset loading** — *"once the session starts, there is a little bit of a delay and then the models are
>   loaded here, the model assets, which means all this time from the start of the session all the way to
>   end of loading the model, **the model is not generating any responses** and roughly looks like this is
>   about **700 milliseconds, which is almost a full second**"*
> - a third track — *"**this is where you see that the first token is generated**, which means it waits for
>   all the models to be loaded and then it starts the token generation process, starting with the first
>   token"*
>
> …and one detail pane: *"I'm going to choose the **inference** section here… you will see here that there
> is **max token count**. And we see here that this currently amounts to **1044**. And **this token count
> includes everything we've added into the session. This includes your instructions, your prompts, your
> tools. It includes the generables with the itinerary, all of it.**"* (`205:895-901`)

Side by side:

| | **Xcode 26 instrument** | **Xcode 27 instrument** |
|---|---|---|
| How you reach it | Blank template, then `+`, then search "foundation models" | its **own template** in the chooser |
| Timeline | 3 tracks (Response / Asset loading / first token) | **6 lanes**: Session, Request, Instructions, Model Inference, Tool, Model Loading |
| Prefill vs decode | not distinguished | **yellow vs orange bars** |
| Structure | one blue bar per session | **tree**: sessions ▸ requests ▸ model inferences ▸ instructions / prompts / responses |
| Text of prompts and responses | not surfaced | **surfaced in the inspector** — hence the privacy dialog |
| Tool calls | not surfaced | **Tool lane** plus invocation location, duration, and output; arguments are not documented |
| Token reporting | one number: "max token count" | **Total / Consumed / Generated / Cached** tokens |
| Triage affordance | none | the **Info column** |
| Privacy confirmation | none described | **"Record Anyway"** |
| Backends | on-device only (nothing else existed) | **any model used through the framework** |

Two of those rows are not incremental. **Prompt and response text in the inspector** is what turns the
instrument from a stopwatch into a debugger — and is exactly why §5.2 exists. **The tree** is what makes
the tool-calling loop legible; with one blue bar per session you could see *that* a request was slow, but
never *which of the four inferences inside it* was slow, or why.

WWDC26's own summary of the change is one word — *"the **enhanced** Xcode instrument"* (✅ session 241,
`241:138`) — which undersells it considerably.

---

## 12. The whole loop, in order

Nothing above is much use as a list of features. Here is the order the tools are actually meant to be
used in, which is also the order of increasing cost.

```
   ┌─ 1. #Playground ────────────────────────────────────────────┐
   │    seconds · no build · human judgement                     │
   │    "is this prompt any good?"                               │
   │    → write down every expectation you form here             │
   └──────────────────────┬──────────────────────────────────────┘
                          │  it produces plausible output
   ┌──────────────────────▼──────────────────────────────────────┐
   │ 2. Scheme simulation                                        │
   │    one menu · one relaunch                                  │
   │    "what does the UI do when the model isn't there?"        │
   │    → availability branches + quota branches                 │
   └──────────────────────┬──────────────────────────────────────┘
                          │  it survives the unhappy paths
   ┌──────────────────────▼──────────────────────────────────────┐
   │ 3. Instruments · Foundation Models template                 │
   │    a build + a trace + a privacy decision                   │
   │    "where did the time go, and what did the model see?"     │
   │    → lanes for shape, tree for cause, Info column for triage│
   └──────────────────────┬──────────────────────────────────────┘
                          │  it is correct and fast enough once
   ┌──────────────────────▼──────────────────────────────────────┐
   │ 4. Evaluations  (Part 6)                                    │
   │    a dataset + evaluators + a test target                   │
   │    "is it *still* good, on every OS update?"                │
   └─────────────────────────────────────────────────────────────┘
```

Apple hands off between the stages explicitly at both ends:

> ✅ **VERIFIED** — `298:50-55`: the `#Playground` pass **is** an evaluation — *"we created a list of
> expectations and used our human judgement"* — and the reason to move on is that *"human judgement
> doesn't scale."*

> ✅ **VERIFIED** — `243:143-145`: *"Once you've ironed out the bugs, **the next thing to explore is
> evaluation.** Watch 'Meet the Evaluations framework' to see how you can **measure and improve the quality
> of your prompts by using structured evaluation.**"*

And Apple's own sample ladder, end to end, is worth copying wholesale: **`#Playground` (seconds) →
heuristic evaluators over a curated dataset (deterministic) → a model judge → generated samples →
κ-calibration of the judge against human scores → diffable runs in CI.** That is Book Tracker, and it is
the spine of [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md).

Where the instrument sits in that ladder is easy to misplace. It is **not** a quality tool. It answers
"what happened and how long did it take". It will never tell you the tags were bad.

---

## 13. Things the instrument does not replace

### 13.1 A transcript recorder

The instrument shows you a trace you captured deliberately. It does not help with the bug your tester hit
on Tuesday. Apple's Origami sample ships a debug utility for exactly that gap, and it is forty lines.

> ✅ **VERIFIED** — `Origami/Models/TranscriptRecorder.swift:16-75`, verbatim (abbreviated):
>
> ```swift
> final class TranscriptRecorder {
>     /// The `UserDefaults` key that gates writing. Off by default; flipped by the
>     /// "Record Transcripts" toggle in Settings.
>     static let isEnabledKey = "TranscriptRecordingEnabled"
>
>     static var isEnabled: Bool {
>         UserDefaults.standard.bool(forKey: isEnabledKey)
>     }
>
>     func snapshot(_ transcript: Transcript) {
>         guard Self.isEnabled else { return }
>         do {
>             try FileManager.default.createDirectory(
>                 at: fileURL.deletingLastPathComponent(),
>                 withIntermediateDirectories: true
>             )
>             let encoder = JSONEncoder()
>             encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
>             let data = try encoder.encode(transcript)
>             try data.write(to: fileURL, options: .atomic)
>             …
> ```
>
> The file is named `<projectTitle>_<yyyyMMdd-HHmmss>.json` under
> `~/Documents/OrigamiTranscripts/`, and the sample re-snapshots after **every** orchestrator effect.
> `Transcript` is ✅ `Encodable`, which is what makes this four lines rather than four hundred.

Why it earns its place next to the instrument:

- It works **outside a profiling session**, on a tester's device, after the fact.
- **`.sortedKeys`** makes two consecutive snapshots diffable. When a tool loop misbehaves, the diff
  between snapshot *n* and *n+1* tells you precisely what the model saw change.
- It is gated by a `UserDefaults` toggle, off by default — the same privacy posture the trace files need.
- No WWDC session mentions it. It is the sample's own idea and it is a good one.

⚠️ The same warning applies with the same force: **these JSON files contain the full transcript.** Ship
the toggle off, never enable it in a release build by default, and delete the directory when you are done.

### 13.2 Evaluations

Covered above and throughout [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md). The one-line division of labour:
**Instruments measures the run; Evaluations measures the result.** A feature can be fast, cheap, structurally
perfect in the tree view, and produce garbage.

### 13.3 Structured logging you write yourself

The instrument sees the framework. It does not see *your* orchestration — the state machine that decides
which mode you are in, the code that decides when to summarise history, the retry you wrapped around
`respond(to:)`. When the Instructions lane shows a switch that should not have happened, the instrument
tells you *that* it happened; only your own logging tells you *which branch of your `body` ran*.

Keep a `Logger` on the orchestrator, log mode transitions with the trigger, and you will be able to line
your own timeline up against the trace's.

### 13.4 A device

Repeating §2.6 because it is the single most common wasted afternoon in this stack: Simulator
inference is host-backed (though the 27.0 sim runtime resolves model assets independently of the
host's Apple Intelligence toggle — see the probe-verified nuance in §2.6), PCC does not work in
simulators at all (known issue **177684296**), and session 243's own requirements say *"on the
device you'd like to run and profile your app on, update to the latest OS releases"* (✅ `243:147`).

> 🔴 **GAP (narrowed 2026-07-31) — whether the Foundation Models *template* records against a
> Simulator destination.** The half of this that a test can decide is now decided: ✅
> **Probe-verified, 2026-07-31** (`probes/` `fm.availability`, on the 27.0 sim runtime) — **the FM
> stack itself works in the Simulator**: model `available`, text inference, guided generation,
> streaming and 8 concurrent sessions all executed, even with the host's Apple Intelligence off
> (tool calling and attachments do not — assets missing). So there is real FM activity in a sim
> process for the template to record. Whether Product ▸ Profile with a Simulator destination
> actually populates the template's lanes remains open — that is Xcode UI behaviour no XCTest can
> decide. Safe default unchanged: **profile on a device.** Even if the template records against a
> Simulator, the numbers would be the host Mac's, which is not a measurement of anything you ship.

> ⚠️ **Probe-verified, 2026-07-31 — `capabilities` will not warn you about the Simulator's gaps.**
> On the 27.0 sim runtime, `SystemLanguageModel.default.capabilities` reports
> `vision=true toolCalling=true guidedGeneration=true reasoning=false` (`probes/`,
> `fm.capabilities`) — while image attachments and tool calling both **fail at runtime** there
> (`LanguageModelError -1` / missing `com.apple.modelcatalog` assets). So `capabilities` is a
> **static declaration of what the model supports, not a per-destination health check**: you cannot
> use `caps.contains(.vision)` to detect the sim's missing pieces, and the bare `-1` stays
> ambiguous. (`reasoning=false` is the one honestly-model-specific bit on this runtime.)

---

## 14. Quick reference

### 14.1 Click paths

| Task | Path |
|---|---|
| Show the playground canvas | Editor Options ▸ ensure **Canvas** is checked |
| Re-run a playground block | the **refresh** button in the canvas (re-runs the *entire* block) |
| Report a bad model output | reproduce in `#Playground` ▸ **thumbs-up icon** beside the response ▸ **Share with Apple** |
| Simulate availability / quota | **Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Options ▸ "Simulated Apple Foundation Models Availability"** |
| Profile (Xcode 27) | **Product ▸ Profile** ▸ **Foundation Models** template ▸ **Record** ▸ **Record Anyway** |
| Profile (Xcode 26) | long-press Run ▸ Profile ▸ **Blank** template ▸ **`+`** ▸ search "foundation models" |
| See the tools bound to an instruction set | tree view ▸ **Instructions** node ▸ inspector |
| Triage a trace fast | the **Info column** — errors, long durations, large token counts |

### 14.2 Reading the timeline

| You see | It means | Go to |
|---|---|---|
| 🟨 long yellow, 🟧 short orange | paying for input | §9.1 TTFT, §10 |
| 🟨 short yellow, 🟧 long orange | paying for output | cap tokens, stream |
| 🟨 long yellow on **every** turn | KV cache invalidated | §10 |
| Instructions lane: **one** region where you expected two | the profile switch never happened | §8 |
| Instructions lane: a new region **every turn** | your `body` resolves differently each turn; full re-prefill each time | §10.2 |
| One request with **many** inference children and no final response | the tool-calling loop is not terminating | §7.3 |
| A 🟨 bar with no 🟧 after it | tool-call-only turn — legitimate, but check your spinner | §9.1 |

### 14.3 The invariants

- **Every model inference should have instructions, a prompt, and either a response or an error.**
  (✅ `243:90`)
- **One `respond(to:)` ≠ one model inference.** N inferences per loop iteration. (✅ `243:87-89`)
- **An instruction switch takes effect on the *next* request**, not mid-request. (✅ `243:124-126`)
- **Appending preserves the KV cache; rewriting invalidates it.** (✅ `242:170-171`)
- **A tool named in the instructions but absent from the toolset never throws.** (✅ `243:100-103`)

### 14.4 Version cheatsheet

| Symbol / feature | Floor |
|---|---|
| `#Playground`, `import Playgrounds` | Xcode 26.0 |
| Thumbs-up feedback in the canvas | macOS/iOS 26 Beta 4 |
| `LanguageModelFeedback`, `logFeedbackAttachment(sentiment:issues:desiredOutput:)` | iOS 26.0 (watchOS 27.0) |
| Playground canvas token counts (Input / Response Token Count) | **26.4** |
| `SystemLanguageModel.tokenCount(for:)`, `.contextSize` | **26.4** (`contextSize` is `@backDeployed`) |
| Scheme availability simulation | Xcode 26.0 |
| Scheme **quota** simulation | Xcode 27.0 + `PrivateCloudComputeLanguageModel` (27.0) |
| Foundation Models instrument, tree + 6 lanes + Info column | **Xcode 27.0** + device on 27 |
| `LanguageModelSession.usage`, `Usage.Input`, `Usage.Output` | **iOS 27.0** |
| `Response.usage`, `Snapshot.usage` | **iOS 27.0** |

### 14.5 Before you share anything

- [ ] `*.trace` is in `.gitignore`.
- [ ] The trace was recorded with **fixture** data, not personal content.
- [ ] Any `logFeedbackAttachment` JSON you are attaching has been read, not just generated.
- [ ] The reproduction is a minimal `#Playground` block, not your whole app.
- [ ] You reproduced it **on a device**, on the OS you are claiming it happens on, and you have said which
      one.

---

## 15. Declared gaps

Everything this guide could not verify, collected so it is easy to close later. None of these is guessed
at anywhere above.

| # | Unknown | What would resolve it | Safe default meanwhile |
|---|---|---|---|
| 1 | **Whether the FM template works against the Simulator.** `243:147` implies a device. | Select a Simulator destination and hit Product ▸ Profile. | Profile on a device; Simulator numbers would be the host Mac's. |
| 2 | **Where a `#Playground` block's model calls execute** (host / Simulator / device), and whether it follows the scheme destination. | Run a playground with a device selected; check whether the response reflects that device's OS. | Use `#Playground` for prompt shape; confirm behaviour on a device. |
| 3 | **The exact contents and semantics of the Xcode 27 scheme menu** — one drop-down or two, whether quota simulation also throws `quotaLimitReached`. | Open the menu; run one request under each setting. | Drive UI off `quotaUsage` **and** catch the thrown error. |
| 4 | **Member names inside `LanguageModelSession.Usage` / `.Input` / `.Output`.** | `/documentation/foundationmodels/languagemodelsession/usage`, or a 27.0 SDK interface dump. | Dump `session.usage` once with `String(describing:)` and code against what you see. |
| 5 | **The `LanguageModelFeedback.Issue.Category` case list.** Only `.incorrect` is attested. | The `Issue.Category` symbol page, or an SDK interface dump. | Use `.incorrect`; put the detail in `explanation`. |
| 6 | **The two 27.0 `logFeedbackAttachment` overloads** (`desiredResponseContent:` / `desiredResponseText:`) — spellings come from an index listing, not a signature. | The symbol pages. | Try `desiredResponseText:` first; fall back to `desiredOutput:`. |
| 7 | **Whether third-party `LanguageModel` backends populate every lane and metric** — cached-token counts presuppose a KV cache the provider may not expose. | A trace against an MLX- or ChatCompletions-backed session on Xcode 27. | Verify the backend's per-token metrics before quoting them. |
| 8 | **Whether the instrument surfaces PCC reasoning tokens at all.** The current page's four metrics do not include reasoning tokens. | A PCC trace with `reasoningLevel` set. | Read reasoning usage from the programmatic `Usage` API; do not claim an Instruments field. |
| 9 | **Whether "Session" in the tree is one `LanguageModelSession` instance**, and whether a node survives a profile switch. Session 243 shows two instruction regions in one recording without saying whether that was one Session node or two. | Expand a trace of a two-profile feature. | Read region counts off the Instructions lane, which is unambiguous. |
| 10 | **`Transcript.Instructions.toolDefinitions` / `.segments` as readable properties** (used by the test in §8.7) — inferred from initialiser labels. | The `Transcript.Instructions` symbol page. | Fall back to encoding the `Transcript` to JSON and searching the string. |

---

## 16. Sources

**Primary — Apple sample code (strongest evidence class).** Downloaded archives, read this session:

- `BookTrackerUsingEvaluationsToEvaluateAnIntelligentFeature/BookTracker/Services/BookTaggingService.swift`
  — `import Playgrounds`, the `#Playground` block at `:76-101`, `SystemLanguageModel(guardrails:)`.
- `OrigamiCraftingADynamicTutorialForAppleIntelligence/Origami/Tutorial/Intelligence/OrigamiInstructions.swift:11-31`
  and `.../CraftTools.swift:12-14` — the verified prose-names-tool / tool-declares-name pattern.
- `.../Origami/Coach/CoachInstructions.swift:15-35` — three tools, one named in prose.
- `.../Origami/Models/OrchestratorProfile.swift` — `var body: some DynamicProfile` (note the **short**
  name in the body type), `.historyTransform(shortHistory(_:))` taking a plain function reference.
- `.../Origami/Models/TranscriptRecorder.swift:16-75` — the JSON transcript snapshotter.
- `.../Origami/Coach/CoachModel.swift:58-73` — the zero-partials stream guard.

⚠️ The coffee/generative-game sample and the SpeechAnalyzer sample in the same harvest are **iOS 26 /
WWDC25 leftovers** and are not cited anywhere in this guide as 2026 evidence.

**Apple documentation.**

- *Analyzing the runtime performance of your Foundation Models app* and *Optimizing key-value caching
  in language model sessions* — direct Apple Markdown captured on 2026-09-22 with response hashes and
  targeted excerpts in the
  [runtime-performance evidence note](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/notes/web/apple-foundation-models-runtime-performance-2026-09-22.md).
- *Managing the context window* — 4,096 tokens, what consumes them, the four-step Instruments workflow,
  the prompt-shortening rules, the unencrypted-recording warning.
- *Using Private Cloud Compute* — the quota API, the four UI recommendations, the scheme steps.
- *Foundation Models updates* — the "February 2026" (26.4) and 2026 entries; the playground token-count
  feature; the "the model changes when a person updates" warnings.
- FoundationModels symbol index — availability strings, `LanguageModelFeedback`, `LanguageModelSession.Usage`.

**Apple Developer Forums.**

- **791250** — *"Provide actionable feedback for the Foundation Models framework and the on-device LLM"*,
  DTS Engineer (Apple), pinned and **locked**, 2025-07-01. The `#Playground` thumbs-up workflow and the
  Feedback Assistant path.
- **831404** — Apple Designer, accepted: the Simulator "punching out to macOS" explanation.
- **831998** — Frameworks Engineer, accepted: PCC does not work in simulators (177684296).
- **836285** — `com.apple.SensitiveContentAnalysisML error 15` from a trivial `#Playground`.
- **836760 / 835211** — the Siri-enablement availability bug, **acknowledged as a bug by an Apple
  Frameworks Engineer** on 836760; unresolved as of 2026-07-27.
- **820819** — Apple asking a developer to file a `LanguageModelFeedback`.

**WWDC26 / Meet with Apple transcripts.**

- **243** — *Debug and profile agentic app experiences with Instruments* (Erik, AI Tools Engineer).
  **The primary source for §5–§9.** Read in full, `transcripts/wwdc2026-243.txt` (153 lines).
- **242** — *Build agentic app experiences with the Foundation Models framework*. KV caches, the
  "training wheels off" framing, the hand-off to 243 for cache invalidation.
- **241** — *What's new in the Foundation Models framework*. `usage` on sessions and responses;
  "the enhanced Xcode instrument".
- **319** — the PCC session. Quota states, the scheme debug option, "data, not just vibes".
- **298** — *Meet the Evaluations framework*. `#Playground` as the zeroth evaluation.
- **205** — *Foundation Models framework code-along* (Shashank). **Xcode 26 baseline**: the `#Playground`
  mechanics, the scheme availability option, the 2025 instrument, the 1,044 → 700 token result.

**Community, attributed as such.**

- `python-apple-fm-sdk` issue **#5** (OPEN) — `LanguageModelFeedback` / `logFeedbackAttachment` are
  Swift-only.
- Prefix-reuse measurements (101× turn-2 TTFT at 4k; unsupported for recurrent-state architectures) —
  community-measured against a non-Apple executor, qwen3-0.6b on Mac. Not Apple figures.
- The `contextSize > 0` defensive read — shipping third-party client code.

**Cross-references in this series.**

- [Part 2 guide 03 — tools and tool calling](../../part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md)
  — the `.required` while-loop, `Tool.name`, and the same silent failure from the API side.
- [Part 3 guide 01 — context window and KV cache](../../part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md)
  — what §10 is measuring.
- [Part 3 guide 02 — dynamic profiles and session state](../../part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md)
  — what the Instructions lane is a picture of.
- [Part 4 guide 01 — Private Cloud Compute](../../part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md)
  — the quota API §4.3 exercises.
- [Part 6 — Evaluations](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md) — where the loop in §12 ends.
