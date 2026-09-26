# Silent-failure index — Shipping and operating on-device AI in a released app

**50 ⚠️ callouts from the guide parts this skill covers, sorted by the symptom you would observe.** Most defects in this stack do not throw, so the symptom is what you start from.

> Sliced from the series index on 2026-09-22. The full index across all 17 parts is at https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/SILENT-FAILURES.md. Generated — regenerate with `./scripts/build-skills.sh` rather than editing by hand.

| Symptom | Entries |
|---|---:|
| [Data & artifact loss](#data--artifact-loss) | 5 |
| [Compiles but unavailable](#compiles-but-unavailable) | 9 |
| [Performance cliffs](#performance-cliffs) | 3 |
| [Resource growth](#resource-growth) | 13 |
| [Misleading signals](#misleading-signals) | 7 |
| [Version drift](#version-drift) | 1 |
| [Docs vs reality](#docs-vs-reality) | 4 |
| [API footguns](#api-footguns) | 3 |
| [General cautions](#general-cautions) | 5 |

## Data & artifact loss

**Part 15**

- [TOC: bookmarks quietly die — init?(resolvingBookmark:) returns nil, not an error, once the entry is purged](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#what-this-covers) — 15.1
- [A stored bookmark quietly stops working — purge or invalidation makes resolve return nil, not an error](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#8-️-silent-failure-the-bookmark-that-quietly-stops-working) — 15.1
- [bookmarkData doesn't pin the entry; resolvingBookmark returns nil, not an error — failure lands in an else branch](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#82-the-defect) — 15.1 🔇
- [Code comment marks the silent branch: a well-formed bookmark whose entry is gone resolves to nil](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#84-the-fix-persist-a-record-never-a-bare-bookmark) — 15.1
- [Every OS update purges all specialized assets regardless of cache policy — they are OS-version specific](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#112-cache-policies-what-the-system-may-take-back) — 15.1

## Compiles but unavailable

**Part 15**

- [compile exits 0 for any arch; codes track device ids, not names — green CI, invalidCompiledModel in users' hands](part-15-shipping-and-operating/README.md#151--shipping-models-background-assets-per-architecture-variants-and-updates) — 15.README 🔇
- [AOT compilation has a far narrower hardware floor than the framework — AOT assets exclude devices the framework supports](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#shipping-models-background-assets-per-architecture-variants-and-updates) — 15.1
- [TOC: coreai-build compile succeeds for architectures the device will reject — only a device load validates](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#what-this-covers) — 15.1
- [A green compile the device rejects — exit 0 proves nothing; the failure is invalidCompiledModel in the field](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#5-️-silent-failure-a-green-compile-that-the-device-rejects) — 15.1
- [xcrun coreai-build compile exits 0 for architectures the device will reject — only a device load validates](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#51-the-defect) — 15.1 🔇
- [A bad app-group entitlement silently drops to the per-bundle cache — specialization cost and storage double](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#103-️-the-initializer-returns-nil-and-apples-own-sample-calls-fatalerror) — 15.1
- [Guided generation (@Generable) is not supported on GPU-pipelined engines](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#123-the-four-realistic-strategies) — 15.1
- [Grammar-constrained decoding needs logits; GPU-pipelined bundles never expose them — fastest backend loses @Generable](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#123-the-four-realistic-strategies) — 15.1
- [iPad RAM follows storage tier — 1–2 TB iPad Pros have more RAM; same-name smaller models jetsam your tested config](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md#per-device-budgets-and-the-storage-tier-surprise) — 15.2

## Performance cliffs

**Part 15**

- [expectFrequentReshapes=true on a fixed-shape graph abandons the AOT specialization — device-validated, can SIGSEGV](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#54-a-second-way-a-compiled-asset-fails-to-load-with-the-same-shape) — 15.1
- [Code comment: set expectFrequentReshapes explicitly false on static graphs — asking was measured to kill AOT and SIGSEGV](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#94-the-fix-is-structural) — 15.1
- [Your build machine is a benchmark variable — the same export can be 2.2× slower and 2× heavier with zero diagnostics](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md#95-the-artifact-is-not-a-function-of-the-recipe) — 15.2 🔇

## Resource growth

**Part 15**

- [A successful load is not a fit test — first inference adds activations and KV, and compute unit moves headroom 2×](part-15-shipping-and-operating/README.md#152--memory-jetsam-thermals-energy-and-measuring-honestly) — 15.README 🔇
- [TOC: two slightly different options structs silently create two multi-gigabyte specializations](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#what-this-covers) — 15.1
- [Prewarming a graph with static-shape host KV I/O allocates the whole cache up front — a net loss; gate your prewarm](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#62-the-three-levers) — 15.1
- [SpecializationOptions is part of the cache key — two variants mean two multi-gigabyte specializations](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#9-️-silent-failure-two-options-structs-two-multi-gigabyte-specializations) — 15.1
- [Slightly different SpecializationOptions from two code paths silently double the multi-GB cache and re-stall first load](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#91-the-defect) — 15.1 🔇
- [Extension memory limits count Core AI models — a model fine in the app can jetsam its extension](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#105-extensions-have-memory-limits-and-core-ai-models-count-against-them) — 15.1
- [.persistent turns off source-deletion reclamation — deleted sources strand multi-GB orphans until the next OS update](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#113-which-policy-to-use) — 15.1
- [TOC: load OK, run dead — a model that loads can still die on its first inference step](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md#contents) — 15.2
- [Loading establishes weights only; the first step adds activations, workspace, maybe a full-context KV cache](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md#11-what-jetsam-looks-like) — 15.2 🔇
- [mmap'd weights look free until touched — residency grows to full size on unified memory; headroom checks lie](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md#22-mmap-vs-dirty) — 15.2 🔇
- [Measured ceiling: an 18 GB int4 35B gets signal 9 on a 12 GB iPhone 17 Pro — ~5–6 GB is the phone-class limit](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md#31-signal-9) — 15.2
- [The same 1.8 GB core leaves ~2.8 GB headroom via ANE but ~6.0 GB via GPU — no API reports the difference](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md#32-load-ok-run-dead) — 15.2 🔇
- [Forum 824753 (community, status unknown): ~40 GiB of 'other' allocations — watch for runaway growth](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md#61-the-forum-report-40-gib-of-other-allocations) — 15.2

## Misleading signals

**Part 15**

- [Specialization reports no progress — minutes of silence that read as a hang](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#64-️-specialization-reports-no-progress) — 15.1
- [The specialization gauge appears only when you directly link CoreAI.framework — transitive linkage shows nothing](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#64-️-specialization-reports-no-progress) — 15.1
- [Code comment: the storage figure counts source assets only — specialized copies in the cache are invisible to it](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#116-reporting-storage-to-the-user) — 15.1
- [iOS 27 betas report appleIntelligenceNotEnabled unless Siri is on — Apple-confirmed bug; don't require Siri in UX](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#122-why-compatible-hardware-was-never-the-right-gate-anyway) — 15.1
- [Memory-pressure trim freed an in-flight MTLBuffer (mlx#3689) — surfaces as a GPU InvalidResource error, hiding the cause](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md#62-what-to-do-about-it) — 15.2 🔇
- [Foundation Models exposes no tokenizer — every published tok/s figure for Apple's model is an estimate](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md#98-️-foundation-models-has-no-tokenizer-so-every-toks-figure-for-it-is-an-estimate) — 15.2
- [Third-party tok/s for Apple's model carries ~±20% error — no tokenizer to count with, and nothing marks the estimates](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md#98-️-foundation-models-has-no-tokenizer-so-every-toks-figure-for-it-is-an-estimate) — 15.2 🔇

## Version drift

**Part 15**

- [The GPU cache-limit API has two spellings across versions — check which one your installed version has](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md#51-️-two-spellings-and-you-must-check-which-one-your-version-has) — 15.2

## Docs vs reality

**Part 15**

- [The individual symbol pages disagree with the framework page — Apple docs conflict on this behavior](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#shipping-models-background-assets-per-architecture-variants-and-updates) — 15.1
- [Apple's docs contradict each other on deleting a cache entry a live AIModel still references](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#74-️-deleting-an-entry-that-is-still-in-use-the-docs-contradict-each-other) — 15.1
- [Reference pages say deleting an in-use entry throws; Apple's other doc says deferred — code for both outcomes](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#74-️-deleting-an-entry-that-is-still-in-use-the-docs-contradict-each-other) — 15.1
- [Bookmark cleanup hits the same doc contradiction as §7.4 — in-use deletion is documented both ways](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#86-cleaning-up-a-bookmark-you-are-done-with) — 15.1

## API footguns

**Part 15**

- [Architecture codes track device identifiers, not marketing names — 'iPhone 17 Pro' reads h17p but is h18p](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#44-️-architecture-codes-track-the-device-identifier-not-the-marketing-name) — 15.1
- [Code comment: match path components exactly — contains('ane') also matches 'gated-deltanet'](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#94-the-fix-is-structural) — 15.1
- [The app-group cache init returns nil and Apple's sample answers with fatalError — copy it and config errors crash](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#103-️-the-initializer-returns-nil-and-apples-own-sample-calls-fatalerror) — 15.1

## General cautions

**Part 15**

- [Read-first note: claims here mix Apple docs with community measurement — check the attribution before acting](part-15-shipping-and-operating/README.md#️-read-this-before-anything-else-in-this-part) — 15.README
- [Do not copy the quoted Background Assets keys into a 27 project — one developer's 26-era config for a removed feature](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#33-the-background-assets-fragments-we-can-verify) — 15.1
- [Status note: thread 836810 is answered by Apple staff — what's missing is the capability, not the answer](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md#121-there-is-no-required-device-capability-for-apple-intelligence) — 15.1
- [There is no NPU priority entitlement or API — Apple staff confirmed on thread 833666](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md#what-you-cannot-control) — 15.2
- [Read the attribution first: community-measured on beta OSes — protocol, not gospel](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md#81-the-table-where-the-winner-loses) — 15.2

---

🔇 = the guide marks this as an explicit **SILENT FAILURE** callout.
