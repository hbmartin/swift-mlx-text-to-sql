# Part 2 — Foundation Models: the everyday API

**Version floor:** the framework itself is **26.0** on iOS, iPadOS, Mac Catalyst, macOS and visionOS —
**no watchOS until 27.0**. Everything genuinely new here (`LanguageModelError`, `ToolCallingMode`,
mutable `transcript`, `Attachment`, `SpotlightSearchTool`, `Response.usage`, `ContextOptions`) is
**27.0**, and a handful of things (`contextSize`, `tokenCount(for:)`) are **26.4**. You need **Xcode 27**
to compile against the new error types, and a **physical device** — the Simulator punches inference out
to the host macOS, so an Xcode 27 SDK on a macOS 26 host produces meaningless errors.

**Who this is for:** Swift app developers writing the feature, not the backend. If you are choosing
*which model* sits behind the session, that is [Part 4](../part-04-beyond-the-built-in-model/README.md); if you
are managing a long conversation, that is [Part 3](../part-03-context-profiles-agentic/README.md).

---

## Why this part exists

The pitch is three lines: make a `LanguageModelSession`, call `respond(to:)`, read `.content`. Those
three lines work, and that is the problem this part exists to solve.

Almost every defect in this surface **returns successfully**. A prompt-injection attack produces a clean
`Response` with plausible text. A `@Guide(.anyOf(["London","Paris","New York"]))` produces `"Beijing"`
and parses fine — Apple reproduced it on their own hardware. A model-level refusal in string mode is a
`String` that says no; your `catch` never fires and your success metrics look healthy. A tool you named
in your instructions but forgot to register makes the model loop forever with no error at all — an entire
WWDC26 session is built around that one bug. `SpotlightSearchTool` hands the model titles without bodies,
and the model invents the bodies.

So the organising claim of Part 2 is: **the guarantees this framework offers are structural, not
semantic, and the boundary between them is where your bugs live.** Guided generation guarantees you get a
well-formed `Itinerary`; it guarantees nothing about the values. `Instructions` versus `Prompt` is a
training-time prior, not a parser — it is a real mitigation and never a proof. Constrained decoding is
enforced in the sampler, which is exactly why a guide whose grammar channel is inert degrades *silently*
into a prompt hint. Learn where each guarantee stops, and the rest of this part is API tour.

---

## Read this first: the triage table

| If your situation is… | Read | Why |
|---|---|---|
| "I have never written a `LanguageModelSession`" | [2.1](references/01-sessions-and-prompting.md) | Every initializer, `respond`/`streamResponse`, `prewarm`, `isResponding`, `GenerationOptions`, `Transcript` |
| "I interpolate user input into `Instructions`" | [2.1 §3](references/01-sessions-and-prompting.md#3-instructions-vs-prompts-is-a-security-boundary) | **Stop.** That is the framework's only trust boundary and you are on the wrong side of it |
| "I want typed Swift values back, not strings" | [2.2](references/02-guided-generation-and-streaming.md) | `@Generable`, `@Guide`, `PartiallyGenerated`, snapshot streaming |
| "My `.anyOf` constraint isn't holding" | [2.2 §4](references/02-guided-generation-and-streaming.md#4-️-anyof-does-not-constrain-generation) | Confirmed broken by Apple staff on 26.2. Validate at the boundary |
| "My schema shape is only known at runtime" | [2.2 §7](references/02-guided-generation-and-streaming.md#7-generationschema-and-dynamicgenerationschema) | `DynamicGenerationSchema` → `GenerationSchema` → `GeneratedContent` |
| "`@Generable` throws `unsupportedCapability` on my own backend" | [2.2 §6](references/02-guided-generation-and-streaming.md#6-️-the-logits-problem-when-your-fastest-backend-loses-guided-generation) | Your fastest engine may not expose logits, and constrained decoding needs them |
| "The model should call my code" | [2.3](references/03-tools-and-tool-calling.md) | The `Tool` protocol end to end |
| "`respond(to:)` never returns" | [2.3 §7](references/03-tools-and-tool-calling.md#7-️-required-is-a-while-loop-and-you-own-the-exit) | `.required` is an unbounded `while` loop and you own the exit |
| "The model loops, offering the same thing, no error" | [2.3 §8](references/03-tools-and-tool-calling.md#8-️-the-tool-you-named-but-never-registered) | A tool named in prose but absent from the toolset |
| "I want RAG over my app's own content" | [2.4](references/04-spotlight-rag-and-system-tools.md) | `SpotlightSearchTool` — and the three ways it currently fails |
| "Spotlight results come back with no body text" | [2.4 §6–§8](references/04-spotlight-rag-and-system-tools.md#6-️-the-metadata-gap--the-defect-that-will-burn-you) | The metadata gap, Apple's index-delegate hydration hook, and the retrieve-then-hydrate fallback |
| "I want to put a photo in a prompt" | [2.5](references/05-image-input-and-attachments.md) | `Attachment`, labels, `ImageReference` |
| "I need bounding boxes / coordinates from an image" | [2.5 §9](references/05-image-input-and-attachments.md#9-what-the-model-cannot-do-with-pixels) | You cannot get them here. Use Vision or Core AI, then describe the crop |
| "It worked last week and no one changed anything" | [2.6 §5.3](references/06-availability-errors-and-guardrails.md#53-guardrails-change-under-a-running-app) | Guardrails update **out of band with OS releases** |
| "My `catch` arms stopped firing after an Xcode upgrade" | [2.6 §3](references/06-availability-errors-and-guardrails.md#3-the-2026-error-reshuffle-four-enums-where-there-was-one) | `GenerationError` → four new enums; the trigger is the rebuild, not the OS |
| "Permissive guardrails made no difference" | [2.6 §4](references/06-availability-errors-and-guardrails.md#4-the-two-refusal-mechanisms) | You are hitting the model's own refusal layer. There is no API for it |
| "I need to ship a paywall around an AI feature" | [2.6 §2.5](references/06-availability-errors-and-guardrails.md#25-there-is-no-required-device-capability-for-apple-intelligence) | The App Store has **no** required device capability for Apple Intelligence |

---

## The guides in this part

### [2.1 — `LanguageModelSession` end to end](references/01-sessions-and-prompting.md)

The foundational guide: every initializer form, `Instructions`/`Prompt` and their result builders, the
24-method `respond`/`streamResponse` matrix, `prewarm(promptPrefix:)`, `isResponding`, the now-mutable
`transcript`, all of `GenerationOptions`, `Response.usage`, and the six-case `Transcript` data model. It
ends with a complete SwiftUI screen that streams, cancels cleanly and catches all three error types.
Section 3 argues that instructions-vs-prompts is the framework's security model rather than an ergonomic
convenience, and section 9.3 turns transcript editing into a KV-cache cost table.

> ⚠️ **SILENT FAILURE** — prompt injection does not throw. There is no `LanguageModelError.promptInjection`,
> no guardrail case, no Instruments track. A successful injection looks exactly like a successful
> generation. Also here: `maximumResponseTokens` truncates mid-sentence with no `wasTruncated` flag, and
> Instruments traces store every prompt and response **unencrypted** in the `.trace` file you attach to
> bug reports.

### [2.2 — Guided generation and snapshot streaming](references/02-guided-generation-and-streaming.md)

What the `@Generable` macro synthesises, every `@Guide` form with evidence, the guide-to-type
compatibility matrix, runtime schemas, `GeneratedContent`, and why streaming gives you *snapshots* rather
than deltas (you assign, never append). It also reconstructs something Apple documents nowhere: guided
generation is grammar-constrained decoding via `xgrammar`, enforced in the sampler by masking logits —
which is the model that makes every other behaviour here intelligible.

> ⚠️ **SILENT FAILURE** — `@Guide(.anyOf([...]))` **does not reliably constrain generation.** An Apple
> Designer reproduced it; an Apple Frameworks Engineer confirmed it on iOS 26.2. The response parses
> cleanly, your `switch` falls through to `default`, in production. Validate every `.anyOf` value at the
> boundary. Section 6 adds the architectural version: a backend that samples on the GPU cannot expose
> logits, so guided generation is *impossible* there — and `CoreAILanguageModel` can advertise the
> capability optimistically before its engine is loaded.
>
> 🔴 **GAP** — nobody has established whether `@Generable enum` suffers the same non-enforcement as
> `.anyOf`. They plausibly land on the same JSON-Schema `enum` keyword. Every closed vocabulary in
> Apple's three 2026 sample apps is a `@Generable enum` and none is an `.anyOf`, which is suggestive of
> where Apple's confidence sits but is not evidence about enforcement. Until someone runs the
> hundred-iteration `#Playground`, treat **both** as advisory. Whether the `.anyOf` defect survives into
> 27.0 at all is also unconfirmed — the reproduction is pinned to 26.2.

### [2.3 — The `Tool` protocol, calling modes, and the required-mode loop](references/03-tools-and-tool-calling.md)

`Tool` member by member; the `@Generable` arguments struct as the contract between model and tool (and
why Apple's own evaluation sample makes every argument optional); writing descriptions that say *when*
rather than *what*; the six-entry anatomy of one tool-using turn; `toolCallingMode` in both places it can
be set, with the precedence rule; transcript rollback on a thrown tool error and
`TranscriptErrorHandlingPolicy`.

> ⚠️ **SILENT FAILURE (two of them, both consequential).** First: `.required` puts the model in an
> unbounded `while` loop with no documented iteration cap — Apple documents exactly two exits and you
> must use one. Second: a tool named in your instructions but missing from the toolset produces an
> infinite loop and **no thrown error**; WWDC26 session 243 exists to teach you to find it in Instruments.
> A third, smaller one: `Tool.parameters` is computed **once** at session init and never re-read, so a
> schema built from asynchronously-loaded data is empty forever. And a fourth that bites the UI first: a
> turn whose entire contribution is a tool call streams **zero** partials, so any spinner that waits for
> the first token hangs there — Apple's Origami sample carries an explicit `didReceivePartial` flag for it.
>
> ✅ **RESOLVED (2026-07-29)** — the declarations of `OCRTool` and `BarcodeReaderTool` were finally
> found, and the reason nobody could find them is itself the reader-critical fact: they live in the
> **`_Vision_FoundationModels` cross-import overlay**, a module the compiler activates only when a
> file imports **both** `Vision` and `FoundationModels` — the symbols are in *neither* parent
> interface. ✅ **SDK-verified**
> (`notes/sdk-interfaces/_Vision_FoundationModels-27.0-macos.swiftinterface:14-47` and `:49-83`):
> both are `struct`s conforming to `FoundationModels.Tool`, `init(name: String? = nil, description:
> String? = nil)`, each with a real nested `Generable` `Arguments` struct and an **opaque**
> `Output` — `call(arguments:)` returns `some PromptRepresentable`, so the output type cannot be
> named in user code. Still open: the exact string `Tool.name` derives when you omit it, and the
> default *value* of `includesSchemaInInstructions` (the requirement and its default implementation
> are SDK-verified; the getter's body is not emitted). Closed by the FoundationModels capture: the
> `onToolCall`/`onToolOutput` signatures — both arities, `async throws`,
> `Transcript.ToolCall`/`ToolOutput` payloads (`FoundationModels-27.0-macos.swiftinterface:1008-1022`).

### [2.4 — Local RAG with `SpotlightSearchTool`, plus OCR and barcodes](references/04-spotlight-rag-and-system-tools.md)

Apple's answer to "RAG on device without a vector database": the model writes and executes queries
against your own Core Spotlight index. Written against session 246 **and against Apple's shipping
sample project for it** — the hiking-trails app — which outranks the transcript wherever the two
disagree. Covers the hard prerequisite (donating content), the `Configuration` surface, the
index-delegate hydration hook, the batched `SearchReply` stream and its `queryToken`, guidance
profiles as a token gate, custom `Generable` pipeline stages, and evaluating a Spotlight-grounded
feature on *result coverage* rather than on how the answers read.

> ⚠️ **SILENT FAILURE — the metadata gap.** On beta builds the tool hands the model identity attributes
> only; bodies do not survive, and `CoreSpotlightSource(fetchAttributes:)` was reported non-functional on
> the tool path. The model then invents the bodies, fluently. Two independent observers, one
> Apple-acknowledged thread — but Apple's sample passes eleven attributes and pairs `fetchAttributes:`
> with `searchableIndexDelegate:` in **one** initialiser, which suggests the delegate is what actually
> supplies them. So wire both, then run the §6.3 test **before** you build anything on top of this; if it
> fails, §8's retrieve-then-hydrate pattern is verified working on three models including Apple's own.
>
> ⚠️ **SILENT FAILURE — the hydration hook that is never called back.**
> `searchableItems(forIdentifiers:searchableItemsHandler:)` is `nonisolated`, is not `async`, and returns
> through a completion handler. Any early `return` that skips the handler — a `guard` on a missing store,
> a swallowed error, an unrecognised identifier — leaves the framework waiting forever. No error, no
> timeout, no warning. Call the handler with `[]` on every path.
>
> 🔴 **GAP — the parts of this surface Apple's own reference app never touches.** Apple's session-246
> sample project closed nine gaps — the `Configuration` shape, the entitlement question, the delegate
> signature, the `SearchReply` case list and its non-frozen-ness, and the wire name `spotlight_search`.
> The declaration-shaped remainder is now closed too: the **`_CoreSpotlight_FoundationModels`
> cross-import overlay interface** was captured 2026-07-29, recaptured 2026-08-20 (✅ SDK-verified —
> `notes/sdk-interfaces/_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface`), settling
> `GuidanceProfile`'s value types, the `ContactResolver` protocol, `.files(FileSource)`, and
> `CustomStage`'s members. What stays open is **behavioural**: none of those four appear in Apple's own
> reference implementation, so their runtime behaviour is untested; the index delegate's firing for
> entity-indexed (`indexAppEntities`) content is unknown; and three beta-era defects (model-catalog
> error 5000, the tool never being invoked, and an Apple-confirmed description-vs-schema mismatch)
> still have **unknown current status**.

### [2.5 — Image input, and what the model cannot do with pixels](references/05-image-input-and-attachments.md)

`Attachment` and every source it accepts, the `orientation:` parameter, labels and `ImageReference` for
keying structured output back to specific images, the transcript types images become, and which backends
accept images at all. The most useful section is §9, and it is a negative result: the model reliably
*names* what is in an image and unreliably *locates* it — its bounding boxes are generated text, not a
regression head's output, and Apple's own answer on the forums is a redirect to Vision.

> ⚠️ **SILENT FAILURE** — a photo carrying EXIF orientation, loaded by a loader that does not apply it,
> produces a fluent and confidently wrong answer. If your feature is mysteriously worse on camera-roll
> photos than on screenshots, that is why. Normalise orientation exactly once, at your app's boundary.
> Related: `summarizeHistory` flattens attachments away, after which the model answers about images it
> can no longer see, from its own earlier description of them.
>
> 🟡 **MAC-AND-DEVICE-NARROWED GAP** — Apple has published **no** per-image token cost, formula, or resize
> policy. On stable macOS 27 and iPhone 15 Pro / iOS build `24A435`, `tokenCount(for:)` returned 6 for text alone but
> threw `LanguageModelError -1` for all six image sizes tested, even though `respond` accepted the
> generated image. Read `response.usage` and measure successful turns; do not use image
> `tokenCount(for:)` as a preflight on these builds. Both destinations confirmed exact label
> write-through; required labeled and unlabeled image-tool turns reached `toolRan=true` and then
> timed out, matching the 2026-08 beta-5 device run. This is a reverified limitation, not runtime
> drift.

### [2.6 — The complete failure taxonomy: availability, errors, guardrails and refusals](references/06-availability-errors-and-guardrails.md)

The largest guide in the part, organised as symptom → cause → fix across five failure planes. The 2026
error reshuffle (one enum became four — plus a fifth error type, `GeneratedContent.ParsingError`, that is
in none of them and that your catch ladder still has to name), the **two distinct refusal mechanisms**
almost everyone conflates, guardrail configuration and its documented blind spot — which Apple's own
sample code falls into — context overflow, the undocumented error domains people are actually hitting,
PCC quota handling, how to file a bug Apple will act on, and a complete copyable graceful-degradation
function.

> ⚠️ **SILENT FAILURE (three, and they compound).** A model-level refusal in **string mode** is not an
> error — it is a successful call returning a `String` that says no, which then poisons the transcript
> and makes the next refusal likelier. Generating a `@Generable` instead converts it into a throw; use
> guided generation as an error-handling mechanism. Second: `.permissiveContentTransformations` applies
> **only to string generation**, so an ordinary refactor to `respond(to:generating:)` silently restores
> default guardrails — **this trap has already caught Apple**, whose Book Tracker sample builds a
> permissive model and then calls `respond(to:generating:)` on the very next line at both call sites, so
> the `guardrails:` argument is inert. Third: rebuilding with Xcode 27 changes which `catch` arms fire,
> with no diagnostic.
>
> ⚠️ **Apple may update the built-in guardrails at any time, outside the OS update cycle.** Your safety
> behaviour is pinned by nothing you control — not your binary, not your deployment target, not the
> user's OS version — and there is no notification. This is the strongest argument in the series for
> [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md): evaluations here are a regression detector for a dependency you
> cannot version-pin.

---

## Reading order

**Everyone reads [2.1](references/01-sessions-and-prompting.md) first.** Every other guide assumes you
know what a session, a `Prompt` and a `Transcript` are, and §3's trust boundary is load-bearing
everywhere else.

**Then [2.6](references/06-availability-errors-and-guardrails.md), earlier than feels natural.** It is
placed last by number and should be read second, because availability gating and the refusal/guardrail
distinction determine your architecture, not your polish pass. Skimming §1–§4 is enough on a first pass;
come back for §7 the first time you see `LanguageModelError error -1`.

**Then pick by feature.** [2.2](references/02-guided-generation-and-streaming.md) if you want typed
output or streaming UI — which is most people. [2.3](references/03-tools-and-tool-calling.md) only if the
model needs to call your code. [2.5](references/05-image-input-and-attachments.md) only if you have
pixels.

**Defer or skip:**
- **[2.4](references/04-spotlight-rag-and-system-tools.md)** is skippable unless you are specifically
  building Spotlight-backed RAG. It is also the guide most likely to have moved: read §14 and §18.3
  before you invest, and measure rather than trust.
- **[2.2 §5–§6](references/02-guided-generation-and-streaming.md#5-how-guided-generation-is-actually-enforced-constrained-decoding)** (constrained decoding internals, the
  logits problem) can be deferred if you only ever use `SystemLanguageModel` or PCC — those always have
  guided generation. Read them the day you let a user pick a backend.
- **[2.2 §12](references/02-guided-generation-and-streaming.md#12-the-python-sdks-parallel-surface)** and
  **[2.5 §11](references/05-image-input-and-attachments.md#11-python-and-the-fm-cli)** are the Python SDK; skip unless you are
  building evaluation pipelines in a notebook.

---

## What this part deliberately does not cover

- **Context management as a discipline** — the 4K budget, KV-cache economics, `DynamicProfile`,
  `historyTransform`, `rollingWindow`/`summarizeHistory`, agentic orchestration. Part 2 tells you the
  transcript is mutable in 27.0 and what that costs; the strategy is
  [Part 3](../part-03-context-profiles-agentic/README.md).
- **Choosing a backend** — PCC eligibility and quota in full, `CoreAILanguageModel`, `MLXLanguageModel`,
  OpenAI-compatible servers, and authoring your own `LanguageModel` provider:
  [Part 4](../part-04-beyond-the-built-in-model/README.md).
- **`#Playground`, the Foundation Models Instrument, the `fm` CLI and the Python SDK** as tools in their
  own right: [Part 5](../part-05-prototyping-profiling-non-swift/README.md).
- **Measuring whether any of this works** — trajectory expectations, result coverage, catching the
  regressions that guardrail and model updates cause: [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md).
- **Device eligibility, entitlements and the Simulator trap** in full: [Part 1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/README.md).
- **Migrating a shipping 26.x app**, including the complete `GenerationError` mapping:
  [Part 17](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/README.md).
- **Vision itself** — object detection, segmentation, saliency. Part 2 tells you to use it and refuses to
  guess the modern Swift request names; the Core AI route is [Part 7](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/README.md).

---

## Sources for this part

Apple documentation under `/documentation/foundationmodels` (harvested 2026-07-27), including
`languagemodelsession`, `generable`, `generationguide`, `tool`, `transcript`, `languagemodelerror`,
`attachment`, `imagereference`, and the articles on tool calling, the context window, KV caching,
multimodal prompting, dynamic profiles, PCC and generative-output safety. WWDC26 sessions 241, 242, 243,
246, 299, 319 and 334, plus Meet-with-Apple 205 (the iOS 26 code-along) — all spoken transcripts, which is
why narrated code appears here as 🟡 RECONSTRUCTED. Apple sample code, read in full and treated as
top-tier evidence wherever it contradicts a transcript: *Origami*, *Book Tracker* (Evaluations), and
*Searching indexed content with natural language* (the session-246 hiking-trails app). Apple open-source read
on disk: `foundation-models-utilities` (including its `foundation-models-language-model-protocol`
SKILL.md and commit `376ca60`, a precise beta1→beta3 changelog), `python-apple-fm-sdk`, `coreai-models`;
plus `ml-explore/mlx-swift-lm`. Roughly thirty Apple Developer Forums threads with Apple-staff answers,
of which the load-bearing ones are 812501 (`.anyOf`), 831404 (the catch ladder and the Simulator
punch-out), 833642 (context, schema limits, no model pinning), 833651/832534 (`SpotlightSearchTool`
schema mismatch), 835777 (guardrails changing under a shipping app), 836673 (the iOS 27 refusal
regression), 836810 (App Store distribution), 837226 ("Tool Choice requires tools"), 838613 (bounding
boxes) and 838904 (the model-catalog bug). Community sources — a Spotlight field-verification note dated
2026-06-13, `noema-ios`, `coreai-model-zoo` — are attributed as community-measured at every point of use
and never presented as Apple figures.
