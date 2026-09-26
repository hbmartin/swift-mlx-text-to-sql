# 2.4 — Local RAG with `SpotlightSearchTool`, plus OCR and barcodes

**What this covers.** Apple's 2026 answer to "how do I do RAG on device without a vector
database": `SpotlightSearchTool`, a `Tool` conformer that lets a language model write and execute
queries against your app's own Core Spotlight index. This guide covers the whole surface from
WWDC26 session 246 **and from Apple's shipping sample project for it** — configuration, the
index-delegate hydration hook, the batched `SearchReply` stream, the two-channel results pattern,
guidance profiles, the contact resolver, and custom `Generable` pipeline stages — and then covers,
honestly, the three ways it is currently known to fail. It closes with the two Vision-backed system
tools, `OCRTool` and `BarcodeReaderTool`.

**Version floor.** `SpotlightSearchTool` is **27.0** — **iOS 27, iPadOS 27, macOS 27, visionOS 27**.
**There is no watchOS support**; Apple's platform sentence omits it and nothing in the corpus
contradicts that. `OCRTool` and `BarcodeReaderTool` are also **27.0**, and live in **Vision**, not
Foundation Models. `GenerationOptions.ToolCallingMode` — which you will need as a diagnostic probe
in §14 — is **27.0**. `CSSearchableIndex` / `CSSearchableItem` / `CSSearchableIndexDelegate` all
predate 26.0 by years; the one delegate method at the centre of this guide,
`searchableItems(forIdentifiers:searchableItemsHandler:)`, is reported as **macOS 15.4+** with a
*new overload* in 27.0 (see §7 — this contradicts the session, and the contradiction matters).

**No entitlement is required.** ✅ **VERIFIED** — Apple's own session-246 sample project ships an
`.entitlements` file containing an empty `<dict/>`. `SpotlightSearchTool` is not a managed
capability, needs no request form, and adds nothing to your provisioning profile.

**What you need.** An app that already donates content to Core Spotlight (§2 — this is a hard
prerequisite, not a nicety), a device or Mac on 27.0, Xcode 27, and a model that declares tool
calling. Read [2.3 — The `Tool` protocol, calling modes, and the required-mode
loop](03-tools-and-tool-calling.md) first; this guide assumes you know what a tool call is and
what `toolCallingMode: .required` does to your loop.

---

## Citation convention used in this guide

The precedence order from the [series README](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/README.md) is: headers/SDK and Apple sample
code → Apple docs → Apple-staff forum answers → WWDC transcripts → community repos. This guide
draws on all five tiers and labels each claim, because for `SpotlightSearchTool` specifically **the
tiers disagree with each other in several places**. Where they disagree I say so and tell you which
one I believe.

| Source | Tier | What it gives us |
|---|---|---|
| **Apple's sample project "Searching indexed content with natural language"** — the hiking-trails app, target `LLMSearchUsingCoreSpotlightApp`, 6 Swift files / 792 lines, `IPHONEOS_DEPLOYMENT_TARGET = 27.0`, Swift 6 | **1 — compiling first-party code** | The real `Configuration` shape, the real delegate signature, the real `searchResults` enum, the entitlement answer, and the instructions template. Cited as `Session.swift:NN` / `Indexer.swift:NN` |
| `developer.apple.com/documentation/foundationmodels` (June 2026 updates page, tool-calling article) | 2 — Apple docs | `OCRTool` / `BarcodeReaderTool` naming and one compilable sample; the complete `GenerationOptions.ToolCallingMode` surface |
| Developer Forums threads 833658, 833651, 832534, 838904, 837226 | 3 — Apple staff + reproducible dev reports | Three live defects, two of them Apple-acknowledged |
| WWDC26 session 246, "LLM search using Core Spotlight" (Jennifer, Spotlight engineering), 138 lines | 4 — transcript | The entire conceptual model. Cited as `246:NN` |
| WWDC26 session 241, "What's new in Foundation Models" (Erik & Zhen) | 4 — transcript | The one-line framing of the three system tools. Cited as `241:LNN` |
| A community field-verification note, dated **2026-06-13**, macOS 27 beta, M4 Max, that ran the tool behind a third-party model | 5 — community repo | Measured numbers and behavioural defects; its reconstructed *shapes* are now superseded where the sample contradicts them |
| A shipping iOS app's `NoemaSpotlightIndexing.swift` | 1 — real source on disk | Verified Core Spotlight donation code |

Session 246 is spoken narration over slides. **Apple read the concepts aloud; nobody read the
signatures aloud.** The sample project is the missing half: it is compiling, shipping Apple code,
so wherever it speaks it **outranks** both the transcript and the community field note, and this
guide has been written to follow it. What the sample does *not* exercise — the file source, the
contact resolver, custom pipeline stages, `GuidanceProfile` — is now nonetheless ✅ **SDK-verified**
at the declaration level: the `_CoreSpotlight_FoundationModels` cross-import overlay interface was
captured on 2026-07-29 (`notes/sdk-interfaces/_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface`),
and it vindicated the field note's spellings almost everywhere. The suspicion that survives is
behavioural, and it is still sharp: **Apple's own reference implementation of this feature does not
use any of them**, so their runtime behaviour remains untested.

---

## Contents

1. [What the tool actually is, and what it replaces](#1-what-the-tool-actually-is-and-what-it-replaces)
2. [The prerequisite nobody can skip: donating content](#2-the-prerequisite-nobody-can-skip-donating-content)
3. [The cross-import overlay, and the two-line version](#3-the-cross-import-overlay-and-the-two-line-version)
4. [The trajectory: what actually happens on one `respond`](#4-the-trajectory-what-actually-happens-on-one-respond)
5. [`Configuration`: sources, guide, and the two members Apple never uses](#5-configuration-sources-guide-and-the-two-members-apple-never-uses)
6. [⚠️ The metadata gap — the defect that will burn you](#6-️-the-metadata-gap--the-defect-that-will-burn-you)
7. [`searchableItems(forIdentifiers:searchableItemsHandler:)` — the intended fix, and the conflict](#7-searchableitemsforidentifierssearchableitemshandler--the-intended-fix-and-the-conflict)
8. [The retrieve-then-hydrate pattern that works today](#8-the-retrieve-then-hydrate-pattern-that-works-today)
9. [Consuming results: two channels, `searchResults`, and `queryToken`](#9-consuming-results-two-channels-searchresults-and-querytoken)
10. [Guidance: `.focused()`, `.complete`, `GuidanceProfile`, and the token gate](#10-guidance-focused-complete-guidanceprofile-and-the-token-gate)
11. [Reference resolution and the contact resolver](#11-reference-resolution-and-the-contact-resolver)
12. [Custom pipeline stages](#12-custom-pipeline-stages)
13. [Custom attributes, `IndexedEntity`, and dynamic guidance](#13-custom-attributes-indexedentity-and-dynamic-guidance)
14. [Three documented failure modes](#14-three-documented-failure-modes)
15. [Running the tool behind a non-Apple model](#15-running-the-tool-behind-a-non-apple-model)
16. [Evaluating a Spotlight-grounded feature](#16-evaluating-a-spotlight-grounded-feature)
17. [`OCRTool` and `BarcodeReaderTool`](#17-ocrtool-and-barcodereadertool)
18. [Adoption checklist and the gap index](#18-adoption-checklist-and-the-gap-index)

---

## 1. What the tool actually is, and what it replaces

Retrieval-augmented generation on device has, until this year, meant one of two things: you built
an embedding pipeline and a vector store yourself, or you gave up and stuffed your whole corpus
into a 4K context window. Apple's framing in session 241 is that this was the most requested
missing piece:

> ✅ **VERIFIED** — `241:L63-66`, verbatim: "we're also introducing a **search tool powered by
> Spotlight** for implementing **fully local Retrieval-Augmented Generation**. **This has been one
> of your most most requested features.** Retrieval-Augmented Generation, or RAG, is a technique
> that gives the model access to **up-to-date personal or domain knowledge** by leveraging a
> **Spotlight index and specially processed queries**."

The deep dive is session 246. Its thesis:

> ✅ **VERIFIED** — `246:19-21`, verbatim: "today, we're introducing **`SpotlightSearchTool`**. It's
> a tool that **adopts the tool protocol**, to let a language model **directly search your app's
> content in Core Spotlight** for contextual response generation. `SpotlightSearchTool` is
> available on **iOS, iPadOS, macOS, and visionOS**."

Three consequences follow immediately, and each of them is load-bearing.

**It is an ordinary `Tool`.** Not a session mode, not a model capability, not a privileged system
path. It conforms to the same `Tool` protocol your own tools conform to, so it composes with your
own tools in the same `tools:` array, it is subject to the same `toolCallingMode`, it costs
context in the same way tool definitions always cost context, and — crucially — **it works behind
any model that conforms to the `LanguageModel` protocol**, not just `SystemLanguageModel`. Apple
says so explicitly:

> ✅ **VERIFIED** — `246:44`, verbatim: "Next you'll want to **choose the right model for your app,
> whether it's the `SystemLanguageModel` or a model of your choosing, which you can do using the
> new Model Provider APIs.**"

That sentence is the seam between session 246 and the model-provider work in
[Part 4](../../part-04-beyond-the-built-in-model/README.md). §15 covers what changes when you take
Apple up on it.

**There is no embedding step and no index you own.** The retrieval substrate is the Core Spotlight
index your app already writes to. You do not build it for the LLM; you build it for search, and
the LLM borrows it. This is why §2 is a hard prerequisite rather than a setup step: an app with an
empty Spotlight index gets a tool that returns nothing, cheerfully, forever.

**The model writes the query, not you.** This is the actual novelty. Apple's closing line is not
marketing fluff — it is an accurate description of the programming model:

> ✅ **VERIFIED** — `246:137-138`, verbatim: "we're not writing search queries anymore. We're
> providing the content, and letting intelligence do the rest."

You surrender query construction to the model. Everything difficult in this guide — guidance
profiles, the schema mismatch in §14, pipeline stages — is downstream of that one decision. The
model is generating a structured query object against a schema the framework injects into its
prompt, and every failure mode is either "the schema was too big for the model's context", "the
schema description and the schema disagreed", or "the model declined to generate one at all".

---

## 2. The prerequisite nobody can skip: donating content

> ✅ **VERIFIED** — `246:22-24`, verbatim: "Before we get started, you'll want to make sure your app
> **donates searchable content with Core Spotlight**. […] **Once your app has donated searchable
> items to Core Spotlight, or indexed entities for Apple Intelligence, we're ready to begin.**"

Two on-ramps, then. The classic one is `CSSearchableIndex.indexSearchableItems(_:)`; the other is
App Intents entity indexing via `CSSearchableIndex.indexAppEntities(_:)`. **They write to the same
index** — see §2.4.

### 2.1 The `CSSearchableIndex` path

This code is ✅ **VERIFIED** in the strongest sense available in this corpus: it is copied from a
shipping iOS app's source on disk (`NoemaSpotlightIndexing.swift`), not reconstructed. It shows
the three things that matter — availability gating, domain-scoped replacement, and the attribute
set.

```swift compile:27
import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

struct TrailRecord: Sendable, Hashable {
    let uniqueIdentifier: String
    let title: String
    let contentDescription: String
    let keywords: [String]
}

enum TrailIndexer {
    static let domain = "com.example.trails"

    static func searchableItem(for record: TrailRecord) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = record.title
        attributes.contentDescription = record.contentDescription
        attributes.keywords = record.keywords
        return CSSearchableItem(
            uniqueIdentifier: record.uniqueIdentifier,
            domainIdentifier: domain,
            attributeSet: attributes
        )
    }

    /// Replace an entire domain's worth of items atomically-ish: delete, then index.
    static func replaceDomain(records: [TrailRecord]) async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        await withCheckedContinuation { continuation in
            CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
                let items = records.map(searchableItem(for:))
                guard !items.isEmpty else { return continuation.resume() }
                CSSearchableIndex.default().indexSearchableItems(items) { _ in
                    continuation.resume()
                }
            }
        }
    }
}
```

Two details from that shipping app are worth stealing, because both are the kind of thing you only
learn from a console log:

- **`CSSearchableIndex.isIndexingAvailable()` is a real gate.** Indexing is not always available;
  calling through anyway is a silent no-op.
- **Do not re-donate identical content.** The app keeps a hash of the last successfully donated
  record set per domain and skips the write when it matches, with this comment in the source:
  *"Re-donating identical records churns the OS-side donation translator (repeated
  `LNSpotlightCascadeTranslator` failures in the log) for no gain."* It also debounces donations
  behind a 0.75–1.5 s sleep. If you donate on every model change you will find that log too.

Apple's own sample does two things differently, and both are worth copying:

> ✅ **VERIFIED** — session-246 sample, `Indexer.swift:34-58` and `Indexer.swift:62-88`.
> **A named index, not the default one:** `let index = CSSearchableIndex(name: "TrailSearchSample")`,
> with `index.indexDelegate = self` set in the initialiser. **Batched donation with client-state
> gating**, in the modern async spellings: `index.fetchLastClientState`, `index.beginBatch()`,
> `try await index.indexSearchableItems(items)`, `try await index.endBatch(withClientState:)`.

A named index gives you a donation namespace you own outright — a cleaner teardown story than
domain identifiers on the shared default index, and the form Apple's App Intents documentation also
prescribes for production. The client-state token is the durable version of the hash trick above:
Spotlight remembers what you last successfully wrote, so you can skip a no-op batch without keeping
your own bookkeeping.

> ✅ **VERIFIED** — session-246 sample, `Indexer.swift:180`. **Custom attributes are donated with
> `attributeSet.setValue(NSNumber(value: distance), forCustomKey: key)`**, where `key` is a
> `CSCustomAttributeKey(keyName:searchable:searchableByDefault:unique:multiValued:)`. That key name
> is the thing you later hand to the tool to make the attribute visible to the model — see §13.

### 2.2 The App Intents path

If your content is already an `AppEntity`, you get the second on-ramp for free — and, per Apple
staff, its custom attributes are reachable from this tool:

> ✅ **VERIFIED** — Developer Forums thread **833658**, answer from an **Apple Engineer**, accepted:
> "`IndexedEntity` is backed by a `CSSearchableItem` that can be extended with any additional
> metadata on the item, whether system attributes or custom attributes, and are available for
> in-app search with any of CoreSpotlight's query APIs, **including `SpotlightSearchTool`**."

See §13 for the second half of that answer, which is about how you make the model *aware* of those
custom attributes.

The mechanism behind "indexed entities for Apple Intelligence" is now concrete:

> ✅ **VERIFIED** — Apple documentation, "Making app entities available in Spotlight", plus WWDC26
> session 343 (ch. 11:59). The second on-ramp is **`IndexedEntity` + `CSSearchableIndex.indexAppEntities(_:priority:)`**.
> Adoption is one protocol conformance — verbatim from the docs: *"Adding this protocol to your
> entity's declaration is the only requirement for support."* `IndexedEntity` supplies default
> implementations for every indexed property; you override selectively with
> `@Property(indexingKey: \.textContent)` to bind to an existing Spotlight key, or
> `customIndexingKey:` to bind to a `CSCustomAttributeKey`.

```swift prelude:guide-context
import AppIntents
import CoreSpotlight

@AppEntity(schema: .messages.message)
struct MessageEntity: IndexedEntity {
    @Property(indexingKey: \.textContent)
    var body: AttributedString?
}

try await CSSearchableIndex(name: "AppIntentsTravelTracking_Landmarks")
    .indexAppEntities(landmarkEntities)
```

Note the named index again — Apple's documentation explicitly directs you to use a named index
rather than the default one in production. Reindex requests for entity-indexed content are serviced
by **`IndexedEntityQuery`** (`reindexEntities(for:indexDescription:)` /
`reindexAllEntities(indexDescription:)`) rather than by `CSSearchableIndexDelegate`; session 343
notes you need not implement it if you already use the Core Spotlight APIs directly.

### 2.3 One index, three consumers

This is the architectural point that makes the two on-ramps worth understanding rather than merely
choosing between.

```text
    @AppEntity + IndexedEntity            CSSearchableItem
              │                                  │
   .indexAppEntities(_:)              .indexSearchableItems(_:)
              └──────────────┬───────────────────┘
                             ▼
            Spotlight semantic index  (lexical + semantic)
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
     Siri / Apple      SpotlightSearchTool   Spotlight
     Intelligence      → LanguageModelSession   search UI
     entity resolution
```

> ✅ **VERIFIED** — Apple documentation, Core Spotlight: the index enables *"fast lexical and
> semantic searches"* — word matching and meaning-based retrieval over the **same** index. And on
> the entity side: *"Entity schemas contribute your app's content to the Spotlight semantic index,
> enabling personal context understanding with attribution back to your app."*

**You do not need two indexing paths.** Whichever on-ramp you take, the content lands in one
semantic index that is then read by three different consumers: Siri's entity resolution, your own
model through `SpotlightSearchTool`, and system Spotlight search itself. The practical rule:

| | App Intents on-ramp | Core Spotlight on-ramp |
|---|---|---|
| Unit | `AppEntity` conforming to `IndexedEntity` | `CSSearchableItem` |
| Index call | `CSSearchableIndex.indexAppEntities(_:priority:)` | `CSSearchableIndex.indexSearchableItems(_:)` |
| Attribute mapping | `@Property(indexingKey:)` / `customIndexingKey:` | `CSSearchableItemAttributeSet` directly |
| Reindex servicing | `IndexedEntityQuery` | `CSSearchableIndexDelegate` |
| Also gives you | Siri actionability (with a schema), on-screen annotation targets | nothing beyond search |
| `SpotlightSearchTool` full-item recovery (§7) | 🔴 unverified | ✅ `searchableItems(forIdentifiers:searchableItemsHandler:)` |

Choose the App Intents on-ramp when your content is already modelled as entities — you get Siri for
free. Choose raw `CSSearchableItem` when it is not, which is what Apple's own session-246 sample
does.

> 🔴 **GAP** — that last table row is the one thing still open, and it matters. **Whether
> `CSSearchableIndexDelegate.searchableItems(forIdentifiers:searchableItemsHandler:)` fires for
> entity-indexed content is unverified.** Nothing in Apple's documentation states what identifiers
> arrive at that delegate when the content was written by `indexAppEntities(_:)` rather than
> `indexSearchableItems(_:)`, or whether the delegate is consulted at all on that path. Since §7's
> hydration hook is the entire answer to §6's metadata gap, an app that indexes only via
> `IndexedEntity` may find it has no way to give the model full item bodies — and may need to
> implement **both** paths. Resolving this needs a test app that indexes only via `IndexedEntity`,
> implements the delegate, and puts a signpost in it.

See [16.3 — Entities, Spotlight, and Foundation Models: one index, three
consumers](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md)
for the App Intents side of this story in full.

### 2.4 Where to learn the donation side properly

Session 246 defers the whole donation story to a prior session:

> ✅ **VERIFIED** — `246:23`, verbatim: "Take a look at our past session on '**Supporting semantic
> search with Core Spotlight**', where we talk through **how to donate searchable content to
> Spotlight, how to manage donations with a delegate and reindex extension, and how to perform
> structured search over item attributes, and search against the semantic index.**"

> 🔴 **GAP** — that session (WWDC25) is not in this corpus. Its treatment of the **reindex
> extension** and the **semantic index** is directly relevant, because the semantic index is what
> makes "similarity match" in §10 mean anything. Nothing in this guide should be read as covering
> donation best practice; it covers only what the tool does with donated content.

---

## 3. The cross-import overlay, and the two-line version

`SpotlightSearchTool` is not declared in `FoundationModels`, and it is not declared in
`CoreSpotlight`. It lives in a **cross-import overlay** between them.

> 🟡 **RECONSTRUCTED** — the overlay module name is given as `_CoreSpotlight_FoundationModels` by
> the community field note. The *behaviour* is ✅ **VERIFIED** by both that note and, indirectly,
> by `246:40`: "We'll start by **importing both `CoreSpotlight` and `FoundationModels`**." The
> leading-underscore module name follows Swift's standard cross-import-overlay naming convention,
> which is why I believe it — but nobody in this corpus has read it off a `.swiftinterface`.

> ⚠️ **SILENT FAILURE** — if you import only `FoundationModels`, `SpotlightSearchTool` does not
> exist and you get an "cannot find `SpotlightSearchTool` in scope" error. That one is loud. The
> quiet version is the opposite: in a file that *does* import both, the symbol appears, autocompletes
> and compiles — so a refactor that moves your session setup into a file importing only
> `FoundationModels` breaks the build in a way that reads like a missing SDK rather than a missing
> import. Add both imports to any file that touches the tool; never `@_exported import` your way
> around it.

The minimal adoption is genuinely two lines of tool code. This exact snippet is ✅ **VERIFIED** —
it is the verbatim repro from Developer Forums thread **838904**, written by a developer following
session 246, and it matches `246:41` ("in one line of code, the tool is ready to search your
app's Core Spotlight index"):

```swift compile:27
import CoreSpotlight
import FoundationModels

let tool = SpotlightSearchTool()

let session = LanguageModelSession(tools: [tool])

let response = try await session.respond(to: "What hikes have I gone on?")
```

Read §14 before you ship that, though: on macOS 27 beta 4 this exact snippet is the one that
produces a model-catalog error, and an Apple engineer confirmed it as a bug.

`LanguageModelSession(tools:)` also takes a trailing instructions builder — this form is
✅ **VERIFIED** from the verbatim code in thread 837226:

```swift prelude:guide-context
let session = LanguageModelSession(tools: [tool]) {
    """
    You are a trail journal assistant. Answer only from the user's own indexed hikes. \
    Always call the Spotlight search tool before answering a question about a specific hike.
    """
}
```

Apple's sample uses the plain-parameter form of the same thing, and passes the model explicitly:

> ✅ **VERIFIED** — session-246 sample, `Session.swift:131-137`, verbatim:
>
> ```swift
> private func makeSession(tool: SpotlightSearchTool) -> LanguageModelSession {
>     LanguageModelSession(
>         model: serverModel,
>         tools: [tool],
>         instructions: instructions
>     )
> }
> ```
>
> `instructions:` takes a `String`. Nothing about the tool needs a special session — it is passed
> through the ordinary `LanguageModelSession(model:tools:instructions:)` initialiser, because it is
> an ordinary `Tool`.

Instructions matter more here than with most tools, for a reason that will become obvious in §14:
the model decides *on its own* whether to call this tool, and when it decides not to, it answers
from world knowledge and you get a fluent, confident, completely ungrounded answer.

### 3.1 The instructions template: your index schema *is* the system prompt

The single most transferable thing in Apple's sample is not an API call. It is a **40-line
instructions string** that spends its entire length describing the shape of the index.

> ✅ **VERIFIED** — session-246 sample, `Session.swift:40-82`. The instructions enumerate **every
> indexed attribute with its semantics and its units** — *"rating (difficulty 1 to 5, where 1 is
> Easy…)"*, *"duration (estimated time in seconds)"*, *"distance (trail distance in miles, stored
> as a custom attribute)"* — and then add negative constraints, verbatim:
>
> - *"Always use the spotlight_search tool to search trails before answering. Never answer from
>   memory."* (`Session.swift:43`)
> - *"All trails are indexed with contentType `public.text`. Do not filter by contentType. Use
>   keyword and text predicates instead."*
> - *"Search for the meaningful topic in the request, not generic words like 'trail', 'trails',
>   'hike'…"*
> - *"When searching for a topic, also search for related words. For example, 'water' could also
>   mean lakes, rivers, creeks, waterfalls, ocean, tidepools, or swimming."*
> - *"If the user asks about an attribute that isn't indexed (for example: elevation gain, calories,
>   pace), say plainly that this data is not available rather than inventing values."*

**Retrieval quality lives in the instructions, not in the configuration.** That is the lesson, and
it follows directly from §1's "the model writes the query": a model that does not know what your
index contains cannot write a good query against it. Four moves, in the order Apple uses them:

1. **Describe the schema, with units.** Every attribute you put in `fetchAttributes` (§5.2) should
   appear here with a sentence saying what it means. `rating` is meaningless; "difficulty 1 to 5,
   where 1 is Easy" is a filter the model can actually construct.
2. **Forbid the predicates that will not work.** If every item shares one `contentType`, say so and
   say "do not filter by it" — otherwise the model will spend a query on a partition that has one
   member.
3. **Seed synonyms.** The semantic index does some of this, but an explicit expansion list
   ("water → lakes, rivers, creeks, waterfalls…") is cheap and directly raises recall.
4. **Name the unindexed fields and forbid inventing them.** This is §6.2's hallucination defence
   written as a prompt: the model is told, in advance, which questions it must decline.

Do not read the negative constraints as generic prompt hygiene. Each of them is a specific failure
Apple hit while building the sample, and the "never answer from memory" line is there because the
default behaviour — §14.2 — is to answer from memory.

---

## 4. The trajectory: what actually happens on one `respond`

Apple walks the trajectory explicitly, and it is worth internalising because every debugging
session you have with this tool is a question of "which of these four steps didn't happen".

> ✅ **VERIFIED** — `246:46-47`, verbatim: "It feels like magic, but **the response follows a path
> of tool calling and generation.** For a question like: *What hikes have I gone on?*, the
> trajectory might start with **the model deciding it needs to use `SpotlightSearchTool`**, the
> model will **invoke the tool with a generated query**, **Spotlight will execute that query and
> return a description of the result set back**, and the model will **reason over that output and
> generate its final response.**"

An independently observed transcript, ✅ **VERIFIED** by the community field note running the tool
behind a third-party model on macOS 27 beta (2026-06-13, M4 Max):

```text
prompt → reasoning → toolCall spotlight_search({"searchTerms":["night hike"]})
       → toolOutput (items) → toolCall fetch_note({"id":"note-003"})
       → toolOutput (body) → grounded answer
```

Two facts fall out of that trace that are not in the session:

- The **wire-level tool name is `spotlight_search`** (snake case), not `SpotlightSearchTool`. That
  is what you will see in a `Transcript`, in an Instruments trace, and in any `onToolCall`
  interception, and it is the name you must use when you refer to the tool in your instructions.
  ✅ **VERIFIED** — Apple's session-246 sample writes it into its own instructions text
  (`Session.swift:43`: *"Always use the spotlight_search tool to search trails before answering"*),
  independently corroborated by the community field note's transcript capture — and now
  ✅ **probe-verified 2026-07-31**: `SpotlightSearchTool().name` returns `spotlight_search` at
  runtime (`probes/`, `fm.spotlight-tool-surface`; `includesSchemaInInstructions` reads `true`).
  Since derived tool names are verbatim type names (`fm.tool-derived-name`), this is a *declared*
  name.
- The generated arguments include **`searchTerms: [String]`**. ✅ **VERIFIED** — same note. This is
  one member of a much larger argument schema; see §14.3, where that schema turns out to be the
  source of the tool's worst bug. The full schema is no longer a mystery: the same probe dumped
  `tool.parameters` verbatim — a **complete query DSL** (discriminated `search | schema | help |
  display` queries; `AllText`/`ContentType`/`Application` predicates; temporal models with
  variables and `DateComponents`; pipeline stages including `Compute`, `Count` and `Custom`;
  `x-order` annotations throughout). It is published nowhere else. The beta-4
  **83,494-character** value is preserved in
  [`probes/artifacts/spotlight-tool-schema-simulator-os27.0.0-24A5390f-xcode-27A5228h.txt`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/probes/artifacts/spotlight-tool-schema-simulator-os27.0.0-24A5390f-xcode-27A5228h.txt),
  and the beta-5 **83,570-character** device value in
  [`probes/artifacts/spotlight-tool-schema-device-os27.0.0-24A5408d-xcode-27A5237l.txt`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/probes/artifacts/spotlight-tool-schema-device-os27.0.0-24A5408d-xcode-27A5237l.txt).
  The whole schema drift is one clarified description: `from` now says to omit it on the entry
  query stage and set it only when consuming a prior stage.

**Host/device split, 2026-09-16.** The schema remained exactly 83,570 characters on the upgraded
stable-macOS run. Spotlight donation and cleanup succeeded in the simulator and on the iPhone 15
Pro, but the local Mac host threw `CSIndexErrorDomain -1003` because its helper application was
unavailable. Treat host donation as an environment preflight, not proof that the schema or the
system tool is invalid; retain a device lane for the shipping behavior.

> ⚠️ **Probe-measured 2026-07-31 — direct programmatic `call(arguments:)` is a dead end in this
> beta, and it fails *in-band*, not by throwing.** From the SIM-27 test-runner app container
> (`probes/`, `fm.spotlight-direct-call`): `CSSearchableItem` donation **works**, and
> `tool.searchResults` emits a `SearchReply` (stage token `search`) per call — so the old "needs a
> signed app container" assumption is refuted for donation and observation. But the argument
> decode rejected every programmatic shape tried — a naive `{"query": "…"}`, the exact
> `FullArguments` shape the tool's own error message prescribes, and an order-preserving
> `GeneratedContent(properties:)` build — each returning a **code-100 JSON error inside the Prompt
> output** ("Malformed tool arguments — retry with the schema below"), never a thrown error. Two
> consequences worth designing around: (1) the tool's malformed-argument recovery is a message *to
> the model*, invisible to any `catch`; (2) all three tested programmatic encodings were rejected
> on 27A5228h/24A5390f, while other encodings remain unproven. The deadline-bounded collector
> observed **three replies across the three calls**, but `SearchReply` exposes no call correlation
> ID, so that count does not prove a one-to-one call/reply mapping.
>
> ✅ **DEVICE-REPRODUCED 2026-08-20** — the iPhone 15 Pro / iOS build `24A5408d` run also donated
> and cleaned up successfully, rejected the same three argument encodings in-band with code 100,
> and produced three `.complete` replies before the bounded listener deadline. This closes the
> physical-container residual but not the missing call-correlation issue.

The second `fetch_note` call in that trace is not part of Apple's design — it is the workaround
from §8. Note where it sits in the trajectory: the model got `items` back, found they contained
nothing it could reason over, and reached for a second tool. That is the shape of a correctly
built Spotlight RAG session in 27.0.

---

## 5. `Configuration`: sources, guide, and the two members Apple never uses

Everything you can tune lives on a `Configuration` value passed to the initialiser. Here is the
whole API, from Apple's own code:

> ✅ **VERIFIED** — session-246 sample, `Session.swift:116-158`, verbatim:
>
> ```swift
> private static let fetchAttributes: [SearchableItemAttribute] = {
>     var attributes: [SearchableItemAttribute] = [
>         .title, .contentDescription, .namedLocation, .stateOrProvince,
>         .keywords, .latitude, .longitude, .rating, .duration,
>         .contentCreationDate, .completionDate
>     ]
>     if let key = SpotlightIndexer.distanceAttributeKey {
>         attributes.append(SearchableItemAttribute(rawValue: key.keyName))
>     }
>     return attributes
> }()
>
> private func makeSpotlightTool() -> SpotlightSearchTool {
>     SpotlightSearchTool(
>         configuration: .init(
>             sources: [
>                 .coreSpotlight(
>                     .init(
>                         searchableIndexDelegate: SpotlightIndexer.shared,
>                         fetchAttributes: Self.fetchAttributes
>                     )
>                 )
>             ],
>             guide: isOnDevice ? .focused() : .complete
>         )
>     )
> }
> ```

Read that carefully, because several things in it correct what a transcript reconstruction would
have told you.

**The configuration has five members; Apple's sample reaches for two.** The header has now been
seen — ✅ **SDK-verified**
(`notes/sdk-interfaces/_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface:49-59`):

```swift illustrative
// _CoreSpotlight_FoundationModels overlay — activated by importing both
// CoreSpotlight and FoundationModels. The full memberwise init, defaults included (:58):
public init(
    sources: [SearchSource] = [],
    guide: SpotlightSearchTool.Guide? = nil,
    contactResolver: (any ContactResolver)? = nil,
    customStages: [any CustomStage] = [],
    maximumResponseSize: Int? = nil
)
```

So `contactResolver:` and `customStages:` are real defaulted parameters after all (§11, §12), plus
one member no source in this corpus had ever named: **`maximumResponseSize: Int?`**. The tool
itself takes only `init(configuration: Configuration = Configuration(sources: [.coreSpotlight]))`
(`:384`) — so the bare `SpotlightSearchTool()` defaults to the Core Spotlight source.

**`guide:` is a `Guide?`, and both spellings are real.** The sample's `.focused()` / `.complete`
are `Guide`'s own static members — but a `Guide(level:format:)` memberwise init *also* exists
(`init(level: GuidanceLevel = .complete, format: FormatLevel = .structured)`, `:65-69`), so the
community field note was right about the composite too. See §10.

**The two `.coreSpotlight` labels are one initialiser, not two.** `searchableIndexDelegate:` and
`fetchAttributes:` are passed together in a single `.init(...)`, and the source case takes the
value with a leading dot — you never spell a `CoreSpotlightSource` type name at the call site.

| Member | Shape | Evidence |
|---|---|---|
| `sources` | `[SearchSource]`, default `[]`; statics `.coreSpotlight` / `.coreSpotlight(CoreSpotlightSource)` / `.files` / `.files(FileSource)` | ✅ SDK-verified `:35-44` + ✅ sample `Session.swift:118-125` |
| `guide` | `Guide?`, default `nil`; statics `.complete` / `.focused(_: ContentDomain = .items)` / `.dynamic(GuidanceProfile)`, or `Guide(level:format:)` | ✅ SDK-verified `:65-80` + ✅ sample `Session.swift:126` |
| `contactResolver` | `(any ContactResolver)?`, default `nil` — a protocol, §11 | ✅ SDK-verified `:52`, `:313-315`; still absent from Apple's sample |
| `customStages` | `[any CustomStage]`, default `[]` — instances, not metatypes, §12 | ✅ SDK-verified `:53-56`, `:217-243`; still absent from Apple's sample |
| `maximumResponseSize` | `Int?`, default `nil` — named in no transcript, doc or field note; semantics untested | ✅ SDK-verified `:57` |

### 5.1 The file source

> ✅ **VERIFIED** — `246:42-43`, verbatim: "You can also provide `SpotlightSearchTool` with a
> **custom configuration**. Here we're specifying a **`FileSource`** to perform a search against
> **file paths in your app's sandbox**."

This is the second retrieval substrate: instead of (or as well as) your donated `CSSearchableItem`
graph, the tool can search **files on disk inside your app's sandbox**. For a document-based app
this is often the more natural source — you do not have to mirror your document tree into the
Spotlight index just to make it reachable.

> ✅ **RESOLVED (2026-07-29)** — both spellings were right, because they are two halves of one API.
> The overlay declares a `FileSource` struct **and** a `.files` static on `SearchSource`
> (✅ **SDK-verified**, `_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface:26-31`, `:35-44`):
>
> ```swift
> public struct FileSource : Sendable {
>     public var fetchAttributes: [SearchableItemAttribute]
>     public var maximumResultCount: Int?
>     public var scopes: [URL]                                  // set after init
>     public init(fetchAttributes: [SearchableItemAttribute] = [])
> }
> // SearchSource statics: .coreSpotlight, .coreSpotlight(CoreSpotlightSource),
> //                       .files, .files(FileSource)
> ```
>
> So it takes an **array of URLs**, via the settable `scopes` var rather than the initialiser —
> `.files(FileSource(...))` is exactly the shape the field note's `.files` and Apple's spoken
> "`FileSource`" jointly predicted. No UTType filter exists on the type. Still unverified, because
> **no source in this corpus constructs one** (Apple's sample passes only `.coreSpotlight`):
> whether the files must already be Spotlight-indexed, and whether security-scoped bookmarks work
> outside the sandbox. Those need a running test, not a header.
>
> **Capture note (updated 2026-07-29):** the earlier dump of the parent
> `CoreSpotlight.swiftinterface` was correct to come back empty — the tool-side types live in the
> **`_CoreSpotlight_FoundationModels` cross-import overlay**, a module that activates only when a
> file imports both `CoreSpotlight` and `FoundationModels`, now captured to
> `notes/sdk-interfaces/_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface` (513 lines,
> macOS 27.0 beta). That is why §3's "import both frameworks" rule is load-bearing: with either
> import missing, `SpotlightSearchTool` and every type in this section simply do not exist.

### 5.2 `fetchAttributes` and `SearchableItemAttribute`

`fetchAttributes:` is the list of attributes you are asking the tool to surface to the model. Its
element type is a small `RawRepresentable` struct, and the escape hatch on it is the most important
thing in this section.

> ✅ **VERIFIED** — session-246 sample, `Session.swift:116-131`. **`SearchableItemAttribute`** is a
> `RawRepresentable` struct with static members `.title`, `.contentDescription`, `.namedLocation`,
> `.stateOrProvince`, `.keywords`, `.latitude`, `.longitude`, `.rating`, `.duration`,
> `.contentCreationDate`, `.completionDate` — **and a public `init(rawValue:)`**, which the sample
> uses as `SearchableItemAttribute(rawValue: key.keyName)` to admit a `CSCustomAttributeKey`.

That last clause is the answer to a question §13 asks and cannot otherwise answer: **this is how a
custom attribute reaches the model.** You donate it with
`attributeSet.setValue(_:forCustomKey:)` (§2.1), then you name it in `fetchAttributes` by wrapping
its `keyName` in a `SearchableItemAttribute`. No dynamic guidance required.

```swift illustrative
// The full round trip for one custom attribute, both halves verified against Apple's sample.
static let distanceKey = CSCustomAttributeKey(
    keyName: "distance", searchable: true, searchableByDefault: true,
    unique: false, multiValued: false
)

// At donation time (Indexer.swift:180):
attributeSet.setValue(NSNumber(value: trail.distanceMiles), forCustomKey: Self.distanceKey!)

// At tool-configuration time (Session.swift:127-129):
attributes.append(SearchableItemAttribute(rawValue: Self.distanceKey!.keyName))
```

Then describe it in your instructions — *"distance (trail distance in miles, stored as a custom
attribute)"* — so the model knows what the number means. §3.1.

> ✅ **RESOLVED (2026-07-29) — the complete enumeration exists, and it is large.** The macOS 27.0
> beta CoreSpotlight Swift interface declares `public struct SearchableItemAttribute : Hashable,
> Sendable, RawRepresentable` (`rawValue: String`, public `init(rawValue:)`) with **176
> `public static let` members** covering the breadth of `CSSearchableItemAttributeSet` —
> ✅ **SDK-verified** (`notes/sdk-interfaces/CoreSpotlight-27.0-macos.swiftinterface:19-207`;
> availability `macOS 27.0, iOS 27.0, visionOS 27.0`, no tvOS/watchOS). All eleven of the sample's
> members are in the list (e.g. `.namedLocation:193`, `.latitude:188`, `.rating:118`,
> `.stateOrProvince:184`), alongside everything from `.displayName` and `.textContent` to
> `.mailboxIdentifiers` and `.fontNames`. Autocompletion will show you the rest;
> `init(rawValue:)` remains the escape hatch for custom `kMDItem…`/`CSCustomAttributeKey` names.

Whether `fetchAttributes:` actually changes what the model sees is the subject of the next section,
and the answer as of the 27.0 betas was reported to be "no". Read on before you rely on it.

---

## 6. ⚠️ The metadata gap — the defect that will burn you

This is the section to read if you read no other.

Apple flags the problem themselves, in careful language, one third of the way through the session:

> ✅ **VERIFIED** — `246:49-51`, verbatim: "**You might notice from some responses, that the model
> was not able to see all of the metadata, that was donated for the items. That's because some
> metadata in the Spotlight index, like text content and HTML, is stored in a highly-compact
> representation that can be searched, but not recovered in a way that a language model can read
> it.** For these cases, you'll want to consider **providing additional metadata for an item, while
> `SpotlightSearchTool` is performing a search.**"

Unpack that. The Spotlight index is a **search structure**, not a document store. When you donate
`attributeSet.textContent`, Spotlight builds whatever inverted-index representation makes that text
*findable*. It does not keep a readable copy for you. `textContent` is effectively write-only:
you can match against it, you cannot read it back. That is not new to 27.0 and it is not a bug —
it is what a search index is. What *is* new is that there is now an LLM downstream of it, and an
LLM handed a list of titles will not say "I have insufficient information".

### 6.1 The field measurement: it is worse than Apple said

> ✅ **VERIFIED** — community field note, macOS 27 beta, M4 Max, dated **2026-06-13**, verbatim:
> "Even with `CoreSpotlightSource(fetchAttributes: [.title, .contentDescription, .keywords])`, the
> `toolOutput` handed to the model carries **only identity attributes** — `uniqueIdentifier`,
> `title`, `contentType`, `contentCreationDate`, `domainIdentifier`. **`contentDescription` and
> `keywords` do not appear** (in `.compact` or `.structured`). This is **not** a Spotlight
> limitation: a raw `CSSearchQuery` with the same `fetchAttributes` returns `contentDescription`
> (full body) fine (`textContent` is index-only — write-only for full-text search, returns nil on
> read)."

That control experiment is the important part. `contentDescription` is a *readable* attribute —
a plain `CSSearchQuery` returns it. So the gap is not "Spotlight cannot recover it"; the gap is
**`SpotlightSearchTool` did not put it in the tool output**, even when asked for it via
`fetchAttributes:`. Apple's explanation at `246:50` covers `textContent` and HTML honestly and
does not cover this.

A second, independent report from the Developer Forums says the same thing from a different angle:

> ✅ **VERIFIED** — Developer Forums thread **833651** (developer `bkusserow`, in a post a DTS
> Engineer replied to): "**`CoreSpotlightSource.fetchAttributes` has no effect** on returned
> attributes on the agentic-search path. `kMDItemDescription` only comes back when the in-query
> `SearchArguments.fetchAttributes` lists it."

Two independent observers, one Apple-acknowledged thread, same conclusion on beta builds. But there
is a third data point, and it points the other way:

**Apple's own sample passes eleven attributes to `fetchAttributes:` and depends on them.** Its
instructions describe `rating`, `duration`, `namedLocation`, `stateOrProvince` and a custom
`distance` key to the model as things it can reason about (§3.1), which is only coherent if those
attributes reach the model. And critically, the sample passes `fetchAttributes:` **together with**
`searchableIndexDelegate:` in the same `.init` — the two are one initialiser, not the alternatives
the field note's call site made them look like.

The inference — and it is an inference, marked as such — is that `fetchAttributes:` names *which*
attributes to surface while the **index delegate is what supplies them** (§7), so a configuration
with `fetchAttributes:` and no delegate is exactly the configuration that returns identity
attributes only. That would reconcile all three observations. It is not confirmed by anything.

The safe posture, which costs you nothing either way: **set `fetchAttributes:` and wire the index
delegate, then run the test in §6.3.** If the test passes, you are on Apple's architecture. If it
fails, go to §8.

That second report also names a type — `SearchArguments`, with its own `fetchAttributes` — which
is part of the *model-generated query object*, not part of your configuration. In other words the
model can ask for attributes even when your configuration cannot. Whether you can influence what
the model asks for is exactly what §10 and §13 are about.

> 🟡 **RECONSTRUCTED** — `SearchArguments.fetchAttributes` as a member of the generated query
> schema. The name comes from one developer's reading of the generated JSON Schema in thread
> 833651. Do not write it in source; you never construct this type.

### 6.2 What the failure looks like

> ⚠️ **SILENT FAILURE** — nothing throws. There is no warning, no `nil`, no empty array, no log
> line. The tool call succeeds. The model receives a well-formed list of items. The response is
> fluent, specific, on-topic, and invented.

The field note's example is the clearest illustration in the corpus and it is worth quoting in
full because it shows exactly how *plausible* the fabrication is:

> ✅ **VERIFIED** — community field note, verbatim: "a model answering from search results alone
> sees only TITLES and will hallucinate bodies (the system model, asked about a night hike,
> invented 'rained heavily / pack a waterproof jacket'; the real note said the headlamp died —
> pack spare batteries)."

Both answers are sensible hiking advice. Both are the kind of thing that appears in a trail note.
One of them is in the user's own journal and the other is the model's prior about night hikes.
No automated check you write against the *shape* of the response will separate them. This is why
§16 (evaluations with a result-coverage metric) is not optional polish.

### 6.3 A test that catches it

Ground truth has to come from your own store, not from the model. The minimum viable regression
test is: donate a small corpus containing at least one item whose body says something a language
model would *not* guess, then assert the model reproduces that specific fact.

```swift prelude:guide-context
import Testing
import CoreSpotlight
import FoundationModels

@Test func modelSeesBodiesNotJustTitles() async throws {
    // A fact no prior would produce: the model cannot guess "spare batteries"
    // from the title "Night hike, Mount Tam".
    await TrailIndexer.replaceDomain(records: [
        TrailRecord(uniqueIdentifier: "trail-003",
                    title: "Night hike, Mount Tam",
                    contentDescription: "My headlamp died on the descent. Bring spare batteries.",
                    keywords: ["night", "mount tam"])
    ])

    let tool = SpotlightSearchTool()
    let session = LanguageModelSession(tools: [tool])
    let answer = try await session.respond(to: "What went wrong on my night hike?").content

    #expect(answer.localizedCaseInsensitiveContains("batter"),
            "Model answered without the item body — metadata gap. Got: \(answer)")
}
```

Run that test *before* you build anything on top of the tool. If it fails — and on 27.0 betas it
is reported to fail with a bare `SpotlightSearchTool()` — go to §8, not to your prompt.

---

## 7. `searchableItems(forIdentifiers:searchableItemsHandler:)` — the intended fix, and the conflict

Apple's own answer to §6 is an index-delegate hook.

> ✅ **VERIFIED** — `246:52-57`, verbatim: "If your app donates searchable content to Core
> Spotlight, you'll already be familiar with the **index delegate protocol**. Your app would set an
> index delegate on your **`CSSearchableIndex`** to handle reindex requests, such as when Spotlight
> needs to perform migration or recovery. **For `SpotlightSearchTool`, we've added a method to the
> delegate to recover the full `CSSearchableItem` by its unique identifier.** This allows the model
> to **efficiently manage responses over potentially millions of results**. On your index delegate,
> simply adopt the new **`searchableItems(forIdentifiers:)`** to return the complete
> `CSSearchableItem`. **If your app has metadata that doesn't make sense to donate for search, but
> might be useful for the model to reason about, this is the right time to set any additional
> attributes on an item for the model to see.**"

The design intent is elegant and worth stating plainly, because it explains *why* the tool is
built this way:

1. Spotlight searches millions of items and produces identifiers cheaply.
2. Only the small set that survives ranking gets hydrated, by calling back into your app.
3. Hydration is *your* code, so you can attach attributes you would never want in a search index —
   a computed summary, a privacy-sensitive field, a relationship the model needs but search does
   not. "**this is the right time to set any additional attributes on an item for the model to
   see**" is an invitation to build a model-only view of your data.

That is a genuinely good retrieval architecture. Here is the exact signature:

> ✅ **VERIFIED** — session-246 sample, `Indexer.swift:123-128`, verbatim:
>
> ```swift
> nonisolated func searchableItems(forIdentifiers identifiers: [String], searchableItemsHandler: @escaping @Sendable ([CSSearchableItem]) -> Void) {
>     Task { @MainActor in
>         let items = createSearchableItems(identifiers: identifiers)
>         searchableItemsHandler(items)
>     }
> }
> ```
>
> The full spelling is **`searchableItems(forIdentifiers:searchableItemsHandler:)`**. It is
> **`nonisolated`**, it is **not `async` and does not `throw`**, the parameter is a plain
> `[String]`, and it **returns `Void` through an `@escaping @Sendable ([CSSearchableItem]) -> Void`
> completion handler** rather than returning an array.

Three consequences of that shape, none of them obvious:

**It is `nonisolated`, so you hop yourself.** The framework calls it off the main actor. Apple's own
code immediately opens `Task { @MainActor in … }` because its store is main-actor-isolated. If
yours is not, do not add the hop — but do not assume you are on the actor you think you are.

**Because it is a completion handler and not `async`, the framework has no way to await you.** You
own the deadline. Never call an unbounded network or disk operation in here; hydration sits on the
critical path of a tool call the user is waiting on.

**The handler must be called exactly once, on every path.** Including the empty path. This is the
one that bites:

> ⚠️ **SILENT FAILURE** — an early `return` that skips `searchableItemsHandler(...)` — a `guard`
> on a missing store, a thrown error you swallow, an identifier you do not recognise — leaves the
> framework waiting for a callback that never arrives. There is no error, no timeout you can see,
> and no compiler warning: the completion handler is not `@discardableResult`-style enforced by
> anything. Your search either hangs or silently degrades to identity attributes. Call the handler
> with `[]` rather than not calling it.

```swift prelude:guide-context
import CoreSpotlight

final class TrailIndexDelegate: NSObject, CSSearchableIndexDelegate {

    let store: TrailStore

    init(store: TrailStore) { self.store = store }

    // Required by the protocol, pre-existing, unrelated to the LLM path.
    func searchableIndex(_ index: CSSearchableIndex,
                         reindexAllSearchableItemsWithAcknowledgementHandler ack: @escaping () -> Void) {
        Task { await TrailIndexer.replaceDomain(records: store.allRecords()); ack() }
    }

    func searchableIndex(_ index: CSSearchableIndex,
                         reindexSearchableItemsWithIdentifiers identifiers: [String],
                         acknowledgementHandler ack: @escaping () -> Void) {
        Task { await TrailIndexer.reindex(identifiers: identifiers); ack() }
    }

    // The hydration hook. Signature ✅ VERIFIED against Apple's sample.
    nonisolated func searchableItems(
        forIdentifiers identifiers: [String],
        searchableItemsHandler: @escaping @Sendable ([CSSearchableItem]) -> Void
    ) {
        Task { @MainActor in
            let items = identifiers.compactMap { id -> CSSearchableItem? in
                guard let trail = store.trail(id: id) else { return nil }
                let attrs = CSSearchableItemAttributeSet(contentType: .text)
                attrs.title = trail.name
                attrs.contentDescription = trail.notes        // ← the body the model needs
                // Model-only enrichment: never donated for search, only ever seen here.
                attrs.keywords = trail.computedThemes
                return CSSearchableItem(uniqueIdentifier: id,
                                        domainIdentifier: TrailIndexer.domain,
                                        attributeSet: attrs)
            }
            searchableItemsHandler(items)     // always call it — even with []
        }
    }
}
```

Wire it in two places — on the index itself, and on the tool's source. Apple's sample makes the
indexer a singleton precisely so that the same object can be both:

```swift prelude:guide-context
// Indexer.swift:34-58 — the sample's shape, condensed.
@MainActor
final class SpotlightIndexer: NSObject, CSSearchableIndexDelegate {
    static let shared = SpotlightIndexer()
    let index = CSSearchableIndex(name: "TrailSearchSample")

    private override init() {
        super.init()
        index.indexDelegate = self          // half one: reindex/recovery
    }
}

let tool = SpotlightSearchTool(configuration: .init(
    sources: [
        .coreSpotlight(.init(
            searchableIndexDelegate: SpotlightIndexer.shared,   // half two: LLM hydration
            fetchAttributes: Self.fetchAttributes
        ))
    ],
    guide: isOnDevice ? .focused() : .complete
))
```

### 7.1 The conflict — and it is a real one

Three sources disagree about this method, and the disagreement is not cosmetic.

| Source | Tier | Claim |
|---|---|---|
| **Session-246 sample, `Indexer.swift:123-128`** | **1** | Apple's own reference app implements `searchableItems(forIdentifiers:searchableItemsHandler:)` and wires the same object as `searchableIndexDelegate:`. This is the sanctioned architecture. |
| `246:54-56` | 4 | "**we've added** a method to the delegate" — i.e. new in 27.0, for this tool |
| Community field note, 2026-06-13 | 5 | "`searchableItems(forIdentifiers:)` (**macOS 15.4+**, with a **new `protectionClass` overload in 27.0**) is the **index-recovery hydration API — not the search-time body path**" |
| Forums thread **833651** | 3 | "`searchableIndexDelegate` **was never invoked in any configuration tried (including `.dynamic`)**" |

Read together: the method **pre-dates this release** (it exists for index recovery, back to macOS
15.4), so `246:54`'s "we've added" is loose — what is new is the *use* the tool makes of it, and
possibly an **overload taking a `protectionClass`**. In two independent 27.0-beta tests the delegate
was **not called during a tool search at all**.

**Which do I believe?** The sample settles the *design* question completely: this is the path Apple
ships, so build for it. It does not settle the *behaviour* question — a sample project compiling is
not the same as a delegate firing, and the sample contains no assertion that it does. So:

> ⚠️ **SILENT FAILURE** — implementing `searchableItems(forIdentifiers:searchableItemsHandler:)`
> and wiring it through `.coreSpotlight(.init(searchableIndexDelegate:…))` compiles, links, and
> runs. If the framework never calls it, **nothing tells you.** Your delegate method simply has a
> breakpoint that never hits. Put a `print` or a signpost in it and check that it fires before you
> build a hydration strategy on top of it.

> 🔴 **GAP** — **current status unknown.** The behavioural observations are beta-era (the field note
> is 2026-06-13 macOS 27 beta; thread 833651 is from the WWDC26 Q&A window), and Apple's sample
> shows intent rather than a measurement. What would resolve this: run the delegate-instrumented app
> on a current 27.0 build and see whether `searchableItems(forIdentifiers:searchableItemsHandler:)`
> is invoked during a `SpotlightSearchTool` search, and whether the attributes you set there reach
> the model. Nobody in this corpus has done that on a post-beta build. **Do this measurement
> yourself before designing around either answer.**

> 🔴 **GAP** — the 27.0 `protectionClass` overload. The field note names it; nothing describes its
> signature, its parameter type (presumably a `CSSearchableItem` data-protection class), or when
> the framework picks the new overload over the old one. What is now known is that **Apple's own
> sample adopts only the non-`protectionClass` spelling** and evidently works, which is the
> strongest available argument that the plain form is the one to implement. Resolving this fully
> needs the `CoreSpotlight` headers from the Xcode 27 SDK.

---

## 8. The retrieve-then-hydrate pattern that works today

Given §6 and §7, the pattern that is *verified working* on 27.0 betas is not Apple's. It is a
two-tool composition: Spotlight retrieves identifiers, your own tool fetches bodies.

> ✅ **VERIFIED** — community field note, macOS 27 beta / M4 Max / 2026-06-13, verbatim: "The model
> chains `spotlight_search` → ids/titles → `fetch_note(id)` → body → grounded answer. This mirrors
> a real app (**Spotlight index = lightweight finding aid; full content = your store**). **Verified
> on the system model, zoo qwen3.5-0.8B, and qwen3-4B.**"

Three models, including Apple's own. That is the strongest empirical claim in the whole Spotlight
corpus.

```swift prelude:guide-context
import CoreSpotlight
import FoundationModels

/// Hydrates a Spotlight hit into the text the model actually needs.
struct FetchTrailNoteTool: Tool {
    let name = "fetch_note"
    let description = "Read the full saved text of a trail note by its identifier."

    let store: TrailStore

    @Generable
    struct Arguments {
        @Guide(description: "The trail id returned by spotlight_search, like trail-003.")
        var id: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let trail = store.trail(id: arguments.id) else {
            return "No note found for id \(arguments.id)."
        }
        return """
        Title: \(trail.name)
        Date: \(trail.completedOn.formatted(date: .abbreviated, time: .omitted))
        Notes: \(trail.notes)
        """
    }
}

let spotlight = SpotlightSearchTool(configuration: .init(
    sources: [.coreSpotlight(.init(searchableIndexDelegate: delegate,
                                   fetchAttributes: [.title, .contentDescription]))],
    guide: .focused()
))

let session = LanguageModelSession(tools: [spotlight, FetchTrailNoteTool(store: store)]) {
    """
    You help the user recall their own hikes. \
    First call spotlight_search to find matching trails. \
    The search returns identifiers and titles only — it does NOT return note text. \
    You MUST call fetch_note with the identifier of each relevant result before \
    describing what happened on a hike. Never describe a hike you have not fetched.
    """
}

let answer = try await session.respond(to: "What did I write about the night hike?")
```

Four things in that snippet are doing real work:

**The instructions state the tool's limitation explicitly.** "The search returns identifiers and
titles only" is not decoration — it is the only thing standing between you and §6.2. The model
does not know its retrieval tool is lossy unless you tell it.

**`description` on the fetch tool names the *source* of the id.** "The trail id returned by
`spotlight_search`" teaches the chain. Note the snake-case wire name from §4, not the Swift type
name — that is what the model sees.

**Ordering.** `[spotlight, FetchTrailNoteTool(...)]` — tool specs are serialised into the prompt in
order, and the retrieval tool coming first reads as the natural first step.

**Never describe a hike you have not fetched.** A blunt instruction, and the one most likely to be
ignored under context pressure. Verify it with an evaluation (§16), not by reading responses.

### 8.1 The cost

This pattern costs one extra round trip per item the model wants to read, and each round trip is
a full decode turn. On the on-device model that is the dominant latency term in the whole feature.
Mitigations, in order of how much I trust them:

- **Return several items per call.** Change `Arguments` to `var ids: [String]` and let the model
  batch. Same schema cost, one round trip.
- **Truncate hard in `call`.** You control the string. A 4K context does not survive five full
  trail journals; return the first ~400 characters plus a marker, and let the model ask for more.
- **Consider whether the answer needs bodies at all.** "How many hikes did I do in June" needs
  counts, not text — see §12.

---

## 9. Consuming results: two channels, `searchResults`, and `queryToken`

The session's `respond` gives you prose. That is the right thing to show in a chat bubble and the
wrong thing to show in a list.

> ✅ **VERIFIED** — `246:58-63`, verbatim: "**The session response is a concise description over the
> result set.** And in an assistant-style interface, **this response is typically what an app would
> want to display.** But **search results are also available directly on `SpotlightSearchTool`
> itself. For a list-style display, this is the best way to access searchable items, especially
> when the result set is large.** **Search replies pass back results in batches during the search,
> so query tokens can be used to manage the conversation stream, ensuring that user interface
> stays up-to-date with the model.**"

> ✅ **VERIFIED** — `246:64-65`, verbatim: "To access results from the `SpotlightSearchTool`, your
> app can **wait for search replies and check for `CSSearchableItem` in the content of the reply.
> Search replies come as an async sequence of events, where each reply may include a batch of
> results, until the tool call completes.**"

This is the pattern Apple's sample is really built around, and it deserves a name.

### 9.1 The two-channel results pattern

**A `SpotlightSearchTool` turn produces two outputs at once, on two independent channels.** The
session's response stream carries *prose* — the model's narration of what it found. The tool's
`searchResults` stream carries *objects* — the actual `CSSearchableItem`s the search touched. You
consume both, in parallel, and you bind your UI to the second one.

The consequence is the thing worth internalising: **you never parse the model's text to find out
which records it used.** No regex over the answer, no asking the model to emit identifiers, no
`@Generable` wrapper around a list of IDs. The record identity comes back over a side channel that
the model cannot corrupt, while the model does the one job it is good at — writing the sentence
that explains the result set.

That generalises well past Spotlight: **any retrieval tool you write should publish its hits on a
side channel and let your list view bind to that**, rather than round-tripping structured data
through the language model. It is cheaper, it cannot hallucinate, and it survives a model that
decides to answer in a different format today.

### 9.2 Why `queryToken` exists

This is the part people miss, and it is stated in one sentence:

> ✅ **VERIFIED** — `246:66-67`, verbatim: "**Keep in mind that for any given response, the model
> may call `SpotlightSearchTool` MORE THAN ONCE, before generating its final response. For that
> reason, use the `queryToken` on each reply, to determine when the user interface should
> refresh.**"

Think about what that means for a naïve consumer. You subscribe to the stream and append every
item you see to an array bound to a `List`. The user asks "which trails did I hike in June, and
which of those had good weather?" The model, reasonably, issues two searches. Your list now
contains the union of two different result sets with no boundary between them, and the user sees
June's hikes interleaved with weather matches as though they were one ranked answer.

The `queryToken` is the boundary marker. It identifies *which tool call* a batch belongs to. The
rule is: **items with the same token accumulate; a new token means start a new list.**

There is a second, subtler reason it matters. Because replies arrive *during* the search, your UI
can populate progressively — which is the entire point of a batched stream — but progressive
population is only coherent within one query. Without the token you cannot tell "three more
results for the question I'm already showing" from "the model changed its mind and is asking
something else".

### 9.3 Consuming the stream

Here is Apple's consumer, in full. It is 20 lines and it is the whole pattern.

> ✅ **VERIFIED** — session-246 sample, `Session.swift:160-181`, verbatim:
>
> ```swift
> private func listenForSearchResults(from tool: SpotlightSearchTool) -> Task<Void, Never> {
>     Task { @MainActor in
>         var seen: Set<String> = []
>         for await reply in tool.searchResults {
>             let items: [CSSearchableItem]
>             switch reply.content {
>             case .items(let searchItems):
>                 items = searchItems.map(\.item)
>             case .scoredItems(let scored):
>                 items = scored.map(\.item.item)
>             case .groupedItems(let groups):
>                 items = groups.values.flatMap { $0 }.map(\.item)
>             case .count, .table, .statistic, .text:
>                 continue
>             @unknown default:
>                 continue
>             }
>             let newItems = items.filter { seen.insert($0.uniqueIdentifier).inserted }
>             self.results.append(contentsOf: newItems)
>         }
>     }
> }
> ```

Four things are now settled that this guide previously had to guess at:

**`reply.content` is an enum with seven cases, and it is non-frozen.** `.items`, `.scoredItems`,
`.groupedItems`, `.count`, `.table`, `.statistic`, `.text` — plus `@unknown default`, which the
compiler will require you to write. ✅ VERIFIED. The list matches the field note's member list
exactly, so that note is now upgraded from "a list of members" to "the case list".

**The payloads are wrapped, and the nesting depth differs per case.** `.items` yields elements with
a `.item` property (→ `CSSearchableItem`); `.scoredItems` yields elements with `.item.item`, because
the score wrapper wraps the item wrapper; `.groupedItems` yields a **dictionary**, hence
`groups.values.flatMap { $0 }.map(\.item)`. Writing `items.append(contentsOf: batch)` on a `.items`
payload will not compile — you need the `.map(\.item)`.

**De-duplication is the app's job.** The model may call the tool more than once in a single turn
(§9.2), and the same item can legitimately appear in two result sets. Apple keeps a
`Set<String>` of `uniqueIdentifier`s and filters against it.

**The consumer runs as a detached `Task` alongside the response.** `listenForSearchResults` returns
the `Task` so the caller can cancel it; it is started *before* `respond`/`streamResponse` and
cancelled after. Both channels are live at once — that is what makes §9.1 work.

> ✅ **VERIFIED** — session-246 sample, `Session.swift:96-112`, from the sample's own comment:
> *"Creates a fresh session and tool for each search so that every query starts with fresh
> context."* **One tool instance per query**, because the tool accumulates results.

That last point corrects the obvious instinct. The tool must outlive a single `respond` call — you
cannot construct it inline and still iterate it — but it should **not** outlive the query:

> ⚠️ **SILENT FAILURE** — the tool instance is the stream, and it is also the accumulator. Two
> mistakes sit either side of the right answer, and neither reports anything.
> **Too short:** constructing `SpotlightSearchTool()` inline inside
> `LanguageModelSession(tools: [SpotlightSearchTool()])` leaves you with no reference to iterate
> `searchResults` on. No error, no warning, no compiler complaint — you simply never see a result.
> **Too long:** holding one tool for the life of the view and reusing it across queries means the
> second query's results arrive on a stream still carrying the first query's, and your
> `uniqueIdentifier` de-duplication will *suppress* legitimate repeats rather than clean them up.
> Apple's answer is to build a fresh tool and a fresh session per query and cancel the listener
> task when the query ends.

```swift compile:27
import SwiftUI
import CoreSpotlight
import FoundationModels

@MainActor
@Observable
final class TrailSearchResults {
    private(set) var items: [CSSearchableItem] = []
    private(set) var label: String?          // LLM-generated, see §12.3
    private var seen: Set<String> = []
    private var listener: Task<Void, Never>?

    /// Call once per query, with a freshly built tool.
    func begin(observing tool: SpotlightSearchTool) {
        listener?.cancel()
        items.removeAll(); seen.removeAll(); label = nil

        listener = Task { @MainActor in
            for await reply in tool.searchResults {
                label = reply.label ?? label      // 🟡 `label` is field-note-attested, see below
                let batch: [CSSearchableItem]
                switch reply.content {
                case .items(let searchItems):   batch = searchItems.map(\.item)
                case .scoredItems(let scored):  batch = scored.map(\.item.item)
                case .groupedItems(let groups): batch = groups.values.flatMap { $0 }.map(\.item)
                case .count, .table, .statistic, .text: continue
                @unknown default: continue
                }
                items.append(contentsOf: batch.filter { seen.insert($0.uniqueIdentifier).inserted })
            }
        }
    }

    func end() { listener?.cancel(); listener = nil }
}
```

```swift prelude:guide-context
struct TrailChatView: View {
    @State private var results = TrailSearchResults()

    var body: some View {
        List(results.items, id: \.uniqueIdentifier) { item in
            VStack(alignment: .leading) {
                Text(item.attributeSet.title ?? "Untitled")
                if let subtitle = item.attributeSet.contentDescription {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(results.label ?? "Results")
    }

    func search(_ question: String) async throws -> String {
        let tool = makeSpotlightTool()               // fresh per query — §9.3
        let session = makeSession(tool: tool)
        results.begin(observing: tool)
        defer { results.end() }
        return try await session.respond(to: question).content
    }
}
```

> ✅ **SDK-verified (2026-07-29)** — `reply.label` and `reply.queryToken` are real members, and there
> are two more. `SearchReply` carries `content`, `label: String?` (yes, `Optional` — keep the
> fallback), `queryToken: SearchReply.QueryToken` (`Hashable` — the §9.2 boundary logic is
> mechanically supported), `stageToken: SearchReply.StageToken` (also `Hashable`, correlating
> pipeline-stage output, §12.3), and `status: Status` — an enum of `.partial` / `.complete`, which
> is per-reply progress signalling no source in this corpus had named
> (`_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface:341-379`). **Apple's sample still uses
> none of them** — it reads only `reply.content` and de-duplicates by identifier.

> 🟠 **Measured on Simulator and device; termination semantics remain open.** The overlay interface
> answers the *type* half: `searchResults` is
> `some AsyncSequence<SearchReply, Never>` (`:381-383`) — it can never throw, but an opaque
> `AsyncSequence` alone says nothing about whether it ever *finishes*. The simulator probe
> (`probes/` `fm.spotlight-direct-call`) kept one listener alive across three direct calls and
> observed three replies before its
> deadline; the sequence therefore did not terminate after the first or second call. It still did
> not terminate after the final call before the collector deadline. Because replies carry no call
> correlation ID, the observation cannot establish a one-to-one mapping, and per-reply
> `status == .complete` is not sequence termination. The iPhone 15 Pro run on 2026-08-20 reproduced
> the same three-reply/non-terminating observation.
> **Safe default:** adopt Apple's per-query lifetime — construct a fresh tool per request and
> cancel the listener `Task` when the call ends — so nothing you ship depends on the answer.

---

## 10. Guidance: `.focused()`, `.complete`, `GuidanceProfile`, and the token gate

The tool is much bigger than it looks. What it hands the model is not "a search box" but a whole
query language.

> ✅ **VERIFIED** — `246:68`, verbatim: "`SpotlightSearchTool` provides a **host of search
> capabilities, from semantic search over text, to structured search over metadata, like dates,
> persons, locations and more.**"

> ✅ **VERIFIED** — `246:74-75`, verbatim: "`SpotlightSearchTool` provides its **entire set of
> search capabilities** to a model for guided generation. But **guidance profiles can help scope
> that guidance to only what an app needs.**"

"Entire set of search capabilities … for guided generation" means: the framework serialises a
description of every capability into the model's prompt. **That description is tokens, and those
tokens come out of your context window.**

### 10.1 The number that decides your architecture

> ✅ **VERIFIED (community-measured)** — community field note, **macOS 27 beta, Apple M4 Max,
> 2026-06-13**, verbatim: "**Guidance level is a token gate.** **`.complete` guidance injects ~13 k
> tokens of tool instructions → instant `contextSizeExceeded` on any 4 k-context model (system or
> zoo). Ship `.focused(.items)` + `format: .compact` for local models.** **`.dynamic(GuidanceProfile)`
> was prompt-sensitive in testing (a model skipped the search and hallucinated) — use
> deliberately.**"

> **Attribution.** ~13,000 tokens is **community-measured**, not Apple-published. One observer, one
> machine, one beta build, one date. Apple has published no figure. Treat the *order of magnitude*
> as real and the digits as indicative, and measure your own with `SystemLanguageModel.default`'s
> token-counting API before you trust it. What is not in doubt is the direction: complete guidance
> is several times the size of a 4K context window. (That note's spellings — `.focused(.items)`,
> `format: .compact` — are now ✅ SDK-verified real API, §10.2; the *measurement* stands too.)

Apple states the same conclusion qualitatively, and it is the single most actionable sentence in
the session:

> ✅ **VERIFIED** — `246:80`, verbatim: "**On-device models have a more restricted model context
> size, so it's best to use FOCUSED guidance for simpler search capabilities.**"

Apple's sample encodes exactly that rule as a one-line ternary, which is the most compact statement
of the whole section:

> ✅ **VERIFIED** — session-246 sample, `Session.swift:126`, verbatim:
> `guide: isOnDevice ? .focused() : .complete`

**Guidance level is a function of model capacity, and nothing else.** The sample does not tune it
per feature, per query or per user; it asks one question — is this running on the device model or
the server model — and branches.

| Backing model | Context | Guidance |
|---|---|---|
| `SystemLanguageModel` (on-device) | ~4K (do not hardcode — read `contextSize`) | `.focused()` |
| A local 4B-class model behind `LanguageModel` | typically 4K–8K | `.focused()` |
| `PrivateCloudComputeLanguageModel` | 32K | `.complete` is affordable — but still costs ~40% of your window |

> ⚠️ **SILENT FAILURE** — this one does throw, which makes it the friendliest bug in the guide,
> but the *diagnosis* is silent. `LanguageModelError.contextSizeExceeded(_:)` (✅ VERIFIED, Apple
> docs: "If your session exceeds the available context size, it throws
> `LanguageModelError.contextSizeExceeded(_:)`") does not say *what* filled the window. A developer
> whose prompt is 80 tokens and whose session blows the context on the first turn will look
> everywhere except at the tool's own guidance text. If you add `SpotlightSearchTool` and
> immediately start overflowing, the tool's guidance is the first suspect, not the last.

### 10.2 The `guide:` values

> ✅ **VERIFIED** — session-246 sample, `Session.swift:126`. `guide:` takes a value with **at least
> two members**: **`.focused()`** — written *with* parentheses, so it has one or more parameters
> that all have defaults — and **`.complete`**, written without, so it is a plain static member.
> The two appear in the arms of one ternary, so they are the same type.

```swift illustrative
// Maximum capability, maximum tokens. PCC or a large local model only.
SpotlightSearchTool(configuration: .init(sources: […], guide: .complete))

// The on-device default you should start from.
SpotlightSearchTool(configuration: .init(sources: […], guide: .focused()))
```

Both shapes turn out to be real, and the earlier correction to the field note was wrong.
✅ **SDK-verified** (`_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface:65-104`):
`SpotlightSearchTool.Guide` is a struct of `level: GuidanceLevel` and `format: FormatLevel`, with
**both** a memberwise `init(level: GuidanceLevel = .complete, format: FormatLevel = .structured)`
and the statics Apple's sample uses — `.complete`, `.focused(_ domain: ContentDomain = .items)`,
`.dynamic(_ profile: GuidanceProfile)` (`:74-80`). `GuidanceLevel` is an enum with the same three
cases; `FormatLevel` is `.structured` / `.compact` (`:85-104`). So `Guide(level:format:)` from the
June field note compiles today — the sample's `.focused()` is simply the sugar that leaves
`format:` at its `.structured` default. If this guide previously told you to change a
`Guide(level:format:)` call site, un-change it.

> ✅ **RESOLVED (2026-07-29)** — **what `.focused()` takes: a `ContentDomain`, defaulting to
> `.items`.** The field note's `.focused(.items)` was exact. `ContentDomain` offers `.audio`,
> `.calendar`, `.communications`, `.documents`, `.items`, `.visualMedia` — each as a bare static
> and as a function taking a per-domain config struct (e.g. `.calendar(Calendar(organizer:
> attendees:location:date:))`) whose fields are all `[SearchableItemAttribute]?`
> (✅ **SDK-verified**, `:109-198`). The types were not in the earlier parent-framework capture
> because they live in the `_CoreSpotlight_FoundationModels` overlay (§5.1's capture note).

> ✅ **RESOLVED (2026-07-29)** — **the third member exists: `.dynamic(GuidanceProfile)`**, both as a
> `GuidanceLevel` case and as a `Guide` static (✅ **SDK-verified**, `:79`, `:102`). Apple's sample
> still uses only `.complete` and `.focused()`. See §10.3.

### 10.3 `GuidanceProfile` — surgical scoping

Apple's worked motivation:

> ✅ **VERIFIED** — `246:76-79`, verbatim: "The hiking trails app **doesn't donate person
> relationships**, so **guiding the model on how to search for authors and recipients, could be
> skipped for limited-context models.** To selectively enable guidance on search capabilities like
> **people and dates**, use a **`GuidanceProfile`**. **You can even specify the exact list of
> metadata attributes, that the model should consider during a search.** Then set a **dynamic guide
> level** using the profile, when creating `SpotlightSearchTool`."

The reasoning is precisely the reasoning behind trimming any prompt: capability descriptions the
model can never usefully act on are pure context tax, and worse, they are a *distraction* — a model
told it can filter by recipient will sometimes try to, against an index that has no recipients.

> ✅ **SDK-verified (2026-07-29)** — the field note's labels were exact, and the type ships. The
> overlay declares
> `GuidanceProfile(textMatch:similarityMatch:numericMatch:dates:people:contentType:attributes:)`
> with **every capability flag an optional `Bool?` defaulting to `nil`** — tri-state, not the
> guessed plain `Bool`: `nil` presumably means "framework default", not "off" — and
> `attributes: [SearchableItemAttribute]? = nil`, the *same* element type as `fetchAttributes`
> (`_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface:203-212`). That last fact closes
> §13's question about custom attributes: `SearchableItemAttribute(rawValue:)` works here too.
> What remains unverified is behavioural: **`GuidanceProfile` still appears nowhere in Apple's
> session-246 sample**, and §10.4's prompt-sensitivity warning stands.
>
> For custom attributes specifically there is still a simpler verified alternative —
> `fetchAttributes` plus `SearchableItemAttribute(rawValue:)`, §5.2. Prefer it for *visibility*;
> use the profile only when you need *guidance*.

```swift prelude:guide-context
// ✅ labels and types SDK-verified; every parameter is optional with a nil default.
let profile = GuidanceProfile(
    textMatch: true,          // literal / keyword matching over indexed text
    similarityMatch: true,    // the semantic index — needs semantic donation, see §2.4
    numericMatch: false,      // no numeric attributes donated for trails
    dates: true,              // completion dates are the whole point
    people: false,            // this app donates no person relationships
    contentType: false,       // one content type only; nothing to disambiguate
    attributes: [.title, .contentCreationDate, .keywords]
)

let tool = SpotlightSearchTool(configuration: .init(
    sources: [.coreSpotlight(.init(searchableIndexDelegate: delegate,
                                   fetchAttributes: Self.fetchAttributes))],
    guide: .dynamic(profile)          // ✅ SDK-verified static — §10.2
))
```

### 10.4 The catch: `.dynamic` is prompt-sensitive

Trimming guidance is not free. From the same field note (community-measured, macOS 27 beta,
2026-06-13): **"`.dynamic(GuidanceProfile)` was prompt-sensitive in testing (a model skipped the
search and hallucinated) — use deliberately."**

There is a coherent mechanism behind that. Tool guidance is not only *instructions for how to
search*; it is also the strongest signal in the prompt that searching is a thing the model should
do. Cut it aggressively and you weaken the cue. This is the same failure as thread 837226 in
§14.2, arrived at from a different direction, and it has the same mitigation: state the
requirement in your instructions, and if that fails, force it with `toolCallingMode`.

The honest ordering for adoption:

1. Start at `.focused()`. Measure that it works. This is what Apple ships.
2. Move to `.dynamic(profile)` only if you need a capability `.focused()` does not expose, or you
   need the tokens back — and be aware you are then off the path Apple's own sample walks.
3. Whenever you change guidance, re-run your evaluation suite (§16). A guidance change is a
   behavioural change to the model's decision to search at all, not a performance tweak.

---

## 11. Reference resolution and the contact resolver

> ✅ **VERIFIED** — `246:81-85`, verbatim: "**Reference resolution** is another way for your app to
> provide **context that's not directly available in the search index.** As an example, if the
> hiking trails app **did** donate person relationships, the person using the app might want to
> **ask about other participants on the trail**. In that case, **the model needs to know who *that
> person* refers to in a prompt. If the app already knows who that person is, use a
> `contactResolver` to help the tool filter to the right set of results.** **A `contactResolver`
> should return any contact information related to the user's identity, that can be matched against
> metadata in the search index.**"

The problem it solves is deixis. A user says "the hike I did with my sister" or "the notes Jamie
sent me". Your index stores contact identifiers, email addresses, handles — not "my sister". The
model cannot bridge that gap from the prompt alone, and it has no business guessing.

Note what Apple actually says the resolver returns: "**any contact information related to the
user's identity**". That is narrower than a general people-lookup service. It is about resolving
*self* and the user's known relationships into index-matchable values, so that the tool can filter
rather than the model inventing a name.

> ✅ **RESOLVED (2026-07-29)** — the `_CoreSpotlight_FoundationModels` interface has been captured,
> and every open question has a small answer. `contactResolver` is a shipping `Configuration`
> label, `(any ContactResolver)? = nil` (`:52`, `:58`). The type is a **protocol**, it is
> **synchronous**, it is passed **nothing**, and it returns a dedicated struct
> (✅ **SDK-verified**, `_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface:313-326`):
>
> ```swift
> public protocol ContactResolver : Sendable {
>     func userIdentity() -> ResolvedContact
> }
> public struct ResolvedContact : Sendable {
>     public var displayName: String
>     public var names: [String]
>     public var nameComponents: [PersonNameComponents]
>     public var emailAddresses: [String]
>     public var phoneNumbers: [String]
>     public init(displayName: String)
> }
> ```
>
> Note how much that shape confirms the reading above: the one requirement is `userIdentity()` —
> no prompt string comes in, no general people lookup goes out. It resolves **self**, as a bundle
> of index-matchable values, exactly as `246:84-85` described. **There is still no example of a
> constructed contact resolver anywhere in this corpus** — not in Apple's session-246 sample either
> — so how the tool actually *uses* the returned values against the index remains untested.

Even with the type verified, the practical substitute below is still boring and still works:
resolve the reference yourself before the prompt reaches the model, and put the resolved value in
the instructions.

```swift prelude:guide-context
// Pre-resolution in your own code — no unverified API required.
let resolved = contactBook.resolve(reference: "my sister")   // your code, your data
let session = LanguageModelSession(tools: [spotlight]) {
    """
    You help the user recall their own hikes.
    When the user says "my sister", they mean \(resolved.displayName) \
    (\(resolved.emailAddresses.joined(separator: ", "))). Use that when filtering by participant.
    """
}
```

This costs tokens and does not scale past a handful of relationships, which is presumably why the
resolver exists. But it is verifiable today.

---

## 12. Custom pipeline stages

This is the most conceptually interesting part of session 246 and the part most likely to be
skipped, because it is introduced twenty minutes in and sounds like an edge case. It is not an
edge case; it is the answer to "my result set is 40,000 items and my context window is 4,000
tokens".

### 12.1 What a pipeline search is

> ✅ **VERIFIED** — `246:86-90`, verbatim: "your app can take advantage of **custom pipeline
> stages**, that take document reasoning even further. **For really complex requests, the language
> model might forgo a simple search query, in favor of a PIPELINE SEARCH. A pipeline search brings
> together queries to the index, plus computation over a result set, for maximal efficiency.** I
> could ask: *how many trails have I hiked this year, and for each month, how many miles have I
> gone on average?* Now, the model could perform a simple search and keep a tally in memory to
> answer the question. **Or, if the result set is likely to be large, `SpotlightSearchTool` allows
> the model to request that Spotlight run a pipeline of search and computation stages.**"

> ✅ **VERIFIED** — `246:91-93`, verbatim: "With a pipeline search, the model can **break down this
> complex query into a set of steps. The model might generate a search for completed hikes, along
> with a COUNTING stage that builds a table by month, then a stage that computes an AVERAGE over
> all counts. Pipeline stages allow the tool to perform efficient computation, or transformation,
> over a result set on behalf of the model.**"

The insight is that "count the hikes per month and average the mileage" does not require the model
to *see* the hikes. It requires the model to *specify a computation* and see the result. Aggregation
runs next to the index, and what crosses into the context window is a small table instead of 40,000
rows. This is the same reasoning behind Apple's advice elsewhere in the forums that arithmetic
belongs in a tool rather than in the model:

> ✅ **VERIFIED** — Developer Forums thread **833560**, **Frameworks Engineer (Apple)**, marked
> Recommended: "adding tools that can do calculations for the model (i.e. average, sum, etc)
> instead of the model trying to do them can help as well."

Built-in stage kinds are legible from the reply-content enum in §9.3, whose seven cases are now
✅ VERIFIED against Apple's sample: `.items`, `.scoredItems`, `.groupedItems`, `.count`, `.table`,
`.statistic`, `.text`. Four of those — `count`, `table`, `statistic`, `text` — are not search hits
at all; they exist precisely because a pipeline stage can produce them.

### 12.2 Registering your own

> ✅ **VERIFIED** — `246:94-96`, verbatim: "**And your app can participate by registering its own
> custom stages. Pipeline stages are `Generable`, so the model will generate a stage on-demand
> based on the user's prompt. And whenever a stage is generated, the model may choose to return
> data back to the app when it makes sense.**"

Read "**pipeline stages are `Generable`**" carefully, because it inverts the usual mental model of
a tool. You are not defining a function the model calls with arguments. You are defining a **type
the model instantiates**. The model generates a value of your stage type — guided by your `@Guide`
annotations, exactly like any other guided generation — and the framework then executes that
instance against a result set. Your `@Guide` descriptions are how you tell the model *when* and
*with what parameters* your computation is worth running.

Apple's worked example:

> ✅ **VERIFIED** — `246:98-105`, verbatim: "Some trails includes personal notes on how each hike
> went, so I might want to ask: *I remember being really happy on some of my hikes. Which ones were
> they?* **On its own, the model could make its best guess at my happiness level, just by reading
> my notes. Or, the app could register a custom stage, that computes a happiness score over each
> item, allowing the model to generate a response, solely on the computed top-scoring results.** To
> build a custom stage that computes a happiness score, we'll want to **operate on
> `CSSearchableItem` as the input, and return a SCORED version as the output. The score could be
> computed by running a sentiment analysis model over the `notes` attribute on the item, or by some
> other custom logic, perhaps taking into account hikes rated with 5 stars. And since this is a
> `Generable` type, we can add properties with `@Guide`s to inform the model on which results to
> prefer. Then we simply register the stage by adding it to the tool's configuration.**"

That example is worth dwelling on because it is a genuinely good argument for the whole mechanism.
"Which hikes was I happy on?" is a question the LLM *can* answer badly by reading notes — and per
§6 it cannot even read the notes. A sentiment model over your own store gets a real number over
every item, cheaply, without any of it entering the context. The LLM's job shrinks to: decide that
happiness is the relevant axis, set a threshold, and phrase the answer.

> ✅ **SDK-verified (2026-07-29)** — the protocol is real and the field note's list was right. From
> the overlay (`_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface:217-243`):
>
> ```swift
> public protocol CustomStage : Generable, Decodable, Encodable, Sendable {
>     static var name: String { get }
>     static var description: String { get }
>     static var inputTypes: [SearchPipelineDataType] { get }
>     static var outputTypes: [SearchPipelineDataType] { get }
>     // Seven overloads, one per SearchPipelineDataType; ALL have default
>     // implementations (:244-266) — implement only the ones your inputTypes name.
>     func execute(items: [SearchableItem]) async throws -> SearchPipelineData
>     func execute(scoredItems: [ScoredSearchableItem]) async throws -> SearchPipelineData
>     func execute(groupedItems: [SearchableItemAttribute: [SearchableItem]]) async throws -> SearchPipelineData
>     func execute(count: Int) async throws -> SearchPipelineData
>     func execute(table: SearchResultsTable) async throws -> SearchPipelineData
>     func execute(statisticName: String, value: Double) async throws -> SearchPipelineData
>     func execute(text: String) async throws -> SearchPipelineData
> }
> ```
>
> `SearchPipelineDataType` is a `String`-raw-value enum: `.items`, `.scoredItems`, `.groupedItems`,
> `.count`, `.table`, `.statistic`, `.text` (`:286-309`) — the same seven shapes as §12.1's reply
> cases. Every `execute` returns a `SearchPipelineData`, a payload enum over those same seven
> shapes (`:270-282`), and registration takes **instances**: `customStages: [any CustomStage]`
> (`:53-58`). `SearchableItem` wraps a `CSSearchableItem` as its single `item` property
> (`CoreSpotlight-27.0-macos.swiftinterface:13-15`); a scored result is
> `ScoredSearchableItem(item:score:)` (`:410-414` in the overlay).
>
> Note also that **custom pipeline stages are absent from Apple's session-246 sample** — the same
> hiking-trails app Apple used at `246:98-105` to motivate the happiness-score stage ships without
> one. That is not proof against the API — the header above is — but combined with §12.4 it is a
> strong signal that this is the least-exercised corner of the tool.

```swift prelude:guide-context
import CoreSpotlight
import FoundationModels
import NaturalLanguage

// ✅ signatures SDK-verified against the overlay; behaviour still subject to §12.4.
@Generable
struct HappinessScoreStage: CustomStage {

    static let name = "happinessScore"
    static let description = "Computes a 0-1 happiness score over each hike's personal notes."

    @Guide(description: """
    Only include hikes whose computed happiness score is at least this value, \
    from 0.0 (very negative notes) to 1.0 (very positive notes). \
    Use 0.6 or higher when the user asks about happy, enjoyable or memorable hikes.
    """)
    var minimumScore: Double

    static let inputTypes: [SearchPipelineDataType] = [.items]
    static let outputTypes: [SearchPipelineDataType] = [.scoredItems]

    func execute(items: [SearchableItem]) async throws -> SearchPipelineData {
        .scoredItems(items.compactMap { wrapped in
            guard let notes = wrapped.item.attributeSet.contentDescription else { return nil }
            let score = Self.sentiment(of: notes)
            guard score >= minimumScore else { return nil }
            return ScoredSearchableItem(item: wrapped, score: score)
        })
    }

    /// Plain NaturalLanguage sentiment, mapped from [-1, 1] to [0, 1].
    private static func sentiment(of text: String) -> Double {
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = text
        let (tag, _) = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore)
        let raw = Double(tag?.rawValue ?? "0") ?? 0
        return (raw + 1) / 2
    }
}

let tool = SpotlightSearchTool(configuration: .init(
    sources: [.coreSpotlight(.init(searchableIndexDelegate: delegate,
                                   fetchAttributes: Self.fetchAttributes))],
    guide: .focused(),
    customStages: [HappinessScoreStage(minimumScore: 0.6)]  // ✅ instances, not metatypes (:53-58)
))
```

The `@Guide` on `minimumScore` is the part that is *not* reconstructed in spirit — Apple says
explicitly "we can add properties with `@Guide`s to inform the model on which results to prefer".
Write those descriptions as though they are prompt text, because they are.

### 12.3 Stage output can come back to your UI

> ✅ **VERIFIED** — `246:106-108`, verbatim: "remember how `SpotlightSearchTool` returns replies
> with search results for display? Well, **the model may decide to send back a search reply with
> the OUTPUT DATA of a pipeline stage, as another kind of partial result. From aggregate counts and
> tables, to free-form text or computed numeric values, your app can display some or all of these
> data types. And each reply comes with a handy LLM-generated label describing the content**,
> giving your app the most flexibility for its user interface."

This closes the loop with §9. The same `searchResults` stream that carries `items` also carries
`count`, `table`, `statistic` and `text` — those are pipeline-stage outputs, not search hits. And
each carries a `label` **the model wrote**, describing what the payload is.

That is a genuinely nice UI affordance: you get "Hikes per month, 2026" as a section header without
writing a formatter, because the model that requested the aggregation also named it. It is also a
thing to be careful with — it is model-generated text going straight into your interface, subject
to all the usual caveats about length, language and tone. Treat it as untrusted display text:
truncate it, and have a fallback for when it is absent.

```swift prelude:guide-context
for await reply in tool.searchResults {
    switch reply.content {                      // ✅ case names and payload types SDK-verified
    case .items(let batch):        show(items: batch.map(\.item), titled: reply.label)
    case .scoredItems(let scored): show(items: scored.map(\.item.item), titled: reply.label)
    case .groupedItems(let groups): show(groups: groups, titled: reply.label)
    case .count(let n):            show(metric: "\(n.value)", titled: reply.label ?? n.header ?? "Count")
    case .table(let table):        show(table: table, titled: reply.label ?? table.header ?? "Breakdown")
    case .statistic(let stat):     show(metric: stat.value.formatted(), titled: reply.label ?? stat.header ?? stat.name)
    case .text(let result):        show(text: result.body, titled: reply.label ?? result.header)
    @unknown default:              break        // the enum is non-frozen; do not crash
    }
}
```

The seven case names and the `@unknown default` requirement are ✅ **VERIFIED** from
`Session.swift:170-180` — Apple's sample matches the last four cases without binding them. The
**associated-value types are now SDK-verified** from the overlay
(`_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface:341-350`, payload structs `:418-477`):
`.count` carries a `SearchCount` (`value: Int, header: String?`), `.statistic` a `SearchStatistic`
(`name: String, value: Double, header: String?`), `.text` a `SearchTextResult`
(`body: String, header: String?`), and `.table` a `SearchResultsTable` — typed `Column`s
(`.string/.integer/.double/.date/.boolean`), `Row`s of `Value`s (same five cases plus `.none`),
and its own optional `header`. Note the pattern: every aggregate payload carries its **own**
`header: String?` in addition to the reply-level `label`, so you have two model-generated titles
to choose from — prefer `reply.label`, fall back to the payload header.

### 12.4 The beta-era caveat

> ⚠️ **SILENT FAILURE** — ✅ **VERIFIED** (community-measured, macOS 27 beta, M4 Max, 2026-06-13),
> verbatim: "A `CustomStage` **conforms and is accepted** in `Configuration.customStages` (the
> session builds and the tool round trip still passes), **but neither an `items→text` nor
> `items→scoredItems` stage was routed through by the 27.0-beta pipeline for our queries —
> including under `SystemLanguageModel`, so it is a tool/beta behavior, not a third-party-model
> limitation.** Docs note stages 'run independently' (isolated execution). **Prefer the
> companion-tool hydration above.**"

Everything compiles. The session builds. Queries succeed. Your stage is simply never executed, and
the model answers without it. This is the worst possible failure shape for a feature whose entire
value proposition is "the computation happened somewhere you cannot see".

> 🔴 **GAP** — **current status unknown.** One observer, one beta build, two stage shapes, one
> machine, June 2026. It may be fixed. Before you invest in custom stages: put a `print` or an
> `OSSignposter` interval at the top of `execute`, ask a question that obviously requires
> aggregation, and confirm it fires. If it does not, fall back to §8 plus a plain computation tool
> — which is exactly what Apple's own forum advice in thread 833560 recommends anyway.

---

## 13. Custom attributes, `IndexedEntity`, and dynamic guidance

A question that comes up immediately once you have donated more than the standard attribute set:
can the model reason over *my* attributes? The answer from Apple is yes, with a condition.

> ✅ **VERIFIED** — Developer Forums thread **833658**, **Engineer (Apple)**, accepted answer,
> verbatim: "`IndexedEntity` is backed by a `CSSearchableItem` that can be extended with any
> additional metadata on the item, whether system attributes or custom attributes, and are
> available for in-app search with any of CoreSpotlight's query APIs, including
> `SpotlightSearchTool`. **For reasoning over custom attributes, you can describe them in the
> instructions for your language model session, or use dynamic guidance in `SpotlightSearchTool`'s
> configuration.**"

Apple's engineer names two mechanisms. Apple's sample uses a third, and it is the one to reach for
first.

**Name the custom key in `fetchAttributes`.** ✅ **VERIFIED** — session-246 sample,
`Session.swift:127-129`. `SearchableItemAttribute` has a public `init(rawValue:)`, so a
`CSCustomAttributeKey`'s `keyName` goes straight into the fetch list:

```swift prelude:guide-context
if let key = SpotlightIndexer.distanceAttributeKey {
    attributes.append(SearchableItemAttribute(rawValue: key.keyName))
}
```

This is precise, costs no context, requires no unverified type, and is what Apple's own reference
app does. Pair it with one line of instructions giving the attribute's units and meaning (§3.1) and
you are done. See §5.2 for the full donate-then-fetch round trip.

The engineer's two mechanisms, in increasing order of precision:

**Describe them in your instructions.** Cheap, verifiable, works today, costs context on every
turn. Good for two or three attributes. You need this anyway — `fetchAttributes` makes the value
*visible*, the instructions make it *meaningful*.

```swift prelude:guide-context
let session = LanguageModelSession(tools: [spotlight]) {
    """
    Trail items carry two custom attributes beyond the standard set:
    • trailDifficulty — one of easy, moderate, strenuous
    • trailDistanceKm — a number
    Use these when the user asks about difficulty or distance.
    """
}
```

**Use dynamic guidance.** That is the `attributes:` parameter of `GuidanceProfile` from §10.3 —
"You can even specify the exact list of metadata attributes, that the model should consider during
a search" (`246:78`). Precise, scoped, and no longer blocked: the parameter's declared type is
known.

> ✅ **RESOLVED (2026-07-29)** — `GuidanceProfile(attributes:)` is
> `[SearchableItemAttribute]? = nil` — the **same element type as `fetchAttributes`**
> (✅ **SDK-verified**, `_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface:210-211`). So a
> custom key goes in exactly the way §5.2 already showed:
> `SearchableItemAttribute(rawValue: key.keyName)` works in both places, and *guidance* on a custom
> attribute uses the same spelling as *visibility* of it. What one costs against the other in
> tokens and retrieval quality is behavioural and still unmeasured (§10.4).

---

## 14. Three documented failure modes

Everything above describes the tool working. This section describes it not working, in three
distinct ways that developers hit in the weeks after WWDC26. All three are **beta-era** and all
three have **unknown current status** — they are here so that when you hit one you recognise it
in ten minutes instead of two days.

Before the three defects, the ordinary errors. A Spotlight-grounded session throws exactly what any
other session throws, and Apple's sample handles them with a file that is byte-for-byte the same as
the one in the unrelated Origami sample:

> ✅ **VERIFIED** — session-246 sample, `Error+DisplayMessage.swift:11-32`. **`SystemLanguageModel.Error`
> is checked first**, via `if self is SystemLanguageModel.Error`, and only then `LanguageModelError`
> with `.timeout`, `.guardrailViolation`, `.refusal`, `.contextSizeExceeded`,
> `.unsupportedLanguageOrLocale` and a `default: break` — so `LanguageModelError` is **non-frozen**.
> Two independent Apple samples shipping the same five case names is as strong a confirmation as
> anything short of the headers. Full taxonomy in
> [2.6 — The complete failure taxonomy](06-availability-errors-and-guardrails.md).

Note what the sample does *not* do: there is no proactive `SystemLanguageModel.default.availability`
switch anywhere in it. Apple's 2026 samples gate reactively, by catching
`SystemLanguageModel.Error`. §14.1 is the reason you should do both.

### 14.1 The model-catalog error — thread 838904

Bare `SpotlightSearchTool()`, on macOS 27 beta 4, with Apple Intelligence available and the model
reporting `.available`:

> ✅ **VERIFIED** — Developer Forums thread **838904** (BlueFox123, 2026-07-22), error verbatim:
>
> ```text
> Model Catalog error: Error Domain=com.apple.UnifiedAssetFramework Code=5000
> "There are no underlying assets (neither atomic instance nor asset roots) for
> consistency token for asset set com.apple.modelcatalog"
> UserInfo={NSLocalizedFailureReason=There are no underlying assets (neither atomic instance ...
> ```
>
> Repro code — the five lines from §3, unchanged from the session.

Apple's response, verbatim:

> ✅ **VERIFIED** — thread **838904**, **Apple Designer (Apple)**: "Whelp, that's totally a bug. 🐛
> You're doing everything correctly! That's not an error you should ever see normally. Thanks for
> reporting! I'm filing a bug report for this, although it would definitely help if you can tell
> me: Did you update your Mac right before this error or within the past few hours before the
> error? Rebooting your Mac _should_ resolve the issue…"

The developer reported that **rebooting did not fix it**, and that it persisted across beta 3 → beta
4. Environment: "macOS Golden Gate Developer Beta 4" — *Golden Gate* being the macOS 27 codename in
developer usage.

**What this tells you about the architecture.** `com.apple.modelcatalog` is an asset set in the
Unified Asset Framework, and the error is about *asset provisioning*, not about the LLM. The
strong inference — and it is an inference, marked as such — is that `SpotlightSearchTool` pulls a
**separate model asset of its own**, distinct from the `SystemLanguageModel` weights, and that
asset can be missing on a machine where the LLM is perfectly healthy.

> ⚠️ **SILENT FAILURE (inverted)** — the practical consequence is a gating bug. Every availability
> check you have been taught to write —
> `SystemLanguageModel.default.availability == .available` — passes, and the tool still cannot
> initialise. **Availability of the model is not availability of the tool.** There is no
> `SpotlightSearchTool.availability`. Wrap tool construction and the first `respond` in error
> handling and degrade to a non-RAG path rather than assuming a green availability check covers it.

> 🔴 **GAP** — **there is no documented pre-flight check for the tool's own asset.** Rebooting is
> Apple's suggested remedy and it did not work for the reporter. Whether the asset downloads on
> demand, whether it is gated on Apple Intelligence being enabled, whether it appears in any
> asset-status API — all unknown. Current status on shipping 27.0 builds is unknown. What would
> resolve it: an Apple statement or a release-note entry, or a reproduction attempt on a current
> build.

### 14.2 The tool is never invoked — thread 837226

The second failure is more insidious because there is no error at all until you go looking.

**Symptom:** the session answers the question. Fluently. From world knowledge. The tool was never
called, `toolReplies=0`, and nothing indicates that anything is wrong.

The developer's diagnostic instinct was correct: force the issue with `toolCallingMode`.

> ✅ **VERIFIED** — Developer Forums thread **837226** (Hunter, 2026-07-07), triggering code
> verbatim:
>
> ```swift
> let session = LanguageModelSession(tools: [tool]) {
>     spotlightSearchInstructions
> }
> let response = try await session.respond(
>     to: prompt,
>     options: GenerationOptions(toolCallingMode: .required)
> )
> ```
>
> Console output verbatim:
>
> ```text
> InferenceError::hostFailed::InferenceError::inferenceFailed::TokenGenerationCore.GuidedGenerationError.invalidConfiguration(errorMessage: "Tool Choice requires tools") in response to ExecuteRequest
> Error during session.respond. description="The operation couldn't be completed. (FoundationModels.LanguageModelError error -1.)"
> Returning empty Spotlight result. elapsedMs=3254 toolReplies=0 totalSearchItems=0 uniqueSearchItems=0
> ```
>
> Reproduced on **iPhone 17 Pro Max, iOS 27 beta 3** (build 24A5380h). Filed **FB23643759**. Open
> at time of capture.

Note the shape of that second failure carefully: **"Tool Choice requires tools"** fires *even
though tools were passed*. The tool array is not reaching the inference layer. So the developer's
probe did not merely fail to force the call — it exposed a second, lower-level defect underneath
the first. The surfaced error is a bare `LanguageModelError error -1`, which tells you nothing.

**Using `.required` as a probe.** This is a good technique and worth generalising, but it has a
documented footgun of its own:

> ✅ **VERIFIED** — Apple documentation, `GenerationOptions.ToolCallingMode` page and the
> tool-calling article, verbatim: "When you set the mode to `required`, you must define an exit
> condition by either throwing an error from a tool's `call(arguments:)` method or by changing the
> mode dynamically using a `LanguageModelSession.DynamicProfile`; **otherwise, the model continues
> to call the tool.**"

✅ **VERIFIED** — the mode's full surface, from Apple docs: `struct ToolCallingMode` with
`static var allowed` ("The model may or may not call tools"), `static var disallowed` ("The model
may not call any tool"), `static var required` ("The model must call one or multiple tools"), and
a `kind` property over a `Kind` enum with the same three cases. Also verified: in the iOS 27
four-argument `GenerationOptions` initialiser, `toolCallingMode` is the one parameter **without a
default value**, so `GenerationOptions(toolCallingMode: .required)` compiles by defaulting the
other three.

There are two spellings of this concept, and Apple staff recommend the other one:

> ✅ **VERIFIED** — Developer Forums thread **833692**, **Frameworks Engineer (Apple)**, marked
> Recommended, verbatim: "You can use `.toolCallingMode` with `DynamicProfiles` for this."

So: `GenerationOptions(toolCallingMode:)` is the one-shot probe you reach for while debugging;
`LanguageModelSession.DynamicProfile.toolCallingMode(_:)` is the one you ship, because a profile
can flip the mode back to `.allowed` after the first tool call and thereby *be* the exit condition.
See [3.2 — Dynamic Profiles, modifiers, session
properties](../../part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md).

**Before you reach for `.required` at all**, work down this list — most "tool not invoked" reports
resolve here:

1. **Is the index actually populated?** Query it with a plain `CSSearchQuery` for a term you know
   is there. An empty index produces empty results, which produces ungrounded answers.
2. **Do your instructions tell the model to search?** "Always call the Spotlight search tool
   before answering a question about a specific hike" is not redundant.
3. **Did you over-trim guidance?** §10.4 — `.dynamic` with a narrow profile weakens the cue to
   search. Try `.focused()` and see if the behaviour returns.
4. **Is the model big enough?** §15 — a 0.6B model cannot handle this tool's schema at all.
5. **Are you on the simulator?** The simulator punches inference out to the host macOS, and an
   Xcode 27 SDK against a macOS 26 host produces meaningless `-1` errors. Test on device.

### 14.3 The description/schema mismatch — threads 832534 and 833651

This is the most serious of the three, because it is structural rather than environmental, and
because Apple has confirmed it.

> ✅ **VERIFIED** — Developer Forums thread **833651**, **DTS Engineer (Apple)**: "Thanks for your
> question. **This is a known issue** discussed here." (linking thread 832534)

The mechanics, from the developer who diagnosed it:

> ✅ **VERIFIED** — thread **833651** (bkusserow), verbatim: "The root cause is a mismatch between
> two things the framework sends to the model in the same tool definition:
> - the human-readable `description` ('Call format'), which presents the top-level arguments as
>   `{ root, modelComposition, … }`, and
> - the `parameters` JSON Schema (`FullArguments`), which requires
>   `{ "query": { "type": "search", "value": { root, modelComposition, … } } }`.
>
> **A model that follows the description is guaranteed to fail the schema.**"

The failure surface is `LanguageModelSession.ToolCallError` with an underlying **"Failed to parse
generated content."** Manually wrapping the arguments makes it parse and search correctly. Also
from that post: `Query` is a **`QueryType` union**, and a search must be wrapped in
**`DiscriminatedSearch`**.

> 🟡 **RECONSTRUCTED** — `FullArguments`, `QueryType`, `DiscriminatedSearch`, `root`,
> `modelComposition` are one developer's reading of the framework-generated schema, not declared
> API you write. They are reproduced here so you recognise them in an error message or an
> Instruments trace. **Do not write these type names in source.**

**Why it hits third-party models hardest.** Apple's own on-device model is trained against this
tool and evidently ignores the prose description in favour of the schema — which is why the
session's demo works. A general-purpose model reads both, and prose instructions in a tool
description are a strong prior. The result is a tool that works behind `SystemLanguageModel` and
is **effectively uninvokable behind a non-Apple model**, which is an unfortunate collision with
`246:44`'s promise that you can bring your own.

> 🔴 **GAP** — **status unknown.** DTS acknowledged it as a known issue during the WWDC26 Q&A
> window (June 2026). No fix is documented in this corpus. If you are building on a current build,
> test it directly: give the tool to a non-Apple model, ask a question that requires a search, and
> check whether you get `ToolCallError` / "Failed to parse generated content."

---

## 15. Running the tool behind a non-Apple model

`246:44` says you can. The field evidence says you can, with constraints — and §14.3 says you may
not be able to at all on beta builds. Here is what was actually measured.

> ✅ **VERIFIED (community-measured)** — community field note, macOS 27 beta / M4 Max /
> 2026-06-13, running `SpotlightSearchTool` behind a locally bundled model via the `LanguageModel`
> protocol:
>
> - **The only capability required is `.toolCalling`.** "**`.guidedGeneration` is NOT required**
>   (the tool does not constrain decoding on the model side), so this works on the GPU-pipelined
>   engine that cannot expose logits."
> - "**qwen3-0.6b is too small for the rich `SpotlightSearchTool` schema** (loops on `<think>` →
>   framework reports 'ended without producing a response'). **Use qwen3-4B or larger.**"
> - "**Append `/no_think` to the instructions** to disable qwen3 reasoning — the search→fetch chain
>   then completes reliably (5/5 on stock qwen3-4B) and is ignored harmlessly by non-qwen models."
> - Tool calling through that particular runtime needed a **ChatML tokenizer** (`<|im_start|>`);
>   Mistral-style (`[INST]`) and Gemma templates did not get `.toolCalling`.

The first bullet is the architecturally significant one. Because the tool does not constrain
decoding, a `LanguageModel` implementation that cannot expose logits — which is most GPU-pipelined
engines — can still host it. That is a genuinely low bar and it is why "any model" is close to
true.

The second and third are a lesson about **schema size** that generalises past qwen3: this tool's
argument schema is large (§10.1's ~13k tokens at `.complete`), and a small reasoning model handed
a large schema will burn its entire token budget thinking about it and produce nothing. The
framework then reports "ended without producing a response", which reads like a framework failure
and is actually a budget failure. If you are hosting a thinking model, disable thinking for
Spotlight-grounded turns.

See [4.2 — Core AI, MLX, and any OpenAI-compatible
server](../../part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md)
for how to get a non-Apple model behind `LanguageModelSession` in the first place.

---

## 16. Evaluating a Spotlight-grounded feature

Given §6, §7.1, §10.4, §12.4 and §14, you should now believe the following: **you cannot tell
whether this feature is working by reading its answers.** The answers are fluent either way. That
is why Apple spends the last quarter of session 246 on evaluations rather than on more API.

> ✅ **VERIFIED** — `246:109-110`, verbatim: "With so many options for customization — **from the
> model we choose and the searchable content our app donates, to guidance levels and custom
> reasoning** — how can we verify, in a broad way, how well the model is responding in our app?
> Well, the **Evaluations framework** can help us in a few important ways. **Not only can we
> quickly build evaluations to see how well the model is calling the tool, and how meaningful the
> response; we can also RAPIDLY ITERATE ON OUR APP'S SEARCHABLE CONTENT PAIRED WITH DIFFERENT
> GUIDANCE PROFILES on `SpotlightSearchTool` itself.**"

The metric Apple picks is the right one:

> ✅ **VERIFIED** — `246:113-117`, verbatim: "we're going to focus on **result coverage** as a way
> to evaluate the hiking trails conversational experience. We want to know, **given a dataset
> that's indexed in Core Spotlight, how well does the model generate responses based on the items
> we expect it to find.** We'll start by **defining a dataset that adopts the
> `ModelSampleProtocol`. Our `TrailRequest` already includes the natural language input that a
> person might ask about trails in our app, the output is a language model response and an
> expectation of the trajectory of the request. We'll also be adding a set of UNIQUE IDENTIFIERS of
> searchable items that we expect the tool to return for that prompt.**"

Result coverage is *"of the items I know should have been found, how many made it into the final
answer"*. It is computed against identifiers you control, so it is immune to the fluency problem.
It also catches all five failure modes in this guide at once: an unpopulated index, an uninvoked
tool, over-trimmed guidance, an unrouted stage, and a hallucinated body all drive coverage down.

The evaluation harness sets up its own world:

> ✅ **VERIFIED** — `246:129-131`, verbatim: "In our TEST TARGET, our evaluation will **load the
> trail items and samples from our generated datasets. Then, we'll DONATE the trail items to Core
> Spotlight, and configure `SpotlightSearchTool` for this evaluation.** Once the evaluation
> completes its run, we can **set the expectation for any metric we've included, like RESULT
> COVERAGE.**"

Donating into the real Core Spotlight index from a test target is worth pausing on: this is not a
mocked retrieval layer. Your evaluation writes real items, runs a real search, and cleans up. Use a
dedicated `domainIdentifier` so `deleteSearchableItems(withDomainIdentifiers:)` gives you a clean
teardown, and expect indexing to be asynchronous — donate, then wait for a plain `CSSearchQuery` to
see the items before you run the model.

And the two expectation shapes:

> ✅ **VERIFIED** — `246:126-127`, verbatim: "The next step is to **define our evaluation with
> metrics and trajectory. For our samples, we expect the trajectory of a response to include a call
> to `SpotlightSearchTool` to perform a query**, so here's how we might define that expectation."

A **trajectory expectation** ("a `SpotlightSearchTool` call occurred") catches §14.2 directly and
mechanically. A **result-coverage metric** catches §6. You want both; they fail for different
reasons.

> 🟡 **RECONSTRUCTED** — the sample type. `ModelSampleProtocol` and `TrailRequest` are ✅ VERIFIED
> names (spoken at `246:115-116`); the members below are inferred from the narration, and `Codable`
> is verified from `246:122` ("Samples can be serialized in any `Codable` format, and JSON works
> well for that purpose").

```swift prelude:guide-context
// 🟡 RECONSTRUCTED — names verified, member types inferred.
struct TrailRequest: ModelSampleProtocol, Codable {
    var input: String                       // "What hikes have I gone on?"
    var output: String                      // a reference response for quality comparison
    var trajectory: [ExpectedToolCall]      // expects a SpotlightSearchTool call
    var expectedItemIdentifiers: [String]   // uniqueIdentifiers the tool should return
}
```

The Evaluations framework's actual spellings are now settled, from Apple's Book Tracker sample —
and `ModelSampleProtocol` is not among them:

> ✅ **VERIFIED** — Book Tracker sample (macOS 27, Evaluations end to end). The dataset unit is
> **`ModelSample<Value>`**, generic over the expected/output type, with
> `ModelSample(prompt:expected:)` and `ModelSample(prompt:expected:instructions:expectations:)`;
> it is `Codable`. An `Evaluation`'s core requirement is
> `func subject(from sample: ModelSample<T>) async throws -> ModelSubject<T>`, returning a
> **`ModelSubject<T>`** (`init(value:)` / `init(value:transcript:)`). Trajectory checking is
> **`ToolCallEvaluator(allPass:percentagePass:)`** over **`TrajectoryExpectation`** — four
> initialisers, `(unordered:)`, `(ordered:allowsAdditionalToolCalls:)`, `(unordered:disallowed:)`,
> `(expected:arguments:)` — whose call-site element type is **`ToolExpectation(_:)`** /
> `ToolExpectation(_:arguments:)`. Feeding it requires
> **`session.transcript.structuredTranscript`** passed to `ModelSubject(value:transcript:)`.

For this guide's purposes the practical shape of a trajectory expectation is therefore:

```swift prelude:guide-context
// ✅ Spellings verified against Apple's Book Tracker sample.
TrajectoryExpectation(unordered: [ToolExpectation("spotlight_search")])
```

Note the **snake-case wire name** (§4), not the Swift type name — the evaluator matches what the
model emitted.

> 🔴 **GAP** — **result coverage itself.** `246:113-117` names it as the metric for exactly this
> feature, but Book Tracker evaluates a book-recommendation feature and contains no
> Spotlight-specific metric; nothing in this corpus shows a built-in result-coverage `Metric`, an
> API for declaring expected item identifiers, or the "donate then evaluate" test-target harness of
> `246:129-131`. Given that Cohen's kappa turned out to be hand-rolled in Apple's own sample rather
> than provided by the framework, **assume result coverage is likewise something you compute
> yourself** — a custom `Evaluator` comparing `expectedItemIdentifiers` against the
> `uniqueIdentifier`s your `searchResults` listener collected — until proven otherwise. See
> [6.3 — `SampleGenerator` and
> `TrajectoryExpectation`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md).

One more thing from `246:118-125`: if you do not have real data, sample generation can expand a
small seed set. "Using the Sample Generation APIs **in a command line tool**, I can **expand this
seed set to many more variations**, to get broad coverage on how people might want to ask about
trails" (`246:125`). For a search feature that is unusually valuable, because the failure mode you
are hunting is *phrasing-dependent* — §10.4's "prompt-sensitive" — and ten hand-written prompts
will not find it.

---

## 17. `OCRTool` and `BarcodeReaderTool`

The other two system tools introduced this year are a different animal: they are backed by Vision,
not Spotlight, and they exist to let the model reason about things it cannot perceive natively even
though it now accepts images.

> ✅ **VERIFIED** — `241:L58-66`, verbatim: "we're introducing several **built-in tools that
> supercharge your `LanguageModelSession`s with system provided functionality**. FoundationModels
> now contains **two native tools backed by the Vision framework's powerful capabilities**." —
> `BarcodeReaderTool` "allows the model read information from barcodes"; `OCRTool` "allows the
> model to extract structured text from images"; "**Both enhance a model's ability to reason about
> visual information in ways it can't natively.**"

> ✅ **VERIFIED** — Apple documentation, `/documentation/updates/foundationmodels`, June 2026,
> verbatim: "Perform image analysis tasks by including an image in your prompt and using tools the
> Vision framework provides, like `OCRTool` and `BarcodeReaderTool`."

> ✅ **VERIFIED** — Apple documentation, Foundation Models "Vision framework tools" section,
> verbatim: "The Vision framework provides optical character recognition (OCR) and barcode tools
> that you can add to a session in the Foundation Models framework. Use **`BarcodeReaderTool`** to
> detect barcodes and interpret their encoded content, and **`OCRTool`** to extract text from
> images."

The usage pattern is the important part, and Apple's own sample makes it explicit — this code is
✅ **VERIFIED**, reproduced verbatim from the documentation page:

```swift compile:27 imports:FoundationModels,Vision
func analyzeBarcodeImage(_ image: CGImage) async {
    do {
        let session = LanguageModelSession(tools: [BarcodeReaderTool()])
        let response = try await session.respond {
            """
            Scan this image for any barcodes. For each barcode found, describe \
            its symbology type and explain what the encoded content means or \
            represents.
            """

            Attachment(image)
                .label("barcode-image")
        }.content

        print("The model response: \(response)")
    } catch {
        // Handle the error.
    }
}
```

Three things to notice, because they are the whole mental model:

**The image goes in the prompt, not into the tool.** You attach the image with `Attachment(image)`
inside the prompt builder and give it a `.label`. The tool then operates on an image already in
the session's transcript. This is why `OCRTool` and `BarcodeReaderTool` require the multimodal
prompting surface — see [2.5 — Image input, and what the model cannot do with
pixels](05-image-input-and-attachments.md).

**The label is the handle.** `.label("barcode-image")` names the attachment so the model can refer
to it. Apple's `ImageReference` type — ✅ VERIFIED from the docs as `struct ImageReference` (iOS
27.0+, conforms to `Generable`, with `var attachmentLabel: String` "The label of the referenced
image" and `func resolved(in:) -> Transcript.ImageAttachment?`) — is the mechanism by which a tool's
`Arguments` can name an image from the transcript. That is how a tool receives an image.

**Instantiation is bare, and that is the whole API.** `BarcodeReaderTool()` — no configuration in
Apple's sample, and none exists: the only initialiser is
`init(name: String? = nil, description: String? = nil)` (✅ **SDK-verified**, see below). There are
no symbology, language or region-of-interest knobs to find.

### When to use these instead of asking the model

The model accepts images now, so a reasonable question is why you would use a tool at all. The
answer is in `241:L66`: "in ways it **can't natively**". Concretely:

- **Barcodes and QR codes are a decoding problem, not a perception problem.** A VLM looking at a
  Code 128 barcode is guessing. Vision's decoder is exact, and it returns the symbology as well as
  the payload. There is no accuracy argument for asking the model.
- **OCR on dense or small text** — receipts, forms, screenshots, tables — is where a general VLM
  degrades and a dedicated recogniser does not. And Apple's phrasing is "extract **structured**
  text", which implies geometry, not just a string blob.
- **Spatial questions belong to Vision regardless.** An independent forum report (thread 838613,
  developer-reported) is that the model reliably *lists* objects in an image but produces
  **unreliable bounding boxes**. If you need coordinates, use Vision, not the LLM.

> ✅ **RESOLVED (2026-07-29)** — **the declarations of `OCRTool` and `BarcodeReaderTool` have been
> read, and the "cross-import overlay" guess was the right one** — the `SpotlightSearchTool`
> pattern exactly. Both live in **`_Vision_FoundationModels`**, the overlay module the compiler
> activates only when a file imports both `Vision` and `FoundationModels`
> (✅ **SDK-verified**, `notes/sdk-interfaces/_Vision_FoundationModels-27.0-macos.swiftinterface:14-47`
> for `BarcodeReaderTool`, `:49-83` for `OCRTool`), which is why the parent `Vision.swiftinterface`
> capture was — correctly — empty. The surface: `struct`s conforming to `FoundationModels.Tool,
> @unchecked Sendable`; `init(name: String? = nil, description: String? = nil)` and **nothing
> else** — no language, symbology or region-of-interest knobs; a nested `Generable` `Arguments`
> struct whose model-facing fields are not emitted in the interface (they surface via
> `generationSchema` at runtime); and an **opaque** `Output` — `call(arguments:) async throws ->
> some PromptRepresentable`, so the output type cannot be named in user code. Availability is in
> the attributes too: both tvOS-unavailable; `BarcodeReaderTool` includes watchOS 27.0,
> `OCRTool` is watchOS-unavailable. Full treatment in
> [reference 03](03-tools-and-tool-calling.md) §10. Still true: **no `OCRTool` call site exists
> anywhere in this corpus**, and Apple's deep-dive session **"What's new in image understanding"**
> (`241:L62`) is still not in it.

---

## 18. Adoption checklist and the gap index

### 18.1 Order of work

1. **Donate content, and verify it independently.** Query the index with a plain `CSSearchQuery`
   before any model is involved. An empty index is the most common cause of "the tool doesn't
   work". Use a **named** `CSSearchableIndex` and batch with client state. (§2)
2. **Import both `CoreSpotlight` and `FoundationModels`** in every file that touches the tool. (§3)
3. **Start bare.** `SpotlightSearchTool()` + `LanguageModelSession(tools:)`. If you get
   `com.apple.UnifiedAssetFramework Code=5000`, you are in §14.1 and it is not your code. No
   entitlement is needed at any point.
4. **Write the instructions before the configuration.** Enumerate every indexed attribute with its
   units, forbid inference about unindexed fields, seed synonyms, and say "never answer from
   memory". This is where retrieval quality lives. (§3.1)
5. **Adopt Apple's configuration:** `sources: [.coreSpotlight(.init(searchableIndexDelegate:fetchAttributes:))]`
   plus `guide: isOnDevice ? .focused() : .complete`. Implement
   `searchableItems(forIdentifiers:searchableItemsHandler:)` on the delegate and always call the
   handler. (§5, §7)
6. **Run the metadata-gap test from §6.3 immediately.** Before you build UI, before you tune
   prompts. Its result determines your entire architecture.
7. **If it fails — and on beta builds it did — adopt retrieve-then-hydrate (§8).** Two tools:
   `spotlight_search` for finding, your own for reading. Verified working on three models.
8. **Never use `.complete` on an on-device model.** (§10) It is a ~13k-token instruction block
   (community-measured) and will overflow a 4K window on turn one.
9. **Build a fresh tool per query and consume `searchResults` on a cancellable `Task`.** (§9) A tool
   constructed inline has no observable stream; a tool reused across queries accumulates.
   De-duplicate by `uniqueIdentifier`, and bind your list to the tool's channel, not to the model's
   prose. (§9.1)
10. **Instrument anything you cannot see.** A signpost in
    `searchableItems(forIdentifiers:searchableItemsHandler:)` (§7) and one at the top of any
    `CustomStage.execute` (§12.4). Both are reported as not being called on beta builds, and
    neither tells you.
11. **Write the evaluation before you tune anything.** Trajectory expectation + result coverage.
    (§16)
12. **Only then** reach for `GuidanceProfile`, the contact resolver, and custom stages — none of
    which appear in Apple's own reference app — and re-run the evaluation after each, because each
    can change whether the model searches at all.

### 18.2 Platform and version matrix

| API | Earliest OS | Platforms | Evidence |
|---|---|---|---|
| `SpotlightSearchTool` | **27.0** | iOS, iPadOS, macOS, visionOS. **No watchOS.** | ✅ `246:21`; sample builds at `IPHONEOS_DEPLOYMENT_TARGET = 27.0` |
| `SpotlightSearchTool.Configuration` (`sources:guide:contactResolver:customStages:maximumResponseSize:`, all defaulted) | **27.0** | as above | ✅ SDK-verified (`_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface:49-59`) + sample `Session.swift:116-158` |
| `SearchableItemAttribute` | **27.0** | as above | ✅ sample `Session.swift:116-131` |
| `GuidanceProfile` / `CustomStage` / `contactResolver` | **27.0** | as above | ✅ SDK-verified (overlay `:203-212`, `:217-243`, `:313-326`) — still **absent from Apple's sample**, so behaviour is untested |
| `OCRTool`, `BarcodeReaderTool` (`_Vision_FoundationModels` overlay) | **27.0** | iOS, iPadOS, macOS, visionOS; `BarcodeReaderTool` also watchOS, `OCRTool` not; no tvOS | ✅ SDK-verified (`_Vision_FoundationModels-27.0-macos.swiftinterface:12-13`, `:46-48`) + `241:L59-61` |
| `GenerationOptions.ToolCallingMode` | **27.0** | wherever Foundation Models is | ✅ Apple docs |
| `ImageReference` | **27.0** | wherever Foundation Models is | ✅ Apple docs + Origami sample |
| `CSSearchableIndex`, `CSSearchableItem`, `CSSearchableIndexDelegate` | predates 26.0 | CoreSpotlight platforms | ✅ shipping app source |
| `searchableItems(forIdentifiers:searchableItemsHandler:)` | **macOS 15.4+**; a `protectionClass` overload is reported new in **27.0** | 🔴 iOS floor not verified | ✅ signature from sample `Indexer.swift:123-128`; availability 🟡 community field note |
| Entitlements | **none** | — | ✅ sample ships an empty `<dict/>` |

### 18.3 The gap index

Every 🔴 in this guide, in one place, so you know exactly what to go and measure. Apple's
session-246 sample project (`246:134`: "Download our sample code to see the hiking trails app in
action") has been obtained and read, and it closed nine of these. On **2026-07-29** the macOS 27.0
beta `CoreSpotlight.swiftinterface` was captured
(`notes/sdk-interfaces/CoreSpotlight-27.0-macos.swiftinterface`), closing §5.2's attribute
enumeration — and later the same day the artefact this table kept asking for landed: the
**`_CoreSpotlight_FoundationModels` cross-import overlay interface**
(`notes/sdk-interfaces/_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface`, 513 lines,
macOS slice), which carries the entire tool-side surface and closed every declaration-shaped row
below. What survives is **behavioural**: things a header cannot answer.

| § | Unknown | What would resolve it |
|---|---|---|
| 2.3 | Whether `searchableItems(forIdentifiers:searchableItemsHandler:)` fires for **entity-indexed** content (`indexAppEntities`) as opposed to `CSSearchableItem`-donated content | Test app that indexes only via `IndexedEntity` and signposts the delegate |
| 2.4 | Donation and semantic-index best practice | WWDC25 "Supporting semantic search with Core Spotlight" |
| 5.1 | ~~`FileSource` vs `.files`~~ — **✅ RESOLVED 2026-07-29**: both — `.files(FileSource)`; URLs via the settable `scopes: [URL]` | Resolved — overlay `:26-31`, `:35-44`. Still open behaviourally: whether files must be pre-indexed; security-scoped bookmarks |
| 5.2 | ~~The complete list of `SearchableItemAttribute` statics~~ — **✅ RESOLVED 2026-07-29**: 176 statics enumerated | Resolved — `CoreSpotlight-27.0-macos.swiftinterface:19-207` |
| 7 | Whether the index delegate is called at all on current builds; the 27.0 `protectionClass` overload | CoreSpotlight headers + an instrumented run |
| 9.3 | ~~Payload types; `label`/`queryToken` as members~~ — **✅ RESOLVED 2026-07-29** (overlay `:341-379`, `:418-477`; plus `stageToken` and `status`). **Whether the stream terminates** is still open — `some AsyncSequence<SearchReply, Never>` does not say | A two-search test against one tool instance |
| 10.2 | ~~What `.focused()` takes; whether `.dynamic(_:)` exists~~ — **✅ RESOLVED 2026-07-29**: `ContentDomain = .items`; yes | Resolved — overlay `:74-80`, `:95-198` |
| 10.3 | ~~`GuidanceProfile` value types / existence~~ — **✅ RESOLVED 2026-07-29**: ships; all flags `Bool?`, `attributes: [SearchableItemAttribute]?` | Resolved — overlay `:203-212`. Behavioural prompt-sensitivity (§10.4) still open |
| 11 | ~~The `contactResolver` type~~ — **✅ RESOLVED 2026-07-29**: a `Sendable` protocol, sync `userIdentity() -> ResolvedContact`, no inputs | Resolved — overlay `:313-326`. How the tool *uses* the values: still untested |
| 12.2 | ~~`CustomStage` signatures; element types; registration~~ — **✅ RESOLVED 2026-07-29**: seven defaulted `execute` overloads over `SearchPipelineDataType`; **instance** registration | Resolved — overlay `:217-266`, `:286-309` |
| 12.4 | Whether custom stages are routed on current builds | Signposted `execute` on a current build |
| 13 | ~~Whether `GuidanceProfile(attributes:)` can express custom keys~~ — **✅ RESOLVED 2026-07-29**: yes, `[SearchableItemAttribute]?` — `init(rawValue:)` works | Resolved — overlay `:210-211` |
| 14.1 | Pre-flight check for the tool's own model-catalog asset; current status | Apple statement / release notes |
| 14.3 | Current status of the description-vs-schema mismatch | Test on a current build with a non-Apple model |
| 16 | Whether **result coverage** is a framework metric or something you compute yourself | Part 6 of this series |
| 17 | ~~Both Vision tools' full declarations~~ — **✅ RESOLVED 2026-07-29**: in the `_Vision_FoundationModels` cross-import overlay; `Arguments` `Generable`, `Output` opaque `some PromptRepresentable` | Resolved — `_Vision_FoundationModels-27.0-macos.swiftinterface:14-83` |

Closed by the sample, and no longer gaps: the `Configuration` shape; `.coreSpotlight`'s single
two-label initialiser; the `guide:` values; the entitlement question; the exact
`searchableItems(forIdentifiers:searchableItemsHandler:)` signature; the `SearchReply.content`
case list and its non-frozen-ness; how custom attributes reach the model; the second Core Spotlight
on-ramp; and the wire name `spotlight_search`.

### 18.4 Related guides

- [2.3 — The `Tool` protocol, calling modes, and the required-mode loop](03-tools-and-tool-calling.md) — prerequisite
- [2.2 — `@Generable`, `@Guide`, dynamic schemas, snapshot streaming](02-guided-generation-and-streaming.md) — pipeline stages are `Generable`
- [2.5 — Image input, and what the model cannot do with pixels](05-image-input-and-attachments.md) — required for the Vision tools
- [2.6 — The complete failure taxonomy](06-availability-errors-and-guardrails.md) — `contextSizeExceeded`, `LanguageModelError -1`
- [3.1 — Token budgeting, transcript anatomy, KV-cache economics](../../part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md) — where the ~13k tokens land
- [3.2 — Dynamic Profiles, modifiers, session properties](../../part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md) — the shipping form of `toolCallingMode`
- [4.2 — Core AI, MLX, and any OpenAI-compatible server](../../part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md) — §15's model constraints
- [6.3 — `SampleGenerator` and `TrajectoryExpectation`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md) — §16 in full
- [16.3 — Entities, Spotlight, and Foundation Models: one index, three consumers](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md) — §2.3 from the App Intents side
- [1.2 — Every version, hardware, entitlement and runtime-surface gate](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/references/02-platform-and-version-gating.md)

---

*Sources for this guide: Apple's sample project **"Searching indexed content with natural language"**
— the hiking-trails app, target `LLMSearchUsingCoreSpotlightApp`, 6 Swift files / 792 lines, iOS 27,
Swift 6 — downloaded and read in full, and treated as top-tier evidence · Apple's **Book Tracker**
Evaluations sample, for §16's type names · WWDC26 session 246 ("LLM search using Core Spotlight",
Jennifer, Spotlight engineering team, 138 lines, read in full) · WWDC26 session 241 ("What's new in
Foundation Models") · WWDC26 session 343 and Apple's "Making app entities available in Spotlight"
documentation, for §2.2–2.3 · Apple documentation for Foundation Models (June 2026 updates,
tool-calling article, generation options) · Apple Developer Forums threads 832534, 833560, 833651,
833658, 833692, 837226, 838613, 838904 · a community field-verification note dated 2026-06-13
(macOS 27 beta, M4 Max) that ran the tool behind a third-party model · `NoemaSpotlightIndexing.swift`
from a shipping iOS app. Where the sample and the field note disagree, the sample wins and the guide
says so. Every number is attributed at its point of use. Nothing in this guide was written from
memory.*
