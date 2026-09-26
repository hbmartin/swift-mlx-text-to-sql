# Core AI, MLX, and any OpenAI-compatible server behind `LanguageModelSession`

**Part 4 · Beyond the built-in model · Reference 02**

**Version floor.** The `LanguageModel` / `LanguageModelExecutor` protocol pair and the
`LanguageModelSession(model:)` initializer that consumes them are **iOS 27.0 / iPadOS 27.0 /
macOS 27.0 / visionOS 27.0**. Nothing in this guide works on 26.x. The three concrete backends have
*narrower* floors than that, and they are not the same as each other:

| Backend | Ships in | Declared platform floor |
|---|---|---|
| `ChatCompletionsLanguageModel` | SwiftPM package `apple/foundation-models-utilities` | `.macOS("27.0") .iOS("27.0") .visionOS("27.0") .watchOS("27.0")` — **no tvOS** ✅ `Package.swift:19-22` |
| `MLXLanguageModel` | library target inside `ml-explore/mlx-swift-lm` | `@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)` — **no watchOS, no tvOS** — *and* it requires the **27.0 SDK** to exist at all ✅ |
| `CoreAILanguageModel` | SwiftPM package `apple/coreai-models` | `platforms: [.macOS("27.0"), .iOS("27.0")]` — **iOS and macOS only** ✅ `Package.swift` |

`@Generable` and `@Guide` themselves are **iOS 26.0 / macOS 26.0** — older than everything above,
which is why `mlx-swift-lm`'s own README annotates the `@Generable` type `@available(iOS 26.0,
macOS 26.0, visionOS 26.0, *)` and the session block `if #available(iOS 27.0, macOS 27.0,
visionOS 27.0, *)`. Two different floors in one file is the normal shape of this code.

---

## What this covers

You have decided not to use `SystemLanguageModel`. This guide is the **consumer** side of that
decision: how to put a different model behind the same `LanguageModelSession` API, with real
initializers, real failure modes, and the one architectural trade that should change which backend
you pick.

- **Path 1 — `ChatCompletionsLanguageModel`.** The one that works today, on hardware you already
  own, without the 27 SDK's model packages. Point it at `mlx_lm.server`, Ollama, LM Studio or vLLM
  and any Hugging Face checkpoint is behind `LanguageModelSession`. Including the confirmed,
  as-of-today unfixed URL-versioning defect, its verified workaround, and the malformed URL in
  Apple's own README.
- **Path 2 — `MLXLanguageModel`.** Where `MLXFoundationModels` actually lives (this is the direct
  answer to Developer Forums thread **836264**), the double gate that makes it vanish silently, the
  `#huggingFaceLanguageModel` macro, the explicit initializer, and why the `capabilities:` array you
  pass is load-bearing rather than decorative.
- **Path 3 — `CoreAILanguageModel`.** One line to load a converted bundle, what it detects about
  your model without asking you, and what the Foundation Models path does *not* expose.
- **The constraint that deserves its own section:** grammar-constrained decoding — the mechanism
  behind `@Generable` — needs engine **logits**. The fastest local backend never surfaces them. A
  bring-your-own-model app therefore **loses Apple's flagship structured-generation feature exactly
  when it selects the fastest backend.** This should change your backend choice, not merely inform
  it.
- **Capability declaration** as the actual contract between you and the framework, and the errors
  the framework throws on your behalf when a backend under-declares.
- **The privacy obligation** from session 339, which applies to you as a *consumer* of a model
  package, not only to the people who ship them.

Authoring a `LanguageModel` conformance of your own is **guide 03** in this part. This guide stops
at the boundary: you are choosing and configuring somebody else's.

## What you need

- **Xcode 27** for anything here. `MLXLanguageModel` specifically needs the 27.0 SDK — see §3.2,
  because building against the 26 SDK does not produce an error, it produces an *empty library*.
- A **device or a Mac**, not the Simulator, for anything you intend to trust.
- Read [Part 1 §3 and §5](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/references/01-apple-ai-stack-2026-map.md)
  first if you have not chosen a backend yet. That guide's decision table is the "which"; this one is
  the "how".
- Read [`02-guided-generation-and-streaming.md`](../../part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md)
  and [`03-tools-and-tool-calling.md`](../../part-02-foundation-models-everyday-api/references/03-tools-and-tool-calling.md)
  — this guide assumes you know what `@Generable`, `Tool`, and a `Transcript` are, and spends its
  time on what happens to them when the model underneath changes.

---

## Contents

1. [What "behind the session" actually means](#1-what-behind-the-session-actually-means)
2. [Path 1 — any OpenAI-compatible server, today](#2-path-1--any-openai-compatible-server-today)
   - [2.1 Adding the package (and the dependency line that resolves to nothing)](#21-adding-the-package-and-the-dependency-line-that-resolves-to-nothing)
   - [2.2 The type, verbatim](#22-the-type-verbatim)
   - [2.3 Pointing it at a local server](#23-pointing-it-at-a-local-server)
   - [2.4 ⚠️ The URL-versioning defect, and the workaround that works](#24-️-the-url-versioning-defect-and-the-workaround-that-works)
   - [2.5 `supportsGuidedGeneration:` is a promise you are making for the server](#25-supportsguidedgeneration-is-a-promise-you-are-making-for-the-server)
   - [2.6 What crosses the wire, and what is quietly dropped](#26-what-crosses-the-wire-and-what-is-quietly-dropped)
   - [2.7 The errors you will actually see](#27-the-errors-you-will-actually-see)
   - [2.8 Transport, timeouts, and the executor-cache wrinkle](#28-transport-timeouts-and-the-executor-cache-wrinkle)
   - [2.9 Linux, and the streaming you do not get there](#29-linux-and-the-streaming-you-do-not-get-there)
3. [Path 2 — `MLXLanguageModel`, and where `MLXFoundationModels` actually is](#3-path-2--mlxlanguagemodel-and-where-mlxfoundationmodels-actually-is)
   - [3.1 The answer to thread 836264](#31-the-answer-to-thread-836264)
   - [3.2 ⚠️ The double gate, and the empty library](#32-️-the-double-gate-and-the-empty-library)
   - [3.3 A consumer `Package.swift` that works](#33-a-consumer-packageswift-that-works)
   - [3.4 The macro path: `#huggingFaceLanguageModel`](#34-the-macro-path-huggingfacelanguagemodel)
   - [3.5 The explicit path: the real initializer](#35-the-explicit-path-the-real-initializer)
   - [3.6 `capabilities:` is routing, not documentation](#36-capabilities-is-routing-not-documentation)
   - [3.7 `LLMRegistry`, and picking a model id](#37-llmregistry-and-picking-a-model-id)
   - [3.8 Weights caching, eviction, and warm-up](#38-weights-caching-eviction-and-warm-up)
   - [3.9 The MLX-specific traps](#39-the-mlx-specific-traps)
4. [Path 3 — `CoreAILanguageModel`, one line to a bundle](#4-path-3--coreailanguagemodel-one-line-to-a-bundle)
   - [4.1 The one line](#41-the-one-line)
   - [4.2 The initializer in full](#42-the-initializer-in-full)
   - [4.3 Capabilities are detected, not declared](#43-capabilities-are-detected-not-declared)
   - [4.4 What the Foundation Models path does not expose](#44-what-the-foundation-models-path-does-not-expose)
   - [4.5 Where the bundle comes from](#45-where-the-bundle-comes-from)
5. [⚠️ The logits constraint: why the fastest backend loses `@Generable`](#5-️-the-logits-constraint-why-the-fastest-backend-loses-generable)
6. [Capabilities, and the errors the framework throws for you](#6-capabilities-and-the-errors-the-framework-throws-for-you)
7. [The privacy obligation](#7-the-privacy-obligation)
8. [Choosing, concretely](#8-choosing-concretely)
9. [Making the backend swappable in real app code](#9-making-the-backend-swappable-in-real-app-code)
10. [Quick reference](#10-quick-reference)
11. [Sources, and where they disagree](#11-sources-and-where-they-disagree)

---

## 1. What "behind the session" actually means

The pitch is one line. Apple's own session 339 narrates it as four consecutive swaps of a single
construction statement, and the punchline from session 241 is blunter: *"Everything downstream stays
the same."*

> 🟡 **RECONSTRUCTED** — the four-swap sequence below is spoken narration from WWDC26 session 339
> (339:15–23), transcribed. Each individual line is corroborated by a different local source, cited
> where it appears in this guide. The *shape* is right; treat it as the outline, not as the
> signatures.

```swift illustrative
// 1. On-device Apple model                                   (339:16-17)
let model = SystemLanguageModel()

// 2. "If you need more horsepower, try Private Cloud Compute. Just swap the model."  (339:19-20)
let model = PrivateCloudComputeLanguageModel()

// 3. "If you want to ship your own model, just point CoreAI at your resources."      (339:21)
let model = try await CoreAILanguageModel(resourcesAt: bundleURL)

// 4. "if you want to try the latest open source models, simply pass in a model ID,
//     and let the framework handle the rest."                                        (339:22)
let model = MLXLanguageModel(configuration: ModelConfiguration(id: "mlx-community/…"))

// …and in every case:
let session = LanguageModelSession(model: model)
let response = try await session.respond(to: "…")
```

Two of those four lines are, as written, not the shipping API. `CoreAILanguageModel(resourcesAt:)`
is real and verified (§4). `MLXLanguageModel(configuration:)` alone is **not** — the real
initializer takes four more parameters, and "simply pass in a model ID" is only true because two
macros fill the rest in for you (§3.5). That gap between the demo line and the shipping signature is
the single most common source of confusion in this area, so this guide always shows the shipping one.

### What actually holds constant

The genuinely stable part is the session. `session.respond(to:)`, `session.streamResponse(to:)`,
`session.transcript`, `Tool` conformances, `Instructions`, `Prompt` — all unchanged. Session 326 is
explicit that this is the point:

> ✅ **VERIFIED (WWDC26 session 326, 326:103-118 verbatim)** — *"To use it, I create a
> `LanguageModelSession`. This is the **same API that gives you access to Apple's on-device large
> language model**. The difference is that now you'll pass in your own model to use. **Same
> `session.respond(to:)` call, same streaming support, same structured output capabilities.**"*

And the session initializer really does take tools and instructions alongside a custom model — this
is not reconstructed, it is in MLX's own doc comment:

> ✅ **VERIFIED (repo source)** — `ml-explore/mlx-swift-lm`,
> `Libraries/MLXFoundationModels/MLXLanguageModel.swift:304-337`:
>
> ```swift
> let session = LanguageModelSession(model: model, tools: [], instructions: nil)
> let response = try await session.respond(to: "Hello!")
> print(response.content)
> ```

### What does not hold constant

Three things change under you when you change the model, and all three are the subject of this guide.

**Capabilities.** A backend declares what it can do. If you ask for something it did not declare,
the framework rejects the request *before* the executor runs.

> ✅ **VERIFIED (Apple's own written guidance)** — from the agent skill Apple ships inside
> `foundation-models-utilities`, `skills/foundation-models-language-model-protocol/SKILL.md:35`:
>
> > *"If a developer asks for a capability you didn't declare (e.g. tool calling on a model that
> > doesn't support it), the framework throws `unsupportedCapability` for you — you don't write
> > defensive code for that."*
>
> The four capabilities are `.toolCalling`, `.vision`, `.reasoning`, `.guidedGeneration`
> (`SKILL.md:314-319`), with `.guidedGeneration` defined as *"Model **strictly** conforms output to a
> JSON Schema"* and the caution *"include only if your model **strictly enforces** JSON Schema"*
> (`SKILL.md:110`).

So `@Generable` against a backend without `.guidedGeneration` is a **throw**, not a silent
degradation. That is the good case. §5 is about the case where you get the throw and there is
nothing you can do about it except change engines.

**Sampling and options coverage.** `GenerationOptions` is a uniform type with a non-uniform
implementation. `ChatCompletionsLanguageModel` *throws* on top-K sampling and on a random seed
(§2.6). `CoreAILanguageModel` honours only `temperature` and cannot reach top-K/top-P/min-P at all
through this path (§4.4). Nothing warns you at the call site; the difference surfaces at runtime.

**Error vocabulary.** The framework ships `LanguageModelError` with nine cases, and session 339's
advice to providers is *"Try to use a built-in `LanguageModelError` when it fits"* (339:151–156).
Providers vary widely in how well they follow it — `ChatCompletionsLanguageModel` maps a 429 to a
generic HTTP error rather than `.rateLimited` (§2.7). Your `catch` ladder is backend-specific in
practice even though it looks portable.

> ⚠️ **SILENT FAILURE — the executor cache is keyed on a `Configuration`, not on your model value.**
> The framework caches one executor per unique `Executor.Configuration`, and `Configuration` is
> `Hashable`. Session 339 narrates this as an animated diagram (339:59–66): *"**The configuration is
> the lookup key, not the model.** … Each unique configuration maps to exactly one executor in the
> store."* Two backends in this guide implement that `Hashable` conformance in ways that **exclude
> settings you probably think are part of the model's identity** — `ChatCompletionsLanguageModel`
> excludes the `URLSession` (§2.8), and `MLXLanguageModel`'s `Configuration` is
> `{ public let modelID: String }` and nothing else (§3.9). Construct two models that differ only in
> an excluded field and the second one silently gets the first one's executor. Nothing throws.

---

## 2. Path 1 — any OpenAI-compatible server, today

This is the most immediately useful thing in this guide, and it is the least advertised. It is not
in session 339's headline list of backends, because it does not ship in the OS — it ships in a
package Apple updates *between* OS releases.

> ✅ **VERIFIED (WWDC26 session 241, `[241:L5]` verbatim)** — *"In addition to the core framework,
> we're also releasing a new package, **Foundation Models framework utilities**, that will be
> **updated between OS releases** to give you access to **emerging and experimental building
> blocks**."* Its stated contents `[241:L128-132]`: *"profile modifiers for transcript management, a
> skill API for procedural knowledge loading, and **a language model that can interface with servers
> using the Chat Completions standard**."*

That last item is `ChatCompletionsLanguageModel`. And because `mlx_lm.server`, **Ollama**,
**LM Studio** and **vLLM** all speak the OpenAI chat-completions protocol, the practical consequence
is larger than "Apple shipped an OpenAI client":

> **A local chat-completions server plus `ChatCompletionsLanguageModel` is any Hugging Face model
> behind `LanguageModelSession`, today, on hardware you already have — without the 27 SDK's model
> packages and without a conversion step.**

It is the fastest path in the entire stack from "I want to try model X inside my app's real prompt
flow, with my real tools and my real `@Generable` types" to running code. It is also the honest
answer for a team that needs a specific frontier model and already pays an inference bill.

### 2.1 Adding the package (and the dependency line that resolves to nothing)

> ⚠️ **The README's own dependency line currently resolves to nothing.** `README.md:30` tells you to
> write `.package(url: "https://github.com/apple/foundation-models-utilities", from: "1.0.0")`. The
> only tags that exist are **`1.0.0-beta1`** and **`1.0.0-beta3`** (`git ls-remote --tags`, checked
> against commit `376ca60`, tag `1.0.0-beta3`, 2026-07-10). SwiftPM's `from:` **excludes
> prereleases**, so that line has nothing to resolve to.

Pin explicitly until a stable tag ships:

```swift prelude:external-module
// Package.swift
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MyApp",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    dependencies: [
        .package(
            url: "https://github.com/apple/foundation-models-utilities",
            exact: "1.0.0-beta3"          // `from: "1.0.0"` resolves to nothing — see above
        )
    ],
    targets: [
        .target(
            name: "MyApp",
            dependencies: [
                .product(name: "FoundationModelsUtilities", package: "foundation-models-utilities")
            ]
        )
    ]
)
```

> ✅ **VERIFIED (repo source)** — the package declares `swift-tools-version: 6.2`,
> `swiftLanguageModes: [.v6]`, `platforms: [.macOS("27.0"), .iOS("27.0"), .visionOS("27.0"),
> .watchOS("27.0")]`, exactly one product `FoundationModelsUtilities`, and **zero external
> dependencies** (`Package.swift:13-63`). `FoundationModels` is a system framework, so there is no
> SwiftPM declaration for it — just `import FoundationModels`.

Two organisational facts worth knowing before you depend on it: **GitHub issues are disabled** on
the repository (`README.md:12` routes bug reports to the Apple Developer Forums), and
`CONTRIBUTING.md` states *"This project is not currently accepting PRs."* If you find a defect, the
forum is the channel — which is exactly how the defect in §2.4 was reported and acknowledged.

### 2.2 The type, verbatim

> ✅ **VERIFIED (repo source)** —
> `Sources/FoundationModelsUtilities/LanguageModels/ChatCompletionsLanguageModel.swift:39-84`:
>
> ```swift
> public struct ChatCompletionsLanguageModel: Sendable, LanguageModel {
>   public var name: String                                 // :42
>   public var url: URL                                     // :47
>   public var additionalHeaders: [String: String]          // :52
>   public var supportsGuidedGeneration: Bool               // :54
>
>   public init(
>     name: String,
>     url: URL,
>     additionalHeaders: [String: String] = [:],
>     supportsGuidedGeneration: Bool = true,
>     urlSessionConfiguration: URLSessionConfiguration? = nil     // :78 — added in beta 3
>   )
> }
> ```
>
> And the capability declaration (`:88-93`):
>
> ```swift
> public var capabilities: LanguageModelCapabilities {
>   if supportsGuidedGeneration {
>     LanguageModelCapabilities([.vision, .toolCalling, .reasoning, .guidedGeneration])
>   } else {
>     LanguageModelCapabilities([.vision, .toolCalling, .reasoning])
>   }
> }
> ```

Read that capability block carefully, because it is a design decision you inherit. `.vision`,
`.toolCalling` and `.reasoning` are declared **unconditionally** — this model claims all three of
them for *every* endpoint you point it at, whether or not the model behind that endpoint has ever
seen an image. Only `.guidedGeneration` is under your control. §2.5 and §6 are about what that costs
you.

The `name:` parameter is the **wire** model name, not a display name: it is sent as the
`"model"` field of the request body (`:239`). For `mlx_lm.server` and vLLM that is the model path or
id the server was started with; for Ollama it is the tag (`llama3.2:3b`).

> 🟡 **RECONSTRUCTED — the beta-1 initializer had no `urlSessionConfiguration:`.** The parameter was
> added in commit `376ca60` ("Updates to accompany Xcode 27 beta 3"), whose own message documents it:
> *"Added `urlSessionConfiguration` parameter to `ChatCompletionsLanguageModel.init` — allows tuning
> timeouts, proxies, and other transport settings; defaults to an ephemeral configuration."* If you
> are reading code written against beta 1, the four-parameter form is why.

### 2.3 Pointing it at a local server

The minimal, complete program:

```swift prelude:external-module
import Foundation
import FoundationModels
import FoundationModelsUtilities

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
func askLocalModel() async throws -> String {
    let model = ChatCompletionsLanguageModel(
        name: "mlx-community/Qwen3-4B-4bit",              // the server's model id, sent as "model"
        url: URL(string: "http://127.0.0.1:8080/v1")!,    // include /v1 — see §2.4
        supportsGuidedGeneration: false                   // most local servers do not enforce it
    )

    let session = LanguageModelSession(model: model)
    let response = try await session.respond(to: "Summarise the Swift concurrency model in 3 bullets.")
    return response.content
}
```

Base URLs for the four servers people actually use. **Every row here is safe** — each ends in a path
component that is literally `v1`, which is what §2.4 requires:

| Server | Base URL to pass as `url:` | Notes |
|---|---|---|
| `mlx_lm.server` | `http://127.0.0.1:8080/v1` | port is whatever you passed to `--port` |
| Ollama | `http://127.0.0.1:11434/v1` | ✅ empirically confirmed safe (§2.4 table) |
| LM Studio | `http://127.0.0.1:1234/v1` | |
| vLLM | `http://127.0.0.1:8000/v1` | |
| OpenAI proper | `https://api.openai.com/v1` | ✅ empirically confirmed safe |
| *no path at all* | `http://localhost:8000` | ✅ also safe — the fallback injects `/v1` for you |

> ⚠️ **The README's first code sample is malformed, and it will not do what it looks like.**
> `README.md:52` and `README.md:67` both write `URL(string: "http://localhost/v1:8000")!` — **the
> port is inside the path.** Its `pathComponents` are `["/", "v1:8000"]`, so `host` is `localhost` on
> the default port **80**, and the request goes to `http://localhost/v1:8000/v1/chat/completions`.
> The intended URL is `http://localhost:8000/v1`. This is not a subtle typo in an appendix; it is in
> the README's very first sample, and copying it produces a connection failure that looks like your
> server is down.

### 2.4 ⚠️ The URL-versioning defect, and the workaround that works

This is the single most important operational fact about this backend, it is confirmed by Apple, and
as of **2026-07-27** it is **not fixed**.

> ✅ **VERIFIED (repo source, quoted in full)** —
> `Sources/FoundationModelsUtilities/LanguageModels/ChatCompletionsLanguageModel.swift:634-648`:
>
> ```swift
> private func buildURLRequest(for request: ChatCompletionRequest) throws -> URLRequest {
>     let isVersioned = baseURL.pathComponents.contains("v1")                    // :635
>     let endpoint = isVersioned ? "/chat/completions" : "/v1/chat/completions"  // :636
>     let url = baseURL.appendingPathComponent(endpoint)                         // :637
>     var urlRequest = URLRequest(url: url)
>     urlRequest.httpMethod = "POST"
>     for (header, value) in headers {
>         urlRequest.setValue(value, forHTTPHeaderField: header)
>     }
>
>     let encoder = JSONEncoder()
>     urlRequest.httpBody = try encoder.encode(request)
>
>     return urlRequest
> }
> ```

The logic recognises exactly one version segment — the literal string `"v1"` — and its fallback is
**unconditional path injection**, not "append nothing". So any server whose base path already
terminates at its API root, but which is versioned as `v1beta`, `v2`, `v3`, or not versioned by path
at all, receives a spurious `/v1`.

> ✅ **VERIFIED — reproduced by executing the two decisive lines** against Swift 6.3.3 Foundation on
> macOS, over eleven base-URL shapes. The table:
>
> | Base URL | `pathComponents` | Resulting endpoint | |
> |---|---|---|---|
> | `https://api.openai.com/v1` | `["/", "v1"]` | `…/v1/chat/completions` | ✅ |
> | `http://localhost:8000` | `[]` | `…:8000/v1/chat/completions` | ✅ |
> | `http://127.0.0.1:11434/v1` (Ollama) | `["/", "v1"]` | `…:11434/v1/chat/completions` | ✅ |
> | `https://api.example.com/` | `["/"]` | `…/v1/chat/completions` | ✅ |
> | `https://generativelanguage.googleapis.com/v1beta/openai` | `["/", "v1beta", "openai"]` | `…/v1beta/openai/`**`v1`**`/chat/completions` | ❌ |
> | `https://api.example.com/v2` | `["/", "v2"]` | `…/v2/`**`v1`**`/chat/completions` | ❌ |
> | `https://api.example.com/v3` | `["/", "v3"]` | `…/v3/`**`v1`**`/chat/completions` | ❌ |
> | `https://x.openai.azure.com/openai/deployments/gpt4` | `["/","openai","deployments","gpt4"]` | `…/gpt4/`**`v1`**`/chat/completions` | ❌ |

So: **Gemini's OpenAI-compatibility endpoint, any `/v2` or `/v3` API, and every Azure OpenAI
deployment path** are broken by construction.

**Apple has confirmed it.** Developer Forums thread **838444** ("Issue: Inflexible API Versioning
Logic in Foundation Models framework utilities", 2026-07-18) reports it against a Volcengine Ark
endpoint on `/api/v3`, with the resulting error verbatim:

```
HTTP error with status code 404:
{"error":{"code":"InvalidAction","message":"The specified action is invalid:
 /api/v3/responses/v1/chat/completions Request id: 0217843811688…","param":"","type":"NotFound"}}
```

> ✅ **VERIFIED (Apple Developer Forums thread 838444, Apple staff reply, accepted)** — the reporter
> proposed
>
> ```swift
> let isVersioned = baseURL.pathComponents.contains { component in
>     component.wholeMatch(of: #/v\d+/#) != nil
> }
> ```
>
> and Apple's reply was *"Fantastic suggestion, thanks! We're on it."* Filed as **FB23837262**.

**But it is not in the shipping code.** `git log -p --all -S "pathComponents.contains" -- Sources/`
returns exactly one hit — the introducing commit `a047a50`. The line is **byte-identical in
`1.0.0-beta1` and `1.0.0-beta3`**, and `git show 376ca60` (the beta-3 commit, which post-dates
nothing relevant here) shows no change to `buildURLRequest`. Apple's acknowledgement is dated
2026-07-18; the newest tag is 2026-07-10. Treat the fix as **announced but unshipped**.

**There is no escape hatch.** `buildURLRequest` is `private`, and no initializer parameter overrides
the path. You cannot subclass a `struct`, and the method is not a protocol requirement.

#### The workaround, and its exact boundary

> ✅ **VERIFIED (same execution run)** — **because the check is `contains`, not a suffix match, any
> base URL with a literal `v1` component anywhere in its path passes.** So:
>
> ```
> https://api.example.com/api/v1  →  https://api.example.com/api/v1/chat/completions   ✅
> ```
>
> If your server exposes its chat-completions endpoint under a path that happens to include a `v1`
> segment, you are fine. If you control the reverse proxy, mounting the upstream at a path
> containing `/v1` is a one-line nginx `location` block and costs you nothing.

For a genuine `/v2` or `/v3` server there is **no workaround within the package**. Your options, in
order of how much you will regret them:

1. **A local reverse proxy** that maps `…/v1/chat/completions` onto the real path. Ugly, reliable,
   and testable.
2. **Vendor the file.** It is Apache 2.0, 953 lines, and zero-dependency. Copy
   `ChatCompletionsLanguageModel.swift` into your target, fix line 635, and accept that you now own
   it. This is a real option for a server-side Swift deployment; it is a poor one for an app you
   intend to keep in sync with the package.
3. **Wait.** Apple said "we're on it" on 2026-07-18. Re-check `git ls-remote --tags` before you build
   anything around 1 or 2.

> 🔴 **GAP — whether this is fixed in a tag published after 2026-07-27.** Our newest evidence is
> commit `376ca60` / tag `1.0.0-beta3` (2026-07-10) plus the forum acknowledgement (2026-07-18). If a
> `1.0.0-beta4` or `1.0.0` exists by the time you read this, **check line 635 yourself** — the exact
> query that settles it is `git log -p -S "pathComponents.contains" -- Sources/`. Until then, the
> safe default is: **put a literal `v1` component in your base URL, or run a proxy.**

#### Why the tests do not catch it

Worth knowing, because it tells you how much to trust the package's coverage in general:

> ✅ **VERIFIED** — the only endpoint assertion in the suite is
> `#expect(request.url?.path.hasSuffix("/chat/completions") == true)`
> (`Tests/…/LanguageModelTests/ChatCompletionsTests+RequestFormat.swift:83`), which passes for
> **every one of the ❌ rows above**.

### 2.5 `supportsGuidedGeneration:` is a promise you are making for the server

The default is `true`. That default is wrong for most local servers, and getting it wrong is not a
compile error.

Here is the mechanism. When you use `@Generable`, the framework hands the executor a
`GenerationSchema` on `request.schema`, and this executor forwards it as an OpenAI `response_format`:

> ✅ **VERIFIED (repo source)** — `ChatCompletionsLanguageModel.swift:263-270`:
>
> ```swift
> responseFormat: request.schema.map { schema in
>   ChatCompletionsClient.ResponseFormat(
>     jsonSchema: ChatCompletionsClient.ResponseFormat.JSONSchemaWrapper(
>       name: schema.name,        // :266 — beta 3; beta 1 used a JSON-decoding `title` hack
>       schema: schema
>     )
>   )
> }
> ```
>
> The wire type sets `type = "json_schema"` and **`strict = true`** (`:818`, `:831`).
> `GenerationSchema` itself *"conforms to `Codable` and encodes to standard JSON Schema"*
> (`skills/foundation-models-language-model-protocol/SKILL.md`, new section at beta 3).

So the executor does not enforce anything. It **asks the server to**. Declaring
`supportsGuidedGeneration: true` is a claim that the endpoint behind your URL *strictly* enforces
JSON Schema — which is exactly what Apple's own capability definition demands: *"include only if
your model **strictly enforces** JSON Schema"* (`SKILL.md:110`).

> ⚠️ **SILENT FAILURE — over-declaring guided generation does not throw; it produces malformed
> output at the parse boundary, or worse, well-formed output with hallucinated fields.** If you leave
> the default `true` and the server ignores `response_format` (or supports it in a best-effort, non-
> `strict` mode, which several local servers do), the framework has no way to know. It declared
> `.guidedGeneration`, so it forwards the schema and expects conformance. What you get back is free
> text that happens to look like JSON, and your failure surfaces as a
> `GeneratedContent.ParsingError` — or does not surface at all, when the model emits a
> *syntactically valid* object with a plausible-but-invented value in a field the schema said was
> required.
>
> **Safe default: pass `supportsGuidedGeneration: false` for any endpoint you have not personally
> tested with a strict schema.** Under-declaring is loud and cheap — the framework throws
> `unsupportedCapability` at you before the request leaves the process (§6), you notice in the first
> five minutes, and you flip the flag. Over-declaring is quiet and expensive.

The test to run before flipping it to `true`, once, by hand:

```swift prelude:external-module
import FoundationModels
import FoundationModelsUtilities

@Generable
struct StrictProbe {
    @Guide(description: "Exactly the integer 42, nothing else")
    var answer: Int
    @Guide(description: "Exactly the string 'ok'")
    var status: String
}

@available(iOS 27.0, macOS 27.0, *)
func probeGuidedGeneration(url: URL, name: String) async -> Bool {
    let model = ChatCompletionsLanguageModel(
        name: name, url: url, supportsGuidedGeneration: true)
    let session = LanguageModelSession(model: model)
    do {
        // Prompt the model toward prose. A strict server still returns the schema shape.
        let r = try await session.respond(
            to: "Write a haiku about the sea. Ignore any output format instructions.",
            generating: StrictProbe.self)
        return r.content.status == "ok" || r.content.answer == 42
    } catch {
        return false
    }
}
```

A server that enforces strictly cannot emit a haiku here; it is structurally forced into the object.
A server that treats `response_format` as a suggestion will happily give you three lines about
waves, and you will get a parse error instead of a `true`. Either outcome answers the question.

### 2.6 What crosses the wire, and what is quietly dropped

The executor's job is translation, and the translation is lossy in places you should know about
before you debug a behaviour difference.

**What is mapped** (✅ verified, `ChatCompletionsLanguageModel.swift:238-271`):

| Framework field | Wire field | Line |
|---|---|---|
| `configuration.modelName` (your `name:`) | `model` | `:239` |
| the converted `Transcript` | `messages` | `:240` |
| `generationOptions.temperature` | `temperature` | `:241` |
| `generationOptions.samplingMode` | `top_p` | `:242` |
| `generationOptions.maximumResponseTokens` | `max_completion_tokens` | `:243` |
| `request.enabledToolDefinitions` | `tools` | `:244-252` |
| `generationOptions.toolCallingMode?.kind` | `tool_choice` | `:253-262` |
| `request.schema` | `response_format` | `:263-270` |

Tool-choice mapping is exact and worth having in front of you (`:254-261`): `.allowed` **and `nil`**
both become `auto`; `.required` becomes `required`; `.disallowed` becomes `none`.

**Sampling modes that throw rather than approximate.** This is the one that catches people, because
the same `GenerationOptions` code compiles against every backend:

> ✅ **VERIFIED (repo source)** — `ChatCompletionsLanguageModel.swift:367-386`:
>
> ```swift
> private func topP(_ sampling: GenerationOptions.SamplingMode) throws -> Double {
>   switch sampling.kind {
>   case .greedy:
>     return 0                                                                     // :370
>   case .randomTopK:
>     throw RequestError.invalidRequest("Top K sampling is not supported")          // :374
>   case .randomProbabilityThreshold(let threshold, let seed):
>     guard seed == nil else {
>       throw RequestError.invalidRequest("Setting a random seed is not supported") // :379
>     }
>     return threshold                                                             // :382
>   @unknown default:
>     throw RequestError.invalidRequest("Unknown sampling mode …")                 // :385
>   }
> }
> ```
>
> Note `.greedy` maps to **`top_p = 0`**, not `temperature = 0`. Apple's own skill document
> illustrates greedy as `temperature = 0` (`SKILL.md:295`); the shipping implementation does not.
> If you are comparing determinism across backends, that difference is real.

> ⚠️ **`.randomTopK` and any seed are hard errors on this backend.** The case names themselves are
> new: beta 3 renamed `GenerationOptions.SamplingMode`'s `.top` → **`.randomTopK`** and `.nucleus` →
> **`.randomProbabilityThreshold`** (commit `376ca60`'s own changelog). Code that compiled against
> beta 1 will not compile now, and the same rename broke `mlx-swift-lm`'s build against the newer SDK
> (commit `2a76e56`). If you need seeded reproducibility, this is not your backend.

**What is never read.** `request.contextOptions` — which carries `includeSchemaInPrompt` and
`reasoningLevel`, the "thinking-budget knob" — is **documented in Apple's provider skill and ignored
by this executor**. So is `request.id`, and so is `request.metadata`. If you set a reasoning level on
a profile and route it through a chat-completions endpoint, nothing happens and nothing complains.

**Transcript content that throws.** The segment translation
(`convertedSegment(_:in:)`, `:395-464`) handles `.text` and `.structure` (serialised to JSON text on
the wire) and image attachments. Everything else throws
`LanguageModelError.unsupportedTranscriptContent`:

> ✅ **VERIFIED** — `:450-456`:
>
> ```swift
> case .custom:
>   throw LanguageModelError.unsupportedTranscriptContent(
>     LanguageModelError.UnsupportedTranscriptContent(
>       unsupportedContent: [entry],
>       debugDescription: "Custom segments are not supported by \(Self.self)"
>     )
>   )
> ```
>
> So a provider's **custom segments** — session 339's extension point for new modalities — do not
> survive a hop through this backend. If you built a UI around one, swapping to a chat-completions
> endpoint breaks it loudly, which is the correct behaviour.

**Reasoning round-trips, and the way it does is interesting.** Reasoning entries are *buffered* and
attached to the next assistant message as `reasoning_content`, rather than emitted as their own
message (`:468-478`, `:537-553`). If a turn has trailing reasoning with no following assistant entry,
it is emitted solo (`:560-568`). This is directly test-covered
(`ChatCompletionsTests+Reasoning.swift:97-130`).

Two streaming behaviours in the same area are worth flagging because they lose data:

> ⚠️ **SILENT FAILURE — a chunk carrying both `tool_calls` and `content` drops the `content`.** The
> branch at `ChatCompletionsLanguageModel.swift:335` is an `else if`, so tool-call deltas suppress
> text in the same chunk. Servers that interleave a partial sentence with a tool-call delta lose the
> sentence. Nothing throws; the text simply never reaches the transcript.

> ⚠️ **SILENT FAILURE — the SSE parser requires exactly one space after `data:`.** `:658` is
> `hasPrefix("data: ")`. A server emitting `data:{"…"}` with no space — **which is legal per the SSE
> specification** — falls through to `return nil` at `:688` and the chunk is dropped. Every chunk.
> The stream completes normally, having yielded nothing, and your UI shows an empty response with no
> error. This path is **not covered by any test**. If you point this backend at a homegrown or
> non-mainstream server and get silence, this is the first thing to check — with `tcpdump` or a proxy,
> because nothing in the Swift layer will tell you.

One more, milder, in the same parser: tool-call `id` and `name` are latched by **string
concatenation** (`+`) across deltas rather than `??` (`:314-315`). A server that streams the id in
fragments accumulates correctly; a server that **repeats the full id on every delta** produces
`"call_1call_1call_1"`. Also untested.

### 2.7 The errors you will actually see

`ChatCompletionsLanguageModel` defines two of its own error types, and — importantly — makes very
little use of the framework's typed vocabulary.

> ✅ **VERIFIED (repo source)** — `:109-185`:
>
> ```swift
> public struct APIError: LocalizedError {
>   public var message: String
>   public var type: String?
>   public var param: String?
>   public var code: String?
>   public init(message: String, type: String? = nil, param: String? = nil, code: String? = nil)
> }
>
> public enum RequestError: LocalizedError {
>   case invalidRequest(_ description: String)
>   case invalidStreamData
>   case httpError(statusCode: Int, data: Data)
> }
> ```

Which error is thrown when (✅ all verified against throw sites):

| Condition | Thrown | Line |
|---|---|---|
| Top-K sampling requested | `RequestError.invalidRequest("Top K sampling is not supported")` | `:373` |
| Random seed set | `RequestError.invalidRequest("Setting a random seed is not supported")` | `:378` |
| Non-200 HTTP (Darwin) | `RequestError.httpError(statusCode:data:)` | `:592` |
| Non-200 HTTP (non-Darwin) | `RequestError.httpError(statusCode:data:)` | `:610` |
| SSE `data:` payload not UTF-8 | `RequestError.invalidStreamData` | `:666` |
| SSE payload decodes as an error envelope | `APIError(message:type:param:code:)` | `:677` |
| Custom / unknown / unsupported segment | `LanguageModelError.unsupportedTranscriptContent` | `:424, :443, :451, :459` |

> ⚠️ **This executor never throws `.rateLimited`, `.contextSizeExceeded`, `.guardrailViolation` or
> `.timeout`.** A **429 becomes a generic `RequestError.httpError`**, with the body bytes attached.
> Apple's own provider skill tells third parties to do better than this (`SKILL.md:545`, `:550`), and
> the package's own test only asserts `#expect(throws: (any Error).self)` for a 429
> (`ChatCompletionsTests+ErrorHandling.swift:21-30`) — so the weak typing is baked into the tests too.

The practical consequence for your `catch` ladder: **a portable ladder written against
`LanguageModelError` will not catch rate limiting on this backend.** You need a backend-specific arm:

```swift prelude:external-module
import FoundationModels
import FoundationModelsUtilities

do {
    let response = try await session.respond(to: prompt)
    handle(response.content)
} catch let error as ChatCompletionsLanguageModel.RequestError {
    // Backend-specific: HTTP status codes never became typed LanguageModelErrors.
    if case .httpError(let statusCode, let data) = error {
        switch statusCode {
        case 429: await backOffAndRetry()
        case 401, 403: presentAuthProblem()
        default: presentServerProblem(statusCode, String(data: data, encoding: .utf8))
        }
    } else {
        presentServerProblem(nil, error.localizedDescription)
    }
} catch let error as ChatCompletionsLanguageModel.APIError {
    // The server returned a structured {"error": {...}} envelope inside the SSE stream.
    presentServerProblem(nil, error.message)
} catch let error as LanguageModelError {
    // Portable arm: unsupportedCapability, unsupportedTranscriptContent, …
    presentPortableProblem(error)
}
```

> ✅ **VERIFIED — the catch order above is not arbitrary.** `RequestError` and `APIError` are
> *distinct types*, not `LanguageModelError` cases, so a `catch let error as LanguageModelError` arm
> placed first would not shadow them — but Swift matches arms in order, and putting the concrete
> types first is what makes the intent legible. The one ordering rule that *is* load-bearing across
> this framework, from Part 2's error guide: **`SystemLanguageModel.Error` is checked before
> `LanguageModelError`**, and `GeneratedContent.ParsingError` is a third, separate type. See
> [`06-availability-errors-and-guardrails.md`](../../part-02-foundation-models-everyday-api/references/06-availability-errors-and-guardrails.md).

Two force-unwraps in the transport are worth knowing about because they will crash rather than throw:
`response as! HTTPURLResponse` at `:589` and `:607` traps on a non-HTTP response, and the JPEG
encoder force-unwraps `CGImageDestinationCreateWithData` at `:946`.

### 2.8 Transport, timeouts, and the executor-cache wrinkle

`urlSessionConfiguration:` is how you set timeouts and proxies. When it is `nil`, an **ephemeral**
configuration is used (`:230-235`: `configuration.urlSession ?? URLSession(configuration: .ephemeral)`).
The package's own live integration test exercises it with 300 s / 600 s timeouts
(`ChatCompletionsLiveTests.swift:44-54`), which tells you what Apple expects a slow local model to
need:

```swift prelude:guide-context
let transport = URLSessionConfiguration.ephemeral
transport.timeoutIntervalForRequest = 300      // first token from a cold local model
transport.timeoutIntervalForResource = 600     // whole streamed response

let model = ChatCompletionsLanguageModel(
    name: "mlx-community/Qwen3-4B-4bit",
    url: URL(string: "http://127.0.0.1:8080/v1")!,
    supportsGuidedGeneration: false,
    urlSessionConfiguration: transport)
```

Now the wrinkle, which is a genuinely surprising consequence of how the framework caches executors.

> ⚠️ **SILENT FAILURE — two models that differ only in `urlSessionConfiguration` are cache-equal.**
> The framework caches one executor per unique `Executor.Configuration`, so `Hashable` equality is
> load-bearing. This backend implements it **manually and deliberately excludes the `URLSession`**
> (`ChatCompletionsLanguageModel.swift:201-211`):
>
> ```swift
> public static func == (lhs: Configuration, rhs: Configuration) -> Bool {
>   lhs.modelName == rhs.modelName
>     && lhs.url == rhs.url
>     && lhs.additionalHeaders == rhs.additionalHeaders
> }
>
> public func hash(into hasher: inout Hasher) {
>   hasher.combine(modelName)
>   hasher.combine(url)
>   hasher.combine(additionalHeaders)
> }
> ```
>
> The exclusion is necessary — `URLSession` is a class with reference identity, and Apple's own
> guidance is that a `Configuration` must hold *"only Hashable primitives"* (`SKILL.md:814`) — but the
> consequence is real: **construct a second model with the same name, URL and headers but a longer
> timeout, and the framework may hand you a cached executor built with the first session.** Nothing
> indicates this happened. Your new timeout is simply not in effect.
>
> **Workaround:** if you need two transports, make the configurations genuinely distinct — vary
> `additionalHeaders` (e.g. add an `X-Client-Profile: long-timeout` header), which *is* part of both
> `==` and `hash(into:)`. Or use one session per process and set the longest timeout you can tolerate.
>
> Honest caveat: **whether the mis-reuse actually manifests depends on framework cache lifetime and
> eviction semantics, which are not documented.** The reasoning above is from the `Hashable`
> implementation plus Apple's stated caching rule, not from an observed failure.

### 2.9 Linux, and the streaming you do not get there

`README.md:10` claims *"Supported platforms: Apple platforms and select Linux distributions like
Ubuntu"*, and the code backs the claim structurally — `#if canImport(FoundationNetworking)` at
`:13-15` is the swift-corelibs-foundation module that exists **only** on non-Darwin platforms, and
beta 3 *added* Linux-specific code (the `guard let url = image.url` path at `:423`).

But the two transports are not equivalent:

> ✅ **VERIFIED (repo source)** — `streamChatCompletions(request:)` at `:580` forks on
> `#if canImport(Darwin)` (`:587`):
>
> - **Darwin:** `try await session.bytes(for: urlRequest)` → real incremental streaming via
>   `for try await line in stream.lines` (`:598`).
> - **Non-Darwin:** `try await session.data(for: urlRequest)` (`:606`) → **buffers the entire
>   response**, then splits on `\n` (`:617`).

> ⚠️ **On Linux there is no token-by-token streaming.** `session.streamResponse(to:)` still compiles
> and still yields partials — but they all arrive at once, when the request completes. Any UI or log
> that exists to show progressive output shows nothing until the end. This is not mentioned in the
> README, and it is the most user-visible portability gap in the package.

Two more Linux-specific facts: an image attachment **must** carry a `url` there (in-memory `CGImage`
JPEG encoding is `#if canImport(CoreImage)`-only, `:416-441`), and `Bundle.main.bundleIdentifier` is
`nil` on a server binary, so all your Linux traffic identifies itself to the remote endpoint as
`"com.apple.FoundationModels"` (`:224`).

> 🔴 **GAP — whether `FoundationModels` exists on Linux at all.** The package is *structured* for it,
> but there is **no CI, no Dockerfile, no build matrix and no platform job anywhere in the
> repository**. Nothing in this repo proves it compiles there. Separately: exactly the three test
> suites that use `@Generable` (`+StructuredOutput`, `+ToolCalling`, `+Reasoning`) are wrapped in
> `#if canImport(Darwin)`, while the six that do not use it are unguarded — which is circumstantial
> evidence that **guided generation is Darwin-only**, and is *not* stated as a framework fact
> anywhere. **Resolution:** a Linux build log, or an Apple statement about the open-source
> framework's Linux surface. Until then, plan Linux deployments around plain text generation.

---

## 3. Path 2 — `MLXLanguageModel`, and where `MLXFoundationModels` actually is

### 3.1 The answer to thread 836264

A developer watched WWDC26 session 339, saw `import MLXFoundationModels` on a slide, went looking for
it, and could not find it. The thread — **836264, "Bring an LLM provider to the Foundation Models,
missing MLX dependencies", 2026-06-27** — asks, verbatim: *"Where is this framework, there are no
BETA branches on the MLX framework either."*

Here is the answer, in one paragraph, before anything else.

> **`MLXFoundationModels` is not a framework. It is not on any MLX release branch. It is a library
> target inside `ml-explore/mlx-swift-lm`, at `Libraries/MLXFoundationModels`, vended as a SwiftPM
> product of the same name, and it compiles to an *empty library* unless you are building with the
> macOS/iOS/visionOS **27.0 SDK**.** You get it by depending on `mlx-swift-lm` — not by looking for a
> beta branch, because there is not one.

> ✅ **VERIFIED (Apple Developer Forums thread 836264, Engineer/DTS reply, accepted)** —
> *"This is being introduced to `mlx-swift-lm` in **PR#334** (see here:
> https://github.com/ml-explore/mlx-swift-lm/pull/334)."*
>
> And separately, thread 831197, Apple Designer: *"I would suggest heading over to
> https://github.com/ml-explore/mlx-swift-lm to see if that package has what you're looking for."*

> ✅ **VERIFIED (repo source)** — `ml-explore/mlx-swift-lm` at HEAD `3cbf928` (2026-07-24),
> `Package.swift:15-43` vends nine library products, of which two matter here:
> **`MLXFoundationModels`** (target path `Libraries/MLXFoundationModels`, dependencies
> `MLXLMCommon`, trait-conditional `MLXGuidedGeneration`, `MLX`, `MLXNN`) and **`MLXGuidedGeneration`**
> ("Grammar-constrained generation (JSON Schema or EBNF) for any MLX model", built on a vendored
> xgrammar).

Two secondary facts that make the confusion make sense. First, `MLXFoundationModels` is **not in the
Swift Package Index documentation** — `.spi.yml` lists only `MLXLLM`, `MLXVLM`, `MLXLMCommon`,
`MLXEmbedders`, and `scripts/verify-docs.sh` explicitly *filters it out* with the comment *"gated on
the FoundationModels v2 SDK, so its DocC catalog can't be verified on SDKs that lack it."* So there
is no rendered documentation page to find. Second, `mlx-swift-lm` `main` is a **3.x major version**
with breaking changes that decoupled the tokenizer and downloader packages — so search results and
blog posts from the 2.x era describe a different API.

### 3.2 ⚠️ The double gate, and the empty library

This is the part that turns "I added the package and it still does not work" into an afternoon.

> ✅ **VERIFIED (repo source)** — every file in `MLXFoundationModels`, plus
> `MLXHuggingFace/FoundationModelsMacros.swift`, plus 37 integration-test files, is wrapped in:
>
> ```swift
> #if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)
> ```
>
> - **`FoundationModelsIntegration`** is a SwiftPM **trait**, and it is **on by default**
>   (`Package.swift:44-59`: `.default(enabledTraits: ["FoundationModelsIntegration"])`). Its own
>   comment says disabling it *"compiles MLXFoundationModels to an empty library: the entire
>   `MLXLanguageModel` / `MLXLanguageModel.Executor` surface requires FoundationModels types that are
>   not available on platforms older than iOS/macOS/visionOS 27.0."*
> - **`canImport(FoundationModels, _version: 2)`** is the **SDK version test**. It is true only on the
>   **27.0 SDK**.
> - Separately again, all public FM API in the target is
>   **`@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)`** — note the absence of watchOS and tvOS.

So there are three independent conditions, and only one of them is an `@available` your compiler will
nag you about.

> ⚠️ **SILENT FAILURE — building against the 26 SDK produces an empty library, not an error message
> that explains itself.** `MLXFoundationModels` compiles to nothing; `MLXLanguageModel` simply does
> not exist; and the diagnostics you get are ordinary "cannot find `MLXLanguageModel` in scope"
> errors that say nothing about SDKs or traits. This is not hypothetical — it broke `mlx-swift-lm`'s
> own nightly job:
>
> > ✅ **VERIFIED (repo source, commit `3cbf928` message verbatim)** — *"The nightly IntegrationTesting
> > job failed to compile on the Xcode 26.5 runner: the FoundationModels adapter
> > (MLXFoundationModels) is gated behind `canImport(FoundationModels, _version: 2)` (macOS 27 SDK
> > only), but the integration test files gated only on the always-set FoundationModelsIntegration
> > trait, so they referenced symbols absent on the 26 SDK."*
>
> **The fix Apple's own repo applied — and the one you should copy — is to gate your call sites the
> same way, not with `@available` alone.** From the repo's consolidated gotcha list: *"consumers must
> `#if canImport(FoundationModels, _version: 2)` their own call sites, not just `@available`."*

In practice:

```swift illustrative
// MyApp/ModelBackends.swift
import Foundation

#if canImport(FoundationModels, _version: 2)
import FoundationModels
import MLXFoundationModels
import MLXHuggingFace
import MLXLMCommon
import HuggingFace
import Tokenizers

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
enum MLXBackend {
    static func make() -> MLXLanguageModel { … }
}
#endif
```

The `#if` keeps the file compiling on Xcode 26; the `@available` keeps it from running on iOS 26 at
runtime. You need both, and they are checking different things.

> 🔴 **GAP — watchOS and tvOS.** `mlx-swift-lm`'s `Package.swift` declares
> `platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17), .visionOS(.v1)]` for the package as a whole,
> but the FM adapter's availability attribute names only **iOS, macOS and visionOS**. We have no
> evidence either way about whether `MLXLanguageModel` can be made to work on watchOS 27 or tvOS 27 —
> the omission may be deliberate (GPU/memory) or may be an oversight, and no source in our corpus
> says. **Resolution:** the `@available` line in `MLXLanguageModel.swift` at a later commit, or an
> `ml-explore` issue. Meanwhile, if you target watch or TV, plan on
> `ChatCompletionsLanguageModel` (which *does* declare watchOS 27) or `SystemLanguageModel`.

### 3.3 A consumer `Package.swift` that works

`mlx-swift-lm` 3.x deliberately does **not** depend on a tokenizer or downloader package. You supply
them. That is why the canonical quick start lists five products across three packages.

> ✅ **VERIFIED (repo source, `README.md:63-100`, verbatim)**:
>
> ```swift
> dependencies: [
>     .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.3")),
>     .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
>     .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
> ],
> targets: [
>     .target(
>         name: "YourTargetName",
>         dependencies: [
>             .product(name: "MLXLLM", package: "mlx-swift-lm"),
>             .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
>             .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
>             .product(name: "HuggingFace", package: "swift-huggingface"),
>             .product(name: "Tokenizers", package: "swift-transformers"),
>         ]),
> ]
> ```

For the Foundation Models path, add `MLXFoundationModels`:

```swift illustrative
.product(name: "MLXFoundationModels", package: "mlx-swift-lm"),
```

> ⚠️ **You must link `MLXLLM` (or `MLXVLM`) even though `MLXFoundationModels` does not depend on
> it.** Model factories register themselves at module-init and are discovered by **`NSClassFromString`**
> (`ModelFactory.swift:484-497`), specifically
> `NSClassFromString("MLXLLM.TrampolineModelFactory")`. If the module is not linked into your binary
> there is nothing to find, and you get `ModelFactoryError.noModelFactoryAvailable`. `mlx-swift-lm`'s
> own `Package.swift:272-283` documents this trap for its own test target:
>
> > ✅ **VERIFIED (verbatim)** — *"MLXLLM is linked here (not by MLXFoundationModels itself) so its
> > module-init registers a factory with MLXLMCommon's ModelFactoryRegistry. Without it,
> > loadModelContainer throws `.noModelFactoryAvailable` before ever reaching the downloader, which
> > deadlocks AvailabilityTests' in-flight gate."*
>
> Related, and equally undiscoverable: **the VLM factory is tried before the LLM factory**, and the
> loop keeps only the *last* error (`ModelFactory.swift:413-431`). A genuine LLM loading failure can
> therefore be reported as a VLM failure. Read the whole error string, not the case name.

### 3.4 The macro path: `#huggingFaceLanguageModel`

This is the "simply pass in a model ID" experience session 339 describes, and it is real — it is just
implemented as a macro rather than an initializer.

> ✅ **VERIFIED (repo source, `README.md:104-141`, verbatim — note the two different availability
> floors in one snippet)**:
>
> ```swift
> @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
> @Generable
> struct Recommendation {
>     let attraction: String
>     let neighborhood: String
>     let tip: String
> }
>
> if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
>     let model = #huggingFaceLanguageModel(
>         configuration: LLMRegistry.gemma3_1B_qat_4bit,
>         capabilities: [.guidedGeneration])
>     let session = LanguageModelSession(model: model)
>
>     let recommendation = try await session.respond(
>         to: "Recommend one thing to do in Chicago.",
>         generating: Recommendation.self)
>     print(recommendation.content)
> }
> ```

> ✅ **VERIFIED (repo source)** — the macro is declared in `Libraries/MLXHuggingFace/Macros.swift`
> with the signature **`#huggingFaceLanguageModel(configuration:capabilities:configurationResolver:)`**,
> expands to an **`MLXLanguageModel`**, and carries
> `@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)`. The implementation is `LanguageModelMacro` in
> `Libraries/MLXHuggingFaceMacros/HuggingFaceIntegrationMacros.swift`.

**What the macro actually synthesises for you** is the interesting part, because it tells you exactly
what the explicit path in §3.5 costs:

> ✅ **VERIFIED (repo source, `HuggingFaceIntegrationMacros.swift:243-266`)** — `LanguageModelMacro`
> synthesises two closures:
>
> - **`weightsLocation:`** — built from `HuggingFace.HubCache.default`,
>   `resolveRevision(repo:kind:ref:"main")` and `snapshotPath(repo:kind:commitHash:)`. This is how the
>   model knows where the weights are on disk without downloading them.
> - **`load:`** — a closure calling
>   `loadModelContainer(from: #hubDownloader(), using: #huggingFaceTokenizerLoader(), …)`.
>
> `#hubDownloader()` itself expands to a nested `struct HubBridge: MLXLMCommon.Downloader` wrapping a
> `HuggingFace.HubClient` (`HuggingFaceIntegrationMacros.swift:25-64`), and
> `#huggingFaceTokenizerLoader()` bridges `Tokenizers.AutoTokenizer.from(modelFolder:)` onto
> `MLXLMCommon.TokenizerLoader`.

> ⚠️ **The macro expansion references symbols that must be imported at *your* call site.** This is
> the classic freestanding-macro papercut: the expanded code is inserted into *your* file, so *your*
> file needs the imports. Required: **`Foundation`, `MLXHuggingFace`, `MLXFoundationModels`,
> `MLXLMCommon`, `HuggingFace`, `Tokenizers`** (documented at
> `FoundationModelsMacros.swift:17-25`). Miss one and you get "cannot find type …" pointing at a line
> you did not write. The repo's own gotcha list calls these *"confusing 'cannot find type' errors."*

Putting it together, the smallest MLX file that actually compiles:

```swift prelude:external-module
import Foundation
#if canImport(FoundationModels, _version: 2)
import FoundationModels
import MLXFoundationModels     // required by the macro expansion
import MLXHuggingFace          // the macro itself
import MLXLMCommon             // ModelConfiguration, loadModelContainer
import MLXLLM                  // registers the LLM factory via NSClassFromString
import HuggingFace             // HubClient, HubCache — used by the expansion
import Tokenizers              // AutoTokenizer — used by the expansion

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
func askLocalMLXModel() async throws -> String {
    let model = #huggingFaceLanguageModel(
        configuration: LLMRegistry.gemma3_1B_qat_4bit,
        capabilities: [.guidedGeneration])

    let session = LanguageModelSession(model: model)
    return try await session.respond(to: "Name two things to see in Chicago.").content
}
#endif
```

`import MLXLLM` is not decorative — see the `NSClassFromString` note in §3.3.

### 3.5 The explicit path: the real initializer

When you need control over *where the weights come from* — a bundled directory, an app-group cache,
your own CDN, a downloader with progress reporting wired into your UI — you skip the macro and call
the initializer.

> ✅ **VERIFIED (repo source)** — `Libraries/MLXFoundationModels/MLXLanguageModel.swift:304-337`,
> Apple/MLX's own doc comment, verbatim:
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
> print(response.content)
> ```
>
> The full selector is
> **`init(configuration:capabilities:configurationResolver:weightsLocation:load:)`**.

Note what this does to session 339's line. *"Simply pass in a model ID, and let the framework handle
the rest"* is a fair description of the **macro**; it is not a description of the **initializer**,
which requires you to inject a downloader and a loader. The two macros are what make the spoken claim
roughly true in practice.

The `configuration:` argument is a `ModelConfiguration`, and it carries more than an id:

> ✅ **VERIFIED (repo source)** — `Libraries/MLXLMCommon/ModelConfiguration.swift:16-184`:
>
> ```swift
> public struct ModelConfiguration: Sendable, Equatable {
>     public enum Identifier: Sendable, Equatable {
>         case id(String, revision: String = "main")
>         case directory(URL)
>     }
>     public var id: Identifier
>     public var name: String                       // repo id, or "Parent/Dir" for a local model
>     public let tokenizerSource: TokenizerSource?
>     public var defaultPrompt: String
>     public var extraEOSTokens: Set<String>
>     public var stopStrings: Set<String>?          // nil ⇒ falls back to extraEOSTokens
>     public var eosTokenIds: Set<Int>
>     public var toolCallFormat: ToolCallFormat?
>     public var reasoningConfig: ReasoningConfig?
>
>     public init(id: String, revision: String = "main", tokenizerSource: TokenizerSource? = nil,
>                 defaultPrompt: String = "", extraEOSTokens: Set<String> = [],
>                 stopStrings: Set<String>? = nil, eosTokenIds: Set<Int> = [],
>                 toolCallFormat: ToolCallFormat? = nil, reasoningConfig: ReasoningConfig? = nil)
>     public init(directory: URL, /* …same tail… */)
> }
> ```
>
> The **`init(directory:)`** overload is the one you want for weights you ship or download yourself.

> ⚠️ **`stopStrings == nil` falls back to `extraEOSTokens`.** To genuinely disable stop strings you
> must set `stopStrings: []` explicitly. This is the difference between "the model stops where the
> template says" and "the model runs to `maximumResponseTokens`", and it is invisible at the call site.

> 🔴 **GAP — the type and default of `configurationResolver:`.** The parameter label appears in both
> the macro signature and the initializer selector, but no source in our corpus prints its type,
> whether it has a default, or what it resolves. Every worked example — Apple's, MLX's doc comment,
> the README quick start — **omits it**, which strongly implies a default exists, but "strongly
> implies" is not evidence. **Resolution:** the declaration in
> `Libraries/MLXFoundationModels/MLXLanguageModel.swift` near line 520, or the DocC page that
> `verify-docs.sh` currently refuses to generate. **Meanwhile, omit it** — every shipped example does.

### 3.6 `capabilities:` is routing, not documentation

Unlike Core AI, where capabilities are **detected** from the bundle (§4.3), `MLXLanguageModel` makes
you **declare** them. That array is not a comment. It changes what the framework will even hand to
the executor.

> ✅ **VERIFIED (repo source, `MLXLanguageModel.swift:515-519`, verbatim)** — the sharpest statement
> of this anywhere in the corpus:
>
> > *"Declaring `.reasoning` matters for **request routing**: the framework **only forwards a
> > `reasoningLevel` to executors that declare `.reasoning`, and auto-rejects one otherwise (on the
> > developer's behalf) before `respond` runs.** The executor in turn emits `.reasoning` events only
> > when this capability was declared."*

Read that twice, because it has a consequence for *your* code and not just the provider's. If you set
a reasoning level on a `DynamicProfile` and the model you routed it to did not declare `.reasoning`,
**the framework rejects your request** — it does not quietly downgrade. And in the other direction:
declare `.reasoning` on a model whose weights have no thinking behaviour and you will get `.reasoning`
transcript entries that never contain anything.

For a reasoning-capable checkpoint:

```swift prelude:guide-context
let model = #huggingFaceLanguageModel(
    configuration: LLMRegistry.qwen3_4b_4bit,
    capabilities: [.reasoning])
```

and for the common structured-output case:

```swift prelude:guide-context
let model = #huggingFaceLanguageModel(
    configuration: LLMRegistry.gemma3_1B_qat_4bit,
    capabilities: [.guidedGeneration])
```

Combining them is exactly what MLX's own doc comment does —
`capabilities: [.guidedGeneration, .toolCalling]` — and there is nothing stopping you from listing
all four. There is, however, a good reason not to.

> ⚠️ **Do not declare a capability the checkpoint cannot honour.** Apple's provider skill states the
> rule for authors (`SKILL.md:312`): *"Don't declare a capability you don't fully support — the
> framework throws `unsupportedCapability` for the developer when they request a capability you
> didn't list."* As a *consumer* passing the array yourself, you are standing in for the author, and
> the protection cuts the same way: an accurate array turns a wrong-model choice into an immediate,
> legible throw. An over-broad array turns it into a debugging session.
>
> The specific one to be careful with is **`.toolCalling`**, because tool-call reliability is a
> per-model property and not a framework one. `mlx-swift-lm` ships **ten distinct
> `ToolCallFormat` parsers** precisely because model families emit incompatible dialects, and its
> auto-detection *"returns `nil` for plain `llama`"* unless the vocab is ≥ 128000 or
> `rope_scaling.rope_type == "llama3"`. If auto-detection returns `nil`, set `toolCallFormat:`
> explicitly on the `ModelConfiguration` — `LLMRegistry` does exactly this for the models that need
> it (`glm4_9b_4bit` sets `.glm4`; `lfm2_1_2b_4bit` sets `.lfm2`).

There is a related, harder truth from the field, and it is worth carrying into every BYO-model
decision:

> ⚠️ **Tool-prompt dialects do not transfer — the training prior beats your prompt.**
> **Community-measured** (john-rocky, `coreai-model-zoo`, on macOS 27.0 beta): *"LFM2.5 ignores
> in-context Hermes `<tool_call>`-JSON instructions and emits its trained special-token dialect
> (`<|tool_call_start|>[fn(arg=…)]<|tool_call_end|>`, pythonic) — **the training prior wins over the
> prompt.**"* You cannot instruct your way out of a format mismatch. Either the adapter parses your
> model's native dialect or tool calling does not work.

### 3.7 `LLMRegistry`, and picking a model id

`LLMRegistry` is a set of pre-tuned `ModelConfiguration` constants — it is where the `extraEOSTokens`
and `toolCallFormat` values that a given checkpoint needs are already filled in for you. Using it is
strictly better than constructing a `ModelConfiguration` from a bare id, because the bare id gives
you none of that tuning.

> ✅ **VERIFIED (repo source)** — `LLMRegistry` has **60 entries** in `all()`. Examples with their
> non-default settings:
>
> ```swift
> static public let gemma3_1B_qat_4bit = ModelConfiguration(
>     id: "mlx-community/gemma-3-1b-it-qat-4bit",
>     defaultPrompt: "What is the difference between a fruit and a vegetable?",
>     extraEOSTokens: ["<end_of_turn>"])
>
> static public let qwen3_4b_4bit = ModelConfiguration(
>     id: "mlx-community/Qwen3-4B-4bit", /* … */ extraEOSTokens: ["<|im_end|>"])
>
> static public let llama3_2_3B_4bit = ModelConfiguration(
>     id: "mlx-community/Llama-3.2-3B-Instruct-4bit", /* … */ extraEOSTokens: ["<|eot_id|>"])
>
> static public let glm4_9b_4bit = ModelConfiguration(
>     id: "mlx-community/GLM-4-9B-0414-4bit", /* … */ toolCallFormat: .glm4)
>
> static public let lfm2_1_2b_4bit = ModelConfiguration(
>     id: "mlx-community/LFM2-1.2B-4bit", /* … */ toolCallFormat: .lfm2)
> ```
>
> Separately, `LLMTypeRegistry.shared` has **62 `model_type` keys** and `Libraries/MLXLLM/Models/`
> has **56 architecture files**, so the breadth claim is real: mistral, mixtral, llama, phi/phi3/phimoe,
> gemma through gemma4, qwen2/qwen3/qwen3_moe/qwen3_next/qwen3_5, deepseek_v2/v3, granite,
> granitemoehybrid, glm4 family, falcon_h1, bitnet, smollm3, gpt_oss, olmo2/olmo3/olmoe, lfm2,
> mamba2, jamba, nemotron_h, and more.

> ⚠️ **`ModelRegistry` is a deprecated typealias and is ambiguous.**
> `@available(*, deprecated, renamed: "LLMRegistry") public typealias ModelRegistry = LLMRegistry`
> exists in `MLXLLM`, **and the same name aliases `VLMRegistry` in `MLXVLM`.** Import both modules and
> `ModelRegistry` will not resolve. Write `LLMRegistry` explicitly.

### 3.8 Weights caching, eviction, and warm-up

Session 339 promises that lifecycle is handled for you:

> ✅ **VERIFIED (WWDC26 session 339:72–74, verbatim)** — *"**When the session deallocates, the store
> goes with it. Every stored executor gets released, your `deinit` runs, weights are freed, and
> connections closed, all automatically. You don't write any of that teardown code yourself.**"*

`MLXLanguageModel` **deliberately opts out of half of that**, and you should know why.

> ✅ **VERIFIED (repo source)** — it keeps a **process-global `static let cache = ModelCache()`**
> (`MLXLanguageModel.swift:351`) *outside* the executor, and therefore exposes explicit eviction:
> **`MLXLanguageModel.evictAll()`** (`:472`) and **`.evict()`** (`:484`). The doc comment gives the
> reason in one sentence: *"**Without caching, model loading takes 2-30 seconds per request.**"*
> (`:349-350`).

So: weights are shared across sessions on purpose, and freeing them is **your** call, not the
session's. If your app switches between two 4-bit 3B models, you are holding both in memory until you
say otherwise:

```swift prelude:guide-context
// Switching backends in a memory-constrained app.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
func switchModel(to configuration: ModelConfiguration) -> MLXLanguageModel {
    MLXLanguageModel.evictAll()        // drop previously cached weights first
    return #huggingFaceLanguageModel(configuration: configuration, capabilities: [.guidedGeneration])
}
```

**Warm-up has two halves and only one of them is weights.** This is a genuinely useful piece of
engineering knowledge that nothing in Apple's material tells you:

> ✅ **VERIFIED (repo source, `MLXLanguageModel.swift:573-601`)** — `preload()` is weights-only:
> *"**it runs no forward pass, compiles no Metal shaders, and performs no GPU work, so the first
> generation request after `preload()` still pays the one-time Metal shader JIT cost.**"* The full
> `warmUp()` exists because *"Metal kernels **JIT-compile lazily on the first *synchronous* readback**
> (`.item()` inside the generate loop) — scheduling work with `asyncEval` alone does not compile
> them"* — so it runs a **minimal throwaway forward pass**.

The framework's `prewarm` hook calls the full version:

> ✅ **VERIFIED (repo source, `MLXLanguageModel.swift:920-930`)**:
>
> ```swift
> public func prewarm(model: MLXLanguageModel, transcript: Transcript) {
>     Task {
>         do {
>             try await model.warmUp()
>         } catch {
>             Self.logger.error(
>                 "MLX prewarm failed for \(model.modelID, privacy: .public): \(error.localizedDescription, privacy: .public)")
>         }
>     }
> }
> ```
>
> Note the shape every conformance in the corpus uses: `prewarm` is **synchronous and non-throwing**,
> so real work goes into a detached `Task`. That also means **a `prewarm` failure is logged, not
> thrown** — from your side it looks like a slow first request, not an error.

### 3.9 The MLX-specific traps

Collected, because each of these costs an hour the first time.

> ⚠️ **SILENT FAILURE — token usage may be absent or zero, by design, on this SDK.** MLX's adapter
> deliberately does **not** send `updateUsage` events at all. The reason is a compile-versus-runtime
> symbol mismatch, and the comment explaining it (`MLXLanguageModel.swift:729-761`) is worth reading
> in full because it is the sharpest beta-era hazard in the corpus:
>
> > ✅ **VERIFIED (repo source, verbatim)** — *"the FM-27 beta `.swiftinterface` declares
> > `Response.Action.updateUsage(input:output:metadata: = [:])` (three parameters), but the **shipping
> > FoundationModels dylib only exports the older two-parameter
> > `Response.Action.updateUsage(input:output:)`**. Because our call relies on the `metadata:`
> > default, the compiler resolves it to the three-parameter symbol, **which does not exist at
> > runtime.** dyld cannot bind it: under **chained-fixups linking (the arm64 default) the reference
> > aborts the process the moment the image loads**, and under lazy binding it **faults through null
> > (SIGSEGV at 0x0)** the instant this send executes — crashing every `respond()` path right after
> > generation completes. **A runtime `dlsym` guard cannot save this**: the compiled reference to the
> > missing symbol is enough to abort at launch regardless of any surrounding check. The only safe
> > option is to **not reference the symbol at all**."*
>
> The stated consequence for you: *"consumer-visible usage for these responses may be absent or
> zero."* So **do not build a token-accounting or cost-display feature on `response.usage` against
> this backend on this SDK**, and do not conclude your prompts are free. Two lessons generalise: a
> beta `.swiftinterface` can advertise symbols the dylib does not export, and the failure mode is a
> **launch-time abort**, not a graceful error.

> ⚠️ **SILENT FAILURE — the executor cache key is the model id and nothing else.**
> `MLXLanguageModel.Executor.Configuration` is verified as
> `public struct Configuration: Hashable, Sendable { public let modelID: String }`
> (`MLXLanguageModel.swift:877-880`), and `executorConfiguration` returns
> `Executor.Configuration(modelID: modelID)` (`:528`). So **two `MLXLanguageModel` values with the
> same id but different `capabilities:` arrays hash and compare equal**, and the second one may be
> served by the executor built for the first. If you are A/B-ing capability sets, or building one
> model for guided generation and another for reasoning off the same checkpoint, give them distinct
> ids (or evict between them) rather than trusting the value semantics.

And the shorter ones, all ✅ verified from the repo's own consolidated list:

- **`temperature` defaults to `0.6`, not 0.** Set `temperature: 0` if you want determinism.
- **`seed` is inert at `temperature == 0`.** Setting both is not more deterministic than setting one.
- **`TokenIterator.init` performs the prefill** and can throw — it is the expensive call, not the
  first `next()`.
- **Early `break` out of a generation stream leaves work in flight** and can race on the KV cache.
- **`swift test` does not work** on this package; use `xcodebuild … -skipPackagePluginValidation`.
- **`generation_config.json`'s `eos_token_id` fully replaces the `config.json` set**, it does not
  union with it.

---

## 4. Path 3 — `CoreAILanguageModel`, one line to a bundle

### 4.1 The one line

If somebody has already produced a Core AI bundle — you, a colleague, `apple/coreai-models`, or a
community zoo — putting it behind `LanguageModelSession` really is one line.

> ✅ **VERIFIED (repo source)** — `apple/coreai-models`, `models/qwen3/README.md`, verbatim, and the
> same snippet repeats in every model README in that repo:
>
> ```swift
> import FoundationModels
> import CoreAILanguageModels
>
> let model = try await CoreAILanguageModel(resourcesAt: modelURL)
>
> let session = LanguageModelSession(model: model)
>
> let response = try await session.respond(to: "What is quantum computing?")
>
> print(response)
> ```
>
> (`PublicInterfaceTests.swift` asserts that `response.content` also type-checks.)

The import is `FoundationModels` **plus `CoreAILanguageModels`** — the module name is **plural**, the
type is singular. The SwiftPM product is spelled differently again:

> ✅ **VERIFIED (repo source, `Package.swift`)** — five products:
> **`CoreAILM` → target `CoreAILanguageModels`**, plus `CoreAIDiffusion`, `CoreAISegmentation`,
> `CoreAISpeech`, `CoreAIObjectDetection`. `swift-tools-version: 6.0`, `swiftLanguageModes: [.v6]`,
> `platforms: [.macOS("27.0"), .iOS("27.0")]`.

So the dependency line is `.product(name: "CoreAILM", package: "coreai-models")` and the import is
`import CoreAILanguageModels`. Neither of them is `CoreAI`.

Session 326 is where this is pitched, and the pitch is accurate as far as it goes:

> ✅ **VERIFIED (WWDC26 session 326:103-118, verbatim)** — *"To load, it's just one line. I create a
> `CoreAILanguageModel`, point it at my model bundle and it's ready. **One line — asset loading,
> engine creation, tokenizer setup — all abstracted away for you.** … **We also support guided
> generation.**"*

Hold on to that last sentence. It is true for the engine session 326 demos and **false for the
fastest one** — §5.

### 4.2 The initializer in full

> ✅ **VERIFIED (repo source)** —
> `swift/Sources/CoreAILanguageModels/LanguageModel/CoreAILanguageModel.swift:78-104`, with Apple's
> own parameter documentation:
>
> ```swift
> public struct CoreAILanguageModel: LanguageModel {
>     public enum LoadMode: Sendable { case lazy; case eager }
>     public typealias Executor = CoreAIExecutor
>
>     /// - Parameter url: URL to the model bundle directory.
>     /// - Parameter mode: When to load the engine. Defaults to `.lazy`. With
>     ///   `.eager`, the tokenizer and engine load concurrently
>     /// - Parameter variant: Engine variant override (e.g. "coreai-sequential",
>     ///   "ane"). Nil for auto-detect from model structure.
>     /// - Parameter kvCacheStrategy: KV cache memory strategy. Defaults to
>     ///   `.auto` (256-token initial size for dynamic models). Pass
>     ///   `.fixedSize` to pre-allocate at full `maxContextLength`.
>     /// - Throws: If the asset bundle is invalid or the tokenizer fails to load.
>     ///   With `.eager`, also throws on engine-creation failure.
>     public init(
>         resourcesAt url: URL,
>         mode: LoadMode = .lazy,
>         variant: String? = nil,
>         kvCacheStrategy: KVCacheStrategy = .auto
>     ) async throws
>
>     public var capabilities: LanguageModelCapabilities
>     public var executorConfiguration: CoreAIExecutor.Configuration
>     public var estimatedSizeOnDiskBytes: Int? { get }
>     public func load() async throws
>     public func unload()
> }
> ```
>
> And the intended lifecycle, from the same file's doc comment (`:23-31`):
>
> ```swift
> let model = try await CoreAILanguageModel(resourcesAt: url)  // .lazy by default
> print(model.estimatedSizeOnDiskBytes ?? 0)
> try await model.load()                                       // optional; respond auto-loads
> let session = LanguageModelSession(model: model)
> // ... generate ...
> model.unload()
> ```

Four things to take from that.

**`variant:` is the most consequential parameter in this guide.** It selects the inference engine, and
the engine determines whether you get `@Generable` at all (§5). The documented values are
`"coreai-sequential"` and `"ane"`; the auto-detected set also includes `"coreai-pipelined"` and
`"static-shape"`. `nil` means "auto-detect from model structure", which means **you do not know which
engine you got unless you asked for one**.

> ✅ **VERIFIED (repo source, `CoreAILanguageModel.swift:12-32`, Apple's own doc comment)** —
> *"## Engine Selection — The engine type is determined by `EngineFactory` based on model structure:
> **Pipelined**: GPU-accelerated with pipeline-depth-matched buffering (fastest for GPU models);
> **Sequential**: CPU-based synchronous execution (fallback); **Static-shape**: Neural Engine
> optimized for chunked static models."*

**`mode:` defaults to `.lazy`,** so the constructor returns before the engine is loaded and `respond`
auto-loads on first use. That is the right default for app launch and the wrong one for a
latency-sensitive first interaction — call `load()` yourself at a moment the user is not waiting.

**`estimatedSizeOnDiskBytes` is available before you load,** which makes it the natural thing to
surface in a "download this model?" UI.

**`unload()` is explicit and non-async.** Like MLX, Core AI holds resources in a process-wide
registry (`ModelResources.shared(for:)`, keyed by the Hashable `Configuration`, values in a
`WeakBox`), so releasing the last model reference releases the engine — but if you hold the model,
you hold the weights.

### 4.3 Capabilities are detected, not declared

This is the biggest behavioural difference from MLX, and it is a good design: you cannot lie about
your bundle, because you are not asked.

> ✅ **VERIFIED (repo source)** — `CoreAILanguageModel` computes capabilities at init:
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
>
> and derives the three flags from the bundle:
>
> | Flag | How it is decided |
> |---|---|
> | `supportsReasoning` | the tokenizer has `<think>` **or** `<\|reasoning_start\|>` |
> | `supportsToolCalling` | `detectToolCallMarkers(using:) != nil` — first of `<tool_call>`, `<function_calls>`, else the Mistral special case `[TOOL_CALLS]` |
> | `isGuidedGenerationSupported` | the loaded engine's **`supportsLogits`** if known, else `variant != "coreai-pipelined"` |

That third row is §5 in one line.

> ✅ **VERIFIED — the unlabelled `LanguageModelCapabilities` initializer is the current spelling.**
> Commit `5ed9981` ("Move away from deprecated FM API (#123)", 2026-07-23) changed
> `LanguageModelCapabilities(capabilities: caps)` → `LanguageModelCapabilities(caps)` in exactly two
> files. The **labelled form still compiles** (test mocks in `foundation-models-utilities` use it),
> but it is deprecated. If you see `init(capabilities:)` in a blog post, that post predates
> 2026-07-23.

### 4.4 What the Foundation Models path does not expose

Going through `LanguageModelSession` is a narrowing. Some of Core AI's knobs are simply not reachable
from `GenerationOptions`.

> ✅ **VERIFIED (repo source)** — inside `CoreAIExecutor.respond`:
>
> - **Only `temperature` is honoured.** `makeSamplingConfig` returns
>   `SamplingConfiguration(temperature:)` when it is set, else the model's base config (`.greedy`).
>   **top-K, top-P and min-P are not reachable through the FM path** even though the underlying
>   sampler supports them.
> - **The default token budget is architecture-dependent:**
>   `maxTokens = request.generationOptions.maximumResponseTokens ?? (model.supportsReasoning ? 2048 : 512)`.
>   A reasoning model silently gets 4× the budget of a non-reasoning one when you do not set the
>   option — which is sensible, and will still surprise you when you compare two models' latency.
> - **Prior `.reasoning` transcript entries are skipped when re-templating**, with the comment
>   *"Don't echo the model's prior reasoning back into the prompt."* Your transcript keeps them; the
>   model does not see them again.
> - The request surface actually read is `request.transcript`, `request.enabledToolDefinitions`,
>   `request.schema`, and `request.generationOptions`. `contextOptions` is not consumed here either.

Two more consumer-visible notes from the same source, both useful:

> ✅ **VERIFIED (repo source, `CoreAILanguageModel.swift:309-310`, verbatim)** — *"FoundationModels
> now threads entry identity itself based on event ordering — we no longer mint an entryID and pass
> it down."* This is a 2026 framework change, and it is why you may see older provider code minting
> UUIDs that current code does not.

> ✅ **VERIFIED (`:487-492`, verbatim)** — *"Reasoning is a sibling of response/tool-calls in the new
> API (not nested under response) because at parse time we don't yet know whether the model will
> follow the thought block with a response or a tool call."* If you are walking a transcript, reasoning
> is its own entry kind, not a field on the response.

### 4.5 Where the bundle comes from

This guide does not cover producing one. That is four whole parts:

- **[Part 7 — Core AI: the Swift runtime](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/README.md)** — `AIModel`,
  `InferenceFunction`, `NDArray`, states, and the runtime that `CoreAILanguageModel` sits on top of.
- **[Part 8 — converting from PyTorch](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/README.md)** — `coreai-torch`,
  `torch.export`, decomposition tables, numeric parity testing.
- **[Part 9 — compression and numeric formats](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md)** —
  palettisation and quantisation, and why int4 is a cliff rather than a slope.
- **[Part 10 — hardware authoring, debugging, LLM deployment](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-10-coreai-hardware-authoring-debugging/README.md)** —
  specialisation, `coreai-build compile`, `.aimodelc`, and the device-class matrix.

Two things from those parts that change *consumer* decisions and are therefore worth stating here:

> ⚠️ **Specialisation is not free and should not happen in a user-interactive flow.** A shipped
> `.aimodel` is a portable, device-agnostic representation; the OS **specialises** it for the specific
> device and OS version before it can run, and Apple's own guidance is quoted as: *"This process can
> take a significant amount of time for very large models… avoid having model specialization occur
> within user-interactive flows."* Your `CoreAILanguageModel(resourcesAt:)` call is where that bill
> lands.

> ⚠️ **Community-measured, device-verified: 4B-class models do not specialise on device.** On
> **FastContext-1.0-4B (Qwen3-4B), iPhone 17 Pro / iOS 27**, the on-device GPU specialisation path
> *"exhausts the device's scratch disk mid-compile → `LLVM ERROR: No space left on device"*, and the
> ANE bundle static-loads (31 ANE regions, ~518 s cold) but dies at warm-up inference with
> `ANECompilerService Code=4097`. The only working path was an **AOT-compiled GPU `.aimodelc`**
> (`--preferred-compute gpu --architecture h18p`). **Community-measured** (john-rocky,
> `coreai-model-zoo`), not an Apple figure. If you are planning to ship a 4B Core AI model to iPhone,
> read Part 10 before you plan anything else.

---

## 5. ⚠️ The logits constraint: why the fastest backend loses `@Generable`

This section exists because the trade it describes is invisible in Apple's material, is easy to
discover only after you have committed, and **should change which backend you pick** rather than
merely informing how you configure it.

### 5.1 The mechanism

`@Generable` is not prompt engineering. The framework does not ask the model nicely to emit JSON and
hope. It constrains **decoding**: at each generation step, the schema is compiled into a grammar, and
tokens the grammar forbids are masked out of the distribution before a token is sampled. That is why
`@Generable` output is structurally valid rather than usually-valid.

Masking a distribution requires having the distribution. It requires **logits**.

So the question "does this backend support guided generation?" reduces to a much more concrete
engineering question: **does this engine hand its per-step logits back to the host, or does it sample
internally and hand back a token id?**

You can see the reduction directly in Core AI's own types:

> ✅ **VERIFIED (repo source)** — `apple/coreai-models`,
> `swift/Sources/CoreAILanguageModels/InferenceEngines/InferenceEngine.swift`:
>
> ```swift
> public typealias LogitsScalarType = Float16      // Float on macOS x86_64
>
> public struct InferenceOutput: Sendable {
>     public let tokenId: Int32
>     public let logits: [LogitsScalarType]?       // only when InferenceOptions.includeLogits
> }
>
> public struct InferenceOptions: Sendable {
>     public var maxTokens: Int?
>     public var includeLogits: Bool
>     public var forcedContinuation: [Int32]?
>     public init(maxTokens: Int? = nil, includeLogits: Bool = false, forcedContinuation: [Int32]? = nil)
> }
> ```
>
> `logits` is **Optional**, and the option that populates it is opt-in. An engine is free to return
> `nil` there — and one does, always.

### 5.2 What the fast engine does

Core AI's **GPU-pipelined** engine — the one whose whole design point is throughput, the one
`EngineFactory` auto-selects for GPU-friendly model structures, the one every published Core AI
throughput number in this corpus was measured on — **samples on the GPU**. The token id comes back;
the distribution never leaves the device pipeline. There is nothing to mask.

> ⚠️ **Community-measured finding, verified against the 27.0 beta** (john-rocky, `coreai-model-zoo`,
> update dated **2026-06-11**), verbatim: *"with the pipelined-engine patch stack, the non-standard
> bundles (hybrid Qwen3.5, SSM Granite/LFM) **DO** run behind `LanguageModelSession` too; note
> **guided generation requires engine logits, which GPU-pipelined bundles don't expose**."*
>
> Cross-checked in the same fork against **`InferenceEngine.supportsLogits`**: the default is
> **`false`**, overridden **`true`** by the **sequential** and **static-shape** engines. That property
> is exactly what `CoreAILanguageModel` reads to decide `isGuidedGenerationSupported` (§4.3), with the
> fallback `variant != "coreai-pipelined"` when the engine is not yet loaded.
>
> **Attribution:** this is a community audit against a beta, corroborated by Apple's own capability-
> detection code but **not stated by Apple anywhere**. Treat the mechanism as established and the
> per-bundle specifics as needing your own verification.

### 5.3 What a correct provider does about it — approximate or throw

Session 339 gives providers a rule for exactly this situation:

> ✅ **VERIFIED (WWDC26 session 339:143–156, verbatim)** — *"**Sometimes your model can't do exactly
> what the developer asked. When that happens, your executor has two choices: approximate or throw.**
> **Be flexible where you can, and honor the developer's intent.** But sometimes there's no honest
> approximation. **If a developer sets a token limit, but also specifies a schema with required
> fields, there might not be a way to satisfy both. So you throw.**"*

There is no honest approximation of a schema. So a correct provider throws, and here is one doing it:

> ✅ **VERIFIED (repo source)** — `john-rocky/coreai-model-zoo`,
> `swift/Sources/ZooFMProvider/ZooExecutor.swift:119-128`:
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

From your side of the API, that is what you will see: a **`LanguageModelError.unsupportedCapability`
whose `capability` is `.guidedGeneration`**, thrown on any `respond(to:generating:)`. It is a good
error. It is also not one you can work around at the call site.

### 5.4 The consequence, stated plainly

> **An app that brings its own model loses Apple's flagship structured-generation feature exactly
> when it selects the fastest backend.**

That inverts the marketing story, in which Apple's runtime is the one with first-class framework
integration and MLX is the research option. On this specific axis, the ranking is:

| Backend | Logits available to the host? | `@Generable` |
|---|---|---|
| `SystemLanguageModel` / `PrivateCloudComputeLanguageModel` | n/a — Apple's problem | ✅ yes, always |
| Core AI, **sequential** engine | ✅ `supportsLogits == true` | ✅ yes |
| Core AI, **static-shape** (ANE) engine | ✅ `supportsLogits == true` | ✅ yes |
| Core AI, **GPU-pipelined** engine | ❌ samples on-GPU | ❌ **no** |
| `MLXLanguageModel` | ✅ logits are just an array | ✅ yes — and `MLXGuidedGeneration` ships for it |
| `ChatCompletionsLanguageModel` | ❌ — but irrelevant | ⚠️ **delegated to the server** (§2.5) |

The last two rows deserve a sentence each.

**MLX gets this for free because of what it is.** MLX is array code; the logits are a variable. The
thing Core AI's pipelined engine structurally cannot do, MLX does by default — which is why
`MLXLanguageModel` can declare `.guidedGeneration` and mean it, and why `mlx-swift-lm` ships an entire
`MLXGuidedGeneration` library ("Grammar-constrained generation (JSON Schema or EBNF) for any MLX
model") built on a vendored xgrammar. **Community-measured framing** from the same audit: *"MLX
exposes logits trivially → structured generation, logprobs tooling, and sampler experiments are
easier on MLX."*

**For a server backend the question moves, it does not disappear.** With
`ChatCompletionsLanguageModel` the constraining happens on the far side of an HTTP connection, in
whatever engine the server runs, under whatever `response_format` semantics it implements. You are
not choosing an engine; you are **trusting a protocol claim**. That is why §2.5 is emphatic about the
`supportsGuidedGeneration:` flag: it is the only place in your code where that trust is written down.

One incidental piece of evidence that the whole industry has converged on the same tool, which is
worth knowing when you compare backends: **Core AI ships its own copy of xgrammar**, and MLX had to
rename its vendored copy's C++ namespaces to avoid colliding with it.

> ✅ **VERIFIED (repo source)** — `mlx-swift-lm`'s `Package.swift:203-228` defines
> `.define("xgrammar", to: "mlx_xgrammar")` with the comment: *"Rename the vendored C++ namespaces at
> compile time so this target's symbols cannot collide with another xgrammar in the same binary
> (e.g. **CoreAI's prebuilt copy**)."* Independently, `apple/coreai-models` depends on
> `github.com/mlc-ai/xgrammar` (branch `main`) and builds a `CXGrammar` bridge target with
> `.define("CXGRAMMAR_IMPORT")`.

### 5.5 What to do about it

Four options, in the order you should consider them.

**1. Use the sequential Core AI variant and pay whatever it costs.** `variant: "coreai-sequential"`
is a one-parameter change and it restores `@Generable`:

```swift prelude:guide-context
let model = try await CoreAILanguageModel(
    resourcesAt: bundleURL,
    variant: "coreai-sequential")     // restores logits → restores @Generable
```

> 🔴 **GAP — how much slower the sequential engine actually is.** Nobody in our corpus has published a
> controlled sequential-versus-pipelined measurement **on the same weights**. The 3.5× figure that
> circulates (qwen3.5, 58.5 → 204 tok/s, M4 Max) compares **pipelined against a hand-rolled per-token
> `fn.run()` loop**, not against the sequential engine, and quoting it as the price of guided
> generation would be wrong. **Resolution:** run `llm-benchmark` (the `Tools/benchmark` executable in
> `apple/coreai-models`, which is actually named `llm-benchmark`) against one bundle twice, with
> `--inference-engine-variant coreai-sequential` and `coreai-pipelined`. **Until someone does, price
> the sequential path as "unknown and possibly large", not as a small tax** — and measure it on your
> bundle before you commit.

Note the second-order consequence, which is easy to miss: **every Core AI throughput number in
circulation was measured on the pipelined engine** — i.e. on the configuration that does *not* have
`@Generable`. If you need guided generation, none of those numbers describe your app.

**2. Use MLX instead.** You get logits, guided generation, tool-call format parsers for ten dialects,
and no conversion step — at the cost of GPU-only execution and a larger binary. For a Mac app or a
power-user feature this is usually the right answer.

**3. Parse free text yourself.** Keep the pipelined engine, drop `@Generable`, and write a tolerant
parser with retries. This is a real engineering choice and it is worse than it sounds: you are
reintroducing exactly the class of failure — plausible, well-formed, wrong — that constrained
decoding exists to eliminate. Budget for validation and a retry policy, not just a `JSONDecoder`.

**4. Split the feature.** Use the fast backend for prose (summaries, rewrites, chat) and a
guided-generation-capable one for the structured step (extraction, classification, tool arguments).
Because both sit behind `LanguageModelSession`, this is genuinely cheap — see §9.

Whichever you choose, decide it **before** you convert a model, not after. Cross-link:
[Part 1 §3.3, §3.4 and the decision table in §5](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/references/01-apple-ai-stack-2026-map.md),
which carries this constraint as a column rather than a footnote.

---

## 6. Capabilities, and the errors the framework throws for you

§1 stated the rule; this section is what it looks like in practice, because the same rule protects you
in two directions and it is worth knowing which one you are relying on.

### 6.1 The four capabilities

> ✅ **VERIFIED** — `.toolCalling`, `.vision`, `.reasoning`, `.guidedGeneration`, from Apple's provider
> skill (`SKILL.md:314-319`) and independently from all three conformances in the corpus. The type is
> `LanguageModelCapabilities`, membership is tested with `.contains(_:)`, and the nested case type is
> `LanguageModelCapabilities.Capability`.

How each backend populates them:

| Backend | How capabilities are set |
|---|---|
| `ChatCompletionsLanguageModel` | `[.vision, .toolCalling, .reasoning]` **unconditionally**, plus `.guidedGeneration` iff `supportsGuidedGeneration` ✅ `:88-93` |
| `MLXLanguageModel` | **exactly the array you pass** to `capabilities:` ✅ `:520`, `:565` |
| `CoreAILanguageModel` | **detected from the bundle** — tokenizer markers and `supportsLogits` ✅ §4.3 |

Three different philosophies, and the middle one puts the burden on you.

### 6.2 Under-declaring is the safe failure

> ✅ **VERIFIED (Apple's own guidance, `SKILL.md:35`)** — *"If a developer asks for a capability you
> didn't declare (e.g. tool calling on a model that doesn't support it), the framework throws
> `unsupportedCapability` for you — you don't write defensive code for that."*

The error is typed and carries the offending capability:

> ✅ **VERIFIED (real throw sites, three independent conformances)** —
> `LanguageModelError.unsupportedCapability(_:)` with payload
> `LanguageModelError.UnsupportedCapability(capability:debugDescription:)`, where `capability` is a
> `LanguageModelCapabilities.Capability`. Thrown at `MLXLanguageModel.swift:960-965` and `:1065-1070`,
> `ZooExecutor.swift:121-127`, and in `apple/coreai-models` as
> `LanguageModelError.unsupportedCapability(.init(capability: .guidedGeneration, debugDescription: "…"))`.

Which makes this a usable runtime probe:

```swift compile:27
import FoundationModels

@available(iOS 27.0, macOS 27.0, *)
func canDoGuidedGeneration(_ model: some LanguageModel) -> Bool {
    model.capabilities.contains(.guidedGeneration)
}
```

`capabilities` is a plain property on the model, so **you can ask before you generate** rather than
catching afterwards. That is the basis of the swappable-backend pattern in §9.

### 6.3 Over-declaring is the unsafe one

There is no framework protection against a model that claims more than it can do — by construction,
the framework believes the declaration. The three ways this reaches you:

1. **`supportsGuidedGeneration: true` against a lenient server** — §2.5. The failure is a parse error
   at best and invented data at worst.
2. **`capabilities: [.toolCalling]` on an MLX checkpoint whose dialect nothing parses** — §3.6. The
   model emits tool-call text, the parser does not recognise it, and the text lands in the response as
   prose. No error.
3. **`.reasoning` on a model with no thinking behaviour** — you get empty `.reasoning` transcript
   entries and a `reasoningLevel` that changes nothing.

All three share a shape: **the capability system is a contract, and only one party is checked.** When
you are the one filling in the array, you are the unchecked party.

### 6.4 The rest of the error vocabulary

For completeness, since a BYO-model app will meet these:

> ✅ **VERIFIED (Apple's provider skill, `SKILL.md:549-557`, nine cases with payload fields)**:
>
> | Case | Payload-specific fields |
> |---|---|
> | `.contextSizeExceeded(ContextSizeExceeded)` | `contextSize: Int`, `tokenCount: Int` |
> | `.rateLimited(RateLimited)` | `resetDate: Date?` |
> | `.guardrailViolation(GuardrailViolation)` | — |
> | `.refusal(Refusal)` | `explanation: String` (**required** by the public initializer as of beta 3) |
> | `.unsupportedCapability(UnsupportedCapability)` | `capability: LanguageModelCapabilities.Capability` |
> | `.unsupportedTranscriptContent(UnsupportedTranscriptContent)` | `unsupportedContent: [Transcript.Entry]` |
> | `.unsupportedGenerationGuide(UnsupportedGenerationGuide)` | `schemaName: String?` |
> | `.unsupportedLanguageOrLocale(UnsupportedLanguageOrLocale)` | `languageCode: Locale.LanguageCode` |
> | `.timeout(Timeout)` | — |
>
> Every payload struct also exposes `debugDescription: String` and `metadata: [String: any Sendable]`.

⚠️ But note what §2.7 established: **a backend is not obliged to use any of them**, and
`ChatCompletionsLanguageModel` mostly does not. The vocabulary is available, not enforced. Write your
portable arm *and* your backend-specific arm.

One last piece of provider judgement, quoted because it explains why some errors you would expect to
be typed are not:

> ✅ **VERIFIED (repo source, `MLXLanguageModel.swift:855-864`)** — MLX deliberately does **not** map
> its `constraintCompilationFailed` onto `unsupportedGenerationGuide`: *"its origin is ambiguous… and
> **claiming user-fault when the cause is actually our infrastructure misleads developers who
> pattern-match on typed errors.**"* A generic error is sometimes the honest one. Do not assume an
> untyped error means the provider was lazy.

---

## 7. The privacy obligation

Session 339's final substantive point is addressed to **both** sides of the ecosystem, and the
consumer half of it is the half people skip.

> ✅ **VERIFIED (WWDC26 session 339:204–205, verbatim)** — *"There's one more thing to keep in mind:
> **whether you're choosing a package or shipping one, make sure everyone in the chain understands the
> privacy implications of the model behind it. On-device and cloud-based models have very different
> privacy characteristics, and your users deserve to know which they're getting.**"*

"Whether you're **choosing** a package" — that is you.

Here is why it is a real obligation and not a compliance box. The whole architectural achievement of
this API is that **the call site does not change**. `session.respond(to: userText)` is byte-identical
whether the prompt stays inside the Secure Enclave's blast radius, goes to a Mac on the same Wi-Fi, or
goes to a third-party API in another jurisdiction. The property that mattered most to your user is the
one property the code no longer expresses.

The four backends have genuinely different characteristics, and the differences are not subtle:

| Backend | Where the prompt goes | What the user should be told |
|---|---|---|
| `SystemLanguageModel` | never leaves the device | nothing beyond normal app disclosure |
| `PrivateCloudComputeLanguageModel` | Apple's PCC, *"designed with **end-to-end privacy** in mind"* (319:15–17); requests are counted against the user's **iCloud account** (319:70) | that it is a cloud model, and that usage is metered against their account |
| `CoreAILanguageModel` / `MLXLanguageModel` | never leaves the device | nothing beyond normal app disclosure — but see the download note below |
| `ChatCompletionsLanguageModel` | **wherever your URL points**, under that operator's retention and training policy | the operator's identity, and whether prompt content may be retained or trained on |

Practical guidance that follows from that table:

**Name the operator, not the technology.** "Uses AI" is not disclosure. If the URL is a vendor's
endpoint, the user is sending their text to that vendor, and the vendor's name is the load-bearing
fact. `ChatCompletionsLanguageModel`'s `name:` parameter is a wire model id, not a user-facing
string — do not reuse it in UI and assume you have disclosed anything.

**A backend swap is a privacy change and needs to be treated like one.** Because the swap is one line,
it can pass code review as a configuration tweak. It is not. If you add a fallback that routes to a
remote endpoint when the local model is unavailable, you have changed where user text goes on a code
path most users will never notice.

**On-device does not mean nothing leaves the device.** Both local backends can *fetch weights*. MLX's
Hugging Face path downloads from the Hub — which tells the Hub which model your user chose and, by
timing, roughly when. A Core AI bundle delivered by Background Assets tells your CDN the same. That is
not prompt content and it is a much smaller disclosure, but it is not zero, and "fully offline" should
mean weights already on disk.

**If you offer a choice, surface it.** The cleanest pattern in the corpus comes from Apple's own
2026 samples: the backend is stored as a **single stored property on the app's model object**, which
means the current backend is a first-class, observable piece of app state you can render. A one-line
label in a settings screen — *"Answers are generated on this device"* versus *"Answers are generated
by ⟨operator⟩"* — is proportionate, and it is the thing session 339 is asking for.

> ⚠️ **The related credential rule, if your endpoint needs auth.** Session 339's packaging advice to
> providers applies to you when you are the one holding a key: *"**If your initializer takes an API
> key as a string, developers will be tempted to take the path of least resistance.**"* (339:157–167).
> `ChatCompletionsLanguageModel` takes `additionalHeaders: [String: String]`, which is exactly such a
> temptation. **Do not ship an app with a bearer token in `additionalHeaders` compiled into the
> binary** — it is extractable, and it is your bill. Apple's stated recommendations are a **token
> provider or sign-in flow**, tokens persisted in the **Keychain**, and **App Attest** for device
> attestation on any cloud-backed model.

---

## 8. Choosing, concretely

Part 1's decision table is the general one, keyed on product constraints. This is the narrower,
consumer-side version: you have already decided to bring a model, and you are choosing *which of these
three paths* to spend the next week on.

### 8.1 Start here

**If you are still prototyping and want an answer today: `ChatCompletionsLanguageModel` against a
local server.** Nothing else in this guide gets you from "I want to try Qwen3-4B with my real
`@Generable` types and my real tools" to running code in an afternoon. There is no conversion step, no
27-SDK gate, no macro import list. You will hit the URL defect (§2.4) — put a literal `v1` in the base
URL and move on. Reach for a different path when you have learned what you needed to learn.

**If you are shipping to iPhone and battery matters: Core AI**, and read Part 10 first about
specialisation and AOT compilation, because that is where the surprises are.

**If you are shipping to Mac, or you need a model that landed last month: MLX.** No conversion step
means new-architecture turnaround in days rather than a porting project.

**If your feature needs `@Generable` and you were about to pick pipelined Core AI: re-read §5 first.**
That is the choice this guide exists to stop you making by accident.

### 8.2 The comparison that actually decides it

| | `ChatCompletionsLanguageModel` | `MLXLanguageModel` | `CoreAILanguageModel` |
|---|---|---|---|
| **Ships in** | `apple/foundation-models-utilities` (SwiftPM) | `ml-explore/mlx-swift-lm` (SwiftPM) | `apple/coreai-models` (SwiftPM) |
| **Platform floor** | iOS/macOS/visionOS/**watchOS** 27.0 | iOS/macOS/visionOS 27.0 **+ 27.0 SDK** | **iOS/macOS only**, 27.0 |
| **What you bring** | a URL | a model id (or a directory) | a converted bundle |
| **Runs where** | your server | device GPU | device GPU / ANE / CPU |
| **Works offline** | ❌ | ✅ (after weights are on disk) | ✅ |
| **`@Generable`** | ⚠️ delegated to the server — see §2.5 | ✅ | ✅ **except on the pipelined engine** — §5 |
| **Capabilities** | `.vision/.toolCalling/.reasoning` claimed unconditionally | **you declare them** | **detected from the bundle** |
| **Streaming** | ✅ on Darwin; ❌ incremental on Linux | ✅ | ✅ |
| **Token usage reported** | ✅ (`stream_options.include_usage` always on) | ⚠️ **may be absent or zero** on this SDK — §3.9 | ✅ |
| **Seeded sampling** | ❌ throws | ✅ (inert at `temperature == 0`) | ⚠️ only `temperature` reaches it |
| **Known live defect** | the `v1` path bug — §2.4 | `updateUsage` removed — §3.9 | pipelined ⇒ no guided generation — §5 |
| **Stability** | *"emerging and experimental"*, out-of-band with the OS | 3.x major, breaking changes recent | tracks the OS release |

### 8.3 Three things that are true of all three

**They are all SwiftPM packages, not system frameworks.** None of these three types is in the OS. The
`LanguageModel` protocol is; the conformances are code you compile into your app, with your app's
binary size, your app's launch cost and your app's bug surface. For Core AI specifically, a community
audit puts a finer point on it:

> ⚠️ **Community-audited** (john-rocky, `coreai-model-zoo`, 2026-07-24): *"Only the **graph compiler +
> executor** (`CoreAI.framework`) is OS-resident. The LLM runtime — `EngineFactory`, the
> `coreai-pipelined` engine, `LanguageBundle`, on-GPU sampling, KV growth — is Swift code from
> `coreai-models` that **you compile into the app**."* The evidence offered is that the author patches
> it, which you cannot do to an OS framework. So "nothing to bundle" is half true: the compiler is
> free, the LLM engine is app code.

**Prewarm is best-effort everywhere.** Session 339: *"**But `prewarm` isn't guaranteed to run.**"*
(339:75–82). Every conformance in the corpus implements it as a synchronous, non-throwing function
that fires a detached `Task`, so a prewarm failure is logged rather than surfaced. Do not design a UX
that depends on it having happened.

**The executor cache is per-session and keyed on `Configuration`.** Constructing the model value is
cheap; constructing the executor is not. Session 339: *"**That split is what keeps your Model trivial
to construct.**"* (339:67–71). Build model values freely; be deliberate about what goes in the
configuration, because that is the cache key (§1, §2.8, §3.9).

### 8.4 The models that quietly cannot do multi-turn cheaply

One model-selection consequence that cuts across all three paths and belongs in a choosing section,
because it is invisible until turn two.

> ⚠️ **Community-measured** (john-rocky, `coreai-model-zoo`): prefix KV-cache reuse is worth
> **turn-2 TTFT 23.28 s → 0.230 s (101×)** at 4k context with byte-identical greedy output, and 15.2×
> at 357 tokens (qwen3-0.6b, Mac). The mechanism is a single integer assignment — nothing is cleared,
> `processedTokenCount` rewinds — and it is free because attention is causal.
>
> **But `trimKVCache` returns `-1` (unsupported) whenever `extraStates` is non-empty.** SSM /
> GatedDeltaNet state is a *running scan*, not positionally addressed, so it cannot be rewound.
> **Linear-attention and hybrid models — Qwen3.5, Qwen3.6, LFM2.5, Granite 4 — forfeit prefix caching
> entirely and must re-prefill every turn.** The measured cost of not having it: *"turn 1 = 0.41 s,
> turn 2 = 2.8 s"* on a 0.8B with a 3-entry history.
>
> If your feature is a **conversation**, that is a model-selection criterion, not a tuning tip. If it
> is one-shot extraction, it does not matter at all.

---

## 9. Making the backend swappable in real app code

The whole value proposition is *"Everything downstream stays the same"* `[241:L50]`. Here is how to
collect that value without scattering `#if` blocks through your app.

### 9.1 Store the model as one property

> ✅ **VERIFIED (Apple sample code, iOS 27)** — both 2026 iOS 27 samples store the backend as a
> **single stored property** on the app's model object, and swap it there rather than at call sites.
> This is the strongest evidence in the corpus that "swapping the backend is one line" is how Apple's
> own engineers write it, not marketing.

```swift compile:27
import FoundationModels
import Observation

@Observable
@available(iOS 27.0, macOS 27.0, *)
final class Assistant {
    /// The one place the backend is chosen. Everything below is backend-agnostic.
    private(set) var model: any LanguageModel = SystemLanguageModel()

    /// Surfaced in UI so the user can see which backend is answering — §7.
    private(set) var backendDescription: String = "On this device"

    func use(_ newModel: any LanguageModel, describedAs description: String) {
        model = newModel
        backendDescription = description
    }

    func answer(_ question: String) async throws -> String {
        let session = LanguageModelSession(model: model)
        return try await session.respond(to: question).content
    }
}
```

`any LanguageModel` is the erasure that makes this work. It became framework API at beta 3:

> ✅ **VERIFIED (repo source, commit `376ca60`'s own changelog)** — *"Removed `.model(any LanguageModel)`
> modifier since it's **now included in the Foundation Models framework**."* The deleted
> hand-rolled `AnyLanguageModel` type-eraser is still readable at `a047a50` and is instructive: it had
> to `unsafeBitCast` a metatype to `UnsafeRawPointer` purely to obtain `Hashable`, because
> `Configuration: Hashable` is so load-bearing to the executor cache.

### 9.2 Branch on capabilities, not on type

The wrong pattern is `if model is CoreAILanguageModel`. The right one is to ask what the model can do,
because that is the question you actually have and it survives a backend swap:

```swift prelude:guide-context
@available(iOS 27.0, macOS 27.0, *)
extension Assistant {
    /// Extract structured data if the backend can guarantee the shape;
    /// otherwise fall back to prose and say so. See §5 for why this is necessary.
    func extractContact(from text: String) async throws -> ContactDraft? {
        guard model.capabilities.contains(.guidedGeneration) else {
            // Do NOT silently parse free text as if it were schema-conformant.
            return nil
        }
        let session = LanguageModelSession(model: model)
        let response = try await session.respond(
            to: "Extract the contact details from:\n\(text)",
            generating: ContactDraft.self)
        return response.content
    }
}

@Generable
struct ContactDraft {
    @Guide(description: "Full name as written")
    var name: String
    @Guide(description: "Email address, or an empty string if none is present")
    var email: String
}
```

Note what the `guard` buys you: on a pipelined Core AI bundle this returns `nil` **before** issuing a
request, instead of throwing `unsupportedCapability` after. Both are correct; the guard is cheaper and
gives you a place to put the fallback.

### 9.3 The split-backend pattern

§5's fourth option, written out. Prose from the fast backend, structure from the capable one, both
behind the same session API:

```swift prelude:guide-context
@available(iOS 27.0, macOS 27.0, *)
struct SplitBackendAssistant {
    /// Fast, on-device, no guided generation (e.g. a pipelined Core AI bundle).
    let proseModel: any LanguageModel
    /// Slower or remote, but guarantees schema conformance.
    let structuredModel: any LanguageModel

    func summarise(_ document: String) async throws -> String {
        let session = LanguageModelSession(model: proseModel)
        return try await session.respond(to: "Summarise:\n\(document)").content
    }

    func tag(_ document: String) async throws -> DocumentTags {
        precondition(structuredModel.capabilities.contains(.guidedGeneration))
        let session = LanguageModelSession(model: structuredModel)
        return try await session.respond(
            to: "Tag this document:\n\(document)",
            generating: DocumentTags.self).content
    }
}
```

Two separate sessions means two separate transcripts, so this is a good pattern for *independent*
operations and a bad one for a conversation you want to continue across both. For that, see §9.4.

### 9.4 Switching backends inside one conversation

A `DynamicProfile` can carry a `.model(_:)` modifier, which is how you change backends **while keeping
the transcript**.

> ✅ **VERIFIED (Apple sample code, iOS 27 — supersedes earlier reconstructions)** — the body type is
> spelled with the **short name**, `var body: some DynamicProfile`, and the model is applied as a
> **modifier**, `Profile { … }.model(x)` — *not* an initialiser label `Profile(model:)`. Both of those
> were written the other way round in earlier drafts of this series and in material still in
> circulation.

```swift prelude:guide-context
import FoundationModels

@available(iOS 27.0, macOS 27.0, *)
struct ResearchProfile: DynamicProfile {
    var needsStructure: Bool
    var localModel: any LanguageModel
    var capableModel: any LanguageModel

    var body: some DynamicProfile {
        if needsStructure {
            Profile {
                Instructions { "Answer strictly in the requested schema." }
            }
            .model(capableModel)
        } else {
            Profile {
                Instructions { "Answer conversationally and briefly." }
            }
            .model(localModel)
        }
    }
}

let session = LanguageModelSession(profile: ResearchProfile(
    needsStructure: state.needsStructure,
    localModel: fastModel,
    capableModel: guidedModel))
```

> ✅ **VERIFIED (WWDC26 session 241, `[241:L97-98]`, verbatim)** — *"**The important thing to
> understand is that a `DynamicProfile` resolves to a single active `Profile` at any given time. You
> use conditionals to pick which `Profile` is active.**"* Flipping `needsStructure` **is** the
> backend swap; the transcript is untouched.

⚠️ But the transcript that survives the swap is now being fed to a *different model*, and every
provider re-templates the whole transcript on every call — session 339: *"**Your executor receives the
full transcript on every call to `respond`.**"* (339:131–142). A transcript built by one model's chat
template is being re-rendered by another's. That works, because the transcript is structured entries
rather than a rendered string, but reasoning entries and tool-call dialects do not always survive the
round trip (§2.6, §4.4). **Test a mid-conversation swap before you ship one.**

Profiles, modifiers and the transcript-management story are Part 3's subject:
[Part 3 — Context, profiles, agentic sessions](../../part-03-context-profiles-agentic/README.md).

### 9.5 A compile-safe file layout

Bringing §3.2's gate together with everything else, this is the layout that survives a colleague
opening the project in Xcode 26:

```
Sources/MyApp/
  Assistant.swift            // @Observable, holds `any LanguageModel` — no backend imports
  Backends/
    SystemBackend.swift      // import FoundationModels only
    ServerBackend.swift      // import FoundationModelsUtilities
    MLXBackend.swift         // #if canImport(FoundationModels, _version: 2) … #endif
    CoreAIBackend.swift      // import CoreAILanguageModels
```

Only `MLXBackend.swift` needs the `#if canImport(FoundationModels, _version: 2)` wrapper, because only
MLX has the SDK gate. Everything else is `@available`. The point of the layout is that `Assistant.swift`
— the file the rest of your app talks to — imports nothing backend-specific and therefore compiles
everywhere.

---

## 10. Quick reference

### 10.1 The three initializers

```swift illustrative
// 1 — any OpenAI-compatible server.  package: apple/foundation-models-utilities
//     iOS/macOS/visionOS/watchOS 27.0
import FoundationModels
import FoundationModelsUtilities

ChatCompletionsLanguageModel(
    name: String,                                     // the WIRE model id — sent as "model"
    url: URL,                                         // MUST contain a literal `v1` component — §2.4
    additionalHeaders: [String: String] = [:],
    supportsGuidedGeneration: Bool = true,            // set false unless you have TESTED it — §2.5
    urlSessionConfiguration: URLSessionConfiguration? = nil)   // beta 3+

// 2 — Hugging Face via MLX.  package: ml-explore/mlx-swift-lm
//     iOS/macOS/visionOS 27.0 AND the 27.0 SDK
#if canImport(FoundationModels, _version: 2)
import FoundationModels
import MLXFoundationModels; import MLXHuggingFace; import MLXLMCommon
import MLXLLM                       // required — factory registration via NSClassFromString
import HuggingFace; import Tokenizers

#huggingFaceLanguageModel(
    configuration: LLMRegistry.gemma3_1B_qat_4bit,
    capabilities: [.guidedGeneration])              // load-bearing — §3.6

// or, explicitly:
MLXLanguageModel(
    configuration: ModelConfiguration(id: "mlx-community/Qwen2.5-3B-Instruct-4bit"),
    capabilities: [.guidedGeneration, .toolCalling],
    weightsLocation: { id in … },
    load: { configuration, progressHandler in
        try await loadModelContainer(
            from: #hubDownloader(), using: #huggingFaceTokenizerLoader(),
            configuration: configuration, progressHandler: progressHandler) })
#endif

// 3 — a Core AI bundle.  package: apple/coreai-models, product CoreAILM
//     iOS/macOS 27.0 only
import FoundationModels
import CoreAILanguageModels          // module is PLURAL, type is singular

try await CoreAILanguageModel(
    resourcesAt: url,
    mode: .lazy,                                    // or .eager
    variant: nil,                                   // "coreai-sequential" restores @Generable — §5
    kvCacheStrategy: .auto)

// …and in every case:
let session = LanguageModelSession(model: model)     // also (model:tools:instructions:)
```

### 10.2 Failure-mode cheat sheet

| Symptom | Cause | Section |
|---|---|---|
| 404 with `…/v2/v1/chat/completions` in the message | the hardcoded `v1` path defect | §2.4 |
| Connection refused to `localhost:80` | you copied the README's `http://localhost/v1:8000` | §2.3 |
| Stream completes, response is empty, no error | server emits `data:{…}` with no space after the colon | §2.6 |
| `@Generable` returns malformed or invented data | `supportsGuidedGeneration: true` on a lenient server | §2.5 |
| Text disappears from a turn that also called a tool | tool-call deltas suppress same-chunk content | §2.6 |
| "Cannot find `MLXLanguageModel` in scope" | building against the 26 SDK; the target compiled out | §3.2 |
| "Cannot find type …" pointing at a `#huggingFaceLanguageModel` line | missing an import the macro expansion needs | §3.4 |
| `ModelFactoryError.noModelFactoryAvailable` | `MLXLLM` / `MLXVLM` not linked | §3.3 |
| A VLM error for an LLM you were loading | VLM factory tried first; only the last error is kept | §3.3 |
| `response.usage` is zero or missing on MLX | `updateUsage` deliberately not sent on this SDK | §3.9 |
| Timeout change had no effect | executor cache key excludes the `URLSession` | §2.8 |
| Second model behaves like the first | MLX cache key is `modelID` alone | §3.9 |
| `unsupportedCapability(.guidedGeneration)` on every structured call | GPU-pipelined Core AI engine — no logits | §5 |
| Turn 2 is ~7× slower than turn 1 | hybrid/SSM model, no prefix KV reuse | §8.4 |
| `.randomTopK` or a seed throws | not supported by the chat-completions executor | §2.6 |
| SwiftPM resolves nothing for `foundation-models-utilities` | `from: "1.0.0"` excludes the only (prerelease) tags | §2.1 |

### 10.3 The five-minute sanity checklist for a new backend

1. Print `model.capabilities` and confirm it matches what you believe about the checkpoint.
2. Round-trip a two-turn conversation and check the second turn's latency (§8.4).
3. Round-trip one `@Generable` type with a deliberately prose-inviting prompt (§2.5).
4. Register one `Tool` and confirm the call actually parses (§3.6).
5. Read `response.usage` and confirm it is non-zero before you build anything on it (§3.9).
6. Trigger one deliberate error — a 401, a bad model id — and confirm your `catch` ladder catches it
   as the type you expected (§2.7).

---

## 11. Sources, and where they disagree

### 11.1 What each claim rests on

| Area | Strongest source |
|---|---|
| `ChatCompletionsLanguageModel` — every signature, the URL defect, wire mapping, SSE parsing | `apple/foundation-models-utilities` at commit `376ca60` (tag `1.0.0-beta3`, 2026-07-10), read file by file; the URL logic additionally **executed** against Swift 6.3.3 Foundation over 11 base-URL shapes |
| The `LanguageModel` / `LanguageModelExecutor` protocol pair, capabilities, `LanguageModelError` | Apple's own `skills/foundation-models-language-model-protocol/SKILL.md` shipped inside that package (815 lines), cross-checked against three independent conformances |
| `MLXLanguageModel`, `#huggingFaceLanguageModel`, the SDK gate | `ml-explore/mlx-swift-lm` at HEAD `3cbf928` (2026-07-24) |
| `CoreAILanguageModel` | `apple/coreai-models`, `CoreAILanguageModel.swift` read in full (777 lines) |
| Where `MLXFoundationModels` lives; the URL defect's acknowledgement | Apple Developer Forums threads **836264** and **838444**, both with accepted Apple-staff replies |
| The one-line-swap narrative, the privacy obligation, approximate-or-throw, prewarm | WWDC26 sessions **339**, **326**, **241**, **319** (transcripts) |
| The logits/guided-generation constraint; the 4B wall; prefix-cache economics | `john-rocky/coreai-model-zoo` — **community-measured against the 27.0 beta**, attributed as such everywhere it appears |
| `DynamicProfile` body spelling and the `.model(_:)` modifier | Apple's 2026 **sample-code projects** (iOS 27 / macOS 27) — the strongest evidence class in this corpus |

### 11.2 Where sources disagree, and how this guide ruled

**1. "Simply pass in a model ID" (session 339) vs. the shipping MLX initializer.**
The transcript says the framework handles the rest; the shipping selector is
`init(configuration:capabilities:configurationResolver:weightsLocation:load:)`. **Ruled for the
source.** The transcript is a fair description of the `#huggingFaceLanguageModel` *macro*, which
synthesises `weightsLocation:` and `load:` for you, and this guide says so explicitly rather than
repeating the one-liner (§3.4, §3.5).

**2. `MLXLanguageModel(modelID:)` is in circulation and is wrong.** Two community blog posts give the
initializer as `MLXLanguageModel(modelID: "mlx-community/my-model")`. No such initializer appears in
the repo. **Ruled for the source**; the label is `configuration:` and it takes a `ModelConfiguration`.

**3. Session 339's prescribed event order vs. what Apple's own adapter does.** The session prescribes
`updateMetadata` → `updateUsage` → text deltas (339:121–130). Apple's `CoreAILanguageModel` sends
usage **at the end**, and a community provider reports that an upfront `updateUsage` on a
tool-calling turn **materialises an empty `Response` transcript entry** on the 27.0 beta. This is a
provider-side concern (guide 03), but it is worth recording that **the session's advice and Apple's
own shipping adapter disagree**, and the adapter is the better guide.

**4. Whether Apple's Core AI adapter has a mis-bound `prewarm`.** A community provider note claims
*"Apple's own adapter has this today, which is why `session.prewarm()` does nothing for Core AI
models"* — the near-miss-signature trap where `prewarm(transcript:)` compiles but is never called as
the witness. **Ruled against that claim for the commit we read:** `CoreAILanguageModel.swift:269-271`
declares `public func prewarm(model: CoreAILanguageModel, transcript: Transcript)`, which matches the
requirement exactly. The community note is either stale or describes a different fork. The underlying
warning is still sound and still worth heeding — the protocol ships a default no-op, so a near-miss
signature compiles and is silently never called — it just does not apply to this file at this commit.

**5. `LanguageModelCapabilities(capabilities:)` vs `(_:)`.** Both exist and both compile. The labelled
form is **deprecated** as of `apple/coreai-models` commit `5ed9981` (2026-07-23). This guide uses the
unlabelled form and dates the change, because half the material in circulation predates it.

**6. `.greedy` sampling.** Apple's provider skill illustrates greedy as `temperature = 0`
(`SKILL.md:295`); the shipping `ChatCompletionsLanguageModel` sets **`top_p = 0`** (`:370`). **Ruled
for the source**, and flagged in §2.6, because it matters to anyone comparing determinism across
backends.

**7. `SkillActivations` conformances, the "5000 tokens" summarisation threshold, and SwiftPM traits in
the utilities package.** All three are documented in that repo's README or agent skill and all three
are **false at HEAD** — `RandomAccessCollection` was removed at beta 3, the token threshold is an
artifact of a deleted API and the current gate is an *entry count*, and the claimed
`#if ChatCompletions` / `#if Skills` / `#if History` traits **do not exist in `Package.swift` at all**.
None of those are this guide's subject — they belong to Part 3's utilities guide — but they are the
reason this guide cites *source files* rather than that package's documentation everywhere it can.

### 11.3 Open gaps carried by this guide

- **The `v1` path defect's fix status after 2026-07-27.** Acknowledged by Apple on 2026-07-18
  ("we're on it"); absent from the newest tag (2026-07-10). Check line 635 yourself. §2.4.
- **The type and default of `MLXLanguageModel`'s `configurationResolver:`.** Label attested, type
  never printed in any source we hold. Omit it. §3.5.
- **watchOS / tvOS support for `MLXLanguageModel`.** The availability attribute names only iOS, macOS
  and visionOS; whether that is deliberate is unrecorded. §3.2.
- **Whether `FoundationModels` exists on Linux, and whether `@Generable` works there.** Structurally
  supported, zero CI, and the Darwin-gated test suites are circumstantial evidence against guided
  generation. §2.9.
- **The real cost of Core AI's sequential engine versus the pipelined one.** No controlled measurement
  on the same weights exists in this corpus. Do not price it from the 3.5× figure in circulation,
  which measures something else. §5.5.
- **Whether the executor cache actually mis-reuses across `urlSessionConfiguration` differences.**
  Reasoned from the `Hashable` implementation plus Apple's stated caching rule; not observed. §2.8.
- **The Anthropic and Google `LanguageModel` packages.** Session 241 announces them —
  *"**Anthropic, and Google are both publishing Swift packages** to provide you with access to their
  latest and greatest models"* `[241:L48]` — but **names no package URLs, no module names and no
  types.** Everything in circulation about their spelling (`ClaudeModel`, `GeminiModel`, `.keychain`)
  is illustrative invention, not API. When they ship, they are §2's story with a different
  initializer: same session, same tools, same `@Generable`, and the same privacy obligation from §7.

---

*Part 4 · Reference 02. Next in this part: **guide 03**, authoring a `LanguageModel` conformance of
your own — the executor, the generation channel, transcript diffing, and the eleven pitfalls Apple
documents for provider authors.*
