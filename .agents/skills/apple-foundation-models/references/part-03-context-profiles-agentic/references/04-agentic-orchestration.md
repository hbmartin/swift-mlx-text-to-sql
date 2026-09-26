# Baton-pass, phone-a-friend, model routing, and tool-calling control

**Part 3 · Context, profiles, agentic sessions · Reference 04**

**Version floor:** everything structural in this guide is **iOS 27.0 / iPadOS 27.0 / macOS 27.0 /
visionOS 27.0 / watchOS 27.0, Xcode 27**. That covers `LanguageModelSession.DynamicProfile`,
`Profile`, every profile modifier including `.model(_:)`, `.toolCallingMode(_:)` and
`.historyTransform(_:)`, `@SessionProperty` / `@SessionPropertyEntry`,
`GenerationOptions.ToolCallingMode`, `TranscriptErrorHandlingPolicy`, the mutable
`session.transcript`, and `PrivateCloudComputeLanguageModel`. The `Tool` protocol itself is older —
**iOS/macOS/visionOS 26.0**, and **watchOS 27.0** — so a tool you already ship compiles unchanged;
what is new is your ability to *steer* when it fires. `apple/foundation-models-utilities` (the
`Skills` type, §8) declares `.macOS("27.0") / .iOS("27.0") / .visionOS("27.0") / .watchOS("27.0")`
and Swift tools 6.2. The Evaluations framework in §9 is **Xcode 27**. Nothing here works on 26.x, and
nothing here needs 26.1 / 26.3 / 26.4 — but note that the **26.4 on-device model refresh explicitly
improved instruction-following and tool-calling**, so any handoff-reliability number measured on
26.0–26.3 does not transfer forward.

---

## What this covers

Apple named two orchestration patterns at WWDC26 and then shipped a sample that uses neither of them
literally. This guide covers both patterns precisely, says which parts are verified and which are
reconstructed from spoken narration, and then covers the four things you actually have to decide once
you have more than one model in play.

- **Baton-pass** — two or more profiles, a variable that selects one, and a tool that lets the model
  set that variable. The full transcript is visible to both; the profile that *receives* the baton
  produces the final answer.
- **Phone-a-friend** — a tool that spawns a **short-lived child session with an independent
  transcript**, prompts it, and returns the response as tool output. The child disappears; the
  **parent** always produces the final answer.
- The real trade-off between them: **shared context and handoff** versus **isolation and cost
  control** — and why that choice is mostly a decision about your token budget, not about elegance.
- **Tool-calling mode** as the orchestration control surface: `.allowed` / `.disallowed` /
  `.required`, set either through `GenerationOptions` (no profile) or a profile modifier (with one),
  plus the precedence rule between them.
- ⚠️ **The `.required` loop.** It is an unbounded `while` loop. Apple documents exactly two exits and
  you must wire one of them. This is the single most consequential silent failure in the agentic API
  and it gets its own section.
- **Tool-as-consent-request** — Apple's Origami sample turns a tool call into a Yes/No question for a
  human and resumes with a synthesized follow-up turn. It appears in no WWDC session; it is the best
  human-in-the-loop pattern in the corpus and this guide reproduces it from source.
- **Model routing economics** — when a hop to Private Cloud Compute pays for itself, what switching
  models costs you in KV cache, and the backend constraint that quietly decides your architecture:
  **grammar-constrained decoding needs engine logits, so a BYO-model app on a GPU-pipelined Core AI
  bundle loses `@Generable`.** If your orchestration depends on structured output, that narrows your
  backend list before you write a line.
- **`Skills`** from `foundation-models-utilities` as a third orchestration option that is neither
  baton-pass nor phone-a-friend.
- **Evaluating agentic behaviour** — trajectory expectations, and how to assert that a handoff
  actually happened rather than that the answer looked plausible.

## What you need

- **Xcode 27** and a device (or Simulator) on **27.0**. The Simulator punches inference out to the
  host macOS, which produces version-skew errors that look like your bug; trust a device.
- Read [`01-context-window-and-kv-cache.md`](01-context-window-and-kv-cache.md) first — this guide
  spends its second half explaining what handoffs cost, and that guide is where the cost model lives.
- Read [`02-dynamic-profiles-and-session-state.md`](02-dynamic-profiles-and-session-state.md) for
  `DynamicProfile`, `DynamicInstructions`, modifiers, lifecycle callbacks and session properties.
  This guide assumes you can write a profile and read a session property.
- Read
  [Part 2 · `03-tools-and-tool-calling.md`](../../part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md)
  for the `Tool` protocol member by member. §5 here is the *orchestration* view of tool calling and
  deliberately does not repeat the protocol reference.
- For PCC specifically — entitlement, eligibility, reasoning levels, quota UX — see
  [Part 4 · `01-private-cloud-compute.md`](../../part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md).

---

## Contents

1. [Two patterns, one question](#1-two-patterns-one-question)
2. [Baton-pass](#2-baton-pass)
3. [Phone-a-friend](#3-phone-a-friend)
4. [Choosing: shared context versus isolation](#4-choosing-shared-context-versus-isolation)
5. [Tool-calling mode as an orchestration control](#5-tool-calling-mode-as-an-orchestration-control)
6. [⚠️ `.required` is a `while` loop and you supply the exit](#6-️-required-is-a-while-loop-and-you-supply-the-exit)
7. [Tool-as-consent-request: Apple's Origami pattern](#7-tool-as-consent-request-apples-origami-pattern)
8. [Model routing economics](#8-model-routing-economics)
9. [`Skills`: the third option](#9-skills-the-third-option)
10. [Evaluating agentic behaviour](#10-evaluating-agentic-behaviour)
11. [Quick reference](#11-quick-reference)
12. [Sources](#12-sources)

---

## 1. Two patterns, one question

Apple gave these patterns names, and the names are load-bearing because they encode the difference.

> ✅ **VERIFIED** — WWDC26 session 242 (`242:119-120`), verbatim: *"We like to refer to these patterns
> as **baton-pass** and **phone-a-friend**. **Baton-pass is a collaboration and phone-a-friend is a
> consultation.**"*

A collaboration means the second participant sees everything the first one saw and takes over. A
consultation means you ask someone a question, get an answer, and carry on being the one responsible
for the outcome. That is the whole distinction, and every mechanical difference falls out of it:

> ✅ **VERIFIED** — the defining attributes, both verbatim from 242:
>
> **Baton-pass** (`242:128`): *"the **full transcript history is visible to both profiles**, and …
> **the profile that receives the baton can carry it across the finish line and provide the final
> response**."*
>
> **Phone-a-friend** (`242:135`): *"the **transcripts for each profile are isolated**, and … the
> **parent profile is always responsible for giving the final answer**."*

Put next to each other:

| | **Baton-pass** | **Phone-a-friend** |
|---|---|---|
| Nature | Collaboration (`242:120`) | Consultation (`242:120`) |
| Trigger | A tool the model calls | A tool the model calls |
| What the tool does | Sets a variable that selects the active profile | **Spawns a short-lived child `LanguageModelSession`** |
| Transcript | **One**, shared, fully visible to both profiles | **Two**, isolated; the child's never merges |
| Who writes the final answer | **The receiving profile** | **Always the parent** |
| Lifetime | Both profiles persist inside one session | The child *"disappears"* (`242:134`) |
| Cost model | You pay for one growing transcript | You pay for a second, disposable prefill |

Both are **tool-driven**. That is worth saying out loud because it is the thing people get wrong when
they read the summary: phone-a-friend is not "just call another session from your app code". Calling
another session from your app code is a perfectly good thing to do — Origami does it, §3.5 — but it
is not an orchestration pattern, because the *model* is not the one deciding. What makes both of
these patterns agentic is that the model chooses, mid-turn, to invoke a tool whose side effect is
structural.

> ⚠️ **Set your expectations about evidence before you read further.** Sessions 242 and 243 describe
> both patterns in prose and show slides. **No Apple sample project implements either one with a
> tool.** Origami — the sample that accompanies session 242 — performs its brainstorm→tutorial→coach
> handoff by mutating an `@Observable` property from app code, not from a tool call (§2.3), and it
> contains no phone-a-friend at all. So: the *shapes* below are Apple's, the *narration* is verbatim,
> and every code listing is marked with what backs it. Where a listing is 🟡 RECONSTRUCTED, it means
> exactly that — the mechanism is attested, the identifiers are ours.

### 1.1 The one question

Before you pick, answer this: **does the second model need to know what the first one heard?**

- **Yes** → baton-pass. A tutorial generator that has to know which of five brainstormed ideas the
  user chose, and *why they rejected the other four*, needs the transcript. Re-summarising it into a
  tool argument loses precisely the thing that makes the handoff worth doing.
- **No** → phone-a-friend. "Give me a title for a project described as X" needs X and nothing else.
  Handing that consultant a 3,000-token craft conversation is pure cost: it slows the call, it eats
  the child's context window, and it gives the child room to answer a question you did not ask.

Everything else — which model, how much it costs, whether it can call tools of its own — is a second-
order decision. Get the context-visibility question right first.

---

## 2. Baton-pass

### 2.1 The three ingredients

> ✅ **VERIFIED** — WWDC26 session 242 (`242:122-124`), verbatim, in order:
> 1. *"there are **two or more profiles**, typically **each leveraging different models**."*
> 2. *"There also needs to be **a variable that controls which profile is active**."*
> 3. *"Finally, we **give each profile a tool that allows the model to set that variable**."*

Read ingredient 3 carefully: *each* profile gets such a tool. A baton you can only pass one way is a
state machine with no way back, and in a conversational app the user will absolutely ask a
tutorial-mode assistant to brainstorm again.

The worked example, also verbatim:

> ✅ **VERIFIED** — `242:126-127`: *"If we're currently brainstorming and ask **how to fold a crane**,
> the **brainstorm profile will call a tool to pass the baton to the tutorial profile**. **A tool
> output signals a successful handoff**, and the **tutorial profile produces the final answer**."*

That sentence contains a mechanical detail that is easy to skim past: **the tool output is the
handoff signal, and it lands in the shared transcript.** The receiving profile does not get told "you
have the baton" out of band. It reads, in the history it inherits, a tool-output entry saying the
switch happened. So what you return from that tool is context for the *next* profile, and it should
read like a briefing, not like a status code.

### 2.2 What the transcript looks like across a pass

One session, one transcript. The instructions entry at the top is re-rendered when the profile
changes; everything after it is inherited verbatim.

```
[0] .instructions   ← re-rendered by the NEW profile on the next request
[1] .prompt         "ideas for a paper craft with my kid"
[2] .response       "Yarn PomPom, Fabric Pouch, Paper Butterfly…"
[3] .prompt         "how do I fold a crane?"
[4] .toolCalls      switchToTutorialMode(craft: "crane")   ← the baton
[5] .toolOutput     "Switched to tutorial mode for crane."  ← the handoff signal
[6] .response       ← written by the TUTORIAL profile
```

> 🟡 **RECONSTRUCTED** — the entry layout. The *sequence* (prompt → tool call → tool output →
> response) is verified from the code-along's live transcript inspection
> (✅ WWDC26 session 205, `205:805-815`, which found six entries for a two-tool-call turn), and the
> content of entries 4–6 follows from `242:126-127`. Nobody has published a transcript dump across an
> actual profile switch. If you need certainty, print `session.transcript` before and after — Origami
> ships a `TranscriptRecorder` that does exactly this (§2.7).

Note where the switch is *not* visible: there is no `.profileChanged` entry. The only trace of the
handoff in the transcript is your tool output and the fact that entry `[0]` now says something
different. That is why the tool output string matters.

### 2.3 What Apple's shipping code actually does

This is the most important correction in this guide, and it cuts both ways.

> ✅ **VERIFIED** — Apple's Origami sample (`OrigamiCraftingADynamicTutorialForAppleIntelligence`,
> `IPHONEOS_DEPLOYMENT_TARGET = 27.0`) implements its mode handoffs **without a tool**. The profile
> is a pure projection of an `@Observable` state machine, and app code mutates the mode.
> `Origami/Models/OrchestratorProfile.swift:11-75`, verbatim:

```swift prelude:guide-context
struct OrchestratorProfile: LanguageModelSession.DynamicProfile {
    var orchestrator: Orchestrator

    // Brainstorm and tutorial work best on a server model. The sample
    // defaults to the on-device system model so it runs out of the box.
    // To use Private Cloud Compute, request access to the managed
    // `com.apple.developer.private-cloud-compute` entitlement at
    // https://developer.apple.com/contact/request/private-cloud-compute/,
    // then replace the `serverModel` initialization with the line below.
    // var serverModel = PrivateCloudComputeLanguageModel()
    var serverModel = SystemLanguageModel()

    var body: some DynamicProfile {
        switch orchestrator.mode {
        case .brainstorm:
            if !isOnDevice {
                Profile {
                    BrainstormInstructions(orchestrator: orchestrator)
                }
                .model(serverModel)
                .temperature(1.0)
            } else {
                // Brainstorming is lower-quality on-device than with
                // Private Cloud Compute.
                Profile {
                    BrainstormInstructions(orchestrator: orchestrator)
                }
                .model(SystemLanguageModel())
            }

        case .tutorial:
            if !isOnDevice {
                Profile {
                    TutorialInstructions(orchestrator: orchestrator)
                }
                .model(serverModel)
                .reasoningLevel(.deep)
            } else {
                // Tutorial generation is lower-quality on-device than with
                // Private Cloud Compute.
                Profile {
                    TutorialInstructions(orchestrator: orchestrator)
                }
                .model(SystemLanguageModel())
                .historyTransform(shortHistory(_:))
            }
        case .term:
            Profile {
                TermInstructions(orchestrator: orchestrator)
            }
            .model(SystemLanguageModel())
            .historyTransform(shortHistory(_:))
        }
    }

    private var isOnDevice: Bool {
        type(of: serverModel) == SystemLanguageModel.self
    }

    /// Returns the most recent four entries so longer on-device sessions
    /// stay within the smaller context window.
    private func shortHistory(_ entries: [Transcript.Entry]) -> [Transcript.Entry] {
        Array(entries.suffix(4))
    }
}
```

Four API facts to bank from those 75 lines, because several contradict what the transcripts implied:

- Conformance is the **nested** `LanguageModelSession.DynamicProfile`, but the `body` type is the
  **short** `some DynamicProfile`. Apple writes the short name inside a conforming type, exactly like
  SwiftUI's `some View`. ✅ verified.
- **`Profile { … }.model(x)`**, a content closure plus a modifier — **not** `Profile(model:) { … }`.
  The initialiser form appears in transcript reconstructions and in no compiling code we have. ✅
  verified — and as of 2026-07-29 settled against the SDK: `Profile` has exactly one initializer
  (the builder-closure form) and **no `model:` label exists in the 27.0 beta interface**
  (`FoundationModels-27.0-macos.swiftinterface:830-843`; `.model(_:)` modifier at `:966-968`).
- **`.temperature(1.0)`** takes a `Double`. **`.reasoningLevel(.deep)`** is exactly as narrated.
- **`.historyTransform(_:)` takes `([Transcript.Entry]) -> [Transcript.Entry]`**, and a plain
  function reference is accepted. It is handed the *entry array*, not a `Transcript`.

And the architectural fact, which is worth more than all four:

> **The `DynamicProfile` is a derived view of app state, exactly like a SwiftUI `body`.** Origami's
> `body` `switch`es on `orchestrator.mode`; `Orchestrator.reduce(_:)` mutates `state.mode`; therefore
> **mutating the mode *is* the agent handoff.** There is no handoff API. There is a state machine and
> a projection of it.
>
> ✅ **VERIFIED** — `Origami/Models/Orchestrator.swift:165-179`, the whole dispatcher:
>
> ```swift
> func send(_ event: OrchestratorEvent) {
>     log("event: \(event)")
>     currentTask?.cancel()
>     if state.mode == .term {
>         dismissTerm()
>     }
>     let effects = reduce(event)
>     guard !effects.isEmpty else { return }
>     currentTask = Task {
>         for effect in effects {
>             await execute(effect)
>             snapshotTranscript()
>         }
>     }
> }
> ```
>
> `reduce` is pure-ish state mutation returning `[OrchestratorEffect]`; `execute` performs the async
> model work. Three flat enums drive it — `OrchestratorMode` (3 cases), `OrchestratorEvent` (11),
> `OrchestratorEffect` (9), all in `OrchestratorState.swift`.

Take the framing seriously. A `DynamicProfile` that reads five scattered `@Observable` booleans is a
profile whose active branch nobody can predict. One enum, one `switch`, one reducer, and the trace in
Instruments becomes readable.

**So is baton-pass real?** Yes — it is the shape 242 describes, and the *only* thing Origami does
differently is who flips the variable. Everything else is identical: one session, one transcript,
profiles swapped by a variable, the receiving profile answering. Origami's flip comes from a button
tap; 242's comes from a tool call. If your app's mode transitions are all user-initiated, you already
have baton-pass and you do not need the tool. **Add the tool only when the model, not the user, is
the one who should decide.**

### 2.4 The tool that passes the baton

Here is the tool-driven version. Everything about the *shape* comes from `242:122-128`; the
identifiers are ours.

> 🟡 **RECONSTRUCTED** — no first-party source exists for this tool. Session 243 names a
> `SwitchToTutorialModeTool` and a tool name `switchToTutorialMode` in a build Apple demoed but did
> not ship (`243:50`, `243:98`, `243:121`, `243:125`), and confirms it takes the chosen craft as an
> argument (`243:125`: *"a tool call to `switchToTutorialMode`, **passing the selected craft as an
> argument**"*). The `Tool` conformance itself is ✅ verified API. What is reconstructed is this
> file's contents, not the protocol.

```swift compile:27
import FoundationModels
import Observation

// The controlling variable. One enum, one owner.
@MainActor
@Observable
final class CraftOrchestrator {
    enum Mode { case brainstorm, tutorial }
    var mode: Mode = .brainstorm
    var selectedCraft: String?
}

enum ToolNames {
    static let switchToTutorialMode = "switchToTutorialMode"
    static let switchToBrainstormMode = "switchToBrainstormMode"
}

struct SwitchToTutorialModeTool: Tool {
    let name = ToolNames.switchToTutorialMode
    let description = """
        Switch into tutorial mode once the person has chosen which craft they \
        want to make. Call this as soon as they pick one; do not start writing \
        the tutorial yourself.
        """

    let orchestrator: CraftOrchestrator

    @Generable
    struct Arguments: Sendable {
        @Guide(description: "The craft the person chose, in their own words")
        var craft: String
    }

    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            orchestrator.selectedCraft = arguments.craft
            orchestrator.mode = .tutorial          // ← the baton
        }
        // The tool output IS the handoff signal, and the receiving profile
        // will read it as history. Write it as a briefing.
        return """
            Switched to tutorial mode. The person chose: \(arguments.craft). \
            Write the step-by-step tutorial for it now.
            """
    }
}
```

and the profile that reads the variable:

```swift prelude:guide-context
struct CraftProfile: LanguageModelSession.DynamicProfile {
    let orchestrator: CraftOrchestrator

    var body: some DynamicProfile {
        switch orchestrator.mode {
        case .brainstorm:
            Profile {
                Instructions {
                    """
                    Help the person brainstorm craft ideas from the photos they share. \
                    Offer a short list of distinct concepts. When they choose one, \
                    call the \(ToolNames.switchToTutorialMode) tool.
                    """
                }
                SwitchToTutorialModeTool(orchestrator: orchestrator)
            }
            .model(PrivateCloudComputeLanguageModel())
            .temperature(1.0)

        case .tutorial:
            Profile {
                Instructions {
                    """
                    You are an expert craft tutorial writer. Write clear, numbered \
                    steps. If the person wants to explore other ideas instead, call \
                    the \(ToolNames.switchToBrainstormMode) tool.
                    """
                }
                SwitchToBrainstormModeTool(orchestrator: orchestrator)
            }
            .model(PrivateCloudComputeLanguageModel())
            .reasoningLevel(.deep)
        }
    }
}
```

Five decisions in that listing that are not decoration:

1. **The tool name is a constant referenced by both the instructions string and the `Tool`
   conformance.** Nothing in the compiler, framework or runtime checks that the name you write in
   prose matches a registered tool — §2.7 is what happens when they drift.
2. **The tool writes the variable and returns prose.** It does not return `"ok"`. The next profile
   reads that string as its most recent context.
3. **The mutation is hopped to the main actor** because the orchestrator is `@Observable` and drives
   SwiftUI. `Tool` requires `Sendable`, not value semantics, and the framework may run your tool
   concurrently with itself — mutable state needs protecting either way.
4. **Each profile carries a tool back.** See ingredient 3 in §2.1.
5. **The instructions name the tool in the *imperative*** — "call the X tool" — rather than describing
   it. Every shipped Apple example that depends on a tool being called also names it in the
   instructions (✅ `Origami/Tutorial/Intelligence/OrigamiInstructions.swift:11-31`,
   ✅ WWDC26 code-along `205:771-774`). The `description` alone is not enough.

### 2.5 The baton lands on the *next* request, not mid-request

This timing fact is verified, easy to get wrong, and explains a whole class of "my handoff didn't
work" reports.

> ✅ **VERIFIED** — WWDC26 session 243 (`243:124-126`), from the Instruments trace of the fixed build:
> *"**The instruction change happened after the second model inference of Request 2.** That inference
> resulted in a **tool call to `switchToTutorialMode`, passing the selected craft as an argument**.
> And **in the following request, the instructions correctly switched over to the tutorial generator,
> with the selected craft passed along as context.**"*

So the sequence inside one `respond(to:)` is:

```
Request 2
├── inference 1   (brainstorm instructions)      → prose
├── inference 2   (brainstorm instructions)      → toolCall switchToTutorialMode
│      └── tool runs, orchestrator.mode = .tutorial
└── inference 3   (brainstorm instructions STILL) → the answer to THIS request
Request 3
└── inference 1   (tutorial instructions)         ← the switch is visible here
```

> ⚠️ **The profile that *called* the tool is usually the one that finishes the current turn.** Session
> 242's framing — *"the tutorial profile produces the final answer"* (`242:127`) — is true of the
> conversation, not necessarily of the same `respond(to:)` call. If you need the receiving profile to
> write the very next sentence the user sees, you have two options: drive the handoff from a UI event
> and start a fresh request (Origami's approach), or set `.toolCallingMode(.required)` on the sending
> profile so it *cannot* produce a prose answer after the tool call, and let the mode flip put the
> receiving profile in charge of the next request (§6).
>
> This is 🟡 **partly reconstructed**: `243:124-126` verifies that the instruction change appears in
> the following request. Whether the framework re-evaluates `body` *between* inferences within one
> request and could therefore swap mid-request is unverified — and there is evidence pointing the
> other way, because a third-party instrumented count found **7 body evaluations across 3 turns**
> (community-measured, `coreai-model-zoo/knowledge/dynamic-profiles-local-models.md`), i.e. more than
> one per turn. Do not build on mid-request switching. Design so the turn boundary is the switch
> point.

**How to see it.** The Instruments **Instructions lane** is the profile-switch visualiser:

> ✅ **VERIFIED** — `243:78`: *"The Instructions lane shows **how long a given set of instructions and
> tools was active**. One set can cover multiple requests."* And the diagnostic read, `243:80`:
> *"it's clear **only one set of instructions was active for the entire session** but the feature was
> supposed to use two, **so something went wrong during the handoff**."* After the fix (`243:117`):
> *"The Instructions lane now shows **two distinct instructions** active during this experience."*

One unbroken region where you expected two means the baton never moved. That is a five-second read
and it is the fastest diagnosis in the toolchain. See
[Part 5 · `01-playground-and-instruments.md`](../../part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md).

### 2.6 What a pass costs

A baton-pass is not free, and the cost is not in the tool call.

> ✅ **VERIFIED** — Apple's KV-caching article: *"A session typically arranges its content into a
> token sequence with a specific order, like **instructions appearing at the top, tool definitions
> coming next, and then transcript entries follow at the end**. Each cached value in the sequence
> depends on every token that precedes it… **A change to the instructions, for example, invalidates
> the cache for the tool definitions and the entire transcript.**"*
>
> ✅ **VERIFIED** — same article, stated for profiles specifically: *"**Switching from one profile to
> another typically changes the entire prefix — which invalidates the cache for the full transcript —
> so treat it as a deliberate reset.** Design your dynamic profiles so transitions … occur at
> **natural boundaries in the conversation rather than on every turn**."*

Both a baton-pass and a plain instructions change rewrite the top of the token sequence, so **every
cached key/value below it is invalidated and the whole transcript is re-prefilled**. If you also
switch models, it is worse — the new model has its own executor and its own cache, and nothing
carries over:

> **Community-measured** — two local models behind `LanguageModel`, macOS 27 beta, M-series Mac,
> 2026-06-13, qwen3-0.6b ↔ qwen3-4b via `coreai-kit`'s `KitLanguageModel`
> (`coreai-model-zoo/knowledge/dynamic-profiles-local-models.md`): *"**Switching models re-prefills
> the shared transcript on the newly active engine.** … Measured: **switch-in first-delta 2.35 s**
> (re-prefill ~106 tokens plus the 4B's reasoning), **switch-back 0.94 s**. Append-only KV reuse only
> helps across consecutive *same-model* turns."* Exact Mac model and macOS build were not stated by
> the author. This is a third-party provider, **not** Apple's own inference stack — Apple has
> published no equivalent figure.

The design rules that fall out:

- **Switch at conversation boundaries, not per turn.** A profile that alternates every turn pays a
  full re-prefill every turn.
- **Keep the shared prefix as long as possible.** Put static instructions and tools at the top of
  your `DynamicInstructions` and conditional content at the bottom — ✅ verified guidance from the
  KV-caching article: *"Place instructions and tools that remain constant at the top … group
  conditional content at the bottom,"* and *"Placing the conditional content **before** the static
  instructions and tools invalidates the cached values and leads to unnecessary recomputation."*
- **Do not add or remove tools to signal a handoff.** Tool definitions live *inside* the instructions
  entry (`Transcript.Instructions.init(id:segments:toolDefinitions:)`), so mutating the toolset has
  the same blast radius as rewriting the instructions, plus an accuracy hazard (§2.8).

Full cost model in [`01-context-window-and-kv-cache.md`](01-context-window-and-kv-cache.md).

### 2.7 ⚠️ SILENT FAILURE — the baton tool you named but never registered

> ⚠️ **SILENT FAILURE. An entire WWDC26 session is built around this one bug, and it is specifically a
> *handoff* bug.**

Your instructions are text. Your toolset is code. Nothing checks that a tool name appearing in the
first also appears in the second. When they drift, the model behaves exactly as if the tool existed,
fails to reach it, and keeps going — with no error anywhere.

> ✅ **VERIFIED** — WWDC26 session 243. The design (`243:50`): *"The brainstorming instructions
> include **two tools**: a **`GenerateCraftIdeaTool`** and a **`SwitchToTutorialModeTool`**."* The
> shipped build registered only the first.
>
> The symptom (`243:63-66`): *"Hm. That's not right. **The model was supposed to kick off a tutorial
> but instead it just offered more ideas.** Something's off."*
>
> The diagnosis (`243:98-99`): *"**The prompt references the `switchToTutorialMode` tool but that tool
> isn't actually configured with this instruction.** … Without it, the app has no way to switch from
> brainstorm mode to tutorial mode, so the crafter gets stuck in a loop."*
>
> Why it is nasty (`243:100-103`): *"Looking at the subsequent nodes in the tree, **this was a silent
> failure. The model kept accepting input and making tool calls but never threw an error. There was
> no clear signal that anything had gone wrong. That makes it a hard bug to catch.**"*

**Why it loops instead of stalling.** The model is told in prose that a `switchToTutorialMode` tool
exists. It is separately handed a menu that does not contain it. Constrained decoding means it can
only emit calls to tools that *are* in the menu, so its attempt to hand off degrades into the nearest
legal action — calling the idea generator again. The output is well-formed. The tool call succeeds.
The controlling variable never moves, so the next turn presents the same instructions and the model
makes the same decision. Every component is individually working. There is nothing to throw.

**This bug class is native to baton-pass** in a way it is not to ordinary tool use, because the
consequence of a missing tool is not "a feature is unavailable" but "the state machine cannot
advance." Three cheap defences, none of which require Instruments:

```swift prelude:guide-context
import Testing
import FoundationModels

// 1. A unit test asserting every tool named in prose is registered.
@Test func batonToolsAreRegistered() throws {
    let brainstormTools: [any Tool] = [
        GenerateCraftIdeasTool(),
        SwitchToTutorialModeTool(orchestrator: CraftOrchestrator())
    ]
    let registered = Set(brainstormTools.map(\.name))
    #expect(registered.contains(ToolNames.switchToTutorialMode))
}
```

```swift prelude:guide-context
// 2. Print what was actually advertised. Tool definitions live in entry 0.
if case let .instructions(instructions) = session.transcript.first {
    print("tools advertised:", instructions.toolDefinitions.map(\.name))
}
```

```swift prelude:guide-context
// 3. A stuck-handoff detector: the same tool N times with no mode change.
Profile { BrainstormInstructions(orchestrator: orchestrator) }
    .onToolCall { call in
        callLog.append(call.toolName)
        if callLog.suffix(4).allSatisfy({ $0 == call.toolName }) {
            logger.warning("possible handoff loop on \(call.toolName)")
        }
    }
```

> The one-argument `onToolCall { call in … }` form with `call.toolName` is ✅ verified from Apple's
> dynamic-profiles article; the zero-argument `onToolCall { … }` form is ✅ verified from compiled test
> code (`mlx-swift-lm`, `StructuredToolOutputSessionTests.swift:62-65`). ✅ **RESOLVED (2026-07-29):**
> both arities exist as declared overloads — the zero-argument form forwards to the
> `(Transcript.ToolCall)` form — and the closures are **`async throws`**
> (✅ **SDK-verified**, `FoundationModels-27.0-macos.swiftinterface:1008-1014`). So the detector above
> may await and may throw. A community security note attributed to WWDC26 session 347 states that
> **throwing from `onToolCall` blocks the tool from running.** This is now runtime-verified on
> stable macOS 27 and iPhone 15 Pro / iOS build `24A435`: the tool body did not run, `respond`
> threw `ToolCallError`, and the default transcript reverted to `[instructions]`. Treat the hook as
> a turn-abort veto, not as a way to return control to the model's loop.

The structural fix is one `enum ToolNames` read by both the conformance and the instructions string,
as in §2.4. It cannot catch a tool you forgot to put in the array — detector 1 can, and it is four
lines.

### 2.8 Passing the baton to a *different* model

Baton-pass is at its most useful, and most dangerous, when the two profiles run on different models,
because the transcript that follows the baton was written for a different context budget and a
different trust boundary.

> ✅ **VERIFIED** — `242:64`: *"it's important to consider that **each model may have different
> context size limits**."* And `242:66-68`: *"When moving between models, you may need to **trim
> unnecessary entries to stay within the context size**. But that's not the only reason … You can also
> **improve the model's focus by removing irrelevant entries**, or **redact private information from
> existing entries when moving to a less private model**."*

Three concrete obligations when the baton crosses a model boundary:

**1. Fit the receiving model's window.** On-device is small. Apple's docs and WWDC26 session 319 both
give **4K on-device / 32K PCC** (✅ both sources agree exactly). Project probes returned **4096** on
the beta-5 physical device and again on stable macOS 27 plus iPhone 15 Pro / iOS build `24A435`.
The old 8192 community comment came from a now-retired upstream snapshot and was never reproduced.
Still **read `contextSize`; do not hardcode it**, because the 27 getter is dynamic and model changes
move the same transcript between different budgets. Origami's answer is the smallest possible
`historyTransform`:

```swift compile:27 imports:FoundationModels
// ✅ VERIFIED — Origami/Models/OrchestratorProfile.swift:289-293
private func shortHistory(_ entries: [Transcript.Entry]) -> [Transcript.Entry] {
    Array(entries.suffix(4))
}
```

applied only to the on-device branches. Four entries. That is the entire trimming strategy in Apple's
flagship dynamic-profiles sample, and it is worth internalising how blunt it is before you build
something clever.

**2. Redact before a privacy hop.** On-device → PCC is a boundary crossing, and 242 explicitly
recommends redacting on the way out (`242:68`). `historyTransform` is the hook, because it runs
before the transcript is rendered to the model and does not mutate the stored transcript:

> ✅ **VERIFIED** — `242:78-80`: *"**Transforms don't permanently mutate the session's transcript.
> Instead, they're local transformations applied prior to prompting the model.** This means **you
> don't need to worry about losing context that may become relevant at a later point**."*

> **Community caution** (attributed to WWDC26 session 347, which is not in our transcript corpus):
> `.historyTransform` *"fires before the transcript is rendered to the model, on every new user
> request **and every loop iteration**"* and *"**transforms are scoped to the current inference
> only** — not visible to the next call, so re-apply every iteration."* Treat the per-iteration claim
> as secondary; the "does not persist" half is corroborated by `242:79`.

**3. Expect the model to notice the seams.** Trimming and redaction change what the model believes:

> ✅ **VERIFIED** — Apple's KV-caching article: *"there's no reliable way for the model to distinguish
> between information that never existed and information that did exist but was removed from the
> context. A model treats whatever's in the context as the complete picture and **reasons confidently
> from incomplete evidence**."*

And the specific tool hazard, verbatim from the same article: *"**Removing a tool the model
previously used can cause the model to produce unexpected results** because it sees references in the
transcript for a tool that no longer exists in its tool definitions. If you do remove any tools, also
remove any associated output that refers to them."* A baton-pass does exactly this — the sending
profile's tools vanish when the receiving profile takes over, and the transcript still contains the
call that passed the baton. Origami lives with it (its coach profile drops `FetchOrigamiTemplate` and
gains three other tools atomically, ✅ `CoachInstructions.swift:12-36`), and so can you, but if the
receiving profile starts hallucinating calls to the sender's tools, this is why.

---

## 3. Phone-a-friend

### 3.1 The mechanism

> ✅ **VERIFIED** — WWDC26 session 242 (`242:130-131`), verbatim: *"you also rely on **tool calling**.
> The key difference is that **instead of toggling a variable, the tool spawns a short-lived
> session**."*
>
> And the worked example (`242:132-134`): *"If we ask for **a fun project for kids**, the model may
> reason that **it needs a title for the project**, and call its phone-a-friend tool **to consult with
> the title profile**. The phone-a-friend tool **spawns a new session with an independent transcript,
> prompts it, and then delivers the response back as tool output**. **The child session disappears**,
> and the **parent session produces the final response**."*

Four verbs in that sentence, and all four matter: **spawns**, **prompts**, **delivers back as tool
output**, **disappears**. A phone-a-friend tool is a completely ordinary `Tool` whose `call` body
happens to contain an entire model interaction. The framework has no idea. There is no
`ChildSession` type, no `subsession(_:)` API, nothing to import. That is the good news and it is also
the thing to be careful about, because nothing will stop you from spawning a child on every turn of a
conversation and wondering where your battery went.

### 3.2 The code

> 🟡 **RECONSTRUCTED** — as with §2.4, the mechanism is verbatim from `242:130-135` and the API pieces
> are individually ✅ verified (`LanguageModelSession(profile:)` from `242:58`;
> `LanguageModelSession(model:instructions:)` from ✅ `Origami/Terms/TermExtractor.swift:32-39`;
> `respond(to:)` → `.content` from the same). No Apple sample implements a phone-a-friend tool.

```swift compile:27
import FoundationModels

struct ConsultTitleSpecialistTool: Tool {
    let name = "generateProjectTitle"
    let description = """
        Ask the naming specialist for a short, playful title for a craft \
        project. Use this whenever you need a name; do not invent one yourself.
        """

    @Generable
    struct Arguments: Sendable {
        @Guide(description: "A one- or two-sentence description of the project")
        var projectDescription: String

        @Guide(description: "The age range the project is aimed at, if known")
        var audience: String?
    }

    func call(arguments: Arguments) async throws -> String {
        // A NEW session with an INDEPENDENT transcript. It dies when this
        // function returns — nothing retains it.
        let child = LanguageModelSession(
            model: SystemLanguageModel(),
            instructions: """
                You name craft projects. Reply with a single title of at most \
                six words. No preamble, no punctuation at the end, no options.
                """
        )

        let prompt = Prompt {
            arguments.projectDescription
            if let audience = arguments.audience {
                "Aimed at: \(audience)."
            }
        }

        let response = try await child.respond(to: prompt)
        return response.content          // delivered back as tool output
    }
}
```

Three things this listing gets right that a first draft usually does not:

**The child is constructed inside `call`, not stored on the tool.** A stored child session would
accumulate a transcript across every consultation in the conversation — which is precisely the
property phone-a-friend exists to avoid, and it would also make the tool stateful in a way that
interacts badly with the framework running your tool concurrently with itself. If you find yourself
wanting to keep the child alive, you want baton-pass.

**The child gets *only* the arguments.** Everything the consultant knows arrives through the
`@Generable` `Arguments` struct, which means the parent model had to decide what was relevant and say
so. That is a feature: it is the compression step, and it is inspectable. It is also where
consultations fail — see §3.6.

**The return value is the tool output the parent will read.** Whatever the child says lands verbatim
in the parent's transcript as a `.toolOutput` entry. So the child's instruction *"Reply with a single
title of at most six words. No preamble"* is not stylistic fussiness — it is the contract that keeps
the parent's context window from absorbing a chatty consultant's essay.

### 3.3 Isolation is verified, and it is the point

> **Community-verified** — `coreai-model-zoo/knowledge/dynamic-profiles-local-models.md`, macOS 27
> beta, M-series Mac, 2026-06-13, describing phone-a-friend implemented against two local models:
> a *"consultation via a **short-lived child `LanguageModelSession`** on the big model with an
> isolated transcript — **The child's transcript never merges into the parent's (verified: parent
> transcript = 1 prompt / 1 response)**."*
>
> That is a third-party measurement against a third-party `LanguageModel` provider, not Apple's own
> stack. It corroborates `242:135` rather than establishing it.

Isolation buys you four things:

1. **A bounded, predictable child cost.** The child's prompt is exactly its instructions plus your
   arguments. It does not grow with the conversation. A consultation on turn 40 costs the same as one
   on turn 2.
2. **The parent's window is charged only for the answer.** One `.toolCalls` entry and one
   `.toolOutput` entry, not a transcript merge.
3. **The consultant cannot be derailed by the conversation.** A user who spent ten turns arguing with
   the parent cannot influence the naming specialist, because the specialist never sees it. This is a
   real prompt-injection containment property, not just a tidiness one.
4. **The child can use a completely different configuration** — a different model, a much lower
   temperature, `.disallowed` tool calling, a tight `maximumResponseTokens` — without touching the
   parent's profile at all.

And it costs you one thing, which is the same thing: **the consultant does not know anything you did
not tell it.** If the answer depends on nuance from earlier in the conversation, you are now relying
on the parent model to have summarised that nuance correctly into a `String` argument. That failure
is silent and it looks like the consultant being stupid.

### 3.4 A child session with its own profile

Nothing stops the child from being as structured as the parent. If the consultant is a recurring role
in your app rather than a one-liner, give it a profile:

```swift prelude:guide-context
struct TitleSpecialistProfile: LanguageModelSession.DynamicProfile {
    var body: some DynamicProfile {
        Profile {
            Instructions {
                """
                You name craft projects. Reply with a single title of at most \
                six words. No preamble, no options.
                """
            }
        }
        .model(SystemLanguageModel())
        .temperature(0.4)
        .maximumResponseTokens(24)
    }
}

func call(arguments: Arguments) async throws -> String {
    let child = LanguageModelSession(profile: TitleSpecialistProfile())
    return try await child.respond(to: arguments.projectDescription).content
}
```

> ✅ `LanguageModelSession(profile:)` is verified (`242:58`; Apple's dynamic-profiles article).
> ✅ `.maximumResponseTokens(_:)` and `.temperature(_:)` are verified profile modifiers.
> 🟡 The combination above is reconstructed — nobody has published a phone-a-friend with a profile.

Two notes. A single-branch `DynamicProfile` is legal and, on at least one third-party provider,
**preferable**: *"Prefer a single-profile `DynamicProfile` over `LanguageModelSession(model:instructions:)`
— the plain initializer's first respond can `decodingFailure` where the profile path is solid"*
(community-measured, `dynamic-profiles-local-models.md`). That is a provider-specific defect, not an
Apple-framework claim, but the single-branch profile costs nothing.

And **`maximumResponseTokens` on the child is your cost ceiling.** It is the only hard limit you have
on how much a consultation can inject into the parent's context.

### 3.5 The closest thing Apple actually ships

Origami has no phone-a-friend tool, but it does have a **short-lived side session with an isolated
transcript**, spun up by app code rather than by the model. It is worth reading because every
mechanical detail of the child half is verified here:

> ✅ **VERIFIED** — `Origami/Terms/TermExtractor.swift`, in full for the session part:

```swift prelude:guide-context
@Generable
private struct ExtractedTerms: Codable {
    var terms: [String]
}

enum TermExtractor {
    static func extract(
        from tutorial: TutorialContent,
        craftDomain: CraftDomain?
    ) async throws -> [String] {
        // Continuous block of prose only — no per-step labels or section
        // headers. The `SystemLanguageModel` context is tight; structural
        // notation here would crowd out the actual text to analyze.
        let body = tutorial.sections
            .flatMap(\.steps)
            .map(\.content)
            .joined(separator: " ")

        let session = LanguageModelSession(
            model: SystemLanguageModel(),
            instructions: instructions(for: craftDomain)
        )
        let response = try await session.respond(
            to: body,
            generating: ExtractedTerms.self
        )

        var seen = Set<String>()
        var result: [String] = []
        for term in response.content.terms where !term.isEmpty {
            let key = term.lowercased()
            guard seen.insert(key).inserted else { continue }
            // Drop anything the model invented or paraphrased that
            // doesn't actually appear in the tutorial text.
            guard body.range(of: term, options: .caseInsensitive) != nil else { continue }
            result.append(term)
        }
        return result
    }
}
```

Four transferable moves, all ✅ verified from that file:

- **`@Generable` on a `private` type compiles.** A consultant's output shape does not have to be part
  of your app's API surface.
- **Strip structure out of the prompt when the child's window is tight.** The comment says it
  outright: *"The `SystemLanguageModel` context is tight; structural notation here would crowd out
  the actual text to analyze."*
- **Validate the child's answer before you trust it.** The hallucination filter — drop any extracted
  term that does not literally occur in the source — is four lines and it is the difference between a
  consultant and an oracle. **Do this in a phone-a-friend tool too**, before you return the string.
  Everything a consultant says becomes context the parent reasons from confidently.
- **The session is a local `let`. It dies at the end of the function.** That is the whole lifecycle.

Origami also caches before consulting — `TermModel.explain` consults a project-wide lookup table
first and *"skip[s] the LLM call entirely"* on a hit (✅ `Terms/TermModel.swift:87-99`). For a
consultant whose answers are stable for a given input, a dictionary in front of the child is the
cheapest optimisation available.

### 3.6 ⚠️ SILENT FAILURE — the consultation that quietly returns nonsense

> ⚠️ **SILENT FAILURE — a failed consultation reaches the parent as ordinary tool output, and the
> parent believes it.**

Consider what happens when the child throws — no Apple Intelligence, guardrail violation, context
exceeded, network gone on a PCC child. You have two choices in `call(arguments:)` and they have
opposite failure modes:

| | Let the error propagate | Catch it and return prose |
|---|---|---|
| Effect on the parent turn | **Aborts.** The framework wraps it in `LanguageModelSession.ToolCallError` and your `catch` gets it | Continues; the parent reads your string as fact |
| Transcript | Rolled back to the previous state by default | Appended normally |
| The user sees | Your error UI | A confident answer built on a fallback |

Apple's own tools take the second route on *recoverable* conditions — `FetchOrigamiTemplate` ends
`return "No template available. Please try your best to generate folding instructions."`
(✅ `CraftTools.swift:30`). That is the right shape when the fallback is honest and the model is told
what happened. It is the wrong shape when your string reads like a real answer.

```swift prelude:guide-context
func call(arguments: Arguments) async throws -> String {
    do {
        let child = LanguageModelSession(profile: TitleSpecialistProfile())
        let title = try await child.respond(to: arguments.projectDescription).content
        // Validate before returning: the parent will treat this as fact.
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.split(separator: " ").count <= 8 else {
            return "The naming specialist returned an unusable title. Ask the person to name it themselves."
        }
        return trimmed
    } catch is CancellationError {
        throw CancellationError()                  // never swallow cancellation
    } catch {
        // Say what happened, in words the parent can act on.
        return "The naming specialist is unavailable right now. Continue without a title."
    }
}
```

Three rules that listing encodes:

1. **Never return a fabricated success.** `return "Untitled Project"` on failure teaches the parent
   that the consultation worked. Say it failed, in a sentence the parent can route around.
2. **Never swallow `CancellationError`.** Origami treats cancellation as a first-class non-error
   outcome everywhere (✅ `catch is CancellationError` at eight distinct sites in
   `Orchestrator.swift`, with `try Task.checkCancellation()` after each stream and
   `currentTask?.cancel()` at the head of every event). A child session that eats cancellation makes
   the parent turn un-cancellable.
3. **Bound the child.** A consultant with no `maximumResponseTokens` and no timeout can stall the
   parent's turn indefinitely, and the user is looking at a spinner attributed to the parent.

### 3.7 The cost you cannot see: a child is a cold start

The child session has **no KV cache**. It prefills its instructions and your arguments from scratch,
every single time.

> ✅ **VERIFIED** — Apple's KV-caching article, on restoring a session: *"The session starts **without
> a KV cache**, so the model **reprocesses the full transcript** on the first call."* The same is
> necessarily true of a freshly constructed one.

For a small consultant that is a rounding error. For a consultant with a 900-token instruction block
called on every turn, it is not — you are paying that prefill every time, forever, and unlike the
parent's transcript it never gets cheaper. Two mitigations:

- **`prewarm()`**, if the consultation is predictable. ✅ `session.prewarm()` and
  `prewarm(promptPrefix:)` are verified API; Apple's guidance is to call it roughly 1–2 seconds
  ahead. This only helps if you know a consultation is coming.
- **Shrink the instructions.** A consultant's instruction block is paid per call. This is the one
  place where being terse has a directly measurable price attached.

> 🔴 **GAP — nobody has published a cost comparison between the two patterns.** We can say what each
> one is charged for (baton-pass: one full re-prefill at the switch, then append-only; phone-a-friend:
> a fresh child prefill per consultation, plus two entries in the parent). We **cannot** give you a
> crossover point, because no Apple or community measurement compares them on the same workload.
> Resolving this needs an Instruments trace of both shapes on one device — the Foundation Models
> template reports **Total, Consumed, Generated, and Cached Tokens** for a request. The KV-caching page
> defines cache hit rate as cached input tokens divided by total input tokens, which is exactly the
> instrumentation required (✅ [direct Apple Markdown captured 2026-09-22](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/notes/web/apple-foundation-models-runtime-performance-2026-09-22.md)).
> **Safe default meanwhile: use phone-a-friend for anything called less than once per turn on average,
> baton-pass for a mode the conversation stays in.**

---

## 4. Choosing: shared context versus isolation

The trade-off is not "which is more powerful". Both are three dozen lines of Swift. The trade-off is
**what you are willing to pay for the second model knowing things.**

### 4.1 The decision, laid out

| Question | Baton-pass | Phone-a-friend |
|---|---|---|
| Does the second model need the conversation? | **Yes — it gets all of it** | **No — it gets your arguments** |
| Who answers the user? | The receiving profile | The parent, always |
| Cost at the moment of handoff | **Full prefix invalidation** — instructions rewritten, whole transcript re-prefilled; more if the model changes too | One child prefill (instructions + arguments), no parent invalidation |
| Cost thereafter | Append-only, until the next switch | Paid again on every consultation |
| Bound on injected tokens | None — the receiving profile inherits everything | Whatever the child returns; cap it with `maximumResponseTokens` |
| Prompt-injection blast radius | Shared: poisoned context reaches both profiles | Contained: the child never sees the conversation |
| Reversibility | Give each profile a tool back | Automatic — the child is gone |
| Debuggability | Instructions lane shows distinct regions per profile | Child inferences appear as separate sessions in the trace |
| Natural fit | **Modes** the conversation *stays in* | **Questions** the conversation *asks in passing* |

### 4.2 Three worked calls

**A tutorial generator taking over from brainstorming → baton-pass.** The tutorial writer needs to
know which idea won *and* what the person said about the others ("nothing with glue", "she's six").
Re-deriving that into tool arguments is lossy and the loss is exactly the personalisation that made
the feature worth building. The conversation then stays in tutorial mode for many turns, so you pay
the prefix invalidation once and amortise it.

**Naming a project → phone-a-friend.** Everything the namer needs fits in a sentence. Handing it
twenty turns of craft conversation would cost tokens, add latency, and give it room to editorialise.
It is called once.

**A safety classifier before a destructive action → phone-a-friend, emphatically.** You want the
classifier to see the *action*, not the conversation that argued for it. Isolation is the security
property here: a user who spent ten turns constructing a persuasive frame cannot carry that frame
into the child, because the child's transcript starts empty. (Then do the deterministic check
anyway — see §7.4.)

### 4.3 They compose, and the composition is the common case

Nothing says you pick one. The shape that shows up in real apps is baton-pass for modes and
phone-a-friend for questions inside a mode:

```swift prelude:guide-context
struct CraftProfile: LanguageModelSession.DynamicProfile {
    let orchestrator: CraftOrchestrator

    var body: some DynamicProfile {
        switch orchestrator.mode {
        case .brainstorm:
            Profile {
                BrainstormInstructions()
                SwitchToTutorialModeTool(orchestrator: orchestrator)  // baton
                ConsultTitleSpecialistTool()                          // phone-a-friend
            }
            .model(PrivateCloudComputeLanguageModel())
            .temperature(1.0)

        case .tutorial:
            Profile {
                TutorialInstructions()
                SwitchToBrainstormModeTool(orchestrator: orchestrator) // baton back
                ConvertMeasurementTool()                               // plain tool
            }
            .model(PrivateCloudComputeLanguageModel())
            .reasoningLevel(.deep)
        }
    }
}
```

> 🟡 **RECONSTRUCTED** — the composition. Every element is verified individually; the arrangement is
> ours. Note the budget constraint it runs into immediately: ✅ Apple's *Managing the context window*
> article says ***"Provide no more than three to five tools per request."*** Three tools per profile
> is already at the comfortable limit, and two of them are structural rather than functional. **A
> baton tool and a phone-a-friend tool each consume one of your five slots.** That is a real design
> pressure and it is the strongest practical argument for driving mode changes from UI events (as
> Origami does) and reserving the model's tool budget for work.

### 4.4 Apple's own recap

> ✅ **VERIFIED** — `242:136-137`: *"Baton-pass and phone-a-friend are good tools to have in your
> belt, **but there are other options as well**. For example, the **Foundation Models framework
> utilities package houses a `Skills` type**, which you may be familiar with as **a popular pattern
> for procedural context loading**."*

That third option is §9. Read §8 first, because routing economics is what decides whether any of this
is affordable.

---

## 5. Tool-calling mode as an orchestration control

New in **27.0**. Until this year the model decided entirely on its own whether to call a tool; the
only lever you had was prose. The full protocol-level treatment is in
[Part 2 · `03-tools-and-tool-calling.md`](../../part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md).
This section is the orchestration view: what each mode does *to an agent loop*.

### 5.1 The three modes

> ✅ **VERIFIED** — `GenerationOptions.ToolCallingMode`, from
> `/documentation/foundationmodels/generationoptions/toolcallingmode` (iOS 27.0+ Beta):
>
> ```swift
> struct ToolCallingMode          // Equatable, Sendable, SendableMetatype
>
> static var allowed              // "The model may or may not call tools."
> static var disallowed           // "The model may not call any tool."
> static var required             // "The model must call one or multiple tools."
>
> var kind: GenerationOptions.ToolCallingMode.Kind
> ```
> `Kind` is an enum with cases `allowed`, `disallowed`, `required`.

Note the shape: **a struct with static factories, not a bare enum** — Apple's resilience idiom, so
they can add modes without breaking your switches. Anything you write over `mode.kind` needs an
`@unknown default`.

> ✅ **VERIFIED** — WWDC26 session 242 (`242:140-146`), the semantics and Apple's stated use cases:

| Mode | Semantics | Apple's use case |
|---|---|---|
| **`.allowed`** *(default)* | *"The **default value** is 'allowed', which is **the existing behavior**. The model **may produce a tool call or it may respond directly**."* | *"the option to use when **you just don't know if tools will be necessary or not, which is the most common case**"* |
| **`.disallowed`** | *"**prevents the model from calling tools**."* | *"helpful if **the user navigates into a part of your app where the session's tools are known to be irrelevant**"* |
| **`.required`** | *"**the model can only call tools**."* | *"particularly useful in **agentic systems that represent all actions as tool calls**"* |

The reference `LanguageModel` provider implements the default explicitly, and implements
`.disallowed` in a way worth knowing:

> ✅ **VERIFIED** — real compiled code against the 27.0 SDK, `mlx-swift-lm`,
> `Libraries/MLXFoundationModels/ToolCalling/ToolCallingModeResolution.swift:14-45`:
>
> ```swift
> static func resolve(
>     _ mode: GenerationOptions.ToolCallingMode?
> ) -> GenerationOptions.ToolCallingMode {
>     mode ?? .allowed
> }
>
> static func usesAllowedBehavior(
>     _ mode: GenerationOptions.ToolCallingMode
> ) -> Bool {
>     switch mode.kind {
>     case .allowed:
>         return true
>     case .required, .disallowed:
>         return false
>     @unknown default:
>         return true
>     }
> }
>
> static func enabledToolDefinitions(
>     for mode: GenerationOptions.ToolCallingMode,
>     from definitions: [Transcript.ToolDefinition]
> ) throws -> [Transcript.ToolDefinition] {
>     if usesAllowedBehavior(mode) {
>         return definitions
>     }
>     if mode.kind == .disallowed {
>         return []
>     }
>     guard !definitions.isEmpty else { throw Error.requiredToolsMissing }
>     return definitions
> }
> ```

**`.disallowed` is realised by sending zero tool definitions.** The tools still exist on the session;
the model is simply not told about them for that request. That has an orchestration consequence in
both directions: it *saves* the tokens those definitions cost, and it *changes the prefix*, so
flipping between `.allowed` and `.disallowed` mid-conversation invalidates the KV cache from the tool-
definition block onward. Treat a mode flip as a switch point, same as a profile change (§2.6).

> ⚠️ That is provider behaviour, ✅ verified in compiled code, and it is the best evidence we have —
> but it is **not** documented Apple-framework behaviour. Whether Apple's own inference stack also
> implements `.disallowed` by withholding definitions is 🔴 unverified.

### 5.2 Two places to set it, one precedence rule

> ✅ **VERIFIED** — `242:147-148`: *"**If you're using profiles, you can specify tool calling mode
> with a modifier.** … **If you're not using a profile, tool calling mode can be set via
> `GenerationOptions` when calling `respond(to:)`.**"*

**Without a profile** — `GenerationOptions`:

> ✅ **VERIFIED** — the initializer, iOS 27.0+ Beta:
> ```swift
> init(samplingMode: GenerationOptions.SamplingMode? = nil,
>      temperature: Double? = nil,
>      maximumResponseTokens: Int? = nil,
>      toolCallingMode: GenerationOptions.ToolCallingMode?)
> ```

```swift prelude:guide-context
import FoundationModels

let session = LanguageModelSession(tools: [SearchBooksTool(library: store)]) {
    "You answer questions about the reader's own library. Never answer from memory."
}

// Force at least one tool call for this request.
let response = try await session.respond(
    to: "What gothic novels do I own?",
    options: GenerationOptions(toolCallingMode: .required)
)

// A follow-up answered only from what is already in the transcript.
let summary = try await session.respond(
    to: "Summarize the books you found.",
    options: GenerationOptions(toolCallingMode: .disallowed)
)
```

> ✅ Both call sites are verified in shape from the `ToolCallingMode` documentation page, and the
> `GenerationOptions(toolCallingMode: .required)` spelling appears verbatim in a developer's code on
> the Apple Developer Forums.

> ⚠️ **Overload footgun.** In that four-argument initializer `toolCallingMode` is the **only
> parameter without a default value**. You cannot omit it and still select this overload — omitting
> it resolves to the iOS 26 three-argument
> `init(samplingMode:temperature:maximumResponseTokens:)`. Harmless in practice; it explains a
> compiler complaint that otherwise looks like nonsense. (✅ derived from the two declarations side by
> side in the docs harvest.)

**With a profile** — the modifier:

> ✅ **VERIFIED** — real compiled code against the 27.0 SDK, `mlx-swift-lm`
> `IntegrationTesting/…/ToolCalling/StructuredToolOutputSessionTests.swift:62-79`:
>
> ```swift
>             .model(model)
>             .toolCallingMode(.required)
>             .onToolCall {
>                 toolCallCount += 1
>             }
>         } else {
>             Profile {
>                 Instructions {
>                     "Use the latest tool output. Return its requiredToken field exactly and no other text."
>                 }
>             }
>             .model(model)
>             .toolCallingMode(.disallowed)
> ```

Apple's own Frameworks Engineer recommends the modifier form for strict retrieval:

> ✅ **VERIFIED** — Developer Forums thread 833692 ("Strict RAG implementation via `.required` tool
> calling and temp=0"), Apple Frameworks Engineer, marked Recommended: *"You can use
> `.toolCallingMode` with `DynamicProfiles` for this."*

**Which wins:**

> ✅ **VERIFIED** — verbatim from Apple's dynamic-profiles article:
> *"When the same modifier appears at multiple levels, a three-tier precedence rule determines which
> value to use — from highest to lowest priority:*
> 1. ***Call-site arguments** — Generation options you pass directly to `respond(to:options:)`
>    override all profile and dynamic profile modifiers.*
> 2. ***Innermost dynamic profile or profile modifier** — The modifier closest to the subprofile
>    declaration overrides a dynamic profile.*
> 3. ***Dynamic profile modifiers** — Act as defaults that apply to all subprofiles unless the
>    modifier is overridden by a subprofile."*

> ✅ **RUNTIME-CONFIRMED, 2026-09-16.** Stable macOS 27 and the physical iPhone confirmed both
> directions: profile-required plus call-site-disallowed produced `toolCalled=false` and
> `toolRan=false`; profile-disallowed plus call-site-required ran the tool and then ended with
> `contextSizeExceeded(4096,4099)`. The call-site value wins exactly as the article states.

> ⚠️ **SILENT FAILURE — a call-site `options:` silently disables your loop exit.** If you have built
> the `.required` exit into your profile (§6.2) and then pass
> `GenerationOptions(toolCallingMode: .disallowed)` at a call site out of habit — or, worse,
> `.required` — the profile's carefully conditioned mode is overridden and nothing tells you. There is
> no warning, no log line, and the symptom is either "the agent never calls tools" or "the agent never
> stops". **Pick one surface per session and stay on it.** If you use profiles, never pass
> `toolCallingMode` at a call site.

### 5.3 What each mode is for, in an agent

Recast for orchestration rather than for a single request:

- **`.allowed`** — the conversational default and what you want for anything a user is talking to.
  The model decides. Your job is prose and tool descriptions.
- **`.disallowed`** — the *finisher*. When the loop has gathered what it needs, flipping to
  `.disallowed` makes the next inference structurally incapable of calling anything, so it must
  answer. This is stronger than "the model may now answer", and it is what Apple's reference provider
  test does. Also the right mode for a read-only mode of your app where the session's tools are
  irrelevant.
- **`.required`** — the *worker*. Apple's stated use case is *"agentic systems that represent all
  actions as tool calls"* (`242:146`), which is exactly the architecture where every step the agent
  takes is a tool invocation and prose is only produced at the very end. It is also an unbounded loop.

---

## 6. ⚠️ `.required` is a `while` loop and you supply the exit

> ⚠️ **SILENT FAILURE — the most consequential one in the agentic API. If you take one thing from
> this guide, take this.**
>
> ✅ **VERIFIED** — WWDC26 session 242 (`242:149-150`), verbatim: *"**Here's the most important thing
> to remember. When tool calling is required, the model is essentially in a while loop — it is your
> job to ensure that there is an exit condition of some kind.**"*
>
> ✅ **VERIFIED** — the same warning appears **in writing**, on both the `ToolCallingMode`
> documentation page and Apple's tool-calling article: *"When you set the mode to `required`, you
> must define an exit condition by either throwing an error from a tool's `call(arguments:)` method
> or by changing the mode dynamically using a `LanguageModelSession.DynamicProfile`; **otherwise, the
> model continues to call the tool.**"*

Read the last clause literally, because every word of it is load-bearing.

**The model does not eventually give up.** There is no documented iteration cap. `respond(to:)` does
not return. Tokens accumulate until the context window is exhausted. Your tool is executed over and
over — and **if your tool has side effects, it performs them over and over.** A `.required` loop
around a tool that sends a message, writes a file, or charges a card is not a hang; it is a
data-corruption bug with a spinner on top.

What the user sees is a spinner. What you see in an Instruments trace is an unbounded stack of model
inferences under a single request — which is exactly what the tree detail view is for:

> ✅ **VERIFIED** — `243:87-89`: *"**Session 1 had two requests.** The first one was kicked off by the
> prompt starting with 'Please generate 3 craft ideas.' That request was made up of **two model
> inferences and a few tool calls**."* One `respond(to:)` is **not** one inference. Under `.required`
> the fan-out has no ceiling but the one you install.

Apple documents exactly **two** exits. Wire one. Always. In production, wire both (§6.4).

### 6.1 Exit A — conditionalise the mode on a variable the loop moves

> ✅ **VERIFIED** — `242:151-152`: *"One good option is to **conditionalize the tool call mode on a
> variable**. Here, we're **requiring tool calls until the model calls the database tool**."*

Apple's own documentation sample, verbatim:

> ✅ **VERIFIED** — from the `GenerationOptions.ToolCallingMode` documentation page:

```swift prelude:guide-context
import FoundationModels

extension SessionPropertyValues {
    @SessionPropertyEntry
    var toolCallCount: Int = 0
}

struct RecipeDynamicProfile: LanguageModelSession.DynamicProfile {
    @SessionProperty(\.toolCallCount)
    var toolCallCount

    var body: some LanguageModelSession.DynamicProfile {
        Profile {
            BreadDatabaseTool()
        }
        .toolCallingMode(toolCallCount < 1 ? .required : .allowed)
        .onToolCall {
            toolCallCount += 1
        }
    }
}
```

```swift prelude:guide-context
let session = LanguageModelSession(profile: RecipeDynamicProfile())
let response = try await session.respond(to: "What's a good sourdough recipe?")
```

Three moving parts, all load-bearing:

1. **A session property holds the counter.** It must survive across loop iterations and be visible to
   both the profile and the lifecycle callback. A local `var` on the profile struct would be reset on
   every re-evaluation. (✅ `@SessionPropertyEntry` with no parentheses, attached to a `var` with an
   initial value, is verified in compiled code:
   `StructuredToolOutputSessionTests.swift:14-18`. **All session properties are mutable and must have
   an initial value** — `242:107`.)
2. **`onToolCall` increments it.** It fires once per tool invocation, at the boundary. Imperative work
   belongs in lifecycle modifiers, never in `body`.
3. **`body` reads it and picks the mode.** Because the body is re-evaluated before each model
   request, the *next* iteration sees a different mode and the model is free to stop.

The reference implementation in compiled code goes one step further and switches to `.disallowed`:

> ✅ **VERIFIED** — `mlx-swift-lm`, `StructuredToolOutputSessionTests.swift:47-79`, compiled against
> the 27.0 SDK:

```swift illustrative
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
private struct StructuredToolOutputProfile: LanguageModelSession.DynamicProfile {
    let model: MLXLanguageModel

    @SessionProperty(\.structuredToolOutputCallCount)
    var toolCallCount

    var body: some LanguageModelSession.DynamicProfile {
        if toolCallCount == 0 {
            Profile {
                Instructions {
                    "Call the lookup tool once. After it returns, answer with the value of its requiredToken field exactly."
                }
                StructuredLookupTool()
            }
            .model(model)
            .toolCallingMode(.required)
            .onToolCall {
                toolCallCount += 1
            }
        } else {
            Profile {
                Instructions {
                    "Use the latest tool output. Return its requiredToken field exactly and no other text."
                }
            }
            .model(model)
            .toolCallingMode(.disallowed)
        }
    }
}
```

with the counter declared as

```swift compile:27 imports:FoundationModels
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
extension SessionPropertyValues {
    @SessionPropertyEntry
    var structuredToolOutputCallCount: Int = 0
}
```

and asserted from outside the session afterwards:

```swift prelude:guide-context
#expect(session.properties.structuredToolOutputCallCount == 1)
```

Four things worth stealing from that test:

- **`.disallowed`, not `.allowed`, for the exit branch.** The second inference becomes structurally
  incapable of looping. "The model may now answer" is a weaker guarantee than "the model cannot do
  anything else".
- **The tool is removed from the exit profile entirely.** Nothing to be tempted by.
- **`session.properties.<name>` is readable from outside the session** — ✅ verified, and it is how
  you write a regression test for "the loop terminated exactly once".
- **The two branches are an `if/else`**, which is the sanctioned conditional shape in the profile
  builder. ✅ Origami uses both `switch` and nested `if/else`; the builder enforces exactly one active
  `Profile`.

Two failure modes of Exit A, neither obvious:

> ⚠️ **`body` must be pure.** It is re-evaluated at least once per model request — Apple says *"the
> body of a `DynamicProfile` is re-evaluated each time the model is prompted"* (✅ `242:59`) — and a
> third-party instrumented count found **7 evaluations across 3 turns** (community-measured,
> `coreai-model-zoo/knowledge/dynamic-profiles-local-models.md`). Read your counter there; never
> mutate. A `body` that increments a counter will terminate a loop it should not have terminated, or
> not terminate one it should, and the arithmetic will look correct in review.

> ⚠️ **The counter is not a fuse unless it counts the right thing.** `toolCallCount < 1` bounds the
> loop *given that `onToolCall` fires* — which it does, on invocation, so it is sound. But if you
> condition on a flag the tool itself sets inside `call` (say `hasAnswer`), and the tool throws before
> setting it, you are back to an unbounded loop with a tool that fails every time. **Prefer a plain
> invocation counter, or combine both:** `toolCallCount < 8 && !hasAnswer`.

### 6.2 Exit B — a "final answer" tool that throws

> ✅ **VERIFIED** — `242:153-154`: *"A second, **more forceful** option is to **equip your model with
> a final answer tool that throws an error**. **Throwing an error aborts the tool calling loop and
> immediately returns control flow to you.**"*

> 🟡 **RECONSTRUCTED** — the code below. The shape follows directly from that sentence plus the ✅
> verified `Tool` and `LanguageModelSession.ToolCallError` declarations. Apple showed this on a
> slide; no source was published, and **no Apple sample project sets `toolCallingMode` at all**, so
> there is no first-party call site to copy.

```swift compile:27
import FoundationModels

/// Thrown to break out of a `.required` tool-calling loop.
struct FinalAnswer: Error {
    let text: String
}

struct FinalAnswerTool: Tool {
    let name = "finalAnswer"
    let description = """
        Call this when you have everything you need and are ready to answer. \
        Put the complete answer for the person in `answer`.
        """

    @Generable
    struct Arguments: Sendable {
        @Guide(description: "The complete final answer, in plain prose.")
        var answer: String
    }

    func call(arguments: Arguments) async throws -> String {
        throw FinalAnswer(text: arguments.answer)   // aborts the loop
    }
}
```

At the call site you unwrap it, because the framework wraps whatever your tool throws:

```swift prelude:guide-context
let session = LanguageModelSession(tools: [SearchBooksTool(library: store), FinalAnswerTool()]) {
    "Answer only from tool results. When you are done, call finalAnswer."
}

func ask(_ prompt: String) async throws -> String {
    do {
        let response = try await session.respond(
            to: prompt,
            options: GenerationOptions(toolCallingMode: .required)
        )
        return response.content          // reached only if the loop ended some other way
    } catch let error as LanguageModelSession.ToolCallError {
        if let final = error.underlyingError as? FinalAnswer {
            return final.text            // the intended exit
        }
        throw error
    }
}
```

> ✅ **VERIFIED** — the unwrapping shape is Apple's own, from the tool-calling article:
> ```swift
> } catch let error as LanguageModelSession.ToolCallError {
>     print(error.tool.name)
>     if case .databaseIsEmpty = error.underlyingError as? SearchBreadDatabaseToolError { … }
> }
> ```
> ✅ `LanguageModelSession.ToolCallError` is iOS 26.0+, **no watchOS**, with `.tool`,
> `.underlyingError` and `.errorDescription`.

Exit B is "more forceful" because it does not depend on the model *choosing* to stop — the act of
declaring completion is what stops it. It is also the one that eats your transcript.

### 6.3 The transcript consequence of Exit B

> ✅ **VERIFIED** — `242:155`: *"**By default, when you throw an error from a tool, or when you cancel
> a response, your session's transcript will roll back to its previous state.**"* And from the
> tool-calling article: *"When errors are thrown from a tool, the framework rolls back the transcript
> to a previously known valid state."*

So Exit B **discards the turn by default**. The prompt, the tool calls, and the tool outputs that led
to the answer are gone from `session.transcript`; only your caught `FinalAnswer.text` survives. For a
one-shot agentic query that is often exactly right — you wanted the answer, not the scaffolding. For
a conversation whose next turn must remember what was found, it is a data-loss bug that presents as
the model "forgetting".

If you need the entries, keep them:

> ✅ **VERIFIED** — `TranscriptErrorHandlingPolicy`, iOS 27.0+ Beta:
> ```swift
> struct TranscriptErrorHandlingPolicy      // Sendable, SendableMetatype
> static let preserveTranscript   // "Keep the current transcript as is."
> static let revertTranscript     // "Revert the transcript back to the state it was in just before
>                                 //  the most recent request."
> ```
> ✅ Settable on the session (`var transcriptErrorHandlingPolicy: TranscriptErrorHandlingPolicy`) and
> available as a profile modifier `transcriptErrorHandlingPolicy(_:)`. `242:158-159`: *"If you're
> using profiles, you can now set `transcriptErrorHandlingPolicy` using a modifier. If you're not
> using a profile, you can set it directly on your session."*

```swift prelude:guide-context
// Non-profile form.
let session = LanguageModelSession(tools: [SearchBooksTool(library: store), FinalAnswerTool()])
session.transcriptErrorHandlingPolicy = .preserveTranscript

// Profile form.
Profile { AgentInstructions() }
    .transcriptErrorHandlingPolicy(.preserveTranscript)
```

> ⚠️ **SILENT FAILURE — `.preserveTranscript` makes transcript sanity your problem.**
>
> ✅ **VERIFIED** — `242:163-164`: *"When using `.preserveTranscript`, **the onus is on you to put
> your transcript back into a good state if you intend to continue using your session.**"*
>
> ✅ **VERIFIED** — the tool-calling article adds the specific hazard: ***"When preserving the
> transcript, the last entry may be partially generated."***
>
> A partially-generated trailing entry is not an error the next `respond(to:)` reports. It is
> *context*. The model reads a truncated response, or a `.toolCalls` entry with no matching
> `.toolOutput`, and reasons confidently from it. Nothing throws; the answers just get strange, in a
> way that looks like model quality rather than like a bug you introduced.

Repair uses the other 27.0 change — `session.transcript` is now settable:

> ✅ **VERIFIED** — `final var transcript: Transcript { get set }`, and `242:165-167`: *"the
> `transcript` property on session is now mutable. Remember though, **you can only modify the
> transcript when the session's `isResponding` property is `false`. Attempting to mutate the
> transcript during a response is a programmer error.**"*

“Programmer error” identifies a caller bug, but the public API represents this condition with
`LanguageModelSession.Error.transcriptMutationWhileResponding`; it is not evidence that the process
must trap.[^transcript-mutation-error] Origami guards on `session.isResponding` for re-entrancy
(✅ `Orchestrator.swift:367`); do the same before any assignment.

```swift prelude:guide-context
// Repair after an aborted turn, under .preserveTranscript.
guard !session.isResponding else { return }

// Drop a trailing tool-call entry that never received its output.
if case .toolCalls = session.transcript.last {
    session.transcript.removeLast()
}
```

### 6.4 Compose both, and add a fuse

| | Exit A — conditional mode | Exit B — throwing final-answer tool |
|---|---|---|
| Requires | a `DynamicProfile` + session property (27.0) | any session; works with `GenerationOptions` (27.0) |
| Bounded by | your counter | the model deciding it is finished |
| Transcript after | intact — the turn completes normally | **rolled back by default**; `.preserveTranscript` then repair |
| Answer arrives as | `response.content` | your error payload, caught at the call site |
| Fails when | the state variable never moves | the model never calls `finalAnswer` |
| Best for | "call retrieval exactly once, then answer" | multi-step agents that decide when they are done |

For anything long-running, use **both**: Exit B as the normal path, Exit A as a hard iteration cap.

```swift prelude:guide-context
extension SessionPropertyValues {
    @SessionPropertyEntry
    var agentToolCallCount: Int = 0
}

struct BoundedAgentProfile: LanguageModelSession.DynamicProfile {
    @SessionProperty(\.agentToolCallCount)
    var toolCallCount

    private let maxIterations = 8

    var body: some DynamicProfile {
        Profile {
            Instructions {
                """
                Work step by step. Every action is a tool call. \
                When you have the complete answer, call finalAnswer with it.
                """
            }
            SearchTool()
            FetchTool()
            FinalAnswerTool()
        }
        // The fuse: past the cap, the model cannot call anything and must answer.
        .toolCallingMode(toolCallCount < maxIterations ? .required : .disallowed)
        .onToolCall {
            toolCallCount += 1
        }
        .transcriptErrorHandlingPolicy(.preserveTranscript)
    }
}
```

> 🟡 **RECONSTRUCTED** — the composition. Every modifier and macro in it is ✅ verified individually;
> the arrangement is ours. Note that a model which finishes properly exits through `finalAnswer`, and
> a model that has gone into a delusional retry loop still terminates at iteration 8 with whatever it
> can say. **Neither exit alone gives you both properties.**

### 6.5 `.required` with an empty toolset

The reference provider treats this as an error:

> ✅ **VERIFIED** — `ToolCallingModeResolution.swift`:
> ```swift
> guard !definitions.isEmpty else { throw Error.requiredToolsMissing }
> ```

On Apple's own stack the observed symptom is uglier:

> ✅ **VERIFIED** — Developer Forums thread 837226, iPhone 17 Pro Max on iOS 27 beta 3, **FB23643759,
> still open**. Console output, verbatim:
> ```
> InferenceError::hostFailed::InferenceError::inferenceFailed::TokenGenerationCore.GuidedGenerationError.invalidConfiguration(errorMessage: "Tool Choice requires tools") in response to ExecuteRequest
> Error during session.respond. description="The operation couldn't be completed. (FoundationModels.LanguageModelError error -1.)"
> ```
> The triggering code passed `tools: [tool]` to the session **and** `toolCallingMode: .required`, so
> the tool array was not reaching the inference layer. **Watch for the string "Tool Choice requires
> tools" in the console** — it means "required mode, empty toolset", regardless of what you thought
> you passed.

> ✅ **Probe-verified, with destination drift.** On the iOS 27 Simulator (2026-07-31), a genuinely
> empty toolset threw the generic NSError-domain code `-1`, did not cast to Swift
> `LanguageModelError`, and wrapped underlying errors. On iPhone 15 Pro / iOS build `24A5408d`
> (2026-08-20), it instead threw typed `LanguageModelError.unsupportedGenerationGuide`, code 6.
> Both reject without hanging; the bridge is not consistent across destinations. Full error-shape
> analysis in 17.3 §6.3. **The safe default stands: assert your toolset is non-empty
> before you set `.required`, and treat an error you cannot classify as retry-once-then-degrade —
> logging both Swift type and NSError domain/code.**

> 🔴 **GAP — there is no first-party call site for `toolCallingMode` anywhere.** Origami, Book Tracker
> and the Core Spotlight sample all ship without it; Origami, the most agentic of the three, steers
> entirely with prose and with tools appearing and disappearing from the profile. The declarations are
> verified, the WWDC narration is unambiguous, and the MLX reference provider implements the mode in
> compiled code — but if you are looking for Apple's own production usage, there is not one yet.

---

## 7. Tool-as-consent-request: Apple's Origami pattern

This pattern appears in **no WWDC session**. It exists only in Apple's Origami sample, it is fully
worked, and it solves a problem every agentic app hits within a week: **the model wants to do
something to the user's data, and a human should say yes first.**

The trick is that the tool does not *ask* and wait. It **records a proposal, tells the model a human
has been asked, and returns immediately.** The tool-calling loop finishes normally. The UI swaps a
text field for Yes/No. Whichever the user taps produces a **synthesized follow-up turn** that tells
the model what happened and asks it to continue.

Everything in this section is ✅ **VERIFIED** — read this session directly from the extracted archive
`OrigamiCraftingADynamicTutorialForAppleIntelligence` (`IPHONEOS_DEPLOYMENT_TARGET = 27.0`,
`SWIFT_VERSION = 6.0`).

### 7.1 The tool

> ✅ **VERIFIED** — `Origami/Coach/MovePhotoToStepTool.swift`, in full:

```swift prelude:guide-context
/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
A tool the coach model calls to move a progress photo to the correct
 step of a tutorial, prompting the user to confirm the change.
*/

import FoundationModels
import os

struct MovePhotoToStepTool: Tool {
    let name = "movePhotoToStep"
    let description =
        "Move a photo the user gave you to the correct step of a tutorial."

    var orchestrator: Orchestrator

    @Generable
    struct Arguments: Sendable {
        @Guide(description: "Section to move the photo TO")
        var tutorialSectionIndex: Int

        @Guide(description: "Step to move the photo TO")
        var tutorialStepNumber: Int
    }

    func call(arguments: Arguments) async throws -> String {
        logger.debug(
            "Move photo to section \(arguments.tutorialSectionIndex) step \(arguments.tutorialStepNumber)"
        )
        await orchestrator.proposeMoveToStep(
            section: arguments.tutorialSectionIndex,
            step: arguments.tutorialStepNumber
        )
        return "Asked the user to confirm moving to step \(arguments.tutorialStepNumber)."
    }
}
```

Look at the return string. It is not `"Moved."` and it is not `"Pending."` — it is
**`"Asked the user to confirm moving to step N."`** The model's next reasoning step reads that as a
fact about the world: a human has been asked. That single sentence is what stops the model from
either claiming the move happened or trying again.

And the tool is registered exactly where you would expect, in the coach persona's instructions,
alongside the prose that names it:

> ✅ **VERIFIED** — `Origami/Coach/CoachInstructions.swift:12-36`:

```swift illustrative
struct CoachInstructions: DynamicInstructions {
    let orchestrator: Orchestrator

    var body: some DynamicInstructions {
        Instructions {
            """
            You are an expert craft tutorial coach.
            When you are asked to valuate the user's in-progress work \
            from a photo: compare their work against the tutorial step \
            they appear to be on and provide specific, constructive feedback.
            …
            If the photo appears like they did the step incorrectly, \
            first check if it might be correct for a **different** step \
            ahead in the tutorial. Next help them find the correct step or else \
            kindly guide them towards a fix. To move a photo to the correct step. \
            call the movePhotoToStep tool.
            """
        }

        CalculatePaperSize()
        ConvertMeasurement()
        MovePhotoToStepTool(orchestrator: orchestrator)
    }
}
```

(Note in passing: three tools appear and disappear atomically with the persona. In tutorial mode the
session has `FetchOrigamiTemplate` only; the instant `orchestrator.tutorialReady` flips, it has these
three and not that one. That is §2's "swap tools with the profile" made concrete — and it is why
`tutorialReady` is a computed property over `coach.isActive`, ✅ `Orchestrator.swift:99-101`.)

### 7.2 The proposal

> ✅ **VERIFIED** — `Origami/Models/Orchestrator.swift:487-494`, comment included because it explains
> the UI contract:

```swift prelude:guide-context
    /// Called by the `MovePhotoToStepTool` tool when the model decides the user is ready
    /// to advance. Stores the proposed section and step on the coach so the UI
    /// can surface a "Move to Step N?" with a Yes or No confirmation in place of the
    /// follow-up text field.
    func proposeMoveToStep(section: Int, step: Int) {
        coach.pendingMoveTo = step
        coach.pendingMoveSection = section
    }
```

Two lines. The tool's entire side effect is setting two optionals on an `@Observable` object. It does
not block, it does not `await` a user, it does not throw.

### 7.3 The UI branch

> ✅ **VERIFIED** — `Origami/Coach/CoachView.swift:38-44`:

```swift prelude:guide-context
                        if showActions {
                            if let target = orchestrator.coach.pendingMoveTo {
                                MoveStepConfirmRow(targetStep: target)
                            } else {
                                CoachActionRow(followUpText: $followUpText, photo: activePhoto)
                            }
                        }
```

The pending proposal **replaces** the follow-up composer rather than appearing next to it. There is
exactly one thing to do next, and it is a binary choice.

> ✅ **VERIFIED** — `Origami/Coach/CoachView.swift:127-157`, the row itself, condensed to its
> structure:

```swift prelude:guide-context
struct MoveStepConfirmRow: View {
    @Environment(Orchestrator.self) private var orchestrator
    let targetStep: Int
    var photo: Photo? = nil

    var body: some View {
        HStack(spacing: 12) {
            Text("Move progress photo to Step \(targetStep)?")
            Button { orchestrator.cancelPendingMove(photo: photo)  } label: { Text("No")  }
            Button { orchestrator.confirmPendingMove(photo: photo) } label: { Text("Yes") }
        }
    }
}
```

The question is phrased in the user's terms — *"Move progress photo to Step 4?"* — not in the model's
(`tutorialSectionIndex: 1, tutorialStepNumber: 4`). Your tool's `@Generable` arguments are an
internal wire format; the consent prompt is UI copy. Do not leak one into the other.

### 7.4 Yes — the synthesized follow-up turn

This is the interesting half.

> ✅ **VERIFIED** — `Origami/Models/Orchestrator.swift:496-545`, in full:

```swift prelude:guide-context
    /// User tapped "Yes" on the move confirmation. Re-attache the photo to
    /// the proposed section and step, then re-run coaching at the new step,
    /// passing along the prior coach text so the model knows it just
    /// honored the move.
    func confirmPendingMove(photo: Photo? = nil) {
        let photoToMove = photo ?? activeCoachPhoto
        let targetStep: Int
        if let coachTarget = coach.pendingMoveTo {
            targetStep = coachTarget
        } else if let photoTarget = photoToMove?.pendingMoveTo {
            targetStep = photoTarget
        } else {
            return
        }
        let targetSection =
            coach.pendingMoveSection
            ?? photoToMove?.pendingMoveToSection
            ?? photoToMove?.tutorialSectionIndex
            ?? coach.activeSectionIndex
            ?? highlightedSectionIndex
            ?? 0
        let priorText: String? = {
            if case .responded(let text) = coach.state, !text.isEmpty {
                return text
            }
            return photoToMove?.coachFeedback
        }()
        guard let movedPhoto = photoToMove else { return }
        movedPhoto.tutorialSectionIndex = targetSection
        movedPhoto.tutorialStepNumber = targetStep
        movedPhoto.pendingMoveTo = nil
        movedPhoto.pendingMoveToSection = nil
        coach.pendingMoveTo = nil
        coach.pendingMoveSection = nil
        let note = priorText.map {
            """
            The user accepted moving this photo, so it has been re-attached to section \(targetSection) step \(targetStep).
            Your prior feedback was: "\($0)".
            Please give them fresh feedback for the new step.
            """
        }
        send(
            .progressPhoto(
                [movedPhoto],
                sectionIndex: targetSection,
                stepNumber: targetStep,
                note: note
            )
        )
    }
```

Five decisions in there, each of which you will otherwise get wrong on the first attempt:

**1. The app performs the mutation, not the model.** `movedPhoto.tutorialSectionIndex = targetSection`
runs in *your* code, after *your* user said yes. The tool never touched the data. That is the security
property, and it is why this pattern survives a prompt-injection review: the model's influence stops
at "propose".

**2. The pending state is cleared on *both* objects before dispatch.** `coach.pendingMoveTo = nil`
and `movedPhoto.pendingMoveTo = nil`. A stale pending flag means the UI shows the Yes/No row again
after the move already happened.

**3. The proposal is defended against staleness with a fallback chain.** `targetSection` falls
through six sources, ending at `0`. That looks paranoid until you remember the proposal was made by a
model, one or more UI events ago, and the user may have navigated in between.

**4. The follow-up turn tells the model what it needs to know, in three sentences.** Read the `note`
again:

```
The user accepted moving this photo, so it has been re-attached to section N step M.
Your prior feedback was: "…".
Please give them fresh feedback for the new step.
```

*What happened* · *what you said before* · *what to do now*. It restates the prior feedback because
the coach's state may have been cleared, and it ends with an explicit instruction so the model does
not simply acknowledge. **A synthesized turn is a prompt you wrote on the user's behalf; write it
like one.**

**5. It goes through the same event pipeline as everything else.** `send(.progressPhoto(…))` is the
ordinary "user added a progress photo" event with a `note` attached. Consent resumption is not a
special code path — it is a normal event with extra context.

> ✅ **VERIFIED** — the `note` reaches the model as a prompt fragment, via
> `Origami/Models/Orchestrator.swift:596-616`, where the coaching prompt is assembled:
>
> ```swift
> let prompt = Prompt {
>     if let note {
>         note
>     }
>     "I'm on section \(sectionIndex) step number \(stepNumber) of the tutorial. How does this look?"
>     imagePrompts
>     "For reference the step reads: \(stepContent ?? "")"
> }
> let stream = session.streamResponse(to: prompt)
> ```
>
> Note the `Prompt` builder accepting an `if let` binding, an interpolated string, **an inline
> `[Prompt]` array** (`imagePrompts`) and another string — all four forms in one builder.

### 7.5 No — the decline is also a turn

> ✅ **VERIFIED** — `Origami/Models/Orchestrator.swift:547-561`, in full:

```swift prelude:guide-context
    /// User tapped "No" on the move confirmation. Clear the pending move
    /// and tell the model the user declined so it can respond.
    func cancelPendingMove(photo: Photo? = nil) {
        let photoToClear = photo ?? activeCoachPhoto
        photoToClear?.pendingMoveTo = nil
        photoToClear?.pendingMoveToSection = nil
        send(
            .coachFollowUp(
                """
                The user declined moving the photo and wants to stay on the current step.
                Please reconfirm or refine your feedback for the current step.
                """
            )
        )
    }
```

**A decline is not a no-op.** If you simply clear the flag and return, the transcript's last
meaningful entry is a tool output saying *"Asked the user to confirm…"* and the model is left waiting
for an answer that never arrives — which is exactly the shape of §7.7's silent failure. Telling the
model "they said no, here is what to do instead" closes the loop and gives it a productive next move.

Note also what the decline handler does *not* do: it does not tell the model it was wrong. *"The user
declined … and wants to stay on the current step"* is a fact about the user's preference, not a
correction. That framing keeps the coach from apologising for three paragraphs.

### 7.6 Why not block inside `onToolCall`?

There is an obvious-looking alternative: use the `onToolCall` lifecycle modifier as an approval gate,
`await` the user inside it, and throw if they decline.

> **Community sketch**, attributed to WWDC26 session 347 (a session **not** in our transcript
> corpus), via `coreai-model-zoo/knowledge/agentic-security-checklist.md`:
> *"`.onToolCall` — fires when the model emits a tool call, **before the executor runs it**. **If the
> callback throws, the tool never runs** and control returns to the loop. → the single chokepoint for
> confirmations."*
>
> ```swift
> // sketch from 347 — NOT verified against a compiling source
> profile.onToolCall { call in
>     guard call.toolName == "OrderTea" else { return }
>     guard await confirmWithUser(call) else { throw CancelledByUser() }
> }
> ```

✅ **RESOLVED on the signature (2026-07-29):** `onToolCall`'s closure **is** `async throws` — both
the zero-argument and the `(Transcript.ToolCall)` overloads are declared
`@escaping … async throws -> Void` (✅ **SDK-verified**,
`FoundationModels-27.0-macos.swiftinterface:1008-1014`) — so the sketch *compiles*: you may `await
confirmWithUser(call)` and you may throw. The effect is now measured: on 2026-09-16 the Mac and
physical-device probes both observed that the tool body did not run, `respond` threw
`ToolCallError`, and the default transcript reverted to its instructions entry. The earlier
community phrase "returns to the loop" is wrong for these runtimes. This is a **turn-level abort**,
not an in-loop denial that lets the model choose another action.

**Origami's shape is better for user-facing consent**, for three
reasons that hold regardless:

1. **It does not hold the tool-calling loop open across human latency.** A user may take thirty
   seconds, or switch apps, or never answer. Origami's turn completes in the normal amount of time
   and the app is idle while the human thinks.
2. **A throw rolls the transcript back** (§6.3) unless you have opted into `.preserveTranscript` and
   accepted the repair burden. Origami's decline path keeps the whole exchange and adds to it.
3. **The refusal is legible to the model.** A blocked tool leaves the model guessing why. An explicit
   *"the user declined and wants to stay"* turn tells it.

Use `onToolCall` for *policy* gates you can decide synchronously — is this tool allowed in this app
state, is this user entitled, is the argument within bounds. Use the propose/confirm pattern for
anything that requires a human to look at something.

### 7.7 ⚠️ SILENT FAILURE — the consent nobody answers

> ⚠️ **SILENT FAILURE — a pending proposal with no resolution path leaves the model believing a
> question is outstanding, forever.**

The transcript now contains a tool output saying *"Asked the user to confirm moving to step 4."* If
the user does none of Yes / No — they scroll away, background the app, navigate to another project —
that sentence stays in the history as the most recent thing that happened. Every subsequent turn is
generated against a context in which a confirmation is pending. Models handle this badly: they ask
again, they assume it was approved, or they refuse to move on. Nothing throws, and nothing in your
crash reporting will ever show it.

Three defences, in order of how much they cost you:

```swift prelude:guide-context
// 1. Clear the proposal on any navigation that ends the consent context.
func dismissCoach() {
    coach.pendingMoveTo = nil
    coach.pendingMoveSection = nil
    send(.dismissCoach)
}
```

```swift prelude:guide-context
// 2. Treat abandonment as an implicit decline when the user does something else.
//    Any new user turn while a proposal is pending should resolve it first.
func sendFollowUp(_ text: String) {
    if coach.pendingMoveTo != nil {
        cancelPendingMove()          // synthesizes the "declined" turn
    }
    send(.coachFollowUp(text))
}
```

```swift illustrative
// 3. Never persist a pending proposal across app launches. Restore the
//    transcript (LanguageModelSession(profile:history:)), not the pending flag.
```

Origami gets defence 1 for free, because `Orchestrator.send(_:)` cancels the in-flight task at the
head of every event and the coach's `dismiss()` clears its state. Defence 2 is not in the sample and
is worth adding to yours. Defence 3 matters the moment you start saving transcripts — a restored
session whose history ends in an unanswered consent request is a session that will behave oddly on
turn one and give you no clue why.

### 7.8 The rules, extracted

If you copy nothing else from Origami, copy these seven:

1. **The tool proposes; the app disposes.** No model-initiated mutation of user data, ever.
2. **The tool returns immediately** with a string saying a human was asked.
3. **The proposal lives in `@Observable` app state**, not in the transcript, not in a continuation.
4. **The UI replaces the composer** with the binary choice, phrased in the user's vocabulary.
5. **Both outcomes produce a turn.** Yes and No are both events; neither is a no-op.
6. **The synthesized turn says what happened, restates what is needed, and gives an instruction.**
7. **Clear the pending state everywhere it can go stale**, and resolve it before accepting any other
   user input.

---

## 8. Model routing economics

`DynamicProfile` exists because you now have more than one model.

> ✅ **VERIFIED** — `242:20-21`: *"With the introduction of the **`LanguageModel` protocol** and
> **`PrivateCloudComputeLanguageModel`**, you now have more models than ever to choose from.
> **`DynamicProfile`** is a new API that gives you the ability to **switch models within your
> `LanguageModelSession`**, providing you with the flexibility to select the best configuration for
> the task at hand."*

And the design rationale, which is the most quotable line in session 242:

> ✅ **VERIFIED** — `242:6-8`: *"The second problem these APIs solve is **establishing boundaries**.
> When using multiple models, you should design around **capability and cost considerations**.
> Dynamic profiles give you that option."*

**Capability and cost.** Not "quality". This section is about the cost half, because the capability
half is easy to reason about and the cost half is where people get surprised.

### 8.1 What each backend is charged for

| | on-device `SystemLanguageModel` | `PrivateCloudComputeLanguageModel` | BYO (`CoreAILanguageModel` / `MLXLanguageModel` / `ChatCompletionsLanguageModel`) |
|---|---|---|---|
| Availability floor | 26.0 | **27.0** | 27.0 |
| Privacy | on device | *"They both offer privacy"* (✅ 319:40) | yours to reason about |
| Works offline | ✅ | 🚫 requires internet (✅ 319:41) | ✅ if local |
| Request limits | none (✅ 319:42) | **daily limit per user** (✅ 319:42) | none |
| Context size | **4K** per Apple's docs and 319:44 — but see below | **32K** (✅ both) | model-dependent |
| Reasoning levels | not supported | `.light` / `.moderate` / `.deep` | model-dependent |
| Entitlement | none | **managed**, apply at `developer.apple.com/contact/request/private-cloud-compute/` | none |
| Memory footprint | shared system model | none (server-side) | **yours**, resident |
| `@Generable` | ✅ | ✅ | ⚠️ **not on GPU-pipelined Core AI bundles** (§8.5) |

> ✅ **VERIFIED** — the on-device/PCC comparison rows are stated identically by WWDC26 session 319
> (`319:38-45`, spoken as a table) and by Apple's *Using Private Cloud Compute* article
> (five rows, same values, `Reasoning: Not supported / Multiple levels`, `Context size: 4K / 32K`).
>
> ⚠️ **Apple documents 4K, but you still should not hardcode it.** A shipping third-party app's own
> source comment claims a different device probe: *"The on-device context is selected by the installed system
> model. **iOS 26 reports 4K while the iOS 27 model reports 8K.** `contextSize` is available in the
> Xcode 26.4+ SDK."* (community, [frozen Noema research note](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md),
> `AFMLLMClient.swift:133-135`; the app hardcodes 4096
> only as a fallback when `contextSize` returns `<= 0`.) Apple's written Group Lab 8121 summary
> documents 4096 for iOS 27, and the unreproduced 8192 comment is now retired as historical
> provenance rather than treated as a competing baseline. **Read
> `contextSize` at runtime** because the OS 27 implementation is dynamic.

The PCC entitlement is worth flagging because it is a *process* dependency, not a code one:

> ✅ **VERIFIED** — Origami's own comment, `OrchestratorProfile.swift:14-20`: *"To use Private Cloud
> Compute, request access to the **managed** `com.apple.developer.private-cloud-compute` entitlement
> at `https://developer.apple.com/contact/request/private-cloud-compute/`, then replace the
> `serverModel` initialization with the line below."* The shipped `Origami.entitlements` contains
> **only** `com.apple.security.app-sandbox` — Apple's flagship dynamic-profiles sample ships
> **on-device by default with PCC commented out**, precisely so it runs without the entitlement.

### 8.2 The switch is the cost, not the model

The single most useful mental correction: routing does not cost you "the more expensive model". It
costs you **a prefix invalidation, once per switch**.

> ✅ **VERIFIED** — `242:170-171`: *"Generally, **appending to the transcript preserves the KV cache,
> and minimizes the time-to-first-token**. If you **rewrite history by removing entries, changing the
> attached tools, or updating the instructions**, that will **typically trigger a cache invalidation,
> and can increase latency**."*
>
> ✅ **VERIFIED** — Apple's KV-caching article: *"**Switching from one profile to another typically
> changes the entire prefix — which invalidates the cache for the full transcript — so treat it as a
> deliberate reset.**"*

And the framing that makes the whole 2026 API change make sense:

> ✅ **VERIFIED** — `242:172-174`: *"Now, we **didn't talk about this last year** because we
> **intentionally shaped `LanguageModelSession` APIs to be append only**. By default, they ensured
> optimal use. But **this year, we're taking the training wheels off**, so to say."*

Two consequences for routing design:

**Route per conversation phase, never per turn.** A router that classifies each user message and
picks a model pays a full re-prefill on every alternation. A router that picks a mode — brainstorm,
tutorial, review — and stays there pays once per mode change and appends the rest of the time.

**Measure, because caching behaviour is model-specific.**

> ✅ **VERIFIED** — `242:175`: *"It's important to understand that **different models have different
> caching behavior and the only way to be certain is by measuring**."* The instrument is the metric:
> **cache hit rate = cached input tokens ÷ total input tokens** (✅ Apple's current KV-caching page,
> [captured directly on 2026-09-22](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/notes/web/apple-foundation-models-runtime-performance-2026-09-22.md)).
> The runtime-performance page names the supporting **Consumed Tokens** and **Cached Tokens** metrics.
> WWDC26 session 243 never says "cache hit rate", so the attribution remains to the written docs.

### 8.3 What switching actually measured, on real hardware

Apple has published no switch-cost figure. The community has:

> **Community-measured** — two local models behind `LanguageModel` via `coreai-kit`'s
> `KitLanguageModel`, qwen3-0.6b ↔ qwen3-4b, macOS 27 beta, M-series Mac (exact model and build not
> stated), 2026-06-13, `coreai-model-zoo/knowledge/dynamic-profiles-local-models.md`:
>
> - **Switch-in first-delta: 2.35 s** (re-prefill of ~106 tokens plus the 4B's reasoning).
> - **Switch-back: 0.94 s.**
> - *"Append-only KV reuse only helps across consecutive **same-model** turns."*
> - **Two resident models cost two footprints:** *"~102 MB with both bundles loaded but un-touched,
>   rising to **~920 MB `phys_footprint`** after the turns run. Note `phys_footprint` is the
>   **jetsam-relevant dirty number** and **excludes clean read-only-mmapped weight pages** — these are
>   4-bit bundles, so total mapped RSS is higher (**~2.4 GB+** of weights). The 86→920 MB growth is
>   runtime KV / activation / Metal buffers, not weights paging in. **Report both numbers, labeled**,
>   if footprint matters for your jetsam budget."*

That last bullet is the one that kills naive local routing on iPhone. **Two local models are two
memory footprints simultaneously**, because the point of routing is that both are ready. If you are
routing between an on-device Apple model and PCC, this does not apply — PCC costs you no local
memory. If you are routing between two of your own bundles, it is the first thing to budget.

The other side of the same coin — what prefix reuse is *worth* when you get it — is dramatic:

> **Community-measured** — `coreai-model-zoo/knowledge/prefix-cache-kv-reuse.md`, qwen3-0.6b,
> sequential engine, on a Mac (exact model and macOS build **not stated**):
>
> | Turn | Prompt tokens | Reused | TTFT with reuse | TTFT without | Speedup |
> |---|---|---|---|---|---|
> | 1 (cold) | 81–3820 | 0 | = without | initial prefill, unavoidable | 1× |
> | 2 | 357 | 336 | **0.126 s** | **1.915 s** | **15.2×** |
> | 2 | 4103 | **4075 (99.3 %)** | **0.230 s** | **23.282 s** | **101×** |
>
> Byte-identical greedy output with reuse on and off, verified at temperature 0. The scaling shape is
> the headline: **re-prefill cost grows with context while reuse cost stays roughly flat.**

Two caveats that turn this from a benchmark into a design rule:

- **The mechanism is a single integer assignment.** Trimming a KV cache does not clear anything — it
  rewinds a `processedTokenCount` cursor, and it is safe because attention is causal, so rows at or
  beyond the retained position are overwritten before any query can read them. The API contract has a
  trap in it: the trim returns the **actual** retained prefix, which may be one less than requested
  because the last generated token's KV lags a step. **Prefill from the returned value, not the
  requested one.**
- ⚠️ **Hybrid and linear-attention models forfeit prefix caching entirely.** The trim is refused
  whenever the graph carries recurrent state (`guard extraStates.isEmpty else { return -1 }`), because
  an SSM / GatedDeltaNet state is a running scan, not positionally addressed, and cannot be rewound.
  Named casualties in the same source: **Qwen3.5, Qwen3.6, LFM2.5, Granite 4** — they re-prefill every
  turn. This is a **model-selection** consequence, not a tuning tip: on a device where multi-turn TTFT
  is the user-felt metric, it can invert the usual "SSMs are better on-device" story.

All community-measured, from one implementation, and not an Apple claim. Full treatment in
[`01-context-window-and-kv-cache.md`](01-context-window-and-kv-cache.md) and
[Part 4 · `03-authoring-a-languagemodel-provider.md`](../../part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md).

### 8.4 How the route gets decided — and a measured disagreement with Apple

Session 242's baton-pass has the *model* flip the route, from inside a tool. On Apple's own models
that is the documented design. On at least one third-party provider it does not work:

> **Community-measured, and a direct disagreement with the WWDC pattern** —
> `coreai-model-zoo/knowledge/dynamic-profiles-local-models.md`: *"**242's baton-pass flips the route
> from inside a tool the model calls. On the kit's upstream engine that path is unreliable**:
> small/thinking models emit tool-call JSON the framework rejects with
> `GenerationError.decodingFailure` ('failed to parse generated content'), **independent of the
> argument schema (verified with required, optional, and empty `@Generable` arguments)**. The reliable
> 'the model decides' channel is **guided generation**."*
>
> ```swift
> @Generable struct RouterDecision {
>     @Guide(description: "true if the request needs the deep/expert model…")
>     var needsExpert: Bool
> }
> // One persistent session on the sequential engine:
> let session = LanguageModelSession(model: routerModel)
> let decision = try await session.respond(to: "Classify: \(q)", generating: RouterDecision.self)
> router.set(decision.content.needsExpert ? .smart : .fast)
> ```
>
> *"Guided generation runs on the **sequential** engine (one logits step per token): the output can't
> leak the model's `<think>` reasoning and can't be malformed."*
>
> **Scope this correctly.** It applies to third-party `LanguageModel` providers running small
> open-weight models. It is **not** a claim about Apple's `SystemLanguageModel` or PCC, where tool
> calling is the framework's own well-exercised path. Apple's own position is unambiguous:
> *"tool arguments always follow the defined schema"* (✅ Apple Frameworks Engineer, Developer Forums
> thread 833642).

The transferable lesson is about *channel reliability*, and it holds everywhere: **tool calling is a
per-model capability, not a framework guarantee.** If your app routes across backends, the routing
decision is the one place you cannot afford a `decodingFailure`, and a one-field `@Generable`
classification is a narrower, more robust channel than a tool call. Two further hard-won rules from
the same source, both community-measured against a third-party engine:

- **One engine, one session, for the engine's lifetime.** *"Two `LanguageModelSession`s over the same
  `KitLanguageModel` **corrupt the KV state** (the second resets the engine under the first). A
  per-turn fresh classifier session is the classic way to trip this — **reuse one router session**."*
  ⚠️ **This directly constrains phone-a-friend on a BYO backend**: a tool that spawns a child session
  over the *same* model instance as the parent may corrupt the parent's cache. Give the consultant its
  own model instance, or use a different backend for it.
- **Prefer a single-profile `DynamicProfile` over `LanguageModelSession(model:instructions:)`** —
  *"the plain initializer's first respond can `decodingFailure` where the profile path is solid."*

### 8.5 ⚠️ The constraint that decides your backend: `@Generable` needs logits

This is the finding that most changes architecture, and it is easy to miss because it lives at the
intersection of two subsystems.

> ⚠️ **SILENT FAILURE-adjacent — it is at least loud, but it arrives after you have chosen your
> engine.** Grammar-constrained decoding requires access to **engine logits**. A GPU-pipelined Core AI
> bundle samples on the GPU and **never surfaces logits**. Consequence: an app that brings its own
> model **loses Apple's flagship structured-generation feature exactly when it selects the fastest
> backend.**
>
> **Community-measured**, `john-rocky/coreai-model-zoo` (`knowledge/fm-provider.md`,
> `knowledge/coreai-vs-mlx-speed.md`): guided generation is available *"**only when
> `engine.supportsLogits`** — **GPU-pipelined engines sample on-GPU and return `false`**, so every
> zoo pipelined bundle lacks `.guidedGeneration`; **the sequential engine has it**."* The provider
> throws `unsupportedCapability` on schema requests. MLX, by contrast, exposes logits trivially, so
> structured generation, logprobs tooling and sampler experiments all work there.

Why this belongs in an orchestration guide rather than a conversion guide: **every pattern in §1–§7
that depends on structured output inherits this constraint.**

- The **routing classifier** of §8.4 is a `@Generable` decision. Unavailable on a pipelined bundle.
- A **phone-a-friend consultant** returning a `@Generable` type instead of prose. Unavailable.
- **Tool arguments** are `@Generable`, and their reliability rests on constrained decoding. On a
  backend without it, the argument-schema guarantee is gone — which is precisely the
  `decodingFailure` symptom of §8.4, seen from the engine side.

So the decision order is: **structured output requirement → engine → speed**, not the reverse. If
your orchestration needs `@Generable` and you are bringing your own model, you are choosing the
sequential engine or MLX, and you are accepting whatever throughput that costs. Decide it before you
build, because retrofitting is a rewrite. Full treatment in
[Part 4 · `02-bring-your-own-model.md`](../../part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md);
the backend decision table is in
[Part 1 · `01-apple-ai-stack-2026-map.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/references/01-apple-ai-stack-2026-map.md).

### 8.6 PCC's operational gates

Routing *to* PCC is not just picking a model. Four things can stop it, and all four have APIs.

**1. Availability.**

> ✅ **VERIFIED** — Apple's *Using Private Cloud Compute* article:
> ```swift
> let model = PrivateCloudComputeLanguageModel()
>
> switch model.availability {
> case .available:
>     // Show your intelligence UI.
> case .unavailable(.deviceNotEligible):
>     // Show an alternative UI.
> case .unavailable(.systemNotReady):
>     // PCC isn't ready to serve requests.
> case .unavailable(let other):
>     // The model is unavailable for an unknown reason.
> }
> ```
> Shipping third-party code matches these cases and adds an `@unknown default:` arm
> ([frozen Noema research note](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md),
> `AppleFoundationModelAvailability.swift:163-186`) — do the same; the enum is
> resilient. And ✅ `319:36-37`: *"just like with the on-device model, **PCC is only available on
> Apple Intelligence devices.**"*

**2. Network.** ✅ Apple's article, doc-only: *"Using PCC requires a network connection, so **if the
request fails because the network connection is unavailable, retry the request using the on-device
model.**"* That is a routing fallback Apple explicitly recommends, and `DynamicProfile` is where it
belongs — a `networkAvailable` flag in your route enum, not a `try?` at the call site.

**3. Locale.** ✅ `PrivateCloudComputeLanguageModel.supportsLocale(_:)` exists and is used in shipping
code to throw before the request ([frozen Noema research note](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md),
`AFMLLMClient.swift:92-95` — written against the
pre-beta-5 synchronous surface). ⚠️ **Changed in Xcode 27 beta 5 (noted 2026-08-23):** the PCC
overload is now **`async throws`** — ✅ **SDK-verified**
(`FoundationModels-27.0-macos.swiftinterface:149`),
`nonisolated(nonsending) func supportsLocale(_ locale: Locale = Locale.current) async throws -> Bool`
— and PCC's `supportedLanguages` is likewise `get async throws` (`27.0:144-146`). A bare
`guard model.supportsLocale(...)` no longer compiles against the beta 5 SDK for PCC. The on-device
equivalent, `SystemLanguageModel.default.supportsLocale(_:)`, is **still synchronous** (`27.0:400`)
and has an **OS 26.0** floor; it appears directly in the 26.0 `SystemLanguageModel` declaration,
before the separate 26.4 context-introspection extension.[^supports-locale-floor] PCC remains
27-only because the PCC model itself is 27-only.

**4. Quota.** This is the one that will actually bite a shipping app.

> ✅ **VERIFIED** — the quota API, verbatim from Apple's article:
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
> Types: `QuotaUsage` struct with `isLimitReached: Bool`, `status` (at least `.belowLimit(Information)`
> where `Information.isApproachingLimit: Bool`), `resetDate` (*"empty when the reset date isn't known
> or when the person is well below their limit"*), and `limitIncreaseSuggestion?` with `.show()`
> presenting system upgrade UI. The thrown error is
> `PrivateCloudComputeLanguageModel.Error.quotaLimitReached(_:)`.

> ✅ **VERIFIED** — the distinction to memorise, from Apple's article: *"**Unlike rate limiting, where
> a person waits for a period of time before trying again, exceeding the daily quota means a person
> either waits for their usage quota to refresh or they upgrade to a higher tier.**"* Retrying does
> not help. Falling back does.

> ⚠️ **The quota API is coarse on purpose, and developers have asked for more.** ✅ Developer Forums
> thread 835974 ("More Detailed Quota Usage for PCC", 24 Jun 2026): *"You can tell if you've reached
> your quota or are below it. If you are below your quota, you can tell if you're approaching the
> limit, but what does this actually mean? Am I over 50%, 90%, 99%?"* You get **reached / approaching
> / below**, not numbers. Budget your routing on states, not on a percentage you do not have.

And the UI guidance, which is unusually specific:

> ✅ **VERIFIED** — `319:84-88`: *"You should **integrate this with your existing UI**. **Avoid
> showing an alert for the usage limit. Because this UI should persist, and not be dismissed.**
> Instead, you can **update the state of your UI, like disabling the button that makes a request.**"*

**The routing consequence of all four.** A `DynamicProfile` whose PCC branch is unguarded will
degrade badly at exactly the moment a user is most engaged — deep in a conversation, quota exhausted.
Make the route a function of *capability plus eligibility*:

```swift prelude:guide-context
@Observable
final class Router {
    enum Route { case onDevice, server }

    var phase: Phase = .brainstorm
    private let server = PrivateCloudComputeLanguageModel()

    // supportsLocale(_:) is async throws on PCC as of Xcode 27 beta 5 — resolve it
    // once, outside the per-turn route computation, and cache the answer.
    private(set) var serverSupportsLocale = false

    func refreshLocaleSupport() async {
        serverSupportsLocale = (try? await server.supportsLocale(Locale.current)) ?? false
    }

    var route: Route {
        guard phase.prefersServer else { return .onDevice }
        guard case .available = server.availability else { return .onDevice }
        guard !server.quotaUsage.isLimitReached else { return .onDevice }
        guard serverSupportsLocale else { return .onDevice }
        return .server
    }
}
```

> 🟡 **RECONSTRUCTED** — the composition. Every member used is ✅ verified — `availability` and its
> cases and `quotaUsage.isLimitReached` are synchronous reads (✅ SDK-verified, `27.0:51-58`), and
> `supportsLocale(_:)` is the beta-5 `async throws` surface (`27.0:149`); the aggregation is ours.
> The async capability check is exactly why it is resolved **outside** `route`: `route` is the kind
> of computed value a `DynamicProfile.body` should *read*, and it must stay pure and cheap because
> `body` is re-evaluated more than once per turn (§6.1) — an `async throws` call cannot appear in
> that path at all. Call `refreshLocaleSupport()` at setup and again on
> `NSLocale.currentLocaleDidChangeNotification`, and treat a thrown check as "not supported": the
> fallback direction (on-device) is the safe one. If `availability` or `quotaUsage` turn out to be
> expensive to read, cache them behind an explicit refresh too. 🔴 We have not measured the cost of
> either.

Also — and this is free — **Xcode can simulate the quota states**, so you can test the fallback path
without exhausting a real account:

> ✅ **VERIFIED** — Apple's article: *Product ▸ Scheme ▸ Edit Scheme ▸ **Run** page ▸ **Options** tab
> ▸ select "**Approaching Quota Usage Limit**" or "**Quota Usage Limit Reached**" from the
> "**Simulated Apple Foundation Models Availability**" drop-down.* ⚠️ Session 319 narrates a slightly
> different path ("select **Debug** and then **Options**") and a different label ("Nearing Usage
> Limit"). The docs are more recent and more specific; prefer them, and if the menu item is not where
> you expect, look on the other tab.

---

## 9. `Skills`: the third option

Apple pointed at a third pattern in the same breath as the first two:

> ✅ **VERIFIED** — `242:136-137`: *"Baton-pass and phone-a-friend are good tools to have in your
> belt, **but there are other options as well**. For example, the **Foundation Models framework
> utilities package houses a `Skills` type**, which you may be familiar with as **a popular pattern
> for procedural context loading**."*

`Skills` ships in `apple/foundation-models-utilities` — an Apple-authored, Apache-2.0, zero-dependency
Swift package that is **versioned separately from the OS**:

> ✅ **VERIFIED** — `242:12-14`: *"Utilities is an **open source Swift package** that houses
> components helpful for building agentic experiences. It will be **updated in between OS releases**
> and give you access to **emerging or experimental patterns**, all **backed by dynamic profiles**."*
>
> ✅ **VERIFIED** — `Package.swift` at tag `1.0.0-beta3` (commit `376ca60`, 2026-07-10):
> `.macOS("27.0") / .iOS("27.0") / .visionOS("27.0") / .watchOS("27.0")`, swift-tools 6.2,
> `swiftLanguageModes: [.v6]`, **zero external dependencies**. Two commits in the whole repository;
> **GitHub issues are disabled** and PRs are not accepted — bugs go to the Developer Forums or
> Feedback Assistant.

### 9.1 What it is

A `Skill` is a named, described bundle of context that the model can **activate on demand** by calling
a synthesized tool. You declare a list; the model picks. Where baton-pass swaps the whole persona and
phone-a-friend leaves the room to ask someone, `Skills` **adds knowledge to the persona you already
have**.

> ✅ **VERIFIED** — `Skills` conforms to `DynamicInstructions`
> (`Sources/FoundationModelsUtilities/Skills/Skills.swift:55`), so it drops into a profile body
> exactly like any other instructions component. Its `body` emits, in order: the leading instructions,
> a `ForEach` over the skills rendering one block each, and the synthesized toggle tool.

> ✅ **VERIFIED** — the default leading instruction, `Skills.swift:57`:
> ```swift
> private static let defaultInstructions = Instructions {
>     """
>     If a skill below fits the user's request, silently activate it before \
>     responding. Otherwise, respond normally without calling tools.
>     """
> }
> ```

> ✅ **VERIFIED** — the synthesized tool's name is derived, `Skills.swift:240`:
> ```swift
> let resolvedName = name ?? (allowsDeactivation ? "toggle_skill" : "activate_skill")
> ```
> i.e. **`toggle_skill`** iff any instructions-backed skill in the list sets
> `allowsDeactivation: true`, otherwise **`activate_skill`**. You can override with `toolName:`.

### 9.2 The storage choice, and why it is a KV-cache decision

This is the part worth reading even if you never use the package, because it is the clearest worked
example of the cost model in §8.2.

A `Skill` has two storages, and they differ in **where the skill's content lands in the transcript**:

| Storage | Content goes into | KV cache | Deactivatable |
|---|---|---|---|
| **`.prompt`** | the **tool output** entry | **preserved** — earlier bytes untouched | no (structurally) |
| **`.instructions`** | the **instructions entry** at the top | **invalidated** — the prefix changed | yes, if `allowsDeactivation: true` |

> ✅ **VERIFIED** — the mechanism, `Skills.swift:293-317`. The toggle tool returns a `Prompt`, and for
> a prompt-backed skill **that return value *is* the skill body**:
>
> ```swift
> func call(arguments: GeneratedContent) async throws -> Prompt {
>   …
>   switch skill.storage {
>   case .prompt(let promptSkill):
>     return promptSkill.prompt
>   case .instructions:
>     let activated = activations.isActive(skill.name)
>     let verb = activated ? "deactivated" : "activated"
>     return Prompt { "Successfully \(verb) skill: \(skill.name)" }
>   }
> }
> ```
>
> Apple's own doc comment states the consequence (`Skill.swift:25-26`): *"the skill's content is added
> to the transcript as part of the matching tool output. **This has the advantage of not invalidating
> the key-value cache.**"*

Note what that makes `Tool.Output`: a **`Prompt`**, not a `String`. This is the only place in the
corpus where a tool returns something other than `String` in compiling code — ✅
`Skills.swift:293`. (Every `call(arguments:)` in every Apple *sample project* returns `String`.)

Also note the third rendering state, which nobody would guess:

> ✅ **VERIFIED** — `Skills.swift:150-176`, three states rather than two:
>
> | Storage | State | Rendered |
> |---|---|---|
> | `.instructions` | active | `\nSkill: <name> [active]` + the body |
> | `.instructions` | inactive | `\nSkill: <name> [inactive]` + `Description: <desc>` |
> | `.prompt` | (n/a) | `\nSkill: <name> [on demand]` + `Description: <desc>` |
>
> with Apple's rationale verbatim (`Skills.swift:168-171`): *"Prompt-based skills are one-shot:
> invoking one injects its content as tool output rather than toggling a persistent mode. We label
> them as on-demand so the model isn't told they're 'inactive' after it has already invoked them."*

### 9.3 The sleeper feature: a skill can carry tools

> ✅ **VERIFIED** — `Skill.swift:194-198`, Apple's doc comment on the
> `@DynamicInstructionsBuilder` initializer: *"The closure may include `Instructions` content as well
> as `Tool` values; while the skill is active, its instructions are injected into the instructions
> entry **and any tools it carries become available to the model**."*
>
> The package's own example (`Skills.swift:40-52`) gates four calendar tools —
> `QueryCalendarEventsTool()`, `AddCalendarEventTool()`, `DeleteCalendarEventTool()`,
> `ModifyCalendarEventTool()` — behind activating a `"calendaring"` skill. And a test proves the tools
> contribute **zero text** to the instructions entry while still being registered
> (`SkillsTests.swift:379-407`, *"active builder skill with a tool renders no tool text"*).

That directly addresses §4.3's pressure. Apple's own budget guidance is ***"Provide no more than three
to five tools per request"*** (✅ *Managing the context window*). A skill lets you declare twenty tools
and advertise only the handful the current request needs — the model pays a one-line description per
inactive skill instead of a full schema per inactive tool.

### 9.4 When to reach for it

| | Baton-pass | Phone-a-friend | `Skills` |
|---|---|---|---|
| Changes the persona | ✅ wholesale | 🚫 | 🚫 — augments it |
| Who decides | the model, via a tool | the model, via a tool | the model, via a synthesized tool |
| Transcript | one, shared | two, isolated | one, shared |
| KV cache | invalidated at the switch | untouched by the parent | **prompt skills: preserved** · instructions skills: invalidated |
| Reversible | with a tool back | automatic | `allowsDeactivation: true`, instructions skills only |
| Best for | modes | questions | **conditional knowledge and conditional toolsets** |

Reach for `Skills` when the answer to "does this change who the assistant is?" is no, but the answer
to "does it need extra knowledge or extra tools right now?" is yes. A cooking app whose assistant
occasionally needs unit-conversion procedure, or an app with twelve domain toolsets of which one is
relevant per conversation, is a `Skills` app, not a baton-pass app.

Two cautions before you adopt:

> ⚠️ **The package is beta-3 and its own README is out of date.** `SkillActivations` **no longer
> conforms to `RandomAccessCollection`** — it was removed in commit `376ca60` — yet `README.md:100`
> and the bundled `SKILL.md:150` still claim it does, and the latter shows a now-broken snippet
> `ForEach(assistant.activations, id: \.self)`. The correct beta-3 form is
> `ForEach(assistant.activations.activeSkillNames, id: \.self)`. ✅ verified against
> `SkillActivations.swift:23-56`, whose **complete** public surface is `init()`, `activate(_:)`,
> `deactivate(_:)`, `isActive(_:)`, `activeSkillNames`.

> 🔴 **GAP (narrowed 2026-07-29) — `Skills` versus `SkillActivation`.** One half is now settled: the
> FoundationModels 27.0 beta interface contains **no** `Skill`, `Skills`, or `SkillActivation`
> symbol (grep-verified against
> `notes/sdk-interfaces/FoundationModels-27.0-macos.swiftinterface`), so whatever session 242 and
> thread 835165 were naming, it is **not a framework type** — the package symbols (`Skill`,
> `Skills`, `SkillActivations`, ✅ verified from source at `376ca60`) are the only shipping
> spellings. What thread 835165's failing `SkillActivation` module actually was remains unresolved.
> **Safe default: take the spellings from the package you actually resolved in your
> `Package.resolved`, not from a session or a forum thread.**

Full treatment — all four `Skill` initializers, the schema construction, `strictSchema`, the
history modifiers the package also ships — in
[`03-skills-and-history-modifiers.md`](03-skills-and-history-modifiers.md).

---

## 10. Evaluating agentic behaviour

Everything above is a behaviour you cannot unit-test.

> ✅ **VERIFIED** — WWDC26 session 243 (`243:21-26`): *"Give a traditional function the same input
> twice, and you get the same output. LLMs don't work that way… **which means standard unit testing
> breaks down. You can't assert that an output matches a hardcoded string. You have to evaluate the
> quality and intent of the response instead.**"*

And Apple's own instruction to do this specifically for the transcript surgery this guide has been
recommending:

> ✅ **VERIFIED** — `242:185-187`: *"When you start to get into **nuanced transcript modifications**
> like this, it becomes **even more important to use the Evaluations framework to create eval sets and
> quantify the effect of context engineering strategies**. **Data driven optimization is the only way
> to be confident.**"*

### 10.1 Why the final answer is not enough

> ✅ **VERIFIED** — WWDC26 session 299 (`299:122-124`): *"**Here's the thing. A model might give you a
> reasonable-sounding answer without ever calling the right tool. The final output can look correct
> while the path to get there isn't right.**"*
>
> And what a tool evaluation checks (`299:130-133`): *"**They let you verify the how, not just the
> what.** … **The model should call the correct tools, with the correct arguments in the order you
> expect. And along the way, you'll double check that there weren't any unexpected tool calls in the
> middle.**"*

Four checks: **correct tools · correct arguments · correct order · no unexpected calls.** Map those
onto this guide and you get: *did the baton get passed · with the right craft · after the user chose ·
without the sender also trying to write the tutorial itself.*

The memorable framing, which is worth keeping:

> ✅ **VERIFIED** — `299:151-152`: *"You can think of a trajectory expectation check like **going over
> the list of decisions you made when planning a route. Cars, bikes, and buses are all tools that have
> their time and place in getting somewhere, but you can evaluate their utility for each segment in a
> specific trip.**"*

### 10.2 The API, as it actually compiles

Everything in this subsection is ✅ **VERIFIED** from Apple's Book Tracker sample
(`BookTrackerUsingEvaluationsToEvaluateAnIntelligentFeature`, `MACOSX_DEPLOYMENT_TARGET = 27.0`),
which ships sixteen trajectory expectations across a 578-line evaluation file.

> ✅ **VERIFIED** — `BookTrackerEvaluations/SearchBooks.swift:46-74`, a sample with expectations:

```swift illustrative
    ModelSample(
        prompt: "gothic",
        expected: BookResults(books: [ … ]),
        instructions: BookAssistant.instructions,
        expectations: TrajectoryExpectation(unordered: [
            ToolExpectation(
                "searchBooks",
                arguments: [
                    .exact(argumentName: "tag", value: .string("gothic"))
                ]
            )
        ])
    ),
```

Four `TrajectoryExpectation` initializers, all observed in that one file:

| Form | Use |
|---|---|
| `TrajectoryExpectation(unordered: [ToolExpectation])` | presence, order irrelevant |
| `TrajectoryExpectation(ordered: [ToolExpectation], allowsAdditionalToolCalls: true)` | multi-step sequences |
| `TrajectoryExpectation(unordered: […], disallowed: [ToolExpectation("findSimilarBooks")])` | the negative case |
| `TrajectoryExpectation(expected: "searchBooks", arguments: […])` | single-call shorthand |

and the complete argument-matcher vocabulary the sample exercises:

| Matcher | Example |
|---|---|
| `.exact(argumentName:value:)` | `.exact(argumentName: "tag", value: .string("gothic"))` |
| `.naturalLanguage(argumentName:criteria:)` | `.naturalLanguage(argumentName: "mood", criteria: "Should relate to uplifting, hopeful, or positive feelings.")` |
| `.keyOnly(argumentName:)` | `.keyOnly(argumentName: "bookId")` |
| `.oneOf(argumentName:allowedValues:)` | `.oneOf(argumentName: "tag", allowedValues: [.string("strategy"), .string("epic")])` |
| `.contains(argumentName:substring:)` | `.contains(argumentName: "tag", substring: "histor")` |
| `.hasSuffix(argumentName:suffix:)` | `.hasSuffix(argumentName: "genre", suffix: "fiction")` |
| `.range(argumentName:minimum:maximum:)` | `.range(argumentName: "limit", minimum: 1, maximum: 3)` |

> **`.naturalLanguage` is the headline capability**: a model decides whether the argument that was
> actually passed satisfies a prose criterion. It is how you assert "the craft argument named the
> thing the user picked" without pinning a string. ✅ 299:163-166: *"**An exact match isn't always
> what you want.** If the prompt is 'Find something cheerful', the model might pass **uplifting,
> happy, cheerful — any of those are fine**. The `.naturalLanguage` matcher **checks whether the value
> matches the intent, not the exact string**."*

⚠️ Only `.string(_)` appears as a value wrapper anywhere in the corpus. 🔴 `.number` / `.bool` /
`.array` are unverified — and remain so after the 2026-07-29 SDK capture: the wrapper type belongs
to the **Evaluations** framework, whose interface was not captured (no
`Evaluations-27.0-macos.swiftinterface` exists in `notes/sdk-interfaces/`). One observation worth
recording: the shape exactly matches `GeneratedContent.Kind`, whose full case list *is*
SDK-verified (`null` / `bool(Bool)` / `number(Double)` / `string(String)` /
`array([GeneratedContent])` / `structure(properties:orderedKeys:)`,
`FoundationModels-27.0-macos.swiftinterface:1376-1384`) — if the matcher's value type is that
enum, the siblings exist; nothing here proves it is.

And the wiring, which has one non-obvious requirement:

> ✅ **VERIFIED** — `SearchBooks.swift:525-563`:

```swift illustrative
struct SearchToolEvaluations: Evaluation {
    var dataset = samples

    let pass = Metric("All Passed")
    let percent = Metric("Percentage Passed")

    var evaluators: Evaluators {
        ToolCallEvaluator(allPass: pass, percentagePass: percent)
    }

    var registeredTools: [any Tool] = [
        SearchBooksTool(books: Book.sampleBooks.map(\.snapshot)),
        GetBookDetailsTool(books: Book.sampleBooks.map(\.snapshot)),
        FindSimilarBooksTool(books: Book.sampleBooks.map(\.snapshot))
    ]

    func subject(from sample: ModelSample<BookResults>) async throws -> ModelSubject<BookResults> {
        let model = SystemLanguageModel(
            guardrails: .permissiveContentTransformations
        )
        let session = LanguageModelSession(
            model: model,
            tools: registeredTools,
            instructions: BookAssistant.instructions
        )

        let response = try await session.respond(to: sample.prompt, generating: BookResults.self)

        return ModelSubject(
            value: response.content,
            transcript: session.transcript.structuredTranscript
        )
    }
```

- **`ToolCallEvaluator(allPass:percentagePass:)`** takes two `Metric`s — strict all-or-nothing, and
  partial credit.
- **The trajectory reaches the evaluator only via `ModelSubject(value:transcript:)`**, and the
  transcript must be **`session.transcript.structuredTranscript`**. Pass the plain `Transcript` and
  the evaluator has nothing to inspect.
- **You build the session yourself inside `subject(from:)`** — and you must build it *the same way the
  feature does*. Book Tracker constructs
  `SystemLanguageModel(guardrails: .permissiveContentTransformations)` in both the app service and
  the evaluation; construct it differently and you are evaluating a different system.

### 10.3 Evaluating a handoff

Now apply it to §2. A baton-pass has a trajectory, and it is short:

```swift prelude:guide-context
import Evaluations
import FoundationModels
import Testing

let handoffSamples = [
    // 1. The baton must be passed, with the craft the user named.
    ModelSample(
        prompt: "the paper butterfly one, how do I fold it?",
        expected: TutorialStarted(craft: "paper butterfly"),
        instructions: BrainstormInstructions.text,
        expectations: TrajectoryExpectation(unordered: [
            ToolExpectation(
                "switchToTutorialMode",
                arguments: [
                    .naturalLanguage(
                        argumentName: "craft",
                        criteria: "Should name the paper butterfly the person selected."
                    )
                ]
            )
        ])
    ),

    // 2. Idle chat must NOT pass the baton. The negative case is the one
    //    that catches an over-eager handoff, and nothing else will.
    ModelSample(
        prompt: "these are all lovely, what do you think of the second one?",
        expected: StillBrainstorming(),
        instructions: BrainstormInstructions.text,
        expectations: TrajectoryExpectation(
            unordered: [],
            disallowed: [ToolExpectation("switchToTutorialMode")]
        )
    ),
]
```

> 🟡 **RECONSTRUCTED** — the samples. Every type, initializer and matcher used is ✅ verified from
> Book Tracker (§10.2); the handoff scenario is ours.

Sample 2 is the important one and it is the one people skip. **A baton tool that fires too eagerly is
invisible in output quality** — the model still answers, just from the wrong persona, with the wrong
model, at the wrong temperature, having burned a full prefix invalidation. `disallowed` is the only
assertion that catches it.

### 10.4 `disallowed` is also your injection test

> **Community framing, and a good one** — `coreai-model-zoo/knowledge/evaluations-framework.md`:
> *"299's mechanism for 'the model must **not** call `findSimilarBooks`' is exactly the gate an
> agentic security checklist asks for: feed **poisoned context**, then assert the destructive tool is
> **absent** from the trajectory **and the parameters weren't rewritten** (`naturalLanguage` matcher on
> the recipient/target). This converts 'we mitigated injection' from a claim into a **number you can
> hill-climb**."*

For the patterns in this guide that means: put a hostile string in the tool output your phone-a-friend
consultant returns, or in the retrieved document your baton-pass profile inherits, and assert with
`disallowed` that no destructive tool appears. It is the only deterministic security test in the
stack.

Relevant to §4.2's third worked call: **phone-a-friend's isolation is a mitigation you can now
measure.** Run the same poisoned-context sample against a shared-transcript design and an isolated-
child design, and the difference in trajectory-pass rate is your containment number.

### 10.5 What to expect when you run it

Three findings worth carrying in, all ✅ verified from session 299 and Book Tracker:

- **Scores drop when the dataset grows, and that is the small set having flattered you.** ✅
  `299:100-102`: *"I've went ahead and ran the evaluation with our new dataset of 100 samples… **we're
  expecting the scores to drop!** And we were correct! … **Our tag generation feature looked like it
  was performing well earlier because we weren't testing it with a comprehensive dataset.**"*
- **Coverage beats count.** ✅ `299:40`: *"**What matters far more than quantity is coverage! So
  instead of asking how many samples do I need? Ask yourself, have I covered the meaningful variety of
  ways this feature will actually be used?**"*
- **Stamp the prompt into the run record.** Book Tracker passes
  `.evaluates(evaluation, info: ["Prompt": BookTaggingService.instructions, …])` so runs are diffable
  in Xcode's Compare view. For orchestration work, add the route: which model, which profile, which
  `toolCallingMode`. Otherwise a regression tells you the number moved and nothing about why.

Full treatment — `SampleGenerator`, model judges, Cohen's-kappa calibration, the `.xcevalresult`
round trip — in
[Part 6 · `03-synthetic-data-and-tool-trajectories.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md)
and [Part 6 · `01-foundations-and-hill-climbing.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/references/01-foundations-and-hill-climbing.md).

---

## 11. Quick reference

### 11.1 The two patterns

| | Baton-pass | Phone-a-friend |
|---|---|---|
| Apple's word | collaboration | consultation |
| Tool's side effect | sets the active-profile variable | spawns a short-lived child session |
| Transcript | one, shared, fully visible to both | two, isolated; child's never merges |
| Final answer | the receiving profile | always the parent |
| Cost | one prefix invalidation per switch | one child prefill per consultation |
| Bound the damage with | `historyTransform`, switch at boundaries | `maximumResponseTokens` on the child, validate the return |

### 11.2 API surface used in this guide

| Symbol | Status | Floor | Where verified |
|---|---|---|---|
| `LanguageModelSession.DynamicProfile` (protocol) | ✅ | 27.0 | Origami `OrchestratorProfile.swift:230` |
| `var body: some DynamicProfile` (**short** form) | ✅ | 27.0 | Origami `OrchestratorProfile.swift:242` |
| `Profile { … }.model(_:)` | ✅ | 27.0 | Origami; **not** `Profile(model:) { }` |
| `.temperature(1.0)` · `.reasoningLevel(.deep)` | ✅ | 27.0 | Origami |
| `.maximumResponseTokens(_:)` · `.samplingMode(_:)` | ✅ (listed) | 27.0 | modifier list; no Apple sample call site |
| `.historyTransform(f)`, `f: ([Transcript.Entry]) -> [Transcript.Entry]` | ✅ | 27.0 | Origami `.historyTransform(shortHistory(_:))` |
| `.transcriptErrorHandlingPolicy(_:)` | ✅ | 27.0 | 242:158-159 + docs |
| `.toolCallingMode(_:)` | ✅ | 27.0 | `mlx-swift-lm` compiled test |
| `.onToolCall { }` (0-arg) | ✅ | 27.0 | `mlx-swift-lm` compiled test |
| `.onToolCall { call in }` (1-arg, `call.toolName`) | ✅ | 27.0 | Apple dynamic-profiles article |
| `.onActivate/.onDeactivate/.onPrompt/.onResponse/.onToolOutput` | ✅ SDK-verified — overload pairs, `async throws` (activate/deactivate: `async`, non-throwing) | 27.0 | `FoundationModels-27.0-macos.swiftinterface:984-1026` |
| `@SessionPropertyEntry` (no parens) on a `var` with an initial value | ✅ | 27.0 | compiled test `:14-18` |
| `@SessionProperty(\.keyPath)` | ✅ | 27.0 | compiled test `:51-52` |
| `session.properties.<name>` | ✅ | 27.0 | compiled test `:120` |
| `GenerationOptions.ToolCallingMode` + `.kind` (non-frozen) | ✅ | 27.0 | `ToolCallingModeResolution.swift` |
| `GenerationOptions(…, toolCallingMode:)` | ✅ | 27.0 | docs + forums code |
| `TranscriptErrorHandlingPolicy.preserveTranscript / .revertTranscript` | ✅ | 27.0 | docs |
| `session.transcript` (settable) · `session.isResponding` | ✅ | 27.0 | 242:165-167; Origami `:367` |
| `LanguageModelSession(profile:)` · `(profile:history:)` | ✅ | 27.0 | 242:58; Origami `:41-47` |
| `LanguageModelSession(model:instructions:)` | ✅ | 26.0 | Origami `TermExtractor.swift:32-39` |
| `LanguageModelSession.ToolCallError` (`.tool`, `.underlyingError`) | ✅ | 26.0, **no watchOS** | docs |
| `PrivateCloudComputeLanguageModel()` · `.availability` · `.quotaUsage` (sync, `27.0:51-58`) · `.supportsLocale(_:)` (**`async throws` as of beta 5**, `27.0:149` — §8.6) | ✅ SDK-verified | 27.0 | docs + shipping code (pre-beta-5 sync call sites) + beta 5 interface |
| `Skills` · `Skill` · `SkillActivations` | ✅ | package 27.0 | `foundation-models-utilities` @ `376ca60` |
| `TrajectoryExpectation` · `ToolExpectation` · `ToolCallEvaluator` | ✅ | Xcode 27 | Book Tracker `SearchBooks.swift` |
| `session.transcript.structuredTranscript` | ✅ SDK-verified — declared by the **Evaluations** framework (Xcode-shipped), which extends `Transcript`; `StructuredTranscript` is Evaluations' type, absent from FoundationModels by design | 27.0 | Book Tracker `:525-563`; `Evaluations-27.0-macos.swiftinterface:278-292` |
| `Profile(model:) { … }` initializer | ✅ **absent from the 27.0 beta interface** (checked 2026-07-29) — `Profile` has exactly one init, the builder-closure form | — | `FoundationModels-27.0-macos.swiftinterface:830-843` — **do not use** |
| `DynamicProfileModifier` requirements | ✅ SDK-verified — `associatedtype Body: DynamicProfile`; `@DynamicProfileBuilder func body(content: Self.Content) -> Body`; `typealias Content = DynamicProfileModifierContent<Self>`; applied via `.modifier(_:)` | 27.0 | `FoundationModels-27.0-macos.swiftinterface:921-962` |
| structured (`@Generable`) tool `Output` on Apple's stack | 🔴 runtime-unverified — the constraint `associatedtype Output: PromptRepresentable` is SDK-verified (`:3055`), so it compiles; every sample still returns `String` | — | documented; no sample demonstrates it |

### 11.3 The silent failures in this guide

| # | Failure | Symptom | Defence |
|---|---|---|---|
| 1 | **`.required` with no exit** | `respond(to:)` never returns; tool side effects repeat | Exit A (conditional mode) + Exit B (throwing final-answer tool), §6.4 |
| 2 | **Baton tool named in prose, absent from the toolset** | Handoff never happens; model loops on the nearest legal tool; no error | One `enum ToolNames`; a unit test; the Instruments Instructions lane |
| 3 | **Call-site `options:` overriding a profile's `toolCallingMode`** | Loop exit silently disabled | One surface per session; never pass `toolCallingMode` at a call site when using profiles |
| 4 | **`.preserveTranscript` with a partial trailing entry** | Answers get strange; nothing throws | Repair under `guard !session.isResponding`; drop a `.toolCalls` with no `.toolOutput` |
| 5 | **A failed consultation returned as plausible prose** | Parent reasons confidently from a fabricated fallback | Say the consultation failed; validate before returning; never swallow `CancellationError` |
| 6 | **An unanswered consent proposal** | Every later turn generated against "a confirmation is pending" | Clear on navigation; resolve before accepting new input; never persist the pending flag |
| 7 | **A stream that yields zero partials** (model emitted only a tool call) | Spinner hangs forever | Drive loading state off stream *completion*, not first token — ✅ Origami `CoachModel.swift:67-72` |

### 11.4 Checklist before you ship an orchestrated feature

- [ ] Every `.required` site has **both** a counter cap and a throwing exit.
- [ ] Every tool name in every instructions string is a constant shared with the `Tool` conformance.
- [ ] A unit test asserts the named tools are registered in the profile that names them.
- [ ] Mode transitions happen at conversation boundaries, and you have looked at the Instructions lane
      to confirm the number of regions matches the number of modes you expected.
- [ ] Profiles that hand off to a smaller model carry a `historyTransform`.
- [ ] Profiles that hand off across a privacy boundary redact in that transform.
- [ ] Every phone-a-friend child has a `maximumResponseTokens` and validates its own output.
- [ ] Every consent proposal has a decline path that produces a turn, and a clear-on-navigate path.
- [ ] The PCC branch of your router checks availability, quota and locale, and falls back on network
      failure.
- [ ] You have run with the Xcode scheme's simulated quota states.
- [ ] A `TrajectoryExpectation` asserts the handoff fires when it should, and a `disallowed`
      expectation asserts it does not fire when it should not.
- [ ] `.evaluates(…, info:)` records which model, profile and tool-calling mode produced the run.

---

## 12. Sources

**Apple sample code — the strongest evidence class here, read directly this session.**
Extracted from the archives obtained via Apple's tutorials JSON API.

- **Origami: Crafting a dynamic tutorial for Apple Intelligence** (iOS/macOS/visionOS 27.0,
  Swift 6.0, 61 Swift files) — `OrchestratorProfile.swift` (the `DynamicProfile`),
  `Orchestrator.swift` (the event/reduce/effect machine, the consent flow at `:487-561`, the
  prompt assembly at `:596-616`), `Coach/MovePhotoToStepTool.swift`, `Coach/CoachInstructions.swift`,
  `Coach/CoachView.swift`, `Coach/CoachModel.swift`, `Terms/TermExtractor.swift`,
  `Tutorial/Intelligence/{OrigamiInstructions,TutorialInstructions,CraftTools}.swift`,
  `Models/{OrchestratorState,TranscriptRecorder,Error+DisplayMessage}.swift`.
- **Book Tracker: Using Evaluations to evaluate an intelligent feature** (macOS 27.0) —
  `BookTrackerEvaluations/SearchBooks.swift` (16 trajectory expectations, `ToolCallEvaluator`),
  `Services/BookSearchTools.swift`.
- ⚠️ **Not cited as 2026 evidence:** the coffee/generative-game sample and the SpeechAnalyzer sample
  are iOS 26 / WWDC25 leftovers that were never refreshed.

**Compiled third-party Swift against the 27.0 SDK**

- `ml-explore/mlx-swift-lm` — `Libraries/MLXFoundationModels/ToolCalling/ToolCallingModeResolution.swift`
  (mode resolution, `.disallowed` as zero definitions, `requiredToolsMissing`);
  `IntegrationTesting/…/StructuredToolOutputSessionTests.swift` (the canonical `.required` → exit
  profile, `@SessionPropertyEntry`, `session.properties`).
- `apple/foundation-models-utilities` @ `376ca60` (tag `1.0.0-beta3`, 2026-07-10) —
  `Skills/{Skill,Skills,SkillActivations}.swift` and `SkillsTests.swift`.

**Apple documentation**

- *Composing dynamic sessions with instructions and profiles* — modifier precedence, `@SessionProperty`.
- *Optimizing key-value caching in language model sessions* — token layout, blast radius, profile
  switching as a deliberate reset, restore path.
- *Expanding generation with tool calling* — the six phases, `.required` exit condition, rollback,
  "the last entry may be partially generated".
- *Managing the context window* — the three-to-five-tools budget.
- *Using Private Cloud Compute* — availability cases, quota API, the 4K/32K table, scheme simulation.
- `GenerationOptions.ToolCallingMode` symbol page — the three modes and the `RecipeDynamicProfile`
  exit sample.
- The `Tool` protocol page and `Transcript` page.

**Apple Developer Forums**

- 833692 — Apple Frameworks Engineer recommending `.toolCallingMode` with dynamic profiles for
  strict RAG.
- 833642 — Apple Frameworks Engineer: guided generation supports any JSON-representable schema,
  *"tool arguments always follow the defined schema"*, on-device window stated as 4,096 tokens.
- 837226 — `.required` with an apparently non-empty toolset producing
  `LanguageModelError error -1` / *"Tool Choice requires tools"*. **FB23643759, still open.**
- 835974 — the PCC quota API exposes coarse states, not numbers.
- 835165 — a `SkillActivation` module reported as failing to build (unresolved, §9.4).

**WWDC26 transcripts** (spoken narration; on-screen code was described, not dictated)

- **242** — *Build agentic app experiences with the Foundation Models framework*. Baton-pass and
  phone-a-friend (`:119-137`), tool calling mode (`:138-154`), transcript error policy (`:155-167`),
  KV caches (`:168-177`), accuracy of history rewriting (`:178-187`).
- **243** — *Debugging and profiling Foundation Models features with Instruments*. The silent-failure
  bug (`:50`, `:63-66`, `:98-103`), the Instructions lane (`:78-80`, `:117-126`), the tree view and
  its invariant (`:85-90`), the three performance metrics (`:131-139`).
- **299** — *Create robust evaluations for agentic apps*. Trajectory expectations (`:149-176`),
  `ToolCallEvaluator` (`:177-180`), synthetic data and coverage (`:31-102`).
- **319** — Private Cloud Compute. The on-device/PCC comparison (`:38-45`), quota UX (`:77-95`).
- **205** — the Foundation Models code-along. The six-entry transcript anatomy (`:805-815`),
  instructions naming the tool (`:771-774`).

**Community repositories — attributed as community-measured throughout**

- `john-rocky/coreai-model-zoo` — `knowledge/dynamic-profiles-local-models.md` (two local models
  behind one session; body re-evaluation count; lifecycle ordering; switch-in/switch-back timings;
  two-footprint memory; guided-generation routing beats tool routing on that engine; one-engine-one-
  session), `knowledge/prefix-cache-kv-reuse.md` (the 15.2× / 101× prefix-reuse table and the hybrid
  refusal), `knowledge/fm-provider.md` and `knowledge/coreai-vs-mlx-speed.md` (`@Generable` requires
  `engine.supportsLogits`), `knowledge/agentic-security-checklist.md` (the `onToolCall` chokepoint
  sketch attributed to WWDC26 347, and the `historyTransform` spotlighting/redaction guidance),
  `knowledge/evaluations-framework.md` (`disallowed` as an injection gate).
- [frozen Noema 3.5 snapshot](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md) — the Apple Foundation Models documentation mirror used to cross-check
  242, and `AFMLLMClient.swift` / `AppleFoundationModelAvailability.swift` for the `contextSize`
  historical, unreproduced 8K observation and the availability/quota switch shapes.

**Sessions not in the corpus, and therefore not relied on**

WWDC26 **347** (*Secure your app: mitigate risks to agentic features*) is referenced only through a
community note; every claim sourced to it is marked secondary. Sessions **240, 343, 344, 345** are
absent from the corpus entirely.

[^transcript-mutation-error]: Apple, [`LanguageModelSession.Error.transcriptMutationWhileResponding`](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/error/transcriptmutationwhileresponding), the typed error for mutating the transcript while a request is in progress.
[^supports-locale-floor]: The authoritative Xcode 26.5 interface places [`supportsLocale(_:)`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/notes/sdk-interfaces/FoundationModels-26.5-macos.swiftinterface#L572-L591) in the OS 26.0 `SystemLanguageModel` declaration; the following extension is explicitly OS 26.4 and contains the context-introspection APIs.
