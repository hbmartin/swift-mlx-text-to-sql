# On-screen awareness: making Siri understand "this"

**Part 16 · Adjacent capabilities · Reference 03**

**Version floor: the 27 releases — iOS 27, iPadOS 27, macOS 27, watchOS 27, visionOS 27, with
Xcode 27.** The on-screen annotation surfaces that are new in this guide — the
`.appEntityIdentifier` view modifiers, `NSUserActivity.appEntityIdentifier`,
`displayRepresentations(for:requestedComponents:)`, `DisplayRepresentation.Components`, and the
entity-annotation properties on notifications, Now Playing and AlarmKit — come from WWDC26
sessions 240, 343 and 344, all of which frame themselves as *"the 27 releases."* Two things in
this guide are **older and must not be version-confused with them**: `EntityIdentifier` itself is
iOS 16 / macOS 13, while `FileEntityIdentifier` is iOS 18 / macOS 15 and already supports both
saved-file and draft identities.[^entity-identifier-api] `NSUserActivity` is a long-standing
Foundation type that is merely gaining a new property, and `Transferable` / `FileRepresentation` /
`SentTransferredFile` are **iOS 16-era Core Transferable** types that the 2026 recipe reuses
unchanged.

⚠️ **A version-label warning you will hit reading Apple's own material.** Session 345 says *"our
2027 releases"* three separate times; sessions 240 and 343 say *"the 27 releases."* These are the
same OS family named two ways — version number and marketing calendar year. It is **not** a claim
about a release after iOS 27. Corroboration: `BarcodeReaderTool` and `OCRTool`, announced at the
same conference, carry documented availability *"iOS 27.0+ Beta, macOS 27.0+ Beta."*

---

## What this covers

**This guide exists to answer two questions that Apple has not answered.**

Both are live threads on the Apple Developer Forums. Both are from working developers who followed
the documentation exactly. One got a reply from an Apple DTS engineer that routed the question to
Feedback Assistant **without answering it**. The other got zero replies in three weeks and 205
views. The one genuinely useful technical answer in the whole cluster came from **another
developer**, not from Apple.

- **Thread 837249** (haozes, 8 July 2026, 0 replies): a hiking/cycling app wants Siri to answer
  *"how much farther to the destination?"* mid-activity. The developer's custom `AppEntity` and
  `EntityQuery` **execute**, but Siri answers from on-screen text — *"Distance: 0.21 mi"* — and
  cannot see data on other tabs. Conclusion drawn: *"Siri seems to be reading the screen directly
  rather than retrieving data from the provided `AppEntity`."*
- **Thread 838329** (FrankSchlegel, 17 July 2026, 4 replies, radar **FB23813341**): an app renders
  an image on screen and wants *"send this to Bubbles"* to work. Plain custom `AppEntity` +
  `Transferable` + `.appEntityIdentifier` produces *"I can't attach the image directly from your
  screen."* The developer instrumented `entities(for:)` with a logger. **It never fired.**

Those two threads look like different problems. They are the **same** problem seen from two sides,
and the finding that unifies them is the most useful thing in this guide:

> **There are two on-screen paths, not one.** Descriptive requests — *"describe this"*, *"create a
> note for this"* — take a **screenshot / OCR** path and **never call your `entities(for:)`**.
> Only **hand-off** requests — *"send this to X"* — enter true entity resolution. Most developers
> debugging "Siri can't see my content" are **testing path 1 while instrumenting path 2**, and
> everything they observe is therefore uninformative.

Get that wrong and you can spend a week building entity plumbing for a request class that will
never consult it. That is exactly what happened in thread 837249.

Around that finding, this guide covers:

- **§1 — The two paths**, with the instrumented evidence table from thread 838329, a
  request-phrasing → path map, and a logging recipe that tells you in one utterance which path you
  are on.
- **§2 — `EntityIdentifier`**, the single type every mechanism in this guide routes through, and
  the five subsystems that consume it.
- **§3 — The four annotation shapes** — `NSUserActivity`, `.appEntityIdentifier(_:)`,
  `.appEntityIdentifier(forSelectionType:_:)`, and canvas annotation — with Apple's own selection
  rule, complete code for each, and the UIKit/AppKit equivalents.
- **§4 — `displayRepresentations(for:requestedComponents:)`**, the hot-path resolution hook, and
  the ⚠️ performance trap that turns on-screen awareness into a stall. This is the callout the
  session buries after the API tour and it is the most actionable item in the whole area.
- **§5 — The verified working hand-off recipe.** `@AppEntity(schema: .files.file)` +
  `FileEntityIdentifier.file(url:)` + **`FileRepresentation`** — not `DataRepresentation` —
  confirmed on device on iOS 27 by a developer who is not Apple. Draft identifiers can represent
  an unmaterialized document, but the verified transfer recipe still needs a real file payload;
  §5.5 separates identity from export and provides the write-out pattern.[^file-identifier-api]
- **§6 — Beyond the screen.** The same `EntityIdentifier` attaches to notifications, Now Playing
  and AlarmKit. Three surfaces, one pattern, one API asymmetry, one hard ban.
- **§7 — Adoption order** — Apple's own five-step prioritisation from session 343 — and a
  diagnostic playbook for when it does not work.
- **§8 — Eight silent failures.** None of them throw.
- **§9 — A complete worked integration** — entity, transfer representation, query, list screen,
  detail screen and notification, assembled from verified fragments.
- **§10–§12 — What is still open**, the gap register, and sources.

## What this does *not* cover

- **The schema domains themselves.** Which of the 23 domains exist, what each contains, which app
  categories have no domain at all, and `.system.searchInApp` as the escape hatch: all of that is
  [Part 16 guide 02](02-app-schema-domains.md). This guide assumes you have picked a domain or
  established that none applies. §5 leans hard on guide 02's discovery-versus-action framing and
  cites it rather than restating it.
- **Indexing.** `IndexedEntity`, `CSSearchableIndex.indexAppEntities(_:)`, `@Property(indexingKey:)`
  and the one-index/three-consumers architecture are
  [Part 16 guide 04](04-entities-spotlight-and-foundation-models.md). Indexing and on-screen
  awareness are **different mechanisms for different request classes** and confusing them is its
  own failure mode — §1.7 draws the line.
- **Query protocols in general.** `EntityStringQuery`, `IntentValueQuery`, `EnumerableEntityQuery`,
  `UniqueAppEntityQuery` and when to use each are guide 02 §10. This guide covers only the two
  `EntityQuery` requirements that on-screen awareness actually calls: `entities(for:)` and
  `displayRepresentations(for:requestedComponents:)`.
- **The new execution model.** `LongRunningIntent`, `ExecutionTargets`, `EntityCollection`,
  `@UnionValue`, `SyncableEntity`: guide 02 §13.
- **Foundation Models.** There is no `AppIntent`-to-`LanguageModelSession` bridge; the connection
  between your entities and your own on-device model runs through the Spotlight semantic index and
  `SpotlightSearchTool`, which is guide 04 and
  [Part 2 guide 04](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md).

## What you need

- **A device, not the Simulator.** Every observation in §1 and §5 was made on device. The Siri
  surfaces this guide describes have no Simulator story we could verify, and the Foundation Models
  corpus already documents a broad class of Simulator-only phantom failures in this stack
  ([Part 1 guide 02](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/references/02-platform-and-version-gating.md)).
- **Apple Intelligence enabled**, with the caveat that on current 27 betas its availability
  reporting is itself buggy — see correction **C1** in the series register: an Apple Frameworks
  Engineer confirmed on forum thread 836760 that `SystemLanguageModel.default.availability`
  returning `.appleIntelligenceNotEnabled` when Siri is switched off is **a bug, not the design**.
  Do not build permanent UX around it.
- **At least one `AppEntity` with a real `EntityQuery`.** On-screen awareness annotates entities;
  it does not create them. If you have not modelled your content as entities yet, start at guide 02.
- **A schema, if you intend to do anything other than reference.** §5 is blunt about why.
- **`import AppIntents`** everywhere, plus `SwiftUI` or `UIKit`/`AppKit` for annotation,
  `CoreTransferable` for hand-off, and `UserNotifications` / `NowPlaying` / `AlarmKit` for §6.

---

## ⚠️ Read this before you trust a symbol name below

Three things about the evidence in this guide, because the evidence quality here is unusually
uneven and pretending otherwise would make the guide dangerous.

**First: there is no sample-code project for this topic in our corpus.** The strongest evidence
class in this series — a compiling first-party Apple sample — does not exist for on-screen
awareness. Sessions 343 and 240 name three sample apps (**CosmoTunes**, **UnicornChat**,
**CometCal**) and Apple publishes them, but they were not obtained. So the top of the evidence
ladder here is **Apple's own published code-sample blocks on the session pages**, which are
verbatim Apple text but are excerpts, not projects. Anything marked ✅ VERIFIED with a
`@ <timestamp>` citation is one of those blocks.

**Second: the single most actionable recipe in this guide is community evidence, and we are not
going to dress it up.** The `.files.file` hand-off in §5 comes from forum thread 838329, posted by
a developer (`J0hn`), marked as the recommended answer, and reported as *confirmed working on
device on iOS 27*. It is **not** in Apple's documentation. Apple's own documentation points a
different direction. We lead with it anyway, because it is the only route anyone has reported
working — and we say exactly where it came from every time it appears.

**Third: the architectural question underneath §5 is open, and Apple deflected it.** The developer
who found the problem asked whether custom `AppEntity` + `Transferable` is *supposed* to work.
Apple's DTS engineer replied by routing the whole thread to Feedback Assistant without answering.
Meanwhile Apple's documentation says schema application is *"optional but recommended,"* which
contradicts the observed behaviour. Both statements appear in §5.7, side by side, unreconciled.
That is the honest state of this API and it is more useful to you than a confident answer would be.

Markers used throughout:

> ✅ **VERIFIED** — quoted from an Apple documentation page, an Apple-published code sample on a
> WWDC26 session page, a session transcript, or a forum post. The citation follows the claim.
>
> 🟡 **RECONSTRUCTED** — the concept is attested but the exact spelling is inferred, usually
> because it reached us through narration or summarisation rather than published text.
>
> 🔴 **GAP** — could not verify. The box says what is unknown, what would resolve it, and what to
> ship in the meantime. A gap box in this series never contains a guess.
>
> ⚠️ **SILENT FAILURE** — it does not throw, it does not log, and the symptom appears somewhere
> other than where the defect is. This guide has eight; they are collected in §8.

**Measurement attribution.** There is exactly one quantitative claim available for this entire
topic and it is qualitative: session 343 says that if Siri cannot understand your on-screen
entities *"quickly enough"* it may ask to clarify or act on the wrong thing. **No latency budget,
no timeout value, and no benchmark is published by Apple for on-screen entity resolution, and we
have no community measurement of one either.** Every performance statement in §4 is therefore
mechanism-based, not number-based, and says so.

---

## Contents

1. [The two paths — the finding that explains everything](#1-the-two-paths)
2. [`EntityIdentifier` — the one type everything routes through](#2-entityidentifier)
3. [The four annotation shapes](#3-the-four-annotation-shapes)
4. [Fast resolution, and the performance trap](#4-fast-resolution)
5. [Handing content to another app — the verified recipe](#5-handing-content-to-another-app)
6. [Beyond the screen — notifications, Now Playing, AlarmKit](#6-beyond-the-screen)
7. [Adoption order and the diagnostic playbook](#7-adoption-order-and-the-diagnostic-playbook)
8. [Silent failures](#8-silent-failures)
9. [A complete worked integration](#9-a-complete-worked-integration)
10. [What is still open](#10-what-is-still-open)
11. [Gap register](#11-gap-register)
12. [Sources](#12-sources)

---

## 1. The two paths

<a name="1-the-two-paths"></a>

Start here. Everything else in this guide is downstream of this section, and if you read only one
section, read this one.

### 1.1 What you get with zero adoption

Before any of the APIs in this guide, Siri already has *some* awareness of your screen. Session 343
states the baseline precisely, and the sentence is worth reading twice because it is simultaneously
more generous and more limited than most developers assume:

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"When people start a Siri request, Siri has an
> understanding of text on screen, **but it's limited to exactly what's in the pixels**. For
> example, Siri **can't act on** the tracks shown, and it **may not be able to tell you about the
> artist** because the artist isn't currently shown on screen."*

Unpack that into three consequences:

1. **Text that is rendered is readable.** You do not have to do anything for Siri to be able to
   read a label that is on screen. This is why the hiking app in thread 837249 got answers at all:
   Siri read *"Distance: 0.21 mi"* off the view.
2. **Nothing off-screen exists.** A property your entity has but your view does not render is
   invisible. Thread 837249's developer found exactly this: heart rate and average speed lived on
   other tabs, and Siri could not reach them.
3. **Nothing is actionable.** Pixels are not references. Siri cannot *do* anything to a thing it
   only saw as text.

What adoption buys is stated just as precisely:

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"Adopting onscreen awareness APIs provides Siri with
> additional context of **what entities are on screen, and where they are on screen**."*

Note both halves: **what**, and **where**. The *where* is why §3.5's canvas annotation carries
bounds, and why spatial phrasing — *"the third one"*, *"the one at the top"* — is a supported
request shape rather than a coincidence.

### 1.2 The instrumented evidence

Here is the finding. A developer instrumented `EntityQuery.entities(for:)` with a logger and drove
Siri through five different request shapes against the same annotated screen, on **iOS 27 beta 3**.

> ✅ **VERIFIED (community, forum thread 838329, FrankSchlegel, 17 July 2026)** — reported on
> device, iOS 27 beta 3. Hardware model not stated in the thread. For reference, our forum corpus
> records iOS 27 beta 3 as build **24A5380h**, released **6 July 2026**.

| Request | Path taken | Evidence observed |
|---|---|---|
| *"Describe this image"* | **Screenshot / OCR** | Responses referenced app **UI chrome**; `entities(for:)` **never called** |
| *"Create a note for this"* | **Screenshot / OCR** | same |
| *"Send this to \<contact\>"* | **Entity resolution** — failed for the custom entity | Siri: *"I can't attach the image directly from your screen"* |
| Hand-off to ChatGPT | **Entity resolution** — fired, then stalled | `entities(for:)` **was called**; Siri then said *"could not clarify what you mean"* |
| Old `NSUserActivity.appEntityIdentifier` route | **Never consumed at all** | no callbacks of any kind |

Two operational takeaways, and they are the thesis of this guide:

> **Descriptive on-screen questions do not consult your entities at all. They screenshot.**
>
> **Only hand-off style requests enter entity resolution.**

The tell in row 1 is the detail that makes this conclusive rather than suggestive: the responses
*referenced app UI chrome*. A model reasoning over your `AppEntity` would describe your content. A
model reasoning over a screenshot describes your toolbar, too, because the toolbar is in the
pixels. That is not a system that failed to find your entity. That is a system that never looked.

### 1.3 Why this explains thread 837249 completely

Now re-read the hiking app's report with the two-path finding in hand.

> ✅ **VERIFIED (community, forum thread 837249, haozes, 8 July 2026, 0 replies)** — a
> hiking/cycling app wants Siri to answer, mid-activity: *"How much farther to the destination?"*,
> *"How far have I already gone?"*, *"How much elevation gain is left?"* Observed: Siri
> **executed** the custom `EntityQuery` (`ToobooWorkoutSessionQuery`) but did not use the
> `AppEntity` data; it read visible on-screen text — *"Distance: 0.21 mi"*, *"Remaining Distance:
> 0.14 mi"* — from the current tab only, and could not reach heart rate or average speed on other
> tabs.

Every one of those utterances is **descriptive**. Not one is a hand-off. So every one of them took
the screenshot path, and the entity plumbing this developer built was never going to be consulted
for any of them — which is why the data on other tabs stayed invisible no matter how correctly the
entities were modelled. The observation that the `EntityQuery` "executed" is not a contradiction:
queries run for other reasons (Spotlight, Shortcuts, parameter resolution), and seeing your query
fire *at some point* is not evidence that it fired *for this request*.

The developer's own diagnosis — *"Siri seems to be reading the screen directly rather than
retrieving data from the provided `AppEntity`"* — is correct. It was correct in July 2026 and
nobody from Apple confirmed it. This guide is confirming it, from a second, independent,
instrumented thread.

There is a second, structural half to that thread's problem, and it belongs to guide 02: **there is
no fitness or workout schema domain.** `.maps` covers starting and stopping navigation and has no
schema for *querying progress*. So even if this developer had been on the entity path, there was no
schema to adopt. See [guide 02 §6](02-app-schema-domains.md) for the full absence list and
[§8](02-app-schema-domains.md) for `.system.searchInApp`, which is the one reachable hook for an
app in an unmodelled category.

### 1.4 The request-phrasing map

You cannot control what a user says. You can predict which path each phrasing lands on, and you
should design your adoption around the ones that reach your code.

| User says | Class | Path | Does your entity code run? |
|---|---|---|---|
| *"Describe this"* | descriptive | screenshot / OCR | **No** |
| *"What does this say?"* | descriptive | screenshot / OCR | **No** |
| *"Summarise this"* | descriptive | screenshot / OCR | **No** (inferred from the two verified descriptive rows) |
| *"Create a note for this"* | capture | screenshot / OCR | **No** |
| *"Send this to \<contact\>"* | hand-off | entity resolution | **Yes** |
| *"Email the people in this event"* | hand-off | entity resolution | **Yes** (session 344 demo utterance) |
| *"Open that third event"* | reference + action | entity resolution | **Yes** (session 344 demo utterance) |
| *"Play the third one"* | reference + action | entity resolution | **Yes** (session 343's motivating example for §4) |
| *"Play the live version"* | reference via Now Playing | entity resolution | **Yes** (session 343 §6) |
| *"Snooze it"* | reference via AlarmKit | entity resolution | **Yes** (session 343 §6) |

> 🟡 **RECONSTRUCTED — the class boundary, not the rows.** The two descriptive rows and the two
> hand-off rows in the top block are verified from thread 838329's instrumentation. *"Summarise
> this"* is our extrapolation from the pattern, not an observation, and is marked as such. The
> demo utterances are verified as utterances Apple showed working; that they take the entity path
> is inference from the fact that they resolve a specific entity by ordinal or by relationship,
> which OCR cannot do.

The pattern that falls out: **if the request needs to identify a specific object in order to act on
it or move it, it takes the entity path. If the request only needs to read the screen, it does
not.** Ordinal reference (*"the third one"*), relational reference (*"the people in this event"*)
and cross-app movement (*"send this to…"*) are all in the first group. Reading, describing,
summarising and capturing are in the second.

### 1.5 Why Apple built it this way (and why that is not a complaint)

It is worth spending a paragraph on the design, because understanding it stops you from filing the
wrong bug.

The screenshot path is **universal**. It works for every app on the system with zero adoption,
including apps whose developers have never heard of App Intents. For *"describe this"*, that is
exactly the right trade: the user wants a description of what they are looking at, the pixels are
what they are looking at, and consulting an app-specific entity model would make the feature work
for 1% of the screens on the device instead of 100%.

The entity path is **precise**. It can name a specific object, carry it across an app boundary, and
survive the object scrolling out of view. It cannot work without adoption, which is why it is the
path Apple's sessions spend twenty minutes on.

So the split is a coverage-versus-precision trade, and both halves are load-bearing. The problem is
purely that **Apple never documents which requests take which path**, so a developer forms a single
mental model — "Siri sees my screen" — that is true for both paths and predictive of neither.

### 1.6 The diagnostic: find out which path you are on in one utterance

Do this before you change any code. It takes five minutes and it is the difference between fixing
the problem and rewriting a subsystem that was never involved.

```swift prelude:guide-context
// ✅ VERIFIED shape (the logging pattern is from forum thread 838329's instrumentation;
//    EntityQuery.entities(for:) is the standard App Intents requirement)
// Pre-2026 API: os.Logger is iOS 14+.

import AppIntents
import os

private let siriLog = Logger(
    subsystem: "com.example.MyApp",
    category: "onscreen-awareness"
)

struct TrackEntityQuery: EntityQuery {

    func entities(for identifiers: [TrackEntity.ID]) async throws -> [TrackEntity] {
        // The single most informative log line you can add to an App Intents integration.
        siriLog.notice("entities(for:) CALLED with \(identifiers.count, privacy: .public) id(s)")

        let results = try await TrackStore.shared.tracks(withIDs: identifiers)

        siriLog.notice("entities(for:) RETURNING \(results.count, privacy: .public) entity(ies)")
        return results
    }
}
```

Then, on device, with the app in the foreground on the screen you care about, say each of these in
turn and watch the log:

1. *"Describe this."*
2. *"Send this to \<a contact\>."*

Interpret as follows:

| Log behaviour | What it means | Where to go next |
|---|---|---|
| Silent for (1), fires for (2) | **Working as designed.** You are seeing the two paths. | §3 and §5. Your annotation is being consulted. |
| Silent for both | Your annotation is not reaching the system, **or** you are on a non-schema entity (§5.3) | §3 first, then §5.3 |
| Fires for (1) | Not something we have observed. Please treat your own logs as authority over this guide. | §10.3 |
| Fires for (2), returns entities, Siri still fails | You are past resolution and stuck in **transfer**. | §5 — this is the `FileRepresentation` problem |

That last row is the important one and it is the exact state thread 838329's ChatGPT hand-off row
documents: `entities(for:)` fired and Siri still could not complete, because resolution and
transfer are two separate mechanisms and only the first one was working.

### 1.7 On-screen awareness is not indexing, and the two are not substitutes

One more distinction to fix before the API tour, because it is the second most common conflation
after the two paths.

| | On-screen awareness | Indexing |
|---|---|---|
| Question it answers | *"What does **this** refer to right now?"* | *"Which of my things is the user talking about?"* |
| Mechanism | `EntityIdentifier` attached to a view, activity, notification or alarm | `IndexedEntity` + `CSSearchableIndex.indexAppEntities(_:)` |
| Scope | The current screen (plus scrolled-off rows, §3.4) | Your whole corpus |
| Lifetime | As long as the view is on screen | Until you delete the index entry |
| Needed for | *"send **this** to…"*, *"play the **third** one"* | *"show the messages with Flare about movies"* |
| Guide | This one | [Guide 04](04-entities-spotlight-and-foundation-models.md) |

They compose: an entity that is both indexed and annotated can be found by description *and*
referred to as "this". They do not substitute: indexing a thousand entities does not make the one
on screen referenceable, and annotating the screen does not make anything findable when the app is
closed.

Session 343's adoption order (§7.1) puts indexing **before** annotation, and that ordering is
deliberate — indexing serves more request classes for less work.

---

## 2. `EntityIdentifier`

<a name="2-entityidentifier"></a>

Everything in §3, §5 and §6 routes through one type. Learn it once and the four annotation shapes
stop looking like four APIs and start looking like four *places to put the same value*.

### 2.1 The initializer

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 343 @ 16:27; and WWDC26 240 @ 17:19)
EntityIdentifier(for: SongEntity.self, identifier: track.id)
```

Two arguments:

- **`for:`** — the **metatype** of your `AppEntity`. Not an instance. This is what tells the system
  *which* entity type to route the identifier to, and therefore which `EntityQuery` to call.
- **`identifier:`** — the entity's `ID` value.

The `identifier:` parameter is **generic over your entity's `ID` type**, and Apple's own samples
prove it by passing different things:

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 343 @ 16:27) — a String
EntityIdentifier(for: AlbumEntity.self, identifier: session.id.uuidString)

// ✅ VERIFIED (Apple code sample, WWDC26 343 @ 16:27) — whatever `.id` is, unconverted
EntityIdentifier(for: SongEntity.self, identifier: playback.currentTrack.id)
```

`AlbumView` passes `session.id.uuidString` — a `String`. `NowPlayingView` passes
`playback.currentTrack.id` directly, unconverted. So there is no requirement to stringify, and no
requirement not to. **Pass the same value your `EntityQuery.entities(for:)` expects to receive**,
because that is precisely what it will receive.

> ⚠️ **The most likely way to get this wrong.** If your entity's `ID` is a `UUID` but you annotate
> with `uuidString`, `entities(for:)` gets called with `String`s it cannot match, returns an empty
> array, and Siri quietly moves on. There is no type error, because both spellings compile against
> a generic parameter. §8.4 covers the symptom.

### 2.2 What consumes it

Session 343 makes an argument for why this type is worth the adoption cost, and it is the best
one-line summary of the App Intents strategy anywhere in the four sessions:

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"your app entities act as a **universal language**.
> They let Siri understand not just what's on screen, but how **other system integrations and
> time-sensitive events** relate to your content."*

Concretely, one `EntityIdentifier` value is accepted by at least six different hosts:

| Host | Property / parameter | Cardinality | Section |
|---|---|---|---|
| `NSUserActivity` | `.appEntityIdentifier` | **singular** | §3.2 |
| SwiftUI view | `.appEntityIdentifier(_:)` | singular | §3.3 |
| SwiftUI collection | `.appEntityIdentifier(forSelectionType:_:)` | one per selection ID | §3.4 |
| `UNMutableNotificationContent` | `.appEntityIdentifiers` | **array** | §6.1 |
| `MusicContent` (Now Playing) | `.appEntityIdentifiers` | **array** | §6.2 |
| `AlarmManager.AlarmConfiguration` | `appEntityIdentifier:` | **singular** | §6.3 |

> ✅ **VERIFIED (Apple code samples, WWDC26 343 @ 16:27 and @ 21:07)** for every row except the
> collection row's cardinality, which follows from the closure signature rather than from a stated
> claim.

**The singular/plural split is a real API asymmetry and it is not arbitrary.** Where the host
represents one thing (a user activity, an alarm), you supply one identifier. Where the host
represents a situation that several entities are simultaneously relevant to (a notification about a
message in a conversation; a track that belongs to an artist and a playlist), you supply an ordered
array. §6.2 covers why the *order* of that array is semantic.

### 2.3 The verified `EntityIdentifier` surface

The current reference resolves the earlier API-shape questions. `EntityIdentifier` is a
`Hashable`, `Sendable` value available from iOS 16 / macOS 13. It exposes `entityType` and the
string-form `identifier`, and supplies both `init(for: Entity)` and
`init(for: Entity.Type, identifier: Entity.ID)`.[^entity-identifier-api] It is not documented as
`Codable`, so do not treat `Sendable` as permission to persist it; persist your entity's own stable
ID and reconstruct the wrapper at the integration boundary.

### 2.4 The one thing `EntityIdentifier` does *not* do

It is a **reference**, not a **payload**. Annotating a view with an `EntityIdentifier` tells the
system *which of your entities this pixel region is*. It does not move any bytes anywhere.

That distinction is the whole of §5, and it is where the documentation and the observed behaviour
part company. Reference and transfer are separate mechanisms with separate requirements, and a
correct reference with no transfer representation produces the single most confusing failure in
this area: Siri identifies the right thing and then says it cannot do anything with it.

---

## 3. The four annotation shapes

<a name="3-the-four-annotation-shapes"></a>

Four APIs. One selection rule. Apple states both.

### 3.1 The selection rule

> ✅ **VERIFIED (transcript, WWDC26 343)** — the four APIs and the criterion for each:

| API | Use when | Apple's example view |
|---|---|---|
| **`NSUserActivity`** (`.userActivity` modifier) | *"the view representing your **primary** onscreen content"* — one dedicated thing | `NowPlayingView` |
| **View entity annotation** (`.appEntityIdentifier(_:)`) | *"when the entity is **one item among many** on screen"* | `AlbumView` — *"because both the album and the containing tracks are visible"* |
| **Collection annotation** (`.appEntityIdentifier(forSelectionType:_:)`) | lists and collections displaying many entities | `PlaylistDetailView` |
| **Custom canvas view annotation** | non-standard drawn subviews | `PianoRollView` |

And Apple's own advice about where to start:

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"When adopting onscreen awareness, the
> **`NSUserActivity` and View Annotation APIs are where you should start**."*

Session 344, the code-along, reduces this to a slogan that is worth quoting to a sceptical
teammate:

> ✅ **VERIFIED (transcript, WWDC26 344)** — *"**that's onscreen awareness… and it takes just two
> view modifiers.**"* … *"**Seriously… two modifiers… that's all it takes** to connect what's on
> screen to the app's content."*

The two modifiers in question are the collection form on the list screen and `.userActivity` on the
detail screen. That is the minimum viable adoption for a standard master–detail app, and it is
genuinely small.

### 3.2 Shape (a): one primary item — `NSUserActivity`

Use when the screen is *about* one thing: a document, a now-playing track, a message being
composed, an event detail view.

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 343 @ 16:27) — verbatim structure
import AppIntents
import SwiftUI

struct NowPlayingView: View {
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        VStack {
            // Player UI
        }
        .userActivity("cosmotunes.nowPlaying", isActive: playback.currentTrack) { activity in
            activity.title = playback.currentTrack?.title
            activity.appEntityIdentifier = EntityIdentifier(
                for: SongEntity.self,
                identifier: playback.currentTrack.id
            )
        }
    }
}
```

Three things to notice, all of which matter:

**The activity type string is yours.** `"cosmotunes.nowPlaying"` is an app-defined reverse-DNS-ish
identifier, the same as any `NSUserActivity` activity type. It is not a system constant.

**`isActive:` gates the annotation.** Apple's sample passes `playback.currentTrack` — an optional —
into a parameter that reads as a `Bool`. That is not a typo we can resolve from the sample alone; it
is how the sample is published. Treat the *intent* as verified (the activity should be active only
while there is a current track) and the *exact expression* as something to let the compiler settle
in your own code.

**`activity.appEntityIdentifier` is singular.** One activity, one entity. If your screen genuinely
has two co-equal primary entities, it is not a primary-entity screen; use shape (b) for both.

> ✅ **VERIFIED (transcript, WWDC26 344)** — the detail-view rationale: *"This tells the system that
> **one specific event is front and center** so Siri can resolve this event to exactly the one being
> viewed."*

⚠️ **A conflict you should know about before you rely on this shape.** Forum thread 838329's
instrumentation lists the `NSUserActivity.appEntityIdentifier` route as *"never consumed at all —
no callbacks"* on iOS 27 beta 3. Sessions 343 and 344 both teach it as a first-class route and 343
recommends it as one of the two places to start. **These cannot both be describing correct
behaviour.** Our reading is that the forum observation is a beta defect or a mis-set activity, not
an API statement — one developer's negative result against two Apple sessions and a published code
sample. But it is a real, dated, on-device observation from a developer who instrumented everything
else correctly, and you deserve to know it exists before you spend a day on this shape. See §8.6
and 🔴 GAP G6.

### 3.3 Shape (b): one entity among many — `.appEntityIdentifier(_:)`

Use when several meaningful entities are visible at once and one of them is *this particular
subview*.

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 343 @ 16:27) — verbatim structure
import AppIntents
import SwiftUI

struct AlbumView: View {
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Album title, artwork, artist…
        }
        .appEntityIdentifier(
            EntityIdentifier(for: AlbumEntity.self, identifier: session.id.uuidString)
        )
    }
}
```

Apple's stated reason for choosing this shape here is worth internalising because it generalises:

> ✅ **VERIFIED (transcript, WWDC26 343)** — the album view uses view annotation *"because both the
> album and the containing tracks are visible"*.

The screen shows an album **and** its tracks. Neither is "the" primary entity. So the album header
gets its own annotation, and the track list gets a collection annotation (shape (c)). Both live on
the same screen, at different levels of the view tree, and the system resolves *"this album"* and
*"the third track"* against different annotations.

**Apply it to the smallest view that visually corresponds to the entity.** The bounds of the
annotated view are what let the system reason about *where* the entity is (§1.1), so annotating a
whole `VStack` that happens to contain the album header is right; annotating the entire screen is
not.

### 3.4 Shape (c): lists and collections — `.appEntityIdentifier(forSelectionType:_:)`

This is the shape most apps need most often, and it is the one whose *absence* causes the subtlest
bug in this guide.

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 343 @ 16:27) — verbatim structure
import AppIntents
import SwiftUI

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

The modifier takes two things: a **selection-ID metatype** and a **closure** mapping each selection
ID to an `EntityIdentifier`. Note the two different types in play — `GeneratedTrack.ID` is the
*model's* identifier type, `SongEntity` is the *entity* type. The closure is where you cross from
one to the other, and it is the only place in the four shapes where that mapping is explicit.

Apple gives two distinct benefits, and both are non-obvious:

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"Collection annotations help me avoid the overhead of
> attaching an annotation to every single row. Instead, **the system fetches identifiers lazily, as
> it needs them**. Collection annotations **also let Siri discover entities that have been selected
> and scrolled off screen. Per row annotations disappear as soon as the view leaves the view
> hierarchy.**"*

**Benefit 1 — laziness.** The closure is called when the system needs an identifier, not once per
row at render time. For a thousand-row list this is the difference between a thousand
`EntityIdentifier` constructions on every layout pass and zero.

**Benefit 2 — scroll-off survival.** SwiftUI recycles rows. A per-row `.appEntityIdentifier` inside
a `ForEach` is destroyed when the row leaves the view hierarchy, taking the annotation with it.
The collection form is attached to the *list*, not the row, so it outlives scrolling.

⚠️ **This is the trap.** Session 240 — the overview session — publishes a code sample that does
exactly the per-row thing:

```swift illustrative
// ✅ VERIFIED (Apple code sample, WWDC26 240 @ 17:19) — the SIMPLE form.
// Correct for a short static list; WRONG for anything scrollable with selection.
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

Both samples are Apple's. **240 shows the simple form; 343 shows the correct form for lists where
selection or scrolling matters.** 343 is the later, more specific session and it explicitly warns
about the pattern 240 demonstrates. Prefer 343's. Full silent-failure treatment in §8.2, and the
same correction appears in [guide 02 §14.3](02-app-schema-domains.md).

A user selects a track, scrolls down forty rows, and says *"send that one to Glow."* With per-row
annotation, the annotation for the selected track no longer exists. Siri has nothing to resolve.
The user gets a clarification prompt or the wrong track — and your logs show nothing, because
nothing failed.

### 3.5 Shape (d): custom canvases — `AppEntityUIElement`

This is the shape with the weakest evidence in the guide, and the honest thing to do is tell you
that before the code rather than after.

**What is solidly attested.** Session 343 names a fourth category — *"custom canvas view
annotation"* for *"non-standard drawn subviews"* — and points at **`PianoRollView`** in the
CosmoTunes sample as the worked example. The UIKit side names a symbol,
**`appEntityUIElementProvider`**. Both of those come from the session.

**What is not.** Apple's published code-sample block for session 343 contains three canvas-free
samples — `NowPlayingView`, `AlbumView`, `PlaylistDetailView` — and **no canvas sample**. The
`AppEntityUIElement` initializer shape below reached our corpus through a documentation-and-session
synthesis pass rather than through a verbatim Apple code block, so its spelling is inferred.

```swift prelude:guide-context
// 🟡 RECONSTRUCTED — the concept is attested (session 343, "custom canvas view annotation",
//    PianoRollView); this exact initializer spelling is NOT from an Apple code sample.
//    Verify against Xcode completion before typing it into a real project.
AppEntityUIElement(
    identifier: EntityIdentifier(for: StickyNote.self, identifier: note.id),
    bounds: note.frame,
    state: State(isSelected: note.isSelected)
)
```

The **structure** is the part worth taking away, and it is a genuine capability rather than a
spelling: a canvas annotation carries three things where the other shapes carry one.

| Component | Why the other shapes do not need it |
|---|---|
| **identifier** | same as everywhere — which entity this is |
| **bounds** | a `Canvas` or custom-drawn view has no subview per item, so the system cannot derive a frame from the view tree |
| **selection state** | in a freeform editor, "selected" is app state, not a `List` selection the system can observe |

That is why this shape exists at all. In a `List`, SwiftUI already knows where each row is and what
is selected. In a piano roll, a whiteboard, a map overlay or a node graph, **only your app knows**,
and the annotation has to carry it.

> 🔴 **GAP G4 — the canvas annotation API.**
>
> **What is unknown:** the exact spelling of `AppEntityUIElement`'s initializer, the type of
> `bounds` (`CGRect`? a SwiftUI `CGRect` in which coordinate space?), the name and shape of the
> selection-state type (the `State(isSelected:)` above is the shakiest token in this guide — it
> collides with SwiftUI's `State` property wrapper, which alone makes it suspect), and the SwiftUI
> modifier that consumes an array of them. Our corpus records it as `appEntityUIElements(_:)`, also
> unverified.
>
> **What would resolve it:** the **CosmoTunes sample project**, which Apple publishes and which
> contains `PianoRollView` — session 343 names it explicitly. Downloading that sample would move
> this entire subsection from 🟡 to ✅ in one step. Failing that, the
> `/documentation/appintents/appentityuielement` page or an SDK interface dump.
>
> **Safe default:** if your content is a list, a grid, or a view hierarchy with one subview per
> item, **use shapes (b) and (c) and do not go near this**. They are fully verified and they cover
> the overwhelming majority of screens. Reach for canvas annotation only when you genuinely draw
> your items, and when you do, let Xcode completion tell you the spelling rather than this guide.

### 3.6 UIKit and AppKit

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"UIKit and AppKit also support all of the onscreen
> awareness APIs. Check out the documentation for: **`AppEntityAnnotatable`**,
> **`UICollectionViewAppIntentsDataSource`**, and **`appEntityUIElementProvider`**."*

Three symbols named in the session. Our documentation pass additionally records a fuller set:

| Symbol | Evidence | Maps to |
|---|---|---|
| `AppEntityAnnotatable` | ✅ named in session 343 | the protocol behind responder-object annotation |
| `appEntityIdentifier` property on responder objects | 🟡 from the docs pass, not the session | shape (b) |
| `appEntityUIElementProvider` closure property on views | ✅ named in session 343 | shape (d) |
| `UICollectionViewAppIntentsDataSource` | ✅ named in session 343 | shape (c) |
| `UITableViewAppIntentsDataSource` | 🟡 from the docs pass | shape (c) |
| `NSTableViewAppIntentsDataSource` | 🟡 from the docs pass | shape (c), AppKit |
| `NSCollectionViewAppIntentsDataSource` | 🟡 from the docs pass | shape (c), AppKit |

The one UIKit call site anyone has published in full is **not** from Apple. It is from forum thread
838329, and it is the collection-view entry point:

```swift illustrative
// ✅ VERIFIED (community, forum thread 838329 — part of the recipe reported working on
//    device on iOS 27). Placeholders <URL> and <ENTITY> are as posted.
public func collectionView(
    _ collectionView: UICollectionView,
    appEntityIdentifierForItemAt indexPath: IndexPath
) -> EntityIdentifier? {
    guard let item = dataSource?.itemIdentifier(for: indexPath) else { return nil }
    guard let fileIdentifier = try? FileEntityIdentifier.file(url: <URL>) else { return nil }
    return EntityIdentifier(for: <ENTITY>.self, identifier: fileIdentifier)
}
```

Read the shape of that method carefully, because it tells you how UIKit's version of shape (c)
works: **`collectionView(_:appEntityIdentifierForItemAt:)` returns an optional `EntityIdentifier`
for a given index path.** That is the lazy, per-item pull the SwiftUI collection modifier's closure
also implements — the system asks for the identifier of item N when it needs item N, rather than
you pushing all of them up front. Returning `nil` is a supported answer for items with no entity.

Session 343 also gives a cross-reference for UIKit adopters: *"Modernize your UIKit app"* — *"to
learn more about how these entity annotations help power **contextual menu items** in UIKit apps."*
So the same annotations feed context menus, which is a second payoff for the same work.

> 🔴 **GAP G5 — the AppKit/UIKit data-source protocol requirements.**
>
> **What is unknown:** we have one method signature, from a forum post, on a delegate whose
> declaring protocol is not stated. `UICollectionViewAppIntentsDataSource`'s other requirements,
> the `UITableView`/`NSTableView`/`NSCollectionView` equivalents' method names, and whether
> `AppEntityAnnotatable` is what the responder-object `appEntityIdentifier` property hangs off, are
> all unverified.
>
> **What would resolve it:** the four data-source pages under `/documentation/appintents/`, or an
> SDK interface dump.
>
> **Safe default:** implement `collectionView(_:appEntityIdentifierForItemAt:)` — it is the one
> signature anyone has reported working — and let the compiler tell you which protocol it wants you
> to declare conformance to.

### 3.7 A complete two-screen adoption

Here is the whole of §3 assembled into the minimum viable adoption Apple's code-along describes:
collection annotation on the list screen, `NSUserActivity` on the detail screen.

```swift prelude:guide-context
// Composition of two ✅ VERIFIED Apple code samples (WWDC26 343 @ 16:27) applied to one app.
// The entity and query are ordinary App Intents; see guide 02 for the schema decision.

import AppIntents
import SwiftUI

// MARK: - The entity

@AppEntity(schema: .audio.song)
struct TrackEntity {
    var id: UUID
    var title: String
    var artistName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(artistName)"
        )
    }
}

// MARK: - The list screen — shape (c)

struct TrackListView: View {
    let tracks: [Track]

    var body: some View {
        List {
            ForEach(tracks) { track in
                TrackRow(track: track)
            }
        }
        // ONE annotation on the list, not one per row.
        // Lazy, and survives selection + scroll-off.
        .appEntityIdentifier(forSelectionType: Track.ID.self) { trackID in
            EntityIdentifier(for: TrackEntity.self, identifier: trackID)
        }
    }
}

// MARK: - The detail screen — shape (a)

struct TrackDetailView: View {
    let track: Track

    var body: some View {
        ScrollView {
            // Artwork, title, credits…
        }
        .userActivity("com.example.MyApp.trackDetail", isActive: true) { activity in
            activity.title = track.title
            activity.appEntityIdentifier = EntityIdentifier(
                for: TrackEntity.self,
                identifier: track.id
            )
        }
    }
}
```

Utterances this enables, per sessions 343 and 344's own demos:

- On the list: *"play the third one"*, *"send that one to Glow"*, *"open that third event"*
  (344's phrasing for the analogous calendar list).
- On the detail: *"send this to Bubbles"*, *"email the people in this event"* (344).

And the adoption cost, from Apple's code-along, worth quoting to whoever is scheduling the work:

> ✅ **VERIFIED (transcript, WWDC26 344)** — *"**Not bad for three structs and filling out a few
> code snippets, right?**"* (for an entire content layer of three entities) and *"**Seriously… two
> modifiers… that's all it takes** to connect what's on screen to the app's content."*

That claim is about **reference**, and it is fair. It is not about **transfer**, which is §5, and
which is where the cost estimate falls apart.

---

## 4. Fast resolution

<a name="4-fast-resolution"></a>

You have annotated a screen with forty entities. A user says *"play the third one."* Something now
has to decide, quickly, which of your forty entities the user means — and "quickly" is doing
enormous work in that sentence.

This section is the one that turns a working integration into a good one, and a naive
implementation of it into a stall.

### 4.1 Why this hook exists

Session 343 introduces it with a consequence rather than an API, which is unusual for Apple and
tells you they have watched this go wrong:

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"After adopting onscreen awareness, some of the app's
> views show many entities at once. Siri needs to **quickly** understand if the on-screen entities
> relate to a request. For example, someone asks Siri to play the third one. **If Siri can't
> understand my on-screen entities quickly enough, it may ask to clarify or play something else
> entirely. People can abandon the request when that happens.**"*

Read the failure mode carefully, because it is not "an error appears":

1. Siri asks the user to clarify — the interaction that on-screen awareness exists to eliminate; or
2. Siri acts on **something else entirely** — a wrong-action bug that looks like a resolution bug; or
3. The user **abandons the request** — which shows up in your analytics, if at all, as a
   feature nobody uses.

None of those produce a log line in your app. All of them are caused by your code being slow.

### 4.2 ⚠️ SILENT FAILURE — the naive implementation turns awareness into a stall

Here is the trap in its purest form. This is what a competent developer writes on the first pass:

```swift prelude:guide-context
// ⚠️ THE NAIVE IMPLEMENTATION. Compiles. Correct. Slow enough to break the feature.
// This is NOT Apple's sample; it is the shape the trap takes.
extension PlaylistQuery {
    func displayRepresentations(
        for identifiers: [PlaylistEntity.ID],
        requestedComponents: DisplayRepresentation.Components = .text
    ) async throws -> [PlaylistEntity.ID: DisplayRepresentation] {

        var result: [PlaylistEntity.ID: DisplayRepresentation] = [:]
        for id in identifiers {
            // One round trip per entity…
            let entity = try await model.playlistEntity(for: id)
            // …and the FULL display representation every time: artwork decoded,
            // thumbnails generated, subtitle fields joined — regardless of what
            // the system actually asked for.
            result[id] = entity.displayRepresentation
        }
        return result
    }
}
```

Everything about that is defensible in isolation and wrong in aggregate. It:

- **fetches one entity at a time** — N round trips to your store instead of one;
- **ignores `requestedComponents` entirely** — it builds the full representation whether or not the
  system wanted an image;
- **does image work on a text query** — decoding artwork for forty rows so the system can compare
  forty *titles* against the phrase "the third one".

And here is the part that makes it a **silent failure** rather than a performance bug: **there is
no error, no warning, no log, and no signal in your app that anything went wrong.** The
implementation is correct. It returns the right dictionary. It just returns it too late, and the
symptom appears in Siri's mouth — *"which one did you mean?"* — several layers away from the code
that caused it. Nothing in your instrumentation connects the two.

It is also a hot path. This runs **every time Siri needs to reason about the current screen**, not
once at launch, and it runs against however many entities you have annotated. A method that costs
15 ms for one entity and gets called with forty identifiers has just spent 600 ms of a budget
nobody has published.

### 4.3 The fix, from Apple

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 343 @ 17:23) — verbatim structure
// Component-based display representation queries
extension PlaylistQuery {
    func displayRepresentations(
        for identifiers: [PlaylistEntity.ID],
        requestedComponents: DisplayRepresentation.Components = .text
    ) async throws -> [PlaylistEntity.ID: DisplayRepresentation] {
        let entities = try await model.playlistEntities(for: identifiers)

        // Fetch display representations for fetched entities
        var result: [PlaylistEntity.ID: DisplayRepresentation] = [:]
        for entity in entities {
            result[entity.id] = await entity.displayRepresentation(with: requestedComponents)
        }
        return result
    }
}
```

Two changes, and they are the whole lesson:

**One batched fetch.** `model.playlistEntities(for: identifiers)` — plural, one call, all
identifiers. Your store almost certainly supports an `IN`-style query; use it. This is the change
that removes N round trips.

**Honour `requestedComponents`.** `entity.displayRepresentation(with: requestedComponents)` — an
`async` overload that builds only what was asked for. This is the change that removes the image
work from text queries.

And Apple states the payoff explicitly:

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"when Siri is trying to understand the content on
> screen, it can **query just the text representation** of the entity and **skip the overhead of
> fetching the full content from the database**."*

### 4.4 `DisplayRepresentation.Components`

This is the type that makes the optimisation possible, and it is also where our verification runs
out.

> ✅ **VERIFIED (Apple code sample, WWDC26 343 @ 17:23)** — `DisplayRepresentation.Components`
> exists, **`.text`** is one of its values, and `.text` is the **default value in Apple's own
> signature**.

> 🔴 **GAP G7 — the rest of `DisplayRepresentation.Components`.**
>
> **What is unknown:** every case other than `.text`. `.image` is the obvious guess given that the
> stated benefit is skipping image work, and we are deliberately **not writing it down as fact**.
> We also do not know whether `Components` is an `OptionSet` (so `[.text, .image]` composes) or an
> enum (so it does not), and we do not know whether the system ever requests anything other than
> `.text` for on-screen resolution.
>
> **What would resolve it:** the `/documentation/appintents/displayrepresentation/components` page,
> the CosmoTunes sample, or an SDK interface dump.
>
> **Safe default — and it is a good one:** *never branch on a case you have not seen*. Write your
> implementation so that it **asks the components value what it wants** rather than switching on
> it, by passing it straight through to `displayRepresentation(with:)` exactly as Apple's sample
> does. That code is correct no matter how many cases the type has. The moment you write
> `if requestedComponents == .text { … } else { … }` you have coupled yourself to a case list you
> cannot see.

The safe pattern, stated as code:

```swift prelude:guide-context
// The forward-compatible shape: pass the value through, never inspect it.
result[entity.id] = await entity.displayRepresentation(with: requestedComponents)

// NOT this — it assumes a case list we cannot verify:
// if requestedComponents == .text { result[entity.id] = textOnlyRepresentation(entity) }
// else { result[entity.id] = fullRepresentation(entity) }
```

### 4.5 The `displayRepresentation(with:)` overload

The other half of the mechanism lives on your entity, not your query.

> ✅ **VERIFIED (Apple code sample, WWDC26 343 @ 17:23)** — `entity.displayRepresentation(with:)`
> is called with `await`, so it is an **`async`** overload of the ordinary
> `displayRepresentation` property.

That overload is where *you* decide what "text only" means for your type. A worked implementation,
built on the verified `DisplayRepresentation(title:subtitle:image:)` initializer:

```swift prelude:guide-context
// Composition: ✅ VERIFIED initializer (WWDC26 343 @ 4:26) +
//              ✅ VERIFIED call site (WWDC26 343 @ 17:23).
// The BODY is ours — Apple does not publish an implementation of this overload.

import AppIntents

@AppEntity(schema: .audio.song)
struct TrackEntity {
    var id: UUID
    var title: String
    var artistName: String
    var artworkAssetID: String?

    // The ordinary, synchronous property. Used by responses, disambiguation,
    // Spotlight, Shortcuts and confirmations.
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(artistName)")
    }

    // The component-aware overload. Called on the on-screen resolution hot path.
    func displayRepresentation(
        with components: DisplayRepresentation.Components
    ) async -> DisplayRepresentation {
        // Cheap fields only. NO artwork decode, NO thumbnail generation,
        // NO extra database round trips. Whatever the components value asks for,
        // the cheap path is always safe to return.
        DisplayRepresentation(title: "\(title)", subtitle: "\(artistName)")
    }
}
```

> 🔴 **GAP G8 — the exact signature of `displayRepresentation(with:)`.**
>
> **What is unknown:** whether it is `async` only or `async throws`, its argument label
> (`with:` is what the call site shows), whether it has a default implementation that the
> `@AppEntity` macro synthesises from the plain property, and whether it is a protocol requirement
> or an extension point. Our sample above is written to be a safe superset: if the macro already
> synthesises one, yours overrides it; if it does not, yours supplies it.
>
> **What would resolve it:** the `AppEntity` protocol page, or the CosmoTunes sample.
>
> **Safe default:** implement it as shown, with a body that is strictly cheaper than your
> synchronous property. If the compiler rejects the signature, take the compiler's version.

### 4.6 A performance budget you can actually apply

There is no published number. Here is what to do in its absence.

> **Attribution note.** Apple publishes **no** latency target, timeout, or benchmark for on-screen
> entity resolution, and we have found **no** community measurement of one. The rules below are
> derived from the *mechanism* — one call, N identifiers, on a path the user is waiting on — and
> from Apple's qualitative statement that being too slow degrades the interaction. They are
> engineering guidance, not measurements, and must not be cited as either Apple-published or
> community-measured numbers.

Rules that follow from the mechanism alone:

1. **One store round trip per call.** If `identifiers.count` correlates with your query count, fix
   that before anything else. This is the largest and most reliable win.
2. **No I/O in the text path.** No file reads, no image decodes, no network. If a field requires
   any of those, it does not belong in a component-aware representation.
3. **No lazy-loading faults.** If your entity is backed by SwiftData or Core Data, touching an
   unfaulted relationship inside this method turns one query into N. Fetch what you need in the
   batch fetch, explicitly.
4. **Bound the work by the *identifiers*, not by your corpus.** The system passes you exactly the
   identifiers it cares about. Never respond by enumerating everything and filtering.
5. **Make it main-actor-free if you can.** If your store is main-actor isolated (a very common
   shape — session 344's `CalendarManager` is), this method contends with your UI. That is a real
   cost on a path that runs while the user is looking at the screen.
6. **Measure it yourself, with `signpost`.** Since there is no published budget, instrument the
   method and know your own number before Siri tells you it is too big.

```swift prelude:guide-context
// Instrumenting the hot path. os.signpost is pre-2026 API (iOS 12+).
import os

private let siriSignpost = OSSignposter(
    subsystem: "com.example.MyApp",
    category: "onscreen-awareness"
)

extension TrackEntityQuery {
    func displayRepresentations(
        for identifiers: [TrackEntity.ID],
        requestedComponents: DisplayRepresentation.Components = .text
    ) async throws -> [TrackEntity.ID: DisplayRepresentation] {

        let state = siriSignpost.beginInterval(
            "displayRepresentations",
            id: siriSignpost.makeSignpostID()
        )
        defer { siriSignpost.endInterval("displayRepresentations", state) }

        let entities = try await store.tracks(withIDs: identifiers)   // ONE round trip

        var result: [TrackEntity.ID: DisplayRepresentation] = [:]
        result.reserveCapacity(entities.count)
        for entity in entities {
            result[entity.id] = await entity.displayRepresentation(with: requestedComponents)
        }
        return result
    }
}
```

Then drive it from Instruments while saying *"play the third one"* at an annotated list. You will
learn more in ten minutes than from any number this guide could invent.

### 4.7 Where else your display representation is consumed

`displayRepresentations(for:requestedComponents:)` is worth implementing well for a reason beyond
this section: the display representation it returns is the most widely consumed thing your entity
has. Session 343 enumerates the consumers, and it is a longer list than most developers expect:

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"Entity display representation can be used in
> **responses**, like when an entity has been created or updated. They are also used when **asking
> someone to choose between similar entities**, or when **answering questions about content in your
> app**. **Spotlight and Shortcuts** can use them, too."*

Plus two more that the session adds later: **intent confirmations**, and the **on-screen-awareness
fast path** this section is about. That is five to six distinct subsystems reading one property —
which is exactly why session 343's adoption order (§7.1) puts *"customizing your entity display
representations"* **first**, ahead of indexing, ahead of annotation, ahead of everything.

The enriched initializer:

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

Note the tension this creates, and resolve it deliberately: **the synchronous property should be
rich** (it feeds result cards, Spotlight rows and disambiguation UI, where an image is worth having)
and **the component-aware overload should be cheap** (it feeds resolution, where forty images are a
stall). They are the same concept at two different price points. Writing one and letting it serve
both is how you end up in §4.2.

---

## 5. Handing content to another app

<a name="5-handing-content-to-another-app"></a>

This is the section the guide exists for. It is also the section where Apple's documentation and
the observed behaviour of the shipping software point in different directions, and where the most
useful answer available came from a developer rather than from Apple.

### 5.1 Reference and transfer are two mechanisms, not one

Annotation (§3) makes an entity **referenceable**. The user can say "this" and the system knows
which of your objects they mean. That is a complete, working capability on its own — it is what
powers *"open that third event"* and *"play the third one"*, both of which stay inside your app.

Moving the entity's **payload** across an app boundary is a different mechanism with different
requirements. *"Send this to Bubbles"* needs the receiving app to end up with actual bytes, and
nothing about an `EntityIdentifier` carries bytes.

The failure mode when you have the first and not the second is specific and worth memorising,
because it is what you will see:

> **Siri identifies the right thing and then says it cannot do anything with it.**
>
> *"I can't attach the image directly from your screen."*

That is not a resolution failure. Your annotation worked. What failed is one layer further on.

### 5.2 The documented route — `Transferable` and `IntentValueRepresentation`

Session 240 splits cross-app work into exactly these two halves and names them:

> ✅ **VERIFIED (transcript, WWDC26 240)** — the two halves are **on-screen awareness** (identify
> what "this" refers to) and **content transfer** (move it to another app).

The documented transfer mechanism is `Transferable` with an `IntentValueRepresentation`:

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 240 @ 18:18) — export only
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
// ✅ VERIFIED (Apple code sample, WWDC26 240 @ 20:00) — export AND import
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

And the rule for choosing between importing-by-creation and importing-by-matching, which Apple
states crisply enough to quote verbatim:

> ✅ **VERIFIED (transcript, WWDC26 240)** — *"When content comes into your app, there are usually
> **two possibilities**. Either that content **refers to something that already exists**, or it
> **represents something entirely new**. **You get to decide which path your app takes. If you're
> matching existing content, use `IntentValueQuery`. If you're creating something new, use
> `importing` on the `transferRepresentation`.**"*

The matching route:

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

> ✅ **VERIFIED (transcript, WWDC26 240)** — *"**Many apps use both**, depending on the intent and
> workflow."* And the framing that makes the design click: *"**Your app doesn't need to know what
> happens next. It just needs to describe its content accurately.**"*

**Now look closely at the shape of that bridge, because it is where the hole is.**

`IntentValueRepresentation` maps your entity onto a **system intent value type**. The types named
across our sources are `IntentPerson`, `PlaceDescriptor` and `PersonNameComponents`. There is a
system type for a person. There is one for a place. **There is no general system value type for
"an arbitrary image my app just rendered."**

That is not a criticism of the design — it is what "structured value type" means. But it is exactly
the hole thread 838329 fell into, and it explains why the developer reached for plain `Transferable`
with a `DataRepresentation` instead. There was no `IntentValueRepresentation` to reach for.

> ⚠️ **Naming hazard.** Session 345 uses **`ValueRepresentation(exporting:)`** for what looks like
> the same job that session 240's **`IntentValueRepresentation(exporting:)`** does. Both are
> `TransferRepresentation`s attached via `static var transferRepresentation`; both export an entity
> as a system-understood structured type. **We found no page reconciling them and we are not
> asserting they are the same type or that one is an alias of the other.** See
> [guide 02 §13.1](02-app-schema-domains.md) and 🔴 GAP G9. Do not port code between the two
> spellings assuming equivalence.

### 5.3 What does not work — and the log line that proves it

Here is the implementation the documentation leads you to write for an on-screen image. It is
reasonable. It compiles. It does not work.

```swift illustrative
// ❌ ✅ VERIFIED (community, forum thread 838329) as the implementation that FAILED on
//      iOS 27 beta 3. Reproduced here so you can recognise it, not so you can use it.
struct OnScreenImageEntity: AppEntity, Transferable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "On-Screen Image")
    static let defaultQuery = Query()
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { … }
        DataRepresentation(exportedContentType: .png)       { … }
    }

    struct Query: EntityQuery {
        func entities(for ids: [String]) async throws -> [OnScreenImageEntity] {
            logger.notice("entities(for:) CALLED \(ids)")   // <- NEVER FIRES
            return ids.filter { store.isCurrent($0) }.map(OnScreenImageEntity.init)
        }
    }
}

Image(uiImage: image)
    .appEntityIdentifier(EntityIdentifier(for: OnScreenImageEntity.self, identifier: id))
```

Three things are notable about that listing:

**The annotation is correct.** `.appEntityIdentifier` with a properly constructed
`EntityIdentifier` — exactly what §3.3 teaches. This is not a mistake being corrected.

**The `Transferable` conformance is textbook.** Two `DataRepresentation`s, one text and one PNG.
This is how you make any type transferable in the Core Transferable world, and it has worked since
iOS 16 for drag-and-drop, share sheets and the pasteboard.

**`entities(for:)` never fires.** That comment — `// <- NEVER FIRES` — is the entire finding.
The developer instrumented the one method that would prove the system was consulting the entity,
and the system never called it.

Result, reported verbatim: Siri responds *"I can't attach the image directly from your screen."*

The corpus summary of the same thread adds the qualifier that matters:

> ✅ **VERIFIED (community, forum thread 838329)** — with a custom `AppEntity` +
> `DataRepresentation`, *"Send this to \<contact\>"* returns *"I can't attach the image directly"*,
> and **`EntityQuery.entities(for:)` was never called in most flows.**

*Most* flows, not all: the ChatGPT hand-off row in §1.2 did fire the query and then stalled
elsewhere. So the mechanism is not "custom entities are invisible" — it is closer to "custom
entities do not survive the transfer stage", with one path getting further than the others.

### 5.4 What does work — the verified recipe

> ✅ **VERIFIED (community, forum thread 838329)** — posted by developer `J0hn`, **marked as the
> recommended answer**, and reported as **confirmed working on device on iOS 27**. The reporter's
> exact wording: *"'Send this to \<contact\>' now works and Siri lifts the on-screen image to
> another app (confirmed on device iOS 27)."*
>
> This is **community evidence, not Apple evidence.** Apple's documentation does not describe this
> recipe. It is the only route anyone has reported working.

Three changes from §5.3, and all three are load-bearing:

| | Does not work | Works |
|---|---|---|
| Entity | plain custom `AppEntity` | **`@AppEntity(schema: .files.file)`** |
| Identifier | a plain `String` | **`FileEntityIdentifier.file(url:)`** |
| Transfer | `DataRepresentation` | **`FileRepresentation` + `SentTransferredFile`** |

#### The entity

```swift prelude:guide-context
// ✅ VERIFIED (community, forum thread 838329) — the schema adoption is the first of the
//    three required changes. Schema-required properties come from the .files.file schema;
//    Xcode's `files_file` snippet scaffolds them (see guide 02 §3.4).
import AppIntents

@AppEntity(schema: .files.file)
struct MyFileEntity { /* schema-required properties */ }
```

`.files` is a **primary-tier** domain with 5 intents and exactly 1 entity — the smallest content
domain Apple ships and, by this finding, the most load-bearing one. [Guide 02 §5.1](02-app-schema-domains.md)
has its full inventory. Note the availability asymmetry: `FileEntityIdentifier` itself is iOS 18 /
macOS 15, but the `.files.file` **schema's** own floor is not stated on its documentation page — the
safe default remains gating schema adoption on the 27 releases where the domain catalog shipped.

#### The identifier

```swift prelude:guide-context
// ✅ VERIFIED (community, forum thread 838329)
guard let fileIdentifier = try? FileEntityIdentifier.file(url: someFileURL) else { return nil }
let identifier = EntityIdentifier(for: MyFileEntity.self, identifier: fileIdentifier)
```

`FileEntityIdentifier.file(url:)` is a **throwing** factory — the forum code wraps it in `try?`.
So a URL that cannot be turned into a file identifier is an expected condition, not a programmer
error, and your annotation code must have an answer for it (returning `nil` from the data-source
method, as the forum code does).

#### The UIKit annotation site

```swift illustrative
// ✅ VERIFIED (community, forum thread 838329) — placeholders as posted
public func collectionView(
    _ collectionView: UICollectionView,
    appEntityIdentifierForItemAt indexPath: IndexPath
) -> EntityIdentifier? {
    guard let item = dataSource?.itemIdentifier(for: indexPath) else { return nil }
    guard let fileIdentifier = try? FileEntityIdentifier.file(url: <URL>) else { return nil }
    return EntityIdentifier(for: <ENTITY>.self, identifier: fileIdentifier)
}
```

#### The transfer representation — the change that actually fixes it

```swift illustrative
// ✅ VERIFIED (community, forum thread 838329) — FileRepresentation, NOT DataRepresentation
public static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(
        contentType: .image,
        exporting: { entity in
            guard let url = try await entity.id.fileURL else {
                throw Errors.unableToRetrieveURL
            }
            return SentTransferredFile(url)
        },
        importing: { received in
            let attributes = try? FileManager.default
                .attributesOfItem(atPath: received.file.path())
            let creationDate = attributes?[.creationDate] as? Date
            let modificationDate = attributes?[.modificationDate] as? Date

            return <ENTITY>(
                id: try FileEntityIdentifier.file(url: received.file),
                creationDate: creationDate,
                fileModificationDate: modificationDate,
                name: received.file.lastPathComponent
            )
        })
}
```

Five details in that block are worth pulling out, because they are what make it work:

1. **`FileRepresentation`, not `DataRepresentation`.** Both are Core Transferable representations
   and both would satisfy a share sheet. Only one satisfies this path. This is the single
   highest-value line in the guide.
2. **`entity.id.fileURL`** — the identifier is not opaque. A `FileEntityIdentifier` can be asked
   for its URL back, and the accessor is **`async` and throwing** (`try await`) and returns an
   **optional**. All three of those matter: it can fail, it can take time, and it can be nil.
3. **`SentTransferredFile(url)`** — the export payload wrapper. Pre-2026 Core Transferable type.
4. **The `importing:` closure reconstructs the entity from a `ReceivedTransferredFile`** —
   `received.file` is the URL, and everything else on the entity is derived from the file system.
   Note that the imported entity's `id` is built with `FileEntityIdentifier.file(url:)` again, this
   time with `try` rather than `try?` because the closure can throw.
5. **`contentType: .image`** — a `UTType`. Use the type that matches what you actually write to
   disk; `.image` is the abstract supertype and is what the reporter used for images.

The current reference fills in the previously missing public surface. `FileEntityIdentifier` is a
`Hashable`, `Codable`, `Sendable` value available from iOS 18 / macOS 15. In addition to
`file(url:)` and the async-throwing `fileURL`, it provides `draft(identifier:)`,
`draftIdentifier`, and `isDraft` for a document that has not been materialized on disk.[^file-identifier-api]

> 🔴 **GAP G10 — saved-file persistence semantics.**
>
> **What remains unknown:** what `file(url:)` throws, whether `fileURL` performs I/O or
> security-scoped resolution, and whether a saved-file identifier survives the file being moved or
> renamed. We also do not know whether it is bookmark-backed or path-backed.
>
> **Safe default for saved files:** treat the URL as the source of truth, keep the file where you
> put it for the lifetime of the annotation, and handle `fileURL` returning `nil` at every call
> site.

### 5.5 ⚠️ Draft identity exists; the verified hand-off still needs a real file payload

`FileEntityIdentifier` does have an in-memory identity form. Use `draft(identifier:)` for a
document that has not been materialized on disk; `isDraft` and `draftIdentifier` let entity code
distinguish that state.[^file-identifier-api]

```swift prelude:guide-context
let identifier = FileEntityIdentifier.draft(identifier: render.contentHash)
precondition(identifier.isDraft)
```

That corrects the identity claim, but it does **not** make bytes transferable. The only
community-verified cross-app hand-off in §5.4 exports a `FileRepresentation` by resolving
`entity.id.fileURL` and returning `SentTransferredFile`. A draft identifier intentionally has no
file URL, and Apple documents no draft-backed replacement for that payload.[^file-identifier-api]
For that verified hand-off path, an image, chart, receipt, QR code, or preview rendered in memory
must still be materialized before export. If you only need stable entity identity before saving,
use a draft identifier; if you need to send the content to another app, use the write-out pattern
below and then replace or reconstruct the identifier with `file(url:)`.

So the verified transfer pattern remains: **materialize, then annotate and export.**

```swift prelude:guide-context
// The write-out pattern. The FileEntityIdentifier / EntityIdentifier lines are
// ✅ VERIFIED (community, forum thread 838329); the file handling around them is
// ordinary pre-2026 Foundation (FileManager, URL, Data.write) and is ours.

import AppIntents
import Foundation
import UniformTypeIdentifiers

@MainActor
final class RenderedImageStore {

    /// A directory we own, inside the app container, that exists only to back
    /// on-screen entity annotations.
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnScreenEntities", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    /// Materialise a transient render and return an identifier the system can resolve.
    ///
    /// - Parameter pngData: your app supplies this; how you produce it is out of scope.
    /// - Parameter stableName: use something derived from the CONTENT, not a UUID per call,
    ///   so repeated renders of the same thing reuse one file instead of filling the directory.
    func identifier(
        forRenderedPNG pngData: Data,
        stableName: String
    ) throws -> EntityIdentifier {

        let url = directory
            .appendingPathComponent(stableName)
            .appendingPathExtension(for: .png)

        // Only write if it is not already there — the annotation may be recomputed
        // many times for one visible image.
        if !FileManager.default.fileExists(atPath: url.path) {
            try pngData.write(to: url, options: .atomic)
        }

        let fileIdentifier = try FileEntityIdentifier.file(url: url)
        return EntityIdentifier(for: MyFileEntity.self, identifier: fileIdentifier)
    }

    /// Call when the content is no longer on screen and no hand-off is in flight.
    func discard(stableName: String) {
        let url = directory
            .appendingPathComponent(stableName)
            .appendingPathExtension(for: .png)
        try? FileManager.default.removeItem(at: url)
    }
}
```

Then the annotation is the ordinary shape (b):

```swift prelude:guide-context
struct RenderedChartView: View {
    let chart: Chart
    @Environment(RenderedImageStore.self) private var store

    var body: some View {
        ChartCanvas(chart: chart)
            .appEntityIdentifier(try? store.identifier(
                forRenderedPNG: chart.pngData,
                stableName: chart.contentHash
            ))
    }
}
```

> ⚠️ **That last snippet has an unverified edge.** We do not know whether
> `.appEntityIdentifier(_:)` accepts an **optional** `EntityIdentifier?` — every Apple sample passes
> a non-optional. If it does not, hoist the `try?` into a computed property and apply the modifier
> conditionally. The compiler will tell you immediately; this is not a silent failure.

**Four rules for the write-out pattern**, all of which follow from the resolution-time requirement:

1. **Write before you annotate, not after.** The URL must resolve when the system asks, and you do
   not control when it asks.
2. **Name files from content, not from calls.** A `UUID()` per render fills the directory with
   duplicates of the same picture and breaks the "same thing, same identifier" property that makes
   repeat requests work.
3. **Do not clean up eagerly.** The file must survive from annotation until the receiving app has
   taken it, and you have no completion callback for that. `temporaryDirectory` is swept by the
   system; do not also sweep it yourself the instant the view disappears.
4. **Consider whether you should be writing at all.** If your content is *already* a file — a
   document, a photo in your library, an attachment — skip all of this and point
   `FileEntityIdentifier.file(url:)` at the real thing. The write-out pattern is a workaround for
   content that has no file, and it is strictly worse than content that has one.

> 🔴 **GAP G11 — the lifetime contract.**
>
> **What is unknown:** how long the file must remain after annotation, whether the system copies it
> at hand-off time or hands over the URL, whether a security-scoped resource is required for
> anything outside the app container, and whether deleting the file mid-transfer produces an error
> or a silent failure.
>
> **What would resolve it:** an Apple statement; there is none in our corpus. Empirically: annotate,
> trigger a hand-off, delete the file at various points, and observe.
>
> **Safe default:** keep the file for the whole time the content is on screen plus a grace period,
> and clean up on a coarse schedule (app background, next launch) rather than on view disappearance.

### 5.6 The contradiction, presented without smoothing

Apple's documentation and Apple's software disagree here. We are going to put both statements on
the page and let them sit there, because papering over it would cost you days.

**What the documentation says.** From *"Providing contextual cues to Apple Intelligence and Siri"*,
on schema adoption for on-screen annotation:

> ✅ **VERIFIED (Apple documentation, read 2026-07-27 via the sosumi.ai mirror of
> `/documentation/appintents/providing-contextual-cues-to-apple-intelligence-and-siri`)** —
> *"Schema application is optional but recommended for consistency."*

**What the software does.** On iOS 27 beta 3, a non-schema entity was **never resolved** for
hand-off — `entities(for:)` never fired for the Siri paths — while the schema-typed `.files.file`
entity resolved and transferred correctly. (Thread 838329, §5.3 and §5.4.)

Those two statements cannot both be a complete description of the same system.

**A reading that reconciles them — and it is a reading, not a fact.** "Optional" may govern
*annotation and reference* — the "this" part, §3 — while schemas govern *transfer* — the payload
part, §5. Under that reading both sentences are true and they are about different stages. It is
consistent with the discovery-versus-action split that Apple states elsewhere and that
[guide 02 §2](02-app-schema-domains.md) builds on:

> ✅ **VERIFIED (Apple documentation, "Making actions and content discoverable by Apple
> Intelligence")** — *"Without both layers, Apple Intelligence cannot act on user requests
> involving your entities."*

> 🟡 **RECONSTRUCTED — the reconciliation itself.** Apple does not say this anywhere we found. It
> is our best reading of two verified but conflicting statements. Treat the *reading* as
> provisional and the two *statements* as solid.

**Why this matters practically.** A developer reading *"optional but recommended for consistency"*
will reasonably conclude that the custom-entity route is supported, build it, and lose days. That
is not a hypothetical — it is what thread 838329 documents happening to a developer who followed
*"Making onscreen content available to Siri and Apple Intelligence"* and the WWDC sessions exactly.

There is a documentation-integrity footnote here too: the article title that developer cites by
name — *"Making onscreen content available to Siri and Apple Intelligence"* — **returned HTTP 404**
when our documentation pass tried to fetch it. The live equivalent appears to be *"Providing
contextual cues to Apple Intelligence and Siri"*, which fetched fine. So the article the community
is working from has been renamed or replaced, which is its own small reason the folklore in this
area is out of date.

### 5.7 What Apple said when asked — and what they did not say

The developer who found all of this asked Apple directly. Here is the full arc of that thread,
because the *shape* of it is the story of this API area in miniature.

1. **The developer followed the documentation exactly** — the on-screen-content article plus the
   WWDC sessions.
2. **It did not work, and they proved it.** Instrumented logging showed the callbacks never fire.
3. **Apple's DTS engineer did not answer the technical question.** Quoted:

   > ✅ **VERIFIED (Apple DTS engineer, forum thread 838329)** — *"There is so much you have
   > provided including issues making onscreen content available to Siri and Apple Intelligence and
   > providing contextual cues to Apple Intelligence and Siri… Because you submitted a focused
   > sample and the same explanation on a good written bug, I'll let the team take over all the
   > issues."*

   The developer is routed to Feedback Assistant. **No API guidance is given.** The radar is
   **FB23813341**.
4. **Another developer supplied the working answer** — the `.files.file` recipe in §5.4, marked as
   the recommended answer and confirmed on device.
5. **The original poster accepted it and restated the question nobody had answered:**

   > ✅ **VERIFIED (forum thread 838329)** — *"I wonder if this more generic approach shouldn't also
   > work… Is on-screen consumption intended to be limited to the predefined assistant schemas, or
   > should a custom `AppEntity` + `Transferable` also be a supported way to expose arbitrary
   > on-screen content?"*

**That question is still open.** Nobody from Apple answered it. As of 2026-07-27 there is no Apple
statement anywhere in our corpus that says whether the §5.3 route is meant to work.

For context on how unusual that is *not*: across the whole App Intents / Siri / on-screen forum
cluster our research pass examined, there was **one substantive Apple answer** (and it was about
Foundation Models availability, not App Intents), **one deflection to Feedback Assistant** (this
thread), and **the rest unanswered**. The single genuinely useful technical answer in the cluster
came from another developer.

That is not a complaint about DTS, who were handed a large multi-issue thread with a sample project
attached and made a defensible triage call. It is a statement about what evidence exists for you to
build on: **for this specific capability, community evidence is the best evidence there is.**

### 5.8 What to do today

| Your situation | Route | Confidence |
|---|---|---|
| Content is **already a file** (document, photo, attachment, export) | `@AppEntity(schema: .files.file)` + `FileEntityIdentifier.file(url:)` + `FileRepresentation` | ✅ community-verified on device, iOS 27 |
| Content is **rendered in memory** and only needs identity | `FileEntityIdentifier.draft(identifier:)` | ✅ Apple-documented from iOS 18; no file URL until materialized[^file-identifier-api] |
| Content is **rendered in memory** and must be handed to another app | Materialize it, then use the saved-file recipe above (§5.5) | ✅ recipe verified; ⚠️ the materialization step remains necessary for this `FileRepresentation` payload |
| Content is a **person** | `IntentValueRepresentation(exporting: \.person)` → `IntentPerson` | ✅ Apple code sample (240 @ 18:18) |
| Content is a **place** | `ValueRepresentation` / `IntentValueRepresentation` → `PlaceDescriptor` | ✅ concept verified; ⚠️ naming hazard, GAP G9 |
| Content is **structured app data with no matching system type** | **No verified route.** Reference works (§3); transfer does not. | 🔴 open — this is FB23813341 |
| You only need **reference**, not transfer ("open that one", "play the third one") | §3 alone. No schema required for annotation. | ✅ Apple code samples |

And the strategic advice that falls out of the whole section, stated plainly:

**If hand-off is a requirement for your feature, choose your entity's schema before you write the
entity.** Retrofitting `.files.file` onto a custom entity is not a small change — it dictates your
identifier type, your transfer representation, and whether your content has to exist as a file at
all. Discovering that requirement after the entity is modelled is the expensive path, and it is the
path both forum threads took.

---

## 6. Beyond the screen

<a name="6-beyond-the-screen"></a>

The same `EntityIdentifier` from §2 attaches to three surfaces that are not the screen at all. This
is genuinely under-known — it appears in one chapter of one session and in one documentation page —
and it is cheap to adopt once the entities exist.

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"All three use the same pattern, and we call these
> **entity annotations**."*

### 6.1 Notifications

The use case: a notification is announced on AirPods, and the user replies to it by voice. For Siri
to act on *the thing the notification is about*, it needs a reference to that thing.

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 343 @ 21:07) — verbatim structure
import AppIntents
import UserNotifications

func scheduleNotification(message: Message, author: Contact, conversation: Conversation) {
    let content = UNMutableNotificationContent()
    content.title = author.name
    content.body = message.body

    // Annotate with entity identifier
    content.appEntityIdentifiers = [
        EntityIdentifier(for: MessageEntity.self, identifier: message.id)
    ]
    // Schedule the notification
}
```

`UNMutableNotificationContent.appEntityIdentifiers` is an **array**. A notification about a message
in a conversation can reasonably reference both the message and the conversation.

### 6.2 Now Playing — and the ordering rule

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, WWDC26 343 @ 21:07) — verbatim structure
import AppIntents
import NowPlaying

final class CosmoTunesMediaSession: MediaSessionRepresentable {
    var content: (any MediaContentRepresentable)? {
        var content = MusicContent(id: track.id.uuidString, songTitle: track.title /* ... */)
        content.appEntityIdentifiers = [
            EntityIdentifier(for: SongEntity.self,     identifier: track.id),
            EntityIdentifier(for: ArtistEntity.self,   identifier: track.session.artistName),
            EntityIdentifier(for: PlaylistEntity.self, identifier: currentPlaylist.id),
        ]
        return content
    }
}
```

⚠️ **The order of that array is semantic.** This is not stylistic:

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"add them to the `appEntityIdentifiers` property **in
> order of most specific to least specific**."*

Song, then artist, then playlist. That ordering is what makes *"play the live version"* work: the
system needs to know that the *song* is the most specific interpretation of "this" and the playlist
the least, so a request that could plausibly refer to any of the three resolves to the right level.

Get the order backwards and you have not broken anything that throws. You have made *"play the live
version"* resolve against a playlist. See §8.7.

Our documentation pass records one more detail for this surface:

> 🟡 **RECONSTRUCTED** — the contextual-cues documentation gives the Media Player key as
> **`MPNowPlayingInfoPropertyAppEntityIdentifiers`**. That is the older `MPNowPlayingInfoCenter`
> route rather than the `NowPlaying` framework route the session's sample uses. Both apparently
> exist; we did not verify how they relate, and we did not verify the constant's spelling against a
> header.

### 6.3 AlarmKit

```swift prelude:external-module
// ✅ VERIFIED (Apple code sample, WWDC26 343 @ 21:07) — verbatim structure
import AppIntents
import AlarmKit

func scheduleAlarm(_ alarm: Alarm) async throws {
    let configuration = AlarmManager.AlarmConfiguration<CosmoTunesAlarmMetadata>.alarm(
        schedule: schedule,
        attributes: attributes,
        appEntityIdentifier: EntityIdentifier(for: AlarmEntity.self, identifier: alarm.id),
        stopIntent: DismissAlarmIntent(),
        secondaryIntent: SnoozeAlarmIntent(),
        sound: sound
    )
    // Schedule alarm
}
```

Note this is a **generic factory** — `AlarmManager.AlarmConfiguration<Metadata>.alarm(…)` — with
`stopIntent:` and `secondaryIntent:` alongside the entity identifier. The payoff is that *"snooze
it"* resolves to your alarm entity rather than to whichever alarm the system guesses.

Here `appEntityIdentifier:` is **singular**. An alarm is one thing.

### 6.4 The asymmetry, and the ban

| Host type | Property / parameter | Cardinality |
|---|---|---|
| `UNMutableNotificationContent` | `.appEntityIdentifiers` | **array** |
| `MusicContent` (`NowPlaying`, via `MediaContentRepresentable`) | `.appEntityIdentifiers` | **array** |
| `AlarmManager.AlarmConfiguration<Metadata>.alarm(…)` | `appEntityIdentifier:` | **singular** |

> ✅ **VERIFIED (Apple code samples, WWDC26 343 @ 21:07)** — all three rows.

And the constraint that will bite someone on your team:

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"Note, that with the **three entity annotation APIs**
> I'm describing, **you can't use `TransientAppEntity`**. Transient entities are temporary model
> objects, so **they don't have persistent identifiers**."*

This connects two sessions that never mention each other. Session 344 gives an excellent, correct,
purely *local* reason to make a type transient:

> ✅ **VERIFIED (transcript, WWDC26 344)** — *"**A transient app entity is one that represents a
> temporary entity that doesn't require a unique identifier and isn't meant to be queried.**… Since
> attendees are always accessed **through the event that holds them**, there's **no need for an
> independent look up path**… **no query to write, no index to maintain.**"*

Both statements are right. Together they mean: **choosing `TransientAppEntity` forecloses all three
system integrations for that type, permanently, and neither session tells you so.** A CometCal
attendee can never be a notification annotation target. Decide transient-versus-persistent with the
system-integration question explicitly on the table. §8.5, and
[guide 02 §14.4](02-app-schema-domains.md).

### 6.5 Whether the ban is enforced

> 🔴 **GAP G12 — what happens if you pass a transient entity's identifier to an annotation surface.**
>
> **What is unknown:** compile error, runtime assertion, or silent no-op. A `TransientAppEntity` by
> definition has no persistent identifier, so it is not obvious you could even *construct* an
> `EntityIdentifier` for one — but nothing we read says the construction is prevented.
>
> **What would resolve it:** trying it, or the `TransientAppEntity` documentation page.
>
> **Safe default:** assume silent. Treat the transient-versus-persistent choice as an architectural
> decision made once, with §6 in mind, rather than a local convenience.

---

## 7. Adoption order and the diagnostic playbook

<a name="7-adoption-order-and-the-diagnostic-playbook"></a>

### 7.1 Apple's own order

Session 343 closes with an explicit, ordered prioritisation. It is worth mirroring exactly, because
the ordering is not what most developers would guess — annotation, the thing this guide is about,
is **fourth**.

> ✅ **VERIFIED (transcript, WWDC26 343)** — the wrap-up, in order:
>
> 1. *"a great place to start is by **customizing your entity display representations**. They are
>    used to display your entities across the system."*
> 2. *"From there, **add your entities to the semantic index, and keep the index up to date**, so
>    Siri can always find your freshest content."*
> 3. *"You might also consider making your entities accessible through Siri with an
>    **`IntentValueQuery` and in-app search**."*
> 4. *"**annotating your views, activities, and your existing system integrations** with entities."*
> 5. *"When you're ready, look into **donating UI interactions**."*

Why this order makes sense, stated in terms of this guide:

| Step | Why it comes when it does | Guide |
|---|---|---|
| 1. Display representations | Consumed by **five or six** subsystems (§4.7), including the on-screen fast path. Highest leverage per line of code on the whole list. | §4.7 |
| 2. Semantic index | Serves every request class that names content rather than pointing at it — a far larger share of real utterances than "this". | [04](04-entities-spotlight-and-foundation-models.md) |
| 3. `IntentValueQuery` + in-app search | Reaches content too large, too remote or too fast-changing to index; `.system.searchInApp` works with no domain adoption at all. | [02 §8, §10.5](02-app-schema-domains.md) |
| 4. **Annotation** | Only helps when the user is *looking at* the thing. Powerful, but narrower than 1–3. | **this guide, §3 and §6** |
| 5. Donations | Refinement. Siri already learns from Siri; donations teach it about your UI. | [02 §12.1](02-app-schema-domains.md) |

If you arrived at this guide because "Siri can't see my content", **check steps 1 and 2 before you
write a single annotation.** A large fraction of the requests you are imagining are index requests,
not on-screen requests, and the index is both cheaper to adopt and broader in reach.

### 7.2 The testing ladder, applied to on-screen awareness

Session 240 gives a four-stage debugging funnel. It is the best methodology in the four sessions and
it maps cleanly onto this guide's failure modes.

> ✅ **VERIFIED (transcript, WWDC26 240)** — the four stages:
>
> 1. **`AppIntentsTesting`** — *"lets you exercise your intents **entirely in isolation. No Siri
>    involved.** … **the fastest and most reliable way to validate your business logic early in
>    development.**"*
> 2. **Shortcuts app** — *"**This is where you validate the shape of your intent. Not just what it
>    does, but how it's configured and exposed.**"*
> 3. **Spotlight** — *"where you validate your **content integration**, ensuring your entities are
>    **indexed correctly, discoverable, and linkable**. This helps you **confirm that Siri can find
>    the right data before it ever tries to act on it.**"*
> 4. **Siri** — *"**Natural language, entity resolution, on-screen context, and cross-app
>    workflows.**"*

**On-screen awareness is a stage-4 capability with stage-1-through-3 prerequisites**, and that is
the whole point of the ladder. Before you conclude that annotation is broken:

| Check | Stage | If it fails, the bug is not in your annotation |
|---|---|---|
| Does your `EntityQuery.entities(for:)` return the right entity for a known ID, called directly from a test? | 1 | Your query is broken. Annotation cannot fix it. |
| Does your intent appear in Shortcuts with the parameters you expect? | 2 | Your intent shape is wrong. |
| Can you find the entity in Spotlight by typing its title? | 3 | Indexing is broken; see guide 04. |
| Does *"send this to X"* fire `entities(for:)` (§1.6)? | 4 | **Now** you are debugging annotation. |

Session 240's own framing of why the order matters: isolate logic → isolate configuration → isolate
retrieval → then the full stack. Or, as our forum research put it: **most "Siri doesn't work"
reports are stage-2 or stage-3 problems misdiagnosed as stage-4.**

### 7.3 The playbook

A decision procedure for "Siri can't see my content", in the order that costs least.

**Step 1 — Classify the request.** Write down the exact sentence you are testing. Is it
descriptive (*"describe this"*, *"what does this say"*, *"summarise this"*, *"make a note of
this"*) or a hand-off / reference-and-act (*"send this to…"*, *"play the third one"*, *"open that
one"*)?

- **Descriptive** → §1.2. Your entity code will not be called. Nothing you do in §3 will change the
  answer. If the information the user wants is off-screen, the only levers you have are (a) render
  it, or (b) reach it through the index instead (guide 04), or (c) `.system.searchInApp`
  (guide 02 §8). **Stop here.** This is where thread 837249 was.
- **Hand-off / reference** → continue.

**Step 2 — Instrument `entities(for:)`.** §1.6. One logger, two utterances, five minutes.

**Step 3 — If it never fires**, in this order:

1. Is the annotation actually on the screen you are testing? Annotations are per-view; a `NavigationStack`
   detail screen does not inherit the list's annotation.
2. Does the ID type you annotate with match the ID type `entities(for:)` expects? §2.1's warning.
3. Are you using per-row annotation on a scrollable list, with a selected row that has scrolled
   away? §3.4 and §8.2.
4. Is the entity **schema-typed**? For hand-off, a plain custom `AppEntity` is the known-failing
   configuration. §5.3.
5. Are you on the `NSUserActivity` route specifically? §3.2's conflict note and §8.6 — try shape (b)
   or (c) as a control.

**Step 4 — If it fires and returns entities but Siri still fails**, you are past resolution and in
transfer. §5.4. Check `FileRepresentation` versus `DataRepresentation` first; it is the single
change that fixed the only reported working case.

**Step 5 — If it fires, returns entities, transfers, but Siri picks the wrong one or asks you to
clarify**, you are in §4. Your `displayRepresentations(for:requestedComponents:)` is missing, slow,
or returning representations that do not distinguish the entities from each other.

**Step 6 — If Siri surfaces something that looks like an internal error**, that is a known class.
Our forum corpus records `TypedValueToContentGraphResolutionErrorDomain` **error 4** reaching end
users through Siri AI (thread 835903). Make sure it is not yours first: never let a raw `Error`
escape `perform()`; conform your error type to `CustomAppIntentErrorConvertible` /
`CustomLocalizedStringResourceConvertible` so whatever Siri says is a string you wrote. §8.8.

### 7.4 What to build first, if you are starting today

For a standard master–detail app with entities already modelled:

1. **Enrich `displayRepresentation`** with a subtitle and an image (§4.7). One property.
2. **Add the component-aware overload** with a cheap body (§4.5). One method.
3. **Implement `displayRepresentations(for:requestedComponents:)`** with one batched fetch (§4.3).
   One method.
4. **Annotate the list** with `.appEntityIdentifier(forSelectionType:_:)` (§3.4). One modifier.
5. **Annotate the detail screen** with `.userActivity` + `appEntityIdentifier` (§3.2). One modifier.
6. **Test with §1.6's two utterances.**
7. Only then: decide whether you need transfer (§5), and if you do, revisit your schema choice
   before writing any more code.

Steps 1–5 are the "two modifiers" claim from session 344 plus the performance work session 343 says
you will need as soon as a screen shows many entities. Together they are perhaps an afternoon. Step
7 is where the schedule risk lives.

---

## 8. Silent failures

<a name="8-silent-failures"></a>

Eight of them. None throw. Several produce no log line anywhere in your process. This is the
defining property of this stack and the reason this series marks them explicitly.

### 8.1 ⚠️ SILENT FAILURE — a naive `displayRepresentations` turns awareness into a stall

**The defect.** Implementing `displayRepresentations(for:requestedComponents:)` by fetching each
entity individually and building the full representation — including image work — for every
requested identifier.

**Why it is silent.** The implementation is *correct*. It returns the right dictionary. It compiles,
it passes unit tests, and it logs nothing. The only symptom is Siri behaving badly several layers
away, and Siri's misbehaviour is indistinguishable from a language-understanding problem.

**The symptom, in Apple's words.**

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"**If Siri can't understand my on-screen entities
> quickly enough, it may ask to clarify or play something else entirely. People can abandon the
> request when that happens.**"*

**Why it hides.** It is a hot path that only gets hot in production. With three entities on screen
in your test project it is imperceptible. With forty rows in a real user's library it is the
difference between the feature working and the feature being abandoned.

**The fix.** §4.3. One batched fetch; pass `requestedComponents` through to
`displayRepresentation(with:)`; never do I/O in the text path.

**How to detect it.** `OSSignposter` around the method (§4.6) and Instruments while saying *"play
the third one"*. There is no other signal.

### 8.2 ⚠️ SILENT FAILURE — per-row annotation loses selected and scrolled-off entities

**The defect.** `.appEntityIdentifier(_:)` applied inside a `ForEach` instead of
`.appEntityIdentifier(forSelectionType:_:)` applied to the list.

**Why it is silent.** SwiftUI recycles rows. When a row leaves the view hierarchy its annotation is
destroyed. Nothing errors — the annotation simply is not there any more, and "not there" is a
perfectly valid state.

> ✅ **VERIFIED (transcript, WWDC26 343)** — *"Collection annotations **also let Siri discover
> entities that have been selected and scrolled off screen. Per row annotations disappear as soon
> as the view leaves the view hierarchy.**"*

**The scenario.** User taps a track, scrolls forty rows down, says *"send that one to Glow."* The
selected track's annotation no longer exists. Siri asks which one, or picks a visible one.

**Why it hides.** It works perfectly in every test you will run by hand, because you test on the
first screenful. It fails for users with long lists — which is all of them.

**The aggravating factor.** Apple publishes a code sample that does this
(240 @ 17:19, reproduced in §3.4). It is not wrong for a short static list; it is wrong for
anything scrollable, and the sample carries no caveat.

**The fix.** §3.4's collection form.

### 8.3 ⚠️ SILENT FAILURE — building entity plumbing for the screenshot path

**The defect.** Modelling entities, writing queries, adopting `IndexedEntity` and annotating views
in order to make *"describe this"* or *"create a note for this"* work.

**Why it is silent.** There is no failure at all. Everything you built is correct and functioning.
It is simply never consulted for those requests, and the system's answer — assembled from a
screenshot — is often *plausible enough* that you assume your entities are being used and are
merely incomplete.

**The tell.** The response references things that are on screen but not in your entity model: UI
chrome, toolbar labels, section headers. That is a screenshot talking.

**Why it hides.** It costs you weeks rather than breaking anything. Thread 837249's developer built
an entire entity layer for a set of requests that could never reach it, then concluded the feature
did not work — when in fact the feature was working exactly as designed on a path that ignores
apps.

**The fix.** §1.6's five-minute instrumentation, run *before* the work rather than after.

### 8.4 ⚠️ SILENT FAILURE — a non-schema entity never resolves for hand-off

**The defect.** A plain custom `AppEntity` + `Transferable` used as the target of a cross-app
hand-off.

**Why it is silent.** `entities(for:)` is not called. No error is raised in your process. Siri
produces a fluent, plausible sentence — *"I can't attach the image directly from your screen"* —
which reads like a capability statement about Siri rather than a defect in your integration.

**The aggravating factor.** Apple's documentation says *"Schema application is optional but
recommended for consistency."* §5.6.

**The fix.** §5.4 — schema-type the entity, use `FileEntityIdentifier`, use `FileRepresentation`.

**The related, subtler variant:** annotating with an ID whose *type* does not match what
`entities(for:)` expects (a `uuidString` where the query wants a `UUID`). Both spellings compile,
because `identifier:` is generic. The query is called with values it cannot match, returns `[]`,
and Siri moves on. §2.1.

### 8.5 ⚠️ SILENT FAILURE — `TransientAppEntity` forecloses three system integrations

**The defect.** Choosing `TransientAppEntity` for a sub-object — which session 344 recommends, for
excellent reasons — and later trying to annotate a notification, Now Playing item or alarm with it.

**Why it is silent.** The two sessions that state the two halves of this never reference each other.
The local decision looks purely local. Whether the annotation attempt fails loudly or quietly is
itself unverified (🔴 GAP G12) — assume quietly.

**The fix.** Make the transient-versus-persistent decision with §6 explicitly in scope. If a type
will ever need to be referenced from outside your app's UI, it needs a persistent identifier.

### 8.6 ⚠️ SILENT FAILURE (reported, unconfirmed) — the `NSUserActivity` route producing no callbacks

**The defect.** Annotating via `NSUserActivity.appEntityIdentifier` and receiving nothing.

**The evidence.** Forum thread 838329's instrumentation lists the route as *"never consumed at
all — no callbacks"* on iOS 27 beta 3.

**The counter-evidence.** Sessions 343 and 344 both teach it, 343 recommends it as one of the two
places to start, and Apple publishes a code sample for it.

**Our reading.** One developer's negative result against two sessions and a published sample.
Most likely a beta defect or a mis-configured activity, **not** an API statement. But we are not in
a position to tell you it works, because nobody in our corpus has reported it working.

**The mitigation.** When you adopt shape (a), **verify it in isolation with §1.6 before you build
on it**, and keep shape (b) in your pocket as a control: annotate the same detail view with
`.appEntityIdentifier(_:)` and see whether the behaviour changes. If it does, you have learned
something Apple's documentation does not tell you, and it is worth a radar.

### 8.7 ⚠️ SILENT FAILURE — Now Playing identifiers in the wrong order

**The defect.** Populating `appEntityIdentifiers` least-specific-first, or in whatever order your
model happens to produce.

**Why it is silent.** The array is valid. Every identifier in it is correct. The system resolves
"this" against the wrong level of the hierarchy and does something reasonable-looking with the
wrong object.

**The rule.** Most specific to least specific — song, then artist, then playlist. §6.2.

### 8.8 ⚠️ SILENT FAILURE — raw internal errors reaching the user through Siri

**The defect.** Letting an untyped `Error` escape `perform()`.

**Why it belongs here.** It does not fail silently in *your* logs — it fails silently in your
*review process*, because the string the user sees is assembled by a subsystem you never see the
output of. Our forum corpus records `TypedValueToContentGraphResolutionErrorDomain` **error 4**
reaching end users through Siri AI (thread 835903), so the class is real even where the specific
error is Apple's rather than an app's.

**The fix.** Conform your error type to `CustomAppIntentErrorConvertible` and/or
`CustomLocalizedStringResourceConvertible`, or construct `AppIntentError(description:)` with a
localized description. Never `throw` a `DecodingError`, a `URLError` or a bare `NSError` out of
`perform()`. [Guide 02 §14.8](02-app-schema-domains.md) has the fuller treatment.

---

## 9. A complete worked integration

<a name="9-a-complete-worked-integration"></a>

Everything above, assembled into one coherent slice of an app. This is a **composition of verified
fragments**, not a transcription of an Apple sample — no such sample is in our corpus. Every block
carries its provenance, and the glue between blocks is ordinary Swift.

The app: a document scanner. It has a library of scans (a list), a detail view for one scan, and a
notification when a background OCR pass finishes. Scans are real files on disk, which — per §5.5 —
is the *easy* case for hand-off, and is why this example can show the whole thing working.

### 9.1 The entity

```swift prelude:guide-context
// Schema adoption: ✅ VERIFIED shape (community, forum thread 838329) — .files.file is the
// schema that makes hand-off work. The property list is scaffolded by Xcode's `files_file`
// snippet (✅ VERIFIED mechanism, WWDC26 344: "<domain>_" completion).
//
// DisplayRepresentation(title:subtitle:image:) — ✅ VERIFIED (Apple code sample, 343 @ 4:26)
// displayRepresentation(with:) — ✅ VERIFIED call site (343 @ 17:23); body is ours.

import AppIntents
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

@AppEntity(schema: .files.file)
struct ScanEntity {
    // Schema-dictated identifier type. Per §5.4 this is what makes transfer work,
    // and per guide 02 §3.2 schemas dictating your ID type is normal, not a surprise.
    var id: FileEntityIdentifier

    var name: String
    var creationDate: Date?
    var fileModificationDate: Date?

    // Rich: feeds result cards, disambiguation, Spotlight, Shortcuts, confirmations.
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(Self.dateFormatter.string(from: creationDate ?? .now))",
            image: thumbnailImage
        )
    }

    // Cheap: feeds on-screen resolution, on a hot path, N entities at a time.
    // NO thumbnail work here. See §4.2 for what happens if you forget.
    func displayRepresentation(
        with components: DisplayRepresentation.Components
    ) async -> DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private var thumbnailImage: DisplayRepresentation.Image? {
        // Whatever your app already has. Deliberately not exercised by the async overload.
        nil
    }
}
```

> 🟡 **RECONSTRUCTED — `DisplayRepresentation.Image`.** The `image:` parameter is verified
> (343 @ 4:26) but we never saw its type spelled out. Session 344's narration describes passing
> *"a system image of a calendar"*. Let Xcode completion give you the real type; do not copy this
> annotation.

### 9.2 The transfer representation

```swift prelude:guide-context
// ✅ VERIFIED (community, forum thread 838329) — FileRepresentation, not DataRepresentation.
// Adapted to the entity above; the structure and every API name is from the thread.

extension ScanEntity: Transferable {
    enum TransferError: Error { case unableToRetrieveURL }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(
            contentType: .pdf,
            exporting: { entity in
                guard let url = try await entity.id.fileURL else {
                    throw TransferError.unableToRetrieveURL
                }
                return SentTransferredFile(url)
            },
            importing: { received in
                let attributes = try? FileManager.default
                    .attributesOfItem(atPath: received.file.path())
                return ScanEntity(
                    id: try FileEntityIdentifier.file(url: received.file),
                    name: received.file.lastPathComponent,
                    creationDate: attributes?[.creationDate] as? Date,
                    fileModificationDate: attributes?[.modificationDate] as? Date
                )
            }
        )
    }
}
```

Note `contentType: .pdf` rather than the thread's `.image` — use the type that matches what you
actually write. Everything else is unchanged from the reported-working recipe.

### 9.3 The query — both requirements

```swift prelude:guide-context
// entities(for:) — the standard EntityQuery requirement.
// displayRepresentations(for:requestedComponents:) — ✅ VERIFIED (Apple code sample, 343 @ 17:23).
// The logger is the §1.6 diagnostic, left in deliberately.

import AppIntents
import os

private let siriLog = Logger(subsystem: "com.example.Scanner", category: "onscreen-awareness")

struct ScanEntityQuery: EntityQuery {

    @Dependency var library: ScanLibrary

    func entities(for identifiers: [FileEntityIdentifier]) async throws -> [ScanEntity] {
        siriLog.notice("entities(for:) CALLED — \(identifiers.count, privacy: .public) id(s)")
        // ONE batched lookup. Never a loop of single fetches.
        let scans = try await library.scans(withIdentifiers: identifiers)
        siriLog.notice("entities(for:) RETURNING \(scans.count, privacy: .public)")
        return scans
    }

    func displayRepresentations(
        for identifiers: [FileEntityIdentifier],
        requestedComponents: DisplayRepresentation.Components = .text
    ) async throws -> [FileEntityIdentifier: DisplayRepresentation] {

        // ONE round trip (§4.3), then the component-aware overload (§4.5).
        let scans = try await library.scans(withIdentifiers: identifiers)

        var result: [FileEntityIdentifier: DisplayRepresentation] = [:]
        result.reserveCapacity(scans.count)
        for scan in scans {
            result[scan.id] = await scan.displayRepresentation(with: requestedComponents)
        }
        return result
    }
}
```

`FileEntityIdentifier`'s documented `Hashable` conformance makes it a valid dictionary key; this
part of the listing no longer rests on an assumption.[^file-identifier-api]

`@Dependency` is the App Intents dependency-injection property wrapper:

> ✅ **VERIFIED (transcript, WWDC26 344)** — *"the property wrapper is **how App Intents injects
> shared resources** into intents and queries, so **instead of creating new instances, it provides
> the same object I register once**."*

### 9.4 The list screen

```swift prelude:guide-context
// ✅ VERIFIED shape (Apple code sample, 343 @ 16:27) — collection annotation.
import AppIntents
import SwiftUI

struct ScanLibraryView: View {
    @Environment(ScanLibrary.self) private var library
    @State private var selection: Scan.ID?

    var body: some View {
        List(selection: $selection) {
            ForEach(library.scans) { scan in
                ScanRow(scan: scan)
            }
        }
        // ONE annotation, on the list. Lazy; survives scroll-off and selection (§3.4).
        .appEntityIdentifier(forSelectionType: Scan.ID.self) { scanID in
            EntityIdentifier(for: ScanEntity.self, identifier: library.fileIdentifier(for: scanID))
        }
    }
}
```

The closure is where the model ID becomes an entity ID. Here it goes one step further than Apple's
sample because `.files.file` dictates a `FileEntityIdentifier` rather than a plain value —
`library.fileIdentifier(for:)` is app code that wraps `FileEntityIdentifier.file(url:)` and its
throwing behaviour.

### 9.5 The detail screen

```swift prelude:guide-context
// ✅ VERIFIED shape (Apple code sample, 343 @ 16:27) — NSUserActivity annotation.
// See §3.2 and §8.6 for the caveat on this route.
struct ScanDetailView: View {
    let scan: Scan
    @Environment(ScanLibrary.self) private var library

    var body: some View {
        ScanPageView(scan: scan)
            .userActivity("com.example.Scanner.scanDetail", isActive: true) { activity in
                activity.title = scan.name
                activity.appEntityIdentifier = EntityIdentifier(
                    for: ScanEntity.self,
                    identifier: library.fileIdentifier(for: scan.id)
                )
            }
    }
}
```

### 9.6 The notification

```swift prelude:guide-context
// ✅ VERIFIED (Apple code sample, 343 @ 21:07) — notification entity annotation.
import AppIntents
import UserNotifications

func notifyOCRFinished(for scan: Scan, in library: ScanLibrary) {
    let content = UNMutableNotificationContent()
    content.title = "Text recognised"
    content.body = "\(scan.name) is now searchable."

    content.appEntityIdentifiers = [
        EntityIdentifier(for: ScanEntity.self, identifier: library.fileIdentifier(for: scan.id))
    ]

    // Schedule as usual.
}
```

That one array is what lets a user who hears the notification on AirPods say *"send that to
Bubbles"* and have it mean the scan, not the last thing they looked at.

### 9.7 What this integration does and does not buy

| Utterance | Works? | Why |
|---|---|---|
| *"Open that third scan"* | ✅ | collection annotation + ordinal reference |
| *"Send this to Bubbles"* (on detail) | ✅ | `.files.file` + `FileRepresentation`, §5.4 |
| *"Send that one to Bubbles"* (after scrolling) | ✅ | collection annotation survives scroll-off, §3.4 |
| *"Send that to Bubbles"* (after the notification) | ✅ | §9.6 |
| *"Describe this scan"* | ⚠️ answered from a **screenshot**, not from `ScanEntity` | §1.2 — nothing in this file participates |
| *"Find my scans about invoices"* | ❌ not covered here | needs indexing — [guide 04](04-entities-spotlight-and-foundation-models.md) |
| *"Rename this scan to Receipts"* | ❌ not covered here | needs `@AppIntent(schema: .files.renameFile)` — [guide 02](02-app-schema-domains.md) |

That last pair is the honest summary of this guide's scope. On-screen awareness makes "this" mean
something. It does not make your app searchable, and it does not make your app do anything.

---

## 10. What is still open

<a name="10-what-is-still-open"></a>

This section is short and it is the most important part of the guide after §1 and §5. Everything
here is a thing Apple could settle with one sentence and has not.

### 10.1 The architectural question — unanswered

> **Is on-screen consumption intended to be limited to the predefined assistant schemas, or should
> a custom `AppEntity` + `Transferable` also be a supported way to expose arbitrary on-screen
> content?**

That is the original poster's phrasing on thread 838329, restated after the community workaround
was accepted. It is the question that decides whether:

- the §5.3 failure is **a bug** — in which case it will be fixed, custom entities will start
  resolving, and building a `.files.file` shim is temporary scaffolding you will later remove; or
- the §5.3 failure is **the design** — in which case the schema surface is the whole of
  actionability, apps in unmodelled categories are permanently excluded from hand-off, and the
  documentation sentence *"Schema application is optional but recommended"* is simply wrong and
  should be corrected.

**Those two futures imply opposite engineering decisions**, which is exactly why an unanswered
architectural question is more expensive than an unimplemented feature.

**Status as of 2026-07-27:** open. Radar **FB23813341**. Apple's DTS engineer routed the thread to
Feedback Assistant without answering. There is no Apple statement in our corpus on either side.

**What to do meanwhile.** Assume the second future, because it is the one that matches observed
behaviour, and build the `.files.file` route if you need hand-off. It works today. If the first
future arrives, you will have written a shim you can delete — which is a much better position than
having designed around a capability that never materialises.

**Related, and equally open** (from the wider forum cluster): thread 829586 — 14 replies, ~1,000
views, the most-discussed thread in the area — reached the same conclusion from the intent side,
and its radar **FB23018652** was characterised by DTS as *an enhancement request, not a bug*. That
is a data point, though not an answer: it suggests Apple currently regards the schema restriction as
intended behaviour. [Guide 02 §6](02-app-schema-domains.md) covers the consequences for apps with
no applicable domain.

### 10.2 The documentation contradiction — unreconciled

Restated here so it is findable: *"Schema application is optional but recommended for consistency"*
(Apple docs) versus a non-schema entity never resolving for hand-off (observed, iOS 27 beta 3).
§5.6 gives a reading that makes both true. **Apple has not confirmed that reading**, and until they
do, the documentation sentence is actively misleading for the transfer case.

### 10.3 The `NSUserActivity` conflict — unresolved

Two Apple sessions teach it and recommend it; one instrumented forum report says it produced no
callbacks at all on beta 3. §3.2, §8.6, GAP G6. We are not able to tell you which is right.

### 10.4 Where this guide's brief and the research notes disagreed

For the series' own auditing purposes, three places where the outline this guide was written from
was tightened by what the notes actually contain:

1. **`AppEntityUIElement` is weaker evidence than it looks.** The brief describes it as a first-class
   fourth annotation shape with *identifier + bounds + selection*. Session 343's **published code
   samples contain no canvas example** — only `NowPlayingView`, `AlbumView` and
   `PlaylistDetailView`. The canvas category and `PianoRollView` are attested from narration; the
   `AppEntityUIElement(identifier:bounds:state:)` spelling is not. It is therefore presented as
   🟡 RECONSTRUCTED with a gap box (§3.5, G4), not as a fourth verified API.
2. **`entities(for:)` is "never called in **most** flows", not "never called".** The instrumentation
   table shows one path — the ChatGPT hand-off — where it *did* fire and then stalled. That
   distinction changes the diagnosis (§1.6's fourth row) and is preserved.
3. **The `NSUserActivity` row in the same table** reports the route as never consumed, which
   contradicts two Apple sessions. The brief did not mention this; the notes do; it is surfaced as
   §8.6 rather than silently dropped.

---

## 11. Gap register

<a name="11-gap-register"></a>

Everything in this guide we could not verify, what would resolve it, and what to ship meanwhile. A
🔴 GAP box in this series never contains a guess.

| # | Gap | What would resolve it | Safe default |
|---|---|---|---|
| G4 | **The canvas annotation API** — `AppEntityUIElement`'s initializer spelling, the `bounds` type and coordinate space, the selection-state type, and the modifier that consumes them. (§3.5) | The **CosmoTunes sample project**, which contains `PianoRollView` and is published by Apple; or the docs page | Use shapes (b)/(c) unless you genuinely draw your items; let Xcode completion supply the spelling |
| G5 | **UIKit/AppKit data-source protocol requirements** — one method signature known, from a forum post; the declaring protocol and the three sibling protocols' methods are unverified. (§3.6) | The four `*AppIntentsDataSource` doc pages, or an SDK dump | Implement `collectionView(_:appEntityIdentifierForItemAt:)` and let the compiler name the protocol |
| G6 | **Does `NSUserActivity.appEntityIdentifier` work on shipping 27?** Two sessions say yes; one instrumented report says no callbacks on beta 3. (§3.2, §8.6, §10.3) | Testing it on a current build; an Apple statement | Adopt it, but verify in isolation with §1.6 before building on it; keep shape (b) as a control |
| G7 | **`DisplayRepresentation.Components` cases beyond `.text`**, and whether it is an `OptionSet` or an enum. (§4.4) | The `Components` doc page, the CosmoTunes sample, or an SDK dump | **Never branch on it.** Pass it through to `displayRepresentation(with:)` unexamined — that code is correct for any case list |
| G8 | **`displayRepresentation(with:)`'s exact signature** — `async` vs `async throws`, whether the macro synthesises a default. (§4.5) | The `AppEntity` protocol page, or the sample | Write it as shown; take the compiler's correction if it objects |
| G9 | **`ValueRepresentation` vs `IntentValueRepresentation`** — same apparent role, two spellings, two sessions, no reconciling page. (§5.2) | The App Intents symbol index, or an SDK dump | Use whichever autocompletes; **do not port code between the spellings assuming equivalence** |
| G10 | **Saved-file identifier persistence semantics** — what `file(url:)` throws, whether `fileURL` does I/O, and whether the identifier is bookmark- or path-backed. The factories, draft API, availability and `Hashable` conformance are now verified.[^file-identifier-api] | Apple documentation of the storage contract, or move/rename testing | Treat the URL as the source of truth; handle `fileURL` returning `nil` at every call site |
| G11 | **The file lifetime contract for hand-off** — how long the file must survive, whether the system copies or hands over the URL, whether deleting mid-transfer errors or fails silently. (§5.5) | An Apple statement (none exists); or empirical deletion testing | Keep the file for the whole time the content is on screen plus a grace period; clean up coarsely |
| G12 | **What happens if a `TransientAppEntity` identifier reaches an annotation surface** — compile error, assertion, or silent no-op. (§6.5) | Trying it; the `TransientAppEntity` docs page | Assume silent; decide transient-vs-persistent with the system-integration question explicit |
| G13 | **`MPNowPlayingInfoPropertyAppEntityIdentifiers`** — spelling unverified against a header, and its relationship to the `NowPlaying`-framework route unknown. (§6.2) | The Media Player docs, or a header | Use the `MediaSessionRepresentable` / `MusicContent` route from the verified sample |
| G14 | **Any latency budget for on-screen entity resolution.** Apple publishes no number; no community measurement exists. (§4.6) | An Apple statement, or a community benchmark somebody publishes | Instrument your own with `OSSignposter`; optimise by mechanism (one fetch, no I/O), not to a target |
| G15 | **Does `.appEntityIdentifier(_:)` accept an optional?** Every Apple sample passes a non-optional; the write-out pattern would like to pass a `try?`. (§5.5) | The modifier's signature | Not silent — the compiler tells you immediately. Hoist the optional into a computed property if needed |
| G16 | **Whether the `.system.searchInApp` / index routes can serve descriptive on-screen questions** that the screenshot path answers badly (thread 837249's real need). (§1.3, §7.3) | Empirical testing | Render the information the user asks about, or route them into your own search UI; do not expect the entity path to be consulted |

### Corrections from the series register applied here

- **C8** — this is guide 2 of the three App Intents / Siri guides that correction C8 calls for.
  Its two mandated cautions are carried: release-year labels are soft (version-floor box), and
  `ValueRepresentation` vs `IntentValueRepresentation` is an unresolved naming hazard (§5.2, G9).
  The mandated honesty about the DTS deflection and the documentation contradiction is §5.6–§5.7
  and §10.
- **C1** — the Siri-enablement availability coupling is presented in *What you need* as **a bug with
  an Apple acknowledgement**, not as a gate to design around.
- **C9** — the sample-code corrections register applies here only negatively: **`coreai` has zero
  sample-code projects**, and no App Intents sample was obtained either. Where this guide would
  have been much stronger with a compiling Apple project, it says so (§3.5, G4).

---

## 12. Sources

<a name="12-sources"></a>

Ordered by evidence class, strongest first. Every claim in this guide traces to one of these.

### Class 1 — Apple sample-code projects

**None.** There is no App Intents / on-screen-awareness sample project in this series' corpus.
Sessions 240 and 343 name three published samples — **CosmoTunes**, **UnicornChat** and
**CometCal** — and obtaining any of them would upgrade several 🟡 markers in §3.5 and §4 to ✅ in
one pass. The reusable discovery recipe recorded in the series' correction register is:

```
developer.apple.com/tutorials/data/index/<framework>   → filter type == "sampleCode"
developer.apple.com/tutorials/data/documentation/<framework>/<slug>.json
                                                        → grep for the docs-assets…zip URL
```

(`sosumi.ai` does not expose sample ZIPs; use the tutorials JSON API.)

⚠️ Two samples elsewhere in the corpus — the coffee/generative-game sample and the SpeechAnalyzer
sample — are **stale iOS 26 / WWDC25 leftovers** and are never cited as 2026 evidence anywhere in
this series.

### Class 2 — Apple-published code samples on WWDC26 session pages

These are verbatim Apple text, published alongside the transcripts, and they are the strongest
evidence in this guide. Fetched 2026-07-27 directly from `developer.apple.com/videos/play/wwdc2026/<n>/`
— which works without a mirror and returns transcript *plus* code blocks.

| Citation | Supplies |
|---|---|
| **343 @ 16:27** | The three annotation shapes: `NowPlayingView` (`NSUserActivity`), `AlbumView` (`.appEntityIdentifier(_:)`), `PlaylistDetailView` (`.appEntityIdentifier(forSelectionType:_:)`) — §3.2, §3.3, §3.4 |
| **343 @ 17:23** | `displayRepresentations(for:requestedComponents:)`, `DisplayRepresentation.Components.text`, `displayRepresentation(with:)` — §4.3 |
| **343 @ 21:07** | Notification / Now Playing / AlarmKit entity annotations — §6 |
| **343 @ 4:26** | `DisplayRepresentation(title:subtitle:image:)` — §4.7 |
| **240 @ 17:19** | Per-row `.appEntityIdentifier` in a `ForEach` — §3.4, §8.2 (shown as the *simple* form) |
| **240 @ 18:18 / 19:21 / 20:00** | `IntentValueRepresentation(exporting:)`, `IntentValueQuery.values(for:)`, `IntentValueRepresentation(exporting:importing:)` — §5.2 |

### Class 3 — Apple documentation

Read 2026-07-27 through the `sosumi.ai` markdown mirror
(`developer.apple.com/documentation/X` → `sosumi.ai/documentation/X`), recorded in
`notes/web/app-intents-siri-schemas.md`.

- `/documentation/appintents/providing-contextual-cues-to-apple-intelligence-and-siri` — the
  *"Schema application is optional but recommended for consistency"* sentence (§5.6), the
  UIKit/AppKit symbol list (§3.6), and `MPNowPlayingInfoPropertyAppEntityIdentifiers` (§6.2).
- `/documentation/appintents/making-actions-and-content-discoverable-by-apple-intelligence` —
  *"Without both layers, Apple Intelligence cannot act on user requests involving your entities"*
  (§5.6).
- `/documentation/appintents/app-schema-domain-files` — the `.files` domain's inventory (§5.4).
  ⚠️ **This page does not mention `FileEntityIdentifier` or `FileRepresentation`.** The linkage
  came entirely from the forum thread. That is a documentation gap and it is why the working recipe
  was undiscoverable from the docs.
- `/documentation/appintents/entityidentifier` and `/fileentityidentifier` — fetched directly on
  2026-07-28 to resolve the earlier availability, conformance, initializer, and draft-identity
  gaps.[^entity-identifier-api][^file-identifier-api]
- ⚠️ **`/documentation/appintents/making-onscreen-content-available-to-siri-and-apple-intelligence`
  returned HTTP 404.** The article is cited by name in thread 838329, so it exists or existed; the
  live equivalent appears to be the contextual-cues page. Noted in §5.6.

[^entity-identifier-api]: Apple,
    [`EntityIdentifier`](https://developer.apple.com/documentation/appintents/entityidentifier),
    documents the type's two initializers, `entityType` and `identifier` properties, `Hashable` and
    `Sendable` conformances, and iOS 16 / macOS 13 availability.
[^file-identifier-api]: Apple,
    [`FileEntityIdentifier`](https://developer.apple.com/documentation/appintents/fileentityidentifier),
    documents iOS 18 / macOS 15 availability, `Hashable`, `Codable`, and `Sendable` conformances,
    the saved-file and draft accessors, and both factories. The dedicated
    [`draft(identifier:)`](https://developer.apple.com/documentation/appintents/fileentityidentifier/draft%28identifier%3A%29)
    page specifies that draft identifiers are for documents not yet materialized on disk and
    therefore have no file URL.

### Class 4 — Apple-staff forum answers

One, and it is a non-answer, which is itself the finding:

- **Thread 838329**, DTS Engineer: *"…Because you submitted a focused sample and the same
  explanation on a good written bug, I'll let the team take over all the issues."* Radar
  **FB23813341**. Quoted in full at §5.7.
- **Thread 829586**, DTS: characterised **FB23018652** (App Schemas restricting custom
  entities/actions) as *an enhancement request, not a bug*. §10.1.
- **Thread 836760**, Apple Frameworks Engineer — outside this guide's topic but load-bearing for
  *What you need*: the Foundation Models / Siri-enablement coupling is **a bug**.

### Class 5 — WWDC26 session transcripts

Fetched 2026-07-27; saved to the corpus. Prose lines cite the `.txt`; code blocks cite
`notes/transcripts/missing-sessions.md`, which is where Apple's separately-published code samples
were reproduced.

| Session | Title | Presenter | Local transcript |
|---|---|---|---|
| **343** | Explore advanced App Intents features for Siri and Apple Intelligence | Antonio Cancio, App Intents | `transcripts/wwdc2026-343.txt` (219 lines) |
| **240** | Build intelligent Siri experiences with App Schemas | Dan Niemeyer, Swift Intelligence Frameworks | `transcripts/wwdc2026-240.txt` (256 lines) |
| **344** | Code-along: Make your app available to Siri | Justin Kang, Swift Intelligence Frameworks | `transcripts/wwdc2026-344.txt` (232 lines) |
| **345** | Discover new capabilities in the App Intents framework | Moe, App Intents | `transcripts/wwdc2026-345.txt` (202 lines) |

⚠️ **Session 344 has no published code-sample block** — its code was narrated on screen only. Every
code-shaped thing attributed to 344 anywhere in this series is reconstructed from narration, and
this guide quotes 344 only for **prose**, never for code.

Session 343 chapter 16:22 (*"Onscreen awareness"*) is the richest single source on this topic in
existence, and chapter 20:51 (*"Leverage existing integrations"*) supplied all of §6.

### Class 6 — Community, always attributed

- **Forum thread 838329** — *"Is `.appEntityIdentifier` + `Transferable` the intended way to let
  Siri send an on-screen image to another app? (iOS 27)"*, FrankSchlegel, **17 July 2026**, 4
  replies / 246 views. Supplies: the two-path instrumentation table (§1.2), the failing
  configuration (§5.3), and — from replier `J0hn`, marked as the recommended answer and reported
  *confirmed working on device on iOS 27* — the entire working recipe (§5.4). **Device model not
  stated; OS reported as iOS 27 beta 3.** Our corpus records iOS 27 beta 3 as build **24A5380h**,
  released **6 July 2026**.
- **Forum thread 837249** — *"Siri AI's onscreen awareness can't understand an `AppEntity` without a
  schema?"*, haozes, **8 July 2026**, **0 replies** / 205 views. Supplies §1.3.
- **Forum thread 829586** — *"Confused about App Intents integration in iOS 27"*, 14 replies,
  ~1,000 views. The most-discussed thread in the cluster. §10.1.
- **Forum thread 835903** — raw `TypedValueToContentGraphResolutionErrorDomain` error 4 reaching end
  users through Siri AI. §8.8.

**The cluster-level finding, which is itself worth citing:** across the App Intents / Siri /
on-screen threads examined, there was **one substantive Apple answer** (836760, about Foundation
Models availability), **one deflection to Feedback Assistant** (838329), and **the rest
unanswered**. The one genuinely useful technical answer in the cluster came from another developer.

### Corpus files behind this guide

- `notes/web/app-intents-siri-schemas.md` (1,652 lines) — the documentation and forum pass. §5 and
  §5.7 are largely its §5 and §11.1.
- `notes/transcripts/missing-sessions.md` (3,216 lines) — the session pass, including Apple's
  published code samples reproduced verbatim. §1.1, §3, §4 and §6 are largely its §1.11–§1.14.
- `notes/forums/forum-pain-points.md` (1,538 lines) — the forum cluster, §3.45–§3.46 and Cluster H.
- `notes/CORRECTIONS-PENDING.md` — items C1, C8, C9, C10.3 and C10.6 as applied above.

### How to re-verify anything in this guide

1. **Session code samples:** fetch `https://developer.apple.com/videos/play/wwdc2026/343/` directly;
   the response includes the transcript *and* the code-sample block with timestamps. No mirror is
   needed. The same works for 240, 344 and 345.
2. **Documentation:** use `sosumi.ai/documentation/<path>`. A plain fetch of
   `developer.apple.com/documentation/...` does **not** work because the page is client-rendered;
   the response contains only the `<title>`.
3. **Forum threads:** fetch `developer.apple.com/forums/thread/<id>` **directly**. The RSS captures
   in the corpus have truncated bodies and **no replies** — and the replies are where both the
   Apple answers and the community recipe live. This is a general lesson: the RSS captures
   systematically omit the authoritative half of every thread.
4. **The remaining gaps:** several API-shape questions in G4–G15 would fall to a single
   `AppIntents` module-interface dump from the Xcode 27 SDK (`swift-api-digester`, or the
   `.swiftinterface` in the SDK) — the identifier surface above was settled the lighter way, by
   fetching the two documentation pages directly on 2026-07-28 — or to downloading the CosmoTunes
   sample. Behavioral questions still require device testing.

---

*Guide last verified 2026-07-27 against the sources above; the identifier API surface was
re-verified directly on 2026-07-28.[^entity-identifier-api][^file-identifier-api] The two forum
threads it answers were open and unanswered by Apple on the earlier date. If you are reading this
after a later 27.x release, re-run §1.6's five-minute diagnostic before trusting §5.3's negative
result: the one thing every party to this agrees on is that the behaviour is beta behaviour.*
