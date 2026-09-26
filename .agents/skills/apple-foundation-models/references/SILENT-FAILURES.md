# Silent-failure index — Foundation Models: the on-device LLM API

**396 ⚠️ callouts from the guide parts this skill covers, sorted by the symptom you would observe.** Most defects in this stack do not throw, so the symptom is what you start from.

> Sliced from the series index on 2026-09-22. The full index across all 17 parts is at https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/SILENT-FAILURES.md. Generated — regenerate with `./scripts/build-skills.sh` rather than editing by hand.

| Symptom | Entries |
|---|---:|
| [Wrong output](#wrong-output) | 24 |
| [Empty output / no-op](#empty-output--no-op) | 27 |
| [Truncation & limits](#truncation--limits) | 6 |
| [Ignored input](#ignored-input) | 30 |
| [Stale state](#stale-state) | 17 |
| [Data & artifact loss](#data--artifact-loss) | 15 |
| [Compiles but unavailable](#compiles-but-unavailable) | 30 |
| [Performance cliffs](#performance-cliffs) | 14 |
| [Resource growth](#resource-growth) | 7 |
| [Misleading signals](#misleading-signals) | 30 |
| [Version drift](#version-drift) | 31 |
| [Docs vs reality](#docs-vs-reality) | 40 |
| [API footguns](#api-footguns) | 70 |
| [General cautions](#general-cautions) | 55 |

## Wrong output

**Part 2**

- [Prompt injection never throws — a successful attack reads as a normal Response; token caps also truncate with no flag.](part-02-foundation-models-everyday-api/README.md#21--languagemodelsession-end-to-end) — 2.README 🔇
- [SpotlightSearchTool hands the model identity attributes only — bodies never arrive and it invents them fluently.](part-02-foundation-models-everyday-api/README.md#24--local-rag-with-spotlightsearchtool-plus-ocr-and-barcodes) — 2.README 🔇
- [EXIF-rotated camera photos load sideways and get fluent wrong answers; summarizeHistory also flattens attachments away.](part-02-foundation-models-everyday-api/README.md#25--image-input-and-what-the-model-cannot-do-with-pixels) — 2.README 🔇
- [A successful prompt injection returns a clean Response with plausible text — no error, guardrail case, or trace shows…](part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md#33-the-concrete-failure) — 2.1 🔇
- [includeSchemaInPrompt:false without a full example still yields well-formed objects — field semantics quietly degrade.](part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md#43-one-shot-prompting-with-a-generable-instance) — 2.1 🔇
- [Schema off, no example: still structurally valid output, just worse — wrong emphasis, empty strings, grammar padding.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#102-the-precondition--and-the-silent-failure-if-you-break-it) — 2.2 🔇
- [Contents entry: the metadata gap — the Spotlight defect where the model invents document bodies.](part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md#contents) — 2.4
- [Heading: the metadata gap — the defect that will burn you.](part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md#6-️-the-metadata-gap--the-defect-that-will-burn-you) — 2.4
- [The tool call succeeds and returns well-formed items with no bodies — the model's answer is fluent, specific, invented.](part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md#62-what-the-failure-looks-like) — 2.4 🔇
- [A URL judged by UTType only — renamed .txt, zero-byte, unscoped file — attaches fine; the answer describes nothing.](part-02-foundation-models-everyday-api/references/05-image-input-and-attachments.md#33-the-file-url-path) — 2.5 🔇
- [EXIF orientation 6 without correction sends the image sideways — the model calls a standing person lying down.](part-02-foundation-models-everyday-api/references/05-image-input-and-attachments.md#52-why-this-bites) — 2.5 🔇

**Part 3**

- [Heading: the consultation that quietly returns nonsense.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#36-️-silent-failure--the-consultation-that-quietly-returns-nonsense) — 3.4
- [A failed child-session consultation reaches the parent as ordinary tool output — and the parent model believes it.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#36-️-silent-failure--the-consultation-that-quietly-returns-nonsense) — 3.4 🔇

**Part 4**

- [Declaring guided generation a server ignores yields parse failures or well-formed output with invented fields.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#25-supportsguidedgeneration-is-a-promise-you-are-making-for-the-server) — 4.2 🔇
- [Backend table: ChatCompletions delegates schema enforcement to the server — strictness is whatever the server does.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#54-the-consequence-stated-plainly) — 4.2
- [Comparison table: @Generable is server-delegated on ChatCompletions and lost on Core AI's pipelined engine.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#82-the-comparison-that-actually-decides-it) — 4.2
- [Over-declaring .guidedGeneration never throws — it returns malformed JSON at the parse boundary or invented fields.](part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md#53-capabilities-are-routing-not-documentation) — 4.3 🔇
- [The id latch concatenates repeated tool-call ids into call_1call_1…, and the else-if drops content sharing a chunk.](part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md#95-two-smaller-channel-rules-both-from-apples-pitfall-list) — 4.3

**Part 5**

- [A tool named in instructions but missing from the toolset loops the model: fluent wrong-mode output and no error.](part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md#contents) — 5.1
- [The canonical bug: instructions name a tool the toolset lacks; the model loops in brainstorm mode, output stays…](part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md#8-️-the-canonical-worked-bug-a-tool-named-in-prose-missing-from-the-toolset) — 5.1
- [Every layer behaves correctly while the user sees the wrong feature — the model can't switch modes and nothing throws.](part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md#84-️-why-this-class-of-bug-is-the-worst-kind) — 5.1
- [The model kept accepting input and making tool calls, never threw, and gave no signal — Apple's archetypal silent…](part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md#84-️-why-this-class-of-bug-is-the-worst-kind) — 5.1 🔇
- [token_count([]) takes the tools path (vacuous all()) and returns the empty toolset's count, not a prompt count.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#73-context_size-and-token_count--the-264-gate) — 5.2
- [Image input is unreliable for spatial localisation — confident answers that misplace regions (thread 838613).](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#113-image-guidance-carried-over-from-the-swift-side) — 5.2

## Empty output / no-op

**Part 2**

- [A tool-call-only turn ends the stream after zero partials — spinner UIs waiting on a first partial hang forever.](part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md#64-a-stream-can-finish-having-yielded-zero-partials) — 2.1 🔇
- [Python's contents.value returns None for a missing key where Swift throws — ported code silently reads null.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#82-reading-values) — 2.2
- [Heading: a stream can finish having yielded zero snapshots.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#96-️-a-stream-can-finish-having-yielded-zero-snapshots) — 2.2
- [for try await can complete with zero iterations on a tool-call-only turn — first-snapshot spinners hang, unwraps crash.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#96-️-a-stream-can-finish-having-yielded-zero-snapshots) — 2.2 🔇
- [Tool-only turns are normal in agentic sessions — zero-snapshot streams occur in routine operation; design for them.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#96-️-a-stream-can-finish-having-yielded-zero-snapshots) — 2.2
- [A turn whose entire output is a tool call streams nothing — streamResponse completes without yielding one partial.](part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md#1-the-loop-in-apples-own-words) — 2.3 🔇
- [Device-tested: unlabelled attachments still reach tools; the hazard is no stable identity for ImageReference lookup.](part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md#10-built-in-system-tools-ocrtool-and-barcodereadertool) — 2.3 🔇
- [Skip calling searchableItemsHandler on any path and Spotlight waits forever — no error, no visible timeout, no results.](part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md#7-searchableitemsforidentifierssearchableitemshandler--the-intended-fix-and-the-conflict) — 2.4 🔇
- [Your searchableItems delegate can be wired, compiled, and simply never called — verify it fires before building on it.](part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md#71-the-conflict--and-it-is-a-real-one) — 2.4 🔇
- [A ResponseStream can end with zero partials on tool-call turns — multimodal turns hit this disproportionately.](part-02-foundation-models-everyday-api/references/05-image-input-and-attachments.md#62-the-mechanism-end-to-end) — 2.5 🔇
- [Labels are identity, not a gate; omit one and identity lookups resolve to nil.](part-02-foundation-models-everyday-api/references/05-image-input-and-attachments.md#64-labelling-rules) — 2.5 🔇
- [The DETR postprocessor suits set-prediction only — with anchor-based YOLO, decode returns [] and you 'detect nothing'.](part-02-foundation-models-everyday-api/references/05-image-input-and-attachments.md#94-the-core-ai-route-real-detection-and-real-segmentation) — 2.5
- [Modifiers apply outside-in — composed in the obvious order, summarizeHistory can never fire.](part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md#63-what-developers-hand-rolled-and-what-replaced-it) — 2.6

**Part 3**

- [summarizeHistory is a no-op on tool-output continuations — the guard fails and nothing records that it skipped.](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#74-summarizehistory--read-this-before-you-ship-it) — 3.1
- [Heading: the composed example in Apple's README can never fire.](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#76-️-silent-failure--the-composed-example-in-apples-readme-can-never-fire) — 3.1
- [summarizeHistory fires only when the last entry is a .prompt — after tool turns it silently skips; Apple's test says so.](part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md#134-summarizehistory--the-most-aggressive-one) — 3.2 🔇
- [Heading: the composition rule — and why Apple's own examples never fire.](part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md#135-️-the-composition-rule--and-why-apples-own-examples-never-fire) — 3.2
- [rollingWindow(10) before summarizeHistory(threshold:10): 10>10 is false forever — summarisation can never run.](part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md#135-️-the-composition-rule--and-why-apples-own-examples-never-fire) — 3.2 🔇
- [Scope note: every composed call site the repo ships is inert — the thresholds can never trip.](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#what-this-covers) — 3.3
- [Contents entry: every composed example in the repository is inert.](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#contents) — 3.3
- [On tool-output continuations the summarise guard fails and the modifier returns — no log, no observable difference.](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#33-summarizehistory--the-nuclear-option) — 3.3 🔇
- [Heading: every composed history-modifier example in the repository is inert.](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#5-️-every-composed-example-in-the-repository-is-inert) — 3.3
- [An inert composition is indistinguishable from a working one — until contextSizeExceeded starts landing in production.](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#5-️-every-composed-example-in-the-repository-is-inert) — 3.3 🔇

**Part 4**

- [First-token spinners can hang two ways at .deep — tool-call-only turns yield zero partials, and reasoning runs unseen.](part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md#65-the-reasoning-segment-and-using-it-for-progress-ui) — 4.1 🔇

**Part 5**

- [A turn that is only a tool call completes streamResponse with zero partials; spinner-until-first-partial UIs hang…](part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md#91-the-three-from-the-session) — 5.1 🔇
- [A tool call() that never returns leaves the Swift continuation unresumed — the session hangs forever, no timeout, no…](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#104-️-a-tool-that-never-returns-hangs-the-session-forever) — 5.2
- [pytest collects test_memory_stress.py and runs nothing — it defines no test_ functions; invoke it with python directly.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#136-how-to-know-whether-you-are-leaking) — 5.2

## Truncation & limits

**Part 2**

- [maximumResponseTokens stops output mid-sentence as a valid Response — no throw and no wasTruncated flag exists.](part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md#104-maximumresponsetokens) — 2.1 🔇
- [Do not hardcode 4096 — budgeting below the real window over-compacts and quietly degrades answers; read contextSize.](part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md#22-which-availability-api-answers-which-question) — 2.6
- [maximumResponseTokens truncates mid-sentence without error — the response arrives valid, just cut off.](part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md#61-the-error-and-the-budget-it-refers-to) — 2.6

**Part 3**

- [A hardcoded 4096 under a 32K PCC window compacts eight times too often and summarises away context the model could use.](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#34-the-rule-read-it-dont-hardcode-it) — 3.1 🔇
- [@Generable schemas ride along with every request but appear in no transcript entry — unbudgeted, they skew your math.](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#122-step-2--price-the-fixed-costs-once) — 3.1
- [Apple: limiting tokens can produce incomplete responses like 'A cat is a small.' — use only to curb verbosity.](part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md#54-maximumresponsetokens) — 3.2

## Ignored input

**Part 2**

- [@Guide(.anyOf) does not reliably constrain output — out-of-set values parse cleanly and your switch hits default.](part-02-foundation-models-everyday-api/README.md#22--guided-generation-and-snapshot-streaming) — 2.README 🔇
- [Contents entry: @Guide(.anyOf) does not constrain generation.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#contents) — 2.2
- [Heading: .anyOf does not constrain generation.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#4-️-anyof-does-not-constrain-generation) — 2.2
- [The model emits values outside your .anyOf set; nothing throws, the String parses, and switches fall to default in prod.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#4-️-anyof-does-not-constrain-generation) — 2.2 🔇
- [Python @fm.generable('description') stores the description and never sends it — the model never sees it.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#121-fmgenerable-and-fmguide) — 2.2
- [Python respond(generating:) drops options= on the floor — temperature, sampling, max tokens have no effect; evals lie.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#123-️-three-python-side-silent-failures) — 2.2 🔇
- [.anyOf on tool arguments is confirmed broken — a three-city constraint got called with 'Beijing'; validate in the tool.](part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md#33-anyof-does-not-constrain--validate-anyway) — 2.3 🔇
- [A CustomStage conforms and is accepted, but the 27.0-beta pipeline never routes items through it — measured no-op.](part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md#124-the-beta-era-caveat) — 2.4 🔇
- [permissiveContentTransformations does not apply to @Generable — adopting guided output silently drops permissive mode.](part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md#52-the-blind-spot-it-does-not-apply-to-generable) — 2.6

**Part 3**

- [Endpoint building recognises only 'v1' — any other version path silently gets /v1/chat/completions appended.](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#19-chatcompletionslanguagemodel-briefly) — 3.3 🔇
- [A call-site GenerationOptions(toolCallingMode:) silently overrides the profile's conditioned exit — loop or no tools.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#52-two-places-to-set-it-one-precedence-rule) — 3.4 🔇

**Part 4**

- [buildURLRequest recognises only 'v1' in the path — other version paths get the wrong endpoint; live defect FB23837262.](part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md#121-the-three-replacements) — 4.1
- [Contents entry: the URL-versioning defect, and the workaround that works.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#contents) — 4.2
- [Heading: the URL-versioning defect, and the workaround that works.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#24-️-the-url-versioning-defect-and-the-workaround-that-works) — 4.2
- [LFM2.5 ignores in-context Hermes tool-call instructions and emits its trained dialect — the training prior wins.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#36-capabilities-is-routing-not-documentation) — 4.2
- [Comparison table: on Core AI only temperature reaches the engine — seeds and other sampling options are dropped.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#82-the-comparison-that-actually-decides-it) — 4.2
- [The shipped executor never reads contextOptions, id, or metadata — ContextOptions(reasoningLevel:) does nothing.](part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md#6-reading-a-request-all-seven-fields) — 4.3
- [Heading: the silent failure hiding in every transcript-conversion switch — unhandled entries just disappear.](part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md#86-️-the-silent-failure-hiding-in-every-one-of-these-switches) — 4.3
- [Catch-all defaults in transcript converters drop unhandled entries — the request goes out short and the model answers.](part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md#86-️-the-silent-failure-hiding-in-every-one-of-these-switches) — 4.3 🔇

**Part 5**

- [A schema flag that fails to apply still yields prose on stdout with exit 0; jq errors lines later, blaming the wrong…](part-05-prototyping-profiling-non-swift/README.md#52--the-fm-cli-and-the-foundation-models-sdk-for-python) — 5.README 🔇
- [fm respond writes prose to stdout when a schema isn't applied, exit 0; jq errors later naming the wrong culprit.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#31-why-this-gap-is-worse-than-it-looks) — 5.2 🔇
- [In the generating=Cat branch of respond, your options are dropped.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#83-respond--five-paths-through-one-method) — 5.2
- [respond(generating:options:) silently discards options — session.py:473 calls _respond_with_schema without them.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#83-respond--five-paths-through-one-method) — 5.2 🔇
- [top_k/top_p/seed are serialised as strings the Swift side fails to cast — sampling is never assigned; seeds do nothing.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#86-generationoptions-and-the-random-sampling-bug) — 5.2 🔇
- [Optionality is substring-sniffed from the type string — 'int | None' fields silently become required.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#93-️-the-optional-detection-trap--the-sharpest-edge-in-the-sdk) — 5.2
- [is_optional is 'Optional' in str(type): int | None never matches, and Optional[int] stops matching on Python 3.14.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#93-️-the-optional-detection-trap--the-sharpest-edge-in-the-sdk) — 5.2 🔇
- [The @fm.generable description is stored and never read — the type-level description never reaches the model.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#96-️-the-type-level-description-is-silently-discarded) — 5.2
- [@fm.generable('desc') stores _generable_description; nothing passes it into the schema — grep finds zero readers.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#96-️-the-type-level-description-is-silently-discarded) — 5.2 🔇
- [value(int, for_property:) never coerces raw values — the coercion helper is dead code and a JSON string stays a str.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#98-reading-a-generatedcontent) — 5.2
- [Reproducible sampling is greedy-only in Python — random-sampling params, seed included, never survive the bridge.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#154-where-this-hands-off-to-part-6) — 5.2

## Stale state

**Part 2**

- [Tool parameters are computed once at session init and never re-read — late-loaded .anyOf data never reaches the schema.](part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md#32-runtime-schemas-and-the-trap-under-them) — 2.3 🔇
- [.preserveTranscript can leave a partially generated last entry — transcript repair is on you before continuing.](part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md#73-the-default-a-thrown-tool-error-rolls-the-transcript-back) — 2.3 🔇
- [preserveTranscript can leave a half-generated entry in history — later turns build on the corrupted tail.](part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md#75-toolcallerror-and-failed-to-parse-generated-content) — 2.6

**Part 3**

- [trimKVCache may retain one token fewer than asked — prefill from the requested offset and model state silently diverges.](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#93-the-contract-and-the-detail-that-will-bite-you) — 3.1
- [A SkillActivations built in a view body resets every render — skills silently deactivate and re-activate in a loop.](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#153-one-skillactivations-per-session-held-outside-the-view) — 3.3 🔇
- [The baton lands on the next request — the profile that called the tool usually still finishes the current turn.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#25-the-baton-lands-on-the-next-request-not-mid-request) — 3.4
- [.preserveTranscript may leave the last entry partially generated — put the transcript back in order before continuing.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#63-the-transcript-consequence-of-exit-b) — 3.4 🔇
- [Heading: the consent nobody answers — a pending proposal that never resolves.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#77-️-silent-failure--the-consent-nobody-answers) — 3.4
- [A pending approval proposal with no resolution path leaves the model believing a question is outstanding, forever.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#77-️-silent-failure--the-consent-nobody-answers) — 3.4 🔇
- [A child session over the parent's model instance corrupts the parent's KV state — give the consultant its own model.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#84-how-the-route-gets-decided--and-a-measured-disagreement-with-apple) — 3.4

**Part 4**

- [Models differing only in URLSessionConfiguration are cache-equal — the second silently inherits the first's transport.](part-04-beyond-the-built-in-model/README.md#44--executor-lifecycle-configuration-identity-and-preserving-work-across-calls) — 4.README 🔇
- [The executor cache is keyed on Configuration, not your model value — equal configs silently share one executor.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#what-does-not-hold-constant) — 4.2 🔇
- [Configuration's == deliberately excludes the URLSession — your timeout config can silently be the other model's.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#28-transport-timeouts-and-the-executor-cache-wrinkle) — 4.2 🔇
- [A hand-written == ignoring a behavioural field makes the framework return the wrong cached executor.](part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md#32-configuration-is-a-cache-key-and-that-is-a-design-constraint) — 4.3 🔇
- [Contents entry: the urlSession that isn't in the cache key.](part-04-beyond-the-built-in-model/references/04-executor-lifecycle-and-kv-reuse.md#contents) — 4.4
- [Heading: the urlSession that isn't in the key.](part-04-beyond-the-built-in-model/references/04-executor-lifecycle-and-kv-reuse.md#3-️-the-urlsession-that-isnt-in-the-key) — 4.4
- [Configs differing only in URLSession are cache-equal — a 600 s timeout silently becomes the default, proxies skipped.](part-04-beyond-the-built-in-model/references/04-executor-lifecycle-and-kv-reuse.md#3-️-the-urlsession-that-isnt-in-the-key) — 4.4 🔇

## Data & artifact loss

**Part 2**

- [summarizeHistory condenses everything into one .prompt entry — attachments vanish and later image answers are invented.](part-02-foundation-models-everyday-api/references/05-image-input-and-attachments.md#73-images-accumulate-and-they-are-not-free-to-keep) — 2.5 🔇
- [rollingWindow is a naive suffix(n), not transcript-aware — it cuts between a prompt and its response.](part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md#63-what-developers-hand-rolled-and-what-replaced-it) — 2.6

**Part 3**

- [Summarisation renders segments to text first — structured content and attachments are dropped without comment.](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#23-segments-the-second-dimension) — 3.1 🔇
- [Policy table: rollingWindow is known-buggy — it can orphan a response — and invalidates the cache when it fires.](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#123-step-3--choose-a-compaction-policy-before-you-need-one) — 3.1
- [Policy table: summarizeHistory collapses history to one entry, losing tool structure, and totally invalidates the cache.](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#123-step-3--choose-a-compaction-policy-before-you-need-one) — 3.1
- [Apple's own test: rollingWindow's naive trim orphans a response — 'in practice it crashes partway through.'](part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md#133-rollingwindowentries--apple-ships-a-known-bug) — 3.2 🔇
- [Scope note: rollingWindow ships known-buggy — Apple's own test documents the orphaned-response outcome.](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#what-this-covers) — 3.3
- [Contents entry: rollingWindow splits prompt/response pairs — and Apple knows.](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#contents) — 3.3
- [Heading: rollingWindow splits prompt/response pairs — and Apple knows.](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#7-️-rollingwindow-splits-promptresponse-pairs--and-apple-knows) — 3.3
- [Apple's test comment verbatim: the naive trim orphans a response and 'in practice it crashes partway through.'](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#7-️-rollingwindow-splits-promptresponse-pairs--and-apple-knows) — 3.3 🔇
- [The summariser never sees instructions, structured content, or images — it compresses a chat it cannot understand.](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#10-what-the-summarizer-actually-reads-transcriptrendering) — 3.3 🔇

**Part 4**

- [summarizeHistory condenses everything to one .prompt entry — .toolCalls entries are destroyed; roll your own modifier.](part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md#101-the-bug-switching-back-to-the-on-device-model-mid-conversation) — 4.1
- [A chunk carrying both tool_calls and content loses the content — the else-if drops interleaved text; nothing throws.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#26-what-crosses-the-wire-and-what-is-quietly-dropped) — 4.2 🔇
- [Heading: wholesale, not additive.](part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md#94-️-wholesale-not-additive) — 4.3
- [updateMetadata events are wholesale snapshots — send fewer keys and the missing ones are removed; re-emit everything.](part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md#94-️-wholesale-not-additive) — 4.3 🔇

## Compiles but unavailable

**Part 2**

- [Contents entry: backends that sample on the GPU expose no logits, so guided generation is lost there.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#contents) — 2.2
- [Heading: the logits problem — the fastest backend can lose guided generation.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#6-️-the-logits-problem-when-your-fastest-backend-loses-guided-generation) — 2.2
- [Engines that sample on the GPU never expose per-step logits — guided generation there is impossible, not degraded.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#6-️-the-logits-problem-when-your-fastest-backend-loses-guided-generation) — 2.2 🔇
- [BarcodeReaderTool lists watchOS, OCRTool does not — gate watchOS OCR paths; cut feature or doc slip is unresolved.](part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md#what-the-two-declarations-actually-say) — 2.3
- [Symbol table: OCRTool has no watchOS row; its Arguments/Output are absent from the captured Vision interface.](part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md#131-symbols-with-version-floor-and-evidence) — 2.3
- [Model availability is not tool availability — every documented check passes while SpotlightSearchTool fails to init.](part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md#141-the-model-catalog-error--thread-838904) — 2.4 🔇
- [On Linux the Python SDK buffers whole responses — streaming arrives in one burst — and @Generable is Darwin-gated.](part-02-foundation-models-everyday-api/references/05-image-input-and-attachments.md#102-the-platform-asymmetry--in-memory-images-are-apple-only) — 2.5
- [Image support needs the macOS 27 SDK at build time — a wheel built without it permanently lacks Attachment.](part-02-foundation-models-everyday-api/references/05-image-input-and-attachments.md#112-the-build-time-sdk-gate--a-wheel-can-permanently-lack-image-support) — 2.5 🔇

**Part 3**

- [BYO models on GPU-pipelined bundles lose @Generable — guided generation needs logits those engines never expose.](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#104-how-this-should-change-your-decision-table) — 3.1
- [Backend table: @Generable is unavailable on GPU-pipelined Core AI bundles — no logits, no constrained decoding.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#81-what-each-backend-is-charged-for) — 3.4
- [Heading: the constraint that decides your backend — @Generable needs logits.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#85-️-the-constraint-that-decides-your-backend-generable-needs-logits) — 3.4
- [GPU-pipelined bundles sample on-GPU and never surface logits — the fastest backend forfeits guided generation.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#85-️-the-constraint-that-decides-your-backend-generable-needs-logits) — 3.4 🔇

**Part 4**

- [PCC without its entitlement fatalErrors past do/catch; availability ignores quota; reasoning tokens eat the 32K unseen.](part-04-beyond-the-built-in-model/README.md#41--private-cloud-compute-eligibility-reasoning-and-quota-ux) — 4.README 🔇
- [GPU-pipelined Core AI returns no logits so @Generable cannot work — variant:nil auto-detect hides which engine you got.](part-04-beyond-the-built-in-model/README.md#42--core-ai-mlx-and-any-openai-compatible-server-behind-languagemodelsession) — 4.README 🔇
- [PCC needs Xcode 27 plus a physical device on 27.0+ — it does not work in the Simulator.](part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md#what-you-need) — 4.1
- [Heading: the missing entitlement does not throw.](part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md#23-️-silent-failure--the-missing-entitlement-does-not-throw) — 4.1
- [Missing the managed PCC entitlement produces a fatalError — do/catch never runs; community-reported, thread 831998.](part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md#23-️-silent-failure--the-missing-entitlement-does-not-throw) — 4.1 🔇
- [Community: watchOS 27 alone is not enough for PCC — the Watch must pair to an iPhone with Apple Intelligence on.](part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md#36-watchos-and-why-it-is-a-pcc-story) — 4.1
- [Heading: the Simulator does not run PCC.](part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md#55-️-the-simulator-does-not-run-pcc) — 4.1
- [Heading: guided generation can disappear.](part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md#123-️-the-constraint-nobody-mentions-guided-generation-can-disappear) — 4.1
- [Moving off PCC to a fast local backend can cost you @Generable — GPU-pipelined engines expose no logits.](part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md#123-️-the-constraint-nobody-mentions-guided-generation-can-disappear) — 4.1
- [Contents entry: the logits constraint — why the fastest backend loses @Generable.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#contents) — 4.2
- [On Linux streamResponse still compiles and yields partials — but all at once, when the request completes.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#29-linux-and-the-streaming-you-do-not-get-there) — 4.2
- [Factories load via NSClassFromString — skip linking MLXLLM and there is nothing to find; loading fails at runtime.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#33-a-consumer-packageswift-that-works) — 4.2
- [Heading: the logits constraint — why the fastest backend loses @Generable.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#5-️-the-logits-constraint-why-the-fastest-backend-loses-generable) — 4.2
- [Verified on 27.0 beta: hybrid/SSM bundles run behind LanguageModelSession, but pipelined engines expose no logits.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#52-what-the-fast-engine-does) — 4.2
- [On non-Darwin the executor buffers the entire response — 'streaming' delivers everything at once at completion.](part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md#22-should-you-support-linux) — 4.3 🔇
- [Verified at CoreAILanguageModel.swift:860 — GPU-pipelined bundles report guided generation unsupported; no logits.](part-04-beyond-the-built-in-model/references/04-executor-lifecycle-and-kv-reuse.md#113-the-constraint-behind-both-of-those-throws) — 4.4

**Part 5**

- [Image support is compiled in or out by the build machine's macOS SDK; users learn only when an image prompt fails.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#64-️-the-build-machine-silently-decides-whether-images-work) — 5.2
- [A wheel built where SDK detection returns None or <27 omits image support; nothing at runtime says so until a prompt…](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#64-️-the-build-machine-silently-decides-whether-images-work) — 5.2 🔇

## Performance cliffs

**Part 3**

- [Cache invalidation never throws — a reordering transform or time-interpolated instructions makes every turn O(N) again.](part-03-context-profiles-agentic/README.md#31--token-budgeting-transcript-anatomy-and-kv-cache-economics) — 3.README 🔇
- [Scope note: linear-attention and hybrid architectures cannot prefix-cache — every turn re-prefills the transcript.](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#what-this-covers) — 3.1
- [Contents entry: architectures that cannot prefix-cache.](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#contents) — 3.1
- [Cache invalidation's only symptom is a longer prefill bar in Instruments — no error, no log line exists.](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#84-taking-the-training-wheels-off) — 3.1 🔇
- [Model switching re-prefills the shared transcript on the new engine — 2.35 s switch-in measured; KV reuse is per-model.](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#89-profile-switching-is-a-deliberate-reset) — 3.1
- [Heading: the model-selection consequence — architectures that cannot prefix-cache.](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#10-️-the-model-selection-consequence-architectures-that-cannot-prefix-cache) — 3.1
- [A conditional above static instructions silently invalidates the cache — TTFT climbs turn over turn, no diagnostic.](part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md#43-the-ordering-rule--static-first-conditional-last) — 3.2 🔇
- [trimKVCache returns -1 whenever SSM state exists — Qwen3.5, LFM2.5, Granite 4 re-prefill every turn, silently.](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#121-the-economics-first) — 3.3
- [Hybrid and linear-attention models refuse the KV trim — every turn re-prefills; the efficiency pick makes chat slower.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#83-what-switching-actually-measured-on-real-hardware) — 3.4

**Part 4**

- [The OS specialises a shipped .aimodel per device before it runs — large models take long; keep it out of user flows.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#45-where-the-bundle-comes-from) — 4.2
- [Prefix KV reuse measured 101x on turn-2 TTFT — but hybrid/SSM models return -1 and silently re-prefill every turn.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#84-the-models-that-quietly-cannot-do-multi-turn-cheaply) — 4.2
- [Heading: linear attention forfeits prefix caching entirely.](part-04-beyond-the-built-in-model/references/04-executor-lifecycle-and-kv-reuse.md#94-️-linear-attention-forfeits-prefix-caching-entirely) — 4.4
- [Hybrid models refuse the trim (-1); the fallback re-prefills — turn-2 TTFT 20x worse and no API reports why.](part-04-beyond-the-built-in-model/references/04-executor-lifecycle-and-kv-reuse.md#94-️-linear-attention-forfeits-prefix-caching-entirely) — 4.4 🔇

**Part 5**

- [Linear-attention/hybrid models forfeit prefix caching and re-prefill each turn; the 101x TTFT gain is attention-only.](part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md#103-the-measurement-loop) — 5.1

## Resource growth

**Part 2**

- [Image attachments leak file descriptors — Python calls fail with Bad file descriptor after ~240-250 sequential requests.](part-02-foundation-models-everyday-api/references/05-image-input-and-attachments.md#113-the-file-descriptor-leak--the-sharpest-image-specific-bug-in-the-corpus) — 2.5 🔇

**Part 4**

- [Heading: reasoning spends your context, invisibly.](part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md#64-️-silent-failure--reasoning-spends-your-context-invisibly) — 4.1
- [Reasoning tokens fill the 32K window while appearing in nothing you render — overflow errors from chats that 'fit'.](part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md#64-️-silent-failure--reasoning-spends-your-context-invisibly) — 4.1 🔇
- [No checkCancellation exists in Apple's executor — a local engine keeps generating after the consumer cancels.](part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md#96-cancellation) — 4.3

**Part 5**

- [TOC: memory across the Python/Swift boundary — fd leaks after ~240 image calls, retained attachments, double-free…](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#contents) — 5.2
- [Native memory and fds cross the Python/Swift boundary — batches leak unless sessions are recreated and releases run.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#13-️-memory-across-the-boundary) — 5.2
- [pip's apple-fm-sdk 0.2.1 still has the image fd leak; the fix landed 2026-07-07 on git main only — install from main.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#132-the-fd-leak-and-why-the-fix-is-not-in-any-release) — 5.2

## Misleading signals

**Part 2**

- [String-mode refusals return as successful Strings, not errors, and poison the transcript for later turns.](part-02-foundation-models-everyday-api/README.md#26--the-complete-failure-taxonomy-availability-errors-guardrails-and-refusals) — 2.README 🔇
- [Assigning transcript.history mid-response compiles clean; the failure erupts as an error from an unrelated await.](part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md#92-the-rule-only-when-isresponding--false) — 2.1 🔇
- [Propagate .emptyTypeChoicesSchema — it catches unloaded .anyOf arrays; Apple's Skills writes try! there, which traps.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#71-generationschema--the-finished-immutable-article) — 2.2
- [Refactor into a file importing only FoundationModels and the break reads like a missing SDK, not a missing import.](part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md#3-the-cross-import-overlay-and-the-two-line-version) — 2.4 🔇
- [spotlight_search never throws on malformed arguments; a code-100 JSON error rides inside the Prompt output, invisible…](part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md#4-the-trajectory-what-actually-happens-on-one-respond) — 2.4
- [contextSizeExceeded throws but never says what filled the window — tool result payloads are the invisible culprit.](part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md#101-the-number-that-decides-your-architecture) — 2.4 🔇
- [A reactive-only design missing the SystemLanguageModel.Error arm mishandles availability failures silently.](part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md#28-proactive-gate-or-reactive-catch--apple-changed-its-mind-quietly) — 2.6
- [Availability failures are SystemLanguageModel.Error, not LanguageModelError — ladders on the latter miss them.](part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md#34-systemlanguagemodelerror--one-case-and-it-is-not-on-watchos) — 2.6
- [Table: in string mode a model-level refusal does not throw — it returns a refusal string as a successful response.](part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md#41-the-architecture-in-apples-words) — 2.6
- [Heading: the refusal that is just a String.](part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md#43-️-silent-failure-the-refusal-that-is-just-a-string) — 2.6
- [Decision table: a 'Sorry, I can't…' String is a silent string-mode refusal — switch to Generable so it throws.](part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md#46-the-decision-table) — 2.6
- [Symptom table: a polite refusal string with no error is a string-mode refusal — use guided generation to make it throw.](part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md#111-symptom--cause--fix) — 2.6

**Part 4**

- [Heading: availability is not a health check.](part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md#54-️-silent-failure--availability-is-not-a-health-check) — 4.1
- [availability == .available says nothing about quota — the most common real failure is invisible to every check.](part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md#54-️-silent-failure--availability-is-not-a-health-check) — 4.1 🔇
- [PCC in the Simulator throws a content-free error that reads as your bug — a known issue per Apple engineering.](part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md#55-️-the-simulator-does-not-run-pcc) — 4.1
- [This executor never throws rateLimited/contextSizeExceeded/timeout — a 429 arrives as generic httpError with raw bytes.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#27-the-errors-you-will-actually-see) — 4.2
- [MLX never emits updateUsage — token usage reads absent or zero by design, a compile-vs-runtime symbol mismatch.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#39-the-mlx-specific-traps) — 4.2 🔇
- [A backend is not obliged to use the typed error vocabulary — and Apple's own executor mostly doesn't.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#64-the-rest-of-the-error-vocabulary) — 4.2
- [Comparison table: MLX may report token usage absent or zero — the deliberate omission documented in §3.9.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#82-the-comparison-that-actually-decides-it) — 4.2
- [Heading: Apple's own executor throws none of the typed LanguageModelError cases.](part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md#113-️-apples-own-executor-throws-none-of-them) — 4.3
- [ChatCompletionsLanguageModel maps nearly everything to RequestError — typed rateLimited/timeout arms never fire.](part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md#113-️-apples-own-executor-throws-none-of-them) — 4.3

**Part 5**

- [Simulator inference runs on the host Mac; an Xcode 27 SDK on macOS 26 manufactures error -1 that looks like your bug.](part-05-prototyping-profiling-non-swift/README.md#51--playground-scheme-simulation-and-reading-a-foundation-models-trace) — 5.README 🔇
- [Simulator inference runs on the host Mac's OS; version-skew errors surface as a bare -1 that reads as your bug.](part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md#26-what-playground-will-not-tell-you--and-the-trap-under-it) — 5.1 🔇
- [One availability branch is contaminated by a confirmed Apple bug — do not design around it.](part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md#42-the-availability-branches-it-lets-you-reach) — 5.1
- [availability returns .appleIntelligenceNotEnabled unless Siri is enabled, even with AI on — Apple-confirmed bug.](part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md#42-the-availability-branches-it-lets-you-reach) — 5.1
- [capabilities claims vision and tool calling on the 27.0 sim where both fail at runtime; it is a declaration, not a…](part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md#134-a-device) — 5.1
- [apple_fm_sdk.__version__ is hardcoded 0.1.0 on a 0.2.1 package; capability checks keyed on it test a constant.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#51-it-is-not-a-python-implementation-of-anything) — 5.2
- [pytest outside the repo root fails on FileNotFoundError for fixtures — it reads like a broken install and is not.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#65-development-install) — 5.2
- [Exceptions raised inside a tool's call() never reach your except block — they are stringified and fed to the model.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#103-️-tool-exceptions-never-reach-your-except-block) — 5.2
- [A tool exception becomes 'Tool error: ...' handed to the model; respond() succeeds and the caller never sees it.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#103-️-tool-exceptions-never-reach-your-except-block) — 5.2 🔇

## Version drift

**Part 2**

- [Beta 5 retyped history from ArraySlice<Transcript.Entry> to Transcript.HistoryView — suffix trims survive, raw-Int…](part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md#91-what-changed) — 2.1
- [Exhaustive Transcript.Entry switches break compiling on the 27 SDK; 'fixing' with default: silently drops new cases.](part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md#121-six-entry-types) — 2.1 🔇
- [The .custom segment case the docs list is not present in the beta 5 interface.](part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md#123-four-segment-types) — 2.1
- [Beta 5 declares exactly three Segment cases — .custom vanished between the 2026-07-29 capture and beta 5.](part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md#123-four-segment-types) — 2.1
- [Version matrix: LanguageModelSession.GenerationError is deprecated in the 27 SDK — the error surface moved.](part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md#version-matrix) — 2.1
- [Which error catch fires depends on the building Xcode — rebuild with 27 and GenerationError arms stop matching.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#34-what-happens-when-a-guide-is-not-supported) — 2.2
- [The iOS 27 metadata: overloads drop includeSchemaInPrompt — the knob moved into ContextOptions.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#91-respond-vs-streamresponse-exactly) — 2.2
- [Exhaustive Transcript.Entry/Segment switches from iOS 26 fail to compile on 27 — .reasoning and .attachment are new.](part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md#51-the-entry-cases) — 2.3 🔇
- [CustomSegment and its protocol are gone from the beta 5 interface; the custom-segment path no longer compiles.](part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md#52-the-four-tool-shaped-types) — 2.3
- [The 27 SDK adds .attachment segments — code with a default: clause silently routes image segments to 'unknown, ignore'.](part-02-foundation-models-everyday-api/references/05-image-input-and-attachments.md#74-the-migration-footgun) — 2.5
- [The retired 8K comment never reproduced; read contextSize because 27 is dynamic and Simulator can return zero.](part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md#22-which-availability-api-answers-which-question) — 2.6
- [The 26.5 GenerationError cases are the before side of the rename — never cite them as the 27 error surface.](part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md#31-the-migration-fact-that-outranks-everything-else-in-this-guide) — 2.6
- [No source change needed — rebuilding with Xcode 27 is what silently flips which error types your catches see.](part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md#31-the-migration-fact-that-outranks-everything-else-in-this-guide) — 2.6

**Part 3**

- [history is Transcript.HistoryView since beta 5 — same element type, its own SubSequence, opaque non-Int Index.](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#1-the-transcript-is-the-context-window) — 3.1
- [Transcript.Entry switches exhaustive on 26 fail to compile on 27 (.reasoning) — add @unknown default deliberately.](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#2-anatomy-six-entry-types-and-what-each-one-costs) — 3.1
- [The overflow error has two live spellings — TN3193's GenerationError name vs the 2026 LanguageModelError name.](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#61-the-error-in-both-spellings) — 3.1 🔇
- [Session-restore labels differ — Origami uses history: on 27, the older sample transcript: on 26; relation unverified.](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#811-restoring-a-session) — 3.1
- [Beta 5 retyped history to Transcript.HistoryView; suffix trims survive, but Int indexing breaks.](part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md#123-the-two-types-are-not-the-same-type) — 3.2
- [Scope note: SkillActivations dropped RandomAccessCollection at beta 3 — shipped docs and snippets still assume it.](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#what-this-covers) — 3.3
- [Contents entry: SkillActivations and the ForEach that stopped compiling.](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#contents) — 3.3
- [Heading: SkillActivations and the ForEach that stopped compiling.](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#15-️-skillactivations-and-the-foreach-that-stopped-compiling) — 3.3
- [Apple documents 4096 as the iOS 27 platform value; a retired unreproduced report claimed 8K — still read contextSize…](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#81-what-each-backend-is-charged-for) — 3.4
- [PCC supportsLocale/supportedLanguages became async throws in beta 5; a sync capability guard no longer compiles.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#86-pccs-operational-gates) — 3.4

**Part 4**

- [Contents entry: the double gate — built against the 26 SDK, MLXFoundationModels compiles to an empty library.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#contents) — 4.2
- [Beta 3 renamed SamplingMode cases (.top→.randomTopK) — beta-1 code stops compiling; topK and seeds throw here.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#26-what-crosses-the-wire-and-what-is-quietly-dropped) — 4.2
- [Heading: the double gate, and the empty library.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#32-️-the-double-gate-and-the-empty-library) — 4.2
- [Built against the 26 SDK, MLXFoundationModels compiles to nothing — errors say 'cannot find', never mentioning SDKs.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#32-️-the-double-gate-and-the-empty-library) — 4.2 🔇
- [Beta 5 confirms six of the seven response actions; updateCustomSegment is not present in the recaptured interface.](part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md#response-actions--responseentryidaction) — 4.3
- [The custom-segment provider path is pre-beta-5 surface; CustomSegment and .updateCustomSegment are absent from beta 5.](part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md#132-custom-segments--the-extension-point-for-new-modalities) — 4.3
- [Beta 3 made .refusal's explanation required — the old Refusal(debugDescription:) example no longer compiles.](part-04-beyond-the-built-in-model/references/04-executor-lifecycle-and-kv-reuse.md#112-throwing-and-throwing-the-right-thing) — 4.4

**Part 5**

- [Stable fm removes beta quota/PCC syntax and exposes seven commands; check deployment-OS help before scripting.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#3--the-fm-help-surface-captured-on-macos-27) — 5.2

## Docs vs reality

**Part 2**

- [Apple's documented nested @Generable example fails macro expansion in Xcode 27 beta 27A5228h; move the nested type to…](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#23-the-canonical-shape) — 2.2
- [Python docstrings leak Swift #/…/# regex delimiters — working tests use bare patterns; do not copy the delimiters.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#35-a-note-on-pattern_) — 2.2
- [Apple's ResponseStream snippet does not compile — unbalanced braces, a stray try!, and an undefined variable.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#93-responsestream-snapshot-and-response) — 2.2
- [LanguageModelSession.Error is in docs and a forum snippet but no shipping sample — keep the arm, distrust its cases.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#111-the-three-error-ladder) — 2.2
- [Apple's article writes GenerationOptions(samplingMode:); Apple's code and the Python SDK write sampling: — unresolved.](part-02-foundation-models-everyday-api/references/05-image-input-and-attachments.md#81-classification-with-greedy-sampling) — 2.5
- [Three names circulate for the availability-testing menu — trust the docs' spelling over transcripts.](part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md#27-testing-availability-without-a-drawer-full-of-devices) — 2.6

**Part 3**

- [Utilities package: the README dependency line resolves to nothing and every composed example it ships is inert.](part-03-context-profiles-agentic/README.md#33--foundation-models-utilities-skills-and-history-transforms) — 3.README 🔇
- [Docs still list four Segment cases; the beta 5 interface declares three — .custom is not present.](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#23-segments-the-second-dimension) — 3.1
- [Session 242 defers to 243 for detecting cache invalidation — 243 never mentions a cache metric; only the docs do.](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#51-the-cache-hit-rate) — 3.1
- [Profile(model:) { } appears in conference write-ups, never in Apple code — the model is applied as a modifier.](part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md#32-the-model-is-a-modifier-not-an-initialiser-label) — 3.2
- [Scope note: the README's '5000 tokens' summarisation trigger doesn't exist — the API threshold counts entries.](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#what-this-covers) — 3.3
- [Contents entry: the '5000 tokens' ghost.](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#contents) — 3.3
- [The README's .package(from:"1.0.0") can never resolve — only prerelease tags exist and from: excludes prereleases.](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#11-the-dependency-line-in-the-readme-does-not-work) — 3.3 🔇
- [Apple's SKILL.md claims summarizeHistory defaults model: — the shipping source has no default; you must pass one.](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#3-the-three-history-modifiers-signature-by-signature) — 3.3
- [Heading: the '5000 tokens' ghost — a README trigger the API cannot express.](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#6-️-the-5000-tokens-ghost) — 3.3
- [The package's modifiers use the lossy session-wide history property that session 242 says not to prefer.](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#the-conflict-stated-plainly) — 3.3
- [README and SKILL.md still claim the conformance beta 3 removed — the shipped ForEach snippet no longer compiles.](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#152-the-conformance-that-was-removed) — 3.3
- [The bundled SKILL.md is stale beta-1 with eight verified wrong claims — agents reading it generate broken code.](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#20-the-skillmd-audit-eight-wrong-claims) — 3.3
- [Evidence note: sessions 242/243 describe both patterns, but no Apple sample implements either with a real tool.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#1-two-patterns-one-question) — 3.4
- [Session 319 and the docs disagree on the quota-simulation menu path and label — prefer the docs, check the other tab.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#86-pccs-operational-gates) — 3.4
- [The package README is out of date — SkillActivations lost RandomAccessCollection; iterate activeSkillNames instead.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#94-when-to-reach-for-it) — 3.4

**Part 4**

- [The PCC article implies any LanguageModel fits the legacy inits — the API types them SystemLanguageModel only.](part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md#42-the-documentation-contradiction-and-how-it-resolves) — 4.1
- [An Apple doc page stacks .reasoningLevel(.deep) with a redundant ContextOptions(reasoningLevel:) — do not copy it.](part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md#63-setting-the-level-two-places) — 4.1
- [Transcript and docs disagree on the quota-simulation scheme page and menu title — the limit-reached option matches.](part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md#8-simulating-quota-states-in-xcode) — 4.1
- [The README dependency line resolves to nothing — only beta tags exist and SwiftPM from: excludes prereleases.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#21-adding-the-package-and-the-dependency-line-that-resolves-to-nothing) — 4.2
- [README's URL 'http://localhost/v1:8000' puts the port in the path — requests actually hit localhost on port 80.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#23-pointing-it-at-a-local-server) — 4.2
- [The README claims Linux support, but the repo has no CI, Dockerfile, or platform matrix — structurally unproven.](part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md#22-should-you-support-linux) — 4.3
- [SKILL.md describes three SwiftPM traits gating features — Package.swift declares none; the claim is fiction.](part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md#23-dependency-weight) — 4.3
- [The prerelease-tag trap: the documented dependency line resolves to nothing — from: excludes beta-only tags.](part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md#25-publishing-your-repo-url-is-the-distribution-channel) — 4.3
- [Session 339's send-metadata-upfront advice breaks tool-calling turns on 27.0 beta — an empty Response entry appears.](part-04-beyond-the-built-in-model/references/04-executor-lifecycle-and-kv-reuse.md#86-report-what-you-reused-honestly) — 4.4 🔇

**Part 5**

- [Menu strings differ between Apple's spoken narration and its written docs — don't pattern-match one exact wording.](part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md#41-the-menu) — 5.1
- [Captions spell the idea tool three ways (GenerateCraftIdeaTool/IdeasTool/generateCraftIdea); the exact name is…](part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md#81-the-feature) — 5.1
- [Session 242 defers cache detection to 243, which never names it; the current written documentation supplies the metric.](part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md#92-the-four-current-token-metrics) — 5.1
- [A community post argues fm serve does not exist from its absence in a transcript; an Apple engineer and a --help paste…](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#26-fm-serve--the-one-written-sentence-and-why-it-matters-most) — 5.2
- [fmx is a third-party macOS 26 look-alike; its slash commands and flags are its own design and read as attested fm…](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#3--the-fm-help-surface-captured-on-macos-27) — 5.2
- [The Python SDK is 26-generation (macOS 26+) though the session is about macOS 27 throughout — expect capability gaps.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#52-️-the-version-discrepancy-this-is-a-26-generation-sdk) — 5.2
- [The SDK runs on macOS 26 but the fm CLI does not exist there — the session presents them as one workflow.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#52-️-the-version-discrepancy-this-is-a-26-generation-sdk) — 5.2
- [The Python SDK lacks PCC, reasoning, and attachments; stable fm no longer supplies the beta PCC route.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#52-️-the-version-discrepancy-this-is-a-26-generation-sdk) — 5.2
- [The docstring's SystemLanguageModel(temperature:top_p:) raises TypeError — sampling lives on GenerationOptions.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#72-the-constructor-use-case-and-guardrails) — 5.2
- [test_composed_prompt_cleanup.py's docstring promises an fd-count regression test; the file has only four mocked unit…](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#136-how-to-know-whether-you-are-leaking) — 5.2

## API footguns

**Part 2**

- [.required has no iteration cap; a tool named in instructions but never registered loops forever with no error.](part-02-foundation-models-everyday-api/README.md#23--the-tool-protocol-calling-modes-and-the-required-mode-loop) — 2.README 🔇
- [Transcript.Response's assetIDs is required yet undocumented — Apple's own code passes an array of one empty string.](part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md#25-seeding-a-session-with-hand-authored-history) — 2.1
- [.required keeps calling tools until you throw from a tool or flip the mode dynamically — there is no default exit.](part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md#105-toolcallingmode-270) — 2.1 🔇
- [GenerationID is stable within one response only — it is not a domain key; matching across responses breaks.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#25-generationid-and-why-you-cannot-use-name-as-an-identity) — 2.2
- [AttachmentLabel output is constrained to be a string, not one of your labels — treat lookup misses as expected.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#27-guided-generation-over-images-attachment--imagereference--attachmentlabel) — 2.2
- [Apple's corrective-string fallback has a reported failure: the model loops re-calling with invalid args — cap retries.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#44-what-apple-recommends-instead) — 2.2
- [streamResponse is neither async nor throwing — schema errors surface later, inside the iteration loop, not at the call.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#91-respond-vs-streamresponse-exactly) — 2.2
- [Python stream_response skips the request lock — a stream and respond() can overlap on one session with no error.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#124-streaming-is-text-only-in-python) — 2.2
- [Contents entry: .required is a while loop and you own the exit.](part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md#contents) — 2.3
- [Contents entry: the tool you named in instructions but never registered.](part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md#contents) — 2.3
- [toolCallingMode is the only non-defaulted param in the 4-arg init — omit it and you get the iOS 26 three-arg overload.](part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md#62-setting-it-without-a-profile-generationoptions) — 2.3
- [Heading: .required is a while loop and you own the exit.](part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md#7-️-required-is-a-while-loop-and-you-own-the-exit) — 2.3
- [Apple verbatim: with required tool calling the model is in a while loop — providing an exit condition is your job.](part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md#7-️-required-is-a-while-loop-and-you-own-the-exit) — 2.3 🔇
- [Profile body is re-evaluated per request — 7 evaluations across 3 turns measured; read state there, never mutate.](part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md#71-exit-a--conditionalise-the-mode-on-state-the-tool-moves) — 2.3
- [Heading: the tool you named but never registered.](part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md#8-️-the-tool-you-named-but-never-registered) — 2.3
- [Instructions naming an unregistered tool loop with no thrown error — WWDC26 session 243 exists to teach the diagnosis.](part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md#8-️-the-tool-you-named-but-never-registered) — 2.3 🔇
- [Corrective strings for bad .anyOf args can wedge the model re-calling with invalid args — bound retries yourself.](part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md#92-throw-or-return-a-corrective-string) — 2.3
- [Throwing from onToolCall stops the whole turn's loop — you cannot reject one tool call and keep the conversation.](part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md#93-ontoolcall-as-an-approval-gate) — 2.3
- [Unrecognised model types default to the JSON tool-call parser — Mistral [TOOL_CALLS] reads as text and no tool runs.](part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md#111-ten-wire-formats-one-abstraction) — 2.3 🔇
- [SpotlightSearchTool is stream and accumulator — built inline in the tools array, no reference exists to read results.](part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md#93-consuming-the-stream) — 2.4 🔇
- [DetectedObject.boundingBox is always top-left; Segment.box flips on macOS — same code, different y per platform.](part-02-foundation-models-everyday-api/references/05-image-input-and-attachments.md#94-the-core-ai-route-real-detection-and-real-segmentation) — 2.5
- [Two box encodings in one repo — detector emits DETR [cx,cy,w,h], segmenter XYXY; check what your export produces.](part-02-foundation-models-everyday-api/references/05-image-input-and-attachments.md#94-the-core-ai-route-real-detection-and-real-segmentation) — 2.5

**Part 3**

- [Profile body ran 7 times across 3 turns — side effects multiply; the unregistered-tool infinite loop also lives here.](part-03-context-profiles-agentic/README.md#32--dynamic-profiles-modifiers-and-session-state) — 3.README 🔇
- [.required never exits by itself — side-effecting tools repeat their work; a call-site options: overrides your loop exit.](part-03-context-profiles-agentic/README.md#34--baton-pass-phone-a-friend-model-routing-and-tool-calling-control) — 3.README 🔇
- [Community count: the DynamicInstructions body ran 7 times across 3 turns — 'each time prompted' understates it.](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#86-the-ordering-rule-for-dynamicinstructions--the-most-actionable-item-in-this-section) — 3.1
- [Heading: the tool named in prose but absent from the toolset.](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#114-️-silent-failure--the-tool-named-in-prose-but-absent-from-the-toolset) — 3.1
- [Heading: the instructions/toolset drift bug.](part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md#44-️-the-instructionstoolset-drift-bug) — 3.2
- [Instructions naming switchToTutorialMode without registering it loop forever with no error — WWDC 243's central bug.](part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md#44-️-the-instructionstoolset-drift-bug) — 3.2 🔇
- [A random seed is best-effort, per Apple's own docs — never assert byte-identical output in a test.](part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md#52-samplingmode) — 3.2
- [.required has no timeout or cap — a never-true exit fills the window and throws contextSizeExceeded many tokens later.](part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md#55-toolcallingmode-on-a-profile) — 3.2 🔇
- [Heading: the body must be pure — it runs more than once per turn.](part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md#62-️-the-body-must-be-pure--it-runs-more-than-once-per-turn) — 3.2
- [Profile body side effects execute an unpredictable number of times — 7 evaluations across 3 turns, community-measured.](part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md#62-️-the-body-must-be-pure--it-runs-more-than-once-per-turn) — 3.2 🔇
- [assetIDs is required, undocumented, and Apple passes an array of one empty string — copy it; the 27 SDK hints at more.](part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md#73-hand-authored-seed-entries) — 3.2
- [A throw from onToolCall aborts the entire turn and rolls the transcript back — no per-call denial exists.](part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md#93-throwing-from-a-lifecycle-callback-aborts-the-turn) — 3.2
- [Surface table: the DynamicProfile/Profile body must never mutate — the §6.2 purity rule.](part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md#115-summary-of-the-surface) — 3.2
- [Surface table: DynamicProfileModifier.body follows the same purity rule — write only inside the hook it installs.](part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md#115-summary-of-the-surface) — 3.2
- [Surface table: DynamicInstructions body must stay pure, and history is read-only there (§12.2).](part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md#115-summary-of-the-surface) — 3.2
- [Heading: history is read-only inside DynamicInstructions and Tool contexts.](part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md#122-️-history-is-read-only-in-two-contexts) — 3.2
- [History is documented read-only inside DynamicInstructions and Tool — what a write there does is an unverified gap.](part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md#122-️-history-is-read-only-in-two-contexts) — 3.2 🔇
- [Heading: the mutable transcript has a dedicated session error.](part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md#144-️-the-mutable-transcript-has-a-dedicated-session-error) — 3.2
- [Mutating the transcript mid-response is caller misuse with a typed error — guard every assignment on isResponding.](part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md#144-️-the-mutable-transcript-has-a-dedicated-session-error) — 3.2
- [Add one skill with allowsDeactivation and the tool renames to toggle_skill — instructions citing activate_skill break.](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#141-the-tool-is-named-toggle_skill-or-activate_skill-and-you-do-not-choose) — 3.3 🔇
- [Prompt skills never register as active — isActive(promptSkillName) is false forever, by deliberate design.](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#143-defer--oncallskill---why-the-verb-reads-backwards) — 3.3 🔇
- [Scope note: .required is an unbounded while loop — Apple documents exactly two exits and you must wire one.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#what-this-covers) — 3.4
- [Contents entry: .required is a while loop and you supply the exit.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#contents) — 3.4
- [Heading: the baton tool you named but never registered.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#27-️-silent-failure--the-baton-tool-you-named-but-never-registered) — 3.4
- [The handoff tool named only in instructions loops forever with no error — session 243 is built around this bug.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#27-️-silent-failure--the-baton-tool-you-named-but-never-registered) — 3.4 🔇
- [toolCallingMode is the only non-defaulted param in the 4-arg init — omitting it selects the iOS 26 overload.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#52-two-places-to-set-it-one-precedence-rule) — 3.4
- [Heading: .required is a while loop and you supply the exit.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#6-️-required-is-a-while-loop-and-you-supply-the-exit) — 3.4
- [Apple verbatim: with required tool calling the model is essentially in a while loop — the exit condition is your job.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#6-️-required-is-a-while-loop-and-you-supply-the-exit) — 3.4 🔇
- [Profile body re-evaluates per request — 7 evaluations in 3 turns measured; read your route variable, never mutate.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#61-exit-a--conditionalise-the-mode-on-a-variable-the-loop-moves) — 3.4

**Part 4**

- [A near-miss prewarm signature compiles but binds the protocol's no-op default — your prewarm is never called.](part-04-beyond-the-built-in-model/README.md#43--authoring-a-languagemodel-provider-package) — 4.README 🔇
- [catch contextSizeExceeded must precede catch LanguageModelError as a type — otherwise the specific arm is dead code.](part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md#92-the-full-catch-ladder) — 4.1
- [The macro expands into your file — miss one of the six required imports and the expansion fails at your call site.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#34-the-macro-path-huggingfacelanguagemodel) — 4.2
- [stopStrings:nil silently falls back to extraEOSTokens — pass [] to truly disable; invisible at the call site.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#35-the-explicit-path-the-real-initializer) — 4.2
- [ModelRegistry aliases LLMRegistry in MLXLLM and VLMRegistry in MLXVLM — import both and the name cannot resolve.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#37-llmregistry-and-picking-a-model-id) — 4.2
- [prewarm has a no-op default witness — an almost-right signature compiles, never runs, and first requests stay slow.](part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md#35-prewarm--and-the-single-worst-footgun-in-the-protocol) — 4.3 🔇
- [Quick reference: prewarm(model:transcript:) defaults to a no-op — your signature must match exactly to be called.](part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md#15-quick-reference) — 4.3
- [Heading: the near-miss signature that binds the default.](part-04-beyond-the-built-in-model/references/04-executor-lifecycle-and-kv-reuse.md#62-️-the-near-miss-signature-that-binds-the-default) — 4.4
- [An almost-right prewarm signature compiles, binds the do-nothing default, and the first response is slow forever.](part-04-beyond-the-built-in-model/references/04-executor-lifecycle-and-kv-reuse.md#62-️-the-near-miss-signature-that-binds-the-default) — 4.4 🔇

**Part 5**

- [includeSchemaInPrompt: false without a one-shot example leaves neither schema nor pattern — structured output degrades.](part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md#91-the-three-from-the-session) — 5.1
- [_stream_response skips the session request lock every respond path takes; a stream and respond() interleave…](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#85-streaming-yields-snapshots-and-only-text) — 5.2
- [GuideType members are camelCase (maxItems) while factories are snake_case (max_items) — an autocomplete trap.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#92-fmguide) — 5.2
- [Tool validation is bare asserts, disabled under python -O — a tool missing description fails later and less legibly.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#105-two-more-sharp-edges) — 5.2
- [ImageAttachment path must be pathlib.Path; a plain str dies on path.is_file() with AttributeError, not a friendly error.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#111-the-prompt-model) — 5.2
- [Prompts expand any non-str iterable: a consumed generator retries as an empty prompt; a dict contributes only its keys.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#112-the-iterable-trap) — 5.2
- [Transcript-loaded tools are historical only; forget to re-pass instances and the replayed session can never call tools.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#124-replaying-a-transcript) — 5.2
- [Manual cleanup of native session resources crashes the interpreter — never call the internal _release() yourself.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#134-️-the-cleanup-that-crashes-the-interpreter) — 5.2
- [session._release() double-frees when GC releases again — EXC_BREAKPOINT/SIGTRAP in libswiftCore.dylib.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#134-️-the-cleanup-that-crashes-the-interpreter) — 5.2
- [except fm.FoundationModelsError misses image failures — PromptError/ImagePromptError subclass plain Exception; catch…](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#14-what-the-python-sdk-cannot-do) — 5.2

## General cautions

**Part 2**

- [Cross-reference: session lifetime ties into §7.3's warning that Instruments traces store prompts unencrypted.](part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md#25-seeding-a-session-with-hand-authored-history) — 2.1
- [Instruments traces store every prompt and response unencrypted — a shared .trace file leaks user text verbatim.](part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md#73-how-much-it-buys) — 2.1 🔇
- [Pointer: the entry payload parameter is undocumented — see the assetIDs callout in §2.5.](part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md#122-entry-payloads) — 2.1
- [GenerationGuide.count has both Int and ClosedRange overloads — both exercised in compiling Apple sample code.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#32-every-guide-with-apples-own-one-liners) — 2.2
- [Where the .anyOf constraint is lost — schema serialisation, grammar compilation, or matcher — remains unresolved.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#54-two-channels-one-api--and-why-anyof-can-fail) — 2.2
- [Heading: do not stream in the background — backgrounded streams invite rateLimited; Apple says use respond(to:).](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#95-️-do-not-stream-in-the-background) — 2.2
- [The 1044→700 token saving is Apple's demo on unspecified hardware — reuse the shape of the claim, not the numbers.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#101-the-measured-effect) — 2.2
- [Heading: three Python-side silent failures, led by options= being dropped when generating= is passed.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#123-️-three-python-side-silent-failures) — 2.2
- [Apple verbatim: recordings capture and store all Foundation Models prompts and responses — guard your traces.](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md#133-debugging-a-structured-output-problem) — 2.2
- [Scope note: covers the OCR/barcode watchOS asymmetry and the attachment label image tools silently require.](part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md#what-this-covers) — 2.3
- [The tool-calling Instruments template records prompts and responses — treat .trace files as user data; never commit.](part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md#84-how-to-spot-it) — 2.3
- [Community-measured: small models emit tool JSON the framework rejects (decodingFailure) — in-tool baton-pass is shaky.](part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md#113-small-models-make-different-mistakes) — 2.3
- [The 27.0 SDK declares exactly four Attachment image inits — CGImage, CIImage, CVPixelBuffer, imageURL; no UIImage.](part-02-foundation-models-everyday-api/references/05-image-input-and-attachments.md#32-what-you-can-hand-it) — 2.5
- [Source note: the coffee/generative-game and SpeechAnalyzer samples surface in searches but are stale iOS 26 evidence.](part-02-foundation-models-everyday-api/references/05-image-input-and-attachments.md#123-sources-in-precedence-order) — 2.5
- [Read-first: most defects here do not throw — string refusals, out-of-band guardrail changes, incomplete catch ladders.](part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md#what-you-need) — 2.6
- [The availability sample is an iOS 26 project — cite it as the 26 baseline only, never as 2026 guidance.](part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md#21-systemlanguagemodelavailability-every-case) — 2.6
- [Evidence note: every symbol in the degradation function is cited upstream; refusal detection is deliberately defensive.](part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md#10-the-complete-graceful-degradation-function) — 2.6
- [Refusal-string detection is a heuristic, not an API — Apple documents only the shape of a refusal.](part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md#104-the-generator-gate-attempt-recover-degrade) — 2.6

**Part 3**

- [Group Labs ship no caption track — cite Apple's written Q&A summary as paraphrase, never as an engineer's words.](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#33--the-on-device-figure-is-4096--settled-by-tn3193) — 3.1
- [Sample logging line: prints a KV cache hit-rate warning so prefix changes show up during development.](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#51-the-cache-hit-rate) — 3.1
- [Scope: trimKVCache(to:) is a community-fork Core AI primitive, not a Foundation Models API you can call.](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#9-what-prefix-reuse-is-worth-measured) — 3.1
- [Attribution: the prefix-reuse numbers are one community Mac run (qwen3-0.6b); exact hardware and build unstated.](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#96-the-numbers) — 3.1
- [Attribution: the cannot-prefix-cache conclusion is one community implementation's finding, not an Apple statement.](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md#103-the-named-list) — 3.1
- [Saved transcripts contain everything typed and generated — debug-gate the writer and treat the files as sensitive.](part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md#75-saving-one-and-the-best-debugging-aid-in-the-corpus) — 3.2
- [Surface table: session.properties has an SDK-verified setter whose runtime semantics remain an open gap.](part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md#115-summary-of-the-surface) — 3.2
- [Read-first: foundation-models-utilities has two commits and only prerelease tags — beta software, not a library.](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#foundation-models-utilities-skills-and-history-transforms) — 3.3
- [.anyOf still can't hard-constrain skill names — Skills defends by throwing ParsingError on unrecognised ones.](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md#144-the-schema-and-what-strictschema-buys-you) — 3.3
- [That .disallowed withholds tool definitions is verified provider behaviour — Apple's own stack is unverified.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#51-the-three-modes) — 3.4
- [PCC quota reports only reached/approaching/below — no percentages or counts; developers asked for more and got none.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#86-pccs-operational-gates) — 3.4
- [Only .string(_) appears as a value wrapper anywhere in the corpus — .number and .bool are unverified gaps.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#102-the-api-as-it-actually-compiles) — 3.4
- [Source note: the coffee/generative-game and SpeechAnalyzer samples are not cited as 2026 evidence — stale iOS 26 era.](part-03-context-profiles-agentic/references/04-agentic-orchestration.md#12-sources) — 3.4

**Part 4**

- [Heading: you cannot build a usage meter.](part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md#76-️-you-cannot-build-a-usage-meter) — 4.1
- [The quota API exposes three coarse states and no numbers — progress bars and request counters cannot be built.](part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md#76-️-you-cannot-build-a-usage-meter) — 4.1
- [Source note: the coffee/generative-game and SpeechAnalyzer samples are excluded as stale iOS 26 evidence.](part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md#151-apple-sample-code-strongest) — 4.1
- [Source note: where transcripts and docs disagree (menu strings, context size), this guide prefers the docs.](part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md#154-wwdc26-transcripts) — 4.1
- [Passing capabilities yourself makes you the author — declare only what the checkpoint honours, or the guard inverts.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#36-capabilities-is-routing-not-documentation) — 4.2
- [additionalHeaders invites hardcoded API keys — session 339's credential warning applies when you hold the key.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#7-the-privacy-obligation) — 4.2
- [Only CoreAI's compiler/executor is OS-resident — the LLM runtime is Swift you compile into the app.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#83-three-things-that-are-true-of-all-three) — 4.2
- [After a backend swap the transcript is re-templated by the new model — reasoning and tool dialects may not survive.](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md#94-switching-backends-inside-one-conversation) — 4.2
- [A custom segment is a compatibility boundary — other executors rightly throw unsupportedTranscriptContent on it.](part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md#132-custom-segments--the-extension-point-for-new-modalities) — 4.3
- [Scope note: two APIs here (trimKVCache, prefixReuseFeedsFullSequence) are community-fork additions, not Apple's.](part-04-beyond-the-built-in-model/references/04-executor-lifecycle-and-kv-reuse.md#executor-lifecycle-configuration-identity-and-preserving-work-across-calls) — 4.4
- [Heading: unresolved conflict — whether Apple's own Core AI adapter shares the prewarm near-miss bug.](part-04-beyond-the-built-in-model/references/04-executor-lifecycle-and-kv-reuse.md#63-️-conflict-does-apples-own-core-ai-adapter-have-this-bug) — 4.4
- [Read-first: trimKVCache(to:) and prefixReuseFeedsFullSequence come from a community fork patch, not Apple.](part-04-beyond-the-built-in-model/references/04-executor-lifecycle-and-kv-reuse.md#9-below-the-diff-rewinding-a-kv-cache-is-one-integer) — 4.4

**Part 5**

- [The instrument's trace file is a sensitive artefact: it captures prompt and response data in the clear.](part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md#what-this-covers) — 5.1
- [No one here ran Xcode 27 Instruments; UI claims trace to the session or preserved direct Apple documentation.](part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md#what-you-need) — 5.1
- [The code-along targets macOS Tahoe/Xcode 26 — treat its Playground UI details as 'at least true in 26', not 27.](part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md#21-the-macro-the-canvas-and-the-refresh-button) — 5.1
- [LanguageModelFeedback attachments carry the full session transcript — consent, no auto-upload, scrub before sharing.](part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md#31-the-programmatic-path-languagemodelfeedback) — 5.1
- [Recording a trace turns FM logging on; read the Record Anyway dialog before clicking.](part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md#52-️-the-record-anyway-dialog--read-this-before-you-click) — 5.1
- [Starting a trace enables prompt/response capture in the clear for the recording — get consent and scrub before sharing.](part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md#52-️-the-record-anyway-dialog--read-this-before-you-click) — 5.1
- [The transcript-recorder JSON files contain the full transcript — apply the same consent and scrubbing rules before…](part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md#131-a-transcript-recorder) — 5.1
- [The coffee-game and SpeechAnalyzer samples are iOS 26-era harvests — do not read them as evidence of 27 behaviour.](part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md#16-sources) — 5.1
- [Evidence in this guide is the weakest of Parts 1-6 — read the provenance warning before trusting details.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#️-read-this-before-you-read-anything-else-the-evidence-here-is-the-weakest-in-parts-16) — 5.2
- [The Swift/Python parity fixtures differ (Int .range vs prose-bounded nested type) — parity is schema-level only.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#99-the-parity-fixtures-the-best-translation-reference-that-exists) — 5.2
- [Transcripts are user words: exporting them off-device is a data-collection decision — consent, redaction, retention.](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#125-what-this-workflow-is-good-for) — 5.2
- [Symptom-to-cause table of the SDK's non-throwing failures: dropped options, failed seed casts, ignored guides, hung…](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#162-️-it-does-not-throw--the-expensive-ones) — 5.2

---

🔇 = the guide marks this as an explicit **SILENT FAILURE** callout.
