# Dynamic Profiles, modifiers, and session state

**Part 3 · Context, profiles, agentic sessions · Reference 02**

**Version floor:** every symbol in this guide — `LanguageModelSession.DynamicProfile`,
`LanguageModelSession.Profile`, `DynamicInstructions`, `LanguageModelSession.DynamicProfileModifier`,
`SessionPropertyValues`, `@SessionPropertyEntry`, `@SessionProperty`, `TranscriptErrorHandlingPolicy`,
the settable `session.transcript` — is **iOS 27.0 / iPadOS 27.0 / macOS 27.0 / visionOS 27.0**, marked
Beta in the SDK documentation. `apple/foundation-models-utilities` additionally declares
**watchOS 27.0**. There is **no back-deployment**: none of this exists on 26.0, 26.1, 26.3 or 26.4.
The host class `LanguageModelSession` is iOS 26.0 (no watchOS until 27.0), and `Tool` is iOS 26.0 /
watchOS 27.0 — so a 26.x app can have tools and sessions but cannot have profiles. One local
documentation mirror in circulation labels the dynamic-sessions article "Beta (iOS 26.0+)". **That
label is wrong**; Apple's own sample ships `IPHONEOS_DEPLOYMENT_TARGET = 27.0` and every compiled
conformance found in the corpus is annotated `@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)`.

---

## What this covers

The flagship 2026 Foundation Models API, and the mental model that makes it tractable.

A `DynamicProfile` is **not a configuration object**. It is a *projection of your app's `@Observable`
state machine* — the same relationship a SwiftUI `View`'s `body` has to `@State`. Apple's Origami
sample makes this literal: an observable orchestrator holds `mode`, the profile's `body` `switch`es
on it, and **mutating `orchestrator.mode` is the agent handoff.** No new session, no transcript
surgery, no `if` ladder inside your prompt string. That framing — rather than the WWDC session's
"swapping hats" metaphor — is what this guide is built around, because it is what the shipping code
actually does.

Concretely:

- The three composable layers — `DynamicInstructions`, `Profile`, `DynamicProfile` — and the exact
  spelling of each, including the two places where the transcript-derived spellings in wide
  circulation are **wrong**.
- `DynamicInstructions` composition: nesting concatenates instructions *and* tools, conditionals are
  legal, and there is a token-ordering rule that costs you the whole KV cache if you break it.
- The `body` contract: **re-evaluated before every prompt**, must resolve to **exactly one** active
  `Profile`, and must be **pure** — a community measurement recorded seven evaluations across three
  turns.
- The complete modifier catalogue: value modifiers, lifecycle modifiers, `historyTransform`, and the
  three-tier precedence rule that decides which wins.
- Custom modifiers via `DynamicProfileModifier` + an extension on `DynamicProfile`, with a real
  Apple-authored implementation quoted line by line.
- Session properties — `@SessionPropertyEntry` on `SessionPropertyValues`, `@SessionProperty(\.…)`
  in profiles and tools, `session.properties` from outside — and the built-in `history` property,
  which is **lossy and global** where `historyTransform` is **lossless and profile-scoped**.
- `transcriptErrorHandlingPolicy`, the newly-mutable `session.transcript`, and the dedicated
  `LanguageModelSession.Error.transcriptMutationWhileResponding` failure for mutating it while a
  request is in progress.[^transcript-mutation-error]
- Apple's own shipped history modifiers in `foundation-models-utilities`, including the one Apple
  ships with a test that pins its buggy behaviour, and the composition rule that makes **every
  composed example in Apple's own repository inert**.

## What you need

- **Xcode 27** and an iOS/macOS/visionOS 27 target. Nothing here compiles against Xcode 26.
- A device, not the Simulator, for anything you intend to measure.
- Familiarity with `Instructions`, `Prompt`, `Tool`, and `Transcript`. If those are new, read
  [`../../part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md`](../../part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md)
  and
  [`../../part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md`](../../part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md)
  first.
- If you plan to switch models mid-session, you also want the `LanguageModel` protocol material in
  Part 4 and the KV-cache guide in this part. Profile switching and cache invalidation are the same
  event seen from two angles.

---

## Contents

1. [The problem profiles solve](#1-the-problem-profiles-solve)
2. [The framing: a profile is a projection of app state](#2-the-framing-a-profile-is-a-projection-of-app-state)
3. [The three layers, and how to spell them](#3-the-three-layers-and-how-to-spell-them)
4. [`DynamicInstructions`: composition that concatenates](#4-dynamicinstructions-composition-that-concatenates)
5. [`Profile` and the modifier catalogue](#5-profile-and-the-modifier-catalogue)
6. [The `body` contract: re-evaluated, pure, singular](#6-the-body-contract-re-evaluated-pure-singular)
7. [Attaching a profile to a session](#7-attaching-a-profile-to-a-session)
8. [Precedence: three tiers for values, accumulation for callbacks](#8-precedence-three-tiers-for-values-accumulation-for-callbacks)
9. [Lifecycle modifiers](#9-lifecycle-modifiers)
10. [Custom modifiers with `DynamicProfileModifier`](#10-custom-modifiers-with-dynamicprofilemodifier)
11. [Session properties](#11-session-properties)
12. [`history` versus `historyTransform`](#12-history-versus-historytransform)
13. [Apple's shipped history modifiers, and their sharp edges](#13-apples-shipped-history-modifiers-and-their-sharp-edges)
14. [`transcriptErrorHandlingPolicy` and the mutable transcript](#14-transcripterrorhandlingpolicy-and-the-mutable-transcript)
15. [A complete worked profile](#15-a-complete-worked-profile)
16. [Quick reference](#16-quick-reference)
17. [Sources](#17-sources)

---

## 1. The problem profiles solve

In the iOS 26 API, a session's instructions were fixed at construction:

> ✅ **VERIFIED** — from Apple's article *Composing dynamic sessions with instructions and profiles*
> (`/documentation/foundationmodels/composing-dynamic-sessions-with-instructions-and-profiles`):
> *"By default, a language model session evaluates instructions upon initialization, and they remain
> static for the session. The dynamic profiles API allows you to build your app so a session uses
> only what's necessary based on the state of your app. When the context of your app changes, the
> instructions, tools, and model configuration change with it."*

If you wanted two personas — a brainstormer and a tutorial writer — you built two sessions, and then
you owned the problem of moving conversation state between them. WWDC26 session 241 describes exactly
that dead end:

> ✅ **VERIFIED** — WWDC26 session 241, `241:75-79`: *"To implement this feature, I'd start by creating
> a `LanguageModelSession`. Then I'll add more sessions, each with its own models, instructions, and
> tools. **But what if I want the model to autonomously switch modes? Things start to get hairy.**
> Managing context and orchestrating an agentic system like this can involve a lot of boilerplates."*

Session 242 names the two motivating problems more precisely, and they are worth keeping in mind
because they explain why the API looks the way it does:

> ✅ **VERIFIED** — WWDC26 session 242, `242:4-8`: *"The first challenge these APIs solve is **context
> management**. In long running sessions, dynamic profiles let you trim or summarize the transcript to
> keep it within the model's context window."* … *"The second problem these APIs solve is
> **establishing boundaries**. When using multiple models, you should design around capability and
> cost considerations."*

And — unusually candid for a WWDC session — Apple explains why they shipped a *primitive* instead of
an `Agent` type:

> ✅ **VERIFIED** — `242:9-11`: *"This field is changing **week-to-week**. The primitives that we're
> introducing are designed to be flexible, ensuring it's possible to build today's abstractions, and
> tomorrow's."* … *"Dynamic profiles enable context engineering, defining model boundaries, and can be
> scaffolded into just about any architecture."*

Read that as a deliberate refusal to ship an opinionated agent framework in the OS. The opinionated
layer lives in a separately-versioned open-source package, `apple/foundation-models-utilities`, which
is updated between OS releases (§13).

The headline capability, in one sentence: **one session, one transcript, a swappable model and
persona.**

> ✅ **VERIFIED** — `241:100-101`: *"As I select the idea, the model switches to Private Cloud Compute.
> **It still has the full context from the analysis**, but generating creative project ideas benefits
> from the larger model's capabilities."*

That single sentence carries a privacy consequence that Apple states plainly and that you must design
around:

> ✅ **VERIFIED** — `241:103`: *"When using this API, consider **privacy boundaries, model
> capabilities, and cost**."*

Switching a profile's model from `SystemLanguageModel` to `PrivateCloudComputeLanguageModel` — or to a
third-party server model behind `ChatCompletionsLanguageModel` — ships **the accumulated on-device
transcript** to the new backend. Session 242 recommends `historyTransform` as the redaction hook for
exactly this hop:

> ✅ **VERIFIED** — `242:66-68`: *"When moving between models, you may need to trim unnecessary entries
> to stay within the context size. But that's not the only reason for adjusting the model's context.
> You can also improve the model's focus by removing irrelevant entries, or **redact private
> information from existing entries when moving to a less private model**."*

---

## 2. The framing: a profile is a projection of app state

The WWDC session reaches for a costume metaphor:

> ✅ **VERIFIED** — `242:60-62`: *"You can think of this as **swapping hats, or switching agents**. You
> can move from brainstorming to planning, to reviewing. All by changing the mode."*

The metaphor is memorable and slightly misleading — it suggests the session is a thing you *do
something to*. Apple's shipping sample says something sharper. In Origami
(*Origami: Crafting a dynamic tutorial for Apple Intelligence*, iOS/macOS/visionOS 27.0, Swift 6,
61 Swift files), the entire agentic behaviour is:

1. An `@Observable` orchestrator holds `mode`.
2. The profile's `body` `switch`es on `orchestrator.mode`.
3. A reducer mutates `mode`.

That is the whole mechanism. There is no handoff call, no `session.switch(to:)`, no transcript
migration. The profile is a **derived view of app state**, in exactly the sense that a SwiftUI `body`
is a derived view of `@State`. Once you hold that, every other rule in this guide stops being
arbitrary:

| Rule | Why it follows from the framing |
|---|---|
| The `body` is re-evaluated before every prompt | A projection has to re-run when its input changes |
| The `body` must be pure | SwiftUI `body` must be pure, for the same reason |
| Imperative work belongs in lifecycle modifiers | They are the `onAppear`/`task` of this DSL |
| Exactly one `Profile` may be active | A projection resolves to one value |
| The transcript survives a switch | The transcript is the session's, not the profile's |

> ✅ **VERIFIED** — Origami's reducer, `Origami/Models/Orchestrator.swift:165-179`:
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
> `reduce` mutates state and returns `[OrchestratorEffect]`; `execute` performs the async model work.
> Because the profile's `body` reads `orchestrator.mode`, **mutating the mode inside `reduce` *is* the
> profile switch.**

Origami declares three flat enums for this — `OrchestratorMode` (3 cases), `OrchestratorEvent`
(11 cases), `OrchestratorEffect` (9 cases) — in a 55-line file
(`Origami/Models/OrchestratorState.swift`). The AI-specific part of the architecture is 75 lines
(`OrchestratorProfile.swift`). Everything else is a plain Swift state machine you could unit-test
without a model.

### What this buys you that a second session does not

A second `LanguageModelSession` starts with an empty KV cache and an empty transcript. A profile
switch keeps both — though the cache does not survive a *model* change, which is covered in §5.7 and
in this part's KV-cache guide. More importantly, the shared transcript is what makes the *baton-pass*
pattern work at all:

> ✅ **VERIFIED** — `242:128`: *"the **full transcript history is visible to both profiles**, and … the
> profile that receives the baton can carry it across the finish line and provide the final response."*

Origami implements this without any tool call at all. `TutorialInstructions` swaps its entire persona
when a plain Boolean flips:

> ✅ **VERIFIED** — `Origami/Tutorial/Intelligence/TutorialInstructions.swift:12-42`:
>
> ```swift
> struct TutorialInstructions: DynamicInstructions {
>     let orchestrator: Orchestrator
>
>     var body: some DynamicInstructions {
>         if orchestrator.tutorialReady {
>             CoachInstructions(orchestrator: orchestrator)
>         } else {
>             Instructions {
>                 """
>                 You are an expert craft AI assistant. Your job is to generate \
>                 step-by-step tutorial instructions for a craft project. …
>                 DO NOT use the word "I" or mention yourself in the tutorial.
>                 """
>             }
>
>             if orchestrator.project.craftDomain == .origami {
>                 // Origami specific tools and instructions.
>                 OrigamiInstructions()
>             }
>         }
>     }
> }
> ```

When `tutorialReady` flips, the *same* session's tutorial-generator persona is replaced wholesale by
the coach persona — different instructions, a different tool set — with the whole conversation intact.
The tool sets are disjoint: in tutorial mode the session has `FetchOrigamiTemplate` and nothing else;
the instant `tutorialReady` is true it has `CalculatePaperSize`, `ConvertMeasurement` and
`MovePhotoToStepTool` and *not* `FetchOrigamiTemplate`.

Three tools appear and three disappear because a Boolean changed. That is the claim "swap tools in and
out" made concrete, and it is the thing that is genuinely hard to build by hand.

---

## 3. The three layers, and how to spell them

There are three types, and the documentation, the WWDC transcripts and the shipping sample do not all
spell them the same way. This section fixes the spellings first, because two of the spellings in wide
circulation do not compile.

| Layer | What it is | Where it lives |
|---|---|---|
| `DynamicInstructions` | A reusable bundle of `Instructions` blocks, `Tool` instances, and nested `DynamicInstructions`. Composable; nesting concatenates. | **Top level**, not nested |
| `LanguageModelSession.Profile` | Binds one `DynamicInstructions` tree to one model configuration (model, temperature, sampling, reasoning level, tool-calling mode, history transform, lifecycle hooks). | Nested under `LanguageModelSession` |
| `LanguageModelSession.DynamicProfile` | The coordination layer. Decides which `Profile` is active right now. | Nested under `LanguageModelSession` |

> ✅ **VERIFIED** — declarations from Apple's documentation index:
>
> ```swift
> protocol DynamicInstructions                                  // iOS 27.0+ Beta
> var body: Self.Body { get }
> associatedtype Body
>
> @resultBuilder struct DynamicInstructionsBuilder              // iOS 27.0+ Beta
> struct DynamicInstructionsForEach<Data, ID, Content>
>   where Data: RandomAccessCollection, ID: Hashable, Content: DynamicInstructions
>
> struct LanguageModelSession.Profile                           // conforms to DynamicProfile
> init(_:)                                                      // "Creates a profile that contains dynamic instructions."
>
> protocol LanguageModelSession.DynamicProfile                  // iOS 27.0+ Beta
> var body: Self.Body { get }
> associatedtype Body
>
> @resultBuilder struct LanguageModelSession.DynamicProfileBuilder
> protocol LanguageModelSession.DynamicProfileModifier          // iOS 27.0+ Beta
> func body(content: Content) -> some LanguageModelSession.DynamicProfile
> ```
>
> Conforming types of `DynamicProfile`: `AnyDynamicProfile`, `ConditionalDynamicProfile`,
> `DynamicProfileModifierContent`, `ModifiedDynamicProfile`, and **`Profile`**.
> Conforming types of `DynamicInstructions`: `AnyDynamicInstructions`,
> `ConditionalDynamicInstructions`, `DynamicInstructionsForEach`, `EmptyDynamicInstructions`,
> **`Instructions`**, `TupleDynamicInstructions`.

Note the last one: **`Instructions` itself conforms to `DynamicInstructions`.** That is why you can
write a bare `Instructions { … }` block inside a `DynamicInstructions` body and why a `Profile` can
accept either.

### 3.1 The conformance is nested; the `body` type is short

Here is the correction that matters most, and it is the one a reconstructed guide gets wrong. The
protocol conformance uses the **nested** name. The `body`'s opaque return type inside a conforming
type uses the **short** name.

> ✅ **VERIFIED** — Apple's Origami sample, `Origami/Models/OrchestratorProfile.swift:11-75`, the
> single most load-bearing listing in this guide:
>
> ```swift
> struct OrchestratorProfile: LanguageModelSession.DynamicProfile {
>     var orchestrator: Orchestrator
>
>     // Brainstorm and tutorial work best on a server model. The sample
>     // defaults to the on-device system model so it runs out of the box.
>     // To use Private Cloud Compute, request access to the managed
>     // `com.apple.developer.private-cloud-compute` entitlement at
>     // https://developer.apple.com/contact/request/private-cloud-compute/,
>     // then replace the `serverModel` initialization with the line below.
>     // var serverModel = PrivateCloudComputeLanguageModel()
>     var serverModel = SystemLanguageModel()
>
>     var body: some DynamicProfile {
>         switch orchestrator.mode {
>         case .brainstorm:
>             if !isOnDevice {
>                 Profile {
>                     BrainstormInstructions(orchestrator: orchestrator)
>                 }
>                 .model(serverModel)
>                 .temperature(1.0)
>             } else {
>                 // Brainstorming is lower-quality on-device than with
>                 // Private Cloud Compute.
>                 Profile {
>                     BrainstormInstructions(orchestrator: orchestrator)
>                 }
>                 .model(SystemLanguageModel())
>             }
>
>         case .tutorial:
>             if !isOnDevice {
>                 Profile {
>                     TutorialInstructions(orchestrator: orchestrator)
>                 }
>                 .model(serverModel)
>                 .reasoningLevel(.deep)
>             } else {
>                 // Tutorial generation is lower-quality on-device than with
>                 // Private Cloud Compute.
>                 Profile {
>                     TutorialInstructions(orchestrator: orchestrator)
>                 }
>                 .model(SystemLanguageModel())
>                 .historyTransform(shortHistory(_:))
>             }
>         case .term:
>             Profile {
>                 TermInstructions(orchestrator: orchestrator)
>             }
>             .model(SystemLanguageModel())
>             .historyTransform(shortHistory(_:))
>         }
>     }
>
>     private var isOnDevice: Bool {
>         type(of: serverModel) == SystemLanguageModel.self
>     }
>
>     /// Returns the most recent four entries so longer on-device sessions
>     /// stay within the smaller context window.
>     private func shortHistory(_ entries: [Transcript.Entry]) -> [Transcript.Entry] {
>         entries.suffix(4)
>     }
> }
> ```

Read that listing twice; almost every rule in this guide is visible in it.

The short `some DynamicProfile` works because the protocol vends nested typealiases —
`DynamicProfile.DynamicProfile` and `DynamicProfile.Profile` are both listed in the documentation
index — which are visible inside a conforming type. It is the same ergonomic as SwiftUI's
`View`/`some View`.

> 🟡 **RECONSTRUCTED — both spellings compile, and Apple uses both.** Apple's *documentation article*
> writes `var body: some LanguageModelSession.DynamicProfile` in all three of its examples; Apple's
> *sample project* writes `var body: some DynamicProfile`. Since the sample compiles and ships, the
> short form is definitely legal inside a conforming type; since the long form is fully qualified, it
> is legal everywhere. **Use the short form inside conforming types** — it matches Apple's own code
> and it is what the nested typealiases exist for. Use the long form in a free-standing extension
> (§10), where the nested typealiases are not in scope from a bare `Self`.

### 3.2 The model is a modifier, not an initialiser label

> ⚠️ **This is the second correction, and it is the one most likely to be in code you copied from a
> conference write-up.**
>
> ```swift
> // ❌ Does not appear anywhere in Apple's shipping sample code.
> Profile(model: PrivateCloudComputeLanguageModel()) {
>     BrainstormInstructions(orchestrator: orchestrator)
> }
>
> // ✅ VERIFIED — Origami, and Apple's documentation article, both use this shape.
> Profile {
>     BrainstormInstructions(orchestrator: orchestrator)
> }
> .model(serverModel)
> ```
>
> `Profile` takes a trailing content closure. The model arrives through the **`.model(_:)` modifier**,
> exactly like `.temperature(_:)` and `.reasoningLevel(_:)`. `Profile`'s only documented initialiser
> is `init(_:)` — *"Creates a profile that contains dynamic instructions."*
>
> ✅ **RESOLVED (2026-07-29) — no `Profile(model:)` overload exists in the 27.0 beta SDK
> interface.** The grep this box asked for has been run.
> `LanguageModelSession.Profile` declares exactly **one** initializer:
> `public init(@DynamicInstructionsBuilder _ dynamicInstructions: () -> some DynamicInstructions)`
> — ✅ **SDK-verified** (`FoundationModels-27.0-macos.swiftinterface:830-843`). The model arrives
> only through the modifier, which has **two** overloads —
> `func model(_ model: any LanguageModel)` and `func model(_ model: some LanguageModel)`, both
> `-> some DynamicProfile` (`:966-968`) — so it accepts an existential or a concrete model. Every
> `Profile(model:)` spelling in circulation is a reconstruction that does not compile against the
> 27.0 beta. (Per this repo's honesty rule: this is absence from the captured beta interface, not a
> promise about the final SDK — but the shipping sample, the docs article, and the interface now
> all agree.)

Two smaller spelling corrections from the same listing:

- **`.temperature(1.0)` takes a `Double`.** The session narration says "set the temperature to 1",
  which is ambiguous; Apple's sample and documentation article both write a floating-point literal
  (`1.0`, `0.8`, `0.1`, `0.2`, `0.5`). ✅ VERIFIED.
- **`.reasoningLevel(.deep)`** is exactly right, and its sibling cases are `.light` and `.moderate`.
  ✅ VERIFIED (`.deep` from Origami; the three-case list from the Private Cloud Compute article).

### 3.3 One more model-spelling note

Origami writes `SystemLanguageModel()` — a bare initialiser — and never writes
`SystemLanguageModel.default` anywhere in 61 files.

> ✅ **VERIFIED** — the bare initialiser is real and is the 2026 house style. Its full form is
> `convenience init(useCase: SystemLanguageModel.UseCase = .general, guardrails: SystemLanguageModel.Guardrails = Guardrails.default)`,
> so `SystemLanguageModel()` is that with both defaults. `static var default` still exists (Apple's
> Book Tracker sample uses both spellings in the same target), so this is a style change, not a
> deprecation.

Origami also ships a runtime model-kind test that is worth stealing, because it lets one profile
struct express "do the expensive thing only if we are not on-device":

```swift prelude:guide-context
private var isOnDevice: Bool {
    type(of: serverModel) == SystemLanguageModel.self
}
```

`serverModel` is a **stored property of the profile struct**, referenced from several branches. That
is what makes flipping the whole app to Private Cloud Compute a one-line change — uncomment one line,
and every branch that reads `serverModel` follows.

---

## 4. `DynamicInstructions`: composition that concatenates

`DynamicInstructions` is the layer you will write the most of. It is a result-builder body containing
three kinds of thing:

> ✅ **VERIFIED** — from the dynamic-sessions article: *"In the `body` of your type, include any
> `Instructions` block, `Tool` instances, and nested `DynamicInstructions`."*

That is the whole surface: text, tools, and other `DynamicInstructions`. The protocol is **top-level**
— `struct MyThing: DynamicInstructions`, not `LanguageModelSession.DynamicInstructions` — and the body
type is `some DynamicInstructions`.

> ✅ **VERIFIED** — Apple's Origami sample,
> `Origami/Tutorial/Intelligence/OrigamiInstructions.swift:11-31`. This is the real name of the type
> WWDC26 session 242 called "OrigamiExpert":
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
>             - Clearly state how the paper should look at the end of each \
>             step
>             - Instead of saying "repeat steps..." fully list out all steps \
>             in a clear way e.g. "Now repeat step N for the right side"
>             """
>         )
>
>         // Fetch the templates tool.
>         FetchOrigamiTemplate()
>     }
> }
> ```

Note that `Instructions(…)` (a value initialiser taking a string) and `Instructions { … }` (a builder)
both appear in adjacent files in the same sample and both compile. Use whichever reads better; there
is no semantic difference.

### 4.1 Nesting concatenates instructions *and* tools

This is the composability claim, and it is worth being precise about what "composable" means here.

> ✅ **VERIFIED** — `242:42`: *"DynamicInstructions are also **composable** so **nesting `OrigamiExpert`
> inside another `DynamicInstructions` body will concatenate the instructions and tools together**."*

Confirmed by the sample: `TutorialInstructions` (quoted in §2) embeds `CoachInstructions` and
`OrigamiInstructions` as *values* in its body, and the resulting session gets the union of their
instructions text and the union of their tools. So a `DynamicInstructions` type is a genuine
component: you can ship a "domain expert" as a struct and drop it into any persona that needs it.

Origami's coach component shows the tools-come-with-it half:

> ✅ **VERIFIED** — `Origami/Coach/CoachInstructions.swift:12-36`:
>
> ```swift
> struct CoachInstructions: DynamicInstructions {
>     let orchestrator: Orchestrator
>
>     var body: some DynamicInstructions {
>         Instructions {
>             """
>             You are an expert craft tutorial coach.
>             When you are asked to valuate the user's in-progress work \
>             from a photo: compare their work against the tutorial step \
>             they appear to be on and provide specific, constructive feedback.
>             …
>             If the photo appears like they did the step incorrectly, \
>             first check if it might be correct for a **different** step \
>             ahead in the tutorial. Next help them find the correct step or else \
>             kindly guide them towards a fix. To move a photo to the correct step. \
>             call the movePhotoToStep tool.
>             """
>         }
>
>         CalculatePaperSize()
>         ConvertMeasurement()
>         MovePhotoToStepTool(orchestrator: orchestrator)
>     }
> }
> ```

Three tools, declared inline, travelling with the persona that needs them. Note also
`MovePhotoToStepTool(orchestrator: orchestrator)` — dependency injection into a tool, which is how a
tool call reaches your app's state. (The consent-request pattern that tool implements is covered in
[the tools guide](../../part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md).)

### 4.2 Conditionals: a bare `if` is legal here

The instructions builder is more permissive than the profile builder:

> ✅ **VERIFIED** — Origami's `TutorialInstructions` (§2) contains a bare `if` with no `else`
> (`TutorialInstructions.swift:36-39`), and `TermInstructions.swift:20-37` does the same. The profile
> builder does **not** permit this — see §6.3.

```swift prelude:guide-context
// ✅ Legal in DynamicInstructionsBuilder.
if orchestrator.project.craftDomain == .origami {
    OrigamiInstructions()
}
```

Apple's documentation article uses the same shape for two independent flags:

> ✅ **VERIFIED** — from the dynamic-sessions article:
>
> ```swift
> struct PresentationInstructions: DynamicInstructions {
>     // The data source for conditional instructions.
>     var isEditingImage = true
>     var isEditingAnimation = false
>
>     var body: some DynamicInstructions {
>         // The instructions and tools that remain the same across any use of this type.
>         Instructions {
>             "Help people improve their presentation."
>         }
>         ListPhotosTool()
>         AddPhotoTool()
>
>         // Depending on the state of the app, include additional instructions
>         // that provide the model with more task-specific instructions and tools.
>         if isEditingImage {
>             ImageEditingInstructions()
>         }
>
>         if isEditingAnimation {
>             AnimationEditingInstructions()
>         }
>     }
> }
> ```

### 4.3 The ordering rule — static first, conditional last

There is one non-obvious rule about *where* in the body you put conditional content, and breaking it
costs you the KV cache on every toggle.

> ✅ **VERIFIED** — from Apple's *Optimizing key-value caching in language model sessions* article:
> *"Place instructions and tools that remain constant at the top of your `DynamicInstructions` body,
> and group conditional content at the bottom. **The framework flattens the resolved instructions and
> tool definitions in the order you declare them**, so content that appears first in the body occupies
> earlier positions in the token sequence."*
>
> And, as an explicit NOTE on the same page: *"Placing the conditional content **before** the static
> instructions and tools invalidates the cached values and leads to unnecessary recomputation."*

The mechanism, from the same article: *"A session typically arranges its content into a token sequence
with a specific order, like instructions appearing at the top, tool definitions coming next, and then
transcript entries follow at the end. Each cached value in the sequence depends on every token that
precedes it."*

So the layout is:

```
[ instructions ][ tool definitions ][ transcript entries ]
       ↑ change anything here and everything after it recomputes
```

Put a conditional `Instructions` block at position 0 and every toggle of that condition invalidates
the tool definitions *and the entire transcript*. Put it last and you invalidate only itself.

> ⚠️ **SILENT FAILURE — a mis-ordered `DynamicInstructions` body has no compiler diagnostic, no
> runtime warning, and no error. It is purely a latency regression that grows with conversation
> length.** The symptom is time-to-first-token climbing turn over turn while your prompt stays the
> same size. The only way to see it is the **cache-hit-rate** read in the Foundation Models
> Instruments template — cached input tokens ÷ total input tokens. Note that WWDC26 session 242 tells
> you to "check the debugging video for detecting cache invalidations," and session 243 never actually
> names a cache metric; the metric is documented only in Apple's written performance article. Budget
> time for that discrepancy if you go looking.

The same article gives the accuracy-side rule for tools, which is stronger than most people expect:

> ✅ **VERIFIED**: *"When you use `DynamicInstructions`, **define the tools you need up front and keep
> that set unchanged**."* … *"Removing a tool the model previously used can cause the model to produce
> unexpected results because it sees references in the transcript for a tool that no longer exists in
> its tool definitions. If you do remove any tools, also remove any associated output that refers to
> them."* … *"**Adding a new tool late in a conversation can produce unexpected behavior.** The model
> follows patterns established in earlier turns and might not incorporate a newly available tool into
> its responses."*

There is real tension here: §2 celebrated Origami swapping three tools in and out, and this article
tells you to keep the tool set unchanged. Both are Apple. The reconciliation is that Origami swaps
tools at a **mode boundary** — a deliberate, user-visible transition where a full cache reset and a
persona change are what you want — not on every turn. Session 242's own worked example of the failure
mode is the give-away:

> ✅ **VERIFIED** — `242:179-184`: *"Let's say I have a session where I asked the model to think of fun
> origami project names. And then let's say I **add a generate title tool to the session**, and prompt
> it for more ideas. What do you expect will happen next? If we're lucky, the model will use the tool
> like we want. But **it's also possible that the model will notice it previously generated titles
> without the tool, and may think it's supposed to do that again. That's not what we want. Our history
> modification confused the model.**"*

And the underlying principle, stated more sharply in the written article than in any session:

> ✅ **VERIFIED**: *"Modifying the transcript impacts model accuracy because **there's no reliable way
> for the model to distinguish between information that never existed and information that did exist
> but was removed from the context**. A model treats whatever's in the context as the complete picture
> and reasons confidently from incomplete evidence."*

### 4.4 ⚠️ The instructions/toolset drift bug

This is the defect WWDC26 session 243's entire Instruments walkthrough is built around, and it is the
canonical `DynamicInstructions` failure.

> ⚠️ **SILENT FAILURE — naming a tool in your instructions text without registering it in the body
> produces an infinite loop and no error whatsoever.**
>
> ✅ **VERIFIED** — `243:98-103`: *"**The prompt references the `switchToTutorialMode` tool but that
> tool isn't actually configured with this instruction.**"* … *"Without it, the app has no way to
> switch from brainstorm mode to tutorial mode, so the crafter gets stuck in a loop."* … *"Looking at
> the subsequent nodes in the tree, **this was a silent failure. The model kept accepting input and
> making tool calls but never threw an error. There was no clear signal that anything had gone wrong.
> That makes it a hard bug to catch.**"*

The structural reason is that **the `Instructions` block is text and the tool list is code, and nothing
cross-checks them.** You can rename a tool and leave its old name in three instruction strings; the
compiler is happy.

Two defences, in order of cost:

1. **A test.** Enumerate the tool names your instructions text mentions and assert each is present in
   the resolved tool set. Cheap, and it catches the rename case forever.
2. **The Instruments Instructions-node inspector**, which is the only place that shows the instruction
   text and its bound tool list side by side (`243:96-97`: *"The inspector shows that this instruction
   only had one tool associated with it."*).

The Instructions **lane** in the same trace is the profile-switch visualiser: one contiguous region
per resolved instruction set. If your profile is supposed to switch and the lane shows a single
unbroken region, the switch never happened (`243:80`). After Apple's fix, *"The Instructions lane now
shows two distinct instructions active during this experience"* (`243:117`).

One timing fact from that walkthrough is worth internalising, because it explains a class of
"my switch didn't take effect" reports:

> ✅ **VERIFIED** — `243:124-126`: *"**The instruction change happened after the second model inference
> of Request 2.** That inference resulted in a tool call to `switchToTutorialMode`, passing the
> selected craft as an argument. And **in the following request, the instructions correctly switched
> over to the tutorial generator**."*

**A profile switch triggered by a tool call takes effect on the *next* request, not mid-request.** The
tool mutates your state; the body re-runs at the next prompt boundary.

### 4.5 `DynamicInstructionsForEach`

> ✅ **VERIFIED** — the type exists and is SwiftUI-`ForEach`-shaped:
> ```swift
> struct DynamicInstructionsForEach<Data, ID, Content>
>   where Data: RandomAccessCollection, ID: Hashable, Content: DynamicInstructions
> ```
> Apple's own `foundation-models-utilities` package uses the **nested** spelling at a call site —
> `DynamicInstructions.ForEach(Array(skills.enumerated()), id: \.element.name)`
> (`Sources/FoundationModelsUtilities/Skills/Skills.swift:149`) — rendering one instructions block per
> skill. So both `DynamicInstructionsForEach` and `DynamicInstructions.ForEach` name the same thing,
> the way SwiftUI's `ForEach` does.

> ✅ **RESOLVED (2026-07-29) — the initialiser list is exactly two.**
> ✅ **SDK-verified** (`FoundationModels-27.0-macos.swiftinterface:784-793`):
>
> ```swift
> init(_ data: Data, id: KeyPath<Data.Element, ID>,
>      @DynamicInstructionsBuilder content: @escaping (Data.Element) -> Content)
> // and, where Data.Element: Identifiable, ID == Data.Element.ID:
> init(_ data: Data, @DynamicInstructionsBuilder content: @escaping (Data.Element) -> Content)
> ```
>
> So the `Identifiable`-constrained overload without `id:` **does** exist; a `Range<Int>` overload
> does **not** (use the `id:` form over a range, e.g. `\.self`). The nested spelling is a
> typealias: `extension DynamicInstructions { typealias ForEach = DynamicInstructionsForEach }`
> (`:749-753`).

---

## 5. `Profile` and the modifier catalogue

A `Profile` is one `DynamicInstructions` tree plus one configuration. Configuration arrives entirely
through modifiers.

> ✅ **VERIFIED** — `242:33`: a `Profile` is *"made up of **instructions, tools, and modifiers** for
> configuring things like the model, temperature, samplingMode and more."*

### 5.1 The complete list

> ✅ **VERIFIED** — the following is the modifier list from Apple's `DynamicProfile` documentation,
> with Apple's own one-line descriptions. Because `Profile` conforms to `DynamicProfile`, every one of
> these applies to both a `Profile` and to a whole `DynamicProfile` (see §8 for what that means).

**Value modifiers — configure the model**

| Modifier | Apple's description | Notes |
|---|---|---|
| `model(_:)` | "Sets the model." | Takes `any LanguageModel`. Moved *into the framework* at Xcode 27 beta 3 — before that, `foundation-models-utilities` shipped its own. |
| `temperature(_:)` | "Sets the model temperature." | `Double`. |
| `samplingMode(_:)` | "Sets the samping mode." *(Apple's typo)* | See §5.2. |
| `reasoningLevel(_:)` | "Sets the reasoning level." | `.light` / `.moderate` / `.deep`. See §5.3. |
| `maximumResponseTokens(_:)` | "Sets the maximum response tokens." | See the warning in §5.4. |
| `toolCallingMode(_:)` | *(tool modifier group)* | `.allowed` / `.disallowed` / `.required`. See §5.5. |
| `transcriptErrorHandlingPolicy(_:)` | "The session's policy for managing the transcript when errors occur." | See §14. |
| `modifier(_:)` | "Apply a modifier to the dynamic profile." | The entry point for custom modifiers. See §10. |

> ✅ **SDK-verified addendum (2026-07-29)** — the value modifiers' exact signatures, from
> `FoundationModels-27.0-macos.swiftinterface:965-982`. Every configuration modifier takes an
> **Optional** and returns `some DynamicProfile`: `temperature(_: Double?)`,
> `samplingMode(_: GenerationOptions.SamplingMode?)`, `maximumResponseTokens(_: Int?)`,
> `reasoningLevel(_: ContextOptions.ReasoningLevel?)`,
> `toolCallingMode(_: GenerationOptions.ToolCallingMode?)`,
> `transcriptErrorHandlingPolicy(_: TranscriptErrorHandlingPolicy?)` — so passing `nil` is legal
> and reads as "no opinion at this level" (consistent with §8's precedence model, though the
> nil-clearing semantics are not separately documented). `model(_:)` has two overloads
> (`any LanguageModel` / `some LanguageModel`, non-optional), and
> `historyTransform(_: @escaping ([Transcript.Entry]) -> [Transcript.Entry])` is synchronous and
> non-throwing — an `async` transform does not compile.

**Lifecycle modifiers — run your code at session events**

| Modifier | Apple's description |
|---|---|
| `onActivate(perform:)` | "Runs when the profile becomes active and allows for set up work." |
| `onDeactivate(perform:)` | "Runs when the profile becomes inactive and allows for teardown work." |
| `onPrompt(perform:)` | "Runs after the user prompt appends to the transcript, but before the model request starts." |
| `onResponse(perform:)` | "Runs after the model produces a response." |
| `onToolCall(perform:)` | "Runs when the model invokes a tool." |
| `onToolOutput(perform:)` | "Runs when a tool call produces output." |
| `onReasoning(perform:)` | "Runs an action whenever this dynamic profile produces reasoning." |

`onReasoning` is listed under the generic "Instance Methods" section of the documentation rather than
in the article's lifecycle table — treat it as real but under-documented, and see §9.

**History**

| Modifier | Apple's description |
|---|---|
| `historyTransform(_:)` | "Apply a transformation to the history prior to invoking the model." |

Plus a fourth group that is not in the framework at all — the history modifiers shipped by
`apple/foundation-models-utilities` as extensions on `DynamicProfile`. Those are §13.

> ✅ **RESOLVED (2026-07-29) — there is no `.contextOptions(_:)` profile modifier in the 27.0 beta
> interface.** The complete built-in modifier surface on
> `LanguageModelSession.DynamicProfile` is read verbatim at
> `FoundationModels-27.0-macos.swiftinterface:957-1028`: `modifier(_:)`, `model(_:)` (×2),
> `temperature(_:)`, `samplingMode(_:)`, `maximumResponseTokens(_:)`, `reasoningLevel(_:)`,
> `toolCallingMode(_:)`, `historyTransform(_:)`, `transcriptErrorHandlingPolicy(_:)`, and the seven
> lifecycle hooks — nothing else. The documentation mirror's `.contextOptions(...)` modifier does
> not compile against this interface; per-call `contextOptions:` (`ContextOptions` itself is
> SDK-verified at `:3132-3136`) and the `.reasoningLevel(_:)` modifier (which takes the *same*
> `ContextOptions.ReasoningLevel?` type, `:976`) are the two real surfaces. **Use
> `.reasoningLevel(_:)` on the profile, and pass `contextOptions:` at the call site if you need
> `includeSchemaInPrompt`.**

### 5.2 `samplingMode`

`samplingMode` is named in the WWDC narration and in Apple's modifier list, but no sample exercises
it. What *is* verified is the underlying type, because it is shared with `GenerationOptions`:

> ✅ **VERIFIED** — `GenerationOptions.SamplingMode` factories are `greedy`, `random(top:seed:)` and
> `random(probabilityThreshold:seed:)`; the nested `Kind` enum's cases are `greedy`, `randomTopK(_:seed:)`
> and `randomProbabilityThreshold(_:seed:)`. **Note that the factory name and the `Kind` case name
> differ** — `random(top:)` produces `.randomTopK`. Apple renamed these during the beta: the
> `foundation-models-utilities` beta-3 commit message reads *"Renamed SamplingMode enum cases —
> `.top` → `.randomTopK` and `.nucleus` → `.randomProbabilityThreshold`."* If you are reading code
> written against beta 1, expect the old names.

> ⚠️ **Seed footgun, stated verbatim on both `random` documentation pages:** *"Setting a random seed
> is **not guaranteed** to result in fully deterministic output. It is **best effort**."* Do not build
> a test that asserts byte-identical output from a fixed seed.

### 5.3 `reasoningLevel` and where it belongs

> ✅ **VERIFIED** — `.reasoningLevel(.deep)` on a `Profile`, from Origami's tutorial branch.
> Apple's documentation article also shows the expression form:
> `.reasoningLevel(likesAstronomy ? .deep : .light)`.

> ✅ **VERIFIED** — `242:52-53`: *"We'll also configure `reasoningLevel`, which is **a capability
> available to most server models**. This controls the model's capacity to think through the problem
> before responding."*

That "most server models" qualifier matters. Setting `.reasoningLevel(.deep)` on a profile whose model
is `SystemLanguageModel` is not an error — but there is nothing in the corpus that says it does
anything either.

> 🔴 **GAP — the behaviour of `reasoningLevel` on a model that does not support reasoning is
> unverified.** Does it throw? Silently no-op? Get clamped? No sample sets it on an on-device model,
> and no documentation page addresses it. **Safe default: set it only inside a branch you know is
> bound to a reasoning-capable model** — Origami's structure does exactly this by putting
> `.reasoningLevel(.deep)` only in the `!isOnDevice` branch. Resolving this needs either a forum answer
> or a device measurement comparing `LanguageModelSession.Usage.Output.reasoningTokenCount` with the
> level set and unset.

### 5.4 `maximumResponseTokens`

> ⚠️ **VERIFIED warning, from Apple's context-window article:** *"Only use `maximumResponseTokens` to
> prevent verbose responses. **Limiting tokens can cause the model to generate incomplete or
> grammatically incorrect responses, like 'A cat is a small.'**"*

It is a cost and latency control, not a formatting control. If you want short answers, ask for short
answers in the instructions.

### 5.5 `toolCallingMode` on a profile

`toolCallingMode` is one of two places you can control tool calling; the other is
`GenerationOptions` at the call site. The full treatment is in
[the tools guide](../../part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md);
what belongs here is the *profile* idiom, because Apple's documentation names dynamic profiles as one
of the two sanctioned exits from `.required`.

> ✅ **VERIFIED**, stated on both the `ToolCallingMode` page and the tool-calling article: *"When you
> set the mode to `required`, you must define an exit condition by either throwing an error from a
> tool's `call(arguments:)` method **or by changing the mode dynamically using a
> `LanguageModelSession.DynamicProfile`**; otherwise, the model continues to call the tool."*

And WWDC26 puts it more bluntly:

> ✅ **VERIFIED** — `242:149-150`: *"Here's the most important thing to remember. When tool calling is
> required, **the model is essentially in a while loop — it is your job to ensure that there is an exit
> condition of some kind**."*

The canonical profile-shaped exit, straight from Apple's documentation, combines a session property
with a conditional mode:

> ✅ **VERIFIED** — from Apple's `GenerationOptions.ToolCallingMode` documentation:
>
> ```swift
> extension SessionPropertyValues {
>     @SessionPropertyEntry
>     var toolCallCount: Int = 0
> }
>
> struct RecipeDynamicProfile: LanguageModelSession.DynamicProfile {
>     @SessionProperty(\.toolCallCount)
>     var toolCallCount
>
>     var body: some LanguageModelSession.DynamicProfile {
>         Profile {
>             BreadDatabaseTool()
>         }
>         .toolCallingMode(toolCallCount < 1 ? .required : .allowed)
>         .onToolCall {
>             toolCallCount += 1
>         }
>     }
> }
> ```

There is an independently-written, compiling variant of the same pattern in `ml-explore/mlx-swift-lm`'s
integration tests, which uses a two-branch body instead of a ternary and flips all the way to
`.disallowed`:

> ✅ **VERIFIED** —
> `IntegrationTesting/IntegrationTestingTests/MLXFoundationModelsIntegration/ToolCalling/StructuredToolOutputSessionTests.swift:54-76`:
>
> ```swift
> var body: some LanguageModelSession.DynamicProfile {
>     if toolCallCount == 0 {
>         Profile {
>             Instructions {
>                 "Call the lookup tool once. After it returns, answer with the value of its requiredToken field exactly."
>             }
>             StructuredLookupTool()
>         }
>         .model(model)
>         .toolCallingMode(.required)
>         .onToolCall {
>             toolCallCount += 1
>         }
>     } else {
>         Profile {
>             Instructions {
>                 "Use the latest tool output. Return its requiredToken field exactly and no other text."
>             }
>         }
>         .model(model)
>         .toolCallingMode(.disallowed)
>     }
> }
> ```

Two independent sources, two spellings of the same idea. Note what the second one buys: in the
`else` branch the tool is *not declared at all*, so the model cannot call it even if it wants to.
`.disallowed` is implemented by sending zero tool definitions — verified in `mlx-swift-lm`'s
`ToolCallingModeResolution.swift:34-40`, where `mode.kind == .disallowed` returns `[]`.

> ⚠️ **SILENT FAILURE — the `.required` loop does not time out.** There is no iteration cap, no
> deadline, and no thrown error. A `.required` profile whose exit condition never becomes true will
> keep calling tools until the context window fills, at which point you get
> `LanguageModelError.contextSizeExceeded` — many seconds and many tokens later, from a call site that
> looks like a plain `respond(to:)`. Write the exit *first*, then the tool.

### 5.6 The Private Cloud Compute entitlement

Both Origami and Apple's Core Spotlight sample ship the same comment block, byte for byte, and it is
the only place in the corpus that documents the entitlement process:

> ✅ **VERIFIED** — `Origami/Models/OrchestratorProfile.swift`:
>
> ```swift
> // Brainstorm and tutorial work best on a server model. The sample
> // defaults to the on-device system model so it runs out of the box.
> // To use Private Cloud Compute, request access to the managed
> // `com.apple.developer.private-cloud-compute` entitlement at
> // https://developer.apple.com/contact/request/private-cloud-compute/,
> // then replace the `serverModel` initialization with the line below.
> // var serverModel = PrivateCloudComputeLanguageModel()
> var serverModel = SystemLanguageModel()
> ```
>
> Origami's `Origami.entitlements` contains **only** `com.apple.security.app-sandbox`. The PCC
> entitlement is **managed** — you apply for it.

Design consequence: build your profile so the server model is a **single stored property**, referenced
from every branch that wants it, exactly as Origami does. Then adopting PCC is a one-line edit and a
provisioning change, not a refactor.

Also note the model-name shorthand in the WWDC captions: session 242 says
"PrivateCloudComputeLanguageModel" once and "PCCLanguageModel" twice. **There is no `PCCLanguageModel`
type.** Two independent sample archives write `PrivateCloudComputeLanguageModel()`.

### 5.7 Every profile switch is a cache reset

Before you design a profile graph, internalise this:

> ✅ **VERIFIED** — from Apple's KV-caching article: *"**Switching from one profile to another
> typically changes the entire prefix — which invalidates the cache for the full transcript — so treat
> it as a deliberate reset.** Design your dynamic profiles so transitions between your profiles occur
> at natural boundaries in the conversation rather than on every turn."*

> ✅ **VERIFIED** — `242:170-171`: *"Generally, **appending to the transcript preserves the KV cache,
> and minimizes the time-to-first-token**. If you rewrite history by removing entries, changing the
> attached tools, or updating the instructions, that will typically trigger a cache invalidation, and
> can increase latency."*

And Apple's framing of what changed this year, which is the best one-sentence summary of the whole
2026 release:

> ✅ **VERIFIED** — `242:172-174`: *"We didn't talk about this last year because we **intentionally
> shaped `LanguageModelSession` APIs to be append only**. By default, they ensured optimal use. But
> **this year, we're taking the training wheels off**, so to say."*

Two numbers, both **community-measured** and both from a third-party `LanguageModel` provider rather
than Apple's models — treat them as order-of-magnitude signals only, not as Apple figures:

> **Community-measured** (`john-rocky/coreai-model-zoo` knowledge notes, two local MLX models of
> 0.6B and 4B on a Mac, no OS build or date recorded): switching models re-prefills the shared
> transcript on the newly-active engine. Switch-in first-delta **2.35 s**, switch-back **0.94 s**.
> Two resident models cost two footprints — **~920 MB `phys_footprint`** after the measured turns.
> The author's conclusion: *"Append-only KV reuse only helps across consecutive same-model turns."*

> ✅ **VERIFIED** — `242:175`: *"It's important to understand that **different models have different
> caching behavior and the only way to be certain is by measuring**."*

---

## 6. The `body` contract: re-evaluated, pure, singular

Three rules govern the `body`. Two are stated by Apple; the third is a community measurement that
sharpens the first, and it is the one that will bite you.

### 6.1 Re-evaluated before every prompt

> ✅ **VERIFIED** — from Apple's dynamic-sessions article: *"**Because the body of dynamic instructions
> re-evaluates before each call to the model, the model always sees a snapshot of your app's current
> state.**"*

> ✅ **VERIFIED** — `242:59`: *"Note that **the body of a `DynamicProfile` is re-evaluated each time
> the model is prompted**, so as the app moves between each mode, the persona of the
> `LanguageModelSession` changes."*

> ✅ **VERIFIED** — `243:8-9`: *"`DynamicInstructions` lets you specify **exactly which instructions
> and tools the model can access**. It **re-evaluates before every request**, so the model always has
> the right context for the task at hand."*

This is the whole trick. You never call anything to switch profiles. You mutate observable state and
the next prompt sees a different world.

### 6.2 ⚠️ The `body` must be pure — it runs more than once per turn

Apple says "each time the model is prompted", which reads as *once per turn*. It is not.

> ⚠️ **SILENT FAILURE — the `body` is evaluated multiple times per turn, and side effects in it will
> execute multiple times, with no warning.**
>
> **Community-measured** (`john-rocky/coreai-model-zoo`, `knowledge/dynamic-profiles-local-models.md`,
> against local MLX-backed models on macOS 27; no build number or date recorded): *"**The `body` is
> re-evaluated multiple times per turn** (7 evaluations for 3 turns). The framework reads it more than
> once to gather instructions and resolve the model. **Keep the body pure** — read your route variable
> there, never mutate state. Imperative work goes in lifecycle modifiers (`onResponse`, …), which fire
> once at their boundary."*
>
> The count is community-measured and provider-specific; do not quote "7 for 3" as a specification.
> The **rule** it implies is not provider-specific and is the same rule SwiftUI has had since 2019.

Concretely:

```swift illustrative
// ❌ WRONG. Counter increments an unpredictable number of times per turn,
//    and the increment itself changes what the body resolves to.
var body: some DynamicProfile {
    turnCount += 1                       // side effect in a projection
    return Profile { … }
}

// ✅ RIGHT. The body reads; a lifecycle modifier writes.
var body: some DynamicProfile {
    Profile { … }
        .onResponse {
            turnCount += 1               // fires once, at a defined boundary
        }
}
```

The same rule rules out: logging from the body, starting `Task`s from the body, mutating
`@SessionProperty` values from the body, and anything that reads a value it just wrote. If you find
yourself needing "the previous value", you want a session property written from `onResponse`, not a
local in the body.

### 6.3 Exactly one active `Profile`

> ✅ **VERIFIED** — `241:97-98`: *"**The important thing to understand is that a `DynamicProfile`
> resolves to a single active `Profile` at any given time. You use conditionals to pick which `Profile`
> is active, and the framework handles the transition for you.**"*

> ✅ **VERIFIED** — from Apple's documentation: *"A dynamic profile is the top-level coordination layer
> that manages profiles. It determines which `Profile` is in an active state… **A body must resolve to
> a single profile.**"* And: *"A `LanguageModelSession.DynamicProfileBuilder` **enforces a hard
> constraint at compile time so exactly one `Profile` is active at a time.** Instead of using parallel
> `if` blocks, use expressions so the compiler verifies the constraint."*

So unlike `DynamicInstructionsBuilder`, the profile builder does **not** accept a bare `if` with no
`else`. The two sanctioned shapes are:

```swift illustrative
// ✅ switch over an enum — exhaustive, so exactly one branch always resolves
switch orchestrator.mode {
case .brainstorm: Profile { … }
case .tutorial:   Profile { … }
case .term:       Profile { … }
}

// ✅ if / else if / else — verified in both Apple's sample and Apple's documentation article
if isEditingImage {
    Profile { ImageEditingInstructions() }
} else if isEditingAnimation {
    Profile { AnimationEditingInstructions() }.model(pccModel).temperature(0.2).reasoningLevel(.light)
} else {
    Profile { PresentationDynamicInstructions() }.temperature(0.8)
}
```

Origami uses both, nested: a `switch` over the mode with an `if !isOnDevice { … } else { … }` inside
two of its cases. That is the sanctioned way to vary configuration within a mode.

The failure this constraint prevents is the ambiguous one — two parallel `if`s that happen to both be
true, leaving the framework to guess. Because the check is a compile-time builder constraint, you find
out immediately. This is one of the few places in this stack where a mistake produces a *diagnostic*
rather than a silent behaviour change; enjoy it.

### 6.4 The body is *not* where imperative work goes

Collecting the three rules into one design directive:

| You want to… | Put it… |
|---|---|
| Choose a persona from app state | in the `body` |
| Choose a model from app state | in the `body`, via `.model(_:)` |
| Compose instructions conditionally | in a `DynamicInstructions` body |
| Update the UI when the model replies | in `.onResponse { }` |
| Advance a state machine | in `.onResponse { }`, `.onToolCall { }`, or a `Tool` |
| Summarise or trim the transcript | in `.onPrompt { }` / `.onResponse { }`, or `historyTransform` |
| Set up or tear down per-persona resources | in `.onActivate { }` / `.onDeactivate { }` |

---

## 7. Attaching a profile to a session

Two initialisers matter, and one of them was missing from every reconstruction in circulation until
Apple's sample shipped.

> ✅ **VERIFIED** — declarations from Apple's `LanguageModelSession` documentation:
>
> ```swift
> // iOS 27.0+ Beta — "Create a session with dynamic instructions."
> convenience init(model: some LanguageModel = SystemLanguageModel.default,
>                  dynamicInstructions: sending some DynamicInstructions,
>                  history: some Collection<Transcript.Entry> = [])
>
> // iOS 27.0+ Beta — "Create a session with a profile."
> convenience init(profile: sending some LanguageModelSession.DynamicProfile,
>                  history: some Collection<Transcript.Entry> = [])
> ```
>
> Note `sending` on the profile parameter — the profile is transferred into the session's isolation
> domain, which is why `Orchestrator` below is captured rather than shared.

Pick `init(dynamicInstructions:)` when you need dynamic *content* but a single fixed configuration —
one model, one temperature, instructions and tools that vary with app state. Pick `init(profile:)`
when the configuration itself varies.

### 7.1 The simple case

> ✅ **VERIFIED** — from Apple's dynamic-sessions article:
>
> ```swift
> let session = LanguageModelSession(
>     profile: PresentationProfile()
> )
> ```

### 7.2 Seeding history

The `history:` label takes anything that is a `Collection<Transcript.Entry>` — which includes both a
plain `[Transcript.Entry]` and a whole `Transcript`, because `Transcript` is itself a collection of
its entries. Apple's sample passes a `Transcript`:

> ✅ **VERIFIED** — `Origami/Models/Orchestrator.swift:41-47`:
>
> ```swift
> @ObservationIgnored
> private lazy var session = LanguageModelSession(
>     profile: OrchestratorProfile(orchestrator: self),
>     history: Transcript(
>         entries: startHistory
>     )
> )
> ```

Three things are going on in those seven lines and all three are worth copying:

1. **`private lazy var` + `@ObservationIgnored`** breaks the ownership knot. The profile holds the
   orchestrator; the orchestrator lazily holds the session. Without `lazy`, `self` is not available;
   without `@ObservationIgnored`, the session becomes an observed property of an `@Observable` class
   and every access participates in change tracking you do not want.
2. **`Transcript(entries:)`** — the initialiser that turns an array of entries into a transcript.
3. **`history:` accepts it directly** because `Transcript` satisfies `some Collection<Transcript.Entry>`.

### 7.3 Hand-authored seed entries

Origami does something no WWDC session mentions: it **fabricates assistant turns** to prime the model
with app state, rather than putting that state in the instructions.

> ✅ **VERIFIED** — `Origami/Models/Orchestrator.swift:103-139`:
>
> ```swift
> var startHistory: [Transcript.Entry] {
>     var desc: [Transcript.Entry] = []
>
>     desc.append(
>         .response(
>             Transcript.Response(
>                 assetIDs: [""],
>                 segments: [
>                     .text(
>                         Transcript
>                             .TextSegment(
>                                 content: "I can see the user's current project is: \(project.description)"
>                             )
>                     )
>                 ]
>             )
>         )
>     )
>     if project.hasTutorial {
>         desc.append(
>             .response(
>                 Transcript.Response(
>                     assetIDs: [""],
>                     segments: [ .text(Transcript.TextSegment(
>                         content: "The user's project has a tutorial: \(project.tutorialDescription)")) ]
>                 )
>             )
>         )
>     }
>     return desc
> }
> ```

Why put this in the history rather than the instructions? Because instructions are the *stable* prefix
— the thing whose invalidation costs you the entire cache (§4.3). Project details change per project;
persona does not. Seeding them as history entries keeps the expensive prefix constant.

Confirmed spellings here: `Transcript.Entry.response(_:)`,
`Transcript.Response(assetIDs:segments:)`, `Transcript.Segment.text(_:)`,
`Transcript.TextSegment(content:)`.

> ⚠️ **`assetIDs` is a required, non-optional `[String]`, and Apple's own sample passes `[""]`** — an
> array containing one empty string. It is undocumented. Copy it; there is nothing better available.
>
> 🔴 **GAP (narrowed 2026-07-29, re-checked 2026-08-23) — what `assetIDs` means is still
> unknown, but the SDK shows its trajectory.** The 27.0 interface declares `Transcript.Response`
> with `assetIDs: [String]` plus a 27-only `metadata: [String : GeneratedContent]` (beta 5 retyped
> it from `[String : any Codable & Sendable & Equatable]`), and the back-deployed `metadata`
> getter on pre-27 runtimes literally returns `["assetIDs": GeneratedContent(assetIDs)]` — ✅
> **SDK-verified** (`FoundationModels-27.0-macos.swiftinterface:2595-2627`). So in the 27 model,
> `assetIDs` is just one key of the general response-metadata bag (the 27-only initializer
> `init(id:metadata:segments:)` drops the label entirely). Its *semantics* remain undocumented;
> `[""]` still has no better reading than "no model produced this."
> **What would resolve it:** an Apple doc page for `Transcript.Response.metadata`, or a device
> dump of what the framework itself writes there — respond once on a 27 runtime and print the
> response entry's `assetIDs`/`metadata` (the `probes/` package's transcript probes are the
> pattern to copy). **Safe default:** keep passing `[""]` for hand-built entries — it is Apple's
> own sample value — and never branch on the field when reading a transcript back.

### 7.4 Restoring a saved conversation

`init(profile:history:)` is also the rehydration path. The older `init(transcript:)` label still
exists, and both appear in Apple samples of different vintages:

> ✅ **VERIFIED** — `init(model:tools:transcript:)` is the iOS 26.0 spelling and is used by Apple's
> 2025-vintage samples; `init(profile:history:)` is the iOS 27 spelling and is what Origami uses.
>
> ✅ **RESOLVED (2026-07-29) — `transcript:` is not deprecated in the 27.0 beta.** The 26.x
> `init(model:tools:transcript:)` appears in the 27.0 interface with no deprecation attribute
> (`FoundationModels-27.0-macos.swiftinterface:41`), and 27.0 even *adds* a generic
> `init(model: some LanguageModel, tools:, transcript:)` (`:1910`). The two labels are different
> shapes, not old/new spellings of one: `transcript:` takes a whole `Transcript` on a tools-based
> session; `history:` takes `some Collection<Transcript.Entry>` on the profile/dynamic-instructions
> initialisers (`:871`, `:1083`). Use whichever matches the session shape you are building.

Rehydration has a cost that surprises people:

> ✅ **VERIFIED** — from Apple's KV-caching article: *"The session starts **without a KV cache**, so
> the model reprocesses the full transcript on the first call to `respond(to:options:)` or
> `prewarm(promptPrefix:)`… **The reprocessing latency on the first call is proportional to the size of
> the restored transcript.**"* The recommended mitigation is to prewarm ahead of the user:
> *"Prewarm the model when you know usage is at least one or two seconds in the future."*

```swift prelude:guide-context
let session = LanguageModelSession(
    profile: OrchestratorProfile(orchestrator: orchestrator),
    history: savedTranscript
)
session.prewarm()
```

### 7.5 Saving one, and the best debugging aid in the corpus

`Transcript` is `Encodable`, which makes a complete conversation dump three lines. Origami ships this
behind a `UserDefaults` toggle and re-snapshots after **every** effect:

> ✅ **VERIFIED** — `Origami/Models/TranscriptRecorder.swift:57-67` does
> `try JSONEncoder().encode(transcript)` with `.prettyPrinted` and `.sortedKeys`, writing to
> `~/Documents/OrigamiTranscripts/<title>_<timestamp>.json`; `Orchestrator.swift:173-178` calls it
> after each effect.

No WWDC session mentions this, and it is the single most useful thing you can add to an
agentic feature during development. When a profile switch does not fire, or history vanishes, the diff
between two consecutive snapshots tells you exactly which entry changed.

```swift compile:27 defines:DEBUG
import FoundationModels
import Foundation

#if DEBUG
/// Dump a session's transcript to disk. Debug builds only.
func snapshot(_ transcript: Transcript, named name: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(transcript)
    let dir = URL.documentsDirectory.appending(path: "Transcripts")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: "\(name)_\(Date.now.timeIntervalSince1970).json")
    try data.write(to: url)
}
#endif
```

> ⚠️ Transcripts contain everything the user typed and everything the model said. Gate the writer on a
> debug flag, keep it out of release builds, and treat the files as sensitive. The same caution Apple
> attaches to Instruments traces applies: session 243's own recording dialog warns that *"This
> instrument captures prompt and response data from your device, which can include sensitive
> information. Logging is off in production but it's on for the duration of your trace so keep your
> trace files somewhere safe."*

---

## 8. Precedence: three tiers for values, accumulation for callbacks

Because `Profile` conforms to `DynamicProfile`, and modifiers apply to `DynamicProfile`, you can put
a modifier at any level of the tree. Which one wins is fully specified.

> ✅ **VERIFIED** — from Apple's dynamic-sessions article, verbatim: *"When the same modifier appears
> at multiple levels, a three-tier precedence rule determines which value to use — from highest to
> lowest priority:*
> 1. *****Call-site arguments** — Generation options you pass directly to `respond(to:options:)`
>    override all profile and dynamic profile modifiers.*
> 2. *****Innermost dynamic profile or profile modifier** — The modifier closest to the subprofile
>    declaration overrides a dynamic profile.*
> 3. *****Dynamic profile modifiers** — Act as defaults that apply to all subprofiles unless the
>    modifier is overridden by a subprofile."*

So: **call site beats inner beats outer.** An outer `DynamicProfile` modifier is a *default*.

> ✅ **VERIFIED** — Apple's worked example of tier 2 versus tier 3:
>
> ```swift
> // A top-level dynamic profile that includes a single subprofile.
> struct WritingProfile: LanguageModelSession.DynamicProfile {
>     var body: some LanguageModelSession.DynamicProfile {
>         // By default, the temperature value applies to both branches in
>         // `WritingContent` unless a branch adds a temperature modifier.
>         WritingContent()
>             .temperature(0.5)
>     }
> }
>
> // A dynamic profile that contains two states.
> struct WritingContent: LanguageModelSession.DynamicProfile {
>     // A custom writing mode that determines which subprofile to use.
>     var mode: MyCustomWritingMode = .creative
>
>     var body: some LanguageModelSession.DynamicProfile {
>         switch mode {
>         case .creative:
>             // Use the temperature `1.0` because the profile-level modifier takes priority.
>             Profile {
>                 CreativeWritingInstructions()
>             }
>             .temperature(1.0)
>         case .technical:
>             // Inherit the temperature `0.5` from `WritingProfile`.
>             Profile {
>                 TechnicalWritingInstructions()
>             }
>         }
>     }
> }
> ```

That example also demonstrates the composition shape you will reach for once a profile grows past
about three branches: **a `DynamicProfile` may contain another `DynamicProfile`.** `WritingProfile`'s
body contains `WritingContent()`, not a `Profile`. Nesting is how you factor a large agent graph into
files without giving up shared defaults.

### 8.1 Lifecycle callbacks accumulate; they do not override

> ✅ **VERIFIED**, verbatim: *"Unlike value modifiers, **life cycle callbacks accumulate across nested
> profiles**. When a profile and a subprofile both register a callback, the framework calls both."*

This asymmetry is deliberate and useful: an outer profile can install cross-cutting logging or
telemetry on `onResponse`, and inner profiles keep their own `onResponse` work. It is also a trap if
you assume override semantics — an outer `.onResponse { history = history.suffix(50) }` and an inner
`.onResponse { history = summarise(history) }` will *both* run, in an order the corpus does not
specify for the framework's own modifiers.

> 🔴 **GAP — the relative ordering of accumulated lifecycle callbacks across nesting levels is not
> documented for the framework.** Apple's `foundation-models-utilities` package documents its own
> `onPrompt`-based modifiers as running **outside-in** (outermost first — see §13.4), and asserts it
> in three places, but that is the package's statement about its own composition, not a framework
> guarantee about arbitrary user callbacks. **Safe default: never let two accumulated callbacks write
> the same state.** Give each level a distinct job — outer observes, inner mutates.

### 8.2 Call-site options still win

```swift prelude:guide-context
// The profile says .allowed; this one call says .required.
let response = try await session.respond(
    to: "What's a good sourdough recipe?",
    options: GenerationOptions(toolCallingMode: .required)
)
```

> ✅ **VERIFIED** — the `GenerationOptions(toolCallingMode:)` call-site form is documented, and tier 1
> of the precedence rule says it overrides everything in the profile tree.

This is a genuinely useful escape hatch — a one-off "answer this without tools" turn does not need a
new branch in your profile — but it is also the reason a profile can look correct and behave
differently. When debugging a profile whose modifier appears not to apply, check every call site for
an `options:` argument before you touch the profile.

---

## 9. Lifecycle modifiers

Lifecycle modifiers are where imperative code lives. They are the reason the `body` can stay pure.

> ✅ **VERIFIED** — `242:94`: *"**Lifecycle modifiers provide access to your profile's progress by
> giving you the opportunity to run imperative code directly in your profile declaration.** This can be
> useful for **updating state external to your session, like reflecting progress in UI**. But it's also
> useful for **internal state updates, like changing the mode in our craft profile or modifying the
> session's history**."*

### 9.1 The seven hooks and when they fire

| Modifier | Fires |
|---|---|
| `onActivate(perform:)` | when the profile becomes active — setup |
| `onDeactivate(perform:)` | when the profile becomes inactive — teardown |
| `onPrompt(perform:)` | **after** the user prompt appends to the transcript, **before** the model request starts |
| `onResponse(perform:)` | after the model produces a response |
| `onToolCall(perform:)` | when the model invokes a tool — **before** the framework runs it |
| `onToolOutput(perform:)` | when a tool call produces output |
| `onReasoning(perform:)` | whenever this dynamic profile produces reasoning |

All seven descriptions are ✅ VERIFIED from Apple's documentation (`onReasoning` from the instance-method
index rather than the article's table).

`onPrompt`'s exact position — *after* the prompt is in the transcript but *before* the request goes out
— is what makes it the right place for history compression. The prompt you are about to send is
already visible to your callback, which is exactly what Apple's own `summarizeHistory` modifier relies
on (§13.3).

**Ordering on a switch** is **community-measured**, not documented:

> **Community-measured** (`john-rocky/coreai-model-zoo`, local MLX models on macOS 27, no build or
> date recorded): *"**Lifecycle order on a switch** is `old.onDeactivate → new.onActivate → onPrompt →
> onResponse`. First entry into a profile fires `onActivate` **before** `onPrompt`."*
>
> That ordering is intuitive and matches the naming, but it is one person's measurement against a
> third-party model provider. Do not build a correctness-critical invariant on it; if you need
> "exactly once, before the first prompt", assert it with your own state flag.

### 9.2 Arity: both zero-argument and argument-taking forms exist

This is the messiest corner of the API surface, so here is exactly what is known.

> ✅ **VERIFIED — zero-argument forms compile.** From `ml-explore/mlx-swift-lm`'s integration tests
> (`StructuredToolOutputSessionTests.swift:62-65`):
>
> ```swift
> .model(model)
> .toolCallingMode(.required)
> .onToolCall {
>     toolCallCount += 1
> }
> ```
>
> Apple's own documentation uses the same zero-argument `onToolCall { toolCallCount += 1 }` and a
> zero-argument `.onResponse { … }`.

> ✅ **VERIFIED — argument-taking forms are documented.** From Apple's dynamic-sessions article:
>
> ```swift
> Profile {
>     MyCustomFileAccessInstructions()
>     MyCustomReadFileTool()
> }
> .onToolCall { toolCall in
>     // Runs before the framework invokes the tool and allows for checking
>     // whether the app is in a state to run the tool.
>     guard myAccessPolicy.permits(toolCall) else {
>         throw MyAccessPolicyError.denied(toolCall.toolName)
>     }
> }
> .onToolOutput { toolCall, output in
>     // Runs after the tool. This is a good place to log any necessary activity.
> }
> ```
>
> So `onToolCall` has a one-argument form whose parameter exposes `.toolName`, `onToolOutput` has a
> two-argument form, and `onResponse` has a one-argument form
> (`.onResponse { response in print("Debug response: \(response)") }` appears in Apple's custom-modifier
> example). These are overloads, not variadic magic.

> ✅ **RESOLVED (2026-07-29) — the declared signatures, read verbatim from the 27.0 interface**
> (`FoundationModels-27.0-macos.swiftinterface:984-1026`). Every transcript-event hook is an
> overload **pair** — a zero-argument convenience that forwards to the payload form — and the
> payload types are all `Transcript` nested types:
>
> | Hook | Payload form's parameters | Closure |
> |---|---|---|
> | `onPrompt` | `(Transcript.Prompt)` | `async throws` |
> | `onResponse` | `(Transcript.Response)` | `async throws` |
> | `onReasoning` | `(Transcript.Reasoning)` | `async throws` |
> | `onToolCall` | `(Transcript.ToolCall)` | `async throws` |
> | `onToolOutput` | `(Transcript.ToolCall, Transcript.ToolOutput)` | `async throws` |
> | `onActivate` / `onDeactivate` | `()` only | `async`, **non-throwing** |
>
> (Full attributes: `@_inheritActorContext perform action: nonisolated(nonsending) sending
> @escaping … async throws -> Void`; the activate/deactivate pair is `@isolated(any) () async ->
> Void`.) So: every hook except activate/deactivate has both arities, all are `async`, the
> transcript-event hooks may `throw` (§9.3's turn-abort), and `onActivate`/`onDeactivate`
> **cannot throw** — teardown code that can fail needs its own error handling.

### 9.3 Throwing from a lifecycle callback aborts the turn

This is the most consequential documented behaviour of the whole lifecycle group:

> ✅ **VERIFIED** — from Apple's dynamic-sessions article: *"Throwing an error inside a life cycle
> callback **propagates to the caller's `respond(to:options:)` or `streamResponse(to:options:)` call**,
> letting you raise errors that surface directly to your call site."*

That makes `onToolCall` a genuine policy chokepoint: you can inspect a pending tool call and refuse it,
and the refusal lands as a thrown error at your own call site rather than as a confusing model
response.

But understand the granularity before you build a consent flow on it:

> ⚠️ **Throwing from `onToolCall` kills the entire turn, not just that one tool call.** The error
> propagates to `respond(to:)`. If the model requested three tools and you deny one, you do not get
> "two ran and one was denied" — you get a thrown error and (by default) a transcript rollback (§14).
>
> A community security note attributed to WWDC26 session 347 describes the same hook as *"the single
> chokepoint for confirmations"* and says a throw means the tool *"never runs and control returns to
> the loop"* — which suggests loop-level rather than turn-level recovery. **That claim is
> community-sourced and conflicts with Apple's documented "propagates to the caller" wording. Apple's
> documentation wins.** Design for turn-level abort.
>
> ✅ **DEVICE-CONFIRMED 2026-08-20** — an iPhone 15 Pro / iOS build `24A5408d` probe threw from
> `onToolCall`; the tool body did not run, `respond` threw `LanguageModelSession.ToolCallError`, and
> the default transcript policy left only the instructions entry.

For *asking* rather than *denying*, use the tool-as-consent-request pattern instead: the tool returns
a string telling the model a human was asked, the app shows a Yes/No UI, and the answer re-enters as a
new user turn. Apple's `MovePhotoToStepTool` does exactly this; it is covered in
[the tools guide](../../part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md).

### 9.4 The canonical use: reclaim context at a response boundary

> ✅ **VERIFIED** — `242:91-92`: *"At certain points in the session, you may need to **summarize earlier
> entries from the existing transcript to reclaim context**. **Doing this after each model's response
> provides a clear boundary in the session's lifecycle.**"*

Apple's documentation gives the minimal version, which is also a complete, copyable pattern:

> ✅ **VERIFIED** — from the dynamic-sessions article:
>
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

Note the shape: trim **in one large step at a threshold**, not a little every turn. That is not
stylistic; it is the documented performance rule.

> ✅ **VERIFIED** — from Apple's KV-caching article: *"**Defer removing entries from the transcript
> until the context window is nearly full, then consolidate the context in a single operation rather
> than trimming incrementally after each turn.** Frequent small edits to the middle of the transcript
> force repeated cache invalidations that increase latency, while a single consolidation step incurs
> the recomputation cost only once."* And: *"When you do trim, **removing only the most recent entries
> is cheaper than modifying earlier ones**."*

Two rules that pull in opposite directions, so be explicit about which you are optimising: trimming the
*tail* is cheap for the cache but destroys the most relevant context; trimming the *head* preserves
relevance but invalidates everything after the cut. The 100/50 threshold pattern above is the
compromise Apple demonstrates — pay the full invalidation rarely.

---

## 10. Custom modifiers with `DynamicProfileModifier`

Once a profile accumulates four or five modifiers, the declaration stops reading like a description of
intent. Custom modifiers fix that, and they are shaped exactly like SwiftUI's `ViewModifier`.

> ✅ **VERIFIED** — `242:81-85`: *"Our `historyTransform` has a lot going on. Let me show you how we can
> use **custom modifiers** to hide the complexity of our transform."* … *"First, we'll declare **a new
> type that conforms to `DynamicProfileModifier`** and apply our `historyTransform`."* … *"We can then
> **make it available for reuse by implementing an extension on `DynamicProfile`**. Any new Profiles
> that would benefit from reducing context can now utilize the new modifier."*

There are two halves, and you need both:

1. A type conforming to `LanguageModelSession.DynamicProfileModifier` with a
   `func body(content: Content) -> some LanguageModelSession.DynamicProfile`.
2. An extension on `LanguageModelSession.DynamicProfile` exposing it as a method, implemented with
   `self.modifier(_:)`.

> ✅ **VERIFIED** — the protocol requirement, from Apple's documentation index:
> ```swift
> protocol DynamicProfileModifier          // LanguageModelSession.DynamicProfileModifier, iOS 27.0+ Beta
> func body(content: Content) -> some LanguageModelSession.DynamicProfile
> ```
> `Content` is an associated type; `DynamicProfileModifierContent` appears in the list of
> `DynamicProfile` conformers, which is the concrete type the framework substitutes.

> ✅ **VERIFIED** — Apple's complete worked example, from the dynamic-sessions article:
>
> ```swift
> struct DebugProfileModifier: LanguageModelSession.DynamicProfileModifier {
>     func body(content: Content) -> some LanguageModelSession.DynamicProfile {
>         content
>             .temperature(0.0)
>             .onResponse { response in
>                 print("Debug response: \(response)")
>             }
>     }
> }
>
> extension LanguageModelSession.DynamicProfile {
>     func debug() -> some LanguageModelSession.DynamicProfile {
>         self.modifier(DebugProfileModifier())
>     }
> }
> ```
>
> Use site:
>
> ```swift
> Profile {
>     Instructions("You are a helpful assistant.")
> }
> .debug()
> ```

Note the spelling difference from §3.1: inside the free-standing `extension`, Apple writes the **fully
qualified** `some LanguageModelSession.DynamicProfile`, because the nested typealiases are not in scope
there the way they are inside a conforming type.

### 10.1 A real one, from Apple's own package

`apple/foundation-models-utilities` (commit `376ca60`, tag `1.0.0-beta3`, 2026-07-10) ships three
history modifiers, and all three are built this way. The pattern is worth studying because it shows
`DynamicProfileModifier` combined with `@SessionProperty(\.history)` — the two APIs that together make
transcript management composable.

> ✅ **VERIFIED** — `Sources/FoundationModelsUtilities/History/DropCompletedToolCalls.swift:43-48`:
>
> ```swift
> private struct DropCompletedToolCallsModifier: LanguageModelSession.DynamicProfileModifier {
>   @SessionProperty(\.history)
>   private var history
>
>   func body(content: Content) -> some DynamicProfile {
>     content.onPrompt { … history = … }
>   }
> }
> ```
>
> And the public surface, `DropCompletedToolCalls.swift:38`:
>
> ```swift
> extension LanguageModelSession.DynamicProfile {
>   public func droppingCompletedToolCalls() -> some DynamicProfile
> }
> ```

Three things to take from this:

- **A modifier can hold session state.** `@SessionProperty` works inside a `DynamicProfileModifier`,
  not just inside a profile or a tool. That is what lets a modifier read and rewrite the history
  without the profile knowing about it.
- **The modifier struct is `private`.** Only the extension method is public. Users of the package never
  name `DropCompletedToolCallsModifier`. Do the same: the modifier type is an implementation detail.
- **The work happens in `onPrompt`, not in `body`.** `body(content:)` is a projection too, and the same
  purity rule applies.

### 10.2 A modifier you will actually want

Here is the WWDC26 example — hiding a history transform behind a name — written against the verified
API shapes above.

```swift compile:27
import FoundationModels

/// Drops tool-call and tool-output entries from the history that the model sees,
/// without touching the session's stored transcript.
struct ReducedContext: LanguageModelSession.DynamicProfileModifier {
    func body(content: Content) -> some LanguageModelSession.DynamicProfile {
        content.historyTransform(Self.withoutToolTraffic(_:))
    }

    private static func withoutToolTraffic(
        _ entries: [Transcript.Entry]
    ) -> [Transcript.Entry] {
        entries.filter { entry in
            switch entry {
            case .toolCalls, .toolOutput: false
            default: true
            }
        }
    }
}

extension LanguageModelSession.DynamicProfile {
    /// Present a tool-traffic-free view of the history to this profile's model.
    func reducedContext() -> some LanguageModelSession.DynamicProfile {
        modifier(ReducedContext())
    }
}
```

Use site:

```swift prelude:guide-context
Profile {
    TechniqueReviewer()
}
.model(SystemLanguageModel())
.reducedContext()
```

> 🟡 **RECONSTRUCTED — the `Transcript.Entry` case names used in that filter.** `.toolCalls` and
> `.toolOutput` are ✅ VERIFIED (they appear in a `switch` over `Transcript.Entry` in
> `foundation-models-utilities`, `History/TranscriptRendering.swift:18-36`, alongside `.prompt`,
> `.response`, `.reasoning` and `.instructions`, with an `@unknown default` — so the enum is
> **non-frozen**). What is reconstructed is only the composition of this particular modifier; the
> pieces are each verified. Note the singular/plural asymmetry — **`.toolCalls` (one entry holding an
> array of calls) but `.toolOutput` (one entry per output)** — which is the single most common typo in
> code that filters a transcript.

Because `Transcript.Entry` is non-frozen, always write your `switch` with a `default` that **keeps**
unknown entries. A future OS adding a new entry kind should not silently start dropping it.

---

## 11. Session properties

A `DynamicProfile` is a struct, re-created and re-evaluated constantly. It is the wrong place to store
anything. Session properties are the right place: state that lives on the **session**, readable and
writable from any profile, any `DynamicInstructions`, any modifier, and any `Tool`.

> ✅ **VERIFIED** — `242:98-99`: *"You'll notice this is also making use of another new concept:
> **session properties**. **Session properties allow you to define state that's accessible from any
> `Tool` or `Profile`.**"*

> ✅ **VERIFIED** — from Apple's documentation: *"Use `@SessionProperty` to access session properties
> from within a `LanguageModelSession.DynamicProfile`, `LanguageModelSession.Profile`,
> `DynamicInstructions`, and `Tool`."*

### 11.1 The three pieces

> ✅ **VERIFIED** — declarations from Apple's documentation index:
>
> ```swift
> @propertyWrapper struct SessionProperty<Value>   // LanguageModelSession.SessionProperty, iOS 27.0+ Beta
> final class SessionPropertyValues                // iOS 27.0+ Beta
> protocol SessionPropertyKey: SendableMetatype    // iOS 27.0+ Beta
> @SessionPropertyEntry                            // macro
> ```

Declaring a property is a two-line extension on `SessionPropertyValues`:

> ✅ **VERIFIED** — compiled code from `ml-explore/mlx-swift-lm`,
> `IntegrationTesting/IntegrationTestingTests/MLXFoundationModelsIntegration/ToolCalling/StructuredToolOutputSessionTests.swift:14-18`:
>
> ```swift
> @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
> extension SessionPropertyValues {
>     @SessionPropertyEntry
>     var structuredToolOutputCallCount: Int = 0
> }
> ```

> ✅ **VERIFIED** — Apple's documentation shows the identical shape with a dictionary:
>
> ```swift
> extension SessionPropertyValues {
>     @SessionPropertyEntry
>     var activatedSkills: [String: Bool] = [:]
> }
> ```

The rules, stated once and worth memorising:

> ✅ **VERIFIED** — `242:106-108`: *"**You can declare properties using the `@SessionPropertyEntry`
> macro within an extension on `SessionPropertyValues`.** **All session properties are mutable and must
> have an initial value.**"*

So: **mutable, always; initial value, required.** An `Optional` with `= nil` is how you express "not
set yet" — session 242's example is *"our summary as an optional string"*.

> **Spelling note.** One documentation mirror writes the macro as `@SessionPropertyEntry()` with
> parentheses. **Compiled code writes it without parentheses.** Both may parse — Swift macros without
> arguments do not require parens — but write it bare, matching the compiling source.

### 11.2 Reading and writing from a profile

> ✅ **VERIFIED** — `StructuredToolOutputSessionTests.swift:47-52`:
>
> ```swift
> @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
> private struct StructuredToolOutputProfile: LanguageModelSession.DynamicProfile {
>     let model: MLXLanguageModel
>
>     @SessionProperty(\.structuredToolOutputCallCount)
>     var toolCallCount
>
>     var body: some LanguageModelSession.DynamicProfile {
> ```

Note there is **no type annotation** on the wrapped property — the key path supplies it. Writing
`@SessionProperty(\.toolCallCount) var toolCallCount: Int` is redundant and Apple's code never does it.

Reading in the body is what makes the counter-based `.required` exit (§5.5) work: the body reads
`toolCallCount`, the `onToolCall` hook writes it, and on the next evaluation the body resolves to a
different branch. **That is the complete loop-termination mechanism** — a session property is the only
thing in the system that both survives a body re-evaluation and can be written from a lifecycle hook.

> ✅ **VERIFIED** — `242:109-111`: *"**Each `Profile` can now read the value of the summary by accessing
> the session property** that we just declared. We'll **include the summary in our profile's
> instructions**… **Any profile can write to the property and changes will be visible across the
> session.**"*

### 11.3 Reading and writing from a `Tool`

This is the piece that makes tools first-class participants in session state rather than isolated
functions.

> ✅ **VERIFIED** — Apple's documentation, complete:
>
> ```swift
> struct PlannerTool: Tool {
>     let description = "Update the state of the activated skills"
>
>     // Read the shared session state for the currently activated skills.
>     @SessionProperty(\.activatedSkills)
>     var activatedSkills
>
>     @Generable
>     struct Arguments {
>         @Guide(description: "The skills to activate")
>         var skills: [String]
>     }
>
>     func call(arguments: Arguments) -> String {
>         // When the model calls this tool, update the skills to an active state.
>         for skill in arguments.skills {
>             activatedSkills[skill] = true
>         }
>         return "Activated: \(arguments.skills.joined(separator: ", "))"
>     }
> }
> ```
>
> Two incidental confirmations in that listing, both of which contradict widely-repeated advice:
> `PlannerTool` declares **no `name`** (it is optional and defaulted), and `call` is
> **neither `async` nor `throws`**.

This closes the baton-pass loop without any orchestrator plumbing: the model calls a tool, the tool
writes a session property, the profile's body reads it on the next prompt and resolves to a different
persona. Compare with Origami, which routes the same signal through an `@Observable` orchestrator
instead. Both work; the session-property version keeps everything inside the Foundation Models types,
while Origami's version puts the state where the rest of the app can see it too. **If the state is
also UI state, use `@Observable`. If it exists only to steer the model, use a session property.**

### 11.4 Reading from outside the session

> ✅ **VERIFIED** — `StructuredToolOutputSessionTests.swift:120`:
>
> ```swift
> #expect(session.properties.structuredToolOutputCallCount == 1)
> ```

`LanguageModelSession.properties` exists, is keyed by the same property names, and is how you assert on
session state from a test. Neither WWDC session mentions it. This is the hook that makes an agentic
flow testable without scraping the transcript: give your profile a `phase` session property, drive the
session, and assert on `session.properties.phase`.

> 🔴 **GAP (narrowed 2026-07-29) — outside writes now provably *compile*; their semantics are still
> unverified.** The interface declares `session.properties: SessionPropertyValues { get }` returning
> a `final class` whose keyed subscript has `get`/`set`/`_modify`, and whose `history` accessor is
> likewise settable (✅ **SDK-verified**, `FoundationModels-27.0-macos.swiftinterface:1097-1107,
> :1071-1076, :1127-1129`) — so `session.properties.phase = .done` from outside is not a compile
> error. What no source shows is what happens next (does an in-flight turn observe it? does it race
> the `transcriptMutationWhileResponding` guard?). **Safe default: treat it as read-only from
> outside the session** and do all writes from a profile, modifier, or tool, where the behaviour is
> verified.

### 11.5 Summary of the surface

| Where | Read | Write | Evidence |
|---|---|---|---|
| `DynamicProfile` / `Profile` body | ✅ | ⚠️ never (purity, §6.2) | compiled + docs |
| Lifecycle modifier closure | ✅ | ✅ | compiled + docs |
| `DynamicProfileModifier.body(content:)` | ✅ | ⚠️ same purity rule — write in the hook it installs | Apple's utilities package |
| `Tool.call(arguments:)` | ✅ | ✅ | Apple docs |
| `DynamicInstructions` body | ✅ | ⚠️ purity; and see the read-only rule in §12.2 | Apple docs |
| Outside, via `session.properties` | ✅ | ⚠️ setter exists (SDK-verified `:1103-1107`); runtime semantics 🔴 GAP | compiled test + 27.0 interface |

---

## 12. `history` versus `historyTransform`

There are two ways to change what the model sees, and choosing wrongly is the most consequential
mistake available in this API. They are not variants of each other; one is destructive and global, the
other is non-destructive and local.

First, the mental model of what "history" even is:

> ✅ **VERIFIED** — `242:69-72`: *"**The transcript is `LanguageModelSession`'s representation of the
> model's context.** `DynamicInstructions` offers **one way** to modify the transcript. More
> specifically, it allows **modifying the instructions entry**. For updating the remaining entries,
> we'll use **a window into the transcript called 'history'**."*

```
transcript  =  [ instructions entry ]  +  history (everything else)
                       ↑                        ↑
              DynamicInstructions      historyTransform  /  @SessionProperty(\.history)
```

> ✅ **VERIFIED** — Apple's documentation for the built-in property, which nails the boundary:
> *"The transcript entries **excluding the leading instructions entry**, if present."* … *"The session
> history provides the transcript entries after instructions such as prompts, responses, tool calls,
> and tool outputs. **The history excludes instructions segments from `DynamicInstructions`.**"*

### 12.1 The decision rule, verbatim

> ✅ **VERIFIED** — `242:102-103`, and this is the sentence to quote at code review: *"**Keep in mind
> that the `history` property is lossy and its changes will be reflected across all profiles in the
> session. For lossless transformations targeted to specific profiles, you should prefer
> `historyTransform`.**"*

| | `historyTransform(_:)` | `@SessionProperty(\.history)` |
|---|---|---|
| Mutates the stored transcript? | **No** — a local transformation applied before prompting | **Yes** — a stateful edit |
| Lossy? | No; the original context is still there | **Yes** |
| Scope | **This profile only** | **Every profile in the session** |
| Reversible | Yes — nothing was removed | No |
| Runs | before each model request, every time | when your code assigns to it |
| Use for | focus, redaction, per-model context sizing | consolidation and summarisation at a boundary |
| KV cache | in-place replacements can preserve it | invalidates from the point of change |

> ✅ **VERIFIED** — `242:78-80`, the property that makes `historyTransform` safe: *"**Transforms don't
> permanently mutate the session's transcript. Instead, they're local transformations applied prior to
> prompting the model.** This means **you don't need to worry about losing context that may become
> relevant at a later point**."*

That last clause is the practical argument. A `historyTransform` that hides tool traffic from a small
on-device model does not prevent a later PCC-backed profile from seeing all of it. A `history`
assignment that drops the same entries destroys them for everyone, forever.

> ✅ **VERIFIED** — Apple's documentation makes the multi-profile case explicit: *"When a
> `DynamicProfile` coordinates multiple profiles, `historyTransform(_:)` allows each profile to manage
> its own view of the history. One profile compresses the history for a small on-device model, and a
> profile that uses a server model — with a much larger context size — gets the full history."*

That is exactly Origami's shape: the two on-device branches carry
`.historyTransform(shortHistory(_:))`, the server branches do not.

### 12.2 ⚠️ `history` is read-only in two contexts

> ⚠️ **SILENT FAILURE RISK — `history` is documented as read-only inside `DynamicInstructions` and
> `Tool`.**
>
> ✅ **VERIFIED** — Apple's documentation, as a NOTE: *"Because model output influences the evaluation
> of `DynamicInstructions` and `Tool`, **the session history is read-only in these contexts.**"*
>
> 🔴 **GAP (narrowed 2026-07-29) — what happens if you write to it anyway.** One of the three
> plausible behaviours is now eliminated: it is **not a compile error**. The interface has a single
> `SessionPropertyValues.history` accessor with a real `set`
> (`FoundationModels-27.0-macos.swiftinterface:1071-1076`; typed `Transcript.HistoryView` as of
> beta 5 — §12.3) and no read-only projection type for the
> `Tool`/`DynamicInstructions` contexts — so the documented read-only rule must be enforced at
> runtime, which leaves **silent no-op or runtime trap**, and nothing in the corpus distinguishes
> those. **Safe default: only assign to `history` from a lifecycle modifier closure** (`onPrompt`,
> `onResponse`), which is where every verified write in the corpus happens, including all three of
> Apple's own history modifiers. Reading it from a tool or from `DynamicInstructions` is fine and
> documented.

### 12.3 The two types are not the same type

A small but real ergonomic wrinkle that will produce a compiler error the first time you hit it:

> ✅ **SDK-verified** (beta 5, `FoundationModels-27.0-macos.swiftinterface:1071-1076`) — the built-in
> property is typed
> ```swift
> var history: Transcript.HistoryView { get set }
> ```
> while `historyTransform(_:)` takes and returns a plain array:
> ```swift
> ([Transcript.Entry]) -> [Transcript.Entry]
> ```
> ⚠️ Until beta 5 the property was typed `ArraySlice<Transcript.Entry>`; the beta 5 interface
> introduced the dedicated `Transcript.HistoryView` collection (`27.0:2667-2694`) — noted
> 2026-08-23.

So `history = history.suffix(50)` still type-checks — for a new reason: `HistoryView` is **its own
`SubSequence`** (`27.0:2669`), so its `suffix` is a `HistoryView`, exactly as `ArraySlice.suffix` was
an `ArraySlice` before beta 5. A `historyTransform` closure that ends in `entries.suffix(20)` still
does **not** — `Array.suffix` returns `ArraySlice`, and the closure must return `[Transcript.Entry]`.
One new wrinkle: `HistoryView.Index` is an opaque struct, not `Int` (`27.0:2703-2718`), so
`history[0]` no longer compiles — use `history.first`/`history.last` or index arithmetic. Apple's
documentation example wraps it:

> ✅ **VERIFIED** — from the dynamic-sessions article:
>
> ```swift
> Profile {
>     Instructions("You help people generate fun and interesting book ideas.")
>     MyCustomBookTool()
> }
> .historyTransform { history in
>     // Perform a local transformation before prompting the model. This transform
>     // doesn't affect the global state of the transcript, so you're not losing
>     // existing transcript context.
>     Array(history.suffix(20))
> }
> ```

Note `Array(...)`. Origami's `shortHistory(_:)` is quoted in the corpus as
`{ entries.suffix(4) }` with a declared return type of `[Transcript.Entry]`, which would not type-check
as written — almost certainly a transcription that dropped the `Array(…)` wrapper during harvesting.
**Write `Array(entries.suffix(4))`.** It is correct under either reading.

The utilities package confirms the slice-like contract from the other direction (its source predates
beta 5 and was written against the `ArraySlice` surface): its modifiers call `lastIndex(where:)`,
`prefix(upTo:)`, `suffix(from:)`, `suffix(_:)`, `count` and `last` on `history`, concatenate it with
`+`, and assign a plain `[Transcript.Entry]` array back into it (`SummarizeHistory.swift:153`). Every
method in that list also exists on beta 5's `HistoryView` — its `RandomAccessCollection` +
`RangeReplaceableCollection` conformances (`27.0:2667`) supply them.

### 12.4 A function reference is a legal transform

The one API detail that most reconstructions got wrong:

> ✅ **VERIFIED** — Origami passes a **function reference**, not a closure:
> `.historyTransform(shortHistory(_:))`, where
> `private func shortHistory(_ entries: [Transcript.Entry]) -> [Transcript.Entry]`.

This matters more than it looks. It means your transform can be a named, testable, `private` method on
the profile struct — or a `static` function, or a free function — and the profile declaration stays
readable. It also means the transform is trivially unit-testable without a model:

```swift prelude:guide-context
import Testing
import FoundationModels

@Test func shortHistoryKeepsTheLastFourEntries() {
    let entries: [Transcript.Entry] = makeEntries(count: 10)
    let trimmed = OrchestratorProfile.shortHistory(entries)   // if you make it static
    #expect(trimmed.count == 4)
}
```

### 12.5 Prefer in-place replacement over deletion

> ✅ **VERIFIED** — from Apple's KV-caching article: *"**Prefer stateless transforms over stateful
> ones** because they don't modify the global transcript… A stateless transform that **drops** entries,
> like truncating to recent history, **invalidates parts of the cache** for the entries it removes.
> However, **a transform that replaces content in-place, like removing debug metadata, can preserve
> cache consistency** because the model sees the same token sequence each time."*

Apple's own illustration:

> ✅ **VERIFIED**:
>
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

Careful reading of that comment: cache validity depends on the **token sequence** being identical, so
"same number of entries in the same order" preserves the cache only if the *content* is also
byte-stable. A transform that strips a timestamp preserves the cache on turn two only if it strips the
same timestamp the same way. A transform that injects "current time: …" defeats the cache every turn.

### 12.6 `historyTransform` is a security hook

A community security note — attributed to WWDC26 session 347, *Secure your app: mitigate risks to
agentic features*, which is **not in this corpus** — describes `historyTransform` as the natural place
for two defensive techniques:

> **Community-sourced, attributed to session 347, secondary evidence:** *"`.historyTransform` — fires
> before the transcript is rendered to the model, on every new user request **and every loop
> iteration**. Modifies the tail of the transcript. → the place to apply **spotlighting** (add
> delimiters to untrusted tool outputs) and **PII redaction** (swap sensitive spans for a placeholder).
> **Transforms are scoped to the current inference only** — not visible to the next call, so re-apply
> every iteration."*
>
> The "current inference only, re-apply every iteration" half is consistent with Apple's documented
> "local transformation applied prior to prompting" and is safe to rely on. The "every loop iteration"
> firing claim is **not** in either WWDC transcript or any Apple documentation page in this corpus —
> treat it as unverified. Resolving it needs the session 347 transcript or an Instruments trace of a
> multi-iteration tool loop with a counting transform.

Independently of that, Apple *does* endorse the redaction use directly, in the passage quoted in §1:
*"redact private information from existing entries when moving to a less private model."* If your
profile graph crosses the on-device → Private Cloud Compute boundary, `historyTransform` on the PCC
branch is the correct and documented place to do it.

---

## 13. Apple's shipped history modifiers, and their sharp edges

Apple ships three ready-made history modifiers — not in the OS framework, but in an open-source
package that updates between OS releases.

> ✅ **VERIFIED** — `242:12-14`: *"we're announcing a new package; **Foundation Models framework
> utilities**. Utilities is an **open source Swift package** that houses components helpful for
> building agentic experiences. It will be **updated in between OS releases** and give you access to
> **emerging or experimental patterns**, all **backed by dynamic profiles**."*

Repository facts, all ✅ VERIFIED from the clone at commit `376ca60` (tag `1.0.0-beta3`, 2026-07-10):
`github.com/apple/foundation-models-utilities`, Apache 2.0, **two commits total**, zero pull requests,
**issues disabled on GitHub** (bugs go to the Developer Forums or Feedback Assistant), no GitHub
releases, platforms `macOS 27 / iOS 27 / visionOS 27 / watchOS 27`, swift-tools 6.2, Swift 6 language
mode, **zero external dependencies**. `README.md` points `from: "1.0.0"` at a version that does not
exist — only prerelease tags are published, so that dependency line resolves to nothing. Pin the tag.

Take "emerging and experimental" literally. What follows is not a criticism of the package; it is the
package doing what its description says.

### 13.1 The three modifiers

> ✅ **VERIFIED** — exact signatures, every parameter, every default:
>
> ```swift
> // DropCompletedToolCalls.swift:38
> extension LanguageModelSession.DynamicProfile {
>   public func droppingCompletedToolCalls() -> some DynamicProfile
> }
>
> // RollingWindow.swift:36 and :64
> extension LanguageModelSession.DynamicProfile {
>   public func rollingWindow(entries: Int) -> some DynamicProfile
>   public func rollingWindow(size: RollingWindowSize) -> some DynamicProfile
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
>
> // RollingWindow.swift:86
> public enum RollingWindowSize: Sendable {
>   case entries(Int)                       // the only case
> }
> ```

`summarizeHistory` has **no default for `model:`**, despite Apple's own bundled skill documentation
claiming `model: Model = SystemLanguageModel()`. A generic parameter cannot carry a default that would
bind `Model` anyway. Pass one explicitly.

### 13.2 `droppingCompletedToolCalls()` — what it actually does

> ✅ **VERIFIED** — `DropCompletedToolCalls.swift:51-65`:
>
> ```swift
> content.onPrompt {
>   let lastOutputIndex =
>     history.lastIndex(where: { entry in
>       if case .response  = entry { return true }
>       if case .toolCalls = entry { return true }
>       return false
>     }) ?? history.startIndex
>
>   let prefix = history.prefix(upTo: lastOutputIndex).filter { entry in
>     if case .toolCalls  = entry { return false }
>     if case .toolOutput = entry { return false }
>     return true
>   }
>
>   let suffix = history.suffix(from: lastOutputIndex)
>
>   history = prefix + suffix
> }
> ```

Semantics: find the last `.response` or `.toolCalls` entry; strip every `.toolCalls` and `.toolOutput`
*before* it; keep everything from it onward verbatim. The most recent tool exchange survives; earlier
ones are evicted. Prompts, responses and instructions are never touched.

Its tests pin the behaviour exactly: after one turn nothing is dropped ("still incomplete"); after two
turns the first turn's tool pair is gone and the second's survives
(`DroppingCompletedToolCallsTests.swift:30-68`).

Note that this modifier writes `history` — it is **lossy and global**, per §12.1. That is a reasonable
trade for tool traffic, which is rarely worth re-reading, but it is a permanent deletion, not a view.

### 13.3 `rollingWindow(entries:)` — Apple ships a known bug

> ✅ **VERIFIED** — the entire implementation, `RollingWindow.swift:77-80`:
>
> ```swift
> content.onPrompt {
>   switch size {
>   case .entries(let numberOfEntries):
>     history = history.suffix(numberOfEntries)
>   }
> }
> ```

A naive `suffix(n)`. It is **not transcript-aware**: it will cut between a prompt and its response, and
it can drop the leading entry.

> ⚠️ **SILENT FAILURE — and Apple documents it in a test rather than fixing it.**
>
> ✅ **VERIFIED** — `RollingWindowTests.swift:71-73`, Apple's own comment, verbatim: *"The naive
> suffix(2) trim repeatedly cuts between a prompt and its response, so the window starts with an
> orphaned response. **This documents the (buggy) naive outcome; in practice it crashes partway
> through.**"*
>
> The asserted expectation (`:74-80`) is an orphaned response with no preceding prompt:
>
> ```swift
> session.transcriptSummary == [
>     .instructions,
>     .response("OK"),        // ← orphaned response, no preceding prompt
>     .prompt("fourth"),
>     .response("OK")
> ]
> ```
>
> **Do not use `rollingWindow(entries:)` with a small window on a conversational session.** If you need
> a window, write your own that trims in prompt/response *pairs*, or use `historyTransform` so the
> damage is local and reversible. A pair-aware window is twenty lines and you can unit-test it without
> a model (§12.4).

An interesting side-observation from the same test: `.instructions` survives at index 0 even with
`windowSize: 2`, although the modifier itself has no logic to preserve it. So the framework must
re-materialise the instructions entry after the modifier runs. 🔴 **GAP — the mechanism is
unverified**; it is inferred from a test expectation, not from documentation. Do not rely on it to
protect your instructions if you write your own trimming code — check explicitly.

### 13.4 `summarizeHistory(...)` — the most aggressive one

> ✅ **VERIFIED** — `SummarizeHistory.swift:99-158`, abridged:
>
> ```swift
> content.onPrompt {
>   guard history.count > entryThreshold else { return }            // strict >
>   guard case .prompt(let prompt) = history.last else { return }    // trailing entry MUST be a prompt
>
>   let session = LanguageModelSession(
>     model: model,
>     instructions: { instructions ?? Instructions { /* default summariser prompt */ } }
>   )
>
>   let textRepresentation = history.chatLog()
>
>   let summary = try await session.respond(
>     to: Prompt { "Summarize this conversation:\n\n\(textRepresentation)" }
>   ).content
>
>   // … assemble summaryContent from the summary plus a postamble …
>
>   history = [
>     .prompt(
>       Transcript.Prompt(
>         id: UUID().uuidString,
>         segments: [.text(summarySegment)] + prompt.segments,
>         options: prompt.options,
>         responseFormat: prompt.responseFormat
>       )
>     )
>   ]
> }
> ```

Three facts that are not obvious from the name:

1. **The threshold is an ENTRY COUNT, not a token count.** `history.count > entryThreshold`, strictly
   greater. There is no token counting anywhere in the package. The README's sentence *"Summarization
   runs only if the rolling window of 10 entries exceeds 5000 tokens"* is **stale prose from a
   deleted, pre-beta-1 token-based API** — `grep -rn "5000" Sources/ Tests/` returns zero hits, and the
   sample it describes (`summarizeHistory(threshold: 5000, …)`) never compiled against any shipped
   version. ✅ VERIFIED by git archaeology across both commits.
2. **It collapses the entire history to exactly ONE entry** — a single `.prompt` whose segments are
   `[summary text] + the original prompt's segments`. Instructions, all prior prompts, responses and
   tool exchanges are gone. `options` and `responseFormat` are carried over from the surviving prompt.
3. **The summariser never sees your instructions.** `history.chatLog()` renders `.instructions` to
   `nil` and excludes it (`TranscriptRendering.swift:35`). Structured content and attachments are
   silently dropped from the rendering too, and multi-segment entries are joined with a **space**
   (`:60`).

> ⚠️ **SILENT FAILURE — `summarizeHistory` is a no-op whenever the trailing entry is not a prompt.**
>
> ✅ **VERIFIED** — Apple's own test comment, `SummarizeHistoryTests.swift:178-184`: *"The single
> respond produces: prompt -> tool call -> tool output -> response. By the time summarization's hook
> runs on the tool-output continuation, the history count (3) already exceeds the threshold (2), but
> the most recent entry is a tool output rather than a prompt. Because summarization only acts when the
> last entry is a prompt, **it is skipped**."*
>
> Consequence: in a tool-heavy agentic session, the hook fires often and does nothing much of the time.
> Nothing logs, nothing throws. If you are relying on summarisation to keep a long session inside a 4K
> context window, you will discover the gap as a `LanguageModelError.contextSizeExceeded` rather than as
> a warning.

### 13.5 ⚠️ The composition rule — and why Apple's own examples never fire

Modifiers wrap lexically and execute **outside-in**: the modifier written *last* is the *outermost*,
and the outermost runs *first*.

> ✅ **VERIFIED** — three independent statements in the repository agree.
> `README.md:78`: *"Modifiers apply in outside-in order: first, the profile drops completed tool calls,
> then applies a rolling window."*
> `DropCompletedToolCalls.swift:23-25`: *"applying it **outermost** ensures tool-call entries are
> cleaned up **before** a rolling window or summarization step runs."*
> `SummarizeHistory.swift:26-28`: *"Because summarization is the most aggressive form of compression,
> it is typically placed **innermost** (applied last) so that lighter-weight modifiers … **run
> first**."*

So for the README's composed example:

```swift prelude:guide-context
Profile {
  Instructions("A conversation between a user and a helpful assistant.")
  ToggleDarkModeTool()
}
.summarizeHistory(entryThreshold: 10, model: status.summarizerModel)   // written first → innermost → runs LAST
.rollingWindow(entries: 10)                                            // middle
.droppingCompletedToolCalls()                                          // written last → outermost → runs FIRST
```

Runtime order: **drop tool calls → rolling window → summarise.**

> ⚠️ **SILENT FAILURE — with those numbers, summarisation can never run.**
>
> By the time `summarizeHistory(entryThreshold: 10)` executes, `rollingWindow(entries: 10)` has already
> truncated the history to at most 10 entries. The gate is `history.count > entryThreshold` — strictly
> greater — so `10 > 10` is false, forever. The composition is inert. Nothing logs; the modifier is
> present, correctly written, and dead.
>
> ✅ **VERIFIED — every composed example shipped in the repository has this defect.**
> `README.md:89-90`, `DropCompletedToolCalls.swift:31-32`, `SummarizeHistory.swift:34-35`, and the
> bundled skill document at `:210-211` and `:271-272` all pair an `entryThreshold` that is greater than
> or equal to the rolling-window size — including `entryThreshold: 50` with `rollingWindow(entries: 10)`,
> where 10 is never greater than 50.
>
> **The rule: `entryThreshold` must be strictly less than the rolling-window size.** If you compose
> these two modifiers, write the assertion down next to them, because nothing else will tell you.

### 13.6 Should you use the package?

Use it for the **shapes** — it is the best available reference implementation of
`DynamicProfileModifier` + `@SessionProperty(\.history)` + `onPrompt`, written by the framework team.
Be selective about the **implementations**: `droppingCompletedToolCalls()` is sound and useful,
`summarizeHistory` is sound but needs the threshold rule above and only fires on prompt boundaries, and
`rollingWindow(entries:)` ships with a test that says it crashes.

Note also that the package's `Skills` type — the "procedural context loading" pattern session 242
mentions (`242:137`) — is built on `DynamicInstructions` and is covered separately in this part's
agentic-patterns material. One fact from its implementation is worth knowing here because it affects
history size: *"A `Skills` activation produces a tool call in the transcript. Even prompt-based skills
generate a tool-call/tool-output pair."*

---

## 14. `transcriptErrorHandlingPolicy` and the mutable transcript

Two related 27.0 additions: control over what happens to the transcript when something fails, and —
for the first time — a settable `session.transcript`.

### 14.1 The default is rollback

> ✅ **VERIFIED** — `242:155`: *"**By default, when you throw an error from a tool, or when you cancel a
> response, your session's transcript will roll back to its previous state.**"*

> ✅ **VERIFIED** — from Apple's tool-calling article: *"When errors are thrown from a tool, the
> framework rolls back the transcript to a previously known valid state. Use
> `transcriptErrorHandlingPolicy` to define whether the session preserves the transcript an error
> occurs or if it reverts back to before the last request. **When preserving the transcript, the last
> entry may be partially generated.**"*

### 14.2 The type is a struct with static members, not an enum

> ✅ **VERIFIED** — from Apple's documentation:
>
> ```swift
> struct TranscriptErrorHandlingPolicy          // Sendable, SendableMetatype — iOS 27.0+
> static let preserveTranscript   // "Keep the current transcript as is."
> static let revertTranscript     // "Revert the transcript back to the state it was in just before the most recent request."
> ```
>
> It is a **struct with static constants**, which is Apple's current idiom for extensible option types
> (the same shape as `GenerationOptions.ToolCallingMode`). Do not write an exhaustive `switch` over it.

Two places to set it:

> ✅ **VERIFIED** — `242:158-159`: *"If you're using profiles, you can now set
> `transcriptErrorHandlingPolicy` using a **modifier**. If you're not using a profile, you can **set it
> directly on your session**."* And the session-level property is documented on `LanguageModelSession`
> as `var transcriptErrorHandlingPolicy: TranscriptErrorHandlingPolicy` (iOS 27).

```swift prelude:guide-context
// Profile form — VERIFIED as a documented modifier.
Profile {
    AgentInstructions()
}
.transcriptErrorHandlingPolicy(.preserveTranscript)

// Session form — the property is documented; assignment shown here is the natural reading.
session.transcriptErrorHandlingPolicy = .preserveTranscript
```

> 🟡 **RECONSTRUCTED — the session-level *assignment*.** The property is ✅ VERIFIED to exist on
> `LanguageModelSession` and session 242 says you "set it directly on your session", but no compiled
> call site appears in the corpus, and whether it is also an `init` parameter is unknown. The
> assignment form is the natural reading of a documented settable property. **If you can express the
> policy on a profile, prefer the profile modifier** — that one is documented as a modifier by name.

### 14.3 What `.preserveTranscript` is for, and what it costs you

> ✅ **VERIFIED** — `242:156-157`: *"For advanced use cases where you want to **allow cancelling part
> way through a response and then resuming again**, you need to **keep your transcript in state after an
> error**."*

> ✅ **VERIFIED** — `242:163-164`: *"When using `.preserveTranscript`, **the onus is on you to put your
> transcript back into a good state if you intend to continue using your session.**"*

"A good state" is doing a lot of work in that sentence. Concretely, after a preserved abort you may
have:

- a trailing `.response` entry that is **partially generated** (Apple's tool-calling article says so
  explicitly),
- a `.toolCalls` entry with no matching `.toolOutput`,
- or a `.prompt` with nothing after it.

Any of those will be fed to the model on the next turn as if it were normal conversation. Recall §4.3's
principle: *the model cannot distinguish between information that never existed and information that
was removed*, and it also cannot tell a truncated answer from a complete one. A half-written response
in the transcript is a confident lie about what the assistant previously said.

**Use `.revertTranscript` (the default) unless you are specifically building resume-after-cancel.** If
you do use `.preserveTranscript`, write the repair step at the same time as the flag, not later.

### 14.4 ⚠️ The mutable transcript has a dedicated session error

> ✅ **VERIFIED** — `242:165-167`: *"To facilitate that, **the `transcript` property on session is now
> mutable**. Remember though, **you can only modify the transcript when the session's `isResponding`
> property is `false`**. **Attempting to mutate the transcript during a response is a programmer
> error.**"*

> ✅ **VERIFIED** — the declaration confirms it: `final var transcript: Transcript { get set }`.

> ⚠️ **CALLER BUG, TYPED FAILURE.** “Programmer error” classifies this as misuse; it does not prove
> a fatal process trap. Foundation Models defines
> `LanguageModelSession.Error.transcriptMutationWhileResponding` for exactly this condition.[^transcript-mutation-error]
> Treat it as a bug in the session owner and prevent it at the mutation boundary:
>
> **Guard every single assignment:**
>
> ```swift
> guard !session.isResponding else { return }
> session.transcript = repaired(session.transcript)
> ```

The hazard is that `isResponding` is a *race*, not a static property of your code. A repair triggered
from a UI action can land while a background stream is still running. Origami's answer is to use
`session.isResponding` as an explicit re-entrancy guard at its event boundary
(`Origami/Models/Orchestrator.swift:367`), and to funnel all model work through a single serialised
task (`currentTask?.cancel()` at the head of every event, `Orchestrator.swift:167`). Copy that
structure: **one owner, one in-flight task, all mutation on the owner.**

Apple's documentation attaches a related warning to `isResponding` itself:

> ✅ **VERIFIED**: *"**You should not call any of the respond methods while this property is `true`.**
> Disable buttons and other interactions to prevent users from submitting a second prompt while the
> model is responding to their first prompt."*

### 14.5 A safe repair helper

```swift compile:27
import FoundationModels

/// The only owner of this session. Main-actor isolation serializes response
/// startup, the idle check, and transcript mutation into one critical region.
@MainActor
final class SessionOwner {
    private let session: LanguageModelSession

    init(session: LanguageModelSession) {
        self.session = session
    }

    /// Starts responses through the same serialized owner that performs repairs.
    func respond(to prompt: String) async throws -> String {
        try await session.respond(to: prompt).content
    }

    /// Repairs the transcript after a preserved abort. No-op while responding.
    /// - Returns: `true` if the transcript was rewritten.
    @discardableResult
    func repairTranscriptIfIdle(
        _ repair: (Transcript) -> Transcript
    ) -> Bool {
        guard !session.isResponding else { return false }
        session.transcript = repair(session.transcript)
        return true
    }
}
```

Two notes on that owner. It returns `false` before attempting an invalid mutation, so a repair at a
bad moment becomes a retry rather than a failed response — you decide when to try again. More
importantly, the session is private and the response entry point lives on the same `@MainActor`
owner; callers cannot race the check with an unowned response. It takes the whole `Transcript`,
because `session.transcript` is a `Transcript`, not an entry array; use `Transcript(entries:)` to
rebuild one.

A minimal, honest repair — drop a trailing entry that has no business being there:

```swift compile:27 imports:FoundationModels
func droppingUnfinishedTail(_ transcript: Transcript) -> Transcript {
    var entries = Array(transcript)
    if case .toolCalls = entries.last {
        entries.removeLast()          // a tool call with no output is worse than nothing
    }
    return Transcript(entries: entries)
}
```

> 🟡 **RECONSTRUCTED — `Array(transcript)`.** `Transcript` is verified to be a `Collection` of
> `Transcript.Entry` (that is why `history:` accepts it, §7.2) and `Transcript(entries:)` is verified
> from Origami, so materialising it into an array is sound. What is not verified is whether
> `Transcript` also exposes a direct `entries` property. **If it does, use it**; the conversion above
> works either way.

There is also a documented, blunter recovery for the specific case of blowing the context window,
which sidesteps transcript surgery entirely by building a new session:

> ✅ **VERIFIED** — from Apple's context-window article:
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
> *"The first transcript entry often contains important instructions and the last entry contains the
> most recent context. By preserving the first and last entry, you maintain continuity while
> dramatically reducing token usage."*
>
> Note that this snippet is written against the older `init(transcript:)` label (§7.4) and that the
> "first entry is the instructions" assumption holds only for a session whose instructions were fixed
> at init. With a `DynamicProfile`, instructions are re-materialised from the profile on every prompt,
> so what you need to preserve is the *history*, and `init(profile:history:)` is the right rebuild
> path.

---

## 15. A complete worked profile

Everything above, assembled into one feature. This is a reading-assistant: it helps you pick an
article to read, then coaches you through it, then answers one-off vocabulary questions without
disturbing the main thread of the conversation. Three personas, two models, one session, one
transcript.

Every API shape used here is verified in §§3–14; the *composition* is this guide's, modelled on
Origami's architecture. Where a shape is reconstructed, it is called out.

### 15.1 The state machine

```swift prelude:guide-context
import Foundation
import Observation

enum ReaderMode: Equatable {
    case choosing      // help the person pick something to read
    case coaching      // walk them through the piece they chose
    case glossing      // a one-off "what does this word mean" lookup
}

enum ReaderEvent {
    case openedLibrary
    case chose(articleID: UUID)
    case askedAboutTerm(String)
    case dismissedTerm
}

@Observable
final class ReaderOrchestrator {
    private(set) var mode: ReaderMode = .choosing
    private(set) var chosenArticle: Article?
    private(set) var pendingTerm: String?

    /// The only place `mode` changes. Mutating it *is* the profile switch.
    func send(_ event: ReaderEvent) {
        switch event {
        case .openedLibrary:
            mode = .choosing
            chosenArticle = nil
        case .chose(let id):
            chosenArticle = Library.shared.article(id)
            mode = .coaching
        case .askedAboutTerm(let term):
            pendingTerm = term
            mode = .glossing
        case .dismissedTerm:
            pendingTerm = nil
            mode = chosenArticle == nil ? .choosing : .coaching
        }
    }
}
```

Nothing here imports `FoundationModels`. That is the point: this file is a plain state machine you can
unit-test in milliseconds, and the AI layer is downstream of it.

### 15.2 Session properties

```swift compile:27
import FoundationModels

extension SessionPropertyValues {
    /// A running summary written at response boundaries, read by every persona.
    @SessionPropertyEntry
    var conversationSummary: String? = nil

    /// Counts tool calls in the current coaching turn, so `.required` has an exit.
    @SessionPropertyEntry
    var lookupsThisTurn: Int = 0
}
```

Both are mutable with initial values, as required. `conversationSummary` is the "optional string"
pattern session 242 describes.

### 15.3 Reusable instruction components

```swift prelude:guide-context
import FoundationModels

/// House style. Nested into every persona, so it is stated once.
struct HouseVoice: DynamicInstructions {
    var body: some DynamicInstructions {
        Instructions {
            """
            Write in plain language. Two or three sentences unless asked for more.
            Never claim to have read something you were not given.
            """
        }
    }
}

/// The coaching persona: article-aware, with the tools that only make sense here.
struct CoachInstructions: DynamicInstructions {
    let article: Article
    let summary: String?

    var body: some DynamicInstructions {
        // Static content first — see §4.3. This part never changes for a given article,
        // so it stays at a stable position in the token sequence.
        HouseVoice()

        Instructions {
            """
            You are helping someone read "\(article.title)".
            Ground every answer in the passage they are on.
            When they ask what a word means, call the glossary tool rather than guessing.
            """
        }

        GlossaryTool()

        // Conditional content last — appending here invalidates only itself.
        if let summary {
            Instructions("Earlier in this conversation: \(summary)")
        }
    }
}

struct ChooserInstructions: DynamicInstructions {
    var body: some DynamicInstructions {
        HouseVoice()
        Instructions {
            """
            Help the person pick something to read from their library.
            Offer at most three options, each with one sentence on why.
            """
        }
        LibrarySearchTool()
    }
}

struct GlossInstructions: DynamicInstructions {
    let term: String

    var body: some DynamicInstructions {
        HouseVoice()
        Instructions {
            """
            Define "\(term)" for a general reader in one or two sentences.
            No preamble. If the surrounding passage is available, ground the answer in it.
            """
        }
    }
}
```

`HouseVoice()` appears in all three personas and its text is emitted once per persona — that is the
concatenation behaviour from §4.1 doing exactly what you want: shared policy, written once.

### 15.4 The profile

```swift illustrative
import FoundationModels

struct ReaderProfile: LanguageModelSession.DynamicProfile {
    var orchestrator: ReaderOrchestrator

    /// One stored model, referenced from several branches. Swapping this line
    /// for `PrivateCloudComputeLanguageModel()` moves the whole feature to PCC.
    var serverModel = SystemLanguageModel()

    @SessionProperty(\.conversationSummary) var summary
    @SessionProperty(\.lookupsThisTurn) var lookups

    var body: some DynamicProfile {
        switch orchestrator.mode {

        case .choosing:
            Profile {
                ChooserInstructions()
            }
            .model(serverModel)
            .temperature(1.0)                     // §3.2 — Double, and a modifier

        case .coaching:
            if let article = orchestrator.chosenArticle {
                Profile {
                    CoachInstructions(article: article, summary: summary)
                }
                .model(serverModel)
                .toolCallingMode(lookups < 3 ? .allowed : .disallowed)
                .onToolCall { lookups += 1 }
                .onResponse { lookups = 0 }
                .compact(keeping: 12)             // the custom modifier below
            } else {
                // The builder needs exactly one profile per path — §6.3.
                Profile {
                    ChooserInstructions()
                }
                .model(serverModel)
            }

        case .glossing:
            Profile {
                GlossInstructions(term: orchestrator.pendingTerm ?? "")
            }
            .model(SystemLanguageModel())         // small, fast, local
            .historyTransform(Self.recentOnly(_:))
        }
    }

    /// Named, `static`, and unit-testable — §12.4.
    static func recentOnly(_ entries: [Transcript.Entry]) -> [Transcript.Entry] {
        Array(entries.suffix(4))                  // note the Array(...) — §12.3
    }
}
```

Read the `.glossing` branch again: a vocabulary lookup runs on the on-device model, sees only the last
four history entries, and **leaves the stored transcript untouched**. When the user dismisses the term
and the mode returns to `.coaching`, the full conversation is still there. That is `historyTransform`
earning its keep — a cheap side-question that cannot damage the main thread.

Compare with what `@SessionProperty(\.history)` would have done: permanently discarded everything
before the last four entries, for every persona, forever.

### 15.5 The custom modifier

```swift compile:27
import FoundationModels

/// Presents a bounded, tool-traffic-free view of the history to this profile's model.
struct Compacted: LanguageModelSession.DynamicProfileModifier {
    let keeping: Int

    func body(content: Content) -> some LanguageModelSession.DynamicProfile {
        content.historyTransform { history in
            let withoutToolTraffic = history.filter { entry in
                switch entry {
                case .toolCalls, .toolOutput: false
                default: true
                }
            }
            return Array(withoutToolTraffic.suffix(max(0, keeping)))
        }
    }
}

extension LanguageModelSession.DynamicProfile {
    /// Hide tool traffic and cap the history this profile's model sees.
    func compact(keeping: Int) -> some LanguageModelSession.DynamicProfile {
        modifier(Compacted(keeping: keeping))
    }
}
```

`.compact(keeping: 12)` at the use site says what it means; `historyTransform` with a filter and a
suffix says how it works. That is the entire argument for custom modifiers.

Note that the whole thing is a **transform**, not a `history` write — so a later PCC-backed branch
still sees the tool traffic if it wants it.

### 15.6 A tool that moves the state machine

```swift prelude:guide-context
import FoundationModels

struct GlossaryTool: Tool {
    let description = "Look up what a term means for the reader."

    @Generable
    struct Arguments: Sendable {
        @Guide(description: "The single word or phrase to define")
        var term: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let entry = await Glossary.shared.definition(for: arguments.term) else {
            // Graceful degradation: tell the model, do not throw — Origami's idiom.
            return "No glossary entry for \"\(arguments.term)\". Explain it from context instead."
        }
        return entry
    }
}
```

Two verified patterns in nine lines: **`name` is omitted** (it is optional and defaulted, and this tool
is not referenced by name in any instructions text — if it were, §4.4 says declare the name), and the
failure path **returns prose to the model rather than throwing**. Throwing from a tool triggers a
transcript rollback under the default policy (§14.1); returning a sentence lets the model recover.

### 15.7 Wiring it up

```swift prelude:guide-context
import FoundationModels
import Observation
import SwiftUI

@MainActor
@Observable
final class ReaderFeature {
    let orchestrator = ReaderOrchestrator()

    @ObservationIgnored
    private lazy var session = LanguageModelSession(
        profile: ReaderProfile(orchestrator: orchestrator),
        history: Transcript(entries: [])
    )

    private(set) var latest: String = ""
    private var currentTask: Task<Void, Never>?

    func ask(_ text: String) {
        currentTask?.cancel()
        currentTask = Task {
            do {
                let stream = session.streamResponse(to: Prompt(text))
                var received = false
                for try await partial in stream {
                    received = true
                    latest = partial.content
                }
                // A turn whose only output was a tool call streams zero partials.
                if !received { latest = "" }
            } catch is CancellationError {
                // Cancellation is an outcome, not a failure.
            } catch {
                latest = error.displayMessage
            }
        }
    }

    func send(_ event: ReaderEvent) {
        orchestrator.send(event)      // the profile switch. That is all.
    }
}
```

`send(_:)` is the entire handoff API. There is no `session.switchProfile(...)`, because there is no such
thing. The next call to `ask` re-evaluates `ReaderProfile.body`, which reads the new `mode`, and the
session is a different assistant with the same memory.

Three details in that listing are load-bearing and all three come from Apple's samples:

- **`@ObservationIgnored private lazy var session`** — §7.2. Without `lazy`, `self` is unavailable for
  the profile; without `@ObservationIgnored`, the session becomes observed state.
- **`if !received { latest = "" }`** — a stream can complete having yielded **zero** partials when the
  model's only output was a tool call. Any spinner driven off first-token arrival hangs forever.
  ✅ VERIFIED from `Origami/Coach/CoachModel.swift:58-73`.
- **`catch is CancellationError` before the general `catch`** — Origami treats cancellation as a
  first-class non-error outcome at eight separate call sites.

`error.displayMessage` refers to the error-taxonomy extension in
[the errors guide](../../part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md);
the short version is that `SystemLanguageModel.Error` must be checked **before** `LanguageModelError`,
and both before `GeneratedContent.ParsingError`.

---

## 16. Quick reference

### 16.1 Version floors

Everything in the table is **iOS 27.0 / iPadOS 27.0 / macOS 27.0 / visionOS 27.0**, Beta. There is no
26.x version of any of it. `foundation-models-utilities` additionally declares **watchOS 27.0**.

| Symbol | Evidence |
|---|---|
| `LanguageModelSession.DynamicProfile` (protocol) | ✅ docs + Apple sample + compiled tests |
| `LanguageModelSession.DynamicProfileBuilder` | ✅ docs |
| `LanguageModelSession.Profile` (struct, `init(_:)`) | ✅ docs + Apple sample |
| `LanguageModelSession.DynamicProfileModifier` (+ `Content`, `body(content:)`) | ✅ docs + Apple's utilities package |
| `DynamicInstructions` (top-level protocol) | ✅ docs + Apple sample |
| `DynamicInstructionsBuilder`, `DynamicInstructionsForEach` | ✅ docs + SDK-verified — `ForEach` has exactly two inits, `(_:id:content:)` and an `Identifiable` `(_:content:)` (`FoundationModels-27.0-macos.swiftinterface:784-793`) |
| `.model(_:)` on a profile | ✅ Apple sample (moved into the framework at Xcode 27 beta 3) |
| `.temperature(_:)` `Double` | ✅ Apple sample + docs |
| `.reasoningLevel(_:)` — `.light` / `.moderate` / `.deep` | ✅ Apple sample (`.deep`) + docs |
| `.samplingMode(_:)` | ✅ docs · no sample · cases renamed during beta |
| `.maximumResponseTokens(_:)`, `.toolCallingMode(_:)`, `.transcriptErrorHandlingPolicy(_:)`, `.modifier(_:)` | ✅ docs |
| `.historyTransform(_:)` — `([Transcript.Entry]) -> [Transcript.Entry]` | ✅ Apple sample (function reference) + docs |
| `.onActivate/.onDeactivate/.onPrompt/.onResponse/.onToolCall/.onToolOutput/.onReasoning` | ✅ docs + SDK-verified — overload pairs, `async throws`, `Transcript.*` payloads; activate/deactivate zero-arg `async` non-throwing (`:984-1026`) |
| `SessionPropertyValues`, `SessionPropertyKey`, `@SessionPropertyEntry`, `@SessionProperty(\.…)` | ✅ docs + compiled tests |
| `\.history` → `Transcript.HistoryView` `{ get set }` (beta 5; `ArraySlice<Transcript.Entry>` in earlier 27.0 betas — §12.3) | ✅ docs + SDK-verified (`27.0:1071-1076`) |
| `session.properties.<name>` | ✅ compiled test · setter SDK-verified (`:1103-1107`); write-from-outside *semantics* 🔴 GAP |
| `LanguageModelSession(profile:history:)` · `init(dynamicInstructions:history:)` | ✅ docs + Apple sample |
| `TranscriptErrorHandlingPolicy` — `.preserveTranscript` / `.revertTranscript` | ✅ docs |
| `session.transcript` — now `{ get set }` | ✅ docs + WWDC |
| `session.isResponding` (26.0) | ✅ docs + Apple sample |

### 16.2 The rules, condensed

1. The `body` re-evaluates before every prompt and **must be pure**. Mutation goes in lifecycle
   modifiers.
2. A `DynamicProfile` body resolves to **exactly one** `Profile`. Use `switch` or `if`/`else if`/`else`
   — never parallel bare `if`s. (`DynamicInstructions` bodies *do* allow a bare `if`.)
3. `Profile { … }.model(x)` — the model is a **modifier**, not an initialiser label.
4. Static instructions and tools **first** in a `DynamicInstructions` body, conditional content
   **last**.
5. Every tool name you mention in instructions text must be in the tool set. Assert it in a test.
6. `historyTransform` is **local, per-profile, lossless**. `@SessionProperty(\.history)` is **global,
   lossy, permanent**. Default to the former.
7. `historyTransform` takes and returns `[Transcript.Entry]`; `history` is a `Transcript.HistoryView`
   (an `ArraySlice` before beta 5). Wrap with `Array(…)`.
8. Precedence: **call site > innermost modifier > outer modifier**. Lifecycle callbacks **accumulate**
   instead of overriding.
9. A profile switch invalidates the KV cache for the whole transcript. Switch at conversation
   boundaries, not per turn.
10. `.required` tool calling is a `while` loop; a session property plus a conditional
    `toolCallingMode` is the profile-shaped exit.
11. Guard every `session.transcript = …` with `!session.isResponding`. Mutating during a response is
    session misuse represented by `LanguageModelSession.Error.transcriptMutationWhileResponding`.[^transcript-mutation-error]
12. If you compose `foundation-models-utilities` history modifiers, `entryThreshold` must be
    **strictly less** than the rolling-window size, or summarisation never fires.

### 16.3 Symptom → cause

| Symptom | Likely cause | § |
|---|---|---|
| Profile never switches; Instruments Instructions lane shows one unbroken region | the state your `body` reads is not the state you mutate, or the mutation is not `@Observable` | 2, 4.4 |
| Switch happens "one turn late" | expected: a tool-driven switch takes effect on the **next** request | 4.4 |
| Model loops, offering the same thing repeatedly, no error ever | a tool named in instructions text but absent from the tool set | 4.4 |
| Side effect runs an unpredictable number of times | side effect in the `body` instead of a lifecycle modifier | 6.2 |
| Compiler rejects your `body` with a builder error | two parallel `if`s; the builder requires exactly one active profile | 6.3 |
| Time-to-first-token climbs turn over turn, prompt size flat | conditional content declared before static content; or a per-turn profile switch | 4.3, 5.7 |
| `.model()` change did not take effect | a call-site `options:` argument, or an inner modifier, overrides it | 8 |
| Context you needed is gone forever | you wrote `@SessionProperty(\.history)` where `historyTransform` was wanted | 12.1 |
| `historyTransform` closure will not compile | returning an `ArraySlice` where `[Transcript.Entry]` is required | 12.3 |
| `summarizeHistory` never fires | `entryThreshold ≥ rollingWindow` size, or the trailing entry is not a `.prompt` | 13.4, 13.5 |
| History window starts with an orphaned response | `rollingWindow(entries:)` cutting between a prompt and its response — a known, pinned bug | 13.3 |
| Strange answers after an aborted turn | `.preserveTranscript` left a partially-generated trailing entry | 14.3 |
| `LanguageModelSession.Error.transcriptMutationWhileResponding` thrown on assignment | `session.transcript = …` while `isResponding` was `true` | 14.4 |
| Spinner never clears | the turn's only output was a tool call; the stream yielded zero partials | 15.7 |
| `LanguageModelError.contextSizeExceeded` in a long session | trimming that silently never ran | 13.5 |

### 16.4 Where the sources disagree, and who wins

| # | Conflict | Ruling |
|---|---|---|
| 1 | `var body: some LanguageModelSession.DynamicProfile` (docs, WWDC, doc mirrors) vs `some DynamicProfile` (Apple sample) | **Both compile.** Use the short form inside a conforming type, the long form in a free extension. Earlier "naming corrections" that mandated the long form everywhere were half wrong. |
| 2 | `Profile(model:) { }` (reconstructions, one doc mirror) vs `Profile { }.model(_:)` (Apple sample + docs) | **Sample wins, now SDK-confirmed** — `Profile` has exactly one init, the builder-closure form; no `model:` label exists in the 27.0 beta interface (`:830-843`, checked 2026-09-08). |
| 3 | `.temperature(1)` (WWDC narration) vs `.temperature(1.0)` (sample + docs) | **`Double`.** |
| 4 | "Beta (iOS 26.0+)" on one doc mirror of the dynamic-sessions article vs 27.0 everywhere else | **27.0.** The mirror is wrong. |
| 5 | `reasoningLevel` as a profile modifier vs `ContextOptions(reasoningLevel:)` per call | **Both exist** — and both take the same `ContextOptions.ReasoningLevel?` type (`:976`, `:3132-3135`). A profile-level `.contextOptions(_:)` modifier **does not exist** in the 27.0 beta interface (checked 2026-07-29). |
| 6 | `ToolCallMode` (a documentation page title) vs `GenerationOptions.ToolCallingMode` (compiled code) | **`ToolCallingMode`.** |
| 7 | `@SessionPropertyEntry()` (one doc mirror) vs `@SessionPropertyEntry` (compiled code) | **No parentheses.** |
| 8 | The demo app's modes: brainstorm/planning/reviewing (session 242) vs `.brainstorm`/`.tutorial`/`.term` (the shipping sample) vs brainstorm/tutorial (session 243) | **The sample.** Three inconsistent tellings of one demo; do not present any WWDC mapping of mode → model as a recommendation. |
| 9 | Brainstorming on PCC (242) vs on-device (the sample) vs both-on-PCC (243) | No recommended mapping exists. Choose per capability, cost and privacy — the three criteria session 241 names. |
| 10 | "`body` re-evaluated each time the model is prompted" (WWDC) vs 7 evaluations across 3 turns (community-measured) | Design for **at least once, possibly several times**. Keep the body pure. |
| 11 | Utilities README's "exceeds 5000 tokens" vs the source's entry-count gate | **The source.** The README sentence is stale prose from a deleted API. |
| 12 | Community claim that a throw from `onToolCall` returns control "to the loop" vs Apple's documented "propagates to the caller's `respond`" | **Apple's documentation.** Design for turn-level abort. |

### 16.5 Pre-ship checklist

- [ ] The `body` contains no assignments, no logging, no `Task {}`. (§6.2)
- [ ] Every branch of the profile body resolves to exactly one `Profile`, via `switch` or `if`/`else`. (§6.3)
- [ ] Static instructions and tools precede all conditional content in every `DynamicInstructions` body. (§4.3)
- [ ] A test asserts that every tool name appearing in instructions text is in the resolved tool set. (§4.4)
- [ ] Any profile with `.toolCallingMode(.required)` has a written-down exit condition. (§5.5)
- [ ] Every persona that crosses to a server model has a `historyTransform` that redacts, or a documented decision that it does not need one. (§1, §12.6)
- [ ] No `@SessionProperty(\.history)` write exists where a `historyTransform` would do. (§12.1)
- [ ] Every `session.transcript = …` is guarded by `!session.isResponding`. (§14.4)
- [ ] `.preserveTranscript`, if set, is paired with a repair path. (§14.3)
- [ ] Loading UI exits on stream **completion**, not first partial. (§15.7)
- [ ] One Instruments trace exists, on device, and the Instructions lane shows the number of regions you expect. (§4.4)
- [ ] If composing utilities history modifiers: `entryThreshold` < rolling-window size. (§13.5)
- [ ] A transcript-snapshot debug harness exists and is off in release. (§7.5)
- [ ] An evaluation exists for the personas the feature depends on, because context-engineering changes are not testable by assertion. (§16.6)

### 16.6 One last piece of advice, from Apple

> ✅ **VERIFIED** — `242:185-187`: *"When you start to get into **nuanced transcript modifications**
> like this, it becomes **even more important to use the Evaluations framework to create eval sets and
> quantify the effect of context engineering strategies**. **Data driven optimization is the only way
> to be confident.**"*

Every technique in this guide changes what the model sees. None of them changes it in a way you can
assert on with `#expect(output == "…")`. Trimming that looks harmless can cost you ten points of task
accuracy, and a summariser that "reads fine" can drop the one fact the next turn needed. Part 6 covers
the Evaluations framework; the specific tool for this guide's material is a trajectory evaluation over
the tool calls your personas depend on, plus a model-judge dimension for answer quality before and
after a context change.

---

## 17. Sources

**Apple sample-code projects, read on disk** — the highest-precedence evidence here, because it
compiles and ships. Downloaded 2026-07-27 from the `docs-assets` ZIPs behind
`developer.apple.com/tutorials/data/documentation/<framework>/<slug>.json`:

- **Origami — *Crafting a dynamic tutorial for Apple Intelligence*** (200 MB archive, 61 Swift files,
  `IPHONEOS/MACOSX/XROS_DEPLOYMENT_TARGET = 27.0`, `SWIFT_VERSION = 6.0`). Files cited:
  `Models/OrchestratorProfile.swift` (the `DynamicProfile`, quoted in full in §3.1),
  `Models/Orchestrator.swift` (the reducer, session construction, seeded history, cancellation),
  `Models/OrchestratorState.swift`, `Models/TranscriptRecorder.swift`,
  `Models/Error+DisplayMessage.swift`, `Tutorial/Intelligence/TutorialInstructions.swift`,
  `Tutorial/Intelligence/OrigamiInstructions.swift`, `Tutorial/Intelligence/CraftTools.swift`,
  `Coach/CoachInstructions.swift`, `Coach/CoachModel.swift`, `Coach/MovePhotoToStepTool.swift`,
  `Terms/TermInstructions.swift`, `Origami.entitlements`.
- **Searching indexed content with natural language** (the hiking-trails `SpotlightSearchTool` app,
  iOS 27) — cited only for the byte-identical Private Cloud Compute entitlement comment block.

Two other Apple samples exist and are **deliberately not cited** as 2026 evidence: the
coffee/generative-game sample and the SpeechAnalyzer sample are iOS 26 / WWDC25 leftovers that were
never refreshed.

**Compiled source read on disk:**

- `apple/foundation-models-utilities` at commit `376ca60` (tag `1.0.0-beta3`, 2026-07-10) —
  `Sources/FoundationModelsUtilities/History/DropCompletedToolCalls.swift`, `…/RollingWindow.swift`,
  `…/SummarizeHistory.swift`, `…/TranscriptRendering.swift`, `Skills/Skills.swift`,
  `Skills/SkillBuilder.swift`, `Package.swift`, `README.md`, `CONTRIBUTING.md`, and the
  `DroppingCompletedToolCallsTests` / `RollingWindowTests` / `SummarizeHistoryTests` suites.
- `ml-explore/mlx-swift-lm` —
  `IntegrationTesting/IntegrationTestingTests/MLXFoundationModelsIntegration/ToolCalling/StructuredToolOutputSessionTests.swift`
  (the compiled `DynamicProfile` conformance, `@SessionPropertyEntry` declaration and
  `session.properties` assertion) and
  `Libraries/MLXFoundationModels/ToolCalling/ToolCallingModeResolution.swift`.

**Apple documentation** (harvested 2026-07-27 via mirrors of `developer.apple.com`):
`/documentation/foundationmodels/composing-dynamic-sessions-with-instructions-and-profiles` (the
primary article for §§3–12) · `/documentation/foundationmodels/optimizing-key-value-caching-in-language-model-sessions`
· `/documentation/foundationmodels/managing-the-context-window` ·
`/documentation/foundationmodels/languagemodelsession` and its `dynamicprofile`,
`dynamicprofilemodifier`, `profile`, `sessionproperty` children ·
`/documentation/foundationmodels/dynamicinstructions` and `/dynamicinstructionsforeach` ·
`/documentation/foundationmodels/sessionpropertyvalues` and `/sessionpropertykey` ·
`/documentation/foundationmodels/transcripterrorhandlingpolicy` ·
`/documentation/foundationmodels/generationoptions` and its `toolcallingmode` / `samplingmode`
children · `/documentation/foundationmodels/analyzing-the-runtime-performance-of-your-foundation-models-app`.

**WWDC26 sessions** (spoken-word transcripts; on-screen code was described, not dictated, which is why
narrated-only code appears here as 🟡 RECONSTRUCTED or is replaced by sample code):
**241** *What's new in the Foundation Models framework* (Zhen) — the dynamic-profiles introduction, the
single-active-`Profile` rule, the privacy-boundary guidance · **242** *Build agentic app experiences
with the Foundation Models framework* (Erik, Oliver) — the primary session for this guide: three
layers, lifecycle modifiers, session properties, the `history` decision rule, tool-calling mode,
`transcriptErrorHandlingPolicy`, KV caches · **243** *Debugging and profiling Foundation Models
features with Instruments* (Erik) — the Instructions lane, the instructions/toolset drift bug, the
"silent failure" quote, the switch-takes-effect-next-request timing.

**Community sources, explicitly attributed as such and never presented as Apple claims:**
`john-rocky/coreai-model-zoo` knowledge notes (`dynamic-profiles-local-models.md` for the body
re-evaluation count, lifecycle ordering and the two model-switch latency figures;
`agentic-security-checklist.md` for the `historyTransform`-as-security-hook framing, attributed there
to WWDC26 session 347, which is **not in this corpus**) · one local documentation mirror of Apple's
Foundation Models articles, used only where it agrees with a primary source, and named explicitly in
§16.4 wherever it disagrees.

**Precedence applied throughout:** Apple sample-code projects > headers and compiled SDK sources >
Apple documentation pages > Apple-staff forum answers > WWDC transcripts > community repositories.
The rulings that precedence produced are tabulated in §16.4 — most importantly that
`Profile { }.model(_:)` beats `Profile(model:) { }`, that `some DynamicProfile` is legal despite every
transcript-derived reconstruction saying otherwise, and that the utilities package's own README loses
to the utilities package's own source.

[^transcript-mutation-error]: Apple, [`LanguageModelSession.Error.transcriptMutationWhileResponding`](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/error/transcriptmutationwhileresponding), “The session’s transcript was mutated while a request was in progress.”
