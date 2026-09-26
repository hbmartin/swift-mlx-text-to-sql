# Section maps for the deep reference guides

The deep guides are bundled with this skill. Each entry links the local file, then lists every **top-level** (`##`) section as an anchor; a guide's own `## Contents` lists its subsections. Open the narrowest relevant section first.

> Generated 2026-09-22 from the guide headings. Regenerate with `./scripts/build-skills.sh` rather than editing by hand.

## Part 2 — Foundation Models: the everyday API

### 2.1 — `LanguageModelSession` end to end

The foundational guide: every initializer form, `Instructions`/`Prompt` and their result builders, the 24-method `respond`/`streamResponse` matrix, `prewarm(promptPrefix:)`, `isResponding`, the now-mutable `transcript`, all of `GenerationOptions`, `Response.usage`, and the six-case `Transcript` data model.

**Local reference:** [part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md](part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| Version floor | `#version-floor` |
| What you need | `#what-you-need` |
| Evidence markers used here | `#evidence-markers-used-here` |
| Contents | `#contents` |
| 1. One session, many backends | `#1-one-session-many-backends` |
| 2. Creating a session: every initializer form | `#2-creating-a-session-every-initializer-form` |
| 3. Instructions vs prompts is a security boundary | `#3-instructions-vs-prompts-is-a-security-boundary` |
| 4. `Instructions`, `Prompt`, and the two result builders | `#4-instructions-prompt-and-the-two-result-builders` |
| 5. `respond(to:)` and the overload matrix | `#5-respondto-and-the-overload-matrix` |
| 6. Streaming: `streamResponse` and snapshots | `#6-streaming-streamresponse-and-snapshots` |
| 7. `prewarm(promptPrefix:)` | `#7-prewarmpromptprefix` |
| 8. `isResponding` and the one-request-at-a-time contract | `#8-isresponding-and-the-one-request-at-a-time-contract` |
| 9. The mutable transcript (27.0) | `#9-the-mutable-transcript-270` |
| 10. `GenerationOptions` in full | `#10-generationoptions-in-full` |
| 11. `Response`, `Snapshot`, and `usage` | `#11-response-snapshot-and-usage` |
| 12. The `Transcript` data model | `#12-the-transcript-data-model` |
| 13. A complete SwiftUI example with cancellation | `#13-a-complete-swiftui-example-with-cancellation` |
| 14. Errors: the three-type taxonomy | `#14-errors-the-three-type-taxonomy` |
| 15. Consolidated gaps | `#15-consolidated-gaps` |
| Quick reference | `#quick-reference` |

### 2.2 — Guided generation and snapshot streaming

What the `@Generable` macro synthesises, every `@Guide` form with evidence, the guide-to-type compatibility matrix, runtime schemas, `GeneratedContent`, and why streaming gives you *snapshots* rather than deltas (you assign, never append).

**Local reference:** [part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md](part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md)

| Section | Anchor |
|---|---|
| Contents | `#contents` |
| 1. The claim, precisely stated | `#1-the-claim-precisely-stated` |
| 2. `@Generable`: what the macro synthesises | `#2-generable-what-the-macro-synthesises` |
| 3. `@Guide`: the complete catalogue | `#3-guide-the-complete-catalogue` |
| 4. ⚠️ `.anyOf` does not constrain generation | `#4-️-anyof-does-not-constrain-generation` |
| 5. How guided generation is actually enforced: constrained decoding | `#5-how-guided-generation-is-actually-enforced-constrained-decoding` |
| 6. ⚠️ The logits problem: when your fastest backend loses guided generation | `#6-️-the-logits-problem-when-your-fastest-backend-loses-guided-generation` |
| 7. `GenerationSchema` and `DynamicGenerationSchema` | `#7-generationschema-and-dynamicgenerationschema` |
| 8. `GeneratedContent`: the untyped door | `#8-generatedcontent-the-untyped-door` |
| 9. Snapshot streaming | `#9-snapshot-streaming` |
| 10. Token economics: `includeSchemaInPrompt` | `#10-token-economics-includeschemainprompt` |
| 11. Failure taxonomy for structured output | `#11-failure-taxonomy-for-structured-output` |
| 12. The Python SDK's parallel surface | `#12-the-python-sdks-parallel-surface` |
| 13. Checklists and decision tables | `#13-checklists-and-decision-tables` |
| 14. Open gaps | `#14-open-gaps` |
| See also | `#see-also` |

### 2.3 — The `Tool` protocol, calling modes, and the required-mode loop

`Tool` member by member; the `@Generable` arguments struct as the contract between model and tool (and why Apple's own evaluation sample makes every argument optional); writing descriptions that say *when* rather than *what*; the six-entry anatomy of one tool-using turn; `toolCallingMode` in both places it can be set, with the precedence rule; transcript rollback on a thrown tool error and `TranscriptErrorHandlingPolicy`.

**Local reference:** [part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md](part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. The loop, in Apple's own words | `#1-the-loop-in-apples-own-words` |
| 2. The `Tool` protocol, member by member | `#2-the-tool-protocol-member-by-member` |
| 3. The arguments struct is the contract | `#3-the-arguments-struct-is-the-contract` |
| 4. Descriptions the model will honour | `#4-descriptions-the-model-will-honour` |
| 5. What a tool call looks like in the transcript | `#5-what-a-tool-call-looks-like-in-the-transcript` |
| 6. `toolCallingMode`: three modes, two places to set it | `#6-toolcallingmode-three-modes-two-places-to-set-it` |
| 7. ⚠️ `.required` is a `while` loop and you own the exit | `#7-️-required-is-a-while-loop-and-you-own-the-exit` |
| 8. ⚠️ The tool you named but never registered | `#8-️-the-tool-you-named-but-never-registered` |
| 9. Errors, rollback, consent, and the `onToolCall` chokepoint | `#9-errors-rollback-consent-and-the-ontoolcall-chokepoint` |
| 10. Built-in system tools: `OCRTool` and `BarcodeReaderTool` | `#10-built-in-system-tools-ocrtool-and-barcodereadertool` |
| 11. Tool calling is a per-model property | `#11-tool-calling-is-a-per-model-property` |
| 12. Testing tools | `#12-testing-tools` |
| 13. Quick reference | `#13-quick-reference` |
| 14. Sources | `#14-sources` |

### 2.4 — Local RAG with `SpotlightSearchTool`, plus OCR and barcodes

Apple's answer to "RAG on device without a vector database": the model writes and executes queries against your own Core Spotlight index.

**Local reference:** [part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md](part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md)

| Section | Anchor |
|---|---|
| Citation convention used in this guide | `#citation-convention-used-in-this-guide` |
| Contents | `#contents` |
| 1. What the tool actually is, and what it replaces | `#1-what-the-tool-actually-is-and-what-it-replaces` |
| 2. The prerequisite nobody can skip: donating content | `#2-the-prerequisite-nobody-can-skip-donating-content` |
| 3. The cross-import overlay, and the two-line version | `#3-the-cross-import-overlay-and-the-two-line-version` |
| 4. The trajectory: what actually happens on one `respond` | `#4-the-trajectory-what-actually-happens-on-one-respond` |
| 5. `Configuration`: sources, guide, and the two members Apple never uses | `#5-configuration-sources-guide-and-the-two-members-apple-never-uses` |
| 6. ⚠️ The metadata gap — the defect that will burn you | `#6-️-the-metadata-gap--the-defect-that-will-burn-you` |
| 7. `searchableItems(forIdentifiers:searchableItemsHandler:)` — the intended fix, and the conflict | `#7-searchableitemsforidentifierssearchableitemshandler--the-intended-fix-and-the-conflict` |
| 8. The retrieve-then-hydrate pattern that works today | `#8-the-retrieve-then-hydrate-pattern-that-works-today` |
| 9. Consuming results: two channels, `searchResults`, and `queryToken` | `#9-consuming-results-two-channels-searchresults-and-querytoken` |
| 10. Guidance: `.focused()`, `.complete`, `GuidanceProfile`, and the token gate | `#10-guidance-focused-complete-guidanceprofile-and-the-token-gate` |
| 11. Reference resolution and the contact resolver | `#11-reference-resolution-and-the-contact-resolver` |
| 12. Custom pipeline stages | `#12-custom-pipeline-stages` |
| 13. Custom attributes, `IndexedEntity`, and dynamic guidance | `#13-custom-attributes-indexedentity-and-dynamic-guidance` |
| 14. Three documented failure modes | `#14-three-documented-failure-modes` |
| 15. Running the tool behind a non-Apple model | `#15-running-the-tool-behind-a-non-apple-model` |
| 16. Evaluating a Spotlight-grounded feature | `#16-evaluating-a-spotlight-grounded-feature` |
| 17. `OCRTool` and `BarcodeReaderTool` | `#17-ocrtool-and-barcodereadertool` |
| 18. Adoption checklist and the gap index | `#18-adoption-checklist-and-the-gap-index` |

### 2.5 — Image input, and what the model cannot do with pixels

`Attachment` and every source it accepts, the `orientation:` parameter, labels and `ImageReference` for keying structured output back to specific images, the transcript types images become, and which backends accept images at all.

**Local reference:** [part-02-foundation-models-everyday-api/references/05-image-input-and-attachments.md](part-02-foundation-models-everyday-api/references/05-image-input-and-attachments.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| Version floor | `#version-floor` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. The symbol inventory, and where each one came from | `#1-the-symbol-inventory-and-where-each-one-came-from` |
| 2. The five-minute version | `#2-the-five-minute-version` |
| 3. `Attachment` in depth: initializers, sources, and one API-spelling conflict | `#3-attachment-in-depth-initializers-sources-and-one-api-spelling-conflict` |
| 4. Any size, any aspect ratio — and what that costs you | `#4-any-size-any-aspect-ratio--and-what-that-costs-you` |
| 5. Orientation is your problem | `#5-orientation-is-your-problem` |
| 6. Labels and `ImageReference`: keying output back to inputs | `#6-labels-and-imagereference-keying-output-back-to-inputs` |
| 7. The transcript side: `AttachmentSegment`, `ImageAttachment`, and the cost of remembering | `#7-the-transcript-side-attachmentsegment-imageattachment-and-the-cost-of-remembering` |
| 8. Structured output from images, and the two Vision-backed tools | `#8-structured-output-from-images-and-the-two-vision-backed-tools` |
| 9. What the model cannot do with pixels | `#9-what-the-model-cannot-do-with-pixels` |
| 10. Which backends accept images | `#10-which-backends-accept-images` |
| 11. Python, and the `fm` CLI | `#11-python-and-the-fm-cli` |
| 12. Gotcha table, open gaps, and sources | `#12-gotcha-table-open-gaps-and-sources` |

### 2.6 — The complete failure taxonomy: availability, errors, guardrails and refusals

The largest guide in the part, organised as symptom → cause → fix across five failure planes.

**Local reference:** [part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md](part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. The five planes a request can fail on | `#1-the-five-planes-a-request-can-fail-on` |
| 2. Availability — the gate before the gate | `#2-availability--the-gate-before-the-gate` |
| 3. The 2026 error reshuffle: four enums where there was one | `#3-the-2026-error-reshuffle-four-enums-where-there-was-one` |
| 4. The two refusal mechanisms | `#4-the-two-refusal-mechanisms` |
| 5. Guardrail configuration and its blind spot | `#5-guardrail-configuration-and-its-blind-spot` |
| 6. Context-window overflow | `#6-context-window-overflow` |
| 7. Errors seen in the wild that are in no enum | `#7-errors-seen-in-the-wild-that-are-in-no-enum` |
| 8. Private Cloud Compute: quota is not availability | `#8-private-cloud-compute-quota-is-not-availability` |
| 9. How to report a bug to Apple so it gets acted on | `#9-how-to-report-a-bug-to-apple-so-it-gets-acted-on` |
| 10. The complete graceful-degradation function | `#10-the-complete-graceful-degradation-function` |
| 11. Quick-reference tables | `#11-quick-reference-tables` |
| Where to go next | `#where-to-go-next` |

## Part 3 — Context, profiles, and agentic sessions

### 3.1 — Token budgeting, transcript anatomy, and KV-cache economics

The conceptual spine: the six `Transcript.Entry` cases and what each costs, `contextSize` and `tokenCount(for:)`, `Usage` and the cache-hit rate, overflow recovery in both the 26.0 and 27.0 idioms, and then the KV material — token layout, the blast-radius table, the ordering rule for `DynamicInstructions`, stateless shape-preserving transforms, and why you batch one big consolidation instead of trimming every turn.

**Local reference:** [part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md](part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. The transcript *is* the context window | `#1-the-transcript-is-the-context-window` |
| 2. Anatomy: six entry types and what each one costs | `#2-anatomy-six-entry-types-and-what-each-one-costs` |
| 3. Reading the budget: `contextSize` and the 4096-token window | `#3-reading-the-budget-contextsize-and-the-4096-token-window` |
| 4. Counting before you spend: `tokenCount(for:)` | `#4-counting-before-you-spend-tokencountfor` |
| 5. Counting after you spend: `Usage` and the cache-hit rate | `#5-counting-after-you-spend-usage-and-the-cache-hit-rate` |
| 6. Overflow: `.contextSizeExceeded` and the pattern people hand-rolled | `#6-overflow-contextsizeexceeded-and-the-pattern-people-hand-rolled` |
| 7. Reclaiming context: four levers, and Apple's shipped modifiers | `#7-reclaiming-context-four-levers-and-apples-shipped-modifiers` |
| 8. The KV cache is a prefix | `#8-the-kv-cache-is-a-prefix` |
| 9. What prefix reuse is worth, measured | `#9-what-prefix-reuse-is-worth-measured` |
| 10. ⚠️ The model-selection consequence: architectures that cannot prefix-cache | `#10-️-the-model-selection-consequence-architectures-that-cannot-prefix-cache` |
| 11. The accuracy hazard: rewriting history confuses the model | `#11-the-accuracy-hazard-rewriting-history-confuses-the-model` |
| 12. Putting it together: a context budget you can defend | `#12-putting-it-together-a-context-budget-you-can-defend` |
| 13. Quick reference | `#13-quick-reference` |
| 14. Sources, and where they disagree | `#14-sources-and-where-they-disagree` |

### 3.2 — Dynamic Profiles, modifiers, and session state

The flagship 2026 API, built around the projection framing above.

**Local reference:** [part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md](part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. The problem profiles solve | `#1-the-problem-profiles-solve` |
| 2. The framing: a profile is a projection of app state | `#2-the-framing-a-profile-is-a-projection-of-app-state` |
| 3. The three layers, and how to spell them | `#3-the-three-layers-and-how-to-spell-them` |
| 4. `DynamicInstructions`: composition that concatenates | `#4-dynamicinstructions-composition-that-concatenates` |
| 5. `Profile` and the modifier catalogue | `#5-profile-and-the-modifier-catalogue` |
| 6. The `body` contract: re-evaluated, pure, singular | `#6-the-body-contract-re-evaluated-pure-singular` |
| 7. Attaching a profile to a session | `#7-attaching-a-profile-to-a-session` |
| 8. Precedence: three tiers for values, accumulation for callbacks | `#8-precedence-three-tiers-for-values-accumulation-for-callbacks` |
| 9. Lifecycle modifiers | `#9-lifecycle-modifiers` |
| 10. Custom modifiers with `DynamicProfileModifier` | `#10-custom-modifiers-with-dynamicprofilemodifier` |
| 11. Session properties | `#11-session-properties` |
| 12. `history` versus `historyTransform` | `#12-history-versus-historytransform` |
| 13. Apple's shipped history modifiers, and their sharp edges | `#13-apples-shipped-history-modifiers-and-their-sharp-edges` |
| 14. `transcriptErrorHandlingPolicy` and the mutable transcript | `#14-transcripterrorhandlingpolicy-and-the-mutable-transcript` |
| 15. A complete worked profile | `#15-a-complete-worked-profile` |
| 16. Quick reference | `#16-quick-reference` |
| 17. Sources | `#17-sources` |

### 3.3 — `foundation-models-utilities`: Skills and history transforms

An audit of Apple's separately-versioned experimental package — two commits, issues disabled, no CI — and the two feature areas that change how you think about a transcript.

**Local reference:** [part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md](part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. The package, honestly: how to depend on something with two commits | `#1-the-package-honestly-how-to-depend-on-something-with-two-commits` |
| 2. The nine public symbols | `#2-the-nine-public-symbols` |
| 3. The three history modifiers, signature by signature | `#3-the-three-history-modifiers-signature-by-signature` |
| 4. Application order: written inside-out, executed outside-in | `#4-application-order-written-inside-out-executed-outside-in` |
| 5. ⚠️ Every composed example in the repository is inert | `#5-️-every-composed-example-in-the-repository-is-inert` |
| 6. ⚠️ The "5000 tokens" ghost | `#6-️-the-5000-tokens-ghost` |
| 7. ⚠️ `rollingWindow` splits prompt/response pairs — and Apple knows | `#7-️-rollingwindow-splits-promptresponse-pairs--and-apple-knows` |
| 8. What these modifiers actually mutate — and why it matters | `#8-what-these-modifiers-actually-mutate--and-why-it-matters` |
| 9. Writing your own history modifier | `#9-writing-your-own-history-modifier` |
| 10. What the summarizer actually reads: `TranscriptRendering` | `#10-what-the-summarizer-actually-reads-transcriptrendering` |
| 11. Skills: the API surface | `#11-skills-the-api-surface` |
| 12. The mechanism: one line of source decides the KV cache | `#12-the-mechanism-one-line-of-source-decides-the-kv-cache` |
| 13. The three transcript shapes | `#13-the-three-transcript-shapes` |
| 14. The synthesized tool: naming, schema, descriptions, and an inverted verb | `#14-the-synthesized-tool-naming-schema-descriptions-and-an-inverted-verb` |
| 15. ⚠️ `SkillActivations` and the `ForEach` that stopped compiling | `#15-️-skillactivations-and-the-foreach-that-stopped-compiling` |
| 16. Skills that carry tools | `#16-skills-that-carry-tools` |
| 17. Choosing: prompt skill, instructions skill, or neither | `#17-choosing-prompt-skill-instructions-skill-or-neither` |
| 18. A complete worked example | `#18-a-complete-worked-example` |
| 19. `ChatCompletionsLanguageModel`, briefly | `#19-chatcompletionslanguagemodel-briefly` |
| 20. The `SKILL.md` audit: eight wrong claims | `#20-the-skillmd-audit-eight-wrong-claims` |
| 21. Quick reference | `#21-quick-reference` |
| 22. Sources | `#22-sources` |

### 3.4 — Baton-pass, phone-a-friend, model routing, and tool-calling control

Apple named two orchestration patterns — collaboration versus consultation — and then shipped a sample that uses neither literally, so this guide separates the verified narration from the reconstructed code and says which is which at every listing.

**Local reference:** [part-03-context-profiles-agentic/references/04-agentic-orchestration.md](part-03-context-profiles-agentic/references/04-agentic-orchestration.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. Two patterns, one question | `#1-two-patterns-one-question` |
| 2. Baton-pass | `#2-baton-pass` |
| 3. Phone-a-friend | `#3-phone-a-friend` |
| 4. Choosing: shared context versus isolation | `#4-choosing-shared-context-versus-isolation` |
| 5. Tool-calling mode as an orchestration control | `#5-tool-calling-mode-as-an-orchestration-control` |
| 6. ⚠️ `.required` is a `while` loop and you supply the exit | `#6-️-required-is-a-while-loop-and-you-supply-the-exit` |
| 7. Tool-as-consent-request: Apple's Origami pattern | `#7-tool-as-consent-request-apples-origami-pattern` |
| 8. Model routing economics | `#8-model-routing-economics` |
| 9. `Skills`: the third option | `#9-skills-the-third-option` |
| 10. Evaluating agentic behaviour | `#10-evaluating-agentic-behaviour` |
| 11. Quick reference | `#11-quick-reference` |
| 12. Sources | `#12-sources` |

## Part 4 — Beyond the built-in model

### 4.1 — Private Cloud Compute: eligibility, reasoning, and quota UX

Apple's server model behind a one-line swap: 32K context, three reasoning levels, no API keys, no token cost to you, and Foundation Models on watchOS for the first time *because* the inference is remote.

**Local reference:** [part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md](part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. Eligibility: three conditions, not one | `#1-eligibility-three-conditions-not-one` |
| 2. The entitlement | `#2-the-entitlement` |
| 3. What you get, and what it costs | `#3-what-you-get-and-what-it-costs` |
| 4. The one-line swap | `#4-the-one-line-swap` |
| 5. Availability is three questions, not one | `#5-availability-is-three-questions-not-one` |
| 6. Reasoning | `#6-reasoning` |
| 7. Quota UX — Apple's most prescriptive design guidance | `#7-quota-ux--apples-most-prescriptive-design-guidance` |
| 8. Simulating quota states in Xcode | `#8-simulating-quota-states-in-xcode` |
| 9. Errors | `#9-errors` |
| 10. Context: 32K, and the cost of coming back down | `#10-context-32k-and-the-cost-of-coming-back-down` |
| 11. Generable, tools, and evaluating before you commit | `#11-generable-tools-and-evaluating-before-you-commit` |
| 12. If you are not eligible | `#12-if-you-are-not-eligible` |
| 13. Declared gaps | `#13-declared-gaps` |
| 14. Quick reference | `#14-quick-reference` |
| 15. Sources | `#15-sources` |

### 4.2 — Core AI, MLX, and any OpenAI-compatible server behind `LanguageModelSession`

The consumer side of bringing your own model, with real initializers rather than demo lines.

**Local reference:** [part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md](part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. What "behind the session" actually means | `#1-what-behind-the-session-actually-means` |
| 2. Path 1 — any OpenAI-compatible server, today | `#2-path-1--any-openai-compatible-server-today` |
| 3. Path 2 — `MLXLanguageModel`, and where `MLXFoundationModels` actually is | `#3-path-2--mlxlanguagemodel-and-where-mlxfoundationmodels-actually-is` |
| 4. Path 3 — `CoreAILanguageModel`, one line to a bundle | `#4-path-3--coreailanguagemodel-one-line-to-a-bundle` |
| 5. ⚠️ The logits constraint: why the fastest backend loses `@Generable` | `#5-️-the-logits-constraint-why-the-fastest-backend-loses-generable` |
| 6. Capabilities, and the errors the framework throws for you | `#6-capabilities-and-the-errors-the-framework-throws-for-you` |
| 7. The privacy obligation | `#7-the-privacy-obligation` |
| 8. Choosing, concretely | `#8-choosing-concretely` |
| 9. Making the backend swappable in real app code | `#9-making-the-backend-swappable-in-real-app-code` |
| 10. Quick reference | `#10-quick-reference` |
| 11. Sources, and where they disagree | `#11-sources-and-where-they-disagree` |

### 4.3 — Authoring a `LanguageModel` provider package

The best-evidenced deep topic in the series, because Apple ships an **815-line agent skill** on exactly this question plus **two complete worked conformances you can read line by line**.

**Local reference:** [part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md](part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. What you are actually building | `#1-what-you-are-actually-building` |
| 2. Step 1 — Packaging | `#2-step-1--packaging` |
| 3. Step 2 — The two protocols, verbatim | `#3-step-2--the-two-protocols-verbatim` |
| 4. The minimum viable conformance — 40 lines, Apple's own | `#4-the-minimum-viable-conformance--40-lines-apples-own` |
| 5. Capabilities: four flags that route requests | `#5-capabilities-four-flags-that-route-requests` |
| 6. Reading a request: all seven fields | `#6-reading-a-request-all-seven-fields` |
| 7. `ContextOptions` vs `GenerationOptions` — the split that matters | `#7-contextoptions-vs-generationoptions--the-split-that-matters` |
| 8. Transcript translation: six entries in, your roles out | `#8-transcript-translation-six-entries-in-your-roles-out` |
| 9. The generation channel: what flows out | `#9-the-generation-channel-what-flows-out` |
| 10. The prescribed event order — and why not to follow it literally | `#10-the-prescribed-event-order--and-why-not-to-follow-it-literally` |
| 11. Errors: approximate or throw | `#11-errors-approximate-or-throw` |
| 12. Step 3 — Authentication | `#12-step-3--authentication` |
| 13. Step 4 — Customization | `#13-step-4--customization` |
| 14. Testing a provider package | `#14-testing-a-provider-package` |
| 15. Quick reference | `#15-quick-reference` |
| 16. Sources and evidence ledger | `#16-sources-and-evidence-ledger` |

### 4.4 — Executor lifecycle, configuration identity, and preserving work across calls

The mechanics that decide whether a provider is fast or slow and — more often than expected — whether it is *correct*.

**Local reference:** [part-04-beyond-the-built-in-model/references/04-executor-lifecycle-and-kv-reuse.md](part-04-beyond-the-built-in-model/references/04-executor-lifecycle-and-kv-reuse.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. The store: one per session, keyed by `Configuration` | `#1-the-store-one-per-session-keyed-by-configuration` |
| 2. What belongs in a `Configuration` | `#2-what-belongs-in-a-configuration` |
| 3. ⚠️ The `urlSession` that isn't in the key | `#3-️-the-urlsession-that-isnt-in-the-key` |
| 4. How load-bearing `Hashable` is: the deleted type-eraser | `#4-how-load-bearing-hashable-is-the-deleted-type-eraser` |
| 5. Teardown you don't write — and two ways to opt out | `#5-teardown-you-dont-write--and-two-ways-to-opt-out` |
| 6. `prewarm` is not guaranteed to run | `#6-prewarm-is-not-guaranteed-to-run` |
| 7. What arrives on every call, and what it costs | `#7-what-arrives-on-every-call-and-what-it-costs` |
| 8. Transcript diffing | `#8-transcript-diffing` |
| 9. Below the diff: rewinding a KV cache is one integer | `#9-below-the-diff-rewinding-a-kv-cache-is-one-integer` |
| 10. A worked executor skeleton | `#10-a-worked-executor-skeleton` |
| 11. Approximate or throw | `#11-approximate-or-throw` |
| 12. Checklist | `#12-checklist` |
| 13. Sources, and where they disagree | `#13-sources-and-where-they-disagree` |

## Part 5 — Prototyping, profiling, and non-Swift access

### 5.1 — `#Playground`, scheme simulation, and reading a Foundation Models trace

Three tools used in a fixed order.

**Local reference:** [part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md](part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. Three properties that break normal debugging | `#1-three-properties-that-break-normal-debugging` |
| 2. `#Playground`: the inner loop | `#2-playground-the-inner-loop` |
| 3. `#Playground` is also the bug-reporting channel | `#3-playground-is-also-the-bug-reporting-channel` |
| 4. Scheme simulation: reaching states you cannot otherwise reach | `#4-scheme-simulation-reaching-states-you-cannot-otherwise-reach` |
| 5. Launching the Foundation Models instrument | `#5-launching-the-foundation-models-instrument` |
| 6. Anatomy of a trace, part 1: the lanes | `#6-anatomy-of-a-trace-part-1-the-lanes` |
| 7. Anatomy of a trace, part 2: the tree detail view | `#7-anatomy-of-a-trace-part-2-the-tree-detail-view` |
| 8. ⚠️ The canonical worked bug: a tool named in prose, missing from the toolset | `#8-️-the-canonical-worked-bug-a-tool-named-in-prose-missing-from-the-toolset` |
| 9. Duration and token metrics | `#9-duration-and-token-metrics` |
| 10. Detecting KV-cache invalidation | `#10-detecting-kv-cache-invalidation` |
| 11. What changed between the 2025 and 2026 instrument | `#11-what-changed-between-the-2025-and-2026-instrument` |
| 12. The whole loop, in order | `#12-the-whole-loop-in-order` |
| 13. Things the instrument does not replace | `#13-things-the-instrument-does-not-replace` |
| 14. Quick reference | `#14-quick-reference` |
| 15. Declared gaps | `#15-declared-gaps` |
| 16. Sources | `#16-sources` |

### 5.2 — The `fm` CLI and the Foundation Models SDK for Python

Two products, two floors, and — unusually — two opposite evidence classes, which the guide flags in its own opening.

**Local reference:** [part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md](part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md)

| Section | Anchor |
|---|---|
| ⚠️ Read this before you read anything else: the evidence here is the weakest in Parts 1–6 | `#️-read-this-before-you-read-anything-else-the-evidence-here-is-the-weakest-in-parts-16` |
| What this covers | `#what-this-covers` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. Why these two tools exist at all | `#1-why-these-two-tools-exist-at-all` |
| 2. The `fm` CLI: everything that is actually attested | `#2-the-fm-cli-everything-that-is-actually-attested` |
| 3. ✅ The `fm` help surface, captured on macOS 27 | `#3--the-fm-help-surface-captured-on-macos-27` |
| 4. The shell-automation pattern (attested) with unverified flags (marked) | `#4-the-shell-automation-pattern-attested-with-unverified-flags-marked` |
| 5. The Python SDK: what it is, and the version discrepancy | `#5-the-python-sdk-what-it-is-and-the-version-discrepancy` |
| 6. Installing it, and why `pip install` compiles Swift | `#6-installing-it-and-why-pip-install-compiles-swift` |
| 7. The model object: availability, context size, token counting | `#7-the-model-object-availability-context-size-token-counting` |
| 8. Sessions, `respond()`, and streaming | `#8-sessions-respond-and-streaming` |
| 9. Guided generation: `@fm.generable`, `fm.guide`, and raw JSON Schema | `#9-guided-generation-fmgenerable-fmguide-and-raw-json-schema` |
| 10. Tools in Python | `#10-tools-in-python` |
| 11. Image attachments | `#11-image-attachments` |
| 12. The cross-language workflow: Swift transcripts into Python | `#12-the-cross-language-workflow-swift-transcripts-into-python` |
| 13. ⚠️ Memory across the boundary | `#13-️-memory-across-the-boundary` |
| 14. What the Python SDK cannot do | `#14-what-the-python-sdk-cannot-do` |
| 15. The evaluation pipeline (session 334's case study) | `#15-the-evaluation-pipeline-session-334s-case-study` |
| 16. Failure-mode index | `#16-failure-mode-index` |
| 17. Quick reference | `#17-quick-reference` |
| 18. Sources, and how to close the gaps yourself | `#18-sources-and-how-to-close-the-gaps-yourself` |
