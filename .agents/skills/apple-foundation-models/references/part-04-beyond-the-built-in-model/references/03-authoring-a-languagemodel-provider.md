# Authoring a `LanguageModel` provider package

**Part 4 · Beyond the built-in model · Reference 03**
**Version floor:** the `LanguageModel` and `LanguageModelExecutor` protocols, `LanguageModelCapabilities`,
`LanguageModelExecutorGenerationRequest`, `LanguageModelExecutorGenerationChannel`, `ContextOptions`
and `Transcript.AttachmentSegment` are **all 27.0 and only 27.0** (`Transcript.CustomSegment`
belonged to this list until Xcode 27 beta 5 — it is **not present in the beta 5 interface**; §13.2) —
**iOS 27.0 / iPadOS 27.0 / macOS 27.0 / visionOS 27.0 / watchOS 27.0**. There is **no tvOS**, and
**nothing in this guide back-deploys to 26.0, 26.1, 26.3 or 26.4**: on a 26.x SDK the symbols do not
exist at all, which is why every provider package in the corpus guards its adapter with
`#if canImport(FoundationModels, _version: 2)` rather than with `@available` alone. Build with
**Xcode 27**. The material below is verified against **Xcode 27 beta 3** era sources
(`apple/foundation-models-utilities` tag `1.0.0-beta3`, commit `376ca60`, 2026-07-10) — several
spellings changed between beta 1 and beta 3, and each one is flagged where it matters.

---

## What this covers

You are writing the Swift package that lets an app developer type

```swift illustrative
let session = LanguageModelSession(model: YourModel(…))
```

and get your inference engine — a local runtime, an OpenAI-compatible endpoint, your company's
frontier API — behind Apple's own session API, with dynamic profiles, tool calling, guided
generation, transcripts and Instruments support arriving for free.

This is the best-evidenced deep topic in the whole series, because Apple ships a **815-line agent
skill** on exactly this question (`skills/foundation-models-language-model-protocol/SKILL.md` in
`apple/foundation-models-utilities`) plus **two complete worked conformances you can read
line-by-line** — `ChatCompletionsLanguageModel` (953 lines, Apple, in the same repo) and
`MLXLanguageModel` (~2,900 lines, Apple/MLX, in `ml-explore/mlx-swift-lm`). A third, Apple's
`CoreAILanguageModel`, and a fourth, the community `ZooLanguageModel`, corroborate every member.

What follows:

- **The four steps from WWDC26 session 339** — packaging, implementing the protocol, authentication,
  customization — in Apple's own order, with the transcript's recommendations checked against what
  Apple's own shipping code actually does. They disagree in three places, and this guide says so.
- **Both protocols verbatim**, the associated-type machinery that links them, and why the split
  exists: `Configuration` is a cache key, and the framework — not you — owns executor lifetime.
- **`LanguageModelCapabilities`**: four capabilities, two initializers, and why declaring one you
  don't strictly support is a routing bug rather than a documentation error.
- **All seven fields of `LanguageModelExecutorGenerationRequest`** — including the three that Apple's
  own shipped conformance ignores entirely.
- **`ContextOptions` versus `GenerationOptions`** — what goes *into the prompt* versus what drives
  *the decoder loop*. This split is the single most useful mental model in the API and it is taught
  explicitly here.
- **Transcript translation**: six entry types in, your model's roles out, with two complete worked
  translators that disagree about what to do with prior reasoning.
- **The generation channel**: three top-level events, every action, `entryID` hygiene, the
  consecutive-only coalescing rule, and the *prescribed event order* — plus the beta-verified reason
  not to follow it literally.
- **Errors**: nine built-in `LanguageModelError` cases with construction examples, the
  approximate-or-throw rule, and the uncomfortable fact that Apple's own `ChatCompletions` executor
  throws none of them.
- **Authentication**: why `init(apiKey: String)` is the wrong primary path, and what to offer instead.
- **Customization**: response metadata, custom segments as the extension point for entirely new
  modalities, attachment segments, and the three-level server-side-tools disclosure pattern.
- **Testing**, in the three layers Apple prescribes, with the one detail that makes assertions
  compile.

## What this does *not* cover

Two provider topics are large enough to have their own guide, and this one only points at them:

- **The executor store, transcript diffing and KV reuse across turns** — how `Configuration` hashing
  produces executor sharing, how to diff the transcript you get on every call against the one you
  saw last time, and what that is worth (community-measured: turn-2 latency flat at ~0.33 s instead
  of growing with history). See
  [`04-executor-lifecycle-and-kv-reuse.md`](04-executor-lifecycle-and-kv-reuse.md).
- **Choosing a backend as an app developer** rather than authoring one. See
  [`02-bring-your-own-model.md`](02-bring-your-own-model.md).

## What you need

- **Xcode 27.** Not "Xcode 26 with a 27 deployment target" — the 27 **SDK**. The FoundationModels
  module has to export version 2 of its interface, and there is a machine-checkable test for that
  (§2.4).
- A real device or Mac for anything you intend to trust, and a plan for what your package does when
  the FoundationModels module is absent (Linux, or a 26 SDK) — §2.2 and §2.4.
- Read [`02-bring-your-own-model.md`](02-bring-your-own-model.md)
  first if you have never *consumed* one of these packages. This guide assumes you know what a
  `Transcript`, a `Tool`, `@Generable` and a `LanguageModelSession` are; Part 2 covers all four.

---

## Contents

1. [What you are actually building](#1-what-you-are-actually-building)
2. [Step 1 — Packaging](#2-step-1--packaging)
3. [Step 2 — The two protocols, verbatim](#3-step-2--the-two-protocols-verbatim)
4. [The minimum viable conformance — 40 lines, Apple's own](#4-the-minimum-viable-conformance--40-lines-apples-own)
5. [Capabilities: four flags that route requests](#5-capabilities-four-flags-that-route-requests)
6. [Reading a request: all seven fields](#6-reading-a-request-all-seven-fields)
7. [`ContextOptions` vs `GenerationOptions` — the split that matters](#7-contextoptions-vs-generationoptions--the-split-that-matters)
8. [Transcript translation: six entries in, your roles out](#8-transcript-translation-six-entries-in-your-roles-out)
9. [The generation channel: what flows out](#9-the-generation-channel-what-flows-out)
10. [The prescribed event order — and why not to follow it literally](#10-the-prescribed-event-order--and-why-not-to-follow-it-literally)
11. [Errors: approximate or throw](#11-errors-approximate-or-throw)
12. [Step 3 — Authentication](#12-step-3--authentication)
13. [Step 4 — Customization](#13-step-4--customization)
14. [Testing a provider package](#14-testing-a-provider-package)
15. [Quick reference](#15-quick-reference)
16. [Sources and evidence ledger](#16-sources-and-evidence-ledger)

---

## 1. What you are actually building

The pitch, in Apple's words, is that the model became a parameter. Five conformers shipped in the
27 cycle — `SystemLanguageModel`, `PrivateCloudComputeLanguageModel`, `CoreAILanguageModel`,
`MLXLanguageModel`, `ChatCompletionsLanguageModel` — and the session API did not change for any of
them.

> ✅ **VERIFIED** — WWDC26 session 339, *"Bring an LLM provider to the Foundation Models framework"*
> (Christopher Webb, Machine Learning Research), lines 10–12:
> *"And because these are built on top of a brand new **public protocol**, developers can bring
> frontier AI models into their apps using the same framework. **Anthropic and Google will soon
> extend the Foundation Models framework with Swift packages of their own**, making state-of-the-art
> Claude and Gemini models available to all Swift developers. Which ever model you use, Apple's,
> yours, or the community's, you call them the same way, because every model conforms to the
> Language Model protocol."*

Your package is a **translation layer**, and Apple says so in the first paragraph of the skill it
wrote for coding agents:

> ✅ **VERIFIED** — `skills/foundation-models-language-model-protocol/SKILL.md:9`:
> *"This skill teaches you how to build the open-source Swift package that bridges a server-side
> inference API to Apple's Foundation Models framework. The package is the **translation layer**
> between the framework's API and your inference endpoint. App developers import the package, name
> your model, and call the same `LanguageModelSession` API they use for the on-device model — your
> endpoint serves the request."*

And the target developer experience, verbatim from the same file (`SKILL.md:13-23`):

```swift illustrative
import MyLanguageModel

let model = MyLanguageModel(name: "your-model-id", baseURL: URL(string: "https://api.example.com")!)
try await model.authenticateIfNeeded()  // OAuth — user signs into their account

let session = LanguageModelSession(model: model)
let response = try await session.respond(to: "Plan a 4-day trip to Buenos Aires…")
```

> *"That's the whole developer surface. Same `LanguageModelSession` API as the on-device model. Your
> endpoint runs the inference."*

Note what is **not** in that snippet: no client object, no streaming setup, no transcript management,
no tool loop. All of that is the framework's, and the reason to write a `LanguageModel` conformance
rather than a plain SDK wrapper is precisely that you inherit it.

> ✅ **VERIFIED** — 339:23: *"And using a model built on top of the Language Model protocol means you
> get access to **all kinds of great Foundation Models features, like Dynamic Profiles**."*

### 1.1 The five things your package owns

Apple's own list, verbatim (`SKILL.md:27-33`), is a good scope check before you start:

> *"You own the package, ship it on GitHub (open source is encouraged), and maintain it. Specifically
> the package:*
>
> - ***Translates** the framework's API calls — conversation history, tool definitions, output schema
>   — into your inference API request shape.*
> - ***Declares** what your model supports — structured output, tool calling, thinking, multimodal —
>   via `LanguageModelCapabilities`.*
> - ***Owns authentication** — OAuth for end-user accounts, API keys for developer-paid usage, or
>   both.*
> - ***Surfaces errors** — including plan limits, with an upsell flow if you want to build one.*
> - ***Streams events** through the framework's executor channel."*

And one thing you explicitly do **not** own:

> ✅ **VERIFIED** — `SKILL.md:35`: *"If a developer asks for a capability you didn't declare (e.g.
> tool calling on a model that doesn't support it), the framework throws `unsupportedCapability` for
> you — you don't write defensive code for that."*

### 1.2 The four steps

Session 339 organises the work into four steps, and this guide follows that order because the
ordering is load-bearing: packaging decisions constrain what you can implement, and authentication
decisions leak into `Configuration`, which is part of the protocol.

> ✅ **VERIFIED** — 339:27–34, paraphrased tightly from the transcript:
>
> 1. **Packaging.** *"A well-crafted Swift package makes it easy for developers to get started."*
> 2. **Implement the protocol** — *"by defining the types that describe your model and the executor
>    that runs it."*
> 3. **Authentication** for server-based models, *"including some best practices."*
> 4. **Customization** — *"From attaching **response metadata**, all the way to defining entirely
>    **new modalities**."*
>
> *(The session's ASR renders "executor" as "EXECutor" throughout; the type is
> `LanguageModelExecutor`.)*

---

## 2. Step 1 — Packaging

### 2.1 SwiftPM, and the shape Apple recommends

> ✅ **VERIFIED** — 339:36: *"We recommend using **Swift package manager** so that developers can
> simply add your package as a dependency of their app. We'll cover how to set up `Package.swift`,
> and how to publish a release."*

Apple's skill ships a concrete `Package.swift` and a concrete directory layout. Both are worth
copying, because the layout encodes a testing strategy (§14): the request builder and the event
translator are separate files precisely so they can be unit-tested as pure functions.

> ✅ **VERIFIED** — `SKILL.md:661-682`, verbatim:
>
> ```
> MyLanguageModel/
> ├── Package.swift
> ├── README.md
> ├── LICENSE
> ├── Sources/
> │   └── MyLanguageModel/
> │       ├── MyLanguageModel.swift          // public model + LanguageModel conformance
> │       ├── MyExecutor.swift               // LanguageModelExecutor conformance
> │       ├── MyRequestBuilder.swift         // request → provider request body
> │       ├── MyEventTranslator.swift        // provider stream → channel events
> │       ├── MyClient.swift                 // transport layer (your choice)
> │       ├── Auth/
> │       │   ├── AuthMode.swift             // Hashable enum: .oauth(accountID:) / .apiKey(_)
> │       │   └── OAuthSession.swift         // browser flow, Keychain, refresh
> │       └── MyError.swift                  // custom errors → LanguageModelError mapping
> └── Tests/
>     └── MyLanguageModelTests/
>         ├── RequestBuilderTests.swift
>         ├── EventTranslatorTests.swift
>         └── ExecutorIntegrationTests.swift
> ```

The manifest, verbatim (`SKILL.md:686-708`) — note that the `platforms:` array is left as a comment
rather than filled in, and note the last line of the section:

```swift prelude:external-module
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "MyLanguageModel",
  platforms: [
    // The LanguageModel / LanguageModelExecutor protocols are available on
    // iOS 27, macOS 27, visionOS 27, and watchOS 27. Set your minimums at or
    // above those, plus whatever your transport/auth dependencies require.
  ],
  products: [
    .library(name: "MyLanguageModel", targets: ["MyLanguageModel"]),
  ],
  targets: [
    .target(name: "MyLanguageModel"),
    .testTarget(
      name: "MyLanguageModelTests",
      dependencies: ["MyLanguageModel"]
    ),
  ]
)
```

> ✅ **VERIFIED** — `SKILL.md:710`: *"`FoundationModels` is a system framework — no SwiftPM dependency
> declaration needed; just `import FoundationModels`. If your package depends on your own SDK as a
> downstream dependency, add it here normally."*

That is the one thing new authors most often get wrong: there is no `.package(url: …foundationmodels…)`
line to add. `import FoundationModels` and go.

Apple's own package fills in the platforms Apple's own way:

> ✅ **VERIFIED** — `apple/foundation-models-utilities`, `Package.swift:13-22, 33-37, 63`:
>
> ```swift
> // swift-tools-version: 6.2
> import PackageDescription
>
> let package = Package(
>   name: "foundation-models-utilities",
>   platforms: [
>     .macOS("27.0"),
>     .iOS("27.0"),
>     .visionOS("27.0"),
>     .watchOS("27.0")
>   ],
>   products: [ .library(name: "FoundationModelsUtilities", targets: ["FoundationModelsUtilities"]) ],
>   targets: [
>     .target(
>       name: "FoundationModelsUtilities",
>       dependencies: [],                                  // ← zero external dependencies
>       swiftSettings: [
>         .enableExperimentalFeature("InternalImportsByDefault"),
>         .enableExperimentalFeature("NonisolatedNonsendingByDefault"),
>         .enableUpcomingFeature("MemberImportVisibility")
>       ]
>     ),
>     …
>   ],
>   swiftLanguageModes: [.v6]
> )
> ```

Three things to steal from that manifest:

**Swift 6 language mode, package-wide.** `swiftLanguageModes: [.v6]`. Both protocols require
`Sendable`, the channel is `async`, and your executor will be called concurrently across sessions.
Turning strict concurrency on at the start is much cheaper than retrofitting it.

**`InternalImportsByDefault`.** This is why every source file in Apple's package annotates its
imports — `public import Foundation`, `public import FoundationModels`, `private import CoreImage`
(`ChatCompletionsLanguageModel.swift:12-20`). If a type from `FoundationModels` appears in your
public API — and it will: `LanguageModelCapabilities`, `Transcript`, `GenerationSchema` — that import
must be `public`. Without the feature flag you get this for free but also silently re-export
everything.

**Four platforms, no tvOS.** Apple ships iOS / macOS / visionOS / watchOS and omits tvOS. Whether
that is a deliberate exclusion or an oversight is not stated anywhere in the repository; the
FoundationModels framework's own availability annotations elsewhere in the corpus also stop at those
four. Do not assume tvOS works because you did not get a compile error — you will simply not be able
to declare the platform.

### 2.2 Should you support Linux?

This is the packaging decision with the largest gap between what the session says and what anyone
has actually proven.

> ✅ **VERIFIED** — 339:42, the sleeper announcement of the session: *"And because the **Foundation
> Models framework is being released as open source**, your package could also be useful to
> developers who **deploy Swift on their servers**, so consider supporting **Linux** too."*

Corroboration that the framework really is an open-source project, from a file header in Apple's own
test target:

> ✅ **VERIFIED** — `Tests/FoundationModelsUtilitiesTests/MockModel.swift:1-11`:
>
> ```
> // This source file is part of the Foundation Models open source project.
> // Copyright © 2024-2027 Apple Inc. and the Foundation Models project authors.
> // Licensed under the Apache License v2.0
> ```

So the intent is real and it is visible in shipped code. What is *not* real yet is proof that any of
it runs. Apple's own `ChatCompletionsLanguageModel` is structured for Linux in three specific ways,
all verifiable:

```swift compile:27
public import Foundation                       // ChatCompletionsLanguageModel.swift:12
#if canImport(FoundationNetworking)            // :13  ← exists only on non-Darwin
public import FoundationNetworking             // :14
#endif                                         // :15
public import FoundationModels                 // :16
#if canImport(CoreImage)                       // :17  ← Apple-only image encoding
private import CoreImage                       // :18
private import UniformTypeIdentifiers          // :19
#endif                                         // :20
```

`FoundationNetworking` is the swift-corelibs-foundation split-out module that exists *only* on
Linux and Windows. Its presence is the strongest machine-checkable signal of Linux intent anywhere
in the package. Beta 3 went further and **added** Linux-specific code — the non-Darwin image path
gained a `guard let url = image.url` (`:423`) that beta 1 did not have.

And yet:

> ⚠️ **The Linux claim is structurally supported and empirically unproven.** `README.md:10` of that
> package says *"Supported platforms: Apple platforms and select Linux distributions like Ubuntu"*,
> but the repository contains **no `.github/` directory, no CI workflow, no Dockerfile and no
> platform matrix** — verified by an exhaustive `find` over the working tree. Nothing in the repo
> demonstrates that the package compiles on Linux, and it requires a Linux `FoundationModels` module
> to exist, which is not evidenced anywhere in this corpus.

Two consequences you must design around if you take the Linux advice:

> ⚠️ **SILENT FAILURE — on non-Darwin, "streaming" is not streaming.** Apple's own executor forks the
> transport on platform (`ChatCompletionsLanguageModel.swift:587` / `:605`):
>
> ```swift
> #if canImport(Darwin)
> let (stream, response) = try await session.bytes(for: urlRequest)   // :588 — true incremental
> …
> for try await line in stream.lines { … }                            // :598
> #else
> let (data, response) = try await session.data(for: urlRequest)      // :606 — buffers EVERYTHING
> …
> for line in text.split(separator: "\n") { … }                       // :617
> #endif
> ```
>
> On Linux the whole response is buffered and then replayed as lines. A developer calling
> `session.streamResponse(to:)` gets a perfectly valid `AsyncSequence` that yields **every partial at
> once, after the request completes**. Nothing throws, nothing warns, and the UI just sits there for
> the full generation time before snapping to the final answer. This is not mentioned in that
> package's README. If you ship a Linux target, say this in yours.

The second consequence is subtler and concerns `@Generable`:

> 🔴 **GAP — whether guided generation works on Linux is unresolved.** In Apple's package, exactly
> three test suites carry `#if canImport(Darwin)` at file scope —
> `ChatCompletionsTests+StructuredOutput.swift:12`, `+ToolCalling.swift:12`, `+Reasoning.swift:12` —
> and the one thing those three have in common is that they use the **`@Generable` macro**. The six
> non-gated suites use none. That is a strong inference that `@Generable` (and therefore structured
> output and tool-argument schemas) is Darwin-only, but it is an inference from *which test files
> were gated*, not from any framework declaration. Resolving it needs a Linux build of
> `FoundationModels`, which does not exist in this corpus. **Safe default meanwhile:** if you ship a
> Linux target, declare `.guidedGeneration` and `.toolCalling` conditionally
> (`#if canImport(Darwin)`) rather than unconditionally, so a Linux consumer gets a clean
> `unsupportedCapability` from the framework instead of a mysterious macro-expansion failure at
> their call site.

### 2.3 Dependency weight

> ✅ **VERIFIED** — 339:43–45: *"Third, your dependencies. **Every dependency translates to bytes that
> a developer ships to their users. Carefully consider what dependencies are linked by your
> package.**"*

Apple takes its own advice to the extreme: `dependencies: []` in
`foundation-models-utilities/Package.swift:33`. The entire OpenAI-compatible client — SSE parser,
wire types, JSON coding, image encoding — is hand-written inside one 953-line file rather than
pulled from a package. That is not stylistic purity; a provider package sits at the *bottom* of the
dependency graph of every app that uses it, so a transitive dependency you take is one every one of
your consumers ships.

The counter-example in the corpus is instructive rather than damning. `mlx-swift-lm` cannot avoid
depending on `mlx-swift` and `swift-syntax`, so it does the next best thing and makes the heavy part
**optional at the manifest level**:

> ✅ **VERIFIED** — `ml-explore/mlx-swift-lm`, `Package.swift:44-59`, verbatim:
>
> ```swift
> traits: [
>     // Gates the MLXLanguageModel adapter for Apple's FoundationModels
>     // framework. Default-on. Disabling the trait compiles MLXFoundationModels
>     // to an empty library: the entire `MLXLanguageModel` / `MLXLanguageModel.Executor`
>     // surface requires FoundationModels types that are not available on platforms
>     // older than iOS/macOS/visionOS 27.0, and the MLXDownloadProgress observable
>     // (whose only producer is that adapter) is gated alongside it. Consumers
>     // targeting older OS versions can still use this package for MLXLLM /
>     // MLXLMCommon / MLXEmbedders etc. by turning the trait off.
>     .trait(
>         name: "FoundationModelsIntegration",
>         description:
>             "Enables the MLXLanguageModel adapter for Apple's FoundationModels framework. Disabling removes the MLXLanguageModel / MLXLanguageModel.Executor types."
>     ),
>     .default(enabledTraits: ["FoundationModelsIntegration"]),
> ],
> ```

**SwiftPM traits are the right tool when your provider adapter is a small part of a larger package.**
A consumer on iOS 26 turns the trait off and keeps using the rest.

> ⚠️ Do not confuse this with a claim you may read elsewhere. Apple's *other* agent skill,
> `skills/foundation-models-utilities/SKILL.md:9-17`, describes `foundation-models-utilities` as
> having "three independent feature areas, each guarded by its own SwiftPM trait" with source files
> gated by `#if ChatCompletions`, `#if Skills` and `#if History`. **None of that exists.**
> `Package.swift` declares no `traits:` and there is not one such `#if` in any source file. That
> skill was written against beta 1 and never updated; §16 lists the other seven places it is stale.

### 2.4 Gating on the SDK, not just the OS

`@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)` tells the *compiler on a 27 SDK* that a symbol
is 27-only. It does nothing for someone building your package with the **26 SDK**, where
`FoundationModels` either does not exist or exports an older interface. You need a second gate.

> ✅ **VERIFIED** — `ml-explore/mlx-swift-lm`, `Libraries/MLXFoundationModels/TranscriptConverter.swift:3-4`
> and `Libraries/MLXHuggingFace/FoundationModelsMacros.swift:3`, the pattern used at the top of
> every FoundationModels-touching file in that repo:
>
> ```swift
> #if FoundationModelsIntegration
> #if canImport(FoundationModels, _version: 2)
>
> import Foundation
> import FoundationModels
> …
>
> @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
> struct TranscriptConverter { … }
> ```

`canImport(FoundationModels, _version: 2)` is true **only on the macOS/iOS/visionOS 27.0 SDK**. On
the 26 SDK the adapter compiles out to an empty library, and the package still builds. The design
intent is stated in the manifest itself (`Package.swift:243-249`):

> *"Public surface is gated by `@available(macOS 27 / iOS 27 / visionOS 27, *)` and
> `#if canImport(FoundationModels)`, so the target builds on every Xcode that compiles the rest of
> mlx-swift-lm."*

This is not theoretical. It is the subject of a real, dated CI failure:

> ✅ **VERIFIED** — commit `3cbf928`, *"Integration tests: build on both macOS 26 and 27 SDKs (#464)"*,
> message verbatim:
>
> > *"The nightly IntegrationTesting job failed to compile on the Xcode 26.5 runner: the
> > FoundationModels adapter (MLXFoundationModels) is gated behind
> > `canImport(FoundationModels, _version: 2)` (macOS 27 SDK only), but the integration test files
> > gated only on the always-set FoundationModelsIntegration trait, so they referenced symbols absent
> > on the 26 SDK."*
> >
> > *"Extend the 37 FoundationModels-gated test files' top-level guard to
> > `#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)`, mirroring the
> > library so they compile out on the 26 SDK and stay active on 27."*

**Gate your tests exactly the way you gate your library.** A trait alone is not an SDK check: the
trait is always on, so files guarded only by the trait reference symbols that may not exist.

Two more consequences of SDK gating worth knowing before you hit them:

- **Your DocC catalog may be unbuildable on older SDKs.** `mlx-swift-lm`'s `scripts/verify-docs.sh`
  explicitly **filters `MLXFoundationModels` out** of documentation verification, with the reason
  in-line: *"gated on the FoundationModels v2 SDK, so its DocC catalog can't be verified on SDKs
  that lack it."* Its `.spi.yml` likewise lists only the four non-FM targets as
  `documentation_targets`, so Swift Package Index never renders the adapter's docs.
- **API drift between betas is real and it breaks builds, not just behaviour.** Three commits in
  that repo exist solely to chase it: `2a76e56` (*"FoundationModels renamed
  `GenerationOptions.SamplingMode.Kind`'s `.top`/`.nucleus` cases to
  `.randomTopK`/`.randomProbabilityThreshold`, which broke compilation against the newer SDK"*),
  `9cd1a48` (*"Fix FoundationModels API drift and the integration tests that no longer compiled"*),
  and `1c86cc1`, which is a runtime crash rather than a compile error and gets its own callout in
  §9.7.

### 2.5 Publishing: your repo URL is the distribution channel

> ✅ **VERIFIED** — 339:46–49: *"Publishing your package is as easy as **creating a git tag**. Swift
> Package Manager is **decentralized, so your repo URL is your distribution channel.** Developers can
> paste the URL into Xcode and start integrating your model into their apps. For more, see
> '**Creating Swift Packages**'."*

There is no registry step, no submission, no review. Tag it and it exists.

Which makes the following mistake, in Apple's own repository, an unusually good teaching example:

> ⚠️ **The prerelease-tag trap — a dependency line that resolves to nothing.**
> `apple/foundation-models-utilities/README.md:30` tells consumers to write
>
> ```swift
> .package(url: "https://github.com/apple/foundation-models-utilities", from: "1.0.0")
> ```
>
> but the only tags that exist are `1.0.0-beta1` and `1.0.0-beta3` (`git ls-remote --tags`).
> **SwiftPM's `from:` requirement excludes prereleases**, so that line matches no version at all.
> A consumer has to write `exact: "1.0.0-beta3"`, or pin a branch or revision, until a stable tag
> ships.
>
> If your package is in beta, **document the `exact:` form in your README** and switch to `from:`
> only when you cut a non-prerelease tag. Test the copy-paste line in a scratch package before you
> publish it; this one shipped.

A second, smaller one from the same README, worth mentioning only because it is the *first* code
sample a reader sees: `README.md:52` and `:67` both write
`URL(string: "http://localhost/v1:8000")!` — the port is inside the path. The host is `localhost` on
port 80 and the request goes to `http://localhost/v1:8000/v1/chat/completions`. The intended URL was
`http://localhost:8000/v1`. **Round-trip your README's URLs through `URLComponents` in a test.**


---

## 3. Step 2 — The two protocols, verbatim

> ✅ **VERIFIED — the complete declarations, quoted from Apple's own skill,
> `skills/foundation-models-language-model-protocol/SKILL.md:41-59`:**
>
> ```swift
> public protocol LanguageModel: Sendable {
>   associatedtype Executor: LanguageModelExecutor where Executor.Model == Self
>   var capabilities: LanguageModelCapabilities { get }
>   var executorConfiguration: Executor.Configuration { get }
> }
>
> public protocol LanguageModelExecutor: Sendable {
>   associatedtype Configuration: Hashable & Sendable
>   associatedtype Model: LanguageModel
>   init(configuration: Configuration) throws
>   func respond(
>     to request: LanguageModelExecutorGenerationRequest,
>     model: Model,
>     streamingInto channel: LanguageModelExecutorGenerationChannel
>   ) async throws
>   func prewarm(model: Model, transcript: Transcript)  // default no-op
> }
> ```

That is the whole thing: **two protocols, five requirements, one linking type.** Everything else in
this guide is about the values that flow through `respond`.

An independent reading agrees on every member. A community author read the same declarations
directly out of the macOS 27 beta `FoundationModels.swiftinterface` and recorded them as:

```swift illustrative
protocol LanguageModel: Sendable {
    associatedtype Executor: LanguageModelExecutor where Self == Executor.Model
    var capabilities: LanguageModelCapabilities { get }
    var executorConfiguration: Executor.Configuration { get }
}

protocol LanguageModelExecutor: Sendable {
    associatedtype Configuration: Hashable, Sendable
    init(configuration: Configuration) throws
    func prewarm(model: Model, transcript: Transcript)
    nonisolated(nonsending) func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: Model,
        streamingInto channel: LanguageModelExecutorGenerationChannel) async throws
}
```

> ✅ **The dispute is now settled first-hand (2026-07-29): this repo holds the interface.** The
> declarations, read verbatim from
> `notes/sdk-interfaces/FoundationModels-27.0-macos.swiftinterface:1481-1487` and `:1709-1719`:
>
> ```swift
> public protocol LanguageModel : Sendable {
>   associatedtype Executor : LanguageModelExecutor where Self == Self.Executor.Model
>   var capabilities: LanguageModelCapabilities { get }
>   var executorConfiguration: Self.Executor.Configuration { get }
> }
> public protocol LanguageModelExecutor : Sendable {
>   associatedtype Configuration : Hashable, Sendable
>   associatedtype Model : LanguageModel
>   func prewarm(model: Self.Model, transcript: Transcript)
>   init(configuration: Self.Configuration) throws
>   nonisolated(nonsending) func respond(to request: LanguageModelExecutorGenerationRequest,
>       model: Self.Model, streamingInto channel: LanguageModelExecutorGenerationChannel) async throws
> }
> ```
>
> Rulings, against the real text: the `where` clause is `Self == Self.Executor.Model` (the two
> orderings were indeed the same constraint); `nonisolated(nonsending)` **is** in the SDK's
> `respond` requirement (the skill omitted it — both spellings still compile as witnesses, since
> the module enables `NonisolatedNonsendingByDefault`, interface line 3); the skill was right that
> `associatedtype Model : LanguageModel` is explicit; `init(configuration:)` **is `throws`**; and
> the default `prewarm` implementation exists in an extension (`:1907` — body not emitted;
> the skill documents it as a no-op). Both protocols are
> `@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)`, tvOS unavailable.

### 3.1 Why the split exists

You could imagine one protocol with a `respond` method on the model. Apple deliberately did not do
that, and the reason is lifetime.

> ✅ **VERIFIED** — 339:52–58: *"The protocol has **two key pieces**. The first is `LanguageModel`. It
> **describes the model to the framework**. It declares **what the model can do, through
> capabilities**, and provides the **configuration** the framework needs to set up the model's
> executor. … The second piece is `LanguageModelExecutor` where the work happens. It has **an
> initializer that takes a `Configuration`**, a **`prewarm`** function for preparing resources ahead
> of the first request, and a **`respond`** function that **streams generation back to the session**.
> … **The `Configuration` is what links the two types: the Model provides it, and the framework uses
> it to construct the executor.**"*

and, the sentence that explains the shape of every conformance in this corpus:

> ✅ **VERIFIED** — 339:67–71: *"Here's a `LanguageModel` implementation. It declares its capabilities
> and returns the configuration the framework uses to find its executor. **The Executor is where the
> real work lives, loading weights, managing resources, and streaming tokens back to the session.**
> The framework constructs it from a configuration your model provides, then hands **the model in on
> every request**. **That split is what keeps your Model trivial to construct.**"*

**Your model type is a description; your executor type is a machine.** A developer may construct
your model type in a SwiftUI `body`, in a `@State` initialiser, or once per keystroke. If
constructing it opened a connection or mmapped weights, that would be a disaster. Because it is
*just* a description that vends a `Configuration`, the framework can construct it as often as it
likes and still hand you exactly one executor.

Apple's skill states the same division as a table (`SKILL.md:61-65`):

| Type | Purpose |
|---|---|
| `MyLanguageModel: LanguageModel` | *"The user-facing model description — capabilities, model id, auth state. Lightweight and `Sendable`."* |
| `MyLanguageModel.Executor: LanguageModelExecutor` | *"Does the actual work — opens the stream, translates events."* |
| `MyLanguageModel.Executor.Configuration: Hashable & Sendable` | *"Snapshot of everything the executor needs. The framework caches one executor per unique configuration, so equality matters — only put Hashable primitives in here."* |

### 3.2 `Configuration` is a cache key, and that is a design constraint

The mechanism is narrated in the session as an animated diagram; the consequence is what you need.

> ✅ **VERIFIED** — 339:59–66: *"Each **session holds an executor store**. When Model1 arrives, the
> framework checks the store using the model's configuration, but there's no matching executor. So,
> the `LanguageModelSession` creates a new executor and stores it. **Model2 produces the same
> configuration, and because `Configuration` is `Hashable`, the framework knows it matches, and
> resolves to the same executor. The configuration is the lookup key, not the model.** Model3
> produces a different configuration, so it gets its own executor. **Each unique configuration maps
> to exactly one executor in the store.**"*

Three rules follow, and Apple states all three explicitly:

> ✅ **VERIFIED** — `SKILL.md:127`: *"The executor does the actual work. The framework caches one
> executor per unique `Configuration`, so make `Configuration` hold only Hashable primitives that
> identify the network endpoint and credential — **NOT opaque store objects whose equality is
> unclear, and NOT per-request data**."*
>
> and `SKILL.md:814` as a numbered pitfall: *"**Configuration must hold only Hashable primitives.**
> Don't put opaque store objects or class references in there — the framework hashes Configuration
> to cache executors."*

What "identifies" your executor is: the endpoint, the model id, the credential identity, and
anything that changes behaviour. Not the request. Not a logger. Not a `URLSession`.

Apple's own executor demonstrates the awkward case — it *does* need to hold a `URLSession` (a class,
with reference identity) for test injection, so it writes `Hashable` by hand and leaves the session
out:

> ✅ **VERIFIED** — `ChatCompletionsLanguageModel.swift:195-212`, verbatim:
>
> ```swift
> public struct Configuration: Hashable, Sendable {
>   fileprivate let modelName: String
>   fileprivate let url: URL
>   fileprivate let additionalHeaders: [String: String]
>   fileprivate let urlSession: URLSession?
>
>   public static func == (lhs: Configuration, rhs: Configuration) -> Bool {
>     lhs.modelName == rhs.modelName
>       && lhs.url == rhs.url
>       && lhs.additionalHeaders == rhs.additionalHeaders
>   }
>
>   public func hash(into hasher: inout Hasher) {
>     hasher.combine(modelName)
>     hasher.combine(url)
>     hasher.combine(additionalHeaders)
>   }
> }
> ```

This is a legitimate and widely-copied pattern — the community `ZooExecutor.Configuration` does the
same thing to smuggle `any InferenceEngine`, `any Tokenizer` and `any PromptDialect` past the
`Hashable` requirement by hashing `modelID` alone. But you should understand what you are buying:

> ⚠️ **SILENT FAILURE — a hand-written `==` that ignores a behavioural field makes the framework hand
> you back the wrong executor.** In the code above, two `ChatCompletionsLanguageModel` values that
> differ *only* in `urlSessionConfiguration` (added in beta 3 to let callers tune timeouts and
> proxies — `ChatCompletionsLanguageModel.swift:78`) compare **equal** and hash **the same**. Within
> one session's executor store the second model therefore resolves to the executor built with the
> **first** model's `URLSession`. Your 600-second timeout silently becomes the other model's 60. No
> error, no log, no warning — and the symptom appears only when two models coexist in one session,
> which is exactly what dynamic profiles encourage.
>
> **The rule this teaches:** every field that changes runtime *behaviour* must participate in `==`
> and `hash(into:)`. If a field is not `Hashable`, hash a stable proxy for it — a name, an id, a
> configuration hash you compute yourself — rather than dropping it. Dropping it is a correctness
> bug, not a style choice.

How far the framework will go to keep `Configuration` hashable is visible in a *deleted* file. Before
beta 3, `foundation-models-utilities` shipped a hand-rolled `AnyLanguageModel` type-eraser (92 lines,
`git show a047a50:…/DynamicProfile+LanguageModel.swift`), removed once the framework shipped
`.model(any LanguageModel)` itself. Its trick:

```swift compile:27
private struct Metatype: Hashable, Equatable, @unchecked Sendable {
  private let type: UnsafeRawPointer
  init(_ swiftType: Any.Type) { type = unsafeBitCast(swiftType, to: UnsafeRawPointer.self) }
  var swiftType: Any.Type { unsafeBitCast(type, to: (Any.Type).self) }
}
```

`unsafeBitCast` of a metatype to a raw pointer, purely to obtain `Hashable`. That is how load-bearing
`Configuration: Hashable` is.

At the other extreme, the smallest legal `Configuration` in the corpus is one string:

> ✅ **VERIFIED** — `MLXLanguageModel.swift:876-880`:
>
> ```swift
> /// Configuration for creating and caching executors.
> public struct Configuration: Hashable, Sendable {
>     /// The model identifier this executor uses for loading and metadata.
>     public let modelID: String
> }
> ```

MLX gets away with one field because its weights live in a **process-global** `static let cache =
ModelCache()` outside the executor entirely (`MLXLanguageModel.swift:351`) — a deliberate opt-out
from the framework's session-scoped teardown, for a reason its doc comment states plainly:
*"Without caching, model loading takes 2-30 seconds per request."* (Apple/MLX-published figure, no
hardware or OS stated; treat it as an order of magnitude, not a benchmark.) That trade-off, and the
`evictAll()` / `evict()` APIs it forces you to add, belong to
[`04-executor-lifecycle-and-kv-reuse.md`](04-executor-lifecycle-and-kv-reuse.md).

### 3.3 Lifetime: the framework does the teardown

> ✅ **VERIFIED** — 339:72–74: *"**When the session deallocates, the store goes with it. Every stored
> executor gets released, your `deinit` runs, weights are freed, and connections closed, all
> automatically. You don't write any of that teardown code yourself.**"*

Believe this for anything you own *inside* the executor. Do not believe it for anything you park in
a `static` — see the MLX note above.

### 3.4 `init(configuration:) throws` — and the non-throwing witness

The protocol requirement throws. Apple's own conformance does not:

```swift prelude:guide-context
public init(configuration: Configuration) {          // ChatCompletionsLanguageModel.swift:191
  self.configuration = configuration
}
```

That is legal: Swift allows a non-throwing function to witness a `throws` requirement (the reverse is
not allowed). Apple's test mocks use the `throws` form (`MockModel.swift:62`), so both appear in the
same repository. Use `throws` when you have something to validate:

> ✅ **VERIFIED** — `SKILL.md:143-149`, Apple's own comment on what belongs in this initialiser:
>
> ```swift
> public init(configuration: Configuration) throws {
>   self.configuration = configuration
>   // Validate configuration here if useful (e.g. malformed URL, missing
>   // required fields) and throw on bad input. Stand up any per-executor
>   // resources you want to reuse across requests (HTTP client, gRPC stub,
>   // vendored SDK handle — your choice).
> }
> ```

Note the second half: **per-executor resources belong here**, because "per executor" is exactly "per
unique configuration, for the lifetime of the session."

### 3.5 `prewarm` — and the single worst footgun in the protocol

> ✅ **VERIFIED** — 339:75–82: *"Within that lifecycle, your executor has one more function:
> **`prewarm`**. Before a request arrives, the developer can ask the framework to prewarm. It's your
> chance to do **expensive setup ahead of time, like loading weights, opening connections, or
> anything that would otherwise slow down that first response.** One approach is to put that setup in
> a **private helper that loads the weights once and caches them**. `prewarm` calls the helper
> **eagerly**, so the weights are ready before the first request arrives. **But `prewarm` isn't
> guaranteed to run.** Either way, weights load exactly once, and **if your executor has no expensive
> setup, like a server-backed model, `prewarm` can simply be a no-op.**"*

Two structural facts the transcript does not say:

**It is synchronous and non-throwing.** `func prewarm(model: Model, transcript: Transcript)` — no
`async`, no `throws`. Every real implementation therefore spawns a detached `Task` and swallows the
error:

> ✅ **VERIFIED** — `MLXLanguageModel.swift:920-930`:
>
> ```swift
> public func prewarm(model: MLXLanguageModel, transcript: Transcript) {
>     Task {
>         do {
>             try await model.warmUp()
>         } catch {
>             Self.logger.error(
>                 "MLX prewarm failed for \(model.modelID, privacy: .public): \(error.localizedDescription, privacy: .public)"
>             )
>         }
>     }
> }
> ```
>
> and Apple's `CoreAIExecutor` does the same thing in one line
> (`CoreAILanguageModel.swift:269-271`): `Task { try? await resources.loadResources() }`.

MLX's own comment on that logger is worth reading, because it tells you what your users will
experience when prewarm fails (`MLXLanguageModel.swift:890-895`): *"A failed warmup is otherwise
invisible (no throw reaches the caller), so this is the only diagnostic surface for a
persistently-failing prewarm (bad id, network gone, OOM). Note it cannot intercept a Metal
command-buffer assertion abort — that is a process crash, not a catchable Swift error."*
**Log inside your `Task`. There is nowhere else for the error to go.**

**And it has a default no-op implementation** — which is where the footgun lives.

> ⚠️ **SILENT FAILURE — the near-miss `prewarm` signature.** `prewarm(model:transcript:)` ships with a
> default no-op extension. If your implementation's signature does not match the requirement
> **exactly**, it does not fail to compile and it does not warn: it simply becomes an ordinary method
> on your type that nothing ever calls, and the framework's no-op default binds as the witness
> instead. `session.prewarm()` then does nothing, forever, silently.
>
> Three independent sources say so, one of them about Apple's own code:
>
> - ✅ **VERIFIED** — `MLXLanguageModel.swift:902-906`: *"This is the protocol witness for
>   `LanguageModelExecutor`'s `prewarm(model:transcript:)`. **The signature must match the requirement
>   *exactly* — concrete `Transcript`, not a generic `some Collection<Transcript.Entry>` — otherwise
>   it fails to bind as the witness and the framework's no-op default silently wins instead.**"*
> - **Community-measured**, `fm-provider.md:183-186` (verified 2026-06-11, macOS 27 beta, M4 Max):
>   *"Implement `prewarm(model:transcript:)` **exactly** — implement `prewarm(transcript:)` and it
>   compiles but is never called. **Apple's own adapter has this today**, which is why
>   `session.prewarm()` does nothing for Core AI models: do your own warm-up (a 1-token generate after
>   load)."*
> - The community `ZooExecutor.swift:68-70` carries the same warning in a comment: *"the protocol
>   ships a default no-op, so a near-miss compiles and is silently never called."*
>
> **How to defend against it.** There is no compiler diagnostic to enable. Write a test: give your
> executor a counter (an `atomic`, a `Mutex<Int>`, an `actor`), call `session.prewarm()` through the
> real `LanguageModelSession` API, and assert the counter moved. That test takes ten lines and is the
> only thing standing between you and a warm-up path that has never once executed.
>
> The temptation to write the generic form is real, because `Transcript` *is* a
> `Collection<Transcript.Entry>` and `some Collection<Transcript.Entry>` looks more idiomatic. Resist
> it here.

One more subtlety, from the implementation that thought hardest about it: **loading weights is not
warming up.**

> ✅ **VERIFIED** — `MLXLanguageModel.swift:573-576`, on the weights-only path: *"This is a
> weights-only load: it runs no forward pass, compiles no Metal shaders, and performs no GPU work, so
> **the first generation request after `preload()` still pays the one-time Metal shader JIT cost.**"*
> and `:598-601` on why the real warm-up runs a throwaway generation: Metal kernels *"JIT-compile
> lazily on the first **synchronous** readback (`.item()` inside the generate loop) — scheduling work
> with `asyncEval` alone does not compile them — so this runs a **minimal throwaway forward pass**."*
>
> If your backend has a compile-on-first-use stage — Metal shaders, a Core AI specialization, a JIT,
> a TLS handshake, a cold Lambda — **prewarm must exercise it, not merely allocate it.** One token of
> real generation is the cheapest honest warm-up.


---

## 4. The minimum viable conformance — 40 lines, Apple's own

Before the 953-line one, here is the smallest complete conformance in the corpus. It is Apple's own
test mock, and it compiles, runs through a real `LanguageModelSession`, and handles a full
tool-calling round trip. If you read one code listing in this guide, read this one.

> ✅ **VERIFIED** — `apple/foundation-models-utilities`,
> `Tests/FoundationModelsUtilitiesTests/MockModel.swift:12-102`, verbatim (comments abridged where
> marked):

```swift compile:27
import Foundation
import FoundationModels

struct MockModel: LanguageModel {
  typealias Executor = MockModelExecutor

  /// An output the mock model produces on a single generation turn.
  enum Event: Hashable {
    case toolCall(name: String, arguments: String)
    case text(String)
  }

  let events: [Event]
  let tokenCount: Int

  var capabilities: LanguageModelCapabilities {
    LanguageModelCapabilities(capabilities: [.toolCalling])
  }

  var executorConfiguration: MockModelExecutor.Configuration {
    MockModelExecutor.Configuration(events: events, tokenCount: tokenCount)
  }

  init(textResponse: String, tokenCount: Int) {
    self.events = [.text(textResponse)]
    self.tokenCount = tokenCount
  }

  init(events: [Event], tokenCount: Int) {
    self.events = events
    self.tokenCount = tokenCount
  }
}

struct MockModelExecutor: LanguageModelExecutor {
  struct Configuration: Hashable {
    var events: [MockModel.Event]
    var tokenCount: Int
  }

  let events: [MockModel.Event]
  let tokenCount: Int

  init(configuration: Configuration) throws {
    self.events = configuration.events
    self.tokenCount = configuration.tokenCount
  }

  nonisolated func respond(
    to request: LanguageModelExecutorGenerationRequest,
    model: MockModel,
    streamingInto channel: LanguageModelExecutorGenerationChannel
  ) async throws {
    switch event(for: request.transcript) {
    case .toolCall(let name, let arguments):
      await channel.send(
        .toolCalls(
          entryID: UUID().uuidString,
          action: .toolCall(
            id: UUID().uuidString,
            name: name,
            action: .appendArguments(arguments, tokenCount: tokenCount)
          )
        )
      )
    case .text(let text):
      let entryID = UUID().uuidString
      await channel.send(
        .response(
          entryID: entryID,
          action: .appendText(text, tokenCount: tokenCount)
        )
      )
      await channel.send(
        .response(
          entryID: entryID,
          action: .updateUsage(
            input: .init(totalTokenCount: tokenCount, cachedTokenCount: 0),
            output: .init(totalTokenCount: tokenCount, reasoningTokenCount: 0)
          )
        )
      )
    }
  }

  /// The event to emit for this turn: the number of model-generated entries
  /// (tool calls and responses) since the last prompt indexes into `events`,
  /// clamped to the final event so a sequence ending in `.text` always
  /// terminates.
  private func event(for transcript: Transcript) -> MockModel.Event {
    var index = 0
    for entry in transcript {
      switch entry {
      case .prompt:
        index = 0
      case .toolCalls, .response, .reasoning:
        index += 1
      default:
        break
      }
    }
    return events[min(index, events.count - 1)]
  }
}
```

Six things this forty-line file teaches that the prose does not:

1. **The executor does not have to be nested.** `MockModelExecutor` is a top-level type, wired up by
   `typealias Executor = MockModelExecutor` on the model. Nesting it as `MyModel.Executor` (which
   `ChatCompletionsLanguageModel`, `MLXLanguageModel` and Apple's skill all do) is a naming
   convention, not a requirement.
2. **`Configuration` only needs `Hashable` spelled out.** `struct Configuration: Hashable` —
   `Sendable` is inferred here because every stored property is. The protocol requires
   `Hashable & Sendable`; you often only write one of them.
3. **`Transcript` is a `Sequence` of `Transcript.Entry`.** `for entry in transcript` just works. You
   do not need `Array(request.transcript)` unless you want random access (Apple's `CoreAIExecutor`
   does write `Array(request.transcript)` at `CoreAILanguageModel.swift:281`, because it indexes).
4. **`@unknown default` on `Transcript.Entry` is mandatory in practice.** The enum is non-frozen; the
   `default: break` here is what lets this file keep compiling when a seventh case ships.
5. **Reuse one `entryID` for every event in one entry.** Note `let entryID = UUID().uuidString` used
   for *both* the `appendText` and the `updateUsage` in the `.text` branch — and note the tool-call
   branch mints its own, separate id. §9.3 is entirely about this rule.
6. **You may send `updateUsage` at the end.** Apple's own mock puts usage after the text, not before
   it. Hold that thought until §10, where the WWDC session says the opposite.

Everything from here on is elaboration on this file.

---

## 5. Capabilities: four flags that route requests

```swift illustrative
public var capabilities: LanguageModelCapabilities { get }
```

Four capabilities exist. All four are exercised in compiled Apple source.

> ✅ **VERIFIED** — the four, with Apple's own one-line definitions, `SKILL.md:314-319`:
>
> | Capability | Meaning (Apple's words) |
> |---|---|
> | `.toolCalling` | *"Model calls developer-registered tools. Translate `request.enabledToolDefinitions` into your provider's tool definitions; emit per-call tool-call events (`.toolCalls(.toolCall(...))`) as the model streams a call."* |
> | `.vision` | *"Prompts may include images. Walk `Transcript.Prompt.segments` and forward image data in your provider's format (base64, URL, etc.)."* |
> | `.reasoning` | *"Model produces structured reasoning separate from response text. Emit `.reasoning(...)` events — a top-level event peer to `.response` and `.toolCalls` — as reasoning streams."* |
> | `.guidedGeneration` | *"Model **strictly** conforms output to a JSON Schema. Forward `request.schema` into your provider's structured-output / JSON-mode field."* |

### 5.1 Two initializers, both real

> ✅ **VERIFIED** — both spellings exist in beta 3 and both compile:
>
> ```swift
> // Positional — ChatCompletionsLanguageModel.swift:90
> LanguageModelCapabilities([.vision, .toolCalling, .reasoning, .guidedGeneration])
>
> // Labelled — MockModel.swift:31, and MLXLanguageModel.swift:565
> LanguageModelCapabilities(capabilities: [.toolCalling])
> ```
>
> The positional form is new. Commit `376ca60` ("Updates to accompany Xcode 27 beta 3") lists
> *"`LanguageModelCapabilities(capabilities: [...])` → `LanguageModelCapabilities([...])`"* among its
> changes — but the labelled form was **not** removed; Apple's own test mocks still use it. Prefer
> the positional form in new code, and do not "fix" the labelled one when you see it.

Membership is tested with `contains`:

> ✅ **VERIFIED** — `MLXLanguageModel.swift:957`: `if !model.capabilities.contains(.vision), …`
> and `ChatCompletionsTests+Configuration.swift:42-45` asserts `model.capabilities.contains(.vision)`.
> The element type is `LanguageModelCapabilities.Capability`, which is the array element type in the
> labelled initializer (`MLXLanguageModel.swift:558`:
> `capabilities: [LanguageModelCapabilities.Capability] = [.guidedGeneration]`).

### 5.2 Declare them conditionally when they *are* conditional

The two shipped conformances take opposite approaches, and both are right for their situation.

**Compute them, when the model tells you.** Apple's Core AI adapter detects capabilities from the
loaded bundle at init time — reasoning from the presence of `<think>` / `<|reasoning_start|>` tokens
in the tokenizer, tool calling from tool-call marker tokens, guided generation from whether the
engine exposes logits:

> ✅ **VERIFIED** — `CoreAILanguageModel.swift:59-65`:
>
> ```swift
> public var capabilities: LanguageModelCapabilities {
>     var caps: [LanguageModelCapabilities.Capability] = []
>     if supportsToolCalling { caps.append(.toolCalling) }
>     if supportsReasoning { caps.append(.reasoning) }
>     if isGuidedGenerationSupported { caps.append(.guidedGeneration) }
>     return LanguageModelCapabilities(caps)
> }
> ```

**Or take them from the caller, when only the caller knows.** MLX refuses to infer:

> ✅ **VERIFIED** — `MLXLanguageModel.swift:509-513`: *"Capabilities are declared explicitly by the
> caller at `init(configuration:capabilities:configurationResolver:weightsLocation:load:)` and stored
> verbatim. The caller includes `.guidedGeneration`/`.toolCalling`/`.reasoning` as appropriate; the
> adapter does not consult `ReasoningHeuristics` (which remains a standalone helper a caller may use
> to compute their own capability set)."*

MLX's reasoning is sound for a package that can load *any* Hugging Face checkpoint: a wrong guess is
worse than an explicit answer. Apple's Core AI adapter can inspect a bundle it controls. Pick the one
that matches how much you know about the weights.

The half-and-half case is `ChatCompletionsLanguageModel`, and it is the most honest thing in the
file:

```swift prelude:guide-context
public var capabilities: LanguageModelCapabilities {           // :88
  if supportsGuidedGeneration {
    LanguageModelCapabilities([.vision, .toolCalling, .reasoning, .guidedGeneration])
  } else {
    LanguageModelCapabilities([.vision, .toolCalling, .reasoning])
  }
}
```

`.vision`, `.toolCalling` and `.reasoning` are declared **unconditionally** — because the OpenAI
chat-completions *protocol* supports all three, whatever the server behind it does — while
`.guidedGeneration` is gated on a `supportsGuidedGeneration: Bool = true` initializer flag, because
`response_format: json_schema` support genuinely varies across Ollama, vLLM, LM Studio and
`mlx_lm.server`. **Where the wire protocol is the contract, declare from the protocol and let the
developer opt out of the parts their server lacks.**

### 5.3 Capabilities are routing, not documentation

This is the part people get wrong. A capability is not a README badge; the framework *reads* it and
changes what it sends you.

> ✅ **VERIFIED** — `MLXLanguageModel.swift:515-519`, the sharpest statement of this anywhere:
> *"Declaring `.reasoning` matters for **request routing**: the framework **only forwards a
> `reasoningLevel` to executors that declare `.reasoning`, and auto-rejects one otherwise (on the
> developer's behalf) before `respond` runs.** The executor in turn emits `.reasoning` events only
> when this capability was declared."*

So under-declaring is safe and self-correcting — the framework throws `unsupportedCapability` at the
developer for you, before your code runs (`SKILL.md:35`, `:312`, `:553`). **Over-declaring is the
dangerous direction**, and it is dangerous in a specific way:

> ⚠️ **SILENT FAILURE — an over-declared `.guidedGeneration` does not throw; it returns garbage.**
> Declaring `.guidedGeneration` tells the framework your model *strictly* enforces the schema. Apple
> says "strictly" twice — `SKILL.md:110` (*"include only if your model **strictly enforces** JSON
> Schema"*) and `SKILL.md:319`. If you declare it and merely *ask* your model for JSON in the prompt,
> the framework will forward `request.schema`, take your output at face value, and hand the developer
> a `GeneratedContent.ParsingError` — or worse, a successfully-parsed object with a hallucinated
> field — instead of a clean `unsupportedCapability` they could have handled. Nothing in the type
> system distinguishes "constrained decoding" from "we asked nicely."
>
> **The test that settles it:** point your model at a schema with a required enum field and a prompt
> that invites a different answer, at temperature 1, fifty times. If you cannot produce fifty valid
> objects, you do not have `.guidedGeneration`.

### 5.4 The architectural constraint: guided generation needs logits

There is a whole class of backend for which `.guidedGeneration` is *structurally* unavailable, and it
is the class app developers reach for when they want speed.

> **Community-measured** (`notes/repos/john-rocky-models.md`, verified 2026-06-11 on macOS 27 beta,
> M4 Max; attribute as community, not Apple): grammar-constrained decoding requires access to the
> engine's **logits** so a grammar can mask the next-token distribution. **GPU-pipelined Core AI
> bundles sample on-GPU and expose no logits** — `engine.supportsLogits` returns `false` — so every
> pipelined bundle lacks `.guidedGeneration`; the sequential engine has it. The consequence for an
> app is stark: *an app that brings its own model loses Apple's flagship structured-generation
> feature exactly when it selects the fastest backend.*

The right response as a provider author is the approximate-or-throw rule applied honestly:

> ✅ **VERIFIED** — community `ZooExecutor.swift:119-128`, the pattern to copy:
>
> ```swift
> // Pipelined zoo bundles sample on-GPU — no logits, no constrained
> // decoding. Approximate-or-throw rule: there is no honest
> // approximation of a schema, so throw.
> if request.schema != nil {
>     throw LanguageModelError.unsupportedCapability(
>         .init(
>             capability: .guidedGeneration,
>             debugDescription:
>                 "GPU-pipelined zoo bundles sample on-device and expose no logits; "
>                 + "guided generation needs a sequential engine."))
> }
> ```

Note that this throws even though the capability was never declared — belt and braces, because the
engine variant can change between constructing the model and running the request. §11 covers when to
throw manually versus letting the framework do it.


---

## 6. Reading a request: all seven fields

Everything the framework knows about a turn arrives in one struct.

> ✅ **VERIFIED** — `SKILL.md:264-274`, verbatim:
>
> ```swift
> public struct LanguageModelExecutorGenerationRequest: Sendable {
>   public var id: UUID
>   public var transcript: Transcript
>   public var enabledToolDefinitions: [Transcript.ToolDefinition]
>   public var schema: GenerationSchema?
>   public var generationOptions: GenerationOptions
>   public var contextOptions: ContextOptions
>   public var metadata: [String: any Sendable & Codable & Equatable]
> }
> ```

Seven fields. Apple's own table of what each is for (`SKILL.md:276-284`), tightened:

| Field | What it is | How to use it |
|---|---|---|
| `id` | *"Unique UUID for this request."* | *"Forward into your provider's request id / log fields for tracing."* |
| `transcript` | *"The full conversation history the developer wants you to continue."* | *"Translate `transcript.entries` into your provider's chat-message array."* §8. |
| `enabledToolDefinitions` | *"Tool definitions the developer registered as available for this turn. Empty if none."* | *"Translate into your provider's tool/function definitions. Skip if you didn't declare `.toolCalling`."* |
| `schema` | *"Optional `GenerationSchema` describing required JSON output shape."* | *"Forward into your provider's structured-output / JSON-mode field. Skip if you didn't declare `.guidedGeneration`."* |
| `generationOptions` | *"Sampling controls: `temperature`, `samplingMode`, `maximumResponseTokens`, `toolCallingMode`."* | *"Translate each present field into your provider's equivalent parameter. Treat `nil` fields as 'use provider default'."* |
| `contextOptions` | *"Prompting controls: `includeSchemaInPrompt`, `reasoningLevel`."* | *"Use `reasoningLevel` to set your provider's thinking-budget knob. `includeSchemaInPrompt` tells you whether to inline the JSON schema into the system prompt."* |
| `metadata` | *"Developer-provided dictionary passed at the call site."* | *"Forward to your provider's metadata field for analytics, or define well-known keys for an escape hatch (e.g. a `passthrough` key for forwarding raw provider-specific options)."* |

> ⚠️ **The shipped conformance ignores three of the seven.** `ChatCompletionsLanguageModel.Executor`
> reads `transcript`, `enabledToolDefinitions`, `schema` and `generationOptions`. It never reads
> `contextOptions`, never reads `id`, never reads `metadata` — verified by grep over all 953 lines.
> So a developer who sets `ContextOptions(reasoningLevel: .deep)` and points at
> `mlx_lm.server` gets **exactly the same request on the wire** as one who set nothing, with no
> diagnostic anywhere. Do not infer from "Apple's example ignores it" that it is unimportant; infer
> that the reference implementation targets a wire protocol (OpenAI chat-completions) that has no
> field for it. If your protocol *does*, read all seven.

A naming trap worth knowing before it costs you an hour:

> **Community-measured trap** (`fm-provider.md:187-188`): *"`request.enabledToolDefinitions` is the
> property; `enabledTools` is only the memberwise-init label."* If you are constructing a request in
> a test and reading it in an executor, the two names do not match, and the compiler error points at
> the wrong one.

### 6.1 Reading the enum-like option structs: the `.kind` projection

`GenerationOptions.SamplingMode` and `GenerationOptions.ToolCallingMode` are structs that *look* like
enums. You can construct them; historically you could not read them. Beta 3 fixed that.

> ✅ **VERIFIED** — `SKILL.md:286-288`, a section added in beta 3: *"Several framework option types
> are enum-like structs you can *construct* but historically couldn't *read*. To let executors
> translate them, there is now a `kind` property on each. Switch on `kind` to map the value onto your
> provider's parameters."*
>
> Apple's illustrative code (`SKILL.md:290-304`):
>
> ```swift
> // generationOptions.samplingMode — translate to your provider's sampling knobs.
> if let mode = request.generationOptions.samplingMode {
>   switch mode.kind {
>   case .greedy:
>     providerRequest.temperature = 0 // deterministic
>   case .randomTopK(let k, let seed):
>     providerRequest.topK = k
>     providerRequest.seed = seed
>   case .randomProbabilityThreshold(let p, let seed):
>     providerRequest.topP = p
>     providerRequest.seed = seed
>   }
> }
> ```

Two notes on that snippet, both verified against shipping code:

**The case names changed in beta 3.** Commit `376ca60`: *"Renamed SamplingMode enum cases —
`.top` → `.randomTopK` and `.nucleus` → `.randomProbabilityThreshold`."* If you find `.top` or
`.nucleus` in a blog post or an LLM-generated file, it is beta-1 vintage. `mlx-swift-lm` has a commit
(`2a76e56`) whose entire purpose is chasing this rename.

**Apple's own executor maps `.greedy` differently from Apple's own skill.** The skill sets
`temperature = 0`; the real implementation sets `top_p = 0`:

```swift prelude:guide-context
private func topP(_ sampling: GenerationOptions.SamplingMode) throws -> Double {   // :367
  switch sampling.kind {
  case .greedy:
    return 0                                                                        // :370
  case .randomTopK:
    throw ChatCompletionsLanguageModel.RequestError.invalidRequest(
      "Top K sampling is not supported"                                             // :374
    )
  case .randomProbabilityThreshold(let threshold, let seed):
    guard seed == nil else {
      throw ChatCompletionsLanguageModel.RequestError.invalidRequest(
        "Setting a random seed is not supported"                                    // :379
      )
    }
    return threshold                                                                // :382
  @unknown default:
    throw ChatCompletionsLanguageModel.RequestError.invalidRequest(
      "Unknown sampling mode \(sampling.kind) is not supported"                     // :385
    )
  }
}
```

> **Ruling on the conflict:** the *code* wins over the skill's illustration, but only as evidence of
> what one implementation chose — not as a rule. `top_p = 0` and `temperature = 0` both produce greedy
> decoding on most OpenAI-compatible servers, and Apple's executor happens to route everything through
> its `top_p` slot because that is where `samplingMode` lands in its request builder
> (`:242`: `topP: try request.generationOptions.samplingMode.map(topP)`). **Map `.greedy` to whatever
> your engine's actual deterministic path is** — for MLX that is `temperature == 0` routing to a
> greedy sampler (`MLXLanguageModel.swift:803-806`), for a raw sampler it may be argmax directly.

Note also the `@unknown default:` on a switch over `kind`. Every one of these option enums is
non-frozen. Omit it and your package stops compiling on the next SDK.

The same `.kind` projection exists on `toolCallingMode`, and Apple's mapping is a good default:

```swift illustrative
mode: {                                                       // :254-261
  switch request.generationOptions.toolCallingMode?.kind {
  case .allowed, .none: .auto
  case .required: .required
  case .disallowed: .none
  @unknown default: .auto
  }
}()
```

Read `case .allowed, .none:` carefully — the `.none` there is `Optional.none`, i.e. the developer set
no mode at all, folded into the same branch as `.allowed`. **`toolCallingMode == nil` means
`.allowed`.**

### 6.2 `GenerationSchema` is `Codable` — do not hand-translate JSON Schema

The single biggest time-saver in the whole API, and it is one sentence:

> ✅ **VERIFIED** — `SKILL.md:308`: *"`GenerationSchema` conforms to `Codable` and encodes to standard
> JSON Schema. Both `request.schema` and each `ToolDefinition.parameters` are `GenerationSchema`
> values, so for most server providers you can hand them straight to a `JSONEncoder` and drop the
> result into your structured-output / function-parameters field — **no manual schema translation
> needed**."*

Apple's executor does exactly that, encoding the `GenerationSchema` inline as the `schema` member of
its wire type:

```swift illustrative
responseFormat: request.schema.map { schema in                // :263-270
  ChatCompletionsClient.ResponseFormat(
    jsonSchema: ChatCompletionsClient.ResponseFormat.JSONSchemaWrapper(
      name: schema.name,
      schema: schema
    )
  )
}
```

and tool parameters go across untranslated too (`:244-252`):

```swift illustrative
tools: request.enabledToolDefinitions.map { tool in
  ChatCompletionsClient.Tool(
    function: ChatCompletionsClient.Tool.Function(
      name: tool.name,
      description: tool.description,
      parameters: tool.parameters          // ← a GenerationSchema, encoded as JSON Schema
    )
  )
}
```

That `schema.name` is itself new:

> ✅ **VERIFIED — `GenerationSchema.name` is a beta-3 API.** Beta 1 carried a private
> `extension GenerationSchema { var title: String }` that round-tripped the schema through
> `JSONEncoder`/`JSONSerialization`, read the `"title"` key, and fell back to `"type"` and then to
> `"Response"`. Commit `376ca60` **deleted that extension entirely** in favour of a first-class
> `GenerationSchema.name` property, and lists the change in its message: *"`ChatCompletionsLanguageModel`
> schema name uses the new `GenerationSchema.name` API."*
>
> 🔴 **GAP (narrowed 2026-07-29) — what `.name` returns for an anonymous or inline schema.** The
> declaration is now pinned: `public var name: String { get }`, 27.0+, **non-optional** —
> ✅ **SDK-verified** (`FoundationModels-27.0-macos.swiftinterface:3319-3327`) — so every schema has
> *some* name and there is no `String?` edge case. What the getter *computes* for an anonymous
> schema is still invisible (non-inlinable body) and untested. **Safe default unchanged:** if your
> wire format requires a non-empty schema name, write
> `schema.name.isEmpty ? "Response" : schema.name` and log when you hit the fallback.

---

## 7. `ContextOptions` vs `GenerationOptions` — the split that matters

New provider authors routinely put things in the wrong bucket, and the resulting bugs are subtle
because both bags arrive on the same request. The distinction is crisp and worth memorising.

> ✅ **VERIFIED** — 339:106–113: *"**every request carries more than history, it carries the
> developer's intent for how the model should respond, expressed through two additional properties.**
> Every request object can include **`ContextOptions`** and **`GenerationOptions`**. **`ContextOptions`
> control what goes into the prompt, like the reasoning level you want the model to use, or a
> response schema. `GenerationOptions` control the decoder loop: sampling strategy, temperature, and
> maximum response length.** Here's what that looks like inside `respond`. Both types of options come
> in on the request, your executor pulls them out and passes them along when calling the model."*

**`ContextOptions` changes the bytes you send. `GenerationOptions` changes how you decode.** If
honouring an option means editing the prompt string, it is a `ContextOptions` concern. If honouring
it means changing a sampler parameter or a stop condition, it is `GenerationOptions`.

| | `ContextOptions` | `GenerationOptions` |
|---|---|---|
| Question it answers | *What does the model read?* | *How does the model write?* |
| Verified members | `includeSchemaInPrompt`, `reasoningLevel` | `temperature`, `samplingMode`, `maximumResponseTokens`, `toolCallingMode` |
| Where it lands | your chat template, your system message, your thinking-budget flag | your sampler, your token budget, your tool-choice field |
| Fails how | model reads the wrong thing and answers plausibly and wrongly | output is malformed or truncated |

The members are verified from two directions: Apple's skill lists both bags' fields
(`SKILL.md:282-283`), and real call sites read them —
`request.contextOptions.reasoningLevel` at `MLXLanguageModel.swift:1110`, `:1154` and `:1186`;
`request.generationOptions.temperature` at `ChatCompletionsLanguageModel.swift:241`,
`.maximumResponseTokens` at `:243`, `.samplingMode` at `:242`, `.toolCallingMode?.kind` at `:255`.

### 7.1 `ReasoningLevel` has four cases, one of which is a string

This is the field the session gestures at and nobody writes down. It is readable in shipping source:

> ✅ **VERIFIED** — `MLXLanguageModel.swift:1903-1916`, the complete switch, verbatim:
>
> ```swift
> static func thinkingEnabled(for level: ContextOptions.ReasoningLevel?) -> Bool? {
>     guard let level else { return nil }
>     switch level {
>     case .light, .moderate, .deep:
>         return true
>     case .custom(let value):
>         let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
>             .lowercased()
>         return normalized == "no_think" ? false : true
>     @unknown default:
>         // A future level we don't recognize → default to thinking on.
>         return true
>     }
> }
> ```
>
> So `ContextOptions.ReasoningLevel` is a **non-frozen enum with at least four cases —
> `.light`, `.moderate`, `.deep`, and `.custom(String)`** — and the type is spelled
> `ContextOptions.ReasoningLevel`, nested on `ContextOptions`. This closes an open question the rest
> of the corpus leaves unresolved (the utilities notes record the type of the "thinking-budget knob"
> as unknown; it is this).

`.custom(String)` is the escape hatch for providers whose thinking control is not a three-point
scale: MLX interprets the specific string `"no_think"` as "thinking off" because that is the token
Qwen-family templates respond to. **If your engine has a numeric thinking budget, document which
string your package accepts in `.custom` and treat the three named levels as coarse buckets onto it.**

Note the framework-side gate again: you will only ever see a non-`nil` `reasoningLevel` if you
declared `.reasoning` (§5.3). A `nil` here means "developer expressed no preference," not "thinking
off" — MLX returns `nil` from that helper and then applies the model's own default.

### 7.2 `includeSchemaInPrompt` is a hint about *duplication*

> ✅ **VERIFIED** — `SKILL.md:283`: *"`includeSchemaInPrompt` tells you whether to inline the JSON
> schema into the system prompt."*

The reason this exists: if your backend does constrained decoding from `request.schema`, putting the
schema in the prompt as well burns tokens describing something the decoder already enforces. If your
backend does *not*, the prompt is the only place the schema can live. The flag lets the developer —
who may know their model responds better to one or the other — control it.

> 🔴 **GAP (narrowed 2026-07-29) — still nobody in this corpus *reads* `includeSchemaInPrompt`, but
> the declaration is settled.** `ContextOptions` is
> `public struct ContextOptions : Sendable, Equatable` with `includeSchemaInPrompt: Bool?` and
> `reasoningLevel: ContextOptions.ReasoningLevel?`, `init` defaulting both to `nil` —
> ✅ **SDK-verified** (`FoundationModels-27.0-macos.swiftinterface:3130-3147`). Note the **optional**
> `Bool?`: `nil` means "the developer expressed no preference", so your executor needs a
> three-state policy, not a boolean one (the framework's own `schema:` overloads default it to
> `ContextOptions(includeSchemaInPrompt: true)`, `:2073-2079`). `ChatCompletionsLanguageModel`
> ignores all of `contextOptions`; MLX reads only `reasoningLevel`. **Safe default unchanged:**
> inline schemas into prompts only when your backend cannot constrain decoding, and treat the flag
> as advisory.


---

## 8. Transcript translation: six entries in, your roles out

This is the part of a provider package that is genuinely yours. The framework has one vocabulary;
your model has another; your executor is the dictionary.

> ✅ **VERIFIED** — 339:86–92: *"The framework hands you **transcript entries**, but your inference
> engine can only process its **native types**. So your executor **sits in the middle, translates the
> entries into messages your inference engine understands**… When your inference engine answers,
> **the same translation runs in reverse: your messages back to transcript entries, streamed to the
> session.**"*

### 8.1 The six entry types

> ✅ **VERIFIED** — `SKILL.md:502-511`, verbatim, with Apple's own comments:
>
> ```swift
> public enum Entry {
>   case instructions(Instructions)  // system prompt
>   case prompt(Prompt)              // user message (may contain text + images)
>   case toolCalls(ToolCalls)        // model's prior tool calls
>   case toolOutput(ToolOutput)      // results returned from those tools
>   case response(Response)          // model's prior text response
>   case reasoning(Reasoning)        // model's prior reasoning
> }
> ```
>
> Six cases, corroborated by three independent readings: the WWDC session (*"Foundation Models defines
> these six entry types"* — 339:98), Apple's `ChatCompletionsLanguageModel.convertedTranscript`
> switch (`:482-557`), and MLX's `TranscriptConverter` switch
> (`TranscriptConverter.swift:26-113`). The enum is **non-frozen** — every switch over it in shipping
> code carries an `@unknown default` or a `default`.

### 8.2 The mapping is yours, and Apple says so

> ✅ **VERIFIED** — 339:99–105: *"**Your model defines its own roles. Your executor's job is to map
> between the two, no matter the shape your model takes.** In this example, **instructions, prompt,
> and response map to system, user, and assistant.** Here, **tool calls, tool outputs, and reasoning
> all map to assistant too.** They're part of what the model did during its turn, and **since this
> model doesn't have dedicated roles for these, we just map them to assistant.** **If your model does
> define something like a dedicated tool role, you can route there instead. Either way, your executor
> stays in control.**"*

Apple's skill gives a starting table (`SKILL.md:515-522`), which is the right default for any
OpenAI-shaped provider:

| Entry | Common provider role | Apple's note |
|---|---|---|
| `.instructions` | `system` | *"Concatenate text segments."* |
| `.prompt` | `user` | *"Walk `segments` — text and images interleaved; forward as your provider's content blocks."* |
| `.toolCalls` | `assistant` | *"Emit a message with the provider's tool-calls array."* |
| `.toolOutput` | `tool` (or `user`, depending on provider convention) | *"One per tool result."* |
| `.response` | `assistant` | *"The model's prior text. Concatenate text segments."* |
| `.reasoning` | provider-specific | see §8.5 — this is the interesting one |

### 8.3 Worked translator #1 — `ChatCompletionsLanguageModel`

The complete entry loop, verbatim from
`ChatCompletionsLanguageModel.swift:468-568`. This is 100 lines that answer most questions you will
have:

```swift prelude:guide-context
var messages: [ChatCompletionsClient.ChatMessage] = []
// Reasoning entries are buffered and attached to the next assistant
// message (response or toolCalls) via `reasoning_content`. If a turn
// has only reasoning with no following assistant entry, it's emitted
// as a standalone assistant message.
var pendingReasoning: String? = nil

func consumePendingReasoning() -> String? {
  defer { pendingReasoning = nil }
  return pendingReasoning
}

// Translate each transcript entry into one chat-completion message.
for entry in entries {
  switch entry {
  case .instructions(let instructions):
    // Instructions become system-role messages.
    messages.append(
      ChatCompletionsClient.ChatMessage(
        role: .system,
        content: try instructions.segments.flatMap { try convertedSegment($0, in: entry) }
      )
    )

  case .prompt(let prompt):
    // User prompts; flush any orphaned reasoning as a message first.
    if let reasoning = consumePendingReasoning() {
      messages.append(
        ChatCompletionsClient.ChatMessage(role: .assistant, reasoningContent: reasoning)
      )
    }
    messages.append(
      ChatCompletionsClient.ChatMessage(
        role: .user,
        content: try prompt.segments.flatMap { try convertedSegment($0, in: entry) }
      )
    )

  case .toolCalls(let toolCalls):
    // Tool calls ride along on an assistant message, with any buffered reasoning attached.
    messages.append(
      ChatCompletionsClient.ChatMessage(
        role: .assistant,
        toolCalls: toolCalls.map { call in
          ChatCompletionsClient.ToolCall(
            id: call.id,
            function: ChatCompletionsClient.ToolCall.FunctionCall(
              name: call.toolName,
              arguments: call.arguments.jsonString
            )
          )
        },
        reasoningContent: consumePendingReasoning()
      )
    )

  case .toolOutput(let toolOutput):
    // Tool outputs become tool-role messages keyed by the originating call ID.
    messages.append(
      ChatCompletionsClient.ChatMessage(
        role: .tool,
        content: try toolOutput.segments.flatMap { try convertedSegment($0, in: entry) },
        toolCallID: toolOutput.id
      )
    )

  case .response(let response):
    // Assistant responses; attach any buffered reasoning to this message.
    messages.append(
      ChatCompletionsClient.ChatMessage(
        role: .assistant,
        content: try response.segments.flatMap { try convertedSegment($0, in: entry) },
        reasoningContent: consumePendingReasoning()
      )
    )

  case .reasoning(let reasoning):
    // Buffer reasoning text; it will attach to the next assistant entry.
    let text = reasoning.segments.compactMap { segment -> String? in
      if case .text(let textSegment) = segment { return textSegment.content }
      return nil
    }.joined()
    pendingReasoning = (pendingReasoning ?? "") + text

  @unknown default:
    continue
  }
}

// Trailing reasoning with no following assistant entry — emit it solo.
if let reasoning = consumePendingReasoning() {
  messages.append(
    ChatCompletionsClient.ChatMessage(role: .assistant, reasoningContent: reasoning)
  )
}

return messages
```

Four details in that listing are worth extracting, because each is a decision you will have to make
too.

**Entries are not one-to-one with messages.** `.reasoning` produces *no* message; it buffers, and
the next assistant-ish entry absorbs it. Your translator is a small state machine, not a `map`.

**Tool-output identity comes from the entry, not from a separate field.**
`toolCallID: toolOutput.id` — the tool-output entry's own `id` *is* the id of the call it answers.

**Tool-call arguments are `GeneratedContent`, and `.jsonString` is the accessor.**
`call.arguments.jsonString` (`:519`). Likewise `call.toolName` and `call.id` on
`Transcript.ToolCall`.

**Segments, not strings.** Every entry carries `segments`, and the segment switch is where images,
structured content, and the extension points live:

```swift illustrative
func convertedSegment(                                        // :395
  _ segment: Transcript.Segment,
  in entry: Transcript.Entry
) throws -> [ChatCompletionsClient.MessageContent] {
  switch segment {
  case .text(let text):
    return [ChatCompletionsClient.MessageContent(text: text.content)]
  // Structured content is serialized to JSON text on the wire.
  case .structure(let structure):
    return [ChatCompletionsClient.MessageContent(text: structure.content.jsonString)]
  case .attachment(let attachment):
    switch attachment.content {
    case .image(let image):
      #if canImport(CoreImage)
      // Images are inlined as base64 data URLs (JPEG).
      let base64String = image.cgImage.jpegData().base64EncodedString()
      let dataURL = URL(string: "data:image/jpeg;base64,\(base64String)")!
      …
      #else
      guard let url = image.url else { throw … }              // :423 — Linux path, beta 3
      …
      #endif
    @unknown default:
      throw LanguageModelError.unsupportedTranscriptContent(
        LanguageModelError.UnsupportedTranscriptContent(
          unsupportedContent: [entry],
          debugDescription: "Attachment type not supported by \(Self.self)."
        )
      )
    }
  case .custom:
    throw LanguageModelError.unsupportedTranscriptContent(
      LanguageModelError.UnsupportedTranscriptContent(
        unsupportedContent: [entry],
        debugDescription: "Custom segments are not supported by \(Self.self)"
      )
    )
  @unknown default:
    throw LanguageModelError.unsupportedTranscriptContent(
      LanguageModelError.UnsupportedTranscriptContent(
        unsupportedContent: [entry],
        debugDescription: "Unknown segment type not supported by \(Self.self)"
      )
    )
  }
}
```

So **`Transcript.Segment` has at least four cases** — `.text`, `.structure`, `.attachment`,
`.custom` — plus non-frozen future ones, and `.text(let text)` gives you a `TextSegment` whose
payload is `.content`. Note that this is also the canonical example of constructing a
`LanguageModelError` payload struct, which §11 returns to.

Also note the beta-3 signal in the `#else` branch: beta 1 read `image.url.scheme` directly and beta 3
reads `guard let url = image.url`, from which **`Transcript.ImageAttachment.url` became Optional in
beta 3.** That is deduced from a diff, not read from a declaration — treat it as strong but indirect.

### 8.4 Worked translator #2 — `MLXLanguageModel`

MLX targets a chat-template abstraction rather than a wire protocol, and its translator is shaped
differently — `compactMap` returning `nil` for entries it drops, with a logger on every drop:

> ✅ **VERIFIED** — `Libraries/MLXFoundationModels/TranscriptConverter.swift:22-114`, abridged to the
> switch:
>
> ```swift
> static func mlxMessages(for entries: some Collection<Transcript.Entry>) -> [Chat.Message] {
>     entries.compactMap { entry -> Chat.Message? in
>         switch entry {
>         case .instructions(let instructions):
>             let text = extractText(from: instructions.segments)
>             let images = extractImages(from: instructions.segments)
>             guard text != nil || !images.isEmpty else {
>                 logger.warning("Skipping instructions entry with no text or image content")
>                 return nil
>             }
>             return Chat.Message.system(text ?? "", images: images)
>
>         case .prompt(let prompt):
>             …
>             return Chat.Message.user(text ?? "", images: images)
>
>         case .response(let response):
>             guard let text = extractText(from: response.segments) else {
>                 logger.warning("Skipping response entry with no text content")
>                 return nil
>             }
>             return Chat.Message.assistant(text)
>
>         case .reasoning:
>             // Prior-turn reasoning is intentionally NOT replayed into the
>             // model's chat history (per SKILL.md): the answer carries
>             // forward, the chain-of-thought does not. Dropped explicitly so
>             // a future SDK change is reviewed here rather than silently
>             // absorbed by the catch-all below.
>             logger.debug("Skipping reasoning entry (not replayed into chat history)")
>             return nil
>
>         case .toolCalls(let toolCalls):
>             // Replay prior tool calls as an assistant message carrying the
>             // structured calls. … Without this, a continuation round would
>             // re-issue the same call.
>             let calls = toolCalls.map { call -> MLXLMCommon.ToolCall in
>                 let argumentsData = Data(call.arguments.jsonString.utf8)
>                 …
>                 return MLXLMCommon.ToolCall(
>                     function: .init(name: call.toolName, arguments: arguments),
>                     id: call.id)
>             }
>             guard !calls.isEmpty else { … return nil }
>             return Chat.Message.assistant("", toolCalls: calls)
>
>         case .toolOutput(let output):
>             let content = extractToolOutputContent(from: output.segments)
>             return Chat.Message.tool(content, id: output.id)
>
>         default:
>             // Skip unsupported entry types. Explicit `return nil` is a
>             // tripwire: a newly added SDK entry type surfaces here for review
>             // rather than being silently coerced into the wrong role.
>             logger.debug("Skipping unsupported entry type")
>             return nil
>         }
>     }
> }
> ```

Note the sentence in the `.toolCalls` comment — *"Without this, a continuation round would re-issue
the same call"* — because it names a bug you will otherwise ship. The tool loop calls `respond`
again after the framework executes your tool. If your translator drops `.toolCalls` and `.toolOutput`
from history, the model sees a conversation in which it never called anything and calls the same tool
again. Forever, in the worst case.

Apple's Core AI adapter maps the same six entries onto template message dicts, with one difference
worth noting — it **skips `.reasoning` too**, with the comment *"Don't echo the model's prior
reasoning back into the prompt."* (`CoreAILanguageModel.swift`, entry mapping table.)

### 8.5 The reasoning-replay disagreement, and how to rule on it

Three implementations, three different answers about the same entry type:

| Implementation | What it does with a prior `.reasoning` entry |
|---|---|
| `ChatCompletionsLanguageModel` | **Replays it**, attached to the following assistant message as `reasoning_content` |
| `MLXLanguageModel` | **Drops it**, deliberately, with a debug log |
| `CoreAILanguageModel` | **Drops it**, deliberately (*"Don't echo the model's prior reasoning back into the prompt"*) |

They are all correct, because the question is a property of the *provider*, not of the framework.
Apple's skill is the ruling document and it says so precisely:

> ✅ **VERIFIED** — `SKILL.md:522`: *"Model's prior reasoning. **If your provider preserves reasoning
> across turns** (e.g. as a dedicated field on assistant messages, or via a signature it requires you
> to echo back), forward `segments` and `signature` accordingly. **When `signature` is non-nil,
> `segments` may be a partial summary rather than the full reasoning — treat the signature as the
> authoritative anchor.** If your provider does not accept prior reasoning, **drop these entries** —
> the framework keeps them in the transcript for downstream consumers regardless."*

Two operational rules fall out of that paragraph:

1. **Dropping an entry from what you send is not dropping it from the transcript.** The developer's
   `session.transcript` keeps everything; you are only deciding what your model reads. This is why
   dropping is safe.
2. **If your provider signs reasoning, the signature is the payload.** `Transcript.Reasoning` carries
   a `signature` alongside `segments`, the segments may be a lossy summary, and the signature is what
   the provider will validate. §9.2 covers emitting it; here, echo it back untouched.

### 8.6 ⚠️ The silent failure hiding in every one of these switches

> ⚠️ **SILENT FAILURE — an unhandled entry or segment disappears, and the model answers anyway.**
> Look at the three catch-alls above:
>
> - `ChatCompletionsLanguageModel.swift:555-556` — `@unknown default: continue`
> - `TranscriptConverter.swift:107-112` — `default: … return nil`
> - Apple's Core AI adapter — same shape
>
> All three *silently drop* the entry. Nothing throws. The request goes out one message short, the
> model answers confidently from incomplete context, and the developer sees a plausible wrong answer
> with no error anywhere in the stack. The failure mode is invisible in exactly the way that makes it
> expensive: it only manifests as quality regression, and only for the users whose transcripts happen
> to contain the entry you dropped.
>
> There is a real instance of this class already in the corpus: Apple's Core AI adapter *"skips tool
> entries and never declares the capability"* (community-measured, `fm-provider.md:79-87`), so a
> `LanguageModelSession` built on a Core AI model with tools registered simply behaves as if the
> tools did not exist.
>
> **Three defences, in increasing order of strength:**
> 1. **Log every drop, at `warning` not `debug`.** MLX does this for empty entries and it is the only
>    reason such bugs are ever found in the field.
> 2. **Throw `unsupportedTranscriptContent` for content you genuinely cannot represent**, the way the
>    segment switch does for `.custom`. A thrown error is a bug report; a silent drop is a support
>    ticket about "the AI being dumb."
> 3. **Assert on entry counts in a test.** Build a transcript with all six entry types, run your
>    translator, and assert the output message count. A `default: continue` will pass every test you
>    write about behaviour and fail this one.
>
> The one legitimate use of a silent drop is a *deliberate* one, and MLX shows how to write it: an
> explicit `case .reasoning: return nil` with a comment explaining the intent, so the catch-all
> never sees it and a future SDK entry type surfaces in review rather than being absorbed.

### 8.7 Dialects do not transfer between model families

One last warning, from the implementation that tried hardest to make one renderer serve many models.

> **Community-measured** (`fm-provider.md:138-179`, verified 2026-06-11, macOS 27 beta, M4 Max):
> *"A model emits tool calls in the format it was **fine-tuned** on, and **an in-context instruction
> will not override that prior**. So tool calling can't share one renderer/parser across families —
> each needs its own."* Measured example: LFM2.5 ignores in-context Hermes `<tool_call>`-JSON
> instructions and emits its trained special-token dialect
> (`<|tool_call_start|>[fn(arg="x")]<|tool_call_end|>`, pythonic) — *"the training prior wins over the
> prompt."*
>
> That author's response was to make the dialect a protocol with `render(transcript:tools:requireToolCall:)`
> and `parseToolCalls(_:tools:)`, auto-selected by probing the tokenizer vocabulary, and to validate
> each dialect the only way that is actually sound: *"verified against the bundle's own
> `chat_template.jinja` — render the template with jinja2 and diff against the Swift output; **the
> template is the spec**."*

If your package targets one model, ignore this. If it targets a family — or worse, "any GGUF" — the
transcript translator is not one function, it is a strategy, and the ground truth for each strategy
is that model's own chat template.


---

## 9. The generation channel: what flows out

> ✅ **VERIFIED** — 339:114–120: *"On the response side, there are a few things to send: **the text
> your inference engine generates, any tool calls or reasoning, and the metadata that travels with
> them. They all go out as events on the channel.** Each chunk that the inference engine emits, a
> token or tool-call fragment, becomes an event. A `textDelta`, a `toolCallDelta`, and so on. The
> framework writes them to the transcript. **Foundation Models exposes both one-shot and streaming
> responses, but the implementation is always streaming; the one-shot API just collects the deltas
> internally.**"*

Two things to take from that paragraph.

**"textDelta" and "toolCallDelta" are the presenter's conceptual names, not API.** The real spelling
is an *action* inside an *event*: `.response(entryID:action: .appendText(_:tokenCount:))` and
`.toolCalls(entryID:action: .toolCall(id:name:action: .appendArguments(_:tokenCount:)))`. If you have
seen `textDelta` in generated code, it came from this session's narration.

**There is no one-shot path to implement.** `session.respond(to:)` and
`session.streamResponse(to:)` reach the same `respond(to:model:streamingInto:)`. Write the streaming
implementation; the collecting is the framework's. This is also why an executor that buffers its
whole answer and sends one giant `appendText` is not "simpler" — it is the streaming implementation
with the streaming removed, and every consumer of your package loses token-by-token UI.

### 9.1 Three top-level events

> ✅ **VERIFIED** — `SKILL.md:351`: *"Events are sent on `LanguageModelExecutorGenerationChannel` via
> `await channel.send(...)`. Three top-level cases — **each is a peer transcript-entry kind**:
> `.response`, `.toolCalls`, and `.reasoning`."*

`send` is `async`; every call site in every conformance is `await channel.send(…)`.

The peer relationship matters and Apple's Core AI adapter explains why it was designed that way:

> ✅ **VERIFIED** — `CoreAILanguageModel.swift:487-492`: *"Reasoning is a sibling of
> response/tool-calls in the new API (not nested under response) because **at parse time we don't yet
> know whether the model will follow the thought block with a response or a tool call.**"*

#### Response actions — `.response(entryID:action:)`

> ✅ **VERIFIED** — `SKILL.md:357-365`:
>
> | Action | When to use (Apple's words) |
> |---|---|
> | `.appendText(_:segmentID:tokenCount:)` | *"Each chunk of model-generated user-facing text."* |
> | `.replaceTextSegment(_:segmentID:tokenCount:)` | *"Whole-segment replacement when your provider sends a final corrected version."* |
> | `.updateCustomSegment(_:)` | *"A value conforming to the `Transcript.CustomSegment` protocol — provider-specific structured payloads."* |
> | `.addAttachmentSegment(_:)` | *"Add a `Transcript.AttachmentSegment` (currently image content) to the response… Each call ADDS a new segment; pass a stable `id` if you'll later remove it."* |
> | `.removeAttachmentSegment(_:)` | *"Remove a previously-added attachment by passing the `Transcript.AttachmentSegment` to drop."* |
> | `.updateMetadata(_:)` | *"Wholesale snapshot of entry metadata. Re-emit every key on every event."* |
> | `.updateUsage(input:output:)` | *"Cumulative running totals. Each event REPLACES prior totals (does not add). Authoritative."* |

> ⚠️ **Beta 5 status (noted 2026-08-23):** the recaptured 27.0 interface confirms six of the seven —
> `appendText` / `replaceTextSegment` / `addAttachmentSegment` / `removeAttachmentSegment` /
> `updateMetadata` / `updateUsage` (`FoundationModels-27.0-macos.swiftinterface:1857-1864`) — but
> **`.updateCustomSegment(_:)` is not present in the beta 5 interface**, and neither is the
> `Transcript.CustomSegment` protocol it carried. Both were in the 2026-07-29 capture; the removal
> happened between that capture and beta 5. See §13.2 for the status note and safe default.

Note that `appendText` and `replaceTextSegment` carry a `segmentID:` in the skill's spelling, while
every call site in shipping code omits it — `.appendText(text, tokenCount: 1)`. It therefore has a
default. Use the two-argument form unless you are managing multiple text segments in one entry.

#### Reasoning actions — `.reasoning(entryID:action:)`

> ✅ **VERIFIED** — `SKILL.md:373-379`:
>
> | Action | When to use |
> |---|---|
> | `.appendText(_:segmentID:tokenCount:)` | *"Append reasoning text to the entry's current text segment. The common case for streaming a thought block."* |
> | `.replaceTextSegment(_:segmentID:tokenCount:)` | *"Replace the entry's current reasoning text segment wholesale."* |
> | `.updateSignature(_:tokenCount:)` | *"Replace the entry's signature wholesale. Pass opaque bytes as `Data` — **don't UTF-8 decode signatures assuming text**."* |
> | `.updateMetadata(_:)` | *"Wholesale metadata snapshot for the reasoning entry."* |
> | `.updateUsage(input:output:)` | *"Cumulative usage totals… **Reasoning-token totals are also accumulated separately by the framework from `appendText` token counts**, so emit `updateUsage` only when your provider reports authoritative totals."* |

That last clause is easy to miss and it is the difference between correct and double-counted
reasoning tokens: the framework is already adding up your `tokenCount:` arguments. Send
`updateUsage` only when you have a number from the provider that supersedes them.

**`entryID` is optional on reasoning, and only on reasoning:**

> ✅ **VERIFIED** — `SKILL.md:371`: *"`entryID` is **optional**. Pass `nil` to coalesce into the
> trailing reasoning entry — if the most-recent consumed event was also reasoning, the framework
> reuses that entry's id; otherwise it mints a fresh UUID. Pass an explicit id when you need a stable
> anchor (e.g. a per-tool-call reasoning entry that you'll reference again from a separate emission
> point)."*

#### Tool-call actions — `.toolCalls(entryID:action:)`, outer and inner

> ✅ **VERIFIED** — `SKILL.md:385-399`. The outer enum:
>
> | Outer action | When to use |
> |---|---|
> | `.toolCall(id:name:action:)` | *"Wraps a per-call event. `id` selects (or opens) the tool call; **`name` carries the function name on every event for that id**; `action` names the mutation."* |
> | `.removeToolCall(_:)` | *"Drop a tool call the model streamed and then retracted. Pass the `Transcript.ToolCall` to remove."* |
> | `.updateMetadata(_:)` | *"Entry-level metadata snapshot. Prefer per-call metadata via `.toolCall(..., .updateMetadata(...))` for values that belong to one specific call."* |
> | `.updateUsage(input:output:)` | *"Usage totals. Cumulative, not additive — each event REPLACES prior totals."* |
>
> and the inner `ToolCall.Action`:
>
> | Inner action | When to use |
> |---|---|
> | `.appendArguments(_:tokenCount:)` | *"The first inner event for a given `id` opens the tool call; subsequent events with the same `id` append argument text. **Deltas for parallel tool calls may be interleaved** — each event carries its own `id` to distinguish them."* |
> | `.updateMetadata(_:)` | *"Per-call metadata snapshot… **Emit this BEFORE the first `.appendArguments` for the id** so the metadata lands on the call when it's first written."* |

Two beta-3 spelling changes here, both from commit `376ca60`: `.removeToolCall(id:)` became
**`.removeToolCall(_:)`** taking a `Transcript.ToolCall`, and `.removeAttachmentSegment(id:)` became
**`.removeAttachmentSegment(_:)`** taking an `AttachmentSegment`. Both now take the *value*, which
means you must keep the value around (or rebuild an equal one) if you might need to remove it.

**You do not accumulate arguments.** Apple's comment in the shipping executor is explicit:
*"Argument accumulation is the framework's job — we just forward each delta via `.appendArguments`."*
(`ChatCompletionsLanguageModel.swift:287-288`.)

### 9.2 The complete emission skeleton

Apple's skill contains a full worked `respond` covering every provider event kind. It is the most
useful single listing in the 815 lines and it is reproduced here from `SKILL.md:151-248`, verbatim:

```swift illustrative
public func respond(
  to request: LanguageModelExecutorGenerationRequest,
  model: MyLanguageModel,
  streamingInto channel: LanguageModelExecutorGenerationChannel
) async throws {
  // 1. Translate `request` into your provider's request format.
  // 2. Open the stream to your provider. The transport is your choice —
  //    URLSession.bytes, a vendored SDK, gRPC, WebSocket, anything that
  //    yields an async sequence of provider events.
  // 3. For each provider event, translate it into one or more channel
  //    events and send them. Use the same `entryID` for all events that
  //    belong to one response entry; use a DIFFERENT `entryID` for the
  //    tool-calls entry.

  let responseEntryID = UUID().uuidString
  let toolCallsEntryID = UUID().uuidString
  let reasoningEntryID = UUID().uuidString

  for try await providerEvent in openProviderStream(for: request) {
    try Task.checkCancellation()

    switch providerEvent {
    case .textDelta(let text):
      await channel.send(
        .response(entryID: responseEntryID, action: .appendText(text, tokenCount: 1))
      )

    case .toolCallStart(let id, let name):
      await channel.send(
        .toolCalls(
          entryID: toolCallsEntryID,
          action: .toolCall(id: id, name: name, action: .appendArguments("", tokenCount: 0))
        )
      )

    case .toolCallArgsDelta(let id, let name, let args):
      await channel.send(
        .toolCalls(
          entryID: toolCallsEntryID,
          action: .toolCall(id: id, name: name, action: .appendArguments(args, tokenCount: 1))
        )
      )

    case .toolCallRetracted(let toolCall):
      // Drop a tool call the model started streaming and then retracted.
      // `removeToolCall` takes the `Transcript.ToolCall` to drop.
      await channel.send(
        .toolCalls(entryID: toolCallsEntryID, action: .removeToolCall(toolCall))
      )

    case .reasoningDelta(let text):
      // Reasoning is its own top-level event. Pass `entryID: nil` to
      // coalesce consecutive deltas into the trailing reasoning entry, or
      // pass a stable id (as below) when you want to anchor a specific
      // entry — for example, a per-tool-call reasoning entry that you'll
      // close before tool-call deltas begin.
      await channel.send(
        .reasoning(entryID: reasoningEntryID, action: .appendText(text, tokenCount: 1))
      )

    case .reasoningSignature(let signature):
      // Wholesale replacement of the entry's signature bytes. `signature`
      // is opaque provider-supplied data — pass it through as `Data`.
      await channel.send(
        .reasoning(entryID: reasoningEntryID, action: .updateSignature(signature, tokenCount: 0))
      )

    case .usage(let prompt, let cached, let completion, let reasoning):
      await channel.send(
        .response(
          entryID: responseEntryID,
          action: .updateUsage(
            input: .init(totalTokenCount: prompt, cachedTokenCount: cached),
            output: .init(totalTokenCount: completion, reasoningTokenCount: reasoning)
          )
        )
      )

    case .done:
      return
    }
  }
}
```

The usage payload types are named in MLX's mirror enum
(`MLXLanguageModel.swift:686-690`, `:721-726`): `LanguageModelExecutorGenerationChannel.Usage.Input`
with `totalTokenCount:` and `cachedTokenCount:`, and `…Usage.Output` with `totalTokenCount:` and
`reasoningTokenCount:`. The metadata value type is
`[String: any Sendable & Codable & Equatable]` (`MLXLanguageModel.swift:713-715`).

### 9.3 `entryID` hygiene, and the coalescing rule that explains it

> ✅ **VERIFIED** — `SKILL.md:650-657`, Apple's complete rule set:
>
> - *"Generate a fresh UUID for each top-level response entry."*
> - *"Generate a SEPARATE fresh UUID for the tool-calls entry. **They must not collide.**"*
> - *"For reasoning entries, you have two patterns: **coalesce consecutive deltas** (pass
>   `entryID: nil`), or **anchor a specific entry** (pass a stable id you generated)."*
> - *"Reuse the same UUID for every event within one entry (every `appendText`, every
>   `updateUsage`)."*

The *why* is a framework behaviour stated nowhere else in the corpus, and it comes with a test:

> ✅ **VERIFIED** — `ChatCompletionsLanguageModel.swift:291-297`, verbatim comment and code:
>
> ```swift
> // Stable entryIDs per event type for the duration of this stream.
> // Without these, interleaved reasoning/response/toolCalls chunks would
> // split into multiple transcript entries — the framework only coalesces
> // consecutive events of the same type into the trailing entry.
> let responseEntryID = UUID().uuidString
> let reasoningEntryID = UUID().uuidString
> let toolCallsEntryID = UUID().uuidString
> ```
>
> Pinned by a test: `ChatCompletionsTests+Reasoning.swift:64-95` interleaves
> `reasoning / text / reasoning / text` and asserts **exactly one** reasoning entry
> (`reasoningText == "First thought"`) and **exactly one** response entry
> (`responseText == "Hello world"`).

**The framework only coalesces *consecutive* events of the same type.** So a provider that emits
thought / text / thought / text — which reasoning models do constantly — will shatter into four
transcript entries unless you pass stable ids. Three UUIDs, minted once at the top of `respond`, and
the problem disappears. This is the cheapest correctness fix in the whole API and it is one line per
event kind.

MLX arrives at the same three-UUID pattern and records why the request's own id is *not* one of them:

> ✅ **VERIFIED** — `MLXLanguageModel.swift:991-997`: *"Per SKILL.md: response and tool-calls entries
> each need a fresh UUID — they live in separate transcript entries. **We preserve the
> framework-supplied `request.id` for tracing by stamping it into the response metadata below, rather
> than reusing it as an entry id.**"*

### 9.4 ⚠️ Wholesale, not additive

> ⚠️ **SILENT FAILURE — `updateMetadata` deletes keys you stop sending.** Apple states it twice:
> *"`updateMetadata` are wholesale snapshots. **A subsequent event with fewer items REMOVES the
> missing ones.** Re-emit everything you want preserved."* (`SKILL.md:805`), and per-call:
> *"Replaces the call's metadata wholesale — re-emit every key you want preserved."* (`:399`).
>
> The failure is silent in both directions. Send `["modelID": x, "requestID": y]` at the start and
> `["tokensPerSecond": z]` at the end, and the developer's final metadata dictionary contains
> **only** `tokensPerSecond`. No error; the earlier keys simply are not there. Developers will report
> it as "your metadata is flaky."
>
> **Build the dictionary once, as a `var`, and re-send the whole thing every time.** Never construct
> a metadata literal at a second call site.

The same rule governs usage, with a subtlety about ordering:

> ✅ **VERIFIED** — `SKILL.md:804`: *"**`updateUsage` is wholesale, not additive.** Always send
> cumulative totals from the provider — never deltas."*
>
> and the interaction with `appendText`'s `tokenCount:`, from Apple's own executor
> (`ChatCompletionsLanguageModel.swift:345-346`):
>
> ```swift
> // Send usage AFTER content so the authoritative cumulative total
> // overwrites any tokens credited by `appendText` for this chunk.
> ```
>
> Every `appendText`/`appendArguments` in that file passes `tokenCount: 1` — a placeholder, because
> the executor cannot tokenize what the server produced. The framework accumulates those, and the
> authoritative `updateUsage` overwrites the accumulation. The test that pins this is
> `ChatCompletionsTests+UsageReporting.swift:108-139`, whose own comment reads: *"The framework treats
> `updateUsage` as wholesale replacement, so the final reported usage should reflect the last
> cumulative value."* Three chunks reporting completion counts 1, 2, 3 produce a final
> `output.totalTokenCount == 3` — **not 6**.

So `tokenCount:` on a delta is a *running credit* the framework maintains, and `updateUsage` is an
*override*. If you can tokenize locally, pass real counts and you may never need `updateUsage`. If
you cannot, pass 1 and correct at the end.

### 9.5 Two smaller channel rules, both from Apple's pitfall list

> ✅ **VERIFIED** — `SKILL.md:806-810`:
>
> - *"**Every `.toolCall(id:name:action:)` event must carry the function `name`** — not just the
>   opener. Subsequent events for the same `id` should pass the same `name`."*
> - *"**Use `.removeToolCall(_:)` when the model retracts a streamed tool call** rather than trying to
>   mutate prior argument deltas — **there is no `replaceArguments` equivalent** for tool calls."*
> - *"**Attachments add, they don't replace.** … To supersede a streamed attachment, send
>   `.removeAttachmentSegment(_:)` followed by a fresh `.addAttachmentSegment(...)` — there is no
>   `replaceAttachmentSegment`."*
> - *"**Don't try to 'fix up' prior text via mutation.** Use `replaceTextSegment` if your provider
>   sends a final corrected version."*

The "carry the name on every event" rule is the one that bites, because most wire protocols send the
function name **once**, on the opening delta, and then send argument fragments only. You have to
latch it. Apple's implementation:

```swift illustrative
var toolCallRouting: [Int: (id: String, name: String)] = [:]   // :289
…
for toolCallDelta in toolCallDeltas {                          // :311
  let existing = toolCallRouting[toolCallDelta.index] ?? (id: "", name: "")
  let routing = (
    id:   existing.id   + (toolCallDelta.id ?? ""),            // :314
    name: existing.name + (toolCallDelta.function?.name ?? "") // :315
  )
  toolCallRouting[toolCallDelta.index] = routing
  guard !routing.id.isEmpty, !routing.name.isEmpty else { continue }   // :319
  await channel.send(
    .toolCalls(
      entryID: toolCallsEntryID,
      action: .toolCall(
        id: routing.id, name: routing.name,
        action: .appendArguments(toolCallDelta.function?.arguments ?? "", tokenCount: 1))))
}
```

Note the routing key: the wire protocol's `index`, not the id — because the id itself may arrive in
fragments. And note the `guard` at `:319`: **nothing is emitted until both id and name are non-empty**,
which is what stops a nameless partial call from reaching the transcript.

> ⚠️ **Two fragilities in that exact code, worth not copying blindly.** The latch uses `+` (string
> concatenation) rather than `??`, so a server that **repeats the full id on every delta** — which is
> legal and which some servers do — produces `"call_1call_1call_1"`. And the `else if` at `:335`
> means **a chunk carrying both `tool_calls` and `content` drops the `content` entirely**. Neither is
> covered by a test. If you are writing a chat-completions client, prefer
> `existing.id.isEmpty ? (delta.id ?? "") : existing.id` and handle both fields in the same chunk.

### 9.6 Cancellation

> ✅ **VERIFIED** — `SKILL.md:637-648`: *"`respond(to:model:streamingInto:)` runs in a Task that may be
> cancelled. Check inside your stream loop:*
>
> ```swift
> for try await providerEvent in openProviderStream(for: request) {
>   try Task.checkCancellation()
>   // ...
> }
> ```
>
> *When cancelled, return or throw `CancellationError()`. **The framework manages the channel lifetime
> around your `respond(...)` call** — you don't need to do anything else on cancellation."*

> ⚠️ **Apple's own executor does not do this.** There is no `try Task.checkCancellation()` anywhere in
> `ChatCompletionsLanguageModel.swift`; the only cancellation handling is
> `continuation.onTermination = { _ in task.cancel() }` at `:630`, which cancels the URLSession task
> when the stream's consumer goes away. For a network client that is *mostly* sufficient. For a local
> engine it is not — a generation loop with no cancellation check keeps burning GPU after the user
> has closed the view. **Follow the skill here, not the sample.**

### 9.7 🔴 The `updateUsage` symbol that exists in the interface and not in the dylib

This one is not a design point; it is a live beta hazard that crashes processes, and it is worth
knowing before you spend a day on it.

> ✅ **VERIFIED** — `MLXLanguageModel.swift:729-761`, the comment left in place of the call, quoted at
> length because every sentence is operational:
>
> > *"Usage is intentionally NOT forwarded to the FoundationModels channel on this SDK. The FM-27 beta
> > `.swiftinterface` declares `Response.Action.updateUsage(input:output:metadata: = [:])` (three
> > parameters), but the shipping FoundationModels dylib only exports the older two-parameter
> > `Response.Action.updateUsage(input:output:)`. Because our call relies on the `metadata:` default,
> > the compiler resolves it to the three-parameter symbol, **which does not exist at runtime**. dyld
> > cannot bind it: under **chained-fixups linking (the arm64 default) the reference aborts the
> > process the moment the image loads**, and under lazy binding it **faults through null (SIGSEGV at
> > 0x0)** the instant this send executes — crashing every `respond()` path right after generation
> > completes.*
> >
> > *A runtime `dlsym` guard cannot save this: the compiled reference to the missing symbol is enough
> > to abort at launch regardless of any surrounding check. **The only safe option is to not reference
> > the symbol at all**, so no `channel.send(.updateUsage(...))` here."*
>
> Recorded as commit `1c86cc1` in `ml-explore/mlx-swift-lm`. The stated effect: *"consumer-visible
> usage for these responses may be absent or zero."*

🔴 **GAP (updated 2026-08-23) — whether this is fixed in the SDK you are building against is still
unknown, and the interface side still declares the three-parameter form.** The macOS 27.0 beta 5
interface captured on this machine (Xcode 27 beta 5, 2026-08-20) **keeps**
`updateUsage(input:output:metadata: … = [:])` on all three `Action` types
(`FoundationModels-27.0-macos.swiftinterface:1863, :1871, :1886`; beta 5 retyped `metadata:` to
`[String : any ConvertibleToGeneratedContent]`) — so the interface/dylib split
the MLX comment describes cannot be ruled out from the interface alone; a `.swiftinterface` cannot
tell you what the dylib exports. Only an `nm`/`dyld_info` dump of the shipping
`FoundationModels.framework` binary, or a link-and-run test, settles it per SDK. **Safe default
unchanged:** call `updateUsage(input:output:)` with **both arguments explicit and no reliance on
any defaulted parameter**, exactly as `ChatCompletionsLanguageModel.swift:351-360` and
`MockModel.swift:95-99` do. If your package crashes at image load with an unbound
`FoundationModels` symbol, this is why, and the fix is to stop referencing the symbol — not to
guard the call.


---

## 10. The prescribed event order — and why not to follow it literally

Session 339 gives one explicit ordering recommendation, and it is the most actionable paragraph in
the session. It is also the recommendation most contradicted by shipping code. Both halves matter.

### 10.1 What Apple recommends, and the reasoning

> ✅ **VERIFIED** — 339:121–130, verbatim:
>
> *"put yourself in the developer's seat for a moment. They've called respond and they're waiting.
> What do they need first? Here's your executor's side of the handshake with the developer. **There's
> a deliberate order to it.**
>
> **First, a metadata update, model and request IDs the developer can use for logging and
> debugging.**
>
> **Then a usage update, prompt token counts for accounting. Sending these upfront means the
> developer isn't waiting through the whole stream to learn what each request costs.**
>
> **Finally, for each token your model produces, send a text delta the moment it arrives.** The
> framework streams those deltas to the session as they arrive, so users see the response appear
> word-by-word instead of all at once."*

**Prescribed order: `updateMetadata` → `updateUsage` (prompt tokens) → N × `appendText`.**

The reasoning is good and you should internalise it even if you deviate. A developer who has to wait
for `.done` to learn that their prompt was 14,000 tokens cannot show a cost estimate, cannot warn a
user before an expensive call completes, and cannot correlate a slow request with a log line. **Your
executor is the only thing that knows the prompt cost, and it knows it before generation starts.**

MLX follows the metadata half exactly:

```swift prelude:guide-context
// Send metadata first                                        // MLXLanguageModel.swift:1006-1009
await Self.emitMetadata(
    ["modelID": modelID, "requestID": request.id.uuidString],
    entryID: entryID, into: channel)
```

### 10.2 🚨 The verified contradiction

> 🚨 **Following the prescribed order literally materialises an empty `Response` entry on tool-calling
> turns.**
>
> **Community-measured**, verified on macOS 27.0 beta (M4 Max, 2026-06-11), recorded twice — in
> `fm-provider.md:129-132` and again as a comment at the top of the shipped executor it produced
> (`ZooExecutor.swift:14-18`):
>
> > *"**Don't send WWDC-339-style upfront usage/metadata.** A `.response(updateUsage:)` event on a
> > turn that ends in tool calls **materializes an EMPTY `Response` transcript entry.** Send metadata
> > + usage **once at end of turn**, attached to the **kind of entry the turn produced**."*
>
> The mechanism is a direct consequence of §9.1: the three top-level events are *peer transcript
> entry kinds*. A `.response(...)` event — of any action, including a pure-metadata or pure-usage one
> — tells the framework a response entry exists. If the turn then produces only tool calls, the
> transcript ends up with an empty response entry sitting next to the tool-calls entry.
>
> **Apple's own Core AI adapter does not follow the prescribed order either**: its usage send is at
> `CoreAILanguageModel.swift:468-476`, which runs *after* the generation loop and the parser flush.
> Apple's `ChatCompletionsLanguageModel` sends usage whenever the server reports it, which for
> OpenAI-compatible servers with `stream_options: {"include_usage": true}` is at the end. And Apple's
> own `MockModel` sends usage after the text.
>
> **So four out of four shipping implementations diverge from the session's advice**, and one
> independent measurement explains why.

### 10.3 How to actually order your events

Take the *intent* of the recommendation and route it correctly:

1. **Emit metadata first, on the entry kind you know the turn will produce.** If your provider tells
   you up front whether this turn is a tool call (many do — the first delta carries `tool_calls`),
   attach metadata to that entry. If you cannot know, buffer it.
2. **Emit prompt-token usage as early as you can *safely*** — meaning: as soon as you have emitted at
   least one content event on the entry that will exist anyway. On a text turn that is right after
   your first `appendText`, which costs the developer one token's worth of latency and preserves the
   whole benefit.
3. **Emit text deltas the moment they arrive.** No batching, no "flush every 50 ms." The framework
   and the app do the coalescing.
4. **Emit authoritative usage at the end**, once, as a wholesale override (§9.4).

If you can decide up front what kind of entry a turn produces, follow the session literally — it is
better developer experience. If you cannot, end-of-turn usage attached to the entry the turn actually
produced is the safe default, and it is what everyone shipping does today.

> 🔴 **GAP — whether the empty-`Response`-entry behaviour still reproduces on later 27 SDKs is
> unverified.** The measurement is from macOS 27.0 beta in June 2026 and no re-test exists in this
> corpus. Resolving it takes ten minutes: build a two-tool session against a model that reliably
> calls a tool, send `.response(entryID:action: .updateUsage(...))` before generation, and print
> `session.transcript`. Until someone does, treat the safe ordering above as the default.

---

## 11. Errors: approximate or throw

### 11.1 The rule

> ✅ **VERIFIED** — 339:143–156: *"**Sometimes your model can't do exactly what the developer asked.
> When that happens, your executor has two choices: approximate or throw.** **Be flexible where you
> can, and honor the developer's intent.** But sometimes there's no honest approximation. **If a
> developer sets a token limit, but also specifies a schema with required fields, there might not be
> a way to satisfy both. So you throw.** Foundation Models ships **`LanguageModelError`** for exactly
> these cases: **context window overflows, rate limits, refusals, and more.** Throw one of these, and
> **any developer who's used the framework already knows how to handle it**."*

and the balance rule for custom errors (339:151–156):

> *"When the built-in `LanguageModelError` cases don't cover your situation, define your own error
> type. Some failures only make sense in the context of your service: **your subscription tiers, your
> features, your account states.** A purpose-built case name carries the intent… **Custom errors are
> powerful, and sometimes you need them. But each one is a new case developers must learn, catch, and
> handle in their app. Try to use a built-in `LanguageModelError` when it fits, and save the custom
> ones for failures only your service can produce.**"*

### 11.2 All nine cases

> ✅ **VERIFIED** — `SKILL.md:545-557`, the complete table with payload fields and Apple's own
> guidance on when to throw each:
>
> | Case | Payload-specific fields | When to throw |
> |---|---|---|
> | `.contextSizeExceeded(ContextSizeExceeded)` | `contextSize: Int`, `tokenCount: Int` | *"The transcript would exceed the model's context window. The developer can recover by trimming entries and retrying."* |
> | `.rateLimited(RateLimited)` | `resetDate: Date?` | *"Provider returned 429 / a burst-throttling signal. Include `resetDate` when the provider tells you when retries will succeed."* |
> | `.guardrailViolation(GuardrailViolation)` | — | *"Provider's safety system flagged the prompt or the response."* |
> | `.refusal(Refusal)` | initializer input `explanation: String`; readable `explanation` is `async throws -> LanguageModelSession.Response<String>` | *"Model declined to answer for non-safety reasons (e.g. asked for something out of scope). Surfaced to the developer via `refusal.explanation` / `refusal.explanationStream`."* In practice, read the generated message from `(try await refusal.explanation).content`.[^refusal-response] |
> | `.unsupportedCapability(UnsupportedCapability)` | `capability: LanguageModelCapabilities.Capability` | *"A capability you didn't declare was requested. **The framework throws this for you when you under-declare** — only throw it manually when your provider rejects a capability mid-stream."* |
> | `.unsupportedTranscriptContent(UnsupportedTranscriptContent)` | `unsupportedContent: [Transcript.Entry]` | *"The transcript contains content the model can't process — unsupported file types, corrupted data, or a custom segment your provider doesn't recognize."* |
> | `.unsupportedGenerationGuide(UnsupportedGenerationGuide)` | `schemaName: String?` | *"The generation schema uses a guide your provider doesn't support (e.g. an exotic regex pattern)."* |
> | `.unsupportedLanguageOrLocale(UnsupportedLanguageOrLocale)` | `languageCode: Locale.LanguageCode` | *"The model declined the request because the prompt language isn't supported."* |
> | `.timeout(Timeout)` | — | *"Request didn't complete within the configured timeout window."* |
>
> Plus, universally (`SKILL.md:559`): *"Every payload struct exposes `debugDescription: String`
> (developer-facing message — **include the provider's raw error string**) and
> `metadata: [String: any Sendable]` (free-form bag for extra context like provider error code or
> request id), in addition to the case-specific fields shown above."*
>
> The enum is **non-frozen**. Independent corroboration of five of the nine cases —
> `.timeout`, `.guardrailViolation`, `.refusal`, `.contextSizeExceeded`,
> `.unsupportedLanguageOrLocale` — comes from Apple's 2026 sample projects, where they appear in an
> app's `catch` ladder; four more (`.unsupportedCapability`, `.unsupportedTranscriptContent`,
> `.unsupportedGenerationGuide`, plus `.rateLimited` from the skill) appear at real throw sites in
> provider code.

Every case is a two-step construction: the enum case wraps a payload struct of the same name in
UpperCamelCase. Apple's examples, verbatim (`SKILL.md:561-614`), abridged to four:

```swift compile:27 imports:Foundation
import FoundationModels

throw LanguageModelError.contextSizeExceeded(
  LanguageModelError.ContextSizeExceeded(
    contextSize: 200_000,
    tokenCount: 220_000,
    debugDescription: "Prompt exceeds context window"
  )
)

throw LanguageModelError.rateLimited(
  LanguageModelError.RateLimited(
    resetDate: Date().addingTimeInterval(60),
    debugDescription: "HTTP 429"
  )
)

throw LanguageModelError.unsupportedGenerationGuide(
  LanguageModelError.UnsupportedGenerationGuide(
    schemaName: "ItineraryDay",
    debugDescription: "Regex anchors are not supported by this model"
  )
)

throw LanguageModelError.timeout(
  LanguageModelError.Timeout(debugDescription: "Request did not complete within configured timeout")
)
```

A beta-3 change to watch for: **`.refusal(Refusal)` gained a required `explanation: String`**, and
the skill's former example constructing `LanguageModelError.Refusal(debugDescription:)` alone was
deleted in commit `376ca60` because it no longer compiles.

Real throw sites in the corpus, for the shapes you will actually write most:

```swift prelude:guide-context
// Under-declared capability rejected at runtime — MLXLanguageModel.swift:960-965
throw LanguageModelError.unsupportedCapability(
    LanguageModelError.UnsupportedCapability(
        capability: .vision,
        debugDescription:
            "This request includes an image, but .vision was not declared at MLXLanguageModel init. Declare .vision to accept image inputs."
    ))

// Content you cannot represent — ChatCompletionsLanguageModel.swift:450-456
throw LanguageModelError.unsupportedTranscriptContent(
  LanguageModelError.UnsupportedTranscriptContent(
    unsupportedContent: [entry],
    debugDescription: "Custom segments are not supported by \(Self.self)"
  )
)
```

Note `\(Self.self)` in the debug description — a small habit worth copying, since a developer with
three provider packages installed needs to know *which* one refused.

### 11.3 ⚠️ Apple's own executor throws none of them

This is the sharpest gap between Apple's written guidance and Apple's shipped sample, and you should
know about it before you use `ChatCompletionsLanguageModel` as your template.

> ⚠️ **`ChatCompletionsLanguageModel` throws exactly one `LanguageModelError` case, and it is not one
> of the interesting ones.** The complete list of what it throws, by condition, verified across all
> 953 lines:
>
> | Condition | Thrown | Line |
> |---|---|---|
> | Top-K sampling requested | `RequestError.invalidRequest("Top K sampling is not supported")` | :373 |
> | Random seed set | `RequestError.invalidRequest("Setting a random seed is not supported")` | :378 |
> | Unknown sampling mode | `RequestError.invalidRequest("Unknown sampling mode …")` | :384 |
> | **Non-200 HTTP — including 429, including 413** | **`RequestError.httpError(statusCode:data:)`** | :592, :610 |
> | SSE `data:` payload not UTF-8 | `RequestError.invalidStreamData` | :666 |
> | SSE payload decodes as an error envelope | `APIError(message:type:param:code:)` | :677 |
> | Custom / unknown / unsupported segment | `LanguageModelError.unsupportedTranscriptContent` | :424, :443, :451, :459 |
>
> **A 429 becomes a generic `RequestError.httpError`, never `.rateLimited`.** A context-window
> rejection becomes `RequestError.httpError`, never `.contextSizeExceeded`. A safety refusal becomes
> `RequestError.httpError`. Every one of those is a case Apple's own skill tells third parties to map
> (`SKILL.md:549-551`), and the weak typing is baked into the tests too: the 429 test asserts only
> `#expect(throws: (any Error).self)` (`ChatCompletionsTests+ErrorHandling.swift:21-30`).
>
> **Ruling:** the skill wins. It is prescriptive documentation written for this exact task; the
> executor is a reference client for a wire protocol whose error semantics vary by vendor. But do not
> copy its error handling — copy its transcript translation and write your own error mapping. A
> developer who cannot distinguish "you are rate limited, retry in 60 s" from "your JSON was
> malformed" cannot build a recovery path, and recovery paths are most of what production AI code is.

Apple's own last word on the subject is worth quoting because it forbids the other common mistake:

> ✅ **VERIFIED** — `SKILL.md:635`: *"**Don't catch transport errors and convert them to generic
> strings.** Let them propagate, or wrap into `LanguageModelError.timeout` only when you know that's
> what they represent."*

### 11.4 When *not* to map an error

The reverse mistake — over-eager mapping — is subtler, and MLX documents the reasoning better than
anyone:

> ✅ **VERIFIED** — `MLXLanguageModel.swift:855-864`: *"`constraintCompilationFailed` is
> **deliberately NOT mapped** to `unsupportedGenerationGuide`: its origin is ambiguous… and
> **claiming user-fault when the cause is actually our infrastructure misleads developers who
> pattern-match on typed errors.**"*

`unsupportedGenerationGuide` says *"your schema is the problem."* If your grammar compiler fell over
for a reason that might be your bug, saying that sends the developer to rewrite a schema that was
fine. **A typed error is an assertion about blame. Only make it when you are sure.**

### 11.5 Plan limits and custom errors

> ✅ **VERIFIED** — `SKILL.md:616-632`: *"If your service has plan tiers and the user has exhausted
> theirs, surface it as a structured error so app developers can present an upsell or fall-back path.
> Two reasonable approaches:*
>
> - ***`rateLimited` with a `resetDate`** — when the limit resets on a known schedule (per-minute,
>   per-day).*
> - ***A custom error type** that conforms to `LocalizedError` and ships in your package, when the
>   user needs to upgrade their account. Optionally include a sign-up URL the developer can wire to
>   their UI."*
>
> ```swift
> public enum MyServiceError: Error, LocalizedError {
>   case planLimitReached(upgradeURL: URL?)
>
>   public var errorDescription: String? {
>     switch self {
>     case .planLimitReached: "Your plan limit has been reached."
>     }
>   }
> }
> ```

The line between the two is the one the session drew: **a limit that time will fix is `rateLimited`;
a limit that only money will fix is yours.** Conform to `LocalizedError` either way — Apple's own
`RequestError` and `APIError` both do (`ChatCompletionsLanguageModel.swift:109`, `:146`) — so that a
developer who does nothing at all still shows a sentence rather than a type name.


---

## 12. Step 3 — Authentication

This section is short in the session and short here, but it contains the one piece of advice most
provider packages get wrong on day one.

> ✅ **VERIFIED** — 339:157–167, verbatim: *"**Your job as a package author is to make it easy for
> developers to do the right thing. If your initializer takes an API key as a string, developers will
> be tempted to take the path of least resistance. Instead, help developers do the right thing by
> offering a token provider or sign in flow.** **And if your package fetches access tokens on behalf
> of developers, make sure to persist them securely using Keychain.** Credential handling is half the
> story. **Device attestation is the other half.** If you're shipping a **cloud-based `LanguageModel`
> package, this is worth a deep look.** This related session walks through **verifying the device,
> catching tampered builds, signing payloads, and using Apple's fraud signal to keep bad traffic off
> your service.** Check it out in '**Secure your apps with App Attest**'."*

### 12.1 Why `init(apiKey: String)` is the wrong *primary* path

The problem is not that the string is insecure in memory. It is that **the path of least resistance
for the developer is to type the key into the call site**, which means the key goes into their source
file, which means it goes into their repository and into their app binary, where anyone with a
`strings` command can read it. Your API shape decides which of those happens.

So: offer the flow first, the key second.

Apple's skill shows both on one type, and the ordering of the initializers in the file is itself the
lesson (`SKILL.md:79-101`):

```swift prelude:guide-context
public struct MyLanguageModel: Sendable {
  public let modelID: String
  public let baseURL: URL
  public let timeout: TimeInterval
  let authMode: AuthMode

  /// Initialize with an OAuth-backed credential store.
  public init(name: String, baseURL: URL, timeout: TimeInterval = 60) {
    self.modelID = name
    self.baseURL = baseURL
    self.timeout = timeout
    self.authMode = .oauth(accountID: OAuthSession.shared.accountID)
  }

  /// Initialize with a developer-supplied API key.
  public init(name: String, apiKey: String, baseURL: URL, timeout: TimeInterval = 60) {
    self.modelID = name
    self.baseURL = baseURL
    self.timeout = timeout
    self.authMode = .apiKey(apiKey)
  }

  /// Trigger an OAuth sign-in flow if the user is not already authenticated.
  /// No-op when the model was created with an API key.
  public func authenticateIfNeeded() async throws {
    if case .oauth = authMode {
      try await OAuthSession.shared.authenticateIfNeeded()
    }
  }
}

public enum AuthMode: Hashable, Sendable {
  case oauth(accountID: String)   // package looks up the live token at request time
  case apiKey(String)
}
```

Four design decisions in that listing, all of them deliberate:

**The default initializer has no credential parameter at all.** `init(name:baseURL:)` is the one a
developer reaches for first, and it enrols them in the sign-in flow by construction.

**`AuthMode` is `Hashable` and `Sendable` because it goes into `Configuration`.** This is the auth
decision leaking into the protocol, and it is the reason auth appears in a guide about protocols:

> ✅ **VERIFIED** — `SKILL.md:347`: *"The `Configuration` should hash on a stable identity (the OAuth
> `accountID`, or the API key itself) so **two sessions for two different users get distinct cached
> executors**."*

Get this wrong and two users share an executor, which for a stateful backend means one user's KV
cache answers the other user's question. **Never store the live token in `Configuration`** — store
the *account identity*. The token rotates; the identity does not, and a rotating token would churn
your executor cache on every refresh.

**`.oauth(accountID:)` carries an id, not a token.** Apple's inline comment says exactly what happens
instead: *"package looks up the live token at request time."* Your executor asks the credential store
for a token inside `respond`, on every request, and the store deals with refresh.

**`authenticateIfNeeded()` is idempotent and safe to call anywhere.**

> ✅ **VERIFIED** — `SKILL.md:330-337`:
>
> ```swift
> public func authenticateIfNeeded() async throws {
>   if try await OAuthSession.shared.currentAccessToken() == nil {
>     try await OAuthSession.shared.runOAuthFlow()
>   }
> }
> ```
>
> *"Make `authenticateIfNeeded()` idempotent. App developers will call it on app launch or before the
> first `respond(...)`."*

Both of those are true: they will call it on every view appearance, in a `task {}` modifier that
re-runs, and concurrently from three places. Make it a no-op when there is a valid token, and
de-duplicate concurrent flows.

### 12.2 Keychain, and what the transcript actually asks for

Four concrete requirements, each traceable to a sentence in 339:157–167:

1. **Do not expose `init(apiKey: String)` as the primary path.** §12.1.
2. **Offer a token provider closure or a sign-in flow.** A closure —
   `tokenProvider: @Sendable () async throws -> String` — is the lighter option and composes with
   whatever identity system the app already has. A sign-in flow is right when the account is *yours*.
3. **Persist fetched tokens in the Keychain.** Note the precise scope: *"if your package **fetches**
   access tokens on behalf of developers."* If the developer hands you a key, storing it is their
   problem; if you obtained it, it is yours.
4. **Integrate App Attest** for device attestation — *"verifying the device, catching tampered
   builds, signing payloads, and using Apple's fraud signal."*

> 🔴 **GAP — no App Attest integration exists anywhere in this corpus.** Session 339 points at a
> separate session ("Secure your apps with App Attest") that was not captured, and neither
> `foundation-models-utilities` nor `mlx-swift-lm` nor any community provider contains a line of
> `DCAppAttestService`. So this guide can tell you *that* Apple recommends attestation for
> cloud-backed provider packages and *what for*, but it cannot show you the integration or tell you
> where in the request path the assertion belongs. Resolving this needs that session or Apple's
> App Attest documentation. **Safe default meanwhile:** ship without attestation rather than shipping
> a half-understood attestation — a broken attestation check locks out legitimate users, which is a
> worse failure than the fraud it prevents. Design the seam now (an `assertionProvider` closure your
> client calls before signing a request) so adding it later is not a breaking change.

Note also what Apple's own `ChatCompletionsLanguageModel` does about auth: **nothing**. It exposes
`additionalHeaders: [String: String]` and documents it as *"Use this to provide authorization tokens
or other vendor-specific headers"* (`:49-52`), with caller headers winning on collision
(`:220-228`). That is the correct design for a *generic* client pointed at any endpoint, and the
wrong design for a package that fronts one service. Know which one you are writing.

---

## 13. Step 4 — Customization

The last step is where the protocol stops being a lowest common denominator. Apple's framing:

> ✅ **VERIFIED** — 339:171: *"The protocol gives you room to **shape `LanguageModelSession` around
> the abilities only your model offers**."*

### 13.1 Response metadata — the lightweight option

> ✅ **VERIFIED** — 339:171–178: *"**Response metadata is a lightweight option** to attach additional
> information to your responses… Here, after streaming completes, our executor sends
> **`tokensPerSecond`** and **`timeToFirstToken`** through the channel. **We recommend providing
> utilities or documentation that make it easy for developers to work with your metadata; clear keys,
> typed accessors, whatever makes sense.** Underneath, **metadata is just a dictionary. It can
> contain strings, numbers, and other built-in types.**"*

🟡 **RECONSTRUCTED** — the session's on-screen snippet was described, not read aloud. Written in the
verified action spelling and with the verified value type, it is:

```swift prelude:guide-context
await channel.send(
    .response(
        entryID: entryID,
        action: .updateMetadata([
            "tokensPerSecond": tokensPerSecond,
            "timeToFirstToken": timeToFirstToken,
        ])))
```

The **key names `tokensPerSecond` and `timeToFirstToken` are spoken in the session** and are
therefore attested; the surrounding call is the verified `.updateMetadata(_:)` action on
`.response(entryID:action:)` with the value type
`[String: any Sendable & Codable & Equatable]` (`MLXLanguageModel.swift:713-715`). Real analogues in
shipping code: `["modelID": modelID, "requestID": request.id.uuidString]`
(`MLXLanguageModel.swift:1007-1009`) and a `Bool` value, `["incompleteOutput": true]` (`:1228-1229`).

Three practical rules:

- **Re-emit every key on every `updateMetadata`** (§9.4). This bites hardest exactly here, because
  performance metrics naturally arrive at different times from identifiers.
- **Take the "typed accessors" advice literally.** Ship
  `extension LanguageModelSession.Response { var tokensPerSecond: Double? }` — or whatever the
  response-metadata accessor turns out to be on your consumers' side — so developers are not writing
  `metadata["tokensPerSecond"] as? Double` in three files.
- **Metadata is per entry.** Attach performance numbers to the entry the turn produced, not
  unconditionally to `.response` (§10.2).

### 13.2 Custom segments — the extension point for new modalities

> 🔴 **NOT PRESENT IN THE 27.0 BETA 5 INTERFACE (noted 2026-08-23).** Everything in this section
> describes a surface the recaptured beta 5 `FoundationModels-27.0-macos.swiftinterface` no longer
> declares: it contains **zero occurrences of `CustomSegment`** — no `Transcript.CustomSegment`
> protocol, no `Transcript.Segment.custom(_:)` case (`Segment` is now `.text` / `.structure` /
> `.attachment`, `27.0:2288-2297`), and no `.updateCustomSegment(_:)` response action
> (`Response.Action`'s statics are now `appendText` / `replaceTextSegment` / `addAttachmentSegment`
> / `removeAttachmentSegment` / `updateMetadata` / `updateUsage`, `27.0:1857-1864`). All three were
> in the 2026-07-29 beta capture; the removal happened between that capture and beta 5, while WWDC
> session 339, the provider SKILL.md, and the docs index still teach the surface. **Do not build a
> provider contract on `.updateCustomSegment(...)` against the beta 5 SDK — it does not compile.**
> The section is retained below, re-scoped as the pre-beta-5 design, because it is the best
> statement of the *intent* Apple has published and the surface may return in a later beta.
>
> 🔴 **GAP — no declared successor.** What is unknown: whether the removal is final, and what (if
> anything) replaces provider-defined structured segments. What would resolve it: a later beta's
> interface, or release notes. **Safe default:** ship structured payloads through the surfaces that
> *are* in the beta 5 interface — `.updateMetadata(_:)` (now typed
> `[String : any ConvertibleToGeneratedContent]`, `27.0:1862`) attached to a text segment, or
> attachment segments for media (`27.0:1860-1861`) — which is also the lower-lock-in design this
> section's own portability warning already recommended. `Transcript.Segment.structure(_:)` still
> exists in transcripts (`27.0:2290`), but the beta 5 channel offers **no response action that
> emits one**.

This was the most forward-looking API in the session, and the one thing in the protocol that let a
third party extend the *framework's* vocabulary rather than just consume it.

> ✅ **VERIFIED** — 339:179–189: *"**Custom segments are the answer.** You'll **define a new segment
> type, receive it in your executor, and stream results back through the same channel**, and the
> developer **never has to leave `LanguageModelSession`** to use them. **Custom segment types let you
> extend the protocol. When a new modality comes along, audio, video, whatever's next, developers
> have a typed, structured way to send that data to your model.**
>
> Here's how it works. First, you'll **define a type that conforms to custom segment. Because custom
> segments are required to be `PromptRepresentable`, developers can pass it directly in their
> prompts, just like text.** In your executor, you'll **receive this as a `customSegment` in the
> transcript, alongside the text entries you're already handling.** When your model responds, you
> **emit the result back through the channel as a custom segment update.** **The segment ID controls
> whether you're adding a new segment, or updating one you've already started streaming. This gives
> you full control over how results stream into the app.**"*

The protocol itself is verified, and it is a *protocol*, not a type:

> ✅ **VERIFIED** — `SKILL.md:403-415`: *"`Transcript.CustomSegment` is a **protocol**, not a concrete
> type. When your provider returns a structured payload that doesn't fit any of the framework's
> built-in segment kinds (text, reasoning, citations, advisories), define your own type that conforms
> to the protocol, and ship it inside an `.updateCustomSegment(...)` event."*
>
> ```swift
> public protocol CustomSegment: Sendable, Identifiable, Equatable, CustomStringConvertible,
>   PromptRepresentable, InstructionsRepresentable
> {
>   associatedtype Content: Sendable & Equatable & Codable
>
>   var id: String { get }
>   var content: Content { get }
> }
> ```

Note the six conformances the protocol requires, and in particular the reason for the last two:

> ✅ **VERIFIED** — `SKILL.md:418`: *"The associated `Content` type is yours to design — it just has to
> be `Sendable & Equatable & Codable`. **The framework uses `PromptRepresentable` /
> `InstructionsRepresentable` to know how to fold the segment back into a future prompt when this
> entry becomes part of the transcript on a subsequent turn**, so make those conformances render the
> segment in a form the model can usefully read."*

That sentence is the whole design. A custom segment is not an out-of-band side channel; it is a
first-class transcript citizen, which means on turn N+1 it has to become *prompt text again*. Your
`promptRepresentation` is what the model will read next turn. Write it as though the model is the
audience, because it is.

Apple's complete worked example (`SKILL.md:420-446`), verbatim — a web-search results segment, which
is exactly the server-side-tool case of §13.4:

```swift illustrative
// ⚠️ Pre-beta-5 surface — Transcript.CustomSegment and .updateCustomSegment(_:) are
// not present in the Xcode 27 beta 5 interface; this no longer compiles (see the
// status note at the top of §13.2).
public struct WebSearchResults: Transcript.CustomSegment {
  public let id: String
  public let content: [Result]

  public struct Result: Sendable, Equatable, Codable {
    public let title: String
    public let url: URL
    public let snippet: String
  }

  public var description: String {
    content.map { "• \($0.title) — \($0.url)" }.joined(separator: "\n")
  }

  public var promptRepresentation: Prompt { Prompt(description) }
  public var instructionsRepresentation: Instructions { Instructions(description) }
}

// Emit as part of a response:
await channel.send(
  .response(
    entryID: responseEntryID,
    action: .updateCustomSegment(WebSearchResults(id: UUID().uuidString, content: results))
  )
)
```

**The `id` is the add-vs-update switch.** A new id adds a segment; reusing an id updates the one you
have already started streaming (339:186–187, and the action's own name — `updateCustomSegment`, not
`addCustomSegment`). So a search-results segment that fills in as results arrive keeps one id, while
two independent searches in one turn get two.

When to reach for one:

> ✅ **VERIFIED** — `SKILL.md:448`: *"Reach for a custom segment when you have a structured payload the
> developer needs to read back later (citations, web-search results, retrieval hits, debug traces).
> **For free-form text, use `.response(action: .appendText(...))` or
> `.reasoning(action: .appendText(...))` instead.**"*

> ⚠️ **And know the cost: a custom segment is a compatibility boundary.** Apple's own
> `ChatCompletionsLanguageModel` throws `unsupportedTranscriptContent` on *any* `.custom` segment it
> encounters (`:450-456`, quoted in §8.3), with the message *"Custom segments are not supported by
> \(Self.self)"*. That is the correct behaviour and it generalises: **a transcript containing your
> custom segment cannot be handed to another provider.** A developer using dynamic profiles to route
> between your model and `SystemLanguageModel` will hit a hard error the moment the other model sees
> your segment. Document that, and consider whether metadata on a text segment would carry the same
> information at a fraction of the lock-in.

### 13.3 Attachment segments — non-text output, today

Custom segments are for *new* modalities. There is already a built-in one for images going *out*:

> ✅ **VERIFIED** — `SKILL.md:450-464`: *"When your model produces non-text output inline with its
> response — **currently images, with the enum designed to grow to other media types** — emit it as an
> attachment segment. The framework places the attachment in the developer's transcript alongside the
> response text so they can render or persist it. **This is the streaming-out counterpart to the
> `.vision` capability, which describes streaming-*in* image input.**"*
>
> ```swift
> public struct AttachmentSegment: Sendable, Identifiable, Equatable {
>   public var id: String
>   public var content: Attachment
>   public var label: String?
> }
>
> public enum Attachment: Sendable, Equatable {
>   case image(ImageAttachment)
> }
> ```

Emitting one (`SKILL.md:468-478`):

```swift prelude:guide-context
let attachment = Transcript.AttachmentSegment(
  id: imageID,                                              // stable id you mint
  content: .image(Transcript.ImageAttachment(cgImage)),     // CGImage / CIImage / CVPixelBuffer / URL
  label: "Generated diagram"                                // optional caption / alt text
)

await channel.send(
  .response(entryID: responseEntryID, action: .addAttachmentSegment(attachment))
)
```

`ImageAttachment` is buildable *"from a `CGImage`, `CIImage`, `CVPixelBuffer`, or a `URL`"*
(`SKILL.md:483`) — the same four sources the input side accepts.

> ✅ **VERIFIED** — `SKILL.md:494`: *"**There is no `replaceAttachmentSegment`** — to replace an
> attachment with a refined version, send a `removeAttachmentSegment` followed by a fresh
> `addAttachmentSegment` (with either the same `id` or a new one). **Each `addAttachmentSegment` ADDS
> a new segment; it does not replace an existing one of the same id.**"*

Which is the opposite convention from custom segments, where a reused id *does* update. Two adjacent
APIs, two opposite id semantics — this is worth a comment in your own code every time you use either.

### 13.4 Server-side tools and the three levels of disclosure

> ✅ **VERIFIED** — 339:190–195: *"**Server-side tools are capabilities your model runs on its own,
> like web search, code execution, or image generation. The model invokes them, the server runs them,
> and your executor watches the results stream in.** … **Server-side tools are named, typed values on
> your model. The developer constructs the model with the tools they want, and your executor receives
> them through the model on every request, the same way it receives every other capability the model
> declares.**"*

Note the architectural point, because it is easy to get backwards: **server-side tools live on your
model type, not in the session's `tools:` array.** That array is for Swift `Tool` conformances the
framework executes locally, and it arrives as `request.enabledToolDefinitions`. Your server-side
tools arrive as properties of the `model` argument to `respond`.

Then the design question — how much of the tool's work should the app be able to see? Apple's answer
is three levels, and choosing between them is a product decision, not a technical one.

**Level 1 — invisible grounding** (339:196–198):

> *"the simplest pattern: **run the tool privately and stream only the answer back. The tool grounds
> the model's response, but its work stays inside your executor.** Each text delta you append gets
> streamed into the transcript by the framework, **with no trace of the tool that produced it.**"*

Just `.appendText`. The developer sees a good answer and nothing else.

**Level 2 — text plus metadata, e.g. citations** (339:199–200):

> *"In addition to grounding the answer on the tool's output, you can also **attach additional
> metadata to the response**. **When a text delta carries metadata, like a citation, forward both to
> the channel, and the framework attaches the metadata to the text segment in the transcript.**"*

`.appendText` plus `.updateMetadata` — remembering §9.4, so build the citation dictionary
cumulatively.

**Level 3 — surface the tool's structured work** (339:201–203):

> *"you can choose to **surface the tool's work itself. With custom segments, you forward the tool's
> structured output to the channel, alongside the text and any metadata, giving apps everything the
> model produced along the way.** **Through one channel, the events you forward, the metadata you
> attach, and the custom segments you design, server-side tools shape what apps using your package
> can show their users.**"*

`.updateCustomSegment` with a type like `WebSearchResults` from §13.2 — which means **Level 3 has no
compiling mechanism on the beta 5 SDK** (§13.2's status note): the action and the protocol behind it
are not present in the beta 5 interface. This is what let an app render a source list, a
code-execution transcript, or a retrieval panel — and it is the reason custom segments existed at
all.

Level 3 costs the portability described in §13.2 — and, as of beta 5, is unavailable outright; the
nearest expressible design is Level 2 with richer metadata. Level 1 costs the app any ability to
show its work. Most packages should ship Level 2 by default and re-evaluate Level 3 if the
custom-segment surface returns in a later beta.

### 13.5 The disclosure recommendation, which applies to you as much as to your users

> ✅ **VERIFIED** — 339:204–205, the final substantive point of the session: *"There's one more thing
> to keep in mind: **whether you're choosing a package or shipping one, make sure everyone in the
> chain understands the privacy implications of the model behind it. On-device and cloud-based models
> have very different privacy characteristics, and your users deserve to know which they're
> getting.**"*

The practical form of this for a package author: **put it in the README, above the fold, in one
sentence.** "This package sends prompt text and images to `api.example.com`." A developer evaluating
five `LanguageModel` packages in an afternoon will not read your privacy policy, and their users
cannot read anything at all.


---

## 14. Testing a provider package

> ✅ **VERIFIED** — `SKILL.md:712-714`: *"Three layers, easiest to most thorough."* The layout in
> §2.1 exists to make layers 1 and 2 possible: if request building and event translation are inside
> `respond`, neither can be tested without a network.

**Layer 1 — request-builder unit tests.** *"Pure-function tests of `request → provider request body`.
No network, no async."* (`SKILL.md:716-718`.) Apple's example is also the only place in the corpus
that shows how to **construct** a `Transcript` by hand, which you will need constantly
(`SKILL.md:720-745`):

```swift prelude:external-module
import Testing
import FoundationModels
@testable import MyLanguageModel

@Test func `system instructions become a system message`() throws {
  let transcript = Transcript(entries: [
    .instructions(
      Transcript.Instructions(
        segments: [.text(Transcript.TextSegment(content: "Be concise."))],
        toolDefinitions: []
      )
    ),
    .prompt(
      Transcript.Prompt(
        segments: [.text(Transcript.TextSegment(content: "Hello"))]
      )
    ),
  ])

  let body = try buildProviderRequest(from: transcript, modelID: "test-model")

  #expect(body.messages[0].role == "system")
  #expect(body.messages[0].text == "Be concise.")
  #expect(body.messages[1].role == "user")
}
```

Note `Transcript(entries:)`, `Transcript.Instructions(segments:toolDefinitions:)` — `toolDefinitions`
is required — and `Transcript.Prompt(segments:)`. Note also the backtick-quoted test name; Apple uses
that style throughout the skill and in the real test files.

**Layer 2 — event-translator unit tests.** *"Pure-function tests of `provider event → channel
event(s)`. Stub the channel with a recording sink and assert the sequence of `send(...)` calls."*
(`SKILL.md:748-750`.) One detail here saves an hour of fighting the compiler:

> ✅ **VERIFIED** — `SKILL.md:764-767`: *"Inspect the recorded event by matching on **`kind.storage`**
> to recover the typed `Response` / `Reasoning` / `ToolCalls` payload, then assert on its `entryID`
> and `action` fields directly. **(Channel events are not `Equatable`, so a literal `==` against an
> event literal won't compile.)**"*

MLX solves the same problem a second way, worth knowing if `kind.storage` proves awkward: it puts a
`generationObserver` closure inside its emit helpers (`MLXLanguageModel.swift:702`, `:717`, `:727`)
and mirrors every channel event into a test-visible enum of its own. That also happens to be what
kept its usage tests passing when the real `updateUsage` send had to be removed (§9.7).

**Layer 3 — end-to-end through `LanguageModelSession`.** *"Stub your transport (`URLProtocol` for
URLSession-based clients, a fake gRPC stub for gRPC, etc.) and drive the executor through the real
`LanguageModelSession.respond(...)` API. This validates the full pipeline — request shape, event
translation, and how the framework assembles your events into the developer-visible response."*
(`SKILL.md:771-773`):

```swift prelude:guide-context
@Test func `streamed text deltas assemble into a complete response`() async throws {
  StubbedTransport.shared.respond(with: [.textDelta("Hello"), .textDelta(", world!"), .done])

  let model = MyLanguageModel(name: "test-model", apiKey: "sk-test", baseURL: .testBase)
  let session = LanguageModelSession(model: model)
  let response = try await session.respond(to: "anything")

  #expect(response.content == "Hello, world!")
}
```

Apple's own coverage checklist for this layer (`SKILL.md:793-800`): plain text; tool-call streaming
(*"open + multiple arg deltas → developer's `Response.toolCalls` contains one fully assembled
call"*); reasoning + text + tool call interleaved; cancellation mid-stream; each error type; and
image input round-trip if you support `.vision`.

**Add three tests Apple's list does not mention**, each targeting a silent failure from this guide:

1. **`prewarm` actually ran** (§3.5) — the ten-line counter test. Nothing else catches a near-miss
   witness.
2. **All six entry types survive translation** (§8.6) — build a transcript with one of each, assert
   the output message count, not just the content.
3. **Two models differing only in a behavioural field get different executors** (§3.2) — construct
   both, put both in one session, and assert the behaviour differs.

And a note on how Apple's real test target is wired, since you will want the same seams:
`ChatCompletionsLanguageModel` keeps an internal `var urlSession: URLSession?` with the comment
*"Overridden in tests to inject a URLSession with mock protocol handlers"* (`:56-57`), the tests
assign it directly (`ChatCompletionsTestUtilities.swift:33`), and a 227-line `MockSSE.swift` builds
`URLProtocol`-based SSE fixtures. Live tests against a real endpoint live in a **separate target**
(`FoundationModelsUtilitiesIntegrationTests`) and are environment-gated, so `swift test` stays
hermetic.

---

## 15. Quick reference

**The protocols** (`SKILL.md:41-59`)

```swift illustrative
public protocol LanguageModel: Sendable {
  associatedtype Executor: LanguageModelExecutor where Executor.Model == Self
  var capabilities: LanguageModelCapabilities { get }
  var executorConfiguration: Executor.Configuration { get }
}

public protocol LanguageModelExecutor: Sendable {
  associatedtype Configuration: Hashable & Sendable
  associatedtype Model: LanguageModel
  init(configuration: Configuration) throws
  func respond(to: LanguageModelExecutorGenerationRequest,
               model: Model,
               streamingInto: LanguageModelExecutorGenerationChannel) async throws
  func prewarm(model: Model, transcript: Transcript)   // ⚠️ default no-op — match EXACTLY
}
```

| Thing | Value |
|---|---|
| Version floor | iOS/iPadOS/macOS/visionOS/watchOS **27.0**. No tvOS. |
| SDK gate | `#if canImport(FoundationModels, _version: 2)` |
| SwiftPM dependency for FoundationModels | **none** — system framework |
| Capabilities | `.toolCalling` · `.vision` · `.reasoning` · `.guidedGeneration` |
| Capability inits | `LanguageModelCapabilities([…])` (beta 3) · `(capabilities: […])` (both work) |
| Request fields | `id` · `transcript` · `enabledToolDefinitions` · `schema` · `generationOptions` · `contextOptions` · `metadata` |
| `GenerationOptions` | `temperature` · `samplingMode` · `maximumResponseTokens` · `toolCallingMode` |
| `ContextOptions` | `includeSchemaInPrompt` · `reasoningLevel` (`.light`/`.moderate`/`.deep`/`.custom(String)`) |
| `SamplingMode.kind` | `.greedy` · `.randomTopK(k, seed)` · `.randomProbabilityThreshold(p, seed)` (renamed in beta 3) |
| `ToolCallingMode.kind` | `.allowed` · `.disallowed` · `.required`; `nil` ⇒ allowed |
| Transcript entries | `.instructions` · `.prompt` · `.toolCalls` · `.toolOutput` · `.response` · `.reasoning` |
| Transcript segments | `.text` · `.structure` · `.attachment` (`.custom` — not present in the beta 5 interface; §13.2) |
| Channel events | `.response(entryID:action:)` · `.reasoning(entryID:action:)` · `.toolCalls(entryID:action:)` |
| Response actions | `appendText` · `replaceTextSegment` · `addAttachmentSegment` · `removeAttachmentSegment` · `updateMetadata` · `updateUsage` (`updateCustomSegment` — not present in the beta 5 interface; §13.2) |
| Reasoning actions | `appendText` · `replaceTextSegment` · `updateSignature` · `updateMetadata` · `updateUsage` |
| ToolCalls actions | outer: `toolCall(id:name:action:)` · `removeToolCall(_:)` · `updateMetadata` · `updateUsage`; inner: `appendArguments` · `updateMetadata` |
| `entryID` | required on `.response`/`.toolCalls` (distinct!), **optional on `.reasoning`** |
| Errors | 9 `LanguageModelError` cases, non-frozen — see §11.2 |

**The seven rules that prevent the seven silent failures**

1. Match `prewarm(model:transcript:)` **exactly**, and test that it ran. (§3.5)
2. Put every behaviour-affecting field in `Configuration`'s `==` and `hash`. (§3.2)
3. Never declare a capability you do not *strictly* implement. (§5.3)
4. Mint three `entryID`s per turn and reuse each within its entry. (§9.3)
5. Re-emit the whole metadata dictionary on every `updateMetadata`. (§9.4)
6. Log or throw on every transcript entry you drop; never `default: continue` silently. (§8.6)
7. Attach usage and metadata to the entry kind the turn actually produced. (§10.3)

---

## 16. Sources and evidence ledger

**Primary — Apple source read directly this session (strongest class):**

- `apple/foundation-models-utilities` @ `376ca60` (tag `1.0.0-beta3`, 2026-07-10):
  - `skills/foundation-models-language-model-protocol/SKILL.md` — 815 lines, read in full. The
    single most valuable artefact in the corpus for this topic.
  - `Sources/FoundationModelsUtilities/LanguageModels/ChatCompletionsLanguageModel.swift` — 953
    lines; all quoted line numbers verified against the file.
  - `Tests/FoundationModelsUtilitiesTests/MockModel.swift` — the 40-line conformance in §4.
  - `Package.swift`.
- `ml-explore/mlx-swift-lm`:
  - `Libraries/MLXFoundationModels/MLXLanguageModel.swift` — capabilities doc comment (`:505-520`),
    `Configuration` (`:876-880`), `prewarm` (`:890-930`), `respond` (`:938-1015`), emit helpers
    (`:700-774`), `thinkingEnabled` (`:1903-1916`).
  - `Libraries/MLXFoundationModels/TranscriptConverter.swift` — the second worked translator.
  - `Package.swift` traits block.

**Secondary — research notes in this corpus:**

- `notes/repos/foundation-models-utilities.md` — the full deep-dive, including the beta-1 → beta-3
  API delta, the `buildURLRequest` bug reproduction, and the catalogue of doc/source divergences.
- `notes/transcripts/fm-ecosystem.md` — WWDC26 session 339 in full (213 lines, Christopher Webb),
  plus 319 and 246. All 339 line citations in this guide come from there.
- `notes/repos/mlx-swift-lm.md` — packaging, traits, SDK gating, CI.
- `notes/repos/apple-coreai-models.md` — the third conformance (`CoreAIExecutor`).
- `notes/repos/john-rocky-models.md` — the community `ZooFMProvider` conformance, the nine traps,
  and every community-measured number quoted here (verified 2026-06-11, macOS 27 beta, M4 Max).

**Where sources disagreed, and how this guide ruled:**

| Conflict | Ruling |
|---|---|
| `where Executor.Model == Self` (skill) vs `where Self == Executor.Model` (swiftinterface read) | Same constraint. Not a disagreement. §3 |
| `nonisolated(nonsending) func respond` present in two conformances, absent in two | Both witness the requirement. Use the plain form. §3 |
| `.greedy` → `temperature = 0` (`SKILL.md:295`) vs `top_p = 0` (`ChatCompletionsLanguageModel.swift:370`) | Code wins as evidence of one choice; map to *your* engine's deterministic path. §6.1 |
| Event order: metadata → usage → text (339:121-130) vs usage-at-end (Apple's Core AI adapter, Apple's mock, community measurement) | Follow the *intent*; do not send `.response` events on a turn that may produce only tool calls. §10 |
| `Task.checkCancellation()` prescribed (`SKILL.md:642`) but absent from `ChatCompletionsLanguageModel` | Follow the skill. §9.6 |
| Skill says map 429 → `.rateLimited` (`:550`); Apple's executor throws `RequestError.httpError` | Follow the skill. §11.3 |
| Reasoning replay: ChatCompletions replays, MLX and Core AI drop | All correct — it is a provider property. `SKILL.md:522` is the ruling text. §8.5 |
| `skills/foundation-models-utilities/SKILL.md` claims three SwiftPM traits gate the package | **False** — no traits, no `#if`. That skill is a beta-1 document, stale in eight verifiable places. §2.3 |

**Declared gaps (nothing guessed inside them):**

- `GenerationSchema.name` for an anonymous/inline schema — §6.2
- `ContextOptions.includeSchemaInPrompt`'s declaration and any real call site — §7.2
- Whether `@Generable` / guided generation works on Linux — §2.2
- Whether the `updateUsage` dylib symbol mismatch persists past Xcode 27 beta 3 — §9.7
- Whether the empty-`Response`-entry behaviour still reproduces — §10.3
- App Attest integration for provider packages — no code anywhere in the corpus — §12.2

**Not used as evidence:** the coffee/generative-game and SpeechAnalyzer sample projects (stale
iOS 26 / WWDC25 leftovers); `skills/foundation-models-utilities/SKILL.md` except where explicitly
flagged as stale.

[^refusal-response]: Apple, [`LanguageModelError.Refusal.explanation`](https://developer.apple.com/documentation/foundationmodels/languagemodelerror/refusal/explanation) (`get async throws`) and [`LanguageModelSession.Response.content`](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/response/content), the generated `String` carried by the response.
