# Part 16 — Adjacent capabilities

**Version floor:** deliberately mixed, and this is the part where version confusion costs the most. The
*new* material floors at **iOS · iPadOS · macOS · visionOS 27 with Xcode 27** —
`CaptureInputSequenceProvider`, `AnalyzerInputConverter`, `LongRunningIntent`, `ExecutionTargets`,
`SpotlightSearchTool`, `IndexedEntityQuery`, `RelevantEntities`. The machinery
underneath it is much older and must not be version-confused with it: the `SpeechAnalyzer` pipeline is
**26.0**, `SFCustomLanguageModelData` is **iOS 17.0 / macOS 14.0**, `StringSearchCriteria` is **iOS 17.2
/ macOS 14.2**, `SnippetIntent` is **26.0** and is routinely mis-reported as new this year,
`EntityIdentifier` is **iOS 16 / macOS 13**, `FileEntityIdentifier` is **iOS 18 / macOS 15** and
supports draft documents that are not yet on disk, `Transferable` / `FileRepresentation` are iOS
16-era, and Core Spotlight predates all of it by years.[^identifier-availability]
16.5 has **no OS floor**: DNIKit is desktop Python (`>=3.7`, 3.9 recommended, **3.9.7 broken**).

**Who this is for:** developers wiring an app *into* the system rather than running a model — speech in,
Siri actions, on-screen context, Spotlight-backed retrieval. Guides 16.1–16.4 are Swift app work and
assume no Core AI or MLX knowledge; 16.5 is for Python ML engineers and is disconnected on purpose.

---

## ⚠️ Two things to learn before you plan anything

**1. There is no new text-to-speech API.** The WWDC26 keynote advertised speech *generation* —
Federighi at **30m:20s** describing a model that "lets supported products understand **and generate**
speech." Developers went looking for the API, found nothing, and asked. Apple staff answered on
Developer Forums **thread 834149**, verbatim: *"The short answer is no. No new API has been released
specific to that model. Though of course you still have the older existing speech synthesis APIs in AV
Foundation."* A second thread (**832868**), citing the keynote timestamp directly, has **zero replies**.
Speech-*in* is genuinely new and genuinely good this year; speech-*out* is the AVFoundation API you
would have shipped in 2019. 16.1 §1.1 carries the full quotation and a 🔴 GAP box distinguishing *"no
API has been released"* from *"no API will be."* Budget accordingly.

**2. The App Intents guides here answer questions Apple itself left unanswered.** Of the App Intents /
Siri / on-screen forum threads in this corpus, **one** had a substantive Apple answer, **one** was
routed to Feedback Assistant without being answered, and the rest are unanswered — the single most
useful technical answer in the whole cluster came from **another developer**. Guides 16.3 and 16.4 are
written to close exactly those holes, and they name their evidence class every single time.

---

## Why this part exists

These are the capabilities that sit *next to* the model rather than inside it: nothing here generates a
token. Four of the five guides are about getting real-world material — audio, entities, screen context,
index content — into a shape Apple Intelligence can use, which is where integrations actually fail:

1. **The surface is documented but never assembled.** App Intents spreads its schema surface across
   roughly twenty-four pages — one index plus one per domain. No page anywhere, Apple's or otherwise,
   puts all 23 domains in one place, so nobody can answer *"is there a schema for what my app does?"*
   without a day of clicking. 16.2 is that page.
2. **The evidence class is weaker than the rest of the series.** There is **no Apple sample project**
   for schema domains or on-screen awareness in this corpus, and the *only* downloadable Speech sample
   is a **WWDC25 leftover** containing none of the 2026 symbols. Three of these guides therefore stand
   on documentation pages, Apple's published session code blocks and forum answers — and say so in a
   box at the top rather than pretending otherwise. Since 2026-07-29, **16.2 and 16.4 are
   additionally checked symbol-by-symbol against the macOS 26.5 and 27.0-beta SDK interfaces** in
   `notes/sdk-interfaces/`, which upgraded their headline claims to ✅ SDK-verified and closed
   seven of their gap-register entries between them.
3. **A known-negative is as load-bearing as an API.** "No TTS API" and "no fitness / health / finance /
   commerce / travel / food / transport / social / education / games schema domain" are both
   *findings*, and both change roadmaps. Guides 16.1 §1 and 16.2 §6 lead with them.
4. **Nothing throws.** A transcript that quietly loses its last sentence, an update intent that
   silently ignores "remove the due date", an entity layer built for a request class that never
   consults it, a model confidently inventing article bodies because the index is searchable but not
   readable — all clean consoles, all shipping code.

---

## Read this first: the triage table

| If your situation is… | Read | Why |
|---|---|---|
| "The keynote promised speech generation and I can't find the API" | [16.1 §1.1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#11-there-is-no-new-text-to-speech-api) | It does not exist. AVFoundation, per Apple staff on thread 834149 |
| "I'm learning the 2026 Speech API from the downloadable sample" | [16.1 §1.2](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#12-the-speechanalyzer-sample-project-is-a-wwdc25-leftover) | That ZIP is WWDC25. It has **none** of the 2026 input symbols |
| "Users report the last sentence gets cut off" | [16.1 §9, §6.6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#9-️-the-cancellation-shield) | The cancellation shield — or a missing `AnalyzerInputConverter.flush()` |
| "My transcript reads *'I went to the I went to the store'*" | [16.1 §8.3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#83-️-silent-failure-strategy-a-silently-degrades-to-append-only) | Your preset does not emit `.audioTimeRange`, so the merge always appends |
| "Empty transcript, clean console" | [16.1 §5.5](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#55-what-breaks-if-you-skip-assets-entirely) | Assets before format before analyzer before audio. The analyzer converts nothing |
| "Is there a Siri schema for what my app does?" | [16.2 §5–§6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/02-app-schema-domains.md#5-the-complete-enumeration--all-23-domains) | All 23 domains enumerated — then the categories with no domain at all |
| "My category isn't covered. What is left?" | [16.2 §8](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/02-app-schema-domains.md#8-systemsearchinapp--the-escape-hatch) | `.system.searchInApp`, with code. Works without domains or indexing |
| "*'Remove the due date'* reports success and changes nothing" | [16.2 §14.1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/02-app-schema-domains.md#141-️-silent-failure--intentparametervaluestate-clear-it-and-dont-touch-it-are-not-the-same-thing) | `IntentParameter.valueState`. A `nil` check cannot express "clear it" |
| "Siri answers from my screen text and ignores my `AppEntity`" | [16.3 §1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/03-onscreen-awareness.md#1-the-two-paths) | Descriptive requests take the screenshot path and never call `entities(for:)` |
| "*'Send this to X'* → *'I can't attach the image from your screen'*" | [16.3 §5](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/03-onscreen-awareness.md#5-handing-content-to-another-app) | `.files.file` + `FileEntityIdentifier` + **`FileRepresentation`**; the verified export path needs a real file, while draft identifiers cover pre-materialization identity[^identifier-availability] |
| "Siri asks to clarify, or acts on the wrong item" | [16.3 §4, §8.2](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/03-onscreen-awareness.md#4-fast-resolution) | A slow `displayRepresentations`; or per-row annotation on a scrolling list |
| "My own model invents details for content I indexed" | [16.4 §7.3, §9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#73-️-silent-failure--the-index-is-searchable-but-not-readable) | The index is searchable, not readable. The hydration hook is the fix |
| "What are *'indexed entities for Apple Intelligence'*?" | [16.4 §1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#1-the-question-and-its-answer) | `IndexedEntity` + `indexAppEntities(_:)`. Same index, different door |
| "Dirty dataset, or a convnet that may be over-wide" | [16.5 §6.3, §6.5, §8](references/05-dnikit-dataset-and-model-introspection.md#63-duplicates--the-one-you-should-run-first) | `Duplicates` and PFA. Prune, retrain, *then* convert |
| Anything transformer, MLX, Core ML or Core AI shaped | **skip [16.5](references/05-dnikit-dataset-and-model-introspection.md)** | DNIKit supports none of them. §1 says so in a table |

---

## The guides in this part

### [16.1 — SpeechAnalyzer: live transcription, assets, and custom vocabulary](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md)

The 2026 speech-to-text stack end to end: an actor owning analysis modules, fed one time-coded audio
sequence, handing each module's output back as its own `AsyncSequence` — with **no accumulated
transcript**, because assembling the document is your job. The year's real change is small and entirely
on the input side (Apple's whole published changelog is two bullets): you no longer hand-build the audio
tap. Covers transcriber choice, both preset matrices, `AssetInventory` and its reservation quota, result
merging, the `SFCustomLanguageModelData` DSL, and §14's alternative — `CoreAISpeech`, Whisper on the
Core AI runtime, cross-linked to Part 7.

> ⚠️ **SILENT FAILURE — the cancellation shield (§9).** Cancel the task that *displays* results and it
> stops reading before the transcriber emits its final updates: **the last phrase of every recording is
> lost, with no error of any kind**, and it never reproduces when you pause before hitting stop — which
> is how everyone tests. Eleven more in §16, including a conflict between two Apple pages that degrades
> time-range merging to append-only, and `bestAvailableAudioFormat` returning `nil` if you query it
> before installing assets.
>
> ✅ **SDK-verified 2026-07-29** against the `Speech-26.5` and `Speech-27.0` (macOS 27.0 beta)
> `.swiftinterface` dumps in `notes/sdk-interfaces/`: every Swift-native symbol, signature,
> availability floor and enum case now carries a file:line citation. Of the original **24 declared
> unknowns**, **12 closed** against the interfaces (several with corrections — `convert(_:at:)`
> takes `AVAudioTime?` not `CMTime?`, `DictationTranscriber` *does* have `alternatives`, and
> `AnalyzerInput.bufferDuration`/`bufferFormat` turn out to be 27-only) and **12 remain open** —
> mostly behavioural questions and ObjC-side API (`SFSpeechLanguageModel.Configuration`) that no
> Swift interface can settle. §15 keeps the full open/closed ledger. The former finish-method
> signature gap is resolved by Apple's current async declaration for
> `cancelAndFinishNow()`.[^speech-cancel]

### [16.2 — App Schema Domains: the complete map of what Siri can actually do](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/02-app-schema-domains.md)

The enumeration is the product: **all 23 domains in three tiers — 182 intents, 74 entities and 50
enums, censused symbol-by-symbol against the macOS 27.0 beta SDK interface on 2026-07-29** — in one
place for the first time, with per-domain commentary on what each one's shape tells you. The SDK
pass corrected five domains the doc pages under-report (clock's entire stopwatch surface among
them). Around it: Apple's discovery-versus-action framing (the most clarifying paragraph in the area), the
macro system and the build errors it generates, query protocols, dialog and snippets, and §13's new
execution model — `LongRunningIntent` past the 30-second wall, `ExecutionTargets`, `EntityCollection`,
`@UnionValue`, `SyncableEntity`. **§6 is the section most readers need**: the categories with no domain.

> ⚠️ **SILENT FAILURE — `IntentParameter.valueState` (§14.1).** In an update intent, `nil` means both
> *"clear this field"* and *"the user never mentioned it"*, and a `nil` check cannot tell them apart.
> The obvious `if let` implementation compiles, runs, returns success, and silently ignores every
> *"remove the due date"* the user will ever say. `.set(value)` / `.set(nil)` / `.unset` is the fix.
>
> 🔴 **GAP — a 21-entry register (§16), five entries closed against the 27.0 beta SDK interface on
> 2026-07-29** — among them the `ValueRepresentation` vs `IntentValueRepresentation` hazard, now
> resolved: they are **one type** (`ValueRepresentation` is an `AppEntity`-scoped typealias), so the
> spellings cannot diverge. Still open: Apple's per-schema documentation is thin — required
> properties are verified for exactly two of ~180 schemas, and the co-requisite graph rests on one
> demonstrated pair.

### [16.3 — On-screen awareness: making Siri understand "this"](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/03-onscreen-awareness.md)

This guide exists to answer two live forum threads Apple did not: a cycling app whose `AppEntity`
executes but which Siri answers from screen text, and an image app whose `entities(for:)` **never
fires**. Same problem from two sides, and the unifying finding is the most useful thing here: **there
are two on-screen paths.** Descriptive requests (*"describe this"*) take a screenshot/OCR path and never
consult your entities; only hand-off requests (*"send this to X"*) enter true entity resolution. Around
that: `EntityIdentifier` and its five consumers, the four annotation shapes,
`displayRepresentations(for:requestedComponents:)`, and §6's notification / Now Playing / AlarmKit uses.

> ⚠️ **SILENT FAILURE — eight (§8), two dominant.** Building an entity layer for a request class that
> never consults it costs weeks and breaks nothing (§8.3) — thread 837249 is exactly that story, and
> §1.6's five-minute instrumentation tells you which path you are on *before* you start. And per-row
> `.appEntityIdentifier` in a `ForEach` — **which Apple's own published sample does, uncaveated** —
> loses selected and scrolled-off entities the moment SwiftUI recycles the row (§8.2).
>
> ⚠️ **The recipe in §5 is community evidence and the guide never dresses it up.**
> `@AppEntity(schema: .files.file)` + `FileEntityIdentifier.file(url:)` + **`FileRepresentation`** (not
> `DataRepresentation`) is reported working on device on iOS 27 by a developer, not by Apple; Apple's
> docs point elsewhere and its DTS engineer routed the underlying question to Feedback Assistant
> (**FB23813341**) without answering it. Both appear side by side in §5.7, unreconciled. Draft
> identifiers support unsaved document identity, but this verified `FileRepresentation` export still
> needs a real file payload, so transient renders must be written out before hand-off.[^identifier-availability]

### [16.4 — One index, three consumers: entities, Spotlight, and Foundation Models](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md)

Session 246's one-line prerequisite — *"donated searchable items to Core Spotlight, **or indexed
entities for Apple Intelligence**"* — left a second on-ramp nobody could identify. It is `IndexedEntity`
+ `CSSearchableIndex.indexAppEntities(_:)`, and it is **not a second index**: same Core Spotlight index,
different door. Hence the thesis — one index, read by Siri's entity resolution, by `SpotlightSearchTool`
(your own model doing RAG) and by Spotlight itself, so one indexing investment serves three surfaces and
one gap starves all three at once. Both on-ramps are given complete, §5 says where they differ, and
§14's adoption sequence is not the order you would guess.

> ⚠️ **SILENT FAILURE — the index is searchable but not readable (§7.3).** Some Spotlight metadata is
> stored in a compact form the model cannot read back, so `SpotlightSearchTool` sees identity attributes
> and **invents the bodies**. §9's hydration hook is the documented fix; its signature is a
> **completion-handler** method — `nonisolated`, non-throwing, not array-returning — and two field
> reports say it did not fire on 27.0 betas. Also §12.3: `RelevantEntities` has **no TTL**, so every
> registration needs a matching removal.
>
> 🔴 **GAP (G5) — the seam between the two halves.** Whether that hook fires at all for content indexed
> via `indexAppEntities(_:)` is documented nowhere: not the docs, not the sessions, not the samples, not
> any forum answer — and not the SDK either: the 2026-07-29 interface pass (which closed G1,
> `IndexedEntity` is iOS 18 / macOS 15, and G4, `priority: Int = 0`) cannot see it, because the
> delegate is Objective-C and outside the Swift module interface. That is the natural path for an
> App Intents-first team and every step of its failure
> is silent. §10 covers nothing else; the safe default is blunt — if you need model-readable bodies,
> donate `CSSearchableItem`s too.

### [16.5 — DNIKit: auditing datasets and networks before you convert](references/05-dnikit-dataset-and-model-introspection.md)

The shortest guide in the series, on purpose. Every other part assumes your model is good and asks how
to deploy it; this one asks whether your *data* is good and whether your network is the size it needs to
be. `Duplicates` finds near-duplicates inflating your validation score, `Familiarity` shows your splits
are not from one distribution, and **PFA** returns per-layer filter counts — prune and retrain first,
quantize second (§8). It is equally clear about fit: **skip it unless you have a data-quality problem.**

> 🔴 **The evidence position is one repository and the guide leads with that.** No WWDC session, no
> Apple documentation page, no forum thread, no sample project. `CONTRIBUTING.md` says verbatim there
> are *"limited plans for future development"*; three commits at depth 50 (2.0.0 in 2023, one 2026
> Keras-3 fix); **no Core AI, no Core ML, no MLX, no Swift** — `coremltools` and `mlx` appear nowhere in
> the tree. Nothing was executed during research (G1): treat every listing as a faithful transcription,
> not a smoke-tested recipe. ⚠️ And **five silent failures (§10)** — the `Familiarity` score's sign is
> documented one way and implemented the other, PFA drops unanalysable layers with only a
> `warnings.warn`, and pre-`2f39056` Keras 3 yields an empty layer list rather than an error. §7's
> worked example carries inline guards for each.

---

## Reading order

**Nobody reads this part front to back, and it is not built for that.** Pick by the surface you are
integrating; the four Swift guides are independent enough to take in any order.

**Anything Siri- or Spotlight-shaped starts at [16.2 §2 and §5–§6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/02-app-schema-domains.md#2-discovery-versus-action--the-framing-everything-else-follows-from)**
— fifteen minutes that tell you whether the schema system covers your app at all, which gates everything
after it. If it does not, §8's `.system.searchInApp` plus 16.4's indexing is your whole available
surface and most of 16.3 becomes optional. **Then 16.4 before 16.3** for discovery or your own RAG, or
**16.3 before 16.4** for *"do this to the thing on screen"* — and in that case read
[16.3 §1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/03-onscreen-awareness.md#1-the-two-paths) before writing a line, because it decides whether the
work is worth doing at all. **Speech is standalone:**
[16.1 §1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#1-two-warnings-before-you-write-any-code) is mandatory and takes two minutes, and §9 and
§16 decide whether your feature ships correctly.

**Deferrable:** 16.1 §11 (custom vocabulary) until real transcripts show which terms fail, and §14 until
you have your own ASR model; 16.2 §13's execution model until you hit the 30-second wall; 16.3 §6 until
basic annotation ships; 16.4 §9–§10 until `SpotlightSearchTool` returns plausible-but-wrong answers.
**Skippable outright:** [16.5](references/05-dnikit-dataset-and-model-introspection.md) unless you have
a TF2/Keras vision model and a data-quality question — its §1 table settles that in thirty seconds.

---

## What this part deliberately does not cover

- **Speech synthesis.** Not because it is out of scope, but because **there is no 2026 API to cover**
  (16.1 §1.1). AVFoundation's speech synthesis is unchanged and outside this series.
- **`SpotlightSearchTool` itself** — configuration, the `SearchReply` stream, `queryToken`, guidance
  levels and their token cost, the contact resolver, the documented failure modes, and the OCR and
  barcode tools — is [Part 2 guide 04](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md);
  read it to build the feature, 16.4 to see why it is only as good as your index.
- **Feeding transcripts or entities into a model.** `LanguageModelSession`, `@Generable`, `Tool` and
  the failure taxonomy are [Part 2](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/README.md); context management is
  [Part 3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/README.md). There is **no `AppIntent` → `LanguageModelSession`
  bridge**; the connection runs through the Spotlight index.
- **Running your own ASR or vision model.** `AIModel`, `InferenceFunction`, states and specialization
  are [Part 7](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/README.md); producing the encoder/decoder split `SpeechBundle`
  needs — which nothing in `apple/coreai-models` currently emits — is
  [Part 8](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/README.md); PFA's *"prune, convert, compress"* handoff lands in
  [Part 9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md).
- **Measuring what you shipped**, including session 246's result-coverage metric for Spotlight-grounded
  features: [Part 6](../part-06-evaluations/README.md). DNIKit runs before training finishes; Evaluations runs
  after the app is built.
- **Availability and gating**, including the acknowledged bug where
  `SystemLanguageModel.default.availability` reports `.appleIntelligenceNotEnabled` merely because Siri
  is switched off: [Part 1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/README.md). Coming from an iOS 26 app:
  [Part 17](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/README.md).

---

## Sources for this part

**Apple documentation**, fetched 2026-07-27 via `sosumi.ai` mirrors: `/documentation/speech/recognizing-speech-in-live-audio`
(16.1's primary source) plus ~32 Speech reference pages; the App Intents landing page, the 23-domain
schema index and eleven itemized per-domain pages, the discovery and contextual-cues articles,
`/appintents/making-app-entities-available-in-spotlight`, `/updates/speech` and `/updates/appintents`.
**Apple sample code:** the session-246 project (`LLMSearchUsingCoreSpotlightApp`,
six Swift files, `IPHONEOS_DEPLOYMENT_TARGET = 27.0`) is the strongest evidence in the part and outranks
the transcripts where 16.4 §9 disagrees with them; `BringingAdvancedSpeechToTextCapabilitiesToYourApp.zip`
is cited **only** as evidence that it is a stale WWDC25 artifact. **WWDC26 sessions 240, 246, 343, 344
and 345**, fetched from `developer.apple.com`, which returns the transcript *and* Apple's published
code-sample blocks — a separate artifact whose agreement with the prose is genuine corroboration;
session 344 published no code block, so everything code-shaped attributed to it is marked 🟡. **Apple
Developer Forums**, with Apple answers distinguished from developer answers every time: 834149 (the TTS
non-answer), 832868 (zero replies), 833658 (`IndexedEntity` is backed by a `CSSearchableItem`), 836760
(the Siri-enablement bug), 833651, 838329 / **FB23813341** (the hand-off recipe and the deflection),
837249, 829586, 832534, 835903, 838904. **Apple open source:** `apple/coreai-models` (`CoreAISpeech`,
line-cited) and `apple/dnikit` at `2f39056` — ~60 source files, 8 test files, 20 `.rst` pages, all seven
notebooks — which for DNIKit is the entire evidence base, because nothing else exists. **Community
measurement**, always labelled as such and never as an Apple figure: the macOS 27 beta metadata-gap and
guidance-token findings behind 16.4 §7, and the on-device `.files.file` confirmation behind 16.3 §5.
**No performance number here is presented as Apple-published** — for on-screen entity resolution Apple
publishes no latency budget, no timeout and no benchmark, so 16.3 §4 argues from mechanism instead.

[^identifier-availability]: Apple, [`EntityIdentifier`](https://developer.apple.com/documentation/appintents/entityidentifier)
    and [`FileEntityIdentifier`](https://developer.apple.com/documentation/appintents/fileentityidentifier),
    document the respective public surfaces and availability. Apple’s dedicated
    [`draft(identifier:)`](https://developer.apple.com/documentation/appintents/fileentityidentifier/draft%28identifier%3A%29)
    page specifies that a draft identifier represents a document that has not yet been materialized
    on disk and has no file URL.
[^speech-cancel]: Apple,
    [`SpeechAnalyzer.cancelAndFinishNow()`](https://developer.apple.com/documentation/speech/speechanalyzer/cancelandfinishnow%28%29),
    declares the method `async`, nonthrowing, and able to finish analysis before any input is
    consumed.
