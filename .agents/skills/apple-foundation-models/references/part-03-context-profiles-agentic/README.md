# Part 3 — Context, profiles, and agentic sessions

**Version floor:** the conceptual material starts at **26.0** (`LanguageModelSession`, `Transcript`,
`Tool` — watchOS only from 27.0), and the two introspection APIs it leans on, `SystemLanguageModel.contextSize`
and `tokenCount(for:)`, are **26.4** — of which only `contextSize` back-deploys. **Everything else in this
part is 27.0 and does not exist below it**: `Transcript.history`, the settable `session.transcript`,
`historyTransform(_:)`, the whole `DynamicProfile` / `Profile` / `DynamicInstructions` family,
`@SessionProperty`, `ToolCallingMode`, `TranscriptErrorHandlingPolicy`, `Usage`, `LanguageModelError`.
`apple/foundation-models-utilities` declares macOS/iOS/visionOS/watchOS **27.0** and **no tvOS**. You need
**Xcode 27** and a real device — the Simulator punches inference out to the host macOS, so every latency
number you take there is meaningless.

**Who this is for:** Swift app developers whose feature has outgrown a single `respond(to:)` call — a
conversation that runs long enough to overflow, a session that needs more than one persona or more than one
model, or an agent that calls tools in a loop. If you are still learning the everyday API, read
[Part 2](../part-02-foundation-models-everyday-api/README.md) first. If you are choosing *which model* sits behind
the session, that is [Part 4](../part-04-beyond-the-built-in-model/README.md).

---

## Why this part exists

Apple said it plainly at WWDC26: *"we intentionally shaped `LanguageModelSession` APIs to be append only…
this year, we're taking the training wheels off."* In 2025 you could not write a slow session, because you
could not modify the transcript. In 2026 you can mutate `session.transcript`, reassign `history`, transform
per profile and swap models mid-conversation — and **every one of those powers is a way to make your app
slower, or wrong, with no error, no warning and no compiler diagnostic.**

Two facts make the whole part follow mechanically. **The transcript *is* the context window** — not a log of
it, a rendering of it — so tool definitions, `@Generable` schemas, images and every past response are all
spending your ~4K budget before the user types anything. And **the KV cache is a prefix**: appending is
free, a change at position *N* invalidates everything from *N* onward. That single sentence explains why
`historyTransform` beats mutating `history`, why conditional content goes at the *bottom* of a
`DynamicInstructions` body, why an interpolated `Date()` in your instructions is a catastrophe, and why
switching profiles is a deliberate reset rather than a cheap toggle.

The second framing correction is about profiles. **A `DynamicProfile` is not a configuration object; it is a
projection of your app's `@Observable` state machine**, in exactly the sense a SwiftUI `body` projects
`@State`. Apple's Origami sample makes this literal — an orchestrator holds `mode`, the profile's `body`
`switch`es on it, and **mutating `orchestrator.mode` *is* the agent handoff.** There is no
`session.switch(to:)`. Once you hold that, the purity rule, the single-active-`Profile` constraint and the
"imperative work goes in lifecycle modifiers" rule all stop being arbitrary.

And the cost that has no error channel: **trimming is a lie to the model.** Apple's own words — *"there's no
reliable way for the model to distinguish between information that never existed and information that did
exist but was removed,"* so it *"reasons confidently from incomplete evidence."* Latency regressions you can
at least measure. This one you can only evaluate.

---

## Read this first: the triage table

| If your situation is… | Read | Why |
|---|---|---|
| "I keep hitting `contextSizeExceeded`" | [3.1 §6–§7](references/01-context-window-and-kv-cache.md#6-overflow-contextsizeexceeded-and-the-pattern-people-hand-rolled) | The four levers, Apple's documented recovery, and the 26.0-only rebuild path |
| "I hardcoded 4096" | [3.1 §3](references/01-context-window-and-kv-cache.md#3-reading-the-budget-contextsize-and-the-4096-token-window) | Read `contextSize` at runtime. Stable macOS 27 and both project-run physical-device baselines returned 4,096, while Simulator hosting has also returned 0. The retired 8,192 community comment never reproduced; treat every value as runtime observation, not a constant. |
| "Time-to-first-token climbs turn over turn, prompt size flat" | [3.1 §8](references/01-context-window-and-kv-cache.md#8-the-kv-cache-is-a-prefix) | Something is invalidating your prefix. §8.10's expensive list is the checklist |
| "I need to know what a turn actually cost" | [3.1 §5](references/01-context-window-and-kv-cache.md#5-counting-after-you-spend-usage-and-the-cache-hit-rate) | `Usage`, `cachedTokenCount`, and the cache-hit-rate formula |
| "I'm choosing a model for a multi-turn chat" | [3.1 §10](references/01-context-window-and-kv-cache.md#10-️-the-model-selection-consequence-architectures-that-cannot-prefix-cache) | Linear-attention hybrids **cannot prefix-cache at all**. This outranks parameter count |
| "I want two personas in one conversation" | [3.2](references/02-dynamic-profiles-and-session-state.md) | `DynamicProfile`, `Profile`, `DynamicInstructions` — and the two spellings in circulation that do not compile |
| "My profile never switches" | [3.2 §2, §6](references/02-dynamic-profiles-and-session-state.md#2-the-framing-a-profile-is-a-projection-of-app-state) | The body is a projection; check what state you read versus what you mutate |
| "Where do I put state that a tool and a profile both need?" | [3.2 §11](references/02-dynamic-profiles-and-session-state.md#11-session-properties) | `@SessionPropertyEntry` on `SessionPropertyValues`, read via `@SessionProperty(\.…)` |
| "Should I use `history` or `historyTransform`?" | [3.2 §12](references/02-dynamic-profiles-and-session-state.md#12-history-versus-historytransform) | Lossy-and-global versus lossless-and-per-profile. The most consequential choice in the API |
| "I want Apple's ready-made trimming modifiers" | [3.3](references/03-skills-and-history-modifiers.md) | All three, line by line — including the one Apple ships with a test that says it crashes |
| "My summarisation modifier does nothing" | [3.3 §5–§6](references/03-skills-and-history-modifiers.md#5-️-every-composed-example-in-the-repository-is-inert) | Every composed example Apple ships is arithmetically inert |
| "I want to load domain knowledge just-in-time" | [3.3 §11–§17](references/03-skills-and-history-modifiers.md#11-skills-the-api-surface) | `Skills`, and the one line of source that decides whether your KV cache survives |
| "One model should hand off to another" | [3.4 §2](references/04-agentic-orchestration.md#2-baton-pass) | Baton-pass — and what Apple's shipping sample does instead |
| "I want a specialist opinion without polluting the conversation" | [3.4 §3](references/04-agentic-orchestration.md#3-phone-a-friend) | Phone-a-friend: a child session with an isolated transcript |
| "`respond(to:)` never returns" | [3.4 §6](references/04-agentic-orchestration.md#6-️-required-is-a-while-loop-and-you-supply-the-exit) | `.required` is an unbounded `while` loop. Apple documents exactly two exits |
| "The model wants to change the user's data" | [3.4 §7](references/04-agentic-orchestration.md#7-tool-as-consent-request-apples-origami-pattern) | Origami's propose/confirm pattern. The tool proposes; the app disposes |
| "Is a hop to PCC worth it?" | [3.4 §8](references/04-agentic-orchestration.md#8-model-routing-economics) | Routing economics, quota gates, and the backend constraint that kills `@Generable` |
| "How do I test that the handoff happened?" | [3.4 §10](references/04-agentic-orchestration.md#10-evaluating-agentic-behaviour) | Trajectory expectations — and why `disallowed` is the assertion people skip |

---

## The guides in this part

### [3.1 — Token budgeting, transcript anatomy, and KV-cache economics](references/01-context-window-and-kv-cache.md)

The conceptual spine: the six `Transcript.Entry` cases and what each costs, `contextSize` and
`tokenCount(for:)`, `Usage` and the cache-hit rate, overflow recovery in both the 26.0 and 27.0 idioms, and
then the KV material — token layout, the blast-radius table, the ordering rule for `DynamicInstructions`,
stateless shape-preserving transforms, and why you batch one big consolidation instead of trimming every
turn. It ends on the two findings most likely to change a decision you have already made: prefix reuse is
worth **23.28 s → 0.230 s (101×)** at 4k context (community-measured), and **hybrid / linear-attention
models forfeit it entirely** because a running scan cannot be rewound.

> ⚠️ **SILENT FAILURE — cache invalidation never throws.** There is no `LanguageModelError.cacheInvalidated`,
> no log line, no Instruments alarm. A `historyTransform` that reorders entries, a conditional above your
> static content, an instructions string interpolating the current time — each silently converts an O(1)
> turn into an O(N) turn and your tests still pass. Also here: hardcoding any context figure instead of
> reading `contextSize` bets your window budget on a constant Apple explicitly declines to guarantee, and
> a rebuild under Xcode 27 changes which `catch` clause fires.
>
> 🔴 **GAP** — the token cost of an image is unpublished (the "896 px" figure in circulation is a
> developer's inference); there is no `tokenCount` for PCC or for a custom `LanguageModel` — confirmed
> against the 27.0 beta interface on 2026-07-29: all five `tokenCount(for:)` overloads sit on
> `SystemLanguageModel` only (`FoundationModels-27.0-macos.swiftinterface:402-436`), and neither the
> `LanguageModel` protocol nor `PrivateCloudComputeLanguageModel` declares one. (TN3193 has since been
> read — 2026-07-27 — and settles the on-device figure at 4,096; see §3.3.)

### [3.2 — Dynamic Profiles, modifiers, and session state](references/02-dynamic-profiles-and-session-state.md)

The flagship 2026 API, built around the projection framing above. Three layers and their exact spellings,
`DynamicInstructions` composition (nesting concatenates instructions *and* tools), the full modifier
catalogue with the three-tier precedence rule, custom modifiers via `DynamicProfileModifier`, session
properties, `transcriptErrorHandlingPolicy`, and a complete worked three-persona feature. Two widely-circulated
spellings are corrected against Apple's shipping sample: it is `Profile { … }.model(x)`, never
`Profile(model:) { }`, and `var body: some DynamicProfile` — the short name — inside a conforming type.

> ⚠️ **SILENT FAILURE** — the `body` is **not** evaluated once per turn (a community count found 7
> evaluations across 3 turns), so a side effect in it runs an unpredictable number of times. Keep it pure.
> One more silent one: a tool named in your instructions prose but absent from the toolset produces an
> infinite loop with no thrown error — an entire WWDC session exists to teach you to find it. And one
> loud cousin worth listing beside them: assigning to `session.transcript` while `isResponding` is
> `true` is session misuse surfaced as the typed
> `LanguageModelSession.Error.transcriptMutationWhileResponding`; guard every write so the response
> task never reaches that failure.[^transcript-mutation-error]
>
> ✅ **Closed 2026-07-29 against the 27.0 beta interface** — the lifecycle closures are now read
> verbatim: each of `onPrompt`/`onResponse`/`onReasoning`/`onToolCall`/`onToolOutput` has a
> zero-argument **and** a payload-taking overload (`Transcript.Prompt`/`.Response`/`.Reasoning`/
> `.ToolCall`/`(ToolCall, ToolOutput)`), all `async throws`; `onActivate`/`onDeactivate` are
> zero-argument `async` non-throwing (`FoundationModels-27.0-macos.swiftinterface:984-1026`). And
> `Profile` has exactly **one** initializer — the `@DynamicInstructionsBuilder` closure form
> (`:838-839`); **no `Profile(model:)` overload exists in the 27.0 beta interface** — the guide's
> `.model(_:)` correction stands. 🔴 Still open: what `Transcript.Response.assetIDs` *means*, and
> the runtime semantics of writing `session.properties` from outside (the setters exist:
> `:1103-1107`).

### [3.3 — `foundation-models-utilities`: Skills and history transforms](references/03-skills-and-history-modifiers.md)

An audit of Apple's separately-versioned experimental package — two commits, issues disabled, no CI — and
the two feature areas that change how you think about a transcript. All three history modifiers line by
line; the outside-in execution order; and **Skills**, which is the clearest worked example of KV-cache
economics in the corpus: one line of source decides whether a skill's body lands in the tool output (cache
preserved) or in the instructions entry (cache destroyed). Read §8 even if you never adopt the package — it
establishes that all three shipped modifiers write the **lossy, session-wide** `history` property rather
than the per-profile `historyTransform` that Apple's own session tells you to prefer.

> ⚠️ **SILENT FAILURE (four, all shipped).** The README's `from: "1.0.0"` dependency line resolves to
> nothing, and fails like a network error. **Every composed example in the repository is inert** —
> `entryThreshold` is never strictly less than the rolling-window size, so summarisation can never fire.
> `summarizeHistory` is a no-op whenever the trailing entry is not a `.prompt`, which in a tool-heavy
> session is most of the time. And `rollingWindow(entries:)` ships with a test whose own comment reads
> *"this documents the (buggy) naive outcome; in practice it crashes partway through."*
>
> 🔴 **GAP** — the bundled `skills/foundation-models-utilities/SKILL.md` is a **stale beta-1 document with
> eight verified wrong claims**, including a SwiftPM trait system that does not exist. If you run coding
> agents against this repository, that file is generating broken code today.

### [3.4 — Baton-pass, phone-a-friend, model routing, and tool-calling control](references/04-agentic-orchestration.md)

Apple named two orchestration patterns — collaboration versus consultation — and then shipped a sample that
uses neither literally, so this guide separates the verified narration from the reconstructed code and says
which is which at every listing. Then the four things you actually have to decide: tool-calling mode as a
control surface, the `.required` loop and its two exits, human-in-the-loop consent (reproduced in full from
Origami, because it appears in no WWDC session), and routing economics — PCC quota gates, what a model
switch costs, and the constraint that **grammar-constrained decoding needs engine logits**, so a BYO app on
the fastest backend loses `@Generable` entirely.

> ⚠️ **SILENT FAILURE — `.required` is an unbounded `while` loop with no iteration cap.** `respond(to:)`
> does not return, and **if your tool has side effects it performs them over and over** — that is a
> data-corruption bug with a spinner on top. Wire both documented exits. Three more live here: a call-site
> `options:` silently overrides your profile's loop exit; a failed consultation returned as plausible prose
> becomes fact the parent reasons from; and an unanswered consent proposal leaves every later turn generated
> against "a confirmation is pending."
>
> 🔴 **GAP** — **there is no first-party call site for `toolCallingMode` anywhere.** No Apple sample sets
> it (the API itself is SDK-verified: one `GenerationOptions.ToolCallingMode` type shared by the
> options field and the profile modifier, `FoundationModels-27.0-macos.swiftinterface:978,
> :3229-3249`). `.required` with an empty toolset produces `LanguageModelError error -1` wrapping an
> internal `GuidedGenerationError` (FB23643759, still open) and no documented case. Nobody has
> published a cost comparison between the two patterns, so there is no crossover point to give you.

---

## Reading order

**Everyone reads [3.1](references/01-context-window-and-kv-cache.md) first, and most people can stop after
§8.** The other three guides are applications of its two ideas; without them, the rules in 3.2 and 3.3 read
as arbitrary style advice. §§9–10 (the measured prefix-reuse numbers, the architectures that cannot cache)
are for people choosing a backend and can be deferred until you are choosing one.

**Then [3.2](references/02-dynamic-profiles-and-session-state.md) if you are on 27.0.** It is the API
reference for this whole part and everything after it assumes you can write a profile and read a session
property. If your deployment target is 26.x, skip it entirely — none of it exists for you, and 3.1 §6 has
the catch-condense-rebuild pattern that does.

**Then pick by problem.** [3.4](references/04-agentic-orchestration.md) if you have more than one model or a
tool loop; §6 is worth reading on its own the moment anyone types `.required`.
[3.3](references/03-skills-and-history-modifiers.md) only if you are adopting the utilities package or want
just-in-time knowledge loading — and read §5 and §7 before you paste anything from Apple's README.

**Defer or skip:**
- **[3.3 §19](references/03-skills-and-history-modifiers.md#19-chatcompletionslanguagemodel-briefly)** (`ChatCompletionsLanguageModel`) is a pointer;
  the real treatment is [Part 4](../part-04-beyond-the-built-in-model/README.md).
- **[3.4 §10](references/04-agentic-orchestration.md#10-evaluating-agentic-behaviour)** (trajectory evaluation) is a preview of
  [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md). Read it when you have something worth regression-testing — but read it
  *before* you ship, because none of this part's techniques is assertable with `#expect`.
- **[3.1 §9](references/01-context-window-and-kv-cache.md#9-what-prefix-reuse-is-worth-measured)** is provider-internals; skip unless you are
  writing a `LanguageModelExecutor`.

---

## What this part deliberately does not cover

- **The everyday session API** — initializers, `respond`/`streamResponse`, `@Generable`, `@Guide`, the
  `Tool` protocol member by member, `Attachment`, and the complete error taxonomy:
  [Part 2](../part-02-foundation-models-everyday-api/README.md). This part is the *strategy* layer above it.
- **Choosing a backend.** PCC eligibility, entitlement and quota in full, `CoreAILanguageModel`,
  `MLXLanguageModel`, `ChatCompletionsLanguageModel`, and authoring your own provider (including the
  executor-side KV-reuse contract that 3.1 §9 only samples):
  [Part 4](../part-04-beyond-the-built-in-model/README.md).
- **The Foundation Models Instrument end to end** — lanes, the tree view, the Instructions-lane read that
  diagnoses a failed handoff in five seconds — plus `#Playground` and the `fm` CLI:
  [Part 5](../part-05-prototyping-profiling-non-swift/README.md).
- **Measuring whether any of this worked.** Every technique here changes what the model sees and none
  changes it in a way you can assert on. Apple's own instruction is to quantify context-engineering with
  eval sets: [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md).
- **Device eligibility, entitlements and the Simulator trap** in full:
  [Part 1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/README.md).
- **Migrating a 26.x app**, including the `GenerationError` → `LanguageModelError` mapping that changes
  which `catch` fires on rebuild: [Part 17](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/README.md).

---

## Sources for this part

Apple sample code, read on disk and treated as the top evidence class because it compiles and ships:
**Origami — *Crafting a dynamic tutorial for Apple Intelligence*** (61 Swift files, deployment target 27.0),
which is the authority for the `DynamicProfile` shape, `Profile { }.model(_:)`, `historyTransform`'s
`([Transcript.Entry]) -> [Transcript.Entry]` signature, `LanguageModelSession(profile:history:)`, seeded
transcripts, the error ladder and the entire consent pattern in 3.4 §7; and **Book Tracker** for the
trajectory-expectation API. Apple open source read at commit `376ca60`: `apple/foundation-models-utilities`
(every modifier, every test, both bundled `SKILL.md` files) and `apple/python-apple-fm-sdk` (the five
`tokenCount` bridges and the availability asymmetry); plus `ml-explore/mlx-swift-lm`'s compiled
`DynamicProfile` and tool-calling-mode tests. Apple documentation harvested 2026-07-27, principally
*Composing dynamic sessions with instructions and profiles*, *Optimizing key-value caching in language model
sessions*, *Managing the context window*, and *Using Private Cloud Compute*. WWDC26 sessions **241, 242,
243, 246, 299, 319, 334** and Meet-with-Apple **205** — all spoken transcripts, which is why narrated code
appears as 🟡 RECONSTRUCTED wherever sample code does not override it. Apple Developer Forums threads with
staff answers: **833642** (4K, no version pinning), **835927** (the 26→27 context-management migration),
**833626** (profile switching and context reconciliation), **833706** (`summarizeHistory` condenses
everything), **833692** (`.toolCallingMode` for strict RAG), **837226** ("Tool Choice requires tools"),
**835974** (coarse PCC quota), **790736** and **817502** (the 26-era overflow idiom). Community sources —
`john-rocky/coreai-model-zoo`, `john-rocky/coreai-models` and the frozen Noema 3.5 snapshot — supply the
prefix-reuse and model-switch measurements, the body-re-evaluation count and a retired 8192 `contextSize` comment,
and are attributed as community-measured at every point of use, never as Apple figures. WWDC26 session
**347** is *not* in the corpus; every claim traced to it is marked secondary and unverified.

[^transcript-mutation-error]: Apple, [`LanguageModelSession.Error.transcriptMutationWhileResponding`](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/error/transcriptmutationwhileresponding), “The session’s transcript was mutated while a request was in progress.”
