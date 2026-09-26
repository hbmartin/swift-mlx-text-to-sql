# Silent-failure index — App Intents, Siri schema domains, and Spotlight entity indexing

**96 ⚠️ callouts from the guide parts this skill covers, sorted by the symptom you would observe.** Most defects in this stack do not throw, so the symptom is what you start from.

> Sliced from the series index on 2026-09-22. The full index across all 17 parts is at https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/SILENT-FAILURES.md. Generated — regenerate with `./scripts/build-skills.sh` rather than editing by hand.

| Symptom | Entries |
|---|---:|
| [Wrong output](#wrong-output) | 6 |
| [Empty output / no-op](#empty-output--no-op) | 11 |
| [Ignored input](#ignored-input) | 1 |
| [Stale state](#stale-state) | 4 |
| [Compiles but unavailable](#compiles-but-unavailable) | 3 |
| [Performance cliffs](#performance-cliffs) | 5 |
| [Misleading signals](#misleading-signals) | 3 |
| [Version drift](#version-drift) | 1 |
| [Docs vs reality](#docs-vs-reality) | 18 |
| [API footguns](#api-footguns) | 23 |
| [General cautions](#general-cautions) | 21 |

## Wrong output

**Part 16**

- [Some Spotlight metadata is searchable but unreadable — SpotlightSearchTool sees titles and invents the bodies](part-16-adjacent-capabilities/README.md#164--one-index-three-consumers-entities-spotlight-and-foundation-models) — 16.README 🔇
- [Skip the units instruction and the model answers 'distance: 4.2' in the wrong unit, confidently — quiet wrongness](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#35-custom-attributes-the-round-trip-that-reaches-the-model) — 16.4
- [The index is searchable but not readable — compact metadata matches queries but the model can't recover it](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#73-️-silent-failure--the-index-is-searchable-but-not-readable) — 16.4
- [Session 246 verbatim: some Spotlight metadata is searchable but not recoverable — the model answers without it](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#73-️-silent-failure--the-index-is-searchable-but-not-readable) — 16.4 🔇
- [.dynamic(GuidanceProfile) measured prompt-sensitive on 27.0 beta — the model may skip the search and answer from memory](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#75-guidanceprofile--scoping-the-tool-to-what-your-index-actually-contains) — 16.4 🔇
- [The model reads titles and invents bodies — unreadable metadata becomes hallucinated content](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#131-️-silent--the-model-reads-titles-and-invents-bodies) — 16.4

## Empty output / no-op

**Part 16**

- [Entity plumbing the screenshot path never consults costs weeks and changes nothing; per-row ids also lose rows](part-16-adjacent-capabilities/README.md#163--on-screen-awareness-making-siri-understand-this) — 16.README 🔇
- [Conformance is not donation — entities never explicitly indexed never appear, however correct the types](part-16-adjacent-capabilities/references/02-app-schema-domains.md#15-testing-the-four-stage-ladder) — 16.2
- [Conflict with the doc shape: thread 838329 reports the NSUserActivity route produced no callbacks at all](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#32-shape-a-one-primary-item--nsuseractivity) — 16.3
- [Entity plumbing for the screenshot request class is never consulted — weeks of work, zero callbacks (thread 837249)](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#83-️-silent-failure--building-entity-plumbing-for-the-screenshot-path) — 16.3
- [A non-schema entity never resolves for hand-off — the pipeline quietly yields nothing](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#84-️-silent-failure--a-non-schema-entity-never-resolves-for-hand-off) — 16.3
- [Reported, unconfirmed: the NSUserActivity route producing no awareness callbacks at all](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#86-️-silent-failure-reported-unconfirmed--the-nsuseractivity-route-producing-no-callbacks) — 16.3
- ['Describe this scan' is answered from a screenshot, not ScanEntity — your entity layer never participates](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#97-what-this-integration-does-and-does-not-buy) — 16.3
- [A property without indexingKey: is simply not in the index — searches and the model see nothing for it](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#43-binding-your-properties-to-spotlight-keys) — 16.4
- [Wire the delegate correctly and on tested 27.0 betas nothing ever invoked it — no throw, no log; hallucination continues](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#94-️-the-conflict--and-it-is-a-real-one) — 16.4
- [An unmapped entity property is simply absent — no error; the field never exists downstream](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#133-️-silent--an-unmapped-entity-property-is-simply-absent) — 16.4
- [The hydration delegate is never called (field-reported) — bodies stay unrecoverable and nothing logs](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#134-️-silent--the-hydration-delegate-is-never-called) — 16.4

## Ignored input

**Part 16**

- [Excessive interaction donations are silently ignored — over-donate and the surplus just disappears](part-16-adjacent-capabilities/references/02-app-schema-domains.md#142-️-excessive-interaction-donations-are-silently-ignored) — 16.2

## Stale state

**Part 16**

- [Entities stay registered until you remove them — no TTL; a missed removal leaves stale suggestions indefinitely](part-16-adjacent-capabilities/references/02-app-schema-domains.md#132-the-three-discovery-mechanisms--and-where-relevantentities-fits) — 16.2
- [SnippetIntent may re-run; cached state renders stale UI — the tapped toggle doesn't move and nothing errors](part-16-adjacent-capabilities/references/02-app-schema-domains.md#147-️-snippetintent-state-caching) — 16.2
- [There is no TTL — registered relevance donations persist until you explicitly remove them](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#123-️-silent-failure--there-is-no-ttl) — 16.4
- [Stale index entries survive deleted content — Spotlight keeps serving what your app already removed](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#132-️-silent--stale-index-entries-survive-deleted-content) — 16.4

## Compiles but unavailable

**Part 16**

- [The .assistant domain's single intent is Japan-only — a region gate on the whole domain](part-16-adjacent-capabilities/references/02-app-schema-domains.md#assistant--1-intent--️-japan-only) — 16.2
- [@available says 26.4 but the cluster is absent from the 26.5 interface — treat the 27.0 SDK as the real floor](part-16-adjacent-capabilities/references/02-app-schema-domains.md#-valuerepresentation-versus-intentvaluerepresentation--resolved-they-are-one-type) — 16.2
- [watchOS is absent from the tool's availability annotation — compiler-attested; plan no watch adoption](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#71-what-apple-actually-announced) — 16.4

## Performance cliffs

**Part 16**

- [A [Entity] parameter fully resolves every element before perform() — hidden N-query stall; EntityCollection passes ids](part-16-adjacent-capabilities/references/02-app-schema-domains.md#133-️-entitycollection--the-parameter-resolution-performance-cliff) — 16.2
- [TOC: the performance trap that turns on-screen awareness into a stall](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#what-this-covers) — 16.3
- [Code comment: the naive displayRepresentations is correct but slow enough to break awareness](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#42-️-silent-failure--the-naive-implementation-turns-awareness-into-a-stall) — 16.3
- [The naive implementation compiles and is correct — and stalls long enough to break the feature](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#42-️-silent-failure--the-naive-implementation-turns-awareness-into-a-stall) — 16.3
- [A naive displayRepresentations turns awareness into a stall — it is called for every entity](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#81-️-silent-failure--a-naive-displayrepresentations-turns-awareness-into-a-stall) — 16.3

## Misleading signals

**Part 16**

- [Unmapped errors leak raw domain strings to users through Siri — map them via AppIntentError and friends](part-16-adjacent-capabilities/references/02-app-schema-domains.md#148-️-raw-internal-errors-reaching-end-users) — 16.2
- [Raw internal error domains reach users through Siri — unmapped errors are surfaced verbatim](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#88-️-silent-failure--raw-internal-errors-reaching-the-user-through-siri) — 16.3
- [SystemLanguageModel .available isn't sufficient — model-catalog failure can break the tool before your code runs](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#138-model-catalog-failure-before-anything-you-wrote-runs) — 16.4

## Version drift

**Part 16**

- [Deprecated schemas stay in the enumeration and keep working — deprecation means migrate, not removed](part-16-adjacent-capabilities/references/02-app-schema-domains.md#what-to-do-if-you-have-adopted-a-deprecated-schema) — 16.2

## Docs vs reality

**Part 16**

- [Session 345 says 'our 2027 releases' while sibling sessions say otherwise — Apple's own year labels conflict](part-16-adjacent-capabilities/references/02-app-schema-domains.md#app-schema-domains-the-complete-map-of-what-siri-can-actually-do) — 16.2
- [Section flag: places where Apple's docs contradict the observed behavior](part-16-adjacent-capabilities/references/02-app-schema-domains.md#️-where-the-docs-contradict-the-observed-behaviour) — 16.2
- [The journaling domain's page name and its symbols don't match — know it before URL-hunting](part-16-adjacent-capabilities/references/02-app-schema-domains.md#3-the-macro-system-and-the-build-errors-it-generates) — 16.2
- [The symbol is AppSchema.JournalIntent (singular) but the domain page says journaling — the mismatch again](part-16-adjacent-capabilities/references/02-app-schema-domains.md#journal--5-intents--1-entity--0-enums) — 16.2
- [Session 240's published sample conflicts with the SDK on this mapping — the interface wins](part-16-adjacent-capabilities/references/02-app-schema-domains.md#105-intentvaluequery--structured-search-and-the-only-multi-type-query) — 16.2
- [SnippetIntent shipped in iOS 26 — material presenting it as new this year mislabels the floor](part-16-adjacent-capabilities/references/02-app-schema-domains.md#114-️-snippetintent-is-an-ios-26-feature--not-new-this-year) — 16.2
- [The macOS interface spells only .audio(.nowPlaying) — the session's .workout situation is absent there](part-16-adjacent-capabilities/references/02-app-schema-domains.md#132-the-three-discovery-mechanisms--and-where-relevantentities-fits) — 16.2
- [Session 345's 'our 2027 releases' conflicts with other sessions' labels — a version-label trap in Apple's material](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#on-screen-awareness-making-siri-understand-this) — 16.3
- [Session 240's own sample uses per-row annotation — the exact pattern that loses selected and scrolled-off entities](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#34-shape-c-lists-and-collections--appentityidentifierforselectiontype_) — 16.3
- [Sessions 345 and 240 use two names for seemingly one representation type — no page reconciles them (G9)](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#52-the-documented-route--transferable-and-intentvaluerepresentation) — 16.3
- [Place content routes via ValueRepresentation/IntentValueRepresentation — concept verified, naming hazard G9 open](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#58-what-to-do-today) — 16.3
- [The .files domain page never mentions FileEntityIdentifier/FileRepresentation — the recipe came from a forum, not docs](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#class-3--apple-documentation) — 16.3
- [The 'making onscreen content available' article 404s — cited by name in thread 838329 but gone](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#class-3--apple-documentation) — 16.3
- [Every circulating reconstruction of the hydration method has the wrong signature — only the interface shape is real](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#92-️-the-exact-signature--and-it-is-not-what-you-would-write) — 16.4
- [Session 246 calls searchableItems(forIdentifiers:) new; it's macOS 15.4+ — only the protectionClass overload is new](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#94-️-the-conflict--and-it-is-a-real-one) — 16.4
- [G8: the .workout situation is absent from the macOS interface — only .audio(.nowPlaying) is spelled there](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#122-the-api) — 16.4
- [Matrix: searchableItems(forIdentifiers:) is macOS 15.4+, conflicting with session 246's 'new'; Obj-C hides it from dumps](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#153-the-version-matrix) — 16.4
- [Session 345 says 'our 2027 releases' three times; 240 and 343 label differently — normalize year labels before citing](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#153-the-version-matrix) — 16.4

## API footguns

**Part 16**

- [In update intents nil means both 'clear' and 'untouched' — if-let code silently drops every 'remove the due date'](part-16-adjacent-capabilities/README.md#162--app-schema-domains-the-complete-map-of-what-siri-can-actually-do) — 16.README 🔇
- [Schemas ship in conversational sets — adopting one intent triggers build errors demanding the rest of its set](part-16-adjacent-capabilities/references/02-app-schema-domains.md#33-️-schemas-come-in-conversational-sets--a-build-error-you-will-not-expect) — 16.2
- [All four reminders update intents hit the valueState nil-conflation bug — 'remove the due date' silently no-ops](part-16-adjacent-capabilities/references/02-app-schema-domains.md#reminders--8-intents--5-entities--2-enums) — 16.2
- [IntentValueQuery input isn't always scalar — session 240's case is a collection; scalar-assuming code misses it](part-16-adjacent-capabilities/references/02-app-schema-domains.md#105-intentvaluequery--structured-search-and-the-only-multi-type-query) — 16.2
- [TransientAppEntity is not a local choice — it forecloses every integration listed in §14.4](part-16-adjacent-capabilities/references/02-app-schema-domains.md#106-transientappentity--when-a-thing-has-no-independent-identity) — 16.2
- [LongRunningIntent requires progress as its liveness signal — never touch progress and assume the intent is killed](part-16-adjacent-capabilities/references/02-app-schema-domains.md#137-longrunningintent--past-the-30-second-wall) — 16.2
- [valueState exists because nil conflates 'clear it' with 'don't touch it' — the obvious code silently drops clears](part-16-adjacent-capabilities/references/02-app-schema-domains.md#141-️-silent-failure--intentparametervaluestate-clear-it-and-dont-touch-it-are-not-the-same-thing) — 16.2
- [Per-row .appEntityIdentifier loses selected and scrolled-off entities — the pattern Apple's sample shows uncaveated](part-16-adjacent-capabilities/references/02-app-schema-domains.md#143-️-per-row-appentityidentifier-loses-selected-and-scrolled-off-entities) — 16.2
- [TransientAppEntity silently forecloses three system integrations — a type choice that disables features elsewhere](part-16-adjacent-capabilities/references/02-app-schema-domains.md#144-️-transientappentity-silently-forecloses-three-system-integrations) — 16.2
- [SyncableEntity with a per-device id compiles cleanly, nothing validates it — Siri still loses entities across devices](part-16-adjacent-capabilities/references/02-app-schema-domains.md#145-️-syncableentity-is-a-promise-nothing-validates) — 16.2
- [LongRunningIntent without progress writes gives no liveness evidence — consequence undocumented; assume killed](part-16-adjacent-capabilities/references/02-app-schema-domains.md#146-️-longrunningintent-without-progress-reporting) — 16.2
- [Annotate a UUID id with uuidString and entities(for:) gets unmatchable Strings — empty array, Siri quietly moves on](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#21-the-initializer) — 16.3
- [The Now Playing identifier array's order is semantic, not stylistic](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#62-now-playing--and-the-ordering-rule) — 16.3
- [Per-row annotation loses selected and scrolled-off entities — annotate the container with forSelectionType](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#82-️-silent-failure--per-row-annotation-loses-selected-and-scrolled-off-entities) — 16.3
- [TransientAppEntity forecloses three system integrations — silently, via the type choice](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#85-️-silent-failure--transientappentity-forecloses-three-system-integrations) — 16.3
- [Now Playing identifiers in the wrong order resolve the wrong entity — the order is semantic](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#87-️-silent-failure--now-playing-identifiers-in-the-wrong-order) — 16.3
- [TOC: the hydration hook is a nonisolated completion-handler method — not the async throwing shape you'd write](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#what-this-covers) — 16.4
- [Index into a named CSSearchableIndex while other code uses the default and the corpus silently splits](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#32-why-a-named-index) — 16.4
- [beginBatch/endBatch is not a transaction — partial writes persist; clientState is for resume, not rollback](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#34-batching-and-the-client-state-pattern) — 16.4
- [CSCustomAttributeKey's init is failable — a nil key means the attribute silently never reaches the index](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#43-binding-your-properties-to-spotlight-keys) — 16.4
- [TransientAppEntity cannot be used as an annotation — the constraint that catches people here](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#52-the-three-things-only-on-ramp-b-gives-you) — 16.4
- [The hydration method is a nonisolated non-throwing completion handler — the natural async form never binds](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#92-️-the-exact-signature--and-it-is-not-what-you-would-write) — 16.4
- [Same object, same uniqueIdentifier on both on-ramps — mismatched ids duplicate entries and break linkage](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#103-the-safe-default) — 16.4

## General cautions

**Part 16**

- [Read-first: two planning-level facts gate everything in this part — learn them before scoping work](part-16-adjacent-capabilities/README.md#️-two-things-to-learn-before-you-plan-anything) — 16.README
- [Symbol-name trust note: verified against the SDK interface — re-check before reusing elsewhere](part-16-adjacent-capabilities/references/02-app-schema-domains.md#️-read-this-before-you-trust-a-symbol-name-below) — 16.2
- [Scope note: the third schema tier matters more than its billing suggests](part-16-adjacent-capabilities/references/02-app-schema-domains.md#️-why-the-third-tier-matters-more-than-it-looks) — 16.2
- [Payoff 2 of interaction donations is a hard-scoped limit, not a general capability](part-16-adjacent-capabilities/references/02-app-schema-domains.md#121-interaction-donations--teaching-siri-what-happens-in-your-ui) — 16.2
- [Session 345 explicitly does not cover UndoableIntent, IntentModes or SnippetIntent — don't cite it for them](part-16-adjacent-capabilities/references/02-app-schema-domains.md#13-the-new-execution-model) — 16.2
- [Session 344 published no code block — every listing attributed to it is transcript reconstruction](part-16-adjacent-capabilities/references/02-app-schema-domains.md#primary--wwdc26-sessions) — 16.2
- [Symbol-name trust note for this guide — verify before porting names](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#️-read-this-before-you-trust-a-symbol-name-below) — 16.3
- [Marker definition: these silent failures neither throw nor log, and symptoms appear far from the defect — eight here](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#️-read-this-before-you-trust-a-symbol-name-below) — 16.3 🔇
- [Draft identity exists, but a verified hand-off still needs a real file payload — materialize first](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#55-️-draft-identity-exists-the-verified-hand-off-still-needs-a-real-file-payload) — 16.3
- [Whether .appEntityIdentifier takes an optional is unverified — but the compiler tells you; explicitly not silent](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#55-️-draft-identity-exists-the-verified-hand-off-still-needs-a-real-file-payload) — 16.3 🔇
- [In-memory content must be written to a file before the FileRepresentation hand-off — the step stays necessary](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#58-what-to-do-today) — 16.3
- [The coffee/game and SpeechAnalyzer samples are stale WWDC25 leftovers — never cited as 2026 evidence](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#class-1--apple-sample-code-projects) — 16.3
- [Session 344 has no published code — listings from it are reconstructions from narration](part-16-adjacent-capabilities/references/03-onscreen-awareness.md#class-5--wwdc26-session-transcripts) — 16.3
- [Symbol-name trust note for this guide](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#️-read-this-before-you-trust-a-symbol-name-below) — 16.4
- [Evidence-class warning: this on-ramp's claims rest on thinner evidence — read the section accordingly](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#4-on-ramp-b-indexedentity-and-indexappentities_) — 16.4
- [Don't adopt AppEntity solely for indexing — it drags in a Siri-facing surface you must then maintain](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#54-choosing) — 16.4
- [Indexing is not annotation — descriptive on-screen content alone builds the wrong layer; the line drawn once](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#64-indexing-is-not-annotation--the-line-drawn-once) — 16.4
- [IntentValueQuery serves Siri only — path-2 content is invisible to SpotlightSearchTool; no configuration reaches it](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#113-path-2--intentvaluequery-structured-search) — 16.4
- [Consumer surface note: the demo's consumer was the Fitness app's suggested-playlists list](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#122-the-api) — 16.4
- [Donate only UI-originated interactions, never Siri-originated — the rule against feeding the ranking loop back](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#124-apples-three-way-decision-rule) — 16.4
- [Get plain indexing working and verified before building consumers — everything downstream depends on it](part-16-adjacent-capabilities/references/04-entities-spotlight-and-foundation-models.md#142-the-sequence) — 16.4

---

🔇 = the guide marks this as an explicit **SILENT FAILURE** callout.
