# `foundation-models-utilities`: Skills and history transforms

**Part 3 · Context, profiles, agentic sessions · Reference 03**

**Version floor: 27.0 everywhere, and there is no lower rung.** `apple/foundation-models-utilities`
declares `.macOS("27.0")`, `.iOS("27.0")`, `.visionOS("27.0")`, `.watchOS("27.0")` — and **no tvOS
entry at all** (✅ `Package.swift:19-22`). It is built with **swift-tools-version 6.2** and enforces
`swiftLanguageModes: [.v6]` package-wide (✅ `Package.swift:13`, `:63`), so it will not build from an
Xcode 26 toolchain. The framework APIs it extends — `LanguageModelSession.DynamicProfile`,
`LanguageModelSession.DynamicProfileModifier`, `@SessionProperty(\.history)`, `DynamicInstructions`,
`.onPrompt { }` — are all **27.0-only**. The one thing in this guide with a lower floor is the `Tool`
protocol itself (iOS/macOS/visionOS **26.0**, watchOS **27.0**), and the package uses it only as an
implementation detail. Nothing described here can be back-deployed to 26.0, 26.1, 26.3 or 26.4.

---

> **⚠️ Read this before you `import FoundationModelsUtilities`**
>
> This package is not a library in the sense you are used to. As of the snapshot this guide is
> written against — commit `376ca60`, tag `1.0.0-beta3`, pushed 2026-07-10 — it has:
>
> - **two commits, total** (✅ `git log --oneline -50`);
> - **two tags, both prereleases**: `1.0.0-beta1` → `a047a50`, `1.0.0-beta3` → `376ca60`. There is no
>   `beta2` and no stable tag (✅ `git ls-remote --tags`);
> - **zero GitHub releases** (✅ `gh release list`, empty);
> - **GitHub issues disabled** — `gh issue list` returns *"the 'apple/foundation-models-utilities'
>   repository has disabled issues"*;
> - **zero pull requests in any state** (✅ `gh pr list --state all --limit 50`, empty), and a
>   `CONTRIBUTING.md` that says *"This project is not currently accepting PRs."*;
> - **no CI of any kind** — no `.github/`, no `Dockerfile`, no build matrix (✅ `find . -not -path
>   "./.git/*"`).
>
> Apple's own framing, from the repository description, is *"Emerging and experimental patterns for
> building with the Foundation Models framework"*, and session 242 says it *"will be updated in
> between OS releases"* and gives you *"emerging or experimental patterns"* (✅ 242:12–14). Take that
> literally. §1 covers what that means for your `Package.swift`, and §5 covers the four shipped
> examples that cannot work.

---

## What this covers

The two feature areas of `apple/foundation-models-utilities` that change how you think about a
transcript — and the exact ways the shipped documentation for both is wrong.

- **How to actually depend on the package.** The README's dependency line resolves to nothing. §1.
- **The three history modifiers**, with their complete signatures, every parameter, every default,
  and every default that Apple's own agent skill claims exists but does not:
  `droppingCompletedToolCalls()`, `rollingWindow(entries:)` / `rollingWindow(size:)`, and
  `summarizeHistory(entryThreshold:model:instructions:summaryPostamble:)`.
- **Application order**, resolved precisely: modifiers wrap inside-out and *execute* outside-in, so
  the last modifier you write is the first one that runs.
- ⚠️ **The inert-composition trap.** Every composed example shipped in the repository — four call
  sites — pairs an `entryThreshold` with a `rollingWindow` size that makes summarisation
  mathematically unreachable. Nothing throws. Nothing warns.
- ⚠️ **The "5000 tokens" ghost.** The README says summarisation triggers on a token count. The API
  has no token awareness anywhere; the gate is `history.count > entryThreshold`, an entry count.
- ⚠️ **`rollingWindow` is a known-buggy modifier that Apple shipped anyway**, with a test whose own
  comment says *"in practice it crashes partway through."*
- **What these modifiers actually mutate** — and why that is the *lossy, session-wide*
  `@SessionProperty(\.history)` path rather than the lossless per-profile `historyTransform(_:)` that
  session 242 tells you to prefer. This is the most consequential thing in the guide and nobody says
  it out loud.
- **Skills** — the best worked example of KV-cache economics in the entire corpus. Why a prompt-based
  skill preserves the key/value cache and an instructions-based skill destroys it, established from
  the one line of source that decides it, plus the three transcript diagrams from Apple's README.
- The synthesized `ToggleSkillTool`: the `activate_skill` / `toggle_skill` naming rule, the three
  rendering states (including `[on demand]`, which is not documented as a state anywhere else),
  `strictSchema`, and the `defer` that makes the tool's own verb read backwards.
- ⚠️ **`SkillActivations` stopped conforming to `RandomAccessCollection` at beta 3**, and both the
  README and Apple's own agent skill still ship a `ForEach` snippet that no longer compiles.
- **`ChatCompletionsLanguageModel`** in brief, with a pointer to Part 4 for the full treatment.
- The `skills/foundation-models-utilities/SKILL.md` audit: a beta-1 document with **eight** verified
  wrong claims, including a SwiftPM trait system that does not exist.

## What you need

- **Xcode 27** and a 27.0 SDK. There is no 26.x path.
- A `FoundationModels` module providing the `LanguageModel` protocol — that is the 27.0 framework.
- Familiarity with `LanguageModelSession.DynamicProfile`, `Profile`, `DynamicInstructions` and the
  transcript's six entry cases. If those are new, read Part 3's profiles guide first, and
  [`../../part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md`](../../part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md)
  for the `Tool` protocol — Skills is built entirely out of one synthesized `Tool`.
- **An expectation-setting note about evidence.** Every source claim in this guide is grounded in a
  read of the repository at commit `376ca60`. **The package could not be compiled and its tests could
  not be run** during that pass — the toolchain available was Swift 6.3.3 targeting
  `arm64-apple-macosx26.0`, and the package requires macOS 27.0. So "✅ VERIFIED" here means *read in
  the shipping source, with file and line*, and behavioural claims are corroborated by Apple's own
  test assertions rather than by execution. The one exception is §19's URL-versioning table, whose
  logic was extracted and executed in isolation against Swift 6.3.3 Foundation.

---

## Contents

1. [The package, honestly: how to depend on something with two commits](#1-the-package-honestly-how-to-depend-on-something-with-two-commits)
2. [The nine public symbols](#2-the-nine-public-symbols)
3. [The three history modifiers, signature by signature](#3-the-three-history-modifiers-signature-by-signature)
4. [Application order: written inside-out, executed outside-in](#4-application-order-written-inside-out-executed-outside-in)
5. [⚠️ Every composed example in the repository is inert](#5-️-every-composed-example-in-the-repository-is-inert)
6. [⚠️ The "5000 tokens" ghost](#6-️-the-5000-tokens-ghost)
7. [⚠️ `rollingWindow` splits prompt/response pairs — and Apple knows](#7-️-rollingwindow-splits-promptresponse-pairs--and-apple-knows)
8. [What these modifiers actually mutate — and why it matters](#8-what-these-modifiers-actually-mutate--and-why-it-matters)
9. [Writing your own history modifier](#9-writing-your-own-history-modifier)
10. [What the summarizer actually reads: `TranscriptRendering`](#10-what-the-summarizer-actually-reads-transcriptrendering)
11. [Skills: the API surface](#11-skills-the-api-surface)
12. [The mechanism: one line of source decides the KV cache](#12-the-mechanism-one-line-of-source-decides-the-kv-cache)
13. [The three transcript shapes](#13-the-three-transcript-shapes)
14. [The synthesized tool: naming, schema, descriptions, and an inverted verb](#14-the-synthesized-tool-naming-schema-descriptions-and-an-inverted-verb)
15. [⚠️ `SkillActivations` and the `ForEach` that stopped compiling](#15-️-skillactivations-and-the-foreach-that-stopped-compiling)
16. [Skills that carry tools](#16-skills-that-carry-tools)
17. [Choosing: prompt skill, instructions skill, or neither](#17-choosing-prompt-skill-instructions-skill-or-neither)
18. [A complete worked example](#18-a-complete-worked-example)
19. [`ChatCompletionsLanguageModel`, briefly](#19-chatcompletionslanguagemodel-briefly)
20. [The `SKILL.md` audit: eight wrong claims](#20-the-skillmd-audit-eight-wrong-claims)
21. [Quick reference](#21-quick-reference)
22. [Sources](#22-sources)

---

## 1. The package, honestly: how to depend on something with two commits

Session 242 announced this package as part of the framework story, not as a curiosity:

> ✅ **VERIFIED** — WWDC26 session 242 (`242:12–14`): *"we're announcing a new package; **Foundation
> Models framework utilities**. Utilities is an **open source Swift package** that houses components
> helpful for building agentic experiences. It will be **updated in between OS releases** and give
> you access to **emerging or experimental patterns**, all **backed by dynamic profiles**."*
>
> And session 241 (`241:130`): *"It provides **profile modifiers for transcript management**, a
> **skill API for procedural knowledge loading**, and a **language model that can interface with
> servers using the Chat Completions standard**."*

Three feature areas, exactly as shipped. What the sessions do not tell you is the maturity. The whole
package is **two commits by one Apple engineer**, with seven Apple co-authors on the first:

```
376ca60  Updates to accompany Xcode 27 beta 3     Erik Hornberger <erik_h@apple.com>  2026-07-10
a047a50  Hello foundation-models-utilities        Erik Hornberger <erik_h@apple.com>  2026-06-07
```

✅ VERIFIED, `git log --oneline -50`. Co-authors on `a047a50`, all `@apple.com`: `oliveroneill`,
`mkery`, `erik-apple`, `matthewfernst`, `rxwei`, `li3zhen1`, `louisdh`, `egourlao`. (`rxwei` is
Richard Wei, of Swift-for-TensorFlow and Swift compiler fame — a useful signal that this is real Apple
engineering effort and not a docs sample.)

### 1.1 The dependency line in the README does not work

> ⚠️ **SILENT FAILURE — the documented dependency declaration resolves to nothing.**
>
> ✅ **VERIFIED** — `README.md:30` instructs consumers to write:
>
> ```swift
> .package(url: "https://github.com/apple/foundation-models-utilities", from: "1.0.0")
> ```
>
> The only tags that exist are `1.0.0-beta1` and `1.0.0-beta3` (✅ `git ls-remote --tags`). SwiftPM's
> `from:` requirement **excludes prereleases**, so there is no version in the allowed range. You do
> not get a helpful "this package has no stable release" diagnostic; you get a resolution failure
> that reads like a network or authentication problem, and developers reach for `--skip-update`,
> proxy settings and keychain fixes before they think to run `git ls-remote --tags`.

Depend on it one of these three ways instead:

```swift illustrative
// Package.swift — pick ONE.

// (a) RECOMMENDED. Pin the exact prerelease you tested against.
.package(
    url: "https://github.com/apple/foundation-models-utilities",
    exact: "1.0.0-beta3"
),

// (b) Pin the commit. Identical bytes to (a) today; immune to a tag being moved.
.package(
    url: "https://github.com/apple/foundation-models-utilities",
    revision: "376ca60"          // tag 1.0.0-beta3, 2026-07-10
),

// (c) Track main. Only if you are prepared for an API break with no release notes.
.package(
    url: "https://github.com/apple/foundation-models-utilities",
    branch: "main"
),
```

and then, in your target:

```swift prelude:guide-context
.product(name: "FoundationModelsUtilities", package: "foundation-models-utilities")
```

✅ The product name is `FoundationModelsUtilities`, a single library over a single target
(`Package.swift:94-97`). The target declares **zero dependencies** (`Package.swift:33`) —
`FoundationModels` is a system framework and needs no SwiftPM declaration; you just
`import FoundationModels`.

**Why (a) over (c):** the two commits that exist already broke source compatibility in three places —
`SkillActivations` lost a protocol conformance, `LanguageModelCapabilities` changed its initializer
label, and the default toggle-tool description text changed (all in `376ca60`). With issues disabled
and no releases, a `branch: "main"` dependency is a silent-breakage generator. Pin, and re-pin
deliberately.

**Why beta 3 and not beta 1:** beta 1 targets the Xcode 27 beta 1 framework API. `376ca60`'s commit
message is a release-note-grade changelog of framework changes between beta 1 and beta 3 — the
`SamplingMode` case renames (`.top` → `.randomTopK`, `.nucleus` → `.randomProbabilityThreshold`),
`GenerationSchema.name` replacing a JSON-title hack, `.model(any LanguageModel)` graduating into the
framework itself. Beta-1 code will not compile against a current SDK.

### 1.2 Where to report a bug

You cannot file one on GitHub. `README.md:12` and `CONTRIBUTING.md` both route you elsewhere:

- **Apple Developer Forums**, Machine Learning & AI → Foundation Models topic (the URL is in
  `README.md:12`);
- **Feedback Assistant** for framework-level defects.

✅ `CONTRIBUTING.md` also asks, in its repro checklist, that you *"Run
`session.logFeedbackAttachment` and serialize to a JSON file."*

> ✅ **RESOLVED (2026-07-29) — `session.logFeedbackAttachment` is a real `LanguageModelSession`
> method family, read from the 27.0 interface.** Three overloads, all synchronous (not `async`),
> all `@discardableResult`, all returning **`Data`** (the JSON to attach to a Feedback report) —
> ✅ **SDK-verified** (`FoundationModels-27.0-macos.swiftinterface:3472-3514`):
>
> ```swift
> func logFeedbackAttachment(sentiment: LanguageModelFeedback.Sentiment?,
>                            issues: [LanguageModelFeedback.Issue] = [],
>                            desiredOutput: Transcript.Entry? = nil) -> Data
> // plus two conveniences, @backDeployed(before: iOS 26.1, macOS 26.1, visionOS 26.1):
> func logFeedbackAttachment(sentiment:issues:desiredResponseText: String?) -> Data
> func logFeedbackAttachment(sentiment:issues:desiredResponseContent:
>                            (any ConvertibleToGeneratedContent)?) -> Data
> ```
>
> Floor: the extension is `@available(iOS 26.0, macOS 26.0, visionOS 26.0, watchOS 27.0)`, so it is
> a 26-era API, not 27-only — `CONTRIBUTING.md` was citing a real symbol all along. Attaching
> `try JSONEncoder().encode(session.transcript)` remains a fine *additional* artifact, but the
> feedback attachment is the one Apple's tooling expects.

### 1.3 What "experimental" means here, concretely

Three things in this package are shipped-and-known-broken rather than merely young. Each gets its own
section, but here they are together so you can decide before you adopt:

| | What | Where |
|---|---|---|
| 1 | `rollingWindow` cuts between a prompt and its response. Apple's own test comment: *"in practice it crashes partway through."* | §7 |
| 2 | All four composed history examples shipped in the repo are arithmetically inert — summarisation can never fire. | §5 |
| 3 | The README and Apple's agent skill both document `SkillActivations` as a collection. It stopped being one at beta 3; the shipped `ForEach` snippet no longer compiles. | §15 |

None of the three throws, warns, or logs.

---

## 2. The nine public symbols

The package's own DocC landing page is the only piece of its documentation that is fully accurate at
`HEAD`, and it doubles as a complete public-API index.

> ✅ **VERIFIED** — `Sources/FoundationModelsUtilities/Documentation.docc/Documentation.md`, verbatim:
>
> ```
> ### Language Models
> - ``ChatCompletionsLanguageModel``
>
> ### Skills
> - ``Skill``
> - ``Skills``
> - ``SkillActivations``
> - ``SkillsBuilder``
>
> ### Context Management
> - ``FoundationModels/LanguageModelSession/DynamicProfile/summarizeHistory(entryThreshold:model:instructions:summaryPostamble:)``
> - ``FoundationModels/LanguageModelSession/DynamicProfile/rollingWindow(entries:)``
> - ``FoundationModels/LanguageModelSession/DynamicProfile/rollingWindow(size:)``
> - ``FoundationModels/LanguageModelSession/DynamicProfile/droppingCompletedToolCalls()``
> - ``RollingWindowSize``
> ```

**Nine symbols. That is the entire public surface.** Four of them are `DynamicProfile` extension
methods that live under `FoundationModels/…` in the DocC hierarchy because they are extensions on a
framework type, not new types of their own. Note also what is *absent*: `TranscriptRendering`'s
`chatLog()` / `chatText` / `textContent` are internal (§10), and every member of `Skill` except its
initializers is internal (§11.1).

The DocC page also carries the package's thesis statement, which is worth having in front of you for
§12:

> ✅ **VERIFIED** — `Documentation.docc/Documentation.md`: *"**Skills.** `Skills` and `Skill` teach a
> session about specialized tasks just-in-time. The model activates a skill by issuing a tool call,
> and the corresponding prompt or instructions content is added to the transcript only when needed —
> keeping the upfront context small and **protecting the key-value cache**."*

Two claims in one sentence, and they are separable. "Keeping the upfront context small" is true of
both skill flavours. "Protecting the key-value cache" is true of **exactly one** of them. §12 is
about which.

---

## 3. The three history modifiers, signature by signature

All three are extensions on `LanguageModelSession.DynamicProfile`. Here they are exactly as declared,
with every parameter and every default:

> ✅ **VERIFIED** — read from the shipping source at `376ca60`:
>
> ```swift
> // DropCompletedToolCalls.swift:38
> extension LanguageModelSession.DynamicProfile {
>     public func droppingCompletedToolCalls() -> some DynamicProfile
> }
>
> // RollingWindow.swift:36
> extension LanguageModelSession.DynamicProfile {
>     public func rollingWindow(entries: Int) -> some DynamicProfile
> }
>
> // RollingWindow.swift:64
> extension LanguageModelSession.DynamicProfile {
>     public func rollingWindow(size: RollingWindowSize) -> some DynamicProfile
> }
>
> // SummarizeHistory.swift:53
> extension LanguageModelSession.DynamicProfile {
>     public func summarizeHistory<Model: LanguageModel>(
>         entryThreshold: Int,                 // no default
>         model: Model,                        // NO DEFAULT — see below
>         instructions: Instructions? = nil,
>         summaryPostamble: String? = nil
>     ) -> some DynamicProfile
> }
>
> // RollingWindow.swift:86
> public enum RollingWindowSize: Sendable {
>     case entries(Int)                        // the only case
> }
> ```

Four observations before the semantics.

**`droppingCompletedToolCalls()` takes no parameters at all.** Not an "aggressiveness" knob, not a
count, nothing. Its behaviour is fixed. If you want different eviction semantics you write your own
modifier — §9.

**`rollingWindow(entries:)` is sugar.** It delegates straight to
`rollingWindow(size: .entries(entries))` (✅ `RollingWindow.swift:37`). Both spellings exist and both
are in the DocC index, so neither is deprecated.

**`RollingWindowSize` has exactly one case.** A one-case enum wrapped in a dedicated public type is
not an accident; it is a seam. The obvious future case is `.tokens(Int)`, which is also what §6's
stale README prose was written for. Today, `.entries(Int)` is all there is, and code that
`switch`es over it needs no `default`.

> ⚠️ **`summarizeHistory` has NO default for `model:`.** Apple's own agent skill claims otherwise —
> `skills/foundation-models-utilities/SKILL.md:234` writes `model: Model = SystemLanguageModel()`.
> The shipping source has no default (✅ `SummarizeHistory.swift:55`), and a generic parameter cannot
> take a default value that would fix `Model` anyway; the compiler would have nothing to infer from.
> You must pass a model. See §20 for the seven other things that document gets wrong.

### 3.1 `droppingCompletedToolCalls()` — evict everything but the live exchange

```swift prelude:guide-context
// DropCompletedToolCalls.swift, inside the modifier's onPrompt hook — ✅ VERIFIED, verbatim
content.onPrompt {
    let lastOutputIndex =
        history.lastIndex(where: { entry in                     // :51
            if case .response  = entry { return true }
            if case .toolCalls = entry { return true }
            return false
        }) ?? history.startIndex                                // :55

    let prefix = history.prefix(upTo: lastOutputIndex).filter { entry in   // :57
        if case .toolCalls  = entry { return false }
        if case .toolOutput = entry { return false }
        return true
    }

    let suffix = history.suffix(from: lastOutputIndex)          // :63

    history = prefix + suffix                                   // :65
}
```

Read that as three steps:

1. Find the index of the **last** `.response` **or** `.toolCalls` entry — the boundary of the
   in-flight exchange.
2. From everything *before* that boundary, delete every `.toolCalls` and `.toolOutput` entry.
3. Keep everything from the boundary onward byte-for-byte.

So **the most recent tool exchange survives; all earlier ones are evicted.** `.instructions`,
`.prompt` and `.response` entries are never touched at any position. `.reasoning` entries are not
touched either — they are not in the filter's deny list.

The two shipped tests pin exactly this:

> ✅ **VERIFIED** — `DroppingCompletedToolCallsTests.swift:30-46` — after **one** turn the transcript
> is `[.instructions, .prompt("first"), .toolCall("activate_skill"), .toolOutput("echoed"),
> .response("OK")]` and **nothing is dropped** (the test's own word for it is that the exchange is
> still *"incomplete"*).
>
> `:48-68` — after **two** turns the transcript is `[.instructions, .prompt("first"), .response("OK"),
> .prompt("second"), .toolCall(…), .toolOutput(…), .response("OK")]`. The **first** turn's tool pair
> is gone; the second's survives.

Note the shape of the win. A tool exchange is two entries plus the arguments JSON plus whatever the
tool returned — and tool outputs are frequently the largest entries in a transcript, because they
carry search results, file contents, or (in the case of a prompt skill, §12) an entire body of
guidance. Evicting completed ones is the cheapest compression available and it is *semantically*
safe in a way that truncation is not: the model's own `.response` entry, which is retained, already
summarises whatever the tool told it.

This is the modifier session 242 was gesturing at:

> ✅ **VERIFIED** — 242:73: *"**Dropping tool calls is one easy way to trim history.**"*

### 3.2 `rollingWindow(entries:)` — `suffix(n)`, and nothing more

```swift prelude:guide-context
// RollingWindow.swift — ✅ VERIFIED, verbatim
content.onPrompt {
    switch size {
    case .entries(let numberOfEntries):
        history = history.suffix(numberOfEntries)               // :79
    }
}
```

That is the whole implementation. It is a naive `suffix(n)` over the entry array with no awareness of
what an entry *is* — no pairing of a prompt with its response, no protection for the instructions
entry, no handling of a `.toolCalls` entry orphaned from its `.toolOutput`. §7 is entirely about what
that costs you.

### 3.3 `summarizeHistory(...)` — the nuclear option

This one is qualitatively different from the other two: it makes a **model call** inside your
profile's `onPrompt` hook, and it **collapses the entire history to a single entry**.

```swift prelude:guide-context
// SummarizeHistory.swift — ✅ VERIFIED, structure and line numbers as read
content.onPrompt {
    guard history.count > entryThreshold else { return }        // :99   ← strictly greater
    guard case .prompt(let prompt) = history.last else { return } // :103 ← trailing entry must be a prompt

    let session = LanguageModelSession(
        model: model,
        instructions: { instructions ?? Instructions { /* default summarizer prompt */ } }  // :107-132
    )

    let textRepresentation = history.chatLog()                  // :134  ← see §10

    let summary = try await session.respond(
        to: Prompt { "Summarize this conversation:\n\n\(textRepresentation)" }   // :136-140
    ).content

    let postamble = summaryPostamble ?? Self.defaultSummaryPostamble             // :142
    var summaryContent = """
        Summary of the conversation so far:
        \(summary)
        """
    if !postamble.isEmpty { summaryContent += "\n\n\(postamble)" }               // :147-149
    summaryContent += "\n\n"                                                     // :150
    let summarySegment = Transcript.TextSegment(content: summaryContent)

    history = [                                                                  // :153
        .prompt(
            Transcript.Prompt(
                id: UUID().uuidString,
                segments: [.text(summarySegment)] + prompt.segments,             // :158
                options: prompt.options,
                responseFormat: prompt.responseFormat
            )
        )
    ]
}
```

Six things to internalise here, because five of them will surprise you.

**(1) The gate is an entry count, strictly greater.** `history.count > entryThreshold`. There is no
token counting in this file, or anywhere in the package — `grep -rn "5000" Sources/ Tests/` returns
zero hits. §6 traces where the README's token language came from.

**(2) The trailing entry must be a `.prompt`, or the whole thing is a no-op.**

> ⚠️ **SILENT FAILURE — summarisation skips itself on tool-output continuations and tells you
> nothing.** The `onPrompt` hook fires on every generation, including the continuation after a tool
> returns. On those iterations `history.last` is a `.toolOutput`, the second `guard` fails, and the
> modifier returns without summarising, without logging, and without any observable difference from
> a successful run.
>
> ✅ **VERIFIED** — Apple's test `only summarizes on prompts, not on tool-output continuations`
> (`SummarizeHistoryTests.swift:155-189`), comment verbatim (`:178-184`): *"The single respond
> produces: prompt -> tool call -> tool output -> response. By the time summarization's hook runs on
> the tool-output continuation, the history count (3) already exceeds the threshold (2), but the most
> recent entry is a tool output rather than a prompt. Because summarization only acts when the last
> entry is a prompt, it is skipped."*
>
> **Consequence for agentic apps:** in a session where most generations are tool-loop iterations
> rather than fresh user prompts, the threshold you configured is not the threshold you get.
> A `.required` tool-calling loop (see Part 2's tool guide §7) can run many inferences per user
> turn, and summarisation will fire on at most one of them. Budget for the transcript growing to
> `entryThreshold + (entries added during the longest tool loop)` before anything compresses.
>
> Apple's own skill document states the rule correctly, and it is one of the places that document is
> right: *"`summarizeHistory` requires the trailing entry to be `.prompt`. It is a no-op for any
> other trailing entry kind."* (✅ `skills/foundation-models-utilities/SKILL.md`, pitfalls list.)

**(3) The result is one entry. Not "the old entries plus a summary" — one entry.** The assignment at
`:153` replaces the entire history array with a single `.prompt`. Everything else — the instructions
entry, every prior prompt and response, every tool exchange — is gone from `history`.

**(4) The summary is prepended into the *user prompt*, not injected as instructions.** The new
prompt's segments are `[summary text] + prompt.segments`. From the model's point of view the user
opened their message with a paragraph of third-person recap and then asked their question. That is
why the default postamble exists at all (see (6)).

**(5) `options` and `responseFormat` are carried over** from the prompt that survived (`:159-160`), so
a guided-generation request is not silently downgraded to freeform when summarisation fires mid-flow.

**(6) There are two prose defaults, and both are test-pinned.** The default summariser instructions:

> ✅ **VERIFIED** — `SummarizeHistory.swift:112-129`, verbatim:
>
> ```
> Compress this conversation between an assistant and a user into a concise summary that preserves:
> 1. Established facts — names, numbers, dates, decisions, preferences.
> 2. The current topic and what stage the conversation is at.
> 3. The thread most recently raised by the user — often the immediate context for what comes next.
> 4. Any open questions or unresolved items.
>
> Use compact third-person statements (for example: "User's dog is named Pepper, a border collie." or
> "User is choosing between two apartments and has just decided office space is the deciding
> factor."). Do not narrate the conversation with phrases like "the user said" or "they discussed".
> Compress aggressively but do not drop the active conversational thread.
> ```

and the default postamble, which is appended to the summary text inside the reconstructed prompt:

> ✅ **VERIFIED** — `SummarizeHistory.swift:76-83`, verbatim:
>
> ```
> Do not begin with phrases like "Based on the context", "Based on the facts", "Based on the
> summary", or any reference to a summary or the facts provided. Treat the summary and facts above as
> things you naturally remember.
> ```

Both are excellent starting points and both are overridable. `instructions:` replaces the summariser's
system prompt; `summaryPostamble:` replaces the postamble. Passing `summaryPostamble: ""` suppresses
the postamble **and** its blank-line separator — pinned by
`SummarizeHistoryTests.swift:99-129`. The default postamble is pinned at `:48-61`, a custom one at
`:64-97`.

### 3.4 The model you pass matters more than it looks

`summarizeHistory` builds a **whole second `LanguageModelSession`** and runs a full generation inside
your prompt hook. That is a synchronous-feeling cost on the user's turn: they hit send, and before
their prompt reaches the primary model, a summariser has to read the entire conversation and write a
paragraph.

Session 242 makes the corresponding architectural point about *which* model to hand it:

> ✅ **VERIFIED** — 242:56, describing the craft app's reviewing profile: *"**To save on unnecessary
> server calls**, this makes use of `SystemLanguageModel`."*

The same logic applies with more force here. Summarisation is a bounded, mechanical transformation
with a rigid output contract — exactly the workload the on-device model is good at, and exactly the
workload you do not want to spend a Private Cloud Compute round trip or a per-user quota unit on.
Pass `SystemLanguageModel()` unless you have measured that it is not good enough:

```swift prelude:guide-context
.summarizeHistory(entryThreshold: 8, model: SystemLanguageModel())
```

> ✅ **VERIFIED** — `SystemLanguageModel()`, the bare initializer, is 2026 house style; Apple's
> Origami sample writes `var serverModel = SystemLanguageModel()` and never writes
> `SystemLanguageModel.default` anywhere (`Origami/Models/OrchestratorProfile.swift:11-75`).

> ✅ **RESOLVED on the declaration (2026-07-29); the behaviour follows.** `.onPrompt`'s closure **is**
> `async throws` — `func onPrompt(perform action: @escaping (Transcript.Prompt) async throws ->
> Void) -> some DynamicProfile`, with a zero-argument forwarding overload — ✅ **SDK-verified**
> (`FoundationModels-27.0-macos.swiftinterface:984-990`). Combined with Apple's documented rule
> that *"throwing an error inside a life cycle callback propagates to the caller's
> `respond(to:options:)`"*, a failing summariser **fails the user's turn**: the error surfaces at
> your `respond` call site. It is not swallowed. No test in the repository exercises this
> (`SummarizeHistoryTests.swift` has five tests and none makes the model throw), so the exact
> transcript state after such a failure is still unobserved — `TranscriptErrorHandlingPolicy`
> applies. **Practical rule unchanged:** wrap your call site in the same error handling you would
> use for any generation, and pass a model whose availability you have already checked — do not
> pass a `PrivateCloudComputeLanguageModel` to the summariser in a code path meant to work offline.

---

## 4. Application order: written inside-out, executed outside-in

This is the single most confusing thing about the three modifiers, and it is confusing for a good
reason: **the order you write them in is the reverse of the order they run in.**

Here is the composed example from the package's own README:

> ✅ **VERIFIED** — `README.md:88-92`, verbatim:
>
> ```swift
> Profile {
>     Instructions("A conversation between a user and a helpful assistant.")
>     ToggleDarkModeTool()
> }
> .summarizeHistory(entryThreshold: 10, model: status.summarizerModel)
> .rollingWindow(entries: 10)
> .droppingCompletedToolCalls()
> ```

**Wrapping order (lexical, bottom-up in effect):** `Profile` is wrapped by `summarizeHistory` first;
that result is wrapped by `rollingWindow`; that result is wrapped by `droppingCompletedToolCalls`.
So:

```
                    ┌──────────────────────────────────────────┐
   OUTERMOST  →     │  droppingCompletedToolCalls()            │   ← written LAST
                    │  ┌────────────────────────────────────┐  │
                    │  │  rollingWindow(entries: 10)        │  │   ← written second
                    │  │  ┌──────────────────────────────┐  │  │
                    │  │  │  summarizeHistory(...)       │  │  │   ← written FIRST
                    │  │  │  ┌────────────────────────┐  │  │  │
   INNERMOST  →     │  │  │  │       Profile { }      │  │  │  │
                    │  │  │  └────────────────────────┘  │  │  │
                    │  │  └──────────────────────────────┘  │  │
                    │  └────────────────────────────────────┘  │
                    └──────────────────────────────────────────┘

   Execution:  drop tool calls  →  rolling window  →  summarize
               (outermost first)
```

**Three independent sources in the repository confirm outside-in execution**, which is enough to treat
it as settled:

> ✅ **VERIFIED** — `README.md:78`: *"Modifiers apply in outside-in order: first, the profile drops
> completed tool calls, then applies a rolling window."*
>
> ✅ **VERIFIED** — `DropCompletedToolCalls.swift:23-25`, doc comment: *"applying it **outermost**
> ensures tool-call entries are cleaned up **before** a rolling window or summarization step runs."*
>
> ✅ **VERIFIED** — `SummarizeHistory.swift:26-28`, doc comment: *"Because summarization is the most
> aggressive form of compression, it is typically placed **innermost** (applied last) so that
> lighter-weight modifiers like `droppingCompletedToolCalls()` and `rollingWindow(entries:)` **run
> first**."*

And Apple's agent skill turns it into a rule of thumb worth memorising:

> ✅ **VERIFIED** — `skills/foundation-models-utilities/SKILL.md:215`: *"the outermost call
> (`droppingCompletedToolCalls()` above) runs first, then the rolling window, then summarization.
> **Lighter compression first means heavier compression sees a smaller transcript.**"*

### The rule, stated once

> **Write your modifiers in decreasing order of aggressiveness. The heaviest goes first in source
> order (so it ends up innermost and runs last); the cheapest goes last in source order (so it ends
> up outermost and runs first).**

If you have used SwiftUI this is the same mental gear-change as `.padding().background()` versus
`.background().padding()` — the modifier chain reads top-down but composes bottom-up. The difference
is that SwiftUI gives you visual feedback when you get it wrong, and this gives you none (§5).

> 🔴 **GAP — outside-in ordering is documented but not test-verified.** All three of the citations
> above are prose written by the same author in the same two commits, so they are one source wearing
> three hats, not three independent confirmations. **No test in the repository composes two
> modifiers.** `DroppingCompletedToolCallsTests.swift`, `RollingWindowTests.swift` and
> `SummarizeHistoryTests.swift` each apply exactly one. **What would resolve this:** a test that
> applies `.summarizeHistory(entryThreshold: 2, …).rollingWindow(entries: 20)` and asserts the final
> entry count, or the `/documentation/foundationmodels/languagemodelsession/dynamicprofilemodifier`
> page stating the composition contract. **Safe default meanwhile:** apply **one** history modifier
> per profile until you have verified ordering on your own device with
> `print(session.transcript)` before and after. A single modifier has no ordering question, and §9
> shows how to write one modifier that does two things.

---

## 5. ⚠️ Every composed example in the repository is inert

Now apply §4's execution order to §4's example and do the arithmetic.

`droppingCompletedToolCalls()` runs first and can only *shrink* `history`. `rollingWindow(entries: 10)`
runs second and guarantees `history.count <= 10`. Then `summarizeHistory(entryThreshold: 10)` runs and
evaluates its gate:

```swift prelude:guide-context
guard history.count > entryThreshold else { return }    // 10 > 10  →  false
```

**`10 > 10` is false. Summarisation can never fire.** The modifier is present, compiles, costs a
wrapper allocation, and does nothing for the life of the app.

> ⚠️ **SILENT FAILURE — an inert history-modifier composition is indistinguishable from a working
> one.** There is no warning at compile time (the values are plain `Int`s in unrelated calls), no
> runtime log, no thrown error, and no observable difference until your transcript grows past your
> model's context window and you start catching `LanguageModelError.contextSizeExceeded` in
> production. The failure surfaces as *"the context management I configured doesn't seem to do
> anything"*, which is not a search term that finds anything.

This is not a one-off typo in one README. **All four composed examples shipped in the repository have
the same defect**, and three of them are worse — they pair `entryThreshold: 50` with a window of 10
or 20:

> ✅ **VERIFIED** — four call sites, each read at `376ca60`:
>
> | # | Location | Composition | Can summarisation fire? |
> |---|---|---|---|
> | 1 | `README.md:89-90` | `entryThreshold: 10` + `rollingWindow(entries: 10)` | ❌ `10 > 10` is false |
> | 2 | `DropCompletedToolCalls.swift:31-33` (doc comment) | `entryThreshold: 50` + `rollingWindow(entries: 10)` | ❌ `10 > 50` is false |
> | 3 | `SummarizeHistory.swift:34-36` (doc comment) | `entryThreshold: 50` + `rollingWindow(entries: 10)` | ❌ never |
> | 4 | `skills/foundation-models-utilities/SKILL.md:210-212` and `:271-273` | `entryThreshold: 50` + `rollingWindow(entries: 10 or 20)` | ❌ never |
>
> That is: the README, both source-file doc comments, and Apple's own agent skill — the document a
> coding assistant will read when you ask it to add context management to your app.

### The correct relationship

For summarisation to ever fire, its threshold must be **strictly less than** whatever the rolling
window leaves behind:

```
entryThreshold  <  rollingWindow entries
```

A working composition therefore looks like this:

```swift prelude:guide-context
Profile {
    Instructions("A conversation between a user and a helpful assistant.")
    ToggleDarkModeTool()
}
.summarizeHistory(entryThreshold: 8, model: SystemLanguageModel())   // innermost, runs LAST
.rollingWindow(entries: 20)                                          // runs SECOND
.droppingCompletedToolCalls()                                        // outermost, runs FIRST
```

Trace it: tool exchanges are evicted → the window clamps to at most 20 entries → summarisation sees
somewhere between 0 and 20 entries and fires whenever that number exceeds 8. The window is the
*ceiling*; the threshold is the *trigger*, and the trigger must sit below the ceiling.

### Or: don't compose them at all

There is a strong argument for using **`droppingCompletedToolCalls()` alone**, and it is the one
composition in the package with no arithmetic trap and no known bug:

```swift prelude:guide-context
Profile {
    Instructions("A conversation between a user and a helpful assistant.")
    ToggleDarkModeTool()
}
.droppingCompletedToolCalls()
```

It cannot cut a prompt from its response (§7), it cannot orphan an entry, it never calls a model, it
has no threshold to get wrong, and in an agentic app — where tool outputs dominate the transcript —
it is where most of the available compression actually is. Add `rollingWindow` or `summarizeHistory`
only when you have measured that you still need them.

> **How to verify your own composition is live.** Instrument it, because nothing else will tell you.
> The `.onPrompt` lifecycle hook (Part 3's profiles guide) gives you a place to observe entry counts,
> and the Foundation Models Instrument gives you token counts per request — 243:93 and 243:130
> describe the token-usage and duration lanes. The cheapest check is a
> `print(history.count)` in a custom modifier of your own (§9) placed at the same position in the
> chain; if the number never exceeds your `entryThreshold`, your summarisation is dead code.

---

## 6. ⚠️ The "5000 tokens" ghost

The README describes the composed example like this:

> ✅ **VERIFIED** — `README.md:78`, verbatim: *"Summarization runs only if the rolling window of 10
> entries **exceeds 5000 tokens**."*

**There is no such behaviour.** The gate is `history.count > entryThreshold` — an entry count — and
`grep -rn "5000" Sources/ Tests/` returns **zero hits** anywhere in the package. The only occurrence
of the number `5000` in the whole repository is that one line of prose.

Here is the full evidence chain, because it is a good worked example of how to date a documentation
artifact:

> ✅ **VERIFIED** — `git show 376ca60 -- README.md` changed the code sample:
>
> ```diff
> -    .summarizeHistory(threshold: 5000, model: summarizerModel)
> +    .summarizeHistory(entryThreshold: 10, model: status.summarizerModel)
> ```
>
> **The prose on line 78 was never updated to match.** And `git show a047a50:Sources/…/SummarizeHistory.swift`
> shows that the source already used `entryThreshold: Int` compared against `history.count` **at beta
> 1** — so `threshold: 5000` never compiled against any shipped version of this package. It is a
> fossil of a pre-beta-1 token-threshold design that was abandoned before the first public commit.

Two conclusions follow, and the second is the useful one.

**First:** `5000` is not a parameter, not a default, and not example-specific. **The current API has
no token awareness whatsoever.** There is no token counter in `SummarizeHistory.swift`, no token case
in `RollingWindowSize`, and no token-based anything in the package. An entry is an entry whether it
holds three words or three thousand.

**Second, and this is the design consequence:** an entry-count threshold is a *terrible proxy* for
context pressure in exactly the app shape this package targets. Consider two transcripts, both nine
entries:

| | Entries | Real size |
|---|---|---|
| A | instructions, 4 × (prompt, response) | maybe 400 tokens |
| B | instructions, prompt, toolCalls, toolOutput (a 6 KB search result), response, prompt, toolCalls, toolOutput (a 40 KB file), response | maybe 12,000 tokens |

`entryThreshold: 10` treats these identically. Transcript B blows the on-device model's ~4K context
long before the counter reaches 10, and no modifier in this package will notice.

**What to do about it.** Until a `.tokens(Int)` case lands in `RollingWindowSize`:

1. **Put `droppingCompletedToolCalls()` outermost and mean it.** It is the only modifier here that
   targets the entries that are *actually* large, and it targets them by kind rather than by
   position.
2. **Set `entryThreshold` from your worst case, not your average.** If a single tool output can be
   40 KB, your threshold has to assume every entry is a 40 KB tool output.
3. **Measure with the real instrument.** The Foundation Models Instrument reports token usage per
   request (✅ 243:93, 243:130) and the KV-cache-hit metric — `cached input tokens ÷ total input
   tokens` — is documented in the captured optimization research. That ratio is what
   §12's argument is ultimately about, and it is measurable today.
4. **If you need a token gate, write one.** §9 shows the modifier pattern; you supply the counting.
   Nothing in the framework hands you a tokenizer, so you will be estimating — but a
   characters-divided-by-four estimate over `history.chatLog()`-style rendering is strictly better
   than an entry count, because at least it varies with content.

Apple's own agent skill flags the README wording, and gets the reason right but the pointer wrong:

> ✅ **VERIFIED** — `skills/foundation-models-utilities/SKILL.md:249`: *"Note: as of writing the
> `entryThreshold` parameter compares to entry count, not token count; the README example wording
> suggesting otherwise (e.g. 'exceeds 5000 tokens') is aspirational. **See the disabled / known-issue
> test in `SummarizeHistoryTests.swift`.**"*
>
> **The referenced test does not exist.** `SummarizeHistoryTests.swift` contains five tests, none
> disabled, none tagged. The only "documents the buggy outcome" test in the package is in
> `RollingWindowTests.swift:60` — a different file about a different modifier. This is item 8 of §20.

---

## 7. ⚠️ `rollingWindow` splits prompt/response pairs — and Apple knows

`rollingWindow` is `history.suffix(n)`. The entry array is not a list of *turns*; it is a flat list of
`Transcript.Entry` values where a single turn can be one entry (`prompt` → `response` is two) or six
(`prompt`, `toolCalls`, `toolOutput`, `toolCalls`, `toolOutput`, `response`). Taking a fixed-length
suffix of that array cuts wherever the count lands, which is very often in the middle of a turn.

The result is a transcript that starts with a `.response` that answers a `.prompt` the model can no
longer see.

> ⚠️ **SILENT FAILURE — and this one is Apple's own words, in Apple's own test.**
>
> ✅ **VERIFIED** — `RollingWindowTests.swift:71-73`, comment verbatim:
>
> > *"The naive suffix(2) trim repeatedly cuts between a prompt and its response, so the window starts
> > with an orphaned response. **This documents the (buggy) naive outcome; in practice it crashes
> > partway through.**"*
>
> The asserted expectation (`:74-80`):
>
> ```swift
> session.transcriptSummary == [
>     .instructions,
>     .response("OK"),        // ← orphaned response, no preceding prompt
>     .prompt("fourth"),
>     .response("OK")
> ]
> ```

Read what that test *is*: a passing test that pins buggy behaviour, with a comment admitting the
behaviour crashes in practice, shipped in a public package tagged `1.0.0-beta3`. This is the
strongest possible corroboration of the "emerging and experimental" label — and the strongest
possible argument for reading this package's source before adopting any of it.

Three practical consequences:

**(1) `rollingWindow` is not safe to use unsupervised on a tool-calling profile.** A tool loop
appends entries in bursts, so the cut point moves unpredictably relative to turn boundaries. If you
use it at all, put `droppingCompletedToolCalls()` outermost so the window sees a transcript made
mostly of clean prompt/response pairs — which halves the number of places a cut can land badly.

**(2) Prefer an even window size, and know it is not a fix.** With a transcript that is exactly
alternating `prompt, response, prompt, response…`, an even `n` lands on turn boundaries. Any tool
call, any `.reasoning` entry, or any multi-entry turn destroys that invariant immediately. Treat an
even window as a mitigation, not a guarantee.

**(3) The instructions entry survives, and nobody knows why.** Look again at the expected value: the
test asserts `.instructions` at index 0 even though `windowSize: 2` was applied and `suffix(2)` over
a longer array cannot possibly retain it. The modifier itself contains no logic to preserve it —
`history = history.suffix(numberOfEntries)`, full stop.

> 🔴 **GAP — why `.instructions` survives a rolling window.** The only explanation consistent with
> the test is that the framework **re-materialises the instructions entry after profile modifiers
> run** — which would make sense, because `DynamicInstructions` is evaluated per request and the
> instructions entry is its output, not a stored value the modifier can delete. But this is an
> inference from one test expectation, not a documented contract. **What would resolve this:** the
> `@SessionProperty(\.history)` documentation stating whether `history` includes the instructions
> entry at all, or an on-device experiment printing `history.count` inside `.onPrompt` before and
> after. **Safe default meanwhile:** do not rely on either behaviour. Do not assume your instructions
> survive a history modifier, and do not assume you can delete them with one.

Note the tension this creates with session 242's model of the transcript:

> ✅ **VERIFIED** — 242:69–72: *"**The transcript is `LanguageModelSession`'s representation of the
> model's context.** `DynamicInstructions` offers **one way** to modify the transcript. More
> specifically, it allows **modifying the instructions entry**. For updating the remaining entries,
> we'll use **a window into the transcript called "history"**."*

If `history` is *"the remaining entries"* — the transcript minus the instructions entry — then
`.instructions` surviving `suffix(2)` is not mysterious at all: it was never in `history` to begin
with, and the test's `transcriptSummary` helper is showing the reassembled *transcript*, not the
`history` window. That reading is consistent with everything we can see, but 242's sentence is
narration and the note above is why we are not upgrading it past 🔴.

---

## 8. What these modifiers actually mutate — and why it matters

This section is the one that changes decisions, and it is not stated anywhere in the package's
documentation.

All three modifiers share one implementation shape:

> ✅ **VERIFIED** — the pattern, from `DropCompletedToolCalls.swift:43-49` (the other two are
> structurally identical):
>
> ```swift
> private struct DropCompletedToolCallsModifier: LanguageModelSession.DynamicProfileModifier {  // :43
>     @SessionProperty(\.history)                                     // :44
>     private var history                                             // :45
>
>     func body(content: Content) -> some DynamicProfile {            // :47
>         content.onPrompt { /* … history = … … */ }                  // :48
>     }
> }
> ```

Three framework APIs surface here that appear nowhere else in this corpus with compiled usage:
`LanguageModelSession.DynamicProfileModifier` (a protocol with an associated `Content` and a
`body(content:)` requirement — SwiftUI-shaped, exactly as session 242 implied at `242:83`),
**`@SessionProperty(\.history)`**, and **`.onPrompt { }`**.

And that is the finding: **these modifiers write to `@SessionProperty(\.history)`. They do not use
`historyTransform(_:)`.** Assignment at `DropCompletedToolCalls.swift:65`, at
`RollingWindow.swift:79`, and at `SummarizeHistory.swift:153` mutates the session property.

Why that matters is stated, unambiguously, by Apple:

> ✅ **VERIFIED** — WWDC26 session 242 (`242:102–103`), verbatim, and this is the decision rule:
>
> *"**Keep in mind that the `history` property is lossy and its changes will be reflected across all
> profiles in the session. For lossless transformations targeted to specific profiles, you should
> prefer `historyTransform`.**"*
>
> And on `historyTransform`'s contrasting semantics (`242:78–80`): *"**Transforms don't permanently
> mutate the session's transcript. Instead, they're local transformations applied prior to prompting
> the model.** This means **you don't need to worry about losing context that may become relevant at
> a later point**."*

Put the two mechanisms side by side:

| | `.historyTransform(_:)` | `@SessionProperty(\.history)` — what these modifiers use |
|---|---|---|
| Mutates the real transcript? | **No.** "Local transformations applied prior to prompting the model" (242:79) | **Yes.** Explicitly *"lossy"* (242:102) |
| Scope | **This profile only** | **Every profile in the session** (242:102) |
| Reversible? | **Yes** — the original context is still there (242:80) | **No** |
| Signature | `([Transcript.Entry]) -> [Transcript.Entry]` ✅ | property-wrapper read/write |
| Apple's recommendation | *"prefer"* for targeted, lossless work (242:103) | for consolidation at a lifecycle boundary (242:92, 242:97) |
| KV cache | stateless, shape-preserving transforms can preserve it (`OptimizingKV.md:106`) | invalidates from the point of change (`OptimizingKV.md:119`) |

> ✅ **VERIFIED — `historyTransform`'s exact signature**, which our earlier notes had marked
> UNVERIFIED and Apple's Origami sample resolves: `.historyTransform(_:)` takes
> `([Transcript.Entry]) -> [Transcript.Entry]`, and a **plain function reference is accepted**. From
> `Origami/Models/OrchestratorProfile.swift`:
>
> ```swift
> Profile {
>     TermInstructions(orchestrator: orchestrator)
> }
> .model(SystemLanguageModel())
> .historyTransform(shortHistory(_:))
>
> // …elsewhere in the same struct:
> /// Returns the most recent four entries so longer on-device sessions
> /// stay within the smaller context window.
> private func shortHistory(_ entries: [Transcript.Entry]) -> [Transcript.Entry] {
>     entries.suffix(4)
> }
> ```
>
> It is handed the **entry array**, not a `Transcript`. Note also `var body: some DynamicProfile` —
> the **short** spelling inside a conforming type — and `Profile { … }.model(…)`, not
> `Profile(model:) { … }`. Apple's shipping sample is the authority on all three.

### The conflict, stated plainly

> ⚠️ **The utilities package's history modifiers take the mechanism Apple's own session tells you
> *not* to prefer.** Session 242 says: for targeted, lossless transformations, use
> `historyTransform`. All three shipped modifiers use the lossy, session-wide `history` property
> instead.

Is that wrong? No — but it is a design choice with consequences you are inheriting silently, and you
should make it deliberately:

**When the package's choice is right.** `summarizeHistory` genuinely *cannot* be a
`historyTransform`. Its whole point is to spend a model call producing a summary and then **keep** it
— re-running an expensive summarisation on every request, and throwing the result away each time,
would be absurd. Consolidation at a lifecycle boundary is precisely what 242:92 describes the
`history` property for: *"At certain points in the session, you may need to **summarize earlier
entries from the existing transcript to reclaim context**."* Same for
`droppingCompletedToolCalls()`, whose purpose is *permanent* eviction — a transform that
re-suppressed the same tool outputs on every request would leave them in the transcript growing
forever, defeating the point.

**When it bites you.** The moment you have **more than one profile** in your `DynamicProfile`. These
modifiers are attached to *one* `Profile` in your `body`, but their effect is on the *session*. So:

```swift prelude:guide-context
var body: some DynamicProfile {
    switch orchestrator.mode {
    case .drafting:
        Profile { DraftingInstructions() }
            .model(SystemLanguageModel())
            .droppingCompletedToolCalls()       // ← attached here…
    case .reviewing:
        Profile { ReviewInstructions() }
            .model(SystemLanguageModel())       // …but the tool outputs are gone here too,
                                                //    permanently, for the rest of the session.
    }
}
```

The reviewing profile never asked for tool eviction and cannot opt out of it. There is no "restore"
— the entries are gone from the session's history, not merely hidden for one request. If the
reviewing profile's job is to audit what the tools returned, you have just made that impossible from
a modifier attached to a different branch.

**The rule to take away:**

> **Treat any history modifier from this package as a session-wide, irreversible mutation, regardless
> of which `Profile` you attached it to. If you want per-profile, reversible trimming — the Origami
> pattern — use `.historyTransform(_:)` with your own function instead. It is one line and the
> framework ships it.**

For the narrow case of "keep the last N entries for this profile only," Apple's own sample already
shows you the whole solution, and it does not need this package at all:

```swift prelude:guide-context
// The per-profile, LOSSLESS alternative to .rollingWindow(entries: 4).
// ✅ Pattern verbatim from Origami/Models/OrchestratorProfile.swift.
private func shortHistory(_ entries: [Transcript.Entry]) -> [Transcript.Entry] {
    entries.suffix(4)
}

// use site
Profile { TutorialInstructions(orchestrator: orchestrator) }
    .model(SystemLanguageModel())
    .historyTransform(shortHistory(_:))
```

It has the same prompt/response-splitting hazard as §7 — `suffix` is `suffix` — but it is *local* and
*reversible*: the entries it hides are still in the transcript for the next profile, and for the next
request.

One more property worth knowing, from a community source and flagged as such:

> **Community-attributed, secondary.** `john-rocky/coreai-model-zoo`'s agentic-security checklist
> (`knowledge/agentic-security-checklist.md:112-116`) states that `.historyTransform` fires *"on
> every new user request **and every loop iteration**"* and that transforms are *"scoped to the
> current inference only — not visible to the next call, so re-apply every iteration."* The note
> attributes this to WWDC26 session 347, which is **not in our transcript corpus**. Treat "every loop
> iteration" as unconfirmed. It matters because if true, an expensive `historyTransform` runs once
> per tool-loop iteration, not once per user turn.

---

## 9. Writing your own history modifier

The three shipped modifiers are 68, 90 and 165 lines respectively, and most of that is doc comments.
The pattern is small enough to reproduce, and — given §5 and §7 — writing your own is often the right
call.

Here it is complete, with imports, as a modifier that does what `rollingWindow` does but refuses to
orphan a `.response`:

```swift compile:27
import FoundationModels

/// Keeps at most `maxEntries` history entries, but never cuts between a prompt
/// and the entries that answer it: if the retained window would begin with a
/// `.response`, `.toolCalls` or `.toolOutput`, it walks backwards to the
/// nearest `.prompt` boundary instead.
///
/// Attach with `.turnAlignedWindow(maxEntries:)`.
private struct TurnAlignedWindowModifier: LanguageModelSession.DynamicProfileModifier {
    let maxEntries: Int

    @SessionProperty(\.history)
    private var history

    func body(content: Content) -> some DynamicProfile {
        content.onPrompt {
            guard history.count > maxEntries else { return }

            // Candidate cut point: keep the last `maxEntries` entries.
            let candidate = history.count - maxEntries

            // Walk backwards until the first retained entry is a `.prompt`
            // (or we reach the start of history and keep everything).
            var cut = candidate
            while cut > 0 {
                if case .prompt = history[history.index(history.startIndex, offsetBy: cut)] {
                    break
                }
                cut -= 1
            }

            history = history.dropFirst(cut)
        }
    }
}

extension LanguageModelSession.DynamicProfile {
    /// A rolling window that only ever begins at a turn boundary.
    func turnAlignedWindow(maxEntries: Int) -> some DynamicProfile {
        modifier(TurnAlignedWindowModifier(maxEntries: maxEntries))
    }
}
```

Four notes on that.

**`modifier(_:)` is the entry point.** ✅ It is listed in the profile-modifier set alongside
`.model`, `.temperature`, `.samplingMode`, `.maximumResponseTokens`, `.reasoningLevel`,
`.toolCallingMode`, `.historyTransform` and `.transcriptErrorHandlingPolicy`
(`john-rocky/coreai-model-zoo`, `knowledge/dynamic-profiles-local-models.md:40-44` — community
source), and session 242 describes exactly this two-step pattern:

> ✅ **VERIFIED** — 242:83–85: *"First, we'll declare **a new type that conforms to
> `DynamicProfileModifier`** and apply our `historyTransform`. We can then **make it available for
> reuse by implementing an extension on `DynamicProfile`**. Any new Profiles that would benefit from
> reducing context can now utilize the new modifier."* And 242:88: *"**Custom modifiers are a great
> way to build reusable configuration for your declarations.**"*

**The `history` type is a `Collection`, not necessarily an `Array`.** From what the three shipped
modifiers exercise, `history` supports `lastIndex(where:)`, `prefix(upTo:)`, `suffix(from:)`,
`suffix(_:)`, `count`, `last`, `+` concatenation with an array literal, and is **assignable from
`[Transcript.Entry]`** (✅ `SummarizeHistory.swift:153` assigns an array literal). So it behaves as a
`RandomAccessCollection` of `Transcript.Entry` with a settable projection.

> ✅ **RESOLVED (2026-07-29; retyped in beta 5, re-checked 2026-08-23) — the concrete type is now
> `Transcript.HistoryView`.** Through beta 4 the 27.0 interface declared
> `SessionPropertyValues.history: ArraySlice<Transcript.Entry>`; the beta 5 capture retypes it as
> the dedicated `Transcript.HistoryView` collection, still with `get`/`set`/`_modify`
> (✅ **SDK-verified**, `FoundationModels-27.0-macos.swiftinterface:1071-1076`), backed by the
> equally retyped `Transcript.history: Transcript.HistoryView` (`:2695-2700`). `HistoryView` is a
> `MutableCollection` + `RandomAccessCollection` + `RangeReplaceableCollection` that is **its own
> `SubSequence`** (`:2667-2694`, `:2669`) and is `ExpressibleByArrayLiteral` (`:2719-2724`), which
> preserves everything observed: all `Collection` operations work, assignment from an array literal
> works, and `history = history.dropFirst(cut)` compiles exactly as written above because
> `dropFirst` returns a `HistoryView`. One consequence is now *stronger* than the slice story:
> `history[3]` with a raw `Int` no longer compiles at all — `HistoryView.Index` is an opaque
> struct, not `Int` (`:2703-2718`); keep using `history.index(_:offsetBy:)`.

**Do the work in `.onPrompt`, not in `body`.** The `body` of a `DynamicProfile` or a
`DynamicProfileModifier` is a pure declarative projection — it can be evaluated more than once per
turn, and Apple's guidance is unambiguous:

> ✅ **VERIFIED** — 242:59: the body re-evaluates *"each time the model is prompted."* But
> **community-measured** (`john-rocky/coreai-model-zoo`, `dynamic-profiles-local-models.md:48`):
> **7 body evaluations for 3 turns** on a third-party provider. Guides in this series state the rule
> as *"at least once per prompt, possibly several times — keep `body` pure."* Mutating session state
> from `body` will multiply your side effects by an amount you do not control.

**One modifier that does two things beats two modifiers.** Given §4's 🔴 GAP on composition ordering
and §5's inert-composition trap, a single modifier whose `onPrompt` does eviction *and* windowing in
one closure — in an order you can read on one screen — removes an entire class of bug. That is the
main reason to write your own rather than compose Apple's.

### The other lifecycle hooks

`.onPrompt` is one of six. The complete set, from a local documentation mirror:

> ✅ **VERIFIED** — `AppleFoundationModels/DynamicSessions.md:92-101`, verbatim:
>
> ```
> ## Life Cycle Modifiers
>
> Attach callbacks to profile events:
>
> * `onActivate()` — runs when this profile becomes active
> * `onDeactivate()` — runs when this profile becomes inactive
> * `onPrompt()` — runs after a user prompt appends to the transcript
> * `onResponse()` — runs after the model produces a response
> * `onToolCall()` — runs when the model invokes a tool
> * `onToolOutput()` — runs when a tool produces output
> ```
>
> Session 242 names only `onResponse` explicitly (242:97), and it names it for exactly this purpose
> (242:91–92): *"At certain points in the session, you may need to **summarize earlier entries from
> the existing transcript to reclaim context**. **Doing this after each model's response provides a
> clear boundary in the session's lifecycle.**"*

Note the mismatch worth thinking about: **242 recommends summarising at the `onResponse` boundary;
the utilities package summarises at `onPrompt`.** Both are defensible — `onResponse` gives you a
clean turn boundary and moves the summariser's latency off the user's critical path, while
`onPrompt` lets you inline the summary into the very prompt being sent (which is exactly what
`SummarizeHistory.swift:153-161` does, and it needs the prompt to exist to do it). If you write your
own summariser and latency matters more than prompt-inlining, `onResponse` is the better hook and
Apple's session agrees.

> ✅ **VERIFIED** — the pattern 242 actually shows, in narration (242:97, 242:104–110): store the
> summary in a **custom session property** declared with `@SessionPropertyEntry` on
> `SessionPropertyValues`, read it back in your `Instructions` body, and trim `history` in
> `.onResponse`. The macro spelling is `@SessionPropertyEntry` with **no parentheses** in compiled
> code, despite `DynamicSessions.md:131` writing `@SessionPropertyEntry()`.

---

## 10. What the summarizer actually reads: `TranscriptRendering`

`summarizeHistory` does not hand the transcript to the summariser model. It hands it a **flattened
plain-text rendering** produced by an internal helper, and what that rendering drops is not
documented anywhere.

> ✅ **VERIFIED** — `Sources/FoundationModelsUtilities/History/TranscriptRendering.swift`, 62 lines,
> entirely internal (note the plain `import FoundationModels` at `:12` — not `public import`, which
> under this package's `InternalImportsByDefault` setting means nothing here is API):
>
> ```swift
> extension Transcript.Entry {
>     var chatText: String? {                                         // :18
>         switch self {
>         case .prompt(let prompt):        return "User: \(prompt.segments.textContent)"
>         case .response(let response):    return "Assistant: \(response.segments.textContent)"
>         case .reasoning(let reasoning):  return "Assistant (reasoning): \(reasoning.segments.textContent)"
>         case .toolCalls(let calls):
>             let rendered = calls.map { "\($0.toolName)(\($0.arguments))" }.joined(separator: ", ")
>             return "Tool call: \(rendered)"                         // :31
>         case .toolOutput(let output):
>             return "Tool output (\(output.toolName)): \(output.segments.textContent)"   // :33
>         case .instructions:              return nil                 // :35  ← DROPPED
>         @unknown default:                return nil
>         }
>     }
> }
>
> extension Sequence where Element == Transcript.Entry {
>     func chatLog(separator: String = "\n") -> String {              // :45
>         compactMap(\.chatText).joined(separator: separator)
>     }
> }
>
> extension Sequence where Element == Transcript.Segment {
>     var textContent: String {                                       // :53
>         compactMap { segment in
>             if case .text(let textSegment) = segment { return textSegment.content }
>             return nil
>         }
>         .joined(separator: " ")                                     // :60  ← SPACE separator
>     }
> }
> ```

Three consequences, and the first two are silent data loss:

> ⚠️ **SILENT FAILURE — the summariser never sees your instructions, your structured content, or
> your images.**
>
> 1. **`.instructions` renders to `nil`** (`:35`) and is excluded from the chat log. The summariser
>    is asked to compress a conversation whose system prompt it has never read. If your instructions
>    establish a persona, a domain vocabulary, or a set of rules that make the conversation
>    intelligible, the summariser is working without them — and its output then becomes the *opening
>    paragraph of the user's next prompt* (§3.3), where it will be read by a model that also sees the
>    freshly re-materialised instructions. Mismatched framing is the failure mode.
> 2. **`textContent` keeps only `.text` segments** (`:53-59`). A `.structure` segment — the
>    `StructuredSegment` produced by a `@Generable` tool output — and an `.attachment` segment
>    (images) both `compactMap` to `nil` and vanish. A conversation that was largely image analysis
>    summarises as though the images were never there.
> 3. Nothing logs any of this. The summary just comes back thinner than you expected.
>
> **Mitigation:** if your transcript carries structured or image content that matters, do not use
> `summarizeHistory`'s default rendering. Pass your own `instructions:` that compensate, or — better
> — write your own summariser modifier (§9) that renders the entries you care about. You have full
> access to `Transcript.Entry` in an `onPrompt` closure; `chatLog()` is internal, so you were going
> to write your own renderer anyway.

The third consequence is smaller but will bite anyone writing tests:

**`textContent` joins segments with a space** (`:60`). Apple's own tests deliberately avoid the
helper because of it — `SummarizeHistoryTests.swift:19-20` defines a local `promptText` using
`joined()` with no separator and comments: *"Using `joined()` (no separator) avoids the space that
`textContent` inserts between segments."* If you assert on rendered transcript text, know which
joiner you are comparing against.

Two small framework facts fall out of this file and are worth recording, because they are hard to
find elsewhere: **`Transcript.ToolOutput` exposes a `toolName`** (`:33`), and **`Transcript.ToolCall`
exposes both `toolName` and `arguments`** (`:29`). The tool-output entry knows which tool produced
it, which is what makes selective tool-output eviction possible in a custom modifier.

---

## 11. Skills: the API surface

Session 242 introduces Skills as an alternative to the two orchestration patterns it spends most of
its time on:

> ✅ **VERIFIED** — 242:136–137: *"Baton-pass and phone-a-friend are good tools to have in your belt,
> **but there are other options as well**. For example, the **Foundation Models framework utilities
> package houses a `Skills` type**, which you may be familiar with as **a popular pattern for
> procedural context loading**."*

"Procedural context loading" is the right phrase. A skill is a body of guidance — a style guide, a
set of domain rules, a reference table, a toolset — that you do **not** want in the instructions
entry all the time, because it costs tokens on every request and dilutes the model's attention. With
`Skills`, the model asks for it when it decides it needs it.

### 11.1 `Skill` — two storages behind one type

```swift illustrative
// ✅ VERIFIED — Sources/FoundationModelsUtilities/Skills/Skill.swift
public struct Skill {                                             // :65
    var name: String { storage.name }                             // :66  ← internal
    var description: String { storage.description }               // :68  ← internal
    func activate() { storage.onActivate() }                      // :70  ← internal
    func deactivate() {                                           // :72  ← internal
        if case .instructions(let skill) = storage { skill.onDeactivate() }
    }
    let storage: Storage                                          // :78  ← internal

    enum Storage {                                                // :80
        case prompt(PromptSkill)                                  // :81
        case instructions(InstructionsSkill)                      // :82
        …
    }
}
```

**Only the initializers are public.** `name`, `description`, `storage`, `activate()` and
`deactivate()` are all internal — Apple's own tests reach them via `@testable import`
(`SkillTests.swift:12`, `:23`). So from your app you can *construct* a `Skill` and hand it to
`Skills`, and that is all. You cannot read a skill's name back out, cannot enumerate storages, and
cannot activate one programmatically. Activation happens **only** through the model calling the
synthesized tool.

The two backing structs make the asymmetry concrete:

```swift compile:27 imports:FoundationModels
// ✅ VERIFIED — Skill.swift:232-246
struct InstructionsSkill {                                        // :232
    let name: String
    let description: String
    let instructions: AnyDynamicInstructions                      // :235
    let allowsDeactivation: Bool                                  // :236  ← ONLY here
    let onActivate:   @Sendable () -> Void
    let onDeactivate: @Sendable () -> Void                        //        ← ONLY here
}

struct PromptSkill {                                              // :241
    let name: String
    let description: String
    let prompt: Prompt                                            // :244
    let onActivate: @Sendable () -> Void
    //  no allowsDeactivation. no onDeactivate.
}
```

**`allowsDeactivation` and `onDeactivate` exist only on `InstructionsSkill`.** A prompt skill is
*structurally* non-toggleable — there is no field to set, and `Skill.deactivate()` at `:72-76` is a
no-op unless the storage is `.instructions`. This is not a policy decision you can override; it falls
out of what a prompt skill *is* (§12).

> ✅ **RESOLVED (2026-07-29) — `AnyDynamicInstructions` is public framework API.** Declared
> `public struct AnyDynamicInstructions : DynamicInstructions` with
> `public init(_ dynamicInstructions: any DynamicInstructions)`, `typealias Body = Never`, and it
> is the registered `@_typeEraser` for the `DynamicInstructions` protocol — ✅ **SDK-verified**
> (`FoundationModels-27.0-macos.swiftinterface:640-663`). Availability: iOS/macOS/visionOS/watchOS
> 27.0, no tvOS. There is also an `init(erasing:)` convenience taking `some DynamicInstructions`
> (`:651-653`) — the form `Skill.swift:183` relies on. So you *may* use it directly; the
> `@DynamicInstructionsBuilder` initializer (below) still does the erasure for you and is the
> nicer spelling.

### 11.2 The four `Skill` initializers

```swift illustrative
// ✅ VERIFIED — all four, exactly as declared in Skill.swift.

// 1. Prompt-based, plain string.                                 Skill.swift:120
public init(
    name: String,
    description: String,
    prompt: String,
    onActivate: @Sendable @escaping () -> Void = {}
)

// 2. Prompt-based, @PromptBuilder.                               Skill.swift:136
public init(
    name: String,
    description: String,
    onActivate: @Sendable @escaping () -> Void = {},
    @PromptBuilder prompt: () -> Prompt
)

// 3. Instructions-based, from an InstructionsRepresentable.       Skill.swift:171
public init(
    name: String,
    description: String,
    instructions: InstructionsRepresentable,
    allowsDeactivation: Bool = false,
    onActivate:   @Sendable @escaping () -> Void = {},
    onDeactivate: @Sendable @escaping () -> Void = {}
)

// 4. Instructions-based, @DynamicInstructionsBuilder.            Skill.swift:211
public init(
    name: String,
    description: String,
    allowsDeactivation: Bool = false,
    onActivate:   @Sendable @escaping () -> Void = {},
    onDeactivate: @Sendable @escaping () -> Void = {},
    @DynamicInstructionsBuilder instructions: () -> some DynamicInstructions
)
```

Initializer 1 delegates to 2 by wrapping the string in `Prompt { prompt }` (`Skill.swift:126-132`).
Initializer 3 wraps its argument in `AnyDynamicInstructions(Instructions(instructions))`
(`Skill.swift:183`).

**Note `allowsDeactivation` defaults to `false`** on both instructions initializers. That default
also decides the *name of the synthesized tool* for the whole `Skills` collection — see §14.1.

**Initializer 4 is the sleeper feature** and gets its own section (§16), because its closure can
contain tools as well as instructions.

### 11.3 `Skills` — a `DynamicInstructions` you put in a `Profile`

```swift illustrative
// ✅ VERIFIED — Skills.swift:55
public struct Skills: DynamicInstructions {

    private static let defaultInstructions = Instructions {       // :57 — new at beta 3
        """
        If a skill below fits the user's request, silently activate it before \
        responding. Otherwise, respond normally without calling tools.
        """
    }
```

Two public initializers, identical but for the last parameter:

```swift illustrative
// ✅ VERIFIED — Skills.swift:93 (result-builder form)
public init(
    activations: SkillActivations,
    toolName: String? = nil,
    toolDescription: String? = nil,
    instructions: Instructions? = nil,          // ← added at beta 3
    strictSchema: Bool = false,
    @SkillsBuilder skills: () -> [Skill]
)

// ✅ VERIFIED — Skills.swift:127 (array form)
public init(
    activations: SkillActivations,
    toolName: String? = nil,
    toolDescription: String? = nil,
    instructions: Instructions? = nil,
    strictSchema: Bool = false,
    skills: [Skill]
)
```

`instructions ?? Skills.defaultInstructions` at `Skills.swift:138`; the override path is tested at
`SkillsTests.swift:213-227`. Because `Skills` conforms to `DynamicInstructions`, it goes wherever
instructions go — inside a `Profile`'s content closure — and its `body` is re-evaluated before each
request, which is what makes activation state visible to the model without a session restart.

The `body` emits three things in order (✅ `Skills.swift:145-202`):

1. the leading `instructions` text,
2. a `DynamicInstructions.ForEach(Array(skills.enumerated()), id: \.element.name)` (`:149`) rendering
   one block per skill,
3. the `ToggleSkillTool` (§14).

### 11.4 `SkillsBuilder` — six methods, and one `if` you cannot write

```swift prelude:guide-context
// ✅ VERIFIED — Sources/FoundationModelsUtilities/Skills/SkillBuilder.swift
// (note: filename is singular `SkillBuilder.swift`, the type is plural `SkillsBuilder`)
@resultBuilder                                                    // :41
public struct SkillsBuilder {
    public static func buildBlock(_ components: [Skill]...) -> [Skill]      // :45
    public static func buildExpression(_ expression: Skill) -> [Skill]      // :51
    public static func buildExpression(_ expression: Skill?) -> [Skill]     // :57
    public static func buildEither(first component: [Skill]) -> [Skill]     // :62
    public static func buildEither(second component: [Skill]) -> [Skill]    // :67
    public static func buildArray(_ components: [[Skill]]) -> [Skill]       // :72
}
```

Six methods. **There is no `buildOptional`.** Optionality is handled by the
`buildExpression(_ expression: Skill?)` overload at `:57`, which is why Apple's own note says *"There
is no `Optional` flag in the API — the builder accepts a `Skill?` directly"*
(✅ `skills/foundation-models-utilities/SKILL.md:177`).

The consequence is a real, if minor, ergonomic trap:

```swift illustrative
Skills(activations: activations) {
    Skill(name: "always", description: "…", prompt: "…")

    // ❌ A bare `if` with no `else` needs buildOptional, which does not exist.
    // if user.isPro {
    //     Skill(name: "pro", description: "…", prompt: "…")
    // }

    // ✅ if/else works — that's buildEither.
    if user.isPro {
        Skill(name: "pro", description: "…", prompt: "…")
    } else {
        Skill(name: "upsell", description: "…", prompt: "…")
    }

    // ✅ or feed the Skill? expression overload from a typed value.
    // (Declared outside the builder so the optionality is explicit rather
    //  than left for overload resolution to infer.)
    proSkill   // `let proSkill: Skill? = user.isPro ? Skill(…) : nil`

    // ✅ or buildArray, via a for-in.
    for topic in user.enabledTopics {
        Skill(name: topic.id, description: topic.blurb, prompt: topic.body)
    }
}
```

All six paths are covered by `SkillBuilderTests.swift` (13 tests, `:27-202`).

---

## 12. The mechanism: one line of source decides the KV cache

This is the part of the package worth studying even if you never adopt it, because it is the clearest
worked example of KV-cache economics in the whole corpus.

### 12.1 The economics, first

A transformer's key/value cache holds the attention keys and values for every token already
processed. Because attention is causal, a token's KV entries depend only on the tokens *before* it.
So:

> ✅ **VERIFIED** — the rule, from the local Apple documentation mirror and corroborated by
> session 242 (`242:170–171`; `OptimizingKV.md:28`, `:32`): **appending to the end of the transcript
> preserves the cache; rewriting anything already in it invalidates everything from the point of
> change onward.** And `OptimizingKV.md:100`: a profile switch is a **full prefix change**.

What that is worth, in wall-clock time:

> **Community-measured**, not an Apple figure. `john-rocky/coreai-model-zoo` reports turn-2
> time-to-first-token dropping from **23.28 s to 0.230 s — 101×** — at 4k context with byte-identical
> greedy output, and 15.2× at 357 tokens. Hardware: qwen3-0.6b on a Mac, via a third-party runtime,
> not Apple's on-device model. Treat the *magnitude* as indicative and the *direction* as certain.
> Reported mechanism: trimming the cache is a **single integer assignment** — nothing is cleared,
> only `processedTokenCount` rewinds, because rows at or beyond the retained position are overwritten
> before any query can read them.
>
> ⚠️ **And the constraint that decides whether any of this applies to you:** the same source reports
> that `trimKVCache` returns `-1` (unsupported) whenever `extraStates` is non-empty. SSM /
> GatedDeltaNet state is a *running scan*, not positionally addressed, so it cannot be rewound.
> **Linear-attention and hybrid models — Qwen3.5, Qwen3.6, LFM2.5, Granite 4 — forfeit prefix caching
> entirely and re-prefill every turn.** If you are running Skills against one of those through a
> custom `LanguageModel`, §12's entire argument evaporates: both skill flavours cost the same,
> because everything is recomputed regardless. Part 1's backend decision table treats this as a
> model-selection consequence, and it is.

For Apple's own on-device `SystemLanguageModel` the cache behaviour is real and the Instrument
measures it: the metric is **cached input tokens ÷ total input tokens**, as recorded in the research
synthesis from `OptimizingKV.md:171`. That ratio is how you check the claims in this section on your
own device.

### 12.2 The line

`Skills` synthesizes exactly one tool. Everything below follows from what that tool **returns**:

> ✅ **VERIFIED** — `Skills.swift:293-319`, the decisive branch, verbatim:
>
> ```swift
> func call(arguments: GeneratedContent) async throws -> Prompt {   // :293
>     …
>     switch skill.storage {
>     case .prompt(let promptSkill):
>         return promptSkill.prompt                                 // :313  ← THE LINE
>     case .instructions:
>         let activated = activations.isActive(skill.name)
>         let verb = activated ? "deactivated" : "activated"
>         return Prompt { "Successfully \(verb) skill: \(skill.name)" }   // :317
>     }
> }
> ```

A `Tool`'s return value **becomes the tool-output transcript entry**. (This is standard framework
behaviour; see Part 2's tool guide §5 for the six-entry anatomy of a tool-using turn.) So:

**For a prompt skill, the tool's return value *is the skill body*.** The entire body lands in a
`.toolOutput` entry, appended at the end of the transcript. Nothing before it changes. **The KV
cache for the whole prefix survives.**

> ✅ **VERIFIED** — `SkillsTests.swift:20-28` asserts
> `toolOutput?.segments.first?.text == "foo prompt"` — the skill's body text, verbatim, in the tool
> output. And the source's own doc comment (`Skill.swift:25-26`): *"the skill's content is added to
> the transcript as part of the matching tool output. This has the advantage of **not invalidating
> the key-value cache**."*

**For an instructions skill, the tool returns a one-line receipt** — `"Successfully activated skill:
bar"` — and the actual body goes somewhere else entirely: into the instructions entry at the **top**
of the transcript, via `Skills`' `DynamicInstructions` body:

> ✅ **VERIFIED** — `Skills.swift:156-165`, verbatim:
>
> ```swift
> if activations.isActive(skill.name) {                             // :156
>     Instructions { "\nSkill: \(skill.name) [active]" }            // :157-159
>     stored.instructions                                           // :160  ← the body, spliced in
> } else {
>     Instructions {
>         "\nSkill: \(skill.name) [inactive]"
>         "Description: \(skill.description)"                       // :163-165
>     }
> }
> ```
>
> and the tool output is only the receipt: `SkillsTests.swift:60` asserts
> `"Successfully activated skill: bar"`.

The instructions entry is the transcript's **prefix**. Changing it changes token 0. **Every cached
key and value downstream is invalidated, and the next request re-prefills the entire conversation.**

### 12.3 So why would anyone use an instructions skill?

Because the cache is not the only thing that matters. The trade is:

| | Prompt skill | Instructions skill |
|---|---|---|
| Where the body lands | `.toolOutput` entry, appended | instructions entry, at the top |
| KV cache | **preserved** ✅ | **invalidated** ❌ |
| How the model weights it | as tool output — ordinary conversational content | as **system-level instructions** — higher priority |
| Persistence | **one shot.** It is in the transcript, but as one historical tool output that ages backwards as the conversation grows | **sticky.** Re-rendered into the instructions entry on every request for as long as it is active |
| Deactivatable | **no** — structurally impossible (§11.1) | **yes**, if `allowsDeactivation: true` |
| Tracked in `activeSkillNames` | **no** (§14.3) | **yes** |
| Can carry tools | no | **yes** (§16) |
| Rendered state | `[on demand]` | `[active]` / `[inactive]` |

Apple's own guidance on choosing is short and good:

> ✅ **VERIFIED** — `skills/foundation-models-utilities/SKILL.md:146` — one of the sections of that
> document that is still correct: *"Choose **prompt-based** when the body is **large or only relevant
> for one turn** (style guides, reference docs, big rules). Choose **instructions-based** when the
> body is **short, must take effect across many turns**, and benefits from being **treated as
> system-level instructions**."*

The sentence to hold on to is *"large or only relevant for one turn."* Both halves point the same
way: the bigger the body, the more expensive it is to put in the prefix (you pay for it on every
request *and* you paid a full re-prefill to put it there); the shorter its useful life, the less you
gain from prefix placement. A 4,000-token style guide that matters for exactly one answer is the
canonical prompt skill. A two-line "the user is a physician, use clinical terminology" that must
govern the next forty turns is the canonical instructions skill.

### 12.4 The one thing both flavours pay

> ✅ **VERIFIED** — `skills/foundation-models-utilities/SKILL.md`, pitfalls list: *"**A `Skills`
> activation produces a tool call in the transcript.** Even prompt-based skills generate a
> tool-call/tool-output pair."*

There is no free activation. Every activation costs:

- one extra **model inference** (the one that emits the tool call) — remember that one call to
  `respond(to:)` is not one inference; a tool-using turn is at least two;
- a `.toolCalls` entry plus a `.toolOutput` entry in the transcript, permanently, unless you evict
  them (which is exactly what §3.1's `droppingCompletedToolCalls()` is for — see §13.3);
- and the tokens for the skill *menu* itself, which is rendered into the instructions entry on every
  single request whether or not anything is activated. A twenty-skill catalogue with a sentence of
  description each is a fixed tax on every turn.

That last cost is the one people forget. `Skills` reduces your context by moving skill *bodies* out
of the prefix; it does not remove the *index*. If your skill descriptions total more than the
smallest skill body, you have made the prefix bigger, not smaller.

---

## 13. The three transcript shapes

Apple's README carries three ASCII diagrams that are the best single explanation of the package.
They are reproduced verbatim below, each followed by what the source actually does.

### 13.1 Prompt-based activation — the body lands in the tool output

> ✅ **VERIFIED** — `README.md:154-170`, verbatim:
>
> ```
>          Before                         After
> ┌───────────────────────┐      ┌───────────────────────┐
> │     Instructions      │      │     Instructions      │
> │      (original)       │      │      (original)       │
> ├───────────────────────┤      ├───────────────────────┤
> │        Prompt         │      │        Prompt         │
> └───────────────────────┘      ├───────────────────────┤
>                                │      Tool Call        │
>                                │  (activate: skill_a)  │
>                                ├───────────────────────┤
>                                │     Tool Output       │
>                                │   (skill_a content)   │
>                                ├───────────────────────┤
>                                │       Response        │
>                                └───────────────────────┘
> ```

Read the top two boxes: **`Instructions (original)` is byte-identical on both sides.** So is
`Prompt`. Everything new is appended below them. That is the whole KV-cache argument in a picture —
the prefix is untouched, so the cache for it is still valid, and the model only has to prefill the
three new entries.

`Tool Output (skill_a content)` is the return value from `Skills.swift:313`. It is not a receipt or a
pointer; it is the skill body itself, sitting in the transcript where the model can read it for the
rest of the conversation — ageing backwards, never re-promoted.

### 13.2 Instructions-based activation — the body merges into the prefix

> ✅ **VERIFIED** — `README.md:174-190`, verbatim:
>
> ```
>             Before                                  After
> ┌────────────────────────────────┐      ┌────────────────────────────────┐
> │          Instructions          │      │          Instructions          │
> │           (original)           │      │  (original + skill_a content)  │
> ├────────────────────────────────┤      ├────────────────────────────────┤
> │             Prompt             │      │             Prompt             │
> └────────────────────────────────┘      ├────────────────────────────────┤
>                                         │           Tool Call            │
>                                         │       (activate: skill_a)      │
>                                         ├────────────────────────────────┤
>                                         │           Tool Output          │
>                                         │    (skill activated message)   │
>                                         ├────────────────────────────────┤
>                                         │            Response            │
>                                         └────────────────────────────────┘
> ```

Same three appended entries — but look at the **top box**. `(original)` became
`(original + skill_a content)`. The first entry in the transcript changed, so the cached keys and
values for it, and for everything after it, are invalid. The next request re-prefills the whole
conversation.

`Tool Output (skill activated message)` is the receipt from `Skills.swift:317` —
`"Successfully activated skill: skill_a"`. It carries no information the model needs; its only job is
to close the tool call so the loop can continue.

**What you are buying with that invalidation:** the body is now *instructions*, which the model
weights more heavily than conversational content, and it is re-rendered into the prefix on every
subsequent request rather than receding into history.

### 13.3 Deactivation + `droppingCompletedToolCalls()` — the full reclamation loop

> ✅ **VERIFIED** — `README.md:208-234`, verbatim:
>
> ```
>             Before                                  After                 Dropping Completed Tool Calls
> ┌────────────────────────────────┐  ┌────────────────────────────────┐  ┌────────────────────────────────┐
> │          Instructions          │  │          Instructions          │  │          Instructions          │
> │  (original + skill_a content)  │  │           (original)           │  │           (original)           │
> ├────────────────────────────────┤  ├────────────────────────────────┤  ├────────────────────────────────┤
> │             Prompt             │  │             Prompt             │  │             Prompt             │
> ├────────────────────────────────┤  ├────────────────────────────────┤  ├────────────────────────────────┤
> │           Tool Call            │  │           Tool Call            │  │            Response            │
> │       (activate: skill_a)      │  │       (activate: skill_a)      │  ├────────────────────────────────┤
> ├────────────────────────────────┤  ├────────────────────────────────┤  │             Prompt             │
> │           Tool Output          │  │           Tool Output          │  ├────────────────────────────────┤
> │    (skill activated message)   │  │    (skill activated message)   │  │            Response            │
> ├────────────────────────────────┤  ├────────────────────────────────┤  └────────────────────────────────┘
> │            Response            │  │            Response            │
> └────────────────────────────────┘  ├────────────────────────────────┤
>                                     │             Prompt             │
>                                     ├────────────────────────────────┤
>                                     │           Tool Call            │
>                                     │     (deactivate: skill_a)      │
>                                     ├────────────────────────────────┤
>                                     │           Tool Output          │
>                                     │  (skill deactivated message)   │
>                                     ├────────────────────────────────┤
>                                     │            Response            │
>                                     └────────────────────────────────┘
> ```

**This third diagram is the package's thesis**, and it is why Skills and the history modifiers belong
in the same guide rather than in two.

Read it left to right. In the middle panel the model has deactivated the skill: the instructions
entry is back to `(original)` — the body was removed from `Skills`' rendering, so the next
re-evaluation of the `DynamicInstructions` body omits it. But the transcript is now *longer*, not
shorter: two complete tool exchanges are sitting in it as archaeological debris.

The right-hand panel applies `droppingCompletedToolCalls()`. Both tool exchanges are earlier than the
last `.response`, so both are evicted, and the transcript collapses back to a clean
`instructions / prompt / response / prompt / response` alternation — with the instructions entry
restored to its **original bytes**.

That is full context reclamation: the skill was loaded, used, unloaded, and every trace of the
loading mechanism removed. Apple's own note says exactly this:

> ✅ **VERIFIED** — `skills/foundation-models-utilities/SKILL.md:146`: instructions skills with
> deactivation are *"useful in combination with `droppingCompletedToolCalls()` to **fully evict the
> activation/deactivation tool-call pair from history**."*

Two caveats before you build on it.

**(1) You have not recovered the cache.** The prefix changed twice (activation, deactivation) and
`droppingCompletedToolCalls()` changed the *middle* of the transcript, which invalidates from that
point onward too. Reclamation is about **context size**, not about cache hits. If you want cache
hits, use a prompt skill and do not use it at all.

**(2) Deactivation as drawn here is the model's decision, not yours.** You *can* deactivate from app
code — `SkillActivations.deactivate(_:)` is public — and because `Skills.body` re-evaluates before
each request, the change is reflected in the very next request's instructions entry and tool schema.
What you cannot do is reach into a turn already in flight, and you cannot make the model issue the
deactivation tool call that the diagram depends on.

> 🔴 **GAP — whether the model reliably deactivates.** The whole third diagram depends on the model
> emitting a second tool call to turn the skill off when it is no longer needed. The default tool
> description asks it to (§14.2), and Apple's test proves the *mechanism* works when the model does
> it (`SkillsTests.swift:63-76`: two `respond` calls produce `"Successfully activated skill: baz"`
> then `"Successfully deactivated skill: baz"` — with a **mock** model that was told what to emit).
> Nothing anywhere measures how often a real model chooses to deactivate unprompted. **What would
> resolve this:** an evaluation run — Part 6's territory — scoring deactivation recall over a
> realistic conversation set. **Safe default meanwhile:** do not architect around automatic
> deactivation. If a skill must come off at a known point (the user left that screen, the task
> completed), call `activations.deactivate(name)` from your app and treat model-initiated
> deactivation as a bonus.

---

## 14. The synthesized tool: naming, schema, descriptions, and an inverted verb

```swift prelude:guide-context
// ✅ VERIFIED — Skills.swift:205
private struct ToggleSkillTool: @unchecked Sendable, Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema
    let onCall: @Sendable (Skill) -> Void
    let skills: [Skill]
    let activations: SkillActivations
}
```

It is `private`. You never construct it, never name it in your code, and cannot subclass or replace
it. You influence it through three `Skills` parameters — `toolName:`, `toolDescription:`,
`strictSchema:` — and through the `allowsDeactivation` flags on your skills.

Note the return type, which is unusual enough to be worth flagging on its own: `func
call(arguments: GeneratedContent) async throws -> Prompt`. Both ends are atypical. `Arguments` is
raw `GeneratedContent` rather than a `@Generable` struct, because the parameter schema is built at
runtime from the current skill list (§14.4). And `Output` is a **`Prompt`** — which is legal because
`Tool.Output` need only be `PromptRepresentable`, but is rare enough that Part 2's tool guide cites
this exact line as its only real-world example of a non-`String` tool output.

### 14.1 The tool is named `toggle_skill` or `activate_skill`, and you do not choose

> ✅ **VERIFIED** — `Skills.swift:221-240`:
>
> ```swift
> let allowsDeactivation = skills.lazy.compactMap({ skill in
>     if case .instructions(let stored) = skill.storage { return stored }
>     return nil
> }).contains(where: \.allowsDeactivation)                          // :226
>
> let resolvedName = name ?? (allowsDeactivation ? "toggle_skill" : "activate_skill")   // :240
> ```

**The rule: the tool is named `toggle_skill` if *any* instructions skill in the collection sets
`allowsDeactivation: true`; otherwise `activate_skill`.** It is a property of the collection, not of
a skill. Flipping one skill's flag renames the tool for all of them.

Tests: `SkillsTests.swift:26` (`activate_skill`), `:129-135` (`toggle_skill`), `:119-127` (a custom
`use_skill` via `toolName:`).

> ⚠️ **SILENT FAILURE — adding one deactivatable skill renames the tool your instructions talk
> about.** If your `Instructions` say *"use the `activate_skill` tool to load a specialist mode"*,
> and six months later you add a single skill with `allowsDeactivation: true`, the tool is now called
> `toggle_skill` and your instructions reference a tool that does not exist. This is the general
> hazard Part 2's tool guide §8 documents — a tool named in instructions but absent from the toolset
> produces a loop with **no thrown error at all** — and this API makes it possible to trigger it by
> changing an unrelated boolean.
>
> **Defence:** pass `toolName:` explicitly the moment you mention the tool in prose. It is one
> parameter and it pins the name against every future edit:
>
> ```swift
> Skills(activations: activations, toolName: "load_skill") { … }
> ```
>
> Better still, take Apple's default advice and **do not mention the tool in your instructions at
> all** — the default leading text (§11.3) already tells the model to *"silently activate"* a
> matching skill, and the default tool description reinforces it.

### 14.2 The four default descriptions

> ✅ **VERIFIED** — `Skills.swift:242-267`:
>
> ```swift
> let hasOnDemandSkill = skills.contains { skill in
>     if case .prompt = skill.storage { return true }
>     return false
> }                                                                 // :242-247
>
> let onDemandExplanation: String? = if hasOnDemandSkill {          // :250
>     """
>     Skills marked [on demand] aren't toggled on or off; calling this tool \
>     on one delivers its guidance once.
>     """
> } else { nil }
>
> let defaultDescription = if allowsDeactivation {
>     "Activate or deactivate a skill yourself when the user's request matches its description, and otherwise respond normally without calling this tool. Don't ask the user for permission to activate, and don't mention activation in your response."
>       + (onDemandExplanation.map { " \($0)" } ?? "")              // :261-262
> } else {
>     "Activate a skill yourself when the user's request matches its description, and otherwise respond normally without calling this tool. Don't ask the user for permission to activate, and don't mention activation in your response."
>       + (onDemandExplanation.map { " \($0)" } ?? "")              // :264-265
> }
> ```

Four combinations of (`allowsDeactivation` × `hasOnDemandSkill`), all asserted verbatim at
`SkillsTests.swift:139-202`, with the `toolDescription:` override path at `:204-211`.

The prose is worth reading as prompt engineering, not just as API surface. Three instructions are
packed into one sentence: *decide yourself* (no confirmation round trip), *don't ask permission*, and
*don't mention activation in your response*. All three were **added at beta 3** — the beta-1
descriptions were the terse `"Activate or deactivate a skill"` / `"Activates a skill"`. That change
is a good proxy for what went wrong in testing: models were narrating their own activations
(*"Let me load my calendaring skill…"*) and asking users for permission to do something the user
never needed to know about.

If you override with `toolDescription:`, keep those three clauses. Losing them is the most likely
cause of a chatty, permission-seeking assistant.

### 14.3 `defer { onCall(skill) }` — why the verb reads backwards

```swift illustrative
// ✅ VERIFIED — Skills.swift:293-319
func call(arguments: GeneratedContent) async throws -> Prompt {
    let name = try arguments.value(String.self, forProperty: "skill")   // :294

    guard let skill = skills.first(where: { $0.name == name }) else {
        throw GeneratedContent.ParsingError(                           // :298
            rawContent: arguments.jsonString,
            debugDescription: """
                Model attempted to toggle a skill named '\(name)', \
                but no matching skill was found.

                Available skills:
                \(skills.map(\.name).joined(separator: "\n"))
                """
        )
    }

    defer { onCall(skill) }                                            // :309  ← IMPORTANT
    …
}
```

`defer` runs **after** the return value has been computed. So the state mutation — which flips the
activation — happens *after* the branch at `:313`/`:317` has already produced the tool output. That
is why the instructions branch reads the way it does:

```swift prelude:guide-context
let activated = activations.isActive(skill.name)
let verb = activated ? "deactivated" : "activated"
```

Read literally, that says *"if it is active, say deactivated"* — which looks like a bug and is not.
`activations.isActive` is being read **before** `onCall` has run, so `activated` describes the
*pre-call* state. A skill that was active is about to be deactivated, so the correct receipt is
`"deactivated"`. Confusing on first read, correct in effect.

Two things follow that you will care about:

**(1) `onActivate` / `onDeactivate` callbacks fire after the tool output is built.** If your
`onActivate` closure updates app state that the tool output should reflect, it will not — the output
was already constructed. Use `onActivate` for UI and side effects, never for anything the model reads
in that same turn.

**(2) The routing itself**, and the fact that prompt skills are never tracked:

```swift illustrative
// ✅ VERIFIED — Skills.swift:185-200
onCall: { [activations] skill in
    switch skill.storage {
    case .prompt:
        // On-demand: fire the activation callback, but don't track the skill
        // as active — there's no persistent state to toggle off later.
        skill.activate()                                              // :190
    case .instructions:
        if activations.isActive(skill.name) {
            activations.deactivate(skill.name)                        // :194
            skill.deactivate()
        } else {
            activations.activate(skill.name)                          // :196
            skill.activate()
        }
    }
}
```

> ⚠️ **SILENT FAILURE — `activations.isActive(promptSkillName)` is always `false`, forever.** The
> `.prompt` branch calls `skill.activate()` (your `onActivate` closure) but **never** calls
> `activations.activate(name)`. So a prompt skill never appears in `activeSkillNames`, and
> `isActive` never returns `true` for one, no matter how many times the model invokes it. This is
> deliberate — Apple's comment at `:188-189` explains it — but it is invisible from the call site.
>
> **The bug it produces:** a SwiftUI badge, chip row, or debug panel driven off
> `activations.activeSkillNames` will show instructions skills and silently omit every prompt skill,
> including ones the model just used. Nothing is nil, nothing throws, the list is simply short.
>
> **Fix:** drive prompt-skill UI off the `onActivate:` closure instead — it is the *only* signal you
> get. That is what it is for:
>
> ```swift
> Skill(
>     name: "citation_style",
>     description: "House rules for formatting citations.",
>     prompt: houseStyleGuide,
>     onActivate: { Task { @MainActor in telemetry.record(.skillUsed("citation_style")) } }
> )
> ```

### 14.4 The schema, and what `strictSchema` buys you

> ✅ **VERIFIED** — `Skills.swift:228-283`:
>
> ```swift
> let activeNames = Set(activations.activeSkillNames)               // :228
>
> var allowed = skills
>     .map(\.name)
>     .filter { !activeNames.contains($0) }                         // :230-233
>
> if !strictSchema || allowsDeactivation {
>     allowed += activeNames                                        // :236
> }
> allowed.sort()                                                    // :237
>
> let parameters = try! GenerationSchema(                           // :269
>     root: DynamicGenerationSchema(
>         name: "Arguments",
>         properties: [
>             DynamicGenerationSchema.Property(
>                 name: "skill",
>                 schema: DynamicGenerationSchema(
>                     type: String.self,
>                     guides: [.anyOf(allowed)]                     // :277
>                 ),
>             )
>         ]
>     ),
>     dependencies: []
> )
> ```

One argument, `skill: String`, constrained by `.anyOf(allowed)`. The interesting part is `allowed`.

With **`strictSchema: false`** (the default, `Skills.swift:98`, `:132`) the enum contains every skill
name, active or not. The model can call `activate_skill` on a skill that is already active. For an
instructions skill with `allowsDeactivation: false` that is a wasted turn: `onCall` sees
`isActive == true`, deactivates it, and the skill silently switches off — the opposite of what the
model asked for.

With **`strictSchema: true`** and no deactivatable skill, active names are **removed** from the enum,
so the model literally cannot emit a redundant activation. That is the reason to set it.

The condition `if !strictSchema || allowsDeactivation` means: **`strictSchema: true` has no effect
once any skill in the collection is deactivatable** — which is correct, because in a toggle world the
model legitimately needs to name an active skill in order to turn it off.

> ⚠️ **A caution about `.anyOf` that this API's shape hides.** In the general case, `@Guide(.anyOf:)`
> on a `String` **does not hard-constrain the model** — Part 2's guided-generation and tools guides
> document arguments arriving outside the declared set. Here, `Skills` defends against that
> explicitly: an unrecognised name throws
> `GeneratedContent.ParsingError(rawContent:debugDescription:)` (`:298`) with the available names in
> the message, rather than silently doing nothing. That is the right pattern and worth copying into
> your own dynamic-schema tools: **always validate in `call`, never trust the guide.**

Two smaller hazards in that block, both real:

- **`try!` at `:269`.** A malformed skill name — one `GenerationSchema` rejects — traps the process
  rather than throwing. Skill names come from your code, so this is a programmer error rather than a
  runtime risk, but keep names simple and identifier-like. Do not build them from user input.
- **`.anyOf(allowed)` is recomputed on every body evaluation**, because `allowed` is derived from
  `activations.activeSkillNames`, and `Skills.body` re-evaluates per request. That is what makes
  `strictSchema` work at all — and it also means the *tool definition* the model sees changes between
  turns. Session 242 warns that adding and removing tools mid-session confuses the model
  (`242:180–184`; `OptimizingKV.md:64-68` names three distinct hazards). Changing a tool's *schema*
  between turns is a milder version of the same thing. It is the price of dynamic activation; be
  aware you are paying it.

---

## 15. ⚠️ `SkillActivations` and the `ForEach` that stopped compiling

### 15.1 The complete type

```swift prelude:guide-context
// ✅ VERIFIED — Sources/FoundationModelsUtilities/Skills/SkillActivations.swift, essentially in full
public final class SkillActivations: Sendable, Observable {       // :23
    private let _registrar = ObservationRegistrar()               // :24
    private let _names = Mutex<[String]>([])                      // :25

    public init() {}                                              // :27

    public func activate(_ name: String) {                        // :29
        _registrar.withMutation(of: self, keyPath: \.activeSkillNames) {
            _names.withLock { names in
                guard !names.contains(name) else { return }
                names.append(name)
            }
        }
    }

    public func deactivate(_ name: String) {                      // :38
        _registrar.withMutation(of: self, keyPath: \.activeSkillNames) {
            _names.withLock { names in names.removeAll(where: { $0 == name }) }
        }
    }

    /// Returns whether the skill with the given name is currently active.
    public func isActive(_ name: String) -> Bool {                // :47
        activeSkillNames.contains(name)
    }

    /// The names of all currently active skills.
    public var activeSkillNames: [String] {                       // :52
        _registrar.access(self, keyPath: \.activeSkillNames)
        return _names.withLock { $0 }
    }
}
```

**That is the entire public surface: `init()`, `activate(_:)`, `deactivate(_:)`, `isActive(_:)`,
`activeSkillNames`.** Five members.

Three implementation details worth knowing:

- **It conforms to `Observable` manually**, not via the `@Observable` macro — it hand-rolls
  `ObservationRegistrar` with `withMutation`/`access` keyed on `\.activeSkillNames`. The macro cannot
  be applied to a `final class` that must also be `Sendable` with `Mutex`-guarded storage, so this is
  the workaround. Practical effect: SwiftUI views observing `activeSkillNames` update correctly.
  (The beta-3 commit message lists *"Fixed `SkillActivations` observation"*, so this was not right
  at beta 1.)
- **Thread safety is `Synchronization.Mutex`** (`import Synchronization` at `:13`), which is why it
  can be `Sendable` and shared across the session, your views, and the tool's `@Sendable` closure.
- **`activate(_:)` is idempotent** (`guard !names.contains(name)`), so repeated activation never
  duplicates a name.

### 15.2 The conformance that was removed

> ⚠️ **`SkillActivations` no longer conforms to `RandomAccessCollection`. Two shipped documents say
> it does, and one ships code that no longer compiles.**
>
> ✅ **VERIFIED** — commit `376ca60`'s own message: *"`SkillActivations` no longer conforms to
> `RandomAccessCollection` — replaced with a public `activeSkillNames` property and an `isActive(_:)`
> method."*
>
> Still claiming otherwise at `HEAD`:
> - `README.md:100` — describes `SkillActivations` as conforming to `Observable` **and**
>   `RandomAccessCollection`. Half true: `Observable` yes, collection no.
> - `skills/foundation-models-utilities/SKILL.md:150` — same claim, spelled
>   `RandomAccessCollection<String>`, **and** at `:158` it ships this SwiftUI snippet:
>
>   ```swift
>   // ❌ DOES NOT COMPILE at 1.0.0-beta3.
>   ForEach(assistant.activations, id: \.self) { name in … }
>   ```
>
> **The correct beta-3 form:**
>
> ```swift
> // ✅ Iterate the array property.
> ForEach(assistant.activations.activeSkillNames, id: \.self) { name in
>     Text(name)
> }
> ```

Everything else you might have written against the collection conformance has a direct replacement:

| Beta-1 (collection) | Beta-3 |
|---|---|
| `activations.contains(name)` | `activations.isActive(name)` |
| `activations.count` | `activations.activeSkillNames.count` |
| `activations.isEmpty` | `activations.activeSkillNames.isEmpty` |
| `for name in activations` | `for name in activations.activeSkillNames` |
| `ForEach(activations, id: \.self)` | `ForEach(activations.activeSkillNames, id: \.self)` |
| `activations.first` | `activations.activeSkillNames.first` |

This is the failure mode this whole guide exists to prevent: the compiler will catch the `ForEach`,
but only if you try it. A coding assistant reading `SKILL.md` will confidently generate the broken
form, and a reader skimming the README will design a feature around a collection that is not there.

### 15.3 One `SkillActivations` per session, held outside the view

> ✅ **VERIFIED** — `skills/foundation-models-utilities/SKILL.md`, pitfalls list, and this part is
> correct: *"**`SkillActivations` is a reference type and `Sendable`.** Hold one per
> 'session-equivalent'… **Don't recreate it on every render or you'll lose the activation state and
> break observation.**"*

> ⚠️ **SILENT FAILURE — a `SkillActivations` created inside a view body resets on every render.**
> Because it is a class with no persistence, constructing it in a computed property, a `body`, or a
> `Profile` you rebuild each time gives you a fresh, empty instance. Every skill silently
> deactivates; the model re-activates; you pay another tool round trip; the cycle repeats. Nothing
> throws, and the symptom — *"the model keeps re-activating the same skill"* — reads like a model
> problem.
>
> Hold it where your session lives:
>
> ```swift
> @Observable
> @MainActor
> final class Assistant {
>     let activations = SkillActivations()      // ← created ONCE, with the session
>     private(set) lazy var session = LanguageModelSession(
>         profile: AssistantProfile(activations: activations)
>     )
> }
> ```
>
> The same rule that Part 3's profiles guide states for the `DynamicProfile`'s backing state machine
> applies here: **the profile is a projection of observable state you own; it is not where state
> lives.**

### 15.4 The three rendering states

`Skills.body` renders one block per skill, and there are **three** states, not two:

> ✅ **VERIFIED** — `Skills.swift:150-176`:
>
> | Storage | Activation | Rendered | Line |
> |---|---|---|---|
> | `.instructions` | active | `\nSkill: <name> [active]` + **the body** | :156-160 |
> | `.instructions` | inactive | `\nSkill: <name> [inactive]` + `Description: <desc>` | :162-165 |
> | `.prompt` | (n/a) | `\nSkill: <name> [on demand]` + `Description: <desc>` | :172-175 |
>
> Apple's rationale for the third state, verbatim (`Skills.swift:168-171`): *"Prompt-based skills are
> one-shot: invoking one injects its content as tool output rather than toggling a persistent mode.
> We label them as **on-demand** so the model isn't told they're 'inactive' after it has already
> invoked them."*

Note the asymmetry: an **inactive** instructions skill shows its `Description:`; an **active** one
drops the description and shows the **body** instead. The description's only job is to help the model
decide whether to activate; once activated, that job is done and the tokens are reclaimed.

Here is exactly what the model sees, from Apple's own test:

> ✅ **VERIFIED** — `SkillsTests.swift:78-97`, the rendered instructions entry after activating `bar`:
>
> ```
> If a skill below fits the user's request, silently activate it before responding. Otherwise, respond normally without calling tools.
>
> Skill: foo [on demand]
> Description: foo description
>
> Skill: bar [active]
> bar instructions
> ```

The leading `"\n"` on each header (`:158`, `:163`, `:173`) is the beta-3 formatting change — beta 1
ran skills together with inline `\n\n` strings; beta 3 emits skill headers and descriptions as
separate `Instructions` lines with a blank line between skills. Six separation tests pin it
(`SkillsTests.swift:265-407`).

---

## 16. Skills that carry tools

The fourth `Skill` initializer takes a `@DynamicInstructionsBuilder` closure, and its doc comment
describes a capability that nothing else in the framework offers:

> ✅ **VERIFIED** — `Skill.swift:194-198`, verbatim: *"The closure may include `Instructions` content
> as well as `Tool` values; while the skill is active, its instructions are injected into the
> instructions entry **and any tools it carries become available to the model**."*

So a skill can gate an entire **toolset** behind a just-in-time activation. Apple's own example, in
the source:

```swift prelude:guide-context
// ✅ VERIFIED — the shape at Skills.swift:40-52
Skill(
    name: "calendaring",
    description: "Look up, create, modify and delete calendar events.",
    allowsDeactivation: true
) {
    Instructions {
        "Use the calendar tools to answer questions about the user's schedule."
        "Always confirm before deleting an event."
    }
    QueryCalendarEventsTool()
    AddCalendarEventTool()
    DeleteCalendarEventTool()
    ModifyCalendarEventTool()
}
```

Four tools that do not exist as far as the model is concerned until it activates `calendaring`. Their
names, descriptions and parameter schemas are **not** in the instructions entry, are **not** in the
tool definitions sent with each request, and cost **nothing** until needed.

That the tools contribute no text is directly tested:

> ✅ **VERIFIED** — `SkillsTests.swift:379-407`, the test named *`active builder skill with a tool
> renders no tool text`* — an active builder skill carrying a tool contributes **zero** characters to
> the rendered instructions entry while still being registered with the session.

This matters more than it first appears, because tool definitions are expensive. Each one costs its
name, its description, and its full JSON parameter schema, on **every request**, for the life of the
session. A four-tool calendar suite with `@Guide`-documented arguments is easily several hundred
tokens of fixed overhead. In a ~4K on-device context that is a real fraction of your budget spent on
capabilities the user may never invoke.

**Why this is the strongest argument for instructions skills.** §12.3 framed the prompt-vs-
instructions choice as a cache trade. Tools break the symmetry: **a prompt skill cannot carry tools**
— `PromptSkill` stores a `Prompt`, not a `DynamicInstructions` body (`Skill.swift:241-246`) — so if
your skill needs tools, you are using an instructions skill and paying the prefix invalidation. That
is fine. You are buying a capability, not just text, and you are buying it exactly once.

**Two cautions.**

**(1) The activation changes the toolset mid-session**, which is the hazard 242 explicitly names:

> ✅ **VERIFIED** — 242:180–184 warns that adding and removing tools mid-session confuses the model;
> `OptimizingKV.md:64-68` names three distinct hazards from it.

The model may reference a tool it saw in an earlier turn and no longer has, or ignore a tool that
appeared without explanation. Mitigate by making the skill's `Instructions` explicitly tell the model
what it can now do (as in the example above) rather than relying on the tool descriptions alone.

**(2) A deactivated tool-carrying skill takes its tools away.** With `allowsDeactivation: true` the
model can turn `calendaring` off, and the four tools vanish from the next request. If a prior turn's
transcript still contains their `.toolCalls` entries, the model now sees historical calls to tools it
no longer has. `droppingCompletedToolCalls()` (§3.1, §13.3) cleans exactly that up, which is another
reason the two halves of this package belong together.

> 🔴 **GAP — what happens if the model calls a tool from a deactivated skill.** We have no test, no
> documentation and no forum answer covering the race between deactivation and a tool call already in
> flight, or a model that names a now-absent tool. Part 2's tool guide §8 documents the general case
> — a tool named but absent produces an **infinite loop with no thrown error** — which suggests this
> is worth avoiding rather than handling. **What would resolve this:** an on-device experiment, or
> the `Skills` documentation growing a statement of the contract. **Safe default meanwhile:** if a
> skill carries tools, prefer `allowsDeactivation: false` and control its lifetime from your app
> (construct a `Skills` collection whose contents match the current app mode) rather than letting the
> model unload capabilities mid-conversation.

---

## 17. Choosing: prompt skill, instructions skill, or neither

Skills is one of four ways to change what a model knows mid-conversation, and it is not always the
right one. Session 242 puts the other three on the table explicitly.

| Approach | Transcript effect | KV cache | Who decides | Use when |
|---|---|---|---|---|
| **Prompt skill** | appends a `.toolOutput` carrying the body | **preserved** | the model | a large body that matters for one turn — style guides, reference docs, long rule sets |
| **Instructions skill** | rewrites the instructions entry | invalidated | the model | a short body that must govern many turns, or one that carries tools |
| **`DynamicInstructions` + your own state** | rewrites the instructions entry | invalidated | **your app** | you know from app state what the model needs — the mode changed, the user opened a screen |
| **Baton-pass / phone-a-friend** (242:119-135) | a tool flips a mode variable, or spawns a child session | full prefix change on switch; child has its own | the model | you need a different *model*, temperature or reasoning level, not just different text |

The fourth row is worth reading against the first two. If what you need is a different persona, a
different model, or a different reasoning budget, Skills is the wrong tool — `DynamicProfile`'s
branching already does that, and Apple's Origami sample shows the pattern in 75 lines
(`OrchestratorProfile.swift`). Skills is specifically for *procedural knowledge*: text and tools that
attach to the current profile rather than replacing it.

And the third row deserves more weight than it usually gets. **If your app already knows what the
model needs, do not make the model ask.** Origami's `TutorialInstructions` conditionally nests
`OrigamiInstructions()` when `orchestrator.project.craftDomain == .origami` — no tool call, no extra
inference, no schema, no activation state, no risk of the model choosing wrong:

```swift illustrative
// ✅ VERIFIED — the pattern, from Origami/Tutorial/Intelligence/TutorialInstructions.swift
struct TutorialInstructions: DynamicInstructions {
    let orchestrator: Orchestrator

    var body: some DynamicInstructions {
        Instructions { "You are an expert craft AI assistant. …" }

        if orchestrator.project.craftDomain == .origami {
            // Origami specific tools and instructions.
            OrigamiInstructions()
        }
    }
}
```

That costs one boolean. `Skills` costs an inference, a tool-call/tool-output pair, a permanent skill
menu in the prefix, and a decision the model can get wrong.

> **The decision rule:** use `Skills` when **the model is better placed than your app to know which
> body of knowledge the request needs.** A support assistant facing an open-ended user question is
> the good case. A screen-scoped feature where the app already knows the domain is not — use a
> conditional `DynamicInstructions` body instead.

### The three questions, in order

1. **Does my app already know?** → conditional `DynamicInstructions`. Stop.
2. **Do I need a different model / temperature / reasoning level?** → `DynamicProfile` branching or
   baton-pass. Stop.
3. **Is the body large, or single-turn?** → prompt skill. **Short and durable, or carrying tools?** →
   instructions skill.

---

## 18. A complete worked example

A drafting assistant with two skills — a large one-shot house style guide (prompt skill) and a short,
sticky, tool-carrying research mode (instructions skill) — plus history management that is actually
live.

```swift prelude:external-module
import FoundationModels
import FoundationModelsUtilities
import Observation
import SwiftUI

// MARK: - A tool that only exists while the research skill is active

struct LookUpSourceTool: Tool {
    let name = "lookUpSource"
    let description = "Looks up a bibliographic source by title or DOI."

    @Generable
    struct Arguments {
        @Guide(description: "A title, DOI, or author-and-year string")
        var query: String
    }

    let library: Library

    func call(arguments: Arguments) async throws -> String {
        guard let hit = await library.find(arguments.query) else {
            // Return prose rather than throwing: keeps the turn alive and steers it.
            return "No matching source. Ask the user for a DOI or a fuller citation."
        }
        return hit.formattedCitation
    }
}

// MARK: - The instructions component

struct DraftingInstructions: DynamicInstructions {
    let activations: SkillActivations
    let library: Library

    var body: some DynamicInstructions {
        Instructions {
            """
            You help the user draft and revise written work. Be concise. \
            Ask a clarifying question only when the request is genuinely ambiguous.
            """
        }

        Skills(
            activations: activations,
            // Pinned so a future `allowsDeactivation` flag can't rename it (§14.1).
            toolName: "load_skill",
            // With one deactivatable skill present, strictSchema has no effect (§14.4),
            // but pinning the intent costs nothing and documents it.
            strictSchema: true
        ) {
            // PROMPT SKILL — large, single-turn, cache-preserving.
            // Its body lands in the tool OUTPUT; the prefix is untouched.
            Skill(
                name: "house_style",
                description: """
                    The publication's house style rules: heading case, serial commas, \
                    number formatting, and the list of banned words.
                    """,
                prompt: HouseStyle.fullGuide,          // ~3,000 tokens. Never in the prefix.
                onActivate: {
                    // The ONLY signal you get for a prompt skill — it never appears
                    // in `activeSkillNames` (§14.3).
                    Task { @MainActor in Telemetry.shared.record(.skillUsed("house_style")) }
                }
            )

            // INSTRUCTIONS SKILL — short, sticky, and it carries a tool.
            // Activating it rewrites the prefix, and that is the price of the tool.
            Skill(
                name: "research_mode",
                description: "Find, verify and format bibliographic sources.",
                allowsDeactivation: true
            ) {
                Instructions {
                    """
                    You are in research mode. Verify every factual claim against a \
                    source before asserting it, and cite sources inline. Use the \
                    lookUpSource tool rather than recalling citations from memory.
                    """
                }
                LookUpSourceTool(library: library)
            }
        }
    }
}

// MARK: - The profile

struct DraftingProfile: LanguageModelSession.DynamicProfile {
    let activations: SkillActivations
    let library: Library

    var body: some DynamicProfile {
        Profile {
            DraftingInstructions(activations: activations, library: library)
        }
        .model(SystemLanguageModel())

        // History management, in EXECUTION order bottom-to-top (§4):
        //   1. droppingCompletedToolCalls()  — outermost, runs FIRST
        //   2. rollingWindow(entries: 24)    — runs second
        //   3. summarizeHistory(...)         — innermost, runs LAST
        //
        // 8 < 24, so summarisation can actually fire (§5). Reversing these two
        // numbers would make the whole chain inert with no error of any kind.
        .summarizeHistory(entryThreshold: 8, model: SystemLanguageModel())
        .rollingWindow(entries: 24)
        .droppingCompletedToolCalls()
    }
}

// MARK: - Ownership

@Observable
@MainActor
final class Assistant {
    // Created ONCE, alongside the session. Recreating this on every render
    // silently resets every activation (§15.3).
    let activations = SkillActivations()
    let library: Library

    private(set) lazy var session = LanguageModelSession(
        profile: DraftingProfile(activations: activations, library: library)
    )

    init(library: Library) { self.library = library }

    /// Force `research_mode` off when the user leaves the research pane.
    /// Do not rely on the model to deactivate (§13.3).
    func leftResearchPane() {
        activations.deactivate("research_mode")
    }
}

// MARK: - UI

struct ActiveSkillsBadge: View {
    let activations: SkillActivations

    var body: some View {
        // NOT `ForEach(activations, id: \.self)` — that stopped compiling at beta 3 (§15.2).
        ForEach(activations.activeSkillNames, id: \.self) { name in
            Text(name)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.tint.opacity(0.15), in: .capsule)
        }
        // `house_style` will NEVER appear here — prompt skills are not tracked (§14.3).
    }
}
```

### What that example is doing, and why

- **The 3,000-token style guide is never in the prefix.** It is a prompt skill, so activating it
  appends a tool output and leaves every cached key and value intact (§12.2). If the user asks three
  questions in a row about wording, the guide is loaded once and the cache survives all three turns.
- **Research mode is an instructions skill because it carries a tool.** A prompt skill cannot
  (§16). The prefix invalidation is the fee for `lookUpSource` not costing tokens on every turn of
  every conversation that never touches research.
- **`toolName: "load_skill"` is pinned** so that adding or removing `allowsDeactivation` on any skill
  can never rename the tool underneath prose that references it (§14.1).
- **The history chain is live**, and the comment says why: `8 < 24`. Every composed example Apple
  ships gets this backwards (§5).
- **`activations` is owned by the `Assistant`, not by a view** (§15.3), and the app force-deactivates
  research mode at a known boundary rather than trusting the model to do it (§13.3).
- **The badge iterates `activeSkillNames`** and carries a comment explaining the one skill it will
  never show.

### The multi-profile caveat

If `DraftingProfile.body` grew a `switch` with a second `Profile` branch, the history modifiers
attached above would still apply **session-wide and permanently** — see §8. There is no way to scope
them to one branch. If you need per-profile trimming, use `.historyTransform(_:)` on that branch
instead, and keep the utilities' modifiers for the compressions you genuinely want to be permanent
(`droppingCompletedToolCalls`, `summarizeHistory`).

---

## 19. `ChatCompletionsLanguageModel`, briefly

The package's third feature area is out of scope for this guide but you will trip over it the moment
you open the repository, so here is enough to orient you. **Part 4 covers it properly** — the wire
mapping in both directions, the executor channel event API, SSE parsing, reasoning round-trips, usage
reporting, and what it teaches about implementing `LanguageModel` yourself.

> ✅ **VERIFIED** — `ChatCompletionsLanguageModel.swift:39` and `:73`:
>
> ```swift
> public struct ChatCompletionsLanguageModel: Sendable, LanguageModel {
>     public init(
>         name: String,
>         url: URL,
>         additionalHeaders: [String: String] = [:],
>         supportsGuidedGeneration: Bool = true,
>         urlSessionConfiguration: URLSessionConfiguration? = nil   // added at beta 3
>     )
> }
> ```

It is a complete, 953-line, worked `LanguageModel` + `LanguageModelExecutor` conformance that speaks
the OpenAI chat-completions wire format — which means `mlx_lm.server`, Ollama, vLLM and LM Studio
become Foundation Models backends with no adapter code. Session 241 describes it as *"a language
model that can interface with servers using the Chat Completions standard"* (✅ `241:130`).

Two facts you need before you point it at anything:

> ⚠️ **The base-URL version detection is broken, was never fixed, and has no escape hatch.**
>
> ✅ **VERIFIED** — `ChatCompletionsLanguageModel.swift:635-637`:
>
> ```swift
> let isVersioned = baseURL.pathComponents.contains("v1")
> let endpoint = isVersioned ? "/chat/completions" : "/v1/chat/completions"
> let url = baseURL.appendingPathComponent(endpoint)
> ```
>
> `"v1"` is the *only* recognised version segment, and the fallback injects `/v1` unconditionally
> rather than appending nothing. **Measured by us** — the two decisive lines were extracted and
> executed against Swift 6.3.3 Foundation on macOS, 2026-07-27:
>
> | Base URL | Result | |
> |---|---|---|
> | `https://api.openai.com/v1` | `…/v1/chat/completions` | ✅ |
> | `http://localhost:8000` | `…/v1/chat/completions` | ✅ |
> | `http://127.0.0.1:11434/v1` (Ollama) | `…/v1/chat/completions` | ✅ |
> | `https://generativelanguage.googleapis.com/v1beta/openai` | `…/openai/**v1**/chat/completions` | ❌ |
> | `https://api.example.com/v2` | `…/v2/**v1**/chat/completions` | ❌ |
> | `https://x.openai.azure.com/openai/deployments/gpt4` | `…/gpt4/**v1**/chat/completions` | ❌ |
>
> `buildURLRequest` is `private` and no initializer parameter overrides the path. **Workaround:**
> because the check is `contains`, not a suffix test, inserting a literal `v1` path component works —
> `https://api.example.com/api/v1` resolves correctly. For a `/v2`-only server there is no workaround
> short of a local reverse proxy. `git log -p --all -S "pathComponents.contains"` returns exactly one
> hit, the introducing commit; the line is byte-identical in beta 1 and beta 3.
>
> **Bonus:** `README.md:52` and `:67` both write `URL(string: "http://localhost/v1:8000")!` — the port
> is inside the path. The intended URL is `http://localhost:8000/v1`. This appears in the README's
> very first code sample.

> ⚠️ **SILENT FAILURE — there is no incremental streaming on Linux.** `streamChatCompletions`
> forks on `#if canImport(Darwin)` (`:587`). Darwin uses `session.bytes(for:)` +
> `for try await line in stream.lines` — true token-by-token streaming. Non-Darwin uses
> `session.data(for:)` (`:606`), which **buffers the entire response** and then splits on `\n`
> (`:617`). `session.streamResponse` still compiles, still yields, and still completes — it just
> delivers everything at once at the end. Nothing indicates the difference. The README's
> *"Supported platforms: Apple platforms and select Linux distributions like Ubuntu"*
> (`README.md:10`) does not mention it, and there is **no CI verifying any Linux behaviour at all**.

The single most instructive detail in that file, and the reason Part 4 opens with it: the executor's
`Configuration` implements `Hashable` **manually and deliberately excludes `urlSession`** from both
`==` and `hash(into:)` (`:201-211`), because *"the framework caches one executor per unique
configuration, so equality matters"* (✅ `skills/foundation-models-language-model-protocol/SKILL.md:65`).
`URLSession` is a class with reference identity; including it would defeat the cache. The consequence
is a latent wrinkle — two models differing **only** in `urlSessionConfiguration` compare equal, so
the framework may hand back an executor built with the other session.

**Cross-link:** everything above, plus the protocol declarations, the three channel event types, all
nine `LanguageModelError` cases with payload fields, and Apple's eleven implementer pitfalls, live in
Part 4. Note also **C4** from the series' corrections register: grammar-constrained decoding needs
engine logits, and GPU-pipelined Core AI bundles never expose them — so `@Generable` and guided
generation are not universally available on a bring-your-own-model path. That is an architectural
constraint, not a footnote, and it interacts with `supportsGuidedGeneration:` above.

---

## 20. The `SKILL.md` audit: eight wrong claims

The repository ships two agent skills under `skills/`, each a plain `SKILL.md` with YAML frontmatter
and **no `references/` or `scripts/` subdirectory**. They matter more than ordinary documentation
because a coding assistant will read them and generate code from them.

- `skills/foundation-models-language-model-protocol/SKILL.md` (815 lines) — **updated at beta 3**,
  and the single most valuable artifact in the repository. It carries the verbatim `LanguageModel` /
  `LanguageModelExecutor` protocol declarations, the full
  `LanguageModelExecutorGenerationRequest` struct, the channel event API, and all nine
  `LanguageModelError` cases. Part 4 is built on it. Trust it.
- `skills/foundation-models-utilities/SKILL.md` (327 lines) — **not touched by commit `376ca60`**
  (`git show 376ca60 --stat` lists only the *other* skill file). It therefore describes **beta 1**.

> ⚠️ **`skills/foundation-models-utilities/SKILL.md` is a stale beta-1 document with eight verified
> wrong claims.** If you have an agent configured to read repository skills, this file is actively
> generating broken code today.
>
> | # | The claim | Line | Reality at `HEAD` |
> |---|---|---|---|
> | 1 | *"Three independent feature areas, each guarded by its own **SwiftPM trait**"* — `ChatCompletions`, `Skills`, `History` — and *"source files are gated by `#if ChatCompletions`, `#if Skills`, and `#if History`"* | `:9-17`, `:326` | **Entirely fictional.** There is no `traits:` declaration in `Package.swift`, and **zero** occurrences of `#if ChatCompletions` / `#if Skills` / `#if History` in any source file. |
> | 2 | `SkillActivations` *"conforms to `RandomAccessCollection<String>`"*, with `ForEach(assistant.activations, id: \.self)` | `:150`, `:158` | Removed at beta 3. The snippet does not compile. Use `.activeSkillNames`. (§15.2) |
> | 3 | `summarizeHistory(entryThreshold:model:…)` with **`model: Model = SystemLanguageModel()`** | `:234`, `:243` | **No default for `model:`** (`SummarizeHistory.swift:55`). A generic parameter cannot carry one. (§3) |
> | 4 | `ChatCompletionsLanguageModel.init` shown without `urlSessionConfiguration` | `:46-52` | Added at beta 3 (`ChatCompletionsLanguageModel.swift:78`). |
> | 5 | Toggle-tool descriptions are `"Activate or deactivate a skill"` / `"Activates a skill"` | `:170` | Replaced at beta 3 by the long *"…Don't ask the user for permission…"* forms (`Skills.swift:259-266`), test-pinned at `SkillsTests.swift:139-202`. (§14.2) |
> | 6 | `response_format` name *"is read from the schema's `title`/`type`, falling back to `\"Response\"`"* | `:72` | The `GenerationSchema.title` JSON hack was **deleted** at beta 3 in favour of the new first-class **`GenerationSchema.name`** (`ChatCompletionsLanguageModel.swift:266`). |
> | 7 | Package layout shows `Tests/FoundationModelsUtilitiesEvaluations/  # eval-driven tests for summarization` | `:323` | That directory does not exist. The second test target is `FoundationModelsUtilitiesIntegrationTests`. |
> | 8 | *"See the disabled / known-issue test in `SummarizeHistoryTests.swift`"* | `:249` | No such test. That file has five tests, none disabled, none tagged. (§6) |
>
> It also **omits** `Skills(instructions:)` and the default leading instruction, both new at beta 3.

Claim 1 is the dangerous one. A "SwiftPM trait" story implies you can adopt Skills without pulling in
the networking code, that there are conditional-compilation flags to set, and that the package has a
modularity design it does not have. An agent that believes it will write `#if Skills` guards, add
`traits:` to your `Package.swift`, and produce a build failure whose cause is a fabricated feature.

**What that file still gets right**, and it is worth reading for these:

- the two-flavour `Skill` table with the KV-cache column (`:141-144`) — matches source exactly;
- the choose-which guidance quoted in §12.3 (`:146`);
- *"**A `Skills` activation produces a tool call in the transcript.** Even prompt-based skills
  generate a tool-call/tool-output pair."*;
- *"**`SkillActivations` is a reference type and `Sendable`.** Hold one per 'session-equivalent'…
  Don't recreate it on every render."* (§15.3);
- *"**`summarizeHistory` requires the trailing entry to be `.prompt`.** It is a no-op for any other
  trailing entry kind."* (§3.3);
- *"**Custom segments aren't supported by `ChatCompletionsLanguageModel`.**"*;
- the outside-in ordering rule (§4);
- the wire-format and SSE-parsing summaries (`:69-76`, `:80-87`).

**If you run coding agents against this repository**, the practical move is to pin the parts of that
file you rely on into your own project notes with the corrections above applied, and not let the
agent read `skills/foundation-models-utilities/SKILL.md` unmediated. The other skill file — the
`LanguageModel` protocol one — is current and can be used as-is.

---

## 21. Quick reference

### 21.1 The nine public symbols

| Symbol | Kind | Notes |
|---|---|---|
| `Skill` | struct | four public initializers; **all other members internal** |
| `Skills` | struct : `DynamicInstructions` | two initializers; put it in a `Profile` content closure |
| `SkillActivations` | final class : `Sendable, Observable` | `init()`, `activate(_:)`, `deactivate(_:)`, `isActive(_:)`, `activeSkillNames`. **Not a Collection.** |
| `SkillsBuilder` | `@resultBuilder` | six methods; **no `buildOptional`** — a bare `if` without `else` will not compile |
| `RollingWindowSize` | enum : `Sendable` | one case: `.entries(Int)` |
| `droppingCompletedToolCalls()` | `DynamicProfile` method | no parameters |
| `rollingWindow(entries:)` | `DynamicProfile` method | sugar for `rollingWindow(size: .entries(_))` |
| `rollingWindow(size:)` | `DynamicProfile` method | |
| `summarizeHistory(entryThreshold:model:instructions:summaryPostamble:)` | `DynamicProfile` method | **`model:` has no default** |

Plus `ChatCompletionsLanguageModel` — see Part 4.

### 21.2 Skill flavours at a glance

| | Prompt skill | Instructions skill |
|---|---|---|
| Initializers | `init(name:description:prompt:onActivate:)`, `init(name:description:onActivate:prompt:)` | `init(name:description:instructions:allowsDeactivation:onActivate:onDeactivate:)`, `init(name:description:allowsDeactivation:onActivate:onDeactivate:instructions:)` |
| Body lands in | `.toolOutput` entry | instructions entry (prefix) |
| KV cache | **preserved** | invalidated |
| Rendered state | `[on demand]` | `[active]` / `[inactive]` |
| Tool output text | **the skill body** | `"Successfully activated skill: <name>"` |
| `allowsDeactivation` | **does not exist** | yes, default `false` |
| Appears in `activeSkillNames` | **never** | when active |
| Can carry tools | no | **yes** |

### 21.3 Copy-paste starters

```swift prelude:guide-context
// Depend on it (the README's `from: "1.0.0"` resolves to nothing).
.package(url: "https://github.com/apple/foundation-models-utilities", exact: "1.0.0-beta3")
```

```swift prelude:guide-context
// A live history chain. entryThreshold MUST be < rollingWindow entries.
.summarizeHistory(entryThreshold: 8, model: SystemLanguageModel())   // innermost, runs LAST
.rollingWindow(entries: 24)                                          // runs second
.droppingCompletedToolCalls()                                        // outermost, runs FIRST
```

```swift prelude:guide-context
// The safest single modifier: no threshold, no known bug, no ordering question.
.droppingCompletedToolCalls()
```

```swift prelude:guide-context
// The lossless, per-profile alternative that needs no package at all.
private func shortHistory(_ entries: [Transcript.Entry]) -> [Transcript.Entry] {
    entries.suffix(4)
}
// …
.historyTransform(shortHistory(_:))
```

```swift prelude:guide-context
// Iterating activations after beta 3.
ForEach(activations.activeSkillNames, id: \.self) { name in Text(name) }
```

### 21.4 Symptom → cause

| Symptom | Cause | § |
|---|---|---|
| SwiftPM cannot resolve the package; looks like a network error | `from: "1.0.0"` excludes both prerelease tags | §1.1 |
| Summarisation never fires; transcript grows until `contextSizeExceeded` | `entryThreshold` ≥ rolling-window size — the composition is inert | §5 |
| Summarisation fires far later than configured in an agentic app | the hook is a no-op unless the trailing entry is a `.prompt`; tool-loop iterations skip it | §3.3 |
| Summary is missing the persona / rules that made the conversation make sense | `.instructions` renders to `nil` in the chat log the summariser reads | §10 |
| Summary is missing structured tool output or image content | `textContent` keeps only `.text` segments | §10 |
| Transcript begins with a `.response` that answers nothing; later, a crash | `rollingWindow` is `suffix(n)` and cuts mid-turn | §7 |
| A profile that never asked for trimming lost its tool history | history modifiers write the **lossy, session-wide** `history` property | §8 |
| Model keeps re-activating the same skill | `SkillActivations` recreated per render | §15.3 |
| `ForEach(activations, …)` does not compile | `RandomAccessCollection` conformance removed at beta 3 | §15.2 |
| A prompt skill never appears in the active-skills UI | prompt skills are never tracked in `activeSkillNames` — by design | §14.3 |
| Model loops forever after you added one deactivatable skill | the tool renamed itself from `activate_skill` to `toggle_skill`, and your instructions still name the old one | §14.1 |
| Model narrates *"let me activate my X skill"* or asks permission | a custom `toolDescription:` dropped the three clauses in the beta-3 default | §14.2 |
| Model re-activates an already-active skill and it switches **off** | `strictSchema: false` (the default) leaves active names in the enum | §14.4 |
| Skill body appears in the prefix and you wanted it in the tool output | you used an instructions skill; use a prompt skill | §12 |
| Skill needs a tool but you wanted cache preservation | prompt skills cannot carry tools — this trade is structural | §16 |
| Ollama / vLLM endpoint returns 404 on `/v1/v1/chat/completions` | base-URL version detection only recognises the literal `v1` | §19 |
| No token-by-token streaming on a Linux server build | non-Darwin buffers the whole response | §19 |
| An agent wrote `#if Skills` guards or added `traits:` to `Package.swift` | it read the stale beta-1 `SKILL.md`, which invents a trait system | §20 |

### 21.5 Never write these

Circulating and wrong, in this area specifically:

- **`from: "1.0.0"`** for this package — no non-prerelease tag exists.
- **`.summarizeHistory(threshold: 5000, …)`** — a pre-beta-1 parameter that never shipped.
- **`model: SystemLanguageModel()` as a default** on `summarizeHistory` — you must pass it.
- **`ForEach(activations, id: \.self)`** — removed conformance.
- **`#if Skills` / `#if History` / `#if ChatCompletions`**, or a `traits:` block — fictional.
- **`Skill.name` / `Skill.description` reads from app code** — internal, not public.
- **`Profile(model:) { … }`** — Apple's shipping sample uses `Profile { … }.model(_:)`.
- **`some LanguageModelSession.DynamicProfile` as the `body` type** — Apple writes the short
  `some DynamicProfile` inside a conforming type; the conformance itself stays nested.
- And the series-wide known-bad list: `.coreaimodel`, `.aiasset`, a `coreai-torch convert` CLI,
  "iOS 20 / macOS 17", and an on-device LoRA training API. None exist.

---

## 22. Sources

**Primary — `apple/foundation-models-utilities` at commit `376ca60` (tag `1.0.0-beta3`,
2026-07-10), read on disk.** This is the highest-precedence evidence in the guide: it is shipping
first-party Swift with file-and-line citations throughout. Files read in full:
`README.md` (235 lines, including all three ASCII diagrams reproduced in §13) ·
`Package.swift` (65) · `CONTRIBUTING.md` · `Documentation.docc/Documentation.md` (34) ·
`Skills/Skill.swift` (247) · `Skills/Skills.swift` (321) · `Skills/SkillActivations.swift` (56) ·
`Skills/SkillBuilder.swift` (75) · `History/DropCompletedToolCalls.swift` (68) ·
`History/RollingWindow.swift` (90) · `History/SummarizeHistory.swift` (165) ·
`History/TranscriptRendering.swift` (62) ·
`LanguageModels/ChatCompletionsLanguageModel.swift` (953) ·
`skills/foundation-models-language-model-protocol/SKILL.md` (815) ·
`skills/foundation-models-utilities/SKILL.md` (327).
Test files read in full and cited for behavioural claims: `SkillsTests.swift` (679) ·
`SkillTests.swift` (105) · `SkillBuilderTests.swift` (203) · `SummarizeHistoryTests.swift` (190) ·
`DroppingCompletedToolCallsTests.swift` (80) · `RollingWindowTests.swift` (93) ·
`MockModel.swift` (122) · `EntrySummary.swift` (64), plus the eleven `ChatCompletionsTests+*`
suites.
Git artifacts: `git log --oneline -50` · `git show 376ca60` (full and scoped) ·
`git show a047a50:…/SummarizeHistory.swift` · `git log -p --all -S "pathComponents.contains"` ·
`git ls-remote --tags`. GitHub queries: `gh repo view`, `gh issue list --state all`,
`gh pr list --state all`, `gh release list`.

**Apple sample-code projects, read on disk** (downloaded 2026-07-27; compiling first-party code, and
the reason several claims in this guide correct our earlier notes): **Origami — *Crafting a dynamic
tutorial for Apple Intelligence*** (iOS/macOS/visionOS 27.0, 61 Swift files) —
`Models/OrchestratorProfile.swift` is the authority for `var body: some DynamicProfile`,
`Profile { … }.model(_:)`, `.historyTransform(_:)`'s
`([Transcript.Entry]) -> [Transcript.Entry]` signature, `LanguageModelSession(profile:history:)`, and
`SystemLanguageModel()` as house style; `Tutorial/Intelligence/TutorialInstructions.swift`,
`Tutorial/Intelligence/OrigamiInstructions.swift`, `Coach/CoachInstructions.swift` for the
`DynamicInstructions` conformances quoted in §9 and §17.
Two other Apple samples exist and are **deliberately not cited here**: the coffee/generative-game
sample and the SpeechAnalyzer sample are iOS 26 / WWDC25 leftovers that were never refreshed, and
nothing in them is evidence about 2026 behaviour.

**WWDC26 sessions** (spoken-word transcripts; code shown on screen was described, not dictated, which
is why narrated code appears in this series as 🟡 RECONSTRUCTED and is not the basis of any signature
here): **242** *Build agentic app experiences with the Foundation Models framework* — the package
announcement (`242:12–14`), the transcript/history model (`242:69–72`), `historyTransform`'s
non-mutating semantics (`242:78–80`), **the lossy-`history`-property decision rule (`242:102–103`)**,
custom modifiers (`242:83–88`), lifecycle modifiers (`242:91–97`), baton-pass and phone-a-friend
(`242:119–137`), and the tool-churn warning (`242:180–184`). **241** *What's new in Foundation
Models* — the package's three feature areas (`241:130`). **243** — the Foundation Models Instrument's
token-usage and duration lanes (`243:93`, `243:130`).

**Apple documentation mirrors** (`AppleFoundationModels/` doc set): `DynamicSessions.md` — the six
lifecycle modifiers verbatim (`:92-101`) and the `@SessionProperty(\.history)` type annotation
(`:118-119` — its `[Transcript.Entry]` annotation is now known to be wrong: beta 5 projects
`Transcript.HistoryView`, §9) ·
`OptimizingKV.md` — append-preserves / rewrite-invalidates (`:28`, `:32`), profile switch as full
prefix change (`:100`), and the cache-hit metric (`:171`).

**Community, attributed as such and never presented as an Apple claim:**
`john-rocky/coreai-model-zoo` — the 101× prefix-reuse measurement and the
`trimKVCache`-returns-`-1`-for-hybrid-architectures constraint (§12.1), the profile-modifier
inventory and `.modifier(_:)` (§9), the 7-body-evaluations-for-3-turns measurement (§9), and the
`historyTransform`-fires-every-loop-iteration claim (§8, flagged as unconfirmed and sourced to a
WWDC26 session absent from our corpus).

**Precedence used throughout:** Apple sample-code projects > headers/SDK sources on disk > Apple
documentation pages > Apple-staff forum answers > WWDC transcripts > community repositories. Two
places in this guide the sources conflict and the guide says which wins:

1. **`skills/foundation-models-utilities/SKILL.md` versus the shipping source.** The source wins,
   eight times over (§20). That document is a beta-1 artifact and Apple did not refresh it at beta 3.
2. **Session 242's advice versus the package's implementation.** 242 says to *prefer*
   `historyTransform` for targeted, lossless work; all three shipped modifiers use the lossy,
   session-wide `@SessionProperty(\.history)` instead. Both are Apple, and neither is wrong — but the
   consequence is real and undocumented, so §8 states it plainly rather than picking a winner.

**Open 🔴 GAPs declared in this guide, collected:** outside-in composition ordering, documented
three times by one author and tested zero times (§4) · why `.instructions` survives a rolling
window (§7) · whether real models deactivate skills unprompted (§13.3) · what happens when a model
calls a tool from a just-deactivated skill (§16). **Closed on 2026-07-29 against
`notes/sdk-interfaces/FoundationModels-27.0-macos.swiftinterface`:**
`session.logFeedbackAttachment` — three synchronous `Data`-returning overloads, 26.0-era
(§1.2, `:3472-3514`) · `.onPrompt` is `async throws`, so a failing summariser fails the turn
(§3.4, `:984-990`) · `@SessionProperty(\.history)` projects `Transcript.HistoryView`
(§9, `:1071-1076`) · `AnyDynamicInstructions` is public API, the protocol's registered type
eraser (§11.1, `:640-663`).
