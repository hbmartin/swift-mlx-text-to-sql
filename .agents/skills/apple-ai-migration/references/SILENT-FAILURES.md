# Silent-failure index — Migrating an Apple AI integration from 26 to 27

**173 ⚠️ callouts from the guide parts this skill covers, sorted by the symptom you would observe.** Most defects in this stack do not throw, so the symptom is what you start from.

> Sliced from the series index on 2026-09-22. The full index across all 17 parts is at https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/SILENT-FAILURES.md. Generated — regenerate with `./scripts/build-skills.sh` rather than editing by hand.

| Symptom | Entries |
|---|---:|
| [Wrong output](#wrong-output) | 8 |
| [Empty output / no-op](#empty-output--no-op) | 4 |
| [Ignored input](#ignored-input) | 10 |
| [Stale state](#stale-state) | 2 |
| [Data & artifact loss](#data--artifact-loss) | 8 |
| [Compiles but unavailable](#compiles-but-unavailable) | 15 |
| [Performance cliffs](#performance-cliffs) | 6 |
| [Resource growth](#resource-growth) | 4 |
| [Precision loss](#precision-loss) | 1 |
| [Misleading signals](#misleading-signals) | 23 |
| [Version drift](#version-drift) | 25 |
| [Docs vs reality](#docs-vs-reality) | 12 |
| [API footguns](#api-footguns) | 19 |
| [General cautions](#general-cautions) | 36 |

## Wrong output

**Part 17**

- [A refused string generation returns success whose content is an apology; apps ship the apology as data](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#63-behavioural--refusal-traffic-moved-between-two-mechanisms) — 17.1 🔇
- [In string mode a refusal is a successful response; the apology string flows into your pipeline as real content](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md#91-the-two-layers-from-apples-own-description) — 17.3 🔇
- [A throwing subject(from:) lets refusals abort samples; aggregate eval scores silently exclude the refused cases](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md#162-the-critical-design-decision) — 17.3 🔇
- [coreai-models has zero EXIF or orientation handling; rotated camera photos silently produce wrong vision results](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#29-image-inputs-and-the-pre-processing-you-used-to-get-for-free) — 17.5
- [optimize() is mandatory in the conversion path yet can miscompile, producing a graph that computes something else](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#34-️-silent-failure-the-converters-optimize-can-miscompile-and-optimize-is-mandatory) — 17.5
- [coreai-torch #49: optimize() removes broadcasting-significant transposes and silently miscompiles NxN distance graphs](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#34-️-silent-failure-the-converters-optimize-can-miscompile-and-optimize-is-mandatory) — 17.5
- [Orientation and coordinate conventions are now your job; getting them wrong yields plausible but wrong vision output](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#35-️-silent-failure-orientation-and-coordinate-conventions-which-used-to-be-someone-elses-job) — 17.5
- [CIImage(contentsOf:) applies EXIF orientation, CGImageSource does not; the same JPEG preprocesses two different ways](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#35-️-silent-failure-orientation-and-coordinate-conventions-which-used-to-be-someone-elses-job) — 17.5

## Empty output / no-op

**Part 17**

- [A response stream can finish with zero text partials when the model emits only a tool call; unguarded UIs show nothing](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#64-behavioural--apples-samples-dropped-proactive-availability-gating) — 17.1 🔇
- [A stream can finish having yielded zero text partials when the model emits only a tool call](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md#610-what-apples-2026-samples-actually-do-which-is-not-what-the-2025-ones-did) — 17.2
- [contiguousElements returns nil once specialization prefers a non-contiguous layout; data you expected is not there](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#23-mlmultiarray--ndarray--and-the-view-discipline) — 17.5
- [Xcode's Source Viewer stays empty unless debug metadata was embedded in the .aimodel at export time](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#43-the-core-ai-debugger-sync-points-and-psnr-against-a-pytorch-reference) — 17.5

## Ignored input

**Part 17**

- [Omit .label() on an image Attachment and tools never see the image; the model improvises with no diagnostic](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#41-additive--image-input-on-the-on-device-model) — 17.1 🔇
- [permissiveContentTransformations only applies to string output; guided generation still runs the default guardrails](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#62-behavioural--guardrails-changed-twice) — 17.1 🔇
- [.anyOf produces no error and no warning and does not constrain; tools receive arguments outside their domain](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#66-behavioural--anyof-still-does-not-constrain) — 17.1 🔇
- [The Python SDK stringifies top_k/top_p/seed so Swift ignores them; seeded evaluation runs are not reproducible](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#92-four-python-sdk-defects-that-will-waste-your-afternoon) — 17.1
- [ba-package package exits 0, the .aar downloads and reports available, and the FM runtime never uses it](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md#35-the-packaging-command-and-the-manifest-defect) — 17.2 🔇
- [The @Guide(.anyOf:) guide does not do what it says: the constraint is accepted and silently ignored](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md#64-️-the-one-guide-that-does-not-do-what-it-says) — 17.2
- [Apple reproduced it: @Guide with .anyOf compiles and runs but generation ignores the allowed-value list](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md#64-️-the-one-guide-that-does-not-do-what-it-says) — 17.2 🔇
- [Set permissiveContentTransformations then call respond(generating:) and the setting is inert; guardrails run as usual](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md#103-the-contradiction-presented-with-both-sides) — 17.3 🔇
- [Palettization silently skips layers incompatible with the configured granularity; the model ships partly uncompressed](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#32-️-silent-failure-numeric-drift-with-no-exception) — 17.5
- [Running python from the coreai-torch clone shadows installed 0.4.1 with the 0.4.0 egg-info; exports silently regress](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#34-the-negative-list-four-things-that-do-not-fix-it) — 17.6 🔇

## Stale state

**Part 17**

- [With .preserveTranscript a failed turn leaves a partial entry; later turns treat truncated output as context and degrade](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md#22-transcripterrorhandlingpolicy--the-new-knob-you-did-not-have) — 17.3 🔇
- [Uploading a fixed model reaches no users until the revision pin advances; the catalog keeps serving the old artifact](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#path-a--re-convert-from-source-apples-original-guidance) — 17.6

## Data & artifact loss

**Part 17**

- [summarizeHistory destroys tool-call metadata; swapping it in for hand-rolled compaction loses tool context](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#77-superseded--hand-rolled-context-management) — 17.1
- [finalize(backend: CoreAI) frees the original dense weights in place; without a checkpoint the source model is gone](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#64-what-does-carry-over-the-optimization-stage) — 17.5
- [Audit before you repack: coreai-build package destroys the producer metadata that identifies bad exports](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#34-the-negative-list-four-things-that-do-not-fix-it) — 17.6
- [AIModel(resolvingBookmark:) returns nil, not an error, once an OS update purges the cached entry](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#️-the-silent-failure) — 17.6
- [Stale bookmarks return nil while malformed ones throw; the nil path fires for every user after every OS update](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#️-the-silent-failure) — 17.6 🔇
- [The nil-return branch is the path every user takes after every OS update; handle it by re-specializing](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#what-fix-it-means) — 17.6
- [Bookmarks-specific trap: bookmark data does not pin the cache entry it references](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#️-and-the-one-bookmarks-specific-trap) — 17.6
- [Bookmark data pins nothing; only a live AIModel pins its cache entry, so storage pressure can purge under a bookmark](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#️-and-the-one-bookmarks-specific-trap) — 17.6

## Compiles but unavailable

**Part 17**

- [Bring-your-own models lose @Generable on GPU-pipelined Core AI bundles; the fastest backend never exposes logits](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#43-additive--the-languagemodel--languagemodelexecutor-protocol-pair) — 17.1
- [BarcodeReaderTool lists watchOS but OCRTool does not; a watchOS target reaching for OCR finds nothing](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#46-additive--system-tools-and-the-one-that-isnt-where-youd-look) — 17.1
- [Copying 2026 samples' reactive-only gating means users discover Apple Intelligence is unavailable only after tapping](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#64-behavioural--apples-samples-dropped-proactive-availability-gating) — 17.1 🔇
- [No App Store required-device-capability exists for Apple Intelligence; incapable devices can always install your app](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#65-behavioural--the-siri-enablement-gate-is-a-defect-not-a-design) — 17.1
- [On GPU-pipelined bundles you lose @Generable entirely; constrained decoding needs logits they never expose](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md#what-this-covers) — 17.2
- [@Generable needs logits the GPU-pipelined Core AI engine never returns; the fastest backend cannot do guided generation](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md#72-️-the-constraint-that-decides-this-for-many-readers-generable-and-logits) — 17.2
- [The GPU-pipelined engine samples on-GPU and returns no logits; @Generable fails at runtime, not at build time](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md#72-️-the-constraint-that-decides-this-for-many-readers-generable-and-logits) — 17.2 🔇
- [Path table: @Generable works on FM and via MLXGuidedGeneration but not on GPU-pipelined Core AI bundles](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md#122-the-three-paths-at-a-glance) — 17.2
- [An SDK-interface/dylib symbol mismatch crashes at load before main; no runtime guard can intercept it](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md#what-this-covers) — 17.4
- [TOC pointer: the load-time crash from an interface/dylib mismatch that no runtime guard can catch](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md#contents) — 17.4
- [The load-time failure no guard can catch: interface/dylib mismatch SIGSEGVs before main](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md#13-️-the-load-time-failure-no-runtime-guard-can-catch) — 17.4
- [The FM-27 beta interface declared a symbol the dylib lacked; respond() SIGSEGVed emitting usage until mlx fix #439](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md#13-️-the-load-time-failure-no-runtime-guard-can-catch) — 17.4 🔇
- [AOT compiles only for Apple Intelligence hardware (A17 Pro+, M1+); older devices silently specialize on device instead](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#44-ahead-of-time-compilation) — 17.5
- [CoreAI.framework is absent from the iOS Simulator SDK; every file importing CoreAI fails to compile for simulator](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#and-one-that-is-not-about-architectures-at-all) — 17.6
- [The beta .swiftinterface declared API the dylib lacked: code compiled fine and segfaulted at load, before main](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#the-27-only-surface-and-the-trait-that-gates-it) — 17.6

## Performance cliffs

**Part 17**

- [CoreAISegmentationEngine re-runs image_encode on every call; the 76% second-inference saving needs your own cache](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md#76-one-structural-fact-worth-knowing-before-you-convert) — 17.2
- [Refusal.explanation re-runs the model for seconds; awaiting it near the main actor freezes the UI with no crash report](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md#11-reading-a-refusal-explanation-and-explanationstream) — 17.3 🔇
- [An optional sample-loader pattern can request an unintended compute unit; inference silently runs on the wrong backend](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#31-️-silent-failure-the-optional-sample-loader-may-request-an-unintended-compute-unit) — 17.5
- [Apple's own CoreAISegmentationEngine re-runs image_encode per call; the 76% saving requires a cache you must write](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#31-️-silent-failure-the-optional-sample-loader-may-request-an-unintended-compute-unit) — 17.5
- [Specialization replaces .mlmodelc compilation and its cache entry is invalidated on every OS update](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#91-the-translation-table-condensed) — 17.5
- [The stale-host 2.2x slowdown hides on large bandwidth-bound models; only small-model benchmarks reveal it](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#41-the-ab) — 17.6

## Resource growth

**Part 17**

- [Each adapter-related call leaks about 100 MB of orphaned APFS clones that ordinary disk tools never surface](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md#44-️-the-100-mb-per-call-disk-leak) — 17.2
- [Two differing SpecializationOptions create two multi-gigabyte cache entries for one model, silently doubling disk](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#33-️-silent-failure-two-options-structs-two-multi-gigabyte-cache-entries) — 17.5
- [Loading with non-identical options specializes twice: two cache entries, two copies on disk, no warning](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#33-️-silent-failure-two-options-structs-two-multi-gigabyte-cache-entries) — 17.5
- [SpecializationOptions is part of the model cache key; varying it multiplies multi-gigabyte cache entries](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#91-the-translation-table-condensed) — 17.5

## Precision loss

**Part 17**

- [Converted models can drift numerically with no exception; only comparing outputs against the source reveals it](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#32-️-silent-failure-numeric-drift-with-no-exception) — 17.5

## Misleading signals

**Part 17**

- [SpotlightSearchTool's description contradicts its schema, so models fail to invoke it; Code=5000 fires while available](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#46-additive--system-tools-and-the-one-that-isnt-where-youd-look) — 17.1
- [buildURLRequest keys versioning on a literal 'v1' path test; providers not on /v1 get mangled URLs and HTTP errors](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#53-additive--chatcompletionslanguagemodel-turns-your-existing-stack-into-a-backend) — 17.1
- [The undocumented LanguageModelError -1 also occurs on physical devices; it is not a simulator-only artifact](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#69-behavioural--the-simulator-punches-out-to-your-mac) — 17.1
- [Python tool exceptions never raise; they are stringified back to the model, so tool bugs look like model quality issues](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#92-four-python-sdk-defects-that-will-waste-your-afternoon) — 17.1
- [compatibleAdapterNotFound really means the adapter is not downloaded yet; the name sends you auditing compatibility](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md#42-apples-answer-one-missing-call) — 17.2 🔇
- [A download that never starts yields an AsyncSequence with zero elements; 0% progress is indistinguishable from pending](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md#45-the-sibling-failure-a-download-that-never-starts-and-never-complains) — 17.2 🔇
- [A generic catch turns every user cancellation into an error banner; it reads as flakiness, not a ladder bug](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md#62-what-the-ordering-does-do) — 17.3 🔇
- [An unsupported-locale prompt can silently succeed on the simulator; a catch arm never fires.](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md#63-destination-dependent-bridging--one-value-two-checks-the-concern-is-real) — 17.3
- [The same unsupported locale bridges differently by destination: simulator success, physical-device guardrailViolation…](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md#63-destination-dependent-bridging--one-value-two-checks-the-concern-is-real) — 17.3
- [Server 429s arrive as RequestError.httpError, never .rateLimited; backoff keyed on .rateLimited never fires](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md#81-the-concrete-evidence) — 17.3 🔇
- [availability/isAvailable can report healthy while the call still throws (catalog asset and PCC entitlement failures)](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md#132-comappleunifiedassetframework-code5000--the-model-catalog) — 17.3 🔇
- [A green Xcode 26 run proves MLX inference only; the FM adapter is not in that binary, so one check covers half](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md#84-what-ran-where) — 17.4
- [On 27 betas availability returns appleIntelligenceNotEnabled unless a Siri toggle is on; Apple confirmed it is a bug](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md#101-model-availability) — 17.4
- [The Core AI gauge and Instruments swap Load and Specialization colors; do not carry color intuition across tools](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#43-the-core-ai-debugger-sync-points-and-psnr-against-a-pytorch-reference) — 17.5
- [The Core AI Xcode gauge appears only with direct CoreAI.framework linkage; transitive linkage shows no gauge at all](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#43-the-core-ai-debugger-sync-points-and-psnr-against-a-pytorch-reference) — 17.5
- [TOC pointer: coreai-build inspect succeeds on assets the runtime rejects, making them look healthy](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#contents) — 17.6
- [Why the asset break is vicious: inspect still reads the broken asset perfectly and nothing warns](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#33-️-why-it-is-vicious-inspect-still-works) — 17.6
- [inspect prints signatures, weights and dtypes from an asset the runtime aborts on; it looks recoverable and is not](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#33-️-why-it-is-vicious-inspect-still-works) — 17.6 🔇
- [A missing per-arch .aimodelc surfaces as ENOENT 'no such file or directory', sending you to debug file paths](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#7-coreai-build-compile-exits-0-for-architectures-a-device-will-reject) — 17.6
- [coreai-build compile exits 0 for any architecture; only an on-device load reveals a wrong-arch artifact](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#️-the-silent-failure-1) — 17.6
- [A green compile validates nothing about the arch choice; a mis-targeted .aimodelc passes CI and fails on device load](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#️-the-silent-failure-1) — 17.6 🔇
- [Int4 quantization failures are swallowed by a try/except while the bundle manifest still claims quantization succeeded](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#️-the-silent-failure-2) — 17.6
- [compiler.py swallows quantize_weights failures and ships unquantized weights while metadata claims int4 success](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#️-the-silent-failure-2) — 17.6 🔇

## Version drift

**Part 17**

- [Nothing announces itself: a rebuild changes what your catch blocks catch; conversions emit 2.2x-slower artifacts](part-17-migration-from-pre-ios-27/README.md#part-17--migration-from-pre-ios-27) — 17.README 🔇
- [Apps built with Xcode 26 keep catching GenerationError until you rebuild with 27; catch semantics change on rebuild](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#what-changed-between-ios-26-and-ios-27-the-complete-checklist) — 17.1 🔇
- [contextSize is a compiled-in 4096 below OS 27 and dynamic at or above it; hardcoding either number breaks on one side.](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#11-the-floor-that-is-easy-to-miss-contextsize-is-back-deployed) — 17.1
- [What-changed entry: beta 5 retyped Transcript.history and the history session property to Transcript.HistoryView.](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#49-additive--a-mutable-transcript-and-transcripthistory) — 17.1
- [Stable fm removes beta quota/PCC syntax; re-check deployment-OS help before migration automation.](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#52-additive--the-fm-command-line-tool-macos-27) — 17.1
- [catch GenerationError clauses still compile after an Xcode 27 rebuild but stop firing; the catch-all absorbs them](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#71-renamed--generationerror--languagemodelerror-and-two-siblings) — 17.1 🔇
- [A wheel built with Xcode 26 permanently lacks image support; ImagePromptError surfaces on the first image call](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#9-the-python-sdk-generation-lag) — 17.1
- [Xcode 26 gives no build-time signal of the adapter sunset: no attested deprecation, and the packaging CLI still ships](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md#the-adapter-sunset-migrating-off-custom-lora-adapters) — 17.2 🔇
- [Revised: Xcode 27 now emits adapter deprecation warnings, and hard obsolete errors once you target OS 27](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md#21-️-the-three-unknowns-and-what-to-do-about-each) — 17.2 🔇
- [MLXFoundationModels compiles only when the trait and the 27-SDK canImport both hold; otherwise it is an empty library](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md#82-where-mlxfoundationmodels-actually-is) — 17.2
- [GenerationError was deprecated, not deleted: catch clauses compile but stop firing once you rebuild with Xcode 27](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md#error-taxonomy-migration-generationerror--languagemodelerror) — 17.3 🔇
- [MLXFoundationModels builds green on the 26 SDK yet compiles to an empty library; the FM adapter is not in the binary](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md#what-this-covers) — 17.4
- [TOC pointer: the empty library — a green 26-SDK build of MLXFoundationModels contains nothing](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md#contents) — 17.4
- [MLXFoundationModels on the 26 SDK: builds successfully and contains nothing](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md#7-️-the-empty-library) — 17.4
- [Apple states it twice in-repo: on the 26 SDK MLXFoundationModels builds successfully as an empty library](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md#7-️-the-empty-library) — 17.4 🔇
- [SkillActivations dropped RandomAccessCollection in beta 3; the README's ForEach snippet no longer compiles](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md#152-skillactivation--foundation-models-utilities-will-not-build-on-xcode-26) — 17.4
- [Build artifacts carry compatibility constraints independent of source; none of these defects appear in a code diff](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#toolchain-and-asset-compatibility-when-your-build-artifacts-stop-working) — 17.6 🔇
- [TOC pointer: the export host's OS version is an input to the model's on-device performance](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#contents) — 17.6
- [Chicken-and-egg: repair tooling on beta-2+ machines runs the same versioned-IR conversion and cannot load the asset](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#️-the-chicken-and-egg) — 17.6
- [On beta-2+ machines the authoring bytecode reader aborts on the asset, so the published repair snippet cannot load it](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#️-the-chicken-and-egg) — 17.6
- [coreai-core==1.0.0b2 pins only the Python layer; the OS framework it dispatches to changes with every macOS update](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#43-the-mechanism-one-wheel-two-native-stacks) — 17.6
- [An artifact exported on an older host runs 2.2x slower on device while staying numerically fine; nothing flags it](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#45-️-the-lesson-the-export-hosts-os-version-is-an-input-to-the-models-performance) — 17.6
- [The lesson: the export host's OS version is an input to the artifact's on-device speed and memory](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#45-️-the-lesson-the-export-hosts-os-version-is-an-input-to-the-models-performance) — 17.6
- [Pinning 1.0.0-beta3 freezes you against beta-4 renames; the package tracks one Xcode beta and breaks on the next](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#the-commit-message-that-is-a-changelog) — 17.6
- [coreai-models pins xgrammar to branch main, not a version; identical checkouts can resolve different dependency code](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#93-applecoreai-models-123--the-ecosystem-chasing-the-same-rename) — 17.6

## Docs vs reality

**Part 17**

- [The apple-intelligence/private-cloud-compute doc path 404s; the live page is developer.apple.com/private-cloud-compute](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#42-additive--privatecloudcomputelanguagemodel) — 17.1
- [Utilities package traps: from: 1.0.0 never resolves, SkillActivations lost its collection shape, API is experimental](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#45-additive--skills-and-history-modifiers-the-utilities-package) — 17.1
- [Evaluations ships no agreement statistic; the sample's Statistics.cohensKappa is 72 lines of hand-rolled Swift](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#51-additive--the-evaluations-framework-xcode-27) — 17.1
- [.coreaimodel, .aiasset and a coreai-torch convert CLI are fabrications; real forms are .aimodel/.aimodelc directories](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#54-additive--core-ai) — 17.1
- [The apple-intelligence/private-cloud-compute documentation path 404s; use the shorter private-cloud-compute URL](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#144-apple-documentation-pages) — 17.1
- [Docs build Transcript.Response(segments:) but Apple's Origami sample also passes assetIDs; the SDK seems to require it](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md#136-when-the-answer-really-is-file-a-feedback) — 17.3
- ['8K context on iOS 27' is retired third-party provenance; Apple's TN3193 states 4096 tokens per session](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md#111-the-264-trap) — 17.4
- [No .coreaimodel, .aiasset or coreai-torch convert exist; real spellings are .aimodel/.aimodelc, both directories](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#27-mlmodel--mlmodelc--aimodel--aimodelc--and-both-are-directories) — 17.5
- [upgrade.md tells you to import MLXLMHuggingFace or MLXEmbeddersHuggingFace; neither module exists in the package](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#️-the-upgrade-doc-names-two-modules-that-do-not-exist-in-the-package) — 17.6
- [The migration doc's own Breaking Changes fix is stale: grep confirms neither named HuggingFace module exists](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#️-the-upgrade-doc-names-two-modules-that-do-not-exist-in-the-package) — 17.6 🔇
- [The utilities README's install line cannot resolve; only prerelease tags exist](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#️-the-silent-failure-3) — 17.6
- [README says .package(from: 1.0.0) but only 1.0.0-beta1 and beta3 tags exist; SwiftPM's from: excludes prereleases](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#️-the-silent-failure-3) — 17.6 🔇

## API footguns

**Part 17**

- [ToolCallingMode.required loops tool calls forever unless a tool throws or a DynamicProfile switches the mode](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#48-additive--toolcallingmode-and-its-exit-condition-trap) — 17.1 🔇
- [toolCallingMode exists on both GenerationOptions and DynamicProfile; precedence when both are set is unverified](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#48-additive--toolcallingmode-and-its-exit-condition-trap) — 17.1
- [Returning a corrective string for invalid .anyOf arguments makes the model loop re-calling; add a counter and hard exit](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#66-behavioural--anyof-still-does-not-constrain) — 17.1
- [The sampling factory is random(top:seed:) but the Kind case is randomTopK; two spellings at two API levels](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#73-renamed--sampling-mode-cases) — 17.1
- [urlSessionConfiguration is excluded from Configuration ==/hash; a cached executor may carry the wrong session](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#74-renamed--model_-moved-from-the-utilities-package-into-the-framework) — 17.1
- [LanguageModel in the MLX protocol is MLX's type, not FoundationModels'; the name collision satisfies the compiler](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md#84-fuse-dont-ship-an-adapter--and-why) — 17.2
- [default: break on the non-frozen error enum silently swallows every future case; use @unknown default instead](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md#33-source-c--two-compiling-apple-sample-apps-five-cases-and-a-default) — 17.3 🔇
- [GeneratedContentParsingError is not a LanguageModelError; guided-generation parse failures skip your ladder](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md#7-generatedcontentparsingerror-is-not-a-languagemodelerror) — 17.3 🔇
- [A misspelled canImport module or undefined condition makes an #if silently false and deletes the guarded code](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md#building-for-two-sdks-conditional-compilation-across-26-and-27) — 17.4 🔇
- [Misspelled canImport, undefined conditions and wrong version forms all make gates quietly always-false](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md#46-️-silent-failure-three-ways-to-write-a-gate-that-is-quietly-always-false) — 17.4
- [loadFunction returns nil for a missing name but throws for a load failure; try? collapses two different diagnoses](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#22-mlmodel--aimodel--but-the-runnable-object-is-a-third-type) — 17.5
- [Outputs.remove(_:) is destructive: read an output twice (log, then return) and the second read is silently nil](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#24-mlfeatureprovider--a-dictionary-and-a-destructive-output-bag) — 17.5
- [InferenceValue.ndArray looks like an ordinary getter but consumes the value and transfers ownership on access](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#24-mlfeatureprovider--a-dictionary-and-a-destructive-output-bag) — 17.5
- [Segment.box origin is bottom-left on macOS and top-left on iOS; detection's boundingBox uses yet another convention](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#35-️-silent-failure-orientation-and-coordinate-conventions-which-used-to-be-someone-elses-job) — 17.5
- [Translation table: Core ML output reads become destructive Outputs.remove(_:) — take each value exactly once](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#91-the-translation-table-condensed) — 17.5
- [A bundle holds two different metadata.json files at different depths; only the inner one is the producer fingerprint](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#35-the-audit-the-producer-fingerprint) — 17.6
- [strip_debug_info mutates in place and returns None; transcribing the snippet as an assignment nulls your program](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#what-strip_debug_info-actually-does) — 17.6
- [expectFrequentReshapes=true on an all-static graph abandons the AOT specialization, recompiles on device and segfaults](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#a-second-related-landmine-at-the-same-layer) — 17.6
- [FM macro expansions need six imports at the call site; missing one yields 'cannot find type' inside generated code](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#️-the-upgrade-doc-names-two-modules-that-do-not-exist-in-the-package) — 17.6

## General cautions

**Part 17**

- [Group Labs ship no caption track — cite Apple's written Q&A summary as paraphrase, never as an engineer's words.](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#11-the-floor-that-is-easy-to-miss-contextsize-is-back-deployed) — 17.1
- [TensorOps availability is per-symbol, not a blanket 26.2; quote each header annotation as a header annotation](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#2-the-tensorops-ladder-is-a-different-ladder) — 17.1
- [Mutating session.transcript during an in-flight request throws the new transcriptMutationWhileResponding error](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#49-additive--a-mutable-transcript-and-transcripthistory) — 17.1
- [Pointer: watchOS 27 beta 2 has an Apple-confirmed build break, covered in the checklist's section 10](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#412-additive--watchos) — 17.1
- [Core AI ships zero Apple sample-code projects; unlike Foundation Models there is no first-party compiling reference](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#54-additive--core-ai) — 17.1
- [Apple's own data: detailed prompts raise generation-error rates via context pressure; terse prompts yield excess items](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#61-behavioural--the-on-device-model-was-rebuilt) — 17.1
- [Whether the concurrency/thermal restriction also covers SystemLanguageModel is unanswered on the forums](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#68-behavioural--concurrency-and-thermals-throttle-you-invisibly) — 17.1
- [Custom LoRA adapters are removed outright; the LanguageModel protocol succeeds the goal, not the train-a-delta mechanism](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#81-withdrawn--custom-lora-adapters) — 17.1
- [Meta note: this section collects every silent failure in the 26-to-27 migration into one table](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#11-every-silent-failure-in-this-migration-collected) — 17.1
- [SwiftTranscriptionSampleApp is a WWDC25 leftover, named only so nobody mistakes it for 2026 evidence](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#142-apple-sample-code-projects-used) — 17.1
- [FoundationModelsCoffeeGame still targets iOS 26.0; cite it only as the before column, never as 2026 API](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#142-apple-sample-code-projects-used) — 17.1
- [Repeated audit result: the coreai documentation index contains zero sample-code projects](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#142-apple-sample-code-projects-used) — 17.1
- [Session 241's transcript says 'Our 2027 release' while every OS reference is 27; do not write '2027 release'](part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md#146-transcripts) — 17.1
- [Three unresolved unknowns about legacy adapters under iOS 27, each paired with a safe default](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md#21-️-the-three-unknowns-and-what-to-do-about-each) — 17.2
- [The whole adapter-pipeline section is 26.x history; do not build new work on it](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md#3-the-historical-record-the-26x-adapter-pipeline) — 17.2
- [The leak cleanup is rm -rf on a system path from Recovery Mode; confirm the volume identifier and keep a backup](part-17-migration-from-pre-ios-27/references/02-adapter-sunset.md#44-️-the-100-mb-per-call-disk-leak) — 17.2
- [Evidence scope: the 26.5 interface proves only the before state and the 27.0 beta only the after](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md#primary--the-compiler-emitted-sdk-interface-strongest-class-in-this-corpus-above-sample-code) — 17.3
- [The 26-era CoffeeGame sample is deliberately not cited as 2026 evidence; it shows only the before shapes](part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md#primary--apple-sample-code-projects-strongest-compiling-app-class) — 17.3
- [A dual-SDK CI matrix that only compiles misses load-time crashes; load and run the binary on-device per beta seed](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md#132-the-three-lessons) — 17.4
- [Support matrix: simulators validate compile and launch only; behavioral results need physical 27 hardware](part-17-migration-from-pre-ios-27/references/04-dual-sdk-builds.md#161-the-two-axes) — 17.4
- [Core AI succeeds Core ML for neural networks only; decision trees and tabular pipelines stay on Core ML by design](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#core-ml-to-core-ai-what-moves-what-stays-and-how) — 17.5
- [TOC pointer to the guide's collection of failures that do not announce themselves](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#contents) — 17.5
- [Section heading for the Core AI failures that do not announce themselves: compute units, drift, caches, miscompiles](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#3-️-what-does-not-announce-itself) — 17.5
- [states: requires a mutable view for every declared state; omitting any produces an error — enumerate stateNames first](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#41-states-kv-caches-as-first-class-in-place-model-inputs) — 17.5
- [The 76% multi-function saving is Apple's demo number with no device or protocol stated; treat it as an existence proof](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#42-multi-function-assets--and-the-finding-that-reframes-them) — 17.5
- [Verified: 0 sample-code entries across all 312 indexed Core AI symbols; no first-party compiling reference exists](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#51-the-hard-fact-core-ai-ships-with-zero-apple-sample-code-projects) — 17.5
- [Span<Int> is not a Sequence: no shape.last; use shape.count and manual index arithmetic in the shim](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#81-step-1-put-both-behind-one-protocol) — 17.5
- [MLState maps to states: mutable views, and every declared state must be supplied or the call errors](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#91-the-translation-table-condensed) — 17.5
- [.aimodel replaces .mlmodel/.mlpackage and is a directory; file-oriented scripts must treat it as a bundle](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#91-the-translation-table-condensed) — 17.5
- [.aimodelc is also a directory; the per-architecture compiled output is a bundle, not a single file](part-17-migration-from-pre-ios-27/references/05-coreml-to-coreai.md#91-the-translation-table-condensed) — 17.5
- [The 0.4.0 asset break was debug-only metadata — weights and program were fine — which is why the repair is cheap](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#32-the-root-cause-and-why-deep-models-fire-it) — 17.6
- [coreai-torch only warns beyond torch 2.13.0 and proceeds; exports made with newer torch are unvalidated](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#path-a--re-convert-from-source-apples-original-guidance) — 17.6
- [Mode.RELEASE just ships less metadata surface; it is no compatibility promise against future versioned-IR changes](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#39-preventing-a-recurrence-moderelease) — 17.6
- [Pinning an older export host conflicts with beta tooling needs; plan two machines or a reversible upgrade procedure](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#47-the-operational-rule) — 17.6
- [AIModel.specialize reports no progress and no cancellation contract; large models block minutes with nothing to show](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#what-to-do-with-the-signal) — 17.6
- [Conversion is not byte-deterministic (a rebuild differed by 492 bytes); content_hash proves identity, not equivalence](part-17-migration-from-pre-ios-27/references/06-toolchain-and-asset-compatibility.md#why-each-field-is-there) — 17.6

---

🔇 = the guide marks this as an explicit **SILENT FAILURE** callout.
