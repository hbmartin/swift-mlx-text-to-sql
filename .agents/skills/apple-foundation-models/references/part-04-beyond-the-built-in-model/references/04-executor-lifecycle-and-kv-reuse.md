# Executor lifecycle, configuration identity, and preserving work across calls

**Part 4 · Beyond the built-in model · Reference 04**

**Version floor:** everything in this guide is **iOS 27.0 / iPadOS 27.0 / macOS 27.0 / visionOS 27.0 /
watchOS 27.0**. The `LanguageModel` and `LanguageModelExecutor` protocols, `Executor.Configuration`,
`prewarm(model:transcript:)`, `LanguageModelExecutorGenerationRequest` and the generation channel do
not exist before 27.0 — Apple's own `foundation-models-utilities` package declares exactly
`.macOS("27.0") .iOS("27.0") .visionOS("27.0") .watchOS("27.0")` and nothing lower
(✅ `Package.swift:19-22`), and MLX gates its whole adapter behind
`@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)` plus
`#if canImport(FoundationModels, _version: 2)`. **There is no back-deployment story here.** Contrast
`@Generable`, which is **26.0** — you can share a `@Generable` type with an app that runs on 26 and
still be unable to run your provider there. `Transcript` and `Tool` are also **26.0** (with watchOS
arriving at **27.0**), but the `.reasoning` entry case that your executor must handle is **27.0**.

⚠️ Two things in this guide are **not Apple APIs at all** and are labelled as such wherever they
appear: `trimKVCache(to:)` / `prefixReuseFeedsFullSequence` are a **community patch** to the Core AI
`InferenceEngine` protocol (a fork, not upstream), and `trimPromptCache(_:numTokens:)` is a shipping
**MLX Swift** function, not a Foundation Models one. Do not go looking for either in the
FoundationModels SDK.

---

## What this covers

The mechanics that decide whether your `LanguageModel` provider is fast or slow — and, more often
than anyone expects, whether it is *correct*.

- **The executor store.** Each `LanguageModelSession` holds one. Your `Configuration` is `Hashable`
  and is the **lookup key — not the model**. Same configuration ⇒ same executor instance ⇒ reused KV
  cache and reused connections. Different configuration ⇒ a new executor, a cold cache, and a
  re-prefill you will feel.
- **What belongs in a `Configuration`**, the manual `==`/`hash` escape hatch every real provider
  reaches for, and a **real latent bug in Apple's own sample package** that is exactly the mistake a
  provider author will make.
- **How load-bearing `Configuration: Hashable` actually is** — illustrated by a deleted 92-line
  type-eraser that `unsafeBitCast`s a metatype to `UnsafeRawPointer` for no reason other than to
  obtain `Hashable`.
- **Teardown you do not write**, and the two legitimate ways to opt out of it (a process-global
  weights cache; a borrow-counted shared resource registry).
- **`prewarm` is not guaranteed to run.** How to design so weights load exactly once either way, and
  the near-miss signature that compiles, binds the framework's default no-op, and never tells you.
- **Transcript diffing** — the heart of a stateful provider. You receive the *full* transcript on
  every `respond`. Appended entries mean you keep your state; removed or modified entries mean you
  invalidate back to the divergence point. The framework hands you the data; **your executor decides
  what counts as a match**.
- **The payoff, measured:** turn-2 TTFT **23.28 s → 0.230 s (101×)** at 4k context with
  byte-identical greedy output — community-measured, and the mechanism is a **single integer
  assignment**. Plus the API contract that makes it safe, and the model architectures that forfeit it
  entirely.
- **Approximate or throw** — Apple's rule for the moments when the developer asked for something your
  model cannot honestly do.

## What you need

- **Xcode 27** and a 27.0 SDK. There is no partial adoption.
- A real device or Mac. The Simulator punches inference out to the host, which produces timing that
  means nothing for any claim in this guide.
- Read [`03-authoring-a-languagemodel-provider.md`](03-authoring-a-languagemodel-provider.md)
  first — this guide assumes you already have a conforming `LanguageModel` / `LanguageModelExecutor`
  pair that compiles and streams text. It also assumes you know what a `Transcript` is; if not, start
  at [`../../part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md`](../../part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md).
- If you are choosing a *model* rather than writing a provider, §9.4 is the section that matters to
  you, and [`../../part-01-orientation-and-gating/references/01-apple-ai-stack-2026-map.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/references/01-apple-ai-stack-2026-map.md)
  carries the decision table.

---

## Contents

1. [The store: one per session, keyed by `Configuration`](#1-the-store-one-per-session-keyed-by-configuration)
2. [What belongs in a `Configuration`](#2-what-belongs-in-a-configuration)
3. [⚠️ The `urlSession` that isn't in the key](#3-️-the-urlsession-that-isnt-in-the-key)
4. [How load-bearing `Hashable` is: the deleted type-eraser](#4-how-load-bearing-hashable-is-the-deleted-type-eraser)
5. [Teardown you don't write — and two ways to opt out](#5-teardown-you-dont-write--and-two-ways-to-opt-out)
6. [`prewarm` is not guaranteed to run](#6-prewarm-is-not-guaranteed-to-run)
7. [What arrives on every call, and what it costs](#7-what-arrives-on-every-call-and-what-it-costs)
8. [Transcript diffing](#8-transcript-diffing)
9. [Below the diff: rewinding a KV cache is one integer](#9-below-the-diff-rewinding-a-kv-cache-is-one-integer)
10. [A worked executor skeleton](#10-a-worked-executor-skeleton)
11. [Approximate or throw](#11-approximate-or-throw)
12. [Checklist](#12-checklist)
13. [Sources, and where they disagree](#13-sources-and-where-they-disagree)

---

## 1. The store: one per session, keyed by `Configuration`

Before any of the performance work makes sense you need the object graph exactly right, because
almost every provider bug in this area is a *lifetime* bug wearing a performance costume.

There are two protocols and they do very different jobs.

> ✅ **VERIFIED** — read from the **macOS 27 beta `FoundationModels.swiftinterface`** by the author of
> `coreai-model-zoo`'s `knowledge/fm-provider.md:19-38`, and independently consistent with every
> member of all three conforming implementations in the corpus (Apple's `CoreAILanguageModel`, MLX's
> `MLXLanguageModel`, the community `ZooLanguageModel`):
>
> ```swift
> protocol LanguageModel: Sendable {
>     associatedtype Executor: LanguageModelExecutor where Self == Executor.Model
>     var capabilities: LanguageModelCapabilities { get }
>     var executorConfiguration: Executor.Configuration { get }
> }
>
> protocol LanguageModelExecutor: Sendable {
>     associatedtype Configuration: Hashable, Sendable
>     init(configuration: Configuration) throws
>     func prewarm(model: Model, transcript: Transcript)    // a default no-op exists
>     nonisolated(nonsending) func respond(
>         to request: LanguageModelExecutorGenerationRequest,
>         model: Model,
>         streamingInto channel: LanguageModelExecutorGenerationChannel) async throws
> }
> ```

Apple's own `foundation-models-utilities` package ships a near-identical transcription of the same
two declarations in its agent skill, with one difference worth noting:

> ✅ **VERIFIED** — `skills/foundation-models-language-model-protocol/SKILL.md:42-58`, which spells
> the associated-type constraint as `where Executor.Model == Self` and the executor's as
> `associatedtype Model: LanguageModel`. Same relationship, written from the other end. Both spellings
> appear in Apple-authored material; they are equivalent.

The session presenter states the linkage in one sentence:

> ✅ **VERIFIED** — WWDC26 session 339, *Bring an LLM provider to the Foundation Models framework*
> (Christopher Webb, Machine Learning Research), `339:58`: *"**The `Configuration` is what links the
> two types: the Model provides it, and the framework uses it to construct the executor.**"*

### 1.1 The store, in Apple's words

This is the paragraph the whole guide hangs on. It is narrated over an animated diagram, so there is
no code on screen — but the prose is unambiguous and it is quoted here in full because every word of
it is load-bearing.

> ✅ **VERIFIED** — WWDC26 session 339, `339:59-66`:
>
> *"Each **session holds an executor store**. When **Model1** arrives, the framework checks the store
> using the model's configuration, but there's no matching executor. So, the `LanguageModelSession`
> creates a new executor and stores it. **Model2 produces the same configuration, and because
> `Configuration` is `Hashable`, the framework knows it matches, and resolves to the same executor.
> The configuration is the lookup key, not the model.** Model3 produces a different configuration, so
> it gets its own executor. **Each unique configuration maps to exactly one executor in the store.**"*

Read that as a data structure and you get, conceptually:

```
LanguageModelSession
└── executorStore: [Executor.Configuration : Executor]      // conceptual shape, not a public API
```

🟡 **RECONSTRUCTED** — the dictionary spelling above. Apple describes a store keyed by configuration
and says each unique configuration maps to exactly one executor; nothing in the corpus exposes the
store as a type you can name, inspect, or pre-populate. Treat it as an implementation detail with a
guaranteed *behaviour*, not as API.

Four consequences fall straight out of it, and they are the reason this guide exists:

1. **Two different `LanguageModel` values that produce equal configurations share one executor** —
   and therefore one KV cache, one connection pool, one set of loaded weights.
2. **One `LanguageModel` value whose configuration changes between turns gets a *new* executor** —
   and therefore a cold cache and a full re-prefill. Nothing warns you.
3. **The store is per session.** Two sessions over the same model do *not* share an executor through
   the framework. (They may still share weights, if you built a process-global cache — §5.)
4. **`==` on your `Configuration` is a correctness contract, not a formality.** Say two things are
   equal and the framework will hand you the executor built for the other one.

### 1.2 Why the split exists

> ✅ **VERIFIED** — `339:67-71`: *"Here's a `LanguageModel` implementation. It declares its
> capabilities and returns the configuration the framework uses to find its executor. **The Executor
> is where the real work lives, loading weights, managing resources, and streaming tokens back to the
> session.** The framework constructs it from a configuration your model provides, then hands **the
> model in on every request**. **That split is what keeps your Model trivial to construct.**"*

That last clause is the design rule for your public API. The `LanguageModel` type is what an app
developer writes in a view initialiser, possibly on every SwiftUI body evaluation. It must be cheap
to construct, cheap to copy, and free of side effects. All expense lives in the executor, which the
framework creates *once* per unique configuration and hands your model back on every call.

Note the direction of that hand-back: `respond(to:model:streamingInto:)` takes the **model** as a
parameter. The executor does not capture it. That is deliberate — it lets a value-type model carry
per-call state (a changed `additionalHeaders` dictionary, a different `name`) into an executor that
was built once. It also means **anything you read off `model` inside `respond` is *not* part of the
cache key** unless you also put it in the configuration. Which is exactly how §3's bug happens.

### 1.3 Four real `Configuration` types, side by side

The best way to calibrate what belongs in a configuration is to look at what four shipping providers
actually put there.

| Provider | `Configuration` fields | Evidence |
|---|---|---|
| Apple `CoreAIExecutor` | `url`, `variant`, `kvCacheStrategy`, `modelIdentifier`, `samplingConfig`, `vocabSize` | ✅ `apple/coreai-models`, `CoreAILanguageModel.swift:875` |
| MLX `MLXLanguageModel.Executor` | `modelID` (one field) | ✅ `MLXLanguageModel.swift:877-880` |
| Apple `ChatCompletionsLanguageModel.Executor` | `modelName`, `url`, `additionalHeaders`, `urlSession` — **only the first three participate in `==`/`hash`** | ✅ `ChatCompletionsLanguageModel.swift:195-211` |
| community `ZooExecutor` | holds `any InferenceEngine`, `any Tokenizer`, `any PromptDialect`; `==`/`hash` on `modelID` alone | ✅ `ZooExecutor.swift:37-49` |

Two of those four (`ChatCompletions`, `Zoo`) hand-write `==` and `hash(into:)` rather than letting
the compiler synthesise them. That is not an accident; it is the normal case (§2.2).

Note also the spread: MLX keys on a **single string**, Apple's Core AI adapter keys on **six fields
including the sampling configuration**. The community write-up spots the difference and draws the
right conclusion:

> ✅ **VERIFIED** — `knowledge/fm-provider.md:190-193` (trap 3): *"**`Configuration` is the executor
> cache key.** The session stores executors keyed by your Hashable `Configuration` — key it by
> **bundle identity (+ anything that changes behavior)**. Apple keys by `(modelIdentifier,
> samplingConfig)`."*

The parenthetical is the rule: **bundle identity, plus anything that changes behaviour.** Anything
that changes behaviour but is *not* in the key produces silent reuse of the wrong executor. Anything
in the key that does *not* change behaviour produces silent duplication of an executor — a second
copy of your weights, a second KV cache, and a first-turn stall the user reads as a hang.


---

## 2. What belongs in a `Configuration`

Apple states the rule twice in its own package's guidance, and both statements are worth having in
front of you while you write the type.

> ✅ **VERIFIED** — `foundation-models-utilities`,
> `skills/foundation-models-language-model-protocol/SKILL.md:65`: *"`MyLanguageModel.Executor.Configuration:
> Hashable & Sendable` — Snapshot of everything the executor needs. **The framework caches one
> executor per unique configuration, so equality matters** — only put Hashable primitives in here."*

> ✅ **VERIFIED** — same file, pitfall list, `SKILL.md:814`: *"**Configuration must hold only Hashable
> primitives.** Don't put opaque store objects or class references in there — the framework hashes
> Configuration to cache executors."*

"Snapshot of everything the executor needs" is the honest description of the *intent*. "Only Hashable
primitives" is the constraint. Those two pull in opposite directions the moment your executor needs a
live object — a loaded engine, a tokenizer, a `URLSession` — and resolving that tension is the whole
of §2.2.

### 2.1 The three questions

For each thing your executor needs, ask:

**(a) Does changing it change behaviour?** If yes it must be *reachable* by the executor. If no, it
does not belong in the configuration at all.

**(b) Does changing it require a *different* executor instance?** This is the question people skip.
Changing the temperature does not require a new executor — it arrives on every request inside
`request.generationOptions` and your `respond` reads it fresh. Changing the model *bundle* does
require a new executor, because the old one has the wrong weights resident. Apple's Core AI adapter
draws this line at an interesting place: it puts `samplingConfig` **in** the key
(✅ `CoreAILanguageModel.swift:875`), because its engine is constructed around a sampling
configuration rather than taking one per call.

**(c) Is it cheap and stable to hash?** A `URL`, a `String`, an `Int`, a `[String: String]` — yes. A
class instance — no, and see below.

Things that should almost never be in a configuration, because the request already carries them:

> ✅ **VERIFIED** — `LanguageModelExecutorGenerationRequest`, from
> `skills/foundation-models-language-model-protocol/SKILL.md:265-273`:
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

Temperature, sampling mode, maximum response tokens, tool-calling mode, reasoning level, the response
schema and the tool definitions all arrive **per request**. None of them belong in the cache key
unless your engine genuinely cannot change them without being rebuilt.

### 2.2 The manual `==`/`hash` escape hatch

Real executors need live objects. The pattern every provider in the corpus converges on is: **hold
the live object in the `Configuration` struct, and hand-write `==` and `hash(into:)` over the
identity fields only.**

> ✅ **VERIFIED** — the community `ZooExecutor.Configuration` (`ZooExecutor.swift:37-49`) holds
> non-Hashable payload — `any InferenceEngine`, `any Tokenizer`, `any PromptDialect` — and implements
> `==` / `hash(into:)` on **`modelID` alone**, so the struct can still be a dictionary key.

This is legitimate and it is what Apple's own package does too. But it moves a compiler-checked
guarantee into your head, and the cost of getting it wrong is §3. So write it down as an invariant in
a comment next to the type:

```swift prelude:guide-context
import Foundation
import FoundationModels

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct MyExecutor: LanguageModelExecutor {
    public typealias Model = MyLanguageModel

    /// The cache key for this executor.
    ///
    /// INVARIANT: two configurations that compare equal MUST be safe to serve
    /// from the same executor instance. Every field that changes how the engine
    /// behaves participates in `==` and `hash(into:)`. Fields excluded below are
    /// excluded because they are *derived* from an included field, never because
    /// they were inconvenient to hash.
    public struct Configuration: Hashable, Sendable {
        // Identity — participates in equality.
        let bundleURL: URL
        let variant: String?
        let quantization: String

        // Live payload — NOT hashable, NOT part of equality, and derived
        // deterministically from the three fields above.
        let engine: any MyInferenceEngine

        public static func == (lhs: Configuration, rhs: Configuration) -> Bool {
            lhs.bundleURL == rhs.bundleURL
                && lhs.variant == rhs.variant
                && lhs.quantization == rhs.quantization
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(bundleURL)
            hasher.combine(variant)
            hasher.combine(quantization)
        }
    }

    private let configuration: Configuration

    public init(configuration: Configuration) throws {
        self.configuration = configuration
    }

    // …
}
```

> 🟡 **RECONSTRUCTED** — the code block above is *illustrative*: `MyInferenceEngine` is invented for
> the example and `bundleURL` / `variant` / `quantization` are chosen to mirror Apple's Core AI
> configuration shape. The **framework-facing** parts — `public struct Configuration: Hashable,
> Sendable`, `public init(configuration:) throws`, `public typealias Model` — are ✅ verified against
> `ChatCompletionsLanguageModel.swift:187-211` and `MLXLanguageModel.swift:877-886`.

The word **derived** in that comment is the test. `engine` above is fine to exclude because you can
only construct one engine from that triple; two equal configurations therefore hold equivalent
engines. The moment a field is *independently settable* by the developer, excluding it is a bug —
which is precisely what happened in §3.

### 2.3 `init(configuration:) throws`, and the witness that doesn't

One small Swift detail with a real consequence. The protocol requirement is `throws`:

> ✅ **VERIFIED** — `SKILL.md:51`: `init(configuration: Configuration) throws`.

But Apple's own `ChatCompletionsLanguageModel.Executor` satisfies it with a **non-throwing**
initializer:

> ✅ **VERIFIED** — `ChatCompletionsLanguageModel.swift:191`:
> ```swift
> public init(configuration: Configuration) {
>   self.configuration = configuration
> }
> ```
> Swift permits a non-throwing witness for a `throws` requirement, so this conforms. The package's own
> test mocks use the `throws` form instead (`MockModel.swift:62`, `SkillsTests.swift:619`), so both
> spellings are exercised in one repository.

Practical guidance: **make it non-throwing if you can.** A throwing initializer means the framework
can fail to build your executor at an arbitrary point in the developer's call — most likely inside
their first `respond`, where the error will be indistinguishable from a generation failure. Validate
what you can in your `LanguageModel`'s own initializer (which the developer calls explicitly, and
which is allowed to be `async throws` — Apple's is: `CoreAILanguageModel(resourcesAt:mode:variant:kvCacheStrategy:) async throws`,
✅ `CoreAILanguageModel.swift:843-846`) and leave the executor's initializer as a field copy.

---

## 3. ⚠️ The `urlSession` that isn't in the key

Here is the bug. It is in Apple's own `foundation-models-utilities` package, at tag `1.0.0-beta3`
(commit `376ca60`, 2026-07-10), it is the reference implementation that everyone writing a
network-backed provider will read first, and it is exactly the class of mistake §2.2 warns about.

> ⚠️ **SILENT FAILURE — two models that differ only in their `URLSessionConfiguration` are
> cache-equal, so the framework may hand you an executor built with the *other* session.** Nothing
> throws. Nothing logs. Your 600-second timeout silently becomes the 60-second default, or your proxy
> is silently bypassed, and the only symptom is a request that behaves like the one you configured
> for a different endpoint.

The evidence, in three pieces.

**Piece one — the initializer gained a `URLSessionConfiguration` parameter at beta 3.**

> ✅ **VERIFIED** — `ChatCompletionsLanguageModel.swift:73-85`:
>
> ```swift
> public init(
>   name: String,
>   url: URL,
>   additionalHeaders: [String: String] = [:],
>   supportsGuidedGeneration: Bool = true,
>   urlSessionConfiguration: URLSessionConfiguration? = nil     // :78 — added in beta 3
> ) {
>   self.name = name
>   self.url = url
>   self.additionalHeaders = additionalHeaders
>   self.supportsGuidedGeneration = supportsGuidedGeneration
>   self.urlSession = urlSessionConfiguration.map { URLSession(configuration: $0) }   // :84
> }
> ```
>
> The commit message for `376ca60` describes it as *"allows tuning timeouts, proxies, and other
> transport settings; defaults to an ephemeral configuration"*, and the package's own live integration
> test exercises it with 300 s / 600 s timeouts (`ChatCompletionsLiveTests.swift:44-54`). So this is a
> parameter developers are explicitly invited to vary.

**Piece two — that session goes into the configuration.**

> ✅ **VERIFIED** — `ChatCompletionsLanguageModel.swift:96-102`:
>
> ```swift
> public var executorConfiguration: Executor.Configuration {
>   Executor.Configuration(
>     modelName: name,
>     url: url,
>     additionalHeaders: additionalHeaders,
>     urlSession: urlSession
>   )
> }
> ```

**Piece three — and is then excluded from `==` and `hash`.**

> ✅ **VERIFIED** — `ChatCompletionsLanguageModel.swift:195-211`:
>
> ```swift
> public struct Configuration: Hashable, Sendable {            // :195
>   fileprivate let modelName: String                          // :196
>   fileprivate let url: URL                                   // :197
>   fileprivate let additionalHeaders: [String: String]        // :198
>   fileprivate let urlSession: URLSession?                    // :199
>
>   public static func == (lhs: Configuration, rhs: Configuration) -> Bool {   // :201
>     lhs.modelName == rhs.modelName
>       && lhs.url == rhs.url
>       && lhs.additionalHeaders == rhs.additionalHeaders
>   }
>
>   public func hash(into hasher: inout Hasher) {              // :207
>     hasher.combine(modelName)
>     hasher.combine(url)
>     hasher.combine(additionalHeaders)
>   }
> }
> ```

And the executor uses whichever session came in with the configuration it was built from:

> ✅ **VERIFIED** — `ChatCompletionsLanguageModel.swift:230-235`:
> `configuration.urlSession ?? URLSession(configuration: .ephemeral)`.

### 3.1 Why it was written this way, and why that isn't a defence

The exclusion is not carelessness — it is a workaround. `URLSession` is a class with reference
identity. Include it in synthesised `Hashable` and two structurally identical models built from two
separate `URLSession(configuration:)` calls hash differently, so *every* model value gets its own
executor and the store degenerates into an unbounded pile. Exclude it and equality is stable. The
author chose stable equality.

The problem is that `urlSession` fails the "derived" test from §2.2. It is not computed from
`modelName`, `url` and `additionalHeaders`; it is an independent input the developer supplies. So
two models that the framework calls equal are genuinely *not* interchangeable.

### 3.2 What actually happens

Consider a session that routes between two models via a dynamic profile — a perfectly ordinary 27.0
pattern (see [Part 3](../../part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md)):

```swift prelude:external-module
import Foundation
import FoundationModels
import FoundationModelsUtilities

let fast = ChatCompletionsLanguageModel(
    name: "qwen3-0.6b",
    url: URL(string: "http://localhost:8000/v1")!,
    urlSessionConfiguration: {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15          // a snappy triage model
        return c
    }())

let deep = ChatCompletionsLanguageModel(
    name: "qwen3-0.6b",                            // same name…
    url: URL(string: "http://localhost:8000/v1")!, // …same URL…
    urlSessionConfiguration: {                     // …different transport
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 600         // long reasoning runs
        return c
    }())
```

`fast.executorConfiguration == deep.executorConfiguration` is **`true`**. Whichever of the two the
session sees first wins the store slot, and the other one silently inherits its transport. If `fast`
arrives first, `deep`'s long reasoning requests time out at 15 seconds and surface as a network
error. If `deep` arrives first, your triage path hangs for ten minutes instead of failing fast.

> 🔴 **GAP — nobody has observed this fire.** The reasoning above is sound from the source, but the
> corpus contains no reproduction, and the exact framework cache semantics (lifetime within a
> session, whether an executor is ever evicted and rebuilt, whether the *first* or the *last*
> configuration wins on a hash hit) are not documented anywhere we have read. The
> `foundation-models-utilities` research note flags the same limitation explicitly (open question 12:
> *"Depends on framework cache semantics (lifetime, eviction). Reasoned from `SKILL.md:65` + the
> manual `Hashable`, not observed."*). Resolving it needs a device test: build two models differing
> only in `urlSessionConfiguration`, route both through one session, and log which timeout the second
> request actually gets. **Until then, do not rely on either outcome — make the difference visible in
> the key instead.**

### 3.3 The fix, and what to do today

If you are writing your own provider, put a **hashable proxy for the transport** in the key:

```swift compile:27
import Foundation
import FoundationModels

public struct Configuration: Hashable, Sendable {
    let modelName: String
    let url: URL
    let additionalHeaders: [String: String]

    /// A hashable stand-in for the transport. Two configurations with different
    /// transport behaviour MUST NOT compare equal, or the framework will serve
    /// one from the other's executor.
    let transportKey: TransportKey

    // Not hashed: derived from `transportKey` at construction.
    let urlSession: URLSession?

    struct TransportKey: Hashable, Sendable {
        var requestTimeout: TimeInterval
        var resourceTimeout: TimeInterval
        var waitsForConnectivity: Bool
        var proxyDescription: String?
        var identifier: String?     // caller-supplied tiebreaker, e.g. "triage" / "deep"
    }

    public static func == (lhs: Configuration, rhs: Configuration) -> Bool {
        lhs.modelName == rhs.modelName
            && lhs.url == rhs.url
            && lhs.additionalHeaders == rhs.additionalHeaders
            && lhs.transportKey == rhs.transportKey
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(modelName)
        hasher.combine(url)
        hasher.combine(additionalHeaders)
        hasher.combine(transportKey)
    }
}
```

> 🟡 **RECONSTRUCTED** — `TransportKey` is our design, not Apple's. The fields are chosen from real
> `URLSessionConfiguration` properties, but no shipping provider in the corpus does this. The
> `identifier` escape hatch is the important one: it lets a developer force two executors apart
> without you having to enumerate every transport property that might matter.

If you are *using* `ChatCompletionsLanguageModel` as it ships today, the safe pattern is to make the
models differ in something that *is* hashed. `additionalHeaders` participates in equality, so a
single distinguishing header does the job and costs one line:

```swift prelude:guide-context
let deep = ChatCompletionsLanguageModel(
    name: "qwen3-0.6b",
    url: URL(string: "http://localhost:8000/v1")!,
    additionalHeaders: ["X-Client-Profile": "deep"],   // forces a distinct cache key
    urlSessionConfiguration: longTimeouts)
```

That is a workaround, and it leaks a private concern onto the wire. Prefer it anyway: a stray header
your server ignores is cheaper than a transport you cannot predict.

### 3.4 The general lesson

This is the single most transferable idea in the guide, so it gets stated plainly:

**Every field you exclude from `==` is a promise that two configurations differing only in that field
are interchangeable. If that promise is false, the framework will keep it anyway — silently, and
usually only under load or under a profile switch, which is to say in production.**

Write the promise as a comment. Then write a test that asserts it. `foundation-models-utilities` has
a whole test file for its configuration (`ChatCompletionsTests+Configuration.swift`, 56 lines,
✅ present in the repo) and it does not contain this assertion.


---

## 4. How load-bearing `Hashable` is: the deleted type-eraser

If §3 tells you that `Configuration`'s equality is a correctness contract, this section tells you how
much of the framework's architecture is resting on the fact that a `Configuration` is `Hashable` at
all. The clearest available illustration is a file Apple **deleted**.

At tag `1.0.0-beta1` (commit `a047a50`, 2026-06-07), `foundation-models-utilities` shipped
`Sources/FoundationModelsUtilities/LanguageModels/DynamicProfile+LanguageModel.swift` — a 92-line
hand-rolled **`AnyLanguageModel` type-eraser**. It existed so that a `DynamicProfile` could carry a
`LanguageModel` without knowing its concrete type; the framework did not yet ship that ability. At
beta 3 it was removed, and the commit message says why.

> ✅ **VERIFIED** — commit `376ca60`'s message, in full for this line: *"Removed `.model(any
> LanguageModel)` modifier since it's now included in the Foundation Models framework."*

So the type-eraser is dead code, and you must not write it. What makes it worth reading is *what it
had to do to survive*.

> ✅ **VERIFIED** — `git show a047a50:Sources/FoundationModelsUtilities/LanguageModels/DynamicProfile+LanguageModel.swift`,
> the load-bearing extract:
>
> ```swift
> var executorConfiguration: Executor.Configuration {
>   func projectExecutorType<L: LanguageModel>(_ model: L) -> L.Executor.Type { L.Executor.self }
>   return Executor.Configuration(storage.executorConfiguration, executorType: projectExecutorType(storage))
> }
> …
> struct Configuration: Hashable, Equatable, @unchecked Sendable {
>   fileprivate let configuration: AnyHashable
>   fileprivate let executorType: Metatype
> }
> private struct Metatype: Hashable, Equatable, @unchecked Sendable {
>   private let type: UnsafeRawPointer
>   init(_ swiftType: Any.Type) { type = unsafeBitCast(swiftType, to: UnsafeRawPointer.self) }
>   var swiftType: Any.Type { unsafeBitCast(type, to: (Any.Type).self) }
> }
> ```

Take that apart slowly, because each line answers a question the protocol forces on you.

### 4.1 Why the metatype had to be in the key

The `LanguageModel` protocol has an associated type: `associatedtype Executor: LanguageModelExecutor
where Self == Executor.Model`. Erase the model and you erase the executor type with it. But the
executor store is keyed by `Configuration` values, and two *different* providers can perfectly well
produce configurations that compare equal — imagine two packages that both key on a single
`modelID: String` and a developer who uses `"qwen3-0.6b"` in both.

If the erased configuration were just the wrapped configuration, those two would collide in the store
and one provider would be handed the other's executor. So the eraser's `Configuration` is a **pair**:
the wrapped configuration *and* the concrete executor type. Two entries are the same only if both
halves match.

`projectExecutorType` is how you get that type out. You cannot write `L.Executor.self` against an
existential; you need a generic context, so a local generic function is opened over the concrete
model just long enough to project `L.Executor.Type`. That is the "associated-type dance" in one line.

### 4.2 Why `unsafeBitCast`

Now the awkward part. `Any.Type` is not `Hashable` in Swift. It is not `Equatable` either. It cannot
be a dictionary key, cannot be combined into a `Hasher`, cannot participate in a synthesised `==`.
And the eraser's `Configuration` *must* be `Hashable`, because that is the protocol requirement —
`associatedtype Configuration: Hashable & Sendable`.

So the code casts the metatype to a raw pointer, which *is* `Hashable`, and casts it back when it
needs the type again. It wraps that in a private `Metatype` struct with `@unchecked Sendable` because
`UnsafeRawPointer` is not `Sendable` either.

> ✅ **VERIFIED** — the research note's own reading of the same file: *"Note the `unsafeBitCast` of a
> metatype to `UnsafeRawPointer` purely to obtain `Hashable` — evidence of how load-bearing
> `Configuration: Hashable` is to the executor cache."*

That is the point. An Apple engineer reached for `unsafeBitCast` — twice, symmetrically — rather than
give up `Hashable`. `Hashable` is not a convenience on this protocol; it is the mechanism. Everything
in §1 through §3 follows from it.

### 4.3 What you should take from this

Three things, in descending order of practical value.

**Do not write this.** The framework ships `.model(any LanguageModel)` as of beta 3
(✅ commit `376ca60`; the modifier is listed among symbols "moved into the framework"). If you are
reading a tutorial or an LLM-generated snippet that hand-rolls an `AnyLanguageModel`, it is written
against beta 1 and is now redundant.

> 🔴 **GAP (checked 2026-07-29, still open) — whether the framework's own eraser uses the same
> trick.** The named resolution has been half-run: the FoundationModels 27.0 interface *was*
> captured, and it shows the shipped modifier pair — `.model(_ model: any LanguageModel)` and
> `.model(_ model: some LanguageModel)` (✅ **SDK-verified**,
> `FoundationModels-27.0-macos.swiftinterface:966-968`) — but **no public `AnyLanguageModel` type
> and no visible cache-key machinery**: whatever erasure the framework performs is internal, and a
> `.swiftinterface` does not emit internal storage. So how the composite cache key is built —
> and whether it includes the executor type — remains unknowable from the interface; only the
> two-provider device test with deliberately colliding configurations would settle it.
> **Meanwhile: make your configuration's identity fields package-specific.** A `modelID` of
> `"qwen3-0.6b"` is a collision waiting to happen; prefix it, or include your bundle URL, or add a
> `providerID` constant. This costs nothing and closes the hazard regardless of how the framework
> behaves.

**`AnyHashable` is a legitimate tool here.** The eraser stores the wrapped configuration as
`AnyHashable`, which is the standard-library box that preserves both `==` and `hash` across
heterogeneous types. If your own configuration needs to carry a caller-supplied hashable payload of
unknown type, `AnyHashable` is the right answer and does not require any unsafe code.

**Prefer designing the collision away over encoding it.** The eraser had to include a type identity
because it could not control what its clients keyed on. You can. §4's GAP box gives the one-line fix.

---

## 5. Teardown you don't write — and two ways to opt out

The lifecycle promise is short and generous:

> ✅ **VERIFIED** — WWDC26 session 339, `339:72-74`: *"**When the session deallocates, the store goes
> with it. Every stored executor gets released, your `deinit` runs, weights are freed, and connections
> closed, all automatically. You don't write any of that teardown code yourself.**"*

For a provider whose expensive state lives *inside* the executor, that is the whole story. Put your
engine handle, your URL session, your Metal buffers in the executor; give the type a `deinit` if it
owns anything C-shaped; and stop thinking about it. The session owns the store, the store owns the
executors, and ARC does the rest.

Two structural situations break that model, and both appear in shipping code.

### 5.1 Opt-out one: a process-global weights cache

Weights are the expensive thing and they are not session-scoped in the developer's mental model. If a
user closes a chat and opens another, they expect the model to still be loaded. Session-scoped
teardown gives them a 2–30 second reload.

MLX solves this by keeping the weights **outside** the executor entirely.

> ✅ **VERIFIED** — `mlx-swift-lm`, `MLXLanguageModel.swift:351`: a process-global
> `static let cache = ModelCache()`, with the doc comment at `:349-350`: *"**Without caching, model
> loading takes 2-30 seconds per request.**"* Because that cache outlives every session, MLX must
> also expose explicit eviction: `MLXLanguageModel.evictAll()` and `.evict()` (`:472`, `:484`).

That is a deliberate trade. You get warm weights across sessions and across model swaps; you give up
the automatic teardown the session promises, and you inherit the obligation to expose an eviction API
and to document when a developer must call it. **If you keep weights in a process-global cache, ship
`evict` and say so in your README.** A developer who cannot free 2 GB on a memory warning will not
ship your package.

### 5.2 Opt-out two: a borrow-counted shared registry — keyed by `Configuration`

Apple's own Core AI adapter takes a more interesting third path, and it is the strongest evidence in
the corpus for how much weight `Configuration` carries. It keeps a **process-wide registry of loaded
resources, keyed by the very same `Hashable` configuration the framework uses for its executor
store** — but holds the values weakly, so the memory still goes away when the last owner does.

> ✅ **VERIFIED** — `apple/coreai-models`,
> `swift/Sources/CoreAILanguageModels/LanguageModel/ModelResources.swift` (introduced by commit
> `eb3998e`, *"Lazy runner design: defer engine load (#91)"*):
>
> - `static func shared(for: CoreAILanguageModel.CoreAIExecutor.Configuration) -> ModelResources` — a
>   **process-wide registry keyed by the Hashable Configuration**, values held in a `WeakBox` *"so
>   releasing the model releases the engine"*.
> - `engine() async throws -> any InferenceEngine` — a **single in-flight load shared by concurrent
>   callers**; failures are **not** cached (the task is dropped so the next caller retries); a
>   `generation` counter lets an in-flight load detect that it was cancelled by `unloadResources()`.
> - `withEngine { engine in … }` — increments `activeBorrows`; a concurrent `unloadResources()` sets
>   `unloadPending` and teardown is **deferred until the last borrow returns**, *"so the engine is
>   never freed mid-generation."*

Four separate ideas there, all worth stealing:

1. **The same key, two levels.** The framework keys executors by configuration within a session;
   Apple keys *weights* by the same configuration across the process. Two sessions over the same
   bundle get two executors and one set of weights. This is almost always what you want, and you get
   it for free by reusing the key you already had to define.
2. **Weak values.** The registry does not keep anything alive. When the last `CoreAILanguageModel`
   and the last executor holding that resource go away, so does the engine — so §5's promise still
   holds from the developer's point of view, without a manual `evict`.
3. **Coalesce concurrent loads, do not cache failures.** Two `respond` calls racing on a cold model
   must produce one load, and a load that threw must not poison the slot forever.
4. **Borrow counting.** This one is not optional. If a developer's session deallocates while a
   generation is in flight — user navigates away mid-stream, which happens constantly — naive teardown
   frees the engine underneath a running GPU encode. Deferring until the last borrow returns is the
   difference between a clean cancellation and a crash report you cannot reproduce.

### 5.3 The pattern in your own executor

```swift prelude:guide-context
import Foundation
import FoundationModels

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct MyExecutor: LanguageModelExecutor {
    public typealias Model = MyLanguageModel

    public struct Configuration: Hashable, Sendable {
        let bundleURL: URL
        let variant: String?
    }

    private let resources: MyModelResources

    public init(configuration: Configuration) {
        // Shared across the process, keyed by the same value the framework
        // uses for its per-session executor store. Held weakly inside.
        self.resources = MyModelResources.shared(for: configuration)
    }

    public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: MyLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        try await resources.withEngine { engine in
            // The engine cannot be torn down while this closure is running.
            try await generate(request, on: engine, into: channel)
        }
    }
}
```

> 🟡 **RECONSTRUCTED** — `MyModelResources` and `withEngine` are our names for Apple's shape. The
> **structure** (a `shared(for:)` registry keyed by the executor `Configuration`, a borrow-scoped
> `withEngine`) is ✅ verified from `ModelResources.swift` as described above; the identifiers here
> are ours because that type is internal to `apple/coreai-models` and is not something you import.

### 5.4 The counterexample: server-backed providers own nothing

Not every provider needs any of this. `ChatCompletionsLanguageModel` holds a `URLSession` and nothing
else; it implements **no** `prewarm`, has no `deinit`, and relies entirely on the session-scoped
teardown of §5.

> ✅ **VERIFIED** — grep for `prewarm` across `foundation-models-utilities` returns only the mention
> in `SKILL.md:57`. Neither `ChatCompletionsLanguageModel.Executor` nor either of the two test mocks
> (`MockModelExecutor`, `SkillsMockModelExecutor`) implements it.

That is the right call for a network model and Apple says so directly (§6). Do not build a resource
registry you do not need; the whole point of §5's promise is that most providers should be able to
ignore it.


---

## 6. `prewarm` is not guaranteed to run

`prewarm` is the one lifecycle hook you get before the first request, and the single most important
fact about it is that **it might not happen**. Apple states this and then states the design
consequence in the same breath.

> ✅ **VERIFIED** — WWDC26 session 339, `339:75-82`:
>
> *"Within that lifecycle, your executor has one more function: **`prewarm`**. Before a request
> arrives, the developer can ask the framework to prewarm. It's your chance to do **expensive setup
> ahead of time, like loading weights, opening connections, or anything that would otherwise slow down
> that first response.**
>
> One approach is to put that setup in a **private helper that loads the weights once and caches
> them**. `prewarm` calls the helper **eagerly**, so the weights are ready before the first request
> arrives. **But `prewarm` isn't guaranteed to run.** Either way, weights load exactly once, and **if
> your executor has no expensive setup, like a server-backed model, `prewarm` can simply be a
> no-op.**"*

Read the middle of that as an instruction, because it is one. The documented pattern is:

> **A private helper that loads-and-caches, called *eagerly* from `prewarm` and *lazily* from
> `respond`.** Weights load exactly once whether or not `prewarm` fires.

This is not a performance trick, it is the correctness requirement. If your `respond` assumes
`prewarm` ran, your provider breaks for every developer who never calls `session.prewarm()` — which,
since the session's `prewarm` is an optimisation hint, is most of them.

### 6.1 The signature is synchronous and non-throwing

Look again at the requirement:

```swift prelude:guide-context
func prewarm(model: Model, transcript: Transcript)   // no async, no throws
```

No `async`. No `throws`. So every real implementation spawns a detached `Task` and swallows or logs
the error. All three conformances in the corpus do exactly that:

> ✅ **VERIFIED** — Apple's Core AI adapter, `CoreAILanguageModel.swift:269-271`:
> ```swift
> public func prewarm(model: CoreAILanguageModel, transcript: Transcript) {
>     Task { try? await resources.loadResources() }
> }
> ```

> ✅ **VERIFIED** — MLX, `MLXLanguageModel.swift:920-930`:
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

> ✅ **VERIFIED** — the community `ZooExecutor.swift:82` declares
> `public func prewarm(model: ZooLanguageModel, transcript: Transcript)` and implements a *real*
> warm-up: a 1-token generate followed by a reset.

Note MLX's choice to **log** rather than swallow. Copy that. A `try?` here means a developer whose
weights failed to download gets no signal at all until the first `respond` fails with what looks like
a generation error. `os.Logger` with `privacy: .public` on the model ID costs nothing and makes the
failure findable in a sysdiagnose.

Also note the `transcript` parameter. Apple passes it, nobody in the corpus reads it, and it is
obvious why it exists: for a provider that can prefill, `prewarm` is the moment to prefill the
instructions entry and whatever prompt is already there. Nothing in the corpus demonstrates that.

> 🔴 **GAP — what the `transcript` argument to `prewarm` actually contains.** The requirement's
> signature is now ✅ **SDK-verified** — `func prewarm(model: Self.Model, transcript: Transcript)`,
> concrete `Transcript`, with the default implementation in an extension
> (`FoundationModels-27.0-macos.swiftinterface:1714, :1906-1908`) — which confirms §6.2's
> exact-signature trap from the SDK side. But the parameter's *contents* remain unobserved: it is
> in the requirement and in all three conformances' signatures, and none of them reads it. We do not know
> whether it is empty at the point a developer calls `session.prewarm()` before any turn, whether it
> carries the instructions entry, or whether it is the full history on a later prewarm. Resolving it
> needs one `print(transcript.count)` on a device. **Meanwhile, do not build prefill-on-prewarm as
> your only fast path** — treat any work you do from `prewarm` as a bonus and make `respond` correct
> without it, exactly as §6 requires anyway.

### 6.2 ⚠️ The near-miss signature that binds the default

> ⚠️ **SILENT FAILURE — `prewarm` ships a default no-op extension, so a signature that is *almost*
> right compiles cleanly, binds the framework's do-nothing default, and is never called.** There is no
> diagnostic. `session.prewarm()` appears to work. The first response is just slow, forever.

This is the most-reported provider footgun in the corpus and it has **three independent sources**,
which is more corroboration than almost anything else in this guide.

> ✅ **VERIFIED** — `knowledge/fm-provider.md:183-186`, trap 1: *"**`prewarm` has a default no-op
> extension.** Implement `prewarm(model:transcript:)` **exactly** — implement `prewarm(transcript:)`
> and it **compiles but is never called**."*

> ✅ **VERIFIED** — `MLXLanguageModel.swift:901-907`, and this is the most precise statement of the
> failure: *"The signature must match the requirement **exactly** — **concrete `Transcript`, not a
> generic `some Collection<Transcript.Entry>`** — otherwise it fails to bind as the witness and the
> framework's no-op default silently wins instead."*

> ✅ **VERIFIED** — `ZooExecutor.swift:68-70`: *"the protocol ships a default no-op, so a near-miss
> compiles and is silently never called."*

MLX's version names the exact trap you will fall into. `Transcript` conforms to `Collection`, and
writing `some Collection<Transcript.Entry>` is idiomatic modern Swift — it is what you would write
for any other API. Here it is wrong, and wrong silently.

**How to detect it in ten seconds.** Add `@_implements`-style explicitness by making the witness
impossible to get wrong:

```swift prelude:guide-context
import FoundationModels
import os

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
extension MyExecutor {
    // Exact witness. Concrete `Transcript`. Both labels. No generics.
    public func prewarm(model: MyLanguageModel, transcript: Transcript) {
        Self.logger.debug("prewarm called")     // ← if this never prints, you are not the witness
        Task {
            do { try await Self.loadedEngine(for: configuration) }
            catch { Self.logger.error("prewarm failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
}
```

The `logger.debug` line is the whole test. Call `session.prewarm()` once from a `#Playground` or a
unit test, and if nothing prints, your signature is not binding. That is a five-minute check that
saves an afternoon.

A second, stronger check: write a test that constructs your executor directly and calls
`prewarm(model:transcript:)` **through an existential**, because that is what the framework does:

```swift prelude:guide-context
import Testing
import FoundationModels

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@Test func `prewarm binds as the protocol witness`() async throws {
    let executor: any LanguageModelExecutor = try MyExecutor(configuration: .testDefault)
    // If your signature is a near-miss, this dispatches to the framework's
    // no-op default and the recorder stays empty.
    (executor as? MyExecutor).map { $0.prewarm(model: .testDefault, transcript: Transcript()) }
    #expect(await PrewarmRecorder.shared.didRun)
}
```

> 🟡 **RECONSTRUCTED** — the test body is our construction. `Transcript()` as a no-argument
> initializer is **not** verified anywhere in the corpus; if it does not exist, build an empty
> transcript however your other tests do. The backtick-quoted test name is Apple's own house style in
> this package (✅ used throughout `foundation-models-utilities`' tests). The **principle** — dispatch
> through the existential, not through the concrete type — is what makes the test meaningful, because
> a near-miss method still exists on the concrete type and calling it directly proves nothing.

### 6.3 ⚠️ Conflict: does Apple's own Core AI adapter have this bug?

Two sources in the corpus disagree, and since this guide's job is to tell you which to trust, here is
the disagreement in full.

**The community claim** (`knowledge/fm-provider.md:183-186`, and repeated as a capability-matrix row
at `:79-87`): *"**Apple's own adapter has this today**, which is why `session.prewarm()` does nothing
for Core AI models: do your own warm-up (a 1-token generate after load)."* The matrix row reads
`session.prewarm() | ❌ silent no-op for Core AI models`.

**The source says otherwise.** `apple/coreai-models`' `CoreAILanguageModel.swift:269` declares
`public func prewarm(model: CoreAILanguageModel, transcript: Transcript)` — the exact witness, both
labels, concrete `Transcript`. That is not a near miss.

**Ruling: the source wins, but the symptom is probably real.** Evidence precedence puts first-party
source above a community write-up, and the signature we can read is correct. The most likely
reconciliation is that the community author measured an **older snapshot** — their fork's base commit
`b1cb71b` predates Apple's SAM3, VLM and Speech additions, so it is demonstrably a mid-2026 snapshot,
not current upstream — or that they observed a *different* defect with the same symptom: `prewarm`
there fires `resources.loadResources()`, which loads weights and (via `loadEngine`) runs
`engine.warmup(queryLength: 1, sampling: nil)` (✅ `ModelResources.swift`, `loadEngine`), but the
call is inside a detached `Task` with `try?`, so a developer who calls `session.prewarm()` and
immediately calls `respond` may well race it and see no benefit at all.

**What to do with that:** treat the *trap* as real (three independent sources describe the mechanism,
including MLX's own code comment) and the *accusation against Apple's adapter* as unproven. Verify
your own binding with the ten-second logger check rather than reasoning from anyone's claim.

### 6.4 Loading weights is not warming up

One more subtlety that the transcript glosses over and MLX documents precisely. On a GPU backend,
having the weights in memory does not mean the first token is fast.

> ✅ **VERIFIED** — `MLXLanguageModel.swift:598-601`: Metal kernels *"**JIT-compile lazily on the first
> *synchronous* readback** (`.item()` inside the generate loop) — scheduling work with `asyncEval`
> alone does not compile them — so this runs a **minimal throwaway forward pass**."*

> ✅ **VERIFIED** — `MLXLanguageModel.swift:573-576`, on the weights-only entry point: `preload()`
> *"**runs no forward pass, compiles no Metal shaders, and performs no GPU work, so the first
> generation request after `preload()` still pays the one-time Metal shader JIT cost.**"*

So there are **two** distinct costs and they need two distinct remedies: weights I/O (fixed by
loading) and shader compilation (fixed only by running a real forward pass to a synchronous readback).
A `prewarm` that only loads weights fixes half the stall and looks, in a benchmark, like it fixed
none of it.

Apple's Core AI path does both, in the right order:
`CoreAIRunner(contentsOf:variant:kvCacheStrategy:)` → `makeInferenceEngine()` →
`try await engine.warmup(queryLength: 1, sampling: nil)` (✅ `ModelResources.swift`, `loadEngine`).
The community `ZooExecutor` reaches the same conclusion independently and implements *"a real 1-token
generate + reset"* (✅ `fm-provider.md:79-87`).

And one Core AI-specific trap if you are wrapping that engine yourself:

> ✅ **VERIFIED** — `knowledge/fm-provider.md:194-197`, trap 4: set `COREAI_CHUNK_THRESHOLD=1`
> **before engine creation** for decode-only `S=1` bundles, and *"never call `engine.warmup()` with
> the default query length on them (warms `S=256`, which the `S=1` graph rejects)."*

That is a warm-up that *fails* on exactly the bundles that most need it. If your provider wraps Core
AI bundles, pass `queryLength: 1` explicitly rather than taking the default.

### 6.5 The load-once helper, written out

Putting §6 together:

```swift prelude:guide-context
import Foundation
import FoundationModels
import os

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct MyExecutor: LanguageModelExecutor {
    public typealias Model = MyLanguageModel

    static let logger = Logger(subsystem: "com.example.MyProvider", category: "executor")

    public struct Configuration: Hashable, Sendable {
        let bundleURL: URL
        let variant: String?
    }

    private let configuration: Configuration
    private let resources: MyModelResources

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.resources = MyModelResources.shared(for: configuration)
    }

    /// The one and only load path. Idempotent, concurrency-coalescing,
    /// and it does NOT cache failures. Called eagerly from `prewarm`
    /// and lazily from `respond`.
    private func readyEngine() async throws -> any MyInferenceEngine {
        try await resources.engine()      // single in-flight load, shared by all callers
    }

    // EXACT witness: both labels, concrete `Transcript`, no generics, no async, no throws.
    public func prewarm(model: MyLanguageModel, transcript: Transcript) {
        Self.logger.debug("prewarm: begin for \(configuration.bundleURL.lastPathComponent, privacy: .public)")
        Task {
            do {
                let engine = try await readyEngine()
                // Weights are not enough — force shader compilation with a real
                // one-token forward pass to a synchronous readback.
                try await engine.warmUp(queryLength: 1)
                Self.logger.debug("prewarm: ready")
            } catch {
                Self.logger.error("prewarm failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: MyLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        // Same helper. If prewarm ran, this returns immediately.
        // If it didn't, this is where the load happens. Either way: exactly once.
        let engine = try await readyEngine()
        try await generate(request, on: engine, into: channel)
    }
}
```

> 🟡 **RECONSTRUCTED** — `MyModelResources`, `MyInferenceEngine` and `warmUp(queryLength:)` are our
> names. Everything framework-facing is ✅ verified: the `prewarm(model:transcript:)` witness
> (`CoreAILanguageModel.swift:269`, `MLXLanguageModel.swift:920`, `ZooExecutor.swift:82`), the
> `respond(to:model:streamingInto:)` signature (`ChatCompletionsLanguageModel.swift:214-218`), and
> the `Configuration: Hashable, Sendable` requirement. The **shape** — one private load-and-cache
> helper, eager from `prewarm`, lazy from `respond` — is Apple's own prescription at `339:75-82`.


---

## 7. What arrives on every call, and what it costs

Everything so far has been about getting one executor to survive across turns. This section is about
what that survival is *for*.

> ✅ **VERIFIED** — WWDC26 session 339, `339:83-85`: *"Once your `respond` function is called, your
> executor goes to work. It **converts the transcript of the conversation into the format your model
> expects**. It **applies the options** the developer has set and it **streams generation events to
> the session**."*

And the shape of what it receives:

> ✅ **VERIFIED** — `knowledge/fm-provider.md:40-47`, read against the 27-beta
> `FoundationModels.swiftinterface`: *"The session hands the executor the **full transcript on every
> `respond`** (entries: `instructions / prompt / toolCalls / toolOutput / response / reasoning`), plus
> `enabledToolDefinitions`, an optional `schema`, and `generationOptions`… One-shot `respond` is just
> collected streaming. **KV reuse across turns is the executor's job** (diff the new transcript
> against the one you saved; invalidate at the divergence point) — **nobody does it for you.**"*

Sit with the phrase *full transcript on every `respond`*. It means the framework has no notion of
"what is new". Turn 7 arrives looking exactly like turn 1 with more entries. If you do nothing, your
executor re-renders the whole conversation into a prompt and re-prefills it from token zero, every
single turn.

### 7.1 The tax, measured

That default is not a small inefficiency; on a local model it is the dominant cost after the first
turn.

> **Community-measured.** `knowledge/fm-provider.md:198-200` (trap 6): *"**Multi-turn re-prefill
> tax.** Until an executor implements transcript diffing, budget ~decode-speed × history-tokens per
> turn on decode-only bundles (measured: **turn 1 = 0.41 s, turn 2 = 2.8 s** on the 0.8B with a
> 3-entry history + hidden thinking)."*
>
> **Attribution:** community work by GitHub user `john-rocky` (Daisuke Majima), Qwen3.5-0.8B int8, a
> Core AI bundle through the `ZooFMProvider`. Hardware model and macOS build **not stated in the
> source** — treat the ratio as indicative and the absolute numbers as unportable. Not an Apple
> figure.

A turn that gets **6.8× slower** between turn 1 and turn 2, on a three-entry history, with nothing
having gone wrong. And it keeps growing, because the history keeps growing.

Note the tail of that quote — *"+ hidden thinking"*. A reasoning model's `<think>` blocks are real
tokens in the transcript that the user never sees, so the history a provider re-prefills is much
larger than the visible conversation. Two related traps from the same source, both worth knowing
before you profile:

> ✅ **VERIFIED** — `fm-provider.md:204-207`, traps 7 and 8: *"**Thinking is invisible in
> `response.content`** — it lands as `.reasoning` transcript entries. A 'hanging' first response is
> usually the model thinking."* And: *"**Small `maximumResponseTokens` + a thinking model = no
> response at all.** If the cap cuts generation mid-`<think>`, the turn produces only reasoning events
> and the session throws **'ended without producing a response'**."*

### 7.2 Where the win lives

> ✅ **VERIFIED** — WWDC26 session 339, `339:131-133`: *"Earlier we saw how the framework **caches
> executors by configuration**. **If your integration is stateful, holding a KV cache or persistent
> session between calls, that caching is what lets you minimize network churn and avoid redoing
> work.**"*

That sentence is the join between §1 and everything that follows. The executor store is not a
micro-optimisation for object allocation; it exists so that a stateful provider has somewhere to keep
its state. If your `Configuration` is wrong (§2, §3), you get a new executor, your state is gone, and
none of §8 or §9 can help you.

**So the ordering of work is: get identity right, then get diffing right, then get rewinding right.**
In that order. A perfect prefix-reuse implementation behind a configuration that changes every turn
buys nothing at all.

---

## 8. Transcript diffing

This is the heart of a stateful provider, and Apple describes the algorithm in enough detail that
there is no reconstruction needed.

> ✅ **VERIFIED** — WWDC26 session 339, `339:134-142`, quoted in full:
>
> *"**Your executor receives the full transcript on every call to `respond`.** Here's what you
> processed last time, an instruction, a prompt, and the response you generated.
>
> When the next call comes in you **compare the new transcript to the one you saved from last time**.
> **In most cases, new entries have simply been appended**, a new prompt after the last response. When
> that's the case, you can **preserve your existing state and only process what's new**.
>
> **But sometimes your comparison finds that entries have been removed or modified, for example, when
> the developer trims older entries to save context. When that happens, you'll need to invalidate back
> to where the transcripts diverge.**
>
> **The framework gives you the full transcript on every call. Your executor decides what counts as a
> match, and how to handle any changes.**"*

Three claims, each with a design consequence.

### 8.1 "New entries have simply been appended" — the fast path

The common case is append-only, and it is worth optimising for aggressively because it is what a chat
loop produces every turn. Here is a real implementation of exactly that, in compiled Swift:

> ✅ **VERIFIED** — the community `ZooExecutor.swift:145-160`, *"append-only KV fast path"*:
>
> ```swift
> // 3) Append-only KV fast path: skip reset and feed only the suffix
> //    when the rendered prompt extends what's already in the cache.
> let fed: [Int32]
> let kvBase: [Int32]
> if let kv = kvTokens, kv.isEmpty {
>     fed = promptTokens
>     kvBase = []
> } else if let kv = kvTokens, promptTokens.count > kv.count,
>     promptTokens.starts(with: kv)
> {
>     fed = Array(promptTokens[kv.count...])
>     …
> ```

Notice **where** the comparison happens. It is not comparing `Transcript.Entry` values — it is
comparing the **rendered token sequences**. `kvTokens` is the exact token array the engine's KV cache
currently holds; `promptTokens` is this turn's full render. `promptTokens.starts(with: kv)` is the
whole test, and `promptTokens[kv.count...]` is the whole optimisation.

That choice matters, because it sidesteps a hard question. Comparing transcript entries requires you
to define entry equality, decide whether a re-serialised tool call with reordered JSON keys is "the
same entry", and handle the fact that your renderer may collapse several entries into one message.
Comparing rendered tokens asks only one question — *is what I am about to send an extension of what I
already processed?* — and it is the question the KV cache actually cares about.

**Guidance: diff at the layer your state is keyed by.** If your state is a KV cache indexed by token
position, diff tokens. If your state is a server-side conversation ID keyed by message count, diff
messages. If it is both, diff both, and let the coarser one gate the finer one.

### 8.2 "Your executor decides what counts as a match"

Apple's closing sentence is a delegation, and it is doing real work. Two examples of providers
deciding differently:

**Prior assistant turns.** Do you count a previous model response as a match? Only if the tokens you
generated are byte-identical to what your renderer produces when it re-renders that response from the
transcript. For plain models they usually are:

> **Community-measured** — `knowledge/prefix-cache-kv-reuse.md:72-76`: the **system prompt and prior
> user turns always match**, because the chat template is append-only there; prior **assistant** turns
> match only when the model's raw generation equals the template's re-render — *"thinking-stripping /
> retokenization can diverge."* Longest-common-prefix degrades gracefully: reuse the common part,
> re-prefill the tail.

**Argument ordering.** If you replay tool calls into the prompt, the JSON you emit on turn N+1 must be
byte-identical to what you emitted on turn N, or the prefix breaks at that entry:

> ✅ **VERIFIED** — `knowledge/fm-provider.md:138-179`, on the LFM tool-call dialect: *"**The replay
> path sorts kwargs so re-rendered calls are byte-stable (the KV fast path's prefix match depends on
> it).**"*

That is a beautiful, non-obvious coupling and it deserves a rule of its own:

> **Prefix reuse imposes a determinism requirement on your prompt renderer.** Any nondeterminism —
> dictionary iteration order, a timestamp, a `UUID`, locale-dependent number formatting, a
> `Set`-derived tool list — silently destroys reuse from the first entry that contains it onward. It
> does not produce wrong output. It produces a provider that is mysteriously slow on turn 2 and fast
> in your unit tests.

Write a test for it: render the same transcript twice and assert the token arrays are equal.

### 8.3 "Invalidate back to where the transcripts diverge"

The removal/modification case is the one that breaks naive implementations, and it is not rare —
Apple names the exact trigger: *"when the developer trims older entries to save context."* Every
history modifier in `foundation-models-utilities` does this. `rollingWindow(entries:)` is a literal
`history.suffix(n)` (✅ `RollingWindow.swift:79`); `summarizeHistory` collapses the entire history to
**one** entry (✅ `SummarizeHistory.swift:153-161`); `droppingCompletedToolCalls()` deletes tool
entries from the middle (✅ `DropCompletedToolCalls.swift:51-65`). See
[Part 3](../../part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md)
for what those do and why.

From your executor's side, all three look the same: **the new transcript is not an extension of the
old one.** And here is the sharp edge — after a `summarizeHistory`, the new transcript is *shorter*
and *begins differently*, so a naive `starts(with:)` check correctly returns false and you fall back
to a full re-prefill. That is safe. But a naive check that only compares *lengths* would see "fewer
entries, must be a trim, keep the prefix" and would then generate on a KV cache whose contents
correspond to text that is no longer in the prompt. **The output would be plausible and wrong.**

The correct shape:

```swift compile:27
/// Returns the number of leading tokens of `new` that are already valid in the cache.
/// Zero means: reset and re-prefill everything.
func reusablePrefixLength(cached: [Int32], new: [Int32]) -> Int {
    // Always leave at least one token to feed, so the graph has work to do.
    let limit = min(cached.count, max(0, new.count - 1))
    var i = 0
    while i < limit, cached[i] == new[i] { i += 1 }
    return i
}
```

> 🟡 **RECONSTRUCTED** — this exact function is ours. It is the *longest common prefix* step that
> `knowledge/prefix-cache-kv-reuse.md:40-46` describes in prose as
> `want = min(commonPrefixLength(full, kvTokens), full.count - 1)`; the `full.count - 1` clamp is
> ✅ verified from that source, along with its stated reason — *"guarantees at least one token is fed,
> so the graph always has something to run."*

Three properties to notice, because each is load-bearing:

1. **It is a common-prefix scan, not a length comparison.** It handles append, trim, summarise, and
   arbitrary mid-history edits with one code path, and it never returns a length it has not verified
   token by token.
2. **It clamps to `new.count - 1`.** A perfectly-matching prompt with nothing to feed is a degenerate
   case that will either error or return nothing. Always leave one token.
3. **Zero is a correct answer.** If the developer swapped instructions, you re-prefill. Correctness
   first; there is no partial credit for a corrupted cache.

### 8.4 The two structural blockers

Even with a correct diff, two things in the *engine* can defeat it. Both are documented, both are
real, and if you skip them you will ship a fast path that silently never fires.

**Blocker one — the engine over-generates past EOS into the cache.**

> ✅ **VERIFIED** — `knowledge/fm-provider.md:129-136`, and repeated at `ZooExecutor.swift:22-33`,
> observed on macOS 27.0 beta: *"**Breaking the token stream does not stop the pipelined engine.** It
> generates to `maxTokens` in the background and those post-EOS tokens land in the KV cache; the next
> `engine.reset()` blocks on them (**and its internal drain traps after ~5 s** — big slow models
> beware). The packaged executor pumps the stream through a task it can settle on the next respond
> instead of breaking the engine stream directly."*

This is an `AsyncSequence`-contract bug wearing an inference-engine costume. Your consumer `break`s at
EOS — the normal, correct thing to do — and the producer keeps running. Every token it generates after
you stopped listening is committed to the KV cache. Your next turn's prefix check then compares your
rendered prompt against a cache containing tokens that were never in any prompt, the match fails, and
you re-prefill. Silently. Forever.

The fork's engine-side fix and its measurement:

> **Community-measured** — `john-rocky/coreai-models` commit `627fec7` (2026-06-13), *"Stop the
> pipelined engine when the consumer stops the stream"*. `generate()` now terminates the inner token
> stream on consumer break — both eagerly via the returned stream's `onTermination` and from the
> forwarding loop's `yield` result — which trips `runCompletion`'s existing cancel flag, stopping
> within pipeline depth. Sampling, KV and the uninterrupted path unchanged, **byte-identical output**
> claimed. Measured through Apple's own `CoreAILanguageModel` adapter, qwen3.5-0.8B, two-turn chat:
> **second-turn latency 2.74 s → 0.40 s**, same output. Hardware and OS **not stated** — UNVERIFIED
> which device. Community fork, not upstream Apple.

The same defect shows up a third time, as a crash:

> ✅ **VERIFIED (as a community report)** — `knowledge/dynamic-profiles-local-models.md:105-122`:
> *"Consecutive same-model plain-respond turns can crash — D1 over-generation leaves post-EOS tokens
> in the cache; the next same-model turn's KV fast-path meets garbage."* Listed workarounds: alternate
> models, change the instructions each turn, or use guided generation.

**Blocker two — thinking models' templates strip historic reasoning.**

> ✅ **VERIFIED** — `knowledge/fm-provider.md:87`: *"thinking models' templates **strip historic
> `<think>` blocks the cache still contains**"*, so *"EOS-ended/thinking turns still reset (measured:
> **~2.3–2.7 s turn-2 settle** on the default 512-token budget)."*

The cache contains the reasoning tokens because the model generated them. The re-rendered prompt does
not, because the chat template drops them. The two diverge at the first reasoning block and you
re-prefill everything after it. Note that Apple's own Core AI executor makes the same choice on the
render side — `.reasoning` entries are **skipped** when building messages, with the comment *"Don't
echo the model's prior reasoning back into the prompt"* (✅ `CoreAILanguageModel.swift`, the
`makeTokens` entry table). That is the right call for output quality and it is fatal for prefix reuse
on the same turn. **You cannot have both** unless your engine offers a prefill-only call, which
brings us to the one thing the community author assessed and deliberately did not build:

> ✅ **VERIFIED** — `knowledge/prefix-cache-kv-reuse.md:94-105`: *"Assistant re-anchoring* (deeper
> reuse when content is stripped, e.g. gpt-oss harmony) was assessed and **deliberately not
> implemented**: it needs a **prefill-only engine call** (align KV to the canonical rendering without
> sampling) since `generate()` always decodes. Judged narrow benefit vs a real new engine API."*

That is an honest engineering judgement, and it tells you the shape of the API you would need to ask
your engine vendor for.

### 8.5 The measured payoff of diffing alone

Before we get to the KV-rewind primitive in §9, here is what plain transcript diffing buys with no
engine changes at all:

> **Community-measured** — `knowledge/fm-provider.md:87`, `ZooFMProvider` on **LFM2.5-1.2B int8**,
> turns ended by token cap: *"turn 2 reused **97 cached tokens** and prefilled **18**, per-turn latency
> **flat at ~0.33 s instead of growing with history**."* Compare the un-diffed baseline from §7.1:
> turn 1 = 0.41 s, turn 2 = 2.8 s. Hardware and OS build not stated. Not an Apple figure.

"Flat instead of growing with history" is the property you are buying. It is worth more than the
absolute number, because it is the difference between a chat that stays usable at turn 20 and one
that does not.

### 8.6 Report what you reused, honestly

The channel has a place to say how much you reused, and telling the truth there is how a developer
finds out that their fast path is not firing.

> ✅ **VERIFIED** — the usage payload types, from Apple's Core AI adapter
> (`CoreAILanguageModel.swift:468-476`) and mirrored in MLX (`MLXLanguageModel.swift:686-690`):
>
> ```swift
> await channel.send(
>     .response(
>         action: .updateUsage(
>             input: .init(totalTokenCount: promptTokens.count, cachedTokenCount: 0),
>             output: .init(totalTokenCount: generatedTokenCount,
>                           reasoningTokenCount: reasoningTokenCount))))
> ```
>
> Note Apple's adapter passes `cachedTokenCount: 0` — it does no reuse, and it says so.

Set `cachedTokenCount` to the prefix length you actually reused. `ZooFMProvider` does exactly this
(✅ `fm-provider.md:79-87`: *"usage events with `cachedTokenCount`"*), and `ChatCompletionsLanguageModel`
plumbs the same field through from an OpenAI-compatible server's
`prompt_tokens_details.cached_tokens` (✅ `ChatCompletionsLanguageModel.swift:354`). It is the one
number that lets a developer see the difference between "my provider is diffing" and "my provider
thinks it is diffing".

Two hazards when you emit it:

> ✅ **VERIFIED** — `SKILL.md:804` pitfall 1: *"`updateUsage` is wholesale, not additive."* The
> framework treats each `updateUsage` as a **replacement**, so send the final cumulative value last.
> `foundation-models-utilities` pins this with a test: three chunks with completion counts 1, 2, 3 →
> final `output.totalTokenCount == 3` (✅ `ChatCompletionsTests+UsageReporting.swift:108-139`).

> ⚠️ **SILENT FAILURE — and this one contradicts the WWDC session directly.** Session 339 prescribes
> sending metadata and usage **upfront**, before any text (`339:121-130`: *"Sending these upfront
> means the developer isn't waiting through the whole stream to learn what each request costs"*). On
> the 27.0 beta, following that advice on a **tool-calling** turn materialises an **empty `Response`
> transcript entry**:
>
> ✅ **VERIFIED** — `knowledge/fm-provider.md:129-132`, repeated at `ZooExecutor.swift:14-18`: *"**Don't
> send WWDC-339-style upfront usage/metadata.** A `.response(updateUsage:)` event on a turn that ends
> in tool calls materializes an **EMPTY `Response` transcript entry.** Send metadata + usage **once at
> end of turn**, attached to the **kind of entry the turn produced**."*
>
> **Apple's own Core AI adapter sends usage at the end**, after the generation loop and the parser
> flush (✅ `CoreAILanguageModel.swift:468-476`). So the session's recommended order is not what
> Apple's own shipping adapter does. **Follow the code, not the talk**, and note that an empty
> response entry is itself a prefix-poisoning event for §8's diff on the next turn.


---

## 9. Below the diff: rewinding a KV cache is one integer

§8 gets you as far as "I know which prefix is still valid." This section is about what it costs to
*act* on that knowledge, and the answer is startling: on a pure-attention model, almost nothing.

> ⚠️ **Read this first.** `trimKVCache(to:)` and `prefixReuseFeedsFullSequence` are **not Foundation
> Models APIs and not Apple APIs**. They are a three-file, +69/−0 patch to the `InferenceEngine`
> protocol in **`john-rocky/coreai-models`**, a community fork of `apple/coreai-models`
> (commit `0fdf710`, 2026-07-03, *"InferenceEngine: trimKVCache primitive for cross-turn prefix
> reuse"*). Everything in §9.1–§9.6 is community work. It is here because it is the clearest published
> account of the mechanism, because the numbers are the only ones anyone has published, and because
> the *contract* it defines is one you will have to define for yourself in some form. It is **not**
> something you can call from the SDK.

### 9.1 The problem, and the insight

The starting state is the worst possible one, and the author says so:

> ✅ **VERIFIED** — `knowledge/prefix-cache-kv-reuse.md:12-18`: *"`CoreAIChatMac/Sources/ChatEngine.swift`
> was doing exactly the worst thing: `engine.reset()` + `applyChatTemplate(full history)` + full
> re-prefill on EVERY turn … For a 4k-token RAG context that is seconds of dead time before the first
> new token, every turn."*

The engines already preserved KV across `generate()` calls and already prefilled only the unprocessed
suffix. The only missing primitive was a **rewind**. And the insight — credited to a comment on
upstream Apple's own `reset()` — is that a rewind is free:

> ✅ **VERIFIED** — `knowledge/prefix-cache-kv-reuse.md:22-25`, quoting the upstream `reset()`
> comment: *"the KV pair needs no clearing — attention only reads positions below the new offset."*
> So a partial trim = just set `processedTokenCount = length`; positions ≥ length are overwritten
> before they're ever read.

Say that back as a fact about attention, because it generalises far beyond this one codebase:

**Trimming a KV cache is a single integer assignment.** No buffer zeroing, no `memmove`, no
reallocation, no GPU work. The KV tensors are left byte-for-byte untouched; only the engine's notion
of *how many tokens are committed* moves backwards.

Why it is safe: attention is **causal**. A query at position *p* attends only to keys at positions
≤ *p*. Rows `[0 ..< retained]` remain valid because they were written at exactly those positions from
exactly those tokens. Rows ≥ `retained` are stale garbage — and every one of them is **overwritten by
the next prefill before any query can reach it**.

> ✅ **VERIFIED** — `CoreAISequentialEngine.swift:432-436`, the doc comment on the sequential
> implementation: *"KV-only (no recurrent state) — always safe; no clearing needed since causal
> attention never reads positions ≥ the retained offset before they're rewritten."*

What actually moves:

> ✅ **VERIFIED** — `CoreAISequentialEngine.processedTokenCount` (`:72`); and in the pipelined engine,
> `EngineImpl.processedTokenCount` **and** `step` (`CoreAIPipelinedEngine.swift:446`, trim at
> `:1406-1415`), plus `lastSampledToken = nil` so the pipelined sampler does not carry a stale token
> across the rewind.

That third assignment is the kind of detail you only find by writing the thing. A pipelined sampler
holds the last token it emitted; rewind without clearing it and the next step conditions on a token
that is no longer in the cache.

### 9.2 The contract — and why you must not trust your own request

Three additions to the engine protocol. The first is the primitive:

> ✅ **VERIFIED** — `InferenceEngine.swift:123`:
> ```swift
> func trimKVCache(to length: Int) async -> Int
> ```
>
> Contract, from the doc comment at `InferenceEngine.swift:111-122`:
> - Rewinds toward `length`, keeping the leading cached tokens valid and dropping everything after,
>   *"so the next `generate(with:)` prefills only the un-cached suffix instead of the whole prompt."*
> - Returns the **ACTUAL retained prefix length** (0…`length`), *"which may be less than requested
>   because the last generated token's KV can lag one step behind — **the caller must prefill from the
>   returned offset, not from `length`**."*
> - Returns a **negative value** if the engine can't safely rewind, in which case the caller must
>   `reset()` and re-feed the full prompt.

The middle bullet is the one that will bite you, so here it is as a rule:

> **`trimKVCache(to:)` returns the retained prefix, which may be `length - 1`.** The last generated
> token's KV lags one step behind the sampler — the token was chosen, but its key/value rows were
> never written, because writing them is the *next* step's job. **Prefill from the returned value,
> never from the value you asked for.** If you prefill from your requested length you skip exactly
> one token, the model conditions on a hole, and you get output that is fluent, wrong, and
> impossible to distinguish from a bad sample.

The negative-return convention is the second half of the contract and it is what makes the whole
thing safe to adopt incrementally: **unsupported is a value, not an error.**

The second addition is the feed contract, which is the easiest thing to get wrong:

> ✅ **VERIFIED** — `InferenceEngine.swift:138`:
> ```swift
> var prefixReuseFeedsFullSequence: Bool { get }
> ```
> - `true` (the default) — `generate(with:)` takes the **FULL running sequence** and the engine slices
>   `input[retained...]` internally. This is `CoreAISequentialEngine`.
> - `false` — the caller passes **ONLY the un-cached suffix**, because the pipelined engine prefills
>   exactly the tokens it is handed, at the current offset (`CoreAIPipelinedEngine.swift:179`, comment
>   at `:176-178`).

Get this backwards in either direction and you do not crash. Feed the full sequence to an engine that
wanted the suffix and you prefill the prompt **twice**, at the wrong offsets, into a cache that now
contains a duplicated prefix. Feed the suffix to an engine that wanted the whole thing and it slices
`suffix[retained...]` and processes a fragment. Both produce garbage, quietly.

The third addition is what makes the first two adoptable:

> ✅ **VERIFIED** — protocol-extension defaults, `InferenceEngine.swift:185` and `:188`:
> ```swift
> public func trimKVCache(to length: Int) async -> Int { -1 }
> public var prefixReuseFeedsFullSequence: Bool { true }
> ```
> i.e. **opt-in and fail-safe**: any engine that doesn't implement it reports "unsupported" and the
> caller degrades to the old full re-prefill path. **No existing engine changes behaviour.**

That is a design worth copying wholesale. Both defaults fail toward the slow-but-correct path. If you
are adding a capability to a protocol other people implement, this is how.

### 9.3 The two implementations

> ✅ **VERIFIED** — sequential, `CoreAISequentialEngine.swift:437-443` — the verified one:
>
> ```swift
> public func trimKVCache(to length: Int) async -> Int {
>     drain()
>     guard length >= 0 else { return -1 }
>     let retained = min(length, processedTokenCount)
>     processedTokenCount = retained
>     return retained
> }
> ```

`drain()` comes first (`:412`) so no in-flight generation is still writing KV. Then clamp, assign,
report. Five lines, one of which is the entire optimisation.

> ✅ **VERIFIED** — pipelined, `CoreAIPipelinedEngine.swift:183-189` (wrapper) → `:1406-1415` (impl):
>
> ```swift
> func trimKVCache(to length: Int) async -> Int {
>     drain()
>     guard tryAcquireEngine() else { return -1 }
>     defer { releaseEngine() }
>     return engine.trimKVCache(to: length)
> }
> ```
> ```swift
> mutating func trimKVCache(to length: Int) -> Int {
>     guard extraStates.isEmpty else { return -1 }
>     let retained = max(0, min(length, processedTokenCount))
>     processedTokenCount = retained
>     step = retained
>     lastSampledToken = nil
>     return retained
> }
> ```

Note `tryAcquireEngine()` returning `-1` on failure rather than blocking: a rewind that cannot get
exclusive access reports unsupported and the caller resets. Correct, and much better than waiting.

> 🔴 **GAP — the pipelined path is UNVERIFIED even by its author.** `knowledge/prefix-cache-kv-reuse.md:78-105`
> says it is implemented and symmetric but could not be exercised: CoreAIChatMac forces
> `variant: "coreai-sequential"` because the pipelined variant **SIGTRAPs in `GrowingLogitsBuffer`**
> for these bundles, and the iOS pipelined app is single-turn. Verification needs a `GrowingLogitsBuffer`
> fix or a multi-turn pipelined device harness. **Every measured number in §9.5 is from the sequential
> engine.** If you are on a pipelined backend, treat the mechanism as sound and the implementation as
> untested.

### 9.4 ⚠️ Linear attention forfeits prefix caching entirely

The `guard extraStates.isEmpty else { return -1 }` in the pipelined implementation is the most
consequential line in the patch, and it is a *model-selection* fact, not a tuning tip.

> ✅ **VERIFIED** — the doc comment at `CoreAIPipelinedEngine.swift:1401-1405`: *"Rejected when the
> graph carries recurrent `extraStates` (GDN/SSM): those hold a running scan that can't be
> reconstructed at position `length` from the retained KV, so a partial rewind would corrupt them.
> Pure attention KV needs no clearing (causal reads never see positions ≥ `length`)."*

The asymmetry is structural, not an implementation gap:

- An **attention KV cache is positionally addressed.** Row *i* is self-contained. You can truncate at
  any *i*, because row *i* depends only on token *i* and its position.
- An **SSM / GatedDeltaNet / Mamba2 state is a running scan** — one fixed-size tensor that is a lossy
  fold of every token seen so far. There is no row to drop. To obtain the state as of token *k* you
  must re-run the scan from zero.

Consequence:

> ✅ **VERIFIED** — `knowledge/prefix-cache-kv-reuse.md:101-102`: Qwen3.5 / Qwen3.6 linear-attention
> hybrids return `-1` and fall back to full re-prefill; *"Pure-attention models get the win."* The
> fork's README names the affected families: **Qwen3.5 / Qwen3.6 (GatedDeltaNet), LFM2.5, and
> Granite 4 (Mamba2)** (✅ `README.md:9-14`).

> ⚠️ **SILENT FAILURE — the model you picked for its efficiency may be the reason your chat is slow,
> and nothing will tell you.** A hybrid model returns `-1`, your caller correctly falls back to
> `reset()` + full re-prefill, every turn works, output is perfect, and turn-2 TTFT is 20× worse than
> it would be on a pure-attention model of the same size. There is no error, no log, no API that
> reports "prefix caching is unavailable for this architecture." **The only way to know is to check
> the return value and surface it** — log it, or put it in `cachedTokenCount` (§8.6) where a developer
> can see the zero.

The framing worth carrying into a model-selection conversation:

> **Linear attention buys O(1) decode memory and pays for it by forfeiting prefix caching.** On a
> device where multi-turn TTFT is the user-felt metric, that trade can invert the usual "state-space
> models are better on-device" story. *(Community-derived from one implementation, not an Apple
> claim.)*

There is one independent corroboration of the same architectural split, from a completely separate
codebase: MLX Swift's `KVCache` protocol carries `var isTrimmable: Bool { get }` alongside
`@discardableResult func trim(_ n: Int) -> Int`, and its public helpers are
`canTrimPromptCache(_ cache: [KVCache]) -> Bool` and
`trimPromptCache(_ cache: [KVCache], numTokens: Int) -> Int`
(✅ `mlx-swift-lm`, `Libraries/MLXLMCommon/KVCache.swift`). The shape is identical — ask first, and get
back the amount actually trimmed rather than the amount requested. MLX also ships `MambaCache` as a
distinct cache class alongside the attention caches.

> 🔴 **GAP — whether `MambaCache.isTrimmable` is `false`.** The parallel is strong enough that it
> looks like independent confirmation, but the corpus records `isTrimmable` as a protocol requirement
> and does not record `MambaCache`'s value for it, nor the body of `canTrimPromptCache`. Resolving it
> is one line of `KVCache.swift`. **Meanwhile: call `canTrimPromptCache(_:)` and branch on it rather
> than assuming, which is what the API is for.**

### 9.5 The caller-side algorithm, and the numbers

The engine half is useless without the caller half. Here is the per-turn algorithm, as the author
describes it:

> ✅ **VERIFIED** — `knowledge/prefix-cache-kv-reuse.md:40-46`, `ChatEngine.send()` per turn:
>
> 1. `full = applyChatTemplate(history)` (unchanged).
> 2. `want = min(commonPrefixLength(full, kvTokens), full.count - 1)` — where `kvTokens` is the
>    **exact token sequence the engine's KV currently holds** (prompt **+** streamed generation),
>    tracked by the caller across turns. The `full.count - 1` clamp guarantees at least one token is
>    fed, so the graph always has something to run.
> 3. `reused = await engine.trimKVCache(to: want)`; on `< 0` → `reset()` and `reused = 0`.
> 4. `feed = engine.prefixReuseFeedsFullSequence ? full : full[reused...]` → `engine.generate(with: feed)`.
> 5. **Break at the stop sequence (no drain)** so the KV ends at prompt + real answer.

Step 5 is where §8.4's first blocker comes back: prefix reuse is only correct if the KV ends at a
*known* token boundary, which requires the engine to actually stop at EOS rather than run on to
`maxTokens`. **The two fork commits compose** — `627fec7` (stop on consumer break) is what makes
`0fdf710` (rewind) correct. If you implement the second without the first, your cache holds tokens
your caller never saw and your prefix match fails from turn 2 onward.

Step 2's `kvTokens` deserves a note of its own: it is **prompt plus streamed generation**, tracked by
the caller. You cannot ask the engine what is in its cache; you have to remember what you put there.
That bookkeeping is your executor's real state, and it is what §5's lifetime discussion exists to
protect.

Losslessness is claimed by construction and demonstrated empirically:

> ✅ **VERIFIED** — `prefix-cache-kv-reuse.md:48-49`, `:60-62`: lossless by construction because
> `KV[0..reused]` holds identical tokens at identical positions whether reused or recomputed; and with
> `CHATMAC_GREEDY=1` (temperature 0) the turn-2 output is **byte-identical** ON vs OFF. A/B toggles
> shipped: `CHATMAC_NO_PREFIX_CACHE=1` forces the old reset path; `CHATMAC_STATS_LOG=<file>` dumps
> `PFXCACHE prompt=… reused=… ttft=…` per turn.

**Ship those toggles.** An environment variable that forces the slow path, plus a per-turn stats line,
is how you prove a caching change is lossless — and how a user reports a bug you can actually chase.

Now the numbers.

> **Community-measured — qwen3-0.6b, sequential engine, CoreAIChatMac, on a Mac. The exact Mac model
> and macOS build are NOT stated in the source — UNVERIFIED.** Source:
> `knowledge/prefix-cache-kv-reuse.md:52-58`. Community work by `john-rocky`; **not an Apple figure.**
>
> | Turn | Prompt tokens | Reused | TTFT, prefix cache ON | TTFT, OFF | Speedup |
> |---|---|---|---|---|---|
> | 1 (cold) | 81–3820 | 0 | = OFF | initial prefill, unavoidable | 1× |
> | 2 | 357 | 336 | **0.126 s** | **1.915 s** | **15.2×** |
> | 2 | 4103 | **4075 (99.3 %)** | **0.230 s** | **23.282 s** | **101×** |
>
> Multi-turn robustness, 3 turns, greedy (`:66-70`):
>
> | Turn | Tokens | Reused | TTFT |
> |---|---|---|---|
> | 1 (cold) | 826 | 0 | 4.40 s |
> | 2 | — | 826 | **0.122 s** |
> | 3 | — | 849 | **0.151 s** |

Three things to take from that table, in order of importance.

**The scaling shape is the headline, not the peak number.** Re-prefill cost grows with context while
reuse cost stays roughly flat: 15× at 357 tokens, 101× at 4k. For a real RAG or agent context it goes
further. Quoting a bare "101×" without the context length is the kind of thing that gets a benchmark
correctly disbelieved.

**Turn 3 reuses turn 2's answer as well as its prompt.** Prior assistant turns are reused for models
whose `reply.content` equals the raw generation (qwen and llama pass through the harmony parser
unchanged, per `:72-76`). That is §8.2's "what counts as a match" paying off.

**Turn 1 still pays in full, and the author says so.** `prefix-cache-kv-reuse.md:63-64` flags that
3820 tokens takes roughly **22 s** on this small model's `S=1` sequential prefill, and names it a
separate **chunked-prefill** lever that prefix caching does not address. That honesty is why the rest
of the numbers are worth reading.

Two limits the author states that you should not have to rediscover (`:78-105`): **short single-turn
chats see nothing** — this is a long-context and agent lever only; and iOS `CoreAIChat` is
single-turn, so prefix caching has nothing to reuse there at all.

### 9.6 What Apple ships, what MLX ships, what nobody ships

To leave you with an accurate map:

| Capability | Foundation Models framework | Apple `coreai-models` engines | MLX Swift | community fork |
|---|---|---|---|---|
| Executor cached by `Configuration` | ✅ (the store, §1) | uses it | uses it | uses it |
| Transcript handed to you whole | ✅ | — | — | — |
| **Diffing the transcript** | ❌ *your job* | ❌ resets + re-prefills | — | ✅ `ZooFMProvider` |
| **KV cache rewind primitive** | ❌ not a framework concept | ❌ upstream has `reset()` only | ✅ `trimPromptCache(_:numTokens:)` | ✅ `trimKVCache(to:)` |
| Ask-before-trimming | — | — | ✅ `canTrimPromptCache(_:)` / `isTrimmable` | ✅ negative return |

> ✅ **VERIFIED** — the "Apple's adapter resets + re-prefills everything" row:
> `knowledge/fm-provider.md:79-87` capability matrix, **KV reuse across turns**: *"❌ Apple's adapter
> resets + re-prefills everything."*

The takeaway for a provider author is unambiguous, and it is the sentence the community write-up and
the WWDC session agree on word for word: **KV reuse across turns is the executor's job, and nobody
does it for you.**


---

## 10. A worked executor skeleton

Everything above, assembled. Read the marker on this section before you copy it.

> 🟡 **RECONSTRUCTED — read this carefully.** Every **framework-facing** signature below is ✅ verified
> and cited in §1–§9: the two protocol conformances, `Configuration: Hashable, Sendable`,
> `init(configuration:)`, `prewarm(model:transcript:)`, `respond(to:model:streamingInto:)`, the
> `request` members, the channel actions, and the `LanguageModelError` construction. Everything with a
> `My` prefix — `MyEngine`, `MyModelResources`, `MyRenderer`, `MyState` — is **ours**, written to show
> the shape. It does not exist and will not compile against anything. Substitute your own engine.
> This is a *pattern*, not a snippet to paste.

```swift prelude:guide-context
import Foundation
import FoundationModels
import Synchronization
import os

// MARK: - The model: trivial to construct, cheap to copy.

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct MyLanguageModel: LanguageModel, Sendable {
    public typealias Executor = MyExecutor

    public let bundleURL: URL
    public let variant: String?
    public let providerID = "com.example.myprovider"   // guards against cross-package key collisions

    public init(bundleURL: URL, variant: String? = nil) {
        self.bundleURL = bundleURL
        self.variant = variant
    }

    public var capabilities: LanguageModelCapabilities {
        // Declare ONLY what you strictly support. The framework throws
        // `unsupportedCapability` on the developer's behalf for anything you omit.
        LanguageModelCapabilities([.toolCalling, .reasoning])
    }

    public var executorConfiguration: MyExecutor.Configuration {
        .init(providerID: providerID, bundleURL: bundleURL, variant: variant)
    }
}

// MARK: - The executor: where the expense and the state live.

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct MyExecutor: LanguageModelExecutor {
    public typealias Model = MyLanguageModel

    static let logger = Logger(subsystem: "com.example.myprovider", category: "executor")

    /// The executor cache key.
    ///
    /// INVARIANT: two configurations that compare equal MUST be interchangeable.
    /// Every field below participates in `==` and `hash(into:)`; there are no
    /// excluded fields, which is the only way to be sure the invariant holds.
    public struct Configuration: Hashable, Sendable {
        public let providerID: String
        public let bundleURL: URL
        public let variant: String?
    }

    private let configuration: Configuration
    private let resources: MyModelResources
    private let state: MyState          // survives across turns because the executor does

    // Non-throwing: validation belongs in the model's own async init.
    public init(configuration: Configuration) {
        self.configuration = configuration
        self.resources = MyModelResources.shared(for: configuration)  // weak-valued, process-wide
        self.state = MyState()
    }

    // MARK: Load exactly once, whether or not prewarm fires.

    private func readyEngine() async throws -> MyEngine {
        try await resources.engine()    // coalesces concurrent loads; does NOT cache failures
    }

    // EXACT witness. Concrete `Transcript`. No generics, no async, no throws.
    public func prewarm(model: MyLanguageModel, transcript: Transcript) {
        Self.logger.debug("prewarm: begin")     // if this never prints, you are not the witness
        Task {
            do {
                let engine = try await readyEngine()
                try await engine.warmUp(queryLength: 1)   // weights are not enough: force shader JIT
                Self.logger.debug("prewarm: ready")
            } catch {
                Self.logger.error("prewarm failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: The turn.

    public nonisolated(nonsending) func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: MyLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {

        // 1. Approximate or throw. No honest approximation of a schema without logits.
        if request.schema != nil, await !readyEngine().supportsLogits {
            throw LanguageModelError.unsupportedCapability(
                .init(capability: .guidedGeneration,
                      debugDescription: "This engine samples on-GPU and exposes no logits; "
                                      + "guided generation requires per-step logits."))
        }

        // 2. Render the FULL transcript deterministically. Determinism is not
        //    cosmetic: the prefix match in step 4 depends on byte stability.
        let renderer = MyRenderer(tools: request.enabledToolDefinitions,
                                  toolCallingMode: request.generationOptions.toolCallingMode?.kind ?? .allowed)
        let promptTokens = try renderer.render(request.transcript)   // sorted kwargs, no UUIDs, no dates

        // 3. Diff against what we know is in the cache. `cachedTokens` is prompt
        //    PLUS everything we streamed last turn — the engine will not tell us.
        let engine = try await readyEngine()
        let cachedTokens = state.cachedTokens
        let want = min(commonPrefixLength(cachedTokens, promptTokens), promptTokens.count - 1)

        // 4. Rewind. NEVER prefill from `want` — prefill from what came back.
        var reused = await engine.trimKVCache(to: want)
        if reused < 0 {                       // unsupported (e.g. recurrent extra states)
            await engine.reset()
            reused = 0
        }
        let feed = engine.prefixReuseFeedsFullSequence
            ? promptTokens
            : Array(promptTokens[reused...])

        // 5. Generate, and break at the stop token WITHOUT draining, so the cache
        //    ends at a token boundary we can name next turn.
        var generated: [Int32] = []
        let stream = try await engine.generate(
            with: feed,
            maxTokens: request.generationOptions.maximumResponseTokens ?? 512)

        for try await token in stream {
            try Task.checkCancellation()
            if engine.isStopToken(token) { break }
            generated.append(token)
            if let text = renderer.decodeIncrementally(token) {
                await channel.send(.response(action: .appendText(text, tokenCount: 1)))
            }
        }

        // 6. Record exactly what the cache now holds, for next turn's diff.
        state.cachedTokens = Array(promptTokens[..<reused]) + Array(feed) + generated

        // 7. Usage LAST, not upfront — upfront usage on a tool-calling turn
        //    materialises an empty Response entry on the 27.0 beta.
        await channel.send(
            .response(
                action: .updateUsage(
                    input: .init(totalTokenCount: promptTokens.count, cachedTokenCount: reused),
                    output: .init(totalTokenCount: generated.count, reasoningTokenCount: 0))))
    }
}

func commonPrefixLength(_ a: [Int32], _ b: [Int32]) -> Int {
    var i = 0
    let limit = min(a.count, b.count)
    while i < limit, a[i] == b[i] { i += 1 }
    return i
}
```

Six things in that skeleton are decisions, not boilerplate:

**`providerID` in the key.** One constant string, and cross-package configuration collisions become
impossible regardless of how the framework's own eraser behaves (§4.3's GAP).

**No excluded fields in `Configuration`.** The invariant comment is trivially true because there is
nothing to exclude. If you must exclude something, §3.3 shows how to keep the promise honest.

**`try Task.checkCancellation()` in the loop.** Apple's guidance says to do this and Apple's own
`ChatCompletionsLanguageModel` does **not** (✅ `foundation-models-utilities` note, defect 7: *"No
`Task.checkCancellation()` in the stream loop — contradicts the skill's own instruction at
`SKILL.md:637-648`. Only `onTermination` → `task.cancel()` at `:630`."*). The guidance is right:

> ✅ **VERIFIED** — `SKILL.md:637-648`: *"When cancelled, return or throw `CancellationError()`. The
> framework manages the channel lifetime around your `respond(...)` call."*

**`break` on the stop token, no drain.** §9.5 step 5. Without it your recorded `cachedTokens` is a
lie and the diff fails from turn 2.

**`state.cachedTokens` assembled from three pieces.** The retained prefix, the tokens you actually
fed, and the tokens you generated. Getting this line wrong is the single most likely bug in the whole
file, and its symptom is "prefix reuse mysteriously stops working after a tool call".

**Usage last.** §8.6's beta contradiction.

### 10.1 Testing it

Apple's own package documents a three-layer strategy and it maps onto this file cleanly
(✅ `SKILL.md:712-800`): request-builder unit tests, event-translator unit tests against a recording
sink, and end-to-end through a real `LanguageModelSession`. Add three more that are specific to this
guide:

1. **Render determinism.** Render the same transcript twice; assert the token arrays are `==`. This
   catches every §8.2 nondeterminism bug before it becomes a performance mystery.
2. **Prefix arithmetic.** Feed a known `(cached, new)` pair through `commonPrefixLength` and your
   clamp; assert the result and assert that `reused <= want`.
3. **`prewarm` binding.** §6.2's ten-second logger check, or the existential-dispatch test.

One caveat from Apple's own testing notes, which will cost you an hour if you do not know it:

> ✅ **VERIFIED** — `SKILL.md:766-768`: inspect a recorded channel event *"by matching on
> `kind.storage` to recover the typed `Response` / `Reasoning` / `ToolCalls` payload… **(Channel
> events are not Equatable, so a literal `==` against an event literal won't compile.)**"*


---

## 11. Approximate or throw

Everything in this guide is about doing more work for the developer. This section is about the
moments when the right answer is to do less, and say so.

> ✅ **VERIFIED** — WWDC26 session 339, `339:143-150`:
>
> *"**Sometimes your model can't do exactly what the developer asked. When that happens, your executor
> has two choices: approximate or throw.**
>
> **Be flexible where you can, and honor the developer's intent.**
>
> But sometimes there's no honest approximation. **If a developer sets a token limit, but also
> specifies a schema with required fields, there might not be a way to satisfy both. So you throw.**
>
> Foundation Models ships **`LanguageModelError`** for exactly these cases: **context window
> overflows, rate limits, refusals, and more.** Throw one of these, and **any developer who's used the
> framework already knows how to handle it**."*

The token-limit-plus-required-fields example is worth dwelling on because it is the general shape of
the problem. Both requests are individually satisfiable. Together they may be jointly unsatisfiable,
and there is no partial answer that is not a lie — a truncated JSON object that omits a required
field is not "approximately" the requested structure, it is invalid data that will fail the
developer's decode with a confusing error somewhere else in their code.

### 11.1 Being flexible where you can

The flexible half is the larger half. Real examples from real providers, all of them honouring intent
rather than refusing:

| The developer asked for | The provider does | Evidence |
|---|---|---|
| `toolCallingMode == nil` | treats it as `.allowed` | ✅ `ZooExecutor.swift:137`, `MLXLanguageModel.swift:969`; `ChatCompletionsLanguageModel.swift:254-261` maps `.allowed` and `.none` to the same `auto` |
| `.greedy` sampling | sends `top_p = 0` on the wire | ✅ `ChatCompletionsLanguageModel.swift:370` |
| `temperature` below zero | clamps to 0; `temperature == 0` routes to greedy | ✅ `MLXLanguageModel.swift:803-806` |
| a `.custom` transcript segment on a text-only wire format | *throws* — see below | ✅ `ChatCompletionsLanguageModel.swift:450-456` |
| `maximumResponseTokens == nil` | picks a default that depends on the model: `2048` for reasoning models, `512` otherwise | ✅ `CoreAILanguageModel.swift`, `maxTokens` default |

That last row is a good example of intent-honouring: a reasoning model with a 512-token cap frequently
produces *only* reasoning and no answer (§7.1's trap 8), so Apple's adapter quietly gives reasoning
models four times the budget. The developer asked for nothing; the provider gave them the thing they
would have asked for.

### 11.2 Throwing, and throwing the right thing

`LanguageModelError` is non-frozen and has nine documented cases:

> ✅ **VERIFIED** — `SKILL.md:549-557`, with payload fields:
>
> | Case | Payload-specific fields |
> |---|---|
> | `.contextSizeExceeded(ContextSizeExceeded)` | `contextSize: Int`, `tokenCount: Int` |
> | `.rateLimited(RateLimited)` | `resetDate: Date?` |
> | `.guardrailViolation(GuardrailViolation)` | — |
> | `.refusal(Refusal)` | `explanation: String` (required by the public initializer) |
> | `.unsupportedCapability(UnsupportedCapability)` | `capability: LanguageModelCapabilities.Capability` |
> | `.unsupportedTranscriptContent(UnsupportedTranscriptContent)` | `unsupportedContent: [Transcript.Entry]` |
> | `.unsupportedGenerationGuide(UnsupportedGenerationGuide)` | `schemaName: String?` |
> | `.unsupportedLanguageOrLocale(UnsupportedLanguageOrLocale)` | `languageCode: Locale.LanguageCode` |
> | `.timeout(Timeout)` | — |
>
> Every payload struct also exposes `debugDescription: String` and `metadata: [String: any Sendable]`
> (`SKILL.md:559`).
>
> ⚠️ Beta-3 change: `.refusal`'s `explanation` became **required**, and the old
> `LanguageModelError.Refusal(debugDescription:)` example was deleted because it no longer compiles
> (✅ `git show 376ca60 -- skills/`).

The canonical throw, in compiled code:

> ✅ **VERIFIED** — `ZooExecutor.swift:119-128`:
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

Note the `debugDescription`. It names the cause *and* the remedy in one sentence. That is the
difference between an error a developer can act on and one they file a radar about.

Apple's Core AI adapter throws the same case with the same shape:

> ✅ **VERIFIED** — `CoreAIExecutor.respondConstrained` throws `unsupportedCapability(.guidedGeneration)`
> with the debug description *"This model's inference engine does not support guided generation
> (constrained decoding requires per-step logits)."*

### 11.3 The constraint behind both of those throws

This is bigger than an error-handling detail and it belongs in your provider's README, not buried in
a catch block.

> ⚠️ **Grammar-constrained decoding requires access to engine logits, and GPU-pipelined Core AI
> bundles never expose them.** The consequence is architectural: **an app that brings its own model
> loses Apple's flagship structured-generation feature exactly when it selects the fastest backend.**
>
> ✅ **VERIFIED** — `CoreAILanguageModel.swift:860`, capability detection at init:
> `isGuidedGenerationSupported` = the loaded engine's `supportsLogits` if known, else
> `variant != "coreai-pipelined"`. And `apple/coreai-models`' constrained-decoding path hardcodes
> per-step options `InferenceOptions(maxTokens: 1, includeLogits: true)`, so it *"requires an engine
> with `supportsLogits` (sequential / static-shape / VLM), **never** the pipelined GPU engine."*
>
> **Community-measured framing** — `knowledge/fm-provider.md:79-87`: *"**GPU-pipelined engines sample
> on-GPU and return `false`**, so every zoo pipelined bundle lacks `.guidedGeneration`; **the
> sequential engine has it**."*

Two practical consequences for a provider author:

1. **Declare `.guidedGeneration` from the *engine*, not from the model file.** Apple's adapter reads
   `supportsLogits` off the loaded engine and only falls back to a variant-name heuristic when the
   engine is not loaded yet. Copy that ordering.
2. **The framework does the refusing for you if you declare honestly.**

> ✅ **VERIFIED** — `SKILL.md:35`: *"If a developer asks for a capability you didn't declare (e.g.
> tool calling on a model that doesn't support it), the framework throws `unsupportedCapability` for
> you — you don't write defensive code for that."* And `SKILL.md:312`: *"Don't declare a capability
> you don't fully support."* `.guidedGeneration` is defined as *"Model **strictly** conforms output to
> a JSON Schema"* (`SKILL.md:314-319`), with the inline caution at `:110`: *"include only if your model
> **strictly enforces** JSON Schema."*

Capabilities are also load-bearing for **routing**, not just for refusing:

> ✅ **VERIFIED** — `MLXLanguageModel.swift:515-519`: *"Declaring `.reasoning` matters for **request
> routing**: the framework **only forwards a `reasoningLevel` to executors that declare `.reasoning`,
> and auto-rejects one otherwise (on the developer's behalf) before `respond` runs.** The executor in
> turn emits `.reasoning` events only when this capability was declared."*

So an over-declared capability does not just produce bad output; it lets requests through that the
framework would otherwise have rejected cleanly on your behalf.

### 11.4 When *not* to map an error

The mirror image of §11.2, and the corpus contains an unusually thoughtful example.

> ✅ **VERIFIED** — `MLXLanguageModel.swift:855-864`: *"`constraintCompilationFailed` is
> **deliberately NOT mapped** to `unsupportedGenerationGuide`: its origin is ambiguous… and **claiming
> user-fault when the cause is actually our infrastructure misleads developers who pattern-match on
> typed errors.**"*

`unsupportedGenerationGuide` tells the developer *"your schema is the problem"*. If your grammar
compiler fell over for its own reasons, saying that sends them to rewrite a schema that was fine. A
generic error is more honest than a precise lie.

The counterexample in the same corpus is `ChatCompletionsLanguageModel`, which maps **nothing**:

> ✅ **VERIFIED** — the executor never throws `.rateLimited`, `.contextSizeExceeded`,
> `.guardrailViolation` or `.timeout`; even an HTTP **429** becomes a generic
> `RequestError.httpError(statusCode:data:)` (`ChatCompletionsLanguageModel.swift:592`). Its own test
> asserts only `#expect(throws: (any Error).self)` for a 429
> (`ChatCompletionsTests+ErrorHandling.swift:21-30`), so the weak typing is baked into the tests. The
> package's own skill tells third parties to do better (`SKILL.md:545`, `:550`).

A 429 with a `Retry-After` header maps cleanly onto `.rateLimited(RateLimited(resetDate:))` and every
developer who has used the framework already knows how to handle that case. Map it.

### 11.5 Custom errors

> ✅ **VERIFIED** — WWDC26 session 339, `339:151-156`: *"When the built-in `LanguageModelError` cases
> don't cover your situation, define your own error type. Some failures only make sense in the context
> of your service: **your subscription tiers, your features, your account states.** A purpose-built
> case name carries the intent…*
>
> ***Custom errors are powerful, and sometimes you need them. But each one is a new case developers
> must learn, catch, and handle in their app. Try to use a built-in `LanguageModelError` when it fits,
> and save the custom ones for failures only your service can produce.**"*

The test is in the last clause: **only your service can produce it.** "Your subscription expired" —
custom. "The context window overflowed" — built-in, always.

---

## 12. Checklist

Run this before you tag a release.

**Identity**

- [ ] Every field that changes behaviour participates in `Configuration`'s `==` and `hash(into:)`.
- [ ] For every excluded field, a comment states why two configurations differing only in it are
      interchangeable — and a test asserts it. (§3)
- [ ] The key includes something package-specific (`providerID`, or your bundle URL) so it cannot
      collide with another provider's key in the same session. (§4.3)
- [ ] Nothing that arrives per-request — temperature, sampling mode, token cap, tool-calling mode,
      reasoning level, schema, tool definitions — is in the key unless your engine truly cannot change
      it without being rebuilt. (§2.1)

**Lifetime**

- [ ] Expensive state lives in the executor, not in the model. The model is cheap to construct. (§1.2)
- [ ] If you keep a process-global weights cache, you ship an `evict` API and document it. (§5.1)
- [ ] Any shared resource is borrow-counted so teardown cannot free an engine mid-generation. (§5.2)
- [ ] Concurrent cold-start loads coalesce into one; failed loads are **not** cached. (§5.2)

**Prewarm**

- [ ] `prewarm(model:transcript:)` — both labels, concrete `Transcript`, no generics. Verified by a
      log line that actually printed. (§6.2)
- [ ] One private load-and-cache helper, called eagerly from `prewarm` and lazily from `respond`.
      Weights load exactly once whether or not `prewarm` fires. (§6.5)
- [ ] Errors inside the detached `Task` are **logged**, not swallowed. (§6.1)
- [ ] Warm-up runs a real forward pass to a synchronous readback, not just a weights load. (§6.4)

**Diffing**

- [ ] Your renderer is deterministic: sorted keys, no `UUID`s, no timestamps, no `Set` iteration
      order, locale-independent formatting. Tested by rendering twice and comparing. (§8.2)
- [ ] The diff is a common-prefix scan, not a length comparison. Trim, summarise and mid-history
      edits all take the same code path. (§8.3)
- [ ] You clamp the reusable prefix to `count - 1` so there is always something to feed. (§8.3)
- [ ] You track what the cache holds as **prompt + everything you streamed**, updated at the end of
      every turn. (§9.5)
- [ ] You break at the stop token without draining, so the cache ends at a nameable boundary. (§8.4)
- [ ] `cachedTokenCount` reports the truth, so a developer can see when reuse is not happening. (§8.6)

**Rewinding**

- [ ] You prefill from the **returned** retained length, never from the length you requested. (§9.2)
- [ ] A negative return means reset and re-prefill; it is a value, not an error. (§9.2)
- [ ] You know which way your engine wants to be fed — full sequence or suffix only — and both
      defaults fail toward the slow, correct path. (§9.2)
- [ ] If your model family is a linear-attention hybrid, you know prefix reuse is unavailable and you
      have said so somewhere a developer will see it. (§9.4)

**Contract**

- [ ] Capabilities are declared from the loaded engine's real support, not from a filename. (§11.3)
- [ ] Where there is no honest approximation, you throw a built-in `LanguageModelError` with a
      `debugDescription` that names the cause *and* the remedy. (§11.2)
- [ ] HTTP status codes map to typed cases — 429 → `.rateLimited(resetDate:)` — rather than to a
      generic transport error. (§11.4)
- [ ] `try Task.checkCancellation()` inside the generation loop; `CancellationError()` on cancel.
      (§10)
- [ ] Usage and metadata go out at the **end** of the turn, attached to the entry kind the turn
      produced. (§8.6)
- [ ] `updateUsage` values are cumulative totals, because the framework replaces rather than adds.
      (§8.6)


---

## 13. Sources, and where they disagree

### 13.1 What this guide is built from

| Source | Class | Used for |
|---|---|---|
| `apple/foundation-models-utilities` @ `376ca60` (tag `1.0.0-beta3`, 2026-07-10) — `ChatCompletionsLanguageModel.swift` (953 lines), `Package.swift`, both `SKILL.md`s, the test suite, and `git show a047a50` for the deleted type-eraser | Apple first-party source | §1–§6, §8.6, §11 |
| `apple/coreai-models` — `CoreAILanguageModel.swift`, `ModelResources.swift`, `CoreAIRunner`, the `InferenceEngine` protocol | Apple first-party source | §1.3, §5.2, §6, §8.4, §11.3 |
| `ml-explore/mlx-swift-lm` — `MLXLanguageModel.swift`, `KVCache.swift`, `Package.swift` traits | Apple-adjacent first-party source | §5.1, §6.1, §6.4, §9.4, §11.4 |
| WWDC26 session **339**, *Bring an LLM provider to the Foundation Models framework* (Christopher Webb) | WWDC transcript | §1.1, §5, §6, §8, §11 — the executor store, teardown, prewarm, diffing and approximate-or-throw are all narrated here |
| `john-rocky/coreai-models` fork, commits `627fec7` and `0fdf710` | Community source | §8.4, §9 |
| `john-rocky/coreai-model-zoo`, `knowledge/fm-provider.md`, `knowledge/prefix-cache-kv-reuse.md`, `knowledge/dynamic-profiles-local-models.md`, and `ZooExecutor.swift` | Community source + community measurement | §7.1, §8, §9.5, §11.2 |

**Everything with a number attached to it in this guide is community-measured.** Apple published no
latency figure for any of this. Where hardware and OS build were not stated in the source, this guide
says so rather than filling them in.

### 13.2 The disagreements, and how they were ruled

Four places where sources conflict. In each case the ruling follows the series' evidence precedence —
first-party source over documentation over transcript over community write-up — and each is flagged
inline where it appears.

**1. Does Apple's Core AI adapter have the silent-no-op `prewarm` bug?** The community write-up says
yes (`fm-provider.md:183-186`, and a capability-matrix row marking `session.prewarm()` a silent no-op
for Core AI models). Apple's source says no — `CoreAILanguageModel.swift:269` declares the exact
witness. **Ruled for the source.** The most likely explanation is that the community measurement was
taken against an older snapshot (their fork's base commit demonstrably predates Apple's SAM3, VLM and
Speech additions), or that they observed a race against the detached `Task` rather than a binding
failure. The *trap itself* stands — three independent sources describe the mechanism, including MLX's
own code comment. §6.3.

**2. Should usage go out first or last?** Session 339 prescribes upfront
(`339:121-130`). Two community sources and **Apple's own Core AI adapter** send it at the end, and the
community sources report that upfront usage on a tool-calling turn materialises an empty `Response`
transcript entry on the 27.0 beta. **Ruled for the code**, which is both first-party and corroborated.
§8.6.

**3. Does `.greedy` map to `temperature = 0` or `top_p = 0`?** The `foundation-models-utilities`
skill's illustrative code suggests `temperature = 0` (`SKILL.md:295`); the real implementation in the
same repository sets `top_p = 0` (`ChatCompletionsLanguageModel.swift:370`). **Ruled for the
implementation.** Noted because it is a reminder that Apple's own agent-skill prose is a *guide*, not
a spec — that file has eight independently verified stale claims.

**4. How is the `LanguageModel` associated-type constraint spelled?** `fm-provider.md` reads it from
the `.swiftinterface` as `where Self == Executor.Model`; `foundation-models-utilities`' skill writes
`where Executor.Model == Self` with `associatedtype Model: LanguageModel` on the executor. **Not a
conflict** — the two are equivalent, and both are Apple-authored. Recorded so nobody spends an
afternoon on it.

### 13.3 Declared gaps

Carried forward, in the order they appear:

1. **The executor store's spelling and semantics** (§1.1, marked 🟡 there because the *behaviour* is
   verified even though the type is not). Described in prose only; not something you can name, inspect
   or pre-populate. Whether the first or the last configuration wins on a hash hit, whether executors
   are ever evicted mid-session, and the store's exact lifetime are all undocumented.
2. **Whether §3's `urlSession` bug fires** (§3.2). The reasoning is sound from the source; nobody has
   observed it. Needs a device test. Do not rely on either outcome.
3. **How the framework's own `.model(any LanguageModel)` builds its cache key** (§4.3) — and therefore
   whether two providers can collide. Needs the 27.0 generated Swift interface. Mitigate by putting a
   `providerID` in your key.
4. **What the `transcript` argument to `prewarm` contains** (§6.1). Nobody in the corpus reads it. One
   `print` on a device resolves it. Do not build prefill-on-prewarm as your only fast path.
5. **The pipelined `trimKVCache` path is untested** (§9.3), by its own author's admission — blocked on
   a `GrowingLogitsBuffer` SIGTRAP. Every measured number in §9.5 is from the sequential engine.
6. **Whether MLX's `MambaCache.isTrimmable` is `false`** (§9.4). The parallel to the Core AI fork's
   `extraStates` guard is compelling but unconfirmed. Call `canTrimPromptCache(_:)` rather than
   assuming.

None of these blocks shipping. Each names what would close it.

### 13.4 Where to go next

- [`03-authoring-a-languagemodel-provider.md`](03-authoring-a-languagemodel-provider.md) — the
  protocol conformance itself, the generation channel event by event, and packaging.
- [`02-bring-your-own-model.md`](02-bring-your-own-model.md) — choosing a backend, and the
  practical business of pointing Core AI, MLX or an OpenAI-compatible server at a session.
- [Part 3, context window and KV cache](../../part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md)
  — the same cache economics seen from the *app developer's* side, including why changing instructions
  invalidates everything after them.
- [Part 3, history modifiers](../../part-03-context-profiles-agentic/references/03-skills-and-history-modifiers.md)
  — the modifiers that produce exactly the removed-and-modified transcripts §8.3 has to survive.
- [Part 1, the stack map](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/references/01-apple-ai-stack-2026-map.md)
  — the backend decision table, including which architectures forfeit prefix caching and which
  backends forfeit guided generation.
