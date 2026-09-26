# One index, three consumers: entities, Spotlight, and Foundation Models

**Part 16 · Adjacent capabilities · Reference 04**

**Version floor: the 27 releases — iOS 27, iPadOS 27, macOS 27, visionOS 27, with Xcode 27.** That
is the floor for the *new* half of this guide: `SpotlightSearchTool` (**27.0**, and **no watchOS**
— Apple's platform sentence omits it, and the SDK declaration now attests it, adding tvOS to the
unavailable list — §7.1), `IndexedEntityQuery` (**27.0**, Apple's own word is *"the
new"*), `RelevantEntities` / `AppEntityContext` (**27.0**), and the `protectionClass` overload of
the index-delegate hydration method (**27.0**).

It is emphatically **not** the floor for the other half. The indexing machinery this guide is about
is old. `CSSearchableIndex`, `CSSearchableItem`, `CSSearchableItemAttributeSet` and
`CSSearchableIndexDelegate` predate 26.0 by years. The hydration method at the centre of §9 —
`searchableItems(forIdentifiers:searchableItemsHandler:)` — is reported as **macOS 15.4+**, which
directly contradicts session 246's framing of it as new, and §9.4 covers that conflict rather than
smoothing it over. `IndexedEntity` itself floors at **macOS 15.0 / iOS 18.0 / visionOS 2.0**, with
watchOS and tvOS unavailable — ✅ **SDK-verified**
(`AppIntents-27.0-macos.swiftinterface:2608-2609`); former gap G1, closed 2026-07-29 (§4.1, §15).

**SDK-interface pass, 2026-07-29.** This guide's claims were re-checked against the SDK module
interfaces in `notes/sdk-interfaces/` — `AppIntents` and `CoreSpotlight`, 26.5 and 27.0-beta macOS
surfaces, plus the cross-import overlay that actually declares `SpotlightSearchTool`
(`_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface`, 513 lines) — all 27.0 files captured
from the real macOS 27.0 SDK in Xcode 27 beta. Confirmed claims are marked ✅ **SDK-verified**
with `file:line` citations; gaps the interfaces close are closed below; gaps they cannot reach say
so — Objective-C API (`CSSearchableIndexDelegate` and the attribute-set properties among it) does
not appear in any Swift module interface.

The single practical consequence of that split: **the index is older than the intelligence that
reads it.** You are not adopting a new subsystem. You are pointing three new consumers at a
subsystem you may already have, and the failure modes in §13 are almost all failures of *content*,
not of API.

---

## What this covers

There was an unanswered question sitting in the middle of this series' research corpus, and it is
worth stating before anything else because this guide exists to answer it.

WWDC26 session 246 — the Spotlight-plus-Foundation-Models session — sets up `SpotlightSearchTool`
with a one-sentence prerequisite:

> ✅ **VERIFIED** — WWDC26 session 246, transcript line 24, verbatim: *"Once your app has donated
> searchable items to Core Spotlight, **or indexed entities for Apple Intelligence**, we're ready to
> begin."*

Everybody who read that sentence understood the first clause. Nobody could identify the second one.
Our own research note recorded it as an open question — *"an interesting second on-ramp… **UNVERIFIED**
how that path differs"* — and it stayed open through two research passes.

**It is resolved.** "Indexed entities for Apple Intelligence" is `IndexedEntity` +
`CSSearchableIndex.indexAppEntities(_:)`, the App Intents indexing API. It is not a second index.
It is the *same* Core Spotlight index, written through a different door.

Which produces the thesis of this guide, and the reason it is worth a guide rather than a footnote:

> **App Intents entities and Core Spotlight items land in the same semantic index, and that one
> index is read by three different consumers: Siri's entity resolution, `SpotlightSearchTool`
> (i.e. your own on-device model doing RAG), and Spotlight search itself.**

One indexing investment serves three surfaces. And — the part that actually changes how you
prioritise work — **a gap in your indexing degrades all three at once, silently, with no error at
any layer.** An entity you forgot to index is invisible to Siri, invisible to your own language
model, and invisible in Spotlight, and nothing in any of those three code paths throws.

The guide covers:

- **§1–§2 — The resolved question, and the architecture.** What the second on-ramp is, with the
  diagram, and what "one index, three consumers" buys and costs.
- **§3 — On-ramp A: `CSSearchableItem` donation.** The classic path, complete, from
  `CSSearchableItemAttributeSet` through batching and client state to custom attribute keys —
  all of it read out of Apple's shipping sample project for session 246.
- **§4 — On-ramp B: `IndexedEntity` + `indexAppEntities(_:)`.** The App Intents path. One protocol
  conformance, `@Property(indexingKey:)`, `customIndexingKey:`, and `IndexedEntityQuery` for
  servicing reindex requests.
- **§5 — Precisely where the two differ**, including the three things only one of them gives you.
- **§6–§8 — The three consumers**, one section each, with what each one actually needs from your
  index and what it does when the index is thin.
- **§9 — The hydration hook.** `searchableItems(forIdentifiers:searchableItemsHandler:)` — why it
  exists (some Spotlight metadata is stored in a compact searchable-but-not-readable form the model
  cannot read), what its exact signature is (⚠️ it is a **completion-handler** method, `nonisolated`
  and **non-throwing** — it does not return an array, and getting this wrong is a compile error at
  best and a silent no-op at worst), and the two field reports that contradict Apple's design story.
- **§10 — The gap that stays open**, stated as sharply as we can state it, with a safe default.
- **§11 — Session 343's three retrieval paths** and the data-shape rule for choosing between them.
- **§12 — `RelevantEntities`**, the third discovery mechanism, and Apple's own three-way decision
  rule for Spotlight vs. donations vs. relevance.
- **§13 — Failure modes**, including four silent ones.
- **§14 — The adoption sequence.** What to index first for the best return across all three
  consumers, which is not the order you would guess.

## What this does *not* cover

- **How to use `SpotlightSearchTool` itself.** Configuration members, the `SearchReply` stream,
  `queryToken`, guidance levels and their token cost, custom pipeline stages, the contact resolver,
  the three documented failure modes, and evaluation are all
  [Part 2 guide 04 — Local RAG with `SpotlightSearchTool`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md).
  This guide covers the *index* side and the *architecture*, and cross-links rather than repeats.
  Where a number from that guide is load-bearing here — the guidance token gate, above all — it is
  restated in one line with a pointer, not re-derived.
- **App schema domains.** Which domains exist, what each contains, what has no domain at all, and
  the discovery-versus-action distinction are
  [Part 16 guide 02 — App Schema Domains](02-app-schema-domains.md). §6 assumes you have read the
  discovery/action framing or are willing to take it on trust.
- **On-screen awareness.** `EntityIdentifier`, the four annotation shapes, and the verified
  `.files.file` hand-off recipe are Part 16 guide 03. Entity *annotation* is a different mechanism
  from entity *indexing* and the two are constantly conflated; §6.4 draws the line and stops.
- **Writing `AppIntent`s.** Nothing here requires you to have any intents at all. Indexing is a
  discovery mechanism; it works on entities that no intent ever accepts as a parameter.
- **Core Spotlight donation best practice.** Apple defers this to a WWDC25 session — *"Supporting
  semantic search with Core Spotlight"* — which is **not in this corpus**. §3 covers what Apple's
  2026 sample does, which is a working reference but not a best-practice treatment.

## What you need

- **An app with content worth finding.** This is the actual prerequisite and it is not a joke: the
  three consumers are all retrieval surfaces, and retrieval over ten items is not worth the code.
  §14's first step is a triage, not an API call.
- **Xcode 27 and a device or Mac on 27.0** if you want the `SpotlightSearchTool` consumer. The other
  two consumers work against older indexes; only the model-facing one is gated on 27. (The entity
  on-ramp itself needs iOS 18 / macOS 15 — §4.1.)
- **No entitlement.** ✅ **VERIFIED** — Apple's session-246 sample project ships an `.entitlements`
  file containing an empty `<dict/>`. `SpotlightSearchTool` is not a managed capability. Neither is
  Core Spotlight indexing. There is no request form and nothing lands in your provisioning profile.
- **`import CoreSpotlight`** for on-ramp A, **`import AppIntents` and `import CoreSpotlight`** for
  on-ramp B, and — for the model consumer — **both `CoreSpotlight` and `FoundationModels` in the
  same file**, because `SpotlightSearchTool` lives in a cross-import overlay and does not exist
  until both are imported (Part 2 guide 04 §3). That overlay is now a captured artifact — a real
  module named `_CoreSpotlight_FoundationModels` whose interface `@_exported import`s both parent
  frameworks, which is the import requirement made literal
  (✅ `_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface:6-7`).

---

## ⚠️ Read this before you trust a symbol name below

Four things about the evidence in this guide, because this landscape is beta-era and a meaningful
fraction of the API spellings in public circulation were reconstructed from *spoken* WWDC narration.

**First: the strongest evidence here is a compiling Apple sample project.** The session-246 sample —
Apple's own, target `LLMSearchUsingCoreSpotlightApp`, `IPHONEOS_DEPLOYMENT_TARGET = 27.0`,
`SWIFT_VERSION = 6.0`, six Swift files and 792 lines total — was obtained and read. Every signature
in §3 and §9 marked ✅ with a file-and-line citation came out of it. That outranks the transcript
everywhere the two disagree, and in §9 they *do* disagree.

**Second: the App Intents side has a weaker evidence class, and I am not going to pretend
otherwise.** There is no Apple sample project in this corpus that indexes via `indexAppEntities`.
What there is: Apple's published code-sample block on the session 343 page (which is a separate
artifact from the transcript prose, so agreement between them is genuine corroboration), Apple's
documentation page *"Making app entities available in Spotlight"* read through a docs mirror, and
one accepted answer from an Apple engineer on the developer forums. That is evidence classes 3 and
4, not class 1. §4 marks accordingly.

**Third: two of this guide's most useful facts are community-measured and are labelled as such
every single time they appear.** Both come from developers testing on 27.0 betas, both contradict
Apple's narration, and both are the kind of thing you would rather know before shipping. They are
never presented as Apple figures.

**Fourth — added 2026-07-29: the SDK module interfaces now sit above all of it.** Every symbol
below was checked against the `AppIntents` and `CoreSpotlight` Swift interfaces from the 26.5 and
27.0-beta macOS SDKs, plus the cross-import overlay module
`_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface`, which is where `SpotlightSearchTool`,
`CoreSpotlightSource` and `GuidanceProfile` actually live (`notes/sdk-interfaces/`).
✅ **SDK-verified** (`file:lines`) marks a declaration read from those files, and it outranks even
the compiling sample — it is the SDK the compiler sees. The one remaining blind spot is stated
where it matters: Objective-C declarations (`CSSearchableIndexDelegate`, the
`CSSearchableItemAttributeSet` properties, the item-deletion methods) do not appear in any Swift
module interface, so §9's hydration signature keeps its sample-class evidence.

Markers used throughout:

> ✅ **SDK-verified** — read from an SDK module interface in `notes/sdk-interfaces/`, cited as
> `filename:lines`. The strongest marker in the guide.

> ✅ **VERIFIED** — quoted from Apple's sample project, Apple's published code samples, an Apple
> documentation page, an Apple-staff forum answer, or a WWDC transcript. The citation follows.

> 🟡 **RECONSTRUCTED** — the concept is attested; the exact spelling is inferred. Treat the shape as
> right and the identifiers as provisional.

> 🔴 **GAP** — we could not verify it and are saying so rather than inventing. Each gap box names
> what is unknown, what would resolve it, and a safe default.

---

## Contents

1. [The question, and its answer](#1-the-question-and-its-answer)
2. [The thesis: one index, three consumers](#2-the-thesis-one-index-three-consumers)
3. [On-ramp A: `CSSearchableItem` donation](#3-on-ramp-a-cssearchableitem-donation)
4. [On-ramp B: `IndexedEntity` and `indexAppEntities(_:)`](#4-on-ramp-b-indexedentity-and-indexappentities)
5. [Where the two on-ramps differ](#5-where-the-two-on-ramps-differ)
6. [Consumer 1 — Siri entity resolution](#6-consumer-1--siri-entity-resolution)
7. [Consumer 2 — `SpotlightSearchTool`, i.e. your own model](#7-consumer-2--spotlightsearchtool-ie-your-own-model)
8. [Consumer 3 — Spotlight search itself](#8-consumer-3--spotlight-search-itself)
9. [The hydration hook, and why it exists](#9-the-hydration-hook-and-why-it-exists)
10. [🔴 The gap that stays open](#10--the-gap-that-stays-open)
11. [Session 343's three retrieval paths](#11-session-343s-three-retrieval-paths)
12. [`RelevantEntities` — the third discovery mechanism](#12-relevantentities--the-third-discovery-mechanism)
13. [Failure modes, four of them silent](#13-failure-modes-four-of-them-silent)
14. [The adoption sequence](#14-the-adoption-sequence)
15. [Gap index, evidence ledger, related guides](#15-gap-index-evidence-ledger-related-guides)

---

## 1. The question, and its answer

### 1.1 The sentence nobody could parse

Session 246 is the session where Apple introduces `SpotlightSearchTool`, the `Tool` conformer that
lets a `LanguageModelSession` write and run queries against your app's Core Spotlight index. It is
the framework's answer to "how do I do retrieval-augmented generation on device without shipping a
vector database."

Before showing any of that, the presenter states a prerequisite:

> ✅ **VERIFIED** — WWDC26 session 246, lines 22–24, verbatim:
>
> *"Before we get started, you'll want to make sure your app **donates searchable content with Core
> Spotlight**. Take a look at our past session on 'Supporting semantic search with Core Spotlight',
> where we talk through how to donate searchable content to Spotlight, how to manage donations with
> a delegate and reindex extension, and how to perform structured search over item attributes, and
> search against the semantic index.*
>
> *Once your app has **donated searchable items to Core Spotlight**, **or indexed entities for
> Apple Intelligence**, we're ready to begin."*

Read that last sentence again. It offers two on-ramps as alternatives, in an "or" construction, and
then never mentions the second one again for the remaining 114 lines of the session. There is no
code for it. There is no cross-reference for it. The demo app — hiking trails — uses the first
on-ramp exclusively.

So the question that sat open: **what is an "indexed entity for Apple Intelligence"?** Plausible
readings included a separate Apple Intelligence–specific index, a privileged donation path available
only to schema-conforming types, and a rename of something in Core Spotlight. All three are wrong.

### 1.2 The answer

> ✅ **VERIFIED** — Apple documentation, *"Making app entities available in Spotlight"*
> (`developer.apple.com/documentation/appintents/making-app-entities-available-in-spotlight`), read
> through the sosumi.ai docs mirror, plus WWDC26 session 343 chapter 11:59 *"Semantic index with
> `IndexedEntity`"*.
>
> The second on-ramp is the **`IndexedEntity` protocol** plus
> **`CSSearchableIndex.indexAppEntities(_:priority:)`**.

That is the whole answer. An "indexed entity for Apple Intelligence" is an `AppEntity` that
conforms to `IndexedEntity` and has been passed to `indexAppEntities(_:)`.

✅ **SDK-verified** (`AppIntents-27.0-macos.swiftinterface:361-367`): the method is declared
`public func indexAppEntities(_ appEntities: [some IndexedEntity], priority: Int = 0) async
throws`, in an `extension CSSearchableIndex` gated `@available(macOS 15.0, iOS 18.0, visionOS
2.0, *)`. Note which module declares it: **AppIntents extends the Core Spotlight class** — the
cross-framework arrangement this section describes is literal, down to the module boundary.

Three things follow immediately, and each one matters more than the naming trivia:

**It is not a different index.** `indexAppEntities(_:)` is a method *on `CSSearchableIndex`*. It
takes the same receiver you would call `indexSearchableItems(_:)` on. The content goes to the same
place. Session 246's "or" is not offering you a choice of destination; it is offering you a choice
of *door*.

**It is not gated on schema adoption.** You do not need `@AppEntity(schema:)` to conform to
`IndexedEntity`. A plain custom `AppEntity` can be indexed. What schema adoption buys you is
covered in §6 and in [Part 16 guide 02](02-app-schema-domains.md) — and it is *action*, not
discovery. This distinction is the single most clarifying idea in the whole App Intents area and it
is Apple's own:

> ✅ **VERIFIED** — Apple documentation, *"Making actions and content discoverable by Apple
> Intelligence"*: discovery is a **runtime** concern satisfied by **indexing** — *"Submit your
> entities to the Spotlight semantic index so the system indexes your app's content and matches it
> to requests"* — while action is a **build-time** concern satisfied by **schemas**. And then, in
> the same document: *"Without both layers, Apple Intelligence cannot act on user requests involving
> your entities."*

**It is minimal to adopt.** One protocol conformance, and Apple says so in as many words:

> ✅ **VERIFIED** — Apple documentation, *"Making app entities available in Spotlight"*, verbatim:
> *"Adding this protocol to your entity's declaration is the only requirement for support."*
> `IndexedEntity` supplies default implementations for all defined properties; you override
> selectively.

### 1.3 Why this was hard to find, and why it matters that it was

The reason the sentence in §1.1 defeated readers is structural, not accidental: **the two on-ramps
are documented by two different teams in two different framework silos, and neither one links to
the other.**

Search the Core Spotlight documentation and you find `CSSearchableItem`, attribute sets, batching,
and the index delegate. Search the App Intents documentation and you find `IndexedEntity`,
`@Property(indexingKey:)`, and `IndexedEntityQuery`. The word "Spotlight" appears in both. The fact
that they write to the same store appears prominently in neither. Session 246 is a Core Spotlight
session that mentions entities once; session 343 is an App Intents session that mentions Foundation
Models never.

That silo is worth naming because it predicts the class of mistake this guide is trying to prevent.
Teams adopt one on-ramp, ship it, and then months later start a second, parallel indexing project
for the other consumer — because nothing in either doc set told them the first project already
covered it. The corollary is more expensive: teams that under-invest in indexing under-invest in
three product surfaces simultaneously, and see the deficit in only one of them, so they debug the
wrong layer.

### 1.4 What the corroboration looks like

Three independent artifacts say the same thing, which is why this is marked ✅ rather than 🟡.

**Apple's documentation for the entity path**, quoted above, plus its own summary line:

> ✅ **VERIFIED** — Apple documentation, App Intents, on schema-typed entities: *"Entity schemas
> contribute your app's content to the **Spotlight semantic index**, enabling personal context
> understanding with attribution back to your app."*

**Apple's Core Spotlight documentation for the index**, which states the dual nature that makes the
whole arrangement work:

> ✅ **VERIFIED** — Apple documentation, Core Spotlight: the index supports *"fast **lexical and
> semantic** searches"* — word matching and meaning-based retrieval over the **same** index.

**An Apple engineer, on the developer forums, answering exactly the interop question**, and this is
the strongest single sentence in the whole file because it names both frameworks in one breath:

> ✅ **VERIFIED** — Apple Developer Forums thread **833658**, answer marked accepted, from an
> **Engineer (Apple)**, verbatim:
>
> *"`IndexedEntity` is **backed by a `CSSearchableItem`** that can be extended with any additional
> metadata on the item, whether system attributes or custom attributes, and are available for in-app
> search with any of CoreSpotlight's query APIs, **including `SpotlightSearchTool`**.*
>
> *For reasoning over custom attributes, you can describe them in the instructions for your language
> model session, or use dynamic guidance in `SpotlightSearchTool`'s configuration."*

"Backed by a `CSSearchableItem`" is the mechanism, stated by Apple, in a sentence that also confirms
the Foundation Models consumer reaches it. That closes the question posed in §1.1 with no
reconstruction required.

---

## 2. The thesis: one index, three consumers

### 2.1 The diagram

```text
   ┌──────────────────────────────┐      ┌──────────────────────────────┐
   │   ON-RAMP A                  │      │   ON-RAMP B                  │
   │   Core Spotlight             │      │   App Intents                │
   │                              │      │                              │
   │   CSSearchableItem           │      │   AppEntity : IndexedEntity  │
   │   + CSSearchableItemAttribute│      │   + @Property(indexingKey:)  │
   │     Set                      │      │   + customIndexingKey:       │
   └──────────────┬───────────────┘      └──────────────┬───────────────┘
                  │                                     │
   index.indexSearchableItems(_:)      index.indexAppEntities(_:priority:)
                  │                                     │
                  └──────────────────┬──────────────────┘
                                     ▼
              ╔══════════════════════════════════════════════╗
              ║        ONE CSSearchableIndex(name:)          ║
              ║                                              ║
              ║   lexical matching  +  semantic matching     ║
              ║   system attributes +  custom attributes     ║
              ╚══════════════════════════════════════════════╝
                 │                   │                   │
      ┌──────────┘                   │                   └──────────┐
      ▼                              ▼                              ▼
┌───────────────┐          ┌───────────────────┐          ┌──────────────────┐
│ CONSUMER 1    │          │ CONSUMER 2        │          │ CONSUMER 3       │
│ Siri / Apple  │          │ SpotlightSearch   │          │ Spotlight search │
│ Intelligence  │          │ Tool              │          │ (the OS UI)      │
│               │          │        │          │          │                  │
│ entity        │          │        ▼          │          │ user types,      │
│ resolution    │          │ LanguageModel     │          │ user gets hits   │
│ "play the     │          │ Session           │          │                  │
│  running mix" │          │ (your own RAG)    │          │                  │
└───────────────┘          └───────────────────┘          └──────────────────┘
      │                              │                              │
      │  needs: findable entities    │  needs: READABLE attributes  │
      │  + a schema to ACT (§6)      │  (§7, §9 — this is the       │
      │                              │   one that breaks)           │
      └──────────────────────────────┴──────────────────────────────┘
                    all three degrade together, silently
```

Two arrows in, one store, three arrows out. Everything in this guide is a detail hanging off that
shape.

### 2.2 What "the same index" actually means, operationally

It is worth being concrete about what is shared and what is not, because "the same index" is doing a
lot of work in that sentence.

**Shared: the store, the matching engine, and the attribute vocabulary.** An item written by
`indexAppEntities(_:)` and an item written by `indexSearchableItems(_:)` are both
`CSSearchableItem`s — Apple's engineer said so in §1.4 — with attribute sets drawn from the same
namespace, matched by the same lexical and semantic machinery. A query does not know or care which
door a result came through.

**Shared: the index identity.** `CSSearchableIndex(name:)` names an index. Both on-ramps are methods
on that object. If you use a named index for one and the default index for the other, you have two
indexes, and no amount of protocol conformance will merge them. This is the most mechanical way to
accidentally defeat the whole architecture, and §3.2 covers why Apple pushes named indexes anyway.

**Not shared: the maintenance protocol.** Reindex requests for `CSSearchableItem`-donated content
go to `CSSearchableIndexDelegate`. Reindex requests for entity-indexed content go to
`IndexedEntityQuery`. Session 343 is explicit that this is an either/or rather than a both:

> ✅ **VERIFIED** — WWDC26 session 343, verbatim: *"Spotlight may need your app to reindex its
> entities. Your app can support reindexing by adopting the new `IndexedEntityQuery`. … **If your
> project already supports reindexing with Core Spotlight-level APIs, you do not need to define an
> `IndexedEntityQuery`.**"*

**Not shared — and this is the open question of the whole guide: the hydration path.** §9's
`searchableItems(forIdentifiers:searchableItemsHandler:)` lives on `CSSearchableIndexDelegate`.
Whether it fires for entity-indexed content is 🔴 unverified. §10 is that gap, in full, with a safe
default.

### 2.3 The upside, stated as a budget argument

Three product surfaces. One body of work. That is the pitch, and it survives contact with the
details better than most architecture pitches do, because the *expensive* part of indexing is not
the API call.

The expensive part is:

1. Deciding **what counts as an indexable unit** in your data model. (A trail? A trail *report*? A
   photo attached to a trail report?)
2. Producing a **good title and description** for each unit — text a stranger could rank.
3. Choosing which of your fields map to **system attributes** rather than dying as untyped strings.
4. Keeping the index **fresh** on create, update and delete.

All four are consumer-agnostic. Every hour spent on them pays into Siri, into your model, and into
Spotlight. Nothing in that list is specific to Foundation Models, and nothing in it is thrown away
if you later decide the language-model feature is not worth shipping.

That is a genuinely unusual property. Most AI-adjacent work in this stack is load-bearing only for
the AI feature. Indexing is not.

### 2.4 The downside, which is the same fact wearing a different hat

Run the argument backwards and it is a warning.

**One thin index starves three consumers.** If your items carry a title and nothing else:

- **Siri** can find them by name and can hand them to an intent, and that may genuinely be enough —
  entity resolution is mostly a name-matching problem.
- **Spotlight search** shows the user a list of titles, which is a degraded but recognisable
  version of the feature.
- **Your language model** gets titles, has no bodies to reason over, and — because a language model
  never declines to answer for want of evidence — **writes a plausible answer anyway**. §7.3 and
  §13.1 are that failure in detail. It is the worst of the three failure modes because it is the
  only one that produces confident output.

**And the diagnosis is misdirected by default.** The symptom appears in the model. The cause is in
the index. Developers who see hallucinated content from a Spotlight-grounded session reach for
prompt engineering, then for a different model, then for guidance profiles — three layers, none of
which is where the problem is. §13 leads with this because it is the most common wasted week in the
area.

### 2.5 A note on what "semantic" buys, and where it stops

The index does lexical *and* semantic matching (§1.4), and semantic matching is what makes
"waterfalls" retrieve an item whose text says "cascades". That is real and it is the reason this
architecture can be described as RAG-without-a-vector-database.

But there is a qualifier in session 343 that should not be smoothed over:

> ✅ **VERIFIED** — WWDC26 session 343, verbatim: *"**And depending on the App Intents domain**,
> indexing entities in Spotlight provides **semantic search** capabilities."*

> 🔴 **GAP (G2)** — **which App Intents domains get semantic search, and what an entity in an
> unmodelled domain gets instead.** Apple's sentence is conditional and the condition is never
> spelled out. The plain reading is that some domains are wired for semantic retrieval and others
> are not, leaving lexical matching only. Nothing in this corpus enumerates the semantic-enabled
> set.
>
> **What would resolve it:** an Apple documentation page or forum answer naming the domains, or an
> A/B test on device — index two entities with synonym-only overlap, one in a modelled domain and
> one in a custom domain, and query for the synonym.
>
> **Safe default:** do not architect a retrieval feature on the assumption that semantic matching
> will bridge your users' vocabulary to your content. **Put the synonyms in the item** — in
> `keywords`, in the description — and put the synonym expansion in your model instructions as
> well. Apple's own sample does exactly this and it is the single most transferable line in its
> prompt (§7.4). Belt and braces costs you nothing and removes a dependency on an unverified
> conditional.

---

## 3. On-ramp A: `CSSearchableItem` donation

This is the classic path and the one Apple's own 2026 sample uses. If your content is not already
modelled as `AppEntity`s, start here — and note that Apple's reference implementation for the
*Foundation Models* consumer chose this on-ramp, not the entity one, which tells you something about
where the load-bearing evidence is.

Everything in §3.1–§3.5 marked ✅ was read out of the session-246 sample project
(`SearchingIndexedContentWithNaturalLanguage`, target `LLMSearchUsingCoreSpotlightApp`, six Swift
files, `IPHONEOS_DEPLOYMENT_TARGET = 27.0`, `SWIFT_VERSION = 6.0`), with file and line.

### 3.1 The shape: one indexer object, three jobs

Apple's sample puts the index, the custom attribute keys and the delegate on a single object. That
is not incidental — the delegate has to be handed to `SpotlightSearchTool`'s configuration later, so
it needs an identity that outlives any one search, and the index it services has to be the same
object it was set on.

> ✅ **VERIFIED** — session-246 sample, `Indexer.swift:34-58`. The guide adds an explicit
> `@MainActor` so the singleton remains Swift 6-safe even when the app target does not use
> MainActor default isolation. The immutable custom key is `nonisolated(unsafe)` because it is
> intentionally read from nonisolated donation code; the index and shared delegate stay isolated:

```swift prelude:guide-context
import CoreSpotlight
import Foundation

@MainActor
final class SpotlightIndexer: NSObject, CSSearchableIndexDelegate {
    static let shared = SpotlightIndexer()

    let index = CSSearchableIndex(name: "TrailSearchSample")

    nonisolated(unsafe) static let distanceAttributeKey: CSCustomAttributeKey? = CSCustomAttributeKey(
        keyName: "distance",
        searchable: true,
        searchableByDefault: true,
        unique: false,
        multiValued: false
    )

    private override init() {
        super.init()
        index.indexDelegate = self
    }
}
```

Four facts in fifteen lines, and each of them is one people get wrong:

**`NSObject` subclass.** `CSSearchableIndexDelegate` is an Objective-C protocol. Your delegate has
to be an `NSObject` subclass, which means it cannot be a `struct` and cannot be an `actor`. The
`private override init()` + `super.init()` dance in the sample is a consequence of that, not
ceremony.

**A named index, not `.default()`.** ✅ Apple's documentation directs you to a named index for
production, and Apple's sample obeys. §3.2.

**`index.indexDelegate = self` at construction.** The delegate is a property on the index object, and
it must be set before anything queries. Set it in `init`, not lazily at first search.

**Custom attribute keys are constructed once, statically, and are optional.**
`CSCustomAttributeKey(keyName:searchable:searchableByDefault:unique:multiValued:)` returns an
optional — the initialiser can fail — which is why the sample's property type is
`CSCustomAttributeKey?` and why every use site unwraps. §3.5.

### 3.2 Why a named index

> ✅ **VERIFIED** — Apple documentation, *"Making app entities available in Spotlight"*, directs
> developers to use a **named** index rather than the default one in production. Apple's session-246
> sample independently does the same thing: `CSSearchableIndex(name: "TrailSearchSample")`.

Two artifacts, one from each on-ramp's documentation lineage, agreeing. Take the hint.

The practical arguments, which Apple does not spell out but which follow from the API shape:

- A named index is **yours**, so `deleteAll`-style operations and client-state bookkeeping (§3.4)
  are scoped to your content rather than racing whatever else your app writes.
- The `SpotlightSearchTool` configuration takes a `searchableIndexDelegate`, and the delegate is
  wired to *an index object*. Naming the index makes "which index does the tool search" answerable
  by reading one line of code.
- ⚠️ **And the trap:** if one part of your app indexes to `CSSearchableIndex(name: "X")` and another
  to the default index, you have two stores. Queries against one will never see the other. Nothing
  warns you. Pick one name, put it in a constant, and never write the initialiser twice.

### 3.3 Building the attribute set

This is where the actual work is, and where the quality of all three consumers is determined.

> 🟡 **RECONSTRUCTED** — the code below. Here is exactly how much is verified and how much is not,
> because this matters more than usual.
>
> **Verified:** the *attribute names* — `title`, `contentDescription`, `namedLocation`,
> `stateOrProvince`, `keywords`, `latitude`, `longitude`, `rating`, `duration`,
> `contentCreationDate`, `completionDate` — are read from the sample's `fetchAttributes` list
> (`Session.swift:116-134`), where they appear as static members of `SearchableItemAttribute`.
> As of 2026-07-29 those members are additionally ✅ **SDK-verified**: the CoreSpotlight 27.0
> interface declares `SearchableItemAttribute` (27.0, watchOS/tvOS unavailable) with every one of
> them as a static member (`CoreSpotlight-27.0-macos.swiftinterface:16-193`).
> Verified separately: the custom-key write, `attributeSet.setValue(_:forCustomKey:)`
> (`Indexer.swift:180`).
>
> **Not verified:** that `CSSearchableItemAttributeSet`'s *properties* carry those identical
> spellings, and the exact `CSSearchableItemAttributeSet` and `CSSearchableItem` initialisers. The
> sample's item-construction helper (`createSearchableItems(identifiers:)`) is referenced but its
> body was not in the extracted portion. `CSSearchableItemAttributeSet` and `CSSearchableItem` are
> **long-standing Core Spotlight API that predates this entire stack** — they are not 2026 surface
> and there is no reason to expect them to have changed — but they are not verified *by this
> session's evidence*, and being Objective-C they are invisible to the 2026-07-29 SDK-interface
> pass too, so they keep the 🟡 marker.
>
> **What to do about it:** type the property name and let Xcode's completion confirm it. Do not copy
> an attribute name out of a blog post; the `CSSearchableItemAttributeSet` surface is enormous and
> a large fraction of the names in circulation are `kMDItem…` constants from the Spotlight metadata
> layer rather than Swift property names.

```swift prelude:guide-context
import CoreSpotlight
import UniformTypeIdentifiers

extension Trail {
    /// One indexable unit. Everything three consumers will ever see about this trail
    /// has to be in here or reachable through §9's hydration hook.
    func makeSearchableItem() -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)

        // ---- identity: what the model and the user both read first
        attributes.title = name                       // "Cascade Falls Loop"
        attributes.contentDescription = summary       // one or two sentences, human-readable

        // ---- retrieval surface: this is what lexical matching actually chews on
        attributes.keywords = keywords                // ["waterfall", "creek", "shaded", "dog-friendly"]

        // ---- typed metadata: this is what STRUCTURED search can filter on
        attributes.namedLocation = trailheadName
        attributes.stateOrProvince = state
        attributes.latitude = NSNumber(value: coordinate.latitude)
        attributes.longitude = NSNumber(value: coordinate.longitude)
        attributes.rating = NSNumber(value: difficulty)      // 1...5
        attributes.duration = NSNumber(value: estimatedSeconds)
        attributes.contentCreationDate = addedDate
        attributes.completionDate = lastHikedDate

        // ---- custom attributes: your vocabulary, see §3.5
        if let key = SpotlightIndexer.distanceAttributeKey {
            attributes.setValue(NSNumber(value: distanceMiles), forCustomKey: key)
        }

        return CSSearchableItem(
            uniqueIdentifier: id.uuidString,          // the join key for EVERYTHING downstream
            domainIdentifier: "trails",
            attributeSet: attributes
        )
    }
}
```

Four decisions in that method are worth arguing about, because they are the ones that determine
whether the three consumers work.

**`uniqueIdentifier` is a join key, not a detail.** It is what comes back in a `CSSearchableItem`
from the tool's result stream, what the model quotes when it wants to chain to a second tool, and
what arrives at §9's hydration delegate. It must be stable across app launches, stable across
reindexes, and resolvable to your model object in O(1). A UUID string from your persistent store is
right. An array index is catastrophically wrong. A hash of the title is wrong the first time a user
renames something.

**`title` is read by all three consumers and by a human.** Spotlight shows it, Siri speaks it, the
model reasons over it and — because of §7.3 — may be reasoning over *nothing else*. A title that
reads well standing alone, out of context, is the single highest-leverage field in the whole
attribute set.

**`keywords` is where you buy vocabulary coverage cheaply.** Users do not search with your nouns.
Given §2.5's unresolved conditional about semantic matching, keywords are the reliable path from
"waterfall" to an item whose description says "cascade".

**Typed attributes are what make structured search possible at all.** A date stored as text in the
description is invisible to a date filter. `SpotlightSearchTool` advertises *"structured search over
metadata, like dates, persons, locations and more"* (session 246 line 68) — that capability is only
as good as the typing you did at donation time.

### 3.4 Batching, and the client-state pattern

Indexing item-by-item as your model changes is correct for incremental updates. Bulk indexing — the
first run, a migration, a restore — should batch.

> ✅ **VERIFIED** — session-246 sample, `Indexer.swift:62-88`, which uses the **async/await**
> spellings throughout: `index.fetchLastClientState`, `index.beginBatch()`,
> `try await index.indexSearchableItems(items)`, `try await index.endBatch(withClientState:)`.

```swift prelude:guide-context
extension SpotlightIndexer {
    /// Bulk-index with a client-state token, so an interrupted run resumes
    /// rather than restarting.
    func indexAll(_ trails: [Trail], version: Int) async throws {
        let lastState = try await index.fetchLastClientState()
        let lastVersion = Int(String(data: lastState, encoding: .utf8) ?? "") ?? 0
        guard lastVersion < version else { return }        // already current, do nothing

        index.beginBatch()
        try await index.indexSearchableItems(trails.map { $0.makeSearchableItem() })
        try await index.endBatch(
            withClientState: Data("\(version)".utf8)
        )
    }
}
```

The client state is opaque to Spotlight — it is whatever `Data` you put in it — and it is the
mechanism for answering "have I already done this?" without keeping a parallel record of your own.
The sample gates its entire seeding routine on it.

⚠️ **The batch is not a transaction.** `beginBatch()` / `endBatch(withClientState:)` bracket a run
so that the client state is committed atomically with respect to the items in it. If the process
dies mid-batch, the client state is not advanced and you re-run. It does not roll back items already
written. Design your seeding to be **idempotent** — same `uniqueIdentifier` in, same item out —
rather than assuming rollback.

### 3.5 Custom attributes: the round trip that reaches the model

Your app has fields Apple never modelled. Trail distance in miles. Roast level. Sprint velocity.
`CSCustomAttributeKey` is the mechanism, and there is a complete round trip in Apple's sample from
donation all the way to the language model's context.

**Write side** ✅ **VERIFIED** — `Indexer.swift:34-42` for the key, `Indexer.swift:180` for the set:

```swift illustrative
static let distanceAttributeKey: CSCustomAttributeKey? = CSCustomAttributeKey(
    keyName: "distance",
    searchable: true,             // the index will match on it
    searchableByDefault: true,    // it participates without being named in the query
    unique: false,
    multiValued: false
)

// at donation time:
attributeSet.setValue(NSNumber(value: distance), forCustomKey: key)
```

**Read side** ✅ **VERIFIED** — `Session.swift:127-129`. This is the part that is genuinely
non-obvious, and it is the answer to "how does a custom attribute become visible to the model":

```swift prelude:guide-context
if let key = SpotlightIndexer.distanceAttributeKey {
    attributes.append(SearchableItemAttribute(rawValue: key.keyName))
}
```

`SearchableItemAttribute` is a `RawRepresentable` struct with a public `init(rawValue:)` — ✅
**SDK-verified** (`CoreSpotlight-27.0-macos.swiftinterface:16-26`: `rawValue: String`,
`init(rawValue:)`, 27.0, watchOS/tvOS unavailable; absent from the 26.5 interface, so the type is
genuinely new this year). A `CSCustomAttributeKey`'s `keyName` goes straight into the tool's
`fetchAttributes` list. That is the bridge. Without it your custom attribute is searchable but
never surfaced to the model.

And then the third leg, which Apple's engineer names explicitly:

> ✅ **VERIFIED** — Developer Forums thread 833658, Engineer (Apple), accepted, verbatim: *"For
> reasoning over custom attributes, you can **describe them in the instructions** for your language
> model session, or use **dynamic guidance** in `SpotlightSearchTool`'s configuration."*

So the full custom-attribute round trip is **three** steps, not two:

| Step | API | Effect if you skip it |
|---|---|---|
| 1. Donate | `setValue(_:forCustomKey:)` with a `searchable: true` key | Value is not in the index at all |
| 2. Fetch | `SearchableItemAttribute(rawValue: key.keyName)` in `fetchAttributes` | Value is searchable but the model never sees it |
| 3. Explain | one line of session instructions giving units and meaning | Model sees `distance: 4.2` and does not know if that is miles, km, or minutes |

⚠️ Step 3 is the one teams skip, and its failure mode is *quiet wrongness* rather than absence: the
model answers using the number, with the wrong unit, confidently. Apple's own sample instructions
spell out units for every single attribute (§7.4). Copy that habit.

### 3.6 Deletion, and the obligation nobody schedules

Session 343 states the maintenance contract for the entity on-ramp, and it applies verbatim to this
one:

> ✅ **VERIFIED** — WWDC26 session 343, verbatim: *"**Index new entities** as people add content to
> your app. **Update existing entries when key properties change, especially those used in your
> display representation.** When people remove content, **delete those index entries** too."*

> 🔴 **GAP (G3) — half-closed 2026-07-29: the item-path deletion spelling is still unverified,
> but the entity-path spellings now are.** The 27.0 interface declares, alongside
> `indexAppEntities`: **`deleteAppEntities(identifiedBy: [Entity.ID], ofType:)`** and
> **`deleteAppEntities(ofType:)`**, both `async throws`, macOS 15.0 / iOS 18.0 / visionOS 2.0 —
> ✅ **SDK-verified** (`AppIntents-27.0-macos.swiftinterface:366-367`). Those are the on-ramp B
> spellings. The classic `CSSearchableIndex` deletion methods for donated *items* — keyed by
> identifier, by domain identifier, and for everything — are Objective-C API and do not appear in
> the Swift interface captures, so no spelling is quoted for on-ramp A.
>
> **What would resolve the rest:** any compiling call site, or the Objective-C header.
>
> **Safe default:** for items, type `index.delete` in Xcode and take the completion. Do not copy an
> item-deletion method name out of this guide or any other prose document — there is nothing to
> copy, deliberately.

The scheduling point matters more than the spelling. **Deletion is the maintenance duty that has no
natural trigger in most apps' code.** Creation and update happen where the user acts. Deletion of
*index* entries frequently happens nowhere, because the object is already gone by the time anyone
remembers, and there is no error to remind you. §13.2 is that failure mode in full: three consumers
confidently surfacing content that no longer exists.

---

<a name="4-on-ramp-b-indexedentity-and-indexappentities"></a>

## 4. On-ramp B: `IndexedEntity` and `indexAppEntities(_:)`

If your content is already modelled as `AppEntity`s — because you wrote App Shortcuts, or adopted a
schema domain, or built a Shortcuts integration — this on-ramp costs you a protocol conformance and
one call. If it is not, adopting `AppEntity` purely to get indexing is a larger project than
adopting `CSSearchableItem`, and §5.4 argues you should not do it.

⚠️ **Evidence-class warning, restated because it changes how you should read this section.** There
is **no Apple sample project in this corpus that calls `indexAppEntities`**. The evidence here is
Apple's published code-sample block on the session 343 page (a separate artifact from the transcript
prose, so their agreement is real corroboration), Apple's documentation page *"Making app entities
available in Spotlight"*, and one Apple-staff forum answer. Strong evidence — but not the compiling
first-party code that backs §3.[^indexed-entity-source]

### 4.1 Minimal adoption is one word

> ✅ **VERIFIED** — Apple documentation, *"Making app entities available in Spotlight"*, verbatim:
> *"Adding this protocol to your entity's declaration is the only requirement for support."*

```swift prelude:guide-context
import AppIntents
import CoreSpotlight

struct TrailEntity: AppEntity, IndexedEntity {
    var id: UUID
    var name: String
    var summary: String

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Trail")
    static let defaultQuery = TrailEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(summary)")
    }
}
```

That is it. `IndexedEntity` supplies default implementations for every indexed property, deriving
them from what your entity already has to provide — principally its `displayRepresentation`. You
override selectively.

Note what is *not* required: no `@AppEntity(schema:)`, no domain adoption, no intent. A plain custom
entity in an app category Apple never modelled can be indexed, and it will be findable. What it will
not be is *actionable* — see §6.2, and [Part 16 guide 02](02-app-schema-domains.md) for the full
treatment of that distinction.

> ✅ **RESOLVED (was GAP G1, closed 2026-07-29)** — **`IndexedEntity` floors at macOS 15.0 /
> iOS 18.0 / visionOS 2.0, with watchOS and tvOS unavailable.** The `AppIntents` module interface
> this gap asked for now exists in the corpus, and both captures agree:
> `@available(macOS 15.0, iOS 18.0, visionOS 2.0, *) public protocol IndexedEntity : AppEntity`
> (`AppIntents-27.0-macos.swiftinterface:2608-2609`;
> `AppIntents-26.5-macos.swiftinterface:11476-11479`, where the watchOS/tvOS-unavailable lines are
> explicit). Session 343's prior-art framing was right: it is 2024-era API. The protocol's surface
> is small — a `var attributeSet: CSSearchableItemAttributeSet` requirement with a default
> implementation, a `defaultAttributeSet`, and a `hideInSpotlight` flag added at macOS 15.4 /
> iOS 18.4 (`:868-889`).
>
> The former safe default hardens into a rule: the entity on-ramp needs
> `#available(iOS 18, macOS 15)`; property-level index mapping (§4.3) needs 15.4 / 18.4; and the
> `SpotlightSearchTool` consumer — verified 27.0 — stays the binding constraint on the
> model-facing feature as a whole.

### 4.2 The indexing call

> ✅ **VERIFIED** — Apple's published code sample for WWDC26 session 343 (timestamp 11:30), verbatim:

```swift prelude:guide-context
// Indexing IndexedEntity with CSSearchableIndex
struct EntityIndexingHelper {
    // Indexes playlist entities
    func indexPlaylist(_ playlist: Playlist) async throws {
        let entity = PlaylistEntity(playlist: playlist)
        try await CSSearchableIndex(name: indexName)
            .indexAppEntities([entity])
    }
}
```

`CSSearchableIndex(name:).indexAppEntities(_:)` — `async throws`, takes an array. ✅ Apple's
documentation gives the full signature as **`indexAppEntities(_:priority:)`**, so the priority
parameter has a default. ✅ **SDK-verified** — the declared signature, in full:

```swift prelude:guide-context
// AppIntents-27.0-macos.swiftinterface:361-367 — the AppIntents module extending the
// Core Spotlight class.
@available(macOS 15.0, iOS 18.0, visionOS 2.0, *)
extension CSSearchableIndex {
    public func indexAppEntities(_ appEntities: [some IndexedEntity], priority: Int = 0) async throws
    public func deleteAppEntities<Entity>(identifiedBy identifiers: [Entity.ID], ofType type: Entity.Type) async throws where Entity : IndexedEntity
    public func deleteAppEntities<Entity>(ofType entityType: Entity.Type) async throws where Entity : IndexedEntity
}
```

The documentation's own example, which is worth reproducing because it independently confirms both
the named-index convention and the method:

> ✅ **VERIFIED** — Apple documentation, *"Making app entities available in Spotlight"*:

```swift prelude:guide-context
try await CSSearchableIndex(name: "AppIntentsTravelTracking_Landmarks")
    .indexAppEntities(landmarkEntities)
```

Two artifacts, two different index names, same method, same named-index convention. Note also that
both construct `CSSearchableIndex(name:)` *at the call site* rather than holding one. That is fine —
the index is a handle to a named store, not a session — but §3.2's warning stands: put the name in
one constant.

> ✅ **RESOLVED (was GAP G4, closed 2026-07-29) — with a remainder.** **`priority:` is a
> `Swift.Int` defaulting to `0`** — the module interface this gap asked for now answers the type
> and default (`AppIntents-27.0-macos.swiftinterface:365`). The same `priority: Int` label
> appears on `CSSearchableItem(appEntity:priority:)` and `associateAppEntity(_:priority:)`
> (`:369-388`). What the number *means* — scheduling, ordering, thermal deferral — is still
> stated nowhere in the corpus, so the safe default stands: omit it, as both of Apple's call
> sites do.

### 4.3 Binding your properties to Spotlight keys

The default implementations get you a title and a subtitle. Getting your *content* into the index —
the body text, the dates, the numbers — means telling the framework which of your properties maps to
which Spotlight attribute.

> ✅ **VERIFIED** — Apple documentation, *"Making app entities available in Spotlight"*, plus WWDC26
> session 343. The property wrappers `@Property`, `@ComputedProperty` and `@DeferredProperty` all
> accept two mapping parameters:
>
> - **`indexingKey:`** — bind to an **existing Spotlight key** via key path, e.g.
>   `\.contentDescription`, `\.textContent`
> - **`customIndexingKey:`** — bind to an app-defined key via `CSCustomAttributeKey`

✅ **SDK-verified** for the entity wrapper: `@Property` inside an entity is `EntityProperty`
(`extension AppEntity { public typealias Property = EntityProperty }`,
`AppIntents-27.0-macos.swiftinterface:417-420`), and it gains
`init(indexingKey: PartialKeyPath<CSSearchableItemAttributeSet>)` and
`init(customIndexingKey: CSCustomAttributeKey)` — each with and without `title:` — at
**macOS 15.4 / iOS 18.4**, watchOS/tvOS unavailable (`:498-512`). So property-level index mapping
is one dot release newer than `IndexedEntity` itself. The parameter types also settle what the
key paths point into: `PartialKeyPath<CSSearchableItemAttributeSet>`, exactly as the examples
assume.

Apple's documentation example:

```swift prelude:guide-context
@AppEntity(schema: .messages.message)
struct MessageEntity: IndexedEntity {
    @Property(indexingKey: \.textContent)
    var body: AttributedString?
}
```

Applied to the running example, with the mapping made explicit:

> 🟡 **RECONSTRUCTED** — the pattern below. The wrappers, both parameter labels, and the
> `\.textContent` key path are ✅ verified from the documentation example above. The *other* key
> paths (`\.contentDescription`, `\.keywords`, `\.rating`) are inferred from the fact that
> `indexingKey:` takes a key path into the Spotlight attribute-set namespace, whose member names are
> verified from §3.3's `SearchableItemAttribute` list. The shape is right; confirm each key path
> with Xcode completion — `CSSearchableItemAttributeSet`'s property spellings are Objective-C and
> stayed outside the 2026-07-29 SDK-interface pass.

```swift prelude:guide-context
import AppIntents
import CoreSpotlight

struct TrailEntity: AppEntity, IndexedEntity {
    var id: UUID
    var name: String

    @Property(indexingKey: \.contentDescription)
    var summary: String

    @Property(indexingKey: \.keywords)
    var keywords: [String]

    @Property(indexingKey: \.rating)
    var difficulty: Double

    // A field Apple never modelled — bind it to your own key instead.
    @Property(customIndexingKey: TrailIndexKeys.distance)
    var distanceMiles: Double

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Trail")
    static let defaultQuery = TrailEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(summary)")
    }
}
```

⚠️ **One practical note on that custom key.** `CSCustomAttributeKey`'s initialiser is **failable** —
§3.1's verified sample declares its key as `CSCustomAttributeKey?` and unwraps at every use site. A
property wrapper argument cannot conveniently take an optional, so give the key a non-optional home
of its own rather than reaching for `!` inline:

```swift prelude:guide-context
enum TrailIndexKeys {
    /// Force-unwrapped exactly once, at a site where a nil key is a programmer error
    /// you want to hear about at launch rather than silently at index time.
    static let distance = CSCustomAttributeKey(
        keyName: "distance",
        searchable: true,
        searchableByDefault: true,
        unique: false,
        multiValued: false
    )!
}
```

**The mental model:** `@Property(indexingKey:)` is the entity on-ramp's equivalent of §3.3's
`attributes.contentDescription = summary`. Same destination, declared rather than assigned. That is
the single most useful sentence for anyone holding both APIs in their head at once — the two
on-ramps are not two systems, they are an imperative API and a declarative API over the same
attribute set.

⚠️ **And the corresponding hazard:** a property with **no** `indexingKey:` is not in the index. It
compiles. It works everywhere else in App Intents — it resolves, it displays, an intent can read it.
It is simply absent from all three consumers in this guide. There is no warning for an unmapped
property, because most properties legitimately should not be indexed. §13.3.

### 4.4 `DisplayRepresentation` is doing more work than you think

Because `IndexedEntity`'s defaults derive from it, and because session 343 lists an unusually long
set of consumers:

> ✅ **VERIFIED** — WWDC26 session 343, verbatim: *"Entity display representation can be used in
> **responses**, like when an entity has been created or updated. They are also used when **asking
> someone to choose between similar entities**, or when **answering questions about content in your
> app**. **Spotlight and Shortcuts** can use them, too."*

And Apple's own published sample for enriching one:

> ✅ **VERIFIED** — Apple code sample, session 343 @ 4:26:

```swift prelude:guide-context
// Enhanced DisplayRepresentation
@AppEntity(schema: .audio.song)
struct SongEntity {

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(artistName)",
            image: artworkImage
        )
    }
}
```

`DisplayRepresentation(title:subtitle:image:)`. This is why session 343's own adoption ladder puts
display representations *first*, before indexing (§14.1) — it is the input to the thing you are
about to do, and improving it improves the index, the disambiguation prompts, the Shortcuts UI and
the Spotlight result row simultaneously.

### 4.5 Servicing reindex requests with `IndexedEntityQuery`

Spotlight can ask your app to re-supply entities — after a migration, a recovery, a restore.

> ✅ **VERIFIED** — WWDC26 session 343, verbatim: *"Spotlight may need your app to reindex its
> entities. Your app can support reindexing by adopting the **new `IndexedEntityQuery`**. … If your
> project already supports reindexing with Core Spotlight-level APIs, you do not need to define an
> `IndexedEntityQuery`."*

> ✅ **VERIFIED** — Apple documentation, method shapes:
>
> ```swift
> func reindexEntities(
>     for identifiers: [PhotoEntity.ID],
>     indexDescription: CSSearchableIndexDescription
> ) async throws
>
> func reindexAllEntities(
>     indexDescription: CSSearchableIndexDescription
> ) async throws
> ```

✅ **SDK-verified** — the 27.0 interface declares exactly those two requirements on
`protocol IndexedEntityQuery : EntityQuery where Self.Entity : IndexedEntity`,
`@available(macOS 27.0, iOS 27.0, visionOS 27.0, *)`
(`AppIntents-27.0-macos.swiftinterface:4250-4254`). The 26.5 interface has no
`IndexedEntityQuery` at all — session 343's *"the new"* was accurate.

Applied:

```swift prelude:guide-context
import AppIntents
import CoreSpotlight

struct TrailEntityQuery: EntityQuery, IndexedEntityQuery {

    // The ordinary EntityQuery requirement.
    func entities(for identifiers: [TrailEntity.ID]) async throws -> [TrailEntity] {
        try await TrailStore.shared.trails(ids: identifiers).map(TrailEntity.init)
    }

    // Spotlight asks for a subset back.
    func reindexEntities(
        for identifiers: [TrailEntity.ID],
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        let entities = try await TrailStore.shared.trails(ids: identifiers).map(TrailEntity.init)
        try await CSSearchableIndex(name: Self.indexName).indexAppEntities(entities)
    }

    // Spotlight asks for everything back.
    func reindexAllEntities(
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        let entities = try await TrailStore.shared.allTrails().map(TrailEntity.init)
        try await CSSearchableIndex(name: Self.indexName).indexAppEntities(entities)
    }

    static let indexName = "TrailSearchSample"
}
```

> 🟡 **RECONSTRUCTED** — the body above. The two method signatures are ✅ SDK-verified, and so is
> the conformance question this note used to hedge: `IndexedEntityQuery` **refines**
> `EntityQuery`, so conforming to `IndexedEntityQuery` alone suffices — writing both, as above, is
> legal but redundant. `CSSearchableIndexDescription`'s members remain unexamined here because
> neither method body needs them.

Two things to take from Apple's sentence rather than from the code.

**It is an either/or.** If you already implement `CSSearchableIndexDelegate`'s reindex methods, you
do not need this. Apple says so directly. That is genuinely useful — it means an app that adopts
*both* on-ramps does not owe two reindex implementations.

**`reindexAllEntities` has to be affordable.** It is the "give me everything" call, on a schedule you
do not control, in a process the user is not looking at. If your store cannot enumerate everything
without a spike, this method is where that shows up. Batching (§3.4) applies to the entity on-ramp
too — `indexAppEntities(_:)` takes an array; feed it in chunks.

---

## 5. Where the two on-ramps differ

They write to the same store. They are not interchangeable. Here is the comparison, with the
evidence class on each row, because several of these rows are the whole reason to read this guide.

### 5.1 The table

| | **On-ramp A — Core Spotlight** | **On-ramp B — App Intents** |
|---|---|---|
| Unit of content | `CSSearchableItem` | `AppEntity` conforming to `IndexedEntity` |
| Index call | `index.indexSearchableItems(_:)` ✅ | `index.indexAppEntities(_:priority:)` ✅ |
| Attribute mapping | `CSSearchableItemAttributeSet` properties, assigned 🟡 | `@Property(indexingKey:)` / `customIndexingKey:` ✅ |
| Custom attributes | `setValue(_:forCustomKey:)` ✅ | `@Property(customIndexingKey:)` ✅ |
| Reindex servicing | `CSSearchableIndexDelegate` ✅ | `IndexedEntityQuery` ✅ (either/or, not both) |
| Batching | `beginBatch()` / `endBatch(withClientState:)` ✅ | chunk the array yourself 🟡 |
| Also gives you | nothing beyond search | Siri actionability (**with a schema**), on-screen annotation targets, Shortcuts, `RelevantEntities` |
| Prerequisite | none | your content modelled as `AppEntity` |
| Apple sample exists | ✅ yes — session 246, six files, compiling | ❌ none in this corpus |
| Semantic matching | index-wide ✅ | *"depending on the App Intents domain"* — conditional, 🔴 G2 |
| §9 hydration for the model | ✅ `searchableItems(forIdentifiers:searchableItemsHandler:)` | 🔴 **unverified — §10** |

### 5.2 The three things only on-ramp B gives you

These are the reason to prefer entities when your content already is one.

**Actionability, if — and only if — you also adopt a schema.** Indexing makes an entity findable.
A schema makes it *usable* as an intent parameter that Siri can fill without the user naming your
app. Apple's own framing, quoted in §1.2: *"Without both layers, Apple Intelligence cannot act on
user requests involving your entities."* And the community's independent read of the same boundary,
from the most-contested thread in the area:

> ✅ **VERIFIED** — Developer Forums thread **829586** (14 replies, ~1k views), reported from the
> Apple Intelligence Group Lab: *"1. Entity **discoverability** does NOT require conforming to
> whitelisted schema domains. 2. Siri can **only take actions** that DO conform to whitelisted
> schema domains."*

So: on-ramp B without a schema = the same discovery you would have got from on-ramp A, plus the
other two items below. On-ramp B *with* a schema = a qualitatively different product surface.
Which domains exist, and what to do when none of them fits, is [Part 16 guide 02](02-app-schema-domains.md).

**On-screen annotation targets.** `EntityIdentifier(for:identifier:)` binds a piece of your UI to an
entity instance, which is how "this" works. That requires an entity to point at; a `CSSearchableItem`
is not one. Part 16 guide 03 covers the four annotation shapes and the verified hand-off recipe.
⚠️ Note the constraint that catches people: `TransientAppEntity` cannot be used as an annotation
target — *"Transient entities are temporary model objects, so they don't have persistent
identifiers"* (✅ session 343) — and a transient entity has no business being indexed either, for
exactly the same reason.

**`RelevantEntities`.** The cold-start mechanism in §12 takes entities. It has no `CSSearchableItem`
equivalent. If you want to push newly-created content into system suggestion surfaces before anyone
has ever searched for it, you need entities.

### 5.3 The one thing only on-ramp A verifiably gives you

**A hydration path to the language model.** §9's delegate method is the documented answer to §7.3's
metadata gap, it lives on `CSSearchableIndexDelegate`, and it is wired into `SpotlightSearchTool`
through `CoreSpotlightSource(searchableIndexDelegate:)` — a parameter the overlay interface
declares verbatim (✅ `_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface:19-20`). Whether
an entity-indexed item ever reaches it is 🔴 unverified, and §10 is about nothing else.

This asymmetry is the practical core of the guide. On-ramp B is the better path for Siri. On-ramp A
is the verified path for your own model. If you want both consumers to work well and you cannot
wait for the gap in §10 to close, §10.3's safe default applies.

### 5.4 Choosing

A three-question decision, in order:

**1. Is your content already `AppEntity`s?**
Yes → on-ramp B is nearly free. Add `IndexedEntity`, map your properties, call
`indexAppEntities(_:)`. Then read §10 before you rely on the model consumer.
No → question 2.

**2. Do you want Siri to *act* on this content — not just find it?**
Yes → and there is a schema domain that fits ([guide 02](02-app-schema-domains.md)) → model your
content as entities and take on-ramp B. The indexing is the small part of that project; the schema
conformance is the big part, and it is worth it for the actionability alone.
No, or there is no domain that fits → question 3.

**3. Do you want a language model reasoning over this content?**
Yes → **on-ramp A**, because it is the path with a compiling Apple reference implementation, a
verified hydration hook, and no unresolved conditional on semantic matching. This is what Apple's
own session-246 sample chose for exactly this consumer.
No → either works; on-ramp A is less code if you are not otherwise in App Intents.

⚠️ **Do not adopt `AppEntity` solely to get indexing.** Conforming to `AppEntity` drags in an
`EntityQuery`, a `TypeDisplayRepresentation`, a `DisplayRepresentation`, identifier-stability
obligations, and — if you go on to a schema — a fixed property list that can dictate your identifier
type. `.photos.asset`, for instance, requires `id: Int` (✅ Apple documentation). That is a
meaningful modelling constraint to accept in exchange for something `CSSearchableItem` gives you in
twenty lines.

### 5.5 Can you use both?

Yes, and §10.3 recommends it in one specific circumstance. Nothing prevents an app from indexing
entities via `indexAppEntities(_:)` *and* donating `CSSearchableItem`s via
`indexSearchableItems(_:)` to the same named index.

Two cautions if you do:

**Identifier discipline becomes load-bearing.** If the same underlying object is indexed twice, once
through each door, you want it to carry the *same* `uniqueIdentifier` — otherwise all three
consumers see duplicates, and the model's context fills with two copies of everything. 🔴 It is
**unverified in this corpus what `uniqueIdentifier` an entity-indexed item receives** — whether it
is the entity's `id` stringified, a namespaced composition, or something else (this is part of gap
G5, §10). Until that is known, deliberate double-indexing risks either duplicates or accidental
overwrites, and you cannot predict which.

**You still owe only one reindex implementation.** Per §4.5's verified either/or, if you implement
`CSSearchableIndexDelegate`'s reindex methods you do not additionally need `IndexedEntityQuery`.

---

## 6. Consumer 1 — Siri entity resolution

The first consumer of the index is the one Apple markets: Siri, and Apple Intelligence behind it,
finding your content by name or description when the user speaks about it.

This section is deliberately short, because the *content* of what Siri does with entities is
[Part 16 guide 02](02-app-schema-domains.md) and guide 03. What belongs here is what this consumer
demands **of the index**, and what it does when the index is thin.

### 6.1 What it consumes

Session 240 — the foundational Siri/App Intents session — decomposes the new Siri into three
capabilities, and the first one is this consumer:

> ✅ **VERIFIED** — WWDC26 session 240, chapter 1:06: the three capabilities are *access app
> entities*, *take actions*, and *understand onscreen context*.

Entity access reads the index. Concretely, what it needs from you:

- **A findable name.** `displayRepresentation`'s title, which is also what
  `IndexedEntity`'s defaults derive from (§4.4). Siri's job at this layer is largely a matching
  problem, and titles are what it matches.
- **Freshness.** Session 343's maintenance rule (§3.6) exists mainly for this consumer — Siri
  answering about content the user deleted is worse than Siri not answering.
- **Nothing else, really.** This is the least demanding of the three consumers. An index that is
  useless for §7's language model — titles only, no bodies — can be entirely adequate here.

That asymmetry is worth internalising: **Siri needs a good index of *names*; your model needs a good
index of *content*.** Teams that index for Siri and then bolt on `SpotlightSearchTool` discover this
the hard way, and diagnose it as a model problem.

### 6.2 What indexing does *not* buy: the discovery/action wall

Restating the boundary because it is where most of the disappointment in this area comes from.

Indexing buys **discovery**. Siri can find your entity, refer to it, disambiguate between two of
them, and read its display representation aloud.

Indexing does not buy **action**. For Siri to route *"add the Cascade Falls trail to my reminders"*
into your app without the user naming your app, the intent has to conform to a published schema.
Apple's documentation says it (§1.2), the forum consensus confirms it (§5.2), and the practical
consequence is a wall: an app in a category with no schema domain — fitness, health, finance,
commerce, travel, food, transport, social, education, games — can be *discovered* and cannot be
*acted upon*.

The one hook that is reachable regardless is `.system.searchInApp`:

> ✅ **VERIFIED** — WWDC26 session 343, verbatim, corroborated by Apple's own published code sample
> for the session at timestamp 14:49: *"To do this, I'll adopt the system `.searchInApp` schema. The
> `.system` search schema introduced in iOS 17 is now named `.system.searchInApp`. It is part of the
> System App Schema domain, and it lets people search in your app with Siri, **no matter which other
> domains you adopt, and even if you don't index your entities**."*

Note the last clause: it is explicitly *independent* of indexing. It is not a consumer of the index
at all — it hands your app Siri's query string and gets out of the way. Full treatment, with code,
in [Part 16 guide 02 §8](02-app-schema-domains.md).

### 6.3 The availability coupling, and what to do about it

Both this consumer and §7's are behind Apple Intelligence enablement, and on 27 betas that gate has
been firing for the wrong reason.

> ✅ **VERIFIED** — Developer Forums thread **836760**, reply from an **Apple Frameworks Engineer**,
> verbatim: *"The Foundation Models framework should be available in Europe even if Siri AI is not
> enabled. Please file a bug report via Feedback Assistant and be sure to include a sysdiagnose to
> help us investigate."*

Two independent beta reports (threads 836760 on macOS, 835211 on iOS 27 beta 1) had
`SystemLanguageModel.default.availability` returning `.appleIntelligenceNotEnabled` unless the user
had switched on "Siri"/"Hey Siri" or "Press Side Button for Siri".

**Classification matters here.** This is a **known defect with an Apple acknowledgement**, not a
gate to design around. Do not build permanent UX that asks users to enable Siri in order to use your
language-model feature. Status as of 2026-07-27: acknowledged, unresolved. Handle
`.appleIntelligenceNotEnabled` gracefully because it will fire on current betas for reasons
unrelated to the user's actual intent — and note that this is Part 1's and Part 2's territory, not
this guide's; it appears here only because it affects two of the three consumers at once.

### 6.4 Indexing is not annotation — the line, drawn once

Two mechanisms, constantly conflated, with different requirements and different payoffs:

| | **Indexing** (this guide) | **On-screen annotation** (guide 03) |
|---|---|---|
| Question it answers | "what content does this app have?" | "what is *this*, on screen, right now?" |
| API | `indexAppEntities(_:)` / `indexSearchableItems(_:)` | `EntityIdentifier(for:identifier:)` + view modifiers |
| Lifetime | persistent, until deleted | the duration of the view |
| Consumed by | Siri, `SpotlightSearchTool`, Spotlight | Siri's on-screen path only |
| Needs a schema | no (for discovery) | for *hand-off*, in practice yes — see guide 03 |

⚠️ And the field observation that stops people building the wrong thing: **descriptive on-screen
questions never consult your entities at all.** Instrumented testing in Developer Forums thread
838329 on iOS 27 beta 3 (community-measured, one developer, one device) found that *"describe this
image"* and *"create a note for this"* take a screenshot/OCR path — `entities(for:)` was never
called — while only hand-off style requests entered entity resolution. A developer in thread 837249
built an entire `AppEntity` + `EntityQuery` layer for a class of request that does not use it.
Neither of those failures is an indexing failure, and neither is fixed by indexing harder.

---

## 7. Consumer 2 — `SpotlightSearchTool`, i.e. your own model

The second consumer is the one this series exists for: a `LanguageModelSession` doing
retrieval-augmented generation over your app's content, with the index as the retriever.

**This section covers the parts that are about the *index*.** How to configure the tool, consume its
result stream, use `queryToken`, register custom pipeline stages, run it behind a third-party model,
and evaluate it are all [Part 2 guide 04](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md).
Read that one to build the feature; read this one to understand why the feature is only as good as
what you donated.

### 7.1 What Apple actually announced

> ✅ **VERIFIED** — WWDC26 session 246, lines 19–21, verbatim: *"today, we're introducing
> **`SpotlightSearchTool`**. It's a tool that **adopts the tool protocol**, to let a language model
> **directly search your app's content in Core Spotlight** for contextual response generation.
> `SpotlightSearchTool` is available on **iOS, iPadOS, macOS, and visionOS**."*

⚠️ **watchOS is not in that list**, and the omission is now compiler-attested: the tool's real
declaration lives in the CoreSpotlight ↔ FoundationModels **cross-import overlay**, captured
2026-07-29 as `_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface`, and it reads
`@available(macOS 27.0, iOS 27.0, visionOS 27.0, *)` with **both watchOS and tvOS explicitly
unavailable** — ✅ **SDK-verified**
(`_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface:327-330`): `public struct
SpotlightSearchTool : FoundationModels.Tool, Sendable`, an ordinary `Tool` conformer exactly as
the session says. (The tool's model-facing *name* — `spotlight_search` — is a runtime `var name:
String` value, so that claim keeps its sample evidence.)

The tool is an ordinary `Tool` conformer. It goes into `LanguageModelSession(tools:)` like any
other, and the model decides when to call it. Its model-facing name is **`spotlight_search`** ✅
(verified twice: from Apple's sample instructions at `Session.swift:43` — *"Always use the
spotlight_search tool to search trails before answering. Never answer from memory."* — and from an
independently observed tool-call trajectory).

### 7.2 The whole configuration, from Apple's sample

Reproduced here in full because it is the one place the index side and the model side meet, and
because two of its members are index-facing.

> ✅ **VERIFIED** — session-246 sample, `Session.swift:116-158`:

```swift illustrative
    private static let fetchAttributes: [SearchableItemAttribute] = {
        var attributes: [SearchableItemAttribute] = [
            .title,
            .contentDescription,
            .namedLocation,
            .stateOrProvince,
            .keywords,
            .latitude,
            .longitude,
            .rating,
            .duration,
            .contentCreationDate,
            .completionDate
        ]
        if let key = SpotlightIndexer.distanceAttributeKey {
            attributes.append(SearchableItemAttribute(rawValue: key.keyName))
        }
        return attributes
    }()

    @MainActor
    private func makeSpotlightTool() -> SpotlightSearchTool {
        SpotlightSearchTool(
            configuration: .init(
                sources: [
                    .coreSpotlight(
                        .init(
                            searchableIndexDelegate: SpotlightIndexer.shared,
                            fetchAttributes: Self.fetchAttributes
                        )
                    )
                ],
                guide: isOnDevice ? .focused() : .complete
            )
        )
    }
```

✅ **SDK-verified** — every spelling in that block now has a declaration behind it, from the
overlay interface (`_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface`): the tool's
initialiser is `init(configuration: Configuration = Configuration(sources: [.coreSpotlight]))`
(`:384`); `SpotlightSearchTool.Configuration` is `init(sources: [SearchSource] = [], guide:
Guide? = nil, contactResolver: (any ContactResolver)? = nil, customStages: [any CustomStage] = [],
maximumResponseSize: Int? = nil)` (`:49-59`) — note the two members the sample never touches, a
contact resolver and custom pipeline stages, plus a `maximumResponseSize` knob;
`SearchSource.coreSpotlight(_:)` (`:35-44`, alongside a `.files(_:)` source the sample does not
use); `CoreSpotlightSource.init(searchableIndexDelegate: (any CSSearchableIndexDelegate)? = nil,
fetchAttributes: [SearchableItemAttribute] = [])` (`:15-22`, plus `maximumResultCount` and
`sourceOptions` properties); and `Guide` statics `.complete` / `.focused(_ domain: ContentDomain =
.items)` / `.dynamic(GuidanceProfile)` (`:61-80`).

Three index-facing observations:

**`searchableIndexDelegate:` is where §9's hydration hook gets wired.** The tool is handed *your
delegate object* — the same `SpotlightIndexer.shared` that owns the index and set itself as
`index.indexDelegate` in §3.1. That is the entire wiring.

**`fetchAttributes:` is where your donation decisions become model-visible.** Anything not in this
list is not surfaced. Anything in this list but never donated is empty. The list is the contract
between §3.3 and the model's context window, and the custom-key bridge on the second-to-last line is
§3.5's read side.

**`guide:` is a function of model capacity, not of content.** Apple's sample picks `.focused()` for
on-device and `.complete` for the server model. The reason is a token gate, and it is the number
that decides your architecture — restated here in one line because it constrains what §7.5's
scoping is *for*:

> **Community-measured** (`spotlight-rag-third-party.md`, one developer, macOS 27 beta, M4 Max,
> 2026-06-13): `.complete` guidance injects **~13k tokens** of tool instructions, which produces an
> immediate `contextSizeExceeded` on any 4k-context model. Ship `.focused()` + `format: .compact`
> for on-device. Attribution: community, not Apple. Apple's own statement is qualitative — *"On-device
> models have a more restricted model context size, so it's best to use FOCUSED guidance for simpler
> search capabilities"* (✅ session 246 line 80). Full treatment: [Part 2 guide 04 §10](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md).

### 7.3 ⚠️ SILENT FAILURE — the index is searchable but not readable

This is the defect that defines this consumer, and it is the reason §9 exists.

> ⚠️ **SILENT FAILURE.** ✅ **VERIFIED** — WWDC26 session 246, lines 49–51, verbatim:
>
> *"**You might notice from some responses, that the model was not able to see all of the metadata,
> that was donated for the items. That's because some metadata in the Spotlight index, like text
> content and HTML, is stored in a highly-compact representation that can be searched, but not
> recovered in a way that a language model can read it.** For these cases, you'll want to consider
> providing additional metadata for an item, while `SpotlightSearchTool` is performing a search."*

Read that twice. **The index is a retrieval structure, not a document store.** `textContent` in
particular is write-only from the reader's perspective: it participates in full-text matching and it
does not come back. The item that matched your user's question about waterfalls may have matched
*on text the model will never see.*

And the field measurement is worse than Apple's phrasing:

> **Community-measured** (`spotlight-rag-third-party.md`, macOS 27 beta / M4 Max, 2026-06-13):
> even with `CoreSpotlightSource(fetchAttributes: [.title, .contentDescription, .keywords])`, the
> `toolOutput` handed to the model carried **only identity attributes** — `uniqueIdentifier`,
> `title`, `contentType`, `contentCreationDate`, `domainIdentifier`. **`contentDescription` and
> `keywords` did not appear**, in either `.compact` or `.structured` format. The same author
> verified this is not a Spotlight limitation: a raw `CSSearchQuery` with the same `fetchAttributes`
> returned `contentDescription` fine.

**Now the failure.** A language model handed a list of titles does not report insufficient evidence.
It writes an answer. From the same field report:

> **Community-measured:** asked about a night hike, the system model invented *"rained heavily / pack
> a waterproof jacket."* The real note said the headlamp died — pack spare batteries.

No exception. No warning. No degraded-quality signal anywhere in the API. A fluent, specific,
plausible, **wrong** paragraph, produced by a pipeline in which every call succeeded. This is the
single most important thing to know about grounding a model on Spotlight, and it is invisible in
every code path you can inspect.

**Detection**, since nothing detects it for you: log the tool's own result stream (§7.6), pick one
item, and diff the attributes that arrived against the attributes you donated. If the body is not in
the arriving set, your model is not reading bodies, and every answer it has ever given you about
content was reconstruction. [Part 2 guide 04 §6.3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md)
has a test that catches it.

**Mitigation** is §9 (Apple's intended fix, with a conflict) or the retrieve-then-hydrate companion
tool ([Part 2 guide 04 §8](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md)),
which is what actually works today.

### 7.4 The instructions are part of the index

Apple's sample devotes forty lines to a system prompt that is, in effect, a **schema description of
the index**. This is the most transferable idea in the sample and it costs nothing.

> ✅ **VERIFIED** — session-246 sample, `Session.swift:40-82`. It enumerates every indexed attribute
> with its semantics and units — *"rating (difficulty 1 to 5, where 1 is Easy…)"*, *"duration
> (estimated time in seconds)"*, *"distance (trail distance in miles, stored as a custom
> attribute)"* — and then adds negative constraints, verbatim:
>
> - *"All trails are indexed with contentType `public.text`. Do not filter by contentType. Use
>   keyword and text predicates instead."*
> - *"Search for the meaningful topic in the request, not generic words like 'trail', 'trails',
>   'hike'…"*
> - *"When searching for a topic, also search for related words. For example, 'water' could also
>   mean lakes, rivers, creeks, waterfalls, ocean, tidepools, or swimming."*
> - *"If the user asks about an attribute that isn't indexed (for example: elevation gain, calories,
>   pace), say plainly that this data is not available rather than inventing values."*

Four moves, and each maps to something in this guide:

1. **Describe your schema with units.** This is §3.5 step 3, and without it your custom attributes
   are numbers without meaning.
2. **Forbid filters that will not work on your data.** The sample's `contentType` instruction exists
   because *all* its items are `public.text`, so a `contentType` filter can only ever narrow to
   everything or nothing.
3. **Seed synonyms.** This is §2.5's safe default, in the prompt rather than in the item — do both.
4. **Forbid inference over unindexed attributes.** This is the only in-band mitigation for §7.3 that
   works without any API at all, and it is the reason it is worth writing down what you did *not*
   index.

**Retrieval quality lives in the instructions, not in the API.** Nothing in `SpotlightSearchTool`'s
configuration surface will teach a model that "water" means "tidepools" in your app.

### 7.5 `GuidanceProfile` — scoping the tool to what your index actually contains

Guidance is what the tool tells the *model* about its own search capabilities. `.complete` describes
everything the tool can do. Your index probably supports a fraction of that.

> ✅ **VERIFIED** — WWDC26 session 246, lines 74–79, verbatim: *"`SpotlightSearchTool` provides its
> **entire set of search capabilities** to a model for guided generation. But **guidance profiles
> can help scope that guidance to only what an app needs.** The hiking trails app doesn't donate
> person relationships, so **guiding the model on how to search for authors and recipients, could be
> skipped for limited-context models.** To selectively enable guidance on search capabilities like
> **people and dates**, use a **`GuidanceProfile`**. **You can even specify the exact list of
> metadata attributes, that the model should consider during a search.** Then set a **dynamic guide
> level** using the profile, when creating `SpotlightSearchTool`."*

Note what that paragraph is really saying: **guidance should be a projection of your donation
decisions.** You did not donate person relationships, so do not spend context teaching the model to
search for them. The profile is where the index side and the prompt side meet.

> ✅ **SDK-verified** — the construction below, formerly a 🟡 reconstruction from a community
> reading. The overlay interface declares `SpotlightSearchTool.GuidanceProfile` with exactly those
> labels, and the value types the reconstruction had to assume are now known: **all six capability
> parameters are `Bool?` defaulting to `nil`**, and `attributes:` is
> **`[SearchableItemAttribute]?`**
> (`_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface:199-213`). The community reading was
> exactly right. Only the *values* below remain illustrative.

```swift prelude:guide-context
let profile = GuidanceProfile(
    textMatch: true,
    similarityMatch: true,
    numericMatch: true,       // we donated rating, duration, distance
    dates: true,              // we donated contentCreationDate, completionDate
    people: false,            // we donate no person relationships — do not spend context on it
    contentType: false,       // everything is public.text; a contentType filter is useless here
    attributes: [.title, .contentDescription, .keywords, .rating, .duration]
)

let tool = SpotlightSearchTool(
    configuration: .init(
        sources: [.coreSpotlight(.init(
            searchableIndexDelegate: SpotlightIndexer.shared,
            fetchAttributes: Self.fetchAttributes
        ))],
        guide: SpotlightSearchTool.Guide(level: .dynamic(profile), format: .compact)
    )
)
```

> ✅ **RESOLVED (was GAP G6, closed 2026-07-29)** — the SDK interface dump this gap asked for now
> exists, and it answers every part. The six capability parameters are **`Bool?`**; `attributes:`
> is **`[SearchableItemAttribute]?`**; and because `SearchableItemAttribute` has a public
> `init(rawValue:)` (§3.5), **a custom attribute key *is* expressible in `attributes:`** —
> `SearchableItemAttribute(rawValue: key.keyName)`, the same bridge as `fetchAttributes`
> (`_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface:199-213`). The related surface is
> declared alongside it: `Guide(level:format:)` with `GuidanceLevel` cases `.complete` /
> `.focused(ContentDomain = .items)` / `.dynamic(GuidanceProfile)` and `FormatLevel` cases
> `.structured` / `.compact` (`:61-104`) — so §7.2's `guide: isOnDevice ? .focused() : .complete`
> and the `.compact` format are all compiler-attested spellings.
>
> ⚠️ The behavioural caution survives the type-level resolution: `.dynamic(GuidanceProfile)` was
> **community-measured as prompt-sensitive** on the 27.0 beta, with a model skipping the search
> entirely and answering from parametric knowledge — a silent failure of its own. `.focused()`
> remains the safe default Apple's own sample ships.

### 7.6 The two-channel results pattern, and why it is an index story

The model narrates. Your UI renders the actual items the tool touched. Both come out of the same
turn, through different channels.

> ✅ **VERIFIED** — session-246 sample, `Session.swift:160-181`:

```swift prelude:guide-context
    private func listenForSearchResults(from tool: SpotlightSearchTool) -> Task<Void, Never> {
        Task { @MainActor in
            var seen: Set<String> = []
            for await reply in tool.searchResults {
                let items: [CSSearchableItem]
                switch reply.content {
                case .items(let searchItems):
                    items = searchItems.map(\.item)
                case .scoredItems(let scored):
                    items = scored.map(\.item.item)
                case .groupedItems(let groups):
                    items = groups.values.flatMap { $0 }.map(\.item)
                case .count, .table, .statistic, .text:
                    continue
                @unknown default:
                    continue
                }
                let newItems = items.filter { seen.insert($0.uniqueIdentifier).inserted }
                self.results.append(contentsOf: newItems)
            }
        }
    }
```

✅ **SDK-verified** — the stream and its cases are declared exactly as the sample consumes them:
`var searchResults: some AsyncSequence<SearchReply, Never>` (`_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface:381-383`),
and `SearchReply.Content` has precisely the seven cases the `switch` covers — `.items`,
`.groupedItems`, `.scoredItems`, `.count`, `.table`, `.statistic`, `.text` — with `SearchableItem`
wrapping `let item: CSSearchableItem`, which is the `.map(\.item)` hop
(`:341-350`, `CoreSpotlight-27.0-macos.swiftinterface:10-15`). Each reply also carries `label`,
`queryToken`, `stageToken` and a `.partial` / `.complete` `status` (`:351-378`) — Part 2 guide 04's
territory.

The index-side lesson: **your UI is rendering `CSSearchableItem`s, so the attribute set you donated
is also your result-row model.** A title good enough for the model is a title good enough for the
list. And de-duplication is by `uniqueIdentifier` — §3.3's join key again, now load-bearing for a
third reason, because the model may call the tool more than once per response.

Everything else about this stream — `queryToken`, the seven content cases, batching semantics — is
[Part 2 guide 04 §9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md).

---

## 8. Consumer 3 — Spotlight search itself

The third consumer is the oldest and the one nobody writes guides about: the user opens Spotlight,
types, and your content appears.

It is in this guide for two reasons, and neither is that it needs explaining.

### 8.1 It is the free rider, and it is the reason to start

Consumers 1 and 2 are new, gated on 27, gated on Apple Intelligence enablement (§6.3), and — in
consumer 2's case — dependent on a metadata hydration story that has an unresolved conflict in it
(§9.4). Consumer 3 has none of those properties. It works on the OS versions you already support, it
requires no entitlement, no model, no schema and no Apple Intelligence, and it has worked this way
for years.

Which makes it the correct *first* justification for an indexing project. If a team cannot get
funding for indexing on the strength of a language-model feature that may not ship, it can get
funding on the strength of "our content becomes findable from the home screen" — and then consumers
1 and 2 arrive as a consequence rather than as a project.

This is not a rhetorical point. It is the difference between an indexing investment that survives a
roadmap change and one that does not.

### 8.2 It is the debugging surface for the other two

When Siri cannot find your content, or the model hallucinates instead of retrieving, the first
question is *"is the content in the index at all?"* — and Spotlight is how you answer it without any
of the machinery of the other two consumers in the way.

Apple's own testing ladder makes this explicit:

> ✅ **VERIFIED** — WWDC26 session 240, chapter 24:18, four stages: **1. `AppIntentsTesting`** —
> invoke intents with test parameters, assert results, no Siri needed. **2. Shortcuts app** —
> validates intent shape and configuration. **3. Spotlight** — validates **indexing and
> discoverability**. **4. Siri** — end-to-end natural language, entity resolution, cross-app
> workflow.

*"Debug at the lowest stage that reproduces the failure"* is the operative advice, and stage 3 is
this consumer. Most "Siri doesn't work" reports are stage-2 or stage-3 problems misdiagnosed as
stage-4 — and by direct extension, most *"the model hallucinates"* reports are stage-3 problems
misdiagnosed as model problems.

**The concrete loop:** index one item, open Spotlight, type a word from its description. If it does
not appear, stop — nothing downstream can work, and you have saved yourself a day of prompt
engineering. If it does appear, you have separated "not indexed" from "indexed but not readable"
(§7.3), which are two entirely different bugs with two entirely different fixes.

### 8.3 What it demands of the index

Almost nothing that the other two do not already demand — one title, one description, freshness —
with one addition worth naming: **the result row is what a human sees**, so `contentDescription`
being written for a machine is a visible product defect here in a way it is not in consumers 1 and 2.
Write it for a person. The model does better on prose written for people than on keyword salad
anyway.

---

## 9. The hydration hook, and why it exists

§7.3 established the defect: the index stores some metadata — text content, HTML — in a compact
representation that is **searchable but not readable**, so the model receives identity attributes and
invents the rest. This section is Apple's answer to that, its exact signature (which is not the
signature most people write), and the two field reports that complicate it.

### 9.1 Apple's design story

> ✅ **VERIFIED** — WWDC26 session 246, lines 52–57, verbatim:
>
> *"If your app donates searchable content to Core Spotlight, you'll already be familiar with the
> **index delegate protocol**. Your app would set an index delegate on your `CSSearchableIndex` to
> handle reindex requests, such as when Spotlight needs to perform migration or recovery.*
>
> ***For `SpotlightSearchTool`, we've added a method to the delegate to recover the full
> `CSSearchableItem` by its unique identifier.** This allows the model to **efficiently manage
> responses over potentially millions of results**.*
>
> *On your index delegate, simply adopt the new **`searchableItems(forIdentifiers:)`** to return the
> complete `CSSearchableItem`.*
>
> ***If your app has metadata that doesn't make sense to donate for search, but might be useful for
> the model to reason about, this is the right time to set any additional attributes on an item for
> the model to see."***

The architecture in one sentence: **the index is a finding aid; the delegate is the document store.**
The tool searches the index, gets identifiers, hands them back to you, and you return fully-populated
items. The model never has to receive a million rows, and you never have to donate to the index
anything that only exists to be reasoned about.

That last quoted paragraph is the underappreciated half. There is a whole class of metadata that is
useless for *search* and valuable for *reasoning* — a computed score, a normalised unit, an
editorial note, a relationship summary — and this hook is the sanctioned place to attach it. It
never enters the index, never bloats it, never affects matching, and reaches the model anyway.

### 9.2 ⚠️ The exact signature — and it is not what you would write

This is the part that costs people an afternoon.

> ✅ **VERIFIED** — session-246 sample project, `Indexer.swift:123-128`, read from Apple's compiling
> code:

```swift prelude:guide-context
    nonisolated func searchableItems(forIdentifiers identifiers: [String], searchableItemsHandler: @escaping @Sendable ([CSSearchableItem]) -> Void) {
        Task { @MainActor in
            let items = createSearchableItems(identifiers: identifiers)
            searchableItemsHandler(items)
        }
    }
```

Four properties of that declaration, each of which contradicts the obvious guess:

**It is a completion-handler method, not an array-returning one.** The full selector is
`searchableItems(forIdentifiers:searchableItemsHandler:)`. It takes `[String]` **and** an
`@escaping @Sendable ([CSSearchableItem]) -> Void`, and returns `Void`. It does **not** return
`[CSSearchableItem]`.

**It is `nonisolated`.** It is called from outside your actor context. That is why the sample's body
hops to `@MainActor` in a `Task` before touching its store, and why the handler is `@Sendable` — the
closure crosses isolation domains.

**It is not `async`.** You cannot `await` in the method body without a `Task`. The completion handler
*is* the asynchrony mechanism. The sample's `Task { @MainActor in … }` is the idiomatic bridge from
this Objective-C-shaped callback into Swift concurrency.

**It is non-throwing.** There is no error channel. If you cannot produce an item for an identifier,
your only options are to omit it from the array you pass to the handler, or to pass a degraded item.
Nothing upstream will hear about the failure.

⚠️ **Why this matters practically.** Every prose reconstruction of this method in circulation —
including one in this project's own research notes before the sample was obtained — writes it as:

```swift illustrative
// ❌ WRONG — this is the reconstruction, not the API.
func searchableItems(forIdentifiers identifiers: [String]) -> [CSSearchableItem] { … }
```

If you write that, one of two things happens. Best case, the compiler rejects it or a protocol-
conformance diagnostic fires. **Worst case — and this is the real hazard with Objective-C-derived
delegate protocols — your method simply never matches the selector the runtime is looking for, your
type still conforms because the requirement is optional, the project builds clean, and the method is
never called.** No error, no warning, no hydration, and §7.3's hallucination continues exactly as
before while you believe you have fixed it. Copy the signature from §9.2, not from memory.

### 9.3 A complete, working implementation

Extending §3.1's indexer:

> 🟡 **RECONSTRUCTED** — the body. The **signature** is ✅ verified verbatim from Apple's sample, as
> is the `Task { @MainActor in … }` bridge and the `searchableItemsHandler(items)` call. The item
> construction inside is §3.3's 🟡 reconstruction.

```swift prelude:guide-context
import CoreSpotlight

extension SpotlightIndexer {

    /// Called by SpotlightSearchTool with the identifiers of items the model wants
    /// to reason about. Return FULL items — including attributes you deliberately
    /// never donated, because they were useless for search and useful for reasoning.
    nonisolated func searchableItems(
        forIdentifiers identifiers: [String],
        searchableItemsHandler: @escaping @Sendable ([CSSearchableItem]) -> Void
    ) {
        Task { @MainActor in
            let items: [CSSearchableItem] = identifiers.compactMap { id in
                guard let trail = TrailStore.shared.trail(id: id) else { return nil }

                let attributes = CSSearchableItemAttributeSet(contentType: .text)

                // The same fields you donated…
                attributes.title = trail.name
                attributes.keywords = trail.keywords

                // …plus the BODY, which the index could search but could not give back,
                // …plus model-only metadata that was never worth indexing at all.
                attributes.contentDescription = """
                    \(trail.fullNotes)

                    Conditions: \(trail.conditionsSummary)
                    """

                return CSSearchableItem(
                    uniqueIdentifier: id,
                    domainIdentifier: "trails",
                    attributeSet: attributes
                )
            }
            searchableItemsHandler(items)
        }
    }
}
```

And the wiring, which is one parameter (✅ verified, §7.2):

```swift prelude:guide-context
SpotlightSearchTool(
    configuration: .init(
        sources: [.coreSpotlight(.init(
            searchableIndexDelegate: SpotlightIndexer.shared,   // ← this line is the wiring
            fetchAttributes: Self.fetchAttributes
        ))],
        guide: .focused()
    )
)
```

Three implementation rules that fall out of §9.2's four properties:

1. **Be fast and be bounded.** You are on a call path the model is blocked on, with an identifier
   array whose size you do not control. Fetch by identifier in one round trip, not N.
2. **Always call the handler.** Exactly once, on every path, including the empty one. It is
   non-throwing and non-async; if you return without calling it, the caller's continuation is
   whatever the framework decided to do about a delegate that went silent — which is unspecified,
   and in the best case is a timeout you will experience as inexplicable latency.
3. **Do not put anything enormous in the item.** These attribute sets go into a language model's
   context window. Ten items × a 5,000-token body is a `contextSizeExceeded` you will diagnose as a
   guidance problem. Summarise at hydration time if your bodies are long.

### 9.4 ⚠️ The conflict — and it is a real one

Everything above is Apple's intended design. Two independent field reports say it did not behave that
way on 27.0 betas, and this guide is not going to present the design story as if they did not exist.

**Field report 1 — the method is older than the session says, and did not hydrate.**

> **Community-measured** (`spotlight-rag-third-party.md`, one developer, macOS 27 beta, M4 Max,
> 2026-06-13): *"`CSSearchableIndexDelegate` conforms and wires via
> `CoreSpotlightSource(searchableIndexDelegate:)`; `searchableItems(forIdentifiers:)`
> (**macOS 15.4+**, with a **new `protectionClass` overload in 27.0**) is the **index-recovery
> hydration API — not the search-time body path.**"*

Two claims there. First, the method **predates this year** — macOS 15.4, with the 27.0 addition
being a `protectionClass` overload rather than the method itself. That directly contradicts session
246's *"we've added a method to the delegate"* and *"the new `searchableItems(forIdentifiers:)`"*.
Both can be reconciled if what is new in 27.0 is the *tool's use of* an existing method, which is
the most economical reading — but the session's phrasing is what it is. The 2026-07-29 SDK pass
cannot arbitrate: `CSSearchableIndexDelegate` is an Objective-C protocol, so neither the method
nor the reported `protectionClass` overload appears in the captured Swift interfaces. Second, and more
consequentially, in that author's testing the method **did not put bodies into the tool output**.

**Field report 2 — the delegate was never invoked at all.**

> **Community-measured** — Developer Forums thread **833651** (whose primary subject, a
> tool-definition schema mismatch, was confirmed by an Apple DTS engineer as a **known issue**
> tracked at thread 832534). A secondary observation in the same post: *"`CoreSpotlightSource
> .fetchAttributes` has no effect on returned attributes on the agentic-search path"*, and
> **`searchableIndexDelegate` was never invoked in any configuration tried, including `.dynamic`.**

⚠️ **SILENT FAILURE, second instance.** Implement the delegate correctly, wire it correctly, ship
it — and on the betas these developers tested, nothing called it. The method does not throw (§9.2).
Nothing logs. Your hydration simply does not happen, and §7.3's hallucination continues.

**How to hold all of this at once:**

- The design is Apple's and is coherent. Implement the method. It costs an hour.
- **Do not assume it fired.** Put a signpost in it — an `os_log`, a counter, a breakpoint — and
  confirm on your actual OS build that it is called before you rely on it for grounding.
- **Have the fallback ready.** The retrieve-then-hydrate companion-tool pattern
  ([Part 2 guide 04 §8](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md))
  was verified working across three models by the same author who found the delegate inert: the
  model chains `spotlight_search` → identifiers → your own `fetch_note(id)` tool → body → grounded
  answer. It is more code and it is under your control end to end.
- These are **beta-era community measurements from mid-2026**, one developer each. They may well be
  fixed in the build you are running. That is precisely why the signpost matters more than the
  conclusion.

### 9.5 What the hook is *not*

**It is not a reindex mechanism.** `CSSearchableIndexDelegate`'s reindex methods are a different
concern — Spotlight asking you to re-donate after a migration. This method asks you to *materialise*
items that are already indexed. Implementing one does not implement the other.

**It is not a search-time filter.** You are not being asked which items match. The matching already
happened. You are being asked to describe items the index already selected.

**It is not a place to do work proportional to your whole store.** See §9.3 rule 1.

---

## 10. 🔴 The gap that stays open

Everything in §9 is on-ramp A's story. The question this guide cannot answer is what happens on
on-ramp B.

### 10.1 The gap, stated precisely

> 🔴 **GAP (G5) — does `CSSearchableIndexDelegate.searchableItems(forIdentifiers:searchableItemsHandler:)`
> fire for content indexed via `indexAppEntities(_:)`?**
>
> **What is known:** ✅ `IndexedEntity` is *"backed by a `CSSearchableItem`"* (Apple engineer, thread
> 833658). ✅ Entity-indexed content is reachable by `SpotlightSearchTool` (same answer, same
> sentence). ✅ The hydration method exists on `CSSearchableIndexDelegate` and is wired through
> `CoreSpotlightSource(searchableIndexDelegate:)`. ✅ **(added 2026-07-29)** The entity→item bridge
> is explicit API in the 27.0 interface: `CSSearchableItem.init(appEntity:)` /
> `init(appEntity:priority:)` (macOS 15 / iOS 18, plus 27.0 `async` variants),
> `associateAppEntity(_:priority:)` on both `CSSearchableItem` and
> `CSSearchableItemAttributeSet`, and a 27.0 `relatedAppEntityIdentifier: EntityIdentifier?`
> property (`AppIntents-27.0-macos.swiftinterface:369-406`) — adjacent evidence that entities and
> items are one currency, but silent on the delegate's behaviour.
>
> **What is unknown:** whether the tool consults that delegate for items that arrived through
> `indexAppEntities(_:)` rather than `indexSearchableItems(_:)`; if it does, **what identifiers
> arrive** — the entity's `id` stringified, a namespaced composition, something else; and whether an
> app whose only Core Spotlight surface is entity indexing is even expected to have a
> `CSSearchableIndexDelegate` at all, given that §4.5's reindex duty is served by
> `IndexedEntityQuery` instead.
>
> **Nothing in Apple's documentation, in the sessions, in the sample projects, or in any forum
> answer in this corpus addresses it.** Session 246 wired the delegate for a `CSSearchableItem`
> app. Session 343 discussed entity indexing without mentioning Foundation Models at all. The two
> halves of the architecture were presented by two teams and the seam between them was never
> described. The 26.5 and 27.0 SDK interfaces were checked on 2026-07-29 and do not settle it
> either — the delegate protocol is Objective-C and sits outside the Swift interface surface.

### 10.2 Why this matters more than a normal gap

Because of §7.3. The hydration hook is not a nicety — it is **the** documented answer to the one
defect that makes this whole consumer produce confident wrong output.

Trace the consequence:

1. You model your content as `AppEntity`s, because you want Siri (§6).
2. You adopt `IndexedEntity` and `indexAppEntities(_:)`, because it is one conformance and Apple
   says it is *"the only requirement."*
3. You add `SpotlightSearchTool`, because your content is now in the index and the tool reads the
   index.
4. The model sees identity attributes and hallucinates bodies (§7.3).
5. You implement §9's hook — the documented fix.
6. **If the delegate does not fire on the entity path, step 5 changes nothing**, and you have no
   signal distinguishing "my delegate is wrong" from "my delegate is not consulted."

That is a plausible sequence, it is the *natural* sequence for an App Intents-first team, and its
failure mode is silent at every step. Meanwhile the developer who took on-ramp A — Apple's own
sample — has a verified path to the same outcome.

There is also a second-order version of the same uncertainty: `@Property(indexingKey:)` maps your
property into the index (§4.3). If the *index* stores it in the compact searchable-but-not-readable
form, then binding your body text to `\.textContent` puts it in exactly the representation §7.3 says
the model cannot read — and the entity path's whole answer to that would be the hook whose behaviour
is unknown.

### 10.3 The safe default

**If you need the language model to read item bodies, donate `CSSearchableItem`s too.**

Take on-ramp B for the entity consumers — Siri, annotation, `RelevantEntities` — and additionally
donate `CSSearchableItem`s through on-ramp A for the content you want the model to reason over, with
`searchableIndexDelegate:` wired and §9's hook implemented. Yes, that is two indexing paths, and yes,
§1.3 said the point of this architecture is that you do not need two. The honest position is that you
do not need two **for discovery**, and you may need two **for model-readable hydration** until this
gap closes.

Costs, stated plainly so you can price it:

- The item-construction code is written once and shared: §9.3's hydration body and §3.3's donation
  body are the same function with different inputs.
- ⚠️ Identifier discipline is now mandatory (§5.5). Same object, same `uniqueIdentifier`, both
  paths — otherwise duplicates in every consumer.
- You owe one reindex implementation, not two (§4.5, verified either/or).
- Realistic cost for an app that already has both an `AppEntity` model and a persistent store:
  a day, most of it deciding what belongs in the hydrated attribute set.

**If you do not need bodies — if your content is genuinely name-shaped, like playlists or albums —
this gap does not affect you.** Index entities, stop, and skip §9 entirely.

### 10.4 What would resolve it, concretely

A test app, and it is small enough to be worth someone's afternoon:

1. Index **only** via `indexAppEntities(_:)` into a named index. Donate zero `CSSearchableItem`s.
2. Give the entity a body property bound with `@Property(indexingKey: \.textContent)`, and make the
   body contain a distinctive token that appears nowhere else.
3. Implement `CSSearchableIndexDelegate` on an object, set it as `index.indexDelegate`, and pass it
   as `searchableIndexDelegate:` in the tool configuration. Put an `os_log` — and a breakpoint — in
   `searchableItems(forIdentifiers:searchableItemsHandler:)` that prints the identifiers verbatim.
4. Ask the model a question that can only be answered from the body.

Three distinguishable outcomes: the delegate fires and the identifiers tell you the entity-to-item
identifier mapping (gap closed, and G5's second half closed with it); the delegate does not fire
(gap closed in the negative, §10.3 becomes mandatory rather than defensive); or the delegate fires
and the model still cannot see the body, which would make this a variant of §9.4's field report 1
rather than an entity-path issue at all.

If you run it, the identifiers you log are the most valuable single line of output in this entire
guide.

---

## 11. Session 343's three retrieval paths

Indexing is not always right. Session 343 frames content discovery as exactly three paths and gives
a decision rule that is a **data-shape** question rather than a feature question, which is the useful
kind.

### 11.1 The rule

> ✅ **VERIFIED** — WWDC26 session 343, verbatim: *"you might **not** index your entities if your
> content dataset is **large, lives on a server, or changes too frequently** to index ahead of time.
> For example, I decided to index all the app's **playlists, but not songs**."*

Three disqualifiers, and the worked example is the clearest part. A music app has thousands of
playlists and millions of songs. Playlists are user-created, personal, comparatively stable, and
few. Songs are none of those. So: index the playlists, serve the songs through a query.

Generalised: **index what is yours, personal, bounded and stable. Query what is vast, remote or
volatile.**

### 11.2 Path 1 — `IndexedEntity` + Spotlight

Covered in full in §4. Its properties as a retrieval path:

- **Ahead-of-time.** The work happens at write time, so read time is fast and works offline.
- **The only path the language model can reach.** `SpotlightSearchTool` searches the index. It does
  not call your `EntityQuery`, your `IntentValueQuery`, or your search UI. **If it is not indexed,
  your model cannot retrieve it.** This is the fact that makes this section belong in this guide: for
  consumer 2, path 1 is not one of three options — it is the only one.
- **You owe maintenance.** Create, update, delete (§3.6).
- **Semantic matching is conditional** on the App Intents domain (§2.5, gap G2).

### 11.3 Path 2 — `IntentValueQuery` (structured search)

> ✅ **VERIFIED** — WWDC26 session 343, verbatim: *"`IntentValueQuery` is suitable **if you don't
> index all your entities ahead of time**. This is very similar to `EntityQuery`. **The key
> differences are that your app receives a structured search input from the system, and you can
> return more than one entity type.**"*

> ✅ **VERIFIED** — Apple code sample, session 343 @ 13:38:

```swift prelude:guide-context
// Structured search of songs and playlists
struct AudioIntentValueQuery: IntentValueQuery {

    // AudioSearch, IntentPerson, and other system types may be supported as input
    func values(for input: AudioSearch) async throws -> [AudioEntity] {
        switch input.criteria {
        case .searchQuery(let query):
            return try await searchResults(for: query)
        case .unspecified:
            return try await likedSongResults()
        // ... also a .url case
        }
    }
}
```

Confirmed shape: `protocol IntentValueQuery` with `func values(for input:) async throws -> [Entity]`
— ✅ **SDK-verified**: the requirement is `func values(for input: Self.Input) async throws ->
Self.Result` over an `Input : _IntentValue` associated type, and the protocol is
`@available(anyAppleOS 26.0, *)`, not new this year
(`AppIntents-27.0-macos.swiftinterface:4401-4412`). The input is a **system-provided structured
search type** (`AudioSearch` and `IntentPerson` are the
named examples, and Apple's own comment says *"other system types may be supported as input"*);
`AudioSearch` has a `.criteria` property with at least `.searchQuery(String)`, `.unspecified`, and
`.url`. The return element type here is `AudioEntity`, described in the session as *"a `UnionValue`
type that includes both songs and playlists"* — that is the "more than one entity type" mechanism.

The case semantics, from the narration, are worth having because they are not guessable:

- `.searchQuery` — *"contains the **relevant part of what the person said**"*. Siri has already
  stripped the carrier phrase; you receive the payload, not the sentence.
- `.unspecified` — *"'Play CosmoTunes' which isn't specific about what I want to play. In that case,
  the app jumps straight into playing songs I've previously liked."* An empty query is a **request
  for your defaults**, not an error.
- `.url` — *"for when someone references a **link** from your app. Like: 'Play that playlist Glow
  sent me.'"*

> 🔴 **GAP (G7)** — **the complete `AudioSearch.criteria` case list, and the full set of system
> input types `IntentValueQuery` accepts.** Apple's narration says *"Check out the documentation for
> the full set of `AudioSearch` criteria"* and *"other system types may be supported"*, and neither
> enumeration is in this corpus. The 2026-07-29 SDK pass narrows without settling: **`AudioSearch`
> is absent from the macOS 27.0 AppIntents interface entirely** — presumably an iOS-surface type —
> so no case list can be read from the captures.
>
> **What would resolve it:** the documentation pages for `AudioSearch` and `IntentValueQuery`, or
> the iOS interface.
>
> **Safe default:** handle the three named cases explicitly and put a `default:` on the switch that
> falls back to your generic search. Do not exhaustively switch on a type whose case list you have
> not seen.

⚠️ **And the constraint that puts this section in this guide:** `IntentValueQuery` serves Siri. It
does **not** serve `SpotlightSearchTool`. If you take path 2 for a body of content, that content is
invisible to your own language model, and no configuration of the tool will reach it. If you need
both, you need path 1 for the model and may add path 2 for Siri's benefit on top.

### 11.4 Path 3 — in-app search via `.system.searchInApp`

> ✅ **VERIFIED** — WWDC26 session 343 plus Apple's published code sample at timestamp 14:49. It
> works *"no matter which other domains you adopt, and **even if you don't index your entities**."*

```swift prelude:guide-context
// Intent that re-runs the Siri search in app
@AppIntent(schema: .system.searchInApp)
struct SearchAudioLibraryIntent {

    var criteria: StringSearchCriteria

    func perform() async throws -> some IntentResult {
        // Perform in-app search with Siri search string
        navigation.searchText = criteria.term
        navigation.selectedTab = .library
        return .result()
    }
}
```

Apple's own header comment — *"Intent that re-runs the Siri search in app"* — is the mental model.
Siri hands you its query string and gets out of the way. It navigates rather than answers.

Note the version story, because it is a good example of why this series marks earliest-OS on
everything: **`StringSearchCriteria` is an iOS 17.2 / macOS 14.2 type** (✅ verified from its
documentation page), and the `.system` search schema *"introduced in iOS 17 is now named
`.system.searchInApp`"* (✅ verbatim). The *type* is old and the *name* is new. This is a rename, not
a new capability. Full treatment in [Part 16 guide 02 §8](02-app-schema-domains.md).

Path 3 is the escape hatch for apps in categories Apple never modelled, and it is **completely
independent of everything else in this guide** — no index, no entities, no schema domain adoption.
Which is exactly why it belongs in the decision table: for some apps it is the only reachable Siri
surface, and it costs twenty lines.

### 11.5 The three paths, side by side

| | **Path 1 — index** | **Path 2 — `IntentValueQuery`** | **Path 3 — `.system.searchInApp`** |
|---|---|---|---|
| When | bounded, personal, local, stable | large / server-side / volatile | no domain fits, or nothing indexed |
| Work happens at | write time | query time | query time, in your app |
| Serves Siri | ✅ | ✅ | ✅ (navigates, does not answer) |
| Serves `SpotlightSearchTool` | ✅ **only this one** | ❌ | ❌ |
| Serves Spotlight UI | ✅ | ❌ | ❌ |
| Offline | ✅ | depends on your backend | ✅ |
| Maintenance burden | create / update / delete | none | none |
| Returns multiple entity types | ❌ | ✅ via `UnionValue` | n/a |

**The row that decides architecture is the `SpotlightSearchTool` row.** Two of the three paths are
invisible to your own model. If a language-model feature over your content is on the roadmap at all,
the "large, server-side or volatile" content you were planning to serve through path 2 needs a
deliberate decision: either index a *projection* of it (titles, summaries, identifiers — enough for
the model to retrieve and then hydrate through your own tool), or accept that the model cannot see
it and say so in your instructions, the way Apple's sample does (§7.4, fourth constraint).

Indexing a projection is usually the right answer and it is under-discussed. You do not have to index
a million songs to let a model find one. You have to index enough of each song for a match to be
possible, and let §9's hook or a companion tool fetch the rest.

---

## 12. `RelevantEntities` — the third discovery mechanism

Session 345 adds a mechanism that is neither indexing nor donation, and argues for it by describing a
hole the other two cannot cover.

### 12.1 The cold-start argument

> ✅ **VERIFIED** — WWDC26 session 345, verbatim: *"But what about that new playlist? **Nobody's
> searched for it in Spotlight since they don't know it exists.** And since **nobody's played it,
> there's no interaction to donate** either. You need a way to tell the system this playlist is
> relevant so it can surface it at the right moment."*

That is the cold-start problem for content discovery, stated exactly. **Spotlight indexing requires
user search intent** — the content is findable, but somebody has to go looking. **Interaction
donation requires prior user behaviour** — the system learns from what has already happened. Neither
mechanism can surface something new that nobody knows about.

### 12.2 The API

> ✅ **VERIFIED** — Apple code sample, WWDC26 session 345 @ 5:18:

```swift prelude:guide-context
// Suggest playlists for the workout session
let playlistEntities = [dailyRun, runningMix]
let workoutContext = AppEntityContext.audio(.workout(activityType: .running))

try await RelevantEntities.shared.updateEntities(
    playlistEntities, for: workoutContext
)

// Clear all entities for a context
try await RelevantEntities.shared.removeAllEntities(for: workoutContext)

// Remove specific entities from a context
try await RelevantEntities.shared.removeEntities(playlistEntities, from: workoutContext)

// Or remove all entities across all contexts
try await RelevantEntities.shared.removeAllEntities()
```

Confirmed surface:

- `RelevantEntities.shared` — a singleton.
- `updateEntities(_:for:) async throws`
- `removeEntities(_:from:) async throws`
- `removeAllEntities(for:) async throws`
- `removeAllEntities() async throws`
- **`AppEntityContext`** — an opaque `Hashable` struct with domain-scoped factories. One concrete
  path is verified from the session: `AppEntityContext.audio(.workout(activityType: .running))` —
  contexts are **domain-scoped** (`.audio`) with a **situation** (`.workout`) carrying
  **parameters** (`activityType:`). ⚠️ But see G8 below: the `.workout` situation is absent from
  the macOS 27.0 interface, so on the Mac the only spellable context is `.audio(.nowPlaying)`.

✅ **SDK-verified** (`AppIntents-27.0-macos.swiftinterface:4837-4846`, `anyAppleOS 27.0`) — all
four methods above, plus one the session did not show: `removeEntities(_:) async throws`, which
removes the given entities with no context parameter.

> 🔴 **GAP (G8) — narrowed 2026-07-29, not closed.** **The full set of `AppEntityContext` domains
> and situations.** The macOS 27.0 interface was checked: `AppEntityContext`'s only factory on
> that surface is `static func audio(_: AudioContext)`, and `AudioContext`'s only member is
> `.nowPlaying` (`AppIntents-27.0-macos.swiftinterface:4814-4837`). The session's
> `.workout(activityType:)` situation is **not present in the macOS 27.0 beta interface** —
> presumably iOS-surface, which this repo has not captured. Whether there is a context for every
> schema domain, or only for a few, remains unknown; arbitrary contexts cannot be constructed —
> the struct is opaque with factory methods only.
>
> **What would resolve it:** the iOS module interface, or the `AppEntityContext` documentation
> page.
>
> **Safe default:** treat `RelevantEntities` as adoptable only if the context you need is one you
> have seen spelled out — on macOS today that means `.audio(.nowPlaying)` and nothing else. There
> is no useful fallback — a wrong context is not a compile error you can guess your way past — so
> if the `.audio` example is not close to your domain, defer this until you can read the factory
> list on your target platform.

⚠️ **Consumer surface worth noting:** the demo showed the **Fitness app's suggested-playlists list**
when setting up a running workout. So `RelevantEntities` feeds *other apps'* suggestion UI, not just
Siri. That makes it a genuinely different distribution channel from anything else in this guide — and
it is the one mechanism here that requires no index at all.

### 12.3 ⚠️ SILENT FAILURE — there is no TTL

> ✅ **VERIFIED** — WWDC26 session 345, verbatim: *"**Entities stay registered until you remove
> them.**"*

No expiry. No automatic invalidation. If you register a playlist as relevant to running workouts and
the user deletes it, it stays registered — pointing at an entity that no longer resolves — until you
call `removeEntities(_:from:)`.

This is §3.6's deletion problem again, in a second system, with the same shape: **the removal call
has no natural trigger in most apps' code**, nothing errors, and the symptom appears in *another
app's UI*, which is the hardest possible place to notice it. Every registration site needs a matching
deregistration site, written at the same time.

The clean pattern is to make the context the unit of ownership: on any change to the set of things
relevant to a context, call `removeAllEntities(for: context)` and then `updateEntities(_:for:)` with
the current set. Idempotent, one code path, no leak-by-omission.

### 12.4 Apple's three-way decision rule

This is the cleanest taxonomy in the whole area and it should be quoted rather than paraphrased.

> ✅ **VERIFIED** — WWDC26 session 345, verbatim: *"Use **Spotlight** when you want your content to
> be **searchable and retrievable by Siri**. Use **interaction donation** to teach Siri and the
> system **how people use your app** — so it can identify patterns and suggest actions people may
> want to repeat. And use **`RelevantEntities`** to hint to the system **which content is relevant in
> specific situations** — so the system can suggest it at the right moment."*

Three mechanisms, three distinct jobs:

| Mechanism | Job | Trigger | Consumed by |
|---|---|---|---|
| Spotlight indexing | **findability** | the user goes looking | Siri, `SpotlightSearchTool`, Spotlight |
| Interaction donation | **behavioural learning** | the user did something in your UI | Siri suggestions, system patterns |
| `RelevantEntities` | **situational suggestion** | a situation arises | other apps' suggestion UI, Siri |

Interaction donation, for completeness, since it is the one mechanism in the table that this guide
does not otherwise cover:

> ✅ **VERIFIED** — WWDC26 session 343, verbatim: *"When people interact with your app **through Siri
> or Shortcuts, the system already knows about it**. But, Apple Intelligence **can't learn from
> actions people take through your app's UI** without your help. That's where donations come in."*

```swift prelude:guide-context
let intent = SendMessageIntent()
intent.destination = .recipients(conversation.recipients.map(\.entity))
try await IntentDonationManager.shared.donate(intent: intent, result: .result(value: result))
```

⚠️ Two rules stated in the session: **donate only UI interactions** — never Siri-originated ones, or
you double-count — and **excessive donations are ignored.** Donation is not free telemetry; it is a
hint channel with a budget.

**Only the first row of that table feeds your language model.** Donations and relevance hints are
Siri-and-system mechanisms. If the question is "how do I get my content in front of my own
`LanguageModelSession`", the answer is always and only the index.

---

## 13. Failure modes, four of them silent

The defining property of this stack is that most defects do not throw. Indexing is a particularly bad
offender because it is a *write* path whose only observable consequence is the *quality* of three
*read* paths, none of which reports quality.

Here is the catalogue, silent ones first.

### 13.1 ⚠️ SILENT — the model reads titles and invents bodies

Covered in full in §7.3. Restated here as an entry in the catalogue because it is the one that costs
the most.

**Symptom.** Fluent, specific, confident answers about your content that are wrong in detail.
**Mechanism.** Some index metadata is stored searchable-but-not-readable (✅ session 246); the tool
output carries identity attributes only (community-measured); a language model handed titles writes
prose anyway.
**What throws.** Nothing. Every call succeeds.
**Detection.** Log the tool's result stream and diff arriving attributes against donated ones.
**Fix.** §9's hydration hook, or a companion hydration tool
([Part 2 guide 04 §8](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md)).
**Why it is misdiagnosed.** The symptom is in the model, the cause is in the index. Teams reach for
prompts, then models, then guidance — three layers away from the problem.

### 13.2 ⚠️ SILENT — stale index entries survive deleted content

**Symptom.** Siri offers something the user deleted. Spotlight shows a row that opens to nothing. The
model cites content that is gone.
**Mechanism.** §3.6 — deletion of index entries has no natural trigger in most codebases. The object
is destroyed; the index entry is not.
**What throws.** Nothing at write time. At read time your app is asked to open an identifier that no
longer resolves, which is *your* error path, three layers away from the omission that caused it.
**Detection.** Delete a thing, then search for it in Spotlight. Ten seconds of work; almost nobody
does it.
**Fix.** Put index deletion in the same function as store deletion, not in a cleanup pass.
**Amplification.** This one hits **all three consumers at once**, which is §2.4's warning made
concrete.

### 13.3 ⚠️ SILENT — an unmapped entity property is simply absent

**Symptom.** A field your users search by never matches. Everything else works.
**Mechanism.** §4.3 — a `@Property` with no `indexingKey:` or `customIndexingKey:` is not indexed. It
resolves, it displays, an intent can read it. It is not in the index.
**What throws.** Nothing, and there cannot be a warning, because most properties legitimately should
not be indexed.
**Detection.** For each property you expect users to search by, run the Spotlight loop in §8.2. This
is a checklist, not a test suite, and it is the only thing that catches it.
**Fix.** Add the mapping.
**Cousin on the other on-ramp:** an attribute you never assigned in §3.3. Same absence, same silence.

### 13.4 ⚠️ SILENT — the hydration delegate is never called

Covered in §9.4. **Symptom:** you implement §9's hook and nothing changes. **Mechanism:** either the
signature does not match the selector (§9.2 — the array-returning reconstruction), or the framework
did not consult the delegate at all (community-measured on 27.0 betas, threads 833651 and the
`spotlight-rag-third-party` field notes), or you are on the entity on-ramp and §10's gap applies.
**What throws:** nothing; the method is non-throwing by design. **Detection:** a signpost inside the
method — an `os_log` and a breakpoint — and confirm on your build before relying on it. **Fix:**
copy the signature from §9.2 verbatim; keep the companion-tool fallback ready.

### 13.5 Two indexes, because two call sites

**Symptom.** Half your content is findable. The half indexed by the other subsystem is not.
**Mechanism.** §3.2 — `CSSearchableIndex(name: "X")` in one file, the default index in another.
**What throws.** Nothing. Both writes succeed.
**Fix.** One constant, one accessor, never call the initialiser twice.
**Prevention that actually works:** make the index a `private let` on one object and expose methods,
so there is no way to name it wrong from outside.

### 13.6 `.complete` guidance blows the context window

**Symptom.** `contextSizeExceeded` on the first turn, before your content is involved at all.
**Mechanism.** Community-measured ~13k tokens of tool instructions under `.complete` guidance against
a 4k on-device context.
**What throws.** ✅ This one *does* throw, cleanly, and is therefore the least dangerous item in this
list.
**Fix.** `.focused()` + `format: .compact` for on-device models. Apple's sample gates on exactly this
(`guide: isOnDevice ? .focused() : .complete`).
**See:** [Part 2 guide 04 §10](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md).

### 13.7 The tool is never invoked

**Symptom.** Ungrounded answers with no tool call in the transcript at all.
**Mechanism.** The model decided it did not need to search. Community-measured as more likely under
`.dynamic(GuidanceProfile)`.
**Detection.** Inspect the transcript for a `spotlight_search` call. If it is absent, this is your
bug, not §13.1's.
**Fixes.** Instructions that mandate the tool — Apple's own sample says *"Always use the
spotlight_search tool to search trails before answering. Never answer from memory."* — and, as an
escape hatch, `GenerationOptions(toolCallingMode: .required)`.
**Note the diagnostic pairing:** §13.1 and §13.7 produce *identical user-visible symptoms* —
confident, wrong, ungrounded prose — and have opposite causes. The transcript is what separates them,
which is why "log the trajectory" is the first debugging step for anything in this consumer.

### 13.8 Model-catalog failure before anything you wrote runs

**Symptom.** `Error Domain=com.apple.UnifiedAssetFramework Code=5000` referencing
`com.apple.modelcatalog` when constructing the tool, on a system where the language model reports
`.available`.
**Mechanism.** Reported on Developer Forums thread **838904** on macOS Golden Gate Developer Beta 4,
from the exact five-line snippet in session 246. The tool appears to pull its own asset from the
model catalog, separately from the LLM's availability check.
**Consequence.** ⚠️ **`SystemLanguageModel` reporting `.available` is not sufficient to conclude that
`SpotlightSearchTool` will work.** Handle construction failure as a first-class path, not an
assertion.

### 13.9 The tool definition itself had a schema bug

Not your fault and worth knowing so you do not debug it: Developer Forums threads **832534** and
**833651** document a mismatch between the tool's human-readable `description` and its `parameters`
JSON Schema, such that a model following the description fails the schema. ✅ An **Apple DTS
engineer** confirmed on 833651: *"This is a known issue discussed here"* (→ 832534). Surface:
`LanguageModelSession.ToolCallError` with underlying *"Failed to parse generated content."*

Beta-era, acknowledged, and a reminder that not every failure in this pipeline is in your index.
[Part 2 guide 04 §14.3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md)
has the detail.

### 13.10 The diagnostic ladder

Given the overlap in symptoms above, work bottom-up. Each rung is cheap and eliminates a stratum.

| Rung | Question | How | If it fails |
|---|---|---|---|
| 0 | Is the content in the store? | your own logging | not an indexing problem |
| 1 | Is it in the index? | type a distinctive word into Spotlight (§8.2) | §13.2, §13.3, §13.5 |
| 2 | Does Siri find it by name? | ask Siri for it by title | entity/display-representation problem, guide 02 |
| 3 | Does the tool get called? | inspect the transcript for `spotlight_search` | §13.7, §13.8, §13.9 |
| 4 | Do bodies arrive? | log `tool.searchResults`, diff attributes | §13.1, §13.4, §10 |
| 5 | Is the answer good? | read it | prompt work — and only now |

**Nobody starts at rung 1.** Everybody starts at rung 5, because that is where the symptom is. The
entire value of this table is the instruction to go down instead of sideways.

---

## 14. The adoption sequence

What to index first, for the best return across all three consumers. This is the closing argument of
the guide, and it deliberately disagrees with the order most teams pick.

### 14.1 Apple's own ladder, and where indexing sits in it

Session 343 ends with a prioritised list, and it is worth starting from Apple's order before
adjusting it.

> ✅ **VERIFIED** — WWDC26 session 343, wrap-up, verbatim and in order:
>
> 1. *"a great place to start is by **customizing your entity display representations**. They are
>    used to display your entities across the system."*
> 2. *"From there, **add your entities to the semantic index, and keep the index up to date**, so
>    Siri can always find your freshest content."*
> 3. *"You might also consider making your entities accessible through Siri with an
>    **`IntentValueQuery` and in-app search**."*
> 4. *"**annotating your views, activities, and your existing system integrations** with entities."*
> 5. *"When you're ready, look into **donating UI interactions**."*

Two things to take from that ordering. **Display representations come before indexing** — because
`IndexedEntity`'s defaults derive from them (§4.4) and because they are consumed by five separate
subsystems, so improving one string improves the index, the disambiguation prompt, the Shortcuts row
and the Spotlight result simultaneously. And **donations come last**, which is a useful corrective to
the instinct that telemetry-shaped work should come first.

Apple's ladder is written for a Siri-first reader. The sequence below is the same work, reordered for
a reader who also wants consumer 2, and with the triage step Apple omits.

### 14.2 The sequence

**Step 0 — Triage: pick the indexable unit, and pick fewer of them.**

Before any API. Two questions:

*What is the unit a user would want to find?* Not your database tables — the thing a person would
name. A trail, not a trail-segment. A note, not a paragraph. Getting this wrong is expensive because
`uniqueIdentifier` (§3.3) is a contract with three consumers and changing it means reindexing
everything.

*Which of your content is bounded, personal and stable?* §11.1's rule. Index that. For everything
large, remote or volatile, decide now whether to index a **projection** (§11.5) or to accept that
your model cannot see it.

Deliverable: a list of one or two types, with a stable identifier for each. Not code.

**Step 1 — Make the display representation good.**

Apple's step 1, and it is right. `DisplayRepresentation(title:subtitle:image:)` on the entity path
(§4.4); a well-written `title` and `contentDescription` on the Core Spotlight path (§3.3). Written
for a human, standing alone, out of context.

This is the highest-leverage hour in the whole project. It improves all three consumers, it is the
input to the indexing defaults, and — because of §7.3 — for consumer 2 it may be the *only* thing the
model ever reads.

**Step 2 — Index one type, end to end, and prove it with Spotlight.**

One type. Both maintenance directions (create *and* delete — see step 3). Then §8.2's loop: type a
distinctive word into Spotlight and see the row.

⚠️ **Do not proceed until that works.** Everything downstream is built on it, and every consumer
above it will fail in a way that points somewhere else.

**Step 3 — Wire deletion and update at the same time as creation, in the same function.**

Not a follow-up ticket. §3.6 and §13.2 are the most reliably-shipped defects in this area precisely
because deletion is a separate task that never gets scheduled. Write it now, while the creation code
is in front of you.

Session 343's rule, verbatim, is the checklist: index on create, **update when key properties change,
especially those used in your display representation**, delete on removal.

**Step 4 — Widen the attribute set, typed.**

Now go back and add the structured metadata: dates as dates, numbers as numbers, locations as
locations (§3.3). This is what makes structured search possible for consumer 2 and better ranking
possible for consumers 1 and 3. Custom attributes here too, with all three legs of §3.5's round trip
— donate, fetch, **explain**.

**Step 5 — Add the model consumer, and immediately test for §7.3.**

Add `SpotlightSearchTool`. Use `guide: .focused()` on device. Then, before you write a single line of
prompt: log `tool.searchResults` and diff the attributes that arrive against the ones you donated.

You are looking for the answer to one question — *does the model see bodies?* — and the answer
determines everything after. If yes, tune prompts. If no, you are in §9 and §10, and no amount of
prompt work will help.

**Step 6 — Hydrate.**

Implement §9's hook with the exact signature from §9.2, **with a signpost in it**. Confirm on your
build that it is called (§9.4 is why). If it is not — or if you are on the entity on-ramp and §10's
gap bites — fall back to the companion-tool pattern, which is verified working and entirely under
your control.

**Step 7 — Instructions as schema description.**

Now write the forty lines Apple's sample writes (§7.4): every attribute with its units and meaning,
negative constraints for filters that cannot work on your data, synonym seeds, and an explicit
instruction to say "not available" rather than infer over unindexed attributes.

This comes *after* step 5, deliberately. Writing instructions before you know what the model actually
receives is writing fiction.

**Step 8 — Widen: second type, then the Siri-specific and situational mechanisms.**

Only now. `IndexedEntityQuery` or the index delegate's reindex methods (§4.5 — one, not both),
`IntentValueQuery` for content you chose not to index (§11.3), `RelevantEntities` for cold-start
suggestions (§12), interaction donations last, per Apple.

### 14.3 The ordering argument, in one paragraph

The reason this sequence puts a *Spotlight* check at step 2 and a *diff of arriving attributes* at
step 5 — rather than putting the model feature first, which is what everyone wants to do — is that
both of those steps are **cheap tests that partition an expensive failure space**. Step 2 separates
"not indexed" from everything else. Step 5 separates "indexed but unreadable" from "readable but
badly prompted." Skipping them does not save the hour; it relocates the hour into a week of debugging
the wrong layer, and §13.10 is the map of that week.

### 14.4 What to index first, in one line

**Index the thing your user would name, with a title you would be happy to read aloud, and delete it
when they delete it.** Everything else in this guide is elaboration on that sentence.

---

## 15. Gap index, evidence ledger, related guides

### 15.1 The gaps, collected

Every 🔴 in this guide, with what would close it and what to do meanwhile.

**SDK-interface pass, 2026-07-29:** every row was checked against the `AppIntents` and
`CoreSpotlight` interfaces (26.5 and 27.0-beta, macOS) and — captured later the same day — the
`_CoreSpotlight_FoundationModels` overlay interface that declares the tool surface. **G1, G4 and
G6 closed; G3 half-closed; G5, G7 and G8 narrowed.** The pass cannot reach G2 — and Objective-C
API is outside any Swift module interface — and the macOS surface cannot prove an iOS-only symbol
absent.

| # | Gap | Resolves with | Safe default |
|---|---|---|---|
| **G1** | ✅ **Resolved (SDK, 2026-07-29)** — `IndexedEntity` is **macOS 15.0 / iOS 18.0 / visionOS 2.0**, watchOS/tvOS unavailable (`AppIntents-27.0-macos.swiftinterface:2608-2609`; 26.5:11476-11479). §4.1 | — | `#available(iOS 18, macOS 15)` for the on-ramp; 27.0 stays the model-consumer floor |
| **G2** | Which App Intents domains get **semantic** search — Apple's *"depending on the App Intents domain"*. Interface checked 2026-07-29 — encodes nothing about matching behaviour | An Apple doc page or forum answer naming them; or an on-device synonym A/B test | Put synonyms in `keywords` **and** in your model instructions. Never depend on semantic matching to bridge vocabulary |
| **G3** | The `CSSearchableIndex` deletion spelling — **item path only**; the entity-path spellings `deleteAppEntities(identifiedBy:ofType:)` / `deleteAppEntities(ofType:)` are now ✅ SDK-verified (`:366-367`). §3.6 | Any compiling call site, or the Objective-C header | For items: type `index.delete` and take Xcode's completion |
| **G4** | ✅ **Resolved (SDK, 2026-07-29)** — `priority:` is `Int = 0` (`:365`); its *semantics* remain undocumented. §4.2 | — | Omit it; both verified Apple call sites do |
| **G5** | **Does the hydration delegate fire for entity-indexed content, and with what identifiers?** Interfaces checked 2026-07-29: the delegate is Objective-C, invisible there; the new entity→item bridge API (§10.1) is adjacent evidence only | §10.4's test app — the highest-value experiment named in this guide | If you need model-readable bodies, donate `CSSearchableItem`s **too** (§10.3) |
| **G6** | ✅ **Resolved (SDK, 2026-07-29)** — the overlay interface answers all of it: the six capability parameters are `Bool?`, `attributes:` is `[SearchableItemAttribute]?`, and custom keys are expressible via `SearchableItemAttribute(rawValue:)` (`_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface:199-213`). §7.5 | — | `.focused()` remains the behavioural safe default — `.dynamic` was community-measured as prompt-sensitive |
| **G7** | The complete `AudioSearch.criteria` case list and the full set of `IntentValueQuery` system input types. `AudioSearch` is absent from the macOS 27.0 AppIntents interface (checked 2026-07-29) | Documentation pages for both, or the iOS interface | Handle the three named cases, always add a `default:` |
| **G8** | The full `AppEntityContext` domain/situation set. macOS 27.0 interface shows only `.audio(.nowPlaying)`; `.workout` absent from that surface (§12.2) | The iOS interface, or the type's doc page | Adopt `RelevantEntities` only for a context you have seen spelled out |

Plus two inherited conflicts that are not gaps — both sides are attested and they disagree:

| # | Conflict | Both sides |
|---|---|---|
| **C1** | Is `searchableItems(forIdentifiers:)` new? | ✅ Session 246: *"we've added a method"* / *"the new"*. **Community-measured:** macOS 15.4+, with only a `protectionClass` overload new in 27.0. Most economical reconciliation: what is new is the **tool's use** of an existing method. The Swift interface captures cannot arbitrate — the delegate is Objective-C (checked 2026-07-29) |
| **C2** | Does the hydration path work? | ✅ Session 246 describes it as the fix for the metadata gap. **Community-measured** on 27.0 betas: bodies did not arrive; in one report the delegate was never invoked in any configuration. Implement it, signpost it, keep the fallback (§9.4) |

### 15.2 Evidence ledger

What this guide rests on, by class, so you can weigh any individual claim.

**Class 0 — SDK module interfaces (added 2026-07-29).** `AppIntents-26.5` / `AppIntents-27.0`,
`CoreSpotlight-26.5` / `CoreSpotlight-27.0`, and `_CoreSpotlight_FoundationModels-27.0` — the
cross-import overlay that declares the entire `SpotlightSearchTool` surface — macOS
`.swiftinterface` captures in `notes/sdk-interfaces/`; the 27.0 files come from the Xcode 27 beta
SDK. Supplies: the closures of G1, G4 and G6, the §4 signatures, `SearchableItemAttribute`'s
member list, the §7 tool / configuration / guide / results declarations, and every ✅
SDK-verified marker. Outranks every class below for what compiles; blind only to Objective-C API.

**Class 1 — compiling Apple sample code.** `SearchingIndexedContentWithNaturalLanguage`, target
`LLMSearchUsingCoreSpotlightApp`, six Swift files, 792 lines, `IPHONEOS_DEPLOYMENT_TARGET = 27.0`,
`SWIFT_VERSION = 6.0`, entitlements an empty `<dict/>`. Supplies: §3.1, §3.4, §3.5, §7.2, §7.4, §7.6,
§9.2, and the tool name `spotlight_search`. **This is the strongest evidence in the guide and it
outranks the transcripts wherever they disagree — which in §9 they do.**

**Class 2 — Apple's published code-sample blocks on session pages.** Separate artifacts from the
transcript prose on the same page, so agreement between them is genuine corroboration rather than one
source read twice. Supplies: §4.2 (`indexAppEntities`), §4.4 (`DisplayRepresentation`), §11.3
(`IntentValueQuery`), §11.4 (`.system.searchInApp`), §12.2 (`RelevantEntities`).

**Class 3 — Apple documentation**, read through the sosumi.ai markdown mirror. Supplies: §1.2,
§4.1, §4.3, §4.5, and the lexical-and-semantic claim in §1.4.

**Class 4 — Apple-staff forum answers.** Thread **833658** (Engineer, accepted) is the load-bearing
one: *"`IndexedEntity` is backed by a `CSSearchableItem`… including `SpotlightSearchTool`."* Thread
**836760** (Frameworks Engineer) on the Siri-enablement coupling being unintended. Thread **833651**
(DTS Engineer) confirming the tool-schema issue as known.

**Class 5 — WWDC session transcripts.** 246 (Spotlight + Foundation Models), 240 (Siri and App
Schemas), 343 (advanced App Intents), 345 (new App Intents capabilities). Supplies most of the
"why", and the direct quotations throughout.

**Class 6 — community measurement, always attributed as such.** Two sources, both mid-2026 betas,
both single-developer:
- `spotlight-rag-third-party.md` — macOS 27 beta, M4 Max, 2026-06-13. Supplies the metadata-gap
  measurement (§7.3), the ~13k guidance-token figure (§7.2), the `.dynamic` prompt-sensitivity
  observation (§7.5), and field report 1 in §9.4.
- Developer Forums threads 829586, 832534, 833651, 835211, 837249, 838329, 838904. Supply §5.2's
  discovery/action confirmation, §6.4's screenshot-path observation, §9.4's field report 2, and
  §13.8–§13.9.

**Never asserted from memory.** Where a symbol appears in none of the above, this guide says so and
tells you to take the spelling from Xcode. §3.6 and §3.3 are the two places that happens most
visibly, and both are deliberate.

### 15.3 The version matrix

| Symbol | Earliest OS | Evidence |
|---|---|---|
| `CSSearchableIndex`, `CSSearchableItem`, `CSSearchableItemAttributeSet`, `CSSearchableIndexDelegate` | predates 26.0 by years | long-standing Core Spotlight API |
| `searchableItems(forIdentifiers:searchableItemsHandler:)` | **macOS 15.4+**, community-measured; new `protectionClass` overload in **27.0** | ⚠️ conflicts with session 246's "new" — §15.1 C1. Objective-C: invisible to the SDK-interface pass |
| `IndexedEntity` | **macOS 15.0 / iOS 18.0 / visionOS 2.0**; watchOS, tvOS unavailable | ✅ SDK interface (`AppIntents-27.0-macos.swiftinterface:2608-2609`) — was 🔴 G1 |
| `indexAppEntities(_:priority:)` | **macOS 15.0 / iOS 18.0 / visionOS 2.0**; `priority: Int = 0` | ✅ SDK interface (`:361-367`) |
| `@Property(indexingKey:)` / `(customIndexingKey:)` on entities | **macOS 15.4 / iOS 18.4** | ✅ SDK interface (`:498-512`) |
| `IndexedEntityQuery` | **27.0** | ✅ session 343: *"the new `IndexedEntityQuery`"* + SDK interface (`:4250-4254`); absent from the 26.5 interface |
| `SpotlightSearchTool` | **27.0** — macOS, iOS, visionOS; **watchOS and tvOS unavailable** | ✅ session 246 line 21 + SDK overlay interface (`_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface:327-330`) — the watchOS omission is compiler-attested |
| `SearchableItemAttribute` | **27.0**; watchOS, tvOS unavailable | ✅ session-246 sample + SDK interface (`CoreSpotlight-27.0-macos.swiftinterface:16-26`); absent from the 26.5 interface |
| `CoreSpotlightSource`, `GuidanceProfile`, `SearchReply` | **27.0**; watchOS, tvOS unavailable | ✅ session-246 sample + SDK overlay interface (`_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface:15-22`, `:199-213`, `:341-378`) |
| `RelevantEntities`, `AppEntityContext` | **27.0** | ✅ session 345 + SDK interface (`AppIntents-27.0-macos.swiftinterface:4814-4846`); macOS surface lacks the `.workout` context |
| `StringSearchCriteria` | **iOS 17.2 / macOS 14.2** | ✅ documentation page + SDK interface (`:792-808`) |
| `.system.searchInApp` (the *name*) | **27.0**; the schema itself is iOS 17 | ✅ session 343, twice + SDK interface: accessor `anyAppleOS 27.0`, deprecated `.system.search` message names it (`:13803-13826`) |
| `SnippetIntent` | **26.0** | ✅ documentation + SDK interface, `anyAppleOS 26.0` (`:1922-1927`) — routinely mis-reported as new in 2026 |

⚠️ **On year labels.** Session 345 says *"our 2027 releases"* three times; sessions 240 and 343 say
*"the 27 releases"*; session 241 says *"our 2027 release."* These are the same OS family named two
ways — the version number and the marketing calendar year. **"2027 releases" is not a claim about a
release after iOS 27.** Corroboration: `BarcodeReaderTool` and `OCRTool`, announced at the same
conference, are documented **"iOS 27.0+ Beta, macOS 27.0+ Beta."**

### 15.4 One-page summary

- **"Indexed entities for Apple Intelligence"** = `IndexedEntity` + `CSSearchableIndex.indexAppEntities(_:)`.
  Resolved. Not a second index — the same Core Spotlight index through a different door.
- **Two on-ramps, one index, three consumers**: Siri entity resolution, `SpotlightSearchTool`
  (your own RAG), and Spotlight search itself.
- **One indexing investment serves all three. One gap in it starves all three, silently.**
- **On-ramp A** (`CSSearchableItem`) is the verified path with a compiling Apple sample and a working
  hydration hook. **On-ramp B** (`IndexedEntity`) additionally buys Siri actionability with a schema,
  on-screen annotation targets, and `RelevantEntities`.
- **The index is searchable, not readable.** The model gets identity attributes and invents bodies.
  This is the defect that defines the model consumer and it never throws.
- **§9's hook is the documented fix**, its signature is a **completion handler** —
  `nonisolated`, non-throwing, `@escaping @Sendable ([CSSearchableItem]) -> Void`, **not**
  array-returning — and two field reports say it did not fire on 27.0 betas. Implement it, signpost
  it, keep the companion-tool fallback.
- 🔴 **Whether that hook fires for entity-indexed content is unverified.** If you need model-readable
  bodies, donate `CSSearchableItem`s too.
- **Only indexing feeds your language model.** `IntentValueQuery`, `.system.searchInApp`, donations
  and `RelevantEntities` are all Siri-and-system mechanisms and are invisible to
  `SpotlightSearchTool`.
- **Start at rung 1**: type a distinctive word into Spotlight. Almost every "the model hallucinates"
  bug is an indexing bug wearing a model costume.

### 15.5 Related guides

- [Part 2 guide 04 — Local RAG with `SpotlightSearchTool`, plus OCR and barcodes](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md)
  — the tool itself: configuration, the `SearchReply` stream, `queryToken`, guidance levels and their
  token cost, the contact resolver, custom pipeline stages, the three documented failure modes,
  running behind a third-party model, and evaluation. **Read that guide to build the feature; read
  this one to understand why it is only as good as your index.**
- [Part 2 guide 03 — The `Tool` protocol, calling modes, and the required-mode loop](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md)
  — what a tool call is, and `toolCallingMode: .required`, which §13.7 uses as an escape hatch.
- [Part 16 guide 02 — App Schema Domains: the complete map of what Siri can actually do](02-app-schema-domains.md)
  — all 23 domains, the discovery-versus-action wall behind §6.2, `.system.searchInApp` in full,
  query protocols, and the decision tree for apps with no domain.
- **Part 16 guide 03 — On-screen awareness: making Siri understand "this"** — `EntityIdentifier`,
  the four annotation shapes, the screenshot-versus-entity-resolution split behind §6.4, and the
  verified `.files.file` + `FileEntityIdentifier` + `FileRepresentation` hand-off recipe.
- [Part 1 — Orientation and gating](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/README.md) — availability, the
  Siri-enablement defect in §6.3, and the known-bad-claims reference.
- [Part 6 — Evaluations](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md) — session 246's own closing argument is that the
  way to tune a Spotlight-grounded feature is to iterate on *content and guidance profiles together*
  under an evaluation harness, with **result coverage** as the metric: given a dataset indexed in
  Core Spotlight, how well does the model generate responses based on the items you expected it to
  find. That is an indexing metric as much as a model metric.

---

*Guide compiled 2026-07-28 against research notes gathered 2026-07-27; re-verified 2026-07-29
against the macOS 26.5 and 27.0-beta SDK module interfaces in `notes/sdk-interfaces/`, including
the `_CoreSpotlight_FoundationModels` cross-import overlay that declares the `SpotlightSearchTool`
surface. That pass closed gaps G1, G4 and G6, half-closed G3, narrowed G5, G7 and G8, and added
every ✅ SDK-verified marker above. Every API name, signature and quotation traces to an artifact
read during those passes; the items still unverified carry 🔴 GAP boxes naming what is unknown,
what would resolve it, and what to do meanwhile.*

[^indexed-entity-source]: Apple, [“Making app entities available in Spotlight”](https://developer.apple.com/documentation/appintents/making-app-entities-available-in-spotlight),
    documents `IndexedEntity` conformance and direct donation through
    `CSSearchableIndex.indexAppEntities(_:)`.
