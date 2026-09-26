# App Schema Domains: the complete map of what Siri can actually do

**Part 16 · Adjacent capabilities · Reference 02**

**Version floor: the 27 releases — iOS 27, iPadOS 27, macOS 27, watchOS 27, visionOS 27, tvOS 27,
with Xcode 27.** That is the floor for the *new* material in this guide: `LongRunningIntent`,
`ExecutionTargets`, `EntityCollection`, `SyncableEntity`, `RelevantEntities`,
`OwnershipProvidingEntity`, `IndexedEntityQuery`, `ValueRepresentation`, `@UnionValue` as an
*input* parameter, and the `.system.searchInApp` schema name. It is **not** the floor for the
schema system itself. App schema domains predate this release — session 240's presenter points
readers at *"my video from WWDC24"* for how schemas work — and three of the load-bearing types in
this guide are considerably older: **`StringSearchCriteria` is iOS 17.2 / macOS 14.2**,
**`SnippetIntent` is iOS 26.0**, and the `.system` search schema was, in Apple's own words,
*"introduced in iOS 17."* Every API below carries its earliest OS where we could establish one,
and a 🔴 GAP box where we could not.

**SDK-interface pass, 2026-07-29.** Everything above was re-checked against the SDK module
interfaces in `notes/sdk-interfaces/` — `AppIntents-26.5-macos.swiftinterface` and, from the real
macOS 27.0 SDK in Xcode 27 beta, `AppIntents-27.0-macos.swiftinterface` (16,826 lines). Claims
confirmed there are marked ✅ **SDK-verified** with `file:line` citations; that marker outranks
every other evidence class in this guide, because it is the declaration the compiler sees. The
headline floors hold: `LongRunningIntent`, the execution-targets machinery, `EntityCollection`,
`SyncableEntity`, `RelevantEntities`, `OwnershipProvidingEntity`, `IndexedEntityQuery`, the
`@UnionValue` input-parameter machinery and `.system.searchInApp` are all `anyAppleOS 27.0` in the
interface, and none of them exists in the 26.5 interface. One refinement: `ValueRepresentation` is
a typealias for `IntentValueRepresentation`, which the 27.0 interface annotates `anyAppleOS 26.4`
— §13.1, whose naming hazard that pass resolves outright.

⚠️ **One version caveat you will trip over reading Apple's own material.** Session 345 says
*"our 2027 releases"* — three separate times. Sessions 240 and 343 say *"the 27 releases."*
Session 241 says *"our 2027 release."* These are the same OS family named two ways: the version
number and the marketing calendar year. **"2027 releases" is not a claim about a release after
iOS 27.** The corroboration is that `BarcodeReaderTool` and `OCRTool`, announced at the same
conference, carry documented availability **"iOS 27.0+ Beta, macOS 27.0+ Beta."** Treat every
year label in this space as soft and every *API name* as the solid part.

---

## What this covers

This guide is an **enumeration**. That is the product. Apple's App Intents documentation spreads
the app-schema surface across roughly twenty-four separate pages — one index plus one page per
domain — and there is no page, in Apple's docs or anywhere else we could find, that puts the whole
thing in one place. Without the whole thing in one place you cannot answer the only question that
actually matters at the start of an integration:

> **Is there a schema for what my app does? And if not, what is left?**

So: **all 23 domains, in three tiers, with the intents, entities and enums each one contains.**
**182 intents, 74 entities and 50 enums — censused symbol-by-symbol against the macOS 27.0 beta
SDK interface on 2026-07-29** (§5.4). Then the part nobody writes down — the
categories that have **no domain at all** — and then the one Siri hook that is reachable
regardless.

Around that enumeration sit the things you need in order to use it:

- **§2–§3 — Why schemas exist at all.** Apple's own discovery-versus-action framing, which is the
  single most clarifying paragraph in the whole area, and the three macros that implement it.
- **§4 — The three tiers**, and the under-appreciated fact that eight of the 23 domains are
  grouped as *Shortcuts-specific*, not Siri-tier.
- **§5 — The complete enumeration.** Thirteen primary domains, two single-purpose, eight
  Shortcuts-only, with counts and per-domain commentary on what the shape of each one tells you.
- **§6 — The absences, stated plainly.** No fitness, health, finance, commerce, travel, food,
  transport, social, education or games domain. For most readers this is the most useful
  paragraph in the guide.
- **§7–§8 — The deprecations, and `.system.searchInApp`** — the escape hatch, with complete code.
  It is a *rename*, not a new schema, and it works regardless of domain adoption or indexing.
- **§9 — A decision tree** from "what does my app do" to one of three outcomes.
- **§10 — Query protocols**, and how entity resolution actually works. Picking the wrong query
  protocol is a leading cause of "Siri can't find my stuff."
- **§11–§12 — Shaping the conversation:** custom dialog, `requestValue`, `SnippetIntent` (which
  is an **iOS 26** feature and is routinely mis-reported as new this year), `ShowsSnippetView`,
  interaction donations, confirmations and `OwnershipProvidingEntity`.
- **§13 — The new execution model.** `LongRunningIntent` past the 30-second wall,
  `ExecutionTargets` for choosing the process, `EntityCollection` for the parameter-resolution
  performance cliff, `@UnionValue`, `ValueRepresentation`, `RelevantEntities`, `SyncableEntity`,
  and the extended native `@Parameter` types.
- **§14 — Silent failures**, including the mandatory one: `IntentParameter.valueState`.
- **§15 — Testing**, §16 — the gap register, §17 — sources and how to re-verify.

## What this does *not* cover

- **On-screen awareness in depth** — the two paths, the four annotation shapes, and the verified
  `.files.file` + `FileEntityIdentifier` + `FileRepresentation` hand-off recipe. That is
  [Part 16 guide 03](03-onscreen-awareness.md). This guide touches on-screen material only where
  the schema map depends on it.
- **Spotlight indexing in depth** — `IndexedEntity`, `indexAppEntities`, the semantic index, and
  the fact that Siri entity resolution and `SpotlightSearchTool` read the *same* index. That is
  [Part 16 guide 04](04-entities-spotlight-and-foundation-models.md).
- **Foundation Models.** There is no direct `AppIntent` → `LanguageModelSession` bridge; the
  connection is indirect and runs through Spotlight. See guide 04 and
  [Part 2 guide 04](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md).
- **Writing a plain `AppIntent`, `AppShortcutsProvider`, or a widget configuration intent.** Those
  are unchanged fundamentals and Apple's own App Intents documentation covers them well.

## What you need

- **Xcode 27.** The schema tooling — autocomplete of schemas by domain, the missing-schema build
  error, and the Fix-Its that generate a schema adoption — is an Xcode feature, not a runtime one.
  You get it whether or not you have a device that runs Apple Intelligence.
- **A device or simulator on the 27 releases** for anything involving Siri end to end.
- **`import AppIntents`.** Everything in §5 lives there. The Spotlight material additionally needs
  `import CoreSpotlight`; `ValueRepresentation` with places needs `GeoToolbox`.
- **Realistic expectations about Siri availability on betas.** `SystemLanguageModel.default
  .availability` returning `.appleIntelligenceNotEnabled` unless "Siri"/"Press Side Button for
  Siri" is switched on is **a bug, acknowledged by an Apple Frameworks Engineer on forum thread
  836760**, not a design constraint you should build around. It affects Foundation Models more
  than App Intents, but it will confuse your device testing. See
  [Part 1 guide 02](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/references/02-platform-and-version-gating.md).

---

## ⚠️ Read this before you trust a symbol name below

**The evidence classes in this guide are not the ones the rest of the series relies on.** There is
no Apple sample-code project for App Intents schema domains in our corpus — we checked. So the top
of the ladder here is Apple's *documentation pages* and Apple's *published code-sample blocks on
the WWDC26 session pages*, which are a distinct artifact from the spoken transcript on the same
page and are therefore an independent second reading of the same API.

**One artifact has since been added above all of these: the SDK module interfaces themselves.** On
2026-07-29 every API symbol in this guide was checked against
`AppIntents-26.5-macos.swiftinterface` and `AppIntents-27.0-macos.swiftinterface`
(`notes/sdk-interfaces/`). Where the interface confirms a claim it is marked ✅ **SDK-verified**
(`AppIntents-27.0-macos.swiftinterface:NNNN`), which outranks every class below — it is what
compiles. Its one blind spot: these are the **macOS** surfaces, so a symbol absent from them may
still exist on iOS (flagged inline where it matters).

In descending order, as used below:

1. **Apple documentation pages**, read through the `sosumi.ai` markdown mirror on 2026-07-27 and
   recorded in `notes/web/app-intents-siri-schemas.md`. This is where the entire §5 enumeration
   comes from. Marked ✅ **VERIFIED (docs)**.
2. **Apple's published code samples on the session pages** for WWDC26 sessions 240, 343 and 345 —
   fetched 2026-07-27, recorded verbatim in `notes/transcripts/missing-sessions.md`. Marked ✅
   **VERIFIED (Apple code sample, session N @ time)**. Where a name appears in *both* the
   transcript prose and the code block, that is two independent renderings and it is called out.
3. **WWDC26 session transcript prose.** Marked ✅ **VERIFIED (transcript)** for direct quotations,
   because the sentence itself is verifiable, and 🟡 **RECONSTRUCTED** for any code shape assembled
   from narration — session **344 published no code-sample block at all**, so everything
   code-shaped attributed to 344 is a reconstruction and is labelled as such.
4. **Apple-staff forum answers** and **community forum findings**, always attributed by thread
   number and by whether the answer came from Apple or from another developer. In this topic area
   that distinction matters unusually much: of the App Intents / Siri / on-screen threads examined,
   **one had a substantive Apple answer, one was deflected to Feedback Assistant, and the rest are
   unanswered.** The single most useful technical answer in the cluster came from another
   developer, not from Apple.

Two hazards were flagged inline wherever they appear, and again in §16 — one of them has since
been resolved:

- **`ValueRepresentation` vs `IntentValueRepresentation` — resolved by the SDK pass.** They are
  the same type: `extension AppEntity { public typealias ValueRepresentation =
  IntentValueRepresentation }` — ✅ **SDK-verified**
  (`AppIntents-27.0-macos.swiftinterface:2629-2634`). §13.1 has the details, including why each
  session used the spelling it did.
- **Release-year labels.** See the version-floor box above.

---

## Contents

1. [Three systems people conflate](#1-three-systems-people-conflate)
2. [Discovery versus action — the framing everything else follows from](#2-discovery-versus-action--the-framing-everything-else-follows-from)
3. [The macro system, and the build errors it generates](#3-the-macro-system-and-the-build-errors-it-generates)
4. [The three tiers, and what each one reaches](#4-the-three-tiers-and-what-each-one-reaches)
5. [The complete enumeration — all 23 domains](#5-the-complete-enumeration--all-23-domains)
6. [The absences — what has no domain at all](#6-the-absences--what-has-no-domain-at-all)
7. [Deprecations, and where generic search went](#7-deprecations-and-where-generic-search-went)
8. [`.system.searchInApp` — the escape hatch](#8-systemsearchinapp--the-escape-hatch)
9. [Decision tree: which route is open to you](#9-decision-tree-which-route-is-open-to-you)
10. [Query protocols and how entity resolution works](#10-query-protocols-and-how-entity-resolution-works)
11. [Shaping the response: dialog, questions, and snippets](#11-shaping-the-response-dialog-questions-and-snippets)
12. [Donations, confirmations, and entity ownership](#12-donations-confirmations-and-entity-ownership)
13. [The new execution model](#13-the-new-execution-model)
14. [Silent failures](#14-silent-failures)
15. [Testing: the four-stage ladder](#15-testing-the-four-stage-ladder)
16. [Gap register](#16-gap-register)
17. [Sources](#17-sources)

---

## 1. Three systems people conflate

Before the map, the terrain. A large share of the developer confusion in this area — and the
forum record makes it very visible — comes from treating three different mechanisms as one
feature. They have different requirements and, crucially, **different degrees of openness**.

### (A) App Shortcuts — voice invocation of your own intents

**Fully open.** Any `AppIntent` you write, exposed through an `AppShortcutsProvider`, is invocable
by voice. No schema required, no indexing required, no whitelist.

The cost is a phrase shape: the user generally has to **name your app**. *"How far have I
travelled in TripLog?"* rather than *"How far have I travelled?"*

Session 240 is explicit that this baseline is real and valuable on its own:

> ✅ **VERIFIED (transcript, WWDC26 240)** — *"When you define an app intent, that action can show
> up across the system in places like **Shortcuts, Spotlight, Widgets**, and more. … **even
> without Siri.**"*

This is the fallback every blocked developer lands on. Forum thread 837249 describes arriving here
and finding it *unnatural* — a cycling app, hands on the bars, having to say the app's name in
every request. That complaint is legitimate and it has no first-party answer. It is also, for many
apps, the only complete answer available today.

### (B) App schema domains — "Siri, do this thing" without naming the app

**Restricted.** For Siri to route a *generic, un-app-qualified* request to your app, your intent or
entity must conform to one of Apple's predefined schemas via `@AppIntent(schema:)` /
`@AppEntity(schema:)` / `@AppEnum(schema:)`. The schema fixes the parameter list and the semantics,
so the system knows what your type *means* rather than merely what it is called.

Session 240 puts the relationship precisely:

> ✅ **VERIFIED (transcript, WWDC26 240)** — *"Just like entities use app schemas to be understood,
> **actions use schemas to become executable by Siri**. Think of schemas as **a specialization of
> App Intents**. **They're still App Intents, but shaped in a way that Siri knows how to
> process.**"*

There are **23 domains**. §5 lists all of them. **The surface is closed** — there is no mechanism
to define your own domain, register a custom schema, or petition at runtime. If your app's core
concept is not on the list, this route is unavailable to you. That structural fact is the cause of
essentially every thread in the forum cluster.

### (C) On-screen awareness — "this"

**Restricted differently**, and the least documented of the three. Evidence from forum thread
838329, instrumented on iOS 27 beta 3, indicates the system takes **two separate paths**:

| Request shape | Path taken | Does it call your `EntityQuery`? |
|---|---|---|
| *"Describe this image"* | screenshot / OCR | **No** |
| *"Create a note for this"* | screenshot / OCR | **No** |
| *"Send this to \<contact\>"* | entity resolution | Yes — but **failed** for a custom entity |
| Hand-off to another app | entity resolution | Yes — fired, then stalled |

> **Community-measured**, forum thread 838329 (FrankSchlegel, 17 Jul 2026), iOS 27 beta 3, on
> device. The `entities(for:)` never-fires observation is from the poster's own instrumented
> logging. Not an Apple statement.

The operational consequence is sharp and worth stating before anyone spends a week on it:
**descriptive on-screen questions never consult your entities.** If your app's Siri ambition is
"answer questions about what's on screen," entity plumbing is the wrong tool — the system is
reading pixels. Guide 03 in this part covers this in full.

### The rule that falls out

**Discoverability is open. Actionability is whitelisted.**

Siri can *see* your custom entity — indexing it into Spotlight is enough for that. It will not
reliably *act* on it, or move it across an app boundary, unless it is schema-typed. This is not a
bug report; it is the documented architecture, and §2 quotes Apple saying so.

The community reached the same conclusion independently. Forum thread 829586 — 14 replies and
about a thousand views, the most-discussed thread in this cluster — records a distinction
attributed to the Apple Intelligence Group Lab:

> **Community-reported** (thread 829586, developer paraphrase of a Group Lab answer; **not** a
> written Apple statement):
> 1. Entity **discoverability** does not require conforming to whitelisted schema domains.
> 2. Siri can **only take actions** that do conform to whitelisted schema domains.

That thread also notes that **Apple's own `TrailEntity` hiking sample maps to no published
domain**, so Siri cannot help users compare routes in Apple's own example. The developer filed
**FB23018652**; DTS characterised it as an enhancement request, not a bug.

---

## 2. Discovery versus action — the framing everything else follows from

The cleanest statement in the entire documentation set is on the page *"Making actions and content
discoverable by Apple Intelligence."* It splits the problem into two layers that are satisfied by
two completely different mechanisms at two different times:

> ✅ **VERIFIED (docs)** — **Discovery is a runtime concern, satisfied by indexing.** *"Submit your
> entities to the Spotlight semantic index so the system indexes your app's content and matches it
> to requests."*

> ✅ **VERIFIED (docs)** — **Action is a build-time concern, satisfied by schemas.** Schema macros
> plus the required properties are what let Apple Intelligence interpret a request and invoke your
> intent.

And then the sentence that resolves the whole forum cluster:

> ✅ **VERIFIED (docs)** — *"Without both layers, Apple Intelligence cannot act on user requests
> involving your entities."*

Read that carefully. It does not say indexing is optional. It says **neither layer alone is
sufficient**. An app that indexes entities but adopts no schema gets discovery without action. An
app that adopts a schema but never indexes gets an executable action that Siri cannot find the
right operand for.

### Why a schema is needed on top of an entity

Session 240 explains what the schema buys in terms of what Siri can *reason* about:

> ✅ **VERIFIED (transcript, WWDC26 240)** — *"modeling an entity is the first step, but **on its
> own, that's not enough** for Siri to be able to find it or talk about it. For Siri to understand
> **what an entity is, what category of thing it represents**, your entity needs to conform to an
> **`AppSchema`**. … **Instead of treating your app like a black box, Siri can reason about what
> the user is talking about.**"*

The same session gives the definition of an entity that prevents the most common misunderstanding
— that entities are a data model you must migrate to:

> ✅ **VERIFIED (transcript, WWDC26 240)** — *"App entities describe **three important things. What
> the thing is, how it's identified, and which properties matter**, like a title, a date, or some
> text."* … *"**They're not a new data model. They're a way of describing your existing content so
> the system can understand it.**"*

And the mapping is mundane on purpose: *"If you have a calendar app, **each event** is an entity.
If you have a mail app, **each message** is an entity. And if you have a photos app, **each photo
and each album** is an entity."* (✅ VERIFIED, transcript, 240.)

### What a domain is

> ✅ **VERIFIED (transcript, WWDC26 240)** — *"schemas are grouped into **`AppSchema` domains**.
> Each domain represents a **category of tasks**, such as mail, photos, messages, and more. …
> Think of domains as **categories of contracts between your app and Siri**."*

"Contract" is the right word and it is worth taking literally. A contract has terms you do not get
to renegotiate: the parameter names, the parameter types, sometimes even your identifier type
(§3.2). In exchange, Siri undertakes to understand the natural language and route it to you. The
trade is real and it is not symmetric — you give up modelling freedom, and what you get back is
language understanding you could not have built.

### ⚠️ Where the docs contradict the observed behaviour

One documentation sentence cuts against all of the above, and you should know about it before you
read it somewhere and act on it. The *"Providing contextual cues to Apple Intelligence and Siri"*
page says, of schema adoption for on-screen annotation:

> ✅ **VERIFIED (docs)** — *"Schema application is optional but recommended for consistency."*

The observed behaviour on iOS 27 beta 3, per thread 838329, is that a **non-schema entity was never
resolved** for hand-off — `entities(for:)` never fired for the Siri paths — while the schema-typed
`.files.file` entity resolved and transferred correctly.

🟡 **RECONSTRUCTED interpretation.** Both statements can be true if "optional" governs
*annotation/reference* — pointing at a thing — while schemas govern *transfer* — moving its
payload. That reading is consistent with the discovery/action split above. **But no Apple page
says this**, and a developer reading "optional but recommended" will reasonably conclude the
custom-entity route is supported, and then lose days. The original poster asked Apple this exact
question:

> **Community quotation**, thread 838329 — *"I wonder if this more generic approach shouldn't also
> work... Is on-screen consumption intended to be limited to the predefined assistant schemas, or
> should a custom `AppEntity` + `Transferable` also be a supported way to expose arbitrary
> on-screen content?"*

**It is still unanswered.** Apple's DTS engineer replied to the thread and routed the developer to
Feedback Assistant (**FB23813341**) without giving API guidance. The working answer in that thread
came from another developer.

**Safe default while this is open:** assume schema-typed means actionable and non-schema means
discoverable-only. Design so that the schema-typed path is the one your feature depends on, and
treat any custom-entity behaviour that happens to work as a bonus you have not been promised.

---

## 3. The macro system, and the build errors it generates

Three macros, one per kind of thing. This is the entire adoption surface.

```swift illustrative
import AppIntents

@AppEntity(schema: .photos.asset)     // content — a noun your app owns
@AppIntent(schema: .photos.openAsset) // actions — a verb Siri can execute
@AppEnum(schema: .photos.assetType)   // property value sets — a closed vocabulary
```

✅ **VERIFIED (docs)** — all three spellings from the *"Making actions and content discoverable by
Apple Intelligence"* page and the app-schema-domains index page.

✅ **SDK-verified** — all three macros are declared in the 27.0 interface, each
`@available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)`:
`macro AppIntent<T>(schema:)` (`AppIntents-27.0-macos.swiftinterface:10944`),
`macro AppEntity<T>(schema:)` (`:10769`), `macro AppEnum<T>(schema:)` (`:10625`). The `schema:`
argument resolves through an `AppSchema` namespace (`:10593`) that exists **only in the 27.0 SDK**
— the 26.5 interface spells the same schemas through an `AssistantSchemas` namespace, which the
27.0 interface marks deprecated throughout. Same schemas, new front door; the macro spellings you
write are unchanged.

Symbol paths follow `AppSchema.<Domain><Kind>.<name>`. So the dot-syntax `.mail.sendDraft` you
write at the macro call site resolves to `AppSchema.MailIntent.sendDraft`, documented at
`/documentation/appintents/appschema/mailintent/senddraft`. ✅ **VERIFIED (docs)** — this is how the
documentation URLs are structured, which is also the fastest way to check whether a schema you
half-remember actually exists: construct the URL.

⚠️ **One naming mismatch to know about before you go URL-hunting.** The journaling domain's page
lives at `app-schema-domain-journaling` and is titled "Journaling", but the symbol is
`AppSchema.JournalIntent` — singular, no "-ing" — and the dot-syntax is `.journal`. ✅ **VERIFIED
(docs)**. Guessing `.journaling` will not compile.

### 3.1 Schemas are enforced at build time, with Fix-Its

This is the pleasant surprise of the system. You do not discover a missing property at runtime in
a Siri transcript; you discover it when you press Build.

> ✅ **VERIFIED (docs)** — *"If your type is missing a required property, Xcode generates an error
> at build time with a Fix-It that adds it for you."*

The required-property set is per schema. For `.photos.asset`:

```swift prelude:guide-context
// Required by @AppEntity(schema: .photos.asset)
var displayRepresentation: DisplayRepresentation
var id: Int
var creationDate: Date?
var assetType: PhotoAssetType?
var isFavorite: Bool
var isHidden: Bool
```

✅ **VERIFIED (docs)** — the *"Making actions and content discoverable"* page lists exactly these.

And for `.photos.openAsset`:

```swift illustrative
// Required by @AppIntent(schema: .photos.openAsset)
var target: <EntityType>
func perform() async throws -> some IntentResult
```

✅ **VERIFIED (docs)**.

### 3.2 Schemas dictate your identifier type — this is not a formality

Look again at `.photos.asset`: **`var id: Int`**.

Not `var id: ID`. Not "some `Hashable`". `Int`. If your photo model is keyed by `UUID` or by a
CloudKit record name, adopting `.photos.asset` means producing a stable `Int` for every asset and
being able to go back the other way — because `EntityQuery.entities(for:)` will hand you `[Int]`
and expect entities in return.

That is a real modelling constraint that lands in your persistence layer, and it is worth
discovering in an afternoon of design rather than three weeks into an implementation. Session 344,
building a calendar app, hit the friendlier version of this and said so out loud:

> 🟡 **RECONSTRUCTED from narration (WWDC26 344)** — *"set the id type to `UUID` to match the data
> model"* for `@AppEntity(schema: .calendar.calendar)`.

So `.calendar.calendar` is *not* pinned to `Int` the way `.photos.asset` is. **The identifier type
is per-schema and you have to look it up.** There is no general rule.

🔴 **GAP — the per-schema required-property tables.** We have verified required-property lists for
exactly two schemas: `.photos.asset` and `.photos.openAsset` (from the docs page above), plus the
parameter lists of `.clock.createTimer`, `.audio.addToPlaylist`, `.system.searchInApp` and
`.system.open` (from Apple code samples, §5 and §8). **The other ~180 schemas' required properties
are not enumerated anywhere in our corpus.** What would resolve it: the per-schema documentation
pages under `/documentation/appintents/appschema/<domain>intent/<name>`, read one at a time. The
27.0 SDK interface was checked on 2026-07-29 and **does not settle it**: the interface encodes
each schema only as an opaque string accessor — `AppSchema.Intent("MailSendDraftIntent")` and the
like — not as a property list; the requirements live in the macro's external definition, outside
the module interface. **Safe default:** do not plan your data model
around a schema you have not opened in Xcode. Type the snippet trigger (§3.4), let Xcode scaffold
the real property list, and *then* decide whether adoption is cheap.

### 3.3 ⚠️ Schemas come in conversational sets — a build error you will not expect

This is the most surprising behaviour in session 240 and it appears in no documentation page we
found.

> ✅ **VERIFIED (transcript, WWDC26 240)** — *"we adopted the `sendMessage` schema in UnicornChat.
> That works great. People can send messages with Siri. But now, let's try to build. **And we get a
> build error.** Xcode is telling us that while we adopted `sendMessage`, **we haven't adopted the
> related `draftMessage` schema**. This is important because **some Siri scenarios require more
> than one schema** to deliver a complete experience."*

The reason is confirmation flow, and once stated it is obvious: Siri drafts, shows you the draft,
and sends on your approval. Without a draft schema there is nothing to show.

> ✅ **VERIFIED (transcript, WWDC26 240)** — *"**This isn't just a compiler error, it's a design
> hint.** Xcode knows that **if your app can send messages with Siri, it also needs a way to draft
> messages, especially when confirmation is required.** So instead of failing silently at runtime,
> **the build system surfaces this early.**"*

And there is a generated fix:

> ✅ **VERIFIED (transcript, WWDC26 240)** — *"If we click into the error, **Xcode offers a
> fix-it**. Xcode **generates a sample adoption of the `draftMessage` schema**. This gives us **an
> intent definition, the required parameters and a stub implementation. All wired correctly.**"*

One detail about the generated stub that matters for concurrency: it *"needs to run on the **main
actor**"* because it *"mutates UI state"* — it opens the message-creation view. ✅ **VERIFIED
(transcript, 240)**. If you are adopting schemas into an actor-isolated architecture, expect
`@MainActor` on the intents that present UI.

**The generalization Apple states:**

> ✅ **VERIFIED (transcript, WWDC26 240)** — *"**if a Siri experience depends on multiple schemas,
> Xcode will tell you, show you what's missing, and help you generate the right remaining
> steps.**"*

🔴 **GAP — the full co-requisite graph.** Exactly **one** pair is demonstrated anywhere in our
corpus: **`.messages.sendMessage` ⇒ `.messages.draftMessage`**. Which other schemas have
co-requisites, and what they are, is unknown. What would resolve it: adopting each schema in a
scratch project and reading the build errors. The 27.0 SDK interface was checked on 2026-07-29
and does not settle it — co-requisites are not encoded in the module interface. **Safe default:** budget for the possibility that adopting *any* "commit an
action" verb drags in its "prepare the action" sibling. Plan schema adoption in pairs, not
singletons.

### 3.4 The Xcode snippet trigger — `<domain>_`

The discovery mechanism is a code snippet keyed by domain prefix. Type the domain name, an
underscore, and Xcode offers every schema in that domain.

> ✅ **VERIFIED (docs)** — from the system-and-in-app-search domain page: *"Xcode generates a
> template implementation when you type `system_` and select a schema from the suggestions list."*

Session 344 walks the same workflow for `.calendar` and confirms the convention generalizes:

> ✅ **VERIFIED (transcript, WWDC26 344)** — *"I'll type **`calendar_`** in the editor. **Xcode
> offers every schema in the Calendar domain, right in autocomplete.** Since the goal is a calendar
> entity, I'll select **`calendar_calendar`**."*

> ✅ **VERIFIED (transcript, WWDC26 344)** — *"**The snippet fills in the structure: the
> `@AppEntity` macro, properties, `DisplayRepresentation` and query stubs.**"*

For intents specifically it *"scaffolds the intent with the **`@AppIntent` macro, the schema, all
the parameters the schema requires, and a `perform` stub**."* ✅ **VERIFIED (transcript, 344)**.

Snippet names verified in session 344, all following `<domain>_<schemaName>`:

| Snippet you type | What it scaffolds |
|---|---|
| `calendar_calendar` | `@AppEntity(schema: .calendar.calendar)` |
| `calendar_attendee` | attendee entity |
| `calendar_attendeeStatus` | `@AppEnum` with *"all the cases the schema supports"* |
| `calendar_attendeeType` | `@AppEnum` for attendee kind |
| `calendar_event` | event entity |
| `calendar_createEvent` | `@AppIntent(schema: .calendar.createEvent)` + params + `perform` stub |
| `calendar_updateEvent` | update intent |
| `system_` (prefix) | every `.system` schema |

✅ **VERIFIED (transcript, 344)** for the `calendar_*` rows; ✅ **VERIFIED (docs)** for `system_`.

**This is the single best way to use §5 of this guide.** The enumeration below tells you *whether*
a schema exists; the snippet tells you *what it requires*. Look it up here, type it there.

### 3.5 The schema `@AppEnum` rule: subsettable, but non-empty

Schema enums behave differently from your own enums, and session 344 states the rule cleanly:

> ✅ **VERIFIED (transcript, WWDC26 344)** — *"**The schema defines the set of possible cases, and
> my app adopts the ones that apply.**"* … *"The snippet comes with **all the cases the schema
> supports**. CometCal's model already maps directly, so no changes are needed, but **if an app
> uses different terminology, simply map the existing model to the schema's cases so Siri can
> recognize the shape.**"*

And the floor:

> ✅ **VERIFIED (transcript, WWDC26 344)** — *"**The schema requires at least one case** to describe
> what kind of attendee this is and since CometCal's attendees are all people, I'll add a
> **`person`** case."*

So: **you pick from a fixed vocabulary, you may not invent cases, and you must supply at least
one.** If your app's vocabulary differs from Apple's — you call them "collaborators", the schema
calls them "attendees" — you map, you do not extend.

### 3.6 The schema is a floor, not a ceiling

A genuinely reassuring rule, and the one most likely to unblock an adoption decision. From
session 344, on building a large `EventEntity`:

> ✅ **VERIFIED (transcript, WWDC26 344)** — *"The schema defines which properties are **required**
> and which are **optional**. The essentials like **`title`** or **`startDate`** are
> straightforward to wire up. **Optional properties that my app doesn't use, like `travelTime` or
> `virtualLocation`, can simply stay unset.** **Properties that aren't part of the schema but exist
> on the data model, like `isFavorite`, can also be added to the entity.**"*

Three rules, in order of how often they are misunderstood:

1. **Required → wire it up.** Non-negotiable; the build fails otherwise.
2. **Optional and unused → leave unset.** You do not have to synthesize data you do not have.
   A calendar app with no travel-time concept does not invent one.
3. **Not in the schema but on your model → add it anyway.** The entity may carry properties the
   schema knows nothing about. Siri will not reason about them, but Shortcuts, your own code and
   the Spotlight index can still use them.

Rule 3 is the important one. Adopting a schema does not force you to throw away the parts of your
model that make your app yours. It forces you to *also* speak Apple's vocabulary for the parts
Apple has vocabulary for.

---

## 4. The three tiers, and what each one reaches

Apple's own index page groups the 23 domains into three tiers. **The tier determines where the
schema is usable**, and this distinction is the easiest thing in the whole area to miss.

| Tier | Count | Domains | Reach |
|---|---:|---|---|
| **Primary** | 13 | `audio` `calendar` `camera` `clock` `files` `mail` `maps` `messages` `notes` `phone` `photos` `reminders` `system` | Apple Intelligence + Siri + Shortcuts |
| **Single-purpose** | 2 | `assistant` `visualIntelligence` | One specific system surface each |
| **Shortcuts-specific** | 8 | `books` `browser` `journal` `presentation` `reader` `spreadsheet` `whiteboard` `wordProcessor` | **Shortcuts app** — per the docs' own grouping |

✅ **VERIFIED (docs)** — the grouping, the tier labels, and the membership of each tier come from
`/documentation/appintents/app-schema-domains`, fetched 2026-07-27.

### ⚠️ Why the third tier matters more than it looks

A developer who adopts, say, `.wordProcessor.createPage` expecting Siri to route natural-language
requests to it is adopting a **Shortcuts-tier** schema. The documentation's own taxonomy places
these outside the Apple Intelligence / Siri tier.

If you are building an iWork-class app, this is the difference between "Siri can create a page in
my app when someone asks" and "there is a Shortcuts action a user can wire into an automation."
Both are worth having. They are not the same thing, and the second one will not satisfy a product
requirement written as the first.

🟡 **RECONSTRUCTED — the exact capability each tier confers.** We have the three-tier grouping and
its labels from the index page. We did **not** find any page that states in prose what capability
each tier grants. The "Reach" column above is **inference from the taxonomy labels**, not a quoted
claim. What would resolve it: a documentation page or session statement defining tier semantics,
or empirical testing — adopt a Shortcuts-tier schema and try an un-app-qualified Siri request on
device. The 27.0 SDK interface was checked on 2026-07-29 and does not settle it — it encodes
domain membership (§5.4) but says nothing about what each tier reaches. **Safe default:** if your feature must work through Siri without the user naming your app,
plan on a *primary*-tier domain, and treat any Shortcuts-tier behaviour beyond the Shortcuts app
as a bonus.

### Corroboration from the domain prose

Two independent signals support the tier reading, both ✅ **VERIFIED (docs)**:

- Primary-domain pages use Apple Intelligence and Siri language directly. The `.notes` page:
  *"Make your note-taking app's actions available to **Apple Intelligence and Siri** by adopting
  schemas for common note actions."* The `.phone` page: *"Make your phone app's actions available
  to **Apple Intelligence and Siri** by adopting schemas for calling actions."*
- The single-purpose pages name their one surface explicitly — `.assistant` registers a side-button
  action, `.visualIntelligence` *"connects your app to the camera control."*

The Shortcuts-tier pages, in the material we captured, do not carry the Apple Intelligence framing.
That is consistent with the taxonomy, and it is *absence* of evidence rather than a statement, so
it strengthens the inference without settling it.

---

## 5. The complete enumeration — all 23 domains

**This is the artifact.** Every domain, every documented leaf schema, grouped by tier.

### How to read the evidence here

Every name below traces to an Apple documentation page read through the `sosumi.ai` mirror during
the research pass of 2026-07-27, recorded in `notes/web/app-intents-siri-schemas.md` §3. That pass
states that each domain page was fetched individually at
`https://sosumi.ai/documentation/appintents/app-schema-domain-<name>`.

One honesty note about *how strongly* verified each row is. The pass's own source-inventory table
itemizes eleven domain pages explicitly by URL — **mail, files, photos, camera, browser, reader,
journaling, books, whiteboard, assistant, and system-and-in-app-search** — plus the index page.
The remaining twelve domains rest on the pass's blanket statement that all were fetched, not on an
itemized URL row. We mark the whole enumeration ✅ **VERIFIED (docs)** because it all comes from the
same class of artifact, and we flag the distinction here rather than burying it, because if any row
in §5 turns out to be wrong it will be in the un-itemized twelve.

**Update, 2026-07-29 — the enumeration is now SDK-checked, and the prediction above came true.**
Every domain below was censused against the `AppSchema` namespace in
`AppIntents-27.0-macos.swiftinterface`, counting the leaf accessors each domain's marker protocol
declares. The docs-derived enumeration is **confirmed for eighteen of the 23 domains and corrected
for five**: `clock` (14 intents / 3 entities / 3 enums — the docs pass missed the entire stopwatch
surface), `mail` (1 enum, `category`), `books` (10 enums, not 12), `presentation` (15 intents —
`addVideoToSlide` exists), and `system` (3 intents once `searchInApp` is counted). Corrections are
applied inline and in §5.4, each with its citation.

Two SDK facts the documentation pages do not carry, both ✅ **SDK-verified**:

- **Eight of the thirteen primary domains are new API surface at 27.0.** The `audio`, `calendar`,
  `clock`, `maps`, `messages`, `notes`, `phone` and `reminders` accessors are all
  `@available(anyAppleOS 27.0, *)` and none of them exists in the 26.5 interface; `mail`, `files`,
  `photos`, `camera`, `system` and the Shortcuts tier carry `@available(iOS 18.0, macOS 15.0,
  visionOS 2.0, *)`. Adopting a new-domain schema pins your deployment floor to the 27 releases;
  the 2024-era domains reach back to iOS 18 / macOS 15.
- **Every domain accessor checked is watchOS- and tvOS-unavailable.** The two single-purpose
  domains are narrower still: `.assistant` is `@available(iOS 26.2, *)` and unavailable on every
  other platform (`:12934-12940`), and `.visualIntelligence` is `@available(iOS 26.0,
  macOS 27.0, *)` with tvOS, watchOS and visionOS unavailable (`:13066-13071`).

Counts are exact at the row level: they count declared leaf schemas and exclude container/protocol
symbols such as `AppSchema.MailIntent`. **Deprecated schemas are included in the counts** and
marked. They remain macOS-surface counts — an iOS interface could conceivably differ.

---

### 5.1 Primary domains (13)

These reach Apple Intelligence, Siri and Shortcuts. If your app's core concept is here, this is
where the whole thing works.

---

#### `.audio` — 7 intents · 18 entities · 6 enums

**The largest entity surface of any domain**, by a factor of three.

*Intents:* `playAudio`, `addToLibrary`, `addToPlaylist`, `createStation`, `recognizeAudio`,
`updateAudioAffinity`, `warmupAudioQueue`

*Entities:* `album`, `algorithmicRadioStation`, `ambientSound`, `artist`, `audiobook`,
`classicalMusicRecording`, `liveRadioStation`, `newsBrief`, `newsProvider`, `playlist`,
`podcastCollection`, `podcastEpisode`, `podcastShow`, `radioShow`, `radioShowEpisode`, `song`,
`songCollection`, `warmupAudioQueueResult`

*Enums:* `activity`, `affinityState`, `appViewIdentifier`, `invocationSource`,
`playbackAttributes`, `queueInsertionLocation`

**What the shape tells you.** Eighteen entities for seven verbs is a domain built around
*naming things precisely* rather than doing many things. `classicalMusicRecording` as a distinct
entity from `song` is a strong signal about how much modelling effort went in — classical music
has works, movements, performers and conductors that a pop-song schema cannot express, and someone
decided that mattered.

`warmupAudioQueue` / `warmupAudioQueueResult` is a **latency-optimization pair with no analogue in
any other domain**. Nothing else in the 23 domains has a "get ready, I'm about to ask" verb. That
tells you where Apple thinks the volume is: "play X" is plausibly the highest-frequency Siri
request category there is, and shaving the warm-up off it was worth a dedicated schema.

Two `.audio` schemas appear in Apple's own code samples with their parameter lists, which is
unusually good evidence:

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 343 @ 5:05)
@AppIntent(schema: .audio.addToPlaylist)
struct AddToPlaylistIntent {

    var audioEntity: AudioEntity
    var playlist: PlaylistEntity

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        // Adds to playlist and shows dialog and snippet
        let view = PlaylistSnippetView(
            playlist: updatedEntity,
            tracks: updated.tracks
        )
        return .result(dialog: dialog, view: view)
    }
}
```

Note `audioEntity: AudioEntity` — session 343 describes `AudioEntity` as *"a `UnionValue` type that
includes both songs and playlists"* (✅ VERIFIED, transcript, 343). **A schema parameter can itself
be a union type.** That is worth internalizing before §13.4.

And `.audio.song` on the entity side:

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 343 @ 4:26)
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

---

#### `.calendar` — 3 intents · 3 entities · 4 enums

*Intents:* `createEvent`, `deleteEvent`, `updateEvent`
*Entities:* `attendee`, `calendar`, `event`
*Enums:* `attendeeStatus`, `attendeeType`, `eventSpan`, `eventStatus`

**Note the absence of any query or search intent.** Reading the calendar is not a schema action.
Three verbs, all mutations. If you want "when is my next meeting?" to work, that comes from
**entity resolution over the Spotlight index** (§10), not from an intent you adopt.

This is the general pattern across primary domains and it takes a moment to accept: **intents are
for changing things; questions are answered by entities.** Session 240's first example of the new
Siri is *"When and where is my next meeting?"* and it is answered by Siri *"understanding what a
meeting is in your app, which meeting is relevant, and which properties to return"* — no
`queryEvents` schema involved. ✅ **VERIFIED (transcript, 240)**.

`.calendar` is the best-documented domain in our corpus because session 344 builds it end to end.
Verified details from that build:

- **`.calendar.calendar`** entity — `id` set to `UUID` in the sample; `DisplayRepresentation` with
  a `calendar` SF Symbol; conforms to `IndexedEntity`.
- **`.calendar.attendee`** — modelled as a **`TransientAppEntity`** (§10.5), carrying an
  `IntentPerson`, a status enum, a type enum, and an `isOptional: Bool`.
- **`.calendar.event`** — composes a `CalendarEntity` and an array of `AttendeeEntity`; uses
  Foundation's **`Calendar.RecurrenceRule`**; and has **two union-typed properties**:

  | Property | Union members |
  |---|---|
  | `location` | **`PlaceDescriptor`** (GeoToolbox) **or `String`** |
  | alarms | **`Duration` or `Date`** |

  🟡 **RECONSTRUCTED** — these come from session 344's narration, which had no published code
  block. The member types are stated in words; the exact union type names shown on screen were
  rendered in our notes as `LocationUnion` / `AlarmUnion` and should be treated as provisional.
  The 27.0 interface was checked on 2026-07-29: no `LocationUnion` or `AlarmUnion` type exists in
  the module, which is consistent with these being **app-side `@UnionValue` declarations** whose
  names are the sample author's, not the SDK's. Name yours whatever you like.

- **`eventStatus`** appears in narration as `EventEntityStatus`. 🟡 The doc index says the enum
  schema is `.calendar.eventStatus`; the generated Swift type name in the sample was
  `EventEntityStatus`. Those are consistent — schema name versus your type's name — but do not
  assume the generated name.

---

#### `.camera` — 5 intents · 0 entities · 3 enums

*Intents:* `openInCaptureMode`, `setDevice`, `startCapture`, `stopCapture`, `switchDevice`
*Enums:* `captureDevice`, `captureDuration`, `captureMode`

**The only domain with zero entities.** A pure control surface: there is nothing to *reference*,
only things to *do*. That is the correct shape for a camera — a photo becomes referenceable the
moment it exists, and at that point it is a `.photos.asset`, not a camera object.

Practical consequence: `.camera` adoption requires no data modelling, no Spotlight indexing, and no
query protocol. It is the cheapest primary domain to adopt in the whole list. If you ship a camera
app, there is very little reason not to.

---

#### `.clock` — 14 intents · 3 entities · 3 enums

*Intents:* `createAlarm`, `updateAlarm`, `snoozeAlarm`, `dismissAlarm`, `deleteAlarm`,
`createTimer`, `updateTimer`, `pauseTimer`, `resumeTimer`, `cancelTimer`, `startStopwatch`,
`stopStopwatch`, `lapStopwatch`, `resetStopwatch`
*Entities:* `alarm`, `stopwatch`, `timer`
*Enums:* `alarmTriggerState`, `stopwatchState`, `timerState`

✅ **SDK-verified** (`AppIntents-27.0-macos.swiftinterface:12013-12166`) — and this is the largest
single correction the SDK pass makes to the docs-derived map. The domain pages gave `.clock` ten
verbs over two nouns; the interface adds a complete **stopwatch lifecycle** — four verbs, a
`stopwatch` entity and a `stopwatchState` enum — that appears on no documentation page in our
corpus.

Fourteen verbs over three nouns: full lifecycle control of alarms, timers and stopwatches, with
`snooze` and `dismiss` broken out as first-class actions rather than folded into `update`. That
split exists because they are the two things people say to a ringing alarm, and Siri needs them to
be distinct utterances mapping to distinct calls.

`.clock.createTimer`'s parameter list is verified from Apple's own code:

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 343 @ 3:42)
@AppIntent(schema: .clock.createTimer)
struct CreateTimerIntent {
    // MARK: Schema Parameters
    var duration: Duration
    var label: String?
    var isSleepTimer: Bool

    func perform() async throws -> some ReturnsValue<TimerEntity> {
        // Checks active timers and requests label parameter
        label = try await $label.requestValue(
            """
            You already have a timer running. \
            What should we call this one?
            """
        )
        return .result(value: timerEntity)
    }
}
```

Three things fall out of that block beyond `.clock`:

1. **`duration: Duration`** — a schema parameter typed as Swift's `Duration`. This corroborates
   session 345's claim that `Duration` is now a natively supported `@Parameter` type (§13.6).
2. **`$label.requestValue(_:)`** — the macro projects each parameter as `$name` and lets you ask a
   clarifying question mid-`perform` (§11.2).
3. **`some ReturnsValue<TimerEntity>`** — a return type composition worth noting: schema intents
   can return entities, not just `IntentResult`.

`.clock` also has a **special relationship with interaction donations**: the donation mechanism's
"ongoing activity" behaviour is scoped, by name, to stopwatch verbs in this domain and navigation
verbs in `.maps` — and the four stopwatch schemas above are exactly the verbs that scoping needs,
which is mutual corroboration. One wording mismatch to note: session 343's scoping quote says
*"stop, start, pause, or lap"*; the interface's fourth verb is `resetStopwatch`, and there is no
`pauseStopwatch`. See §12.1.

---

#### `.files` — 5 intents · 1 entity · 0 enums

*Intents:* `createFolder`, `deleteFiles`, `moveFiles`, `openFile`, `renameFile`
*Entities:* `file`

**Tiny domain, outsized importance.** `.files.file` is the schema that forum thread 838329 found to
be the *only* working route for handing an on-screen item to another app. The mechanism is
`FileEntityIdentifier` as the entity's identifier type plus `FileRepresentation` as the transfer
representation — and **neither of those is mentioned on the `.files` domain page.** That linkage
came entirely from the forum thread. It is a documentation gap worth knowing about, because
nothing on the domain page would lead you to the recipe.

The full recipe, its caveats, and why the obvious alternative silently fails are guide 03 in this
part. The one-line version, because it belongs in any map of this territory:

> **Community-verified**, thread 838329, confirmed on device on iOS 27: `@AppEntity(schema:
> .files.file)` + `FileEntityIdentifier.file(url:)` + `FileRepresentation` works for "send this
> to \<contact\>". Plain custom `AppEntity` + `Transferable` + `DataRepresentation` **never
> resolved** — `entities(for:)` was never called. **Caveat:** this verified `FileRepresentation`
> hand-off requires a real file payload, so transient renders must be written out before export.
> That is not an identity limitation: `FileEntityIdentifier.draft(identifier:)` can represent a
> document before it is materialized, but the draft deliberately has no `fileURL` to transfer.[^file-identifier-drafts]

---

#### `.mail` — 12 intents · 5 entities · 1 enum

*Intents:* `createDraft`, `updateDraft`, `saveDraft`, `openDraft`, `deleteDraft`, `sendDraft`,
`openMessage`, `replyMail`, `forwardMail`, `updateMail`, `archiveMail`, `deleteMail`
*Entities:* `account`, `draft`, `mailbox`, `message`, `thread`
*Enums:* `category`

✅ **SDK-verified**, with two facts the domain page misses: the enum `category` exists — and has
existed since the iOS 18-era surface (`AppIntents-27.0-macos.swiftinterface:12879-12888`) — and
`openDraft`, `openMessage` and the `thread` entity are `anyAppleOS 27.0` additions to an otherwise
iOS 18-era domain (`:12784-12796`).

**The reference model for what "complete" schema coverage looks like.** A clean two-phase CRUD
design: six verbs for the draft lifecycle, six for the message lifecycle, and the entity set covers
every noun a mail app has — including `account` and `mailbox`, which many apps would treat as
configuration rather than content.

The draft/message split is the same pattern as `.messages`' `draftMessage`/`sendMessage`
co-requisite (§3.3), and it is the strongest hint available about what the co-requisite graph looks
like elsewhere: **wherever a domain has both a "prepare" and a "commit" verb, assume they travel
together.** `.mail` has `createDraft` → `saveDraft` → `sendDraft` as an explicit chain, which is
exactly the shape a confirmation flow needs.

One enum — `category`, which the docs pass counted as zero. Mail otherwise has no closed
vocabularies: a mailbox is a name, not a case.

---

#### `.maps` — 6 intents · 6 entities · 7 enums

*Intents:* `startNavigation`, `stopNavigation`, `addNavigationWaypoints`, `shareETA`,
`stopShareETA`, `reportIncident`
*Entities:* `currentLocation`, `navigationSession`, `operatingHours`, `operatingTimeRange`,
`place`, `rating`
*Enums:* `amenity`, `incident`, `navigationPreferences`, `operatingStatus`, `priceRange`,
`ratingDescriptor`, `transportType`

**The most instructive domain in the whole list, because of what it lacks.**

`.maps` has `navigationSession` as an entity and `addNavigationWaypoints` as an intent. It has
`currentLocation`. It has a rich place model — `operatingHours`, `operatingTimeRange`, `rating`,
`priceRange`, `amenity` — clearly intended for "is it open?" and "is it any good?".

What it does **not** have is **any schema for querying progress**. There is no "how far have I
gone", no "how much elevation is left", no "what's my ETA to the next waypoint". Navigation can be
started, stopped and amended. It cannot be *interrogated*.

That gap is the direct structural cause of forum thread 837249: a hiking/cycling app wanting Siri
to answer, mid-activity, *"How much farther to the destination?"* and *"How far have I already
gone?"*. The developer built a custom `AppEntity` and an `EntityQuery`; Siri executed the query,
ignored the data, and read the visible on-screen text instead — *"Distance: 0.21 mi"*, *"Remaining
Distance: 0.14 mi"* — from the current tab only, unable to reach data on other tabs. **Zero
replies. Apple never answered.**

That developer had **no schema to adopt even if they had wanted to**: there is no fitness domain
(§6), and `.maps` covers starting and stopping navigation but not asking about it. §5.7 of the
research pass and §1 above explain the second half of the failure — those are *descriptive*
on-screen questions, which take the screenshot path and never consult entities. The entity plumbing
was built for a request class that does not use it.

`PlaceDescriptor` — from **GeoToolbox**, not App Intents — is the system's canonical "a place"
currency type. It shows up as a `.calendar.event` location union member (§5.1) *and* as the payload
you export to Maps via `ValueRepresentation` (§13.1). If you model places at all, model them as
`PlaceDescriptor`.

---

#### `.messages` — 5 intents · 4 entities · 5 enums

*Intents:* `draftMessage`, `sendMessage`, `editSentMessage`, `unsendMessage`,
`setMessageReadStatus`
*Entities:* `conversation`, `customAttachment`, `message`, `messagePerson`
*Enums:* `conversationAttribute`, `customReaction`, `messageAttribute`, `messageEffect`,
`messageType`

The domain with the **only verified co-requisite pair**: adopting `sendMessage` without
`draftMessage` is a build error (§3.3).

**`customAttachment` is the interesting entity.** It is what makes "send this to \<contact\>" able
to carry a payload rather than just text. If you are building a messaging app that handles anything
richer than strings, that is the noun to look at first.

`messagePerson` is a distinct entity from `.phone`'s `phonePerson` and from the system's
`IntentPerson` value type — three different person representations across the surface. 🔴 **GAP:**
we do not have the relationship between them documented. What would resolve it: the per-schema doc
pages. **Safe default:** where a schema names a person type, use the one the schema names, and use
`IntentPerson` for cross-app value transfer (§13.1) where no schema dictates otherwise.

An entity-level example from Apple's own code, notable because it is where indexing and schema
adoption meet in three lines:

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 240 @ 7:59)
// Contributing message content to Apple Intelligence

@AppEntity(schema: .messages.message)
struct MessageEntity: IndexedEntity {

    // The text content of the message
    @Property(indexingKey: \.textContent)
    var body: AttributedString?
}
```

---

#### `.notes` — 2 intents · 3 entities · 0 enums

*Intents:* `createNote`, `updateNote`
*Entities:* `account`, `folder`, `note`

> ✅ **VERIFIED (docs)** — *"Make your note-taking app's actions available to Apple Intelligence and
> Siri by adopting schemas for common note actions."*

**No `deleteNote`. No search.** Two verbs. Note that `.reminders` has a delete verb and `.calendar`
has one, so the omission here is a choice rather than a pattern.

`.notes` matters disproportionately because of a DTS answer in thread 829586: asked what to do
about **plain-text documents that fit no domain**, Apple's DTS engineer recommended
`@AppIntent(schema: .notes.createNote)`. That is an Apple-staff answer and it is worth taking
seriously as a precedent — **the schema whose *shape* fits your content may be a legitimate
adoption target even if the schema's *name* is not what you would have called your app.** A
document-capture app is not a note-taking app, but "create a thing containing text" is the same
contract.

That precedent has limits. It works because `createNote` genuinely describes the action. It would
not license adopting `.notes.createNote` for something that is not textual content creation.

---

#### `.phone` — 1 intent · 1 entity · 1 enum

*Intents:* `startCall`
*Entities:* `phonePerson`
*Enums:* `audioVisualMode`

> ✅ **VERIFIED (docs)** — *"Make your phone app's actions available to Apple Intelligence and Siri
> by adopting schemas for calling actions."*

**The smallest domain.** One verb, and the enum is presumably audio-vs-video. If you ship a VoIP
app, this is a single afternoon and it is the highest-leverage single schema in the list relative
to its size: "call \<person\>" is a request people already make constantly, and being the app that
answers it is worth more than most multi-schema adoptions.

---

#### `.photos` — 28 intents · 3 entities · 4 enums

**The largest intent surface of any domain, by more than double.**

*Intents:* `addAssetsToAlbum`, `cleanupPhoto`, `copyEdits`, `createAlbum`, `createAssets`, `crop`,
`deleteAlbum`, `deleteAssets`, `duplicateAssets`, `editAsset`, `openAlbum`, `openAsset`,
`pasteEdits`, `postToSharedAlbum`, `removeAssetsFromAlbum`, `setDepth`, `setExposure`, `setFilter`,
`setRotation`, `setSaturation`, `setWarmth`, `straighten`, `toggleDepth`, `toggleSuggestedEdits`,
`updateAlbum`, `updateAsset`, `updateRecognizedPerson`, `search` (**deprecated**)

*Entities:* `album`, `asset`, `recognizedPerson`
*Enums:* `albumType`, `assetType`, `filterType`, `rotationDirection`

**What 28 intents over 3 entities tells you: schemas can be extremely fine-grained inside a blessed
domain.** `setExposure`, `setWarmth`, `setSaturation`, `straighten`, `crop`, `setRotation`,
`setDepth` — these are individual slider adjustments, each with its own schema. There is no generic
`applyEdit(parameter:value:)`; there are seven separate verbs.

That granularity is what makes *"make this a bit warmer"* work without Siri having to know your
app's parameter names. It is also a warning about adoption cost: full `.photos` coverage is a
substantial project, and unlike `.messages` there is no evidence that these verbs come in
co-requisite sets, so **partial adoption looks viable here** — `crop` and `straighten` without
`setDepth` is a coherent app.

`.photos.asset` is the schema with the verified required-property list and the **`id: Int`**
constraint (§3.2). Plan for it.

`.photos.search` is **deprecated** — see §7.

---

#### `.reminders` — 8 intents · 5 entities · 2 enums

*Intents:* `createList`, `createReminder`, `createSection`, `deleteReminders`, `updateGroup`,
`updateList`, `updateReminder`, `updateSection`
*Entities:* `group`, `list`, `locationTrigger`, `reminder`, `section`
*Enums:* `listType`, `locationTriggerEvent`

A four-level containment model — `group` contains `list` contains `section` contains `reminder` —
which is more structure than most task apps have. If your app is flatter, §3.6's rule applies:
optional properties you do not use stay unset.

**`locationTrigger` + `locationTriggerEvent` is the entity worth noticing.** Geofenced reminders
are modelled as first-class schema content, which means "remind me to do X when I get to Y" can
route to your app. Very few app categories get that kind of proactive hook.

⚠️ Every `update*` verb in this domain — and there are four of them — is exposed to the
`valueState` bug class in §14.1. `.reminders` is the domain where "remove the due date" is a normal
thing to say, and where getting it wrong is silent.

---

#### `.system` — "System and in-app search" — 3 intents · 0 entities · 0 enums

*Intents:* `open`, `searchInApp`, `search` (**deprecated** — renamed; see §8)

> ✅ **VERIFIED (docs)** — the `.system` domain provides *"a structured representation for common
> search actions and content"* applicable to any app category that handles searching or opening
> content.

✅ **SDK-verified** (`AppIntents-27.0-macos.swiftinterface:13762-13797`) — and the doc-page lag
noted in §8.2 is now resolved from the SDK side: the interface declares all three, with `open` and
`searchInApp` on an `anyAppleOS 27.0` extension and the deprecated `search` on the iOS 18-era one.
The docs pass counted two because the domain page had not caught up.

**This is the domain that matters most to readers who found no other domain**, and it is the
smallest primary domain in the list. Two live verbs, both category-agnostic, both worth adopting
by nearly every app in existence — plus one deprecated name.

**`.system.open`** is the cheapest high-value schema in the entire enumeration and it fixes a
concrete, visible defect. Session 344's diagnostic story:

> ✅ **VERIFIED (transcript, WWDC26 344)** — *"tapping the event from my conversation with Siri
> **opens CometCal, but it just lands on the main screen. It doesn't navigate to the event** like I
> would expect. **Siri doesn't know how to open a specific event in the app yet.**"*

The fix is one small intent:

```swift prelude:guide-context
// 🟡 RECONSTRUCTED from WWDC26 344 narration — session 344 published no code block.
// Verified from narration: the parameter is named `target`; the schema is `.system.open`.
import AppIntents

@AppIntent(schema: .system.open)
struct OpenEventIntent {
    var target: EventEntity

    @Dependency var navigation: NavigationManager

    @MainActor
    func perform() async throws -> some IntentResult {
        navigation.navigate(to: target)
        return .result()
    }
}
```

> ✅ **VERIFIED (transcript, WWDC26 344)** — *"here's an **`OpenEventIntent`**. It's a small intent
> that conforms to the **`system.open`** schema. It **takes an `EventEntity` as its `target`** and
> tells the `NavigationManager` to navigate to that event. **The system calls this whenever someone
> taps an event result in Spotlight or Siri, or asks Siri to open one.**"*

**Three trigger surfaces for one small type:** a Spotlight result tap, a Siri result tap, and an
explicit "open X" request. Without it, every one of those dead-ends on your root screen — and the
user experiences that as your app being broken, not as a missing integration.

Put `.system.open` at the top of your adoption checklist regardless of what else you adopt. One
version note from the SDK pass: the `.system.open` dot-syntax accessor is `anyAppleOS 27.0` in the
interface — the 26.5 interface's `.system` domain has only `search` — so writing it takes the
Xcode 27 SDK even though the underlying open-intent machinery is older
(✅ `AppIntents-27.0-macos.swiftinterface:13783-13797`).

**`.system.search`** is the other half, and it is where the story gets interesting enough to
deserve its own section. It is deprecated *as a name*, not as a capability — it was **renamed** to
`.system.searchInApp`. See §7 for the deprecation set and §8 for the code.

---

### 5.2 Single-purpose domains (2)

Two domains, one intent each, and each one wired to exactly one system surface. Neither is what its
name suggests.

---

#### `.assistant` — 1 intent · ⚠️ **JAPAN ONLY**

*Intents:* `activate`

> ✅ **VERIFIED (docs)** — this schema *"registers your app as a side button action on iPhone. This
> schema is available only in Japan."* The related guide Apple links is *"Launching voice-based
> conversational app from the side button of iPhone."*

**Call this one out loudly because the name is a trap.** `.assistant` invites the assumption that
it is the general-purpose "make my app an assistant" hook — the thing every developer building a
conversational app goes looking for. It is not. It is a **regional side-button registration with
exactly one action**, available only in Japan.

If you are building a voice-based conversational app outside Japan and you were hoping this was
your route in: it is not, and there is no equivalent. Your options are §8's `.system.searchInApp`
and App Shortcuts.

---

#### `.visualIntelligence` — 1 intent

*Intents:* `semanticContentSearch`

> ✅ **VERIFIED (docs)** — the domain *"connects your app to the camera control"*, letting users
> *"point the camera at relevant content"* and get results from your app.

Adoption is a **three-part** requirement, not just a macro:

1. Apply the `semanticContentSearch` schema.
2. Implement an **`IntentValueQuery`** that receives Visual Intelligence types.
3. Match captured camera/screenshot content to your app's entities and return results.

✅ **VERIFIED (docs)**.

Step 2 is the notable one. **`IntentValueQuery` is the only place in the entire schema system where
your app receives *system-captured visual content* as input.** Everywhere else, the system hands
you identifiers or strings; here it hands you what the camera saw.

This is the closest existing analogue to what thread 838329's author wanted — a general "here is
some visual content, tell me what it is in your app" pipe — but it is **scoped to the camera
control surface**, not to arbitrary on-screen content. If your product need is "understand what is
on the user's screen", `.visualIntelligence` does not reach it.

🔴 **GAP — the Visual Intelligence input types.** The docs prose says the `IntentValueQuery`
*"receives Visual Intelligence types"* without naming them. We do not have the type list. What
would resolve it: the `.visualIntelligence` domain page's symbol table, or the Visual Intelligence
framework documentation. **Safe default:** write the query against whatever type Xcode's schema
snippet scaffolds; do not guess the type name from this guide.

---

### 5.3 Shortcuts-specific domains (8)

Per the index page's own grouping, these eight are **Shortcuts-specific** rather than Apple
Intelligence / Siri tier. Read §4's caveat before planning around them.

Structurally they are the most interesting part of the map, because they are where Apple modelled
*productivity software* — and the three iWork-shaped domains are near-isomorphic in a way that
tells you how Apple thinks about document apps.

---

#### `.books` — 9 intents · 3 entities · 10 enums

*Intents:* `navigatePage`, `openBook`, `updateCharacterSpacing`, `updateFontSize`,
`updateLineSpacing`, `updateSettings`, `updateWordSpacing`, `playAudiobook` (**deprecated**),
`search` (**deprecated**)
*Entities:* `audiobook`, `book`, `settings`
*Enums:* `contentType`, `font`, `fontSize`, `navigationDirection`, `pageNavigationSetting`,
`relativeCharacterSpacingChange`, `relativeFontChange`, `relativeLineSpacingChange`,
`relativeWordSpacingChange`, `theme`

**Ten enums for nine intents — the largest enum set of any domain in the map** (✅ SDK-verified,
`AppIntents-27.0-macos.swiftinterface:13522-13576`; the docs pass counted twelve, but its own name
list — reproduced above — always had ten, and ten is what the interface declares). Look at
the names: `relativeFontChange`, `relativeLineSpacingChange`, `relativeWordSpacingChange`,
`relativeCharacterSpacingChange`. Four separate closed vocabularies for "a bit bigger" / "a bit
smaller". That is what it takes to make *"make the text a little larger"* work reliably without
Siri needing to know your app's point sizes.

Two deprecations here, and the SDK settles what replaced them. `playAudiobook`'s deprecation
message in the interface is, verbatim, *"Use .audio.playAudio instead)"* — ✅ **SDK-verified**,
upgrading what this guide previously carried as a 🟡 inference from the entity overlap with
`.audio.audiobook`. `search` is part of the generic-search deprecation set (§7).

---

#### `.browser` — 13 intents · 5 entities · 1 enum

*Intents:* `bookmarkTab`, `bookmarkURL`, `clearHistory`, `closeTabs`, `closeWindows`, `createTab`,
`createWindow`, `deleteBookmarks`, `findOnPage`, `openBookmark`, `openURLInTab`, `switchTab`,
`search` (**deprecated**)
*Entities:* `bookmark`, `readingListItem`, `tab`, `tabGroup`, `window`
*Enums:* `clearHistoryTimeFrame`

A complete window/tab/bookmark model. Note that **`findOnPage` survived while `search` was
deprecated** — the pattern in §7 holds: *domain-specific* search verbs live; *generic* search verbs
died.

---

#### `.journal` — 5 intents · 1 entity · 0 enums

*Intents:* `createAudioEntry`, `createEntry`, `deleteEntry`, `updateEntry`, `search`
(**deprecated**)
*Entities:* `entry`

⚠️ **The naming mismatch again:** the symbol is `AppSchema.JournalIntent` (singular "Journal"), the
domain page is titled "Journaling" and lives at `app-schema-domain-journaling`, and the dot-syntax
is `.journal`. ✅ **VERIFIED (docs)**.

`createAudioEntry` as a distinct verb from `createEntry` is worth noting — a voice-first creation
path modelled explicitly.

---

#### `.presentation` — 15 intents · 3 entities · 0 enums

*Intents:* `addAudioToSlide`, `addCommentToSlide`, `addImageToSlide`, `addTextBoxToSlide`,
`addVideoToSlide`, `addWebVideoToSlide`, `create`, `createSlide`, `deleteSlide`, `open`,
`openSlide`, `setSlideTitle`, `startPlayback`, `stopPlayback`, `update`
*Entities:* `document`, `slide`, `template`

✅ **SDK-verified** (`AppIntents-27.0-macos.swiftinterface:16457-16536`). The docs pass counted
fourteen: `addVideoToSlide` — underlying name `AddVideoToPresentationSlideIntent` — is declared in
the interface (`:16505`), and was already present in the 26.5 SDK
(`AppIntents-26.5-macos.swiftinterface:5851`).

---

#### `.reader` — 9 intents · 2 entities · 1 enum

*Intents:* `deletePages`, `enhanceDocuments`, `insertPages`, `openDocument`, `openPage`,
`resizeDocuments`, `rotateDocuments`, `rotatePages`, `searchDocuments`
*Entities:* `document`, `page`
*Enums:* `documentKind`

**`.reader` keeps a live `searchDocuments`** while `.browser`, `.books`, `.journal` and `.system`
all had their generic `search` deprecated. That is the cleanest single piece of evidence for the
§7 thesis: the surviving search verbs are the domain-specific ones, and `searchDocuments` is
specific — it searches *documents*, a modelled noun, not "stuff".

`enhanceDocuments` and `resizeDocuments` mark this as a scanning/PDF domain rather than a
general reading domain.

---

#### `.spreadsheet` — 14 intents · 3 entities · 0 enums

*Intents:* `addAudioToSheet`, `addCommentToSheet`, `addImageToSheet`, `addTextBoxToSheet`,
`addVideoToSheet`, `addWebVideoToSheet`, `create`, `createSheet`, `delete`, `deleteSheet`, `open`,
`openSheet`, `update`, `updateSheet`
*Entities:* `document`, `sheet`, `template`

**Note what is absent: there is no cell, no formula, no range, no chart.** A spreadsheet schema
with no concept of a cell tells you exactly what tier it is aimed at — document-level automation in
Shortcuts, not "Siri, sum column B."

---

#### `.whiteboard` — 7 intents · 2 entities · 2 enums

*Intents:* `createBoard`, `createItem`, `deleteBoard`, `deleteItem`, `openBoard`, `updateBoard`,
`updateItem`
*Entities:* `board`, `item`
*Enums:* `color`, `itemType`

The most abstract domain in the list — `item` with an `itemType` enum is a deliberately open
container. If your app is a freeform canvas of any kind (mind maps, diagrams, sticky notes,
moodboards), this is the closest fit in the enumeration, and its abstraction is a feature.

---

#### `.wordProcessor` — 9 intents · 3 entities · 0 enums

*Intents:* `addAudioToPage`, `addImageToPage`, `addTextBoxToPage`, `addVideoToPage`,
`addWebVideoToPage`, `create`, `createPage`, `open`, `openPage`
*Entities:* `document`, `page`, `template`

---

#### The iWork isomorphism

The three productivity domains rhyme, deliberately:

| | `.presentation` | `.spreadsheet` | `.wordProcessor` |
|---|---|---|---|
| Container entity | `document` | `document` | `document` |
| Unit entity | `slide` | `sheet` | `page` |
| Template entity | `template` | `template` | `template` |
| Insertion verbs | `add{Audio,Comment,Image,TextBox,Video,WebVideo}ToSlide` | `add{Audio,Comment,Image,TextBox,Video,WebVideo}ToSheet` | `add{Audio,Image,TextBox,Video,WebVideo}ToPage` |
| Lifecycle | `create`/`open`/`update` + `create<Unit>`/`open<Unit>`/`delete<Unit>` | same | `create`/`open` + `createPage`/`openPage` |

✅ **VERIFIED (docs)**, updated against the SDK census — every cell above matches the 27.0
interface.

**Practical advice:** if you are building an iWork-class app, adopt all three in parallel. The
shapes are the same, your adapter code will be near-identical, and the marginal cost of the second
and third domains is a fraction of the first. Note the small asymmetries — only `.presentation`
and `.spreadsheet` have comment verbs; only `.presentation` has playback verbs and a unit-title
verb (`setSlideTitle`); `.wordProcessor` has no update or delete verbs at all. Do not assume
symmetry you have not checked. (An earlier revision of this guide reported `.presentation` lacking
a plain `addVideoToSlide`; the SDK interface has it — see the `.presentation` entry above.)

---

### 5.4 The whole surface, counted

| Tier | Domain | Intents | Entities | Enums |
|---|---|---:|---:|---:|
| Primary | `audio` | 7 | 18 | 6 |
| Primary | `calendar` | 3 | 3 | 4 |
| Primary | `camera` | 5 | 0 | 3 |
| Primary | `clock` | 14 | 3 | 3 |
| Primary | `files` | 5 | 1 | 0 |
| Primary | `mail` | 12 | 5 | 1 |
| Primary | `maps` | 6 | 6 | 7 |
| Primary | `messages` | 5 | 4 | 5 |
| Primary | `notes` | 2 | 3 | 0 |
| Primary | `phone` | 1 | 1 | 1 |
| Primary | `photos` | 28 | 3 | 4 |
| Primary | `reminders` | 8 | 5 | 2 |
| Primary | `system` | 3 | 0 | 0 |
| Single-purpose | `assistant` | 1 | 0 | 0 |
| Single-purpose | `visualIntelligence` | 1 | 0 | 0 |
| Shortcuts | `books` | 9 | 3 | 10 |
| Shortcuts | `browser` | 13 | 5 | 1 |
| Shortcuts | `journal` | 5 | 1 | 0 |
| Shortcuts | `presentation` | 15 | 3 | 0 |
| Shortcuts | `reader` | 9 | 2 | 1 |
| Shortcuts | `spreadsheet` | 14 | 3 | 0 |
| Shortcuts | `whiteboard` | 7 | 2 | 2 |
| Shortcuts | `wordProcessor` | 9 | 3 | 0 |
| | **Total** | **182** | **74** | **50** |

✅ **SDK-verified** for every row (`AppIntents-27.0-macos.swiftinterface`, `AppSchema` namespace,
censused 2026-07-29): the table counts the leaf schema accessors the 27.0 beta interface actually
declares, which supersedes the doc-page census this guide originally carried. The two censuses
agree for eighteen domains; the SDK corrects five (`clock` +4/+1/+1, `mail` +1 enum, `books`
−2 enums, `presentation` +1 intent, `system` +1 intent). Counts include deprecated schemas
(`search` ×5, `playAudiobook`), exclude container/protocol symbols (`AppSchema.MailIntent` and
friends), and are macOS-surface counts — an iOS interface could conceivably differ.

**Tier subtotals:** primary domains carry **99 intents, 52 entities, 36 enums**. Shortcuts-tier
domains carry **81 intents, 22 entities, 14 enums**. Single-purpose carries 2 intents.

That split is worth a moment. **Nearly half the intent surface — 81 of 182 — is in the tier that
the taxonomy places outside Siri.** If you counted "182 intents" and concluded the schema system
was broad, the number that actually governs un-app-qualified Siri routing is **99**, spread across
thirteen domains, of which one (`photos`) is 28.

---

## 6. The absences — what has no domain at all

**If you read one section of this guide, read this one.** For most apps this is the answer.

Here is the complete list of app categories with **no schema domain**, primary or otherwise:

- **Fitness and workouts** — no run, ride, session, workout, rep, set, split, pace or heart-rate
  schema. The `.maps` navigation entities are the nearest thing and they cannot be queried (§5.1).
- **Health** — no symptom, medication, dose, measurement, appointment or condition schema.
- **Finance and banking** — no account, transaction, transfer, balance, budget or invoice schema.
- **Shopping and commerce** — no product, cart, order, delivery, return or wishlist schema.
- **Travel and booking** — no flight, hotel, reservation, itinerary or boarding-pass schema.
- **Food ordering and recipes** — no dish, menu, order, ingredient or recipe schema.
- **Ride-hailing and transport** — no ride, trip, driver, fare or transit schema. (Navigation
  exists; *being driven* does not.)
- **Social feeds** — no post, feed, follow, like, comment or profile schema.
- **Education and learning** — no course, lesson, assignment, deck, card or quiz schema.
- **Developer tools** — no repository, build, issue, pull request or deployment schema.
- **Games** — nothing at all.
- **Smart home** — not absent so much as elsewhere: that surface lives in HomeKit, not App Intents
  schemas.

✅ **VERIFIED (docs)** as an *absence*: this list is derived by taking the complete 23-domain
enumeration from the index page and naming what is not in it. Absence claims are weaker than
presence claims — a domain could exist and be undocumented — but the index page is precisely the
page whose job is to enumerate domains, so its silence is meaningful. And as of 2026-07-29 the
absence is ✅ **SDK-corroborated**: the 27.0 beta interface's `AppSchema` namespace declares
exactly the 23 domains in §5.4 and no others — phrased carefully, none of the categories above is
present in the macOS 27.0 beta SDK interface.

### What this means concretely

If your app is in any of those categories:

1. **You have no primary schema domain to adopt.** There is therefore **no route to
   un-app-qualified Siri actionability** through the schema system for your app's core concepts.
2. **Your custom `AppEntity` types are still DISCOVERABLE.** Index them (`IndexedEntity` +
   `CSSearchableIndex.indexAppEntities(_:)`, guide 04) and Siri can find them, name them and
   surface them in Spotlight. That is real value and it is not gated on schemas.
3. **They are not ACTIONABLE.** Siri will not execute an action against them, and will not
   reliably move them across an app boundary. That is Apple's documented architecture (§2), not a
   defect.
4. **`.system.searchInApp` is your one reachable Siri hook** (§8). It works regardless of domain
   adoption and regardless of indexing. It navigates the user into your app's own search UI rather
   than answering in Siri's voice — but it is a supported, un-app-qualified Siri entry point, and
   for an uncovered category it is the only one.
5. **App Shortcuts remain fully open** (§1A), at the cost of the user naming your app.

### The two-sided honesty about this

**The optimistic side.** Look again at §5.1's `.notes` entry: Apple's own DTS engineer recommended
`.notes.createNote` for plain-text documents in an app that is not a note-taking app. Schemas
describe **shapes of actions**, not app categories. Before concluding you have no domain, check
whether one of the 13 primary domains describes a *shape* your app performs:

| Does your app… | Look at |
|---|---|
| create textual content? | `.notes.createNote` / `.notes.updateNote` |
| play any audio at all — podcasts, ambient sound, radio, lessons? | `.audio` (18 entities; `ambientSound`, `newsBrief` and `radioShow` are broader than they sound) |
| show places, or navigate? | `.maps` |
| produce or consume files? | `.files` (and this is the on-screen hand-off route) |
| set timers or alarms? | `.clock` (14 verbs including stopwatches; a workout interval timer *is* a timer) |
| let the user call someone? | `.phone` |
| capture from the camera? | `.camera` (zero entities — very cheap) |
| open a specific item? | **`.system.open` — adopt this regardless** |
| have any search UI at all? | **`.system.searchInApp` — adopt this regardless** |

A fitness app has timers, plays audio, shows places, and captures photos. None of those make it a
fitness domain, but each is a genuine Siri capability it can have today.

**The pessimistic side, which is also true.** None of that gives you the request the developer in
thread 837249 actually wanted: *"How much farther to the destination?"*, asked hands-free, mid-ride,
without naming the app. That request needs a schema for **querying activity progress**, and there
is not one. That developer's thread has **zero replies and no first-party answer**, and thread
829586 — with 14 replies and about a thousand views — records **FB23018652** being characterised by
DTS as an **enhancement request, not a bug**.

So the honest summary for an uncovered category is: **you can be found, you can be opened, you can
be searched, and you can be invoked by name. You cannot be acted on generically.** Design your
Siri story around the first four.

### One workaround, reported and untested

Thread 829586 records a proposed route that nobody in the thread confirmed working:

> **Community-proposed, UNTESTED** (thread 829586): expose custom entities via discoverability
> (indexing), build an in-app agent, and expose intents to Siri that *message that agent*,
> conforming to the **Messages** app schema domain.

We are recording it because it is in circulation, not because we recommend it. It routes a
general-purpose request through a schema whose contract is about sending messages between people.
🔴 **GAP:** whether Siri actually routes to it, and whether it survives review, is unverified.
**Safe default:** do not build on this. Use `.system.searchInApp` plus App Shortcuts, and file a
feedback referencing FB23018652 so the enhancement request accumulates weight.

---

## 7. Deprecations, and where generic search went

Five schemas are marked deprecated across the enumeration. Four of them are the same schema in
different domains.

| Deprecated schema | Domain | Tier | Replacement |
|---|---|---|---|
| `.system.search` | `system` | Primary | **Renamed `.system.searchInApp`** (§8) |
| `.browser.search` | `browser` | Shortcuts | Spotlight / `IndexedEntity`; `.system.searchInApp` |
| `.books.search` | `books` | Shortcuts | Spotlight / `IndexedEntity`; `.system.searchInApp` |
| `.journal.search` | `journal` | Shortcuts | Spotlight / `IndexedEntity`; `.system.searchInApp` |
| `.books.playAudiobook` | `books` | Shortcuts | `.audio.playAudio` — ✅ SDK deprecation message |

✅ **VERIFIED (docs)** for the deprecation marks themselves, and — as of 2026-08-23, against the
beta 5 recapture — ✅ **SDK-verified** for the whole replacement column: the 27.0 interface
attaches a message to each deprecated accessor. `.system.search` says *"Use .system.searchInApp
instead"* (`AppIntents-27.0-macos.swiftinterface:13776`), and beta 5 re-pointed the `photos`,
`browser`, `journal` and `books` `search` schemas at the terminal replacement directly — all four
now say *"Use .system.searchInApp instead"* (`AppIntents-27.0-macos.swiftinterface:11518`,
`:12421`, `:13332`, `:13412`), collapsing the two-hop chain (`search` → `.system.search` →
`.system.searchInApp`) the beta 4 capture documented; only the legacy `AssistantSchemas` `search`
accessors still point, with a straight face, at the deprecated `.system.search` (`:14307` et al.).
`.books.playAudiobook` says *"Use .audio.playAudio instead"*
(`AppIntents-27.0-macos.swiftinterface:13418`), confirming what this guide previously carried as a
🟡 inference. (Beta 5 also modernized the attribute form to `@available(anyAppleOS, deprecated:
27.0, …)` and dropped the stray `)` the beta 4 messages carried.)

Note also `.photos.search`, marked deprecated in the `.photos` enumeration (§5.1) — a sixth
instance of the same pattern.

### The thesis: generic search became infrastructure

The deprecation set is not random. Every deprecated search is a **generic** search — "search my
app for a string". Every *surviving* search verb is **domain-specific**: `.reader.searchDocuments`
lives, `.browser.findOnPage` lives.

Two things absorbed generic search:

**1. Spotlight and `IndexedEntity`.** Session 240's argument is that string-matching was never what
people wanted anyway:

> ✅ **VERIFIED (transcript, WWDC26 240)** — *"When someone says something like: **'The best
> windsurfing in Carmel'**, they're **not looking for an exact text match. They're expressing
> meaning.** To support that experience, Siri needs **more than string matching. It needs semantic
> search.** And that's exactly what `IndexedEntity` enables."*

And:

> ✅ **VERIFIED (transcript, WWDC26 240)** — *"**'Show the messages with Flare about movies'** —
> that's **not a string match**. Siri can find messages that reference movie titles because it's
> performing a **semantic query** over UnicornChat's indexed messages."*

A per-domain `search` intent cannot deliver that. It hands you a string; you do a `LIKE '%…%'`. The
semantic index does the meaning part *before* your app is involved, and returns entities.

**2. `.system.searchInApp`**, for the case where you want Siri's query string re-run inside **your**
search UI (§8).

### What to do if you have adopted a deprecated schema

- **`.system.search`** → **rename the schema reference.** This is the cheapest possible migration
  because it is a rename, not a replacement with new semantics (§8). Your `criteria:
  StringSearchCriteria` parameter and your `perform()` body are unchanged.
- **`.browser.search` / `.books.search` / `.journal.search`** → two moves, and you probably want
  both: adopt **`.system.searchInApp`** so the un-app-qualified Siri path still lands in your
  search UI, and adopt **`IndexedEntity` + `indexAppEntities`** so the content becomes findable
  semantically without an intent at all. Guide 04 covers the second.
- **`.books.playAudiobook`** → 🟡 look at `.audio.playAudio` with `.audio.audiobook` as the entity.
  Verify against the `.audio` domain page before committing; we have not confirmed the parameter
  mapping.

⚠️ **Deprecated does not mean removed.** These schemas are still in the enumeration and still
counted in §5.4 — and the 27.0 beta interface still declares every one of them, so they compile
with warnings today (✅ SDK, checked 2026-07-29). Nothing in our sources says when — or whether —
they stop compiling. 🔴 **GAP:**
no removal timeline is published in any source we read. **Safe default:** migrate at your
convenience, but do not assume a deprecated schema will keep working across two OS majors.

---

## 8. `.system.searchInApp` — the escape hatch

**This is the single most useful fact in this guide for anyone whose category is in §6.**

### 8.1 What it is, in Apple's words

> ✅ **VERIFIED (transcript, WWDC26 343 @ ~15:27)** — *"To do this, I'll adopt the system
> **`.searchInApp`** schema. **The `.system` search schema introduced in iOS 17 is now named
> `.system.searchInApp`.** It is part of the **System App Schema domain**, and it lets people search
> in your app with Siri, **no matter which other domains you adopt, and even if you don't index
> your entities**."*

Three separate facts in one sentence, and all three matter:

1. **The exact spelling is `.system.searchInApp`**, used as `@AppIntent(schema: .system.searchInApp)`.
2. **It is a RENAME, not a new schema.** The iOS 17 `.system` search schema *"is now named
   `.system.searchInApp`."* Same schema, new name — not a replacement with new semantics.
3. **It works regardless of domain adoption or entity indexing.** No prerequisite. This is the
   property that makes it the escape hatch.

### 8.2 Why we believe the rename claim

This one has unusually good evidence for a 2026 API name, so it is worth showing the chain:

- **Two independent renderings on the same page.** The sentence above is transcript prose. Apple
  *also* publishes a separate code-sample block on session 343's page, and it contains
  `@AppIntent(schema: .system.searchInApp)` at timestamp 14:49. Those are two different artifacts
  generated from the same session, and they agree.
- **Corroboration from an unrelated type's age.** The parameter type is `StringSearchCriteria`, and
  that type's documentation page gives its availability as **iOS 17.2+, iPadOS 17.2+, Mac Catalyst
  17.2+, macOS 14.2+, tvOS 17.2+, watchOS 10.2+** (visionOS listed with an undefined version). ✅
  **VERIFIED (docs)**, fetched from `/documentation/appintents/stringsearchcriteria`. **The type is
  old.** If `searchInApp` were a genuinely new 2026 schema you would expect a new criteria type.
  An iOS 17.2 parameter type on a schema Apple describes as "the iOS 17 search schema, renamed" is
  exactly what a rename looks like.
- **The doc-page lag.** The `.system` domain page still lists only `open` and `search`
  (deprecated), and does **not** list `searchInApp`. That is the one piece of counter-evidence, and
  the most likely explanation is documentation lag: the page title is *"System and in-app search"*,
  which corroborates that in-app search belongs there.

✅ **SDK-verified — the gap this box used to carry is closed.** The SDK interface dump this guide
asked for now exists, and it settles the spelling outright. The 27.0 interface declares, on
`extension AppSchema.SystemIntent` at `@available(anyAppleOS 27.0, *)`, the accessor
`var searchInApp` — underlying intent name `SystemSearchInAppIntent` — alongside `var open`
(`AppIntents-27.0-macos.swiftinterface:13783-13797`). The deprecated `var search` — underlying
name `ShowInAppSearchResultsIntent` — carries the SDK's own message: *"Use .system.searchInApp
instead"* (`:13774-13782`). That is the rename, stated by the compiler. The 26.5 interface has
only `search` (`AppIntents-26.5-macos.swiftinterface:5574-5582`), so the `searchInApp` *name*
requires the Xcode 27 SDK — while the underlying `ShowInAppSearchResultsIntent` protocol is
macOS 14.2 / iOS 17.2 (`AppIntents-27.0-macos.swiftinterface:809-810`), which squares with "the
iOS 17 search schema, renamed" exactly. The fallback advice stands: on an older SDK, write the
deprecated `.system.search`; it is the same schema.

### 8.3 The complete code

Apple's own sample first, verbatim:

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 343 @ 14:49)
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

Note Apple's own header comment: **"Intent that re-runs the Siri search in app."** That is the
mental model in six words. Siri hands you its own query string and gets out of the way.

Now a complete, compilable version for an app that has no schema domain — the hiking-app case from
thread 837249. The important dependency detail is to construct one `NavigationModel`, store that
object as the app's state, and register that exact object with `add(dependency:)`; `@Dependency`
then resolves the same instance instead of a separately constructed model.[^app-dependency-registration]

```swift prelude:guide-context
import AppIntents
import SwiftUI
import Observation

// MARK: - App-side navigation state
//
// Nothing App-Intents-specific here. This is just the object that owns
// "which tab is showing, and what is in the search field."

@MainActor
@Observable
final class NavigationModel {
    enum Tab: Hashable { case activity, routes, history, settings }

    var selectedTab: Tab = .activity
    var searchText: String = ""

    func showSearch(_ term: String) {
        searchText = term
        selectedTab = .routes
    }
}

// MARK: - Dependency registration
//
// @Dependency is how App Intents injects shared objects into intents and
// queries — "instead of creating new instances, it provides the same object
// I register once."  (✅ VERIFIED, transcript, WWDC26 344)

@main
@MainActor
struct TrailLogApp: App {
    @State private var navigation: NavigationModel

    init() {
        let navigation = NavigationModel()
        _navigation = State(initialValue: navigation)

        // Register the same instance supplied to RootView below.
        AppDependencyManager.shared.add(dependency: navigation)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(navigation)
        }
    }
}

// MARK: - The escape hatch itself

@AppIntent(schema: .system.searchInApp)
struct SearchTrailLogIntent {

    // Required by the schema. StringSearchCriteria is iOS 17.2+ / macOS 14.2+.
    var criteria: StringSearchCriteria

    @Dependency private var navigation: NavigationModel

    @MainActor
    func perform() async throws -> some IntentResult {
        navigation.showSearch(criteria.term)
        return .result()
    }
}
```

Three implementation notes on that listing:

- **`criteria.term`** — ✅ **VERIFIED (docs)**: *"The string value used for matching items in the
  application."* — and now ✅ **SDK-verified** (`AppIntents-27.0-macos.swiftinterface:792-808`):
  `public var term: String`, `init(term:)`, conformances `SearchCriteria`, `Sendable`, `Equatable`
  and `Hashable`, availability `macOS 14.2 / iOS 17.2 / watchOS 10.2 / tvOS 17.2` — the exact
  floor the docs page gave.
- **`@MainActor` on `perform()`** because it mutates UI state. Session 240 makes exactly this point
  about the Xcode-generated `draftMessage` stub: it *"needs to run on the main actor"* because it
  *"mutates UI state."* ✅ **VERIFIED (transcript, 240)**.
- **`AppDependencyManager.shared.add(dependency:)`** is Apple's documented registration spelling.
  The official sample constructs one navigation model, stores it for the app, registers that same
  value, and retrieves it from an intent with `@Dependency`; session 344 independently describes
  the same-instance contract.[^app-dependency-registration]

### 8.4 What it does and does not buy you

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"Siri calls this intent with **the same string it
> searched for**, and the intent's perform method **finds and shows those results in the app**."*

And the motivation, which is the answer to "why not just let Siri render results?":

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"Siri can display a list of entity search results.
> **That's a nice default. But I spent a lot of time crafting the app's own search experience, and
> I'd love to show these results there.**"*

So the honest ledger:

| It gives you | It does not give you |
|---|---|
| An un-app-qualified Siri entry point | An answer spoken in Siri's voice |
| Your own search UI, with your own ranking, filters and design | A result Siri can reason further about |
| Zero prerequisites — no domain adoption, no indexing | Anything hands-free (it navigates; the user must look) |
| A one-struct adoption | Any ability to *act* on the results |

**For an uncovered category (§6), this is the whole schema-tier story.** It is a navigation hook,
not an intelligence feature. That is a real limitation and you should scope product expectations to
it — but it is also a supported, first-party, un-app-qualified Siri entry point for an app that has
no other one, and there is nothing else in the enumeration that does that.

### 8.5 Adopt it even if you *do* have a domain

Note the phrasing again: *"no matter which other domains you adopt."* This is not an
either/or. A photos app that adopts twenty `.photos` schemas should still adopt
`.system.searchInApp`, because there will always be requests the fine-grained verbs do not cover,
and landing the user in your search UI with the right string in the field is a much better failure
mode than Siri shrugging.

Pair it with `.system.open` (§5.1). Together they are two small structs that fix the two most
visible dead-ends in any Siri integration: "I can't search your app" and "tapping the result does
nothing."

---

## 9. Decision tree: which route is open to you

Run this once, before writing any code. It takes ten minutes and it will save you either three
weeks or a wrong architecture.

```
START: What does my app's core experience DO?
│
├─ 1. Is that action in one of the 13 PRIMARY domains? (§5.1)
│     Check by SHAPE, not by app category (§6):
│     create text · play audio · navigate/show places · handle files ·
│     set timers/alarms · call people · capture from camera ·
│     send messages · manage mail · edit photos · manage reminders/calendar
│     │
│     ├─ YES → Adopt it.
│     │        • Type `<domain>_` in Xcode, read what the snippet requires (§3.4)
│     │        • Check the identifier type it forces on you (§3.2)
│     │        • Expect a co-requisite build error; adopt in pairs (§3.3)
│     │        • Add IndexedEntity + indexAppEntities so Siri can find operands (§10.1)
│     │        • Add .system.open and .system.searchInApp anyway (§8.5)
│     │        → FULL: un-app-qualified Siri, discovery AND action
│     │
│     └─ NO  → continue
│
├─ 2. Is it in one of the 8 SHORTCUTS-SPECIFIC domains? (§5.3)
│     books · browser · journal · presentation · reader ·
│     spreadsheet · whiteboard · wordProcessor
│     │
│     ├─ YES → Adopt it, but read §4 first.
│     │        The taxonomy places these OUTSIDE the Siri tier.
│     │        Plan the feature as Shortcuts automation, not as a Siri answer.
│     │        Still add .system.open + .system.searchInApp for the Siri path.
│     │        → PARTIAL: Shortcuts actions; Siri reach unverified
│     │
│     └─ NO  → continue
│
├─ 3. Do I connect to the camera control specifically? (§5.2)
│     └─ YES → .visualIntelligence.semanticContentSearch + IntentValueQuery
│              → NARROW: one surface, but a genuinely unique one
│
├─ 4. Am I a voice-conversational app shipping in Japan? (§5.2)
│     └─ YES → .assistant.activate — side-button registration
│              → NARROW and REGIONAL. Outside Japan: not available.
│
└─ 5. NONE OF THE ABOVE — the §6 case.
      │
      ├─ ALWAYS: .system.searchInApp        (§8) → un-app-qualified Siri entry
      ├─ ALWAYS: .system.open               (§5.1) → results become tappable
      ├─ ALWAYS: IndexedEntity + indexAppEntities (guide 04) → discovery
      ├─ ALWAYS: AppShortcutsProvider       (§1A) → voice, user names the app
      ├─ CONSIDER: RelevantEntities         (§13.3) → situational suggestions
      └─ FILE FEEDBACK referencing FB23018652        → the enhancement request
        → DISCOVERABLE + SEARCHABLE + OPENABLE + INVOCABLE-BY-NAME.
          NOT generically actionable. Scope the product to that.
```

### The four things everyone should adopt regardless of branch

This is the floor, and it is cheap:

| # | Adopt | Cost | What breaks without it |
|---|---|---|---|
| 1 | **`.system.open`** | one struct | Every Siri/Spotlight result tap dead-ends on your root screen |
| 2 | **`.system.searchInApp`** | one struct | No un-app-qualified Siri entry point at all |
| 3 | **`IndexedEntity` + `indexAppEntities`** | one protocol + index calls on create/update/delete | Siri cannot find your content to name it |
| 4 | **`AppShortcutsProvider`** | one type | No voice invocation of anything |

Numbers 1 and 2 are §5.1 and §8 of this guide. Number 3 is guide 04. Number 4 is ordinary App
Intents.

### The cost model, from Apple's own code-along

Worth quoting as a calibration point, because adoption cost is the thing people most often
overestimate. Session 344 built a calendar app's entire content layer — calendar, attendee and
event entities, indexed, with queries — and summarized it:

> ✅ **VERIFIED (transcript, WWDC26 344)** — *"**Not bad for three structs and filling out a few
> code snippets, right?**"*

and, on connecting on-screen content:

> ✅ **VERIFIED (transcript, WWDC26 344)** — *"**Seriously… two modifiers… that's all it takes** to
> connect what's on screen to the app's content."*

Treat that as the *best* case: a SwiftUI + SwiftData app, in a domain with complete schema
coverage, presented by the team that built the framework. Your mileage will vary most where the
schema dictates an identifier type your persistence layer does not already have (§3.2).

---

## 10. Query protocols and how entity resolution works

Adopting a schema makes an action executable. It does not make Siri able to find the *thing* to
execute it on. That is entity resolution, and it runs through a **query protocol**. Picking the
wrong one is one of the most common causes of "Siri can't find my stuff."

### 10.1 The five protocols

| Protocol | Input | Method | Use when |
|---|---|---|---|
| `EntityQuery` | `[ID]` | `entities(for:)` | **Baseline.** Resolve identifiers back to entities. Everything needs this. |
| `EntityStringQuery` | `String` | `entities(matching:)` | You **cannot index ahead of time**. You own the search logic. |
| `EnumerableEntityQuery` | — | `allEntities()` | The system needs to **offer your entities as choices** |
| `IndexedEntityQuery` | reindex requests | `reindexEntities(for:indexDescription:)`, `reindexAllEntities(indexDescription:)` | You use `IndexedEntity` and must service Spotlight reindex callbacks |
| `IntentValueQuery` | **structured system types** | `values(for:)` | Large / server-side / fast-changing data; Visual Intelligence input; resolving `IntentPerson` / `AudioSearch` |

✅ **VERIFIED (docs)** for the protocol names and the `IndexedEntityQuery` method signatures; ✅
**VERIFIED (Apple code sample)** for `EntityStringQuery` and `IntentValueQuery` shapes below; ✅
**VERIFIED (transcript, 344)** for `EnumerableEntityQuery`. As of 2026-07-29 all of them are also
✅ **SDK-verified**, with availability floors the docs pass could not supply
(`AppIntents-27.0-macos.swiftinterface`): `EntityQuery` macOS 13 / iOS 16 (`:4200`);
`EntityStringQuery` macOS 13 / iOS 16 (`:4229`); `EnumerableEntityQuery` macOS 14 / iOS 17
(`:4233`); `IndexedEntityQuery` macOS 27 / iOS 27 / visionOS 27 (`:4251`); and `IntentValueQuery`
at **`anyAppleOS 26.0`** — it is not new this year (`:4402`). A sixth, `UniqueAppEntityQuery`,
exists for singleton entities and predates this release — ✅ SDK-verified at macOS 15 / iOS 18,
requirement `func uniqueEntity() async throws` (`:2726-2729`).

### 10.2 `EntityQuery` versus `EnumerableEntityQuery` — a clean rule

Session 344 gives the distinction in one line, and it is the kind of rule you remember:

> ✅ **VERIFIED (transcript, WWDC26 344)** — *"`EntityQuery` covers cases where **the system already
> knows an entity's ID**. But later, when **creating events, the system will need to know which
> calendars are available so Siri can offer them as options**. For that, I'll conform to
> `EnumerableEntityQuery` and add an **`allEntities`** method."*

**`EntityQuery` = resolve by ID. `EnumerableEntityQuery` = offer as a choice.**

If any intent parameter is a small, bounded set the user might be asked to pick from — which
calendar, which account, which mailbox, which list — that entity needs `EnumerableEntityQuery`.
Without it, Siri has an intent it can run and no way to enumerate the options.

```swift prelude:guide-context
// 🟡 RECONSTRUCTED from WWDC26 344 narration (no published code block).
// The facts asserted — the two protocols, the two method names, @Dependency,
// and the @MainActor propagation — are all stated in narration.
import AppIntents

@MainActor
struct CalendarEntityQuery: EntityQuery, EnumerableEntityQuery {
    @Dependency var calendarManager: CalendarManager

    func entities(for identifiers: [UUID]) async throws -> [CalendarEntity] {
        // fetch by ID
    }

    func allEntities() async throws -> [CalendarEntity] {
        // every calendar the user has
    }
}
```

On the `@MainActor` there: session 344 notes *"The `CalendarManager` is main-actor isolated, so I'll
**also annotate the query struct as `@MainActor`**."* ✅ **VERIFIED (transcript, 344)**. Actor
isolation propagates from your data layer into your queries; plan for it rather than fighting it.

### 10.3 `EntityStringQuery` — the "I can't index" fallback

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 240 @ 8:36)
// An interface that locates entities using arbitrary string input

struct ContactQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [ContactEntity] {
        let predicate = #Predicate<Person> { person in
            person.name.localizedStandardContains(string)
        }
        let descriptor = FetchDescriptor<Person>(predicate: predicate)
        let matches = try modelContext.fetch(descriptor)
        return matches.map(\.entity)
    }
}
```

The trade-off, stated by Apple in one sentence — quote this when someone asks why they should
bother indexing:

> ✅ **VERIFIED (transcript, WWDC26 240)** — *"**You don't get semantic understanding, but you do
> get full control over how you search for and match your app's entities.**"*

### 10.4 When *not* to index — Apple's fixed formula

Three different sessions state the same test in near-identical words, which means it is the
official rule rather than one presenter's opinion:

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"you might **not** index your entities if your content
> dataset is **large, lives on a server, or changes too frequently** to index ahead of time. For
> example, I decided to index all the app's **playlists, but not songs**."*

Session 240 uses the same phrasing — *"Your dataset might be large, lives on a server, or changes
too frequently to index ahead of time"* — and session 345 repeats it again. ✅ **VERIFIED
(transcript, 240 and 345)**.

**The worked judgement is the useful part**: index playlists, not songs. Playlists are few, stable,
and user-named — exactly what semantic matching is good at. Songs are many, churn with the catalog,
and are better served by a structured query. That is a mixed strategy inside one app, and it is the
right shape for most media apps.

### 10.5 `IntentValueQuery` — structured search, and the only multi-type query

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"`IntentValueQuery` is suitable **if you don't index
> all your entities ahead of time**. This is very similar to `EntityQuery`. **The key differences
> are that your app receives a structured search input from the system, and you can return more
> than one entity type.**"*

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 343 @ 13:38)
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

**What each criteria case means**, from the narration — this is where the design intent lives:

| Case | Meaning | Example utterance |
|---|---|---|
| `.searchQuery(String)` | *"contains the **relevant part of what the person said**"* — Siri has already stripped the carrier phrase | "play something by Glow" |
| `.unspecified` | no specific target named; do something sensible | *"'Play CosmoTunes' which isn't specific about what I want to play. In that case, the app jumps straight into playing songs I've previously liked."* |
| `.url` | *"for when someone references a **link** from your app"* | *"Play that playlist Glow sent me."* |

✅ **VERIFIED (transcript, WWDC26 343)** for all three descriptions.

**`.unspecified` is the case most developers will forget**, and it is the one that handles the
most common utterance of all — the bare app name. Handle it with a sensible default rather than
returning empty.

⚠️ **Do not assume the input is scalar.** Session 343's input is a scalar `AudioSearch`. Session
240's is an **array**:

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 240 @ 19:21)
// Working across apps - IntentValueQuery

struct ContactEntityQuery: IntentValueQuery {

    func values(for input: [IntentPerson]) async throws -> [ContactEntity] {
        let names = input.map(\.displayName)
        let descriptor = FetchDescriptor<Contact>()
        let contacts = try model.mainContext.fetch(descriptor)
        let matches = contacts.filter { contact in
            names.contains(where: { name in
                contact.name.localizedStandardContains(name)
            })
        }
        return matches.map(\.entity)
    }
}
```

`values(for:)` is generic over the input type and **that type may itself be a collection** — ✅
**SDK-verified**: the protocol's requirement is `func values(for input: Self.Input) async throws
-> Self.Result` over an `Input : _IntentValue` associated type
(`AppIntents-27.0-macos.swiftinterface:4401-4412`), so any conforming input type, scalar or
collection, is admissible.

⚠️ **One doc-vs-SDK conflict inside session 240's sample.** Apple's published code maps
`input.map(\.displayName)` — but the macOS 27.0 interface's `IntentPerson` has **no `displayName`
property**. It has `var name: IntentPerson.Name`, an enum whose cases are `.displayName(String)`,
`.components(PersonNameComponents)` and `.unknown` (`:8245-8287`). Both facts stand — the sample
is Apple's, and the interface is what compiles on the Mac. Prefer the interface: read the name by
switching over `person.name`, and treat the sample's key path as iOS-surface convenience or
sample-code drift until a matching declaration shows up.

🔴 **GAP — the full input-type inventory.** Apple's own code comment says *"AudioSearch,
IntentPerson, **and other system types may be supported as input**"*, and the narration adds
*"Check out the documentation for the full set of `AudioSearch` criteria."* The 27.0 macOS
interface was checked on 2026-07-29 and narrows this without settling it: **`AudioSearch` is not
present in the macOS 27.0 beta AppIntents interface at all** — presumably an iOS-surface type —
so no criteria list can be read from the captures. We do not have either
list. What would resolve it: the `IntentValueQuery` documentation page and the `AudioSearch` page.
**Safe default:** implement `values(for:)` against the type Xcode's schema snippet gives you, and
`switch` exhaustively so a new criteria case is a compile error rather than a silent no-op.

### 10.6 `TransientAppEntity` — when a thing has no independent identity

Not a query protocol, but the decision that determines whether you need one at all.

> ✅ **VERIFIED (transcript, WWDC26 344)** — *"**A transient app entity is one that represents a
> temporary entity that doesn't require a unique identifier and isn't meant to be queried.** That's
> the right fit here. In CometCal, **an attendee represents a person's *participation in a specific
> event*, not the person themselves.** The same person can attend multiple events, and **indexing
> each attendance separately would create duplicative results in Spotlight**. Since attendees are
> always accessed **through the event that holds them**, there's **no need for an independent look
> up path**. `TransientAppEntity` makes that explicit… **no query to write, no index to
> maintain.**"*

**The decision rule, distilled: is this thing ever the *target* of a lookup, or is it only ever
reached *through* a parent?** Only-through-a-parent means `TransientAppEntity`.

✅ **SDK-verified** shape (`AppIntents-27.0-macos.swiftinterface:2688-2703`): `protocol
TransientAppEntity : AppEntity { init() }`, macOS 13.0 / iOS 16.0 — old API, not 2026 surface —
with a default `id: UUID` and a synthesized default query, which is the "no query to write"
promise made literal.

```swift illustrative
// 🟡 RECONSTRUCTED — session 344 published no code block.
@AppEntity
struct AttendeeEntity: TransientAppEntity {
    var person: IntentPerson
    var status: AttendeeStatus
    var type: AttendeeType
    var isOptional: Bool
}
```

⚠️ **This choice is not local.** See §14.4: a `TransientAppEntity` **cannot** be used with any of
the three entity-annotation surfaces (notifications, Now Playing, AlarmKit). Choosing transient for
good local reasons silently forecloses system integrations for that type.

---

## 11. Shaping the response: dialog, questions, and snippets

Once Siri can find your entity and run your intent, the remaining question is what the user hears
and sees. Session 343 is the source for all of this, and its framing is worth keeping:

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"Siri does the heavy lifting. It understands natural
> language, picks the right action, and crafts a helpful response. The App Intents framework gives
> you the tools to shape what Siri does, and **refine how it responds**."*

### 11.1 Custom dialog — and the `full:` / `supporting:` rule

The baseline is to return an empty `IntentResult`, which *"tells Siri to take care of the response
when the intent runs"* — Siri writes the sentence. ✅ **VERIFIED (transcript, 343)**.

To take it over, add `ProvidesDialog` and return an `IntentDialog` with **two** strings:

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 343 @ 2:42)
@AppIntent(schema: .audio.addToPlaylist)
struct AddToPlaylistIntent {

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Adds song to playlist and responds
        return .result(
            dialog: IntentDialog(
                full: """
                      Added \(song.title) to the \
                      \(playlist.title) mix tape.
                      """,
                supporting: "Added"
            )
        )
    }
}
```

**The rule governing the split is easy to get backwards**, so here it is verbatim:

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"Siri can show the **supporting** string with UI, and
> read the **full** dialog on voice-only devices like AirPods. **Because of this, the full string
> should describe what happened on its own.**"*

- **`supporting:`** is the caption that sits next to a visual. It can be terse — "Added" — because
  the visual carries the rest.
- **`full:`** must be **self-sufficient audio**. Someone with AirPods in and a phone in their
  pocket hears only this. "Added" is a failure; "Added Aurora to the Late Nights mix tape" is not.

✅ **SDK-verified** (`AppIntents-27.0-macos.swiftinterface:4447-4454`):
`IntentDialog(full:supporting:)` is macOS 13.0 / iOS 16.0, with `(full:systemImageName:)` and
`(full:supporting:systemImageName:)` overloads at macOS 14.2 / iOS 17.2. The two-string split is
not new API — just newly explained.

The presenter's stated motivation for customizing at all is brand vocabulary: *"I call songs
**tracks** and playlists **mix tapes**."* ✅ **VERIFIED (transcript, 343)**. That is the honest
reason to do this — not to be clever, but because Siri's generic phrasing will call your objects
by the wrong nouns.

### 11.2 Asking a question mid-`perform` — `requestValue`

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"But what if you want to ask people a question **while
> your intent is running**? A well-placed clarifying question lets people finish the action they
> meant to take. To ask a question **before your intent result**, use a dialog request within your
> perform method."*

The mechanism is the parameter projection. The `@AppIntent` macro exposes each parameter as
`$name`, and `$name.requestValue(_:)` is an `async throws` call that returns the resolved value:

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 343 @ 3:42)
@AppIntent(schema: .clock.createTimer)
struct CreateTimerIntent {
    // MARK: Schema Parameters
    var duration: Duration
    var label: String?
    var isSleepTimer: Bool

    func perform() async throws -> some ReturnsValue<TimerEntity> {
        // Checks active timers and requests label parameter
        label = try await $label.requestValue(
            """
            You already have a timer running. \
            What should we call this one?
            """
        )
        return .result(value: timerEntity)
    }
}
```

Note that this is **conditional**: the question is asked only because another timer is already
running. That is the pattern — inspect state, ask only when the answer is genuinely ambiguous.

Apple's own restraint advice, which belongs next to the API rather than in a design appendix:

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"Remember to **ask clarifying questions sparingly to
> avoid friction**."*

✅ **SDK-verified — the "other kinds" now have names.** Session 343 says: *"If you want to ask
people to **choose from a list of items**, or ask for a **confirmation**, check out the sample app
and documentation to learn about other kinds of dialog requests"* — and left the symbols unnamed,
which this guide previously carried as a 🔴 GAP. The 27.0 interface declares all three on
`IntentParameter`, macOS 13.0 / iOS 16.0 (`AppIntents-27.0-macos.swiftinterface:4367-4369`):

```swift prelude:guide-context
final public func requestValue(_ dialog: IntentDialog? = nil) async throws -> Value.ValueType
final public func requestDisambiguation(among itemsToDisambiguate: [Value.ValueType], dialog: IntentDialog? = nil) async throws -> Value.ValueType
final public func requestConfirmation(for itemToConfirm: Value.ValueType, dialog: IntentDialog? = nil) async throws -> Bool
```

`$parameter.requestDisambiguation(among:dialog:)` is "choose from a list";
`$parameter.requestConfirmation(for:dialog:)` is the confirmation. (This closes former register
entry G15, §16.)

### 11.3 `DisplayRepresentation` — the highest-leverage thing you can customize

This is the item Apple puts **first** in its own recommended adoption order, and the reason is that
it is consumed by more subsystems than anything else you write.

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"Entity display representation can be used in
> **responses**, like when an entity has been created or updated. They are also used when **asking
> someone to choose between similar entities**, or when **answering questions about content in your
> app**. **Spotlight and Shortcuts** can use them, too."*

Counting the consumers named across session 343: responses, disambiguation, question-answering,
Spotlight, Shortcuts — plus **intent confirmations** (§12.2) and the **on-screen-awareness fast
path** (§14.3). That is seven surfaces fed by one property.

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 343 @ 4:26)
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

`DisplayRepresentation(title:subtitle:image:)` — the title is a `LocalizedStringResource`-style
interpolation; subtitle and image are the enrichment. Session 344's calendar variant uses
`DisplayRepresentation(title:image:)` with an SF Symbol — the same initializer with `subtitle:`
defaulted. ✅ **SDK-verified** (`AppIntents-27.0-macos.swiftinterface:3844-3859`): the overload
set is `init(title:subtitle:image:)` (macOS 13 / iOS 16, subtitle and image defaulted),
`init(title:subtitle:image:synonyms:)` (macOS 14 / iOS 17), and a 27.0 overload taking an async
image closure. `image:` is a nested `DisplayRepresentation.Image`, built with `init(named:)`,
`init(systemName:)`, `init(data:)` or `init(url:)`.

### 11.4 ⚠️ `SnippetIntent` is an iOS 26 feature — not new this year

This correction matters because `SnippetIntent` is routinely described in 2026 write-ups as part of
the new Siri work. It is not.

> ✅ **VERIFIED (docs)** — `/documentation/appintents/snippetintent` gives availability as
> **iOS 26.0+ / macOS 26.0+ / watchOS 26.0+ / visionOS 26.0+ / tvOS 26.0+**, and the App Intents
> updates page lists it under **June 2025**.

```swift illustrative
// ✅ VERIFIED (docs) — the declaration as published
protocol SnippetIntent : AppIntent where Self.PerformResult : ShowsSnippetView
```

✅ **SDK-verified** — the interface carries the identical declaration at
`@available(anyAppleOS 26.0, *)` (`AppIntents-27.0-macos.swiftinterface:3662-3667`), plus a
`static func reload()` and the `EmptySnippetIntent` default type (`:3668-3689`). The 26.0 floor is
compiler-attested, not just documented.

It is **prior art that the 2026 Siri work builds on**, not part of this release. If you are writing
a migration plan from iOS 26, `SnippetIntent` is not on it — you may already have it.

Purpose, ✅ **VERIFIED (docs)**: display *"custom SwiftUI views to show people the result of their
action, confirm a selection, and more."* Snippets support **interactive** elements — buttons and
toggles that trigger further app intents.

**Two behaviours that bite**, both ✅ **VERIFIED (docs)**:

1. **The system can call a `SnippetIntent` multiple times.** Your `perform()` must re-fetch current
   state on each call so the view reflects user interaction. **Do not cache.** This is a real
   correctness trap: a snippet that caches its data will show stale state after the user taps one
   of its own buttons.
2. **Snippet-only intents are non-discoverable by default.** Set `isDiscoverable = true` to surface
   them in Shortcuts or Spotlight.

Related symbols: **`ShowsSnippetView`** (the result conformance) and **`EmptySnippetIntent`** (a
default empty implementation).

### 11.5 The other route: a snippet view straight from a schema intent

You do not need `SnippetIntent` to show a custom view. A schema intent can return one directly by
composing `ShowsSnippetView` into its result type:

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 343 @ 5:05)
@AppIntent(schema: .audio.addToPlaylist)
struct AddToPlaylistIntent {

    var audioEntity: AudioEntity
    var playlist: PlaylistEntity

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        // Adds to playlist and shows dialog and snippet
        let view = PlaylistSnippetView(
            playlist: updatedEntity,
            tracks: updated.tracks
        )
        return .result(dialog: dialog, view: view)
    }
}
```

The composition is `some IntentResult & ProvidesDialog & ShowsSnippetView` with the matching
`.result(dialog:view:)` factory.

**When you get one for free:** session 344 notes that *"By default, **Siri builds the result card
from the display representation**. Snippet views let me replace that with a custom SwiftUI view."*
✅ **VERIFIED (transcript, 344)**. So the ladder is: do nothing → Siri renders your
`DisplayRepresentation`; add `ShowsSnippetView` → you render.

Design advice from the same session, and it is good: *"You can get really creative here… **but also
remember to keep it simple and lightweight.**"* ✅ **VERIFIED (transcript, 344)**.

### 11.6 Apple's own "don't" list

Rare enough to be worth reproducing in full, because negative guidance is scarce in this area:

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"When approaching customization, **test your intents
> and decide where customization actually makes sense for your app**. Make sure your responses are
> accurate and **sound natural across all platforms, including voice-only devices like AirPods**.
> Remember to **ask clarifying questions sparingly to avoid friction**. Finally, use custom visuals
> to bring your app's identity to Siri, **keeping in mind how they'll scale across the
> ecosystem**."*

Four rules, and the second and fourth are the ones people violate: a response written for a phone
screen read aloud on AirPods, and a snippet designed for an iPhone rendered on a Watch.

---

## 12. Donations, confirmations, and entity ownership

### 12.1 Interaction donations — teaching Siri what happens in your UI

The boundary is precise, and stating it correctly prevents both under- and over-donating:

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"When people interact with your app **through Siri or
> Shortcuts, the system already knows about it**. But, Apple Intelligence **can't learn from actions
> people take through your app's UI** without your help. That's where donations come in."*

The mechanism:

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"Each donation is a hint that a person took a specific
> action in your app's UI. The system stores these as **schema-conforming App Intents in a temporary
> transcript**, giving Siri the context it needs to make smarter decisions."*

Note "**schema-conforming**". Donations are expressed in the schema vocabulary — which is another
way in which the schema tier is the price of admission.

**Two distinct payoffs**, both named:

1. **Preference learning and app disambiguation.** *"After messaging them frequently in the app,
   eventually, when someone says: 'Send a message to a contact from the Home Screen,' Siri might
   **infer the right app** to use for that contact."*
2. **Live-activity awareness.** *"Interaction Donations also keep Siri aware of **ongoing
   activities** in your app."* The example: a `NavigationSession` started in the app's UI is
   donated; the user then asks Siri to add a stop, and *"Thanks to the Interaction Donation, Siri
   can know **what NavigationSession is active** in the app."*

✅ **VERIFIED (transcript, 343)** for both.

⚠️ **Payoff 2 is explicitly scoped — it is a hard limit, not a general capability:**

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"This pattern applies to intents that **start or stop
> NavigationSessions in the Maps domain**, and **stop, start, pause, or lap stopwatches in the Clock
> domain**."*

Two domains. Navigation sessions and stopwatches. If you were hoping to donate "a workout is in
progress" or "a document is open" and have Siri reason about it, that is not what this does.

```swift illustrative
// ✅ VERIFIED (Apple code sample, WWDC26 343 @ 7:44)
@ModelActor
actor ModelManager {
    func sendMessage(_ /* ... */, donateIntent: Bool = false) async throws -> [Message.ID] {

        // Donate intent with parameters and result so Siri can learn user preferences
        if donateIntent {
            let intent = SendMessageIntent()
            intent.destination = .recipients(conversation.recipients.map(\.entity))

            let result = messages.map(\.entity)
            Task {
                try await IntentDonationManager.shared.donate(
                    intent: intent,
                    result: .result(value: result)
                )
            }
        }
    }
}
```

**API:** `IntentDonationManager.shared.donate(intent:result:)`, `async throws`. The result is passed
as `.result(value:)` — **you donate the outcome, not just the invocation.**

**The pattern worth copying** is the `donateIntent: Bool = false` flag. One shared helper serves
both the UI path and the intent path, and only the UI call site passes `true`. The rationale,
verbatim: *"Apple Intelligence **already learns from Siri interactions**, so I only need to donate
**UI** interactions."* ✅ **VERIFIED (transcript, 343)**.

Getting this wrong double-counts: donate from inside `perform()` and every Siri-originated action
is recorded twice.

### 12.2 Confirmations and `OwnershipProvidingEntity`

The security framing is unusually direct about *why* this exists:

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"Asking people to confirm that the action looks right
> keeps them informed and protects them from **unintended side effects, which are a known risk with
> Large Language Models**."*

And the default policy, which is the part that should make you sit up:

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"**By default, Siri assumes your entities are private
> to the person, and may skip confirmations for them.**"*

**The absence of the protocol is a decision, not a neutral default.** If your entities can be
shared or made public and you do not say so, Siri may act on them without asking.

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 343 @ 10:03)
// Informs system if entity is public or shared with others
@AppEntity(schema: .calendar.event)
struct EventEntity: OwnershipProvidingEntity {

    var ownership: EntityOwnership {
        // isShared used to compute ownership state: .shared, .public, or .unknown
        attendees.isEmpty ? .unknown : .shared
    }
}
```

**Confirmed API:**
- protocol **`OwnershipProvidingEntity`**
- requirement **`var ownership: EntityOwnership`**
- **`EntityOwnership`** members named in Apple's own code comment: **`.shared`**, **`.public`**,
  **`.unknown`**

✅ **SDK-verified** (`AppIntents-27.0-macos.swiftinterface:10651-10668`, `anyAppleOS 27.0`):
`protocol OwnershipProvidingEntity : AppEntity` with exactly that requirement. One shape
correction to the sample's comment: `EntityOwnership` is an **`OptionSet`**, not an enum — static
members `.unknown`, `.shared` and `.public` — and **no `.private` member exists in the 27.0
interface**. "Private" is the *implicit* default when you do not adopt the protocol, exactly as
the research pass recorded; `.unknown` is the spelling for "I cannot say". (This closes former
register entry G17, §16.)

Two scoping rules, both explicit:

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"**Only add the protocol to entities that people can
> share or make public in your app.** Then, provide the ownership state. **Keep the ownership state
> up to date whenever the system requests an entity from your app.** This ensures Siri has the
> necessary information when deciding to confirm."*

The worked example of the resulting policy: *"Siri may **not** confirm when I update a personal
event, but it **may** confirm when I ask it to update Crew Lunch since I'm updating an event **with
attendees**."* ✅ **VERIFIED (transcript, 343)**. And confirmations reuse your
`DisplayRepresentation` as their visual — the seventh consumer from §11.3.

Note the second rule carefully: ownership is computed **every time the system requests the entity**,
not once at creation. In the sample it is a computed property over `attendees`, which is exactly
right. A stored `let ownership` set at init would go stale the moment someone shares the event.

### 12.3 Where confirmations come for free

Not everything needs `OwnershipProvidingEntity`. Session 344 notes that for a delete intent —
parameters being just the event and an optional `span` for recurring events — *"**Siri
automatically handles the confirmation dialog before anything is removed.**"* ✅ **VERIFIED
(transcript, 344)**. The same demo shows Siri *"makes sure to disambiguate when more than one event
matches."*

So destructive schema verbs get confirmation behaviour from the schema itself. What
`OwnershipProvidingEntity` adds is the *sharing* dimension that the schema cannot infer.

---

## 13. The new execution model

Everything in this section is **new in the 27 releases** and comes from WWDC26 session 345, which
refers to them as *"our 2027 releases"* — see the version-floor box at the top of this guide before
reading anything into that phrasing.

Session 345 is the one that is *not* Siri-specific. Sessions 240, 343 and 344 are about making Siri
understand your app; 345 is about the App Intents framework as an execution substrate — process
selection, background execution, parameter resolution cost, cross-app value transfer. Much of it
applies whether or not you ever adopt a schema.

⚠️ **Session 345 explicitly does not cover** `UndoableIntent`, `IntentModes` or `SnippetIntent`,
despite the first two appearing on the App Intents updates page. The SDK pass now supplies the
first two's shapes, which is enough to plan against but no substitute for usage guidance —
✅ **SDK-verified**: `UndoableIntent : SystemIntent` with a `@MainActor var undoManager:
UndoManager?`, `anyAppleOS 26.0` (`AppIntents-27.0-macos.swiftinterface:3707-3716`); and
`IntentModes`, an `OptionSet` — `.background`, `.foreground`, `.foreground(.immediate)` /
`(.deferred)` / `(.dynamic)` — consumed by `static var supportedModes` on `AppIntent`,
`anyAppleOS 26.0` (`:3106-3107`, `:3250-3277`). 🔴 **GAP:** neither has session coverage or a
usage example in our corpus, and `SnippetIntent` aside (§11.4), the *semantics* remain
undocumented here. **Safe default:** the shapes above are compiler-truth; do not design around
them from the shape alone.

### 13.1 `ValueRepresentation` — sharing structured types across apps

The problem is stated precisely, and it is a real hole in `Transferable`:

> ✅ **VERIFIED (transcript, WWDC26 345)** — *"Maps needs some **structured information** — a
> coordinate, an address, or something it can navigate to. But that kind of data **doesn't have an
> associated data format that can be put in a file or data**. The existing **file and data
> representations** work great for known formats like PDFs or images — **but not for structured
> types that don't have any**."*

> ✅ **VERIFIED (transcript, WWDC26 345)** — *"This is where **`ValueRepresentation`** comes in. It's
> a new representation type that lets you share **structured types that the system already
> understands**."*

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 345 @ 0:01)
struct LandmarkEntity: AppEntity, Transferable {
    var id: Int
    var landmark: Landmark  // contains CLLocationCoordinate2D

    static var transferRepresentation: some TransferRepresentation {
        ValueRepresentation(
            exporting: { entity in
                PlaceDescriptor(
                    representations: [.coordinate(entity.landmark.locationCoordinate)],
                    commonName: entity.landmark.name
                )
            }
        )
    }
}

// If the entity already has a PlaceDescriptor property, use a key-path — much less code:
struct LandmarkEntity: AppEntity, Transferable {
    var id: Int
    @Property var placeDescriptor: PlaceDescriptor

    static var transferRepresentation: some TransferRepresentation {
        ValueRepresentation(exporting: \.placeDescriptor)
    }
}
```

**Confirmed API:**
- `ValueRepresentation(exporting:)` writable two ways — a closure form and a **key-path form**
  (per the SDK, one closure-form initialiser that key-path literals convert into; see the
  resolution box below).
- It **composes**: *"I just need to add a `ValueRepresentation` **alongside any existing
  representations**."* ✅ VERIFIED (transcript, 345). Your `FileRepresentation` and
  `DataRepresentation` stay.
- `PlaceDescriptor(representations:commonName:)` comes from **GeoToolbox**, with
  `.coordinate(CLLocationCoordinate2D)` as a representation case.

Apple's own recommendation: *"If my entity already has a `PlaceDescriptor` `@Property`, I can **skip
the closure entirely and use a key-path**. Same result, much less code."* ✅ VERIFIED (transcript,
345).

#### ✅ `ValueRepresentation` versus `IntentValueRepresentation` — resolved: they are one type

**This was this guide's flagged naming hazard, and the SDK pass settles it.**

Session 240 uses **`IntentValueRepresentation`** for what looks like the same job — exporting a
`ContactEntity` as an `IntentPerson`:

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 240 @ 18:18)
// Working across apps - Exporting content to another app

extension ContactEntity: Transferable {

    static var transferRepresentation: some TransferRepresentation {
        IntentValueRepresentation(
            exporting: \.person
        )
    }
}
```

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 240 @ 20:00)
// Working across apps - IntentValueRepresentation

extension ContactEntity: Transferable {

    static var transferRepresentation: some TransferRepresentation {
        IntentValueRepresentation(exporting: \.person, importing: { intentPerson in
            let contact = Contact(importing: intentPerson)
            ContactManager.shared.contacts.append(contact)
            return contact.entity
        })
    }
}
```

Session 345 uses **`ValueRepresentation(exporting:)`**. Both appear in **Apple's own published code
samples**, so neither is a transcription artifact.

✅ **SDK-verified — same type.** The SDK interface dump this guide asked for now exists, and the
answer is (b), an alias:

```swift illustrative
// ✅ SDK-verified (AppIntents-27.0-macos.swiftinterface:2629-2650)
extension AppEntity {
    public typealias ValueRepresentation = IntentValueRepresentation
}

public struct IntentValueRepresentation<Item, IntentValue> : TransferRepresentation
    where Item : Transferable, IntentValue : _IntentValue, IntentValue : Sendable {
    // init(exporting:) and init(exporting:importing:), constrained to system intent
    // values — with a dedicated extension for IntentValue == IntentPerson
}
```

That also explains each session's spelling: session 345 writes `ValueRepresentation` *inside an
entity declaration*, where the `AppEntity`-scoped typealias resolves; session 240 writes the
underlying name, which works anywhere. They cannot diverge — port code freely between the two
spellings, remembering only that the short one resolves inside `AppEntity`-conforming scope. The
key-path call sites (`exporting: \.person`) compile against the closure-form initialisers via
Swift's key-path-as-function conversion; there is no separate key-path overload in the interface.

⚠️ **One availability surprise:** the interface annotates the whole cluster
`@available(anyAppleOS 26.4, *)` — not 27.0 — yet none of it appears in this repo's 26.5
interface capture. Treat the 27.0 SDK's annotation as the deployment floor Xcode 27 will enforce,
and treat "new in the 27 releases" as true of the SDK that declares it rather than of the
availability number it carries. (This closes former register entry G4, §16.)

#### The import decision, which is genuinely crisp

Independent of the naming question, session 240 gives a clean rule for the *receiving* side:

> ✅ **VERIFIED (transcript, WWDC26 240)** — *"When content comes into your app, there are usually
> **two possibilities**. Either that content **refers to something that already exists**, or it
> **represents something entirely new**. **You get to decide which path your app takes. If you're
> matching existing content, use `IntentValueQuery`. If you're creating something new, use
> `importing` on the `transferRepresentation`.**"*

| Incoming content | Mechanism |
|---|---|
| refers to something you already have | **`IntentValueQuery`** (§10.5) |
| represents something new | **`importing:`** on the transfer representation |

And: *"**Many apps use both**, depending on the intent and workflow."* ✅ VERIFIED (transcript,
240). `exporting:` alone means resolve-or-nothing; adding `importing:` means the receiving app
**creates** something.

The framing that makes the whole design click:

> ✅ **VERIFIED (transcript, WWDC26 240)** — *"**Your app doesn't need to know what happens next. It
> just needs to describe its content accurately.**"*

### 13.2 The three discovery mechanisms — and where `RelevantEntities` fits

Session 345 argues for a third mechanism by showing what the first two cannot do:

> ✅ **VERIFIED (transcript, WWDC26 345)** — *"But what about that new playlist? **Nobody's searched
> for it in Spotlight since they don't know it exists.** And since **nobody's played it, there's no
> interaction to donate** either. You need a way to tell the system this playlist is relevant so it
> can surface it at the right moment."*

That is the **cold-start problem**, stated exactly. Spotlight indexing pays off when a user goes
looking. Donation pays off after a user has behaved. Neither works for content that is new.

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 345 @ 5:18)
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

**Confirmed API:**
- `RelevantEntities.shared` — a singleton.
- `updateEntities(_:for:)`, `removeAllEntities(for:)`, `removeEntities(_:from:)`,
  `removeAllEntities()` — all `async throws`. ✅ **SDK-verified**
  (`AppIntents-27.0-macos.swiftinterface:4837-4846`, `anyAppleOS 27.0`), plus a fifth method the
  session did not show: `removeEntities(_:) async throws`, no context parameter.
- **`AppEntityContext`** — an opaque `Hashable` struct with domain-scoped factory methods. One
  concrete path verified from the session: `AppEntityContext.audio(.workout(activityType:
  .running))` — contexts are **domain-scoped** (`.audio`) with a **situation** (`.workout`)
  carrying **parameters** (`activityType:`). ⚠️ But see the gap box below: on the macOS surface
  the interface spells only `.audio(.nowPlaying)`.

⚠️ **Lifecycle rule with no safety net:** *"**Entities stay registered until you remove them.**"* ✅
VERIFIED (transcript, 345). **There is no TTL.** Registration is a memory-management obligation on
your app: register when a thing becomes situationally relevant, remove when it stops. A bug here
does not throw; it just leaves stale suggestions in other apps' UI indefinitely.

🔴 **GAP — the full `AppEntityContext` inventory — narrowed but not closed.** The 27.0 macOS
interface was checked on 2026-07-29: `AppEntityContext`'s only factory on that surface is
`static func audio(_: AudioContext)`, and `AudioContext`'s only member is `.nowPlaying`
(`AppIntents-27.0-macos.swiftinterface:4814-4837`). The session's `.workout(activityType:)`
situation is **not present in the macOS 27.0 beta interface** — presumably an iOS-surface case
this repo has not captured. What would resolve it: the iOS interface, or the `AppEntityContext`
documentation page. **Safe default:** rely on Xcode completion at the call site; do not invent a
context path — on the Mac, `.audio(.nowPlaying)` is the only spellable context today.

**The three-way decision rule — the cleanest taxonomy in the whole session set:**

> ✅ **VERIFIED (transcript, WWDC26 345)** — *"Use **Spotlight** when you want your content to be
> **searchable and retrievable by Siri**. Use **interaction donation** to teach Siri and the system
> **how people use your app** — so it can identify patterns and suggest actions people may want to
> repeat. And use **`RelevantEntities`** to hint to the system **which content is relevant in
> specific situations** — so the system can suggest it at the right moment."*

| Mechanism | Job | Trigger |
|---|---|---|
| Spotlight / `IndexedEntity` | **findability** | user searches |
| Interaction donation | **behavioural learning** | user has done it before |
| `RelevantEntities` | **situational suggestion** | a situation arises |

One under-appreciated detail: the consumer surface demonstrated was the **Fitness app's suggested
playlists when setting up a running workout.** ✅ VERIFIED (transcript, 345). So `RelevantEntities`
feeds **other apps' suggestion UI**, not only Siri. That is a genuinely different distribution
channel, and it is available to apps in uncovered categories (§6) — registering relevance does not
require a schema.

### 13.3 ⚠️ `EntityCollection` — the parameter-resolution performance cliff

This section documents a cost that is otherwise completely invisible.

> ✅ **VERIFIED (transcript, WWDC26 345)** — *"**Before an intent runs, the system resolves every
> entity.** That means **calling the entity query to populate all of its properties**, so the intent
> has everything it may need. For most intents, that's exactly what you want. But in my case, this
> meant **resolving hundreds or thousands of photo entities**, even though **my code only needs the
> entity ID** to update my data model."*

Read that again if you have an intent taking `[SomeEntity]`. **Every element is fully resolved
through your query before `perform()` is entered.** If your query hits a database, that is N round
trips you never wrote and cannot see in your own code.

> ✅ **VERIFIED (transcript, WWDC26 345)** — *"**`EntityCollection`** fixes this. It's a new type
> that **stores an array of entity identifiers, instead of the fully resolved entities**. When you
> use `EntityCollection` as your parameter type, the system **passes just the identifiers** to the
> intent's perform method, **without resolving the full entities**."*

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 345 @ 7:15)
struct TagPhotosIntent: AppIntent {
    static let title: LocalizedStringResource = "Tag Travel Photos"

    @Parameter var photos: EntityCollection<PhotoEntity>   // was: [PhotoEntity]
    @Parameter var tag: String

    func perform() async throws -> some IntentResult {
        modelData.tagPhotos(ids: photos.identifiers, tag: tag)   // was: tagPhotos(photos, tag: tag)
        return .result()
    }
}
```

**Confirmed API:** `EntityCollection<E>`, generic over the entity type, with an **`.identifiers`**
property. It is a drop-in replacement for `[E]` as a `@Parameter` type.

✅ **SDK-verified** (`AppIntents-27.0-macos.swiftinterface:10284-10328`, `anyAppleOS 27.0`):
`struct EntityCollection<Entity: AppEntity>` with `var identifiers: [Entity.ID]`,
`init(identifiers: [Entity.ID] = [])`, `init(entities: [Entity])`, `count` / `isEmpty`,
`append` / `remove` / `contains` for both identifiers and entities, and a `Collection` conformance
over `Entity.ID` — plus an escape hatch the session did not mention: `func resolvedEntities()
async throws -> [Entity]`, for the moment inside `perform()` when you discover you need the full
entities after all.

**Adoption criterion, distilled: use `EntityCollection` whenever `perform` only needs IDs.**

**Measured claim — read the attribution carefully.** Apple's stated result: *"I built a Shortcut to
find and tag **1000 photos**. First, with a regular array of photo entities. Then with
`EntityCollection`, which was **almost instant**."* ✅ VERIFIED (transcript, 345). **Apple-published,
qualitative only** — no absolute numbers, no hardware, no OS build given in the session. *"Almost
instant"* is the ceiling of what can honestly be claimed; do not repeat it as a multiplier.

### 13.4 `@UnionValue` — one parameter, several entity types

> ✅ **VERIFIED (transcript, WWDC26 345)** — *"A union value is a **Swift enum where each case wraps
> a different type**, letting a single parameter represent one of several options."*

> ✅ **VERIFIED (transcript, WWDC26 345)** — *"With `@UnionValue` **supporting input parameters**, I
> can use **one widget for both**."*

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 345 @ 11:58)
@UnionValue
enum TravelGalleryContent {
    case landmarkCollection(LandmarkCollectionEntity)
    case photoAlbum(PhotoAlbumEntity)

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Travel Gallery"
    static let caseDisplayRepresentations: [Cases: DisplayRepresentation] = [
        .landmarkCollection: "Landmark Collection",
        .photoAlbum: "Photo Album"
    ]
}
```

**Confirmed API:**
- macro **`@UnionValue`** on an enum whose cases each wrap exactly one type.
- What it generates, verbatim: *"The macro generates everything the system needs — **type
  information, case metadata, and picker support**."*
- **`static let typeDisplayRepresentation: TypeDisplayRepresentation`** — *"the label for the
  **overall type**."*
- **`static let caseDisplayRepresentations: [Cases: DisplayRepresentation]`** — *"maps **each case
  to the name shown in the picker**."*

**The non-obvious detail:** the dictionary key type is a macro-synthesized **`Cases`** type,
referenced as `.landmarkCollection` / `.photoAlbum` — **not the enum itself**. The enum has payloads
so it cannot be trivially `Hashable`; hence a separate caseless mirror. If you write
`[TravelGalleryContent: DisplayRepresentation]` it will not compile, and the reason will not be
obvious.

✅ **SDK-verified** (`AppIntents-27.0-macos.swiftinterface:5159`, `:3716-3736`): the macro attaches
conformance to `AppUnionValue` (`anyAppleOS 27.0`), whose requirements are exactly the two statics
above — and `Cases` is a real associated type, constrained to `AppUnionValueCasesProviding :
AppEnum`, which confirms the caseless-mirror reading: the dictionary key type is `Self.Cases`, and
it is itself an `AppEnum`.

**What is actually new here.** Session 343 uses `AudioEntity` as *"a `UnionValue` type that includes
both songs and playlists"* as an `IntentValueQuery` **return** element type. Session 345 frames
**input parameters** as the new capability. Cross-referencing the two: `@UnionValue` enums work
both as query return types (which predates this release) and as `@Parameter` input types (new).
That split is now SDK-attested rather than inferred: the 26.5 interface already carries the
`@UnionValue` macro, conforming only to `_IntentValueRepresentable`
(`AppIntents-26.5-macos.swiftinterface:10344`); the 27.0 interface adds the `AppUnionValue`
conformance that brings `Cases`, display representations and picker support. The macro is old; the
input-parameter machinery is 27.0.

Scope: *"this isn't limited to Widgets — `@UnionValue` parameters **work everywhere your intent
does, including the Shortcuts app**."* ✅ VERIFIED (transcript, 345).

**Where you have already met unions in this guide:** `.audio.addToPlaylist` takes an `AudioEntity`
union (§5.1), and `.calendar.event` has two union-typed properties — `location` as
`PlaceDescriptor | String` and alarms as `Duration | Date` (§5.1). **Apple's own schemas use
unions**, so you will consume them before you author one.

### 13.5 `SyncableEntity` — cross-device Siri conversations

> ✅ **VERIFIED (transcript, WWDC26 345)** — *"With our 2027 releases, **Siri can continue
> conversations across devices** — and your entities can be part of those conversations."*

The failure mode this addresses:

> ✅ **VERIFIED (transcript, WWDC26 345)** — *"If I ask Siri on my iPhone to add a photo to an album,
> then switch to my other device and ask Siri to tag that photo — **Siri might not be able to find
> that photo**. … Your entity's ID **might be generated locally on each device**. Local IDs work
> great on the device they were created on. **But each device generates its own local IDs. So the
> same entity can end up with a different ID on each device.**"*

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 345 @ 10:14)
// If your ID is already stable across devices (server UUID, CloudKit record ID):
struct PhotoEntity: AppEntity, SyncableEntity {
    var id: Int  // Already stable across devices — that's it
}

// If you use local IDs, pair a local and a stable ID:
struct PhotoEntity: AppEntity, SyncableEntity {
    var id: SyncableEntityIdentifier<String, String>

    init(localID: String, stableID: String) {
        self.id = SyncableEntityIdentifier(local: localID, stable: stableID)
    }
}
```

**Confirmed API:**
- protocol **`SyncableEntity`** — *"it **declares to the system** that your entity's ID is stable
  and can be used across devices."*
- **`SyncableEntityIdentifier<Local, Stable>`** — two generic parameters, `init(local:stable:)`.
- Division of labour, verbatim: *"**On-device, your code uses the local ID. And across devices, the
  system uses the stable one.**"*

✅ **SDK-verified** (`AppIntents-27.0-macos.swiftinterface:2651-2687`, `anyAppleOS 27.0`):
`protocol SyncableEntity : AppEntity` is an **empty marker** — it *declares*, literally — and
`struct SyncableEntityIdentifier<LocalID, StableID>` (the SDK's generic parameter names) requires
both to be `EntityIdentifierConvertible & Sendable`, stores `local` / `stable` as optionals, and
adds a convenience `init(id:)` when `LocalID == StableID`.

Named sources of stable IDs: *"That could come from **your server, or from CloudKit record IDs**."*
Named source of unstable IDs: *"local identifiers, like **CoreData row IDs**."* ✅ VERIFIED
(transcript, 345).

**Read the first word of the protocol description again: it *declares*.** `SyncableEntity` is not a
synchronization mechanism. It does not make your IDs stable. It tells the system they already are.
See §14.5 for why that is a silent failure waiting to happen.

### 13.6 Native `@Parameter` types

> ✅ **VERIFIED (transcript, WWDC26 345)** — *"When you declare a `@Parameter`, the system gives you
> a **native picker, Siri understanding, and localization for free**. We're extending that same
> support to more native types. We're adding native support for **`Duration`**, so no more building
> custom time pickers. And **`PersonNameComponents`** for structured name input instead of a plain
> string. **And more.**"*

Two types named explicitly: **`Duration`** and **`PersonNameComponents`**.

✅ **SDK-verified — with an availability surprise.** The interface conforms both to the
intent-value machinery at `@available(anyAppleOS 26.0, *)`, not 27.0: `Duration : _IntentValue,
DisplayRepresentable` (`AppIntents-27.0-macos.swiftinterface:5074-5078`) and `PersonNameComponents
: _IntentValue, DisplayRepresentable` (`:5090-5094`). Session 345 presents them as part of this
year's extension; the SDK dates the conformances to 26.0. And one member of "and more" is
findable: `Calendar.RecurrenceRule : IntentValueConvertible` at `anyAppleOS 27.0` (`:5071-5073`)
— the Foundation type §5.1's `.calendar.event` uses.

🔴 **GAP:** the rest of "and more" was not enumerated — the 27.0 interface was checked on
2026-07-29 and a complete inventory of native `@Parameter` types was not extracted from it. What
would resolve it: the App Intents updates page, the `@Parameter` documentation, or a systematic
sweep of the interface's `_IntentValue` conformances. **Safe default:** try the type; if it does
not get a picker, fall back to a supported representation.

**Corroboration for `Duration` from two other sessions**, which is a good sign the claim is real:
`.clock.createTimer` declares `var duration: Duration` (session 343, §5.1), and CometCal's event
alarm union includes `Duration` (session 344, §5.1).

The payoff restated: *"Each one gets a **native picker** and works **everywhere your intent does —
Siri, Shortcuts and Widgets**."* ✅ VERIFIED (transcript, 345).

### 13.7 `LongRunningIntent` — past the 30-second wall

The limit, stated as a hard number:

> ✅ **VERIFIED (transcript, WWDC26 345)** — *"When your intent runs — **from Siri, Shortcuts, or any
> system surface** — **it only has 30 seconds to finish**. That works for most everyday actions. But
> not every intent is that quick."*

That is the clearest statement of the App Intents execution ceiling in our corpus, and it is worth
knowing even if you never adopt `LongRunningIntent`: **30 seconds, from any surface.**

> ✅ **VERIFIED (transcript, WWDC26 345)** — *"**`LongRunningIntent`** fixes this. It lets your
> intent **run beyond the 30-second limit** — and **manages the background task lifecycle of your
> app**. And as your intent runs, **progress updates appear automatically as a Live Activity**."*

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 345 @ 13:41)
struct UploadPhotoIntent: LongRunningIntent, CancellableIntent {
    static let title: LocalizedStringResource = "Upload Photo"

    @Parameter var photo: IntentFile

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await performBackgroundTask {
            let chunks = calculateChunks(for: photo)
            progress.totalUnitCount = Int64(chunks)

            for chunk in 1...chunks {
                try Task.checkCancellation()
                try await uploadChunk(chunk)
                progress.completedUnitCount = Int64(chunk)
            }
            return "Upload complete!"
        } onCancel: { reason in
            cleanup(for: reason)
        }
        return .result(dialog: "\(result)")
    }
}
```

**Confirmed API:**
- protocol **`LongRunningIntent`** — ✅ **SDK-verified**: `protocol LongRunningIntent :
  ProgressReportingIntent`, `anyAppleOS 27.0` (`AppIntents-27.0-macos.swiftinterface:3601-3604`).
  It refines `ProgressReportingIntent` — macOS 14 / iOS 17, itself refining `AppIntent` and
  supplying the implicit `progress: Foundation.Progress` member (`:3625-3634`) — so the
  narration's *"because it builds on `ProgressReportingIntent`"* is literal, and this guide's
  earlier 🟡 "appears to refine `AppIntent`" is superseded.
- protocol **`CancellableIntent`** with an **`onCancel`** handler, supplied here as the trailing
  closure of `performBackgroundTask`. ✅ **SDK-verified** at `anyAppleOS 26.4` (`:3369-3376`),
  along with a standalone `withIntentCancellationHandler(operation:onCancel:isolation:)`.
- **`performBackgroundTask { … } onCancel: { reason in … }`** — `async throws`, generic over the
  body's return type. ✅ **SDK-verified** (`:3605-3611`): `performBackgroundTask<T>(options:
  LongRunningTaskOptions = [], operation:) async throws -> T`, with the `onCancel:` overload gated
  `where Self : CancellableIntent` — which is why the sample conforms to both protocols.
- **`progress`** — an implicit member with `totalUnitCount` / `completedUnitCount` as `Int64`,
  available *"because it builds on **`ProgressReportingIntent`**."* ✅ SDK-verified: it is
  `Foundation.Progress`, from the `ProgressReportingIntent` extension (`:1889-1894`).

⚠️ **Progress reporting is not optional and not decorative:**

> ✅ **VERIFIED (transcript, WWDC26 345)** — *"**`LongRunningIntent` requires the intent to report
> progress**, so the system knows it's still working and hasn't stalled."*

It is the **liveness signal**. An intent that adopts `LongRunningIntent` and never touches
`progress` should be assumed to get killed. See §14.6.

**Cancellation:**

> ✅ **VERIFIED (transcript, WWDC26 345)** — *"**`CancellableIntent`** lets your intent **clean up
> gracefully when cancelled** — whether **the person tapped cancel, the system timed out or needed
> to reclaim resources**. … the handler **gives me the reason**, and I can use it to **cleanup
> partial uploads or cancel in-flight requests**."*

Three causes named: **user-initiated, system timeout, resource reclamation.** ✅ **SDK-verified —
the type this guide could not previously place in a signature is `IntentCancellationReason`**: a
`Sendable`, `Equatable` struct at `anyAppleOS 26.4`, and it is exactly what the `onCancel:`
handler receives (`AppIntents-27.0-macos.swiftinterface:3377-3389`, `:3610`). Its visible members
are **`.timeout`** and **`.userCancelled`** — two, not three: the interface has no distinct
member for resource reclamation, which presumably surfaces as `.timeout` or a non-public value.
(This closes former register entry G9's naming half; the reclamation mapping stays open.)

UI consequence worth designing for: *"there's a **stop button right on the Live Activity**, so the
person can cancel it at any time."* ✅ VERIFIED (transcript, 345). Your cancellation path is
user-reachable by default, so it will be exercised.

**Background GPU — the capability that matters for this series:**

> ✅ **VERIFIED (transcript, WWDC26 345)** — *"`LongRunningIntent` also supports **background GPU
> access on supported devices** — for tasks like **photo processing or on-device inference**. **Just
> make sure to add GPU access to your app's entitlement.**"*

This is a supported path to running **on-device inference from a background App Intent** — relevant
to anyone wiring Foundation Models, Core AI or MLX behind a Shortcut. The SDK now supplies the
request side: ✅ **SDK-verified**, GPU access is asked for as an option flag —
`performBackgroundTask(options: [.requiresGPU]) { … }`, via `LongRunningTaskOptions`
(`AppIntents-27.0-macos.swiftinterface:3612-3624`). Two gates remain underspecified: "supported
devices" (unnamed) and the GPU-access entitlement (🔴 **GAP** — the name is not given in the
session and appears nowhere in the 27.0 interface, checked 2026-07-29; the forum corpus records
`continued-processing.gpu` as an existing background-GPU entitlement, from a developer post rather
than from Apple, so treat that as a lead, not the answer).

### 13.8 `ExecutionTargets` — choosing the process

The setup is a real architectural problem, not a toy:

> ✅ **VERIFIED (transcript, WWDC26 345)** — *"When your intents, entities, and queries live in a
> **shared package** like this — linked by your app and extensions — the system has to decide
> **which process runs each intent** when a request comes in. It picks a target based on
> **heuristics** like **if the app is already running, it prefers the app**. and **if not, it
> launches the extension**. **But sometimes that's not the right choice.**"*

The concrete failure: *"My widget shares the data model with the app — but **having two processes
write to the same data store can cause conflicts**. So I gave the widget **read-only** access and
the main app handles all the writes."* ✅ VERIFIED (transcript, 345).

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 345 @ 16:54)
// Write operation — needs the main app
struct UpdateFavoriteIntent: AppIntent {
    static var allowedExecutionTargets: ExecutionTargets { .main }
}

// Standalone download — runs in the extension
struct DownloadPhotoIntent: AppIntent {
    static var allowedExecutionTargets: ExecutionTargets { .appIntentsExtension }
}

// Display-only — runs in the widget extension
struct GetLandmarkStatusIntent: AppIntent {
    static var allowedExecutionTargets: ExecutionTargets { .widgetKitExtension }
}

// Works in either — lets the system choose
struct TagPhotosIntent: AppIntent {
    static var allowedExecutionTargets: ExecutionTargets { [.main, .appIntentsExtension] }
}
```

**Confirmed API — with the real type name, from the SDK:**
- `static var allowedExecutionTargets: ExecutionTargets` — ✅ **SDK-verified**, declared on
  `AppIntent` **and on `EntityQuery`** (your queries can be pinned too), both `anyAppleOS 27.0`
  (`AppIntents-27.0-macos.swiftinterface:3111-3112`, `:4205-4206`).
- **`ExecutionTargets`** is a genuine **`OptionSet`** — ✅ SDK-verified — and its real name is
  **`IntentExecutionTargets`** (`:3570-3597`); `ExecutionTargets` is a typealias for it scoped
  inside `AppIntent` (`:3120-3122`), which is why the sample's spelling compiles inside an intent
  and why diagnostics will say `IntentExecutionTargets`.
- Members confirmed: **`.main`**, **`.appIntentsExtension`**, **`.widgetKitExtension`** — plus a
  **`.default`** the session did not mention (`:3574-3585`).

> ✅ **VERIFIED (transcript, WWDC26 345)** — *"With `ExecutionTargets`, you **override the system's
> heuristics** and control exactly which process handles your intent."*

**The decision rule that falls out:** pin `.main` for anything that **writes**; allow the extension
for anything that is **standalone or read-only**; leave it unset when you genuinely do not care.
The default heuristic — prefer the app if it is running, else launch the extension — is fine until
two processes touch the same store, at which point it is a data-corruption source that reproduces
only when the app happens to be running.

### 13.9 Apple's own recommended adoption orders

Two sessions close with an ordered list. They are worth following because they are ordered by
leverage, not by API novelty.

**Session 343 — for Siri integration** (✅ VERIFIED, transcript, verbatim in order):

1. *"a great place to start is by **customizing your entity display representations**. They are
   used to display your entities across the system."*
2. *"From there, **add your entities to the semantic index, and keep the index up to date**, so
   Siri can always find your freshest content."*
3. *"You might also consider making your entities accessible through Siri with an
   **`IntentValueQuery` and in-app search**."*
4. *"**annotating your views, activities, and your existing system integrations** with entities."*
5. *"When you're ready, look into **donating UI interactions**."*

**Donations are last. `DisplayRepresentation` is first** — consistent with it feeding seven
subsystems (§11.3).

**Session 345 — for framework capabilities** (✅ VERIFIED, transcript, verbatim in order):

1. *"add **`ValueRepresentation`** to your entities so they can carry structured data across apps."*
2. *"**Register relevant content** with the system — so it gets surfaced at the right moment."*
3. *"Adopt **`EntityCollection`** to make your intents faster when working with large numbers of
   entities."*
4. *"add **`LongRunningIntent`** to any intent that needs more than 30 seconds to finish."*

**Session 240 — for the overall integration** (✅ VERIFIED, transcript, verbatim in order):

1. *"**Model and index your entities to Spotlight** so Siri can find your content."*
2. *"**Adopt app schema domains** that match your app's core experiences."*
3. *"**Adopt `Transferable`** to enable content import and export."*
4. *"**Test early and often** using AppIntentsTesting, then Shortcuts, Spotlight, and Siri."*

---

## 14. Silent failures

The defining property of this stack is that most defects do not throw. This section collects the
ones we can evidence. The first is the worst.

### 14.1 ⚠️ SILENT FAILURE — `IntentParameter.valueState`: "clear it" and "don't touch it" are not the same thing

**This is the most consequential API detail in the entire App Intents session set, and every
update-style intent written the obvious way gets it wrong.**

Consider an update intent with an optional parameter — a due date, a recurrence rule, a location, a
label. The user says one of two things:

- *"Remove the due date from that reminder."*
- *"Change the title of that reminder."*

In both cases your `dueDate` parameter arrives as `nil`. In the first case, `nil` means **the user
explicitly asked you to clear it**. In the second, `nil` means **the user never mentioned it and
you must leave it alone**.

**A `nil` check cannot distinguish these.** Session 344 states the problem in exactly those terms:

> ✅ **VERIFIED (transcript, WWDC26 344)** — *"there's one important subtlety with **optional
> parameters in update intents** worth calling out. For example, **when `recurrence` is nil, does
> that mean "don't change it" or "remove it"? A simple nil check doesn't tell me which case I'm
> dealing with.** … the `@AppIntent` macro **wraps each property in an `IntentParameter` which
> exposes a `valueState`**. This is how I tell the difference. **`.set` with an actual value** means
> a new value is provided. **`.set` with a nil value** means it's **explicitly cleared**.
> **`.unset`** means **the parameter isn't part of the request**."*

**Confirmed API:** `$parameter.valueState`, an enum with **`.set(T?)`** and **`.unset`**.

✅ **SDK-verified** (`AppIntents-27.0-macos.swiftinterface:4351-4361`):
`IntentParameter.ValueState` is `case unset` / `case set(Value)` — for an optional parameter
`Value` *is* the optional, which is what makes `.set(nil)` expressible — and the extension
declaring it is `@available(macOS 15.2, iOS 18.2, watchOS 11.2, tvOS 18.2, visionOS 2.2, *)`. The
mechanism predates this release cycle; the sessions did not invent it, they finally explained it.

| `valueState` | The user meant | Correct action |
|---|---|---|
| `.set(value)` | "make it this" | assign it |
| `.set(nil)` | **"clear it"** | delete / clear the field |
| `.unset` | "I didn't mention it" | **leave untouched** |

**The wrong code — and it is the code everyone writes:**

```swift illustrative
// ❌ WRONG. Compiles. Runs. Never errors. Silently ignores "remove the due date".
func perform() async throws -> some IntentResult {
    var updates = ReminderUpdates()
    if let title { updates.title = title }
    if let dueDate { updates.dueDate = dueDate }        // <- the bug
    if let recurrence { updates.recurrence = convert(recurrence) }
    try await store.apply(updates, to: reminder)
    return .result()
}
```

When the user says *"remove the due date"*, `dueDate` is `nil`, the `if let` fails, `updates.dueDate`
is never touched, the store is updated with no change to the due date, and the intent **returns
success**. Siri confirms the action. The due date is still there. Nothing anywhere reports a
problem.

**The right code:**

```swift prelude:guide-context
// 🟡 RECONSTRUCTED shape (session 344 published no code block); the three-case
// semantics are ✅ VERIFIED from narration, quoted above.
func perform() async throws -> some IntentResult {
    var updates = ReminderUpdates()

    switch $title.valueState {
    case .set(let newTitle?): updates.title = .set(newTitle)   // change it
    case .set(nil):           updates.title = .clear           // clear it
    case .unset:              break                            // don't touch it
    }

    switch $dueDate.valueState {
    case .set(let date?):     updates.dueDate = .set(date)
    case .set(nil):           updates.dueDate = .clear
    case .unset:              break
    }

    switch $recurrence.valueState {
    case .set(let rule?):     updates.recurrence = .set(convert(rule))
    case .set(nil):           updates.recurrence = .clear
    case .unset:              break
    }

    try await store.apply(updates, to: reminder)
    return .result()
}
```

Note that the fix does not stop at the intent. **Your data layer needs a three-state update type
too.** If `ReminderUpdates.dueDate` is a plain `Date?`, you have merely moved the ambiguity one
layer down. That is why the listing above uses a `.set` / `.clear` / absent representation on the
update struct — some form of that is required, whether you spell it as an enum, an
`Optional<Optional<Date>>`, or a separate `clearedFields: Set<Field>`.

**Apple's generalization:**

> ✅ **VERIFIED (transcript, WWDC26 344)** — *"**This pattern applies to any optional parameter where
> clearing the value is a meaningful action.**"*

**Blast radius.** Count the `update*` and `delete*` verbs in §5.4: `.calendar.updateEvent`,
`.clock.updateAlarm`, `.clock.updateTimer`, `.mail.updateDraft`, `.mail.updateMail`,
`.messages.editSentMessage`, `.notes.updateNote`, `.photos.updateAlbum`, `.photos.updateAsset`,
`.photos.updateRecognizedPerson`, `.reminders.updateGroup`, `.reminders.updateList`,
`.reminders.updateReminder`, `.reminders.updateSection`, `.books.updateSettings` and its four
spacing siblings, `.browser` bookmark edits, `.journal.updateEntry`, `.presentation.update`,
`.spreadsheet.update`/`.updateSheet`, `.whiteboard.updateBoard`/`.updateItem`. **Every one of them
is exposed.** If you adopt an update schema, audit it for this before you ship.

**Why it is a *silent* failure and not merely a bug:** there is no diagnostic. It compiles cleanly,
there is no runtime warning, `perform()` returns success, Siri says "OK", and the user believes the
change happened. The only way to find it is to specifically test the phrase "remove the X" and then
go and look at the data.

### 14.2 ⚠️ Excessive interaction donations are silently ignored

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"Your interaction donations should accurately represent
> real user behavior in your app. **If your app donates excessively, the system may ignore those
> donations.**"*

No threshold is published. No error is surfaced. No API tells you your donations were dropped. An
app that donates on every scroll, every selection, every view appearance can end up with **worse**
Siri behaviour than one that donates nothing, and there is no signal to diagnose it from.

🔴 **GAP:** the threshold, the window and whether it is per-app or per-intent are all unknown.
**Safe default:** donate only completed, user-initiated, meaningful actions from the UI, never from
inside `perform()`, and treat donation as a rare event rather than telemetry.

### 14.3 ⚠️ Per-row `.appEntityIdentifier` loses selected and scrolled-off entities

Session 240 shows the per-row form inside a `ForEach`:

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 240 @ 17:19) — the SIMPLE form
List {
    ForEach(messages) { message in
        MessageRow(message: message)
            .appEntityIdentifier(
                EntityIdentifier(
                    for: MessageEntity.self,
                    identifier: message.id
                )
            )
    }
}
```

Session 343 warns about exactly this pattern:

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"Collection annotations help me avoid the overhead of
> attaching an annotation to every single row. Instead, **the system fetches identifiers lazily, as
> it needs them**. Collection annotations **also let Siri discover entities that have been selected
> and scrolled off screen. Per row annotations disappear as soon as the view leaves the view
> hierarchy.**"*

SwiftUI recycles rows. When a row scrolls out of the hierarchy its annotation goes with it. A user
who selects something, scrolls away, and then says *"send that one"* has selected an entity the
system can no longer see — and the failure is Siri being confused, not an error in your logs.

**The correct form for lists:**

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 343 @ 16:27) — the CORRECT form for lists
struct PlaylistDetailView: View {
    var body: some View {
        List {
            ForEach(playlist.tracks) { track in
                PlaylistTrackRow(track: track)
            }
        }
        .appEntityIdentifier(forSelectionType: GeneratedTrack.ID.self) { trackID in
            EntityIdentifier(for: SongEntity.self, identifier: trackID)
        }
    }
}
```

**240 shows the simple form; 343 shows the correct form for lists where selection matters.** Both
are Apple code samples. Prefer 343's. Full treatment in guide 03.

### 14.4 ⚠️ `TransientAppEntity` silently forecloses three system integrations

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"Note, that with the **three entity annotation APIs**
> I'm describing, **you can't use `TransientAppEntity`**. Transient entities are temporary model
> objects, so **they don't have persistent identifiers**."*

The three surfaces are notifications (`UNMutableNotificationContent.appEntityIdentifiers`), Now
Playing (`MusicContent.appEntityIdentifiers`), and AlarmKit
(`AlarmConfiguration.alarm(…appEntityIdentifier:…)`). ✅ **VERIFIED (Apple code sample, 343 @
21:07)**.

Session 344 chooses `TransientAppEntity` for `AttendeeEntity` for excellent local reasons (§10.6).
The consequence is that a CometCal attendee can **never** be an annotation target on any of those
three surfaces. That is a live design constraint discovered a session apart from the decision that
causes it.

🔴 **GAP:** whether this is a compile error, a runtime assertion, or a silent no-op is **not stated
anywhere in our sources.** What would resolve it: trying it. **Safe default:** treat it as silent.
Decide transient-versus-persistent with the system-integration question explicitly on the table:
*"will this type ever need to appear in a notification, in Now Playing, or on an alarm?"*

### 14.5 ⚠️ `SyncableEntity` is a promise nothing validates

Conforming to `SyncableEntity` with a locally-generated `id` and no `SyncableEntityIdentifier` is a
**lie to the system that compiles cleanly**. The protocol *declares* stability (§13.5); it does not
provide it. Nothing checks. The symptom is the exact failure the API exists to prevent — Siri
losing an entity across devices — appearing in an app that has "adopted" the fix.

**Safe default:** before conforming, answer in one sentence where the stable ID comes from. If the
answer is "the ID we already have", verify that it is generated centrally (server, CloudKit record
ID) and not per-device (Core Data row ID, `UUID()` at insert time).

### 14.6 ⚠️ `LongRunningIntent` without progress reporting

Progress is the liveness signal (§13.7), not a UI nicety. An intent that adopts `LongRunningIntent`
and never writes to `progress.completedUnitCount` gives the system no evidence it is alive. Apple
says the requirement exists *"so the system knows it's still working and hasn't stalled."*

🔴 **GAP:** the exact consequence — killed, throttled, or merely shown without progress — is not
stated. **Safe default:** set `totalUnitCount` before the loop and update `completedUnitCount`
inside it, exactly as the sample does, even for work whose length you have to estimate.

### 14.7 ⚠️ `SnippetIntent` state caching

The system may call a `SnippetIntent` multiple times, and `perform()` must re-fetch state each time
(§11.4). A snippet that caches renders stale state after the user interacts with its own controls —
they tap a toggle, the toggle does not move, and nothing errors.

### 14.8 ⚠️ Raw internal errors reaching end users

**Community-reported, not Apple-acknowledged.** Forum thread 835903 records
`TypedValueToContentGraphResolutionErrorDomain error 4` **leaking to end users through the Siri
UI**. Our research pass looked for first-party documentation of that behaviour and found none.

The machinery to prevent leakage does exist, and it is documented:

- `AppIntentError` and its subtypes (`PermissionRequired`, `Unrecoverable`, `UserActionRequired`)
- **`AppIntentError.init(description:)`** — construct with a localized description (new)
- **`CustomAppIntentErrorConvertible`** and **`CustomLocalizedStringResourceConvertible`** — map
  your domain errors to something presentable

✅ **VERIFIED (docs)** for the symbol names, from the framework's Errors topic — and ✅
**SDK-verified** for the load-bearing ones (`AppIntents-27.0-macos.swiftinterface:3305-3340`):
`AppIntentError.init(description:)`, `init(predefinedError:description:)` and two
`init(wrapping:)` overloads are all `anyAppleOS 27.0`, as is `protocol
CustomAppIntentErrorConvertible { var appIntentError: AppIntentError { get } }`;
`UserActionRequired`'s members are `.signin`, `.accountSetup` and `.confirmation`.

**The rule that follows: never let a raw `Error` escape `perform()`.** Conform your error type to
`CustomAppIntentErrorConvertible` / `CustomLocalizedStringResourceConvertible` so that whatever
Siri surfaces is a string you wrote. Given thread 835903, assume anything that escapes is
user-visible.

### 14.9 The one that is not silent — the schema co-requisite build error

Worth ending on, because it is the counter-example. Adopting `.messages.sendMessage` without
`.messages.draftMessage` **fails the build with a Fix-It** (§3.3). Apple chose a loud failure for a
case that would otherwise have been a silent partial experience:

> ✅ **VERIFIED (transcript, WWDC26 240)** — *"instead of failing silently at runtime, **the build
> system surfaces this early.**"*

That is the design instinct the rest of this section wishes had been applied more widely.

---

## 15. Testing: the four-stage ladder

Session 240 gives an ordered methodology that we have not seen written down anywhere else, and it
is genuinely good. Its value is as a **debugging funnel**: each stage isolates one class of failure,
so you always know which layer you are arguing with.

| Stage | Tool | What it validates — verbatim |
|---|---|---|
| 1 | **`AppIntentsTesting`** | *"lets you exercise your intents **entirely in isolation. No Siri involved.** … **the fastest and most reliable way to validate your business logic early in development.**"* |
| 2 | **Shortcuts app** | *"**This is where you validate the shape of your intent. Not just what it does, but how it's configured and exposed.**"* |
| 3 | **Spotlight** | *"where you validate your **content integration**, ensuring your entities are **indexed correctly, discoverable, and linkable**. This helps you **confirm that Siri can find the right data before it ever tries to act on it.**"* |
| 4 | **Siri** | *"**Natural language, entity resolution, on-screen context, and cross-app workflows.**"* |

✅ **VERIFIED (transcript, WWDC26 240)** for every quoted cell.

**`AppIntentsTesting` is a framework** (`/documentation/AppIntentsTesting`) that lets you invoke
intents with test parameters and assert on results like ordinary unit tests, with no Siri involved.
✅ **VERIFIED (docs)** — the page exists.

**Debug at the lowest stage that reproduces the failure.** Most "Siri doesn't work" reports are
stage-2 or stage-3 problems misdiagnosed as stage-4:

| Symptom | Most likely stage | Why |
|---|---|---|
| Intent does the wrong thing | 1 | business logic; Siri is not involved |
| Intent does not appear in Shortcuts | 2 | configuration/exposure, not language |
| Siri says it cannot find the thing | 3 | indexing or query protocol (§10) |
| Siri finds it but will not act | — | **schema tier** (§2, §6) — no amount of testing fixes this |
| "Remove the X" appears to work but doesn't | 1 | `valueState` (§14.1) — and stage 1 will catch it |

That fourth row is the one the ladder cannot help with, and it is why §5 and §6 exist: if the
capability is not in the enumeration, no stage of testing will produce it.

A concrete stage-3 verification worth copying, from session 344: create an entity in the app
("Lunar Orbit Log"), swipe down to Spotlight, and search for it — *"and there it is with the
calendar icon and the title."* ✅ **VERIFIED (transcript, 344)**. That single check validates
`IndexedEntity` conformance, the index call, and your `DisplayRepresentation` in one motion.

⚠️ **A stage-3 obligation that is easy to miss.** Conformance is not donation:

> ✅ **VERIFIED (transcript, WWDC26 344)** — *"There's one more piece that's easy to miss.
> **`IndexedEntity` defines the shape of my indexed content, but entities still need to be
> donated.**"*

The rule: *"**Anytime calendars, or any indexed entity for that matter, are changed, the index needs
to be updated.**"* ✅ **VERIFIED (transcript, 344)** — index on create, re-index on update, delete
on removal. An app that conforms to `IndexedEntity` and never calls `indexAppEntities` passes
compilation, passes stage 1, passes stage 2, and fails stage 3 with an empty Spotlight and no
error. Guide 04 covers the index lifecycle in full.

---

## 16. Gap register

Everything in this guide we could not verify, what would resolve it, and what to do meanwhile.
A 🔴 GAP box in this series never contains a guess.

**SDK-interface pass, 2026-07-29:** every row below was checked against
`AppIntents-26.5-macos.swiftinterface` and `AppIntents-27.0-macos.swiftinterface`. **Five rows
closed** — G4, G5, G9, G15 and G17, marked ✅ resolved below with the answer inline. The interface
does not settle the remaining rows; where it narrows one, the row says so.

| # | Gap | What would resolve it | Safe default |
|---|---|---|---|
| G1 | **Exact tier semantics.** What capability does each of the three domain tiers actually confer? Inferred from grouping labels; never stated in prose. (§4) | A docs page or session statement defining tier reach; or empirical testing of an un-app-qualified Siri request against a Shortcuts-tier schema. Interface checked 2026-07-29 — encodes membership, not tier capability | If the feature must work through Siri without the user naming your app, require a **primary**-tier domain |
| G2 | **Per-schema required-property tables.** Verified for `.photos.asset` and `.photos.openAsset` only; ~180 schemas unenumerated. (§3.2) | The per-schema doc pages under `/documentation/appintents/appschema/<domain>intent/<name>`. Interface checked 2026-07-29 — schemas are opaque string accessors there; not settled | Do not design a data model around a schema you have not scaffolded in Xcode with `<domain>_` |
| G3 | **The schema co-requisite graph.** Exactly one pair demonstrated: `.messages.sendMessage ⇒ .messages.draftMessage`. (§3.3) | Adopting each schema in a scratch project and reading the build errors. Interface checked 2026-07-29 — co-requisites are not encoded there | Budget for "commit" verbs dragging in "prepare" siblings; plan adoption in pairs |
| G4 | ✅ **Resolved (SDK, 2026-07-29).** Same type: `ValueRepresentation` is an `AppEntity`-scoped typealias for `IntentValueRepresentation`, `anyAppleOS 26.4` (`AppIntents-27.0-macos.swiftinterface:2629-2634`). §13.1 | — | Port code freely between the spellings; the short one resolves in `AppEntity` scope |
| G5 | ✅ **Resolved (SDK, 2026-07-29).** `.system.searchInApp` is declared at `anyAppleOS 27.0`, underlying name `SystemSearchInAppIntent`; the deprecated `.system.search` carries the SDK message *"Use .system.searchInApp instead"* (`:13774-13797`). §8.2 | — | On pre-27 SDKs, the deprecated `.system.search` is the same schema |
| G6 | **`AppEntityContext`'s full domain/situation inventory.** Narrowed 2026-07-29: the macOS 27.0 interface spells only `.audio(.nowPlaying)`; the session's `.workout(activityType:)` is absent from the macOS surface. (§13.2) | The iOS interface, or the `AppEntityContext` docs page | Rely on Xcode completion; do not invent a context path |
| G7 | **`IntentValueQuery` input types** — Apple's comment says "and other system types may be supported"; and the full `AudioSearch` criteria list. `AudioSearch` is absent from the macOS 27.0 interface entirely (checked 2026-07-29). (§10.5) | The `IntentValueQuery` and `AudioSearch` docs pages, or the iOS interface | Implement against the type the schema snippet gives you; `switch` exhaustively |
| G8 | **`.visualIntelligence` input types.** Docs say the query "receives Visual Intelligence types" without naming them. Interface checked 2026-07-29 — only the schema accessor is visible; not settled. (§5.2) | The `.visualIntelligence` domain page symbol table | Write the query against whatever the snippet scaffolds |
| G9 | ✅ **Resolved (SDK, 2026-07-29), naming half.** The type is `IntentCancellationReason`, `anyAppleOS 26.4`, members `.timeout` / `.userCancelled` (`:3377-3389`). No distinct member for resource reclamation — that mapping stays open. §13.7 | — | `switch` non-exhaustively; treat unknown values as cleanup-and-exit |
| G10 | **The background-GPU entitlement name** for `LongRunningIntent`. Session 345 says "add GPU access to your app's entitlement" without naming it. The *request* side is now SDK-verified — `LongRunningTaskOptions.requiresGPU` (`:3616`) — but the entitlement name appears nowhere in the interface (checked 2026-07-29). (§13.7) | Apple's entitlements documentation | `continued-processing.gpu` is a **developer-reported** existing background-GPU entitlement (forum corpus) — a lead, not the answer |
| G11 | **Consequence of `TransientAppEntity` on annotation surfaces** — compile error, runtime assertion, or silent no-op? (§14.4) | Trying it | Assume silent; decide transient-vs-persistent with the system-integration question explicit |
| G12 | **Consequence of `LongRunningIntent` without progress** — killed, throttled, or merely progress-less? (§14.6) | Testing a long intent that never updates progress | Always report progress |
| G13 | **Donation throttle threshold, window, and scope.** No number, no error, no API. (§14.2) | Apple documentation; none found | Donate only completed, user-initiated UI actions |
| G14 | **Deprecated-schema removal timeline.** Nothing in our sources says when or whether deprecated schemas stop compiling. (§7) | Release notes | Migrate at leisure; do not assume two more OS majors |
| G15 | ✅ **Resolved (SDK, 2026-07-29).** The other kinds are `requestDisambiguation(among:dialog:)` and `requestConfirmation(for:dialog:)`, on `IntentParameter` since macOS 13 / iOS 16 (`:4367-4369`). §11.2 | — | — |
| G16 | **`UndoableIntent` and `IntentModes` semantics.** Shapes now SDK-verified (§13 preamble): both `anyAppleOS 26.0`; `UndoableIntent : SystemIntent` with `undoManager`; `IntentModes` an OptionSet with `.background` / `.foreground(...)`. Still in no session and no usage example. (§13) | Their docs pages | Do not design around them from shape alone |
| G17 | ✅ **Resolved (SDK, 2026-07-29).** `EntityOwnership` is an `OptionSet` with `.unknown` / `.shared` / `.public` and **no `.private` member** (`:8941-8947`). "Private" is the implicit non-adoption default. §12.2 | — | Use `.unknown` as the spelling for "cannot say" |
| G18 | **Which domains get semantic (vs merely lexical) Spotlight search.** Session 343 says it is *"depending on the App Intents domain"* and does not say which. (§10) | Apple documentation; none found | Do not promise semantic matching for an uncovered domain; verify empirically at testing stage 3 |
| G19 | **Person-type relationships:** `.messages.messagePerson`, `.phone.phonePerson`, and the system `IntentPerson`. (§5.1) | The per-schema doc pages | Use the type the schema names; use `IntentPerson` for cross-app value transfer |
| G20 | **Is custom `AppEntity` + `Transferable` on-screen hand-off *supposed* to work?** Asked by a developer on thread 838329; Apple routed it to Feedback Assistant (**FB23813341**) without answering. (§2) | An Apple answer; the radar | Assume schema-typed = actionable, non-schema = discoverable-only |
| G21 | **How complete the §5 enumeration is — substantially closed 2026-07-29.** The SDK census (§5.4) now verifies every row against the 27.0 macOS interface, correcting five domains. Residual softness: the counts are macOS-surface; an iOS interface could differ | The iOS interface, for the residual | Verify the specific domain you are adopting before planning around its inventory |

### Corrections this guide applies

Two items from the series correction register are folded in above rather than left as open notes:

- **C10.3** — `.system.searchInApp` is a **rename**, not a new schema. The `UNVERIFIED` flag that
  previously sat on the spelling is downgraded on the strength of two independent renderings on
  session 343's page plus `StringSearchCriteria`'s iOS 17.2 availability. §8.2.
- **C10.6** — `IntentParameter.valueState` gets its own callout box, as required. §14.1.

And two cautions carried per the register, one since retired:

- **Release-year labels are soft** — the updates page and session 345 use different conventions and
  345 says "2027 releases". Version-floor box, top of guide.
- **`ValueRepresentation` vs `IntentValueRepresentation`** — *resolved 2026-07-29 by the SDK pass*:
  same type, `AppEntity`-scoped typealias. §13.1 and former G4.

---

## 17. Sources

### Primary — SDK module interfaces (added 2026-07-29)

| File | What it is |
|---|---|
| `notes/sdk-interfaces/AppIntents-26.5-macos.swiftinterface` | The AppIntents Swift interface from the macOS 26.5 SDK (11,752 lines) |
| `notes/sdk-interfaces/AppIntents-27.0-macos.swiftinterface` | The AppIntents Swift interface from the **Xcode 27 beta / macOS 27.0 SDK** (16,826 lines) |

These are the declarations the compiler sees, and they outrank every other evidence class in this
guide. They supplied: the §5 domain census and its five corrections, the §8.2 `searchInApp`
resolution, every ✅ SDK-verified availability floor, and the closure of register entries G4, G5,
G9, G15 and G17. Two limits to keep in mind: they are the **macOS** surface, so an iOS-only symbol
(`AudioSearch`, the `.workout` context) is invisibly absent rather than demonstrated missing; and
Objective-C API does not appear in a Swift module interface at all.

### Primary — Apple documentation

Read through the `sosumi.ai` markdown mirror on **2026-07-27** (`developer.apple.com/documentation/X`
→ `sosumi.ai/documentation/X`), recorded in `notes/web/app-intents-siri-schemas.md`.

| Page | Supplied |
|---|---|
| `/appintents/` | Framework landing page and topic taxonomy |
| `/appintents/app-schema-domains` | **The domain index** — 23 domains in 3 tiers, plus the three macros |
| `/appintents/app-schema-domain-mail` | 12 intents, 5 entities |
| `/appintents/app-schema-domain-files` | 5 intents, 1 entity |
| `/appintents/app-schema-domain-photos` | 28 intents, 3 entities, 4 enums |
| `/appintents/app-schema-domain-camera` | 5 intents, 3 enums |
| `/appintents/app-schema-domain-browser` | 13 intents, 5 entities, 1 enum |
| `/appintents/app-schema-domain-reader` | 9 intents, 2 entities, 1 enum |
| `/appintents/app-schema-domain-journaling` | 5 intents, 1 entity |
| `/appintents/app-schema-domain-books` | 9 intents, 3 entities, "12" enums (SDK census: 10 — §5.4) |
| `/appintents/app-schema-domain-whiteboard` | 7 intents, 2 entities, 2 enums |
| `/appintents/app-schema-domain-assistant` | 1 intent (`activate`), Japan-only |
| `/appintents/app-schema-domain-system-and-in-app-search` | 2 intents (`open`, `search` deprecated) |
| `/appintents/making-actions-and-content-discoverable-by-apple-intelligence` | The discovery/action framing; required-property lists; Fix-Its |
| `/appintents/providing-contextual-cues-to-apple-intelligence-and-siri` | *"Schema application is optional but recommended"*; annotation APIs |
| `/appintents/making-app-entities-available-in-spotlight` | `IndexedEntity`, `indexAppEntities` |
| `/appintents/snippetintent` | `SnippetIntent` declaration and **iOS 26.0 availability** |
| `/appintents/stringsearchcriteria` | `StringSearchCriteria`, **iOS 17.2 / macOS 14.2**, `term`, conformances |
| `/updates/appintents` | The 2026 API list |
| `/AppIntentsTesting` | The testing framework's existence |

Two URLs that failed and are worth knowing about: `/appintents/making-onscreen-content-available-
to-siri-and-apple-intelligence` returned **404** despite being cited by name in forum thread 838329
(the live equivalent appears to be the contextual-cues page), and `/appintents/app-intent-domains`
is not a real path — the correct one is `app-schema-domains`.

### Primary — WWDC26 sessions

All fetched **2026-07-27** directly from `developer.apple.com/videos/play/wwdc2026/<n>/`, which
returns the full transcript **and** Apple's published code-sample block. Notes in
`notes/transcripts/missing-sessions.md`; raw transcripts in `transcripts/wwdc2026-<n>.txt`.

| Session | Title | Presenter | Sample app | Code block? |
|---|---|---|---|---|
| **240** | Build intelligent Siri experiences with App Schemas | Dan Niemeyer, Swift Intelligence Frameworks | UnicornChat | ✅ 5 samples |
| **343** | Explore advanced App Intents features for Siri and Apple Intelligence | Antonio Cancio, App Intents | CosmoTunes, UnicornChat, CometCal | ✅ 9 samples |
| **344** | Code-along: Make your app available to Siri | Justin Kang, Swift Intelligence Frameworks | CometCal | ❌ **none** — narration only |
| **345** | Discover new capabilities in the App Intents framework | Moe, App Intents | Landmarks Travel Tracking | ✅ 7 samples |

⚠️ **Session 344 published no code-sample block.** Every code listing in this guide attributed to
344 is 🟡 **RECONSTRUCTED** from narration and labelled as such. The *facts* asserted in 344's
narration — `valueState`'s three states, the `TransientAppEntity` rule, `EnumerableEntityQuery`'s
purpose, the `system.open` parameter name — are quoted directly and are reliable; the code shapes
around them are ours.

### Developer Forums

Thread numbers, with who answered:

| Thread | Subject | Answered by |
|---|---|---|
| **838329** | On-screen image hand-off; the `.files.file` recipe | **Another developer** (`J0hn`, marked recommended). Apple's DTS engineer deflected to Feedback Assistant, **FB23813341** |
| **837249** | On-screen awareness without a schema (hiking/cycling app) | **Nobody.** 0 replies, ~205 views |
| **829586** | App Intents vs App Schemas | Community, 14 replies, ~1k views. **FB23018652**, characterised by DTS as an enhancement request |
| **835903** | Raw internal error (`TypedValueToContentGraphResolutionErrorDomain error 4`) surfacing through Siri | Community report; no Apple acknowledgement located |
| **836760** | Foundation Models tied to Siri enablement | **Apple Frameworks Engineer** — confirmed it is a **bug** |
| **835211** | `SystemLanguageModel.default.availability` tied to Siri toggle | Nobody; corroborates 836760 |
| **775988** | `DynamicOptionsProvider` + search composition | Community; predates the 2026 work |

**The pattern is itself a finding.** Across this cluster there is one substantive Apple answer
(836760, and it was about Foundation Models availability rather than App Intents), one deflection
to Feedback Assistant, and otherwise silence. **The single most useful technical answer in the
cluster came from another developer.** Weight community findings accordingly — not because they are
strong evidence, but because in this area they are frequently the *only* evidence.

### Corpus files behind this guide

- `notes/web/app-intents-siri-schemas.md` (1,652 lines) — the domain enumeration, the docs
  quotations, the forum analysis
- `notes/transcripts/missing-sessions.md` (3,216 lines) — sessions 240, 343, 344, 345 with Apple's
  published code samples reproduced
- `notes/forums/forum-pain-points.md` (1,538 lines) — the thread inventory and the undocumented
  error/limit table
- `notes/CORRECTIONS-PENDING.md` — items C8, C10.3 and C10.6, applied in §8.2, §14.1 and §16
- `transcripts/wwdc2026-{240,343,344,345}.txt` — the raw session prose

[^app-dependency-registration]: Apple,
    [*Creating your first app intent*](https://developer.apple.com/documentation/appintents/creating-your-first-app-intent),
    §“Register dependencies to other parts of your code,” constructs one `NavigationModel`, stores
    it on the app, registers it with `AppDependencyManager.shared.add(dependency:)`, and later
    resolves it with `@Dependency`. The same-instance behavior is also stated in the authoritative
    [WWDC26 session 344 transcript, lines 53–56](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/transcripts/wwdc2026-344.txt#L53-L56).
[^file-identifier-drafts]: Apple,
    [`FileEntityIdentifier`](https://developer.apple.com/documentation/appintents/fileentityidentifier)
    and [`draft(identifier:)`](https://developer.apple.com/documentation/appintents/fileentityidentifier/draft%28identifier%3A%29),
    document draft identifiers for documents that are not yet materialized on disk and therefore
    have no file URL. The saved-file factory is separately documented as `file(url:)`.

### How to re-verify any row of §5

The fastest route, and it takes about thirty seconds per domain:

0. `grep '<Domain>Intent {' notes/sdk-interfaces/AppIntents-27.0-macos.swiftinterface` — the
   SDK census route this guide's 2026-07-29 pass used; each domain's marker-protocol extension
   lists every leaf accessor.
1. `https://sosumi.ai/documentation/appintents/app-schema-domain-<name>` — for the domain's
   inventory. Note the URL slugs that do not match the dot-syntax: `journaling` (not `journal`),
   `system-and-in-app-search` (not `system`).
2. `https://sosumi.ai/documentation/appintents/appschema/<domain>intent/<schemaname>` — for an
   individual schema's page.
3. In Xcode 27, type `<domain>_` and read the completion list. **This is the authoritative answer**
   and it is the only one that reflects the SDK you are actually building against.

Step 3 beats steps 1 and 2. Use this guide to know *what to look for*; use Xcode to know *what is
there*.

---

*Compiled 2026-07-28 from sources fetched 2026-07-27; re-verified 2026-07-29 against the macOS
26.5 and 27.0-beta SDK module interfaces in `notes/sdk-interfaces/`. Every schema identifier, API
name and quotation above traces to an SDK interface declaration, an Apple documentation page, an
Apple-published session code sample, or an Apple session transcript — or is explicitly marked 🟡
RECONSTRUCTED or 🔴 GAP. The §5 census, all ✅ SDK-verified markers, and the closure of register
entries G4, G5, G9, G15 and G17 date from the 2026-07-29 pass. Where the notes and the brief
disagreed, the notes won; where the interface and anything else disagreed, the interface won.*
