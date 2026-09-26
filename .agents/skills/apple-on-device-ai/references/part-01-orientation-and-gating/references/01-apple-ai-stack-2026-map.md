# The 2026 Apple AI stack, and how to choose a model backend

**Part 1 · Orientation and gating · reference guide 1 of 2**

---

## What this covers

The structural change that happened at WWDC26, and the decision it replaced. In 2025 you chose a
*framework*: Foundation Models, or Core ML, or MLX. In 2026 Foundation Models grew a public
`LanguageModel` / `LanguageModelExecutor` protocol pair, Apple shipped conformers backed by Core AI
and by MLX, and the question became **which backend runs behind one session API**. This guide maps
the layers, walks the five shipping conformers and exactly when each is right, says where Core ML
still belongs, gives a decision table keyed on constraints you actually have (privacy, offline,
cost, model choice, context size, latency, energy, app size, eligibility) plus the two feature
cliffs a bring-your-own model can fall off — `@Generable` and prefix reuse — presents the measured
performance picture with full attribution — including the places where the ranking *inverts*
depending on what you measure — and carries the series' known-bad-claims reference.

## Version floor

Everything here targets **iOS 27 / iPadOS 27 / macOS 27 / watchOS 27 / visionOS 27 / tvOS 27** with
**Xcode 27**, and every API is marked with the earliest OS that has it. Three floors matter and are
routinely confused:

- **26.0** — the Foundation Models framework itself, `SystemLanguageModel`, `LanguageModelSession`,
  `@Generable`, `Tool`. Available on iOS/iPadOS/Mac Catalyst/macOS/visionOS 26.0. **No watchOS.**
- **26.4** — a mid-cycle release that added context-size inspection and token counting
  (`SystemLanguageModel.contextSize`, `tokenCount(for:)`), and reduced guardrail false positives.
- **27.0** — everything in this guide's headline: the `LanguageModel` protocol,
  `PrivateCloudComputeLanguageModel`, `ContextOptions`, Dynamic Profiles, the whole **Core AI**
  framework, and watchOS support for `LanguageModelSession`.

## What you need

An Apple silicon Mac, Xcode 27, and — for anything on-device — an Apple Intelligence–capable device.
Nothing in this guide requires you to write code; it is the map you read before you pick a direction.
If you already know which backend you want, skip to [§5, the decision table](#5-the-decision-table),
then go to the part that covers it.

> **Sourcing.** Every non-obvious claim below carries ✅ **VERIFIED**, 🟡 **RECONSTRUCTED**, or
> 🔴 **GAP**, per the [series conventions](../../README.md#editorial-conventions). Every number
> carries its provenance: **Apple-published** or **community-measured**, with hardware, OS and date
> where the source gave them. A large fraction of the measured data in this guide is
> community-measured on **beta** operating systems and will move.

---

## Contents

1. [The one thing that changed](#1-the-one-thing-that-changed)
2. [The layer diagram, and what each layer owns](#2-the-layer-diagram-and-what-each-layer-owns)
3. [The five `LanguageModel` conformers](#3-the-five-languagemodel-conformers)
   - [3.1 `SystemLanguageModel`](#31-systemlanguagemodel--260-the-default)
   - [3.2 `PrivateCloudComputeLanguageModel`](#32-privatecloudcomputelanguagemodel--270-the-one-with-a-policy-gate)
   - [3.3 `CoreAILanguageModel`](#33-coreailanguagemodel--270-your-weights-apples-runtime)
   - [3.4 `MLXLanguageModel`](#34-mlxlanguagemodel--270-sdk-the-hugging-face-firehose)
   - [3.5 `ChatCompletionsLanguageModel`](#35-chatcompletionslanguagemodel--the-one-that-works-today)
   - [3.6 The protocol itself](#36-the-protocol-itself-and-why-it-is-two-types)
4. [Where Core ML still belongs](#4-where-core-ml-still-belongs)
5. [The decision table](#5-the-decision-table)
   - [5.1 The first cliff: `@Generable` and the fastest engine](#51-the-first-cliff-generable-and-the-fastest-engine)
   - [5.2 The second cliff: prefix reuse, and the models that cannot have it](#52-the-second-cliff-prefix-reuse-and-the-models-that-cannot-have-it)
   - [5.3 A note on multi-backend apps](#53-a-note-on-multi-backend-apps)
6. [The honest performance picture](#6-the-honest-performance-picture)
   - [6.1 Dense models: Core AI ties or wins. MoE: MLX wins.](#61-m4-max-dense-models-tie-or-favour-core-ai-moe-favours-mlx)
   - [6.2 iPhone, matched bytes: throughput parity, energy inversion](#62-iphone-17-pro-matched-bytes-throughput-parity-and-an-energy-inversion)
   - [6.3 Three rankings from one device](#63-three-rankings-from-one-device-burst-sustained-and-joules)
   - [6.4 Why a tok/s number without a protocol is meaningless](#64-why-a-toks-number-without-a-protocol-is-meaningless)
   - [6.5 The artifact is not a function of the recipe](#65-the-artifact-is-not-a-function-of-the-recipe)
   - [6.6 What to take away](#66-what-to-actually-take-away-from-all-of-this)
7. [Silent failures you can hit before you write a line of model code](#7-silent-failures-you-can-hit-before-you-write-a-line-of-model-code)
8. [Known-bad claims: material in circulation that is fabricated](#8-known-bad-claims-material-in-circulation-that-is-fabricated)
9. [How to read this series](#9-how-to-read-this-series)
10. [What this guide could not verify](#10-what-this-guide-could-not-verify)

---

## 1. The one thing that changed

If you read one paragraph of this series, read this one.

Through 2025, Apple's on-device AI story was three products that did not talk to each other. The
Foundation Models framework gave you a sealed system LLM behind `LanguageModelSession`. Core ML ran
a converted `.mlmodel` and made the hardware decisions for you. MLX was a research-grade array
framework you embedded, with weights you chose. Choosing between them was a genuine fork in the road:
different types, different file formats, different mental models, and no path between them that did
not involve rewriting your call sites.

In 2026 that fork closed. `LanguageModelSession` now sits on a **public protocol pair** —
`LanguageModel` describes a model, `LanguageModelExecutor` runs it — and Apple shipped conformers
that put Core AI and MLX *underneath* the Foundation Models API rather than beside it.

> ✅ **VERIFIED** — `protocol LanguageModel : Sendable` and `protocol LanguageModelExecutor :
> Sendable`, both `iOS 27.0+ Beta`, are documented framework symbols under the "Custom Language
> Model Provider" topic group of
> `developer.apple.com/documentation/foundationmodels`, alongside `LanguageModelCapabilities`,
> `LanguageModelExecutorGenerationChannel` and `LanguageModelExecutorGenerationRequest`. Apple's
> page lists `PrivateCloudComputeLanguageModel` and `SystemLanguageModel` as the conforming types it
> ships in the OS.

WWDC26 session 339 states the consequence directly:

> "And because these are built on top of a brand new **public protocol**, developers can bring
> frontier AI models into their apps using the same framework. […] Which ever model you use,
> Apple's, yours, or the community's, **you call them the same way, because every model conforms to
> the Language Model protocol.**"
> — WWDC26 session 339, "Bring an LLM provider to the Foundation Models framework", lines 10–12

Concretely, the same three lines of app code run against five different backends. Only the
construction line changes:

```swift compile:27
import FoundationModels

// 1 — On-device. Free, private, offline, no entitlement.            (iOS 26.0+)
let model = SystemLanguageModel()                     // 2026 house style; `.default` also works

// 2 — Apple's server model on Private Cloud Compute.                (iOS 27.0+, entitlement)
// let model = PrivateCloudComputeLanguageModel()

// 3 — Your own weights, run by Core AI on ANE/GPU/CPU.              (iOS 27.0+)
// let model = try await CoreAILanguageModel(resourcesAt: bundleURL)

// 4 — Anything on the MLX community Hugging Face org.               (27.0 SDK)
// let model = MLXLanguageModel(configuration: ModelConfiguration(id: "mlx-community/…"))

// 5 — Any OpenAI-chat-completions server: mlx_lm.server, Ollama, vLLM, LM Studio.
// let model = ChatCompletionsLanguageModel(name: "…", url: serverURL)

let session = LanguageModelSession(model: model)
let response = try await session.respond(to: "Summarize this contract.")
print(response.content)
```

Everything you already know about the framework survives the swap. Guided generation with
`@Generable`, tool calling, streaming, transcript inspection, Dynamic Profiles — all of it is defined
against the session, not against Apple's model.

> "The Foundation Models framework offers a **unified Swift API**, regardless of which model you're
> talking to. **Getting structured output with Generable, or calling Tools, works just the same with
> the PCC model, as it does with the on-device model.**"
> — WWDC26 session 319, lines 32–35

That is the reframing. "Which framework do I choose" became "**which backend do I choose behind one
session API**", and the answer is now a per-feature decision you can change later without touching
your call sites — which is exactly the property that makes it worth designing for on day one.

Apple's own 2026 sample code is built around exactly that property, and the idiom is worth copying
before you write anything else:

> ✅ **VERIFIED (Apple sample code)** — both iOS 27 samples store the backend as a **single stored
> property** and ship it set to the on-device model, with the PCC line commented out directly above:
>
> ```swift
> // Brainstorm and tutorial work best on a server model. The sample
> // defaults to the on-device system model so it runs out of the box.
> // To use Private Cloud Compute, request access to the managed
> // `com.apple.developer.private-cloud-compute` entitlement at
> // https://developer.apple.com/contact/request/private-cloud-compute/,
> // then replace the `serverModel` initialization with the line below.
> // var serverModel = PrivateCloudComputeLanguageModel()
> var serverModel = SystemLanguageModel()
> ```
> — Origami, `Origami/Models/OrchestratorProfile.swift:14-21`; **byte-for-byte the same comment
> block** appears in the Core Spotlight sample at `LLMSearchUsingCoreSpotlightApp/Session.swift:27-34`.
> Both then branch on `type(of: serverModel) == SystemLanguageModel.self` to adjust quality
> expectations at runtime.

Two things fall out of that. First, "swapping the backend is one line" is not marketing — it is how
Apple's own flagship samples are structured, and the line in question is a **property declaration**,
not a call site. Second, the backend you picked is a *runtime* fact your code may legitimately want
to branch on: the samples lower their guidance level and shorten their history when the property
holds the on-device model. Store the model once; derive from it.

### Three caveats before you get too comfortable

The unification is real but it is not seamless, and three things are worth internalising immediately
so the rest of the series reads correctly.

**Capabilities are declared, not discovered.** A conformer advertises what it can do through
`LanguageModelCapabilities`, and the framework routes on that declaration.

> ✅ **VERIFIED** — Apple's `LanguageModelCapabilities` page documents exactly four capability
> members: `guidedGeneration` ("The capability to ensure model output conforms to a given generation
> schema"), `reasoning` ("The capability to reason, structurally separately from producing a
> response"), `toolCalling`, and `vision` ("The capability to accept image inputs in prompts"). The
> page also states: "When a model doesn't support a capability, **the framework can refuse to
> dispatch incompatible requests to the executor** and throw a
> `LanguageModelError.unsupportedCapability(_:)` error instead."

So `@Generable` against a backend that has not declared `.guidedGeneration` is a throw, not a
silent degradation — which is good. But it also means **swapping backends can turn working code into
a thrown error**, and you find out at runtime. Check `capabilities.contains(_:)` before you branch
on a feature.

**A backend swap is a privacy change and you must say so.** Session 339's closing substantive point
is aimed at both package authors and app developers:

> "make sure everyone in the chain understands the privacy implications of the model behind it.
> **On-device and cloud-based models have very different privacy characteristics, and your users
> deserve to know which they're getting.**"
> — WWDC26 session 339, lines 204–205

**One documentation contradiction is live.** The classic session initializers are typed against the
concrete system model, not the protocol.

> ✅ **VERIFIED (and contradictory)** — Apple's `LanguageModelSession` reference gives
> `convenience init(model: SystemLanguageModel = .default, tools: [any Tool] = [], @InstructionsBuilder instructions: …)`
> for iOS 26.0+, i.e. **`SystemLanguageModel`, not `some LanguageModel`**. Only the two 27.0-era
> dynamic-profile initializers are documented as generic
> (`init(model: some LanguageModel = SystemLanguageModel.default, dynamicInstructions:history:)`).
> Meanwhile Apple's PCC article says: "Because both `PrivateCloudComputeLanguageModel` and
> `SystemLanguageModel` conform to the `LanguageModel` protocol, **you can pass either to
> `init(model:tools:instructions:)`.**"

> 🔴 **GAP (narrowed) — which `LanguageModelSession.init(model:...)` overload is real on the 27 SDK.**
> The reference page and the PCC article disagree. Apple's sample code makes the generic overload
> much the likelier reading: the Core Spotlight sample's `makeSession(tool:)` calls
> `LanguageModelSession(model: serverModel, tools: [tool], instructions: instructions)`
> against a property whose *inferred* type Apple's own instructions tell you to
> change to `PrivateCloudComputeLanguageModel` by editing one line. That instruction only makes sense
> if an `init(model:tools:instructions:)` generic over `LanguageModel` exists. But the shipped
> configuration compiles with `SystemLanguageModel`, so the swapped form is **untested code in a
> comment**, not a compiled witness. **Resolution:** `swift-symbolgraph` or a plain grep of
> `…/FoundationModels.framework/Modules/FoundationModels.swiftmodule/*.swiftinterface` on a machine
> with Xcode 27. Until then, if a session initializer fails to type-check with a non-system model,
> assume you need the dynamic-profile initializer, not that you spelled the model wrong.

---

## 2. The layer diagram, and what each layer owns

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  Foundation Models framework                             iOS 26.0 / 27.0     │
│  LanguageModelSession ── backed by any `LanguageModel` conformer             │
│    SystemLanguageModel · PrivateCloudComputeLanguageModel                    │
│    CoreAILanguageModel · MLXLanguageModel · ChatCompletionsLanguageModel      │
│    …and any third-party package that conforms                                │
├──────────────────────────────────┬───────────────────────────────────────────┤
│  Core AI                iOS 27.0 │  MLX                    open source       │
│  the inference framework that    │  the array framework for Apple silicon    │
│  powers on-device Apple          │  mlx · mlx-lm · mlx-swift · mlx-swift-lm  │
│  Intelligence, now public        │  OpenAI-compatible server, distributed    │
│  .aimodel → specialize → AIModel │  Python-first, no conversion step         │
│  → InferenceFunction → NDArray   │                                           │
├──────────────────────────────────┴───────────────────────────────────────────┤
│  Metal Performance Shaders                                                   │
│  Metal Performance Primitives + TensorOps (MSL)          custom kernels       │
└──────────────────────────────────────────────────────────────────────────────┘

  Evaluations framework (Xcode 27) cuts across every layer above.
  Core ML sits *beside* this stack, narrowed to non-neural-network models.
```

The layering at the bottom is Apple's own, stated in the Metal session:

> "Apple platforms provide **first-class support for running ML models at every layer of the
> software stack**. High-level frameworks like **Core AI and MLX** make it easy to deploy your models
> with minimal code, while lower-level APIs like **Metal Performance Shaders** provide access to
> high-performance Metal kernels. **These layers all build on the low-level acceleration provided by
> Metal Performance Primitives and the TensorOps library.**"
> — WWDC26 session 330 (Metal / TensorOps)

### What each layer actually owns

**Foundation Models owns the conversation.** Transcript management, instructions-versus-prompts,
guided generation and its schema compilation, the `Tool` protocol, streaming semantics, Dynamic
Profiles, session properties, and the error taxonomy. None of that is model-specific; it is why
swapping the backend leaves your app code alone. See
[Part 2](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/README.md) and
[Part 3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/README.md).

**Core AI owns execution of a neural network you supply.** It is described by Apple as "the
inference framework powering on-device Apple Intelligence", now public.

> ✅ **VERIFIED** — the Core AI framework page is titled "Run AI models in your app on Apple
> silicon" and is available on `iOS 27.0+ Beta, iPadOS 27.0+ Beta, Mac Catalyst 27.0+ Beta,
> macOS 27.0+ Beta, tvOS 27.0+ Beta, visionOS 27.0+ Beta, watchOS 27.0+ Beta`. Its overview reads:
> "Core AI helps you build, run, and deploy AI models in your app. […] The Swift API makes common
> tasks simple, while giving you more control over model specialization, caching, and inference
> performance when needed."

The pipeline it owns, end to end:

```
PyTorch model
  → coreai-torch (TorchConverter)          → .aimodel   portable, unspecialized
  → xcrun coreai-build compile  (optional  → .aimodelc  one per device architecture
     on macOS, MANDATORY on iOS)
  → on-device specialization               → cached specialized artifact (AIModelCache)
  → AIModel → InferenceFunction → run(inputs:) → NDArray / CVPixelBuffer
```

Covered across [Part 7](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/README.md) through
[Part 10](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-10-coreai-hardware-authoring-debugging/README.md).

**MLX owns iteration speed.** It is an open-source array framework plus a model layer
(`mlx-lm`, `mlx-swift-lm`) plus an OpenAI-compatible server. Its structural advantage is that **there
is no conversion step**: a new architecture lands on Hugging Face and MLX can usually run it in days,
because the model is Python (or Swift) code operating on arrays, not a compiled graph. Its structural
limit is the corollary: it is a GPU-path runtime, and (per community consensus, see §6) it does not
reach the Neural Engine. [Part 12](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/README.md) and
[Part 13](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/README.md).

**Metal Performance Primitives / TensorOps owns the floor.** A Metal Shading Language API for tensor
operations — `matmul2d`, convolution, cooperative tensors, quantized tensor types with MX scale
planes — that automatically uses whatever matrix hardware the GPU generation has, including the M5
neural accelerators. You go here when both frameworks above have failed you and you can name the
kernel you need. [Part 11](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-11-metal-and-tensorops/README.md).

**Evaluations cuts across all of it.** It is a Swift framework new in Xcode 27, and it is Apple's
answer to a structural fact of this stack: there is **no model version pinning API**. The on-device
model changes under your shipped app when the OS updates, and the only way to know whether that
broke your feature is to have measured it. Apple's own recommendation for choosing between backends
is an evaluation, not a benchmark:

> "When deciding between the on-device and PCC model, or deciding the reasoning level to use, it's
> good to make that decision **based on data, not just vibes**. […] **You may be surprised how well
> the on-device model performs at certain tasks, especially with the updated model this year. But
> the only way to know is by evaluating.**"
> — WWDC26 session 319, lines 61–64

[Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md).

---

## 3. The five `LanguageModel` conformers

Apple's own framing, from session 339, orders them by how much you have to bring:

> "The on-device System Language Model has been rebuilt from the ground up: it's smarter, better at
> instruction following, and accepts images directly in your prompts. **Beyond the system model,
> we've added three more options.**"
> — WWDC26 session 339, line 6

Those three are Private Cloud Compute, Core AI, and MLX. The fifth — `ChatCompletionsLanguageModel`
— is not in the session's headline list at all, because it ships in a separate package on a separate
release cadence. It is, today, the most immediately useful of the five for a lot of readers.

---

### 3.1 `SystemLanguageModel` — 26.0, the default

**Bring:** nothing. **Cost:** nothing. **Reach:** every Apple Intelligence device.

> ✅ **VERIFIED** — `SystemLanguageModel` is available on `iOS 26.0+, iPadOS 26.0+, Mac Catalyst
> 26.0+, macOS 26.0+, visionOS 26.0+` — **no watchOS**. Documented members:
>
> ```swift
> static var `default`: SystemLanguageModel                 // "The base version of the model."
> convenience init(useCase: SystemLanguageModel.UseCase = .general,
>                  guardrails: SystemLanguageModel.Guardrails = Guardrails.default)
> var isAvailable: Bool
> var availability: SystemLanguageModel.Availability
> @backDeployed(before: iOS 26.4, macOS 26.4, visionOS 26.4)
> final var contextSize: Int { get }
> final var supportedLanguages: Set<Locale.Language> { get }
> final func supportsLocale(_ locale: Locale = Locale.current) -> Bool
> nonisolated(nonsending) final func tokenCount(for instructions: Instructions) async throws -> Int
> ```
>
> `UseCase` has `.general` and `.contentTagging`. `Guardrails` has `.default` and
> `.permissiveContentTransformations`.

Because every parameter on that initializer is defaulted, **`SystemLanguageModel()` is legal**, and it
is what Apple writes in 2026.

> ✅ **VERIFIED (Apple sample code)** — Origami and the Core Spotlight sample use
> **`SystemLanguageModel()` exclusively** and never write `.default` anywhere
> (`OrchestratorProfile.swift:11-75`, `TermExtractor.swift:32-39`, `Session.swift:27-34`). Book Tracker
> uses both spellings. `SystemLanguageModel(guardrails: .permissiveContentTransformations)` also
> **appears in a sample** — previously this parameter was known to us only from a forum post.
> The two spellings are equivalent; `SystemLanguageModel()` is the 2026 house style, and it is the
> one that reads correctly when you later swap the property to another conformer.

What changed in the 2026 model, per session 241: it was "rebuilt from the ground up", is better at
logic and tool calling, and **accepts images directly in prompts** — the on-device model gained
vision. Apple's docs surface that as the `Attachment` / `ImageAttachmentContent` / `ImageReference`
types and the `.vision` capability, all `iOS 27.0+`.

**Choose it when** the task is summarize, classify, extract, tag, rewrite, or produce structured
output from text the user already has. This is the majority of shipping AI features. It costs you no
weights, no memory budget, no download, no specialization step, and no per-token bill. The community
formulation is worth keeping:

> "when Apple's system model does the task. Summarize, classify, extract, rewrite, structured
> output… costs you no weights, no memory budget, and no specialization step. If your feature fits,
> stop there. **Dropping to Core AI to re-implement what the system model already does is wasted
> work.**"
> — Blake Crosley, *Core AI: Running Models on Apple Silicon*, 2026-06-08 (community, graded
> well-sourced: 17 footnotes each to a specific Apple doc page)

**Its three hard limits.** Context is small; you cannot change the weights; and availability is a
runtime property you must handle.

> ✅ **VERIFIED** — Apple's PCC article and WWDC26 session 319 (lines 38–45) give the same five-row
> comparison: privacy ✅/✅, works offline ✅/🚫, request limits none/daily-per-user, context size
> **4K / 32K**, reasoning not-supported / multiple-levels.

> ⚠️ **Do not hardcode 4096.** Apple's slide, Apple's docs, and TN3193 all put the on-device
> context at 4,096 tokens per session — settled in §10 — and as of 2026-08-02 Apple's **written
> Q&A summary** for WWDC26 Group Lab 8121 documents the same platform value for **iOS 27
> specifically**, adding that the budget is **shared across input and output**. Its worked example
> says a 4,000-token input leaves roughly 96 tokens for the response (ch. `0:08:11`). (A shipping
> third-party app's source carries a comment that "the iOS 27 model reports 8K"; that unverified
> device-specific report conflicts with Apple's documented platform value but is not disproved,
> and that app hardcodes 4096 only as a fallback for when `contextSize` returns `<= 0`.)
> Read `SystemLanguageModel.default.contextSize` — it is `@backDeployed`
> to 26.4, so it is safe to call without an availability fence on any 26.4+ deployment. Treat `<= 0`
> as unknown.

Availability is the single largest source of "it doesn't work on my device" reports in the forums:

> ✅ **VERIFIED** — `SystemLanguageModel.Availability` is `@frozen enum` with `.available` and
> `.unavailable(UnavailableReason)`; `UnavailableReason` has `.appleIntelligenceNotEnabled`,
> `.deviceNotEligible`, `.modelNotReady`.

```swift illustrative
switch SystemLanguageModel.default.availability {
case .available:
    // Show your intelligence UI.
case .unavailable(.deviceNotEligible):
    // Permanent. Hide the feature and show an alternate experience.
case .unavailable(.appleIntelligenceNotEnabled):
    // Recoverable. Prompt the user to turn Apple Intelligence on.
case .unavailable(.modelNotReady):
    // Temporary — assets are still downloading. Tell them to try again.
case .unavailable(let other):
    // Unknown reason. Do NOT assume this is permanent.
@unknown default:
    break
}
```

**But note what Apple's own 2026 code actually does, because it is not this.**

> ✅ **VERIFIED (Apple sample code)** — the availability switch above appears in **exactly one** of the
> five sample archives, and it is the **iOS 26** one (`FoundationModelsCoffeeGame`,
> `MainMenu/MainMenuView.swift:47-70`). The two genuine iOS 27 samples **never call
> `SystemLanguageModel.availability`, never use `@available`/`#available` guards, and never gate UI on
> model readiness.** Both handle the Apple-Intelligence-disabled path **reactively**, by catching
> `SystemLanguageModel.Error` at use time and rendering a display message
> (`Origami/Models/Error+DisplayMessage.swift:12-36`, and the same file again in
> `LLMSearchUsingCoreSpotlightApp/`). `SystemLanguageModel.Error` is a **distinct type from
> `LanguageModelError`** and is checked **first**.

Teach yourself both and ship both. The proactive switch is what decides whether your feature's entry
point is even visible — you cannot show a button and discover on tap that the device is
`.deviceNotEligible`. The reactive catch is what covers the states that change *between* your check
and your call: Apple Intelligence turned off mid-session, assets evicted, a model still downloading.
Apple's current samples do only the second, which reads as under-defensive for a feature with a
discoverable UI entry point rather than as a recommendation to drop the first.

> 🔴 **GAP — whether dropping the proactive gate is Apple's intent or sample untidiness.** Two
> independent 27.0 samples omit it and one 26.0 sample has it, which is a pattern but not a policy
> statement. No WWDC26 session or doc page we hold retracts the availability-switch guidance.
> **Resolution:** watch for the availability article being revised, or ask in a lab.

> **Beta gotcha, community-reported:** on the iOS 27 and macOS 27 betas, developers report
> `availability` returning `.appleIntelligenceNotEnabled` unless the user has enabled *"Siri"* /
> *"Hey Siri"* or *"Press Side Button for Siri"* in Settings — i.e. Apple Intelligence being on is
> not by itself sufficient. Reported independently on iOS 27 beta 1 (forums thread 835211) and macOS
> 27 beta 2 (thread 836760). **It is a defect, not a gate to design around.** An Apple Frameworks
> Engineer answered 836760: *"The Foundation Models framework should be available in Europe even if
> Siri AI is not enabled. Please file a bug report via Feedback Assistant and be sure to include a
> sysdiagnose to help us investigate."* Unresolved as of 2026-07-27, so you will still hit it on the
> betas — but do not ship UX that permanently instructs users to turn Siri on. Full treatment in
> [`platform-and-version-gating`](02-platform-and-version-gating.md).

---

### 3.2 `PrivateCloudComputeLanguageModel` — 27.0, the one with a policy gate

**Bring:** an entitlement, and eligibility. **Cost:** no per-token bill to you; a daily quota to your
user. **Reach:** Apple Intelligence devices with a network — **including Apple Watch**.

> ✅ **VERIFIED** — `final class PrivateCloudComputeLanguageModel`, available on **iOS 27.0+,
> macOS 27.0+, watchOS 27.0+, visionOS 27.0+**. Its entitlement is
> `com.apple.developer.private-cloud-compute`, listed in the framework index under the "Private Cloud
> Compute" topic group.

```swift compile:27 imports:FoundationModels
if #available(iOS 27.0, macOS 27.0, watchOS 27.0, visionOS 27.0, *) {
    let model = PrivateCloudComputeLanguageModel()
    let session = LanguageModelSession(model: model)
    let response = try await session.respond(
        to: "What are the tradeoffs in this architecture?",
        contextOptions: ContextOptions(reasoningLevel: .deep)
    )
}
```

> ✅ **VERIFIED** — `ContextOptions` and `ContextOptions.ReasoningLevel` (`.light`, `.moderate`,
> `.deep`) are `iOS 27.0+` documented symbols. The parameter on `respond` is **`contextOptions:`**,
> not `options:` — `options:` takes `GenerationOptions`, which controls the decoder loop
> (sampling, temperature, max response length). Session 339 makes the split explicit: "`ContextOptions`
> control what goes into the prompt […] `GenerationOptions` control the decoder loop."

**What you get:** a 32,000-token context window, reasoning with three levels, and the same
`@Generable` / `Tool` / streaming surface. It is the same model behind many Apple Intelligence
features. Session 319's target use cases are "assistants that reason over large user input" and
"features that rely on making lots of tool calls, with large outputs".

**Reasoning is not free.** It is literally extra generated text in a separate transcript segment:

> "**This literally happens by letting the model generate extra text, in a separate segment of the
> transcript.** […] **So it uses tokens. This counts towards your context size limit.**"
> — WWDC26 session 319, lines 48–58

Apple's docs add that reasoning segments do not appear in the final response content, and recommend
**starting at `.moderate`**, escalating to `.deep` only for tasks with many competing constraints.

**Lead with eligibility, because for many readers the answer is "you can't".** This is the single
most important product fact about PCC and it is *not* fully stated in any WWDC session we have.

> ✅ **VERIFIED (three conditions, assembled)** — no-cost PCC access requires **all three** of:
> 1. Enrolment in the **App Store Small Business Program**;
> 2. Fewer than **2 million total first-time App Store downloads**, cumulative/lifetime across your
>    apps — *not* a rolling annual figure;
> 3. The **Private Cloud Compute entitlement** assigned to your account, applied for on the developer
>    website.
>
> Announced at Platforms State of the Union, 9 June 2026. Sessions 241 and 319 mention **only** the
> download threshold, so a developer can meet the download bar and still be ineligible. A forum
> poster with 180k units in the last year was excluded on the basis of pre-2015 success — a genuine
> consequence of the lifetime reading, not a misunderstanding.
>
> ⚠️ The URL `developer.apple.com/apple-intelligence/private-cloud-compute/` **404s**. The live path
> is `developer.apple.com/private-cloud-compute/`.

> ✅ **VERIFIED (Apple sample code)** — `com.apple.developer.private-cloud-compute` is a **managed**
> entitlement, and the request URL Apple puts in front of developers is
> **`https://developer.apple.com/contact/request/private-cloud-compute/`**. Both statements come from
> a comment block that ships **byte-for-byte identically** in two independent iOS 27 samples
> (`Origami/Models/OrchestratorProfile.swift:14-21`,
> `LLMSearchUsingCoreSpotlightApp/Session.swift:27-34`). Both samples' `.entitlements` files ship
> **without** it — Origami's contains only `com.apple.security.app-sandbox`.

That last detail is the product fact, not a build detail: **Apple's own flagship 2026 samples ship
configured for the on-device model, with PCC as a commented-out line you enable after your
entitlement request is granted.** If the samples cannot assume you have it, neither can your
architecture. Design the on-device path first and treat PCC as the upgrade.

> 🔴 **GAP — the Small Business Program condition rests on secondary sources.** It appears in the
> WWDC26 developer-site Apple Intelligence guide and in secondary coverage, but in no transcript we
> hold and in no doc page we read. **Resolution:** read the entitlement application page directly
> before you plan a business around it.

**Quota, not rate limiting.** Apple's docs draw the distinction sharply: "**Unlike rate limiting,
where a person waits for a period of time before trying again, exceeding the daily quota means a
person either waits for their usage quota to refresh or they upgrade to a higher tier.**" Requests
are counted against **the user's iCloud account**, not yours.

> ✅ **VERIFIED** — `PrivateCloudComputeLanguageModel.quotaUsage` returns a `QuotaUsage` struct with
> `isLimitReached: Bool`, `status` (with case `.belowLimit(Information)` where
> `Information.isApproachingLimit: Bool`), `resetDate` (empty when unknown or well below limit), and
> `limitIncreaseSuggestion` (optional, with `.show()` presenting system upgrade UI). The thrown error
> is `PrivateCloudComputeLanguageModel.Error.quotaLimitReached(_:)`. Quota is **orthogonal to
> availability** — a model can report `.available` and still throw `quotaLimitReached`.

Apple's UX guidance is unusually prescriptive and worth following: **do not use an alert**; the state
should persist rather than be dismissed. Disable the button, show a subtle label underneath, and
offer a "manage limit" affordance only when `limitIncreaseSuggestion != nil`.

You can test all of this without burning quota:

> ✅ **VERIFIED (docs wording)** — Product > Scheme > Edit Scheme → **Run** page → **Options** tab →
> the **"Simulated Apple Foundation Models Availability"** menu, with **"Approaching Quota Usage
> Limit"** and **"Quota Usage Limit Reached"**. (Session 319 narrates slightly different strings —
> "Debug then Options", "Simulate…", "Nearing Usage Limit". Trust the docs; the transcript is spoken
> from a beta build.)

**Choose it when** the on-device model has measurably failed your evaluation on context size or
reasoning depth — and you are eligible. Apple's own ordering: "**Start with the on-device model and
evaluate it** with the Evaluations framework. **If you determine your feature needs more reasoning
capability or context size, then use PCC.**"

**Also choose it for watchOS.** PCC is what brings `LanguageModelSession` to Apple Watch at all,
because the inference is remote. `SystemLanguageModel` has no watchOS availability.

Deep dive: [`fm-private-cloud-compute`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md).

---

### 3.3 `CoreAILanguageModel` — 27.0, your weights, Apple's runtime

**Bring:** a converted model bundle. **Cost:** app size or a download, memory, battery, and the
engineering time to convert and compress. **Reach:** Apple silicon, iOS/macOS 27.0+.

> ✅ **VERIFIED (repo source)** — from `apple/coreai-models`,
> `swift/Sources/CoreAILanguageModels/LanguageModel/CoreAILanguageModel.swift`:
>
> ```swift
> public struct CoreAILanguageModel: LanguageModel {
>     public enum LoadMode: Sendable { case lazy; case eager }
>     public typealias Executor = CoreAIExecutor
>
>     public init(resourcesAt url: URL,
>                 mode: LoadMode = .lazy,
>                 variant: String? = nil,          // e.g. "coreai-sequential", "ane"
>                 kvCacheStrategy: KVCacheStrategy = .auto) async throws
>
>     public var capabilities: LanguageModelCapabilities
>     public var executorConfiguration: CoreAIExecutor.Configuration
>     public var estimatedSizeOnDiskBytes: Int? { get }
>     public func load() async throws
>     public func unload()
> }
> ```
>
> Apple's own doc comment in that file shows the intended lifecycle:
> ```swift
> let model = try await CoreAILanguageModel(resourcesAt: url)  // .lazy by default
> print(model.estimatedSizeOnDiskBytes ?? 0)
> try await model.load()                                       // optional; respond auto-loads
> let session = LanguageModelSession(model: model)
> // ... generate ...
> model.unload()
> ```
> The Swift package declares `platforms: [.macOS("27.0"), .iOS("27.0")]` and vends five products:
> `CoreAILM` → `CoreAILanguageModels`, `CoreAIDiffusion`, `CoreAISegmentation`, `CoreAISpeech`,
> `CoreAIObjectDetection`.

The import is `import FoundationModels` **plus** `import CoreAILanguageModels` — the module name is
plural, the type is singular.

**This is a package dependency, not a system framework.** That matters more than it sounds.

> ⚠️ **Community finding that complicates Apple's framing.** A community audit (john-rocky,
> `coreai-model-zoo`, 2026-07-24) reports: "Only the **graph compiler + executor**
> (`CoreAI.framework`) is OS-resident. The LLM runtime — `EngineFactory`, the `coreai-pipelined`
> engine, `LanguageBundle`, on-GPU sampling, KV growth — is Swift code from `coreai-models` that
> **you compile into the app**." The proof offered is that the author patches it, which you cannot do
> to an OS framework. Practical consequence: the "nothing to bundle" pitch is half true — the
> compiler is free, the LLM engine is app code with app-code binary size and app-code bugs.
> **Community-measured/community-audited, not Apple-stated.**

**Capabilities are detected, not declared by you.** `CoreAILanguageModel` inspects the bundle at
init: `supportsReasoning` if the tokenizer has `<think>` or `<|reasoning_start|>`;
`supportsToolCalling` if it can detect tool-call markers; `isGuidedGenerationSupported` from the
engine's `supportsLogits`, falling back to `variant != "coreai-pipelined"`.

**`@Generable` is unavailable on the fast path. Price this before anything else.**

This is the single most consequential trade in the entire BYO-model story, and it is easy to miss
because it is stated nowhere in Apple's marketing. Grammar-constrained decoding works by **masking
the logits** at each step so the sampler can only pick tokens the schema permits. It therefore needs
the engine to hand you logits. Core AI's **fastest** LLM engine — the GPU-pipelined one — **samples
on the GPU and never surfaces them**. So `isGuidedGenerationSupported` comes back `false`, and
`@Generable` — Apple's flagship structured-generation feature, the thing that makes the whole
framework pleasant to use — **is unavailable exactly when you select the fastest backend.**

> ⚠️ **This is a real constraint, not a detail.** The rule is *approximate-or-throw*, and there is no
> honest approximation of a schema, so a correct provider throws:
>
> ```swift
> // Pipelined zoo bundles sample on-GPU — no logits, no constrained
> // decoding. Approximate-or-throw rule: there is no honest
> // approximation of a schema, so throw.
> if request.schema != nil {
>     throw LanguageModelError.unsupportedCapability(
>         .init(capability: .guidedGeneration,
>               debugDescription:
>                   "GPU-pipelined zoo bundles sample on-device and expose no logits; "
>                   + "guided generation needs a sequential engine."))
> }
> ```
> **Community-measured / community-audited against the 27.0 beta** (john-rocky, `coreai-model-zoo`;
> see `notes/repos/john-rocky-models.md`). Cross-checked against `InferenceEngine.supportsLogits` in
> the same fork: **GPU-pipelined engines return `false`; the sequential engine returns `true`.**
> Apple has published nothing on this either way.

The consequence for planning: if guided generation is load-bearing for your feature — and if you are
extracting structured data, it is — your Core AI options are the **sequential** engine variant
(`variant: "coreai-sequential"`), or you leave Core AI. And note what that does to §6: **every Core
AI throughput number in this guide was measured on the pipelined engine**, i.e. on the configuration
that does *not* have `@Generable`. If you need guided generation, none of those numbers are yours.

> 🔴 **GAP — how much slower the sequential engine actually is.** Nobody in our corpus has published
> a controlled sequential-versus-pipelined measurement on the same weights. The one 3.5× figure in
> circulation (qwen3.5, 58.5 → 204 tok/s, M4 Max) is **pipelined versus a hand-rolled per-token
> `fn.run()` loop**, not versus the sequential engine, and quoting it as the cost of guided generation
> would be wrong. **Resolution:** run `llm-benchmark` against one bundle twice, with
> `--inference-engine-variant coreai-sequential` and `coreai-pipelined`. Until someone does, price the
> sequential path as "unknown and possibly large", not as a small tax.

The honest framings of the choice are:

- **`@Generable` matters more than tok/s** → sequential Core AI, MLX, PCC, or the system model.
- **tok/s matters more than `@Generable`** → pipelined Core AI, and you parse free text yourself with
  all the failure modes that implies.
- **Both matter** → you are describing the system model or PCC, which get both for free. Re-read §3.1
  before committing to your own weights.

**Choose Core AI when you can name the control you need.** The best formulation in the corpus:

> "each layer down trades a default away for a handle. Foundation Models hands you everything and
> asks nothing. Core AI hands you the levers and asks you to know which to pull. **If you cannot name
> the specialization, caching, or scheduling control you need, you do not need Core AI yet.**"
> — Blake Crosley, 2026-06-08 (community)

Concretely, the reasons that hold up: you need a *specific* model (a domain fine-tune, a
multilingual model the system model doesn't cover, a non-LLM neural network entirely); you need
**Neural Engine** execution for its energy and GPU-exclusivity properties; you need deterministic
first-launch behaviour via ahead-of-time compilation; or you need a non-text modality — segmentation,
diffusion, speech, detection — for which `coreai-models` already ships a recipe.

**Two costs to price in before you commit.** First, on iOS, ahead-of-time compilation is
**mandatory**, not an optimization — iOS cannot JIT the MLIR in an `.aimodel`, and the failure is a
maximally misleading `NSPOSIXErrorDomain Code=2 "No such file or directory"`. Second, cold
specialization is real: community measurements on iPhone put a 0.8B model at ~4.8 s and a 2.3 GB
model at ~29 s, with one 3 GB `.aimodelc` taking **194 s** cold and 0.46 s warm. Both are covered in
[`coreai-specialization-caching-and-aot`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md).

**And one thing that is not a cost but a model-selection constraint: prefix reuse.** If your feature
is multi-turn — chat, an agent loop, anything with retrieved documents in the context — the metric
your users feel is turn-2 time-to-first-token, and it is decided by whether the engine can *rewind*
its KV cache instead of re-prefilling the whole conversation. It is worth roughly two orders of
magnitude, and **some model architectures cannot have it at all**. See
[§5.2](#52-the-second-cliff-prefix-reuse-and-the-models-that-cannot-have-it).

---

### 3.4 `MLXLanguageModel` — 27.0 SDK, the Hugging Face firehose

**Bring:** a model ID. **Cost:** a download, GPU memory, and the MLX runtime in your binary.
**Reach:** Apple silicon; GPU only.

Session 339's pitch is "simply pass in a model ID, and let the framework handle the rest". The
shipping initializer is more honest than that.

> ✅ **VERIFIED (repo source)** — `ml-explore/mlx-swift-lm`,
> `Libraries/MLXFoundationModels/MLXLanguageModel.swift`, Apple/MLX doc comment:
>
> ```swift
> import MLXFoundationModels
> import MLXHuggingFace
> import MLXLMCommon
> import HuggingFace
> import Tokenizers
>
> let model = MLXLanguageModel(
>     configuration: ModelConfiguration(id: "mlx-community/Qwen2.5-3B-Instruct-4bit"),
>     capabilities: [.guidedGeneration, .toolCalling],
>     weightsLocation: { id in … },
>     load: { configuration, progressHandler in
>         try await loadModelContainer(
>             from: #hubDownloader(),
>             using: #huggingFaceTokenizerLoader(),
>             configuration: configuration,
>             progressHandler: progressHandler)
>     })
> let session = LanguageModelSession(model: model, tools: [], instructions: nil)
> let response = try await session.respond(to: "Hello!")
> ```
>
> The real init is `init(configuration:capabilities:configurationResolver:weightsLocation:load:)`.
> The `#hubDownloader()` / `#huggingFaceTokenizerLoader()` macros are what make the transcript's
> one-liner claim roughly true in practice.

**Where it lives, because this confused people at ship time.** `MLXFoundationModels` is not a
separate Apple framework and it is not on any MLX release branch you can search for. It is a library
target inside `ml-explore/mlx-swift-lm`.

> ✅ **VERIFIED (repo source)** — the target is compiled only under
> `#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)`.
> `FoundationModelsIntegration` is a SwiftPM **trait**, on by default; `canImport(FoundationModels,
> _version: 2)` is the **macOS/iOS/visionOS 27.0 SDK** test. Build against the 26 SDK and the whole
> adapter compiles out silently — which is exactly what broke mlx-swift-lm's own nightly integration
> job on an Xcode 26.5 runner. Forum thread 836264 ("Where is this framework, there are no BETA
> branches on the MLX framework either") is the same confusion.
>
> ⚠️ `mlx-swift-lm` `main` is a **3.x major version** with breaking changes that decoupled the
> tokenizer and downloader packages. **Pin a version.**

**MLX's real advantage is turnaround, not tok/s.** There is no conversion step and no compiler, so a
new architecture is a pull request against Swift or Python source. The community audit puts it
plainly: MLX keeps "fully-OSS stack (every layer fixable); **no conversion step → new-arch turnaround
in days**; mature 4-bit affine quant; **free logits**; no O(p²) prefill-scratch wall."

**Free logits is the underrated one, and it is where MLX quietly beats Core AI's fast path at
Apple's own flagship feature.** MLX is Python (or Swift) code operating on arrays; the logits are a
variable. So the thing Core AI's GPU-pipelined engine structurally cannot do — hand you the
per-step distribution — MLX does by default, and grammar-constrained decoding follows. Concretely:
`MLXLanguageModel` can declare `.guidedGeneration` in its capability set and mean it, while a
pipelined Core AI bundle must throw `unsupportedCapability` (§3.3). `mlx-swift-lm` also ships
`MLXGuidedGeneration` ("Grammar-constrained generation (JSON Schema or EBNF) for any MLX model")
built on xgrammar.

> ⚠️ **The decision this creates.** For a BYO-model feature that needs `@Generable`, MLX and
> *sequential* Core AI are the two live options, and MLX is the one that does not force you onto a
> slower engine variant to get it — logprob tooling and sampler experiments come along for free.
> The community audit that measured both puts it as a "reverse differential": *"FM guided generation
> (`@Generable`) needs engine logits, and the GPU-pipelined fast path does not expose logits. MLX
> exposes logits trivially → structured generation, logprobs tooling, and sampler experiments are
> easier on MLX."* **Community-measured** (john-rocky, `coreai-model-zoo`; see
> `notes/repos/john-rocky-models.md`). This is the exact inverse of the marketing story, in which
> Apple's runtime is the one with the first-class framework integration.

**Its structural limit.** MLX runs on the GPU. Community consensus — asserted on Hacker News,
consistent with every measurement in §6 — is that MLX cannot reach the Neural Engine. The strong
version of that claim ("MLX is therefore slow") is **contradicted** by the measurements in §6.3,
where MLX owns the Mac energy Pareto frontier. The defensible version is: *MLX is a GPU-path runtime,
so it throttles like one and contends with your UI rendering.*

> ⚠️ One correction worth carrying, because an earlier version of the same community source got it
> wrong and then fixed it: **MLX does run on iPhone**, via mlx-swift. Only the ANE is closed to it.
> (Self-correction dated 2026-07-24 in `coreai-vs-mlx-speed.md`.)

**Choose MLX when** you want breadth of model choice and speed of iteration over deployment polish:
prototyping, research, a Mac app, a power-user feature, an MoE model, or any architecture that landed
last month. Choose against it when your product is a battery-sensitive always-on iPhone feature and
you have an ANE-friendly alternative.

Deep dives: [Part 12](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/README.md), [Part 13](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/README.md), and
specifically
[`mlx-swift-fm-bridge-and-guided-generation`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md).

---

### 3.5 `ChatCompletionsLanguageModel` — the one that works today

**Bring:** a URL. **Cost:** whatever your server costs. **Reach:** anywhere, including Linux.

This is the quiet one. It is not in session 339's headline list because it does not ship in the OS —
it ships in **`apple/foundation-models-utilities`**, a package Apple explicitly updates *between* OS
releases with "emerging and experimental building blocks".

> ✅ **VERIFIED (repo source)** — `Sources/FoundationModelsUtilities/LanguageModels/ChatCompletionsLanguageModel.swift`:
>
> ```swift
> public struct ChatCompletionsLanguageModel: Sendable, LanguageModel {
>   public var name: String
>   public var url: URL
>   public var additionalHeaders: [String: String]
>   public var supportsGuidedGeneration: Bool
>
>   public init(
>     name: String,
>     url: URL,
>     additionalHeaders: [String: String] = [:],
>     supportsGuidedGeneration: Bool = true,
>     urlSessionConfiguration: URLSessionConfiguration? = nil   // added in beta 3
>   )
> }
> ```
>
> Capabilities are declared as `[.vision, .toolCalling, .reasoning]` unconditionally, plus
> `.guidedGeneration` gated on the `supportsGuidedGeneration` flag.

Usage is three lines:

```swift prelude:external-module
import FoundationModels
import FoundationModelsUtilities

let model = ChatCompletionsLanguageModel(
    name: "minimax-m2.5",
    url: URL(string: "http://localhost:8000/v1")!,
    supportsGuidedGeneration: false        // some local servers don't support it
)
let session = LanguageModelSession(model: model)
```

**Why this matters more than its billing suggests.** `mlx_lm.server` is OpenAI-chat-completions
compatible. So are Ollama, LM Studio, and vLLM — all of which, per session 232, are themselves built
on MLX/MLX-LM. Which means:

> **`mlx_lm.server` + `ChatCompletionsLanguageModel` = any Hugging Face model behind
> `LanguageModelSession`, today, on hardware you already have, without waiting for
> `MLXLanguageModel` or the 27 SDK.**

That is the fastest path in the entire stack from "I want to try model X in my app's real prompt
flow" to running code. It is also the honest answer for a team that needs a specific frontier model
and has its own inference bill.

**Three practical warnings.**

> ⚠️ **Known defect — hardcoded `v1` path.** `buildURLRequest` decides versioning with
> `baseURL.pathComponents.contains("v1")` and appends `/chat/completions` or `/v1/chat/completions`.
> Servers on any other version path break. Confirmed and accepted on Apple Developer Forums thread
> 838444 (Apple staff response), filed as FB23837262, at
> `ChatCompletionsLanguageModel.swift` line ~634. **Live limitation as of 2026-07-27.**

> ⚠️ **`from: "1.0.0"` resolves to nothing.** The package's only tags are prereleases, and SwiftPM's
> `from:` excludes prereleases. Pin `exact: "1.0.0-beta3"` or a revision.

> ⚠️ **This package is explicitly experimental and out-of-band with the OS.** Session 241 calls it
> "emerging and experimental building blocks" updated "between OS releases". Treat its API surface as
> less stable than the in-OS `FoundationModels` framework. It also carries breaking changes across
> its own betas — `LanguageModelCapabilities(capabilities:)` became `LanguageModelCapabilities(_:)`
> between beta 1 and beta 3 (the labelled form still compiles; Apple's docs now mark it
> *Deprecated*).

One more thing this package proves, which is otherwise only a claim: it declares "Supported
platforms: **Apple platforms and select Linux distributions like Ubuntu**", and its source guards
`#if canImport(FoundationNetworking)` — the swift-corelibs-foundation module that exists only on
non-Darwin platforms. That is the strongest machine-checkable evidence in the corpus for the "runs
everywhere Swift runs" claim.

Deep dive: [`fm-utilities-skills-and-history-modifiers`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md)
and [`byo-model-behind-languagemodelsession`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md).

---

### 3.6 The protocol itself, and why it is two types

You do not need this to *use* a backend. You need it to *understand* why backends behave differently,
and to author one.

> 🟡 **RECONSTRUCTED** — the shape below was read from the macOS 27 beta
> `FoundationModels.swiftinterface` by a community researcher and is consistent with all three
> conforming implementations we have source for (`CoreAILanguageModel`, `MLXLanguageModel`, and a
> community `ZooLanguageModel`). Apple's documentation confirms every **member** but does not print
> the full signatures, so treat the shape as right and details like `nonisolated(nonsending)` as
> provisional.

```swift illustrative
protocol LanguageModel: Sendable {
    associatedtype Executor: LanguageModelExecutor where Self == Executor.Model
    var capabilities: LanguageModelCapabilities { get }
    var executorConfiguration: Executor.Configuration { get }
}

protocol LanguageModelExecutor: Sendable {
    associatedtype Configuration: Hashable, Sendable      // per-session executor cache KEY
    init(configuration: Configuration) throws
    func prewarm(model: Model, transcript: Transcript)
    nonisolated(nonsending) func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: Model,
        streamingInto channel: LanguageModelExecutorGenerationChannel) async throws
}
```

The split exists for one reason, and Apple's docs state it: "**Because most of the work is done in
the executor, keep the type that adopts this protocol intentionally light.**"

The mechanism that makes that work — and the single most consequential thing to know about backend
behaviour — is the **executor store**:

> "Each **session holds an executor store**. […] Model2 produces the same configuration, and because
> `Configuration` is `Hashable`, the framework knows it matches, and resolves to the same executor.
> **The configuration is the lookup key, not the model.** […] Each unique configuration maps to
> exactly one executor in the store."
> — WWDC26 session 339, lines 59–66

So: same `Configuration` ⇒ same executor instance ⇒ reused weights, reused KV cache, reused
connection. A *different* `Configuration` ⇒ a whole new executor, a fresh weight load, a cold cache.
If your app appears to reload a 4 GB model on every request, the answer is almost always that
something in your configuration is varying.

And when the session deallocates, the store goes with it: every executor is released, `deinit` runs,
weights are freed. You write no teardown code — **unless** the backend deliberately opts out, which
`MLXLanguageModel` does by keeping a process-global `static let cache = ModelCache()` outside the
executor, with explicit `evictAll()` / `evict()`. Its doc comment explains why: "**Without caching,
model loading takes 2-30 seconds per request.**"

Full treatment in
[`authoring-a-languagemodel-provider`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md)
and
[`provider-executor-store-and-kv-reuse`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/references/04-executor-lifecycle-and-kv-reuse.md).

**A sixth category exists and is not shipped yet.** Session 339 (lines 10–12) says "**Anthropic and
Google will soon extend the Foundation Models framework with Swift packages of their own**", and
notes Gemini models are available through the Firebase Apple SDK.

> 🔴 **GAP — no first-party Anthropic or Google `LanguageModel` package was found.** We have the
> announcement and nothing else: no package URL, no type name, no initializer. Community articles
> that show `ClaudeModel(apiKey: .keychain)` or `GeminiModel(apiKey:)` are **illustrative sketches by
> their authors, not API** — and session 339's own guidance argues against exactly that shape ("If
> your initializer takes an API key as a string, developers will be tempted to take the path of least
> resistance. Instead… offer a token provider or sign in flow"). **Resolution:** check
> `github.com/anthropics` and the Firebase Apple SDK release notes; do not write against a guessed
> type name.

---

## 4. Where Core ML still belongs

Core ML is not dead, it is *narrowed*, and knowing where the line sits saves you from both mistakes:
porting a working `.mlmodel` for no reason, and starting a new transformer project in the wrong
framework.

The cleanest statement is in Apple's own Core AI documentation, and it is a one-liner:

> ✅ **VERIFIED** — from *Run AI models in your app on Apple silicon* (the Core AI framework
> overview page): "**If your app uses model types other than neural networks, such as decision trees
> or tabular feature engineering, see Core ML.**"

That single sentence draws the boundary: **Core AI takes neural networks. Core ML keeps everything
that is not one.** In practice that means:

| Stays in Core ML | Moves to Core AI |
|---|---|
| Decision trees, gradient-boosted trees, random forests | Transformers, LLMs, VLMs |
| Tabular feature engineering, pipelines, scalers, imputers | CNNs, ViTs, diffusion models |
| Linear/logistic regression, SVMs, k-NN | Encoders (CLIP, T5, RoBERTa), ASR, TTS backbones |
| Create ML–trained classifiers built on those primitives | Anything you would export from PyTorch today |
| Your existing shipped `.mlmodel` / `.mlpackage` | Anything new with attention in it |

Two independent readings arrived at the same conclusion, which is why we state it with confidence
despite neither being a formal Apple policy statement:

> **Apple's written WWDC 2026 Group Lab summary.** For lab **8121**, "Coding Intelligence,
> Machine Learning & AI Group Lab," Apple's published Q&A summary describes Core ML as focused on
> traditional machine learning such as decision trees, directs new neural-network work toward Core
> AI, and positions MLX for on-device training and distributed workloads. Apple publishes no caption
> track for the lab, so this is evidence from its written summary, not a quotation of panel speech.
> Treat it as a **direction-of-travel signal**, not a formal platform-support policy.
>
> **An independent reader of the updated docs.** "Core ML narrows to classic, non-neural ML (its own
> docs now point you there for 'decision trees or tabular feature engineering'); Core AI takes neural
> nets and transformers (the new .aimodel format, the new profiler); MLX stays the separate
> bring-your-own-weights track." — Hacker News comment 48459443, user `ABS`.

Two parties reaching the same reading from different evidence raises confidence considerably. Both
are still **community**, not Apple policy.

### What this does *not* mean

**It does not mean your shipped Core ML models break.** No deprecation timeline has been announced.
Existing `.mlmodel` and `.mlpackage` files continue to work. The historically accurate analogy from
the community is UIKit and SwiftUI: both coexist for years, but every new platform capability ships
in the new framework and the old one quietly stops receiving investment.

**It does not mean Core ML was bad at this.** It means Core ML was designed for a different workload:

> "Core ML was designed for **batch inference on deterministic models** — not autoregressive token
> generation, streaming responses, multi-turn sessions, or tool calling." — byteiota, June 2026
> (community, pre-WWDC speculation piece — cite the framing, not its predictions)

The structural tell is that Foundation Models v1 in 2025 had to be built *alongside* Core ML rather
than on top of it. Core AI is what "on top of it" looks like when you build the inference layer for
LLM-shaped work from scratch.

**It does not mean "convert everything now."** If you have a shipping Core ML pipeline that meets its
latency and quality budget, converting it buys you nothing this year. Convert when you need something
Core AI has and Core ML doesn't: states/KV cache as a first-class concept, multi-function assets,
custom Metal kernels embedded in the asset, the Core AI Debugger's source-level tracing, or an
architecture `coremltools` chokes on.

> One naming correction, because it circulates: **`coreai-opt` (`apple/coreai-optimization`) is the
> successor to `coremltools` on the optimization side** — quantization, palettization, pruning. That
> mapping is stated outright by the Hacker News reader above and by no article we read. See
> [Part 9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md).

---

## 5. The decision table

Read this top to bottom and stop at the first row that describes a constraint you actually have.
Constraints beat preferences; the order is roughly "most likely to eliminate options first".

The fourth column is the one people forget until it is expensive: **what your choice costs you in
`@Generable`.** Guided generation needs engine logits, and one of the backends below is fastest
precisely because it does not produce any. Read [§5.1](#51-the-first-cliff-generable-and-the-fastest-engine)
before you rely on a ⚠️.

| If your constraint is… | Then | Keeps `@Generable`? | Because |
|---|---|---|---|
| **Data must not leave the device, ever** | `SystemLanguageModel`, or `CoreAILanguageModel`, or `MLXLanguageModel` | ✅ — **unless** pipelined Core AI | All three are local. PCC is privacy-preserving but is still a network round trip; `ChatCompletions` is whatever your server is. |
| **Must work offline** | `SystemLanguageModel` / `CoreAILanguageModel` / `MLXLanguageModel` | ✅ — **unless** pipelined Core AI | PCC "requires a network connection" (Apple docs), which also tells you the fallback: "if the request fails because the network connection is unavailable, **retry the request using the on-device model**." |
| **Zero marginal cost, at any volume** | `SystemLanguageModel` first; PCC second if eligible | ✅ | Apple charges you nothing for either. PCC's cost lands on your *user* as a daily quota. Everything else costs device resources or server bills. |
| **Zero device cost — no app-size or memory budget** | `SystemLanguageModel` or PCC | ✅ | Core AI and MLX both mean weights: download size, disk, and wired memory. The system model lives in Apple's process; a community harness measured its own in-process peak at **27 MB**, which is harness overhead, *not* the model. |
| **You need a specific model** (domain fine-tune, specific language coverage, a named open-weight family) | `CoreAILanguageModel` or `MLXLanguageModel` | ⚠️ **only on MLX or sequential Core AI** | The system model is sealed. You cannot swap its weights, and as of OS 27 you cannot ship a custom LoRA adapter for it either — see the note below. |
| **You need more than the on-device model's 4,096-token context** | PCC (32K), or a Core AI / MLX model you chose for its context | ⚠️ same caveat on the Core AI branch | Apple specifies 4,096 tokens per on-device session; still read `contextSize` so model choice and future OS revisions remain explicit.[^tn3193-context] Some Core AI recipes ship 32K–131K context (`gemma3-*-it` at 131072, `qwen3-4b`/`8b` at 40960). |
| **You need explicit reasoning** | PCC (`.light` / `.moderate` / `.deep`), or a reasoning model via Core AI / MLX | ⚠️ same caveat on the Core AI branch | `SystemLanguageModel` does not do reasoning. `CoreAILanguageModel` detects `.reasoning` from tokenizer markers (`<think>`, <code>&lt;&#124;reasoning_start&#124;&gt;</code>). |
| **You need guided generation (`@Generable`)** | `SystemLanguageModel`, PCC, MLX, or a *sequential* Core AI variant | ✅ by construction | ⚠️ Core AI's **fastest** engine does not expose logits, so `.guidedGeneration` is unavailable on it — and every Core AI number in §6 was measured on that engine. This is the one place where "fastest" and "flagship feature" are mutually exclusive. [§5.1](#51-the-first-cliff-generable-and-the-fastest-engine). |
| **Multi-turn chat, an agent loop, or RAG — turn-2 TTFT is the felt metric** | A **pure-attention** model. **Not** Qwen3.5, Qwen3.6, LFM2.5 or Granite 4. | — (orthogonal) | Prefix reuse is worth ~**101×** on turn-2 TTFT at 4k context. Linear-attention and hybrid SSM models **structurally cannot have it** and re-prefill the whole conversation every turn. [§5.2](#52-the-second-cliff-prefix-reuse-and-the-models-that-cannot-have-it). |
| **Lowest energy per token on iPhone** | `SystemLanguageModel`, then the ANE | ✅ system model; ⚠️ engine-dependent on a bundle | Community-measured on M4 Max: Apple FM at **0.11 J/tok**, ~2× better than GPU runtimes and ~4× better than the CoreML/ANE path. §6.3 explains why low *power* ≠ low *energy*. |
| **An always-on / long-running feature** | ANE-backed Core AI, or accept ~half your burst rate | ⚠️ engine-dependent | Community-measured on iPhone 17 Pro: GPU runtimes shed 50–60% of throughput over 10 minutes; the ANE retains ~65–67%. "The GPU wins the sprint; the ANE wins the marathon." |
| **The GPU must stay free for your UI** | ANE-backed Core AI | ⚠️ engine-dependent | The most robust ANE advantage is not speed, it is **GPU exclusivity** — the one structural fact MLX cannot reach. |
| **Deterministic first launch matters** | Core AI with AOT (`coreai-build`) + `AIModelCache` | ⚠️ engine-dependent | Cold specialization is otherwise seconds to minutes. Community-measured: 0.8B ≈ 4.8 s, 2.3 GB ≈ 29 s, and one 3 GB `.aimodelc` at **194 s cold / 0.46 s warm** on iPhone. |
| **You need Apple Watch** | PCC | ✅ | `SystemLanguageModel` has no watchOS availability. `LanguageModelSession` itself gains watchOS at 27.0. |
| **You need MoE (mixture-of-experts)** | MLX | ✅ — MLX has free logits | Community-measured: MLX beats Core AI's stock lowering by **+28%** on gpt-oss-20b. Core AI reaches parity only with a hand-written gather kernel. §6.1. |
| **Fastest possible iteration on a brand-new architecture** | MLX (or `ChatCompletionsLanguageModel` → `mlx_lm.server`) | ✅ | No conversion step. New architectures land in days, not after a converter learns the ops. |
| **You need a frontier model** | `ChatCompletionsLanguageModel` → your server, or a third-party package when one ships | ⚠️ your server's problem — `supportsGuidedGeneration:` is a flag **you** assert | Nothing on-device is a frontier model. Be explicit with users about where the data goes. |
| **You are not shipping an LLM at all** (trees, tabular, classical ML) | **Core ML** | n/a | Apple's docs route you there by name. §4. |
| **You cannot name a control you need** | `SystemLanguageModel` | ✅ | The strongest single line in the corpus: "If you cannot name the specialization, caching, or scheduling control you need, you do not need Core AI yet." |

> **Known negative that changes advice: custom LoRA adapters for the system model are gone.**
> Two independent Apple-staff statements indicate custom adapters are **discontinued in OS 27**; the
> Adapter Training Toolkit stops at 26.0.0. All `.fmadapter` /
> `SystemLanguageModel.Adapter` / `xcrun ba-package foundation-models` material is now historical.
> If you were planning to fine-tune the system model: you cannot. The migration path is a model of
> your own via Core AI or MLX. See
> [Part 17](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/README.md).

### 5.1 The first cliff: `@Generable` and the fastest engine

Every row above with a ⚠️ in the third column is the same fact wearing a different hat, so state it
once. **Grammar-constrained decoding masks logits.** No logits, no `@Generable`. Core AI's
GPU-pipelined engine is fastest because it keeps the whole sampling loop on the GPU and never brings
a distribution back to the host, so `InferenceEngine.supportsLogits` is `false` and
`CoreAILanguageModel` declines to declare `.guidedGeneration` for that bundle. The framework then
refuses to dispatch schema requests to it and throws `LanguageModelError.unsupportedCapability`.

> ⚠️ **The asymmetry that catches people:** the system model and PCC give you `@Generable` *and*
> Apple's best throughput, for free. The moment you bring your own model you are choosing between
> them. **An app that brings its own model loses Apple's flagship structured-generation feature
> exactly when it picks the fastest backend.** Nothing in Apple's material says this; it is
> **community-measured / community-audited** (john-rocky, `coreai-model-zoo`, verified 2026-06-11
> against the 27.0 beta; see `notes/repos/john-rocky-models.md`).

The escapes, in the order most teams should try them:

1. **Don't bring your own model.** Re-read §3.1. If the system model does the task, this whole cliff
   is imaginary.
2. **MLX.** Free logits, `MLXGuidedGeneration` (JSON Schema / EBNF via xgrammar), and no slower
   variant to fall back to. §3.4.
3. **Sequential Core AI** (`variant: "coreai-sequential"`). You keep `@Generable` and the ANE story
   and give up the pipelined engine's throughput — by an amount nobody has published. Measure it
   yourself before you commit; see the gap in §3.3.
4. **Parse free text yourself.** Honest, occasionally correct, and the reason `@Generable` exists.
   Budget for retries and a validation layer, and measure the failure rate with
   [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md) before you convince yourself it is fine.

Full treatment in
[`byo-model-behind-languagemodelsession`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md)
and [`guided-generation-and-streaming`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md).

### 5.2 The second cliff: prefix reuse, and the models that cannot have it

The other feature cliff is not about a framework at all. It is about the **architecture of the model
you picked**, which means it is a decision you make months before you can feel the consequence.

If your feature is multi-turn, the number your users experience is turn-2 time-to-first-token. A
naive chat loop re-templates the whole history and re-prefills it from scratch every turn, so turn
*N* pays for turns 1..*N*−1 again before emitting a single new token. The fix is to **rewind** the KV
cache to the longest common prefix instead of resetting it, and it is nearly free:

> ✅ **VERIFIED (repo source — community fork of `apple/coreai-models`)** — the mechanism is worth
> understanding because it is what explains the exception. Trimming a KV cache is a **single integer
> assignment**: `processedTokenCount` moves backwards and nothing is cleared, zeroed, moved or
> reallocated (`CoreAISequentialEngine.swift:437-443`). It is safe because attention is **causal** — a
> query at position *p* only reads keys at positions ≤ *p*, so every row at or beyond the retained
> position is overwritten by the next prefill before any query could read it. Apple's *upstream*
> engine already states the invariant, in `reset()`'s own comment: *"the KV pair needs no clearing —
> attention only reads positions below the new offset."* The community patch simply exposes the
> partial case as `trimKVCache(to:)` on `InferenceEngine`.

**What it is worth.** Community-measured (john-rocky, `coreai-model-zoo`, `CoreAIChatMac`,
qwen3-0.6b, sequential engine, Mac — **exact Mac model and macOS build not stated by the source**):

| Turn | Prompt tokens | Reused | TTFT, reuse ON | TTFT, reuse OFF | Speedup |
|---|---:|---:|---:|---:|---:|
| 2 | 357 | 336 | **0.126 s** | 1.915 s | **15.2×** |
| 2 | 4,103 | 4,075 (99.3%) | **0.230 s** | 23.282 s | **101×** |

With greedy decoding the turn-2 output is **byte-identical** ON versus OFF, which is the claim that
makes this a free win rather than a quality trade. And note the scaling shape, which is the actually
useful part: re-prefill cost grows with context while reuse cost stays roughly flat, so the ratio
*increases* with how much context you have. RAG and agent loops are where it pays.

> ⚠️ **And here is the model-selection consequence.** The rewind is refused outright when the graph
> carries recurrent state:
>
> ```swift
> guard extraStates.isEmpty else { return -1 }
> ```
>
> An attention KV cache is **positionally addressed** — row *i* is self-contained, so you can truncate
> at any *i*. An SSM / GatedDeltaNet / Mamba2 state is a **running scan**: one fixed-size tensor that
> is a lossy fold of every token seen so far. There is no row to drop, and to obtain the state as of
> token *k* you must re-run the scan from zero. So **linear-attention and hybrid models forfeit prefix
> caching entirely** and re-prefill every turn. Named in the source: **Qwen3.5, Qwen3.6 (GatedDeltaNet),
> LFM2.5, and Granite 4 (Mamba2)**.

That inverts the usual on-device folklore. Linear attention buys you O(1) decode memory and *pays for
it with multi-turn TTFT* — on a phone, where turn-2 latency is the felt metric, that can be the wrong
side of the trade even though the architecture looks strictly more efficient on paper. If you are
picking weights for a chat or agent feature, **"is it pure attention?" belongs on the same checklist
as context size and licence.**

> ⚠️ **SILENT FAILURE — an unsupported rewind degrades quietly.** `trimKVCache(to:)` returns a
> *negative* value when the engine cannot rewind, and the correct caller response is to `reset()` and
> re-feed everything. Nothing throws. You do not get an error, a warning, or a capability flag — you
> get a chat that was fast in testing on one model and takes twenty-three seconds per turn on
> another. **Log the reused-prefix length per turn**, the way the source's `PFXCACHE prompt=…
> reused=… ttft=…` line does, or you will not notice.

> ⚠️ **The API contract, because it is easy to get wrong even on a model that supports it.**
> `trimKVCache(to:)` returns the **actual** retained prefix, which may be `length - 1` because the
> last generated token's KV can lag one step behind. **Prefill from the returned value, not from the
> value you requested.** There is a second contract alongside it — `prefixReuseFeedsFullSequence` —
> deciding whether you hand the engine the full running sequence (it slices internally) or only the
> un-cached suffix. The sequential engine wants the former, the pipelined engine the latter.

**Attribution and limits, stated plainly.** All of the above is **community-measured and
community-implemented** in a fork of `apple/coreai-models`, not an Apple API and not an Apple claim.
The sequential-engine path is the measured one; the **pipelined implementation is symmetric but
UNVERIFIED** — the author could not exercise it because the pipelined variant SIGTRAPs in
`GrowingLogitsBuffer` for these bundles. Source: `notes/repos/john-rocky-models.md`. Full treatment
in [`provider-executor-store-and-kv-reuse`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/references/04-executor-lifecycle-and-kv-reuse.md)
and Part 3's context-and-KV-cache guide.

### 5.3 A note on multi-backend apps

(Not to be confused with the hybrid *models* of §5.2 — this is about apps that ship more than one
backend.)

The decision table is per-*feature*, not per-app, and the strongest evidence for that is that real
apps ship several backends at once. One shipping open-source iOS/macOS app in the corpus integrates
**six**: llama.cpp GGUF, MLX (mlx-swift + mlx-swift-lm), ExecuTorch, Core ML/ANE with stateful
`.mlmodelc` graphs, Apple Foundation Models (`SystemLanguageModel` on iOS 26+ **and**
`PrivateCloudComputeLanguageModel` on iOS 27+), and Core AI via Apple's vendored `coreai-models`
package on iOS/macOS/visionOS 27+. It targets iOS 18–27 simultaneously.

That is not indecision. It is what "different constraints for different features and different
device tiers" looks like in production, and the `LanguageModel` protocol is what makes it cheap.

The corresponding anti-pattern is picking one backend for the whole app on the basis of a headline
tok/s number. Which brings us to the numbers.

---

## 6. The honest performance picture

**Read this section header before the tables:** every number in §6 is **community-measured on beta
operating systems**, by one research group (the `apple-silicon-llm-bench` / `coreai-model-zoo`
project, MIT-licensed, by john-rocky / MLBoy). Apple has published no comparative benchmarks between
Core AI and MLX, and this guide does not invent any.

The reason to trust this source at all is its methodology hygiene, which is unusual: it publishes
fairness rules, keeps failed runs on the record, CI-checks that its README tables match its raw
JSONL, flags its own Debug-vs-Release capture contamination, and publishes at least three
self-corrections we can point at. The reason to still hold it loosely is that it is one group, on
beta OSes, and several of its own numbers moved between June and July 2026.

Apple's own published performance claims are separately marked below.

---

### 6.1 M4 Max: dense models tie or favour Core AI; MoE favours MLX

**Community-measured.** MacBook Pro **M4 Max 128 GB, macOS 27 beta**. Protocol: Apple's own
`llm-benchmark` defaults — **512-token prompt / 1024-token generation / 5 trials, release build**.
Core AI side = models exported with **Apple's official `coreai-models` recipes, unmodified**, run
with Apple's official runners. MLX side = **`mlx-lm` 0.31.3**, `mlx-community` weights.

> ⚠️ **All seven Core AI rows ran on the `coreai-pipelined` engine** — the fast one, which exposes no
> logits and therefore has no `@Generable` ([§5.1](#51-the-first-cliff-generable-and-the-fastest-engine)).
> If your feature needs guided generation, this table describes a configuration you cannot ship.

| Model | Arch | Artifact | Core AI decode (prefill) | MLX decode (prefill) | Verdict |
|---|---|---|---:|---:|---|
| gpt-oss-20b | **MoE**, MXFP4 | 13 GB | 78.1 (1,252) | **100.2** (1,528) | **MLX +28%** |
| qwen3-0.6b | dense | 335 MB | **484** (9,396) | 432 (9,366) | **Core AI +12%** |
| qwen3-4b | dense | 2.1 GB | 145.4 (**1,635**) | 145.8 (1,495) | tie |
| qwen3-8b | dense | 4.3 GB | **94.1** (912) | 90.0 (825) | **Core AI +5%** |
| gemma3-4b-it | dense | 2.1 GB | **141.5** (1,669) | 136.3 (1,631) | **Core AI +4%** |
| gemma3-12b-it | dense | 6.2 GB | 55.0 (**578**) | 55.1 (528) | tie |
| mistral-7b-v0.3 | dense | 3.8 GB | **101.7** (976) | 97.5 (918) | **Core AI +4%** |

The author's own read, and the noise floor:

> "**Core AI matches or beats MLX on every dense model; MLX's one clear win is the MoE** (expert
> dispatch, not the core engine). On noise: per-trial σ is ≤0.4% on 6 of 7 models (worst 1.3%) — the
> dense deltas are 10–30× trial noise with a consistent direction."

**Why MoE inverts.** The stock lowering for mixture-of-experts uses a `GatherMM` that reads *all*
experts per token — an over-read that MLX's sparse dispatch avoids. The same project measured the
fix: replacing stock `GatherMM` with a custom Metal `gather_qmm` kernel took LFM2.5-8B-A1B from
**39 → 141 tok/s (3.6×)** and Qwen3.6-35B-A3B from **30.9 → 64.9 (2.1×)** on M4 Max. Their conclusion
is the useful one: with the kernel you reach **parity, which is the ceiling — not a win**, because
"MLX's sparse dispatch is already good."

**The size trend, and the folklore correction.** An earlier snapshot of the same project showed Core
AI at **2.47×** MLX on Qwen3-0.6B and **1.05×** at Qwen3-8B, which produced a wave of "Core AI barely
edges out MLX at realistic sizes" coverage. That framing is correct in direction and the mechanism is
straightforward: small models are dispatch-bound (where Core AI's async overlap dominates), large
models are memory-bandwidth-bound (where everyone converges and MLX's 4-bit quantization erases the
gap).

> ⚠️ **Two attribution caveats on the 2.47× figure, both from the source itself.** First, the 1,121
> tok/s Core AI number in that comparison came from a **macOS 26–era export artifact**; a re-export on
> macOS 27 beta of the *same command* produced ~500 tok/s — see §6.5. Second, the corresponding
> iPhone "1.6×" figure was measured against a **Debug-build** MLX capture, and the author says so:
> "Release-build cold captures of the same model read 126–133 tok/s, so warm MLX on Release is likely
> ~130 and Core AI's warm lead nearer **~1.4×** than 1.6×."
> **Do not quote 2.47× or 1.6× without those caveats.**

> ⚠️ **A precision asymmetry inside this source.** One of its own methodology files says "**Core AI
> ships int8, MLX ships 4-bit** — so this is not an iso-precision comparison, it is a ship-config
> comparison", while its results table lists the `4bit` registry preset for the qwen3 rows. We could
> not reconcile these two statements from the notes we have. Read the table as **"Apple's shipping
> recipe vs MLX's shipping quantization"**, not as a controlled numerics experiment.

**The one-line rule the source distills, which is the actually useful output:**

> "**The difference is operator/architecture coverage on the engine — NOT the core engine.** On
> standard **dense** transformers Core AI's pipelined engine ties or beats MLX. Core AI only loses
> where the model uses an op-class the stock engine lowers *naively*."

Practically: dense → expect a tie-or-win from Core AI for free. MoE → budget a custom kernel or ship
at 0.5–0.78× MLX. Multi-head latent attention (MLA) → Core AI loses and the structural fix is
unsolved; ship for coverage or quality, not speed.

---

### 6.2 iPhone 17 Pro, matched bytes: throughput parity, and an energy inversion

This is the most decision-relevant single table in the corpus, because it is the only one that holds
model *bytes* roughly constant across three execution paths and measures energy alongside speed.

**Community-measured.** iPhone 17 Pro, **DeepSeek-R1-1.5B**, matched 4-bit bytes (ANE 0.97 GB /
Core AI GPU 0.95 GB / MLX 0.95 GB), **cold short-chat, median of 3**.

| Path | Decode tok/s | Energy (tokens per 1% battery) |
|---|---:|---:|
| **Core AI, ANE** | **83.3** | **6,144** |
| Core AI, GPU | 75.9 | 4,506 |
| MLX (mlx-swift, GPU) | 73.0 | 5,662 |

Three things fall out, and none of them is "X is faster than Y".

**1. Throughput is parity, not a win.** The 83.3 / 75.9 / 73.0 spread is ~14% top to bottom, and the
source is explicit that the sign of the ANE-vs-GPU delta **flips across sibling models** — i.e. this
is not a stable ANE speed advantage, it is noise around parity that happens to land ANE-first on this
model.

**2. The energy ranking is a different ranking.** ANE leads MLX by only **~+8.5%** on tokens per
battery percent — but it leads *Core AI's own GPU path* by **+36%**. Read that again: the second-place
energy finisher is **MLX**, and the worst of the three is Core AI on the GPU. If your mental model was
"Apple's framework is the efficient one", this table is the correction.

**3. The robust ANE advantage is not on this table at all.** The source's own summary:

> "the robust ANE win is **GPU exclusivity** (UI/rendering don't contend)."

That is the argument for the ANE that survives measurement. It is a *systems* argument, not a
throughput argument: while the model runs, your app's rendering, your Metal effects, and your
scrolling are not fighting it for the GPU.

> 🔴 **GAP — this table's underlying data file is not in the repository we read.**
> `coreai-vs-mlx-speed.md` lines 68–77 cite `litertlm-convert/reports/coreai-ane-gpu-parity-addendum.md`
> as the source of these numbers, and that file is **not present** in the cloned repo. So the numbers
> are attributed to a named researcher with a stated protocol, but the raw capture behind them is
> **unverified at source** — unlike the §6.1 table, whose JSONL is published and CI-checked.
> **Resolution:** ask the author, or re-measure. Treat these three rows as directionally useful and
> individually soft.

---

### 6.3 Three rankings from one device: burst, sustained, and joules

This is the section to internalise if you take nothing else from §6. **The ranking changes depending
on which axis you measure**, and every one of these axes is a real product constraint for somebody.

#### Axis 1 — burst throughput

Whoever wins the first thirty seconds. This is what every headline number is, and it is the least
representative of a shipped feature.

#### Axis 2 — sustained throughput (thermals)

**Community-measured.** iPhone 17 Pro, Gemma 4 E2B, **600 s of continuous generation**, cold
(`nominal`) start, unplugged, tg128, decode rate from a rolling window.

| Runtime / compute | Burst tok/s | Sustained (10 min) | Retained |
|---|---:|---:|---:|
| CoreML / **ANE** | 33 | **22** | **67%** |
| MLX / GPU | 48 | 18 | 38% |
| LiteRT-LM / GPU | 56 | 27 | 48% |

> "Run the same model **continuously** and it flips: the GPU runtimes (MLX, LiteRT-LM) heat up and
> shed **~50–60% of their throughput** under sustained load, while the **ANE barely moves** (retains
> ~65%). […] Two **independent** GPU runtimes collapsing the same way is a **GPU-thermal property of
> the phone, not a runtime quirk.** The GPU wins the sprint; the ANE wins the marathon — and it frees
> the GPU for the rest of the app."

The same source publishes a retention figure for Core AI's own path: **56%**.

> ⚠️ **Internal inconsistency in this source, flagged rather than resolved.** The table above puts
> MLX/GPU retention at **38%**, while a companion list of retention percentages across all measured
> arms gives **MLX-OptiQ 67% / MLX-PTQ 64%**. These are different captures of different builds and
> the source does not reconcile them. Take the *qualitative* finding — GPU paths throttle hard, the
> ANE does not — as well-supported, and treat any specific retention percentage as ±20 points.

#### Axis 3 — energy per token

**Community-measured.** M4 Max, Gemma 4 E2B, sustained-512, via `powermetrics` (whole-system package
power).

| Runtime | Avg package power (W) | Energy per 512-token run (J) | **J / token** |
|---|---:|---:|---:|
| **Apple Foundation Models** (system model) | 7.6 | 67.4 | **0.11** |
| mlx-swift (4-bit MLX) | 24.7 | 123.0 | 0.24 |
| llama.cpp (Q4_K_M GGUF) | 24.5 | 126.3 | 0.25 |
| coreml-llm (INT4 palettized, **ANE**) | 12.7 | 244.9 | 0.48 |

> "**Energy ranking inverts the decode-tok/s ranking.** Apple FM is 2× more efficient per token than
> the GPU-backed runtimes despite producing tokens at ~half the rate. **CoreML/ANE has the lowest
> *instantaneous* power (12.7 W) but is the *worst* J/tok at 4× Apple FM, because the slower decode
> (32 tok/s) keeps the package powered up much longer.**"

**Low power ≠ low energy.** That is the counterintuitive, load-bearing insight, and it is why "the
ANE is the efficient one" is only true when the ANE is also *fast enough*. A path that draws half the
watts but takes three times as long loses.

A separate, later capture of the same project (M4 Max, best-available builds, 2026-07-19,
decode-window J/token, warm loads) puts MLX on top of the Mac Pareto frontier outright: **MLX PTQ
4-bit at 0.090 J/tok, 14.6 W, and 177.8 tok/s** — fastest *and* most efficient, at the lowest package
power; with a patched Core AI int4 reference row at ~0.33 J/tok and 53 effective tok/s. The author's
summary: "**MLX owns the Mac energy Pareto.**"

#### Axis 4 — quality, which nobody measures and which dominates everything

The same project's seven-runtime iPhone 17 Pro table (Gemma 4 E2B, GSM8K n=100) is the only one in
existence that puts speed, memory, quality, and energy on one axis. Its verdict:

> "No runtime is Pareto-dominant once quality is on the table: **speed/memory/energy → LiteRT-LM,
> quality → MLX-OptiQ, balance → Core AI or Cactus-uncalibrated.**"

And the finding that should make you rethink your whole benchmarking plan: one runtime's *shipped
default* build scored **3.0%** on GSM8K while the build it had demoted scored **87.0%** — same speed,
same engine, different file. The author's line is the best one-sentence summary of on-device model
evaluation in 2026:

> "**'Which file did the runtime hand you' is worth 84 points** — the sharpest case yet for stating
> the build per row."

Separately: Google's own official QAT GGUF for Gemma 4 **does not load** — llama.cpp aborts on a
vocab defect. **Shipping an artifact is not the same as shipping a usable artifact.** Verify the
weights you downloaded actually produce correct output before you benchmark anything with them.

---

### 6.4 Why a tok/s number without a protocol is meaningless

The same artifact, on the same device, measured by the same person on the same day:

| Protocol | Decode tok/s |
|---|---:|
| 512-token prompt / 1024-token generation | 115 |
| 128-token prompt / 128-token generation | 184–190 (median 5 = 184) |

**A 1.6× swing from the measurement protocol alone.** Decode rate is context-length dependent: the
deeper the KV cache, the slower each token. And in the same capture, "later trials drop to ~125
thermally" — so even within one protocol, trial ordering matters.

Three consequences:

1. **Never compare two numbers whose protocols you cannot state.** Most of the numbers on the
   internet do not state theirs.
2. **Match the protocol to your feature.** If your feature is a 4,000-token document summary, a
   128/128 benchmark is fiction. If it is a chat reply, a 512/1024 benchmark understates you.
3. **Cold vs warm is a separate axis again.** Core AI's pipelined GPU engine pays a one-time
   kernel-compilation and pipeline-fill cost — community-measured at **71 tok/s on the very first
   generation, ~181 on every run after, including across app restarts.** Report both.

---

### 6.5 The artifact is not a function of the recipe

This is the biggest single gotcha in the corpus and it is a *build reproducibility* problem, not a
performance problem.

> "**`coreai.llm.export qwen3-0.6b` produced a 1,116 tok/s artifact when this repo's Mac numbers were
> first taken, and a ~500 tok/s artifact two days later — same command, same registry preset, same
> source checkout, same wheel versions, same machine. The only environment change in between was the
> macOS 26 → 27 beta upgrade.**"
> — community, `methodology/coreai-export-lowering.md`, investigation dated 2026-06-11

The forensics are specific and checkable. The fast artifact's program text contains plain `Linear$N`
composites and **zero quantization ops** — 4-bit weights consumed natively by the runtime's quantized
matmul path. The slow artifact contains `ParametrizedLinear$N` composites plus **141 ×
`constexpr_blockwise_shift_scale` ops** — explicit dequantize-then-matmul. Same 4-bit storage class
(327 MB vs 320 MB); the **compute path** differs 2.2×.

The decisive result is the one that rules out "you upgraded your wheels":

> "re-exporting on macOS 27β with `USE_LOCAL_COREAI=1` — i.e. the *byte-identical frozen wheel
> compiler that produced the fast artifact on macOS 26* — STILL yields the dequant-style artifact…
> Same pass code, different OS underneath, different lowering ⇒ **the fold decision consults the
> running OS (capability/target queries under the pass), not just the stack's own code.**"

Confirmed on device, too: the macOS-26 artifact measured **115.1 tok/s decode / 5,807 prefill /
0.22 GB** on iPhone 17 Pro versus the 27β artifact's **57.2 / 1,519 / 0.47 GB** — ~2× decode, 3.8×
prefill, half the memory, from the export *environment* alone.

**What to do about it, in the author's words:**

1. "**An `.aimodel` is a build artifact, not a pure function of the recipe.** Treat it like a
   compiled binary: version-stamp it, keep it, benchmark exactly what ships."
2. Record the artifact date and OS alongside every number.
3. "The effect is size-dependent: at 8B both artifact generations measure ~94 tok/s
   (bandwidth-bound); at 0.6B the lowering dominates (2.2×). **Small-model numbers are the canary.**"
4. "If you have a macOS-26-era artifact, **keep it** — as of the 27 beta we know no recipe flag that
   re-produces the native-quantized lowering."

> 🔴 **GAP — we do not know whether this was fixed.** The forensics are dated **2026-06-11**; this
> guide is written 2026-07-27, several betas later. Nobody in our corpus re-ran it.
> **Resolution:** export the same registry preset on a current macOS 27 beta, `strings` the resulting
> `main.mlirb`, and look for `constexpr_blockwise_shift_scale`. If it is absent, the regression is
> fixed and every §6.1 Core AI number in this guide is a floor, not a ceiling. This single fact
> changes advice in three guides.

---

### 6.6 What to actually take away from all of this

1. **There is no winner.** Core AI ties or beats MLX on dense models by 4–12% and loses MoE by 28%;
   MLX wins Mac energy outright; the ANE wins sustained throughput and GPU exclusivity and loses
   joules-per-token when it is slow; Apple's own system model is the energy champion at half the
   token rate. **Every one of those is the same hardware, measured on a different axis.**
2. **Pick your axis before you pick your backend.** Write down, in one sentence, which of burst
   throughput / sustained throughput / energy / memory / quality / TTFT your feature actually lives
   or dies on. Most features live on TTFT and quality, and neither appears in a tok/s headline.
3. **Deltas of 4–12% are not a reason to change frameworks.** They are smaller than the swing you get
   from a different measurement protocol (1.6×), a different export environment (2.2×), or a
   different downloaded file (84 GSM8K points).
4. **Measure the thing you ship, on the device you ship to, in a Release build.** Debug builds add
   large per-token host overhead and understate decode — this bit the benchmark author himself, and
   it is why one of his own MLX rows carries a public correction.
5. **Then measure quality with Evaluations**, because a fast wrong answer is not a feature.
   [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md).
6. **Two structural facts outrank every number above, because they are step functions rather than
   percentages.** Whether your backend can do `@Generable` at all ([§5.1](#51-the-first-cliff-generable-and-the-fastest-engine)),
   and whether your model's architecture permits prefix reuse
   ([§5.2](#52-the-second-cliff-prefix-reuse-and-the-models-that-cannot-have-it)). One decides whether
   your parsing layer exists; the other is worth ~101× on the latency your users actually feel. Settle
   both before you spend a day arguing about 4%.

Full treatment of measurement methodology, thermals, jetsam and energy:
[`on-device-memory-thermals-and-benchmarking`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md).

---

## 7. Silent failures you can hit before you write a line of model code

The defining property of this stack is that **most defects do not throw**. That is true at the
orientation level too — the following four will cost you a day each and none of them produces an
error. All four are backend-independent: they will happen behind any conformer you choose.

> ⚠️ **SILENT FAILURE — `prewarm` with a near-miss signature compiles and is never called.**
>
> `LanguageModelExecutor.prewarm(model:transcript:)` ships with a **default no-op extension**. If
> your implementation's signature does not match the requirement *exactly*, it does not become the
> protocol witness — the framework's no-op default wins instead, silently. Nothing warns you. Your
> `session.prewarm()` call appears to work and does nothing, and you discover it as "why is the first
> response always 3 seconds slow".
>
> Three independent sources say so. The MLX adapter's own comment is the most precise:
>
> > "The signature must match the requirement *exactly* — **concrete `Transcript`, not a generic
> > `some Collection<Transcript.Entry>`** — otherwise it fails to bind as the witness and the
> > framework's no-op default silently wins instead."
> > — `MLXLanguageModel.swift:901-907`
>
> And a community provider note reports the same class of bug **in Apple's own adapter today**:
> "Implement `prewarm(transcript:)` and it compiles but is never called. **Apple's own adapter has
> this today**, which is why `session.prewarm()` does nothing for Core AI models: do your own warm-up
> (a 1-token generate after load)."
>
> **How to detect it:** put a log line or a breakpoint in your `prewarm` and confirm it is reached.
> Do not infer it from timing.
>
> **A second layer to the same trap:** even a correctly-bound `prewarm` may not warm what you think.
> MLX's own code documents that loading weights is not sufficient — "Metal kernels **JIT-compile
> lazily on the first *synchronous* readback** […] so this runs a **minimal throwaway forward
> pass**", and its weights-only `preload()` is explicitly documented as leaving the shader-JIT cost
> on your first real request. And per session 339: "**`prewarm` isn't guaranteed to run.**" Design so
> that weights load exactly once *either way*.

> ⚠️ **SILENT FAILURE — a tool named in your instructions but absent from the toolset loops forever.**
>
> If your instructions text references a tool that is not in the session's `tools:` array, the model
> keeps trying to call it. The result is an infinite loop with **no error thrown**. WWDC26 session
> 243 uses exactly this as its worked debugging example, and the Foundation Models Instrument in
> Xcode 27 is how you see it. This is backend-independent — it will happen on any conformer.
> See [`fm-playground-and-instruments`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-05-prototyping-profiling-non-swift/references/01-playground-and-instruments.md).

> ⚠️ **SILENT FAILURE — `MLXFoundationModels` compiles out entirely on the 26 SDK.**
>
> The adapter is gated on `#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)`.
> `FoundationModelsIntegration` is a SwiftPM trait that is on by default, so it is *always* true —
> which means the only real gate is the second clause, the 27.0 SDK test. Build with Xcode 26 and the
> entire bridge disappears without a diagnostic; you get "cannot find `MLXLanguageModel` in scope",
> which reads like a missing dependency rather than a missing SDK. This is precisely what broke
> mlx-swift-lm's own nightly job on an Xcode 26.5 runner, and it is the answer to forum thread
> 836264.
>
> **Rule:** `canImport(FoundationModels, _version: 2)` is the reliable "am I on the 27 SDK" test.
> Detail in [`platform-and-version-gating`](02-platform-and-version-gating.md).

> ⚠️ **SILENT FAILURE — a response stream can finish having yielded zero partials.**
>
> If the model answers a turn with **only a tool call**, the stream completes without ever producing a
> partial response. Any UI that shows a spinner "until the first token" therefore hangs **forever** —
> not until a timeout, because nothing timed out and nothing threw. The stream ended normally with an
> empty yield count.
>
> > ✅ **VERIFIED (Apple sample code)** — Origami handles this case explicitly rather than assuming a
> > first partial arrives (`Origami/Coach/CoachModel.swift:67-72`). It is the only sample that does, and no
> > WWDC26 session mentions it.
>
> **How to detect it:** count the partials you consumed and branch on zero after the stream ends,
> rather than driving your loading state from "have I seen a token yet". This bites hardest on
> tool-heavy agent features — which is to say, exactly the features 2026 encourages you to build.
> See [`guided-generation-and-streaming`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md).

A fifth, less dramatic but very common: **`from: "1.0.0"` in `Package.swift` silently resolves to
nothing** for `apple/foundation-models-utilities`, because its only tags are prereleases and SwiftPM's
`from:` excludes those. You get a resolution failure that reads like a network problem. Pin
`exact: "1.0.0-beta3"` or a revision.

And a sixth that belongs to model selection rather than code: an unsupported KV rewind degrades to
full re-prefill without an error. See
[§5.2](#52-the-second-cliff-prefix-reuse-and-the-models-that-cannot-have-it).

---

## 8. Known-bad claims: material in circulation that is fabricated

This section exists because a research pass across ~14 community sources on this stack found that
**two of them are demonstrably fabricated** and a third uses a wrong file extension throughout. If
you search the web for "Apple Core AI tutorial", you will land on this material. So will your coding
agent. This is the inoculation.

### The blacklist

| Claim in circulation | Reality |
|---|---|
| Model format is **`.coreaimodel`** | It is **`.aimodel`** (portable source) and **`.aimodelc`** (AOT-compiled, one per device architecture). |
| Model format is **`.aiasset`** | Same. There is an `AIModelAsset` *type*, which is probably where the confusion started, but the file extension is `.aimodel`. |
| A CLI: `coreai-torch convert --model … --architecture transformer --output …` | **No such CLI.** `coreai-torch` is a **Python package**; the real API is `TorchConverter().add_exported_program(ep).to_coreai()`. |
| A CLI: `coreai-optimization quantize --model … --precision int4 …` | **No such CLI attested anywhere.** `coreai-opt` is a config-driven Python library. |
| Swift API `CoreAIModel(named:)` + `model.generate(prompt:parameters:)` returning `.text` | The real types are `AIModelAsset` / `AIModel` / `InferenceFunction` / `NDArray`. There is no `generate(prompt:)`. For text generation you use `CoreAILanguageModel` behind `LanguageModelSession`. |
| "Ships with **iOS 20, macOS 17**, iPadOS 20, visionOS 4" | **iOS 27 / macOS 27 / visionOS 27.** These version numbers do not exist. This line alone is disqualifying — it is a tell that the text was generated without grounding. |
| An **on-device LoRA training API**: `LanguageModelAdapter.train(examples:configuration:)`, `FineTuningExample(prompt:completion:)`, "training times under 10 minutes on A17 Pro", "adapter size capped at 50MB", `LanguageModelSession(adapter:)` | **Fabricated.** No other source in a 40-file, ~80,000-line research corpus mentions on-device LoRA training in Foundation Models, and no WWDC26 coverage does either. The article asserting it **self-declares AI authorship in its own footer.** Compounding the point: custom *pre-trained* adapters are being **discontinued** in OS 27 — the opposite direction of travel. |
| "Prerequisites: **Xcode 26.3 or later**" for the iOS 27 SDK | **Xcode 27.** |
| `AICacheModel` | A typo in one otherwise-careful article, which correctly hyperlinks `AIModelCache`. The type is **`AIModelCache`**. Do not propagate `AICacheModel`. |
| `LanguageModelSession.isAvailable` | Unverified and probably wrong. The documented pattern is `SystemLanguageModel.default.availability` (or `.isAvailable` on the *model*, not the session). |

### Two more that are illustrative sketches, not API

These appear in reasonable articles by authors who *labelled them as illustrative* — but the labels
get lost when the snippet is copied.

- `GeminiModel(apiKey: .keychain)` / `ClaudeModel(apiKey: .keychain)` — **not real type names.** The
  packages were announced, not shipped (§3.6). And session 339 explicitly recommends against an
  API-key-string initializer, so even the *shape* is unlikely.
- `AIModelAsset(url:)`, `function.descriptor.inputs.first!` — the author of these writes, in the code
  block itself, "Call shape is illustrative; confirm the exact initializer against Apple's docs."
  Honour that.

### How to spot the next one

Four heuristics, derived from the two fabricated sources:

1. **Impossible version numbers.** "iOS 20", "macOS 17", "Xcode 26.3 for the 27 SDK". A grounded
   author gets these right because they are everywhere in the real material.
2. **Benchmark tables with no methodology.** "iPhone 16 Pro: 15–25 tok/s" with no model named, no
   protocol, no build configuration, and no source. §6 should have convinced you that a number
   without a protocol is not a number.
3. **CLI syntax for a Python library.** `coreai-torch convert --flag` is the classic tell — LLMs
   pattern-match "ML conversion tool" onto "CLI with flags".
4. **APIs that solve exactly the problem the article is about, and that nobody else mentions.** An
   on-device fine-tuning API is what you would invent if you needed a satisfying ending. Cross-check
   any headline API against a second, independent source before you build on it.

### And one true claim that keeps getting reported as false

Neither `.coreaimodel` nor the fake LoRA API should make you dismiss the whole community corpus. The
single most useful cross-framework fact in the 2026 landscape — that
**`CoreAILanguageModel(resourcesAt:)` and `MLXLanguageModel(...)` unify Core AI and MLX under
`LanguageModelSession`** — was reported by community writers *before* it was easy to verify, and it is
correct: two independent articles showed it, and we have since read both types' source. Grade
sources, don't discard categories.

---

## 9. How to read this series

Seventeen parts is a lot. Nobody reads all of it. Find your goal below.

### "I want to add an AI feature to my Swift app"

The default path, and the one most readers want.

1. **[Part 1](../README.md)** — this guide, then
   [`platform-and-version-gating`](02-platform-and-version-gating.md). Do the gating one *before* you
   write code; version confusion is the largest source of phantom bug reports in the forums.
2. **[Part 2](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/README.md)** — sessions and prompting, guided
   generation, tools, and the failure taxonomy. If your feature is summarize/classify/extract/tag,
   Part 2 is very likely the whole job.
3. **[Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md)** — before you ship, not after. There is no model version
   pinning API; an evaluation suite is your only regression gate against an OS update.
4. **[Part 15](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/README.md)** — if you got as far as shipping weights.

Add **[Part 3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/README.md)** when your feature outgrows a single prompt:
context budgeting, KV-cache economics, Dynamic Profiles, and multi-step orchestration.

### "The built-in model isn't enough"

1. **[Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md)** — start with
   [`fm-private-cloud-compute`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md),
   because eligibility gates a large fraction of readers out entirely and the fallback is a different
   architecture. Then
   [`byo-model-behind-languagemodelsession`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md)
   for the consumer side of Core AI / MLX / chat-completions.
2. If you are *shipping* a model provider package rather than consuming one, the same part covers the
   protocol, capabilities, the generation channel, and executor/KV-cache lifecycle.

### "I have my own model and I need it on device"

The long road. It is sequential because the material is.

1. **[Part 7](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/README.md)** — the runtime object model, then specialization,
   caching and AOT. Read the AOT guide before you plan an iOS ship date.
2. **[Part 8](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/README.md)** — `coreai-torch`, the IO contract, op
   coverage, composites, externalization.
3. **[Part 9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md)** — quantization, palettization, pruning,
   and the numeric-format matrix.
4. **[Part 10](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-10-coreai-hardware-authoring-debugging/README.md)** — ANE-versus-GPU authoring rules
   (two *opposite* rulesets), the Core AI Debugger, and the LLM export path end to end.

Read Part 10's authoring guide **early** relative to the rest — it determines whether the rest of
the pipeline is worth running at all.

### "I'm a Python ML engineer and I just want to run models fast"

**[Part 12](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/README.md)**, in order: core fundamentals, numerics and hardware gating,
quantization, `mlx-lm`, serving and distributed, fine-tuning and porting. Then
**[Part 5](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-05-prototyping-profiling-non-swift/README.md)** if you want the `fm` CLI and the Python
SDK, and **[Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md)** because Apple's Python SDK is explicitly pitched at
evaluation pipelines.

### "I'm writing kernels"

**[Part 11](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-11-metal-and-tensorops/README.md)**, after
[`coreai-custom-metal-kernels`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/references/03-custom-metal-kernels.md)
in Part 8 so `TorchMetalKernel` is already established. Quantized tensors and MX scale planes first,
then cooperative tensors and FlashAttention.

### "I have a shipping iOS 26 app"

**[Part 17](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/README.md)**, then
[`platform-and-version-gating`](02-platform-and-version-gating.md). The two things most likely to
break you: custom adapters are discontinued in OS 27, and new enum cases (`Transcript.Entry.reasoning`
among them) break exhaustive switches when you rebuild against the 27 SDK.

### "I need to get from MLX to Core AI, or from one stack to the other"

**[Part 14](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-14-bridges-between-stacks/README.md)**.

### "I need speech, or something else adjacent"

**[Part 16](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/README.md)**. Note one known negative up front: **there is no
new text-to-speech API.** The WWDC26 keynote advertised improved speech *generation* in the
second-generation on-device model; Apple confirmed on the forums (thread 834149) that no new API
shipped, and directed developers to AVFoundation.

### Reading rules that apply everywhere

- **Believe the evidence markers.** A 🟡 signature is a shape you should sanity-check against your
  SDK, not a string to paste.
- **A 🔴 GAP is load-bearing information.** It tells you where to point your own investigation, and
  it is deliberately empty of guesses.
- **Check the version floor before you check anything else.** 26.0, 26.4 and 27.0 all matter.
- **Never quote a number from §6 without its protocol, hardware and date.**

---

## 10. What this guide could not verify

Collected here so downstream readers and agents do not mistake absence for nonexistence.

> 🔴 **GAP — is the core `FoundationModels` framework actually open source?**
> Session 241 announced it twice, explicitly ("the core of the FoundationModels framework will also be
> open source… a great solution for interacting with LLMs everywhere Swift runs, **including Linux
> servers**"). A search across `apple/*` and `swiftlang/*` on GitHub on 2026-07-27 found **no
> standalone repository for the core framework** — only `apple/foundation-models-utilities`,
> `apple/python-apple-fm-sdk`, and `apple/coreai-models`. The Linux claim currently rests on the
> *utilities* package's platform statement and its `#if canImport(FoundationNetworking)` guards.
> **Do not assert either way.** **Resolution:** check `github.com/apple` and `github.com/swiftlang`
> for a new repository; check whether the OS-shipped framework's `.swiftinterface` matches a public
> source tree.

> 🔴 **GAP (narrowed) — the exact `LanguageModelSession.init(model:...)` overload set on the 27 SDK.**
> Apple's reference page types the classic initializers against `SystemLanguageModel`; Apple's PCC
> article says you can pass any `LanguageModel` conformer to the same initializer; Apple's sample code
> instructs you to swap the model property to `PrivateCloudComputeLanguageModel` in one line, which
> only works if the generic overload exists — but ships the `SystemLanguageModel` configuration. See §1.
> **Resolution:** read `FoundationModels.swiftinterface` from an Xcode 27 SDK.

> 🔴 **GAP — whether proactive availability gating is still Apple's recommendation.**
> Both genuine iOS 27 samples omit `SystemLanguageModel.availability` entirely and handle
> unavailability reactively by catching `SystemLanguageModel.Error`; the iOS 26 sample gates
> proactively. No doc page or session retracts the availability guidance. This guide teaches both.
> See §3.1. **Resolution:** watch for a revision of Apple's availability article, or ask in a lab.

> 🔴 **GAP — Core AI has no Apple sample code at all.**
> An exhaustive sweep of Apple's `sampleCode` doc indexes found **zero sample projects for `coreai`**,
> against three for `foundationmodels` / `evaluations` / `corespotlight`. Every Core AI claim in this
> series is therefore doc-, transcript- or community-sourced — never confirmed against compiling
> first-party code, which is the evidence class that corrected 66 items elsewhere in this guide.
> Weight §3.3 and Parts 7–10 accordingly. **Resolution:** re-run the index sweep when a sample ships.

> ✅ **VERIFIED — the on-device model has a 4,096-token context per session.**
> Apple Technical Note TN3193 states the number and scope directly: instructions, prompts, tools,
> schemas, transcript history, and the response all share the same 4,096-token budget.[^tn3193-context]
> The uncorroborated 8,192-token source comment remains useful only as a reminder to read
> `SystemLanguageModel.default.contextSize` at runtime instead of hardcoding a policy decision.

> 🔴 **GAP — the on-device model's parameter count and quantization.**
> Community reverse-engineering puts Apple's on-device weights at roughly 2-bit base plus 4-bit task
> adapters; various articles assert "about 3B" and "20B sparse with 1–4B active" *in the same piece*.
> Apple has published no numbers we read. **Do not cite a parameter count for the system model.**
> A related consequence worth knowing: `FoundationModels` **does not expose a tokenizer**, so any
> tok/s figure measured against the system model by a third party is estimated (one harness uses
> `utf8.count / 4` and states ±20%).

> ✅ **MEASURED — and the beta/stable surfaces differ.** The project captured every help page on
> macOS 27 beta 5, then compared it with stable macOS 27 build `26A428` on 2026-09-16. Stable has
> a smaller surface that advertises only the `system` model. The canonical command comparison is
> [5.2 §3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#3--the-fm-help-surface-captured-on-macos-27).
> `--image`, `--label`, `--schema`, and the structured-schema grammar remain available. Interactive
> slash commands and field-level `serve` compatibility are still runtime gaps. See Part 5 §3 and
> `notes/PLATFORM-UPGRADE-VALIDATION-2026-09-16.md`.

> 🔴 **GAP — whether the macOS 26→27 export-lowering regression is fixed.** See §6.5.

> 🔴 **GAP — no first-party Anthropic or Google `LanguageModel` package located.** See §3.6.

> 🔴 **GAP — the raw data behind the iPhone matched-bytes table in §6.2** is not present in the
> repository that cites it.

> 🔴 **GAP — Core AI's error types.**
> No inference, specialization, or cache error type appears among the 312 indexed Core AI symbols;
> `AssetError` covers asset operations only. What `AIModel.init`, `loadFunction`, `run`, and cache
> deletion actually throw is unknown, which is a real problem for writing correct `catch` blocks.
> **Resolution:** device testing, or a newer SDK's `.swiftinterface`.

Two more honest notes about this guide's own sourcing:

- **Session 241 says "Our 2027 release."** Every OS reference in the same session is iOS 27 /
  macOS 27, and the session is WWDC26. Either Apple internally calls the OS-27 cycle "the 2027
  release", or it is a transcription artifact. This guide uses "iOS 27 / macOS 27" throughout and you
  should too.
- **Several WWDC transcript claims in this corpus are already superseded** by forum answers from
  Apple staff — custom adapters, PCC eligibility, the prescribed provider event ordering. Where they
  conflict, the series takes the forum answer and says so. That precedence order is in the
  [series README](../../README.md#precedence-when-sources-conflict).

---

## Where to go next

- **You are building a normal app feature:** [`platform-and-version-gating`](02-platform-and-version-gating.md),
  then [Part 2](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/README.md).
- **You already know you need your own weights:** [Part 7](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/README.md) for
  Core AI, or [Part 12](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/README.md) / [Part 13](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/README.md) for MLX.
- **You want to try a Hugging Face model in your app this afternoon:** `mlx_lm.server` +
  [`ChatCompletionsLanguageModel`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md).
- **You are about to quote a benchmark:** re-read [§6.4](#64-why-a-toks-number-without-a-protocol-is-meaningless).

---

*Last structural update: 2026-09-16. Written against iOS 27 / macOS 27, with beta-5 SDK evidence
and stable host/device runtime validation kept distinct. Every
measured number in §6 is community-measured on beta operating systems and should be re-verified
before it is quoted.*

[^tn3193-context]: Apple, [TN3193: Managing the on-device foundation model's context
    window](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window)
    (4,096 tokens per `LanguageModelSession`).
